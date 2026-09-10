extends SceneTree
## --headless --script res://tests/compact_raid_smoke.gd
## Omit --headless and add -- --capture-dir=/absolute/path for visual evidence.

var app: Control
var checks = 0
var failures = 0
var capture_dir = ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			capture_dir = arg.trim_prefix("--capture-dir=")
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("COMPACT_RAID_TEST " + message)

func settle() -> void:
	for i in range(4):
		await process_frame

func press_key(code: Key) -> void:
	for pressed in [true, false]:
		var event = InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()

func label_named(value: String) -> Label:
	for node in app.screen.find_children("*", "Label", true, false):
		if node.text == value:
			return node
	return null

func capture(suffix: String) -> void:
	if capture_dir.is_empty():
		return
	if is_instance_valid(app.toast_label):
		app.toast_label.hide()
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(capture_dir)
	root.get_texture().get_image().save_png(capture_dir.path_join("%d_%s.png" % [root.size.x, suffix]))

func run() -> void:
	app = load("res://ui/main.tscn").instantiate()
	app.ui_layout_mode = "compact"
	root.add_child(app)
	app.qa_mode = true
	await settle()
	for view in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = view
		await create_timer(0.2).timeout
		await settle()
		check(root.content_scale_size == view, "Main uses actual compact canvas dimensions")
		for route in ["hud", "hud_coop"]:
			app.state.hud_scale = 100.0
			app.state.hud_safe_zone = 56.0
			app.state.raid_ammo = 24
			app.state.raid_low_health = true
			app.navigate(route, false)
			await settle()
			check(app.screen.find_children("*", "ScrollContainer", true, false).is_empty(), route + " never scrolls")
			check(app.screen._crosshair.get_global_rect().get_center().is_equal_approx(Vector2(view) * 0.5), route + " crosshair stays centered")
			var ammo = label_named("24")
			check(ammo != null and ammo.get_theme_font_size("font_size") == 60, "Ammo retains native readable font size")
			for label in app.screen.find_children("*", "Label", true, false):
				check(Rect2(Vector2.ZERO, Vector2(view)).grow(1).encloses(label.get_global_rect()), "%s label stays in viewport: %s %s" % [route, label.text, label.get_global_rect()])
			await capture(route)
			await press_key(KEY_Y)
			check(not app.state.raid_low_health and label_named("BLEEDING") == null, "Compact quick heal clears damaged state")
			await press_key(KEY_R)
			check(app.screen._ring_nodes.size() == 1 and label_named("--") != null, "Compact reload shows ring and ammo state")
			await create_timer(2.6).timeout
			check(app.state.raid_ammo == 30 and app.screen._ring_nodes.is_empty(), "Compact reload completes")
			await press_key(KEY_X)
			check(app.current_route == ("summary_squad" if route == "hud_coop" else "summary_solo"), "Compact extraction chooses correct summary")
		app.state.hud_scale = 120.0
		app.state.hud_safe_zone = 80.0
		app.state.raid_low_health = true
		app.navigate("hud_coop", false)
		await settle()
		var vitals = app.screen._fade_groups[0]
		check(vitals.scale.is_equal_approx(Vector2(1.2, 1.2)), "Compact HUD respects scale preference")
		check((vitals.position + vitals.pivot_offset).is_equal_approx(Vector2(48, view.y - 48)), "Compact safe zone anchors vitals")
		for route in ["hud_detail", "status_icons", "squad_list", "reload", "mag_empty"]:
			app.navigate(route, false)
			await settle()
			var detail = app.screen.get_node("RaidDetail")
			check(Rect2(Vector2.ZERO, Vector2(view)).encloses(detail.get_global_rect()), route + " plate viewport stays visible")
			check(detail.get_node("Content").scale == Vector2.ONE, route + " detail stays at native scale")
			await capture(route)
		for route in ["summary_solo", "summary_squad"]:
			app.navigate(route, false)
			await settle()
			var count = 3 if route == "summary_squad" else 4
			for tab_index in range(count):
				app.screen.get_node("RaidSummaryTab%d" % tab_index).pressed.emit()
				await settle()
				var pane = app.screen.get_node("RaidSummary%d" % tab_index)
				check(pane.visible and pane.follow_focus, "Summary tab exposes a focus-following scroll pane")
				check(not pane.get_h_scroll_bar().visible, "Summary needs no horizontal scrolling")
				for item_image in pane.get_node("Content").find_children("*", "TextureRect", true, false):
					check(item_image.size.x <= 40 and item_image.size.y <= 40, "Summary item art retains its icon dimensions: %s %s" % [item_image.texture.resource_path, item_image.size])
				if tab_index == 0:
					check(pane.get_v_scroll_bar().visible, "Long summary content scrolls vertically")
					pane.scroll_vertical = 400
					await settle()
					check(pane.scroll_vertical > 0, "Summary scroll reaches additional content")
					pane.scroll_vertical = 0
				for button in app.screen.get_children():
					if button is Button:
						check(Rect2(Vector2.ZERO, Vector2(view)).encloses(button.get_global_rect()), "Summary action remains visible: " + button.text)
				await capture(route + "_" + str(tab_index))
			await press_key(KEY_ENTER)
			if route == "summary_squad":
				check(app.screen._squad_countdown.text.contains("3 / 3"), "Compact squad readiness updates")
				await create_timer(1.4).timeout
			check(app.current_route == "bunker", "Compact summary primary action returns to bunker")
	print("COMPACT_RAID_TEST_COMPLETE checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
