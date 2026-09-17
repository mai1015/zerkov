extends RefCounted
## Additional native negatives and reconciliation checks on the same controller
## used by the application. Native inserts here construct unit-test fixtures only.
const PRIMARY: StringName = &"zerkov.slot.weapon_primary"
var test: SceneTree
var publications: int = 0
var fixture_command: int = 8_000_000

func run(context: SceneTree) -> void:
	test = context
	var reconciler := test.get("reconciler") as EquippedItemReconciler
	reconciler.reconciliation_published.connect(_published)
	_exercise()
	if reconciler.reconciliation_published.is_connected(_published):
		reconciler.reconciliation_published.disconnect(_published)
	test = null

func _published(_outcome: Dictionary) -> void:
	publications += 1

func _check(ok: bool, text: String) -> bool:
	return bool(test.call("check", ok, text))

func _exercise() -> void:
	var owner := test.get("owner") as RaidInventoryOwner
	var controller := test.get("controller") as InventoryEquipmentController
	var bridge := test.get("bridge") as InventoryProjectionBridge
	var reconciler := test.get("reconciler") as EquippedItemReconciler
	var native := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var item: Dictionary = test.call("equipment", PRIMARY)
	var weapon_key := reconciler.weapon_id_for_slot(PRIMARY).canonical_key()
	var initial_count := publications
	if not _check(controller.submit_unequip(item).accepted, "controller mutation reaches native unequip"): return
	_check(reconciler.mapping_for_slot(PRIMARY).is_empty() and publications == initial_count + 1,
		"UI unequip removes the weapon mapping in one publication")
	var stored: Dictionary = test.call("find_item", controller.items_for(&"backpack"), item.item_id)
	if not _check(controller.submit_equip(&"backpack", stored, PRIMARY).accepted, "controller re-equip succeeds"): return
	_check(reconciler.weapon_id_for_slot(PRIMARY).canonical_key() == weapon_key and publications == initial_count + 2,
		"UI re-equip restores stable weapon identity exactly once")
	var duplicate := reconciler.reconcile_snapshot(&"raid", bridge.confirmed_snapshot(&"raid", inventory_id),
		owner.generation(), bridge.scope_generation(&"raid"))
	_check(duplicate.get("duplicate", false) and publications == initial_count + 2, "repeated confirmed projection does not duplicate reconciliation")
	var pack: Dictionary = controller.descriptor(&"backpack")
	var added := native.insert_item(inventory_id, String(ZerkovInventoryCatalog.ITEM_AKM), 1,
		{"kind":"spatial", "container":pack.container_id, "x":0, "y":0, "rotated":false}, LocalCampaignContent.CONTENT_ACTOR, _command())
	if not _check(added.accepted, "second compatible firearm constructed in native test"): return
	var other: Dictionary = test.call("find_item", controller.items_for(&"backpack"), added.new_item_id)
	var before := native.make_persistence_record(inventory_id)
	var occupied := controller.submit_equip(&"backpack", other, PRIMARY)
	_check(not occupied.accepted and native.make_persistence_record(inventory_id) == before,
		"occupied compatible slot rejects without swapping or losing either firearm")
	_check(native.remove_item(inventory_id, added.new_item_id, LocalCampaignContent.CONTENT_ACTOR, _command()).accepted, "remove second firearm fixture")
	# Exercise the two actual gear definitions too, without pretending root
	# storage was created by these optional named-slot equipment items.
	for pair: Array in [[ZerkovInventoryCatalog.ITEM_RIG_BASIC, &"zerkov.slot.rig"],
		[ZerkovInventoryCatalog.ITEM_BACKPACK_DAYPACK, &"zerkov.slot.backpack"]]:
		added = native.insert_item(inventory_id, String(pair[0]), 1,
			{"kind":"spatial", "container":pack.container_id, "x":0, "y":0, "rotated":false}, LocalCampaignContent.CONTENT_ACTOR, _command())
		if not _check(added.accepted, "canonical container gear fixture"): return
		other = test.call("find_item", controller.items_for(&"backpack"), added.new_item_id)
		var equipped := controller.submit_equip(&"backpack", other, pair[1])
		if not _check(equipped.accepted, "canonical rig/backpack equip: " + str(equipped)): return
		var gear: Dictionary = test.call("equipment", pair[1])
		_check(gear.item_id == added.new_item_id and gear.definition_id == String(pair[0]), "occupied gear slot uses canonical item identity")
		_check(reconciler.current_mappings().size() == 2, "nonweapon gear does not create a weapon mapping")
		if not _check(controller.submit_unequip(gear).accepted, "canonical rig/backpack unequip"): return
		_check(native.remove_item(inventory_id, added.new_item_id, LocalCampaignContent.CONTENT_ACTOR, _command()).accepted, "remove container gear fixture")
	# Fill only the controller's ordinary auto-placement destinations. It must
	# reject the whole operation, not delete gear or silently use secure space.
	var filler: Array[int] = []
	for source: StringName in [&"backpack", &"rig", &"pockets"]:
		var desc: Dictionary = controller.descriptor(source)
		for y in range(int(desc.rows)):
			for x in range(int(desc.columns)):
				if not controller._fits_target(source, {"w":1,"h":1}, Vector2i(x,y), 0): continue
				var result := native.insert_item(inventory_id, String(ZerkovInventoryCatalog.ITEM_BANDAGE), 1,
					{"kind":"spatial", "container":desc.container_id, "x":x, "y":y, "rotated":false}, LocalCampaignContent.CONTENT_ACTOR, _command())
				if result.accepted: filler.append(int(result.new_item_id))
	before = native.make_persistence_record(inventory_id)
	item = test.call("equipment", PRIMARY)
	var full := controller.submit_unequip(item)
	_check(not full.accepted and full.reason == &"equipment_no_space" and native.make_persistence_record(inventory_id) == before,
		"full loadout leaves equipped firearm and secure contents intact")
	for id: int in filler: _check(native.remove_item(inventory_id, id, LocalCampaignContent.CONTENT_ACTOR, _command()).accepted, "remove native occupancy fixture")
	item = test.call("equipment", PRIMARY)
	before = native.make_persistence_record(inventory_id)
	_check(native.apply_persistence_record(before, true).ok, "replace live inventory through native persistence boundary")
	_check(not controller.equipment_view().available and controller.equipment_view().slots.is_empty(), "owner-scope replacement invalidates equipment view")
	_check(not controller.submit_unequip(item).accepted and native.make_persistence_record(inventory_id) == before,
		"old equipment gesture cannot mutate the replacement inventory")

func _command() -> int:
	# Native fixture mutations and product intents use disjoint explicit IDs.
	# Never consume the next product request ID via a fixture auto-allocation.
	fixture_command += 1
	return fixture_command
