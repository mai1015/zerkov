class_name WearableStorageIntentAdapter
extends InventoryIntentAdapter
## The local campaign installs this policy at the existing admission boundary.
## Replay, schema, actor, revision and world checks remain in the base adapter.
var _storage := WearableStoragePolicy.new()

func _routed_fact_validation(operation: StringName, payload: Dictionary, shape: Dictionary, actor: int) -> Dictionary:
	var result := super._routed_fact_validation(operation, payload, shape, actor)
	if not StringName(result.reason).is_empty(): return result
	# Removing a provider must use its explicit equip/move path. Native quick
	# transfer may choose its own root or detach a filled bag across inventories.
	if operation == INTENT_KIND_QUICK_TRANSFER:
		var source := _authority.snapshot(int(shape.source_inventory_id))
		for key: StringName in [&"rig", &"backpack"]:
			var storage := _storage.state(source, key)
			if storage.equipped and int(shape.primary_item_id) == int(storage.provider_item_id):
				result.reason = &"empty_storage_before_unequip" if storage.recovery_count > 0 else &"storage_provider_requires_explicit_move"
				return result
	var snapshot := _authority.snapshot(int(shape.destination_inventory_id))
	result.reason = _storage.rejection(snapshot, operation, payload)
	if StringName(result.reason).is_empty() and operation == INTENT_KIND_QUICK_TRANSFER:
		result.reason = _complete_transfer_rejection(payload)
	return result

func _complete_transfer_rejection(payload: Dictionary) -> StringName:
	var target := _authority.snapshot(int(payload.destination_inventory_id))
	if target == null or target.get_profile_identifier() != String(ZerkovInventoryCatalog.PROFILE_PLAYER_RAID): return &""
	if _storage.state(target, &"rig").equipped and _storage.state(target, &"backpack").equipped: return &""
	return &"" if not _storage.quick_location(_authority.snapshot(int(payload.source_inventory_id)), target, int(payload.item_id)).is_empty() else &"no_equipped_storage_space"

func _invoke_complete_transfer(payload: Dictionary, actor: int, command_id: int) -> Dictionary:
	var target := _authority.snapshot(int(payload.destination_inventory_id))
	if target == null or target.get_profile_identifier() != String(ZerkovInventoryCatalog.PROFILE_PLAYER_RAID) or (_storage.state(target, &"rig").equipped and _storage.state(target, &"backpack").equipped):
		return super._invoke_complete_transfer(payload, actor, command_id)
	var location := _storage.quick_location(_authority.snapshot(int(payload.source_inventory_id)), target, int(payload.item_id))
	# One existing atomic native transfer; never mutate then roll back a hidden
	# destination. No partial success or private fake-native receipt is returned.
	return _authority.loot_item(int(payload.source_inventory_id), int(payload.destination_inventory_id), int(payload.item_id), location, actor, command_id)

func _invoke_routed_native(operation: StringName, payload: Dictionary, actor: int, command_id: int) -> Dictionary:
	if operation == INTENT_KIND_QUICK_TRANSFER: return _invoke_complete_transfer(payload, actor, command_id)
	return super._invoke_routed_native(operation, payload, actor, command_id)
