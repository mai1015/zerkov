#include "resources/inventory_container_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryContainerDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void InventoryContainerDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void InventoryContainerDefinition::set_layout_kind(LayoutKind p_layout_kind) {
	layout_kind = p_layout_kind;
	notify_property_list_changed();
	emit_changed();
}

void InventoryContainerDefinition::set_grid_width(int p_grid_width) {
	grid_width = p_grid_width;
	emit_changed();
}

void InventoryContainerDefinition::set_grid_height(int p_grid_height) {
	grid_height = p_grid_height;
	emit_changed();
}

void InventoryContainerDefinition::set_grid_allow_rotation(bool p_grid_allow_rotation) {
	grid_allow_rotation = p_grid_allow_rotation;
	emit_changed();
}

void InventoryContainerDefinition::set_named_slots(const TypedArray<InventoryNamedSlot> &p_named_slots) {
	named_slots = p_named_slots;
	emit_changed();
}

void InventoryContainerDefinition::set_ordered_list_max_entries(int p_ordered_list_max_entries) {
	ordered_list_max_entries = p_ordered_list_max_entries;
	emit_changed();
}

void InventoryContainerDefinition::set_enabled_features(const PackedStringArray &p_enabled_features) {
	enabled_features = p_enabled_features;
	emit_changed();
}

void InventoryContainerDefinition::set_constraints(const Ref<InventoryContainerConstraints> &p_constraints) {
	constraints = p_constraints;
	emit_changed();
}

void InventoryContainerDefinition::set_discovery_policy_identifier(const StringName &p_identifier) {
	discovery_policy_identifier = p_identifier;
	emit_changed();
}

void InventoryContainerDefinition::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("grid_width") || p_property.name == StringName("grid_height") ||
			p_property.name == StringName("grid_allow_rotation")) {
		if (layout_kind != LAYOUT_SPATIAL_GRID) {
			p_property.usage &= ~PROPERTY_USAGE_EDITOR;
		}
	}
	if (p_property.name == StringName("named_slots") && layout_kind != LAYOUT_NAMED_SLOTS) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (p_property.name == StringName("ordered_list_max_entries") && layout_kind != LAYOUT_ORDERED_LIST) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void InventoryContainerDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &InventoryContainerDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &InventoryContainerDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &InventoryContainerDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &InventoryContainerDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_layout_kind", "layout_kind"), &InventoryContainerDefinition::set_layout_kind);
	ClassDB::bind_method(D_METHOD("get_layout_kind"), &InventoryContainerDefinition::get_layout_kind);
	ClassDB::bind_method(D_METHOD("set_grid_width", "grid_width"), &InventoryContainerDefinition::set_grid_width);
	ClassDB::bind_method(D_METHOD("get_grid_width"), &InventoryContainerDefinition::get_grid_width);
	ClassDB::bind_method(D_METHOD("set_grid_height", "grid_height"), &InventoryContainerDefinition::set_grid_height);
	ClassDB::bind_method(D_METHOD("get_grid_height"), &InventoryContainerDefinition::get_grid_height);
	ClassDB::bind_method(D_METHOD("set_grid_allow_rotation", "grid_allow_rotation"), &InventoryContainerDefinition::set_grid_allow_rotation);
	ClassDB::bind_method(D_METHOD("get_grid_allow_rotation"), &InventoryContainerDefinition::get_grid_allow_rotation);
	ClassDB::bind_method(D_METHOD("set_named_slots", "named_slots"), &InventoryContainerDefinition::set_named_slots);
	ClassDB::bind_method(D_METHOD("get_named_slots"), &InventoryContainerDefinition::get_named_slots);
	ClassDB::bind_method(D_METHOD("set_ordered_list_max_entries", "ordered_list_max_entries"), &InventoryContainerDefinition::set_ordered_list_max_entries);
	ClassDB::bind_method(D_METHOD("get_ordered_list_max_entries"), &InventoryContainerDefinition::get_ordered_list_max_entries);
	ClassDB::bind_method(D_METHOD("set_enabled_features", "enabled_features"), &InventoryContainerDefinition::set_enabled_features);
	ClassDB::bind_method(D_METHOD("get_enabled_features"), &InventoryContainerDefinition::get_enabled_features);
	ClassDB::bind_method(D_METHOD("set_constraints", "constraints"), &InventoryContainerDefinition::set_constraints);
	ClassDB::bind_method(D_METHOD("get_constraints"), &InventoryContainerDefinition::get_constraints);
	ClassDB::bind_method(D_METHOD("set_discovery_policy_identifier", "identifier"), &InventoryContainerDefinition::set_discovery_policy_identifier);
	ClassDB::bind_method(D_METHOD("get_discovery_policy_identifier"), &InventoryContainerDefinition::get_discovery_policy_identifier);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.container.backpack_grid"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "layout_kind", PROPERTY_HINT_ENUM, "SpatialGrid,NamedSlots,OrderedList"),
			"set_layout_kind", "get_layout_kind");

	ADD_GROUP("Spatial Grid", "grid_");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "grid_width", PROPERTY_HINT_RANGE, "1,256,1,or_greater"),
			"set_grid_width", "get_grid_width");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "grid_height", PROPERTY_HINT_RANGE, "1,256,1,or_greater"),
			"set_grid_height", "get_grid_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "grid_allow_rotation"), "set_grid_allow_rotation", "get_grid_allow_rotation");

	ADD_GROUP("Named Slots", "");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "named_slots", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:InventoryNamedSlot", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_named_slots", "get_named_slots");

	ADD_GROUP("Ordered List", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "ordered_list_max_entries", PROPERTY_HINT_RANGE, "1,4096,1,or_greater"),
			"set_ordered_list_max_entries", "get_ordered_list_max_entries");

	ADD_GROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "enabled_features"), "set_enabled_features", "get_enabled_features");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "constraints", PROPERTY_HINT_RESOURCE_TYPE, "InventoryContainerConstraints"),
			"set_constraints", "get_constraints");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "discovery_policy_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.discovery.world_chest"),
			"set_discovery_policy_identifier", "get_discovery_policy_identifier");

	BIND_ENUM_CONSTANT(LAYOUT_SPATIAL_GRID);
	BIND_ENUM_CONSTANT(LAYOUT_NAMED_SLOTS);
	BIND_ENUM_CONSTANT(LAYOUT_ORDERED_LIST);
}

} // namespace godot
