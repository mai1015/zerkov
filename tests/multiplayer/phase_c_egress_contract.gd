extends RefCounted
## Task 10.5 grant-scoped confirmed-state egress contract.
class Auth:
	extends ZSessionAuthenticatorPort
	var credential: PackedByteArray
	var grant_value: ZSessionAuthGrant
	func _init(value: PackedByteArray, grant: ZSessionAuthGrant) -> void:
		credential = value.duplicate()
		grant_value = grant
	func authenticate(request: ZSessionRequest) -> ZSessionAuthGrant:
		return grant_value if request != null and request.credential == credential else null
class CommandPolicy:
	extends ZRemoteCommandPolicyPort
	func is_relevant(_a: ZSessionAdmission, _k: StringName,
			_p: Dictionary, _t: int) -> bool:
		return true
	func expected_revision(_a: ZSessionAdmission, _k: StringName,
			_p: Dictionary, _t: int) -> int:
		return 0
	func validate_semantics(_a: ZSessionAdmission, _k: StringName,
			_p: Dictionary, _t: int) -> StringName:
		return &""
class Projection:
	extends ZReplicationProjectionPort
	var calls: int = 0
	var mode: StringName = &""
	var records: Dictionary = {}
	func seed(a: ZSessionAdmission, channel: StringName, subject: StringName,
			revision: int, payload: Dictionary) -> void:
		records[_key(a, channel, subject)] = {
			"revision": revision, "payload": payload.duplicate(true)}
	func advance(a: ZSessionAdmission, channel: StringName, subject: StringName,
			payload: Dictionary) -> int:
		var key := _key(a, channel, subject)
		var record: Dictionary = records.get(key, {}) as Dictionary
		var revision := int(record.get("revision", 0)) + 1
		seed(a, channel, subject, revision, payload)
		return revision
	func snapshot(a: ZSessionAdmission, channel: StringName,
			subject: StringName) -> Dictionary:
		calls += 1
		var record: Dictionary = records.get(_key(a, channel, subject), {}) as Dictionary
		if mode == &"shape":
			return {"ok": true, "reason": &"", "revision": 1,
				"payload": {}, "extra": true}
		if mode == &"reject":
			return {"ok": false, "reason": &"projection_rejected",
				"revision": -1, "payload": {}}
		if mode == &"unbounded":
			var bytes := PackedByteArray()
			bytes.resize(300)
			return {"ok": true, "reason": &"", "revision": 1,
				"payload": {"blob": bytes}}
		if record.is_empty():
			return {"ok": false, "reason": &"projection_missing",
				"revision": -1, "payload": {}}
		a.principal_key = &"forged_projection_principal"
		return {"ok": true, "reason": &"", "revision": int(record.revision),
			"payload": (record.payload as Dictionary).duplicate(true)}
	func delta(a: ZSessionAdmission, channel: StringName, subject: StringName,
			predecessor: int) -> Dictionary:
		calls += 1
		var record: Dictionary = records.get(_key(a, channel, subject), {}) as Dictionary
		if record.is_empty():
			return {"ok": false, "reason": &"projection_missing",
				"predecessor_revision": -1, "revision": -1, "payload": {}}
		var reported := predecessor + 1 if mode == &"predecessor" else predecessor
		return {"ok": true, "reason": &"", "predecessor_revision": reported,
			"revision": int(record.revision),
			"payload": (record.payload as Dictionary).duplicate(true)}
	static func _key(a: ZSessionAdmission, channel: StringName,
			subject: StringName) -> String:
		return "%s|%s|%s" % [a.actor_id.canonical_key(), channel, subject]
var checks := 0
var failures := 0
func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("MULTIPLAYER_PHASE_C_EGRESS: " + message)
func run() -> Dictionary:
	_test_egress()
	return {"checks": checks, "failures": failures}
func _test_egress() -> void:
	var fingerprint := "c".repeat(64)
	var features := PackedStringArray(["raid_intent_v1", "replication_egress_v1"])
	var required := ZProductCompatibilityManifest.create(1, 3, fingerprint, features)
	var offered := ZProductCompatibilityManifest.create(
		1, 3, fingerprint, PackedStringArray([features[1], features[0]]))
	check(required != null and offered != null, "")
	if required == null or offered == null:
		return
	var raid_id := ZRaidId.from_parts(PackedStringArray(["multiplayer", "phase_c_egress"]))
	var credential := PackedByteArray([2, 7, 1, 8, 2, 8])
	var owner := _remote(raid_id, credential, required, offered,
		&"steam_phase_c_owner", &"profile_phase_c_owner", 31, &"owner_a")
	var observer := _remote(raid_id, credential, required, offered,
		&"steam_phase_c_observer", &"profile_phase_c_observer", 41, &"observer_a")
	check(owner != null and owner.is_usable(), "")
	check(observer != null and observer.is_usable(), "")
	if owner == null or observer == null or not owner.is_usable() or not observer.is_usable():
		return
	var projection := Projection.new()
	var server_scene := load(
		"res://game/multiplayer/compositions/dedicated_server.tscn") as PackedScene
	var owner_scene := load(
		"res://game/multiplayer/compositions/owning_client.tscn") as PackedScene
	var observer_scene := load(
		"res://game/multiplayer/compositions/observer_client.tscn") as PackedScene
	check(server_scene != null and owner_scene != null and observer_scene != null,
		"")
	if server_scene == null or owner_scene == null or observer_scene == null:
		return
	var server := server_scene.instantiate() as ZDedicatedServerComposition
	var owner_client := owner_scene.instantiate() as ZOwningClientComposition
	var observer_client := observer_scene.instantiate() as ZObserverClientComposition
	check(server != null and server.configure(raid_id, 20260919,
		CommandPolicy.new(), projection), "")
	if server == null or not server.has_canonical_authority():
		return
	check(server.admit_remote_session(owner), "")
	check(server.admit_remote_session(observer), "")
	check(owner_client.bind_replication_recipient(owner), "")
	check(observer_client.bind_replication_recipient(observer), "")
	var owner_streams := [
		[&"inventory", &"loadout", {"value": 11}],
		[&"weapon", &"primary", {"value": 21}],
		[&"ability", &"player", {"value": 31}],
		[&"vision", &"world", {"value": 41}],
	]
	for stream in owner_streams:
		projection.seed(owner, stream[0], stream[1], 1, stream[2])
		check(server.grant_replication(owner, stream[0], stream[1]),
			"owner stream grant %s" % stream[0])
		var route := server.replication_snapshot_for_peer(31, stream[0], stream[1])
		check(_route_matches(route, owner, stream[0], stream[1], 1, 1),
			"owner exact route %s" % stream[0])
		check(owner_client.apply_replication_envelope(_envelope(route)),
			"owner applies %s" % stream[0])
		check(int(owner_client.replica_store().state_for(
			stream[0], stream[1]).get("value", 0)) == int(stream[2].value),
			"owner state converges %s" % stream[0])
	check(server.replication_grant_count() == 4, "")
	projection.seed(observer, &"vision", &"world", 1, {"value": 51})
	check(server.grant_replication(observer, &"vision", &"world"),
		"")
	var observer_route := server.replication_snapshot_for_peer(
		41, &"vision", &"world")
	check(_route_matches(observer_route, observer, &"vision", &"world", 1, 1),
		"")
	check(observer_client.apply_replication_envelope(_envelope(observer_route)),
		"")
	check(not owner_client.apply_replication_envelope(_envelope(observer_route))
		and owner_client.replica_store().last_error == &"replica_recipient_mismatch",
		"")
	check(owner.principal_key == &"steam_phase_c_owner",
		"")
	var detached := owner_client.replica_store().state_for(&"inventory", &"loadout")
	detached["value"] = 999
	check(int(owner_client.replica_store().state_for(
		&"inventory", &"loadout").get("value", 0)) == 11,
		"")
	projection.advance(owner, &"inventory", &"loadout", {"value": 12})
	var calls_before := projection.calls
	var route := server.replication_delta_for_peer(31, &"inventory", &"loadout", 0)
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_predecessor_revision_mismatch"
		and projection.calls == calls_before,
		"")
	route = server.replication_delta_for_peer(31, &"inventory", &"loadout", 1)
	check(_route_matches(route, owner, &"inventory", &"loadout", 2, 2),
		"")
	var delta := _envelope(route)
	var malformed := delta.duplicate(true)
	malformed["extra"] = true
	check(not owner_client.apply_replication_envelope(malformed)
		and owner_client.replica_store().last_error == &"replica_envelope_shape_invalid",
		"")
	var tampered := delta.duplicate(true)
	tampered["recipient_peer"] = 41
	check(not owner_client.apply_replication_envelope(tampered)
		and owner_client.replica_store().last_error == &"replica_recipient_mismatch",
		"")
	var gap := delta.duplicate(true)
	gap["sequence"] = 3
	check(not owner_client.apply_replication_envelope(gap)
		and owner_client.replica_store().last_error == &"replica_sequence_gap",
		"")
	var predecessor := delta.duplicate(true)
	predecessor["predecessor_revision"] = 0
	check(not owner_client.apply_replication_envelope(predecessor)
		and owner_client.replica_store().last_error
			== &"replica_predecessor_revision_mismatch",
		"")
	check(owner_client.apply_replication_envelope(delta),
		"")
	check(not owner_client.apply_replication_envelope(delta)
		and owner_client.replica_store().last_error == &"replica_sequence_replayed",
		"")
	projection.seed(owner, &"weapon", &"backup", 1, {"value": 61})
	check(server.grant_replication(owner, &"weapon", &"backup"),
		"")
	projection.mode = &"shape"
	route = server.replication_snapshot_for_peer(31, &"weapon", &"backup")
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_projection_result_invalid",
		"")
	projection.mode = &""
	route = server.replication_snapshot_for_peer(31, &"weapon", &"backup")
	check(bool(route.get("ok", false))
		and int(_envelope(route).get("sequence", 0)) == 1,
		"")
	check(owner_client.apply_replication_envelope(_envelope(route)),
		"")
	projection.seed(owner, &"ability", &"status", 1, {"value": 71})
	check(server.grant_replication(owner, &"ability", &"status"),
		"")
	projection.mode = &"unbounded"
	route = server.replication_snapshot_for_peer(31, &"ability", &"status")
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_projection_payload_unbounded",
		"")
	projection.mode = &""
	route = server.replication_snapshot_for_peer(31, &"ability", &"status")
	check(bool(route.get("ok", false))
		and int(_envelope(route).get("sequence", 0)) == 1,
		"")
	check(server.revoke_replication(owner, &"ability", &"player"),
		"")
	calls_before = projection.calls
	route = server.replication_snapshot_for_peer(31, &"ability", &"player")
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_grant_missing"
		and projection.calls == calls_before,
		"")
	var replacement := _remote(raid_id, credential, required, offered,
		&"steam_phase_c_owner", &"profile_phase_c_owner", 33, &"owner_b")
	check(replacement != null and replacement.is_usable()
		and replacement.authority_epoch > owner.authority_epoch,
		"")
	check(server.admit_remote_session(replacement),
		"")
	calls_before = projection.calls
	route = server.replication_snapshot_for_peer(31, &"inventory", &"loadout")
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_recipient_not_active"
		and projection.calls == calls_before,
		"")
	route = server.replication_snapshot_for_peer(33, &"inventory", &"loadout")
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_grant_missing",
		"")
	projection.seed(replacement, &"inventory", &"loadout", 2, {"value": 13})
	check(server.grant_replication(replacement, &"inventory", &"loadout"),
		"")
	route = server.replication_snapshot_for_peer(33, &"inventory", &"loadout")
	check(_route_matches(route, replacement, &"inventory", &"loadout", 1, 2),
		"")
	var replacement_client := owner_scene.instantiate() as ZOwningClientComposition
	check(replacement_client.bind_replication_recipient(replacement)
		and replacement_client.apply_replication_envelope(_envelope(route)),
		"")
	check(not owner_client.apply_replication_envelope(_envelope(route))
		and owner_client.replica_store().last_error == &"replica_recipient_mismatch",
		"")
	check(server.retire_remote_session(observer), "")
	calls_before = projection.calo
	route = server.replication_snapshot_for_peer(41, &"vision", &"world")
	check(not bool(route.get("ok", false))
		and route.get("reason") == &"replication_recipient_not_active"
		and projection.calls == calls_before,
		"")
	var source_file := FileAccss.open(
		"res://game/multiplayer/grant_scoped_replication_egress.gd", FileAccess.READ)
	var source := source_file.get_as_text() if source_file != null else ""
	check(not source.is_empty(), "")
	check(source.find("func broadcast") == -1 and source.find("rpc(") == -1
		and source.find("MultiplayerPeer") == -1,
		"")
	owner_client.free()
	observer_client.free()
	replacement_client.free()
	server.free()
func _remote(raid_id: ZRaidId, credential: PackedByteArray,
		required: ZProductCompatibilityManifest,
		offered: ZProductCompatibilityManifest, principal: StringName,
		profile: StringName, peer: int, instance: StringName) -> ZSessionAdmission:
	var grant := ZSessionAuthGrant.create(principal, profile, &"player")
	var coordinator := SessionCoordinator.new(AuthenticatedSessionIngress.new(
		Auth.new(credential, grant), required))
	return coordinator.open_remote(
		raid_id, profile, &"player", peer, instance, credential, offered)
func _envelope(route: Dictionary) -> Dictionary:
	return route.get("envelope", {}) as Dictionary
func _route_matches(route: Dictionary, admission: ZSessionAdmission,
		channel: StringName, subject: StringName, sequence: int, revision: int) -> bool:
	if not bool(route.get("ok", false)):
		return false
	var envelope := _envelope(route)
	return int(route.get("transport_peer_id", 0)) == admission.transport_peer_id \
		and int(envelope.get("recipient_peer", 0)) == admission.transport_peer_id \
		and envelope.get("recipient_session") == admission.session_id.canonical_key() \
		and envelope.get("recipient_actor") == admission.actor_id.canonical_key() \
		and int(envelope.get("authority_epoch", 0)) == admission.authority_epoch \
		and envelope.get("compatibility_digest") == admission.compatibility_digest \
		and envelope.get("channel") == String(channel) \
		and envelope.get("subject") == String(subject) \
		and int(envelope.get("sequence", 0)) == sequence \
		and int(envelope.get("revision", -1)) == revision
