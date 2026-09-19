extends Node2D
## Art-review door, reusable through interact() or set_open(). No input ownership.
signal state_changed(is_open: bool)
@export var door_id: String = "coastal.cabin.front"
var is_open: bool = false
func _ready() -> void:
	add_to_group("coastal_interactables")
func interaction_point() -> Vector2:
	return global_position
func hint() -> String:
	return "Close door" if is_open else "Open door"
func interact(actor: Node2D) -> bool:
	if actor == null or actor.global_position.distance_to(global_position)>85.0:
		return false
	return set_open(not is_open)
func set_open(value: bool) -> bool:
	if not value and has_node("Threshold"):
		for body in $Threshold.get_overlapping_bodies():
			if body.is_in_group("coastal_review_actor"):
				return false
	is_open=value
	$Leaf.visible = not value
	$OpenLeaf.visible = value
	$Body/Collision.set_deferred("disabled", value)
	state_changed.emit(value)
	return true
