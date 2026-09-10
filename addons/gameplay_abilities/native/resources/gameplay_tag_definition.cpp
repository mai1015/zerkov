#include "resources/gameplay_tag_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayTagDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayTagDefinition::set_description(const String &p_description) {
	description = p_description;
	emit_changed();
}

void GameplayTagDefinition::set_source_label(const String &p_source_label) {
	source_label = p_source_label;
	emit_changed();
}

void GameplayTagDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplayTagDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplayTagDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_description", "description"), &GameplayTagDefinition::set_description);
	ClassDB::bind_method(D_METHOD("get_description"), &GameplayTagDefinition::get_description);
	ClassDB::bind_method(D_METHOD("set_source_label", "source_label"), &GameplayTagDefinition::set_source_label);
	ClassDB::bind_method(D_METHOD("get_source_label"), &GameplayTagDefinition::get_source_label);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "state.control.stunned (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "description", PROPERTY_HINT_MULTILINE_TEXT),
			"set_description", "get_description");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "source_label", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "defaults to this resource's path when empty"),
			"set_source_label", "get_source_label");
}

} // namespace godot
