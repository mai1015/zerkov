#ifndef INVENTORY_SYSTEM_RESOURCES_ITEM_TRAIT_VALUE_H
#define INVENTORY_SYSTEM_RESOURCES_ITEM_TRAIT_VALUE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `inv::ItemTraitValue` (native/core/
// inv_definitions.h): one typed trait attached to an `InventoryItemDefinition`
// (native/resources/inventory_item_definition.h). The payload is opaque
// canonical bytes the core does not interpret beyond bounding it -- there is
// no first-party typed editor surface for trait payloads in this slice, so
// authoring a trait means authoring its already-canonical byte payload
// directly. `trait_identifier` must name an `InventoryTraitSchema` registered
// in the same catalog (validated at registration, never here).
class InventoryItemTraitValue : public Resource {
	GDCLASS(InventoryItemTraitValue, Resource)

public:
	void set_trait_identifier(const StringName &p_trait_identifier);
	StringName get_trait_identifier() const { return trait_identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	void set_payload(const PackedByteArray &p_payload);
	PackedByteArray get_payload() const { return payload; }

protected:
	static void _bind_methods();

private:
	StringName trait_identifier;
	int version = 1;
	PackedByteArray payload;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_ITEM_TRAIT_VALUE_H
