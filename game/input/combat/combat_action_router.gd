class_name ZCombatActionRouter
extends RefCounted
## Task 5.7: CommonUI logical actions and AI combat requests enter the same
## canonical envelope/queue. No weapon, health, inventory, or scene mutations.
## Receipts describe QUEUE ADMISSION ONLY, never a committed attack or heal.

var last_error: StringName = &""
var _encoder: ZCombatInputAdapter
var _sink: ZCombatIntentSink
var _binding: Dictionary = {}
var _inside: bool = false
var _released: bool = false
var _bound_once: bool = false


func bind(encoder: ZCombatInputAdapter, sink: ZCombatIntentSink) -> bool:
	if _bound_once or _released or _inside or encoder == null or not encoder.is_configured() or sink == null:
		last_error = &"combat_router_binding_invalid"
		return false
	var binding := encoder.binding_context()
	_inside = true
	var initial_context := sink.context()
	_inside = false
	if not _context_matches(initial_context, binding):
		last_error = &"combat_router_context_mismatch"
		return false
	_binding = binding.duplicate(true)
	_binding.make_read_only()
	_encoder = encoder
	_sink = sink
	_bound_once = true
	last_error = &""
	return true


## Call only from the current gameplay CommonUI context, not raw InputMap
## polling. Context/modal filtering stays in CommonUI. Include the captured
## generation in callbacks so a replaced session's input is rejected.
func submit_logical(action_id: StringName, payload: Dictionary, target_tick: int,
	expected_generation: int, request_id: ZRequestId = null) -> Dictionary:
	if _binding.get("source", -1) != ZRaidIntent.Source.PLAYER:
		return _reject(&"combat_logical_source_invalid")
	var action := ZCombatActionCodec.action_for_logical(action_id)
	if action.is_empty():
		return _reject(&"combat_action_unsupported")
	return submit_action(action, payload, target_tick, expected_generation, request_id)


## AI/root callers use the same payload codec. Stable producer request IDs may
## be supplied for retries; the existing raid queue rejects duplicates. This
## function does not invent a second lifetime replay ledger.
func submit_action(action: StringName, payload: Dictionary, target_tick: int,
	expected_generation: int, request_id: ZRequestId = null) -> Dictionary:
	if not _preflight(target_tick, expected_generation):
		return _reject(last_error)
	_inside = true
	var intent := _encoder.build_combat_intent(target_tick, action, payload, request_id)
	return _finish(intent)


## Use this instead of a separate movement encoder for the bound actor/source.
func submit_movement(target_tick: int, expected_generation: int, move: Vector2,
	facing: Vector2 = Vector2.ZERO, sprint: bool = false, crouch: bool = false,
	request_id: ZRequestId = null) -> Dictionary:
	if not _preflight(target_tick, expected_generation):
		return _reject(last_error)
	_inside = true
	var intent := _encoder.build_movement_intent(target_tick, move, facing, sprint, crouch, request_id)
	return _finish(intent)


func release() -> bool:
	if _inside:
		last_error = &"combat_router_reentrant"
		return false
	_released = true
	_sink = null
	_encoder = null
	return true


func _finish(intent: ZRaidIntent) -> Dictionary:
	if intent == null:
		var reason := _encoder.last_error()
		_inside = false
		return _reject(reason)
	# Snapshot correlation before crossing the sink. A rejected submission burns
	# its allocated sequence; reusing it could collide with another input path.
	var receipt := {"admitted": false, "committed": false,
		"request_id": intent.request_id.canonical_key(), "sequence": intent.sequence,
		"generation": intent.generation, "target_tick": intent.target_tick, "kind": String(intent.kind), "reason": &""}
	var result := _sink.admit(intent)
	_inside = false
	if not _valid_admission(result):
		# The external operation may have admitted: never claim a safe retry or
		# roll back the sequence when the result contract itself is broken.
		_released = true
		last_error = &"combat_admission_outcome_unknown"
		receipt.reason = last_error
		receipt["outcome_unknown"] = true
		receipt.admitted = null
	else:
		receipt.admitted = result.admitted
		receipt.reason = result.reason
		last_error = receipt.reason
	receipt.make_read_only()
	return receipt


static func _valid_admission(result: Dictionary) -> bool:
	if typeof(result.get("admitted")) != TYPE_BOOL \
		or typeof(result.get("reason")) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return false
	var reason := String(result.reason)
	if reason.to_utf8_buffer().size() > ZCanonicalValue.DEFAULT_MAX_STRING_BYTES:
		return false
	# Contradictory success/error flags are not reliable admission evidence.
	return reason.is_empty() if result.admitted else not reason.is_empty()


func _preflight(target_tick: int, expected_generation: int) -> bool:
	last_error = &""
	if _inside:
		last_error = &"combat_router_reentrant"
		return false
	if _released or not _bound_once or _encoder == null or _sink == null or not _encoder.is_configured():
		last_error = &"combat_router_unavailable"
		return false
	_inside = true
	var context := _sink.context()
	_inside = false
	if expected_generation != _binding.generation or _encoder.binding_context() != _binding \
		or not _context_matches(context, _binding):
		last_error = &"combat_router_context_stale"
		return false
	if context.lifecycle not in ["active", "extracting"]:
		last_error = &"combat_router_phase_closed"
		return false
	if target_tick <= 0 or target_tick > ZCombatActionCodec.MAX_COUNTER \
		or target_tick != context.current_tick + 1:
		last_error = &"combat_router_target_tick_invalid"
		return false
	return true


static func _context_matches(context: Dictionary, binding: Dictionary) -> bool:
	if context.size() != 7 or typeof(context.get("current_tick")) != TYPE_INT \
		or context.current_tick < 0 or context.current_tick >= ZCombatActionCodec.MAX_COUNTER \
		or typeof(context.get("lifecycle")) != TYPE_STRING:
		return false
	for key: String in binding:
		if not context.has(key) or typeof(context[key]) != typeof(binding[key]) or context[key] != binding[key]:
			return false
	return context.lifecycle in ["preparing", "active", "extracting"]


func _reject(reason: StringName) -> Dictionary:
	last_error = reason
	var result := {"admitted": false, "committed": false, "reason": reason}
	result.make_read_only()
	return result
