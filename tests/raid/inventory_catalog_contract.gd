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
	check(resource.trait_schemas.size() == 6, "slot and ammunition traits are explicit")
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

	print("INVENTORY_CATALOG_RESULT checks=", checks, " failures=", failures,
		" findings=", findings.size())
	quit(0 if failures == 0 else 1)


func _container(resource: InventoryCatalogResource, identifier: StringName) -> InventoryContainerDefinition:
	for value in resource.containers:
		var container := value as InventoryContainerDefinition
		if container.identifier == identifier:
			return container
	return null


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
