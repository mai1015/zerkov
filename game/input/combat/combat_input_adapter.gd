class_name ZCombatInputAdapter
extends UIIntentAdapter
## One encoder per actor/source for BOTH movement and combat. Inherited movement
## helpers use this same sequence allocator. Never run a second UIIntentAdapter
## for the same actor/source alongside this one.

var _configured_once: bool = false
var _released: bool = false
var _source: ZRaidIntent.Source = ZRaidIntent.Source.PLAYER
var _scope: String = ""


func configure(session_id: ZSessionId, actor_id: ZEntityId, authority_epoch: int, generation: int) -> bool:
	return configure_source(session_id, actor_id, authority_epoch, generation, ZRaidIntent.Source.PLAYER)


func configure_source(session_id: ZSessionId, actor_id: ZEntityId, authority_epoch: int,
	generation: int, source: ZRaidIntent.Source) -> bool:
	_last_error = &""
	if _configured_once or _released:
		_last_error = &"combat_encoder_already_bound"
		return false
	if session_id == null or actor_id == null or source not in [ZRaidIntent.Source.PLAYER, ZRaidIntent.Source.AI]:
		_last_error = &"combat_encoder_identity_invalid"
		return false
	var session_copy := ZSessionId.parse(session_id.canonical_key())
	var actor_copy := ZEntityId.parse(actor_id.canonical_key())
	if not super.configure(session_copy, actor_copy, authority_epoch, generation):
		return false
	_source = source
	_configured_once = true
	_scope = ZCanonicalValue.sha256(binding_context()).substr(0, 32)
	return true


func binding_context() -> Dictionary:
	var result := {"session_id": _session_id.canonical_key() if _session_id != null else "",
		"actor_id": _actor_id.canonical_key() if _actor_id != null else "",
		"authority_epoch": _authority_epoch, "generation": _generation, "source": int(_source)}
	result.make_read_only()
	return result


func is_configured() -> bool:
	return _configured_once and not _released and super.is_configured()


func build_movement_intent(target_tick: int, move_input: Vector2,
	facing_input: Vector2 = Vector2.ZERO, sprint: bool = false, crouch: bool = false,
	request_id: ZRequestId = null) -> ZRaidIntent:
	if not _preflight(target_tick, request_id):
		return null
	# Normalization/canonical payload stay owned by task 3's existing encoder.
	var id := _request_id(request_id)
	var intent := super.build_movement_intent(target_tick, move_input, facing_input, sprint, crouch, id)
	if intent != null:
		intent.source = _source
	return intent


func build_combat_intent(target_tick: int, action: StringName, payload: Dictionary,
	request_id: ZRequestId = null) -> ZRaidIntent:
	if not _preflight(target_tick, request_id):
		return null
	var error := ZCombatActionCodec.validate_payload(action, payload)
	if not error.is_empty():
		_last_error = error
		return null
	var id := _request_id(request_id)
	_next_sequence += 1
	return ZRaidIntent.create(id, _source, _session_id, _actor_id, _authority_epoch,
		_generation, target_tick, _next_sequence,
		StringName(ZCombatActionCodec.INTENT_PREFIX + String(action)), payload)


func release() -> void:
	_released = true
	_session_id = null
	_actor_id = null
	_last_error = &"combat_encoder_released"


func _preflight(target_tick: int, request_id: ZRequestId) -> bool:
	_last_error = &""
	if not is_configured():
		_last_error = &"combat_encoder_unavailable"
		return false
	if target_tick <= 0 or target_tick > ZCombatActionCodec.MAX_COUNTER \
		or _next_sequence >= MAX_REQUEST_SEQUENCE:
		_last_error = &"combat_encoder_counter_exhausted"
		return false
	if request_id != null and ZRequestId.parse(request_id.canonical_key()) == null:
		_last_error = &"combat_request_id_invalid"
		return false
	return true


func _request_id(supplied: ZRequestId) -> ZRequestId:
	if supplied != null:
		return ZRequestId.parse(supplied.canonical_key())
	return ZRequestId.from_parts(PackedStringArray(["input", _scope, str(_next_sequence + 1)]))
