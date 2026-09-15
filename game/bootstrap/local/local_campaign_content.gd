class_name LocalCampaignContent
extends RefCounted
## New-campaign content, not a missing/corrupt-save fallback. Called only after
## an explicit create request and a verified ProfileStore `profile_missing`.
const C = ZerkovInventoryCatalog
const V = RaidProgressionValues
const PROFILE_ID: String = "zerkov.profile.local"
const VERSION: int = 1
const RAID_LIMIT_TICKS: int = 54_000
const EXTRACTION_TICKS: int = 300
const CONTENT_ACTOR: int = 7_200_001

static func create_payload(parent: Node) -> Dictionary:
	var owner := RaidInventoryOwner.new()
	parent.add_child(owner)
	if not owner.configure():
		owner.queue_free()
		return {}
	var ok := equip_starter(owner)
	var payload: Dictionary = {}
	if ok:
		payload = {"project": {"local_campaign": {"version": VERSION,
			"name": "Local operator", "seed": 1,
			"health_policy": "recover_at_home", "starter_issued": true}},
			"domains": {V.LOADOUT: owner.raid_authority().make_persistence_record(owner.raid_player_inventory_id),
				V.STASH: owner.profile_authority().make_persistence_record(owner.profile_inventory_id)}}
	owner.teardown(owner.generation())
	owner.queue_free()
	return payload

static func equip_starter(owner: RaidInventoryOwner) -> bool:
	var native := owner.raid_authority()
	var id := owner.raid_player_inventory_id
	var equipment := container_id(native.snapshot(id), C.CONTAINER_EQUIPMENT)
	var pockets := container_id(native.snapshot(id), C.CONTAINER_POCKETS)
	var secure := container_id(native.snapshot(id), C.CONTAINER_SECURE)
	var rows: Array = [
		[C.ITEM_AKM, 1, {"kind":"slot", "container":equipment, "slot_identifier":String(EquippedItemReconciler.SLOT_PRIMARY)}],
		[C.ITEM_MACHETE, 1, {"kind":"slot", "container":equipment, "slot_identifier":String(EquippedItemReconciler.SLOT_MELEE)}],
		[C.ITEM_AMMO_762, 60, {"kind":"spatial", "container":pockets, "x":0, "y":0, "rotated":false}],
		[C.ITEM_BANDAGE, 2, {"kind":"spatial", "container":pockets, "x":1, "y":0, "rotated":false}],
		[C.ITEM_SPLINT, 2, {"kind":"spatial", "container":secure, "x":0, "y":0, "rotated":false}]]
	for row: Array in rows:
		if native.insert_item(id, String(row[0]), row[1], row[2], CONTENT_ACTOR).get("accepted") != true:
			return false
	return true

static func container_id(snapshot: InventorySnapshotResource, definition: StringName) -> int:
	for row: Dictionary in snapshot.get_containers():
		if row.provider_item == 0 and StringName(row.container_definition_identifier) == definition:
			return int(row.id)
	return 0
