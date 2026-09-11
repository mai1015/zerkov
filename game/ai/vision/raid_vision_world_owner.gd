class_name RaidVisionWorldOwner
extends Node
## Game-owned authoritative Common Vision world for one raid generation.
##
## The native node is retained privately and never attached to the scene tree or
## returned to callers. All mutation ports are sealed-profile,
## generation/binding-checked operations intended for the task-6.2 lifecycle
## owner. Only the bound RaidAuthority's authenticated VISION slot can advance
## time; this owner has no render-delta or public direct-tick driver.

enum Lifecycle {
	NOT_STARTED,
	ACTIVE,
	QUARANTINED,
	TORN_DOWN,
}

const LIFECYCLE_NAMES: PackedStringArray = [
	"not_started",
	"active",
	"quarantined",
	"torn_down",
]
const PHASE_HANDLER_ID: StringName = &"raid_vision_world"
const NATIVE_MAX_OBSERVERS: int = 4_096
const NATIVE_MAX_OCCLUDER_SEGMENTS: int = 131_072

var lifecycle: Lifecycle = Lifecycle.NOT_STARTED
var last_error: StringName = &""

var _generation: int = 0
var _world_id: int = 0
var _configuration: Dictionary = {}
var _configuration_fingerprint: String = ""
var _provenance_fingerprint: String = ""
var _native_world: CommonVisionWorld2D
var _last_attempted_tick: int = 0
var _last_successful_tick: int = 0
var _last_evaluation_tick: int = 0
var _last_attempted_evaluation_tick: int = 0
var _last_tick_was_evaluation: bool = false
var _is_advancing: bool = false
var _inside_phase_handler: bool = false
var _raid_authority_ref: WeakRef
var _raid_authority_instance_id: int = 0
var _raid_authority_generation: int = 0
var _history: Array[Dictionary] = []
var _last_native_status: Dictionary = {}

var _ticks_received: int = 0
var _evaluation_attempts: int = 0
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

	# A detached Node has no public scene-tree traversal path. The owner keeps
	# the only native reference and frees it synchronously on failure/teardown.
	_native_world = native_world
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
		"canonical_coordinate_limit_raw": ZWorldUnits.MAX_CANONICAL_RAW,
		"cadence_first_tick": ZerkovVisionConfig.CADENCE_FIRST_TICK,
		"cadence_interval_ticks": ZerkovVisionConfig.CADENCE_INTERVAL_TICKS,
		"work_budget_per_evaluation": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"phase_handler_id": String(PHASE_HANDLER_ID),
		"native_handle_exposed": false,
	}
	_make_deep_read_only(result)
	return result


## Claims the one fixed Vision-owner slot while RaidAuthority is PREPARING.
## There is intentionally no caller-selected handler identity.
func register_with_raid_authority(raid_authority: RaidAuthority) -> bool:
	last_error = &""
	if not is_current_generation(_generation):
		return _reject(&"vision_owner_inactive")
	if raid_authority == null or not is_instance_valid(raid_authority):
		return _reject(&"raid_authority_invalid")
	if _raid_authority_instance_id != 0:
		return _reject(&"raid_authority_already_registered")
	if _last_attempted_tick != 0:
		return _reject(&"vision_tick_driver_already_started")
	var captured_raid_generation := raid_authority.generation()
	if not raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.VISION,
		PHASE_HANDLER_ID,
		Callable(self, "_handle_raid_phase"),
		captured_raid_generation,
	):
		return _reject(raid_authority.last_error)
	_raid_authority_ref = weakref(raid_authority)
	_raid_authority_instance_id = raid_authority.get_instance_id()
	_raid_authority_generation = captured_raid_generation
	return true


## The following ports are the only production route to native world state.
## They apply sealed profiles and require the exact bound raid and owner
## generation. Task 6.2 remains responsible for actor identity, transform
## revisions, liveness, and when these ports are invoked.
func set_occluder_segments(
	raid_authority: RaidAuthority,
	segments: Array,
	geometry_revision: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	if geometry_revision <= 0 \
			or geometry_revision > ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT:
		return _reject(&"vision_geometry_revision_invalid")
	if segments.size() > NATIVE_MAX_OCCLUDER_SEGMENTS:
		return _reject(&"vision_occluder_limit")
	var accepted: Array[Dictionary] = []
	var segment_ids: Dictionary = {}
	for segment_value in segments:
		if not segment_value is Dictionary:
			return _reject(&"vision_occluder_invalid")
		var segment := segment_value as Dictionary
		if not _has_exact_keys(segment, PackedStringArray([
			"id", "a", "b", "mask", "two_sided",
		])) or not _all_int_fields(segment, PackedStringArray(["id", "mask"])):
			return _reject(&"vision_occluder_invalid")
		var segment_id := int(segment["id"])
		var mask := int(segment["mask"])
		if segment_id <= 0 or segment_ids.has(segment_id) \
				or mask <= 0 or mask & ZerkovVisionConfig.OCCLUDER_LAYER_ALL != mask \
				or typeof(segment["two_sided"]) != TYPE_BOOL \
				or not bool(segment["two_sided"]):
			return _reject(&"vision_occluder_invalid")
		if not _point_dictionary_is_valid(segment["a"]) \
				or not _point_dictionary_is_valid(segment["b"]) \
				or segment["a"] == segment["b"]:
			return _reject(&"vision_occluder_invalid")
		segment_ids[segment_id] = true
		accepted.append(segment.duplicate(true))
	return _accept_native_mutation(
		_native_world.set_occluder_segments(accepted, geometry_revision)
	)


func register_observer(
	raid_authority: RaidAuthority,
	observer_id: int,
	profile_id: String,
	position_raw: Vector2i,
	facing_raw: Vector2i,
	revision: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	var definition := _observer_definition(
		observer_id, profile_id, position_raw, facing_raw, revision
	)
	if definition.is_empty():
		return _reject(&"vision_observer_definition_invalid")
	return _accept_native_mutation(_native_world.register_observer(definition))


func update_observer(
	raid_authority: RaidAuthority,
	observer_id: int,
	profile_id: String,
	position_raw: Vector2i,
	facing_raw: Vector2i,
	revision: int,
	expected_revision: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	if expected_revision <= 0 \
			or expected_revision >= ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT \
			or revision != expected_revision + 1:
		return _reject(&"vision_observer_revision_invalid")
	var definition := _observer_definition(
		observer_id, profile_id, position_raw, facing_raw, revision
	)
	if definition.is_empty():
		return _reject(&"vision_observer_definition_invalid")
	return _accept_native_mutation(
		_native_world.update_observer(definition, expected_revision)
	)


func remove_observer(
	raid_authority: RaidAuthority,
	observer_id: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	if observer_id <= 0:
		return _reject(&"vision_observer_id_invalid")
	return _accept_native_mutation(_native_world.remove_observer(observer_id))


func register_target(
	raid_authority: RaidAuthority,
	target_id: int,
	profile_id: String,
	position_raw: Vector2i,
	revision: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	var definition := _target_definition(target_id, profile_id, position_raw, revision)
	if definition.is_empty():
		return _reject(&"vision_target_definition_invalid")
	return _accept_native_mutation(_native_world.register_target(definition))


func update_target(
	raid_authority: RaidAuthority,
	target_id: int,
	profile_id: String,
	position_raw: Vector2i,
	revision: int,
	expected_revision: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	if expected_revision <= 0 \
			or expected_revision >= ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT \
			or revision != expected_revision + 1:
		return _reject(&"vision_target_revision_invalid")
	var definition := _target_definition(target_id, profile_id, position_raw, revision)
	if definition.is_empty():
		return _reject(&"vision_target_definition_invalid")
	return _accept_native_mutation(
		_native_world.update_target(definition, expected_revision)
	)


func remove_target(
	raid_authority: RaidAuthority,
	target_id: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return false
	if target_id <= 0:
		return _reject(&"vision_target_id_invalid")
	return _accept_native_mutation(_native_world.remove_target(target_id))


## Returns the add-on's detached value copy after recursively making it
## read-only. No returned value can configure, mutate, query, or advance the
## private native world.
func observer_projection(
	raid_authority: RaidAuthority,
	observer_id: int,
	expected_generation: int
) -> Dictionary:
	last_error = &""
	if not _check_bound_access(raid_authority, expected_generation):
		return _read_only_failure(last_error)
	if observer_id <= 0:
		last_error = &"vision_observer_id_invalid"
		return _read_only_failure(last_error)
	var projection: Dictionary = _native_world.get_projection(observer_id).duplicate(true)
	_make_deep_read_only(projection)
	return projection


func _handle_raid_phase(
	raid_authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	last_error = &""
	if not _bound_authority_matches(raid_authority):
		return _reject(&"raid_authority_binding_invalid")
	if phase != RaidAuthority.TickPhase.VISION:
		return _reject(&"vision_phase_invalid")
	if not raid_authority.is_dispatching_phase_handler(
		phase,
		tick,
		PHASE_HANDLER_ID,
		_raid_authority_generation,
	):
		return _reject(&"vision_phase_attestation_failed")
	if _inside_phase_handler:
		return _reject(&"vision_phase_reentrant")
	_inside_phase_handler = true
	var advanced := _advance_attested_tick(raid_authority, phase, tick)
	_inside_phase_handler = false
	return advanced


## Advances only from the exact synchronously executing fixed phase slot. The
## signature deliberately contains no delta/time input.
func _advance_attested_tick(
	raid_authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int
) -> bool:
	if _is_advancing:
		return _reject(&"vision_tick_reentrant")
	if not is_current_generation(_generation):
		return _reject(&"vision_owner_inactive")
	if not _inside_phase_handler \
			or not raid_authority.is_dispatching_phase_handler(
				phase, tick, PHASE_HANDLER_ID, _raid_authority_generation
			):
		return _reject(&"vision_phase_attestation_failed")
	if tick <= 0 or tick > ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT:
		return _reject(&"vision_tick_out_of_range")
	if tick != _last_attempted_tick + 1:
		return _reject(&"vision_tick_regressed_or_skipped")

	_is_advancing = true
	var evaluates := ZerkovVisionConfig.is_evaluation_tick(tick)
	_last_attempted_tick = tick
	_last_tick_was_evaluation = evaluates
	_ticks_received = _bounded_add(_ticks_received, 1)
	if not evaluates:
		_last_successful_tick = tick
		_cadence_skips = _bounded_add(_cadence_skips, 1)
		_is_advancing = false
		return true

	_last_attempted_evaluation_tick = tick
	_evaluation_attempts = _bounded_add(_evaluation_attempts, 1)
	var native_result := _native_world.advance(
		tick,
		ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
	)
	_last_native_status = _native_status_copy(native_result)
	if not _metrics_are_valid(native_result):
		_failed_evaluations = _bounded_add(_failed_evaluations, 1)
		_append_invalid_metrics_failure(tick, native_result)
		_quarantine()
		_is_advancing = false
		return _reject(&"vision_native_metrics_invalid")

	var requested := int(native_result["requested"])
	var consumed := int(native_result["consumed"])
	var completed := int(native_result["completed"])
	var deferred := int(native_result["deferred"])
	var invalidated := int(native_result["invalidated"])
	var exhausted := deferred > 0 \
		or requested > ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION
	var native_ok := bool(native_result.get("ok", false))
	_append_metrics_record(
		tick, native_ok, requested, consumed, completed, deferred, invalidated, exhausted
	)
	_account_metrics(requested, consumed, completed, deferred, exhausted)
	if not native_ok:
		_failed_evaluations = _bounded_add(_failed_evaluations, 1)
		_quarantine()
		_is_advancing = false
		return _reject(&"vision_native_advance_failed")

	_last_successful_tick = tick
	_last_evaluation_tick = tick
	_evaluation_ticks = _bounded_add(_evaluation_ticks, 1)
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
		"last_tick": _last_attempted_tick,
		"last_attempted_tick": _last_attempted_tick,
		"last_successful_tick": _last_successful_tick,
		"last_evaluation_tick": _last_evaluation_tick,
		"last_attempted_evaluation_tick": _last_attempted_evaluation_tick,
		"last_tick_was_evaluation": _last_tick_was_evaluation,
		"cadence_first_tick": ZerkovVisionConfig.CADENCE_FIRST_TICK,
		"cadence_interval_ticks": ZerkovVisionConfig.CADENCE_INTERVAL_TICKS,
		"work_budget_per_evaluation": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"history_limit": ZerkovVisionConfig.TELEMETRY_HISTORY_LIMIT,
		"ticks_received": _ticks_received,
		"evaluation_attempts": _evaluation_attempts,
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


## Fingerprints the bounded summary (not recipient records). History entries
## are represented by individual hashes so the canonical value stays below
## ZCanonicalValue's node bound at the 64-entry history limit.
func telemetry_fingerprint() -> String:
	var history_fingerprints: Array[String] = []
	for record in _history:
		history_fingerprints.append(ZCanonicalValue.sha256(record))
	return ZCanonicalValue.sha256({
		"lifecycle": String(lifecycle_name()),
		"world_id": _world_id,
		"generation": _generation,
		"configuration_fingerprint": _configuration_fingerprint,
		"provenance_fingerprint": _provenance_fingerprint,
		"last_attempted_tick": _last_attempted_tick,
		"last_successful_tick": _last_successful_tick,
		"last_evaluation_tick": _last_evaluation_tick,
		"last_attempted_evaluation_tick": _last_attempted_evaluation_tick,
		"last_tick_was_evaluation": _last_tick_was_evaluation,
		"ticks_received": _ticks_received,
		"evaluation_attempts": _evaluation_attempts,
		"evaluation_ticks": _evaluation_ticks,
		"cadence_skips": _cadence_skips,
		"requested_work_units": _requested_work_units,
		"consumed_work_units": _consumed_work_units,
		"completed_observers": _completed_observers,
		"deferred_observers": _deferred_observers,
		"budget_exhaustions": _budget_exhaustions,
		"failed_evaluations": _failed_evaluations,
		"last_native_status": _last_native_status,
		"history_fingerprints": history_fingerprints,
	})


func last_native_status() -> Dictionary:
	var result := _last_native_status.duplicate(true)
	_make_deep_read_only(result)
	return result


func teardown(expected_generation: int) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.ACTIVE and lifecycle != Lifecycle.QUARANTINED:
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
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.QUARANTINED:
		teardown(_generation)


func _check_bound_access(
	raid_authority: RaidAuthority,
	expected_generation: int
) -> bool:
	if expected_generation != _generation:
		return _reject(&"stale_generation")
	if lifecycle == Lifecycle.QUARANTINED:
		return _reject(&"vision_owner_quarantined")
	if not is_current_generation(expected_generation):
		return _reject(&"vision_owner_inactive")
	if not _bound_authority_matches(raid_authority):
		return _reject(&"raid_authority_binding_invalid")
	return true


func _bound_authority_matches(raid_authority: RaidAuthority) -> bool:
	var captured_authority: Variant = _raid_authority_ref.get_ref() \
		if _raid_authority_ref != null else null
	return (
		raid_authority != null
		and is_instance_valid(raid_authority)
		and captured_authority == raid_authority
		and raid_authority.get_instance_id() == _raid_authority_instance_id
		and raid_authority.generation() == _raid_authority_generation
		and (
			raid_authority.lifecycle == RaidAuthority.Lifecycle.PREPARING
			or raid_authority.lifecycle == RaidAuthority.Lifecycle.ACTIVE
			or raid_authority.lifecycle == RaidAuthority.Lifecycle.EXTRACTING
		)
	)


func _observer_definition(
	observer_id: int,
	profile_id: String,
	position_raw: Vector2i,
	facing_raw: Vector2i,
	revision: int
) -> Dictionary:
	if observer_id <= 0 or revision <= 0 \
			or revision > ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT \
			or not _point_is_valid(position_raw) \
			or not _point_is_valid(facing_raw) \
			or facing_raw == Vector2i.ZERO:
		return {}
	var profile := ZerkovVisionConfig.observer_profile(profile_id)
	if profile.is_empty():
		return {}
	return {
		"id": observer_id,
		"position": _point(position_raw),
		"facing": _point(facing_raw),
		"range": int(profile["range_raw"]),
		"cone_cos_million": int(profile["cone_cos_million"]),
		"full_circle": bool(profile["full_circle"]),
		"target_mask": int(profile["target_mask"]),
		"occluder_mask": int(profile["occluder_mask"]),
		"memory_ticks": int(profile["memory_ticks"]),
		"priority": int(profile["priority"]),
		"urgent": bool(profile["urgent"]),
		"revision": revision,
	}


func _target_definition(
	target_id: int,
	profile_id: String,
	position_raw: Vector2i,
	revision: int
) -> Dictionary:
	if target_id <= 0 or revision <= 0 \
			or revision > ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT \
			or not _point_is_valid(position_raw):
		return {}
	var profile := ZerkovVisionConfig.target_profile(profile_id)
	if profile.is_empty():
		return {}
	var offsets := (profile["sample_offsets"] as Array).duplicate(true)
	for offset_value in offsets:
		var offset := offset_value as Dictionary
		var sample := Vector2i(
			position_raw.x + int(offset["x"]),
			position_raw.y + int(offset["y"]),
		)
		if not _point_is_valid(sample):
			return {}
	return {
		"id": target_id,
		"position": _point(position_raw),
		"mask": int(profile["mask"]),
		"sample_policy": int(profile["sample_policy"]),
		"sample_offsets": offsets,
		"revision": revision,
	}


func _accept_native_mutation(native_result: Dictionary) -> bool:
	_last_native_status = _native_status_copy(native_result)
	if not bool(native_result.get("ok", false)):
		return _reject(&"vision_native_mutation_failed")
	return true


func _append_metrics_record(
	tick: int,
	ok: bool,
	requested: int,
	consumed: int,
	completed: int,
	deferred: int,
	invalidated: int,
	exhausted: bool
) -> void:
	var record := {
		"ok": ok,
		"tick": tick,
		"budget": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"requested": requested,
		"consumed": consumed,
		"completed": completed,
		"deferred": deferred,
		"invalidated": invalidated,
		"budget_exhausted": exhausted,
		"native_code": int(_last_native_status.get("code", 0)),
		"native_diagnostic": int(_last_native_status.get("diagnostic", 0)),
		"native_detail": int(_last_native_status.get("detail", 0)),
		"terminal": not ok,
	}
	_history.append(record)
	if _history.size() > ZerkovVisionConfig.TELEMETRY_HISTORY_LIMIT:
		_history.pop_front()


func _append_invalid_metrics_failure(tick: int, native_result: Dictionary) -> void:
	var record := {
		"ok": false,
		"tick": tick,
		"budget": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"metrics_valid": false,
		"native_code": int(_last_native_status.get("code", 0)),
		"native_diagnostic": int(_last_native_status.get("diagnostic", 0)),
		"native_detail": int(_last_native_status.get("detail", 0)),
		"native_keys": PackedStringArray(native_result.keys()).duplicate(),
		"terminal": true,
	}
	_history.append(record)
	if _history.size() > ZerkovVisionConfig.TELEMETRY_HISTORY_LIMIT:
		_history.pop_front()


func _account_metrics(
	requested: int,
	consumed: int,
	completed: int,
	deferred: int,
	exhausted: bool
) -> void:
	_requested_work_units = _bounded_add(_requested_work_units, requested)
	_consumed_work_units = _bounded_add(_consumed_work_units, consumed)
	_completed_observers = _bounded_add(_completed_observers, completed)
	_deferred_observers = _bounded_add(_deferred_observers, deferred)
	if exhausted:
		_budget_exhaustions = _bounded_add(_budget_exhaustions, 1)


func _quarantine() -> void:
	lifecycle = Lifecycle.QUARANTINED
	# Whole-call native failure may leave an immutable publication prefix. Free
	# the private world immediately so no subsequent call can advance or mutate
	# that partial state. Recovery is a fresh owner/generation after teardown.
	_dispose_native_world()


func _metrics_are_valid(metrics: Dictionary) -> bool:
	if typeof(metrics.get("ok", null)) != TYPE_BOOL \
			or typeof(metrics.get("code", null)) != TYPE_INT \
			or typeof(metrics.get("diagnostic", null)) != TYPE_INT \
			or typeof(metrics.get("detail", null)) != TYPE_INT:
		return false
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
	var result := {
		"ok": bool(status.get("ok", false)),
		"code": int(status["code"]) if typeof(status.get("code", null)) == TYPE_INT else 0,
		"diagnostic": int(status["diagnostic"]) \
			if typeof(status.get("diagnostic", null)) == TYPE_INT else 0,
		"detail": int(status["detail"]) \
			if typeof(status.get("detail", null)) == TYPE_INT else 0,
	}
	for key in ["requested", "consumed", "completed", "invalidated", "deferred"]:
		if typeof(status.get(key, null)) == TYPE_INT:
			result[key] = int(status[key])
	return result


func _dispose_native_world() -> void:
	if _native_world == null or not is_instance_valid(_native_world):
		_native_world = null
		return
	_native_world.free()
	_native_world = null


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


static func _point(value: Vector2i) -> Dictionary:
	return {"x": value.x, "y": value.y}


static func _point_is_valid(point: Vector2i) -> bool:
	return absi(point.x) <= ZWorldUnits.MAX_CANONICAL_RAW \
		and absi(point.y) <= ZWorldUnits.MAX_CANONICAL_RAW


static func _point_dictionary_is_valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var point := value as Dictionary
	return (
		_has_exact_keys(point, PackedStringArray(["x", "y"]))
		and _all_int_fields(point, PackedStringArray(["x", "y"]))
		and absi(int(point["x"])) <= ZWorldUnits.MAX_CANONICAL_RAW
		and absi(int(point["y"])) <= ZWorldUnits.MAX_CANONICAL_RAW
	)


static func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


static func _all_int_fields(value: Dictionary, keys: PackedStringArray) -> bool:
	for key in keys:
		if not value.has(key) or typeof(value[key]) != TYPE_INT:
			return false
	return true


static func _read_only_failure(reason: StringName) -> Dictionary:
	var result := {"ok": false, "reason": String(reason)}
	_make_deep_read_only(result)
	return result


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
