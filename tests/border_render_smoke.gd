extends SceneTree
## GPU regression: run without --headless. Check pixels, not only node bounds.
const PixelStyle = preload("res://ui/theme/pixel_style.gd")
const Grid = preload("res://ui/screens/character/components/inventory_grid.gd")

var app: Control
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("BORDER_RENDER_TEST: " + message)

func frame_image() -> Image:
	for frame in range(4):
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func bounds(control: Control) -> Rect2i:
	return Rect2i(PixelStyle.snapped_rect(PixelStyle.output_transform(control) * Rect2(Vector2.ZERO, control.size)))

func delta(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))

func edge_visible(before: Image, after: Image, rect: Rect2i, side: int) -> bool:
	var hits := 0
	var samples := 0
	var vertical := side == SIDE_LEFT or side == SIDE_RIGHT
	var length := rect.size.y if vertical else rect.size.x
	for offset in range(4, length - 4):
		var point := rect.position
		if vertical:
			point += Vector2i(0 if side == SIDE_LEFT else rect.size.x - 1, offset)
		else:
			point += Vector2i(offset, 0 if side == SIDE_TOP else rect.size.y - 1)
		hits += int(delta(before.get_pixelv(point), after.get_pixelv(point)) > 0.025)
		samples += 1
	return samples > 0 and float(hits) / samples > 0.95

func check_inventory(dimensions: Vector2i) -> void:
	app.navigate("inventory", false)
	Input.warp_mouse(Vector2(10, dimensions.y - 10))
	var before := await frame_image()
	var targets: Array[Button] = []
	for button in app.screen.find_children("*", "Button", true, false):
		if button.text == "ESC · CLOSE":
			targets.append(button)
	for label in app.screen.find_children("*", "Label", true, false):
		if label.text in ["ON SLING", "ON BACK", "LEG STRAP", "HOLSTER"]:
			targets.append(label.get_parent())
	check(targets.size() == 5, "Found Close and all four gear weapon slots")
	var colors := {}
	for button in targets:
		var style: StyleBox = button.get_theme_stylebox("normal")
		var source: StyleBoxFlat = style.source if style is PixelStyle else style
		colors[source] = source.border_color
		source.border_color = Color.TRANSPARENT
	var after := await frame_image()
	for button in targets:
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			check(edge_visible(before, after, bounds(button), side), "%s %s side %d is continuously visible" % [dimensions, button.get_path(), side])
	for source in colors:
		source.border_color = colors[source]

func check_clipped_grid(dimensions: Vector2i) -> void:
	# An empty grid with an exact-size clipping parent catches outer-edge loss.
	app.screen.hide()
	var clip := Control.new()
	clip.position = Vector2(91, 79)
	clip.size = Vector2(148, 148)
	clip.clip_contents = true
	app.add_child(clip)
	var grid := Grid.new()
	grid.set_grid_size(2, 2)
	clip.add_child(grid)
	var rendered := await frame_image()
	var rect := bounds(grid)
	var fill := rendered.get_pixelv(rect.position + Vector2i(5, 5))
	# Compare against a solid fill of the same color, avoiding art/background noise.
	var blank := Image.create(rendered.get_width(), rendered.get_height(), false, Image.FORMAT_RGBA8)
	blank.fill(fill)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		check(edge_visible(rendered, blank, rect, side), "%s clipped grid perimeter %d visible" % [dimensions, side])
	var center: Vector2i = (PixelStyle.output_transform(grid) * Vector2(74, 74)).round()
	check(delta(rendered.get_pixel(center.x, rect.position.y + 10), fill) > 0.025, "%s grid column divider visible" % dimensions)
	check(delta(rendered.get_pixel(rect.position.x + 10, center.y), fill) > 0.025, "%s grid row divider visible" % dimensions)
	clip.queue_free()
	app.screen.show()
	await process_frame

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Border pixel regression requires a graphical renderer.")
		quit(1)
		return
	app = load("res://ui/main.tscn").instantiate()
	app.ui_layout_mode = "desktop"
	root.add_child(app)
	# Keep the test's explicitly mounted screen while resizing between captures.
	app.qa_mode = true
	for dimensions in [Vector2i(1920, 1080), Vector2i(1600, 900), Vector2i(1366, 768), Vector2i(1280, 720), Vector2i(1440, 900)]:
		root.size = dimensions
		await create_timer(0.25).timeout
		await check_inventory(dimensions)
		await check_clipped_grid(dimensions)
	print("BORDER_RENDER_TEST_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
