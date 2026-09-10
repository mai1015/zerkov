@tool
class_name LtsIconButton
extends Button

## Icon-only editor action. The tooltip is the accessible name fallback and
## the action keeps native Button focus/pressed/disabled geometry.

signal action_requested

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _label := "Editor action"
var _icon_names: Array = []
var _state: StringName = LtsComponentState.DEFAULT
var _blocked_by_host := false


func _init() -> void:
	theme_type_variation = &"LevelTaskIconButton"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_apply_state()
	pressed.connect(_on_pressed)


func setup(label: String, icons: Array = [], state: Variant = LtsComponentState.DEFAULT) -> LtsIconButton:
	_label = label
	_icon_names = icons.duplicate()
	_state = LtsComponentState.normalize(state)
	_apply_state()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func set_host_blocked(blocked: bool, reason: String = "") -> void:
	_blocked_by_host = blocked
	if not reason.is_empty():
		tooltip_text = reason
	_apply_state()


func _on_pressed() -> void:
	if disabled or LtsComponentState.is_blocked(_state):
		return
	action_requested.emit()


func _apply_state() -> void:
	var normalized := LtsComponentState.normalize(_state)
	tooltip_text = _label
	if normalized == LtsComponentState.LOADING:
		text = "Loading..."
	else:
		text = ""
	button_pressed = normalized == LtsComponentState.ACTIVE
	toggle_mode = normalized == LtsComponentState.ACTIVE
	disabled = _blocked_by_host or normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	if _icon_names.is_empty():
		icon = LtsComponentTheme.state_icon(self, normalized)
	else:
		icon = LtsComponentTheme.resolve_icon(self, _icon_names, LtsComponentState.icon_name(normalized))
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"Button")
