@tool
class_name LtsResourceRow
extends Button

## Keyboard-reachable resource navigation row. A Button gives the row the
## editor's native hover, selected, focus, and disabled treatment while the
## visible path and status text remain available without a tooltip.

signal resource_activated

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _resource_name := "Task graph"
var _resource_path := "res://levels/task_graph.tres"
var _icon_names: Array = []
var _state: StringName = LtsComponentState.DEFAULT
var _blocked_by_host := false


func _init() -> void:
	theme_type_variation = &"LevelTaskResourceRow"
	focus_mode = Control.FOCUS_ALL
	alignment = HORIZONTAL_ALIGNMENT_LEFT


func _ready() -> void:
	_apply_state()
	pressed.connect(_on_pressed)


func setup(resource_name: String, resource_path: String, icons: Array = [], state: Variant = LtsComponentState.DEFAULT) -> LtsResourceRow:
	_resource_name = resource_name
	_resource_path = resource_path
	_icon_names = icons.duplicate()
	_state = LtsComponentState.normalize(state)
	_apply_state()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func set_host_blocked(blocked: bool) -> void:
	_blocked_by_host = blocked
	_apply_state()


func _on_pressed() -> void:
	if disabled:
		return
	resource_activated.emit()


func _apply_state() -> void:
	var normalized := LtsComponentState.normalize(_state)
	var status := ""
	match normalized:
		LtsComponentState.LOADING:
			status = " [Loading...]"
		LtsComponentState.EMPTY:
			status = " [No resource]"
		LtsComponentState.ERROR:
			status = " [Error LTS-RESOURCE-001]"
		LtsComponentState.DISABLED:
			status = " [Read-only]"
		_:
			status = ""
	text = _resource_name + status
	tooltip_text = _resource_path
	button_pressed = normalized == LtsComponentState.ACTIVE
	toggle_mode = normalized == LtsComponentState.ACTIVE
	disabled = _blocked_by_host or normalized == LtsComponentState.DISABLED or normalized == LtsComponentState.LOADING
	if _icon_names.is_empty():
		icon = LtsComponentTheme.state_icon(self, normalized)
	else:
		icon = LtsComponentTheme.resolve_icon(self, _icon_names, LtsComponentState.icon_name(normalized))
	LtsComponentTheme.preview_style(self, normalized, &"normal", &"Button")
