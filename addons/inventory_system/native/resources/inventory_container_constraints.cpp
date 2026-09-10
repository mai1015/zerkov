#include "resources/inventory_container_constraints.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryContainerConstraints::set_max_items(int p_max_items) {
	max_items = p_max_items;
	emit_changed();
}

void InventoryContainerConstraints::set_has_mass_capacity(bool p_has_mass_capacity) {
	has_mass_capacity = p_has_mass_capacity;
	emit_changed();
}

void InventoryContainerConstraints::set_mass_capacity_mg(int64_t p_mass_capacity_mg) {
	mass_capacity_mg = p_mass_capacity_mg;
	emit_changed();
}

void InventoryContainerConstraints::set_required_traits(const PackedStringArray &p_required_traits) {
	required_traits = p_required_traits;
	emit_changed();
}

void InventoryContainerConstraints::set_blocked_traits(const PackedStringArray &p_blocked_traits) {
	blocked_traits = p_blocked_traits;
	emit_changed();
}

void InventoryContainerConstraints::set_allow_nesting(bool p_allow_nesting) {
	allow_nesting = p_allow_nesting;
	emit_changed();
}

void InventoryContainerConstraints::set_max_nesting_depth(int p_max_nesting_depth) {
	max_nesting_depth = p_max_nesting_depth;
	emit_changed();
}

void InventoryContainerConstraints::set_access_mask(int p_access_mask) {
	access_mask = p_access_mask;
	emit_changed();
}

void InventoryContainerConstraints::set_retention(Retention p_retention) {
	retention = p_retention;
	emit_changed();
}

void InventoryContainerConstraints::set_allow_stack_split(bool p_allow_stack_split) {
	allow_stack_split = p_allow_stack_split;
	emit_changed();
}

void InventoryContainerConstraints::set_allow_auto_placement(bool p_allow_auto_placement) {
	allow_auto_placement = p_allow_auto_placement;
	emit_changed();
}

void InventoryContainerConstraints::set_allow_quick_transfer(bool p_allow_quick_transfer) {
	allow_quick_transfer = p_allow_quick_transfer;
	emit_changed();
}

void InventoryContainerConstraints::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_max_items", "max_items"), &InventoryContainerConstraints::set_max_items);
	ClassDB::bind_method(D_METHOD("get_max_items"), &InventoryContainerConstraints::get_max_items);
	ClassDB::bind_method(D_METHOD("set_has_mass_capacity", "has_mass_capacity"), &InventoryContainerConstraints::set_has_mass_capacity);
	ClassDB::bind_method(D_METHOD("get_has_mass_capacity"), &InventoryContainerConstraints::get_has_mass_capacity);
	ClassDB::bind_method(D_METHOD("set_mass_capacity_mg", "mass_capacity_mg"), &InventoryContainerConstraints::set_mass_capacity_mg);
	ClassDB::bind_method(D_METHOD("get_mass_capacity_mg"), &InventoryContainerConstraints::get_mass_capacity_mg);
	ClassDB::bind_method(D_METHOD("set_required_traits", "required_traits"), &InventoryContainerConstraints::set_required_traits);
	ClassDB::bind_method(D_METHOD("get_required_traits"), &InventoryContainerConstraints::get_required_traits);
	ClassDB::bind_method(D_METHOD("set_blocked_traits", "blocked_traits"), &InventoryContainerConstraints::set_blocked_traits);
	ClassDB::bind_method(D_METHOD("get_blocked_traits"), &InventoryContainerConstraints::get_blocked_traits);
	ClassDB::bind_method(D_METHOD("set_allow_nesting", "allow_nesting"), &InventoryContainerConstraints::set_allow_nesting);
	ClassDB::bind_method(D_METHOD("get_allow_nesting"), &InventoryContainerConstraints::get_allow_nesting);
	ClassDB::bind_method(D_METHOD("set_max_nesting_depth", "max_nesting_depth"), &InventoryContainerConstraints::set_max_nesting_depth);
	ClassDB::bind_method(D_METHOD("get_max_nesting_depth"), &InventoryContainerConstraints::get_max_nesting_depth);
	ClassDB::bind_method(D_METHOD("set_access_mask", "access_mask"), &InventoryContainerConstraints::set_access_mask);
	ClassDB::bind_method(D_METHOD("get_access_mask"), &InventoryContainerConstraints::get_access_mask);
	ClassDB::bind_method(D_METHOD("set_retention", "retention"), &InventoryContainerConstraints::set_retention);
	ClassDB::bind_method(D_METHOD("get_retention"), &InventoryContainerConstraints::get_retention);
	ClassDB::bind_method(D_METHOD("set_allow_stack_split", "allow_stack_split"), &InventoryContainerConstraints::set_allow_stack_split);
	ClassDB::bind_method(D_METHOD("get_allow_stack_split"), &InventoryContainerConstraints::get_allow_stack_split);
	ClassDB::bind_method(D_METHOD("set_allow_auto_placement", "allow_auto_placement"), &InventoryContainerConstraints::set_allow_auto_placement);
	ClassDB::bind_method(D_METHOD("get_allow_auto_placement"), &InventoryContainerConstraints::get_allow_auto_placement);
	ClassDB::bind_method(D_METHOD("set_allow_quick_transfer", "allow_quick_transfer"), &InventoryContainerConstraints::set_allow_quick_transfer);
	ClassDB::bind_method(D_METHOD("get_allow_quick_transfer"), &InventoryContainerConstraints::get_allow_quick_transfer);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_items", PROPERTY_HINT_RANGE, "0,4096,1,or_greater"),
			"set_max_items", "get_max_items");
	ADD_GROUP("Mass Capacity", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "has_mass_capacity"), "set_has_mass_capacity", "get_has_mass_capacity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mass_capacity_mg", PROPERTY_HINT_RANGE, "0,1000000000,1,or_greater"),
			"set_mass_capacity_mg", "get_mass_capacity_mg");
	ADD_GROUP("Filters", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "required_traits"), "set_required_traits", "get_required_traits");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "blocked_traits"), "set_blocked_traits", "get_blocked_traits");
	ADD_GROUP("Nesting", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_nesting"), "set_allow_nesting", "get_allow_nesting");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_nesting_depth", PROPERTY_HINT_RANGE, "0,16,1,or_greater"),
			"set_max_nesting_depth", "get_max_nesting_depth");
	ADD_GROUP("Policy", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "access_mask", PROPERTY_HINT_FLAGS, "Insert,Remove,Move,Inspect"),
			"set_access_mask", "get_access_mask");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "retention", PROPERTY_HINT_ENUM, "None,Protected,Bound"),
			"set_retention", "get_retention");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_stack_split"), "set_allow_stack_split", "get_allow_stack_split");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_auto_placement"), "set_allow_auto_placement", "get_allow_auto_placement");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "allow_quick_transfer"), "set_allow_quick_transfer", "get_allow_quick_transfer");

	BIND_ENUM_CONSTANT(RETENTION_NONE);
	BIND_ENUM_CONSTANT(RETENTION_PROTECTED);
	BIND_ENUM_CONSTANT(RETENTION_BOUND);

	BIND_BITFIELD_FLAG(ACCESS_INSERT);
	BIND_BITFIELD_FLAG(ACCESS_REMOVE);
	BIND_BITFIELD_FLAG(ACCESS_MOVE);
	BIND_BITFIELD_FLAG(ACCESS_INSPECT);
}

} // namespace godot
