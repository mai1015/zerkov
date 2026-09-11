@tool
class_name ZSawmillYard
extends Node2D
## Materializes literal authored rectangles into the scene's TileMapLayers.
## The resource is the editable source; this is not a procedural map generator.
## Native tile navigation is disabled until the game-owned Task 3.9 bake.
## OccluderSources are inspectable authoring regions, not a Common Vision bake.

@export var layout: ZSawmillYardLayout


func _ready() -> void:
	compose()


func compose() -> void:
	if layout == null:
		return
	for layer_name in ["Ground", "Detail", "Obstacles", "Canopy", "Markers"]:
		(get_node(layer_name) as TileMapLayer).clear()
	for branch_name in ["Anchors", "OccluderSources"]:
		for child in get_node(branch_name).get_children():
			child.free()
	_paint_regions("Ground", layout.ground_regions)
	_paint_regions("Detail", layout.detail_regions)
	for row in layout.structures:
		_paint_regions(row.layer, [row])
		var source := Marker2D.new()
		source.name = String(row.id).get_slice(".", 3)
		source.position = Vector2(row.rect.position * layout.TILE_SIZE)
		source.set_meta("stable_id", String(row.id))
		source.set_meta("source_layer", String(row.layer))
		source.set_meta("source_tile", String(row.tile))
		source.set_meta("bounds_cells", row.rect)
		source.set_meta("role", String(row.role))
		get_node("OccluderSources").add_child(source)
	for row in layout.anchors:
		var marker := Marker2D.new()
		marker.name = String(row.id).replace(".", "_")
		marker.position = layout.cell_center(row.cell)
		marker.set_meta("stable_id", String(row.id))
		marker.set_meta("authored", row.duplicate(true))
		get_node("Anchors").add_child(marker)
		if not String(row.tile).is_empty():
			(get_node("Markers") as TileMapLayer).set_cell(row.cell, 0, layout.PALETTE[row.tile])
	get_node("Bounds").set_meta("world_rect_px", layout.world_bounds())
	get_node("Routes").set_meta("authored_routes", layout.routes.duplicate(true))
	set_meta("level_id", layout.level_id)
	set_meta("composition_revision", layout.revision)


func _paint_regions(layer_name: String, rows: Array) -> void:
	var layer := get_node(layer_name) as TileMapLayer
	for row in rows:
		for cell in layout.cells_in(row.rect):
			layer.set_cell(cell, 0, layout.PALETTE[row.tile])
