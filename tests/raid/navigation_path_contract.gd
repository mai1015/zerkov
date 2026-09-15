extends SceneTree
## Headless contract for task 3.9: authored navigation data and the
## deterministic path-request seam, with pathfinding results kept outside
## canonical add-on state.
## Run with:
##   godot --headless --path . --resolution 1920x1080 --audio-driver Dummy
##     --script res://tests/raid/navigation_path_contract.gd

const LAYOUT_PATH := "res://game/world/sawmill/sawmill_yard_layout.tres"
const SPAWN_ID := "zerkov.spawn.sawmill.west_service"
const EXTRACT_ID := "zerkov.extract.sawmill.road_gate"
const NAV_SOURCES := [
	"res://game/world/navigation/z_navigation_grid.gd",
	"res://game/world/navigation/z_navigation_path_result.gd",
	"res://game/world/navigation/z_navigation_astar.gd",
	"res://game/world/navigation/z_navigation_path_service.gd",
]
## Engine navigation maps/agents, nondeterministic timing, and every
## canonical-state writer are banned from the game-owned seam sources.
const BANNED_SOURCE_TOKENS := [
	"NavigationServer", "NavigationAgent", "NavigationRegion2D", "NavigationMap",
	"get_simple_path", "nav_rid", "randf", "Time.get_", "await ",
	"_physics_process", "_process(", "delta", "RaidAuthority", "enqueue_intent",
	"register_phase_handler", "InventoryAuthority", "WeaponAuthority",
	"GameplayAbility", "CommonVision", "LevelTask", "set_meta", "add_child",
	"preload(", "res://", "ResourceLoader",
]
const SYNTHETIC_GENERATION := 7

var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("NAVIGATION_PATH_CONTRACT: " + message)


func run() -> void:
	_test_source_purity()
	_test_grid_bake_from_authored_layout()
	_test_blocking_agrees_with_collision()
	_test_straight_open_path()
	_test_path_around_authored_wall()
	_test_spawn_to_extraction()
	_test_blocked_start_goal_and_out_of_bounds()
	_test_unreachable_enclosed_goal()
	_test_budget_exhaustion()
	_test_determinism_two_independent_runs()
	_test_cache_and_revision_invalidation()
	_test_stale_revision_and_seal_mutate_nothing()
	_test_requests_leave_state_digest_unchanged()
	print("NAVIGATION_PATH_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


# --- Fixtures -------------------------------------------------------------


func _sawmill_layout() -> Resource:
	return load(LAYOUT_PATH) as Resource


func _sawmill_grid() -> ZNavigationGrid:
	var grid := ZNavigationGrid.bake_from_sawmill_layout(_sawmill_layout())
	if grid == null:
		check(false, "sawmill grid bake failed: %s" % String(ZNavigationGrid.last_error))
	return grid


## Synthetic fixture: a movement world built through task 3.6's public API,
## so even synthetic navigation data has no second blocking truth.
func _synthetic_world(size_cells: Vector2i, colliders: Array) -> ZMovementWorld2D:
	var world := ZMovementWorld2D.new()
	var configured := world.configure(
		Rect2(Vector2.ZERO, Vector2(size_cells * ZWorldUnits.SOURCE_TILE_PIXELS)),
		SYNTHETIC_GENERATION,
		"fixture.nav.grid"
	)
	check(configured, "synthetic movement world configures")
	for row in colliders:
		var added := world.add_static_collider_cells(
			String(row[0]), row[1], SYNTHETIC_GENERATION
		)
		check(added, "synthetic collider injected: %s" % String(row[0]))
	return world


func _synthetic_grid(
	size_cells: Vector2i, colliders: Array, revision: int
) -> ZNavigationGrid:
	return ZNavigationGrid.bake_from_movement_world(
		_synthetic_world(size_cells, colliders), size_cells, revision,
		"fixture.nav.grid"
	)


func _service_for(grid: ZNavigationGrid) -> ZNavigationPathService:
	var service := ZNavigationPathService.new()
	check(service.configure(grid, grid.revision()), "service binds baked grid")
	return service


## Independent probe of task 3.6 collision: can the navigation body stand at
## this cell centre on this movement world?
func _movement_probe_blocked(world: ZMovementWorld2D, cell: Vector2i) -> bool:
	var center := ZWorldUnits.tile_center_to_godot(cell)
	var probe_id := ZEntityId.from_parts(
		PackedStringArray(["navprobe", "c%d_%d" % [cell.x, cell.y]])
	)
	var registered := world.register_actor(
		probe_id, center.vector2_value,
		ZNavigationGrid.NAVIGATION_BODY_HALF_EXTENTS_PX, world.generation()
	)
	if registered:
		return false
	var reason := String(world.last_error)
	check(
		reason == "actor_spawn_blocked" or reason == "actor_out_of_bounds",
		"unexpected probe rejection at %s: %s" % [str(cell), reason]
	)
	return true


func _is_valid_path(
	grid: ZNavigationGrid, result: ZNavigationPathResult,
	start: Vector2i, goal: Vector2i
) -> void:
	check(result.is_ok(), "path outcome is ok, got %s" % String(result.outcome))
	if not result.is_ok() or result.cells.is_empty():
		return
	check(result.cells.size() >= 1, "ok result carries a non-empty cell path")
	check(result.cells[0] == start, "path begins at the start cell")
	check(result.cells[result.cells.size() - 1] == goal, "path ends at the goal cell")
	var cost := 0
	for index in result.cells.size():
		var cell: Vector2i = result.cells[index]
		check(grid.is_walkable(cell), "path cell %s is walkable" % str(cell))
		if index == 0:
			continue
		var previous: Vector2i = result.cells[index - 1]
		var step := cell - previous
		check(
			absi(step.x) <= 1 and absi(step.y) <= 1 and (step.x != 0 or step.y != 0),
			"path step %s is a single-cell move" % str(step)
		)
		cost += 14 if step.x != 0 and step.y != 0 else 10
	check(cost == result.cost, "reported cost %d matches the integer step costs %d"
			% [result.cost, cost])


## Independent uniform-cost oracle (no heuristic; deterministic O(n^2)
## selection with explicit (cost, y, x) ordering) used to cross-check A*
## optimality. Returns -1 when the goal is unreachable.
func _dijkstra_cost(grid: ZNavigationGrid, start: Vector2i, goal: Vector2i) -> int:
	if not grid.is_walkable(start) or not grid.is_walkable(goal):
		return -1
	var dist := {start: 0}
	var done := {}
	var size := grid.size_cells()
	var steps := [
		[Vector2i(1, 0), 10], [Vector2i(-1, 0), 10],
		[Vector2i(0, 1), 10], [Vector2i(0, -1), 10],
		[Vector2i(1, 1), 14], [Vector2i(1, -1), 14],
		[Vector2i(-1, 1), 14], [Vector2i(-1, -1), 14],
	]
	while true:
		var best := Vector2i(-1, -1)
		var best_cost := -1
		for y in size.y:
			for x in size.x:
				var cell := Vector2i(x, y)
				if done.has(cell) or not dist.has(cell):
					continue
				var cell_cost: int = dist[cell]
				if best_cost < 0 or cell_cost < best_cost:
					best_cost = cell_cost
					best = cell
		if best == Vector2i(-1, -1):
			return -1
		done[best] = true
		if best == goal:
			return best_cost
		for pair in steps:
			var step: Vector2i = pair[0]
			var next := best + step
			if not grid.is_walkable(next):
				continue
			if step.x != 0 and step.y != 0:
				if not grid.is_walkable(Vector2i(best.x + step.x, best.y)) \
						or not grid.is_walkable(Vector2i(best.x, best.y + step.y)):
					continue
			var candidate := best_cost + int(pair[1])
			if not dist.has(next) or int(dist[next]) > candidate:
				dist[next] = candidate
	return -1


# --- Tests ----------------------------------------------------------------


func _test_source_purity() -> void:
	for source_path in NAV_SOURCES:
		var script := load(source_path) as GDScript
		check(script != null, "navigation source loads: %s" % source_path)
		if script == null:
			continue
		var source := script.source_code
		for token in BANNED_SOURCE_TOKENS:
			check(
				not source.contains(token),
				"%s must not contain '%s'" % [source_path, token]
			)
		var instance = script.new()
		check(instance is RefCounted, "%s is a pure RefCounted module" % source_path)
	var grid := ZNavigationGrid.new()
	check(not grid.is_baked(), "fresh grid starts unbaked")
	var service := ZNavigationPathService.new()
	check(not service.is_configured(), "fresh service starts unconfigured")
	var stale := service.request_path(Vector2i(1, 1), Vector2i(2, 2), 0)
	check(
		stale.outcome == ZNavigationPathResult.OUTCOME_STALE_REVISION,
		"unconfigured service returns stale_revision"
	)
	check(service.cache_entry_count() == 0, "unconfigured service has no cache")


func _test_grid_bake_from_authored_layout() -> void:
	var layout := _sawmill_layout()
	var grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	check(grid != null, "authored layout bakes a navigation grid")
	if grid == null:
		return
	check(grid.is_baked(), "baked grid reports baked")
	check(grid.revision() == int(layout.get("revision")),
		"grid revision is the authored layout revision")
	check(grid.size_cells() == Vector2i(40, 20), "grid is the authored 40x20 cell grid")
	check(grid.level_id() == "zerkov.level.sawmill_yard", "grid carries the level id")
	check(grid.source_digest() != "", "grid records its collision source digest")
	check(grid.blocked_cell_count() > 0, "authored obstacles block cells")
	check(grid.blocked_cell_count() + grid.walkable_cell_count() == 800,
		"blocked + walkable equals the full 800 authored cells")
	check(grid.digest() != "", "grid advisory digest is available")

	var grid_b := ZNavigationGrid.bake_from_sawmill_layout(layout)
	check(grid_b != null and grid_b.digest() == grid.digest(),
		"two independent bakes of unchanged authored data are identical")

	# Inspectable, explicitly ordered blocked set.
	var blocked := grid.blocked_cells()
	check(blocked.size() == grid.blocked_cell_count(), "blocked set size matches")
	var sorted := true
	for index in range(1, blocked.size()):
		var a: Vector2i = blocked[index - 1]
		var b: Vector2i = blocked[index]
		if a.y > b.y or (a.y == b.y and a.x >= b.x):
			sorted = false
	check(sorted, "blocked cells are ordered (y, then x), never dict order")

	# Spot cells against the authored structures.
	check(grid.is_blocked(Vector2i(0, 0)), "north fence corner cell is blocked")
	check(grid.is_blocked(Vector2i(17, 4)), "mill west wall cell is blocked")
	check(grid.is_walkable(Vector2i(1, 1)),
		"Canopy-layer trees do not block navigation")
	check(grid.is_walkable(Vector2i(21, 6)), "saw-house doorway cell is walkable")
	check(grid.is_walkable(Vector2i(4, 15)), "player spawn cell is walkable")
	check(not grid.has_cell(Vector2i(40, 0)), "x beyond the authored grid is unknown")
	check(not grid.has_cell(Vector2i(0, 20)), "y beyond the authored grid is unknown")
	check(not grid.has_cell(Vector2i(-1, 0)), "negative cells are unknown")

	# Bake failure modes fail closed.
	check(ZNavigationGrid.bake_from_sawmill_layout(null) == null
			and ZNavigationGrid.last_error == &"layout_missing",
		"bake rejects a missing layout")
	check(ZNavigationGrid.bake_from_sawmill_layout(Resource.new()) == null
			and ZNavigationGrid.last_error == &"layout_api_invalid",
		"bake rejects a resource without the layout API")
	check(ZNavigationGrid.bake_from_movement_world(null, Vector2i(4, 4), 1) == null
			and ZNavigationGrid.last_error == &"movement_world_missing",
		"bake rejects a missing movement world")
	var unconfigured := ZMovementWorld2D.new()
	check(ZNavigationGrid.bake_from_movement_world(unconfigured, Vector2i(4, 4), 1) == null
			and ZNavigationGrid.last_error == &"movement_world_unconfigured",
		"bake rejects an unconfigured movement world")


func _test_blocking_agrees_with_collision() -> void:
	var layout := _sawmill_layout()
	var grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	check(grid != null, "agreement bake exists")
	if grid == null:
		return

	# Cell-for-cell agreement with an independently built task 3.6 world.
	var world := ZMovementWorldBuilder.build_from_sawmill_layout(layout, 9)
	check(world != null and world.is_configured(),
		"independent movement world builds from the same layout")
	var mismatched_cells := 0
	for y in 20:
		for x in 40:
			var cell := Vector2i(x, y)
			var collision_blocked := _movement_probe_blocked(world, cell)
			if collision_blocked != grid.is_blocked(cell):
				mismatched_cells += 1
	check(mismatched_cells == 0,
		"navigation blocking agrees cell-for-cell with 3.6 collision (%d mismatches)"
			% mismatched_cells)

	# Cell-for-cell agreement with the authored Obstacles structures the
	# movement world itself was built from.
	var expected := {}
	for row in layout.structures:
		if String(row.get("layer", "")) == "Obstacles":
			for cell in layout.cells_in(row.rect):
				expected[cell] = true
	var structure_mismatches := 0
	for y in 20:
		for x in 40:
			var cell := Vector2i(x, y)
			if expected.has(cell) != grid.is_blocked(cell):
				structure_mismatches += 1
	check(structure_mismatches == 0,
		"navigation blocking equals the authored Obstacles union (%d mismatches)"
			% structure_mismatches)
	check(grid.blocked_cell_count() == expected.size(),
		"blocked cell count equals the authored Obstacles cell count")

	# Synthetic agreement: a directly constructed movement world (not via the
	# builder) bakes to exactly its blocked cells and nothing else.
	var synthetic := _synthetic_grid(
		Vector2i(12, 6),
		[["fixture.nav.block", Rect2i(10, 3, 2, 2)]],
		3
	)
	check(synthetic != null, "synthetic bake exists")
	if synthetic != null:
		var expected_synth := {}
		for cell in [
			Vector2i(10, 3), Vector2i(11, 3), Vector2i(10, 4), Vector2i(11, 4),
		]:
			expected_synth[cell] = true
		var synth_mismatches := 0
		for y in 6:
			for x in 12:
				var cell := Vector2i(x, y)
				if expected_synth.has(cell) != synthetic.is_blocked(cell):
					synth_mismatches += 1
		check(synth_mismatches == 0,
			"synthetic grid blocks exactly the collision rect cells (%d mismatches)"
				% synth_mismatches)


func _test_straight_open_path() -> void:
	var grid := _synthetic_grid(Vector2i(12, 6), [], 2)
	var service := _service_for(grid)
	var start := Vector2i(1, 2)
	var goal := Vector2i(10, 2)
	var expected: Array[Vector2i] = []
	for x in range(1, 11):
		expected.append(Vector2i(x, 2))
	var result := service.request_path(start, goal, 2)
	check(result.outcome == ZNavigationPathResult.OUTCOME_OK,
		"straight open path outcome is ok")
	check(result.cells == expected,
		"straight open path is the exact straight cell line")
	check(result.cost == 90,
		"straight open path cost is the integer orth sum 90")
	check(result.expanded_nodes == 10,
		"straight open path expands only the corridor cells")
	check(result.digest() != "", "straight path digests")
	check(_dijkstra_cost(grid, start, goal) == result.cost,
		"independent uniform-cost oracle agrees on the straight path cost")

	var same_cell := service.request_path(Vector2i(5, 3), Vector2i(5, 3), 2)
	check(same_cell.outcome == ZNavigationPathResult.OUTCOME_OK
			and same_cell.cells == [Vector2i(5, 3)] and same_cell.cost == 0,
		"start == goal returns the single-cell zero-cost path")


func _test_path_around_authored_wall() -> void:
	# Synthetic authored wall with one opening: exact hand-computed optimum.
	var walled := _synthetic_grid(
		Vector2i(7, 7),
		[["fixture.nav.wall_column", Rect2i(3, 0, 1, 6)]],
		4
	)
	var walled_service := _service_for(walled)
	var wall_start := Vector2i(1, 3)
	var wall_goal := Vector2i(5, 3)
	var wall_result := walled_service.request_path(wall_start, wall_goal, 4)
	_is_valid_path(walled, wall_result, wall_start, wall_goal)
	var avoided_wall := true
	for cell in wall_result.cells:
		if cell.x == 3 and cell.y <= 5:
			avoided_wall = false
	check(avoided_wall, "path routes around the wall, never through it")
	check(wall_result.cost == 88,
		"wall detour cost is the hand-computed optimum 88")
	check(_dijkstra_cost(walled, wall_start, wall_goal) == 88,
		"independent uniform-cost oracle agrees on the wall detour optimum")

	# Real authored geometry: west of the mill wall into the roofless house
	# forces the authored three-cell south doorway.
	var layout := _sawmill_layout()
	var grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var service := _service_for(grid)
	var start := Vector2i(15, 4)
	var goal := Vector2i(21, 4)
	var result := service.request_path(start, goal, grid.revision())
	_is_valid_path(grid, result, start, goal)
	var used_doorway := false
	for cell in result.cells:
		if cell.y == 6 and cell.x >= 20 and cell.x <= 22:
			used_doorway = true
	check(used_doorway, "path crosses the authored saw-house doorway at y=6")
	check(result.cost > ZNavigationAStar.heuristic(start, goal),
		"authored wall forces a detour strictly above the octile lower bound")
	check(result.cost == _dijkstra_cost(grid, start, goal),
		"A* cost equals the independent uniform-cost optimum on the real layout")


func _test_spawn_to_extraction() -> void:
	var layout := _sawmill_layout()
	var grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var service := _service_for(grid)
	var spawn_marker := layout.marker(SPAWN_ID) as ZSpawnMarker
	var extract_marker := layout.marker(EXTRACT_ID) as ZExtractionMarker
	check(spawn_marker != null, "typed spawn marker resolves from task 3.11")
	check(extract_marker != null, "typed extract marker resolves from task 3.11")
	if spawn_marker == null or extract_marker == null:
		return
	var result := service.request_path(
		spawn_marker.cell, extract_marker.cell, grid.revision()
	)
	_is_valid_path(grid, result, spawn_marker.cell, extract_marker.cell)
	check(result.cells.size() < 64,
		"spawn -> extract path stays within bounded canonical size")
	check(result.cost == _dijkstra_cost(grid, spawn_marker.cell, extract_marker.cell),
		"spawn -> extract is the optimal path on the real Sawmill layout")
	check(not result.digest().is_empty(),
		"spawn -> extract digests through ZCanonicalValue.sha256")

	# Every extraction zone cell is reachable from the spawn.
	for cell in layout.cells_in(extract_marker.zone_cells):
		var zone_result := service.request_path(
			spawn_marker.cell, cell, grid.revision()
		)
		check(zone_result.is_ok(),
			"extraction zone cell %s is reachable from spawn" % str(cell))

	# Every deterministically derived patrol waypoint is on walkable data.
	for patrol in layout.patrol_markers():
		check(grid.is_walkable(patrol.cell),
			"patrol waypoint %s is walkable" % String(patrol.marker_id))
		check(grid.is_walkable(patrol.approach_cell),
			"patrol approach %s is walkable" % String(patrol.marker_id))


func _test_blocked_start_goal_and_out_of_bounds() -> void:
	var layout := _sawmill_layout()
	var grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var service := _service_for(grid)
	var walkable := Vector2i(4, 15)

	var blocked_start := service.request_path(
		Vector2i(0, 0), walkable, grid.revision()
	)
	check(blocked_start.outcome == ZNavigationPathResult.OUTCOME_START_BLOCKED,
		"blocked start (north fence) returns start_blocked")
	check(blocked_start.cells.is_empty(), "blocked start carries no cells")
	check(service.last_error == &"start_blocked",
		"service records the typed diagnostic")

	var blocked_goal := service.request_path(
		walkable, Vector2i(17, 4), grid.revision()
	)
	check(blocked_goal.outcome == ZNavigationPathResult.OUTCOME_GOAL_BLOCKED,
		"blocked goal (mill west wall) returns goal_blocked")
	check(blocked_goal.cells.is_empty(), "blocked goal carries no cells")

	var both_blocked := service.request_path(
		Vector2i(0, 0), Vector2i(17, 4), grid.revision()
	)
	check(both_blocked.outcome == ZNavigationPathResult.OUTCOME_START_BLOCKED,
		"blocked start takes precedence over blocked goal")

	var goal_oob := service.request_path(walkable, Vector2i(40, 10), grid.revision())
	check(goal_oob.outcome == ZNavigationPathResult.OUTCOME_OUT_OF_BOUNDS,
		"goal beyond the authored grid returns out_of_bounds")
	var start_oob := service.request_path(Vector2i(-1, 3), walkable, grid.revision())
	check(start_oob.outcome == ZNavigationPathResult.OUTCOME_OUT_OF_BOUNDS,
		"negative start returns out_of_bounds")
	var oob_over_blocked := service.request_path(
		Vector2i(0, 20), Vector2i(0, 0), grid.revision()
	)
	check(oob_over_blocked.outcome == ZNavigationPathResult.OUTCOME_OUT_OF_BOUNDS,
		"out-of-bounds takes precedence over blocked cells")


func _test_unreachable_enclosed_goal() -> void:
	var grid := _synthetic_grid(
		Vector2i(9, 9),
		[
			["fixture.nav.ring_north", Rect2i(3, 3, 3, 1)],
			["fixture.nav.ring_south", Rect2i(3, 5, 3, 1)],
			["fixture.nav.ring_west", Rect2i(3, 4, 1, 1)],
			["fixture.nav.ring_east", Rect2i(5, 4, 1, 1)],
		],
		3
	)
	check(grid != null, "enclosing-ring bake exists")
	if grid == null:
		return
	var expected_synth := {}
	for cell in [
		Vector2i(3, 3), Vector2i(4, 3), Vector2i(5, 3),
		Vector2i(3, 4), Vector2i(5, 4),
		Vector2i(3, 5), Vector2i(4, 5), Vector2i(5, 5),
	]:
		expected_synth[cell] = true
	var synth_mismatches := 0
	for y in 9:
		for x in 9:
			var cell := Vector2i(x, y)
			if expected_synth.has(cell) != grid.is_blocked(cell):
				synth_mismatches += 1
	check(synth_mismatches == 0,
		"enclosing ring blocks exactly its cells; the enclosed goal stays walkable (%d mismatches)"
			% synth_mismatches)
	var enclosed := _service_for(grid)
	var unreachable := enclosed.request_path(Vector2i(1, 1), Vector2i(4, 4), 3)
	check(unreachable.outcome == ZNavigationPathResult.OUTCOME_UNREACHABLE,
		"fully enclosed walkable goal is unreachable")
	check(unreachable.cells.is_empty(),
		"unreachable result carries no cells")
	check(unreachable.expanded_nodes > 0,
		"unreachable result still reports its bounded work")
	check(enclosed.request_path(Vector2i(1, 1), Vector2i(4, 4), 3).outcome
			== ZNavigationPathResult.OUTCOME_UNREACHABLE,
		"unreachable result is not cached")


func _test_budget_exhaustion() -> void:
	var grid := _synthetic_grid(Vector2i(40, 6), [], 11)
	var service := _service_for(grid)
	var start := Vector2i(1, 3)
	var goal := Vector2i(38, 3)
	var full := service.request_path(start, goal, 11)
	check(full.is_ok(), "long corridor path succeeds with the default budget")
	var tight := service.request_path(start, goal, 11, full.expanded_nodes)
	check(tight.is_ok() and tight.digest() == full.digest(),
		"a budget that exactly covers the search returns the identical path")
	var short := service.request_path(start, goal, 11, full.expanded_nodes - 1)
	check(short.outcome == ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED,
		"one node under the requirement returns budget_exhausted")
	check(short.expanded_nodes == full.expanded_nodes - 1,
		"exhausted request expanded exactly its budget of nodes")
	check(short.cells.is_empty(), "exhausted result carries no partial cells")
	var zero := service.request_path(start, goal, 11, 0)
	check(zero.outcome == ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED
			and zero.expanded_nodes == 0,
		"zero budget performs no work and returns budget_exhausted")
	var negative := service.request_path(start, goal, 11, -5)
	check(negative.outcome == ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED,
		"negative budget is refused as budget_exhausted")
	check(service.request_path(start, goal, 11).is_ok(),
		"an exhausted request never poisons a later full-budget request")


func _test_determinism_two_independent_runs() -> void:
	var layout := _sawmill_layout()
	var spawn: Vector2i = layout.marker(SPAWN_ID).cell
	var extract: Vector2i = layout.marker(EXTRACT_ID).cell
	var crate: Vector2i = layout.marker("zerkov.loot.sawmill.crate.saw_house").cell

	var grid_a := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var grid_b := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var service_a := _service_for(grid_a)
	var service_b := _service_for(grid_b)
	check(grid_a.digest() == grid_b.digest(),
		"independent bakes produce identical grid digests")

	var a_spawn_extract := service_a.request_path(spawn, extract, grid_a.revision())
	var b_spawn_extract := service_b.request_path(spawn, extract, grid_b.revision())
	check(a_spawn_extract.is_ok() and b_spawn_extract.is_ok(),
		"both independent runs resolve spawn -> extract")
	check(a_spawn_extract.digest() == b_spawn_extract.digest(),
		"identical ZCanonicalValue digest across two independent runs")
	check(a_spawn_extract.cells == b_spawn_extract.cells,
		"identical cell sequence across two independent runs")
	check(a_spawn_extract.expanded_nodes == b_spawn_extract.expanded_nodes,
		"identical expansion count across two independent runs")
	check(not a_spawn_extract.digest().is_empty(),
		"path digest is a real bounded canonical digest")

	service_a.invalidate_cache(grid_a.revision())
	var recomputed := service_a.request_path(spawn, extract, grid_a.revision())
	check(recomputed.digest() == a_spawn_extract.digest() and not recomputed.cached,
		"recomputation after cache invalidation returns the identical digest")

	# Request order independence: interleaving other requests changes nothing.
	var a_crate := service_a.request_path(crate, extract, grid_a.revision())
	var a_again := service_a.request_path(spawn, extract, grid_a.revision())
	check(a_again.digest() == a_spawn_extract.digest(),
		"the same request returns the same path after other interleaved requests")
	var b_again := service_b.request_path(crate, extract, grid_b.revision())
	check(a_crate.digest() == b_again.digest(),
		"interleaved request digests match across runs too")


func _test_cache_and_revision_invalidation() -> void:
	var grid := _synthetic_grid(Vector2i(5, 5), [], 5)
	var service := _service_for(grid)
	var result := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 5)
	check(result.is_ok() and not result.cached, "first request computes fresh")
	check(service.cache_entry_count() == 1, "ok result is cached")
	var hit := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 5)
	check(hit.cached, "second identical request is served from the cache")
	check(hit.digest() == result.digest(),
		"cache hit digests identically to the fresh computation")
	check(hit.cells == result.cells, "cache hit returns identical cells")

	check(service.invalidate_cache(5), "explicit invalidation succeeds")
	check(service.cache_entry_count() == 0, "invalidation drops every entry")
	var fresh := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 5)
	check(fresh.is_ok() and not fresh.cached, "post-invalidation request recomputes")
	check(fresh.digest() == result.digest(), "recomputed digest is unchanged")
	check(not service.invalidate_cache(4), "invalidation with a stale revision fails")

	# Rebinding under a new revision hard-clears the cache; old entries can
	# never be served, and stale requests are refused.
	var rebaked := _synthetic_grid(Vector2i(5, 5), [], 6)
	check(service.configure(rebaked, 6), "service rebinds under a new revision")
	check(service.cache_entry_count() == 0, "rebind hard-clears the cache")
	var stale_after_rebind := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 5)
	check(stale_after_rebind.outcome == ZNavigationPathResult.OUTCOME_STALE_REVISION,
		"request carrying the previous revision returns stale_revision")
	check(service.request_path(Vector2i(0, 0), Vector2i(4, 4), 6).is_ok(),
		"request carrying the current revision succeeds after rebind")

	# Same-revision rebinding is refused so entries can never outlive a grid.
	var service_b := ZNavigationPathService.new()
	var grid_five := _synthetic_grid(Vector2i(4, 4), [], 5)
	check(service_b.configure(grid_five, 5), "fresh service binds revision 5")
	check(not service_b.configure(_synthetic_grid(Vector2i(4, 4), [], 5), 5)
			and service_b.last_error == &"revision_unchanged",
		"rebinding the same revision is refused")
	check(not service_b.configure(grid_five, 4)
			and service_b.last_error == &"revision_mismatch",
		"binding a revision the grid does not carry is refused")
	check(not service_b.configure(null, 6) and service_b.last_error == &"grid_missing",
		"binding a missing grid is refused")

	# Bounded FIFO eviction keeps the cache deterministic in size.
	var wide := _synthetic_grid(Vector2i(40, 6), [], 21)
	var bulk := _service_for(wide)
	for y_value in [1, 4]:
		var y := int(y_value)
		for x in 40:
			bulk.request_path(Vector2i(0, 0), Vector2i(x, y), 21)
	check(bulk.cache_entry_count() == ZNavigationPathService.MAX_CACHE_ENTRIES,
		"cache holds at most MAX_CACHE_ENTRIES entries")


func _test_stale_revision_and_seal_mutate_nothing() -> void:
	var grid := _synthetic_grid(Vector2i(5, 5), [], 9)
	var service := _service_for(grid)
	var kept := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 9)
	check(kept.is_ok(), "pre-stale request succeeds")
	check(service.cache_entry_count() == 1, "pre-stale cache holds one entry")

	var stale := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 8)
	check(stale.outcome == ZNavigationPathResult.OUTCOME_STALE_REVISION,
		"stale revision returns stale_revision")
	check(stale.cells.is_empty() and stale.cost == 0,
		"stale result carries no path and no cost")
	check(stale.revision == 8,
		"stale result reports the revision the caller presented")
	check(service.cache_entry_count() == 1,
		"stale request mutated no cache entry")
	var negative_revision := service.request_path(Vector2i(0, 0), Vector2i(4, 4), -1)
	check(negative_revision.outcome == ZNavigationPathResult.OUTCOME_STALE_REVISION,
		"negative revision returns stale_revision")
	check(not service.invalidate_cache(8), "stale invalidation mutates nothing")
	check(service.cache_entry_count() == 1, "cache untouched by stale invalidation")

	# Teardown: every later request is inert.
	check(service.seal(9), "service seals under the current revision")
	check(service.is_sealed(), "service reports sealed")
	var after_seal := service.request_path(Vector2i(0, 0), Vector2i(4, 4), 9)
	check(after_seal.outcome == ZNavigationPathResult.OUTCOME_STALE_REVISION,
		"request after seal returns stale_revision")
	check(after_seal.cells.is_empty(), "sealed request carries no cells")
	check(service.cache_entry_count() == 0, "seal drops the derived cache")
	check(not service.seal(8), "sealing with a stale revision fails")
	check(not service.configure(grid, 10),
		"a sealed service cannot be reconfigured")


func _test_requests_leave_state_digest_unchanged() -> void:
	var raid := ZRaidId.from_parts(PackedStringArray(["fixture", "nav", "raid"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid, &"nav_profile", &"player")
	check(admission.is_usable(), "offline session admission is usable")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 709), "authority configures")
	var generation := authority.generation()
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"authority activates")
	check(authority.advance_one(generation), "authority advances a first tick")
	check(authority.advance_one(generation), "authority advances a second tick")

	var layout := _sawmill_layout()
	var spawn: Vector2i = layout.marker(SPAWN_ID).cell
	var extract: Vector2i = layout.marker(EXTRACT_ID).cell
	var grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	var service := _service_for(grid)

	var digest_before := authority.state_digest()
	check(not digest_before.is_empty(), "canonical raid digest is available")

	# A burst of fresh, cached, invalid, exhausted and rebuilt requests.
	for index in 6:
		var result := service.request_path(spawn, extract, grid.revision())
		check(result.is_ok(), "digest-probe request %d resolves" % index)
		service.invalidate_cache(grid.revision())
	var blocked_start := service.request_path(Vector2i(0, 0), extract, grid.revision())
	check(blocked_start.outcome == ZNavigationPathResult.OUTCOME_START_BLOCKED,
		"digest-probe blocked start rejected")
	var out_of_bounds := service.request_path(spawn, Vector2i(40, 0), grid.revision())
	check(out_of_bounds.outcome == ZNavigationPathResult.OUTCOME_OUT_OF_BOUNDS,
		"digest-probe out-of-bounds rejected")
	var exhausted := service.request_path(spawn, extract, grid.revision(), 2)
	check(exhausted.outcome == ZNavigationPathResult.OUTCOME_BUDGET_EXHAUSTED,
		"digest-probe exhausted request rejected")
	var stale := service.request_path(spawn, extract, grid.revision() + 5)
	check(stale.outcome == ZNavigationPathResult.OUTCOME_STALE_REVISION,
		"digest-probe stale revision rejected")

	# Full cache rebuild: re-bake the grid and refill the cache.
	var rebuilt_grid := ZNavigationGrid.bake_from_sawmill_layout(layout)
	check(rebuilt_grid.digest() == grid.digest(),
		"rebuilt grid digest equals the original bake")
	var rebuilt_service := ZNavigationPathService.new()
	check(rebuilt_service.configure(rebuilt_grid, rebuilt_grid.revision()),
		"rebuilt service binds")
	check(rebuilt_service.request_path(spawn, extract, rebuilt_grid.revision()).is_ok(),
		"rebuilt service resolves")
	check(rebuilt_service.cache_entry_count() == 1, "rebuilt cache refilled")

	var digest_after := authority.state_digest()
	check(digest_after == digest_before,
		"issuing path requests leaves RaidAuthority.state_digest() bit-identical")

	# Liveness: the digest really tracks canonical state, it is not constant.
	check(authority.advance_one(generation), "authority advances a third tick")
	check(authority.state_digest() != digest_after,
		"a real canonical mutation changes the digest")

	check(authority.teardown(generation), "authority tears down")
	var digest_torn_down := authority.state_digest()
	check(digest_torn_down != digest_before,
		"teardown is a canonical state change the digest observes")
