#include "resources/weapon_definition_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void WeaponDefinitionResource::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void WeaponDefinitionResource::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void WeaponDefinitionResource::set_mechanism(Mechanism p_mechanism) {
	mechanism = p_mechanism;
	emit_changed();
}

void WeaponDefinitionResource::set_fire_mode(FireMode p_fire_mode) {
	fire_mode = p_fire_mode;
	emit_changed();
}

void WeaponDefinitionResource::set_shot_profile_id(const StringName &p_shot_profile_id) {
	shot_profile_id = p_shot_profile_id;
	emit_changed();
}

void WeaponDefinitionResource::set_shot_profile_version(int p_shot_profile_version) {
	shot_profile_version = p_shot_profile_version;
	emit_changed();
}

void WeaponDefinitionResource::set_ammunition_trait(const StringName &p_ammunition_trait) {
	ammunition_trait = p_ammunition_trait;
	emit_changed();
}

void WeaponDefinitionResource::set_capacity(int p_capacity) {
	capacity = p_capacity;
	emit_changed();
}

void WeaponDefinitionResource::set_cadence_ticks(int p_cadence_ticks) {
	cadence_ticks = p_cadence_ticks;
	emit_changed();
}

void WeaponDefinitionResource::set_reload_ticks(int p_reload_ticks) {
	reload_ticks = p_reload_ticks;
	emit_changed();
}

void WeaponDefinitionResource::set_noise_radius_milliunits(int64_t p_noise_radius_milliunits) {
	noise_radius_milliunits = p_noise_radius_milliunits;
	emit_changed();
}

void WeaponDefinitionResource::set_accuracy_moa_milli(int64_t p_accuracy_moa_milli) {
	accuracy_moa_milli = p_accuracy_moa_milli;
	emit_changed();
}

void WeaponDefinitionResource::set_recoil_profile_id(const StringName &p_recoil_profile_id) {
	recoil_profile_id = p_recoil_profile_id;
	emit_changed();
}

void WeaponDefinitionResource::set_recoil_profile_version(int p_recoil_profile_version) {
	recoil_profile_version = p_recoil_profile_version;
	emit_changed();
}

void WeaponDefinitionResource::set_attachment_slots(const TypedArray<WeaponAttachmentSlotResource> &p_attachment_slots) {
	attachment_slots = p_attachment_slots;
	emit_changed();
}

void WeaponDefinitionResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &WeaponDefinitionResource::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &WeaponDefinitionResource::get_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &WeaponDefinitionResource::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &WeaponDefinitionResource::get_version);
	ClassDB::bind_method(D_METHOD("set_mechanism", "mechanism"), &WeaponDefinitionResource::set_mechanism);
	ClassDB::bind_method(D_METHOD("get_mechanism"), &WeaponDefinitionResource::get_mechanism);
	ClassDB::bind_method(D_METHOD("set_fire_mode", "fire_mode"), &WeaponDefinitionResource::set_fire_mode);
	ClassDB::bind_method(D_METHOD("get_fire_mode"), &WeaponDefinitionResource::get_fire_mode);
	ClassDB::bind_method(D_METHOD("set_shot_profile_id", "shot_profile_id"), &WeaponDefinitionResource::set_shot_profile_id);
	ClassDB::bind_method(D_METHOD("get_shot_profile_id"), &WeaponDefinitionResource::get_shot_profile_id);
	ClassDB::bind_method(D_METHOD("set_shot_profile_version", "shot_profile_version"), &WeaponDefinitionResource::set_shot_profile_version);
	ClassDB::bind_method(D_METHOD("get_shot_profile_version"), &WeaponDefinitionResource::get_shot_profile_version);
	ClassDB::bind_method(D_METHOD("set_ammunition_trait", "ammunition_trait"), &WeaponDefinitionResource::set_ammunition_trait);
	ClassDB::bind_method(D_METHOD("get_ammunition_trait"), &WeaponDefinitionResource::get_ammunition_trait);
	ClassDB::bind_method(D_METHOD("set_capacity", "capacity"), &WeaponDefinitionResource::set_capacity);
	ClassDB::bind_method(D_METHOD("get_capacity"), &WeaponDefinitionResource::get_capacity);
	ClassDB::bind_method(D_METHOD("set_cadence_ticks", "cadence_ticks"), &WeaponDefinitionResource::set_cadence_ticks);
	ClassDB::bind_method(D_METHOD("get_cadence_ticks"), &WeaponDefinitionResource::get_cadence_ticks);
	ClassDB::bind_method(D_METHOD("set_reload_ticks", "reload_ticks"), &WeaponDefinitionResource::set_reload_ticks);
	ClassDB::bind_method(D_METHOD("get_reload_ticks"), &WeaponDefinitionResource::get_reload_ticks);
	ClassDB::bind_method(D_METHOD("set_noise_radius_milliunits", "noise_radius_milliunits"), &WeaponDefinitionResource::set_noise_radius_milliunits);
	ClassDB::bind_method(D_METHOD("get_noise_radius_milliunits"), &WeaponDefinitionResource::get_noise_radius_milliunits);
	ClassDB::bind_method(D_METHOD("set_accuracy_moa_milli", "accuracy_moa_milli"), &WeaponDefinitionResource::set_accuracy_moa_milli);
	ClassDB::bind_method(D_METHOD("get_accuracy_moa_milli"), &WeaponDefinitionResource::get_accuracy_moa_milli);
	ClassDB::bind_method(D_METHOD("set_recoil_profile_id", "recoil_profile_id"), &WeaponDefinitionResource::set_recoil_profile_id);
	ClassDB::bind_method(D_METHOD("get_recoil_profile_id"), &WeaponDefinitionResource::get_recoil_profile_id);
	ClassDB::bind_method(D_METHOD("set_recoil_profile_version", "recoil_profile_version"), &WeaponDefinitionResource::set_recoil_profile_version);
	ClassDB::bind_method(D_METHOD("get_recoil_profile_version"), &WeaponDefinitionResource::get_recoil_profile_version);
	ClassDB::bind_method(D_METHOD("set_attachment_slots", "attachment_slots"), &WeaponDefinitionResource::set_attachment_slots);
	ClassDB::bind_method(D_METHOD("get_attachment_slots"), &WeaponDefinitionResource::get_attachment_slots);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.weapon.pistol_m9 (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_version", "get_version");
	// Every named value is shown so an author can see the deferred V1
	// vocabulary, but WeaponDefinitionCatalog::register_weapon() rejects
	// anything other than Hitscan2D with a diagnostic naming this field and
	// the requested value (see this class's header comment).
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mechanism", PROPERTY_HINT_ENUM, "Hitscan2D,Projectile2D"),
			"set_mechanism", "get_mechanism");
	// Same deferred-vocabulary/explicit-rejection contract as `mechanism`.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "fire_mode", PROPERTY_HINT_ENUM, "SemiAuto,Automatic,Burst"),
			"set_fire_mode", "get_fire_mode");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "shot_profile_id", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.shot_profile.rifle_9mm"),
			"set_shot_profile_id", "get_shot_profile_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shot_profile_version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_shot_profile_version", "get_shot_profile_version");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "ammunition_trait", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.ammo_trait.9mm"),
			"set_ammunition_trait", "get_ammunition_trait");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "capacity", PROPERTY_HINT_RANGE, "1,1000000,1,or_greater"),
			"set_capacity", "get_capacity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cadence_ticks", PROPERTY_HINT_RANGE, "1,3600000,1,or_greater"),
			"set_cadence_ticks", "get_cadence_ticks");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "reload_ticks", PROPERTY_HINT_RANGE, "1,3600000,1,or_greater"),
			"set_reload_ticks", "get_reload_ticks");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "noise_radius_milliunits", PROPERTY_HINT_RANGE, "0,1000000000,1,or_greater"),
			"set_noise_radius_milliunits", "get_noise_radius_milliunits");
	// "1000" = one minute of angle, full group diameter (weapon-authoring
	// spec.md "Unambiguous Integer MOA Authoring"); see this class's header
	// comment for the exact conversion the core performs.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "accuracy_moa_milli", PROPERTY_HINT_RANGE, "0,60000,1,or_greater"),
			"set_accuracy_moa_milli", "get_accuracy_moa_milli");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "recoil_profile_id", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.recoil_profile.rifle_9mm"),
			"set_recoil_profile_id", "get_recoil_profile_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "recoil_profile_version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_recoil_profile_version", "get_recoil_profile_version");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "attachment_slots", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:WeaponAttachmentSlotResource", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_attachment_slots", "get_attachment_slots");

	BIND_ENUM_CONSTANT(FIRE_MODE_SEMI_AUTO);
	BIND_ENUM_CONSTANT(FIRE_MODE_AUTOMATIC);
	BIND_ENUM_CONSTANT(FIRE_MODE_BURST);
	BIND_ENUM_CONSTANT(MECHANISM_HITSCAN_2D);
	BIND_ENUM_CONSTANT(MECHANISM_PROJECTILE_2D);
}

} // namespace godot
