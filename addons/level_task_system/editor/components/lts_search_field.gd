@tool
class_name LtsSearchField
extends LineEdit

## Search/filter field that preserves its query while loading or reporting a
## provider error. The field inherits LineEdit focus, selection, caret, and
## placeholder visuals from the active editor theme.

signal query_changed(query: String)

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _state: StringName = LtsComponentState.DEFAULT
var _base_placeholder := "Search resources"
var _last_error := ""
var _connected := false


func _init() -> void:
	theme_type_variation = &"LevelTaskSearchField"
	focus_mode = Control.FOCUS_ALL
	clear_button_enabled = true
	placeholder_text = _base_placeholder


func _ready() -> void:
	if not _connected:
		text_changed.connect(_on_text_changed)
		_connected = true
	_apply_state()


func setup(placeholder: String = "Search resources", state: Variant = LtsComponentState.DEFAULT) -> LtsSearchField:
	_base_placeholder = placeholder
	_state = LtsComponentState.normalize(state)
	_apply_state()
	return self


func set_state(value: Variant, error_message: String = "") -> void:
	_state = LtsComponentState.normalize(value)
	_last_error = error_message
	_apply_state()


func get_state() -> StringName:
	return _state


func _on_text_changed(value: String) -> void:
	query_changed.emit(value)


func _apply_state() -> void:
	var normalized := LtsComponentState.normalize(_state)
	tooltip_text = _base_placeholder
	editable = not (normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING)
	if normalized == LtsComponentState.LOADING:
		placeholder_text = "Searching... " + _base_placeholder
	elif normalized == LtsComponentState.EMPTY:
		placeholder_text = "No matches. Clear the filter."
	elif normalized == LtsComponentState.ERROR:
		placeholder_text = "Search error LTS-SEARCH-001"
		tooltip_text = _last_error if not _last_error.is_empty() else "Search error LTS-SEARCH-001"
	else:
		placeholder_text = _base_placeholder
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"LineEdit")
	if normalized == LtsComponentState.ERROR:
		add_theme_color_override(&"font_color", LtsComponentTheme.state_color(self, normalized))
	else:
		remove_theme_color_override(&"font_color")
