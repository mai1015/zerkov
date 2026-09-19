class_name ZGrantScopedReplicationEgress
extends RefCounted
## Server-owned, transport-neutral replication egress for task 10.5.
##
## Every publication is bound to one current authenticated admission and one
## explicit {channel, subject} grant. There is no broadcast path. Projection
## providers cannot choose recipients, peers, epochs, compatibility or stream
## sequence values. Snapshot and delta payloads are confirmed replacement views.

const PROTOCOL_VERSION: int = 1
const MAX_GRANTS: int = 256
const MAX_REVISION: int = 2_147_483_647
const MAX_SEQUENCE: int = 2_147_483_647

const SNAPSHOT_RESULT_KEYS := PackedStringArray([
	"ok", "reason", "revision", "payload",
])
const DELTA_RESULT_KEYS := PackedStringArray([
	"ok", "reason", "predecessor_revision", "revision", "payload",
])

var last_error: StringName = &""

var _sessions: ZProductSessionRegistry
var _projection: ZReplicationProjectionPort
var _grants: Dictionary = {}
var _next_sequence_by_grant: Dictionary = {}
var _last_revision_by_grant: Dictionary = {}
var _configured: bool = false


func configure(
	sessions: ZProductSessionRegistry,
	projection: ZReplicationProjectionPort
) -> bool:
	last_error = &""
	if _configured:
		return _reject(&"replication_egress_already_configured")
	if sessions == null or projection == null:
		return _reject(&"replication_egress_invalid_config")
	_sessions = sessions
	_projection = projection
	_configured = true
	return true


func grant(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> bool:
	last_error = &""
	if not _configured:
		return _reject(&"replication_egress_not_configured")
	if not _valid_channel(channel):
		return _reject(&"replication_channel_invalid")
	if not ZIdentityRules.is_valid_part(String(subject)):
		return _reject(&"replication_subject_invalid")
	var current := _current_admission(admission)
	if current == null:
		return _reject(&"replication_recipient_not_active")
	var key := _grant_key(current, channel, subject)
	if _grants.has(key):
		return true
	if _grants.size() >= MAX_GRANTS:
		return _reject(&"replication_grant_capacity_full")
	_grants[key] = _grant_record(current, channel, subject)
	_next_sequence_by_grant[key] = 1
	_last_revision_by_grant[key] = -1
	return true


func revoke(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> bool:
	last_error = &""
	if not _configured:
		return _reject(&"replication_egress_not_configured")
	if admission == null or not admission.is_usable():
		return _reject(&"replication_recipient_invalid")
	if not _valid_channel(channel):
		return _reject(&"replication_channel_invalid")
	if not ZIdentityRules.is_valid_part(String(subject)):
		return _reject(&"replication_subject_invalid")
	var key := _grant_key(admission, channel, subject)
	if not _grants.has(key):
		return _reject(&"replication_grant_missing")
	_remove_grant(key)
	return true


func revoke_recipient(admission: ZSessionAdmission) -> int:
	last_error = &""
	if not _configured or admission == null or not admission.is_usable():
		last_error = &"replication_recipient_invalid"
		return 0
	var removed := 0
	for key_value: Variant in _grants.keys():
		var key := String(key_value)
		var record: Dictionary = _grants.get(key, {}) as Dictionary
		if _record_matches_recipient(record, admission):
			_remove_grant(key)
			removed += 1
	return removed


func snapshot_for_peer(
	transport_peer_id: int,
	channel: StringName,
	subject: StringName
) -> Dictionary:
	last_error = &""
	var context := _route_context(transport_peer_id, channel, subject)
	if not bool(context.get("ok", false)):
		return _route_reject(StringName(context.get(
			"reason", &"replication_route_invalid"
		)))
	var admission: ZSessionAdmission = context["admission"]
	var grant_key := String(context["grant_key"])
	var projected: Dictionary = _projection.snapshot(
		admission.snapshot(), channel, subject
	)
	if not _has_exact_keys(projected, SNAPSHOT_RESULT_KEYS):
		return _route_reject(&"replication_projection_result_invalid")
	if not bool(projected["ok"]):
		return _route_reject(_projection_reason(projected))
	if typeof(projected["revision"]) != TYPE_INT:
		return _route_reject(&"replication_projection_revision_invalid")
	var revision := int(projected["revision"])
	var last_revision := int(_last_revision_by_grant.get(grant_key, -1))
	if revision < 0 or revision > MAX_REVISION or revision <= last_revision:
		return _route_reject(&"replication_projection_revision_invalid")
	if not projected["payload"] is Dictionary:
		return _route_reject(&"replication_projection_payload_invalid")
	var payload: Dictionary = (projected["payload"] as Dictionary).duplicate(true)
	if not ZCanonicalValue.is_bounded(payload):
		return _route_reject(&"replication_projection_payload_unbounded")
	return _publish(
		admission,
		grant_key,
		&"snapshot",
		channel,
		subject,
		-1,
		revision,
		payload
	)


func delta_for_peer(
	transport_peer_id: int,
	channel: StringName,
	subject: StringName,
	predecessor_revision: int
) -> Dictionary:
	last_error = &""
	if predecessor_revision < 0 or predecessor_revision > MAX_REVISION:
		return _route_reject(&"replication_predecessor_revision_invalid")
	var context := _route_context(transport_peer_id, channel, subject)
	if not bool(context.get("ok", false)):
		return _route_reject(StringName(context.get(
			"reason", &"replication_route_invalid"
		)))
	var admission: ZSessionAdmission = context["admission"]
	var grant_key := String(context["grant_key"])
	var last_revision := int(_last_revision_by_grant.get(grant_key, -1))
	if last_revision < 0 or predecessor_revision != last_revision:
		return _route_reject(&"replication_predecessor_revision_mismatch")
	var projected: Dictionary = _projection.delta(
		admission.snapshot(), channel, subject, predecessor_revision
	)
	if not _has_exact_keys(projected, DELTA_RESULT_KEYS):
		return _route_reject(&"replication_projection_result_invalid")
	if not bool(projected["ok"]):
		return _route_reject(_projection_reason(projected))
	if (
		typeof(projected["predecessor_revision"]) != TYPE_INT
		or typeof(projected["revision"]) != TYPE_INT
	):
		return _route_reject(&"replication_projection_revision_invalid")
	var projected_predecessor := int(projected["predecessor_revision"])
	var revision := int(projected["revision"])
	if (
		projected_predecessor != predecessor_revision
		or revision <= predecessor_revision
		or revision > MAX_REVISION
	):
		return _route_reject(&"replication_projection_revision_invalid")
	if not projected["payload"] is Dictionary:
		return _route_reject(&"replication_projection_payload_invalid")
	var payload: Dictionary = (projected["payload"] as Dictionary).duplicate(true)
	if not ZCanonicalValue.is_bounded(payload):
		return _route_reject(&"replication_projection_payload_unbounded")
	return _publish(
		admission,
		grant_key,
		&"delta",
		channel,
		subject,
		predecessor_revision,
		revision,
		payload
	)


func has_grant(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> bool:
	if not _configured or admission == null or not admission.is_usable():
		return false
	return _grants.has(_grant_key(admission, channel, subject))


func grant_count() -> int:
	return _grants.size()


func _route_context(
	transport_peer_id: int,
	channel: StringName,
	subject: StringName
) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": &"replication_egress_not_configured"}
	if not _valid_channel(channel):
		return {"ok": false, "reason": &"replication_channel_invalid"}
	if not ZIdentityRules.is_valid_part(String(subject)):
		return {"ok": false, "reason": &"replication_subject_invalid"}
	var admission := _sessions.admission_for_peer(transport_peer_id)
	if admission == null:
		return {"ok": false, "reason": &"replication_recipient_not_active"}
	var key := _grant_key(admission, channel, subject)
	var grant_record: Dictionary = _grants.get(key, {}) as Dictionary
	if grant_record.is_empty():
		return {"ok": false, "reason": &"replication_grant_missing"}
	if not _record_matches(grant_record, admission, channel, subject):
		return {"ok": false, "reason": &"replication_grant_stale"}
	return {
		"ok": true,
		"reason": &"",
		"admission": admission,
		"grant_key": key,
	}


func _publish(
	admission: ZSessionAdmission,
	grant_key: String,
	kind: StringName,
	channel: StringName,
	subject: StringName,
	predecessor_revision: int,
	revision: int,
	payload: Dictionary
) -> Dictionary:
	var sequence := int(_next_sequence_by_grant.get(grant_key, 0))
	if sequence <= 0 or sequence > MAX_SEQUENCE:
		return _route_reject(&"replication_sequence_exhausted")
	var envelope := {
		"version": PROTOCOL_VERSION,
		"kind": String(kind),
		"raid_id": admission.raid_id.canonical_key(),
		"channel": String(channel),
		"subject": String(subject),
		"recipient_session": admission.session_id.canonical_key(),
		"recipient_actor": admission.actor_id.canonical_key(),
		"recipient_peer": admission.transport_peer_id,
		"authority_epoch": admission.authority_epoch,
		"compatibility_digest": admission.compatibility_digest,
		"sequence": sequence,
		"predecessor_revision": predecessor_revision,
		"revision": revision,
		"payload": payload.duplicate(true),
	}
	if not ZCanonicalValue.is_bounded(envelope):
		return _route_reject(&"replication_envelope_unbounded")
	_next_sequence_by_grant[grant_key] = sequence + 1
	_last_revision_by_grant[grant_key] = revision
	return {
		"ok": true,
		"reason": &"",
		"transport_peer_id": admission.transport_peer_id,
		"envelope": envelope.duplicate(true),
	}


func _current_admission(admission: ZSessionAdmission) -> ZSessionAdmission:
	if (
		admission == null
		or not admission.is_usable()
		or admission.trust_level
			!= ZSessionAdmission.TrustLevel.REMOTE_AUTHENTICATED
	):
		return null
	var current := _sessions.admission_for_session(admission.session_id)
	return current if _same_recipient(current, admission) else null


func _remove_grant(key: String) -> void:
	_grants.erase(key)
	_next_sequence_by_grant.erase(key)
	_last_revision_by_grant.erase(key)


static func _same_recipient(
	left: ZSessionAdmission,
	right: ZSessionAdmission
) -> bool:
	return (
		left != null
		and right != null
		and left.is_usable()
		and right.is_usable()
		and left.raid_id.is_equal(right.raid_id)
		and left.session_id.is_equal(right.session_id)
		and left.actor_id.is_equal(right.actor_id)
		and left.transport_peer_id == right.transport_peer_id
		and left.authority_epoch == right.authority_epoch
		and left.compatibility_digest == right.compatibility_digest
	)


static func _grant_record(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> Dictionary:
	return {
		"raid_id": admission.raid_id.canonical_key(),
		"recipient_session": admission.session_id.canonical_key(),
		"recipient_actor": admission.actor_id.canonical_key(),
		"recipient_peer": admission.transport_peer_id,
		"authority_epoch": admission.authority_epoch,
		"compatibility_digest": admission.compatibility_digest,
		"channel": String(channel),
		"subject": String(subject),
	}


static func _record_matches_recipient(
	record: Dictionary,
	admission: ZSessionAdmission
) -> bool:
	return (
		String(record.get("raid_id", "")) == admission.raid_id.canonical_key()
		and String(record.get("recipient_session", ""))
			== admission.session_id.canonical_key()
		and String(record.get("recipient_actor", ""))
			== admission.actor_id.canonical_key()
		and int(record.get("recipient_peer", 0)) == admission.transport_peer_id
		and int(record.get("authority_epoch", 0)) == admission.authority_epoch
		and String(record.get("compatibility_digest", ""))
			== admission.compatibility_digest
	)


static func _record_matches(
	record: Dictionary,
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> bool:
	return (
		_record_matches_recipient(record, admission)
		and String(record.get("channel", "")) == String(channel)
		and String(record.get("subject", "")) == String(subject)
	)


static func _grant_key(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> String:
	return "%s|%s|%d|%d|%s|%s" % [
		admission.raid_id.canonical_key(),
		admission.session_id.canonical_key(),
		admission.transport_peer_id,
		admission.authority_epoch,
		String(channel),
		String(subject),
	]


static func _valid_channel(channel: StringName) -> bool:
	return channel in [&"inventory", &"weapon", &"ability", &"vision"]


static func _has_exact_keys(
	result: Dictionary,
	expected_keys: PackedStringArray
) -> bool:
	if result.size() != expected_keys.size():
		return false
	for key in expected_keys:
		if not result.has(key):
			return false
	return typeof(result["ok"]) == TYPE_BOOL


static func _projection_reason(result: Dictionary) -> StringName:
	var reason_value: Variant = result.get(
		"reason", &"replication_projection_rejected"
	)
	if reason_value is StringName:
		return reason_value as StringName
	if reason_value is String and not String(reason_value).is_empty():
		return StringName(reason_value)
	return &"replication_projection_rejected"


func _route_reject(code: StringName) -> Dictionary:
	last_error = code
	return {
		"ok": false,
		"reason": code,
		"transport_peer_id": 0,
		"envelope": {},
	}


func _reject(code: StringName) -> bool:
	last_error = code
	return false
