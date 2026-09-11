extends SceneTree
## Task 5.6 permanent headless contract. This suite exercises canonical combat
## consequences only; it deliberately creates no viewport or presentation node.


class HitPublisher:
	extends RefCounted

	var admission: ZSessionAdmission
	var generation: int = 0
	var queued: Dictionary = {}
	var ordinal: int = 0
	var last_error: StringName = &""

	func configure(value: ZSessionAdmission, authority_generation: int) -> void:
		admission = value.snapshot()
		generation = authority_generation

	func queue_hit(tick: int, target: ZEntityId, zone: StringName,
			damage_milliunits: int) -> String:
		ordinal += 1
		var consequence_id := ZConsequenceId.from_parts(PackedStringArray([
			"health_contract", String.num_int64(tick), String.num_int64(ordinal)]))
		var event_id := consequence_id.canonical_key()
		var payload := {
			"schema": HealthConsequenceAdapter.WEAPON_CONSEQUENCE_SCHEMA,
			"accepted": true,
			"consequence_id": event_id,
			"weapon_consequence_id": "health-contract-shot-%d" % ordinal,
			"raid_id": admission.raid_id.canonical_key(),
			"session_id": admission.session_id.canonical_key(),
			"authority_epoch": admission.authority_epoch,
			"authority_generation": generation,
			"binding_generation": 1,
			"weapon_context_binding_generation": 1,
			"actor_id": admission.actor_id.canonical_key(),
			"actor_source": int(ZRaidIntent.Source.PLAYER),
			"weapon_instance_id": "health-contract-weapon-instance",
			"weapon_entity_id": "health-contract-weapon-entity",
			"weapon_binding_generation": 1,
			"weapon_id": "health-contract-weapon",
			"weapon_version": 1,
			"weapon_revision": ordinal,
			"loaded_rounds_after_commit": 30 - ordinal,
			"tick": tick,
			"damage_milliunits": damage_milliunits,
			"consumed_profile": {"id": "health-contract-ammo", "version": 1},
			"outcome": &"hit",
			"miss_reason": &"",
			"hit": true,
			"blocked": false,
			"entity_id": target.canonical_key(),
			"body_revision": 1,
			"profile_id": "health-contract-profile",
			"hitbox_id": "health-contract-hitbox",
			"body_zone": zone,
			"anatomy_group": &"limb",
			"obstruction_id": "",
			"hit_point_raw": Vector2i(1, 2),
			"ray_fraction_numerator": 1,
			"ray_fraction_denominator": 2,
			"world_revision": tick,
			"world_snapshot_digest": String("a").repeat(64),
			"world_resolution_digest": String("b").repeat(64),
		}
		payload["resolution_digest"] = ZCanonicalValue.sha256(payload)
		if not queued.has(tick):
			queued[tick] = []
		(queued[tick] as Array).append(payload)
		return event_id

	func handle_phase(
		authority: RaidAuthority,
		phase: RaidAuthority.TickPhase,
		tick: int,
		_intents: Array[ZRaidIntent]
	) -> bool:
		last_error = &""
		if phase != RaidAuthority.TickPhase.WORLD_CONSEQUENCES:
			last_error = &"phase_invalid"
			return false
		for value in queued.get(tick, []) as Array:
			var payload := value as Dictionary
			var event_id := ZConsequenceId.parse(String(payload["consequence_id"]))
			if event_id == null or not authority.record_event(
					ZRaidEvent.EventKind.HIT, event_id, tick, admission.actor_id,
					payload, generation):
				last_error = authority.last_error
				return false
		return true


class FakeMedicalPort:
	extends MedicalInventoryParticipantPort

	var ready: bool = true
	var actor_key: String = ""
	var token: String = "fake-medical-token"
	var revision: int = 0
	var commit_mode: StringName = &"success"
	var held: Dictionary = {}
	var consumed: int = 0
	var rollback_count: int = 0
	var teardown_proven: bool = false

	func is_ready() -> bool:
		return ready

	func identity_token() -> String:
		return token if ready else ""

	func actor_id() -> String:
		return actor_key

	func owner_generation() -> int:
		return 1

	func inventory_id() -> int:
		return 99

	func current_revision() -> int:
		return revision

	func prepare_treatment(
		reservation_id: String,
		treatment: StringName,
		expected_revision: int,
		_deadline_tick: int
	) -> Dictionary:
		if not ready or expected_revision != revision or held.has(reservation_id):
			return {"accepted": false, "reason": &"fake_prepare_rejected",
				"mutation_state": MUTATION_NONE}
		held[reservation_id] = {"treatment": treatment, "stage": 1,
			"predecessor_revision": revision}
		return _result(reservation_id, treatment, 1, MUTATION_NONE)

	func commit_treatment_silent(reservation_id: String) -> Dictionary:
		if not held.has(reservation_id):
			return {"accepted": false, "reason": &"fake_unknown",
				"mutation_state": MUTATION_NONE}
		var record := held[reservation_id] as Dictionary
		if commit_mode == &"fail_none":
			return {"accepted": false, "reason": &"fake_commit_rejected",
				"mutation_state": MUTATION_NONE}
		if commit_mode == &"fail_ambiguous":
			ready = false
			return {"accepted": false, "reason": &"fake_commit_ambiguous",
				"mutation_state": MUTATION_AMBIGUOUS}
		record["stage"] = 2
		held[reservation_id] = record
		revision += 1
		consumed += 1
		return _result(reservation_id, StringName(record["treatment"]), 2,
			MUTATION_COMMITTED)

	func publish_treatment(reservation_id: String) -> Dictionary:
		if not held.has(reservation_id):
			return {"accepted": false, "reason": &"fake_unknown",
				"mutation_state": MUTATION_NONE}
		var record := held[reservation_id] as Dictionary
		if int(record["stage"]) != 2:
			return {"accepted": false, "reason": &"fake_stage_invalid",
				"mutation_state": MUTATION_NONE}
		record["stage"] = 4
		held[reservation_id] = record
		return _result(reservation_id, StringName(record["treatment"]), 4,
			MUTATION_COMMITTED)

	func rollback_treatment(reservation_id: String) -> Dictionary:
		if not held.has(reservation_id) or not ready:
			return {"accepted": false, "reason": &"fake_rollback_unproven",
				"mutation_state": MUTATION_AMBIGUOUS}
		var record := held[reservation_id] as Dictionary
		if int(record["stage"]) == 2:
			revision = int(record["predecessor_revision"])
			consumed -= 1
		record["stage"] = 3
		held[reservation_id] = record
		rollback_count += 1
		return _result(reservation_id, StringName(record["treatment"]), 3,
			MUTATION_NONE)

	func release_treatment(reservation_id: String) -> Dictionary:
		return rollback_treatment(reservation_id)

	func clear() -> bool:
		for value in held.values():
			if int((value as Dictionary)["stage"]) == 1 \
					or int((value as Dictionary)["stage"]) == 2:
				if not teardown_proven:
					return false
		ready = false
		held.clear()
		return true

	func _result(
		reservation_id: String,
		treatment: StringName,
		stage: int,
		mutation: StringName
	) -> Dictionary:
		return {
			"accepted": true,
			"reason": &"",
			"reservation_id": reservation_id,
			"treatment": treatment,
			"item_identifier": ZerkovInventoryCatalog.ITEM_BANDAGE \
				if treatment == ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE \
				else ZerkovInventoryCatalog.ITEM_SPLINT,
			"predecessor_revision": maxi(0, revision - (1 if stage >= 2 else 0)),
			"revision": revision,
			"stage": stage,
			"mutation_state": mutation,
		}


class FakeReloadAdapter:
	extends InventoryWeaponAdapter

	var pending_actor: String = ""
	var interrupted: Array[Dictionary] = []
	var has_pending: bool = true

	func is_bound() -> bool:
		return true

	func owner_generation() -> int:
		return 1

	func inventory_id() -> int:
		return 99

	func pending_reloads() -> Array[Dictionary]:
		if not has_pending:
			return []
		return [{"actor_id": pending_actor, "weapon_id": "health-test-weapon"}]

	func interrupt_reload(
		weapon_id: String,
		reason: StringName,
		tick: int
	) -> Dictionary:
		var result := {"accepted": true, "weapon_id": weapon_id,
			"reason": reason, "tick": tick}
		interrupted.append(result)
		has_pending = false
		return result


var checks: int = 0
var failures: int = 0
var _fixtures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("HEALTH_CONSEQUENCE_ADAPTER_CONTRACT: " + message)


func run() -> void:
	_test_policy_and_injury_order()
	_test_damage_bleed_and_death_order()
	_test_atomic_treatment_and_rollback()
	_test_real_inventory_medical_transactions()
	_test_treatment_order_bounds_and_release()
	_test_repeatable_trace()
	_test_same_tick_death_rejects_treatment()
	_test_ambiguous_commit_fail_stops()
	_test_malformed_and_capacity_fail_before_mutation()
	_test_due_bleed_after_hit_death()
	_test_multiple_due_bleeds_after_bleed_death()
	_test_ambiguous_receipt_after_recovery()
	_test_queue_after_authority_teardown()
	_test_real_publish_teardown()
	_test_forged_phase_and_reentrant_admission()
	_test_registration_reentrant_release()
	_test_registration_context_revalidation_cleanup()
	_test_unproven_owner_unload_cannot_clear_hold()
	for fixture in _fixtures.duplicate():
		_cleanup_fixture(fixture)
	await process_frame
	await process_frame
	print("HEALTH_CONSEQUENCE_ADAPTER_RESULT checks=", checks,
		" failures=", failures, " no_ui=true")
	quit(0 if failures == 0 else 1)


func _test_policy_and_injury_order() -> void:
	var validation := ZerkovHealthConsequencePolicy.validate()
	check(bool(validation.get("ok", false))
		and String(validation.get("digest", "")).length() == 64,
		"data-defined consequence policy validates and hashes: " + str(validation))
	var injuries := ZerkovHealthConsequencePolicy.injuries_for_damage(
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000_000)
	check(injuries == PackedStringArray(["heavy_bleed", "fracture"]),
		"limb secondary effects have one declared stable order")
	check(ZerkovHealthConsequencePolicy.injuries_for_damage(
		ZerkovHealthAbilityContent.ZONE_THORAX, 42_000_000) \
			== PackedStringArray(["heavy_bleed"]),
		"non-limb zones do not invent fractures")
	var catalog_resource := ZerkovInventoryCatalog.build_resource()
	var trait_ids := PackedStringArray()
	for value in catalog_resource.trait_schemas:
		trait_ids.append(String((value as InventoryTraitSchema).identifier))
	check(trait_ids.has(String(ZerkovInventoryCatalog.TRAIT_MEDICAL_BANDAGE))
		and trait_ids.has(String(ZerkovInventoryCatalog.TRAIT_MEDICAL_SPLINT)),
		"bandage and splint carry unique sealed transaction traits")


func _test_damage_bleed_and_death_order() -> void:
	var fixture := _new_fixture("damage_death")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var component := fixture["component"] as GameplayAbilityComponent
	var operation := publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])),
		"weapon hit reaches phase-7 health consequences")
	var snapshot := adapter.actor_snapshot(target)
	var leg := _zone(snapshot, ZerkovHealthAbilityContent.ZONE_LEFT_LEG)
	check(int(leg.get("health_micros", -1)) == 23_000_000
		and bool(leg.get("heavy_bleed", false))
		and bool(leg.get("fractured", false)),
		"one 42-damage hit changes exact limb health, bleed, and fracture once")
	check(int(snapshot.get("pain_micros", -1)) == 40_000_000
		and int(snapshot.get("movement_scale_micros", -1)) == 750_000,
		"native injury effects own pain and leg movement cost")
	var outcome := adapter.damage_result(operation)
	check(bool(outcome.get("committed", false))
		and int(outcome.get("health_revision", -1)) == 1
		and (outcome.get("event_ids", []) as Array).size() == 2
		and String(outcome.get("outcome_digest", "")).length() == 64
		and adapter.damage_result(operation) == outcome,
		"stable damage identity stores one detached replay result and two injuries")
	check(adapter.bleed_schedule_count() == 1,
		"heavy bleed creates one bounded due-work schedule")
	for _index in 60:
		check(authority.advance_one(int(fixture["generation"])),
			"bleed fixture advances deterministically")
	snapshot = adapter.actor_snapshot(target)
	leg = _zone(snapshot, ZerkovHealthAbilityContent.ZONE_LEFT_LEG)
	check(int(leg.get("health_micros", -1)) == 22_000_000
		and int(snapshot.get("health_revision", -1)) == 2,
		"heavy bleed applies exactly one fixed-unit consequence at tick 61")

	var lethal_fixture := _new_fixture("lethal")
	var lethal_authority := lethal_fixture["authority"] as RaidAuthority
	var lethal_adapter := lethal_fixture["adapter"] as HealthConsequenceAdapter
	var lethal_publisher := lethal_fixture["publisher"] as HitPublisher
	var lethal_target := lethal_fixture["target"] as ZEntityId
	var lethal_medical := FakeMedicalPort.new()
	lethal_medical.actor_key = lethal_target.canonical_key()
	var reload := FakeReloadAdapter.new()
	reload.pending_actor = lethal_target.canonical_key()
	root.add_child(reload)
	lethal_fixture["reload_node"] = reload
	check(lethal_adapter.attach_medical_inventory(
		lethal_target, lethal_medical, reload),
		"death fixture binds exact actor reload interruption adapter")
	var lethal_operation := lethal_publisher.queue_hit(
		1, lethal_target, ZerkovHealthAbilityContent.ZONE_HEAD, 42_000)
	check(lethal_authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(lethal_fixture["generation"])) and lethal_authority.advance_one(
			int(lethal_fixture["generation"])),
		"lethal hit commits in phase 7")
	var lethal := lethal_adapter.damage_result(lethal_operation)
	var kinds := _journal_kinds(lethal_authority)
	check(bool(lethal.get("dead", false))
		and bool(lethal.get("death_committed", false))
		and kinds == PackedStringArray(["hit", "death", "kill"]),
		"lethal state emits death then kill exactly once after the source hit")
	check(lethal_adapter.bleed_schedule_count() == 0
		and not bool(lethal_adapter.actor_snapshot(lethal_target).get("alive", true))
		and reload.interrupted.size() == 1
		and reload.interrupted[0].get("reason") == &"death"
		and int(reload.interrupted[0].get("tick", -1)) == 1,
		"death cancels due bleed, publishes dead state, and interrupts reload once")
	var ignored_operation := lethal_publisher.queue_hit(
		2, lethal_target, ZerkovHealthAbilityContent.ZONE_HEAD, 42_000)
	check(lethal_authority.advance_one(int(lethal_fixture["generation"])),
		"post-death combat input is deterministically consumed")
	var ignored := lethal_adapter.damage_result(ignored_operation)
	check(bool(ignored.get("ignored_target_dead", false))
		and int(ignored.get("applied_damage_micros", -1)) == 0
		and reload.interrupted.size() == 1
		and _journal_kinds(lethal_authority) \
			== PackedStringArray(["hit", "death", "kill", "hit"]),
		"post-death hit cannot apply damage or duplicate terminal events")


func _test_atomic_treatment_and_rollback() -> void:
	var fixture := _new_fixture("treatment_success")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var port := FakeMedicalPort.new()
	port.actor_key = target.canonical_key()
	check(adapter.attach_medical_inventory(target, port),
		"medical participant binds to the exact stable actor")
	publisher.queue_hit(1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "treatment setup injury commits")
	var request := _treatment_request(
		fixture, "success", 2, 1, ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1, 0)
	var queued := adapter.queue_treatment(request)
	check(bool(queued.get("accepted", false)) and bool(queued.get("queued", false)),
		"valid treatment is queue-only before its authoritative tick")
	check(authority.advance_one(int(fixture["generation"])),
		"prepared health and inventory treatment commits atomically")
	var receipt := adapter.treatment_receipt(String(request["request_id"]))
	var leg := _zone(adapter.actor_snapshot(target),
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG)
	check(bool(receipt.get("committed", false)) and port.consumed == 1
		and String(receipt.get("outcome_digest", "")).length() == 64
		and not bool(leg.get("heavy_bleed", true))
		and bool(leg.get("bandaged", false))
		and adapter.bleed_schedule_count() == 0,
		"successful bandage couples one item to one exact-zone state transition")
	var replay := adapter.queue_treatment(request)
	check(replay == receipt and port.consumed == 1,
		"treatment request replay consumes no second item or health transition")

	var rollback_fixture := _new_fixture("treatment_rollback")
	var rollback_authority := rollback_fixture["authority"] as RaidAuthority
	var rollback_adapter := rollback_fixture["adapter"] as HealthConsequenceAdapter
	var rollback_publisher := rollback_fixture["publisher"] as HitPublisher
	var rollback_target := rollback_fixture["target"] as ZEntityId
	var rollback_port := FakeMedicalPort.new()
	rollback_port.actor_key = rollback_target.canonical_key()
	rollback_port.commit_mode = &"fail_none"
	check(rollback_adapter.attach_medical_inventory(rollback_target, rollback_port),
		"rollback participant binds")
	rollback_publisher.queue_hit(
		1, rollback_target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(rollback_authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(rollback_fixture["generation"])) and rollback_authority.advance_one(
			int(rollback_fixture["generation"])), "rollback setup injury commits")
	var before := rollback_adapter.actor_snapshot(rollback_target)
	var rollback_request := _treatment_request(
		rollback_fixture, "rollback", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_SPLINT, 1, 0)
	check(bool(rollback_adapter.queue_treatment(rollback_request).get(
		"accepted", false)) and rollback_authority.advance_one(
			int(rollback_fixture["generation"])),
		"proven inventory rejection rolls the native health transition back")
	var rolled_receipt := rollback_adapter.treatment_receipt(
		String(rollback_request["request_id"]))
	var after := rollback_adapter.actor_snapshot(rollback_target)
	check(not bool(rolled_receipt.get("committed", true))
		and rollback_port.consumed == 0 and rollback_port.rollback_count == 1
		and _zone(after, ZerkovHealthAbilityContent.ZONE_LEFT_LEG).get("fractured")
		and int(after.get("health_revision", -1)) \
			== int(before.get("health_revision", -2)),
		"rollback leaves item quantity, injury, and health revision at predecessor")


func _test_same_tick_death_rejects_treatment() -> void:
	var fixture := _new_fixture("same_tick_death")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var port := FakeMedicalPort.new()
	port.actor_key = target.canonical_key()
	check(adapter.attach_medical_inventory(target, port),
		"same-tick participant binds")
	publisher.queue_hit(1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "same-tick setup injury commits")
	var request := _treatment_request(
		fixture, "death_race", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1, 0)
	check(bool(adapter.queue_treatment(request).get("accepted", false)),
		"same-tick treatment is accepted before death is known")
	publisher.queue_hit(2, target, ZerkovHealthAbilityContent.ZONE_HEAD, 42_000)
	check(authority.advance_one(int(fixture["generation"])),
		"same-tick weapon damage orders before treatment")
	var receipt := adapter.treatment_receipt(String(request["request_id"]))
	check(not bool(receipt.get("committed", true))
		and receipt.get("reason") == &"health_actor_not_alive"
		and port.consumed == 0 and port.held.is_empty(),
		"same-tick death rejects queued healing before inventory preparation")


func _test_real_inventory_medical_transactions() -> void:
	var fixture := _new_fixture("real_inventory", true)
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var admission := fixture["admission"] as ZSessionAdmission
	var component := fixture["component"] as GameplayAbilityComponent
	var owner := RaidInventoryOwner.new()
	owner.name = "HealthMedicalInventoryOwner"
	root.add_child(owner)
	check(owner.configure(), "real medical inventory owner configures")
	var inventory_authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var pockets := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	check(pockets > 0, "real medical pockets container resolves")
	var bandages := inventory_authority.insert_item(
		inventory_id, String(ZerkovInventoryCatalog.ITEM_BANDAGE), 2,
		_spatial(pockets, 0, 0), RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 56_001)
	var splints := inventory_authority.insert_item(
		inventory_id, String(ZerkovInventoryCatalog.ITEM_SPLINT), 2,
		_spatial(pockets, 2, 0), RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 56_002)
	check(bool(bandages.get("accepted", false))
		and bool(splints.get("accepted", false)),
		"authored bandage and splint quantities insert into real inventory")
	var identity := OfflineInventoryIdentity.new()
	check(identity.configure(admission, owner, component.entity_id),
		"offline medical identity binds actor to exact raid inventory")
	var port := InventoryMedicalParticipant.new()
	check(port.configure(owner, admission, identity, owner.generation())
		and port.is_ready(),
		"production medical participant verifies owner, identity, and catalog")
	var predecessor := port.current_revision()
	var probe_reservation := "health-contract-medical-probe"
	var held := port.prepare_treatment(
		probe_reservation, ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE,
		predecessor, 100)
	var released := port.release_treatment(probe_reservation)
	check(bool(held.get("accepted", false)) and int(held.get("stage", 0)) == 1
		and bool(released.get("accepted", false))
		and int(released.get("stage", 0)) == 3
		and port.current_revision() == predecessor
		and _definition_quantity(owner, ZerkovInventoryCatalog.ITEM_BANDAGE) == 2,
		"prepare/release holds one exact medical trait without quantity mutation")
	check(adapter.attach_medical_inventory(target, port),
		"production medical participant attaches to health actor")
	publisher.queue_hit(1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "real inventory setup injury commits")
	var bandage_request := _treatment_request(
		fixture, "real_bandage", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1,
		port.current_revision())
	check(bool(adapter.queue_treatment(bandage_request).get("accepted", false))
		and authority.advance_one(int(fixture["generation"])),
		"real bandage inventory and ability successors commit together")
	var after_bandage := adapter.actor_snapshot(target)
	check(bool(adapter.treatment_receipt(String(bandage_request["request_id"]))
		.get("committed", false))
		and _definition_quantity(owner, ZerkovInventoryCatalog.ITEM_BANDAGE) == 1
		and not bool(_zone(after_bandage,
			ZerkovHealthAbilityContent.ZONE_LEFT_LEG).get("heavy_bleed", true))
		and int(after_bandage.get("health_revision", -1)) == 2,
		"real bandage consumes exactly one item and cancels exact-zone bleed")
	var splint_request := _treatment_request(
		fixture, "real_splint", 3, 2,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_SPLINT, 2,
		port.current_revision())
	check(bool(adapter.queue_treatment(splint_request).get("accepted", false))
		and authority.advance_one(int(fixture["generation"])),
		"real splint inventory and ability successors commit together")
	var after_splint := adapter.actor_snapshot(target)
	check(bool(adapter.treatment_receipt(String(splint_request["request_id"]))
		.get("committed", false))
		and _definition_quantity(owner, ZerkovInventoryCatalog.ITEM_SPLINT) == 1
		and not bool(_zone(after_splint,
			ZerkovHealthAbilityContent.ZONE_LEFT_LEG).get("fractured", true))
		and bool(_zone(after_splint,
			ZerkovHealthAbilityContent.ZONE_LEFT_LEG).get("splinted", false))
		and int(after_splint.get("health_revision", -1)) == 3,
		"real splint consumes exactly one item and cancels exact-zone fracture")
	var teardown_hold := port.prepare_treatment(
		"health-contract-owner-teardown", ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE,
		port.current_revision(), 100)
	check(bool(teardown_hold.get("accepted", false))
		and owner.teardown(owner.generation()) and port.clear()
		and port.lifecycle == InventoryMedicalParticipant.Lifecycle.RELEASED,
		"exact owner-generation unload proves an unfinished hold cannot later commit")
	fixture["inventory_owner"] = owner
	fixture["inventory_identity"] = identity


func _test_ambiguous_commit_fail_stops() -> void:
	var fixture := _new_fixture("ambiguous")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var port := FakeMedicalPort.new()
	port.actor_key = target.canonical_key()
	port.commit_mode = &"fail_ambiguous"
	check(adapter.attach_medical_inventory(target, port),
		"ambiguous participant binds")
	publisher.queue_hit(1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "ambiguous setup injury commits")
	var request := _treatment_request(
		fixture, "ambiguous", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1, 0)
	check(bool(adapter.queue_treatment(request).get("accepted", false))
		and not authority.advance_one(int(fixture["generation"])),
		"unprovable cross-domain commit fails the authoritative tick")
	var recovery := adapter.recovery_details()
	check(adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED
		and authority.lifecycle == RaidAuthority.Lifecycle.FAILED
		and bool(recovery.get("requires_authoritative_teardown", false)),
		"ambiguous mutation latches bounded truthful fail-stop state")
	check(not adapter.recover_by_teardown(2)
		and adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED,
		"recovery cannot claim success while the participant remains unproven")
	port.teardown_proven = true
	check(adapter.recover_by_teardown(2)
		and adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.RELEASED
		and (fixture["component"] as GameplayAbilityComponent).is_torn_down(),
		"authoritative participant teardown resolves fail-stop without replay")


func _test_treatment_order_bounds_and_release() -> void:
	var fixture := _new_fixture("treatment_order")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var port := FakeMedicalPort.new()
	port.actor_key = target.canonical_key()
	check(adapter.attach_medical_inventory(target, port),
		"ordered treatment participant binds")
	publisher.queue_hit(1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "ordered treatment injury commits")
	# Queue later sequence first. The expected predecessor revisions deliberately
	# prove that sequence 1 must run before sequence 2 for both domains to commit.
	var bandage := _treatment_request(
		fixture, "ordered_bandage", 2, 2,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 2, 1)
	var splint := _treatment_request(
		fixture, "ordered_splint", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_SPLINT, 1, 0)
	check(bool(adapter.queue_treatment(bandage).get("accepted", false))
		and bool(adapter.queue_treatment(splint).get("accepted", false))
		and authority.advance_one(int(fixture["generation"])),
		"same-due-tick treatments sort by command sequence, not arrival")
	check(bool(adapter.treatment_receipt(String(splint["request_id"])).get(
		"committed", false))
		and bool(adapter.treatment_receipt(String(bandage["request_id"])).get(
			"committed", false))
		and port.consumed == 2
		and _journal_treatments(authority) \
			== PackedStringArray(["splint", "bandage"]),
		"deterministic treatment ordering commits exact health/inventory predecessors")

	var bounded := _new_fixture("bounded_queue")
	var bounded_adapter := bounded["adapter"] as HealthConsequenceAdapter
	var bounded_target := bounded["target"] as ZEntityId
	var bounded_port := FakeMedicalPort.new()
	bounded_port.actor_key = bounded_target.canonical_key()
	check(bounded_adapter.attach_medical_inventory(bounded_target, bounded_port),
		"bounded-queue participant binds")
	var first_request: Dictionary = {}
	var all_admitted := true
	for index in HealthConsequenceAdapter.MAX_PENDING_TREATMENTS:
		var request := _treatment_request(
			bounded, "bounded_%02d" % index, 100, index + 1,
			ZerkovHealthAbilityContent.ZONE_LEFT_ARM,
			ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 0, 0)
		if index == 0:
			first_request = request
		all_admitted = all_admitted \
			and bool(bounded_adapter.queue_treatment(request).get("accepted", false))
	var overflow := _treatment_request(
		bounded, "bounded_overflow", 100, 65,
		ZerkovHealthAbilityContent.ZONE_LEFT_ARM,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 0, 0)
	var overflow_receipt := bounded_adapter.queue_treatment(overflow)
	check(all_admitted
		and bounded_adapter.pending_treatment_count() \
			== HealthConsequenceAdapter.MAX_PENDING_TREATMENTS
		and overflow_receipt.get("reason") == &"health_treatment_queue_capacity",
		"pending treatment ledger admits 64 and rejects the 65th before mutation")
	check(bounded_adapter.queue_treatment(first_request)
		== bounded_adapter.treatment_receipt(String(first_request["request_id"])),
		"queued request identity replay consumes no extra bounded slot")
	var bounded_component := bounded["component"] as GameplayAbilityComponent
	check(bounded_adapter.release_binding(&"bounded_release", 0)
		and bounded_adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.RELEASED
		and bounded_adapter.pending_treatment_count() == 0
		and bounded_component.is_torn_down(),
		"release terminalizes pending work and tears down owned health runtime")
	var released_receipt := bounded_adapter.treatment_receipt(
		String(first_request["request_id"]))
	check(released_receipt.get("reason") == &"health_adapter_released"
		and not bool(released_receipt.get("committed", true))
		and bounded_adapter.queue_treatment(first_request).get("reason") \
			== &"health_treatment_queue_unavailable",
		"late treatment after release is terminal and mutation-free")


func _test_malformed_and_capacity_fail_before_mutation() -> void:
	var malformed := _new_fixture("malformed_source")
	var malformed_authority := malformed["authority"] as RaidAuthority
	var malformed_adapter := malformed["adapter"] as HealthConsequenceAdapter
	var malformed_publisher := malformed["publisher"] as HitPublisher
	var malformed_target := malformed["target"] as ZEntityId
	malformed_publisher.queue_hit(
		1, malformed_target, ZerkovHealthAbilityContent.ZONE_LEFT_ARM, 42_000)
	var forged := (malformed_publisher.queued[1] as Array)[0] as Dictionary
	forged["damage_milliunits"] = 41_999
	var before := malformed_adapter.actor_snapshot(malformed_target)
	check(malformed_authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(malformed["generation"]))
		and not malformed_authority.advance_one(int(malformed["generation"])),
		"malformed signed consequence fails the authoritative tick")
	check(malformed_adapter.lifecycle \
			== HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED
		and malformed_adapter.last_error == &"health_weapon_consequence_digest_invalid"
		and malformed_adapter.actor_snapshot(malformed_target) == before,
		"malformed source digest fails before health, injury, or event mutation")

	var saturated := _new_fixture("event_capacity")
	var saturated_authority := saturated["authority"] as RaidAuthority
	var saturated_adapter := saturated["adapter"] as HealthConsequenceAdapter
	var saturated_publisher := saturated["publisher"] as HitPublisher
	var saturated_target := saturated["target"] as ZEntityId
	var one_slot := RaidEventJournal.new()
	check(one_slot.configure(saturated["raid_id"] as ZRaidId, 1),
		"one-slot journal configures for preflight boundary")
	saturated_authority.journal = one_slot
	saturated_publisher.queue_hit(
		1, saturated_target, ZerkovHealthAbilityContent.ZONE_LEFT_ARM, 42_000)
	before = saturated_adapter.actor_snapshot(saturated_target)
	check(saturated_authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(saturated["generation"]))
		and not saturated_authority.advance_one(int(saturated["generation"])),
		"insufficient consequence journal capacity fails the tick")
	check(saturated_adapter.last_error == &"health_event_capacity_exceeded"
		and saturated_adapter.actor_snapshot(saturated_target) == before
		and one_slot.size() == 1,
		"event capacity is preflighted after source receipt and before health mutation")


func _test_repeatable_trace() -> void:
	var left := _new_fixture("repeat_left")
	var right := _new_fixture("repeat_right")
	for fixture in [left, right]:
		var publisher := fixture["publisher"] as HitPublisher
		var target := fixture["target"] as ZEntityId
		publisher.queue_hit(
			1, target, ZerkovHealthAbilityContent.ZONE_LEFT_ARM, 42_000)
		publisher.queue_hit(
			1, target, ZerkovHealthAbilityContent.ZONE_ABDOMEN, 30_000)
		var authority := fixture["authority"] as RaidAuthority
		check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
			int(fixture["generation"]))
			and authority.advance_one(int(fixture["generation"])),
			"repeatable trace commits in source sequence")
	check(_normalized_actor_state(
		(left["adapter"] as HealthConsequenceAdapter).actor_snapshot(
			left["target"] as ZEntityId)) \
		== _normalized_actor_state(
			(right["adapter"] as HealthConsequenceAdapter).actor_snapshot(
				right["target"] as ZEntityId))
		and _normalized_event_trace(left["authority"] as RaidAuthority) \
			== _normalized_event_trace(right["authority"] as RaidAuthority),
		"identical ordered facts produce identical native state and consequence trace")


func _test_due_bleed_after_hit_death() -> void:
	var fixture := _new_fixture("due_bleed_hit_death")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var generation := int(fixture["generation"])
	publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"due-bleed/hit-death fixture becomes active")
	for tick in range(1, 61):
		check(authority.advance_one(generation),
			"due-bleed/hit-death fixture advances to tick " + str(tick))
	publisher.queue_hit(61, target, ZerkovHealthAbilityContent.ZONE_HEAD, 42_000)
	check(authority.advance_one(generation),
		"death on a due-bleed tick retires cancelled work without failing the raid")
	check(adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.BOUND
		and bool(adapter.actor_snapshot(target).get("dead", false))
		and adapter.bleed_schedule_count() == 0,
		"same-tick lethal hit leaves the ordinary dead adapter bound with no bleed")


func _test_multiple_due_bleeds_after_bleed_death() -> void:
	var fixture := _new_fixture("multiple_due_bleeds_death")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var generation := int(fixture["generation"])
	publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_HEAD, 34_000)
	publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"multiple-due-bleeds fixture becomes active")
	for tick in range(1, 61):
		check(authority.advance_one(generation),
			"multiple-due-bleeds fixture advances to tick " + str(tick))
	check(authority.advance_one(generation),
		"one lethal due bleed retires other cancelled due bleeds")
	check(adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.BOUND
		and bool(adapter.actor_snapshot(target).get("dead", false))
		and adapter.bleed_schedule_count() == 0,
		"lethal bleed leaves the ordinary dead adapter bound with no schedules")


func _test_ambiguous_receipt_after_recovery() -> void:
	var fixture := _new_fixture("ambiguous_receipt")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var port := FakeMedicalPort.new()
	port.actor_key = target.canonical_key()
	port.commit_mode = &"fail_ambiguous"
	check(adapter.attach_medical_inventory(target, port),
		"ambiguous receipt port binds")
	publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "ambiguous receipt injury setup")
	var request := _treatment_request(
		fixture, "ambiguous_recovery", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1, 0)
	check(bool(adapter.queue_treatment(request).get("accepted", false)),
		"ambiguous receipt request queues")
	check(not authority.advance_one(int(fixture["generation"])),
		"ambiguous receipt request fails stop")
	port.teardown_proven = true
	check(adapter.recover_by_teardown(2),
		"ambiguous receipt recovery proves teardown")
	var receipt := adapter.treatment_receipt(String(request["request_id"]))
	check(bool(receipt.get("terminal", false))
		and not bool(receipt.get("queued", true))
		and receipt.get("reason") == &"health_adapter_released"
		and adapter.pending_treatment_count() == 0,
		"resolved teardown terminalizes a dequeued ambiguous treatment receipt")


func _test_queue_after_authority_teardown() -> void:
	var fixture := _new_fixture("queue_late")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var request := _treatment_request(
		fixture, "post_teardown", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 0, 0)
	check(authority.teardown(int(fixture["generation"])),
		"late-queue owner authority tears down")
	var receipt := adapter.queue_treatment(request)
	check(not bool(receipt.get("accepted", true))
		and receipt.get("reason") == &"health_treatment_queue_unavailable"
		and adapter.pending_treatment_count() == 0,
		"torn-down authority generation cannot admit a treatment slot")


func _test_real_publish_teardown() -> void:
	var fixture := _new_fixture("publish_teardown", true)
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var admission := fixture["admission"] as ZSessionAdmission
	var component := fixture["component"] as GameplayAbilityComponent
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	check(owner.configure(), "reentrant medical inventory owner configures")
	fixture["inventory_owner"] = owner
	var inventory_authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var pockets := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	var inserted := inventory_authority.insert_item(
		inventory_id, String(ZerkovInventoryCatalog.ITEM_BANDAGE), 2,
		_spatial(pockets, 0, 0), RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 56_501)
	check(bool(inserted.get("accepted", false)),
		"reentrant fixture inserts bandages")
	var identity := OfflineInventoryIdentity.new()
	check(identity.configure(admission, owner, component.entity_id),
		"reentrant fixture identity binds")
	fixture["inventory_identity"] = identity
	var port := InventoryMedicalParticipant.new()
	check(port.configure(owner, admission, identity, owner.generation()),
		"reentrant production port configures")
	check(adapter.attach_medical_inventory(target, port),
		"reentrant production port attaches")
	var publication_observed: Array[Dictionary] = []
	inventory_authority.quantity_reservation_published.connect(
		func(_result: Dictionary) -> void:
			publication_observed.append({
				"teardown": owner.teardown(owner.generation()),
				"port_ready": port.is_ready(),
				"inventory_loaded": inventory_authority.has_inventory(inventory_id),
			}))
	publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])), "reentrant treatment injury setup")
	var request := _treatment_request(
		fixture, "reentrant_bandage", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1,
		port.current_revision())
	check(bool(adapter.queue_treatment(request).get("accepted", false)),
		"reentrant bandage queues")
	check(not authority.advance_one(int(fixture["generation"]))
		and adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED
		and port.lifecycle == InventoryMedicalParticipant.Lifecycle.RECOVERY_REQUIRED,
		"owner teardown during native publication fails the stale continuation")
	check(publication_observed.size() == 1
		and not bool(publication_observed[0].get("teardown", true))
		and bool(publication_observed[0].get("inventory_loaded", false)),
		"reentrant owner teardown is not mistaken for a completed scoped unload")
	var recovery := adapter.recovery_details()
	var recovery_details := recovery.get("details", {}) as Dictionary
	var publication := recovery_details.get("publication", {}) as Dictionary
	var port_recovery := publication.get("recovery", {}) as Dictionary
	var port_details := port_recovery.get("details", {}) as Dictionary
	check(publication.get("mutation_state") \
			== MedicalInventoryParticipantPort.MUTATION_COMMITTED
		and bool(port_details.get("native_publication_committed", false)),
		"reentrant publication reports its proven committed mutation honestly")
	check(adapter.recover_by_teardown(2),
		"reentrant publication recovery resolves exact native reservation health")
	var receipt := adapter.treatment_receipt(String(request["request_id"]))
	check(bool(receipt.get("terminal", false))
		and not bool(receipt.get("queued", true))
		and not bool(receipt.get("committed", true))
		and receipt.get("reason") == &"health_adapter_released"
		and receipt.get("mutation_state") \
			== MedicalInventoryParticipantPort.MUTATION_COMMITTED
		and adapter.pending_treatment_count() == 0,
		"reentrant publication recovery terminalizes the in-flight receipt")


func _test_forged_phase_and_reentrant_admission() -> void:
	var fixture := _new_fixture("phase_fence")
	var authority := fixture["authority"] as RaidAuthority
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var publisher := fixture["publisher"] as HitPublisher
	var target := fixture["target"] as ZEntityId
	var before := adapter.actor_snapshot(target)
	check(not adapter.handle_raid_phase(
		authority, RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
		1, [], adapter.binding_generation())
		and adapter.actor_snapshot(target) == before,
		"direct phase callback outside exact authority dispatch cannot mutate health")
	var request := _treatment_request(
		fixture, "during_damage", 2, 1,
		ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE, 1, 0)
	var observed: Array[Dictionary] = []
	adapter.damage_committed.connect(func(_result: Dictionary) -> void:
		observed.append({
			"queue": adapter.queue_treatment(request),
			"release": adapter.release_binding(),
			"phase": adapter.handle_raid_phase(
				authority, RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
				1, [], adapter.binding_generation()),
		}))
	publisher.queue_hit(
		1, target, ZerkovHealthAbilityContent.ZONE_LEFT_LEG, 42_000)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE,
		int(fixture["generation"])) and authority.advance_one(
			int(fixture["generation"])),
		"reentrant public callback leaves genuine damage successful")
	check(observed.size() == 1 and not bool(observed[0].get("release", true))
		and not bool(observed[0].get("phase", true))
		and not bool((observed[0].get("queue", {}) as Dictionary).get(
			"accepted", true))
		and adapter.pending_treatment_count() == 0
		and int(_zone(adapter.actor_snapshot(target),
			ZerkovHealthAbilityContent.ZONE_LEFT_LEG).get(
				"health_micros", -1)) == 23_000_000,
		"public damage callback rejects recursive queue, release, and phase calls")


func _test_registration_reentrant_release() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"health_consequence", "register_reentry"]))
	var admission := SessionCoordinator.new().open_offline(
		raid_id, &"register_reentry", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 560),
		"registration reentry authority configures")
	var adapter := HealthConsequenceAdapter.new()
	check(adapter.bind_authority(authority, authority.generation()),
		"registration reentry adapter binds")
	var component := _new_health_component(88_001)
	var observed: Array[Dictionary] = []
	component.ability_granted.connect(func(_grant: Dictionary) -> void:
		if observed.is_empty():
			observed.append({
				"released": adapter.release_binding(),
				"lifecycle": adapter.lifecycle,
			}))
	var result := adapter.register_actor(
		admission.actor_id, ZRaidIntent.Source.PLAYER,
		component, component.entity_id)
	check(observed.size() == 1 and not bool(observed[0].get("released", true))
		and bool(result.get("accepted", false)) and adapter.is_bound(),
		"bootstrap ability notification cannot release binding mid-registration")
	if adapter.is_bound():
		adapter.release_binding()
	authority.teardown(authority.generation())
	if not component.is_torn_down():
		component.queue_teardown(component.get_current_tick())
	component.queue_free()


func _test_registration_context_revalidation_cleanup() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"health_consequence", "register_context_change"]))
	var admission := SessionCoordinator.new().open_offline(
		raid_id, &"register_context_change", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 561),
		"registration context-change authority configures")
	var generation := authority.generation()
	var adapter := HealthConsequenceAdapter.new()
	check(adapter.bind_authority(authority, generation),
		"registration context-change adapter binds")
	var component := _new_health_component(88_002)
	var before := component.write_snapshot()
	var transitioned: Array[bool] = []
	component.ability_granted.connect(func(_grant: Dictionary) -> void:
		if transitioned.is_empty():
			transitioned.append(authority.transition(
				RaidAuthority.Lifecycle.ACTIVE, generation)))
	var result := adapter.register_actor(
		admission.actor_id, ZRaidIntent.Source.PLAYER,
		component, component.entity_id)
	check(transitioned == [true]
		and not bool(result.get("accepted", true))
		and result.get("reason") == &"health_registration_context_changed"
		and bool(result.get("cleanup_proven", false))
		and adapter.actor_count() == 0
		and component.write_snapshot() == before,
		"callback-driven authority transition rejects registration and restores bytes")
	if adapter.is_bound():
		adapter.release_binding()
	if authority.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		authority.teardown(generation)
	if not component.is_torn_down():
		component.queue_teardown(component.get_current_tick())
	component.queue_free()


func _test_unproven_owner_unload_cannot_clear_hold() -> void:
	var fixture := _new_fixture("unload_proof", true)
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	check(owner.configure(), "unload proof owner configures")
	fixture["inventory_owner"] = owner
	var inventory_authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var pockets := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	var inserted := inventory_authority.insert_item(
		inventory_id, String(ZerkovInventoryCatalog.ITEM_BANDAGE), 2,
		_spatial(pockets, 0, 0), RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 56_601)
	check(bool(inserted.get("accepted", false)),
		"unload proof fixture inserts bandages")
	var identity := OfflineInventoryIdentity.new()
	check(identity.configure(
		fixture["admission"] as ZSessionAdmission, owner,
		(fixture["component"] as GameplayAbilityComponent).entity_id),
		"unload proof identity binds")
	fixture["inventory_identity"] = identity
	var port := InventoryMedicalParticipant.new()
	check(port.configure(owner, fixture["admission"] as ZSessionAdmission,
		identity, owner.generation()), "unload proof port configures")
	var held := port.prepare_treatment(
		"medical-held-before-unload",
		ZerkovHealthConsequencePolicy.TREATMENT_BANDAGE,
		port.current_revision(), 100)
	check(bool(held.get("accepted", false)), "unload proof medical item held")
	var other_hold := inventory_authority.prepare_quantity_reservation(
		inventory_id, "other-reservation-to-publish",
		String(ZerkovInventoryCatalog.TRAIT_MEDICAL_BANDAGE),
		[String(ZerkovInventoryCatalog.CONTAINER_POCKETS)],
		1, port.current_revision(), 100)
	check(bool(other_hold.get("accepted", false)),
		"unload proof independent remainder held")
	var observed: Array[Dictionary] = []
	inventory_authority.quantity_reservation_published.connect(
		func(_result: Dictionary) -> void:
			observed.append({
				"owner_teardown": owner.teardown(owner.generation()),
				"native_inventory_loaded": inventory_authority.has_inventory(inventory_id),
			}))
	var other_commit := inventory_authority.commit_quantity_reservation_silent(
		inventory_id, "other-reservation-to-publish")
	var other_published := inventory_authority.publish_quantity_reservation(
		"other-reservation-to-publish")
	check(bool(other_commit.get("accepted", false))
		and bool(other_published.get("accepted", false)),
		"independent publication reaches reentrant teardown")
	var cleared := port.clear()
	var late_commit := inventory_authority.commit_quantity_reservation_silent(
		inventory_id, "medical-held-before-unload")
	check(not cleared or not bool(late_commit.get("accepted", false)),
		"clear never claims unload while the exact native hold can still commit")


func _new_fixture(label: String, use_player_actor: bool = false) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"health_consequence", label]))
	var admission := SessionCoordinator.new().open_offline(
		raid_id, StringName("health_consequence_" + label), &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 560),
		label + " authority configures")
	var generation := authority.generation()
	var target := admission.actor_id if use_player_actor else ZEntityId.from_parts(
		PackedStringArray(["health_consequence", label, "target"]))
	if not use_player_actor:
		check(authority.authorize_actor(target, ZRaidIntent.Source.AI, generation),
			label + " target identity is authorized")
	var publisher := HitPublisher.new()
	publisher.configure(admission, generation)
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.WORLD_CONSEQUENCES,
		StringName("health_hits_" + label), Callable(publisher, "handle_phase"),
		generation), label + " hit publisher registers")
	var adapter := HealthConsequenceAdapter.new()
	check(adapter.bind_authority(authority, generation),
		label + " health adapter binds")
	var component := _new_health_component(70_000 + _fixtures.size())
	var registration := adapter.register_actor(
		target, ZRaidIntent.Source.PLAYER if use_player_actor \
			else ZRaidIntent.Source.AI, component, component.entity_id)
	check(bool(registration.get("accepted", false))
		and int(registration.get("ability_count", 0)) == 36,
		label + " health actor registers all owned transitions")
	var fixture := {
		"label": label,
		"raid_id": raid_id,
		"admission": admission,
		"authority": authority,
		"generation": generation,
		"target": target,
		"publisher": publisher,
		"adapter": adapter,
		"component": component,
	}
	_fixtures.append(fixture)
	return fixture


func _new_health_component(entity_id: int) -> GameplayAbilityComponent:
	var component := GameplayAbilityComponent.new()
	component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	component.entity_id = entity_id
	component.tick_rate = ZerkovHealthAbilityContent.TICK_RATE
	component.definition_catalog = ZerkovHealthAbilityContent.build_definition_catalog()
	root.add_child(component)
	var findings: Array = component.configure()
	check(GameplayDefinitionValidator.is_ok(findings) and component.is_configured(),
		"real native health component configures")
	return component


func _treatment_request(
	fixture: Dictionary,
	label: String,
	target_tick: int,
	sequence: int,
	zone: StringName,
	treatment: StringName,
	health_revision: int,
	inventory_revision: int
) -> Dictionary:
	var admission := fixture["admission"] as ZSessionAdmission
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	var request_id := ZRequestId.from_parts(PackedStringArray([
		"health_treatment", String(fixture["label"]), label])).canonical_key()
	return {
		"schema": HealthConsequenceAdapter.TREATMENT_REQUEST_SCHEMA,
		"request_id": request_id,
		"raid_id": admission.raid_id.canonical_key(),
		"session_id": admission.session_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"authority_generation": int(fixture["generation"]),
		"adapter_generation": adapter.binding_generation(),
		"actor_id": (fixture["target"] as ZEntityId).canonical_key(),
		"actor_registration_generation": 1,
		"target_tick": target_tick,
		"sequence": sequence,
		"body_zone": zone,
		"treatment": treatment,
		"expected_health_revision": health_revision,
		"expected_inventory_revision": inventory_revision,
	}


func _zone(snapshot: Dictionary, zone: StringName) -> Dictionary:
	for value in snapshot.get("body_parts", []) as Array:
		var body_part := value as Dictionary
		if StringName(body_part.get("zone_identifier", &"")) == zone:
			return body_part
	return {}


func _journal_kinds(authority: RaidAuthority) -> PackedStringArray:
	var result := PackedStringArray()
	for value in authority.journal.records():
		result.append(String((value as Dictionary).get("kind", "")))
	return result


func _journal_treatments(authority: RaidAuthority) -> PackedStringArray:
	var result := PackedStringArray()
	for value in authority.journal.records():
		var record := value as Dictionary
		if String(record.get("kind", "")) == "heal":
			result.append(String((record.get("payload", {}) as Dictionary).get(
				"treatment", "")))
	return result


func _normalized_actor_state(snapshot: Dictionary) -> Dictionary:
	return {
		"health_revision": int(snapshot.get("health_revision", -1)),
		"alive": bool(snapshot.get("alive", false)),
		"dead": bool(snapshot.get("dead", false)),
		"pain_micros": int(snapshot.get("pain_micros", -1)),
		"movement_scale_micros": int(snapshot.get("movement_scale_micros", -1)),
		"body_parts": (snapshot.get("body_parts", []) as Array).duplicate(true),
	}


func _normalized_event_trace(authority: RaidAuthority) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in authority.journal.records():
		var record := value as Dictionary
		var payload := record.get("payload", {}) as Dictionary
		result.append({
			"kind": String(record.get("kind", "")),
			"tick": int(record.get("tick", -1)),
			"event_type": String(payload.get("event_type", "")),
			"body_zone": String(payload.get("body_zone", "")),
			"damage_milliunits": int(payload.get("damage_milliunits", 0)),
			"applied_damage_micros": int(payload.get("applied_damage_micros", 0)),
		})
	return result


func _definition_quantity(owner: RaidInventoryOwner, definition: StringName) -> int:
	var result := 0
	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	if snapshot == null:
		return 0
	for value in snapshot.get_items():
		var item := value as Dictionary
		if StringName(item.get("item_definition_identifier", &"")) == definition:
			result += int(item.get("quantity", 0))
	return result


func _root_container(owner: RaidInventoryOwner, definition: StringName) -> int:
	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	if snapshot == null:
		return 0
	for value in snapshot.get_containers():
		var container := value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get(
					"container_definition_identifier", &"")) == definition:
			return int(container.get("id", 0))
	return 0


func _spatial(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container,
		"x": x, "y": y, "rotated": false}


func _cleanup_fixture(fixture: Dictionary) -> void:
	var adapter := fixture["adapter"] as HealthConsequenceAdapter
	if adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.BOUND \
			or adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.INVALIDATED \
			or adapter.lifecycle == HealthConsequenceAdapter.Lifecycle.RECOVERY_REQUIRED:
		adapter.release_binding(&"test_release")
	var authority := fixture["authority"] as RaidAuthority
	if authority.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		authority.teardown(int(fixture["generation"]))
	var component := fixture["component"] as GameplayAbilityComponent
	if component != null and is_instance_valid(component):
		if not component.is_torn_down():
			component.queue_teardown(component.get_current_tick())
		component.queue_free()
	var identity := fixture.get("inventory_identity") as OfflineInventoryIdentity
	if identity != null:
		identity.release()
	var owner := fixture.get("inventory_owner") as RaidInventoryOwner
	if owner != null and is_instance_valid(owner):
		if owner.lifecycle != RaidInventoryOwner.Lifecycle.TORN_DOWN:
			owner.teardown(owner.generation())
		owner.queue_free()
	var reload_node := fixture.get("reload_node") as InventoryWeaponAdapter
	if reload_node != null and is_instance_valid(reload_node):
		reload_node.queue_free()
	_fixtures.erase(fixture)
