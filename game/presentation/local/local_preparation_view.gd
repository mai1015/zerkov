class_name LocalPreparationView
extends RefCounted
## Read-only pre-flight summary. Stash/world stock is never counted as carried.
## Loose rounds are not loaded ammunition, and warnings never gate deployment.
static func from_views(inventory: InventoryView, health: HealthView, equipment: Dictionary = {}) -> Dictionary:
	var result := {"ready":false, "equipment":[], "loose_rounds":0, "medical_items":0,
		"carried_stacks":0, "equipment_ready":false, "health":"Unavailable", "warnings":[]}
	if inventory == null or not inventory.is_ready() or inventory.scope() != InventoryView.Scope.RAID:
		result.warnings = ["Loadout temporarily unavailable. Open equipment to check it."]
		return RaidProgressionValues.freeze(result)
	result.ready = true
	var firearm := false
	var equipment_revision_current := false
	var seen: Dictionary = {}
	for container: InventoryView.ContainerRecord in inventory.containers():
		if equipment.get("ready", false) and container.inventory_id() == equipment.get("inventory_id") and container.inventory_revision() == equipment.get("revision"):
			equipment_revision_current = true
		if container.kind() == InventoryView.ContainerKind.EQUIPMENT: result.equipment_ready = true
		if container.kind() in [InventoryView.ContainerKind.STASH, InventoryView.ContainerKind.CRATE, InventoryView.ContainerKind.CORPSE]: continue
		for item: InventoryView.ItemRecord in container.items():
			var key := "%d:%d" % [container.inventory_id(), item.instance_id()]
			if seen.has(key): continue
			seen[key] = true
			result.carried_stacks += 1
			if container.kind() == InventoryView.ContainerKind.EQUIPMENT:
				result.equipment.append(item.display_name())
				firearm = firearm or item.category() == &"rifle"
			if item.category() == &"ammo": result.loose_rounds += item.quantity()
			if item.category() == &"medical": result.medical_items += item.quantity()
	if equipment_revision_current:
		result.equipment_ready = true
		result.equipment = equipment.get("names", []).duplicate()
		firearm = equipment.get("has_rifle", false)
		result.loose_rounds = equipment.get("loose_rounds", 0)
		result.medical_items = equipment.get("medical_items", 0)
	result.equipment.sort()
	if health != null and health.is_ready() and health.generation() == inventory.generation() \
		and health.actor_id().canonical_key() == inventory.actor_id().canonical_key():
		result.health = "%d / %d HP" % [health.current_health(), health.maximum_health()]
		if health.current_health() < health.maximum_health(): result.warnings.append("You have injuries. Check Health before leaving.")
	else:
		result.warnings.append("Health temporarily unavailable. Check your operator.")
	if not result.equipment_ready: result.warnings.append("Equipment temporarily unavailable. Check your loadout.")
	elif not firearm: result.warnings.append("No rifle equipped. You can still deploy.")
	elif result.loose_rounds == 0: result.warnings.append("No loose reserve ammunition carried.")
	if result.medical_items == 0: result.warnings.append("No medical supplies carried.")
	return RaidProgressionValues.freeze(result)


## Called only at the game composition boundary. Native slot snapshots are not
## yet represented by the Character grid projection; do not call that omission
## an empty loadout. No native object is returned to the UI.
static func equipment_from_snapshot(snapshot: InventorySnapshotResource) -> Dictionary:
	var result := {"ready":false, "inventory_id":0, "revision":0, "names":[], "has_rifle":false, "loose_rounds":0, "medical_items":0}
	if snapshot == null or snapshot.get_visibility() != InventorySnapshotResource.VISIBILITY_OWNER \
		or StringName(snapshot.get_profile_identifier()) != ZerkovInventoryCatalog.PROFILE_PLAYER_RAID:
		return RaidProgressionValues.freeze(result)
	var equipment := LocalCampaignContent.container_id(snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	if equipment <= 0: return RaidProgressionValues.freeze(result)
	result.ready = true
	result.inventory_id = snapshot.get_inventory_id()
	result.revision = snapshot.get_revision()
	for item: Dictionary in snapshot.get_items():
		var location: Dictionary = item.get("location", {})
		var identifier := String(item.get("item_definition_identifier", ""))
		if identifier == String(ZerkovInventoryCatalog.ITEM_AMMO_762) and location.get("kind") == "spatial": result.loose_rounds += int(item.get("quantity", 0))
		if identifier in [String(ZerkovInventoryCatalog.ITEM_BANDAGE), String(ZerkovInventoryCatalog.ITEM_SPLINT)]: result.medical_items += int(item.get("quantity", 0))
		if location.get("kind") != "slot" or location.get("container") != equipment: continue
		result.names.append("AKM" if identifier == String(ZerkovInventoryCatalog.ITEM_AKM) else LocalGameViews.display_item(identifier))
		result.has_rifle = result.has_rifle or identifier == String(ZerkovInventoryCatalog.ITEM_AKM)
	result.names.sort()
	return RaidProgressionValues.freeze(result)
