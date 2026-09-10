extends Control

## Static reload-ring renderer. The HUD controller updates progress in place.

var progress: float = 0.0
var tint: Color = Color("#e6e8e3")
var track: Color = Color(0.0, 0.0, 0.0, 0.70)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func set_progress(value: float) -> void:
	progress = clampf(value, 0.0, 1.0)
	queue_redraw()

func _draw() -> void:
	var center: Vector2 = size * 0.5
	var radius: float = minf(size.x, size.y) * 0.5 - 4.0
	draw_circle(center, radius, Color(0.0, 0.0, 0.0, 0.46))
	draw_arc(center, radius, 0.0, TAU, 72, track, 4.0, true)
	if progress > 0.001:
		draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + TAU * progress, 72, tint, 3.0, true)
