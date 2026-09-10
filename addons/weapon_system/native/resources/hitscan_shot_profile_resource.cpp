#include "resources/hitscan_shot_profile_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void HitscanShotProfileResource::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void HitscanShotProfileResource::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void HitscanShotProfileResource::set_damage_milliunits(int64_t p_damage_milliunits) {
	damage_milliunits = p_damage_milliunits;
	emit_changed();
}

void HitscanShotProfileResource::set_range_milliunits(int64_t p_range_milliunits) {
	range_milliunits = p_range_milliunits;
	emit_changed();
}

void HitscanShotProfileResource::set_spread_microradians(int64_t p_spread_microradians) {
	spread_microradians = p_spread_microradians;
	emit_changed();
}

void HitscanShotProfileResource::set_aim_tolerance_microradians(int64_t p_aim_tolerance_microradians) {
	aim_tolerance_microradians = p_aim_tolerance_microradians;
	emit_changed();
}

void HitscanShotProfileResource::set_origin_tolerance_milliunits(int64_t p_origin_tolerance_milliunits) {
	origin_tolerance_milliunits = p_origin_tolerance_milliunits;
	emit_changed();
}

void HitscanShotProfileResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &HitscanShotProfileResource::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &HitscanShotProfileResource::get_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &HitscanShotProfileResource::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &HitscanShotProfileResource::get_version);
	ClassDB::bind_method(D_METHOD("set_damage_milliunits", "damage_milliunits"), &HitscanShotProfileResource::set_damage_milliunits);
	ClassDB::bind_method(D_METHOD("get_damage_milliunits"), &HitscanShotProfileResource::get_damage_milliunits);
	ClassDB::bind_method(D_METHOD("set_range_milliunits", "range_milliunits"), &HitscanShotProfileResource::set_range_milliunits);
	ClassDB::bind_method(D_METHOD("get_range_milliunits"), &HitscanShotProfileResource::get_range_milliunits);
	ClassDB::bind_method(D_METHOD("set_spread_microradians", "spread_microradians"), &HitscanShotProfileResource::set_spread_microradians);
	ClassDB::bind_method(D_METHOD("get_spread_microradians"), &HitscanShotProfileResource::get_spread_microradians);
	ClassDB::bind_method(D_METHOD("set_aim_tolerance_microradians", "aim_tolerance_microradians"), &HitscanShotProfileResource::set_aim_tolerance_microradians);
	ClassDB::bind_method(D_METHOD("get_aim_tolerance_microradians"), &HitscanShotProfileResource::get_aim_tolerance_microradians);
	ClassDB::bind_method(D_METHOD("set_origin_tolerance_milliunits", "origin_tolerance_milliunits"), &HitscanShotProfileResource::set_origin_tolerance_milliunits);
	ClassDB::bind_method(D_METHOD("get_origin_tolerance_milliunits"), &HitscanShotProfileResource::get_origin_tolerance_milliunits);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.shot_profile.rifle_9mm (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "damage_milliunits", PROPERTY_HINT_RANGE, "1,1000000000,1,or_greater"),
			"set_damage_milliunits", "get_damage_milliunits");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "range_milliunits", PROPERTY_HINT_RANGE, "1,1000000000,1,or_greater"),
			"set_range_milliunits", "get_range_milliunits");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "spread_microradians", PROPERTY_HINT_RANGE, "0,3141593,1,or_greater"),
			"set_spread_microradians", "get_spread_microradians");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "aim_tolerance_microradians", PROPERTY_HINT_RANGE, "0,3141593,1,or_greater"),
			"set_aim_tolerance_microradians", "get_aim_tolerance_microradians");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "origin_tolerance_milliunits", PROPERTY_HINT_RANGE, "0,1000000000,1,or_greater"),
			"set_origin_tolerance_milliunits", "get_origin_tolerance_milliunits");
}

} // namespace godot
