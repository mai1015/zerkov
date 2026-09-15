class_name ZNorthlineReviewWalker
extends CharacterBody2D
## Collision-aware inspector for this standalone environment. NOT a raid actor.
## No health, inventory, stamina, weapon state, persistence or authority mutation.
const TEXTURE = preload("res://assets/world/northline_zone/review_walker.png")
var enabled: bool = false
var animate: bool = false
var elapsed: float = 0.0
var face_left: bool = false
var layers: Array[Sprite2D] = []

func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	var circle := CircleShape2D.new()
	circle.radius = 5.0
	var shape := CollisionShape2D.new()
	shape.shape = circle
	add_child(shape)
	for row: int in range(4):
		var sprite := Sprite2D.new()
		sprite.texture = TEXTURE
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.region_enabled = true
		sprite.region_filter_clip_enabled = true
		sprite.centered = false
		sprite.position = Vector2(-32, -48)
		layers.append(sprite)
		add_child(sprite)
	show_frame(false, 0)
	queue_redraw()

func _draw() -> void:
	draw_circle(Vector2(0, -2), 9, Color(0.01,0.025,0.018,0.38))
	draw_arc(Vector2.ZERO, 10, 0, TAU, 20, Color(0.57,0.82,0.74,0.75), 1)

func show_frame(moving: bool, frame: int) -> void:
	for row: int in range(layers.size()):
		layers[row].region_rect = Rect2((frame % 6) * 64, (row + (4 if moving else 0)) * 64, 64, 64)
		layers[row].flip_h = face_left

func _physics_process(delta: float) -> void:
	if not enabled:
		velocity = Vector2.ZERO
		return
	var input := Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var speed := 144.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 88.0
	velocity = input.normalized() * speed
	if input.x != 0:
		face_left = input.x < 0
	move_and_slide()
	if animate:
		elapsed += delta
	show_frame(input != Vector2.ZERO, int(elapsed * (10 if input != Vector2.ZERO else 6)))
