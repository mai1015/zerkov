extends Node2D
## Cutaway belongs to the local viewer, never to shared/multiplayer world state.
signal local_interior_changed(inside: bool)
var local_inside := false
func _ready() -> void:
	$InteriorTrigger.body_entered.connect(_entered)
	$InteriorTrigger.body_exited.connect(_exited)
func _entered(body: Node2D) -> void:
	if body.is_in_group("coastal_review_actor"):
		set_local_inside(true)
func _exited(body: Node2D) -> void:
	if body.is_in_group("coastal_review_actor"):
		set_local_inside(false)
func set_local_inside(value: bool) -> void:
	local_inside=value
	$Roof.visible=not value
	$Facade.visible=not value
	if has_node("PorchFixture"): $PorchFixture.visible=not value
	$CutawayCaps.visible=value
	# Movement blockers and the external building shadow remain present.
	local_interior_changed.emit(value)
