@tool
class_name LtsConversationTimeline
extends VBoxContainer

## Timeline projection for a conversation definition.
##
## This control renders the projection it receives and emits intents for the
## authoring shell.  It never edits a Resource or keeps a canonical step
## graph.  All fields remain visible, including branch targets and diagnostic
## paths, so color is not required to understand the conversation.

signal step_selected(step_identifier: String)
signal choice_selected(step_identifier: String, choice_identifier: String)
signal command_intent_requested(intent_data: Dictionary)
signal add_step_requested(step_kind: int)
signal remove_step_requested(step_identifier: String)
signal add_choice_requested(step_identifier: String)
signal remove_choice_requested(step_identifier: String, choice_identifier: String)

const ConversationProjection := preload("res://addons/level_task_system/editor/conversation/lts_conversation_projection.gd")
const Intent := preload("res://addons/level_task_system/editor/conversation/lts_conversation_command_intent.gd")
const ThemeHelper := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _projection: Dictionary = {}
var _selection: Dictionary = {}
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


func set_projection(projection: Dictionary) -> LtsConversationTimeline:
	_projection = projection.duplicate(true)
	_selection = _projection.get("selection", {}).duplicate(true) if _projection.get("selection", {}) is Dictionary else {}
	_read_only = bool(_projection.get("read_only", false))
	if _built:
		_render()
	return self


func get_projection() -> Dictionary:
	return _projection.duplicate(true)


func set_read_only(value: bool, reason: String = "") -> void:
	_read_only = value
	if reason.is_empty():
		return
	tooltip_text = reason
	if _built:
		_render()


func is_read_only() -> bool:
	return _read_only


func select_step(step_identifier: String) -> void:
	step_selected.emit(step_identifier)


func select_choice(step_identifier: String, choice_identifier: String) -> void:
	choice_selected.emit(step_identifier, choice_identifier)


func request_add_step(step_kind: int = ConversationProjection.STEP_LINE) -> void:
	if _read_only:
		return
	add_step_requested.emit(step_kind)


func request_remove_step(step_identifier: String) -> void:
	if _read_only:
		return
	remove_step_requested.emit(step_identifier)


func request_add_choice(step_identifier: String) -> void:
	if _read_only:
		return
	add_choice_requested.emit(step_identifier)


func request_remove_choice(step_identifier: String, choice_identifier: String) -> void:
	if _read_only:
		return
	remove_choice_requested.emit(step_identifier, choice_identifier)


func _build_shell() -> void:
	if _body != null:
		return
	var command_bar := HBoxContainer.new()
	command_bar.name = "TimelineCommandBar"
	add_child(command_bar)
	_header_label = Label.new()
	_header_label.name = "TimelineHeading"
	_header_label.text = "Conversation timeline"
	_header_label.tooltip_text = _header_label.text
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	command_bar.add_child(_header_label)
	var add_button := Button.new()
	add_button.name = "AddStep"
	add_button.text = "Add line"
	add_button.tooltip_text = "Add a line step to this conversation"
	add_button.icon = ThemeHelper.resolve_icon(add_button, [&"Add", &"CreateNew", &"Plus"], &"Add")
	add_button.focus_mode = Control.FOCUS_ALL
	add_button.pressed.connect(func() -> void: request_add_step(ConversationProjection.STEP_LINE))
	command_bar.add_child(add_button)
	_scroll = ScrollContainer.new()
	_scroll.name = "TimelineScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.name = "TimelineBody"
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override(&"separation", ThemeHelper.theme_separation(self, &"VBoxContainer"))
	_scroll.add_child(_body)


func _render() -> void:
	if not _built or _body == null:
		return
	for child in _body.get_children():
		child.free()
	var steps: Array = _projection.get("steps", []) if _projection.get("steps", []) is Array else []
	if steps.is_empty():
		var empty_label := Label.new()
		empty_label.name = "TimelineEmpty"
		empty_label.text = "No conversation steps. Add a line to begin the structured definition."
		empty_label.tooltip_text = empty_label.text
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(empty_label)
		return
	for step_value in steps:
		if step_value is Dictionary:
			_body.add_child(_build_step_card(step_value))


func _build_step_card(step: Dictionary) -> Control:
	var step_identifier := String(step.get("identifier", ""))
	var kind := String(step.get("kind", "unknown"))
	var card := PanelContainer.new()
	card.name = "Step_%s" % _safe_name(step_identifier)
	card.theme_type_variation = &"LevelTaskDrawer"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tooltip_text = ConversationProjection.step_summary(step, kind)
	var column := VBoxContainer.new()
	column.name = "StepColumn"
	card.add_child(column)
	var header := HBoxContainer.new()
	header.name = "StepHeader"
	column.add_child(header)
	var select_button := Button.new()
	select_button.name = "SelectStep"
	select_button.text = "%02d  %s  ·  %s" % [int(step.get("index", 0)) + 1, String(step.get("kind_label", "Step")), step_identifier]
	select_button.tooltip_text = "Select step %s" % step_identifier
	select_button.icon = ThemeHelper.resolve_icon(select_button, _step_icons(kind), &"Node")
	select_button.focus_mode = Control.FOCUS_ALL
	select_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_button.button_pressed = bool(step.get("selected", false))
	select_button.toggle_mode = true
	select_button.pressed.connect(func() -> void: select_step(step_identifier))
	header.add_child(select_button)
	var status := _status_label(step.get("findings", []))
	header.add_child(status)
	var remove_button := Button.new()
	remove_button.name = "RemoveStep"
	remove_button.text = "Remove"
	remove_button.tooltip_text = "Remove step %s" % step_identifier
	remove_button.icon = ThemeHelper.resolve_icon(remove_button, [&"Remove", &"Delete"], &"Remove")
	remove_button.focus_mode = Control.FOCUS_ALL
	remove_button.disabled = _read_only
	remove_button.pressed.connect(func() -> void: request_remove_step(step_identifier))
	header.add_child(remove_button)
	var summary := Label.new()
	summary.name = "StepSummary"
	summary.text = String(step.get("summary", ""))
	summary.tooltip_text = summary.text
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(summary)

	match kind:
		"line":
			_add_field(column, "Speaker identifier", String(step.get("speaker_identifier", "")), step_identifier, "", "speaker_identifier", _intent_kind(kind, "speaker_identifier"))
			_add_field(column, "Localization key", String(step.get("line_key", "")), step_identifier, "", "line_key", _intent_kind(kind, "line_key"))
			_add_field(column, "Next step", String(step.get("next_step_identifier", "")), step_identifier, "", "next_step_identifier", _intent_kind(kind, "next_step_identifier"))
		"choice":
			_add_choices(column, step)
		"condition":
			_add_field(column, "Condition provider", String(step.get("provider_identifier", "")), step_identifier, "", "provider_identifier", "step")
			_add_conditions(column, step_identifier, step.get("conditions", []), "")
			_add_field(column, "True branch", _branch_target(step, "true_step_identifier"), step_identifier, "", "true_step_identifier", "step")
			_add_field(column, "False branch", _branch_target(step, "false_step_identifier"), step_identifier, "", "false_step_identifier", "step")
		"action":
			_add_field(column, "Action provider", String(step.get("provider_identifier", "")), step_identifier, "", "provider_identifier", _intent_kind(kind, "provider_identifier"))
			_add_field(column, "Success branch", _branch_target(step, "success_step_identifier"), step_identifier, "", "success_step_identifier", _intent_kind(kind, "success_step_identifier"))
			_add_field(column, "Failure branch", _branch_target(step, "failure_step_identifier"), step_identifier, "", "failure_step_identifier", _intent_kind(kind, "failure_step_identifier"))
		"jump":
			_add_field(column, "Jump target", _branch_target(step, "target_step_identifier"), step_identifier, "", "target_step_identifier", "step")
		"outcome":
			_add_field(column, "Terminal outcome", String(step.get("outcome_identifier", "")), step_identifier, "", "outcome_identifier", _intent_kind(kind, "outcome_identifier"))
	return card


func _add_choices(column: VBoxContainer, step: Dictionary) -> void:
	var step_identifier := String(step.get("identifier", ""))
	var choices: Array = step.get("choices", []) if step.get("choices", []) is Array else []
	var heading := Label.new()
	heading.name = "ChoicesHeading"
	heading.text = "Choices (%d)" % choices.size()
	heading.tooltip_text = "Branching choices for step %s" % step_identifier
	column.add_child(heading)
	for choice_value in choices:
		if not choice_value is Dictionary:
			continue
		var choice: Dictionary = choice_value
		var choice_identifier := String(choice.get("identifier", ""))
		var choice_panel := PanelContainer.new()
		choice_panel.name = "Choice_%s" % _safe_name(choice_identifier)
		choice_panel.theme_type_variation = &"LevelTaskGraphNode"
		choice_panel.tooltip_text = "Choice %s" % choice_identifier
		var choice_column := VBoxContainer.new()
		choice_panel.add_child(choice_column)
		var choice_header := HBoxContainer.new()
		choice_column.add_child(choice_header)
		var choice_button := Button.new()
		choice_button.name = "SelectChoice"
		choice_button.text = "Choice  ·  %s" % choice_identifier
		choice_button.tooltip_text = "Select choice %s" % choice_identifier
		choice_button.icon = ThemeHelper.resolve_icon(choice_button, [&"Branch", &"ArrowRight"], &"Node")
		choice_button.focus_mode = Control.FOCUS_ALL
		choice_button.toggle_mode = true
		choice_button.button_pressed = bool(choice.get("selected", false))
		choice_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		choice_button.pressed.connect(func() -> void: select_choice(step_identifier, choice_identifier))
		choice_header.add_child(choice_button)
		var choice_findings := _status_label(choice.get("findings", []))
		choice_header.add_child(choice_findings)
		var remove_choice := Button.new()
		remove_choice.name = "RemoveChoice"
		remove_choice.text = "Remove"
		remove_choice.tooltip_text = "Remove choice %s" % choice_identifier
		remove_choice.icon = ThemeHelper.resolve_icon(remove_choice, [&"Remove", &"Delete"], &"Remove")
		remove_choice.focus_mode = Control.FOCUS_ALL
		remove_choice.disabled = _read_only
		remove_choice.pressed.connect(func() -> void: request_remove_choice(step_identifier, choice_identifier))
		choice_header.add_child(remove_choice)
		_add_field(choice_column, "Choice localization key", String(choice.get("label_key", "")), step_identifier, choice_identifier, "label_key", "choice")
		_add_field(choice_column, "Target step", String(choice.get("target_step_identifier", "")), step_identifier, choice_identifier, "target_step_identifier", "choice")
		_add_conditions(choice_column, step_identifier, choice.get("conditions", []), choice_identifier)
		column.add_child(choice_panel)
	var add_choice := Button.new()
	add_choice.name = "AddChoice"
	add_choice.text = "Add choice"
	add_choice.tooltip_text = "Add a choice to step %s" % step_identifier
	add_choice.icon = ThemeHelper.resolve_icon(add_choice, [&"Add", &"CreateNew", &"Branch"], &"Add")
	add_choice.focus_mode = Control.FOCUS_ALL
	add_choice.disabled = _read_only
	add_choice.pressed.connect(func() -> void: request_add_choice(step_identifier))
	column.add_child(add_choice)


func _add_conditions(column: VBoxContainer, step_identifier: String, conditions_value: Variant, choice_identifier: String) -> void:
	var conditions: Array = conditions_value if conditions_value is Array else []
	var heading := Label.new()
	heading.name = "ConditionsHeading"
	heading.text = "Conditions (%d)" % conditions.size()
	heading.tooltip_text = "Structured fact predicates; edits are emitted as canonical condition commands"
	column.add_child(heading)
	for index in conditions.size():
		var condition: Dictionary = conditions[index] if conditions[index] is Dictionary else {}
		var row := HBoxContainer.new()
		row.name = "Condition_%d" % index
		var provider := _condition_field("Provider", String(condition.get("provider_identifier", "")), step_identifier, choice_identifier, index, "provider_identifier", condition)
		row.add_child(provider)
		var fact := _condition_field("Fact", String(condition.get("fact_identifier", "")), step_identifier, choice_identifier, index, "fact_identifier", condition)
		row.add_child(fact)
		var comparator := OptionButton.new()
		comparator.name = "Comparator"
		comparator.tooltip_text = "Condition comparator"
		comparator.focus_mode = Control.FOCUS_ALL
		for label in ["==", "!=", ">", ">=", "<", "<="]:
			comparator.add_item(label)
		comparator.select(_comparator_index(condition.get("comparator", 0)))
		comparator.disabled = _read_only
		comparator.item_selected.connect(func(selected: int) -> void: _emit_condition_field(step_identifier, choice_identifier, index, "comparator", selected, condition))
		row.add_child(comparator)
		var expected := Label.new()
		expected.name = "Expected"
		expected.text = "expected: %s" % _value_text(condition.get("expected", null))
		expected.tooltip_text = "Expected value is structured; use the contextual Inspector to edit its type safely."
		expected.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		expected.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(expected)
		column.add_child(row)


func _condition_field(label_text: String, value_text: String, step_identifier: String, choice_identifier: String, index: int, field_name: String, condition: Dictionary) -> LineEdit:
	var field := LineEdit.new()
	field.name = label_text
	field.text = value_text
	field.placeholder_text = label_text
	field.tooltip_text = "%s in condition %d" % [label_text, index + 1]
	field.focus_mode = Control.FOCUS_ALL
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.editable = not _read_only
	field.text_submitted.connect(func(value: String) -> void: _emit_condition_field(step_identifier, choice_identifier, index, field_name, value, condition))
	return field


func _emit_condition_field(step_identifier: String, choice_identifier: String, index: int, field_name: String, value: Variant, original: Dictionary) -> void:
	if _read_only:
		return
	var conditions: Array = []
	var steps: Array = _projection.get("document", {}).get("steps", []) if _projection.get("document", {}) is Dictionary else []
	for step_value in steps:
		if not step_value is Dictionary or String(step_value.get("identifier", "")) != step_identifier:
			continue
		if choice_identifier.is_empty():
			conditions = step_value.get("conditions", []).duplicate(true) if step_value.get("conditions", []) is Array else []
		else:
			for choice_value in step_value.get("choices", []) if step_value.get("choices", []) is Array else []:
				if choice_value is Dictionary and String(choice_value.get("identifier", "")) == choice_identifier:
					conditions = choice_value.get("conditions", []).duplicate(true) if choice_value.get("conditions", []) is Array else []
		if not conditions.is_empty() and index >= 0 and index < conditions.size():
			conditions[index] = conditions[index].duplicate(true)
			conditions[index][field_name] = value
			_emit_intent(Intent.edit_condition(String(_projection.get("identifier", "")), step_identifier, conditions, choice_identifier))


func _add_field(column: VBoxContainer, label_text: String, value_text: String, step_identifier: String, choice_identifier: String, field_name: String, field_kind: String) -> void:
	var row := HBoxContainer.new()
	row.name = "Field_%s" % _safe_name(field_name)
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
	field.text_submitted.connect(func(value: String) -> void: _emit_field_intent(step_identifier, choice_identifier, field_name, field_kind, value))
	row.add_child(field)
	column.add_child(row)


func _emit_field_intent(step_identifier: String, choice_identifier: String, field_name: String, field_kind: String, value: String) -> void:
	if _read_only:
		return
	var conversation_identifier := String(_projection.get("identifier", ""))
	var intent
	if field_kind == "speaker":
		intent = Intent.edit_speaker(conversation_identifier, step_identifier, value)
	elif field_kind == "line":
		intent = Intent.edit_line(conversation_identifier, step_identifier, value)
	elif field_kind == "choice":
		intent = Intent.edit_choice(conversation_identifier, step_identifier, choice_identifier, field_name, value)
	elif field_kind == "action":
		intent = Intent.edit_action(conversation_identifier, step_identifier, field_name, value)
	elif field_kind == "outcome":
		intent = Intent.edit_outcome(conversation_identifier, step_identifier, value)
	else:
		intent = Intent.edit_step_field(conversation_identifier, step_identifier, field_name, value)
	_emit_intent(intent)


func _emit_intent(intent) -> void:
	if intent == null or not intent.has_method("to_dict"):
		return
	command_intent_requested.emit(intent.to_dict())


func _status_label(findings_value: Variant) -> Label:
	var findings: Array = findings_value if findings_value is Array else []
	var label := Label.new()
	label.name = "ValidationStatus"
	if findings.is_empty():
		label.text = "Ready"
		label.tooltip_text = "No local validation findings"
	else:
		var first: Dictionary = findings[0] if findings[0] is Dictionary else {}
		label.text = "Error %s" % String(first.get("code", "LTS-CONVERSATION"))
		label.tooltip_text = "%s · %s" % [String(first.get("message", "Validation finding")), String(first.get("path", "conversation"))]
	return label


func _step_icons(kind: String) -> Array:
	match kind:
		"line": return [&"Dialog", &"Chat", &"Script"]
		"choice": return [&"Branch", &"Split", &"Node"]
		"condition": return [&"Branch", &"Split", &"Node"]
		"action": return [&"Link", &"Gear", &"Node"]
		"jump": return [&"ArrowRight", &"Forward", &"Node"]
		"outcome": return [&"Check", &"Flag", &"Node"]
	return [&"Node"]


func _intent_kind(kind: String, field_name: String) -> String:
	if kind == "line":
		if field_name == "speaker_identifier": return "speaker"
		return "line"
	if kind == "action": return "action"
	if kind == "outcome": return "outcome"
	return "step"


func _branch_target(step: Dictionary, field_name: String) -> String:
	return String(step.get(field_name, ""))


func _comparator_index(value: Variant) -> int:
	if value is String:
		var labels := ["==", "!=", ">", ">=", "<", "<="]
		return labels.find(String(value)) if labels.has(String(value)) else 0
	return clampi(int(value), 0, 5)


func _value_text(value: Variant) -> String:
	if value == null:
		return "none"
	if value is Dictionary:
		for key in ["string_value", "text_value", "integer_value", "boolean_value", "fixed_raw"]:
			if value.has(key): return "none" if value[key] == null else "%s" % value[key]
		return JSON.stringify(value)
	return String(value)


func _safe_name(value: String) -> String:
	return value.replace(".", "_").replace("/", "_").replace(" ", "_")
