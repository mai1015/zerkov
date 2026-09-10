#ifndef INVENTORY_SYSTEM_RESOURCES_ITEM_DEFINITION_H
#define INVENTORY_SYSTEM_RESOURCES_ITEM_DEFINITION_H

#include "resources/inventory_item_trait_value.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Editor-authored counterpart of `inv::ItemDefinition` (native/core/
// inv_definitions.h). Mass is authored directly as checked signed 64-bit
// milligrams (`unit_mass_mg`) -- this resource exposes no float mass
// convenience, so there is no rounding rule to document (contracts.md:
// "floating-point mass is never authoritative"). `InventoryCatalog`
// (native/godot/inventory_catalog.h) validates and copies this into a sealed
// native catalog; later mutation of this Resource never affects an already
// sealed catalog.
class InventoryItemDefinition : public Resource {
	GDCLASS(InventoryItemDefinition, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }

	// Maximum quantity one stack of this item may hold. 1 means "does not
	// stack"; `inventory.feature.stacking` owns merge/split behavior on top
	// of this bound (contracts.md "Stack semantics").
	void set_max_stack(int64_t p_max_stack);
	int64_t get_max_stack() const { return max_stack; }

	// Checked signed 64-bit milligrams; the canonical mass unit
	// (`inv::MASS_UNIT`). Never a float.
	void set_unit_mass_mg(int64_t p_unit_mass_mg);
	int64_t get_unit_mass_mg() const { return unit_mass_mg; }

	void set_footprint_width(int p_footprint_width);
	int get_footprint_width() const { return footprint_width; }

	void set_footprint_height(int p_footprint_height);
	int get_footprint_height() const { return footprint_height; }

	void set_allow_rotation(bool p_allow_rotation);
	bool get_allow_rotation() const { return allow_rotation; }

	void set_traits(const TypedArray<InventoryItemTraitValue> &p_traits);
	TypedArray<InventoryItemTraitValue> get_traits() const { return traits; }

	// Identifiers of `InventoryContainerDefinition`s this item provides when
	// equipped/placed (rigs, backpacks, cases, secure containers). Validated
	// against the same catalog at registration.
	void set_provided_containers(const PackedStringArray &p_provided_containers);
	PackedStringArray get_provided_containers() const { return provided_containers; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int schema_version = 1;
	int64_t max_stack = 1;
	int64_t unit_mass_mg = 0;
	int footprint_width = 1;
	int footprint_height = 1;
	bool allow_rotation = false;
	TypedArray<InventoryItemTraitValue> traits;
	PackedStringArray provided_containers;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_ITEM_DEFINITION_H
