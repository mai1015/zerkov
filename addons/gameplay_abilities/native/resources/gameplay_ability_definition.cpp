#include "resources/gameplay_ability_definition.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void GameplayAbilityDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void GameplayAbilityDefinition::set_activation_policy(ActivationPolicy p_policy) {
	activation_policy = p_policy;
	emit_changed();
}

void GameplayAbilityDefinition::set_required_tags(const Ref<GameplayTagQueryResource> &p_query) {
	required_tags = p_query;
	emit_changed();
}

void GameplayAbilityDefinition::set_blocked_tags(const Ref<GameplayTagQueryResource> &p_query) {
	blocked_tags = p_query;
	emit_changed();
}

void GameplayAbilityDefinition::set_owned_tags(const PackedStringArray &p_tags) {
	owned_tags = p_tags;
	emit_changed();
}

void GameplayAbilityDefinition::set_cancel_tags(const Ref<GameplayTagQueryResource> &p_query) {
	cancel_tags = p_query;
	emit_changed();
}

void GameplayAbilityDefinition::set_cost_effect(const StringName &p_identifier) {
	cost_effect = p_identifier;
	emit_changed();
}

void GameplayAbilityDefinition::set_cooldown_effect(const StringName &p_identifier) {
	cooldown_effect = p_identifier;
	emit_changed();
}

void GameplayAbilityDefinition::set_commit_effects(const PackedStringArray &p_identifiers) {
	commit_effects = p_identifiers;
	emit_changed();
}

void GameplayAbilityDefinition::set_triggers(const TypedArray<GameplayAbilityTrigger> &p_triggers) {
	triggers = p_triggers;
	emit_changed();
}

void GameplayAbilityDefinition::set_concurrency_policy(ConcurrencyPolicy p_policy) {
	concurrency_policy = p_policy;
	emit_changed();
}

void GameplayAbilityDefinition::set_duplicate_grant_policy(DuplicateGrantPolicy p_policy) {
	duplicate_grant_policy = p_policy;
	emit_changed();
}

void GameplayAbilityDefinition::set_revoke_policy(RevokePolicy p_policy) {
	revoke_policy = p_policy;
	emit_changed();
}

void GameplayAbilityDefinition::set_prediction_policy(PredictionPolicy p_policy) {
	prediction_policy = p_policy;
	emit_changed();
	notify_property_list_changed();
}

void GameplayAbilityDefinition::set_hook_binding(HookBinding p_binding) {
	hook_binding = p_binding;
	emit_changed();
}

void GameplayAbilityDefinition::set_auto_commit(bool p_auto_commit) {
	auto_commit = p_auto_commit;
	emit_changed();
}

void GameplayAbilityDefinition::set_ends_on_commit(bool p_ends_on_commit) {
	ends_on_commit = p_ends_on_commit;
	emit_changed();
}

void GameplayAbilityDefinition::set_prediction_safe_declared(bool p_declared) {
	prediction_safe_declared = p_declared;
	emit_changed();
}

void GameplayAbilityDefinition::set_target_schema(const StringName &p_identifier) {
	target_schema = p_identifier;
	emit_changed();
}

void GameplayAbilityDefinition::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("prediction_safe_declared") && prediction_policy != PREDICTION_PREDICTABLE) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void GameplayAbilityDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &GameplayAbilityDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &GameplayAbilityDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_activation_policy", "policy"), &GameplayAbilityDefinition::set_activation_policy);
	ClassDB::bind_method(D_METHOD("get_activation_policy"), &GameplayAbilityDefinition::get_activation_policy);
	ClassDB::bind_method(D_METHOD("set_required_tags", "query"), &GameplayAbilityDefinition::set_required_tags);
	ClassDB::bind_method(D_METHOD("get_required_tags"), &GameplayAbilityDefinition::get_required_tags);
	ClassDB::bind_method(D_METHOD("set_blocked_tags", "query"), &GameplayAbilityDefinition::set_blocked_tags);
	ClassDB::bind_method(D_METHOD("get_blocked_tags"), &GameplayAbilityDefinition::get_blocked_tags);
	ClassDB::bind_method(D_METHOD("set_owned_tags", "tags"), &GameplayAbilityDefinition::set_owned_tags);
	ClassDB::bind_method(D_METHOD("get_owned_tags"), &GameplayAbilityDefinition::get_owned_tags);
	ClassDB::bind_method(D_METHOD("set_cancel_tags", "query"), &GameplayAbilityDefinition::set_cancel_tags);
	ClassDB::bind_method(D_METHOD("get_cancel_tags"), &GameplayAbilityDefinition::get_cancel_tags);
	ClassDB::bind_method(D_METHOD("set_cost_effect", "identifier"), &GameplayAbilityDefinition::set_cost_effect);
	ClassDB::bind_method(D_METHOD("get_cost_effect"), &GameplayAbilityDefinition::get_cost_effect);
	ClassDB::bind_method(D_METHOD("set_cooldown_effect", "identifier"), &GameplayAbilityDefinition::set_cooldown_effect);
	ClassDB::bind_method(D_METHOD("get_cooldown_effect"), &GameplayAbilityDefinition::get_cooldown_effect);
	ClassDB::bind_method(D_METHOD("set_commit_effects", "identifiers"), &GameplayAbilityDefinition::set_commit_effects);
	ClassDB::bind_method(D_METHOD("get_commit_effects"), &GameplayAbilityDefinition::get_commit_effects);
	ClassDB::bind_method(D_METHOD("set_triggers", "triggers"), &GameplayAbilityDefinition::set_triggers);
	ClassDB::bind_method(D_METHOD("get_triggers"), &GameplayAbilityDefinition::get_triggers);
	ClassDB::bind_method(D_METHOD("set_concurrency_policy", "policy"), &GameplayAbilityDefinition::set_concurrency_policy);
	ClassDB::bind_method(D_METHOD("get_concurrency_policy"), &GameplayAbilityDefinition::get_concurrency_policy);
	ClassDB::bind_method(D_METHOD("set_duplicate_grant_policy", "policy"),
			&GameplayAbilityDefinition::set_duplicate_grant_policy);
	ClassDB::bind_method(D_METHOD("get_duplicate_grant_policy"), &GameplayAbilityDefinition::get_duplicate_grant_policy);
	ClassDB::bind_method(D_METHOD("set_revoke_policy", "policy"), &GameplayAbilityDefinition::set_revoke_policy);
	ClassDB::bind_method(D_METHOD("get_revoke_policy"), &GameplayAbilityDefinition::get_revoke_policy);
	ClassDB::bind_method(D_METHOD("set_prediction_policy", "policy"), &GameplayAbilityDefinition::set_prediction_policy);
	ClassDB::bind_method(D_METHOD("get_prediction_policy"), &GameplayAbilityDefinition::get_prediction_policy);
	ClassDB::bind_method(D_METHOD("set_hook_binding", "binding"), &GameplayAbilityDefinition::set_hook_binding);
	ClassDB::bind_method(D_METHOD("get_hook_binding"), &GameplayAbilityDefinition::get_hook_binding);
	ClassDB::bind_method(D_METHOD("set_auto_commit", "auto_commit"), &GameplayAbilityDefinition::set_auto_commit);
	ClassDB::bind_method(D_METHOD("get_auto_commit"), &GameplayAbilityDefinition::get_auto_commit);
	ClassDB::bind_method(D_METHOD("set_ends_on_commit", "ends_on_commit"), &GameplayAbilityDefinition::set_ends_on_commit);
	ClassDB::bind_method(D_METHOD("get_ends_on_commit"), &GameplayAbilityDefinition::get_ends_on_commit);
	ClassDB::bind_method(D_METHOD("set_prediction_safe_declared", "declared"),
			&GameplayAbilityDefinition::set_prediction_safe_declared);
	ClassDB::bind_method(D_METHOD("get_prediction_safe_declared"),
			&GameplayAbilityDefinition::get_prediction_safe_declared);
	ClassDB::bind_method(D_METHOD("set_target_schema", "identifier"), &GameplayAbilityDefinition::set_target_schema);
	ClassDB::bind_method(D_METHOD("get_target_schema"), &GameplayAbilityDefinition::get_target_schema);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "ability.dash (>= 2 dotted segments, [a-z][a-z0-9_]*)"),
			"set_identifier", "get_identifier");

	ADD_GROUP("Activation", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "activation_policy", PROPERTY_HINT_ENUM,
						 "Manual,Gameplay Event,Passive On Grant"),
			"set_activation_policy", "get_activation_policy");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "triggers", PROPERTY_HINT_ARRAY_TYPE,
						 vformat("%d/%d:GameplayAbilityTrigger", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_triggers", "get_triggers");

	ADD_GROUP("Tags", "");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "required_tags", PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_required_tags", "get_required_tags");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "blocked_tags", PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_blocked_tags", "get_blocked_tags");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "owned_tags"), "set_owned_tags", "get_owned_tags");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "cancel_tags", PROPERTY_HINT_RESOURCE_TYPE,
						 "GameplayTagQueryResource"),
			"set_cancel_tags", "get_cancel_tags");

	ADD_GROUP("Cost & Cooldown", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "cost_effect", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "effect identifier, or empty for none"),
			"set_cost_effect", "get_cost_effect");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "cooldown_effect", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "effect identifier, or empty for none"),
			"set_cooldown_effect", "get_cooldown_effect");

	ADD_GROUP("Commit", "");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "commit_effects"),
			"set_commit_effects", "get_commit_effects");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_commit"), "set_auto_commit", "get_auto_commit");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "ends_on_commit"), "set_ends_on_commit", "get_ends_on_commit");

	ADD_GROUP("Policies", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "concurrency_policy", PROPERTY_HINT_ENUM,
						 "Reject If Active,Allow Multiple"),
			"set_concurrency_policy", "get_concurrency_policy");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "duplicate_grant_policy", PROPERTY_HINT_ENUM,
						 "Reject,Replace,Multi Grant"),
			"set_duplicate_grant_policy", "get_duplicate_grant_policy");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "revoke_policy", PROPERTY_HINT_ENUM,
						 "Cancel Active,Permit Completion"),
			"set_revoke_policy", "get_revoke_policy");

	ADD_GROUP("Prediction", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "prediction_policy", PROPERTY_HINT_ENUM,
						 "Not Predictable,Predictable"),
			"set_prediction_policy", "get_prediction_policy");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "prediction_safe_declared"),
			"set_prediction_safe_declared", "get_prediction_safe_declared");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "hook_binding", PROPERTY_HINT_ENUM,
						 "None,Authority Only,Prediction Safe"),
			"set_hook_binding", "get_hook_binding");

	ADD_GROUP("Target Data", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_schema", PROPERTY_HINT_PLACEHOLDER_TEXT,
						 "GameplayTargetDataSchema identifier, or empty for none"),
			"set_target_schema", "get_target_schema");

	BIND_ENUM_CONSTANT(ACTIVATION_MANUAL);
	BIND_ENUM_CONSTANT(ACTIVATION_GAMEPLAY_EVENT);
	BIND_ENUM_CONSTANT(ACTIVATION_PASSIVE_ON_GRANT);

	BIND_ENUM_CONSTANT(CONCURRENCY_REJECT_IF_ACTIVE);
	BIND_ENUM_CONSTANT(CONCURRENCY_ALLOW_MULTIPLE);

	BIND_ENUM_CONSTANT(DUPLICATE_GRANT_REJECT);
	BIND_ENUM_CONSTANT(DUPLICATE_GRANT_REPLACE);
	BIND_ENUM_CONSTANT(DUPLICATE_GRANT_MULTI_GRANT);

	BIND_ENUM_CONSTANT(REVOKE_CANCEL_ACTIVE);
	BIND_ENUM_CONSTANT(REVOKE_PERMIT_COMPLETION);

	BIND_ENUM_CONSTANT(PREDICTION_NOT_PREDICTABLE);
	BIND_ENUM_CONSTANT(PREDICTION_PREDICTABLE);

	BIND_ENUM_CONSTANT(HOOK_BINDING_NONE);
	BIND_ENUM_CONSTANT(HOOK_BINDING_AUTHORITY_ONLY);
	BIND_ENUM_CONSTANT(HOOK_BINDING_PREDICTION_SAFE);
}

} // namespace godot
