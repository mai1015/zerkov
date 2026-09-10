#include "godot/gameplay_ability_command_builder.h"

#include "godot/gameplay_ability_component.h"
#include "godot/gameplay_ability_godot_util.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

Dictionary GameplayAbilityCommandBuilder::submit(const Dictionary &p_command) {
	Dictionary result;
	if (native == nullptr || owner == nullptr) {
		// Either never bound, or already invalidated (the owning hook call
		// already returned) -- see `_invalidate()`'s doc comment.
		result["status"] = status_dict(ga::make_status(ga::StatusCode::HOOK_FAILED));
		return result;
	}

	const int kind_raw = int(p_command.get("kind", 0));
	if (kind_raw < 0 ||
			kind_raw > int(ga::AbilityHookCommandKind::CANCEL_EXECUTION)) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return result;
	}

	ga::AbilityHookCommand command;
	command.kind = static_cast<ga::AbilityHookCommandKind>(kind_raw);

	if (command.kind == ga::AbilityHookCommandKind::APPLY_SELF_EFFECT ||
			command.kind == ga::AbilityHookCommandKind::APPLY_TARGET_EFFECT) {
		command.effect_definition = owner->resolve_effect_definition_id(to_std(String(p_command.get("effect_definition", String()))));
		command.explicit_target = to_entity_id(int64_t(p_command.get("explicit_target", 0)));
		// Finding 6d: shared fail-closed converter (GameplayAbilityComponent::
		// parse_set_by_caller_fields) -- this call site used to silently
		// truncate at MAX_SET_BY_CALLER and substitute a zero magnitude for a
		// value that failed quantization; a malformed `set_by_caller` now
		// rejects the whole hook command instead.
		if (p_command.has("set_by_caller")) {
			const Array fields = p_command["set_by_caller"];
			if (!GameplayAbilityComponent::parse_set_by_caller_fields(fields, command.set_by_caller)) {
				result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
				return result;
			}
		}
	} else if (command.kind ==
			ga::AbilityHookCommandKind::EMIT_GAMEPLAY_EVENT) {
		const Dictionary event_dict = p_command.get("event", Dictionary());
		ga::GameplayEventContext event;
		// Best-effort: an unresolvable event_tag leaves `event` at its
		// zeroed/INVALID default, which `AbilityCommandBuilder::submit`
		// forwards unchanged -- the SAME "unknown reference simply fails
		// downstream, never a special case here" posture the rest of this
		// file already takes for effect identifiers.
		owner->build_gameplay_event(event_dict, event);
		command.event = event;
	} else if (command.kind == ga::AbilityHookCommandKind::START_TASK) {
		const Ref<GameplayAbilityTaskRequest> task_request =
				p_command.get("task_request",
						Ref<GameplayAbilityTaskRequest>());
		if (!owner->build_ability_task_request(
					task_request, command.task_request)) {
			result["status"] = status_dict(ga::make_status(
					ga::StatusCode::INVALID_ABILITY_TASK,
					ga::DiagnosticId::INVALID_TASK_PAYLOAD));
			return result;
		}
	} else if (command.kind == ga::AbilityHookCommandKind::CANCEL_TASK) {
		const int64_t raw_task = p_command.get("task", int64_t(0));
		const int reason = p_command.get("cancel_reason",
				int(ga::AbilityTaskCancelReason::EXPLICIT));
		if (raw_task <= 0 || reason < 0 ||
				reason > int(ga::AbilityTaskCancelReason::
									 TARGET_SESSION_CANCELLED)) {
			result["status"] = status_dict(ga::make_status(
					ga::StatusCode::INVALID_ARGUMENT));
			return result;
		}
		command.task =
				ga::AbilityTaskHandle{ static_cast<uint64_t>(raw_task) };
		command.task_cancel_reason =
				static_cast<ga::AbilityTaskCancelReason>(reason);
	}

	const ga::Status status = native->submit(command);
	result["status"] = status_dict(status);
	return result;
}

Dictionary GameplayAbilityCommandBuilder::request_task(
		const Ref<GameplayAbilityTaskRequest> &p_request) {
	Dictionary result;
	if (native == nullptr || owner == nullptr) {
		result["status"] = status_dict(
				ga::make_status(ga::StatusCode::HOOK_FAILED));
		result["task"] = int64_t(0);
		return result;
	}
	ga::AbilityTaskRequest request;
	if (!owner->build_ability_task_request(p_request, request)) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::INVALID_ABILITY_TASK,
				ga::DiagnosticId::INVALID_TASK_PAYLOAD));
		result["task"] = int64_t(0);
		return result;
	}
	ga::AbilityTaskHandle task;
	const ga::Status status = native->request_task(request, task);
	result["status"] = status_dict(status);
	result["task"] = int64_t(task.value);
	return result;
}

void GameplayAbilityCommandBuilder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("submit", "command"), &GameplayAbilityCommandBuilder::submit);
	ClassDB::bind_method(D_METHOD("request_task", "request"),
			&GameplayAbilityCommandBuilder::request_task);
}

} // namespace godot
