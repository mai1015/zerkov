#ifndef INVENTORY_SYSTEM_RESOURCES_CONTAINER_DEFINITION_H
#define INVENTORY_SYSTEM_RESOURCES_CONTAINER_DEFINITION_H

#include "resources/inventory_container_constraints.h"
#include "resources/inventory_named_slot.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Editor-authored counterpart of `inv::ContainerDefinition` (native/core/
// inv_definitions.h). A container selects exactly ONE ownership layout via
// `layout_kind`; only the fields relevant to the selected layout are
// meaningful (`_validate_property` hides the rest in the Inspector, matching
// this addon sibling's `GameplayEffectDefinition` convention). `constraints`
// composes zero or more deterministic constraints on top of the layout.
class InventoryContainerDefinition : public Resource {
	GDCLASS(InventoryContainerDefinition, Resource)

public:
	// Mirrors `inv::OwnershipLayoutKind` (SPATIAL_GRID=1, NAMED_SLOTS=2,
	// ORDERED_LIST=3); the façade converter maps these Godot-conventional
	// zero-based values onto the core's own explicitly.
	enum LayoutKind {
		LAYOUT_SPATIAL_GRID = 0,
		LAYOUT_NAMED_SLOTS = 1,
		LAYOUT_ORDERED_LIST = 2,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_schema_version(int p_schema_version);
	int get_schema_version() const { return schema_version; }

	void set_layout_kind(LayoutKind p_layout_kind);
	LayoutKind get_layout_kind() const { return layout_kind; }

	// -- SPATIAL_GRID fields --
	void set_grid_width(int p_grid_width);
	int get_grid_width() const { return grid_width; }
	void set_grid_height(int p_grid_height);
	int get_grid_height() const { return grid_height; }
	void set_grid_allow_rotation(bool p_grid_allow_rotation);
	bool get_grid_allow_rotation() const { return grid_allow_rotation; }

	// -- NAMED_SLOTS fields --
	void set_named_slots(const TypedArray<InventoryNamedSlot> &p_named_slots);
	TypedArray<InventoryNamedSlot> get_named_slots() const { return named_slots; }

	// -- ORDERED_LIST fields --
	void set_ordered_list_max_entries(int p_ordered_list_max_entries);
	int get_ordered_list_max_entries() const { return ordered_list_max_entries; }

	// Identifiers of `inventory.feature.*` modules this container activates
	// (e.g. `inventory.feature.stacking`, `inventory.feature.mass_capacity`).
	void set_enabled_features(const PackedStringArray &p_enabled_features);
	PackedStringArray get_enabled_features() const { return enabled_features; }

	void set_constraints(const Ref<InventoryContainerConstraints> &p_constraints);
	Ref<InventoryContainerConstraints> get_constraints() const { return constraints; }

	// Empty preserves instant disclosure. A non-empty identifier references
	// one registered InventoryDiscoveryPolicy and requires
	// inventory.feature.discovery on this container and its profile.
	void set_discovery_policy_identifier(const StringName &p_identifier);
	StringName get_discovery_policy_identifier() const { return discovery_policy_identifier; }

protected:
	static void _bind_methods();
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	int schema_version = 1;
	LayoutKind layout_kind = LAYOUT_SPATIAL_GRID;

	int grid_width = 1;
	int grid_height = 1;
	bool grid_allow_rotation = false;

	TypedArray<InventoryNamedSlot> named_slots;

	int ordered_list_max_entries = 1;

	PackedStringArray enabled_features;
	Ref<InventoryContainerConstraints> constraints;
	StringName discovery_policy_identifier;
};

} // namespace godot

VARIANT_ENUM_CAST(InventoryContainerDefinition::LayoutKind);

#endif // INVENTORY_SYSTEM_RESOURCES_CONTAINER_DEFINITION_H
