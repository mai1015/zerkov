extends Node2D

const SUN_PATH := "res://game/presentation/shoreline_prototype/resources/sun_profile.tres"
var sun: Resource
var player: CharacterBody2D
var camera: Camera2D
var overlay: Control
var overview := true
var message_time := 0.0
var hud_accum := 0.0
var sun_preset := 0

func _ready() -> void:
	sun = load(SUN_PATH)
	player = $World/Player
	camera = $Camera
	overlay = $HUD/Overlay
	overlay.player = player
	overlay.sun = sun
	player.interaction_completed.connect(_show_message)
	$World/Cabin.local_interior_changed.connect(func(inside: bool):
		_show_message("INTERIOR  |  Roof hidden for local viewer" if inside else "EXTERIOR  |  Roof restored"))

func _show_message(value: String) -> void:
	overlay.message = value
	message_time = 4.0

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_H: sun.shadows_enabled = not sun.shadows_enabled
		KEY_J: sun.contacts_enabled = not sun.contacts_enabled
		KEY_R:
			sun_preset = (sun_preset + 1) % 3
			sun.direction_degrees = [39.0, 72.0, -24.0][sun_preset]
		KEY_F2: overview = not overview
		KEY_TAB: $HUD.visible = not $HUD.visible
		KEY_C: get_tree().debug_collisions_hint = not get_tree().debug_collisions_hint
		KEY_ESCAPE: get_tree().quit()

func _process(delta: float) -> void:
	if not overview:
		camera.position = camera.position.lerp(player.global_position, 1.0 - exp(-delta * 7.0))
		camera.zoom = camera.zoom.lerp(Vector2(1.65, 1.65), 1.0 - exp(-delta * 6.0))
	else:
		camera.position = camera.position.lerp(Vector2(896, 512), 1.0 - exp(-delta * 5.0))
		camera.zoom = camera.zoom.lerp(Vector2(1.0714, 1.0714), 1.0 - exp(-delta * 5.0))
	message_time -= delta
	if message_time < 0.0:
		overlay.message = ""
	hud_accum += delta
	if hud_accum > 0.1:
		hud_accum = 0.0
		overlay.hint_text = player.target.hint() if is_instance_valid(player.target) else ""
		overlay.hint_screen = player.get_global_transform_with_canvas().origin + Vector2(27, -29)
		overlay.queue_redraw()
