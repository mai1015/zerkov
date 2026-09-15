extends RefCounted
## Invoked by the workflow's exact-1080 temporary SceneTree driver.
## Observes the unmodified product scene. No route forcing, fixture provider,
## starter inventory, synthetic raid or gameplay dependency is injected.
var checks: int = 0
var failures: int = 0
var stages: Array[Dictionary] = []

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("NORMAL_LAUNCH_PROBE: " + label)

func settle(tree: SceneTree) -> void:
	for _index in range(12):
		await tree.process_frame
	await tree.create_timer(0.15).timeout

func key(tree: SceneTree, code: Key) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		tree.root.push_input(event)
	await settle(tree)

func click(tree: SceneTree, control: Control) -> void:
	var at := control.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.pressed = pressed
		tree.root.push_input(event)
	await settle(tree)

func observe(app: Control, label: String) -> Dictionary:
	var screen: Control = app.screen
	var texts: Array[String] = []
	if screen != null:
		for child: Node in screen.find_children("*", "Label", true, false):
			if child is Label and child.is_visible_in_tree():
				texts.append(child.text)
	var view: Variant = screen.app.presentation_view() if screen != null else null
	var record := {"step": label, "route": app.current_route,
		"qa_mode": app.qa_mode, "prototype_fixture_mode": app.prototype_fixture_mode,
		"fixture_provider_present": app.fixture_provider_for_test() != null,
		"locked": bool(screen.get("_production_state_locked")) if screen != null else true,
		"accepts_input": screen.accepts_input() if screen != null else false,
		"view_ready": view.is_ready() if view != null else false,
		"visible_labels": texts}
	stages.append(record)
	print("NORMAL_LAUNCH_STAGE ", JSON.stringify(record))
	return record

func run(tree: SceneTree) -> Dictionary:
	check(tree.root.size == Vector2i(1920, 1080), "exact window")
	check(tree.root.get_visible_rect().size == Vector2(1920, 1080), "exact viewport")
	var app := load("res://ui/main.tscn").instantiate() as Control
	app.name = "NormalLaunchFlowProbe"
	tree.root.add_child(app)
	await settle(tree)
	var boot := observe(app, "normal_boot")
	check(boot.route == "title", "default scene starts at title")
	check(not boot.qa_mode and not boot.prototype_fixture_mode, "production mode, not a preview")
	check(not boot.fixture_provider_present, "no fixture provider")
	await key(tree, KEY_ENTER)
	var menu := observe(app, "press_enter")
	check(menu.route == "main_menu", "real Enter dispatch reaches main menu")
	check(not menu.fixture_provider_present, "input did not enable fixtures")
	var blocked: bool = menu.locked or not menu.view_ready
	if blocked and menu.route == "main_menu":
		var return_button: Button = null
		for child: Node in app.screen.find_children("*", "Button", true, false):
			if child is Button and child.is_visible_in_tree() and child.text == "RETURN TO TITLE":
				return_button = child
				break
		check(return_button != null, "blocked menu offers a visible recovery action")
		if return_button != null:
			await click(tree, return_button)
			var returned := observe(app, "click_return_to_title")
			check(returned.route == "title", "actual mouse dispatch returns to title")
			await key(tree, KEY_ENTER)
			var repeated := observe(app, "press_enter_again")
			check(repeated.route == "main_menu" and repeated.locked, "re-entry reproduces the same blocker")
			check(not repeated.fixture_provider_present, "re-entry never substitutes fixtures")
	var report := {"checks": checks, "failures": failures,
		"completed_game_cycles": 0, "game_cycle_complete": false,
		"first_blocker": "main_menu_missing_authoritative_presentation" if blocked else "later_stages_not_exercised",
		"stages": stages, "scope": "normal product launch and real keyboard/mouse dispatch; no developer route forcing"}
	app.queue_free()
	await settle(tree)
	print("NORMAL_LAUNCH_PROBE_RESULT checks=", checks, " failures=", failures,
		" completed_game_cycles=0 game_cycle_complete=false")
	return report
