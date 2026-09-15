extends RefCounted
## Invoked by the existing registered 1080 capture driver, not another runner.
const Pose = preload("res://game/presentation/northline_zone/review_locomotion_pose.gd")

func run(view: Control, check: Callable) -> void:
	_test_source_facing(view, check)
	var pose = Pose.new()
	check.call(pose.advance(8.8, 0.1) and pose.moving and pose.frame == 1, "distance-driven first step")
	pose.advance(8.8, 0.1)
	check.call(pose.frame == 2, "distance-driven next step")
	pose.advance(0.0, 1.0/60.0)
	check.call(not pose.moving and pose.frame == 0, "blocked body resets to idle")
	pose.advance(0.0, 0.2)
	check.call(pose.frame == 1, "independent idle phase")
	pose.advance(4.4, 1.0/60.0)
	check.call(pose.moving and pose.frame == 0, "walk transition starts fresh phase")
	var a = Pose.new()
	var b = Pose.new()
	for i: int in range(6):
		a.advance(4.4, 0.05)
	for i: int in range(3):
		b.advance(8.8, 0.1)
	check.call(a.frame == b.frame and is_equal_approx(a.distance_phase, b.distance_phase), "frame rate independent distance phase")
	var slow = Pose.new()
	var fast = Pose.new()
	slow.advance(8.8, 0.1)
	fast.advance(17.6, 0.1)
	check.call(fast.frame > slow.frame, "sprint cadence follows resolved distance")
	var before: Dictionary = pose.snapshot()
	for bad: Vector2 in [Vector2(-1,0.1), Vector2(1,-1), Vector2(INF,0.1), Vector2(1,NAN), Vector2(1,2)]:
		check.call(not pose.advance(bad.x, bad.y) and pose.snapshot() == before, "invalid pose sample is mutation-free")
	pose.reset()
	check.call(pose.frame == 0 and not pose.moving, "explicit pose reset")
	var effect = view.world.polish
	var solids: int = view.world.get_node("AuthoredLayoutCollision").get_child_count()
	var props: int = view.world.props_root.get_child_count()
	var original_data := JSON.stringify(view.data)
	check.call(effect._plants.size() > 0 and effect._plants.size() <= 48, "actual source vegetation with fixed budget")
	check.call(effect._lamps.size() == 4 and effect._walls.get_child_count() > 10, "shadowed lamps and authored blockers")
	for lamp: PointLight2D in effect._lamps:
		check.call(lamp.shadow_enabled and lamp.shadow_item_cull_mask == 2, "local shadow masks enabled")
	for lamp: PointLight2D in effect._lamps:
		check.call(lamp.energy <= float(lamp.get_meta("base_energy")), "bounded lamp variation")
	check.call(effect.freeze_at(3.0), "freeze all ambient effects at known time")
	var frozen_state: Dictionary = effect.diagnostic_snapshot()
	effect._process(0.5)
	check.call(effect.diagnostic_snapshot() == frozen_state, "freeze stops presentation clock")
	check.call(not effect.freeze_at(NAN) and not effect.sample_at(-1.0) and effect.diagnostic_snapshot() == frozen_state, "invalid visual clock rejected")
	effect.set_reduced_motion(true)
	check.call(effect._wind.get_shader_parameter("strength") == 0.0, "reduced motion fixes vegetation roots and canopy")
	var reduced: float = effect.seconds
	effect.frozen = false
	effect._process(0.5)
	check.call(effect.seconds == reduced, "reduced motion stops ambience advancement")
	effect.set_reduced_motion(false)
	effect.update_camera(Rect2(0,0,640,360), false)
	effect._process(0.5)
	check.call(effect.seconds == reduced, "offscreen ambience is suspended")
	effect.update_camera(Rect2(864,470,640,360), true)
	check.call(not effect.active, "overview disables local effect lights")
	effect.update_camera(Rect2(864,470,640,360), false)
	effect._process(0.5)
	check.call(effect.seconds > reduced, "visible ambience resumes")
	var count: int = effect.get_child_count()
	for i: int in range(10):
		effect.set_enabled(false)
		effect.set_enabled(true)
		effect.sample_at(float(i))
	check.call(effect.get_child_count() == count, "toggles and sampling do not allocate nodes")
	check.call(view.world.props_root.get_child_count() == props and view.world.get_node("AuthoredLayoutCollision").get_child_count() == solids, "polish preserves native collision and authored props")
	check.call(JSON.stringify(view.data) == original_data, "polish cannot mutate map data")
	effect.freeze_at(3.0)
	effect.update_camera(Rect2(view.camera.position - Vector2(320,180),Vector2(640,360)),view.overview)


func _test_source_facing(view: Control, check: Callable) -> void:
	# Visually verified against the original source sheets: the unmirrored
	# gas-mask/hoodie artwork faces LEFT. Do not derive the expected flip from
	# the implementation constant; doing so would repeat the original mistake.
	var walker = view.walker
	var saved_facing: bool = walker.face_left
	var saved_region: Rect2 = walker.layers[0].region_rect
	var saved_position: Vector2 = walker.position
	var saved_velocity: Vector2 = walker.velocity
	var saved_pose: Dictionary = walker.pose.snapshot()
	for left: bool in [true, false]:
		walker.face_left = left
		for moving: bool in [false, true]:
			for frame: int in range(6):
				walker.show_frame(moving, frame)
				var aligned: bool = true
				for row: int in range(walker.layers.size()):
					var layer: Sprite2D = walker.layers[row]
					aligned = aligned and layer.flip_h == (not left)
					aligned = aligned and layer.region_rect == Rect2(frame * 64, (row + (4 if moving else 0)) * 64, 64, 64)
				check.call(aligned, "source-left art: all layers face " + ("left" if left else "right") + " in " + ("walk" if moving else "idle") + " frame " + str(frame))
	# Turning the visual must not reverse frame order or mutate physics/gait.
	check.call(walker.position == saved_position and walker.velocity == saved_velocity, "facing render does not alter physics")
	check.call(walker.pose.snapshot() == saved_pose, "facing render does not alter gait phase")
	walker.face_left = saved_facing
	walker.show_frame(saved_region.position.y >= 256.0, int(saved_region.position.x / 64.0))
