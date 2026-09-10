@tool
class_name LtsPortRow
extends Button

## Named port/edge affordance used both inside the showcase and as a compact
## representation beside GraphEdit documentation. Direction, outcome/type,
## and rejection text stay on-surface; tint is only a supplementary cue.

signal port_activated

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _direction := "OUT"
var _port_name := "success"
var _port_type := "outcome"
var _state: StringName = LtsComponentState.DEFAULT
var _detail := ""


func _init() -> void:
	theme_type_variation = &"LevelTaskGraphNode"
	focus_mode = Control.FOCUS_ALL
	alignment = HORIZONTAL_ALIGNMENT_LEFT


func _ready() -> void:
	_apply_state()
	pressed.connect(_on_pressed)


func setup(direction: String, port_name: String, port_type: String, state: Variant = LtsComponentState.DEFAULT, detail: String = "") -> LtsPortRow:
	_direction = direction.to_upper()
	_port_name = port_name
	_port_type = port_type
	_state = LtsComponentState.normalize(state)
	_detail = detail
	_apply_state()
	return self


func set_state(value: Variant, detail: String = "") -> void:
	_state = LtsComponentState.normalize(value)
	if not detail.is_empty():
		_detail = detail
	_apply_state()


func get_state() -> StringName:
	return _state


func _on_pressed() -> void:
	if not disabled:
		port_activated.emit()


func _apply_state() -> void:
	var normalized := LtsComponentState.normalize(_state)
	var state_suffix := ""
	match normalized:
		LtsComponentState.ACTIVE:
			state_suffix = " [selected]"
		LtsComponentState.FOCUS:
			state_suffix = " [keyboard focus]"
		LtsComponentState.DISABLED:
			state_suffix = " [incompatible]"
		LtsComponentState.LOADING:
			state_suffix = " [pending]"
		LtsComponentState.EMPTY:
			state_suffix = " [no edge]"
		LtsComponentState.ERROR:
			state_suffix = " [Error LTS-PORT-001]"
		_:
			state_suffix = ""
	text = "%s  %s : %s%s" % [_direction, _port_name, _port_type, state_suffix]
	tooltip_text = _detail if not _detail.is_empty() else "%s port '%s' (%s)" % [_direction, _port_name, _port_type]
	button_pressed = normalized == LtsComponentState.ACTIVE
	toggle_mode = normalized == LtsComponentState.ACTIVE
	disabled = normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"Button")
