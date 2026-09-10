#include "resources/gameplay_ability_trigger.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayAbilityTrigger::set_kind(Kind p_kind) {
	kind = p_kind;
	emit_changed();
	notify_property_list_changed();
}

void GameplayAbilityTrigger::set_input_id(const String &p_input_id) {
	input_id = p_input_id;
	emit_changed();
}

void GameplayAbilityTrigger::set_gameplay_event_tag(const StringName &p_tag) {
	gameplay_event_tag = p_tag;
	emit_changed();
}

void GameplayAbilityTrigger::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("input_id") && kind != KIND_INPUT) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (p_property.name == StringName("gameplay_event_tag") && kind != KIND_GAMEPLAY_EVENT) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayAbilityTrigger::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_kind", "kind"), &GameplayAbilityTrigger::set_kind);
	ClassDB::bind_method(D_METHOD("get_kind"), &GameplayAbilityTrigger::get_kind);
	ClassDB::bind_method(D_METHOD("set_input_id", "input_id"), &GameplayAbilityTrigger::set_input_id);
	ClassDB::bind_method(D_METHOD("get_input_id"), &GameplayAbilityTrigger::get_input_id);
	ClassDB::bind_method(D_METHOD("set_gameplay_event_tag", "tag"), &GameplayAbilityTrigger::set_gameplay_event_tag);
	ClassDB::bind_method(D_METHOD("get_gameplay_event_tag"), &GameplayAbilityTrigger::get_gameplay_event_tag);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM, "Input,Gameplay Event"),
			"set_kind", "get_kind");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "input_id", PROPERTY_HINT_PLACEHOLDER_TEXT, "action.dash"),
			"set_input_id", "get_input_id");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "gameplay_event_tag", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "event.taunted"),
			"set_gameplay_event_tag", "get_gameplay_event_tag");

	BIND_ENUM_CONSTANT(KIND_INPUT);
	BIND_ENUM_CONSTANT(KIND_GAMEPLAY_EVENT);
}

} // namespace godot
