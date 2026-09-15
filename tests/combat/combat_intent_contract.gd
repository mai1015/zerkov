extends SceneTree
## Real base-revision identity/envelope/queue and movement encoder. The sink
## below is a named test double for RaidAuthority's lifecycle API, not combat.

const SESSION := "zerkov.session.combat.one"
const ACTOR := "zerkov.entity.player.one"
const WEAPON := "zerkov.weapon.instance.akm"
const CODEC = preload("res://game/input/combat/combat_action_codec.gd")
var checks: int = 0
var failures: int = 0

class QueueSink extends ZCombatIntentSink:
	var queue := ZRaidIntentQueue.new()
	var ctx := {"session_id": SESSION, "actor_id": ACTOR, "source": 0,
		"authority_epoch": 1, "generation": 1, "current_tick": 0, "lifecycle": "active"}
	var hook: Callable
	var context_hook: Callable
	var malformed: bool = false
	var override_result: Dictionary = {}
	func context() -> Dictionary:
		if context_hook.is_valid():
			context_hook.call()
		return ctx.duplicate()
	func admit(intent: ZRaidIntent) -> Dictionary:
		if hook.is_valid():
			hook.call()
		var accepted := queue.admit(intent, ctx.current_tick, ZSessionId.parse(ctx.session_id),
			ZEntityId.parse(ctx.actor_id), ctx.authority_epoch, ctx.generation)
		if not override_result.is_empty():
			return override_result
		return {} if malformed else {"admitted": accepted, "reason": queue.last_error}

func _initialize() -> void:
	_test_codec()
	_test_encoder()
	_test_router()
	_test_capacity()
	_test_reentry_and_unknown()
	var a := _replay(false)
	var b := _replay(true)
	check(not a.is_empty() and a == b, "PLAYER/AI replay digest ignores queue arrival order")
	print("COMBAT_INTENT_RESULT checks=", checks, " failures=", failures,
		" replay_ticks=240 replay_runs=2 digest=", a)
	quit(0 if failures == 0 else 1)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("COMBAT_INTENT: " + message)

func _payload(action: StringName) -> Dictionary:
	match action:
		&"aim": return {"direction_milli": Vector2i(1000, 0), "aiming": true}
		&"fire": return {"weapon_id": WEAPON, "expected_weapon_revision": 0}
		&"reload": return {"weapon_id": WEAPON, "expected_weapon_revision": 0, "expected_inventory_revision": 0}
		&"cancel_reload": return {"weapon_id": WEAPON, "expected_weapon_revision": 0, "reservation_id": "zerkov.reservation.reload.one"}
		&"melee": return {"weapon_id": "zerkov.weapon.instance.machete", "expected_equipment_revision": 0}
	return {"body_zone": "left_arm", "treatment": "bandage", "expected_health_revision": 0, "expected_inventory_revision": 0}

func _encoder(actor: String = ACTOR, source: ZRaidIntent.Source = ZRaidIntent.Source.PLAYER,
	generation: int = 1, session: String = SESSION) -> ZCombatInputAdapter:
	var result := ZCombatInputAdapter.new()
	check(result.configure_source(ZSessionId.parse(session), ZEntityId.parse(actor), 1, generation, source), "encoder configured")
	return result

func _test_codec() -> void:
	for action: StringName in CODEC.ACTIONS:
		var good := _payload(action)
		check(CODEC.validate_payload(action, good).is_empty(), "valid " + action)
		check(CODEC.action_for_logical(StringName(CODEC.ACTION_PREFIX + action)) == action, "catalog logical ID " + action)
		check(CODEC.action_for_intent(StringName(CODEC.INTENT_PREFIX + action)) == action, "canonical intent kind " + action)
		var empty := good.duplicate(true)
		empty.erase(empty.keys()[0])
		check(not CODEC.validate_payload(action, empty).is_empty(), "missing field rejected " + action)
		for key in ["actor_id", "generation", "source", "damage", "hit_result", "spread_seed", "stamina_cost"]:
			var extra := good.duplicate(true)
			extra[key] = 1
			check(not CODEC.validate_payload(action, extra).is_empty(), "extra authority field rejected " + key)
		for key: String in good:
			var bad := good.duplicate(true)
			bad[key] = null
			check(not CODEC.validate_payload(action, bad).is_empty(), "null field rejected")
	var old_cancel := _payload(&"cancel_reload")
	old_cancel.erase("expected_weapon_revision")
	check(CODEC.validate_payload(&"cancel_reload", old_cancel) == &"combat_cancel_payload_invalid", "cancel requires weapon revision")
	var old_melee := {"weapon_id": "zerkov.weapon.instance.machete", "expected_inventory_revision": 17}
	check(CODEC.validate_payload(&"melee", old_melee) == &"combat_melee_payload_invalid", "inventory revision is not an equipment revision alias")
	for action: StringName in [&"cancel_reload", &"melee"]:
		var field := "expected_weapon_revision" if action == &"cancel_reload" else "expected_equipment_revision"
		for invalid: Variant in [true, -1, 2_147_483_648, 1.0, "1"]:
			var bad := _payload(action)
			bad[field] = invalid
			check(not CODEC.validate_payload(action, bad).is_empty(), "strict revision type and bounds " + action)
		var extra := _payload(action)
		extra["expected_inventory_revision"] = 17
		check(not CODEC.validate_payload(action, extra).is_empty(), "unrelated revision claim rejected " + action)
	check(CODEC.action_for_logical(&"common_ui/zerkov/gameplay/grenade").is_empty(), "unimplemented actions not silently routed")
	check(CODEC.action_for_logical(&"fire").is_empty(), "logical ID namespace required")
	check(not CODEC.validate_payload(&"fire", {"weapon_id": WEAPON, "expected_weapon_revision": true}).is_empty(), "bool is not a revision")
	check(not CODEC.validate_payload(&"fire", {"weapon_id": WEAPON, "expected_weapon_revision": -1}).is_empty(), "negative revision")
	check(not CODEC.validate_payload(&"fire", {"weapon_id": WEAPON, "expected_weapon_revision": 2_147_483_648}).is_empty(), "revision cap")
	for direction: Variant in [Vector2.ZERO, Vector2(INF, 0), Vector2i.ZERO, Vector2i(1001, 0), Vector2i(-2147483648, 0)]:
		check(not CODEC.validate_payload(&"aim", {"direction_milli": direction, "aiming": true}).is_empty(), "invalid direction")
	var release_aim := _payload(&"aim")
	release_aim.aiming = false
	check(CODEC.validate_payload(&"aim", release_aim).is_empty(), "aim release is explicit and valid")
	var cyclic: Dictionary = {}
	cyclic.self = cyclic
	check(not CODEC.validate_payload(&"fire", cyclic).is_empty(), "cyclic input bounded before deep copy")
	cyclic.clear()
	for zone: String in CODEC.BODY_ZONES:
		for treatment: String in ["bandage", "splint"]:
			var heal := _payload(&"quick_heal")
			heal.body_zone = zone
			heal.treatment = treatment
			check(CODEC.validate_payload(&"quick_heal", heal).is_empty(), "all explicit medical selections")
	for key: String in ["body_zone", "treatment"]:
		var bad := _payload(&"quick_heal")
		bad[key] = "invented"
		check(not CODEC.validate_payload(&"quick_heal", bad).is_empty(), "unknown medical selection")
	for id: Variant in ["", "bad", "zerkov.weapon.bad name", "a".repeat(129), "zerkov.weapon.a.\nb"]:
		check(not CODEC.validate_payload(&"fire", {"weapon_id": id, "expected_weapon_revision": 0}).is_empty(), "bad weapon identity")

func _test_encoder() -> void:
	var empty := ZCombatInputAdapter.new()
	check(empty.build_combat_intent(1, &"fire", _payload(&"fire")) == null, "unbound encoder")
	var session := ZSessionId.parse(SESSION)
	var actor := ZEntityId.parse(ACTOR)
	check(empty.configure(session, actor, 1, 1), "compatible base configure API")
	session.set("_value", &"zerkov.session.changed.one")
	actor.set("_value", &"zerkov.entity.changed.one")
	check(empty.binding_context().session_id == SESSION and empty.binding_context().actor_id == ACTOR, "binding copies input IDs")
	check(not empty.configure(ZSessionId.parse(SESSION), ZEntityId.parse(ACTOR), 1, 1), "cannot reset sequence in live generation")
	var move := empty.build_movement_intent(1, Vector2(1, 1), Vector2.RIGHT)
	var shot := empty.build_combat_intent(1, &"fire", _payload(&"fire"))
	var inherited := empty.build_movement_intent_from_actions(1, true, false, false, false)
	check(move.sequence == 1 and shot.sequence == 2 and inherited.sequence == 3, "movement and combat share allocator including inherited helpers")
	check(move.request_id.canonical_key() != shot.request_id.canonical_key(), "cross-kind request identities distinct")
	check(UIIntentAdapter.validate_movement_payload(move.payload).is_empty(), "unchanged task-3 movement schema")
	var original := UIIntentAdapter.create_movement_intent(move.request_id, move.session_id, move.actor_id,
		1, 1, 1, 1, Vector2(1, 1), Vector2.RIGHT)
	check(move.canonical_record() == original.canonical_record(), "movement semantics equal task-3 base encoder")
	var payload := _payload(&"reload")
	var captured := empty.build_combat_intent(1, &"reload", payload)
	payload.expected_inventory_revision = 1234
	check(captured.payload.expected_inventory_revision == 0, "payload snapshot detached")
	check(empty.build_combat_intent(1, &"fire", {}) == null, "malformed input rejected before sequence allocation")
	check(empty.build_combat_intent(1, &"fire", _payload(&"fire")).sequence == 5, "invalid payload consumes no ID")
	check(empty.build_combat_intent(0, &"fire", _payload(&"fire")) == null, "zero target tick")
	var other := _encoder(ACTOR, ZRaidIntent.Source.PLAYER, 2)
	check(other.build_combat_intent(1, &"fire", _payload(&"fire")).request_id.canonical_key() != move.request_id.canonical_key(), "generation scopes identity at equal sequence")
	var other_session := _encoder(ACTOR, ZRaidIntent.Source.PLAYER, 1, "zerkov.session.combat.two")
	check(other_session.build_movement_intent(1, Vector2.RIGHT).request_id.canonical_key() != move.request_id.canonical_key(), "session scopes identity")
	var other_actor := _encoder("zerkov.entity.player.two")
	check(other_actor.build_movement_intent(1, Vector2.RIGHT).request_id.canonical_key() != move.request_id.canonical_key(), "actor scopes identity at equal sequence")
	var other_source := _encoder(ACTOR, ZRaidIntent.Source.AI)
	check(other_source.build_movement_intent(1, Vector2.RIGHT).request_id.canonical_key() != move.request_id.canonical_key(), "source scopes identity at equal sequence")
	var other_epoch := ZCombatInputAdapter.new()
	check(other_epoch.configure(ZSessionId.parse(SESSION), ZEntityId.parse(ACTOR), 2, 1), "epoch fixture configures")
	check(other_epoch.build_movement_intent(1, Vector2.RIGHT).request_id.canonical_key() != move.request_id.canonical_key(), "epoch scopes identity at equal sequence")
	var ai := _encoder("zerkov.entity.scav.one", ZRaidIntent.Source.AI)
	check(ai.build_movement_intent(1, Vector2.RIGHT).source == ZRaidIntent.Source.AI, "AI movement source preserved")
	check(ai.build_combat_intent(1, &"fire", _payload(&"fire")).source == ZRaidIntent.Source.AI, "AI uses same combat schema")
	var capped := _encoder()
	capped.set("_next_sequence", 2_147_483_646)
	check(capped.build_combat_intent(1, &"fire", _payload(&"fire")).sequence == 2_147_483_647, "last sequence accepted")
	check(capped.build_combat_intent(1, &"fire", _payload(&"fire")) == null, "combat fails closed at exhaustion")
	check(capped.build_movement_intent(1, Vector2.RIGHT) == null, "inherited movement also bounded")
	empty.release()
	check(empty.build_movement_intent(1, Vector2.RIGHT) == null and not empty.is_configured(), "released encoder inert")
	check(not empty.configure(ZSessionId.parse(SESSION), ZEntityId.parse(ACTOR), 1, 2), "fresh owner required on replacement")

func _test_router() -> void:
	var sink := QueueSink.new()
	var encoder := _encoder()
	var router := ZCombatActionRouter.new()
	check(not router.bind(encoder, ZCombatIntentSink.new()), "unbound sink cannot masquerade as authority")
	check(router.bind(encoder, sink), "retry valid binding")
	for action: StringName in CODEC.ACTIONS:
		var result := router.submit_logical(StringName(CODEC.ACTION_PREFIX + action), _payload(action), 1, 1)
		check(result.admitted and result.committed == false and result.is_read_only(), "logical action admitted, NOT committed " + action)
	check(router.submit_movement(1, 1, Vector2.RIGHT).admitted, "movement interoperates with all combat actions")
	var intents := sink.queue.drain_tick(1)
	check(intents.size() == 7, "six combat actions and one movement in REAL queue")
	for index: int in range(intents.size()):
		check(intents[index].sequence == index + 1, "canonical sequence")
		if index < 6:
			check(CODEC.validate_intent(intents[index]).is_empty(), "consumer can revalidate encoded schema")
	check(not router.submit_logical(&"common_ui/zerkov/gameplay/fire_mode", {}, 1, 1).admitted, "unsupported logical action")
	for phase: String in ["preparing", "settling", "completed", "failed", "torn_down"]:
		sink.ctx.lifecycle = phase
		check(not router.submit_action(&"fire", _payload(&"fire"), 1, 1).admitted, "closed lifecycle " + phase)
	sink.ctx.lifecycle = "extracting"
	check(router.submit_action(&"fire", _payload(&"fire"), 1, 1).admitted, "extracting accepts intent like authority")
	check(not router.submit_action(&"fire", _payload(&"fire"), 1, 2).admitted, "late callback captured stale generation")
	for target in [0, 2, 601, 2_147_483_648]:
		check(not router.submit_action(&"fire", _payload(&"fire"), target, 1).admitted, "router only next tick")
	for key: String in ["session_id", "actor_id", "source", "authority_epoch", "generation"]:
		var old: Variant = sink.ctx[key]
		sink.ctx[key] = old + 1 if old is int else String(old) + ".changed"
		check(not router.submit_action(&"fire", _payload(&"fire"), 1, 1).admitted, "binding divergence " + key)
		sink.ctx[key] = old
	var explicit := ZRequestId.from_parts(PackedStringArray(["combat_test", "same"]))
	check(router.submit_action(&"fire", _payload(&"fire"), 1, 1, explicit).admitted, "first stable producer request")
	var repeated := router.submit_action(&"fire", _payload(&"fire"), 1, 1, explicit)
	check(not repeated.admitted and repeated.reason == &"duplicate_request", "same producer request cannot execute twice")
	check(router.release(), "release router")
	check(not router.submit_movement(1, 1, Vector2.RIGHT).admitted, "released route")
	check(not router.bind(encoder, sink), "router cannot silently rebind")

func _test_capacity() -> void:
	var sink := QueueSink.new()
	var router := ZCombatActionRouter.new()
	check(router.bind(_encoder(), sink), "capacity router")
	for index: int in range(ZRaidIntentQueue.MAX_QUEUED_INTENTS):
		var result := router.submit_action(&"fire", _payload(&"fire"), 1, 1)
		if not result.admitted:
			check(false, "unexpected early queue full at " + str(index))
	check(sink.queue.size() == 1024, "real queue maximum")
	var full := router.submit_action(&"fire", _payload(&"fire"), 1, 1)
	check(not full.admitted and full.reason == &"intent_queue_full", "queue capacity reported")
	check(sink.queue.drain_tick(1).size() == 1024, "no accepted input lost")
	sink.ctx.current_tick = 1
	var next := router.submit_action(&"fire", _payload(&"fire"), 2, 1)
	check(next.admitted and next.sequence == 1026, "failed enqueue does not recycle sequence")

func _test_reentry_and_unknown() -> void:
	var sink := QueueSink.new()
	var router := ZCombatActionRouter.new()
	check(router.bind(_encoder(), sink), "reentry router")
	# Weak capture avoids constructing a test-only reference cycle.
	var weak_router: WeakRef = weakref(router)
	var nested: Array = []
	sink.hook = func() -> void:
		var target: ZCombatActionRouter = weak_router.get_ref()
		nested.append(target.submit_action(&"fire", _payload(&"fire"), 1, 1))
		nested.append(target.release())
	check(router.submit_action(&"fire", _payload(&"fire"), 1, 1).admitted, "outer enqueue succeeds")
	check(nested.size() == 2 and not nested[0].admitted and nested[0].reason == &"combat_router_reentrant" and nested[1] == false,
		"sink callback cannot recurse or release in-flight router")
	check(sink.queue.size() == 1 and router.last_error.is_empty(), "reentrant rejection did not hide outer success")
	sink.hook = Callable()
	sink.context_hook = func() -> void:
		var target: ZCombatActionRouter = weak_router.get_ref()
		nested.append(target.submit_action(&"fire", _payload(&"fire"), 1, 1))
	check(router.submit_action(&"fire", _payload(&"fire"), 1, 1).admitted, "context read fenced against reentry")
	check(not nested[-1].admitted and sink.queue.size() == 2, "context callback adds no nested input")
	sink.context_hook = Callable()
	sink.malformed = true
	var ambiguous := router.submit_action(&"fire", _payload(&"fire"), 1, 1)
	check(ambiguous.admitted == null and ambiguous.outcome_unknown and sink.queue.size() == 3,
		"post-enqueue malformed result is unknown, not false non-admission")
	check(not router.submit_action(&"fire", _payload(&"fire"), 1, 1).admitted, "unknown result stops subsequent requests")

	for contradictory: Dictionary in [
		{"admitted": true, "reason": "also_rejected"},
		{"admitted": false, "reason": ""},
		{"admitted": false, "reason": "x".repeat(257)},
	]:
		var wrong_sink := QueueSink.new()
		var wrong_router := ZCombatActionRouter.new()
		check(wrong_router.bind(_encoder(), wrong_sink), "malformed-admission router")
		wrong_sink.override_result = contradictory
		var wrong := wrong_router.submit_action(&"fire", _payload(&"fire"), 1, 1)
		check(wrong.admitted == null and wrong.outcome_unknown and wrong_sink.queue.size() == 1,
			"contradictory/oversized admission result is unknown after actual enqueue")

func _replay(reverse_arrival: bool) -> String:
	var player := _encoder()
	var ai := _encoder("zerkov.entity.scav.one", ZRaidIntent.Source.AI)
	var queue := ZRaidIntentQueue.new()
	var digest := ""
	for tick: int in range(1, 241):
		var commands: Array[ZRaidIntent] = []
		for encoder: ZCombatInputAdapter in [player, ai]:
			commands.append(encoder.build_movement_intent(tick, Vector2.RIGHT))
			commands.append(encoder.build_combat_intent(tick, &"aim", _payload(&"aim")))
			commands.append(encoder.build_combat_intent(tick, &"fire", _payload(&"fire")))
		if reverse_arrival:
			commands.reverse()
		for intent: ZRaidIntent in commands:
			check(queue.admit(intent, tick - 1, ZSessionId.parse(SESSION), intent.actor_id, 1, 1), "mixed source input admitted")
		var due := queue.drain_tick(tick)
		check(due.size() == 6, "all due input delivered once")
		for intent: ZRaidIntent in due:
			digest = (digest + ZCanonicalValue.encode(intent.canonical_record())).sha256_text()
	return digest
