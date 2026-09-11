extends SceneTree
## Task 5.4 focused permanent contract.
## Run with the repository-pinned Godot executable in headless mode only.

const BODY_LAYER: int = 1
const OBSTRUCTION_LAYER: int = 2

class FakeWeaponContext:
	extends WeaponInstanceContextAdapter

	var expected_authority: RaidAuthority
	var expected_weapon_authority: WeaponAuthority
	var expected_actor: ZEntityId
	var expected_generation: int = 1
	var records: Array[Dictionary] = []
	var authoritative_origin: Dictionary = {"x": 0, "y": 0}
	var authoritative_aim: Dictionary = {"x": 1_000_000, "y": 0}

	func authenticates_combat_binding(
		raid_authority: RaidAuthority,
		weapon_authority: WeaponAuthority,
		actor_id: ZEntityId,
		actor_source: ZRaidIntent.Source,
		expected_binding_generation: int
	) -> bool:
		return raid_authority == expected_authority \
			and weapon_authority == expected_weapon_authority \
			and actor_id != null and expected_actor != null \
			and actor_id.is_equal(expected_actor) \
			and int(actor_source) == int(ZRaidIntent.Source.PLAYER) \
			and expected_binding_generation == expected_generation

	func instance_records() -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for record in records:
			result.append(record.duplicate(true))
		return result

	func authority_context(weapon_id: String, tick: int) -> Dictionary:
		if records.is_empty() or String(records[0].get("weapon_id", "")) != weapon_id:
			return {"ok": false, "reason": &"weapon_instance_not_owned"}
		return {
			"ok": true,
			"context": {
				"actor_live": true,
				"weapon_equipped": true,
				"weapon_usable": true,
				"authoritative_origin": authoritative_origin.duplicate(true),
				"authoritative_aim": authoritative_aim.duplicate(true),
				"spread_modifier_ppm": 1_000_000,
				"damage_modifier_ppm": 1_000_000,
				"range_modifier_ppm": 1_000_000,
				"noise_modifier_ppm": 1_000_000,
				"recoil_modifier_ppm": 1_000_000,
			},
			"tick": tick,
		}


class CollidingWeaponCombatAdapter:
	extends WeaponCombatAdapter

	func _stable_ids_for_shot(_shot_identity: String) -> Dictionary:
		var parts := PackedStringArray(["weapon_shot", "forced", "collision"])
		return {
			"event_id": ZConsequenceId.from_parts(parts).canonical_key(),
			"request_id": ZRequestId.from_parts(parts).canonical_key(),
		}


class FullWeaponCombatAdapter:
	extends WeaponCombatAdapter

	func fill_resolved_ledger_for_test() -> void:
		for index in MAX_RESOLVED_SHOTS:
			_resolved_by_identity["seed-%04d" % index] = {
				"fingerprint": "seed", "result": {"accepted": true}}

	func fill_pending_queue_for_test() -> void:
		for index in MAX_PENDING_SHOTS:
			var identity := "seed-pending-%04d" % index
			_pending_order.append(identity)
			_pending_by_identity[identity] = {
				"fingerprint": "seed", "receipt": {"accepted": true}}


class FullHitboxWorld:
	extends BodyHitboxWorld2D

	func fill_query_ledger_for_test() -> void:
		for index in MAX_QUERY_RESULTS:
			_query_ledger["seed-%04d" % index] = {
				"fingerprint": "seed", "result": {"accepted": true}}


var checks: int = 0
var failures: int = 0
var _fixtures: Dictionary = {}


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("WEAPON_COMBAT_ADAPTER_CONTRACT: " + message)


func run() -> void:
	_test_hit_replay_and_reentry()
	_test_miss_and_occlusion()
	_test_binding_and_lifecycle_guards()
	_test_malformed_collision_and_capacity_fail_atomicity()
	print("WEAPON_COMBAT_ADAPTER_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_hit_replay_and_reentry() -> void:
	var fixture := _new_fixture("hit", &"hit")
	var adapter := fixture["adapter"] as WeaponCombatAdapter
	var publications: Array[Dictionary] = []
	var reentry_rejected := [false]
	adapter.consequence_committed.connect(func(value: Dictionary) -> void:
		publications.append(value)
		reentry_rejected[0] = not adapter.release_binding(&"reentrant_release") \
			and adapter.last_error == &"reentrant_binding_change"
	)
	check((fixture["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(fixture["generation"])),
		"hit authority activates")
	check((fixture["authority"] as RaidAuthority).advance_one(
		int(fixture["generation"])), "hit tick advances through phase 6")
	var result := adapter.last_result()
	check(bool(result.get("accepted", false)) \
		and result.get("outcome") == &"hit" \
		and bool(result.get("hit", false)) \
		and not bool(result.get("blocked", true)),
		"non-replayed native committed shot resolves to one hit")
	check(not StringName(result.get("body_zone", &"")).is_empty() \
		and not String(result.get("hitbox_id", "")).is_empty() \
		and String(result.get("entity_id", "")) \
			== (fixture["target"] as ZEntityId).canonical_key(),
		"hit retains the authoritative target, hitbox, and body-zone facts")
	check(String(result.get("resolution_digest", "")).length() == 64 \
		and String(result.get("world_resolution_digest", "")).length() == 64,
		"consequence and world resolutions have stable digests")
	check(adapter.ledger_size() == 1 and adapter.pending_count() == 0 \
		and publications.size() == 1,
		"one first-seen shot creates one ledger result and one publication")
	var metadata := (fixture["world"] as BodyHitboxWorld2D).snapshot_metadata(
		fixture["capability"])
	check(int(metadata.get("query_result_count", -1)) == 1 \
		and (fixture["authority"] as RaidAuthority).journal.size() == 1,
		"one first-seen shot performs one query and writes one audit input")
	check(result.is_read_only() \
		and (result.get("consumed_profile", {}) as Dictionary).is_read_only() \
		and publications[0].is_read_only(),
		"stored and emitted results are recursively read-only")
	check(bool(reentry_rejected[0]) and adapter.is_bound(),
		"synchronous publication callback cannot release the active binding")

	var first_copy := result.duplicate(true)
	first_copy["body_zone"] = &"forged"
	first_copy["resolution_digest"] = String("0").repeat(64)
	var args := fixture["fire_args"] as Array
	var replay_result := adapter.commit_fire(
		String(args[0]), int(args[1]), String(args[2]), int(args[3]),
		int(args[4]), int(args[5]))
	check(replay_result == result \
		and StringName(replay_result.get("body_zone", &"")) \
			!= StringName(first_copy.get("body_zone", &"")),
		"adapter-owned operation replay returns a detached original consequence")
	metadata = (fixture["world"] as BodyHitboxWorld2D).snapshot_metadata(
		fixture["capability"])
	check(publications.size() == 1 \
		and int(metadata.get("query_result_count", -1)) == 1 \
		and (fixture["authority"] as RaidAuthority).journal.size() == 1,
		"operation replay performs no native call, query, event, or emission")
	var divergent_replay := adapter.commit_fire(
		String(args[0]), int(args[1]), String(args[2]), int(args[3]),
		int(args[4]), int(args[5]) + 1)
	check(not bool(divergent_replay.get("accepted", true)) \
		and divergent_replay.get("reason") == &"weapon_command_identity_collision",
		"same adapter-owned command identity rejects divergent operation facts")
	check(_publication_counts(fixture) == Vector2i(1, 1),
		"divergent operation replay fails before native, query, or audit work")
	_cleanup_fixture(fixture)

	var queued_duplicates := _new_fixture(
		"queued_duplicates", &"miss", null, &"queued_duplicates")
	check((queued_duplicates["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(queued_duplicates["generation"])) \
		and (queued_duplicates["authority"] as RaidAuthority).advance_one(
			int(queued_duplicates["generation"])),
		"same-phase duplicate and replay do not fail the original shot")
	check((queued_duplicates["adapter"] as WeaponCombatAdapter).ledger_size() == 1 \
		and (queued_duplicates["publications"] as Array).size() == 1 \
		and _publication_counts(queued_duplicates) == Vector2i(1, 1),
		"queued non-replay duplicate and early replay resolve exactly once")
	_cleanup_fixture(queued_duplicates)


func _test_miss_and_occlusion() -> void:
	var clear := _new_fixture("clear_miss", &"miss")
	check((clear["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(clear["generation"])) \
		and (clear["authority"] as RaidAuthority).advance_one(
			int(clear["generation"])), "clear-miss tick advances")
	var clear_result := (clear["adapter"] as WeaponCombatAdapter).last_result()
	check(clear_result.get("outcome") == &"miss" \
		and clear_result.get("miss_reason") == &"clear" \
		and not bool(clear_result.get("hit", true)) \
		and not bool(clear_result.get("blocked", true)),
		"clear ray emits one explicit stable miss")
	_cleanup_fixture(clear)

	var blocked := _new_fixture("occluded", &"occluded")
	check((blocked["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(blocked["generation"])) \
		and (blocked["authority"] as RaidAuthority).advance_one(
			int(blocked["generation"])), "occluded tick advances")
	var blocked_result := (blocked["adapter"] as WeaponCombatAdapter).last_result()
	check(blocked_result.get("outcome") == &"miss" \
		and blocked_result.get("miss_reason") == &"occluded" \
		and bool(blocked_result.get("blocked", false)) \
		and String(blocked_result.get("obstruction_id", "")) \
			== "zerkov.obstruction.weapon_combat.occluder",
		"nearest obstruction deterministically becomes an occluded miss")
	check(String(blocked_result.get("entity_id", "")).is_empty() \
		and String(blocked_result.get("hitbox_id", "")).is_empty(),
		"occlusion does not leak the body candidate behind it")
	_cleanup_fixture(blocked)


func _test_binding_and_lifecycle_guards() -> void:
	var direct := _new_fixture("direct_phase", &"miss", null, &"direct_phase")
	var direct_adapter := direct["adapter"] as WeaponCombatAdapter
	check(not _object_exposes_reference(direct_adapter, direct["capability"]),
		"adapter property discovery exposes no raw hitbox bearer or wrapper")
	check((direct["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(direct["generation"])) \
		and (direct["authority"] as RaidAuthority).advance_one(
			int(direct["generation"])),
		"direct-call guard fixture advances through the registered phase 6")
	check(not bool(direct.get("direct_phase_result", true)) \
		and direct_adapter.ledger_size() == 1 \
		and _publication_counts(direct) == Vector2i(1, 1),
		"phase-5 direct resolver call fails before the one registered dispatch")
	_cleanup_fixture(direct)

	var fixture := _new_fixture("binding", &"miss")
	var authority := fixture["authority"] as RaidAuthority
	var foreign_actor := ZEntityId.from_parts(PackedStringArray(["weapon_combat", "foreign_owner"] ))
	check(authority.authorize_actor(
		foreign_actor, ZRaidIntent.Source.AI, int(fixture["generation"])),
		"foreign owner is independently authorized for the guard fixture")
	var foreign_world := BodyHitboxWorld2D.new()
	var foreign_capability := foreign_world.bind_raid_authority(
		authority, foreign_actor, ZRaidIntent.Source.AI, int(fixture["generation"]))
	var rejected := WeaponCombatAdapter.new()
	root.add_child(rejected)
	check(foreign_capability != null \
		and not rejected.bind_context(
			authority, fixture["weapon_authority"], fixture["weapon_context"],
			foreign_world, foreign_capability, Callable(self, "_unused_world_phase"),
			int(fixture["generation"]), 1,
			BODY_LAYER, OBSTRUCTION_LAYER) \
		and rejected.last_error == &"hitbox_binding_invalid",
		"wrong actor/source hitbox binding fails authentication")
	check(not rejected.bind_context(
		authority, fixture["weapon_authority"], fixture["weapon_context"],
		fixture["world"], fixture["capability"], Callable(self, "_unused_world_phase"),
		int(fixture["generation"]) + 1,
		1, BODY_LAYER, OBSTRUCTION_LAYER) \
		and rejected.last_error == &"raid_authority_invalid",
		"stale raid generation cannot bind")
	foreign_world.release_binding(foreign_capability, &"test_release")
	rejected.queue_free()

	var adapter := fixture["adapter"] as WeaponCombatAdapter
	var old_generation := adapter.binding_generation()
	check(adapter.release_binding(&"test_release") \
		and adapter.lifecycle == WeaponCombatAdapter.Lifecycle.RELEASED \
		and not authority.has_phase_handler(
			WeaponCombatAdapter.PHASE_HANDLER_ID, int(fixture["generation"])),
		"release disconnects and unregisters before dependency teardown")
	check(not adapter.commit_fire("released", 1, "released", 0, 1, 0).get(
		"accepted", true) \
		and adapter.last_error == &"combat_binding_invalidated",
		"released binding cannot expose a prior replay ledger")
	(fixture["world"] as BodyHitboxWorld2D).release_binding(
		fixture["capability"], &"test_release")
	authority.teardown(int(fixture["generation"]))
	fixture["weapon_context"].queue_free()
	fixture["weapon_authority"].queue_free()
	_fixtures.erase(String(fixture["label"]))

	var replacement := _new_fixture("replacement", &"miss", adapter)
	check(adapter.binding_generation() > old_generation and adapter.is_bound(),
		"released adapter rebinds only to the fresh exact dependency graph")
	_cleanup_fixture(replacement)


func _test_malformed_collision_and_capacity_fail_atomicity() -> void:
	var overflow := _new_fixture(
		"overflow_origin", &"miss", null, &"overflow_origin")
	check((overflow["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(overflow["generation"])) \
		and not (overflow["authority"] as RaidAuthority).advance_one(
			int(overflow["generation"])),
		"unscalable authoritative origin fail-stops before native arithmetic")
	check((overflow["adapter"] as WeaponCombatAdapter).last_error \
		== &"committed_shot_geometry_out_of_range" \
		and (overflow["adapter"] as WeaponCombatAdapter).pending_count() == 0 \
		and _publication_counts(overflow) == Vector2i(0, 0),
		"origin overflow fails before multiply, query, audit, or publication")
	_cleanup_fixture(overflow)

	var malformed := _new_fixture("malformed", &"miss", null, &"malformed")
	check((malformed["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(malformed["generation"])),
		"malformed authority activates")
	check((malformed["authority"] as RaidAuthority).advance_one(
		int(malformed["generation"])),
		"malformed public shot notification cannot affect the owned operation")
	check(_publication_counts(malformed) == Vector2i(1, 1) \
		and (malformed["adapter"] as WeaponCombatAdapter).ledger_size() == 1,
		"malformed signal DTO creates no additional consequence side effect")
	_cleanup_fixture(malformed)

	var external := _new_fixture(
		"external_native", &"miss", null, &"external_native")
	check((external["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(external["generation"])) \
		and (external["authority"] as RaidAuthority).advance_one(
			int(external["generation"])),
		"unowned direct native commit does not enter the combat adapter")
	check(bool((external["external_outcome"] as Dictionary).get("accepted", false)) \
		and (external["adapter"] as WeaponCombatAdapter).ledger_size() == 0 \
		and _publication_counts(external) == Vector2i(0, 0),
		"native signal is notification-only without adapter-owned operation")
	_cleanup_fixture(external)

	var identity_collision := _new_fixture(
		"identity_collision", &"miss", null, &"identity_collision")
	check((identity_collision["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(identity_collision["generation"])) \
		and (identity_collision["authority"] as RaidAuthority).advance_one(
			int(identity_collision["generation"])),
		"forged public committed-shot DTO is ignored during exact phase 5")
	check((identity_collision["adapter"] as WeaponCombatAdapter).ledger_size() == 1 \
		and _publication_counts(identity_collision) == Vector2i(1, 1),
		"forged signal cannot create a second query, audit, or result")
	_cleanup_fixture(identity_collision)

	var stale := _new_fixture("stale_shot", &"miss", null, &"stale_tick")
	check((stale["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(stale["generation"])) \
		and (stale["authority"] as RaidAuthority).advance_one(
			int(stale["generation"])),
		"stale second operation is rejected without harming the valid commit")
	check(not bool((stale["injected_receipt"] as Dictionary).get("accepted", true)) \
		and (stale["injected_receipt"] as Dictionary).get("reason") \
			== &"weapon_commit_phase_invalid" \
		and _publication_counts(stale) == Vector2i(1, 1),
		"stale operation fails before native mutation or extra consequence")
	_cleanup_fixture(stale)

	var colliding_adapter := CollidingWeaponCombatAdapter.new()
	var id_collision := _new_fixture(
		"derived_collision", &"miss", colliding_adapter)
	check((id_collision["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(id_collision["generation"])) \
		and (id_collision["authority"] as RaidAuthority).advance_one(
			int(id_collision["generation"])),
		"first forced-ID shot resolves normally")
	id_collision["skip_fire_until"] = 10
	for _index in 8:
		check((id_collision["authority"] as RaidAuthority).advance_one(
			int(id_collision["generation"])),
			"collision fixture advances through deterministic cadence")
	check(not (id_collision["authority"] as RaidAuthority).advance_one(
		int(id_collision["generation"])),
		"second mechanically committed shot detects the derived ID collision")
	check((id_collision["adapter"] as WeaponCombatAdapter).last_error \
		== &"consequence_id_collision" \
		and _publication_counts(id_collision) == Vector2i(1, 1),
		"collision adds no second query, audit, or publication")
	_cleanup_fixture(id_collision)

	var pending_adapter := FullWeaponCombatAdapter.new()
	var pending_full := _new_fixture(
		"pending_full", &"miss", pending_adapter, &"pending_capacity")
	pending_adapter.fill_pending_queue_for_test()
	check((pending_full["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(pending_full["generation"])) \
		and not (pending_full["authority"] as RaidAuthority).advance_one(
			int(pending_full["generation"])),
		"sixty-fifth pending shot fails the bounded queue")
	check(pending_adapter.last_error \
		== &"pending_shot_capacity_exceeded" \
		and pending_adapter.pending_count() \
			== WeaponCombatAdapter.MAX_PENDING_SHOTS \
		and _publication_counts(pending_full) == Vector2i(0, 0),
		"pending capacity fails before any query or audit publication")
	_cleanup_fixture(pending_full)

	var full_adapter := FullWeaponCombatAdapter.new()
	var ledger_full := _new_fixture("ledger_full", &"miss", full_adapter)
	full_adapter.fill_resolved_ledger_for_test()
	check((ledger_full["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(ledger_full["generation"])) \
		and not (ledger_full["authority"] as RaidAuthority).advance_one(
			int(ledger_full["generation"])),
		"resolved-shot ledger saturation fails the tick")
	check(full_adapter.last_error == &"shot_ledger_capacity_exceeded" \
		and full_adapter.ledger_size() == WeaponCombatAdapter.MAX_RESOLVED_SHOTS \
		and _publication_counts(ledger_full) == Vector2i(0, 0),
		"resolved-shot ledger capacity fails before query or audit publication")
	_cleanup_fixture(ledger_full)

	var full_world := FullHitboxWorld.new()
	var query_full := _new_fixture(
		"query_full", &"miss", null, &"", full_world)
	full_world.fill_query_ledger_for_test()
	check((query_full["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(query_full["generation"])) \
		and not (query_full["authority"] as RaidAuthority).advance_one(
			int(query_full["generation"])),
		"hitbox-query ledger saturation fails the tick")
	check((query_full["adapter"] as WeaponCombatAdapter).last_error \
		== &"hitbox_query_capacity_exceeded" \
		and int(full_world.snapshot_metadata(query_full["capability"]).get(
			"query_result_count", -1)) == BodyHitboxWorld2D.MAX_QUERY_RESULTS \
		and (query_full["authority"] as RaidAuthority).journal.size() == 0,
		"hitbox-query ledger capacity fails before query or audit publication")
	_cleanup_fixture(query_full)

	var journal_full := _new_fixture("journal_full", &"miss")
	var replacement_journal := RaidEventJournal.new()
	check(replacement_journal.configure(
		ZRaidId.parse(String(journal_full["raid_id"])), 1),
		"bounded journal replacement configures")
	check(replacement_journal.append(
		ZRaidEvent.EventKind.SPAWN,
		ZConsequenceId.from_parts(PackedStringArray(["weapon_combat", "prefill"])),
		0, (journal_full["admission"] as ZSessionAdmission).actor_id, {}),
		"bounded journal is filled before the shot")
	(journal_full["authority"] as RaidAuthority).journal = replacement_journal
	check((journal_full["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(journal_full["generation"])) \
		and not (journal_full["authority"] as RaidAuthority).advance_one(
			int(journal_full["generation"])),
		"journal saturation fails the world-consequence phase")
	check((journal_full["adapter"] as WeaponCombatAdapter).last_error \
		== &"journal_full" \
		and int(((journal_full["world"] as BodyHitboxWorld2D).snapshot_metadata(
			journal_full["capability"])).get("query_result_count", -1)) == 0 \
		and replacement_journal.size() == 1,
		"journal capacity is preflighted before the spatial query")
	_cleanup_fixture(journal_full)

	var journal_collision := _new_fixture("journal_collision", &"miss")
	var collision_identity := "weapon-combat-journal_collision-1:shot"
	var collision_adapter := journal_collision["adapter"] as WeaponCombatAdapter
	var collision_ids := collision_adapter._stable_ids_for_shot(collision_identity)
	check((journal_collision["authority"] as RaidAuthority).journal.append(
		ZRaidEvent.EventKind.SPAWN,
		ZConsequenceId.parse(String(collision_ids.get("event_id", ""))),
		0, (journal_collision["admission"] as ZSessionAdmission).actor_id, {}),
		"journal collision fixture preclaims the derived consequence ID")
	check((journal_collision["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(journal_collision["generation"])) \
		and not (journal_collision["authority"] as RaidAuthority).advance_one(
			int(journal_collision["generation"])),
		"preexisting audit consequence identity fails the shot tick")
	check((journal_collision["adapter"] as WeaponCombatAdapter).last_error \
		== &"duplicate_event" \
		and int(((journal_collision["world"] as BodyHitboxWorld2D).snapshot_metadata(
			journal_collision["capability"])).get("query_result_count", -1)) == 0 \
		and (journal_collision["authority"] as RaidAuthority).journal.size() == 1,
		"journal consequence-ID collision fails before the spatial query")
	_cleanup_fixture(journal_collision)


func _new_fixture(
	label: String,
	mode: StringName,
	adapter_value: WeaponCombatAdapter = null,
	injection: StringName = &"",
	world_value: BodyHitboxWorld2D = null
) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["weapon_combat", label]))
	var admission := SessionCoordinator.new().open_offline(
		raid_id, StringName("weapon_combat_" + label), &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 54), "%s authority configures" % label)
	var generation := authority.generation()
	var target := ZEntityId.from_parts(PackedStringArray(["weapon_combat", label, "target"] ))
	check(authority.authorize_actor(target, ZRaidIntent.Source.AI, generation),
		"%s target actor is authorized" % label)

	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(
		weapon_authority).get("ok", false)), "%s weapon content configures" % label)
	var identities := EquippedItemReconciler.derive_identity_keys(
		admission, 1, 1, 1, ZerkovInventoryCatalog.ITEM_AKM)
	var weapon_id := String(identities.get("weapon_id", ""))
	check(not weapon_id.is_empty(), "%s stable weapon identity derives" % label)
	check(bool(weapon_authority.create_weapon(
		weapon_id, String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION, ZerkovCombatContent.AKM_CAPACITY,
		{"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION},
		raid_id.canonical_key(), admission.authority_epoch).get("ok", false)),
		"%s loaded AKM instance creates" % label)
	var weapon_context := FakeWeaponContext.new()
	weapon_context.expected_authority = authority
	weapon_context.expected_weapon_authority = weapon_authority
	weapon_context.expected_actor = admission.actor_id
	weapon_context.records = [{
		"weapon_id": weapon_id,
		"entity_id": String(identities.get("entity_id", "")),
		"weapon_binding_generation": 1,
		"equipped": true,
		"parked": false,
	}]
	if injection == &"overflow_origin":
		weapon_context.authoritative_origin = {
			"x": WeaponCombatAdapter.MAX_COMMAND_COUNTER, "y": 0}
	root.add_child(weapon_context)

	var world := world_value if world_value != null else BodyHitboxWorld2D.new()
	var capability := world.bind_raid_authority(
		authority, admission.actor_id, ZRaidIntent.Source.PLAYER, generation)
	check(capability != null, "%s hitbox world binds" % label)
	var provenance := world.binding_provenance(capability)
	var fixture := {
		"label": label,
		"mode": mode,
		"injection": injection,
		"raid_id": raid_id.canonical_key(),
		"admission": admission,
		"authority": authority,
		"generation": generation,
		"target": target,
		"weapon_authority": weapon_authority,
		"weapon_context": weapon_context,
		"weapon_id": weapon_id,
		"world": world,
		"capability": capability,
		"token": int(provenance.get("binding_token", 0)),
		"publications": [],
		"fire_args": [],
		"fire_receipt": {},
		"injected_receipt": {},
		"external_outcome": {},
		"skip_fire_until": 0,
	}
	_fixtures[label] = fixture
	check(_publish_world_snapshot(fixture, 0, 1),
		"%s initial hitbox snapshot publishes" % label)
	var adapter := adapter_value if adapter_value != null else WeaponCombatAdapter.new()
	if adapter.get_parent() == null:
		root.add_child(adapter)
	fixture["adapter"] = adapter
	adapter.consequence_committed.connect(func(value: Dictionary) -> void:
		(fixture["publications"] as Array).append(value)
	)
	check(adapter.bind_context(
		authority, weapon_authority, weapon_context, world, capability,
		Callable(self, "_resolve_world_phase").bind(label),
		generation, weapon_context.expected_generation,
		BODY_LAYER, OBSTRUCTION_LAYER), "%s combat adapter binds" % label)
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		StringName("world_" + label),
		Callable(self, "_publish_world_phase").bind(label), generation),
		"%s world publisher registers" % label)
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		StringName("fire_" + label),
		Callable(self, "_fire_phase").bind(label), generation,
		WeaponInstanceContextAdapter.CONSUMER_PHASE_PRIORITY),
		"%s fire producer registers" % label)
	return fixture


func _publish_world_phase(
	_authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent],
	label: String
) -> bool:
	return _publish_world_snapshot(_fixtures[label] as Dictionary, tick, tick + 1)


func _resolve_world_phase(
	authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent],
	label: String
) -> bool:
	var fixture := _fixtures[label] as Dictionary
	return (fixture["adapter"] as WeaponCombatAdapter).resolve_world_consequences(
		fixture["capability"], authority, phase, tick,
		(fixture["adapter"] as WeaponCombatAdapter).binding_generation())


func _unused_world_phase(
	_authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	_tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	return true


func _publish_world_snapshot(fixture: Dictionary, tick: int, revision: int) -> bool:
	var bodies: Array = []
	var obstructions: Array = []
	if fixture["mode"] == &"hit" or fixture["mode"] == &"occluded":
		bodies.append({
			"entity_id": (fixture["target"] as ZEntityId).canonical_key(),
			"actor_source": int(ZRaidIntent.Source.AI),
			"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1),
			"body_revision": revision,
			"origin_raw": Vector2i(5_000_000, 0),
			"facing_quarter_turns": 0,
			"collision_layer": BODY_LAYER,
			"targetable": true,
		})
	if fixture["mode"] == &"occluded":
		obstructions.append({
			"obstruction_id": "zerkov.obstruction.weapon_combat.occluder",
			"geometry_revision": revision,
			# The left arm begins at x=4_480_000.  The obstruction begins on
			# the exact same ray fraction; BodyHitboxWorld2D's stable policy
			# gives the boundary tie to obstruction.
			"min_raw": Vector2i(4_480_000, -1_000_000),
			"max_raw": Vector2i(4_580_000, 1_000_000),
			"collision_layer": OBSTRUCTION_LAYER,
			"enabled": true,
		})
	var admission := fixture["admission"] as ZSessionAdmission
	return (fixture["world"] as BodyHitboxWorld2D).publish_snapshot(
		tick, revision, bodies, obstructions,
		int(fixture["generation"]), int(fixture["token"]),
		admission.actor_id, ZRaidIntent.Source.PLAYER, fixture["capability"])


func _fire_phase(
	_authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent],
	label: String
) -> bool:
	var fixture := _fixtures[label] as Dictionary
	if tick < int(fixture.get("skip_fire_until", 0)):
		return true
	var weapon_authority := fixture["weapon_authority"] as WeaponAuthority
	var adapter := fixture["adapter"] as WeaponCombatAdapter
	var weapon_id := String(fixture["weapon_id"])
	var native_state := weapon_authority.snapshot(weapon_id)
	var command_id := "weapon-combat-%s-%d" % [label, tick]
	var sequence := maxi(
		int(native_state.get("admitted_sequence_high_watermark", 0)),
		int(native_state.get("last_command_sequence", 0))) + 1
	var expected_revision := int(native_state.get("revision", -1))
	fixture["fire_args"] = [
		command_id, sequence, weapon_id, expected_revision, tick, 11]
	if fixture["injection"] == &"external_native":
		fixture["external_outcome"] = _native_fire_for_fixture(fixture)
		return bool((fixture["external_outcome"] as Dictionary).get(
			"accepted", false))
	var receipt := adapter.commit_fire(
		command_id, sequence, weapon_id, expected_revision, tick, 11)
	fixture["fire_receipt"] = receipt
	if not bool(receipt.get("accepted", false)):
		return false
	match StringName(fixture["injection"]):
		&"malformed":
			var malformed := {"accepted": true, "unexpected": true}
			weapon_authority.emit_signal("shot_committed", malformed)
		&"identity_collision":
			var divergent := _native_fire_for_fixture(fixture)
			divergent["replayed"] = false
			(divergent["shot"] as Dictionary)["consequence_id"] += "-forged"
			weapon_authority.emit_signal("shot_committed", divergent)
		&"stale_tick":
			var stale_receipt := adapter.commit_fire(
				command_id + "-stale", sequence + 1, weapon_id,
				int(weapon_authority.snapshot(weapon_id).get("revision", -1)),
				tick + 1, 11)
			fixture["injected_receipt"] = stale_receipt
		&"queued_duplicates":
			fixture["early_replay"] = adapter.commit_fire(
				command_id, sequence, weapon_id, expected_revision, tick, 11)
		&"direct_phase":
			fixture["direct_phase_result"] = adapter.resolve_world_consequences(
				fixture["capability"], _authority,
				RaidAuthority.TickPhase.WORLD_CONSEQUENCES, tick,
				adapter.binding_generation())
	return true


func _native_fire_for_fixture(fixture: Dictionary) -> Dictionary:
	var args := fixture["fire_args"] as Array
	var weapon_authority := fixture["weapon_authority"] as WeaponAuthority
	var weapon_context := fixture["weapon_context"] as FakeWeaponContext
	var context := (weapon_context.authority_context(
		String(args[2]), int(args[4]))["context"] as Dictionary).duplicate(true)
	return weapon_authority.fire({
		"command_id": String(args[0]),
		"sequence": int(args[1]),
		"instance_id": String(args[2]),
		"expected_revision": int(args[3]),
		"tick": int(args[4]),
		"authority_scope": String(fixture["raid_id"]),
		"authority_epoch": (fixture["admission"] as ZSessionAdmission).authority_epoch,
		"claimed_origin": (context["authoritative_origin"] as Dictionary).duplicate(true),
		"claimed_aim": (context["authoritative_aim"] as Dictionary).duplicate(true),
		"spread_seed": int(args[5]),
	}, context)


func _publication_counts(fixture: Dictionary) -> Vector2i:
	var metadata := (fixture["world"] as BodyHitboxWorld2D).snapshot_metadata(
		fixture["capability"])
	return Vector2i(
		int(metadata.get("query_result_count", -1)),
		(fixture["authority"] as RaidAuthority).journal.size())


func _object_exposes_reference(subject: Object, needle: Variant) -> bool:
	for property in subject.get_property_list():
		var property_name := StringName((property as Dictionary).get("name", &""))
		if property_name.is_empty():
			continue
		if _variant_contains_reference(subject.get(property_name), needle, 0):
			return true
	return false


func _variant_contains_reference(value: Variant, needle: Variant, depth: int) -> bool:
	if depth > 8:
		return false
	if typeof(value) == TYPE_OBJECT:
		return value == needle
	if typeof(value) == TYPE_CALLABLE:
		for argument in (value as Callable).get_bound_arguments():
			if _variant_contains_reference(argument, needle, depth + 1):
				return true
		return false
	if typeof(value) == TYPE_DICTIONARY:
		for child in (value as Dictionary).values():
			if _variant_contains_reference(child, needle, depth + 1):
				return true
		return false
	if typeof(value) == TYPE_ARRAY:
		for child in value as Array:
			if _variant_contains_reference(child, needle, depth + 1):
				return true
	return false


func _cleanup_fixture(fixture: Dictionary) -> void:
	var adapter := fixture["adapter"] as WeaponCombatAdapter
	if adapter.lifecycle == WeaponCombatAdapter.Lifecycle.BOUND \
			or adapter.lifecycle == WeaponCombatAdapter.Lifecycle.INVALIDATED:
		adapter.release_binding(&"test_release")
	var world := fixture["world"] as BodyHitboxWorld2D
	if not world.binding_provenance(fixture["capability"]).is_empty():
		world.release_binding(fixture["capability"], &"test_release")
	var authority := fixture["authority"] as RaidAuthority
	if authority.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		authority.teardown(int(fixture["generation"]))
	fixture["weapon_context"].queue_free()
	fixture["weapon_authority"].queue_free()
	adapter.queue_free()
	_fixtures.erase(String(fixture["label"]))
