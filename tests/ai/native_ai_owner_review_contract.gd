extends SceneTree
## Exact production RaidAuthority/owner/registry + real Common Vision.
## Faults corrupt test-owned staged value records, not native handles or the
## production exact-script checks. This is not a Sawmill playtest.

const F = preload("res://tests/ai/fixtures/ai_test_fixtures.gd")
var checks: int = 0
var failures: int = 0
var registry: RaidVisionActorRegistry
var actors: Array = []
var mode: String = ""
var later_callbacks: int = 0
var subject_serial: int = 0


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("NATIVE_AI_OWNER_REVIEW: " + message)


func run() -> void:
	if not ClassDB.class_exists("CommonVisionWorld2D"):
		print("NATIVE_AI_OWNER_REVIEW_BLOCKED missing_CommonVisionWorld2D")
		quit(2)
		return
	_test_generation_preflight()
	for fault: String in ["missing_frame", "native_sync_failure", "collection_failure"]:
		_test_failure(fault)
	_test_moving_geometry_and_removal()
	print("NATIVE_AI_OWNER_REVIEW_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _raid() -> RefCounted:
	subject_serial += 1
	var id_type: Script = load("res://game/domain/z_raid_id.gd")
	var coordinator_type: Script = load("res://game/bootstrap/session_coordinator.gd")
	var raid_type: Script = load("res://game/raid/raid_authority.gd")
	var id: RefCounted = id_type.call("parse", "zerkov.raid.ai.owner_review_%d" % subject_serial)
	var coordinator: RefCounted = coordinator_type.new()
	var admission: RefCounted = coordinator.call("open_offline", id, &"owner_review", &"player")
	var raid: RefCounted = raid_type.new()
	check(raid.call("configure", id, admission, 19), "real raid configured")
	return raid


func _owner() -> Node:
	var value: Node = load("res://game/ai/vision/raid_vision_world_owner.gd").new()
	root.add_child(value)
	return value


func _test_generation_preflight() -> void:
	var raid := _raid()
	var generation: int = raid.call("generation")
	var wrong := RaidVisionActorRegistry.new()
	check(wrong.configure(generation + 1), "different registry generation")
	var owner := _owner()
	check(not owner.configure(9700, {}, wrong, generation), "mismatched registry rejected during configure")
	check(owner.last_error == &"vision_actor_registry_generation_invalid", "explicit generation diagnostic")
	check(owner.lifecycle_name() == &"not_started" and not owner.get("_runtime_alive"), "rejection allocates no native world")
	check(wrong.is_active(generation + 1), "rejection does not consume caller registry")
	check(not owner.configure(9700, {}, wrong), "omitted expected generation rejected")
	check(owner.configure(9700, {}, wrong, generation + 1), "matching expected generation configures")
	check(not owner.register_with_raid_authority(raid), "actual raid mismatch rejected before registration")
	check(owner.last_error == &"vision_actor_registry_raid_mismatch", "binding generation diagnostic")
	check(not raid.call("has_phase_handler", &"raid_vision_world", generation), "mismatched owner did not claim slot")
	check(owner.teardown(owner.generation()), "unbound native owner tears down")
	check(raid.call("teardown", generation), "preflight raid teardown")
	owner.queue_free()


func _bind(raid: RefCounted, owner: Node) -> bool:
	var generation: int = raid.call("generation")
	registry = RaidVisionActorRegistry.new()
	if not registry.configure(generation) or not owner.configure(9700 + subject_serial, {}, registry, generation):
		check(false, "pinned native startup: " + String(owner.last_error))
		return false
	check(owner.configuration_receipt().actor_frame_required_every_tick, "staged-frame obligation published")
	check(owner.register_with_raid_authority(raid), "exact production owner registered")
	check(raid.call("register_phase_handler", 1, &"owner_review_stage", _stage, generation), "frame producer registered")
	check(raid.call("register_phase_handler", 3, &"owner_review_later", _later, generation), "later phase sentinel")
	actors = [F.actor(F.SCAV), F.actor(F.PLAYER, "player", Vector2i(4_000_000, 0))]
	later_callbacks = 0
	return bool(raid.call("transition", 1, generation))


func _test_failure(fault: String) -> void:
	mode = fault
	var raid := _raid()
	var owner := _owner()
	var generation: int = raid.call("generation")
	if not _bind(raid, owner):
		owner.queue_free()
		return
	var failed_tick: int = 1
	if fault == "missing_frame":
		check(raid.call("advance_one", generation), "initial frame succeeds before skipped staging")
		failed_tick = 2  # A non-evaluation tick STILL requires a full staged frame.
	var previous_later := later_callbacks
	check(not raid.call("advance_one", generation), "owner fault fails real authority tick: " + fault)
	check(raid.call("lifecycle_name") == &"failed", "authority terminalizes: " + fault)
	check(later_callbacks == previous_later, "no later phase executes after failure")
	var telemetry: Dictionary = owner.telemetry_snapshot()
	check(telemetry.last_attempted_tick == failed_tick, "failed tick retained in telemetry")
	check(not owner.get("_runtime_alive") and not registry.is_active(generation), "native disposal invalidates registry")
	check(registry.projection_for(generation, F.SCAV).is_empty(), "no usable projection after quarantine")
	if fault == "collection_failure":
		check(telemetry.failed_evaluations == 1 and telemetry.evaluation_ticks == 0, "collection failure downgrades native success")
		check(telemetry.last_native_status.ok == false and telemetry.last_native_status.completed == 1,
			"successful native completed prefix preserved, not counted as accepted evaluation")
		check(telemetry.last_native_status.consumed > 0, "real native work happened before collection failure")
		check(telemetry.history[-1].terminal and telemetry.history[-1].completed == 1, "failed metrics history sealed")
	else:
		check(telemetry.history[-1].kind == "actor_sync_failed", "actor synchronization failure branch recorded")
		check(telemetry.history[-1].reason == ("vision_actor_frame_missing" if fault == "missing_frame" else "vision_native_actor_command_failed"),
			"specific missing-frame/native failure retained")
	check(not raid.call("advance_one", generation), "terminal raid cannot retry mutation")
	check(owner.teardown(owner.generation()), "failed owner tears down")
	check(raid.call("teardown", generation), "failed raid tears down")
	owner.queue_free()


func _test_moving_geometry_and_removal() -> void:
	mode = "evolving"
	var raid := _raid()
	var owner := _owner()
	var generation: int = raid.call("generation")
	if not _bind(raid, owner):
		owner.queue_free()
		return
	for tick: int in range(1, 8):
		if not raid.call("advance_one", generation):
			check(false, "evolving real-owner tick: " + String(raid.last_error))
			break
		check(registry.diagnostics().tick == tick, "every canonical frame applied")
		var projection := registry.projection_for(generation, F.SCAV)
		if tick == 1:
			check(not projection.is_empty() and projection.records.size() == 1, "real native sight established")
		elif tick == 2:
			check(projection.is_read_only() and projection.records.is_read_only(), "cadence gap retains frozen projection")
		elif tick == 4:
			check(projection.geometry_revision == 2 and projection.records[0].state == 1, "changed wall occludes moved player")
			check(projection.records[0].last_known_position.x == 4_000_000, "native memory retains pre-occlusion observation")
		elif tick >= 5:
			check(projection.is_empty(), "dead/omitted observer projection removed immediately")
	check(registry.diagnostics().actors == 0, "all actors removed after final frame")
	check(owner.telemetry_snapshot().evaluation_ticks == 3, "only 1/4/7 evaluated")
	check(raid.call("unregister_phase_handler", &"owner_review_later", generation), "remove sentinel")
	check(raid.call("unregister_phase_handler", &"owner_review_stage", generation), "remove frame producer")
	check(owner.teardown(owner.generation()), "evolving owner teardown")
	check(raid.call("teardown", generation), "evolving raid teardown")
	owner.queue_free()


func _stage(raid: RefCounted, _phase: int, tick: int, _intents: Array) -> bool:
	if mode == "missing_frame" and tick == 2:
		return true  # Deliberately violate documented frame obligation.
	var segments: Array = []
	var geometry_revision: int = 1
	if mode == "evolving":
		if tick == 2:
			actors[1].position_raw = Vector2i(10_000_000, 0)
			actors[1].revision = 2
		if tick >= 3:
			geometry_revision = 2
			segments = [{"id": 1, "a": {"x": 2_000_000, "y": -4_000_000},
				"b": {"x": 2_000_000, "y": 4_000_000}, "mask": 1, "two_sided": true}]
		if tick == 5:
			actors[0].alive = false
			actors[0].revision = 2
		elif tick == 6:
			actors = [actors[0]]
		elif tick == 7:
			actors = []
	if not registry.stage_frame(int(raid.call("generation")), tick, actors, geometry_revision, segments):
		return false
	if mode == "native_sync_failure":
		# Duplicate a valid native registration AFTER earlier commands commit.
		var staged: Dictionary = registry.get("_staged")
		for command: Dictionary in staged.commands.duplicate(true):
			if command.method == &"register_target":
				staged.commands.append(command)
				break
	elif mode == "collection_failure":
		# Native commands remain valid and advance succeeds. Corrupt only the
		# retained projection-lookup identity to trigger collection failure.
		var staged: Dictionary = registry.get("_staged")
		staged.entities[F.SCAV].native_id = 0
	return true


func _later(_raid: RefCounted, _phase: int, _tick: int, _intents: Array) -> bool:
	later_callbacks += 1
	return true
