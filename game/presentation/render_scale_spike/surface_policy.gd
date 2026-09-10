extends RefCounted
## Isolated candidate policies. No production rendering or authority dependency.

const CANDIDATES: Array[String] = ["320_fixed", "640_fractional", "640_integer", "adaptive_integer"]

static func layout(candidate: String, output: Vector2i) -> Dictionary:
	assert(candidate in CANDIDATES)
	var surface := Vector2i(320, 180) if candidate == "320_fixed" else Vector2i(640, 360)
	var zoom := 0.5 if candidate == "320_fixed" else 1.0
	var factor := minf(float(output.x) / surface.x, float(output.y) / surface.y)
	if candidate in ["640_integer", "adaptive_integer"]:
		factor = maxf(1.0, floorf(factor))
	if candidate == "adaptive_integer":
		surface = Vector2i(floorf(output.x / factor), floorf(output.y / factor))
	var displayed := Vector2i(Vector2(surface) * factor)
	return {"candidate": candidate, "surface": surface, "zoom": zoom,
		"factor": factor, "rect": Rect2i((output - displayed) / 2, displayed)}

static func snap_camera(pose: Vector2, zoom: float) -> Vector2:
	return (pose * zoom).round() / zoom

static func world_to_output(point: Vector2, camera: Vector2, policy: Dictionary) -> Vector2:
	var local := (point - camera) * float(policy.zoom) + Vector2(policy.surface) * 0.5
	return Vector2(policy.rect.position) + local * float(policy.factor)

static func output_to_world(point: Vector2, camera: Vector2, policy: Dictionary) -> Dictionary:
	if not Rect2(policy.rect).has_point(point):
		return {"accepted": false}
	return {"accepted": true, "world": (point - Vector2(policy.rect.position)) / float(policy.factor) / float(policy.zoom) - Vector2(policy.surface) * 0.5 / float(policy.zoom) + camera}
