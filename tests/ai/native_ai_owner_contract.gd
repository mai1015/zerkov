extends SceneTree
## Real RaidAuthority + exact Vision owner integration. The world/action port
## is a fixture, so this proves lifecycle/cadence/queue admission, not combat.

const F = preload("res://tests/ai/fixtures/ai_test_fixtures.gd")
var checks: int = 0
var failures: int = 0
var observed_intents: int = 0
var owner: Node
var runtime: RaidAIRuntime
var driver: RaidAIPhaseDriver
var registry: RaidVisionActorRegistry

class QueueWorld extends RaidAIWorldPort:
	var raid_ref: WeakRef
	var actors: Array = []
	func is_ready(generation: int) -> bool:
		return generation == 1
	func capture_vision_frame(_generation: int, _tick: int) -> Dictionary:
		return {"actors": actors.duplicate(true), "geometry_revision": 1, "segments": []}
	func self_state(_generation: int, _tick: int, id: String) -> Dictionary:
		for actor: Dictionary in actors:
			if actor.entity_id == id:
				return F.own(id, actor.position_raw)
		return {}
	var sequence: int = 0

	func submit_action_request(request: Dictionary) -> Dictionary:
		sequence += 1
		var raid: RefCounted = raid_ref.get_ref()
		var admission: RefCounted = raid.call("admission")
		var payload: Dictionary = {}
		if request.payload.has("direction_milli"):
			var direction: Vector2i = request.payload.direction_milli
			payload["direction_milli"] = {"x": direction.x, "y": direction.y}
		var request_type: Script = load("res://game/domain/z_request_id.gd")
		var intent_type: Script = load("res://game/domain/z_raid_intent.gd")
		var entity_type: Script = load("res://game/domain/z_entity_id.gd")
		var intent: RefCounted = intent_type.call("create", request_type.call("from_parts", PackedStringArray(["ai_native_test", str(sequence)])),
			1, admission.session_id, entity_type.call("parse", request.actor_id),
			admission.authority_epoch, admission.generation, request.target_tick, sequence, request.kind, payload)
		# Deliberately no committed receipt or fake damage: enqueue is admission.
		return {"admitted": raid.call("enqueue_intent", intent, admission.generation), "reason": raid.last_error}


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("NATIVE_AI_OWNER: " + message)


func run() -> void:
	if not ClassDB.class_exists("CommonVisionWorld2D"):
		print("NATIVE_AI_OWNER_BLOCKED missing_CommonVisionWorld2D")
		quit(2)
		return
	var raid_type: Script = load("res://game/raid/raid_authority.gd")
	var raid_id_type: Script = load("res://game/domain/z_raid_id.gd")
	var entity_type: Script = load("res://game/domain/z_entity_id.gd")
	var coordinator_type: Script = load("res://game/bootstrap/session_coordinator.gd")
	var phases: Dictionary = raid_type.get_script_constant_map()["TickPhase"]
	check(phases.MOVEMENT == 1 and phases.AI_DECISIONS == 3 and phases.TASKS_AND_AUDIT == 7, "phase enum matches driver")
	var raid_id: RefCounted = raid_id_type.call("parse", "zerkov.raid.ai.native_owner")
	var coordinator: RefCounted = coordinator_type.new()
	var admission: RefCounted = coordinator.call("open_offline", raid_id, &"ai_native_profile", &"player")
	var raid: RefCounted = raid_type.new()
	check(raid.call("configure", raid_id, admission, 17), "real raid configured")
	var generation: int = raid.call("generation")
	check(generation == 1, "fixture expects initial generation")
	check(raid.call("authorize_actor", entity_type.call("parse", F.SCAV), 1, generation), "AI actor authorized normally")
	var world := QueueWorld.new()
	world.raid_ref = weakref(raid)
	world.actors = [F.actor(F.SCAV), F.actor(admission.actor_id.canonical_key(), "player", Vector2i(4_000_000, 0))]
	registry = RaidVisionActorRegistry.new()
	check(registry.configure(generation), "registry configured")
	owner = load("res://game/ai/vision/raid_vision_world_owner.gd").new() as Node
	root.add_child(owner)
	if not owner.configure(9602, {}, registry, generation):
		check(false, "pinned native owner startup: " + String(owner.last_error))
		owner.queue_free()
		quit(1)
		return
	check(owner.register_with_raid_authority(raid), "exact owner claims reserved slot")
	runtime = RaidAIRuntime.new()
	check(runtime.configure(raid_id.canonical_key(), generation, 17, world, registry, ZAIProfile.scav(), ZAIProfile.mutant()), "AI runtime bound")
	check(raid.call("register_phase_handler", 1, &"native_ai_movement", _movement, generation), "movement fixture named callback")
	check(raid.call("register_phase_handler", 4, &"native_ai_intents", _inspect_intents, generation), "intent observer registered")
	driver = RaidAIPhaseDriver.new()
	check(driver.bind(raid, generation, runtime, &"native_ai_movement"), "phase driver bound")
	check(raid.call("transition", 1, generation), "raid active")
	for tick: int in range(1, 11):
		check(raid.call("advance_one", generation), "real authority tick " + str(tick) + ": " + String(raid.last_error))
		if failures > 0: break
	check(owner.telemetry_snapshot().evaluation_ticks == 4, "native evaluation only at 1/4/7/10")
	check(registry.diagnostics().tick == 10, "actor updates at all ten authority ticks")
	check(observed_intents > 0, "real authority queue admits next-tick AI requests")
	check(not driver._decisions(raid, 3, 11, []), "out-of-phase callback rejected")
	check(driver.release(generation), "remove AI callbacks before Vision teardown")
	check(owner.teardown(owner.generation()), "native Vision teardown")
	check(not registry.is_active(generation), "owner disposal invalidates retained registry")
	check(raid.call("teardown", generation), "raid teardown")
	owner.queue_free()
	print("NATIVE_AI_OWNER_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _movement(_raid: RefCounted, _phase: int, _tick: int, _intents: Array) -> bool:
	return true  # Authored stationary fixture, not task-3 movement.


func _inspect_intents(_raid: RefCounted, _phase: int, tick: int, intents: Array) -> bool:
	for intent in intents:
		check(intent.source == 1 and intent.target_tick == tick, "real admitted AI envelope")
		observed_intents += 1
	return true
