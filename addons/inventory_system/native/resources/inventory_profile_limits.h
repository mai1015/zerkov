#ifndef INVENTORY_SYSTEM_RESOURCES_PROFILE_LIMITS_H
#define INVENTORY_SYSTEM_RESOURCES_PROFILE_LIMITS_H

#include <godot_cpp/classes/resource.hpp>

namespace godot {

// Editor-authored counterpart of `inv::InventoryLimitsDefinition` (native/
// core/inv_definitions.h). Defaults mirror the current compiled-in hard
// bounds (native/core/inv_limits.h); a profile may lower these but the core
// re-validates that a lowered value never exceeds the hard limit at
// registration.
class InventoryProfileLimits : public Resource {
	GDCLASS(InventoryProfileLimits, Resource)

public:
	void set_max_items(int p_max_items);
	int get_max_items() const { return max_items; }

	void set_max_containers(int p_max_containers);
	int get_max_containers() const { return max_containers; }

	void set_max_references(int p_max_references);
	int get_max_references() const { return max_references; }

	void set_max_nesting_depth(int p_max_nesting_depth);
	int get_max_nesting_depth() const { return max_nesting_depth; }

	void set_max_mutable_components_per_item(int p_max_mutable_components_per_item);
	int get_max_mutable_components_per_item() const { return max_mutable_components_per_item; }

protected:
	static void _bind_methods();

private:
	int max_items = 4096;
	int max_containers = 512;
	int max_references = 256;
	int max_nesting_depth = 16;
	int max_mutable_components_per_item = 32;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_PROFILE_LIMITS_H
