extends SceneTree
## Task 4.12 contract: opaque persistence bytes round-trip canonically, hostile
## records fail before live mutation, and same-id replacement retires every
## stale presentation/intent generation before the restored runtime is used.

const Boundary = preload("res://game/inventory/inventory_persistence_boundary.gd")
const Bridge = preload("res://game/inventory/presentation/inventory_projection_bridge.gd")
const Controller = preload("res://game/inventory/presentation/inventory_presentation_controller.gd")
const Adapter = preload("res://game/inventory/inventory_intent_adapter.gd")
const ReloadAdapter = preload("res://game/inventory/equipment/inventory_weapon_adapter.gd")

const MAX_TRANSFER_DISTANCE_RAW: int = 2_000_000


class PersistenceIdentityPort extends ZInventoryIdentityPort:
	var session_key: String = ""
	var actor_key: String = ""
	var epoch: int = 0
	var generation: int = 0
	var native_actor: int = 0
	var owned_inventory_id: int = 0

	func native_actor_id(
		p_session: ZSessionId,
		p_actor: ZEntityId,
		p_epoch: int,
		p_generation: int
	) -> int:
		if p_session == null or p_actor == null:
			return 0
		return native_actor if p_session.canonical_key() == session_key \
			and p_actor.canonical_key() == actor_key \
			and p_epoch == epoch and p_generation == generation else 0

	func actor_owns_inventory(
		p_session: ZSessionId,
		p_actor: ZEntityId,
		inventory_id: int,
		p_epoch: int,
		p_generation: int
	) -> bool:
		return inventory_id == owned_inventory_id \
			and native_actor_id(p_session, p_actor, p_epoch, p_generation) \
				== native_actor


class PersistenceWorldPort extends ZInventoryWorldPolicyPort:
	var actor_key: String = ""
	var generation: int = 0
	var world_ids: Dictionary = {}
	var after_first_allow: Callable
	var after_allow_fired: bool = false

	func is_world_inventory(
		actor: ZEntityId,
		inventory_id: int,
		p_generation: int
	) -> bool:
		return _matches(actor, p_generation) and bool(world_ids.get(inventory_id, false))

	func authoritative_distance_raw(
		actor: ZEntityId,
		inventory_id: int,
		p_generation: int
	) -> int:
		return 1_000_000 if is_world_inventory(actor, inventory_id, p_generation) else -1

	func is_currently_visible(
		actor: ZEntityId,
		inventory_id: int,
		p_generation: int
	) -> bool:
		return is_world_inventory(actor, inventory_id, p_generation)

	func access_state(
		actor: ZEntityId,
		inventory_id: int,
		p_generation: int
	) -> StringName:
		return ACCESS_OPEN if is_world_inventory(actor, inventory_id, p_generation) \
			else ACCESS_UNAVAILABLE

	func allows_transfer(
		actor: ZEntityId,
		source_inventory_id: int,
		destination_inventory_id: int,
		item_id: int,
		p_generation: int
	) -> bool:
		var allowed := is_world_inventory(actor, source_inventory_id, p_generation) \
			and destination_inventory_id > 0 and item_id > 0
		if allowed and not after_allow_fired and after_first_allow.is_valid():
			after_allow_fired = true
			after_first_allow.call()
		return allowed

	func arm_after_first_allow(callback: Callable) -> void:
		after_first_allow = callback
		after_allow_fired = false

	func _matches(actor: ZEntityId, p_generation: int) -> bool:
		return actor != null and actor.canonical_key() == actor_key \
			and p_generation == generation


class BoundReloadPort extends WeaponReloadParticipantPort:
	var ready: bool = true

	func commit_capability() -> CommitCapability:
		return CommitCapability.FACADE_SINGLE_WRITER

	func is_ready() -> bool:
		return ready

	func identity_token() -> String:
		return "persistence-replacement-reload-port-v1"

	func clear() -> void:
		ready = false


var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_PERSISTENCE_REPLACEMENT_CONTRACT: " + message)


func run() -> void:
	var owner := RaidInventoryOwner.new()
	owner.name = "PersistenceOwner"
	root.add_child(owner)
	check(owner.configure(), "canonical inventory owner configures")
	check(owner.materialize_loot_fixture(), "canonical loot fixture materializes")
	var owner_generation := owner.generation()
	var boundary := Boundary.new()
	check(boundary.bind_owner(owner, owner_generation),
		"persistence boundary binds one exact owner generation")

	var targets: Array[Dictionary] = [
		{"scope": Boundary.SCOPE_PROFILE, "inventory_id": owner.profile_inventory_id},
		{"scope": Boundary.SCOPE_RAID, "inventory_id": owner.raid_player_inventory_id},
		{"scope": Boundary.SCOPE_RAID, "inventory_id": owner.world_crate_inventory_id},
		{"scope": Boundary.SCOPE_RAID, "inventory_id": owner.corpse_inventory_id},
	]
	var envelopes: Dictionary = {}
	for target in targets:
		var scope := StringName(target["scope"])
		var inventory_id := int(target["inventory_id"])
		var authority := owner.profile_authority() \
			if scope == Boundary.SCOPE_PROFILE else owner.raid_authority()
		var live_snapshot := authority.snapshot(inventory_id)
		var envelope := boundary.capture_record(scope, inventory_id, owner_generation)
		var preflight := boundary.preflight_bytes(
			envelope.get("record_bytes", PackedByteArray()) as PackedByteArray,
			scope,
			inventory_id,
			owner_generation)
		check(not envelope.is_empty() and bool(preflight.get("ok", false)),
			"%s/%d record survives disposable-authority preflight" % [scope, inventory_id])
		check((preflight.get("canonical_bytes", PackedByteArray()) as PackedByteArray) \
				== live_snapshot.canonical_bytes() \
			and int(preflight.get("canonical_hash", 0)) == live_snapshot.hash(),
			"%s/%d preflight restores exact canonical bytes and native hash" \
				% [scope, inventory_id])
		check((preflight.get("record_bytes", PackedByteArray()) as PackedByteArray) \
				== (envelope.get("record_bytes", PackedByteArray()) as PackedByteArray),
			"%s/%d persistence record remakes byte-identically" % [scope, inventory_id])
		envelopes["%s:%d" % [scope, inventory_id]] = envelope

	var crate_key := "%s:%d" % [Boundary.SCOPE_RAID, owner.world_crate_inventory_id]
	var crate_envelope := envelopes[crate_key] as Dictionary
	var crate_before_hostile := owner.raid_authority().snapshot(
		owner.world_crate_inventory_id).canonical_bytes()
	var crate_digest_before_hostile := _sha256_bytes(crate_before_hostile)

	var duplicate_result := boundary.replace_live(
		crate_envelope, owner_generation, crate_digest_before_hostile)
	check(bool(duplicate_result.get("ok", false)) \
		and bool(duplicate_result.get("duplicate", false)) \
		and not bool(duplicate_result.get("replaced", true)) \
		and boundary.is_bound(),
		"byte-identical duplicate restore is an idempotent no-op generation")

	var empty_preflight := boundary.preflight_bytes(
		PackedByteArray(), Boundary.SCOPE_RAID,
		owner.world_crate_inventory_id, owner_generation)
	check(not bool(empty_preflight.get("ok", true)) \
		and empty_preflight.get("reason", &"") == &"persistence_record_size_invalid",
		"empty persistence input fails the product size gate")
	var malformed_preflight := _without_expected_native_error(func() -> Dictionary:
		return boundary.preflight_bytes(
			PackedByteArray([0x7f, 0x00, 0xff]), Boundary.SCOPE_RAID,
			owner.world_crate_inventory_id, owner_generation))
	check(not bool(malformed_preflight.get("ok", true)),
		"malformed persistence input fails disposable decoding")
	var full_record := crate_envelope["record_bytes"] as PackedByteArray
	var truncated_record := full_record.slice(0, full_record.size() - 1)
	var truncated_preflight := _without_expected_native_error(func() -> Dictionary:
		return boundary.preflight_bytes(
			truncated_record, Boundary.SCOPE_RAID,
			owner.world_crate_inventory_id, owner_generation))
	check(not bool(truncated_preflight.get("ok", true)),
		"truncated persistence input fails disposable decoding")
	var wrong_schema_record := full_record.duplicate()
	wrong_schema_record[0] = 2
	wrong_schema_record[1] = 0
	var wrong_schema := _without_expected_native_error(func() -> Dictionary:
		return boundary.preflight_bytes(
			wrong_schema_record, Boundary.SCOPE_RAID,
			owner.world_crate_inventory_id, owner_generation))
	check(not bool(wrong_schema.get("ok", true)) \
		and int((wrong_schema.get("native_status", {}) as Dictionary).get("code", -1)) \
			== InventoryCatalog.STATUS_SCHEMA_MISMATCH,
		"unsupported record schema fails with native schema-mismatch status")
	var wrong_scope := boundary.preflight_bytes(
		(envelopes["%s:%d" % [Boundary.SCOPE_PROFILE, owner.profile_inventory_id]] \
			as Dictionary)["record_bytes"] as PackedByteArray,
		Boundary.SCOPE_RAID,
		owner.raid_player_inventory_id,
		owner_generation)
	check(not bool(wrong_scope.get("ok", true)) \
		and wrong_scope.get("reason", &"") == &"persistence_identity_mismatch",
		"colliding numeric id cannot cross profile/raid scope")

	var digest_tamper := crate_envelope.duplicate(true)
	var tampered_bytes := digest_tamper["record_bytes"] as PackedByteArray
	tampered_bytes[tampered_bytes.size() - 1] ^= 0x01
	digest_tamper["record_bytes"] = tampered_bytes
	var digest_tamper_result := boundary.replace_live(
		digest_tamper, owner_generation, crate_digest_before_hostile)
	check(not bool(digest_tamper_result.get("ok", true)) \
		and digest_tamper_result.get("reason", &"") \
			== &"persistence_record_digest_mismatch",
		"record-byte tampering fails the envelope digest gate")
	var schema_tamper := crate_envelope.duplicate(true)
	schema_tamper["schema"] = "zerkov.inventory.persistence-envelope.v999"
	var schema_tamper_result := boundary.replace_live(
		schema_tamper, owner_generation, crate_digest_before_hostile)
	check(not bool(schema_tamper_result.get("ok", true)) \
		and schema_tamper_result.get("reason", &"") \
			== &"persistence_envelope_schema_mismatch",
		"wrong product envelope schema fails closed")
	var extra_key := crate_envelope.duplicate(true)
	extra_key["unexpected"] = true
	check(not bool(boundary.replace_live(
		extra_key, owner_generation, crate_digest_before_hostile).get("ok", true)),
		"envelope with an unknown field fails its exact schema")

	var forged_source_generation := crate_envelope.duplicate(true)
	forged_source_generation["source_owner_generation"] = owner_generation + 999
	forged_source_generation["envelope_sha256"] = _envelope_digest(
		forged_source_generation)
	var untrusted_generation_result := boundary.replace_live(
		forged_source_generation,
		int(forged_source_generation["source_owner_generation"]),
		crate_digest_before_hostile)
	check(not bool(untrusted_generation_result.get("ok", true)) \
		and untrusted_generation_result.get("reason", &"") == &"stale_owner_generation",
		"persisted source generation cannot authorize the current owner")
	check(owner.raid_authority().snapshot(owner.world_crate_inventory_id) \
		.canonical_bytes() == crate_before_hostile,
		"all malformed/schema/digest/generation failures leave live bytes exact")

	var wrong_catalog := _build_wrong_catalog()
	check(wrong_catalog != null \
		and wrong_catalog.manifest_fingerprint() != owner.catalog().manifest_fingerprint(),
		"wrong-catalog fixture has a distinct sealed manifest")
	var wrong_owner := RaidInventoryOwner.new()
	wrong_owner.name = "WrongCatalogPersistenceOwner"
	root.add_child(wrong_owner)
	check(wrong_owner.configure(wrong_catalog), "wrong-catalog owner configures")
	var wrong_boundary := Boundary.new()
	check(wrong_boundary.bind_owner(wrong_owner, wrong_owner.generation()),
		"wrong-catalog source boundary binds")
	var wrong_envelope := wrong_boundary.capture_record(
		Boundary.SCOPE_RAID, wrong_owner.raid_player_inventory_id,
		wrong_owner.generation())
	var wrong_catalog_result := _without_expected_native_error(func() -> Dictionary:
		return boundary.preflight_bytes(
			wrong_envelope.get("record_bytes", PackedByteArray()) as PackedByteArray,
			Boundary.SCOPE_RAID, owner.raid_player_inventory_id, owner_generation))
	check(not bool(wrong_catalog_result.get("ok", true)) \
		and int((wrong_catalog_result.get("native_status", {}) as Dictionary) \
			.get("code", -1)) == InventoryCatalog.STATUS_MANIFEST_MISMATCH,
		"wrong sealed catalog fails with native manifest-mismatch status")
	check(wrong_owner.teardown(wrong_owner.generation()),
		"wrong-catalog owner tears down")
	wrong_owner.queue_free()

	var admission := _make_admission()
	var identity := PersistenceIdentityPort.new()
	identity.session_key = admission.session_id.canonical_key()
	identity.actor_key = admission.actor_id.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned_inventory_id = owner.raid_player_inventory_id
	var world := PersistenceWorldPort.new()
	world.actor_key = admission.actor_id.canonical_key()
	world.generation = admission.generation
	world.world_ids[owner.world_crate_inventory_id] = true
	world.world_ids[owner.corpse_inventory_id] = true
	var adapter := Adapter.new()
	check(adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW),
		"intent adapter binds before live replacement")
	var bridge := Bridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"projection bridge binds before live replacement")
	var controller := Controller.new()
	check(controller.bind(owner, bridge, adapter, admission),
		"presentation controller binds before live replacement")
	var reload_port := BoundReloadPort.new()
	var reload_adapter := ReloadAdapter.new()
	reload_adapter.name = "PersistenceReplacementReloadAdapter"
	root.add_child(reload_adapter)
	check(reload_adapter.bind_owner(
		owner, admission, reload_port, owner_generation),
		"reload adapter binds the exact player-inventory generation")
	var reload_invalidations: Array[StringName] = []
	reload_adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		reload_invalidations.append(reason))
	var controller_invalidations: Array[StringName] = []
	controller.binding_invalidated.connect(func(reason: StringName) -> void:
		controller_invalidations.append(reason))
	var adapter_invalidations: Array[StringName] = []
	adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		adapter_invalidations.append(reason))

	var crate_items := controller.items_for(&"crate")
	var transferred_item := crate_items[0] as Dictionary
	var accepted := controller.submit_quick(&"crate", transferred_item)
	check(bool(accepted.get("accepted", false)) and adapter.tracked_request_count() == 1,
		"pre-replacement adapter owns one completed request receipt")
	var retired_request := ZRequestId.parse(String(accepted.get("request_id", "")))
	check(retired_request != null \
		and not adapter.receipt_for_request(retired_request).is_empty(),
		"completed request is replayable before generation replacement")
	var retired_transaction_callback := _transaction_callback_for_scope(
		bridge, Bridge.SCOPE_RAID)
	check(retired_transaction_callback.is_valid(),
		"test captures the exact pre-replacement transaction callback generation")
	var old_model := bridge.presentation_model(Bridge.SCOPE_RAID)
	var old_scope_generation := bridge.scope_generation(Bridge.SCOPE_RAID)
	var remaining_items := controller.items_for(&"crate")
	var remaining_item := remaining_items[0] as Dictionary
	var pending_id := bridge.begin_pending_intent(
		Bridge.SCOPE_RAID,
		&"move",
		{"inventory_id": owner.world_crate_inventory_id,
			"items": [int(remaining_item["item_id"])]},
		owner_generation,
		old_scope_generation)
	check(pending_id > 0 and not old_model.get_pending(pending_id).is_empty(),
		"old presentation generation contains a pending intent")
	var current_crate_bytes := owner.raid_authority().snapshot(
		owner.world_crate_inventory_id).canonical_bytes()
	var current_crate_digest := _sha256_bytes(current_crate_bytes)
	check(current_crate_bytes != crate_before_hostile,
		"replacement candidate differs from current live state")
	var stale_digest_replacement := boundary.replace_live(
		crate_envelope, owner_generation, crate_digest_before_hostile)
	check(not bool(stale_digest_replacement.get("ok", true)) \
		and stale_digest_replacement.get("reason", &"") == &"stale_live_digest" \
		and owner.raid_authority().snapshot(owner.world_crate_inventory_id) \
			.canonical_bytes() == current_crate_bytes \
		and adapter.is_bound() and controller.is_bound() \
		and not old_model.get_pending(pending_id).is_empty(),
		"stale compare-and-swap digest fails without retiring live bindings or pending state")
	var replacement := boundary.replace_live(
		crate_envelope, owner_generation, current_crate_digest)
	check(bool(replacement.get("ok", false)) \
		and bool(replacement.get("replaced", false)) \
		and not bool(replacement.get("duplicate", true)),
		"validated same-id live replacement commits exactly once")
	check(owner.raid_authority().snapshot(owner.world_crate_inventory_id) \
		.canonical_bytes() == crate_before_hostile \
		and String(replacement.get("restored_canonical_sha256", "")) \
			== String(crate_envelope["canonical_sha256"]),
		"live authority restores the captured canonical bytes and SHA-256 exactly")
	check(not boundary.is_bound() and boundary.last_error \
		== &"persistence_replacement_committed",
		"persistence boundary retires its own pre-replacement generation")
	check(not adapter.is_bound() and adapter.tracked_request_count() == 0 \
		and adapter.tracked_command_count() == 0 \
		and adapter.receipt_for_request(retired_request).is_empty(),
		"intent adapter clears stale request and native-command replay ledgers")
	check(adapter_invalidations == [&"inventory_generation_changing"],
		"intent adapter publishes one synchronous generation invalidation")
	check(not controller.is_bound() \
		and controller_invalidations == [&"inventory_generation_changing"],
		"controller drops its stale adapter/model binding synchronously")
	check(old_model.is_resynchronizing() and old_model.get_pending(pending_id).is_empty(),
		"old presentation model cancels pending state before replacement visibility")
	check(bridge.scope_generation(Bridge.SCOPE_RAID) > old_scope_generation \
		and bridge.scope_status(Bridge.SCOPE_RAID) \
			== Bridge.ProjectionStatus.RESYNCHRONIZING,
		"bridge advances generation and withholds the replacement until resync")
	check(reload_adapter.is_bound(),
		"crate-only replacement preserves the unrelated player reload binding")
	var restored_bytes_before_late := owner.raid_authority().snapshot(
		owner.world_crate_inventory_id).canonical_bytes()
	var stale_controller_result := controller.submit_quick(&"crate", transferred_item)
	check(not bool(stale_controller_result.get("accepted", true)) \
		and owner.raid_authority().snapshot(owner.world_crate_inventory_id) \
			.canonical_bytes() == restored_bytes_before_late,
		"stale controller gesture cannot mutate the restored authority")
	var stale_adapter_result := adapter.submit_intent(_minimal_late_intent(admission))
	check(not bool(stale_adapter_result.get("accepted", true)) \
		and stale_adapter_result.get("reason", &"") == &"stale_generation",
		"stale adapter rejects a late request without replaying old success")
	var replacement_transaction_callback := _transaction_callback_for_scope(
		bridge, Bridge.SCOPE_RAID)
	check(replacement_transaction_callback.is_valid() \
		and _callback_scope_generation(replacement_transaction_callback) \
			== bridge.scope_generation(Bridge.SCOPE_RAID) \
		and _callback_scope_generation(retired_transaction_callback) \
			== old_scope_generation,
		"replacement installs a transaction callback bound to the new generation")
	# The native signal has no generation token. Invoke the exact disconnected
	# callback retained by the old binding to exercise its bound generation
	# guard without misrepresenting a current signal emission as an old one.
	retired_transaction_callback.call(accepted.duplicate(true))
	await process_frame
	check(owner.raid_authority().snapshot(owner.world_crate_inventory_id) \
		.canonical_bytes() == restored_bytes_before_late,
		"late old-generation transaction callback cannot mutate canonical state")
	check(bridge.scope_status(Bridge.SCOPE_RAID) == Bridge.ProjectionStatus.READY \
		and bridge.confirmed_snapshot(Bridge.SCOPE_RAID,
			owner.world_crate_inventory_id).canonical_bytes() \
			== restored_bytes_before_late,
		"deferred bridge resync converges only to exact restored bytes")
	var reused_command_id := int(accepted.get("command_id", 0))
	var revision_before_reuse := owner.raid_authority().inventory_revision(
		owner.world_crate_inventory_id)
	var reused_result: Dictionary = owner.raid_authority().remove_item(
		owner.world_crate_inventory_id,
		int(transferred_item.get("item_id", 0)),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		reused_command_id)
	var revision_after_reuse := owner.raid_authority().inventory_revision(
		owner.world_crate_inventory_id)
	check(reused_command_id > 0 \
		and bool(reused_result.get("accepted", false)) \
		and not bool(reused_result.get("replayed", true)) \
		and revision_after_reuse == revision_before_reuse + 1 \
		and revision_after_reuse == 5,
		"restored native journal accepts the same command id in the new generation")
	check(bridge.scope_status(Bridge.SCOPE_RAID) == Bridge.ProjectionStatus.READY \
		and bridge.confirmed_revision(
			Bridge.SCOPE_RAID, owner.world_crate_inventory_id) == revision_after_reuse \
		and bridge.confirmed_snapshot(
			Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes() \
			== owner.raid_authority().snapshot(
				owner.world_crate_inventory_id).canonical_bytes(),
		"new-generation callback processes the reused id and keeps projection truthful")
	check(bridge.begin_pending_intent(
		Bridge.SCOPE_RAID, &"move",
		{"inventory_id": owner.world_crate_inventory_id, "items": []},
		owner_generation, old_scope_generation) == 0,
		"retired presentation generation cannot publish new pending state")

	var player_key := "%s:%d" % [
		Boundary.SCOPE_RAID, owner.raid_player_inventory_id]
	var player_envelope := envelopes[player_key] as Dictionary
	var player_before_restore := owner.raid_authority().snapshot(
		owner.raid_player_inventory_id).canonical_bytes()
	var player_restore_boundary := Boundary.new()
	check(player_restore_boundary.bind_owner(owner, owner_generation),
		"fresh persistence boundary binds after the crate generation edge")
	var player_replacement := player_restore_boundary.replace_live(
		player_envelope,
		owner_generation,
		_sha256_bytes(player_before_restore))
	check(bool(player_replacement.get("ok", false)) \
		and bool(player_replacement.get("replaced", false)),
		"player persistence replacement commits")
	# The record and canonical encodings are deliberately different envelopes;
	# verify the restored canonical value against a disposable decode instead.
	var player_verify_boundary := Boundary.new()
	check(player_verify_boundary.bind_owner(owner, owner_generation),
		"verification boundary binds after player replacement")
	var player_preflight := player_verify_boundary.preflight_bytes(
		player_envelope["record_bytes"] as PackedByteArray,
		Boundary.SCOPE_RAID,
		owner.raid_player_inventory_id,
		owner_generation)
	check(bool(player_preflight.get("ok", false)) \
		and owner.raid_authority().snapshot(owner.raid_player_inventory_id) \
			.canonical_bytes() \
			== (player_preflight["canonical_bytes"] as PackedByteArray),
		"player replacement restores exact preflight canonical bytes")
	check(reload_adapter.lifecycle == ReloadAdapter.Lifecycle.INVALIDATED \
		and reload_invalidations == [&"authority_invalidation"] \
		and reload_adapter.pending_reloads().is_empty(),
		"player generation replacement synchronously invalidates reload coordination")
	check(player_verify_boundary.release_binding(),
		"post-replacement verification boundary releases")

	var replacement_owner := RaidInventoryOwner.new()
	replacement_owner.name = "ReplacementPersistenceOwner"
	root.add_child(replacement_owner)
	check(replacement_owner.configure(), "replacement owner configures")
	var first_owner_model := bridge.presentation_model(Bridge.SCOPE_RAID)
	check(bridge.bind_owner(replacement_owner, replacement_owner.generation()),
		"bridge explicitly replaces its live owner binding")
	check(first_owner_model.is_disconnected() \
		and bridge.authority_for_scope(Bridge.SCOPE_RAID) \
			== replacement_owner.raid_authority(),
		"same numeric ids cannot retain presentation state across owner instances")
	var retired_boundary_result := boundary.capture_record(
		Boundary.SCOPE_RAID, replacement_owner.raid_player_inventory_id,
		replacement_owner.generation())
	check(not bool(retired_boundary_result.get("ok", false)) \
		and boundary.last_error == &"persistence_boundary_not_bound",
		"retired persistence boundary cannot follow a replacement owner")

	check(owner.teardown(owner_generation), "original owner tears down")
	check(replacement_owner.teardown(replacement_owner.generation()),
		"replacement owner tears down")
	bridge.queue_free()
	reload_adapter.queue_free()
	owner.queue_free()
	replacement_owner.queue_free()
	await process_frame
	await process_frame
	await _test_reentrant_generation_replacement()
	await _test_shared_allocator_floor_replacement_and_retry()
	print("INVENTORY_PERSISTENCE_REPLACEMENT_RESULT checks=", checks,
		" failures=", failures,
		" exact_round_trips=", targets.size())
	quit(0 if failures == 0 else 1)


func _make_admission() -> ZSessionAdmission:
	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"inventory", "persistence", "raid"]))
	var request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray([
			"inventory", "persistence", "admission"])),
		raid_id,
		&"inventory_persistence_profile",
		&"player",
		81)
	return ZSessionAdmission.accept_local(
		request,
		ZSessionId.from_parts(PackedStringArray([
			"inventory", "persistence", "session"])),
		ZEntityId.from_parts(PackedStringArray([
			"inventory", "persistence", "actor"])))


func _test_reentrant_generation_replacement() -> void:
	var owner := RaidInventoryOwner.new()
	owner.name = "ReentrantPersistenceOwner"
	root.add_child(owner)
	check(owner.configure() and owner.materialize_loot_fixture(),
		"reentrant replacement owner and loot configure")
	var admission := _make_admission()
	var identity := PersistenceIdentityPort.new()
	identity.session_key = admission.session_id.canonical_key()
	identity.actor_key = admission.actor_id.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned_inventory_id = owner.raid_player_inventory_id
	var world := PersistenceWorldPort.new()
	world.actor_key = admission.actor_id.canonical_key()
	world.generation = admission.generation
	world.world_ids[owner.world_crate_inventory_id] = true
	var adapter := Adapter.new()
	check(adapter.configure(
		owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW),
		"reentrant replacement intent adapter configures")
	var authority := owner.raid_authority()
	var crate_id := owner.world_crate_inventory_id
	var player_id := owner.raid_player_inventory_id
	var crate_snapshot := authority.snapshot(crate_id)
	var player_before := authority.snapshot(player_id).canonical_bytes()
	var crate_before := crate_snapshot.canonical_bytes()
	var record := authority.make_persistence_record(crate_id)
	var replacement_results: Array[Dictionary] = []
	world.arm_after_first_allow(func() -> void:
		replacement_results.append(authority.apply_persistence_record(record, true)))
	var item_id := int((crate_snapshot.get_items()[0] as Dictionary)["id"])
	var result := adapter.submit_intent(_quick_transfer_intent(
		admission,
		"reentrant_generation_replacement",
		crate_id,
		player_id,
		item_id,
		crate_snapshot.get_revision(),
		authority.inventory_revision(player_id),
		9_100))
	check(replacement_results.size() == 1 \
		and bool(replacement_results[0].get("ok", false)),
		"policy callback establishes the same-id replacement generation")
	check(not bool(result.get("accepted", true)) \
		and result.get("reason", &"") == &"stale_generation",
		"submission interrupted by replacement unwinds without native transfer")
	check(not adapter.is_bound() and adapter.tracked_request_count() == 0 \
		and adapter.tracked_command_count() == 0,
		"deferred invalidation clears receipts created while the submission unwinds")
	check(authority.snapshot(crate_id).canonical_bytes() == crate_before \
		and authority.snapshot(player_id).canonical_bytes() == player_before,
		"reentrant replacement path leaves both canonical inventories byte exact")
	check(owner.teardown(owner.generation()),
		"reentrant replacement owner tears down")
	owner.queue_free()
	await process_frame


func _test_shared_allocator_floor_replacement_and_retry() -> void:
	var owner := RaidInventoryOwner.new()
	owner.name = "AllocatorFloorPersistenceOwner"
	root.add_child(owner)
	check(owner.configure() and owner.materialize_loot_fixture(),
		"allocator-floor owner and loot configure")
	var owner_generation := owner.generation()
	var authority := owner.raid_authority()
	var crate_id := owner.world_crate_inventory_id
	var captured_snapshot := authority.snapshot(crate_id)
	var boundary := Boundary.new()
	check(boundary.bind_owner(owner, owner_generation),
		"allocator-floor persistence boundary binds")
	var envelope := boundary.capture_record(
		Boundary.SCOPE_RAID, crate_id, owner_generation)
	check(not envelope.is_empty(),
		"allocator-floor fixture captures the pre-allocation crate record")

	var admission := _make_admission()
	var identity := PersistenceIdentityPort.new()
	identity.session_key = admission.session_id.canonical_key()
	identity.actor_key = admission.actor_id.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned_inventory_id = owner.raid_player_inventory_id
	var world := PersistenceWorldPort.new()
	world.actor_key = admission.actor_id.canonical_key()
	world.generation = admission.generation
	world.world_ids[crate_id] = true
	world.world_ids[owner.corpse_inventory_id] = true
	var adapter := Adapter.new()
	check(adapter.configure(
		owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW),
		"allocator-floor intent adapter binds before replacement")
	var bridge := Bridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"allocator-floor projection bridge binds before replacement")
	var controller := Controller.new()
	check(controller.bind(owner, bridge, adapter, admission),
		"allocator-floor presentation controller binds before replacement")
	var adapter_invalidations: Array[StringName] = []
	adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		adapter_invalidations.append(reason))
	var controller_invalidations: Array[StringName] = []
	controller.binding_invalidated.connect(func(reason: StringName) -> void:
		controller_invalidations.append(reason))

	var inserted: Dictionary = authority.insert_item(
		crate_id,
		String(ZerkovInventoryCatalog.ITEM_BOLTS),
		1,
		{"kind": "spatial", "container": owner.world_crate_container_id(),
			"x": 7, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		9_801)
	var live_after_insert := authority.snapshot(crate_id)
	check(bool(inserted.get("accepted", false)) \
		and live_after_insert.canonical_bytes() != captured_snapshot.canonical_bytes(),
		"post-capture insertion advances shared allocators and visible crate state")
	var preflight := boundary.preflight_bytes(
		envelope.get("record_bytes", PackedByteArray()) as PackedByteArray,
		Boundary.SCOPE_RAID,
		crate_id,
		owner_generation)
	var expected_bytes := preflight.get(
		"expected_live_canonical_bytes", PackedByteArray()) as PackedByteArray
	check(bool(preflight.get("ok", false)) \
		and bool(preflight.get("allocator_floor_adjusted", false)) \
		and not expected_bytes.is_empty() \
		and expected_bytes != (preflight.get(
			"canonical_bytes", PackedByteArray()) as PackedByteArray),
		"preflight predicts live shared-allocator convergence without weakening the saved digest")

	var replacement := boundary.replace_live(
		envelope,
		owner_generation,
		_sha256_bytes(live_after_insert.canonical_bytes()))
	var restored_snapshot := authority.snapshot(crate_id)
	check(bool(replacement.get("ok", false)) \
		and bool(replacement.get("replaced", false)) \
		and bool(replacement.get("verified", false)) \
		and bool(replacement.get("allocator_floor_adjusted", false)),
		"allocator-drift replacement returns one truthful verified success receipt")
	check(restored_snapshot.canonical_bytes() == expected_bytes \
		and String(replacement.get("restored_canonical_sha256", "")) \
			== _sha256_bytes(expected_bytes) \
		and String(replacement.get("persisted_canonical_sha256", "")) \
			== String(envelope.get("canonical_sha256", "")),
		"live replacement restores the exact convergence-aware canonical bytes and both digests")
	check(_snapshots_visible_equal(restored_snapshot, captured_snapshot),
		"allocator convergence changes no restored items, containers, references, or revision")
	check(adapter_invalidations == [&"inventory_generation_changing"] \
		and controller_invalidations == [&"inventory_generation_changing"] \
		and not adapter.is_bound() and not controller.is_bound(),
		"committed allocator-drift replacement invalidates stale adapters exactly once")
	await process_frame

	var retry_adapter := Adapter.new()
	check(retry_adapter.configure(
		owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW),
		"retry intent adapter binds to the restored generation")
	var retry_controller := Controller.new()
	check(retry_controller.bind(owner, bridge, retry_adapter, admission),
		"retry presentation controller binds to the restored generation")
	var retry_invalidations: Array[StringName] = []
	retry_adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		retry_invalidations.append(reason))
	retry_controller.binding_invalidated.connect(func(reason: StringName) -> void:
		retry_invalidations.append(reason))
	var retry_boundary := Boundary.new()
	check(retry_boundary.bind_owner(owner, owner_generation),
		"retry persistence boundary binds to the restored generation")
	var before_retry := authority.snapshot(crate_id).canonical_bytes()
	var retry := retry_boundary.replace_live(
		envelope, owner_generation, _sha256_bytes(before_retry))
	check(bool(retry.get("ok", false)) \
		and bool(retry.get("duplicate", false)) \
		and not bool(retry.get("replaced", true)) \
		and bool(retry.get("verified", false)) \
		and authority.snapshot(crate_id).canonical_bytes() == before_retry,
		"retry recognizes the convergence-aware canonical state as an exact no-op")
	check(retry_boundary.is_bound() and retry_adapter.is_bound() \
		and retry_controller.is_bound() and retry_invalidations.is_empty(),
		"duplicate retry preserves current adapter and controller bindings")
	check(retry_boundary.release_binding(),
		"allocator-floor retry boundary releases")
	retry_controller.unbind()
	check(retry_adapter.release_binding(),
		"allocator-floor retry adapter releases")
	check(owner.teardown(owner_generation),
		"allocator-floor owner tears down")
	bridge.queue_free()
	owner.queue_free()
	await process_frame


func _snapshots_visible_equal(
	left: InventorySnapshotResource,
	right: InventorySnapshotResource
) -> bool:
	return left != null and right != null \
		and left.get_inventory_id() == right.get_inventory_id() \
		and left.get_profile_identifier() == right.get_profile_identifier() \
		and left.get_revision() == right.get_revision() \
		and left.get_manifest_fingerprint() == right.get_manifest_fingerprint() \
		and left.get_manifest_algorithm() == right.get_manifest_algorithm() \
		and left.get_containers() == right.get_containers() \
		and left.get_items() == right.get_items() \
		and left.get_references() == right.get_references()


func _transaction_callback_for_scope(
	bridge: InventoryProjectionBridge,
	scope: StringName
) -> Callable:
	var authority := bridge.authority_for_scope(scope)
	for entry_value in (bridge.get("_authority_connections") as Array):
		var entry := entry_value as Dictionary
		if StringName(entry.get("scope", &"")) == scope \
				and entry.get("authority", null) == authority:
			return entry.get("transaction", Callable()) as Callable
	return Callable()


func _callback_scope_generation(callback: Callable) -> int:
	var bound_arguments := callback.get_bound_arguments()
	return int(bound_arguments.back()) if not bound_arguments.is_empty() else 0


func _minimal_late_intent(admission: ZSessionAdmission) -> ZRaidIntent:
	return ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray([
			"inventory", "persistence", "late"])),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		admission.generation,
		1,
		1,
		Adapter.INTENT_KIND_MOVE,
		{})


func _quick_transfer_intent(
	admission: ZSessionAdmission,
	request_suffix: String,
	source_inventory_id: int,
	destination_inventory_id: int,
	item_id: int,
	source_revision: int,
	destination_revision: int,
	command_id: int
) -> ZRaidIntent:
	return ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray([
			"inventory", "persistence", request_suffix])),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		admission.generation,
		1,
		1,
		Adapter.INTENT_KIND_QUICK_TRANSFER,
		{
			"inventory_command_id": command_id,
			"source_inventory_id": source_inventory_id,
			"destination_inventory_id": destination_inventory_id,
			"item_id": item_id,
			"expected_source_revision": source_revision,
			"expected_destination_revision": destination_revision,
		})


func _build_wrong_catalog() -> InventoryCatalog:
	var catalog := InventoryCatalog.new()
	var builtins: Dictionary = catalog.register_builtin_definitions()
	if int(builtins.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
		return null
	var resource := ZerkovInventoryCatalog.build_resource()
	for finding_value in catalog.validate_resource(resource):
		if int((finding_value as Dictionary).get("status_code", -1)) \
				!= InventoryCatalog.STATUS_OK:
			return null
	for finding_value in catalog.register_catalog_resource(resource):
		if int((finding_value as Dictionary).get("status_code", -1)) \
				!= InventoryCatalog.STATUS_OK:
			return null
	var canonical_mapping := ZerkovEquipmentAbilityContent.integration_mapping_bytes()
	var mapping: Dictionary = catalog.register_integration_mapping(
		String(ZerkovEquipmentAbilityContent.INTEGRATION_MAPPING_ID),
		canonical_mapping,
		"res://game/content/zerkov_equipment_ability_content.gd")
	if int(mapping.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
		return null
	var extra: Dictionary = catalog.register_integration_mapping(
		"zerkov.integration.contract.persistence_wrong_catalog",
		PackedByteArray([0x77]),
		"res://tests/raid/inventory_persistence_replacement_contract.gd")
	if int(extra.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
		return null
	var sealed: Dictionary = catalog.seal()
	return catalog if int(sealed.get("status_code", -1)) \
		== InventoryCatalog.STATUS_OK else null


func _envelope_digest(envelope: Dictionary) -> String:
	return ZCanonicalValue.sha256({
		"schema": String(envelope.get("schema", "")),
		"scope": String(envelope.get("scope", "")),
		"inventory_id": int(envelope.get("inventory_id", 0)),
		"profile_identifier": String(envelope.get("profile_identifier", "")),
		"revision": int(envelope.get("revision", -1)),
		"manifest_fingerprint": String(envelope.get("manifest_fingerprint", "")),
		"manifest_algorithm": String(envelope.get("manifest_algorithm", "")),
		"canonical_hash": String(envelope.get("canonical_hash", "")),
		"canonical_sha256": String(envelope.get("canonical_sha256", "")),
		"record_sha256": String(envelope.get("record_sha256", "")),
		"source_owner_generation": int(envelope.get("source_owner_generation", 0)),
	})


func _sha256_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _without_expected_native_error(callback: Callable) -> Dictionary:
	var was_printing := Engine.is_printing_error_messages()
	Engine.set_print_error_messages(false)
	var result := callback.call() as Dictionary
	Engine.set_print_error_messages(was_printing)
	return result
