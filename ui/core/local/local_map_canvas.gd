class_name LocalMapCanvas
extends Control
## Authored Sawmill geometry plus public task/exit markers and the local actor.
## Enemy transforms never enter this presentation surface.
var _layout: ZSawmillYardLayout
var _markers: Array[MapView.Marker] = []
var _geometry: Array = []
var _native: bool = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layout = load("res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	queue_redraw()

func present(view: MapView, geometry: Array = [], native: bool = false) -> void:
	_geometry=geometry
	_native=native
	_markers = view.markers() if view != null and view.is_ready() else []
	queue_redraw()

func _draw() -> void:
	if _layout == null: return
	var box := Rect2(Vector2(24, 24), size - Vector2(48, 48))
	draw_rect(box, Color("151d19"))
	if _native:
		for row:Dictionary in _geometry:
			var color:=Color("37556b") if row.water else Color("708174")
			if row.has("rect"):
				var rect:Rect2=row.rect
				draw_rect(Rect2(box.position+rect.position*box.size,rect.size*box.size),color)
			elif row.has("polygon"):
				var points:=PackedVector2Array()
				for at:Vector2 in row.polygon:points.append(box.position+at*box.size)
				draw_colored_polygon(points,color)
	else:
		var extent := Vector2(_layout.size_cells)
		for row: Dictionary in _layout.structures:
			var rect: Rect2i = row.rect
			draw_rect(Rect2(box.position + Vector2(rect.position) / extent * box.size, Vector2(rect.size) / extent * box.size),
				Color("708174") if row.layer == "Obstacles" else Color("344c3f"))
	for marker: MapView.Marker in _markers:
		if not marker.is_visible(): continue
		var point := box.position + marker.normalized_position() * box.size
		var player := marker.kind() == MapView.MarkerKind.PLAYER
		var exit := marker.kind() == MapView.MarkerKind.EXTRACTION
		var color := Color("eef0df") if player else (Color("6fc997") if exit else Color("efa94f"))
		draw_circle(point, 7.0 if player else 5.0, color)
		var text_width:=ThemeDB.fallback_font.get_string_size(marker.label(),HORIZONTAL_ALIGNMENT_LEFT,-1,16).x
		var label_at:=point+Vector2(10,4)
		label_at.x=clampf(label_at.x,box.position.x+4,box.end.x-minf(text_width,box.size.x-8)-4)
		label_at.y=clampf(label_at.y,box.position.y+18,box.end.y-4)
		draw_string(ThemeDB.fallback_font,label_at,marker.label(),HORIZONTAL_ALIGNMENT_LEFT,box.size.x-8,16,color)
