extends SceneTree
## Real RaidAuthority queue/lifecycle test. Consumes envelopes, not weapons or
## health effects. No fixture is represented as a committed shot/heal/melee hit.

var checks: int = 0
var failures: int = 0
var delivered: Array[Dictionary] = []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("NATIVE_COMBAT_INTENT: " + message)

func run() -> void:
	for name: String in ["CommonVisionWorld2D", "WeaponAuthority", "GameplayAbilityComponent"]:
		if not ClassDB.class_exists(name):
			print("NATIVE_COMBAT_INTENT_BLOCKED missing_", name)
			quit(2)
			return
	var coordinator: RefCounted = load("res://game/bootstrap/session_coordinator.gd").new()
	var raid_id: RefCounted = load("res://game/domain/z_raid_id.gd").call("parse", "zerkov.raid.combat.input")
	var admission: RefCounted = coordinator.call("open_offline", raid_id, &"combat_native", &"player")
	var raid: RefCounted = load("res://game/raid/raid_authority.gd").new()
	check(raid.call("configure", raid_id, admission, 17), "real authority configured")
	var generation: int = raid.call("generation")
	var npc := ZEntityId.from_parts(PackedStringArray(["combat_native", "scav"]))
	check(raid.call("authorize_actor", npc, ZRaidIntent.Source.AI, generation), "AI authorization during PREPARING")
	check(raid.call("register_phase_handler", 4, &"combat_input_probe", _collect, generation), "real named phase registration")
	var encoder := ZCombatInputAdapter.new()
	check(encoder.configure(admission.session_id, admission.actor_id, admission.authority_epoch, generation), "player encoder")
	var sink: ZCombatIntentSink = load("res://game/input/combat/raid_combat_intent_sink.gd").new()
	check(sink.call("bind", raid, admission.actor_id, ZRaidIntent.Source.PLAYER, generation), "concrete sink bound")
	var router := ZCombatActionRouter.new()
	check(router.bind(encoder, sink), "router bound")
	var payload := {"weapon_id": "zerkov.weapon.instance.akm", "expected_weapon_revision": 0}
	check(not router.submit_action(&"fire", payload, 1, generation).admitted, "no input while PREPARING")
	check(raid.call("transition", 1, generation), "real authority active")
	var catalog: Script = load("res://game/input/zerkov_input_actions.gd")
	var names := catalog.get_script_constant_map()
	for action: StringName in ZCombatActionCodec.ACTIONS:
		check(ZCombatActionCodec.action_for_logical(names["GAME_" + String(action).to_upper()]) == action,
			"logical ID matches actual CommonUI catalog")
	var expected_actions: Array[Dictionary] = [
		{"kind": &"aim", "payload": {"direction_milli": Vector2i(1000, 0), "aiming": true}},
		{"kind": &"fire", "payload": payload},
		{"kind": &"reload", "payload": {"weapon_id": payload.weapon_id, "expected_weapon_revision": 0, "expected_inventory_revision": 0}},
		{"kind": &"cancel_reload", "payload": {"weapon_id": payload.weapon_id, "expected_weapon_revision": 0, "reservation_id": "zerkov.reservation.reload.one"}},
		{"kind": &"melee", "payload": {"weapon_id": "zerkov.weapon.instance.machete", "expected_equipment_revision": 0}},
		{"kind": &"quick_heal", "payload": {"body_zone": "thorax", "treatment": "bandage", "expected_health_revision": 0, "expected_inventory_revision": 0}},
	]
	for row: Dictionary in expected_actions:
		var receipt := router.submit_logical(names["GAME_" + String(row.kind).to_upper()], row.payload, 1, generation)
		check(receipt.admitted and not receipt.committed, "real combat envelope admission")
	check(router.submit_movement(1, generation, Vector2.RIGHT).admitted, "movement shares real actor queue")
	var ai_encoder := ZCombatInputAdapter.new()
	check(ai_encoder.configure_source(admission.session_id, npc, admission.authority_epoch, generation, ZRaidIntent.Source.AI), "AI encoder")
	var ai_sink: ZCombatIntentSink = load("res://game/input/combat/raid_combat_intent_sink.gd").new()
	check(ai_sink.call("bind", raid, npc, ZRaidIntent.Source.AI, generation), "AI sink authorization")
	var ai_router := ZCombatActionRouter.new()
	check(ai_router.bind(ai_encoder, ai_sink), "AI router")
	check(not ai_router.submit_logical(names.GAME_FIRE, payload, 1, generation).admitted, "UI entry cannot impersonate AI")
	check(ai_router.submit_action(&"fire", payload, 1, generation).admitted, "AI uses same combat schema")
	check(raid.call("advance_one", generation), "real authority delivers one canonical tick")
	check(delivered.size() == 8, "seven player plus one AI intents delivered")
	check(delivered[0].source == 0 and delivered[-1].source == 1, "deterministic source ordering")
	var replay := ZRequestId.from_parts(PackedStringArray(["combat_input", "duplicate"]))
	check(router.submit_action(&"fire", payload, 2, generation, replay).admitted, "new request")
	var duplicate := router.submit_action(&"fire", payload, 2, generation, replay)
	check(not duplicate.admitted and duplicate.reason == &"duplicate_request", "real authority deduplication")
	var unchecked := encoder.build_combat_intent(2, &"fire", payload)
	unchecked.payload["hit_result"] = true
	check(not sink.admit(unchecked).admitted, "concrete sink also enforces schema")
	check(raid.call("transition", 2, generation), "extraction countdown phase")
	check(router.submit_action(&"fire", payload, 2, generation).admitted, "extracting permits gameplay input")
	check(raid.call("advance_one", generation), "next real tick")
	check(delivered.size() == 10, "duplicate/malformed inputs did not enter real queue")
	check(raid.call("transition", 3, generation), "settling closes admission")
	check(not router.submit_action(&"fire", payload, 3, generation).admitted, "settling rejects input")
	check(raid.call("teardown", generation), "real teardown")
	check(not router.submit_action(&"fire", payload, 3, generation).admitted, "retained callback after teardown rejected")
	check(router.release() and ai_router.release(), "router cleanup")
	sink.call("release")
	ai_sink.call("release")
	print("NATIVE_COMBAT_INTENT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

func _collect(_raid: RefCounted, _phase: int, tick: int, intents: Array) -> bool:
	for value: ZRaidIntent in intents:
		check(value.target_tick == tick, "canonical tick alignment")
		if value.kind != UIIntentAdapter.INTENT_KIND_MOVEMENT:
			check(ZCombatActionCodec.validate_intent(value).is_empty(), "consumer sees valid combat schema")
		delivered.append(value.canonical_record())
	return true
