extends SceneTree
## Headless contract for presentation camera follow, cursor aim mapping, and
## interaction candidate targeting (task 3.7).

const ViewportPolicy = preload("res://game/presentation/world/world_viewport_policy.gd")
const CameraFollow = preload("res://game/presentation/world/world_camera_follow.gd")
const Camera2DNode = preload("res://game/presentation/world/world_camera_2d.gd")
const CursorAdapter = preload("res://game/input/world_cursor_adapter.gd")
const MovementWorldScript = preload("res://game/world/movement/z_movement_world_2d.gd")
const Locomotion = preload("res://game/world/player/player_locomotion.gd")
const IntentAdapter = preload("res://game/input/ui_intent_adapter.gd")
const Output = preload("res://tests/visual/sawmill_yard/exact_output.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("WORLD_CAMERA_CURSOR: " + message)


func run() -> void:
	if DisplayServer.get_name() == "headless":
		root.size = Output.EXACT_SIZE
	if not Output.accepts_window(root):
		push_error("WORLD_CAMERA_CURSOR: exact 1920x1080 root required; observed " + str(root.size))
		quit(2)
		return

	_test_render_scale_and_fit()
	_test_camera_whole_raster_pixels()
	_test_camera_clamps_four_edges()
	_test_camera_converges_to_correction_record()
	_test_screen_world_round_trip()
	_test_pointer_in_matte_rejection()
	_test_candidate_ranking_determinism_and_order_independence()
	_test_interaction_intent_emission()
	_test_adapter_holds_no_transform_authority()

	print("WORLD_CAMERA_CURSOR_RESULT checks=", checks, " failures=", failures)
	quit(1 if failures > 0 else 0)


func _test_render_scale_and_fit() -> void:
	var exact_fit := ViewportPolicy.calculate_fit(Vector2i(1920, 1080))
	check(exact_fit.ok, "1920x1080 fit calculation succeeds")
	check(exact_fit.factor == 3, "fit factor at 1920x1080 is exactly k=3")
	check(exact_fit.displayed_size == Vector2i(1920, 1080), "displayed size matches 1920x1080")
	check(exact_fit.matte_rect == Rect2i(0, 0, 1920, 1080), "matte rect covers full window")
	check(not exact_fit.has_matte, "1920x1080 has zero matte")

	# Explicit matte test case with non-acceptance aspect ratio
	var letterbox_fit := ViewportPolicy.calculate_fit(Vector2i(1920, 1200))
	check(letterbox_fit.factor == 3, "letterbox 1920x1200 uses factor k=3")
	check(letterbox_fit.displayed_size == Vector2i(1920, 1080), "letterbox displayed size is 1920x1080")
	check(letterbox_fit.matte_rect == Rect2i(0, 60, 1920, 1080), "letterbox has 60px vertical matte offset")
	check(letterbox_fit.has_matte, "1920x1200 has non-zero matte")


func _test_camera_whole_raster_pixels() -> void:
	var cam := CameraFollow.new()
	cam.configure(Rect2(0.0, 0.0, 1280.0, 640.0), Vector2(400.0, 250.0))

	var subpixel_targets := [
		Vector2(400.2, 250.7),
		Vector2(400.5, 250.5),
		Vector2(400.8, 250.1),
		Vector2(512.333, 288.666),
		Vector2(320.1, 180.9),
	]
	for target in subpixel_targets:
		var pos := cam.follow_position(target, true)
		check(pos.x == roundf(pos.x), "camera position X is whole world-raster pixel for target " + str(target))
		check(pos.y == roundf(pos.y), "camera position Y is whole world-raster pixel for target " + str(target))

	# Test with presentation impulse
	cam.apply_impulse(Vector2(2.4, -1.7))
	var impulse_pos := cam.follow_position(Vector2(400.0, 250.0), true)
	check(impulse_pos.x == roundf(impulse_pos.x), "camera position X with impulse is whole raster pixel")
	check(impulse_pos.y == roundf(impulse_pos.y), "camera position Y with impulse is whole raster pixel")


func _test_camera_clamps_four_edges() -> void:
	var cam := CameraFollow.new()
	# Level bounds: 1280x640 (Sawmill yard). Viewport: 640x360.
	# Valid camera center ranges: X in [320, 960], Y in [180, 460].
	var bounds := Rect2(0.0, 0.0, 1280.0, 640.0)
	cam.configure(bounds, Vector2(640.0, 320.0))

	# West clamp (X min = 320)
	var west_pos := cam.follow_position(Vector2(100.0, 320.0), true)
	check(west_pos.x == 320.0, "camera clamps at west level edge (320)")

	# East clamp (X max = 960)
	var east_pos := cam.follow_position(Vector2(1200.0, 320.0), true)
	check(east_pos.x == 960.0, "camera clamps at east level edge (960)")

	# North clamp (Y min = 180)
	var north_pos := cam.follow_position(Vector2(640.0, 50.0), true)
	check(north_pos.y == 180.0, "camera clamps at north level edge (180)")

	# South clamp (Y max = 460)
	var south_pos := cam.follow_position(Vector2(640.0, 600.0), true)
	check(south_pos.y == 460.0, "camera clamps at south level edge (460)")


func _test_camera_converges_to_correction_record() -> void:
	var cam := CameraFollow.new()
	# Generous bounds so clamp does not mask convergence:
	cam.configure(Rect2(0.0, 0.0, 2000.0, 2000.0), Vector2(500.0, 500.0))
	cam.set_convergence_rate(0.25)

	# Construct a correction record where requested was (550, 500) but resolved is (520, 500)
	var correction := {
		"actor_id": "test_actor",
		"blocked_axes": 1,
		"blocking_collider_ids": ["fixture.wall"],
		"requested_position_micro": Vector2i(17187500, 15625000), # (550, 500) px
		"resolved_position_micro": Vector2i(16250000, 15625000),  # (520, 500) px
		"tick": 10,
	}

	cam.converge_to_correction(correction, false)
	var initial_dist := absf(cam.current_unrounded_px.x - 520.0)
	check(initial_dist > 0.0, "camera starts away from corrected target")

	var prev_dist := initial_dist
	var monotonic := true
	var no_overshoot := true

	# Step convergence over 20 ticks and verify strict monotonic convergence without overshoot
	for step in range(20):
		cam.step_convergence()
		var cur_x := cam.current_unrounded_px.x
		var dist := absf(cur_x - 520.0)
		if dist > prev_dist + 0.00001:
			monotonic = false
		if cur_x > 520.001:
			# Target is 520 from starting 500, so cur_x must never exceed 520
			no_overshoot = false
		prev_dist = dist

	check(monotonic, "camera distance to corrected position strictly decreases monotonically")
	check(no_overshoot, "camera converges without overshoot oscillation past corrected position")
	check(absf(cam.position_px.x - 520.0) <= 1.0, "camera successfully converged to corrected position")


func _test_screen_world_round_trip() -> void:
	var cam_pos := Vector2(640.0, 320.0)
	var output_size := Vector2i(1920, 1080)

	# Points to test: center, 4 corners of the 640x360 raster, arbitrary interior points
	var test_world_points: Array[Vector2] = [
		cam_pos,                                    # Center
		cam_pos + Vector2(-320.0, -180.0),          # Top-left
		cam_pos + Vector2(319.0, -180.0),           # Top-right
		cam_pos + Vector2(-320.0, 179.0),           # Bottom-left
		cam_pos + Vector2(319.0, 179.0),            # Bottom-right
		Vector2(512.0, 256.0),                      # Interior A
		Vector2(700.0, 350.0),                      # Interior B
	]

	for world_point in test_world_points:
		var expected_raster := Vector2i(floori(world_point.x), floori(world_point.y))
		var screen_pt := ViewportPolicy.world_to_screen(world_point, cam_pos, output_size)
		var aim := ViewportPolicy.screen_to_world(screen_pt, cam_pos, output_size)
		check(aim.inside_surface, "round-trip point is inside world surface: " + str(world_point))
		check(aim.world_raster_pixel == expected_raster,
			"world->screen->world lands in identical raster pixel: expected " + str(expected_raster) + " got " + str(aim.world_raster_pixel))


func _test_pointer_in_matte_rejection() -> void:
	var cam_pos := Vector2(320.0, 180.0)

	# 1920x1080 pointer out of screen bounds
	var negative_screen := Vector2(-10.0, 500.0)
	var res_neg := ViewportPolicy.screen_to_world(negative_screen, cam_pos, Vector2i(1920, 1080))
	check(not res_neg.inside_surface, "negative screen coordinate is outside surface")
	check(res_neg.reason == &"outside_world_surface", "reports outside_world_surface reason")

	# Explicit letterbox case: 1920x1200 (matte is y < 60 and y >= 1140)
	var letterbox_size := Vector2i(1920, 1200)
	var top_matte_pt := Vector2(960.0, 30.0)
	var bottom_matte_pt := Vector2(960.0, 1160.0)
	var valid_surface_pt := Vector2(960.0, 600.0)

	var res_top := ViewportPolicy.screen_to_world(top_matte_pt, cam_pos, letterbox_size)
	check(not res_top.inside_surface, "pointer in top matte is rejected as outside surface")
	check(res_top.reason == &"outside_world_surface", "top matte reason is outside_world_surface")

	var res_bottom := ViewportPolicy.screen_to_world(bottom_matte_pt, cam_pos, letterbox_size)
	check(not res_bottom.inside_surface, "pointer in bottom matte is rejected as outside surface")
	check(res_bottom.reason == &"outside_world_surface", "bottom matte reason is outside_world_surface")

	var res_valid := ViewportPolicy.screen_to_world(valid_surface_pt, cam_pos, letterbox_size)
	check(res_valid.inside_surface, "pointer in letterbox content area is accepted")


func _test_candidate_ranking_determinism_and_order_independence() -> void:
	var adapter := CursorAdapter.new()
	var aim := Vector2(100.0, 100.0)
	var actor := Vector2(50.0, 50.0)

	# Create 4 candidates with known distances and a tie case:
	# A: cell (3, 3) -> center (112, 112) -> aim dist^2 = 288
	# B: cell (2, 2) -> center (80, 80)   -> aim dist^2 = 800
	# C: cell (4, 2) -> center (144, 80)  -> aim dist^2 = 2336
	# D: cell (2, 4) -> center (80, 144)  -> aim dist^2 = 2336 (tie on aim with C, check actor dist / tie-break)
	var c_a := {"id": "zerkov.loot.sawmill.crate.a", "cell": Vector2i(3, 3)}
	var c_b := {"id": "zerkov.loot.sawmill.crate.b", "cell": Vector2i(2, 2)}
	var c_c := {"id": "zerkov.loot.sawmill.crate.c", "cell": Vector2i(4, 2)}
	var c_d := {"id": "zerkov.loot.sawmill.crate.d", "cell": Vector2i(2, 4)}

	var list_1 := [c_a, c_b, c_c, c_d]
	var list_2 := [c_d, c_c, c_b, c_a]
	var list_3 := [c_b, c_d, c_a, c_c]

	var rank_1 := adapter.rank_candidates(aim, actor, list_1)
	var rank_2 := adapter.rank_candidates(aim, actor, list_2)
	var rank_3 := adapter.rank_candidates(aim, actor, list_3)

	check(rank_1.size() == 4, "all 4 candidates ranked")
	check(rank_1[0] == "zerkov.loot.sawmill.crate.a", "closest to aim ranks first")
	check(rank_1[1] == "zerkov.loot.sawmill.crate.b", "second closest ranks second")
	check(rank_1 == rank_2, "ranking is order-independent (permutation 1 vs 2)")
	check(rank_1 == rank_3, "ranking is order-independent (permutation 1 vs 3)")

	# Explicit tie-break: same aim and actor distance, tie-break by marker_id
	var tie_1 := {"id": "zerkov.loot.sawmill.zebra", "cell": Vector2i(10, 10)}
	var tie_2 := {"id": "zerkov.loot.sawmill.alpha", "cell": Vector2i(10, 10)}
	var tie_ranked := adapter.rank_candidates(aim, actor, [tie_1, tie_2])
	check(tie_ranked[0] == "zerkov.loot.sawmill.alpha", "tie-break on equal distance uses marker_id total order")


func _test_interaction_intent_emission() -> void:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "test_raid"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"profile_cursor", &"player")

	var adapter := CursorAdapter.new()
	check(not adapter.is_configured(), "adapter initially unconfigured")
	check(adapter.build_interaction_intent(1, "zerkov.loot.crate") == null,
		"unconfigured adapter refuses intent build")

	check(adapter.configure(
		admission.session_id,
		admission.actor_id,
		admission.authority_epoch,
		admission.generation
	), "adapter configures with valid admission")

	var intent := adapter.build_interaction_intent(5, "zerkov.loot.sawmill.crate.log_racks")
	check(intent != null, "interaction intent built successfully")
	check(intent.source == ZRaidIntent.Source.PLAYER, "intent source is PLAYER")
	check(intent.kind == CursorAdapter.INTENT_KIND_INTERACTION, "intent kind is interaction")
	check(intent.target_tick == 5, "target tick preserved")
	check(intent.payload["target_id"] == "zerkov.loot.sawmill.crate.log_racks", "target_id in payload matches")

	# Test build_interaction_intent_from_aim
	var markers := [
		{"id": "zerkov.loot.crate.near", "cell": Vector2i(10, 10)},
		{"id": "zerkov.loot.crate.far", "cell": Vector2i(20, 20)},
	]
	# Screen center (960, 540) with camera at (320, 180) maps to world (320, 180) = tile (10, 5.6)
	var aim_intent := adapter.build_interaction_intent_from_aim(
		6,
		Vector2(960.0, 540.0),
		Vector2(320.0, 180.0),
		markers,
		Vector2(320.0, 180.0)
	)
	check(aim_intent != null, "aim-based interaction intent built")
	check(aim_intent.payload["target_id"] == "zerkov.loot.crate.near", "names closest target to aim")

	# Test pointer in matte returns null and records error
	var matte_intent := adapter.build_interaction_intent_from_aim(
		7,
		Vector2(-50.0, 500.0),
		Vector2(320.0, 180.0),
		markers
	)
	check(matte_intent == null, "pointer in matte rejects intent creation")
	check(adapter.last_error() == &"aim_outside_world_surface", "error recorded as aim_outside_world_surface")


func _test_adapter_holds_no_transform_authority() -> void:
	# Runs two identical 20-tick simulations:
	# Run A: pure simulation without camera adapter.
	# Run B: simulation alongside camera follow and cursor adapter reading pose every tick.
	# State digests must match bit-for-bit.
	var digest_a := _simulate_run(false)
	var digest_b := _simulate_run(true)

	check(not digest_a.is_empty(), "simulation A produces non-empty digest")
	check(digest_a == digest_b, "state_digest() is identical with and without camera adapter")


func _simulate_run(with_camera: bool) -> String:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "cam_auth_test"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"profile_cam", &"player")

	var authority := RaidAuthority.new()
	authority.configure(raid, admission, 101)
	var gen := authority.generation()

	var loco := Locomotion.new()
	loco.configure(admission.actor_id, Vector2(100.0, 100.0))
	loco.register_with_authority(authority, gen)
	authority.transition(RaidAuthority.Lifecycle.ACTIVE, gen)

	var move_adapter := IntentAdapter.new()
	move_adapter.configure(admission.session_id, admission.actor_id, admission.authority_epoch, gen)

	var cam: CameraFollow = null
	var cursor: CursorAdapter = null
	if with_camera:
		cam = CameraFollow.new()
		cam.configure(Rect2(0.0, 0.0, 1280.0, 640.0), Vector2(100.0, 100.0))
		cursor = CursorAdapter.new()
		cursor.configure(admission.session_id, admission.actor_id, admission.authority_epoch, gen)

	for t in range(1, 21):
		var intent := move_adapter.build_movement_intent(t, Vector2(1.0, 0.5), Vector2.ZERO, false, false)
		authority.enqueue_intent(intent, gen)
		authority.clock.step(1)
		authority.advance_one(gen)

		if with_camera:
			cam.follow_locomotion(loco)
			cursor.set_camera_position(cam.position_px)
			var _aim := cursor.screen_to_world(Vector2(960.0, 540.0))

	return authority.state_digest()
