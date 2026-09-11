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

	func configure(callback: Callable, identity: String) -> bool:
		if not callback.is_valid() or identity.is_empty() \
				or not callback_identity.is_empty():
			return false
		callback_identity = identity
		invoked.connect(func(
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
		)
		return true

	func invoke(
		authority: RaidAuthority,
		phase: TickPhase,
		tick: int,
		intents: Array[ZRaidIntent]
	) -> Variant:
		var result_box: Array = []
		invoked.emit(authority, phase, tick, intents, result_box)
		if result_box.size() != 1:
			return null
		return result_box[0]

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
var _processing_handler_registration_id: String = ""
var _processing_handler_callback_identity: String = ""
var _phase_handlers: Dictionary = {}
var _handler_ids: Dictionary = {}
var _issued_handler_registration_ids: Dictionary = {}
var _authorized_actor_sources: Dictionary = {}
var _weapon_actor_states: Dictionary = {}


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


## Stronger dispatch proof for handlers that own irreversible cross-domain
## work. Merely calling a registered callback-shaped method during the same
## tick/phase is insufficient: the exact handler registration must currently
## be the authority's active dispatch frame.
func is_dispatching_phase_handler(
	handler_id: StringName,
	phase: TickPhase,
	tick: int,
	expected_generation: int
) -> bool:
	if not is_processing_tick_phase(phase, tick, expected_generation) \
			or _processing_handler_id != handler_id:
		return false
	var registration := _handler_ids.get(handler_id, {}) as Dictionary
	return not registration.is_empty() \
		and int(registration.get("phase", -1)) == int(phase)


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
	if not ZIdentityRules.is_valid_part(String(handler_id)) or not callback.is_valid():
		return _reject(&"handler_invalid")
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
	if _issued_handler_registration_ids.size() >= MAX_HANDLER_REGISTRATIONS:
		return _reject(&"handler_registration_limit")
	var registration_id := _new_handler_registration_id()
	if registration_id.is_empty():
		return _reject(&"handler_registration_identity_failed")
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
	var handler_ids: Array = _phase_handlers.get(int(phase), [])
	if handler_ids.size() >= MAX_HANDLERS_PER_PHASE:
		return _reject(&"phase_handler_limit")
	var relay := PhaseHandlerRelay.new()
	if not relay.configure(callback, callback_identity):
		return _reject(&"handler_callback_relay_invalid")
	var registration := {
		"id": handler_id,
		"registration_id": registration_id,
		"callback_identity": callback_identity,
		"relay": relay,
		"phase": int(phase),
		"priority": priority,
		"after": dependencies,
	}
	_handler_ids[handler_id] = registration
	handler_ids.append(handler_id)
	handler_ids.sort_custom(func(left_value: Variant, right_value: Variant) -> bool:
		var left_id := StringName(left_value)
		var right_id := StringName(right_value)
		var left := _handler_ids[left_id] as Dictionary
		var right := _handler_ids[right_id] as Dictionary
		if int(left["priority"]) != int(right["priority"]):
			return int(left["priority"]) < int(right["priority"])
		return String(left_id) < String(right_id)
	)
	_phase_handlers[int(phase)] = handler_ids
	_issued_handler_registration_ids[registration_id] = true
	return true


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
	for registered_id_value in handlers:
		if StringName(registered_id_value) != handler_id:
			retained.append(registered_id_value)
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
	if not ZIdentityRules.is_valid_part(String(handler_id)):
		return _reject(&"handler_invalid")
	if not _handler_ids.has(handler_id):
		return true
	for registered_value in _handler_ids.values():
		var registered := registered_value as Dictionary
		var dependencies := registered.get("after", PackedStringArray()) as PackedStringArray
		if dependencies.has(String(handler_id)):
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
		var handler_ids: Array = _phase_handlers.get(phase_value, [])
		if not _phase_handler_roster_is_coherent(phase_value, handler_ids):
			return _fail_current_tick(tick, &"phase_handler_registration_corrupted")
		for handler_id_value in handler_ids:
			if typeof(handler_id_value) != TYPE_STRING_NAME \
					and typeof(handler_id_value) != TYPE_STRING:
				return _fail_current_tick(tick, &"phase_handler_registration_corrupted")
			var handler_id := StringName(handler_id_value)
			var entry := _handler_ids.get(handler_id, {}) as Dictionary
			if entry.is_empty() \
					or StringName(entry.get("id", &"")) != handler_id \
					or int(entry.get("phase", -1)) != phase_value:
				return _fail_current_tick(tick, &"phase_handler_registration_corrupted")
			var relay := entry.get("relay") as PhaseHandlerRelay
			var callback_identity := String(entry.get("callback_identity", ""))
			if relay == null or not is_instance_valid(relay) \
					or callback_identity.is_empty() \
					or relay.callback_identity != callback_identity:
				return _fail_current_tick(tick, &"phase_handler_invalidated")
			_processing_handler_id = handler_id
			_processing_handler_registration_id = String(entry["registration_id"])
			_processing_handler_callback_identity = callback_identity
			var handler_intents: Array[ZRaidIntent] = []
			for intent in due_intents:
				var intent_copy := intent.snapshot()
				if intent_copy == null:
					return _fail_current_tick(tick, &"queued_intent_corrupted")
				handler_intents.append(intent_copy)
			var outcome: Variant = relay.invoke(self, phase, tick, handler_intents)
			_processing_handler_id = &""
			_processing_handler_registration_id = ""
			_processing_handler_callback_identity = ""
			if typeof(outcome) != TYPE_BOOL or not outcome:
				return _fail_current_tick(tick, &"phase_handler_failed")
	last_processed_tick = tick
	_is_advancing = false
	_processing_tick = 0
	_processing_phase = -1
	_processing_handler_id = &""
	_processing_handler_registration_id = ""
	_processing_handler_callback_identity = ""
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
	_processing_handler_registration_id = ""
	_processing_handler_callback_identity = ""
	lifecycle = Lifecycle.FAILED
	_seal_terminal_runtime()
	return _reject(code)


func _seal_terminal_runtime() -> void:
	clock.pause()
	clock.clear_pending()
	clock.seal()
	journal.seal()
	rng.seal()
	_intent_queue.clear()
	_phase_handlers.clear()
	_handler_ids.clear()


func _new_handler_registration_id() -> String:
	for _attempt in 4:
		var bytes := Crypto.new().generate_random_bytes(32)
		if bytes.size() != 32:
			continue
		var candidate := bytes.hex_encode()
		if not _issued_handler_registration_ids.has(candidate):
			return candidate
	return ""


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
	return actual_ids == expected_ids


func phase_handler_callback_is_safe(callback: Callable) -> bool:
	return callback.is_valid() \
		and not _variant_graph_contains_hitbox_bearer(
			callback, 0, {get_instance_id(): true})


func _phase_callback_identity(callback: Callable) -> String:
	if not callback.is_valid():
		return ""
	var owner := callback.get_object()
	if owner == null or not is_instance_valid(owner):
		return ""
	var bound_arguments := callback.get_bound_arguments()
	if not ZCanonicalValue.is_bounded(bound_arguments):
		return ""
	return ZCanonicalValue.sha256({
		"object_instance_id": owner.get_instance_id(),
		"method": String(callback.get_method()),
		"bound_arguments": bound_arguments,
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
