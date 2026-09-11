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
	app.prototype_fixture_mode = true
	root.add_child(app)
	app.qa_mode = true
	await settle()
	app.navigate("bunker")
	await settle()
	var original_station = app.screen._selected_station
	await click_at(Vector2(150, 196))
	check(app.screen._selected_station == original_station
		and app.toast_label.text.contains("PROTOTYPE ONLY"),
		"Station activation discloses the gate without changing its mock selection")
	await click_at(Vector2(1820, 1010))
	check(app.current_route == "bunker", "Gated station Use preserves the bunker route")
	app.navigate("crafting")
	await settle()
	var original_recipe = JSON.stringify(app.screen._recipe_data())
	var queue_before = JSON.stringify(app.fixture_state_for_test().bunker_craft_queue)
	var collected_before = JSON.stringify(app.fixture_state_for_test().get("bunker_collected"))
	app.screen._on_recipe_selected(1)
	await settle()
	check(JSON.stringify(app.screen._recipe_data()) == original_recipe,
		"Prototype recipe action preserves detail data")
	app.screen._on_collect_queue("splint")
	await settle()
	check(JSON.stringify(app.fixture_state_for_test().bunker_craft_queue) == queue_before,
		"Prototype collection preserves the queue")
	check(JSON.stringify(app.fixture_state_for_test().get("bunker_collected")) == collected_before,
		"Prototype collection creates no stash receipt")
	app.screen._on_craft_now()
	await settle()
	check(app.fixture_state_for_test().bunker_craft_queue.size() == 2,
		"Prototype craft preserves queue size")
	check(JSON.stringify(app.fixture_state_for_test().bunker_craft_queue) == queue_before,
		"Prototype craft preserves queue contents")
	app.screen._on_craft_now()
	check(app.fixture_state_for_test().bunker_craft_queue.size() == 2,
		"Repeated prototype craft creates no duplicate output")
	app.fixture_state_for_test().bunker_craft_queue[0].finish_at = Time.get_ticks_msec() - 1
	await settle()
	await settle()
	check(app.screen._craft_status_labels[0].text == "READY", "Timer completion updates ready state")
	app.screen._on_collect_queue(str(
		app.fixture_state_for_test().bunker_craft_queue[0].id))
	await settle()
	check(app.fixture_state_for_test().bunker_craft_queue.size() == 2,
		"Ready fixture craft remains read-only behind the gate")
	app.navigate("build_mode")
	await settle()
	var original_rotation = app.screen._build_rotation
	var original_placed = app.fixture_state_for_test().get("bunker_placed")
	await key(KEY_R)
	check(app.screen._build_rotation == original_rotation,
		"Prototype rotate preserves the authored build preview")
	app.screen._on_build_item("GENERATOR")
	await settle()
	app.screen._on_place_building()
	check(not is_instance_valid(app.modal), "Blocked placement does not open confirmation")
	app.screen._on_build_item("WORKBENCH")
	await settle()
	app.screen._confirm_place_building()
	await settle()
	check(app.fixture_state_for_test().get("bunker_placed") == original_placed,
		"Prototype placement preserves placed count")
	await key(KEY_ESCAPE)
	check(app.current_route == "bunker", "Escape exits build mode to bunker")
	await key(KEY_B)
	check(app.current_route == "bunker" and app.toast_label.text.contains("PROTOTYPE ONLY"),
		"B discloses the prototype build gate")
	app.navigate("session")
	await settle()
	var original_privacy = app.fixture_state_for_test().get("bunker_privacy")
	await click_at(Vector2(1460, 170))
	check(app.fixture_state_for_test().get("bunker_privacy") == original_privacy,
		"Prototype session privacy stays unchanged")
	var original_code = app.fixture_state_for_test().get("bunker_code")
	app.screen._on_new_code()
	await settle()
	check(app.fixture_state_for_test().get("bunker_code") == original_code,
		"Prototype new-code action preserves the world code")
	var invited_before = JSON.stringify(app.fixture_state_for_test().get("bunker_invited"))
	app.screen._on_invite("DENZ")
	await settle()
	check(JSON.stringify(app.fixture_state_for_test().get("bunker_invited")) == invited_before,
		"Prototype invite adds no mock social state")
	var guest_before = app.fixture_state_for_test().get("bunker_guest_present")
	app.screen._confirm_kick_guest()
	await settle()
	check(app.fixture_state_for_test().get("bunker_guest_present") == guest_before,
		"Prototype kick preserves world occupancy")
	app.fixture_state_for_test()["frontflow_worlds"] = [
		{"name": "QA World", "privacy": "FRIENDS", "max_players": 3}]
	app.fixture_state_for_test()["frontflow_selected_world"] = 0
	app.navigate("session")
	await settle()
	check(app.fixture_state_for_test().bunker_privacy == "FRIENDS" \
			and app.screen._max_players() == 3,
		"Session reads selected world settings")
	app.screen._on_privacy("CLOSED")
	await settle()
	check(app.fixture_state_for_test().frontflow_worlds[0].privacy == "FRIENDS",
		"Prototype privacy action preserves selected world metadata")
	print("BUNKER_TEST_COMPLETE failures=", failures)
	quit(failures)
