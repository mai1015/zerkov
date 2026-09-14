class_name ZMovementStep2D
extends RefCounted
## Pure, integer-only candidate for one authoritative movement step.
## Not an authority, clock, intent-admission service, or scene controller.
## Positions/extents use ZWorldUnits canonical microunits. Velocity and speed
## use those units per RaidAuthority tick; acceleration is per component/tick.
## The owner must validate the intent, invoke once in MOVEMENT, commit once,
## and publish a detached projection. No presentation caller may commit it.
## Static AABBs only. X-then-Y sweep order is deliberate and replay-stable.

const AXIS_SCALE: int = 1_000
const MAX_STEP_RAW: int = 1_000_000
const MAX_HALF_EXTENT_RAW: int = 1_000_000
const MAX_BLOCKERS: int = 2_048
const LIMIT: int = ZWorldUnits.MAX_VISION_CANONICAL_RAW


static func resolve(
	position_raw: Vector2i,
	velocity_raw: Vector2i,
	axes: Vector2i,
	half_extent_raw: Vector2i,
	world_raw: Rect2i,
	blockers_raw: Array[Rect2i],
	speed_raw: int,
	acceleration_raw: int
) -> Dictionary:
	if speed_raw < 1 or speed_raw > MAX_STEP_RAW \
			or acceleration_raw < 1 or acceleration_raw > MAX_STEP_RAW:
		return _failure(&"invalid_movement_limits")
	if absi(axes.x) > AXIS_SCALE or absi(axes.y) > AXIS_SCALE:
		return _failure(&"invalid_movement_axes")
	if half_extent_raw.x < 1 or half_extent_raw.y < 1 \
			or half_extent_raw.x > MAX_HALF_EXTENT_RAW \
			or half_extent_raw.y > MAX_HALF_EXTENT_RAW:
		return _failure(&"invalid_body_extent")
	if not _rect_is_bounded(world_raw):
		return _failure(&"invalid_world_bounds")
	if not _velocity_is_bounded(velocity_raw, speed_raw):
		return _failure(&"invalid_movement_velocity")
	if blockers_raw.size() > MAX_BLOCKERS:
		return _failure(&"movement_blocker_budget_exceeded")
	if not _inside_world(position_raw, half_extent_raw, world_raw):
		return _failure(&"body_outside_world")
	for obstacle in blockers_raw:
		if not _rect_is_bounded(obstacle):
			return _failure(&"invalid_movement_blocker")
		if _overlaps(position_raw, half_extent_raw, obstacle):
			return _failure(&"body_initially_overlapping")

	var divisor: int = maxi(AXIS_SCALE, _ceil_sqrt(_squared(axes)))
	var target := Vector2i(
		_divide(axes.x * speed_raw, divisor),
		_divide(axes.y * speed_raw, divisor)
	)
	var desired := Vector2i(
		velocity_raw.x + clampi(target.x - velocity_raw.x,
			-acceleration_raw, acceleration_raw),
		velocity_raw.y + clampi(target.y - velocity_raw.y,
			-acceleration_raw, acceleration_raw)
	)
	desired = _limit_speed(desired, speed_raw)

	# Keep intermediate additions in scalar int (64-bit), not Vector2i.
	var x: int = clampi(int(position_raw.x) + int(desired.x),
		int(world_raw.position.x) + int(half_extent_raw.x),
		int(world_raw.position.x) + int(world_raw.size.x) - int(half_extent_raw.x))
	for obstacle in blockers_raw:
		if not _intervals_overlap(
			int(position_raw.y) - int(half_extent_raw.y),
			int(position_raw.y) + int(half_extent_raw.y),
			obstacle.position.y, int(obstacle.position.y) + int(obstacle.size.y)
		):
			continue
		var left: int = obstacle.position.x
		var right: int = int(obstacle.position.x) + int(obstacle.size.x)
		if desired.x > 0 and int(position_raw.x) + int(half_extent_raw.x) <= left:
			x = mini(x, left - int(half_extent_raw.x))
		elif desired.x < 0 and int(position_raw.x) - int(half_extent_raw.x) >= right:
			x = maxi(x, right + int(half_extent_raw.x))

	var y: int = clampi(int(position_raw.y) + int(desired.y),
		int(world_raw.position.y) + int(half_extent_raw.y),
		int(world_raw.position.y) + int(world_raw.size.y) - int(half_extent_raw.y))
	for obstacle in blockers_raw:
		if not _intervals_overlap(
			x - int(half_extent_raw.x), x + int(half_extent_raw.x),
			obstacle.position.x, int(obstacle.position.x) + int(obstacle.size.x)
		):
			continue
		var top: int = obstacle.position.y
		var bottom: int = int(obstacle.position.y) + int(obstacle.size.y)
		if desired.y > 0 and int(position_raw.y) + int(half_extent_raw.y) <= top:
			y = mini(y, top - int(half_extent_raw.y))
		elif desired.y < 0 and int(position_raw.y) - int(half_extent_raw.y) >= bottom:
			y = maxi(y, bottom + int(half_extent_raw.y))

	var position := Vector2i(x, y)
	var actual := position - position_raw
	var blocked_x: bool = actual.x != desired.x
	var blocked_y: bool = actual.y != desired.y
	# Everything below is a value type; no nested mutable containers escape.
	var result: Dictionary = {
		"ok": true,
		"reason": StringName(),
		"position_raw": position,
		"velocity_raw": Vector2i(0 if blocked_x else desired.x, 0 if blocked_y else desired.y),
		"requested_step_raw": desired,
		"resolved_step_raw": actual,
		"blocked_x": blocked_x,
		"blocked_y": blocked_y,
	}
	result.make_read_only()
	return result


static func _rect_is_bounded(rect: Rect2i) -> bool:
	# Check endpoints as scalar ints before any Vector2i endpoint arithmetic.
	return rect.size.x > 0 and rect.size.y > 0 \
		and rect.size.x <= LIMIT and rect.size.y <= LIMIT \
		and absi(rect.position.x) <= LIMIT and absi(rect.position.y) <= LIMIT \
		and absi(int(rect.position.x) + int(rect.size.x)) <= LIMIT \
		and absi(int(rect.position.y) + int(rect.size.y)) <= LIMIT


static func _inside_world(p: Vector2i, h: Vector2i, world: Rect2i) -> bool:
	return int(p.x) - int(h.x) >= world.position.x \
		and int(p.y) - int(h.y) >= world.position.y \
		and int(p.x) + int(h.x) <= int(world.position.x) + int(world.size.x) \
		and int(p.y) + int(h.y) <= int(world.position.y) + int(world.size.y)


static func _intervals_overlap(a_min: int, a_max: int, b_min: int, b_max: int) -> bool:
	# Touching is valid contact, not penetration.
	return a_min < b_max and a_max > b_min


static func _overlaps(p: Vector2i, h: Vector2i, rect: Rect2i) -> bool:
	return _intervals_overlap(int(p.x) - int(h.x), int(p.x) + int(h.x),
		rect.position.x, int(rect.position.x) + int(rect.size.x)) \
		and _intervals_overlap(int(p.y) - int(h.y), int(p.y) + int(h.y),
			rect.position.y, int(rect.position.y) + int(rect.size.y))


static func _velocity_is_bounded(value: Vector2i, speed: int) -> bool:
	# Bound components before squaring; reject hostile int32 extremes safely.
	return absi(value.x) <= speed and absi(value.y) <= speed \
		and _squared(value) <= speed * speed


static func _squared(value: Vector2i) -> int:
	return int(value.x) * int(value.x) + int(value.y) * int(value.y)


static func _limit_speed(value: Vector2i, speed: int) -> Vector2i:
	var squared: int = _squared(value)
	if squared <= speed * speed:
		return value
	var length: int = _ceil_sqrt(squared)
	return Vector2i(_divide(value.x * speed, length), _divide(value.y * speed, length))


static func _ceil_sqrt(value: int) -> int:
	# All callers bound components to MAX_STEP_RAW before squaring.
	# Fixed upper bound avoids overflow and bounds this search to 21 steps.
	var low: int = 0
	var high: int = MAX_STEP_RAW * 2
	while low < high:
		var middle: int = _divide(low + high, 2)
		if middle * middle < value:
			low = middle + 1
		else:
			high = middle
	return low


static func _divide(numerator: int, denominator: int) -> int:
	@warning_ignore("integer_division")
	return numerator / denominator


static func _failure(reason: StringName) -> Dictionary:
	var result: Dictionary = {"ok": false, "reason": reason}
	result.make_read_only()
	return result
