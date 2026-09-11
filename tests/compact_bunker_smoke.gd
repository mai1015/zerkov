extends SceneTree
## DEFERRED / HISTORICAL SUITE: native compact bunker regression.
## Do not invoke or regenerate smaller-window evidence until task 11.8 or a
## later approved display-support proposal explicitly reopens this suite.

var failures: int = 0
var checks: int = 0
var app
var capture_dir: String = "/tmp/zerkov-compact-bunker"

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: compact_bunker_smoke is historical; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
	else: print("PASS ", message)

func settle() -> void:
	for i in range(5): await process_frame

func click_at(point: Vector2) -> void:
	var motion = InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	await process_frame
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event)
		await process_frame
	await settle()

func wheel(pane: ScrollContainer) -> void:
	var previous: int = pane.scroll_vertical
	var point: Vector2 = pane.get_global_rect().get_center()
	for i in range(20):
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_WHEEL_DOWN
		event.position = point
		event.global_position = point
		event.pressed = true
		root.push_input(event)
		event = event.duplicate()
		event.pressed = false
		root.push_input(event)
	await settle()
	check(pane.scroll_vertical > previous, "%s wheel reaches lower content" % pane.name)
	check(not pane.get_h_scroll_bar().visible, "%s has no horizontal scrolling" % pane.name)

func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	# Capture the settled surface after normal transient feedback disappears.
	if is_instance_valid(app.toast_label) and app.toast_timer.time_left > 0:
		await create_timer(app.toast_timer.time_left + 0.1).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(capture_dir.path_join(label + ".png"))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(capture_dir)
	root.size = Vector2i(1280, 720)
	app = load("res://ui/main.tscn").instantiate()
	app.ui_layout_mode = "compact"
	root.add_child(app)
	app.qa_mode = true
	await settle()
	for resolution in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = resolution
		await settle()
		var suffix: String = str(resolution.x)
		app.navigate("bunker")
		await settle()
		check(app.screen.get_viewport_rect().size == Vector2(resolution), "Bunker uses native %s pixels" % suffix)
		await capture("bunker_" + suffix)
		await wheel(app.screen.get_node("CompactStationDetails"))
		if resolution.y == 540: await wheel(app.screen.get_node("CompactStations"))
		app.screen._on_station(2)
		await settle()
		await click_at(Vector2(resolution.x - 96, resolution.y - 38))
		check(app.current_route == "crafting", "Pinned Use opens selected medical station")
		await capture("crafting_" + suffix)
		await wheel(app.screen.get_node("CompactRecipes"))
		await wheel(app.screen.get_node("CompactCraftDetail"))
		await click_at(Vector2(568, 142))
		check(app.screen._compact_craft_tab == "QUEUE", "Queue tab opens after wheel scrolling")
		await capture("queue_" + suffix)
		await wheel(app.screen.get_node("CompactCraftQueue"))
		app.screen._compact_collect_all()
		await settle()
		var queue_size: int = app.state.bunker_craft_queue.size()
		await click_at(Vector2(resolution.x - 128, resolution.y - 38))
		check(app.state.bunker_craft_queue.size() == mini(queue_size + 1, 2), "Pinned craft action remains usable")
		app.navigate("build_mode")
		await settle()
		await capture("build_mode_" + suffix)
		await wheel(app.screen.get_node("CompactBuildCatalog"))
		await click_at(Vector2(resolution.x - 270, resolution.y - 38))
		check(app.screen._build_rotation == 1, "Pinned rotate survives compact rebuild")
		app.screen._confirm_place_building()
		await settle()
		check(app.state.bunker_placed >= 8, "Compact placement persists mock state")
		app.navigate("session")
		await settle()
		await capture("session_" + suffix)
		await click_at(Vector2(resolution.x - 432, 204))
		check(app.state.bunker_privacy == "CLOSED", "Session privacy survives compact rebuild")
		await wheel(app.screen.get_node("CompactSession"))
		await capture("session_scrolled_" + suffix)
	print("COMPACT_BUNKER_TEST_COMPLETE checks=", checks, " failures=", failures)
	quit(failures)
