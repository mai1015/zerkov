#include "godot/gameplay_ability_hook_bridge.h"

#include "godot/gameplay_ability_command_builder.h"
#include "godot/gameplay_ability_component.h"

namespace godot {

ga::Status interpret_script_hook_result(const Variant &p_result) {
	switch (p_result.get_type()) {
		case Variant::NIL:
			return ga::ok_status();
		case Variant::BOOL:
			return bool(p_result) ? ga::ok_status() : ga::make_status(ga::StatusCode::HOOK_FAILED);
		default:
			// Garbage return (a String, Dictionary, Object, number, ...) --
			// bounded diagnostic, never an attempt to coerce or interpret it.
			return ga::make_status(ga::StatusCode::HOOK_FAILED);
	}
}

ga::Status ScriptAuthorityAbilityHook::execute(const ga::AbilityExecutionContext &p_context, ga::AbilityCommandBuilder &p_commands) {
	if (owner == nullptr || !callable.is_valid()) {
		return ga::make_status(ga::StatusCode::HOOK_FAILED);
	}
	const Dictionary context_dict = owner->ability_execution_context_dict(p_context);
	Ref<GameplayAbilityCommandBuilder> builder;
	builder.instantiate();
	builder->_bind_native(&p_commands, owner);

	const Variant result = callable.call(context_dict, builder);
	builder->_invalidate();

	return interpret_script_hook_result(result);
}

ga::Status ScriptAuthorityAbilityHook::on_task_event(
		const ga::AbilityExecutionContext &p_context,
		const ga::AbilityTaskEvent &p_event,
		ga::AbilityCommandBuilder &p_commands) {
	if (owner == nullptr || !task_callable.is_valid()) {
		return ga::ok_status();
	}
	Ref<GameplayAbilityCommandBuilder> builder;
	builder.instantiate();
	builder->_bind_native(&p_commands, owner);
	const Variant result = task_callable.call(
			owner->ability_execution_context_dict(p_context),
			owner->ability_task_event_dict(p_event), builder);
	builder->_invalidate();
	return interpret_script_hook_result(result);
}

ga::Status ScriptPredictionSafeAbilityHook::execute(const ga::AbilityExecutionContext &p_context, ga::AbilityCommandBuilder &p_commands) {
	if (owner == nullptr || !callable.is_valid()) {
		return ga::make_status(ga::StatusCode::HOOK_FAILED);
	}
	const Dictionary context_dict = owner->ability_execution_context_dict(p_context);
	Ref<GameplayAbilityCommandBuilder> builder;
	builder.instantiate();
	builder->_bind_native(&p_commands, owner);

	const Variant result = callable.call(context_dict, builder);
	builder->_invalidate();

	return interpret_script_hook_result(result);
}

ga::Status ScriptPredictionSafeAbilityHook::on_task_event(
		const ga::AbilityExecutionContext &p_context,
		const ga::AbilityTaskEvent &p_event,
		ga::AbilityCommandBuilder &p_commands) {
	if (owner == nullptr || !task_callable.is_valid()) {
		return ga::ok_status();
	}
	Ref<GameplayAbilityCommandBuilder> builder;
	builder.instantiate();
	builder->_bind_native(&p_commands, owner);
	const Variant result = task_callable.call(
			owner->ability_execution_context_dict(p_context),
			owner->ability_task_event_dict(p_event), builder);
	builder->_invalidate();
	return interpret_script_hook_result(result);
}

} // namespace godot
