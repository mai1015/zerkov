@tool
class_name LtsConversationPreviewModel
extends RefCounted

## Headless conversation-preview runtime used by the editor simulator.
##
## The native `lts::ConversationInstance` is intentionally not ClassDB-bound in
## the current addon release.  This model therefore provides a deterministic,
## bounded adapter over the same canonical dictionary shape used by the
## document projections.  It mirrors the native runtime's yielded frames,
## revision checks, condition semantics, action boundary, and fail-atomic
## traversal.  Definitions and facts are deep-copied on input; preview state
## can never mutate an authored Resource, document model, or live authority.

signal frame_changed(frame: Dictionary)
signal trace_changed(trace: Array)
signal state_changed(status: Dictionary)
signal error_raised(error: Dictionary)
signal restarted(entry_label: String)

const STATE_INACTIVE := "inactive"
const STATE_LINE := "line"
const STATE_CHOICE := "choice"
const STATE_WAITING_FOR_ACTION := "waiting_for_action"
const STATE_TERMINAL := "terminal"
const STATE_ERROR := "error"
const STATE_UNAVAILABLE := "unavailable"

const MODE_DETERMINISTIC_ADAPTER := "deterministic_adapter"
const MODE_NATIVE := "native"

const STEP_LINE := 0
const STEP_CHOICE := 1
const STEP_CONDITION := 2
const STEP_EXTERNAL_ACTION := 3
const STEP_JUMP := 4
const STEP_OUTCOME := 5

const MAX_STEPS := 512
const MAX_CHOICES := 16
const MAX_CONDITIONS := 8
const MAX_FACTS := 256
const MAX_TRACE_RECORDS := 1024
const MAX_PARAMETERS := 8
const MAX_STRING_BYTES := 4096
const DEFAULT_STEP_BUDGET := 1024
const DEFAULT_JUMP_BUDGET := 256
const DEFAULT_TRACE_LIMIT := 256

const COMPARATOR_LABELS := {
	0: "Equal",
	1: "Not equal",
	2: "Less",
	3: "Less or equal",
	4: "Greater",
	5: "Greater or equal",
}

var _definition: Dictionary = {}
var _steps: Dictionary = {}
var _facts_entries: Array = []
var _facts_lookup: Dictionary = {}
var _runtime_adapter: Object = null
var _native_extension_available := true
var _mode := MODE_DETERMINISTIC_ADAPTER
var _configured := false
var _started := false
var _entry_label := ""
var _instance_identifier := "editor.preview.conversation"
var _scope_identifier := "editor.preview"
var _task_integration_handle := ""
var _current_step_identifier := ""
var _frame: Dictionary = {}
var _frame_revision := 0
var _runtime_revision := 0
var _status := STATE_INACTIVE
var _pending_request: Dictionary = {}
var _last_error: Dictionary = {}
var _trace: Array = []
var _transcript: Array = []
var _trace_sequence := 0
var _max_trace_records := DEFAULT_TRACE_LIMIT
var _max_steps_per_advance := DEFAULT_STEP_BUDGET
var _max_jumps_per_advance := DEFAULT_JUMP_BUDGET


func _init(source: Variant = null, facts: Variant = {}, native_extension_available: bool = true) -> void:
	_native_extension_available = native_extension_available
	if source != null:
		bind_definition(source, facts)


## Configure a canonical conversation definition without starting it.
##
## `source` may be a canonical Dictionary, a document-model wrapper, a
## LevelTaskConversationDefinition Resource, or a deterministic test double
## exposing the same getters.  The returned record is intentionally explicit
## so callers can surface malformed content in the findings drawer.
func bind_definition(source: Variant, facts: Variant = {}, entry_label: String = "") -> Dictionary:
	_clear_runtime()
	if not _native_extension_available:
		return _set_configuration_error(_unavailable_error())
	var definition := _coerce_definition(source)
	if definition.is_empty():
		return _set_configuration_error(_diagnostic(
			"LTS-CONVERSATION-PREVIEW-001",
			"Conversation definition is unavailable or has no canonical document.",
			"conversation.definition"
		))
	var findings := validate_definition(definition)
	if not findings.is_empty():
		_definition = definition.duplicate(true)
		_configured = false
		_status = STATE_ERROR
		_last_error = findings[0].duplicate(true)
		error_raised.emit(_last_error.duplicate(true))
		_emit_state()
		return _failure("configure", _last_error)
	_definition = definition.duplicate(true)
	_steps = _index_steps(_definition.get("steps", []))
	_entry_label = entry_label if not entry_label.is_empty() else String(_definition.get("entry_label", ""))
	_max_steps_per_advance = clampi(int(_definition.get("max_steps_per_advance", DEFAULT_STEP_BUDGET)), 1, DEFAULT_STEP_BUDGET)
	_max_jumps_per_advance = clampi(int(_definition.get("max_jumps_per_advance", DEFAULT_JUMP_BUDGET)), 1, DEFAULT_JUMP_BUDGET)
	_max_trace_records = clampi(int(_definition.get("max_trace_records", DEFAULT_TRACE_LIMIT)), 1, MAX_TRACE_RECORDS)
	_configured = true
	_mode = MODE_DETERMINISTIC_ADAPTER
	_last_error = {}
	var facts_result := _normalize_facts(facts)
	if not bool(facts_result.get("ok", false)):
		_configured = false
		_status = STATE_ERROR
		_last_error = facts_result.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-002", "Fact snapshot is invalid.", "conversation.facts"))
		error_raised.emit(_last_error.duplicate(true))
		_emit_state()
		return _failure("configure", _last_error)
	_facts_entries = facts_result.get("entries", []).duplicate(true)
	_facts_lookup = facts_result.get("lookup", {}).duplicate(true)
	_status = STATE_INACTIVE
	_emit_state()
	return {
		"ok": true,
		"configured": true,
		"operation": "configure",
		"identifier": String(_definition.get("identifier", "")),
		"entry_label": _entry_label,
		"mode": _mode,
		"status": get_status(),
	}


func configure(source: Variant, facts: Variant = {}, entry_label: String = "") -> Dictionary:
	return bind_definition(source, facts, entry_label)


func set_definition(source: Variant, facts: Variant = {}, entry_label: String = "") -> Dictionary:
	return bind_definition(source, facts, entry_label)


func load_definition(source: Variant, facts: Variant = {}, entry_label: String = "") -> Dictionary:
	return bind_definition(source, facts, entry_label)


func bind_conversation(source: Variant, facts: Variant = {}, entry_label: String = "") -> Dictionary:
	return bind_definition(source, facts, entry_label)


## Bind a document model or `{documents:{conversations:{...}}}` wrapper by ID.
func bind_document(source: Variant, conversation_identifier: String = "", facts: Variant = {}, entry_label: String = "") -> Dictionary:
	var definition := _coerce_definition(source, conversation_identifier)
	return bind_definition(definition, facts, entry_label)


## Attach an object that follows the ConversationInstance API.  This seam is
## deliberately duck-typed so a future registered native binding can be used
## without changing the preview UI.  The deterministic adapter remains the
## default when no native object is supplied.
func bind_runtime(runtime_instance: Object, definition_source: Variant = null) -> Dictionary:
	if runtime_instance == null or not _native_extension_available:
		return _set_configuration_error(_diagnostic(
			"LTS-CONVERSATION-PREVIEW-NATIVE-001",
			"Native conversation runtime is unavailable; preview is read-only.",
			"conversation.native_runtime"
		))
	if not runtime_instance.has_method("start") and not runtime_instance.has_method("begin"):
		return _set_configuration_error(_diagnostic(
			"LTS-CONVERSATION-PREVIEW-NATIVE-002",
			"Native conversation runtime does not expose a start/begin API.",
			"conversation.native_runtime"
		))
	_runtime_adapter = runtime_instance
	_mode = MODE_NATIVE
	if definition_source != null:
		var configured := bind_definition(definition_source)
		if not bool(configured.get("ok", false)):
			return configured
		_mode = MODE_NATIVE
	_configured = true
	_status = STATE_INACTIVE
	_emit_state()
	return {"ok": true, "mode": _mode, "status": get_status()}


func clear_runtime_adapter() -> void:
	_runtime_adapter = null
	_mode = MODE_DETERMINISTIC_ADAPTER


func set_native_extension_available(available: bool) -> void:
	_native_extension_available = available
	if not available:
		_runtime_adapter = null
		_mode = MODE_DETERMINISTIC_ADAPTER
		_status = STATE_UNAVAILABLE
		_last_error = _diagnostic(
			"LTS-CONVERSATION-PREVIEW-NATIVE-001",
			"Native extension unavailable; conversation preview is disabled until the extension is loaded.",
			"conversation.native_extension"
		)
		error_raised.emit(_last_error.duplicate(true))
	else:
		if _status == STATE_UNAVAILABLE:
			_status = STATE_INACTIVE if _configured else STATE_ERROR
			_last_error = {} if _configured else _last_error
	_emit_state()


func is_native_extension_available() -> bool:
	return _native_extension_available


func has_native_runtime() -> bool:
	return _runtime_adapter != null and is_instance_valid(_runtime_adapter)


func is_available() -> bool:
	return _native_extension_available and _configured


func is_unavailable() -> bool:
	return _status == STATE_UNAVAILABLE or not _native_extension_available


## Start a new isolated run.  The first frame has revision one, matching the
## native ConversationInstance contract.  `entry_label` may select any valid
## local step label without changing the saved definition.
func start(
		instance_identifier: String = "editor.preview.conversation",
		scope_identifier: String = "editor.preview",
		entry_label: String = "",
		task_integration_handle: String = ""
) -> Dictionary:
	if not _native_extension_available:
		return _failure("start", _unavailable_error())
	if not _configured:
		return _failure("start", _last_error if not _last_error.is_empty() else _diagnostic(
			"LTS-CONVERSATION-PREVIEW-003",
			"Conversation definition is not configured.",
			"conversation.definition"
		))
	if _mode == MODE_NATIVE and has_native_runtime():
		return _start_native(instance_identifier, scope_identifier, entry_label, task_integration_handle)
	var selected_entry := entry_label if not entry_label.is_empty() else _entry_label
	if not _steps.has(selected_entry):
		return _failure("start", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-004",
			"Preview entry label does not identify a conversation step.",
			"conversation.entry_label",
			{"entry_label": selected_entry}
		))
	var normalized_instance := instance_identifier.strip_edges()
	var normalized_scope := scope_identifier.strip_edges()
	if normalized_instance.is_empty() or normalized_scope.is_empty():
		return _failure("start", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-005",
			"Preview instance and scope identifiers are required.",
			"conversation.preview_scope"
		))
	var before := _capture_runtime()
	_started = true
	_entry_label = selected_entry
	_instance_identifier = normalized_instance
	_scope_identifier = normalized_scope
	_task_integration_handle = task_integration_handle.strip_edges()
	_current_step_identifier = selected_entry
	_frame_revision = 1
	_runtime_revision = 1
	_status = STATE_LINE
	_pending_request = {}
	_last_error = {}
	_trace.clear()
	_transcript.clear()
	_trace_sequence = 0
	_append_trace({
		"type": "start",
		"operation": "start",
		"entry_label": selected_entry,
		"step_identifier": selected_entry,
		"frame_revision": _frame_revision,
	})
	var process_result := _process_until_yield()
	if not bool(process_result.get("ok", false)):
		_restore_runtime(before)
		return _failure("start", process_result.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-006", "Preview could not start.", "conversation.runtime")))
	_emit_frame()
	return _success("start", true)


func begin(
		instance_identifier: String = "editor.preview.conversation",
		scope_identifier: String = "editor.preview",
		entry_label: String = "",
		task_integration_handle: String = ""
) -> Dictionary:
	return start(instance_identifier, scope_identifier, entry_label, task_integration_handle)


func restart_from_entry(entry_label: String = "") -> Dictionary:
	var selected_entry := entry_label if not entry_label.is_empty() else _entry_label
	var result := start(_instance_identifier, _scope_identifier, selected_entry, _task_integration_handle)
	if bool(result.get("ok", false)):
		restarted.emit(selected_entry)
	return result


func restart(entry_label: String = "") -> Dictionary:
	return restart_from_entry(entry_label)


## Replace the synthetic fact snapshot.  A changed active frame receives a
## new revision; stale choice submissions therefore fail exactly as they do
## against the production runtime. Missing facts never satisfy NOT_EQUAL.
func set_facts(facts: Variant) -> Dictionary:
	var normalized := _normalize_facts(facts)
	if not bool(normalized.get("ok", false)):
		return _failure("set_facts", normalized.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-007", "Fact snapshot is invalid.", "conversation.facts")))
	var new_entries: Array = normalized.get("entries", [])
	var new_lookup: Dictionary = normalized.get("lookup", {})
	if _facts_entries == new_entries and _facts_lookup == new_lookup:
		return _success("set_facts", false)
	var before := _capture_runtime()
	_facts_entries = new_entries.duplicate(true)
	_facts_lookup = new_lookup.duplicate(true)
	if not _started or _status in [STATE_INACTIVE, STATE_ERROR, STATE_UNAVAILABLE]:
		_emit_state()
		return _success("set_facts", true)
	if _status in [STATE_WAITING_FOR_ACTION, STATE_TERMINAL]:
		_append_trace({
			"type": "facts_updated",
			"operation": "set_facts",
			"step_identifier": _current_step_identifier,
			"frame_revision": _frame_revision,
			"changed": true,
		})
		_emit_frame()
		return _success("set_facts", true)
	_frame_revision += 1
	_runtime_revision += 1
	var rebuild := _rebuild_current_frame()
	if not bool(rebuild.get("ok", false)):
		_restore_runtime(before)
		return _failure("set_facts", rebuild.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-008", "Fact update could not rebuild the current frame.", "conversation.frame")))
	_append_trace({
		"type": "facts_updated",
		"operation": "set_facts",
		"step_identifier": _current_step_identifier,
		"frame_revision": _frame_revision,
		"changed": true,
	})
	# A choice prompt is a snapshot of the frame revision.  Re-publish the
	# current prompt after a fact update so the UI has a fresh, selectable
	# revision instead of retaining buttons tied to the stale prompt.
	if _status == STATE_CHOICE:
		_append_transcript({
			"type": "choice_prompt",
			"step_identifier": _current_step_identifier,
			"choices": _array_copy(_frame.get("available_choices", [])),
			"choice_visibility": _array_copy(_frame.get("condition_visibility", [])),
			"frame_revision": _frame_revision,
			"refreshed": true,
		})
	_emit_frame()
	return _success("set_facts", true)


func update_facts(facts: Variant) -> Dictionary:
	return set_facts(facts)


func set_variables(variables: Variant) -> Dictionary:
	return set_facts(variables)


func get_facts() -> Array:
	return _facts_entries.duplicate(true)


func get_variables() -> Dictionary:
	var result: Dictionary = {}
	for entry_value in _facts_entries:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		result[String(entry.get("key", ""))] = entry.get("value", null)
	return result


## Stable fact rows suitable for an Inspector/Tree projection.
func inspect_variables(query: String = "") -> Array:
	var needle := query.strip_edges().to_lower()
	var rows: Array = []
	for entry_value in _facts_entries:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value.duplicate(true)
		var haystack := "%s %s %s" % [String(entry.get("provider_identifier", "")), String(entry.get("fact_identifier", "")), String(entry.get("key", ""))]
		if not needle.is_empty() and haystack.to_lower().find(needle) < 0:
			continue
		rows.append(entry)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("key", "")) < String(b.get("key", ""))
	)
	return rows


func get_variable_inspection(query: String = "") -> Dictionary:
	return {
		"variables": inspect_variables(query),
		"dependencies": get_condition_dependencies(),
		"step_identifier": _current_step_identifier,
		"frame_revision": _frame_revision,
	}


func inspect_facts(query: String = "") -> Array:
	return inspect_variables(query)


func get_condition_dependencies() -> Array:
	var dependencies: Array = []
	var seen: Dictionary = {}
	var visibility := get_condition_visibility()
	for item_value in visibility:
		if not item_value is Dictionary:
			continue
		for evaluation_value in item_value.get("evaluations", []):
			if not evaluation_value is Dictionary:
				continue
			var evaluation: Dictionary = evaluation_value
			var key := String(evaluation.get("key", ""))
			if key.is_empty() or seen.has(key):
				continue
			seen[key] = true
			dependencies.append({
				"key": key,
				"provider_identifier": String(evaluation.get("provider_identifier", "")),
				"fact_identifier": String(evaluation.get("fact_identifier", "")),
				"present": bool(evaluation.get("present", false)),
				"actual": evaluation.get("actual", null),
				"expected": evaluation.get("expected", null),
				"matches": bool(evaluation.get("matches", false)),
			})
	dependencies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("key", "")) < String(b.get("key", ""))
	)
	return dependencies


func get_condition_visibility() -> Array:
	if _frame.is_empty():
		return []
	var value: Variant = _frame.get("condition_visibility", [])
	return value.duplicate(true) if value is Array else []


func get_choice_visibility() -> Array:
	return get_condition_visibility()


func get_available_choices() -> Array:
	if _frame.is_empty():
		return []
	var value: Variant = _frame.get("available_choices", _frame.get("choices", []))
	return value.duplicate(true) if value is Array else []


func can_select_choice(choice_identifier: String, frame_revision: int = -1) -> bool:
	if not _started or _status != STATE_CHOICE:
		return false
	if frame_revision >= 0 and frame_revision != _frame_revision:
		return false
	for choice_value in get_available_choices():
		if choice_value is Dictionary and String(choice_value.get("identifier", "")) == choice_identifier:
			return true
	return false


func select_choice(choice_identifier: String, frame_revision: int = -1) -> Dictionary:
	if not _native_extension_available:
		return _failure("select_choice", _unavailable_error())
	if _mode == MODE_NATIVE and has_native_runtime():
		return _select_choice_native(choice_identifier, frame_revision)
	if not _started or _status != STATE_CHOICE:
		return _failure("select_choice", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-CHOICE-001",
			"Preview is not waiting for a choice.",
			"conversation.choice"
		))
	var expected_revision := _frame_revision if frame_revision < 0 else frame_revision
	if expected_revision != _frame_revision:
		return _failure("select_choice", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-CHOICE-002",
			"Choice belongs to an earlier frame revision.",
			"conversation.frame_revision",
			{"expected_revision": _frame_revision, "received_revision": expected_revision}
		))
	var selected: Dictionary = {}
	var step: Dictionary = _steps.get(_current_step_identifier, {})
	for choice_value in step.get("choices", []):
		if choice_value is Dictionary and String(choice_value.get("identifier", "")) == choice_identifier:
			selected = choice_value
			break
	if selected.is_empty():
		return _failure("select_choice", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-CHOICE-003",
			"Choice identifier is not authored on the current step.",
			"conversation.choice.%s" % choice_identifier
		))
	var evaluation := _evaluate_conditions(selected.get("conditions", []))
	if not bool(evaluation.get("matches", false)):
		return _failure("select_choice", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-CHOICE-004",
			"Choice is hidden by its current conditions.",
			"conversation.choice.%s.conditions" % choice_identifier,
			{"choice_identifier": choice_identifier, "evaluations": evaluation.get("evaluations", [])}
		))
	var target := String(selected.get("target_step_identifier", ""))
	if not _steps.has(target):
		return _failure("select_choice", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-CHOICE-005",
			"Choice target does not exist.",
			"conversation.choice.%s.target_step_identifier" % choice_identifier
		))
	var before := _capture_runtime()
	_append_transcript({
		"type": "choice_selected",
		"choice_identifier": choice_identifier,
		"step_identifier": _current_step_identifier,
		"frame_revision": _frame_revision,
		"label_key": String(selected.get("label_key", "")),
	})
	_append_trace({
		"type": "choice_selected",
		"operation": "select_choice",
		"step_identifier": _current_step_identifier,
		"choice_identifier": choice_identifier,
		"frame_revision": _frame_revision,
		"target_step_identifier": target,
	})
	_current_step_identifier = target
	_frame_revision += 1
	_runtime_revision += 1
	var process_result := _process_until_yield()
	if not bool(process_result.get("ok", false)):
		_restore_runtime(before)
		return _failure("select_choice", process_result.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-CHOICE-006", "Choice target could not be reached.", "conversation.choice")))
	_emit_frame()
	return _success("select_choice", true, {"choice_identifier": choice_identifier})


func choose(choice_identifier: String, frame_revision: int = -1) -> Dictionary:
	return select_choice(choice_identifier, frame_revision)


func continue_line(frame_revision: int = -1) -> Dictionary:
	if not _native_extension_available:
		return _failure("continue_line", _unavailable_error())
	if _mode == MODE_NATIVE and has_native_runtime():
		return _continue_line_native(frame_revision)
	if not _started or _status != STATE_LINE:
		return _failure("continue_line", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-LINE-001",
			"Preview is not waiting for a line continuation.",
			"conversation.line"
		))
	var expected_revision := _frame_revision if frame_revision < 0 else frame_revision
	if expected_revision != _frame_revision:
		return _failure("continue_line", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-LINE-002",
			"Line continuation belongs to an earlier frame revision.",
			"conversation.frame_revision",
			{"expected_revision": _frame_revision, "received_revision": expected_revision}
		))
	var step: Dictionary = _steps.get(_current_step_identifier, {})
	var target := String(step.get("next_step_identifier", ""))
	if target.is_empty() or not _steps.has(target):
		return _failure("continue_line", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-LINE-003",
			"Line continuation target does not exist.",
			"conversation.step.%s.next_step_identifier" % _current_step_identifier
		))
	var before := _capture_runtime()
	_append_trace({
		"type": "line_continued",
		"operation": "continue_line",
		"step_identifier": _current_step_identifier,
		"frame_revision": _frame_revision,
		"target_step_identifier": target,
	})
	_current_step_identifier = target
	_frame_revision += 1
	_runtime_revision += 1
	var process_result := _process_until_yield()
	if not bool(process_result.get("ok", false)):
		_restore_runtime(before)
		return _failure("continue_line", process_result.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-LINE-004", "Line continuation target could not be reached.", "conversation.line")))
	_emit_frame()
	return _success("continue_line", true)


func advance_line(frame_revision: int = -1) -> Dictionary:
	return continue_line(frame_revision)


func continue_frame(frame_revision: int = -1) -> Dictionary:
	return continue_line(frame_revision)


func acknowledge_action(request_identifier: String, success: bool, response: Variant = null) -> Dictionary:
	if not _native_extension_available:
		return _failure("acknowledge_action", _unavailable_error())
	if _mode == MODE_NATIVE and has_native_runtime():
		return _acknowledge_action_native(request_identifier, success, response)
	if not _started or _status != STATE_WAITING_FOR_ACTION or _pending_request.is_empty():
		return _failure("acknowledge_action", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-ACTION-001",
			"Preview has no pending action request.",
			"conversation.action_request"
		))
	if request_identifier != String(_pending_request.get("request_identifier", "")):
		return _failure("acknowledge_action", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-ACTION-002",
			"Action acknowledgement does not match the pending request.",
			"conversation.action_request.request_identifier"
		))
	var step: Dictionary = _steps.get(_current_step_identifier, {})
	var target := String(step.get("success_step_identifier", "") if success else step.get("failure_step_identifier", ""))
	if target.is_empty() or not _steps.has(target):
		return _failure("acknowledge_action", _diagnostic(
			"LTS-CONVERSATION-PREVIEW-ACTION-003",
			"Action acknowledgement target does not exist.",
			"conversation.action_request"
		))
	var before := _capture_runtime()
	_append_trace({
		"type": "action_acknowledged",
		"operation": "acknowledge_action",
		"step_identifier": _current_step_identifier,
		"frame_revision": _frame_revision,
		"request_identifier": request_identifier,
		"success": success,
		"target_step_identifier": target,
		"response": _safe_value(response),
	})
	_pending_request = {}
	_current_step_identifier = target
	_frame_revision += 1
	_runtime_revision += 1
	var process_result := _process_until_yield()
	if not bool(process_result.get("ok", false)):
		_restore_runtime(before)
		return _failure("acknowledge_action", process_result.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-ACTION-004", "Acknowledged action target could not be reached.", "conversation.action_request")))
	_emit_frame()
	return _success("acknowledge_action", true)


func acknowledge(request_identifier: String, success: bool, response: Variant = null) -> Dictionary:
	return acknowledge_action(request_identifier, success, response)


func reject_action(request_identifier: String) -> Dictionary:
	return acknowledge_action(request_identifier, false)


func timeout_action(request_identifier: String) -> Dictionary:
	return acknowledge_action(request_identifier, false)


func get_frame() -> Dictionary:
	return _frame.duplicate(true)


func current_frame() -> Dictionary:
	return get_frame()


func get_current_frame() -> Dictionary:
	return get_frame()


func get_transcript() -> Array:
	return _transcript.duplicate(true)


func chat_messages() -> Array:
	return get_transcript()


func get_trace() -> Array:
	return _trace.duplicate(true)


func trace_records() -> Array:
	return get_trace()


func get_trace_limit() -> int:
	return _max_trace_records


func set_trace_limit(limit: int) -> void:
	_max_trace_records = clampi(limit, 1, MAX_TRACE_RECORDS)
	while _trace.size() > _max_trace_records:
		_trace.pop_front()
	_emit_trace()


func export_trace() -> Dictionary:
	return {
		"schema_version": 1,
		"kind": "conversation_preview_trace",
		"conversation_identifier": String(_definition.get("identifier", "")),
		"entry_label": _entry_label,
		"mode": _mode,
		"bounded": true,
		"max_records": _max_trace_records,
		"records": get_trace(),
	}


func get_trace_export() -> Dictionary:
	return export_trace()


func export_trace_json() -> String:
	return JSON.stringify(export_trace())


func get_status() -> Dictionary:
	return {
		"state": _status,
		"status": _status,
		"available": is_available(),
		"unavailable": is_unavailable(),
		"native_extension_available": _native_extension_available,
		"native_runtime_available": has_native_runtime(),
		"mode": _mode,
		"configured": _configured,
		"started": _started,
		"terminal": _status == STATE_TERMINAL,
		"waiting_for_choice": _status == STATE_CHOICE,
		"waiting_for_line": _status == STATE_LINE,
		"waiting_for_action": _status == STATE_WAITING_FOR_ACTION,
		"frame_revision": _frame_revision,
		"revision": _runtime_revision,
		"entry_label": _entry_label,
		"current_step_identifier": _current_step_identifier,
		"outcome_identifier": String(_frame.get("outcome_identifier", "")),
		"trace_count": _trace.size(),
		"trace_limit": _max_trace_records,
		"last_error": _last_error.duplicate(true),
		"diagnostic": _last_error.duplicate(true),
	}


func state() -> Dictionary:
	return get_status()


func get_diagnostic() -> Dictionary:
	return _last_error.duplicate(true)


## Pure definition validation used before simulation.  It intentionally mirrors
## the native conversation limits and rejects non-yielding malformed payloads
## before a preview can allocate or traverse them.
static func validate_definition(source: Dictionary) -> Array:
	var findings: Array = []
	var identifier := String(source.get("identifier", ""))
	if identifier.is_empty():
		findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-010", "Conversation identifier is required.", "conversation.identifier"))
	var entry := String(source.get("entry_label", ""))
	if entry.is_empty():
		findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-011", "Conversation entry label is required.", "conversation.entry_label"))
	var outcomes: Array = source.get("terminal_outcomes", []) if source.get("terminal_outcomes", []) is Array else []
	if outcomes.is_empty():
		findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-012", "At least one terminal outcome is required.", "conversation.terminal_outcomes"))
	var outcome_ids: Dictionary = {}
	for outcome_value in outcomes:
		var outcome := String(outcome_value)
		if outcome.is_empty() or outcome_ids.has(outcome):
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-013", "Terminal outcomes must be unique non-empty identifiers.", "conversation.terminal_outcomes"))
		else:
			outcome_ids[outcome] = true
	var steps: Array = source.get("steps", []) if source.get("steps", []) is Array else []
	if steps.is_empty():
		findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-014", "Conversation must contain at least one step.", "conversation.steps"))
	if steps.size() > MAX_STEPS:
		findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-015", "Conversation step count exceeds the bounded preview limit.", "conversation.steps", {"count": steps.size(), "limit": MAX_STEPS}))
	var step_ids: Dictionary = {}
	for index in range(steps.size()):
		var step_value = steps[index]
		if not step_value is Dictionary:
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-016", "Conversation step must be a dictionary.", "conversation.steps.%d" % index))
			continue
		var step: Dictionary = step_value
		var step_id := String(step.get("identifier", ""))
		if step_id.is_empty() or step_ids.has(step_id):
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-017", "Step identifiers must be unique and non-empty.", "conversation.step.%s.identifier" % (step_id if not step_id.is_empty() else str(index))))
		else:
			step_ids[step_id] = true
		var kind := _static_step_kind(step.get("kind", STEP_LINE))
		if kind < STEP_LINE or kind > STEP_OUTCOME:
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-018", "Step kind is not supported by the preview adapter.", "conversation.step.%s.kind" % step_id))
			continue
		var conditions: Array = step.get("conditions", []) if step.get("conditions", []) is Array else []
		if conditions.size() > MAX_CONDITIONS:
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-019", "Condition count exceeds the bounded preview limit.", "conversation.step.%s.conditions" % step_id))
		for condition_index in range(conditions.size()):
			var condition_check := _static_validate_condition(conditions[condition_index], "conversation.step.%s.conditions.%d" % [step_id, condition_index])
			if not condition_check.is_empty():
				findings.append(condition_check)
		var choices: Array = step.get("choices", []) if step.get("choices", []) is Array else []
		if choices.size() > MAX_CHOICES:
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-020", "Choice count exceeds the bounded preview limit.", "conversation.step.%s.choices" % step_id))
		var choice_ids: Dictionary = {}
		for choice_index in range(choices.size()):
			var choice_value = choices[choice_index]
			if not choice_value is Dictionary:
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-021", "Choice must be a dictionary.", "conversation.step.%s.choices.%d" % [step_id, choice_index]))
				continue
			var choice: Dictionary = choice_value
			var choice_id := String(choice.get("identifier", ""))
			if choice_id.is_empty() or choice_ids.has(choice_id):
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-022", "Choice identifiers must be unique on a step.", "conversation.step.%s.choice.%s.identifier" % [step_id, choice_id if not choice_id.is_empty() else str(choice_index)]))
			else:
				choice_ids[choice_id] = true
			if String(choice.get("label_key", "")).is_empty():
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-023", "Choice localization key is required.", "conversation.step.%s.choice.%s.label_key" % [step_id, choice_id]))
			var choice_conditions: Array = choice.get("conditions", []) if choice.get("conditions", []) is Array else []
			if choice_conditions.size() > MAX_CONDITIONS:
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-024", "Choice condition count exceeds the bounded preview limit.", "conversation.step.%s.choice.%s.conditions" % [step_id, choice_id]))
			for condition_index in range(choice_conditions.size()):
				var choice_check := _static_validate_condition(choice_conditions[condition_index], "conversation.step.%s.choice.%s.conditions.%d" % [step_id, choice_id, condition_index])
				if not choice_check.is_empty():
					findings.append(choice_check)
		var field_targets := _static_targets_for_kind(kind, step)
		for target_value in field_targets:
			var target: Dictionary = target_value
			var target_identifier := String(target.get("value", ""))
			if target_identifier.is_empty():
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-025", "%s is required for this step kind." % String(target.get("label", "Target")), "conversation.step.%s.%s" % [step_id, String(target.get("field", "target"))]))
		for choice_value in choices:
			if choice_value is Dictionary and String(choice_value.get("target_step_identifier", "")).is_empty():
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-026", "Choice target is required.", "conversation.step.%s.choices" % step_id))
	if not entry.is_empty() and not step_ids.has(entry):
		findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-027", "Entry label does not identify a step.", "conversation.entry_label"))
	# Cross-reference checks are kept separate so all failures are visible in
	# one deterministic pass, rather than failing on the first missing target.
	for step_value in steps:
		if not step_value is Dictionary:
			continue
		var step: Dictionary = step_value
		var step_id := String(step.get("identifier", ""))
		var kind := _static_step_kind(step.get("kind", STEP_LINE))
		var targets := _static_targets_for_kind(kind, step)
		for target_value in targets:
			var target: Dictionary = target_value
			var target_id := String(target.get("value", ""))
			if not target_id.is_empty() and not step_ids.has(target_id):
				findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-028", "Step target '%s' does not exist." % target_id, "conversation.step.%s.%s" % [step_id, String(target.get("field", "target"))]))
		for choice_value in step.get("choices", []) if step.get("choices", []) is Array else []:
			if choice_value is Dictionary:
				var choice: Dictionary = choice_value
				var target_id := String(choice.get("target_step_identifier", ""))
				if not target_id.is_empty() and not step_ids.has(target_id):
					findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-029", "Choice target '%s' does not exist." % target_id, "conversation.step.%s.choice.%s.target_step_identifier" % [step_id, String(choice.get("identifier", ""))]))
		if kind == STEP_OUTCOME and not outcome_ids.has(String(step.get("outcome_identifier", ""))):
			findings.append(_static_diagnostic("LTS-CONVERSATION-PREVIEW-030", "Outcome is not declared by terminal_outcomes.", "conversation.step.%s.outcome_identifier" % step_id))
	findings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.get("path", "")) != String(b.get("path", "")):
			return String(a.get("path", "")) < String(b.get("path", ""))
		return String(a.get("code", "")) < String(b.get("code", ""))
	)
	return findings


func _process_until_yield() -> Dictionary:
	var steps_seen := 0
	var jumps_seen := 0
	_frame = {}
	_pending_request = {}
	while true:
		if steps_seen >= _max_steps_per_advance:
			return {"ok": false, "error": _diagnostic(
				"LTS-CONVERSATION-PREVIEW-LIMIT-001",
				"Conversation control flow exceeded the step budget before yielding.",
				"conversation.runtime.step_budget",
				{"steps": steps_seen, "limit": _max_steps_per_advance}
			)}
		if not _steps.has(_current_step_identifier):
			return {"ok": false, "error": _diagnostic(
				"LTS-CONVERSATION-PREVIEW-031",
				"Runtime reached a missing conversation step.",
				"conversation.step.%s" % _current_step_identifier
			)}
		var step: Dictionary = _steps[_current_step_identifier]
		steps_seen += 1
		var kind := _step_kind(step.get("kind", STEP_LINE))
		_append_trace({
			"type": "visit",
			"operation": "process_until_yield",
			"step_identifier": _current_step_identifier,
			"step_kind": _kind_name(kind),
			"frame_revision": _frame_revision,
			"step_index": steps_seen,
		})
		match kind:
			STEP_LINE:
				_status = STATE_LINE
				_frame = _line_frame(step)
				_append_transcript({
					"type": "line",
					"step_identifier": _current_step_identifier,
					"speaker_identifier": String(step.get("speaker_identifier", "")),
					"line_key": String(step.get("line_key", "")),
					"parameters": _array_copy(step.get("parameters", [])),
					"frame_revision": _frame_revision,
				})
				_append_trace({"type": "frame", "frame_kind": "line", "step_identifier": _current_step_identifier, "frame_revision": _frame_revision})
				return {"ok": true}
			STEP_CHOICE:
				_status = STATE_CHOICE
				_frame = _choice_frame(step)
				_append_transcript({
					"type": "choice_prompt",
					"step_identifier": _current_step_identifier,
					"choices": _array_copy(_frame.get("available_choices", [])),
					"choice_visibility": _array_copy(_frame.get("condition_visibility", [])),
					"frame_revision": _frame_revision,
				})
				_append_trace({"type": "frame", "frame_kind": "choice", "step_identifier": _current_step_identifier, "frame_revision": _frame_revision, "available_choices": _array_copy(_frame.get("available_choices", []))})
				return {"ok": true}
			STEP_CONDITION:
				var condition_result := _evaluate_conditions(step.get("conditions", []))
				var condition_target := String(step.get("true_step_identifier", "") if condition_result.get("matches", false) else step.get("false_step_identifier", ""))
				_append_trace({
					"type": "condition",
					"step_identifier": _current_step_identifier,
					"frame_revision": _frame_revision,
					"matches": bool(condition_result.get("matches", false)),
					"evaluations": _array_copy(condition_result.get("evaluations", [])),
					"target_step_identifier": condition_target,
				})
				if condition_target.is_empty() or not _steps.has(condition_target):
					return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-032", "Condition branch target does not exist.", "conversation.step.%s" % _current_step_identifier)}
				_current_step_identifier = condition_target
				continue
			STEP_JUMP:
				if jumps_seen >= _max_jumps_per_advance:
					return {"ok": false, "error": _diagnostic(
						"LTS-CONVERSATION-PREVIEW-LIMIT-002",
						"Conversation control flow exceeded the jump budget before yielding.",
						"conversation.runtime.jump_budget",
						{"jumps": jumps_seen, "limit": _max_jumps_per_advance}
					)}
				jumps_seen += 1
				var jump_target := String(step.get("target_step_identifier", ""))
				_append_trace({"type": "jump", "step_identifier": _current_step_identifier, "frame_revision": _frame_revision, "jump_index": jumps_seen, "target_step_identifier": jump_target})
				if jump_target.is_empty() or not _steps.has(jump_target):
					return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-033", "Jump target does not exist.", "conversation.step.%s.target_step_identifier" % _current_step_identifier)}
				_current_step_identifier = jump_target
				continue
			STEP_EXTERNAL_ACTION:
				_status = STATE_WAITING_FOR_ACTION
				var request_identifier := _request_identifier(_current_step_identifier, _frame_revision)
				_pending_request = {
					"request_identifier": request_identifier,
					"conversation_identifier": String(_definition.get("identifier", "")),
					"instance_identifier": _instance_identifier,
					"scope_identifier": _scope_identifier,
					"task_integration_handle": _task_integration_handle,
					"step_identifier": _current_step_identifier,
					"provider_identifier": String(step.get("provider_identifier", "")),
					"frame_revision": _frame_revision,
					"parameters": _array_copy(step.get("parameters", [])),
				}
				_frame = {
					"kind": "action",
					"frame_kind": "external_action",
					"revision": _frame_revision,
					"frame_revision": _frame_revision,
					"step_identifier": _current_step_identifier,
					"action_request": _pending_request.duplicate(true),
					"terminal": false,
				}
				_append_transcript({"type": "action_request", "step_identifier": _current_step_identifier, "request": _pending_request.duplicate(true), "frame_revision": _frame_revision})
				_append_trace({"type": "frame", "frame_kind": "external_action", "step_identifier": _current_step_identifier, "frame_revision": _frame_revision, "request_identifier": request_identifier})
				return {"ok": true}
			STEP_OUTCOME:
				_status = STATE_TERMINAL
				_frame = {
					"kind": "outcome",
					"frame_kind": "outcome",
					"revision": _frame_revision,
					"frame_revision": _frame_revision,
					"step_identifier": _current_step_identifier,
					"outcome_identifier": String(step.get("outcome_identifier", "")),
					"terminal": true,
				}
				_append_transcript({"type": "outcome", "step_identifier": _current_step_identifier, "outcome_identifier": String(step.get("outcome_identifier", "")), "frame_revision": _frame_revision})
				_append_trace({"type": "frame", "frame_kind": "outcome", "step_identifier": _current_step_identifier, "frame_revision": _frame_revision, "outcome_identifier": String(step.get("outcome_identifier", ""))})
				return {"ok": true}
	return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-034", "Unknown conversation step kind.", "conversation.runtime")}


func _rebuild_current_frame() -> Dictionary:
	if not _steps.has(_current_step_identifier):
		return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-035", "Current step no longer exists.", "conversation.frame.step_identifier")}
	var step: Dictionary = _steps[_current_step_identifier]
	match _status:
		STATE_LINE:
			_frame = _line_frame(step)
			return {"ok": true}
		STATE_CHOICE:
			_frame = _choice_frame(step)
			return {"ok": true}
		STATE_WAITING_FOR_ACTION:
			_frame["revision"] = _frame_revision
			_frame["frame_revision"] = _frame_revision
			return {"ok": true}
		STATE_TERMINAL:
			return {"ok": true}
	return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-036", "Current frame cannot be rebuilt in this state.", "conversation.frame")}


func _line_frame(step: Dictionary) -> Dictionary:
	return {
		"kind": "line",
		"frame_kind": "line",
		"revision": _frame_revision,
		"frame_revision": _frame_revision,
		"step_identifier": _current_step_identifier,
		"speaker_identifier": String(step.get("speaker_identifier", "")),
		"line_key": String(step.get("line_key", "")),
		"localization_key": String(step.get("line_key", "")),
		"parameters": _array_copy(step.get("parameters", [])),
		"terminal": false,
		"condition_visibility": _condition_visibility(step),
	}


func _choice_frame(step: Dictionary) -> Dictionary:
	var available: Array = []
	var visibility := _condition_visibility(step)
	for item_value in visibility:
		if not item_value is Dictionary:
			continue
		var item: Dictionary = item_value
		if String(item.get("owner_kind", "")) != "choice" or not bool(item.get("visible", false)):
			continue
		var choice: Dictionary = item.get("choice", {}) if item.get("choice", {}) is Dictionary else {}
		available.append({
			"identifier": String(choice.get("identifier", "")),
			"label_key": String(choice.get("label_key", "")),
			"target_step_identifier": String(choice.get("target_step_identifier", "")),
			"conditions": _array_copy(choice.get("conditions", [])),
		})
	return {
		"kind": "choice",
		"frame_kind": "choice",
		"revision": _frame_revision,
		"frame_revision": _frame_revision,
		"step_identifier": _current_step_identifier,
		"choices": _array_copy(available),
		"available_choices": _array_copy(available),
		"condition_visibility": _array_copy(visibility),
		"terminal": false,
	}


func _condition_visibility(step: Dictionary) -> Array:
	var result: Array = []
	var step_conditions: Array = step.get("conditions", []) if step.get("conditions", []) is Array else []
	if not step_conditions.is_empty():
		var step_evaluation := _evaluate_conditions(step_conditions)
		result.append({
			"owner_kind": "step",
			"owner_identifier": _current_step_identifier,
			"visible": bool(step_evaluation.get("matches", false)),
			"conditions": _array_copy(step_conditions),
			"evaluations": _array_copy(step_evaluation.get("evaluations", [])),
			"reason": String(step_evaluation.get("reason", "")),
		})
	var choices: Array = step.get("choices", []) if step.get("choices", []) is Array else []
	for choice_value in choices:
		if not choice_value is Dictionary:
			continue
		var choice: Dictionary = choice_value
		var evaluation := _evaluate_conditions(choice.get("conditions", []))
		result.append({
			"owner_kind": "choice",
			"owner_identifier": String(choice.get("identifier", "")),
			"visible": bool(evaluation.get("matches", false)),
			"choice": choice.duplicate(true),
			"conditions": _array_copy(choice.get("conditions", [])),
			"evaluations": _array_copy(evaluation.get("evaluations", [])),
			"reason": String(evaluation.get("reason", "No condition dependencies.")),
		})
	return result


func _evaluate_conditions(conditions_value: Variant) -> Dictionary:
	var conditions: Array = conditions_value if conditions_value is Array else []
	if conditions.size() > MAX_CONDITIONS:
		return {"matches": false, "evaluations": [], "reason": "Condition count exceeds the preview limit."}
	var evaluations: Array = []
	var all_match := true
	var reason := "No condition dependencies."
	for index in range(conditions.size()):
		var predicate_value = conditions[index]
		if not predicate_value is Dictionary:
			all_match = false
			reason = "Condition %d is malformed." % index
			evaluations.append({"index": index, "matches": false, "present": false, "reason": reason})
			continue
		var predicate: Dictionary = predicate_value
		var provider := String(predicate.get("provider_identifier", predicate.get("provider", "")))
		var fact := String(predicate.get("fact_identifier", predicate.get("fact", "")))
		var key := _fact_key(provider, fact)
		var present := _facts_lookup.has(key)
		var actual = _facts_lookup.get(key, null)
		var expected = predicate.get("expected", predicate.get("value", null))
		var comparator := _comparator_value(predicate.get("comparator", predicate.get("operator", 0)))
		var matches := present and _compare_values(actual, expected, comparator)
		if not matches:
			all_match = false
			if not present:
				reason = "Missing fact %s." % key
			else:
				reason = "Fact %s does not satisfy %s." % [key, String(COMPARATOR_LABELS.get(comparator, "condition"))]
		evaluations.append({
			"index": index,
			"key": key,
			"provider_identifier": provider,
			"fact_identifier": fact,
			"comparator": comparator,
			"comparator_label": String(COMPARATOR_LABELS.get(comparator, "Unknown")),
			"expected": _safe_value(expected),
			"actual": _safe_value(actual) if present else null,
			"present": present,
			"matches": matches,
			"reason": "Matched." if matches else ("Missing fact." if not present else "Value mismatch."),
		})
	return {"matches": all_match, "evaluations": evaluations, "reason": reason}


func _normalize_facts(source: Variant) -> Dictionary:
	var entries: Array = []
	var lookup: Dictionary = {}
	if source == null:
		return {"ok": true, "entries": entries, "lookup": lookup}
	if source is Dictionary and source.has("facts") and source.get("facts") is Array:
		source = source.get("facts")
	if source is Array:
		if source.size() > MAX_FACTS:
			return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-FACT-001", "Fact count exceeds the preview limit.", "conversation.facts")}
		for value in source:
			if not value is Dictionary:
				return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-FACT-002", "Fact rows must be dictionaries.", "conversation.facts")}
			var row: Dictionary = value
			var provider := String(row.get("provider_identifier", row.get("provider", "")))
			var fact := String(row.get("fact_identifier", row.get("fact", "")))
			if provider.is_empty() or fact.is_empty():
				return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-FACT-003", "Fact rows require provider and fact identifiers.", "conversation.facts")}
			var fact_value = row.get("value", row.get("actual", row.get("expected", null)))
			_add_fact(entries, lookup, provider, fact, fact_value)
		return {"ok": true, "entries": entries, "lookup": lookup}
	if not source is Dictionary:
		return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-FACT-004", "Facts must be a dictionary or bounded array.", "conversation.facts")}
	var input: Dictionary = source
	if input.has("provider_identifier") and input.has("fact_identifier"):
		var provider := String(input.get("provider_identifier", ""))
		var fact := String(input.get("fact_identifier", ""))
		_add_fact(entries, lookup, provider, fact, input.get("value", input.get("actual", null)))
		return {"ok": true, "entries": entries, "lookup": lookup}
	for raw_key in input.keys():
		var key := String(raw_key)
		var value = input[raw_key]
		if value is Dictionary and value.has("provider_identifier") and value.has("fact_identifier"):
			_add_fact(entries, lookup, String(value.get("provider_identifier", "")), String(value.get("fact_identifier", "")), value.get("value", value.get("actual", null)))
			continue
		if value is Dictionary and not value.has("type") and not value.has("value") and not value.has("boolean_value") and not value.has("integer_value") and not value.has("string_value"):
			# Nested provider map: {"game.fact": {"has_key": true}}.
			for nested_key in value.keys():
				_add_fact(entries, lookup, key, String(nested_key), value[nested_key])
			continue
		var separator_index := key.rfind("|")
		if separator_index < 0:
			separator_index = key.rfind("/")
		if separator_index > 0 and separator_index < key.length() - 1:
			_add_fact(entries, lookup, key.substr(0, separator_index), key.substr(separator_index + 1), value)
			continue
		# Keep the exact dotted key available.  When a predicate asks for
		# provider.fact, this exact key is tried before the fact-only fallback.
		_add_raw_fact(entries, lookup, key, value)
	if entries.size() > MAX_FACTS:
		return {"ok": false, "error": _diagnostic("LTS-CONVERSATION-PREVIEW-FACT-001", "Fact count exceeds the preview limit.", "conversation.facts")}
	return {"ok": true, "entries": entries, "lookup": lookup}


func _add_fact(entries: Array, lookup: Dictionary, provider: String, fact: String, value: Variant) -> void:
	if provider.is_empty() or fact.is_empty():
		return
	var key := _fact_key(provider, fact)
	var safe_value = _safe_value(value)
	if lookup.has(key):
		lookup[key] = safe_value
		for entry_value in entries:
			if entry_value is Dictionary and String(entry_value.get("key", "")) == key:
				entry_value["value"] = safe_value
				return
		return
	lookup[key] = safe_value
	entries.append({
		"key": key,
		"provider_identifier": provider,
		"fact_identifier": fact,
		"value": safe_value,
		"present": true,
	})


func _add_raw_fact(entries: Array, lookup: Dictionary, key: String, value: Variant) -> void:
	if key.is_empty():
		return
	var safe_value = _safe_value(value)
	lookup[key] = safe_value
	entries.append({
		"key": key,
		"provider_identifier": "",
		"fact_identifier": key,
		"value": safe_value,
		"present": true,
	})


func _coerce_definition(source: Variant, conversation_identifier: String = "") -> Dictionary:
	if source == null:
		return {}
	if source is Dictionary:
		var input: Dictionary = source
		if input.has("documents") and input.get("documents") is Dictionary:
			var documents: Dictionary = input.get("documents", {})
			var conversations: Dictionary = documents.get("conversations", {}) if documents.get("conversations", {}) is Dictionary else {}
			if not conversation_identifier.is_empty() and conversations.has(conversation_identifier) and conversations[conversation_identifier] is Dictionary:
				return conversations[conversation_identifier].duplicate(true)
			if input.get("kind", "") == "conversation":
				return input.duplicate(true)
			if conversations.size() == 1:
				return conversations.values()[0].duplicate(true)
			return {}
		for wrapper_key in ["document", "definition", "conversation"]:
			if input.has(wrapper_key) and input[wrapper_key] is Dictionary:
				return input[wrapper_key].duplicate(true)
		if input.get("kind", "conversation") == "conversation" or input.has("steps"):
			return input.duplicate(true)
		return {}
	if source is Object:
		var object_source: Object = source
		if object_source.has_method("get_document") and not conversation_identifier.is_empty():
			var model_document = object_source.call("get_document", "conversation", conversation_identifier)
			if model_document is Dictionary:
				return model_document.duplicate(true)
		if object_source.has_method("get_resource_document") and not conversation_identifier.is_empty():
			var resource_document = object_source.call("get_resource_document", "conversation", conversation_identifier)
			if resource_document is Dictionary:
				return resource_document.duplicate(true)
		if object_source.has_method("get_definition"):
			var object_definition = object_source.call("get_definition")
			if object_definition is Dictionary:
				return object_definition.duplicate(true)
		if object_source.has_method("get_steps") and object_source.has_method("get_entry_label"):
			return _resource_to_definition(object_source)
	return {}


func _resource_to_definition(resource: Object) -> Dictionary:
	var result: Dictionary = {
		"kind": "conversation",
		"identifier": String(_object_value(resource, "get_identifier", "")),
		"schema_version": int(_object_value(resource, "get_schema_version", 1)),
		"entry_label": String(_object_value(resource, "get_entry_label", "")),
		"speaker_identifiers": _string_array(_object_value(resource, "get_speaker_identifiers", [])),
		"terminal_outcomes": _string_array(_object_value(resource, "get_terminal_outcomes", [])),
		"max_steps_per_advance": int(_object_value(resource, "get_max_steps_per_advance", DEFAULT_STEP_BUDGET)),
		"max_jumps_per_advance": int(_object_value(resource, "get_max_jumps_per_advance", DEFAULT_JUMP_BUDGET)),
		"steps": [],
	}
	var steps_value = _object_value(resource, "get_steps", [])
	if steps_value is Array:
		for step_resource in steps_value:
			if step_resource is Object:
				result["steps"].append(_resource_to_step(step_resource))
	return result


func _resource_to_step(resource: Object) -> Dictionary:
	var result: Dictionary = {
		"identifier": String(_object_value(resource, "get_identifier", "")),
		"kind": int(_object_value(resource, "get_kind", STEP_LINE)),
		"speaker_identifier": String(_object_value(resource, "get_speaker_identifier", "")),
		"line_key": String(_object_value(resource, "get_line_key", "")),
		"parameters": [],
		"next_step_identifier": String(_object_value(resource, "get_next_step_identifier", "")),
		"provider_identifier": String(_object_value(resource, "get_provider_identifier", "")),
		"conditions": [],
		"true_step_identifier": String(_object_value(resource, "get_true_step_identifier", "")),
		"false_step_identifier": String(_object_value(resource, "get_false_step_identifier", "")),
		"success_step_identifier": String(_object_value(resource, "get_success_step_identifier", "")),
		"failure_step_identifier": String(_object_value(resource, "get_failure_step_identifier", "")),
		"choices": [],
		"target_step_identifier": String(_object_value(resource, "get_target_step_identifier", "")),
		"outcome_identifier": String(_object_value(resource, "get_outcome_identifier", "")),
	}
	var parameters_value = _object_value(resource, "get_parameters", [])
	if parameters_value is Array:
		for parameter in parameters_value:
			if parameter is Object:
				result["parameters"].append({
					"identifier": String(_object_value(parameter, "get_identifier", "")),
					"value": _value_from_resource(_object_value(parameter, "get_value", null)),
				})
	var conditions_value = _object_value(resource, "get_conditions", [])
	if conditions_value is Array:
		for condition in conditions_value:
			if condition is Object:
				result["conditions"].append(_predicate_from_resource(condition))
	var choices_value = _object_value(resource, "get_choices", [])
	if choices_value is Array:
		for choice in choices_value:
			if choice is Object:
				var choice_result: Dictionary = {
					"identifier": String(_object_value(choice, "get_identifier", "")),
					"label_key": String(_object_value(choice, "get_label_key", "")),
					"target_step_identifier": String(_object_value(choice, "get_target_step_identifier", "")),
					"conditions": [],
				}
				var choice_conditions = _object_value(choice, "get_conditions", [])
				if choice_conditions is Array:
					for condition in choice_conditions:
						if condition is Object:
							choice_result["conditions"].append(_predicate_from_resource(condition))
				result["choices"].append(choice_result)
	return result


func _predicate_from_resource(resource: Object) -> Dictionary:
	return {
		"provider_identifier": String(_object_value(resource, "get_provider_identifier", "")),
		"fact_identifier": String(_object_value(resource, "get_fact_identifier", "")),
		"comparator": int(_object_value(resource, "get_comparator", 0)),
		"expected": _value_from_resource(_object_value(resource, "get_expected", null)),
	}


func _value_from_resource(resource: Variant) -> Variant:
	if resource == null:
		return null
	if resource is Dictionary:
		return resource.duplicate(true)
	if resource is Object and resource.has_method("get_type"):
		var value_type := int(resource.call("get_type"))
		match value_type:
			1:
				return {"type": 1, "boolean_value": bool(_object_value(resource, "get_boolean_value", false))}
			2:
				return {"type": 2, "integer_value": int(_object_value(resource, "get_integer_value", 0))}
			3:
				return {"type": 3, "fixed_raw": int(_object_value(resource, "get_fixed_raw", 0))}
			4:
				return {"type": 4, "string_value": String(_object_value(resource, "get_text_value", _object_value(resource, "get_string_value", "")))}
			5:
				return {"type": 5, "text_value": String(_object_value(resource, "get_text_value", ""))}
			6:
				return {"type": 6, "bytes_value": _object_value(resource, "get_bytes_value", PackedByteArray())}
			_:
				return {"type": 0}
	return resource


func _object_value(source: Object, method_name: String, fallback: Variant) -> Variant:
	if source != null and source.has_method(method_name):
		return source.call(method_name)
	return fallback


func _start_native(instance_identifier: String, scope_identifier: String, entry_label: String, integration_handle: String) -> Dictionary:
	var method_name := "start" if _runtime_adapter.has_method("start") else "begin"
	var call_result = _runtime_adapter.call(method_name, instance_identifier, scope_identifier, _facts_entries, entry_label, integration_handle)
	return _consume_native_result("start", call_result, true)


func _continue_line_native(frame_revision: int) -> Dictionary:
	var result = _runtime_adapter.call("continue_line", _frame_revision if frame_revision < 0 else frame_revision)
	return _consume_native_result("continue_line", result, true)


func _select_choice_native(choice_identifier: String, frame_revision: int) -> Dictionary:
	var result = _runtime_adapter.call("select_choice", choice_identifier, _frame_revision if frame_revision < 0 else frame_revision)
	return _consume_native_result("select_choice", result, true)


func _acknowledge_action_native(request_identifier: String, success: bool, response: Variant) -> Dictionary:
	var result = _runtime_adapter.call("acknowledge_action", request_identifier, success, response)
	return _consume_native_result("acknowledge_action", result, true)


func _consume_native_result(operation: String, call_result: Variant, changed: bool) -> Dictionary:
	var ok := true
	var error: Dictionary = {}
	if call_result is Dictionary:
		ok = bool(call_result.get("ok", true))
		if not ok:
			error = call_result.get("error", _diagnostic("LTS-CONVERSATION-PREVIEW-NATIVE-003", "Native conversation operation failed.", "conversation.native_runtime"))
	if call_result is Object and call_result.has_method("ok"):
		ok = bool(call_result.call("ok"))
	if not ok:
		return _failure(operation, error if not error.is_empty() else _diagnostic("LTS-CONVERSATION-PREVIEW-NATIVE-003", "Native conversation operation failed.", "conversation.native_runtime"))
	var frame_value: Variant = null
	for method_name in ["get_current_frame", "current_frame", "get_frame", "frame"]:
		if _runtime_adapter.has_method(method_name):
			frame_value = _runtime_adapter.call(method_name)
			break
	if frame_value is Dictionary:
		_frame = frame_value.duplicate(true)
		_frame_revision = int(_frame.get("frame_revision", _frame.get("revision", _frame_revision + (1 if changed else 0))))
		_runtime_revision += 1 if changed else 0
		_current_step_identifier = String(_frame.get("step_identifier", _current_step_identifier))
		_status = _status_from_frame(_frame)
		_append_trace({"type": operation, "operation": operation, "step_identifier": _current_step_identifier, "frame_revision": _frame_revision, "mode": MODE_NATIVE})
		_emit_frame()
	return _success(operation, changed)


func _status_from_frame(frame: Dictionary) -> String:
	if bool(frame.get("terminal", false)) or String(frame.get("kind", "")) in ["outcome", "terminal"]:
		return STATE_TERMINAL
	match String(frame.get("kind", frame.get("frame_kind", ""))):
		"line": return STATE_LINE
		"choice": return STATE_CHOICE
		"action", "external_action": return STATE_WAITING_FOR_ACTION
	return STATE_INACTIVE


func _capture_runtime() -> Dictionary:
	return {
		"started": _started,
		"entry_label": _entry_label,
		"instance_identifier": _instance_identifier,
		"scope_identifier": _scope_identifier,
		"task_integration_handle": _task_integration_handle,
		"current_step_identifier": _current_step_identifier,
		"frame": _frame.duplicate(true),
		"frame_revision": _frame_revision,
		"runtime_revision": _runtime_revision,
		"status": _status,
		"pending_request": _pending_request.duplicate(true),
		"last_error": _last_error.duplicate(true),
		"trace": _trace.duplicate(true),
		"transcript": _transcript.duplicate(true),
		"trace_sequence": _trace_sequence,
	}


func _restore_runtime(state: Dictionary) -> void:
	_started = bool(state.get("started", false))
	_entry_label = String(state.get("entry_label", _entry_label))
	_instance_identifier = String(state.get("instance_identifier", _instance_identifier))
	_scope_identifier = String(state.get("scope_identifier", _scope_identifier))
	_task_integration_handle = String(state.get("task_integration_handle", _task_integration_handle))
	_current_step_identifier = String(state.get("current_step_identifier", ""))
	_frame = state.get("frame", {}).duplicate(true)
	_frame_revision = int(state.get("frame_revision", 0))
	_runtime_revision = int(state.get("runtime_revision", 0))
	_status = String(state.get("status", STATE_INACTIVE))
	_pending_request = state.get("pending_request", {}).duplicate(true)
	_last_error = state.get("last_error", {}).duplicate(true)
	_trace = state.get("trace", []).duplicate(true)
	_transcript = state.get("transcript", []).duplicate(true)
	_trace_sequence = int(state.get("trace_sequence", 0))


func _clear_runtime() -> void:
	_started = false
	_current_step_identifier = ""
	_frame = {}
	_frame_revision = 0
	_runtime_revision = 0
	_status = STATE_INACTIVE
	_pending_request = {}
	_last_error = {}
	_trace.clear()
	_transcript.clear()
	_trace_sequence = 0
	_steps.clear()
	_configured = false


func _append_trace(record: Dictionary) -> void:
	_trace_sequence += 1
	var entry := record.duplicate(true)
	entry["sequence"] = _trace_sequence
	entry["bounded"] = true
	_trace.append(entry)
	while _trace.size() > _max_trace_records:
		_trace.pop_front()
	_emit_trace()


func _append_transcript(record: Dictionary) -> void:
	_transcript.append(record.duplicate(true))
	while _transcript.size() > _max_trace_records:
		_transcript.pop_front()


func _emit_frame() -> void:
	frame_changed.emit(get_frame())
	_emit_trace()
	_emit_state()


func _emit_trace() -> void:
	trace_changed.emit(get_trace())


func _emit_state() -> void:
	state_changed.emit(get_status())


func _set_configuration_error(error: Dictionary) -> Dictionary:
	_configured = false
	_status = STATE_UNAVAILABLE if not _native_extension_available else STATE_ERROR
	_last_error = error.duplicate(true)
	error_raised.emit(_last_error.duplicate(true))
	_emit_state()
	return _failure("configure", _last_error)


func _failure(operation: String, error: Dictionary, extra: Dictionary = {}) -> Dictionary:
	_last_error = error.duplicate(true)
	error_raised.emit(_last_error.duplicate(true))
	var result := {
		"ok": false,
		"applied": false,
		"changed": false,
		"operation": operation,
		"error": _last_error.duplicate(true),
		"diagnostic": _last_error.duplicate(true),
		"status": get_status(),
	}
	for key in extra.keys():
		result[key] = extra[key]
	return result


func _success(operation: String, changed: bool, extra: Dictionary = {}) -> Dictionary:
	var result := {
		"ok": true,
		"applied": changed,
		"changed": changed,
		"operation": operation,
		"frame": get_frame(),
		"status": get_status(),
	}
	for key in extra.keys():
		result[key] = extra[key]
	return result


func _unavailable_error() -> Dictionary:
	return _diagnostic(
		"LTS-CONVERSATION-PREVIEW-NATIVE-001",
		"Native extension unavailable; conversation preview is disabled.",
		"conversation.native_extension",
		{"read_only": true, "recovery": "Build and load the Level Task System GDExtension."}
	)


func _diagnostic(code: String, message: String, path: String, details: Dictionary = {}) -> Dictionary:
	var result := {"severity": "error", "code": code, "message": message, "path": path}
	for key in details.keys():
		result[key] = details[key]
	return result


static func _static_diagnostic(code: String, message: String, path: String, details: Dictionary = {}) -> Dictionary:
	var result := {"severity": "error", "code": code, "message": message, "path": path}
	for key in details.keys():
		result[key] = details[key]
	return result


func _index_steps(steps: Variant) -> Dictionary:
	var result: Dictionary = {}
	if not steps is Array:
		return result
	for step_value in steps:
		if step_value is Dictionary:
			var step: Dictionary = step_value
			result[String(step.get("identifier", ""))] = step.duplicate(true)
	return result


func _request_identifier(step_identifier: String, revision: int) -> String:
	var seed := ("lts.conversation.preview|%s|%s|%s|%d" % [String(_definition.get("identifier", "")), _instance_identifier, step_identifier, revision]).hash()
	return "request.preview.h%s" % str(absi(seed))


func _fact_key(provider: String, fact: String) -> String:
	if provider.is_empty():
		return fact
	return "%s.%s" % [provider, fact]


func _comparator_value(value: Variant) -> int:
	if value is String:
		var normalized := String(value).strip_edges().to_lower().replace("_", " ")
		for key in COMPARATOR_LABELS.keys():
			if String(COMPARATOR_LABELS[key]).to_lower() == normalized:
				return int(key)
		if normalized == "eq": return 0
		if normalized == "neq": return 1
		if normalized == "lt": return 2
		if normalized == "lte": return 3
		if normalized == "gt": return 4
		if normalized == "gte": return 5
	return int(value)


func _compare_values(actual: Variant, expected: Variant, comparator: int) -> bool:
	var actual_value := _untyped_value(actual)
	var expected_value := _untyped_value(expected)
	var actual_type := _value_type(actual)
	var expected_type := _value_type(expected)
	# Canonical Resource snapshots carry typed values while lightweight editor
	# adapters commonly supply the equivalent primitive.  Normalize that one
	# representation boundary, but keep strict type matching when both sides
	# are authored as typed values (or both are primitive values).
	var actual_is_typed: bool = actual is Dictionary and actual.has("type")
	var expected_is_typed: bool = expected is Dictionary and expected.has("type")
	if actual_is_typed and not expected_is_typed:
		expected_type = actual_type
	elif expected_is_typed and not actual_is_typed:
		actual_type = expected_type
	if actual_type != expected_type:
		return false
	match comparator:
		0: return actual_value == expected_value
		1: return actual_value != expected_value
		2: return _ordered_compare(actual_value, expected_value) < 0
		3: return _ordered_compare(actual_value, expected_value) <= 0
		4: return _ordered_compare(actual_value, expected_value) > 0
		5: return _ordered_compare(actual_value, expected_value) >= 0
	return false


func _ordered_compare(actual: Variant, expected: Variant) -> int:
	if actual == expected:
		return 0
	if (actual is int or actual is float) and (expected is int or expected is float):
		return -1 if float(actual) < float(expected) else 1
	var actual_text := str(actual)
	var expected_text := str(expected)
	return -1 if actual_text < expected_text else 1


func _value_type(value: Variant) -> String:
	if value is Dictionary and value.has("type"):
		return "typed:%d" % int(value.get("type", 0))
	if value is bool: return "bool"
	if value is int: return "int"
	if value is float: return "float"
	if value is String: return "string"
	if value is StringName: return "string"
	if value is PackedByteArray: return "bytes"
	if value is Array: return "array"
	if value is Dictionary: return "dictionary"
	return str(typeof(value))


func _untyped_value(value: Variant) -> Variant:
	if not value is Dictionary or not value.has("type"):
		return value
	var typed: Dictionary = value
	var value_type := int(typed.get("type", 0))
	match value_type:
		0: return null
		1: return bool(typed.get("boolean_value", typed.get("value", false)))
		2: return int(typed.get("integer_value", typed.get("value", 0)))
		3: return int(typed.get("fixed_raw", typed.get("value", 0)))
		4, 5: return String(typed.get("string_value", typed.get("text_value", typed.get("value", ""))))
		6: return typed.get("bytes_value", typed.get("value", PackedByteArray()))
	return typed.get("value", null)


func _safe_value(value: Variant) -> Variant:
	if value is Dictionary:
		return value.duplicate(true)
	if value is Array:
		return value.duplicate(true)
	if value is PackedByteArray:
		return value.duplicate()
	if value is Object:
		return str(value)
	return value


func _array_copy(value: Variant) -> Array:
	return value.duplicate(true) if value is Array else []


func _string_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array or value is PackedStringArray:
		for item in value:
			result.append(String(item))
	return result


func _step_kind(value: Variant) -> int:
	if value is String or value is StringName:
		return _static_step_kind(value)
	var kind := int(value)
	# Godot Resource enums use 0..5, while native C++ enum values are 1..6.
	# Canonical document dictionaries always use the former; accept outcome 6
	# as a convenience for native-shaped test doubles.
	return STEP_OUTCOME if kind == 6 else kind


static func _static_step_kind(value: Variant) -> int:
	if value is String or value is StringName:
		match String(value).strip_edges().to_lower():
			"line": return STEP_LINE
			"choice": return STEP_CHOICE
			"condition": return STEP_CONDITION
			"action", "external_action": return STEP_EXTERNAL_ACTION
			"jump": return STEP_JUMP
			"outcome", "terminal": return STEP_OUTCOME
	return int(value)


func _kind_name(kind: int) -> String:
	return ["line", "choice", "condition", "action", "jump", "outcome"][clampi(kind, 0, 5)]


static func _static_targets_for_kind(kind: int, step: Dictionary) -> Array:
	var result: Array = []
	match kind:
		STEP_LINE:
			result.append({"field": "next_step_identifier", "label": "Line continuation target", "value": String(step.get("next_step_identifier", ""))})
		STEP_CONDITION:
			result.append({"field": "true_step_identifier", "label": "True branch target", "value": String(step.get("true_step_identifier", ""))})
			result.append({"field": "false_step_identifier", "label": "False branch target", "value": String(step.get("false_step_identifier", ""))})
		STEP_EXTERNAL_ACTION:
			result.append({"field": "success_step_identifier", "label": "Action success target", "value": String(step.get("success_step_identifier", ""))})
			result.append({"field": "failure_step_identifier", "label": "Action failure target", "value": String(step.get("failure_step_identifier", ""))})
		STEP_JUMP:
			result.append({"field": "target_step_identifier", "label": "Jump target", "value": String(step.get("target_step_identifier", ""))})
	return result


static func _static_validate_condition(value: Variant, path: String) -> Dictionary:
	if not value is Dictionary:
		return _static_diagnostic("LTS-CONVERSATION-PREVIEW-037", "Condition must be a dictionary.", path)
	var condition: Dictionary = value
	if String(condition.get("provider_identifier", condition.get("provider", ""))).is_empty() or String(condition.get("fact_identifier", condition.get("fact", ""))).is_empty():
		return _static_diagnostic("LTS-CONVERSATION-PREVIEW-038", "Condition requires provider and fact identifiers.", path)
	var comparator_value := condition.get("comparator", condition.get("operator", 0))
	if comparator_value is int and (int(comparator_value) < 0 or int(comparator_value) > 5):
		return _static_diagnostic("LTS-CONVERSATION-PREVIEW-039", "Condition comparator is not supported.", path)
	if not condition.has("expected") and not condition.has("value"):
		return _static_diagnostic("LTS-CONVERSATION-PREVIEW-040", "Condition expected value is required.", path)
	return {}
