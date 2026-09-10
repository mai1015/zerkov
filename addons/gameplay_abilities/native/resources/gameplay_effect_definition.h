#ifndef GAMEPLAY_ABILITIES_RESOURCES_EFFECT_DEFINITION_H
#define GAMEPLAY_ABILITIES_RESOURCES_EFFECT_DEFINITION_H

#include "resources/gameplay_modifier_declaration.h"
#include "resources/gameplay_set_by_caller_field.h"
#include "resources/gameplay_stacking_policy.h"
#include "resources/gameplay_tag_query_resource.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Editor-authored counterpart of `ga::EffectDefinitionDesc`
// (native/core/ga_effects.h). Every reference field here (modifiers' target
// attributes, granted tags, requirement/immunity queries, stacking overflow
// effect, cue identifiers, set-by-caller fields) is validated and resolved
// against the sealed tag/attribute/effect registries by
// `GameplayDefinitionValidator` -- never by this class, which is pure data.
class GameplayEffectDefinition : public Resource {
	GDCLASS(GameplayEffectDefinition, Resource)

public:
	enum DurationPolicy {
		DURATION_INSTANT = 0,
		DURATION_DURATION = 1,
		DURATION_INFINITE = 2,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	void set_duration_policy(DurationPolicy p_policy);
	DurationPolicy get_duration_policy() const { return duration_policy; }

	// Meaningful only when duration_policy == DURATION_DURATION.
	void set_duration_ticks(int64_t p_ticks);
	int64_t get_duration_ticks() const { return duration_ticks; }

	void set_has_period(bool p_has_period);
	bool get_has_period() const { return has_period; }

	// Meaningful only when has_period is true.
	void set_period_ticks(int64_t p_ticks);
	int64_t get_period_ticks() const { return period_ticks; }

	void set_modifiers(const TypedArray<GameplayModifierDeclaration> &p_modifiers);
	TypedArray<GameplayModifierDeclaration> get_modifiers() const { return modifiers; }

	void set_granted_tags(const PackedStringArray &p_tags);
	PackedStringArray get_granted_tags() const { return granted_tags; }

	void set_source_requirements(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_source_requirements() const { return source_requirements; }

	void set_target_requirements(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_target_requirements() const { return target_requirements; }

	// Evaluated against the TARGET only; satisfying it rejects application.
	void set_immunity(const Ref<GameplayTagQueryResource> &p_query);
	Ref<GameplayTagQueryResource> get_immunity() const { return immunity; }

	void set_stacking(const Ref<GameplayStackingPolicy> &p_stacking);
	Ref<GameplayStackingPolicy> get_stacking() const { return stacking; }

	void set_set_by_caller_fields(const TypedArray<GameplaySetByCallerField> &p_fields);
	TypedArray<GameplaySetByCallerField> get_set_by_caller_fields() const { return set_by_caller_fields; }

	// Must each already be declared by a `GameplayCueDefinition` in the same
	// validated asset set.
	void set_cue_identifiers(const PackedStringArray &p_identifiers);
	PackedStringArray get_cue_identifiers() const { return cue_identifiers; }

	// Declares eligibility for the v1 prediction-safe self-effect set. Full
	// prediction conformance is validated by the ability layer (out of scope
	// here -- see GameplayDefinitionValidator's documented seam).
	void set_prediction_safe(bool p_prediction_safe);
	bool get_prediction_safe() const { return prediction_safe; }

	// Duration/infinite effects that need validated target metadata for
	// later periodic calculations or restored cues opt into retaining the
	// bounded canonical TargetEffectContext in active state/snapshots.
	void set_retain_target_context(bool p_retain);
	bool get_retain_target_context() const {
		return retain_target_context;
	}

protected:
	static void _bind_methods();
	// Hides duration_ticks unless duration_policy == DURATION_DURATION, and
	// period_ticks unless has_period is true.
	void _validate_property(PropertyInfo &p_property) const;

private:
	StringName identifier;
	DurationPolicy duration_policy = DURATION_INSTANT;
	int64_t duration_ticks = 0;
	bool has_period = false;
	int64_t period_ticks = 0;
	TypedArray<GameplayModifierDeclaration> modifiers;
	PackedStringArray granted_tags;
	Ref<GameplayTagQueryResource> source_requirements;
	Ref<GameplayTagQueryResource> target_requirements;
	Ref<GameplayTagQueryResource> immunity;
	Ref<GameplayStackingPolicy> stacking;
	TypedArray<GameplaySetByCallerField> set_by_caller_fields;
	PackedStringArray cue_identifiers;
	bool prediction_safe = false;
	bool retain_target_context = false;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayEffectDefinition::DurationPolicy);

#endif // GAMEPLAY_ABILITIES_RESOURCES_EFFECT_DEFINITION_H
