#include "resources/gameplay_effect_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayEffectDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayEffectDefinition::set_duration_policy(DurationPolicy p_policy) {
	duration_policy = p_policy;
	emit_changed();
	notify_property_list_changed();
}

void GameplayEffectDefinition::set_duration_ticks(int64_t p_ticks) {
	duration_ticks = p_ticks < 0 ? 0 : p_ticks;
	emit_changed();
}

void GameplayEffectDefinition::set_has_period(bool p_has_period) {
	has_period = p_has_period;
	emit_changed();
	notify_property_list_changed();
}

void GameplayEffectDefinition::set_period_ticks(int64_t p_ticks) {
	period_ticks = p_ticks < 0 ? 0 : p_ticks;
	emit_changed();
}

void GameplayEffectDefinition::set_modifiers(const TypedArray<GameplayModifierDeclaration> &p_modifiers) {
	modifiers = p_modifiers;
	emit_changed();
}

void GameplayEffectDefinition::set_granted_tags(const PackedStringArray &p_tags) {
	granted_tags = p_tags;
	emit_changed();
}

void GameplayEffectDefinition::set_source_requirements(const Ref<GameplayTagQueryResource> &p_query) {
	source_requirements = p_query;
	emit_changed();
}

void GameplayEffectDefinition::set_target_requirements(const Ref<GameplayTagQueryResource> &p_query) {
	target_requirements = p_query;
	emit_changed();
}

void GameplayEffectDefinition::set_immunity(const Ref<GameplayTagQueryResource> &p_query) {
	immunity = p_query;
	emit_changed();
}

void GameplayEffectDefinition::set_stacking(const Ref<GameplayStackingPolicy> &p_stacking) {
	stacking = p_stacking;
	emit_changed();
}

void GameplayEffectDefinition::set_set_by_caller_fields(const TypedArray<GameplaySetByCallerField> &p_fields) {
	set_by_caller_fields = p_fields;
	emit_changed();
}

void GameplayEffectDefinition::set_cue_identifiers(const PackedStringArray &p_identifiers) {
	cue_identifiers = p_identifiers;
	emit_changed();
}

void GameplayEffectDefinition::set_prediction_safe(bool p_prediction_safe) {
	prediction_safe = p_prediction_safe;
	emit_changed();
}

void GameplayEffectDefinition::set_retain_target_context(bool p_retain) {
	retain_target_context = p_retain;
	emit_changed();
}

void GameplayEffectDefinition::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("duration_ticks") && duration_policy != DURATION_DURATION) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (p_property.name == StringName("period_ticks") && !has_period) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayEffectDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplayEffectDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplayEffectDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_duration_policy", "policy"), &GameplayEffectDefinition::set_duration_policy);
	ClassDB::bind_method(D_METHOD("get_duration_policy"), &GameplayEffectDefinition::get_duration_policy);
	ClassDB::bind_method(D_METHOD("set_duration_ticks", "ticks"), &GameplayEffectDefinition::set_duration_ticks);
	ClassDB::bind_method(D_METHOD("get_duration_ticks"), &GameplayEffectDefinition::get_duration_ticks);
	ClassDB::bind_method(D_METHOD("set_has_period", "has_period"), &GameplayEffectDefinition::set_has_period);
	ClassDB::bind_method(D_METHOD("get_has_period"), &GameplayEffectDefinition::get_has_period);
	ClassDB::bind_method(D_METHOD("set_period_ticks", "ticks"), &GameplayEffectDefinition::set_period_ticks);
	ClassDB::bind_method(D_METHOD("get_period_ticks"), &GameplayEffectDefinition::get_period_ticks);
	ClassDB::bind_method(D_METHOD("set_modifiers", "modifiers"), &GameplayEffectDefinition::set_modifiers);
	ClassDB::bind_method(D_METHOD("get_modifiers"), &GameplayEffectDefinition::get_modifiers);
	ClassDB::bind_method(D_METHOD("set_granted_tags", "tags"), &GameplayEffectDefinition::set_granted_tags);
	ClassDB::bind_method(D_METHOD("get_granted_tags"), &GameplayEffectDefinition::get_granted_tags);
	ClassDB::bind_method(D_METHOD("set_source_requirements", "query"),
			&GameplayEffectDefinition::set_source_requirements);
	ClassDB::bind_method(D_METHOD("get_source_requirements"), &GameplayEffectDefinition::get_source_requirements);
	ClassDB::bind_method(D_METHOD("set_target_requirements", "query"),
			&GameplayEffectDefinition::set_target_requirements);
	ClassDB::bind_method(D_METHOD("get_target_requirements"), &GameplayEffectDefinition::get_target_requirements);
	ClassDB::bind_method(D_METHOD("set_immunity", "query"), &GameplayEffectDefinition::set_immunity);
	ClassDB::bind_method(D_METHOD("get_immunity"), &GameplayEffectDefinition::get_immunity);
	ClassDB::bind_method(D_METHOD("set_stacking", "stacking"), &GameplayEffectDefinition::set_stacking);
	ClassDB::bind_method(D_METHOD("get_stacking"), &GameplayEffectDefinition::get_stacking);
	ClassDB::bind_method(D_METHOD("set_set_by_caller_fields", "fields"),
			&GameplayEffectDefinition::set_set_by_caller_fields);
	ClassDB::bind_method(D_METHOD("get_set_by_caller_fields"), &GameplayEffectDefinition::get_set_by_caller_fields);
	ClassDB::bind_method(D_METHOD("set_cue_identifiers", "identifiers"),
			&GameplayEffectDefinition::set_cue_identifiers);
	ClassDB::bind_method(D_METHOD("get_cue_identifiers"), &GameplayEffectDefinition::get_cue_identifiers);
	ClassDB::bind_method(D_METHOD("set_prediction_safe", "prediction_safe"),
			&GameplayEffectDefinition::set_prediction_safe);
	ClassDB::bind_method(D_METHOD("get_prediction_safe"), &GameplayEffectDefinition::get_prediction_safe);
	ClassDB::bind_method(D_METHOD("set_retain_target_context", "retain"),
			&GameplayEffectDefinition::set_retain_target_context);
	ClassDB::bind_method(D_METHOD("get_retain_target_context"),
			&GameplayEffectDefinition::get_retain_target_context);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "effect.poison.weak (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");
	ADD_GROUP("Lifetime", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "duration_policy", PROPERTY_HINT_ENUM, "Instant,Duration,Infinite"),
			"set_duration_policy", "get_duration_policy");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "duration_ticks", PROPERTY_HINT_RANGE, "1,36000000,1,or_greater"),
			"set_duration_ticks", "get_duration_ticks");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "has_period"), "set_has_period", "get_has_period");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "period_ticks", PROPERTY_HINT_RANGE, "1,36000000,1,or_greater"),
			"set_period_ticks", "get_period_ticks");
	ADD_GROUP("Modifiers", "");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "modifiers", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayModifierDeclaration", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_modifiers", "get_modifiers");
	ADD_GROUP("Tags", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "granted_tags"),
			"set_granted_tags", "get_granted_tags");
	ADD_GROUP("Requirements", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "source_requirements", PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_source_requirements", "get_source_requirements");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "target_requirements", PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_target_requirements", "get_target_requirements");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "immunity", PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_immunity", "get_immunity");
	ADD_GROUP("Stacking", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "stacking", PROPERTY_HINT_RESOURCE_TYPE, "GameplayStackingPolicy"),
			"set_stacking", "get_stacking");
	ADD_GROUP("Set By Caller", "");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "set_by_caller_fields", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplaySetByCallerField", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_set_by_caller_fields", "get_set_by_caller_fields");
	ADD_GROUP("Presentation", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "cue_identifiers"),
			"set_cue_identifiers", "get_cue_identifiers");
	ADD_GROUP("", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "prediction_safe"), "set_prediction_safe", "get_prediction_safe");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "retain_target_context"),
			"set_retain_target_context", "get_retain_target_context");

	BIND_ENUM_CONSTANT(DURATION_INSTANT);
	BIND_ENUM_CONSTANT(DURATION_DURATION);
	BIND_ENUM_CONSTANT(DURATION_INFINITE);
}

} // namespace godot
