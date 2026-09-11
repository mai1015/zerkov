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
	if not ZIdentityRules.is_valid_part(String(handler_id)) or not callback.is_valid():
		return _reject(&"handler_invalid")
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
	_phase_handlers.clear()
	_handler_ids.clear()


func _actor_source_key(actor_id: ZEntityId, source: ZRaidIntent.Source) -> String:
	return "%s|%d" % [actor_id.canonical_key(), int(source)]


func _reject(code: StringName) -> bool:
	last_error = code
	return false
