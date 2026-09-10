@tool
class_name LtsInspectorField
extends PanelContainer

## Compact contextual field row. The value is retained while loading and
## error states so the author can see what needs recovery.

signal value_committed(value: String)

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _field_label := "Stable identifier"
var _field_value := "task.graph.main"
var _field_help := "Canonical identifier"
var _state: StringName = LtsComponentState.DEFAULT
var _error_message := ""
var _value_edit: LineEdit
var _state_label: Label
var _built := false


func _init() -> void:
	theme_type_variation = &"LevelTaskInspectorField"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	_build()


func setup(label_text: String, value_text: String, help_text: String = "", state: Variant = LtsComponentState.DEFAULT) -> LtsInspectorField:
	_field_label = label_text
	_field_value = value_text
	_field_help = help_text
	_state = LtsComponentState.normalize(state)
	_build()
	return self


func set_state(value: Variant, error_message: String = "") -> void:
	_state = LtsComponentState.normalize(value)
	_error_message = error_message
	_apply_state()


func get_state() -> StringName:
	return _state


func get_value() -> String:
	return _value_edit.text if _value_edit != null else _field_value


func _build() -> void:
	if not _built and not is_inside_tree():
		return
	if _value_edit != null:
		return
	var margin := MarginContainer.new()
	margin.name = "FieldMargin"
	add_child(margin)
	var column := VBoxContainer.new()
	column.name = "FieldColumn"
	margin.add_child(column)
	var header := HBoxContainer.new()
	header.name = "FieldHeader"
	column.add_child(header)
	var label := Label.new()
	label.name = "FieldLabel"
	label.text = _field_label
	label.tooltip_text = _field_label
	header.add_child(label)
	header.add_spacer(false)
	_state_label = Label.new()
	_state_label.name = "StateLabel"
	header.add_child(_state_label)
	_value_edit = LineEdit.new()
	_value_edit.name = "Value"
	_value_edit.text = _field_value
	_value_edit.placeholder_text = "Value"
	_value_edit.tooltip_text = _field_help
	_value_edit.focus_mode = Control.FOCUS_ALL
	_value_edit.text_submitted.connect(_on_value_submitted)
	column.add_child(_value_edit)
	var help := Label.new()
	help.name = "FieldHelp"
	help.text = _field_help
	help.tooltip_text = _field_help
	column.add_child(help)
	_apply_state()


func _on_value_submitted(value: String) -> void:
	_field_value = value
	value_committed.emit(value)


func _apply_state() -> void:
	if _value_edit == null:
		return
	var normalized := LtsComponentState.normalize(_state)
	var state_text := ""
	match normalized:
		LtsComponentState.ACTIVE:
			state_text = "Editing"
		LtsComponentState.FOCUS:
			state_text = "Keyboard focus"
		LtsComponentState.DISABLED:
			state_text = "Locked"
		LtsComponentState.LOADING:
			state_text = "Loading..."
		LtsComponentState.EMPTY:
			state_text = "No value"
		LtsComponentState.ERROR:
			state_text = "Error LTS-FIELD-001"
		_:
			state_text = ""
	_state_label.text = state_text
	_state_label.tooltip_text = state_text
	LtsComponentTheme.apply_state_text(_state_label, normalized, state_text)
	_value_edit.editable = not (normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING)
	if normalized == LtsComponentState.EMPTY:
		_value_edit.placeholder_text = "Select a resource"
	elif normalized == LtsComponentState.ERROR:
		_value_edit.tooltip_text = _error_message if not _error_message.is_empty() else "Invalid value at %s" % _field_label
	else:
		_value_edit.placeholder_text = "Value"
		_value_edit.tooltip_text = _field_help
	LtsComponentTheme.preview_style(self, normalized, &"panel", &"PanelContainer")
	if normalized == LtsComponentState.ERROR:
		_value_edit.add_theme_color_override(&"font_color", LtsComponentTheme.state_color(self, normalized))
	else:
		_value_edit.remove_theme_color_override(&"font_color")
