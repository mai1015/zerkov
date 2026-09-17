extends "res://ui/screens/character/character_screen.gd"
## Live equipment behavior on the existing authored Character workspace.
## No authority or save capability is retained by a widget. Preview stays on
## the inherited fixture path; production never binds its sample gear labels.
const EquipmentGrid = preload("res://ui/screens/character/components/inventory_grid.gd")
const EQUIPMENT_BUTTONS := {
	&"zerkov.slot.weapon_primary": ["CharacterColumn/SlingSlot", "SlingDetail", "SlingIcon"],
	&"zerkov.slot.weapon_melee": ["CharacterColumn/LegStrapSlot", "LegStrapDetail", "LegStrapIcon"],
	&"zerkov.slot.rig": ["RigSwap", "", ""],
	&"zerkov.slot.backpack": ["PackSwap", "", ""]}
var _equipment_slots: Dictionary = {}
var _secure_grid: Control
var _secure_title: Label

func _equipment_controller() -> InventoryEquipmentController:
	return _inventory_controller as InventoryEquipmentController

func _bind_gear() -> void:
	if not _live_inventory_binding:
		super._bind_gear()
		return
	for names: Array in [["HeadSlot", "HeadDetail"], ["FaceSlot", "FaceDetail"],
		["ArmorSlot", "ArmorDetail"], ["HeadsetSlot", "HeadsetDetail"],
		["BackSlot", "BackDetail"], ["HolsterSlot", "HolsterDetail"]]:
		var button := _node("CharacterColumn/" + names[0]) as Button
		button.disabled = true
		button.tooltip_text = "Unavailable: this equipment slot is not part of the current loadout."
		(button.get_node(names[1]) as Label).text = "UNAVAILABLE"
		for icon: Node in button.find_children("*", "TextureRect", true, false): icon.hide()
	var hint := _node("CharacterColumn/GearHint") as Label
	hint.text = "LIVE EQUIPMENT · select an item, then activate a slot\nDrag to equip · activate equipped gear to unequip"
	hint.size.x = 480
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_refresh_equipment()

func _bind_loadout() -> void:
	super._bind_loadout()
	if not _live_inventory_binding: return
	# Keep the existing storage geometry. Root rig/backpack storage is separate
	# from named-slot gear and must not claim a fixture bag is equipped.
	for pair: Array in [["Rig", &"zerkov.slot.rig", "rig"], ["Pack", &"zerkov.slot.backpack", "backpack"]]:
		var swap := _node(pair[0] + "Swap") as Button
		var preview := Callable(self, "_swap_container").bind(pair[2])
		if swap.pressed.is_connected(preview): swap.pressed.disconnect(preview)
		(_node(pair[0] + "Title") as Label).text = pair[2].to_upper() + " STORAGE · LIVE"
		for icon: Node in _node(pair[0] + "Container").find_children("*", "TextureRect", true, false): icon.hide()
	if _secure_grid == null:
		var column := _node("CharacterColumn")
		_secure_title = Label.new()
		_secure_title.name = "SecureTitle"
		_secure_title.position = Vector2(0, 578)
		_secure_title.size = Vector2(480, 28)
		_secure_title.add_theme_font_size_override("font_size", 12)
		column.add_child(_secure_title)
		_secure_grid = EquipmentGrid.new()
		_secure_grid.name = "SecureGrid"
		_secure_grid.position = Vector2(0, 612)
		column.add_child(_secure_grid)
	var controller := _equipment_controller()
	var dimensions := controller.grid_size(&"secure") if controller != null else Vector2i.ZERO
	_secure_title.text = "SECURE CONTAINER · %d×%d · LIVE" % [dimensions.x, dimensions.y]
	_bind_grid(_secure_grid, dimensions.x, dimensions.y, "secure", "secure")
	_refresh_equipment()

func _refresh_equipment() -> void:
	var controller := _equipment_controller()
	_equipment_slots.clear()
	var available: bool = false
	if controller != null:
		var view := controller.equipment_view()
		available = bool(view.available) and controller.mutation_available(&"equipment")
		for row: Dictionary in view.slots: _equipment_slots[StringName(row.slot_id)] = row.item
	for slot_id: StringName in EQUIPMENT_BUTTONS:
		var names: Array = EQUIPMENT_BUTTONS[slot_id]
		var button := _node(names[0]) as Button
		if button == null: continue
		var item: Dictionary = _equipment_slots.get(slot_id, {})
		button.disabled = not available or not _equipment_slots.has(slot_id)
		button.tooltip_text = (String(item.get("name", "Empty slot")) + "\nSelect a loadout item then activate to equip.\nWithout a selection, activate to unequip to storage.") if available else "Equipment unavailable"
		var activate := _equipment_activate.bind(slot_id)
		if not button.pressed.is_connected(activate): button.pressed.connect(activate, CONNECT_DEFERRED)
		button.set_drag_forwarding(_equipment_drag.bind(slot_id, button),
			_equipment_can_drop.bind(slot_id), _equipment_drop.bind(slot_id))
		if not String(names[1]).is_empty():
			(button.get_node(names[1]) as Label).text = String(item.name) + " · EQUIPPED" if not item.is_empty() else "EMPTY · SELECT ITEM TO EQUIP"
		else:
			button.text = String(item.name) if not item.is_empty() else "EMPTY GEAR SLOT"
		if not String(names[2]).is_empty():
			var icon := button.get_node(names[2]) as TextureRect
			icon.texture = null
			icon.visible = not item.is_empty() and not bool(item.get("icon_placeholder", true))
			if icon.visible and ResourceLoader.exists(String(item.icon)): icon.texture = load(String(item.icon))

func _equipment_activate(slot_id: StringName) -> void:
	if not accepts_input() or not _live_inventory_binding: return
	var controller := _equipment_controller()
	if controller == null: return
	var result: Dictionary
	if not _selected_live_item.is_empty() and _selected_live_source != "equipment":
		result = controller.submit_equip(StringName(_selected_live_source), _selected_live_item, slot_id)
	else:
		var item: Dictionary = _equipment_slots.get(slot_id, {})
		if item.is_empty():
			_notify("Select an item in your loadout, then activate this slot.")
			return
		result = controller.submit_unequip(item)
	_equipment_result(result)

func _equipment_result(result: Dictionary) -> void:
	_handle_live_result(result, "equipment")
	if result.get("accepted", false):
		_selected_live_item = {}; _selected_live_source = ""
		_close_tip()
		_refresh_body()

func _equipment_drag(_position: Vector2, slot_id: StringName, button: Button) -> Variant:
	if not accepts_input() or button.disabled: return null
	var item: Dictionary = _equipment_slots.get(slot_id, {})
	if item.is_empty(): return null
	var preview := Label.new()
	preview.text = String(item.name)
	if button.get_viewport().gui_is_dragging(): button.set_drag_preview(preview)
	else: preview.free()
	return {"type":"inventory_item", "source":"equipment", "item":item.duplicate(true),
		"item_id":item.item_id, "binding_token":_active_binding_token, "split":false}

func _equipment_can_drop(_position: Vector2, data: Variant, slot_id: StringName) -> bool:
	# Accept well-shaped releases so invalid destinations still get an explicit
	# authoritative rejection. Hover does not promise compatibility or mutate.
	return accepts_input() and _equipment_slots.has(slot_id) and data is Dictionary \
		and data.get("type") == "inventory_item" and data.get("item") is Dictionary

func _equipment_drop(_position: Vector2, data: Variant, slot_id: StringName) -> void:
	if not _equipment_can_drop(_position, data, slot_id): return
	var item: Dictionary = data.item.duplicate(true)
	item["_binding_token"] = int(data.get("binding_token", 0))
	_submit_equipment_drop.call_deferred(item, StringName(data.get("source", "")), slot_id, bool(data.get("split", false)))

func _submit_equipment_drop(item: Dictionary, source: StringName, slot_id: StringName, split: bool) -> void:
	if not accepts_input() or _payload_is_stale(item): return
	if split:
		_notify("Equipment requires a whole item; split the stack in storage first.")
		return
	var controller := _equipment_controller()
	if controller != null: _equipment_result(controller.submit_equip(source, item, slot_id))
