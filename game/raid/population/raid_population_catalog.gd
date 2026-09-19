class_name RaidPopulationCatalog
extends RefCounted
## Closed authored candidate points and loot rules. Geometry remains authored by
## each map; these are optional population anchors validated by contracts and again
## against the live movement world before interaction registration.

const OPTIONAL_ACTIVE_COUNT: int = 2
const GRID_SIZE := Vector2i(8, 6)
const VISUAL_WOOD: StringName = &"wood_supply_crate"
const VISUAL_MILITARY: StringName = &"military_crate"

const CANDIDATES := {
	"sawmill": [
		{"id":"zerkov.loot.sawmill.optional.service_cache", "label":"Service cache", "position":Vector2(336,464), "table":"industrial", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.sawmill.optional.haul_lane", "label":"Haul lane cache", "position":Vector2(240,336), "table":"industrial", "visual":"military_crate"},
		{"id":"zerkov.loot.sawmill.optional.mill_aisle", "label":"Mill aisle cache", "position":Vector2(496,336), "table":"industrial", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.sawmill.optional.south_road", "label":"South road cache", "position":Vector2(656,336), "table":"mixed", "visual":"military_crate"},
		{"id":"zerkov.loot.sawmill.optional.east_haul", "label":"East haul cache", "position":Vector2(912,336), "table":"mixed", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.sawmill.optional.east_verge", "label":"East verge cache", "position":Vector2(1072,496), "table":"industrial", "visual":"military_crate"},
	],
	"northline": [
		{"id":"zerkov.loot.northline.optional.checkpoint_west", "label":"Checkpoint cache", "position":Vector2(432,368), "table":"northline", "visual":"military_crate"},
		{"id":"zerkov.loot.northline.optional.freight_east", "label":"Freight cache", "position":Vector2(1296,592), "table":"industrial", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.northline.optional.rail_north", "label":"Rail cache", "position":Vector2(1584,368), "table":"northline", "visual":"military_crate"},
		{"id":"zerkov.loot.northline.optional.south_depot", "label":"South depot cache", "position":Vector2(1872,816), "table":"industrial", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.northline.optional.east_storage", "label":"East storage cache", "position":Vector2(2448,592), "table":"northline", "visual":"military_crate"},
		{"id":"zerkov.loot.northline.optional.service_road", "label":"Service road cache", "position":Vector2(720,816), "table":"mixed", "visual":"wood_supply_crate"},
	],
	"blackwater": [
		{"id":"zerkov.loot.blackwater.optional.customs_west", "label":"Customs cache", "position":Vector2(432,368), "table":"blackwater", "visual":"military_crate"},
		{"id":"zerkov.loot.blackwater.optional.records_row", "label":"Records cache", "position":Vector2(720,368), "table":"blackwater", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.blackwater.optional.east_yard", "label":"East yard cache", "position":Vector2(1296,368), "table":"mixed", "visual":"military_crate"},
		{"id":"zerkov.loot.blackwater.optional.southwest", "label":"Southwest cache", "position":Vector2(432,1040), "table":"industrial", "visual":"wood_supply_crate"},
		{"id":"zerkov.loot.blackwater.optional.roadside", "label":"Roadside cache", "position":Vector2(1296,1040), "table":"blackwater", "visual":"military_crate"},
		{"id":"zerkov.loot.blackwater.optional.crossing", "label":"Crossing cache", "position":Vector2(1584,816), "table":"mixed", "visual":"wood_supply_crate"},
	],
}

const ITEM_RULES := {
	"zerkov.item.quest.supply_crate": {"weight":0, "minimum":1, "maximum":1, "footprint":Vector2i(2,2), "rotate":true},
	"zerkov.item.weapon.akm": {"weight":2, "minimum":1, "maximum":1, "footprint":Vector2i(5,2), "rotate":true},
	"zerkov.item.weapon.machete": {"weight":4, "minimum":1, "maximum":1, "footprint":Vector2i(3,1), "rotate":true},
	"zerkov.item.ammo.caliber_762x39_standard": {"weight":22, "minimum":20, "maximum":60, "footprint":Vector2i(1,1), "rotate":false},
	"zerkov.item.magazine.akm_30": {"weight":8, "minimum":1, "maximum":1, "footprint":Vector2i(1,2), "rotate":true},
	"zerkov.item.medical.bandage": {"weight":18, "minimum":1, "maximum":3, "footprint":Vector2i(1,1), "rotate":false},
	"zerkov.item.medical.splint": {"weight":10, "minimum":1, "maximum":2, "footprint":Vector2i(1,2), "rotate":true},
	"zerkov.item.valuable.encrypted_drive": {"weight":3, "minimum":1, "maximum":1, "footprint":Vector2i(1,1), "rotate":false},
	"zerkov.item.valuable.gold_watch": {"weight":5, "minimum":1, "maximum":1, "footprint":Vector2i(1,1), "rotate":false},
	"zerkov.item.junk.battery": {"weight":12, "minimum":1, "maximum":3, "footprint":Vector2i(1,2), "rotate":true},
	"zerkov.item.junk.duct_tape": {"weight":15, "minimum":1, "maximum":3, "footprint":Vector2i(1,1), "rotate":false},
	"zerkov.item.junk.bolts": {"weight":16, "minimum":2, "maximum":6, "footprint":Vector2i(1,1), "rotate":false},
	"zerkov.item.junk.scrap_metal": {"weight":12, "minimum":1, "maximum":4, "footprint":Vector2i(2,1), "rotate":true},
}

const TABLES := {
	"industrial": [
		"zerkov.item.ammo.caliber_762x39_standard", "zerkov.item.magazine.akm_30",
		"zerkov.item.medical.bandage", "zerkov.item.junk.battery",
		"zerkov.item.junk.duct_tape", "zerkov.item.junk.bolts",
		"zerkov.item.junk.scrap_metal", "zerkov.item.weapon.machete",
	],
	"mixed": [
		"zerkov.item.ammo.caliber_762x39_standard", "zerkov.item.medical.bandage",
		"zerkov.item.medical.splint", "zerkov.item.junk.battery",
		"zerkov.item.junk.duct_tape", "zerkov.item.junk.bolts",
		"zerkov.item.valuable.gold_watch", "zerkov.item.valuable.encrypted_drive",
	],
	"northline": [
		"zerkov.item.weapon.akm", "zerkov.item.ammo.caliber_762x39_standard",
		"zerkov.item.magazine.akm_30", "zerkov.item.medical.bandage",
		"zerkov.item.medical.splint", "zerkov.item.junk.battery",
		"zerkov.item.junk.bolts", "zerkov.item.valuable.encrypted_drive",
	],
	"blackwater": [
		"zerkov.item.ammo.caliber_762x39_standard", "zerkov.item.magazine.akm_30",
		"zerkov.item.medical.bandage", "zerkov.item.medical.splint",
		"zerkov.item.junk.duct_tape", "zerkov.item.valuable.gold_watch",
		"zerkov.item.valuable.encrypted_drive", "zerkov.item.junk.scrap_metal",
	],
}

static func candidates(map_id: String) -> Array:
	return RaidProgressionValues.freeze((CANDIDATES.get(map_id, []) as Array).duplicate(true))

static func candidate(map_id: String, target_id: String) -> Dictionary:
	if not CANDIDATES.has(map_id) or target_id.is_empty():
		return {}
	for row: Dictionary in CANDIDATES[map_id]:
		if String(row.id) == target_id:
			return row.duplicate(true)
	return {}

static func accepts_target_for_map(map_id: String, target_id: String) -> bool:
	return not candidate(map_id, target_id).is_empty()

static func accepts_target(target_id: String) -> bool:
	if target_id.is_empty():
		return false
	for map_id: String in ["sawmill", "northline", "blackwater"]:
		if accepts_target_for_map(map_id, target_id):
			return true
	return false

static func table(identifier: String) -> Array:
	return (TABLES.get(identifier, TABLES["mixed"]) as Array).duplicate()

static func item_rule(definition: String) -> Dictionary:
	return (ITEM_RULES.get(definition, {}) as Dictionary).duplicate(true)

static func validates(map_id: String) -> bool:
	var rows: Array = CANDIDATES.get(map_id, [])
	if rows.size() != 6:
		return false
	var ids: Dictionary = {}
	for row: Dictionary in rows:
		var id := String(row.get("id", ""))
		var position: Variant = row.get("position")
		if not id.begins_with("zerkov.loot." + map_id + ".optional.") or ids.has(id) \
				or not position is Vector2 or not position.is_finite() \
				or not TABLES.has(String(row.get("table", ""))) \
				or StringName(row.get("visual", &"")) not in [VISUAL_WOOD, VISUAL_MILITARY]:
			return false
		ids[id] = true
	return true
