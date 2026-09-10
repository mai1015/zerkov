#include "resources/gameplay_stacking_policy.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayStackingPolicy::set_stackable(bool p_stackable) {
	stackable = p_stackable;
	emit_changed();
	notify_property_list_changed();
}

void GameplayStackingPolicy::set_stack_key(const String &p_key) {
	stack_key = p_key;
	emit_changed();
}

void GameplayStackingPolicy::set_source_scope(SourceScope p_scope) {
	source_scope = p_scope;
	emit_changed();
}

void GameplayStackingPolicy::set_max_stacks(int p_max_stacks) {
	max_stacks = p_max_stacks < 1 ? 1 : p_max_stacks;
	emit_changed();
}

void GameplayStackingPolicy::set_overflow_policy(OverflowPolicy p_policy) {
	overflow_policy = p_policy;
	emit_changed();
	notify_property_list_changed();
}

void GameplayStackingPolicy::set_refresh_duration_on_add(bool p_refresh) {
	refresh_duration_on_add = p_refresh;
	emit_changed();
}

void GameplayStackingPolicy::set_reset_period_on_add(bool p_reset) {
	reset_period_on_add = p_reset;
	emit_changed();
}

void GameplayStackingPolicy::set_removal_rule(RemovalRule p_rule) {
	removal_rule = p_rule;
	emit_changed();
}

void GameplayStackingPolicy::set_overflow_effect(const StringName &p_effect) {
	overflow_effect = p_effect;
	emit_changed();
}

void GameplayStackingPolicy::_validate_property(PropertyInfo &p_property) const {
	static const StringName stack_shape_fields[] = {
		StringName("stack_key"),
		StringName("source_scope"),
		StringName("max_stacks"),
		StringName("overflow_policy"),
		StringName("refresh_duration_on_add"),
		StringName("reset_period_on_add"),
		StringName("removal_rule"),
		StringName("overflow_effect"),
	};
	if (!stackable) {
		for (const StringName &field : stack_shape_fields) {
			if (p_property.name == field) {
				p_property.usage &= ~PROPERTY_USAGE_EDITOR;
				return;
			}
		}
	}
	if (p_property.name == StringName("overflow_effect") && overflow_policy != OVERFLOW_APPLY_EFFECT) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayStackingPolicy::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_stackable", "stackable"), &GameplayStackingPolicy::set_stackable);
	ClassDB::bind_method(D_METHOD("is_stackable"), &GameplayStackingPolicy::is_stackable);
	ClassDB::bind_method(D_METHOD("set_stack_key", "key"), &GameplayStackingPolicy::set_stack_key);
	ClassDB::bind_method(D_METHOD("get_stack_key"), &GameplayStackingPolicy::get_stack_key);
	ClassDB::bind_method(D_METHOD("set_source_scope", "scope"), &GameplayStackingPolicy::set_source_scope);
	ClassDB::bind_method(D_METHOD("get_source_scope"), &GameplayStackingPolicy::get_source_scope);
	ClassDB::bind_method(D_METHOD("set_max_stacks", "max_stacks"), &GameplayStackingPolicy::set_max_stacks);
	ClassDB::bind_method(D_METHOD("get_max_stacks"), &GameplayStackingPolicy::get_max_stacks);
	ClassDB::bind_method(D_METHOD("set_overflow_policy", "policy"), &GameplayStackingPolicy::set_overflow_policy);
	ClassDB::bind_method(D_METHOD("get_overflow_policy"), &GameplayStackingPolicy::get_overflow_policy);
	ClassDB::bind_method(D_METHOD("set_refresh_duration_on_add", "refresh"),
			&GameplayStackingPolicy::set_refresh_duration_on_add);
	ClassDB::bind_method(D_METHOD("is_refresh_duration_on_add"), &GameplayStackingPolicy::is_refresh_duration_on_add);
	ClassDB::bind_method(D_METHOD("set_reset_period_on_add", "reset"),
			&GameplayStackingPolicy::set_reset_period_on_add);
	ClassDB::bind_method(D_METHOD("is_reset_period_on_add"), &GameplayStackingPolicy::is_reset_period_on_add);
	ClassDB::bind_method(D_METHOD("set_removal_rule", "rule"), &GameplayStackingPolicy::set_removal_rule);
	ClassDB::bind_method(D_METHOD("get_removal_rule"), &GameplayStackingPolicy::get_removal_rule);
	ClassDB::bind_method(D_METHOD("set_overflow_effect", "effect"), &GameplayStackingPolicy::set_overflow_effect);
	ClassDB::bind_method(D_METHOD("get_overflow_effect"), &GameplayStackingPolicy::get_overflow_effect);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "stackable"), "set_stackable", "is_stackable");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "stack_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "defaults to the owning effect's identifier"),
			"set_stack_key", "get_stack_key");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "source_scope", PROPERTY_HINT_ENUM, "Source Scoped,Target Scoped"),
			"set_source_scope", "get_source_scope");
	// 999 mirrors ga::MAX_STACK_COUNT (native/core/ga_limits.h); kept as a
	// literal here so this Resource stays free of a core include (see
	// native/godot/gameplay_definition_validator.cpp for the enforced bound).
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_stacks", PROPERTY_HINT_RANGE, "1,999,1"),
			"set_max_stacks", "get_max_stacks");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "overflow_policy", PROPERTY_HINT_ENUM,
						 "Reject,Refresh,Replace,Apply Overflow Effect"),
			"set_overflow_policy", "get_overflow_policy");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "refresh_duration_on_add"),
			"set_refresh_duration_on_add", "is_refresh_duration_on_add");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "reset_period_on_add"),
			"set_reset_period_on_add", "is_reset_period_on_add");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "removal_rule", PROPERTY_HINT_ENUM,
						 "Remove Single Stack,Remove All Stacks"),
			"set_removal_rule", "get_removal_rule");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "overflow_effect", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "identifier of the effect applied on overflow"),
			"set_overflow_effect", "get_overflow_effect");

	BIND_ENUM_CONSTANT(SOURCE_SCOPED);
	BIND_ENUM_CONSTANT(TARGET_SCOPED);
	BIND_ENUM_CONSTANT(OVERFLOW_REJECT);
	BIND_ENUM_CONSTANT(OVERFLOW_REFRESH);
	BIND_ENUM_CONSTANT(OVERFLOW_REPLACE);
	BIND_ENUM_CONSTANT(OVERFLOW_APPLY_EFFECT);
	BIND_ENUM_CONSTANT(REMOVE_SINGLE_STACK);
	BIND_ENUM_CONSTANT(REMOVE_ALL_STACKS);
}

} // namespace godot
