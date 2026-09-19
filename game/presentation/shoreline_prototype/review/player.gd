extends CharacterBody2D
## Standalone review controller only. Never a replacement for Zerkov authority.
@export var walk_speed: float = 155.0
var automated_input := Vector2.ZERO
var automated := false
var target: Node2D
signal interaction_completed(text: String)
func _ready() -> void:
	add_to_group("coastal_review_actor")
func _physics_process(_delta: float) -> void:
	var direction := automated_input
	if not automated:
		direction=Vector2(float(Input.is_physical_key_pressed(KEY_D))-float(Input.is_physical_key_pressed(KEY_A)),float(Input.is_physical_key_pressed(KEY_S))-float(Input.is_physical_key_pressed(KEY_W)))
	var speed:=walk_speed * (1.55 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	velocity=direction.limit_length()*speed
	move_and_slide()
	if absf(direction.x)>0.05:
		$Visual/Sprite.flip_h=direction.x<0.0
		$Visual/CastShadow.flip_h=direction.x<0.0
	_find_target()
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_F:
		activate_target()
func _find_target() -> void:
	target=null
	var best := 72.0
	for candidate in get_tree().get_nodes_in_group("coastal_interactables"):
		var point: Vector2=candidate.interaction_point()
		var distance:=global_position.distance_to(point)
		if distance >= best:
			continue
		var query:=PhysicsRayQueryParameters2D.create(global_position+Vector2(0,-6),point,1)
		# The target's own movement footprint is not an intervening wall.
		var excludes: Array[RID]=[get_rid()]
		for child in candidate.get_children():
			if child is CollisionObject2D:
				excludes.append(child.get_rid())
		query.exclude=excludes
		if not get_world_2d().direct_space_state.intersect_ray(query).is_empty():
			continue
		target=candidate
		best=distance
func activate_target() -> bool:
	if is_instance_valid(target) and target.interact(self):
		if not String(target.get("search_label") if target.get("search_label") != null else "").is_empty():
			interaction_completed.emit("Searched: "+String(target.search_label)+"  |  inventory adapter not connected")
		else:
			interaction_completed.emit("Door opened" if target.is_open else "Door closed")
		return true
	return false
