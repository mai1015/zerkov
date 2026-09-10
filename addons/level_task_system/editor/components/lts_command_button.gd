@tool
class_name LtsCommandButton
extends Button

## Native-theme command button used by the editor workspace and showcase.
## Semantic state is explicit so loading/disabled actions remain readable and
## do not silently accept a second command.

signal command_requested

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

@export var command_label: String = "Command":
	set(value):
		command_label = value
		_apply_state()

@export var command_tooltip: String = "":
	set(value):
		command_tooltip = value
		_apply_state()

var _state: StringName = LtsComponentState.DEFAULT
var _icon_names: Array = []
var _blocked_by_host := false
var _ready_for_state := false


func _init() -> void:
	theme_type_variation = &"LevelTaskCommandButton"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_ready_for_state = true
	_apply_state()
	pressed.connect(_on_pressed)


func setup(label: String, icons: Array = [], tooltip: String = "") -> LtsCommandButton:
	command_label = label
	_icon_names = icons.duplicate()
	command_tooltip = tooltip
	_apply_state()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func set_host_blocked(blocked: bool, reason: String = "") -> void:
	_blocked_by_host = blocked
	if blocked and not reason.is_empty():
		command_tooltip = reason
	_apply_state()


func _on_pressed() -> void:
	if disabled or LtsComponentState.is_blocked(_state):
		return
	command_requested.emit()


func _apply_state() -> void:
	if not is_inside_tree() and not _ready_for_state:
		return
	var normalized := LtsComponentState.normalize(_state)
	var display_label := command_label
	if display_label.is_empty():
		display_label = "Command"
	if normalized == LtsComponentState.LOADING:
		display_label = "Loading... " + display_label
	elif normalized == LtsComponentState.EMPTY:
		display_label = "Create " + display_label
	elif normalized == LtsComponentState.ERROR:
		display_label = "Retry " + display_label
	text = display_label
	tooltip_text = command_tooltip if not command_tooltip.is_empty() else display_label
	button_pressed = normalized == LtsComponentState.ACTIVE
	toggle_mode = normalized == LtsComponentState.ACTIVE
	disabled = _blocked_by_host or normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	if not _icon_names.is_empty():
		icon = LtsComponentTheme.resolve_icon(self, _icon_names, LtsComponentState.icon_name(normalized))
	else:
		icon = LtsComponentTheme.state_icon(self, normalized)
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"Button")
