class_name ZPlayerAnimationState
extends RefCounted
## Presentation only. The root-owned projection adapter supplies ordered,
## committed events AFTER authority publication. No animation callback mutates
## an actor, weapon, inventory, health component, or the raid clock.
##
## Last committed action wins, death is terminal, locomotion resumes when an
## action clip expires. Unsupported clips fail explicitly (no guessed art).

const MAX_TICK: int = 2147483647
const ALLOWED_CLIPS: Array[String] = ["idle", "walk", "attack", "grenade", "death"]
var _clips: Dictionary = {}
var _generation: int = 0
var _sequence: int = 0
var _tick: int = 0
var _event_tick: int = 0
var _moving: bool = false
var _locomotion_started: int = 0
var _action: String = ""
var _action_started: int = 0
var _dead: bool = false
var _released: bool = true


func configure(clips: Dictionary, generation: int) -> bool:
	if generation <= _generation or generation > MAX_TICK:
		return false
	if clips.size() > ALLOWED_CLIPS.size():
		return false
	var candidate: Dictionary = {}
	for key: Variant in clips:
		if not key is String or not ALLOWED_CLIPS.has(key) or not clips[key] is Dictionary:
			return false
		var clip: Dictionary = clips[key]
		if not _whole(clip.get("frame_count"), 1, 128):
			return false
		if not _whole(clip.get("ticks_per_frame"), 1, 120) or not clip.get("loop") is bool:
			return false
		if bool(clip["loop"]) != (key == "idle" or key == "walk"):
			return false
		candidate[key] = {"frame_count": int(clip["frame_count"]),
			"ticks_per_frame": int(clip["ticks_per_frame"]), "loop": clip["loop"]}
	for required: String in ["idle", "walk", "death"]:
		if not candidate.has(required):
			return false
	_clips = candidate
	_generation = generation
	_sequence = 0
	_tick = 0
	_event_tick = 0
	_moving = false
	_locomotion_started = 0
	_action = ""
	_action_started = 0
	_dead = false
	_released = false
	return true


func advance_to(tick: int) -> bool:
	if _released or tick < _tick or tick > MAX_TICK:
		return false
	_tick = tick
	return true


func consume(event: Dictionary) -> bool:
	if _released or _dead:
		return false
	for field: String in ["generation", "sequence", "tick"]:
		if typeof(event.get(field)) != TYPE_INT:
			return false
	# GDScript does not allow every cross-type equality comparison. Validate the
	# Variant before comparing it, otherwise a rejected event logs an error.
	if typeof(event.get("committed")) != TYPE_BOOL or not event["committed"]:
		return false
	if not event.get("kind") is String:
		return false
	var kind: String = event["kind"]
	var sequence: int = event["sequence"]
	var event_tick: int = event["tick"]
	if event["generation"] != _generation or sequence <= _sequence or sequence > MAX_TICK:
		return false
	if event_tick < _event_tick or event_tick > _tick or event_tick < 0:
		return false
	if kind == "locomotion":
		if event.size() != 6 or not event.get("moving") is bool:
			return false
	elif kind not in ["attack", "grenade", "death"] or not _clips.has(kind) or event.size() != 5:
		return false
	# Commit presentation state only after the entire event has passed preflight.
	_sequence = sequence
	_event_tick = event_tick
	if kind == "locomotion":
		if _moving != event["moving"]:
			_locomotion_started = event_tick
		_moving = event["moving"]
	else:
		_action = kind
		_action_started = event_tick
		_dead = kind == "death"
	return true


func snapshot() -> Dictionary:
	if _released:
		return {}
	var state: String = "walk" if _moving else "idle"
	var started: int = _locomotion_started
	if not _action.is_empty():
		var action_clip: Dictionary = _clips[_action]
		var duration: int = action_clip["frame_count"] * action_clip["ticks_per_frame"]
		if _dead or _tick - _action_started < duration:
			state = _action
			started = _action_started
	var clip: Dictionary = _clips[state]
	@warning_ignore("integer_division")
	var frame: int = int((_tick - started) / int(clip["ticks_per_frame"]))
	frame = frame % int(clip["frame_count"]) if clip["loop"] else mini(frame, int(clip["frame_count"]) - 1)
	var result := {"generation": _generation, "sequence": _sequence, "tick": _tick,
		"state": state, "frame": frame, "terminal": _dead}
	result.make_read_only()
	return result


func release() -> void:
	_released = true
	_clips.clear()


static func _whole(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum
