@tool
class_name LtsLocalizationBoundary
extends RefCounted

## Editor-only seam for inline conversation text and localization extraction.
##
## Canonical conversation documents contain localization keys and bounded
## parameters.  The records produced here are editor metadata: draft text,
## extraction context, and proposal bookkeeping are kept under an explicit
## editor-only branch and are removed by runtime_projection().  Consequently
## changing a translation or its source context does not change the runtime
## identity of a conversation line.

const MAX_LOCALIZATION_KEY_BYTES := 128
const MAX_LOCALIZATION_SEGMENTS := 8
const MAX_LOCALIZATION_SEGMENT_BYTES := 32
const MAX_DRAFT_TEXT_BYTES := 256
const MAX_SOURCE_PATH_BYTES := 256
const MAX_CONTEXT_BYTES := 256
const MAX_EXTRACTION_ENTRIES := 512

const KEY_ERROR_CODE := "LTS-LOCALIZATION-001"
const DRAFT_ERROR_CODE := "LTS-LOCALIZATION-002"
const EXTRACTION_ERROR_CODE := "LTS-LOCALIZATION-003"
const IDENTITY_ERROR_CODE := "LTS-LOCALIZATION-004"
const STALE_ERROR_CODE := "LTS-LOCALIZATION-005"

const DRAFT_KIND := "localization_draft"
const PROPOSAL_KIND := "localization_extraction_proposal"
const EDITOR_LOCALIZATION_BRANCH := "editor_localization"

# These names are intentionally narrow.  `text` remains canonical when it is
# part of an unrelated authored value; only explicitly editor/localization
# fields are removed from the runtime projection.
const EDITOR_ONLY_KEYS := {
	"editor_only": true,
	"editor_localization": true,
	"inline_draft": true,
	"localization_draft": true,
	"localization_drafts": true,
	"draft_text": true,
	"source_text": true,
	"translation": true,
	"translated": true,
	"translation_text": true,
	"translated_text": true,
	"inline_text": true,
	"extraction": true,
	"extraction_entries": true,
	"extraction_metadata": true,
	"extraction_proposal": true,
	"source_catalog_fingerprint": true,
	"creates_key": true,
	"changes_runtime_identity": true,
	"runtime_identity_changed": true,
	"source_path": true,
	"context": true,
	"translations": true,
	"localizations": true,
}


static func validate_key(value: Variant, allow_empty: bool = false) -> Dictionary:
	if not value is String:
		return _failure(KEY_ERROR_CODE, "INVALID_IDENTIFIER", "localization_key", 0)
	var key := String(value)
	if key.is_empty():
		if allow_empty:
			return _success({"key": key, "canonical_key": key})
		return _failure(KEY_ERROR_CODE, "IDENTIFIER_EMPTY", "localization_key", 0)

	var key_bytes := key.to_utf8_buffer()
	if key_bytes.size() > MAX_LOCALIZATION_KEY_BYTES:
		return _failure(KEY_ERROR_CODE, "IDENTIFIER_TOO_LONG", "localization_key", key_bytes.size())

	var segments := key.split(".")
	var byte_offset := 0
	for segment_index in range(segments.size()):
		var segment := String(segments[segment_index])
		var segment_bytes := segment.to_utf8_buffer()
		if segment.is_empty():
			return _failure(KEY_ERROR_CODE, "IDENTIFIER_EMPTY", "localization_key", byte_offset)
		if segment_bytes.size() > MAX_LOCALIZATION_SEGMENT_BYTES:
			return _failure(KEY_ERROR_CODE, "IDENTIFIER_SEGMENT_TOO_LONG", "localization_key", segment_bytes.size())

		for character_index in range(segment.length()):
			var codepoint := segment.unicode_at(character_index)
			var is_lower_alpha := codepoint >= 97 and codepoint <= 122
			if character_index == 0:
				if not is_lower_alpha:
					return _failure(KEY_ERROR_CODE, "IDENTIFIER_BAD_CHARACTER", "localization_key", byte_offset + character_index)
			elif not is_lower_alpha and not (codepoint >= 48 and codepoint <= 57) and codepoint != 95:
				return _failure(KEY_ERROR_CODE, "IDENTIFIER_BAD_CHARACTER", "localization_key", byte_offset + character_index)

		byte_offset += segment_bytes.size()
		if segment_index + 1 < segments.size():
			byte_offset += 1
		if segment_index + 1 > MAX_LOCALIZATION_SEGMENTS:
			return _failure(KEY_ERROR_CODE, "IDENTIFIER_TOO_MANY_SEGMENTS", "localization_key", segment_index + 1)

	return _success({"key": key, "canonical_key": key})


static func validate_localization_key(value: Variant, allow_empty: bool = false) -> Dictionary:
	return validate_key(value, allow_empty)


static func validate_optional_localization_key(value: Variant) -> Dictionary:
	return validate_key(value, true)


static func validate_optional_key(value: Variant) -> Dictionary:
	return validate_key(value, true)


static func canonicalize_key(value: Variant, allow_empty: bool = false) -> Dictionary:
	var result := validate_key(value, allow_empty)
	if bool(result.get("ok", false)):
		result["value"] = result.get("canonical_key", "")
	return result


static func canonicalize_localization_key(value: Variant) -> Dictionary:
	return canonicalize_key(value)


static func make_draft(key: String = "", text: String = "", source_path: String = "", context: String = "") -> Dictionary:
	return {
		"kind": DRAFT_KIND,
		"editor_only": true,
		"key": key,
		"text": text,
		"source_path": source_path,
		"context": context,
	}


static func make_inline_draft(key: String = "", text: String = "", source_path: String = "", context: String = "") -> Dictionary:
	return make_draft(key, text, source_path, context)


static func inline_draft(key: String = "", text: String = "", source_path: String = "", context: String = "") -> Dictionary:
	return make_draft(key, text, source_path, context)


static func make_localization_draft(key: String = "", text: String = "", source_path: String = "", context: String = "") -> Dictionary:
	return make_draft(key, text, source_path, context)


static func validate_draft(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _failure(DRAFT_ERROR_CODE, "INVALID_ARGUMENT", "localization_draft", 0)
	var draft: Dictionary = value
	var key_result := validate_key(draft.get("key", ""), true)
	if not bool(key_result.get("ok", false)):
		return _with_path(key_result, "localization_draft.key")
	var text_result := _validate_bounded_string(draft.get("text", ""), MAX_DRAFT_TEXT_BYTES, "localization_draft.text")
	if not bool(text_result.get("ok", false)):
		return text_result
	var source_result := _validate_bounded_string(draft.get("source_path", ""), MAX_SOURCE_PATH_BYTES, "localization_draft.source_path")
	if not bool(source_result.get("ok", false)):
		return source_result
	var context_result := _validate_bounded_string(draft.get("context", ""), MAX_CONTEXT_BYTES, "localization_draft.context")
	if not bool(context_result.get("ok", false)):
		return context_result
	return _success({"draft": draft.duplicate(true)})


static func runtime_projection(value: Variant) -> Variant:
	return _runtime_projection(value)


static func canonical_runtime_projection(value: Variant) -> Variant:
	return runtime_projection(value)


static func strip_editor_metadata(value: Variant) -> Variant:
	return runtime_projection(value)


static func runtime_fingerprint(value: Variant) -> String:
	return _sha256_json(runtime_projection(value))


static func canonical_runtime_fingerprint(value: Variant) -> String:
	return runtime_fingerprint(value)


static func propose_extraction(draft_value: Variant, target_key: Variant, existing_entries: Variant = []) -> Dictionary:
	var draft_result := validate_draft(draft_value)
	if not bool(draft_result.get("ok", false)):
		return draft_result
	var key_result := validate_key(target_key)
	if not bool(key_result.get("ok", false)):
		return _with_path(key_result, "extraction.target_key")
	var entries_result := _normalize_entries(existing_entries)
	if not bool(entries_result.get("ok", false)):
		return entries_result

	var draft: Dictionary = draft_value
	var target := String(target_key)
	var source_key := String(draft.get("key", ""))
	var entries: Array = entries_result.get("entries", []).duplicate(true)
	var exists := false
	for entry_value in entries:
		if String(entry_value.get("key", "")) == target:
			exists = true
			break

	var proposal := {
		"kind": PROPOSAL_KIND,
		"editor_only": true,
		"source_key": source_key,
		"key": target,
		"text": String(draft.get("text", "")),
		"source_path": String(draft.get("source_path", "")),
		"context": String(draft.get("context", "")),
		"source_catalog_fingerprint": String(entries_result.get("fingerprint", "")),
		"creates_key": not exists,
		"changes_runtime_identity": source_key != target,
		"identity_preserving": source_key == target,
		"applied": false,
	}
	var proposal_result := _validate_proposal(proposal)
	if not bool(proposal_result.get("ok", false)):
		return proposal_result
	var result := _success({
		"proposal": proposal.duplicate(true),
		"entries": entries,
		"runtime_identity_changed": bool(proposal.get("changes_runtime_identity", false)),
	})
	# Mirroring the fields at the top level keeps this a convenient value object
	# for callers while the nested proposal is the explicit apply payload.
	for field in proposal.keys():
		result[field] = proposal[field]
	return result


static func make_extraction_proposal(draft_value: Variant, target_key: Variant, existing_entries: Variant = []) -> Dictionary:
	return propose_extraction(draft_value, target_key, existing_entries)


static func propose_localization_extraction(draft_value: Variant, target_key: Variant, existing_entries: Variant = []) -> Dictionary:
	return propose_extraction(draft_value, target_key, existing_entries)


static func apply_extraction(source_value: Variant, proposal_value: Variant, allow_identity_change: bool = false) -> Dictionary:
	var proposal_result := _unwrap_proposal(proposal_value)
	if not bool(proposal_result.get("ok", false)):
		return proposal_result
	var proposal: Dictionary = proposal_result.get("proposal", {})
	var before_fingerprint := runtime_fingerprint(source_value)

	if not source_value is Dictionary:
		return _failure(EXTRACTION_ERROR_CODE, "INVALID_ARGUMENT", "source", 0)
	var source: Dictionary = source_value
	if _looks_like_draft(source):
		return _apply_to_draft(source, proposal, allow_identity_change, before_fingerprint)
	return _apply_to_document(source, proposal, allow_identity_change, before_fingerprint)


static func apply_localization_extraction(source_value: Variant, proposal_value: Variant, allow_identity_change: bool = false) -> Dictionary:
	return apply_extraction(source_value, proposal_value, allow_identity_change)


static func _apply_to_draft(source: Dictionary, proposal: Dictionary, allow_identity_change: bool, before_fingerprint: String) -> Dictionary:
	var source_result := validate_draft(source)
	if not bool(source_result.get("ok", false)):
		return source_result
	var identity_result := _check_identity(source, proposal, allow_identity_change)
	if not bool(identity_result.get("ok", false)):
		return identity_result
	var candidate := source.duplicate(true)
	candidate["kind"] = DRAFT_KIND
	candidate["editor_only"] = true
	candidate["key"] = String(proposal.get("key", ""))
	candidate["text"] = String(proposal.get("text", ""))
	candidate["source_path"] = String(proposal.get("source_path", ""))
	candidate["context"] = String(proposal.get("context", ""))
	var candidate_result := validate_draft(candidate)
	if not bool(candidate_result.get("ok", false)):
		return candidate_result
	return _applied_result(candidate, candidate, proposal, before_fingerprint, bool(identity_result.get("identity_changed", false)))


static func _apply_to_document(source: Dictionary, proposal: Dictionary, allow_identity_change: bool, before_fingerprint: String) -> Dictionary:
	var entries_result := _document_entries(source)
	if not bool(entries_result.get("ok", false)):
		return entries_result
	var entries: Array = entries_result.get("entries", []).duplicate(true)
	var catalog_fingerprint := String(entries_result.get("fingerprint", ""))
	var expected_fingerprint := String(proposal.get("source_catalog_fingerprint", ""))
	if not expected_fingerprint.is_empty() and expected_fingerprint != catalog_fingerprint:
		return _failure(STALE_ERROR_CODE, "CATALOG_FINGERPRINT_DIFFERS", "editor_localization", 0, {"actual_fingerprint": catalog_fingerprint})

	var source_key := _document_source_key(source)
	var proposal_source_key := String(proposal.get("source_key", ""))
	if not source_key.is_empty() and source_key != proposal_source_key:
		return _failure(EXTRACTION_ERROR_CODE, "VALUE_OUT_OF_RANGE", "source_key", 0)
	var identity_changed := bool(proposal.get("changes_runtime_identity", proposal_source_key != String(proposal.get("key", ""))))
	if identity_changed and not allow_identity_change:
		return _failure(IDENTITY_ERROR_CODE, "MANIFEST_FINGERPRINT_DIFFERS", "localization_key", 0)

	var candidate := source.duplicate(true)
	if identity_changed and allow_identity_change:
		# An explicit identity migration may update a key field when the document
		# has one.  Draft text and extraction metadata are still kept separate.
		if candidate.has("line_key"):
			candidate["line_key"] = String(proposal.get("key", ""))
		elif candidate.has("localization_key"):
			candidate["localization_key"] = String(proposal.get("key", ""))

	var upserted := _upsert_entry(entries, proposal)
	var editor_localization: Dictionary = candidate.get(EDITOR_LOCALIZATION_BRANCH, {}).duplicate(true) if candidate.get(EDITOR_LOCALIZATION_BRANCH, {}) is Dictionary else {}
	editor_localization["entries"] = upserted
	editor_localization["last_proposal"] = proposal.duplicate(true)
	editor_localization["editor_only"] = true
	candidate[EDITOR_LOCALIZATION_BRANCH] = editor_localization
	var after_fingerprint := runtime_fingerprint(candidate)
	if not identity_changed and after_fingerprint != before_fingerprint:
		return _failure(IDENTITY_ERROR_CODE, "MANIFEST_FINGERPRINT_DIFFERS", "runtime_projection", 0)
	return _applied_result(candidate, candidate, proposal, before_fingerprint, identity_changed, {"entries": upserted})


static func _applied_result(value: Dictionary, document: Dictionary, proposal: Dictionary, before_fingerprint: String, identity_changed: bool, extra: Dictionary = {}) -> Dictionary:
	var after_fingerprint := runtime_fingerprint(value)
	var result := _success({
		"applied": true,
		"value": value.duplicate(true),
		"draft": value.duplicate(true),
		"document": document.duplicate(true),
		"proposal": proposal.duplicate(true),
		"runtime_projection": runtime_projection(value),
		"runtime_fingerprint_before": before_fingerprint,
		"runtime_fingerprint": after_fingerprint,
		"runtime_identity_changed": identity_changed,
	})
	for key in extra.keys():
		result[key] = extra[key]
	return result


static func _check_identity(source: Dictionary, proposal: Dictionary, allow_identity_change: bool) -> Dictionary:
	var source_key := String(source.get("key", ""))
	var proposal_source_key := String(proposal.get("source_key", ""))
	if source_key != proposal_source_key:
		return _failure(EXTRACTION_ERROR_CODE, "VALUE_OUT_OF_RANGE", "source_key", 0)
	var identity_changed := bool(proposal.get("changes_runtime_identity", proposal_source_key != String(proposal.get("key", ""))))
	if identity_changed and not allow_identity_change:
		return _failure(IDENTITY_ERROR_CODE, "MANIFEST_FINGERPRINT_DIFFERS", "localization_key", 0)
	return _success({"identity_changed": identity_changed})


static func _validate_proposal(proposal: Dictionary) -> Dictionary:
	var source_key := String(proposal.get("source_key", ""))
	var target_key := String(proposal.get("key", ""))
	var source_result := validate_key(source_key, true)
	if not bool(source_result.get("ok", false)):
		return _with_path(source_result, "extraction.source_key")
	var target_result := validate_key(target_key, false)
	if not bool(target_result.get("ok", false)):
		return _with_path(target_result, "extraction.key")
	var expected_identity_change := source_key != target_key
	if bool(proposal.get("changes_runtime_identity", expected_identity_change)) != expected_identity_change:
		return _failure(EXTRACTION_ERROR_CODE, "VALUE_OUT_OF_RANGE", "extraction.changes_runtime_identity", 0)
	if proposal.has("identity_preserving") and bool(proposal.get("identity_preserving", false)) == expected_identity_change:
		return _failure(EXTRACTION_ERROR_CODE, "VALUE_OUT_OF_RANGE", "extraction.identity_preserving", 0)
	var text_result := _validate_bounded_string(proposal.get("text", ""), MAX_DRAFT_TEXT_BYTES, "extraction.text")
	if not bool(text_result.get("ok", false)):
		return text_result
	var source_path_result := _validate_bounded_string(proposal.get("source_path", ""), MAX_SOURCE_PATH_BYTES, "extraction.source_path")
	if not bool(source_path_result.get("ok", false)):
		return source_path_result
	return _validate_bounded_string(proposal.get("context", ""), MAX_CONTEXT_BYTES, "extraction.context")


static func _normalize_entries(value: Variant) -> Dictionary:
	var raw_entries: Array = []
	if value is Array:
		raw_entries = value.duplicate(true)
	elif value is Dictionary:
		var catalog: Dictionary = value
		if catalog.get("entries", []) is Array:
			raw_entries = catalog.get("entries", []).duplicate(true)
		else:
			return _failure(EXTRACTION_ERROR_CODE, "INVALID_ARGUMENT", "extraction.entries", 0)
	elif value == null:
		raw_entries = []
	else:
		return _failure(EXTRACTION_ERROR_CODE, "INVALID_ARGUMENT", "extraction.entries", 0)

	if raw_entries.size() > MAX_EXTRACTION_ENTRIES:
		return _failure(EXTRACTION_ERROR_CODE, "COUNT_LIMIT_EXCEEDED", "extraction.entries", raw_entries.size())
	var entries: Array = []
	var seen: Dictionary = {}
	for index in range(raw_entries.size()):
		if not raw_entries[index] is Dictionary:
			return _failure(EXTRACTION_ERROR_CODE, "INVALID_ARGUMENT", "extraction.entries[%d]" % index, 0)
		var entry: Dictionary = raw_entries[index]
		var key_result := validate_key(entry.get("key", ""), false)
		if not bool(key_result.get("ok", false)):
			return _with_path(key_result, "extraction.entries[%d].key" % index)
		var text_result := _validate_bounded_string(entry.get("text", ""), MAX_DRAFT_TEXT_BYTES, "extraction.entries[%d].text" % index)
		if not bool(text_result.get("ok", false)):
			return text_result
		var source_result := _validate_bounded_string(entry.get("source_path", ""), MAX_SOURCE_PATH_BYTES, "extraction.entries[%d].source_path" % index)
		if not bool(source_result.get("ok", false)):
			return source_result
		var context_result := _validate_bounded_string(entry.get("context", ""), MAX_CONTEXT_BYTES, "extraction.entries[%d].context" % index)
		if not bool(context_result.get("ok", false)):
			return context_result
		var normalized := {
			"key": String(entry.get("key", "")),
			"text": String(entry.get("text", "")),
			"source_path": String(entry.get("source_path", "")),
			"context": String(entry.get("context", "")),
		}
		var normalized_key := String(normalized["key"])
		if seen.has(normalized_key):
			return _failure(EXTRACTION_ERROR_CODE, "DEFINITION_DUPLICATE", "extraction.entries[%d].key" % index, index)
		seen[normalized_key] = true
		entries.append(normalized)
	_sort_entries(entries)
	return _success({"entries": entries, "fingerprint": _entries_fingerprint(entries)})


static func _document_entries(document: Dictionary) -> Dictionary:
	var branch: Variant = document.get(EDITOR_LOCALIZATION_BRANCH, {})
	if branch is Dictionary:
		return _normalize_entries(branch.get("entries", []))
	if branch is Array:
		return _normalize_entries(branch)
	return _failure(EXTRACTION_ERROR_CODE, "INVALID_ARGUMENT", EDITOR_LOCALIZATION_BRANCH, 0)


static func _upsert_entry(entries: Array, proposal: Dictionary) -> Array:
	var result := entries.duplicate(true)
	var target := String(proposal.get("key", ""))
	var replacement := {
		"key": target,
		"text": String(proposal.get("text", "")),
		"source_path": String(proposal.get("source_path", "")),
		"context": String(proposal.get("context", "")),
	}
	var found := false
	for index in range(result.size()):
		if String(result[index].get("key", "")) == target:
			result[index] = replacement
			found = true
			break
	if not found:
		result.append(replacement)
	_sort_entries(result)
	return result


static func _entries_fingerprint(entries: Array) -> String:
	var canonical: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		canonical.append({
			"key": String(entry.get("key", "")),
			"text": String(entry.get("text", "")),
			"source_path": String(entry.get("source_path", "")),
			"context": String(entry.get("context", "")),
		})
	return _sha256_json(canonical)


static func _runtime_projection(value: Variant) -> Variant:
	if value is Dictionary:
		var editor_kind := String(value.get("kind", ""))
		var is_editor_record := editor_kind in [DRAFT_KIND, PROPOSAL_KIND]
		if bool(value.get("editor_only", false)) and (value.has("text") or value.has("source_path") or value.has("context")):
			is_editor_record = true
		if is_editor_record:
			# A draft's key is useful for an identity comparison; its source text,
			# proposal metadata, and editor kind are not runtime inputs.
			if editor_kind == DRAFT_KIND and value.has("key"):
				return {"key": String(value.get("key", ""))}
			return {}
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key in keys:
			if EDITOR_ONLY_KEYS.has(String(key)):
				continue
			if String(key) in ["text", "translation", "translated"] and (value.has("line_key") or value.has("localization_key")):
				continue
			result[String(key)] = _runtime_projection(value[key])
		return result
	if value is Array:
		var array_result: Array = []
		for item in value:
			array_result.append(_runtime_projection(item))
		return array_result
	if value is PackedStringArray:
		return Array(value)
	if value is PackedByteArray:
		return value.hex_encode()
	return value


static func _stable_projection(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key in keys:
			result[String(key)] = _stable_projection(value[key])
		return result
	if value is Array:
		var array_result: Array = []
		for item in value:
			array_result.append(_stable_projection(item))
		return array_result
	if value is PackedStringArray:
		return Array(value)
	if value is PackedByteArray:
		return value.hex_encode()
	return value


static func _sha256_json(value: Variant) -> String:
	var json := JSON.stringify(_stable_projection(value), "", true, true)
	return json.sha256_text()


static func _sort_entries(entries: Array) -> void:
	for index in range(entries.size()):
		for next_index in range(index + 1, entries.size()):
			if _entry_less(entries[next_index], entries[index]):
				var temporary = entries[index]
				entries[index] = entries[next_index]
				entries[next_index] = temporary


static func _entry_less(left: Dictionary, right: Dictionary) -> bool:
	# Match LocalizationExtractionEntry::operator< exactly: fields compare in
	# authored byte/string order, not by a length-prefixed display sort key.
	var left_fields := [
		String(left.get("key", "")),
		String(left.get("text", "")),
		String(left.get("source_path", "")),
		String(left.get("context", "")),
	]
	var right_fields := [
		String(right.get("key", "")),
		String(right.get("text", "")),
		String(right.get("source_path", "")),
		String(right.get("context", "")),
	]
	for field_index in range(left_fields.size()):
		if left_fields[field_index] == right_fields[field_index]:
			continue
		return left_fields[field_index] < right_fields[field_index]
	return false


static func _document_source_key(document: Dictionary) -> String:
	if document.has("line_key"):
		return String(document.get("line_key", ""))
	if document.has("localization_key"):
		return String(document.get("localization_key", ""))
	if document.has("key") and document.get("kind", "") == DRAFT_KIND:
		return String(document.get("key", ""))
	return ""


static func _looks_like_draft(value: Dictionary) -> bool:
	if String(value.get("kind", "")) == DRAFT_KIND:
		return true
	return value.has("text") and (value.has("key") or value.has("source_path") or value.has("context")) and not value.has("documents") and not value.has("steps")


static func _validate_bounded_string(value: Variant, limit: int, path: String) -> Dictionary:
	if not value is String:
		return _failure(DRAFT_ERROR_CODE, "INVALID_ARGUMENT", path, 0)
	var size := String(value).to_utf8_buffer().size()
	if size > limit:
		return _failure(DRAFT_ERROR_CODE, "BYTE_LIMIT_EXCEEDED", path, size)
	return _success()


static func _unwrap_proposal(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _failure(EXTRACTION_ERROR_CODE, "INVALID_ARGUMENT", "extraction_proposal", 0)
	var candidate: Dictionary = value
	if candidate.get("proposal", null) is Dictionary:
		var nested: Dictionary = candidate.get("proposal", {}).duplicate(true)
		# propose_extraction mirrors payload fields at the top level for
		# convenience.  Reject a caller that mutates only one copy; otherwise a
		# stale/identity-changing proposal could be disguised at the boundary.
		for field in ["source_key", "key", "text", "source_path", "context", "changes_runtime_identity"]:
			if candidate.has(field) and candidate[field] != nested.get(field):
				return _failure(EXTRACTION_ERROR_CODE, "VALUE_OUT_OF_RANGE", "extraction_proposal.%s" % field, 0)
		candidate = nested
	var validation := _validate_proposal(candidate)
	if not bool(validation.get("ok", false)):
		return validation
	return _success({"proposal": candidate})


static func _success(extra: Dictionary = {}) -> Dictionary:
	var result := {
		"ok": true,
		"valid": true,
		"applied": false,
		"code": "",
		"diagnostic": "",
		"path": "",
		"detail": 0,
	}
	for key in extra.keys():
		result[key] = extra[key]
	return result


static func _failure(code: String, diagnostic: String, path: String = "", detail: int = 0, extra: Dictionary = {}) -> Dictionary:
	var result := {
		"ok": false,
		"valid": false,
		"applied": false,
		"code": code,
		"diagnostic": diagnostic,
		"path": path,
		"detail": detail,
	}
	for key in extra.keys():
		result[key] = extra[key]
	return result


static func _with_path(result: Dictionary, path: String) -> Dictionary:
	var copy := result.duplicate(true)
	copy["path"] = path
	return copy
