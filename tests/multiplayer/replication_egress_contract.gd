extends RefCounted
## Task 10.5/10.6 grant-scoped replication and hidden-identity contract.

class FakeAuthenticator:
	extends ZSessionAuthenticatorPort
	var credential: PackedByteArray
	var grant: ZSessionAuthGrant
	func _init(p_credential: PackedByteArray, p_grant: ZSessionAuthGrant) -> void:
		credential = p_credential.duplicate()
		grant = p_grant
	func authenticate(request: ZSessionRequest) -> ZSessionAuthGrant:
		return grant if request != null and request.credential == credential else null


class FakeVisionSource:
	extends ZAuthorizedVisionProjectionPort
	var authorized: Dictionary = {}
	var projections: Dictionary = {}
	var identities: Dictionary = {}
	var resolve_calls: Array[int] = []

	func is_authorized_recipient(
		recipient_actor_id: ZEntityId,
		_generation: int
	) -> bool:
		return recipient_actor_id != null and authorized.has(
			recipient_actor_id.canonical_key()
		)

	func projection_for(
		recipient_actor_id: ZEntityId,
		_generation: int
	) -> Dictionary:
		if not is_authorized_recipient(recipient_actor_id, _generation):
			return {}
		return (projections.get(
			recipient_actor_id.canonical_key(), {}
		) as Dictionary).duplicate(true)

	func entity_for_visible_native_id(
		_recipient_actor_id: ZEntityId,
		native_target_id: int,
		_generation: int
	) -> ZEntityId:
		resolve_calls.append(native_target_id)
		return ZEntityId.parse(String(identities.get(native_target_id, "")))


var checks: int = 0
var failures: int = 0


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("REPLICATION_EGRESS_CONTRACT: " + message)


func run() -> Dictionary:
	var fingerprint := "a".repeat(64)
	var required := ZProductCompatibilityManifest.create(
		1,
		4,
		fingerprint,
		PackedStringArray(["replication_egress_v1"])
	)
	var offered := ZProductCompatibilityManifest.create(
		1,
		4,
		fingerprint,
		PackedStringArray(["replication_egress_v1"])
	)
	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"multiplayer", "replication_egress_contract",
	]))
	var credential := PackedByteArray([10, 5, 10, 6])
	var coordinator_a := _coordinator(
		credential, required, &"steam_a", &"profile_a")
	var coordinator_b := _coordinator(
		credential, required, &"steam_b", &"profile_b")
	var coordinator_c := _coordinator(
		credential, required, &"steam_c", &"profile_c")
	var admission_a := coordinator_a.open_remote(
		raid_id, &"profile_a", &"player", 31, &"client_a", credential, offered)
	var admission_b := coordinator_b.open_remote(
		raid_id, &"profile_b", &"player", 32, &"client_b", credential, offered)
	var admission_c := coordinator_c.open_remote(
		raid_id, &"profile_c", &"player", 33, &"client_c", credential, offered)
	check(
		admission_a.is_usable() and admission_b.is_usable() and admission_c.is_usable(),
		"three authenticated session fixtures construct"
	)

	var registry := ZProductSessionRegistry.new(raid_id)
	check(
		registry.activate(admission_a)
			and registry.activate(admission_b)
			and registry.activate(admission_c),
		"all three authenticated sessions activate"
	)

	var source := FakeVisionSource.new()
	for admission in [admission_a, admission_b, admission_c]:
		source.authorized[admission.actor_id.canonical_key()] = true
	source.identities[2] = admission_b.actor_id.canonical_key()
	source.identities[3] = admission_c.actor_id.canonical_key()
	source.identities[1] = admission_a.actor_id.canonical_key()
	source.projections[admission_a.actor_id.canonical_key()] = _projection(
		101,
		7,
		20,
		[
			_visible(2, 20, Vector2i(20, 5)),
			_remembered(3, 18, Vector2i(40, 7)),
		]
	)
	source.projections[admission_b.actor_id.canonical_key()] = _projection(
		102,
		4,
		20,
		[
			_visible(1, 20, Vector2i(10, 5)),
			_unknown(3),
		]
	)
	source.projections[admission_c.actor_id.canonical_key()] = _projection(
		103,
		2,
		20,
		[_unknown(1), _unknown(2)]
	)

	var relevance := ZVisionReplicationRelevance.new()
	check(relevance.configure(source, 1), "Vision relevance source configures")
	var egress := ZReplicationEgress.new()
	check(egress.configure(registry, relevance, 9), "replication egress configures")

	var channels := PackedStringArray([
		"inventory", "weapon", "ability", "vision",
	])
	var grant_a := ZReplicationGrant.create(
		admission_a, channels, PackedInt64Array([1001]))
	var grant_b := ZReplicationGrant.create(
		admission_b, channels, PackedInt64Array([2002]))
	var grant_c := ZReplicationGrant.create(
		admission_c, channels, PackedInt64Array([3003]))
	check(
		grant_a != null and grant_b != null and grant_c != null,
		"recipient grants construct from authenticated admissions"
	)
	check(
		egress.install_grant(grant_a)
			and egress.install_grant(grant_b)
			and egress.install_grant(grant_c),
		"exact recipient grants install"
	)
	var inactive_grant := ZReplicationGrant.create(
		coordinator_a.open_remote(
			raid_id,
			&"profile_a",
			&"player",
			40,
			&"not_activated",
			credential,
			offered
		),
		channels,
		PackedInt64Array([1001])
	)
	check(
		inactive_grant != null
			and not egress.install_grant(inactive_grant)
			and egress.last_error == &"replication_grant_session_inactive",
		"an authenticated but inactive session receives no egress grant"
	)

	var vision_a := egress.refresh_vision_for_session(admission_a.session_id, 20)
	check(
		vision_a.get("ok") == true
			and source.resolve_calls == [2]
			and relevance.visible_entity_ids(admission_a.actor_id)
				== PackedStringArray([admission_b.actor_id.canonical_key()]),
		"only a currently visible target identity is resolved for recipient A"
	)
	check(
		not source.resolve_calls.has(3),
		"remembered hidden target identity is never resolved"
	)
	var vision_b := egress.refresh_vision_for_session(admission_b.session_id, 20)
	check(
		vision_b.get("ok") == true
			and relevance.allows(admission_b.actor_id, admission_a.actor_id)
			and not relevance.allows(admission_b.actor_id, admission_c.actor_id),
		"recipient B receives an independent exact Vision scope"
	)
	check(
		egress.refresh_vision_for_session(admission_c.session_id, 20).get("ok") == true
			and relevance.visible_entity_ids(admission_c.actor_id).is_empty(),
		"recipient C has an authorized but empty visibility projection"
	)

	var hidden_key := admission_c.actor_id.canonical_key()
	check(
		ZReplicationRecord.create(
			ZReplicationGrant.CHANNEL_WEAPON,
			"weapon:malicious",
			admission_b.actor_id,
			9,
			ZReplicationRecord.Kind.SNAPSHOT,
			ZReplicationRecord.Scope.VISION,
			1,
			0,
			{"hidden_actor": hidden_key}
		) == null,
		"payload cannot smuggle an undeclared canonical entity identity"
	)

	var inventory_a := _record(
		&"inventory", "inventory:1001", admission_a.actor_id,
		ZReplicationRecord.Scope.OWNER, 1, 0,
		{"items": ["bandage", "magazine"], "weight": 12},
		PackedStringArray())
	var inventory_b := _record(
		&"inventory", "inventory:2002", admission_b.actor_id,
		ZReplicationRecord.Scope.OWNER, 1, 0,
		{"items": ["rifle"], "weight": 18},
		PackedStringArray())
	var weapon_b := _record(
		&"weapon", "weapon:actor_b", admission_b.actor_id,
		ZReplicationRecord.Scope.VISION, 1, 0,
		{"equipped": true, "stance": "ready"},
		PackedStringArray([admission_b.actor_id.canonical_key()]))
	var ability_a := _record(
		&"ability", "ability:actor_a", admission_a.actor_id,
		ZReplicationRecord.Scope.OWNER, 1, 0,
		{"grants": ["sprint", "reload"]}, PackedStringArray())
	var hidden_ability_c := _record(
		&"ability", "ability:actor_c", admission_c.actor_id,
		ZReplicationRecord.Scope.VISION, 1, 0,
		{"active": ["bleeding"]},
		PackedStringArray([admission_c.actor_id.canonical_key()]))
	check(
		inventory_a != null
			and inventory_b != null
			and weapon_b != null
			and ability_a != null
			and hidden_ability_c != null,
		"inventory, weapon, ability source records construct"
	)
	check(
		egress.publish_record(inventory_a)
			and egress.publish_record(inventory_b)
			and egress.publish_record(weapon_b)
			and egress.publish_record(ability_a)
			and egress.publish_record(hidden_ability_c),
		"authoritative records enter bounded stream journals"
	)

	var batch_a := egress.egress_for_session(admission_a.session_id)
	check(
		batch_a.get("ok") == true
			and int(batch_a.get("transport_peer_id", 0)) == 31
			and String(batch_a.get("session_id", ""))
				== admission_a.session_id.canonical_key(),
		"egress names exactly one authenticated recipient"
	)
	check(
		_has_frame(batch_a, &"inventory", "inventory:1001", 1)
			and _has_frame(batch_a, &"ability", "ability:actor_a", 1)
			and _has_frame(batch_a, &"weapon", "weapon:actor_b", 1)
			and _has_channel(batch_a, &"vision"),
		"owner-private and Vision-visible streams reach recipient A"
	)
	check(
		not _has_frame(batch_a, &"inventory", "inventory:2002", 1)
			and not _has_frame(batch_a, &"ability", "ability:actor_c", 1),
		"foreign private and hidden public streams do not reach recipient A"
	)
	check(
		ZCanonicalValue.encode(batch_a).find(hidden_key) == -1,
		"recipient A batch contains no hidden entity identity through any feed"
	)

	var batch_b := egress.egress_for_session(admission_b.session_id)
	check(
		_has_frame(batch_b, &"inventory", "inventory:2002", 1)
			and not _has_frame(batch_b, &"inventory", "inventory:1001", 1)
			and not _has_frame(batch_b, &"ability", "ability:actor_c", 1),
		"recipient B mapping is independent and exact"
	)

	var inventory_a_delta := _record(
		&"inventory", "inventory:1001", admission_a.actor_id,
		ZReplicationRecord.Scope.OWNER, 2, 1,
		{"removed": ["bandage"], "weight": 11}, PackedStringArray(),
		ZReplicationRecord.Kind.DELTA)
	check(
		inventory_a_delta != null and egress.publish_record(inventory_a_delta),
		"contiguous inventory delta publishes"
	)
	var cursor := {inventory_a.stream_key: 1}
	var delta_batch := egress.egress_for_session(admission_a.session_id, cursor)
	check(
		_has_frame(delta_batch, &"inventory", "inventory:1001", 2)
			and not _has_frame(delta_batch, &"inventory", "inventory:1001", 1),
		"recipient cursor receives delta without replaying its snapshot"
	)
	var wrong_base := _record(
		&"inventory", "inventory:1001", admission_a.actor_id,
		ZReplicationRecord.Scope.OWNER, 9, 8,
		{"weight": 99}, PackedStringArray(), ZReplicationRecord.Kind.DELTA)
	check(
		wrong_base != null
			and not egress.publish_record(wrong_base)
			and egress.last_error == &"replication_delta_base_mismatch",
		"delta cannot skip authoritative stream revisions"
	)
	var replacement_snapshot := _record(
		&"inventory", "inventory:1001", admission_a.actor_id,
		ZReplicationRecord.Scope.OWNER, 10, 0,
		{"items": ["magazine"], "weight": 11}, PackedStringArray())
	check(
		replacement_snapshot != null and egress.publish_record(replacement_snapshot),
		"new full snapshot rebases a bounded stream"
	)
	var resync_batch := egress.egress_for_session(
		admission_a.session_id, {inventory_a.stream_key: 2})
	check(
		_has_frame(resync_batch, &"inventory", "inventory:1001", 10)
			and (resync_batch.get("resync_streams", []) as Array).has(
				inventory_a.stream_key
			),
		"cursor behind the retained snapshot is explicitly rebased"
	)

	var replacement_a := coordinator_a.open_remote(
		raid_id, &"profile_a", &"player", 41, &"client_a2", credential, offered)
	check(
		replacement_a.is_usable()
			and registry.activate(replacement_a)
			and not egress.egress_for_session(admission_a.session_id).get("ok", false),
		"session replacement immediately invalidates old egress mapping"
	)
	var replacement_grant := ZReplicationGrant.create(
		replacement_a, channels, PackedInt64Array([1001]))
	check(
		replacement_grant != null
			and egress.install_grant(replacement_grant)
			and egress.egress_for_session(replacement_a.session_id).get("ok") == true,
		"newer authenticated session receives a new exact recipient grant"
	)
	check(
		egress.revoke_session(replacement_a.session_id)
			and not egress.egress_for_session(replacement_a.session_id).get("ok", false),
		"grant revocation tears down recipient egress"
	)

	return {"checks": checks, "failures": failures}


func _coordinator(
	credential: PackedByteArray,
	required: ZProductCompatibilityManifest,
	principal: StringName,
	profile: StringName
) -> SessionCoordinator:
	return SessionCoordinator.new(AuthenticatedSessionIngress.new(
		FakeAuthenticator.new(
			credential,
			ZSessionAuthGrant.create(principal, profile, &"player")
		),
		required
	))


func _record(
	channel: StringName,
	subject: String,
	owner: ZEntityId,
	scope: ZReplicationRecord.Scope,
	revision: int,
	base_revision: int,
	payload: Dictionary,
	references: PackedStringArray,
	kind: ZReplicationRecord.Kind = ZReplicationRecord.Kind.SNAPSHOT
) -> ZReplicationRecord:
	return ZReplicationRecord.create(
		channel,
		subject,
		owner,
		9,
		kind,
		scope,
		revision,
		base_revision,
		payload,
		references
	)


func _projection(
	observer_id: int,
	revision: int,
	completed_tick: int,
	records: Array
) -> Dictionary:
	return {
		"completed_tick": completed_tick,
		"observer_id": observer_id,
		"ok": true,
		"records": records,
		"result_revision": revision,
	}


func _visible(target_id: int, tick: int, position: Vector2i) -> Dictionary:
	return {
		"has_last_known_position": true,
		"last_known_position": position,
		"last_seen_tick": tick,
		"state": ZVisionReplicationRelevance.VISIBLE,
		"target_id": target_id,
		"target_revision": 1,
	}


func _remembered(target_id: int, tick: int, position: Vector2i) -> Dictionary:
	return {
		"has_last_known_position": true,
		"last_known_position": position,
		"last_seen_tick": tick,
		"state": ZVisionReplicationRelevance.REMEMBERED,
		"target_id": target_id,
		"target_revision": 1,
	}


func _unknown(target_id: int) -> Dictionary:
	return {
		"has_last_known_position": false,
		"last_known_position": Vector2i.ZERO,
		"last_seen_tick": 0,
		"state": ZVisionReplicationRelevance.UNKNOWN,
		"target_id": target_id,
		"target_revision": 0,
	}


func _has_channel(batch: Dictionary, channel: StringName) -> bool:
	for raw_frame in batch.get("frames", []) as Array:
		var frame := raw_frame as Dictionary
		if StringName(frame.get("channel", "")) == channel:
			return true
	return false


func _has_frame(
	batch: Dictionary,
	channel: StringName,
	subject: String,
	revision: int
) -> bool:
	for raw_frame in batch.get("frames", []) as Array:
		var frame := raw_frame as Dictionary
		if (
			StringName(frame.get("channel", "")) == channel
			and String(frame.get("subject_id", "")) == subject
			and int(frame.get("revision", 0)) == revision
		):
			return true
	return false
