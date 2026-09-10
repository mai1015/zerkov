#include "resources/gameplay_attribute_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayAttributeDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayAttributeDefinition::set_default_base(double p_value) {
	default_base = p_value;
	emit_changed();
}

void GameplayAttributeDefinition::set_has_min(bool p_has_min) {
	has_min = p_has_min;
	emit_changed();
	notify_property_list_changed();
}

void GameplayAttributeDefinition::set_min_value(double p_value) {
	min_value = p_value;
	emit_changed();
}

void GameplayAttributeDefinition::set_has_max(bool p_has_max) {
	has_max = p_has_max;
	emit_changed();
	notify_property_list_changed();
}

void GameplayAttributeDefinition::set_max_value(double p_value) {
	max_value = p_value;
	emit_changed();
}

void GameplayAttributeDefinition::set_display_name(const String &p_display_name) {
	display_name = p_display_name;
	emit_changed();
}

void GameplayAttributeDefinition::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("min_value") && !has_min) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (p_property.name == StringName("max_value") && !has_max) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayAttributeDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplayAttributeDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplayAttributeDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_default_base", "value"), &GameplayAttributeDefinition::set_default_base);
	ClassDB::bind_method(D_METHOD("get_default_base"), &GameplayAttributeDefinition::get_default_base);
	ClassDB::bind_method(D_METHOD("set_has_min", "has_min"), &GameplayAttributeDefinition::set_has_min);
	ClassDB::bind_method(D_METHOD("get_has_min"), &GameplayAttributeDefinition::get_has_min);
	ClassDB::bind_method(D_METHOD("set_min_value", "value"), &GameplayAttributeDefinition::set_min_value);
	ClassDB::bind_method(D_METHOD("get_min_value"), &GameplayAttributeDefinition::get_min_value);
	ClassDB::bind_method(D_METHOD("set_has_max", "has_max"), &GameplayAttributeDefinition::set_has_max);
	ClassDB::bind_method(D_METHOD("get_has_max"), &GameplayAttributeDefinition::get_has_max);
	ClassDB::bind_method(D_METHOD("set_max_value", "value"), &GameplayAttributeDefinition::set_max_value);
	ClassDB::bind_method(D_METHOD("get_max_value"), &GameplayAttributeDefinition::get_max_value);
	ClassDB::bind_method(D_METHOD("set_display_name", "display_name"), &GameplayAttributeDefinition::set_display_name);
	ClassDB::bind_method(D_METHOD("get_display_name"), &GameplayAttributeDefinition::get_display_name);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "attribute.vitals.health (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "default_base", PROPERTY_HINT_RANGE,
						 "-1000000,1000000,0.000001,or_greater,or_less"),
			"set_default_base", "get_default_base");
	ADD_GROUP("Bounds", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "has_min"), "set_has_min", "get_has_min");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "min_value", PROPERTY_HINT_RANGE,
						 "-1000000,1000000,0.000001,or_greater,or_less"),
			"set_min_value", "get_min_value");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "has_max"), "set_has_max", "get_has_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_value", PROPERTY_HINT_RANGE,
						 "-1000000,1000000,0.000001,or_greater,or_less"),
			"set_max_value", "get_max_value");
	ADD_GROUP("Presentation", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "display_name"), "set_display_name", "get_display_name");
}

} // namespace godot
