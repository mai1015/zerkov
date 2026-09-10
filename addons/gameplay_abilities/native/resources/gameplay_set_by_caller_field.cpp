#include "resources/gameplay_set_by_caller_field.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplaySetByCallerField::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplaySetByCallerField::set_required(bool p_required) {
	required = p_required;
	emit_changed();
}

void GameplaySetByCallerField::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplaySetByCallerField::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplaySetByCallerField::get_identifier);
	ClassDB::bind_method(D_METHOD("set_required", "required"), &GameplaySetByCallerField::set_required);
	ClassDB::bind_method(D_METHOD("is_required"), &GameplaySetByCallerField::is_required);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "heal_amount ([a-z][a-z0-9_]*, single segment)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "required"), "set_required", "is_required");
}

} // namespace godot
