class_name LocalInventoryController
extends InventoryEquipmentController

## Root composition selects a real level container for the existing workspace.
## This changes presentation identity only. Every transfer still revalidates the
## registered target, authoritative range/occlusion and native item revisions.
func bind_world_inventory(source: StringName, inventory_id: int) -> bool:
	if not _binding_is_current() or source not in [SOURCE_CRATE, SOURCE_CORPSE] or inventory_id <= 0:
		return false
	var snapshot := _owner.raid_authority().snapshot(inventory_id)
	var expected := ZerkovInventoryCatalog.PROFILE_WORLD_CRATE if source == SOURCE_CRATE else ZerkovInventoryCatalog.PROFILE_CORPSE
	if snapshot == null or StringName(snapshot.get_profile_identifier()) != expected:
		return false
	if _inventory_id_for_source(source) == inventory_id: return true
	close_loot_container()
	_clear_loot_state_hint()
	_binding_serial += 1
	_source_bindings[String(source)]["inventory_id"] = inventory_id
	projection_changed.emit(SCOPE_RAID)
	return true




var _storage := WearableStoragePolicy.new()

func storage_state(source: StringName) -> Dictionary:
	var snapshot: InventorySnapshotResource = _bridge.confirmed_snapshot(SCOPE_RAID, _owner.raid_player_inventory_id) if _binding_is_current() else null
	return _freeze(_storage.state(snapshot, source))

func descriptor(source: StringName) -> Dictionary:
	var result := super.descriptor(source)
	if source not in [SOURCE_RIG, SOURCE_BACKPACK] or not result.available: return result
	var storage := storage_state(source)
	result["recovery_only"] = not storage.equipped and storage.recovery_count > 0
	if not storage.equipped and storage.recovery_count == 0:
		result.available = false
		result.reason = &"storage_not_equipped"
		result.container_id = 0
		result.columns = 0; result.rows = 0
	return result

func grid_size(source: StringName) -> Vector2i:
	if source in [SOURCE_RIG, SOURCE_BACKPACK]:
		var storage := storage_state(source)
		return storage.size if storage.equipped else Vector2i.ZERO
	return super.grid_size(source)

func _fits_target(source: StringName, item: Dictionary, position: Vector2i, ignore: int) -> bool:
	if source in [SOURCE_RIG, SOURCE_BACKPACK]:
		var storage := storage_state(source)
		if not storage.equipped or int(item.get("item_id", 0)) == int(storage.provider_item_id): return false
	return super._fits_target(source, item, position, ignore)


## Recover an older V1 item without exposing an unequipped storage grid. The
## ordinary submission seam still revalidates source, revision and identity.
func recover_unassigned(source: StringName, item: Dictionary) -> Dictionary:
	if not _binding_is_current() or source not in [SOURCE_RIG, SOURCE_BACKPACK]:
		return _rejection_result(&"storage_recovery_unavailable", OP_MOVE)
	var storage := storage_state(source)
	if storage.equipped or storage.recovery_count == 0:
		return _rejection_result(&"storage_recovery_unavailable", OP_MOVE)
	var snapshot := _bridge.confirmed_snapshot(SCOPE_RAID, _owner.raid_player_inventory_id)
	var location := _storage.quick_location(snapshot, snapshot, int(item.get("item_id", 0)), true)
	if location.is_empty():
		return _rejection_result(&"no_equipped_storage_space", OP_MOVE)
	for target: StringName in [SOURCE_POCKETS, SOURCE_RIG, SOURCE_BACKPACK]:
		var desc := descriptor(target)
		if int(desc.get("container_id", 0)) == int(location.container):
			var captured := item.duplicate(true)
			return submit_drop(source, target, captured, Vector2i(location.x, location.y))
	return _rejection_result(&"no_equipped_storage_space", OP_MOVE)
