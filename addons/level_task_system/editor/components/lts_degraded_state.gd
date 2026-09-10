@tool
class_name LtsDegradedState
extends PanelContainer

## Bounded read-only native-extension diagnostic. It is safe to construct in
## a headless process and never exposes semantic mutation controls.

signal refresh_requested
signal copy_requested

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")
const CommandButtonScript := preload("res://addons/level_task_system/editor/components/lts_command_button.gd")

var _title_text := "Native extension unavailable"
var _guidance := "Build and load the Level Task System GDExtension to enable authoring."
var _details := "Detected class: LevelTaskSystemVersion | code: LTS-NATIVE-001"
var _state: StringName = LtsComponentState.ERROR
var _refresh_button
var _copy_button
var _icon: TextureRect
var _status: Label
var _details_label: Label
var _built := false


func _init() -> void:
	theme_type_variation = &"LevelTaskEmptyState"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	_build()


func setup(title_text: String, guidance_text: String, details_text: String, state: Variant = LtsComponentState.ERROR):
	_title_text = title_text
	_guidance = guidance_text
	_details = details_text
	_state = LtsComponentState.normalize(state)
	_build()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_apply_state()


func get_state() -> StringName:
	return _state


func is_read_only() -> bool:
	return true


func _build() -> void:
	if not _built and not is_inside_tree():
		return
	if _refresh_button != null:
		return
	var column := VBoxContainer.new()
	column.name = "DegradedColumn"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(column)
	_icon = TextureRect.new()
	_icon.name = "DiagnosticIcon"
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.tooltip_text = "Native extension status"
	column.add_child(_icon)
	var title := Label.new()
	title.name = "DiagnosticTitle"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = _title_text
	title.tooltip_text = _title_text
	column.add_child(title)
	_status = Label.new()
	_status.name = "ReadOnlyStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_status)
	var guidance := Label.new()
	guidance.name = "BuildGuidance"
	guidance.text = _guidance
	guidance.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	guidance.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	guidance.tooltip_text = _guidance
	column.add_child(guidance)
	_details_label = Label.new()
	_details_label.name = "DiagnosticDetails"
	_details_label.text = _details
	_details_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_details_label.tooltip_text = _details
	column.add_child(_details_label)
	var actions := HBoxContainer.new()
	actions.name = "DiagnosticActions"
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(actions)
	_refresh_button = CommandButtonScript.new()
	_refresh_button.name = "Refresh"
	_refresh_button.call("setup", "Refresh", [&"Reload", &"Refresh"], "Reload the native extension")
	_refresh_button.connect("command_requested", _on_refresh)
	actions.add_child(_refresh_button)
	_copy_button = CommandButtonScript.new()
	_copy_button.name = "CopyDetails"
	_copy_button.call("setup", "Copy details", [&"Copy"], "Copy diagnostic details")
	_copy_button.connect("command_requested", _on_copy)
	actions.add_child(_copy_button)
	_apply_state()


func _on_refresh() -> void:
	refresh_requested.emit()


func _on_copy() -> void:
	copy_requested.emit()


func _apply_state() -> void:
	if _refresh_button == null:
		return
	var normalized := LtsComponentState.normalize(_state)
	var status_text := "Read-only"
	match normalized:
		LtsComponentState.DEFAULT:
			status_text = "Ready for extension check"
		LtsComponentState.HOVER:
			status_text = "Recovery action highlighted"
		LtsComponentState.ACTIVE:
			status_text = "Recovery action selected"
		LtsComponentState.FOCUS:
			status_text = "Keyboard focus: recovery available"
		LtsComponentState.DISABLED:
			status_text = "Read-only: refresh unavailable"
		LtsComponentState.LOADING:
			status_text = "Loading native extension..."
		LtsComponentState.EMPTY:
			status_text = "No native status reported"
		LtsComponentState.ERROR:
			status_text = "Error LTS-NATIVE-001: authoring disabled"
	_status.text = status_text
	_status.tooltip_text = status_text
	LtsComponentTheme.apply_state_text(_status, normalized, status_text)
	_icon.texture = LtsComponentTheme.state_icon(self, normalized)
	_refresh_button.call("set_state", normalized)
	_copy_button.call("set_state", normalized)
	# A degraded surface always keeps mutation controls unavailable. Copying
	# and refreshing are diagnostic actions, not document mutations.
	_copy_button.disabled = false if normalized != LtsComponentState.DISABLED else true
	LtsComponentTheme.preview_style(self, normalized, &"panel", &"PanelContainer")
