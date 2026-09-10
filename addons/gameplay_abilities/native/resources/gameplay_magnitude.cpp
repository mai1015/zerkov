#include "resources/gameplay_magnitude.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayMagnitude::set_kind(Kind p_kind) {
	kind = p_kind;
	emit_changed();
	notify_property_list_changed();
}

void GameplayMagnitude::set_coefficient(double p_coefficient) {
	coefficient = p_coefficient;
	emit_changed();
}

void GameplayMagnitude::set_attribute(const StringName &p_attribute) {
	attribute = p_attribute;
	emit_changed();
}

void GameplayMagnitude::set_set_by_caller_field(const StringName &p_field) {
	set_by_caller_field = p_field;
	emit_changed();
}

void GameplayMagnitude::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("attribute") &&
			kind != KIND_SOURCE_ATTRIBUTE && kind != KIND_TARGET_ATTRIBUTE) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (p_property.name == StringName("set_by_caller_field") && kind != KIND_SET_BY_CALLER) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayMagnitude::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_kind", "kind"), &GameplayMagnitude::set_kind);
	ClassDB::bind_method(D_METHOD("get_kind"), &GameplayMagnitude::get_kind);
	ClassDB::bind_method(D_METHOD("set_coefficient", "coefficient"), &GameplayMagnitude::set_coefficient);
	ClassDB::bind_method(D_METHOD("get_coefficient"), &GameplayMagnitude::get_coefficient);
	ClassDB::bind_method(D_METHOD("set_attribute", "attribute"), &GameplayMagnitude::set_attribute);
	ClassDB::bind_method(D_METHOD("get_attribute"), &GameplayMagnitude::get_attribute);
	ClassDB::bind_method(D_METHOD("set_set_by_caller_field", "field"), &GameplayMagnitude::set_set_by_caller_field);
	ClassDB::bind_method(D_METHOD("get_set_by_caller_field"), &GameplayMagnitude::get_set_by_caller_field);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM,
						 "Constant,Ability Level,Source Attribute,Target Attribute,Set By Caller"),
			"set_kind", "get_kind");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "coefficient", PROPERTY_HINT_RANGE,
						 "-1000,1000,0.0001,or_greater,or_less"),
			"set_coefficient", "get_coefficient");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "attribute", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "attribute.vitals.health"),
			"set_attribute", "get_attribute");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "set_by_caller_field", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "heal_amount"),
			"set_set_by_caller_field", "get_set_by_caller_field");

	BIND_ENUM_CONSTANT(KIND_CONSTANT);
	BIND_ENUM_CONSTANT(KIND_ABILITY_LEVEL);
	BIND_ENUM_CONSTANT(KIND_SOURCE_ATTRIBUTE);
	BIND_ENUM_CONSTANT(KIND_TARGET_ATTRIBUTE);
	BIND_ENUM_CONSTANT(KIND_SET_BY_CALLER);
}

} // namespace godot
