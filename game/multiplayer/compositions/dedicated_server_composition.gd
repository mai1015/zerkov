class_name ZDedicatedServerComposition
extends Node
## Transport-neutral dedicated-server composition for tasks 10.3-10.5.
##
## The server owns canonical RaidAuthority, remote sessions, command admission
## and exact-recipient confirmed-state egress. It starts no network peer by
## itself. New remote actors must be admitted while PREPARING; a newer session
## for an already-authorized stable actor may replace its transport binding.

var last_error: StringName = &""
var _raid_id: ZRaidId
var _server_admission: ZSessionAdmission
var _raid: RaidAuthority
var _sessions: ZProductSessionRegistry
var _command_gate: ZRemoteCommandGate
var _replication_egress: ZGrantScopedReplicationEgress
var _configured: bool = false


func configure(
	raid_id: ZRaidId,
	seed: int,
	policy: ZRemoteCommandPolicyPort,
	projection: ZReplicationProjectionPort = null
) -> bool:
	last_error = &""
	if _configured:
		return _reject(&"server_composition_already_configured")
	if raid_id == null or not raid_id.is_initialized() or seed <= 0 or policy == null:
		return _reject(&"server_composition_invalid_config")
	var coordinator := SessionCoordinator.new()
	var admission := coordinator.open_offline(
		raid_id, &"server_authority", &"authority")
	if admission == null or not admission.is_usable():
		return _reject(&"server_authority_admission_failed")
	var raid := RaidAuthority.new()
	if not raid.configure(raid_id, admission, seed):
		return _reject(raid.last_error)
	var sessions := ZProductSessionRegistry.new(raid_id)
	var gate := ZRemoteCommandGate.new()
	if not gate.configure(raid, sessions, policy):
		return _reject(gate.last_error)
	var projection_port := projection
	if projection_port == null:
		projection_port = ZReplicationProjectionPort.new()
	var egress := ZGrantScopedReplicationEgress.new()
	if not egress.configure(sessions, projection_port):
		return _reject(egress.last_error)
	_raid_id = ZRaidId.parse(raid_id.canonical_key())
	_server_admission = admission.snapshot()
	_raid = raid
	_sessions = sessions
	_command_gate = gate
	_replication_egress = egress
	_configured = true
	return true


func canonical_role() -> StringName:
	return &"dedicated_server"


func has_canonical_authority() -> bool:
	return _configured and _raid != null


func raid_authority() -> RaidAuthority:
	return _raid


func server_admission() -> ZSessionAdmission:
	return _server_admission.snapshot() if _server_admission != null else null


func admit_remote_session(admission: ZSessionAdmission) -> bool:
	last_error = &""
	if not _configured or admission == null:
		return _reject(&"server_composition_not_configured")
	var replaced := _sessions.admission_for_actor(admission.actor_id)
	if not _sessions.activate(admission):
		return _reject(_sessions.last_error)
	if replaced != null:
		_replication_egress.revoke_recipient(replaced)
		if replaced.transport_peer_id != admission.transport_peer_id:
			_command_gate.clear_peer_rate_state(replaced.transport_peer_id)
	var actor := admission.actor_id
	var generation := _raid.generation()
	if _raid.has_authorized_actor_source(actor, ZRaidIntent.Source.PLAYER, generation):
		return true
	if _raid.lifecycle != RaidAuthority.Lifecycle.PREPARING:
		_sessions.retire(admission.session_id, admission.authority_epoch)
		return _reject(&"remote_actor_authorization_closed")
	if not _raid.authorize_actor(actor, ZRaidIntent.Source.PLAYER, generation):
		_sessions.retire(admission.session_id, admission.authority_epoch)
		return _reject(_raid.last_error)
	return true


func retire_remote_session(admission: ZSessionAdmission) -> bool:
	last_error = &""
	if not _configured or admission == null:
		return _reject(&"server_composition_not_configured")
	_replication_egress.revoke_recipient(admission)
	if not _sessions.retire(admission.session_id, admission.authority_epoch):
		return _reject(_sessions.last_error)
	_command_gate.clear_peer_rate_state(admission.transport_peer_id)
	return true


func start_raid() -> bool:
	last_error = &""
	if not _configured:
		return _reject(&"server_composition_not_configured")
	if not _raid.transition(RaidAuthority.Lifecycle.ACTIVE, _raid.generation()):
		return _reject(_raid.last_error)
	return true


func submit_remote_command(
	transport_peer_id: int,
	wire_size_bytes: int,
	command: Variant
) -> Dictionary:
	if not _configured:
		return {
			"accepted": false,
			"reason": &"server_composition_not_configured",
			"gate_trace": PackedStringArray(),
		}
	return _command_gate.admit_remote_command(
		transport_peer_id, wire_size_bytes, command)


func grant_replication(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> bool:
	last_error = &""
	if not _configured:
		return _reject(&"server_composition_not_configured")
	if not _replication_egress.grant(admission, channel, subject):
		return _reject(_replication_egress.last_error)
	return true


func revoke_replication(
	admission: ZSessionAdmission,
	channel: StringName,
	subject: StringName
) -> bool:
	last_error = &""
	if not _configured:
		return _reject(&"server_composition_not_configured")
	if not _replication_egress.revoke(admission, channel, subject):
		return _reject(_replication_egress.last_error)
	return true


func replication_snapshot_for_peer(
	transport_peer_id: int,
	channel: StringName,
	subject: StringName
) -> Dictionary:
	if not _configured:
		return _replication_reject(&"server_composition_not_configured")
	return _replication_egress.snapshot_for_peer(
		transport_peer_id, channel, subject)


func replication_delta_for_peer(
	transport_peer_id: int,
	channel: StringName,
	subject: StringName,
	predecessor_revision: int
) -> Dictionary:
	if not _configured:
		return _replication_reject(&"server_composition_not_configured")
	return _replication_egress.delta_for_peer(
		transport_peer_id, channel, subject, predecessor_revision)


func replication_grant_count() -> int:
	return _replication_egress.grant_count() \
		if _replication_egress != null else 0


func remote_session_count() -> int:
	return _sessions.active_session_count() if _sessions != null else 0


static func _replication_reject(code: StringName) -> Dictionary:
	return {
		"ok": false,
		"reason": code,
		"transport_peer_id": 0,
		"envelope": {},
	}


func _reject(code: StringName) -> bool:
	last_error = code
	return false
