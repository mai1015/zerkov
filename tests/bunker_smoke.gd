extends SceneTree

var failures = 0
var app

func _initialize():
	call_deferred("run")

func check(value: bool, message: String):
	if not value:
		failures += 1
		push_error(message)
	else: print("PASS ", message)

func settle():
	await process_frame
	await process_frame

func click_at(point: Vector2):
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event)
	await settle()

func key(code: Key):
	for pressed in [true, false]:
		var event = InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()

func run():
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	app.qa_mode = true
	await settle()
	app.navigate("bunker")
	await settle()
	await click_at(Vector2(150, 196))
	check(app.screen._selected_station == 2, "Station selection persists during rebuild")
	await click_at(Vector2(1820, 1010))
	check(app.current_route == "crafting", "Medical station Use opens crafting")
	app.screen._on_recipe_selected(1)
	await settle()
	check(app.screen._recipe_data()[0] == "Splint", "Recipe selection updates detail data")
	app.screen._on_collect_queue("splint")
	await settle()
	check(app.state.bunker_craft_queue.size() == 1, "Ready craft collection frees a slot")
	check(app.state.bunker_collected.has("Splint ×1"), "Collection records stash receipt")
	app.screen._on_craft_now()
	await settle()
	check(app.state.bunker_craft_queue.size() == 2, "Selected recipe queues after collection")
	check(app.state.bunker_craft_queue[1].name.begins_with("Splint"), "Queued output matches selected recipe")
	app.screen._on_craft_now()
	check(app.state.bunker_craft_queue.size() == 2, "Full queue rejects additional craft")
	app.state.bunker_craft_queue[0].finish_at = Time.get_ticks_msec() - 1
	await settle()
	await settle()
	check(app.screen._craft_status_labels[0].text == "READY", "Timer completion updates ready state")
	app.screen._on_collect_queue(str(app.state.bunker_craft_queue[0].id))
	await settle()
	check(app.state.bunker_craft_queue.size() == 1, "Newly finished craft can be collected")
	app.navigate("build_mode")
	await settle()
	await key(KEY_R)
	check(app.screen._build_rotation == 1, "Rotate persists and rebuilds preview")
	app.screen._on_build_item("GENERATOR")
	await settle()
	app.screen._on_place_building()
	check(not is_instance_valid(app.modal), "Blocked placement does not open confirmation")
	app.screen._on_build_item("WORKBENCH")
	await settle()
	app.screen._confirm_place_building()
	await settle()
	check(app.state.bunker_placed == 8, "Placement increments visible placed count")
	await key(KEY_ESCAPE)
	check(app.current_route == "bunker", "Escape exits build mode to bunker")
	await key(KEY_B)
	check(app.current_route == "build_mode", "B enters build mode")
	app.navigate("session")
	await settle()
	await click_at(Vector2(1460, 170))
	check(app.state.bunker_privacy == "CLOSED", "Session privacy survives rebuild")
	var original_code = app.state.bunker_code
	app.screen._on_new_code()
	await settle()
	check(app.state.bunker_code != original_code, "New code changes world code")
	app.screen._on_invite("DENZ")
	await settle()
	check(app.state.bunker_invited.has("DENZ"), "Mock invite has persistent visible state")
	app.screen._confirm_kick_guest()
	await settle()
	check(not app.state.bunker_guest_present, "Kick removes guest and updates world occupancy")
	app.state["frontflow_worlds"] = [{"name": "QA World", "privacy": "FRIENDS", "max_players": 3}]
	app.state["frontflow_selected_world"] = 0
	app.navigate("session")
	await settle()
	check(app.state.bunker_privacy == "FRIENDS" and app.screen._max_players() == 3, "Session reads selected world settings")
	app.screen._on_privacy("CLOSED")
	await settle()
	check(app.state.frontflow_worlds[0].privacy == "CLOSED", "Privacy updates selected world metadata")
	print("BUNKER_TEST_COMPLETE failures=", failures)
	quit(failures)
