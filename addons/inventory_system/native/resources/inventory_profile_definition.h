#ifndef INVENTORY_SYSTEM_RESOURCES_PROFILE_DEFINITION_H
#define INVENTORY_SYSTEM_RESOURCES_PROFILE_DEFINITION_H

#include "resources/inventory_profile_limits.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `inv::InventoryProfileDefinition`
// (native/core/inv_definitions.h). Declares an inventory's stable root
// containers, enabled command features, and aggregate limits.
// `InventoryAuthority.create_inventory()` instantiates one `InventoryRuntime`
// per profile identifier.
class InventoryProfileDefinition : public Resource {
	GDCLASS(InventoryProfileDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }

	// Identifiers of `InventoryContainerDefinition`s instantiated as this
	// profile's root containers.
	void set_root_containers(const PackedStringArray &p_root_containers);
	PackedStringArray get_root_containers() const { return root_containers; }

	// Identifiers of `inventory.feature.*` modules this profile enables
	// (e.g. `inventory.feature.mass_capacity`, `inventory.feature.nesting`).
	void set_enabled_features(const PackedStringArray &p_enabled_features);
	PackedStringArray get_enabled_features() const { return enabled_features; }

	// Optional; a null value registers with the core's own compiled-in hard
	// defaults (see `InventoryProfileLimits`' own defaults, which already
	// mirror them).
	void set_limits(const Ref<InventoryProfileLimits> &p_limits);
	Ref<InventoryProfileLimits> get_limits() const { return limits; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = 1;
	PackedStringArray root_containers;
	PackedStringArray enabled_features;
	Ref<InventoryProfileLimits> limits;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_PROFILE_DEFINITION_H
