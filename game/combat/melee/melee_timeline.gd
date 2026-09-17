class_name ZMeleeTimeline
extends RefCounted
## One actor's tick-driven swing. No world queries, health values, signals,
## animation, wall clock, or resource mutation. Execution owns cost admission.
var _swing: Dictionary = {}
var _last_tick: int = 0
var _hit: bool = false
var _interrupted: bool = false

func can_start(tick: int) -> bool:
	return tick > 0 and tick >= _last_tick and (_swing.is_empty() or tick >= int(_swing.ready_tick))

func has_active_work(tick: int) -> bool:
	return not _swing.is_empty() and tick < int(_swing.get("ready_tick", 0))

func start(request_id: String, tick: int, definition: Dictionary, aim_raw: Vector2i) -> bool:
	if not can_start(tick) or request_id.is_empty() or aim_raw == Vector2i.ZERO \
		or absi(int(aim_raw.x)) > 1_000_000 or absi(int(aim_raw.y)) > 1_000_000 \
		or not _valid_definition(definition) or tick > 2_147_000_000:
		return false
	_swing = {"request_id": request_id, "start_tick": tick,
		"active_tick": tick + int(definition.windup_ticks),
		"recovery_tick": tick + int(definition.windup_ticks) + int(definition.active_ticks),
		"ready_tick": tick + int(definition.windup_ticks) + int(definition.active_ticks) + int(definition.recovery_ticks),
		"aim_raw": aim_raw, "definition": definition.duplicate(true)}
	_last_tick = tick
	_hit = false
	_interrupted = false
	return true

func advance(tick: int, usable: bool) -> Dictionary:
	if tick < _last_tick:
		return {"ok": false, "reason": &"melee_tick_regressed"}
	_last_tick = tick
	if not _swing.is_empty() and tick < int(_swing.ready_tick) and not usable and not _interrupted:
		_interrupted = true
		_swing.ready_tick = maxi(int(_swing.ready_tick), tick + int(_swing.definition.recovery_ticks))
	return snapshot(tick)

func mark_contact(tick: int) -> bool:
	var view := snapshot(tick)
	if not view.get("query_contact", false):
		return false
	_hit = true
	return true

func snapshot(tick: int) -> Dictionary:
	var phase: StringName = &"ready"
	if not _swing.is_empty() and tick < int(_swing.ready_tick):
		phase = &"recovery" if _interrupted or tick >= int(_swing.recovery_tick) else (&"active" if tick >= int(_swing.active_tick) else &"windup")
	var result := {"ok": true, "phase": phase,
		"query_contact": phase == &"active" and not _hit and not _interrupted,
		"contact_committed": _hit, "interrupted": _interrupted,
		"swing": _swing.duplicate(true)}
	_freeze(result)
	return result

func clear() -> void:
	_swing = {}
	_hit = false
	_interrupted = false

static func _freeze(value: Variant) -> void:
	if value is Dictionary:
		for child in value.values(): _freeze(child)
		value.make_read_only()
	elif value is Array:
		for child in value: _freeze(child)
		value.make_read_only()

static func _valid_definition(value: Dictionary) -> bool:
	return value == ZMeleePolicy.definition(&"machete") or value == ZMeleePolicy.definition(&"mutant")
