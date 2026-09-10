extends Control

## Static HUD crosshair renderer. The HUD scene owns this node; hud.gd only
## updates its state when settings or the mock raid state changes.

var shape: String = "CROSS"
var tint: Color = Color("#e6e8e3")
var spread: float = 0.0
var hit: bool = false
var kill: bool = false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func _draw() -> void:
	var center := Vector2(20, 20)
	if shape == "RING":
		draw_arc(center, 9 + spread, 0, TAU, 48, Color(0, 0, 0, 0.8), 4, true)
		draw_arc(center, 9 + spread, 0, TAU, 48, tint, 2, true)
	elif shape in ["DOT", "PIXEL"]:
		var dot_size := 2.0 if shape == "DOT" else 6.0
		draw_rect(Rect2(center - Vector2.ONE * (dot_size / 2 + 1), Vector2.ONE * (dot_size + 2)), Color(0, 0, 0, 0.8))
		draw_rect(Rect2(center - Vector2.ONE * dot_size / 2, Vector2.ONE * dot_size), tint)
	else:
		var gap := 5.0 + spread + (4.0 if shape == "OPEN" else 0.0)
		for direction in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
			var a: Vector2 = center + direction * gap
			var b: Vector2 = center + direction * (gap + 10)
			draw_line(a, b, Color(0, 0, 0, 0.8), 4)
			draw_line(a, b, tint, 2)
	if hit:
		for direction in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			draw_line(center + direction * 7, center + direction * 12, Color("#d9483b") if kill else tint, 2)
