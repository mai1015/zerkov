@tool
extends Resource
## Shared, event-driven art-direction settings. Angles are screen-space degrees.
@export var shadows_enabled: bool = true:
	set(value):
		shadows_enabled = value
		emit_changed()
@export var contacts_enabled: bool = true:
	set(value):
		contacts_enabled = value
		emit_changed()
@export_range(-180, 180) var direction_degrees: float = 39.0:
	set(value):
		direction_degrees = value
		emit_changed()
@export_range(0.1, 2.0) var length_scale: float = 0.76:
	set(value):
		length_scale = value
		emit_changed()
@export_range(0.0, 0.8) var opacity: float = 0.37:
	set(value):
		opacity = value
		emit_changed()
@export_range(0.0, 0.8) var contact_opacity: float = 0.32:
	set(value):
		contact_opacity = value
		emit_changed()
func direction() -> Vector2:
	return Vector2.RIGHT.rotated(deg_to_rad(direction_degrees))
