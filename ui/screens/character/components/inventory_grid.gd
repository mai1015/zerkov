extends Control
## A small, native Control inventory grid used by the character screens.
##
## The grid deliberately owns only presentation and pointer/drag semantics.  The
## screen that owns it keeps the actual item arrays in app.state and decides what
## a move means.  This keeps the mock easy to navigate without introducing game
## or economy logic.

signal item_hovered(item: Dictionary, hovering: bool)
signal item_selected(item: Dictionary)
signal context_requested(item: Dictionary)
signal quick_moved(item: Dictionary, source_id: String)
signal split_requested(item: Dictionary, source_id: String, destination: Vector2i)
signal item_dropped(item: Dictionary, source_id: String, destination: Vector2i)
signal drop_rejected(item: Dictionary, source_id: String, destination: Vector2i)

const CELL: int = 74
const PixelStyle = preload("res://ui/theme/pixel_style.gd")
const GRID_BG := Color(0.027, 0.035, 0.031, 0.78)
const GRID_LINE := Color(0.90, 0.92, 0.89, 0.10)
const SLOT_BG := Color(0.12, 0.14, 0.13, 0.70)
const SLOT_BORDER := Color(0.80, 0.84, 0.80, 0.22)
const TEXT := Color(0.90, 0.91, 0.89, 1.0)
const MUTED := Color(0.55, 0.57, 0.54, 1.0)
const GREEN := Color(0.37, 0.83, 0.42, 1.0)
const ORANGE := Color(0.91, 0.59, 0.18, 1.0)
const RED := Color(0.85, 0.28, 0.23, 1.0)

var cell_size: int = CELL
var grid_columns: int = 1
var grid_rows: int = 1
var source_id: String = "stash"
var inventory_id: int = 0
var container_id: int = 0
var scope: StringName = &""
var owner_generation: int = 0
var scope_generation: int = 0
var binding_token: int = 0
var mutation_enabled: bool = true
var quick_transfer_enabled: bool = true
var split_enabled: bool = true
var items: Array = []
var occupancy_items: Array = []
var compatibility_key: String = ""
var selected_id: String = ""

var _slots: Array = []
var _rebuild_active := false
var _rebuild_queued := false
var _hovered_key := ""


class ItemSlot extends Button:
	const SLOT_TEXT := Color(0.90, 0.91, 0.89, 1.0)
	const SLOT_MUTED := Color(0.55, 0.57, 0.54, 1.0)
	const SLOT_PLACEHOLDER := Color(0.91, 0.59, 0.18, 1.0)
	var owner_grid: Control
	var item: Dictionary
	var _icon: TextureRect
	var _count: Label
	var _tag: Label
	var _ctrl_press_active := false
	var _ctrl_drag_started := false

	func configure(grid: Control, value: Dictionary) -> void:
		owner_grid = grid
		if item == value:
			return
		item = value.duplicate(true)
		flat = true
		text = ""
		focus_mode = Control.FOCUS_ALL
		# Let wheel/trackpad events reach the enclosing native scroll pane.
		mouse_force_pass_scroll_events = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_refresh_interaction_hint()
		for child in get_children():
			remove_child(child)
			child.queue_free()
		_build_content()
		_apply_style()

	func _build_content() -> void:
		_icon = TextureRect.new()
		_icon.name = "ItemIcon"
		_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_icon.offset_left = 6.0
		_icon.offset_top = 6.0
		_icon.offset_right = -6.0
		_icon.offset_bottom = -6.0
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var path: String = _asset_path(str(item.get("icon", "")))
		if not path.is_empty() and ResourceLoader.exists(path):
			_icon.texture = load(path)
		add_child(_icon)

		if int(item.get("count", 0)) > 0:
			_count = Label.new()
			_count.name = "Count"
			_count.text = str(item.get("count", 0))
			_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			_count.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			_count.offset_left = 5.0
			_count.offset_top = 5.0
			_count.offset_right = -5.0
			_count.offset_bottom = -3.0
			_count.add_theme_color_override("font_color", SLOT_TEXT)
			_count.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
			_count.add_theme_constant_override("shadow_offset_x", 0)
			_count.add_theme_constant_override("shadow_offset_y", 1)
			_count.add_theme_font_size_override("font_size", 11)
			_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(_count)

		if bool(item.get("valuable", false)):
			var tint: ColorRect = ColorRect.new()
			tint.name = "ValueTint"
			tint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
			tint.offset_top = -3.0
			tint.color = ORANGE
			tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(tint)
		elif bool(item.get("mid_value", false)):
			var mid_tint: ColorRect = ColorRect.new()
			mid_tint.name = "ValueTint"
			mid_tint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
			mid_tint.offset_top = -3.0
			mid_tint.color = MUTED
			mid_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(mid_tint)

		_tag = Label.new()
		_tag.name = "ItemTag"
		var is_placeholder_art := bool(item.get("icon_placeholder", false))
		_tag.text = "PLACEHOLDER" if is_placeholder_art else str(item.get("short", item.get("kind", "")))
		_tag.position = Vector2(5, 4)
		_tag.size = Vector2(55, 15)
		_tag.add_theme_color_override("font_color", SLOT_PLACEHOLDER if is_placeholder_art else SLOT_MUTED)
		_tag.add_theme_font_size_override("font_size", 8)
		_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if is_placeholder_art:
			_tag.tooltip_text = str(item.get("icon_accessibility_label", "PLACEHOLDER ART · neutral item placeholder"))
		add_child(_tag)

	func _apply_style() -> void:
		if owner_grid == null:
			return
		var normal = owner_grid.call("_style_for_item", item, false)
		var hover = owner_grid.call("_style_for_item", item, true)
		var pressed = owner_grid.call("_style_for_item", item, true)
		add_theme_stylebox_override("normal", normal)
		add_theme_stylebox_override("hover", hover)
		add_theme_stylebox_override("pressed", pressed)
		add_theme_stylebox_override("focus", hover)
		modulate = owner_grid.call("_modulate_for_item", item)

	func refresh_style() -> void:
		_refresh_interaction_hint()
		_apply_style()

	func _refresh_interaction_hint() -> void:
		if owner_grid == null:
			return
		var suffix := "READ-ONLY · select for details"
		if bool(owner_grid.call("is_mutation_enabled")):
			var quick_enabled := bool(owner_grid.get("quick_transfer_enabled"))
			var can_split := bool(owner_grid.get("split_enabled"))
			if quick_enabled and not can_split:
				suffix = "DRAG · loot   CTRL+CLICK · quick transfer"
			elif can_split and not quick_enabled:
				suffix = "DRAG · exact placement   CTRL+DRAG · split"
			else:
				suffix = "RMB · options   CTRL+CLICK · quick move"
		var art_notice := "\nPLACEHOLDER ART · neutral item placeholder" if bool(item.get("icon_placeholder", false)) else ""
		tooltip_text = str(item.get("name", "Item")) + art_notice + "\n" + suffix

	func _gui_input(event: InputEvent) -> void:
		if not event is InputEventMouseButton:
			return
		var mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			if mouse_event.pressed:
				owner_grid.call("_slot_context", item)
				accept_event()
		elif mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed and mouse_event.ctrl_pressed:
				_ctrl_press_active = true
				_ctrl_drag_started = false
				owner_grid.call("_begin_ctrl_gesture", item)
				accept_event()
			elif not mouse_event.pressed and (_ctrl_press_active or _ctrl_drag_started):
				if not _ctrl_drag_started:
					owner_grid.call("_finish_ctrl_gesture", item)
				_ctrl_press_active = false
				_ctrl_drag_started = false
				accept_event()

	func _on_pressed() -> void:
		# Button activation covers keyboard/controller focus as well as an ordinary
		# pointer click. Ctrl-click is consumed by _gui_input so its release can
		# still arbitrate quick-transfer versus drag/split first.
		if owner_grid != null and not _ctrl_press_active:
			owner_grid.call("_slot_selected", item)

	func _on_mouse_entered() -> void:
		if owner_grid != null:
			owner_grid.call("_slot_hover", item, true)

	func _on_mouse_exited() -> void:
		if owner_grid != null:
			owner_grid.call("_slot_hover", item, false)

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if owner_grid == null or not bool(owner_grid.call("is_mutation_enabled")):
			return null
		_ctrl_drag_started = true
		owner_grid.call("_mark_drag_started", item)
		var preview: Label = Label.new()
		preview.text = str(item.get("name", "ITEM")).to_upper()
		preview.add_theme_color_override("font_color", SLOT_TEXT)
		preview.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
		preview.add_theme_constant_override("shadow_offset_y", 2)
		preview.add_theme_font_size_override("font_size", 11)
		preview.position = Vector2(-10, -18)
		# In production this runs while Godot owns the drag gesture. Contract
		# harnesses may call the native seam directly, where no viewport drag is
		# active and set_drag_preview would emit an engine error.
		var viewport := get_viewport()
		if viewport != null and viewport.gui_is_dragging():
			set_drag_preview(preview)
		else:
			# Contract/headless callers exercise the native payload seam directly;
			# without an active Godot drag manager this preview is otherwise an
			# unparented CanvasItem that survives until process exit.
			preview.free()
		return {
			"type": "inventory_item",
			"item": item.duplicate(true),
			"source": owner_grid.get("source_id"),
			"item_id": item.get("item_id", item.get("id", "")),
			"inventory_id": owner_grid.get("inventory_id"),
			"container_id": owner_grid.get("container_id"),
			"scope": owner_grid.get("scope"),
			"owner_generation": owner_grid.get("owner_generation"),
			"scope_generation": owner_grid.get("scope_generation"),
			"binding_token": owner_grid.get("binding_token"),
			"split": _ctrl_press_active,
		}

	func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
		# An occupied destination is represented by this Button, not the grid
		# beneath it. Forward native drag queries explicitly so compatible stack
		# drops can reach the grid's merge arbitration instead of disappearing at
		# the child-Control hit-test boundary.
		if owner_grid == null or not is_instance_valid(owner_grid):
			return false
		return bool(owner_grid.call("_can_drop_data", _grid_position(at_position), data))

	func _drop_data(at_position: Vector2, data: Variant) -> void:
		if owner_grid == null or not is_instance_valid(owner_grid):
			return
		owner_grid.call("_drop_data", _grid_position(at_position), data)

	func _grid_position(local_position: Vector2) -> Vector2:
		var canvas_position := get_global_transform_with_canvas() * local_position
		return owner_grid.get_global_transform_with_canvas().affine_inverse() * canvas_position

	func _asset_path(asset_name: String) -> String:
		if asset_name.is_empty():
			return ""
		if asset_name.begins_with("res://"):
			return asset_name
		var candidates: Array[String] = [
			"res://assets/handoff/" + asset_name,
			"res://assets/original/" + asset_name,
			"res://assets/" + asset_name,
		]
		for candidate in candidates:
			if ResourceLoader.exists(candidate):
				return candidate
		return ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	queue_redraw()


func set_grid_size(columns: int, rows: int, next_cell_size: int = CELL) -> void:
	var next_columns: int = maxi(1, columns)
	var next_rows: int = maxi(1, rows)
	var next_size: int = maxi(24, next_cell_size)
	var dimensions_changed: bool = grid_columns != next_columns or grid_rows != next_rows \
		or cell_size != next_size
	grid_columns = next_columns
	grid_rows = next_rows
	cell_size = next_size
	custom_minimum_size = Vector2(grid_columns * cell_size, grid_rows * cell_size)
	size = custom_minimum_size
	queue_redraw()
	if dimensions_changed:
		_rebuild_slots()


func set_items(next_items: Array, next_occupancy: Array = []) -> void:
	var occupancy := next_items if next_occupancy.is_empty() else next_occupancy
	if items == next_items and occupancy_items == occupancy:
		return
	items = next_items.duplicate(true)
	occupancy_items = occupancy.duplicate(true)
	if _can_refresh_slot_states_in_place():
		var next_by_key := {}
		for value in items:
			if value is Dictionary:
				next_by_key[_item_key(value as Dictionary)] = value
		for slot in _slots:
			if not is_instance_valid(slot):
				continue
			slot.item = (next_by_key[_item_key(slot.item)] as Dictionary).duplicate(true)
			slot.refresh_style()
		queue_redraw()
		return
	_rebuild_slots()


func set_mutation_enabled(enabled: bool) -> void:
	if mutation_enabled == enabled:
		return
	mutation_enabled = enabled
	for child in _slots:
		if is_instance_valid(child):
			child.refresh_style()
	queue_redraw()


func set_operation_availability(quick_enabled: bool, can_split: bool) -> void:
	if quick_transfer_enabled == quick_enabled and split_enabled == can_split:
		return
	quick_transfer_enabled = quick_enabled
	split_enabled = can_split
	for child in _slots:
		if is_instance_valid(child):
			child.refresh_style()


func set_selected_item_id(item_id: String) -> void:
	if selected_id == item_id:
		return
	selected_id = item_id
	for child in _slots:
		if is_instance_valid(child):
			child.refresh_style()
	queue_redraw()


func is_mutation_enabled() -> bool:
	return mutation_enabled


func set_compatibility(key: String) -> void:
	if compatibility_key == key:
		return
	compatibility_key = key
	for child in _slots:
		if is_instance_valid(child):
			child.refresh_style()
	queue_redraw()


func clear_compatibility() -> void:
	set_compatibility("")


func get_cell_size() -> int:
	return cell_size


func find_first_fit(item: Dictionary) -> Vector2i:
	for y in range(grid_rows):
		for x in range(grid_columns):
			if _fits(item, Vector2i(x, y), str(item.get("id", ""))):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func can_place(item: Dictionary, cell: Vector2i, ignore_id: String = "") -> bool:
	return _fits(item, cell, ignore_id)


func _rebuild_slots() -> void:
	if _rebuild_active:
		_rebuild_queued = true
		return
	_rebuild_active = true
	var focused_key := ""
	var focus_owner := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focus_owner is ItemSlot and focus_owner.owner_grid == self:
		focused_key = _item_key(focus_owner.item)
	var retained := {}
	for child in _slots:
		if is_instance_valid(child): retained[_item_key(child.item)] = child
	var next_slots: Array = []
	for value in items:
		if not value is Dictionary:
			continue
		var item: Dictionary = value as Dictionary
		var key := _item_key(item)
		var slot: ItemSlot = retained.get(key)
		if slot == null:
			slot = ItemSlot.new()
			slot.mouse_entered.connect(slot._on_mouse_entered)
			slot.mouse_exited.connect(slot._on_mouse_exited)
			slot.pressed.connect(slot._on_pressed)
			add_child(slot)
		retained.erase(key)
		var item_w: int = max(1, int(item.get("w", item.get("width", 1))))
		var item_h: int = max(1, int(item.get("h", item.get("height", 1))))
		slot.position = Vector2(int(item.get("x", 0)) * cell_size + 1, int(item.get("y", 0)) * cell_size + 1)
		slot.size = Vector2(item_w * cell_size - 3, item_h * cell_size - 3)
		# Publish the complete retained list only after reconciliation. Native
		# mouse_entered/mouse_exited can fire synchronously from configure(), so a
		# callback must never observe `_slots` cleared or partially appended.
		next_slots.append(slot)
		slot.configure(self, item)
		# A projection rebuild is a gesture cancellation boundary. Do not let a
		# late mouse release turn a removed/stale drag into quick transfer.
		slot._ctrl_press_active = false
		slot._ctrl_drag_started = false
	for child in retained.values():
		remove_child(child)
		child.queue_free()
	_slots = next_slots
	var live_keys := {}
	for slot in _slots:
		live_keys[_item_key(slot.item)] = true
	var occupancy_keys := {}
	for value in occupancy_items:
		if value is Dictionary:
			occupancy_keys[_item_key(value as Dictionary)] = true
	# Filtering removes slots from the visible layer, not from canonical
	# occupancy. Keep a selected hidden item selected so clearing the filter
	# restores its focus/rim instead of silently selecting another item.
	var selection_removed := not selected_id.is_empty() and not occupancy_keys.has(selected_id)
	if selection_removed:
		selected_id = ""
	var ordered_slots := _slots.duplicate()
	ordered_slots.sort_custom(func(left, right):
		if left.position.y != right.position.y:
			return left.position.y < right.position.y
		if left.position.x != right.position.x:
			return left.position.x < right.position.x
		return _item_key(left.item) < _item_key(right.item)
	)
	if not focused_key.is_empty() and not live_keys.has(focused_key) and not ordered_slots.is_empty():
		ordered_slots[0].call_deferred("grab_focus")
	queue_redraw()
	_rebuild_active = false
	if _rebuild_queued:
		_rebuild_queued = false
		call_deferred("_rebuild_slots")


func _can_refresh_slot_states_in_place() -> bool:
	if _rebuild_active or items.size() != _slots.size():
		return false
	var next_by_key := {}
	for value in items:
		if not value is Dictionary:
			return false
		var item: Dictionary = value
		var key := _item_key(item)
		if key.is_empty() or next_by_key.has(key):
			return false
		next_by_key[key] = item
	for slot in _slots:
		if not is_instance_valid(slot):
			return false
		var key := _item_key(slot.item)
		if not next_by_key.has(key):
			return false
		var previous: Dictionary = slot.item.duplicate(true)
		var next: Dictionary = (next_by_key[key] as Dictionary).duplicate(true)
		previous.erase("state")
		next.erase("state")
		if previous != next:
			return false
	return true


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), GRID_BG, true)
	for column in range(grid_columns + 1):
		# Keep the final stroke inside our rect (also inside a scroll clip).
		var x: float = minf(float(column * cell_size), size.x - 1.0)
		PixelStyle.draw_hairline(self, Rect2(x, 0, 1, size.y), GRID_LINE, Rect2(Vector2.ZERO, size))
	for row in range(grid_rows + 1):
		var y: float = minf(float(row * cell_size), size.y - 1.0)
		PixelStyle.draw_hairline(self, Rect2(0, y, size.x, 1), GRID_LINE, Rect2(Vector2.ZERO, size))


func _slot_hover(item: Dictionary, hovering: bool) -> void:
	var key := _item_key(item)
	if hovering:
		if _hovered_key == key:
			return
		_hovered_key = key
	elif _hovered_key != key:
		return
	else:
		_hovered_key = ""
	var payload := item.duplicate(true)
	payload["_binding_token"] = binding_token
	item_hovered.emit(payload, hovering)


func _slot_selected(item: Dictionary) -> void:
	set_selected_item_id(_item_key(item))
	var payload := item.duplicate(true)
	payload["_binding_token"] = binding_token
	item_selected.emit(payload)


func _slot_context(item: Dictionary) -> void:
	set_selected_item_id(_item_key(item))
	var payload := item.duplicate(true)
	payload["_binding_token"] = binding_token
	context_requested.emit(payload)


func _slot_quick_move(item: Dictionary) -> void:
	var payload := item.duplicate(true)
	payload["_binding_token"] = binding_token
	quick_moved.emit(payload, source_id)


func _begin_ctrl_gesture(_item: Dictionary) -> void:
	# The grid intentionally does not submit here.  A release without a drag
	# becomes quick-transfer only after Godot has ruled out a drag gesture.
	return


func _finish_ctrl_gesture(item: Dictionary) -> void:
	_slot_quick_move(item)


func _mark_drag_started(_item: Dictionary) -> void:
	# Kept as an explicit seam for tests and for screen-level gesture guards.
	return


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Dictionary:
		return false
	var payload: Dictionary = data as Dictionary
	if str(payload.get("type", "")) != "inventory_item":
		return false
	# Return true for every well-formed inventory release, including an invalid
	# cell. Godot otherwise suppresses _drop_data and the user receives no
	# native rejection feedback. _drop_data performs the fit/merge decision.
	return payload.get("item", {}) is Dictionary and _cell_for_position(at_position) != Vector2i(-99999, -99999)


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not data is Dictionary:
		return
	var payload: Dictionary = data as Dictionary
	if str(payload.get("type", "")) != "inventory_item":
		return
	var raw_item: Variant = payload.get("item", {})
	if not raw_item is Dictionary:
		drop_rejected.emit({}, str(payload.get("source", "")), _cell_for_position(at_position))
		return
	var item: Dictionary = (raw_item as Dictionary).duplicate(true)
	var cell: Vector2i = _cell_for_position(at_position)
	var source_key := str(payload.get("source", ""))
	item["_binding_token"] = int(payload.get("binding_token", 0))
	if not mutation_enabled:
		drop_rejected.emit(item, source_key, cell)
		return
	var merge_target_id := _merge_target(item, cell, str(payload.get("item_id", "")))
	if payload.get("split", false) and _fits(item, cell, _item_key(item)):
		split_requested.emit(item, source_key, cell)
	elif _fits(item, cell, str(payload.get("item_id", ""))):
		var move_item := item.duplicate(true)
		move_item["_drop_mode"] = "move"
		item_dropped.emit(move_item, source_key, cell)
	elif merge_target_id > 0:
		var merge_item := item.duplicate(true)
		merge_item["_drop_mode"] = "merge"
		merge_item["_merge_target_item_id"] = merge_target_id
		item_dropped.emit(merge_item, source_key, cell)
	else:
		drop_rejected.emit(item, source_key, cell)


func _cell_for_position(position: Vector2) -> Vector2i:
	return Vector2i(floor(position.x / float(cell_size)), floor(position.y / float(cell_size)))


func _fits(item: Dictionary, cell: Vector2i, ignore_id: String = "") -> bool:
	var item_w: int = max(1, int(item.get("w", item.get("width", 1))))
	var item_h: int = max(1, int(item.get("h", item.get("height", 1))))
	if cell.x < 0 or cell.y < 0 or cell.x + item_w > grid_columns or cell.y + item_h > grid_rows:
		return false
	var occupied_values := occupancy_items if not occupancy_items.is_empty() else items
	for existing_value in occupied_values:
		if not existing_value is Dictionary:
			continue
		var existing: Dictionary = existing_value as Dictionary
		if _item_key(existing) == ignore_id:
			continue
		if _rects_overlap(cell.x, cell.y, item_w, item_h, int(existing.get("x", 0)), int(existing.get("y", 0)), max(1, int(existing.get("w", existing.get("width", 1)))), max(1, int(existing.get("h", existing.get("height", 1))))):
			return false
	return true


func _item_key(item: Dictionary) -> String:
	return str(item.get("item_id", item.get("id", "")))


func _merge_target(item: Dictionary, cell: Vector2i, ignore_id: String) -> int:
	var source_key := str(item.get("merge_key", item.get("item_definition_identifier", item.get("definition_id", ""))))
	var source_quantity := int(item.get("quantity", item.get("count", 1)))
	var candidates := occupancy_items if not occupancy_items.is_empty() else items
	for existing_value in candidates:
		if not existing_value is Dictionary:
			continue
		var existing: Dictionary = existing_value as Dictionary
		var existing_id := _item_key(existing)
		if existing_id == ignore_id:
			continue
		var existing_key := str(existing.get("merge_key", existing.get("item_definition_identifier", existing.get("definition_id", ""))))
		if existing_key != source_key:
			continue
		var existing_max: int = maxi(1, int(existing.get("max_stack", 1)))
		if existing_max <= 1 or int(existing.get("quantity", existing.get("count", 1))) + source_quantity > existing_max:
			continue
		var ew: int = maxi(1, int(existing.get("w", existing.get("width", 1))))
		var eh: int = maxi(1, int(existing.get("h", existing.get("height", 1))))
		if cell.x >= int(existing.get("x", 0)) and cell.x < int(existing.get("x", 0)) + ew and cell.y >= int(existing.get("y", 0)) and cell.y < int(existing.get("y", 0)) + eh:
			return int(existing.get("item_id", existing.get("id", 0)))
	return 0


func _rects_overlap(ax: int, ay: int, aw: int, ah: int, bx: int, by: int, bw: int, bh: int) -> bool:
	return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


func _matches_compatibility(item: Dictionary) -> bool:
	if compatibility_key.is_empty():
		return true
	var value: String = str(item.get("compatibility", ""))
	if value.is_empty():
		return false
	return value.to_lower() == compatibility_key.to_lower()


func _modulate_for_item(item: Dictionary) -> Color:
	var result := Color.WHITE if compatibility_key.is_empty() or _matches_compatibility(item) else Color(1, 1, 1, 0.34)
	if StringName(item.get("state", &"normal")) == &"pending":
		result.a *= 0.78
	if not mutation_enabled:
		result.a *= 0.58
	return result


func _style_for_item(item: Dictionary, highlighted: bool) -> StyleBox:
	var style := StyleBoxFlat.new()
	style.bg_color = SLOT_BG
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = SLOT_BORDER
	if compatibility_key.is_empty() or _matches_compatibility(item):
		if not compatibility_key.is_empty() and _matches_compatibility(item):
			style.border_color = GREEN
			style.shadow_color = Color(0.37, 0.83, 0.42, 0.20)
			style.shadow_size = 2
	var state := StringName(item.get("state", &"normal"))
	if _item_key(item) == selected_id or state == &"selected":
		style.border_color = TEXT
		style.shadow_color = Color(0.90, 0.91, 0.89, 0.20)
		style.shadow_size = 2
	match state:
		&"pending":
			style.border_color = ORANGE
			style.shadow_color = Color(0.91, 0.59, 0.18, 0.24)
			style.shadow_size = 2
		&"accepted-flash":
			style.border_color = GREEN
			style.shadow_color = Color(0.37, 0.83, 0.42, 0.24)
			style.shadow_size = 2
		&"rejected", &"stale-corrected":
			style.border_color = RED
			style.shadow_color = Color(0.85, 0.28, 0.23, 0.24)
			style.shadow_size = 2
		&"read-only", &"disconnected", &"resynchronizing":
			style.border_color = MUTED
	if highlighted and state in [&"normal", &"selected"]:
		style.bg_color = Color(0.22, 0.24, 0.22, 0.82)
		if _item_key(item) != selected_id:
			style.border_color = Color(0.95, 0.70, 0.35, 1.0)
	return ZKit.scale_safe(style)
