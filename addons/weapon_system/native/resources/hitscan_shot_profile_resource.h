#ifndef WEAPON_SYSTEM_RESOURCES_HITSCAN_SHOT_PROFILE_RESOURCE_H
#define WEAPON_SYSTEM_RESOURCES_HITSCAN_SHOT_PROFILE_RESOURCE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `wpn::HitscanShotProfile` (native/core/
// wpn_definitions.h), mirrored field for field. `WeaponDefinitionCatalog`
// (native/godot/weapon_definition_catalog.h) VALIDATES and COPIES this
// Resource's current field values into a sealed native `wpn::WeaponCatalog`;
// later mutation of this Resource never affects an already sealed catalog
// (weapon-authoring spec.md "Immutable Versioned Weapon Definitions").
//
// V1 is a small, fixed hitscan shot schema (design.md "Definition model"):
// this class deliberately has no penetration, projectile-travel, or
// armor-response field. Bullet/penetration data belongs to a future
// `AmmunitionBallisticProfile` definition kind owned by ammunition content,
// never to a weapon or shot profile (weapon-authoring spec.md "Ammunition
// Ballistic Profile Identity": "Weapon attempts to define penetration").
class HitscanShotProfileResource : public Resource {
	GDCLASS(HitscanShotProfileResource, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	// Checked signed 64-bit "milliunits" of damage; the canonical fixed-point
	// damage unit `wpn::HitscanShotProfile::damage_milliunits` uses. Never a
	// float.
	void set_damage_milliunits(int64_t p_damage_milliunits);
	int64_t get_damage_milliunits() const { return damage_milliunits; }

	// Maximum hit range in checked signed 64-bit world milliunits.
	void set_range_milliunits(int64_t p_range_milliunits);
	int64_t get_range_milliunits() const { return range_milliunits; }

	// Deterministic shot-sampling half-angle in signed 64-bit microradians
	// (this addon's CURRENT "spread/accuracy authoring" surface -- the
	// integer-`accuracy_moa_milli` nanoradian contract design.md describes is
	// a later core numeric-contract task and is not yet part of the sealed
	// `wpn::HitscanShotProfile` schema this Resource mirrors).
	void set_spread_microradians(int64_t p_spread_microradians);
	int64_t get_spread_microradians() const { return spread_microradians; }

	// Maximum accepted deviation between claimed and authoritative aim, in
	// signed 64-bit microradians.
	void set_aim_tolerance_microradians(int64_t p_aim_tolerance_microradians);
	int64_t get_aim_tolerance_microradians() const { return aim_tolerance_microradians; }

	// Maximum accepted deviation between claimed and authoritative origin, in
	// signed 64-bit world milliunits.
	void set_origin_tolerance_milliunits(int64_t p_origin_tolerance_milliunits);
	int64_t get_origin_tolerance_milliunits() const { return origin_tolerance_milliunits; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int version = 1;
	int64_t damage_milliunits = 0;
	int64_t range_milliunits = 0;
	int64_t spread_microradians = 0;
	int64_t aim_tolerance_microradians = 0;
	int64_t origin_tolerance_milliunits = 0;
};

} // namespace godot

#endif // WEAPON_SYSTEM_RESOURCES_HITSCAN_SHOT_PROFILE_RESOURCE_H
