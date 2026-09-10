extends StyleBox
## Square StyleBoxFlat adapter for fractionally scaled PC canvases.
## Compatibility has no 2D MSAA; subpixel border polygons can disappear.
## Keep layout margins unchanged and rasterize only the rim on output pixels.

var source: StyleBoxFlat
var _shadow: StyleBoxFlat

func configure(value: StyleBoxFlat) -> void:
	source = value
	source.changed.connect(_refresh)
	_refresh()

func _refresh() -> void:
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		set_content_margin(side, source.get_margin(side))
	_shadow = null
	if source.shadow_size > 0:
		_shadow = source.duplicate()
		_shadow.set_border_width_all(0)
		_shadow.draw_center = false
	emit_changed()

static func output_transform(item: CanvasItem) -> Transform2D:
	var viewport := item.get_viewport()
	# Snap within the render target, before the window adds letterbox offsets.
	return viewport.get_stretch_transform() * viewport.global_canvas_transform * item.get_global_transform_with_canvas()

static func snapped_rect(rect: Rect2) -> Rect2:
	var start := rect.position.round()
	return Rect2(start, rect.end.round() - start)

static func draw_hairline(item: CanvasItem, rect: Rect2, color: Color, clip: Rect2) -> void:
	var transform := output_transform(item)
	var bounds := snapped_rect(transform * clip)
	var pixels := snapped_rect(transform * rect)
	pixels.size = pixels.size.max(Vector2.ONE).min(bounds.size)
	pixels.position = pixels.position.clamp(bounds.position, bounds.end - pixels.size)
	RenderingServer.canvas_item_add_rect(item.get_canvas_item(), transform.affine_inverse() * pixels, color)

func _get_draw_rect(rect: Rect2) -> Rect2:
	return source.get_draw_rect(rect)

func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var item := get_current_item_drawn()
	if item == null:
		source.draw(to_canvas_item, rect)
		return
	var transform := output_transform(item)
	# Preserve the native style exactly at 1080p/upscales, and for rotated art.
	if (transform.x.x >= 1.0 and transform.y.y >= 1.0) or not is_zero_approx(transform.x.y) or not is_zero_approx(transform.y.x):
		source.draw(to_canvas_item, rect)
		return
	var outer := snapped_rect(transform * rect)
	if not outer.has_area():
		return
	var inverse := transform.affine_inverse()
	var left := _width(source.border_width_left, transform.x.x)
	var top := _width(source.border_width_top, transform.y.y)
	var right := _width(source.border_width_right, transform.x.x)
	var bottom := _width(source.border_width_bottom, transform.y.y)
	left = minf(left, outer.size.x)
	right = minf(right, outer.size.x - left)
	top = minf(top, outer.size.y)
	bottom = minf(bottom, outer.size.y - top)
	var inner := outer.grow_individual(-left, -top, -right, -bottom)
	if source.shadow_size > 0:
		_shadow.draw(to_canvas_item, inverse * outer)
	if source.draw_center and inner.has_area():
		RenderingServer.canvas_item_add_rect(to_canvas_item, inverse * inner, source.bg_color)
	if source.border_color.a <= 0.0:
		return
	# Non-overlapping strips preserve translucent border alpha at the corners.
	var strips := [
		Rect2(outer.position, Vector2(left, outer.size.y)),
		Rect2(Vector2(outer.end.x - right, outer.position.y), Vector2(right, outer.size.y)),
		Rect2(Vector2(inner.position.x, outer.position.y), Vector2(inner.size.x, top)),
		Rect2(Vector2(inner.position.x, outer.end.y - bottom), Vector2(inner.size.x, bottom)),
	]
	for strip in strips:
		if strip.has_area():
			RenderingServer.canvas_item_add_rect(to_canvas_item, inverse * strip, source.border_color)

func _width(logical: int, scale_factor: float) -> float:
	return maxf(1.0, roundf(logical * scale_factor)) if logical > 0 else 0.0
