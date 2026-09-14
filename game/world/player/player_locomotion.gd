class_name ZPlayerLocomotion
extends RefCounted
## Authoritative deterministic player locomotion module.
##
## Manages player position, velocity, facing, and stance on fixed 60 Hz ticks
## driven by the authoritative RaidClock. UI and input controllers submit
## bounded intents without direct transform authority.

enum Stance {
	STAND = 0,
	SPRINT = 1,
	CROUCH = 2,
}

const WALK_SPEED_PX_PER_SEC: float = 128.0
const SPRINT_SPEED_PX_PER_SEC: float = 192.0
const CROUCH_SPEED_PX_PER_SEC: float = 64.0

const ACCELERATION_PX_PER_SEC2: float = 768.0
const DECELERATION_PX_PER_SEC2: float = 1024.0

const TICK_RATE: int = 60
const TICK_DELTA: float = 1.0 / 60.0

const INPUT_SCALE: int = 1_000_000

## Authoritative player body shape for task 3.6 collision: an axis-aligned
## box (documented in game/world/movement/z_movement_world_2d.gd) of 16x16 px
## inside a 32 px authored tile, leaving 3-cell authored corridors passable.
const DEFAULT_BODY_HALF_EXTENTS_PX: Vector2 = Vector2(8.0, 8.0)

const DEFAULT_PHASE_HANDLER_ID: StringName = &"player_locomotion"
const INTENT_KIND_MOVEMENT: StringName = &"player_movement"

var _actor_id: ZEntityId
var _registered_authority: RaidAuthority
var _generation: int = 0

var position_px: Vector2 = Vector2.ZERO
var velocity_px: Vector2 = Vector2.ZERO
var facing_direction: Vector2 = Vector2(0.0, 1.0)
var facing_4: ZPlayerFacing.Facing4 = ZPlayerFacing.Facing4.SOUTH
var facing_8: ZPlayerFacing.Facing8 = ZPlayerFacing.Facing8.SOUTH
var stance: Stance = Stance.STAND
var last_processed_tick: int = 0
var last_error: StringName = &""
var _movement_world: ZMovementWorld2D = null
var _movement_world_generation: int = -1
var _movement_world_custom: bool = false
var _body_half_extents_px: Vector2 = DEFAULT_BODY_HALF_EXTENTS_PX
var _last_movement_result: ZMovementResult = null
var _last_pose_published: bool = false


func configure(
	actor_id: ZEntityId,
	initial_position_px: Vector2 = Vector2.ZERO,
	initial_facing: ZPlayerFacing.Facing4 = ZPlayerFacing.Facing4.SOUTH
) -> void:
	_actor_id = actor_id
	position_px = initial_position_px
	velocity_px = Vector2.ZERO
	facing_4 = initial_facing
	facing_8 = ZPlayerFacing.facing_4_to_8(initial_facing)
	facing_direction = ZPlayerFacing.facing_4_to_vector(initial_facing)
	stance = Stance.STAND
	last_processed_tick = 0
	last_error = &""
	_last_movement_result = null
	_body_half_extents_px = DEFAULT_BODY_HALF_EXTENTS_PX
	_attach_open_world(0)


func actor_id() -> ZEntityId:
	return _actor_id


func register_with_authority(
	authority: RaidAuthority,
	expected_generation: int,
	priority: int = 0,
	dependencies: PackedStringArray = PackedStringArray()
) -> bool:
	last_error = &""
	if authority == null or not is_instance_valid(authority):
		last_error = &"authority_invalid"
		return false
	if _actor_id == null and authority.admission() != null:
		_actor_id = authority.admission().actor_id
	if _movement_world_custom and _movement_world != null \
			and _movement_world.generation() != expected_generation:
		last_error = &"movement_world_generation_mismatch"
		return false
	var callback := Callable(self, "_handle_movement_phase")
	if not authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		DEFAULT_PHASE_HANDLER_ID,
		callback,
		expected_generation,
		priority,
		dependencies
	):
		last_error = authority.last_error
		return false
	_registered_authority = authority
	_generation = expected_generation
	if not _movement_world_custom and _movement_world_generation != expected_generation:
		_attach_open_world(expected_generation)
	return true


func _handle_movement_phase(
	authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	intents: Array[ZRaidIntent]
) -> bool:
	last_error = &""
	if authority == null or not is_instance_valid(authority):
		last_error = &"authority_invalid"
		return false
	if phase != RaidAuthority.TickPhase.MOVEMENT:
		last_error = &"phase_invalid"
		return false
	if authority.generation() != _generation:
		# Late or replayed dispatch against a replaced or completed raid is
		# inert: no state mutation and no pose publication.
		last_error = &"stale_generation"
		_last_pose_published = false
		return true

	var selected_intent: ZRaidIntent = null
	for intent in intents:
		if intent == null or intent.kind != INTENT_KIND_MOVEMENT:
			continue
		if _actor_id != null and intent.actor_id != null and not intent.actor_id.is_equal(_actor_id):
			continue
		if intent.target_tick != tick:
			continue
		if selected_intent == null or intent.sequence > selected_intent.sequence:
			selected_intent = intent

	if selected_intent != null:
		var step_result := step_with_intent(tick, selected_intent)
		if not bool(step_result.get("ok", false)):
			last_error = StringName(str(step_result.get("reason", "intent_step_failed")))
			step_tick(tick, Vector2.ZERO, Vector2.ZERO, false, false)
	else:
		step_tick(tick, Vector2.ZERO, Vector2.ZERO, false, false)

	if _actor_id != null:
		# The published pose always reports the RESOLVED position: after task
		# 3.6 position_px is only ever written from a movement-world result.
		_last_pose_published = authority.publish_weapon_actor_pose(
			_actor_id,
			position_px,
			facing_direction,
			tick,
			authority.generation()
		)
	else:
		_last_pose_published = false

	return true


func step_tick(
	tick: int,
	move_input_normalized: Vector2,
	facing_input_normalized: Vector2 = Vector2.ZERO,
	sprint: bool = false,
	crouch: bool = false
) -> Dictionary:
	last_error = &""
	if tick <= last_processed_tick:
		last_error = &"tick_regressed"
		return {"ok": false, "reason": last_error}

	var move_in := UIIntentAdapter.normalize_input(move_input_normalized)
	var facing_in := UIIntentAdapter.normalize_input(facing_input_normalized)

	if crouch:
		stance = Stance.CROUCH
	elif sprint:
		stance = Stance.SPRINT
	else:
		stance = Stance.STAND

	var max_speed: float
	match stance:
		Stance.CROUCH: max_speed = CROUCH_SPEED_PX_PER_SEC
		Stance.SPRINT: max_speed = SPRINT_SPEED_PX_PER_SEC
		Stance.STAND, _: max_speed = WALK_SPEED_PX_PER_SEC

	var target_velocity := move_in * max_speed

	if not target_velocity.is_zero_approx():
		var diff := target_velocity - velocity_px
		var diff_len := diff.length()
		var step_rate := DECELERATION_PX_PER_SEC2 if velocity_px.length() > max_speed else ACCELERATION_PX_PER_SEC2
		var step := step_rate * TICK_DELTA
		if diff_len <= step:
			velocity_px = target_velocity
		else:
			velocity_px += (diff / diff_len) * step
	else:
		var current_speed := velocity_px.length()
		var decel_step := DECELERATION_PX_PER_SEC2 * TICK_DELTA
		if current_speed <= decel_step:
			velocity_px = Vector2.ZERO
		else:
			velocity_px -= (velocity_px / current_speed) * decel_step

	var current_speed := velocity_px.length()
	if not target_velocity.is_zero_approx() and current_speed > max_speed:
		velocity_px = velocity_px.normalized() * max_speed

	# Task 3.6: locomotion computes only the desired velocity above; the
	# authoritative position comes back from the movement world. There is no
	# unchecked integration step writing position_px anymore.
	var movement := _resolve_authoritative_step(tick)
	if movement.ok:
		position_px = movement.resolved_position_px
		velocity_px = movement.resolved_velocity_px
		_last_movement_result = movement
	else:
		last_error = movement.reason

	if not facing_in.is_zero_approx():
		facing_direction = facing_in.normalized()
		facing_4 = ZPlayerFacing.resolve_facing_4(facing_direction, facing_4)
		facing_8 = ZPlayerFacing.resolve_facing_8(facing_direction, facing_8)
	elif not velocity_px.is_zero_approx():
		facing_direction = velocity_px.normalized()
		facing_4 = ZPlayerFacing.resolve_facing_4(facing_direction, facing_4)
		facing_8 = ZPlayerFacing.resolve_facing_8(facing_direction, facing_8)
	elif not move_in.is_zero_approx():
		facing_direction = move_in.normalized()
		facing_4 = ZPlayerFacing.resolve_facing_4(facing_direction, facing_4)
		facing_8 = ZPlayerFacing.resolve_facing_8(facing_direction, facing_8)

	last_processed_tick = tick

	var snapshot := get_snapshot()
	snapshot["ok"] = true
	return snapshot


func step_with_intent(tick: int, intent: ZRaidIntent) -> Dictionary:
	last_error = &""
	if intent == null:
		last_error = &"intent_null"
		return {"ok": false, "reason": last_error}
	if intent.source != ZRaidIntent.Source.PLAYER:
		last_error = &"intent_source_invalid"
		return {"ok": false, "reason": last_error}
	if intent.kind != INTENT_KIND_MOVEMENT:
		last_error = &"intent_kind_invalid"
		return {"ok": false, "reason": last_error}
	var payload_error := UIIntentAdapter.validate_movement_payload(intent.payload)
	if not payload_error.is_empty():
		last_error = payload_error
		return {"ok": false, "reason": last_error}

	var move_raw: Vector2i = intent.payload["move_vector"]
	var facing_raw: Vector2i = intent.payload["facing_vector"]
	var sprint: bool = intent.payload["sprint"]
	var crouch: bool = intent.payload["crouch"]

	var move_in := Vector2(float(move_raw.x) / float(INPUT_SCALE), float(move_raw.y) / float(INPUT_SCALE))
	var facing_in := Vector2(float(facing_raw.x) / float(INPUT_SCALE), float(facing_raw.y) / float(INPUT_SCALE))

	return step_tick(tick, move_in, facing_in, sprint, crouch)


func get_snapshot() -> Dictionary:
	var canonical_pos := ZWorldUnits.godot_to_canonical(position_px)
	var weapon_aim := ZWorldUnits.godot_direction_to_weapon(facing_direction)
	var weapon_pos := ZWorldUnits.godot_to_weapon(position_px)
	var tile_pos := ZWorldUnits.godot_to_tile(position_px)
	return {
		"actor_id": _actor_id.canonical_key() if _actor_id != null else "",
		"blocked_axes": _last_movement_result.blocked_axes if _last_movement_result != null else 0,
		"canonical_position": canonical_pos.vector2i_value if canonical_pos.ok else Vector2i.ZERO,
		"facing_4": int(facing_4),
		"facing_8": int(facing_8),
		"facing_direction": facing_direction,
		"last_processed_tick": last_processed_tick,
		"movement_corrected": _last_movement_result.corrected if _last_movement_result != null else false,
		"pose_published": _last_pose_published,
		"position_px": position_px,
		"speed": velocity_px.length(),
		"stance": int(stance),
		"tile_position": tile_pos.vector2i_value if tile_pos.ok else Vector2i.ZERO,
		"velocity_px": velocity_px,
		"weapon_aim": weapon_aim.vector2i_value if weapon_aim.ok else Vector2i.ZERO,
		"weapon_position": weapon_pos.vector2i_value if weapon_pos.ok else Vector2i.ZERO,
	}


func canonical_record() -> Dictionary:
	var canonical_pos := ZWorldUnits.godot_to_canonical(position_px)
	var weapon_aim := ZWorldUnits.godot_direction_to_weapon(facing_direction)
	var weapon_pos := ZWorldUnits.godot_to_weapon(position_px)
	var tile_pos := ZWorldUnits.godot_to_tile(position_px)
	return {
		"actor_id": _actor_id.canonical_key() if _actor_id != null else "",
		"canonical_position": canonical_pos.vector2i_value if canonical_pos.ok else Vector2i.ZERO,
		"facing_4": int(facing_4),
		"facing_8": int(facing_8),
		"last_processed_tick": last_processed_tick,
		"movement_blocked_axes": _last_movement_result.blocked_axes if _last_movement_result != null else 0,
		"movement_corrected": _last_movement_result.corrected if _last_movement_result != null else false,
		"stance": int(stance),
		"tile_position": tile_pos.vector2i_value if tile_pos.ok else Vector2i.ZERO,
		"velocity_raw": Vector2i(
			roundi(velocity_px.x * 1000.0),
			roundi(velocity_px.y * 1000.0)
		),
		"weapon_aim": weapon_aim.vector2i_value if weapon_aim.ok else Vector2i.ZERO,
		"weapon_position": weapon_pos.vector2i_value if weapon_pos.ok else Vector2i.ZERO,
	}


func digest() -> String:
	return ZCanonicalValue.sha256(canonical_record())


func teleport(new_position_px: Vector2) -> bool:
	last_error = &""
	var canonical_check := ZWorldUnits.godot_to_canonical(new_position_px)
	if not canonical_check.ok:
		last_error = canonical_check.error_code
		return false
	if _movement_world != null \
			and (_generation <= 0 or _movement_world_generation == _generation) \
			and _actor_id != null:
		if not _movement_world.teleport_actor(
			_actor_id, new_position_px, _movement_world_generation
		):
			last_error = _movement_world.last_error
			return false
		# Authority wins: read the resolved canonical position back.
		position_px = _movement_world.actor_position_px(_actor_id)
	else:
		position_px = new_position_px
	velocity_px = Vector2.ZERO
	return true

## Attaches a real collision world (task 3.6). The world must already be
## configured for the same generation locomotion runs at; the actor registers
## at the current position with the given body half extents. Fail-closed.
func attach_movement_world(
	world: ZMovementWorld2D,
	body_half_extents_px: Vector2 = DEFAULT_BODY_HALF_EXTENTS_PX
) -> bool:
	last_error = &""
	if world == null or not is_instance_valid(world) or not world.is_configured():
		last_error = &"movement_world_invalid"
		return false
	if _actor_id == null or not _actor_id.is_initialized():
		last_error = &"actor_unconfigured"
		return false
	if _generation > 0 and world.generation() != _generation:
		last_error = &"movement_world_generation_mismatch"
		return false
	if body_half_extents_px.x <= 0.0 or body_half_extents_px.y <= 0.0 \
			or is_nan(body_half_extents_px.x) or is_nan(body_half_extents_px.y):
		last_error = &"body_extents_invalid"
		return false
	if not world.register_actor(_actor_id, position_px, body_half_extents_px, world.generation()):
		last_error = world.last_error
		return false
	_body_half_extents_px = body_half_extents_px
	_movement_world = world
	_movement_world_generation = world.generation()
	_movement_world_custom = true
	return true

## Read-only accessor for composition diagnostics. Presentation consumes
## ZMovementResult values and correction snapshots, never this reference.
func movement_world() -> ZMovementWorld2D:
	return _movement_world

func last_movement_result() -> ZMovementResult:
	return _last_movement_result

## Terminal movement teardown for the raid composition boundary.
func seal_movement_world(expected_generation: int = -1) -> bool:
	last_error = &""
	if _movement_world == null:
		last_error = &"movement_world_missing"
		return false
	var generation := expected_generation \
			if expected_generation >= 0 else _movement_world_generation
	return _movement_world.seal(generation)

func _attach_open_world(generation: int) -> void:
	var world := ZMovementWorld2D.new()
	if not world.configure_open_world(generation):
		last_error = world.last_error
		return
	if _actor_id != null and _actor_id.is_initialized() \
			and not world.register_actor(
				_actor_id, position_px, _body_half_extents_px, generation
			):
		last_error = world.last_error
		return
	_movement_world = world
	_movement_world_generation = generation
	_movement_world_custom = false

func _resolve_authoritative_step(tick: int) -> ZMovementResult:
	var actor_key := _actor_id.canonical_key() \
			if _actor_id != null and _actor_id.is_initialized() else ""
	if _movement_world == null or not is_instance_valid(_movement_world):
		return ZMovementResult.failure(&"movement_world_missing", tick, actor_key)
	if _movement_world.is_sealed():
		return ZMovementResult.failure(&"movement_world_sealed", tick, actor_key)
	if _generation > 0 and _movement_world_generation != _generation:
		return ZMovementResult.failure(
			&"movement_generation_mismatch", tick, actor_key
		)
	return _movement_world.resolve_actor_step(
		_actor_id, tick, velocity_px, _movement_world_generation
	)
