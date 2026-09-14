extends SceneTree
## Headless contract for player locomotion, facing resolution, and input intent seam.
## Run with: godot --headless --path . --resolution 1920x1080 --audio-driver Dummy --script res://tests/raid/player_locomotion_contract.gd

const Locomotion = preload("res://game/world/player/player_locomotion.gd")
const Facing = preload("res://game/world/player/player_facing.gd")
const IntentAdapter = preload("res://game/input/ui_intent_adapter.gd")
const WorldUnits = preload("res://game/domain/z_world_units.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("PLAYER_LOCOMOTION_CONTRACT: " + message)


func run() -> void:
	_test_ui_intent_adapter()
	_test_facing_resolution_and_tie_breaks()
	_test_acceleration_from_rest()
	_test_deceleration_to_stop()
	_test_clamped_max_speeds_and_stances()
	_test_diagonal_normalization_policy()
	_test_intent_validation_rejections()
	_test_raid_authority_integration()
	_test_determinism_and_digest()

	print("PLAYER_LOCOMOTION_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_ui_intent_adapter() -> void:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "locomotion_001"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"profile_locomotion", &"player")
	check(admission.is_usable(), "session admission is valid")

	var adapter := IntentAdapter.new()
	check(not adapter.is_configured(), "adapter starts unconfigured")
	check(adapter.build_movement_intent(1, Vector2.ONE) == null, "unconfigured adapter rejects build")
	check(adapter.last_error() == &"adapter_unconfigured", "unconfigured diagnostic is recorded")

	check(adapter.configure(
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		admission.generation
	), "adapter configures with valid admission")
	check(adapter.is_configured(), "adapter reports configured")

	# Cardinal intent generation
	var cardinal_intent := adapter.build_movement_intent(
		1, Vector2(1.0, 0.0), Vector2.ZERO, false, false
	)
	check(cardinal_intent != null, "cardinal movement intent builds")
	check(cardinal_intent.source == ZRaidIntent.Source.PLAYER, "intent source is strictly PLAYER")
	check(cardinal_intent.kind == IntentAdapter.INTENT_KIND_MOVEMENT, "intent kind is player_movement")
	check(cardinal_intent.target_tick == 1, "target tick is preserved")
	check(cardinal_intent.sequence == 1, "sequence is monotonic")
	check(cardinal_intent.payload["move_vector"] == Vector2i(IntentAdapter.INPUT_SCALE, 0),
		"cardinal right input scales to exact fixed scale")
	check(cardinal_intent.payload["facing_vector"] == Vector2i.ZERO, "zero facing maps to zero vector")
	check(not cardinal_intent.payload["sprint"], "sprint flag is false")
	check(not cardinal_intent.payload["crouch"], "crouch flag is false")
	check(ZCanonicalValue.is_bounded(cardinal_intent.payload), "payload is bounded canonical value")

	# Discrete action input generation
	var action_intent := adapter.build_movement_intent_from_actions(
		2, true, false, false, true, Vector2(0.0, -1.0), true, false
	)
	check(action_intent != null, "action-based movement intent builds")
	check(action_intent.sequence == 2, "sequence increments for next intent")
	check(action_intent.payload["sprint"] and not action_intent.payload["crouch"],
		"action flags reflect sprint=true crouch=false")
	check(action_intent.payload["facing_vector"] == Vector2i(0, -IntentAdapter.INPUT_SCALE),
		"action facing maps to negative Y (up)")

	# Diagonal normalization in intent generation
	var raw_diagonal := Vector2(1.0, 1.0)
	var diag_intent := adapter.build_movement_intent(3, raw_diagonal)
	var move_vec: Vector2i = diag_intent.payload["move_vector"]
	check(move_vec.x == 707107 and move_vec.y == 707107,
		"diagonal input is normalized to 1.0 before fixed-point scaling")
	var move_len := sqrt(float(move_vec.x * move_vec.x + move_vec.y * move_vec.y))
	check(absf(move_len - float(IntentAdapter.INPUT_SCALE)) <= 1.5,
		"normalized diagonal magnitude matches 1_000_000 scale")

	# Analog sub-unit input preserved
	var half_intent := adapter.build_movement_intent(4, Vector2(0.5, 0.0))
	check(half_intent.payload["move_vector"] == Vector2i(500000, 0),
		"sub-unit analog stick magnitude is preserved without stretching")

	# Over-magnitude clamped to 1.0
	var over_intent := adapter.build_movement_intent(5, Vector2(10.0, 0.0))
	check(over_intent.payload["move_vector"] == Vector2i(IntentAdapter.INPUT_SCALE, 0),
		"over-magnitude input is clamped to unit length")

	# Transform non-authority proof: adapter cannot mutate scene/transform state
	var dummy_node := Node2D.new()
	dummy_node.position = Vector2(100.0, 200.0)
	dummy_node.rotation = 1.234
	dummy_node.scale = Vector2(2.0, 2.0)
	var orig_transform := dummy_node.transform
	var _intent := adapter.build_movement_intent(6, Vector2(1.0, 1.0), Vector2(0.0, 1.0), true, false)
	check(dummy_node.transform == orig_transform,
		"intent adapter never writes or mutates transforms")
	dummy_node.free()


func _test_facing_resolution_and_tie_breaks() -> void:
	# Zero input retains current facing
	check(Facing.resolve_facing_4(Vector2.ZERO, Facing.Facing4.NORTH) == Facing.Facing4.NORTH,
		"zero vector maintains 4-way facing")
	check(Facing.resolve_facing_8(Vector2.ZERO, Facing.Facing8.NORTH_WEST) == Facing.Facing8.NORTH_WEST,
		"zero vector maintains 8-way facing")

	# Cardinal resolution
	check(Facing.resolve_facing_4(Vector2(0.0, -1.0)) == Facing.Facing4.NORTH, "4-way north")
	check(Facing.resolve_facing_4(Vector2(1.0, 0.0)) == Facing.Facing4.EAST, "4-way east")
	check(Facing.resolve_facing_4(Vector2(0.0, 1.0)) == Facing.Facing4.SOUTH, "4-way south")
	check(Facing.resolve_facing_4(Vector2(-1.0, 0.0)) == Facing.Facing4.WEST, "4-way west")

	# Dominant axis resolution
	check(Facing.resolve_facing_4(Vector2(1.0, 0.2)) == Facing.Facing4.EAST, "horizontal dominant east")
	check(Facing.resolve_facing_4(Vector2(-1.0, 0.5)) == Facing.Facing4.WEST, "horizontal dominant west")
	check(Facing.resolve_facing_4(Vector2(0.3, 1.0)) == Facing.Facing4.SOUTH, "vertical dominant south")
	check(Facing.resolve_facing_4(Vector2(-0.4, -1.0)) == Facing.Facing4.NORTH, "vertical dominant north")

	# 4-way diagonal tie-break: hysteresis retention
	var se_diag := Vector2(1.0, 1.0)
	check(Facing.resolve_facing_4(se_diag, Facing.Facing4.SOUTH) == Facing.Facing4.SOUTH,
		"diagonal SE with current SOUTH retains SOUTH")
	check(Facing.resolve_facing_4(se_diag, Facing.Facing4.EAST) == Facing.Facing4.EAST,
		"diagonal SE with current EAST retains EAST")
	check(Facing.resolve_facing_4(se_diag, Facing.Facing4.NORTH) == Facing.Facing4.SOUTH,
		"diagonal SE with non-matching NORTH falls back to vertical SOUTH")
	check(Facing.resolve_facing_4(se_diag, Facing.Facing4.WEST) == Facing.Facing4.SOUTH,
		"diagonal SE with non-matching WEST falls back to vertical SOUTH")

	var nw_diag := Vector2(-1.0, -1.0)
	check(Facing.resolve_facing_4(nw_diag, Facing.Facing4.NORTH) == Facing.Facing4.NORTH,
		"diagonal NW with current NORTH retains NORTH")
	check(Facing.resolve_facing_4(nw_diag, Facing.Facing4.WEST) == Facing.Facing4.WEST,
		"diagonal NW with current WEST retains WEST")
	check(Facing.resolve_facing_4(nw_diag, Facing.Facing4.SOUTH) == Facing.Facing4.NORTH,
		"diagonal NW with non-matching SOUTH falls back to vertical NORTH")

	# 4-way explicit tie-break policy overrides
	check(Facing.resolve_facing_4(se_diag, Facing.Facing4.NORTH, Facing.TieBreak4.PREFER_HORIZONTAL) == Facing.Facing4.EAST,
		"prefer horizontal tie-break chooses EAST on SE diagonal")
	check(Facing.resolve_facing_4(se_diag, Facing.Facing4.WEST, Facing.TieBreak4.PREFER_VERTICAL) == Facing.Facing4.SOUTH,
		"prefer vertical tie-break chooses SOUTH on SE diagonal")

	# 8-way resolution
	check(Facing.resolve_facing_8(Vector2(0.0, -1.0)) == Facing.Facing8.NORTH, "8-way north")
	check(Facing.resolve_facing_8(Vector2(1.0, -1.0)) == Facing.Facing8.NORTH_EAST, "8-way north-east")
	check(Facing.resolve_facing_8(Vector2(1.0, 0.0)) == Facing.Facing8.EAST, "8-way east")
	check(Facing.resolve_facing_8(Vector2(1.0, 1.0)) == Facing.Facing8.SOUTH_EAST, "8-way south-east")
	check(Facing.resolve_facing_8(Vector2(0.0, 1.0)) == Facing.Facing8.SOUTH, "8-way south")
	check(Facing.resolve_facing_8(Vector2(-1.0, 1.0)) == Facing.Facing8.SOUTH_WEST, "8-way south-west")
	check(Facing.resolve_facing_8(Vector2(-1.0, 0.0)) == Facing.Facing8.WEST, "8-way west")
	check(Facing.resolve_facing_8(Vector2(-1.0, -1.0)) == Facing.Facing8.NORTH_WEST, "8-way north-west")

	# 8-way sector boundary tie-break: exact 22.5 deg multiples prefer cardinal
	# At 22.5 deg (boundary between EAST and SOUTH_EAST):
	var b_east_se := Vector2(cos(TAU / 16.0), sin(TAU / 16.0))
	check(Facing.resolve_facing_8(b_east_se) == Facing.Facing8.EAST,
		"boundary tie at 22.5 deg prefers cardinal EAST")
	# At 67.5 deg (boundary between SOUTH_EAST and SOUTH):
	var b_se_south := Vector2(cos(3.0 * TAU / 16.0), sin(3.0 * TAU / 16.0))
	check(Facing.resolve_facing_8(b_se_south) == Facing.Facing8.SOUTH,
		"boundary tie at 67.5 deg prefers cardinal SOUTH")
	# At 112.5 deg (boundary between SOUTH and SOUTH_WEST):
	var b_south_sw := Vector2(cos(5.0 * TAU / 16.0), sin(5.0 * TAU / 16.0))
	check(Facing.resolve_facing_8(b_south_sw) == Facing.Facing8.SOUTH,
		"boundary tie at 112.5 deg prefers cardinal SOUTH")
	# At 157.5 deg (boundary between SOUTH_WEST and WEST):
	var b_sw_west := Vector2(cos(7.0 * TAU / 16.0), sin(7.0 * TAU / 16.0))
	check(Facing.resolve_facing_8(b_sw_west) == Facing.Facing8.WEST,
		"boundary tie at 157.5 deg prefers cardinal WEST")

	# Vector conversion helpers
	check(Facing.facing_4_to_vector(Facing.Facing4.NORTH) == Vector2(0.0, -1.0), "facing 4 vector north")
	check(Facing.facing_8_to_vector(Facing.Facing8.SOUTH_EAST).is_equal_approx(Vector2(0.70710678, 0.70710678)),
		"facing 8 vector south-east")
	check(Facing.facing_name_4(Facing.Facing4.EAST) == &"east", "facing 4 name")
	check(Facing.facing_name_8(Facing.Facing8.NORTH_WEST) == &"north_west", "facing 8 name")


func _test_acceleration_from_rest() -> void:
	var actor := ZEntityId.from_parts(PackedStringArray(["fixture", "loco", "accel_actor"]))
	var loco := Locomotion.new()
	loco.configure(actor, Vector2.ZERO, Facing.Facing4.SOUTH)
	check(loco.velocity_px == Vector2.ZERO and loco.position_px == Vector2.ZERO, "starts at rest")

	var accel_per_tick := Locomotion.ACCELERATION_PX_PER_SEC2 * Locomotion.TICK_DELTA
	check(absf(accel_per_tick - 12.8) <= 0.0001, "acceleration per tick is exactly 12.8 px/s")

	# Accelerating right
	for tick in range(1, 11):
		var snap := loco.step_tick(tick, Vector2(1.0, 0.0), Vector2.ZERO, false, false)
		check(snap["ok"], "step tick %d ok" % tick)
		var expected_speed: float = minf(128.0, float(tick) * accel_per_tick)
		check(absf(loco.velocity_px.x - expected_speed) <= 0.01,
			"tick %d velocity x is expected %.2f (observed %.2f)" % [tick, expected_speed, loco.velocity_px.x])
		check(loco.velocity_px.y == 0.0, "velocity y remains zero during cardinal X move")
		check(loco.position_px.x > 0.0, "position advances monotonically")

	# At tick 10: reaches exactly max walk speed 128 px/s
	check(absf(loco.velocity_px.x - Locomotion.WALK_SPEED_PX_PER_SEC) <= 0.01,
		"tick 10 reaches max walk speed 128 px/s")

	# Tick 11: remains clamped at max walk speed
	loco.step_tick(11, Vector2(1.0, 0.0), Vector2.ZERO, false, false)
	check(absf(loco.velocity_px.x - Locomotion.WALK_SPEED_PX_PER_SEC) <= 0.0001,
		"tick 11 speed remains clamped at 128 px/s")


func _test_deceleration_to_stop() -> void:
	var actor := ZEntityId.from_parts(PackedStringArray(["fixture", "loco", "decel_actor"]))
	var loco := Locomotion.new()
	loco.configure(actor, Vector2.ZERO, Facing.Facing4.EAST)
	loco.velocity_px = Vector2(Locomotion.WALK_SPEED_PX_PER_SEC, 0.0)

	var decel_per_tick := Locomotion.DECELERATION_PX_PER_SEC2 * Locomotion.TICK_DELTA
	check(absf(decel_per_tick - 17.066667) <= 0.001, "deceleration per tick is approx 17.067 px/s")

	var tick := 1
	var prior_speed := loco.velocity_px.length()
	while not loco.velocity_px.is_zero_approx() and tick <= 20:
		loco.step_tick(tick, Vector2.ZERO, Vector2.ZERO, false, false)
		var current_speed := loco.velocity_px.length()
		check(current_speed < prior_speed or current_speed == 0.0,
			"tick %d speed decreases during deceleration" % tick)
		prior_speed = current_speed
		tick += 1

	# From 128 px/s with 1024 px/s^2 deceleration: 128 / 17.0667 = 7.5 ticks -> exactly 8 ticks to stop
	check(tick - 1 == 8, "deceleration to exact stop takes exactly 8 ticks (observed %d)" % (tick - 1))
	check(loco.velocity_px == Vector2.ZERO, "velocity is exactly zero at stop")

	# Extra tick with zero input remains at rest
	loco.step_tick(tick, Vector2.ZERO, Vector2.ZERO, false, false)
	check(loco.velocity_px == Vector2.ZERO, "remains at rest on subsequent zero input")


func _test_clamped_max_speeds_and_stances() -> void:
	var actor := ZEntityId.from_parts(PackedStringArray(["fixture", "loco", "speed_actor"]))
	var loco := Locomotion.new()
	loco.configure(actor, Vector2.ZERO, Facing.Facing4.SOUTH)

	# Walk max speed
	for tick in range(1, 20):
		loco.step_tick(tick, Vector2(0.0, 1.0), Vector2.ZERO, false, false)
	check(absf(loco.velocity_px.length() - Locomotion.WALK_SPEED_PX_PER_SEC) <= 0.001,
		"walk clamps to 128 px/s")
	check(loco.stance == Locomotion.Stance.STAND, "stance is STAND")

	# Sprint max speed
	for tick in range(20, 40):
		loco.step_tick(tick, Vector2(0.0, 1.0), Vector2.ZERO, true, false)
	check(absf(loco.velocity_px.length() - Locomotion.SPRINT_SPEED_PX_PER_SEC) <= 0.001,
		"sprint clamps to 192 px/s")
	check(loco.stance == Locomotion.Stance.SPRINT, "stance is SPRINT")

	# Crouch deceleration down from sprint
	for tick in range(40, 60):
		loco.step_tick(tick, Vector2(0.0, 1.0), Vector2.ZERO, false, true)
	check(absf(loco.velocity_px.length() - Locomotion.CROUCH_SPEED_PX_PER_SEC) <= 0.001,
		"crouch clamps to 64 px/s")
	check(loco.stance == Locomotion.Stance.CROUCH, "stance is CROUCH")

	# Simultaneous sprint + crouch: crouch takes priority
	for tick in range(60, 70):
		loco.step_tick(tick, Vector2(0.0, 1.0), Vector2.ZERO, true, true)
	check(absf(loco.velocity_px.length() - Locomotion.CROUCH_SPEED_PX_PER_SEC) <= 0.001,
		"simultaneous sprint and crouch clamps to crouch speed 64 px/s")
	check(loco.stance == Locomotion.Stance.CROUCH, "simultaneous stance resolves to CROUCH")


func _test_diagonal_normalization_policy() -> void:
	var actor_cardinal := ZEntityId.from_parts(PackedStringArray(["fixture", "loco", "cardinal"]))
	var actor_diagonal := ZEntityId.from_parts(PackedStringArray(["fixture", "loco", "diagonal"]))

	var loco_cardinal := Locomotion.new()
	loco_cardinal.configure(actor_cardinal, Vector2.ZERO, Facing.Facing4.EAST)

	var loco_diagonal := Locomotion.new()
	loco_diagonal.configure(actor_diagonal, Vector2.ZERO, Facing.Facing4.SOUTH)

	for tick in range(1, 30):
		loco_cardinal.step_tick(tick, Vector2(1.0, 0.0), Vector2.ZERO, false, false)
		# Raw unnormalized digital diagonal (1, 1) has length 1.4142
		loco_diagonal.step_tick(tick, Vector2(1.0, 1.0), Vector2.ZERO, false, false)

	var cardinal_speed := loco_cardinal.velocity_px.length()
	var diagonal_speed := loco_diagonal.velocity_px.length()

	check(absf(cardinal_speed - Locomotion.WALK_SPEED_PX_PER_SEC) <= 0.001,
		"cardinal reaches 128 px/s")
	check(absf(diagonal_speed - Locomotion.WALK_SPEED_PX_PER_SEC) <= 0.001,
		"diagonal reaches 128 px/s (NOT 128 * sqrt(2) = 181)")
	check(absf(cardinal_speed - diagonal_speed) <= 0.001,
		"diagonal normalization policy ensures diagonal speed exactly equals cardinal speed")

	# Distance traveled should be identical
	var cardinal_dist := loco_cardinal.position_px.length()
	var diagonal_dist := loco_diagonal.position_px.length()
	check(absf(cardinal_dist - diagonal_dist) <= 0.01,
		"distance traveled diagonally matches cardinal distance")


func _test_intent_validation_rejections() -> void:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "loco", "val_raid"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"val_profile", &"player")

	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 101), "validation authority configures")
	var gen := authority.generation()
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, gen), "authority activates")

	var request := ZRequestId.from_parts(PackedStringArray(["val", "req_001"]))

	# Valid baseline intent
	var valid_intent := IntentAdapter.create_movement_intent(
		request, admission.session_id, admission.actor_id,
		admission.authority_epoch, gen, 1, 1, Vector2(1.0, 0.0)
	)
	check(authority.enqueue_intent(valid_intent, gen), "well-formed movement intent is admitted")

	# Rejection 1: Invalid source (AI instead of PLAYER)
	var ai_source_intent := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["val", "ai_source"])),
		ZRaidIntent.Source.AI,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		gen, 1, 2, IntentAdapter.INTENT_KIND_MOVEMENT,
		valid_intent.payload
	)
	check(not authority.enqueue_intent(ai_source_intent, gen)
		and authority.last_error == &"actor_source_not_authorized",
		"AI source on player sequence/actor is rejected as unauthorized")

	# Rejection 2: Wrong session
	var wrong_session := ZSessionId.from_parts(PackedStringArray(["offline", "wrong", "00000099"]))
	var wrong_session_intent := IntentAdapter.create_movement_intent(
		ZRequestId.from_parts(PackedStringArray(["val", "wrong_session"])),
		wrong_session, admission.actor_id, admission.authority_epoch,
		gen, 1, 3, Vector2(1.0, 0.0)
	)
	check(not authority.enqueue_intent(wrong_session_intent, gen)
		and authority.last_error == &"session_mismatch", "session mismatch rejected")

	# Rejection 3: Wrong actor
	var wrong_actor := ZEntityId.from_parts(PackedStringArray(["offline", "wrong", "actor"]))
	var wrong_actor_intent := IntentAdapter.create_movement_intent(
		ZRequestId.from_parts(PackedStringArray(["val", "wrong_actor"])),
		admission.session_id, wrong_actor, admission.authority_epoch,
		gen, 1, 4, Vector2(1.0, 0.0)
	)
	check(not authority.enqueue_intent(wrong_actor_intent, gen)
		and authority.last_error == &"actor_source_not_authorized",
		"wrong actor rejected as unauthorized by authority")
	var queue := ZRaidIntentQueue.new()
	check(not queue.admit(wrong_actor_intent, 0, admission.session_id, admission.actor_id, admission.authority_epoch, gen)
		and queue.last_error == &"actor_mismatch",
		"wrong actor rejected as actor_mismatch by queue")

	# Rejection 4: Target tick in the past
	var past_intent := IntentAdapter.create_movement_intent(
		ZRequestId.from_parts(PackedStringArray(["val", "past_tick"])),
		admission.session_id, admission.actor_id, admission.authority_epoch,
		gen, 0, 5, Vector2(1.0, 0.0)
	)
	check(not authority.enqueue_intent(past_intent, gen)
		and authority.last_error == &"target_tick_out_of_bounds", "past target tick rejected")

	# Rejection 5: Target tick > 600 in future
	var future_intent := IntentAdapter.create_movement_intent(
		ZRequestId.from_parts(PackedStringArray(["val", "far_future"])),
		admission.session_id, admission.actor_id, admission.authority_epoch,
		gen, 602, 6, Vector2(1.0, 0.0)
	)
	check(not authority.enqueue_intent(future_intent, gen)
		and authority.last_error == &"target_tick_out_of_bounds", "far future tick rejected")

	# Rejection 6: Float in payload (not bounded canonical value)
	var float_intent := ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["val", "float_payload"])),
		ZRaidIntent.Source.PLAYER,
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		gen, 1, 7, IntentAdapter.INTENT_KIND_MOVEMENT,
		{"move_vector": Vector2(1.0, 0.0)} # float Vector2 instead of Vector2i!
	)
	check(not authority.enqueue_intent(float_intent, gen)
		and authority.last_error == &"payload_invalid_or_unbounded", "float in payload rejected")

	# Rejection 7: Missing keys in payload (payload validator)
	var missing_key_payload := {"move_vector": Vector2i.ZERO}
	check(IntentAdapter.validate_movement_payload(missing_key_payload) == &"payload_key_count_invalid",
		"payload missing keys rejected")

	# Rejection 8: Extra keys in payload
	var extra_key_payload := valid_intent.payload.duplicate(true)
	extra_key_payload["cheat_speed"] = 9999
	check(IntentAdapter.validate_movement_payload(extra_key_payload) == &"payload_key_count_invalid",
		"payload with extra unapproved keys rejected")


func _test_raid_authority_integration() -> void:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "loco", "integ_raid"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"integ_profile", &"player")

	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 202), "integration authority configures")
	var gen := authority.generation()

	var loco := Locomotion.new()
	loco.configure(admission.actor_id, Vector2(100.0, 100.0), Facing.Facing4.SOUTH)

	check(loco.register_with_authority(authority, gen), "locomotion registers in TickPhase.MOVEMENT")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, gen), "authority transitions to ACTIVE")

	var adapter := IntentAdapter.new()
	adapter.configure(admission.session_id, admission.actor_id, admission.authority_epoch, gen)

	# Enqueue 5 movement intents for ticks 1..5
	for t in range(1, 6):
		var intent := adapter.build_movement_intent(t, Vector2(1.0, 0.0), Vector2.ZERO, false, false)
		check(authority.enqueue_intent(intent, gen), "intent for tick %d admitted" % t)

	# Step clock and advance ticks through RaidAuthority
	for t in range(1, 6):
		authority.clock.step(1)
		check(authority.advance_one(gen), "authority advances tick %d" % t)
		check(loco.last_processed_tick == t, "locomotion processed tick %d in phase MOVEMENT" % t)

	check(loco.position_px.x > 100.0, "position advanced in authority simulation")
	check(loco.velocity_px.x > 0.0, "velocity is positive")
	check(authority.last_processed_tick == 5, "authority reached tick 5")


func _test_determinism_and_digest() -> void:
	var run_a_snapshots: Array[Dictionary] = []
	var run_b_snapshots: Array[Dictionary] = []
	var run_a_digests: Array[String] = []
	var run_b_digests: Array[String] = []

	# Run A
	var actor_a := ZEntityId.from_parts(PackedStringArray(["fixture", "det", "actor_a"]))
	var loco_a := Locomotion.new()
	loco_a.configure(actor_a, Vector2(50.0, 50.0), Facing.Facing4.SOUTH)

	for tick in range(1, 61):
		# Script of inputs:
		# ticks 1..10: accelerate right
		# ticks 11..20: sprint down-right
		# ticks 21..30: aim left while moving up
		# ticks 31..40: crouch move left
		# ticks 41..60: decelerate to stop
		var move_in := Vector2.ZERO
		var face_in := Vector2.ZERO
		var sprint := false
		var crouch := false

		if tick <= 10:
			move_in = Vector2(1.0, 0.0)
		elif tick <= 20:
			move_in = Vector2(1.0, 1.0)
			sprint = true
		elif tick <= 30:
			move_in = Vector2(0.0, -1.0)
			face_in = Vector2(-1.0, 0.0)
		elif tick <= 40:
			move_in = Vector2(-1.0, 0.0)
			crouch = true
		# ticks 41..60 are zero input (stopping)

		var snap := loco_a.step_tick(tick, move_in, face_in, sprint, crouch)
		run_a_snapshots.append(snap)
		run_a_digests.append(loco_a.digest())

	# Run B: Identical sequence from fresh instance
	var actor_b := ZEntityId.from_parts(PackedStringArray(["fixture", "det", "actor_a"]))
	var loco_b := Locomotion.new()
	loco_b.configure(actor_b, Vector2(50.0, 50.0), Facing.Facing4.SOUTH)

	for tick in range(1, 61):
		var move_in := Vector2.ZERO
		var face_in := Vector2.ZERO
		var sprint := false
		var crouch := false

		if tick <= 10:
			move_in = Vector2(1.0, 0.0)
		elif tick <= 20:
			move_in = Vector2(1.0, 1.0)
			sprint = true
		elif tick <= 30:
			move_in = Vector2(0.0, -1.0)
			face_in = Vector2(-1.0, 0.0)
		elif tick <= 40:
			move_in = Vector2(-1.0, 0.0)
			crouch = true

		var snap := loco_b.step_tick(tick, move_in, face_in, sprint, crouch)
		run_b_snapshots.append(snap)
		run_b_digests.append(loco_b.digest())

	check(run_a_digests.size() == 60 and run_b_digests.size() == 60, "60 ticks processed in both runs")
	var identical_digests := true
	for i in 60:
		if run_a_digests[i] != run_b_digests[i]:
			identical_digests = false
			break
	check(identical_digests, "identical tick scripts produce 100% bit-for-bit identical digests")

	var identical_positions := true
	for i in 60:
		if run_a_snapshots[i]["position_px"] != run_b_snapshots[i]["position_px"]:
			identical_positions = false
			break
	check(identical_positions, "identical tick scripts produce identical positions")

	var identical_velocities := true
	for i in 60:
		if run_a_snapshots[i]["velocity_px"] != run_b_snapshots[i]["velocity_px"]:
			identical_velocities = false
			break
	check(identical_velocities, "identical tick scripts produce identical velocities")

	var identical_facings := true
	for i in 60:
		if run_a_snapshots[i]["facing_4"] != run_b_snapshots[i]["facing_4"] \
				or run_a_snapshots[i]["facing_8"] != run_b_snapshots[i]["facing_8"]:
			identical_facings = false
			break
	check(identical_facings, "identical tick scripts produce identical discrete facings")
