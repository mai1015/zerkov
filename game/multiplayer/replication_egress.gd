class_name ZReplicationEgress
extends RefCounted
## Bounded server-owned snapshot/delta egress with exact recipient mapping.
##
## There is deliberately no broadcast API. Every read names one authenticated
## session, revalidates that session against ZProductSessionRegistry, applies its
## grant, and filters every declared entity reference through owner/Vision scope.

const MAX_GRANTS: int = ZProductSessionRegistry.MAX_ACTIVE_SESSIONS
const MAX_STREAMS: int = 256
const MAX_DELTAS_PER_STREAM: int = 64
const MAX_FRAMES_PER_EGRESS: int = 256
const MAX_CURSOR_STREAMS: int = 256

var last_error: StringName = &""

var _registry: ZProductSessionRegistry
var _relevance: ZVisionReplicationRelevance
var _generation: int = 0
var _grants_by_session: Dictionary = {}
var _streams: Dictionary = {}


func configure(
	registry: ZProductSessionRegistry,
	relevance: ZVisionReplicationRelevance,
	generation: int
) -> bool:
	last_error = &""
	if (
		_registry != null
		or _relevance != null
		or registry == null
		or relevance == null
		or generation <= 0
	):
		return _reject(&"replication_egress_configuration_invalid")
	_registry = registry
	_relevance = relevance
	_generation = generation
	return true


func install_grant(grant: ZReplicationGrant) -> bool:
	last_error = &""
	if not _is_configured() or grant == null or not grant.is_usable():
		return _reject(&"replication_grant_invalid")
	var frozen := grant.snapshot()
	if frozen == null or not _grant_matches_active_session(frozen):
		return _reject(&"replication_grant_session_inactive")
	var session_key := frozen.admission.session_id.canonical_key()
	if (
		not _grants_by_session.has(session_key)
		and _grants_by_session.size() >= MAX_GRANTS
	):
		return _reject(&"replication_grant_capacity_full")
	_grants_by_session[session_key] = frozen
	return true


func revoke_session(session_id: ZSessionId) -> bool:
	last_error = &""
	if session_id == null or not session_id.is_initialized():
		return _reject(&"replication_session_id_invalid")
	var session_key := session_id.canonical_key()
	var grant := _grants_by_session.get(session_key, null) as ZReplicationGrant
	if grant == null:
		return _reject(&"replication_grant_not_found")
	_grants_by_session.erase(session_key)
	_relevance.clear_recipient(grant.admission.actor_id)
	return true


func publish_record(record: ZReplicationRecord) -> bool:
	last_error = &""
	if (
		not _is_configured()
		or record == null
		or not record.is_usable()
		or record.generation != _generation
	):
		return _reject(&"replication_record_invalid")
	var frozen := record.snapshot()
	if frozen == null:
		return _reject(&"replication_record_snapshot_invalid")
	var stream_key := frozen.stream_key
	var current := _streams.get(stream_key, {}) as Dictionary
	if current.is_empty():
		if frozen.kind != ZReplicationRecord.Kind.SNAPSHOT:
			return _reject(&"replication_stream_requires_snapshot")
		if _streams.size() >= MAX_STREAMS:
			return _reject(&"replication_stream_capacity_full")
		_streams[stream_key] = {
			"deltas": [],
			"latest_revision": frozen.revision,
			"snapshot": frozen,
		}
		return true

	var latest_revision := int(current.get("latest_revision", 0))
	var latest_record := _latest_record(current)
	if frozen.revision < latest_revision:
		return _reject(&"replication_record_revision_regressed")
	if frozen.revision == latest_revision:
		if latest_record != null and latest_record.record_digest == frozen.record_digest:
			return true
		return _reject(&"replication_record_revision_conflict")
	if frozen.kind == ZReplicationRecord.Kind.SNAPSHOT:
		_streams[stream_key] = {
			"deltas": [],
			"latest_revision": frozen.revision,
			"snapshot": frozen,
		}
		return true
	if frozen.base_revision != latest_revision:
		return _reject(&"replication_delta_base_mismatch")
	var deltas := current.get("deltas", []) as Array
	if deltas.size() >= MAX_DELTAS_PER_STREAM:
		return _reject(&"replication_delta_capacity_full")
	deltas.append(frozen)
	current["deltas"] = deltas
	current["latest_revision"] = frozen.revision
	_streams[stream_key] = current
	return true


func refresh_vision_for_session(
	session_id: ZSessionId,
	tick: int
) -> Dictionary:
	last_error = &""
	var grant := _active_grant(session_id)
	if grant == null:
		return _error(&"replication_grant_session_inactive")
	if not grant.allows_channel(ZReplicationGrant.CHANNEL_VISION):
		return _error(&"replication_vision_channel_not_granted")
	var relevance_result := _relevance.refresh(grant.admission.actor_id, tick)
	if not bool(relevance_result.get("ok", false)):
		return _error(StringName(relevance_result.get(
			"reason", &"replication_vision_refresh_failed"
		)))
	var visible_ids := PackedStringArray()
	for raw_id in relevance_result.get("visible_entity_ids", []) as Array:
		visible_ids.append(String(raw_id))
	var record := ZReplicationRecord.create(
		ZReplicationGrant.CHANNEL_VISION,
		"vision:" + grant.admission.actor_id.canonical_key(),
		grant.admission.actor_id,
		_generation,
		ZReplicationRecord.Kind.SNAPSHOT,
		ZReplicationRecord.Scope.OWNER,
		int(relevance_result["result_revision"]),
		0,
		{
			"completed_tick": int(relevance_result["completed_tick"]),
			"visible_entity_ids": relevance_result["visible_entity_ids"],
			"visible_set_digest": String(relevance_result["visible_set_digest"]),
		},
		visible_ids
	)
	if record == null or not publish_record(record):
		return _error(
			last_error
			if not last_error.is_empty()
			else &"replication_vision_record_invalid"
		)
	return {
		"ok": true,
		"record_digest": record.record_digest,
		"result_revision": record.revision,
		"stream_key": record.stream_key,
	}


func egress_for_session(
	session_id: ZSessionId,
	since_revisions: Dictionary = {}
) -> Dictionary:
	last_error = &""
	var grant := _active_grant(session_id)
	if grant == null:
		return _error(&"replication_grant_session_inactive")
	if not _valid_cursors(since_revisions):
		return _error(&"replication_cursor_invalid")

	var frames: Array = []
	var resync_streams: Array = []
	var stream_keys := _streams.keys()
	stream_keys.sort()
	for raw_stream_key in stream_keys:
		var stream_key := String(raw_stream_key)
		var stream := _streams[stream_key] as Dictionary
		var snapshot_record := stream.get("snapshot", null) as ZReplicationRecord
		if snapshot_record == null or not _record_visible_to_grant(
			snapshot_record, grant
		):
			continue
		var since_revision := int(since_revisions.get(stream_key, 0))
		var latest_revision := int(stream.get("latest_revision", 0))
		if since_revision > latest_revision:
			return _error(&"replication_cursor_ahead")
		if since_revision < snapshot_record.revision:
			frames.append(snapshot_record.wire_record())
			if since_revision > 0:
				resync_streams.append(stream_key)
		for raw_delta in stream.get("deltas", []) as Array:
			var delta := raw_delta as ZReplicationRecord
			if (
				delta != null
				and delta.revision > since_revision
				and _record_visible_to_grant(delta, grant)
			):
				frames.append(delta.wire_record())
				if frames.size() > MAX_FRAMES_PER_EGRESS:
					return _error(&"replication_egress_frame_capacity_full")

	return {
		"actor_id": grant.admission.actor_id.canonical_key(),
		"authority_epoch": grant.admission.authority_epoch,
		"frames": frames,
		"grant_digest": grant.grant_digest,
		"ok": true,
		"resync_streams": resync_streams,
		"session_id": grant.admission.session_id.canonical_key(),
		"transport_peer_id": grant.admission.transport_peer_id,
	}


func grant_count() -> int:
	return _grants_by_session.size()


func stream_count() -> int:
	return _streams.size()


func _record_visible_to_grant(
	record: ZReplicationRecord,
	grant: ZReplicationGrant
) -> bool:
	if (
		record == null
		or not record.is_usable()
		or not grant.allows_channel(record.channel)
	):
		return false
	var recipient_actor := grant.admission.actor_id
	if record.scope == ZReplicationRecord.Scope.OWNER:
		if not record.owner_actor_id.is_equal(recipient_actor):
			return false
	elif not _relevance.allows(recipient_actor, record.owner_actor_id):
		return false
	if record.channel == ZReplicationGrant.CHANNEL_INVENTORY:
		var inventory_id := _inventory_id_from_subject(record.subject_id)
		if inventory_id <= 0 or not grant.owns_inventory(inventory_id):
			return false
	for reference in record.entity_references:
		var entity_id := ZEntityId.parse(String(reference))
		if entity_id == null or not _relevance.allows(recipient_actor, entity_id):
			return false
	return true


func _active_grant(session_id: ZSessionId) -> ZReplicationGrant:
	if not _is_configured() or session_id == null or not session_id.is_initialized():
		return null
	var grant := _grants_by_session.get(
		session_id.canonical_key(), null
	) as ZReplicationGrant
	if grant == null or not grant.is_usable() or not _grant_matches_active_session(grant):
		return null
	return grant.snapshot()


func _grant_matches_active_session(grant: ZReplicationGrant) -> bool:
	if grant == null or not grant.is_usable():
		return false
	var active := _registry.admission_for_session(grant.admission.session_id)
	return (
		active != null
		and active.is_usable()
		and active.session_id.is_equal(grant.admission.session_id)
		and active.actor_id.is_equal(grant.admission.actor_id)
		and active.principal_key == grant.admission.principal_key
		and active.transport_peer_id == grant.admission.transport_peer_id
		and active.authority_epoch == grant.admission.authority_epoch
		and active.compatibility_digest == grant.admission.compatibility_digest
	)


func _valid_cursors(cursors: Dictionary) -> bool:
	if cursors.size() > MAX_CURSOR_STREAMS:
		return false
	for raw_key in cursors.keys():
		if (
			typeof(raw_key) != TYPE_STRING
			or not ZProductCompatibilityManifest.is_sha256(String(raw_key))
			or typeof(cursors[raw_key]) != TYPE_INT
			or int(cursors[raw_key]) < 0
			or int(cursors[raw_key]) > ZReplicationRecord.MAX_REVISION
		):
			return false
	return true


func _latest_record(stream: Dictionary) -> ZReplicationRecord:
	var deltas := stream.get("deltas", []) as Array
	if not deltas.is_empty():
		return deltas[deltas.size() - 1] as ZReplicationRecord
	return stream.get("snapshot", null) as ZReplicationRecord


static func _inventory_id_from_subject(subject_id: String) -> int:
	const PREFIX := "inventory:"
	if not subject_id.begins_with(PREFIX):
		return 0
	var suffix := subject_id.substr(PREFIX.length())
	if not suffix.is_valid_int():
		return 0
	return int(suffix)


func _is_configured() -> bool:
	return _registry != null and _relevance != null and _generation > 0


func _error(reason: StringName) -> Dictionary:
	last_error = reason
	return {"ok": false, "reason": reason}


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
