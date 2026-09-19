extends RefCounted
## Phase B task 10.3/10.4 structural and adversarial contract.

class FakeAuthenticator:
	extends ZSessionAuthenticatorPort
	var expected_credential: PackedByteArray
	var grant: ZSessionAuthGrant
	func _init(p_expected_credential: PackedByteArray, p_grant: ZSessionAuthGrant) -> void:
		expected_credential = p_expected_credential.duplicate()
		grant = p_grant
	func authenticate(request: ZSessionRequest) -> ZSessionAuthGrant:
		if request == null or request.credential != expected_credential:
			return null
		return grant

class FakePolicy:
	extends ZRemoteCommandPolicyPort
	var relevant: bool = true
	var revision: int = 7
	var semantic_reason: StringName = &""
	var mutate_inputs: bool = false
	func is_relevant(admission: ZSessionAdmission, _kind: StringName,
			payload: Dictionary, _server_tick: int) -> bool:
		if mutate_inputs:
			admission.principal_key = &"forged"
			payload["dx"] = 999
		return relevant
	func expected_revision(admission: ZSessionAdmission, _kind: StringName,
			payload: Dictionary, _server_tick: int) -> int:
		if mutate_inputs:
			admission.profile_key = &"forged"
			payload["dy"] = 999
		return revision
	func validate_semantics(admission: ZSessionAdmission, kind: StringName,
			payload: Dictionary, _server_tick: int) -> StringName:
		if mutate_inputs:
			admission.actor_slot = &"forged"
			payload["dx"] = 777
		if not semantic_reason.is_empty():
			return semantic_reason
		if kind != &"move":
			return &"remote_semantic_kind_invalid"
		if payload.size() != 2 or not payload.has("dx") or not payload.has("dy") 				or typeof(payload["dx"]) != TYPE_INT or typeof(payload["dy"]) != TYPE_INT:
			return &"remote_semantic_payload_invalid"
		return &""

var checks: int = 0
var failures: int = 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("MULTIPLAYER_PHASE_B: " + message)

func run() -> Dictionary:
	_test_replica_scene_separation()
	_test_remote_command_gate()
	return {"checks": checks, "failures": failures}

func _test_replica_scene_separation() -> void:
	var server_scene := load("res://game/multiplayer/compositions/dedicated_server.tscn") as PackedScene
	var owner_scene := load("res://game/multiplayer/compositions/owning_client.tscn") as PackedScene
	var observer_scene := load("res://game/multiplayer/compositions/observer_client.tscn") as PackedScene
	check(server_scene != null and owner_scene != null and observer_scene != null,
		"all three role-separated multiplayer scenes load")
	if server_scene == null or owner_scene == null or observer_scene == null:
		return
	var owner := owner_scene.instantiate() as ZOwningClientComposition
	var observer := observer_scene.instantiate() as ZObserverClientComposition
	check(owner != null and owner.canonical_role() == &"owning_client"
			and not owner.has_canonical_authority() and not owner.has_method("raid_authority"),
		"owning client exposes replica role and no authority handle")
	check(observer != null and observer.canonical_role() == &"observer_client"
			and not observer.has_canonical_authority() and not observer.has_method("raid_authority"),
		"observer client exposes replica role and no authority handle")
	check(owner.apply_replica_snapshot(
			&"private_inventory", 1, {"slots": 2, "weight": 11}),
		"owning client accepts bounded private snapshot")
	check(observer.apply_replica_snapshot(
			&"public_actor", 1, {"pose_x": 10, "pose_y": 20}),
		"observer accepts independent public snapshot")
	check(owner.replica_store().state(&"public_actor").is_empty()
			and observer.replica_store().state(&"private_inventory").is_empty(),
		"owner and observer stores do not alias scoped state")
	var owner_copy := owner.replica_store().state(&"private_inventory")
	owner_copy["slots"] = 99
	check(int(owner.replica_store().state(&"private_inventory").get("slots", 0)) == 2,
		"replica reads return copies")
	check(not owner.apply_replica_snapshot(&"private_inventory", 1, {"slots": 3})
			and owner.replica_store().last_error == &"replica_revision_not_newer",
		"replica revisions are strictly monotonic")
	var banned := PackedStringArray([
		"RaidAuthority", "InventoryAuthority", "WeaponAuthority",
		"GameplayAbilityComponent", "SessionCoordinator", "ZProductSessionRegistry",
		"ZRemoteCommandGate",
	])
	for path in PackedStringArray([
		"res://game/multiplayer/compositions/owning_client_composition.gd",
		"res://game/multiplayer/compositions/observer_client_composition.gd",
	]):
		var file := FileAccess.open(path, FileAccess.READ)
		var source := file.get_as_text() if file != null else ""
		check(not source.is_empty(), "%s source is readable" % path)
		for token in banned:
			check(source.find(token) == -1,
				"%s contains no authority token %s" % [path, token])
	owner.free()
	observer.free()

func _test_remote_command_gate() -> void:
	var fingerprint := "a".repeat(64)
	var required := ZProductCompatibilityManifest.create(
		1, 3, fingerprint,
		PackedStringArray(["raid_intent_v1", "authoritative_inventory"]))
	var offered := ZProductCompatibilityManifest.create(
		1, 3, fingerprint,
		PackedStringArray(["authoritative_inventory", "raid_intent_v1"]))
	check(required != null and offered != null, "compatibility fixture constructs")
	var raid_id := ZRaidId.from_parts(PackedStringArray(["multiplayer", "phase_b_contract"]))
	var credential := PackedByteArray([4, 8, 15, 16, 23, 42])
	var grant := ZSessionAuthGrant.create(&"steam_phase_b", &"profile_phase_b", &"player")
	var coordinator := SessionCoordinator.new(
		AuthenticatedSessionIngress.new(FakeAuthenticator.new(credential, grant), required))
	var remote := coordinator.open_remote(
		raid_id, &"profile_phase_b", &"player", 31, &"client_a",
		credential, offered)
	check(remote.is_usable(), "remote owner session authenticates")

	var policy := FakePolicy.new()
	var scene := load("res://game/multiplayer/compositions/dedicated_server.tscn") as PackedScene
	var server := scene.instantiate() as ZDedicatedServerComposition
	check(server != null and server.canonical_role() == &"dedicated_server"
			and server.configure(raid_id, 20260919, policy)
			and server.has_canonical_authority(),
		"dedicated server owns canonical authority composition")
	if server == null or not server.has_canonical_authority():
		return
	check(server.admit_remote_session(remote) and server.remote_session_count() == 1,
		"remote actor binds before activation")
	var raid := server.raid_authority()
	var generation := raid.generation()
	var authority_admission := server.server_admission()
	check(authority_admission != null
			and authority_admission.trust_level == ZSessionAdmission.TrustLevel.LOCAL_TRUSTED
			and not authority_admission.session_id.is_equal(remote.session_id),
		"canonical authority uses server-owned session")
	check(server.start_raid(), "server activates canonical raid")

	var naive := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["phase_b", "naive_remote"])),
		ZRaidIntent.Source.PLAYER, remote.session_id, remote.actor_id,
		remote.authority_epoch, generation, 1, 1, &"move", {"dx": 1, "dy": 0})
	check(not raid.enqueue_intent(naive, generation) and raid.last_error == &"session_mismatch",
		"raw remote session cannot bypass product ingress")

	var command := _command(remote, 1, 7)
	var wire_size := _wire_size(command)
	check(wire_size > 0 and wire_size <= ZRemoteCommandGate.MAX_WIRE_BYTES,
		"valid fixture is within transport byte bound")

	var result := server.submit_remote_command(
		31, ZRemoteCommandGate.MAX_WIRE_BYTES + 1, command)
	check(not result.accepted and result.reason == &"remote_command_size_out_of_bounds"
			and result.gate_trace == PackedStringArray(["size"]),
		"size gate rejects first")

	var malformed := command.duplicate(true)
	malformed["unexpected"] = 1
	result = server.submit_remote_command(31, _wire_size(malformed), malformed)
	check(not result.accepted and result.reason == &"remote_command_shape_invalid",
		"exact command shape is mandatory")

	var large_blob := PackedByteArray()
	large_blob.resize(300)
	var unbounded := command.duplicate(true)
	unbounded["payload"] = {"blob": large_blob}
	result = server.submit_remote_command(31, 128, unbounded)
	check(not result.accepted and result.reason == &"remote_command_unbounded",
		"unbounded nested payload rejects")

	for _index in range(ZRemoteCommandGate.MAX_PACKETS_PER_WINDOW):
		result = server.submit_remote_command(900, 1, {})
	check(not result.accepted and result.reason == &"remote_command_shape_invalid",
		"junk is charged before shape rejection")
	result = server.submit_remote_command(900, 1, {})
	check(not result.accepted and result.reason == &"remote_rate_exceeded"
			and result.gate_trace == PackedStringArray(["size", "rate"]),
		"flood stops at rate gate")

	var missing := command.duplicate(true)
	missing["session_id"] = ZSessionId.from_parts(
		PackedStringArray(["remote", "ghost", "client", "00000001"])).canonical_key()
	result = server.submit_remote_command(31, _wire_size(missing), missing)
	check(not result.accepted and result.reason == &"remote_session_not_active",
		"inactive session rejects")

	var incompatible := command.duplicate(true)
	incompatible["compatibility_digest"] = "b".repeat(64)
	result = server.submit_remote_command(31, _wire_size(incompatible), incompatible)
	check(not result.accepted and result.reason == &"remote_compatibility_mismatch",
		"compatibility is bound per command")

	var forged := command.duplicate(true)
	forged["actor_id"] = ZEntityId.from_parts(
		PackedStringArray(["remote", "profile_other", "player"])).canonical_key()
	result = server.submit_remote_command(31, _wire_size(forged), forged)
	check(not result.accepted and result.reason == &"remote_actor_not_owned",
		"session cannot command unowned actor")

	policy.relevant = false
	result = server.submit_remote_command(31, wire_size, command)
	check(not result.accepted and result.reason == &"remote_command_not_relevant",
		"relevance rejects before sequence consumption")
	policy.relevant = true

	var bad_revision := command.duplicate(true)
	bad_revision["base_revision"] = 8
	result = server.submit_remote_command(31, _wire_size(bad_revision), bad_revision)
	check(not result.accepted and result.reason == &"remote_revision_mismatch",
		"revision mismatch rejects after sequence preflight")

	policy.semantic_reason = &"remote_semantic_fixture_rejected"
	result = server.submit_remote_command(31, wire_size, command)
	check(not result.accepted and result.reason == &"remote_semantic_fixture_rejected",
		"semantic policy fails closed")
	policy.semantic_reason = &""

	policy.mutate_inputs = true
	var accepted_one := server.submit_remote_command(31, wire_size, command)
	check(accepted_one.accepted and int(accepted_one.remote_sequence) == 1
			and int(accepted_one.internal_sequence) == 1
			and accepted_one.gate_trace == PackedStringArray([
				"size", "rate", "shape", "session", "compatibility", "ownership",
				"relevance", "sequence", "revision", "semantic", "enqueue"]),
		"valid command traverses required gates in order")
	check(int((command["payload"] as Dictionary)["dx"]) == 1
			and remote.principal_key == &"steam_phase_b"
			and remote.profile_key == &"profile_phase_b",
		"policy receives isolated snapshots and payload copies")

	result = server.submit_remote_command(31, wire_size, command)
	check(not result.accepted and result.reason == &"command_sequence_replayed",
		"accepted sequence cannot replay")
	var gap_command := _command(remote, 3, 7)
	result = server.submit_remote_command(31, _wire_size(gap_command), gap_command)
	check(not result.accepted and result.reason == &"command_sequence_gap",
		"future sequence gap rejects")
	var second := _command(remote, 2, 7)
	var accepted_two := server.submit_remote_command(31, _wire_size(second), second)
	check(accepted_two.accepted and int(accepted_two.internal_sequence) == 2,
		"next remote sequence maps to next canonical actor sequence")

	var other_grant := ZSessionAuthGrant.create(
		&"steam_other_phase_b", &"profile_other_phase_b", &"player")
	var other_coordinator := SessionCoordinator.new(
		AuthenticatedSessionIngress.new(
			FakeAuthenticator.new(credential, other_grant), required))
	var late_actor := other_coordinator.open_remote(
		raid_id, &"profile_other_phase_b", &"player", 41, &"late_client",
		credential, offered)
	check(late_actor.is_usable() and not server.admit_remote_session(late_actor)
			and server.last_error == &"remote_actor_authorization_closed"
			and server.remote_session_count() == 1,
		"new actor cannot join after PREPARING")

	var replacement := coordinator.open_remote(
		raid_id, &"profile_phase_b", &"player", 32, &"client_b",
		credential, offered)
	check(replacement.is_usable() and replacement.actor_id.is_equal(remote.actor_id)
			and replacement.authority_epoch > remote.authority_epoch,
		"replacement retains actor with newer epoch")
	check(server.admit_remote_session(replacement) and server.remote_session_count() == 1,
		"newer session replaces transport binding")
	var old_after_replace := _command(remote, 3, 7)
	result = server.submit_remote_command(31, _wire_size(old_after_replace), old_after_replace)
	check(not result.accepted and result.reason == &"remote_session_not_active",
		"retired session cannot issue late command")
	var replacement_first := _command(replacement, 1, 7)
	var replacement_result := server.submit_remote_command(
		32, _wire_size(replacement_first), replacement_first)
	check(replacement_result.accepted
			and int(replacement_result.remote_sequence) == 1
			and int(replacement_result.internal_sequence) == 3,
		"replacement resets remote sequence only; canonical sequence continues")
	server.free()

func _command(admission: ZSessionAdmission, sequence: int, base_revision: int) -> Dictionary:
	return {
		"actor_id": admission.actor_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"base_revision": base_revision,
		"compatibility_digest": admission.compatibility_digest,
		"kind": "move",
		"payload": {"dx": 1, "dy": 0},
		"sequence": sequence,
		"session_id": admission.session_id.canonical_key(),
	}

func _wire_size(command: Dictionary) -> int:
	var encoded := ZCanonicalValue.encode(command)
	return maxi(1, encoded.to_utf8_buffer().size())
