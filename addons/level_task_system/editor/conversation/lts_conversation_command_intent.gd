@tool
class_name LtsConversationCommandIntent
extends RefCounted

## A serializable authoring intent for one conversation edit.
##
## The intent is deliberately separate from the document command.  Views can
## describe what the author meant (speaker, line, choice, condition, action,
## or outcome) while the existing document model remains the only authority
## that applies and inverts the resulting command.

const DocumentCommand := preload("res://addons/level_task_system/editor/document/lts_document_command.gd")

const EDIT_SPEAKER := "conversation.speaker.set"
const EDIT_LINE := "conversation.line.set"
const EDIT_CHOICE := "conversation.choice.set"
const EDIT_CONDITION := "conversation.condition.set"
const EDIT_ACTION := "conversation.action.set"
const EDIT_OUTCOME := "conversation.outcome.set"
const EDIT_STEP := "conversation.step.set"
const EDIT_ENTRY := "conversation.entry.set"
const EDIT_TERMINAL_OUTCOMES := "conversation.terminal_outcomes.set"
const ADD_STEP := "conversation.step.add"
const REMOVE_STEP := "conversation.step.remove"
const ADD_CHOICE := "conversation.choice.add"
const REMOVE_CHOICE := "conversation.choice.remove"

const STEP_FIELDS: PackedStringArray = [
	"identifier", "kind", "speaker_identifier", "line_key", "parameters",
	"next_step_identifier", "provider_identifier", "conditions",
	"true_step_identifier", "false_step_identifier", "success_step_identifier",
	"failure_step_identifier", "choices", "target_step_identifier",
	"outcome_identifier",
]
const CHOICE_FIELDS: PackedStringArray = [
	"identifier", "label_key", "target_step_identifier", "conditions",
]

var intent: String = ""
var document_identifier: String = ""
var step_identifier: String = ""
var choice_identifier: String = ""
var field_path: Array = []
var value: Variant = null
var description: String = ""
var _command_data: Dictionary = {}


func _init(source: Variant = null) -> void:
	if not source is Dictionary:
		return
	var data: Dictionary = source
	intent = String(data.get("intent", data.get("type", "")))
	document_identifier = String(data.get("document_identifier", data.get("conversation_identifier", "")))
	step_identifier = String(data.get("step_identifier", ""))
	choice_identifier = String(data.get("choice_identifier", ""))
	field_path = data.get("field_path", []).duplicate(true) if data.get("field_path", []) is Array else []
	value = data.get("value", null)
	description = String(data.get("description", ""))
	var command = data.get("command", {})
	if command is Dictionary:
		_command_data = command.duplicate(true)


static func edit_speaker(conversation_identifier: String, step_identifier: String, speaker_identifier: String):
	return _step_field(EDIT_SPEAKER, conversation_identifier, step_identifier, "speaker_identifier", speaker_identifier, "Set speaker")


static func edit_line(conversation_identifier: String, step_identifier: String, line_key: String):
	return _step_field(EDIT_LINE, conversation_identifier, step_identifier, "line_key", line_key, "Set localization key")


static func edit_line_next(conversation_identifier: String, step_identifier: String, next_step_identifier: String):
	return _step_field(EDIT_LINE, conversation_identifier, step_identifier, "next_step_identifier", next_step_identifier, "Set next step")


static func edit_choice(conversation_identifier: String, step_identifier: String, choice_identifier: String, field_name: String, field_value: Variant):
	if not CHOICE_FIELDS.has(field_name):
		return _invalid("Choice field is not part of the canonical definition: %s" % field_name)
	var command = DocumentCommand.set_choice_field(conversation_identifier, step_identifier, choice_identifier, field_name, field_value)
	return _new_intent(EDIT_CHOICE, conversation_identifier, step_identifier, choice_identifier, ["steps", step_identifier, "choices", choice_identifier, field_name], field_value, command, "Edit choice %s" % field_name)


static func edit_choice_label(conversation_identifier: String, step_identifier: String, choice_identifier: String, label_key: String):
	return edit_choice(conversation_identifier, step_identifier, choice_identifier, "label_key", label_key)


static func edit_choice_target(conversation_identifier: String, step_identifier: String, choice_identifier: String, target_step_identifier: String):
	return edit_choice(conversation_identifier, step_identifier, choice_identifier, "target_step_identifier", target_step_identifier)


static func edit_condition(conversation_identifier: String, step_identifier: String, conditions: Array, choice_identifier: String = ""):
	if choice_identifier.is_empty():
		return _step_field(EDIT_CONDITION, conversation_identifier, step_identifier, "conditions", conditions, "Set step conditions")
	var command = DocumentCommand.set_choice_field(conversation_identifier, step_identifier, choice_identifier, "conditions", conditions)
	return _new_intent(EDIT_CONDITION, conversation_identifier, step_identifier, choice_identifier, ["steps", step_identifier, "choices", choice_identifier, "conditions"], conditions, command, "Set choice conditions")


static func edit_condition_field(conversation_identifier: String, step_identifier: String, condition_index: int, field_name: String, field_value: Variant, choice_identifier: String = ""):
	var path: Array
	var command
	if choice_identifier.is_empty():
		path = ["steps", step_identifier, "conditions", str(condition_index), field_name]
		command = DocumentCommand.set_field("conversation", conversation_identifier, path, field_value)
	else:
		path = ["steps", step_identifier, "choices", choice_identifier, "conditions", str(condition_index), field_name]
		command = DocumentCommand.set_field("conversation", conversation_identifier, path, field_value)
	return _new_intent(EDIT_CONDITION, conversation_identifier, step_identifier, choice_identifier, path, field_value, command, "Edit condition %s" % field_name)


static func edit_action(conversation_identifier: String, step_identifier: String, field_name: String, field_value: Variant):
	if field_name not in ["provider_identifier", "success_step_identifier", "failure_step_identifier"]:
		return _invalid("Action field is not part of the canonical definition: %s" % field_name)
	return _step_field(EDIT_ACTION, conversation_identifier, step_identifier, field_name, field_value, "Edit action %s" % field_name)


static func edit_action_provider(conversation_identifier: String, step_identifier: String, provider_identifier: String):
	return edit_action(conversation_identifier, step_identifier, "provider_identifier", provider_identifier)


static func edit_action_success(conversation_identifier: String, step_identifier: String, success_step_identifier: String):
	return edit_action(conversation_identifier, step_identifier, "success_step_identifier", success_step_identifier)


static func edit_action_failure(conversation_identifier: String, step_identifier: String, failure_step_identifier: String):
	return edit_action(conversation_identifier, step_identifier, "failure_step_identifier", failure_step_identifier)


static func edit_outcome(conversation_identifier: String, step_identifier: String, outcome_identifier: String):
	return _step_field(EDIT_OUTCOME, conversation_identifier, step_identifier, "outcome_identifier", outcome_identifier, "Set terminal outcome")


static func edit_step_field(conversation_identifier: String, step_identifier: String, field_name: String, field_value: Variant):
	if not STEP_FIELDS.has(field_name):
		return _invalid("Step field is not part of the canonical definition: %s" % field_name)
	return _step_field(EDIT_STEP, conversation_identifier, step_identifier, field_name, field_value, "Edit step %s" % field_name)


static func set_entry_label(conversation_identifier: String, entry_label: String):
	var command = DocumentCommand.set_field("conversation", conversation_identifier, ["entry_label"], entry_label)
	return _new_intent(EDIT_ENTRY, conversation_identifier, "", "", ["entry_label"], entry_label, command, "Set entry label")


static func set_terminal_outcomes(conversation_identifier: String, outcomes: Array):
	var command = DocumentCommand.set_field("conversation", conversation_identifier, ["terminal_outcomes"], outcomes)
	return _new_intent(EDIT_TERMINAL_OUTCOMES, conversation_identifier, "", "", ["terminal_outcomes"], outcomes, command, "Set terminal outcomes")


static func add_step(conversation_identifier: String, step: Dictionary, index: int = -1):
	var command = DocumentCommand.add_conversation_step(conversation_identifier, step)
	var data = _new_intent(ADD_STEP, conversation_identifier, String(step.get("identifier", "")), "", ["steps"], step, command, "Add conversation step")
	if index >= 0:
		data._command_data["payload"]["index"] = index
	return data


static func remove_step(conversation_identifier: String, step_identifier: String):
	var command = DocumentCommand.remove_conversation_step(conversation_identifier, step_identifier)
	return _new_intent(REMOVE_STEP, conversation_identifier, step_identifier, "", ["steps", step_identifier], null, command, "Remove conversation step")


static func add_choice(conversation_identifier: String, step_identifier: String, choice: Dictionary, index: int = -1):
	var command = DocumentCommand.add_conversation_choice(conversation_identifier, step_identifier, choice)
	var data = _new_intent(ADD_CHOICE, conversation_identifier, step_identifier, String(choice.get("identifier", "")), ["steps", step_identifier, "choices"], choice, command, "Add conversation choice")
	if index >= 0:
		data._command_data["payload"]["index"] = index
	return data


static func remove_choice(conversation_identifier: String, step_identifier: String, choice_identifier: String):
	var command = DocumentCommand.remove_conversation_choice(conversation_identifier, step_identifier, choice_identifier)
	return _new_intent(REMOVE_CHOICE, conversation_identifier, step_identifier, choice_identifier, ["steps", step_identifier, "choices", choice_identifier], null, command, "Remove conversation choice")


func to_command():
	if _command_data.is_empty():
		return null
	return DocumentCommand.from_dict(_command_data)


func command_data() -> Dictionary:
	return _command_data.duplicate(true)


func apply_to(model: Object) -> Dictionary:
	var command = to_command()
	if command == null or model == null or not model.has_method("apply_command"):
		return {
			"ok": false,
			"applied": false,
			"error": {"code": "LTS-CONVERSATION-INTENT-001", "path": "conversation", "severity": "error", "message": "Intent has no applicable document command"},
		}
	return model.call("apply_command", command)


func to_dict() -> Dictionary:
	return {
		"schema_version": 1,
		"intent": intent,
		"document_identifier": document_identifier,
		"step_identifier": step_identifier,
		"choice_identifier": choice_identifier,
		"field_path": field_path.duplicate(true),
		"value": value.duplicate(true) if value is Array or value is Dictionary else value,
		"description": description,
		"command": _command_data.duplicate(true),
	}


func serialize() -> Dictionary:
	return to_dict()


func to_json() -> String:
	return JSON.stringify(to_dict())


func is_valid() -> bool:
	return not intent.is_empty() and not document_identifier.is_empty() and not _command_data.is_empty()


static func from_dict(data: Dictionary):
	return LtsConversationCommandIntent.new(data)


static func _step_field(intent_name: String, conversation_identifier: String, step_identifier: String, field_name: String, field_value: Variant, description_text: String):
	if not STEP_FIELDS.has(field_name):
		return _invalid("Step field is not part of the canonical definition: %s" % field_name)
	var command = DocumentCommand.set_step_field(conversation_identifier, step_identifier, field_name, field_value)
	return _new_intent(intent_name, conversation_identifier, step_identifier, "", ["steps", step_identifier, field_name], field_value, command, description_text)


static func _new_intent(intent_name: String, conversation_identifier: String, step_identifier: String, choice_identifier: String, path: Array, field_value: Variant, command, description_text: String):
	var data := LtsConversationCommandIntent.new()
	data.intent = intent_name
	data.document_identifier = conversation_identifier
	data.step_identifier = step_identifier
	data.choice_identifier = choice_identifier
	data.field_path = path.duplicate(true)
	data.value = field_value.duplicate(true) if field_value is Array or field_value is Dictionary else field_value
	data.description = description_text
	data._command_data = command.to_dict() if command is Object and command.has_method("to_dict") else command.duplicate(true) if command is Dictionary else {}
	return data


static func _invalid(message: String):
	var data := LtsConversationCommandIntent.new()
	data.description = message
	return data
