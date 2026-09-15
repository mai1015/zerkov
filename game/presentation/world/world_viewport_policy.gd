class_name ZWorldViewportPolicy
extends RefCounted
## Authoritative presentation math for the 640x360 fixed world surface.
##
## Implements the integer enlargement factor k = floor(min(W/640, H/360)),
## centered letterbox/pillarbox matte layout, and forward/inverse screen-world
## coordinate projections.

const BASE_SURFACE_SIZE := Vector2i(640, 360)
const ACCEPTANCE_OUTPUT_SIZE := Vector2i(1920, 1080)
const ACCEPTANCE_SCALE: int = 3


## Evaluates integer enlargement and centered matte placement for a given output.
static func calculate_fit(output_size: Vector2i) -> Dictionary:
	if output_size.x <= 0 or output_size.y <= 0:
		return {
			"displayed_size": Vector2i.ZERO,
			"factor": 0,
			"has_matte": true,
			"matte_rect": Rect2i(Vector2i.ZERO, Vector2i.ZERO),
			"ok": false,
			"surface_size": BASE_SURFACE_SIZE,
		}
	var k_x: int = floori(float(output_size.x) / float(BASE_SURFACE_SIZE.x))
	var k_y: int = floori(float(output_size.y) / float(BASE_SURFACE_SIZE.y))
	var factor: int = maxi(1, mini(k_x, k_y))
	var displayed := BASE_SURFACE_SIZE * factor
	var matte_offset := (output_size - displayed) / 2
	var matte_rect := Rect2i(matte_offset, displayed)
	var has_matte: bool = (matte_rect.position != Vector2i.ZERO or matte_rect.size != output_size)
	return {
		"displayed_size": displayed,
		"factor": factor,
		"has_matte": has_matte,
		"matte_rect": matte_rect,
		"ok": true,
		"surface_size": BASE_SURFACE_SIZE,
	}


## Maps world coordinates to full-output screen coordinates through camera and matte.
static func world_to_screen(
	world_pos: Vector2,
	camera_pos: Vector2,
	output_size: Vector2i = ACCEPTANCE_OUTPUT_SIZE
) -> Vector2:
	var fit := calculate_fit(output_size)
	var factor: float = float(fit.factor)
	var half_surface := Vector2(BASE_SURFACE_SIZE) * 0.5
	var local := (world_pos - camera_pos) + half_surface
	return Vector2(fit.matte_rect.position) + local * factor


## Maps full-output screen pointer to world position. Returns a typed result.
## If the pointer falls in the matte, returns an outside_surface result.
static func screen_to_world(
	screen_pos: Vector2,
	camera_pos: Vector2,
	output_size: Vector2i = ACCEPTANCE_OUTPUT_SIZE
) -> ZWorldCursorAimResult:
	var fit := calculate_fit(output_size)
	if not fit.ok:
		return ZWorldCursorAimResult.outside_surface(screen_pos, &"invalid_output_size")
	var rect: Rect2i = fit.matte_rect
	if not Rect2(rect).has_point(screen_pos):
		return ZWorldCursorAimResult.outside_surface(screen_pos, &"outside_world_surface")
	var factor: float = float(fit.factor)
	var half_surface := Vector2(BASE_SURFACE_SIZE) * 0.5
	var local := (screen_pos - Vector2(rect.position)) / factor
	var world_pos := camera_pos + (local - half_surface)
	var raster_px := Vector2i(floori(world_pos.x), floori(world_pos.y))
	return ZWorldCursorAimResult.success(world_pos, screen_pos, raster_px)
