class_name OfflineInventoryController
extends InventoryPresentationController
## Existing Character workspace API with a pre-raid command sink. No raid
## admission, world loot, prediction queue, clock or second inventory algorithm.
var _session: OfflineBunkerSession
var _lease: int = 0
var _selected: Dictionary = {}
const LOCAL_ACTOR = "zerkov.entity.offline.local"

func attach(session: OfflineBunkerSession) -> void:
	_session = session
	_lease = session.generation()

func is_bound() -> bool:
	return _session != null and is_instance_valid(_session) and _session.is_open() and _lease == _session.generation()

func current_owner_generation() -> int:
	return _lease

func unbind() -> void:
	_session = null
	_selected.clear()

func descriptor(source: StringName) -> Dictionary:
	var key := _canonical_source(source)
	var scope := scope_for_source(key)
	var dimensions := grid_size(key)
	var cid := _session.container_id(String(key)) if is_bound() else 0
	return {"source": key, "scope": scope, "inventory_id": 1, "container_id": cid,
		"container_definition_identifier": String(OfflineBunkerSession.ROOTS.get(String(key), "")),
		"columns": dimensions.x, "rows": dimensions.y, "owner_generation": _lease,
		"scope_generation": _lease, "mapping_key": _mapping_key(scope, _lease, 1, cid),
		"available": cid > 0, "reason": &"" if cid > 0 else &"offline_inventory_unavailable"}

func mutation_available(source: StringName) -> bool:
	return is_bound() and String(_canonical_source(source)) in ["stash", "pockets", "rig", "backpack"]

func scope_ready(source: StringName) -> bool:
	return mutation_available(source)

func status_reason(source: StringName) -> StringName:
	return &"" if mutation_available(source) else &"offline_inventory_unavailable"

func split_available(source: StringName, target: StringName) -> bool:
	return mutation_available(source) and mutation_available(target)

func quick_transfer_available(source: StringName) -> bool:
	return mutation_available(source)

func loot_mutation_available() -> bool:
	return false

func loot_search_available() -> bool:
	return false

func open_loot_container() -> bool:
	return false

func close_loot_container() -> bool:
	return false

func is_loot_container_open() -> bool:
	return false

func loot_container_state() -> StringName:
	return &"unavailable"

func loot_status_text() -> String:
	return "RAID LOOT UNAVAILABLE"

func loot_status_detail() -> String:
	return "This is the offline bunker. No raid is active."

func inventory_view(scope: StringName) -> InventoryView:
	var kind := InventoryView.Scope.PROFILE if scope == SCOPE_PROFILE else InventoryView.Scope.RAID
	var actor := ZEntityId.parse(LOCAL_ACTOR)
	if not is_bound():
		return InventoryView.unavailable(kind, ZReadOnlyView.SyncState.UNBOUND, &"offline_profile_closed")
	var current := _session.snapshot()
	var records: Array[InventoryView.ContainerRecord] = []
	var sources: Array = [SOURCE_STASH] if scope == SCOPE_PROFILE else [SOURCE_POCKETS, SOURCE_RIG, SOURCE_BACKPACK]
	for source: StringName in sources:
		var desc := descriptor(source)
		var items: Array[InventoryView.ItemRecord] = []
		for item: Dictionary in _snapshot_items_for_descriptor(current, desc):
			var meta := _presentation_for(String(item.item_definition_identifier))
			var rotated: bool = bool(item.location.get("rotated", false))
			var sz := Vector2i(meta.get("w", 1), meta.get("h", 1))
			if rotated:
				sz = Vector2i(sz.y, sz.x)
			var record := InventoryView.ItemRecord.create(item.id, StringName(item.item_definition_identifier),
				String(meta.get("name", item.item_definition_identifier)), item.quantity,
				Vector2i(item.location.get("x", 0), item.location.get("y", 0)), sz, rotated,
				StringName(meta.get("icon", "item_parts.png")), StringName(meta.get("category", "item")),
				bool(meta.get("icon_placeholder", false)))
			if record == null:
				return InventoryView.unavailable(kind, ZReadOnlyView.SyncState.STALE, &"offline_item_projection_invalid")
			items.append(record)
		var container := InventoryView.ContainerRecord.create(1, desc.container_id,
			_session.revision(), _container_kind_for_source(source), StringName(desc.container_definition_identifier),
			_container_display_name(source), grid_size(source), false, items)
		if container == null:
			return InventoryView.unavailable(kind, ZReadOnlyView.SyncState.STALE, &"offline_container_projection_invalid")
		records.append(container)
	return InventoryView.create(_lease, _session.revision(), 0, kind, actor, records)

func items_for(source: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not is_bound():
		return result
	var desc := descriptor(source)
	for row: Dictionary in _snapshot_items_for_descriptor(_session.snapshot(), desc):
		result.append(_display_item(row, desc))
	return result

func items_for_view(source: StringName, view: InventoryView) -> Array[Dictionary]:
	if not is_bound() or view == null or not view.is_ready() or view.generation() != _lease or view.revision() != _session.revision():
		return []
	return items_for(source)

func _display_item(row: Dictionary, desc: Dictionary) -> Dictionary:
	var definition := String(row.item_definition_identifier)
	var meta := _presentation_for(definition)
	var loc: Dictionary = row.location.duplicate(true)
	var rotated := bool(loc.get("rotated", false))
	var base := Vector2i(meta.get("w", 1), meta.get("h", 1))
	var sz := Vector2i(base.y, base.x) if rotated else base
	var kind := String(meta.get("kind", "item"))
	var category := "guns" if kind == "weapon" else (kind if kind in ["ammo", "armor", "clothing", "food"] else "util")
	return {"id": int(row.id), "item_id": int(row.id), "inventory_id": 1,
		"container_id": desc.container_id, "scope": desc.scope,
		"owner_generation": _lease, "scope_generation": _lease, "mapping_key": desc.mapping_key,
		"offline_revision": _session.revision(), "item_definition_identifier": definition,
		"definition_id": definition, "icon": String(meta.get("icon", "item_parts.png")),
		"icon_placeholder": bool(meta.get("icon_placeholder", false)),
		"icon_accessibility_label": String(meta.get("icon_accessibility_label", "")),
		"quantity": int(row.quantity), "count": int(row.quantity),
		"x": int(loc.get("x", 0)), "y": int(loc.get("y", 0)), "rotated": rotated,
		"w": sz.x, "h": sz.y, "width": sz.x, "height": sz.y,
		"base_width": base.x, "base_height": base.y, "max_stack": int(meta.get("max_stack", 1)),
		"merge_key": definition, "name": String(meta.get("name", definition)),
		"short": String(meta.get("short", kind)).to_upper(), "kind": kind, "category": category,
		"compatibility": String(meta.get("compatibility", "")), "rotatable": bool(meta.get("rotatable", false)),
		"location": loc, "state": &"normal"}

func select(source: StringName, item_id: int) -> bool:
	for item: Dictionary in items_for(source):
		if item.item_id == item_id:
			_selected = {"source": String(source), "item": item.duplicate(true)}
			return true
	return false

func hover(_source: StringName, _item_id: int, _hovering: bool = true) -> bool:
	return is_bound()

func submit_drop(source: StringName, target: StringName, item: Dictionary, destination: Vector2i,
	mode: StringName = OP_MOVE, merge_target_item_id: int = 0, split_quantity: int = 0) -> Dictionary:
	return _send(String(mode), source, target, item, destination, split_quantity, merge_target_item_id)

func submit_rotate(source: StringName, item: Dictionary) -> Dictionary:
	return _send("rotate", source, source, item)

func submit_quick(source: StringName, item: Dictionary) -> Dictionary:
	return _send("quick", source, SOURCE_POCKETS if source == SOURCE_STASH else SOURCE_STASH, item)

func equipment(slot: String) -> Dictionary:
	if not is_bound():
		return {}
	for row: Dictionary in _session.snapshot().get_items():
		if int(row.location.container) == _session.container_id("equipment") and row.location.get("slot_identifier", "") == slot:
			return _display_item(row, {"container_id": _session.container_id("equipment"), "scope": SCOPE_RAID,
				"mapping_key": "equipment"})
	return {}

func activate_equipment(slot: String) -> Dictionary:
	var worn := equipment(slot)
	if not worn.is_empty():
		return _send("quick", &"equipment", SOURCE_STASH, worn)
	if _selected.is_empty():
		return _feedback({"accepted": false, "reason": "select_an_item_then_click_its_slot", "status": {"reason": "select_an_item_then_click_its_slot"}})
	return _send("move", StringName(_selected.source), &"equipment", _selected.item, Vector2i.ZERO, 0, 0, slot)

func _send(operation: String, source: StringName, target: StringName, item: Dictionary,
	at: Vector2i = Vector2i.ZERO, quantity: int = 0, other: int = 0, slot: String = "") -> Dictionary:
	if not is_bound():
		return _feedback({"accepted": false, "reason": "offline_profile_closed", "status": {"reason": "offline_profile_closed"}})
	var command := {"operation": operation, "source": String(_canonical_source(source)), "target": String(_canonical_source(target)),
		"item_id": item.get("item_id", 0), "generation": item.get("owner_generation", -1),
		"revision": item.get("offline_revision", -1), "x": at.x, "y": at.y,
		"quantity": quantity, "other_item_id": other, "slot": slot}
	return _feedback(_session.execute(command))

func _feedback(result: Dictionary) -> Dictionary:
	result = result.duplicate(true)
	result["ui_resolved"] = true
	if result.get("accepted", false):
		_selected.clear()
		projection_changed.emit(SCOPE_PROFILE)
		projection_changed.emit(SCOPE_RAID)
		accepted_feedback.emit(result)
	else:
		last_error = StringName(result.get("reason", "rejected"))
		rejection_feedback.emit(result)
	return RaidProgressionValues.freeze(result)
