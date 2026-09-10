#include "resources/gameplay_modifier_declaration.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayModifierDeclaration::set_target_attribute(const StringName &p_attribute) {
	target_attribute = p_attribute;
	emit_changed();
}

void GameplayModifierDeclaration::set_op(Op p_op) {
	op = p_op;
	emit_changed();
}

void GameplayModifierDeclaration::set_magnitude(const Ref<GameplayMagnitude> &p_magnitude) {
	magnitude = p_magnitude;
	emit_changed();
}

void GameplayModifierDeclaration::set_priority(int p_priority) {
	priority = p_priority;
	emit_changed();
}

void GameplayModifierDeclaration::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_target_attribute", "attribute"),
			&GameplayModifierDeclaration::set_target_attribute);
	ClassDB::bind_method(D_METHOD("get_target_attribute"), &GameplayModifierDeclaration::get_target_attribute);
	ClassDB::bind_method(D_METHOD("set_op", "op"), &GameplayModifierDeclaration::set_op);
	ClassDB::bind_method(D_METHOD("get_op"), &GameplayModifierDeclaration::get_op);
	ClassDB::bind_method(D_METHOD("set_magnitude", "magnitude"), &GameplayModifierDeclaration::set_magnitude);
	ClassDB::bind_method(D_METHOD("get_magnitude"), &GameplayModifierDeclaration::get_magnitude);
	ClassDB::bind_method(D_METHOD("set_priority", "priority"), &GameplayModifierDeclaration::set_priority);
	ClassDB::bind_method(D_METHOD("get_priority"), &GameplayModifierDeclaration::get_priority);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_attribute", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "attribute.vitals.health"),
			"set_target_attribute", "get_target_attribute");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "op", PROPERTY_HINT_ENUM, "Add,Multiply,Override"),
			"set_op", "get_op");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "magnitude", PROPERTY_HINT_RESOURCE_TYPE, "GameplayMagnitude"),
			"set_magnitude", "get_magnitude");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "priority"), "set_priority", "get_priority");

	BIND_ENUM_CONSTANT(OP_ADD);
	BIND_ENUM_CONSTANT(OP_MULTIPLY);
	BIND_ENUM_CONSTANT(OP_OVERRIDE);
}

} // namespace godot
