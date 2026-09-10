#include "godot/inventory_catalog.h"

#include "core/inv_builtin_features.h"
#include "core/inv_definitions.h"
#include "core/inv_identifier.h"
#include "core/inv_version.h"

#include "godot/inventory_godot_util.h"

#include "resources/inventory_container_constraints.h"
#include "resources/inventory_item_trait_value.h"
#include "resources/inventory_named_slot.h"
#include "resources/inventory_profile_limits.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

namespace {

std::vector<std::string> to_string_vector(const PackedStringArray &p_array) {
	std::vector<std::string> result;
	result.reserve(p_array.size());
	for (int i = 0; i < p_array.size(); ++i) {
		result.push_back(to_std(p_array[i]));
	}
	return result;
}

// Resource path if saved, else an addressable "<anonymous InventoryX>"
// fallback -- matches this addon's own "stable-path diagnostics" contract
// (7.1) even for an unsaved/in-memory Resource.
String source_label_of(const Ref<Resource> &p_resource, const char *p_kind) {
	if (p_resource.is_valid() && !p_resource->get_path().is_empty()) {
		return p_resource->get_path();
	}
	return vformat("<anonymous %s>", p_kind);
}

inv::TraitSchemaDefinition to_trait_schema_definition(const Ref<InventoryTraitSchema> &p_resource) {
	inv::TraitSchemaDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_resource->get_identifier()));
	desc.version = std::uint16_t(p_resource->get_version());
	desc.authority_affecting = p_resource->get_authority_affecting();
	desc.max_payload_bytes = std::uint32_t(p_resource->get_max_payload_bytes());
	return desc;
}

inv::DiscoveryPolicyDefinition to_discovery_policy_definition(const Ref<InventoryDiscoveryPolicy> &p_resource) {
	inv::DiscoveryPolicyDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_resource->get_identifier()));
	desc.schema_version = std::uint16_t(p_resource->get_schema_version());
	desc.container_search_instant = p_resource->get_container_search_instant();
	const int container_duration = p_resource->get_container_search_duration_ms();
	desc.container_search_duration_ms = std::uint32_t(container_duration < 0 ? 0 : container_duration);
	desc.item_scan_instant = p_resource->get_item_scan_instant();
	const int item_duration = p_resource->get_item_scan_duration_ms();
	desc.item_scan_duration_ms = std::uint32_t(item_duration < 0 ? 0 : item_duration);
	desc.shell_label = to_std(p_resource->get_shell_label());
	return desc;
}

inv::ItemTraitValue to_item_trait_value(const Ref<InventoryItemTraitValue> &p_resource) {
	inv::ItemTraitValue value;
	if (p_resource.is_null()) {
		return value;
	}
	value.trait_identifier = to_std(String(p_resource->get_trait_identifier()));
	value.version = std::uint16_t(p_resource->get_version());
	value.canonical_payload = from_packed(p_resource->get_payload());
	return value;
}

inv::ItemDefinition to_item_definition(const Ref<InventoryItemDefinition> &p_resource) {
	inv::ItemDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_resource->get_identifier()));
	desc.schema_version = std::uint16_t(p_resource->get_schema_version());
	desc.max_stack = std::uint64_t(p_resource->get_max_stack());
	desc.unit_mass_mg = p_resource->get_unit_mass_mg();
	desc.footprint_width = std::uint32_t(p_resource->get_footprint_width());
	desc.footprint_height = std::uint32_t(p_resource->get_footprint_height());
	desc.allow_rotation = p_resource->get_allow_rotation();

	const TypedArray<InventoryItemTraitValue> traits = p_resource->get_traits();
	desc.traits.reserve(traits.size());
	for (int i = 0; i < traits.size(); ++i) {
		const Ref<InventoryItemTraitValue> trait = traits[i];
		if (trait.is_null()) {
			continue;
		}
		desc.traits.push_back(to_item_trait_value(trait));
	}

	desc.provided_containers = to_string_vector(p_resource->get_provided_containers());
	return desc;
}

inv::NamedSlotDefinition to_named_slot_definition(const Ref<InventoryNamedSlot> &p_resource) {
	inv::NamedSlotDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_resource->get_identifier()));
	desc.max_items = std::uint32_t(p_resource->get_max_items());
	desc.required_traits = to_string_vector(p_resource->get_required_traits());
	desc.blocked_traits = to_string_vector(p_resource->get_blocked_traits());
	return desc;
}

inv::LayoutDefinition to_layout_definition(const Ref<InventoryContainerDefinition> &p_resource) {
	switch (p_resource->get_layout_kind()) {
		case InventoryContainerDefinition::LAYOUT_NAMED_SLOTS: {
			inv::NamedSlotsLayout layout;
			const TypedArray<InventoryNamedSlot> slots = p_resource->get_named_slots();
			layout.slots.reserve(slots.size());
			for (int i = 0; i < slots.size(); ++i) {
				const Ref<InventoryNamedSlot> slot = slots[i];
				if (slot.is_null()) {
					continue;
				}
				layout.slots.push_back(to_named_slot_definition(slot));
			}
			return layout;
		}
		case InventoryContainerDefinition::LAYOUT_ORDERED_LIST: {
			inv::OrderedListLayout layout;
			layout.max_entries = std::uint32_t(p_resource->get_ordered_list_max_entries());
			return layout;
		}
		case InventoryContainerDefinition::LAYOUT_SPATIAL_GRID:
		default: {
			inv::SpatialGridLayout layout;
			layout.width = std::uint32_t(p_resource->get_grid_width());
			layout.height = std::uint32_t(p_resource->get_grid_height());
			layout.allow_rotation = p_resource->get_grid_allow_rotation();
			return layout;
		}
	}
}

inv::ContainerConstraints to_container_constraints(const Ref<InventoryContainerConstraints> &p_resource) {
	inv::ContainerConstraints desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.max_items = std::uint32_t(p_resource->get_max_items());
	desc.has_mass_capacity = p_resource->get_has_mass_capacity();
	desc.mass_capacity_mg = p_resource->get_mass_capacity_mg();
	desc.required_traits = to_string_vector(p_resource->get_required_traits());
	desc.blocked_traits = to_string_vector(p_resource->get_blocked_traits());
	desc.allow_nesting = p_resource->get_allow_nesting();
	desc.max_nesting_depth = std::uint32_t(p_resource->get_max_nesting_depth());
	desc.access_mask = std::uint8_t(p_resource->get_access_mask());
	switch (p_resource->get_retention()) {
		case InventoryContainerConstraints::RETENTION_PROTECTED:
			desc.retention = inv::RetentionClass::PROTECTED;
			break;
		case InventoryContainerConstraints::RETENTION_BOUND:
			desc.retention = inv::RetentionClass::BOUND;
			break;
		case InventoryContainerConstraints::RETENTION_NONE:
		default:
			desc.retention = inv::RetentionClass::NONE;
			break;
	}
	desc.allow_stack_split = p_resource->get_allow_stack_split();
	desc.allow_auto_placement = p_resource->get_allow_auto_placement();
	desc.allow_quick_transfer = p_resource->get_allow_quick_transfer();
	return desc;
}

inv::ContainerDefinition to_container_definition(const Ref<InventoryContainerDefinition> &p_resource) {
	inv::ContainerDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_resource->get_identifier()));
	desc.schema_version = std::uint16_t(p_resource->get_schema_version());
	desc.layout = to_layout_definition(p_resource);
	desc.enabled_features = to_string_vector(p_resource->get_enabled_features());
	desc.constraints = to_container_constraints(p_resource->get_constraints());
	desc.discovery_policy_identifier = to_std(String(p_resource->get_discovery_policy_identifier()));
	return desc;
}

inv::InventoryLimitsDefinition to_limits_definition(const Ref<InventoryProfileLimits> &p_resource) {
	inv::InventoryLimitsDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.max_items = std::uint32_t(p_resource->get_max_items());
	desc.max_containers = std::uint32_t(p_resource->get_max_containers());
	desc.max_references = std::uint32_t(p_resource->get_max_references());
	desc.max_nesting_depth = std::uint32_t(p_resource->get_max_nesting_depth());
	desc.max_mutable_components_per_item = std::uint32_t(p_resource->get_max_mutable_components_per_item());
	return desc;
}

inv::InventoryProfileDefinition to_profile_definition(const Ref<InventoryProfileDefinition> &p_resource) {
	inv::InventoryProfileDefinition desc;
	if (p_resource.is_null()) {
		return desc;
	}
	desc.identifier = to_std(String(p_resource->get_identifier()));
	desc.schema_version = std::uint16_t(p_resource->get_schema_version());
	desc.root_containers = to_string_vector(p_resource->get_root_containers());
	desc.enabled_features = to_string_vector(p_resource->get_enabled_features());
	desc.limits = to_limits_definition(p_resource->get_limits());
	return desc;
}

// Shared register-and-report body for one definition kind. `p_register`
// wraps the specific `inv::DefinitionCatalog::register_*()` overload; every
// caller below already validated p_resource is non-null.
template <typename Desc, typename RegisterFn>
Dictionary register_one(inv::DefinitionCatalog &p_catalog, Desc p_desc, const String &p_identifier,
		const String &p_source, RegisterFn p_register) {
	inv::IdentifierConflict conflict;
	const inv::Status status = p_register(p_catalog, std::move(p_desc), to_std(p_source), &conflict);
	return diagnostic_dict(status, p_identifier, p_source);
}

} // namespace

InventoryCatalog::InventoryCatalog() {}

InventoryCatalog::~InventoryCatalog() {}

Dictionary InventoryCatalog::register_builtin_definitions() {
	const inv::Status status = catalog.register_builtin_definitions();
	return diagnostic_dict(status, String("inventory.builtin"), String("<builtin>"));
}

Dictionary InventoryCatalog::register_discovery_definitions() {
	const inv::Status status = catalog.register_discovery_definitions();
	return diagnostic_dict(status, String(inv::FEATURE_DISCOVERY), String("<builtin-discovery>"));
}

Dictionary InventoryCatalog::register_trait_schema(const Ref<InventoryTraitSchema> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>"));
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "InventoryTraitSchema");
	return register_one(catalog, to_trait_schema_definition(p_resource), identifier, source,
			[](inv::DefinitionCatalog &c, inv::TraitSchemaDefinition d, const std::string &s, inv::IdentifierConflict *conflict) {
				return c.register_trait_schema(std::move(d), s, conflict);
			});
}

Dictionary InventoryCatalog::register_discovery_policy(const Ref<InventoryDiscoveryPolicy> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>"));
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "InventoryDiscoveryPolicy");
	return register_one(catalog, to_discovery_policy_definition(p_resource), identifier, source,
			[](inv::DefinitionCatalog &c, inv::DiscoveryPolicyDefinition d, const std::string &s, inv::IdentifierConflict *conflict) {
				return c.register_discovery_policy(std::move(d), s, conflict);
			});
}

Dictionary InventoryCatalog::register_item(const Ref<InventoryItemDefinition> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>"));
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "InventoryItemDefinition");
	return register_one(catalog, to_item_definition(p_resource), identifier, source,
			[](inv::DefinitionCatalog &c, inv::ItemDefinition d, const std::string &s, inv::IdentifierConflict *conflict) {
				return c.register_item(std::move(d), s, conflict);
			});
}

Dictionary InventoryCatalog::register_container(const Ref<InventoryContainerDefinition> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>"));
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "InventoryContainerDefinition");
	return register_one(catalog, to_container_definition(p_resource), identifier, source,
			[](inv::DefinitionCatalog &c, inv::ContainerDefinition d, const std::string &s, inv::IdentifierConflict *conflict) {
				return c.register_container(std::move(d), s, conflict);
			});
}

Dictionary InventoryCatalog::register_profile(const Ref<InventoryProfileDefinition> &p_resource) {
	if (p_resource.is_null()) {
		return diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>"));
	}
	const String identifier = String(p_resource->get_identifier());
	const String source = source_label_of(p_resource, "InventoryProfileDefinition");
	return register_one(catalog, to_profile_definition(p_resource), identifier, source,
			[](inv::DefinitionCatalog &c, inv::InventoryProfileDefinition d, const std::string &s, inv::IdentifierConflict *conflict) {
				return c.register_profile(std::move(d), s, conflict);
			});
}

Array InventoryCatalog::register_catalog_resource(const Ref<InventoryCatalogResource> &p_catalog) {
	Array results;
	if (p_catalog.is_null()) {
		results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>")));
		return results;
	}

	const TypedArray<InventoryTraitSchema> trait_schemas = p_catalog->get_trait_schemas();
	for (int i = 0; i < trait_schemas.size(); ++i) {
		results.append(register_trait_schema(trait_schemas[i]));
	}
	const TypedArray<InventoryDiscoveryPolicy> discovery_policies = p_catalog->get_discovery_policies();
	if (!discovery_policies.is_empty() && catalog.find_feature(inv::FEATURE_DISCOVERY) == nullptr) {
		const Dictionary feature_result = register_discovery_definitions();
		if (int(feature_result.get("status_code", int(inv::StatusCode::INTERNAL_ERROR))) != int(inv::StatusCode::OK)) {
			results.append(feature_result);
			return results;
		}
	}
	for (int i = 0; i < discovery_policies.size(); ++i) {
		results.append(register_discovery_policy(discovery_policies[i]));
	}
	const TypedArray<InventoryContainerDefinition> containers = p_catalog->get_containers();
	for (int i = 0; i < containers.size(); ++i) {
		results.append(register_container(containers[i]));
	}
	const TypedArray<InventoryItemDefinition> items = p_catalog->get_items();
	for (int i = 0; i < items.size(); ++i) {
		results.append(register_item(items[i]));
	}
	const TypedArray<InventoryProfileDefinition> profiles = p_catalog->get_profiles();
	for (int i = 0; i < profiles.size(); ++i) {
		results.append(register_profile(profiles[i]));
	}
	return results;
}

Dictionary InventoryCatalog::register_integration_mapping(const String &p_identifier, const PackedByteArray &p_canonical_bytes, const String &p_source) {
	inv::IdentifierConflict conflict;
	const inv::Status status = catalog.register_integration_mapping(
			to_std(p_identifier), from_packed(p_canonical_bytes), to_std(p_source), &conflict);
	return diagnostic_dict(status, p_identifier, p_source);
}

Dictionary InventoryCatalog::seal() {
	std::string offending;
	const inv::Status status = catalog.seal(&offending);
	return diagnostic_dict(status, String(offending.c_str()), String("<seal>"));
}

int64_t InventoryCatalog::manifest_fingerprint() const {
	const inv::ContentManifest *manifest = catalog.manifest();
	return manifest == nullptr ? 0 : int64_t(manifest->fingerprint);
}

String InventoryCatalog::api_version() const {
	return String(inv::api_version_string().c_str());
}

int InventoryCatalog::api_version_major() const { return inv::api_version_major(); }
int InventoryCatalog::api_version_minor() const { return inv::api_version_minor(); }
int InventoryCatalog::api_version_patch() const { return inv::api_version_patch(); }
int InventoryCatalog::protocol_version() const { return int(inv::protocol_version()); }
int InventoryCatalog::resource_schema_version() const { return int(inv::resource_schema_version()); }
int InventoryCatalog::feature_module_version() const { return int(inv::feature_module_version()); }
int InventoryCatalog::persistence_schema_version() const { return int(inv::persistence_schema_version()); }
String InventoryCatalog::manifest_algorithm() const { return String(inv::manifest_algorithm()); }
String InventoryCatalog::mass_unit() const { return String(inv::mass_unit()); }

Array InventoryCatalog::validate_resource(const Ref<Resource> &p_resource) const {
	Array results;
	if (p_resource.is_null()) {
		results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(), String("<null>")));
		return results;
	}

	// A fresh scratch catalog: never `this->catalog`, so validate_resource()
	// never registers into (or otherwise affects) an already-sealed or
	// still-open real catalog (3.9's "without registering" contract).
	inv::DefinitionCatalog scratch;

	if (const Ref<InventoryTraitSchema> trait_schema = p_resource; trait_schema.is_valid()) {
		inv::IdentifierConflict conflict;
		const inv::Status status = scratch.register_trait_schema(
				to_trait_schema_definition(trait_schema), to_std(source_label_of(p_resource, "InventoryTraitSchema")), &conflict);
		results.append(diagnostic_dict(status, String(trait_schema->get_identifier()), source_label_of(p_resource, "InventoryTraitSchema")));
		return results;
	}
	if (const Ref<InventoryDiscoveryPolicy> discovery_policy = p_resource; discovery_policy.is_valid()) {
		inv::IdentifierConflict conflict;
		const inv::Status status = scratch.register_discovery_policy(
				to_discovery_policy_definition(discovery_policy),
				to_std(source_label_of(p_resource, "InventoryDiscoveryPolicy")),
				&conflict);
		results.append(diagnostic_dict(status, String(discovery_policy->get_identifier()),
				source_label_of(p_resource, "InventoryDiscoveryPolicy")));
		return results;
	}
	if (const Ref<InventoryItemDefinition> item = p_resource; item.is_valid()) {
		inv::IdentifierConflict conflict;
		const inv::Status status = scratch.register_item(
				to_item_definition(item), to_std(source_label_of(p_resource, "InventoryItemDefinition")), &conflict);
		results.append(diagnostic_dict(status, String(item->get_identifier()), source_label_of(p_resource, "InventoryItemDefinition")));
		return results;
	}
	if (const Ref<InventoryContainerDefinition> container = p_resource; container.is_valid()) {
		inv::IdentifierConflict conflict;
		const inv::Status status = scratch.register_container(
				to_container_definition(container), to_std(source_label_of(p_resource, "InventoryContainerDefinition")), &conflict);
		results.append(diagnostic_dict(status, String(container->get_identifier()), source_label_of(p_resource, "InventoryContainerDefinition")));
		return results;
	}
	if (const Ref<InventoryProfileDefinition> profile = p_resource; profile.is_valid()) {
		inv::IdentifierConflict conflict;
		const inv::Status status = scratch.register_profile(
				to_profile_definition(profile), to_std(source_label_of(p_resource, "InventoryProfileDefinition")), &conflict);
		results.append(diagnostic_dict(status, String(profile->get_identifier()), source_label_of(p_resource, "InventoryProfileDefinition")));
		return results;
	}
	if (const Ref<InventoryCatalogResource> full_catalog = p_resource; full_catalog.is_valid()) {
		scratch.register_builtin_definitions();
		const TypedArray<InventoryDiscoveryPolicy> discovery_policies = full_catalog->get_discovery_policies();
		if (!discovery_policies.is_empty()) {
			const inv::Status feature_status = scratch.register_discovery_definitions();
			if (!feature_status.ok()) {
				results.append(diagnostic_dict(feature_status, String(inv::FEATURE_DISCOVERY), String("<builtin-discovery>")));
				return results;
			}
		}
		const TypedArray<InventoryTraitSchema> trait_schemas = full_catalog->get_trait_schemas();
		for (int i = 0; i < trait_schemas.size(); ++i) {
			const Ref<InventoryTraitSchema> entry = trait_schemas[i];
			if (entry.is_null()) {
				results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(),
						vformat("%s[trait_schemas[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
				continue;
			}
			inv::IdentifierConflict conflict;
			const inv::Status status = scratch.register_trait_schema(to_trait_schema_definition(entry),
					to_std(vformat("%s[trait_schemas[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)), &conflict);
			results.append(diagnostic_dict(status, String(entry->get_identifier()),
					vformat("%s[trait_schemas[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
		}
		for (int i = 0; i < discovery_policies.size(); ++i) {
			const Ref<InventoryDiscoveryPolicy> entry = discovery_policies[i];
			if (entry.is_null()) {
				results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(),
						vformat("%s[discovery_policies[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
				continue;
			}
			inv::IdentifierConflict conflict;
			const inv::Status status = scratch.register_discovery_policy(to_discovery_policy_definition(entry),
					to_std(vformat("%s[discovery_policies[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)), &conflict);
			results.append(diagnostic_dict(status, String(entry->get_identifier()),
					vformat("%s[discovery_policies[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
		}
		const TypedArray<InventoryContainerDefinition> containers = full_catalog->get_containers();
		for (int i = 0; i < containers.size(); ++i) {
			const Ref<InventoryContainerDefinition> entry = containers[i];
			if (entry.is_null()) {
				results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(),
						vformat("%s[containers[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
				continue;
			}
			inv::IdentifierConflict conflict;
			const inv::Status status = scratch.register_container(to_container_definition(entry),
					to_std(vformat("%s[containers[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)), &conflict);
			results.append(diagnostic_dict(status, String(entry->get_identifier()),
					vformat("%s[containers[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
		}
		const TypedArray<InventoryItemDefinition> items = full_catalog->get_items();
		for (int i = 0; i < items.size(); ++i) {
			const Ref<InventoryItemDefinition> entry = items[i];
			if (entry.is_null()) {
				results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(),
						vformat("%s[items[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
				continue;
			}
			inv::IdentifierConflict conflict;
			const inv::Status status = scratch.register_item(to_item_definition(entry),
					to_std(vformat("%s[items[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)), &conflict);
			results.append(diagnostic_dict(status, String(entry->get_identifier()),
					vformat("%s[items[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
		}
		const TypedArray<InventoryProfileDefinition> profiles = full_catalog->get_profiles();
		for (int i = 0; i < profiles.size(); ++i) {
			const Ref<InventoryProfileDefinition> entry = profiles[i];
			if (entry.is_null()) {
				results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(),
						vformat("%s[profiles[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
				continue;
			}
			inv::IdentifierConflict conflict;
			const inv::Status status = scratch.register_profile(to_profile_definition(entry),
					to_std(vformat("%s[profiles[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)), &conflict);
			results.append(diagnostic_dict(status, String(entry->get_identifier()),
					vformat("%s[profiles[%d]]", source_label_of(p_resource, "InventoryCatalogResource"), i)));
		}
		std::string offending;
		const inv::Status seal_status = scratch.seal(&offending);
		results.append(diagnostic_dict(seal_status, String(offending.c_str()), String("<seal>")));
		return results;
	}

	results.append(diagnostic_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT), String(),
			vformat("<unrecognized resource type '%s'>", p_resource->get_class())));
	return results;
}

void InventoryCatalog::_bind_methods() {
	ClassDB::bind_method(D_METHOD("register_builtin_definitions"), &InventoryCatalog::register_builtin_definitions);
	ClassDB::bind_method(D_METHOD("register_discovery_definitions"), &InventoryCatalog::register_discovery_definitions);
	ClassDB::bind_method(D_METHOD("register_trait_schema", "resource"), &InventoryCatalog::register_trait_schema);
	ClassDB::bind_method(D_METHOD("register_discovery_policy", "resource"), &InventoryCatalog::register_discovery_policy);
	ClassDB::bind_method(D_METHOD("register_item", "resource"), &InventoryCatalog::register_item);
	ClassDB::bind_method(D_METHOD("register_container", "resource"), &InventoryCatalog::register_container);
	ClassDB::bind_method(D_METHOD("register_profile", "resource"), &InventoryCatalog::register_profile);
	ClassDB::bind_method(D_METHOD("register_catalog_resource", "catalog"), &InventoryCatalog::register_catalog_resource);
	ClassDB::bind_method(D_METHOD("register_integration_mapping", "identifier", "canonical_bytes", "source"),
			&InventoryCatalog::register_integration_mapping, DEFVAL(String("<script>")));
	ClassDB::bind_method(D_METHOD("seal"), &InventoryCatalog::seal);
	ClassDB::bind_method(D_METHOD("is_sealed"), &InventoryCatalog::is_sealed);
	ClassDB::bind_method(D_METHOD("manifest_fingerprint"), &InventoryCatalog::manifest_fingerprint);
	ClassDB::bind_method(D_METHOD("api_version"), &InventoryCatalog::api_version);
	ClassDB::bind_method(D_METHOD("api_version_major"), &InventoryCatalog::api_version_major);
	ClassDB::bind_method(D_METHOD("api_version_minor"), &InventoryCatalog::api_version_minor);
	ClassDB::bind_method(D_METHOD("api_version_patch"), &InventoryCatalog::api_version_patch);
	ClassDB::bind_method(D_METHOD("protocol_version"), &InventoryCatalog::protocol_version);
	ClassDB::bind_method(D_METHOD("resource_schema_version"), &InventoryCatalog::resource_schema_version);
	ClassDB::bind_method(D_METHOD("feature_module_version"), &InventoryCatalog::feature_module_version);
	ClassDB::bind_method(D_METHOD("persistence_schema_version"), &InventoryCatalog::persistence_schema_version);
	ClassDB::bind_method(D_METHOD("manifest_algorithm"), &InventoryCatalog::manifest_algorithm);
	ClassDB::bind_method(D_METHOD("mass_unit"), &InventoryCatalog::mass_unit);
	ClassDB::bind_method(D_METHOD("validate_resource", "resource"), &InventoryCatalog::validate_resource);

	BIND_ENUM_CONSTANT(STATUS_OK);
	BIND_ENUM_CONSTANT(STATUS_INVALID_ARGUMENT);
	BIND_ENUM_CONSTANT(STATUS_NOT_FOUND);
	BIND_ENUM_CONSTANT(STATUS_ALREADY_EXISTS);
	BIND_ENUM_CONSTANT(STATUS_OUT_OF_BOUNDS);
	BIND_ENUM_CONSTANT(STATUS_ARITHMETIC_ERROR);
	BIND_ENUM_CONSTANT(STATUS_LIMIT_EXCEEDED);
	BIND_ENUM_CONSTANT(STATUS_NOT_SUPPORTED);
	BIND_ENUM_CONSTANT(STATUS_INTERNAL_ERROR);
	BIND_ENUM_CONSTANT(STATUS_INVALID_IDENTIFIER);
	BIND_ENUM_CONSTANT(STATUS_DUPLICATE_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_UNKNOWN_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_INVALID_REFERENCE);
	BIND_ENUM_CONSTANT(STATUS_CATALOG_SEALED);
	BIND_ENUM_CONSTANT(STATUS_CATALOG_NOT_SEALED);
	BIND_ENUM_CONSTANT(STATUS_HASH_COLLISION);
	BIND_ENUM_CONSTANT(STATUS_DEPENDENCY_MISSING);
	BIND_ENUM_CONSTANT(STATUS_DEPENDENCY_CYCLE);
	BIND_ENUM_CONSTANT(STATUS_INCOMPATIBLE_DEFINITION);
	BIND_ENUM_CONSTANT(STATUS_MANIFEST_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_PROTOCOL_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_SCHEMA_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_FEATURE_UNSUPPORTED);
	BIND_ENUM_CONSTANT(STATUS_ENCODE_FAILED);
	BIND_ENUM_CONSTANT(STATUS_DECODE_FAILED);
	BIND_ENUM_CONSTANT(STATUS_PAYLOAD_TOO_LARGE);
	BIND_ENUM_CONSTANT(STATUS_REVISION_MISMATCH);
	BIND_ENUM_CONSTANT(STATUS_DUPLICATE_COMMAND);
	BIND_ENUM_CONSTANT(STATUS_PERMISSION_DENIED);
	BIND_ENUM_CONSTANT(STATUS_ROLE_VIOLATION);
	BIND_ENUM_CONSTANT(STATUS_INVARIANT_VIOLATION);
	BIND_ENUM_CONSTANT(STATUS_COMMAND_REJECTED);
	BIND_ENUM_CONSTANT(STATUS_SNAPSHOT_REQUIRED);
}

} // namespace godot
