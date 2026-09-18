class_name InventoryEquipmentRules
extends RefCounted
## Declaration-only metadata. The actual snapshot fingerprint must match the
## sealed authored catalog before its named slots can be exposed or admitted.
## Native InventoryAuthority remains responsible for compatibility/occupancy.
var _fingerprint: int = 0
var _declared: Array[StringName] = []

func _init() -> void:
	var resource := ZerkovInventoryCatalog.build_resource()
	var catalog := ZerkovInventoryCatalog.build_sealed_catalog()
	if resource == null or catalog == null: return
	for container: InventoryContainerDefinition in resource.containers:
		if container.identifier != ZerkovInventoryCatalog.CONTAINER_EQUIPMENT: continue
		for slot: InventoryNamedSlot in container.named_slots:
			_declared.append(StringName(slot.identifier))
	_fingerprint = catalog.manifest_fingerprint()
	_declared.make_read_only()

func container_id(snapshot: InventorySnapshotResource) -> int:
	if snapshot == null or _fingerprint == 0 or snapshot.get_manifest_fingerprint() != _fingerprint \
		or StringName(snapshot.get_profile_identifier()) != ZerkovInventoryCatalog.PROFILE_PLAYER_RAID:
		return 0
	var found: int = 0
	for container: Dictionary in snapshot.get_containers():
		if int(container.provider_item) == 0 and StringName(container.container_definition_identifier) == ZerkovInventoryCatalog.CONTAINER_EQUIPMENT:
			if found != 0: return 0
			found = int(container.id)
	return found

func slots(snapshot: InventorySnapshotResource) -> Array[StringName]:
	return _declared if container_id(snapshot) > 0 else []

func declares(snapshot: InventorySnapshotResource, location: Dictionary) -> bool:
	var id := container_id(snapshot)
	return id > 0 and location.get("kind") == "slot" and int(location.get("container", 0)) == id \
		and _declared.has(StringName(location.get("slot_identifier", "")))
