#ifndef WEAPON_SYSTEM_RESOURCES_WEAPON_DEFINITION_RESOURCE_H
#define WEAPON_SYSTEM_RESOURCES_WEAPON_DEFINITION_RESOURCE_H

#include "resources/weapon_attachment_slot_resource.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Editor-authored counterpart of `wpn::WeaponDefinition` (native/core/
// wpn_definitions.h), mirrored field for field. `WeaponDefinitionCatalog`
// (native/godot/weapon_definition_catalog.h) VALIDATES and COPIES this
// Resource's current field values into a sealed native `wpn::WeaponCatalog`;
// later mutation of this Resource never affects an already sealed catalog
// (weapon-authoring spec.md "Immutable Versioned Weapon Definitions").
//
// `fire_mode`/`mechanism` deliberately list every real-world firearm
// mechanism a later version might add (design.md Non-Goals: "automatic or
// burst fire", "... or projectiles") so an author can see the deferred
// vocabulary in the inspector, but `WeaponDefinitionCatalog::register_weapon()`
// rejects anything other than SemiAuto/Hitscan2D with a diagnostic naming
// the exact field and requested value -- it never silently substitutes
// semi-auto hitscan (weapon-authoring spec.md "Small Explicit V1 Firearm
// Schema": "Deferred mechanism is authored").
//
// This schema intentionally has NO property for a detachable-magazine item,
// chamber simulation, heat, jams, durability, or penetration: every one of
// those V1 Non-Goals (design.md "Goals / Non-Goals") is unrepresentable here
// by omission rather than merely rejected at validation time -- there is no
// field an author could even attempt to set.
//
// `accuracy_moa_milli`, `recoil_profile_id`/`recoil_profile_version`, and
// `attachment_slots` mirror the core's later `wpn::WeaponDefinition` fields
// (design.md "Definition model"). `recoil_profile_id` is a REQUIRED
// reference -- `wpn::WeaponDefinition::validate()` rejects an empty one --
// exactly like `shot_profile_id`. `attachment_slots` is bounded
// (MAX_ATTACHMENT_SLOTS_PER_WEAPON) and flat: each entry is a stable slot ID
// plus the ONE attachment kind it accepts (`WeaponAttachmentSlotResource`);
// an attachment-provided slot cannot be authored here at all, matching
// `AttachmentDefinitionResource`'s own explicit-rejection-only nested-slot
// contract (design.md "Flat attachment loadout": "V1 does not permit nested
// attachment graphs").
class WeaponDefinitionResource : public Resource {
	GDCLASS(WeaponDefinitionResource, Resource)

public:
	// Mirrors `wpn::FireMode`, plus deferred values V1 explicitly rejects.
	enum FireMode {
		FIRE_MODE_SEMI_AUTO = 0,
		FIRE_MODE_AUTOMATIC = 1,
		FIRE_MODE_BURST = 2,
	};

	// Mirrors `wpn::WeaponMechanism`, plus a deferred value V1 explicitly
	// rejects.
	enum Mechanism {
		MECHANISM_HITSCAN_2D = 0,
		MECHANISM_PROJECTILE_2D = 1,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	void set_mechanism(Mechanism p_mechanism);
	Mechanism get_mechanism() const { return mechanism; }

	void set_fire_mode(FireMode p_fire_mode);
	FireMode get_fire_mode() const { return fire_mode; }

	void set_shot_profile_id(const StringName &p_shot_profile_id);
	StringName get_shot_profile_id() const { return shot_profile_id; }

	void set_shot_profile_version(int p_shot_profile_version);
	int get_shot_profile_version() const { return shot_profile_version; }

	void set_ammunition_trait(const StringName &p_ammunition_trait);
	StringName get_ammunition_trait() const { return ammunition_trait; }

	// Internal loaded-round capacity. V1 has no detachable-magazine item
	// identity; this is a plain bounded count (design.md "Instance and
	// transition model": "no separate chamber or detachable-magazine
	// identity").
	void set_capacity(int p_capacity);
	int get_capacity() const { return capacity; }

	// Positive minimum authority ticks between accepted shots.
	void set_cadence_ticks(int p_cadence_ticks);
	int get_cadence_ticks() const { return cadence_ticks; }

	// Positive authority ticks a reload takes to complete.
	void set_reload_ticks(int p_reload_ticks);
	int get_reload_ticks() const { return reload_ticks; }

	// Checked signed 64-bit world milliunits of noise radius published for
	// every committed shot, including misses.
	void set_noise_radius_milliunits(int64_t p_noise_radius_milliunits);
	int64_t get_noise_radius_milliunits() const { return noise_radius_milliunits; }

	// Full group diameter in thousandths of one MOA (weapon-authoring
	// spec.md "Unambiguous Integer MOA Authoring"): `1000` means one minute
	// of angle. Non-negative, bounded by the sealed V1 limit (60 MOA). The
	// core converts HALF this diameter to a non-negative integer nanoradian
	// angular radius as
	// `round_half_up(accuracy_moa_milli * 3_141_592_654 / 21_600_000)`; no
	// presentation crosshair or platform floating-point value participates
	// in authority.
	void set_accuracy_moa_milli(int64_t p_accuracy_moa_milli);
	int64_t get_accuracy_moa_milli() const { return accuracy_moa_milli; }

	// REQUIRED reference to a sealed `RecoilProfileResource`, exactly like
	// `shot_profile_id` -- `wpn::WeaponDefinition::validate()` rejects an
	// empty `recoil_profile_id`.
	void set_recoil_profile_id(const StringName &p_recoil_profile_id);
	StringName get_recoil_profile_id() const { return recoil_profile_id; }

	void set_recoil_profile_version(int p_recoil_profile_version);
	int get_recoil_profile_version() const { return recoil_profile_version; }

	// Bounded ordered set of stable flat attachment slots (design.md "Flat
	// attachment loadout"); at most MAX_ATTACHMENT_SLOTS_PER_WEAPON (8),
	// unique slot IDs. Order is authoring-significant (it participates in the
	// content fingerprint), not merely cosmetic.
	void set_attachment_slots(const TypedArray<WeaponAttachmentSlotResource> &p_attachment_slots);
	TypedArray<WeaponAttachmentSlotResource> get_attachment_slots() const { return attachment_slots; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int version = 1;
	Mechanism mechanism = MECHANISM_HITSCAN_2D;
	FireMode fire_mode = FIRE_MODE_SEMI_AUTO;
	StringName shot_profile_id;
	int shot_profile_version = 1;
	StringName ammunition_trait;
	int capacity = 1;
	int cadence_ticks = 1;
	int reload_ticks = 1;
	int64_t noise_radius_milliunits = 0;
	int64_t accuracy_moa_milli = 0;
	StringName recoil_profile_id;
	int recoil_profile_version = 1;
	TypedArray<WeaponAttachmentSlotResource> attachment_slots;
};

} // namespace godot

VARIANT_ENUM_CAST(WeaponDefinitionResource::FireMode);
VARIANT_ENUM_CAST(WeaponDefinitionResource::Mechanism);

#endif // WEAPON_SYSTEM_RESOURCES_WEAPON_DEFINITION_RESOURCE_H
