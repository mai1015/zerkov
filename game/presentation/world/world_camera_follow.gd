class_name ZWorldCameraFollow
extends RefCounted
## Presentation camera follow adapter for 2D world viewports.
##
## Tracks authoritative actor pose and correction records, applies the
## round-once whole raster pixel rule, clamps to level boundaries, and converges
## monotonically without overshoot oscillation. Holds zero transform authority.

const BASE_SURFACE_SIZE := Vector2i(640, 360)

var level_bounds: Rect2 = Rect2()
var viewport_size: Vector2i = BASE_SURFACE_SIZE
var position_px: Vector2 = Vector2.ZERO
var target_px: Vector2 = Vector2.ZERO
var current_unrounded_px: Vector2 = Vector2.ZERO
var convergence_rate: float = 1.0
var presentation_impulse: Vector2 = Vector2.ZERO
var last_correction: Dictionary = {}


func configure(
	bounds: Rect2,
	initial_pos: Vector2 = Vector2.ZERO,
	p_viewport_size: Vector2i = BASE_SURFACE_SIZE
) -> void:
	level_bounds = bounds
	viewport_size = p_viewport_size
	convergence_rate = 1.0
	presentation_impulse = Vector2.ZERO
	last_correction.clear()
	target_px = initial_pos
	current_unrounded_px = initial_pos
	position_px = _round_and_clamp(initial_pos)


func set_convergence_rate(rate: float) -> void:
	convergence_rate = clampf(rate, 0.01, 1.0)


func apply_impulse(impulse: Vector2) -> void:
	presentation_impulse += impulse


func clear_impulse() -> void:
	presentation_impulse = Vector2.ZERO


## Updates target from authoritative position and evaluates one presentation step.
func follow_position(p_target_px: Vector2, snap: bool = false) -> Vector2:
	target_px = p_target_px
	if snap or convergence_rate >= 1.0:
		current_unrounded_px = target_px
	else:
		var diff := target_px - current_unrounded_px
		if diff.length_squared() < 0.0001:
			current_unrounded_px = target_px
		else:
			current_unrounded_px += diff * convergence_rate
	var desired := current_unrounded_px + presentation_impulse
	presentation_impulse = Vector2.ZERO
	position_px = _round_and_clamp(desired)
	return position_px


## Updates target from authoritative movement result.
func follow_movement_result(result: ZMovementResult, snap: bool = false) -> Vector2:
	if result == null or not result.ok:
		return position_px
	return follow_position(result.resolved_position_px, snap)


## Updates target from authoritative player locomotion module.
func follow_locomotion(locomotion: ZPlayerLocomotion, snap: bool = false) -> Vector2:
	if locomotion == null:
		return position_px
	return follow_position(locomotion.position_px, snap)


## Converges target to a movement correction record without overshoot.
func converge_to_correction(record: Dictionary, snap: bool = false) -> Vector2:
	if record.is_empty():
		return position_px
	last_correction = record.duplicate(true)
	var resolved_px := Vector2.ZERO
	if record.has("resolved_position_micro"):
		var micro: Vector2i = record["resolved_position_micro"]
		var conv := ZWorldUnits.canonical_to_godot(micro)
		if conv.ok:
			resolved_px = conv.vector2_value
	elif record.has("resolved_position_px"):
		resolved_px = record["resolved_position_px"]
	return follow_position(resolved_px, snap)


## Steps convergence towards target by one discrete step.
func step_convergence() -> Vector2:
	return follow_position(target_px, false)


## Computes clamped position for given camera coordinate within level bounds.
func clamp_camera(cam_pos: Vector2) -> Vector2:
	if level_bounds.size.x <= 0.0 or level_bounds.size.y <= 0.0:
		return cam_pos
	var half_vp := Vector2(viewport_size) * 0.5
	var min_x := ceilf(level_bounds.position.x + half_vp.x)
	var max_x := floorf(level_bounds.end.x - half_vp.x)
	var min_y := ceilf(level_bounds.position.y + half_vp.y)
	var max_y := floorf(level_bounds.end.y - half_vp.y)

	var clamped := cam_pos
	if min_x > max_x:
		clamped.x = roundf(level_bounds.position.x + level_bounds.size.x * 0.5)
	else:
		clamped.x = clampf(cam_pos.x, min_x, max_x)

	if min_y > max_y:
		clamped.y = roundf(level_bounds.position.y + level_bounds.size.y * 0.5)
	else:
		clamped.y = clampf(cam_pos.y, min_y, max_y)

	return clamped


## Rounds once to whole world-raster pixels and clamps to bounds.
func _round_and_clamp(raw_pos: Vector2) -> Vector2:
	var rounded := Vector2(roundf(raw_pos.x), roundf(raw_pos.y))
	return clamp_camera(rounded)
