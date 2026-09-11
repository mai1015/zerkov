extends SceneTree
## DEFERRED / HISTORICAL SUITE: native compact frontflow regression.
## Do not invoke or regenerate smaller-window evidence until task 11.8 or a
## later approved display-support proposal explicitly reopens this suite.

var app: Control
var failures: int = 0
var checks: int = 0
var capture_dir: String = ""

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: compact_frontflow_smoke is historical; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("COMPACT_FRONTFLOW: " + message)

func settle() -> void:
	for i in range(5):
		await process_frame

func route(value: String) -> void:
	app.navigate(value, false)
	await settle()

func key(code: Key) -> void:
	for down in [true, false]:
		var event = InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		root.push_input(event)
	await settle()

func click(node: Control) -> void:
	check(node != null, "Requested action exists")
	if node == null: return
	var point: Vector2 = node.get_global_rect().get_center()
	check(Rect2(Vector2.ZERO, Vector2(root.size)).has_point(point), "Action is inside window: " + node.name)
	var motion = InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	for down in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = down
		root.push_input(event)
	await settle()

func button(prefix: String) -> Button:
	var nodes: Array[Node] = app.screen.find_children("*", "Button", true, false)
	nodes.reverse()
	for node in nodes:
		if node.is_visible_in_tree() and node.text.begins_with(prefix):
			return node
	return null

func wheel(pane_name: String) -> void:
	var pane: ScrollContainer = app.screen.find_child(pane_name, true, false)
	check(pane != null, "Scroll pane exists: " + pane_name)
	if pane == null: return
	var before: int = pane.scroll_vertical
	var point: Vector2 = pane.get_global_rect().get_center()
	for i in range(4):
		for down in [true, false]:
			var event = InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_WHEEL_DOWN
			event.position = point
			event.global_position = point
			event.pressed = down
			root.push_input(event)
	await settle()
	check(pane.scroll_vertical > before, "Mouse wheel moves " + pane_name)

func capture(label: String) -> void:
	if capture_dir.is_empty(): return
	if is_instance_valid(app.toast_label): app.toast_label.hide()
	await RenderingServer.frame_post_draw
	var path: String = capture_dir.path_join(str(root.size.x) + "_" + label + ".png")
	root.get_texture().get_image().save_png(path)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
	if not capture_dir.is_empty(): DirAccess.make_dir_recursive_absolute(capture_dir)
	root.size = Vector2i(1280, 720)
	app = load("res://ui/main.tscn").instantiate()
	app.ui_layout_mode = "compact"
	root.add_child(app)
	app.qa_mode = true
	await settle()
	for window_size in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = window_size
		await settle()
		await route("main_menu")
		check(app.screen.scale == Vector2.ONE, "Native screen scale")
		await capture("main_menu")
		await key(KEY_DOWN)
		await key(KEY_ENTER)
		check(app.current_route == "saves", "Arrow-key navigation survives menu reparenting")
		await route("main_menu")
		if window_size.y == 540: await wheel("MenuWorlds")
		await click(button("ENTER   CONTINUE"))
		check(app.current_route == "session", "Pinned continue navigates")
		await route("saves")
		await capture("saves")
		if window_size.y == 540: await wheel("WorldList")
		var count: int = app.screen._worlds().size()
		await click(button("DUPLICATE"))
		check(app.screen._worlds().size() == count + 1, "Duplicate world survives compact layout")
		await click(button("RENAME"))
		check(is_instance_valid(app.modal), "Rename remains reachable")
		var name_field: LineEdit = app.modal.find_children("*", "LineEdit", true, false)[0]
		name_field.text = "Compact renamed"
		var confirmation: Button = app.modal.find_children("*", "Button", true, false)[1]
		await click(confirmation)
		check(app.screen._selected_world_data().name == "COMPACT RENAMED", "Rename applies to selected world")
		await click(button("DELETE"))
		confirmation = app.modal.find_children("*", "Button", true, false)[1]
		await click(confirmation)
		check(app.screen._worlds().size() == count, "Confirmed delete removes selected world")
		await click(button("+ NEW WORLD"))
		check(app.screen.world_name_field.is_visible_in_tree(), "New world tab reveals editable form")
		await capture("new_world")
		await wheel("NewWorldForm")
		await capture("new_world_scrolled")
		app.screen.world_name_field.text = "Compact test"
		app.screen._world_name_changed("Compact test")
		await click(button("CREATE AND ENTER"))
		check(app.modal != null, "Pinned create opens confirmation")
		if is_instance_valid(app.modal): app._close_overlay(app.modal)
		app.screen._create_world_confirmed("Compact test")
		await settle()
		check(app.current_route == "session", "World creation enters session")
		await route("join_friend")
		await capture("join_friend")
		await wheel("FriendList")
		app.screen.friend_code_field.text = "invalid"
		await click(button("JOIN BY CODE"))
		check(not app.screen.friend_code_error.text.is_empty(), "Invalid code stays visible")
		await click(button("WORLD DETAILS"))
		await capture("friend_detail")
		await wheel("FriendDetail")
		await capture("friend_detail_scrolled")
		await click(button("ENTER   JOIN"))
		check(app.current_route == "session", "Pinned detail join navigates")
		app.state["frontflow_compact_join_friend"] = "friends"
		await route("join_friend")
		app.screen.friend_code_field.text = "zk-compact"
		await click(button("JOIN BY CODE"))
		check(app.current_route == "session" and app.state.get("frontflow_join_code") == "ZK-COMPACT", "Valid friend code normalizes and joins")
		await route("pause")
		await capture("pause")
		await click(button("FRIENDS"))
		check(app.state.get("bunker_privacy") == "FRIENDS", "Pause privacy updates")
		await route("deploying")
		await capture("deploying")
		await wheel("DeploymentBriefing")
		app.state["frontflow_compact_saves"] = "worlds"
		app.state["frontflow_compact_join_friend"] = "friends"
	# Empty worlds continue to expose creation, while destructive actions disable.
	app.state["frontflow_worlds"] = []
	await route("saves")
	check(button("DELETE").disabled, "Delete disabled for empty world list")
	await click(button("+ NEW WORLD"))
	check(app.screen.world_name_field.is_visible_in_tree(), "Empty list can create first world")
	await route("main_menu")
	await click(button("CREATE YOUR FIRST WORLD"))
	check(app.screen.world_name_field.is_visible_in_tree(), "Empty-world Continue opens form directly")
	print("COMPACT_FRONTFLOW_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
