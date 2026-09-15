class_name ZNorthlineZoneOverlay
extends Control
## Crisp cartographic annotations over the actual native world render.
var view: Control

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func projected(at: Vector2) -> Vector2:
	return (at - view.camera.position) * view.camera.zoom * 3.0 + Vector2(960, 540)

func _draw() -> void:
	if view == null or view.world == null:
		return
	var data: Dictionary = view.data
	var font := ThemeDB.fallback_font
	if view.overview:
		# Grid in actual world space, plus a one-gameplay-viewport footprint.
		var tl := projected(Vector2.ZERO)
		var br := projected(Vector2(data["size"][0],data["size"][1]))
		for x: int in range(0,2689,336):
			draw_line(projected(Vector2(x,0)),projected(Vector2(x,1792)),Color(0.7,0.8,0.72,0.10),1)
		for y: int in range(0,1793,224):
			draw_line(projected(Vector2(0,y)),projected(Vector2(2688,y)),Color(0.7,0.8,0.72,0.10),1)
		draw_rect(Rect2(tl,br-tl),Color("8fa28d"),false,1)
		for i: int in range(data["sectors"].size()):
			var sector: Dictionary = data["sectors"][i]
			var at := projected(Vector2(sector["at"][0],sector["at"][1]))
			var text: String = str(sector["name"])
			var w := font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,14).x
			draw_rect(Rect2(at-Vector2(w/2+8,13),Vector2(w+16,27)),Color(0.025,0.052,0.042,0.94))
			draw_string(font,at+Vector2(-w/2,6),text,HORIZONTAL_ALIGNMENT_LEFT,-1,14,Color("e9d8ae"))
		var previous: Vector2 = view.last_detail_position
		var r := Rect2(projected(previous - Vector2(320,180)),Vector2(640,360) * view.camera.zoom * 3)
		draw_rect(r,Color(0.82,0.79,0.57,0.70),false,2)
	if view.routes_visible:
		for route: Dictionary in data["routes"]:
			var points := PackedVector2Array()
			for p: Array in route["points"]:
				points.append(projected(Vector2(p[0],p[1])))
			if points.size() >= 2:
				draw_polyline(points,Color(str(route["color"])),2 if view.overview else 3)
	if view.overview or view.routes_visible:
		for e: Dictionary in data["exits"]:
			var at := projected(Vector2(e["at"][0],e["at"][1]))
			draw_rect(Rect2(at-Vector2(6,6),Vector2(12,12)),Color("8ec1a2"),false,2)
			var text: String = str(e["name"])
			var dx := -font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,13).x - 12 if e["id"]=="rail" else 12.0
			draw_string(font,at+Vector2(dx,-8),text,HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color("b5dcc0"))
	if view.walk_mode:
		var at := projected(view.walker.position)
		draw_circle(at,4,Color("b8e8ca")) if view.overview else draw_arc(at+Vector2(0,3),31,0,TAU,24,Color(0.6,0.84,0.7,0.5),1)
