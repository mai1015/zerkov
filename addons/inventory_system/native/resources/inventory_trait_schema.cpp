#include "resources/inventory_trait_schema.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void InventoryTraitSchema::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void InventoryTraitSchema::set_version(int p_version) {
	version = p_version;
	emit_changed();
}

void InventoryTraitSchema::set_authority_affecting(bool p_authority_affecting) {
	authority_affecting = p_authority_affecting;
	emit_changed();
}

void InventoryTraitSchema::set_max_payload_bytes(int p_max_payload_bytes) {
	max_payload_bytes = p_max_payload_bytes;
	emit_changed();
}

void InventoryTraitSchema::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &InventoryTraitSchema::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &InventoryTraitSchema::get_identifier);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &InventoryTraitSchema::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &InventoryTraitSchema::get_version);
	ClassDB::bind_method(D_METHOD("set_authority_affecting", "authority_affecting"), &InventoryTraitSchema::set_authority_affecting);
	ClassDB::bind_method(D_METHOD("get_authority_affecting"), &InventoryTraitSchema::get_authority_affecting);
	ClassDB::bind_method(D_METHOD("set_max_payload_bytes", "max_payload_bytes"), &InventoryTraitSchema::set_max_payload_bytes);
	ClassDB::bind_method(D_METHOD("get_max_payload_bytes"), &InventoryTraitSchema::get_max_payload_bytes);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "game.trait.headwear (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "version"), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "authority_affecting"), "set_authority_affecting", "get_authority_affecting");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_payload_bytes", PROPERTY_HINT_RANGE, "0,1024,1,or_greater"),
			"set_max_payload_bytes", "get_max_payload_bytes");
}

} // namespace godot
