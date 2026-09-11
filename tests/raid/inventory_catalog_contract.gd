extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/inventory_catalog_contract.gd

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_CATALOG_CONTRACT: " + message)


func run() -> void:
	var resource := ZerkovInventoryCatalog.build_resource()
	check(resource != null, "catalog resource builds")
	check(resource.items.size() == 16, "first-playable catalog has 16 focused items")
	check(resource.containers.size() == 9, "catalog has nine container/equipment definitions")
	check(resource.profiles.size() == 4, "catalog has player, stash, crate, and corpse profiles")
	check(resource.trait_schemas.size() == 8,
		"slot, ammunition, and medical-consumption traits are explicit")
	check(resource.discovery_policies.size() == 1, "world loot has one staged-search policy")

	var identifiers: Dictionary = {}
	var trait_identifiers: Dictionary = {}
	for trait_value in resource.trait_schemas:
		var trait_schema := trait_value as InventoryTraitSchema
		check(_is_valid_identifier(String(trait_schema.identifier)),
			"trait identifier follows the stable grammar: " + String(trait_schema.identifier))
		trait_identifiers[String(trait_schema.identifier)] = true
	for policy_value in resource.discovery_policies:
		var policy := policy_value as InventoryDiscoveryPolicy
		check(_is_valid_identifier(String(policy.identifier)),
			"discovery identifier follows the stable grammar: " + String(policy.identifier))
		check((policy.container_search_instant and policy.container_search_duration_ms == 0)
			or (not policy.container_search_instant and policy.container_search_duration_ms > 0
			and policy.container_search_duration_ms <= 86_400_000),
			"container discovery duration is explicit and bounded")
		check((policy.item_scan_instant and policy.item_scan_duration_ms == 0)
			or (not policy.item_scan_instant and policy.item_scan_duration_ms > 0
			and policy.item_scan_duration_ms <= 86_400_000),
			"item discovery duration is explicit and bounded")
	for item_value in resource.items:
		var item := item_value as InventoryItemDefinition
		check(not identifiers.has(String(item.identifier)), "item identifier is unique")
		identifiers[String(item.identifier)] = true
		check(_is_valid_identifier(String(item.identifier)),
			"item identifier follows the stable grammar: " + String(item.identifier))
		check(item.max_stack > 0 and item.max_stack <= 1_000_000,
			"item stack limit is positive and bounded")
		check(item.unit_mass_mg > 0, "item mass is positive")
		check(item.footprint_width > 0 and item.footprint_width <= 64
			and item.footprint_height > 0 and item.footprint_height <= 64,
			"item footprint is bounded")
		check(item.traits.size() <= 32, "item trait count is bounded")
		check(item.provided_containers.size() <= 8, "item-provided container count is bounded")
		for item_trait_value in item.traits:
			var item_trait := item_trait_value as InventoryItemTraitValue
			check(_is_valid_identifier(String(item_trait.trait_identifier)),
				"item trait reference follows the stable grammar")
			check(trait_identifiers.has(String(item_trait.trait_identifier)),
				"item trait reference resolves in the authored catalog")
		for provided_identifier in item.provided_containers:
			check(_is_valid_identifier(String(provided_identifier)),
				"provided-container reference follows the stable grammar")
	for expected_id in ZerkovInventoryCatalog.FIRST_PLAYABLE_ITEM_IDS:
		check(identifiers.has(String(expected_id)), "required item is authored: " + String(expected_id))

	var containers_by_id: Dictionary = {}
	for container_value in resource.containers:
		var container := container_value as InventoryContainerDefinition
		var container_id := String(container.identifier)
		check(_is_valid_identifier(container_id),
			"container identifier follows the stable grammar: " + container_id)
		check(not containers_by_id.has(container_id), "container identifier is unique")
		containers_by_id[container_id] = container
		check(_container_layout_is_bounded(container), "container layout is bounded: " + container_id)
		check(_container_constraints_are_bounded(container),
			"container constraints are bounded: " + container_id)
		for feature in _required_container_features(container):
			check(container.enabled_features.has(feature),
				"container feature closure includes " + feature + " for " + container_id)
		for feature in container.enabled_features:
			check(_is_valid_identifier(String(feature)),
				"container feature reference follows the stable grammar")
		if not String(container.discovery_policy_identifier).is_empty():
			check(_is_valid_identifier(String(container.discovery_policy_identifier)),
				"container discovery reference follows the stable grammar")
		for slot_value in container.named_slots:
			var slot := slot_value as InventoryNamedSlot
			check(_is_valid_identifier(String(slot.identifier)),
				"named-slot identifier follows the stable grammar")
			check(slot.max_items > 0, "named-slot cardinality is positive")
			for required_trait in slot.required_traits:
				check(trait_identifiers.has(String(required_trait)),
					"named-slot required trait resolves")

	for item_value in resource.items:
		var item := item_value as InventoryItemDefinition
		for provided_identifier in item.provided_containers:
			check(containers_by_id.has(String(provided_identifier)),
				"item-provided container resolves in the authored catalog")

	var profile_identifiers: Dictionary = {}
	for profile_value in resource.profiles:
		var profile := profile_value as InventoryProfileDefinition
		var profile_id := String(profile.identifier)
		check(_is_valid_identifier(profile_id),
			"profile identifier follows the stable grammar: " + profile_id)
		check(not profile_identifiers.has(profile_id), "profile identifier is unique")
		profile_identifiers[profile_id] = true
		check(not profile.root_containers.is_empty() and profile.root_containers.size() <= 32,
			"profile root-container count is bounded")
		check(_profile_limits_are_bounded(profile.limits), "profile aggregate limits are bounded")
		for root_identifier in profile.root_containers:
			var root_id := String(root_identifier)
			check(_is_valid_identifier(root_id), "profile root reference follows the stable grammar")
			check(containers_by_id.has(root_id), "profile root reference resolves")
			if containers_by_id.has(root_id):
				var root_container := containers_by_id[root_id] as InventoryContainerDefinition
				for feature in root_container.enabled_features:
					check(profile.enabled_features.has(feature),
						"profile feature closure includes root feature " + String(feature))
		for feature in profile.enabled_features:
			check(_is_valid_identifier(String(feature)),
				"profile feature reference follows the stable grammar")

	var validator := InventoryCatalog.new()
	var findings: Array = validator.validate_resource(resource)
	check(not findings.is_empty(), "native catalog validator returns findings")
	for finding_value in findings:
		var finding := finding_value as Dictionary
		check(int(finding.get("status_code", -1)) == InventoryCatalog.STATUS_OK,
			"native catalog validation accepts: " + str(finding))

	var catalog := ZerkovInventoryCatalog.build_sealed_catalog()
	check(catalog != null and catalog.is_sealed(), "catalog registers and seals")
	if catalog != null:
		var fingerprint := catalog.manifest_fingerprint()
		check(fingerprint != 0, "sealed catalog has a content fingerprint")
		(resource.items[0] as InventoryItemDefinition).unit_mass_mg = 1
		check(catalog.manifest_fingerprint() == fingerprint,
			"post-seal resource mutation cannot change canonical catalog")

	var secure := _container(resource, ZerkovInventoryCatalog.CONTAINER_SECURE)
	check(secure != null, "secure container exists")
	check(secure != null and secure.constraints.retention == InventoryContainerConstraints.RETENTION_PROTECTED,
		"secure container is protected-retention")
	var equipment := _container(resource, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	check(equipment != null and equipment.layout_kind == InventoryContainerDefinition.LAYOUT_NAMED_SLOTS,
		"equipment uses canonical named slots")
	check(equipment != null and equipment.named_slots.size() == 4,
		"equipment has primary, melee, rig, and backpack slots")
	var world_crate := _container(resource, ZerkovInventoryCatalog.CONTAINER_WORLD_CRATE)
	check(world_crate != null and world_crate.discovery_policy_identifier
		== ZerkovInventoryCatalog.DISCOVERY_WORLD_LOOT,
		"world crate is staged-searchable")
	var corpse := _container(resource, ZerkovInventoryCatalog.CONTAINER_CORPSE)
	check(corpse != null and corpse.discovery_policy_identifier
		== ZerkovInventoryCatalog.DISCOVERY_WORLD_LOOT,
		"corpse inventory is staged-searchable")
	var magazine_container := _container(
		resource, ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM)
	check(magazine_container != null
		and magazine_container.layout_kind == InventoryContainerDefinition.LAYOUT_ORDERED_LIST
		and magazine_container.ordered_list_max_entries == 1,
		"AKM magazine owns one ordered ammunition stack")
	check(ZerkovInventoryCatalog.MAGAZINE_AKM_CAPACITY_ROUNDS
		== ZerkovCombatContent.AKM_CAPACITY,
		"inventory magazine round capacity matches the authored Weapon AKM capacity")
	check(magazine_container != null
		and magazine_container.constraints.has_mass_capacity
		and magazine_container.constraints.mass_capacity_mg
			== ZerkovInventoryCatalog.MAGAZINE_AKM_AMMO_CAPACITY_MG
		and ZerkovInventoryCatalog.MAGAZINE_AKM_AMMO_CAPACITY_MG
			== ZerkovInventoryCatalog.MAGAZINE_AKM_CAPACITY_ROUNDS \
				* ZerkovInventoryCatalog.AMMO_762_UNIT_MASS_MG,
		"AKM magazine declares the exact fixed-mass equivalent of thirty rounds")
	check(magazine_container != null
		and magazine_container.enabled_features.has(ZerkovInventoryCatalog.FEATURE_MASS),
		"magazine container enables native mass-capacity enforcement")
	check(magazine_container != null
		and magazine_container.constraints.allow_nesting
		and magazine_container.constraints.max_nesting_depth == 1,
		"item-provided magazine container admits its exact depth-one materialization")
	check(magazine_container != null
		and magazine_container.enabled_features.has(ZerkovInventoryCatalog.FEATURE_NESTING),
		"magazine container declares the nesting feature required by its constraints")
	var player_profile := _profile(resource, ZerkovInventoryCatalog.PROFILE_PLAYER_RAID)
	check(player_profile != null
		and player_profile.enabled_features.has(ZerkovInventoryCatalog.FEATURE_LIST)
		and player_profile.enabled_features.has(ZerkovInventoryCatalog.FEATURE_MASS)
		and player_profile.enabled_features.has(ZerkovInventoryCatalog.FEATURE_NESTING),
		"player profile reports the nested ordered-list and mass capabilities it materializes")
	for nested_profile_id in [
		ZerkovInventoryCatalog.PROFILE_STASH,
		ZerkovInventoryCatalog.PROFILE_WORLD_CRATE,
		ZerkovInventoryCatalog.PROFILE_CORPSE,
	]:
		var nested_profile := _profile(resource, nested_profile_id)
		check(nested_profile != null
			and nested_profile.enabled_features.has(ZerkovInventoryCatalog.FEATURE_LIST),
			String(nested_profile_id)
				+ " reports the ordered-list capability of carried magazine children")
	if catalog != null:
		_run_live_magazine_contract(catalog)

	print("INVENTORY_CATALOG_RESULT checks=", checks, " failures=", failures,
		" findings=", findings.size())
	quit(0 if failures == 0 else 1)


func _run_live_magazine_contract(catalog: InventoryCatalog) -> void:
	var authority := InventoryAuthority.new()
	authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	authority.set_catalog(catalog)
	root.add_child(authority)
	var inventory_id := authority.create_inventory(
		String(ZerkovInventoryCatalog.PROFILE_PLAYER_RAID))
	check(inventory_id > 0, "canonical player raid inventory creates for live magazine proof")
	if inventory_id <= 0:
		root.remove_child(authority)
		authority.free()
		return
	check(authority.has_feature(
		inventory_id, ZerkovInventoryCatalog.FEATURE_LIST),
		"live player inventory advertises ordered-list support")
	check(authority.has_feature(
		inventory_id, ZerkovInventoryCatalog.FEATURE_NESTING),
		"live player inventory advertises nested-container support")
	var initial_snapshot := authority.snapshot(inventory_id)
	var backpack_id := _root_container_id(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var rig_id := _root_container_id(initial_snapshot, ZerkovInventoryCatalog.CONTAINER_RIG)
	check(backpack_id > 0 and rig_id > 0,
		"canonical player backpack and rig resolve for live magazine proof")

	# A full magazine is accepted at the declared boundary.
	var full_magazine_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM),
		1,
		{
			"kind": "spatial",
			"container": backpack_id,
			"x": 0,
			"y": 0,
			"rotated": false,
		},
		7_201,
		7_001
	)
	var full_magazine_item_id := int(full_magazine_insert.get("new_item_id", 0))
	var full_magazine_container_id := _provided_container_id(
		authority.snapshot(inventory_id),
		full_magazine_item_id,
		ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM)
	check(bool(full_magazine_insert.get("accepted", false))
		and full_magazine_item_id > 0 and full_magazine_container_id > 0,
		"real AKM magazine inserts and materializes its ammunition container")
	var capacity_result: Dictionary = authority.container_mass_capacity(
		inventory_id, full_magazine_container_id)
	check(bool(capacity_result.get("ok", false))
		and int(capacity_result.get("mass_capacity_mg", -1))
			== ZerkovInventoryCatalog.MAGAZINE_AKM_AMMO_CAPACITY_MG,
		"live magazine exposes the exact 489000 mg native capacity")
	var full_ammunition_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		ZerkovInventoryCatalog.MAGAZINE_AKM_CAPACITY_ROUNDS,
		{"kind": "list", "container": full_magazine_container_id, "ordinal": 0},
		7_201,
		7_002
	)
	var full_ammunition_item_id := int(full_ammunition_insert.get("new_item_id", 0))
	check(bool(full_ammunition_insert.get("accepted", false))
		and int((_snapshot_item(
			authority.snapshot(inventory_id), full_ammunition_item_id)).get("quantity", 0))
			== ZerkovInventoryCatalog.MAGAZINE_AKM_CAPACITY_ROUNDS,
		"fresh real magazine accepts exactly thirty 7.62 rounds")

	# Merging into an existing stack is a separate public mutation path from
	# insertion.  It must pass through the same native mass-capacity guard.
	var merge_source_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		1,
		{"kind": "spatial", "container": rig_id, "x": 0, "y": 0, "rotated": false},
		7_201,
		7_003
	)
	var merge_source_item_id := int(merge_source_insert.get("new_item_id", 0))
	check(bool(merge_source_insert.get("accepted", false)) and merge_source_item_id > 0,
		"loose round fixture exists for the merge-boundary challenge")
	var revision_before_merge_rejection := authority.inventory_revision(inventory_id)
	var state_before_merge_rejection := authority.make_persistence_record(inventory_id)
	var over_capacity_merge: Dictionary = authority.merge_stacks(
		inventory_id,
		merge_source_item_id,
		full_ammunition_item_id,
		7_201,
		7_004
	)
	var merge_status := over_capacity_merge.get("status", {}) as Dictionary
	check(not bool(over_capacity_merge.get("accepted", true))
		and int(merge_status.get("code", -1)) == 6
		and int(merge_status.get("diagnostic", -1)) == 123
		and int(merge_status.get("detail", -1)) == 505_300,
		"cross-container merge cannot bypass the thirty-round native mass bound: "
			+ str(merge_status))
	check(authority.inventory_revision(inventory_id) == revision_before_merge_rejection
		and authority.make_persistence_record(inventory_id) == state_before_merge_rejection
		and int((_snapshot_item(
			authority.snapshot(inventory_id), full_ammunition_item_id)).get("quantity", 0)) == 30
		and int((_snapshot_item(
			authority.snapshot(inventory_id), merge_source_item_id)).get("quantity", 0)) == 1,
		"rejected over-capacity merge leaves revision and complete canonical state unchanged")

	# A separate empty shell proves 31 rounds fail as one atomic arrival, not
	# merely because another stack already occupies the one-entry list.
	var empty_magazine_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM),
		1,
		{
			"kind": "spatial",
			"container": backpack_id,
			"x": 1,
			"y": 0,
			"rotated": false,
		},
		7_201,
		7_005
	)
	var empty_magazine_item_id := int(empty_magazine_insert.get("new_item_id", 0))
	var empty_magazine_container_id := _provided_container_id(
		authority.snapshot(inventory_id),
		empty_magazine_item_id,
		ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM)
	check(bool(empty_magazine_insert.get("accepted", false))
		and empty_magazine_item_id > 0 and empty_magazine_container_id > 0,
		"second fresh magazine materializes for the over-capacity boundary")
	var snapshot_before_31 := authority.snapshot(inventory_id)
	var revision_before_31 := authority.inventory_revision(inventory_id)
	var state_before_31 := authority.make_persistence_record(inventory_id)
	var over_capacity_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		ZerkovInventoryCatalog.MAGAZINE_AKM_CAPACITY_ROUNDS + 1,
		{"kind": "list", "container": empty_magazine_container_id, "ordinal": 0},
		7_201,
		7_006
	)
	var capacity_status := over_capacity_insert.get("status", {}) as Dictionary
	check(not bool(over_capacity_insert.get("accepted", true))
		and int(capacity_status.get("code", -1)) == 6
		and int(capacity_status.get("diagnostic", -1)) == 123
		and int(capacity_status.get("detail", -1)) == 505_300,
		"fresh real magazine rejects round thirty-one with the exact native diagnostic: "
			+ str(capacity_status))
	var snapshot_after_31 := authority.snapshot(inventory_id)
	check(authority.inventory_revision(inventory_id) == revision_before_31
		and authority.make_persistence_record(inventory_id) == state_before_31
		and snapshot_after_31.get_items().size() == snapshot_before_31.get_items().size()
		and snapshot_after_31.get_containers().size() \
			== snapshot_before_31.get_containers().size()
		and _items_in_container(snapshot_after_31, empty_magazine_container_id).is_empty()
		and _provided_container_id(
			snapshot_after_31,
			empty_magazine_item_id,
			ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM) == empty_magazine_container_id,
		"round-thirty-one rejection preserves revision, shell, child container, and all items")

	# Retain the independent filter and one-stack behavior on a third shell.
	var filter_magazine_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM),
		1,
		{
			"kind": "spatial",
			"container": backpack_id,
			"x": 2,
			"y": 0,
			"rotated": false,
		},
		7_201,
		7_007
	)
	var filter_magazine_item_id := int(filter_magazine_insert.get("new_item_id", 0))
	var filter_magazine_container_id := _provided_container_id(
		authority.snapshot(inventory_id),
		filter_magazine_item_id,
		ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM)
	check(bool(filter_magazine_insert.get("accepted", false))
		and filter_magazine_item_id > 0 and filter_magazine_container_id > 0,
		"third fresh magazine materializes for filter and stack-count checks")

	var revision_before_filter_rejection := authority.inventory_revision(inventory_id)
	var incompatible_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_BANDAGE),
		1,
		{"kind": "list", "container": filter_magazine_container_id, "ordinal": 0},
		7_201,
		7_008
	)
	var incompatible_status := incompatible_insert.get("status", {}) as Dictionary
	check(not bool(incompatible_insert.get("accepted", true))
		and int(incompatible_status.get("diagnostic", 0)) == 118,
		"magazine container rejects non-7.62 ammunition by its native trait filter")
	check(authority.inventory_revision(inventory_id) == revision_before_filter_rejection,
		"filtered magazine insertion leaves canonical revision unchanged")

	var ammunition_insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		12,
		{"kind": "list", "container": filter_magazine_container_id, "ordinal": 0},
		7_201,
		7_009
	)
	check(bool(ammunition_insert.get("accepted", false)),
		"compatible 7.62 ammunition loads into the real magazine container")
	var ammunition_item_id := int(ammunition_insert.get("new_item_id", 0))
	var loaded_snapshot := authority.snapshot(inventory_id)
	var ammunition_item := _snapshot_item(loaded_snapshot, ammunition_item_id)
	var ammunition_location := ammunition_item.get("location", {}) as Dictionary
	check(not ammunition_item.is_empty()
		and int(ammunition_item.get("quantity", 0)) == 12
		and String(ammunition_location.get("kind", "")) == "list"
		and int(ammunition_location.get("container", 0)) == filter_magazine_container_id
		and int(ammunition_location.get("ordinal", -1)) == 0,
		"loaded ammunition is canonically owned by the magazine ordered list")

	var revision_before_capacity_rejection := authority.inventory_revision(inventory_id)
	var second_stack: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		1,
		{"kind": "list", "container": filter_magazine_container_id, "ordinal": 1},
		7_201,
		7_010
	)
	var second_status := second_stack.get("status", {}) as Dictionary
	check(not bool(second_stack.get("accepted", true))
		and int(second_status.get("diagnostic", 0)) == 26,
		"magazine rejects a second ammunition stack at its one-item count capacity")
	check(authority.inventory_revision(inventory_id) == revision_before_capacity_rejection
		and int((_snapshot_item(
			authority.snapshot(inventory_id), ammunition_item_id)).get("quantity", 0)) == 12,
		"capacity rejection cannot mutate or duplicate magazine ammunition")
	var unloaded: Dictionary = authority.unload_inventory(inventory_id)
	check(bool(unloaded.get("ok", false)), "live magazine inventory unloads cleanly")
	root.remove_child(authority)
	authority.free()


func _container(resource: InventoryCatalogResource, identifier: StringName) -> InventoryContainerDefinition:
	for value in resource.containers:
		var container := value as InventoryContainerDefinition
		if container.identifier == identifier:
			return container
	return null


func _profile(resource: InventoryCatalogResource, identifier: StringName) -> InventoryProfileDefinition:
	for value in resource.profiles:
		var profile := value as InventoryProfileDefinition
		if profile.identifier == identifier:
			return profile
	return null


func _root_container_id(snapshot: InventorySnapshotResource, definition: StringName) -> int:
	if snapshot == null:
		return 0
	for value in snapshot.get_containers():
		var container := value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get("container_definition_identifier", &"")) == definition:
			return int(container.get("id", 0))
	return 0


func _provided_container_id(
	snapshot: InventorySnapshotResource,
	provider_item: int,
	definition: StringName
) -> int:
	if snapshot == null or provider_item <= 0:
		return 0
	for value in snapshot.get_containers():
		var container := value as Dictionary
		if int(container.get("provider_item", 0)) == provider_item \
				and StringName(container.get("container_definition_identifier", &"")) == definition:
			return int(container.get("id", 0))
	return 0


func _snapshot_item(snapshot: InventorySnapshotResource, item_id: int) -> Dictionary:
	if snapshot == null or item_id <= 0:
		return {}
	for value in snapshot.get_items():
		var item := value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return item
	return {}


func _items_in_container(snapshot: InventorySnapshotResource, container_id: int) -> Array[int]:
	var item_ids: Array[int] = []
	if snapshot == null or container_id <= 0:
		return item_ids
	for value in snapshot.get_items():
		var item := value as Dictionary
		var location := item.get("location", {}) as Dictionary
		if int(location.get("container", 0)) == container_id:
			item_ids.append(int(item.get("id", 0)))
	item_ids.sort()
	return item_ids


func _is_valid_identifier(identifier: String) -> bool:
	if identifier.to_utf8_buffer().size() > 128:
		return false
	var segments := identifier.split(".")
	if segments.size() < 2 or segments.size() > 8:
		return false
	for segment in segments:
		if segment.is_empty():
			return false
		for index in segment.length():
			var code := segment.unicode_at(index)
			if index == 0:
				if code < 97 or code > 122:
					return false
			elif not ((code >= 97 and code <= 122) or (code >= 48 and code <= 57) or code == 95):
				return false
	return true


func _container_layout_is_bounded(container: InventoryContainerDefinition) -> bool:
	match container.layout_kind:
		InventoryContainerDefinition.LAYOUT_SPATIAL_GRID:
			return container.grid_width > 0 and container.grid_width <= 256 \
				and container.grid_height > 0 and container.grid_height <= 256
		InventoryContainerDefinition.LAYOUT_NAMED_SLOTS:
			return not container.named_slots.is_empty() and container.named_slots.size() <= 128
		InventoryContainerDefinition.LAYOUT_ORDERED_LIST:
			return container.ordered_list_max_entries > 0 \
				and container.ordered_list_max_entries <= 4096
	return false


func _container_constraints_are_bounded(container: InventoryContainerDefinition) -> bool:
	var constraints := container.constraints
	if constraints == null:
		return true
	return constraints.max_items >= 0 and constraints.max_items <= 4096 \
		and constraints.mass_capacity_mg >= 0 \
		and constraints.max_nesting_depth >= 0 and constraints.max_nesting_depth <= 16 \
		and constraints.required_traits.size() <= 32 \
		and constraints.blocked_traits.size() <= 32


func _required_container_features(container: InventoryContainerDefinition) -> PackedStringArray:
	var required := PackedStringArray()
	match container.layout_kind:
		InventoryContainerDefinition.LAYOUT_SPATIAL_GRID:
			required.append(ZerkovInventoryCatalog.FEATURE_SPATIAL)
		InventoryContainerDefinition.LAYOUT_NAMED_SLOTS:
			required.append(ZerkovInventoryCatalog.FEATURE_SLOTS)
		InventoryContainerDefinition.LAYOUT_ORDERED_LIST:
			required.append(ZerkovInventoryCatalog.FEATURE_LIST)
	var constraints := container.constraints
	if constraints != null:
		if constraints.max_items > 0:
			required.append(ZerkovInventoryCatalog.FEATURE_COUNT)
		if constraints.has_mass_capacity:
			required.append(ZerkovInventoryCatalog.FEATURE_MASS)
		if not constraints.required_traits.is_empty() or not constraints.blocked_traits.is_empty():
			required.append(ZerkovInventoryCatalog.FEATURE_FILTER)
		if constraints.allow_nesting:
			required.append(ZerkovInventoryCatalog.FEATURE_NESTING)
		if constraints.access_mask != 15:
			required.append("inventory.feature.access")
		if constraints.retention != InventoryContainerConstraints.RETENTION_NONE:
			required.append(ZerkovInventoryCatalog.FEATURE_RETENTION)
		if constraints.allow_stack_split:
			required.append(ZerkovInventoryCatalog.FEATURE_STACKING)
		if constraints.allow_auto_placement:
			required.append(ZerkovInventoryCatalog.FEATURE_AUTO)
		if constraints.allow_quick_transfer:
			required.append(ZerkovInventoryCatalog.FEATURE_QUICK)
	if container.layout_kind == InventoryContainerDefinition.LAYOUT_SPATIAL_GRID \
		and container.grid_allow_rotation:
		required.append(ZerkovInventoryCatalog.FEATURE_ROTATION)
	if not String(container.discovery_policy_identifier).is_empty():
		required.append(ZerkovInventoryCatalog.FEATURE_DISCOVERY)
	return required


func _profile_limits_are_bounded(limits: InventoryProfileLimits) -> bool:
	return limits != null \
		and limits.max_items > 0 and limits.max_items <= 4096 \
		and limits.max_containers > 0 and limits.max_containers <= 512 \
		and limits.max_references >= 0 and limits.max_references <= 256 \
		and limits.max_nesting_depth >= 0 and limits.max_nesting_depth <= 16 \
		and limits.max_mutable_components_per_item >= 0 \
		and limits.max_mutable_components_per_item <= 32
