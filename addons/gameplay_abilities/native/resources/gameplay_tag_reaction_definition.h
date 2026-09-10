#ifndef GAMEPLAY_ABILITIES_RESOURCES_TAG_REACTION_DEFINITION_H
#define GAMEPLAY_ABILITIES_RESOURCES_TAG_REACTION_DEFINITION_H

#include "resources/gameplay_tag_operand.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored declaration of "when this tag operand's effective truth
// value transitions, apply this effect to the owning component"
// (design.md decision 3 "Model reactions as immutable registered
// definitions"; proposal.md's tag-reaction additions). Deliberately just
// data, matching every other definition Resource in this addon
// (GameplayTagDefinition, GameplayEffectDefinition, ...): registration into
// a sealed core registry, predicate-edge evaluation, the deferred dispatch
// queue, cycle validation, and authority/network restrictions are ALL a
// later change in this same spec (design.md decisions 3-6, tasks 3.1-5.6).
// This class has NO runtime behavior of its own yet -- it exists so
// `GameplayDefinitionCatalog` has a stable, bindable collection member for
// reaction identity, and so identifier-level validation and the
// content-manifest fingerprint (see
// `GameplayDefinitionValidator::validate_catalog`,
// `GameplayAbilityComponent::configure()`, native/core/ga_tag_reactions.h)
// can already cover it.
class GameplayTagReactionDefinition : public Resource {
	GDCLASS(GameplayTagReactionDefinition, Resource)

public:
	// Mirrors `ga::TagReactionMode` (native/core/ga_tag_reactions.h) exactly.
	enum Mode {
		MODE_ON_ADDED = 0,
		MODE_ON_REMOVED = 1,
		MODE_WHILE_PRESENT = 2,
	};

	void set_identifier(const StringName &p_identifier);
	StringName get_identifier() const { return identifier; }

	// The tag predicate this reaction observes -- exact or parent-aware, per
	// `GameplayTagOperand::MatchMode` (see that class's header comment).
	void set_operand(const Ref<GameplayTagOperand> &p_operand);
	Ref<GameplayTagOperand> get_operand() const { return operand; }

	void set_mode(Mode p_mode);
	Mode get_mode() const { return mode; }

	// The effect this reaction applies to its own owning component -- v1 is
	// self-target only (design.md decision 3). Resolved against the same
	// catalog's `effect_definitions` by a later change's validation pass;
	// this task only checks that the string is present (see
	// `GameplayDefinitionValidator::validate_catalog`).
	void set_effect_identifier(const StringName &p_identifier);
	StringName get_effect_identifier() const { return effect_identifier; }

protected:
	static void _bind_methods();

private:
	StringName identifier;
	Ref<GameplayTagOperand> operand;
	Mode mode = MODE_ON_ADDED;
	StringName effect_identifier;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayTagReactionDefinition::Mode);

#endif // GAMEPLAY_ABILITIES_RESOURCES_TAG_REACTION_DEFINITION_H
