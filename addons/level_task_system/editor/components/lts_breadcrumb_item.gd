@tool
class_name LtsBreadcrumbItem
extends Button

## A breadcrumb control is intentionally a native Button. The showcase adds
## separators as ordinary labels so the current item remains keyboard and
## screen-reader discoverable as a labelled control.

signal breadcrumb_activated

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _label := "Task graphs"
var _full_path := "Catalog / Task graphs / main"
var _state: StringName = LtsComponentState.DEFAULT


func _init() -> void:
	theme_type_variation = &"LevelTaskBreadcrumb"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_apply_state()
	pressed.connect(_on_pressed)


func setup(label: String, full_path: String = "", state: Variant = LtsComponentState.DEFAULT) -> LtsBreadcrumbItem:
	_label = label
	_full_path = full_path if not full_path.is_empty() else label
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
		breadcrumb_activated.emit()


func _apply_state() -> void:
	var normalized := LtsComponentState.normalize(_state)
	text = _label
	tooltip_text = _full_path
	button_pressed = normalized == LtsComponentState.ACTIVE
	toggle_mode = normalized == LtsComponentState.ACTIVE
	disabled = normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	if normalized == LtsComponentState.LOADING:
		text = _label + " [Loading...]"
	elif normalized == LtsComponentState.ERROR:
		text = _label + " [Broken reference]"
	elif normalized == LtsComponentState.EMPTY:
		text = "Catalog"
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"Button")
