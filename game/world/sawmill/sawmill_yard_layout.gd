@tool
class_name ZSawmillYardLayout
extends Resource
## Authored composition data only. No random placement, inventory, navigation
## requests, task progression, interaction policy, or authority lives here.

@export var level_id: String = "zerkov.level.sawmill_yard"
@export var revision: int = 1
@export var size_cells: Vector2i = Vector2i(40, 20)
@export var ground_regions: Array[Dictionary] = []
@export var detail_regions: Array[Dictionary] = []
@export var structures: Array[Dictionary] = []
@export var landmarks: Array[Dictionary] = []
@export var anchors: Array[Dictionary] = []
@export var routes: Array[Dictionary] = []
@export var review_views: Array[Dictionary] = []

const TILE_SIZE: int = ZWorldUnits.SOURCE_TILE_PIXELS
const PALETTE := {
	"dirt": Vector2i(0, 0), "grass": Vector2i(1, 0),
	"stone_floor": Vector2i(2, 0), "water": Vector2i(3, 0),
	"road": Vector2i(0, 1), "sand": Vector2i(1, 1),
	"log_wall": Vector2i(2, 1), "fence": Vector2i(3, 1),
	"canopy": Vector2i(0, 2), "sawdust": Vector2i(1, 2),
	"lichen": Vector2i(2, 2), "dock": Vector2i(3, 2),
	"actor_marker": Vector2i(0, 3), "fx_marker": Vector2i(1, 3),
	"extract": Vector2i(2, 3), "rock_blocked": Vector2i(3, 3),
}


func world_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(size_cells * TILE_SIZE))


func cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell * TILE_SIZE) + Vector2.ONE * (TILE_SIZE / 2.0)


func anchor(stable_id: String) -> Dictionary:
	for row in anchors:
		if row.id == stable_id:
			return row.duplicate(true)
	return {}


func cells_in(rect: Rect2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			result.append(Vector2i(x, y))
	return result


# --- Typed Markers (Task 3.11) ---

var _markers_cache: Array[ZWorldMarker] = []
var _markers_by_id: Dictionary = {} # StringName -> ZWorldMarker
var _marker_build_errors: Array[String] = []


func marker(marker_id: Variant) -> ZWorldMarker:
	_ensure_markers()
	return _markers_by_id.get(StringName(marker_id), null)


func markers_of_kind(kind: Variant) -> Array[ZWorldMarker]:
	_ensure_markers()
	var result: Array[ZWorldMarker] = []
	for m in _markers_cache:
		if m.matches_kind(kind):
			result.append(m)
	return result


func all_markers() -> Array[ZWorldMarker]:
	_ensure_markers()
	return _markers_cache.duplicate()


func patrol_markers() -> Array[ZPatrolMarker]:
	_ensure_markers()
	var result: Array[ZPatrolMarker] = []
	for m in _markers_cache:
		if m is ZPatrolMarker:
			result.append(m as ZPatrolMarker)
	return result


func rebuild_markers() -> void:
	_markers_cache.clear()
	_markers_by_id.clear()
	_marker_build_errors.clear()
	_build_markers()


func validate_markers() -> Array[String]:
	_ensure_markers()
	var problems := _marker_build_errors.duplicate()
	var seen_ids: Dictionary = {}
	for m in _markers_cache:
		var m_id := m.marker_id
		if seen_ids.has(m_id):
			problems.append("duplicate_marker_id: %s" % m_id)
		seen_ids[m_id] = true
		problems.append_array(m.validate())
	return problems


func _ensure_markers() -> void:
	if not _markers_cache.is_empty():
		return
	_build_markers()


func _build_markers() -> void:
	_markers_cache.clear()
	_markers_by_id.clear()
	_marker_build_errors.clear()

	# 1. Promote authored anchors to typed Resource markers
	for row in anchors:
		var m := _create_marker_from_anchor(row)
		if m == null:
			continue
		_register_marker(m)

	# 2. Derive patrol markers deterministically from authored routes
	for route in routes:
		var route_markers := derive_patrol_markers_for_route(route)
		for pm in route_markers:
			_register_marker(pm)


func _register_marker(m: ZWorldMarker) -> void:
	var id := m.marker_id
	if _markers_by_id.has(id):
		var err := "duplicate_marker_id: %s" % id
		_marker_build_errors.append(err)
		return
	_markers_by_id[id] = m
	_markers_cache.append(m)


func _create_marker_from_anchor(row: Dictionary) -> ZWorldMarker:
	var kind: String = row.get("kind", "")
	var m: ZWorldMarker
	match kind:
		"spawn":
			m = ZSpawnMarker.new()
		"objective_crate":
			var om := ZObjectiveMarker.new()
			om.landmark_id = StringName(row.get("landmark_id", ""))
			om.content_profile_id = StringName(row.get("content_profile_id", ""))
			m = om
		"loot":
			var lm := ZLootMarker.new()
			lm.content_profile_id = StringName(row.get("content_profile_id", ""))
			lm.is_corpse = false
			m = lm
		"corpse":
			var cm := ZLootMarker.new()
			cm.content_profile_id = StringName(row.get("content_profile_id", ""))
			cm.is_corpse = true
			m = cm
		"extract":
			var em := ZExtractionMarker.new()
			em.zone_cells = row.get("zone_cells", Rect2i())
			m = em
		"encounter":
			m = ZEncounterMarker.new()
		_:
			m = ZWorldMarker.new()

	m.marker_id = StringName(row.get("id", ""))
	m.cell = row.get("cell", Vector2i.ZERO)
	m.approach_cell = row.get("approach_cell", Vector2i.ZERO)
	m.display_name = row.get("name", "")
	m.tile = row.get("tile", "")
	m.label_offset_px = row.get("label_offset_px", Vector2i.ZERO)
	return m


static func derive_patrol_markers_for_route(route: Dictionary) -> Array[ZPatrolMarker]:
	var result: Array[ZPatrolMarker] = []
	var route_id_str: String = route.get("id", "")
	var points: PackedVector2Array = route.get("points", PackedVector2Array())
	if route_id_str.is_empty() or points.is_empty():
		return result

	var segments := route_id_str.split(".")
	var route_name: String = segments[segments.size() - 1] if segments.size() >= 4 else route_id_str
	var route_display: String = route.get("name", route_name.to_upper())

	var n := points.size()
	for i in range(n):
		var pt := Vector2i(points[i])
		var step := Vector2i.ZERO
		if i < n - 1:
			var nxt := Vector2i(points[i + 1])
			step = Vector2i(signi(nxt.x - pt.x), signi(nxt.y - pt.y))
		elif i > 0:
			var prev := Vector2i(points[i - 1])
			step = Vector2i(signi(prev.x - pt.x), signi(prev.y - pt.y))
		var approach := pt + step

		var pm := ZPatrolMarker.new()
		pm.marker_id = StringName("zerkov.patrol.sawmill.%s.%d" % [route_name, i])
		pm.cell = pt
		pm.approach_cell = approach
		pm.display_name = "%s / WAYPOINT %d" % [route_display, i]
		pm.route_id = StringName(route_id_str)
		pm.ordinal = i
		result.append(pm)
	return result

