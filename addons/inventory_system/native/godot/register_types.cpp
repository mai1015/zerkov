#include "godot/register_types.h"

#include "godot/inventory_authority.h"
#include "godot/inventory_catalog.h"
#include "godot/inventory_discovery_resources.h"
#include "godot/inventory_replica_node.h"
#include "godot/inventory_observer_replica_node.h"
#include "godot/inventory_network_gateway.h"
#include "godot/inventory_snapshot_resource.h"

#include "resources/inventory_catalog_resource.h"
#include "resources/inventory_container_constraints.h"
#include "resources/inventory_container_definition.h"
#include "resources/inventory_discovery_policy.h"
#include "resources/inventory_item_definition.h"
#include "resources/inventory_item_trait_value.h"
#include "resources/inventory_named_slot.h"
#include "resources/inventory_profile_definition.h"
#include "resources/inventory_profile_limits.h"
#include "resources/inventory_trait_schema.h"

#include <gdextension_interface.h>

#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_inventory_system_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	// Authoring resources (native/resources/). Sub-resources are registered
	// before the definitions that reference them purely for readability --
	// ClassDB registration order does not otherwise matter.
	GDREGISTER_CLASS(InventoryTraitSchema);
	GDREGISTER_CLASS(InventoryItemTraitValue);
	GDREGISTER_CLASS(InventoryItemDefinition);
	GDREGISTER_CLASS(InventoryNamedSlot);
	GDREGISTER_CLASS(InventoryContainerConstraints);
	GDREGISTER_CLASS(InventoryDiscoveryPolicy);
	GDREGISTER_CLASS(InventoryContainerDefinition);
	GDREGISTER_CLASS(InventoryProfileLimits);
	GDREGISTER_CLASS(InventoryProfileDefinition);
	GDREGISTER_CLASS(InventoryCatalogResource);

	// Façade (native/godot/): the sealed-catalog boundary, the immutable
	// snapshot DTO, and the authoritative role.
	GDREGISTER_CLASS(InventoryCatalog);
	GDREGISTER_CLASS(InventorySnapshotResource);
	GDREGISTER_CLASS(InventoryDiscoveryEntryResource);
	GDREGISTER_CLASS(InventoryDiscoveryContainerViewResource);
	GDREGISTER_CLASS(InventoryDiscoveryTaskResource);
	GDREGISTER_CLASS(InventoryDiscoveryResultResource);
	GDREGISTER_CLASS(InventoryDiscoverySnapshotResource);
	GDREGISTER_CLASS(InventoryDiscoveryDeltaResource);
	GDREGISTER_CLASS(InventoryAuthority);
	GDREGISTER_CLASS(InventoryReplicaNode);
	GDREGISTER_CLASS(InventoryObserverReplicaNode);
	GDREGISTER_CLASS(InventoryNetworkGateway);
}

void uninitialize_inventory_system_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

// Entry point named in addons/inventory_system/inventory_system.gdextension.
GDExtensionBool GDE_EXPORT inventory_system_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_inventory_system_module);
	init_obj.register_terminator(uninitialize_inventory_system_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
