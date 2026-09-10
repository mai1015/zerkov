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
var items: Array = []
var compatibility_key: String = ""
var selected_id: String = ""

var _slots: Array = []


class ItemSlot extends Button:
	const SLOT_TEXT := Color(0.90, 0.91, 0.89, 1.0)
	const SLOT_MUTED := Color(0.55, 0.57, 0.54, 1.0)
	var owner_grid: Control
	var item: Dictionary
	var _icon: TextureRect
	var _count: Label
	var _tag: Label

	func configure(grid: Control, value: Dictionary) -> void:
		owner_grid = grid
		if item == value: return
		item = value.duplicate(true)
		flat = true
		text = ""
		focus_mode = Control.FOCUS_ALL
		# Let wheel/trackpad events reach the enclosing native scroll pane.
		mouse_force_pass_scroll_events = true
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tooltip_text = str(item.get("name", "Item")) + "\nRMB · options   CTRL+CLICK · quick move"
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
		_tag.text = str(item.get("short", ""))
		_tag.position = Vector2(5, 4)
		_tag.size = Vector2(55, 15)
		_tag.add_theme_color_override("font_color", SLOT_MUTED)
		_tag.add_theme_font_size_override("font_size", 8)
		_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		_apply_style()

	func _gui_input(event: InputEvent) -> void:
		if not event is InputEventMouseButton:
			return
		var mouse_event: InputEventMouseButton = event as InputEventMouseButton
		if not mouse_event.pressed:
			return
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			owner_grid.call("_slot_context", item)
			accept_event()
		elif mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.ctrl_pressed:
			owner_grid.call("_slot_quick_move", item)
			accept_event()
		elif mouse_event.button_index == MOUSE_BUTTON_LEFT:
			owner_grid.call("_slot_selected", item)

	func _on_mouse_entered() -> void:
		if owner_grid != null:
			owner_grid.call("_slot_hover", item, true)

	func _on_mouse_exited() -> void:
		if owner_grid != null:
			owner_grid.call("_slot_hover", item, false)

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if owner_grid == null:
			return null
		var preview: Label = Label.new()
		preview.text = str(item.get("name", "ITEM")).to_upper()
		preview.add_theme_color_override("font_color", SLOT_TEXT)
		preview.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
		preview.add_theme_constant_override("shadow_offset_y", 2)
		preview.add_theme_font_size_override("font_size", 11)
		preview.position = Vector2(-10, -18)
		set_drag_preview(preview)
		return {
			"type": "inventory_item",
			"item": item.duplicate(true),
			"source": owner_grid.get("source_id"),
			"item_id": str(item.get("id", "")),
		}

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
	grid_columns = max(1, columns)
	grid_rows = max(1, rows)
	cell_size = max(24, next_cell_size)
	custom_minimum_size = Vector2(grid_columns * cell_size, grid_rows * cell_size)
	size = custom_minimum_size
	queue_redraw()
	_rebuild_slots()


func set_items(next_items: Array) -> void:
	if items == next_items: return
	items = next_items.duplicate(true)
	_rebuild_slots()


func set_compatibility(key: String) -> void:
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
	var retained := {}
	for child in _slots:
		if is_instance_valid(child): retained[str(child.item.get("id", ""))] = child
	_slots.clear()
	for value in items:
		if not value is Dictionary:
			continue
		var item: Dictionary = value as Dictionary
		var key := str(item.get("id", ""))
		var slot: ItemSlot = retained.get(key)
		if slot == null:
			slot = ItemSlot.new()
			slot.mouse_entered.connect(slot._on_mouse_entered)
			slot.mouse_exited.connect(slot._on_mouse_exited)
			add_child(slot)
		retained.erase(key)
		var item_w: int = max(1, int(item.get("w", 1)))
		var item_h: int = max(1, int(item.get("h", 1)))
		slot.position = Vector2(int(item.get("x", 0)) * cell_size + 1, int(item.get("y", 0)) * cell_size + 1)
		slot.size = Vector2(item_w * cell_size - 3, item_h * cell_size - 3)
		slot.configure(self, item)
		_slots.append(slot)
	for child in retained.values():
		remove_child(child)
		child.queue_free()
	queue_redraw()


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
	item_hovered.emit(item, hovering)


func _slot_selected(item: Dictionary) -> void:
	selected_id = str(item.get("id", ""))
	item_selected.emit(item)


func _slot_context(item: Dictionary) -> void:
	selected_id = str(item.get("id", ""))
	context_requested.emit(item)


func _slot_quick_move(item: Dictionary) -> void:
	quick_moved.emit(item, source_id)


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Dictionary:
		return false
	var payload: Dictionary = data as Dictionary
	if str(payload.get("type", "")) != "inventory_item":
		return false
	var item: Dictionary = payload.get("item", {})
	var cell: Vector2i = _cell_for_position(at_position)
	return _fits(item, cell, str(payload.get("item_id", "")))


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not data is Dictionary:
		return
	var payload: Dictionary = data as Dictionary
	if str(payload.get("type", "")) != "inventory_item":
		return
	var item: Dictionary = payload.get("item", {})
	var cell: Vector2i = _cell_for_position(at_position)
	if _fits(item, cell, str(payload.get("item_id", ""))):
		item_dropped.emit(item, str(payload.get("source", "")), cell)
	else:
		drop_rejected.emit(item, str(payload.get("source", "")), cell)


func _cell_for_position(position: Vector2) -> Vector2i:
	return Vector2i(floor(position.x / float(cell_size)), floor(position.y / float(cell_size)))


func _fits(item: Dictionary, cell: Vector2i, ignore_id: String = "") -> bool:
	var item_w: int = max(1, int(item.get("w", 1)))
	var item_h: int = max(1, int(item.get("h", 1)))
	if cell.x < 0 or cell.y < 0 or cell.x + item_w > grid_columns or cell.y + item_h > grid_rows:
		return false
	for existing_value in items:
		if not existing_value is Dictionary:
			continue
		var existing: Dictionary = existing_value as Dictionary
		if str(existing.get("id", "")) == ignore_id:
			continue
		if _rects_overlap(cell.x, cell.y, item_w, item_h, int(existing.get("x", 0)), int(existing.get("y", 0)), max(1, int(existing.get("w", 1))), max(1, int(existing.get("h", 1)))):
			return false
	return true


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
	if compatibility_key.is_empty() or _matches_compatibility(item):
		return Color.WHITE
	return Color(1, 1, 1, 0.34)


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
	if str(item.get("id", "")) == selected_id:
		style.border_color = TEXT
		style.shadow_color = Color(0.90, 0.91, 0.89, 0.20)
		style.shadow_size = 2
	if highlighted:
		style.bg_color = Color(0.22, 0.24, 0.22, 0.82)
		if str(item.get("id", "")) != selected_id:
			style.border_color = Color(0.95, 0.70, 0.35, 1.0)
	return ZKit.scale_safe(style)
