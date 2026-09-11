extends SceneTree
## Run with: godot --headless --path . --script res://tests/zerkov_screen_lifecycle_contract.gd

const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)

var failures: int = 0
var checks: int = 0
var app: Control


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("ZERKOV_SCREEN_LIFECYCLE: " + message)


func settle() -> void:
	for _frame in range(6):
		await process_frame


func geometry_snapshot(owner: Control) -> Array[String]:
	var snapshot: Array[String] = []
	_append_geometry(owner, owner, snapshot)
	return snapshot


func _append_geometry(owner: Control, node: Node, snapshot: Array[String]) -> void:
	var control := node as Control
	if control != null:
		var path := "." if control == owner else str(owner.get_path_to(control))
		snapshot.append("%s|anchors=%s|offsets=%s|position=%s|size=%s|minimum=%s|scale=%s|rotation=%s|pivot=%s" % [
			path,
			Vector4(control.anchor_left, control.anchor_top, control.anchor_right, control.anchor_bottom),
			Vector4(control.offset_left, control.offset_top, control.offset_right, control.offset_bottom),
			control.position,
			control.size,
			control.custom_minimum_size,
			control.scale,
			control.rotation,
			control.pivot_offset,
		])
	for child in node.get_children():
		_append_geometry(owner, child, snapshot)


func back_registration_count(runtime: CommonUIRuntime, screen: CommonActivatableScreen) -> int:
	var count := 0
	for action in runtime.get_active_actions():
		if action.get("action") == CommonUIDefaults.BACK and action.get("screen") == screen:
			count += 1
	return count


func exercise_resolution(view_size: Vector2i, runtime: CommonUIRuntime) -> Dictionary:
	var label := "%dx%d" % [view_size.x, view_size.y]
	var actions_before := runtime.get_active_actions().size()
	root.size = view_size
	app = load("res://ui/main.tscn").instantiate() as Control
	check(app != null, "main scene instantiates [" + label + "]")
	if app == null:
		return {"label": label, "controls": 0, "hash": ""}

	app.initial_route = "main_menu"
	root.add_child(app)
	app.qa_mode = true
	await settle()

	var menu_layer := app.common_ui_root.menu_layer() as CommonUILayer
	var shared_screen := app.screen as ZScreen
	check(menu_layer != null, "menu layer is available [" + label + "]")
	check(shared_screen != null, "main menu resolves to ZScreen [" + label + "]")
	if menu_layer == null or shared_screen == null:
		app.queue_free()
		await settle()
		app = null
		return {"label": label, "controls": 0, "hash": ""}

	check(menu_layer.get_top_screen() == shared_screen, "shared screen owns the layer top [" + label + "]")
	check(shared_screen.state == CommonActivatableScreen.State.ACTIVE,
		"shared screen reaches ACTIVE [" + label + "]")
	check(shared_screen.is_routing_active(), "shared screen is routing-active [" + label + "]")
	check(shared_screen.process_mode == Node.PROCESS_MODE_INHERIT,
		"active shared screen processing is enabled [" + label + "]")
	check(shared_screen.screen_context == &"screen/main_menu",
		"shared screen owns a stable route context [" + label + "]")
	check(shared_screen.context_priority == CommonUIDefaults.PRIORITY_MENU,
		"shared menu screen uses menu context priority [" + label + "]")
	var active_context := shared_screen.get_context_handle()
	check(active_context != null and active_context.is_active() and not active_context.is_suspended(),
		"active shared screen owns an unsuspended CommonUI context [" + label + "]")
	check(back_registration_count(runtime, shared_screen) == 1,
		"active shared screen registers one screen-scoped Back action [" + label + "]")

	var lifecycle_counts := {"activated": 0, "deactivated": 0}
	shared_screen.activated.connect(func() -> void: lifecycle_counts.activated += 1)
	shared_screen.deactivated.connect(func() -> void: lifecycle_counts.deactivated += 1)
	var before_geometry := geometry_snapshot(shared_screen)

	app.navigate("saves")
	await settle()
	var covering_screen := app.screen as ZScreen
	check(covering_screen != null and covering_screen != shared_screen,
		"pushing a route installs a covering shared screen [" + label + "]")
	check(menu_layer.get_depth() == 2,
		"covering route retains the prior screen in the stack [" + label + "]")
	check(shared_screen.state == CommonActivatableScreen.State.INACTIVE,
		"covered shared screen reaches INACTIVE [" + label + "]")
	check(not shared_screen.is_routing_active(),
		"covered shared screen is not routing-active [" + label + "]")
	check(shared_screen.process_mode == Node.PROCESS_MODE_DISABLED,
		"covered shared screen processing is disabled [" + label + "]")
	check(shared_screen.get_context_handle() == null,
		"covered shared screen releases its CommonUI context [" + label + "]")
	check(back_registration_count(runtime, shared_screen) == 0,
		"covered shared screen releases its Back action [" + label + "]")
	check(int(lifecycle_counts.deactivated) == 1,
		"covering emits exactly one shared-screen deactivation [" + label + "]")
	check(geometry_snapshot(shared_screen) == before_geometry,
		"covering does not change shared-screen layout geometry [" + label + "]")

	app.back()
	await settle()
	check(app.screen == shared_screen,
		"pop restores the retained shared screen instance [" + label + "]")
	check(menu_layer.get_top_screen() == shared_screen and menu_layer.get_depth() == 1,
		"restored shared screen owns the only menu stack entry [" + label + "]")
	check(shared_screen.state == CommonActivatableScreen.State.ACTIVE,
		"restored shared screen returns to ACTIVE [" + label + "]")
	check(shared_screen.is_routing_active(),
		"restored shared screen is routing-active [" + label + "]")
	check(shared_screen.process_mode == Node.PROCESS_MODE_INHERIT,
		"restored shared screen processing is enabled [" + label + "]")
	var restored_context := shared_screen.get_context_handle()
	check(restored_context != null and restored_context.is_active() and not restored_context.is_suspended(),
		"restored shared screen reacquires an unsuspended CommonUI context [" + label + "]")
	check(back_registration_count(runtime, shared_screen) == 1,
		"restored shared screen reacquires exactly one Back action [" + label + "]")
	check(int(lifecycle_counts.activated) == 1,
		"restoring emits exactly one shared-screen activation [" + label + "]")
	var restored_geometry := geometry_snapshot(shared_screen)
	check(restored_geometry == before_geometry,
		"reactivation preserves every descendant Control geometry property [" + label + "]")
	check(not is_instance_valid(covering_screen), "popped covering screen is released [" + label + "]")

	var geometry_text := "\n".join(PackedStringArray(restored_geometry))
	var result := {
		"label": label,
		"controls": restored_geometry.size(),
		"hash": geometry_text.sha256_text(),
	}
	app.queue_free()
	await settle()
	app = null
	check(runtime.get_active_actions().size() == actions_before,
		"app teardown releases shared-screen actions [" + label + "]")
	return result


func run() -> void:
	var route_count := 0
	for route in ZRouteCatalog.ROUTES:
		route_count += 1
		var scene := ZRouteCatalog.scene_for(route)
		check(scene != null, "registered route resolves a scene: " + str(route))
		if scene == null:
			continue
		var instance := scene.instantiate()
		check(instance is ZScreen, "registered route uses the shared ZScreen base: " + str(route))
		check(instance is CommonActivatableScreen,
			"registered route participates in CommonActivatableScreen: " + str(route))
		instance.free()

	var runtime := get_root().get_node_or_null("CommonUI") as CommonUIRuntime
	check(runtime != null, "native CommonUI runtime is available")
	if runtime == null:
		print("ZERKOV_SCREEN_LIFECYCLE_RESULT checks=", checks, " failures=", failures,
			" routes=", route_count, " geometry_controls=0 geometry_sha256=")
		quit(1)
		return

	var geometry_records: Array[String] = []
	var geometry_controls := 0
	for view_size in [FIRST_PLAYABLE_SIZE]:
		var result: Dictionary = await exercise_resolution(view_size, runtime)
		geometry_controls += int(result.controls)
		geometry_records.append("%s:%s" % [result.label, result.hash])

	var geometry_text := "\n".join(PackedStringArray(geometry_records))
	print("ZERKOV_SCREEN_LIFECYCLE_RESULT checks=", checks, " failures=", failures,
		" routes=", route_count, " geometry_controls=", geometry_controls,
		" geometry_sha256=", geometry_text.sha256_text(),
		" geometry_by_resolution=", ",".join(PackedStringArray(geometry_records)))
	quit(0 if failures == 0 else 1)
