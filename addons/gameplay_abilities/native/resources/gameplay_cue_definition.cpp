#include "resources/gameplay_cue_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayCueDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayCueDefinition::set_display_name(const String &p_display_name) {
	display_name = p_display_name;
	emit_changed();
}

void GameplayCueDefinition::set_description(const String &p_description) {
	description = p_description;
	emit_changed();
}

void GameplayCueDefinition::set_category(const StringName &p_category) {
	category = p_category;
	emit_changed();
}

void GameplayCueDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplayCueDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplayCueDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_display_name", "display_name"), &GameplayCueDefinition::set_display_name);
	ClassDB::bind_method(D_METHOD("get_display_name"), &GameplayCueDefinition::get_display_name);
	ClassDB::bind_method(D_METHOD("set_description", "description"), &GameplayCueDefinition::set_description);
	ClassDB::bind_method(D_METHOD("get_description"), &GameplayCueDefinition::get_description);
	ClassDB::bind_method(D_METHOD("set_category", "category"), &GameplayCueDefinition::set_category);
	ClassDB::bind_method(D_METHOD("get_category"), &GameplayCueDefinition::get_category);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "cue.poison.tick (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "display_name"), "set_display_name", "get_display_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "description", PROPERTY_HINT_MULTILINE_TEXT),
			"set_description", "get_description");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "category", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "vfx, audio, hud, animation, ..."),
			"set_category", "get_category");
}

} // namespace godot
