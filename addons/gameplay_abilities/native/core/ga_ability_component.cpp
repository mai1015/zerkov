#include "core/ga_ability_component.h"

#include "core/ga_targeting.h"

#include <algorithm>
#include <utility>

namespace ga {

// ---------------------------------------------------------------------------
// AbilityExecutionContext
// ---------------------------------------------------------------------------

Status AbilityExecutionContext::find_owner_attribute(DefinitionId p_id, Fixed &r_out) const {
	for (const auto &entry : owner_attributes) {
		if (entry.first == p_id) {
			r_out = entry.second;
			return ok_status();
		}
	}
	return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_id);
}

// ---------------------------------------------------------------------------
// AbilityCommandBuilder
// ---------------------------------------------------------------------------

Status AbilityCommandBuilder::submit(const AbilityHookCommand &p_command) {
	if (!violation.ok()) {
		return violation; // sticky -- a hook cannot "retry past" a rejection
	}
	if (recorded.size() >= MAX_ABILITY_HOOK_COMMANDS) {
		violation = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, recorded.size());
		return violation;
	}

	if (prediction_safe_mode) {
		const bool prediction_lifecycle_command =
				p_command.kind == AbilityHookCommandKind::CANCEL_TASK ||
				p_command.kind == AbilityHookCommandKind::COMMIT_EXECUTION ||
				p_command.kind == AbilityHookCommandKind::END_EXECUTION ||
				p_command.kind == AbilityHookCommandKind::CANCEL_EXECUTION;
		const bool prediction_task_start = p_command.kind == AbilityHookCommandKind::START_TASK &&
				p_command.task_request.prediction_policy != AbilityTaskPredictionPolicy::AUTHORITY_ONLY;
		if (p_command.kind != AbilityHookCommandKind::APPLY_SELF_EFFECT &&
				!prediction_lifecycle_command && !prediction_task_start) {
			violation = make_status(StatusCode::CAPABILITY_VIOLATION, DiagnosticId::HOOK_CAPABILITY_DENIED, static_cast<std::uint64_t>(p_command.kind));
			return violation;
		}
		if (p_command.kind == AbilityHookCommandKind::APPLY_SELF_EFFECT) {
			const EffectDefinition *definition = effects->find(p_command.effect_definition);
			if (definition == nullptr || !definition->prediction_safe || definition->has_period) {
				violation = make_status(StatusCode::CAPABILITY_VIOLATION, DiagnosticId::HOOK_CAPABILITY_DENIED, p_command.effect_definition);
				return violation;
			}
		}
	} else if (p_command.kind == AbilityHookCommandKind::APPLY_TARGET_EFFECT) {
		bool found = false;
		for (EntityId candidate : *valid_targets) {
			if (candidate == p_command.explicit_target) {
				found = true;
				break;
			}
		}
		if (!found) {
			violation = make_status(StatusCode::CAPABILITY_VIOLATION, DiagnosticId::TARGET_NOT_RELEVANT, p_command.explicit_target.value);
			return violation;
		}
	}

	recorded.push_back(p_command);
	return ok_status();
}

Status AbilityCommandBuilder::request_task(const AbilityTaskRequest &p_request,
		AbilityTaskHandle &r_requested_task) {
	r_requested_task = INVALID_ABILITY_TASK_HANDLE;
	if (!violation.ok()) {
		return violation;
	}
	AbilityHookCommand command;
	command.kind = AbilityHookCommandKind::START_TASK;
	command.task_request = p_request;
	command.task = AbilityTaskHandle{ next_task_raw + 1 };
	const Status status = submit(command);
	if (!status.ok()) {
		return status;
	}
	next_task_raw = command.task.value;
	r_requested_task = command.task;
	return ok_status();
}

Status validate_prediction_safe_hook(const PredictionSafeAbilityHook &p_hook) {
	std::uint64_t flags = 0;
	if (p_hook.depends_on_time()) {
		flags |= PREDICTION_UNSAFE_TIME;
	}
	if (p_hook.depends_on_randomness()) {
		flags |= PREDICTION_UNSAFE_RANDOMNESS;
	}
	if (p_hook.depends_on_scene_or_physics()) {
		flags |= PREDICTION_UNSAFE_SCENE_OR_PHYSICS;
	}
	if (p_hook.uses_unrestricted_callback()) {
		flags |= PREDICTION_UNSAFE_UNRESTRICTED_CALLBACK;
	}
	if (flags != 0) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, flags);
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

AbilityComponent::AbilityComponent(const AbilityRegistry &p_abilities, const EffectRegistry &p_effects,
		const AttributeRegistry &p_attributes, const TagRegistry &p_tags,
		EntityId p_entity, ComponentRole p_role,
		const TagReactionRegistry *p_reactions, std::size_t p_max_reaction_chain_depth) :
		ability_registry(&p_abilities), effect_registry(&p_effects),
		owner_entity(p_entity), component_role(p_role),
		attribute_set(p_attributes), tag_container(p_tags),
		task_runtime(p_tags, tag_container, p_entity),
		effect_runtime(p_effects, p_entity, attribute_set, tag_container),
		reaction_registry(p_reactions), max_reaction_chain_depth(p_max_reaction_chain_depth) {
	// See GA_ABILITY_OWNED_TAG_SOURCE_BASE's doc comment: bumps this
	// component's OWN owned-tag SourceToken allocator into a disjoint range
	// from EffectRuntime's independent, privately-allocated tokens in the
	// same shared TagContainer.
	owned_tag_source_allocator.restore_from(GA_ABILITY_OWNED_TAG_SOURCE_BASE);
	watch_cancel_tags();
	watch_change_tracking();
	tag_container.add_listener([this](const TagChangeRecord &) {
		if (task_runtime.size() > 0) {
			task_tag_state_dirty = true;
		}
	});

	// Task 4.1/4.6: decided once, for this component's whole lifetime (role
	// never changes for a live instance) -- see `reactions_enabled`'s and the
	// constructor's own doc comments in the header.
	reactions_enabled = (reaction_registry != nullptr) && reaction_registry->sealed() &&
			(component_role == ComponentRole::OFFLINE_AUTHORITY || component_role == ComponentRole::SERVER_AUTHORITY);
	if (reactions_enabled) {
		watch_tag_reactions();
		// Baselines an empty tag_container to "false" for every registered
		// operand -- correct and edge-free by construction (nothing has
		// changed yet), and exercises the exact same code path a later
		// snapshot-restore caller reuses (task 4.1).
		reinitialize_tag_reaction_baselines();
	}
}

// ---------------------------------------------------------------------------
// Role enforcement
// ---------------------------------------------------------------------------

Status AbilityComponent::check_role(ChangeProvenance p_provenance) const {
	const bool authority_role = (component_role == ComponentRole::OFFLINE_AUTHORITY || component_role == ComponentRole::SERVER_AUTHORITY);
	if (authority_role && p_provenance != ChangeProvenance::AUTHORITATIVE) {
		return make_status(StatusCode::ROLE_VIOLATION, DiagnosticId::NONE, static_cast<std::uint64_t>(p_provenance));
	}
	if (component_role == ComponentRole::NETWORK_CLIENT && p_provenance != ChangeProvenance::PREDICTED) {
		return make_status(StatusCode::ROLE_VIOLATION, DiagnosticId::NONE, static_cast<std::uint64_t>(p_provenance));
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Owner teardown seam
// ---------------------------------------------------------------------------

Status AbilityComponent::queue_teardown(Tick p_tick) {
	last_known_tick = p_tick;
	if (torn_down) {
		return ok_status();
	}
	if (queue.is_dispatching()) {
		queue.request_mutation([this, p_tick]() { queue_teardown(p_tick); });
		return ok_status();
	}

	owner_alive = false;
	torn_down = true;
	const std::vector<ExecutionId> ids = active_executions();
	for (ExecutionId id : ids) {
		cancel_execution_immediate(id, p_tick, ChangeProvenance::AUTHORITATIVE, ExecutionEndReason::OWNER_TEARDOWN);
	}
	// Defensive orphan cleanup: a conforming task always belonged to one of
	// the executions above, but teardown must leave every index empty even if
	// a malformed pre-release snapshot had introduced an inconsistency.
	task_runtime.clear_all(AbilityTaskCancelReason::OWNER_TEARDOWN, p_tick);

	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Hook binding
// ---------------------------------------------------------------------------

Status AbilityComponent::bind_authority_hook(DefinitionId p_ability, AuthorityAbilityHook *p_hook) {
	const AbilityDefinition *definition = ability_registry->find(p_ability);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_ability);
	}
	if (p_hook != nullptr && definition->hook_binding != AbilityHookBinding::AUTHORITY_ONLY) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	authority_hooks[p_ability] = p_hook;
	return ok_status();
}

Status AbilityComponent::bind_prediction_safe_hook(DefinitionId p_ability, PredictionSafeAbilityHook *p_hook) {
	const AbilityDefinition *definition = ability_registry->find(p_ability);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_ability);
	}
	if (p_hook != nullptr) {
		if (definition->hook_binding != AbilityHookBinding::PREDICTION_SAFE) {
			return make_status(StatusCode::INVALID_ARGUMENT);
		}
		const Status conformance = validate_prediction_safe_hook(*p_hook);
		if (!conformance.ok()) {
			return conformance;
		}
	}
	prediction_hooks[p_ability] = p_hook;
	return ok_status();
}

// ---------------------------------------------------------------------------
// Grants
// ---------------------------------------------------------------------------

Status AbilityComponent::grant_ability(DefinitionId p_ability, std::int32_t p_level, const std::string &p_input_id,
		Tick p_tick, AbilitySpecId &r_spec, ChangeProvenance p_provenance) {
	r_spec = INVALID_ABILITY_SPEC_ID;
	last_known_tick = p_tick;
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		return role_status;
	}
	const AbilityDefinition *definition = ability_registry->find(p_ability);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_ability);
	}
	if (p_input_id.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_input_id.size());
	}

	AbilitySpecId existing_spec = INVALID_ABILITY_SPEC_ID;
	for (const auto &entry : grants) {
		if (entry.second.ability == p_ability && !entry.second.revoked) {
			existing_spec = entry.first;
			break;
		}
	}
	if (existing_spec) {
		switch (definition->duplicate_grant_policy) {
			case AbilityDuplicateGrantPolicy::REJECT:
				return make_status(StatusCode::ABILITY_ALREADY_GRANTED, DiagnosticId::NONE, existing_spec.value);
			case AbilityDuplicateGrantPolicy::REPLACE: {
				const Status revoke_status = revoke_ability(existing_spec, p_tick, p_provenance);
				if (!revoke_status.ok()) {
					return revoke_status;
				}
				break;
			}
			case AbilityDuplicateGrantPolicy::MULTI_GRANT:
				break;
		}
	}

	if (grants.size() >= MAX_ABILITY_GRANTS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, grants.size());
	}

	const AbilitySpecId spec = spec_allocator.allocate();
	AbilityGrant grant;
	grant.spec = spec;
	grant.ability = p_ability;
	grant.level = p_level;
	grant.input_id = p_input_id;

	Transaction txn(next_transaction_id(), p_tick);
	grants[spec] = grant;
	txn.add_undo([this, spec]() { grants.erase(spec); });

	AbilityLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = AbilityLifecycleKind::GRANTED;
	event.owner = owner_entity;
	event.spec = spec;
	event.ability = p_ability;
	event.tick = p_tick;
	event.transaction = txn.id();
	event.provenance = p_provenance;
	const Status notify_status = emit_ability_event(event, txn);
	TransactionScope scope(txn, queue);
	if (!notify_status.ok()) {
		scope.fail(notify_status);
	}
	const Status commit_status = scope.finish();
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	if (!commit_status.ok()) {
		return commit_status;
	}
	r_spec = spec;

	if (definition->activation_policy == ActivationPolicy::PASSIVE_ON_GRANT) {
		ActivationRequest request;
		request.spec = spec;
		request.provenance = p_provenance;
		request_activation(request, p_tick);
	}

	return ok_status();
}

Status AbilityComponent::revoke_ability(AbilitySpecId p_spec, Tick p_tick, ChangeProvenance p_provenance) {
	last_known_tick = p_tick;
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		return role_status;
	}
	auto it = grants.find(p_spec);
	if (it == grants.end()) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::NONE, p_spec.value);
	}
	if (it->second.revoked) {
		return ok_status(); // idempotent
	}
	const DefinitionId ability = it->second.ability;
	const AbilityDefinition *definition = ability_registry->find(ability);

	Transaction txn(next_transaction_id(), p_tick);
	it->second.revoked = true;
	txn.add_undo([this, p_spec]() {
		auto undo_it = grants.find(p_spec);
		if (undo_it != grants.end()) {
			undo_it->second.revoked = false;
		}
	});

	AbilityLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = AbilityLifecycleKind::REVOKED;
	event.owner = owner_entity;
	event.spec = p_spec;
	event.ability = ability;
	event.tick = p_tick;
	event.transaction = txn.id();
	event.provenance = p_provenance;
	const Status notify_status = emit_ability_event(event, txn);
	TransactionScope scope(txn, queue);
	if (!notify_status.ok()) {
		scope.fail(notify_status);
	}
	const Status commit_status = scope.finish();
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	if (!commit_status.ok()) {
		return commit_status;
	}

	if (definition != nullptr && definition->revoke_policy == AbilityRevokePolicy::CANCEL_ACTIVE) {
		const std::vector<ExecutionId> ids = active_executions();
		for (ExecutionId id : ids) {
			const ActiveExecution *execution = find_execution(id);
			if (execution != nullptr && execution->spec == p_spec) {
				cancel_execution_immediate(id, p_tick, p_provenance, ExecutionEndReason::REVOKED);
			}
		}
	}
	return ok_status();
}

bool AbilityComponent::has_grant(AbilitySpecId p_spec) const {
	return grants.find(p_spec) != grants.end();
}

const AbilityGrant *AbilityComponent::find_grant(AbilitySpecId p_spec) const {
	auto it = grants.find(p_spec);
	return it == grants.end() ? nullptr : &it->second;
}

std::vector<AbilitySpecId> AbilityComponent::granted_specs() const {
	std::vector<AbilitySpecId> result;
	result.reserve(grants.size());
	for (const auto &entry : grants) {
		result.push_back(entry.first);
	}
	return result; // std::map<AbilitySpecId, ...> already iterates ascending
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

ActivationResult AbilityComponent::request_activation(const ActivationRequest &p_request, Tick p_tick) {
	last_known_tick = p_tick;
	if (queue.is_dispatching()) {
		const ActivationRequest captured = p_request;
		queue.request_mutation([this, captured, p_tick]() { request_activation_immediate(captured, p_tick, 0); });
		ActivationResult result;
		result.queued = true;
		return result;
	}

	ActivationResult result = request_activation_immediate(p_request, p_tick, 0);
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return result;
}

std::vector<ActivationResult> AbilityComponent::process_activation_batch(const std::vector<ActivationRequest> &p_requests, Tick p_tick) {
	last_known_tick = p_tick;
	std::vector<ActivationRequest> sorted = p_requests;
	std::stable_sort(sorted.begin(), sorted.end(), [](const ActivationRequest &a, const ActivationRequest &b) {
		if (a.command_sequence.value != b.command_sequence.value) {
			return a.command_sequence.value < b.command_sequence.value;
		}
		return a.spec.value < b.spec.value;
	});

	std::vector<ActivationResult> results;
	results.reserve(sorted.size());
	for (const ActivationRequest &request : sorted) {
		results.push_back(request_activation_immediate(request, p_tick, 0));
	}

	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return results;
}

ActivationResult AbilityComponent::request_activation_immediate(const ActivationRequest &p_request, Tick p_tick,
		std::size_t p_event_depth, const GameplayEventContext *p_triggering_event) {
	ActivationResult result;

	if (torn_down) {
		result.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
		return result;
	}
	const Status role_status = check_role(p_request.provenance);
	if (!role_status.ok()) {
		result.status = role_status;
		return result;
	}
	if (p_request.targets.size() > MAX_TARGETS_PER_COMMAND) {
		result.status = make_status(StatusCode::ABILITY_INVALID_TARGET, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_request.targets.size());
		return result;
	}

	auto grant_it = grants.find(p_request.spec);
	if (grant_it == grants.end()) {
		result.status = make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::NONE, p_request.spec.value);
		return result;
	}
	AbilityGrant &grant = grant_it->second;
	if (grant.revoked) {
		result.status = make_status(StatusCode::ABILITY_REVOKED, DiagnosticId::NONE, p_request.spec.value);
		return result;
	}
	const AbilityDefinition *definition = ability_registry->find(grant.ability);
	if (definition == nullptr) {
		result.status = make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, grant.ability);
		return result;
	}

	// Invariant relied on by `ga::PredictionReconciler::reconcile`'s replay
	// path (ga_reconciliation.cpp): reconciliation now re-runs a still-
	// pending predicted command through `ga::PredictingComponent::repredict`
	// PRESERVING its original `command_sequence` (see that fix's own
	// comment -- "Reconciliation can execute a pending ability twice") and
	// replays it against the client's just-restored CONFIRMED baseline. That
	// baseline can only ever be older than the still-outstanding command it
	// is being replayed against: an entry only remains "still pending" in
	// the journal because neither an ACCEPTED nor a REJECTED decision has
	// reached this client for it yet, and the authority only ever advances
	// THIS field (and therefore only ever lets that advance appear in any
	// snapshot the client could have adopted) at the exact moment it decides
	// that command's fate -- the same moment it sends the very
	// acknowledgement the entry is still waiting on. So a legitimate replay's
	// preserved `command_sequence` is always strictly greater than this
	// grant's restored `last_command_sequence`, and this check passes
	// exactly as it would for any ordinary fresh activation. If that ever
	// did not hold (e.g. a caller replayed against a snapshot newer than the
	// one paired with the still-outstanding decision), failing closed here
	// with `STALE_COMMAND` is still the correct outcome, not a bug: it would
	// mean the restored baseline already reflects this exact command's
	// effect, so applying it again locally must not happen either. Either
	// way the caller's `PredictionOutcome` still carries the preserved
	// identity (stamped before this call resolves), so a resend still
	// reaches the server for `ga::proto::CommandSequenceTracker`'s own
	// duplicate detection to settle idempotently.
	if (p_request.command_sequence && grant.last_command_sequence &&
			p_request.command_sequence.value <= grant.last_command_sequence.value) {
		result.status = make_status(StatusCode::STALE_COMMAND, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_request.command_sequence.value);
		return result;
	}

	if (definition->concurrency_policy == AbilityConcurrencyPolicy::REJECT_IF_ACTIVE) {
		for (const auto &entry : executions) {
			if (entry.second.spec == p_request.spec &&
					(entry.second.phase == ExecutionPhase::BEGUN || entry.second.phase == ExecutionPhase::ACTIVE)) {
				result.status = make_status(StatusCode::ABILITY_ALREADY_ACTIVE, DiagnosticId::NONE, entry.first.value);
				return result;
			}
		}
	}

	if (!(definition->required_tags == TagQuery()) && !definition->required_tags.evaluate(tag_container)) {
		result.status = make_status(StatusCode::ABILITY_MISSING_TAG);
		return result;
	}
	if (!(definition->blocked_tags == TagQuery()) && definition->blocked_tags.evaluate(tag_container)) {
		result.status = make_status(StatusCode::ABILITY_BLOCKED_TAG);
		return result;
	}

	if (grant.cooldown_handle && effect_runtime.has_effect(grant.cooldown_handle)) {
		const ActiveEffect *active = effect_runtime.find(grant.cooldown_handle);
		const Tick ready_tick = active != nullptr ? active->end_tick : INVALID_TICK;
		result.status = make_status(StatusCode::ABILITY_ON_COOLDOWN, DiagnosticId::NONE, ready_tick);
		result.cooldown_ready_tick = ready_tick;
		return result;
	}

	if (definition->has_cost_effect) {
		const EffectDefinition *cost_definition = effect_registry->find(definition->cost_effect);
		if (cost_definition != nullptr) {
			const Status cost_status = check_cost_affordable(*cost_definition, grant.level, p_request.set_by_caller);
			if (!cost_status.ok()) {
				result.status = cost_status;
				return result;
			}
		}
	}

	// --- Begin. ---
	const ExecutionId execution_id = execution_allocator.allocate();
	ActiveExecution execution;
	execution.id = execution_id;
	execution.spec = p_request.spec;
	execution.ability = grant.ability;
	execution.phase = ExecutionPhase::BEGUN;
	execution.begin_tick = p_tick;
	execution.targets = p_request.targets;
	execution.set_by_caller = p_request.set_by_caller;
	execution.provenance = p_request.provenance;
	execution.prediction_key = p_request.prediction_key;
	if (p_triggering_event != nullptr) {
		execution.has_triggering_event = true;
		execution.triggering_event = *p_triggering_event;
	}

	Transaction txn(next_transaction_id(), p_tick);
	executions[execution_id] = execution;
	txn.add_undo([this, execution_id]() { executions.erase(execution_id); });

	const CommandSeq previous_sequence = grant.last_command_sequence;
	if (p_request.command_sequence) {
		grant.last_command_sequence = p_request.command_sequence;
		txn.add_undo([this, spec = p_request.spec, previous_sequence]() {
			auto undo_it = grants.find(spec);
			if (undo_it != grants.end()) {
				undo_it->second.last_command_sequence = previous_sequence;
			}
		});
	}

	AbilityLifecycleEvent begin_event;
	begin_event.id = event_allocator.allocate();
	begin_event.kind = AbilityLifecycleKind::PHASE_CHANGED;
	begin_event.owner = owner_entity;
	begin_event.spec = p_request.spec;
	begin_event.ability = grant.ability;
	begin_event.execution = execution_id;
	begin_event.phase = ExecutionPhase::BEGUN;
	begin_event.tick = p_tick;
	begin_event.transaction = txn.id();
	begin_event.provenance = p_request.provenance;
	begin_event.prediction_key = p_request.prediction_key;
	const Status notify_status = emit_ability_event(begin_event, txn);

	TransactionScope scope(txn, queue);
	if (!notify_status.ok()) {
		scope.fail(notify_status);
	}
	const Status commit_status = scope.finish();
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	if (!commit_status.ok()) {
		result.status = commit_status;
		return result;
	}

	result.status = ok_status();
	result.execution = execution_id;

	if (definition->auto_commit) {
		// Always passed a real destination (straight into this very result),
		// so an auto-committed activation can never hit the
		// `PENDING_REMOTE_EFFECT_DROPPED` diagnostic -- see
		// `commit_execution_immediate`'s doc comment.
		const Status commit_result = commit_execution_immediate(execution_id, p_tick, p_event_depth, &result.pending_remote_effects);
		if (!commit_result.ok()) {
			// Nothing else will ever commit an orphaned auto-commit
			// execution -- tear down the BEGUN record deterministically.
			cancel_execution_immediate(execution_id, p_tick, p_request.provenance, ExecutionEndReason::HOOK_FAILURE);
			result.status = commit_result;
			result.execution = INVALID_EXECUTION_ID;
			result.pending_remote_effects.clear();
		}
	}
	return result;
}

Status AbilityComponent::commit_activation(ExecutionId p_execution, Tick p_tick,
		std::vector<PendingRemoteEffectCommand> *r_pending_remote_effects) {
	last_known_tick = p_tick;
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	const Status status = commit_execution_immediate(p_execution, p_tick, 0, r_pending_remote_effects);
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return status;
}

Status AbilityComponent::commit_execution_immediate(ExecutionId p_execution, Tick p_tick, std::size_t p_event_depth,
		std::vector<PendingRemoteEffectCommand> *r_pending_remote_effects) {
	auto exec_it = executions.find(p_execution);
	if (exec_it == executions.end() || exec_it->second.phase != ExecutionPhase::BEGUN) {
		return make_status(StatusCode::ABILITY_ALREADY_ENDED, DiagnosticId::NONE, p_execution.value);
	}
	ActiveExecution &execution = exec_it->second;
	auto grant_it = grants.find(execution.spec);
	if (grant_it == grants.end() || grant_it->second.revoked) {
		return make_status(StatusCode::ABILITY_REVOKED, DiagnosticId::NONE, execution.spec.value);
	}
	AbilityGrant &grant = grant_it->second;
	const AbilityDefinition *definition = ability_registry->find(execution.ability);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, execution.ability);
	}

	// Commit-time revalidation -- tags/cooldown/cost may have changed since begin.
	if (!(definition->required_tags == TagQuery()) && !definition->required_tags.evaluate(tag_container)) {
		return make_status(StatusCode::ABILITY_MISSING_TAG);
	}
	if (!(definition->blocked_tags == TagQuery()) && definition->blocked_tags.evaluate(tag_container)) {
		return make_status(StatusCode::ABILITY_BLOCKED_TAG);
	}
	if (grant.cooldown_handle && effect_runtime.has_effect(grant.cooldown_handle)) {
		return make_status(StatusCode::ABILITY_ON_COOLDOWN);
	}
	if (definition->has_cost_effect) {
		const EffectDefinition *cost_definition = effect_registry->find(definition->cost_effect);
		if (cost_definition != nullptr) {
			const Status cost_status = check_cost_affordable(*cost_definition, grant.level, execution.set_by_caller);
			if (!cost_status.ok()) {
				return cost_status;
			}
		}
	}

	Transaction txn(next_transaction_id(), p_tick);
	std::vector<GameplayEventContext> emitted_events;
	std::vector<PendingRemoteEffectCommand> pending_remote_effects;
	std::vector<AbilityHookCommand> post_commit_commands;
	const Status body_status = commit_execution_body(execution, grant, *definition, p_tick,
			txn, emitted_events, pending_remote_effects, post_commit_commands);

	TransactionScope scope(txn, queue);
	if (!body_status.ok()) {
		scope.fail(body_status);
	}
	const Status commit_status = scope.finish();
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	if (!commit_status.ok()) {
		// A failed/rolled-back commit "accepted" nothing -- any command
		// pushed into `pending_remote_effects` before the failure belongs to
		// state that no longer exists. Never surface it.
		return commit_status;
	}

	// Only a genuinely COMMITTED transaction's remote commands are ever
	// surfaced or diagnosed -- see the comment above.
	if (!pending_remote_effects.empty()) {
		if (r_pending_remote_effects != nullptr) {
			*r_pending_remote_effects = std::move(pending_remote_effects);
		} else {
			// See `AbilityDiagnosticKind::PENDING_REMOTE_EFFECT_DROPPED`'s own
			// doc comment: the caller explicitly passed no destination for
			// these, so make that choice observable rather than silently
			// losing the accepted command(s).
			emit_diagnostic(AbilityDiagnosticKind::PENDING_REMOTE_EFFECT_DROPPED, execution.spec, p_execution, ok_status(), p_tick);
		}
	} else if (r_pending_remote_effects != nullptr) {
		r_pending_remote_effects->clear();
	}

	const bool ends_on_commit = definition->ends_on_commit;
	const ChangeProvenance provenance = execution.provenance;
	if (ends_on_commit) {
		// `execution`/`grant`/`exec_it`/`grant_it` become invalid the moment
		// this call erases the execution -- nothing below may reference them.
		end_execution_immediate(p_execution, p_tick, provenance);
	}

	for (const GameplayEventContext &event : emitted_events) {
		handle_gameplay_event_internal(event, p_tick, p_event_depth + 1);
	}
	if (find_execution(p_execution) != nullptr && !post_commit_commands.empty()) {
		apply_task_callback_commands(p_execution, std::move(post_commit_commands), p_tick);
	}

	return ok_status();
}

Status AbilityComponent::commit_execution_body(ActiveExecution &p_execution, AbilityGrant &p_grant, const AbilityDefinition &p_definition,
		Tick p_tick, Transaction &p_txn, std::vector<GameplayEventContext> &r_emitted_events,
		std::vector<PendingRemoteEffectCommand> &r_pending_remote_effects,
		std::vector<AbilityHookCommand> &r_post_commit_commands) {
	EffectSpec self_template;
	self_template.source = owner_entity;
	self_template.target = owner_entity;
	self_template.level = p_grant.level;
	self_template.set_by_caller = p_execution.set_by_caller;

	// 1. Cost.
	if (p_definition.has_cost_effect) {
		EffectSpec cost_spec = self_template;
		cost_spec.definition = p_definition.cost_effect;
		EffectHandle unused_handle;
		const Status status = effect_runtime.apply(cost_spec, p_tick, &attribute_set, &tag_container, p_txn, queue, unused_handle,
				p_execution.provenance, p_execution.prediction_key, nullptr);
		if (!status.ok()) {
			p_txn.fail(status);
			return status;
		}
	}

	// 2. Cooldown.
	if (p_definition.has_cooldown_effect) {
		EffectSpec cooldown_spec = self_template;
		cooldown_spec.definition = p_definition.cooldown_effect;
		EffectHandle cooldown_handle;
		const Status status = effect_runtime.apply(cooldown_spec, p_tick, &attribute_set, &tag_container, p_txn, queue, cooldown_handle,
				p_execution.provenance, p_execution.prediction_key, nullptr);
		if (!status.ok()) {
			p_txn.fail(status);
			return status;
		}
		const EffectHandle previous_cooldown = p_grant.cooldown_handle;
		p_grant.cooldown_handle = cooldown_handle;
		const AbilitySpecId spec = p_execution.spec;
		p_txn.add_undo([this, spec, previous_cooldown]() {
			auto it = grants.find(spec);
			if (it != grants.end()) {
				it->second.cooldown_handle = previous_cooldown;
			}
		});
	}

	// 3. Declared commit effects (self), in declared order.
	//
	// Task 6.11: a DURATION/INFINITE commit effect's handle is only tracked
	// as EXECUTION-OWNED (torn down atomically when this execution ends or
	// cancels -- see `ActiveExecution::owned_effect_handles`'s own doc
	// comment) when `p_definition.ends_on_commit` is false, i.e. when this
	// execution actually HAS an active phase for the effect to be scoped to
	// (the Channel-style "this buff disappears the moment I stop
	// channeling/get cancelled" contract). When `ends_on_commit` is true,
	// commit and end happen in the SAME call with no active phase at all --
	// there is no meaningful window for "execution-scoped" to describe, so
	// treating the handle as owned could only ever tear back down what this
	// SAME transaction pair just atomically committed, silently discarding a
	// lasting effect the definition author declared (see this function's own
	// class file comment / the task 6.11 report: this used to apply a
	// DURATION/INFINITE effect and remove it again in the same call, still
	// returning `ok()`). A lasting commit effect instead follows its OWN
	// declared lifetime policy (duration/period/explicit removal) exactly
	// like the cooldown effect already does -- see the comment on
	// `ActiveExecution::owned_effect_handles` ("cooldown ... deliberately
	// outlives the execution"), which this extends to every commit effect on
	// an `ends_on_commit` ability for the same reason.
	std::vector<EffectHandle> owned_handles;
	for (DefinitionId effect_id : p_definition.commit_effects) {
		EffectSpec spec = self_template;
		spec.definition = effect_id;
		EffectHandle handle;
		const Status status = effect_runtime.apply(spec, p_tick, &attribute_set, &tag_container, p_txn, queue, handle,
				p_execution.provenance, p_execution.prediction_key, nullptr);
		if (!status.ok()) {
			p_txn.fail(status);
			return status;
		}
		if (handle && !p_definition.ends_on_commit) {
			owned_handles.push_back(handle);
		}
	}

	// 4. Bound behavior hook, if any.
	if (p_definition.hook_binding != AbilityHookBinding::NONE) {
		const AbilityExecutionContext context = build_execution_context(p_execution, p_grant, p_definition, p_tick);
		const bool prediction_mode = (p_definition.hook_binding == AbilityHookBinding::PREDICTION_SAFE);
		AbilityCommandBuilder builder(*effect_registry, p_execution.targets, prediction_mode,
				task_runtime.allocator_next_raw());

		Status hook_status = ok_status();
		if (prediction_mode) {
			auto it = prediction_hooks.find(p_execution.ability);
			if (it != prediction_hooks.end() && it->second != nullptr) {
				hook_status = it->second->execute(context, builder);
			}
		} else {
			auto it = authority_hooks.find(p_execution.ability);
			if (it != authority_hooks.end() && it->second != nullptr) {
				hook_status = it->second->execute(context, builder);
			}
		}

		// A rejected submission is checked UNCONDITIONALLY, regardless of
		// what the hook itself returned -- see AbilityCommandBuilder's doc
		// comment ("Hook attempts direct mutation" scenario).
		if (!builder.violation_status().ok()) {
			emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED, p_execution.spec, p_execution.id, builder.violation_status(), p_tick);
			p_txn.fail(builder.violation_status());
			return builder.violation_status();
		}
		if (!hook_status.ok()) {
			p_txn.fail(hook_status);
			return hook_status;
		}

		std::size_t post_commit_task_starts = 0;
		for (const AbilityHookCommand &command : builder.commands()) {
			switch (command.kind) {
				case AbilityHookCommandKind::APPLY_SELF_EFFECT:
				case AbilityHookCommandKind::APPLY_TARGET_EFFECT: {
					EffectSpec spec;
					spec.definition = command.effect_definition;
					spec.source = owner_entity;
					spec.target = (command.kind == AbilityHookCommandKind::APPLY_TARGET_EFFECT) ? command.explicit_target : owner_entity;
					spec.level = p_grant.level;
					spec.set_by_caller = command.set_by_caller;
					// v1 scope: this runtime only owns `owner_entity`'s
					// containers, so a genuinely remote target cannot be
					// applied here -- that boundary is correct, not a bug
					// (see PendingRemoteEffectCommand's doc comment). A
					// self-target command applies immediately, atomically, in
					// THIS same transaction; a remote-target command is
					// instead surfaced, in commit order, as a
					// `PendingRemoteEffectCommand` so the caller can apply it
					// against the TARGET's own component through
					// `apply_remote_effect` -- never silently discarded
					// (task 6.13).
					if (spec.target == owner_entity) {
						EffectHandle handle;
						const Status status = effect_runtime.apply(spec, p_tick, &attribute_set, &tag_container, p_txn, queue, handle,
								p_execution.provenance, p_execution.prediction_key, nullptr);
						if (!status.ok()) {
							p_txn.fail(status);
							return status;
						}
						// See the identical rule and its rationale on step 3's
						// declared `commit_effects` loop above -- a hook-applied
						// self effect is exactly as execution-scoped (or not) as
						// a declared one.
						if (handle && !p_definition.ends_on_commit) {
							owned_handles.push_back(handle);
						}
					} else {
						PendingRemoteEffectCommand pending;
						pending.source = owner_entity;
						pending.target = spec.target;
						pending.effect_definition = spec.definition;
						pending.level = spec.level;
						pending.set_by_caller = spec.set_by_caller;
						pending.provenance = p_execution.provenance;
						pending.prediction_key = p_execution.prediction_key;
						pending.originating_spec = p_execution.spec;
						pending.originating_execution = p_execution.id;
						pending.tick = p_tick;
						r_pending_remote_effects.push_back(std::move(pending));
					}
					break;
				}
				case AbilityHookCommandKind::EMIT_GAMEPLAY_EVENT: {
					r_emitted_events.push_back(command.event);
					break;
				}
				case AbilityHookCommandKind::START_TASK: {
					if (p_definition.ends_on_commit ||
							command.task.value !=
									task_runtime.allocator_next_raw() +
											post_commit_task_starts + 1) {
						const Status status = make_status(
								StatusCode::INVALID_ABILITY_TASK,
								DiagnosticId::INVALID_TASK_PAYLOAD,
								command.task.value);
						p_txn.fail(status);
						return status;
					}
					const Status status = task_runtime.validate_start_request(
							command.task_request, p_tick, p_execution.provenance);
					if (!status.ok()) {
						p_txn.fail(status);
						return status;
					}
					if (task_runtime.tasks_for_execution(p_execution.id).size() +
									post_commit_task_starts >=
							MAX_ABILITY_TASKS_PER_EXECUTION) {
						const Status capacity = make_status(
								StatusCode::CAPACITY_EXCEEDED,
								DiagnosticId::COUNT_LIMIT_EXCEEDED,
								MAX_ABILITY_TASKS_PER_EXECUTION);
						p_txn.fail(capacity);
						return capacity;
					}
					if (task_runtime.size() + post_commit_task_starts >=
							MAX_ACTIVE_ABILITY_TASKS) {
						const Status capacity = make_status(
								StatusCode::CAPACITY_EXCEEDED,
								DiagnosticId::COUNT_LIMIT_EXCEEDED,
								MAX_ACTIVE_ABILITY_TASKS);
						p_txn.fail(capacity);
						return capacity;
					}
					r_post_commit_commands.push_back(command);
					++post_commit_task_starts;
					break;
				}
				case AbilityHookCommandKind::CANCEL_TASK:
				r_post_commit_commands.push_back(command);
				break;
				case AbilityHookCommandKind::COMMIT_EXECUTION: {
					const Status status = make_status(
							StatusCode::CAPABILITY_VIOLATION,
							DiagnosticId::HOOK_CAPABILITY_DENIED,
							static_cast<std::uint64_t>(command.kind));
					p_txn.fail(status);
					return status;
				}
				case AbilityHookCommandKind::END_EXECUTION:
				case AbilityHookCommandKind::CANCEL_EXECUTION:
					r_post_commit_commands.push_back(command);
					break;
			}
		}
	}

	p_execution.owned_effect_handles = owned_handles;

	// 5. Owned tags -- participates in the SAME `p_txn` as everything above
	// (see file comment); no ordering requirement to maintain.
	if (!p_definition.owned_tags.empty()) {
		const SourceToken source = owned_tag_source_allocator.allocate();
		p_execution.owned_tag_source = source;
		std::vector<TagMutationOp> ops;
		ops.reserve(p_definition.owned_tags.size());
		for (DefinitionId tag : p_definition.owned_tags) {
			ops.push_back(TagMutationOp{ TagMutationOp::Kind::ADD, tag, source });
		}
		const Status status = tag_container.apply_mutations(ops, p_txn, queue);
		if (!status.ok()) {
			p_txn.fail(status);
			return status;
		}
	}

	p_execution.phase = ExecutionPhase::ACTIVE;
	p_execution.commit_tick = p_tick;

	AbilityLifecycleEvent commit_event;
	commit_event.id = event_allocator.allocate();
	commit_event.kind = AbilityLifecycleKind::COMMITTED;
	commit_event.owner = owner_entity;
	commit_event.spec = p_execution.spec;
	commit_event.ability = p_execution.ability;
	commit_event.execution = p_execution.id;
	commit_event.phase = ExecutionPhase::COMMITTED;
	commit_event.tick = p_tick;
	commit_event.transaction = p_txn.id();
	commit_event.provenance = p_execution.provenance;
	commit_event.prediction_key = p_execution.prediction_key;
	Status notify_status = emit_ability_event(commit_event, p_txn);
	if (!notify_status.ok()) {
		return notify_status;
	}

	AbilityLifecycleEvent active_event = commit_event;
	active_event.id = event_allocator.allocate();
	active_event.kind = AbilityLifecycleKind::PHASE_CHANGED;
	active_event.phase = ExecutionPhase::ACTIVE;
	notify_status = emit_ability_event(active_event, p_txn);
	if (!notify_status.ok()) {
		return notify_status;
	}

	return ok_status();
}

AbilityExecutionContext AbilityComponent::build_execution_context(const ActiveExecution &p_execution, const AbilityGrant &p_grant,
		const AbilityDefinition &p_definition, Tick p_tick) const {
	(void)p_definition;
	AbilityExecutionContext context;
	context.owner = owner_entity;
	context.spec = p_execution.spec;
	context.execution = p_execution.id;
	context.ability = p_execution.ability;
	context.level = p_grant.level;
	context.tick = p_tick;
	context.role = component_role;
	context.provenance = p_execution.provenance;
	for (DefinitionId id : attribute_set.initialized_attributes()) {
		Fixed value;
		if (attribute_set.get_current(id, value).ok()) {
			context.owner_attributes.emplace_back(id, value);
		}
	}
	context.owner_tags = tag_container.owned_tags();
	context.targets = p_execution.targets;
	context.set_by_caller = p_execution.set_by_caller;
	context.active_tasks = task_runtime.tasks_for_execution(p_execution.id);
	context.has_event = p_execution.has_triggering_event;
	if (p_execution.has_triggering_event) {
		context.event = p_execution.triggering_event;
	}
	return context;
}

Status AbilityComponent::check_cost_affordable(const EffectDefinition &p_cost_definition, std::int32_t p_level,
		const std::vector<SetByCallerMagnitude> &p_set_by_caller) const {
	std::map<DefinitionId, Fixed> deltas; // ascending by construction (std::map)
	for (const ModifierDeclaration &modifier : p_cost_definition.modifiers) {
		if (modifier.op != ModifierOp::ADD) {
			continue; // see doc comment: only ADD-op modifiers gate affordability in v1
		}
		Fixed magnitude = Fixed::zero();
		switch (modifier.magnitude.kind) {
			case MagnitudeSourceKind::CONSTANT: {
				magnitude = modifier.magnitude.coefficient;
				break;
			}
			case MagnitudeSourceKind::ABILITY_LEVEL: {
				const Status status = fixed_mul(modifier.magnitude.coefficient, Fixed::from_int(p_level), magnitude);
				if (!status.ok()) {
					return status;
				}
				break;
			}
			case MagnitudeSourceKind::SOURCE_ATTRIBUTE:
			case MagnitudeSourceKind::TARGET_ATTRIBUTE: {
				// Cost/cooldown are always self-effects (source == target ==
				// owner), so either kind reads this component's OWN current value.
				Fixed raw;
				const Status get_status = attribute_set.get_current(modifier.magnitude.attribute, raw);
				if (!get_status.ok()) {
					return get_status;
				}
				const Status mul_status = fixed_mul(modifier.magnitude.coefficient, raw, magnitude);
				if (!mul_status.ok()) {
					return mul_status;
				}
				break;
			}
			case MagnitudeSourceKind::SET_BY_CALLER: {
				Fixed raw = Fixed::zero();
				for (const SetByCallerMagnitude &supplied : p_set_by_caller) {
					if (supplied.field == modifier.magnitude.set_by_caller_field) {
						raw = supplied.value;
						break;
					}
				}
				const Status status = fixed_mul(modifier.magnitude.coefficient, raw, magnitude);
				if (!status.ok()) {
					return status;
				}
				break;
			}
		}
		Fixed &total = deltas[modifier.target_attribute];
		const Status sum_status = fixed_add(total, magnitude, total);
		if (!sum_status.ok()) {
			return sum_status;
		}
	}

	for (const auto &entry : deltas) {
		if (entry.second >= Fixed::zero()) {
			continue; // a non-negative total never makes this attribute unaffordable
		}
		Fixed current;
		const Status status = attribute_set.get_current(entry.first, current);
		if (!status.ok()) {
			continue; // an uninitialized attribute is not this preflight's concern
		}
		Fixed projected;
		const Status add_status = fixed_add(current, entry.second, projected);
		if (!add_status.ok()) {
			return add_status;
		}
		if (projected < Fixed::zero()) {
			return make_status(StatusCode::ABILITY_COST_UNAFFORDABLE, DiagnosticId::NONE, entry.first);
		}
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Deterministic execution-owned ability tasks
// ---------------------------------------------------------------------------

void AbilityComponent::add_ability_task_listener(
		std::function<void(const AbilityTaskEvent &, NotificationQueue &)> p_listener) {
	task_listeners.push_back(std::move(p_listener));
}

void AbilityComponent::enqueue_task_event(const AbilityTaskEvent &p_event) {
	const Status status = queue.enqueue([this, p_event]() {
		dispatch_task_event(p_event);
	});
	if (!status.ok()) {
		emit_diagnostic(AbilityDiagnosticKind::RECURSION_LIMIT_REACHED, p_event.spec,
				p_event.execution, status, p_event.tick);
	}
}

void AbilityComponent::enqueue_task_events(const std::vector<AbilityTaskEvent> &p_events) {
	for (const AbilityTaskEvent &event : p_events) {
		enqueue_task_event(event);
	}
}

AbilityTaskStartResult AbilityComponent::start_ability_task(ExecutionId p_execution,
		const AbilityTaskRequest &p_request, Tick p_tick, ChangeProvenance p_provenance,
		AbilityTaskHandle p_reserved_handle) {
	last_known_tick = p_tick;
	AbilityTaskStartResult result;
	if (torn_down) {
		result.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
		return result;
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		result.status = role_status;
		return result;
	}
	if (queue.is_dispatching()) {
		const Status queued_status = queue.request_mutation(
				[this, p_execution, p_request, p_tick, p_provenance, p_reserved_handle]() {
					start_ability_task(p_execution, p_request, p_tick, p_provenance,
							p_reserved_handle);
				});
		result.status = queued_status;
		result.queued = queued_status.ok();
		return result;
	}

	const ActiveExecution *execution = find_execution(p_execution);
	if (execution == nullptr ||
			(execution->phase != ExecutionPhase::BEGUN &&
					execution->phase != ExecutionPhase::ACTIVE)) {
		result.status = make_status(StatusCode::INVALID_ABILITY_TASK,
				DiagnosticId::TASK_PARENT_MISSING, p_execution.value);
		return result;
	}
	const AbilityGrant *grant = find_grant(execution->spec);
	if (grant == nullptr || grant->revoked) {
		result.status = make_status(StatusCode::ABILITY_REVOKED, DiagnosticId::TASK_PARENT_MISSING,
				execution->spec.value);
		return result;
	}

	result = task_runtime.start(p_request, execution->id, execution->spec,
			execution->ability, p_tick, p_provenance, execution->prediction_key,
			p_reserved_handle);
	if (!result.status.ok()) {
		return result;
	}
	if (result.terminal) {
		enqueue_task_event(result.event);
	} else {
		const ActiveAbilityTask *active = task_runtime.find(result.task);
		if (active != nullptr) {
			AbilityTaskEvent started;
			started.task = active->handle;
			started.owner = active->owner;
			started.execution = active->execution;
			started.spec = active->spec;
			started.ability = active->ability;
			started.kind = active->request.kind;
			started.outcome = AbilityTaskOutcome::ACTIVE;
			started.status = ok_status();
			started.tick = p_tick;
			started.provenance = active->provenance;
			started.prediction_key = active->prediction_key;
			started.task_visibility = active->request.visibility;
			enqueue_task_event(started);
		}
	}
	queue.dispatch();
	flush_change_tracking();

	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return result;
}

AbilityTaskTransitionResult AbilityComponent::cancel_ability_task(
		AbilityTaskHandle p_task, Tick p_tick, AbilityTaskCancelReason p_reason,
		ChangeProvenance p_provenance) {
	last_known_tick = p_tick;
	AbilityTaskTransitionResult result;
	if (torn_down) {
		result.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
		return result;
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		result.status = role_status;
		return result;
	}
	if (queue.is_dispatching()) {
		const Status queued_status = queue.request_mutation(
				[this, p_task, p_tick, p_reason, p_provenance]() {
					cancel_ability_task(p_task, p_tick, p_reason, p_provenance);
				});
		result.status = queued_status;
		result.queued = queued_status.ok();
		return result;
	}
	result = task_runtime.cancel(p_task, p_tick, p_reason);
	if (result.transitioned) {
		enqueue_task_event(result.event);
		queue.dispatch();
		flush_change_tracking();
	}
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return result;
}

AbilityTaskTransitionResult AbilityComponent::submit_logical_input(
		const AbilityTaskLogicalInputCommand &p_command, Tick p_tick,
		ChangeProvenance p_provenance) {
	last_known_tick = p_tick;
	AbilityTaskTransitionResult result;
	if (torn_down) {
		result.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
		return result;
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		result.status = role_status;
		return result;
	}
	if (queue.is_dispatching()) {
		const Status queued_status = queue.request_mutation(
				[this, p_command, p_tick, p_provenance]() {
					submit_logical_input(p_command, p_tick, p_provenance);
				});
		result.status = queued_status;
		result.queued = queued_status.ok();
		return result;
	}

	// Deadlines/due work precede same-tick logical input.
	bool task_fanout_truncated = false;
	enqueue_task_events(task_runtime.advance_to(p_tick, &task_fanout_truncated));
	queue.dispatch();
	flush_change_tracking();
	if (task_fanout_truncated) {
		emit_task_fanout_truncated(p_tick);
	}
	result = task_runtime.submit_logical_input(p_command, p_tick);
	if (result.transitioned) {
		enqueue_task_event(result.event);
		queue.dispatch();
		flush_change_tracking();
	}
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return result;
}

AbilityTaskTransitionResult AbilityComponent::complete_target_task(
		AbilityTaskHandle p_task, TargetSessionId p_session, Tick p_tick,
		Status p_status, const TargetEffectContext *p_context) {
	last_known_tick = p_tick;
	AbilityTaskTransitionResult result;
	if (torn_down) {
		result.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
		return result;
	}
	// A session's OWNING coordinator resolves it over an authority-role
	// component (GameplayAbilityWorldCoordinator::attach_wait_target_data's
	// own authority_role() gate) -- but a NETWORK_CLIENT's own coordinator
	// mirrors the same session (restored from the authority's snapshot, see
	// GameplayAbilityWorldCoordinator::restore_snapshot) to run the SAME
	// registered provider locally for prediction
	// (PredictingComponent::predict_target_intent_full submits straight to
	// the client's own coordinator, resolving through THIS component with
	// role NETWORK_CLIENT). This entry point takes no caller-supplied
	// provenance (unlike the other three task entry points) and must not
	// grow new public API just to carry one, so the expected provenance is
	// derived from this component's own role instead of hardcoded to one
	// value.
	const Status role_status = check_role(
			component_role == ComponentRole::NETWORK_CLIENT ?
					ChangeProvenance::PREDICTED :
					ChangeProvenance::AUTHORITATIVE);
	if (!role_status.ok()) {
		result.status = role_status;
		return result;
	}
	if (queue.is_dispatching()) {
		// `p_context` may point at a caller-local temporary (see
		// GameplayAbilityWorldCoordinator::resolve_session's `task_context`),
		// so the deferred closure captures a VALUE copy rather than the
		// pointer itself -- the pointer would otherwise dangle by the time
		// this replays.
		const bool has_context = p_context != nullptr;
		const TargetEffectContext context_copy =
				has_context ? *p_context : TargetEffectContext{};
		const Status queued_status = queue.request_mutation(
				[this, p_task, p_session, p_tick, p_status, has_context,
						context_copy]() {
					complete_target_task(p_task, p_session, p_tick,
							p_status,
							has_context ? &context_copy : nullptr);
				});
		result.status = queued_status;
		result.queued = queued_status.ok();
		return result;
	}
	result = task_runtime.complete_target(p_task, p_tick, p_session,
			p_status, p_context);
	if (result.transitioned) {
		enqueue_task_event(result.event);
		queue.dispatch();
		flush_change_tracking();
	}
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return result;
}

Status AbilityComponent::acknowledge_task_authority(PredictionKey p_prediction_key,
		Tick p_tick) {
	last_known_tick = p_tick;
	if (!p_prediction_key) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_TASK_PAYLOAD);
	}
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	// An authority-role component's own WAIT_AUTHORITY tasks always complete
	// immediately at start (see AbilityTaskRuntime::start's `complete_immediately`
	// branch for AUTHORITATIVE provenance), so any task still sitting in
	// `authority_index` by the time this is called belongs to a
	// NETWORK_CLIENT-role component's predicted execution waiting on a later
	// acknowledgement. This entry point takes no caller-supplied provenance
	// (unlike the other three task entry points) and must not grow new public
	// API just to carry one, so the PREDICTED-only expectation is hardcoded.
	const Status role_status = check_role(ChangeProvenance::PREDICTED);
	if (!role_status.ok()) {
		return role_status;
	}
	if (queue.is_dispatching()) {
		return queue.request_mutation(
				[this, p_prediction_key, p_tick]() {
					acknowledge_task_authority(p_prediction_key, p_tick);
				});
	}
	bool task_fanout_truncated = false;
	enqueue_task_events(task_runtime.advance_to(p_tick, &task_fanout_truncated));
	enqueue_task_events(task_runtime.acknowledge_authority(p_prediction_key, p_tick));
	if (task_fanout_truncated) {
		emit_task_fanout_truncated(p_tick);
	}
	queue.dispatch();
	flush_change_tracking();
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return ok_status();
}

void AbilityComponent::notify_restored_ability_tasks(Tick p_tick) {
	for (AbilityTaskHandle handle : task_runtime.active_handles()) {
		const ActiveAbilityTask *active = task_runtime.find(handle);
		if (active == nullptr) {
			continue;
		}
		AbilityTaskEvent event;
		event.task = active->handle;
		event.owner = active->owner;
		event.execution = active->execution;
		event.spec = active->spec;
		event.ability = active->ability;
		event.kind = active->request.kind;
		event.outcome = AbilityTaskOutcome::ACTIVE;
		event.tick = p_tick;
		event.provenance = active->provenance;
		event.prediction_key = active->prediction_key;
		event.restored = true;
		event.task_visibility = active->request.visibility;
		enqueue_task_event(event);
	}
	queue.dispatch();
	flush_change_tracking();
}

void AbilityComponent::dispatch_task_event(const AbilityTaskEvent &p_event) {
	for (const auto &listener : task_listeners) {
		listener(p_event, queue);
	}
	if (p_event.outcome == AbilityTaskOutcome::ACTIVE || p_event.restored) {
		return;
	}

	const ActiveExecution *execution = find_execution(p_event.execution);
	if (execution == nullptr ||
			(execution->phase != ExecutionPhase::BEGUN &&
					execution->phase != ExecutionPhase::ACTIVE)) {
		return;
	}
	const AbilityGrant *grant = find_grant(execution->spec);
	const AbilityDefinition *definition = ability_registry->find(execution->ability);
	if (grant == nullptr || definition == nullptr ||
			definition->hook_binding == AbilityHookBinding::NONE) {
		return;
	}

	const AbilityExecutionContext context =
			build_execution_context(*execution, *grant, *definition, p_event.tick);
	const bool prediction_mode =
			definition->hook_binding == AbilityHookBinding::PREDICTION_SAFE;
	AbilityCommandBuilder builder(*effect_registry, execution->targets,
			prediction_mode, task_runtime.allocator_next_raw());
	Status hook_status = ok_status();
	if (prediction_mode) {
		auto it = prediction_hooks.find(execution->ability);
		if (it != prediction_hooks.end() && it->second != nullptr) {
			hook_status = it->second->on_task_event(context, p_event, builder);
		}
	} else {
		auto it = authority_hooks.find(execution->ability);
		if (it != authority_hooks.end() && it->second != nullptr) {
			hook_status = it->second->on_task_event(context, p_event, builder);
		}
	}
	if (!builder.violation_status().ok()) {
		emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
				execution->spec, execution->id, builder.violation_status(),
				p_event.tick);
		return;
	}
	if (!hook_status.ok()) {
		emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
				execution->spec, execution->id, hook_status, p_event.tick);
		return;
	}
	if (!builder.commands().empty()) {
		queue.request_mutation([this, execution_id = execution->id,
									 commands = builder.commands(), tick = p_event.tick]() mutable {
			apply_task_callback_commands(execution_id, std::move(commands), tick);
		});
	}
}

void AbilityComponent::apply_task_callback_commands(ExecutionId p_execution,
		std::vector<AbilityHookCommand> p_commands, Tick p_tick) {
	const ActiveExecution *execution = find_execution(p_execution);
	if (execution == nullptr) {
		return;
	}
	const AbilityGrant *grant = find_grant(execution->spec);
	const AbilityDefinition *definition = ability_registry->find(execution->ability);
	if (grant == nullptr || definition == nullptr) {
		return;
	}
	const AbilitySpecId execution_spec = execution->spec;

	// Validate the whole task/lifecycle portion before the first mutation.
	std::uint64_t expected_task = task_runtime.allocator_next_raw();
	bool terminal_command_seen = false;
	ExecutionPhase simulated_phase = execution->phase;
	std::size_t simulated_component_tasks = task_runtime.size();
	std::set<AbilityTaskHandle> simulated_parent_tasks;
	for (AbilityTaskHandle task :
			task_runtime.tasks_for_execution(p_execution)) {
		simulated_parent_tasks.insert(task);
	}
	for (const AbilityHookCommand &command : p_commands) {
		if (terminal_command_seen) {
			emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
					execution->spec, execution->id,
					make_status(StatusCode::CAPABILITY_VIOLATION,
							DiagnosticId::HOOK_CAPABILITY_DENIED),
					p_tick);
			return;
		}
		switch (command.kind) {
			case AbilityHookCommandKind::START_TASK: {
				++expected_task;
				if (command.task.value != expected_task ||
						!task_runtime.validate_start_request(command.task_request, p_tick,
								execution->provenance)
								 .ok() ||
						simulated_component_tasks >=
								MAX_ACTIVE_ABILITY_TASKS ||
						simulated_parent_tasks.size() >=
								MAX_ABILITY_TASKS_PER_EXECUTION) {
					emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
							execution->spec, execution->id,
							make_status(StatusCode::INVALID_ABILITY_TASK,
									DiagnosticId::INVALID_TASK_PAYLOAD,
									command.task.value),
							p_tick);
					return;
				}
				++simulated_component_tasks;
				simulated_parent_tasks.insert(command.task);
				break;
			}
			case AbilityHookCommandKind::CANCEL_TASK: {
				const ActiveAbilityTask *task = task_runtime.find(command.task);
				if (task == nullptr || task->execution != p_execution ||
						simulated_parent_tasks.erase(command.task) == 0) {
					emit_diagnostic(AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
							execution->spec, execution->id,
							make_status(StatusCode::CAPABILITY_VIOLATION,
									DiagnosticId::TASK_PARENT_MISSING,
									command.task.value),
							p_tick);
					return;
				}
				--simulated_component_tasks;
				break;
			}
			case AbilityHookCommandKind::COMMIT_EXECUTION:
				if (simulated_phase != ExecutionPhase::BEGUN) {
					return;
				}
				if (definition->ends_on_commit) {
					terminal_command_seen = true;
					simulated_phase = ExecutionPhase::ENDED;
				} else {
					simulated_phase = ExecutionPhase::ACTIVE;
				}
				break;
			case AbilityHookCommandKind::END_EXECUTION:
				if (simulated_phase != ExecutionPhase::ACTIVE) {
					return;
				}
				terminal_command_seen = true;
				simulated_phase = ExecutionPhase::ENDED;
				break;
			case AbilityHookCommandKind::CANCEL_EXECUTION:
				terminal_command_seen = true;
				simulated_phase = ExecutionPhase::CANCELLED;
				break;
			case AbilityHookCommandKind::APPLY_SELF_EFFECT:
			case AbilityHookCommandKind::APPLY_TARGET_EFFECT: {
				const EntityId target =
						command.kind ==
										AbilityHookCommandKind::
												APPLY_TARGET_EFFECT
						? command.explicit_target
						: owner_entity;
				if (target == owner_entity) {
					EffectSpec spec;
					spec.definition =
							command.effect_definition;
					spec.source = owner_entity;
					spec.target = owner_entity;
					spec.level = grant->level;
					spec.set_by_caller =
							command.set_by_caller;
					const Status status =
							effect_runtime.preflight_apply(
									spec, p_tick,
									&attribute_set,
									&tag_container);
					if (!status.ok()) {
						emit_diagnostic(
								AbilityDiagnosticKind::
										CAPABILITY_VIOLATION_DETECTED,
								execution->spec,
								execution->id, status,
								p_tick);
						return;
					}
				}
				break;
			}
			default:
				break;
		}
	}

	AbilityComponentBatchCapture before;
	Status batch_status = capture_target_batch_state(before);
	if (!batch_status.ok()) {
		emit_diagnostic(
				AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
				execution->spec, execution->id, batch_status, p_tick);
		return;
	}
	batch_status = begin_target_batch_publication();
	if (!batch_status.ok()) {
		emit_diagnostic(
				AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
				execution->spec, execution->id, batch_status, p_tick);
		return;
	}
	auto rollback_batch = [this, &before]() {
		const Status hold_status =
				rollback_target_batch_publication();
		const Status restore_status =
				restore_target_batch_state(before);
		return hold_status.ok() ? restore_status : hold_status;
	};

	for (const AbilityHookCommand &command : p_commands) {
		const ActiveExecution *current = find_execution(p_execution);
		if (current == nullptr) {
			batch_status = make_status(StatusCode::CAPABILITY_VIOLATION,
					DiagnosticId::TASK_PARENT_MISSING,
					p_execution.value);
			break;
		}
		switch (command.kind) {
			case AbilityHookCommandKind::START_TASK: {
				batch_status =
						start_ability_task(p_execution,
								command.task_request, p_tick,
								current->provenance,
								command.task)
								.status;
				break;
			}
			case AbilityHookCommandKind::CANCEL_TASK: {
				batch_status =
						cancel_ability_task(command.task, p_tick,
								command.task_cancel_reason,
								current->provenance)
								.status;
				break;
			}
			case AbilityHookCommandKind::COMMIT_EXECUTION: {
				std::vector<PendingRemoteEffectCommand> remote;
				batch_status = commit_activation(p_execution, p_tick,
						&remote);
				if (batch_status.ok() && !remote.empty()) {
					emit_diagnostic(
							AbilityDiagnosticKind::
									PENDING_REMOTE_EFFECT_DROPPED,
							current->spec, current->id,
							make_status(StatusCode::NOT_SUPPORTED,
									DiagnosticId::
											REMOTE_EFFECT_UNCONSUMED,
									remote.size()),
							p_tick);
				}
				break;
			}
			case AbilityHookCommandKind::END_EXECUTION:
				batch_status = end_execution(p_execution, p_tick,
						current->provenance);
				break;
			case AbilityHookCommandKind::CANCEL_EXECUTION:
				batch_status = cancel_execution(p_execution, p_tick,
						current->provenance,
						ExecutionEndReason::EXPLICIT_CANCEL)
									 .status;
				break;
			case AbilityHookCommandKind::EMIT_GAMEPLAY_EVENT:
				batch_status =
						handle_gameplay_event(command.event, p_tick);
				break;
			case AbilityHookCommandKind::APPLY_SELF_EFFECT:
			case AbilityHookCommandKind::APPLY_TARGET_EFFECT: {
				const EntityId target =
						command.kind == AbilityHookCommandKind::APPLY_TARGET_EFFECT
						? command.explicit_target
						: owner_entity;
				if (target != owner_entity) {
					emit_diagnostic(AbilityDiagnosticKind::PENDING_REMOTE_EFFECT_DROPPED,
							current->spec, current->id, ok_status(), p_tick);
					break;
				}
				EffectSpec spec;
				spec.definition = command.effect_definition;
				spec.source = owner_entity;
				spec.target = owner_entity;
				spec.level = grant->level;
				spec.set_by_caller = command.set_by_caller;
				Transaction txn(next_transaction_id(), p_tick);
				EffectHandle handle;
				const Status apply_status = effect_runtime.apply(spec, p_tick,
						&attribute_set, &tag_container, txn, queue, handle,
						current->provenance, current->prediction_key, nullptr);
				TransactionScope scope(txn, queue);
				if (!apply_status.ok()) {
					scope.fail(apply_status);
				}
				batch_status = scope.finish();
				if (handle) {
					auto it = executions.find(p_execution);
					if (it != executions.end()) {
						it->second.owned_effect_handles.push_back(handle);
					}
				}
				break;
			}
		}
		if (!batch_status.ok()) {
			break;
		}
	}
	if (!batch_status.ok()) {
		const Status rollback_status = rollback_batch();
		if (!rollback_status.ok()) {
			batch_status = rollback_status;
		}
		emit_diagnostic(
				AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
				execution_spec, p_execution, batch_status, p_tick);
		return;
	}
	batch_status = commit_target_batch_publication(p_tick);
	if (!batch_status.ok()) {
		// `commit_hold` cannot fail after the successful begin above unless
		// an internal invariant was violated. Restore state even though this
		// path should be unreachable.
		restore_target_batch_state(before);
		emit_diagnostic(
				AbilityDiagnosticKind::CAPABILITY_VIOLATION_DETECTED,
				execution_spec, p_execution, batch_status, p_tick);
	}
}

void AbilityComponent::flush_task_tag_edges(Tick p_tick) {
	if (!task_tag_state_dirty) {
		return;
	}
	task_tag_state_dirty = false;
	bool task_fanout_truncated = false;
	enqueue_task_events(task_runtime.notify_tag_state_changed(p_tick, &task_fanout_truncated));
	queue.dispatch();
	flush_change_tracking();
	if (task_fanout_truncated) {
		emit_task_fanout_truncated(p_tick);
	}
}

// ---------------------------------------------------------------------------
// Gameplay events
// ---------------------------------------------------------------------------

Status AbilityComponent::handle_gameplay_event(const GameplayEventContext &p_event, Tick p_tick) {
	last_known_tick = p_tick;
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	// Deadline/due work has canonical priority over a same-tick event.
	bool task_fanout_truncated = false;
	enqueue_task_events(task_runtime.advance_to(p_tick, &task_fanout_truncated));
	queue.dispatch();
	flush_change_tracking();
	if (task_fanout_truncated) {
		emit_task_fanout_truncated(p_tick);
	}
	const Status status = handle_gameplay_event_internal(p_event, p_tick, 0);
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return status;
}

Status AbilityComponent::handle_gameplay_event_internal(const GameplayEventContext &p_event, Tick p_tick, std::size_t p_depth) {
	if (p_depth >= MAX_EVENT_RECURSION) {
		const Status status = make_status(StatusCode::RECURSION_LIMIT, DiagnosticId::STACK_LIMIT_REACHED, p_depth);
		emit_diagnostic(AbilityDiagnosticKind::RECURSION_LIMIT_REACHED, INVALID_ABILITY_SPEC_ID, INVALID_EXECUTION_ID, status, p_tick);
		return status;
	}

	AbilityTaskGameplayEvent task_event;
	task_event.event_tag = p_event.event_tag;
	task_event.instigator = p_event.instigator;
	task_event.target = p_event.target;
	task_event.magnitude = p_event.magnitude;
	task_event.payload_tag = p_event.payload_tag;
	bool task_fanout_truncated = false;
	enqueue_task_events(task_runtime.notify_gameplay_event(task_event, p_tick, &task_fanout_truncated));
	queue.dispatch();
	flush_change_tracking();
	if (task_fanout_truncated) {
		emit_task_fanout_truncated(p_tick);
	}

	// Stable spec order: ascending AbilitySpecId (authority-assigned,
	// monotonic -- see ga_ids.h).
	for (AbilitySpecId spec : granted_specs()) {
		const AbilityGrant *grant = find_grant(spec);
		if (grant == nullptr || grant->revoked) {
			continue;
		}
		const AbilityDefinition *definition = ability_registry->find(grant->ability);
		if (definition == nullptr) {
			continue;
		}
		bool matches = false;
		for (const AbilityTrigger &trigger : definition->triggers) {
			if (trigger.kind == AbilityTriggerDesc::Kind::GAMEPLAY_EVENT && trigger.gameplay_event_tag == p_event.event_tag) {
				matches = true;
				break;
			}
		}
		if (!matches) {
			continue;
		}

		ActivationRequest request;
		request.spec = spec;
		request.provenance = ChangeProvenance::AUTHORITATIVE;
		request_activation_immediate(request, p_tick, p_depth, &p_event);
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Task 6.13 -- applying a PendingRemoteEffectCommand on its real target
// ---------------------------------------------------------------------------

Status AbilityComponent::apply_remote_effect(const PendingRemoteEffectCommand &p_command, Tick p_tick,
		const AttributeSet *p_source_attributes, const TagContainer *p_source_tags, EffectHandle &r_handle) {
	last_known_tick = p_tick;
	r_handle = INVALID_EFFECT_HANDLE;
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	// A remote-target effect is never predicted (task 8.4) -- this call is
	// UNCONDITIONALLY authoritative regardless of `p_command.provenance`, so
	// a `NETWORK_CLIENT` component (which `check_role` only ever admits a
	// `PREDICTED` change for) structurally cannot be driven through this
	// path no matter what a caller puts in `p_command`. See this method's
	// own doc comment in ga_ability_component.h.
	const Status role_status = check_role(ChangeProvenance::AUTHORITATIVE);
	if (!role_status.ok()) {
		return role_status;
	}
	if (p_command.target != owner_entity) {
		return make_status(StatusCode::CAPABILITY_VIOLATION, DiagnosticId::TARGET_NOT_RELEVANT, p_command.target.value);
	}

	EffectSpec spec;
	spec.definition = p_command.effect_definition;
	spec.source = p_command.source;
	spec.target = owner_entity;
	spec.level = p_command.level;
	spec.set_by_caller = p_command.set_by_caller;
	spec.target_context = p_command.target_context;

	Transaction txn(next_transaction_id(), p_tick);
	EffectHandle handle;
	const Status apply_status = effect_runtime.apply(spec, p_tick, p_source_attributes, p_source_tags, txn, queue, handle,
			ChangeProvenance::AUTHORITATIVE, INVALID_PREDICTION_KEY, nullptr);

	TransactionScope scope(txn, queue);
	if (!apply_status.ok()) {
		scope.fail(apply_status);
	}
	const Status commit_status = scope.finish();
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	if (!commit_status.ok()) {
		return commit_status;
	}
	r_handle = handle;
	return ok_status();
}

Status AbilityComponent::preflight_remote_effect(const PendingRemoteEffectCommand &p_command, Tick p_tick,
		const AttributeSet *p_source_attributes, const TagContainer *p_source_tags) const {
	PreparedEffectApplication prepared;
	return prepare_remote_effect(p_command, p_tick, p_source_attributes,
			p_source_tags, prepared);
}

Status AbilityComponent::prepare_remote_effect(
		const PendingRemoteEffectCommand &p_command, Tick p_tick,
		const AttributeSet *p_source_attributes,
		const TagContainer *p_source_tags,
		PreparedEffectApplication &r_prepared) const {
	r_prepared = PreparedEffectApplication{};
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	// A remote-target effect is never predicted (task 8.4) -- mirrors
	// `apply_remote_effect`'s own unconditional AUTHORITATIVE role check; see
	// that method's doc comment (ga_ability_component.h).
	const Status role_status = check_role(ChangeProvenance::AUTHORITATIVE);
	if (!role_status.ok()) {
		return role_status;
	}
	if (p_command.target != owner_entity) {
		return make_status(StatusCode::CAPABILITY_VIOLATION, DiagnosticId::TARGET_NOT_RELEVANT, p_command.target.value);
	}

	EffectSpec spec;
	spec.definition = p_command.effect_definition;
	spec.source = p_command.source;
	spec.target = owner_entity;
	spec.level = p_command.level;
	spec.set_by_caller = p_command.set_by_caller;
	spec.target_context = p_command.target_context;

	// No Transaction, no mutation, no `last_known_tick` update. In addition
	// to validation, the returned opaque value freezes fixed-point
	// magnitudes for the later cross-component commit.
	return effect_runtime.prepare_apply(spec, p_tick, p_source_attributes,
			p_source_tags, r_prepared);
}

Status AbilityComponent::begin_prepared_effect_mutation(Tick p_tick,
		PreparedAbilityComponentMutation &r_mutation) {
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::OWNER_FREED);
	}
	const Status role_status =
			check_role(ChangeProvenance::AUTHORITATIVE);
	if (!role_status.ok()) {
		return role_status;
	}
	if (r_mutation.transaction != nullptr || queue.is_dispatching()) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER);
	}
	Status status = queue.begin_hold();
	if (!status.ok()) {
		return status;
	}
	r_mutation.attribute_modifier_next =
			attribute_set.allocator_next_raw();
	r_mutation.effect_allocators =
			effect_runtime.capture_allocator_state();
	r_mutation.transaction_next = transaction_allocator.next_raw();
	r_mutation.last_known_tick = last_known_tick;
	r_mutation.transaction = std::make_unique<Transaction>(
			next_transaction_id(), p_tick);
	r_mutation.committed = false;
	r_mutation.finished = false;
	return ok_status();
}

Status AbilityComponent::apply_prepared_effect(
		const PreparedEffectApplication &p_prepared, Tick p_tick,
		const AttributeSet *p_source_attributes,
		const TagContainer *p_source_tags,
		PreparedAbilityComponentMutation &p_mutation,
		EffectHandle &r_handle) {
	r_handle = INVALID_EFFECT_HANDLE;
	if (p_mutation.transaction == nullptr || p_mutation.finished ||
			p_mutation.committed) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER);
	}
	last_known_tick = p_tick;
	return effect_runtime.apply_prepared(p_prepared, p_tick,
			p_source_attributes, p_source_tags,
			*p_mutation.transaction, queue, r_handle,
			ChangeProvenance::AUTHORITATIVE,
			INVALID_PREDICTION_KEY);
}

bool AbilityComponent::can_commit_prepared_effect_mutation(
		const PreparedAbilityComponentMutation &p_mutation) const {
	return p_mutation.transaction != nullptr && !p_mutation.finished &&
			!p_mutation.committed &&
			queue.can_enqueue(
					p_mutation.transaction->notification_count());
}

Status AbilityComponent::commit_prepared_effect_mutation(
		PreparedAbilityComponentMutation &p_mutation) {
	if (!can_commit_prepared_effect_mutation(p_mutation)) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	Status status = p_mutation.transaction->commit(queue);
	if (!status.ok()) {
		return status;
	}
	p_mutation.committed = true;
	p_mutation.finished = true;
	return ok_status();
}

Status AbilityComponent::rollback_prepared_effect_mutation(
		PreparedAbilityComponentMutation &p_mutation) {
	if (p_mutation.transaction == nullptr) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::SEQUENCE_OUT_OF_ORDER);
	}
	if (p_mutation.committed) {
		return make_status(StatusCode::INTERNAL_ERROR,
				DiagnosticId::TARGET_BATCH_ROLLED_BACK);
	}
	if (!p_mutation.finished) {
		p_mutation.transaction->rollback();
	}
	attribute_set.restore_allocator_exact(
			p_mutation.attribute_modifier_next);
	effect_runtime.restore_allocator_state_exact(
			p_mutation.effect_allocators);
	transaction_allocator.restore_exact(
			p_mutation.transaction_next);
	last_known_tick = p_mutation.last_known_tick;
	p_mutation.finished = true;
	return queue.rollback_hold();
}

// ---------------------------------------------------------------------------
// Ending & cancellation
// ---------------------------------------------------------------------------

Status AbilityComponent::end_execution(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance) {
	last_known_tick = p_tick;
	if (torn_down) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		return role_status;
	}
	const Status status = end_execution_immediate(p_execution, p_tick, p_provenance);
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return status;
}

Status AbilityComponent::end_execution_immediate(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance) {
	auto it = executions.find(p_execution);
	if (it == executions.end() || it->second.phase != ExecutionPhase::ACTIVE) {
		return make_status(StatusCode::ABILITY_ALREADY_ENDED, DiagnosticId::NONE, p_execution.value);
	}
	const ActiveExecution execution = it->second; // copy: the map entry is erased below

	Transaction txn(next_transaction_id(), p_tick);
	executions.erase(it);
	txn.add_undo([this, execution]() { executions[execution.id] = execution; });

	for (EffectHandle handle : execution.owned_effect_handles) {
		const Status status = effect_runtime.remove_effect(handle, p_tick, txn, queue, p_provenance, /*p_force_remove_all_stacks=*/true);
		if (!status.ok()) {
			txn.fail(status);
			TransactionScope scope(txn, queue);
			scope.finish();
			queue.dispatch();
			flush_change_tracking();
			flush_tag_reactions(p_tick);
			return status;
		}
	}

	AbilityLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = AbilityLifecycleKind::ENDED;
	event.owner = owner_entity;
	event.spec = execution.spec;
	event.ability = execution.ability;
	event.execution = execution.id;
	event.phase = ExecutionPhase::ENDED;
	event.end_reason = ExecutionEndReason::EXPLICIT_SUCCESS;
	event.tick = p_tick;
	event.transaction = txn.id();
	event.provenance = p_provenance;
	event.prediction_key = execution.prediction_key;
	event.cleaned_task_count = task_runtime.tasks_for_execution(execution.id).size();
	Status notify_status = emit_ability_event(event, txn);

	if (notify_status.ok() && execution.owned_tag_source) {
		const AbilityDefinition *definition = ability_registry->find(execution.ability);
		if (definition != nullptr && !definition->owned_tags.empty()) {
			std::vector<TagMutationOp> ops;
			ops.reserve(definition->owned_tags.size());
			for (DefinitionId tag : definition->owned_tags) {
				ops.push_back(TagMutationOp{ TagMutationOp::Kind::REMOVE, tag, execution.owned_tag_source });
			}
			const Status tag_status = tag_container.apply_mutations(ops, txn, queue);
			if (!tag_status.ok()) {
				txn.fail(tag_status);
				notify_status = tag_status;
			}
		}
	}

	TransactionScope scope(txn, queue);
	if (!notify_status.ok()) {
		scope.fail(notify_status);
	}
	const Status commit_status = scope.finish();
	if (commit_status.ok()) {
		task_runtime.cleanup_execution(execution.id,
				AbilityTaskCancelReason::PARENT_ENDED, p_tick);
	}
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	return commit_status;
}

CancellationResult AbilityComponent::cancel_execution(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance, ExecutionEndReason p_reason) {
	last_known_tick = p_tick;
	CancellationResult result;
	result.execution = p_execution;
	if (torn_down) {
		result.status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::OWNER_FREED);
		return result;
	}
	const Status role_status = check_role(p_provenance);
	if (!role_status.ok()) {
		result.status = role_status;
		return result;
	}
	result = cancel_execution_immediate(p_execution, p_tick, p_provenance, p_reason);
	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return result;
}

CancellationResult AbilityComponent::cancel_execution_immediate(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance, ExecutionEndReason p_reason) {
	CancellationResult result;
	result.execution = p_execution;

	auto it = executions.find(p_execution);
	if (it == executions.end()) {
		result.status = make_status(StatusCode::ABILITY_ALREADY_ENDED, DiagnosticId::NONE, p_execution.value);
		return result;
	}
	if (it->second.phase != ExecutionPhase::BEGUN && it->second.phase != ExecutionPhase::ACTIVE) {
		result.status = make_status(StatusCode::ABILITY_ALREADY_ENDED, DiagnosticId::NONE, p_execution.value);
		return result;
	}
	const ActiveExecution execution = it->second; // copy: the map entry is erased below

	Transaction txn(next_transaction_id(), p_tick);
	executions.erase(it);
	txn.add_undo([this, execution]() { executions[execution.id] = execution; });

	for (EffectHandle handle : execution.owned_effect_handles) {
		const Status status = effect_runtime.remove_effect(handle, p_tick, txn, queue, p_provenance, /*p_force_remove_all_stacks=*/true);
		if (!status.ok()) {
			txn.fail(status);
			TransactionScope scope(txn, queue);
			scope.finish();
			queue.dispatch();
			flush_change_tracking();
			flush_tag_reactions(p_tick);
			result.status = status;
			return result;
		}
	}

	AbilityLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = AbilityLifecycleKind::CANCELLED;
	event.owner = owner_entity;
	event.spec = execution.spec;
	event.ability = execution.ability;
	event.execution = execution.id;
	event.phase = ExecutionPhase::CANCELLED;
	event.end_reason = p_reason;
	event.tick = p_tick;
	event.transaction = txn.id();
	event.provenance = p_provenance;
	event.prediction_key = execution.prediction_key;
	event.cleaned_task_count = task_runtime.tasks_for_execution(execution.id).size();
	Status notify_status = emit_ability_event(event, txn);

	if (notify_status.ok() && execution.owned_tag_source) {
		const AbilityDefinition *definition = ability_registry->find(execution.ability);
		if (definition != nullptr && !definition->owned_tags.empty()) {
			std::vector<TagMutationOp> ops;
			ops.reserve(definition->owned_tags.size());
			for (DefinitionId tag : definition->owned_tags) {
				ops.push_back(TagMutationOp{ TagMutationOp::Kind::REMOVE, tag, execution.owned_tag_source });
			}
			const Status tag_status = tag_container.apply_mutations(ops, txn, queue);
			if (!tag_status.ok()) {
				txn.fail(tag_status);
				notify_status = tag_status;
			}
		}
	}

	TransactionScope scope(txn, queue);
	if (!notify_status.ok()) {
		scope.fail(notify_status);
	}
	result.status = scope.finish();
	if (result.status.ok()) {
		AbilityTaskCancelReason task_reason = AbilityTaskCancelReason::PARENT_CANCELLED;
		switch (p_reason) {
			case ExecutionEndReason::REVOKED:
				task_reason = AbilityTaskCancelReason::SPEC_REVOKED;
				break;
			case ExecutionEndReason::OWNER_TEARDOWN:
				task_reason = AbilityTaskCancelReason::OWNER_TEARDOWN;
				break;
			case ExecutionEndReason::AUTHORITY_CORRECTION:
				task_reason = AbilityTaskCancelReason::AUTHORITY_CORRECTION;
				break;
			default:
				break;
		}
		task_runtime.cleanup_execution(execution.id, task_reason, p_tick);
	}
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);
	return result;
}

bool AbilityComponent::has_execution(ExecutionId p_execution) const {
	return executions.find(p_execution) != executions.end();
}

const ActiveExecution *AbilityComponent::find_execution(ExecutionId p_execution) const {
	auto it = executions.find(p_execution);
	return it == executions.end() ? nullptr : &it->second;
}

std::vector<ExecutionId> AbilityComponent::active_executions() const {
	std::vector<ExecutionId> result;
	result.reserve(executions.size());
	for (const auto &entry : executions) {
		result.push_back(entry.first);
	}
	return result;
}

// ---------------------------------------------------------------------------
// Tick driver
// ---------------------------------------------------------------------------

Status AbilityComponent::advance_to(Tick p_tick) {
	last_known_tick = p_tick;
	if (torn_down) {
		return ok_status();
	}
	// Ability-task deadlines and due ticks precede tag edges, gameplay
	// events, logical input, and callback-produced commands at this tick.
	bool task_fanout_truncated = false;
	enqueue_task_events(task_runtime.advance_to(p_tick, &task_fanout_truncated));
	queue.dispatch();
	flush_change_tracking();
	if (task_fanout_truncated) {
		emit_task_fanout_truncated(p_tick);
	}

	Transaction txn(next_transaction_id(), p_tick);
	const Status status = effect_runtime.advance_to(p_tick, txn, queue);
	TransactionScope scope(txn, queue);
	if (!status.ok()) {
		scope.fail(status);
	}
	const Status commit_status = scope.finish();
	queue.dispatch();
	flush_change_tracking();
	flush_tag_reactions(p_tick);

	if (!draining) {
		draining = true;
		drain_pending_requests(p_tick);
		draining = false;
	}
	return commit_status;
}

// ---------------------------------------------------------------------------
// Reentrancy plumbing
// ---------------------------------------------------------------------------

void AbilityComponent::drain_pending_requests(Tick p_tick) {
	std::size_t iterations = 0;
	while (iterations < MAX_EVENT_RECURSION) {
		std::vector<std::function<void()>> pending = queue.take_pending_requests();
		if (pending.empty()) {
			return;
		}
		for (const std::function<void()> &fn : pending) {
			fn();
		}
		++iterations;
	}
	const std::vector<std::function<void()>> overflow = queue.take_pending_requests();
	if (!overflow.empty()) {
		const Status status = make_status(StatusCode::RECURSION_LIMIT, DiagnosticId::STACK_LIMIT_REACHED, overflow.size());
		emit_diagnostic(AbilityDiagnosticKind::RECURSION_LIMIT_REACHED, INVALID_ABILITY_SPEC_ID, INVALID_EXECUTION_ID, status, p_tick);
	}
}

void AbilityComponent::watch_cancel_tags() {
	tag_container.add_listener([this](const TagChangeRecord &record) {
		if (!record.added) {
			return; // cancel_tags queries only need to be (re)checked when something NEW is granted
		}
		// Defer: this listener runs during NotificationQueue::dispatch(), so
		// any mutation it wants (cancelling an execution) must go through
		// request_mutation rather than being applied reentrantly.
		queue.request_mutation([this]() {
			const std::vector<ExecutionId> ids = active_executions();
			for (ExecutionId id : ids) {
				const ActiveExecution *execution = find_execution(id);
				if (execution == nullptr || execution->phase != ExecutionPhase::ACTIVE) {
					continue;
				}
				const AbilityDefinition *definition = ability_registry->find(execution->ability);
				if (definition == nullptr) {
					continue;
				}
				if (!(definition->cancel_tags == TagQuery()) && definition->cancel_tags.evaluate(tag_container)) {
					cancel_execution_immediate(id, last_known_tick, ChangeProvenance::AUTHORITATIVE, ExecutionEndReason::CANCEL_TAG);
				}
			}
		});
	});
}

// ---------------------------------------------------------------------------
// Per-audience change tracking
// (add-granular-delta-replication-2026-07-27, tasks 1.1-1.4)
// ---------------------------------------------------------------------------

void AbilityComponent::watch_change_tracking() {
	attribute_set.add_listener([this](const AttributeChangeRecord &p_record, NotificationQueue &) {
		note_dirty(ChangeSection::ATTRIBUTE, p_record.attribute, /*p_owner_visible=*/true,
				visibility_config_.attribute_public(p_record.attribute));
	});
	tag_container.add_listener([this](const TagChangeRecord &p_record) {
		note_dirty(ChangeSection::TAG_SOURCE, p_record.source.value, /*p_owner_visible=*/true,
				visibility_config_.tag_public(p_record.tag));
	});
	effect_runtime.add_lifecycle_listener([this](const EffectLifecycleEvent &p_event, NotificationQueue &) {
		// No public exposure for effects today -- see
		// `AudienceVisibilityConfig`'s own comment on why ACTIVE_EFFECT is
		// OWNER_FACING only.
		note_dirty(ChangeSection::ACTIVE_EFFECT, p_event.handle.value, /*p_owner_visible=*/true, /*p_public_visible=*/false);
	});
	add_ability_task_listener([this](const AbilityTaskEvent &p_event, NotificationQueue &) {
		if (p_event.restored) {
			// A restore replays PRIOR state (task 5.8's "restore without
			// replay" contract); it is not a new change -- mirrors this
			// class's own `AbilityLifecycleKind::SNAPSHOT_RESTORED` exclusion
			// in `note_ability_lifecycle_dirty` below.
			return;
		}
		note_dirty(ChangeSection::ABILITY_TASK, p_event.task.value,
				task_visible_to(p_event.task_visibility, AbilityTaskVisibility::OWNER_ONLY),
				task_visible_to(p_event.task_visibility, AbilityTaskVisibility::OBSERVABLE));
	});
}

void AbilityComponent::note_dirty(ChangeSection p_section, std::uint64_t p_identity, bool p_owner_visible, bool p_public_visible) {
	if (p_owner_visible) {
		pending_owner_dirty_.push_back(DirtyRecord{ p_section, p_identity });
	}
	if (p_public_visible) {
		pending_public_dirty_.push_back(DirtyRecord{ p_section, p_identity });
	}
}

void AbilityComponent::note_ability_lifecycle_dirty(const AbilityLifecycleEvent &p_event) {
	switch (p_event.kind) {
		case AbilityLifecycleKind::GRANTED:
		case AbilityLifecycleKind::REVOKED:
			note_dirty(ChangeSection::ABILITY_GRANT, p_event.spec.value, /*p_owner_visible=*/true,
					visibility_config_.ability_public(p_event.ability));
			return;
		case AbilityLifecycleKind::PHASE_CHANGED:
			// PHASE_CHANGED also fires for BEGIN (`request_activation`), which
			// sets `grant.last_command_sequence` -- a field ABILITY_GRANT's own
			// delta/snapshot record carries (`write_grant_delta_record`/
			// `write_grants_section`). Without this mark, a peer that already
			// confirmed this grant's baseline would never learn the new
			// sequence through deltas alone. Every OTHER PHASE_CHANGED
			// transition leaves the grant untouched, so this is a safe
			// over-approximation, not a precisely-conditioned one (see
			// `ChangeTracker::commit_change`'s own "a duplicate identity is
			// harmless, just slightly wasteful").
			note_dirty(ChangeSection::ABILITY_GRANT, p_event.spec.value, /*p_owner_visible=*/true,
					visibility_config_.ability_public(p_event.ability));
			// No public exposure for executions today -- see
			// `AudienceVisibilityConfig`'s own comment on why
			// ACTIVE_EXECUTION is OWNER_FACING only.
			note_dirty(ChangeSection::ACTIVE_EXECUTION, p_event.execution.value, /*p_owner_visible=*/true, /*p_public_visible=*/false);
			return;
		case AbilityLifecycleKind::COMMITTED:
			// COMMITTED sets `grant.cooldown_handle` whenever the ability
			// declares a cooldown effect (`commit_execution_body`) -- the same
			// gap PHASE_CHANGED's own comment above describes, for the SAME
			// ABILITY_GRANT record's cooldown field instead of its command
			// sequence. Committed executions with no cooldown effect leave the
			// grant untouched; marking it dirty anyway is the same safe
			// over-approximation as above.
			note_dirty(ChangeSection::ABILITY_GRANT, p_event.spec.value, /*p_owner_visible=*/true,
					visibility_config_.ability_public(p_event.ability));
			note_dirty(ChangeSection::ACTIVE_EXECUTION, p_event.execution.value, /*p_owner_visible=*/true, /*p_public_visible=*/false);
			return;
		case AbilityLifecycleKind::ENDED:
		case AbilityLifecycleKind::CANCELLED:
			// Neither mutates a grant field (see `commit_execution_body`/
			// execution-teardown paths) -- ACTIVE_EXECUTION only. No public
			// exposure for executions today -- see `AudienceVisibilityConfig`'s
			// own comment on why ACTIVE_EXECUTION is OWNER_FACING only.
			note_dirty(ChangeSection::ACTIVE_EXECUTION, p_event.execution.value, /*p_owner_visible=*/true, /*p_public_visible=*/false);
			return;
		case AbilityLifecycleKind::REQUESTED:
		case AbilityLifecycleKind::FAILED:
			// Neither persists a record this ledger tracks: REQUESTED
			// precedes any state change, FAILED means nothing was created.
			return;
		case AbilityLifecycleKind::SNAPSHOT_RESTORED:
			// Replays prior state; not a new change (mirrors the ability-task
			// listener's identical `p_event.restored` exclusion above).
			return;
	}
}

void AbilityComponent::flush_change_tracking() {
	if (!pending_owner_dirty_.empty()) {
		change_tracker_.commit_change(ChangeAudience::OWNER_FACING, std::move(pending_owner_dirty_));
		pending_owner_dirty_.clear();
	}
	if (!pending_public_dirty_.empty()) {
		change_tracker_.commit_change(ChangeAudience::PUBLIC, std::move(pending_public_dirty_));
		pending_public_dirty_.clear();
	}
}

void AbilityComponent::record_target_session_change(TargetSessionId p_session, bool p_public_visible) {
	change_tracker_.commit_change(ChangeAudience::OWNER_FACING,
			{ DirtyRecord{ ChangeSection::TARGET_SESSION, p_session.value } });
	if (p_public_visible) {
		change_tracker_.commit_change(ChangeAudience::PUBLIC,
				{ DirtyRecord{ ChangeSection::TARGET_SESSION, p_session.value } });
	}
}

// ---------------------------------------------------------------------------
// Tag reactions (tasks 4.1-4.6)
// ---------------------------------------------------------------------------

namespace {

// Canonical DISPATCH-order value for `TagReactionMode` (design.md decision 4:
// "ON_REMOVED, then ON_ADDED, then WHILE_PRESENT" -- deliberately NOT the
// enum's own raw value, which is this type's unrelated AUTHORING order; see
// `TagReactionMode`'s own doc comment in ga_tag_reactions.h).
std::uint8_t reaction_dispatch_mode_order(TagReactionMode p_mode) {
	switch (p_mode) {
		case TagReactionMode::ON_REMOVED:
			return 0;
		case TagReactionMode::ON_ADDED:
			return 1;
		case TagReactionMode::WHILE_PRESENT:
			return 2;
	}
	return 3; // unreachable for a definition from a sealed registry
}

// Task 4.2's full canonical order: (1) operand tag identity, (2) EXACT before
// PARENT_AWARE (the enum's own raw values already sort that way -- EXACT=0,
// PARENT_AWARE=1), (3) `reaction_dispatch_mode_order` above, (4) reaction
// identifier. `p_a`/`p_b` are looked up in `p_registry`, which MUST be the
// same sealed registry `p_a`/`p_b` were produced from (every caller passes
// ids straight from `affected_reactions`/`canonical_order` on this exact
// registry).
bool reaction_canonical_less(const TagReactionRegistry &p_registry, DefinitionId p_a, DefinitionId p_b) {
	const TagReactionDefinition *a = p_registry.find(p_a);
	const TagReactionDefinition *b = p_registry.find(p_b);
	if (a == nullptr || b == nullptr) {
		return p_a < p_b; // unreachable for a sealed registry's own ids; fail closed to a stable order
	}
	if (a->operand_tag != b->operand_tag) {
		return a->operand_tag < b->operand_tag;
	}
	if (a->match_mode != b->match_mode) {
		return static_cast<std::uint8_t>(a->match_mode) < static_cast<std::uint8_t>(b->match_mode);
	}
	const std::uint8_t order_a = reaction_dispatch_mode_order(a->mode);
	const std::uint8_t order_b = reaction_dispatch_mode_order(b->mode);
	if (order_a != order_b) {
		return order_a < order_b;
	}
	return a->id < b->id;
}

} // namespace

void AbilityComponent::watch_tag_reactions() {
	// Unlike `watch_cancel_tags`, this listener never mutates or defers
	// anything itself -- it only accumulates the exact tag ids this
	// in-flight transaction changed. `flush_tag_reactions`, called right
	// after THIS transaction's own `queue.dispatch()` returns (see every
	// call site added alongside this task), does the actual diff/enqueue
	// work once, over the FULL accumulated set -- see that method's own doc
	// comment for why this split is correct and how it orders relative to
	// `watch_cancel_tags`'s deferred cancellations.
	tag_container.add_listener([this](const TagChangeRecord &record) {
		pending_reaction_tags.insert(record.tag);
	});
}

void AbilityComponent::reinitialize_tag_reaction_baselines() {
	reaction_truth_baseline.clear();
	pending_reaction_tags.clear(); // discard any not-yet-flushed accumulation too -- see doc comment
	if (!reactions_enabled) {
		return;
	}
	for (DefinitionId reaction_id : reaction_registry->canonical_order()) {
		const TagReactionDefinition *definition = reaction_registry->find(reaction_id);
		if (definition == nullptr) {
			continue; // unreachable for a sealed registry's own canonical_order()
		}
		const bool truth = (definition->match_mode == TagReactionMatchMode::EXACT)
				? tag_container.has_exact(definition->operand_tag)
				: tag_container.has_parent_aware(definition->operand_tag);
		reaction_truth_baseline[reaction_id] = truth;
	}
}

std::vector<TagReactionBinding> AbilityComponent::active_tag_reaction_bindings() const {
	std::vector<TagReactionBinding> result;
	result.reserve(while_present_bindings.size());
	for (const auto &entry : while_present_bindings) { // std::map ascending == canonical order
		result.push_back(TagReactionBinding{ entry.first, entry.second });
	}
	return result;
}

Status AbilityComponent::restore_tag_reaction_bindings(const std::vector<TagReactionBinding> &p_bindings) {
	if (p_bindings.empty()) {
		// Overwhelmingly common case (no reactions at all, or none currently
		// bound) -- never needs `reaction_registry`, so a reaction-less
		// component restores its (already empty) bindings for free.
		while_present_bindings.clear();
		return ok_status();
	}

	std::map<DefinitionId, EffectHandle> validated;
	for (const TagReactionBinding &binding : p_bindings) {
		if (reaction_registry == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::INVALID_REACTION_BINDING, binding.reaction);
		}
		const TagReactionDefinition *definition = reaction_registry->find(binding.reaction);
		if (definition == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::INVALID_REACTION_BINDING, binding.reaction);
		}
		if (definition->mode != TagReactionMode::WHILE_PRESENT) {
			// Only a WHILE_PRESENT reaction can ever have bound a handle
			// (task 4.4) -- a binding naming any other mode could not have
			// been produced by a conforming peer.
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::INVALID_REACTION_BINDING, binding.reaction);
		}
		const ActiveEffect *active = effect_runtime.find(binding.handle);
		if (active == nullptr) {
			return make_status(StatusCode::UNKNOWN_EFFECT_HANDLE, DiagnosticId::INVALID_REACTION_BINDING, binding.handle.value);
		}
		if (active->definition != definition->effect_id) {
			// The restored effect handle exists but does not name THIS
			// reaction's own registered target effect -- "Snapshot contains
			// an invalid reaction binding" / "incompatible target effect".
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::INVALID_REACTION_BINDING, binding.reaction);
		}
		if (validated.find(binding.reaction) != validated.end()) {
			// Non-canonical (duplicate) entry -- mirrors
			// `TagContainer::restore_snapshot`'s own stance on a
			// crafted/duplicated snapshot: reject rather than silently keep
			// the last one.
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, binding.reaction);
		}
		validated[binding.reaction] = binding.handle;
	}

	// Every entry validated -- install the whole batch in one shot; nothing
	// above ever touched `while_present_bindings` itself.
	while_present_bindings = std::move(validated);
	return ok_status();
}

void AbilityComponent::flush_tag_reactions(Tick p_tick) {
	// Task tag-query edges share the same post-transaction boundary as tag
	// reactions, but their terminal callbacks remain deferred through the
	// notification queue. This observes the whole committed tag batch once.
	flush_task_tag_edges(p_tick);

	if (!reactions_enabled || torn_down || pending_reaction_tags.empty()) {
		// Task 4.6 teardown: never accumulate across a torn-down component's
		// remaining lifetime either, so a later (still possible, e.g. a
		// still-unwinding nested call) accumulation cannot leak into some
		// future flush.
		pending_reaction_tags.clear();
		return;
	}
	const std::vector<DefinitionId> changed_tags(pending_reaction_tags.begin(), pending_reaction_tags.end());
	pending_reaction_tags.clear();

	// Task 4.1: ONLY the operands `affected_reactions` names for THIS
	// transaction's changed exact tags are diffed -- an unrelated overlapping
	// source or additional matching descendant never reaches this loop at
	// all, let alone produces an edge while truth is unchanged.
	const std::vector<DefinitionId> affected = reaction_registry->affected_reactions(changed_tags);
	std::vector<TagReactionEdge> edges;
	for (DefinitionId reaction_id : affected) {
		const TagReactionDefinition *definition = reaction_registry->find(reaction_id);
		if (definition == nullptr) {
			continue; // unreachable for a sealed registry's own affected_reactions()
		}
		const bool new_truth = (definition->match_mode == TagReactionMatchMode::EXACT)
				? tag_container.has_exact(definition->operand_tag)
				: tag_container.has_parent_aware(definition->operand_tag);

		auto baseline_it = reaction_truth_baseline.find(reaction_id);
		const bool old_truth = (baseline_it != reaction_truth_baseline.end()) ? baseline_it->second : false;
		if (old_truth == new_truth) {
			continue; // no transition for this operand -- nothing to do, baseline already correct
		}
		// Baseline is updated UNCONDITIONALLY, even if the chain bound below
		// ends up dropping this edge -- the underlying tag transaction stays
		// committed regardless (design.md decision 5), so truth tracking must
		// not fall behind reality just because dispatch was cut short.
		reaction_truth_baseline[reaction_id] = new_truth;

		bool produces_edge = false;
		switch (definition->mode) {
			case TagReactionMode::ON_ADDED:
				produces_edge = (!old_truth && new_truth);
				break;
			case TagReactionMode::ON_REMOVED:
				produces_edge = (old_truth && !new_truth);
				break;
			case TagReactionMode::WHILE_PRESENT:
				produces_edge = true; // either direction is meaningful (apply vs. release)
				break;
		}
		if (!produces_edge) {
			continue;
		}
		edges.push_back(TagReactionEdge{ reaction_id, new_truth });
	}

	if (edges.empty()) {
		return;
	}

	// Task 4.5: checked at SCHEDULE time (not later, inside the deferred
	// batch) so a bound already exceeded never even enqueues work -- the
	// diagnostic fires exactly once for the whole stopped batch, naming the
	// chain that led here (`active_reaction_chain_path`), and nothing below
	// this point runs for these edges.
	if (active_reaction_chain_depth >= max_reaction_chain_depth) {
		emit_tag_reaction_diagnostic(TagReactionDiagnosticKind::CHAIN_LIMIT_REACHED, INVALID_DEFINITION_ID, ok_status(), p_tick, active_reaction_chain_path);
		return;
	}

	std::sort(edges.begin(), edges.end(), [this](const TagReactionEdge &a, const TagReactionEdge &b) {
		return reaction_canonical_less(*reaction_registry, a.reaction_id, b.reaction_id);
	});

	// Task 4.2: enqueued through the SAME deferred-mutation mechanism
	// `watch_cancel_tags` uses. `request_mutation` always defers (regardless
	// of `is_dispatching()`), so this batch runs later, as its own ordinary
	// transaction(s), never reentrantly inside this tag notification --
	// and, because every blocking-tag cancellation this SAME transaction
	// queued was queued DURING the `dispatch()` call that just returned
	// (strictly before this `flush_tag_reactions` call runs), it is already
	// ahead of this batch in `NotificationQueue`'s pending-request list
	// (task 4.6's "cancellation before reactions").
	queue.request_mutation([this, edges, chain_depth = active_reaction_chain_depth, chain_path = active_reaction_chain_path, p_tick]() {
		dispatch_reaction_batch(edges, chain_depth, chain_path, p_tick);
	});
}

void AbilityComponent::dispatch_reaction_batch(std::vector<TagReactionEdge> p_edges, std::size_t p_chain_depth, std::vector<std::string> p_chain_path, Tick p_tick) {
	if (torn_down) {
		return; // task 4.6: discard pending reaction work without applying effects
	}
	for (const TagReactionEdge &edge : p_edges) {
		if (torn_down) {
			return; // teardown may begin partway through this batch (e.g. a sibling edge's own effect commit)
		}
		const TagReactionDefinition *definition = reaction_registry->find(edge.reaction_id);
		if (definition == nullptr) {
			continue; // unreachable for a sealed registry's own ids
		}

		// Task 4.5: THIS edge, and anything ITS effect application causes,
		// runs one hop deeper than the batch it came from. Save/restore
		// around each edge so independent SIBLING edges in `p_edges` each
		// start their own subtree at `p_chain_depth + 1` rather than
		// accumulating across siblings.
		const std::size_t saved_depth = active_reaction_chain_depth;
		std::vector<std::string> saved_path = active_reaction_chain_path;
		active_reaction_chain_depth = p_chain_depth + 1;
		active_reaction_chain_path = p_chain_path;
		active_reaction_chain_path.push_back(definition->identifier);

		dispatch_single_reaction_edge(*definition, edge.truth_now, p_tick);

		active_reaction_chain_depth = saved_depth;
		active_reaction_chain_path = std::move(saved_path);
	}
}

void AbilityComponent::dispatch_single_reaction_edge(const TagReactionDefinition &p_definition, bool p_truth_now, Tick p_tick) {
	// V1 reactions always apply the effect from the owning component to
	// itself, with no target selector, context payload, set-by-caller value,
	// or level (design.md decision 3) -- so every `EffectSpec` below is just
	// `definition/source/target`, mirroring `commit_execution_body`'s own
	// `self_template` for a self-effect.
	EffectSpec spec;
	spec.definition = p_definition.effect_id;
	spec.source = owner_entity;
	spec.target = owner_entity;

	switch (p_definition.mode) {
		case TagReactionMode::ON_ADDED:
		case TagReactionMode::ON_REMOVED: {
			// Task 4.3: apply exactly once via the existing atomic
			// effect-transaction path. A failure creates nothing, does NOT
			// roll back the (already committed) triggering tag transaction,
			// and does NOT suppress the rest of this batch's edges (the
			// caller's loop continues regardless of what happens here).
			Transaction txn(next_transaction_id(), p_tick);
			EffectHandle handle;
			const Status apply_status = effect_runtime.apply(spec, p_tick, &attribute_set, &tag_container, txn, queue, handle,
					ChangeProvenance::AUTHORITATIVE, INVALID_PREDICTION_KEY, nullptr);
			TransactionScope scope(txn, queue);
			if (!apply_status.ok()) {
				scope.fail(apply_status);
			}
			const Status commit_status = scope.finish();
			queue.dispatch();
			flush_change_tracking();
			flush_tag_reactions(p_tick); // observe any tag change THIS application itself caused, at the incremented depth the caller just set
			if (!commit_status.ok()) {
				emit_tag_reaction_diagnostic(TagReactionDiagnosticKind::APPLICATION_FAILED, p_definition.id, commit_status, p_tick);
			}
			break;
		}
		case TagReactionMode::WHILE_PRESENT: {
			if (p_truth_now) {
				// False-to-true: apply once and bind the returned handle
				// (task 4.4). A binding should never already exist here (a
				// false-to-true edge only fires when the baseline was
				// false, and the true-to-false edge below always erases its
				// binding) -- defensive: treat an unexpected existing
				// binding as already-satisfied rather than double-applying.
				if (while_present_bindings.find(p_definition.id) != while_present_bindings.end()) {
					break;
				}
				Transaction txn(next_transaction_id(), p_tick);
				EffectHandle handle;
				const Status apply_status = effect_runtime.apply(spec, p_tick, &attribute_set, &tag_container, txn, queue, handle,
						ChangeProvenance::AUTHORITATIVE, INVALID_PREDICTION_KEY, nullptr);
				TransactionScope scope(txn, queue);
				if (!apply_status.ok()) {
					scope.fail(apply_status);
				}
				const Status commit_status = scope.finish();
				queue.dispatch();
				flush_change_tracking();
				flush_tag_reactions(p_tick);
				if (!commit_status.ok()) {
					// No binding recorded; no continuous retry while the
					// predicate stays true -- only a LATER false-to-true
					// edge tries again (spec "While-present application
					// fails").
					emit_tag_reaction_diagnostic(TagReactionDiagnosticKind::APPLICATION_FAILED, p_definition.id, commit_status, p_tick);
				} else {
					while_present_bindings[p_definition.id] = handle;
				}
			} else {
				// True-to-false: remove EXACTLY the bound handle once.
				auto it = while_present_bindings.find(p_definition.id);
				if (it == while_present_bindings.end()) {
					// Nothing bound (its own false-to-true application must
					// have failed) -- not "stale" (never existed), so no
					// diagnostic; there is nothing to remove.
					break;
				}
				const EffectHandle handle = it->second;
				if (!effect_runtime.has_effect(handle)) {
					// Task 4.4: bound effect was removed externally before
					// this true-to-false edge -- clear the stale binding
					// with a diagnostic; do not attempt removal, and do not
					// recreate it (only the NEXT false-to-true edge may).
					while_present_bindings.erase(it);
					emit_tag_reaction_diagnostic(TagReactionDiagnosticKind::STALE_HANDLE_CLEARED, p_definition.id, ok_status(), p_tick);
					break;
				}
				Transaction txn(next_transaction_id(), p_tick);
				const Status remove_status = effect_runtime.remove_effect(handle, p_tick, txn, queue, ChangeProvenance::AUTHORITATIVE, /*p_force_remove_all_stacks=*/true);
				TransactionScope scope(txn, queue);
				if (!remove_status.ok()) {
					scope.fail(remove_status);
				}
				const Status commit_status = scope.finish();
				queue.dispatch();
				flush_change_tracking();
				// The binding is cleared regardless of outcome: this is the
				// one true-to-false edge for this predicate interval, and a
				// failed removal is reported like any other isolated
				// reaction failure, not retried (there is no "later edge"
				// for a true-to-false transition to retry from -- only a
				// FUTURE false-to-true edge starts a new predicate interval).
				while_present_bindings.erase(it);
				flush_tag_reactions(p_tick);
				if (!commit_status.ok()) {
					emit_tag_reaction_diagnostic(TagReactionDiagnosticKind::APPLICATION_FAILED, p_definition.id, commit_status, p_tick);
				}
			}
			break;
		}
	}
}

void AbilityComponent::emit_tag_reaction_diagnostic(TagReactionDiagnosticKind p_kind, DefinitionId p_reaction, Status p_status, Tick p_tick, std::vector<std::string> p_reaction_path) {
	TagReactionDiagnosticEvent event;
	event.kind = p_kind;
	event.owner = owner_entity;
	event.reaction = p_reaction;
	event.status = p_status;
	event.tick = p_tick;
	event.reaction_path = std::move(p_reaction_path);
	for (const TagReactionDiagnosticListener &listener : tag_reaction_diagnostic_listeners) {
		listener(event);
	}
}

void AbilityComponent::add_tag_reaction_diagnostic_listener(TagReactionDiagnosticListener p_listener) {
	tag_reaction_diagnostic_listeners.push_back(std::move(p_listener));
}

// ---------------------------------------------------------------------------
// Signals
// ---------------------------------------------------------------------------

void AbilityComponent::add_ability_listener(AbilityLifecycleListener p_listener) {
	ability_listeners.push_back(std::move(p_listener));
}

void AbilityComponent::add_diagnostic_listener(AbilityDiagnosticListener p_listener) {
	diagnostic_listeners.push_back(std::move(p_listener));
}

Status AbilityComponent::emit_ability_event(const AbilityLifecycleEvent &p_event, Transaction &p_txn) {
	const Status status = p_txn.add_notification([this, p_event]() {
		note_ability_lifecycle_dirty(p_event);
		for (const AbilityLifecycleListener &listener : ability_listeners) {
			listener(p_event, queue);
		}
	});
	if (!status.ok()) {
		p_txn.fail(status);
	}
	return status;
}

void AbilityComponent::emit_task_fanout_truncated(Tick p_tick) {
	emit_diagnostic(AbilityDiagnosticKind::TASK_FANOUT_TRUNCATED,
			INVALID_ABILITY_SPEC_ID, INVALID_EXECUTION_ID,
			make_status(StatusCode::CAPACITY_EXCEEDED,
					DiagnosticId::COUNT_LIMIT_EXCEEDED,
					MAX_TASK_TERMINAL_EVENTS_PER_TICK),
			p_tick);
}

void AbilityComponent::emit_diagnostic(AbilityDiagnosticKind p_kind, AbilitySpecId p_spec, ExecutionId p_execution, Status p_status, Tick p_tick) {
	AbilityDiagnosticEvent event;
	event.kind = p_kind;
	event.owner = owner_entity;
	event.spec = p_spec;
	event.execution = p_execution;
	event.status = p_status;
	event.tick = p_tick;
	for (const AbilityDiagnosticListener &listener : diagnostic_listeners) {
		listener(event);
	}
}

// ---------------------------------------------------------------------------
// Canonical snapshots
// ---------------------------------------------------------------------------

Status AbilityComponent::capture_target_batch_state(
		AbilityComponentBatchCapture &r_capture) const {
	SnapshotWriter writer;
	Status status = write_snapshot(writer);
	if (!status.ok()) {
		return status;
	}
	r_capture.snapshot = writer.take();
	r_capture.attribute_modifier_next =
			attribute_set.allocator_next_raw();
	r_capture.effect_allocators =
			effect_runtime.capture_allocator_state();
	r_capture.spec_next = spec_allocator.next_raw();
	r_capture.execution_next = execution_allocator.next_raw();
	r_capture.transaction_next = transaction_allocator.next_raw();
	r_capture.event_next = event_allocator.next_raw();
	r_capture.owned_tag_source_next =
			owned_tag_source_allocator.next_raw();
	r_capture.last_known_tick = last_known_tick;
	r_capture.task_tag_state_dirty = task_tag_state_dirty;
	return ok_status();
}

Status AbilityComponent::restore_target_batch_state(
		const AbilityComponentBatchCapture &p_capture) {
	SnapshotReader reader(p_capture.snapshot);
	Status status = restore_snapshot(reader);
	if (!status.ok() || !reader.at_end()) {
		return status.ok() ?
				make_status(StatusCode::DECODE_FAILED,
						DiagnosticId::TRUNCATED_PAYLOAD) :
				status;
	}
	attribute_set.restore_allocator_exact(
			p_capture.attribute_modifier_next);
	effect_runtime.restore_allocator_state_exact(
			p_capture.effect_allocators);
	spec_allocator.restore_exact(p_capture.spec_next);
	execution_allocator.restore_exact(p_capture.execution_next);
	transaction_allocator.restore_exact(p_capture.transaction_next);
	event_allocator.restore_exact(p_capture.event_next);
	owned_tag_source_allocator.restore_exact(
			p_capture.owned_tag_source_next);
	last_known_tick = p_capture.last_known_tick;
	task_tag_state_dirty = p_capture.task_tag_state_dirty;
	return ok_status();
}

Status AbilityComponent::begin_target_batch_publication() {
	if (queue.is_dispatching()) {
		return make_status(StatusCode::CAPABILITY_VIOLATION,
				DiagnosticId::HOOK_CAPABILITY_DENIED);
	}
	return queue.begin_hold();
}

Status AbilityComponent::commit_target_batch_publication(Tick p_tick) {
	Status status = queue.commit_hold();
	if (!status.ok()) {
		return status;
	}
	if (!queue.is_holding()) {
		queue.dispatch();
		flush_change_tracking();
		flush_tag_reactions(p_tick);
	}
	return ok_status();
}

Status AbilityComponent::release_target_batch_publication_hold() {
	return queue.commit_hold();
}

Status AbilityComponent::rollback_target_batch_publication() {
	return queue.rollback_hold();
}

bool AbilityComponent::target_batch_publication_hold_changed() const {
	return queue.current_hold_changed();
}

Status AbilityComponent::write_snapshot(SnapshotWriter &p_writer,
		AbilityTaskVisibility p_task_audience,
		TargetResultVisibility p_target_context_audience) const {
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_COMPONENT)) {
		return p_writer.status();
	}
	p_writer.write_u64(owner_entity.value);
	p_writer.write_u8(static_cast<std::uint8_t>(component_role));

	Status status = attribute_set.write_snapshot(p_writer);
	if (!status.ok()) {
		return status;
	}
	status = tag_container.write_snapshot(p_writer);
	if (!status.ok()) {
		return status;
	}
	status = effect_runtime.write_snapshot(p_writer, p_target_context_audience);
	if (!status.ok()) {
		return status;
	}

	// Task 5.3: active WHILE_PRESENT reaction bindings, right after effects
	// (a restoring reader validates a binding's handle against the
	// just-restored EffectRuntime -- see restore_tag_reaction_bindings).
	// Written unconditionally (empty for a reaction-less or non-authority
	// component -- active_tag_reaction_bindings() already returns empty in
	// both cases) so the wire layout is identical regardless of role or
	// catalog.
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDINGS)) {
		return p_writer.status();
	}
	const std::vector<TagReactionBinding> bindings = active_tag_reaction_bindings();
	p_writer.write_count(bindings.size(), MAX_ACTIVE_REACTION_BINDINGS);
	for (const TagReactionBinding &binding : bindings) {
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDING_ENTRY)) {
			return p_writer.status();
		}
		p_writer.write_u32(binding.reaction);
		p_writer.write_u64(binding.handle.value);
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}

	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANTS)) {
		return p_writer.status();
	}
	p_writer.write_count(grants.size(), MAX_ABILITY_GRANTS);
	for (const auto &entry : grants) {
		const AbilityGrant &grant = entry.second;
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANT_ENTRY)) {
			return p_writer.status();
		}
		p_writer.write_u64(grant.spec.value);
		p_writer.write_u32(grant.ability);
		p_writer.write_i32(grant.level);
		p_writer.write_string(grant.input_id);
		p_writer.write_bool(grant.revoked);
		p_writer.write_u64(grant.cooldown_handle.value);
		p_writer.write_u64(grant.last_command_sequence.value);
		p_writer.write_u64(grant.revision);
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}

	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTIONS)) {
		return p_writer.status();
	}
	p_writer.write_count(executions.size(), MAX_ACTIVE_EXECUTIONS);
	for (const auto &entry : executions) {
		const ActiveExecution &execution = entry.second;
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTION_ENTRY)) {
			return p_writer.status();
		}
		p_writer.write_u64(execution.id.value);
		p_writer.write_u64(execution.spec.value);
		p_writer.write_u32(execution.ability);
		p_writer.write_u8(static_cast<std::uint8_t>(execution.phase));
		p_writer.write_u64(execution.begin_tick);
		p_writer.write_u64(execution.commit_tick);
		p_writer.write_u64(execution.owned_tag_source.value);

		p_writer.write_count(execution.owned_effect_handles.size(), MAX_ACTIVE_EFFECTS);
		for (EffectHandle handle : execution.owned_effect_handles) {
			p_writer.write_u64(handle.value);
		}
		p_writer.write_count(execution.targets.size(), MAX_TARGETS_PER_COMMAND);
		for (EntityId target : execution.targets) {
			p_writer.write_u64(target.value);
		}
		p_writer.write_count(execution.set_by_caller.size(), MAX_SET_BY_CALLER);
		for (const SetByCallerMagnitude &magnitude : execution.set_by_caller) {
			p_writer.write_string(magnitude.field);
			p_writer.write_fixed(magnitude.value);
		}
		p_writer.write_u8(static_cast<std::uint8_t>(execution.provenance));
		p_writer.write_u64(execution.revision);

		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}

	status = task_runtime.write_snapshot(p_writer, p_task_audience);
	if (!status.ok()) {
		return status;
	}

	if (!p_writer.end_section()) {
		return p_writer.status();
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityComponent::restore_snapshot(SnapshotReader &p_reader) {
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_COMPONENT)) {
		return p_reader.status();
	}
	std::uint64_t entity_value = 0;
	std::uint8_t role_raw = 0;
	if (!p_reader.read_u64(entity_value) || !p_reader.read_u8(role_raw)) {
		return p_reader.status();
	}
	if (role_raw > static_cast<std::uint8_t>(ComponentRole::NETWORK_CLIENT)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, role_raw);
	}

	// NOTE: attributes()/tags()/effects() restore directly into this
	// component's live subsystem objects (they cannot be default-constructed
	// standalone -- see file comment). Each of their OWN `restore_snapshot`
	// implementations already leaves ITS OWN state untouched on failure; a
	// failure on a LATER section here may still leave an EARLIER section's
	// state already replaced -- MIXED state, part new / part old, at THIS
	// core layer. This method itself does not (and, being section-at-a-time
	// with no whole-component undo buffer, structurally cannot cheaply)
	// roll that back; a bare caller here should still treat any non-OK
	// result as "discard and rebuild this whole component" rather than
	// assume partial consistency across subsystem boundaries.
	//
	// The Godot layer one level up (`GameplayAbilityComponent::
	// restore_snapshot`/`reconcile_snapshot`, native/godot/
	// gameplay_ability_component.cpp) is where "discard and rebuild" is
	// actually MADE UNNECESSARY for the common case: it captures this
	// component's pre-restore state via `write_snapshot()` before ever
	// calling down into this method, and on a non-OK result HERE, restores
	// that captured pre-state back through this SAME method -- well-defined
	// specifically because every section below builds into a local
	// temporary and only commits wholesale at its own tail (see each one's
	// own doc comment), so replaying the pre-state simply wholesale-
	// replaces every section again, identical in effect to a fresh restore,
	// with no partial-section state for it to trip over. Only if THAT
	// rollback restore also fails does the Godot wrapper give up and
	// quarantine itself -- see that pair's own doc comments for the full
	// rollback-then-quarantine contract (spec "Restoring a snapshot MUST
	// replace the covered state atomically").
	Status status = attribute_set.restore_snapshot(p_reader);
	if (!status.ok()) {
		return status;
	}
	status = tag_container.restore_snapshot(p_reader);
	if (!status.ok()) {
		return status;
	}
	status = effect_runtime.restore_snapshot(p_reader);
	if (!status.ok()) {
		return status;
	}

	// Task 5.3: active WHILE_PRESENT reaction bindings -- decoded into a
	// local vector first, then validated and installed in ONE call
	// (`restore_tag_reaction_bindings`) so an invalid binding is rejected
	// BEFORE any of this section's entries are installed (the "Snapshot
	// contains an invalid reaction binding" scenario's "before partial
	// restoration"), exactly like `restore_tag_reaction_bindings`'s own doc
	// comment documents. Validated against `effect_runtime`, which the
	// section above already restored -- so a handle reference here is
	// checked against the FINAL restored effect state, never a stale one.
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDINGS)) {
		return p_reader.status();
	}
	std::size_t binding_count = 0;
	if (!p_reader.read_count(binding_count, MAX_ACTIVE_REACTION_BINDINGS)) {
		return p_reader.status();
	}
	std::vector<TagReactionBinding> decoded_bindings;
	decoded_bindings.reserve(binding_count);
	for (std::size_t i = 0; i < binding_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDING_ENTRY)) {
			return p_reader.status();
		}
		std::uint32_t reaction_raw = 0;
		std::uint64_t handle_value = 0;
		if (!p_reader.read_u32(reaction_raw) || !p_reader.read_u64(handle_value)) {
			return p_reader.status();
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		decoded_bindings.push_back(TagReactionBinding{ DefinitionId(reaction_raw), EffectHandle{ handle_value } });
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}
	status = restore_tag_reaction_bindings(decoded_bindings);
	if (!status.ok()) {
		return status;
	}

	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANTS)) {
		return p_reader.status();
	}
	std::size_t grant_count = 0;
	if (!p_reader.read_count(grant_count, MAX_ABILITY_GRANTS)) {
		return p_reader.status();
	}
	std::map<AbilitySpecId, AbilityGrant> new_grants;
	std::uint64_t max_spec_value = 0;
	for (std::size_t i = 0; i < grant_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANT_ENTRY)) {
			return p_reader.status();
		}
		AbilityGrant grant;
		std::uint64_t spec_value = 0;
		std::uint64_t cooldown_value = 0;
		std::uint64_t sequence_value = 0;
		std::uint32_t ability_raw = 0;
		if (!p_reader.read_u64(spec_value) || !p_reader.read_u32(ability_raw) || !p_reader.read_i32(grant.level) ||
				!p_reader.read_string(grant.input_id) || !p_reader.read_bool(grant.revoked) ||
				!p_reader.read_u64(cooldown_value) || !p_reader.read_u64(sequence_value) || !p_reader.read_u64(grant.revision)) {
			return p_reader.status();
		}
		if (ability_registry->find(DefinitionId(ability_raw)) == nullptr) {
			return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, ability_raw);
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		grant.spec = AbilitySpecId{ spec_value };
		grant.ability = DefinitionId(ability_raw);
		grant.cooldown_handle = EffectHandle{ cooldown_value };
		grant.last_command_sequence = CommandSeq{ sequence_value };
		if (spec_value > max_spec_value) {
			max_spec_value = spec_value;
		}
		new_grants[grant.spec] = grant;
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}

	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTIONS)) {
		return p_reader.status();
	}
	std::size_t execution_count = 0;
	if (!p_reader.read_count(execution_count, MAX_ACTIVE_EXECUTIONS)) {
		return p_reader.status();
	}
	std::map<ExecutionId, ActiveExecution> new_executions;
	std::uint64_t max_execution_value = 0;
	for (std::size_t i = 0; i < execution_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTION_ENTRY)) {
			return p_reader.status();
		}
		ActiveExecution execution;
		std::uint64_t id_value = 0;
		std::uint64_t spec_value = 0;
		std::uint64_t tag_source_value = 0;
		std::uint32_t ability_raw = 0;
		std::uint8_t phase_raw = 0;
		std::uint8_t provenance_raw = 0;
		if (!p_reader.read_u64(id_value) || !p_reader.read_u64(spec_value) || !p_reader.read_u32(ability_raw) ||
				!p_reader.read_u8(phase_raw) || !p_reader.read_u64(execution.begin_tick) || !p_reader.read_u64(execution.commit_tick) ||
				!p_reader.read_u64(tag_source_value)) {
			return p_reader.status();
		}
		if (phase_raw > static_cast<std::uint8_t>(ExecutionPhase::CANCELLED)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, phase_raw);
		}
		if (ability_registry->find(DefinitionId(ability_raw)) == nullptr) {
			return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, ability_raw);
		}

		std::size_t handle_count = 0;
		if (!p_reader.read_count(handle_count, MAX_ACTIVE_EFFECTS)) {
			return p_reader.status();
		}
		for (std::size_t h = 0; h < handle_count; ++h) {
			std::uint64_t handle_value = 0;
			if (!p_reader.read_u64(handle_value)) {
				return p_reader.status();
			}
			execution.owned_effect_handles.push_back(EffectHandle{ handle_value });
		}
		std::size_t target_count = 0;
		if (!p_reader.read_count(target_count, MAX_TARGETS_PER_COMMAND)) {
			return p_reader.status();
		}
		for (std::size_t t = 0; t < target_count; ++t) {
			std::uint64_t target_value = 0;
			if (!p_reader.read_u64(target_value)) {
				return p_reader.status();
			}
			execution.targets.push_back(EntityId{ target_value });
		}
		std::size_t sbc_count = 0;
		if (!p_reader.read_count(sbc_count, MAX_SET_BY_CALLER)) {
			return p_reader.status();
		}
		for (std::size_t s = 0; s < sbc_count; ++s) {
			SetByCallerMagnitude magnitude;
			if (!p_reader.read_string(magnitude.field) || !p_reader.read_fixed(magnitude.value)) {
				return p_reader.status();
			}
			execution.set_by_caller.push_back(magnitude);
		}
		if (!p_reader.read_u8(provenance_raw) || !p_reader.read_u64(execution.revision)) {
			return p_reader.status();
		}
		if (provenance_raw > static_cast<std::uint8_t>(ChangeProvenance::PREDICTED)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, provenance_raw);
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}

		execution.id = ExecutionId{ id_value };
		execution.spec = AbilitySpecId{ spec_value };
		execution.ability = DefinitionId(ability_raw);
		execution.phase = static_cast<ExecutionPhase>(phase_raw);
		execution.owned_tag_source = SourceToken{ tag_source_value };
		execution.provenance = static_cast<ChangeProvenance>(provenance_raw);

		if (id_value > max_execution_value) {
			max_execution_value = id_value;
		}
		new_executions[execution.id] = execution;
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}

	status = task_runtime.restore_snapshot(p_reader,
			[&new_executions](ExecutionId p_execution, AbilitySpecId p_spec,
					DefinitionId p_ability) {
				auto it = new_executions.find(p_execution);
				return it != new_executions.end() && it->second.spec == p_spec &&
						it->second.ability == p_ability &&
						(it->second.phase == ExecutionPhase::BEGUN ||
								it->second.phase == ExecutionPhase::ACTIVE);
			});
	if (!status.ok()) {
		return status;
	}

	if (!p_reader.end_section()) {
		return p_reader.status();
	}

	grants = std::move(new_grants);
	executions = std::move(new_executions);
	spec_allocator.restore_from(max_spec_value + 1);
	execution_allocator.restore_from(max_execution_value + 1);
	task_tag_state_dirty = false;
	owner_entity = EntityId{ entity_value };
	// NOTE: `role_raw` is decoded and validated (so a malformed byte still
	// fails closed) but deliberately NOT applied to `component_role`: role is
	// this LOCAL instance's own authority/ownership stance (offline/server/
	// network-client), decided by which peer constructed it -- never a
	// property the snapshot's ORIGINATING peer should be able to dictate to
	// a restoring one.
	(void)role_raw;

	// Task 5.3/design.md decision 6: now that EVERY section (tags included)
	// has committed, reinitialize every reaction operand's truth baseline
	// from the just-restored tag state, so the FIRST post-restore committed
	// transaction diffs against restored values instead of a stale
	// pre-restore baseline -- see that method's own doc comment. A no-op if
	// `!reactions_enabled` (mirrors the constructor's own baselining call).
	// This is the ONE required call site: every restore path in this addon
	// (a plain restore, a rollback-on-failure restore, and
	// `PredictionReconciler::reconcile`'s own internal restore) converges on
	// THIS method, so no caller needs to remember to call it separately.
	reinitialize_tag_reaction_baselines();

	return ok_status();
}

AbilityLifecycleEvent AbilityComponent::make_snapshot_restored_event(const ActiveExecution &p_execution, Tick p_tick) const {
	AbilityLifecycleEvent event;
	event.kind = AbilityLifecycleKind::SNAPSHOT_RESTORED;
	event.owner = owner_entity;
	event.spec = p_execution.spec;
	event.ability = p_execution.ability;
	event.execution = p_execution.id;
	event.phase = p_execution.phase;
	event.tick = p_tick;
	event.provenance = p_execution.provenance;
	event.prediction_key = p_execution.prediction_key;
	return event;
}

// ---------------------------------------------------------------------------
// Canonical delta codec: ABILITY_GRANT and ACTIVE_EXECUTION per-record and
// whole-section codecs (add-granular-delta-replication-2026-07-27, task 2.1)
// ---------------------------------------------------------------------------

Status AbilityComponent::write_grant_delta_record(SnapshotWriter &p_writer, AbilitySpecId p_spec) const {
	const AbilityGrant *grant = find_grant(p_spec);
	if (grant == nullptr) {
		return make_status(StatusCode::ABILITY_NOT_GRANTED, DiagnosticId::NONE, p_spec.value);
	}
	p_writer.write_u64(grant->spec.value);
	p_writer.write_u32(grant->ability);
	p_writer.write_i32(grant->level);
	p_writer.write_string(grant->input_id);
	p_writer.write_bool(grant->revoked);
	p_writer.write_u64(grant->cooldown_handle.value);
	p_writer.write_u64(grant->last_command_sequence.value);
	p_writer.write_u64(grant->revision);
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityComponent::decode_grant_delta_record(SnapshotReader &p_reader, AbilityGrant &r_grant) const {
	AbilityGrant grant;
	std::uint64_t spec_value = 0;
	std::uint32_t ability_raw = 0;
	std::uint64_t cooldown_value = 0;
	std::uint64_t sequence_value = 0;
	if (!p_reader.read_u64(spec_value) || !p_reader.read_u32(ability_raw) || !p_reader.read_i32(grant.level) ||
			!p_reader.read_string(grant.input_id) || !p_reader.read_bool(grant.revoked) ||
			!p_reader.read_u64(cooldown_value) || !p_reader.read_u64(sequence_value) || !p_reader.read_u64(grant.revision)) {
		return p_reader.status();
	}
	if (ability_registry->find(DefinitionId(ability_raw)) == nullptr) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, ability_raw);
	}
	grant.spec = AbilitySpecId{ spec_value };
	grant.ability = DefinitionId(ability_raw);
	grant.cooldown_handle = EffectHandle{ cooldown_value };
	grant.last_command_sequence = CommandSeq{ sequence_value };
	r_grant = grant;
	return ok_status();
}

Status AbilityComponent::write_grants_section(SnapshotWriter &p_writer, const std::function<bool(DefinitionId)> &p_is_public) const {
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANTS)) {
		return p_writer.status();
	}
	std::vector<AbilitySpecId> visible;
	for (const auto &entry : grants) {
		if (p_is_public(entry.second.ability)) {
			visible.push_back(entry.first);
		}
	}
	p_writer.write_count(visible.size(), MAX_ABILITY_GRANTS);
	for (AbilitySpecId spec : visible) {
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANT_ENTRY)) {
			return p_writer.status();
		}
		const Status entry_status = write_grant_delta_record(p_writer, spec);
		if (!entry_status.ok()) {
			return entry_status;
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityComponent::decode_grants_section(SnapshotReader &p_reader, std::map<AbilitySpecId, AbilityGrant> &r_grants) const {
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANTS)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_ABILITY_GRANTS)) {
		return p_reader.status();
	}
	std::map<AbilitySpecId, AbilityGrant> decoded;
	for (std::size_t i = 0; i < count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_GRANT_ENTRY)) {
			return p_reader.status();
		}
		AbilityGrant grant;
		const Status entry_status = decode_grant_delta_record(p_reader, grant);
		if (!entry_status.ok()) {
			return entry_status;
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		decoded[grant.spec] = grant;
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}
	r_grants = std::move(decoded);
	return ok_status();
}

Status AbilityComponent::write_execution_delta_record(SnapshotWriter &p_writer, ExecutionId p_execution) const {
	const ActiveExecution *execution = find_execution(p_execution);
	if (execution == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_execution.value);
	}
	p_writer.write_u64(execution->id.value);
	p_writer.write_u64(execution->spec.value);
	p_writer.write_u32(execution->ability);
	p_writer.write_u8(static_cast<std::uint8_t>(execution->phase));
	p_writer.write_u64(execution->begin_tick);
	p_writer.write_u64(execution->commit_tick);
	p_writer.write_u64(execution->owned_tag_source.value);

	p_writer.write_count(execution->owned_effect_handles.size(), MAX_ACTIVE_EFFECTS);
	for (EffectHandle handle : execution->owned_effect_handles) {
		p_writer.write_u64(handle.value);
	}
	p_writer.write_count(execution->targets.size(), MAX_TARGETS_PER_COMMAND);
	for (EntityId target : execution->targets) {
		p_writer.write_u64(target.value);
	}
	p_writer.write_count(execution->set_by_caller.size(), MAX_SET_BY_CALLER);
	for (const SetByCallerMagnitude &magnitude : execution->set_by_caller) {
		p_writer.write_string(magnitude.field);
		p_writer.write_fixed(magnitude.value);
	}
	p_writer.write_u8(static_cast<std::uint8_t>(execution->provenance));
	p_writer.write_u64(execution->revision);
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityComponent::decode_execution_delta_record(SnapshotReader &p_reader, ActiveExecution &r_execution) const {
	ActiveExecution execution;
	std::uint64_t id_value = 0;
	std::uint64_t spec_value = 0;
	std::uint64_t tag_source_value = 0;
	std::uint32_t ability_raw = 0;
	std::uint8_t phase_raw = 0;
	std::uint8_t provenance_raw = 0;
	if (!p_reader.read_u64(id_value) || !p_reader.read_u64(spec_value) || !p_reader.read_u32(ability_raw) ||
			!p_reader.read_u8(phase_raw) || !p_reader.read_u64(execution.begin_tick) || !p_reader.read_u64(execution.commit_tick) ||
			!p_reader.read_u64(tag_source_value)) {
		return p_reader.status();
	}
	if (phase_raw > static_cast<std::uint8_t>(ExecutionPhase::CANCELLED)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, phase_raw);
	}
	if (ability_registry->find(DefinitionId(ability_raw)) == nullptr) {
		return make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, ability_raw);
	}

	std::size_t handle_count = 0;
	if (!p_reader.read_count(handle_count, MAX_ACTIVE_EFFECTS)) {
		return p_reader.status();
	}
	for (std::size_t h = 0; h < handle_count; ++h) {
		std::uint64_t handle_value = 0;
		if (!p_reader.read_u64(handle_value)) {
			return p_reader.status();
		}
		execution.owned_effect_handles.push_back(EffectHandle{ handle_value });
	}
	std::size_t target_count = 0;
	if (!p_reader.read_count(target_count, MAX_TARGETS_PER_COMMAND)) {
		return p_reader.status();
	}
	for (std::size_t t = 0; t < target_count; ++t) {
		std::uint64_t target_value = 0;
		if (!p_reader.read_u64(target_value)) {
			return p_reader.status();
		}
		execution.targets.push_back(EntityId{ target_value });
	}
	std::size_t sbc_count = 0;
	if (!p_reader.read_count(sbc_count, MAX_SET_BY_CALLER)) {
		return p_reader.status();
	}
	for (std::size_t s = 0; s < sbc_count; ++s) {
		SetByCallerMagnitude magnitude;
		if (!p_reader.read_string(magnitude.field) || !p_reader.read_fixed(magnitude.value)) {
			return p_reader.status();
		}
		execution.set_by_caller.push_back(magnitude);
	}
	if (!p_reader.read_u8(provenance_raw) || !p_reader.read_u64(execution.revision)) {
		return p_reader.status();
	}
	if (provenance_raw > static_cast<std::uint8_t>(ChangeProvenance::PREDICTED)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, provenance_raw);
	}

	execution.id = ExecutionId{ id_value };
	execution.spec = AbilitySpecId{ spec_value };
	execution.ability = DefinitionId(ability_raw);
	execution.phase = static_cast<ExecutionPhase>(phase_raw);
	execution.owned_tag_source = SourceToken{ tag_source_value };
	execution.provenance = static_cast<ChangeProvenance>(provenance_raw);

	r_execution = std::move(execution);
	return ok_status();
}

Status AbilityComponent::write_executions_section(SnapshotWriter &p_writer) const {
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTIONS)) {
		return p_writer.status();
	}
	p_writer.write_count(executions.size(), MAX_ACTIVE_EXECUTIONS);
	for (const auto &entry : executions) {
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTION_ENTRY)) {
			return p_writer.status();
		}
		const Status entry_status = write_execution_delta_record(p_writer, entry.first);
		if (!entry_status.ok()) {
			return entry_status;
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}
	if (!p_writer.end_section()) {
		return p_writer.status();
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityComponent::decode_executions_section(SnapshotReader &p_reader, std::map<ExecutionId, ActiveExecution> &r_executions) const {
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTIONS)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_ACTIVE_EXECUTIONS)) {
		return p_reader.status();
	}
	std::map<ExecutionId, ActiveExecution> decoded;
	for (std::size_t i = 0; i < count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_EXECUTION_ENTRY)) {
			return p_reader.status();
		}
		ActiveExecution execution;
		const Status entry_status = decode_execution_delta_record(p_reader, execution);
		if (!entry_status.ok()) {
			return entry_status;
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		decoded[execution.id] = execution;
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}
	r_executions = std::move(decoded);
	return ok_status();
}

// ---------------------------------------------------------------------------
// Canonical delta codec: RECORD_OPS-mode decode (add-granular-delta-
// replication-2026-07-27, task 2.3) -- see each method's own declaration
// comment (ga_ability_component.h) for the shared "copy current, apply ops"
// shape every one of these follows.
// ---------------------------------------------------------------------------

namespace {

// Task 2.2/2.3: reads and validates the `GA_SNAPSHOT_KIND_DELTA_RECORD_OP`
// op-list header shared by every RECORD_OPS section -- the ascending-
// identity, no-duplicate op count -- so the six `decode_*_record_ops`
// methods below do not each repeat this framing by hand. `p_apply_op` is
// invoked once per decoded op, already positioned to read that op's own
// body (if `p_op == DeltaOpKind::ADD`/`UPDATE`) with `p_identity` and
// `p_op` already validated; it must return non-OK to fail the WHOLE section
// closed (this function's own caller never installs a partially-applied
// merge).
Status decode_delta_record_ops(SnapshotReader &p_reader,
		const std::function<Status(std::uint64_t p_identity, DeltaOpKind p_op)> &p_apply_op) {
	std::size_t op_count = 0;
	if (!p_reader.read_count(op_count, MAX_DELTA_RECORD_OPS_PER_SECTION)) {
		return p_reader.status();
	}
	std::uint64_t previous_identity = 0;
	bool have_prior = false;
	for (std::size_t i = 0; i < op_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
			return p_reader.status();
		}
		std::uint64_t identity = 0;
		std::uint8_t op_raw = 0;
		if (!p_reader.read_u64(identity) || !p_reader.read_u8(op_raw)) {
			return p_reader.status();
		}
		if (!is_valid_delta_op_kind(op_raw)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, op_raw);
		}
		if (have_prior && identity <= previous_identity) {
			// Non-canonical (out-of-order or duplicate) op -- a well-formed
			// batch never encodes one (mirrors every whole-section
			// snapshot's identical canonical-order rejection, e.g.
			// `TagContainer::restore_snapshot`).
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, identity);
		}
		previous_identity = identity;
		have_prior = true;
		const Status apply_status = p_apply_op(identity, static_cast<DeltaOpKind>(op_raw));
		if (!apply_status.ok()) {
			return apply_status;
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
	}
	return ok_status();
}

} // namespace

Status AbilityComponent::decode_attribute_record_ops(SnapshotReader &p_reader,
		std::map<DefinitionId, AttributeValue> &r_attributes, std::vector<AttributeModifier> &r_modifiers) const {
	SnapshotWriter current_writer;
	Status status = attribute_set.write_snapshot(current_writer);
	if (!status.ok()) {
		return status;
	}
	std::vector<std::uint8_t> current_bytes = current_writer.take();
	SnapshotReader current_reader(current_bytes);
	std::map<DefinitionId, AttributeValue> attributes_copy;
	std::vector<AttributeModifier> modifiers_copy;
	status = attribute_set.decode_snapshot_section(current_reader, attributes_copy, modifiers_copy);
	if (!status.ok()) {
		return status;
	}

	status = decode_delta_record_ops(p_reader, [&](std::uint64_t p_identity, DeltaOpKind p_op) -> Status {
		const DefinitionId id = static_cast<DefinitionId>(p_identity);
		if (p_op == DeltaOpKind::REMOVE) {
			attributes_copy.erase(id);
			modifiers_copy.erase(std::remove_if(modifiers_copy.begin(), modifiers_copy.end(),
										 [id](const AttributeModifier &p_modifier) { return p_modifier.target_attribute == id; }),
					modifiers_copy.end());
			return ok_status();
		}
		DefinitionId decoded_id = INVALID_DEFINITION_ID;
		AttributeValue value;
		std::vector<AttributeModifier> record_modifiers;
		const Status record_status = attribute_set.decode_attribute_delta_record(p_reader, decoded_id, value, record_modifiers);
		if (!record_status.ok()) {
			return record_status;
		}
		if (decoded_id != id) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, decoded_id);
		}
		attributes_copy[id] = value;
		modifiers_copy.erase(std::remove_if(modifiers_copy.begin(), modifiers_copy.end(),
									 [id](const AttributeModifier &p_modifier) { return p_modifier.target_attribute == id; }),
				modifiers_copy.end());
		modifiers_copy.insert(modifiers_copy.end(), record_modifiers.begin(), record_modifiers.end());
		return ok_status();
	});
	if (!status.ok()) {
		return status;
	}

	// Re-derive canonical modifier order (target_attribute is the primary
	// key, so a stable sort by target alone already reproduces
	// `canonical_modifier_order`'s content order across DIFFERENT
	// attributes; each attribute's OWN modifier sub-list was already
	// written/decoded in canonical order by `write_attribute_delta_record`/
	// `decode_attribute_delta_record`).
	std::stable_sort(modifiers_copy.begin(), modifiers_copy.end(),
			[](const AttributeModifier &p_a, const AttributeModifier &p_b) { return p_a.target_attribute < p_b.target_attribute; });

	r_attributes = std::move(attributes_copy);
	r_modifiers = std::move(modifiers_copy);
	return ok_status();
}

Status AbilityComponent::decode_tag_source_record_ops(SnapshotReader &p_reader,
		std::map<DefinitionId, std::set<SourceToken>> &r_owners, std::uint64_t &r_revision) const {
	SnapshotWriter current_writer;
	Status status = tag_container.write_snapshot(current_writer);
	if (!status.ok()) {
		return status;
	}
	std::vector<std::uint8_t> current_bytes = current_writer.take();
	SnapshotReader current_reader(current_bytes);
	std::map<DefinitionId, std::set<SourceToken>> owners_copy;
	std::uint64_t revision_copy = 0;
	status = tag_container.decode_snapshot_section(current_reader, owners_copy, revision_copy);
	if (!status.ok()) {
		return status;
	}

	status = decode_delta_record_ops(p_reader, [&](std::uint64_t p_identity, DeltaOpKind p_op) -> Status {
		const SourceToken source{ p_identity };
		// A source token owns at most one tag at a time (see
		// `ga_change_tracking.h`'s `DirtyRecord` doc comment) -- remove it
		// from wherever it currently is before possibly re-adding it, so
		// both REMOVE and ADD/UPDATE share this one cleanup step.
		for (auto &entry : owners_copy) {
			entry.second.erase(source);
		}
		if (p_op == DeltaOpKind::REMOVE) {
			return ok_status();
		}
		DefinitionId tag = INVALID_DEFINITION_ID;
		const Status record_status = tag_container.decode_tag_source_delta_record(p_reader, tag);
		if (!record_status.ok()) {
			return record_status;
		}
		owners_copy[tag].insert(source);
		return ok_status();
	});
	if (!status.ok()) {
		return status;
	}

	// `TagContainer` only ever keeps a tag key while its owner set is
	// non-empty (see that class's own file comment) -- a REMOVE (or a move
	// that emptied a tag's set) must not leave a stale empty entry behind,
	// or `install_records`' `adjust_ancestor_index` pass would treat an
	// unowned tag as owned.
	for (auto it = owners_copy.begin(); it != owners_copy.end();) {
		if (it->second.empty()) {
			it = owners_copy.erase(it);
		} else {
			++it;
		}
	}

	r_owners = std::move(owners_copy);
	r_revision = revision_copy;
	return ok_status();
}

Status AbilityComponent::decode_grant_record_ops(SnapshotReader &p_reader, std::map<AbilitySpecId, AbilityGrant> &r_grants) const {
	std::map<AbilitySpecId, AbilityGrant> grants_copy = grants;
	const Status status = decode_delta_record_ops(p_reader, [&](std::uint64_t p_identity, DeltaOpKind p_op) -> Status {
		const AbilitySpecId spec{ p_identity };
		if (p_op == DeltaOpKind::REMOVE) {
			grants_copy.erase(spec);
			return ok_status();
		}
		AbilityGrant grant;
		const Status record_status = decode_grant_delta_record(p_reader, grant);
		if (!record_status.ok()) {
			return record_status;
		}
		if (grant.spec != spec) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, grant.spec.value);
		}
		grants_copy[spec] = grant;
		return ok_status();
	});
	if (!status.ok()) {
		return status;
	}
	r_grants = std::move(grants_copy);
	return ok_status();
}

Status AbilityComponent::decode_execution_record_ops(SnapshotReader &p_reader, std::map<ExecutionId, ActiveExecution> &r_executions) const {
	std::map<ExecutionId, ActiveExecution> executions_copy = executions;
	const Status status = decode_delta_record_ops(p_reader, [&](std::uint64_t p_identity, DeltaOpKind p_op) -> Status {
		const ExecutionId id{ p_identity };
		if (p_op == DeltaOpKind::REMOVE) {
			executions_copy.erase(id);
			return ok_status();
		}
		ActiveExecution execution;
		const Status record_status = decode_execution_delta_record(p_reader, execution);
		if (!record_status.ok()) {
			return record_status;
		}
		if (execution.id != id) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, execution.id.value);
		}
		executions_copy[id] = execution;
		return ok_status();
	});
	if (!status.ok()) {
		return status;
	}
	r_executions = std::move(executions_copy);
	return ok_status();
}

Status AbilityComponent::decode_effect_record_ops(SnapshotReader &p_reader, std::map<EffectHandle, ActiveEffect> &r_effects) const {
	SnapshotWriter current_writer;
	Status status = effect_runtime.write_snapshot(current_writer, TargetResultVisibility::INTERNAL);
	if (!status.ok()) {
		return status;
	}
	std::vector<std::uint8_t> current_bytes = current_writer.take();
	SnapshotReader current_reader(current_bytes);
	std::map<EffectHandle, ActiveEffect> effects_copy;
	status = effect_runtime.decode_snapshot_section(current_reader, effects_copy);
	if (!status.ok()) {
		return status;
	}

	status = decode_delta_record_ops(p_reader, [&](std::uint64_t p_identity, DeltaOpKind p_op) -> Status {
		const EffectHandle handle{ p_identity };
		if (p_op == DeltaOpKind::REMOVE) {
			effects_copy.erase(handle);
			return ok_status();
		}
		ActiveEffect effect;
		std::size_t context_bytes = 0;
		const Status record_status = effect_runtime.decode_active_effect_delta_record(p_reader, effect, context_bytes);
		if (!record_status.ok()) {
			return record_status;
		}
		if (effect.handle != handle) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, effect.handle.value);
		}
		effects_copy[handle] = std::move(effect);
		return ok_status();
	});
	if (!status.ok()) {
		return status;
	}
	r_effects = std::move(effects_copy);
	return ok_status();
}

Status AbilityComponent::decode_task_record_ops(SnapshotReader &p_reader, std::map<AbilityTaskHandle, ActiveAbilityTask> &r_tasks) const {
	SnapshotWriter current_writer;
	Status status = task_runtime.write_snapshot(current_writer, AbilityTaskVisibility::INTERNAL);
	if (!status.ok()) {
		return status;
	}
	std::vector<std::uint8_t> current_bytes = current_writer.take();
	SnapshotReader current_reader(current_bytes);
	std::map<AbilityTaskHandle, ActiveAbilityTask> tasks_copy;
	std::uint64_t discarded_allocator_raw = 0;
	status = task_runtime.decode_snapshot_section(current_reader, tasks_copy, discarded_allocator_raw);
	if (!status.ok()) {
		return status;
	}

	status = decode_delta_record_ops(p_reader, [&](std::uint64_t p_identity, DeltaOpKind p_op) -> Status {
		const AbilityTaskHandle handle{ p_identity };
		if (p_op == DeltaOpKind::REMOVE) {
			tasks_copy.erase(handle);
			return ok_status();
		}
		ActiveAbilityTask task;
		const Status record_status = task_runtime.decode_task_delta_record(p_reader, task);
		if (!record_status.ok()) {
			return record_status;
		}
		if (task.handle != handle) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, task.handle.value);
		}
		tasks_copy[handle] = std::move(task);
		return ok_status();
	});
	if (!status.ok()) {
		return status;
	}
	r_tasks = std::move(tasks_copy);
	return ok_status();
}

// ---------------------------------------------------------------------------
// Canonical delta codec: top-level composer/applier (task 2.1-2.4)
// ---------------------------------------------------------------------------

namespace {

AbilityTaskVisibility delta_task_visibility(ChangeAudience p_audience) {
	return p_audience == ChangeAudience::PUBLIC ? AbilityTaskVisibility::OBSERVABLE : AbilityTaskVisibility::OWNER_ONLY;
}

TargetResultVisibility delta_target_context_visibility(ChangeAudience p_audience) {
	return p_audience == ChangeAudience::PUBLIC ? TargetResultVisibility::OBSERVABLE : TargetResultVisibility::OWNER_ONLY;
}

} // namespace

Status AbilityComponent::write_delta_batch(SnapshotWriter &p_writer, ChangeAudience p_audience,
		const std::vector<DirtyRecord> &p_dirty, const DeltaBaseline &p_baseline,
		const GameplayAbilityWorldCoordinator *p_session_coordinator) const {
	const bool is_public = p_audience == ChangeAudience::PUBLIC;
	const std::function<bool(DefinitionId)> always_public = [](DefinitionId) { return true; };
	const std::function<bool(DefinitionId)> attribute_is_public = [this](DefinitionId p_id) { return visibility_config_.attribute_public(p_id); };
	const std::function<bool(DefinitionId)> tag_is_public = [this](DefinitionId p_id) { return visibility_config_.tag_public(p_id); };
	const std::function<bool(DefinitionId)> ability_is_public = [this](DefinitionId p_id) { return visibility_config_.ability_public(p_id); };

	const std::vector<std::uint64_t> attribute_dirty = dirty_identities_for_section(p_dirty, ChangeSection::ATTRIBUTE);
	const std::vector<std::uint64_t> tag_dirty = dirty_identities_for_section(p_dirty, ChangeSection::TAG_SOURCE);
	const std::vector<std::uint64_t> grant_dirty = dirty_identities_for_section(p_dirty, ChangeSection::ABILITY_GRANT);
	const std::vector<std::uint64_t> execution_dirty = dirty_identities_for_section(p_dirty, ChangeSection::ACTIVE_EXECUTION);
	const std::vector<std::uint64_t> effect_dirty = dirty_identities_for_section(p_dirty, ChangeSection::ACTIVE_EFFECT);
	const std::vector<std::uint64_t> task_dirty = dirty_identities_for_section(p_dirty, ChangeSection::ABILITY_TASK);
	const std::vector<std::uint64_t> session_dirty = dirty_identities_for_section(p_dirty, ChangeSection::TARGET_SESSION);

	if (!session_dirty.empty() && p_session_coordinator == nullptr) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, session_dirty.size());
	}

	std::size_t section_count = 0;
	section_count += attribute_dirty.empty() ? 0 : 1;
	section_count += tag_dirty.empty() ? 0 : 1;
	section_count += grant_dirty.empty() ? 0 : 1;
	section_count += execution_dirty.empty() ? 0 : 1;
	section_count += effect_dirty.empty() ? 0 : 1;
	section_count += task_dirty.empty() ? 0 : 1;
	section_count += session_dirty.empty() ? 0 : 1;

	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_BATCH)) {
		return p_writer.status();
	}
	p_writer.write_u16(DELTA_BATCH_VERSION);
	p_writer.write_count(section_count, MAX_DELTA_SECTIONS_PER_BATCH);

	if (!attribute_dirty.empty()) {
		const DeltaSectionMode mode = choose_delta_section_mode(attribute_dirty.size(), attribute_set.initialized_attributes().size());
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::ATTRIBUTE));
		p_writer.write_u8(static_cast<std::uint8_t>(mode));
		if (mode == DeltaSectionMode::FULL_REENCODE) {
			const Status status = attribute_set.write_snapshot_filtered(p_writer, is_public ? attribute_is_public : always_public);
			if (!status.ok()) {
				return status;
			}
		} else {
			p_writer.write_count(attribute_dirty.size(), MAX_DELTA_RECORD_OPS_PER_SECTION);
			for (std::uint64_t raw_id : attribute_dirty) {
				const DefinitionId id = static_cast<DefinitionId>(raw_id);
				const bool exists = attribute_set.has_attribute(id);
				const DeltaOpKind op = exists ? (p_baseline.knows(ChangeSection::ATTRIBUTE, raw_id) ? DeltaOpKind::UPDATE : DeltaOpKind::ADD) : DeltaOpKind::REMOVE;
				if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
					return p_writer.status();
				}
				p_writer.write_u64(raw_id);
				p_writer.write_u8(static_cast<std::uint8_t>(op));
				if (exists) {
					const Status status = attribute_set.write_attribute_delta_record(p_writer, id);
					if (!status.ok()) {
						return status;
					}
				}
				if (!p_writer.end_section()) {
					return p_writer.status();
				}
			}
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!tag_dirty.empty()) {
		const DeltaSectionMode mode = choose_delta_section_mode(tag_dirty.size(), tag_container.source_record_count());
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::TAG_SOURCE));
		p_writer.write_u8(static_cast<std::uint8_t>(mode));
		if (mode == DeltaSectionMode::FULL_REENCODE) {
			const Status status = tag_container.write_snapshot_filtered(p_writer, is_public ? tag_is_public : always_public);
			if (!status.ok()) {
				return status;
			}
		} else {
			const std::map<SourceToken, DefinitionId> source_records = tag_container.all_source_records();
			p_writer.write_count(tag_dirty.size(), MAX_DELTA_RECORD_OPS_PER_SECTION);
			for (std::uint64_t raw_id : tag_dirty) {
				const SourceToken source{ raw_id };
				const auto it = source_records.find(source);
				const bool exists = it != source_records.end();
				const DeltaOpKind op = exists ? (p_baseline.knows(ChangeSection::TAG_SOURCE, raw_id) ? DeltaOpKind::UPDATE : DeltaOpKind::ADD) : DeltaOpKind::REMOVE;
				if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
					return p_writer.status();
				}
				p_writer.write_u64(raw_id);
				p_writer.write_u8(static_cast<std::uint8_t>(op));
				if (exists) {
					const Status status = tag_container.write_tag_source_delta_record(p_writer, it->second);
					if (!status.ok()) {
						return status;
					}
				}
				if (!p_writer.end_section()) {
					return p_writer.status();
				}
			}
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!grant_dirty.empty()) {
		const DeltaSectionMode mode = choose_delta_section_mode(grant_dirty.size(), grants.size());
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::ABILITY_GRANT));
		p_writer.write_u8(static_cast<std::uint8_t>(mode));
		if (mode == DeltaSectionMode::FULL_REENCODE) {
			const Status status = write_grants_section(p_writer, is_public ? ability_is_public : always_public);
			if (!status.ok()) {
				return status;
			}
		} else {
			p_writer.write_count(grant_dirty.size(), MAX_DELTA_RECORD_OPS_PER_SECTION);
			for (std::uint64_t raw_id : grant_dirty) {
				const AbilitySpecId spec{ raw_id };
				const bool exists = find_grant(spec) != nullptr;
				const DeltaOpKind op = exists ? (p_baseline.knows(ChangeSection::ABILITY_GRANT, raw_id) ? DeltaOpKind::UPDATE : DeltaOpKind::ADD) : DeltaOpKind::REMOVE;
				if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
					return p_writer.status();
				}
				p_writer.write_u64(raw_id);
				p_writer.write_u8(static_cast<std::uint8_t>(op));
				if (exists) {
					const Status status = write_grant_delta_record(p_writer, spec);
					if (!status.ok()) {
						return status;
					}
				}
				if (!p_writer.end_section()) {
					return p_writer.status();
				}
			}
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!execution_dirty.empty()) {
		const DeltaSectionMode mode = choose_delta_section_mode(execution_dirty.size(), executions.size());
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::ACTIVE_EXECUTION));
		p_writer.write_u8(static_cast<std::uint8_t>(mode));
		if (mode == DeltaSectionMode::FULL_REENCODE) {
			const Status status = write_executions_section(p_writer);
			if (!status.ok()) {
				return status;
			}
		} else {
			p_writer.write_count(execution_dirty.size(), MAX_DELTA_RECORD_OPS_PER_SECTION);
			for (std::uint64_t raw_id : execution_dirty) {
				const ExecutionId execution_id{ raw_id };
				const bool exists = find_execution(execution_id) != nullptr;
				const DeltaOpKind op = exists ? (p_baseline.knows(ChangeSection::ACTIVE_EXECUTION, raw_id) ? DeltaOpKind::UPDATE : DeltaOpKind::ADD) : DeltaOpKind::REMOVE;
				if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
					return p_writer.status();
				}
				p_writer.write_u64(raw_id);
				p_writer.write_u8(static_cast<std::uint8_t>(op));
				if (exists) {
					const Status status = write_execution_delta_record(p_writer, execution_id);
					if (!status.ok()) {
						return status;
					}
				}
				if (!p_writer.end_section()) {
					return p_writer.status();
				}
			}
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!effect_dirty.empty()) {
		const DeltaSectionMode mode = choose_delta_section_mode(effect_dirty.size(), effect_runtime.active_count());
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::ACTIVE_EFFECT));
		p_writer.write_u8(static_cast<std::uint8_t>(mode));
		if (mode == DeltaSectionMode::FULL_REENCODE) {
			const Status status = effect_runtime.write_snapshot(p_writer, delta_target_context_visibility(p_audience));
			if (!status.ok()) {
				return status;
			}
		} else {
			p_writer.write_count(effect_dirty.size(), MAX_DELTA_RECORD_OPS_PER_SECTION);
			for (std::uint64_t raw_id : effect_dirty) {
				const EffectHandle handle{ raw_id };
				const bool exists = effect_runtime.has_effect(handle);
				const DeltaOpKind op = exists ? (p_baseline.knows(ChangeSection::ACTIVE_EFFECT, raw_id) ? DeltaOpKind::UPDATE : DeltaOpKind::ADD) : DeltaOpKind::REMOVE;
				if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
					return p_writer.status();
				}
				p_writer.write_u64(raw_id);
				p_writer.write_u8(static_cast<std::uint8_t>(op));
				if (exists) {
					const Status status = effect_runtime.write_active_effect_delta_record(p_writer, handle, delta_target_context_visibility(p_audience));
					if (!status.ok()) {
						return status;
					}
				}
				if (!p_writer.end_section()) {
					return p_writer.status();
				}
			}
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!task_dirty.empty()) {
		const DeltaSectionMode mode = choose_delta_section_mode(task_dirty.size(), task_runtime.size());
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::ABILITY_TASK));
		p_writer.write_u8(static_cast<std::uint8_t>(mode));
		if (mode == DeltaSectionMode::FULL_REENCODE) {
			const Status status = task_runtime.write_snapshot(p_writer, delta_task_visibility(p_audience));
			if (!status.ok()) {
				return status;
			}
		} else {
			p_writer.write_count(task_dirty.size(), MAX_DELTA_RECORD_OPS_PER_SECTION);
			for (std::uint64_t raw_id : task_dirty) {
				const AbilityTaskHandle handle{ raw_id };
				const bool exists = task_runtime.has(handle);
				const DeltaOpKind op = exists ? (p_baseline.knows(ChangeSection::ABILITY_TASK, raw_id) ? DeltaOpKind::UPDATE : DeltaOpKind::ADD) : DeltaOpKind::REMOVE;
				if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_RECORD_OP)) {
					return p_writer.status();
				}
				p_writer.write_u64(raw_id);
				p_writer.write_u8(static_cast<std::uint8_t>(op));
				if (exists) {
					const Status status = task_runtime.write_task_delta_record(p_writer, handle);
					if (!status.ok()) {
						return status;
					}
				}
				if (!p_writer.end_section()) {
					return p_writer.status();
				}
			}
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!session_dirty.empty()) {
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_writer.status();
		}
		p_writer.write_u8(static_cast<std::uint8_t>(ChangeSection::TARGET_SESSION));
		p_writer.write_u8(static_cast<std::uint8_t>(DeltaSectionMode::FULL_REENCODE));
		const Status status = p_session_coordinator->write_snapshot(p_writer, delta_target_context_visibility(p_audience), owner_entity);
		if (!status.ok()) {
			return status;
		}
		if (!p_writer.end_section()) {
			return p_writer.status();
		}
	}

	if (!p_writer.end_section()) {
		return p_writer.status();
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityComponent::apply_delta_batch(SnapshotReader &p_reader, GameplayAbilityWorldCoordinator *p_session_coordinator) {
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_DELTA_BATCH)) {
		return p_reader.status();
	}
	std::uint16_t version = 0;
	if (!p_reader.read_u16(version)) {
		return p_reader.status();
	}
	if (version != DELTA_BATCH_VERSION) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::PROTOCOL_VERSION_DIFFERS, version);
	}
	std::size_t section_count = 0;
	if (!p_reader.read_count(section_count, MAX_DELTA_SECTIONS_PER_BATCH)) {
		return p_reader.status();
	}

	bool have_attribute = false;
	std::map<DefinitionId, AttributeValue> new_attributes;
	std::vector<AttributeModifier> new_attribute_modifiers;

	bool have_tag = false;
	std::map<DefinitionId, std::set<SourceToken>> new_tag_owners;
	std::uint64_t new_tag_revision = 0;

	bool have_grant = false;
	std::map<AbilitySpecId, AbilityGrant> new_grants;

	bool have_execution = false;
	std::map<ExecutionId, ActiveExecution> new_executions;

	bool have_effect = false;
	std::map<EffectHandle, ActiveEffect> new_effects;
	std::size_t new_effect_retained_bytes = 0;

	bool have_task = false;
	std::map<AbilityTaskHandle, ActiveAbilityTask> new_tasks;
	std::uint64_t new_task_allocator_raw = 0;

	bool owned_sections_installed = false;
	// Installs this component's own six sections (ATTRIBUTE, TAG_SOURCE,
	// ABILITY_GRANT, ACTIVE_EXECUTION, ACTIVE_EFFECT, ABILITY_TASK) from the
	// local temporaries above -- a pure, non-failing mutation by the time
	// EITHER of this lambda's two call sites below reach it (every
	// validation for a section that decoded already ran before `have_*` was
	// set true). Idempotent via `owned_sections_installed`: called from the
	// TARGET_SESSION case (see that case's own comment for why installing
	// early is REQUIRED there, not merely convenient) and, for a batch with
	// no TARGET_SESSION section, once after the loop ends.
	const auto install_owned_sections = [&]() {
		if (owned_sections_installed) {
			return;
		}
		owned_sections_installed = true;
		if (have_attribute) {
			attribute_set.install_records(std::move(new_attributes), std::move(new_attribute_modifiers));
		}
		if (have_tag) {
			tag_container.install_records(std::move(new_tag_owners), new_tag_revision);
		}
		if (have_grant) {
			std::uint64_t max_spec = 0;
			for (const auto &entry : new_grants) {
				max_spec = std::max(max_spec, entry.first.value);
			}
			// An empty `new_grants` (unreachable in practice -- grants are
			// never erased once created, only flagged `revoked`, see
			// `write_snapshot`'s own grants loop) carries no allocator
			// information to restore from; leave the cursor exactly where
			// it was rather than wrongly resetting it to 1.
			if (!new_grants.empty()) {
				// `+ 1`, matching `restore_snapshot`'s own identical
				// convention elsewhere in this file -- see that call site
				// for the allocator's "restored cursor" semantics this
				// mirrors.
				spec_allocator.restore_from(std::max(spec_allocator.next_raw(), max_spec + 1));
			}
			grants = std::move(new_grants);
		}
		if (have_execution) {
			std::uint64_t max_execution = 0;
			for (const auto &entry : new_executions) {
				max_execution = std::max(max_execution, entry.first.value);
			}
			// Unlike grants, executions ARE legitimately erased once ended/
			// cancelled (see `end_execution_immediate`), so an empty
			// `new_executions` here is a real, reachable state -- same
			// "nothing to restore the cursor from" reasoning as above still
			// applies.
			if (!new_executions.empty()) {
				execution_allocator.restore_from(std::max(execution_allocator.next_raw(), max_execution + 1));
			}
			executions = std::move(new_executions);
		}
		if (have_effect) {
			effect_runtime.install_records(std::move(new_effects), new_effect_retained_bytes);
		}
		if (have_task) {
			task_runtime.install_records(std::move(new_tasks), new_task_allocator_raw);
		}
	};

	std::int32_t previous_section_kind = -1;
	for (std::size_t i = 0; i < section_count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_DELTA_SECTION)) {
			return p_reader.status();
		}
		std::uint8_t section_raw = 0;
		std::uint8_t mode_raw = 0;
		if (!p_reader.read_u8(section_raw) || !p_reader.read_u8(mode_raw)) {
			return p_reader.status();
		}
		if (!is_valid_change_section(section_raw)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, section_raw);
		}
		if (!is_valid_delta_section_mode(mode_raw)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, mode_raw);
		}
		if (static_cast<std::int32_t>(section_raw) <= previous_section_kind) {
			// Non-canonical (out-of-order, duplicate, or repeated) section --
			// see `decode_delta_record_ops`'s identical rationale above for
			// why this is rejected rather than tolerated.
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, section_raw);
		}
		previous_section_kind = section_raw;
		const ChangeSection section = static_cast<ChangeSection>(section_raw);
		const DeltaSectionMode mode = static_cast<DeltaSectionMode>(mode_raw);

		switch (section) {
			case ChangeSection::ATTRIBUTE: {
				const Status status = mode == DeltaSectionMode::FULL_REENCODE
						? attribute_set.decode_snapshot_section(p_reader, new_attributes, new_attribute_modifiers)
						: decode_attribute_record_ops(p_reader, new_attributes, new_attribute_modifiers);
				if (!status.ok()) {
					return status;
				}
				if (new_attributes.size() > MAX_ATTRIBUTES) {
					return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, new_attributes.size());
				}
				have_attribute = true;
				break;
			}
			case ChangeSection::TAG_SOURCE: {
				const Status status = mode == DeltaSectionMode::FULL_REENCODE
						? tag_container.decode_snapshot_section(p_reader, new_tag_owners, new_tag_revision)
						: decode_tag_source_record_ops(p_reader, new_tag_owners, new_tag_revision);
				if (!status.ok()) {
					return status;
				}
				std::size_t total_sources = 0;
				for (const auto &entry : new_tag_owners) {
					total_sources += entry.second.size();
				}
				if (total_sources > MAX_TAG_SOURCES) {
					return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, total_sources);
				}
				have_tag = true;
				break;
			}
			case ChangeSection::ABILITY_GRANT: {
				const Status status = mode == DeltaSectionMode::FULL_REENCODE
						? decode_grants_section(p_reader, new_grants)
						: decode_grant_record_ops(p_reader, new_grants);
				if (!status.ok()) {
					return status;
				}
				if (new_grants.size() > MAX_ABILITY_GRANTS) {
					return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, new_grants.size());
				}
				have_grant = true;
				break;
			}
			case ChangeSection::ACTIVE_EXECUTION: {
				const Status status = mode == DeltaSectionMode::FULL_REENCODE
						? decode_executions_section(p_reader, new_executions)
						: decode_execution_record_ops(p_reader, new_executions);
				if (!status.ok()) {
					return status;
				}
				if (new_executions.size() > MAX_ACTIVE_EXECUTIONS) {
					return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, new_executions.size());
				}
				have_execution = true;
				break;
			}
			case ChangeSection::ACTIVE_EFFECT: {
				const Status status = mode == DeltaSectionMode::FULL_REENCODE
						? effect_runtime.decode_snapshot_section(p_reader, new_effects)
						: decode_effect_record_ops(p_reader, new_effects);
				if (!status.ok()) {
					return status;
				}
				std::size_t retained_bytes = 0;
				const Status validate_status = effect_runtime.validate_records(new_effects, retained_bytes);
				if (!validate_status.ok()) {
					return validate_status;
				}
				new_effect_retained_bytes = retained_bytes;
				have_effect = true;
				break;
			}
			case ChangeSection::ABILITY_TASK: {
				Status status;
				if (mode == DeltaSectionMode::FULL_REENCODE) {
					status = task_runtime.decode_snapshot_section(p_reader, new_tasks, new_task_allocator_raw);
				} else {
					status = decode_task_record_ops(p_reader, new_tasks);
					std::uint64_t max_handle = 0;
					for (const auto &entry : new_tasks) {
						max_handle = std::max(max_handle, entry.first.value);
					}
					new_task_allocator_raw = std::max(task_runtime.allocator_next_raw(), max_handle);
				}
				if (!status.ok()) {
					return status;
				}
				// Parent (execution/spec/ability) existence is checked
				// against THIS SAME batch's not-yet-installed grant/
				// execution content when either was itself touched by this
				// batch (ACTIVE_EXECUTION/ABILITY_GRANT both sort before
				// ABILITY_TASK in ascending `ChangeSection` order, so both
				// have already been fully decoded above whenever present),
				// falling back to this component's CURRENT live state for
				// whichever of the two this batch left untouched.
				const auto parent_exists = [&](ExecutionId p_execution, AbilitySpecId p_spec, DefinitionId p_ability) {
					const ActiveExecution *execution = nullptr;
					if (have_execution) {
						const auto it = new_executions.find(p_execution);
						execution = it == new_executions.end() ? nullptr : &it->second;
					} else {
						execution = find_execution(p_execution);
					}
					return execution != nullptr && execution->spec == p_spec && execution->ability == p_ability &&
							(execution->phase == ExecutionPhase::BEGUN || execution->phase == ExecutionPhase::ACTIVE);
				};
				const Status validate_status = task_runtime.validate_records(new_tasks, parent_exists);
				if (!validate_status.ok()) {
					return validate_status;
				}
				have_task = true;
				break;
			}
			case ChangeSection::TARGET_SESSION: {
				if (mode != DeltaSectionMode::FULL_REENCODE) {
					return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, mode_raw);
				}
				if (p_session_coordinator == nullptr) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
				}
				// TARGET_SESSION is the highest-valued `ChangeSection`
				// enumerator, so ascending order guarantees it is always
				// the LAST section in a batch -- every OTHER section has
				// already fully decoded (and, for ABILITY_TASK, validated
				// its parent execution) into a local temporary by the time
				// control reaches here. `GameplayAbilityWorldCoordinator::
				// restore_owner_snapshot` itself validates each session
				// against THIS component's LIVE execution/task state (it
				// is a referential, not a pure, decode -- see
				// ga_targeting.cpp), so those six sections MUST already be
				// installed before it runs, not merely decoded -- install
				// them now rather than after the loop. A TARGET_SESSION
				// failure from this point on therefore leaves the six
				// sections already applied to `this`; a TARGET_SESSION-free
				// batch is unaffected and keeps the full all-or-nothing
				// guarantee across its own six sections (see this method's
				// own doc comment, ga_ability_component.h).
				install_owned_sections();
				const Status status = p_session_coordinator->restore_owner_snapshot(p_reader, owner_entity);
				if (!status.ok()) {
					return status;
				}
				break;
			}
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}

	// Every section above decoded (and, for TARGET_SESSION, already applied
	// to the SEPARATE coordinator AFTER already installing the six sections
	// below -- see that case's own comment) successfully. For a batch with
	// no TARGET_SESSION section, `install_owned_sections` has not run yet;
	// do so now. Idempotent (a no-op if TARGET_SESSION already triggered
	// it), and every call is a pure, non-failing mutation at this point:
	// every validation already ran.
	install_owned_sections();

	return ok_status();
}

} // namespace ga
