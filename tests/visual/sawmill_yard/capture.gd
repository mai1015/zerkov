extends SceneTree
## Native Task 3.4 evidence only. World pixels come exclusively from the
## accepted TileSet; labels/chrome are test-only crisp output-space Controls.
## No player controller, authority, AI, inventory, task or extract runtime.

const EXACT_SIZE := Vector2i(1920, 1080)
const Output = preload("res://tests/visual/sawmill_yard/exact_output.gd")
const YardScene = preload("res://game/world/sawmill/sawmill_yard.tscn")
const Tokens = preload("res://ui/theme/tokens.gd")
const FONT = preload("res://assets/fonts/IBMPlexMono-Regular.ttf")
const HEADING = preload("res://assets/fonts/ChakraPetch-SemiBold.ttf")
const OUTPUT := "res://docs/qa/sawmill_layout/implementation"

var checks := 0
var failures := 0
var records: Array[Dictionary] = []
var surface: SubViewport
var output_target: SubViewport
var desktop_preview: TextureRect
var presenter: TextureRect
var camera: Camera2D
var yard: ZSawmillYard
var chrome: Control
var annotations: Control
var title: Label
var note: Label


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SAWMILL_CAPTURE: " + message)


func run() -> void:
	if not Output.overrides_are_exact(OS.get_cmdline_args()) or not Output.overrides_are_exact(OS.get_cmdline_user_args()):
		push_error("SAWMILL_CAPTURE: nonexact or ambiguous output override rejected")
		quit(2)
		return
	if DisplayServer.get_name() == "headless":
		push_error("SAWMILL_CAPTURE: a native graphical renderer is required")
		quit(2)
		return
	# Custom SceneTree scripts have a dummy root until configured here. The
	# external driver validates --resolution 1920x1080 before launch. Explicit
	# viewport mode prevents macOS
	# backing-scale changes from silently changing the evidence framebuffer.
	root.borderless = true
	root.unresizable = true
	root.position = Vector2i.ZERO
	root.size = EXACT_SIZE
	root.content_scale_size = EXACT_SIZE
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	await process_frame
	await process_frame
	check(Output.accepts_window(root) and root.content_scale_size == EXACT_SIZE, "native GPU root/output target exact 1920x1080")
	if failures > 0:
		quit(1)
		return
	_build_world()
	_build_chrome()
	var chrome_reference := PackedByteArray()
	for view in yard.layout.review_views:
		camera.position = Vector2(view.camera_px).round()
		camera.force_update_scroll()
		check(camera.position == view.camera_px, "authored camera is integral " + view.id)
		check(camera.zoom == Vector2.ONE and camera.rotation == 0.0 and not camera.position_smoothing_enabled, "selected static camera policy")
		chrome.hide()
		annotations.hide()
		var world_frame := await frame()
		var source := surface.get_texture().get_image()
		check(source.get_size() == Output.WORLD_SIZE, "only internal world surface is 640x360")
		# Compare every native output pixel to an exact nearest 3x enlargement
		# in memory. No source-size or other-size image is written to disk.
		source.resize(EXACT_SIZE.x, EXACT_SIZE.y, Image.INTERPOLATE_NEAREST)
		source.convert(Image.FORMAT_RGB8)
		world_frame.convert(Image.FORMAT_RGB8)
		check(world_frame.get_data() == source.get_data(), "all world pixels are exact nearest 3x " + view.id)
		presenter.hide()
		chrome.show()
		title.text = ""
		note.text = ""
		var chrome_only := await frame()
		if chrome_reference.is_empty():
			chrome_reference = chrome_only.get_data()
		check(chrome_only.get_data() == chrome_reference, "crisp chrome unaffected by world camera " + view.id)
		presenter.show()
		title.text = view.title
		note.text = view.note
		_label_anchors()
		annotations.show()
		var rendered := await frame()
		if not _exact_frame(rendered):
			push_error("SAWMILL_CAPTURE: output mismatch; no path or image will be written")
			quit(2)
			return
		var filename := "1920x1080_" + String(view.id) + ".png"
		check(_exact_frame(rendered), "exact native image immediately before save " + filename)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
		check(rendered.save_png(OUTPUT + "/" + filename) == OK, "save " + filename)
		records.append({
			"file": filename, "dimensions": [1920, 1080],
			"sha256": FileAccess.get_sha256(OUTPUT + "/" + filename),
			"camera_px": [camera.position.x, camera.position.y],
			"world_surface": [640, 360], "world_scale": 3,
			"camera_zoom": [1, 1], "title": view.title,
			"world_pixel_match": world_frame.get_data() == source.get_data(),
			"annotation_scope": "capture-only; no gameplay UI or task state",
		})
	await _test_camera_rounding()
	var contact_sheet := await _capture_contact_sheet()
	var report := {
		"task": "3.4", "engine": Engine.get_version_info(),
		"display": DisplayServer.get_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"checks": checks, "failures": failures, "captures": records,
		"contact_sheet": contact_sheet,
		"output_target": [1920, 1080],
		"host_window_size": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"host_window_note": "OS-clamped preview only; never read or saved as evidence. The exact GPU root target is captured.",
		"human_approval": false, "independent_acceptance": false,
	}
	var file := FileAccess.open(OUTPUT + "/captures.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("SAWMILL_CAPTURE_RESULT checks=", checks, " failures=", failures, " captures=", records.size(), " output=1920x1080 world=640x360 scale=3 human_approval=false")
	desktop_preview.texture = null
	desktop_preview.free()
	presenter.texture = null
	presenter.free()
	chrome.free()
	annotations.free()
	surface.free()
	output_target.free()
	yard = null
	camera = null
	await process_frame
	quit(0 if failures == 0 else 1)


func _build_world() -> void:
	# Native GPU composition target. The OS may clamp its desktop preview,
	# so evidence is read exclusively from this exact output target.
	output_target = SubViewport.new()
	output_target.name = "Exact1920x1080Output"
	output_target.size = EXACT_SIZE
	output_target.disable_3d = true
	output_target.world_2d = World2D.new()
	output_target.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(output_target)
	desktop_preview = TextureRect.new()
	desktop_preview.texture = output_target.get_texture()
	desktop_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	desktop_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	desktop_preview.size = Vector2(EXACT_SIZE)
	root.add_child(desktop_preview)
	surface = SubViewport.new()
	surface.name = "FixedWorldSurface640x360"
	surface.size = Output.WORLD_SIZE
	surface.disable_3d = true
	surface.world_2d = World2D.new()
	surface.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	surface.snap_2d_transforms_to_pixel = true
	surface.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	output_target.add_child(surface)
	yard = YardScene.instantiate() as ZSawmillYard
	surface.add_child(yard)
	camera = Camera2D.new()
	camera.position_smoothing_enabled = false
	camera.rotation_smoothing_enabled = false
	camera.zoom = Vector2.ONE
	surface.add_child(camera)
	presenter = TextureRect.new()
	presenter.name = "Exact3xWorldPresentation"
	presenter.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	presenter.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	presenter.texture = surface.get_texture()
	presenter.size = Vector2(EXACT_SIZE)
	presenter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	output_target.add_child(presenter)


func _build_chrome() -> void:
	chrome = Control.new()
	chrome.name = "CrispCaptureChrome1920x1080"
	chrome.size = Vector2(EXACT_SIZE)
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	output_target.add_child(chrome)
	_panel(chrome, Vector2.ZERO, Vector2(1920, 112))
	_panel(chrome, Vector2(0, 976), Vector2(1920, 104))
	_label(chrome, "SAWMILL YARD / GREYBOX", Vector2(40, 24), 28, Tokens.TEXT, true)
	title = _label(chrome, "", Vector2(40, 68), 18, Tokens.ACCENT)
	_label(chrome, "TASK 3.4 / AUTHORING REVIEW", Vector2(1440, 28), 16, Tokens.SOFT)
	_label(chrome, "1920x1080 / 640x360 WORLD @ 3x", Vector2(1440, 60), 14, Tokens.MUTED)
	note = _label(chrome, "", Vector2(40, 992), 16, Tokens.TEXT)
	_label(chrome, "32px PROJECT-OWNED TILESET  |  MARKER GLYPHS ARE GREYBOX PROXIES  |  HUMAN APPROVAL: FALSE", Vector2(40, 1032), 14, Tokens.MUTED)
	annotations = Control.new()
	annotations.name = "CrispAnchorAnnotations"
	annotations.size = Vector2(EXACT_SIZE)
	annotations.mouse_filter = Control.MOUSE_FILTER_IGNORE
	output_target.add_child(annotations)


func _label_anchors() -> void:
	for child in annotations.get_children():
		child.free()
	for row in yard.layout.anchors:
		if row.kind == "encounter":
			continue
		var point := (yard.layout.cell_center(row.cell) - camera.position + Vector2(Output.WORLD_SIZE) / 2.0) * Output.WORLD_SCALE
		if not Rect2(64, 144, 1792, 768).has_point(point):
			continue
		var label_point := point + Vector2(row.label_offset_px)
		if label_point.y < 144:
			label_point.y = point.y + 68
		label_point.x = clampf(label_point.x, 40, 1504)
		label_point.y = minf(label_point.y, 920)
		var color: Color = Tokens.ACCENT if row.kind in ["objective_crate", "loot", "extract"] else Tokens.TEXT
		_label(annotations, row.name, label_point, 18, color)


func _panel(parent: Control, position_px: Vector2, size_px: Vector2) -> void:
	var panel := ColorRect.new()
	panel.color = Tokens.DARK
	panel.position = position_px
	panel.size = size_px
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)


func _label(parent: Control, text: String, position_px: Vector2, font_size: int, color: Color, heading: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.position = position_px
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", HEADING if heading else FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Tokens.BG)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.add_theme_constant_override("shadow_outline_size", 2)
	parent.add_child(label)
	return label


func frame() -> Image:
	for _index in range(4):
		await process_frame
	RenderingServer.force_draw(true)
	var rendered := output_target.get_texture().get_image()
	check(_exact_frame(rendered), "native GPU root target and framebuffer remain exactly 1920x1080")
	return rendered


func _exact_frame(rendered: Image) -> bool:
	return output_target.size == EXACT_SIZE and output_target.get_visible_rect().size == Vector2(EXACT_SIZE) and surface.size == Output.WORLD_SIZE and presenter.size == Vector2(EXACT_SIZE) and rendered.get_size() == EXACT_SIZE


func _test_camera_rounding() -> void:
	chrome.hide()
	annotations.hide()
	camera.position = Vector2(320, 180)
	camera.force_update_scroll()
	var before := await frame()
	camera.position = Vector2(320.49, 180.49).round()
	camera.force_update_scroll()
	var held := await frame()
	check(before.get_data() == held.get_data(), "fractional camera desire holds until rounding boundary")
	camera.position = Vector2(320.51, 180.0).round()
	camera.force_update_scroll()
	var moved := await frame()
	var crop := Rect2i(24, 24, 1848, 1008)
	check(before.get_region(Rect2i(crop.position + Vector2i(3, 0), crop.size)).get_data() == moved.get_region(crop).get_data(), "one source pixel camera pan moves world exactly three output pixels")


func _capture_contact_sheet() -> Dictionary:
	presenter.hide()
	chrome.hide()
	annotations.hide()
	var sheet := Control.new()
	sheet.size = Vector2(EXACT_SIZE)
	output_target.add_child(sheet)
	var background := ColorRect.new()
	background.size = Vector2(EXACT_SIZE)
	background.color = Tokens.BG
	sheet.add_child(background)
	_label(sheet, "SAWMILL YARD / COMPOSITION REVIEW", Vector2(24, 24), 28, Tokens.TEXT, true)
	_label(sheet, "SIX NATIVE 1920x1080 VIEWS / THUMBNAILS ONLY / OPEN ORIGINALS FOR EXACT 3x PIXELS", Vector2(24, 68), 16, Tokens.MUTED)
	for index in records.size():
		var record := records[index]
		var image := Image.load_from_file(OUTPUT + "/" + record.file)
		check(image.get_size() == EXACT_SIZE, "contact source is an original exact-1920 capture")
		if image.get_size() != EXACT_SIZE:
			sheet.free()
			quit(2)
			return {}
		var origin := Vector2(24 + (index % 3) * 632, 144 + (index / 3) * 408)
		_label(sheet, record.title, origin - Vector2(0, 32), 16, Tokens.ACCENT)
		var thumbnail := TextureRect.new()
		thumbnail.texture = ImageTexture.create_from_image(image)
		thumbnail.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumbnail.position = origin
		thumbnail.size = Vector2(608, 342)
		sheet.add_child(thumbnail)
	_label(sheet, "WEST SERVICE -> LOG RACKS -> SAW HOUSE -> SETTLING DOCK -> ROAD GATE", Vector2(24, 936), 22, Tokens.TEXT, true)
	_label(sheet, "Direct haul lane + southern bypass / four authored 96px clear corridors / nine stable anchors", Vector2(24, 980), 16, Tokens.SOFT)
	_label(sheet, "Composition evidence only. No movement, AI, search, task, countdown or human playtest acceptance.", Vector2(24, 1020), 16, Tokens.MUTED)
	var rendered := await frame()
	if not _exact_frame(rendered):
		sheet.free()
		push_error("SAWMILL_CAPTURE: contact sheet output mismatch; no write")
		quit(2)
		return {}
	var filename := "1920x1080_contact_sheet.png"
	check(rendered.save_png(OUTPUT + "/" + filename) == OK, "save exact-1920 native GPU contact sheet")
	var record := {"file": filename, "dimensions": [1920, 1080], "sha256": FileAccess.get_sha256(OUTPUT + "/" + filename), "kind": "labeled native GPU montage; thumbnails are not gameplay output"}
	sheet.free()
	return record
