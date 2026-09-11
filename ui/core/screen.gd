class_name ZScreen
extends CommonActivatableScreen

const U = preload("res://ui/theme/tokens.gd")
const InputActions = preload("res://game/input/zerkov_input_actions.gd")
var app: ZUIContext
var _adaptive_queued: bool = false
var _adaptive_applied: bool = false
var _layout_snapshot: ZLayoutSnapshot
var _layout_size := Vector2(-1, -1)
var lower_contexts: Array[CommonUIContextHandle] = []
var _production_state_locked: bool = false

const PRODUCTION_SELF_MANAGED_ROUTES: PackedStringArray = [
	"title", "controls", "inventory", "health", "stats",
]
const LOCKED_STATE_NODE: StringName = &"ProductionUnavailableState"

func _ready() -> void:
	if app == null:
		_open_preview_host.call_deferred()
		return
	screen_context = StringName("screen/" + app.current_route)
	context_priority = ZRouteCatalog.priority_for(app.current_route)
	theme = U.make_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_for_context()
	queue_adaptive_layout()

func _open_preview_host() -> void:
	# F6 on any route is an isolated fixture session with normal CommonUI input.
	var host: Control = load("res://ui/dev/preview_host.tscn").instantiate()
	host.initial_route = ZRouteCatalog.id_for_scene(scene_file_path)
	if host.initial_route.is_empty():
		host.free()
		push_error("Register the preview scene in ZRouteCatalog first: " + scene_file_path)
		return
	get_tree().root.add_child(host)
	queue_free()

func build() -> void:
	pass

func _on_activated() -> void:
	process_mode = Node.PROCESS_MODE_INHERIT
	register_action(CommonUIDefaults.BACK, _on_common_ui_back, {"priority": 100})
	_register_zerkov_ui_actions()


func _register_zerkov_ui_actions() -> void:
	if app == null:
		return
	# These are the already-advertised first-playable navigation affordances.
	# Registration stays on the active ZScreen so CommonUI owns eligibility,
	# modal suspension, and exactly-once dispatch; no parallel input stack is
	# introduced here. Gameplay actions remain definitions-only until task 5.7.
	var route := app.current_route
	if route not in [
		"hud", "hud_coop", "inventory", "health", "stats", "maps", "tasks",
		"bunker", "session", "settings", "controls"
	]:
		return
	register_action(InputActions.UI_OPEN_INVENTORY, _on_open_inventory, {"priority": 40})
	register_action(InputActions.UI_OPEN_MAP, _on_open_map, {"priority": 40})
	register_action(InputActions.UI_OPEN_TASKS, _on_open_tasks, {"priority": 40})
	register_action(InputActions.UI_OPEN_SETTINGS, _on_open_settings, {"priority": 40})


func _on_open_inventory(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED or not accepts_input():
		return CommonUIRuntime.ROUTE_UNHANDLED
	if app.current_route in ["inventory", "health", "stats"]:
		app.back()
	else:
		app.navigate("inventory")
	return CommonUIRuntime.ROUTE_HANDLED


func _on_open_map(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED or not accepts_input():
		return CommonUIRuntime.ROUTE_UNHANDLED
	app.navigate("maps")
	return CommonUIRuntime.ROUTE_HANDLED


func _on_open_tasks(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED or not accepts_input():
		return CommonUIRuntime.ROUTE_UNHANDLED
	app.navigate("tasks")
	return CommonUIRuntime.ROUTE_HANDLED


func _on_open_settings(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED or not accepts_input():
		return CommonUIRuntime.ROUTE_UNHANDLED
	app.navigate("settings")
	return CommonUIRuntime.ROUTE_HANDLED

func _on_deactivated() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED

func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
	return lower_contexts.duplicate()

func accepts_input() -> bool:
	return app != null and not _production_state_locked and app.accepts_input(self)

func refresh_view() -> void:
	if _should_render_locked_state():
		var reason := &"fixture_provider_stale_generation" \
				if app != null and app.fixture_generation() > 0 else &""
		_build_locked_state(reason)
		return
	var interaction := ZLayoutSnapshot.interaction(self)
	if _layout_snapshot != null: _layout_snapshot.restore(self)
	reset_adaptive_layout()
	_build_for_context()
	if _layout_snapshot == null: _layout_snapshot = ZLayoutSnapshot.new(self)
	_apply_adaptive_layout()
	# Bind the deferred restore to this screen instance. If CommonUI replaces the
	# screen before the message runs, Godot drops the call with the retired owner
	# instead of passing a freed Object through a typed static callable.
	call_deferred("_restore_interaction_if_current", interaction)


func _restore_interaction_if_current(interaction: Dictionary) -> void:
	if not is_inside_tree() or app == null or _production_state_locked:
		return
	ZLayoutSnapshot.restore_interaction(self, interaction)

func reflow(view: Vector2) -> void:
	if view.is_equal_approx(_layout_size): return
	refresh_view()


func _build_for_context() -> void:
	_production_state_locked = false
	if app == null:
		return
	if app.fixture_generation() > 0:
		if not app.has_fixture_provider() or not _prepare_fixture_preview():
			_build_locked_state(&"fixture_provider_stale_generation")
			return
		build()
		return
	if _should_render_locked_state():
		_build_locked_state()
		return
	build()


func _prepare_fixture_preview() -> bool:
	return app != null and app.prepare_fixture_route()


func _should_render_locked_state() -> bool:
	if app == null:
		return false
	if app.fixture_generation() > 0:
		return not app.has_fixture_provider()
	if app.current_route in PRODUCTION_SELF_MANAGED_ROUTES:
		if app.current_route in ["inventory", "health", "stats"]:
			return app.character_runtime() == null
		if app.current_route == "controls":
			var input := app.input_service()
			return input == null or not input.is_configured()
		return false
	return true


func _build_locked_state(reason_override: StringName = &"") -> void:
	_production_state_locked = true
	set_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	set_process_unhandled_key_input(false)
	var existing := get_node_or_null(NodePath(String(LOCKED_STATE_NODE)))
	if existing != null:
		existing.free()
	for child in get_children():
		if child is CanvasItem:
			(child as CanvasItem).hide()

	var overlay := Panel.new()
	overlay.name = LOCKED_STATE_NODE
	overlay.position = Vector2.ZERO
	overlay.size = Vector2(1920, 1080)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_theme_stylebox_override("panel", U.style(U.BG, Color.TRANSPARENT, 0))
	overlay.show()
	add_child(overlay)

	var card := Panel.new()
	card.position = Vector2(520, 326)
	card.size = Vector2(880, 428)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.add_theme_stylebox_override("panel", U.style(U.PANEL, U.LINE, 1))
	overlay.add_child(card)

	var route_label: String = String(
		ZRouteCatalog.labels().get(app.current_route, app.current_route))
	var title := U.label(card, String(route_label).to_upper(),
		Rect2(48, 40, 784, 40), 22, U.TEXT)
	title.add_theme_font_override("font", U.tracked_font(false, true, 2))
	U.label(card, "PRODUCTION DATA UNAVAILABLE",
		Rect2(48, 96, 784, 28), 13, U.RED, true)
	var detail := U.label(card,
		"No authoritative presentation service is connected for this route. " \
		+ "The screen is locked and no fixture profile, inventory, raid, task, " \
		+ "map, or settlement state has been created.",
		Rect2(48, 144, 784, 92), 14, U.SOFT)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.vertical_alignment = VERTICAL_ALIGNMENT_TOP

	var view := app.presentation_view()
	var sync_name := String(view.sync_state_name()).to_upper() \
			if view != null else "UNBOUND"
	var diagnostic := reason_override if not reason_override.is_empty() \
			else app.presentation_diagnostic()
	U.label(card, "STATE  %s" % sync_name,
		Rect2(48, 256, 240, 28), 11, U.MUTED, true)
	var diagnostic_label := U.label(card,
		"DIAGNOSTIC  " + String(diagnostic).to_upper(),
		Rect2(48, 292, 784, 28), 11, U.YELLOW, true)
	diagnostic_label.clip_text = true
	diagnostic_label.tooltip_text = String(diagnostic)
	var action_text := "RETURN TO TITLE" if app.current_route == "main_menu" else "BACK"
	var callback := Callable(self, "_return_from_locked_state")
	var action := U.button(card, action_text, Rect2(48, 348, 240, 44), callback, false)
	default_focus = get_path_to(action)


func _return_from_locked_state() -> void:
	if app == null:
		return
	if app.current_route == "main_menu":
		app.navigate("title", false)
	else:
		app.back()

func _on_common_ui_back(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	if app != null:
		app.back()
	return CommonUIRuntime.ROUTE_HANDLED

func reset_adaptive_layout() -> void:
	_adaptive_applied = false

func queue_adaptive_layout() -> void:
	if _adaptive_queued:
		return
	_adaptive_queued = true
	call_deferred("_apply_adaptive_layout")

func _apply_adaptive_layout() -> void:
	_adaptive_queued = false
	if _adaptive_applied or not is_inside_tree():
		return
	var view: Vector2 = get_viewport_rect().size
	_layout_size = view
	if _layout_snapshot == null: _layout_snapshot = ZLayoutSnapshot.new(self)
	if view.x < 1920 or view.y < 1080:
		_adaptive_applied = true
		layout_compact(view)
	var navigation := get_node_or_null("NavigationChrome") as ZNavigationChrome
	if navigation != null:
		navigation.show()
		navigation.layout_for(view)

func layout_compact(_view: Vector2) -> void:
	pass

func box(parent: Node, bounds: Rect2, color: Color = U.PANEL, border: Color = U.LINE) -> Panel:
	var node = Panel.new()
	node.add_theme_stylebox_override("panel", U.style(color, border))
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	U.place(node, bounds)
	parent.add_child(node)
	return node

func txt(parent: Node, content: String, bounds: Rect2, font_size: int = 14, color: Color = U.TEXT, mono: bool = false) -> Label:
	return U.label(parent, content, bounds, font_size, color, mono)

func pic(parent: Node, asset_name: String, bounds: Rect2, cover: bool = false) -> TextureRect:
	var node = TextureRect.new()
	var path = asset_name if asset_name.begins_with("res://") else "res://assets/handoff/" + asset_name
	if ResourceLoader.exists(path):
		node.texture = load(path)
	else:
		push_warning("Missing UI art: " + path)
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if cover else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	U.place(node, bounds)
	parent.add_child(node)
	return node

func btn(parent: Node, content: String, bounds: Rect2, callback: Callable, primary: bool = false) -> Button:
	return U.button(parent, content, bounds, callback, primary)

func bar(parent: Node, bounds: Rect2, value: float, color: Color = U.GREEN) -> ProgressBar:
	var node = ProgressBar.new()
	node.show_percentage = false
	node.value = value
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill_style = U.style(color, Color.TRANSPARENT, 0)
	var track_style = U.style(U.SUBTLE, Color.TRANSPARENT, 0)
	for s in [fill_style, track_style]:
		s.content_margin_left = 0
		s.content_margin_right = 0
		s.content_margin_top = 0
		s.content_margin_bottom = 0
	node.add_theme_stylebox_override("fill", fill_style)
	node.add_theme_stylebox_override("background", track_style)
	U.place(node, bounds)
	parent.add_child(node)
	return node

func rule(parent: Node, x: float, y: float, width: float) -> ColorRect:
	var node = ColorRect.new()
	node.color = U.LINE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	U.place(node, Rect2(x, y, width, 1))
	parent.add_child(node)
	return node

func heading(content: String, subtitle: String = "") -> void:
	txt(self, content, Rect2(48, 96, 1200, 48), 32)
	if not subtitle.is_empty():
		txt(self, subtitle, Rect2(48, 152, 1400, 24), 12, U.MUTED, true)

func chrome(active: String) -> void:
	var navigation := get_node_or_null("NavigationChrome") as ZNavigationChrome
	if navigation == null:
		navigation = preload("res://ui/components/layout/navigation_chrome.tscn").instantiate()
		navigation.name = "NavigationChrome"
		add_child(navigation)
		navigation.navigate_requested.connect(go)
		navigation.insurance_requested.connect(func(): toast("Insurance claims are outside the approved design set."))
		navigation.back_requested.connect(func(): app.back())
	navigation.active_route = active
	navigation.layout_for(get_viewport_rect().size)

func _compact_chrome(active: String) -> void:
	chrome(active)

func footer(content: String) -> void:
	txt(self, content, Rect2(48, 1024, 1440, 24), 11, U.MUTED, true)

func background(asset_name: String = "bg_raid_frame.png", darkness: float = 0.65, blur: bool = false) -> void:
	var base = box(self, Rect2(0, 0, 1920, 1080), U.BG, Color.TRANSPARENT)
	base.set_meta("z_backdrop", true)
	var bg = pic(self, asset_name, Rect2(0, 0, 1920, 1080), true)
	bg.set_meta("z_backdrop", true)
	if blur:
		bg.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		var material = ShaderMaterial.new()
		material.shader = preload("res://ui/shaders/backdrop.gdshader")
		bg.material = material
	var shade = ColorRect.new()
	shade.color = Color(0, 0, 0, darkness)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_meta("z_backdrop", true)
	U.place(shade, Rect2(0, 0, 1920, 1080))
	add_child(shade)

func go(route: String) -> void:
	app.navigate(route)

func toast(message: String) -> void:
	app.toast(message)
