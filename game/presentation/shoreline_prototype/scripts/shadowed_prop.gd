@tool
extends Node2D
## A source-faithful sprite, editable ground footprint and two independent shadows.
## Static props have NO frame callback. The sun resource only notifies on changes.
@export var sun_profile: Resource
@export var asset_id: String = ""
@export var silhouette_height: float = 64.0
@export_range(0, 1024) var physical_height: float = 48.0:
	set(value):
		physical_height=value
		if is_node_ready(): _apply_shadows()
@export var flat_footprint: bool = false:
	set(value):
		flat_footprint=value
		if is_node_ready(): _apply_shadows()
@export var ground_size: Vector2 = Vector2(32, 16):
	set(value):
		ground_size=value
		if is_node_ready(): _apply_shadows()
@export var search_label: String = ""
@export var container_id: String = ""
signal search_requested(id: String, actor: Node2D)
var searched := false

func _ready() -> void:
	if sun_profile != null:
		if not sun_profile.changed.is_connected(_apply_shadows):
			sun_profile.changed.connect(_apply_shadows)
	_apply_shadows()
	if not Engine.is_editor_hint() and not search_label.is_empty():
		add_to_group("coastal_interactables")

func _apply_shadows() -> void:
	if sun_profile == null or not has_node("CastShadow"):
		return
	var cast := get_node("CastShadow") as Sprite2D
	var contact := get_node("ContactShadow") as Sprite2D
	var direction: Vector2 = sun_profile.direction()
	var length: float = physical_height * float(sun_profile.length_scale)
	cast.visible = bool(sun_profile.shadows_enabled)
	cast.modulate = Color(0.09, 0.115, 0.115, float(sun_profile.opacity))
	if flat_footprint:
		cast.transform = Transform2D(0.0, direction * length)
	else:
		var projection := direction * length / maxf(silhouette_height, 1.0)
		cast.transform = Transform2D(Vector2.RIGHT, -projection, Vector2.ZERO)
	contact.visible = bool(sun_profile.contacts_enabled)
	contact.modulate = Color(0.07, 0.09, 0.075, float(sun_profile.contact_opacity))
	contact.scale = ground_size * 1.65 / 96.0

func interaction_point() -> Vector2:
	return global_position + Vector2(0, 7)

func hint() -> String:
	return ("Inspect " if searched else "Search ") + search_label

func interact(actor: Node2D) -> bool:
	if actor == null or container_id.is_empty() or actor.global_position.distance_to(interaction_point()) > 70.0:
		return false
	search_requested.emit(container_id, actor)
	# Acknowledgement only. Actual inventory/persistence is deliberately host-owned.
	searched = true
	return true
