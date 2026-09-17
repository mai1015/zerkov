class_name InventoryEquipmentController
extends InventoryPresentationController
## Named-slot equipment complements (not masquerades as) spatial ItemRecords.
## All mutations reuse the existing controller's pending/receipt/intent seam.
const SOURCE_SECURE: StringName = &"secure"
const SOURCE_EQUIPMENT: StringName = &"equipment"
var _equipment_rules := InventoryEquipmentRules.new()

func _configure_source_bindings() -> void:
	super._configure_source_bindings()
	for source: StringName in [SOURCE_SECURE, SOURCE_EQUIPMENT]:
		_source_bindings[String(source)] = {
			"scope": SCOPE_RAID, "inventory_id": int(_owner.raid_player_inventory_id),
			"container_definition_identifier": String(ZerkovInventoryCatalog.CONTAINER_SECURE if source == SOURCE_SECURE else ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)}

func descriptor(source: StringName) -> Dictionary:
	var result := super.descriptor(source)
	if source == SOURCE_SECURE:
		var size := grid_size(source)
		result.columns = size.x; result.rows = size.y
	return result

func grid_size(source: StringName) -> Vector2i:
	return _container_size(String(ZerkovInventoryCatalog.CONTAINER_SECURE)) if source == SOURCE_SECURE else super.grid_size(source)

func _sources_for_scope(scope: StringName) -> Array[StringName]:
	var result := super._sources_for_scope(scope)
	if scope == SCOPE_RAID: result.append(SOURCE_SECURE)
	return result

func _container_kind_for_source(source: StringName) -> InventoryView.ContainerKind:
	return InventoryView.ContainerKind.SECURE if source == SOURCE_SECURE else super._container_kind_for_source(source)

func _container_display_name(source: StringName) -> String:
	return "Secure container" if source == SOURCE_SECURE else super._container_display_name(source)

func _is_actor_owned_source(source: StringName) -> bool:
	return source in [SOURCE_SECURE, SOURCE_EQUIPMENT] or super._is_actor_owned_source(source)

func items_for_view(source: StringName, view: InventoryView) -> Array[Dictionary]:
	var result := super.items_for_view(source, view)
	var desc := descriptor(source)
	for item: Dictionary in result:
		item.inventory_revision = _bridge.confirmed_revision(StringName(desc.scope), int(desc.inventory_id))
		item.equipment_binding_serial = _binding_serial
	return result

func items_for(source: StringName) -> Array[Dictionary]:
	if source != SOURCE_EQUIPMENT: return super.items_for(source)
	var result: Array[Dictionary] = []
	for slot: Dictionary in equipment_view().slots:
		if not slot.item.is_empty(): result.append(slot.item)
	return result

func equipment_view() -> Dictionary:
	var desc := descriptor(SOURCE_EQUIPMENT)
	var result := {"available": false, "reason": String(desc.reason), "slots": [],
		"owner_generation": _owner_generation, "binding_serial": _binding_serial,
		"inventory_revision": -1, "inventory_id": int(desc.inventory_id)}
	if not _binding_is_current() or not desc.available: return _freeze(result)
	var snapshot := _bridge.confirmed_snapshot(SCOPE_RAID, int(desc.inventory_id))
	var declared := _equipment_rules.slots(snapshot)
	if declared.is_empty(): return _freeze(result)
	var occupants: Dictionary = {}
	for item: Dictionary in snapshot.get_items():
		if _equipment_rules.declares(snapshot, item.location):
			var slot_id := StringName(item.location.slot_identifier)
			if occupants.has(slot_id): return _freeze(result)
			occupants[slot_id] = item
	result.available = true
	result.reason = ""
	result.inventory_revision = snapshot.get_revision()
	for slot_id: StringName in declared:
		var item: Dictionary = {}
		if occupants.has(slot_id):
			var native_item: Dictionary = occupants[slot_id]
			var definition := String(native_item.item_definition_identifier)
			var meta := _presentation_for(definition)
			item = {"id": int(native_item.id), "item_id": int(native_item.id),
				"inventory_id": int(desc.inventory_id), "container_id": int(desc.container_id),
				"scope": SCOPE_RAID, "scope_generation": int(desc.scope_generation),
				"owner_generation": _owner_generation, "mapping_key": String(desc.mapping_key),
				"equipment_binding_serial": _binding_serial, "inventory_revision": snapshot.get_revision(),
				"item_definition_identifier": definition, "definition_id": definition,
				"quantity": int(native_item.quantity), "count": int(native_item.quantity),
				"name": String(meta.name), "icon": String(meta.icon),
				"icon_placeholder": bool(meta.icon_placeholder), "kind": String(meta.kind),
				"width": int(meta.w), "height": int(meta.h), "w": int(meta.w), "h": int(meta.h),
				"x": 0, "y": 0, "rotated": false, "rotatable": false,
				"location": native_item.location.duplicate(true)}
		result.slots.append({"slot_id": String(slot_id), "item": item, "empty": item.is_empty()})
	return _freeze(result)

func submit_equip(source: StringName, item: Dictionary, slot_id: StringName) -> Dictionary:
	if _submission_active: return _rejection_result(REASON_REENTRANT_SUBMISSION, &"equip")
	var from := descriptor(source)
	var to := descriptor(SOURCE_EQUIPMENT)
	if not _can_submit(from, to): return _reject(_reason_for_unavailable(from, to), &"equip")
	if source == SOURCE_EQUIPMENT or not _is_actor_owned_source(source) or from.scope != SCOPE_RAID \
		or int(from.inventory_id) != int(to.inventory_id):
		return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, &"equip")
	if not _equipment_item_current(item, from): return _reject(REASON_STALE_DRAG_TARGET, &"equip")
	return _submit(SCOPE_RAID, InventoryIntentAdapter.INTENT_KIND_EQUIP, {
		"inventory_command_id": 0, "inventory_id": int(from.inventory_id), "item_id": int(item.item_id),
		"destination_location": {"kind":"slot", "container":int(to.container_id), "slot_identifier":String(slot_id)},
		"expected_revision": int(item.inventory_revision)}, [int(item.item_id)], &"equip", int(from.inventory_id))

func submit_unequip(item: Dictionary, target: StringName = &"", position: Vector2i = Vector2i(-1, -1)) -> Dictionary:
	if _submission_active: return _rejection_result(REASON_REENTRANT_SUBMISSION, &"unequip")
	var from := descriptor(SOURCE_EQUIPMENT)
	if not from.available or not mutation_available(SOURCE_EQUIPMENT): return _reject(REASON_MUTATION_UNAVAILABLE, &"unequip")
	if not _equipment_item_current(item, from): return _reject(REASON_STALE_DRAG_TARGET, &"unequip")
	if target.is_empty():
		var found := _unequip_destination(item)
		if found.is_empty(): return _reject(&"equipment_no_space", &"unequip")
		target = found.source; position = found.position
	var to := descriptor(target)
	if not _can_submit(from, to): return _reject(_reason_for_unavailable(from, to), &"unequip")
	if not _is_actor_owned_source(target) or target == SOURCE_EQUIPMENT or to.scope != SCOPE_RAID \
		or int(from.inventory_id) != int(to.inventory_id):
		return _reject(REASON_CROSS_AUTHORITY_UNAVAILABLE, &"unequip")
	if not _fits_target(target, item, position, int(item.item_id)): return _reject(REASON_INVALID_DESTINATION, &"unequip")
	return _submit(SCOPE_RAID, InventoryIntentAdapter.INTENT_KIND_UNEQUIP, {
		"inventory_command_id": 0, "inventory_id": int(from.inventory_id), "item_id": int(item.item_id),
		"destination_location": _location(to, position, false), "expected_revision": int(item.inventory_revision)},
		[int(item.item_id)], &"unequip", int(from.inventory_id))

func submit_drop(source: StringName, target: StringName, item: Dictionary, destination: Vector2i,
		mode: StringName = OP_MOVE, merge_target_item_id: int = 0, split_quantity: int = 0) -> Dictionary:
	if source == SOURCE_EQUIPMENT:
		if mode != OP_MOVE: return _reject(REASON_UNSUPPORTED_OPERATION, mode)
		return submit_unequip(item, target, destination)
	return super.submit_drop(source, target, item, destination, mode, merge_target_item_id, split_quantity)

func _equipment_item_current(item: Dictionary, desc: Dictionary) -> bool:
	return _binding_is_current() and _valid_live_item(item, desc) \
		and int(item.get("equipment_binding_serial", -1)) == _binding_serial \
		and int(item.get("inventory_revision", -1)) == _bridge.confirmed_revision(SCOPE_RAID, int(desc.inventory_id))

func _unequip_destination(item: Dictionary) -> Dictionary:
	for source: StringName in [SOURCE_BACKPACK, SOURCE_RIG, SOURCE_POCKETS]:
		var desc := descriptor(source)
		if not desc.available: continue
		for y in range(int(desc.rows)):
			for x in range(int(desc.columns)):
				if _fits_target(source, item, Vector2i(x,y), int(item.item_id)):
					return {"source":source, "position":Vector2i(x,y)}
	return {}

static func _freeze(value: Variant) -> Variant:
	if value is Dictionary:
		for key in value: value[key] = _freeze(value[key])
		value.make_read_only()
	elif value is Array:
		for index in value.size(): value[index] = _freeze(value[index])
		value.make_read_only()
	return value
