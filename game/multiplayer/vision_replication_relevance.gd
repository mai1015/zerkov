class_name ZVisionReplicationRelevance
extends RefCounted
## Recipient-specific replication relevance derived from full Vision snapshots.
##
## Only CURRENTLY VISIBLE native target records are resolved to stable entity
## identities. Unknown and remembered records are deliberately skipped without
## identity resolution so another feed cannot reveal hidden roster membership.

const UNKNOWN: int = 0
const REMEMBERED: int = 1
const VISIBLE: int = 2
const MAX_RECORDS: int = 128
const MAX_REVISION: int = 2_147_483_647

var last_error: StringName = &""

var _source: ZAuthorizedVisionProjectionPort
var _generation: int = 0
var _state_by_recipient: Dictionary = {}


func configure(
	source: ZAuthorizedVisionProjectionPort,
	generation: int
) -> bool:
	last_error = &""
	if _source != null or source == null or generation <= 0:
		return _reject(&"vision_relevance_configuration_invalid")
	_source = source
	_generation = generation
	return true


func refresh(recipient_actor_id: ZEntityId, tick: int) -> Dictionary:
	last_error = &""
	if (
		_source == null
		or recipient_actor_id == null
		or not recipient_actor_id.is_initialized()
		or recipient_actor_id.kind() != ZEntityId.KIND
		or tick <= 0
		or tick > MAX_REVISION
	):
		return _error(&"vision_relevance_request_invalid")
	if not _source.is_authorized_recipient(recipient_actor_id, _generation):
		return _error(&"vision_relevance_recipient_unauthorized")
	var projection := _source.projection_for(recipient_actor_id, _generation)
	if not _valid_projection_envelope(projection, tick):
		return _error(&"vision_relevance_projection_invalid")

	var recipient_key := recipient_actor_id.canonical_key()
	var previous := _state_by_recipient.get(recipient_key, {}) as Dictionary
	var revision := int(projection["result_revision"])
	var completed_tick := int(projection["completed_tick"])
	if not previous.is_empty():
		var previous_revision := int(previous.get("revision", 0))
		var previous_tick := int(previous.get("completed_tick", 0))
		if revision < previous_revision or completed_tick < previous_tick:
			return _error(&"vision_relevance_projection_regressed")

	var visible: Dictionary = {}
	var seen_native_ids: Dictionary = {}
	for raw_record in projection["records"] as Array:
		if not _valid_record(raw_record, completed_tick):
			return _error(&"vision_relevance_record_invalid")
		var record := raw_record as Dictionary
		var native_target_id := int(record["target_id"])
		if seen_native_ids.has(native_target_id):
			return _error(&"vision_relevance_target_duplicate")
		seen_native_ids[native_target_id] = true
		# Hidden/remembered identities are never resolved or retained.
		if int(record["state"]) != VISIBLE:
			continue
		var entity_id := _source.entity_for_visible_native_id(
			recipient_actor_id,
			native_target_id,
			_generation
		)
		if (
			entity_id == null
			or not entity_id.is_initialized()
			or entity_id.kind() != ZEntityId.KIND
		):
			return _error(&"vision_relevance_visible_identity_unknown")
		var entity_key := entity_id.canonical_key()
		if entity_key == recipient_key:
			continue
		visible[entity_key] = true

	var visible_ids := PackedStringArray()
	for entity_key in visible.keys():
		visible_ids.append(String(entity_key))
	visible_ids.sort()
	var previous_ids := PackedStringArray()
	if not previous.is_empty():
		previous_ids = (previous.get("visible", PackedStringArray()) as PackedStringArray).duplicate()
	var added := _difference(visible_ids, previous_ids)
	var removed := _difference(previous_ids, visible_ids)
	var visible_digest := _visible_digest(
		recipient_key,
		revision,
		completed_tick,
		visible_ids
	)
	if not previous.is_empty() and revision == int(previous["revision"]):
		if visible_digest != String(previous.get("visible_digest", "")):
			return _error(&"vision_relevance_projection_conflict")
		added = PackedStringArray()
		removed = PackedStringArray()

	_state_by_recipient[recipient_key] = {
		"completed_tick": completed_tick,
		"revision": revision,
		"visible": visible_ids.duplicate(),
		"visible_digest": visible_digest,
	}
	return {
		"added": _to_array(added),
		"completed_tick": completed_tick,
		"ok": true,
		"recipient_actor_id": recipient_key,
		"removed": _to_array(removed),
		"result_revision": revision,
		"visible_entity_ids": _to_array(visible_ids),
		"visible_set_digest": visible_digest,
	}


func allows(
	recipient_actor_id: ZEntityId,
	subject_actor_id: ZEntityId
) -> bool:
	if recipient_actor_id == null or subject_actor_id == null:
		return false
	var recipient_key := recipient_actor_id.canonical_key()
	var subject_key := subject_actor_id.canonical_key()
	if recipient_key == subject_key:
		return true
	var state := _state_by_recipient.get(recipient_key, {}) as Dictionary
	if state.is_empty():
		return false
	return (state.get("visible", PackedStringArray()) as PackedStringArray).has(
		subject_key
	)


func visible_entity_ids(recipient_actor_id: ZEntityId) -> PackedStringArray:
	if recipient_actor_id == null:
		return PackedStringArray()
	var state := _state_by_recipient.get(
		recipient_actor_id.canonical_key(), {}
	) as Dictionary
	return (
		(state.get("visible", PackedStringArray()) as PackedStringArray).duplicate()
		if not state.is_empty()
		else PackedStringArray()
	)


func clear_recipient(recipient_actor_id: ZEntityId) -> void:
	if recipient_actor_id != null:
		_state_by_recipient.erase(recipient_actor_id.canonical_key())


func _valid_projection_envelope(projection: Dictionary, tick: int) -> bool:
	if projection.size() != 5:
		return false
	for required_key in [
		"completed_tick", "observer_id", "ok", "records", "result_revision",
	]:
		if not projection.has(required_key):
			return false
	return (
		projection.get("ok") == true
		and typeof(projection.get("observer_id", null)) == TYPE_INT
		and int(projection["observer_id"]) > 0
		and typeof(projection.get("result_revision", null)) == TYPE_INT
		and int(projection["result_revision"]) > 0
		and int(projection["result_revision"]) <= MAX_REVISION
		and typeof(projection.get("completed_tick", null)) == TYPE_INT
		and int(projection["completed_tick"]) > 0
		and int(projection["completed_tick"]) <= tick
		and projection.get("records", null) is Array
		and (projection["records"] as Array).size() <= MAX_RECORDS
	)


func _valid_record(value: Variant, completed_tick: int) -> bool:
	if not value is Dictionary:
		return false
	var record := value as Dictionary
	if (
		record.size() != 6
		or not record.has("has_last_known_position")
		or not record.has("last_known_position")
		or not record.has("last_seen_tick")
		or not record.has("state")
		or not record.has("target_id")
		or not record.has("target_revision")
		or typeof(record["target_id"]) != TYPE_INT
		or int(record["target_id"]) <= 0
		or typeof(record["state"]) != TYPE_INT
		or int(record["state"]) < UNKNOWN
		or int(record["state"]) > VISIBLE
		or typeof(record["has_last_known_position"]) != TYPE_BOOL
	):
		return false
	if int(record["state"]) == UNKNOWN:
		return record["has_last_known_position"] == false
	return (
		record["has_last_known_position"] == true
		and record["last_known_position"] is Vector2i
		and typeof(record["last_seen_tick"]) == TYPE_INT
		and int(record["last_seen_tick"]) > 0
		and int(record["last_seen_tick"]) <= completed_tick
		and typeof(record["target_revision"]) == TYPE_INT
		and int(record["target_revision"]) > 0
		and int(record["target_revision"]) <= MAX_REVISION
		and (
			int(record["state"]) != VISIBLE
			or int(record["last_seen_tick"]) == completed_tick
		)
	)


func _visible_digest(
	recipient_key: String,
	revision: int,
	completed_tick: int,
	visible_ids: PackedStringArray
) -> String:
	return ZCanonicalValue.sha256({
		"completed_tick": completed_tick,
		"recipient_actor_id": recipient_key,
		"result_revision": revision,
		"visible_entity_ids": _to_array(visible_ids),
	})


static func _difference(
	left: PackedStringArray,
	right: PackedStringArray
) -> PackedStringArray:
	var right_set: Dictionary = {}
	for item in right:
		right_set[String(item)] = true
	var result := PackedStringArray()
	for item in left:
		if not right_set.has(String(item)):
			result.append(String(item))
	return result


static func _to_array(values: PackedStringArray) -> Array:
	var result: Array = []
	for value in values:
		result.append(String(value))
	return result


func _error(reason: StringName) -> Dictionary:
	last_error = reason
	return {"ok": false, "reason": reason}


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
