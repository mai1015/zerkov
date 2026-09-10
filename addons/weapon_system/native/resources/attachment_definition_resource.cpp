#include "resources/attachment_definition_resource.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void AttachmentDefinitionResource::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void AttachmentDefinitionResource::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void AttachmentDefinitionResource::set_compatible_slot_kinds_mask(int p_mask) {
	compatible_slot_kinds_mask = p_mask;
	emit_changed();
}

void AttachmentDefinitionResource::set_compatible_tags(const PackedStringArray &p_tags) {
	compatible_tags = p_tags;
	emit_changed();
}

void AttachmentDefinitionResource::set_accuracy_modifier_ppm(int64_t p_accuracy_modifier_ppm) {
	accuracy_modifier_ppm = p_accuracy_modifier_ppm;
	emit_changed();
}

void AttachmentDefinitionResource::set_recoil_modifier_ppm(int64_t p_recoil_modifier_ppm) {
	recoil_modifier_ppm = p_recoil_modifier_ppm;
	emit_changed();
}

void AttachmentDefinitionResource::set_noise_modifier_ppm(int64_t p_noise_modifier_ppm) {
	noise_modifier_ppm = p_noise_modifier_ppm;
	emit_changed();
}

void AttachmentDefinitionResource::set_reload_duration_modifier_ppm(int64_t p_reload_duration_modifier_ppm) {
	reload_duration_modifier_ppm = p_reload_duration_modifier_ppm;
	emit_changed();
}

void AttachmentDefinitionResource::set_cadence_modifier_ppm(int64_t p_cadence_modifier_ppm) {
	cadence_modifier_ppm = p_cadence_modifier_ppm;
	emit_changed();
}

void AttachmentDefinitionResource::set_provided_slot_count(int p_provided_slot_count) {
	provided_slot_count = p_provided_slot_count;
	emit_changed();
}

void AttachmentDefinitionResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &AttachmentDefinitionResource::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &AttachmentDefinitionResource::get_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &AttachmentDefinitionResource::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &AttachmentDefinitionResource::get_version);
	ClassDB::bind_method(D_METHOD("set_compatible_slot_kinds_mask", "mask"), &AttachmentDefinitionResource::set_compatible_slot_kinds_mask);
	ClassDB::bind_method(D_METHOD("get_compatible_slot_kinds_mask"), &AttachmentDefinitionResource::get_compatible_slot_kinds_mask);
	ClassDB::bind_method(D_METHOD("set_compatible_tags", "tags"), &AttachmentDefinitionResource::set_compatible_tags);
	ClassDB::bind_method(D_METHOD("get_compatible_tags"), &AttachmentDefinitionResource::get_compatible_tags);
	ClassDB::bind_method(D_METHOD("set_accuracy_modifier_ppm", "accuracy_modifier_ppm"), &AttachmentDefinitionResource::set_accuracy_modifier_ppm);
	ClassDB::bind_method(D_METHOD("get_accuracy_modifier_ppm"), &AttachmentDefinitionResource::get_accuracy_modifier_ppm);
	ClassDB::bind_method(D_METHOD("set_recoil_modifier_ppm", "recoil_modifier_ppm"), &AttachmentDefinitionResource::set_recoil_modifier_ppm);
	ClassDB::bind_method(D_METHOD("get_recoil_modifier_ppm"), &AttachmentDefinitionResource::get_recoil_modifier_ppm);
	ClassDB::bind_method(D_METHOD("set_noise_modifier_ppm", "noise_modifier_ppm"), &AttachmentDefinitionResource::set_noise_modifier_ppm);
	ClassDB::bind_method(D_METHOD("get_noise_modifier_ppm"), &AttachmentDefinitionResource::get_noise_modifier_ppm);
	ClassDB::bind_method(D_METHOD("set_reload_duration_modifier_ppm", "reload_duration_modifier_ppm"), &AttachmentDefinitionResource::set_reload_duration_modifier_ppm);
	ClassDB::bind_method(D_METHOD("get_reload_duration_modifier_ppm"), &AttachmentDefinitionResource::get_reload_duration_modifier_ppm);
	ClassDB::bind_method(D_METHOD("set_cadence_modifier_ppm", "cadence_modifier_ppm"), &AttachmentDefinitionResource::set_cadence_modifier_ppm);
	ClassDB::bind_method(D_METHOD("get_cadence_modifier_ppm"), &AttachmentDefinitionResource::get_cadence_modifier_ppm);
	ClassDB::bind_method(D_METHOD("set_provided_slot_count", "provided_slot_count"), &AttachmentDefinitionResource::set_provided_slot_count);
	ClassDB::bind_method(D_METHOD("get_provided_slot_count"), &AttachmentDefinitionResource::get_provided_slot_count);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.attachment.acog_scope (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version", PROPERTY_HINT_RANGE, "1,65535,1,or_greater"),
			"set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "compatible_slot_kinds_mask", PROPERTY_HINT_FLAGS, "Optic,Muzzle,Stock,Grip"),
			"set_compatible_slot_kinds_mask", "get_compatible_slot_kinds_mask");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "compatible_tags"),
			"set_compatible_tags", "get_compatible_tags");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "accuracy_modifier_ppm", PROPERTY_HINT_RANGE, "-500000,500000,1"),
			"set_accuracy_modifier_ppm", "get_accuracy_modifier_ppm");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "recoil_modifier_ppm", PROPERTY_HINT_RANGE, "-500000,500000,1"),
			"set_recoil_modifier_ppm", "get_recoil_modifier_ppm");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "noise_modifier_ppm", PROPERTY_HINT_RANGE, "-500000,500000,1"),
			"set_noise_modifier_ppm", "get_noise_modifier_ppm");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "reload_duration_modifier_ppm", PROPERTY_HINT_RANGE, "-500000,500000,1"),
			"set_reload_duration_modifier_ppm", "get_reload_duration_modifier_ppm");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cadence_modifier_ppm", PROPERTY_HINT_RANGE, "-500000,500000,1"),
			"set_cadence_modifier_ppm", "get_cadence_modifier_ppm");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "provided_slot_count", PROPERTY_HINT_RANGE, "0,8,1,or_greater"),
			"set_provided_slot_count", "get_provided_slot_count");

	BIND_BITFIELD_FLAG(SLOT_KIND_BIT_OPTIC);
	BIND_BITFIELD_FLAG(SLOT_KIND_BIT_MUZZLE);
	BIND_BITFIELD_FLAG(SLOT_KIND_BIT_STOCK);
	BIND_BITFIELD_FLAG(SLOT_KIND_BIT_GRIP);
}

} // namespace godot
