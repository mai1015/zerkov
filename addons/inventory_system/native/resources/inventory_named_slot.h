#ifndef INVENTORY_SYSTEM_RESOURCES_NAMED_SLOT_H
#define INVENTORY_SYSTEM_RESOURCES_NAMED_SLOT_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `inv::NamedSlotDefinition` (native/core/
// inv_definitions.h): one stable slot on a `NAMED_SLOTS`-layout
// `InventoryContainerDefinition` (e.g. headwear, weapon_primary).
class InventoryNamedSlot : public Resource {
	GDCLASS(InventoryNamedSlot, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_max_items(int p_max_items);
	int get_max_items() const { return max_items; }

	void set_required_traits(const PackedStringArray &p_required_traits);
	PackedStringArray get_required_traits() const { return required_traits; }

	void set_blocked_traits(const PackedStringArray &p_blocked_traits);
	PackedStringArray get_blocked_traits() const { return blocked_traits; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int max_items = 1;
	PackedStringArray required_traits;
	PackedStringArray blocked_traits;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_NAMED_SLOT_H
