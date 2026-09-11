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
	var replay := (fixture["weapon_authority"] as WeaponAuthority).fire(
		fixture["fire_command"], fixture["fire_context"])
	check(bool(replay.get("accepted", false)) and bool(replay.get("replayed", false)),
		"native WeaponAuthority returns the original fire receipt as replay")
	var replay_result := adapter.replay_committed_shot(replay)
	check(replay_result == result \
		and StringName(replay_result.get("body_zone", &"")) \
			!= StringName(first_copy.get("body_zone", &"")),
		"replay returns a detached original consequence")
	metadata = (fixture["world"] as BodyHitboxWorld2D).snapshot_metadata(
		fixture["capability"])
	check(publications.size() == 1 \
		and int(metadata.get("query_result_count", -1)) == 1 \
		and (fixture["authority"] as RaidAuthority).journal.size() == 1,
		"replay performs no second query, event, or consequence emission")
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
			foreign_world, foreign_capability, int(fixture["generation"]), 1,
			BODY_LAYER, OBSTRUCTION_LAYER) \
		and rejected.last_error == &"hitbox_binding_invalid",
		"wrong actor/source hitbox binding fails authentication")
	check(not rejected.bind_context(
		authority, fixture["weapon_authority"], fixture["weapon_context"],
		fixture["world"], fixture["capability"], int(fixture["generation"]) + 1,
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
	check(not adapter.replay_committed_shot({}).get("accepted", true) \
		and adapter.last_error == &"combat_binding_stale",
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
	var malformed := _new_fixture("malformed", &"miss", null, &"malformed")
	check((malformed["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(malformed["generation"])),
		"malformed authority activates")
	check(not (malformed["authority"] as RaidAuthority).advance_one(
		int(malformed["generation"])) \
		and (malformed["authority"] as RaidAuthority).lifecycle \
			== RaidAuthority.Lifecycle.FAILED,
		"malformed committed-shot callback fails the raid tick closed")
	check(_publication_counts(malformed) == Vector2i(0, 0),
		"malformed input fails before query or audit publication")
	_cleanup_fixture(malformed)

	var identity_collision := _new_fixture(
		"identity_collision", &"miss", null, &"identity_collision")
	check((identity_collision["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(identity_collision["generation"])) \
		and not (identity_collision["authority"] as RaidAuthority).advance_one(
			int(identity_collision["generation"])),
		"same shot identity with divergent facts fails the tick")
	check((identity_collision["adapter"] as WeaponCombatAdapter).last_error \
		== &"shot_identity_collision" \
		and _publication_counts(identity_collision) == Vector2i(0, 0),
		"shot identity collision fails before query or audit publication")
	_cleanup_fixture(identity_collision)

	var stale := _new_fixture("stale_shot", &"miss", null, &"stale_tick")
	check((stale["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(stale["generation"])) \
		and not (stale["authority"] as RaidAuthority).advance_one(
			int(stale["generation"])),
		"stale committed-shot tick fails the authority tick")
	check((stale["adapter"] as WeaponCombatAdapter).last_error \
		== &"committed_shot_phase_invalid" \
		and _publication_counts(stale) == Vector2i(0, 0),
		"stale shot facts fail before query or audit publication")
	_cleanup_fixture(stale)

	var colliding_adapter := CollidingWeaponCombatAdapter.new()
	var id_collision := _new_fixture(
		"derived_collision", &"miss", colliding_adapter, &"derived_collision")
	check((id_collision["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(id_collision["generation"])) \
		and not (id_collision["authority"] as RaidAuthority).advance_one(
			int(id_collision["generation"])),
		"derived consequence-ID collision fails the tick")
	check((id_collision["adapter"] as WeaponCombatAdapter).last_error \
		== &"consequence_id_collision" \
		and _publication_counts(id_collision) == Vector2i(0, 0),
		"consequence-ID collision reserves no query or audit side effect")
	_cleanup_fixture(id_collision)

	var pending_full := _new_fixture(
		"pending_full", &"miss", null, &"pending_capacity")
	check((pending_full["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(pending_full["generation"])) \
		and not (pending_full["authority"] as RaidAuthority).advance_one(
			int(pending_full["generation"])),
		"sixty-fifth pending shot fails the bounded queue")
	check((pending_full["adapter"] as WeaponCombatAdapter).last_error \
		== &"pending_shot_capacity_exceeded" \
		and (pending_full["adapter"] as WeaponCombatAdapter).pending_count() \
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
		"fire_command": {},
		"fire_context": {},
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
	var weapon_authority := fixture["weapon_authority"] as WeaponAuthority
	var weapon_id := String(fixture["weapon_id"])
	var native_state := weapon_authority.snapshot(weapon_id)
	var context := {
		"actor_live": true,
		"weapon_equipped": true,
		"weapon_usable": true,
		"authoritative_origin": {"x": 0, "y": 0},
		"authoritative_aim": {"x": 1_000_000, "y": 0},
		"spread_modifier_ppm": 1_000_000,
		"damage_modifier_ppm": 1_000_000,
		"range_modifier_ppm": 1_000_000,
		"noise_modifier_ppm": 1_000_000,
		"recoil_modifier_ppm": 1_000_000,
	}
	var command := {
		"command_id": "weapon-combat-%s-%d" % [label, tick],
		"sequence": 1,
		"instance_id": weapon_id,
		"expected_revision": int(native_state.get("revision", -1)),
		"tick": tick,
		"authority_scope": String(fixture["raid_id"]),
		"authority_epoch": (fixture["admission"] as ZSessionAdmission).authority_epoch,
		"claimed_origin": {"x": 0, "y": 0},
		"claimed_aim": {"x": 1_000_000, "y": 0},
		"spread_seed": 11,
	}
	fixture["fire_command"] = command
	fixture["fire_context"] = context
	var outcome := weapon_authority.fire(command, context)
	if not bool(outcome.get("accepted", false)):
		return false
	match StringName(fixture["injection"]):
		&"malformed":
			var malformed := outcome.duplicate(true)
			malformed["unexpected"] = true
			weapon_authority.emit_signal("shot_committed", malformed)
		&"identity_collision":
			var divergent := outcome.duplicate(true)
			(divergent["shot"] as Dictionary)["damage_milliunits"] = \
				int((divergent["shot"] as Dictionary)["damage_milliunits"]) + 1
			weapon_authority.emit_signal("shot_committed", divergent)
		&"stale_tick":
			var stale := outcome.duplicate(true)
			(stale["shot"] as Dictionary)["tick"] = tick + 1
			(stale["shot"] as Dictionary)["consequence_id"] += "-stale"
			weapon_authority.emit_signal("shot_committed", stale)
		&"derived_collision":
			var colliding := outcome.duplicate(true)
			(colliding["shot"] as Dictionary)["consequence_id"] += "-other"
			weapon_authority.emit_signal("shot_committed", colliding)
		&"pending_capacity":
			for index in WeaponCombatAdapter.MAX_PENDING_SHOTS:
				var extra := outcome.duplicate(true)
				(extra["shot"] as Dictionary)["consequence_id"] += "-%03d" % index
				weapon_authority.emit_signal("shot_committed", extra)
		&"queued_duplicates":
			weapon_authority.emit_signal("shot_committed", outcome.duplicate(true))
			var early_replay := outcome.duplicate(true)
			early_replay["replayed"] = true
			weapon_authority.emit_signal("shot_committed", early_replay)
	return true


func _publication_counts(fixture: Dictionary) -> Vector2i:
	var metadata := (fixture["world"] as BodyHitboxWorld2D).snapshot_metadata(
		fixture["capability"])
	return Vector2i(
		int(metadata.get("query_result_count", -1)),
		(fixture["authority"] as RaidAuthority).journal.size())


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
