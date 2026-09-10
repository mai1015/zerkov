#include "resources/inventory_profile_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryProfileDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void InventoryProfileDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void InventoryProfileDefinition::set_root_containers(const PackedStringArray &p_root_containers) {
	root_containers = p_root_containers;
	emit_changed();
}

void InventoryProfileDefinition::set_enabled_features(const PackedStringArray &p_enabled_features) {
	enabled_features = p_enabled_features;
	emit_changed();
}

void InventoryProfileDefinition::set_limits(const Ref<InventoryProfileLimits> &p_limits) {
	limits = p_limits;
	emit_changed();
}

void InventoryProfileDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &InventoryProfileDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &InventoryProfileDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &InventoryProfileDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &InventoryProfileDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_root_containers", "root_containers"), &InventoryProfileDefinition::set_root_containers);
	ClassDB::bind_method(D_METHOD("get_root_containers"), &InventoryProfileDefinition::get_root_containers);
	ClassDB::bind_method(D_METHOD("set_enabled_features", "enabled_features"), &InventoryProfileDefinition::set_enabled_features);
	ClassDB::bind_method(D_METHOD("get_enabled_features"), &InventoryProfileDefinition::get_enabled_features);
	ClassDB::bind_method(D_METHOD("set_limits", "limits"), &InventoryProfileDefinition::set_limits);
	ClassDB::bind_method(D_METHOD("get_limits"), &InventoryProfileDefinition::get_limits);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.profile.extraction_character"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "root_containers"), "set_root_containers", "get_root_containers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "enabled_features"), "set_enabled_features", "get_enabled_features");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "limits", PROPERTY_HINT_RESOURCE_TYPE, "InventoryProfileLimits"),
			"set_limits", "get_limits");
}

} // namespace godot
