extends SceneTree
## Headless contract for task 3.6: server-authoritative 2D movement, collision,
## correction and blocked-movement results.
## Run with: godot --headless --path . --resolution 1920x1080 --audio-driver Dummy
##   --script res://tests/raid/movement_authority_contract.gd

const MovementWorldScript = preload("res://game/world/movement/z_movement_world_2d.gd")
const Locomotion = preload("res://game/world/player/player_locomotion.gd")
const IntentAdapter = preload("res://game/input/ui_intent_adapter.gd")

const MICRO: int = 31250  # ZWorldUnits microunits per Godot px (1_000_000 / 32).
const HALF: int = 250000  # 8 px body half extent in microunits.
const WALL_EAST_LO: int = 9375000  # 300 px.
const FLUSH_X: int = 9125000  # 300 px - 8 px half extent.

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("MOVEMENT_AUTHORITY_CONTRACT: " + message)


func run() -> void:
	load("res://tests/raid/movement_navigation_regression_cases.gd").new().run(Callable(self, "check"))
	_test_module_purity_and_construction()
	_test_actor_registration_validation()
	_test_free_movement_open_world()
	_test_head_on_block()
	_test_wall_slide_x_blocked()
	_test_wall_slide_y_blocked()
	_test_corner_double_block()
	_test_bounds_clamping()
	_test_collider_id_reporting()
	_test_correction_records()
	_test_generation_and_seal_rejection()
	_test_presentation_writeback_isolation()
	_test_determinism_two_independent_runs()
	_test_locomotion_integration()
	_test_raid_authority_sawmill_integration()

	print("MOVEMENT_AUTHORITY_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


## Deterministic synthetic yard: bounds 640x360 px, one full-height east wall,
## one south wall, and an interior L-corner (north + west legs).
func _make_yard(generation: int) -> ZMovementWorld2D:
	var world := ZMovementWorld2D.new()
	var configured := world.configure(Rect2(0, 0, 640.0, 360.0), generation, "fixture.level.yard")
	assert(configured)
	world.add_static_collider_px("fixture.wall.east", Rect2(300.0, 0.0, 32.0, 360.0), generation)
	world.add_static_collider_px("fixture.wall.south", Rect2(0.0, 300.0, 300.0, 32.0), generation)
	world.add_static_collider_px("fixture.wall.north_leg", Rect2(480.0, 68.0, 132.0, 32.0), generation)
	world.add_static_collider_px("fixture.wall.west_leg", Rect2(480.0, 100.0, 32.0, 132.0), generation)
	return world


func _actor(slot: String) -> ZEntityId:
	return ZEntityId.from_parts(PackedStringArray(["fixture", "movement", slot]))


func _micro_to_px(micro: Vector2i) -> Vector2:
	return Vector2(
		float(micro.x) * 32.0 / 1000000.0,
		float(micro.y) * 32.0 / 1000000.0
	)


func _test_module_purity_and_construction() -> void:
	var movement_script := load(
		"res://game/world/movement/z_movement_world_2d.gd"
	) as GDScript
	var source := movement_script.source_code
	for banned in [
		"preload(", "load(", "ResourceLoader", "res://", "sawmill",
		"PhysicsServer", "move_and_slide(", "Time.get_", "_physics_process(",
		"_process(", "randf",
	]:
		check(not source.contains(banned), "movement world source must not contain '%s'" % banned)

	var world := ZMovementWorld2D.new()
	check(not world.is_configured(), "new world starts unconfigured")
	var stale := world.resolve_actor_step(_actor("early"), 1, Vector2(128.0, 0.0), 0)
	check(not stale.ok and stale.reason == &"world_unconfigured",
		"unconfigured world rejects resolution with world_unconfigured")
	check(not world.register_actor(_actor("early"), Vector2(10, 10), Vector2(8, 8), 0),
		"unconfigured world rejects registration")

	check(not world.configure(Rect2(0, 0, 0, 100), 1), "zero-size bounds rejected")
	check(not world.configure(Rect2(0, 0, -10, 100), 1), "negative bounds rejected")
	check(world.configure(Rect2(0, 0, 640.0, 360.0), 1, "fixture.level.yard"),
		"valid bounds configure")
	check(world.is_configured() and world.generation() == 1, "configured generation recorded")
	check(world.collider_count() == 0, "fresh world has no colliders")
	var bounds := world.bounds_px()
	check(absf(bounds.position.x) < 0.001 and absf(bounds.position.y) < 0.001
			and absf(bounds.size.x - 640.0) < 0.001 and absf(bounds.size.y - 360.0) < 0.001,
		"bounds round-trips to the authored px rect")

	check(world.add_static_collider_px("fixture.wall.east", Rect2(300.0, 0.0, 32.0, 360.0), 1),
		"static collider injection succeeds")
	check(not world.add_static_collider_px("fixture.wall.east", Rect2(0, 0, 1, 1), 1)
			and world.last_error == &"collider_id_duplicate",
		"duplicate collider id rejected")
	check(not world.add_static_collider_px("", Rect2(0, 0, 1, 1), 1)
			and world.last_error == &"collider_id_invalid",
		"empty collider id rejected")
	check(not world.add_static_collider_px("fixture.bad", Rect2(10, 10, 0, 5), 1)
			and world.last_error == &"collider_rect_invalid",
		"degenerate collider rect rejected")
	check(world.collider_count() == 1, "only the valid collider was stored")
	check(not world.add_static_collider_px("fixture.stale", Rect2(0, 0, 1, 1), 2)
			and world.last_error == &"stale_generation",
		"collider injection with stale generation is inert")

	# Cell-authored and px-authored rects describe identical geometry.
	var cells_world := ZMovementWorld2D.new()
	cells_world.configure(Rect2(0, 0, 640.0, 360.0), 2)
	cells_world.add_static_collider_cells("fixture.cell_block", Rect2i(10, 10, 2, 2), 2)
	cells_world.register_actor(_actor("cells"), Vector2(100, 100), Vector2(8, 8), 2)
	var px_world := ZMovementWorld2D.new()
	px_world.configure(Rect2(0, 0, 640.0, 360.0), 2)
	px_world.add_static_collider_px("fixture.cell_block", Rect2(320.0, 320.0, 64.0, 64.0), 2)
	px_world.register_actor(_actor("cells"), Vector2(100, 100), Vector2(8, 8), 2)
	check(cells_world.digest() == px_world.digest(),
		"cell rect (10,10,2,2) equals px rect (320,320,64,64) in canonical space")


func _test_actor_registration_validation() -> void:
	var world := _make_yard(3)
	var actor := _actor("register_probe")
	check(world.register_actor(actor, Vector2(200.0, 140.0), Vector2(8, 8), 3),
		"valid spawn registers")
	check(world.has_actor(actor), "registered actor is present")
	check(world.actor_position_px(actor).is_equal_approx(Vector2(200.0, 140.0)),
		"registered position round-trips")
	check(world.actor_last_tick(actor) == 0, "fresh body has tick 0")
	check(world.actor_count() == 1, "one body registered")

	check(not world.register_actor(actor, Vector2(50.0, 50.0), Vector2(8, 8), 3)
			and world.last_error == &"actor_already_registered",
		"duplicate actor registration rejected")
	check(not world.register_actor(_actor("in_wall"), Vector2(310.0, 10.0), Vector2(8, 8), 3)
			and world.last_error == &"actor_spawn_blocked",
		"spawn inside a blocking collider rejected")
	check(not world.register_actor(_actor("outside"), Vector2(700.0, 10.0), Vector2(8, 8), 3)
			and world.last_error == &"actor_out_of_bounds",
		"spawn outside level bounds rejected")
	check(not world.register_actor(_actor("thin"), Vector2(50.0, 50.0), Vector2(0.0, 8.0), 3)
			and world.last_error == &"body_shape_invalid",
		"degenerate body extents rejected")
	check(not world.register_actor(null, Vector2(50.0, 50.0), Vector2(8, 8), 3)
			and world.last_error == &"actor_id_invalid",
		"null actor id rejected")
	check(not world.register_actor(_actor("stale"), Vector2(50.0, 50.0), Vector2(8, 8), 2)
			and world.last_error == &"stale_generation",
		"registration with stale generation rejected")
	check(not world.teleport_actor(actor, Vector2(310.0, 10.0), 3)
			and world.last_error == &"actor_spawn_blocked",
		"teleport into a collider rejected")
	check(world.teleport_actor(actor, Vector2(210.0, 140.0), 3),
		"teleport to a free position succeeds")
	check(world.actor_position_px(actor).is_equal_approx(Vector2(210.0, 140.0)),
		"teleport position is authoritative")


func _test_free_movement_open_world() -> void:
	var world := ZMovementWorld2D.new()
	check(world.configure_open_world(1), "open world configures")
	var actor_a := _actor("free_a")
	var actor_b := _actor("free_b")
	check(world.register_actor(actor_a, Vector2.ZERO, Vector2(8, 8), 1), "actor a registers at origin")
	check(world.register_actor(actor_b, Vector2(100.0, 100.0), Vector2(8, 8), 1), "actor b registers")

	var result := world.resolve_actor_step(actor_a, 1, Vector2(128.0, 0.0), 1)
	check(result.ok, "free step resolves")
	check(not result.corrected and result.blocked_axes == 0,
		"free step is unblocked and uncorrected")
	check(result.requested_position_micro == Vector2i(66667, 0),
		"128 px/s implies 66667 micro displacement per tick (half away from zero)")
	check(result.resolved_position_micro == result.requested_position_micro,
		"free resolution equals the implied displacement")
	check(result.resolved_velocity_px == Vector2(128.0, 0.0),
		"resolved velocity equals requested velocity when free")
	check(result.blocking_collider_ids.is_empty(), "free step reports no collider ids")
	check(result.resolved_position_px == _micro_to_px(Vector2i(66667, 0)),
		"resolved px derives from the canonical micro position")
	check(world.actor_position_micro(actor_a) == Vector2i(66667, 0), "world state advanced")

	var second := world.resolve_actor_step(actor_a, 2, Vector2(128.0, 0.0), 1)
	check(second.resolved_position_micro == Vector2i(133334, 0),
		"free movement accumulates exactly")

	var result_b := world.resolve_actor_step(actor_b, 1, Vector2(0.0, -192.0), 1)
	check(result_b.resolved_position_micro == Vector2i(3125000, 3025000),
		"192 px/s implies exactly 100000 micro per tick (negative axis)")

	var idle := world.resolve_actor_step(actor_a, 3, Vector2.ZERO, 1)
	check(idle.ok and not idle.corrected and idle.resolved_position_micro == Vector2i(133334, 0),
		"zero velocity keeps the body in place")
	check(world.correction_count() == 0, "free movement produces no corrections")


func _test_head_on_block() -> void:
	var world := _make_yard(2)
	var actor := _actor("head_on")
	check(world.register_actor(actor, Vector2(200.0, 140.0), Vector2(8, 8), 2), "spawn registers")

	var first_blocked_tick := -1
	var blocked_result: ZMovementResult = null
	for tick in range(1, 41):
		var result := world.resolve_actor_step(actor, tick, Vector2(192.0, 0.0), 2)
		if result.corrected:
			first_blocked_tick = tick
			blocked_result = result
			break
		check(result.resolved_position_micro.x == 6250000 + 100000 * tick,
			"tick %d advances unblocked exactly" % tick)
	check(first_blocked_tick == 29,
		"head-on block first clamps at tick 29 (observed %d)" % first_blocked_tick)
	check(blocked_result != null and blocked_result.ok, "blocked step still resolves ok")
	check(blocked_result.requested_position_micro == Vector2i(9150000, 4375000),
		"requested micro position is the implied displacement")
	check(blocked_result.resolved_position_micro == Vector2i(FLUSH_X, 4375000),
		"resolved micro position clamps flush against the wall (300-8 px)")
	check(blocked_result.corrected, "blocked move is flagged corrected")
	check(blocked_result.blocked_x() and not blocked_result.blocked_y(),
		"only the X axis is blocked head-on")
	check(blocked_result.blocking_collider_ids == PackedStringArray(["fixture.wall.east"]),
		"head-on block reports the authored structure id")
	check(blocked_result.resolved_velocity_px == Vector2.ZERO,
		"resolved velocity zeroes the blocked axis component")
	check(blocked_result.resolved_position_px == Vector2(292.0, 140.0),
		"resolved px position is exactly (292, 140)")

	for tick in range(first_blocked_tick + 1, first_blocked_tick + 7):
		var held := world.resolve_actor_step(actor, tick, Vector2(192.0, 0.0), 2)
		check(held.resolved_position_micro == Vector2i(FLUSH_X, 4375000),
			"tick %d holds the flush position against the wall" % tick)
		check(held.blocked_x() and held.blocking_collider_ids.size() == 1,
			"tick %d keeps reporting the block" % tick)

	var retreat := world.resolve_actor_step(actor, first_blocked_tick + 7, Vector2(-192.0, 0.0), 2)
	check(retreat.ok and not retreat.corrected and not retreat.blocked_x(),
		"moving away from the wall is free again")
	check(retreat.resolved_position_micro == Vector2i(FLUSH_X - 100000, 4375000),
		"retreat advances away from the wall")


func _test_wall_slide_x_blocked() -> void:
	var world := _make_yard(2)
	var actor := _actor("slide_x")
	world.register_actor(actor, Vector2(200.0, 140.0), Vector2(8, 8), 2)

	var blocked_from := -1
	for tick in range(1, 36):
		var result := world.resolve_actor_step(actor, tick, Vector2(192.0, 192.0), 2)
		if result.blocked_x():
			blocked_from = tick
			check(not result.blocked_y(), "slide keeps the Y axis unblocked")
			check(result.resolved_velocity_px == Vector2(0.0, 192.0),
				"resolved velocity keeps the unblocked component")
			break
		check(result.resolved_position_micro == Vector2i(6250000 + 100000 * tick, 4375000 + 100000 * tick),
			"pre-block diagonal tick %d advances both axes" % tick)
	check(blocked_from == 29, "diagonal into the east wall clamps X at tick 29")

	for tick in range(blocked_from, 36):
		var slide := world.resolve_actor_step(actor, tick + 1, Vector2(192.0, 192.0), 2)
		check(slide.resolved_position_micro.x == FLUSH_X,
			"blocked tick holds X at the wall while sliding")
		check(slide.resolved_position_micro.y == 4375000 + 100000 * (tick + 1),
			"blocked tick %d keeps advancing Y (wall slide)" % (tick + 1))
		check(slide.resolved_velocity_px == Vector2(0.0, 192.0),
			"slide velocity zeroes only the blocked component")
	check(world.actor_position_micro(actor) == Vector2i(FLUSH_X, 4375000 + 3600000),
		"final slide position keeps the full unblocked travel (36 ticks)")


func _test_wall_slide_y_blocked() -> void:
	var world := _make_yard(2)
	var actor := _actor("slide_y")
	world.register_actor(actor, Vector2(140.0, 200.0), Vector2(8, 8), 2)

	var blocked_from := -1
	for tick in range(1, 36):
		var result := world.resolve_actor_step(actor, tick, Vector2(-192.0, 192.0), 2)
		if result.blocked_y():
			blocked_from = tick
			check(not result.blocked_x(), "Y-blocked slide keeps X unblocked")
			check(result.resolved_velocity_px == Vector2(-192.0, 0.0),
				"resolved velocity keeps the unblocked X component")
			check(result.resolved_position_micro.y == FLUSH_X,
				"Y clamps flush against the south wall (300-8 px)")
			break
	check(blocked_from == 29, "diagonal into the south wall clamps Y at tick 29")

	for tick in range(blocked_from, 36):
		var slide := world.resolve_actor_step(actor, tick + 1, Vector2(-192.0, 192.0), 2)
		check(slide.resolved_position_micro.y == FLUSH_X,
			"blocked tick holds Y at the wall")
		check(slide.resolved_position_micro.x == 4375000 - 100000 * (tick + 1),
			"blocked tick %d keeps advancing X (wall slide)" % (tick + 1))


func _test_corner_double_block() -> void:
	var world := _make_yard(2)
	var actor := _actor("corner")
	world.register_actor(actor, Vector2(530.0, 120.0), Vector2(8, 8), 2)

	for tick in range(1, 4):
		var result := world.resolve_actor_step(actor, tick, Vector2(-192.0, -192.0), 2)
		check(result.ok and not result.corrected,
			"corner approach tick %d is still free" % tick)
	check(world.actor_position_micro(actor) == Vector2i(16262500, 3450000),
		"three free ticks reach the corner approach position")

	var corner := world.resolve_actor_step(actor, 4, Vector2(-192.0, -192.0), 2)
	check(corner.blocked_x() and corner.blocked_y(),
		"interior corner blocks both axes in one tick")
	check(corner.requested_position_micro == Vector2i(16162500, 3350000),
		"corner requested micro position is the implied displacement")
	check(corner.resolved_position_micro == Vector2i(16250000, 3375000),
		"corner resolution clamps flush on both axes (520, 108 px)")
	check(corner.resolved_velocity_px == Vector2.ZERO,
		"double block zeroes both velocity components")
	check(corner.blocking_collider_ids == PackedStringArray([
			"fixture.wall.north_leg", "fixture.wall.west_leg",
		]), "corner reports both authored ids sorted deterministically")
	check(corner.corrected, "corner move is flagged corrected")

	var held := world.resolve_actor_step(actor, 5, Vector2(-192.0, -192.0), 2)
	check(held.blocked_x() and held.blocked_y()
			and held.resolved_position_micro == Vector2i(16250000, 3375000),
		"continued diagonal into the corner stays fully blocked in place")

	var escape := world.resolve_actor_step(actor, 6, Vector2(192.0, 192.0), 2)
	check(escape.ok and not escape.corrected and not escape.blocked_x() and not escape.blocked_y(),
		"reversing out of the corner is free")


func _test_bounds_clamping() -> void:
	var world := _make_yard(4)
	var actor := _actor("bounds_east")
	world.register_actor(actor, Vector2(620.0, 180.0), Vector2(8, 8), 4)
	for tick in range(1, 4):
		var result := world.resolve_actor_step(actor, tick, Vector2(192.0, 0.0), 4)
		check(result.ok and not result.corrected,
			"tick %d inside the level moves freely" % tick)
	var clamped := world.resolve_actor_step(actor, 4, Vector2(192.0, 0.0), 4)
	check(clamped.blocked_x() and clamped.corrected,
		"east bounds edge blocks and corrects")
	check(clamped.resolved_position_micro == Vector2i(19750000, 5625000),
		"east bounds clamp holds the body flush at 640-8 px")
	check(clamped.blocking_collider_ids == PackedStringArray(["fixture.level.yard"]),
		"bounds clamp reports the configured bounds collider id")

	var west_actor := _actor("bounds_west")
	world.register_actor(west_actor, Vector2(10.0, 10.0), Vector2(8, 8), 4)
	var west := world.resolve_actor_step(west_actor, 1, Vector2(-192.0, 0.0), 4)
	check(west.blocked_x() and west.resolved_position_micro == Vector2i(HALF, 312500),
		"west bounds clamp holds the body flush at 8 px")

	var corner_actor := _actor("bounds_corner")
	world.register_actor(corner_actor, Vector2(630.0, 350.0), Vector2(8, 8), 4)
	var corner := world.resolve_actor_step(corner_actor, 1, Vector2(192.0, 192.0), 4)
	check(corner.blocked_x() and corner.blocked_y(),
		"level corner blocks both axes")
	check(corner.resolved_position_micro == Vector2i(19750000, 11000000),
		"level corner clamps flush on both axes (632, 352 px)")
	check(corner.blocking_collider_ids == PackedStringArray(["fixture.level.yard"]),
		"both-axis bounds clamp reports the bounds id exactly once")


func _test_collider_id_reporting() -> void:
	var world := _make_yard(2)
	var actor := _actor("ids")
	world.register_actor(actor, Vector2(200.0, 140.0), Vector2(8, 8), 2)
	for tick in range(1, 30):
		world.resolve_actor_step(actor, tick, Vector2(192.0, 0.0), 2)
	var result := world.resolve_actor_step(actor, 30, Vector2(192.0, 0.0), 2)
	check(result.blocking_collider_ids.size() == 1
			and result.blocking_collider_ids[0] == "fixture.wall.east",
		"single-axis block reports exactly the authored structure id")
	check(result.blocking_collider_ids[0].begins_with("fixture.wall."),
		"reported id is the full stable authored string (no node/index identity)")

	var corner_actor := _actor("ids_corner")
	world.register_actor(corner_actor, Vector2(530.0, 120.0), Vector2(8, 8), 2)
	for tick in range(1, 4):
		world.resolve_actor_step(corner_actor, tick, Vector2(-192.0, -192.0), 2)
	var corner_first := world.resolve_actor_step(corner_actor, 4, Vector2(-192.0, -192.0), 2)
	var corner_again := world.resolve_actor_step(corner_actor, 5, Vector2(-192.0, -192.0), 2)
	check(corner_first.blocking_collider_ids == corner_again.blocking_collider_ids,
		"repeated identical blocks report byte-identical sorted id lists")
	var ids: Array = []
	for id in corner_first.blocking_collider_ids:
		ids.append(id)
	check(ids == ["fixture.wall.north_leg", "fixture.wall.west_leg"]
			and ids[0] < ids[1],
		"multi-axis block lists ids in lexicographic sort order")


func _test_correction_records() -> void:
	var world := _make_yard(2)
	var actor := _actor("corrected")
	world.register_actor(actor, Vector2(200.0, 140.0), Vector2(8, 8), 2)
	for tick in range(1, 30):
		world.resolve_actor_step(actor, tick, Vector2(192.0, 0.0), 2)
	world.resolve_actor_step(actor, 30, Vector2(192.0, 0.0), 2)
	world.resolve_actor_step(actor, 31, Vector2(192.0, 0.0), 2)

	var snapshot := world.corrections_snapshot_for(actor)
	check(snapshot.size() == 3, "three blocked ticks appended three corrections")
	var record: Dictionary = snapshot[0]
	check(record["tick"] == 29, "correction records the tick")
	check(record["actor_id"] == actor.canonical_key(), "correction records the actor identity")
	check(record["requested_position_micro"] == Vector2i(9150000, 4375000),
		"correction records the requested (implied) micro position")
	check(record["resolved_position_micro"] == Vector2i(FLUSH_X, 4375000),
		"correction records the resolved micro position")
	check(record["requested_velocity_milli"] == Vector2i(6000, 0),
		"correction records requested velocity in weapon milliunits")
	check(record["resolved_velocity_milli"] == Vector2i.ZERO,
		"correction records resolved velocity in weapon milliunits")
	check(record["blocked_axes"] == ZMovementResult.BLOCKED_AXIS_X,
		"correction records the blocked axis mask")
	check(record["blocking_collider_ids"] == ["fixture.wall.east"],
		"correction records the sorted blocking ids")
	check(ZCanonicalValue.is_bounded(record), "correction record is bounded canonical")

	# Bounded log: 70 blocked ticks keep only the newest 64 records.
	var bounded_world := ZMovementWorld2D.new()
	bounded_world.configure(Rect2(0, 0, 640.0, 360.0), 5, "fixture.level.yard")
	var bounded_actor := _actor("bounded")
	bounded_world.register_actor(bounded_actor, Vector2(620.0, 180.0), Vector2(8, 8), 5)
	for tick in range(1, 71):
		bounded_world.resolve_actor_step(bounded_actor, tick, Vector2(192.0, 0.0), 5)
	check(bounded_world.correction_count() == 64,
		"correction log is bounded to 64 records (observed %d)" % bounded_world.correction_count())
	var bounded_snapshot := bounded_world.corrections_snapshot()
	check(bounded_snapshot[0]["tick"] == 7 and bounded_snapshot[63]["tick"] == 70,
		"bounded log drops the oldest records and keeps the newest")


func _test_generation_and_seal_rejection() -> void:
	var world := ZMovementWorld2D.new()
	world.configure(Rect2(0, 0, 640.0, 360.0), 5)
	check(not world.register_actor(_actor("gen"), Vector2(50.0, 50.0), Vector2(8, 8), 4)
			and world.last_error == &"stale_generation",
		"future generation registration rejected")
	var actor := _actor("gen")
	check(world.register_actor(actor, Vector2(50.0, 50.0), Vector2(8, 8), 5), "actor registers")
	check(not world.teleport_actor(actor, Vector2(60.0, 50.0), 4),
		"teleport with stale generation is inert")
	check(not world.add_static_collider_px("fixture.late", Rect2(0, 0, 4, 4), 4),
		"late collider injection with stale generation is inert")

	var stale_step := world.resolve_actor_step(actor, 1, Vector2(128.0, 0.0), 6)
	check(not stale_step.ok and stale_step.reason == &"stale_generation",
		"resolution with wrong generation fails closed")
	check(world.actor_position_micro(actor) == Vector2i(1562500, 1562500),
		"stale resolution did not move the body")

	var accepted := world.resolve_actor_step(actor, 1, Vector2(128.0, 0.0), 5)
	check(accepted.ok, "correct generation resolves")
	var replayed := world.resolve_actor_step(actor, 1, Vector2(128.0, 0.0), 5)
	check(not replayed.ok and replayed.reason == &"tick_regressed",
		"replayed tick is rejected")
	var late := world.resolve_actor_step(actor, 0, Vector2(128.0, 0.0), 5)
	check(not late.ok and late.reason == &"tick_regressed",
		"regressed tick is rejected")
	check(world.actor_position_micro(actor) == accepted.resolved_position_micro,
		"replayed and regressed calls are inert")

	check(not world.seal(4), "seal with wrong generation rejected")
	check(world.seal(5), "seal with the current generation succeeds")
	check(world.is_sealed(), "world reports sealed")
	var sealed_step := world.resolve_actor_step(actor, 2, Vector2(128.0, 0.0), 5)
	check(not sealed_step.ok and sealed_step.reason == &"world_sealed",
		"sealed world rejects even the correct generation (late call inert)")
	check(world.actor_position_micro(actor) == accepted.resolved_position_micro,
		"sealed world did not move the body")
	check(not world.register_actor(_actor("post_seal"), Vector2(50.0, 50.0), Vector2(8, 8), 5),
		"sealed world rejects registration")


func _test_presentation_writeback_isolation() -> void:
	var world := _make_yard(2)
	var actor := _actor("presentation")
	world.register_actor(actor, Vector2(200.0, 140.0), Vector2(8, 8), 2)
	for tick in range(1, 30):
		world.resolve_actor_step(actor, tick, Vector2(192.0, 0.0), 2)
	var result := world.resolve_actor_step(actor, 30, Vector2(192.0, 0.0), 2)

	# Presentation holds a result and mutates it: nothing may flow back.
	result.resolved_position_micro = Vector2i.ZERO
	result.resolved_position_px = Vector2.ZERO
	result.resolved_velocity_px = Vector2(9999.0, 9999.0)
	result.blocked_axes = 0
	result.corrected = false
	check(world.actor_position_micro(actor) == Vector2i(FLUSH_X, 4375000),
		"mutating a held result cannot move the authoritative body")

	var snapshot := world.corrections_snapshot_for(actor)
	snapshot[0]["resolved_position_micro"] = Vector2i(-1, -1)
	snapshot[0]["tick"] = -99
	var fresh := world.corrections_snapshot_for(actor)
	check(fresh[0]["resolved_position_micro"] == Vector2i(FLUSH_X, 4375000)
			and fresh[0]["tick"] == 29,
		"mutating a correction snapshot cannot rewrite the correction log")

	var next := world.resolve_actor_step(actor, 31, Vector2(0.0, 192.0), 2)
	check(next.ok and next.resolved_position_micro.x == FLUSH_X,
		"subsequent resolution ignores presentation-side result tampering")


func _run_intent_script() -> Dictionary:
	var world := _make_yard(3)
	var actor := _actor("replay")
	var session := ZSessionId.from_parts(PackedStringArray(["offline", "movement", "00000001"]))
	var loco := Locomotion.new()
	loco.configure(actor, Vector2(200.0, 140.0))
	check(loco.attach_movement_world(world, Vector2(8, 8)), "replay run attaches yard world")

	var tick_digests: PackedStringArray = PackedStringArray()
	var result_digests: PackedStringArray = PackedStringArray()
	var world_digests: PackedStringArray = PackedStringArray()
	for tick in range(1, 91):
		var move := Vector2(1.0, 1.0) if tick > 80 else Vector2(1.0, 0.0)
		var intent := IntentAdapter.create_movement_intent(
			ZRequestId.from_parts(PackedStringArray([
				"move", "replay", "%08d" % tick,
			])),
			session,
			actor,
			1,
			3,
			tick,
			tick,
			move
		)
		var outcome := loco.step_with_intent(tick, intent)
		check(bool(outcome.get("ok", false)), "replay tick %d accepted" % tick)
		tick_digests.append(loco.digest())
		result_digests.append(loco.last_movement_result().digest())
		world_digests.append(world.digest())
	var chain := ZCanonicalValue.sha256("movement-authority-chain-v1")
	for index in tick_digests.size():
		chain = ZCanonicalValue.sha256([
			chain, tick_digests[index], result_digests[index], world_digests[index],
		])
	return {
		"chain": chain,
		"corrections": world.corrections_snapshot_for(actor),
		"final_digest": world.digest(),
		"position": loco.position_px,
		"tick_digests": tick_digests,
	}


func _test_determinism_two_independent_runs() -> void:
	var run_a := _run_intent_script()
	var run_b := _run_intent_script()
	check(run_a["chain"] == run_b["chain"] and not String(run_a["chain"]).is_empty(),
		"the same accepted intent sequence yields bit-identical chained sha256 digests")
	check(run_a["tick_digests"].size() == 90 and run_b["tick_digests"].size() == 90,
		"both independent runs executed all 90 ticks")
	check(run_a["tick_digests"] == run_b["tick_digests"],
		"per-tick locomotion digests are bit-identical across runs")
	check(run_a["final_digest"] == run_b["final_digest"],
		"final movement world digests are bit-identical across runs")
	check(run_a["corrections"] == run_b["corrections"],
		"correction logs are identical across runs")
	check(run_a["position"] == run_b["position"],
		"final resolved positions are identical across runs")
	var final_position: Vector2 = run_a["position"]
	check(absf(final_position.x - 292.0) < 0.0001,
		"replay run ends flush against the east wall (resolved x ~= 292)")
	check(final_position.y > 145.0, "replay run slid along the wall after the block")


func _test_locomotion_integration() -> void:
	# Locomotion always resolves through a movement world; position_px is only
	# ever written from a movement result (no unchecked integration step).
	var world := _make_yard(4)
	var actor := _actor("loco_player")
	var loco := Locomotion.new()
	loco.configure(actor, Vector2(200.0, 140.0))
	check(loco.movement_world() != null, "locomotion starts with a default open world")
	check(loco.movement_world().collider_count() == 0, "default open world has no colliders")
	check(loco.attach_movement_world(world, Vector2(8, 8)), "yard world attaches")

	var blocked_tick := -1
	for tick in range(1, 61):
		loco.step_tick(tick, Vector2(1.0, 0.0))
		if loco.last_movement_result() != null and loco.last_movement_result().blocked_x():
			blocked_tick = tick
			break
	check(blocked_tick > 0, "locomotion hits the wall under walk acceleration")
	check(loco.position_px.x == 292.0,
		"locomotion position converges exactly to the resolved flush position")
	var blocked := loco.last_movement_result()
	check(blocked.blocked_x() and blocked.corrected, "locomotion result reports the block")
	check(blocked.blocking_collider_ids == PackedStringArray(["fixture.wall.east"]),
		"locomotion reports the authored collider id")
	check(loco.velocity_px == Vector2.ZERO, "locomotion velocity zeroes on head-on block")
	check(world.actor_position_px(actor).is_equal_approx(Vector2(292.0, 140.0)),
		"the movement world owns the same resolved body position")

	for tick in range(blocked_tick + 1, blocked_tick + 6):
		loco.step_tick(tick, Vector2(1.0, 1.0))
		check(loco.position_px.x == 292.0,
			"locomotion wall-slide tick %d keeps resolved X" % tick)
		check(loco.velocity_px.x == 0.0 and loco.velocity_px.y > 0.0,
			"locomotion slide keeps only the unblocked velocity component")
	check(loco.position_px.y > 140.0, "locomotion slide advanced along the wall")

	for tick in range(blocked_tick + 6, blocked_tick + 20):
		loco.step_tick(tick, Vector2.ZERO)
	check(loco.velocity_px.length() < 0.001, "locomotion decelerates to a stop after release")

	# Default open world regression: unattached locomotion still moves freely.
	var free_loco := Locomotion.new()
	free_loco.configure(_actor("loco_free"), Vector2(50.0, 50.0))
	for tick in range(1, 6):
		free_loco.step_tick(tick, Vector2(1.0, 0.0))
	check(free_loco.position_px.x > 50.0, "default open world still advances freely")
	check(free_loco.last_movement_result() != null
			and not free_loco.last_movement_result().corrected,
		"default open world never corrects")

	# Attach validation.
	check(not free_loco.attach_movement_world(null)
			and free_loco.last_error == &"movement_world_invalid",
		"attaching an invalid world fails closed")
	check(not free_loco.attach_movement_world(ZMovementWorld2D.new())
			and free_loco.last_error == &"movement_world_invalid",
		"attaching an unconfigured world fails closed")


func _run_sawmill_raid() -> Dictionary:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "movement", "sawmill_raid"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"movement_profile", &"player")
	var authority := RaidAuthority.new()
	var configured := authority.configure(raid, admission, 303)
	assert(configured)
	var gen := authority.generation()

	var layout := load("res://game/world/sawmill/sawmill_yard_layout.tres") as Resource
	var world := ZMovementWorldBuilder.build_from_sawmill_layout(layout, gen)
	var loco := Locomotion.new()
	loco.configure(admission.actor_id, Vector2(500.0, 160.0))
	check(loco.attach_movement_world(world, Vector2(8, 8)),
		"sawmill movement world attaches to locomotion")
	check(loco.register_with_authority(authority, gen),
		"locomotion registers with the raid authority")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, gen), "authority activates")

	var adapter := IntentAdapter.new()
	adapter.configure(admission.session_id, admission.actor_id, admission.authority_epoch, gen)
	for tick in range(1, 35):
		var move := Vector2(1.0, 1.0) if tick > 24 else Vector2(1.0, 0.0)
		var intent := adapter.build_movement_intent(tick, move)
		check(authority.enqueue_intent(intent, gen), "sawmill intent tick %d admitted" % tick)
	for tick in range(1, 35):
		authority.clock.step(1)
		check(authority.advance_one(gen), "sawmill authority advances tick %d" % tick)

	return {
		"actor_id": admission.actor_id,
		"authority": authority,
		"generation": gen,
		"locomotion": loco,
		"world": world,
	}


func _test_raid_authority_sawmill_integration() -> void:
	# Builder validation against the authored layout resource.
	var layout := load("res://game/world/sawmill/sawmill_yard_layout.tres") as Resource
	var obstacle_count := 0
	for row in layout.structures:
		if String(row.get("layer", "")) == "Obstacles":
			obstacle_count += 1
	check(obstacle_count > 0, "authored layout exposes Obstacles structures")
	var built := ZMovementWorldBuilder.build_from_sawmill_layout(layout, 9)
	check(built != null and built.collider_count() == obstacle_count,
		"builder injects exactly the Obstacles-layer structures (%d)" % obstacle_count)
	var built_bounds := built.bounds_px()
	check(absf(built_bounds.size.x - 1280.0) < 0.001 and absf(built_bounds.size.y - 640.0) < 0.001,
		"builder bounds match the 40x20 cell world rect")
	check(ZMovementWorldBuilder.build_from_sawmill_layout(null, 9) == null
			and ZMovementWorldBuilder.last_error == &"layout_missing",
		"builder rejects a missing layout")
	check(ZMovementWorldBuilder.build_from_sawmill_layout(Resource.new(), 9) == null
			and ZMovementWorldBuilder.last_error == &"layout_api_invalid",
		"builder rejects a resource without the layout API")

	# Full authority loop against the real authored geometry.
	var run := _run_sawmill_raid()
	var authority: RaidAuthority = run["authority"]
	var gen: int = run["generation"]
	var loco: Locomotion = run["locomotion"]
	var world: ZMovementWorld2D = run["world"]

	check(authority.last_processed_tick == 34, "authority processed all 34 ticks")
	check(loco.position_px.x == 536.0,
		"player converges flush against mill_west_wall (544-8 px)")
	var result := loco.last_movement_result()
	check(result != null and result.blocked_x(),
		"final locomotion result reports the blocked axis")
	check(result.blocking_collider_ids == PackedStringArray([
			"zerkov.structure.sawmill.mill_west_wall",
		]), "blocked id is the stable authored sawmill structure id")
	check(loco.position_px.y > 160.0,
		"player wall-slides south along the mill wall after the block")
	check(bool(loco.get_snapshot()["pose_published"]),
		"resolved pose was published to the authority during MOVEMENT")
	check(world.corrections_snapshot_for(run["actor_id"]).size() > 0,
		"movement world recorded corrections for the raid actor")
	check(not authority.state_digest().is_empty(), "authority digest is available")

	# Teardown: late calls against the torn-down raid are inert.
	check(authority.teardown(gen), "authority tears down")
	check(not authority.advance_one(gen), "torn-down authority cannot advance")
	check(loco.seal_movement_world(), "composition seals the movement world at teardown")
	var before := loco.position_px
	loco.step_tick(35, Vector2(1.0, 0.0))
	check(loco.position_px == before and loco.last_error == &"movement_world_sealed",
		"late locomotion step against the sealed raid world is inert")

