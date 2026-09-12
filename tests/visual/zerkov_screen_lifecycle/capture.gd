extends SceneTree
## Captures one lifecycle-active shared screen without re-opening the initial route.

const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")

var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("ZERKOV_SCREEN_LIFECYCLE_CAPTURE: " + message)


func settle() -> void:
	for _frame in range(6):
		await process_frame


func run() -> void:
	root.size = FIRST_PLAYABLE_SIZE
	check(root.get_visible_rect().size == Vector2(FIRST_PLAYABLE_SIZE),
		"capture is gated to exact 1920x1080")
	if root.get_visible_rect().size != Vector2(FIRST_PLAYABLE_SIZE):
		quit(2)
		return
	var capture_path := "res://screen_lifecycle_capture.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-path="):
			capture_path = argument.trim_prefix("--capture-path=")

	var app := load("res://ui/main.tscn").instantiate() as Control
	check(app != null, "main scene instantiates")
	if app == null:
		quit(1)
		return
	app.initial_route = "main_menu"
	root.add_child(app)
	app.qa_mode = true
	await settle()

	var screen := app.screen as ZScreen
	check(screen != null, "main menu uses the shared ZScreen base")
	check(screen != null and screen.is_routing_active(),
		"captured shared screen is CommonUI routing-active")
	check(screen != null and app.common_ui_root.menu_layer().get_top_screen() == screen,
		"captured shared screen owns the CommonUI menu layer top")

	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	var exact_capture_size := image.get_size() == FIRST_PLAYABLE_SIZE
	check(exact_capture_size,
		"framebuffer is exact 1920x1080 immediately before capture")
	if not exact_capture_size:
		capture_path = ""
		quit(2)
		return
	var absolute_path := ProjectSettings.globalize_path(capture_path)
	DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	if not Exact1080CaptureGuard.accepts(root, root, image):
		push_error("ZERKOV_SCREEN_LIFECYCLE_CAPTURE: physical output changed before PNG write")
		quit(2)
		return
	var save_error := image.save_png(absolute_path)
	check(save_error == OK, "capture saves successfully: " + error_string(save_error))
	print("ZERKOV_SCREEN_LIFECYCLE_CAPTURE_RESULT failures=", failures,
		" size=", image.get_size(), " path=", capture_path)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
