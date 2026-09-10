#ifndef INVENTORY_SYSTEM_RESOURCES_CATALOG_RESOURCE_H
#define INVENTORY_SYSTEM_RESOURCES_CATALOG_RESOURCE_H

#include "resources/inventory_container_definition.h"
#include "resources/inventory_discovery_policy.h"
#include "resources/inventory_item_definition.h"
#include "resources/inventory_profile_definition.h"
#include "resources/inventory_trait_schema.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Aggregates every authoring definition for one-call registration
// (`InventoryCatalog.register_catalog_resource()`, native/godot/
// inventory_catalog.h). Named `InventoryCatalogResource` (rather than
// `InventoryCatalog`, this addon sibling's usual undecorated naming) to
// avoid colliding with the façade's own `InventoryCatalog` RefCounted, which
// owns the sealed native catalog this resource's contents are copied into.
class InventoryCatalogResource : public Resource {
	GDCLASS(InventoryCatalogResource, Resource)

public:
	void set_trait_schemas(const TypedArray<InventoryTraitSchema> &p_trait_schemas);
	TypedArray<InventoryTraitSchema> get_trait_schemas() const { return trait_schemas; }

	void set_items(const TypedArray<InventoryItemDefinition> &p_items);
	TypedArray<InventoryItemDefinition> get_items() const { return items; }

	void set_containers(const TypedArray<InventoryContainerDefinition> &p_containers);
	TypedArray<InventoryContainerDefinition> get_containers() const { return containers; }

	void set_discovery_policies(const TypedArray<InventoryDiscoveryPolicy> &p_policies);
	TypedArray<InventoryDiscoveryPolicy> get_discovery_policies() const { return discovery_policies; }

	void set_profiles(const TypedArray<InventoryProfileDefinition> &p_profiles);
	TypedArray<InventoryProfileDefinition> get_profiles() const { return profiles; }

protected:
	static void _bind_methods();

private:
	TypedArray<InventoryTraitSchema> trait_schemas;
	TypedArray<InventoryItemDefinition> items;
	TypedArray<InventoryContainerDefinition> containers;
	TypedArray<InventoryDiscoveryPolicy> discovery_policies;
	TypedArray<InventoryProfileDefinition> profiles;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_CATALOG_RESOURCE_H
