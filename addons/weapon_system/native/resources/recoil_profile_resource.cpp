#include "resources/recoil_profile_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void RecoilProfileResource::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void RecoilProfileResource::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void RecoilProfileResource::set_vertical_kick_nrad(int64_t p_vertical_kick_nrad) {
	vertical_kick_nrad = p_vertical_kick_nrad;
	emit_changed();
}

void RecoilProfileResource::set_horizontal_kick_min_nrad(int64_t p_horizontal_kick_min_nrad) {
	horizontal_kick_min_nrad = p_horizontal_kick_min_nrad;
	emit_changed();
}

void RecoilProfileResource::set_horizontal_kick_max_nrad(int64_t p_horizontal_kick_max_nrad) {
	horizontal_kick_max_nrad = p_horizontal_kick_max_nrad;
	emit_changed();
}

void RecoilProfileResource::set_recovery_per_tick_nrad(int64_t p_recovery_per_tick_nrad) {
	recovery_per_tick_nrad = p_recovery_per_tick_nrad;
	emit_changed();
}

void RecoilProfileResource::set_max_vertical_offset_nrad(int64_t p_max_vertical_offset_nrad) {
	max_vertical_offset_nrad = p_max_vertical_offset_nrad;
	emit_changed();
}

void RecoilProfileResource::set_max_horizontal_offset_nrad(int64_t p_max_horizontal_offset_nrad) {
	max_horizontal_offset_nrad = p_max_horizontal_offset_nrad;
	emit_changed();
}

void RecoilProfileResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &RecoilProfileResource::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &RecoilProfileResource::get_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &RecoilProfileResource::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &RecoilProfileResource::get_version);
	ClassDB::bind_method(D_METHOD("set_vertical_kick_nrad", "vertical_kick_nrad"), &RecoilProfileResource::set_vertical_kick_nrad);
	ClassDB::bind_method(D_METHOD("get_vertical_kick_nrad"), &RecoilProfileResource::get_vertical_kick_nrad);
	ClassDB::bind_method(D_METHOD("set_horizontal_kick_min_nrad", "horizontal_kick_min_nrad"), &RecoilProfileResource::set_horizontal_kick_min_nrad);
	ClassDB::bind_method(D_METHOD("get_horizontal_kick_min_nrad"), &RecoilProfileResource::get_horizontal_kick_min_nrad);
	ClassDB::bind_method(D_METHOD("set_horizontal_kick_max_nrad", "horizontal_kick_max_nrad"), &RecoilProfileResource::set_horizontal_kick_max_nrad);
	ClassDB::bind_method(D_METHOD("get_horizontal_kick_max_nrad"), &RecoilProfileResource::get_horizontal_kick_max_nrad);
	ClassDB::bind_method(D_METHOD("set_recovery_per_tick_nrad", "recovery_per_tick_nrad"), &RecoilProfileResource::set_recovery_per_tick_nrad);
	ClassDB::bind_method(D_METHOD("get_recovery_per_tick_nrad"), &RecoilProfileResource::get_recovery_per_tick_nrad);
	ClassDB::bind_method(D_METHOD("set_max_vertical_offset_nrad", "max_vertical_offset_nrad"), &RecoilProfileResource::set_max_vertical_offset_nrad);
	ClassDB::bind_method(D_METHOD("get_max_vertical_offset_nrad"), &RecoilProfileResource::get_max_vertical_offset_nrad);
	ClassDB::bind_method(D_METHOD("set_max_horizontal_offset_nrad", "max_horizontal_offset_nrad"), &RecoilProfileResource::set_max_horizontal_offset_nrad);
	ClassDB::bind_method(D_METHOD("get_max_horizontal_offset_nrad"), &RecoilProfileResource::get_max_horizontal_offset_nrad);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.recoil_profile.rifle_9mm (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "vertical_kick_nrad", PROPERTY_HINT_RANGE, "0,50000000,1,or_greater"),
			"set_vertical_kick_nrad", "get_vertical_kick_nrad");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "horizontal_kick_min_nrad", PROPERTY_HINT_RANGE, "-50000000,50000000,1,or_greater,or_less"),
			"set_horizontal_kick_min_nrad", "get_horizontal_kick_min_nrad");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "horizontal_kick_max_nrad", PROPERTY_HINT_RANGE, "-50000000,50000000,1,or_greater,or_less"),
			"set_horizontal_kick_max_nrad", "get_horizontal_kick_max_nrad");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "recovery_per_tick_nrad", PROPERTY_HINT_RANGE, "1,200000000,1,or_greater"),
			"set_recovery_per_tick_nrad", "get_recovery_per_tick_nrad");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_vertical_offset_nrad", PROPERTY_HINT_RANGE, "0,200000000,1,or_greater"),
			"set_max_vertical_offset_nrad", "get_max_vertical_offset_nrad");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_horizontal_offset_nrad", PROPERTY_HINT_RANGE, "0,200000000,1,or_greater"),
			"set_max_horizontal_offset_nrad", "get_max_horizontal_offset_nrad");
}

} // namespace godot
