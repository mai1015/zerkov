#include "resources/inventory_item_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryItemDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void InventoryItemDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void InventoryItemDefinition::set_max_stack(int64_t p_max_stack) {
	max_stack = p_max_stack;
	emit_changed();
}

void InventoryItemDefinition::set_unit_mass_mg(int64_t p_unit_mass_mg) {
	unit_mass_mg = p_unit_mass_mg;
	emit_changed();
}

void InventoryItemDefinition::set_footprint_width(int p_footprint_width) {
	footprint_width = p_footprint_width;
	emit_changed();
}

void InventoryItemDefinition::set_footprint_height(int p_footprint_height) {
	footprint_height = p_footprint_height;
	emit_changed();
}

void InventoryItemDefinition::set_allow_rotation(bool p_allow_rotation) {
	allow_rotation = p_allow_rotation;
	emit_changed();
}

void InventoryItemDefinition::set_traits(const TypedArray<InventoryItemTraitValue> &p_traits) {
	traits = p_traits;
	emit_changed();
}

void InventoryItemDefinition::set_provided_containers(const PackedStringArray &p_provided_containers) {
	provided_containers = p_provided_containers;
	emit_changed();
}

void InventoryItemDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &InventoryItemDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &InventoryItemDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &InventoryItemDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &InventoryItemDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_max_stack", "max_stack"), &InventoryItemDefinition::set_max_stack);
	ClassDB::bind_method(D_METHOD("get_max_stack"), &InventoryItemDefinition::get_max_stack);
	ClassDB::bind_method(D_METHOD("set_unit_mass_mg", "unit_mass_mg"), &InventoryItemDefinition::set_unit_mass_mg);
	ClassDB::bind_method(D_METHOD("get_unit_mass_mg"), &InventoryItemDefinition::get_unit_mass_mg);
	ClassDB::bind_method(D_METHOD("set_footprint_width", "footprint_width"), &InventoryItemDefinition::set_footprint_width);
	ClassDB::bind_method(D_METHOD("get_footprint_width"), &InventoryItemDefinition::get_footprint_width);
	ClassDB::bind_method(D_METHOD("set_footprint_height", "footprint_height"), &InventoryItemDefinition::set_footprint_height);
	ClassDB::bind_method(D_METHOD("get_footprint_height"), &InventoryItemDefinition::get_footprint_height);
	ClassDB::bind_method(D_METHOD("set_allow_rotation", "allow_rotation"), &InventoryItemDefinition::set_allow_rotation);
	ClassDB::bind_method(D_METHOD("get_allow_rotation"), &InventoryItemDefinition::get_allow_rotation);
	ClassDB::bind_method(D_METHOD("set_traits", "traits"), &InventoryItemDefinition::set_traits);
	ClassDB::bind_method(D_METHOD("get_traits"), &InventoryItemDefinition::get_traits);
	ClassDB::bind_method(D_METHOD("set_provided_containers", "provided_containers"), &InventoryItemDefinition::set_provided_containers);
	ClassDB::bind_method(D_METHOD("get_provided_containers"), &InventoryItemDefinition::get_provided_containers);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.item.rifle (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_stack", PROPERTY_HINT_RANGE, "1,1000000,1,or_greater"),
			"set_max_stack", "get_max_stack");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "unit_mass_mg", PROPERTY_HINT_RANGE, "0,1000000000,1,or_greater"),
			"set_unit_mass_mg", "get_unit_mass_mg");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "footprint_width", PROPERTY_HINT_RANGE, "1,64,1,or_greater"),
			"set_footprint_width", "get_footprint_width");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "footprint_height", PROPERTY_HINT_RANGE, "1,64,1,or_greater"),
			"set_footprint_height", "get_footprint_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_rotation"), "set_allow_rotation", "get_allow_rotation");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "traits", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryItemTraitValue", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_traits", "get_traits");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "provided_containers"),
			"set_provided_containers", "get_provided_containers");
}

} // namespace godot
