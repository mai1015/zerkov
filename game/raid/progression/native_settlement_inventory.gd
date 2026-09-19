class_name NativeSettlementInventory
extends SettlementInventoryPort
## Real Inventory System staging. No live inventory is altered during planning.
## Extract preserves the loadout exactly. Death keeps the complete ownership
## subtree rooted in the secure container and releases every other root item.
var _catalog: InventoryCatalog

func configure(catalog: InventoryCatalog = null) -> bool:
	if _catalog != null: return false
	_catalog = ZerkovInventoryCatalog.build_sealed_catalog() if catalog == null else catalog
	return _catalog != null and _catalog.is_sealed()

func _load(record: PackedByteArray, profile: StringName) -> InventoryAuthority:
	if _catalog == null or record.is_empty() or record.size() > ProfileCanonicalCodec.MAX_BLOB_BYTES: return null
	var authority := InventoryAuthority.new()
	authority.set_catalog(_catalog)
	var result := authority.apply_persistence_record(record)
	if result.get("ok") != true or int(result.get("inventory_id", 0)) != 1:
		authority.free()
		return null
	var snapshot := authority.snapshot(1)
	if snapshot == null or StringName(snapshot.get_profile_identifier()) != profile:
		authority.free()
		return null
	return authority

func validate_loadout(record: PackedByteArray) -> bool:
	var authority := _load(record, ZerkovInventoryCatalog.PROFILE_PLAYER_RAID)
	if authority == null: return false
	authority.free()
	return true

func validate_stash(record: PackedByteArray) -> bool:
	var authority := _load(record, ZerkovInventoryCatalog.PROFILE_STASH)
	if authority == null: return false
	authority.free()
	return true

func plan(record: PackedByteArray, outcome: String) -> Dictionary:
	if outcome not in ["extracted", "dead", "timeout", "abandoned"]: return {"ok": false}
	var authority := _load(record, ZerkovInventoryCatalog.PROFILE_PLAYER_RAID)
	if authority == null: return {"ok": false}
	var before := authority.snapshot(1)
	var before_items: Array = before.get_items()
	if outcome == "extracted":
		authority.free()
		return {"ok": true, "record": record.duplicate(), "retained": _group(before_items), "lost": []}
	var containers: Dictionary = {}
	var equipment_container := 0
	for row: Dictionary in before.get_containers():
		containers[int(row.id)] = row
		if int(row.provider_item) == 0 and row.container_definition_identifier == String(ZerkovInventoryCatalog.CONTAINER_EQUIPMENT):
			equipment_container = int(row.id)
	var entries: Array = []
	for item: Dictionary in before_items:
		var container: Dictionary = containers.get(int(item.location.container), {})
		if container.is_empty(): authority.free(); return {"ok": false}
		if int(container.provider_item) != 0: continue # Process the native subtree once, at its owning root.
		var equipped_secure_provider: bool = String(item.item_definition_identifier) == String(ZerkovInventoryCatalog.ITEM_SECURE_CONTAINER_BASIC) \
			and item.location.get("kind") == "slot" and int(item.location.get("container", 0)) == equipment_container \
			and StringName(item.location.get("slot_identifier", "")) == &"zerkov.slot.secure"
		var secure: bool = container.container_definition_identifier == String(ZerkovInventoryCatalog.CONTAINER_SECURE) \
			or equipped_secure_provider
		entries.append({"item": int(item.id), "disposition": "retain"} if secure \
			else {"item": int(item.id), "disposition": "release_to", "external_owner": 7_100_001})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.item < b.item)
	# The native command's complete plan is one transaction. No manual snapshot
	# editing or remove_item loops may bypass protected/container semantics.
	if not entries.is_empty():
		var result := authority.settle_inventory(1, entries, 7_100_002)
		if result.get("accepted") != true:
			authority.free()
			return {"ok": false, "reason": &"native_settlement_rejected", "diagnostic": result.get("status", {})}
	var after := authority.snapshot(1)
	var retained: Array = after.get_items()
	var retained_ids: Dictionary = {}
	for item: Dictionary in retained: retained_ids[int(item.id)] = true
	var lost: Array = []
	for item: Dictionary in before_items:
		if not retained_ids.has(int(item.id)): lost.append(item)
	var bytes := authority.make_persistence_record(1)
	authority.free()
	return {"ok": not bytes.is_empty(), "record": bytes, "retained": _group(retained), "lost": _group(lost)}

## Only call after deployment's profile write is verified. New owners are not
## exposed until both records pass native validation/replacement. No seed data.
func instantiate_owner(parent: Node, domains: Dictionary) -> RaidInventoryOwner:
	if parent == null or not domains.get(RaidProgressionValues.LOADOUT) is PackedByteArray \
		or not domains.get(RaidProgressionValues.STASH) is PackedByteArray \
		or not validate_loadout(domains[RaidProgressionValues.LOADOUT]) \
		or not validate_stash(domains[RaidProgressionValues.STASH]): return null
	var owner := RaidInventoryOwner.new()
	parent.add_child(owner)
	if not owner.configure(_catalog): owner.queue_free(); return null
	var loadout := owner.raid_authority().apply_persistence_record(domains[RaidProgressionValues.LOADOUT], true)
	var stash := owner.profile_authority().apply_persistence_record(domains[RaidProgressionValues.STASH], true)
	if loadout.get("ok") != true or stash.get("ok") != true:
		owner.teardown(owner.generation())
		owner.queue_free()
		return null
	return owner

static func _group(items: Array) -> Array:
	var counts: Dictionary = {}
	for item: Dictionary in items:
		var definition := String(item.item_definition_identifier)
		counts[definition] = int(counts.get(definition, 0)) + int(item.quantity)
	var keys := counts.keys()
	keys.sort()
	var result: Array = []
	for key: String in keys: result.append({"definition": key, "quantity": counts[key]})
	return result
