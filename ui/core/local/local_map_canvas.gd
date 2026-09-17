class_name LocalMapCanvas
extends Control
## Authored static geometry plus public task/exit markers and the local actor.
## Enemy transforms never enter this presentation surface.
const Style = preload("res://ui/theme/local_journey_style.gd")
var _layout: ZSawmillYardLayout
var _markers: Array[MapView.Marker] = []
var _view: MapView
var _geometry: Array = []
var _native: bool = false
var _extent := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_layout = load("res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	queue_redraw()

func present(view: MapView, geometry: Array = [], native: bool = false, extent := Vector2.ZERO) -> void:
	if view == _view and is_same(geometry, _geometry) and native == _native and extent == _extent: return
	_view = view
	_geometry = geometry
	_native = native
	_extent = extent
	_markers = view.markers() if view != null and view.is_ready() else []
	queue_redraw()

func _draw() -> void:
	if _layout == null: return
	var box := Rect2(Vector2(24, 24), size - Vector2(48, 48))
	var extent := _extent if _native else Vector2(_layout.size_cells)
	if extent.x <= 0 or extent.y <= 0: return
	# Keep world proportions: the map is a tactical projection, not stretched art.
	var scale_factor := minf(box.size.x / extent.x, box.size.y / extent.y)
	var world_size := extent * scale_factor
	box = Rect2(box.position + (box.size - world_size) * 0.5, world_size)
	draw_rect(box, Color("10191a"))
	var grid_step := 128 if _native else 4
	for cell in range(0, int(extent.x) + 1, grid_step):
		var x := box.position.x + cell * scale_factor
		draw_line(Vector2(x, box.position.y), Vector2(x, box.end.y), Color("21302e"), 1)
	for cell in range(0, int(extent.y) + 1, grid_step):
		var y := box.position.y + cell * scale_factor
		draw_line(Vector2(box.position.x, y), Vector2(box.end.x, y), Color("21302e"), 1)
	if _native:
		for row: Dictionary in _geometry:
			var color := Color("37556b") if row.water else Color("586660")
			if row.has("rect"):
				var rect: Rect2 = row.rect
				var shape := Rect2(box.position + rect.position * box.size, rect.size * box.size)
				draw_rect(shape, color)
				if not row.water: draw_rect(shape, Color("839084"), false, 1)
			elif row.has("polygon"):
				var points := PackedVector2Array()
				for at: Vector2 in row.polygon: points.append(box.position + at * box.size)
				draw_colored_polygon(points, color)
	else:
		for row: Dictionary in _layout.structures:
			var rect: Rect2i = row.rect
			var shape := Rect2(box.position + Vector2(rect.position) * scale_factor, Vector2(rect.size) * scale_factor)
			draw_rect(shape, Color("586660") if row.layer == "Obstacles" else Color("263a32"))
			if row.layer == "Obstacles": draw_rect(shape, Color("839084"), false, 1)
	draw_rect(box, Style.LINE, false, 1)
	var labels: Array[Rect2] = []
	for marker: MapView.Marker in _markers:
		if not marker.is_visible(): continue
		var point := box.position + marker.normalized_position() * box.size
		var player := marker.kind() == MapView.MarkerKind.PLAYER
		var exit := marker.kind() == MapView.MarkerKind.EXTRACTION
		var color := Style.TEXT if player else (Color("81c7a0") if exit else Style.ACCENT)
		draw_circle(point, 10, Color(color, 0.16))
		draw_circle(point, 5 if player else 4, color)
		var text := marker.label().to_upper()
		var width := minf(Style.MONO.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 18, box.size.x - 16)
		var label_box := marker_label_rect(point, width, box, labels)
		labels.append(label_box)
		var label_pos := label_box.position
		draw_line(point, label_box.get_center(), Color(color, 0.35), 1)
		draw_rect(Rect2(label_pos, Vector2(width, 28)), Color("101718"))
		draw_rect(Rect2(label_pos, Vector2(width, 28)), Color(color, 0.5), false, 1)
		draw_string(Style.MONO, label_pos + Vector2(9, 19), text, HORIZONTAL_ALIGNMENT_LEFT, width - 18, 14, color)


static func marker_label_rect(point: Vector2, width: float, bounds: Rect2, occupied: Array[Rect2]) -> Rect2:
	# Small deterministic layout over public markers only, not hidden entities.
	var offsets := [Vector2(14, -14), Vector2(14, 18), Vector2(14, -46),
		Vector2(-width - 14, -14), Vector2(-width - 14, 18), Vector2(-width - 14, -46)]
	var result := Rect2()
	for offset: Vector2 in offsets:
		var at := point + offset
		at.x = clampf(at.x, bounds.position.x + 8, bounds.end.x - width - 8)
		at.y = clampf(at.y, bounds.position.y + 8, bounds.end.y - 36)
		result = Rect2(at, Vector2(width, 28))
		var overlaps := false
		for other: Rect2 in occupied:
			if result.grow(3).intersects(other): overlaps = true; break
		if not overlaps: return result
	return result
