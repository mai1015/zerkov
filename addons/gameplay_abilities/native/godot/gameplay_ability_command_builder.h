#ifndef GAMEPLAY_ABILITIES_GODOT_ABILITY_COMMAND_BUILDER_H
#define GAMEPLAY_ABILITIES_GODOT_ABILITY_COMMAND_BUILDER_H

#include "core/ga_ability_component.h"
#include "resources/gameplay_ability_task_request.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

// Task 6.10: the Callable-facing wrapper around `ga::AbilityCommandBuilder&`
// a script-authored hook receives. Mirrors `addons/common_ui/native/godot/`'s
// own "wrap a core collaborator behind a RefCounted handle, invalidate it the
// instant the borrowed pointer stops being valid" precedent (see
// `CommonUIActionHandle`) -- here the borrowed `ga::AbilityCommandBuilder*`
// is only ever valid for the duration of ONE synchronous
// `AuthorityAbilityHook::execute`/`PredictionSafeAbilityHook::execute` call
// (it lives on `AbilityComponent::commit_execution_body`'s own stack), so a
// script that stashes this Ref anywhere and calls `submit` later gets a
// harmless `STATUS_HOOK_FAILED` instead of touching freed memory.
namespace godot {

class GameplayAbilityComponent;

class GameplayAbilityCommandBuilder : public RefCounted {
	GDCLASS(GameplayAbilityCommandBuilder, RefCounted)

public:
	// Submits an `AbilityHookCommand`-shaped Dictionary:
	//   { kind: int,                 # 0 APPLY_SELF_EFFECT, 1 APPLY_TARGET_EFFECT, 2 EMIT_GAMEPLAY_EVENT
	//     effect_definition: String, # APPLY_SELF_EFFECT / APPLY_TARGET_EFFECT
	//     explicit_target: int,      # APPLY_TARGET_EFFECT only
	//     set_by_caller: Array[Dictionary{field:String, value:float}],
	//     event: Dictionary{event_tag:String, instigator:int, target:int, magnitude:float, payload_tag:int} } # EMIT_GAMEPLAY_EVENT only
	// Returns {status: Dictionary}. Every capability rule
	// `ga::AbilityCommandBuilder::submit` already enforces (sticky rejection,
	// prediction-safe mode restricted to a prediction-safe non-periodic self
	// effect, target must already be one of this execution's own targets)
	// applies unchanged -- this method never second-guesses or relaxes it.
	Dictionary submit(const Dictionary &p_command);
	Dictionary request_task(
			const Ref<GameplayAbilityTaskRequest> &p_request);

	// Internal wiring, called only from gameplay_ability_hook_bridge.cpp --
	// never exposed to ClassDB (a raw core pointer cannot be Variant-marshalled).
	void _bind_native(ga::AbilityCommandBuilder *p_native, GameplayAbilityComponent *p_owner) {
		native = p_native;
		owner = p_owner;
	}
	// Called unconditionally the instant the owning hook's Callable returns,
	// so a script that retained this Ref cannot use it afterward.
	void _invalidate() {
		native = nullptr;
		owner = nullptr;
	}

protected:
	static void _bind_methods();

private:
	ga::AbilityCommandBuilder *native = nullptr;
	GameplayAbilityComponent *owner = nullptr;
};

} // namespace godot

#endif // GAMEPLAY_ABILITIES_GODOT_ABILITY_COMMAND_BUILDER_H
