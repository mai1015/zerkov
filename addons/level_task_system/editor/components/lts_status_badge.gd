@tool
class_name LtsStatusBadge
extends PanelContainer

## Inline status badge. The icon and severity wording deliberately stay
## present when a custom theme has little color separation.

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _label_text := "Ready"
var _state: StringName = LtsComponentState.DEFAULT
var _status_label: Label
var _icon: TextureRect
var _built := false


func _init() -> void:
	theme_type_variation = &"LevelTaskStatusBadge"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	_build()


func setup(label_text: String, state: Variant = LtsComponentState.DEFAULT) -> LtsStatusBadge:
	_label_text = label_text
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
	if _status_label != null:
		_apply_state()
		return
	var row := HBoxContainer.new()
	row.name = "StatusRow"
	add_child(row)
	_icon = TextureRect.new()
	_icon.name = "StatusIcon"
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.tooltip_text = "Status"
	row.add_child(_icon)
	_status_label = Label.new()
	_status_label.name = "StatusText"
	row.add_child(_status_label)
	_apply_state()


func _apply_state() -> void:
	if _status_label == null:
		return
	var normalized := LtsComponentState.normalize(_state)
	var text := _label_text
	match normalized:
		LtsComponentState.HOVER:
			text += " (hover)"
		LtsComponentState.ACTIVE:
			text += " (selected)"
		LtsComponentState.FOCUS:
			text += " (keyboard focus)"
		LtsComponentState.DISABLED:
			text = "Read-only: " + text
		LtsComponentState.LOADING:
			text = "Validating... " + text
		LtsComponentState.EMPTY:
			text = "No runtime activity"
		LtsComponentState.ERROR:
			text = "Error LTS-STATUS-001: " + text
	_status_label.text = text
	_status_label.tooltip_text = text
	_status_label.remove_theme_color_override(&"font_color")
	if normalized == LtsComponentState.ERROR \
			or normalized == LtsComponentState.LOADING \
			or normalized == LtsComponentState.ACTIVE \
			or normalized == LtsComponentState.FOCUS:
		_status_label.add_theme_color_override(&"font_color", LtsComponentTheme.state_color(self, normalized))
	_icon.texture = LtsComponentTheme.state_icon(self, normalized)
	_icon.tooltip_text = text
	LtsComponentTheme.preview_style(self, normalized, &"panel", &"PanelContainer")
