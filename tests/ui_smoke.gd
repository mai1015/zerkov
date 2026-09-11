extends SceneTree
## Run with: godot --headless --path . --script res://tests/ui_smoke.gd

var failures: int = 0
var checks: int = 0
var app: Control

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("UI_TEST: " + message)

func settle() -> void:
	await process_frame
	await process_frame

func click_at(point: Vector2) -> void:
	var motion = InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		root.push_input(event)
	await settle()

func press_key(code: Key) -> void:
	for pressed in [true, false]:
		var event = InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()

func run() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	app.qa_mode = true
	await settle()
	await click_at(Vector2(960, 540))
	check(app.current_route == "main_menu", "Click anywhere on title enters main menu")
	await click_at(Vector2(160, 274))
	check(app.current_route == "session", "Main menu Continue button enters bunker session")
	await press_key(KEY_ESCAPE)
	check(app.current_route == "pause", "Escape pauses bunker session")
	await press_key(KEY_ESCAPE)
	check(app.current_route == "session", "Escape resumes original bunker session")
	await press_key(KEY_ESCAPE)
	await press_key(KEY_ENTER)
	check(app.current_route == "session", "Enter activates focused Resume in pause")
	await press_key(KEY_ESCAPE)
	app.screen._privacy_friends()
	await settle()
	check(app.state.get("bunker_privacy") == "FRIENDS", "Pause privacy updates session state")
	check(app.state.get("frontflow_worlds", [])[0].get("privacy") == "FRIENDS", "Pause privacy updates selected world")
	await press_key(KEY_ESCAPE)
	check(app.current_route == "session", "Privacy changes preserve pause return context")
	app.navigate("main_menu", false)
	await settle()
	await press_key(KEY_DOWN)
	await press_key(KEY_ENTER)
	check(app.current_route == "saves", "Arrow and Enter select Play from the main menu")
	for route in app.ROUTES:
		check(ResourceLoader.exists(ZRouteCatalog.path_for(route)), "Missing route scene: " + route)
		app.navigate(route, false)
		await settle()
		check(app.screen.get_script() != null, "Script failed to load: " + route)
		var children: Array[Node] = app.screen.find_children("*", "", true, false)
		check(children.size() >= 5, "Screen did not build: " + route)
		for node in children:
			if node is TextureRect:
				check(node.texture != null, "Missing texture in " + route + ": " + str(node.get_path()))
			if node is Button and not node is OptionButton and not node.disabled and node.get_script() == null:
				var wired = not node.pressed.get_connections().is_empty() or not node.toggled.get_connections().is_empty() or not node.gui_input.get_connections().is_empty()
				check(wired, "Unwired button in " + route + ": " + node.text)
		print("UI_TEST_SCREEN ", route, " nodes=", children.size())

	app.navigate("main_menu", false)
	await settle()
	app.navigate("session")
	await settle()
	app.navigate("settings")
	await settle()
	app.back()
	await settle()
	check(app.current_route == "session", "Back from settings must preserve bunker context")
	app.back()
	await settle()
	check(app.current_route == "pause", "Shared Back policy must open pause from a bunker session")
	app.back()
	await settle()
	check(app.current_route == "session", "Pause Back must restore the retained bunker session")

	app.toggle_picker()
	await settle()
	check(is_instance_valid(app.picker), "F1 screen picker opens")
	var picker_buttons: Array[Node] = app.picker.find_children("*", "Button", true, false)
	check(picker_buttons.size() == app.ROUTES.size(), "Catalog must expose every route")
	app.toggle_picker()
	await settle()
	check(not is_instance_valid(app.picker), "F1 screen picker closes")

	var result: Dictionary = {"accepted": false}
	app.screen.app.confirm("UI test", "Confirm local mock action", func(): result.accepted = true)
	await settle()
	var buttons: Array[Node] = app.modal.find_children("*", "Button", true, false)
	for button in buttons:
		if button.text == "CANCEL": button.pressed.emit()
	await settle()
	check(not result.accepted, "Cancel must not execute confirmation action")
	check(not is_instance_valid(app.modal), "Cancel closes confirmation")
	app.screen.app.confirm("UI test", "Confirm local mock action", func(): result.accepted = true)
	await settle()
	buttons = app.modal.find_children("*", "Button", true, false)
	for button in buttons:
		if button.text == "CONFIRM": button.pressed.emit()
	await settle()
	check(result.accepted, "Confirm executes local action")
	check(not is_instance_valid(app.modal), "Confirm closes confirmation")

	app.state["smoke_sentinel"] = 42
	app.navigate("inventory")
	app.navigate("maps")
	app.navigate("inventory")
	check(app.state.get("smoke_sentinel") == 42, "Local mock state persists across navigation")
	app.navigate("saves")
	await settle()
	var world_count: int = app.state.frontflow_worlds.size()
	app.screen._duplicate_world()
	await settle()
	check(app.state.frontflow_worlds.size() == world_count + 1, "Duplicate world creates another local card")
	app.screen._rename_world()
	await settle()
	var rename_fields: Array[Node] = app.modal.find_children("*", "LineEdit", true, false)
	rename_fields[0].text = "QA WORLD"
	rename_fields[0].text_submitted.emit("QA WORLD")
	await settle()
	check(app.state.frontflow_worlds[app.state.frontflow_selected_world].name == "QA WORLD", "Rename updates selected world")
	app.screen._delete_world_confirmed()
	await settle()
	check(app.state.frontflow_worlds.size() == world_count, "Deleting a duplicate removes only that local world")
	app.navigate("join_friend")
	await settle()
	app.screen._submit_friend_code("bad code")
	check(app.current_route == "join_friend", "Invalid invitation stays on join screen")
	app.screen._submit_friend_code("ZK-4A91-KX")
	await settle()
	check(app.current_route == "session", "Valid mock invitation enters session")
	app.state["frontflow_worlds"] = []
	app.navigate("saves")
	await settle()
	check(app.state.frontflow_worlds.is_empty(), "An empty world list must not recreate deleted defaults")
	app.screen._create_world_confirmed("FRESH START")
	await settle()
	check(app.state.frontflow_worlds.size() == 1 and app.state.frontflow_worlds[0].name == "FRESH START", "Create world works from the empty state")
	print("UI_TEST_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
