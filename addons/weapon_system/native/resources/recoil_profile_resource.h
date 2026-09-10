#ifndef WEAPON_SYSTEM_RESOURCES_RECOIL_PROFILE_RESOURCE_H
#define WEAPON_SYSTEM_RESOURCES_RECOIL_PROFILE_RESOURCE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `wpn::RecoilProfile` (native/core/
// wpn_definitions.h), mirrored field for field. `WeaponDefinitionCatalog`
// (native/godot/weapon_definition_catalog.h) VALIDATES and COPIES this
// Resource's current field values into a sealed native `wpn::WeaponCatalog`
// via `register_recoil_profile()`; later mutation of this Resource never
// affects an already sealed catalog (weapon-authoring spec.md "Immutable
// Versioned Weapon Definitions").
//
// V1 recoil is deterministic and tick-based (design.md "Definition model" /
// "Accuracy and recoil"): vertical kick is non-negative, horizontal kick is a
// bounded signed range, recovery is a single positive per-tick slope, and the
// accumulated offsets are bounded. This schema deliberately has no field for
// a variable/authored recovery CURVE -- recovery is always linear toward zero
// at `recovery_per_tick_nrad` (design.md "Canonical Modifier Algebra":
// "Recoil modifiers affect new kick magnitude only in V1; recovery slope is
// fixed by the sealed recoil profile").
class RecoilProfileResource : public Resource {
	GDCLASS(RecoilProfileResource, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	// Non-negative per-shot vertical kick, in signed 64-bit nanoradians.
	void set_vertical_kick_nrad(int64_t p_vertical_kick_nrad);
	int64_t get_vertical_kick_nrad() const { return vertical_kick_nrad; }

	// Bounded signed per-shot horizontal kick range, in nanoradians;
	// `horizontal_kick_min_nrad` MUST NOT exceed `horizontal_kick_max_nrad`.
	void set_horizontal_kick_min_nrad(int64_t p_horizontal_kick_min_nrad);
	int64_t get_horizontal_kick_min_nrad() const { return horizontal_kick_min_nrad; }

	void set_horizontal_kick_max_nrad(int64_t p_horizontal_kick_max_nrad);
	int64_t get_horizontal_kick_max_nrad() const { return horizontal_kick_max_nrad; }

	// Positive per-authority-tick recovery slope, in nanoradians.
	void set_recovery_per_tick_nrad(int64_t p_recovery_per_tick_nrad);
	int64_t get_recovery_per_tick_nrad() const { return recovery_per_tick_nrad; }

	// Maximum accumulated vertical offset; MUST be at least
	// `vertical_kick_nrad` (a single kick must always fit).
	void set_max_vertical_offset_nrad(int64_t p_max_vertical_offset_nrad);
	int64_t get_max_vertical_offset_nrad() const { return max_vertical_offset_nrad; }

	// Maximum accumulated horizontal offset; MUST be at least the largest
	// magnitude of `horizontal_kick_min_nrad`/`horizontal_kick_max_nrad`.
	void set_max_horizontal_offset_nrad(int64_t p_max_horizontal_offset_nrad);
	int64_t get_max_horizontal_offset_nrad() const { return max_horizontal_offset_nrad; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int version = 1;
	int64_t vertical_kick_nrad = 0;
	int64_t horizontal_kick_min_nrad = 0;
	int64_t horizontal_kick_max_nrad = 0;
	int64_t recovery_per_tick_nrad = 1;
	int64_t max_vertical_offset_nrad = 0;
	int64_t max_horizontal_offset_nrad = 0;
};

} // namespace godot

#endif // WEAPON_SYSTEM_RESOURCES_RECOIL_PROFILE_RESOURCE_H
