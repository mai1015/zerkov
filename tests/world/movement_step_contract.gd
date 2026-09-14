extends SceneTree
## Pure movement contract: no scene mounting, resizing, capture, or UI fixtures.
## Native execution is REQUIRED before this candidate can be accepted.
## godot --headless --path . --script res://tests/world/movement_step_contract.gd

const Step = preload("res://game/world/movement/z_movement_step_2d.gd")
const WORLD := Rect2i(0, 0, 10_000, 10_000)
const HALF := Vector2i(250, 250)
const WALL := Rect2i(4_000, 1_000, 100, 8_000)
var checks: int = 0
var failures: int = 0
var scenarios: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("MOVEMENT_STEP: " + message)


func _step(p: Vector2i, axis: Vector2i, blocks: Array[Rect2i] = [],
		v: Vector2i = Vector2i.ZERO, acceleration: int = 1_000) -> Dictionary:
	return Step.resolve(p, v, axis, HALF, WORLD, blocks, 1_000, acceleration)


func _run() -> void:
	_test_acceleration_and_braking()
	_test_analog_and_diagonal()
	_test_sweeps_and_slide()
	_test_world_contact()
	_test_invalid_input()
	_test_order_and_no_aliases()
	_test_replay()
	_test_scalar_boundaries()
	print("MOVEMENT_STEP_RESULT scenarios=", scenarios, " checks=", checks,
		" failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_acceleration_and_braking() -> void:
	scenarios += 2
	var r := _step(Vector2i(1_000, 1_000), Vector2i(1_000, 0), [], Vector2i.ZERO, 100)
	_check(r.get("ok", false), "cardinal acceleration admitted")
	_check(r.get("position_raw") == Vector2i(1_100, 1_000), "one tick acceleration")
	_check(r.get("velocity_raw") == Vector2i(100, 0), "velocity is per tick")
	r = _step(Vector2i(1_000, 1_000), Vector2i.ZERO, [], Vector2i(100, 0), 50)
	_check(r.get("position_raw") == Vector2i(1_050, 1_000), "zero axes brake rather than teleport")
	_check(r.get("velocity_raw") == Vector2i(50, 0), "braking approaches zero")


func _test_analog_and_diagonal() -> void:
	scenarios += 2
	var r := _step(Vector2i(1_000, 1_000), Vector2i(500, 0))
	_check(r.get("velocity_raw") == Vector2i(500, 0), "analog magnitude preserved")
	r = _step(Vector2i(1_000, 1_000), Vector2i(1_000, 1_000))
	var velocity: Vector2i = r.get("velocity_raw", Vector2i.ZERO)
	_check(velocity.x == velocity.y and velocity.x > 0, "diagonal is symmetric")
	_check(velocity.x * velocity.x + velocity.y * velocity.y <= 1_000_000,
		"diagonal cannot exceed the radial speed limit")


func _test_sweeps_and_slide() -> void:
	scenarios += 5
	var blocks: Array[Rect2i] = [WALL]
	var r := _step(Vector2i(3_500, 5_000), Vector2i(1_000, 0), blocks)
	_check(r.get("position_raw") == Vector2i(3_750, 5_000), "right sweep stops at contact")
	_check(r.get("blocked_x", false) and r.get("velocity_raw") == Vector2i.ZERO,
		"blocked velocity is cleared")
	r = _step(Vector2i(5_000, 5_000), Vector2i(-1_000, 0), blocks)
	_check(r.get("position_raw") == Vector2i(4_350, 5_000), "left sweep stops at contact")
	var thin: Array[Rect2i] = [Rect2i(4_000, 1_000, 1, 8_000)]
	r = _step(Vector2i(3_500, 5_000), Vector2i(1_000, 0), thin)
	_check(r.get("position_raw") == Vector2i(3_750, 5_000), "one-unit wall cannot be tunneled")
	r = _step(Vector2i(3_500, 5_000), Vector2i(1_000, 1_000), blocks)
	var p: Vector2i = r.get("position_raw", Vector2i.ZERO)
	_check(p.x == 3_750 and p.y > 5_000, "remaining axis slides along the wall")
	_check(r.get("blocked_x", false) and not r.get("blocked_y", true), "slide flags are distinct")
	r = _step(Vector2i(3_750, 5_000), Vector2i(-1_000, 0), blocks)
	_check(r.get("position_raw") == Vector2i(2_750, 5_000), "contact permits movement away")


func _test_world_contact() -> void:
	scenarios += 2
	var r := _step(Vector2i(9_500, 9_500), Vector2i(1_000, 1_000))
	_check(r.get("position_raw") == Vector2i(9_750, 9_750), "whole body remains inside bounds")
	_check(r.get("blocked_x", false) and r.get("blocked_y", false), "corner blocks both axes")
	r = Step.resolve(Vector2i(250, 250), Vector2i.ZERO, Vector2i(1_000, 0),
		HALF, Rect2i(0, 0, 500, 500), [], 1_000, 1_000)
	_check(r.get("position_raw") == Vector2i(250, 250), "exact body-sized world is valid")
	_check(r.get("blocked_x", false), "body-sized world admits no translation")


func _test_invalid_input() -> void:
	scenarios += 7
	var p := Vector2i(1_000, 1_000)
	var r := _step(p, Vector2i(1_001, 0))
	_check(not r.get("ok", true), "oversized axis rejected")
	r = _step(p, Vector2i(-2_147_483_648, 0))
	_check(not r.get("ok", true), "minimum int32 axis rejected before products")
	r = _step(p, Vector2i.ZERO, [], Vector2i(1_000, 1_000))
	_check(not r.get("ok", true), "overspeed diagonal input velocity rejected")
	r = _step(Vector2i(4_000, 5_000), Vector2i.ZERO, [WALL])
	_check(r.get("reason") == &"body_initially_overlapping", "penetration rejected without depenetration")
	r = _step(Vector2i(0, 0), Vector2i.ZERO)
	_check(r.get("reason") == &"body_outside_world", "invalid spawn rejected")
	r = _step(p, Vector2i.ZERO, [Rect2i(5_000, 5_000, 0, 100)])
	_check(r.get("reason") == &"invalid_movement_blocker", "empty blocker rejected")
	var too_many: Array[Rect2i] = []
	too_many.resize(Step.MAX_BLOCKERS + 1)
	too_many.fill(Rect2i(8_000, 8_000, 10, 10))
	r = _step(p, Vector2i.ZERO, too_many)
	_check(r.get("reason") == &"movement_blocker_budget_exceeded", "bounded work enforced")
	_check(r.is_read_only(), "failure receipt is read-only")


func _test_order_and_no_aliases() -> void:
	scenarios += 2
	var a: Array[Rect2i] = [WALL, Rect2i(6_000, 1_000, 100, 8_000)]
	var original: Array[Rect2i] = a.duplicate()
	var b: Array[Rect2i] = [a[1], a[0]]
	var first := _step(Vector2i(3_500, 5_000), Vector2i(1_000, 0), a)
	var second := _step(Vector2i(3_500, 5_000), Vector2i(1_000, 0), b)
	_check(first == second, "blocker enumeration order does not change the result")
	_check(a == original, "input geometry remains unchanged")
	_check(first.is_read_only(), "success projection candidate is read-only")
	a.clear()
	_check(first.get("position_raw") == Vector2i(3_750, 5_000), "receipt has no geometry alias")


func _replay() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var p := Vector2i(1_000, 1_000)
	var v := Vector2i.ZERO
	var axes: Array[Vector2i] = [Vector2i(1_000, 0), Vector2i(0, 1_000),
		Vector2i(-1_000, 0), Vector2i(0, -1_000), Vector2i.ZERO]
	for tick in range(120):
		var r := _step(p, axes[tick % axes.size()], [WALL], v, 150)
		if not r.get("ok", false):
			_check(false, "replay encountered an invalid resolved position")
			return []
		records.append(r)
		p = r["position_raw"]
		v = r["velocity_raw"]
	return records


func _test_replay() -> void:
	scenarios += 1
	var first := _replay()
	var second := _replay()
	_check(first.size() == 120 and second.size() == 120, "both replays completed")
	_check(first == second, "identical accepted samples produce identical step records")


func _test_scalar_boundaries() -> void:
	scenarios += 3
	var r := Step.resolve(Vector2i(-5_000, -5_000), Vector2i.ZERO,
		Vector2i(-1_000, 0), HALF, Rect2i(-10_000, -10_000, 10_000, 10_000), [], 1_000, 1_000)
	_check(r.get("position_raw") == Vector2i(-6_000, -5_000), "negative coordinates resolve exactly")
	r = Step.resolve(Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO, HALF,
		Rect2i(Step.LIMIT, 0, 1, 1), [], 1_000, 1_000)
	_check(r.get("reason") == &"invalid_world_bounds", "endpoint rejected before Vector2i overflow")
	_check(Step._ceil_sqrt(2_000_000_000_000) == 1_414_214, "bounded integer sqrt at maximum input")
