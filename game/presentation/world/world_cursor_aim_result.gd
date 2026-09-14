class_name ZWorldCursorAimResult
extends RefCounted
## Typed result of mapping an output viewport pointer to a world coordinate.
##
## Distinguishes valid world-surface pointer positions from positions landing
## in the centered matte or outside the output viewport.

var ok: bool = false
var inside_surface: bool = false
var world_position: Vector2 = Vector2.ZERO
var world_raster_pixel: Vector2i = Vector2i.ZERO
var screen_position: Vector2 = Vector2.ZERO
var reason: StringName = &""


static func success(
	p_world_pos: Vector2,
	p_screen_pos: Vector2,
	p_raster_pixel: Vector2i
) -> ZWorldCursorAimResult:
	var result := ZWorldCursorAimResult.new()
	result.ok = true
	result.inside_surface = true
	result.world_position = p_world_pos
	result.world_raster_pixel = p_raster_pixel
	result.screen_position = p_screen_pos
	result.reason = &""
	return result


static func outside_surface(
	p_screen_pos: Vector2,
	p_reason: StringName = &"outside_world_surface"
) -> ZWorldCursorAimResult:
	var result := ZWorldCursorAimResult.new()
	result.ok = false
	result.inside_surface = false
	result.world_position = Vector2.ZERO
	result.world_raster_pixel = Vector2i.ZERO
	result.screen_position = p_screen_pos
	result.reason = p_reason
	return result
