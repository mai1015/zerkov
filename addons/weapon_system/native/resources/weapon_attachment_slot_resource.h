#ifndef WEAPON_SYSTEM_RESOURCES_WEAPON_ATTACHMENT_SLOT_RESOURCE_H
#define WEAPON_SYSTEM_RESOURCES_WEAPON_ATTACHMENT_SLOT_RESOURCE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// One entry in `WeaponDefinitionResource.attachment_slots`: the editor-
// authored counterpart of `wpn::WeaponAttachmentSlot` (native/core/
// wpn_definitions.h) -- a stable slot ID plus the single attachment kind it
// accepts. Intentionally a tiny standalone Resource (rather than an inline
// Dictionary), mirroring this addon's own `HitscanShotProfileResource`/
// `WeaponDefinitionResource` precedent and the sibling gameplay_abilities
// addon's `GameplaySetByCallerField`/`GameplayAbilityTrigger` "one array
// element per small Resource" pattern.
//
// V1's flat attachment loadout means this slot only ever accepts ONE
// compatible attachment kind and never itself declares child slots (design.md
// "Flat attachment loadout"); `SlotKind` therefore intentionally has no way
// to express more than one kind per slot (unlike
// `AttachmentDefinitionResource.compatible_slot_kinds_mask`, which is a bitmask
// because an ATTACHMENT may fit several slot kinds).
class WeaponAttachmentSlotResource : public Resource {
	GDCLASS(WeaponAttachmentSlotResource, Resource)

public:
	// Mirrors the closed V1 `wpn::AttachmentSlotKind` set (native/core/
	// wpn_definitions.h). `WeaponDefinitionCatalog` translates this ordinal
	// explicitly into the sealed core bit value; the numeric value here is
	// never cast directly onto the core enum (see that façade's
	// `to_attachment_slot_kind_bit()`).
	enum SlotKind {
		SLOT_KIND_OPTIC = 0,
		SLOT_KIND_MUZZLE = 1,
		SLOT_KIND_STOCK = 2,
		SLOT_KIND_GRIP = 3,
	};

	void set_slot_id(const StringName &p_slot_id);
	StringName get_slot_id() const { return slot_id; }

	void set_slot_kind(SlotKind p_slot_kind);
	SlotKind get_slot_kind() const { return slot_kind; }

protected:
	static void _bind_methods();

private:
	StringName slot_id;
	SlotKind slot_kind = SLOT_KIND_OPTIC;
};

} // namespace godot

VARIANT_ENUM_CAST(WeaponAttachmentSlotResource::SlotKind);

#endif // WEAPON_SYSTEM_RESOURCES_WEAPON_ATTACHMENT_SLOT_RESOURCE_H
