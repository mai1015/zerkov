class_name ZProductSessionRegistry
extends RefCounted
## Server-owned authenticated session, actor ownership and command-sequence fence.
##
## This registry does not execute gameplay, retain credentials or implement
## reconnect/resync. A remote-command adapter must pass this gate before it
## creates an internal ZRaidIntent for RaidAuthority.

const MAX_ACTIVE_SESSIONS: int = 64
const MAX_COMMAND_SEQUENCE: int = 2_147_483_647

var last_error: StringName = &""

var _raid_id: ZRaidId
var _by_session: Dictionary = {}
var _session_by_actor: Dictionary = {}
var _session_by_peer: Dictionary = {}
var _principal_by_actor: Dictionary = {}
var _retired_epoch_by_actor: Dictionary = {}
var _next_sequence_by_session: Dictionary = {}


func _init(raid_id: ZRaidId) -> void:
	if raid_id != null and raid_id.is_initialized():
		_raid_id = ZRaidId.parse(raid_id.canonical_key())


func activate(admission: ZSessionAdmission) -> bool:
	last_error = &""
	if (
		admission == null
		or not admission.is_usable()
		or admission.trust_level != ZSessionAdmission.TrustLevel.REMOTE_AUTHENTICATED
	):
		return _reject(&"remote_admission_required")
	if _raid_id == null:
		return _reject(&"registry_raid_invalid")
	var frozen := admission.snapshot()
	if frozen == null:
		return _reject(&"admission_snapshot_invalid")
	if not frozen.raid_id.is_equal(_raid_id):
		return _reject(&"raid_mismatch")

	var session_key := frozen.session_id.canonical_key()
	var actor_key := frozen.actor_id.canonical_key()
	var peer_id := frozen.transport_peer_id
	if _by_session.has(session_key):
		return _reject(&"session_already_active")
	if (
		_principal_by_actor.has(actor_key)
		and StringName(_principal_by_actor[actor_key]) != frozen.principal_key
	):
		return _reject(&"actor_owned_by_another_principal")
	var retired_floor := int(_retired_epoch_by_actor.get(actor_key, 0))

	var replaced: ZSessionAdmission = null
	if _session_by_actor.has(actor_key):
		var replaced_key := String(_session_by_actor[actor_key])
		replaced = _by_session.get(replaced_key) as ZSessionAdmission
		if replaced == null:
			return _reject(&"registry_state_invalid")
		if replaced.principal_key != frozen.principal_key:
			return _reject(&"actor_owned_by_another_principal")
		if (
			replaced.profile_key != frozen.profile_key
			or replaced.actor_slot != frozen.actor_slot
		):
			return _reject(&"actor_claim_changed")
		if frozen.authority_epoch <= replaced.authority_epoch:
			return _reject(&"authority_epoch_not_newer")
	elif frozen.authority_epoch <= retired_floor:
		return _reject(&"authority_epoch_retired")

	if _session_by_peer.has(peer_id):
		var peer_session_key := String(_session_by_peer[peer_id])
		if replaced == null or peer_session_key != replaced.session_id.canonical_key():
			return _reject(&"transport_peer_already_bound")
	if replaced == null and _by_session.size() >= MAX_ACTIVE_SESSIONS:
		return _reject(&"session_capacity_full")

	if replaced != null:
		_remove_active(replaced, true)
	_by_session[session_key] = frozen
	_session_by_actor[actor_key] = session_key
	_session_by_peer[peer_id] = session_key
	_principal_by_actor[actor_key] = frozen.principal_key
	_next_sequence_by_session[session_key] = 1
	return true


func command_rejection(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	transport_peer_id: int,
	authority_epoch: int,
	sequence: int
) -> StringName:
	if session_id == null or not session_id.is_initialized():
		return &"session_id_invalid"
	if actor_id == null or not actor_id.is_initialized():
		return &"actor_id_invalid"
	if transport_peer_id <= 1 or transport_peer_id > ZSessionRequest.MAX_TRANSPORT_PEER_ID:
		return &"transport_peer_invalid"
	if authority_epoch <= 0:
		return &"authority_epoch_invalid"
	if sequence <= 0 or sequence > MAX_COMMAND_SEQUENCE:
		return &"command_sequence_out_of_bounds"

	var session_key := session_id.canonical_key()
	var current := _by_session.get(session_key) as ZSessionAdmission
	if current == null:
		return &"session_not_active"
	if not current.actor_id.is_equal(actor_id):
		return &"actor_not_owned"
	if current.transport_peer_id != transport_peer_id:
		return &"transport_peer_mismatch"
	if current.authority_epoch != authority_epoch:
		return &"authority_epoch_mismatch"
	var expected := int(_next_sequence_by_session.get(session_key, 0))
	if expected <= 0:
		return &"registry_state_invalid"
	if expected > MAX_COMMAND_SEQUENCE:
		return &"command_sequence_exhausted"
	if sequence < expected:
		return &"command_sequence_replayed"
	if sequence > expected:
		return &"command_sequence_gap"
	return &""


func admit_command(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	transport_peer_id: int,
	authority_epoch: int,
	sequence: int
) -> bool:
	last_error = &""
	var rejection := command_rejection(
		session_id,
		actor_id,
		transport_peer_id,
		authority_epoch,
		sequence
	)
	if not rejection.is_empty():
		return _reject(rejection)
	var session_key := session_id.canonical_key()
	_next_sequence_by_session[session_key] = sequence + 1
	return true


func owns_actor(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	transport_peer_id: int,
	authority_epoch: int
) -> bool:
	if session_id == null or actor_id == null:
		return false
	var current := _by_session.get(session_id.canonical_key()) as ZSessionAdmission
	return (
		current != null
		and current.actor_id.is_equal(actor_id)
		and current.transport_peer_id == transport_peer_id
		and current.authority_epoch == authority_epoch
	)


func retire(session_id: ZSessionId, authority_epoch: int) -> bool:
	last_error = &""
	if session_id == null or not session_id.is_initialized():
		return _reject(&"session_id_invalid")
	var current := _by_session.get(session_id.canonical_key()) as ZSessionAdmission
	if current == null:
		return _reject(&"session_not_active")
	if current.authority_epoch != authority_epoch:
		return _reject(&"authority_epoch_mismatch")
	_remove_active(current, true)
	return true


func admission_for_session(session_id: ZSessionId) -> ZSessionAdmission:
	if session_id == null or not session_id.is_initialized():
		return null
	var current := _by_session.get(session_id.canonical_key()) as ZSessionAdmission
	return current.snapshot() if current != null else null


func admission_for_actor(actor_id: ZEntityId) -> ZSessionAdmission:
	if actor_id == null or not actor_id.is_initialized():
		return null
	var session_key := String(_session_by_actor.get(actor_id.canonical_key(), ""))
	var current := _by_session.get(session_key) as ZSessionAdmission
	return current.snapshot() if current != null else null


func admission_for_peer(transport_peer_id: int) -> ZSessionAdmission:
	if transport_peer_id <= 1 or transport_peer_id > ZSessionRequest.MAX_TRANSPORT_PEER_ID:
		return null
	var session_key := String(_session_by_peer.get(transport_peer_id, ""))
	var current := _by_session.get(session_key) as ZSessionAdmission
	return current.snapshot() if current != null else null


func next_command_sequence(session_id: ZSessionId) -> int:
	if session_id == null or not session_id.is_initialized():
		return 0
	return int(_next_sequence_by_session.get(session_id.canonical_key(), 0))


func active_session_count() -> int:
	return _by_session.size()


func _remove_active(admission: ZSessionAdmission, record_epoch: bool) -> void:
	var session_key := admission.session_id.canonical_key()
	var actor_key := admission.actor_id.canonical_key()
	_by_session.erase(session_key)
	_next_sequence_by_session.erase(session_key)
	if String(_session_by_actor.get(actor_key, "")) == session_key:
		_session_by_actor.erase(actor_key)
	if String(_session_by_peer.get(admission.transport_peer_id, "")) == session_key:
		_session_by_peer.erase(admission.transport_peer_id)
	if record_epoch:
		_retired_epoch_by_actor[actor_key] = maxi(
			int(_retired_epoch_by_actor.get(actor_key, 0)),
			admission.authority_epoch
		)


func _reject(code: StringName) -> bool:
	last_error = code
	return false
