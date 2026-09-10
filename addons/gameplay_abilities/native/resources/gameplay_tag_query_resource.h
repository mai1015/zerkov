#ifndef GAMEPLAY_ABILITIES_RESOURCES_TAG_QUERY_RESOURCE_H
#define GAMEPLAY_ABILITIES_RESOURCES_TAG_QUERY_RESOURCE_H

#include "resources/gameplay_tag_operand.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Editor-authored counterpart of `ga::TagRequirementDesc`
// (native/core/ga_effects.h): an implicit AND of an all-list, an any-list,
// and a none-list, matching the shape `ga::TagQuery::build_requirements`
// consumes -- not the fully general nested `ga::TagQuery` tree, which this
// addon's authoring layer deliberately does not expose (see
// native/core/ga_tag_query.h's `compose`/`build_requirements` split). Any
// operand list may be left empty; an entirely empty resource is the trivial
// always-true query.
//
// `GameplayDefinitionValidator` resolves every operand's tag identifier
// against a sealed `ga::TagRegistry` and calls `ga::TagQuery::build_requirements`
// to obtain the normalized, depth/operand-bounded core value -- this class
// never re-implements query normalization or evaluation itself.
class GameplayTagQueryResource : public Resource {
	GDCLASS(GameplayTagQueryResource, Resource)

public:
	void set_all_of(const TypedArray<GameplayTagOperand> &p_operands);
	TypedArray<GameplayTagOperand> get_all_of() const { return all_of; }

	void set_any_of(const TypedArray<GameplayTagOperand> &p_operands);
	TypedArray<GameplayTagOperand> get_any_of() const { return any_of; }

	void set_none_of(const TypedArray<GameplayTagOperand> &p_operands);
	TypedArray<GameplayTagOperand> get_none_of() const { return none_of; }

protected:
	static void _bind_methods();

private:
	TypedArray<GameplayTagOperand> all_of;
	TypedArray<GameplayTagOperand> any_of;
	TypedArray<GameplayTagOperand> none_of;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_RESOURCES_TAG_QUERY_RESOURCE_H
