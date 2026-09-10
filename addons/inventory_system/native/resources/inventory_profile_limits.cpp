#include "resources/inventory_profile_limits.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryProfileLimits::set_max_items(int p_max_items) {
	max_items = p_max_items;
	emit_changed();
}

void InventoryProfileLimits::set_max_containers(int p_max_containers) {
	max_containers = p_max_containers;
	emit_changed();
}

void InventoryProfileLimits::set_max_references(int p_max_references) {
	max_references = p_max_references;
	emit_changed();
}

void InventoryProfileLimits::set_max_nesting_depth(int p_max_nesting_depth) {
	max_nesting_depth = p_max_nesting_depth;
	emit_changed();
}

void InventoryProfileLimits::set_max_mutable_components_per_item(int p_max_mutable_components_per_item) {
	max_mutable_components_per_item = p_max_mutable_components_per_item;
	emit_changed();
}

void InventoryProfileLimits::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_max_items", "max_items"), &InventoryProfileLimits::set_max_items);
	ClassDB::bind_method(D_METHOD("get_max_items"), &InventoryProfileLimits::get_max_items);
	ClassDB::bind_method(D_METHOD("set_max_containers", "max_containers"), &InventoryProfileLimits::set_max_containers);
	ClassDB::bind_method(D_METHOD("get_max_containers"), &InventoryProfileLimits::get_max_containers);
	ClassDB::bind_method(D_METHOD("set_max_references", "max_references"), &InventoryProfileLimits::set_max_references);
	ClassDB::bind_method(D_METHOD("get_max_references"), &InventoryProfileLimits::get_max_references);
	ClassDB::bind_method(D_METHOD("set_max_nesting_depth", "max_nesting_depth"), &InventoryProfileLimits::set_max_nesting_depth);
	ClassDB::bind_method(D_METHOD("get_max_nesting_depth"), &InventoryProfileLimits::get_max_nesting_depth);
	ClassDB::bind_method(D_METHOD("set_max_mutable_components_per_item", "max_mutable_components_per_item"),
			&InventoryProfileLimits::set_max_mutable_components_per_item);
	ClassDB::bind_method(D_METHOD("get_max_mutable_components_per_item"), &InventoryProfileLimits::get_max_mutable_components_per_item);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_items", PROPERTY_HINT_RANGE, "1,4096,1,or_greater"),
			"set_max_items", "get_max_items");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_containers", PROPERTY_HINT_RANGE, "1,512,1,or_greater"),
			"set_max_containers", "get_max_containers");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_references", PROPERTY_HINT_RANGE, "0,256,1,or_greater"),
			"set_max_references", "get_max_references");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_nesting_depth", PROPERTY_HINT_RANGE, "0,16,1,or_greater"),
			"set_max_nesting_depth", "get_max_nesting_depth");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_mutable_components_per_item", PROPERTY_HINT_RANGE, "0,32,1,or_greater"),
			"set_max_mutable_components_per_item", "get_max_mutable_components_per_item");
}

} // namespace godot
