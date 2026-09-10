extends Node2D
## Existing handoff art at one authored source pixel per world unit, with
## deliberately synthetic calibration marks. This is not a Sawmill level.
const Tokens = preload("res://ui/theme/tokens.gd")
const ART = preload("res://assets/handoff/bg_raid_frame.png")
const STRIPES := Rect2(-144, -100, 64, 8)

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_redraw()

func _draw() -> void:
	# Repeat the approved 640x360 play region to provide overscan during the
	# diagnostic camera path. Repeated seams are fixture-only, not level content.
	for y in range(-1, 2):
		for x in range(-1, 2):
			draw_texture_rect_region(ART, Rect2(Vector2(-320 + x * 640, -180 + y * 360), Vector2(640, 360)), Rect2(3, 3, 640, 360))
	draw_rect(Rect2(-148, -104, 72, 16), Tokens.BG)
	for x in range(64):
		draw_rect(Rect2(STRIPES.position + Vector2(x, 0), Vector2(1, 8)), Tokens.TEXT if x % 2 == 0 else Tokens.BG)
	# 32px tile ruler and 64px character-cell footprint, no invented character art.
	draw_rect(Rect2(-40, 40, 32, 32), Tokens.ACCENT, false, 1.0)
	draw_rect(Rect2(16, 32, 64, 64), Tokens.SOFT, false, 1.0)
	for x in range(0, 65, 8):
		draw_line(Vector2(16 + x, 96), Vector2(16 + x, 100), Tokens.SOFT, 1.0)
	# Fine diagonal / point probes reveal filtering and dropped source pixels.
	for x in range(24):
		draw_rect(Rect2(-144 + x, -72 + x, 1, 1), Tokens.ACCENT)
	draw_rect(Rect2(-108, -72, 1, 1), Tokens.TEXT)
