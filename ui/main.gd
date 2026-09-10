extends Control

const U = preload("res://ui/theme/tokens.gd")
const Adaptive = preload("res://ui/core/adaptive.gd")
const RouteCatalog = preload("res://ui/core/route_catalog.gd")
const DESKTOP_CANVAS = Vector2i(1920, 1080)
const DESKTOP_MIN_WINDOW = Vector2i(1280, 720)
var ROUTES: Dictionary = RouteCatalog.labels()
@export var initial_route: String = "title"
var fixtures := ZUIFixtureStore.new()

var state: Dictionary:
	get: return fixtures.state
	set(value): fixtures.state = value
var current_route: String = ""
var previous_route: String = "main_menu"
var navigator: ZUINavigator
var history: Array[String]:
	get: return navigator.history() if navigator != null else []
var screen: Control
var feedback: ZUIFeedback
var overlay: Control:
	get: return feedback
var toast_label: Label:
	get: return feedback.toast_label if feedback != null else null
var toast_timer: Timer:
	get: return feedback.toast_timer if feedback != null else null
var picker: Control:
	get: return feedback.picker if feedback != null else null
var modal: Control:
	get: return feedback.modal if feedback != null else null
var qa_mode: bool = false
var resize_timer: Timer
var _last_window_size: Vector2i
var _resize_pending: bool = false
var ui_layout_mode: String = "auto"
var common_ui_root: CommonUIScreenRoot
var screen_layer: CommonUILayer

func _ready() -> void:
	common_ui_root = get_node("CommonUIScreenRoot") as CommonUIScreenRoot
	screen_layer = common_ui_root.menu_layer()
	navigator = ZUINavigator.new()
	navigator.configure(self, common_ui_root)
	add_child(navigator)
	navigator.committed.connect(_on_route_committed)
	navigator.rejected.connect(func(_route: String, reason: String) -> void: toast(reason))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--layout="):
			var requested = arg.trim_prefix("--layout=")
			if requested in ["auto", "desktop", "compact"]:
				ui_layout_mode = requested
	_sync_window_scale()
	resize_timer = Timer.new()
	resize_timer.one_shot = true
	resize_timer.wait_time = 0.12
	resize_timer.timeout.connect(_finish_window_resize)
	add_child(resize_timer)
	get_window().size_changed.connect(_on_window_resized)
	theme = U.make_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	RenderingServer.set_default_clear_color(U.BG)
	feedback = preload("res://ui/core/feedback.tscn").instantiate()
	feedback.configure(self, common_ui_root)
	add_child(feedback)
	var start = initial_route
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screen="):
			start = arg.trim_prefix("--screen=")
		if arg == "--qa" or arg == "--smoke":
			qa_mode = true
	navigate(start, false)
	if qa_mode:
		call_deferred("_run_qa")

func _sync_window_scale() -> void:
	var window = get_window()
	_last_window_size = window.size
	# Normal PC previews retain the handoff composition. Compact reflow is a
	# fallback for genuinely small windows, not every window below native1080p.
	var desktop = ui_layout_mode == "desktop" or (ui_layout_mode == "auto" and window.size.x >= DESKTOP_MIN_WINDOW.x and window.size.y >= DESKTOP_MIN_WINDOW.y)
	var logical = DESKTOP_CANVAS if desktop else window.size
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	if window.content_scale_size != logical:
		window.content_scale_size = logical

func _on_window_resized() -> void:
	if get_window().size == _last_window_size:
		return
	_sync_window_scale()
	_resize_pending = true
	if is_instance_valid(resize_timer):
		resize_timer.start()

func _finish_window_resize() -> void:
	if qa_mode or current_route.is_empty():
		return
	var view: Vector2 = get_viewport_rect().size
	if is_instance_valid(modal) and not modal.is_queued_for_deletion():
		if modal.has_method("resize_to_view"):
			modal.resize_to_view(view)
		else:
			modal.get_child(0).size = view
			var dialog: Control = modal.get_child(1)
			dialog.position = (view - dialog.size) / 2
		# Confirmation callbacks may belong to the current screen. Keep it alive
		# until the dialog completes, then apply the deferred reflow.
		return
	_resize_pending = false
	for layer in [common_ui_root.hud_layer(), common_ui_root.menu_layer()]:
		for child in layer.get_children():
			if child is ZScreen and layer.has_screen(child): child.reflow(view)
	feedback.resize_to_view(view)

func _on_route_committed(route: String, view: Control) -> void:
	previous_route = current_route if not current_route.is_empty() else "main_menu"
	current_route = route
	screen = view

func navigate(route: String, record: bool = true) -> void:
	feedback.dismiss_all()
	navigator.navigate(route, record)

func back() -> void:
	navigator.back()

func handle_back_action() -> void:
	if is_instance_valid(modal):
		_close_overlay(modal)
	elif is_instance_valid(picker):
		_close_overlay(picker)
	elif current_route == "pause":
		back()
	elif current_route in ["build_mode", "crafting", "summary_solo", "summary_squad"]:
		navigate("bunker")
	elif current_route in ["hud", "hud_coop", "bunker", "session", "main_menu"]:
		navigate("pause")
	else:
		back()

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if event is InputEventKey and event.keycode == KEY_F1:
		toggle_picker()
		get_viewport().set_input_as_handled()
		return
	if is_instance_valid(modal) or is_instance_valid(picker):
		if event is InputEventKey and event.keycode == KEY_ESCAPE:
			_close_overlay(modal if is_instance_valid(modal) else picker)
		get_viewport().set_input_as_handled()
		return
	if current_route == "title" and (event is InputEventKey or event is InputEventMouseButton):
		navigate("main_menu")
		get_viewport().set_input_as_handled()
		return
	if not event is InputEventKey:
		return
	if event.keycode == KEY_ESCAPE:
		handle_back_action()
		get_viewport().set_input_as_handled()
		return
	var focused = get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	if current_route in ["hud", "hud_coop", "inventory", "health", "stats", "maps", "tasks", "bunker", "session"]:
		match event.keycode:
			KEY_TAB:
				if current_route in ["inventory", "health", "stats"]: back()
				else: navigate("inventory")
			KEY_M: navigate("maps")
			KEY_J: navigate("tasks")

func _run_qa() -> void:
	var capture_dir = ""
	var single = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): capture_dir = arg.trim_prefix("--capture-dir=")
		if arg.begins_with("--screen="): single = arg.trim_prefix("--screen=")
	if not capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(capture_dir)
	var failures = 0
	var routes: Array = [single] if not single.is_empty() else ROUTES.keys()
	for route in routes:
		if not ResourceLoader.exists(RouteCatalog.path_for(route)):
			push_error("QA missing scene: " + route)
			failures += 1
			continue
		navigate(route, false)
		for frame in range(6):
			await get_tree().process_frame
		if screen.get_script() == null or screen.get_child_count() == 0:
			push_error("QA screen did not build: " + route)
			failures += 1
		if not capture_dir.is_empty():
			await RenderingServer.frame_post_draw
			var capture = get_viewport().get_texture().get_image()
			var err = capture.save_png(capture_dir.path_join(route + ".png"))
			if err != OK: failures += 1
		print("QA_SCREEN ", route, " nodes=", screen.find_children("*", "", true, false).size())
	print("QA_COMPLETE screens=", routes.size(), " missing_or_capture_errors=", failures)
	get_tree().quit(0 if failures == 0 else 1)

# Small public facade for screen contexts and the native review harness.
func toast(message: String) -> void:
	feedback.toast(message)

func confirm(title_text: String, message: String, callback: Callable) -> void:
	feedback.confirm(title_text, message, callback)

func prompt(title_text: String, initial_value: String, callback: Callable, max_length: int = 24) -> void:
	feedback.prompt(title_text, initial_value, callback, max_length)

func toggle_picker() -> void:
	feedback.toggle_picker()

func _close_overlay(control: Control) -> void:
	feedback._close_overlay(control)
