class_name RaidPopulationGenerator
extends RefCounted
## Deterministic one-shot population generator. It owns no scene or tick state.

const OBJECTIVE_ROLLS: int = 3
const OPTIONAL_ROLLS: int = 4

static func generate(map_id: String, map_identity: String, seed: int,
		objective_points: Array, optional_candidates: Array = []) -> Dictionary:
	if not SupplyRunGraph.is_map(map_id) or not RaidProgressionValues.sha(map_identity) \
			or not RaidProgressionValues.counter(seed, 1) or objective_points.size() != 3:
		return {}
	var candidates := optional_candidates if not optional_candidates.is_empty() \
		else RaidPopulationCatalog.candidates(map_id)
	if candidates.size() < RaidPopulationCatalog.OPTIONAL_ACTIVE_COUNT:
		return {}
	var selected := _select_candidates(candidates, _stream_seed(seed, map_id, map_identity, "locations"))
	if selected.size() != RaidPopulationCatalog.OPTIONAL_ACTIVE_COUNT:
		return {}
	var objective: Array = []
	for index: int in objective_points.size():
		var point: Dictionary = objective_points[index]
		var row := _container_row(point, true, seed, map_id, map_identity, OBJECTIVE_ROLLS,
			index == 0)
		if row.is_empty():
			return {}
		objective.append(row)
	var optional: Array = []
	for point: Dictionary in selected:
		var row := _container_row(point, false, seed, map_id, map_identity, OPTIONAL_ROLLS, false)
		if row.is_empty():
			return {}
		optional.append(row)
	var core := {
		"schema": RaidPopulationValues.SCHEMA,
		"version": RaidPopulationValues.VERSION,
		"map_id": map_id,
		"map_identity": map_identity,
		"seed": seed,
		"objective_containers": objective,
		"optional_containers": optional,
	}
	var digest := RaidProgressionValues.digest(core)
	if digest.is_empty():
		return {}
	core["digest"] = digest
	var result: Dictionary = RaidProgressionValues.freeze(core)
	return result if RaidPopulationValues.valid_plan(result) else {}

static func _select_candidates(candidates: Array, seed: int) -> Array:
	var rows := candidates.duplicate(true)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("id", "")) < String(b.get("id", "")))
	var rng := ZRaidRng.new(seed)
	for index: int in range(rows.size() - 1, 0, -1):
		var other := rng.next_int(index + 1)
		var swap: Variant = rows[index]
		rows[index] = rows[other]
		rows[other] = swap
	return rows.slice(0, RaidPopulationCatalog.OPTIONAL_ACTIVE_COUNT)

static func _container_row(point: Dictionary, objective: bool, base_seed: int,
		map_id: String, map_identity: String, rolls: int, guaranteed_objective: bool) -> Dictionary:
	var id := String(point.get("id", ""))
	var label := String(point.get("label", ""))
	var position: Variant = point.get("position")
	var table_id := String(point.get("table", "mixed"))
	var visual := StringName(point.get("visual", RaidPopulationCatalog.VISUAL_WOOD))
	if id.is_empty() or label.is_empty() or not position is Vector2 or not position.is_finite() \
			or not RaidPopulationCatalog.TABLES.has(table_id):
		return {}
	var occupied: Dictionary = {}
	var items: Array = []
	if guaranteed_objective:
		var guaranteed := _place_item(String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE), 1,
			occupied, ZRaidRng.new(_stream_seed(base_seed, map_id, map_identity, "guaranteed:" + id)))
		if guaranteed.is_empty():
			return {}
		items.append(guaranteed)
	var rng := ZRaidRng.new(_stream_seed(base_seed, map_id, map_identity, "contents:" + id))
	var chosen := _weighted_unique(RaidPopulationCatalog.table(table_id), rolls, rng)
	for definition: String in chosen:
		var rule := RaidPopulationCatalog.item_rule(definition)
		var quantity := int(rule.minimum) + rng.next_int(int(rule.maximum) - int(rule.minimum) + 1)
		var placed := _place_item(definition, quantity, occupied, rng)
		if placed.is_empty():
			return {}
		items.append(placed)
	return RaidProgressionValues.freeze({
		"id": id,
		"label": label,
		"objective": objective,
		"position": [roundi(position.x), roundi(position.y)],
		"loot_table": table_id,
		"visual": String(visual),
		"items": items,
	})

static func _weighted_unique(table: Array, count: int, rng: ZRaidRng) -> Array[String]:
	var available: Array[String] = []
	for value: Variant in table:
		var definition := String(value)
		if RaidPopulationCatalog.ITEM_RULES.has(definition) and not available.has(definition):
			available.append(definition)
	var result: Array[String] = []
	while result.size() < count and not available.is_empty():
		var total: int = 0
		for definition: String in available:
			total += int(RaidPopulationCatalog.ITEM_RULES[definition].weight)
		if total < 1:
			break
		var roll := rng.next_int(total)
		var selected := available[0]
		for definition: String in available:
			roll -= int(RaidPopulationCatalog.ITEM_RULES[definition].weight)
			if roll < 0:
				selected = definition
				break
		result.append(selected)
		available.erase(selected)
	return result

static func _place_item(definition: String, quantity: int, occupied: Dictionary,
		rng: ZRaidRng) -> Dictionary:
	var rule := RaidPopulationCatalog.item_rule(definition)
	if rule.is_empty():
		return {}
	var orientations: Array[bool] = [false]
	if bool(rule.rotate) and Vector2i(rule.footprint).x != Vector2i(rule.footprint).y:
		orientations.append(true)
		if rng.next_int(2) == 1:
			orientations.reverse()
	for rotated: bool in orientations:
		var footprint: Vector2i = rule.footprint
		if rotated:
			footprint = Vector2i(footprint.y, footprint.x)
		for y: int in range(RaidPopulationCatalog.GRID_SIZE.y - footprint.y + 1):
			for x: int in range(RaidPopulationCatalog.GRID_SIZE.x - footprint.x + 1):
				if not _fits(Vector2i(x, y), footprint, occupied):
					continue
				for cy: int in range(y, y + footprint.y):
					for cx: int in range(x, x + footprint.x):
						occupied[Vector2i(cx, cy)] = true
				return {"definition":definition, "quantity":quantity,
					"x":x, "y":y, "rotated":rotated}
	return {}

static func _fits(origin: Vector2i, footprint: Vector2i, occupied: Dictionary) -> bool:
	for y: int in range(origin.y, origin.y + footprint.y):
		for x: int in range(origin.x, origin.x + footprint.x):
			if occupied.has(Vector2i(x, y)):
				return false
	return true

static func _stream_seed(seed: int, map_id: String, map_identity: String, stream: String) -> int:
	var digest := (RaidPopulationValues.SCHEMA + ":" + str(RaidPopulationValues.VERSION) \
		+ ":" + map_id + ":" + map_identity + ":" + str(seed) + ":" + stream).sha256_text()
	return 1 + int(digest.substr(0, 7).hex_to_int())
