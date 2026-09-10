#include "resources/inventory_catalog_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryCatalogResource::set_trait_schemas(const TypedArray<InventoryTraitSchema> &p_trait_schemas) {
	trait_schemas = p_trait_schemas;
	emit_changed();
}

void InventoryCatalogResource::set_items(const TypedArray<InventoryItemDefinition> &p_items) {
	items = p_items;
	emit_changed();
}

void InventoryCatalogResource::set_containers(const TypedArray<InventoryContainerDefinition> &p_containers) {
	containers = p_containers;
	emit_changed();
}

void InventoryCatalogResource::set_discovery_policies(const TypedArray<InventoryDiscoveryPolicy> &p_policies) {
	discovery_policies = p_policies;
	emit_changed();
}

void InventoryCatalogResource::set_profiles(const TypedArray<InventoryProfileDefinition> &p_profiles) {
	profiles = p_profiles;
	emit_changed();
}

void InventoryCatalogResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_trait_schemas", "trait_schemas"), &InventoryCatalogResource::set_trait_schemas);
	ClassDB::bind_method(D_METHOD("get_trait_schemas"), &InventoryCatalogResource::get_trait_schemas);
	ClassDB::bind_method(D_METHOD("set_items", "items"), &InventoryCatalogResource::set_items);
	ClassDB::bind_method(D_METHOD("get_items"), &InventoryCatalogResource::get_items);
	ClassDB::bind_method(D_METHOD("set_containers", "containers"), &InventoryCatalogResource::set_containers);
	ClassDB::bind_method(D_METHOD("get_containers"), &InventoryCatalogResource::get_containers);
	ClassDB::bind_method(D_METHOD("set_discovery_policies", "discovery_policies"), &InventoryCatalogResource::set_discovery_policies);
	ClassDB::bind_method(D_METHOD("get_discovery_policies"), &InventoryCatalogResource::get_discovery_policies);
	ClassDB::bind_method(D_METHOD("set_profiles", "profiles"), &InventoryCatalogResource::set_profiles);
	ClassDB::bind_method(D_METHOD("get_profiles"), &InventoryCatalogResource::get_profiles);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "trait_schemas", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryTraitSchema", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_trait_schemas", "get_trait_schemas");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "items", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryItemDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_items", "get_items");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "containers", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryContainerDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_containers", "get_containers");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "discovery_policies", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryDiscoveryPolicy", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_discovery_policies", "get_discovery_policies");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "profiles", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryProfileDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_profiles", "get_profiles");
}

} // namespace godot
