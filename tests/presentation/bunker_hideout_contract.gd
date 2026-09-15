extends SceneTree
## Genuine graphical capture of the exact production view, not a painted mockup.
const VIEW = preload("res://game/presentation/bunker/bunker_hideout_view.tscn")
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
var checks := 0
var failures := 0
var view: ZBunkerHideoutView
var output := ""

func _initialize() -> void:
	_run.call_deferred()

func expect(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("BUNKER_ASSERTION: " + description)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("BUNKER_CAPTURE_REQUIRES_GRAPHICAL_RENDERER")
		quit(2)
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	if output.is_empty():
		quit(2)
		return
	root.borderless = true
	root.size = Vector2i(1920, 1080)
	await process_frame
	expect(root.size == Vector2i(1920, 1080), "window size before mount")
	expect(DisplayServer.window_get_size() == Vector2i(1920, 1080), "physical window size")
	view = VIEW.instantiate()
	root.add_child(view)
	for index: int in range(5):
		await process_frame
	expect(view.world.valid, "authored world loaded")
	expect(view.surface.size == Vector2i(640, 360), "native world raster")
	expect(view.world.assets.size() == 72, "source kit identity count")
	expect(view.world.layout["props"].size() == 20, "authored station/prop count")
	expect(view.world.layout["rooms"].size() == 6, "room count")
	expect(view.current_room == "workshop", "initial selected workshop")
	expect(not view.select_room("unknown"), "unknown selection rejected")
	expect(view.current_room == "workshop", "invalid selection mutation-free")
	expect(view.world.layout["systems_available"] == false, "no invented simulation")
	# Native input dispatch: both facility list and the map must select rooms.
	await click(Vector2(1620, 224))
	expect(view.current_room == "storage", "actual list mouse input")
	await click(Vector2(720, 510))
	expect(view.current_room == "workshop", "actual map mouse input")
	await click(Vector2(1620, 350))
	expect(view.current_room == "medical", "medical list input")
	await click(Vector2(1620, 266))
	expect(view.current_room == "workshop", "return to workshop")
	for room: Dictionary in view.world.layout["rooms"]:
		expect(view.world.assets.has(room["station"]), "station source resolves " + room["id"])
		var r: Array = room["rect"]
		expect(view.world.room_at(Vector2(r[0] + 4, r[1] + 4)) == room["id"], "room anchor resolves")
	var standard: Image = await capture("bunker-standard-1080.png")
	await click(Vector2(1680, 930))
	expect(view.emergency, "lighting button is cosmetic and responsive")
	var emergency: Image = await capture("bunker-emergency-1080.png")
	if standard != null and emergency != null:
		expect(standard.get_pixel(24, 24) == emergency.get_pixel(24, 24), "HUD unaffected by world treatment")
		expect(standard.get_pixel(760, 460) != emergency.get_pixel(760, 460), "lighting changes rendered world")
	view.queue_free()
	await process_frame
	print("BUNKER_NATIVE_RESULT checks=%d failures=%d output=1920x1080 world=640x360 scale=3 rooms=6 props=20 captures=2" % [checks, failures])
	quit(0 if failures == 0 else 1)

func click(point: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = point
	move.global_position = point
	Input.parse_input_event(move)
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await process_frame

func capture(filename: String) -> Image:
	for index: int in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if not Exact1080CaptureGuard.accepts(root, root, image):
		push_error("BUNKER_CAPTURE_PHYSICAL_GUARD")
		failures += 1
		return null
	expect(image.get_size() == Vector2i(1920, 1080), "raw screenshot dimensions")
	DirAccess.make_dir_recursive_absolute(output)
	if not Exact1080CaptureGuard.accepts(root, root, image):
		return null
	var saved := image.save_png(output.path_join(filename))
	expect(saved == OK, "save native PNG")
	return image
