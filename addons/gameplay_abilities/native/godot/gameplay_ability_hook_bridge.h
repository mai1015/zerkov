#ifndef GAMEPLAY_ABILITIES_GODOT_ABILITY_HOOK_BRIDGE_H
#define GAMEPLAY_ABILITIES_GODOT_ABILITY_HOOK_BRIDGE_H

#include "core/ga_ability_component.h"

#include <godot_cpp/variant/callable.hpp>

// Task 6.10: Callable-based adapters implementing `ga::AuthorityAbilityHook`
// and `ga::PredictionSafeAbilityHook` so a game registers a hook with a
// GDScript Callable instead of a compiled C++ subclass (see
// `addons/gameplay_abilities/docs/hooks.md`'s "Known gap: no GDScript
// exposure exists yet", which this closes).
//
// Deliberately TWO separate classes with NO shared base, mirroring
// `ga_ability_component.h`'s own file comment on why
// `AuthorityAbilityHook`/`PredictionSafeAbilityHook` share no ancestor: an
// author who registers a script as prediction-safe has committed, at the
// type level, to the SAME structural guarantee a hand-written C++
// `PredictionSafeAbilityHook` subclass gets -- there is no cast or runtime
// flag that lets a `ScriptPredictionSafeAbilityHook` instance later behave
// like a `ScriptAuthorityAbilityHook` one. Both classes forward to the
// IDENTICAL core validation their C++ counterparts go through
// (`AbilityComponent::bind_authority_hook`/`bind_prediction_safe_hook`,
// `AbilityCommandBuilder::submit`) -- neither relaxes nor duplicates any
// rule from ga_ability_component.h/.cpp.
namespace godot {

class GameplayAbilityComponent;

// Interprets a script hook's `Callable::call` return value (task 6.10's "a
// script hook that throws/errors or returns garbage must fail the
// transaction with a bounded diagnostic -- never corrupt state"):
//   Nil          -> ok_status() (a plain `func(...) -> void` hook "just works")
//   bool         -> that value (true = ok; false = the hook deliberately failed)
//   anything else (including whatever a script that errored mid-call left
//                  behind) -> STATUS_HOOK_FAILED, a stable bounded code, never
//                  an unbounded string built from the garbage value itself.
// Every command the script already legitimately `submit()`-ed before
// returning still stands -- `submit()` only ever records a command AFTER
// validating it, and the core caller checks the sticky
// `AbilityCommandBuilder::violation_status()` unconditionally regardless of
// what this function returns (see ga_ability_component.cpp's
// commit_execution_body), so a mid-call script error can only ever mean
// "fewer commands were submitted than intended," never a corrupted or
// partially-applied one.
ga::Status interpret_script_hook_result(const Variant &p_result);

// Wraps a `Callable` as an `ga::AuthorityAbilityHook`. `p_owner` must outlive
// this instance -- `GameplayAbilityComponent` owns every adapter it creates
// for exactly this reason (see that class's `script_authority_hooks` member).
class ScriptAuthorityAbilityHook : public ga::AuthorityAbilityHook {
public:
	ScriptAuthorityAbilityHook(GameplayAbilityComponent *p_owner,
			const Callable &p_callable, const Callable &p_task_callable) :
			owner(p_owner), callable(p_callable),
			task_callable(p_task_callable) {}

	ga::Status execute(const ga::AbilityExecutionContext &p_context, ga::AbilityCommandBuilder &p_commands) override;
	ga::Status on_task_event(const ga::AbilityExecutionContext &p_context,
			const ga::AbilityTaskEvent &p_event,
			ga::AbilityCommandBuilder &p_commands) override;

private:
	GameplayAbilityComponent *owner = nullptr;
	Callable callable;
	Callable task_callable;
};

// Wraps a `Callable` as an `ga::PredictionSafeAbilityHook`. The four
// `depends_on_*`/`uses_unrestricted_callback` overrides return exactly what
// the script author declared at `GameplayAbilityComponent::bind_prediction_safe_hook`
// call time -- an HONEST self-declaration, exactly like the C++ interface's
// own contract (ga_ability_component.h), never something this adapter
// infers or verifies by inspection.
class ScriptPredictionSafeAbilityHook : public ga::PredictionSafeAbilityHook {
public:
	ScriptPredictionSafeAbilityHook(GameplayAbilityComponent *p_owner, const Callable &p_callable,
			bool p_depends_on_time, bool p_depends_on_randomness, bool p_depends_on_scene_or_physics,
			bool p_uses_unrestricted_callback,
			const Callable &p_task_callable) :
			owner(p_owner),
			callable(p_callable),
			task_callable(p_task_callable),
			time_dependence(p_depends_on_time),
			randomness_dependence(p_depends_on_randomness),
			scene_or_physics_dependence(p_depends_on_scene_or_physics),
			unrestricted_callback(p_uses_unrestricted_callback) {}

	ga::Status execute(const ga::AbilityExecutionContext &p_context, ga::AbilityCommandBuilder &p_commands) override;
	ga::Status on_task_event(const ga::AbilityExecutionContext &p_context,
			const ga::AbilityTaskEvent &p_event,
			ga::AbilityCommandBuilder &p_commands) override;

	bool depends_on_time() const override { return time_dependence; }
	bool depends_on_randomness() const override { return randomness_dependence; }
	bool depends_on_scene_or_physics() const override { return scene_or_physics_dependence; }
	bool uses_unrestricted_callback() const override { return unrestricted_callback; }

private:
	GameplayAbilityComponent *owner = nullptr;
	Callable callable;
	Callable task_callable;
	bool time_dependence = false;
	bool randomness_dependence = false;
	bool scene_or_physics_dependence = false;
	bool unrestricted_callback = false;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_GODOT_ABILITY_HOOK_BRIDGE_H
