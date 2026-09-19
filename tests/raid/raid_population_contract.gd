extends SceneTree
## Pure deterministic population plan and live authored-point contracts.
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, note: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("RAID_POPULATION_ASSERT: " + note)

func run() -> void:
	for map_id: String in ["sawmill", "northline", "blackwater"]:
		check(RaidPopulationCatalog.validates(map_id), "closed authored candidates " + map_id)
		var objective := _objective_points(map_id)
		var identity := ("population-contract:" + map_id).sha256_text()
		var first := RaidPopulationGenerator.generate(map_id, identity, 41, objective)
		var replay := RaidPopulationGenerator.generate(map_id, identity, 41, objective)
		var changed := RaidPopulationGenerator.generate(map_id, identity, 42, objective)
		check(RaidPopulationValues.valid_plan(first), "valid generated plan " + map_id)
		check(first == replay and first.digest == replay.digest, "same seed exact replay " + map_id)
		check(first.digest != changed.digest, "different seed changes plan " + map_id)
		check(first.objective_containers.size() == 3 and first.optional_containers.size() == 2,
			"guaranteed and bounded container counts " + map_id)
		var supply_count := 0
		var optional_ids: Dictionary = {}
		for row: Dictionary in first.objective_containers:
			for item: Dictionary in row.items:
				if item.definition == String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE):
					supply_count += 1
		for row: Dictionary in first.optional_containers:
			optional_ids[row.id] = true
			for item: Dictionary in row.items:
				check(item.definition != String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE),
					"optional loot cannot contain task objective")
		check(supply_count == 1 and first.objective_containers[0].items[0].definition \
			== String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE), "one guaranteed objective " + map_id)
		check(optional_ids.size() == 2, "unique optional locations " + map_id)
		for candidate: Dictionary in RaidPopulationCatalog.candidates(map_id):
			check(RaidPopulationCatalog.accepts_target(String(candidate.id)),
				"closed optional target vocabulary " + String(candidate.id))
		var descriptor := RaidPopulationValues.descriptor(first)
		check(RaidPopulationValues.valid_descriptor(descriptor), "closed descriptor " + map_id)
		var tampered := first.duplicate(true)
		tampered["digest"] = "0".repeat(64)
		check(not RaidPopulationValues.valid_plan(tampered), "tampered digest rejected " + map_id)
		var foreign := first.duplicate(true)
		foreign.optional_containers[0]["id"] = "zerkov.loot." + map_id + ".optional.foreign"
		check(not RaidPopulationValues.valid_plan(_redigest(foreign)),
			"foreign candidate rejected after recomputing digest " + map_id)
		var moved := first.duplicate(true)
		moved.optional_containers[0].position[0] = int(moved.optional_containers[0].position[0]) + 1
		check(not RaidPopulationValues.valid_plan(_redigest(moved)),
			"candidate coordinate drift rejected after recomputing digest " + map_id)
		var invalid_quantity := first.duplicate(true)
		invalid_quantity.optional_containers[0].items[0]["quantity"] = 0
		check(not RaidPopulationValues.valid_plan(_redigest(invalid_quantity)),
			"invalid item quantity rejected after recomputing digest " + map_id)
		var wrong_objective := first.duplicate(true)
		wrong_objective.objective_containers[0]["id"] = "zerkov.loot." + map_id + ".crate.foreign"
		check(not RaidPopulationValues.valid_plan(_redigest(wrong_objective)),
			"objective vocabulary rejected after recomputing digest " + map_id)
		var other_identity := RaidPopulationGenerator.generate(map_id,
			("other:" + map_id).sha256_text(), 41, objective)
		check(other_identity.digest != first.digest, "map identity binds plan " + map_id)
	check(not RaidPopulationCatalog.accepts_target("zerkov.loot.foreign.optional.path"),
		"foreign optional target rejected")
	check(not RaidGameplayInput.valid_payload(&"interaction",
		{"target_id":"zerkov.loot.foreign.optional.path"}),
		"input codec remains fail closed for arbitrary target")
	check(RaidGameplayInput.valid_payload(&"interaction",
		{"target_id":"zerkov.loot.sawmill.optional.service_cache"}),
		"input codec admits closed optional target")
	_validate_candidate_geometry()
	print("RAID_POPULATION_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

func _redigest(plan: Dictionary) -> Dictionary:
	var core := plan.duplicate(true)
	core.erase("digest")
	plan["digest"] = RaidProgressionValues.digest(core)
	return plan

func _objective_points(map_id: String) -> Array:
	var result: Array = []
	var labels := SupplyRunGraph.crate_titles(map_id)
	for index: int in 3:
		result.append({
			"id": SupplyRunGraph.crates_for(map_id)[index],
			"label": labels[index],
			"position": Vector2(64 + index * 96, 64),
			"table": "mixed",
			"visual": "wood_supply_crate",
		})
	return result

func _validate_candidate_geometry() -> void:
	var sawmill := load("res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	var sawmill_world := ZMovementWorldBuilder.build_from_sawmill_layout(sawmill, 1)
	var sawmill_grid := ZNavigationGrid.bake_from_movement_world(sawmill_world,
		sawmill.size_cells, sawmill.revision, sawmill.level_id)
	_validate_points("sawmill", RaidPopulationCatalog.candidates("sawmill"),
		sawmill_world, sawmill_grid, sawmill.world_bounds())
	for map_id: String in ["northline", "blackwater"]:
		var map := NativeRaidMap.open(map_id)
		check(map != null, "native map population preflight " + map_id)
		if map == null:
			continue
		_validate_points(map_id, RaidPopulationCatalog.candidates(map_id),
			map.build_movement(1), map.grid(), map.bounds())

func _validate_points(map_id: String, points: Array, world: ZMovementWorld2D,
		grid: ZNavigationGrid, bounds: Rect2) -> void:
	check(world != null and grid != null, "population geometry owners " + map_id)
	for row: Dictionary in points:
		var at: Vector2 = row.position
		var cell := ZWorldUnits.godot_to_tile(at)
		check(bounds.has_point(at), "candidate within map " + String(row.id))
		check(cell.ok and grid.is_walkable(cell.vector2i_value), "candidate navigation " + String(row.id))
		check(world.query_placement_px(at, Vector2(12, 12)).get("ok", false),
			"candidate authoritative placement " + String(row.id))
