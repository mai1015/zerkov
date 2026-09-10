class_name ZerkovInventoryCatalog
extends RefCounted
## First-playable inventory definitions and sealed catalog factory.

const ITEM_AKM: StringName = &"zerkov.item.weapon.akm"
const ITEM_MACHETE: StringName = &"zerkov.item.weapon.machete"
const ITEM_AMMO_762: StringName = &"zerkov.item.ammo.caliber_762x39_standard"
const ITEM_MAGAZINE_AKM: StringName = &"zerkov.item.magazine.akm_30"
const ITEM_BANDAGE: StringName = &"zerkov.item.medical.bandage"
const ITEM_SPLINT: StringName = &"zerkov.item.medical.splint"
const ITEM_SUPPLY_CRATE: StringName = &"zerkov.item.quest.supply_crate"
const ITEM_SEALED_DOCUMENTS: StringName = &"zerkov.item.quest.sealed_documents"
const ITEM_ENCRYPTED_DRIVE: StringName = &"zerkov.item.valuable.encrypted_drive"
const ITEM_GOLD_WATCH: StringName = &"zerkov.item.valuable.gold_watch"
const ITEM_BATTERY: StringName = &"zerkov.item.junk.battery"
const ITEM_DUCT_TAPE: StringName = &"zerkov.item.junk.duct_tape"
const ITEM_BOLTS: StringName = &"zerkov.item.junk.bolts"
const ITEM_SCRAP_METAL: StringName = &"zerkov.item.junk.scrap_metal"
const ITEM_RIG_BASIC: StringName = &"zerkov.item.gear.rig_basic"
const ITEM_BACKPACK_DAYPACK: StringName = &"zerkov.item.gear.backpack_daypack"

const CONTAINER_POCKETS: StringName = &"zerkov.container.player.pockets"
const CONTAINER_RIG: StringName = &"zerkov.container.player.rig"
const CONTAINER_BACKPACK: StringName = &"zerkov.container.player.backpack"
const CONTAINER_SECURE: StringName = &"zerkov.container.player.secure"
const CONTAINER_EQUIPMENT: StringName = &"zerkov.container.player.equipment"
const CONTAINER_STASH: StringName = &"zerkov.container.profile.stash"
const CONTAINER_WORLD_CRATE: StringName = &"zerkov.container.world.crate"
const CONTAINER_CORPSE: StringName = &"zerkov.container.world.corpse"
const CONTAINER_MAGAZINE_AKM: StringName = &"zerkov.container.magazine.akm_30"

const PROFILE_PLAYER_RAID: StringName = &"zerkov.profile.raid.player"
const PROFILE_STASH: StringName = &"zerkov.profile.meta.stash"
const PROFILE_WORLD_CRATE: StringName = &"zerkov.profile.raid.world_crate"
const PROFILE_CORPSE: StringName = &"zerkov.profile.raid.corpse"

const DISCOVERY_WORLD_LOOT: StringName = &"zerkov.discovery.raid.world_loot"

const TRAIT_PRIMARY_WEAPON: StringName = &"zerkov.trait.slot.primary_weapon"
const TRAIT_MELEE_WEAPON: StringName = &"zerkov.trait.slot.melee_weapon"
const TRAIT_RIG: StringName = &"zerkov.trait.slot.rig"
const TRAIT_BACKPACK: StringName = &"zerkov.trait.slot.backpack"
const TRAIT_AMMO_762: StringName = &"zerkov.trait.ammo.caliber_762x39"
const TRAIT_MAGAZINE_AKM: StringName = &"zerkov.trait.magazine.akm"

const FIRST_PLAYABLE_ITEM_IDS: PackedStringArray = [
	ITEM_AKM,
	ITEM_MACHETE,
	ITEM_AMMO_762,
	ITEM_MAGAZINE_AKM,
	ITEM_BANDAGE,
	ITEM_SPLINT,
	ITEM_SUPPLY_CRATE,
	ITEM_SEALED_DOCUMENTS,
	ITEM_ENCRYPTED_DRIVE,
	ITEM_GOLD_WATCH,
	ITEM_BATTERY,
	ITEM_DUCT_TAPE,
	ITEM_BOLTS,
	ITEM_SCRAP_METAL,
	ITEM_RIG_BASIC,
	ITEM_BACKPACK_DAYPACK,
]

const FEATURE_SPATIAL: String = "inventory.feature.spatial_grid"
const FEATURE_SLOTS: String = "inventory.feature.named_slots"
const FEATURE_LIST: String = "inventory.feature.ordered_list"
const FEATURE_COUNT: String = "inventory.feature.count_capacity"
const FEATURE_MASS: String = "inventory.feature.mass_capacity"
const FEATURE_FILTER: String = "inventory.feature.filtering"
const FEATURE_NESTING: String = "inventory.feature.nesting"
const FEATURE_RETENTION: String = "inventory.feature.protected_retention"
const FEATURE_STACKING: String = "inventory.feature.stacking"
const FEATURE_AUTO: String = "inventory.feature.auto_placement"
const FEATURE_QUICK: String = "inventory.feature.quick_transfer"
const FEATURE_ROTATION: String = "inventory.feature.rotation"
const FEATURE_DISCOVERY: String = "inventory.feature.discovery"


## The fixture rows are authored as data rather than generated from a random
## stream.  This keeps the first-playable loot contract stable across runs,
## while the owning raid authority still allocates the canonical item ids.
static func world_crate_fixture_contents() -> Array[Dictionary]:
	return [
		_fixture_row(ITEM_SEALED_DOCUMENTS, 1, 0, 0, false),
		_fixture_row(ITEM_ENCRYPTED_DRIVE, 1, 2, 0, false),
		_fixture_row(ITEM_GOLD_WATCH, 1, 3, 0, false),
		_fixture_row(ITEM_DUCT_TAPE, 2, 4, 0, false),
	]


static func corpse_fixture_contents() -> Array[Dictionary]:
	return [
		_fixture_row(ITEM_AKM, 1, 0, 0, false),
		_fixture_row(ITEM_AMMO_762, 60, 5, 0, false),
		_fixture_row(ITEM_BANDAGE, 2, 6, 0, false),
		_fixture_row(ITEM_BOLTS, 4, 7, 0, false),
	]


static func _fixture_row(
	item_definition_identifier: StringName,
	quantity: int,
	x: int,
	y: int,
	rotated: bool
) -> Dictionary:
	return {
		"item_definition_identifier": String(item_definition_identifier),
		"quantity": quantity,
		"location": {
			"kind": "spatial",
			"container": 0,
			"x": x,
			"y": y,
			"rotated": rotated,
		},
	}


static func build_resource() -> InventoryCatalogResource:
	var resource := InventoryCatalogResource.new()
	resource.trait_schemas = _trait_schemas()
	resource.discovery_policies = [_world_loot_discovery()]
	resource.items = _items()
	resource.containers = _containers()
	resource.profiles = _profiles()
	return resource


static func build_sealed_catalog() -> InventoryCatalog:
	var catalog := InventoryCatalog.new()
	var builtin_result: Dictionary = catalog.register_builtin_definitions()
	if int(builtin_result.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
		push_error("Zerkov inventory builtins failed: " + str(builtin_result))
		return null
	var resource := build_resource()
	var validation: Array = catalog.validate_resource(resource)
	for finding_value in validation:
		var finding := finding_value as Dictionary
		if int(finding.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
			push_error("Zerkov inventory validation failed: " + str(finding))
			return null
	var findings: Array = catalog.register_catalog_resource(resource)
	for finding_value in findings:
		var finding := finding_value as Dictionary
		if int(finding.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
			push_error("Zerkov inventory registration failed: " + str(finding))
			return null
	var seal_result: Dictionary = catalog.seal()
	if int(seal_result.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
		push_error("Zerkov inventory seal failed: " + str(seal_result))
		return null
	return catalog


## Runs the native validator against the complete authored resource without
## creating a live authority.  A game composition root may use this for a
## bounded preflight before calling build_sealed_catalog().
static func validate_resource() -> Array:
	var validator := InventoryCatalog.new()
	return validator.validate_resource(build_resource())


static func _trait_schemas() -> Array[InventoryTraitSchema]:
	var schemas: Array[InventoryTraitSchema] = []
	for identifier in [
		TRAIT_PRIMARY_WEAPON,
		TRAIT_MELEE_WEAPON,
		TRAIT_RIG,
		TRAIT_BACKPACK,
		TRAIT_AMMO_762,
		TRAIT_MAGAZINE_AKM,
	]:
		var schema := InventoryTraitSchema.new()
		schema.identifier = identifier
		schema.version = 1
		schema.authority_affecting = true
		schema.max_payload_bytes = 16
		schemas.append(schema)
	return schemas


static func _items() -> Array[InventoryItemDefinition]:
	return [
		_item(ITEM_AKM, 1, 3_400_000, Vector2i(5, 2), true, [TRAIT_PRIMARY_WEAPON]),
		_item(ITEM_MACHETE, 1, 650_000, Vector2i(3, 1), true, [TRAIT_MELEE_WEAPON]),
		_item(ITEM_AMMO_762, 60, 16_300, Vector2i(1, 1), false, [TRAIT_AMMO_762]),
		_item(ITEM_MAGAZINE_AKM, 1, 350_000, Vector2i(1, 2), true,
			[TRAIT_MAGAZINE_AKM], [CONTAINER_MAGAZINE_AKM]),
		_item(ITEM_BANDAGE, 4, 70_000, Vector2i(1, 1)),
		_item(ITEM_SPLINT, 2, 160_000, Vector2i(1, 2), true),
		_item(ITEM_SUPPLY_CRATE, 1, 5_000_000, Vector2i(2, 2), true),
		_item(ITEM_SEALED_DOCUMENTS, 1, 900_000, Vector2i(2, 1), true),
		_item(ITEM_ENCRYPTED_DRIVE, 1, 120_000, Vector2i(1, 1)),
		_item(ITEM_GOLD_WATCH, 1, 90_000, Vector2i(1, 1)),
		_item(ITEM_BATTERY, 4, 180_000, Vector2i(1, 2), true),
		_item(ITEM_DUCT_TAPE, 4, 240_000, Vector2i(1, 1)),
		_item(ITEM_BOLTS, 8, 80_000, Vector2i(1, 1)),
		_item(ITEM_SCRAP_METAL, 6, 450_000, Vector2i(2, 1), true),
		_item(ITEM_RIG_BASIC, 1, 1_100_000, Vector2i(3, 3), false, [TRAIT_RIG]),
		_item(ITEM_BACKPACK_DAYPACK, 1, 1_300_000, Vector2i(3, 4), false, [TRAIT_BACKPACK]),
	]


static func _item(
	identifier: StringName,
	max_stack: int,
	unit_mass_mg: int,
	footprint: Vector2i,
	allow_rotation: bool = false,
	trait_ids: Array = [],
	provided_containers: Array = []
) -> InventoryItemDefinition:
	var item := InventoryItemDefinition.new()
	item.identifier = identifier
	item.schema_version = 1
	item.max_stack = max_stack
	item.unit_mass_mg = unit_mass_mg
	item.footprint_width = footprint.x
	item.footprint_height = footprint.y
	item.allow_rotation = allow_rotation
	var traits: Array[InventoryItemTraitValue] = []
	for trait_id in trait_ids:
		var trait_value := InventoryItemTraitValue.new()
		trait_value.trait_identifier = trait_id
		trait_value.version = 1
		trait_value.payload = PackedByteArray()
		traits.append(trait_value)
	item.traits = traits
	item.provided_containers = PackedStringArray(provided_containers)
	return item


static func _world_loot_discovery() -> InventoryDiscoveryPolicy:
	var policy := InventoryDiscoveryPolicy.new()
	policy.identifier = DISCOVERY_WORLD_LOOT
	policy.schema_version = 1
	policy.container_search_instant = false
	policy.container_search_duration_ms = 900
	policy.item_scan_instant = false
	policy.item_scan_duration_ms = 350
	policy.shell_label = "Unsearched container"
	return policy


static func _containers() -> Array[InventoryContainerDefinition]:
	var containers: Array[InventoryContainerDefinition] = [
		_grid(CONTAINER_POCKETS, Vector2i(4, 2), 8, 8_000_000),
		_grid(CONTAINER_RIG, Vector2i(6, 3), 18, 12_000_000),
		_grid(CONTAINER_BACKPACK, Vector2i(8, 5), 40, 28_000_000, true),
		_grid(CONTAINER_SECURE, Vector2i(3, 2), 6, 8_000_000, false,
			InventoryContainerConstraints.RETENTION_PROTECTED),
		_equipment(),
		_grid(CONTAINER_STASH, Vector2i(12, 20), 240, 250_000_000, true),
		_grid(CONTAINER_WORLD_CRATE, Vector2i(8, 6), 48, 100_000_000, true,
			InventoryContainerConstraints.RETENTION_NONE, DISCOVERY_WORLD_LOOT),
		_grid(CONTAINER_CORPSE, Vector2i(10, 8), 80, 120_000_000, true,
			InventoryContainerConstraints.RETENTION_NONE, DISCOVERY_WORLD_LOOT),
		_magazine_container(),
	]
	return containers


static func _grid(
	identifier: StringName,
	size: Vector2i,
	max_items: int,
	mass_capacity_mg: int,
	allow_nesting: bool = false,
	retention: int = InventoryContainerConstraints.RETENTION_NONE,
	discovery: StringName = &""
) -> InventoryContainerDefinition:
	var constraints := InventoryContainerConstraints.new()
	constraints.max_items = max_items
	constraints.has_mass_capacity = true
	constraints.mass_capacity_mg = mass_capacity_mg
	constraints.allow_nesting = allow_nesting
	constraints.max_nesting_depth = 4 if allow_nesting else 0
	constraints.retention = retention
	constraints.allow_stack_split = true
	constraints.allow_auto_placement = true
	constraints.allow_quick_transfer = true

	var container := InventoryContainerDefinition.new()
	container.identifier = identifier
	container.schema_version = 1
	container.layout_kind = InventoryContainerDefinition.LAYOUT_SPATIAL_GRID
	container.grid_width = size.x
	container.grid_height = size.y
	container.grid_allow_rotation = true
	container.constraints = constraints
	var features := PackedStringArray([
		FEATURE_SPATIAL,
		FEATURE_COUNT,
		FEATURE_MASS,
		FEATURE_STACKING,
		FEATURE_AUTO,
		FEATURE_QUICK,
		FEATURE_ROTATION,
	])
	if allow_nesting:
		features.append(FEATURE_NESTING)
	if retention != InventoryContainerConstraints.RETENTION_NONE:
		features.append(FEATURE_RETENTION)
	if not discovery.is_empty():
		features.append(FEATURE_DISCOVERY)
		container.discovery_policy_identifier = discovery
	container.enabled_features = features
	return container


static func _equipment() -> InventoryContainerDefinition:
	var slots: Array[InventoryNamedSlot] = [
		_slot(&"zerkov.slot.weapon_primary", TRAIT_PRIMARY_WEAPON),
		_slot(&"zerkov.slot.weapon_melee", TRAIT_MELEE_WEAPON),
		_slot(&"zerkov.slot.rig", TRAIT_RIG),
		_slot(&"zerkov.slot.backpack", TRAIT_BACKPACK),
	]
	var container := InventoryContainerDefinition.new()
	container.identifier = CONTAINER_EQUIPMENT
	container.schema_version = 1
	container.layout_kind = InventoryContainerDefinition.LAYOUT_NAMED_SLOTS
	container.named_slots = slots
	container.enabled_features = PackedStringArray([FEATURE_SLOTS, FEATURE_FILTER])
	container.constraints = InventoryContainerConstraints.new()
	return container


static func _slot(identifier: StringName, required_trait: StringName) -> InventoryNamedSlot:
	var slot := InventoryNamedSlot.new()
	slot.identifier = identifier
	slot.max_items = 1
	slot.required_traits = PackedStringArray([required_trait])
	return slot


static func _magazine_container() -> InventoryContainerDefinition:
	var constraints := InventoryContainerConstraints.new()
	constraints.max_items = 1
	constraints.required_traits = PackedStringArray([TRAIT_AMMO_762])
	constraints.allow_stack_split = true
	var container := InventoryContainerDefinition.new()
	container.identifier = CONTAINER_MAGAZINE_AKM
	container.schema_version = 1
	container.layout_kind = InventoryContainerDefinition.LAYOUT_ORDERED_LIST
	container.ordered_list_max_entries = 1
	container.constraints = constraints
	container.enabled_features = PackedStringArray([
		FEATURE_LIST,
		FEATURE_COUNT,
		FEATURE_FILTER,
		FEATURE_STACKING,
	])
	return container


static func _profiles() -> Array[InventoryProfileDefinition]:
	return [
		_profile(PROFILE_PLAYER_RAID, [
			CONTAINER_POCKETS,
			CONTAINER_RIG,
			CONTAINER_BACKPACK,
			CONTAINER_SECURE,
			CONTAINER_EQUIPMENT,
		], 128, 24, 4, _player_features()),
		_profile(PROFILE_STASH, [CONTAINER_STASH], 512, 64, 8, _grid_features(true, false)),
		_profile(PROFILE_WORLD_CRATE, [CONTAINER_WORLD_CRATE], 64, 16, 4,
			_grid_features(true, true)),
		_profile(PROFILE_CORPSE, [CONTAINER_CORPSE], 96, 24, 4,
			_grid_features(true, true)),
	]


static func _profile(
	identifier: StringName,
	roots: Array,
	max_items: int,
	max_containers: int,
	max_nesting_depth: int,
	features: PackedStringArray
) -> InventoryProfileDefinition:
	var limits := InventoryProfileLimits.new()
	limits.max_items = max_items
	limits.max_containers = max_containers
	limits.max_references = 32
	limits.max_nesting_depth = max_nesting_depth
	limits.max_mutable_components_per_item = 8
	var profile := InventoryProfileDefinition.new()
	profile.identifier = identifier
	profile.schema_version = 1
	profile.root_containers = PackedStringArray(roots)
	profile.enabled_features = features
	profile.limits = limits
	return profile


static func _player_features() -> PackedStringArray:
	var features := _grid_features(true, false)
	features.append(FEATURE_SLOTS)
	features.append(FEATURE_FILTER)
	features.append(FEATURE_RETENTION)
	return features


static func _grid_features(include_nesting: bool, include_discovery: bool) -> PackedStringArray:
	var features := PackedStringArray([
		FEATURE_SPATIAL,
		FEATURE_COUNT,
		FEATURE_MASS,
		FEATURE_STACKING,
		FEATURE_AUTO,
		FEATURE_QUICK,
		FEATURE_ROTATION,
	])
	if include_nesting:
		features.append(FEATURE_NESTING)
	if include_discovery:
		features.append(FEATURE_DISCOVERY)
	return features
