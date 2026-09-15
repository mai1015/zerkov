extends SceneTree
## PR #2 regressions. Real game code; explicitly named test doubles for ports.
const F = preload("res://tests/ai/fixtures/ai_test_fixtures.gd")
var checks: int = 0
var failures: int = 0

class FaultWorld extends F.WorldDouble:
	var bad_self: bool = false
	func self_state(generation: int, tick: int, id: String) -> Dictionary:
		return {} if bad_self else super.self_state(generation, tick, id)

class IdleWorld extends F.WorldDouble:
	func patrol_points(_id: String) -> Array:
		return []

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("AI_REVIEW: " + message)

func run() -> void:
	_test_noise_window()
	_test_noise_long_run(2, 54_000)
	_test_noise_long_run(64, 300)
	_test_phase_gap()
	_test_capacity_preflight()
	_test_perception_snapshot()
	_test_profile_resources()
	_test_collection_fault_record()
	_test_runtime_noise_soak()
	_test_action_timeout()
	_test_retreat_latch()
	_test_idle_and_stop()
	_test_idle_roster()
	print("AI_REVIEW_RESULT checks=", checks, " failures=", failures,
		" noise_long_ticks=54000 noise_long_events=108000 noise_peak_events_per_tick=64")
	quit(0 if failures == 0 else 1)

func _record(noise: RaidNoiseService, tick: int, index: int = 0, position: Vector2i = Vector2i.ZERO) -> bool:
	return noise.record_committed(1, "zerkov.consequence.review.n%d_%d" % [tick, index],
		F.PLAYER, tick, position, &"gunshot", 1000)

func _listeners() -> Array:
	return [{"entity_id": F.SCAV, "position_raw": Vector2i.ZERO, "minimum_strength_milli": 1}]

func _test_noise_window() -> void:
	var noise := RaidNoiseService.new()
	check(noise.configure("zerkov.raid.review.window", 1, 2, 1, 4, 1), "one resolved-tick retry window")
	check(_record(noise, 1) and _record(noise, 1, 1), "fill current tick")
	check(_record(noise, 1), "exact pending retry is idempotent")
	check(not _record(noise, 1, 0, Vector2i(1, 0)) and noise.last_error == &"noise_event_identity_conflict", "pending conflict rejected")
	check(not _record(noise, 1, 2) and noise.last_error == &"noise_tick_capacity_exhausted", "per-tick bound still enforced")
	check(noise.resolve_tick(1, 1, _listeners()), "publish first frame")
	check(noise.observations_for(1, F.SCAV, 2).size() == 2, "exactly two audible facts")
	check(_record(noise, 1) and noise.diagnostics().pending_events == 0, "resolved retry never re-emits")
	check(not _record(noise, 1, 0, Vector2i(1, 0)), "resolved conflict still detected")
	check(_record(noise, 2) and _record(noise, 2, 1), "full next tick fits beside history")
	var before := noise.diagnostics()
	check(not noise.resolve_tick(1, 2, [null]), "malformed listener rejects resolve")
	check(noise.diagnostics() == before, "failed resolve does not evict history or consume tick")
	check(noise.resolve_tick(1, 2, _listeners()), "retry valid resolve")
	check(noise.diagnostics().history_events == 2 and noise.diagnostics().oldest_retry_tick == 2, "only active window retained")
	check(not _record(noise, 1) and noise.last_error == &"noise_event_tick_invalid", "expired retry rejected after eviction")
	check(_record(noise, 2), "window lower boundary still deduplicates")
	check(not _record(noise, 4), "future event rejected")
	check(noise.resolve_tick(1, 3, _listeners()), "quiet tick advances pruning")
	check(noise.diagnostics().history_events == 0 and noise.observations_for(1, F.SCAV, 4).is_empty(), "quiet frame expires ledger without replay")
	check(not _record(noise, 2), "quiet eviction still rejects stale event")
	check(noise.release(1) and noise.diagnostics().history_events == 0, "release clears retained history")
	var short := RaidNoiseService.new()
	check(not short.configure("zerkov.raid.review.short", 1, 2, 1, 2, 1), "explicit window must reserve worst-case capacity")
	check(short.configure("zerkov.raid.review.short", 1, 2, 1, 2), "small history chooses safe zero resolved-tick window")
	check(short.diagnostics().retry_window_ticks == 0, "effective window disclosed")
	for tick: int in range(1, 10):
		check(_record(short, tick) and _record(short, tick, 1) and short.resolve_tick(1, tick, []), "tiny history never exhausts over time")
	check(not _record(short, 9), "zero resolved-tick window rejects resolved retry")

func _test_noise_long_run(rate: int, ticks: int) -> void:
	var noise := RaidNoiseService.new()
	check(noise.configure("zerkov.raid.review.longrun", 1), "long-run noise configured")
	var accepted: int = 0
	var bounded: bool = true
	for tick: int in range(1, ticks + 1):
		for index: int in range(rate):
			if not _record(noise, tick, index):
				check(false, "long-run admission at tick %d after %d events: %s" % [tick, accepted, noise.last_error])
				return
			accepted += 1
		if not noise.resolve_tick(1, tick, _listeners()):
			check(false, "long-run resolve failed")
			return
		var diagnostics := noise.diagnostics()
		bounded = bounded and diagnostics.history_events <= diagnostics.retry_window_ticks * rate \
			and diagnostics.history_events <= diagnostics.history_limit \
			and noise.observations_for(1, F.SCAV, tick + 1).size() == rate
	check(accepted == rate * ticks and accepted > RaidNoiseService.MAX_EVENT_HISTORY, "events exceed old lifetime ceiling")
	check(bounded, "long run retains bounded fingerprints and exact once-per-tick observations")
	check(noise.diagnostics().history_events == noise.diagnostics().retry_window_ticks * rate, "steady-state history plateaus")

func _runtime(world: RaidAIWorldPort, registry: RaidVisionActorRegistry) -> RaidAIRuntime:
	var runtime := RaidAIRuntime.new()
	check(registry.configure(1), "runtime registry configured")
	check(runtime.configure("zerkov.raid.review.runtime", 1, 17, world, registry, ZAIProfile.scav(), ZAIProfile.mutant()), "runtime configured")
	return runtime

func _first_tick(runtime: RaidAIRuntime, registry: RaidVisionActorRegistry, native: F.VisionDouble) -> void:
	check(runtime.stage_after_movement(1, 1) and registry.apply_staged(native, 1, 1) \
		and registry.collect_projections(native, 1, 1) and runtime.decide(1, 1) \
		and runtime.resolve_noise(1, 1), "initial integrated pure tick")

func _test_phase_gap() -> void:
	var world := FaultWorld.new()
	world.actors = [F.actor(F.SCAV)]
	var registry := RaidVisionActorRegistry.new()
	var runtime := _runtime(world, registry)
	var native := F.VisionDouble.new()
	_first_tick(runtime, registry, native)
	check(runtime.debug_snapshot().agents.size() == 1, "brain exists before omission")
	world.actors = []
	check(runtime.stage_after_movement(1, 2), "movement removes actor before decisions")
	var frame := runtime.debug_snapshot()
	check(frame.agents.is_empty() and frame.staged_tick == 2 and frame.tick == 1, "phase-gap snapshot skips orphaned brain and discloses both ticks")
	var overlay := ZAIDebugOverlay.new()
	check(overlay.publish(frame) and not overlay.summary().is_empty(), "overlay safe in phase gap")
	check(not runtime.decide(1, 2), "out-of-order decision fails without crashing diagnostics")
	check(runtime.debug_snapshot().agents.is_empty(), "diagnostics remain safe after rejected decide")
	check(runtime.release(1) and runtime.debug_snapshot().released, "release diagnostics safe")
	overlay.free()
	# A permanent self-state failure after staging must also leave readable output.
	world = FaultWorld.new()
	world.actors = [F.actor(F.SCAV)]
	registry = RaidVisionActorRegistry.new()
	runtime = _runtime(world, registry)
	native = F.VisionDouble.new()
	_first_tick(runtime, registry, native)
	world.actors = [F.actor(F.MUTANT, "mutant")]
	check(runtime.stage_after_movement(1, 2) and registry.apply_staged(native, 1, 2), "replacement staged")
	world.bad_self = true
	check(not runtime.decide(1, 2), "self-state failure reproduced")
	frame = runtime.debug_snapshot()
	check(frame.failed and frame.agents.size() == 1 and frame.agents[0].entity_id == F.MUTANT, "failed decision snapshot remains usable")
	check(runtime.release(1), "failed runtime cleanup")

func _test_capacity_preflight() -> void:
	var world := F.WorldDouble.new()
	for i: int in range(65):
		world.actors.append(F.actor("zerkov.entity.scav.n%d" % i))
	world.actors[64].alive = false
	var registry := RaidVisionActorRegistry.new()
	var runtime := _runtime(world, registry)
	check(not runtime.stage_after_movement(1, 1) and runtime.last_error == &"ai_agent_capacity", "64 alive plus retained dead exceeds runtime roster, not native observers")
	check(registry.diagnostics().staged_tick == 0 and registry.diagnostics().tick == 0 \
		and registry.diagnostics().identities == 0, "capacity rejection leaves registry unstaged")
	check(runtime.debug_snapshot().failed, "capacity failure still diagnosable")
	check(runtime.release(1), "capacity cleanup")

func _test_perception_snapshot() -> void:
	var scav := ZAIProfile.scav()
	scav.sight_range_raw = 9_000_000
	scav.cone_cos_million = 700_000
	scav.memory_ticks = 30
	var mutant := ZAIProfile.mutant()
	var expected := scav.perception_record()
	var registry := RaidVisionActorRegistry.new()
	check(registry.configure(1, scav, mutant), "custom perception profiles configured")
	var world := F.WorldDouble.new()
	world.actors = [F.actor(F.SCAV), F.actor(F.PLAYER, "player", Vector2i(4_000_000, 0))]
	var runtime := RaidAIRuntime.new()
	check(runtime.configure("zerkov.raid.review.profile", 1, 17, world, registry, scav, mutant), "same perception profile admitted by runtime")
	scav.memory_ticks = 1
	scav.sight_range_raw = 1_000_000
	var wrong := RaidAIRuntime.new()
	check(not wrong.configure("zerkov.raid.review.wrong", 1, 17, world, registry, scav, mutant), "perception mismatch rejected at runtime configuration")
	var native := F.VisionDouble.new()
	check(runtime.stage_after_movement(1, 1) and registry.apply_staged(native, 1, 1), "native observer definitions materialized")
	var id := registry.native_id_for(1, F.SCAV)
	var target := registry.native_id_for(1, F.PLAYER)
	check(native.observers[id].range == expected.sight_range_raw \
		and native.observers[id].cone_cos_million == expected.cone_cos_million \
		and native.observers[id].memory_ticks == expected.memory_ticks, "native fields use configured snapshot, not magic numbers or mutable resource")
	native.projections[id] = F.native_projection(id, target, 1, 1, Vector2i(4_000_000, 0))
	check(registry.collect_projections(native, 1, 1) and runtime.decide(1, 1) \
		and runtime.resolve_noise(1, 1), "custom profile decision tick")
	var frame := runtime.debug_snapshot()
	check(frame.agents[0].perception == expected, "debug FOV uses same configured perception")
	var overlay := ZAIDebugOverlay.new()
	frame = frame.duplicate(true)
	frame.vision_budget = {"consumed": 3, "budget": 16384, "deferred": 0}
	check(overlay.publish(frame), "valid budget and profile published")
	var summary := overlay.summary()
	for invalid: Variant in [[], 1, "wrong", null, {"consumed": []}, {"budget": -1}]:
		var malformed := frame.duplicate(true)
		malformed.vision_budget = invalid
		check(not overlay.publish(malformed) and overlay.summary() == summary, "malformed vision budget rejected without corrupting last good frame")
	overlay.free()
	check(runtime.stage_after_movement(1, 2) and registry.apply_staged(native, 1, 2), "non-evaluation actor update retains projections")
	var retained := registry.projection_for(1, F.SCAV)
	check(retained.is_read_only() and retained.records.is_read_only() \
		and retained.records[0].is_read_only() and retained.records[0].last_known_position.is_read_only(), "retained projections remain recursively read-only between collect calls")
	var copy := retained.duplicate(true)
	copy.records[0].last_known_position.x = 999
	check(registry.projection_for(1, F.SCAV).records[0].last_known_position.x == 4_000_000, "detached copy cannot mutate registry")
	var adapter := VisionAIAdapter.new()
	check(adapter.configure(1, F.SCAV, id), "profile expiry adapter configured")
	check(not adapter.consume(1, 31, retained, registry, scav).ok, "adapter rejects independently changed perception settings")
	var fixed := ZAIProfile.scav()
	fixed.memory_ticks = expected.memory_ticks
	fixed.sight_range_raw = expected.sight_range_raw
	fixed.cone_cos_million = expected.cone_cos_million
	check(adapter.consume(1, 31, retained, registry, fixed).facts.size() == 1, "memory inclusive lower expiry boundary")
	check(adapter.consume(1, 32, retained, registry, fixed).facts.is_empty(), "same configured memory expires in adapter")
	check(runtime.release(1), "custom profile cleanup")

func _visible(tick: int) -> Dictionary:
	return F.knowledge(F.SCAV, tick, [F.fact(F.PLAYER, tick, Vector2i(2_000_000, 0))])

func _action(result: Dictionary, kind: StringName) -> Dictionary:
	for action: Dictionary in result.get("actions", []):
		if action.kind == kind:
			return action
	return {}

func _test_action_timeout() -> void:
	var profile := ZAIProfile.scav()
	profile.reaction_ticks = 1
	profile.attack_request_interval_ticks = 1
	profile.retry_ticks = 1
	profile.path_timeout_ticks = 2
	profile.action_timeout_ticks = 9
	var ai := ZAIAgent.new()
	check(ai.configure(1, F.SCAV, profile, 17), "independent timeout agent")
	ai.step(1, 1, F.own(), _visible(1))
	check(not _action(ai.step(1, 2, F.own(), _visible(2)), &"fire").is_empty(), "shot submitted")
	check(_action(ai.step(1, 5, F.own(), _visible(5)), &"fire").is_empty() \
		and ai.debug_snapshot().last_rejection != &"action_receipt_timeout", "path deadline does not expire action receipt")
	check(_action(ai.step(1, 12, F.own(), _visible(12)), &"fire").is_empty() \
		and ai.debug_snapshot().last_rejection == &"action_receipt_timeout", "independent action deadline expires and backs off")
	check(not _action(ai.step(1, 13, F.own(), _visible(13)), &"fire").is_empty(), "action retry uses retry policy")
	profile.action_timeout_ticks = 0
	check(not profile.is_valid(), "zero action timeout rejected")

func _test_retreat_latch() -> void:
	var profile := ZAIProfile.scav()
	profile.retreat_ticks = 2
	profile.search_ticks = 20
	var ai := ZAIAgent.new()
	check(ai.configure(1, F.SCAV, profile, 17, [], [Vector2i(-4_000_000, 0)]), "retreat agent")
	var own := F.own()
	own.health_milli = 100
	check(ai.step(1, 1, own, _visible(1)).state == "retreat", "low health enters retreat")
	ai.step(1, 2, own, F.knowledge(F.SCAV, 2))
	check(ai.step(1, 3, own, F.knowledge(F.SCAV, 3)).state == "search", "retreat timeout exits once")
	for tick: int in range(4, 9):
		check(ai.step(1, tick, own, F.knowledge(F.SCAV, tick)).state == "search" \
			and ai.debug_snapshot().since_tick == 3, "persistent injury does not restart retreat/search cycle")
	own.health_milli = 300
	ai.step(1, 9, own, F.knowledge(F.SCAV, 9))
	own.health_milli = 100
	check(ai.step(1, 10, own, _visible(10)).state != "retreat", "partial healing below recovery threshold does not re-arm")
	own.health_milli = 400
	ai.step(1, 11, own, _visible(11))
	own.health_milli = 100
	check(ai.step(1, 12, own, _visible(12)).state == "retreat", "new injury after recovery can retreat again")

func _test_idle_and_stop() -> void:
	var idle := ZAIAgent.new()
	check(idle.configure(1, F.SCAV, ZAIProfile.scav(), 17), "idle agent")
	for tick: int in range(1, 101):
		check(idle.step(1, tick, F.own(), F.knowledge(F.SCAV, tick)).actions.is_empty(), "idle produces no zero-move spam")
	var moving := ZAIAgent.new()
	check(moving.configure(1, F.SCAV, ZAIProfile.scav(), 17, [Vector2i(4_000_000, 0)]), "moving agent")
	var own := F.own()
	var initial := moving.step(1, 1, own, F.knowledge(F.SCAV, 1))
	check(_action(initial, &"move").is_empty(), "awaiting initial path needs no redundant stop")
	var path := {"request_id": initial.path_request.request_id, "generation": 1, "actor_id": F.SCAV,
		"resolved_tick": 2, "navigation_revision": 1, "ok": true, "points": [Vector2i(4_000_000, 0)]}
	check(_action(moving.step(1, 2, own, F.knowledge(F.SCAV, 2), [], path), &"move").payload.direction_milli != Vector2i.ZERO, "motion still emitted")
	own.can_move = false
	var stop := _action(moving.step(1, 3, own, F.knowledge(F.SCAV, 3)), &"move")
	check(not stop.is_empty() and stop.payload.direction_milli == Vector2i.ZERO, "one explicit stop after motion")
	var rejected := {"request_id": stop.request_id, "generation": 1, "actor_id": F.SCAV, "resolved_tick": 3, "accepted": false}
	check(not _action(moving.step(1, 4, own, F.knowledge(F.SCAV, 4), [], {}, [rejected]), &"move").is_empty(), "rejected stop retried")
	check(_action(moving.step(1, 5, own, F.knowledge(F.SCAV, 5)), &"move").is_empty(), "stationary state suppresses repeated stops")

func _test_idle_roster() -> void:
	var world := IdleWorld.new()
	for i: int in range(64):
		world.actors.append(F.actor("zerkov.entity.scav.idle%d" % i))
	var registry := RaidVisionActorRegistry.new()
	var runtime := _runtime(world, registry)
	_first_tick(runtime, registry, F.VisionDouble.new())
	check(world.actions.is_empty() and runtime.debug_snapshot().budget.actions == 0, "64 idle NPCs produce zero action requests")
	check(runtime.release(1), "idle roster cleanup")


func _test_profile_resources() -> void:
	for archetype: String in ["scav", "mutant"]:
		var profile := load("res://game/ai/profiles/" + archetype + ".tres") as ZAIProfile
		var expected := ZAIProfile.scav() if archetype == "scav" else ZAIProfile.mutant()
		check(profile != null and profile.is_valid(), "authored profile loads: " + archetype)
		check(profile.perception_record() == expected.perception_record(), "authored and factory perception agree: " + archetype)


func _test_collection_fault_record() -> void:
	var registry := RaidVisionActorRegistry.new()
	var native := F.VisionDouble.new()
	check(registry.configure(1), "collection-fault registry configures")
	check(registry.stage_frame(1, 1, [F.actor(F.SCAV)], 1, []), "collection fault staged")
	var staged: Dictionary = registry.get("_staged")
	staged.entities[F.SCAV].native_id = 0
	check(registry.apply_staged(native, 1, 1), "valid native commands apply despite injected retained lookup corruption")
	check(native.observers.size() == 1, "test corruption does not change native commands")
	check(not registry.collect_projections(native, 1, 1), "retained identity fault fails collection")
	check(registry.last_error == &"vision_projection_identity_invalid" and not registry.is_active(1), "collection failure is explicit and fail-stop")


func _test_runtime_noise_soak() -> void:
	var world := IdleWorld.new()
	world.actors = [F.actor(F.SCAV)]
	var registry := RaidVisionActorRegistry.new()
	var runtime := _runtime(world, registry)
	var native := F.VisionDouble.new()
	var completed := 0
	for tick: int in range(1, 5001):
		for event: int in range(2):
			world.noises.append({"event_id": "zerkov.consequence.runtime.t%d_e%d" % [tick, event],
				"source_id": F.PLAYER, "tick": tick, "position_raw": Vector2i(2_000_000, 0),
				"category": &"gunshot", "intensity_milli": 1000})
		if not runtime.stage_after_movement(1, tick) or not registry.apply_staged(native, 1, tick) \
			or not registry.collect_projections(native, 1, tick) or not runtime.decide(1, tick) \
			or not runtime.resolve_noise(1, tick):
			check(false, "runtime noise soak failed at tick %d: %s" % [tick, runtime.last_error])
			break
		completed = tick
		world.actions.clear()
		if tick in [4096, 4097, 5000]:
			var snapshot := runtime.debug_snapshot()
			check(not snapshot.failed and snapshot.noise.resolved_tick == tick, "runtime survives old lifetime exhaustion boundary")
			check(snapshot.noise.history_events <= 240, "runtime noise history remains tick-bounded")
	check(completed == 5000, "actual runtime processes 10000 committed events across all AI phases")
	check(runtime.release(1), "runtime soak teardown")
