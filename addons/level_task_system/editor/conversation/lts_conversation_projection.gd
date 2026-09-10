@tool
class_name LtsConversationProjection
extends RefCounted

## Pure projections used by both conversation authoring views.
##
## A projection is rebuilt from the bound LtsDocumentModel each time.  It is
## safe to hand to a Control, but it never becomes an editable semantic store.
## The text view consumes `text_outline`, a structured list of canonical fields
## (not a parser input), so switching views cannot discard branches or IDs.

const DocumentProjection := preload("res://addons/level_task_system/editor/document/lts_document_projection.gd")

const KIND_CONVERSATION := "conversation"
const STEP_LINE := 0
const STEP_CHOICE := 1
const STEP_CONDITION := 2
const STEP_EXTERNAL_ACTION := 3
const STEP_JUMP := 4
const STEP_OUTCOME := 5

const STEP_KIND_LABELS: Dictionary = {
	STEP_LINE: "Line",
	STEP_CHOICE: "Choice",
	STEP_CONDITION: "Condition",
	STEP_EXTERNAL_ACTION: "External action",
	STEP_JUMP: "Jump",
	STEP_OUTCOME: "Outcome",
}

const STEP_KIND_NAMES: Dictionary = {
	STEP_LINE: "line",
	STEP_CHOICE: "choice",
	STEP_CONDITION: "condition",
	STEP_EXTERNAL_ACTION: "action",
	STEP_JUMP: "jump",
	STEP_OUTCOME: "outcome",
}

const STEP_FIELDS_BY_KIND: Dictionary = {
	"line": ["speaker_identifier", "line_key", "next_step_identifier"],
	"choice": [],
	"condition": ["provider_identifier", "true_step_identifier", "false_step_identifier"],
	"action": ["provider_identifier", "success_step_identifier", "failure_step_identifier"],
	"jump": ["target_step_identifier"],
	"outcome": ["outcome_identifier"],
}

const REFERENCE_FIELDS_BY_KIND: Dictionary = {
	"line": {"next_step_identifier": "next step"},
	"condition": {"true_step_identifier": "true branch", "false_step_identifier": "false branch"},
	"action": {"success_step_identifier": "success branch", "failure_step_identifier": "failure branch"},
	"jump": {"target_step_identifier": "jump target"},
}


static func canonical_document(source: Variant, conversation_identifier: String = "") -> Dictionary:
	if source is Dictionary:
		if source.has("documents"):
			var conversations: Dictionary = source.get("documents", {}).get("conversations", {})
			if not conversation_identifier.is_empty() and conversations.has(conversation_identifier):
				return conversations[conversation_identifier].duplicate(true)
			if source.get("kind", "") == KIND_CONVERSATION:
				return source.duplicate(true)
			return {}
	if source is Object:
		if source.has_method("get_document") and not conversation_identifier.is_empty():
			var result = source.call("get_document", KIND_CONVERSATION, conversation_identifier)
			return result.duplicate(true) if result is Dictionary else {}
		if source.has_method("get_resource_document") and not conversation_identifier.is_empty():
			var document = source.call("get_resource_document", KIND_CONVERSATION, conversation_identifier)
			return document.duplicate(true) if document is Dictionary else {}
	return {}


static func project(source: Variant, conversation_identifier: String, selection: Dictionary = {}, findings: Array = []) -> Dictionary:
	var document := canonical_document(source, conversation_identifier)
	var normalized_selection := normalize_selection(selection, conversation_identifier)
	var local_findings := validate_document(document)
	if not findings.is_empty():
		local_findings.append_array(findings.duplicate(true))
	local_findings = sort_findings(local_findings)
	return {
		"kind": KIND_CONVERSATION,
		"identifier": conversation_identifier if conversation_identifier != "" else String(document.get("identifier", "")),
		"revision": int(source.call("get_revision") if source is Object and source.has_method("get_revision") else 0),
		"document": document,
		"selection": normalized_selection,
		"timeline": timeline(document, normalized_selection, local_findings),
		"text_outline": text_outline(document, normalized_selection, local_findings),
		"findings": local_findings,
		"is_valid": local_findings.filter(func(item: Dictionary) -> bool: return String(item.get("severity", "error")) == "error").is_empty(),
	}


static func timeline(document: Dictionary, selection: Dictionary = {}, findings: Array = []) -> Dictionary:
	var items: Array = []
	var steps: Array = document.get("steps", []) if document.get("steps", []) is Array else []
	for index in steps.size():
		var step: Dictionary = steps[index] if steps[index] is Dictionary else {}
		var step_identifier := String(step.get("identifier", ""))
		var kind := kind_name(step.get("kind", STEP_LINE))
		var choices: Array = []
		for choice_value in step.get("choices", []) if step.get("choices", []) is Array else []:
			if not choice_value is Dictionary:
				continue
			var choice: Dictionary = choice_value
			var choice_identifier := String(choice.get("identifier", ""))
			choices.append({
				"identifier": choice_identifier,
				"label_key": String(choice.get("label_key", "")),
				"target_step_identifier": String(choice.get("target_step_identifier", "")),
				"conditions": choice.get("conditions", []).duplicate(true) if choice.get("conditions", []) is Array else [],
				"selected": is_selected_choice(selection, step_identifier, choice_identifier),
				"findings": findings_for(findings, document, "choice", choice_identifier, step_identifier),
			})
		var branches := branch_projection(step, kind)
		items.append({
			"index": index,
			"identifier": step_identifier,
			"kind": kind,
			"kind_label": kind_label(step.get("kind", STEP_LINE)),
			"speaker_identifier": String(step.get("speaker_identifier", "")),
			"line_key": String(step.get("line_key", "")),
			"summary": step_summary(step, kind),
			"choices": choices,
			"branches": branches,
			"conditions": step.get("conditions", []).duplicate(true) if step.get("conditions", []) is Array else [],
			"selected": is_selected_step(selection, step_identifier),
			"findings": findings_for(findings, document, "step", step_identifier),
		})
	return {
		"kind": KIND_CONVERSATION,
		"identifier": String(document.get("identifier", "")),
		"document": document.duplicate(true),
		"selection": selection.duplicate(true),
		"findings": findings.duplicate(true),
		"entry_label": String(document.get("entry_label", "")),
		"terminal_outcomes": _string_array(document.get("terminal_outcomes", [])),
		"steps": items,
		"empty": items.is_empty(),
	}


static func text_outline(document: Dictionary, selection: Dictionary = {}, findings: Array = []) -> Array:
	var rows: Array = []
	var steps: Array = document.get("steps", []) if document.get("steps", []) is Array else []
	for index in steps.size():
		var step: Dictionary = steps[index] if steps[index] is Dictionary else {}
		var step_identifier := String(step.get("identifier", ""))
		var kind := kind_name(step.get("kind", STEP_LINE))
		rows.append(_outline_row(
			"step:%s" % step_identifier,
			0,
			"step",
			step_identifier,
			step_identifier,
			kind_label(step.get("kind", STEP_LINE)),
			"",
			is_selected_step(selection, step_identifier),
			findings_for(findings, document, "step", step_identifier)
		))
		for field_name in STEP_FIELDS_BY_KIND.get(kind, []):
			rows.append(_outline_row(
				"step:%s:%s" % [step_identifier, field_name],
				1,
				"field",
				step_identifier,
				field_name,
				_field_label(field_name),
				String(step.get(field_name, "")),
				is_selected_field(selection, step_identifier, field_name),
				findings_for(findings, document, "step", step_identifier, field_name)
			))
		if kind == "choice":
			for choice_value in step.get("choices", []) if step.get("choices", []) is Array else []:
				if not choice_value is Dictionary:
					continue
				var choice: Dictionary = choice_value
				var choice_identifier := String(choice.get("identifier", ""))
				rows.append(_outline_row(
					"choice:%s:%s" % [step_identifier, choice_identifier],
					1,
					"choice",
					step_identifier,
					choice_identifier,
					"Choice %s" % choice_identifier,
					"",
					is_selected_choice(selection, step_identifier, choice_identifier),
					findings_for(findings, document, "choice", choice_identifier, step_identifier)
				))
				for choice_field in ["label_key", "target_step_identifier"]:
					rows.append(_outline_row(
						"choice:%s:%s:%s" % [step_identifier, choice_identifier, choice_field],
						2,
						"field",
						step_identifier,
						choice_field,
						_field_label(choice_field),
						String(choice.get(choice_field, "")),
						is_selected_field(selection, choice_identifier, choice_field),
						findings_for(findings, document, "choice", choice_identifier, step_identifier, choice_field)
					))
				_add_condition_rows(rows, step_identifier, choice.get("conditions", []), 2, choice_identifier, selection, findings, document)
		_add_condition_rows(rows, step_identifier, step.get("conditions", []), 1, "", selection, findings, document)
	return rows


static func validate_document(document: Dictionary) -> Array:
	var findings: Array = []
	var conversation_identifier := String(document.get("identifier", ""))
	if conversation_identifier.is_empty():
		findings.append(_finding("LTS-CONVERSATION-001", "error", "Conversation identifier is required", "conversation", ""))
	var entry_label := String(document.get("entry_label", ""))
	if entry_label.is_empty():
		findings.append(_finding("LTS-CONVERSATION-002", "error", "Entry label is required", "conversation", "", "entry_label"))
	var outcomes := _string_array(document.get("terminal_outcomes", []))
	if outcomes.is_empty():
		findings.append(_finding("LTS-CONVERSATION-003", "error", "At least one terminal outcome is required", "conversation", "", "terminal_outcomes"))
	var steps: Array = document.get("steps", []) if document.get("steps", []) is Array else []
	if steps.is_empty():
		findings.append(_finding("LTS-CONVERSATION-004", "error", "Conversation must contain at least one step", "conversation", "", "steps"))
	var ids: Dictionary = {}
	for step_value in steps:
		if not step_value is Dictionary:
			findings.append(_finding("LTS-CONVERSATION-005", "error", "Step entry is not a dictionary", "conversation", "", "steps"))
			continue
		var step: Dictionary = step_value
		var step_identifier := String(step.get("identifier", ""))
		if step_identifier.is_empty():
			findings.append(_finding("LTS-CONVERSATION-006", "error", "Step identifier is required", "step", "", "identifier"))
		elif ids.has(step_identifier):
			findings.append(_finding("LTS-CONVERSATION-007", "error", "Step identifier is duplicated", "step", step_identifier, "identifier"))
		else:
			ids[step_identifier] = true
	for step_value in steps:
		if not step_value is Dictionary:
			continue
		var step: Dictionary = step_value
		var step_identifier := String(step.get("identifier", ""))
		var kind := kind_name(step.get("kind", STEP_LINE))
		if not STEP_KIND_NAMES.values().has(kind):
			findings.append(_finding("LTS-CONVERSATION-008", "error", "Step kind is not supported", "step", step_identifier, "kind"))
			continue
		for field_name in REFERENCE_FIELDS_BY_KIND.get(kind, {}).keys():
			var target := String(step.get(field_name, ""))
			if target.is_empty():
				findings.append(_finding("LTS-CONVERSATION-009", "error", "%s is required" % String(REFERENCE_FIELDS_BY_KIND[kind][field_name]).capitalize(), "step", step_identifier, field_name))
			elif not ids.has(target):
				findings.append(_finding("LTS-CONVERSATION-010", "error", "%s '%s' does not exist" % [String(REFERENCE_FIELDS_BY_KIND[kind][field_name]).capitalize(), target], "step", step_identifier, field_name))
		if kind == "line":
			if String(step.get("speaker_identifier", "")).is_empty():
				findings.append(_finding("LTS-CONVERSATION-011", "error", "Line speaker is required", "step", step_identifier, "speaker_identifier"))
			if String(step.get("line_key", "")).is_empty():
				findings.append(_finding("LTS-CONVERSATION-012", "error", "Localization key is required", "step", step_identifier, "line_key"))
		if kind == "choice":
			var choices: Array = step.get("choices", []) if step.get("choices", []) is Array else []
			if choices.is_empty():
				findings.append(_finding("LTS-CONVERSATION-013", "error", "Choice step needs at least one choice", "step", step_identifier, "choices"))
			var choice_ids: Dictionary = {}
			for choice_value in choices:
				if not choice_value is Dictionary:
					findings.append(_finding("LTS-CONVERSATION-014", "error", "Choice entry is not a dictionary", "step", step_identifier, "choices"))
					continue
				var choice: Dictionary = choice_value
				var choice_identifier := String(choice.get("identifier", ""))
				if choice_identifier.is_empty():
					findings.append(_finding("LTS-CONVERSATION-015", "error", "Choice identifier is required", "choice", "", "identifier"))
				elif choice_ids.has(choice_identifier):
					findings.append(_finding("LTS-CONVERSATION-016", "error", "Choice identifier is duplicated", "choice", choice_identifier, "identifier"))
				else:
					choice_ids[choice_identifier] = true
				if String(choice.get("label_key", "")).is_empty():
					findings.append(_finding("LTS-CONVERSATION-017", "error", "Choice localization key is required", "choice", choice_identifier, "label_key"))
				var target := String(choice.get("target_step_identifier", ""))
				if target.is_empty() or not ids.has(target):
					findings.append(_finding("LTS-CONVERSATION-018", "error", "Choice target '%s' does not exist" % target, "choice", choice_identifier, "target_step_identifier"))
		if kind == "outcome":
			var outcome_identifier := String(step.get("outcome_identifier", ""))
			if not outcomes.has(outcome_identifier):
				findings.append(_finding("LTS-CONVERSATION-019", "error", "Outcome '%s' is not declared by the conversation" % outcome_identifier, "step", step_identifier, "outcome_identifier"))
	if not entry_label.is_empty() and not ids.has(entry_label):
		findings.append(_finding("LTS-CONVERSATION-020", "error", "Entry label '%s' does not identify a step" % entry_label, "conversation", "", "entry_label"))
	for finding_value in findings:
		if not finding_value is Dictionary:
			continue
		var finding: Dictionary = finding_value
		finding["resource_kind"] = KIND_CONVERSATION
		finding["resource_identifier"] = conversation_identifier
		finding["path"] = DocumentProjection.finding_path(
			KIND_CONVERSATION,
			conversation_identifier,
			String(finding.get("element_kind", "")),
			String(finding.get("element_identifier", "")),
			String(finding.get("field_path", ""))
		)
	return sort_findings(findings)


static func normalize_selection(selection: Dictionary, conversation_identifier: String = "") -> Dictionary:
	var result := {
		"resource_kind": KIND_CONVERSATION,
		"resource_identifier": conversation_identifier,
		"element_kind": "",
		"element_identifier": "",
		"field_path": "",
	}
	for key in result.keys():
		if selection.has(key):
			result[key] = String(selection[key])
	if result["resource_identifier"].is_empty() and selection.has("identifier"):
		result["resource_identifier"] = String(selection["identifier"])
	if result["element_kind"].is_empty() and selection.has("type"):
		result["element_kind"] = String(selection["type"])
	if result["element_identifier"].is_empty() and selection.has("element_id"):
		result["element_identifier"] = String(selection["element_id"])
	result["element_kind"] = String(result["element_kind"]).to_lower()
	return result


static func kind_name(kind: Variant) -> String:
	if kind is String:
		var normalized := String(kind).strip_edges().to_lower()
		if normalized in ["external action", "external_action", "action"]:
			return "action"
		return normalized
	return String(STEP_KIND_NAMES.get(int(kind), "unknown"))


static func kind_label(kind: Variant) -> String:
	if kind is String:
		var name := kind_name(kind)
		for value in STEP_KIND_NAMES.keys():
			if STEP_KIND_NAMES[value] == name:
				return String(STEP_KIND_LABELS[value])
		return String(kind).capitalize()
	return String(STEP_KIND_LABELS.get(int(kind), "Unknown"))


static func step_summary(step: Dictionary, kind: String = "") -> String:
	var resolved_kind := kind if not kind.is_empty() else kind_name(step.get("kind", STEP_LINE))
	match resolved_kind:
		"line":
			return "%s · %s" % [String(step.get("speaker_identifier", "(speaker)")), String(step.get("line_key", "(localization key)"))]
		"choice":
			return "%d choices" % (step.get("choices", []).size() if step.get("choices", []) is Array else 0)
		"condition":
			return "%s · true → %s · false → %s" % [String(step.get("provider_identifier", "(provider)")), String(step.get("true_step_identifier", "(unset)")), String(step.get("false_step_identifier", "(unset)"))]
		"action":
			return "%s · success → %s · failure → %s" % [String(step.get("provider_identifier", "(provider)")), String(step.get("success_step_identifier", "(unset)")), String(step.get("failure_step_identifier", "(unset)"))]
		"jump":
			return "target → %s" % String(step.get("target_step_identifier", "(unset)"))
		"outcome":
			return "terminal · %s" % String(step.get("outcome_identifier", "(unset)"))
	return ""


static func branch_projection(step: Dictionary, kind: String) -> Array:
	var result: Array = []
	for field_name in REFERENCE_FIELDS_BY_KIND.get(kind, {}).keys():
		result.append({
			"field_name": field_name,
			"label": String(REFERENCE_FIELDS_BY_KIND[kind][field_name]).capitalize(),
			"target_step_identifier": String(step.get(field_name, "")),
		})
	if kind == "choice":
		for choice_value in step.get("choices", []) if step.get("choices", []) is Array else []:
			if choice_value is Dictionary:
				result.append({
					"field_name": "choice:%s" % String(choice_value.get("identifier", "")),
					"label": "Choice %s" % String(choice_value.get("identifier", "")),
					"target_step_identifier": String(choice_value.get("target_step_identifier", "")),
				})
	return result


static func findings_for(findings: Array, _document: Dictionary, element_kind: String, element_identifier: String, _parent_identifier: String = "", field_name: String = "") -> Array:
	var result: Array = []
	for finding_value in findings:
		if not finding_value is Dictionary:
			continue
		var finding: Dictionary = finding_value
		if String(finding.get("element_kind", "")).to_lower() != element_kind.to_lower():
			continue
		if String(finding.get("element_identifier", "")) != element_identifier:
			continue
		if not field_name.is_empty() and String(finding.get("field_path", "")) != field_name:
			continue
		result.append(finding.duplicate(true))
	return result


static func sort_findings(findings: Array) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for finding_value in findings:
		if not finding_value is Dictionary:
			continue
		var finding: Dictionary = finding_value
		var identity := "%s|%s|%s" % [
			String(finding.get("severity", "error")),
			String(finding.get("code", "")),
			String(finding.get("path", "")),
		]
		if seen.has(identity):
			continue
		seen[identity] = true
		result.append(finding.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%s|%s|%s|%s" % [String(a.get("path", "")), String(a.get("code", "")), String(a.get("severity", "")), String(a.get("message", ""))]
		var b_key := "%s|%s|%s|%s" % [String(b.get("path", "")), String(b.get("code", "")), String(b.get("severity", "")), String(b.get("message", ""))]
		return a_key < b_key
	)
	return result


static func _outline_row(row_id: String, depth: int, role: String, step_identifier: String, element_identifier: String, label: String, value: String, selected: bool, row_findings: Array) -> Dictionary:
	return {
		"row_id": row_id,
		"depth": depth,
		"role": role,
		"step_identifier": step_identifier,
		"element_identifier": element_identifier,
		"field_name": row_id.get_slice(":", -1) if role == "field" else "",
		"label": label,
		"value": value,
		"selected": selected,
		"editable": role == "field",
		"findings": row_findings.duplicate(true),
	}


static func _add_condition_rows(rows: Array, step_identifier: String, conditions_value: Variant, depth: int, choice_identifier: String, selection: Dictionary, findings: Array, document: Dictionary) -> void:
	if not conditions_value is Array:
		return
	for index in conditions_value.size():
		var condition: Dictionary = conditions_value[index] if conditions_value[index] is Dictionary else {}
		var prefix := "choice:%s:%s:conditions:%d" % [step_identifier, choice_identifier, index] if not choice_identifier.is_empty() else "step:%s:conditions:%d" % [step_identifier, index]
		rows.append(_outline_row(
			prefix,
			depth,
			"condition",
			step_identifier,
			choice_identifier,
			"Condition %d" % (index + 1),
			_condition_summary(condition),
			false,
		findings_for(
			findings,
			document,
			"choice" if not choice_identifier.is_empty() else "step",
			choice_identifier if not choice_identifier.is_empty() else step_identifier,
			step_identifier,
			"conditions"
		)
		))


static func _condition_summary(condition: Dictionary) -> String:
	return "%s · %s %s %s" % [String(condition.get("provider_identifier", "(provider)")), String(condition.get("fact_identifier", "(fact)")), _comparator_label(condition.get("comparator", 0)), _value_label(condition.get("expected", null))]


static func _comparator_label(value: Variant) -> String:
	if value is String:
		return String(value)
	return String({0: "==", 1: "!=", 2: ">", 3: ">=", 4: "<", 5: "<="}.get(int(value), "?"))


static func _value_label(value: Variant) -> String:
	if value == null:
		return "none"
	if value is Dictionary:
		for key in ["string_value", "text_value", "integer_value", "boolean_value", "fixed_raw"]:
			if value.has(key):
				return "none" if value[key] == null else "%s" % value[key]
		return JSON.stringify(value)
	return String(value)


static func _field_label(field_name: String) -> String:
	return field_name.replace("_", " ").capitalize()


static func _finding(code: String, severity: String, message: String, element_kind: String, element_identifier: String, field_path: String = "") -> Dictionary:
	var path := DocumentProjection.finding_path("conversation", "", element_kind, element_identifier, field_path)
	return {
		"code": code,
		"severity": severity,
		"message": message,
		"path": path,
		"element_kind": element_kind,
		"element_identifier": element_identifier,
		"field_path": field_path,
		"fixable": true,
	}


static func _is_step_kind(kind: Variant, expected: int) -> bool:
	return int(kind) == expected


static func is_selected_step(selection: Dictionary, step_identifier: String) -> bool:
	return String(selection.get("element_kind", "")) in ["step", "line"] and String(selection.get("element_identifier", "")) == step_identifier


static func is_selected_choice(selection: Dictionary, _step_identifier: String, choice_identifier: String) -> bool:
	return String(selection.get("element_kind", "")) == "choice" and String(selection.get("element_identifier", "")) == choice_identifier


static func is_selected_field(selection: Dictionary, element_identifier: String, field_name: String) -> bool:
	return String(selection.get("element_identifier", "")) == element_identifier and String(selection.get("field_path", "")).ends_with(field_name)


static func _string_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array or value is PackedStringArray:
		for item in value:
			result.append(String(item))
	return result
