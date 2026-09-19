class_name ZClientReplicaStore
extends RefCounted
## Bounded client-only confirmed-state holder. No authority or command execution.
##
## Product replication envelopes are accepted only after binding one exact
## authenticated recipient tuple. Both snapshots and deltas carry confirmed
## replacement views; pending prediction belongs to task 10.7, not this store.

const PROTOCOL_VERSION: int = 1
const MAX_CHANNELS: int = 32
const MAX_REVISION: int = 2_147_483_647
const MAX_SEQUENCE: int = 2_147_483_647
const ENVELOPE_KEYS := PackedStringArray([
	"version", "kind", "raid_id", "channel", "subject",
	"recipient_session", "recipient_actor", "recipient_peer",
	"authority_epoch", "compatibility_digest", "sequence",
	"predecessor_revision", "revision", "payload",
])

var last_error: StringName = &""
var _state_by_stream: Dictionary = {}
var _revision_by_stream: Dictionary = {}
var _next_sequence_by_stream: Dictionary = {}

var _recipient_bound: bool = false
var _raid_id: String = ""
var _recipient_session: String = ""
var _recipient_actor: String = ""
var _recipient_peer: int = 0
var _authority_epoch: int = 0
var _compatibility_digest: String = ""


func bind_recipient(admission: ZSessionAdmission) -> bool:
	last_error = &""
	if (
		admission == null
		or not admission.is_usable()
		or admission.trust_level
			!= ZSessionAdmission.TrustLevel.REMOTE_AUTHENTICATED
	):
		return _reject(&"replica_recipient_invalid")
	var same := (
		_recipient_bound
		and _raid_id == admission.raid_id.canonical_key()
		and _recipient_session == admission.session_id.canonical_key()
		and _recipient_actor == admission.actor_id.canonical_key()
		and _recipient_peer == admission.transport_peer_id
		and _authority_epoch == admission.authority_epoch
		and _compatibility_digest == admission.compatibility_digest
	)
	if same:
		return true
	_clear_state()
	_raid_id = admission.raid_id.canonical_key()
	_recipient_session = admission.session_id.canonical_key()
	_recipient_actor = admission.actor_id.canonical_key()
	_recipient_peer = admission.transport_peer_id
	_authority_epoch = admission.authority_epoch
	_compatibility_digest = admission.compatibility_digest
	_recipient_bound = true
	return true


## Legacy bounded snapshot seam retained for the Phase B composition contract.
func apply_snapshot(channel: StringName, revision: int, payload: Dictionary) -> bool:
	last_error = &""
	if not ZIdentityRules.is_valid_part(String(channel)):
		return _reject(&"replica_channel_invalid")
	if revision < 0 or revision > MAX_REVISION:
		return _reject(&"replica_revision_out_of_bounds")
	if not ZCanonicalValue.is_bounded(payload):
		return _reject(&"replica_payload_invalid_or_unbounded")
	var stream := _legacy_stream_key(channel)
	if not _state_by_stream.has(stream) and _state_by_stream.size() >= MAX_CHANNELS:
		return _reject(&"replica_channel_capacity_full")
	var current := int(_revision_by_stream.get(stream, -1))
	if revision <= current:
		return _reject(&"replica_revision_not_newer")
	_state_by_stream[stream] = payload.duplicate(true)
	_revision_by_stream[stream] = revision
	return true


func apply_envelope(envelope: Dictionary) -> bool:
	last_error = &""
	if not _recipient_bound:
		return _reject(&"replica_recipient_not_bound")
	if not _has_exact_keys(envelope, ENVELOPE_KEYS):
		return _reject(&"replica_envelope_shape_invalid")
	if not ZCanonicalValue.is_bounded(envelope):
		return _reject(&"replica_envelope_unbounded")
	if typeof(envelope["version"]) != TYPE_INT \
			or int(envelope["version"]) != PROTOCOL_VERSION:
		return _reject(&"replica_protocol_version_invalid")
	for key in [
		"kind", "raid_id", "channel", "subject", "recipient_session",
		"recipient_actor", "compatibility_digest",
	]:
		if typeof(envelope[key]) != TYPE_STRING:
			return _reject(&"replica_envelope_type_invalid")
	for key in [
		"recipient_peer", "authority_epoch", "sequence",
		"predecessor_revision", "revision",
	]:
		if typeof(envelope[key]) != TYPE_INT:
			return _reject(&"replica_envelope_type_invalid")
	if not envelope["payload"] is Dictionary:
		return _reject(&"replica_envelope_type_invalid")

	if (
		String(envelope["raid_id"]) != _raid_id
		or String(envelope["recipient_session"]) != _recipient_session
		or String(envelope["recipient_actor"]) != _recipient_actor
		or int(envelope["recipient_peer"]) != _recipient_peer
		or int(envelope["authority_epoch"]) != _authority_epoch
		or String(envelope["compatibility_digest"]) != _compatibility_digest
	):
		return _reject(&"replica_recipient_mismatch")

	var kind := StringName(envelope["kind"])
	if kind not in [&"snapshot", &"delta"]:
		return _reject(&"replica_envelope_kind_invalid")
	var channel := StringName(envelope["channel"])
	var subject := StringName(envelope["subject"])
	if not _valid_replication_channel(channel):
		return _reject(&"replica_channel_invalid")
	if not ZIdentityRules.is_valid_part(String(subject)):
		return _reject(&"replica_subject_invalid")
	var stream := _stream_key(channel, subject)
	if not _state_by_stream.has(stream) and _state_by_stream.size() >= MAX_CHANNELS:
		return _reject(&"replica_channel_capacity_full")

	var sequence := int(envelope["sequence"])
	if sequence <= 0 or sequence > MAX_SEQUENCE:
		return _reject(&"replica_sequence_out_of_bounds")
	var expected_sequence := int(_next_sequence_by_stream.get(stream, 1))
	if sequence < expected_sequence:
		return _reject(&"replica_sequence_replayed")
	if sequence > expected_sequence:
		return _reject(&"replica_sequence_gap")

	var predecessor_revision := int(envelope["predecessor_revision"])
	var revision := int(envelope["revision"])
	if revision < 0 or revision > MAX_REVISION:
		return _reject(&"replica_revision_out_of_bounds")
	var current_revision := int(_revision_by_stream.get(stream, -1))
	if kind == &"snapshot":
		if predecessor_revision != -1:
			return _reject(&"replica_snapshot_predecessor_invalid")
		if revision <= current_revision:
			return _reject(&"replica_revision_not_newer")
	else:
		if current_revision < 0:
			return _reject(&"replica_delta_without_snapshot")
		if predecessor_revision != current_revision:
			return _reject(&"replica_predecessor_revision_mismatch")
		if revision <= current_revision:
			return _reject(&"replica_revision_not_newer")

	var payload: Dictionary = (envelope["payload"] as Dictionary).duplicate(true)
	if not ZCanonicalValue.is_bounded(payload):
		return _reject(&"replica_payload_invalid_or_unbounded")
	_state_by_stream[stream] = payload
	_revision_by_stream[stream] = revision
	_next_sequence_by_stream[stream] = sequence + 1
	return true


func state(channel: StringName) -> Dictionary:
	var current: Dictionary = _state_by_stream.get(
		_legacy_stream_key(channel), {}
	) as Dictionary
	return current.duplicate(true)


func revision(channel: StringName) -> int:
	return int(_revision_by_stream.get(_legacy_stream_key(channel), -1))


func state_for(channel: StringName, subject: StringName) -> Dictionary:
	var current: Dictionary = _state_by_stream.get(
		_stream_key(channel, subject), {}
	) as Dictionary
	return current.duplicate(true)


func revision_for(channel: StringName, subject: StringName) -> int:
	return int(_revision_by_stream.get(_stream_key(channel, subject), -1))


func next_sequence_for(channel: StringName, subject: StringName) -> int:
	return int(_next_sequence_by_stream.get(_stream_key(channel, subject), 1))


func channel_count() -> int:
	return _state_by_stream.size()


func is_recipient_bound() -> bool:
	return _recipient_bound


func clear() -> void:
	_clear_state()
	_recipient_bound = false
	_raid_id = ""
	_recipient_session = ""
	_recipient_actor = ""
	_recipient_peer = 0
	_authority_epoch = 0
	_compatibility_digest = ""
	last_error = &""


func _clear_state() -> void:
	_state_by_stream.clear()
	_revision_by_stream.clear()
	_next_sequence_by_stream.clear()


static func _legacy_stream_key(channel: StringName) -> String:
	return "legacy|%s" % String(channel)


static func _stream_key(channel: StringName, subject: StringName) -> String:
	return "%s|%s" % [String(channel), String(subject)]


static func _valid_replication_channel(channel: StringName) -> bool:
	return channel in [&"inventory", &"weapon", &"ability", &"vision"]


static func _has_exact_keys(
	value: Dictionary,
	expected: PackedStringArray
) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


func _reject(code: StringName) -> bool:
	last_error = code
	return false
