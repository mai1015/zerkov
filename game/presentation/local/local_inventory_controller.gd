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


