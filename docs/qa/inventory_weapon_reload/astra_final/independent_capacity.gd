extends SceneTree
## Fresh validator fixture; never loads or subclasses a promoted test.

const OUT: String = "res://docs/qa/inventory_weapon_reload/astra_final/"
var checks: int = 0
var failures: int = 0
var assertions: Array[Dictionary] = []
var evidence: Dictionary = {}
var authority: InventoryAuthority
var inventory: int
var command: int = 84000


func _initialize() -> void:
	call_deferred("run")


func verify(condition: bool, label: String) -> void:
	checks += 1
	assertions.append({"check": checks, "label": label, "passed": condition})
	if not condition:
		failures += 1
		push_error("ASTRA_CAPACITY: " + label)


func run() -> void:
	var resource := ZerkovInventoryCatalog.build_resource()
	var magazine_definition: InventoryContainerDefinition
	var compatible_ammo: Array = []
	for value in resource.items:
		for trait_value in value.traits:
			if trait_value.trait_identifier == ZerkovInventoryCatalog.TRAIT_AMMO_762:
				compatible_ammo.append(String(value.identifier))
	for value in resource.containers:
		if value.identifier == ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM:
			magazine_definition = value
	verify(compatible_ammo == [String(ZerkovInventoryCatalog.ITEM_AMMO_762)],
		"sealed catalog has exactly one compatible ammunition mass definition")
	verify(ZerkovInventoryCatalog.MAGAZINE_AKM_CAPACITY_ROUNDS == 30
		and ZerkovCombatContent.AKM_CAPACITY == 30, "inventory and Weapon AKM both declare thirty rounds")
	verify(magazine_definition != null and magazine_definition.constraints.allow_nesting
		and magazine_definition.constraints.max_nesting_depth == 1, "magazine declares exact child depth one")
	verify(magazine_definition.constraints.has_mass_capacity
		and magazine_definition.constraints.mass_capacity_mg == 489000,
		"native magazine constraint declares 489000 mg")
	var catalog := ZerkovInventoryCatalog.build_sealed_catalog()
	verify(catalog != null and catalog.is_sealed(), "unmodified canonical catalog seals")
	authority = InventoryAuthority.new()
	authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	authority.set_catalog(catalog)
	root.add_child(authority)
	inventory = authority.create_inventory(String(ZerkovInventoryCatalog.PROFILE_PLAYER_RAID))
	verify(inventory > 0, "real canonical player raid inventory created")
	var backpack := container_id(ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var rig := container_id(ZerkovInventoryCatalog.CONTAINER_RIG)
	verify(backpack > 0 and rig > 0, "root container identities resolve")
	var full := shell(backpack, 0)
	var child_full := int(full["child"])
	var thirty := insert(ZerkovInventoryCatalog.ITEM_AMMO_762, 30, list_location(child_full, 0))
	evidence["fresh_30"] = thirty
	verify(bool(thirty.get("accepted", false)), "fresh thirty-round arrival succeeds")
	var full_stack := int(thirty.get("new_item_id", 0))
	verify(quantity(full_stack) == 30, "fresh thirty-round stack has exactly thirty")
	var mass: Dictionary = authority.container_mass_capacity(inventory, child_full)
	verify(bool(mass.get("ok", false)) and int(mass.get("mass_capacity_mg", 0)) == 489000,
		"native live child reports declared mass capacity")
	var spare := insert(ZerkovInventoryCatalog.ITEM_AMMO_762, 1, spatial(rig, 0))
	verify(bool(spare.get("accepted", false)), "loose round exists for cross-container merge")
	var before_merge := state()
	command += 1
	var merge_result: Dictionary = authority.merge_stacks(inventory,
		int(spare["new_item_id"]), full_stack, 8842, command)
	evidence["cross_container_merge"] = merge_result
	capacity_rejection(merge_result, "merge beyond thirty")
	verify(state() == before_merge, "over-capacity merge preserves bytes, revision and exact topology")
	verify(quantity(full_stack) == 30 and quantity(int(spare["new_item_id"])) == 1,
		"over-capacity merge preserves both source and target quantities")
	var empty := shell(backpack, 2)
	var child_empty := int(empty["child"])
	var before_31 := state()
	var thirty_one := insert(ZerkovInventoryCatalog.ITEM_AMMO_762, 31, list_location(child_empty, 0))
	evidence["fresh_31"] = thirty_one
	capacity_rejection(thirty_one, "fresh thirty-one arrival")
	verify(state() == before_31, "fresh thirty-one rejection preserves bytes, revision and complete topology")
	verify(container_id(ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM, int(empty["shell"])) == child_empty
		and quantity(int(empty["shell"])) == 1 and members(child_empty).is_empty(),
		"rejected thirty-one arrival retains shell and its empty child list")
	var filtered := shell(backpack, 4)
	var child_filter := int(filtered["child"])
	var before_filter := state()
	var incompatible := insert(ZerkovInventoryCatalog.ITEM_BANDAGE, 1, list_location(child_filter, 0))
	evidence["filter"] = incompatible
	verify(not bool(incompatible.get("accepted", true))
		and int((incompatible.get("status", {}) as Dictionary).get("diagnostic", 0)) == 118,
		"non-ammunition is rejected by native trait filter")
	verify(state() == before_filter, "trait-filter rejection is completely atomic")
	var one := insert(ZerkovInventoryCatalog.ITEM_AMMO_762, 1, list_location(child_filter, 0))
	verify(bool(one.get("accepted", false)), "one compatible round enters empty filtered list")
	var before_second := state()
	var second := insert(ZerkovInventoryCatalog.ITEM_AMMO_762, 1, list_location(child_filter, 1))
	evidence["second_stack"] = second
	verify(not bool(second.get("accepted", true))
		and int((second.get("status", {}) as Dictionary).get("diagnostic", 0)) == 26,
		"second stack rejects by list count even while mass is below capacity")
	verify(state() == before_second, "second-stack rejection preserves complete canonical state")
	command += 1
	var legal_merge: Dictionary = authority.merge_stacks(inventory,
		int(spare["new_item_id"]), int(one["new_item_id"]), 8842, command)
	evidence["legal_merge_control"] = legal_merge
	verify(bool(legal_merge.get("accepted", false)) and quantity(int(one["new_item_id"])) == 2
		and quantity(int(spare["new_item_id"])) == 0,
		"cross-container merge works below capacity, proving overflow rejection is specific")
	verify(authority.active_quantity_reservation_count() == 0, "capacity mutations create no reservation")
	evidence["final_topology"] = {"items": authority.snapshot(inventory).get_items(),
		"containers": authority.snapshot(inventory).get_containers(), "revision": authority.inventory_revision(inventory)}
	verify(bool(authority.unload_inventory(inventory).get("ok", false)), "capacity fixture unload succeeds")
	authority.free()
	authority = null
	var result := {"checks": checks, "failures": failures, "human_approval": false,
		"canonical_catalog": true, "diagnostic_115_blocker_absent": failures == 0,
		"assertions": assertions, "evidence": evidence}
	var file := FileAccess.open(OUT + "capacity_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t") + "\n")
	file.close()
	print("ASTRA_CAPACITY_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func shell(backpack: int, x: int) -> Dictionary:
	var result := insert(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM, 1, spatial(backpack, x))
	var item := int(result.get("new_item_id", 0))
	var child := container_id(ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM, item)
	verify(bool(result.get("accepted", false)) and item > 0 and child > 0,
		"canonical magazine materializes without diagnostic 115 at x=" + str(x))
	var snapshot := authority.snapshot(inventory)
	var provider: Dictionary = {}
	for value in snapshot.get_items():
		if int(value.get("id", 0)) == item:
			provider = value
	verify(int((provider.get("location", {}) as Dictionary).get("container", 0)) == backpack
		and int(child) != backpack and members(child).is_empty(),
		"provider in root owns empty child: actual ancestry establishes depth one at x=" + str(x))
	return {"shell": item, "child": child}


func capacity_rejection(result: Dictionary, label: String) -> void:
	var status := result.get("status", {}) as Dictionary
	verify(not bool(result.get("accepted", true)), label + " rejects")
	verify(int(status.get("code", -1)) == 6 and int(status.get("diagnostic", -1)) == 123
		and int(status.get("detail", -1)) == 505300, label + " has exact native 6/123/505300 diagnostic")


func insert(definition: StringName, count: int, location: Dictionary) -> Dictionary:
	command += 1
	return authority.insert_item(inventory, String(definition), count, location, 8842, command)


func container_id(definition: StringName, provider: int = 0) -> int:
	for value in authority.snapshot(inventory).get_containers():
		if StringName(value.get("container_definition_identifier", "")) == definition \
			and int(value.get("provider_item", 0)) == provider:
			return int(value.get("id", 0))
	return 0


func quantity(id: int) -> int:
	for value in authority.snapshot(inventory).get_items():
		if int(value.get("id", 0)) == id:
			return int(value.get("quantity", 0))
	return 0


func members(container: int) -> Array:
	var result: Array = []
	for value in authority.snapshot(inventory).get_items():
		if int((value.get("location", {}) as Dictionary).get("container", 0)) == container:
			result.append(value)
	return result


func state() -> Dictionary:
	var snapshot := authority.snapshot(inventory)
	return {"bytes": authority.make_persistence_record(inventory), "revision": snapshot.get_revision(),
		"items": snapshot.get_items(), "containers": snapshot.get_containers()}


func spatial(container: int, x: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": 0, "rotated": false}


func list_location(container: int, ordinal: int) -> Dictionary:
	return {"kind": "list", "container": container, "ordinal": ordinal}
