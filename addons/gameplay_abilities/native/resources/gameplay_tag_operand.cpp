#include "resources/gameplay_tag_operand.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayTagOperand::set_tag(const StringName &p_tag) {
	tag = p_tag;
	emit_changed();
}

void GameplayTagOperand::set_match_mode(MatchMode p_mode) {
	match_mode = p_mode;
	emit_changed();
}

void GameplayTagOperand::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_tag", "tag"), &GameplayTagOperand::set_tag);
	ClassDB::bind_method(D_METHOD("get_tag"), &GameplayTagOperand::get_tag);
	ClassDB::bind_method(D_METHOD("set_match_mode", "mode"), &GameplayTagOperand::set_match_mode);
	ClassDB::bind_method(D_METHOD("get_match_mode"), &GameplayTagOperand::get_match_mode);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "tag", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "state.control.stunned (>= 2 dotted segments)"),
			"set_tag", "get_tag");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "match_mode", PROPERTY_HINT_ENUM, "Exact,Parent Aware"),
			"set_match_mode", "get_match_mode");

	BIND_ENUM_CONSTANT(MATCH_EXACT);
	BIND_ENUM_CONSTANT(MATCH_PARENT_AWARE);
}

} // namespace godot
