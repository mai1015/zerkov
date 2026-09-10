class_name ZRaidIntentQueue
extends RefCounted
## Bounded, authenticated, deterministic queue for all raid mutation intent.

const MAX_QUEUED_INTENTS: int = 1024
const MAX_TRACKED_REQUESTS: int = 262_144
const MAX_FUTURE_TICKS: int = 600
const MAX_SEQUENCE: int = 2_147_483_647

var last_error: StringName = &""
var _queued: Array[ZRaidIntent] = []
var _seen_requests: Dictionary = {}
var _seen_sequences: Dictionary = {}


func admit(
	intent: ZRaidIntent,
	current_tick: int,
	expected_session: ZSessionId,
	expected_actor: ZEntityId,
	expected_epoch: int,
	expected_generation: int
) -> bool:
	last_error = &""
	if intent == null:
		return _reject(&"intent_missing")
	if current_tick < 0:
		return _reject(&"current_tick_invalid")
	if intent.request_id == null or not intent.request_id.is_initialized():
		return _reject(&"request_id_invalid")
	if intent.session_id == null or not intent.session_id.is_equal(expected_session):
		return _reject(&"session_mismatch")
	if intent.actor_id == null or not intent.actor_id.is_equal(expected_actor):
		return _reject(&"actor_mismatch")
	if intent.authority_epoch != expected_epoch:
		return _reject(&"authority_epoch_mismatch")
	if intent.generation != expected_generation:
		return _reject(&"generation_mismatch")
	if int(intent.source) < ZRaidIntent.Source.PLAYER or int(intent.source) > ZRaidIntent.Source.SYSTEM:
		return _reject(&"source_invalid")
	if (intent.target_tick <= current_tick
		or intent.target_tick - current_tick > MAX_FUTURE_TICKS):
		return _reject(&"target_tick_out_of_bounds")
	if intent.sequence <= 0 or intent.sequence > MAX_SEQUENCE:
		return _reject(&"sequence_out_of_bounds")
	if not ZIdentityRules.is_valid_part(String(intent.kind)):
		return _reject(&"intent_kind_invalid")
	if not ZCanonicalValue.is_bounded(intent.payload):
		return _reject(&"payload_invalid_or_unbounded")
	if _queued.size() >= MAX_QUEUED_INTENTS:
		return _reject(&"intent_queue_full")
	var request_key := intent.request_id.canonical_key()
	if _seen_requests.has(request_key):
		return _reject(&"duplicate_request")
	var sequence_key := "%s|%d|%d" % [
		intent.actor_id.canonical_key(),
		int(intent.source),
		intent.sequence,
	]
	if _seen_sequences.has(sequence_key):
		return _reject(&"duplicate_sequence")
	if _seen_requests.size() >= MAX_TRACKED_REQUESTS:
		return _reject(&"request_history_full")
	var queued_copy := intent.snapshot()
	if queued_copy == null:
		return _reject(&"intent_snapshot_invalid")

	_seen_requests[request_key] = true
	_seen_sequences[sequence_key] = true
	_queued.append(queued_copy)
	return true


func drain_tick(tick: int) -> Array[ZRaidIntent]:
	var due: Array[ZRaidIntent] = []
	var remaining: Array[ZRaidIntent] = []
	for intent in _queued:
		if intent.target_tick == tick:
			due.append(intent)
		else:
			remaining.append(intent)
	_queued = remaining
	due.sort_custom(_comes_before)
	return due


func clear() -> void:
	_queued.clear()
	_seen_requests.clear()
	_seen_sequences.clear()
	last_error = &""


func size() -> int:
	return _queued.size()


func _reject(code: StringName) -> bool:
	last_error = code
	return false


static func _comes_before(left: ZRaidIntent, right: ZRaidIntent) -> bool:
	if left.target_tick != right.target_tick:
		return left.target_tick < right.target_tick
	if left.source != right.source:
		return left.source < right.source
	var left_actor := left.actor_id.canonical_key()
	var right_actor := right.actor_id.canonical_key()
	if left_actor != right_actor:
		return left_actor < right_actor
	if left.sequence != right.sequence:
		return left.sequence < right.sequence
	return left.request_id.canonical_key() < right.request_id.canonical_key()
