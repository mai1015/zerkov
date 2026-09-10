class_name ZScreen
extends CommonActivatableScreen

const U = preload("res://ui/theme/tokens.gd")
var app: ZUIContext
var _adaptive_queued: bool = false
var _adaptive_applied: bool = false
var _layout_snapshot: ZLayoutSnapshot
var _layout_size := Vector2(-1, -1)
var lower_contexts: Array[CommonUIContextHandle] = []

func _ready() -> void:
	if app == null:
		_open_preview_host.call_deferred()
		return
	screen_context = StringName("screen/" + app.current_route)
	context_priority = CommonUIDefaults.PRIORITY_HUD if ZRouteCatalog.role_for(app.current_route) == "hud" else CommonUIDefaults.PRIORITY_MENU
	theme = U.make_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	build()
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

func _on_deactivated() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED

func _collect_lower_contexts() -> Array[CommonUIContextHandle]:
	return lower_contexts.duplicate()

func accepts_input() -> bool:
	return app != null and app.accepts_input(self)

func refresh_view() -> void:
	var interaction := ZLayoutSnapshot.interaction(self)
	if _layout_snapshot != null: _layout_snapshot.restore(self)
	reset_adaptive_layout()
	build()
	if _layout_snapshot == null: _layout_snapshot = ZLayoutSnapshot.new(self)
	_apply_adaptive_layout()
	ZLayoutSnapshot.restore_interaction.call_deferred(self, interaction)

func reflow(view: Vector2) -> void:
	if view.is_equal_approx(_layout_size): return
	refresh_view()

func _on_common_ui_back(event: Dictionary) -> int:
	if event.get("phase") != CommonUIRuntime.PHASE_PRESSED:
		return CommonUIRuntime.ROUTE_UNHANDLED
	if app != null and app.has_method("handle_back_action"):
		app.handle_back_action()
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
