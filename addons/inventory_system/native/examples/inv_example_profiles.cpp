#include "examples/inv_example_profiles.h"

#include "core/inv_builtin_features.h"
#include "core/inv_definitions.h"
#include "core/inv_limits.h"

#include <algorithm>
#include <string>
#include <utility>
#include <vector>

namespace invexamples {

namespace {

inv::TraitSchemaDefinition make_trait_schema(const std::string &p_identifier) {
	inv::TraitSchemaDefinition schema;
	schema.identifier = p_identifier;
	schema.max_payload_bytes = 64;
	return schema;
}

inv::ItemTraitValue make_trait_value(const std::string &p_trait, std::vector<std::uint8_t> p_payload = {}) {
	inv::ItemTraitValue value;
	value.trait_identifier = p_trait;
	value.version = inv::RESOURCE_SCHEMA_VERSION;
	value.canonical_payload = std::move(p_payload);
	return value;
}

inv::NamedSlotDefinition make_equipment_slot(const std::string &p_identifier, const std::string &p_category_trait) {
	inv::NamedSlotDefinition slot;
	slot.identifier = p_identifier;
	slot.max_items = 1;
	slot.required_traits = { std::string(inv::TRAIT_EQUIPMENT), p_category_trait };
	return slot;
}

inv::ContainerDefinition make_equipment_container() {
	inv::ContainerDefinition result;
	result.identifier = CONTAINER_EQUIPMENT;
	result.layout = inv::NamedSlotsLayout{ {
			make_equipment_slot(SLOT_HEADWEAR, TRAIT_HEADWEAR),
			make_equipment_slot(SLOT_ARMOR, TRAIT_BODY_ARMOR),
			make_equipment_slot(SLOT_WEAPON_PRIMARY, TRAIT_WEAPON_PRIMARY),
			make_equipment_slot(SLOT_WEAPON_SECONDARY, TRAIT_WEAPON_SECONDARY),
			make_equipment_slot(SLOT_RIG, TRAIT_RIG),
			make_equipment_slot(SLOT_BACKPACK, TRAIT_BACKPACK),
			make_equipment_slot(SLOT_SECURE_CONTAINER, TRAIT_SECURE_CONTAINER),
	} };
	// Equipping a rig, backpack, or secure container attaches that item's
	// own provided grid beneath the equipment root, so the root itself must
	// permit one level of nested containment.
	result.constraints.allow_nesting = true;
	result.constraints.max_nesting_depth = 4;
	result.enabled_features = inv::required_container_features(result);
	return result;
}

inv::ContainerDefinition make_spatial_container(
		const std::string &p_identifier,
		std::uint32_t p_width,
		std::uint32_t p_height,
		bool p_rotation,
		inv::ContainerConstraints p_constraints) {
	inv::ContainerDefinition result;
	result.identifier = p_identifier;
	result.layout = inv::SpatialGridLayout{ p_width, p_height, p_rotation };
	result.constraints = std::move(p_constraints);
	result.enabled_features = inv::required_container_features(result);
	return result;
}

inv::ContainerDefinition make_ordered_list_container(
		const std::string &p_identifier,
		std::uint32_t p_max_entries,
		inv::ContainerConstraints p_constraints) {
	inv::ContainerDefinition result;
	result.identifier = p_identifier;
	result.layout = inv::OrderedListLayout{ p_max_entries };
	result.constraints = std::move(p_constraints);
	result.enabled_features = inv::required_container_features(result);
	return result;
}

inv::ItemDefinition make_item(
		const std::string &p_identifier,
		std::uint64_t p_max_stack,
		std::int64_t p_unit_mass_mg,
		std::uint32_t p_width,
		std::uint32_t p_height,
		bool p_rotation) {
	inv::ItemDefinition result;
	result.identifier = p_identifier;
	result.max_stack = p_max_stack;
	result.unit_mass_mg = p_unit_mass_mg;
	result.footprint_width = p_width;
	result.footprint_height = p_height;
	result.allow_rotation = p_rotation;
	return result;
}

} // namespace

inv::Status register_example_trait_schemas(inv::DefinitionCatalog &r_catalog, bool p_reverse_order) {
	std::vector<inv::TraitSchemaDefinition> schemas = {
		make_trait_schema(TRAIT_HEADWEAR),
		make_trait_schema(TRAIT_BODY_ARMOR),
		make_trait_schema(TRAIT_WEAPON_PRIMARY),
		make_trait_schema(TRAIT_WEAPON_SECONDARY),
		make_trait_schema(TRAIT_RIG),
		make_trait_schema(TRAIT_BACKPACK),
		make_trait_schema(TRAIT_SECURE_CONTAINER),
		make_trait_schema(TRAIT_LOOTABLE),
		make_trait_schema(TRAIT_QUEST_BOUND),
	};
	if (p_reverse_order) {
		std::reverse(schemas.begin(), schemas.end());
	}
	for (inv::TraitSchemaDefinition &schema : schemas) {
		inv::Status status = r_catalog.register_trait_schema(std::move(schema), "examples:trait_schema");
		if (!status.ok()) {
			return status;
		}
	}
	return inv::ok_status();
}

inv::Status register_example_items(inv::DefinitionCatalog &r_catalog, bool p_reverse_order) {
	inv::ItemDefinition helmet = make_item(ITEM_HELMET, 1, 1200, 1, 1, false);
	helmet.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 1 }), make_trait_value(TRAIT_HEADWEAR) };

	inv::ItemDefinition body_armor = make_item(ITEM_BODY_ARMOR, 1, 4000, 2, 2, false);
	body_armor.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 2 }), make_trait_value(TRAIT_BODY_ARMOR) };

	inv::ItemDefinition rifle = make_item(ITEM_RIFLE, 1, 3500, 2, 1, true);
	rifle.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 3 }), make_trait_value(TRAIT_WEAPON_PRIMARY) };

	inv::ItemDefinition pistol = make_item(ITEM_PISTOL, 1, 1200, 1, 1, false);
	pistol.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 4 }), make_trait_value(TRAIT_WEAPON_SECONDARY) };

	inv::ItemDefinition rig = make_item(ITEM_RIG, 1, 1200, 2, 2, false);
	rig.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 5 }), make_trait_value(TRAIT_RIG) };
	rig.provided_containers = { CONTAINER_RIG_GRID };

	inv::ItemDefinition backpack = make_item(ITEM_BACKPACK, 1, 1600, 2, 3, false);
	backpack.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 6 }), make_trait_value(TRAIT_BACKPACK) };
	backpack.provided_containers = { CONTAINER_BACKPACK_GRID };

	inv::ItemDefinition secure_container = make_item(ITEM_SECURE_CONTAINER, 1, 900, 1, 1, false);
	secure_container.traits = { make_trait_value(inv::TRAIT_EQUIPMENT, { 7 }), make_trait_value(TRAIT_SECURE_CONTAINER) };
	secure_container.provided_containers = { CONTAINER_SECURE_GRID };

	inv::ItemDefinition ammo = make_item(ITEM_AMMO_9MM, 60, 20, 1, 1, false);
	ammo.traits = { make_trait_value(inv::TRAIT_AMMUNITION), make_trait_value(TRAIT_LOOTABLE) };

	inv::ItemDefinition ration = make_item(ITEM_RATION, 10, 150, 1, 1, false);
	ration.traits = { make_trait_value(TRAIT_LOOTABLE) };

	inv::ItemDefinition valuable_gem = make_item(ITEM_VALUABLE_GEM, 1, 50, 1, 1, false);
	valuable_gem.traits = { make_trait_value(TRAIT_LOOTABLE) };

	inv::ItemDefinition quest_key = make_item(ITEM_QUEST_KEY, 1, 80, 1, 1, false);
	quest_key.traits = { make_trait_value(TRAIT_QUEST_BOUND) };

	std::vector<inv::ItemDefinition> items = {
		helmet,
		body_armor,
		rifle,
		pistol,
		rig,
		backpack,
		secure_container,
		ammo,
		ration,
		valuable_gem,
		quest_key,
	};
	if (p_reverse_order) {
		std::reverse(items.begin(), items.end());
	}
	for (inv::ItemDefinition &item : items) {
		inv::Status status = r_catalog.register_item(std::move(item), "examples:item");
		if (!status.ok()) {
			return status;
		}
	}
	return inv::ok_status();
}

inv::Status register_extraction_character_profile(inv::DefinitionCatalog &r_catalog, bool p_reverse_order) {
	inv::ContainerConstraints pockets_constraints;
	pockets_constraints.max_items = 8;
	pockets_constraints.has_mass_capacity = true;
	pockets_constraints.mass_capacity_mg = 200000;
	pockets_constraints.allow_stack_split = true;
	pockets_constraints.allow_auto_placement = true;

	inv::ContainerConstraints rig_constraints;
	rig_constraints.max_items = 9;
	rig_constraints.has_mass_capacity = true;
	rig_constraints.mass_capacity_mg = 400000;
	rig_constraints.allow_nesting = true;
	rig_constraints.max_nesting_depth = 2;
	rig_constraints.allow_stack_split = true;
	rig_constraints.allow_auto_placement = true;

	inv::ContainerConstraints backpack_constraints;
	backpack_constraints.max_items = 25;
	backpack_constraints.has_mass_capacity = true;
	backpack_constraints.mass_capacity_mg = 900000;
	backpack_constraints.allow_nesting = true;
	backpack_constraints.max_nesting_depth = 2;
	backpack_constraints.allow_stack_split = true;
	backpack_constraints.allow_auto_placement = true;
	backpack_constraints.allow_quick_transfer = true;

	inv::ContainerConstraints secure_constraints;
	secure_constraints.max_items = 9;
	secure_constraints.allow_nesting = true;
	secure_constraints.max_nesting_depth = 1;
	secure_constraints.retention = inv::RetentionClass::PROTECTED;
	secure_constraints.allow_auto_placement = true;

	std::vector<inv::ContainerDefinition> containers = {
		make_equipment_container(),
		make_spatial_container(CONTAINER_POCKETS, 4, 2, true, pockets_constraints),
		make_spatial_container(CONTAINER_RIG_GRID, 3, 3, true, rig_constraints),
		make_spatial_container(CONTAINER_BACKPACK_GRID, 5, 5, true, backpack_constraints),
		make_spatial_container(CONTAINER_SECURE_GRID, 3, 3, false, secure_constraints),
	};
	if (p_reverse_order) {
		std::reverse(containers.begin(), containers.end());
	}
	for (inv::ContainerDefinition &container : containers) {
		inv::Status status = r_catalog.register_container(std::move(container), "examples:extraction_character");
		if (!status.ok()) {
			return status;
		}
	}

	inv::InventoryProfileDefinition profile;
	profile.identifier = PROFILE_EXTRACTION_CHARACTER;
	profile.root_containers = { CONTAINER_EQUIPMENT, CONTAINER_POCKETS };
	return r_catalog.register_profile(std::move(profile), "examples:extraction_character");
}

inv::Status register_stash_profile(inv::DefinitionCatalog &r_catalog) {
	inv::ContainerConstraints constraints;
	constraints.max_items = 200;
	constraints.allow_nesting = true;
	constraints.max_nesting_depth = 8;
	constraints.allow_stack_split = true;
	constraints.allow_auto_placement = true;
	constraints.allow_quick_transfer = true;
	// No mass capacity: the stash is not a carried-mass movement policy.

	inv::Status status = r_catalog.register_container(
			make_spatial_container(CONTAINER_STASH_GRID, 10, 40, true, constraints),
			"examples:stash");
	if (!status.ok()) {
		return status;
	}

	inv::InventoryProfileDefinition profile;
	profile.identifier = PROFILE_STASH;
	profile.root_containers = { CONTAINER_STASH_GRID };
	return r_catalog.register_profile(std::move(profile), "examples:stash");
}

inv::Status register_world_crate_profile(inv::DefinitionCatalog &r_catalog) {
	inv::ContainerConstraints constraints;
	constraints.max_items = 36;
	// Looting out (REMOVE/MOVE/INSPECT) stays available; INSERT is blocked
	// so the crate cannot be used to dump items back in.
	constraints.access_mask = inv::AccessFlag::REMOVE | inv::AccessFlag::MOVE | inv::AccessFlag::INSPECT;
	constraints.required_traits = { TRAIT_LOOTABLE };
	constraints.blocked_traits = { TRAIT_QUEST_BOUND };
	constraints.allow_stack_split = true;
	constraints.allow_auto_placement = true;
	constraints.allow_quick_transfer = true;

	inv::Status status = r_catalog.register_container(
			make_spatial_container(CONTAINER_WORLD_CRATE_GRID, 6, 6, true, constraints),
			"examples:world_crate");
	if (!status.ok()) {
		return status;
	}

	inv::InventoryProfileDefinition profile;
	profile.identifier = PROFILE_WORLD_CRATE;
	profile.root_containers = { CONTAINER_WORLD_CRATE_GRID };
	return r_catalog.register_profile(std::move(profile), "examples:world_crate");
}

inv::Status register_simple_list_profile(inv::DefinitionCatalog &r_catalog) {
	inv::ContainerConstraints constraints;
	constraints.max_items = 40;
	constraints.allow_stack_split = true;

	inv::Status status = r_catalog.register_container(
			make_ordered_list_container(CONTAINER_SIMPLE_LIST, 40, constraints),
			"examples:simple_list");
	if (!status.ok()) {
		return status;
	}

	inv::InventoryProfileDefinition profile;
	profile.identifier = PROFILE_SIMPLE_LIST;
	profile.root_containers = { CONTAINER_SIMPLE_LIST };
	return r_catalog.register_profile(std::move(profile), "examples:simple_list");
}

inv::Status populate_example_catalog(
		inv::DefinitionCatalog &r_catalog,
		bool p_seal,
		bool p_reverse_order) {
	inv::Status status = r_catalog.register_builtin_definitions();
	if (!status.ok()) {
		return status;
	}

	if (!p_reverse_order) {
		status = register_example_trait_schemas(r_catalog, false);
		if (!status.ok()) {
			return status;
		}
		status = register_example_items(r_catalog, false);
		if (!status.ok()) {
			return status;
		}
		status = register_extraction_character_profile(r_catalog, false);
		if (!status.ok()) {
			return status;
		}
		status = register_stash_profile(r_catalog);
		if (!status.ok()) {
			return status;
		}
		status = register_world_crate_profile(r_catalog);
		if (!status.ok()) {
			return status;
		}
		status = register_simple_list_profile(r_catalog);
		if (!status.ok()) {
			return status;
		}
	} else {
		// Reverse both the group order and the element order within the
		// multi-definition groups to exercise order independence broadly.
		status = register_simple_list_profile(r_catalog);
		if (!status.ok()) {
			return status;
		}
		status = register_world_crate_profile(r_catalog);
		if (!status.ok()) {
			return status;
		}
		status = register_stash_profile(r_catalog);
		if (!status.ok()) {
			return status;
		}
		status = register_extraction_character_profile(r_catalog, true);
		if (!status.ok()) {
			return status;
		}
		status = register_example_items(r_catalog, true);
		if (!status.ok()) {
			return status;
		}
		status = register_example_trait_schemas(r_catalog, true);
		if (!status.ok()) {
			return status;
		}
	}

	if (p_seal) {
		return r_catalog.seal();
	}
	return inv::ok_status();
}

} // namespace invexamples
