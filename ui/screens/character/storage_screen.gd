extends "res://ui/screens/character/equipment_screen.gd"
## Existing equipment widgets, one carried-storage scroller, original Quick Use.
## Unworn gear has no grid, even when a legacy save needs item recovery.
var _storage_scroll: ScrollContainer
var _storage_content: Control
var _recovery_buttons: Dictionary = {}
var _recovery_items: Dictionary = {}

func _bind_content() -> void:
	super._bind_content()
	_arrange_storage()

func _apply_adaptive_layout() -> void:
	super._apply_adaptive_layout()
	_arrange_storage()

func _apply_queued_compact_reflow() -> void:
	super._apply_queued_compact_reflow()
	_arrange_storage()

func _bind_grid(grid: Control, columns: int, rows: int, source: String, data: String) -> void:
	if _live_inventory_binding and _inventory_controller is LocalInventoryController and source in ["rig", "backpack", "secure"]:
		var guard := _guard_grid.bind(grid, StringName(source))
		if not grid.visibility_changed.is_connected(guard): grid.visibility_changed.connect(guard)
		if _inventory_controller.grid_size(StringName(source)) == Vector2i.ZERO:
			grid.set_items([], [])
			grid.set_mutation_enabled(false)
			grid.set_operation_availability(false, false)
			grid.hide()
			return
	super._bind_grid(grid, columns, rows, source, data)

func _guard_grid(grid: Control, source: StringName) -> void:
	# Reflow must not resurrect old cells after binding hid them. Also guards a
	# legacy-content grid: recovery rows are not replacement storage capacity.
	if is_instance_valid(_inventory_controller) and _inventory_controller is LocalInventoryController \
		and not _inventory_controller.storage_state(source).equipped and grid.visible:
		grid.hide()

func _arrange_storage() -> void:
	if not _live_inventory_binding or not _inventory_controller is LocalInventoryController or _surface == null: return
	AuthoredQuickUse.pin_character(self)
	for entry: Array in [["RigGrid", &"rig"], ["PackGrid", &"backpack"], ["SecureGrid", &"secure"]]: _guard_grid(_node(entry[0]), entry[1])
	# Safety holds at every size; the approved full-column composition remains
	# exact 1920x1080, not a new compact/responsive acceptance claim.
	if get_viewport_rect().size != Vector2(1920, 1080): return
	if _storage_scroll == null:
		_storage_scroll = ScrollContainer.new()
		_storage_scroll.name = "StorageScroll"
		_storage_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_storage_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		_storage_scroll.follow_focus = true
		_surface.add_child(_storage_scroll)
		_storage_content = Control.new()
		_storage_content.name = "StorageContent"
		_storage_content.mouse_filter = Control.MOUSE_FILTER_PASS
		_storage_scroll.add_child(_storage_content)
	_storage_scroll.position = Vector2(568, 188)
	_storage_scroll.size = Vector2(640, 748)
	_storage_scroll.show()
	for path: String in ["DesktopPocketsScroll", "DesktopRigScroll", "DesktopPackScroll"]:
		var old := _node(path)
		if old != null: old.hide()
	var active_recovery: Dictionary = {}
	var cursor := 0.0
	_place_storage(_node("PocketsTitle"), Rect2(0, cursor, 620, 26))
	cursor += 32
	var pockets := _node("PocketsGrid")
	_place_storage(pockets, Rect2(Vector2(0, cursor), pockets.custom_minimum_size))
	cursor += pockets.custom_minimum_size.y + 24
	for entry: Array in [["Rig", &"rig", "RIG"], ["Pack", &"backpack", "BACKPACK"]]:
		var prefix: String = entry[0]
		var source: StringName = entry[1]
		var storage: Dictionary = _inventory_controller.storage_state(source)
		var title := _node(prefix + "Title") as Label
		var icon := _node(prefix + "Container") as Button
		var action := _node(prefix + "Swap") as Button
		_place_storage(icon, Rect2(0, cursor, 66, 66))
		_place_storage(title, Rect2(86, cursor, 534, 26))
		_place_storage(action, Rect2(86, cursor + 30, 534, 36))
		title.text = entry[2]
		title.clip_text = true
		icon.disabled = true
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		action.text = String(_equipment_slots.get(WearableStoragePolicy.PROVIDERS[String(source)].slot, {}).get("name", "EMPTY · EQUIP " + String(entry[2])))
		LocalJourneyStyle.button(action)
		cursor += 78
		var grid := _node(prefix + "Grid")
		if storage.equipped:
			title.text += " · %d × %d" % [storage.size.x, storage.size.y]
			_place_storage(grid, Rect2(Vector2(0, cursor), grid.custom_minimum_size))
			cursor += grid.custom_minimum_size.y + 24
		else:
			grid.hide()
			for item: Dictionary in _inventory_controller.items_for(source):
				var key := "%s:%d" % [source, item.item_id]
				active_recovery[key] = true
				_recovery_items[key] = item.duplicate(true)
				var recover := _recovery_buttons.get(key) as Button
				if recover == null:
					recover = Button.new()
					recover.name = prefix + "Recovery_" + str(item.item_id)
					_storage_content.add_child(recover)
					recover.pressed.connect(_capture_recovery.bind(source, key))
					_recovery_buttons[key] = recover
				recover.text = "RECOVER %s ×%d TO STORAGE" % [String(item.name).to_upper(), int(item.quantity)]
				recover.tooltip_text = "Saved item without its gear. Move it to pockets or equipped storage. If full, make room or equip the matching gear."
				recover.disabled = not _inventory_controller.mutation_available(source)
				LocalJourneyStyle.button(recover)
				_place_storage(recover, Rect2(0, cursor, 620, 36))
				cursor += 44
	if _secure_grid != null and _secure_swap != null:
		var secure: Dictionary = _inventory_controller.storage_state(&"secure")
		_place_storage(_secure_title, Rect2(0, cursor, 620, 26))
		_secure_title.text = "SECURE CONTAINER"
		cursor += 32
		_place_storage(_secure_swap, Rect2(0, cursor, 620, 36))
		_secure_swap.text = String(_equipment_slots.get(WearableStoragePolicy.PROVIDERS["secure"].slot, {}).get("name", "EMPTY · EQUIP SECURE CONTAINER"))
		LocalJourneyStyle.button(_secure_swap)
		cursor += 44
		if secure.equipped:
			_secure_title.text += " · %d × %d" % [secure.size.x, secure.size.y]
			_place_storage(_secure_grid, Rect2(Vector2(0, cursor), _secure_grid.custom_minimum_size))
			cursor += _secure_grid.custom_minimum_size.y + 18
		else:
			_secure_grid.hide()
			for item: Dictionary in _inventory_controller.items_for(&"secure"):
				var key := "secure:%d" % int(item.item_id)
				active_recovery[key] = true
				_recovery_items[key] = item.duplicate(true)
				var recover := _recovery_buttons.get(key) as Button
				if recover == null:
					recover = Button.new()
					recover.name = "SecureRecovery_" + str(item.item_id)
					_storage_content.add_child(recover)
					recover.pressed.connect(_capture_recovery.bind(&"secure", key))
					_recovery_buttons[key] = recover
				recover.text = "RECOVER %s ×%d TO STORAGE" % [String(item.name).to_upper(), int(item.quantity)]
				recover.tooltip_text = "Saved secure item without its container. Move it to ordinary carried storage before equipping another secure container."
				recover.disabled = not _inventory_controller.mutation_available(&"secure")
				LocalJourneyStyle.button(recover)
				_place_storage(recover, Rect2(0, cursor, 620, 36))
				cursor += 44
	for key: String in _recovery_buttons.keys():
		if active_recovery.has(key): continue
		var old: Button = _recovery_buttons[key]
		if old.has_focus(): (_node("RigSwap") as Button).grab_focus()
		old.hide(); old.queue_free()
		_recovery_buttons.erase(key); _recovery_items.erase(key)
	_storage_content.custom_minimum_size = Vector2(620, cursor)
	_storage_content.size = _storage_content.custom_minimum_size
	var character := _node("CharacterColumn")
	character.position.y = 188 + (748 - 602) * 0.5
	character.size.y = 602
	character.visible = _tab_name() == "gear"
	var hint := _node("CharacterColumn/GearHint") as Label
	hint.position.y = 556
	hint.size = Vector2(480, 44)
	hint.text = "Drag to equip · select equipped gear to remove\nStorage must have space for the removed item."
	var loot_scroll := _node("DesktopStashScroll") as ScrollContainer
	loot_scroll.size.y = 700

func _capture_recovery(source: StringName, key: String) -> void:
	if not accepts_input() or not _recovery_items.has(key): return
	_recover_unassigned.call_deferred(source, _recovery_items[key].duplicate(true))

func _recover_unassigned(source: StringName, item: Dictionary) -> void:
	if not accepts_input() or not _inventory_controller is LocalInventoryController: return
	var result := (_inventory_controller as LocalInventoryController).recover_unassigned(source, item)
	_handle_live_result(result, String(source))
	_refresh_body()

func _place_storage(node: Control, rect: Rect2) -> void:
	if node.get_parent() != _storage_content: node.reparent(_storage_content, false)
	node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	node.position = rect.position
	node.size = rect.size
	node.mouse_force_pass_scroll_events = true
	node.show()
