extends SceneTree
## Deterministic game-AI tests. VisionDouble checks the documented native API
## boundary, NOT the native LOS implementation. Run native_ai_vision_contract
## separately with the real Common Vision addon before marking 6.2 accepted.

const F = preload("res://tests/ai/fixtures/ai_test_fixtures.gd")
var checks: int = 0
var failures: int = 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("AI_WORKSTREAM: " + message)


func _initialize() -> void:
	_test_registry()
	_test_vision()
	_test_states()
	_test_navigation()
	_test_hearing()
	_test_bad_inputs()
	_test_phase_driver()
	_test_edge_receipts()
	var a := _run_many(false)
	var b := _run_many(true)
	check(not a.is_empty() and a == b, "64-agent replay ignores insertion order")
	print("AI_WORKSTREAM_RESULT checks=", checks, " failures=", failures,
		" replay_agents=64 replay_ticks=120 replay_runs=2 digest=", a)
	quit(0 if failures == 0 else 1)


func _registry() -> RaidVisionActorRegistry:
	var registry := RaidVisionActorRegistry.new()
	check(registry.configure(1), "registry configure")
	return registry


func _test_registry() -> void:
	var registry := _registry()
	var native := F.VisionDouble.new()
	var actors: Array = [F.actor(F.SCAV), F.actor(F.PLAYER, "player", Vector2i(2_000_000, 0))]
	check(registry.stage_frame(1, 1, actors, 1, []), "stage initial")
	check(native.calls.is_empty(), "staging does not call native mutation")
	check(registry.apply_staged(native, 1, 1), "apply registration")
	check(native.targets.size() == 2 and native.observers.size() == 1, "player target only; NPC target and observer")
	var scav_id := registry.native_id_for(1, F.SCAV)
	check(native.observers[scav_id].range == 18_000_000 and native.observers[scav_id].memory_ticks == 180, "sealed Scav perception values")
	check(not registry.stage_frame(2, 2, actors, 1, []), "stale generation")
	var bad := actors.duplicate(true)
	bad[0].position_raw.x += 10
	check(not registry.stage_frame(1, 2, bad, 1, []), "same revision changed position rejected")
	bad[0].revision = 3
	check(not registry.stage_frame(1, 2, bad, 1, []), "skipped source revision rejected")
	bad[0].revision = 2
	check(registry.stage_frame(1, 2, bad, 1, []), "exact source successor")
	check(registry.apply_staged(native, 1, 2), "native CAS successor")
	check(native.observers[scav_id].revision == 2, "native observer revision increments exactly")
	check(not registry.apply_staged(native, 1, 2), "frame cannot replay native mutation")
	bad[0].alive = false
	bad[0].revision = 3
	check(registry.stage_frame(1, 3, bad, 1, []) and registry.apply_staged(native, 1, 3), "death removes native registration")
	check(not native.targets.has(scav_id) and not native.observers.has(scav_id), "dead observer and target removed")
	bad[0].alive = true
	bad[0].revision = 4
	check(not registry.stage_frame(1, 4, bad, 1, []), "same identity cannot resurrect")
	check(registry.release(1), "release")
	check(registry.entity_for_native_id(1, scav_id).is_empty(), "released identity not observable")
	var failure := _registry()
	var broken := F.VisionDouble.new()
	broken.fail_method = &"register_observer"
	check(failure.stage_frame(1, 1, actors, 1, []), "partial failure staged")
	check(not failure.apply_staged(broken, 1, 1), "native partial failure surfaced")
	check(not failure.is_active(1), "partial failure quarantines registry")
	check(failure.projection_for(1, F.SCAV).is_empty(), "no publication after partial failure")
	var geometry := _registry()
	var segment := {"id": 1, "a": {"x": 0, "y": 0}, "b": {"x": 0, "y": 1000000}, "mask": 1, "two_sided": true}
	check(geometry.stage_frame(1, 1, actors, 1, [segment]), "explicit occluder accepted")
	var geometry_native := F.VisionDouble.new()
	check(geometry.apply_staged(geometry_native, 1, 1), "explicit occluder applied")
	check(geometry.stage_frame(1, 2, actors, 1, []),
		"unchanged geometry revision accepts an omitted payload")
	check(geometry.apply_staged(geometry_native, 1, 2),
		"omitted unchanged geometry performs no native replacement")
	segment.b.y = 2000000
	check(not geometry.stage_frame(1, 3, actors, 1, [segment]), "same geometry revision conflict")
	check(not _registry().stage_frame(1, 1, [actors[0], actors[0]], 1, []), "duplicate actor rejected")
	var extreme: Dictionary = F.actor(F.SCAV, "scav", Vector2i(0, ZAIValues.LIMIT))
	check(not _registry().stage_frame(1, 1, [extreme], 1, []), "sample sum overflow preflight")
	var corrupted := _registry()
	check(corrupted.stage_frame(1, 1, actors, 1, []), "corrupted-command probe staged")
	var staged: Dictionary = corrupted.get("_staged")
	staged.commands.append({"method": &"call_deferred", "args": ["free"]})
	check(not corrupted.apply_staged(F.VisionDouble.new(), 1, 1) and corrupted.last_error == &"vision_native_method_forbidden", "retained commands cannot invoke arbitrary native Object methods")
	check(ZAIValues.direction(Vector2i(-ZAIValues.LIMIT, 0), Vector2i(ZAIValues.LIMIT, 0)) == Vector2i(1000, 0), "direction uses 64-bit differences")
	check(not ZAIValues.within(Vector2i(-ZAIValues.LIMIT, 0), Vector2i(ZAIValues.LIMIT, 0), 18_000_000), "opposite extremes are not nearby")


func _test_vision() -> void:
	var registry := _registry()
	var native := F.VisionDouble.new()
	var actors: Array = [F.actor(F.SCAV), F.actor(F.PLAYER, "player", Vector2i(2_000_000, 0))]
	check(registry.stage_frame(1, 1, actors, 1, []) and registry.apply_staged(native, 1, 1), "vision fixture registered")
	var observer := registry.native_id_for(1, F.SCAV)
	var target := registry.native_id_for(1, F.PLAYER)
	var adapter := VisionAIAdapter.new()
	check(adapter.configure(1, F.SCAV, observer), "projection adapter bound to recipient")
	var projection := F.native_projection(observer, target, 1, 1, actors[1].position_raw)
	var view := adapter.consume(1, 1, projection, registry, ZAIProfile.scav())
	check(view.ok and view.facts.size() == 1 and view.facts[0].kind == &"visible", "current visible record")
	check(view.is_read_only() and view.facts.is_read_only() and view.facts[0].is_read_only(), "recursive read-only publication")
	var stale := adapter.consume(1, 4, projection, registry, ZAIProfile.scav())
	check(stale.ok and stale.facts[0].kind == &"remembered" and not stale.fresh, "deferred projection never stays live indefinitely")
	var remembered := F.native_projection(observer, target, 4, 2, Vector2i(2_000_000, 0), 1, 1)
	actors[1].position_raw = Vector2i(50_000_000, 10_000_000)
	actors[1].revision = 2
	check(registry.stage_frame(1, 2, actors, 1, []) and registry.apply_staged(native, 1, 2), "hidden target actually moved at world input")
	view = adapter.consume(1, 4, remembered, registry, ZAIProfile.scav())
	check(view.ok and view.facts[0].position_raw == Vector2i(2_000_000, 0), "occluded facts retain disclosed position, never look up live transform")
	check(not view.facts[0].has("health") and not view.facts[0].has("inventory"), "hidden attributes absent")
	var expired := adapter.consume(1, 182, remembered, registry, ZAIProfile.scav())
	check(expired.ok and expired.facts.is_empty(), "bounded memory expires on decision ticks even if native query deferred")
	var conflict := remembered.duplicate(true)
	conflict.records[0].last_known_position.x = 123
	check(not adapter.consume(1, 4, conflict, registry, ZAIProfile.scav()).ok, "same projection revision conflict")
	var unknown := F.native_projection(observer, target, 5, 3, Vector2i.ZERO, 0, 1)
	view = adapter.consume(1, 5, unknown, registry, ZAIProfile.scav())
	check(view.ok and view.facts.is_empty(), "removal/expiry terminal record yields no target data")
	unknown.result_revision = 4
	unknown.records[0].has_last_known_position = true
	check(not adapter.consume(1, 5, unknown, registry, ZAIProfile.scav()).ok, "unknown position smuggling rejected")
	check(not adapter.consume(2, 6, {}, registry, ZAIProfile.scav()).ok, "recipient generation checked")
	check(adapter.release(1) and not adapter.consume(1, 6, {}, registry, ZAIProfile.scav()).ok, "released adapter inert")


func _test_states() -> void:
	var profile := ZAIProfile.scav()
	profile.reaction_ticks = 3
	profile.attack_request_interval_ticks = 2
	profile.search_ticks = 6
	profile.retreat_ticks = 3
	profile.retry_ticks = 3
	var ai := ZAIAgent.new()
	check(ai.configure(1, F.SCAV, profile, 1, [Vector2i(4_000_000, 0)], [Vector2i(-2_000_000, 0)]), "Scav configured")
	var own := F.own()
	var result := ai.step(1, 1, own, F.knowledge(F.SCAV, 1))
	check(result.state == "patrol" and not result.path_request.is_empty(), "idle enters patrol with bounded path request")
	for tick: int in range(2, 5):
		result = ai.step(1, tick, own, F.knowledge(F.SCAV, tick, [F.fact(F.PLAYER, tick, Vector2i(2_000_000, 0))]))
		check(result.state == "engage" and not _has(result, &"fire"), "reaction delay before firing")
	result = ai.step(1, 5, own, F.knowledge(F.SCAV, 5, [F.fact(F.PLAYER, 5, Vector2i(2_000_000, 0))]))
	check(_has(result, &"fire") and _has(result, &"aim"), "Scav requests aim and fire after reaction")
	var fire: Dictionary = _action(result, &"fire")
	check(fire.target_tick == 6, "AI actions target the next authority tick")
	var receipt := {"request_id": fire.request_id, "generation": 1, "actor_id": F.SCAV, "resolved_tick": 6, "accepted": false}
	result = ai.step(1, 6, own, F.knowledge(F.SCAV, 6, [F.fact(F.PLAYER, 6, Vector2i(2_000_000, 0))]), [], {}, [receipt])
	check(not _has(result, &"fire"), "rejected fire does not cause immediate retry loop")
	own.ammo = 0
	result = ai.step(1, 9, own, F.knowledge(F.SCAV, 9, [F.fact(F.PLAYER, 9, Vector2i(2_000_000, 0))]))
	check(_has(result, &"reload") and not _has(result, &"fire"), "empty Scav requests reload, no fabricated rounds")
	result = ai.step(1, 10, own, F.knowledge(F.SCAV, 10, [F.fact(F.PLAYER, 9, Vector2i(2_000_000, 0), &"remembered")]))
	check(result.state == "search" and not _has(result, &"fire"), "loss of sight searches remembered position")
	result = ai.step(1, 17, own, F.knowledge(F.SCAV, 17))
	check(result.state == "patrol", "search expires")
	own.health_milli = 100
	result = ai.step(1, 18, own, F.knowledge(F.SCAV, 18, [F.fact(F.PLAYER, 18, Vector2i(2_000_000, 0))]))
	check(result.state == "retreat" and not _has(result, &"fire"), "injured Scav retreats")
	own.alive = false
	result = ai.step(1, 19, own, F.knowledge(F.SCAV, 19))
	check(result.state == "dead" and result.actions.is_empty(), "death terminalizes AI")
	own.alive = true
	result = ai.step(1, 20, own, F.knowledge(F.SCAV, 20))
	check(result.state == "dead" and result.actions.is_empty(), "old brain cannot resurrect")
	var mutant := ZAIAgent.new()
	profile = ZAIProfile.mutant()
	profile.reaction_ticks = 1
	check(mutant.configure(1, F.MUTANT, profile, 1), "mutant configured")
	own = F.own(F.MUTANT)
	result = mutant.step(1, 1, own, F.knowledge(F.MUTANT, 1, [F.fact(F.PLAYER, 1, Vector2i(3_000_000, 0))]))
	check(result.path_request.reason == &"chase_visible" and not _has(result, &"melee"), "mutant chases, cannot hit out of reach")
	result = mutant.step(1, 2, own, F.knowledge(F.MUTANT, 2, [F.fact(F.PLAYER, 2, Vector2i(1_000_000, 0))]))
	check(_has(result, &"melee") and not _has(result, &"fire"), "mutant emits melee intent, not damage")


func _test_navigation() -> void:
	var ai := ZAIAgent.new()
	var profile := ZAIProfile.scav()
	profile.path_timeout_ticks = 3
	profile.retry_ticks = 2
	check(ai.configure(1, F.SCAV, profile, 9, [Vector2i(4_000_000, 0)]), "path agent configured")
	var own := F.own()
	var result := ai.step(1, 1, own, F.knowledge(F.SCAV, 1))
	var request: Dictionary = result.path_request
	check(_action(result, &"move").is_empty(), "initially stopped agent does not fabricate movement without a path")
	var receipt := {"request_id": request.request_id, "generation": 1, "actor_id": F.SCAV,
		"resolved_tick": 2, "navigation_revision": 1, "ok": true, "points": [Vector2i(4_000_000, 0)]}
	result = ai.step(1, 2, own, F.knowledge(F.SCAV, 2), [], receipt)
	check(_action(result, &"move").payload.direction_milli.x == 1000, "matched path produces movement intent")
	own.can_move = false
	result = ai.step(1, 3, own, F.knowledge(F.SCAV, 3))
	check(_action(result, &"move").payload.direction_milli == Vector2i.ZERO, "blocked movement usability stops requests")
	own.can_move = true
	own.navigation_revision = 2
	result = ai.step(1, 4, own, F.knowledge(F.SCAV, 4))
	check(not result.path_request.is_empty() and _action(result, &"move").is_empty(), "navigation revision invalidates path")
	request = result.path_request
	receipt.request_id = request.request_id
	receipt.navigation_revision = 2
	receipt.resolved_tick = 8
	result = ai.step(1, 8, own, F.knowledge(F.SCAV, 8), [], receipt)
	check(_action(result, &"move").is_empty(), "late path result cannot revive timed-out request")
	check(result.path_request.is_empty(), "failed path uses bounded retry delay")
	check(ai.release(1) and not ai.step(1, 9, own, F.knowledge(F.SCAV, 9)).ok, "late callback after release rejected")


func _test_hearing() -> void:
	var noise := RaidNoiseService.new()
	check(noise.configure("zerkov.raid.ai.test", 1), "existing noise service configured")
	check(noise.record_committed(1, "zerkov.consequence.shot.one", F.PLAYER, 1, Vector2i(2_250_000, 0), &"gunshot", 1000), "committed gunshot")
	check(noise.resolve_tick(1, 1, [{"entity_id": F.SCAV, "position_raw": Vector2i.ZERO, "minimum_strength_milli": 80}]), "noise resolves before next decisions")
	var facts := noise.observations_for(1, F.SCAV, 2)
	check(facts.size() == 1 and not facts[0].has("source_id") and not facts[0].visual_confirmation, "audible facts are not visual target identity")
	var ai := ZAIAgent.new()
	check(ai.configure(1, F.SCAV, ZAIProfile.scav(), 1), "hearing agent configured")
	var result := ai.step(1, 2, F.own(), F.knowledge(F.SCAV, 2), facts)
	check(result.state == "investigate" and not _has(result, &"fire"), "noise causes investigation only")
	check(ai.debug_snapshot().target_id.is_empty(), "hearing cannot assign target entity")
	check(result.path_request.destination_raw == Vector2i(2_500_000, 500_000), "investigation uses coarse region center")
	check(noise.resolve_tick(1, 2, []), "empty next noise frame")
	check(noise.observations_for(1, F.SCAV, 3).is_empty(), "no replay of old noise")


func _test_bad_inputs() -> void:
	var ai := ZAIAgent.new()
	check(ai.configure(1, F.SCAV, ZAIProfile.scav(), 0), "invalid input agent configured")
	var own := F.own()
	own["target_live_transform"] = Vector2i(10, 10)
	check(not ai.step(1, 1, own, F.knowledge(F.SCAV, 1)).ok, "extra hidden-state field rejected")
	check(not ai.step(2, 1, F.own(), F.knowledge(F.SCAV, 1)).ok, "stale generation decision")
	var wrong := F.knowledge(F.PLAYER, 1)
	check(not ai.step(1, 1, F.own(), wrong).ok, "wrong recipient knowledge")
	var future := F.fact(F.PLAYER, 100, Vector2i.ZERO)
	check(not ai.step(1, 1, F.own(), F.knowledge(F.SCAV, 1, [future])).ok, "future observation rejected")
	check(ai.step(1, 1, F.own(), F.knowledge(F.SCAV, 1)).ok, "rejected inputs do not advance state")
	check(not ai.step(1, 1, F.own(), F.knowledge(F.SCAV, 1)).ok, "duplicate decision tick")
	var base := RaidAIWorldPort.new()
	var runtime := RaidAIRuntime.new()
	check(not runtime.configure("zerkov.raid.ai.test", 1, 1, base, _registry(), ZAIProfile.scav(), ZAIProfile.mutant()), "unbound world integration cannot masquerade as running AI")


func _run_many(reverse_order: bool) -> String:
	var world := F.WorldDouble.new()
	world.reverse_inputs = reverse_order
	for index: int in range(64):
		world.actors.append(F.actor("zerkov.entity.scav.n%02d" % index, "scav", Vector2i(index * 100_000, 0)))
	var registry := _registry()
	var native := F.VisionDouble.new()
	var runtime := RaidAIRuntime.new()
	check(runtime.configure("zerkov.raid.ai.many", 1, 42, world, registry, ZAIProfile.scav(), ZAIProfile.mutant(), 8), "64 agents with decision budget 8")
	var hashes: Array = []
	var all_visited: Dictionary = {}
	for tick: int in range(1, 121):
		if not runtime.stage_after_movement(1, tick) or not registry.apply_staged(native, 1, tick) \
			or not registry.collect_projections(native, 1, tick) or not runtime.decide(1, tick) \
			or not runtime.resolve_noise(1, tick):
			check(false, "many-NPC tick failed: %s / %s" % [runtime.last_error, registry.last_error])
			return ""
		var snapshot := runtime.debug_snapshot()
		check(snapshot.budget.decisions == 8 and snapshot.budget.deferred == 56, "bounded scheduler work")
		# A scheduled decision may intentionally emit no intent while waiting.
		for agent: Dictionary in snapshot.agents:
			if agent.tick > 0:
				all_visited[agent.entity_id] = true
		for request: Dictionary in world.actions:
			check(request.target_tick == tick + 1, "queued intents are next-tick only")
		hashes.append(JSON.stringify(world.actions).sha256_text())
		world.actions.clear()
		if tick == 8:
			check(all_visited.size() == 64, "no starvation under budget exhaustion")
	check(runtime.release(1), "many-agent cleanup")
	check(not runtime.stage_after_movement(1, 121), "released runtime rejects late phase")
	return JSON.stringify(hashes).sha256_text()


func _has(result: Dictionary, kind: StringName) -> bool:
	return not _action(result, kind).is_empty()


func _action(result: Dictionary, kind: StringName) -> Dictionary:
	for action: Dictionary in result.get("actions", []):
		if action.kind == kind:
			return action
	return {}


func _test_phase_driver() -> void:
	var world := F.WorldDouble.new()
	world.actors = [F.actor(F.SCAV)]
	var registry := _registry()
	var runtime := RaidAIRuntime.new()
	check(runtime.configure("zerkov.raid.ai.phases", 1, 9, world, registry, ZAIProfile.scav(), ZAIProfile.mutant()), "phase runtime configured")
	var raid := F.PhaseAuthorityDouble.new()
	var driver := RaidAIPhaseDriver.new()
	check(driver.bind(raid, 1, runtime, &"player_movement"), "register exact named callbacks")
	check(raid.rows.size() == 3 and raid.rows[&"ai_actor_sync"].after.has("player_movement"), "phase integration uses movement dependency")
	check(not driver._movement(raid, 1, 1, []), "direct callback outside dispatch rejected")
	check(not driver._movement(F.PhaseAuthorityDouble.new(), 1, 1, []), "foreign authority callback rejected")
	check(raid.dispatch(&"ai_actor_sync", 1), "attested movement callback stages actor frame")
	var native := F.VisionDouble.new()
	check(registry.apply_staged(native, 1, 1) and registry.collect_projections(native, 1, 1), "reserved native phase fixture")
	check(raid.dispatch(&"ai_decisions", 1), "attested decision phase executes")
	check(raid.dispatch(&"ai_noise", 1), "attested noise phase executes")
	raid.block_removal = true
	check(not driver.release(1), "failed deregistration blocks teardown")
	check(not runtime.debug_snapshot().released, "blocked teardown retains runtime")
	raid.block_removal = false
	check(driver.release(1), "release retries successfully")
	check(raid.rows.is_empty() and raid.removal_order == [&"ai_noise", &"ai_decisions", &"ai_actor_sync"], "callbacks removed in reverse order")
	check(not driver._decisions(raid, 3, 2, []), "late callback rejected after release")
	var failed_raid := F.PhaseAuthorityDouble.new()
	failed_raid.fail_registration = &"ai_decisions"
	var failed_runtime := RaidAIRuntime.new()
	check(failed_runtime.configure("zerkov.raid.ai.rollback", 1, 9, world, _registry(), ZAIProfile.scav(), ZAIProfile.mutant()), "rollback fixture")
	check(not RaidAIPhaseDriver.new().bind(failed_raid, 1, failed_runtime, &"player_movement"), "registration failure reported")
	check(failed_raid.rows.is_empty(), "registration rollback leaves no retained callback")


func _test_edge_receipts() -> void:
	var profile := ZAIProfile.scav()
	profile.reaction_ticks = 1
	profile.attack_request_interval_ticks = 1
	var ai := ZAIAgent.new()
	check(ai.configure(1, F.SCAV, profile, 1), "receipt-edge agent")
	var first := ai.step(1, 1, F.own(), F.knowledge(F.SCAV, 1, [F.fact(F.PLAYER, 1, Vector2i(1_000_000, 0))]))
	first = ai.step(1, 2, F.own(), F.knowledge(F.SCAV, 2, [F.fact(F.PLAYER, 2, Vector2i(1_000_000, 0))]))
	var shot := _action(first, &"fire")
	check(not shot.is_empty(), "initial shot requested")
	var early := {"request_id": shot.request_id, "generation": 1, "actor_id": F.SCAV, "resolved_tick": 2, "accepted": true}
	var second := ai.step(1, 3, F.own(), F.knowledge(F.SCAV, 3, [F.fact(F.PLAYER, 3, Vector2i(1_000_000, 0))]), [], {}, [early])
	check(not _has(second, &"fire"), "early acknowledgement cannot clear pending shot")
	var noise := RaidNoiseService.new()
	check(noise.configure("zerkov.raid.ai.extreme", 1), "extreme noise fixture")
	var extreme := Vector2i(ZAIValues.LIMIT, 0)
	check(noise.record_committed(1, "zerkov.consequence.edge.noise", F.PLAYER, 1, extreme, &"gunshot", 1000), "extreme event recorded")
	check(noise.resolve_tick(1, 1, [{"entity_id": F.SCAV, "position_raw": extreme, "minimum_strength_milli": 1}]), "extreme audible event resolves")
	var listener := ZAIAgent.new()
	listener.configure(1, F.SCAV, profile, 2)
	var result := listener.step(1, 2, F.own(F.SCAV, Vector2i(ZAIValues.LIMIT - 2_000_000, 0)), F.knowledge(F.SCAV, 2), noise.observations_for(1, F.SCAV, 2))
	check(result.ok and ZAIValues.position(listener.debug_snapshot().last_known_raw), "coarse hearing center stays inside signed coordinate domain")
