class_name ZInteractionPolicyOwner
extends RefCounted
## Task 3.8 -- the RaidAuthority composition owner for `ZInteractionPolicy`.
##
## This owner is the only path by which the pure policy is fed state and its
## verdicts are recorded inside a raid:
##
## * `register_with_authority(...)` claims one
##   `RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS` phase handler with an
##   explicit `expected_generation`, exactly like the verified
##   `ZPlayerLocomotion` MOVEMENT handler (the reference pattern). Late,
##   replayed or out-of-generation dispatch is inert: it mutates nothing and
##   publishes nothing.
## * Actor positions are never trusted from callers. They resolve from the
##   attached task 3.6 `ZMovementWorld2D` (the authoritative resolved poses,
##   already advanced by this tick's MOVEMENT phase) or, when no world is
##   attached, from explicitly injected positions set through
##   `set_actor_position` -- still game-owned composition state, never a
##   presentation write.
## * Interaction intents use kind `interaction` with payload
##   `{"target_id": String}` -- the shape task 3.7's landed
##   `ZWorldCursorAdapter.build_interaction_intent` already emits. An optional
##   `"requested_kind"` payload key lets other game-owned callers (AI,
##   abilities) name the verb; when absent, the kind is resolved from the
##   target's authoritative index entry, so presentation never asserts a kind.
##
## The owner never performs the range/line/eligibility reasoning itself: it
## only validates identity and generation, resolves authoritative state, and
## delegates to `ZInteractionPolicy.evaluate`. Every mutating entry point
## validates `expected_generation` against the registered authority first;
## a torn-down, replaced or completed raid (generation bumped by teardown or
## seal) is inert.

const DEFAULT_PHASE_HANDLER_ID: StringName = &"interaction_policy"
## Matches `ZWorldCursorAdapter.INTENT_KIND_INTERACTION` (task 3.7); do not
## invent a second interaction intent kind.
const INTENT_KIND_INTERACTION: StringName = &"interaction"
const PAYLOAD_TARGET_ID: String = "target_id"
const PAYLOAD_REQUESTED_KIND: String = "requested_kind"
## Bounded evaluation log, same shape/limit convention as the task 3.6
## movement correction log: newest retained, oldest dropped.
const MAX_EVALUATION_LOG: int = 64

var last_error: StringName = &""
var _authority: RaidAuthority = null
var _generation: int = 0
var _targets: Dictionary = {}
var _occluders: Array[ZerkovOccluderSegment] = []
var _actor_positions: Dictionary = {}
var _movement_world: ZMovementWorld2D = null
var _movement_world_generation: int = -1
var _last_result: ZInteractionResult = null
var _evaluation_log: Array[Dictionary] = []


## Validates and adopts the injected static state for one raid generation.
## `targets` maps String target id -> `ZInteractionTargetState` and every
## entry must pass `ZInteractionTargetState.validate`. Fail-closed: on any
## problem nothing is adopted.
func configure(
	expected_generation: int,
	targets: Dictionary = {},
	occluders: Array[ZerkovOccluderSegment] = []
) -> bool:
	last_error = &""
	if expected_generation <= 0:
		return _reject(&"generation_invalid")
	var validated: Dictionary = {}
	for key_value in targets.keys():
		var key := String(key_value)
		var value: Variant = targets[key_value]
		if not value is ZInteractionTargetState:
			return _reject(&"target_invalid")
		var state := value as ZInteractionTargetState
		if key != String(state.target_id):
			return _reject(&"target_key_mismatch")
		var problems := state.validate()
		if not problems.is_empty():
			return _reject(&"target_invalid")
		validated[key] = state
	for segment_value in occluders:
		if not segment_value is ZerkovOccluderSegment:
			return _reject(&"occluder_invalid")
	_generation = expected_generation
	_targets = validated
	_occluders = occluders.duplicate()
	_actor_positions = {}
	_movement_world = null
	_movement_world_generation = -1
	_last_result = null
	_evaluation_log = []
	return true


## Claims the INTERACTIONS_AND_WEAPONS phase handler. Mirrors
## `ZPlayerLocomotion.register_with_authority` (the verified reference):
## explicit `expected_generation`, explicit priority/dependencies, failure
## diagnostics surfaced through `last_error`.
func register_with_authority(
	authority: RaidAuthority,
	expected_generation: int,
	priority: int = 0,
	dependencies: PackedStringArray = PackedStringArray()
) -> bool:
	last_error = &""
	if authority == null or not is_instance_valid(authority):
		return _reject(&"authority_invalid")
	if _generation <= 0:
		return _reject(&"owner_unconfigured")
	if expected_generation != _generation:
		return _reject(&"owner_generation_mismatch")
	var callback := Callable(self, "_handle_interaction_phase")
	if not authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		DEFAULT_PHASE_HANDLER_ID,
		callback,
		expected_generation,
		priority,
		dependencies
	):
		last_error = authority.last_error
		return false
	_authority = authority
	return true


## Attaches the authoritative task 3.6 movement world the actor positions
## resolve from. The world must be configured for exactly the owner's raid
## generation; fail-closed otherwise.
func attach_movement_world(world: ZMovementWorld2D, expected_generation: int) -> bool:
	last_error = &""
	if world == null or not is_instance_valid(world) or not world.is_configured():
		return _reject(&"movement_world_invalid")
	if not _mutation_generation_is_current(expected_generation):
		return _reject(&"stale_generation")
	if world.generation() != expected_generation:
		return _reject(&"movement_world_generation_mismatch")
	_movement_world = world
	_movement_world_generation = world.generation()
	return true


## Adds or replaces one target snapshot for the current generation. Heal
## targets (live actors, not layout data) enter the index here.
func upsert_target(state: ZInteractionTargetState, expected_generation: int) -> bool:
	last_error = &""
	if state == null or not state is ZInteractionTargetState:
		return _reject(&"target_invalid")
	var problems := state.validate()
	if not problems.is_empty():
		return _reject(&"target_invalid")
	if not _mutation_generation_is_current(expected_generation):
		return _reject(&"stale_generation")
	_targets[String(state.target_id)] = state
	return true


func remove_target(target_id: StringName, expected_generation: int) -> bool:
	last_error = &""
	if not _mutation_generation_is_current(expected_generation):
		return _reject(&"stale_generation")
	_targets.erase(String(target_id))
	return true


## Direct injection of an authoritative actor position, for compositions
## without a movement world (or before one is attached). Positions are
## validated through `ZWorldUnits` and stored per canonical actor key.
func set_actor_position(
	actor_id: ZEntityId,
	position_px: Vector2,
	expected_generation: int
) -> bool:
	last_error = &""
	if actor_id == null or not actor_id.is_initialized():
		return _reject(&"actor_id_invalid")
	if not ZWorldUnits.godot_to_canonical(position_px).ok:
		return _reject(&"actor_position_invalid")
	if not _mutation_generation_is_current(expected_generation):
		return _reject(&"stale_generation")
	_actor_positions[actor_id.canonical_key()] = position_px
	return true


## Authority-side synchronous evaluation for one actor. This is the typed
## entry game-owned systems call (never presentation); it performs no
## mutation beyond remembering the last result. A stale, replaced,
## completed or torn-down raid denies inertly with `generation_stale`.
func evaluate_for_actor(
	actor_id: ZEntityId,
	target_id: StringName,
	requested_kind: StringName,
	expected_generation: int
) -> ZInteractionResult:
	last_error = &""
	if not _evaluation_generation_is_current(expected_generation):
		last_error = &"stale_generation"
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_GENERATION_STALE, target_id, requested_kind
		)
	if actor_id == null or not actor_id.is_initialized():
		last_error = &"actor_id_invalid"
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_ACTOR_UNKNOWN, target_id, requested_kind
		)
	var resolved := _resolve_actor_position(actor_id)
	if not bool(resolved.get("ok", false)):
		last_error = &"actor_unknown"
		return ZInteractionResult.deny(
			ZInteractionResult.REASON_ACTOR_UNKNOWN, target_id, requested_kind
		)
	var request := ZInteractionRequest.create(
		actor_id, resolved["position_px"], target_id, requested_kind
	)
	var result := ZInteractionPolicy.evaluate(request, _targets, _occluders)
	_last_result = result
	return result


func _handle_interaction_phase(
	authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	intents: Array[ZRaidIntent]
) -> bool:
	last_error = &""
	if authority == null or not is_instance_valid(authority):
		return _reject(&"authority_invalid")
	if phase != RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS:
		return _reject(&"phase_invalid")
	if authority.generation() != _generation:
		# Late or replayed dispatch against a replaced or completed raid is
		# inert: no evaluation, no log mutation.
		last_error = &"stale_generation"
		return true
	for intent in intents:
		if intent == null or intent.kind != INTENT_KIND_INTERACTION:
			continue
		if intent.target_tick != tick:
			continue
		_evaluate_intent(intent, tick)
	return true


## Read-only accessors for composition and projection. Returned containers
## are duplicates; mutating them cannot change owner state.
func last_result() -> ZInteractionResult:
	return _last_result


func evaluation_log() -> Array[Dictionary]:
	return _evaluation_log.duplicate(true)


func targets_snapshot() -> Dictionary:
	return _targets.duplicate()


func target_count() -> int:
	return _targets.size()


## Small canonical summary; the full digest below chains every record so it
## never trips `ZCanonicalValue` collection bounds.
func canonical_record() -> Dictionary:
	return {
		"generation": _generation,
		"log_count": _evaluation_log.size(),
		"occluder_count": _occluders.size(),
		"target_count": _targets.size(),
	}


## Deterministic chained digest over the sorted target index, the injected
## occluders and the bounded evaluation log (framing idiom of the movement
## contract's replay chain: every part is hashed individually, order is
## explicit, never Dictionary iteration order).
func digest() -> String:
	var chain := ZCanonicalValue.sha256(["interaction-policy-owner-v1", _generation])
	if chain.is_empty():
		return ""
	for target_id in _sorted_target_ids():
		chain = ZCanonicalValue.sha256([chain, (_targets[target_id] as ZInteractionTargetState).digest()])
		if chain.is_empty():
			return ""
	for segment in _occluders:
		chain = ZCanonicalValue.sha256([chain, segment.digest()])
		if chain.is_empty():
			return ""
	for record in _evaluation_log:
		chain = ZCanonicalValue.sha256([chain, ZCanonicalValue.sha256(record)])
		if chain.is_empty():
			return ""
	return chain


func _evaluate_intent(intent: ZRaidIntent, tick: int) -> void:
	var target_str := String(intent.payload.get(PAYLOAD_TARGET_ID, ""))
	var requested_kind := StringName(String(intent.payload.get(PAYLOAD_REQUESTED_KIND, "")))
	if String(requested_kind).is_empty():
		# Presentation intents name only the target; the authoritative index
		# decides what kind of thing it is. Unknown targets still evaluate
		# (and deny with `unknown_target`) so the verdict is always logged.
		var indexed: Variant = _targets.get(target_str, null)
		if indexed is ZInteractionTargetState:
			requested_kind = (indexed as ZInteractionTargetState).kind
	var actor_id := intent.actor_id
	var resolved := _resolve_actor_position(actor_id) if actor_id != null \
		else {"ok": false}
	var result: ZInteractionResult
	if not bool(resolved.get("ok", false)):
		result = ZInteractionResult.deny(
			ZInteractionResult.REASON_ACTOR_UNKNOWN, StringName(target_str),
			requested_kind
		)
	else:
		var request := ZInteractionRequest.create(
			actor_id, resolved["position_px"], StringName(target_str), requested_kind
		)
		result = ZInteractionPolicy.evaluate(request, _targets, _occluders)
	_last_result = result
	_evaluation_log.append({
		"actor_id": actor_id.canonical_key() if actor_id != null else "",
		"allowed": result.allowed,
		"distance_micro": result.distance_micro,
		"kind": String(result.kind),
		"reason": String(result.reason),
		"request_id": intent.request_id.canonical_key() if intent.request_id != null else "",
		"sequence": intent.sequence,
		"target_id": String(result.target_id),
		"tick": tick,
	})
	if _evaluation_log.size() > MAX_EVALUATION_LOG:
		_evaluation_log.pop_front()


func _resolve_actor_position(actor_id: ZEntityId) -> Dictionary:
	if _movement_world != null and is_instance_valid(_movement_world) \
			and _movement_world.has_actor(actor_id):
		return {"ok": true, "position_px": _movement_world.actor_position_px(actor_id)}
	var key := actor_id.canonical_key()
	if _actor_positions.has(key):
		return {"ok": true, "position_px": _actor_positions[key]}
	return {"ok": false}


## Mutation entry points may run before registration (composition time), but
## never against a registered authority whose generation moved on.
func _mutation_generation_is_current(expected_generation: int) -> bool:
	if expected_generation != _generation:
		return false
	if _authority == null:
		return true
	return is_instance_valid(_authority) and _authority.generation() == expected_generation


## Evaluation is authority-driven: it requires a live registration whose
## generation still matches (teardown bumps the authority generation, so
## torn-down and replaced raids fail closed here).
func _evaluation_generation_is_current(expected_generation: int) -> bool:
	return _authority != null and is_instance_valid(_authority) \
		and expected_generation == _generation \
		and _authority.generation() == expected_generation


func _sorted_target_ids() -> Array[String]:
	var ids: Array[String] = []
	for key_value in _targets.keys():
		ids.append(String(key_value))
	ids.sort()
	return ids


func _reject(code: StringName) -> bool:
	last_error = code
	return false