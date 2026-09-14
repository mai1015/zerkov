class_name ZMovementWorld2D
extends RefCounted
## Server-authoritative deterministic 2D movement, collision and correction.
##
## Pure simulation module. Blocking geometry and the level bounds are injected
## by the caller (see ZMovementWorldBuilder); this world never loads a scene or
## resource. Bodies are axis-aligned boxes keyed by ZEntityId, resolved on the
## fixed 60 Hz tick in exact integer microunits (ZWorldUnits canonical space).
## There is no physics server, no move_and_slide, no PhysicsDirectSpaceState2D,
## no render or physics frame timing and no wall clock anywhere in this file.
##
## Authority rule: when an intent's implied displacement disagrees with the
## resolved displacement, the resolved position wins. The bounded correction
## log records every disagreement so presentation can converge; it exposes
## read-only snapshots only, so presentation can never write movement state
## back through it.

const TICK_RATE: int = RaidClock.TICK_RATE
const SECONDS_PER_TICK: float = 1.0 / float(RaidClock.TICK_RATE)
## 1 Godot px = 31,250 microunits, derived from the published ZWorldUnits
## constants; no second conversion relation is introduced here.
const MICRO_PER_PX: float = float(ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT) \
		/ float(ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT)
const MAX_CORRECTION_RECORDS: int = 64
const MAX_STATIC_COLLIDERS: int = 512

var last_error: StringName = &""
var _generation: int = -1
var _sealed: bool = false
var _configured: bool = false
var _bounds_min_micro: Vector2i = Vector2i.ZERO
var _bounds_max_micro: Vector2i = Vector2i.ZERO
var _bounds_collider_id: String = ""
var _colliders: Array[Dictionary] = []
var _collider_ids: Dictionary = {}
var _bodies: Dictionary = {}
var _corrections: Array[Dictionary] = []


func configure(
	bounds_px: Rect2,
	expected_generation: int,
	bounds_collider_id: String = ""
) -> bool:
	last_error = &""
	if _configured:
		last_error = &"world_already_configured"
		return false
	if expected_generation < 0:
		last_error = &"generation_invalid"
		return false
	if not _is_finite_point(bounds_px.position) or not _is_finite_point(bounds_px.end):
		last_error = &"bounds_invalid"
		return false
	if bounds_px.size.x <= 0.0 or bounds_px.size.y <= 0.0:
		last_error = &"bounds_invalid"
		return false
	var min_conversion := ZWorldUnits.godot_to_canonical(bounds_px.position)
	var max_conversion := ZWorldUnits.godot_to_canonical(bounds_px.end)
	if not min_conversion.ok or not max_conversion.ok:
		last_error = &"bounds_invalid"
		return false
	_bounds_min_micro = min_conversion.vector2i_value
	_bounds_max_micro = max_conversion.vector2i_value
	_bounds_collider_id = bounds_collider_id
	_generation = expected_generation
	_configured = true
	return true


## Free-space world spanning the full canonical (Vision) coordinate range.
## Used by ZPlayerLocomotion as its default resolution space so that a
## locomotion instance never performs an unchecked integration step.
func configure_open_world(expected_generation: int) -> bool:
	last_error = &""
	if _configured:
		last_error = &"world_already_configured"
		return false
	if expected_generation < 0:
		last_error = &"generation_invalid"
		return false
	_bounds_min_micro = Vector2i(
		-ZWorldUnits.MAX_VISION_CANONICAL_RAW,
		-ZWorldUnits.MAX_VISION_CANONICAL_RAW
	)
	_bounds_max_micro = Vector2i(
		ZWorldUnits.MAX_VISION_CANONICAL_RAW,
		ZWorldUnits.MAX_VISION_CANONICAL_RAW
	)
	_bounds_collider_id = ""
	_generation = expected_generation
	_configured = true
	return true


func is_configured() -> bool:
	return _configured


func generation() -> int:
	return _generation


func is_sealed() -> bool:
	return _sealed


func collider_count() -> int:
	return _colliders.size()


func bounds_px() -> Rect2:
	if not _configured:
		return Rect2()
	var min_point := ZWorldUnits.canonical_to_godot(_bounds_min_micro)
	var max_point := ZWorldUnits.canonical_to_godot(_bounds_max_micro)
	if not min_point.ok or not max_point.ok:
		return Rect2()
	return Rect2(min_point.vector2_value, max_point.vector2_value - min_point.vector2_value)


## Injects one static blocking rect authored in Godot px.
func add_static_collider_px(
	collider_id: String,
	rect_px: Rect2,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _fail(&"stale_generation")
	if collider_id.is_empty():
		return _fail(&"collider_id_invalid")
	if _collider_ids.has(collider_id):
		return _fail(&"collider_id_duplicate")
	if _colliders.size() >= MAX_STATIC_COLLIDERS:
		return _fail(&"collider_limit")
	if not _is_finite_point(rect_px.position) or not _is_finite_point(rect_px.end):
		return _fail(&"collider_rect_invalid")
	if rect_px.size.x <= 0.0 or rect_px.size.y <= 0.0:
		return _fail(&"collider_rect_invalid")
	var min_conversion := ZWorldUnits.godot_to_canonical(rect_px.position)
	var max_conversion := ZWorldUnits.godot_to_canonical(rect_px.end)
	if not min_conversion.ok or not max_conversion.ok:
		return _fail(&"collider_rect_invalid")
	return _insert_collider(collider_id, min_conversion.vector2i_value, max_conversion.vector2i_value)


## Injects one static blocking rect authored in level cells (1 cell = 1 tile =
## 32 px, per ZWorldUnits.SOURCE_TILE_PIXELS). ZMovementWorldBuilder uses this
## entry point; conversion stays inside the module instead of at call sites.
func add_static_collider_cells(
	collider_id: String,
	rect_cells: Rect2i,
	expected_generation: int
) -> bool:
	var tile := ZWorldUnits.SOURCE_TILE_PIXELS
	return add_static_collider_px(
		collider_id,
		Rect2(
			Vector2(rect_cells.position) * float(tile),
			Vector2(rect_cells.size) * float(tile)
		),
		expected_generation
	)


## Registers one authoritative body. The spawn must be free of static geometry
## and fully inside the level bounds; fail-closed keeps late or replayed
## registration against a replaced raid inert.
func register_actor(
	actor_id: ZEntityId,
	position_px: Vector2,
	half_extents_px: Vector2,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _fail(&"stale_generation")
	var key := _actor_key(actor_id)
	if key.is_empty():
		return _fail(&"actor_id_invalid")
	if _bodies.has(key):
		return _fail(&"actor_already_registered")
	if not _is_finite_point(position_px) \
			or not _is_finite_point(half_extents_px) \
			or half_extents_px.x <= 0.0 or half_extents_px.y <= 0.0:
		return _fail(&"body_shape_invalid")
	var conversion := ZWorldUnits.godot_to_canonical(position_px)
	if not conversion.ok:
		return _fail(&"position_invalid")
	var position_micro := conversion.vector2i_value
	var half_micro := Vector2i(
		_round_half_away_from_zero(half_extents_px.x * MICRO_PER_PX),
		_round_half_away_from_zero(half_extents_px.y * MICRO_PER_PX)
	)
	if not _body_inside_bounds(position_micro, half_micro):
		return _fail(&"actor_out_of_bounds")
	if _body_overlaps_any_collider(position_micro, half_micro):
		return _fail(&"actor_spawn_blocked")
	_bodies[key] = {
		"actor": key,
		"half": half_micro,
		"pos": position_micro,
		"tick": 0,
	}
	return true


func has_actor(actor_id: ZEntityId) -> bool:
	return _bodies.has(_actor_key(actor_id))


func actor_count() -> int:
	return _bodies.size()


func actor_position_px(actor_id: ZEntityId) -> Vector2:
	var body := _bodies.get(_actor_key(actor_id)) as Dictionary
	if body == null:
		return Vector2.INF
	var conversion := ZWorldUnits.canonical_to_godot(body["pos"])
	return conversion.vector2_value if conversion.ok else Vector2.INF


func actor_position_micro(actor_id: ZEntityId) -> Vector2i:
	var body := _bodies.get(_actor_key(actor_id)) as Dictionary
	return body["pos"] if body != null else Vector2i.ZERO


func actor_last_tick(actor_id: ZEntityId) -> int:
	var body := _bodies.get(_actor_key(actor_id)) as Dictionary
	return int(body["tick"]) if body != null else -1


## Composition-only repositioning (spawn placement, extraction snaps). Same
## validation as registration and subject to the generation contract.
func teleport_actor(
	actor_id: ZEntityId,
	position_px: Vector2,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _fail(&"stale_generation")
	var key := _actor_key(actor_id)
	if key.is_empty():
		return _fail(&"actor_id_invalid")
	var body := _bodies.get(key) as Dictionary
	if body == null:
		return _fail(&"actor_not_registered")
	if not _is_finite_point(position_px):
		return _fail(&"position_invalid")
	var conversion := ZWorldUnits.godot_to_canonical(position_px)
	if not conversion.ok:
		return _fail(&"position_invalid")
	var position_micro := conversion.vector2i_value
	if not _body_inside_bounds(position_micro, body["half"]):
		return _fail(&"actor_out_of_bounds")
	if _body_overlaps_any_collider(position_micro, body["half"]):
		return _fail(&"actor_spawn_blocked")
	body["pos"] = position_micro
	_bodies[key] = body
	return true


## Resolves exactly one authoritative movement step for one actor and tick.
## Locomotion supplies the desired velocity; this world derives the implied
## displacement, clamps it against bounds and static geometry axis by axis
## (X first, then Y — a fixed order), and returns the typed result. Replayed
## ticks, stale generations and sealed worlds are inert failures.
func resolve_actor_step(
	actor_id: ZEntityId,
	tick: int,
	requested_velocity_px: Vector2,
	expected_generation: int
) -> ZMovementResult:
	last_error = &""
	var key := _actor_key(actor_id)
	if not _configured:
		last_error = &"world_unconfigured"
		return ZMovementResult.failure(&"world_unconfigured", tick, key)
	if _sealed:
		last_error = &"world_sealed"
		return ZMovementResult.failure(&"world_sealed", tick, key)
	if expected_generation != _generation:
		last_error = &"stale_generation"
		return ZMovementResult.failure(&"stale_generation", tick, key)
	if key.is_empty():
		last_error = &"actor_id_invalid"
		return ZMovementResult.failure(&"actor_id_invalid", tick, key)
	var body := _bodies.get(key) as Dictionary
	if body == null:
		last_error = &"actor_not_registered"
		return ZMovementResult.failure(&"actor_not_registered", tick, key)
	if tick <= int(body["tick"]):
		last_error = &"tick_regressed"
		return ZMovementResult.failure(&"tick_regressed", tick, key)
	if not _is_finite_point(requested_velocity_px):
		last_error = &"velocity_invalid"
		return ZMovementResult.failure(&"velocity_invalid", tick, key)

	var displacement := _velocity_to_displacement_micro(requested_velocity_px)
	var requested_micro: Vector2i = body["pos"] + displacement
	var resolved_micro := requested_micro
	var blocked_axes: int = 0
	var blocking_ids := PackedStringArray()

	if displacement.x != 0:
		var outcome := _resolve_axis_move(body, true, displacement.x)
		resolved_micro.x = int(outcome["position"])
		if bool(outcome["blocked"]):
			blocked_axes |= ZMovementResult.BLOCKED_AXIS_X
			_append_unique_all(blocking_ids, outcome["ids"])
	if displacement.y != 0:
		var y_body := {
			"half": body["half"],
			"pos": Vector2i(resolved_micro.x, (body["pos"] as Vector2i).y),
		}
		var outcome := _resolve_axis_move(y_body, false, displacement.y)
		resolved_micro.y = int(outcome["position"])
		if bool(outcome["blocked"]):
			blocked_axes |= ZMovementResult.BLOCKED_AXIS_Y
			_append_unique_all(blocking_ids, outcome["ids"])

	blocking_ids.sort()
	var corrected := resolved_micro != requested_micro
	var resolved_velocity := requested_velocity_px
	if (blocked_axes & ZMovementResult.BLOCKED_AXIS_X) != 0:
		resolved_velocity.x = 0.0
	if (blocked_axes & ZMovementResult.BLOCKED_AXIS_Y) != 0:
		resolved_velocity.y = 0.0

	var px_conversion := ZWorldUnits.canonical_to_godot(resolved_micro)
	if not px_conversion.ok:
		last_error = &"resolved_position_out_of_range"
		return ZMovementResult.failure(&"resolved_position_out_of_range", tick, key)

	body["pos"] = resolved_micro
	body["tick"] = tick
	_bodies[key] = body

	if corrected:
		_append_correction(
			tick,
			key,
			requested_micro,
			resolved_micro,
			requested_velocity_px,
			resolved_velocity,
			blocked_axes,
			blocking_ids
		)

	var result := ZMovementResult.new()
	result.ok = true
	result.tick = tick
	result.actor_id = key
	result.requested_position_micro = requested_micro
	result.resolved_position_micro = resolved_micro
	result.resolved_position_px = px_conversion.vector2_value
	result.requested_velocity_px = requested_velocity_px
	result.resolved_velocity_px = resolved_velocity
	result.blocked_axes = blocked_axes
	result.blocking_collider_ids = blocking_ids
	result.corrected = corrected
	return result


func correction_count() -> int:
	return _corrections.size()


## Read-only deep copy for presentation. Mutating the returned value can never
## change world state.
func corrections_snapshot() -> Array[Dictionary]:
	var snapshot: Array[Dictionary] = []
	for record in _corrections:
		snapshot.append(record.duplicate(true))
	return snapshot


func corrections_snapshot_for(actor_id: ZEntityId) -> Array[Dictionary]:
	var key := _actor_key(actor_id)
	var snapshot: Array[Dictionary] = []
	for record in _corrections:
		if String(record["actor_id"]) == key:
			snapshot.append(record.duplicate(true))
	return snapshot


## Terminal teardown. Every later mutating call against this world is inert
## regardless of the generation argument a late caller might present.
func seal(expected_generation: int) -> bool:
	last_error = &""
	if not _configured:
		return _fail(&"world_unconfigured")
	if expected_generation != _generation:
		return _fail(&"stale_generation")
	_sealed = true
	return true


## Integer/fixed-point canonical projection (ZCanonicalValue-compatible).
func canonical_record() -> Dictionary:
	var collider_records: Array = []
	for collider in _colliders:
		collider_records.append({
			"id": String(collider["id"]),
			"min": collider["min"],
			"max": collider["max"],
		})
	var body_records: Array = []
	var body_keys := _bodies.keys()
	body_keys.sort()
	for body_key in body_keys:
		var body: Dictionary = _bodies[body_key]
		body_records.append({
			"actor": String(body["actor"]),
			"half": body["half"],
			"pos": body["pos"],
			"tick": int(body["tick"]),
		})
	return {
		"bounds_id": _bounds_collider_id,
		"bounds_max": _bounds_max_micro,
		"bounds_min": _bounds_min_micro,
		"bodies": body_records,
		"colliders": collider_records,
		"correction_count": _corrections.size(),
		"generation": _generation,
		"last_correction": _corrections.back().duplicate(true) if not _corrections.is_empty() else {},
		"sealed": _sealed,
	}


func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())


func _insert_collider(collider_id: String, min_micro: Vector2i, max_micro: Vector2i) -> bool:
	if min_micro.x >= max_micro.x or min_micro.y >= max_micro.y:
		return _fail(&"collider_rect_invalid")
	var record := {
		"id": collider_id,
		"min": min_micro,
		"max": max_micro,
	}
	# Deterministic ordering: sorted by stable authored id, so collider-id
	# reporting and digest input never depend on injection order.
	var insert_at := _colliders.size()
	for index in _colliders.size():
		if String(_colliders[index]["id"]) > collider_id:
			insert_at = index
			break
	_colliders.insert(insert_at, record)
	_collider_ids[collider_id] = true
	return true


## Axis-separated resolution of one axis. The body may end flush against a
## blocking rect but never overlapping it (strict interval overlap). A blocked
## axis reports every authored collider that actually limited the move.
func _resolve_axis_move(body: Dictionary, axis_is_x: bool, displacement: int) -> Dictionary:
	var half: Vector2i = body["half"]
	var position: Vector2i = body["pos"]
	var start: int = position.x if axis_is_x else position.y
	var half_axis: int = half.x if axis_is_x else half.y
	var bounds_min_axis: int = _bounds_min_micro.x if axis_is_x else _bounds_min_micro.y
	var bounds_max_axis: int = _bounds_max_micro.x if axis_is_x else _bounds_max_micro.y
	var candidate: int = start + displacement
	var blocked := false
	var blocking_ids := PackedStringArray()

	if displacement > 0 and candidate + half_axis > bounds_max_axis:
		candidate = bounds_max_axis - half_axis
		blocked = true
		if not _bounds_collider_id.is_empty():
			blocking_ids.append(_bounds_collider_id)
	elif displacement < 0 and candidate - half_axis < bounds_min_axis:
		candidate = bounds_min_axis + half_axis
		blocked = true
		if not _bounds_collider_id.is_empty():
			blocking_ids.append(_bounds_collider_id)

	for collider in _colliders:
		var collider_min: Vector2i = collider["min"]
		var collider_max: Vector2i = collider["max"]
		if axis_is_x:
			if position.y - half.y >= collider_max.y or position.y + half.y <= collider_min.y:
				continue
		else:
			if position.x - half.x >= collider_max.x or position.x + half.x <= collider_min.x:
				continue
		var collider_lo: int = collider_min.x if axis_is_x else collider_min.y
		var collider_hi: int = collider_max.x if axis_is_x else collider_max.y
		if displacement > 0 and start + half_axis <= collider_lo and candidate + half_axis > collider_lo:
			candidate = mini(candidate, collider_lo - half_axis)
			blocked = true
			blocking_ids.append(String(collider["id"]))
		elif displacement < 0 and start - half_axis >= collider_hi and candidate - half_axis < collider_hi:
			candidate = maxi(candidate, collider_hi + half_axis)
			blocked = true
			blocking_ids.append(String(collider["id"]))

	return {"position": candidate, "blocked": blocked, "ids": blocking_ids}


func _append_correction(
	tick: int,
	actor_key: String,
	requested_micro: Vector2i,
	resolved_micro: Vector2i,
	requested_velocity_px: Vector2,
	resolved_velocity_px: Vector2,
	blocked_axes: int,
	blocking_ids: PackedStringArray
) -> void:
	var collider_ids: Array = []
	for collider_id in blocking_ids:
		collider_ids.append(collider_id)
	_corrections.append({
		"actor_id": actor_key,
		"blocked_axes": blocked_axes,
		"blocking_collider_ids": collider_ids,
		"requested_position_micro": requested_micro,
		"requested_velocity_milli": ZMovementResult.velocity_to_milli(requested_velocity_px),
		"resolved_position_micro": resolved_micro,
		"resolved_velocity_milli": ZMovementResult.velocity_to_milli(resolved_velocity_px),
		"tick": tick,
	})
	if _corrections.size() > MAX_CORRECTION_RECORDS:
		_corrections.pop_front()


func _body_inside_bounds(position_micro: Vector2i, half_micro: Vector2i) -> bool:
	return position_micro.x - half_micro.x >= _bounds_min_micro.x \
			and position_micro.y - half_micro.y >= _bounds_min_micro.y \
			and position_micro.x + half_micro.x <= _bounds_max_micro.x \
			and position_micro.y + half_micro.y <= _bounds_max_micro.y


func _body_overlaps_any_collider(position_micro: Vector2i, half_micro: Vector2i) -> bool:
	for collider in _colliders:
		var collider_min: Vector2i = collider["min"]
		var collider_max: Vector2i = collider["max"]
		if position_micro.x - half_micro.x < collider_max.x \
				and position_micro.x + half_micro.x > collider_min.x \
				and position_micro.y - half_micro.y < collider_max.y \
				and position_micro.y + half_micro.y > collider_min.y:
			return true
	return false


func _velocity_to_displacement_micro(velocity_px: Vector2) -> Vector2i:
	return Vector2i(
		_round_half_away_from_zero(velocity_px.x * MICRO_PER_PX * SECONDS_PER_TICK),
		_round_half_away_from_zero(velocity_px.y * MICRO_PER_PX * SECONDS_PER_TICK)
	)


func _actor_key(actor_id: ZEntityId) -> String:
	return actor_id.canonical_key() if actor_id != null and actor_id.is_initialized() else ""


func _append_unique_all(target: PackedStringArray, additions: PackedStringArray) -> void:
	for addition in additions:
		if not target.has(addition):
			target.append(addition)


func _is_mutable_generation(expected_generation: int) -> bool:
	return _configured and not _sealed and expected_generation == _generation


func _is_finite_point(point: Vector2) -> bool:
	return not is_nan(point.x) and not is_nan(point.y) \
			and not is_inf(point.x) and not is_inf(point.y)


func _round_half_away_from_zero(value: float) -> int:
	var magnitude := absf(value)
	var whole := floori(magnitude)
	var fraction := magnitude - whole
	var rounded := whole + 1 if absf(fraction - 0.5) <= 0.00001 else floori(magnitude + 0.5)
	return rounded if value >= 0.0 else -rounded


func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
