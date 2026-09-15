class_name RaidAIPhaseDriver
extends RefCounted
## Exact named phase callbacks. Runtime does not get to advance RaidAuthority.
## Methods use a RefCounted authority port so pure tests need no native addons;
## production binds the existing RaidAuthority API, not a parallel clock.

const MOVEMENT: int = 1
const AI_DECISIONS: int = 3
const TASKS_AND_AUDIT: int = 7
const HANDLERS: Array[StringName] = [&"ai_actor_sync", &"ai_decisions", &"ai_noise"]
var last_error: StringName = &""
var _raid_ref: WeakRef
var _runtime: RaidAIRuntime
var _generation: int = 0
var _registrations: Dictionary = {}
var _inside: bool = false
var _released: bool = false


func bind(raid: RefCounted, generation: int, runtime: RaidAIRuntime,
	movement_handler: StringName, movement_priority: int = 100,
	audit_after: PackedStringArray = PackedStringArray(), audit_priority: int = 100) -> bool:
	if _generation != 0 or raid == null or runtime == null or generation < 1 \
		or movement_handler.is_empty() or not raid.has_method("register_phase_handler") \
		or not raid.has_method("is_dispatching_phase_registration"):
		return _reject(&"ai_phase_binding_invalid")
	for method: StringName in [&"generation", &"has_phase_handler", &"phase_handler_registration_id", &"unregister_phase_handler"]:
		if not raid.has_method(method):
			return _reject(&"ai_phase_authority_api_invalid")
	if int(raid.call("generation")) != generation \
		or not bool(raid.call("has_phase_handler", &"raid_vision_world", generation)):
		return _reject(&"ai_phase_authority_not_ready")
	_generation = generation
	_raid_ref = weakref(raid)
	_runtime = runtime
	var rows: Array = [
		[MOVEMENT, HANDLERS[0], Callable(self, "_movement"), movement_priority, PackedStringArray([movement_handler])],
		[AI_DECISIONS, HANDLERS[1], Callable(self, "_decisions"), 0, PackedStringArray()],
		[TASKS_AND_AUDIT, HANDLERS[2], Callable(self, "_noise"), audit_priority, audit_after],
	]
	for row: Array in rows:
		if not bool(raid.call("register_phase_handler", row[0], row[1], row[2], generation, row[3], row[4])):
			var reason: StringName = raid.get("last_error")
			if not release(generation):
				return _reject(&"ai_phase_registration_rollback_failed")
			return _reject(reason)
		_registrations[row[1]] = raid.call("phase_handler_registration_id", row[1], generation)
	return true


func _movement(raid: RefCounted, phase: int, tick: int, _intents: Array) -> bool:
	return _run(raid, phase, tick, HANDLERS[0], Callable(self, "_movement"), MOVEMENT)


func _decisions(raid: RefCounted, phase: int, tick: int, _intents: Array) -> bool:
	return _run(raid, phase, tick, HANDLERS[1], Callable(self, "_decisions"), AI_DECISIONS)


func _noise(raid: RefCounted, phase: int, tick: int, _intents: Array) -> bool:
	return _run(raid, phase, tick, HANDLERS[2], Callable(self, "_noise"), TASKS_AND_AUDIT)


func _run(raid: RefCounted, phase: int, tick: int, id: StringName, callback: Callable, expected_phase: int) -> bool:
	if _released or _inside or _raid_ref == null or _raid_ref.get_ref() != raid or phase != expected_phase \
		or not _registrations.has(id) or not bool(raid.call("is_dispatching_phase_registration",
			id, _registrations[id], callback, phase, tick, _generation)):
		return _reject(&"ai_phase_not_current")
	_inside = true
	var ok: bool = false
	match phase:
		MOVEMENT: ok = _runtime.stage_after_movement(_generation, tick)
		AI_DECISIONS: ok = _runtime.decide(_generation, tick)
		TASKS_AND_AUDIT: ok = _runtime.resolve_noise(_generation, tick)
	_inside = false
	if not ok:
		last_error = _runtime.last_error
	return ok


## Remove callbacks before releasing the Vision owner. Failed removal retains
## runtime ownership so teardown can be retried; never silently orphan a slot.
func release(generation: int) -> bool:
	if generation != _generation or _inside:
		return _reject(&"ai_phase_release_invalid")
	var raid: RefCounted = _raid_ref.get_ref() if _raid_ref != null else null
	if raid != null and int(raid.call("generation")) == generation:
		for index: int in range(HANDLERS.size() - 1, -1, -1):
			var id: StringName = HANDLERS[index]
			if _registrations.has(id):
				if bool(raid.call("has_phase_handler", id, generation)):
					if raid.call("phase_handler_registration_id", id, generation) != _registrations[id]:
						return _reject(&"ai_phase_release_registration_replaced")
					if not bool(raid.call("unregister_phase_handler", id, generation)):
						return _reject(&"ai_phase_release_blocked")
				_registrations.erase(id)
	if _runtime != null:
		_runtime.release(generation)
	_released = true
	_raid_ref = null
	_runtime = null
	return true


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false
