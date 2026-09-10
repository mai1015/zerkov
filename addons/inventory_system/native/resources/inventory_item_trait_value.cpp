#include "resources/inventory_item_trait_value.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryItemTraitValue::set_trait_identifier(const StringName &p_trait_identifier) {
	trait_identifier = p_trait_identifier;
	emit_changed();
}

void InventoryItemTraitValue::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void InventoryItemTraitValue::set_payload(const PackedByteArray &p_payload) {
	payload = p_payload;
	emit_changed();
}

void InventoryItemTraitValue::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_trait_identifier", "trait_identifier"), &InventoryItemTraitValue::set_trait_identifier);
	ClassDB::bind_method(D_METHOD("get_trait_identifier"), &InventoryItemTraitValue::get_trait_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &InventoryItemTraitValue::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &InventoryItemTraitValue::get_version);
	ClassDB::bind_method(D_METHOD("set_payload", "payload"), &InventoryItemTraitValue::set_payload);
	ClassDB::bind_method(D_METHOD("get_payload"), &InventoryItemTraitValue::get_payload);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "trait_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.trait.headwear"),
			"set_trait_identifier", "get_trait_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version"), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_BYTE_ARRAY, "payload"), "set_payload", "get_payload");
}

} // namespace godot
