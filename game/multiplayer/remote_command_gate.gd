class_name ZRemoteCommandGate
extends RefCounted
## Product-owned fail-closed ingress for untrusted remote gameplay commands.
## The trusted transport supplies actual received byte count plus decoded values.

const MAX_WIRE_BYTES: int = 4096
const MAX_PACKETS_PER_WINDOW: int = 32
const RATE_WINDOW_TICKS: int = 60
const MAX_TRACKED_PEERS: int = 256
const MAX_INTERNAL_SEQUENCE: int = 2_147_483_647
const COMMAND_KEYS: PackedStringArray = [
	"actor_id", "authority_epoch", "base_revision", "compatibility_digest",
	"kind", "payload", "sequence", "session_id",
]

var last_error: StringName = &""
var last_gate_trace: PackedStringArray = PackedStringArray()
var _authority: RaidAuthority
var _registry: ZProductSessionRegistry
var _policy: ZRemoteCommandPolicyPort
var _authority_admission: ZSessionAdmission
var _rate_by_peer: Dictionary = {}
var _next_internal_sequence_by_actor: Dictionary = {}
var _inside_admission: bool = false

func configure(
	authority: RaidAuthority,
	registry: ZProductSessionRegistry,
	policy: ZRemoteCommandPolicyPort
) -> bool:
	last_error = &""
	if _authority != null or _registry != null or _policy != null:
		return _reject_config(&"remote_gate_already_configured")
	if authority == null or registry == null or policy == null:
		return _reject_config(&"remote_gate_dependency_missing")
	var admission := authority.admission()
	if admission == null or not admission.is_usable() 			or admission.trust_level != ZSessionAdmission.TrustLevel.LOCAL_TRUSTED:
		return _reject_config(&"server_authority_admission_required")
	if authority.generation() <= 0:
		return _reject_config(&"server_authority_generation_invalid")
	_authority = authority
	_registry = registry
	_policy = policy
	_authority_admission = admission.snapshot()
	return _authority_admission != null

func is_configured() -> bool:
	return _authority != null and _registry != null and _policy != null 		and _authority_admission != null

func admit_remote_command(
	transport_peer_id: int,
	wire_size_bytes: int,
	command: Variant
) -> Dictionary:
	last_error = &""
	last_gate_trace = PackedStringArray()
	if _inside_admission:
		return _reject_receipt(&"remote_gate_reentrant")
	if not is_configured():
		return _reject_receipt(&"remote_gate_not_configured")
	_inside_admission = true
	var result := _admit_remote_command_inner(transport_peer_id, wire_size_bytes, command)
	_inside_admission = false
	return result

func _admit_remote_command_inner(
	transport_peer_id: int,
	wire_size_bytes: int,
	command: Variant
) -> Dictionary:
	last_gate_trace.append("size")
	if wire_size_bytes <= 0 or wire_size_bytes > MAX_WIRE_BYTES:
		return _reject_receipt(&"remote_command_size_out_of_bounds")

	var server_tick := _authority.last_processed_tick
	last_gate_trace.append("rate")
	var rate_reason := _charge_rate(transport_peer_id, server_tick)
	if not rate_reason.is_empty():
		return _reject_receipt(rate_reason)

	last_gate_trace.append("shape")
	var decoded := _decode_command(command)
	if not bool(decoded.get("ok", false)):
		return _reject_receipt(StringName(decoded.get("reason", &"remote_command_shape_invalid")))

	var session_id := decoded["session_id"] as ZSessionId
	var actor_id := decoded["actor_id"] as ZEntityId
	var authority_epoch := int(decoded["authority_epoch"])
	var sequence := int(decoded["sequence"])
	var kind := StringName(decoded["kind"])
	var payload := (decoded["payload"] as Dictionary).duplicate(true)

	last_gate_trace.append("session")
	var remote_admission := _registry.admission_for_session(session_id)
	if remote_admission == null or remote_admission.transport_peer_id != transport_peer_id:
		return _reject_receipt(&"remote_session_not_active")

	last_gate_trace.append("compatibility")
	if String(decoded["compatibility_digest"]) != remote_admission.compatibility_digest:
		return _reject_receipt(&"remote_compatibility_mismatch")

	last_gate_trace.append("ownership")
	if not _registry.owns_actor(session_id, actor_id, transport_peer_id, authority_epoch):
		return _reject_receipt(&"remote_actor_not_owned")

	last_gate_trace.append("relevance")
	if not _policy.is_relevant(
		remote_admission.snapshot(), kind, payload.duplicate(true), server_tick):
		return _reject_receipt(&"remote_command_not_relevant")

	last_gate_trace.append("sequence")
	var sequence_reason := _registry.command_rejection(
		session_id, actor_id, transport_peer_id, authority_epoch, sequence)
	if not sequence_reason.is_empty():
		return _reject_receipt(sequence_reason)

	last_gate_trace.append("revision")
	var expected_revision := _policy.expected_revision(
		remote_admission.snapshot(), kind, payload.duplicate(true), server_tick)
	if expected_revision < 0:
		return _reject_receipt(&"remote_revision_policy_unavailable")
	if int(decoded["base_revision"]) != expected_revision:
		return _reject_receipt(&"remote_revision_mismatch")

	last_gate_trace.append("semantic")
	var semantic_reason := _policy.validate_semantics(
		remote_admission.snapshot(), kind, payload.duplicate(true), server_tick)
	if not semantic_reason.is_empty():
		return _reject_receipt(semantic_reason)

	var actor_key := actor_id.canonical_key()
	var internal_sequence := int(_next_internal_sequence_by_actor.get(actor_key, 1))
	if internal_sequence <= 0 or internal_sequence > MAX_INTERNAL_SEQUENCE:
		return _reject_receipt(&"internal_command_sequence_exhausted")

	var current_authority_admission := _authority.admission()
	if current_authority_admission == null 			or not current_authority_admission.session_id.is_equal(_authority_admission.session_id) 			or current_authority_admission.authority_epoch != _authority_admission.authority_epoch:
		return _reject_receipt(&"server_authority_session_changed")

	var request_digest := ZCanonicalValue.sha256({
		"actor_id": actor_key,
		"remote_authority_epoch": authority_epoch,
		"remote_sequence": sequence,
		"remote_session_id": session_id.canonical_key(),
	})
	if request_digest.length() < 32:
		return _reject_receipt(&"internal_request_identity_failed")
	var request_id := ZRequestId.from_parts(PackedStringArray([
		"remote", request_digest.substr(0, 32), str(sequence),
	]))
	if request_id == null:
		return _reject_receipt(&"internal_request_identity_failed")

	var generation := _authority.generation()
	var target_tick := _authority.last_processed_tick + 1
	var intent := ZRaidIntent.create(
		request_id, ZRaidIntent.Source.PLAYER,
		current_authority_admission.session_id, actor_id,
		current_authority_admission.authority_epoch, generation,
		target_tick, internal_sequence, kind, payload)
	last_gate_trace.append("enqueue")
	if not _authority.enqueue_intent(intent, generation):
		return _reject_receipt(_authority.last_error)

	# The session registry preflight above was non-consuming. Commit its replay
	# fence only after canonical queue admission succeeds. No external callback is
	# invoked between preflight and this commit, so failure here is an invariant
	# violation rather than a normal client rejection.
	if not _registry.admit_command(
		session_id, actor_id, transport_peer_id, authority_epoch, sequence):
		return _reject_receipt(&"remote_sequence_commit_invariant_failed")

	_next_internal_sequence_by_actor[actor_key] = internal_sequence + 1
	return {
		"accepted": true,
		"reason": StringName(),
		"request_id": request_id.canonical_key(),
		"actor_id": actor_key,
		"remote_sequence": sequence,
		"internal_sequence": internal_sequence,
		"target_tick": target_tick,
		"gate_trace": last_gate_trace.duplicate(),
	}

func _decode_command(command: Variant) -> Dictionary:
	if typeof(command) != TYPE_DICTIONARY:
		return {"ok": false, "reason": &"remote_command_shape_invalid"}
	var command_dict := command as Dictionary
	if command_dict.size() != COMMAND_KEYS.size():
		return {"ok": false, "reason": &"remote_command_shape_invalid"}
	for key in command_dict.keys():
		if typeof(key) != TYPE_STRING or not COMMAND_KEYS.has(String(key)):
			return {"ok": false, "reason": &"remote_command_shape_invalid"}
	if not ZCanonicalValue.is_bounded(command_dict):
		return {"ok": false, "reason": &"remote_command_unbounded"}
	if typeof(command_dict.get("session_id", null)) != TYPE_STRING 			or typeof(command_dict.get("actor_id", null)) != TYPE_STRING 			or typeof(command_dict.get("authority_epoch", null)) != TYPE_INT 			or typeof(command_dict.get("sequence", null)) != TYPE_INT 			or typeof(command_dict.get("base_revision", null)) != TYPE_INT 			or typeof(command_dict.get("compatibility_digest", null)) != TYPE_STRING 			or (typeof(command_dict.get("kind", null)) != TYPE_STRING 				and typeof(command_dict.get("kind", null)) != TYPE_STRING_NAME) 			or typeof(command_dict.get("payload", null)) != TYPE_DICTIONARY:
		return {"ok": false, "reason": &"remote_command_type_invalid"}
	var session_id := ZSessionId.parse(String(command_dict["session_id"]))
	var actor_id := ZEntityId.parse(String(command_dict["actor_id"]))
	var kind := StringName(command_dict["kind"])
	if session_id == null or actor_id == null 			or int(command_dict["authority_epoch"]) <= 0 			or int(command_dict["sequence"]) <= 0 			or int(command_dict["sequence"]) > ZProductSessionRegistry.MAX_COMMAND_SEQUENCE 			or int(command_dict["base_revision"]) < 0 			or not ZProductCompatibilityManifest.is_sha256(String(command_dict["compatibility_digest"])) 			or not ZIdentityRules.is_valid_part(String(kind)):
		return {"ok": false, "reason": &"remote_command_value_invalid"}
	return {
		"ok": true,
		"session_id": session_id,
		"actor_id": actor_id,
		"authority_epoch": int(command_dict["authority_epoch"]),
		"sequence": int(command_dict["sequence"]),
		"base_revision": int(command_dict["base_revision"]),
		"compatibility_digest": String(command_dict["compatibility_digest"]),
		"kind": kind,
		"payload": (command_dict["payload"] as Dictionary).duplicate(true),
	}

func _charge_rate(transport_peer_id: int, server_tick: int) -> StringName:
	if transport_peer_id <= 1 or transport_peer_id > ZSessionRequest.MAX_TRANSPORT_PEER_ID:
		return &"remote_transport_peer_invalid"
	if server_tick < 0:
		return &"remote_rate_clock_invalid"
	var bucket := _rate_by_peer.get(transport_peer_id, {}) as Dictionary
	if bucket.is_empty():
		if _rate_by_peer.size() >= MAX_TRACKED_PEERS:
			return &"remote_rate_peer_capacity_full"
		_rate_by_peer[transport_peer_id] = {"start_tick": server_tick, "count": 1}
		return &""
	var start_tick := int(bucket.get("start_tick", -1))
	var count := int(bucket.get("count", 0))
	if start_tick < 0 or server_tick < start_tick:
		return &"remote_rate_clock_regressed"
	if server_tick - start_tick >= RATE_WINDOW_TICKS:
		bucket["start_tick"] = server_tick
		bucket["count"] = 1
		_rate_by_peer[transport_peer_id] = bucket
		return &""
	if count >= MAX_PACKETS_PER_WINDOW:
		return &"remote_rate_exceeded"
	bucket["count"] = count + 1
	_rate_by_peer[transport_peer_id] = bucket
	return &""

func clear_peer_rate_state(transport_peer_id: int) -> void:
	_rate_by_peer.erase(transport_peer_id)

func _reject_receipt(code: StringName) -> Dictionary:
	last_error = code
	return {"accepted": false, "reason": code, "gate_trace": last_gate_trace.duplicate()}

func _reject_config(code: StringName) -> bool:
	last_error = code
	return false
