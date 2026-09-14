class_name UIIntentAdapter
extends RefCounted
## Game-owned adapter converting logical UI / controller actions into bounded
## raid intents. This adapter has no transform authority and never mutates
## scene or spatial state.

const INTENT_KIND_MOVEMENT: StringName = &"player_movement"
const INPUT_SCALE: int = 1_000_000
const MAX_REQUEST_SEQUENCE: int = 2_147_483_647

var _session_id: ZSessionId
var _actor_id: ZEntityId
var _authority_epoch: int = 0
var _generation: int = 0
var _next_sequence: int = 0
var _last_error: StringName = &""


func configure(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	authority_epoch: int,
	generation: int
) -> bool:
	_last_error = &""
	if session_id == null or not session_id.is_initialized():
		_last_error = &"session_id_invalid"
		return false
	if actor_id == null or not actor_id.is_initialized():
		_last_error = &"actor_id_invalid"
		return false
	if authority_epoch <= 0 or generation <= 0:
		_last_error = &"epoch_or_generation_invalid"
		return false
	_session_id = session_id
	_actor_id = actor_id
	_authority_epoch = authority_epoch
	_generation = generation
	_next_sequence = 0
	return true


func is_configured() -> bool:
	return _session_id != null and _actor_id != null and _authority_epoch > 0 and _generation > 0


func last_error() -> StringName:
	return _last_error


func build_movement_intent(
	target_tick: int,
	move_input: Vector2,
	facing_input: Vector2 = Vector2.ZERO,
	sprint: bool = false,
	crouch: bool = false,
	request_id: ZRequestId = null
) -> ZRaidIntent:
	if not is_configured():
		_last_error = &"adapter_unconfigured"
		return null
	_next_sequence += 1
	var resolved_request_id := request_id
	if resolved_request_id == null:
		var actor_slot := _actor_id.canonical_key().get_slice(".", 4)
		resolved_request_id = ZRequestId.from_parts(PackedStringArray([
			"move",
			actor_slot if not actor_slot.is_empty() else "player",
			"%08d" % _next_sequence,
		]))
	return create_movement_intent(
		resolved_request_id,
		_session_id,
		_actor_id,
		_authority_epoch,
		_generation,
		target_tick,
		_next_sequence,
		move_input,
		facing_input,
		sprint,
		crouch
	)


func build_movement_intent_from_actions(
	target_tick: int,
	move_up: bool,
	move_left: bool,
	move_down: bool,
	move_right: bool,
	facing_input: Vector2 = Vector2.ZERO,
	sprint: bool = false,
	crouch: bool = false,
	request_id: ZRequestId = null
) -> ZRaidIntent:
	var move_x := (1.0 if move_right else 0.0) - (1.0 if move_left else 0.0)
	var move_y := (1.0 if move_down else 0.0) - (1.0 if move_up else 0.0)
	return build_movement_intent(
		target_tick,
		Vector2(move_x, move_y),
		facing_input,
		sprint,
		crouch,
		request_id
	)


static func create_movement_intent(
	request_id: ZRequestId,
	session_id: ZSessionId,
	actor_id: ZEntityId,
	authority_epoch: int,
	generation: int,
	target_tick: int,
	sequence: int,
	move_input: Vector2,
	facing_input: Vector2 = Vector2.ZERO,
	sprint: bool = false,
	crouch: bool = false
) -> ZRaidIntent:
	var normalized_move := normalize_input(move_input)
	var normalized_facing := normalize_input(facing_input)

	var move_raw := Vector2i(
		roundi(normalized_move.x * INPUT_SCALE),
		roundi(normalized_move.y * INPUT_SCALE)
	)
	var facing_raw := Vector2i(
		roundi(normalized_facing.x * INPUT_SCALE),
		roundi(normalized_facing.y * INPUT_SCALE)
	)

	var payload := {
		"crouch": crouch,
		"facing_vector": facing_raw,
		"move_vector": move_raw,
		"sprint": sprint,
	}

	return ZRaidIntent.create(
		request_id,
		ZRaidIntent.Source.PLAYER,
		session_id,
		actor_id,
		authority_epoch,
		generation,
		target_tick,
		sequence,
		INTENT_KIND_MOVEMENT,
		payload
	)


static func normalize_input(raw: Vector2) -> Vector2:
	if not _is_finite_vector(raw):
		return Vector2.ZERO
	var length_sq := raw.length_squared()
	if length_sq > 1.0:
		return raw.normalized()
	return raw


static func _is_finite_vector(v: Vector2) -> bool:
	return not is_nan(v.x) and not is_nan(v.y) and not is_inf(v.x) and not is_inf(v.y)


static func validate_movement_payload(payload: Dictionary) -> StringName:
	if not ZCanonicalValue.is_bounded(payload):
		return &"payload_unbounded_or_invalid"
	if payload.size() != 4:
		return &"payload_key_count_invalid"
	for key in ["move_vector", "facing_vector", "sprint", "crouch"]:
		if not payload.has(key):
			return &"payload_missing_required_key"
	if typeof(payload["move_vector"]) != TYPE_VECTOR2I:
		return &"payload_move_vector_invalid"
	if typeof(payload["facing_vector"]) != TYPE_VECTOR2I:
		return &"payload_facing_vector_invalid"
	if typeof(payload["sprint"]) != TYPE_BOOL:
		return &"payload_sprint_invalid"
	if typeof(payload["crouch"]) != TYPE_BOOL:
		return &"payload_crouch_invalid"
	var move_raw: Vector2i = payload["move_vector"]
	if absi(move_raw.x) > INPUT_SCALE + 1 or absi(move_raw.y) > INPUT_SCALE + 1:
		return &"payload_move_vector_out_of_bounds"
	var facing_raw: Vector2i = payload["facing_vector"]
	if absi(facing_raw.x) > INPUT_SCALE + 1 or absi(facing_raw.y) > INPUT_SCALE + 1:
		return &"payload_facing_vector_out_of_bounds"
	return &""
