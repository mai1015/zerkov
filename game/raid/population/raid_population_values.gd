class_name RaidPopulationValues
extends RefCounted
## Closed immutable values for one deterministic raid population plan.

const SCHEMA: String = "zerkov.raid.population.v1"
const VERSION: int = 1
const MAX_CONTAINERS: int = 8
const MAX_ITEMS_PER_CONTAINER: int = 8

static func descriptor(plan: Dictionary) -> Dictionary:
	if not valid_plan(plan):
		return {}
	return RaidProgressionValues.freeze({
		"version": VERSION,
		"map_id": String(plan.map_id),
		"seed": int(plan.seed),
		"map_identity": String(plan.map_identity),
		"digest": String(plan.digest),
	})

static func valid_descriptor(value: Variant) -> bool:
	return value is Dictionary and value.size() == 5 \
		and value.get("version") == VERSION \
		and SupplyRunGraph.is_map(String(value.get("map_id", ""))) \
		and RaidProgressionValues.counter(value.get("seed"), 1) \
		and RaidProgressionValues.sha(value.get("map_identity")) \
		and RaidProgressionValues.sha(value.get("digest"))

static func valid_plan(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var plan: Dictionary = value
	if plan.size() != 8 or plan.get("schema") != SCHEMA or plan.get("version") != VERSION \
			or not SupplyRunGraph.is_map(String(plan.get("map_id", ""))) \
			or not RaidProgressionValues.counter(plan.get("seed"), 1) \
			or not RaidProgressionValues.sha(plan.get("map_identity")) \
			or not plan.get("objective_containers") is Array \
			or not plan.get("optional_containers") is Array \
			or not RaidProgressionValues.sha(plan.get("digest")):
		return false
	var objective: Array = plan.objective_containers
	var optional: Array = plan.optional_containers
	if objective.size() != 3 or optional.size() != RaidPopulationCatalog.OPTIONAL_ACTIVE_COUNT \
			or objective.size() + optional.size() > MAX_CONTAINERS:
		return false
	var ids: Dictionary = {}
	var objective_item_count: int = 0
	var expected_objectives := SupplyRunGraph.crates_for(String(plan.map_id))
	for index: int in objective.size():
		var row_value: Variant = objective[index]
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if String(row.get("id", "")) != expected_objectives[index] \
				or not _valid_container(row, true) or ids.has(String(row.id)):
			return false
		ids[String(row.id)] = true
		for item: Dictionary in row.items:
			if item.definition == String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE):
				objective_item_count += 1
	for row_value: Variant in optional:
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		var authored := RaidPopulationCatalog.candidate(String(plan.map_id), String(row.get("id", "")))
		if authored.is_empty() or not _valid_container(row, false) or ids.has(String(row.id)) \
				or String(row.label) != String(authored.label) \
				or String(row.loot_table) != String(authored.table) \
				or String(row.visual) != String(authored.visual) \
				or row.position != [roundi(authored.position.x), roundi(authored.position.y)]:
			return false
		ids[String(row.id)] = true
		for item: Dictionary in row.items:
			if item.definition == String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE):
				return false
	if objective_item_count != 1 or objective[0].items[0].definition \
			!= String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE):
		return false
	var core := plan.duplicate(true)
	core.erase("digest")
	return RaidProgressionValues.digest(core) == String(plan.digest)

static func _valid_container(row: Dictionary, objective: bool) -> bool:
	var position: Variant = row.get("position")
	if row.size() != 7 or typeof(row.get("id")) != TYPE_STRING \
			or String(row.id).is_empty() or typeof(row.get("label")) != TYPE_STRING \
			or String(row.label).is_empty() or row.get("objective") != objective \
			or not position is Array or position.size() != 2 \
			or typeof(position[0]) != TYPE_INT or typeof(position[1]) != TYPE_INT \
			or int(position[0]) < 0 or int(position[1]) < 0 \
			or int(position[0]) > 4096 or int(position[1]) > 4096 \
			or typeof(row.get("loot_table")) != TYPE_STRING \
			or not RaidPopulationCatalog.TABLES.has(String(row.loot_table)) \
			or StringName(row.get("visual", "")) not in [RaidPopulationCatalog.VISUAL_WOOD, RaidPopulationCatalog.VISUAL_MILITARY] \
			or not row.get("items") is Array or row.items.is_empty() \
			or row.items.size() > MAX_ITEMS_PER_CONTAINER:
		return false
	var occupied: Dictionary = {}
	for item_value: Variant in row.items:
		if not item_value is Dictionary:
			return false
		var item: Dictionary = item_value
		if item.size() != 5 or typeof(item.get("definition")) != TYPE_STRING \
				or not RaidPopulationCatalog.ITEM_RULES.has(String(item.definition)) \
				or not RaidProgressionValues.counter(item.get("quantity"), 1) \
				or typeof(item.get("x")) != TYPE_INT or typeof(item.get("y")) != TYPE_INT \
				or typeof(item.get("rotated")) != TYPE_BOOL:
			return false
		var rule := RaidPopulationCatalog.item_rule(String(item.definition))
		var table: Array = RaidPopulationCatalog.table(String(row.loot_table))
		if int(item.quantity) < int(rule.minimum) or int(item.quantity) > int(rule.maximum) \
				or (item.definition != String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE) \
				and not table.has(String(item.definition))):
			return false
		var footprint: Vector2i = rule.footprint
		if bool(item.rotated):
			if not bool(rule.rotate):
				return false
			footprint = Vector2i(footprint.y, footprint.x)
		if item.x < 0 or item.y < 0 or item.x + footprint.x > RaidPopulationCatalog.GRID_SIZE.x \
				or item.y + footprint.y > RaidPopulationCatalog.GRID_SIZE.y:
			return false
		for y: int in range(item.y, item.y + footprint.y):
			for x: int in range(item.x, item.x + footprint.x):
				var cell := Vector2i(x, y)
				if occupied.has(cell):
					return false
				occupied[cell] = true
	return true
