extends SceneTree

var app: Control
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("RESPONSIVE_TEST: " + message)

func settle() -> void:
	await create_timer(0.22).timeout
	for frame in range(4):
		await process_frame

func resize_to(dimensions: Vector2i) -> void:
	root.size = dimensions
	await settle()

func run() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate()
	root.add_child(app)
	await settle()
	app.navigate("inventory", false)
	await settle()
	app.state["resize_test"] = "retained"
	var shell: Control = app.screen.get_node("InventoryContent")
	var search: LineEdit = app.screen.find_child("StashSearch", true, false)
	search.text = "ammo"
	search.text_changed.emit(search.text)
	search.caret_column = 2
	var history_size: int = app.history.size()
	check(ProjectSettings.get_setting("display/window/size/window_width_override") == 1600, "Play defaults to desktop preview width")
	check(ProjectSettings.get_setting("display/window/size/window_height_override") == 900, "Play defaults to desktop preview height")
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(960, 540), Vector2i(1440, 900), Vector2i(1280, 800), Vector2i(1279, 720), Vector2i(1280, 719), Vector2i(1920, 1080)]:
		var old_screen: Control = app.screen
		await resize_to(dimensions)
		check(app.current_route == "inventory", "Resize preserves current route")
		check(app.history.size() == history_size, "Resize does not add navigation history")
		check(app.state.get("resize_test") == "retained", "Resize preserves mock state")
		var desktop: bool = dimensions.x >= 1280 and dimensions.y >= 720
		var expected = Vector2(1920, 1080) if desktop else Vector2(dimensions)
		check(root.get_visible_rect().size.is_equal_approx(expected), "PC windows preserve reference canvas; tiny windows use native pixels")
		check(is_instance_valid(old_screen) and app.screen == old_screen, "Resize retains the screen instance")
		check(app.screen.get_node("InventoryContent") == shell, "Resize retains the authored shell")
		check(app.screen.find_child("StashSearch", true, false) == search, "Resize retains the input control")
		check(search.text == "ammo" and search.caret_column == 2, "Resize preserves search text and caret")
		if not desktop:
			check(app.screen.find_child("LoadoutScroll", true, false) != null, "Compact inventory owns scroll pane")
			var grids: Array = app.screen._grids
			check(grids[0].get_cell_size() == 74, "Inventory keeps 74px intrinsic cells")
		else:
			check(not app.screen.find_child("LoadoutScroll", true, false).is_visible_in_tree(), "Normal PC window displays the original multi-column inventory")
			check(not app.screen._adaptive_applied, "Normal PC window never enters compact reflow")

	await resize_to(Vector2i(1280, 720))
	var callback_screen: Control = app.screen
	var result = {"value": ""}
	callback_screen.app.prompt(
		"Resize-safe input", "Initial", func(value): result.value = value
	)
	await settle()
	var field: LineEdit = app.modal.find_children("*", "LineEdit", true, false)[0]
	field.text = "Kept while resizing"
	await resize_to(Vector2i(960, 540))
	check(is_instance_valid(callback_screen) and app.screen == callback_screen, "Open modal keeps callback owner alive during resize")
	check(field.text == "Kept while resizing", "Resize preserves open input value")
	check(root.get_visible_rect().encloses(app.modal.get_child(1).get_global_rect()), "Dialog remains within small viewport")
	field.text_submitted.emit(field.text)
	await settle()
	check(result.value == "Kept while resizing", "Dialog callback completes after resize")
	check(is_instance_valid(callback_screen) and app.screen == callback_screen and app.screen._adaptive_applied, "Deferred reflow retains the callback owner after dialog closes")
	check(app.current_route == "inventory", "Dialog reflow preserves route")

	app.toggle_picker()
	await settle()
	check(root.get_visible_rect().encloses(app.picker.get_global_rect()), "Catalog fits960 viewport")
	var list: ScrollContainer = app.picker.find_child("ScreenCatalog", true, false)
	check(list != null, "Catalog is scrollable")
	check(list.get_v_scroll_bar().max_value > list.get_v_scroll_bar().page, "Catalog has offscreen rows accessible by scrolling")
	var point: Vector2 = list.global_position + Vector2(200, 100)
	var motion = InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	await process_frame
	var wheel = InputEventMouseButton.new()
	wheel.position = point
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.factor = 4
	wheel.pressed = true
	root.push_input(wheel)
	await settle()
	check(list.scroll_vertical > 0, "Mouse wheel scrolls screen catalog")
	app.picker.selected.emit("showcase")
	await settle()
	check(app.picker == null and app.current_route == "showcase", "F1 catalog opens the responsive component study")
	app.toast("Resize-safe notification")
	await settle()
	check(root.get_visible_rect().encloses(app.toast_label.get_global_rect()), "Toast fits viewport")
	check(app.toast_label.position.y + app.toast_label.size.y <= root.size.y - 80, "Toast stays above pinned actions")
	check(app.toast_label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Toast never blocks input")
	var showcase: ScrollContainer = app.screen.find_child("ComponentStates", true, false)
	check(showcase != null and showcase.get_v_scroll_bar().max_value > showcase.get_v_scroll_bar().page, "Component showcase scrolls on small screen")
	print("RESPONSIVE_TEST_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
