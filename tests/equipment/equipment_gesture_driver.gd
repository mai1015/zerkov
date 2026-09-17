extends RefCounted
## Exercises Godot's drag manager and native Button activation. No forced drag
## payloads, direct controller submissions, or canonical mutations are used.
var driver: RefCounted
var _drop_events: Array[Dictionary] = []

func run(value: RefCounted) -> bool:
	driver = value
	var sling := driver.named("InventoryContent/CharacterColumn/SlingSlot") as Button
	var grid: Control = driver.game._ui.screen.call("_grid_for_source", "backpack")
	var id: int = driver.gear(driver.PRIMARY).item_id
	if not await drag(sling, grid.get_global_rect().position + Vector2(37, 37)): return false
	if not driver.check(driver.gear(driver.PRIMARY).is_empty(), "real drag unequips primary to storage"): return false
	var item: Control = driver.item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM))
	if not driver.check(item != null and item.get("item").item_id == id, "drag keeps the same native item"): return false
	if not await drag(item, sling.get_global_rect().get_center()): return false
	if not driver.check(driver.gear(driver.PRIMARY).get("item_id") == id, "real drag equips storage item"): return false
	await driver.linger("Drag equipment to storage and back")
	if not await activate(sling): return false
	if not driver.check(driver.gear(driver.PRIMARY).is_empty(), "keyboard activation unequips primary"): return false
	item = driver.item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM))
	if not await activate(item) or not await activate(sling): return false
	if not driver.check(driver.gear(driver.PRIMARY).get("item_id") == id, "keyboard selects and equips the same item"): return false
	await driver.linger("Keyboard selection and equipment activation")
	var splint: Control = driver.item_slot("secure", String(ZerkovInventoryCatalog.ITEM_SPLINT))
	var splint_id: int = splint.get("item").item_id
	var pockets: Control = driver.game._ui.screen.call("_grid_for_source", "pockets")
	if not await drag(splint, pockets.get_global_rect().position + Vector2(185, 37)): return false
	if not driver.check(driver.item_slot("secure", String(ZerkovInventoryCatalog.ITEM_SPLINT)) == null, "secure item actually leaves its container"): return false
	splint = driver.item_slot("pockets", String(ZerkovInventoryCatalog.ITEM_SPLINT))
	if not driver.check(splint != null and splint.get("item").item_id == splint_id, "secure transfer retains item identity"): return false
	var secure: Control = driver.game._ui.screen.call("_grid_for_source", "secure")
	if not await drag(splint, secure.get_global_rect().position + Vector2(37, 37)): return false
	splint = driver.item_slot("secure", String(ZerkovInventoryCatalog.ITEM_SPLINT))
	if not driver.check(splint != null and splint.get("item").quantity == 2 and splint.get("item").item_id == splint_id, "secure transfer conserves identity and quantity"): return false
	await driver.linger("Secure-container contents move through inventory intents")
	return true

func activate(control: Control) -> bool:
	if not driver.check(control != null and control.is_visible_in_tree(), "keyboard target exists"): return false
	control.grab_focus()
	await driver.process_frame
	if not driver.check(driver.root.gui_get_focus_owner() == control, "native equipment control accepts keyboard focus"): return false
	await driver.key(KEY_SPACE)
	return driver.failures == 0

func drag(source: Control, destination: Vector2) -> bool:
	if not driver.check(source != null and source.is_visible_in_tree(), "drag source visible"): return false
	_drop_events.clear()
	var observed: Array[Control] = []
	for grid: Control in driver.game._ui.screen.get("_grids"):
		grid.drop_rejected.connect(_observe_drop.bind(grid, false))
		grid.item_dropped.connect(_observe_drop.bind(grid, true))
		grid.set_drag_forwarding(Callable(), _observe_can.bind(grid), _observe_release.bind(grid))
		observed.append(grid)
	var start := source.get_global_rect().get_center()
	motion(start, Vector2.ZERO, false)
	await driver.process_frame
	button(start, true)
	await driver.process_frame
	var previous := start
	for index in range(1, 17):
		var point := start.lerp(destination, float(index) / 16.0)
		motion(point, point - previous, true)
		previous = point
		await driver.process_frame
	var started: bool = driver.root.gui_is_dragging()
	button(destination, false)
	await driver.settle()
	for grid: Control in observed:
		if not is_instance_valid(grid): continue
		grid.drop_rejected.disconnect(_observe_drop.bind(grid, false))
		grid.item_dropped.disconnect(_observe_drop.bind(grid, true))
		grid.set_drag_forwarding(Callable(), Callable(), Callable())
	print("EQUIPMENT_DRAG_TRACE start=", start, " destination=", destination,
		" events=", _drop_events)
	return driver.check(started and not driver.root.gui_is_dragging(), "native drag starts and completes without forced payload")

func motion(point: Vector2, relative: Vector2, held: bool) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point; event.global_position = point; event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	if driver.cursor != null: driver.cursor.position = point

func button(point: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point; event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _observe_drop(item: Dictionary, source_key: String, cell: Vector2i, grid: Control, admitted: bool) -> void:
	_drop_events.append({"source": source_key, "target": grid.source_id,
		"cell": cell, "admitted": admitted, "enabled": grid.mutation_enabled,
		"grid_rect": grid.get_global_rect(), "grid_transform": grid.get_global_transform_with_canvas(),
		"size_cells": Vector2i(grid.grid_columns, grid.grid_rows),
		"item_id": item.get("item_id", 0), "item_size": Vector2i(item.get("w", 0), item.get("h", 0)),
		"occupancy": grid.occupancy_items, "viewport_mouse": grid.get_viewport().get_mouse_position()})

func _observe_can(point: Vector2, data: Variant, grid: Control) -> bool:
	return grid.call("_can_drop_data", point, data)

func _observe_release(point: Vector2, data: Variant, grid: Control) -> void:
	print("EQUIPMENT_RELEASE_COORDINATES local_argument=", point,
		" live_local_mouse=", grid.get_local_mouse_position(),
		" viewport_mouse=", grid.get_viewport().get_mouse_position(),
		" global_transform=", grid.get_global_transform_with_canvas(),
		" local_transform=", grid.get_transform(), " parent=", grid.get_parent().get_path(),
		" native_hover=", grid.get_viewport().gui_get_hovered_control())
	grid.call("_drop_data", point, data)
