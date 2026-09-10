@tool
class_name LtsEmptyState
extends PanelContainer

## Intentional empty-content presentation: explain the scope and offer the
## next author action. Unexpected native failures belong to LtsDegradedState.

signal action_requested

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")
const CommandButtonScript := preload("res://addons/level_task_system/editor/components/lts_command_button.gd")

var _title_text := "No resource selected"
var _explanation := "Choose a catalog resource or create a task graph to begin."
var _action_text := "Create task graph"
var _state: StringName = LtsComponentState.EMPTY
var _action
var _icon: TextureRect
var _title_label: Label
var _body_label: Label
var _built := false


func _init() -> void:
	theme_type_variation = &"LevelTaskEmptyState"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	_build()


func setup(title_text: String, explanation_text: String, action_text: String = "Create task graph", state: Variant = LtsComponentState.EMPTY) -> LtsEmptyState:
	_title_text = title_text
	_explanation = explanation_text
	_action_text = action_text
	_state = LtsComponentState.normalize(state)
	_build()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func _build() -> void:
	if not _built and not is_inside_tree():
		return
	if _action != null:
		return
	var column := VBoxContainer.new()
	column.name = "EmptyColumn"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(column)
	_icon = TextureRect.new()
	_icon.name = "EmptyIcon"
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.tooltip_text = "Empty content"
	column.add_child(_icon)
	_title_label = Label.new()
	_title_label.name = "EmptyTitle"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title_label)
	_body_label = Label.new()
	_body_label.name = "EmptyExplanation"
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_body_label)
	_action = CommandButtonScript.new()
	_action.name = "EmptyAction"
	_action.call("setup", _action_text, [&"Add", &"CreateNew"], "Create the first authored resource")
	_action.connect("command_requested", _on_action)
	column.add_child(_action)
	_apply_state()


func _on_action() -> void:
	if _state != LtsComponentState.DISABLED and _state != LtsComponentState.LOADING:
		action_requested.emit()


func _apply_state() -> void:
	if _action == null:
		return
	var normalized := LtsComponentState.normalize(_state)
	_title_label.text = _title_text
	_body_label.text = _explanation
	match normalized:
		LtsComponentState.DEFAULT:
			_body_label.text = _explanation
		LtsComponentState.HOVER:
			_body_label.text = _explanation + " (action is under the pointer)"
		LtsComponentState.ACTIVE:
			_body_label.text = _explanation + " (action selected)"
		LtsComponentState.FOCUS:
			_body_label.text = _explanation + " Use Enter to continue."
		LtsComponentState.DISABLED:
			_body_label.text = "Creation is unavailable while the native extension is read-only."
		LtsComponentState.LOADING:
			_body_label.text = "Loading the catalog... existing context is preserved."
		LtsComponentState.EMPTY:
			_body_label.text = _explanation
		LtsComponentState.ERROR:
			_body_label.text = "Error LTS-EMPTY-001: " + _explanation
	_title_label.tooltip_text = _title_label.text
	_body_label.tooltip_text = _body_label.text
	_icon.texture = LtsComponentTheme.state_icon(self, normalized)
	_action.call("set_state", normalized)
	_action.tooltip_text = _action_text
	_action.disabled = normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	LtsComponentTheme.preview_style(self, normalized, &"panel", &"PanelContainer")
