class_name ZWorldCamera2D
extends Camera2D
## Presentation Camera2D node binding the ZWorldCameraFollow adapter.
##
## Enforces the presentation contract: zoom (1, 1), position/rotation smoothing
## disabled, whole-raster pixel positioning, and zero transform authority.

var follow: ZWorldCameraFollow = ZWorldCameraFollow.new()


func _init() -> void:
	position_smoothing_enabled = false
	rotation_smoothing_enabled = false
	zoom = Vector2.ONE
	anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER


func configure(
	bounds: Rect2,
	initial_pos: Vector2 = Vector2.ZERO,
	viewport_size: Vector2i = ZWorldCameraFollow.BASE_SURFACE_SIZE
) -> void:
	follow.configure(bounds, initial_pos, viewport_size)
	position = follow.position_px


func follow_position(target_px: Vector2, snap: bool = false) -> Vector2:
	var result := follow.follow_position(target_px, snap)
	position = result
	return result


func follow_movement_result(result: ZMovementResult, snap: bool = false) -> Vector2:
	var outcome := follow.follow_movement_result(result, snap)
	position = outcome
	return outcome


func follow_locomotion(locomotion: ZPlayerLocomotion, snap: bool = false) -> Vector2:
	var outcome := follow.follow_locomotion(locomotion, snap)
	position = outcome
	return outcome


func converge_to_correction(record: Dictionary, snap: bool = false) -> Vector2:
	var outcome := follow.converge_to_correction(record, snap)
	position = outcome
	return outcome


func step_convergence() -> Vector2:
	var outcome := follow.step_convergence()
	position = outcome
	return outcome
