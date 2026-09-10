#ifndef INVENTORY_SYSTEM_RESOURCES_CONTAINER_CONSTRAINTS_H
#define INVENTORY_SYSTEM_RESOURCES_CONTAINER_CONSTRAINTS_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

// Editor-authored counterpart of `inv::ContainerConstraints` (native/core/
// inv_definitions.h). Composable capacity/filter/access/nesting/retention/
// stack-split/auto-place/quick-transfer policy attached to an
// `InventoryContainerDefinition`. Every flag/bound here only accepts or
// rejects a proposed state -- it never invents placement semantics, which
// belong to the container's own ownership layout.
class InventoryContainerConstraints : public Resource {
	GDCLASS(InventoryContainerConstraints, Resource)

public:
	enum Retention {
		RETENTION_NONE = 0,
		RETENTION_PROTECTED = 1,
		RETENTION_BOUND = 2,
	};

	// Bitmask matching `inv::AccessFlag` (INSERT=1, REMOVE=2, MOVE=4, INSPECT=8).
	// Bound via BIND_BITFIELD_FLAG (see the .cpp's _bind_methods()) and
	// VARIANT_BITFIELD_CAST below, so every bit is a GDScript-referenceable
	// named constant -- `InventoryContainerConstraints.ACCESS_INSERT` etc. --
	// exactly like this class's own `Retention` enum, rather than being
	// documented only here in the header with no script-visible names.
	enum AccessFlagBits {
		ACCESS_INSERT = 1 << 0,
		ACCESS_REMOVE = 1 << 1,
		ACCESS_MOVE = 1 << 2,
		ACCESS_INSPECT = 1 << 3,
	};

	// Zero inherits the profile's hard bound.
	void set_max_items(int p_max_items);
	int get_max_items() const { return max_items; }

	void set_has_mass_capacity(bool p_has_mass_capacity);
	bool get_has_mass_capacity() const { return has_mass_capacity; }

	// Checked signed 64-bit milligrams; meaningful only when
	// `has_mass_capacity` is true and the profile enables
	// `inventory.feature.mass_capacity`.
	void set_mass_capacity_mg(int64_t p_mass_capacity_mg);
	int64_t get_mass_capacity_mg() const { return mass_capacity_mg; }

	void set_required_traits(const PackedStringArray &p_required_traits);
	PackedStringArray get_required_traits() const { return required_traits; }

	void set_blocked_traits(const PackedStringArray &p_blocked_traits);
	PackedStringArray get_blocked_traits() const { return blocked_traits; }

	void set_allow_nesting(bool p_allow_nesting);
	bool get_allow_nesting() const { return allow_nesting; }

	void set_max_nesting_depth(int p_max_nesting_depth);
	int get_max_nesting_depth() const { return max_nesting_depth; }

	// Bitmask of AccessFlagBits; default grants insert/remove/move/inspect
	// (matches `inv::DEFAULT_ACCESS`).
	void set_access_mask(int p_access_mask);
	int get_access_mask() const { return access_mask; }

	void set_retention(Retention p_retention);
	Retention get_retention() const { return retention; }

	void set_allow_stack_split(bool p_allow_stack_split);
	bool get_allow_stack_split() const { return allow_stack_split; }

	void set_allow_auto_placement(bool p_allow_auto_placement);
	bool get_allow_auto_placement() const { return allow_auto_placement; }

	void set_allow_quick_transfer(bool p_allow_quick_transfer);
	bool get_allow_quick_transfer() const { return allow_quick_transfer; }

protected:
	static void _bind_methods();

private:
	int max_items = 0;
	bool has_mass_capacity = false;
	int64_t mass_capacity_mg = 0;
	PackedStringArray required_traits;
	PackedStringArray blocked_traits;
	bool allow_nesting = false;
	int max_nesting_depth = 0;
	int access_mask = ACCESS_INSERT | ACCESS_REMOVE | ACCESS_MOVE | ACCESS_INSPECT;
	Retention retention = RETENTION_NONE;
	bool allow_stack_split = false;
	bool allow_auto_placement = false;
	bool allow_quick_transfer = false;
};

} // namespace godot

VARIANT_ENUM_CAST(InventoryContainerConstraints::Retention);
VARIANT_BITFIELD_CAST(InventoryContainerConstraints::AccessFlagBits);

#endif // INVENTORY_SYSTEM_RESOURCES_CONTAINER_CONSTRAINTS_H
