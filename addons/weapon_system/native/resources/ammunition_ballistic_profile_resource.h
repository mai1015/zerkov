#ifndef WEAPON_SYSTEM_RESOURCES_AMMUNITION_BALLISTIC_PROFILE_RESOURCE_H
#define WEAPON_SYSTEM_RESOURCES_AMMUNITION_BALLISTIC_PROFILE_RESOURCE_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `wpn::AmmunitionBallisticProfile`
// (native/core/wpn_definitions.h), mirrored field for field.
// `WeaponDefinitionCatalog` (native/godot/weapon_definition_catalog.h)
// VALIDATES and COPIES this Resource's current field values into a sealed
// native `wpn::WeaponCatalog` via `register_ballistic_profile()`; later
// mutation of this Resource never affects an already sealed catalog
// (weapon-authoring spec.md "Immutable Versioned Weapon Definitions").
//
// This schema intentionally has NO penetration, armor-response, or
// projectile-ballistics field: "The Weapon System does not define, calculate,
// or modify penetration. A game may place penetration, armor damage,
// material response, and projectile ballistics on the referenced bullet
// profile" (design.md "Bullet profile and penetration ownership") -- a game
// that wants those values attaches them to ITS OWN ammunition content
// alongside (or via) this profile's identity, never as a field this addon
// owns (weapon-authoring spec.md "Ammunition Ballistic Profile Identity":
// "Weapon attempts to define penetration").
class AmmunitionBallisticProfileResource : public Resource {
	GDCLASS(AmmunitionBallisticProfileResource, Resource)

public:
	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_version(int p_version);
	int get_version() const { return version; }

	// The exact ammunition trait this profile satisfies; a weapon definition's
	// own `ammunition_trait` must match for reload/fire compatibility
	// (weapon-authoring spec.md "Ammunition Ballistic Profile Identity").
	void set_ammunition_trait(const StringName &p_ammunition_trait);
	StringName get_ammunition_trait() const { return ammunition_trait; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	int version = 1;
	StringName ammunition_trait;
};

} // namespace godot

#endif // WEAPON_SYSTEM_RESOURCES_AMMUNITION_BALLISTIC_PROFILE_RESOURCE_H
