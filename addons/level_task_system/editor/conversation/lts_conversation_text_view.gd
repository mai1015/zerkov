@tool
class_name LtsConversationTextView
extends VBoxContainer

## Structured text/outline projection for the conversation editor.
##
## This intentionally is not a free-form dialogue language.  Every editable
## row maps to a canonical field path and commits through a
## LtsConversationCommandIntent.  The outline therefore preserves stable IDs,
## choices, predicates, branch targets, actions, and outcomes on every mode
## switch.

signal step_selected(step_identifier: String)
signal choice_selected(step_identifier: String, choice_identifier: String)
signal command_intent_requested(intent_data: Dictionary)
signal condition_edit_requested(step_identifier: String, choice_identifier: String)

const ConversationProjection := preload("res://addons/level_task_system/editor/conversation/lts_conversation_projection.gd")
const Intent := preload("res://addons/level_task_system/editor/conversation/lts_conversation_command_intent.gd")
const ThemeHelper := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _projection: Dictionary = {}
var _read_only := false
var _built := false
var _header_label: Label
var _body: VBoxContainer
var _scroll: ScrollContainer


func _init() -> void:
	theme_type_variation = &"LevelTaskDrawer"
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	_built = true
	ThemeHelper.inherit_editor_theme(self)
	_build_shell()
	_render()


func set_projection(projection: Dictionary) -> LtsConversationTextView:
	_projection = projection.duplicate(true)
	_read_only = bool(_projection.get("read_only", false))
	if _built:
		_render()
	return self


func get_projection() -> Dictionary:
	return _projection.duplicate(true)


func set_read_only(value: bool, reason: String = "") -> void:
	_read_only = value
	if not reason.is_empty():
		tooltip_text = reason
	if _built:
		_render()


func is_read_only() -> bool:
	return _read_only


func request_condition_edit(step_identifier: String, choice_identifier: String = "") -> void:
	condition_edit_requested.emit(step_identifier, choice_identifier)


func _build_shell() -> void:
	if _body != null:
		return
	var command_bar := HBoxContainer.new()
	command_bar.name = "TextCommandBar"
	add_child(command_bar)
	_header_label = Label.new()
	_header_label.name = "TextHeading"
	_header_label.text = "Structured text outline"
	_header_label.tooltip_text = "Canonical fields shown in a text-oriented authoring view"
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_bar.add_child(_header_label)
	var hint := Label.new()
	hint.name = "TextModeHint"
	hint.text = "No free-form parser"
	hint.tooltip_text = "Each field is committed as a typed document command; switching modes is lossless."
	command_bar.add_child(hint)
	_scroll = ScrollContainer.new()
	_scroll.name = "TextScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.name = "TextBody"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override(&"separation", ThemeHelper.theme_separation(self, &"VBoxContainer"))
	_scroll.add_child(_body)


func _render() -> void:
	if not _built or _body == null:
		return
	for child in _body.get_children():
		child.free()
	var document: Dictionary = _projection.get("document", {}) if _projection.get("document", {}) is Dictionary else {}
	if document.is_empty():
		var empty := Label.new()
		empty.text = "No conversation selected. Choose a conversation resource to edit its structured definition."
		empty.tooltip_text = empty.text
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(empty)
		return
	_build_metadata(document)
	var rows: Array = _projection.get("text_outline", []) if _projection.get("text_outline", []) is Array else []
	if rows.is_empty():
		var empty_rows := Label.new()
		empty_rows.text = "No structured rows are available for this conversation."
		empty_rows.tooltip_text = empty_rows.text
		_body.add_child(empty_rows)
		return
	for row_value in rows:
		if row_value is Dictionary:
			_body.add_child(_build_row(row_value))


func _build_metadata(document: Dictionary) -> void:
	var metadata := PanelContainer.new()
	metadata.name = "ConversationMetadata"
	metadata.theme_type_variation = &"LevelTaskDrawer"
	var column := VBoxContainer.new()
	metadata.add_child(column)
	var heading := Label.new()
	heading.text = "Definition context"
	heading.tooltip_text = "Metadata remains part of the canonical conversation document"
	column.add_child(heading)
	_add_scalar_field(column, "Entry label", String(document.get("entry_label", "")), "entry_label", "entry")
	var outcomes: Array = document.get("terminal_outcomes", []) if document.get("terminal_outcomes", []) is Array else []
	var outcomes_label := Label.new()
	outcomes_label.text = "Terminal outcomes (%d)" % outcomes.size()
	outcomes_label.tooltip_text = "Named outcomes available to task graph conversation nodes"
	column.add_child(outcomes_label)
	for index in outcomes.size():
		_add_outcome_field(column, index, String(outcomes[index]), outcomes)
	_body.add_child(metadata)


func _add_scalar_field(column: VBoxContainer, label_text: String, value_text: String, field_name: String, field_kind: String) -> void:
	var row := HBoxContainer.new()
	row.name = "Metadata_%s" % field_name
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = label_text
	row.add_child(label)
	var field := LineEdit.new()
	field.name = field_name
	field.text = value_text
	field.placeholder_text = label_text
	field.tooltip_text = "Canonical field %s" % field_name
	field.focus_mode = Control.FOCUS_ALL
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.editable = not _read_only
	field.text_submitted.connect(func(value: String) -> void:
		if _read_only:
			return
		if field_kind == "entry":
			_emit_intent(Intent.set_entry_label(String(_projection.get("identifier", "")), value))
	)
	row.add_child(field)
	column.add_child(row)


func _add_outcome_field(column: VBoxContainer, index: int, value_text: String, outcomes: Array) -> void:
	var row := HBoxContainer.new()
	row.name = "Outcome_%d" % index
	var label := Label.new()
	label.text = "Outcome %d" % (index + 1)
	label.tooltip_text = "Named terminal outcome %d" % (index + 1)
	row.add_child(label)
	var field := LineEdit.new()
	field.name = "OutcomeValue"
	field.text = value_text
	field.placeholder_text = "success"
	field.tooltip_text = "Edit this outcome name without changing step identities"
	field.focus_mode = Control.FOCUS_ALL
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.editable = not _read_only
	field.text_submitted.connect(func(value: String) -> void:
		if _read_only:
			return
		var candidate := outcomes.duplicate(true)
		candidate[index] = value
		_emit_intent(Intent.set_terminal_outcomes(String(_projection.get("identifier", "")), candidate))
	)
	row.add_child(field)
	column.add_child(row)


func _build_row(row: Dictionary) -> Control:
	var role := String(row.get("role", ""))
	if role == "condition":
		return _build_condition_row(row)
	var container := PanelContainer.new()
	container.name = "Row_%s" % _safe_name(String(row.get("row_id", "row")))
	container.theme_type_variation = &"LevelTaskDrawer" if role == "step" else &"LevelTaskGraphNode"
	container.tooltip_text = String(row.get("label", ""))
	var row_box := HBoxContainer.new()
	container.add_child(row_box)
	var depth := int(row.get("depth", 0))
	var prefix := ""
	for _index in depth:
		prefix += "  "
	if role == "step":
		var button := Button.new()
		button.name = "SelectStep"
		button.text = "%s%s  ·  %s" % [prefix, String(row.get("label", "Step")), String(row.get("step_identifier", ""))]
		button.tooltip_text = "Select step %s" % String(row.get("step_identifier", ""))
		button.icon = ThemeHelper.resolve_icon(button, [&"Dialog", &"Branch", &"Node"], &"Node")
		button.focus_mode = Control.FOCUS_ALL
		button.toggle_mode = true
		button.button_pressed = bool(row.get("selected", false))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func() -> void: step_selected.emit(String(row.get("step_identifier", ""))))
		row_box.add_child(button)
		var status := _status_label(row.get("findings", []))
		row_box.add_child(status)
		return container
	if role == "choice":
		var choice_button := Button.new()
		choice_button.name = "SelectChoice"
		choice_button.text = "%s%s" % [prefix, String(row.get("label", "Choice"))]
		choice_button.tooltip_text = "Select choice %s" % String(row.get("element_identifier", ""))
		choice_button.icon = ThemeHelper.resolve_icon(choice_button, [&"Branch", &"ArrowRight"], &"Node")
		choice_button.focus_mode = Control.FOCUS_ALL
		choice_button.toggle_mode = true
		choice_button.button_pressed = bool(row.get("selected", false))
		choice_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choice_button.pressed.connect(func() -> void: choice_selected.emit(String(row.get("step_identifier", "")), String(row.get("element_identifier", ""))))
		row_box.add_child(choice_button)
		row_box.add_child(_status_label(row.get("findings", [])))
		return container
	var label := Label.new()
	label.text = "%s%s" % [prefix, String(row.get("label", "Field"))]
	label.tooltip_text = label.text
	row_box.add_child(label)
	var field := LineEdit.new()
	field.name = "FieldValue"
	field.text = String(row.get("value", ""))
	field.placeholder_text = String(row.get("label", "Value"))
	field.tooltip_text = "Canonical field %s" % String(row.get("field_name", ""))
	field.focus_mode = Control.FOCUS_ALL
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.editable = not _read_only and bool(row.get("editable", false))
	field.text_submitted.connect(func(value: String) -> void: _emit_field_intent(row, value))
	row_box.add_child(field)
	row_box.add_child(_status_label(row.get("findings", [])))
	return container


func _build_condition_row(row: Dictionary) -> Control:
	var container := PanelContainer.new()
	container.name = "Condition_%s" % _safe_name(String(row.get("row_id", "condition")))
	container.theme_type_variation = &"LevelTaskInspectorField"
	container.tooltip_text = "Structured condition predicate; no text parser is used"
	var row_box := HBoxContainer.new()
	container.add_child(row_box)
	var prefix := ""
	for _index in int(row.get("depth", 0)):
		prefix += "  "
	var label := Label.new()
	label.text = "%s%s: %s" % [prefix, String(row.get("label", "Condition")), String(row.get("value", ""))]
	label.tooltip_text = "Conditions are edited as typed predicate data in the contextual Inspector."
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_box.add_child(label)
	var edit := Button.new()
	edit.name = "EditCondition"
	edit.text = "Edit predicate"
	edit.tooltip_text = "Request structured condition editing for this step"
	edit.icon = ThemeHelper.resolve_icon(edit, [&"Edit", &"Inspector"], &"Edit")
	edit.focus_mode = Control.FOCUS_ALL
	edit.disabled = _read_only
	# Condition rows retain the owning choice identifier in `element_identifier`
	# when they belong to a choice.  Forward it so the shell can open the
	# correct typed predicate editor without reparsing the outline row.
	edit.pressed.connect(func() -> void: request_condition_edit(String(row.get("step_identifier", "")), String(row.get("element_identifier", ""))))
	row_box.add_child(edit)
	row_box.add_child(_status_label(row.get("findings", [])))
	return container


func _emit_field_intent(row: Dictionary, value: String) -> void:
	if _read_only:
		return
	var conversation_identifier := String(_projection.get("identifier", ""))
	var step_identifier := String(row.get("step_identifier", ""))
	var choice_identifier := String(row.get("element_identifier", "")) if String(row.get("element_identifier", "")) != step_identifier else ""
	var field_name := String(row.get("field_name", ""))
	var intent
	if not choice_identifier.is_empty() and field_name in ["label_key", "target_step_identifier"]:
		intent = Intent.edit_choice(conversation_identifier, step_identifier, choice_identifier, field_name, value)
	else:
		var kind := _step_kind(step_identifier)
		if kind == "line" and field_name == "speaker_identifier":
			intent = Intent.edit_speaker(conversation_identifier, step_identifier, value)
		elif kind == "line" and field_name in ["line_key", "next_step_identifier"]:
			intent = Intent.edit_line(conversation_identifier, step_identifier, value) if field_name == "line_key" else Intent.edit_line_next(conversation_identifier, step_identifier, value)
		elif kind == "action":
			intent = Intent.edit_action(conversation_identifier, step_identifier, field_name, value)
		elif kind == "outcome" and field_name == "outcome_identifier":
			intent = Intent.edit_outcome(conversation_identifier, step_identifier, value)
		else:
			intent = Intent.edit_step_field(conversation_identifier, step_identifier, field_name, value)
	_emit_intent(intent)


func _step_kind(step_identifier: String) -> String:
	var steps: Array = _projection.get("document", {}).get("steps", []) if _projection.get("document", {}) is Dictionary else []
	for step_value in steps:
		if step_value is Dictionary and String(step_value.get("identifier", "")) == step_identifier:
			return ConversationProjection.kind_name(step_value.get("kind", ConversationProjection.STEP_LINE))
	return ""


func _emit_intent(intent) -> void:
	if intent != null and intent.has_method("to_dict"):
		command_intent_requested.emit(intent.to_dict())


func _status_label(findings_value: Variant) -> Label:
	var findings: Array = findings_value if findings_value is Array else []
	var label := Label.new()
	if findings.is_empty():
		label.text = "Ready"
		label.tooltip_text = "No local validation findings"
	else:
		var first: Dictionary = findings[0] if findings[0] is Dictionary else {}
		label.text = "Error %s" % String(first.get("code", "LTS-CONVERSATION"))
		label.tooltip_text = "%s · %s" % [String(first.get("message", "Validation finding")), String(first.get("path", "conversation"))]
	return label


func _safe_name(value: String) -> String:
	return value.replace(".", "_").replace(":", "_").replace("/", "_").replace(" ", "_")
