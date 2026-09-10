@tool
class_name LtsFindingRow
extends Button

## Persistent diagnostic row with severity word, stable code, and source
## path. Error/warning state is never represented by hue alone.

signal finding_activated

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var severity := "Warning"
var diagnostic_code := "LTS-GRAPH-004"
var source_path := "task_graph.main/node.condition"
var explanation := "Condition has no reachable false outcome"
var _state: StringName = LtsComponentState.DEFAULT


func _init() -> void:
	theme_type_variation = &"LevelTaskFindingRow"
	focus_mode = Control.FOCUS_ALL
	alignment = HORIZONTAL_ALIGNMENT_LEFT


func _ready() -> void:
	_apply_state()
	pressed.connect(_on_pressed)


func setup(severity_text: String, code: String, path: String, detail: String, state: Variant = LtsComponentState.ERROR) -> LtsFindingRow:
	severity = severity_text
	diagnostic_code = code
	source_path = path
	explanation = detail
	_state = LtsComponentState.normalize(state)
	_apply_state()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func _on_pressed() -> void:
	if not disabled:
		finding_activated.emit()


func _apply_state() -> void:
	var normalized := LtsComponentState.normalize(_state)
	var prefix := severity
	match normalized:
		LtsComponentState.DEFAULT:
			prefix = "Info"
		LtsComponentState.HOVER:
			prefix = severity + " (hover)"
		LtsComponentState.ACTIVE:
			prefix = severity + " (selected)"
		LtsComponentState.FOCUS:
			prefix = severity + " (keyboard focus)"
		LtsComponentState.DISABLED:
			prefix = severity + " (resolved)"
		LtsComponentState.LOADING:
			prefix = "Validating..."
		LtsComponentState.EMPTY:
			prefix = "No findings"
		LtsComponentState.ERROR:
			prefix = "Error"
	text = "%s  %s  %s" % [prefix, diagnostic_code, source_path]
	tooltip_text = explanation
	button_pressed = normalized == LtsComponentState.ACTIVE
	toggle_mode = normalized == LtsComponentState.ACTIVE
	disabled = normalized == LtsComponentState.EMPTY
	icon = LtsComponentTheme.state_icon(self, normalized)
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"Button")
