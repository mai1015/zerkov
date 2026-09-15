extends RefCounted
## Presentation pose for the environment inspector only. Input is RESOLVED
## displacement, never key state. Not an authority, stamina or combat controller.
const FRAMES: int = 6
const PIXELS_PER_CYCLE: float = 52.8
const IDLE_FPS: float = 6.0
var moving: bool = false
var distance_phase: float = 0.0
var idle_phase: float = 0.0
var frame: int = 0

func advance(distance: float, delta: float) -> bool:
	if not is_finite(distance) or not is_finite(delta) or distance < 0.0 or delta < 0.0 or delta > 1.0:
		return false
	var next_moving := distance > 0.01
	if next_moving != moving:
		distance_phase = 0.0
		idle_phase = 0.0
	moving = next_moving
	if moving:
		distance_phase = fposmod(distance_phase + distance, PIXELS_PER_CYCLE)
		frame = int(floor(distance_phase / PIXELS_PER_CYCLE * FRAMES))
	else:
		idle_phase = fposmod(idle_phase + delta * IDLE_FPS, float(FRAMES))
		frame = int(floor(idle_phase))
	return true

func reset() -> void:
	moving = false
	distance_phase = 0.0
	idle_phase = 0.0
	frame = 0

func snapshot() -> Dictionary:
	var result := {"moving": moving, "frame": frame, "distance_phase": distance_phase, "idle_phase": idle_phase}
	result.make_read_only()
	return result
