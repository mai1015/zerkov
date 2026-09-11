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
## This identity is owned by RaidAuthority. Generic handler registration may
## never claim it, even in another phase.
const RESERVED_VISION_HANDLER_ID: StringName = &"raid_vision_world"
const VISION_OWNER_SCRIPT_PATH: String = \
	"res://game/ai/vision/raid_vision_world_owner.gd"

var lifecycle: Lifecycle = Lifecycle.PREPARING
var last_error: StringName = &""
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
var _phase_handlers: Dictionary = {}
var _handler_ids: Dictionary = {}
var _authorized_actor_sources: Dictionary = {}
var _vision_owner_ref: WeakRef
var _vision_owner_instance_id: int = 0
var _vision_owner_generation: int = 0
var _vision_owner_raid_generation: int = 0
var _releasing_vision_owner: bool = false


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
	lifecycle = next
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.EXTRACTING:
		clock.resume()
	else:
		clock.pause()
	if lifecycle == Lifecycle.COMPLETED or lifecycle == Lifecycle.FAILED:
		clock.clear_pending()
		_seal_terminal_runtime()
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


func register_phase_handler(
	phase: TickPhase,
	handler_id: StringName,
	callback: Callable,
	expected_generation: int
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
	# Generic Vision handlers may not consume the authority-owned slot's final
	# capacity before the real owner registers.
	if phase == TickPhase.VISION \
			and not _handler_ids.has(RESERVED_VISION_HANDLER_ID) \
			and (_phase_handlers.get(int(phase), []) as Array).size() \
				>= MAX_HANDLERS_PER_PHASE - 1:
		return _reject(&"phase_handler_limit")
	return _register_phase_handler_unchecked(phase, handler_id, callback)


## Claims the sole game-owned Vision slot. The authority derives the callback
## from the concrete configured owner; callers cannot supply an identity or
## Callable. The owner's provisional binding is checked before anything is
## published into the phase table.
func register_vision_world_owner(
	owner: RaidVisionWorldOwner,
	owner_generation: int,
	expected_generation: int
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
	if not owner.is_registration_claim_current(
		self, owner_generation, expected_generation
	):
		return _reject(&"vision_owner_claim_invalid")
	var callback := Callable(owner, "_handle_raid_phase")
	if not callback.is_valid():
		return _reject(&"vision_owner_callback_invalid")
	if not _register_phase_handler_unchecked(
		TickPhase.VISION, RESERVED_VISION_HANDLER_ID, callback
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
	expected_generation: int
) -> bool:
	last_error = &""
	if not _is_current_generation(expected_generation):
		return _reject(&"stale_generation")
	if not _vision_owner_matches(owner, owner_generation, expected_generation):
		return _reject(&"vision_owner_binding_invalid")
	if not owner.is_release_claim_current(
		self, owner_generation, expected_generation
	):
		return _reject(&"vision_owner_release_claim_invalid")
	if _is_advancing:
		return _reject(&"vision_owner_release_during_tick")
	if lifecycle == Lifecycle.PREPARING:
		_remove_reserved_vision_handler()
		_release_vision_owner_binding(false)
		return true
	if lifecycle == Lifecycle.ACTIVE or lifecycle == Lifecycle.EXTRACTING:
		lifecycle = Lifecycle.FAILED
		_seal_terminal_runtime()
		return true
	return _reject(&"vision_owner_release_closed")


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


## True only during this authority's synchronous release callback for the
## exact registered object and generations. Direct/replayed owner callbacks
## therefore cannot clear a live binding.
func is_releasing_vision_world_owner(
	owner: RaidVisionWorldOwner,
	owner_generation: int,
	expected_generation: int
) -> bool:
	return _releasing_vision_owner \
		and _vision_owner_matches(owner, owner_generation, expected_generation)


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
		lifecycle = Lifecycle.FAILED
		clock.reset(last_processed_tick, true)
		_seal_terminal_runtime()
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


func teardown(expected_generation: int) -> bool:
	last_error = &""
	if not _configured or expected_generation != _generation:
		return _reject(&"stale_generation")
	if _is_advancing:
		return _reject(&"teardown_during_tick")
	if lifecycle == Lifecycle.TORN_DOWN:
		return _reject(&"already_torn_down")
	_release_vision_owner_binding(true)
	lifecycle = Lifecycle.TORN_DOWN
	clock.pause()
	clock.clear_pending()
	clock.seal()
	journal.seal()
	rng.seal()
	_intent_queue.clear()
	_phase_handlers.clear()
	_handler_ids.clear()
	_authorized_actor_sources.clear()
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

	_is_advancing = true
	_processing_tick = tick
	last_phase_trace = PackedStringArray()
	var due_intents: Array[ZRaidIntent] = []
	for phase_value in PHASE_NAMES.size():
		var phase: TickPhase = phase_value
		_processing_phase = phase_value
		last_phase_trace.append(PHASE_NAMES[phase_value])
		if phase == TickPhase.ADMIT_INTENTS:
			due_intents = _intent_queue.drain_tick(tick)
		var handlers: Array = _phase_handlers.get(phase_value, [])
		for entry in handlers:
			_processing_handler_id = entry["id"]
			var callback: Callable = entry["callback"]
			if _processing_handler_id == RESERVED_VISION_HANDLER_ID \
					and not _reserved_vision_callback_is_current():
				return _fail_current_tick(tick, &"vision_owner_provenance_invalid")
			if not callback.is_valid():
				return _fail_current_tick(tick, &"phase_handler_invalidated")
			var handler_intents: Array[ZRaidIntent] = []
			for intent in due_intents:
				var intent_copy := intent.snapshot()
				if intent_copy == null:
					return _fail_current_tick(tick, &"queued_intent_corrupted")
				handler_intents.append(intent_copy)
			var outcome: Variant = callback.call(self, phase, tick, handler_intents)
			_processing_handler_id = &""
			if typeof(outcome) != TYPE_BOOL or not outcome:
				return _fail_current_tick(tick, &"phase_handler_failed")
		_processing_phase = -1
	last_processed_tick = tick
	_is_advancing = false
	_processing_tick = 0
	_processing_phase = -1
	_processing_handler_id = &""
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


func _fail_current_tick(tick: int, code: StringName) -> bool:
	# The clock has already consumed this tick. A handler failure is terminal, so
	# retain any committed audit prefix and keep the canonical tick invariant.
	last_processed_tick = tick
	_is_advancing = false
	_processing_tick = 0
	_processing_phase = -1
	_processing_handler_id = &""
	lifecycle = Lifecycle.FAILED
	_seal_terminal_runtime()
	return _reject(code)


func _seal_terminal_runtime() -> void:
	_processing_phase = -1
	_processing_handler_id = &""
	clock.pause()
	clock.clear_pending()
	clock.seal()
	journal.seal()
	rng.seal()
	_intent_queue.clear()
	_release_vision_owner_binding(true)
	_phase_handlers.clear()
	_handler_ids.clear()


func _register_phase_handler_unchecked(
	phase: TickPhase,
	handler_id: StringName,
	callback: Callable
) -> bool:
	if _handler_ids.has(handler_id):
		return _reject(&"handler_id_duplicate")
	var handlers: Array = _phase_handlers.get(int(phase), [])
	if handlers.size() >= MAX_HANDLERS_PER_PHASE:
		return _reject(&"phase_handler_limit")
	handlers.append({"id": handler_id, "callback": callback})
	handlers.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left["id"]) < String(right["id"])
	)
	_phase_handlers[int(phase)] = handlers
	_handler_ids[handler_id] = true
	return true


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
	for entry_value in handlers:
		if not entry_value is Dictionary:
			continue
		var entry := entry_value as Dictionary
		if entry.get("id", &"") != RESERVED_VISION_HANDLER_ID:
			continue
		var callback_value: Variant = entry.get("callback", Callable())
		if not callback_value is Callable:
			return false
		var callback := callback_value as Callable
		return callback.is_valid() \
			and callback.get_object() == owner \
			and callback.get_method() == &"_handle_raid_phase" \
			and callback.get_bound_arguments_count() == 0
	return false


func _remove_reserved_vision_handler() -> void:
	var handlers: Array = _phase_handlers.get(int(TickPhase.VISION), [])
	var retained: Array = []
	for entry_value in handlers:
		if entry_value is Dictionary \
				and (entry_value as Dictionary).get("id", &"") \
					== RESERVED_VISION_HANDLER_ID:
			continue
		retained.append(entry_value)
	if retained.is_empty():
		_phase_handlers.erase(int(TickPhase.VISION))
	else:
		_phase_handlers[int(TickPhase.VISION)] = retained
	_handler_ids.erase(RESERVED_VISION_HANDLER_ID)


func _release_vision_owner_binding(seal_owner: bool) -> void:
	var owner_value: Variant = _vision_owner_ref.get_ref() \
		if _vision_owner_ref != null else null
	var owner_generation := _vision_owner_generation
	var raid_generation := _vision_owner_raid_generation
	_releasing_vision_owner = true
	if owner_value is RaidVisionWorldOwner and is_instance_valid(owner_value):
		(owner_value as RaidVisionWorldOwner).release_registered_binding(
			self, owner_generation, raid_generation, seal_owner
		)
	_releasing_vision_owner = false
	_vision_owner_ref = null
	_vision_owner_instance_id = 0
	_vision_owner_generation = 0
	_vision_owner_raid_generation = 0


func _actor_source_key(actor_id: ZEntityId, source: ZRaidIntent.Source) -> String:
	return "%s|%d" % [actor_id.canonical_key(), int(source)]


func _reject(code: StringName) -> bool:
	last_error = code
	return false
