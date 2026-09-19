class_name WearableStoragePolicy
extends RefCounted
## Game policy over the V1 native root containers. Storage is available only
## while its declared provider is equipped. Old unassigned contents remain
## recoverable, never deleted or silently granted a replacement container.
const C = preload("res://game/content/zerkov_inventory_catalog.gd")
const PROVIDER_SOURCES := [&"rig", &"backpack", &"secure"]
const AUTO_PLACEMENT_SOURCES := [&"rig", &"backpack"]
const PROVIDERS := {
	"rig": {"slot": &"zerkov.slot.rig", "item": C.ITEM_RIG_BASIC, "container": C.CONTAINER_RIG},
	"backpack": {"slot": &"zerkov.slot.backpack", "item": C.ITEM_BACKPACK_DAYPACK, "container": C.CONTAINER_BACKPACK},
	"secure": {"slot": &"zerkov.slot.secure", "item": C.ITEM_SECURE_CONTAINER_BASIC, "container": C.CONTAINER_SECURE},
}
var _sizes: Dictionary = {}
var _items: Dictionary = {}

func _init() -> void:
	var catalog := C.build_resource()
	for container: InventoryContainerDefinition in catalog.containers:
		_sizes[String(container.identifier)] = Vector2i(container.grid_width, container.grid_height)
	for item: InventoryItemDefinition in catalog.items:
		_items[String(item.identifier)] = {"size": Vector2i(item.footprint_width, item.footprint_height), "rotates": item.allow_rotation}

func state(snapshot: InventorySnapshotResource, source: StringName) -> Dictionary:
	var result := {"equipped": false, "container_id": 0, "provider_item_id": 0,
		"size": Vector2i.ZERO, "recovery_count": 0, "definition": ""}
	if snapshot == null or snapshot.get_profile_identifier() != String(C.PROFILE_PLAYER_RAID) or not PROVIDERS.has(String(source)):
		return result
	var spec: Dictionary = PROVIDERS[String(source)]
	var equipment := LocalCampaignContent.container_id(snapshot, C.CONTAINER_EQUIPMENT)
	result.container_id = LocalCampaignContent.container_id(snapshot, spec.container)
	result.size = _sizes.get(String(spec.container), Vector2i.ZERO)
	for item: Dictionary in snapshot.get_items():
		var loc: Dictionary = item.location
		if loc.get("kind") == "slot" and int(loc.get("container", 0)) == equipment and StringName(loc.get("slot_identifier", "")) == spec.slot:
			result.definition = String(item.item_definition_identifier)
			result.equipped = result.definition == String(spec.item)
			result.provider_item_id = int(item.id)
		if int(loc.get("container", 0)) == int(result.container_id): result.recovery_count += 1
	return result

func destination_allowed(snapshot: InventorySnapshotResource, container_id: int) -> bool:
	if snapshot == null: return false
	for source: StringName in PROVIDER_SOURCES:
		var storage := state(snapshot, source)
		if container_id == int(storage.container_id): return storage.equipped
	return true

func rejection(snapshot: InventorySnapshotResource, operation: StringName, payload: Dictionary) -> StringName:
	if snapshot == null or snapshot.get_profile_identifier() != String(C.PROFILE_PLAYER_RAID): return &""
	var location: Dictionary = payload.get("destination_location", {})
	var destination := int(location.get("container", 0))
	if operation == &"inventory_merge":
		for item: Dictionary in snapshot.get_items():
			if int(item.id) == int(payload.get("destination_item_id", 0)): destination = int(item.location.container)
	if destination > 0 and not destination_allowed(snapshot, destination): return &"storage_not_equipped"
	# V1 roots do not travel with their provider item. Until item-owned storage
	# is migrated, removing a filled provider is rejected rather than orphaning
	# the root. This applies to rig, backpack, and the protected secure root.
	if operation in [&"inventory_move", &"inventory_unequip"]:
		for source: StringName in PROVIDER_SOURCES:
			var storage := state(snapshot, source)
			if int(payload.get("item_id", 0)) == int(storage.provider_item_id):
				if storage.recovery_count > 0: return &"empty_storage_before_unequip"
				if destination == int(storage.container_id): return &"storage_provider_cannot_store_itself"
	return &""

func quick_location(source: InventorySnapshotResource, target: InventorySnapshotResource, item_id: int, preserve_rotation: bool = false) -> Dictionary:
	if source == null or target == null: return {}
	var item: Dictionary = {}
	for row: Dictionary in source.get_items():
		if int(row.id) == item_id: item = row; break
	var fact: Dictionary = _items.get(String(item.get("item_definition_identifier", "")), {})
	if fact.is_empty(): return {}
	# Secure storage is never an automatic-transfer destination. The player must
	# explicitly choose to protect an item; quick transfer uses ordinary carried
	# capacity only.
	var candidates: Array[StringName] = [C.CONTAINER_POCKETS]
	for key: StringName in AUTO_PLACEMENT_SOURCES:
		if state(target, key).equipped: candidates.append(PROVIDERS[String(key)].container)
	for definition: StringName in candidates:
		var id := LocalCampaignContent.container_id(target, definition)
		var size: Vector2i = _sizes.get(String(definition), Vector2i.ZERO)
		for rotated: bool in ([bool(item.location.get("rotated", false))] if preserve_rotation else ([false, true] if fact.rotates else [false])):
			var extent: Vector2i = Vector2i(fact.size.y, fact.size.x) if rotated else fact.size
			for y in range(size.y - extent.y + 1):
				for x in range(size.x - extent.x + 1):
					var rect := Rect2i(Vector2i(x, y), extent)
					var free := true
					for other: Dictionary in target.get_items():
						if int(other.location.get("container", 0)) != id or (source.get_inventory_id() == target.get_inventory_id() and int(other.id) == item_id): continue
						var other_fact: Dictionary = _items.get(String(other.item_definition_identifier), {})
						if other_fact.is_empty(): free = false; break
						var other_extent: Vector2i = Vector2i(other_fact.size.y, other_fact.size.x) if other.location.get("rotated", false) else other_fact.size
						if rect.intersects(Rect2i(Vector2i(other.location.x, other.location.y), other_extent)): free = false; break
					if free: return {"kind":"spatial", "container":id, "x":x, "y":y, "rotated":rotated}
	return {}
