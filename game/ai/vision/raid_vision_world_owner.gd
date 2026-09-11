class_name RaidVisionWorldOwner
extends Node
## Scene-owned authoritative Common Vision world for one raid generation.
##
## RaidAuthority (or a focused test driver before registration) supplies exact
## integer ticks.  This owner never processes render delta and never registers,
## updates, or removes gameplay observers/targets; task 6.2 owns that lifecycle.

enum Lifecycle {
	NOT_STARTED,
	ACTIVE,
	TORN_DOWN,
}

const LIFECYCLE_NAMES: PackedStringArray = [
	"not_started",
	"active",
	"torn_down",
]
const NATIVE_WORLD_NODE_NAME: StringName = &"CommonVisionAuthorityWorld"
const DEFAULT_PHASE_HANDLER_ID: StringName = &"raid_vision_world"
const NATIVE_MAX_OBSERVERS: int = 4_096

var lifecycle: Lifecycle = Lifecycle.NOT_STARTED
var last_error: StringName = &""

var _generation: int = 0
var _world_id: int = 0
var _configuration: Dictionary = {}
var _configuration_fingerprint: String = ""
var _provenance_fingerprint: String = ""
var _native_world: CommonVisionWorld2D
var _last_tick: int = 0
var _last_evaluation_tick: int = 0
var _last_tick_was_evaluation: bool = false
var _is_advancing: bool = false
var _inside_phase_handler: bool = false
var _raid_authority_ref: WeakRef
var _raid_authority_instance_id: int = 0
var _raid_authority_generation: int = 0
var _history: Array[Dictionary] = []
var _last_native_status: Dictionary = {}

var _ticks_received: int = 0
var _evaluation_ticks: int = 0
var _cadence_skips: int = 0
var _requested_work_units: int = 0
var _consumed_work_units: int = 0
var _completed_observers: int = 0
var _deferred_observers: int = 0
var _budget_exhaustions: int = 0
var _failed_evaluations: int = 0


## Starts exactly one offline authority world from the sealed configuration.
## A rejected attempt leaves this owner empty and retryable; a successful owner
## cannot be reconfigured because native configure() is a destructive reset.
func configure(world_id: int, configuration_record: Dictionary = {}) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.NOT_STARTED or _native_world != null:
		return _reject(&"owner_already_configured")
	if world_id <= 0 or world_id > ZerkovVisionConfig.WORLD_ID_MAX:
		return _reject(&"vision_world_id_invalid")

	var candidate := ZerkovVisionConfig.configuration() \
		if configuration_record.is_empty() else configuration_record.duplicate(true)
	var validation := ZerkovVisionConfig.validate_configuration(candidate, true)
	if not bool(validation.get("ok", false)):
		return _reject(StringName(validation.get("reason", &"vision_configuration_invalid")))
	var preflight := ZerkovVisionConfig.runtime_preflight()
	if not bool(preflight.get("ok", false)):
		return _reject(StringName(preflight.get("reason", &"vision_runtime_incompatible")))

	var native_object: Object = ClassDB.instantiate("CommonVisionWorld2D")
	var native_world := native_object as CommonVisionWorld2D
	if native_world == null:
		if native_object != null:
			native_object.free()
		return _reject(&"vision_world_create_failed")
	var world_configuration := candidate["world"] as Dictionary
	var native_result: Dictionary = native_world.configure(
		world_id,
		int(world_configuration["role"]),
		int(world_configuration["spatial_cell_size_raw"]),
		int(world_configuration["max_visited_cells"]),
	)
	if not bool(native_result.get("ok", false)):
		_last_native_status = _native_status_copy(native_result)
		native_world.free()
		return _reject(&"vision_native_configuration_failed")

	_native_world = native_world
	_native_world.name = NATIVE_WORLD_NODE_NAME
	add_child(_native_world)
	_configuration = candidate.duplicate(true)
	_make_deep_read_only(_configuration)
	_configuration_fingerprint = String(validation.get("fingerprint", ""))
	_provenance_fingerprint = String(preflight.get("fingerprint", ""))
	_world_id = world_id
	_generation = 1
	lifecycle = Lifecycle.ACTIVE
	_last_native_status = _native_status_copy(native_result)
	return true


func start(world_id: int, configuration_record: Dictionary = {}) -> bool:
	return configure(world_id, configuration_record)


func generation() -> int:
	return _generation


func world_id() -> int:
	return _world_id


func lifecycle_name() -> StringName:
	return StringName(LIFECYCLE_NAMES[int(lifecycle)])


func is_current_generation(expected_generation: int) -> bool:
	return lifecycle == Lifecycle.ACTIVE \
		and expected_generation == _generation \
		and _native_world != null \
		and is_instance_valid(_native_world)


## The production actor-registration owner introduced by task 6.2 will use this
## generation-checked handle.  Task 6.1 exposes no actor mutation facade.
func authority_world(expected_generation: int) -> CommonVisionWorld2D:
	return _native_world if is_current_generation(expected_generation) else null


func configuration_fingerprint() -> String:
	return _configuration_fingerprint


func provenance_fingerprint() -> String:
	return _provenance_fingerprint


func configuration_receipt() -> Dictionary:
	var result := {
		"active": lifecycle == Lifecycle.ACTIVE,
		"lifecycle": String(lifecycle_name()),
		"world_id": _world_id,
		"generation": _generation,
		"configuration_fingerprint": _configuration_fingerprint,
		"provenance_fingerprint": _provenance_fingerprint,
		"coordinate_scale": ZerkovVisionConfig.EXPECTED_COORDINATE_SCALE,
		"cadence_first_tick": ZerkovVisionConfig.CADENCE_FIRST_TICK,
		"cadence_interval_ticks": ZerkovVisionConfig.CADENCE_INTERVAL_TICKS,
		"work_budget_per_evaluation": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
	}
	_make_deep_read_only(result)
	return result


## Registers the sole deterministic phase-3 driver.  Shared bootstrap wiring is
## intentionally outside this task; composition may call this while the raid is
## PREPARING.  Once registered, direct tick driving is rejected.
func register_with_raid_authority(
	raid_authority: RaidAuthority,
	handler_id: StringName = DEFAULT_PHASE_HANDLER_ID
) -> bool:
	last_error = &""
	if not is_current_generation(_generation):
		return _reject(&"vision_owner_inactive")
	if raid_authority == null or not is_instance_valid(raid_authority):
		return _reject(&"raid_authority_invalid")
	if _raid_authority_instance_id != 0:
		return _reject(&"raid_authority_already_registered")
	if _last_tick != 0:
		return _reject(&"vision_tick_driver_already_started")
	var captured_raid_generation := raid_authority.generation()
	if not raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		handler_id,
		Callable(self, "handle_raid_phase"),
		captured_raid_generation,
	):
		return _reject(raid_authority.last_error)
	_raid_authority_ref = weakref(raid_authority)
	_raid_authority_instance_id = raid_authority.get_instance_id()
	_raid_authority_generation = captured_raid_generation
	return true


func handle_raid_phase(
	raid_authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	last_error = &""
	var captured_authority: Variant = _raid_authority_ref.get_ref() \
		if _raid_authority_ref != null else null
	if raid_authority == null or not is_instance_valid(raid_authority) \
			or captured_authority != raid_authority \
			or raid_authority.get_instance_id() != _raid_authority_instance_id \
			or raid_authority.generation() != _raid_authority_generation:
		return _reject(&"raid_authority_binding_invalid")
	if phase != RaidAuthority.TickPhase.VISION:
		return _reject(&"vision_phase_invalid")
	if _inside_phase_handler:
		return _reject(&"vision_phase_reentrant")
	_inside_phase_handler = true
	var advanced := advance_authority_tick(tick, _generation)
	_inside_phase_handler = false
	return advanced


## Advances one exact RaidClock tick.  The signature deliberately contains no
## delta/time input; non-cadence ticks account for telemetry but request zero
## native work.
func advance_authority_tick(tick: int, expected_generation: int) -> bool:
	last_error = &""
	if _is_advancing:
		return _reject(&"vision_tick_reentrant")
	if not is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if _raid_authority_instance_id != 0 and not _inside_phase_handler:
		return _reject(&"vision_tick_driver_is_raid_authority")
	if tick <= 0 or tick > ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT:
		return _reject(&"vision_tick_out_of_range")
	if tick != _last_tick + 1:
		return _reject(&"vision_tick_regressed_or_skipped")

	_is_advancing = true
	var evaluates := ZerkovVisionConfig.is_evaluation_tick(tick)
	if not evaluates:
		_last_tick = tick
		_last_tick_was_evaluation = false
		_ticks_received = _bounded_add(_ticks_received, 1)
		_cadence_skips = _bounded_add(_cadence_skips, 1)
		_is_advancing = false
		return true

	var native_result: Dictionary = _native_world.advance(
		tick,
		ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
	)
	_last_native_status = _native_status_copy(native_result)
	if not bool(native_result.get("ok", false)):
		_failed_evaluations = _bounded_add(_failed_evaluations, 1)
		_is_advancing = false
		return _reject(&"vision_native_advance_failed")
	if not _metrics_are_valid(native_result):
		_failed_evaluations = _bounded_add(_failed_evaluations, 1)
		_is_advancing = false
		return _reject(&"vision_native_metrics_invalid")

	var requested := int(native_result["requested"])
	var consumed := int(native_result["consumed"])
	var completed := int(native_result["completed"])
	var deferred := int(native_result["deferred"])
	var invalidated := int(native_result["invalidated"])
	var exhausted := deferred > 0 \
		or requested > ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION
	var record := {
		"tick": tick,
		"budget": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"requested": requested,
		"consumed": consumed,
		"completed": completed,
		"deferred": deferred,
		"invalidated": invalidated,
		"budget_exhausted": exhausted,
	}
	_history.append(record)
	if _history.size() > ZerkovVisionConfig.TELEMETRY_HISTORY_LIMIT:
		_history.pop_front()

	_last_tick = tick
	_last_evaluation_tick = tick
	_last_tick_was_evaluation = true
	_ticks_received = _bounded_add(_ticks_received, 1)
	_evaluation_ticks = _bounded_add(_evaluation_ticks, 1)
	_requested_work_units = _bounded_add(_requested_work_units, requested)
	_consumed_work_units = _bounded_add(_consumed_work_units, consumed)
	_completed_observers = _bounded_add(_completed_observers, completed)
	_deferred_observers = _bounded_add(_deferred_observers, deferred)
	if exhausted:
		_budget_exhaustions = _bounded_add(_budget_exhaustions, 1)
	_is_advancing = false
	return true


func telemetry_snapshot() -> Dictionary:
	var history_copy: Array[Dictionary] = []
	for record in _history:
		history_copy.append(record.duplicate(true))
	var result := {
		"lifecycle": String(lifecycle_name()),
		"world_id": _world_id,
		"generation": _generation,
		"configuration_fingerprint": _configuration_fingerprint,
		"provenance_fingerprint": _provenance_fingerprint,
		"last_tick": _last_tick,
		"last_evaluation_tick": _last_evaluation_tick,
		"last_tick_was_evaluation": _last_tick_was_evaluation,
		"cadence_first_tick": ZerkovVisionConfig.CADENCE_FIRST_TICK,
		"cadence_interval_ticks": ZerkovVisionConfig.CADENCE_INTERVAL_TICKS,
		"work_budget_per_evaluation": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"history_limit": ZerkovVisionConfig.TELEMETRY_HISTORY_LIMIT,
		"ticks_received": _ticks_received,
		"evaluation_ticks": _evaluation_ticks,
		"cadence_skips": _cadence_skips,
		"requested_work_units": _requested_work_units,
		"consumed_work_units": _consumed_work_units,
		"completed_observers": _completed_observers,
		"deferred_observers": _deferred_observers,
		"budget_exhaustions": _budget_exhaustions,
		"failed_evaluations": _failed_evaluations,
		"last_error": String(last_error),
		"last_native_status": _last_native_status.duplicate(true),
		"history": history_copy,
	}
	_make_deep_read_only(result)
	return result


## Fingerprints the bounded summary (not unbounded recipient records).  History
## entries are represented by individual hashes so the canonical value stays
## below ZCanonicalValue's node bound even at the 64-entry history limit.
func telemetry_fingerprint() -> String:
	var history_fingerprints: Array[String] = []
	for record in _history:
		history_fingerprints.append(ZCanonicalValue.sha256(record))
	return ZCanonicalValue.sha256({
		"world_id": _world_id,
		"generation": _generation,
		"configuration_fingerprint": _configuration_fingerprint,
		"provenance_fingerprint": _provenance_fingerprint,
		"last_tick": _last_tick,
		"last_evaluation_tick": _last_evaluation_tick,
		"last_tick_was_evaluation": _last_tick_was_evaluation,
		"ticks_received": _ticks_received,
		"evaluation_ticks": _evaluation_ticks,
		"cadence_skips": _cadence_skips,
		"requested_work_units": _requested_work_units,
		"consumed_work_units": _consumed_work_units,
		"completed_observers": _completed_observers,
		"deferred_observers": _deferred_observers,
		"budget_exhaustions": _budget_exhaustions,
		"failed_evaluations": _failed_evaluations,
		"history_fingerprints": history_fingerprints,
	})


func last_native_status() -> Dictionary:
	var result := _last_native_status.duplicate(true)
	_make_deep_read_only(result)
	return result


func teardown(expected_generation: int) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.ACTIVE:
		return _reject(&"vision_owner_not_active")
	if expected_generation != _generation:
		return _reject(&"stale_generation")
	if _is_advancing or _inside_phase_handler:
		return _reject(&"vision_teardown_during_tick")

	_dispose_native_world()
	lifecycle = Lifecycle.TORN_DOWN
	_generation += 1
	_world_id = 0
	_configuration = {}
	_configuration_fingerprint = ""
	_provenance_fingerprint = ""
	_raid_authority_ref = null
	_raid_authority_instance_id = 0
	_raid_authority_generation = 0
	return true


func _exit_tree() -> void:
	if lifecycle == Lifecycle.ACTIVE:
		teardown(_generation)


func _metrics_are_valid(metrics: Dictionary) -> bool:
	for key in ["requested", "consumed", "completed", "invalidated", "deferred"]:
		if not metrics.has(key) or typeof(metrics[key]) != TYPE_INT or int(metrics[key]) < 0:
			return false
	var maximum_requested := NATIVE_MAX_OBSERVERS \
		* ZerkovVisionConfig.NATIVE_MAX_WORK_UNITS
	return (
		int(metrics["requested"]) <= maximum_requested
		and int(metrics["consumed"]) <= ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION
		and int(metrics["completed"]) <= NATIVE_MAX_OBSERVERS
		and int(metrics["deferred"]) <= NATIVE_MAX_OBSERVERS
		and int(metrics["invalidated"]) == 0
		and int(metrics["completed"]) + int(metrics["deferred"]) <= NATIVE_MAX_OBSERVERS
	)


func _bounded_add(current: int, amount: int) -> int:
	if amount <= 0:
		return current
	var limit := ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT
	if current >= limit - mini(amount, limit):
		return limit
	return current + amount


func _native_status_copy(status: Dictionary) -> Dictionary:
	return {
		"ok": bool(status.get("ok", false)),
		"code": int(status.get("code", 0)),
		"diagnostic": int(status.get("diagnostic", 0)),
		"detail": int(status.get("detail", 0)),
	}


func _dispose_native_world() -> void:
	if _native_world == null or not is_instance_valid(_native_world):
		_native_world = null
		return
	if _native_world.get_parent() == self:
		remove_child(_native_world)
	_native_world.queue_free()
	_native_world = null


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


static func _make_deep_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		for key in dictionary:
			_make_deep_read_only(dictionary[key])
		dictionary.make_read_only()
	elif value is Array:
		var array := value as Array
		for child in array:
			_make_deep_read_only(child)
		array.make_read_only()
