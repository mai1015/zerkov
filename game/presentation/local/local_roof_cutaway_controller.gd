class_name LocalRoofCutawayController
extends Node
## Viewer-local presentation only. Roof cutaways never mutate collision, vision,
## interaction, inventory, AI, or profile state.
const FADE_SECONDS := 0.18
const MIN_POINTS := 3
var _groups: Array[Dictionary] = []
var _ids: Dictionary = {}
var _last_position := Vector2.INF
var _transition_count: int = 0

func configure(world_root: Node2D, initial_position: Vector2) -> bool:
	if world_root == null or not initial_position.is_finite() or not _groups.is_empty():
		return false
	var stack: Array[Node] = [world_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Node2D and node.has_meta("cutaway_region"):
			if not _bind_group(node as Node2D):
				release()
				return false
		stack.append_array(node.get_children())
	_last_position = Vector2.INF
	update_position(initial_position, true)
	return true

func _bind_group(node: Node2D) -> bool:
	var id_value: Variant = node.get_meta("cutaway_id", "")
	var region_value: Variant = node.get_meta("cutaway_region", null)
	var margin_value: Variant = node.get_meta("cutaway_exit_margin", 8.0)
	if not id_value is String or String(id_value).is_empty() or _ids.has(String(id_value)):
		return false
	if not region_value is PackedVector2Array or region_value.size() < MIN_POINTS:
		return false
	if typeof(margin_value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(margin_value)) or float(margin_value) < 0.0 or float(margin_value) > 64.0:
		return false
	var visual := node.get_node_or_null("CutawayVisuals") as CanvasItem
	if visual == null:
		return false
	var polygon := PackedVector2Array()
	for local_point: Vector2 in region_value:
		var world_point: Vector2 = node.global_transform * local_point
		if not world_point.is_finite():
			return false
		polygon.append(world_point)
	if absf(_signed_area(polygon)) < 1.0:
		return false
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for point: Vector2 in polygon:
		bounds = bounds.expand(point)
	bounds = bounds.grow(float(margin_value))
	var color := visual.modulate
	color.a = 1.0
	visual.modulate = color
	var row := {
		"id": String(id_value),
		"polygon": polygon,
		"exit_bounds": bounds,
		"visual": visual,
		"inside": false,
		"tween": null,
	}
	_groups.append(row)
	_ids[String(id_value)] = true
	return true

func update_position(position: Vector2, immediate: bool = false) -> void:
	if not position.is_finite() or (not immediate and position == _last_position):
		return
	_last_position = position
	for row: Dictionary in _groups:
		var inside: bool = Geometry2D.is_point_in_polygon(position, row.polygon)
		if bool(row.inside) and not inside:
			inside = (row.exit_bounds as Rect2).has_point(position)
		if inside == bool(row.inside):
			continue
		row.inside = inside
		_transition_count += 1
		_set_visual(row, not inside, immediate)

func _set_visual(row: Dictionary, closed: bool, immediate: bool) -> void:
	var old_tween: Variant = row.tween
	if old_tween is Tween and old_tween.is_valid():
		old_tween.kill()
	var visual := row.visual as CanvasItem
	var alpha := 1.0 if closed else 0.0
	if immediate or not is_inside_tree():
		var color := visual.modulate
		color.a = alpha
		visual.modulate = color
		row.tween = null
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(visual, "modulate:a", alpha, FADE_SECONDS)
	row.tween = tween

func group_count() -> int:
	return _groups.size()

func transition_count() -> int:
	return _transition_count

func is_open(id_value: String) -> bool:
	for row: Dictionary in _groups:
		if row.id == id_value:
			return bool(row.inside)
	return false

func release() -> void:
	for row: Dictionary in _groups:
		var tween: Variant = row.tween
		if tween is Tween and tween.is_valid():
			tween.kill()
		var visual := row.visual as CanvasItem
		if visual != null:
			var color := visual.modulate
			color.a = 1.0
			visual.modulate = color
	_groups.clear()
	_ids.clear()
	_last_position = Vector2.INF
	_transition_count = 0

static func _signed_area(points: PackedVector2Array) -> float:
	var sum := 0.0
	for index: int in range(points.size()):
		var a := points[index]
		var b := points[(index + 1) % points.size()]
		sum += a.x * b.y - b.x * a.y
	return sum * 0.5
