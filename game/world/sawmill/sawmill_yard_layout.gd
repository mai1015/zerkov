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
