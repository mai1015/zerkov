extends SceneTree
## Real Common Vision conformance check. Missing native classes are BLOCKED,
## never a passing skip. No software replacement for LOS is used by this test.

const F = preload("res://tests/ai/fixtures/ai_test_fixtures.gd")
var checks: int = 0
var failures: int = 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("NATIVE_AI_VISION: " + message)


func _initialize() -> void:
	if not ClassDB.class_exists("CommonVisionWorld2D"):
		print("NATIVE_AI_VISION_BLOCKED missing_CommonVisionWorld2D")
		quit(2)
		return
	var native: Object = ClassDB.instantiate("CommonVisionWorld2D")
	check(native.call("configure", 9601, 0, 4_000_000, 256).get("ok") == true, "native world configured")
	var registry := RaidVisionActorRegistry.new()
	check(registry.configure(1), "actor registry configured")
	var actors: Array = [F.actor(F.SCAV), F.actor(F.PLAYER, "player", Vector2i(4_000_000, 0))]
	check(registry.stage_frame(1, 1, actors, 1, []) and registry.apply_staged(native, 1, 1), "real actor registration")
	check(native.call("advance", 1, 16384).get("ok") == true and registry.collect_projections(native, 1, 1), "first real evaluation")
	var adapter := VisionAIAdapter.new()
	check(adapter.configure(1, F.SCAV, registry.native_id_for(1, F.SCAV)), "recipient adapter")
	var frame := adapter.consume(1, 1, registry.projection_for(1, F.SCAV), registry, ZAIProfile.scav())
	check(frame.ok and frame.facts.size() == 1 and frame.facts[0].kind == &"visible", "unoccluded target visible")
	var wall := {"id": 1, "a": {"x": 2_000_000, "y": -2_000_000}, "b": {"x": 2_000_000, "y": 2_000_000}, "mask": 1, "two_sided": true}
	for tick: int in range(2, 185):
		if tick == 5:
			actors[1].revision = 2
			actors[1].position_raw = Vector2i(5_000_000, 0)
		check(registry.stage_frame(1, tick, actors, 2, [wall]) and registry.apply_staged(native, 1, tick), "real revision progression")
		if (tick - 1) % 3 == 0:
			check(native.call("advance", tick, 16384).get("ok") == true and registry.collect_projections(native, 1, tick), "bounded native cadence")
		frame = adapter.consume(1, tick, registry.projection_for(1, F.SCAV), registry, ZAIProfile.scav())
		check(frame.ok, "adapter accepts actual native projection")
		if tick == 4 or tick == 7:
			check(frame.facts.size() == 1 and frame.facts[0].kind == &"remembered" \
				and frame.facts[0].position_raw == Vector2i(4_000_000, 0), "wall occlusion does not disclose hidden movement")
		if tick == 184:
			check(frame.facts.is_empty(), "memory expires without hidden refresh")
	# Zero budget must report deferral rather than manufacture a completed view.
	var deferred: Dictionary = native.call("advance", 187, 0)
	check(deferred.get("ok") == true and deferred.get("completed") == 0 and deferred.get("deferred") == 1, "native zero-work deferral")
	var id := registry.native_id_for(1, F.PLAYER)
	check(native.call("remove_target", id).get("ok") == true, "native target removed")
	registry.release(1)
	native.free()
	print("NATIVE_AI_VISION_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
