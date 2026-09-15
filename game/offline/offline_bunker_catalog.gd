class_name OfflineBunkerCatalog
extends RefCounted
## Uses the existing item/container definitions; does not change the raid catalog.
const PROFILE := "zerkov.profile.offline.bunker"
const DOMAIN := "zerkov.inventory.bunker"
const STARTER_VERSION := 1

static func build() -> InventoryCatalog:
	var resource := ZerkovInventoryCatalog.build_resource()
	resource.profiles.append(ZerkovInventoryCatalog._profile(PROFILE, [
		ZerkovInventoryCatalog.CONTAINER_STASH,
		ZerkovInventoryCatalog.CONTAINER_POCKETS,
		ZerkovInventoryCatalog.CONTAINER_RIG,
		ZerkovInventoryCatalog.CONTAINER_BACKPACK,
		ZerkovInventoryCatalog.CONTAINER_SECURE,
		ZerkovInventoryCatalog.CONTAINER_EQUIPMENT,
	], 640, 96, 8, ZerkovInventoryCatalog._player_features()))
	var catalog := InventoryCatalog.new()
	if catalog.register_builtin_definitions().get("status_code", -1) != InventoryCatalog.STATUS_OK:
		return null
	for row: Dictionary in catalog.validate_resource(resource):
		if row.get("status_code", -1) != InventoryCatalog.STATUS_OK:
			return null
	for row: Dictionary in catalog.register_catalog_resource(resource):
		if row.get("status_code", -1) != InventoryCatalog.STATUS_OK:
			return null
	return catalog if catalog.seal().get("status_code", -1) == InventoryCatalog.STATUS_OK else null

static func starter() -> Array[Dictionary]:
	# Modest editable starting content, not world loot or a repeatedly seeded fixture.
	return [
		{"definition": ZerkovInventoryCatalog.ITEM_AKM, "quantity": 1, "at": [0, 0]},
		{"definition": ZerkovInventoryCatalog.ITEM_MACHETE, "quantity": 1, "at": [5, 0]},
		{"definition": ZerkovInventoryCatalog.ITEM_AMMO_762, "quantity": 30, "at": [5, 1]},
		{"definition": ZerkovInventoryCatalog.ITEM_BANDAGE, "quantity": 4, "at": [6, 1]},
		{"definition": ZerkovInventoryCatalog.ITEM_SPLINT, "quantity": 1, "at": [7, 1]},
	]
