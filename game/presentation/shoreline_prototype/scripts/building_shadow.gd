@tool
extends Polygon2D
@export var sun_profile: Resource
@export var footprint: Rect2 = Rect2(-176, -210, 352, 210)
@export_range(0, 1024) var physical_height: float = 92.0:
	set(value):
		physical_height=value
		if is_node_ready(): refresh()
func _ready() -> void:
	if sun_profile != null and not sun_profile.changed.is_connected(refresh):
		sun_profile.changed.connect(refresh)
	refresh()
func refresh() -> void:
	if sun_profile == null:
		return
	var r := footprint
	var delta: Vector2 = sun_profile.direction() * physical_height * float(sun_profile.length_scale)
	var points := PackedVector2Array([r.position, r.position+Vector2(r.size.x,0), r.end, r.position+Vector2(0,r.size.y)])
	for i in range(4):
		points.append(points[i]+delta)
	polygon = Geometry2D.convex_hull(points)
	color = Color(0.09,0.115,0.115,float(sun_profile.opacity))
	visible = bool(sun_profile.shadows_enabled)
