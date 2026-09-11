extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/units_clock_contract.gd

const WorldUnits = preload("res://game/domain/z_world_units.gd")
const Clock = preload("res://game/raid/raid_clock.gd")
const RaidRng = preload("res://game/raid/raid_rng.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("UNITS_CLOCK_CONTRACT: " + message)


func run() -> void:
	_test_units()
	_test_clock()
	print("UNITS_CLOCK_CONTRACT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_units() -> void:
	var canonical := WorldUnits.godot_to_canonical(Vector2(32.0, -64.0))
	check(canonical.ok and canonical.vector2i_value == Vector2i(1_000_000, -2_000_000),
		"32 px equals one canonical world unit")
	var weapon := WorldUnits.godot_to_weapon(Vector2(32.0, -64.0))
	check(weapon.ok and weapon.vector2i_value == Vector2i(1000, -2000),
		"32 px equals 1000 weapon milliunits")
	var weapon_direction := WorldUnits.godot_direction_to_weapon(Vector2(3.0, 4.0))
	check(weapon_direction.ok
		and weapon_direction.vector2i_value == Vector2i(600_000, 800_000),
		"weapon aim is normalized to the fixed one-million direction scale")
	var negative_direction := WorldUnits.godot_direction_to_weapon(Vector2(-1.0, 0.0))
	check(negative_direction.ok
		and negative_direction.vector2i_value == Vector2i(-1_000_000, 0),
		"negative weapon aim preserves direction after normalization")
	check(not WorldUnits.godot_direction_to_weapon(Vector2.ZERO).ok,
		"zero weapon aim fails closed")
	var far_shared_point := Vector2(100_000.0, -100_000.0)
	check(WorldUnits.MAX_GODOT_COORDINATE_PX == 1_048_576.0
		and WorldUnits.MAX_CANONICAL_RAW == 32_768_000_000,
		"shared world limits retain the accepted units contract")
	var far_weapon := WorldUnits.godot_to_weapon(far_shared_point)
	check(far_weapon.ok
		and far_weapon.vector2i_value == Vector2i(3_125_000, -3_125_000),
		"shared weapon conversion retains the accepted 100,000px domain")
	var far_weapon_round_trip := WorldUnits.weapon_to_godot(
		far_weapon.vector2i_value
	)
	check(far_weapon_round_trip.ok
		and far_weapon_round_trip.vector2_value == far_shared_point,
		"shared weapon conversion round-trips 100,000px")
	var restored := WorldUnits.canonical_to_godot(canonical.vector2i_value)
	check(restored.ok and restored.vector2_value.is_equal_approx(Vector2(32.0, -64.0)),
		"canonical coordinates round-trip")
	var tile := WorldUnits.godot_to_tile(Vector2(-0.1, 63.9))
	check(tile.ok and tile.vector2i_value == Vector2i(-1, 1), "tile conversion floors negatives")
	var far_tile := WorldUnits.godot_to_tile(far_shared_point)
	check(far_tile.ok and far_tile.vector2i_value == Vector2i(3125, -3125),
		"shared tile conversion retains the accepted 100,000px domain")
	var far_tile_origin := WorldUnits.tile_origin_to_godot(far_tile.vector2i_value)
	check(far_tile_origin.ok and far_tile_origin.vector2_value == far_shared_point,
		"shared tile origin round-trips 100,000px")
	var center := WorldUnits.tile_center_to_godot(Vector2i(-1, 2))
	check(center.ok and center.vector2_value == Vector2(-16.0, 80.0), "tile center is stable")
	var half_pixel := 0.5 * WorldUnits.GODOT_PIXELS_PER_WORLD_UNIT / float(
		WorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT
	)
	check(WorldUnits.godot_to_canonical(Vector2(half_pixel, 0.0)).vector2i_value.x == 1,
		"positive half rounds away from zero")
	check(WorldUnits.godot_to_canonical(Vector2(-half_pixel, 0.0)).vector2i_value.x == -1,
		"negative half rounds away from zero")
	check(not WorldUnits.godot_to_canonical(Vector2(NAN, 0.0)).ok, "NaN is rejected")
	check(not WorldUnits.godot_to_canonical(Vector2(INF, 0.0)).ok, "infinity is rejected")
	check(not WorldUnits.godot_to_canonical(Vector2(2_000_000.0, 0.0)).ok,
		"out-of-bounds position is rejected")
	var boundary := WorldUnits.godot_to_canonical(Vector2(
		WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
		-WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
	))
	check(boundary.ok and boundary.vector2i_value == Vector2i(
		WorldUnits.MAX_VISION_CANONICAL_RAW,
		-WorldUnits.MAX_VISION_CANONICAL_RAW,
	), "exact signed safe boundary converts without Vector2i wrap")
	var restored_boundary := WorldUnits.canonical_to_godot(boundary.vector2i_value)
	check(restored_boundary.ok and restored_boundary.vector2_value == Vector2(
		WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
		-WorldUnits.MAX_VISION_GODOT_COORDINATE_PX,
	), "exact signed safe boundary round-trips")
	var outside := WorldUnits.godot_to_canonical(Vector2(
		WorldUnits.MAX_VISION_GODOT_COORDINATE_PX + 1.0,
		17.0,
	))
	check(not outside.ok and outside.vector2i_value == Vector2i.ZERO,
		"one pixel outside rejects without a wrapped or partial result")
	check(not WorldUnits.canonical_to_godot(Vector2i(
		WorldUnits.MAX_VISION_CANONICAL_RAW + 1,
		0,
	)).ok, "one canonical raw unit outside rejects before float conversion")
	var damage := WorldUnits.weapon_damage_to_ability(42_500)
	check(damage.ok and damage.integer_value == 42_500_000,
		"weapon damage converts exactly to ability fixed units")
	var minimum_int: int = -9_223_372_036_854_775_807 - 1
	check(not WorldUnits.weapon_damage_to_ability(minimum_int).ok,
		"minimum signed integer damage is rejected without absolute-value overflow")
	var first_rng := RaidRng.new(minimum_int)
	var second_rng := RaidRng.new(minimum_int)
	check(first_rng.state > 0 and first_rng.state < RaidRng.MODULUS
		and first_rng.next_int(1000) == second_rng.next_int(1000),
		"minimum signed integer seed normalizes deterministically")


func _test_clock() -> void:
	var clock := Clock.new()
	check(clock.current_tick == 0 and clock.paused, "clock starts paused at tick zero")
	check(clock.request_ticks(10) == 10, "clock accepts bounded scheduled ticks")
	check(clock.drain_catch_up().is_empty(), "paused clock does not drain")
	var stepped := clock.step(2)
	check(stepped == PackedInt64Array([1, 2]), "paused clock steps exact ticks")
	check(clock.pending_ticks == 10, "stepping does not consume scheduled catch-up")
	clock.resume()
	check(clock.step(1).is_empty(), "running clock cannot use debug step")
	var first_drain := clock.drain_catch_up(99)
	check(first_drain == PackedInt64Array([3, 4, 5, 6, 7, 8, 9, 10]),
		"catch-up is capped at eight ticks per drain")
	check(clock.pending_ticks == 2, "catch-up backlog remains explicit")
	check(clock.drain_catch_up() == PackedInt64Array([11, 12]), "remaining ticks drain in order")
	check(clock.request_ticks(300) == Clock.MAX_PENDING_TICKS,
		"pending queue has a hard bound")
	check(clock.rejected_ticks == 60, "overflowing scheduled ticks are accounted for")
	clock.pause()
	check(clock.drain_catch_up().is_empty(), "pause freezes pending ticks")
	check(not clock.reset(-1), "negative reset tick is rejected")
	check(clock.current_tick == 12, "rejected reset is fail-atomic")
	clock.seal()
	check(clock.is_sealed() and clock.paused and clock.pending_ticks == 0,
		"sealing freezes and clears the clock")
	check(clock.request_ticks(1) == 0 and clock.step(1).is_empty()
		and not clock.reset(0), "sealed clock APIs cannot advance or reset authority time")
