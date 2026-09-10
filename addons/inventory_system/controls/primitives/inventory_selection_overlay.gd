class_name InventorySelectionOverlay
extends Control

## Reusable "selected" decoration (DESIGN.md §12's `selected` row is
## documented per-primitive with the same shape: a thicker accent border).
## Any primitive that can be selected -- [InventoryItemCard], a grid cell, a
## slot, a list row -- adds one of these as a full-rect child instead of
## re-deriving selection styling itself, and calls [method refresh] whenever
## selection might have changed. Invisible and inert when inactive.

var _panel: Panel


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Deliberately NOT PRESET_FULL_RECT on this outer control: a caller adds
	# this as a SIBLING of whatever it decorates and positions/sizes it
	# explicitly at that sibling's own local rect (see e.g.
	# InventorySpatialGridControl._build_cards()) -- full-rect anchors here
	# would fight that explicit placement (Godot's own "non-equal opposite
	# anchors" warning) and stretch to fill THIS control's parent (the whole
	# container control) instead of the one cell/card it should overlay. The
	# inner `_panel` below still fills whatever rect this outer control ends
	# up with, which is the correct place for a full-rect fill.
	visible = false
	_panel = Panel.new()
	_panel.name = "SelectionPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)


## [param type_name]: which Theme Type Variation to pull the `selected` state
## StyleBox from -- [constant InventoryThemeFactory.TYPE_ITEM_CARD] by
## default; pass TYPE_GRID_CELL/TYPE_SLOT/TYPE_LIST_ROW to match whichever
## primitive this overlay decorates, per [InventoryThemeFactory]'s per-state
## StyleBox naming convention ([method InventoryThemeFactory.state_stylebox_name]).
func refresh(active: bool, type_name: StringName = &"InventoryItemCard") -> void:
	visible = active
	if not active:
		return
	var stylebox := get_theme_stylebox(
			InventoryThemeFactory.state_stylebox_name(InventoryPresentationModel.STATE_SELECTED), type_name)
	if stylebox != null:
		_panel.add_theme_stylebox_override(&"panel", stylebox)
