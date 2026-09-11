extends SceneTree
## Native GPU evidence and regression harness for the exact first-playable output.
## Run without --headless.
const FIRST_PLAYABLE_SIZE := Vector2i(1920, 1080)

const Policy = preload("res://game/presentation/render_scale_spike/surface_policy.gd")
const Probe = preload("res://game/presentation/render_scale_spike/world_probe.gd")
const Tokens = preload("res://ui/theme/tokens.gd")
const CURRENT_OUTPUT := "res://docs/qa/render_scale/current_1080"

var checks := 0
var failures := 0
var records: Array[Dictionary] = []
var output := CURRENT_OUTPUT
var app: Control
var surface: SubViewport
var presenter: TextureRect
var camera: Camera2D
var caption: Label

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			output = argument.trim_prefix("--capture-dir=")
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("RENDER_SCALE: " + message)

func frame() -> Image:
	for i in range(4):
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func save_image(value: Image, name: String) -> void:
	check(value.save_png(output + "/" + name + ".png") == OK, "Save " + name)

func configure(policy: Dictionary) -> void:
	surface.size = policy.surface
	camera.zoom = Vector2.ONE * float(policy.zoom)
	camera.position = Vector2.ZERO
	presenter.position = Vector2(policy.rect.position)
	presenter.size = Vector2(policy.rect.size)
	camera.force_update_scroll()
	caption.text = "RENDER SCALE / %s / %dx%d / %.2fx" % [policy.candidate, policy.surface.x, policy.surface.y, policy.factor]

func stripe_widths(rendered: Image, policy: Dictionary) -> Array[int]:
	var start := Policy.world_to_output(Probe.STRIPES.position, Vector2.ZERO, policy)
	var end := Policy.world_to_output(Probe.STRIPES.end, Vector2.ZERO, policy)
	var y := int((start.y + end.y) * 0.5)
	var widths: Array[int] = []
	var previous := -1
	var width := 0
	for x in range(int(start.x), int(end.x)):
		var value := int(rendered.get_pixel(x, y).r > 0.5)
		if value != previous and width > 0:
			widths.append(width)
			width = 0
		previous = value
		width += 1
	widths.append(width)
	return widths

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Native graphical renderer required; headless captures are not evidence.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	surface = SubViewport.new()
	surface.disable_3d = true
	surface.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	surface.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	surface.snap_2d_transforms_to_pixel = true
	root.add_child(surface)
	surface.add_child(Probe.new())
	camera = Camera2D.new()
	camera.position_smoothing_enabled = false
	camera.rotation_smoothing_enabled = false
	surface.add_child(camera)
	presenter = TextureRect.new()
	presenter.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	presenter.texture = surface.get_texture()
	presenter.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	presenter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(presenter)
	app = load("res://ui/main.tscn").instantiate()
	app.initial_route = "hud"
	app.ui_layout_mode = "desktop"
	root.add_child(app)
	await frame()
	app.qa_mode = true
	check(app.current_route == "hud" and app.screen != null, "Existing HUD mounts")
	# Only the test instance substitutes its backdrop. Production assets/scenes
	# remain untouched. Freeze fixture animation so UI hashes are meaningful.
	app.screen.get_node("BackgroundFrame").hide()
	app.screen.get_node("Atmosphere").hide()
	app.screen.process_mode = Node.PROCESS_MODE_DISABLED
	caption = Label.new()
	caption.position = Vector2(56, 132)
	caption.add_theme_font_override("font", load("res://assets/fonts/IBMPlexMono-Regular.ttf"))
	caption.add_theme_font_size_override("font_size", 14)
	caption.add_theme_color_override("font_color", Tokens.TEXT)
	caption.add_theme_color_override("font_shadow_color", Tokens.BG)
	caption.add_theme_constant_override("shadow_outline_size", 2)
	root.add_child(caption)
	for dimensions in [FIRST_PLAYABLE_SIZE]:
		# Render an exact-size native GPU framebuffer. This never resizes PNGs
		# after capture; only the world passes through the small SubViewport.
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		root.content_scale_size = dimensions
		app.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		app.size = Vector2(1920, 1080)
		app.scale = Vector2(dimensions) / Vector2(1920, 1080)
		caption.scale = app.scale
		caption.position = Vector2(56, 132) * app.scale
		await frame()
		Input.warp_mouse(Vector2(8, 8))
		var hud_reference := PackedByteArray()
		for candidate in Policy.CANDIDATES:
			var policy: Dictionary = Policy.layout(candidate, dimensions)
			configure(policy)
			var rendered := await frame()
			check(rendered.get_size() == dimensions, "Native output dimensions")
			var key := "%dx%d_%s" % [dimensions.x, dimensions.y, candidate]
			save_image(rendered, key)
			var widths := stripe_widths(rendered, policy)
			var unique: Array[int] = []
			for width in widths:
				if width not in unique:
					unique.append(width)
			unique.sort()
			if candidate in ["640_integer", "adaptive_integer"]:
				check(widths.size() == 64 and unique.size() == 1 and unique[0] == int(policy.factor), key + " uniform source pixel widths")
			if candidate == "320_fixed":
				check(widths.size() < 64, "320 negative control demonstrates source detail loss")
			# Render the actual existing UI alone against a constant backdrop and
			# require byte identity across candidates and camera impulses.
			presenter.hide()
			caption.hide()
			var hud := await frame()
			if hud_reference.is_empty():
				hud_reference = hud.get_data()
				save_image(hud, "%dx%d_hud_only" % [dimensions.x, dimensions.y])
			check(hud.get_data() == hud_reference, key + " HUD byte identity")
			presenter.show()
			caption.show()
			var camera_error := 0.0
			var pointer_error := 0.0
			for step in range(33):
				var desired := Vector2(step * 0.125, step * -0.0625)
				var snapped := Policy.snap_camera(desired, policy.zoom)
				camera_error = maxf(camera_error, maxf(absf(desired.x - snapped.x), absf(desired.y - snapped.y)) * policy.zoom)
				for point in [Vector2.ZERO, Vector2(-100, 64), Vector2(200, -80)]:
					var mapped: Vector2 = Policy.world_to_output(point, snapped, policy)
					var restored: Dictionary = Policy.output_to_world(mapped, snapped, policy)
					check(restored.accepted, "Inside pointer accepted")
					pointer_error = maxf(pointer_error, point.distance_to(restored.world))
			check(camera_error <= 0.50001, key + " camera rounding bounded by half raster pixel")
			check(pointer_error < 0.0001, key + " pointer inverse round trip")
			check(not Policy.output_to_world(Vector2(policy.rect.end), Vector2.ZERO, policy).accepted, "Outside right/bottom rejected")
			if candidate == "640_integer":
				# Actual GPU temporal checks: subpixel motion holds the frame, then
				# advances exactly one source pixel. Save world-only pan/impulse frames.
				app.hide()
				caption.hide()
				camera.position = Vector2.ZERO
				camera.force_update_scroll()
				var still := await frame()
				save_image(still, key + "_pan_000")
				camera.position = Policy.snap_camera(Vector2(0.49, 0.49), 1.0)
				camera.force_update_scroll()
				var hold := await frame()
				check(still.get_data() == hold.get_data(), key + " subpixel pan has zero changed pixels")
				camera.position = Policy.snap_camera(Vector2(0.51, 0.0), 1.0)
				camera.force_update_scroll()
				var pan := await frame()
				save_image(pan, key + "_pan_051")
				var crop := Rect2i(policy.rect.position + Vector2i(24, 24), policy.rect.size - Vector2i(64, 64))
				check(still.get_region(Rect2i(crop.position + Vector2i(int(policy.factor), 0), crop.size)).get_data() == pan.get_region(crop).get_data(), key + " one source pixel pan is exact integer output shift")
				camera.position = Policy.snap_camera(Vector2(3.6, -2.2), 1.0)
				camera.force_update_scroll()
				app.show()
				var shake := await frame()
				save_image(shake, key + "_impulse")
				presenter.hide()
				var shaken_hud := await frame()
				check(shaken_hud.get_data() == hud_reference, key + " camera impulse cannot alter HUD pixels")
				presenter.show()
				caption.show()
			records.append({"key": key, "surface": [policy.surface.x, policy.surface.y], "zoom": policy.zoom, "scale": policy.factor, "display_rect": [policy.rect.position.x, policy.rect.position.y, policy.rect.size.x, policy.rect.size.y], "stripe_runs": widths.size(), "stripe_widths": unique, "max_camera_error_raster_px": camera_error, "max_pointer_error_world_px": pointer_error})
	var report := {"engine": Engine.get_version_info(), "display": DisplayServer.get_name(), "checks": checks, "failures": failures, "records": records, "human_approval": false}
	var file := FileAccess.open(output + "/metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("RENDER_SCALE_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
