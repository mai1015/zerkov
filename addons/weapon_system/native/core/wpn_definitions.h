#ifndef WEAPON_SYSTEM_CORE_DEFINITIONS_H
#define WEAPON_SYSTEM_CORE_DEFINITIONS_H

#include "core/wpn_status.h"

#include <cstdint>
#include <string>
#include <vector>

namespace wpn {

enum class WeaponMechanism : std::uint8_t {
	HITSCAN_2D = 1,
};

enum class FireMode : std::uint8_t {
	SEMI_AUTO = 1,
};

// NOTE: `spread_microradians` predates the sealed integer milli-MOA/nanoradian
// numeric contract (weapon-authoring: "Unambiguous Integer MOA Authoring").
// It is retained only because `native/godot/weapon_authority.cpp` already
// reads/writes it and that façade is outside this task's scope; it is no
// longer consulted by the fire-path dispersion calculation, which now
// derives its angular radius from `WeaponDefinition::accuracy_moa_milli`
// (see `core/wpn_numerics.h`). A later façade-owning task should retire this
// field once the Resource/Dictionary surface is updated to author MOA
// instead.
struct HitscanShotProfile {
	std::string id;
	std::uint16_t version = 1;
	std::int64_t damage_milliunits = 0;
	std::int64_t range_milliunits = 0;
	std::int64_t spread_microradians = 0;
	std::int64_t aim_tolerance_microradians = 0;
	std::int64_t origin_tolerance_milliunits = 0;

	Status validate() const;
	std::uint64_t fingerprint() const;
};

// Stable ID/version, non-negative vertical kick, a bounded signed horizontal
// kick range, a tick-based recovery slope, and maximum accumulated offsets,
// all in integer nanoradians (weapon-authoring: "Versioned Recoil and Flat
// Attachment Definitions"). Recoil recovery/kick runtime consumption is task
// 4.10; this is authoring/catalog data only.
struct RecoilProfile {
	std::string id;
	std::uint16_t version = 1;
	std::int64_t vertical_kick_nrad = 0;
	std::int64_t horizontal_kick_min_nrad = 0;
	std::int64_t horizontal_kick_max_nrad = 0;
	std::int64_t recovery_per_tick_nrad = 0;
	std::int64_t max_vertical_offset_nrad = 0;
	std::int64_t max_horizontal_offset_nrad = 0;

	Status validate() const;
	std::uint64_t fingerprint() const;
};

// Closed V1 set of flat attachment slot kinds (design.md, "Flat attachment
// loadout": "such as `optic`, `muzzle`, `stock`, or `grip`"). Represented as
// bit flags so `AttachmentDefinition::compatible_slot_kinds_mask` can declare
// several compatible kinds order-independently.
enum class AttachmentSlotKind : std::uint32_t {
	OPTIC = 1u << 0,
	MUZZLE = 1u << 1,
	STOCK = 1u << 2,
	GRIP = 1u << 3,
};

constexpr std::uint32_t ALL_ATTACHMENT_SLOT_KINDS =
		static_cast<std::uint32_t>(AttachmentSlotKind::OPTIC) |
		static_cast<std::uint32_t>(AttachmentSlotKind::MUZZLE) |
		static_cast<std::uint32_t>(AttachmentSlotKind::STOCK) |
		static_cast<std::uint32_t>(AttachmentSlotKind::GRIP);

// Stable ID/version, compatible slot kinds/tags, and bounded signed
// parts-per-million modifiers for accuracy, recoil kick, noise, reload
// duration, and cadence (weapon-authoring: "Versioned Recoil and Flat
// Attachment Definitions"). Deliberately carries no ammunition identity,
// capacity, damage, penetration, or recovery-slope field, and
// `provided_slot_count` exists only so V1 can explicitly reject an attempt to
// author a nested attachment graph rather than silently ignoring it.
struct AttachmentDefinition {
	std::string id;
	std::uint16_t version = 1;
	std::uint32_t compatible_slot_kinds_mask = 0;
	std::vector<std::string> compatible_tags;
	std::int64_t accuracy_modifier_ppm = 0;
	std::int64_t recoil_modifier_ppm = 0;
	std::int64_t noise_modifier_ppm = 0;
	std::int64_t reload_duration_modifier_ppm = 0;
	std::int64_t cadence_modifier_ppm = 0;
	std::uint32_t provided_slot_count = 0; // MUST be 0 in V1; nested graphs are unsupported.

	Status validate() const;
	std::uint64_t fingerprint() const;
};

// Stable ID/version plus the exact ammunition trait this profile satisfies
// (weapon-authoring: "Ammunition Ballistic Profile Identity"). Penetration
// and armor-response values are owned by game ammunition content and are
// deliberately absent from this weapon-owned type (design.md, "Bullet
// profile and penetration ownership").
struct AmmunitionBallisticProfile {
	std::string id;
	std::uint16_t version = 1;
	std::string ammunition_trait;

	Status validate() const;
	std::uint64_t fingerprint() const;
};

// One stable, ordered flat attachment slot declared by a weapon definition:
// a stable slot ID plus the single kind of attachment it accepts.
struct WeaponAttachmentSlot {
	std::string slot_id;
	AttachmentSlotKind slot_kind = AttachmentSlotKind::OPTIC;

	bool operator==(const WeaponAttachmentSlot &p_other) const {
		return slot_id == p_other.slot_id && slot_kind == p_other.slot_kind;
	}
};

struct WeaponDefinition {
	std::string id;
	std::uint16_t version = 1;
	WeaponMechanism mechanism = WeaponMechanism::HITSCAN_2D;
	FireMode fire_mode = FireMode::SEMI_AUTO;
	std::string shot_profile_id;
	std::uint16_t shot_profile_version = 1;
	std::string ammunition_trait;
	std::uint32_t capacity = 0;
	std::uint32_t cadence_ticks = 0;
	std::uint32_t reload_ticks = 0;
	std::int64_t noise_radius_milliunits = 0;
	// Full group diameter in thousandths of one MOA (weapon-authoring:
	// "Unambiguous Integer MOA Authoring"); non-negative, bounded by
	// MAX_ACCURACY_MOA_MILLI. Converted to a non-negative integer nanoradian
	// angular radius by `convert_accuracy_moa_milli_to_angular_radius_nrad`.
	std::int64_t accuracy_moa_milli = 0;
	std::string recoil_profile_id;
	std::uint16_t recoil_profile_version = 1;
	std::vector<WeaponAttachmentSlot> attachment_slots;

	Status validate() const;
	std::uint64_t fingerprint() const;
};

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_DEFINITIONS_H
