extends SceneTree
## Task 4.12a contract.
## Run with: godot --headless --path . --audio-driver Dummy \
##   --script res://tests/raid/inventory_nested_magazine_contract.gd

const ACTOR_ID: int = 8_412
const COMMAND_SEED_MAGAZINE: int = 84_120
const COMMAND_SEED_AMMUNITION: int = 84_121
const TRANSFER_COMMAND_BASE: int = 84_200
const LOADED_ROUNDS: int = 30
const LOADED_AMMUNITION_MASS_MG: int = \
	LOADED_ROUNDS * ZerkovInventoryCatalog.AMMO_762_UNIT_MASS_MG
const LOADED_MAGAZINE_SUBTREE_MASS_MG: int = 350_000 + LOADED_AMMUNITION_MASS_MG

var checks: int = 0
var failures: int = 0
var catalog: InventoryCatalog
var authority: InventoryAuthority


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_NESTED_MAGAZINE_CONTRACT: " + message)


func run() -> void:
	var resource := ZerkovInventoryCatalog.build_resource()
	_assert_profile_metadata(resource)
	catalog = ZerkovInventoryCatalog.build_sealed_catalog()
	check(catalog != null and catalog.is_sealed(),
		"normalized catalog registers and seals")
	if catalog == null:
		_finish()
		return

	authority = InventoryAuthority.new()
	authority.name = "InventoryNestedMagazineAuthority"
	authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	authority.set_catalog(catalog)
	root.add_child(authority)

	var cases := _profile_cases()
	var inventory_ids: Dictionary = {}
	var root_container_ids: Dictionary = {}
	for case_value in cases:
		var case := case_value as Dictionary
		var profile_id := StringName(case.get("profile", &""))
		var inventory_id := authority.create_inventory(String(profile_id))
		inventory_ids[profile_id] = inventory_id
		check(inventory_id > 0, String(case.get("label", "profile"))
			+ " inventory creates")
		var snapshot := authority.snapshot(inventory_id)
		var root_definition := StringName(case.get("root", &""))
		var root_container_id := _root_container_id(snapshot, root_definition)
		root_container_ids[profile_id] = root_container_id
		check(root_container_id > 0, String(case.get("label", "profile"))
			+ " root container resolves")
		_assert_exact_capabilities(authority, inventory_id, case)

	var player_id := int(inventory_ids.get(
		ZerkovInventoryCatalog.PROFILE_PLAYER_RAID, 0))
	var player_root_id := int(root_container_ids.get(
		ZerkovInventoryCatalog.PROFILE_PLAYER_RAID, 0))
	var magazine_insert: Dictionary = authority.insert_item(
		player_id,
		String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM),
		1,
		_spatial(player_root_id, 0, 0),
		ACTOR_ID,
		COMMAND_SEED_MAGAZINE
	)
	var magazine_item_id := int(magazine_insert.get("new_item_id", 0))
	var seeded_snapshot := authority.snapshot(player_id)
	var magazine_container_id := _provided_container_id(
		seeded_snapshot,
		magazine_item_id,
		ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM
	)
	check(bool(magazine_insert.get("accepted", false))
		and magazine_item_id > 0 and magazine_container_id > 0,
		"player source creates one stable magazine item and child container")
	var ammunition_insert: Dictionary = authority.insert_item(
		player_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		LOADED_ROUNDS,
		_list_location(magazine_container_id, 0),
		ACTOR_ID,
		COMMAND_SEED_AMMUNITION
	)
	var ammunition_item_id := int(ammunition_insert.get("new_item_id", 0))
	check(bool(ammunition_insert.get("accepted", false)) and ammunition_item_id > 0,
		"player source canonically loads thirty rounds into the magazine list")
	_assert_loaded_inventory(
		authority,
		player_id,
		ZerkovInventoryCatalog.PROFILE_PLAYER_RAID,
		player_root_id,
		5,
		28_000_000,
		magazine_item_id,
		magazine_container_id,
		ammunition_item_id,
		"player source"
	)

	var source_id := player_id
	for destination_index in range(1, cases.size()):
		var destination_case := cases[destination_index] as Dictionary
		var destination_profile := StringName(destination_case.get("profile", &""))
		var destination_id := int(inventory_ids.get(destination_profile, 0))
		var destination_root_id := int(root_container_ids.get(destination_profile, 0))
		var label := String(destination_case.get("label", "destination"))
		var command_base := TRANSFER_COMMAND_BASE + destination_index * 10

		_assert_wrong_layout_transfer_is_atomic(
			source_id,
			destination_id,
			destination_root_id,
			magazine_item_id,
			command_base,
			label
		)

		var source_revision_before := authority.inventory_revision(source_id)
		var destination_revision_before := authority.inventory_revision(destination_id)
		var transfer_location := _spatial(destination_root_id, 0, 0)
		var transfer_result: Dictionary = authority.loot_item(
			source_id,
			destination_id,
			magazine_item_id,
			transfer_location,
			ACTOR_ID,
			command_base + 1
		)
		check(bool(transfer_result.get("accepted", false))
			and not bool(transfer_result.get("replayed", true))
			and int(transfer_result.get("transferred_quantity", 0)) == 1
			and int(transfer_result.get("remaining_quantity", -1)) == 0,
			label + " accepts the complete magazine subtree transfer")
		check(authority.inventory_revision(source_id) == source_revision_before + 1
			and authority.inventory_revision(destination_id)
				== destination_revision_before + 1,
			label + " transfer advances each touched inventory exactly once")
		check(not _snapshot_has_item(authority.snapshot(source_id), magazine_item_id)
			and not _snapshot_has_item(authority.snapshot(source_id), ammunition_item_id)
			and _provided_container_id(
				authority.snapshot(source_id),
				magazine_item_id,
				ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM) == 0,
			label + " transfer removes the complete subtree from its source")

		_assert_loaded_inventory(
			authority,
			destination_id,
			destination_profile,
			destination_root_id,
			1,
			int(destination_case.get("root_mass_capacity_mg", 0)),
			magazine_item_id,
			magazine_container_id,
			ammunition_item_id,
			label
		)
		_assert_transfer_replay_is_idempotent(
			source_id,
			destination_id,
			magazine_item_id,
			transfer_location,
			command_base + 1,
			label
		)
		_assert_persistence_round_trip(
			destination_id,
			destination_profile,
			destination_root_id,
			int(destination_case.get("root_mass_capacity_mg", 0)),
			magazine_item_id,
			magazine_container_id,
			ammunition_item_id,
			label
		)
		source_id = destination_id

	_cleanup(cases, inventory_ids)
	_finish()


func _assert_profile_metadata(resource: InventoryCatalogResource) -> void:
	check(resource != null, "catalog resource builds for metadata inspection")
	if resource == null:
		return
	for case_value in _profile_cases():
		var case := case_value as Dictionary
		var profile_id := StringName(case.get("profile", &""))
		var profile := _profile(resource, profile_id)
		var expected_features := case.get("features", PackedStringArray()) \
			as PackedStringArray
		check(profile != null, String(case.get("label", "profile"))
			+ " profile exists")
		check(profile != null and profile.enabled_features == expected_features,
			String(case.get("label", "profile"))
				+ " publishes the exact normalized capability list: expected="
				+ str(expected_features) + " actual="
				+ str(profile.enabled_features if profile != null else PackedStringArray()))
		if profile == null:
			continue
		var expected_limits := case.get("limits", PackedInt64Array()) as PackedInt64Array
		check(_profile_limits(profile) == expected_limits,
			String(case.get("label", "profile"))
				+ " keeps its sealed item/container/reference/nesting/component limits")


func _assert_exact_capabilities(
	target_authority: InventoryAuthority,
	inventory_id: int,
	case: Dictionary
) -> void:
	var expected_features := case.get("features", PackedStringArray()) as PackedStringArray
	var known_features := PackedStringArray([
		ZerkovInventoryCatalog.FEATURE_SPATIAL,
		ZerkovInventoryCatalog.FEATURE_SLOTS,
		ZerkovInventoryCatalog.FEATURE_LIST,
		ZerkovInventoryCatalog.FEATURE_COUNT,
		ZerkovInventoryCatalog.FEATURE_MASS,
		ZerkovInventoryCatalog.FEATURE_FILTER,
		ZerkovInventoryCatalog.FEATURE_NESTING,
		ZerkovInventoryCatalog.FEATURE_RETENTION,
		ZerkovInventoryCatalog.FEATURE_STACKING,
		ZerkovInventoryCatalog.FEATURE_AUTO,
		ZerkovInventoryCatalog.FEATURE_QUICK,
		ZerkovInventoryCatalog.FEATURE_ROTATION,
		ZerkovInventoryCatalog.FEATURE_DISCOVERY,
	])
	var label := String(case.get("label", "profile"))
	for feature in known_features:
		check(target_authority.has_feature(inventory_id, feature)
			== expected_features.has(feature),
			label + " exact capability query matches metadata for " + feature)
	check(not target_authority.has_feature(
		inventory_id, "inventory.feature.not_authored"),
		label + " unknown capability query fails closed")


func _assert_wrong_layout_transfer_is_atomic(
	source_id: int,
	destination_id: int,
	destination_root_id: int,
	magazine_item_id: int,
	command_id: int,
	label: String
) -> void:
	var source_before := _inventory_state(authority, source_id)
	var destination_before := _inventory_state(authority, destination_id)
	var rejection: Dictionary = authority.loot_item(
		source_id,
		destination_id,
		magazine_item_id,
		_list_location(destination_root_id, 0),
		ACTOR_ID,
		command_id
	)
	var status := rejection.get("status", {}) as Dictionary
	check(not bool(rejection.get("accepted", true))
		and int(status.get("code", -1)) == InventoryCatalog.STATUS_INVALID_ARGUMENT
		and int(status.get("diagnostic", -1)) == 61,
		label + " rejects a list placement against its spatial root with stable status")
	check(_inventory_state(authority, source_id) == source_before
		and _inventory_state(authority, destination_id) == destination_before,
		label + " wrong-layout transfer is fail-atomic for both inventories")


func _assert_transfer_replay_is_idempotent(
	source_id: int,
	destination_id: int,
	magazine_item_id: int,
	destination_location: Dictionary,
	command_id: int,
	label: String
) -> void:
	var source_before := _inventory_state(authority, source_id)
	var destination_before := _inventory_state(authority, destination_id)
	var replay: Dictionary = authority.loot_item(
		source_id,
		destination_id,
		magazine_item_id,
		destination_location,
		ACTOR_ID,
		command_id
	)
	check(bool(replay.get("accepted", false))
		and bool(replay.get("replayed", false))
		and int(replay.get("transferred_quantity", 0)) == 1
		and int(replay.get("remaining_quantity", -1)) == 0
		and (replay.get("events", []) as Array).is_empty(),
		label + " exact command replay returns its terminal receipt without events")
	check(_inventory_state(authority, source_id) == source_before
		and _inventory_state(authority, destination_id) == destination_before,
		label + " exact command replay leaves both inventories byte-identical")

	var conflict_location := destination_location.duplicate(true)
	conflict_location["x"] = int(conflict_location.get("x", 0)) + 1
	var conflict: Dictionary = authority.loot_item(
		source_id,
		destination_id,
		magazine_item_id,
		conflict_location,
		ACTOR_ID,
		command_id
	)
	var conflict_status := conflict.get("status", {}) as Dictionary
	check(not bool(conflict.get("accepted", true))
		and int(conflict_status.get("code", -1))
			== InventoryCatalog.STATUS_DUPLICATE_COMMAND
		and int(conflict_status.get("diagnostic", -1)) == 125,
		label + " command-id payload conflict fails closed with stable status")
	check(_inventory_state(authority, source_id) == source_before
		and _inventory_state(authority, destination_id) == destination_before,
		label + " command-id conflict cannot mutate either inventory")


func _assert_persistence_round_trip(
	inventory_id: int,
	profile_id: StringName,
	root_container_id: int,
	root_mass_capacity_mg: int,
	magazine_item_id: int,
	magazine_container_id: int,
	ammunition_item_id: int,
	label: String
) -> void:
	var live_snapshot := authority.snapshot(inventory_id)
	var live_snapshot_bytes := live_snapshot.canonical_bytes()
	var live_snapshot_hash := live_snapshot.hash()
	var record := authority.make_persistence_record(inventory_id)
	check(not record.is_empty()
		and record == authority.make_persistence_record(inventory_id),
		label + " persistence encoding is deterministic without mutation")

	var restored_authority := InventoryAuthority.new()
	restored_authority.name = "Restored" + label.replace(" ", "").capitalize()
	restored_authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	restored_authority.set_catalog(catalog)
	root.add_child(restored_authority)
	var restore_result: Dictionary = restored_authority.apply_persistence_record(record)
	check(bool(restore_result.get("ok", false))
		and int(restore_result.get("inventory_id", 0)) == inventory_id,
		label + " persistence record restores its exact inventory identity")
	var restored_snapshot := restored_authority.snapshot(inventory_id)
	check(restored_snapshot != null
		and restored_snapshot.canonical_bytes() == live_snapshot_bytes
		and restored_snapshot.hash() == live_snapshot_hash,
		label + " persistence restore reproduces exact snapshot bytes and hash")
	check(restored_authority.make_persistence_record(inventory_id) == record,
		label + " restored persistence bytes are deterministic and identical")
	_assert_exact_capabilities(
		restored_authority, inventory_id, _profile_case(profile_id))
	_assert_loaded_inventory(
		restored_authority,
		inventory_id,
		profile_id,
		root_container_id,
		1,
		root_mass_capacity_mg,
		magazine_item_id,
		magazine_container_id,
		ammunition_item_id,
		label + " restored"
	)

	var state_before_overfill := _inventory_state(restored_authority, inventory_id)
	var overfill: Dictionary = restored_authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		1,
		_list_location(magazine_container_id, 1),
		ACTOR_ID,
		TRANSFER_COMMAND_BASE + 100 + inventory_id
	)
	var overfill_status := overfill.get("status", {}) as Dictionary
	check(not bool(overfill.get("accepted", true))
		and int(overfill_status.get("code", -1))
			== InventoryCatalog.STATUS_LIMIT_EXCEEDED,
		label + " restored full magazine rejects an extra round")
	check(_inventory_state(restored_authority, inventory_id) == state_before_overfill,
		label + " restored capacity rejection preserves all canonical bytes")

	var unload_result: Dictionary = restored_authority.unload_inventory(inventory_id)
	check(bool(unload_result.get("ok", false)),
		label + " restored inventory unloads cleanly")
	root.remove_child(restored_authority)
	restored_authority.free()


func _assert_loaded_inventory(
	target_authority: InventoryAuthority,
	inventory_id: int,
	profile_id: StringName,
	root_container_id: int,
	expected_root_count: int,
	root_mass_capacity_mg: int,
	magazine_item_id: int,
	magazine_container_id: int,
	ammunition_item_id: int,
	label: String
) -> void:
	var snapshot := target_authority.snapshot(inventory_id)
	check(snapshot != null, label + " owner snapshot exists")
	if snapshot == null:
		return
	check(snapshot.get_inventory_id() == inventory_id
		and snapshot.get_profile_identifier() == String(profile_id)
		and snapshot.get_visibility() == InventorySnapshotResource.VISIBILITY_OWNER,
		label + " snapshot keeps inventory/profile/owner identity")
	check(snapshot.get_manifest_fingerprint() == catalog.manifest_fingerprint()
		and not snapshot.canonical_bytes().is_empty(),
		label + " snapshot binds the sealed manifest and canonical bytes")
	check(snapshot.get_items().size() == 2
		and snapshot.get_containers().size() == expected_root_count + 1,
		label + " snapshot exposes exactly magazine, ammunition, roots, and one child")

	var magazine := _snapshot_item(snapshot, magazine_item_id)
	var ammunition := _snapshot_item(snapshot, ammunition_item_id)
	var magazine_location := magazine.get("location", {}) as Dictionary
	var ammunition_location := ammunition.get("location", {}) as Dictionary
	var provided_ids := magazine.get("provided_containers", PackedInt64Array()) \
		as PackedInt64Array
	check(StringName(magazine.get("item_definition_identifier", &""))
			== ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM
		and int(magazine.get("quantity", 0)) == 1
		and provided_ids == PackedInt64Array([magazine_container_id])
		and _location_equals(magazine_location, _spatial(root_container_id, 0, 0)),
		label + " snapshot preserves stable magazine identity, provider edge, and placement")
	check(StringName(ammunition.get("item_definition_identifier", &""))
			== ZerkovInventoryCatalog.ITEM_AMMO_762
		and int(ammunition.get("quantity", 0)) == LOADED_ROUNDS
		and _location_equals(
			ammunition_location, _list_location(magazine_container_id, 0)),
		label + " snapshot exposes thirty rounds in the stable ordered-list child")
	var provided_container := _snapshot_container(snapshot, magazine_container_id)
	check(StringName(provided_container.get(
			"container_definition_identifier", &""))
			== ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM
		and int(provided_container.get("provider_item", 0)) == magazine_item_id,
		label + " snapshot preserves the child-container-to-provider identity edge")

	var total_mass := target_authority.total_mass(inventory_id)
	var root_mass := target_authority.container_mass(inventory_id, root_container_id)
	var child_mass := target_authority.container_mass(
		inventory_id, magazine_container_id)
	var root_capacity := target_authority.container_mass_capacity(
		inventory_id, root_container_id)
	var child_capacity := target_authority.container_mass_capacity(
		inventory_id, magazine_container_id)
	var root_count := target_authority.count_in_container(inventory_id, root_container_id)
	var child_count := target_authority.count_in_container(
		inventory_id, magazine_container_id)
	var child_remaining := target_authority.remaining_count_capacity(
		inventory_id, magazine_container_id)
	check(bool(total_mass.get("ok", false))
		and int(total_mass.get("mass_mg", -1)) == LOADED_MAGAZINE_SUBTREE_MASS_MG,
		label + " total-mass query counts the nested subtree exactly once")
	check(bool(root_mass.get("ok", false))
		and int(root_mass.get("mass_mg", -1)) == LOADED_MAGAZINE_SUBTREE_MASS_MG,
		label + " root-mass query includes the complete magazine subtree")
	check(bool(child_mass.get("ok", false))
		and int(child_mass.get("mass_mg", -1)) == LOADED_AMMUNITION_MASS_MG,
		label + " child-mass query reports only its thirty contained rounds")
	check(bool(root_capacity.get("ok", false))
		and int(root_capacity.get("mass_capacity_mg", -1)) == root_mass_capacity_mg
		and bool(child_capacity.get("ok", false))
		and int(child_capacity.get("mass_capacity_mg", -1))
			== ZerkovInventoryCatalog.MAGAZINE_AKM_AMMO_CAPACITY_MG,
		label + " queries retain exact root and magazine mass capacities")
	check(bool(root_count.get("ok", false))
		and int(root_count.get("count", -1)) == 1
		and bool(child_count.get("ok", false))
		and int(child_count.get("count", -1)) == 1
		and bool(child_remaining.get("ok", false))
		and int(child_remaining.get("remaining", -1)) == 0,
		label + " count queries retain one parent, one child stack, and no list headroom")


func _profile_cases() -> Array[Dictionary]:
	var nested_grid_features := PackedStringArray([
		ZerkovInventoryCatalog.FEATURE_SPATIAL,
		ZerkovInventoryCatalog.FEATURE_COUNT,
		ZerkovInventoryCatalog.FEATURE_MASS,
		ZerkovInventoryCatalog.FEATURE_STACKING,
		ZerkovInventoryCatalog.FEATURE_AUTO,
		ZerkovInventoryCatalog.FEATURE_QUICK,
		ZerkovInventoryCatalog.FEATURE_ROTATION,
		ZerkovInventoryCatalog.FEATURE_NESTING,
		ZerkovInventoryCatalog.FEATURE_LIST,
	])
	var player_features := nested_grid_features.duplicate()
	player_features.append(ZerkovInventoryCatalog.FEATURE_SLOTS)
	player_features.append(ZerkovInventoryCatalog.FEATURE_FILTER)
	player_features.append(ZerkovInventoryCatalog.FEATURE_RETENTION)
	var world_features := nested_grid_features.duplicate()
	world_features.append(ZerkovInventoryCatalog.FEATURE_DISCOVERY)
	return [
		{
			"label": "player raid",
			"profile": ZerkovInventoryCatalog.PROFILE_PLAYER_RAID,
			"root": ZerkovInventoryCatalog.CONTAINER_BACKPACK,
			"root_mass_capacity_mg": 28_000_000,
			"features": player_features,
			"limits": PackedInt64Array([128, 24, 32, 4, 8]),
		},
		{
			"label": "stash",
			"profile": ZerkovInventoryCatalog.PROFILE_STASH,
			"root": ZerkovInventoryCatalog.CONTAINER_STASH,
			"root_mass_capacity_mg": 250_000_000,
			"features": nested_grid_features,
			"limits": PackedInt64Array([512, 64, 32, 8, 8]),
		},
		{
			"label": "world crate",
			"profile": ZerkovInventoryCatalog.PROFILE_WORLD_CRATE,
			"root": ZerkovInventoryCatalog.CONTAINER_WORLD_CRATE,
			"root_mass_capacity_mg": 100_000_000,
			"features": world_features,
			"limits": PackedInt64Array([64, 16, 32, 4, 8]),
		},
		{
			"label": "corpse",
			"profile": ZerkovInventoryCatalog.PROFILE_CORPSE,
			"root": ZerkovInventoryCatalog.CONTAINER_CORPSE,
			"root_mass_capacity_mg": 120_000_000,
			"features": world_features,
			"limits": PackedInt64Array([96, 24, 32, 4, 8]),
		},
	]


func _profile_case(profile_id: StringName) -> Dictionary:
	for case_value in _profile_cases():
		var case := case_value as Dictionary
		if StringName(case.get("profile", &"")) == profile_id:
			return case
	return {}


func _profile(
	resource: InventoryCatalogResource,
	profile_id: StringName
) -> InventoryProfileDefinition:
	for profile_value in resource.profiles:
		var profile := profile_value as InventoryProfileDefinition
		if profile.identifier == profile_id:
			return profile
	return null


func _profile_limits(profile: InventoryProfileDefinition) -> PackedInt64Array:
	if profile == null or profile.limits == null:
		return PackedInt64Array()
	return PackedInt64Array([
		profile.limits.max_items,
		profile.limits.max_containers,
		profile.limits.max_references,
		profile.limits.max_nesting_depth,
		profile.limits.max_mutable_components_per_item,
	])


func _root_container_id(
	snapshot: InventorySnapshotResource,
	definition: StringName
) -> int:
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
			and StringName(container.get(
				"container_definition_identifier", &"")) == definition:
			return int(container.get("id", 0))
	return 0


func _provided_container_id(
	snapshot: InventorySnapshotResource,
	provider_item_id: int,
	definition: StringName
) -> int:
	if snapshot == null or provider_item_id <= 0:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == provider_item_id \
			and StringName(container.get(
				"container_definition_identifier", &"")) == definition:
			return int(container.get("id", 0))
	return 0


func _snapshot_container(
	snapshot: InventorySnapshotResource,
	container_id: int
) -> Dictionary:
	if snapshot == null:
		return {}
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("id", 0)) == container_id:
			return container
	return {}


func _snapshot_item(snapshot: InventorySnapshotResource, item_id: int) -> Dictionary:
	if snapshot == null:
		return {}
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return item
	return {}


func _snapshot_has_item(snapshot: InventorySnapshotResource, item_id: int) -> bool:
	return not _snapshot_item(snapshot, item_id).is_empty()


func _inventory_state(
	target_authority: InventoryAuthority,
	inventory_id: int
) -> Dictionary:
	var snapshot := target_authority.snapshot(inventory_id)
	if snapshot == null:
		return {}
	return {
		"revision": target_authority.inventory_revision(inventory_id),
		"snapshot": snapshot.canonical_bytes(),
		"persistence": target_authority.make_persistence_record(inventory_id),
	}


func _spatial(container_id: int, x: int, y: int) -> Dictionary:
	return {
		"kind": "spatial",
		"container": container_id,
		"x": x,
		"y": y,
		"rotated": false,
	}


func _list_location(container_id: int, ordinal: int) -> Dictionary:
	return {
		"kind": "list",
		"container": container_id,
		"ordinal": ordinal,
	}


func _location_equals(actual: Dictionary, expected: Dictionary) -> bool:
	if String(actual.get("kind", "")) != String(expected.get("kind", "")) \
		or int(actual.get("container", 0)) != int(expected.get("container", -1)):
		return false
	match String(expected.get("kind", "")):
		"spatial":
			return int(actual.get("x", -1)) == int(expected.get("x", -2)) \
				and int(actual.get("y", -1)) == int(expected.get("y", -2)) \
				and bool(actual.get("rotated", true)) \
					== bool(expected.get("rotated", false))
		"list":
			return int(actual.get("ordinal", -1)) \
				== int(expected.get("ordinal", -2))
	return false


func _cleanup(cases: Array[Dictionary], inventory_ids: Dictionary) -> void:
	if authority == null:
		return
	for case_value in cases:
		var case := case_value as Dictionary
		var inventory_id := int(inventory_ids.get(
			StringName(case.get("profile", &"")), 0))
		if inventory_id > 0 and authority.has_inventory(inventory_id):
			check(bool(authority.unload_inventory(inventory_id).get("ok", false)),
				String(case.get("label", "profile")) + " inventory unloads cleanly")
	root.remove_child(authority)
	authority.free()
	authority = null


func _finish() -> void:
	print("INVENTORY_NESTED_MAGAZINE_RESULT checks=", checks,
		" failures=", failures)
	quit(0 if failures == 0 else 1)
