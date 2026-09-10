#ifndef GAMEPLAY_ABILITIES_RESOURCES_STACKING_POLICY_H
#define GAMEPLAY_ABILITIES_RESOURCES_STACKING_POLICY_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {

// Editor-authored counterpart of `ga::StackingPolicyDesc`
// (native/core/ga_effects.h). See that header for the exact runtime meaning
// of every field; this class only carries the authored values through to
// `GameplayDefinitionValidator`, which builds the sealed `ga::StackingPolicy`.
class GameplayStackingPolicy : public Resource {
	GDCLASS(GameplayStackingPolicy, Resource)

public:
	enum SourceScope {
		// Each applying source owns its own independent stack group on a
		// given target.
		SOURCE_SCOPED = 0,
		// Every application against a given target shares one stack group
		// regardless of source.
		TARGET_SCOPED = 1,
	};

	enum OverflowPolicy {
		// Reject the new application outright.
		OVERFLOW_REJECT = 0,
		// Keep the stack count at maximum but still refresh/reset per policy.
		OVERFLOW_REFRESH = 1,
		// Tear down and rebuild the active instance fresh under the same handle.
		OVERFLOW_REPLACE = 2,
		// Leave the stack group untouched and additionally apply
		// `overflow_effect` as its own independent application.
		OVERFLOW_APPLY_EFFECT = 3,
	};

	enum RemovalRule {
		// One removal decrements the stack count by one.
		REMOVE_SINGLE_STACK = 0,
		// One removal tears down the entire active instance immediately.
		REMOVE_ALL_STACKS = 1,
	};

	void set_stackable(bool p_stackable);
	bool is_stackable() const { return stackable; }

	// Canonical stacking key. Left empty, defaults to the owning effect's own
	// identifier at validation time.
	void set_stack_key(const String &p_key);
	String get_stack_key() const { return stack_key; }

	void set_source_scope(SourceScope p_scope);
	SourceScope get_source_scope() const { return source_scope; }

	void set_max_stacks(int p_max_stacks);
	int get_max_stacks() const { return max_stacks; }

	void set_overflow_policy(OverflowPolicy p_policy);
	OverflowPolicy get_overflow_policy() const { return overflow_policy; }

	void set_refresh_duration_on_add(bool p_refresh);
	bool is_refresh_duration_on_add() const { return refresh_duration_on_add; }

	void set_reset_period_on_add(bool p_reset);
	bool is_reset_period_on_add() const { return reset_period_on_add; }

	void set_removal_rule(RemovalRule p_rule);
	RemovalRule get_removal_rule() const { return removal_rule; }

	// Only meaningful (and only permitted to be non-empty) when
	// overflow_policy == OVERFLOW_APPLY_EFFECT.
	void set_overflow_effect(const StringName &p_effect);
	StringName get_overflow_effect() const { return overflow_effect; }

protected:
	static void _bind_methods();
	// Hides every stacking-shape field when `stackable` is off, and hides
	// `overflow_effect` unless the overflow policy actually uses it.
	void _validate_property(PropertyInfo &p_property) const;

private:
	bool stackable = false;
	String stack_key;
	SourceScope source_scope = SOURCE_SCOPED;
	int max_stacks = 1;
	OverflowPolicy overflow_policy = OVERFLOW_REJECT;
	bool refresh_duration_on_add = true;
	bool reset_period_on_add = true;
	RemovalRule removal_rule = REMOVE_SINGLE_STACK;
	StringName overflow_effect;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayStackingPolicy::SourceScope);
VARIANT_ENUM_CAST(GameplayStackingPolicy::OverflowPolicy);
VARIANT_ENUM_CAST(GameplayStackingPolicy::RemovalRule);

#endif // GAMEPLAY_ABILITIES_RESOURCES_STACKING_POLICY_H
