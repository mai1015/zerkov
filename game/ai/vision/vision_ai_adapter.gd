class_name VisionAIAdapter
extends RefCounted
## Task 6.3. Recipient-specific, value-only knowledge. Never queries live actors.
## Common Vision projections are full snapshots, not sparse updates.

const UNKNOWN: int = 0
const REMEMBERED: int = 1
const VISIBLE: int = 2
const MAX_RECORDS: int = RaidVisionActorRegistry.MAX_ACTORS

var last_error: StringName = &""
var _generation: int = 0
var _observer_id: int = 0
var _entity_id: String = ""
var _last_result_revision: int = 0
var _last_completed_tick: int = 0
var _last_projection: Dictionary = {}
var _released: bool = false


func configure(generation: int, entity_id: String, observer_id: int) -> bool:
	if _generation != 0 or generation <= 0 or not ZAIValues.entity(entity_id) or observer_id <= 0:
		return _reject(&"ai_vision_configuration_invalid")
	_generation = generation
	_entity_id = entity_id
	_observer_id = observer_id
	return true


## Registry is visible only to this game-owned adapter, never to the brain.
## Validate all native fields that can affect decisions before retaining data.
func consume(generation: int, tick: int, projection: Dictionary,
	registry: RaidVisionActorRegistry, profile: ZAIProfile) -> Dictionary:
	last_error = &""
	if _released or generation != _generation or _generation == 0 or tick < 1 \
		or tick >= ZAIValues.MAX_TICK or registry == null or not registry.is_active(generation) \
		or profile == null or not profile.is_valid():
		return _error(&"ai_vision_binding_invalid")
	if projection.is_empty():
		return _frame(tick, 0, [], false)
	if projection.get("ok") != true or projection.get("observer_id") != _observer_id \
		or not ZAIValues.integer(projection.get("result_revision"), 1, ZAIValues.MAX_TICK) \
		or not ZAIValues.integer(projection.get("completed_tick"), 1, tick) \
		or not projection.get("records") is Array or projection.records.size() > MAX_RECORDS:
		return _error(&"ai_vision_projection_invalid")
	var revision: int = projection.result_revision
	var completed: int = projection.completed_tick
	if revision < _last_result_revision or completed < _last_completed_tick:
		return _error(&"ai_vision_projection_regressed")
	if revision == _last_result_revision and projection != _last_projection:
		return _error(&"ai_vision_projection_conflict")
	var facts: Array = []
	var seen: Dictionary = {}
	for record: Variant in projection.records:
		if not record is Dictionary or not ZAIValues.integer(record.get("target_id"), 1, 4096) \
			or not ZAIValues.integer(record.get("state"), UNKNOWN, VISIBLE) \
			or typeof(record.get("has_last_known_position")) != TYPE_BOOL:
			return _error(&"ai_vision_record_invalid")
		if seen.has(record.target_id):
			return _error(&"ai_vision_target_duplicate")
		seen[record.target_id] = true
		if record.state == UNKNOWN:
			if record.has_last_known_position:
				return _error(&"ai_vision_unknown_has_position")
			continue  # Memory-expired/removal tombstones contain no actionable data.
		if not record.has_last_known_position or not ZAIValues.point(record.get("last_known_position")) \
			or not ZAIValues.integer(record.get("last_seen_tick"), 1, completed) \
			or not ZAIValues.integer(record.get("target_revision"), 1, ZAIValues.MAX_TICK):
			return _error(&"ai_vision_observation_invalid")
		var key: String = registry.entity_for_native_id(generation, record.target_id)
		if key.is_empty():
			return _error(&"ai_vision_target_identity_unknown")
		if key == _entity_id or tick - int(record.last_seen_tick) > profile.memory_ticks:
			continue
		var visible: bool = record.state == VISIBLE \
			and tick - completed <= profile.max_projection_age_ticks
		if record.state == VISIBLE and record.last_seen_tick != completed:
			return _error(&"ai_vision_visible_timestamp_invalid")
		var confidence: int = 1000 if visible else 500
		facts.append({"entity_id": key, "kind": &"visible" if visible else &"remembered",
			"position_raw": ZAIValues.decode_point(record.last_known_position),
			"last_seen_tick": record.last_seen_tick, "confidence_milli": confidence,
			"target_revision": record.target_revision})
	facts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.entity_id < b.entity_id)
	# Retain a normalized/validated value snapshot. Input is from the native
	# port, not arbitrary scene dictionaries; no actor object is ever retained.
	_last_projection = projection.duplicate(true)
	_last_result_revision = revision
	_last_completed_tick = completed
	return _frame(tick, completed, facts, tick - completed <= profile.max_projection_age_ticks)


func release(generation: int) -> bool:
	if generation != _generation:
		return _reject(&"ai_vision_generation_invalid")
	_released = true
	_last_projection = {}
	return true


func _frame(tick: int, completed: int, facts: Array, fresh: bool) -> Dictionary:
	return ZAIValues.frozen({"ok": true, "generation": _generation, "recipient": _entity_id,
		"tick": tick, "completed_tick": completed, "fresh": fresh, "facts": facts})


func _error(reason: StringName) -> Dictionary:
	_reject(reason)
	return ZAIValues.frozen({"ok": false, "reason": reason})


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
