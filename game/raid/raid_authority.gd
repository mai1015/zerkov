class_name RaidAuthority
extends RefCounted
## Single game-owned authority boundary for one raid generation.

enum Lifecycle {
	PREPARING,
	ACTIVE,
	EXTRACTING,
	SETTLING,
	COMPLETED,
	FAILED,
	TORN_DOWN,
}

enum TickPhase {
	ADMIT_INTENTS,
	MOVEMENT,
	VISION,
	AI_DECISIONS,
	INTERACTIONS_AND_WEAPONS,
	WORLD_CONSEQUENCES,
	ABILITIES_AND_DUE_WORK,
	TASKS_AND_AUDIT,
	PUBLISH_PROJECTIONS,
}

class PhaseHandlerRelay:
	extends RefCounted

	signal invoked(
		authority: RaidAuthority,
		phase: TickPhase,
		tick: int,
		intents: Array[ZRaidIntent],
		result_box: Array
	)

	var callback_identity: String = ""
	var bridge_connection_identity: String = ""

	func configure(callback: Callable, identity: String) -> bool:
		if not callback.is_valid() or identity.is_empty() \
				or not callback_identity.is_empty():
			return false
		callback_identity = identity
		var bridge := func(
			authority: RaidAuthority,
			phase: TickPhase,
			tick: int,
			intents: Array[ZRaidIntent],
			result_box: Array
		) -> void:
			if not authority.phase_handler_callback_is_safe(callback):
				result_box.append(false)
				return
			result_box.append(callback.call(authority, phase, tick, intents))
		invoked.connect(bridge)
		var connections := get_signal_connection_list(&"invoked")
		if connections.size() != 1:
			return false
		var connected_callable := (
			(connections[0] as Dictionary).get("callable", Callable()) as Callable)
		bridge_connection_identity = _connection_identity(
			connected_callable)
		return not bridge_connection_identity.is_empty()

	func invoke(
		authority: RaidAuthority,
		phase: TickPhase,
		tick: int,
		intents: Array[ZRaidIntent]
	) -> Variant:
		var connections := get_signal_connection_list(&"invoked")
		if connections.size() != 1 \
				or _connection_identity(
					(connections[0] as Dictionary).get("callable", Callable())) \
					!= bridge_connection_identity:
			return null
		var result_box: Array = []
		invoked.emit(authority, phase, tick, intents, result_box)
		if result_box.size() != 1:
			return null
		return result_box[0]

	func _connection_identity(callback: Callable) -> String:
		if not callback.is_valid():
			return ""
		var owner := callback.get_object()
		if owner == null or not is_instance_valid(owner):
			return ""
		return ZCanonicalValue.sha256({
			"object_instance_id": owner.get_instance_id(),
			"method": String(callback.get_method()),
			"bound_argument_count": callback.get_bound_arguments_count(),
		})

const LIFECYCLE_NAMES: PackedStringArray = [
	"preparing",
	"active",
	"extracting",
	"settling",
	"completed",
	"failed",
	"torn_down",
]

const PHASE_NAMES: PackedStringArray = [
	"admit_intents",
	"movement",
	"vision",
	"ai_decisions",
	"interactions_and_weapons",
	"world_consequences",
	"abilities_and_due_work",
	"tasks_and_audit",
	"publish_projections",
]

const MAX_HANDLERS_PER_PHASE: int = 16
const MAX_HANDLER_DEPENDENCIES: int = 8
const MAX_HANDLER_REGISTRATIONS: int = 256
const MIN_PHASE_HANDLER_PRIORITY: int = -1_024
const MAX_PHASE_HANDLER_PRIORITY: int = 1_024
## This identity is owned by RaidAuthority. Generic handler registration may
## never claim it, even in another phase.
const RESERVED_VISION_HANDLER_ID: StringName = &"raid_vision_world"
const VISION_OWNER_SCRIPT_PATH: String = \
	"res://game/ai/vision/raid_vision_world_owner.gd"
const _ATTEST_TERMINAL_READ: StringName = &"raid_terminal_cause_read"
const _ATTEST_TERMINAL_COMMIT: StringName = &"raid_terminal_cause_commit"
const _ATTEST_TERMINAL_SEAL: StringName = &"raid_terminal_runtime_seal"
const _ATTEST_OWNER_RELEASE: StringName = &"raid_vision_owner_binding_release"
const _ATTEST_HANDLER_REGISTER: StringName = &"raid_phase_handler_register"
const _ATTEST_OWNER_REGISTER_REQUEST: StringName = \
	&"vision_owner_registration_request"
const _ATTEST_OWNER_RELEASE_REQUEST: StringName = \
	&"vision_owner_release_request"
const _ATTEST_OWNER_PREDELETE_REQUEST: StringName = \
	&"vision_owner_predelete_request"
const _ANONYMOUS_CALLABLE_METHOD: StringName = &"<anonymous lambda>"
const _TERMINAL_LATCH_INVALID: StringName = &"terminal_cause_latch_invalid"

var lifecycle: Lifecycle = Lifecycle.PREPARING
var _last_operation_error: StringName = &""
var _terminal_latch_dispatch: Callable = Callable():
	set(value):
		# Construction installs this once. Reflection may read the non-authorizing
		# dispatcher for diagnostics, but cannot swap out its lexical cause state.
		if not _terminal_latch_dispatch.is_valid():
			_terminal_latch_dispatch = value
var last_error: StringName:
	get:
		var terminal_cause := _read_terminal_cause()
		return terminal_cause if not terminal_cause.is_empty() \
			else _last_operation_error
	set(value):
		# Once the opaque terminal latch commits an owner-loss cause, neither
		# ordinary API reentry nor Object.set() can replace the observable cause.
		if _read_terminal_cause().is_empty():
			_last_operation_error = value
var last_processed_tick: int = 0
var last_phase_trace: PackedStringArray = PackedStringArray()
var clock: RaidClock
var journal: RaidEventJournal
var rng: ZRaidRng

var _raid_id: ZRaidId
var _admission: ZSessionAdmission
var _intent_queue := ZRaidIntentQueue.new()
var _generation: int = 0
var _configured: bool = false
var _is_advancing: bool = false
var _processing_tick: int = 0
var _processing_phase: int = -1
var _processing_handler_id: StringName = &""
var _processing_handler_registration_id: String = ""
var _processing_handler_callback_identity: String = ""
var _tick_handler_roster_commitment: String = ""
var _named_phase_handlers_only: bool = false
var _phase_handlers: Dictionary = {}
var _handler_ids: Dictionary = {}
var _issued_handler_registration_ids: Dictionary = {}
var _authorized_actor_sources: Dictionary = {}
var _weapon_actor_states: Dictionary = {}
var _vision_owner_ref: WeakRef
var _vision_owner_instance_id: int = 0
var _vision_owner_generation: int = 0
var _vision_owner_raid_generation: int = 0


func _init() -> void:
	# The terminal cause lives only in lexical closure state. The reflected
	# Callable permits authenticated reads, but commit requires a fresh,
	# operation-bound anonymous proof created inside the validated failure path.
	var terminal_state := {"cause": StringName()}
	var captured_authority_id := get_instance_id()
	var captured_authority_script: Variant = get_script()
	_terminal_latch_dispatch = func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation == _ATTEST_TERMINAL_READ:
			if not _has_exact_keys(request, PackedStringArray([
				"authority_instance_id", "challenge",
			])) or typeof(request.get("authority_instance_id", null)) != TYPE_INT \
					or int(request["authority_instance_id"]) \
						!= captured_authority_id \
					or not request.get("challenge", null) is RefCounted:
				return {"ok": false}
			return {
				"ok": true,
				"challenge": request["challenge"],
				"cause": terminal_state["cause"],
			}
		if operation != _ATTEST_TERMINAL_COMMIT \
				or not _has_exact_keys(request, PackedStringArray([
					"authority_instance_id", "raid_generation", "cause",
					"owner_instance_id", "owner_generation", "attestation",
					"challenge",
				])) or typeof(request.get("authority_instance_id", null)) != TYPE_INT \
				or int(request["authority_instance_id"]) != captured_authority_id \
				or typeof(request.get("raid_generation", null)) != TYPE_INT \
				or typeof(request.get("owner_instance_id", null)) != TYPE_INT \
				or typeof(request.get("owner_generation", null)) != TYPE_INT \
				or typeof(request.get("cause", null)) != TYPE_STRING_NAME \
				or not request.get("challenge", null) is RefCounted:
			return {"ok": false}
		var candidate_cause := request["cause"] as StringName
		if candidate_cause != &"vision_owner_destroyed" \
				and candidate_cause != &"vision_owner_lost_during_tick":
			return {"ok": false}
		var commit_context := {
			"authority_instance_id": captured_authority_id,
			"raid_generation": int(request["raid_generation"]),
			"owner_instance_id": int(request["owner_instance_id"]),
			"owner_generation": int(request["owner_generation"]),
			"cause": candidate_cause,
		}
		if not _transient_attestation_is_valid(
			request.get("attestation", null),
			captured_authority_script,
			_ATTEST_TERMINAL_COMMIT,
			commit_context,
		):
			return {"ok": false}
		if (terminal_state["cause"] as StringName).is_empty():
			terminal_state["cause"] = candidate_cause
		return {
			"ok": true,
			"challenge": request["challenge"],
			"cause": terminal_state["cause"],
		}


func configure(raid_id: ZRaidId, admission: ZSessionAdmission, seed: int) -> bool:
	last_error = &""
	if _configured:
		return _reject(&"authority_already_configured")
	if raid_id == null or not raid_id.is_initialized():
		return _reject(&"raid_id_invalid")
	if admission == null or not admission.is_usable():
		return _reject(&"session_admission_invalid")
	var raid_copy := ZRaidId.parse(raid_id.canonical_key())
	var admission_copy := admission.snapshot()
	if raid_copy == null or admission_copy == null:
		return _reject(&"session_admission_invalid")
	if not admission_copy.raid_id.is_equal(raid_copy):
		return _reject(&"session_raid_mismatch")

	_raid_id = raid_copy
	_admission = admission_copy
	_generation = admission_copy.generation
	clock = RaidClock.new()
	journal = RaidEventJournal.new()
	if not journal.configure(raid_id):
		return _reject(&"journal_configuration_failed")
	rng = ZRaidRng.new(seed)
	_configured = true
	_authorize_actor_source(admission_copy.actor_id, ZRaidIntent.Source.PLAYER)
	return true


func generation() -> int:
	return _generation


func raid_id() -> ZRaidId:
	return ZRaidId.parse(_raid_id.canonical_key()) if _raid_id != null else null


func admission() -> ZSessionAdmission:
	return _admission.snapshot() if _admission != null else null


func lifecycle_name() -> StringName:
	return StringName(LIFECYCLE_NAMES[int(lifecycle)])


func transition(next: Lifecycle, expected_generation: int) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if _is_advancing:
		return _reject(&"transition_during_tick")
	if not _can_transition(lifecycle, next):
		return _reject(&"lifecycle_transition_invalid")
	var lifecycle_context := _authority_lifecycle_attestation_context()
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation != _ATTEST_TERMINAL_SEAL \
				and operation != _ATTEST_OWNER_RELEASE:
			return {"ok": false}
		return _answer_attestation(
			operation, request, operation, lifecycle_context
		)
	lifecycle = next
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.EXTRACTING:
		clock.resume()
	else:
		clock.pause()
	if lifecycle == Lifecycle.COMPLETED or lifecycle == Lifecycle.FAILED:
		clock.clear_pending()
		if not _seal_terminal_runtime(lifecycle_attestation):
			return _reject(&"raid_terminal_seal_failed")
	return true


func authorize_actor(
	actor_id: ZEntityId,
	source: ZRaidIntent.Source,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.PREPARING:
		return _reject(&"actor_authorization_closed")
	if int(source) < ZRaidIntent.Source.PLAYER or int(source) > ZRaidIntent.Source.SYSTEM:
		return _reject(&"source_invalid")
	if actor_id == null or ZEntityId.parse(actor_id.canonical_key()) == null:
		return _reject(&"actor_id_invalid")
	_authorize_actor_source(actor_id, source)
	return true


## Side-effect-free authorization port for game-owned boundaries that must
## prove an actor/source belongs to this exact raid authority. The backing set
## remains private so callers cannot enumerate or mutate authority ownership.
func has_authorized_actor_source(
	actor_id: ZEntityId,
	source: ZRaidIntent.Source,
	expected_generation: int
) -> bool:
	if not _is_current_generation(expected_generation):
		return false
	if int(source) < ZRaidIntent.Source.PLAYER or int(source) > ZRaidIntent.Source.SYSTEM:
		return false
	if actor_id == null or ZEntityId.parse(actor_id.canonical_key()) == null:
		return false
	return _authorized_actor_sources.has(_actor_source_key(actor_id, source))


## Read-only phase authentication for synchronous game-owned adapters.  A
## signal emitted by a domain façade is admitted only while the exact raid
## generation is executing the domain's documented phase and tick.
func is_processing_tick_phase(
	phase: TickPhase,
	tick: int,
	expected_generation: int
) -> bool:
	return _is_mutable_generation(expected_generation) \
		and _is_advancing \
		and int(phase) >= 0 \
		and int(phase) < PHASE_NAMES.size() \
		and _processing_phase == int(phase) \
		and _processing_tick == tick


## Exact, non-reusable registration provenance for security-sensitive phase
## consumers. Handler names are reusable composition labels and are not an
## authority proof by themselves.
func phase_handler_registration_id(
	handler_id: StringName,
	expected_generation: int
) -> String:
	if not _is_current_generation(expected_generation):
		return ""
	var registration := _handler_ids.get(handler_id, {}) as Dictionary
	return String(registration.get("registration_id", ""))


func has_exact_phase_handler(
	handler_id: StringName,
	registration_id: String,
	callback: Callable,
	phase: TickPhase,
	expected_generation: int
) -> bool:
	if not _is_current_generation(expected_generation) \
			or registration_id.is_empty() or not callback.is_valid():
		return false
	var registration := _handler_ids.get(handler_id, {}) as Dictionary
	var callback_identity := _phase_callback_identity(callback)
	return not registration.is_empty() \
		and String(registration.get("registration_id", "")) == registration_id \
		and int(registration.get("phase", -1)) == int(phase) \
		and not callback_identity.is_empty() \
		and String(registration.get("callback_identity", "")) == callback_identity


func is_dispatching_phase_registration(
	handler_id: StringName,
	registration_id: String,
	callback: Callable,
	phase: TickPhase,
	tick: int,
	expected_generation: int
) -> bool:
	return is_processing_tick_phase(phase, tick, expected_generation) \
		and _processing_handler_id == handler_id \
		and _processing_handler_registration_id == registration_id \
		and _processing_handler_callback_identity \
			== _phase_callback_identity(callback) \
		and has_exact_phase_handler(
			handler_id, registration_id, callback, phase, expected_generation)


func register_phase_handler(
	phase: TickPhase,
	handler_id: StringName,
	callback: Callable,
	expected_generation: int,
	priority: int = 0,
	after_handler_ids: PackedStringArray = PackedStringArray()
) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.PREPARING:
		return _reject(&"handler_registration_closed")
	if int(phase) < 0 or int(phase) >= PHASE_NAMES.size():
		return _reject(&"phase_invalid")
	if handler_id == RESERVED_VISION_HANDLER_ID:
		return _reject(&"handler_id_reserved")
	if not ZIdentityRules.is_valid_part(String(handler_id)) or not callback.is_valid():
		return _reject(&"handler_invalid")
	if _named_phase_handlers_only and _phase_callback_is_anonymous(callback):
		return _reject(&"anonymous_phase_handler_forbidden")
	if not phase_handler_callback_is_safe(callback):
		return _reject(&"handler_callback_retains_capability")
	var callback_identity := _phase_callback_identity(callback)
	if callback_identity.is_empty():
		return _reject(&"handler_callback_identity_invalid")
	if priority < MIN_PHASE_HANDLER_PRIORITY or priority > MAX_PHASE_HANDLER_PRIORITY:
		return _reject(&"handler_priority_invalid")
	if after_handler_ids.size() > MAX_HANDLER_DEPENDENCIES:
		return _reject(&"handler_dependency_limit")
	if _handler_ids.has(handler_id):
		return _reject(&"handler_id_duplicate")
	var dependencies := PackedStringArray()
	for dependency_value in after_handler_ids:
		var dependency_id := StringName(dependency_value)
		if not ZIdentityRules.is_valid_part(String(dependency_id)) \
				or dependency_id == handler_id \
				or dependencies.has(String(dependency_id)):
			return _reject(&"handler_dependency_invalid")
		var dependency := _handler_ids.get(dependency_id, {}) as Dictionary
		if dependency.is_empty() or int(dependency.get("phase", -1)) != int(phase):
			return _reject(&"handler_dependency_missing")
		var dependency_priority := int(dependency.get("priority", 0))
		if dependency_priority > priority \
				or (dependency_priority == priority \
					and String(dependency_id) >= String(handler_id)):
			return _reject(&"handler_dependency_order_invalid")
		dependencies.append(String(dependency_id))
	# Generic Vision handlers may not consume the authority-owned slot's final
	# capacity before the real owner registers.
	if phase == TickPhase.VISION \
			and not _handler_ids.has(RESERVED_VISION_HANDLER_ID) \
			and (_phase_handlers.get(int(phase), []) as Array).size() \
				>= MAX_HANDLERS_PER_PHASE - 1:
		return _reject(&"phase_handler_limit")
	var registration_context := {
		"authority_instance_id": get_instance_id(),
		"raid_generation": _generation,
		"phase": int(phase),
		"handler_id": handler_id,
		"callback": callback,
		"priority": priority,
		"after": dependencies,
	}
	var registration_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_HANDLER_REGISTER, registration_context
		)
	return _register_phase_handler_unchecked(
		phase, handler_id, callback, priority, dependencies,
		registration_attestation,
	)


## A live spatial bearer and an opaque callable closure must never coexist in
## the retained phase graph. BodyHitboxWorld2D calls this before issuing its
## capability; later handler registrations must be named Object methods.
func require_named_phase_handlers(expected_generation: int) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.PREPARING:
		return _reject(&"handler_registration_closed")
	for registration_value in _handler_ids.values():
		var registration := registration_value as Dictionary
		if bool(registration.get("anonymous", true)):
			return _reject(&"anonymous_phase_handler_forbidden")
		var relay := registration.get("relay") as PhaseHandlerRelay
		if relay == null or not is_instance_valid(relay):
			return _reject(&"phase_handler_registration_corrupted")
		var connections := relay.get_signal_connection_list(&"invoked")
		if connections.size() != 1:
			return _reject(&"phase_handler_registration_corrupted")
	_named_phase_handlers_only = true
	return true


## Claims the sole game-owned Vision slot. The authority derives the callback
## from the concrete configured owner; callers cannot supply an identity or
## Callable. The owner's provisional binding is checked before anything is
## published into the phase table.
func register_vision_world_owner(
	owner: RaidVisionWorldOwner,
	owner_generation: int,
	expected_generation: int,
	attestation: Variant = Callable()
) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.PREPARING:
		return _reject(&"handler_registration_closed")
	if owner == null or not is_instance_valid(owner):
		return _reject(&"vision_owner_invalid")
	if not _is_exact_vision_owner(owner):
		return _reject(&"vision_owner_type_invalid")
	if owner_generation <= 0:
		return _reject(&"vision_owner_generation_invalid")
	if _vision_owner_instance_id != 0 \
			or _handler_ids.has(RESERVED_VISION_HANDLER_ID):
		return _reject(&"vision_owner_slot_claimed")
	if not _transient_attestation_is_valid(
		attestation,
		VISION_OWNER_SCRIPT_PATH,
		_ATTEST_OWNER_REGISTER_REQUEST,
		{
			"owner_instance_id": owner.get_instance_id(),
			"owner_generation": owner_generation,
			"authority_instance_id": get_instance_id(),
			"raid_generation": expected_generation,
		},
	):
		return _reject(&"vision_owner_registration_attestation_invalid")
	var callback := Callable(owner, "_handle_raid_phase")
	if not callback.is_valid():
		return _reject(&"vision_owner_callback_invalid")
	var dependencies := PackedStringArray()
	var registration_context := {
		"authority_instance_id": get_instance_id(),
		"raid_generation": _generation,
		"phase": int(TickPhase.VISION),
		"handler_id": RESERVED_VISION_HANDLER_ID,
		"callback": callback,
		"priority": 0,
		"after": dependencies,
	}
	var registration_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		return _answer_attestation(
			operation, request, _ATTEST_HANDLER_REGISTER, registration_context
		)
	if not _register_phase_handler_unchecked(
		TickPhase.VISION, RESERVED_VISION_HANDLER_ID, callback, 0,
		dependencies, registration_attestation
	):
		return false
	_vision_owner_ref = weakref(owner)
	_vision_owner_instance_id = owner.get_instance_id()
	_vision_owner_generation = owner_generation
	_vision_owner_raid_generation = expected_generation
	return true


## Releases a matching owner before simulation starts. Once ticks can run, a
## disappearing Vision authority terminalizes the raid instead of silently
## continuing without perception.
func release_vision_world_owner(
	owner: RaidVisionWorldOwner,
	owner_generation: int,
	expected_generation: int,
	attestation: Variant = Callable()
) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if not _vision_owner_matches(owner, owner_generation, expected_generation):
		return _reject(&"vision_owner_binding_invalid")
	if not _transient_attestation_is_valid(
		attestation,
		VISION_OWNER_SCRIPT_PATH,
		_ATTEST_OWNER_RELEASE_REQUEST,
		{
			"owner_instance_id": owner.get_instance_id(),
			"owner_generation": owner_generation,
			"authority_instance_id": get_instance_id(),
			"raid_generation": expected_generation,
		},
	):
		return _reject(&"vision_owner_release_attestation_invalid")
	if _is_advancing:
		return _reject(&"vision_owner_release_during_tick")
	var lifecycle_context := _authority_lifecycle_attestation_context()
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation != _ATTEST_TERMINAL_SEAL \
				and operation != _ATTEST_OWNER_RELEASE:
			return {"ok": false}
		return _answer_attestation(
			operation, request, operation, lifecycle_context
		)
	if lifecycle == Lifecycle.PREPARING:
		if _phase_handler_has_dependents(RESERVED_VISION_HANDLER_ID):
			return _reject(&"handler_has_dependents")
		if not _release_vision_owner_binding(lifecycle_attestation):
			return _reject(&"vision_owner_binding_release_failed")
		return true
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.EXTRACTING:
		lifecycle = Lifecycle.FAILED
		if not _seal_terminal_runtime(lifecycle_attestation):
			return _reject(&"raid_terminal_seal_failed")
		return true
	return _reject(&"vision_owner_release_closed")


## Handles the one release case that cannot be made fail-atomic: the bound
## owner is already inside NOTIFICATION_PREDELETE and must cease to exist. A
## PREPARING owner with no dependents still uses the ordinary release path;
## this fallback terminalizes every other live composition and clears the
## owner slot and complete dependency graph synchronously. The current tick
## remains marked as advancing until its callback unwinds.
func fail_vision_world_owner_predelete(
	owner: RaidVisionWorldOwner,
	owner_generation: int,
	expected_generation: int,
	attestation: Variant = Callable()
) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if not _vision_owner_matches(owner, owner_generation, expected_generation):
		return _reject(&"vision_owner_binding_invalid")
	if not _transient_attestation_is_valid(
		attestation,
		VISION_OWNER_SCRIPT_PATH,
		_ATTEST_OWNER_PREDELETE_REQUEST,
		{
			"owner_instance_id": owner.get_instance_id(),
			"owner_generation": owner_generation,
			"authority_instance_id": get_instance_id(),
			"raid_generation": expected_generation,
		},
	):
		return _reject(&"vision_owner_predelete_attestation_invalid")
	if lifecycle != Lifecycle.PREPARING \
			and lifecycle != Lifecycle.ACTIVE \
			and lifecycle != Lifecycle.EXTRACTING \
			and lifecycle != Lifecycle.SETTLING:
		return _reject(&"vision_owner_predelete_closed")
	var lifecycle_context := _authority_lifecycle_attestation_context()
	var failure_reason := &"vision_owner_lost_during_tick" \
		if _is_advancing else &"vision_owner_destroyed"
	var commit_context := lifecycle_context.duplicate()
	commit_context["cause"] = failure_reason
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation == _ATTEST_TERMINAL_COMMIT:
			return _answer_attestation(
				operation, request, operation, commit_context
			)
		if operation == _ATTEST_TERMINAL_SEAL \
				or operation == _ATTEST_OWNER_RELEASE:
			return _answer_attestation(
				operation, request, operation, lifecycle_context
			)
		return {"ok": false}
	# A dependency-free PREPARING owner can disappear without terminalizing
	# the raid, but the old owner is still synchronously quarantined before the
	# slot becomes reusable.
	if lifecycle == Lifecycle.PREPARING \
			and not _phase_handler_has_dependents(RESERVED_VISION_HANDLER_ID):
		if not _release_vision_owner_binding(lifecycle_attestation):
			return _reject(&"vision_owner_binding_release_failed")
		return true
	if not _commit_terminal_cause(failure_reason, lifecycle_attestation):
		return _reject(_TERMINAL_LATCH_INVALID)
	lifecycle = Lifecycle.FAILED
	if not _seal_terminal_runtime(lifecycle_attestation):
		return _reject(&"raid_terminal_seal_failed")
	return true


## Read-only phase attestation for game-owned handlers that must reject direct,
## forged, or replayed callback invocation.  It is true only while the exact
## registered slot is synchronously executing for the current authority tick.
func is_dispatching_phase_handler(
	phase: TickPhase,
	tick: int,
	handler_id: StringName,
	expected_generation: int
) -> bool:
	return (
		_is_current_generation(expected_generation)
		and (lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.EXTRACTING)
		and _is_advancing
		and tick > 0
		and _processing_tick == tick
		and clock != null
		and clock.current_tick == tick
		and int(phase) >= 0
		and int(phase) < PHASE_NAMES.size()
		and _processing_phase == int(phase)
		and not handler_id.is_empty()
		and _processing_handler_id == handler_id
	)


## Stronger attestation for the reserved Vision slot. Besides the current
## phase/tick, this binds the exact registered owner object, both generations,
## and the authority-derived callback provenance.
func is_dispatching_vision_world_owner(
	owner: RaidVisionWorldOwner,
	phase: TickPhase,
	tick: int,
	owner_generation: int,
	expected_generation: int
) -> bool:
	if phase != TickPhase.VISION \
			or not is_dispatching_phase_handler(
				phase, tick, RESERVED_VISION_HANDLER_ID, expected_generation
			):
		return false
	if not _vision_owner_matches(owner, owner_generation, expected_generation):
		return false
	return _reserved_vision_callback_is_current()


## Phase-handler lifetimes are explicit and generation-scoped. A provider
## cannot be removed while a registered consumer still declares that provider
## as an ordering dependency; composition tears consumers down first.
func can_unregister_phase_handler(
	handler_id: StringName,
	expected_generation: int
) -> bool:
	last_error = &""
	return _phase_handler_removal_is_valid(handler_id, expected_generation)


func unregister_phase_handler(
	handler_id: StringName,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _phase_handler_removal_is_valid(handler_id, expected_generation):
		return false
	if not _handler_ids.has(handler_id):
		return true
	var registration := _handler_ids[handler_id] as Dictionary
	var phase_value := int(registration.get("phase", -1))
	var handlers: Array = _phase_handlers.get(phase_value, [])
	var retained: Array = []
	for entry_value in handlers:
		if _phase_entry_handler_id(entry_value) != handler_id:
			retained.append(entry_value)
	if retained.is_empty():
		_phase_handlers.erase(phase_value)
	else:
		_phase_handlers[phase_value] = retained
	_handler_ids.erase(handler_id)
	return true


func _phase_handler_removal_is_valid(
	handler_id: StringName,
	expected_generation: int
) -> bool:
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if _is_advancing:
		return _reject(&"handler_change_during_tick")
	if handler_id == RESERVED_VISION_HANDLER_ID:
		return _reject(&"handler_id_reserved")
	if not ZIdentityRules.is_valid_part(String(handler_id)):
		return _reject(&"handler_invalid")
	if not _handler_ids.has(handler_id):
		return true
	if _phase_handler_has_dependents(handler_id):
		return _reject(&"handler_has_dependents")
	return true


func has_phase_handler(handler_id: StringName, expected_generation: int) -> bool:
	return _is_current_generation(expected_generation) and _handler_ids.has(handler_id)


func enqueue_intent(intent: ZRaidIntent, expected_generation: int) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.ACTIVE and lifecycle != Lifecycle.EXTRACTING:
		return _reject(&"raid_not_accepting_intents")
	if intent == null or intent.actor_id == null:
		return _reject(&"intent_actor_invalid")
	var authorization_key := _actor_source_key(intent.actor_id, intent.source)
	if not _authorized_actor_sources.has(authorization_key):
		return _reject(&"actor_source_not_authorized")
	var reference_tick := _processing_tick if _is_advancing else last_processed_tick
	if not _intent_queue.admit(
		intent,
		reference_tick,
		_admission.session_id,
		intent.actor_id,
		_admission.authority_epoch,
		_generation
	):
		last_error = _intent_queue.last_error
		return false
	return true


func request_clock_ticks(count: int, expected_generation: int) -> int:
	last_error = &""
	if not _is_current_generation(expected_generation):
		last_error = &"stale_generation"
		return 0
	if lifecycle != Lifecycle.ACTIVE and lifecycle != Lifecycle.EXTRACTING:
		last_error = &"raid_not_advancing"
		return 0
	return clock.request_ticks(count)


func drain_requested_ticks(expected_generation: int) -> int:
	return _drain_requested_ticks(expected_generation, RaidClock.MAX_CATCH_UP_TICKS_PER_DRAIN)


func _drain_requested_ticks(expected_generation: int, limit: int) -> int:
	last_error = &""
	if _is_advancing:
		last_error = &"reentrant_tick"
		return 0
	if not _is_current_generation(expected_generation):
		last_error = &"stale_generation"
		return 0
	if lifecycle != Lifecycle.ACTIVE and lifecycle != Lifecycle.EXTRACTING:
		last_error = &"raid_not_advancing"
		return 0
	if clock.current_tick != last_processed_tick:
		var lifecycle_context := _authority_lifecycle_attestation_context()
		var lifecycle_attestation := func(
			operation: StringName, request: Dictionary
		) -> Dictionary:
			if operation != _ATTEST_TERMINAL_SEAL \
					and operation != _ATTEST_OWNER_RELEASE:
				return {"ok": false}
			return _answer_attestation(
				operation, request, operation, lifecycle_context
			)
		lifecycle = Lifecycle.FAILED
		clock.reset(last_processed_tick, true)
		if not _seal_terminal_runtime(lifecycle_attestation):
			last_error = &"raid_terminal_seal_failed"
			return 0
		last_error = &"clock_tick_out_of_sync"
		return 0
	var processed := 0
	for _index in mini(limit, RaidClock.MAX_CATCH_UP_TICKS_PER_DRAIN):
		var ticks := clock.drain_catch_up(1)
		if ticks.is_empty():
			break
		if not _process_tick(int(ticks[0]), expected_generation):
			break
		processed += 1
	return processed


func advance_one(expected_generation: int) -> bool:
	last_error = &""
	if _is_advancing:
		# queue_free() commits the bound owner to deletion before PREDELETE is
		# delivered at frame end. If a later handler reenters in that interval,
		# terminalize from the engine-owned queued state now so the committed
		# owner-loss cause cannot be replaced by `reentrant_tick`.
		if _terminalize_queued_vision_owner_during_tick():
			return _reject(&"vision_owner_lost_during_tick")
		return _reject(&"reentrant_tick")
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.ACTIVE and lifecycle != Lifecycle.EXTRACTING:
		return _reject(&"raid_not_advancing")
	if clock.pending_ticks == 0 and request_clock_ticks(1, expected_generation) != 1:
		return false
	return _drain_requested_ticks(expected_generation, 1) == 1


func record_event(
	kind: ZRaidEvent.EventKind,
	event_id: ZConsequenceId,
	tick: int,
	actor_id: ZEntityId,
	payload: Dictionary,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _reject(&"stale_or_terminal_generation")
	var expected_tick := _processing_tick if _is_advancing else last_processed_tick
	if tick != expected_tick:
		return _reject(&"event_tick_invalid")
	if not journal.append(kind, event_id, tick, actor_id, payload):
		last_error = journal.last_error
		return false
	return true


## Exact journal preflight used immediately before a consequence-owning world
## query.  No capacity or identity is consumed by this call.
func can_record_event(
	kind: ZRaidEvent.EventKind,
	event_id: ZConsequenceId,
	tick: int,
	actor_id: ZEntityId,
	payload: Dictionary,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _reject(&"stale_or_terminal_generation")
	var expected_tick := _processing_tick if _is_advancing else last_processed_tick
	if tick != expected_tick:
		return _reject(&"event_tick_invalid")
	if not journal.can_append(kind, event_id, tick, actor_id, payload):
		last_error = journal.last_error
		return false
	return true


func apply_if_current(expected_generation: int, mutation: Callable) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _reject(&"stale_or_terminal_generation")
	if _is_advancing:
		return _reject(&"external_mutation_during_tick")
	if not mutation.is_valid():
		return _reject(&"mutation_invalid")
	mutation.call()
	return true


## Movement is the only phase allowed to publish the current firing pose. The
## conversion happens here because RaidAuthority owns the Godot/fixed-unit
## boundary; Weapon System consumers never receive an untrusted transform.
func publish_weapon_actor_pose(
	actor_id: ZEntityId,
	origin_px: Vector2,
	aim_direction: Vector2,
	tick: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _reject(&"stale_or_terminal_generation")
	if not _is_advancing or _processing_phase != int(TickPhase.MOVEMENT) \
			or tick != _processing_tick:
		return _reject(&"weapon_pose_phase_invalid")
	var actor_key := _authorized_actor_key(actor_id)
	if actor_key.is_empty():
		return _reject(&"weapon_actor_not_authorized")
	var origin := ZWorldUnits.godot_to_weapon(origin_px)
	var aim := ZWorldUnits.godot_direction_to_weapon(aim_direction)
	if not origin.ok:
		return _reject(&"weapon_origin_invalid")
	if not aim.ok:
		return _reject(&"weapon_aim_invalid")
	var state := (_weapon_actor_states.get(actor_key, {}) as Dictionary).duplicate(true)
	var next_pose := {
		"authoritative_origin": origin.vector2i_value,
		"authoritative_aim": aim.vector2i_value,
		"pose_tick": tick,
	}
	if int(state.get("pose_tick", -1)) == tick:
		if state.get("authoritative_origin", Vector2i.ZERO) != origin.vector2i_value \
				or state.get("authoritative_aim", Vector2i.ZERO) != aim.vector2i_value:
			return _reject(&"weapon_pose_tick_conflict")
		return true
	if int(state.get("pose_tick", -1)) > tick:
		return _reject(&"weapon_pose_tick_regressed")
	state.merge(next_pose, true)
	state["actor_id"] = actor_key
	_weapon_actor_states[actor_key] = state
	return true


## Liveness/usability are durable authority facts. They may be initialized
## during PREPARING and then changed only by phase-7 health/due-work owners,
## after the current tick's weapon phase and before the next one.
func publish_weapon_actor_status(
	actor_id: ZEntityId,
	actor_live: bool,
	weapon_usable: bool,
	tick: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_mutable_generation(expected_generation):
		return _reject(&"stale_or_terminal_generation")
	var preparing_publication := lifecycle == Lifecycle.PREPARING \
		and not _is_advancing and tick == 0
	var due_work_publication := _is_advancing \
		and _processing_phase == int(TickPhase.ABILITIES_AND_DUE_WORK) \
		and tick == _processing_tick
	if not preparing_publication and not due_work_publication:
		return _reject(&"weapon_status_phase_invalid")
	var actor_key := _authorized_actor_key(actor_id)
	if actor_key.is_empty():
		return _reject(&"weapon_actor_not_authorized")
	var state := (_weapon_actor_states.get(actor_key, {}) as Dictionary).duplicate(true)
	var previous_tick := int(state.get("status_tick", -1))
	if previous_tick == tick:
		if bool(state.get("actor_live", false)) != actor_live \
				or bool(state.get("weapon_usable", false)) != weapon_usable:
			return _reject(&"weapon_status_tick_conflict")
		return true
	if previous_tick > tick:
		return _reject(&"weapon_status_tick_regressed")
	state["actor_id"] = actor_key
	state["actor_live"] = actor_live
	state["weapon_usable"] = weapon_usable
	state["status_tick"] = tick
	_weapon_actor_states[actor_key] = state
	return true


## Read-only trusted facts for Weapon System fire validation. A current pose is
## mandatory and this provider is intentionally available only during phase 5;
## stale callbacks and out-of-band callers fail closed instead of reusing pose.
func authoritative_weapon_actor_context(
	actor_id: ZEntityId,
	tick: int,
	expected_generation: int
) -> Dictionary:
	if not _is_mutable_generation(expected_generation):
		return {"ok": false, "reason": &"stale_or_terminal_generation"}
	if not _is_advancing \
			or _processing_phase != int(TickPhase.INTERACTIONS_AND_WEAPONS) \
			or tick != _processing_tick:
		return {"ok": false, "reason": &"weapon_context_phase_invalid"}
	var actor_key := _authorized_actor_key(actor_id)
	if actor_key.is_empty():
		return {"ok": false, "reason": &"weapon_actor_not_authorized"}
	var state := _weapon_actor_states.get(actor_key, {}) as Dictionary
	if int(state.get("pose_tick", -1)) != tick:
		return {"ok": false, "reason": &"weapon_pose_stale"}
	if int(state.get("status_tick", -1)) < 0:
		return {"ok": false, "reason": &"weapon_status_missing"}
	var origin := state.get("authoritative_origin", Vector2i.ZERO) as Vector2i
	var aim := state.get("authoritative_aim", Vector2i.ZERO) as Vector2i
	if aim == Vector2i.ZERO:
		return {"ok": false, "reason": &"weapon_aim_invalid"}
	return {
		"ok": true,
		"actor_id": actor_key,
		"tick": tick,
		"status_tick": int(state["status_tick"]),
		"actor_live": bool(state["actor_live"]),
		"weapon_usable": bool(state["weapon_usable"]),
		"authoritative_origin": {"x": origin.x, "y": origin.y},
		"authoritative_aim": {"x": aim.x, "y": aim.y},
	}


func teardown(expected_generation: int) -> bool:
	last_error = &""
	if not _configured or expected_generation != _generation:
		return _reject(&"stale_generation")
	if _is_advancing:
		return _reject(&"teardown_during_tick")
	if lifecycle == Lifecycle.TORN_DOWN:
		return _reject(&"already_torn_down")
	var lifecycle_context := _authority_lifecycle_attestation_context()
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation != _ATTEST_TERMINAL_SEAL \
				and operation != _ATTEST_OWNER_RELEASE:
			return {"ok": false}
		return _answer_attestation(
			operation, request, operation, lifecycle_context
		)
	if not _release_vision_owner_binding(lifecycle_attestation):
		return _reject(&"vision_owner_binding_release_failed")
	lifecycle = Lifecycle.TORN_DOWN
	clock.pause()
	clock.clear_pending()
	clock.seal()
	journal.seal()
	rng.seal()
	_intent_queue.clear()
	_phase_handlers.clear()
	_handler_ids.clear()
	_issued_handler_registration_ids.clear()
	_authorized_actor_sources.clear()
	_weapon_actor_states.clear()
	_generation += 1
	return true


func state_digest() -> String:
	if not _configured:
		return ""
	var state := {
		"authority_epoch": _admission.authority_epoch,
		"generation": _generation,
		"journal": journal.records(),
		"last_processed_tick": last_processed_tick,
		"lifecycle": LIFECYCLE_NAMES[int(lifecycle)],
		"raid_id": _raid_id.canonical_key(),
		"rng_state": rng.state,
		"session_id": _admission.session_id.canonical_key(),
		"weapon_actor_states": _canonical_weapon_actor_states(),
	}
	var direct := ZCanonicalValue.sha256(state)
	if not direct.is_empty():
		return direct
	var journal_digest := journal.digest()
	if journal_digest.is_empty():
		return ""
	state["journal"] = {"digest": journal_digest, "size": journal.size()}
	return ZCanonicalValue.sha256(state)


func _process_tick(tick: int, expected_generation: int) -> bool:
	if _is_advancing:
		return _reject(&"reentrant_tick")
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if lifecycle != Lifecycle.ACTIVE and lifecycle != Lifecycle.EXTRACTING:
		return _reject(&"raid_not_advancing")
	if tick != clock.current_tick:
		return _reject(&"clock_tick_mismatch")
	if tick != last_processed_tick + 1:
		return _reject(&"tick_regressed_or_skipped")

	_tick_handler_roster_commitment = _phase_handler_roster_commitment()
	if _tick_handler_roster_commitment.is_empty():
		return _reject(&"phase_handler_roster_invalid")
	var lifecycle_context := _authority_lifecycle_attestation_context()
	var commit_context := lifecycle_context.duplicate()
	commit_context["cause"] = &"vision_owner_lost_during_tick"
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation == _ATTEST_TERMINAL_COMMIT:
			return _answer_attestation(
				operation, request, operation, commit_context
			)
		if operation != _ATTEST_TERMINAL_SEAL \
				and operation != _ATTEST_OWNER_RELEASE:
			return {"ok": false}
		return _answer_attestation(
			operation, request, operation, lifecycle_context
		)
	_is_advancing = true
	_processing_tick = tick
	last_phase_trace = PackedStringArray()
	# Once a tick starts with the reserved Vision owner, no later callback may
	# make that authority disappear and still let the tick commit. Capture the
	# requirement before any reflectively reachable handler can mutate fields.
	var vision_owner_required_for_tick := _vision_owner_instance_id != 0 \
		or _handler_ids.has(RESERVED_VISION_HANDLER_ID)
	var due_intents: Array[ZRaidIntent] = []
	for phase_value in PHASE_NAMES.size():
		if _phase_handler_roster_commitment() \
				!= _tick_handler_roster_commitment:
			return _fail_current_tick(
				tick, &"phase_handler_registration_corrupted", lifecycle_attestation)
		var phase: TickPhase = phase_value
		_processing_phase = phase_value
		last_phase_trace.append(PHASE_NAMES[phase_value])
		if phase == TickPhase.ADMIT_INTENTS:
			due_intents = _intent_queue.drain_tick(tick)
		var handler_ids: Array = _phase_handlers.get(phase_value, [])
		if not _phase_handler_roster_is_coherent(phase_value, handler_ids):
			return _fail_current_tick(
				tick, &"phase_handler_registration_corrupted", lifecycle_attestation)
		for handler_id_value in handler_ids:
			if typeof(handler_id_value) != TYPE_STRING_NAME \
					and typeof(handler_id_value) != TYPE_STRING \
					and typeof(handler_id_value) != TYPE_DICTIONARY:
				return _fail_current_tick(
					tick, &"phase_handler_registration_corrupted", lifecycle_attestation)
			var handler_id := _phase_entry_handler_id(handler_id_value)
			if handler_id.is_empty():
				return _fail_current_tick(
					tick, &"phase_handler_registration_corrupted", lifecycle_attestation)
			var entry := _handler_ids.get(handler_id, {}) as Dictionary
			if entry.is_empty() \
					or StringName(entry.get("id", &"")) != handler_id \
					or int(entry.get("phase", -1)) != phase_value:
				return _fail_current_tick(
					tick, &"phase_handler_registration_corrupted", lifecycle_attestation)
			var relay := entry.get("relay") as PhaseHandlerRelay
			var callback_identity := String(entry.get("callback_identity", ""))
			var bridge_identity := String(
				entry.get("bridge_connection_identity", ""))
			if relay == null or not is_instance_valid(relay) \
					or callback_identity.is_empty() \
					or bridge_identity.is_empty() \
					or relay.callback_identity != callback_identity \
					or relay.bridge_connection_identity != bridge_identity:
				return _fail_current_tick(
					tick, &"phase_handler_invalidated", lifecycle_attestation)
			_processing_handler_id = handler_id
			_processing_handler_registration_id = String(entry["registration_id"])
			_processing_handler_callback_identity = callback_identity
			if _processing_handler_id == RESERVED_VISION_HANDLER_ID \
					and not _reserved_vision_callback_is_current():
				var invalid_reason := &"vision_owner_lost_during_tick" \
					if _bound_vision_owner_is_queued_for_deletion() \
					else &"vision_owner_provenance_invalid"
				return _fail_current_tick(
					tick, invalid_reason, lifecycle_attestation
				)
			var handler_intents: Array[ZRaidIntent] = []
			for intent in due_intents:
				var intent_copy := intent.snapshot()
				if intent_copy == null:
					return _fail_current_tick(
						tick, &"queued_intent_corrupted", lifecycle_attestation
					)
				handler_intents.append(intent_copy)
			var outcome: Variant = relay.invoke(self, phase, tick, handler_intents)
			_processing_handler_id = &""
			_processing_handler_registration_id = ""
			_processing_handler_callback_identity = ""
			# A PREDELETE fail-stop can terminalize and seal the authority from
			# inside this callback. Finish only the already-consumed tick; do not
			# dispatch another handler or replace the recorded terminal cause.
			if not _read_terminal_cause().is_empty():
				return _finish_preterminalized_tick(tick)
			if vision_owner_required_for_tick \
					and not _reserved_vision_callback_is_current():
				return _fail_current_tick(
					tick, &"vision_owner_lost_during_tick", lifecycle_attestation
				)
			if typeof(outcome) != TYPE_BOOL or not outcome:
				return _fail_current_tick(
					tick, &"phase_handler_failed", lifecycle_attestation
				)
		_processing_phase = -1
	last_processed_tick = tick
	_is_advancing = false
	_processing_tick = 0
	_processing_phase = -1
	_processing_handler_id = &""
	_processing_handler_registration_id = ""
	_processing_handler_callback_identity = ""
	_tick_handler_roster_commitment = ""
	last_error = &""
	return true


func _can_transition(current: Lifecycle, next: Lifecycle) -> bool:
	match current:
		Lifecycle.PREPARING:
			return next == Lifecycle.ACTIVE or next == Lifecycle.FAILED
		Lifecycle.ACTIVE:
			return next == Lifecycle.EXTRACTING or next == Lifecycle.SETTLING or next == Lifecycle.FAILED
		Lifecycle.EXTRACTING:
			return next == Lifecycle.ACTIVE or next == Lifecycle.SETTLING or next == Lifecycle.FAILED
		Lifecycle.SETTLING:
			return next == Lifecycle.COMPLETED or next == Lifecycle.FAILED
		Lifecycle.COMPLETED, Lifecycle.FAILED, Lifecycle.TORN_DOWN:
			return false
	return false


func _is_current_generation(expected_generation: int) -> bool:
	return _configured and expected_generation == _generation and lifecycle != Lifecycle.TORN_DOWN


func _is_mutable_generation(expected_generation: int) -> bool:
	return (
		_is_current_generation(expected_generation)
		and lifecycle != Lifecycle.COMPLETED
		and lifecycle != Lifecycle.FAILED
	)


func _authorize_actor_source(actor_id: ZEntityId, source: ZRaidIntent.Source) -> void:
	_authorized_actor_sources[_actor_source_key(actor_id, source)] = true


func _fail_current_tick(
	tick: int,
	code: StringName,
	lifecycle_attestation: Variant = Callable()
) -> bool:
	# The clock has already consumed this tick. A handler failure is terminal, so
	# retain any committed audit prefix and keep the canonical tick invariant.
	if code == &"vision_owner_lost_during_tick" \
			and not _commit_terminal_cause(code, lifecycle_attestation):
		code = _TERMINAL_LATCH_INVALID
	last_processed_tick = tick
	_is_advancing = false
	_processing_tick = 0
	_processing_phase = -1
	_processing_handler_id = &""
	_processing_handler_registration_id = ""
	_processing_handler_callback_identity = ""
	_tick_handler_roster_commitment = ""
	lifecycle = Lifecycle.FAILED
	if not _seal_terminal_runtime(lifecycle_attestation):
		return _reject(&"raid_terminal_seal_failed")
	return _reject(code)


func _finish_preterminalized_tick(tick: int) -> bool:
	var terminal_cause := _read_terminal_cause()
	var code := terminal_cause if not terminal_cause.is_empty() \
		else &"raid_terminalized_during_tick"
	last_processed_tick = tick
	_is_advancing = false
	_processing_tick = 0
	_processing_phase = -1
	_processing_handler_id = &""
	_processing_handler_registration_id = ""
	_processing_handler_callback_identity = ""
	_tick_handler_roster_commitment = ""
	return _reject(code)


func _seal_terminal_runtime(
	lifecycle_attestation: Variant = Callable()
) -> bool:
	if not _transient_attestation_is_valid(
		lifecycle_attestation,
		get_script(),
		_ATTEST_TERMINAL_SEAL,
		_authority_lifecycle_attestation_context(),
	):
		return false
	_processing_phase = -1
	_processing_handler_id = &""
	_processing_handler_registration_id = ""
	_processing_handler_callback_identity = ""
	_tick_handler_roster_commitment = ""
	clock.pause()
	clock.clear_pending()
	clock.seal()
	journal.seal()
	rng.seal()
	_intent_queue.clear()
	var released := _release_vision_owner_binding(lifecycle_attestation)
	_phase_handlers.clear()
	_handler_ids.clear()
	return released


func _register_phase_handler_unchecked(
	phase: TickPhase,
	handler_id: StringName,
	callback: Callable,
	priority: int = 0,
	after_handler_ids: PackedStringArray = PackedStringArray(),
	attestation: Variant = Callable()
) -> bool:
	if not _transient_attestation_is_valid(
		attestation,
		get_script(),
		_ATTEST_HANDLER_REGISTER,
		{
			"authority_instance_id": get_instance_id(),
			"raid_generation": _generation,
			"phase": int(phase),
			"handler_id": handler_id,
			"callback": callback,
			"priority": priority,
			"after": after_handler_ids,
		},
	):
		return _reject(&"handler_registration_attestation_invalid")
	if _handler_ids.has(handler_id):
		return _reject(&"handler_id_duplicate")
	if _named_phase_handlers_only and _phase_callback_is_anonymous(callback):
		return _reject(&"anonymous_phase_handler_forbidden")
	if not phase_handler_callback_is_safe(callback):
		return _reject(&"handler_callback_retains_capability")
	var callback_identity := _phase_callback_identity(callback)
	if callback_identity.is_empty():
		return _reject(&"handler_callback_identity_invalid")
	if _issued_handler_registration_ids.size() >= MAX_HANDLER_REGISTRATIONS:
		return _reject(&"handler_registration_limit")
	var registration_id := _new_handler_registration_id()
	if registration_id.is_empty():
		return _reject(&"handler_registration_identity_failed")
	var handlers: Array = _phase_handlers.get(int(phase), [])
	if handlers.size() >= MAX_HANDLERS_PER_PHASE:
		return _reject(&"phase_handler_limit")
	var relay := PhaseHandlerRelay.new()
	if not relay.configure(callback, callback_identity):
		return _reject(&"handler_callback_relay_invalid")
	var registration := {
		"id": handler_id,
		"registration_id": registration_id,
		"callback_identity": callback_identity,
		"bridge_connection_identity": relay.bridge_connection_identity,
		"anonymous": _phase_callback_is_anonymous(callback),
		"relay": relay,
		"phase": int(phase),
		"priority": priority,
		"after": after_handler_ids,
	}
	if handler_id == RESERVED_VISION_HANDLER_ID:
		# The accepted Vision authority contract intentionally exposes this one
		# authority-derived callback for provenance tamper detection. Generic
		# handlers remain relay-only and retain no caller Callable in the record.
		registration["callback"] = callback
	_handler_ids[handler_id] = registration
	handlers.append(registration if handler_id == RESERVED_VISION_HANDLER_ID \
		else handler_id)
	handlers.sort_custom(func(left_value: Variant, right_value: Variant) -> bool:
		var left_id := _phase_entry_handler_id(left_value)
		var right_id := _phase_entry_handler_id(right_value)
		var left := _handler_ids[left_id] as Dictionary
		var right := _handler_ids[right_id] as Dictionary
		if int(left["priority"]) != int(right["priority"]):
			return int(left["priority"]) < int(right["priority"])
		return String(left_id) < String(right_id)
	)
	_phase_handlers[int(phase)] = handlers
	_issued_handler_registration_ids[registration_id] = true
	return true


func _phase_handler_has_dependents(handler_id: StringName) -> bool:
	for registered_value in _handler_ids.values():
		if not registered_value is Dictionary:
			continue
		var registered := registered_value as Dictionary
		var dependencies := registered.get(
			"after", PackedStringArray()
		) as PackedStringArray
		if dependencies.has(String(handler_id)):
			return true
	return false


func _vision_owner_matches(
	owner: RaidVisionWorldOwner,
	owner_generation: int,
	expected_generation: int
) -> bool:
	if owner == null or not is_instance_valid(owner) \
			or not _is_exact_vision_owner(owner) or _vision_owner_ref == null:
		return false
	var captured: Variant = _vision_owner_ref.get_ref()
	return (
		captured == owner
		and owner.get_instance_id() == _vision_owner_instance_id
		and owner_generation == _vision_owner_generation
		and expected_generation == _vision_owner_raid_generation
		and expected_generation == _generation
	)


func _is_exact_vision_owner(owner: RaidVisionWorldOwner) -> bool:
	if owner == null or not is_instance_valid(owner):
		return false
	var owner_script: Variant = owner.get_script()
	if not owner_script is Script \
			or String((owner_script as Script).resource_path) \
				!= VISION_OWNER_SCRIPT_PATH:
		return false
	var expected_script: Resource = ResourceLoader.load(VISION_OWNER_SCRIPT_PATH)
	return expected_script != null and owner_script == expected_script


func _reserved_vision_callback_is_current() -> bool:
	if _vision_owner_ref == null:
		return false
	var owner_value: Variant = _vision_owner_ref.get_ref()
	if not owner_value is RaidVisionWorldOwner:
		return false
	var owner := owner_value as RaidVisionWorldOwner
	if not _vision_owner_matches(
		owner, _vision_owner_generation, _vision_owner_raid_generation
	) or not owner.is_registered_binding_current(
		self, _vision_owner_generation, _vision_owner_raid_generation
	):
		return false
	var handlers: Array = _phase_handlers.get(int(TickPhase.VISION), [])
	var has_reserved_entry := false
	for entry_value in handlers:
		if _phase_entry_handler_id(entry_value) == RESERVED_VISION_HANDLER_ID:
			has_reserved_entry = true
			break
	if not has_reserved_entry:
		return false
	var registration := _handler_ids.get(
		RESERVED_VISION_HANDLER_ID, {}) as Dictionary
	var callback := Callable(owner, "_handle_raid_phase")
	var stored_callback := registration.get("callback", Callable()) as Callable
	var callback_identity := _phase_callback_identity(callback)
	var relay := registration.get("relay") as PhaseHandlerRelay
	return not registration.is_empty() \
		and int(registration.get("phase", -1)) == int(TickPhase.VISION) \
		and stored_callback == callback \
		and not callback_identity.is_empty() \
		and String(registration.get("callback_identity", "")) == callback_identity \
		and relay != null and is_instance_valid(relay) \
		and relay.callback_identity == callback_identity \
		and relay.bridge_connection_identity \
			== String(registration.get("bridge_connection_identity", ""))


## Commits the one owner-loss transition that can be observed before Godot
## delivers PREDELETE: the exact bound Node is already irreversibly queued
## while its authority callback is still on the stack. This method accepts no
## caller bearer and remains inert unless engine-owned state and the complete
## current-tick binding agree.
func _terminalize_queued_vision_owner_during_tick() -> bool:
	if not _is_advancing \
			or _processing_tick <= 0 \
			or (lifecycle != Lifecycle.ACTIVE \
				and lifecycle != Lifecycle.EXTRACTING) \
			or _vision_owner_ref == null:
		return false
	var owner_value: Variant = _vision_owner_ref.get_ref()
	if not owner_value is RaidVisionWorldOwner \
			or not is_instance_valid(owner_value):
		return false
	var owner := owner_value as RaidVisionWorldOwner
	if not owner.is_queued_for_deletion() \
			or not _vision_owner_matches(
				owner, _vision_owner_generation, _vision_owner_raid_generation
			):
		return false
	var lifecycle_context := _authority_lifecycle_attestation_context()
	var commit_context := lifecycle_context.duplicate()
	commit_context["cause"] = &"vision_owner_lost_during_tick"
	var lifecycle_attestation := func(
		operation: StringName, request: Dictionary
	) -> Dictionary:
		if operation == _ATTEST_TERMINAL_COMMIT:
			return _answer_attestation(
				operation, request, operation, commit_context
			)
		if operation == _ATTEST_TERMINAL_SEAL \
				or operation == _ATTEST_OWNER_RELEASE:
			return _answer_attestation(
				operation, request, operation, lifecycle_context
			)
		return {"ok": false}
	if not _commit_terminal_cause(
		&"vision_owner_lost_during_tick", lifecycle_attestation
	):
		return false
	lifecycle = Lifecycle.FAILED
	return _seal_terminal_runtime(lifecycle_attestation)


## Deliberately inert compatibility trap for reflective callers. Reserved-slot
## removal is committed only inside the attested two-sided release below.
func _remove_reserved_vision_handler(
	_attestation: Variant = Callable()
) -> bool:
	return false


func _release_vision_owner_binding(
	lifecycle_attestation: Variant = Callable()
) -> bool:
	if not _transient_attestation_is_valid(
		lifecycle_attestation,
		get_script(),
		_ATTEST_TERMINAL_SEAL,
		_authority_lifecycle_attestation_context(),
	):
		return false
	var owner_value: Variant = _vision_owner_ref.get_ref() \
		if _vision_owner_ref != null else null
	var owner_generation := _vision_owner_generation
	var raid_generation := _vision_owner_raid_generation
	if owner_value is RaidVisionWorldOwner and is_instance_valid(owner_value):
		if not (owner_value as RaidVisionWorldOwner).release_registered_binding(
			self, owner_generation, raid_generation, lifecycle_attestation
		):
			return false
	# Commit reserved-handler removal inside the same authority-attested release
	# boundary. No separately callable helper can publish half of this change.
	var handlers: Array = _phase_handlers.get(int(TickPhase.VISION), [])
	var retained: Array = []
	for handler_id_value in handlers:
		if _phase_entry_handler_id(handler_id_value) == RESERVED_VISION_HANDLER_ID:
			continue
		retained.append(handler_id_value)
	if retained.is_empty():
		_phase_handlers.erase(int(TickPhase.VISION))
	else:
		_phase_handlers[int(TickPhase.VISION)] = retained
	_handler_ids.erase(RESERVED_VISION_HANDLER_ID)
	_vision_owner_ref = null
	_vision_owner_instance_id = 0
	_vision_owner_generation = 0
	_vision_owner_raid_generation = 0
	return true


func _authority_lifecycle_attestation_context() -> Dictionary:
	return {
		"authority_instance_id": get_instance_id(),
		"raid_generation": _generation,
		"owner_instance_id": _vision_owner_instance_id,
		"owner_generation": _vision_owner_generation,
	}


func _bound_vision_owner_is_queued_for_deletion() -> bool:
	if _vision_owner_ref == null:
		return false
	var owner_value: Variant = _vision_owner_ref.get_ref()
	if not owner_value is RaidVisionWorldOwner \
			or not is_instance_valid(owner_value):
		return false
	var owner := owner_value as RaidVisionWorldOwner
	return owner.is_queued_for_deletion() \
		and _vision_owner_matches(
			owner, _vision_owner_generation, _vision_owner_raid_generation
		)


func _commit_terminal_cause(
	cause: StringName,
	attestation: Variant = Callable()
) -> bool:
	if not _callable_has_exact_script(
		_terminal_latch_dispatch, get_script()
	):
		return false
	var challenge := RefCounted.new()
	var result: Variant = _terminal_latch_dispatch.call(
		_ATTEST_TERMINAL_COMMIT,
		{
			"authority_instance_id": get_instance_id(),
			"raid_generation": _generation,
			"owner_instance_id": _vision_owner_instance_id,
			"owner_generation": _vision_owner_generation,
			"cause": cause,
			"attestation": attestation,
			"challenge": challenge,
		},
	)
	if not result is Dictionary:
		return false
	var response := result as Dictionary
	if not _has_exact_keys(response, PackedStringArray([
		"ok", "challenge", "cause",
	])) or typeof(response.get("ok", null)) != TYPE_BOOL \
			or not bool(response["ok"]) \
			or response.get("challenge", null) != challenge \
			or typeof(response.get("cause", null)) != TYPE_STRING_NAME:
		return false
	var committed_cause := response["cause"] as StringName
	return committed_cause == &"vision_owner_destroyed" \
		or committed_cause == &"vision_owner_lost_during_tick"


func _read_terminal_cause() -> StringName:
	if not _callable_has_exact_script(
		_terminal_latch_dispatch, get_script()
	):
		return _TERMINAL_LATCH_INVALID
	var challenge := RefCounted.new()
	var result: Variant = _terminal_latch_dispatch.call(
		_ATTEST_TERMINAL_READ,
		{
			"authority_instance_id": get_instance_id(),
			"challenge": challenge,
		},
	)
	if not result is Dictionary:
		return _TERMINAL_LATCH_INVALID
	var response := result as Dictionary
	if not _has_exact_keys(response, PackedStringArray([
		"ok", "challenge", "cause",
	])) or typeof(response.get("ok", null)) != TYPE_BOOL \
			or not bool(response["ok"]) \
			or response.get("challenge", null) != challenge \
			or typeof(response.get("cause", null)) != TYPE_STRING_NAME:
		return _TERMINAL_LATCH_INVALID
	var cause := response["cause"] as StringName
	if cause.is_empty() or cause == &"vision_owner_destroyed" \
			or cause == &"vision_owner_lost_during_tick":
		return cause
	return _TERMINAL_LATCH_INVALID


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


static func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


func _new_handler_registration_id() -> String:
	for _attempt in 4:
		var bytes := Crypto.new().generate_random_bytes(32)
		if bytes.size() != 32:
			continue
		var candidate := bytes.hex_encode()
		if not _issued_handler_registration_ids.has(candidate):
			return candidate
	return ""


func _phase_entry_handler_id(value: Variant) -> StringName:
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return StringName(value)
	if typeof(value) == TYPE_DICTIONARY:
		return StringName((value as Dictionary).get("id", &""))
	return &""


func _phase_handler_roster_is_coherent(
	phase_value: int,
	actual_ids: Array
) -> bool:
	var expected_ids: Array = []
	for handler_id_value in _handler_ids.keys():
		var handler_id := StringName(handler_id_value)
		var registration := _handler_ids[handler_id] as Dictionary
		if int(registration.get("phase", -1)) == phase_value:
			expected_ids.append(handler_id)
	expected_ids.sort_custom(func(left_value: Variant, right_value: Variant) -> bool:
		var left_id := StringName(left_value)
		var right_id := StringName(right_value)
		var left := _handler_ids[left_id] as Dictionary
		var right := _handler_ids[right_id] as Dictionary
		if int(left.get("priority", 0)) != int(right.get("priority", 0)):
			return int(left.get("priority", 0)) < int(right.get("priority", 0))
		return String(left_id) < String(right_id)
	)
	var normalized_actual: Array = []
	for entry_value in actual_ids:
		var entry_id := _phase_entry_handler_id(entry_value)
		if entry_id.is_empty():
			return false
		if typeof(entry_value) == TYPE_DICTIONARY \
				and entry_id != RESERVED_VISION_HANDLER_ID:
			return false
		normalized_actual.append(entry_id)
	return normalized_actual == expected_ids


func _phase_handler_roster_commitment() -> String:
	var handler_ids := PackedStringArray(_handler_ids.keys())
	handler_ids.sort()
	var encoded := "raid-phase-roster-v1|%d|" % handler_ids.size()
	for handler_id_value in handler_ids:
		var handler_id := StringName(handler_id_value)
		var registration := _handler_ids.get(handler_id, {}) as Dictionary
		if registration.is_empty():
			return ""
		var fields := PackedStringArray([
			String(handler_id),
			String(registration.get("registration_id", "")),
			String(registration.get("callback_identity", "")),
			String(registration.get("bridge_connection_identity", "")),
			str(int(registration.get("phase", -1))),
			str(int(registration.get("priority", 0))),
			"1" if bool(registration.get("anonymous", true)) else "0",
		])
		var dependencies := PackedStringArray(
			registration.get("after", PackedStringArray()))
		fields.append(str(dependencies.size()))
		for dependency in dependencies:
			fields.append(dependency)
		for field in fields:
			encoded += "%d:%s|" % [field.to_utf8_buffer().size(), field]
	for phase_value in PHASE_NAMES.size():
		var ordered_ids: Array = _phase_handlers.get(phase_value, [])
		encoded += "p%d:%d|" % [phase_value, ordered_ids.size()]
		for entry_value in ordered_ids:
			var handler_id := _phase_entry_handler_id(entry_value)
			if handler_id.is_empty():
				return ""
			if typeof(entry_value) == TYPE_DICTIONARY \
					and handler_id != RESERVED_VISION_HANDLER_ID:
				return ""
			var encoded_id := String(handler_id)
			encoded += "%d:%s|" % [
				encoded_id.to_utf8_buffer().size(), encoded_id]
	return encoded.sha256_text()


func phase_handler_callback_is_safe(callback: Callable) -> bool:
	return callback.is_valid() \
		and not _variant_graph_contains_hitbox_bearer(
			callback, 0, {get_instance_id(): true})


func _phase_callback_is_anonymous(callback: Callable) -> bool:
	return String(callback.get_method()) == "<anonymous lambda>"


func _phase_callback_identity(callback: Callable) -> String:
	if not callback.is_valid():
		return ""
	var owner := callback.get_object()
	if owner == null or not is_instance_valid(owner):
		return ""
	var bound_arguments := callback.get_bound_arguments()
	var encoded_arguments: Array = []
	for argument in bound_arguments:
		if argument is Object:
			var object := argument as Object
			if object == null or not is_instance_valid(object):
				return ""
			var script_path := ""
			var script_value: Variant = object.get_script()
			if script_value is Script:
				script_path = String((script_value as Script).resource_path)
			encoded_arguments.append({
				"object_instance_id": object.get_instance_id(),
				"script_path": script_path,
			})
		elif ZCanonicalValue.is_bounded(argument):
			encoded_arguments.append({"value": argument})
		else:
			return ""
	return ZCanonicalValue.sha256({
		"object_instance_id": owner.get_instance_id(),
		"method": String(callback.get_method()),
		"bound_arguments": encoded_arguments,
	})


func _variant_graph_contains_hitbox_bearer(
	value: Variant,
	depth: int,
	visited: Dictionary
) -> bool:
	if depth > 16:
		# Deep/cyclic collection graphs are rejected rather than accepted without
		# a complete bearer scan.
		return true
	if value is BodyHitboxWorld2D.BindingCapability:
		return true
	if typeof(value) == TYPE_CALLABLE:
		var callable := value as Callable
		if _variant_graph_contains_hitbox_bearer(
			callable.get_object(), depth + 1, visited):
			return true
		for argument in callable.get_bound_arguments():
			if _variant_graph_contains_hitbox_bearer(
				argument, depth + 1, visited):
				return true
		return false
	if typeof(value) == TYPE_OBJECT:
		var object := value as Object
		if object == null or not is_instance_valid(object):
			return false
		var instance_id := object.get_instance_id()
		if visited.has(instance_id):
			return false
		visited[instance_id] = true
		for property_value in object.get_property_list():
			var property_name := StringName(
				(property_value as Dictionary).get("name", &""))
			if property_name.is_empty():
				continue
			if _variant_graph_contains_hitbox_bearer(
				object.get(property_name), depth + 1, visited):
				return true
		# PhaseHandlerRelay signal connections are an intentional retained edge
		# and must be scanned. Arbitrary engine-object signals are excluded: their
		# process-wide graphs are neither owned by this registration nor bounded.
		if object is PhaseHandlerRelay:
			for connection_value in object.get_signal_connection_list(&"invoked"):
				var connection := connection_value as Dictionary
				if _variant_graph_contains_hitbox_bearer(
					connection.get("callable", Callable()),
					depth + 1, visited):
					return true
		return false
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary := value as Dictionary
		for key in dictionary.keys():
			if _variant_graph_contains_hitbox_bearer(
				key, depth + 1, visited):
				return true
			var child: Variant = dictionary[key]
			if _variant_graph_contains_hitbox_bearer(
				child, depth + 1, visited):
				return true
		return false
	if typeof(value) == TYPE_ARRAY:
		for child in value as Array:
			if _variant_graph_contains_hitbox_bearer(
				child, depth + 1, visited):
				return true
	return false


func _actor_source_key(actor_id: ZEntityId, source: ZRaidIntent.Source) -> String:
	return "%s|%d" % [actor_id.canonical_key(), int(source)]


func _authorized_actor_key(actor_id: ZEntityId) -> String:
	if actor_id == null:
		return ""
	var parsed := ZEntityId.parse(actor_id.canonical_key())
	if parsed == null:
		return ""
	for source in range(int(ZRaidIntent.Source.PLAYER), int(ZRaidIntent.Source.SYSTEM) + 1):
		if _authorized_actor_sources.has(_actor_source_key(parsed, source)):
			return parsed.canonical_key()
	return ""


func _canonical_weapon_actor_states() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var actor_keys := PackedStringArray(_weapon_actor_states.keys())
	actor_keys.sort()
	for actor_key in actor_keys:
		var state := (_weapon_actor_states[actor_key] as Dictionary).duplicate(true)
		var origin := state.get("authoritative_origin", Vector2i.ZERO) as Vector2i
		var aim := state.get("authoritative_aim", Vector2i.ZERO) as Vector2i
		state["authoritative_origin"] = {"x": origin.x, "y": origin.y}
		state["authoritative_aim"] = {"x": aim.x, "y": aim.y}
		result.append(state)
	return result


func _reject(code: StringName) -> bool:
	last_error = code
	return false
