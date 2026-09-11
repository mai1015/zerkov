class_name RaidVisionWorldOwner
extends Node
## Game-owned authoritative Common Vision world for one raid generation.
##
## Task 6.1 owns configuration, deterministic authority cadence, bounded work,
## telemetry, and teardown only. Actor/target/occluder lifecycle and AI-facing
## projections deliberately have no production port in this slice.
##
## The live CommonVisionWorld2D exists only in lexical state captured by an
## opaque Callable. No Object/Resource property on this owner retains it, and
## the Callable can only advance while RaidAuthority attests this exact owner,
## generation, phase, tick, and reserved callback slot.

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
const PHASE_HANDLER_ID: StringName = RaidAuthority.RESERVED_VISION_HANDLER_ID
const NATIVE_MAX_OBSERVERS: int = 4_096

const _RUNTIME_ADVANCE: StringName = &"advance_attested"
const _RUNTIME_DISPOSE: StringName = &"dispose_attested"
const _RUNTIME_STATUS: StringName = &"status"
const _RAID_AUTHORITY_SCRIPT_PATH: String = "res://game/raid/raid_authority.gd"
const _ANONYMOUS_CALLABLE_METHOD: StringName = &"<anonymous lambda>"
const _ATTEST_REGISTER_REQUEST: StringName = \
	&"vision_owner_registration_request"
const _ATTEST_RELEASE_REQUEST: StringName = &"vision_owner_release_request"
const _ATTEST_PREDELETE_REQUEST: StringName = &"vision_owner_predelete_request"
const _ATTEST_QUARANTINE: StringName = &"vision_owner_quarantine"
const _ATTEST_RUNTIME_DISPOSE: StringName = &"vision_runtime_dispose"
const _ATTEST_AUTHORITY_RELEASE: StringName = \
	&"raid_vision_owner_binding_release"

var lifecycle: Lifecycle = Lifecycle.NOT_STARTED
var last_error: StringName = &""

var _generation: int = 0
var _world_id: int = 0
var _configuration: Dictionary = {}
var _configuration_fingerprint: String = ""
var _provenance_fingerprint: String = ""

# The Callable owns inaccessible lexical state. Its bound-argument list is
# empty and its Callable object is this script resource, never the native node.
var _runtime_dispatch: Callable = Callable():
	set(value):
		# configure() installs the dispatcher exactly once. It stays as an inert
		# status capability after disposal so Object.set() cannot replace the
		# only path that can destroy the captured native allocation.
		if not _runtime_dispatch.is_valid():
			_runtime_dispatch = value
var _runtime_alive: bool = false

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
var _binding_registered: bool = false
var _binding_consumed: bool = false

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
	if lifecycle != Lifecycle.NOT_STARTED or _runtime_alive \
			or _runtime_dispatch.is_valid():
		return _reject(&"owner_already_configured")
	if world_id <= 0 or world_id > ZerkovVisionConfig.WORLD_ID_MAX:
		return _reject(&"vision_world_id_invalid")

	var candidate := ZerkovVisionConfig.configuration() \
		if configuration_record.is_empty() else configuration_record.duplicate(true)
	var validation := ZerkovVisionConfig.validate_configuration(candidate, true)
	if not bool(validation.get("ok", false)):
		return _reject(StringName(validation.get(
			"reason", &"vision_configuration_invalid"
		)))
	var preflight := ZerkovVisionConfig.runtime_preflight()
	if not bool(preflight.get("ok", false)):
		return _reject(StringName(preflight.get(
			"reason", &"vision_runtime_incompatible"
		)))

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

	# This state is captured by the lambda and cannot be reached through
	# Object.get(), get_property_list(), Callable.get_object(), or the Callable's
	# (empty) bound-argument list. No operation returns the native value.
	var runtime_state := {
		"alive": true,
		"native": native_world,
	}
	var captured_owner_id := get_instance_id()
	var captured_owner_generation := 1
	_runtime_dispatch = func(operation: StringName, request: Dictionary) -> Dictionary:
		if operation == _RUNTIME_STATUS:
			return {"ok": true, "alive": bool(runtime_state["alive"])}
		var owner_value: Variant = request.get("owner", null)
		if not owner_value is RaidVisionWorldOwner \
				or not is_instance_valid(owner_value) \
				or (owner_value as RaidVisionWorldOwner).get_instance_id() \
					!= captured_owner_id:
			return {"ok": false, "reason": "runtime_owner_invalid"}
		var owner := owner_value as RaidVisionWorldOwner
		if operation == _RUNTIME_DISPOSE:
			if not _has_exact_keys(request, PackedStringArray([
				"owner", "owner_generation", "attestation",
			])) or typeof(request.get("owner_generation", null)) != TYPE_INT \
					or int(request["owner_generation"]) != captured_owner_generation \
					or not _transient_attestation_is_valid(
						request.get("attestation", null),
						owner.get_script(),
						_ATTEST_RUNTIME_DISPOSE,
						{
							"owner_instance_id": captured_owner_id,
							"owner_generation": captured_owner_generation,
						},
					):
				return {"ok": false, "reason": "runtime_disposal_unauthorized"}
			if not bool(runtime_state["alive"]):
				return {"ok": true, "alive": false}
			var native_value: Variant = runtime_state["native"]
			if native_value is CommonVisionWorld2D and is_instance_valid(native_value):
				(native_value as CommonVisionWorld2D).free()
			runtime_state["native"] = null
			runtime_state["alive"] = false
			return {"ok": true, "alive": false}
		if operation != _RUNTIME_ADVANCE \
				or not bool(runtime_state["alive"]) \
				or not _has_exact_keys(request, PackedStringArray([
					"owner", "raid_authority", "phase", "tick",
					"owner_generation", "raid_generation", "work_budget",
				])):
			return {"ok": false, "reason": "runtime_operation_rejected"}
		for integer_key in [
			"phase", "tick", "owner_generation", "raid_generation", "work_budget",
		]:
			if typeof(request.get(integer_key, null)) != TYPE_INT:
				return {"ok": false, "reason": "runtime_request_invalid"}
		var raid_value: Variant = request.get("raid_authority", null)
		if not raid_value is RaidAuthority or not is_instance_valid(raid_value) \
				or int(request["owner_generation"]) != captured_owner_generation \
				or int(request["work_budget"]) \
					!= ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION:
			return {"ok": false, "reason": "runtime_request_invalid"}
		var raid := raid_value as RaidAuthority
		var phase: RaidAuthority.TickPhase = int(request["phase"])
		var tick := int(request["tick"])
		var raid_generation := int(request["raid_generation"])
		if not raid.is_dispatching_vision_world_owner(
			owner, phase, tick, captured_owner_generation, raid_generation
		):
			return {"ok": false, "reason": "runtime_dispatch_unattested"}
		var native_value: Variant = runtime_state["native"]
		if not native_value is CommonVisionWorld2D or not is_instance_valid(native_value):
			return {"ok": false, "reason": "runtime_native_invalid"}
		return (native_value as CommonVisionWorld2D).advance(
			tick, int(request["work_budget"])
		).duplicate(true)

	_runtime_alive = true
	_configuration = candidate.duplicate(true)
	_make_deep_read_only(_configuration)
	_configuration_fingerprint = String(validation.get("fingerprint", ""))
	_provenance_fingerprint = String(preflight.get("fingerprint", ""))
	_world_id = world_id
	_generation = captured_owner_generation
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
		and _runtime_alive \
		and _runtime_dispatch.is_valid() \
		and not is_queued_for_deletion()


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
		"canonical_coordinate_limit_raw": ZWorldUnits.MAX_VISION_CANONICAL_RAW,
		"cadence_first_tick": ZerkovVisionConfig.CADENCE_FIRST_TICK,
		"cadence_interval_ticks": ZerkovVisionConfig.CADENCE_INTERVAL_TICKS,
		"work_budget_per_evaluation": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
		"phase_handler_id": String(PHASE_HANDLER_ID),
		"native_handle_exposed": false,
		"actor_lifecycle_ports_exposed": false,
		"runtime_storage": "opaque_closure",
	}
	_make_deep_read_only(result)
	return result


## Claims the fixed Vision slot with a one-call anonymous attestation. The
## authority derives and records the callback without accepting a caller-
## supplied identity or reusable capability.
func register_with_raid_authority(raid_authority: RaidAuthority) -> bool:
	last_error = &""
	if not is_current_generation(_generation):
		return _reject(&"vision_owner_inactive")
	if raid_authority == null or not is_instance_valid(raid_authority):
		return _reject(&"raid_authority_invalid")
	if _binding_consumed or _binding_registered:
		return _reject(&"raid_authority_already_registered")
	if _last_attempted_tick != 0:
		return _reject(&"vision_tick_driver_already_started")
	var captured_raid_generation := raid_authority.generation()
	_raid_authority_ref = weakref(raid_authority)
	_raid_authority_instance_id = raid_authority.get_instance_id()
	_raid_authority_generation = captured_raid_generation
	var attestation_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
		"authority_instance_id": _raid_authority_instance_id,
		"raid_generation": captured_raid_generation,
	}
	var registration_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation,
			request,
			_ATTEST_REGISTER_REQUEST,
			attestation_context,
		)
	if not raid_authority.register_vision_world_owner(
		self, _generation, captured_raid_generation, registration_attestation
	):
		var reason := raid_authority.last_error
		# Registration has not published a live owner binding yet, so rollback is
		# kept inside this validated boundary instead of exposing a mutable helper.
		_binding_registered = false
		_raid_authority_ref = null
		_raid_authority_instance_id = 0
		_raid_authority_generation = 0
		return _reject(reason)
	_binding_registered = true
	_binding_consumed = true
	return true


func is_registered_binding_current(
	raid_authority: RaidAuthority,
	owner_generation: int,
	raid_generation: int
) -> bool:
	return _binding_registered \
		and _binding_values_match(raid_authority, owner_generation, raid_generation) \
		and lifecycle == Lifecycle.ACTIVE \
		and _runtime_alive \
		and not is_queued_for_deletion()


## Authority-owned release callback. An owner that has already participated in
## simulation or merely held the reserved slot is quarantined and loses the
## runtime synchronously. The proof is transient and bound to both objects and
## generations; no writable property grants this authority.
func release_registered_binding(
	raid_authority: RaidAuthority,
	owner_generation: int,
	raid_generation: int,
	attestation: Variant = Callable()
) -> bool:
	if raid_authority == null or not is_instance_valid(raid_authority) \
			or not _transient_attestation_is_valid(
				attestation,
				_RAID_AUTHORITY_SCRIPT_PATH,
				_ATTEST_AUTHORITY_RELEASE,
				{
					"authority_instance_id": raid_authority.get_instance_id(),
					"raid_generation": raid_generation,
					"owner_instance_id": get_instance_id(),
					"owner_generation": owner_generation,
				},
			) or not _binding_values_match(
			raid_authority, owner_generation, raid_generation
		):
		return false
	var disposal_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
	}
	var disposal_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_RUNTIME_DISPOSE, disposal_context
		)
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.QUARANTINED:
		lifecycle = Lifecycle.QUARANTINED
		if not _dispose_native_runtime(disposal_attestation):
			return false
	# Keep the clear in the already authority-attested callback. A separate
	# reflectively callable clearing helper would split the two-sided binding.
	_binding_registered = false
	_raid_authority_ref = null
	_raid_authority_instance_id = 0
	_raid_authority_generation = 0
	return true


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
	if not raid_authority.is_dispatching_vision_world_owner(
		self, phase, tick, _generation, _raid_authority_generation
	):
		return _reject(&"vision_phase_attestation_failed")
	if _inside_phase_handler:
		return _reject(&"vision_phase_reentrant")
	_inside_phase_handler = true
	var advanced := _advance_attested_tick(raid_authority, phase, tick)
	_inside_phase_handler = false
	return advanced


## Advances only from the exact synchronously executing reserved owner slot.
## The signature deliberately contains no delta/time input.
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
			or not raid_authority.is_dispatching_vision_world_owner(
				self, phase, tick, _generation, _raid_authority_generation
			):
		return _reject(&"vision_phase_attestation_failed")
	if tick <= 0 or tick > ZerkovVisionConfig.TELEMETRY_COUNTER_LIMIT:
		return _reject(&"vision_tick_out_of_range")
	if tick != _last_attempted_tick + 1:
		return _reject(&"vision_tick_regressed_or_skipped")

	var lifecycle_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
	}
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation != _ATTEST_QUARANTINE \
				and operation != _ATTEST_RUNTIME_DISPOSE:
			return {"ok": false}
		return _answer_attestation(
			operation, request, operation, lifecycle_context
		)
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
	var native_result := _dispatch_runtime_advance(raid_authority, phase, tick)
	_last_native_status = _native_status_copy(native_result)
	if not _metrics_are_valid(native_result):
		_failed_evaluations = _bounded_add(_failed_evaluations, 1)
		_append_invalid_metrics_failure(tick, native_result)
		if not _quarantine(lifecycle_attestation):
			_is_advancing = false
			return _reject(&"vision_quarantine_attestation_failed")
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
		if not _quarantine(lifecycle_attestation):
			_is_advancing = false
			return _reject(&"vision_quarantine_attestation_failed")
		_is_advancing = false
		return _reject(&"vision_native_advance_failed")

	_last_successful_tick = tick
	_last_evaluation_tick = tick
	_evaluation_ticks = _bounded_add(_evaluation_ticks, 1)
	_is_advancing = false
	return true


## Single overridable result boundary used by the isolated contract fixture to
## inject a documented native failure record. It accepts/returns values only;
## no native Object or actor lifecycle operation crosses this seam. Production
## RaidAuthority accepts only this base script, so an overriding subclass can
## run only behind the contract's test-local authority fixture.
func _dispatch_runtime_advance(
	raid_authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int
) -> Dictionary:
	if not _runtime_dispatch.is_valid():
		return {"ok": false, "reason": "runtime_capability_invalid"}
	var result: Variant = _runtime_dispatch.call(_RUNTIME_ADVANCE, {
		"owner": self,
		"raid_authority": raid_authority,
		"phase": int(phase),
		"tick": tick,
		"owner_generation": _generation,
		"raid_generation": _raid_authority_generation,
		"work_budget": ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION,
	})
	return result as Dictionary if result is Dictionary else {}


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
	var release_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
		"authority_instance_id": _raid_authority_instance_id,
		"raid_generation": _raid_authority_generation,
	}
	var release_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_RELEASE_REQUEST, release_context
		)
	# Releasing the authority slot is the commit precondition. In particular, a
	# later phase callback cannot ignore RaidAuthority's in-tick rejection and
	# then destroy the runtime behind the still-registered Vision handler.
	if not _release_authority_for_teardown(release_attestation):
		return false
	var disposal_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
	}
	var disposal_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_RUNTIME_DISPOSE, disposal_context
		)
	if not _dispose_native_runtime(disposal_attestation):
		return _reject(&"vision_runtime_disposal_failed")
	lifecycle = Lifecycle.TORN_DOWN
	_generation += 1
	_world_id = 0
	_configuration = {}
	_configuration_fingerprint = ""
	_provenance_fingerprint = ""
	_binding_registered = false
	_raid_authority_ref = null
	_raid_authority_instance_id = 0
	_raid_authority_generation = 0
	return true


func _exit_tree() -> void:
	# `_exit_tree` is directly callable by ordinary project GDScript while this
	# node is still live and parented, so it must never mint lifecycle authority.
	# A real queued destruction reaches NOTIFICATION_PREDELETE first and is
	# authenticated there by Object's engine-owned deletion-queue state.
	pass


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE \
			or (lifecycle != Lifecycle.ACTIVE \
				and lifecycle != Lifecycle.QUARANTINED):
		return
	# GDScript may invoke `_notification(NOTIFICATION_PREDELETE)` directly. Only
	# Object's engine-owned queued-for-deletion bit proves this is the real
	# destruction path. An unqueued direct `free()` is canceled as well: callers
	# must use queue_free() so the owner cannot disappear before its authority,
	# reserved slot, and native runtime are reconciled atomically.
	if not is_queued_for_deletion():
		cancel_free()
		return
	var predelete_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
		"authority_instance_id": _raid_authority_instance_id,
		"raid_generation": _raid_authority_generation,
	}
	var predelete_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_PREDELETE_REQUEST, predelete_context
		)
	_fail_authority_for_predelete(predelete_attestation)
	var disposal_context := {
		"owner_instance_id": get_instance_id(),
		"owner_generation": _generation,
	}
	var disposal_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_RUNTIME_DISPOSE, disposal_context
		)
	_dispose_native_runtime(disposal_attestation)
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.QUARANTINED:
		lifecycle = Lifecycle.TORN_DOWN
		_generation += 1
	_binding_registered = false
	_raid_authority_ref = null
	_raid_authority_instance_id = 0
	_raid_authority_generation = 0


func _binding_values_match(
	raid_authority: RaidAuthority,
	owner_generation: int,
	raid_generation: int
) -> bool:
	var captured_authority: Variant = _raid_authority_ref.get_ref() \
		if _raid_authority_ref != null else null
	return (
		raid_authority != null
		and is_instance_valid(raid_authority)
		and captured_authority == raid_authority
		and raid_authority.get_instance_id() == _raid_authority_instance_id
		and owner_generation == _generation
		and raid_generation == _raid_authority_generation
		and raid_authority.generation() == raid_generation
	)


func _bound_authority_matches(raid_authority: RaidAuthority) -> bool:
	return _binding_registered \
		and _binding_values_match(
			raid_authority, _generation, _raid_authority_generation
		) \
		and (raid_authority.lifecycle == RaidAuthority.Lifecycle.PREPARING \
			or raid_authority.lifecycle == RaidAuthority.Lifecycle.ACTIVE \
			or raid_authority.lifecycle == RaidAuthority.Lifecycle.EXTRACTING)


func _release_authority_for_teardown(
	attestation: Variant = Callable()
) -> bool:
	if not _binding_registered or _raid_authority_ref == null:
		return true
	var raid_value: Variant = _raid_authority_ref.get_ref()
	if not raid_value is RaidAuthority or not is_instance_valid(raid_value):
		return true
	var raid := raid_value as RaidAuthority
	var released := raid.release_vision_world_owner(
		self, _generation, _raid_authority_generation, attestation
	)
	if not released:
		var reason := raid.last_error
		return _reject(reason if not reason.is_empty() \
			else &"vision_authority_release_failed")
	if _binding_registered:
		return _reject(&"vision_authority_release_incomplete")
	return true


func _fail_authority_for_predelete(
	attestation: Variant = Callable()
) -> bool:
	if not _binding_registered or _raid_authority_ref == null:
		return true
	var raid_value: Variant = _raid_authority_ref.get_ref()
	if not raid_value is RaidAuthority or not is_instance_valid(raid_value):
		return true
	return (raid_value as RaidAuthority).fail_vision_world_owner_predelete(
		self, _generation, _raid_authority_generation, attestation
	)


## Deliberately inert compatibility trap for reflective callers. Binding state
## mutates only inside the registration rollback, authority-attested release,
## explicit teardown, or engine-authenticated PREDELETE boundaries above.
func _clear_authority_binding(_attestation: Variant = Callable()) -> bool:
	return false


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


func _quarantine(attestation: Variant = Callable()) -> bool:
	if not _transient_attestation_is_valid(
		attestation,
		get_script(),
		_ATTEST_QUARANTINE,
		{
			"owner_instance_id": get_instance_id(),
			"owner_generation": _generation,
		},
	):
		return false
	lifecycle = Lifecycle.QUARANTINED
	# Whole-call native failure may leave an immutable publication prefix. The
	# opaque runtime is invalidated immediately; recovery requires a new owner.
	return _dispose_native_runtime(attestation)


func _metrics_are_valid(metrics: Dictionary) -> bool:
	if typeof(metrics.get("ok", null)) != TYPE_BOOL \
			or typeof(metrics.get("code", null)) != TYPE_INT \
			or typeof(metrics.get("diagnostic", null)) != TYPE_INT \
			or typeof(metrics.get("detail", null)) != TYPE_INT:
		return false
	for key in ["requested", "consumed", "completed", "invalidated", "deferred"]:
		if not metrics.has(key) or typeof(metrics[key]) != TYPE_INT \
				or int(metrics[key]) < 0:
			return false
	var maximum_requested := NATIVE_MAX_OBSERVERS \
		* ZerkovVisionConfig.NATIVE_MAX_WORK_UNITS
	return (
		int(metrics["requested"]) <= maximum_requested
		and int(metrics["consumed"]) <= ZerkovVisionConfig.WORK_BUDGET_PER_EVALUATION
		and int(metrics["completed"]) <= NATIVE_MAX_OBSERVERS
		and int(metrics["deferred"]) <= NATIVE_MAX_OBSERVERS
		and int(metrics["invalidated"]) == 0
		and int(metrics["completed"]) + int(metrics["deferred"]) \
			<= NATIVE_MAX_OBSERVERS
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


func _dispose_native_runtime(attestation: Variant = Callable()) -> bool:
	if not _runtime_dispatch.is_valid():
		return not _runtime_alive
	var result: Variant = _runtime_dispatch.call(_RUNTIME_DISPOSE, {
		"owner": self,
		"owner_generation": _generation,
		"attestation": attestation,
	})
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		_last_native_status = {
			"ok": false,
			"code": 0,
			"diagnostic": 0,
			"detail": 0,
		}
		return false
	_runtime_alive = false
	# The shared lexical `alive` bit makes both the owner-held status dispatcher
	# and every retained copy inert synchronously.
	return true


static func _transient_attestation_is_valid(
	candidate: Variant,
	expected_script: Variant,
	operation: StringName,
	context: Dictionary
) -> bool:
	if not candidate is Callable:
		return false
	var attestation := candidate as Callable
	if not _callable_has_exact_script(attestation, expected_script):
		return false
	var challenge := RefCounted.new()
	var request := context.duplicate(true)
	request["challenge"] = challenge
	var result: Variant = attestation.call(operation, request)
	if not result is Dictionary:
		return false
	var response := result as Dictionary
	return _has_exact_keys(response, PackedStringArray(["ok", "challenge"])) \
		and typeof(response.get("ok", null)) == TYPE_BOOL \
		and bool(response["ok"]) \
		and response.get("challenge", null) == challenge


static func _callable_has_exact_script(
	candidate: Callable,
	expected_script: Variant
) -> bool:
	if not candidate.is_valid() \
			or candidate.get_method() != _ANONYMOUS_CALLABLE_METHOD \
			or candidate.get_bound_arguments_count() != 0:
		return false
	var expected_resource: Variant = ResourceLoader.load(expected_script) \
		if expected_script is String else expected_script
	return expected_resource is Script \
		and candidate.get_object() == expected_resource


static func _answer_attestation(
	operation: StringName,
	request: Dictionary,
	expected_operation: StringName,
	expected_context: Dictionary
) -> Dictionary:
	if operation != expected_operation \
			or request.size() != expected_context.size() + 1 \
			or not request.get("challenge", null) is RefCounted:
		return {"ok": false}
	for key in expected_context:
		if not request.has(key) or request[key] != expected_context[key]:
			return {"ok": false}
	return {"ok": true, "challenge": request["challenge"]}


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


static func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


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
