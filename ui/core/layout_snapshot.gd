class_name ZLayoutSnapshot
extends RefCounted

## Retains authored controls when a compact layout temporarily reparents them.
## Layout properties are restored; live model values are never rolled back.
const PROPERTIES := [
	"anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
	"offset_left", "offset_top", "offset_right", "offset_bottom",
	"grow_horizontal", "grow_vertical", "custom_minimum_size", "position", "size",
	"visible", "clip_contents", "mouse_filter", "scale", "pivot_offset", "rotation",
]
var _entries: Array[Dictionary] = []
var _root_children: Array[Node] = []
var _canvas_entries: Array[Dictionary] = []

func _init(root: Control) -> void:
	_root_children.assign(root.get_children())
	for node in root.find_children("*", "CanvasItem", true, false):
		if not node is Control: _canvas_entries.append({"node": node, "visible": node.visible})
	for node in root.find_children("*", "Control", true, false):
		if not node.get_parent().get_children().has(node):
			continue # Engine-owned scrollbars are not authored layout controls.
		var values := {}
		for property in PROPERTIES:
			values[property] = node.get(property)
		if node is Button: values["icon"] = node.icon
		if node is Label:
			for property in ["clip_text", "horizontal_alignment", "vertical_alignment", "autowrap_mode"]:
				values[property] = node.get(property)
		if node is TextureRect:
			for property in ["texture", "stretch_mode", "expand_mode"]:
				values[property] = node.get(property)
		values["name"] = node.name
		_entries.append({"node": node, "parent": node.get_parent(), "index": node.get_index(), "values": values})

func restore(root: Control) -> void:
	for node in root.find_children("*", "Control", true, false):
		if node.has_meta("z_layout_restore"):
			var overrides: Dictionary = node.get_meta("z_layout_restore")
			for property in overrides: node.set(property, overrides[property])
			node.remove_meta("z_layout_restore")
	for entry in _canvas_entries:
		if is_instance_valid(entry.node): entry.node.visible = entry.visible
	for entry in _entries:
		if not is_instance_valid(entry.node) or not is_instance_valid(entry.parent):
			continue
		var node: Control = entry.node
		var parent: Node = entry.parent
		if not is_instance_valid(node) or not is_instance_valid(parent):
			continue
		if node.get_parent() != parent:
			node.reparent(parent, false)
		parent.move_child(node, mini(int(entry.index), parent.get_child_count() - 1))
		for property in entry.values:
			node.set(property, entry.values[property])
	# All retained controls have been rescued from temporary layout hosts first.
	for child in root.get_children():
		if child is Control and not _root_children.has(child):
			root.remove_child(child)
			child.queue_free()
	for key in [&"tasks_compact_chrome"]:
		if root.has_meta(key): root.remove_meta(key)

## Temporary presentation overrides are reversible without reverting model data.
static func layout_value(node: Control, property: String, value: Variant) -> void:
	var original: Dictionary = node.get_meta("z_layout_restore", {})
	if not original.has(property): original[property] = node.get(property)
	node.set_meta("z_layout_restore", original)
	node.set(property, value)

static func button_variant(button: Button, variant: String) -> void:
	layout_value(button, "theme_type_variation", "ZPrimaryButton" if variant == "primary" else "ZButton")
	for key in ["normal", "hover", "pressed", "focus", "disabled"]:
		layout_value(button, "theme_override_styles/" + key, null)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		layout_value(button, "theme_override_colors/" + key, null)

static func interaction(root: Control) -> Dictionary:
	var scroll := {}
	for pane in root.find_children("*", "ScrollContainer", true, false):
		scroll[str(pane.name)] = Vector2i(pane.scroll_horizontal, pane.scroll_vertical)
	var focus := root.get_viewport().gui_get_focus_owner()
	return {"scroll": scroll, "focus": focus if focus != null and root.is_ancestor_of(focus) else null,
		"caret": focus.caret_column if focus is LineEdit else -1}

static func restore_interaction(root: Control, state: Dictionary) -> void:
	if not is_instance_valid(root) or not root.is_inside_tree(): return
	for pane in root.find_children("*", "ScrollContainer", true, false):
		if state.scroll.has(str(pane.name)):
			var value: Vector2i = state.scroll[str(pane.name)]
			pane.scroll_horizontal = value.x
			pane.scroll_vertical = value.y
	var focus: Variant = state.focus
	if is_instance_valid(focus) and focus.is_visible_in_tree() and focus.focus_mode != Control.FOCUS_NONE:
		focus.grab_focus()
		if focus is LineEdit and int(state.caret) >= 0: focus.caret_column = int(state.caret)
