#ifndef GAMEPLAY_ABILITIES_RESOURCES_ABILITY_DEFINITION_H
#define GAMEPLAY_ABILITIES_RESOURCES_ABILITY_DEFINITION_H

#include "resources/gameplay_ability_trigger.h"
#include "resources/gameplay_tag_query_resource.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Editor-authored counterpart of `ga::AbilityDefinitionDesc`
// (native/core/ga_abilities.h), mirrored field for field (task 9.1's
// remainder). Every reference field here (required/blocked/cancel tag
// queries, owned tags, cost/cooldown/commit effect identifiers, trigger
// gameplay-event tags) is validated and resolved against the sealed tag/
// effect registries by `GameplayDefinitionValidator` -- never by this class,
// which is pure data, exactly like `GameplayEffectDefinition`.
//
// `GameplayAbilityComponent::set_ability_definitions` still takes an
// `Array[Dictionary]` shaped like `ga::AbilityDefinitionDesc` (see that
// class's header comment) rather than `TypedArray<GameplayAbilityDefinition>`
// directly -- widening that native binding is out of this task's edit scope
// (native/godot/gameplay_ability_component.h/.cpp is frozen here). Use
// `GameplayAbilityDefinitionBridge.to_dictionary()`
// (runtime/ga_ability_definition_bridge.gd) to convert an authored resource
// into the exact Dictionary shape the component already accepts.
class GameplayAbilityDefinition : public Resource {
	GDCLASS(GameplayAbilityDefinition, Resource)

public:
	// Mirrors ga::ActivationPolicy.
	enum ActivationPolicy {
		ACTIVATION_MANUAL = 0,
		ACTIVATION_GAMEPLAY_EVENT = 1,
		ACTIVATION_PASSIVE_ON_GRANT = 2,
	};

	// Mirrors ga::AbilityConcurrencyPolicy.
	enum ConcurrencyPolicy {
		CONCURRENCY_REJECT_IF_ACTIVE = 0,
		CONCURRENCY_ALLOW_MULTIPLE = 1,
	};

	// Mirrors ga::AbilityDuplicateGrantPolicy.
	enum DuplicateGrantPolicy {
		DUPLICATE_GRANT_REJECT = 0,
		DUPLICATE_GRANT_REPLACE = 1,
		DUPLICATE_GRANT_MULTI_GRANT = 2,
	};

	// Mirrors ga::AbilityRevokePolicy.
	enum RevokePolicy {
		REVOKE_CANCEL_ACTIVE = 0,
		REVOKE_PERMIT_COMPLETION = 1,
	};

	// Mirrors ga::AbilityPredictionPolicy.
	enum PredictionPolicy {
		PREDICTION_NOT_PREDICTABLE = 0,
		PREDICTION_PREDICTABLE = 1,
	};

	// Mirrors ga::AbilityHookBinding.
	enum HookBinding {
		HOOK_BINDING_NONE = 0,
		HOOK_BINDING_AUTHORITY_ONLY = 1,
		HOOK_BINDING_PREDICTION_SAFE = 2,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_activation_policy(ActivationPolicy p_policy);
	ActivationPolicy get_activation_policy() const { return activation_policy; }

	// Evaluated against the OWNER's own tags at request time.
	void set_required_tags(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_required_tags() const { return required_tags; }

	void set_blocked_tags(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_blocked_tags() const { return blocked_tags; }

	// Granted to the owner for as long as an execution of this ability stays
	// ACTIVE.
	void set_owned_tags(const PackedStringArray &p_tags);
	PackedStringArray get_owned_tags() const { return owned_tags; }

	// Evaluated against the OWNER's tags while an execution is ACTIVE;
	// satisfying it cancels that execution.
	void set_cancel_tags(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_cancel_tags() const { return cancel_tags; }

	// Effect identifier, or empty for none. Applied source == target == the
	// owner, exactly like any other effect (design.md "Ability Costs and
	// Cooldowns as Effects").
	void set_cost_effect(const StringName &p_identifier);
	StringName get_cost_effect() const { return cost_effect; }

	void set_cooldown_effect(const StringName &p_identifier);
	StringName get_cooldown_effect() const { return cooldown_effect; }

	// Declared effects applied to the owner atomically at commit, alongside
	// cost/cooldown/owned tags.
	void set_commit_effects(const PackedStringArray &p_identifiers);
	PackedStringArray get_commit_effects() const { return commit_effects; }

	void set_triggers(const TypedArray<GameplayAbilityTrigger> &p_triggers);
	TypedArray<GameplayAbilityTrigger> get_triggers() const { return triggers; }

	void set_concurrency_policy(ConcurrencyPolicy p_policy);
	ConcurrencyPolicy get_concurrency_policy() const { return concurrency_policy; }

	void set_duplicate_grant_policy(DuplicateGrantPolicy p_policy);
	DuplicateGrantPolicy get_duplicate_grant_policy() const { return duplicate_grant_policy; }

	void set_revoke_policy(RevokePolicy p_policy);
	RevokePolicy get_revoke_policy() const { return revoke_policy; }

	// Declaring PREDICTION_PREDICTABLE subjects this definition to the
	// prediction-safety validation
	// `GameplayDefinitionValidator::validate_prediction_eligibility_seam`
	// runs (`ga::validate_prediction_eligibility`).
	void set_prediction_policy(PredictionPolicy p_policy);
	PredictionPolicy get_prediction_policy() const { return prediction_policy; }

	void set_hook_binding(HookBinding p_binding);
	HookBinding get_hook_binding() const { return hook_binding; }

	// If false, activation stops at the BEGUN phase and something must call
	// commit explicitly. If true (the common case), begin and commit happen
	// in one call.
	void set_auto_commit(bool p_auto_commit);
	bool get_auto_commit() const { return auto_commit; }

	// If true (the common case), a successful commit immediately ends the
	// execution. If false, the execution remains ACTIVE (e.g. a channel).
	void set_ends_on_commit(bool p_ends_on_commit);
	bool get_ends_on_commit() const { return ends_on_commit; }

	// Author's own declaration of prediction-safe eligibility; only
	// meaningful when prediction_policy == PREDICTION_PREDICTABLE (the
	// validator's conformance check enforces the rest -- see
	// `ga::AbilityDefinitionDesc::prediction_safe_declared`'s own doc
	// comment for exactly what this static check can and cannot verify).
	void set_prediction_safe_declared(bool p_declared);
	bool get_prediction_safe_declared() const { return prediction_safe_declared; }

	// Names a `GameplayTargetDataSchema` (native/resources/gameplay_target_data_schema.h)
	// this ability's activation-command target data must conform to, or empty
	// for "no per-ability schema, only the global bounds apply" (task 7.16).
	// Resolved against `GameplayAbilityComponent.target_data_schemas` at
	// `configure()` time -- see that class's doc comment. An unresolvable
	// identifier here is a configuration error, exactly like an unresolvable
	// `cost_effect`/`cooldown_effect` reference.
	void set_target_schema(const StringName &p_identifier);
	StringName get_target_schema() const { return target_schema; }

protected:
	static void _bind_methods();
	// Hides `prediction_safe_declared` unless prediction_policy ==
	// PREDICTION_PREDICTABLE, so the inspector never suggests it means
	// anything for a non-predictable ability.
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	ActivationPolicy activation_policy = ACTIVATION_MANUAL;

	Ref<GameplayTagQueryResource> required_tags;
	Ref<GameplayTagQueryResource> blocked_tags;
	PackedStringArray owned_tags;
	Ref<GameplayTagQueryResource> cancel_tags;

	StringName cost_effect;
	StringName cooldown_effect;
	PackedStringArray commit_effects;

	TypedArray<GameplayAbilityTrigger> triggers;

	ConcurrencyPolicy concurrency_policy = CONCURRENCY_REJECT_IF_ACTIVE;
	DuplicateGrantPolicy duplicate_grant_policy = DUPLICATE_GRANT_REJECT;
	RevokePolicy revoke_policy = REVOKE_CANCEL_ACTIVE;
	PredictionPolicy prediction_policy = PREDICTION_NOT_PREDICTABLE;
	HookBinding hook_binding = HOOK_BINDING_NONE;

	bool auto_commit = true;
	bool ends_on_commit = true;
	bool prediction_safe_declared = false;
	StringName target_schema;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayAbilityDefinition::ActivationPolicy);
VARIANT_ENUM_CAST(GameplayAbilityDefinition::ConcurrencyPolicy);
VARIANT_ENUM_CAST(GameplayAbilityDefinition::DuplicateGrantPolicy);
VARIANT_ENUM_CAST(GameplayAbilityDefinition::RevokePolicy);
VARIANT_ENUM_CAST(GameplayAbilityDefinition::PredictionPolicy);
VARIANT_ENUM_CAST(GameplayAbilityDefinition::HookBinding);

#endif // GAMEPLAY_ABILITIES_RESOURCES_ABILITY_DEFINITION_H
