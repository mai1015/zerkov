#include "resources/ammunition_ballistic_profile_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void AmmunitionBallisticProfileResource::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void AmmunitionBallisticProfileResource::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void AmmunitionBallisticProfileResource::set_ammunition_trait(const StringName &p_ammunition_trait) {
	ammunition_trait = p_ammunition_trait;
	emit_changed();
}

void AmmunitionBallisticProfileResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &AmmunitionBallisticProfileResource::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &AmmunitionBallisticProfileResource::get_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &AmmunitionBallisticProfileResource::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &AmmunitionBallisticProfileResource::get_version);
	ClassDB::bind_method(D_METHOD("set_ammunition_trait", "ammunition_trait"), &AmmunitionBallisticProfileResource::set_ammunition_trait);
	ClassDB::bind_method(D_METHOD("get_ammunition_trait"), &AmmunitionBallisticProfileResource::get_ammunition_trait);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.ballistic_profile.9mm_fmj (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "ammunition_trait", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.ammo_trait.9mm"),
			"set_ammunition_trait", "get_ammunition_trait");
}

} // namespace godot
