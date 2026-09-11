extends SceneTree
## Task 3.4 composition gate: static authored identities and native occupied
## cells. This does not accept the later movement, pathfinder, Vision bake,
## marker lifecycle or whole-raid contracts in Tasks 3.6 and 3.9-3.12.

const YardScene = preload("res://game/world/sawmill/sawmill_yard.tscn")
const Output = preload("res://tests/visual/sawmill_yard/exact_output.gd")
const TILESET_PATH := "res://game/world/sawmill/sawmill_tileset.tres"
const SPAWN := "zerkov.spawn.sawmill.west_service"
const EXTRACT := "zerkov.extract.sawmill.road_gate"
const STABLE_ANCHORS := {
	SPAWN: Vector2i(4, 15),
	"zerkov.loot.sawmill.crate.log_racks": Vector2i(9, 5),
	"zerkov.loot.sawmill.crate.saw_house": Vector2i(21, 4),
	"zerkov.loot.sawmill.crate.settling_dock": Vector2i(25, 14),
	"zerkov.loot.sawmill.service_cache": Vector2i(10, 14),
	"zerkov.loot.sawmill.corpse.haul_lane": Vector2i(29, 12),
	EXTRACT: Vector2i(37, 10),
	"zerkov.encounter.sawmill.scav_cover": Vector2i(30, 6),
	"zerkov.encounter.sawmill.mutant_verge": Vector2i(15, 17),
}
const LAYERS := ["Ground", "Detail", "Obstacles", "Canopy", "Markers"]
const DIRECTIONS := [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]

var checks := 0
var failures := 0
var yard: ZSawmillYard
var layout: ZSawmillYardLayout
var blocked: Dictionary = {}
var reached: Dictionary = {}
var source_cells := 0
var physics_cells := 0
var occluder_cells := 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SAWMILL_LAYOUT: " + message)


func run() -> void:
	# The headless backend reports a dummy 64px Window irrespective of the CLI
	# size. Configure its non-rendering root to the sole acceptance canvas.
	if DisplayServer.get_name() == "headless":
		root.size = Output.EXACT_SIZE
	if not Output.accepts_window(root):
		push_error("SAWMILL_LAYOUT: exact 1920x1080 root required; observed " + str(root.size))
		quit(2)
		return
	_test_output_guard()
	yard = YardScene.instantiate() as ZSawmillYard
	root.add_child(yard)
	layout = yard.layout
	await process_frame
	check(layout.level_id == "zerkov.level.sawmill_yard", "spec level identity")
	check(layout.revision == 1, "authored composition revision")
	check(layout.size_cells == Vector2i(40, 20), "authored 40 by 20 source tiles")
	check(layout.world_bounds() == Rect2(0, 0, 1280, 640), "source-pixel bounds, not an output surface")
	check(layout.TILE_SIZE == 32 and layout.TILE_SIZE == ZWorldUnits.SOURCE_TILE_PIXELS, "accepted units")
	_test_native_layers()
	_test_identifiers_and_sources()
	reached = _flood(blocked, layout.anchor(SPAWN).cell)
	check(reached.size() + blocked.size() == 800, "every unblocked cell connects to spawn; no orphan navigation pockets")
	_test_anchors()
	_test_routes()
	_test_boundaries()
	_test_repeat_and_reorder()
	_test_negative_geometry()
	print("SAWMILL_LAYOUT_RESULT checks=", checks, " failures=", failures,
		" anchors=", layout.anchors.size(), " landmarks=", layout.landmarks.size(),
		" routes=", layout.routes.size(), " reachable_cells=", reached.size(),
		" native_cells=", source_cells, " physics_cells=", physics_cells,
		" occluder_cells=", occluder_cells, " human_approval=false")
	yard.free()
	yard = null
	layout = null
	await process_frame
	quit(0 if failures == 0 else 1)


func _test_output_guard() -> void:
	check(Output.accepts_window(root), "current root is exact 1920x1080")
	check(Output.accepts_arguments(PackedStringArray(["--resolution", "1920x1080"])), "exact launch command accepted")
	check(Output.EXACT_SIZE == Vector2i(1920, 1080), "sole supported output")
	check(Output.WORLD_SIZE * Output.WORLD_SCALE == Output.EXACT_SIZE, "640 by 360 is exactly 3x")
	check(not Output.accepts_arguments(PackedStringArray()), "omitted output fails closed without a launch")
	check(not Output.accepts_arguments(PackedStringArray(["--resolution"])), "missing argument fails closed")
	check(not Output.accepts_arguments(PackedStringArray(["--resolution", "forbidden"])), "nonexact argument fails closed")
	check(not Output.accepts_arguments(PackedStringArray(["--resolution", "1920x1080", "--resolution", "1920x1080"])), "ambiguous duplicate fails closed")
	check(not Output.accepts_arguments(PackedStringArray(["--resolution=1920x1080"])), "unapproved argument form fails closed")
	check(ProjectSettings.get_setting("display/window/size/viewport_width") == 1920, "project width retained")
	check(ProjectSettings.get_setting("display/window/size/viewport_height") == 1080, "project height retained")


func _test_native_layers() -> void:
	for layer_name in LAYERS:
		var layer := yard.get_node(layer_name) as TileMapLayer
		check(layer != null, "separate native layer " + layer_name)
		check(layer.tile_set.resource_path == TILESET_PATH, "accepted project-owned TileSet " + layer_name)
		check(not layer.navigation_enabled, "runtime navigation is not silently generated " + layer_name)
		check(layer.texture_filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE, "nearest inheritance " + layer_name)
		for cell in layer.get_used_cells():
			source_cells += 1
			check(Rect2i(Vector2i.ZERO, layout.size_cells).has_point(cell), "%s cell %s inside bounds" % [layer_name, cell])
			check(layer.get_cell_source_id(cell) == 0 and layer.get_cell_alternative_tile(cell) == 0, "only accepted base source tiles")
			var tile := layer.get_cell_tile_data(cell)
			check(tile != null, "%s cell %s has actual TileData" % [layer_name, cell])
			if tile == null:
				continue
			var source_id := String(tile.get_custom_data("source_tile_id"))
			check(source_id.begins_with("zerkov.tile.sawmill.greybox."), "project-owned source at " + str(cell))
			var polygons := tile.get_collision_polygons_count(0)
			if layer.collision_enabled and polygons > 0:
				check(not blocked.has(cell), "one native blocking layer per cell at " + str(cell))
				blocked[cell] = true
				physics_cells += 1
				for polygon_index in polygons:
					check(not tile.is_collision_polygon_one_way(0, polygon_index), "no ambiguous one-way geometry in this top-down composition")
					for point in tile.get_collision_polygon_points(0, polygon_index):
						check(_contains_closed(layout.world_bounds(), layer.map_to_local(cell) + point), "native collision point within world bounds")
			if tile.get_occluder(0) != null:
				occluder_cells += 1
				for point in tile.get_occluder(0).polygon:
					check(_contains_closed(layout.world_bounds(), layer.map_to_local(cell) + point), "native occluder point within world bounds")
	check((yard.get_node("Ground") as TileMapLayer).get_used_cells().size() == 800, "ground has complete coverage")
	check(yard.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "yard nearest filtering")
	check(physics_cells > 200 and physics_cells < 360, "bounded native obstacle population")


func _test_identifiers_and_sources() -> void:
	var seen: Dictionary = {}
	for collection in [layout.ground_regions, layout.detail_regions, layout.structures, layout.landmarks, layout.anchors, layout.routes]:
		for row in collection:
			var id := String(row.id)
			check(ZIdentityRules.is_valid(id, id.get_slice(".", 1)), "stable grammar " + id)
			check(not seen.has(id), "unique authored identity " + id)
			seen[id] = true
	check(yard.get_node("OccluderSources").get_child_count() == layout.structures.size(), "one explicit source per authored structure")
	var total_cells := 0
	for row in layout.structures:
		check(row.rect.size.x > 0 and row.rect.size.y > 0, "positive source rectangle " + row.id)
		check(Rect2i(Vector2i.ZERO, layout.size_cells).encloses(row.rect), "occluder source bounds " + row.id)
		var layer := yard.get_node(row.layer) as TileMapLayer
		for cell in layout.cells_in(row.rect):
			total_cells += 1
			var data := layer.get_cell_tile_data(cell)
			check(data != null and data.get_occluder(0) != null, "explicit source has native occlusion " + row.id + " " + str(cell))
			check(data != null and data.get_collision_polygons_count(0) > 0, "explicit solid source " + row.id)
	check(total_cells == occluder_cells, "sources account for every native occluder exactly once")
	check(total_cells <= 320, "authored cell budget for later deterministic bake")
	check(layout.landmarks.size() == 3, "exactly three objective landmarks")
	for row in layout.landmarks:
		var objective := layout.anchor(row.objective_id)
		check(not objective.is_empty(), "landmark references existing objective " + row.id)
		check(objective.get("landmark_id") == row.id, "bidirectional landmark identity " + row.id)
		check(row.rect.has_point(objective.cell), "objective sits within named landmark " + row.id)
		check(not String(row.identity).is_empty(), "documented silhouette for " + row.id)


func _test_anchors() -> void:
	check(layout.anchors.size() == STABLE_ANCHORS.size(), "fixed anchor set")
	var cells: Dictionary = {}
	var objective_count := 0
	for row in layout.anchors:
		check(STABLE_ANCHORS.get(row.id) == row.cell, "stable authored position " + row.id)
		check(not cells.has(row.cell), "anchors never overlap " + row.id)
		cells[row.cell] = true
		check(reached.has(row.cell), "spawn reaches anchor " + row.id + " at " + str(row.cell))
		check(reached.has(row.approach_cell), "spawn reaches approach " + row.id + " at " + str(row.approach_cell))
		check(_manhattan(row.cell, row.approach_cell) == 1, "adjacent distinct approach " + row.id)
		var point := layout.cell_center(row.cell)
		check(ZWorldUnits.godot_to_vision(point).ok, "anchor fits accepted fixed-unit conversion " + row.id)
		if row.kind == "objective_crate":
			objective_count += 1
		if row.has("content_profile_id"):
			var expected := String(ZerkovInventoryCatalog.PROFILE_CORPSE) if row.kind == "corpse" else String(ZerkovInventoryCatalog.PROFILE_WORLD_CRATE)
			check(row.content_profile_id == expected, "reference accepted content profile " + row.id)
	check(objective_count == 3, "three Supply Run crate anchors, without task runtime")
	var extract := layout.anchor(EXTRACT)
	check(extract.zone_cells == Rect2i(36, 9, 3, 3), "authored Road Gate zone")
	check(extract.zone_cells.has_point(extract.cell), "extract marker inside its zone")
	for cell in layout.cells_in(extract.zone_cells):
		check(reached.has(cell), "entire extraction zone reachable " + str(cell))
	check(_anchor_node_snapshot().size() == STABLE_ANCHORS.size(), "scene exposes every stable marker")


func _test_routes() -> void:
	check(layout.routes.size() == 4, "direct lane, bypass, and two objective approaches")
	for row in layout.routes:
		check(row.width_cells == 3, "explicit 96px corridor " + row.id)
		var route_cells := _route_cells(row)
		check(not route_cells.is_empty(), "nonempty axis-aligned route " + row.id)
		for cell in route_cells:
			check(reached.has(cell) and not blocked.has(cell), "three-cell clear route " + row.id + " at " + str(cell))


func _test_boundaries() -> void:
	for x in layout.size_cells.x:
		check(blocked.has(Vector2i(x, 0)), "north boundary " + str(x))
		check(blocked.has(Vector2i(x, layout.size_cells.y - 1)), "south boundary " + str(x))
	for y in layout.size_cells.y:
		check(blocked.has(Vector2i(0, y)), "west boundary " + str(y))
		check(blocked.has(Vector2i(layout.size_cells.x - 1, y)), "east boundary " + str(y))
	check(not reached.has(Vector2i(-1, 10)), "no escape west")
	check(not reached.has(Vector2i(40, 10)), "extract is an internal zone, not an unbounded world opening")


func _test_repeat_and_reorder() -> void:
	var before := _anchor_node_snapshot()
	var counts: Array[int] = []
	for layer_name in LAYERS:
		counts.append((yard.get_node(layer_name) as TileMapLayer).get_used_cells().size())
	yard.compose()
	check(before == _anchor_node_snapshot(), "recomposition preserves fixed anchor IDs and poses")
	for index in LAYERS.size():
		check(counts[index] == (yard.get_node(LAYERS[index]) as TileMapLayer).get_used_cells().size(), "recomposition does not duplicate cells")
	var anchor_root := yard.get_node("Anchors")
	anchor_root.move_child(anchor_root.get_child(0), anchor_root.get_child_count() - 1)
	check(before == _anchor_node_snapshot(), "scene order is not identity")
	var second := YardScene.instantiate() as ZSawmillYard
	root.add_child(second)
	var first_node := yard.get_node("Anchors").get_child(0)
	var second_node := second.get_node("Anchors").get_child(1)
	check(first_node != second_node, "distinct scene instances own distinct marker nodes")
	check(second.layout.anchor(SPAWN) == layout.anchor(SPAWN), "reinstantiation has deterministic authored data")
	var detached := layout.anchor(SPAWN)
	detached.cell = Vector2i(-100, -100)
	check(layout.anchor(SPAWN).cell == STABLE_ANCHORS[SPAWN], "anchor lookup returns detached data")
	second.free()


func _test_negative_geometry() -> void:
	check(_geometry_findings(blocked, layout.anchors).is_empty(), "unmodified composition passes the mutation-sensitive geometry validator")
	var bad := blocked.duplicate()
	var spawn_cell: Vector2i = layout.anchor(SPAWN).cell
	for direction in DIRECTIONS:
		bad[spawn_cell + direction] = true
	check(_geometry_findings(bad, layout.anchors).has("unreachable:" + EXTRACT), "negative control: sealed spawn diagnoses unreachable Road Gate")
	bad = blocked.duplicate()
	bad[Vector2i(22, 10)] = true
	check(_geometry_findings(bad, layout.anchors).has("blocked_route:zerkov.route.sawmill.haul_lane"), "negative control: road obstruction diagnoses the affected authored route")
	bad = blocked.duplicate()
	bad.erase(Vector2i(0, 10))
	check(_geometry_findings(bad, layout.anchors).has("open_boundary:(0, 10)"), "negative control: missing fence diagnoses the exact open boundary")
	var anchors := layout.anchors.duplicate(true)
	anchors.append(layout.anchor(SPAWN))
	check(_geometry_findings(blocked, anchors).has("duplicate:" + SPAWN), "negative control: duplicate identity is rejected by validator")
	anchors = layout.anchors.duplicate(true)
	anchors[1].cell = Vector2i(-1, -1)
	check(_geometry_findings(blocked, anchors).has("unreachable:zerkov.loot.sawmill.crate.log_racks"), "negative control: out-of-bounds anchor is diagnosed by identity")


func _geometry_findings(solids: Dictionary, anchors: Array[Dictionary]) -> PackedStringArray:
	var findings := PackedStringArray()
	var visited := _flood(solids, layout.anchor(SPAWN).cell)
	var ids: Dictionary = {}
	for row in anchors:
		if ids.has(row.id):
			findings.append("duplicate:" + row.id)
		ids[row.id] = true
		if not visited.has(row.cell) or not visited.has(row.approach_cell):
			findings.append("unreachable:" + row.id)
	for row in layout.routes:
		for cell in _route_cells(row):
			if solids.has(cell) or not visited.has(cell):
				findings.append("blocked_route:" + row.id)
				break
	for cell in layout.cells_in(Rect2i(Vector2i.ZERO, layout.size_cells)):
		if cell.x == 0 or cell.y == 0 or cell.x == layout.size_cells.x - 1 or cell.y == layout.size_cells.y - 1:
			if not solids.has(cell):
				findings.append("open_boundary:" + str(cell))
	return findings


func _anchor_node_snapshot() -> Dictionary:
	var snapshot: Dictionary = {}
	for child in yard.get_node("Anchors").get_children():
		var id := String(child.get_meta("stable_id"))
		check(not snapshot.has(id), "native markers have unique IDs " + id)
		check(child.position == layout.cell_center(layout.anchor(id).cell), "native marker pose " + id)
		snapshot[id] = child.position
	return snapshot


func _route_cells(row: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var points: PackedVector2Array = row.points
	for index in range(1, points.size()):
		var start := Vector2i(points[index - 1])
		var end := Vector2i(points[index])
		if start.x != end.x and start.y != end.y:
			return {}
		var step := Vector2i(signi(end.x - start.x), signi(end.y - start.y))
		var cell := start
		for _distance in range(_manhattan(start, end) + 1):
			for y in range(-1, 2):
				for x in range(-1, 2):
					result[cell + Vector2i(x, y)] = true
			cell += step
	return result


func _flood(solids: Dictionary, start: Vector2i) -> Dictionary:
	var visited: Dictionary = {}
	if solids.has(start):
		return visited
	var queue: Array[Vector2i] = [start]
	visited[start] = true
	var index := 0
	while index < queue.size():
		var current := queue[index]
		index += 1
		for direction in DIRECTIONS:
			var next: Vector2i = current + direction
			if Rect2i(Vector2i.ZERO, layout.size_cells).has_point(next) and not solids.has(next) and not visited.has(next):
				visited[next] = true
				queue.append(next)
	return visited


func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


func _contains_closed(rect: Rect2, point: Vector2) -> bool:
	return point.x >= rect.position.x and point.y >= rect.position.y and point.x <= rect.end.x and point.y <= rect.end.y
