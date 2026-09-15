extends SceneTree
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
const Scene = preload("res://game/presentation/northline_zone/northline_zone.tscn")
const EXACT := Vector2i(1920,1080)
var checks: int = 0
var failures: int = 0
var output: String = ""

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("NORTHLINE_ASSERTION: " + label)

func frames(count: int = 3) -> void:
	for i: int in range(count):
		await process_frame
	await RenderingServer.frame_post_draw

func click(at: Vector2) -> void:
	var move := InputEventMouseMotion.new()
	move.position = at
	move.global_position = at
	Input.parse_input_event(move)
	for pressed: bool in [true,false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await frames()

func key(code: int) -> void:
	for pressed: bool in [true,false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await frames()

func capture(name: String) -> void:
	root.gui_release_focus()
	var move := InputEventMouseMotion.new()
	move.position = Vector2(1870,998)
	move.global_position = move.position
	Input.parse_input_event(move)
	await frames(3)
	var image := root.get_texture().get_image()
	if not Exact1080CaptureGuard.accepts(root, root, image):
		check(false,"physical capture guard")
		return
	check(image.save_png(output.path_join(name)) == OK,"save " + name)

func run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	if output.is_empty() or DisplayServer.get_name() == "headless":
		print("NORTHLINE_BLOCKED: graphical renderer and output required")
		quit(2)
		return
	root.borderless = true
	root.size = EXACT
	await process_frame
	DirAccess.make_dir_recursive_absolute(output)
	var view = Scene.instantiate()
	root.add_child(view)
	await frames()
	check(view.overview,"initial full map")
	check(view.surface.size == Vector2i(640,360),"world raster remains fixed")
	check(view.data["size"] == [2688.0,1792.0],"actual larger geometry")
	check(view.world.get_node("AuthoredLayoutCollision").get_child_count() > 600,"native wall + cover collision")
	check(view.world.props_root.get_child_count() > 500,"individual placed props")
	await capture("northline-full-map-1080.png")
	for i: int in range(view.data["sectors"].size()):
		view.select_sector(i)
		await frames()
		check(view.camera.zoom == Vector2.ONE,"unchanged detail scale")
		await capture("northline-" + str(view.data["sectors"][i]["id"]) + "-1080.png")
	view.toggle_overview()
	view.toggle_routes()
	await frames()
	await capture("northline-routes-1080.png")
	view.toggle_routes()
	# Actual native GUI events switch sectors and overview.
	await click(Vector2(1330,40))
	check(not view.overview,"native overview button")
	root.gui_release_focus()
	await key(KEY_M)
	check(view.overview,"native overview keyboard")
	await click(Vector2(132,282))
	check(view.sector_index == 4 and not view.overview,"native sector selection")
	view.pan(Vector2(-10000,-10000))
	check(view.camera.position == Vector2(320,180),"camera min")
	view.pan(Vector2(10000,10000))
	check(view.camera.position == Vector2(2368,1612),"camera max")
	root.gui_release_focus()
	await key(KEY_P)
	check(view.walk_mode and view.walker.enabled,"native walking-mode control")
	view.walker.animate = false
	# Prove the actual review CharacterBody collides with a fixed wall.
	view.walker.enabled = false
	view.walker.position = Vector2(360,52)
	await physics_frame
	await physics_frame
	var contact = view.walker.move_and_collide(Vector2(0,-80))
	check(contact != null and view.walker.position.y > 12,"native boundary blocks walker")
	view.walker.position = Vector2(view.data["spawn"][0],view.data["spawn"][1])
	await physics_frame
	view.walker.enabled = true
	var start: Vector2 = view.walker.position
	var press := InputEventKey.new()
	press.keycode = KEY_D
	press.physical_keycode = KEY_D
	press.pressed = true
	Input.parse_input_event(press)
	for i: int in range(10):
		await physics_frame
	press = InputEventKey.new()
	press.keycode = KEY_D
	press.physical_keycode = KEY_D
	press.pressed = false
	Input.parse_input_event(press)
	await physics_frame
	check(view.walker.position.x > start.x + 2,"native WASD moves collision inspector")
	# Traverse every checked exit path using actual native move_and_collide.
	view.walker.enabled = false
	for route: Dictionary in view.data["native_walk_routes"]:
		var route_points: Array = route["points"]
		view.walker.position = Vector2(route_points[0][0],route_points[0][1])
		await physics_frame
		await physics_frame
		var clear_path: bool = true
		for point: Array in route_points.slice(1):
			var destination := Vector2(point[0],point[1])
			# Axis-aligned, bounded segments match the offline review grid.
			while view.walker.position.distance_to(destination) > 0.1:
				var motion: Vector2 = (destination-view.walker.position).limit_length(8)
				var hit = view.walker.move_and_collide(motion)
				if hit != null:
					clear_path = false
					break
			if not clear_path:
				break
		check(clear_path,"native exit walk " + str(route["id"]))
	view.select_sector(3)
	if not view.walk_mode:
		view.toggle_walk()
	view.walker.animate = false
	# Reset to a fixed location and pose for reproducible native evidence.
	view.walker.enabled = false
	view.walker.position = Vector2(1132,718)
	view.walker.show_frame(false,0)
	await frames()
	await capture("northline-walkthrough-1080.png")
	print("NORTHLINE_NATIVE_RESULT checks=%d failures=%d captures=12 sectors=9 output=1920x1080 world=640x360" % [checks,failures])
	view.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures == 0 else 1)
