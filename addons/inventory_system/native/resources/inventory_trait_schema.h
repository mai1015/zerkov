#ifndef INVENTORY_SYSTEM_RESOURCES_TRAIT_SCHEMA_H
#define INVENTORY_SYSTEM_RESOURCES_TRAIT_SCHEMA_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `inv::TraitSchemaDefinition`
// (native/core/inv_definitions.h). Pure data: identifier, schema version,
// whether the trait is authority-affecting, and its bounded payload budget.
// `InventoryCatalog` (native/godot/inventory_catalog.h) validates and copies
// this into a sealed native `inv::DefinitionCatalog` -- this class never
// registers or validates itself.
class InventoryTraitSchema : public Resource {
	GDCLASS(InventoryTraitSchema, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	// True (the default) when this trait can affect authority, placement,
	// ownership, capacity, or transactions -- an unknown authority-affecting
	// trait makes a catalog incompatible (contracts.md). False marks a purely
	// presentational/cosmetic trait.
	void set_authority_affecting(bool p_authority_affecting);
	bool get_authority_affecting() const { return authority_affecting; }

	// Bounded canonical payload budget for any `InventoryItemTraitValue`
	// referencing this schema. Mirrors `inv::MAX_TRAIT_PAYLOAD_BYTES` (1024)
	// as an editor default; the core re-validates the real bound at
	// registration regardless of what is authored here.
	void set_max_payload_bytes(int p_max_payload_bytes);
	int get_max_payload_bytes() const { return max_payload_bytes; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int version = 1;
	bool authority_affecting = true;
	int max_payload_bytes = 1024;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_RESOURCES_TRAIT_SCHEMA_H
