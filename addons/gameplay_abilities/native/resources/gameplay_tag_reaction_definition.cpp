#include "resources/gameplay_tag_reaction_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayTagReactionDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayTagReactionDefinition::set_operand(const Ref<GameplayTagOperand> &p_operand) {
	operand = p_operand;
	emit_changed();
}

void GameplayTagReactionDefinition::set_mode(Mode p_mode) {
	mode = p_mode;
	emit_changed();
}

void GameplayTagReactionDefinition::set_effect_identifier(const StringName &p_identifier) {
	effect_identifier = p_identifier;
	emit_changed();
}

void GameplayTagReactionDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplayTagReactionDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplayTagReactionDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_operand", "operand"), &GameplayTagReactionDefinition::set_operand);
	ClassDB::bind_method(D_METHOD("get_operand"), &GameplayTagReactionDefinition::get_operand);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &GameplayTagReactionDefinition::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &GameplayTagReactionDefinition::get_mode);
	ClassDB::bind_method(D_METHOD("set_effect_identifier", "identifier"),
			&GameplayTagReactionDefinition::set_effect_identifier);
	ClassDB::bind_method(D_METHOD("get_effect_identifier"), &GameplayTagReactionDefinition::get_effect_identifier);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "reaction.state.control.stunned_slow (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "operand", PROPERTY_HINT_RESOURCE_TYPE, "GameplayTagOperand"),
			"set_operand", "get_operand");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "On Added,On Removed,While Present"),
			"set_mode", "get_mode");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "effect_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "effect.state.control.slow_on_stun"),
			"set_effect_identifier", "get_effect_identifier");

	BIND_ENUM_CONSTANT(MODE_ON_ADDED);
	BIND_ENUM_CONSTANT(MODE_ON_REMOVED);
	BIND_ENUM_CONSTANT(MODE_WHILE_PRESENT);
}

} // namespace godot
