#ifndef GAMEPLAY_ABILITIES_RESOURCES_MODIFIER_DECLARATION_H
#define GAMEPLAY_ABILITIES_RESOURCES_MODIFIER_DECLARATION_H

#include "resources/gameplay_magnitude.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::ModifierDeclarationDesc`
// (native/core/ga_effects.h): one declared attribute modifier an effect
// applies. `op` mirrors `ga::ModifierOp` (native/core/ga_attribute_state.h)
// exactly -- ADD, MULTIPLY, OVERRIDE, evaluated in that phase order.
class GameplayModifierDeclaration : public Resource {
	GDCLASS(GameplayModifierDeclaration, Resource)

public:
	enum Op {
		OP_ADD = 0,
		OP_MULTIPLY = 1,
		OP_OVERRIDE = 2,
	};

	void set_target_attribute(const StringName &p_attribute);
	StringName get_target_attribute() const { return target_attribute; }

	void set_op(Op p_op);
	Op get_op() const { return op; }

	void set_magnitude(const Ref<GameplayMagnitude> &p_magnitude);
	Ref<GameplayMagnitude> get_magnitude() const { return magnitude; }

	// Stable priority tie-breaker within a phase (see ga_attribute_state.h).
	void set_priority(int p_priority);
	int get_priority() const { return priority; }

protected:
	static void _bind_methods();

private:
	StringName target_attribute;
	Op op = OP_ADD;
	Ref<GameplayMagnitude> magnitude;
	int priority = 0;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayModifierDeclaration::Op);

#endif // GAMEPLAY_ABILITIES_RESOURCES_MODIFIER_DECLARATION_H
