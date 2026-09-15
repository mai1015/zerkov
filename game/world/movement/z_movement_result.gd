class_name ZMovementResult
extends RefCounted
## Typed authoritative movement outcome for exactly one actor and tick.
##
## Produced by ZMovementWorld2D only. It carries the resolved authoritative
## state (position in canonical microunits and Godot px, resolved velocity,
## blocked axes, and the stable authored ids at each final limiting boundary
## (including ties)). Presentation may read a result but never write it back
## into the movement world: the value object holds no reference to world state.

const BLOCKED_AXIS_X: int = 1
const BLOCKED_AXIS_Y: int = 2

## Godot px per world unit and Weapon milliunits per world unit are the only
## published conversion constants; this derived ratio never re-states them.
const _MILLIUNITS_PER_PX: float = float(ZWorldUnits.WEAPON_MILLIUNITS_PER_WORLD_UNIT) \
		/ float(ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT)

var ok: bool = false
var reason: StringName = &""
var tick: int = 0
var actor_id: String = ""
var requested_position_micro: Vector2i = Vector2i.ZERO
var resolved_position_micro: Vector2i = Vector2i.ZERO
var resolved_position_px: Vector2 = Vector2.ZERO
var requested_velocity_px: Vector2 = Vector2.ZERO
var resolved_velocity_px: Vector2 = Vector2.ZERO
var blocked_axes: int = 0
var blocking_collider_ids: PackedStringArray = PackedStringArray()
var corrected: bool = false


static func failure(p_reason: StringName, p_tick: int, p_actor_id: String) -> ZMovementResult:
	var result := ZMovementResult.new()
	result.ok = false
	result.reason = p_reason
	result.tick = p_tick
	result.actor_id = p_actor_id
	return result


func blocked_x() -> bool:
	return (blocked_axes & BLOCKED_AXIS_X) != 0


func blocked_y() -> bool:
	return (blocked_axes & BLOCKED_AXIS_Y) != 0


## Integer/fixed-point inspection projection. Use digest() for long contact
## lists. Velocity uses the derived Weapon ratio above.
func canonical_record() -> Dictionary:
	var collider_ids: Array = []
	for collider_id in blocking_collider_ids:
		collider_ids.append(collider_id)
	return {
		"actor_id": actor_id,
		"blocked_axes": blocked_axes,
		"blocking_collider_ids": collider_ids,
		"corrected": corrected,
		"ok": ok,
		"reason": String(reason),
		"requested_position_micro": requested_position_micro,
		"requested_velocity_milli": velocity_to_milli(requested_velocity_px),
		"resolved_position_micro": resolved_position_micro,
		"resolved_velocity_milli": velocity_to_milli(resolved_velocity_px),
		"tick": tick,
	}


func digest() -> String:
	var record := canonical_record()
	var ids: Array = record["blocking_collider_ids"]
	var chain := ZCanonicalValue.sha256(["movement-contacts-v1", ids.size()])
	if chain.is_empty():
		push_error("MOVEMENT_RESULT_DIGEST: hashing failure")
		return ""
	for collider_id in ids:
		chain = ZCanonicalValue.sha256([chain, collider_id])
		if chain.is_empty():
			push_error("MOVEMENT_RESULT_DIGEST: invalid collider identity")
			return ""
	record["schema"] = "movement-result-v2"
	record["blocking_collider_ids"] = {"count": ids.size(), "digest": chain}
	var result := ZCanonicalValue.sha256(record)
	if result.is_empty():
		push_error("MOVEMENT_RESULT_DIGEST: invalid canonical record")
	return result


## Shared px/s -> milliunit/s projection used by results and the correction
## log so both stay integer-canonical.
static func velocity_to_milli(velocity_px: Vector2) -> Vector2i:
	return Vector2i(
		_round_half_away_from_zero(velocity_px.x * _MILLIUNITS_PER_PX),
		_round_half_away_from_zero(velocity_px.y * _MILLIUNITS_PER_PX)
	)


static func _round_half_away_from_zero(value: float) -> int:
	var magnitude := absf(value)
	var whole := floori(magnitude)
	var fraction := magnitude - whole
	var rounded := whole + 1 if absf(fraction - 0.5) <= 0.00001 else floori(magnitude + 0.5)
	return rounded if value >= 0.0 else -rounded
