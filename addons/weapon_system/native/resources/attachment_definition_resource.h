#ifndef WEAPON_SYSTEM_RESOURCES_ATTACHMENT_DEFINITION_RESOURCE_H
#define WEAPON_SYSTEM_RESOURCES_ATTACHMENT_DEFINITION_RESOURCE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `wpn::AttachmentDefinition` (native/core/
// wpn_definitions.h), mirrored field for field. `WeaponDefinitionCatalog`
// (native/godot/weapon_definition_catalog.h) VALIDATES and COPIES this
// Resource's current field values into a sealed native `wpn::WeaponCatalog`
// via `register_attachment()`; later mutation of this Resource never affects
// an already sealed catalog (weapon-authoring spec.md "Immutable Versioned
// Weapon Definitions").
//
// This schema intentionally has NO penetration, ammunition-identity,
// capacity, or damage field: those V1 Non-Goals for attachments (design.md
// "Flat attachment loadout": "Attachments MUST NOT modify ammunition
// identity, capacity, damage, penetration, or recoil recovery slope in V1")
// are unrepresentable here by omission, exactly like
// `WeaponDefinitionResource`'s omitted detachable-magazine/chamber/durability
// fields.
//
// `provided_slot_count` IS mirrored from the core struct (rather than
// omitted) specifically so `register_attachment()` can reject an authored
// nested attachment graph with an explicit field-identifying diagnostic
// instead of the field being simply absent (weapon-authoring spec.md
// "Versioned Recoil and Flat Attachment Definitions": "Attachment recursively
// provides another slot" -> "V1 validation rejects the nested graph
// explicitly"). A conforming V1 attachment always leaves it at 0.
class AttachmentDefinitionResource : public Resource {
	GDCLASS(AttachmentDefinitionResource, Resource)

public:
	// Bitmask matching `wpn::AttachmentSlotKind` (OPTIC=1, MUZZLE=2, STOCK=4,
	// GRIP=8). Bound via BIND_BITFIELD_FLAG (see the .cpp's _bind_methods())
	// and VARIANT_BITFIELD_CAST below, so every bit is a GDScript-referenceable
	// named constant -- `AttachmentDefinitionResource.SLOT_KIND_BIT_OPTIC`
	// etc. -- exactly like `InventoryContainerConstraints.AccessFlagBits`
	// (addons/inventory_system/native/resources/
	// inventory_container_constraints.h). `WeaponDefinitionCatalog` copies
	// `compatible_slot_kinds_mask` directly with no translation, since
	// `PROPERTY_HINT_FLAGS`'s sequential-bit assignment already matches the
	// core enum 1:1 (unlike `WeaponAttachmentSlotResource.slot_kind`, which is
	// a single ordinal choice and IS translated explicitly).
	enum SlotKindBits {
		SLOT_KIND_BIT_OPTIC = 1 << 0,
		SLOT_KIND_BIT_MUZZLE = 1 << 1,
		SLOT_KIND_BIT_STOCK = 1 << 2,
		SLOT_KIND_BIT_GRIP = 1 << 3,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	// Bitmask over the closed V1 `wpn::AttachmentSlotKind` set; see
	// `SlotKindBits` above.
	void set_compatible_slot_kinds_mask(int p_mask);
	int get_compatible_slot_kinds_mask() const { return compatible_slot_kinds_mask; }

	// Bounded set of free-form compatibility tags (weapon-authoring spec.md
	// "Versioned Recoil and Flat Attachment Definitions": "compatible slot
	// kinds/tags"); at most MAX_ATTACHMENT_COMPATIBLE_TAGS (8), each a valid
	// identifier, no duplicates.
	void set_compatible_tags(const PackedStringArray &p_tags);
	PackedStringArray get_compatible_tags() const { return compatible_tags; }

	// Signed parts-per-million modifiers, zero neutral, bounded to
	// +/-MAX_MODIFIER_DELTA_PPM (weapon-authoring spec.md "Canonical Modifier
	// Algebra").
	void set_accuracy_modifier_ppm(int64_t p_accuracy_modifier_ppm);
	int64_t get_accuracy_modifier_ppm() const { return accuracy_modifier_ppm; }

	void set_recoil_modifier_ppm(int64_t p_recoil_modifier_ppm);
	int64_t get_recoil_modifier_ppm() const { return recoil_modifier_ppm; }

	void set_noise_modifier_ppm(int64_t p_noise_modifier_ppm);
	int64_t get_noise_modifier_ppm() const { return noise_modifier_ppm; }

	void set_reload_duration_modifier_ppm(int64_t p_reload_duration_modifier_ppm);
	int64_t get_reload_duration_modifier_ppm() const { return reload_duration_modifier_ppm; }

	void set_cadence_modifier_ppm(int64_t p_cadence_modifier_ppm);
	int64_t get_cadence_modifier_ppm() const { return cadence_modifier_ppm; }

	// MUST be 0 in V1 -- see class comment. Any other value is rejected by
	// `WeaponDefinitionCatalog::register_attachment()` with the offending
	// field/value named, never silently clamped to 0.
	void set_provided_slot_count(int p_provided_slot_count);
	int get_provided_slot_count() const { return provided_slot_count; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int version = 1;
	int compatible_slot_kinds_mask = 0;
	PackedStringArray compatible_tags;
	int64_t accuracy_modifier_ppm = 0;
	int64_t recoil_modifier_ppm = 0;
	int64_t noise_modifier_ppm = 0;
	int64_t reload_duration_modifier_ppm = 0;
	int64_t cadence_modifier_ppm = 0;
	int provided_slot_count = 0;
};

} // namespace godot

VARIANT_BITFIELD_CAST(AttachmentDefinitionResource::SlotKindBits);

#endif // WEAPON_SYSTEM_RESOURCES_ATTACHMENT_DEFINITION_RESOURCE_H
