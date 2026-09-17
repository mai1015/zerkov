class_name LocalMapCanvas
extends Control
## Authored Sawmill geometry plus public task/exit markers and the local actor.
## Enemy transforms never enter this presentation surface.
const Style = preload("res://ui/theme/local_journey_style.gd")
var _layout: ZSawmillYardLayout
var _markers: Array[MapView.Marker] = []
var _view: MapView

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_layout = load("res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	queue_redraw()

func present(view: MapView) -> void:
	if view == _view: return
	_view = view
	_markers = view.markers() if view != null and view.is_ready() else []
	queue_redraw()

func _draw() -> void:
	if _layout == null: return
	var box := Rect2(Vector2(24, 24), size - Vector2(48, 48))
	var extent := Vector2(_layout.size_cells)
	# Keep world proportions: the map is a tactical projection, not stretched art.
	var scale_factor := minf(box.size.x / extent.x, box.size.y / extent.y)
	var world_size := extent * scale_factor
	box = Rect2(box.position + (box.size - world_size) * 0.5, world_size)
	draw_rect(box, Color("10191a"))
	for cell in range(0, int(extent.x) + 1, 4):
		var x := box.position.x + cell * scale_factor
		draw_line(Vector2(x, box.position.y), Vector2(x, box.end.y), Color("21302e"), 1)
	for cell in range(0, int(extent.y) + 1, 4):
		var y := box.position.y + cell * scale_factor
		draw_line(Vector2(box.position.x, y), Vector2(box.end.x, y), Color("21302e"), 1)
	for row: Dictionary in _layout.structures:
		var rect: Rect2i = row.rect
		var shape := Rect2(box.position + Vector2(rect.position) * scale_factor, Vector2(rect.size) * scale_factor)
		draw_rect(shape, Color("586660") if row.layer == "Obstacles" else Color("263a32"))
		if row.layer == "Obstacles": draw_rect(shape, Color("839084"), false, 1)
	draw_rect(box, Style.LINE, false, 1)
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
		var label_pos := point + Vector2(14, -14)
		if label_pos.x + width > box.end.x - 8: label_pos.x = point.x - width - 14
		label_pos.x = clampf(label_pos.x, box.position.x + 8, box.end.x - width - 8)
		label_pos.y = clampf(label_pos.y, box.position.y + 8, box.end.y - 36)
		draw_rect(Rect2(label_pos, Vector2(width, 28)), Color("101718"))
		draw_rect(Rect2(label_pos, Vector2(width, 28)), Color(color, 0.5), false, 1)
		draw_string(Style.MONO, label_pos + Vector2(9, 19), text, HORIZONTAL_ALIGNMENT_LEFT, width - 18, 14, color)
