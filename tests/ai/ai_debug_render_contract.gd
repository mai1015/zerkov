extends SceneTree
## Synthetic AI diagnostics only, not a Sawmill encounter or performance claim.
## Genuine 1920x1080 output with the approved 640x360 world at exact nearest 3x.

func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var failures: int = 0
	var checks: int = 0
	var capture: String = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			capture = argument.trim_prefix("--capture=")
	if DisplayServer.get_name() == "headless":
		print("AI_DEBUG_RENDER_BLOCKED graphical_renderer_required")
		quit(2)
		return
	root.borderless = true
	root.size = Vector2i(1920, 1080)
	await process_frame
	if root.size != Vector2i(1920, 1080) or root.get_visible_rect().size != Vector2(1920, 1080):
		push_error("AI debug requires exact 1920x1080 before constructing the scene")
		quit(2)
		return
	var background := ColorRect.new()
	background.color = Color(0.04, 0.055, 0.08)
	background.size = Vector2(1920, 1080)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	var world := SubViewport.new()
	world.size = Vector2i(640, 360)
	world.transparent_bg = true
	world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(world)
	var image_rect := TextureRect.new()
	image_rect.texture = world.get_texture()
	image_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	image_rect.size = Vector2(1920, 1080)
	image_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(image_rect)
	var overlay := load("res://game/ai/debug/ai_debug_overlay.tscn").instantiate() as ZAIDebugOverlay
	world.add_child(overlay)
	checks += 1
	if overlay.visible: failures += 1
	var brain := ZAIAgent.new()
	var fixture := preload("res://tests/ai/fixtures/ai_test_fixtures.gd")
	brain.configure(1, fixture.SCAV, ZAIProfile.scav(), 17)
	brain.step(1, 1, fixture.own(fixture.SCAV, Vector2i(4_000_000, 5_000_000)),
		fixture.knowledge(fixture.SCAV, 1, [fixture.fact(fixture.PLAYER, 1, Vector2i(12_000_000, 6_000_000))]))
	brain.step(1, 4, fixture.own(fixture.SCAV, Vector2i(4_000_000, 5_000_000)), fixture.knowledge(fixture.SCAV, 4))
	var entry := brain.debug_snapshot().duplicate(true)
	entry.merge({"observer_position_raw": Vector2i(4_000_000, 5_000_000), "observer_facing_raw": Vector2i(1_000_000, 0),
		"archetype": "scav", "perception": ZAIProfile.scav().perception_record(), "vision": {"state": "remembered", "completed_tick": 4, "fresh": true}, "path": [Vector2i(6_000_000, 5_000_000), Vector2i(8_000_000, 7_000_000), Vector2i(12_000_000, 6_000_000)]}, true)
	var before := brain.debug_snapshot()
	var frame := {"diagnostic_only": true, "tick": 4, "agents": [entry],
		"budget": {"decisions": 1, "deferred": 0, "decision_budget": 8},
		"vision_budget": {"consumed": 240, "budget": 16384, "deferred": 0}}
	checks += 1
	if not overlay.publish(frame): failures += 1
	overlay.diagnostics_enabled = true
	checks += 1
	if not overlay.visible: failures += 1
	checks += 1
	if overlay.publish({"diagnostic_only": false, "agents": [], "budget": {}}): failures += 1
	checks += 1
	if before != brain.debug_snapshot(): failures += 1
	var label := Label.new()
	label.position = Vector2(40, 35)
	label.add_theme_font_size_override("font_size", 26)
	label.text = "ZERKOV / AI DIAGNOSTIC FIXTURE\n" + overlay.summary() + "\nBlue: observer/cone    Green: path    Amber: historical observation\nNOT a native Vision or integrated gameplay acceptance capture"
	root.add_child(label)
	for _index in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	checks += 1
	if image.get_size() != Vector2i(1920, 1080) or root.size != Vector2i(1920, 1080): failures += 1
	checks += 1
	if image.is_empty(): failures += 1
	if failures == 0 and not capture.is_empty():
		var absolute := ProjectSettings.globalize_path(capture)
		DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
		checks += 1
		if image.save_png(absolute) != OK: failures += 1
	print("AI_DEBUG_RENDER_RESULT checks=", checks, " failures=", failures, " output=1920x1080 world=640x360")
	quit(0 if failures == 0 else 1)
