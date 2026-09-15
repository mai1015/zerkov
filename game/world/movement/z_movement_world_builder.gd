class_name ZMovementWorldBuilder
extends RefCounted
## Composes a ZMovementWorld2D from authored level data (task 3.6).
##
## This builder is the only place authored layout content is translated into
## injected movement geometry. ZMovementWorld2D itself stays a pure, testable
## module and never loads the Sawmill scene or any resource; the layout is
## consumed duck-typed so this adapter tracks the authored resource shape
## without a hard script dependency.

const OBSTACLE_LAYER: String = "Obstacles"

static var last_error: StringName = &""


## Builds a movement world bounded by the layout's world rect with one static
## blocking collider per Obstacles-layer structure. The level identifier
## becomes the bounds collider id, so bounds clamping reports a stable
## authored identity. Canopy and every other layer are non-blocking.
static func build_from_sawmill_layout(
	layout: Resource,
	expected_generation: int
) -> ZMovementWorld2D:
	last_error = &""
	if layout == null:
		last_error = &"layout_missing"
		return null
	if not layout.has_method("world_bounds"):
		last_error = &"layout_api_invalid"
		return null
	var bounds: Rect2 = layout.world_bounds()
	if not _is_finite_rect(bounds) or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		last_error = &"layout_bounds_invalid"
		return null
	var level_id := String(layout.get("level_id"))
	var world := ZMovementWorld2D.new()
	if not world.configure(bounds, expected_generation, level_id):
		last_error = world.last_error
		return null
	var structures: Array = layout.get("structures")
	for row_value in structures:
		if typeof(row_value) != TYPE_DICTIONARY:
			last_error = &"structure_row_invalid"
			return null
		var row: Dictionary = row_value
		if String(row.get("layer", "")) != OBSTACLE_LAYER:
			continue
		var collider_id := String(row.get("id", ""))
		if collider_id.is_empty():
			last_error = &"structure_id_invalid"
			return null
		if typeof(row.get("rect", null)) != TYPE_RECT2I:
			last_error = &"structure_rect_invalid"
			return null
		if not world.add_static_collider_cells(collider_id, row["rect"], expected_generation):
			last_error = world.last_error
			return null
	return world


static func _is_finite_rect(rect: Rect2) -> bool:
	var point := rect.position
	var end := rect.end
	for value in [point.x, point.y, end.x, end.y]:
		if is_nan(value) or is_inf(value):
			return false
	return true
