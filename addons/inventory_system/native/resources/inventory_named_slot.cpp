#include "resources/inventory_named_slot.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryNamedSlot::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void InventoryNamedSlot::set_max_items(int p_max_items) {
	max_items = p_max_items;
	emit_changed();
}

void InventoryNamedSlot::set_required_traits(const PackedStringArray &p_required_traits) {
	required_traits = p_required_traits;
	emit_changed();
}

void InventoryNamedSlot::set_blocked_traits(const PackedStringArray &p_blocked_traits) {
	blocked_traits = p_blocked_traits;
	emit_changed();
}

void InventoryNamedSlot::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &InventoryNamedSlot::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &InventoryNamedSlot::get_identifier);
	ClassDB::bind_method(D_METHOD("set_max_items", "max_items"), &InventoryNamedSlot::set_max_items);
	ClassDB::bind_method(D_METHOD("get_max_items"), &InventoryNamedSlot::get_max_items);
	ClassDB::bind_method(D_METHOD("set_required_traits", "required_traits"), &InventoryNamedSlot::set_required_traits);
	ClassDB::bind_method(D_METHOD("get_required_traits"), &InventoryNamedSlot::get_required_traits);
	ClassDB::bind_method(D_METHOD("set_blocked_traits", "blocked_traits"), &InventoryNamedSlot::set_blocked_traits);
	ClassDB::bind_method(D_METHOD("get_blocked_traits"), &InventoryNamedSlot::get_blocked_traits);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.slot.headwear"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_items", PROPERTY_HINT_RANGE, "1,128,1,or_greater"),
			"set_max_items", "get_max_items");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "required_traits"), "set_required_traits", "get_required_traits");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "blocked_traits"), "set_blocked_traits", "get_blocked_traits");
}

} // namespace godot
