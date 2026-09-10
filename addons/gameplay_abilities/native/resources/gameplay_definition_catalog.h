#ifndef GAMEPLAY_ABILITIES_RESOURCES_DEFINITION_CATALOG_H
#define GAMEPLAY_ABILITIES_RESOURCES_DEFINITION_CATALOG_H

#include "resources/gameplay_ability_definition.h"
#include "resources/gameplay_attribute_definition.h"
#include "resources/gameplay_cue_definition.h"
#include "resources/gameplay_effect_definition.h"
#include "resources/gameplay_tag_definition.h"
#include "resources/gameplay_tag_reaction_definition.h"
#include "resources/gameplay_target_data_schema.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// The project-wide, explicit source of definition identity (design.md
// decision 1 "Use a unified project definition catalog";
// specs/gameplay-definition-authoring/spec.md "Project-Wide Gameplay
// Definition Catalog"). A `GameplayAbilityComponent` resolves AT MOST one
// catalog at `configure()` time -- its own `definition_catalog` override,
// else the project setting `gameplay_abilities/default_definition_catalog`,
// else no catalog at all -- and registers the resolved catalog's
// collections into its OWN sealed, component-local core registries exactly
// like the legacy per-component definition arrays it replaces (see that
// class's `configure()`).
//
// This resource is deliberately just data, like every other definition
// Resource in this addon: it owns no runtime registry, tag container, or
// mutable gameplay state of its own. "Global" here means globally defined
// identity, never globally shared runtime state (proposal.md "Why";
// design.md's "Keep runtime tag ownership ... component-scoped").
//
// `tag_reactions` is the one collection with no sealed core-registry
// counterpart yet: `GameplayTagReactionDefinition` is presently a
// data-only shell (see that class's header comment) that a later change in
// this same spec wires into real cross-reference/cycle validation and
// dispatch. It still fully participates in this task's identifier-level
// catalog validation and content-manifest fingerprint contribution (see
// `GameplayDefinitionValidator::validate_catalog` and
// `GameplayAbilityComponent::configure()`).
class GameplayDefinitionCatalog : public Resource {
	GDCLASS(GameplayDefinitionCatalog, Resource)

public:
	void set_tag_definitions(const TypedArray<GameplayTagDefinition> &p_tags);
	TypedArray<GameplayTagDefinition> get_tag_definitions() const { return tag_definitions; }

	void set_attribute_definitions(const TypedArray<GameplayAttributeDefinition> &p_attributes);
	TypedArray<GameplayAttributeDefinition> get_attribute_definitions() const { return attribute_definitions; }

	void set_effect_definitions(const TypedArray<GameplayEffectDefinition> &p_effects);
	TypedArray<GameplayEffectDefinition> get_effect_definitions() const { return effect_definitions; }

	void set_ability_definitions(const TypedArray<GameplayAbilityDefinition> &p_abilities);
	TypedArray<GameplayAbilityDefinition> get_ability_definitions() const { return ability_definitions; }

	void set_cue_definitions(const TypedArray<GameplayCueDefinition> &p_cues);
	TypedArray<GameplayCueDefinition> get_cue_definitions() const { return cue_definitions; }

	void set_target_data_schemas(const TypedArray<GameplayTargetDataSchema> &p_schemas);
	TypedArray<GameplayTargetDataSchema> get_target_data_schemas() const { return target_data_schemas; }

	// Declarative tag-reaction definitions (design.md decision 3). See this
	// class's own header comment for exactly what task 1 does and does not
	// implement for this collection yet.
	void set_tag_reactions(const TypedArray<GameplayTagReactionDefinition> &p_reactions);
	TypedArray<GameplayTagReactionDefinition> get_tag_reactions() const { return tag_reactions; }

protected:
	static void _bind_methods();

private:
	TypedArray<GameplayTagDefinition> tag_definitions;
	TypedArray<GameplayAttributeDefinition> attribute_definitions;
	TypedArray<GameplayEffectDefinition> effect_definitions;
	TypedArray<GameplayAbilityDefinition> ability_definitions;
	TypedArray<GameplayCueDefinition> cue_definitions;
	TypedArray<GameplayTargetDataSchema> target_data_schemas;
	TypedArray<GameplayTagReactionDefinition> tag_reactions;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_DEFINITION_CATALOG_H
