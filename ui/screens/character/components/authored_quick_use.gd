class_name AuthoredQuickUse
extends RefCounted
## Mount the existing authored Quick Use title and item slots unchanged in style.
## No new keybind/action strip, assignment service or gameplay input handler.
const SOURCE := "res://ui/screens/character/character_workspace.tscn"
const NAMES := ["QuickUseTitle", "QuickSlot5", "QuickSlot6", "QuickSlot7", "QuickSlot8"]

static func pin_character(screen: Control) -> void:
	var controls: Array[Control] = []
	for name: String in NAMES:
		var node: Control = screen._node(name)
		if node == null: return
		controls.append(node)
	_pin(screen, controls)

static func mount_hud(screen: Control) -> void:
	if screen.has_node("QuickUse"): return
	# Never mount/build the preview workspace. Take its original authored controls
	# before it enters the tree, so fixture controllers never activate. There is
	# one design source to edit, not a second handwritten hotbar.
	var authored := (load(SOURCE) as PackedScene).instantiate()
	var controls: Array[Control] = []
	for name: String in NAMES:
		controls.append(authored.get_node("InventoryContent/" + name))
	_pin(screen, controls)
	authored.free()

static func _pin(screen: Control, controls: Array[Control]) -> void:
	var row := screen.get_node_or_null("QuickUse") as Control
	if row == null:
		row = Control.new()
		row.name = "QuickUse"
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.set_meta("authored_source", SOURCE)
		screen.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	row.offset_left = -151; row.offset_right = 151
	row.offset_top = -110; row.offset_bottom = -14
	row.show()
	for index in range(controls.size()):
		var control := controls[index]
		if control.get_parent() != row:
			# The HUD takes children from an off-tree authored scene. Its original
			# serialization owner is not an ancestor in the HUD, so retire it first.
			if not screen.is_ancestor_of(control):
				control.owner = null
				for child: Node in control.find_children("*", "", true, false): child.owner = null
			control.reparent(row, false)
		control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		control.position = Vector2(0, 0) if index == 0 else Vector2((index - 1) * 76, 24)
		control.size = Vector2(302, 22) if index == 0 else Vector2(74, 72)
		control.show()
		if control is Label:
			control.text = "QUICK USE · UNAVAILABLE"
			control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		elif control is Button:
			# Keep numbered item-slot design; don't invent a binding or populate
			# the preview bottle/count as a confirmed quick-slot assignment.
			control.disabled = true
			control.focus_mode = Control.FOCUS_NONE
			control.tooltip_text = "Quick item assignments are not available in this build."
			control.mouse_default_cursor_shape = Control.CURSOR_ARROW
			for name: String in ["Icon", "Count"]:
				var sample := control.get_node_or_null(name) as CanvasItem
				if sample != null: sample.hide()
