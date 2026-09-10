extends SceneTree
## Native utility-screen state and input regression coverage.
## Run with: godot --headless --path . --script res://tests/utility_smoke.gd

var failures: int = 0
var checks: int = 0
var app: Control


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("UTILITY_TEST: " + message)


func settle() -> void:
	await process_frame
	await process_frame


func press_key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()


func press_mouse(button: MouseButton) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = Vector2(900, 500)
		event.global_position = event.position
		event.pressed = pressed
		root.push_input(event)
	await settle()


func utility_screen() -> Control:
	return app.screen


func run() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	app.qa_mode = true
	await settle()

	# Settings: values are live, apply is recorded, section revert restores only
	# the active section, and defaults also refresh flattened HUD keys.
	app.navigate("settings", false)
	await settle()
	var settings: Control = utility_screen()
	settings._set_setting("hud_scale", 117.0)
	check(float(app.state.get("hud_scale", 0.0)) == 117.0, "HUD scale mirrors to top-level app state")
	check(float(app.state.get("hud_settings", {}).get("hud_scale", 0.0)) == 117.0, "HUD scale mirrors into hud_settings")
	settings._settings_apply()
	check(bool(app.state.get("utility_settings_applied", false)), "Apply records settings state")
	settings._set_setting("hud_scale", 83.0)
	settings._settings_revert()
	await settle()
	check(float(app.state.get("hud_scale", 0.0)) == 100.0, "HUD section revert restores default scale")
	settings = utility_screen()
	settings._set_setting("hud_scale", 123.0)
	settings._settings_defaults()
	await settle()
	check(float(app.state.get("utility_settings", {}).get("hud_scale", 0.0)) == 100.0, "Defaults restore utility settings")
	check(float(app.state.get("hud_settings", {}).get("hud_scale", 0.0)) == 100.0, "Defaults restore mirrored HUD settings")

	# Maps: zoom, zone selection, and marker detail are all persistent local state.
	app.navigate("maps", false)
	await settle()
	var maps: Control = utility_screen()
	maps._map_zoom(20)
	await settle()
	check(int(app.state.get("utility_map_zoom", 0)) == 120, "Map zoom increments and persists")
	maps = utility_screen()
	maps._select_map_zone(2)
	await settle()
	check(int(app.state.get("utility_map_zone", -1)) == 2, "Map zone selection persists")
	maps = utility_screen()
	maps._select_map_marker("extract", 1)
	await settle()
	check(str(app.state.get("utility_map_marker", "")) == "extract:1", "Extract marker selection persists")

	# Tasks: tracking writes the HUD task id, progress can complete the local
	# objective set, and turn-in records a durable completed state.
	app.navigate("tasks", false)
	await settle()
	var tasks: Control = utility_screen()
	tasks._toggle_task_tracking("field_dressing")
	await settle()
	check(str(app.state.get("hud_tracked_task_id", "")) == "field_dressing", "Task tracking updates HUD task id")
	tasks = utility_screen()
	var supply: Dictionary = tasks._task_record("supply_run")
	check(not supply.is_empty(), "Supply run task record is available")
	check(not bool(tasks._task_complete(supply)), "Supply run starts incomplete")
	tasks._advance_objective("supply_run", 2)
	await settle()
	tasks = utility_screen()
	tasks._advance_objective("supply_run", 3)
	await settle()
	tasks = utility_screen()
	supply = tasks._task_record("supply_run")
	check(bool(tasks._task_complete(supply)), "Objective progress completes supply run")
	tasks._turn_in_task("supply_run")
	await settle()
	check(bool(app.state.get("utility_tasks_completed", {}).get("supply_run", false)), "Turn-in records completed task state")

	# Controls: the deliberate default V conflict is visible, keyboard and mouse
	# capture write bindings, duplicate conflicts are reported, and resolving a
	# pair allows saving.
	app.navigate("controls", false)
	await settle()
	var controls: Control = utility_screen()
	check(controls._conflict_pairs().size() == 1, "Default controls expose one deliberate conflict")
	check(controls._binding_conflicts("melee", "primary").has("push_to_talk"), "Conflict identifies duplicate action")
	controls._begin_capture("melee", "primary")
	await settle()
	await press_key(KEY_Q)
	controls = utility_screen()
	check(str(controls._binding_value("melee", "primary")) == "Q", "Keyboard capture assigns a key")
	check(controls._conflict_pairs().is_empty(), "Keyboard rebind clears the default conflict")
	controls._begin_capture("fire", "primary")
	await settle()
	await press_mouse(MOUSE_BUTTON_MIDDLE)
	controls = utility_screen()
	check(str(controls._binding_value("fire", "primary")) == "MMB", "Mouse capture assigns MMB")
	controls._begin_capture("push_to_talk", "primary")
	await settle()
	await press_mouse(MOUSE_BUTTON_LEFT)
	controls = utility_screen()
	check(str(controls._binding_value("push_to_talk", "primary")) == "LMB", "Mouse capture assigns LMB")
	controls._begin_capture("melee", "primary")
	await settle()
	await press_mouse(MOUSE_BUTTON_LEFT)
	controls = utility_screen()
	check(controls._binding_conflicts("melee", "primary").has("push_to_talk"), "Mouse rebind reports duplicate conflict")
	controls._resolve_conflict("melee", "push_to_talk", "primary")
	await settle()
	controls = utility_screen()
	check(str(controls._binding_value("push_to_talk", "primary")) == "—", "Conflict resolution clears the losing binding")
	check(controls._conflict_pairs().is_empty(), "Conflict resolution leaves no duplicate pairs")
	controls._save_controls()
	check(bool(app.state.get("utility_controls_saved", false)), "Controls save after conflicts resolve")

	print("UTILITY_TEST_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
