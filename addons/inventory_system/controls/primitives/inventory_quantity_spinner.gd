class_name InventoryQuantitySpinner
extends Control

## Minimal inline quantity-picker primitive for the split action (tasks.md
## 8.5). A full modal quantity picker is the `inventory_common_ui` adapter's
## job (task 9.4, serialized as a CommonUI modal transaction); this addon
## keeps a plain, CommonUI-independent [Control] fallback so split works with
## only `inventory_system` enabled.
##
## Deliberately NOT an [InventoryModal]/[PopupPanel] -- no focus-trap, no
## scrim -- so a host can embed it inline next to a drop target. [member min_value]/
## [member max_value] bound the pickable split-off quantity; [method InventoryInteractionController.confirm_split]
## configures them so a split always leaves at least one unit behind in the
## source stack (taking the FULL quantity is a move, not a split) and takes at
## least one unit for the new stack. This primitive never validates placement
## FEASIBILITY -- the eventual `split_stack()` call remains the sole authority
## on whether the chosen quantity is actually accepted.

signal value_changed(value: int)
signal confirmed(value: int)
signal cancelled

var tokens: InventoryDesignTokens
var min_value: int = 1
var max_value: int = 1

var _value: int = 1
var _label: Label
var _decrement_button: Button
var _increment_button: Button
var _confirm_button: Button
var _cancel_button: Button
var _row: HBoxContainer


func _init() -> void:
	theme_type_variation = InventoryThemeFactory.TYPE_MODAL
	_build_children()


## This primitive is a plain [Control] (see this file's header comment for
## why), not a real Container -- unlike a [VBoxContainer]/[PanelContainer] it
## does NOT automatically propagate a child's minimum size upward on its own.
## Overriding this virtual is what lets a HOST Container (e.g.
## [InventoryModal.set_content], tasks.md 8.3/8.5's split-quantity flow) size
## itself correctly around this spinner instead of collapsing it to (0, 0)
## while [member _row]'s buttons still render at their own natural size
## regardless, overflowing past the host's too-small allocated rect --
## empirically confirmed while wiring InventoryModal around this control (the
## visual-QA state sheet's modal cells rendered as a collapsed sliver with the
## spinner's row bleeding out past it before this fix).
func _get_minimum_size() -> Vector2:
	return _row.get_combined_minimum_size() if _row != null else Vector2.ZERO


func _build_children() -> void:
	_row = HBoxContainer.new()
	_row.name = "Row"
	add_child(_row)
	var row := _row

	_decrement_button = Button.new()
	_decrement_button.name = "Decrement"
	_decrement_button.text = "-"
	_decrement_button.pressed.connect(decrement)
	row.add_child(_decrement_button)

	_label = Label.new()
	_label.name = "Value"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_label)

	_increment_button = Button.new()
	_increment_button.name = "Increment"
	_increment_button.text = "+"
	_increment_button.pressed.connect(increment)
	row.add_child(_increment_button)

	_confirm_button = Button.new()
	_confirm_button.name = "Confirm"
	_confirm_button.text = "Confirm"
	_confirm_button.pressed.connect(func(): confirmed.emit(_value))
	row.add_child(_confirm_button)

	_cancel_button = Button.new()
	_cancel_button.name = "Cancel"
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(func(): cancelled.emit())
	row.add_child(_cancel_button)


## [param p_max_value]: normally the source stack's CURRENT quantity minus 1.
func configure(p_min_value: int, p_max_value: int, p_initial_value: int, p_tokens: InventoryDesignTokens = null) -> void:
	tokens = p_tokens if p_tokens != null else InventoryDesignTokens.new()
	min_value = maxi(p_min_value, 1)
	max_value = maxi(p_max_value, min_value)
	set_value(p_initial_value)


func set_value(value: int) -> void:
	var clamped := clampi(value, min_value, max_value)
	var changed := clamped != _value
	_value = clamped
	_refresh_label()
	if changed:
		value_changed.emit(_value)


func increment() -> void:
	set_value(_value + 1)


func decrement() -> void:
	set_value(_value - 1)


func value() -> int:
	return _value


func _refresh_label() -> void:
	_label.text = "x%d" % _value
