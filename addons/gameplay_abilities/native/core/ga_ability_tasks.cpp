#include "core/ga_ability_tasks.h"

#include <algorithm>
#include <limits>
#include <utility>

namespace ga {

namespace {

bool task_order_less(const ActiveAbilityTask &p_a, const ActiveAbilityTask &p_b) {
	if (p_a.execution != p_b.execution) {
		return p_a.execution < p_b.execution;
	}
	return p_a.handle < p_b.handle;
}

bool is_valid_task_kind(AbilityTaskKind p_kind) {
	return static_cast<std::uint8_t>(p_kind) <= static_cast<std::uint8_t>(AbilityTaskKind::WAIT_TARGET_DATA);
}

bool is_valid_visibility(AbilityTaskVisibility p_visibility) {
	return static_cast<std::uint8_t>(p_visibility) <= static_cast<std::uint8_t>(AbilityTaskVisibility::INTERNAL);
}

bool is_valid_prediction_policy(AbilityTaskPredictionPolicy p_policy) {
	return static_cast<std::uint8_t>(p_policy) <= static_cast<std::uint8_t>(AbilityTaskPredictionPolicy::REQUIRES_AUTHORITY);
}

} // namespace

// Exported (see ga_ability_tasks.h's own doc comment): the SAME predicate the
// core snapshot section below, the standalone `TASK_STATE` DTO codec, and the
// observer task section (`gap_task_messages.cpp`) all evaluate, rather than
// each keeping a private duplicate.
bool task_visible_to(AbilityTaskVisibility p_task_visibility,
		AbilityTaskVisibility p_audience) {
	switch (p_audience) {
		case AbilityTaskVisibility::OWNER_ONLY:
			// Owner snapshot: public/observable and owner-only waits, but not
			// authority-internal implementation state.
			return p_task_visibility != AbilityTaskVisibility::INTERNAL;
		case AbilityTaskVisibility::OBSERVABLE:
			// Observer snapshot: only explicitly observable waits.
			return p_task_visibility == AbilityTaskVisibility::OBSERVABLE;
		case AbilityTaskVisibility::INTERNAL:
			// Canonical authority snapshot/reconciliation baseline.
			return true;
	}
	return false;
}

Status AbilityTaskRuntime::encode_query(const TagQuery &p_query, std::vector<std::uint8_t> &r_bytes) const {
	ByteWriter writer(MAX_TASK_PAYLOAD_BYTES);
	const Status status = p_query.encode(writer);
	if (!status.ok() || !writer.ok()) {
		return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD, writer.size());
	}
	r_bytes = writer.take();
	return ok_status();
}

Status AbilityTaskRuntime::validate_request(const AbilityTaskRequest &p_request, Tick p_start_tick,
		ChangeProvenance p_provenance) const {
	if (!is_valid_task_kind(p_request.kind)) {
		return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_KIND,
				static_cast<std::uint64_t>(p_request.kind));
	}
	if (!is_valid_visibility(p_request.visibility) || !is_valid_prediction_policy(p_request.prediction_policy)) {
		return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_ENUM);
	}
	// Fix (spec "Task Snapshot Visibility and Restore"): `INTERNAL` tasks are
	// never replicated to any remote peer, including the owner -- see
	// `task_visible_to`/`AbilityComponent::write_snapshot`'s owner-facing
	// audience. A task that ALSO declares `PREDICTION_SAFE` could be
	// predicted locally by the owning client, but the owner could then never
	// receive the authoritative snapshot/event needed to confirm or roll
	// back that prediction (`PredictionReconciler` only ever reconciles
	// against what actually crosses the wire) -- it would dangle forever
	// unreconciled. Reject the combination outright, the same way an
	// ambiguous kind-specific payload is rejected below, rather than let it
	// build a prediction that can never resolve. `visibility` defaults to
	// `OWNER_ONLY`, so this is additive and never fires for an
	// already-valid request that does not opt into both fields.
	if (p_request.visibility == AbilityTaskVisibility::INTERNAL &&
			p_request.prediction_policy == AbilityTaskPredictionPolicy::PREDICTION_SAFE) {
		return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD,
				static_cast<std::uint64_t>(p_request.kind));
	}
	if (p_request.has_deadline) {
		if (p_request.deadline_tick == INVALID_TICK || p_request.deadline_tick < p_start_tick ||
				p_request.deadline_tick - p_start_tick > MAX_TASK_DEADLINE_HORIZON_TICKS) {
			return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::TASK_DEADLINE_INVALID,
					p_request.deadline_tick);
		}
	}
	if (p_provenance == ChangeProvenance::PREDICTED &&
			p_request.prediction_policy == AbilityTaskPredictionPolicy::AUTHORITY_ONLY) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED,
				static_cast<std::uint64_t>(p_request.kind));
	}

	const TagQuery default_query;
	const bool has_event_fields =
			p_request.gameplay_event_tag != INVALID_DEFINITION_ID ||
			p_request.gameplay_event_match != TagMatchMode::EXACT;
	const bool has_tag_query_fields =
			p_request.tag_query != default_query ||
			p_request.tag_edge != AbilityTaskTagEdge::BECOMES_TRUE ||
			p_request.complete_if_already_satisfied;
	const bool has_input_fields =
			p_request.logical_input != INVALID_DEFINITION_ID ||
			p_request.logical_phase != LogicalInputPhase::PRESS;
	const bool has_authority_fields =
			p_request.authority_prediction != INVALID_PREDICTION_KEY;
	const bool has_target_fields =
			p_request.target_schema != INVALID_DEFINITION_ID;
	auto reject_ambiguous = [](std::uint64_t p_detail) {
		return make_status(StatusCode::INVALID_ABILITY_TASK,
				DiagnosticId::INVALID_TASK_PAYLOAD, p_detail);
	};

	switch (p_request.kind) {
		case AbilityTaskKind::WAIT_TICKS: {
			if (has_event_fields || has_tag_query_fields || has_input_fields ||
					has_authority_fields || has_target_fields) {
				return reject_ambiguous(
						static_cast<std::uint64_t>(p_request.kind));
			}
			Tick ignored = 0;
			const Status status = tick_advance(p_start_tick, p_request.wait_ticks, ignored);
			if (!status.ok()) {
				return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD,
						p_request.wait_ticks);
			}
			break;
		}
		case AbilityTaskKind::WAIT_GAMEPLAY_EVENT:
			if (p_request.wait_ticks != 0 || has_tag_query_fields ||
					has_input_fields || has_authority_fields ||
					has_target_fields) {
				return reject_ambiguous(
						static_cast<std::uint64_t>(p_request.kind));
			}
			if (p_request.gameplay_event_tag == INVALID_DEFINITION_ID ||
					tag_registry->definition(p_request.gameplay_event_tag) == nullptr ||
					static_cast<std::uint8_t>(p_request.gameplay_event_match) >
							static_cast<std::uint8_t>(TagMatchMode::PARENT_AWARE)) {
				return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD,
						p_request.gameplay_event_tag);
			}
			break;
		case AbilityTaskKind::WAIT_TAG_QUERY:
			if (p_request.wait_ticks != 0 || has_event_fields ||
					has_input_fields || has_authority_fields ||
					has_target_fields) {
				return reject_ambiguous(
						static_cast<std::uint64_t>(p_request.kind));
			}
			if (static_cast<std::uint8_t>(p_request.tag_edge) >
					static_cast<std::uint8_t>(AbilityTaskTagEdge::BECOMES_FALSE)) {
				return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_ENUM);
			}
			{
				std::vector<std::uint8_t> query_bytes;
				if (!encode_query(p_request.tag_query, query_bytes).ok()) {
					return make_status(StatusCode::INVALID_ABILITY_TASK,
							DiagnosticId::INVALID_TASK_PAYLOAD);
				}
			}
			break;
		case AbilityTaskKind::WAIT_LOGICAL_INPUT:
			if (p_request.wait_ticks != 0 || has_event_fields ||
					has_tag_query_fields || has_authority_fields ||
					has_target_fields) {
				return reject_ambiguous(
						static_cast<std::uint64_t>(p_request.kind));
			}
			if (p_request.logical_input == INVALID_DEFINITION_ID ||
					tag_registry->definition(p_request.logical_input) == nullptr ||
					static_cast<std::uint8_t>(p_request.logical_phase) >
							static_cast<std::uint8_t>(LogicalInputPhase::CANCEL)) {
				return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD,
						p_request.logical_input);
			}
			break;
		case AbilityTaskKind::WAIT_AUTHORITY:
			if (p_request.wait_ticks != 0 || has_event_fields ||
					has_tag_query_fields || has_input_fields ||
					has_target_fields) {
				return reject_ambiguous(
						static_cast<std::uint64_t>(p_request.kind));
			}
			if (p_provenance == ChangeProvenance::PREDICTED && !p_request.authority_prediction) {
				return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD);
			}
			break;
		case AbilityTaskKind::WAIT_TARGET_DATA:
			if (p_request.wait_ticks != 0 || has_event_fields ||
					has_tag_query_fields || has_input_fields ||
					has_authority_fields) {
				return reject_ambiguous(
						static_cast<std::uint64_t>(p_request.kind));
			}
			if (p_request.target_schema == INVALID_DEFINITION_ID) {
				return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD);
			}
			break;
	}
	return ok_status();
}

AbilityTaskStartResult AbilityTaskRuntime::start(const AbilityTaskRequest &p_request,
		ExecutionId p_execution, AbilitySpecId p_spec, DefinitionId p_ability, Tick p_tick,
		ChangeProvenance p_provenance, PredictionKey p_prediction_key,
		AbilityTaskHandle p_reserved_handle) {
	AbilityTaskStartResult result;
	if (!p_execution || !p_spec || p_ability == INVALID_DEFINITION_ID || !owner) {
		result.status = make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::TASK_PARENT_MISSING,
				p_execution.value);
		return result;
	}
	if (tasks.size() >= MAX_ACTIVE_ABILITY_TASKS) {
		result.status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				tasks.size());
		return result;
	}
	const auto parent_it = by_execution.find(p_execution);
	if (parent_it != by_execution.end() && parent_it->second.size() >= MAX_ABILITY_TASKS_PER_EXECUTION) {
		result.status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				parent_it->second.size());
		return result;
	}
	// `MAX_TASK_WAITS_PER_INDEX`: bounds how many tasks may share one
	// event/tag/input waiter index bucket (`gameplay_event_index`,
	// `tag_query_index`, `logical_input_index` -- see `attach_indexes`).
	// Equal to `MAX_ACTIVE_ABILITY_TASKS` today, so the `tasks.size()` check
	// above already makes this unreachable in practice (a single bucket can
	// never hold more entries than the whole component has active tasks) --
	// enforced anyway, the same way ga_limits.h documents
	// `MAX_ACTIVE_REACTION_BINDINGS` being a transitively-implied bound, so
	// the constant stays an honest, independently-checked contract rather
	// than a number nothing reads.
	switch (p_request.kind) {
		case AbilityTaskKind::WAIT_GAMEPLAY_EVENT: {
			const auto index_it = gameplay_event_index.find(p_request.gameplay_event_tag);
			if (index_it != gameplay_event_index.end() && index_it->second.size() >= MAX_TASK_WAITS_PER_INDEX) {
				result.status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
						index_it->second.size());
				return result;
			}
			break;
		}
		case AbilityTaskKind::WAIT_TAG_QUERY:
			if (tag_query_index.size() >= MAX_TASK_WAITS_PER_INDEX) {
				result.status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
						tag_query_index.size());
				return result;
			}
			break;
		case AbilityTaskKind::WAIT_LOGICAL_INPUT: {
			const auto index_it = logical_input_index.find(p_request.logical_input);
			if (index_it != logical_input_index.end() && index_it->second.size() >= MAX_TASK_WAITS_PER_INDEX) {
				result.status = make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
						index_it->second.size());
				return result;
			}
			break;
		}
		default:
			break;
	}
	result.status = validate_request(p_request, p_tick, p_provenance);
	if (!result.status.ok()) {
		return result;
	}

	const std::uint64_t expected_raw = allocator.next_raw() + 1;
	if (p_reserved_handle && p_reserved_handle.value != expected_raw) {
		result.status = make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::SEQUENCE_OUT_OF_ORDER,
				p_reserved_handle.value);
		return result;
	}
	const AbilityTaskHandle handle = allocator.allocate();
	result.task = handle;

	ActiveAbilityTask task;
	task.handle = handle;
	task.owner = owner;
	task.execution = p_execution;
	task.spec = p_spec;
	task.ability = p_ability;
	task.request = p_request;
	task.start_tick = p_tick;
	task.provenance = p_provenance;
	task.prediction_key = p_prediction_key;
	if (p_request.kind == AbilityTaskKind::WAIT_TICKS) {
		const Status due_status = tick_advance(p_tick, p_request.wait_ticks, task.due_tick);
		if (!due_status.ok()) {
			result.status = due_status;
			return result;
		}
	}
	if (p_request.kind == AbilityTaskKind::WAIT_TAG_QUERY) {
		task.last_tag_truth = p_request.tag_query.evaluate(*tag_container);
	}

	// Canonical priority: a deadline already reached at start wins before an
	// immediately satisfied wait condition.
	if (p_request.has_deadline && p_request.deadline_tick <= p_tick) {
		result.terminal = true;
		result.event = make_event(task, AbilityTaskOutcome::TIMED_OUT, p_tick,
				AbilityTaskCancelReason::NONE,
				make_status(StatusCode::ABILITY_TASK_TIMED_OUT, DiagnosticId::TASK_DEADLINE_INVALID,
						p_request.deadline_tick));
		result.status = ok_status();
		return result;
	}

	bool complete_immediately = false;
	if (p_request.kind == AbilityTaskKind::WAIT_TICKS && task.due_tick <= p_tick) {
		complete_immediately = true;
	} else if (p_request.kind == AbilityTaskKind::WAIT_TAG_QUERY &&
			p_request.complete_if_already_satisfied) {
		const bool desired = p_request.tag_edge == AbilityTaskTagEdge::BECOMES_TRUE;
		complete_immediately = task.last_tag_truth == desired;
	} else if (p_request.kind == AbilityTaskKind::WAIT_AUTHORITY &&
			p_provenance == ChangeProvenance::AUTHORITATIVE) {
		complete_immediately = true;
	}

	if (complete_immediately) {
		result.terminal = true;
		result.event = make_event(task, AbilityTaskOutcome::COMPLETED, p_tick,
				AbilityTaskCancelReason::NONE, ok_status());
		result.status = ok_status();
		return result;
	}

	tasks.emplace(handle, task);
	attach_indexes(task);
	result.status = ok_status();
	return result;
}

void AbilityTaskRuntime::attach_indexes(const ActiveAbilityTask &p_task) {
	by_execution[p_task.execution].insert(p_task.handle);
	if (p_task.request.has_deadline) {
		deadline_index[p_task.request.deadline_tick].insert(p_task.handle);
	}
	switch (p_task.request.kind) {
		case AbilityTaskKind::WAIT_TICKS:
			due_index[p_task.due_tick].insert(p_task.handle);
			break;
		case AbilityTaskKind::WAIT_GAMEPLAY_EVENT:
			gameplay_event_index[p_task.request.gameplay_event_tag].insert(p_task.handle);
			break;
		case AbilityTaskKind::WAIT_TAG_QUERY:
			tag_query_index.insert(p_task.handle);
			break;
		case AbilityTaskKind::WAIT_LOGICAL_INPUT:
			logical_input_index[p_task.request.logical_input].insert(p_task.handle);
			break;
		case AbilityTaskKind::WAIT_AUTHORITY:
			authority_index[p_task.request.authority_prediction].insert(p_task.handle);
			break;
		case AbilityTaskKind::WAIT_TARGET_DATA:
			break;
	}
}

template <typename K>
static void erase_index_value(std::map<K, std::set<AbilityTaskHandle>> &p_index,
		const K &p_key, AbilityTaskHandle p_handle) {
	auto it = p_index.find(p_key);
	if (it == p_index.end()) {
		return;
	}
	it->second.erase(p_handle);
	if (it->second.empty()) {
		p_index.erase(it);
	}
}

void AbilityTaskRuntime::detach_indexes(const ActiveAbilityTask &p_task) {
	erase_index_value(by_execution, p_task.execution, p_task.handle);
	if (p_task.request.has_deadline) {
		erase_index_value(deadline_index, p_task.request.deadline_tick, p_task.handle);
	}
	switch (p_task.request.kind) {
		case AbilityTaskKind::WAIT_TICKS:
			erase_index_value(due_index, p_task.due_tick, p_task.handle);
			break;
		case AbilityTaskKind::WAIT_GAMEPLAY_EVENT:
			erase_index_value(gameplay_event_index, p_task.request.gameplay_event_tag, p_task.handle);
			break;
		case AbilityTaskKind::WAIT_TAG_QUERY:
			tag_query_index.erase(p_task.handle);
			break;
		case AbilityTaskKind::WAIT_LOGICAL_INPUT:
			erase_index_value(logical_input_index, p_task.request.logical_input, p_task.handle);
			break;
		case AbilityTaskKind::WAIT_AUTHORITY:
			erase_index_value(authority_index, p_task.request.authority_prediction, p_task.handle);
			break;
		case AbilityTaskKind::WAIT_TARGET_DATA:
			break;
	}
}

AbilityTaskEvent AbilityTaskRuntime::make_event(const ActiveAbilityTask &p_task,
		AbilityTaskOutcome p_outcome, Tick p_tick, AbilityTaskCancelReason p_cancel_reason,
		Status p_status) const {
	AbilityTaskEvent event;
	event.task = p_task.handle;
	event.owner = p_task.owner;
	event.execution = p_task.execution;
	event.spec = p_task.spec;
	event.ability = p_task.ability;
	event.kind = p_task.request.kind;
	event.outcome = p_outcome;
	event.cancel_reason = p_cancel_reason;
	event.status = p_status;
	event.tick = p_tick;
	event.provenance = p_task.provenance;
	event.prediction_key = p_task.prediction_key;
	event.task_visibility = p_task.request.visibility;
	return event;
}

AbilityTaskTransitionResult AbilityTaskRuntime::transition(AbilityTaskHandle p_task,
		AbilityTaskOutcome p_outcome, Tick p_tick, AbilityTaskCancelReason p_cancel_reason,
		Status p_status) {
	AbilityTaskTransitionResult result;
	auto it = tasks.find(p_task);
	if (it == tasks.end()) {
		result.status = make_status(StatusCode::UNKNOWN_ABILITY_TASK, DiagnosticId::NONE, p_task.value);
		return result;
	}
	const ActiveAbilityTask task = it->second;
	detach_indexes(task);
	tasks.erase(it);
	result.transitioned = true;
	result.event = make_event(task, p_outcome, p_tick, p_cancel_reason, p_status);
	result.status = ok_status();
	return result;
}

AbilityTaskTransitionResult AbilityTaskRuntime::cancel(AbilityTaskHandle p_task, Tick p_tick,
		AbilityTaskCancelReason p_reason) {
	return transition(p_task, AbilityTaskOutcome::CANCELLED, p_tick, p_reason,
			make_status(StatusCode::ABILITY_TASK_CANCELLED, DiagnosticId::NONE,
					static_cast<std::uint64_t>(p_reason)));
}

AbilityTaskTransitionResult AbilityTaskRuntime::fail(AbilityTaskHandle p_task, Tick p_tick,
		Status p_status) {
	if (p_status.ok()) {
		p_status = make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_PAYLOAD);
	}
	return transition(p_task, AbilityTaskOutcome::FAILED, p_tick,
			AbilityTaskCancelReason::NONE, p_status);
}

AbilityTaskTransitionResult AbilityTaskRuntime::complete_target(AbilityTaskHandle p_task,
		Tick p_tick, TargetSessionId p_session, Status p_status,
		const TargetEffectContext *p_context) {
	AbilityTaskTransitionResult result;
	const ActiveAbilityTask *task = find(p_task);
	if (task == nullptr) {
		result.status = make_status(StatusCode::UNKNOWN_ABILITY_TASK, DiagnosticId::NONE, p_task.value);
		return result;
	}
	if (task->request.kind != AbilityTaskKind::WAIT_TARGET_DATA) {
		result.status = make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_TASK_KIND,
				p_task.value);
		return result;
	}
	result = transition(p_task, p_status.ok() ? AbilityTaskOutcome::COMPLETED : AbilityTaskOutcome::FAILED,
			p_tick, AbilityTaskCancelReason::NONE, p_status);
	if (result.transitioned) {
		result.event.target_session = p_session;
		if (p_context != nullptr) {
			result.event.target_context = *p_context;
		}
	}
	return result;
}

std::vector<AbilityTaskHandle> AbilityTaskRuntime::canonical_candidates(
		const std::set<AbilityTaskHandle> &p_handles) const {
	std::vector<AbilityTaskHandle> result;
	result.reserve(p_handles.size());
	for (AbilityTaskHandle handle : p_handles) {
		if (tasks.find(handle) != tasks.end()) {
			result.push_back(handle);
		}
	}
	std::sort(result.begin(), result.end(), [this](AbilityTaskHandle p_a, AbilityTaskHandle p_b) {
		return task_order_less(tasks.at(p_a), tasks.at(p_b));
	});
	return result;
}

std::vector<AbilityTaskEvent> AbilityTaskRuntime::advance_to(Tick p_tick, bool *r_truncated) {
	std::set<AbilityTaskHandle> deadline_candidates;
	for (auto it = deadline_index.begin(); it != deadline_index.end() && it->first <= p_tick; ++it) {
		deadline_candidates.insert(it->second.begin(), it->second.end());
	}
	std::set<AbilityTaskHandle> due_candidates;
	for (auto it = due_index.begin(); it != due_index.end() && it->first <= p_tick; ++it) {
		due_candidates.insert(it->second.begin(), it->second.end());
	}

	std::vector<AbilityTaskEvent> events;
	for (AbilityTaskHandle handle : canonical_candidates(deadline_candidates)) {
		if (events.size() >= MAX_TASK_TERMINAL_EVENTS_PER_TICK) {
			if (r_truncated != nullptr) {
				*r_truncated = true;
			}
			break;
		}
		AbilityTaskTransitionResult result = transition(handle, AbilityTaskOutcome::TIMED_OUT, p_tick,
				AbilityTaskCancelReason::NONE,
				make_status(StatusCode::ABILITY_TASK_TIMED_OUT, DiagnosticId::NONE, handle.value));
		if (result.transitioned) {
			events.push_back(result.event);
		}
	}
	for (AbilityTaskHandle handle : canonical_candidates(due_candidates)) {
		if (events.size() >= MAX_TASK_TERMINAL_EVENTS_PER_TICK) {
			if (r_truncated != nullptr) {
				*r_truncated = true;
			}
			break;
		}
		if (!has(handle)) {
			continue; // deadline won at the same tick
		}
		AbilityTaskTransitionResult result = transition(handle, AbilityTaskOutcome::COMPLETED, p_tick,
				AbilityTaskCancelReason::NONE, ok_status());
		if (result.transitioned) {
			events.push_back(result.event);
		}
	}
	return events;
}

std::vector<AbilityTaskEvent> AbilityTaskRuntime::notify_gameplay_event(
		const AbilityTaskGameplayEvent &p_event, Tick p_tick, bool *r_truncated) {
	std::set<AbilityTaskHandle> candidates;
	for (const auto &entry : gameplay_event_index) {
		const DefinitionId awaited = entry.first;
		for (AbilityTaskHandle handle : entry.second) {
			const ActiveAbilityTask *task = find(handle);
			if (task == nullptr) {
				continue;
			}
			const bool match = task->request.gameplay_event_match == TagMatchMode::EXACT
					? p_event.event_tag == awaited
					: tag_registry->is_descendant_of(p_event.event_tag, awaited);
			if (match) {
				candidates.insert(handle);
			}
		}
	}

	std::vector<AbilityTaskEvent> events;
	for (AbilityTaskHandle handle : canonical_candidates(candidates)) {
		if (events.size() >= MAX_TASK_TERMINAL_EVENTS_PER_TICK) {
			if (r_truncated != nullptr) {
				*r_truncated = true;
			}
			break;
		}
		const ActiveAbilityTask *active = find(handle);
		if (active == nullptr) {
			continue;
		}
		if (active->request.has_deadline && active->request.deadline_tick <= p_tick) {
			AbilityTaskTransitionResult timed_out = transition(handle, AbilityTaskOutcome::TIMED_OUT,
					p_tick, AbilityTaskCancelReason::NONE,
					make_status(StatusCode::ABILITY_TASK_TIMED_OUT));
			if (timed_out.transitioned) {
				events.push_back(timed_out.event);
			}
			continue;
		}
		AbilityTaskTransitionResult completed = transition(handle, AbilityTaskOutcome::COMPLETED,
				p_tick, AbilityTaskCancelReason::NONE, ok_status());
		if (completed.transitioned) {
			completed.event.matched_definition = p_event.event_tag;
			completed.event.instigator = p_event.instigator;
			completed.event.target = p_event.target;
			completed.event.magnitude = p_event.magnitude;
			completed.event.payload_tag = p_event.payload_tag;
			events.push_back(completed.event);
		}
	}
	return events;
}

std::vector<AbilityTaskEvent> AbilityTaskRuntime::notify_tag_state_changed(Tick p_tick, bool *r_truncated) {
	const std::vector<AbilityTaskHandle> candidates = canonical_candidates(tag_query_index);
	std::vector<AbilityTaskEvent> events;
	for (AbilityTaskHandle handle : candidates) {
		if (events.size() >= MAX_TASK_TERMINAL_EVENTS_PER_TICK) {
			if (r_truncated != nullptr) {
				*r_truncated = true;
			}
			break;
		}
		auto it = tasks.find(handle);
		if (it == tasks.end()) {
			continue;
		}
		ActiveAbilityTask &task = it->second;
		if (task.request.has_deadline && task.request.deadline_tick <= p_tick) {
			AbilityTaskTransitionResult timed_out = transition(handle, AbilityTaskOutcome::TIMED_OUT,
					p_tick, AbilityTaskCancelReason::NONE,
					make_status(StatusCode::ABILITY_TASK_TIMED_OUT));
			if (timed_out.transitioned) {
				events.push_back(timed_out.event);
			}
			continue;
		}
		const bool now = task.request.tag_query.evaluate(*tag_container);
		const bool desired = task.request.tag_edge == AbilityTaskTagEdge::BECOMES_TRUE;
		const bool crossed = task.last_tag_truth != now && now == desired;
		task.last_tag_truth = now;
		if (!crossed) {
			continue;
		}
		AbilityTaskTransitionResult completed = transition(handle, AbilityTaskOutcome::COMPLETED,
				p_tick, AbilityTaskCancelReason::NONE, ok_status());
		if (completed.transitioned) {
			events.push_back(completed.event);
		}
	}
	return events;
}

AbilityTaskTransitionResult AbilityTaskRuntime::submit_logical_input(
		const AbilityTaskLogicalInputCommand &p_command, Tick p_tick) {
	AbilityTaskTransitionResult result;
	// `MAX_TASK_INPUTS_PER_TICK`: bounds this local (non-network) submission
	// path's per-tick work. The wire/remote path already runs every incoming
	// command through the protocol layer's own `RateLimiter`
	// (gap_command_gate.h) before it ever reaches here; this is the
	// equivalent budget for a caller driving the task runtime directly.
	// Counts every attempt (valid task or not) so a flood of bad handles
	// cannot dodge the bound, and is checked before any other validation so
	// exceeding it never depends on -- or mutates -- task state.
	if (p_tick != input_budget_tick) {
		input_budget_tick = p_tick;
		input_budget_used = 0;
	}
	if (input_budget_used >= MAX_TASK_INPUTS_PER_TICK) {
		result.status = make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, input_budget_used);
		return result;
	}
	++input_budget_used;
	auto it = tasks.find(p_command.task);
	if (it == tasks.end()) {
		result.status = make_status(StatusCode::UNKNOWN_ABILITY_TASK, DiagnosticId::NONE,
				p_command.task.value);
		return result;
	}
	ActiveAbilityTask &task = it->second;
	if (p_command.owner != owner || p_command.execution != task.execution ||
			task.request.kind != AbilityTaskKind::WAIT_LOGICAL_INPUT ||
			p_command.logical_input != task.request.logical_input ||
			p_command.phase != task.request.logical_phase) {
		result.status = make_status(StatusCode::ABILITY_TASK_INPUT_REJECTED,
				DiagnosticId::INVALID_TASK_PAYLOAD, p_command.task.value);
		return result;
	}
	if (!p_command.sequence || p_command.sequence.value <= task.last_input_sequence.value) {
		result.status = make_status(StatusCode::STALE_COMMAND, DiagnosticId::TASK_SEQUENCE_REJECTED,
				p_command.sequence.value);
		return result;
	}
	if (task.request.has_deadline && task.request.deadline_tick <= p_tick) {
		return transition(p_command.task, AbilityTaskOutcome::TIMED_OUT, p_tick,
				AbilityTaskCancelReason::NONE,
				make_status(StatusCode::ABILITY_TASK_TIMED_OUT));
	}
	task.last_input_sequence = p_command.sequence;
	result = transition(p_command.task, AbilityTaskOutcome::COMPLETED, p_tick,
			AbilityTaskCancelReason::NONE, ok_status());
	if (result.transitioned) {
		result.event.logical_phase = p_command.phase;
		result.event.command_sequence = p_command.sequence;
	}
	return result;
}

std::vector<AbilityTaskEvent> AbilityTaskRuntime::acknowledge_authority(
		PredictionKey p_prediction_key, Tick p_tick) {
	auto it = authority_index.find(p_prediction_key);
	if (it == authority_index.end()) {
		return {};
	}
	const std::vector<AbilityTaskHandle> handles = canonical_candidates(it->second);
	std::vector<AbilityTaskEvent> events;
	for (AbilityTaskHandle handle : handles) {
		AbilityTaskTransitionResult result = transition(handle, AbilityTaskOutcome::COMPLETED,
				p_tick, AbilityTaskCancelReason::NONE, ok_status());
		if (result.transitioned) {
			events.push_back(result.event);
		}
	}
	return events;
}

std::size_t AbilityTaskRuntime::cleanup_execution(ExecutionId p_execution,
		AbilityTaskCancelReason p_reason, Tick p_tick) {
	(void)p_tick;
	auto it = by_execution.find(p_execution);
	if (it == by_execution.end()) {
		return 0;
	}
	const std::vector<AbilityTaskHandle> handles = canonical_candidates(it->second);
	std::size_t count = 0;
	for (AbilityTaskHandle handle : handles) {
		auto task_it = tasks.find(handle);
		if (task_it == tasks.end()) {
			continue;
		}
		const ActiveAbilityTask task = task_it->second;
		detach_indexes(task);
		tasks.erase(task_it);
		++count;
	}
	(void)p_reason;
	return count;
}

void AbilityTaskRuntime::clear_all(AbilityTaskCancelReason p_reason, Tick p_tick) {
	(void)p_reason;
	(void)p_tick;
	tasks.clear();
	by_execution.clear();
	due_index.clear();
	deadline_index.clear();
	gameplay_event_index.clear();
	tag_query_index.clear();
	logical_input_index.clear();
	authority_index.clear();
}

bool AbilityTaskRuntime::has(AbilityTaskHandle p_task) const {
	return tasks.find(p_task) != tasks.end();
}

const ActiveAbilityTask *AbilityTaskRuntime::find(AbilityTaskHandle p_task) const {
	auto it = tasks.find(p_task);
	return it == tasks.end() ? nullptr : &it->second;
}

std::vector<AbilityTaskHandle> AbilityTaskRuntime::active_handles() const {
	std::vector<AbilityTaskHandle> result;
	result.reserve(tasks.size());
	for (const auto &entry : tasks) {
		result.push_back(entry.first);
	}
	return result;
}

std::vector<AbilityTaskHandle> AbilityTaskRuntime::tasks_for_execution(
		ExecutionId p_execution) const {
	auto it = by_execution.find(p_execution);
	return it == by_execution.end() ? std::vector<AbilityTaskHandle>{}
									 : canonical_candidates(it->second);
}

Status AbilityTaskRuntime::write_snapshot(SnapshotWriter &p_writer,
		AbilityTaskVisibility p_max_visibility) const {
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_TASKS)) {
		return p_writer.status();
	}
	p_writer.write_u64(allocator.next_raw());

	std::vector<const ActiveAbilityTask *> visible;
	for (const auto &entry : tasks) {
		if (task_visible_to(entry.second.request.visibility, p_max_visibility)) {
			visible.push_back(&entry.second);
		}
	}
	p_writer.write_count(visible.size(), MAX_ACTIVE_ABILITY_TASKS);
	for (const ActiveAbilityTask *task : visible) {
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ABILITY_TASK_ENTRY)) {
			return p_writer.status();
		}
		const Status field_status = write_task_entry_fields(p_writer, *task);
		if (!field_status.ok()) {
			return field_status;
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

// Shared by `write_snapshot`'s own per-entry loop and the delta codec's
// `write_task_delta_record` (task 2.1: "reusing the existing snapshot
// record codecs") -- exactly the field sequence `write_snapshot` always
// wrote, unchanged.
Status AbilityTaskRuntime::write_task_entry_fields(SnapshotWriter &p_writer, const ActiveAbilityTask &task) const {
	p_writer.write_u64(task.handle.value);
	p_writer.write_u64(task.owner.value);
	p_writer.write_u64(task.execution.value);
	p_writer.write_u64(task.spec.value);
	p_writer.write_u32(task.ability);
	p_writer.write_u8(static_cast<std::uint8_t>(task.request.kind));
	p_writer.write_bool(task.request.has_deadline);
	p_writer.write_u64(task.request.deadline_tick);
	p_writer.write_u8(static_cast<std::uint8_t>(task.request.visibility));
	p_writer.write_u8(static_cast<std::uint8_t>(task.request.prediction_policy));
	p_writer.write_u64(task.start_tick);
	p_writer.write_u64(task.due_tick);
	p_writer.write_u8(static_cast<std::uint8_t>(task.provenance));
	p_writer.write_u64(task.prediction_key.value);

	p_writer.write_u64(task.request.wait_ticks);
	p_writer.write_u32(task.request.gameplay_event_tag);
	p_writer.write_u8(static_cast<std::uint8_t>(task.request.gameplay_event_match));
	std::vector<std::uint8_t> query_bytes;
	const Status query_status = encode_query(task.request.tag_query, query_bytes);
	if (!query_status.ok()) {
		return query_status;
	}
	p_writer.write_count(query_bytes.size(), MAX_TASK_PAYLOAD_BYTES);
	for (std::uint8_t byte : query_bytes) {
		p_writer.write_u8(byte);
	}
	p_writer.write_u8(static_cast<std::uint8_t>(task.request.tag_edge));
	p_writer.write_bool(task.request.complete_if_already_satisfied);
	p_writer.write_bool(task.last_tag_truth);
	p_writer.write_u32(task.request.logical_input);
	p_writer.write_u8(static_cast<std::uint8_t>(task.request.logical_phase));
	p_writer.write_u64(task.last_input_sequence.value);
	p_writer.write_u64(task.request.authority_prediction.value);
	p_writer.write_u32(task.request.target_schema);
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status AbilityTaskRuntime::write_task_delta_record(SnapshotWriter &p_writer, AbilityTaskHandle p_task) const {
	auto it = tasks.find(p_task);
	if (it == tasks.end()) {
		return make_status(StatusCode::UNKNOWN_ABILITY_TASK, DiagnosticId::NONE, p_task.value);
	}
	return write_task_entry_fields(p_writer, it->second);
}

Status AbilityTaskRuntime::restore_snapshot(SnapshotReader &p_reader,
		const std::function<bool(ExecutionId, AbilitySpecId, DefinitionId)> &p_parent_exists) {
	std::map<AbilityTaskHandle, ActiveAbilityTask> decoded;
	std::uint64_t allocator_raw = 0;
	const Status decode_status = decode_snapshot_section(p_reader, decoded, allocator_raw);
	if (!decode_status.ok()) {
		return decode_status;
	}

	const Status validate_status = validate_records(decoded, p_parent_exists);
	if (!validate_status.ok()) {
		return validate_status;
	}

	install_records(std::move(decoded), allocator_raw);
	return ok_status();
}

// The pure-decode half of `restore_snapshot` -- see
// `AttributeSet::decode_snapshot_section`'s doc comment for why this exists.
// `r_allocator_raw` is the section's own explicit wire allocator cursor
// (validated here to be at least the highest decoded handle, exactly like
// `restore_snapshot` always checked); a caller with no such wire cursor
// (the delta codec, for a RECORD_OPS section) never calls this.
Status AbilityTaskRuntime::decode_snapshot_section(SnapshotReader &p_reader,
		std::map<AbilityTaskHandle, ActiveAbilityTask> &r_tasks, std::uint64_t &r_allocator_raw) const {
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_TASKS)) {
		return p_reader.status();
	}
	std::uint64_t allocator_raw = 0;
	std::size_t count = 0;
	if (!p_reader.read_u64(allocator_raw) ||
			!p_reader.read_count(count, MAX_ACTIVE_ABILITY_TASKS)) {
		return p_reader.status();
	}

	std::map<AbilityTaskHandle, ActiveAbilityTask> decoded;
	std::uint64_t max_handle = 0;
	std::uint64_t previous_handle = 0;
	for (std::size_t i = 0; i < count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ABILITY_TASK_ENTRY)) {
			return p_reader.status();
		}
		ActiveAbilityTask task;
		const Status entry_status = decode_task_entry_fields(p_reader, task);
		if (!entry_status.ok()) {
			return entry_status;
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		// Canonical-ordering check (task 5's "no partial or out-of-order
		// snapshot" rule): unlike every other RECORD-LOCAL check
		// `decode_task_entry_fields` already performed, this compares
		// against a PRECEDING entry, so it belongs to this whole-section
		// decode, not the per-record decoder a delta record op also calls.
		if (task.handle.value <= previous_handle) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, task.handle.value);
		}
		previous_handle = task.handle.value;
		decoded.emplace(task.handle, task);
		max_handle = std::max(max_handle, task.handle.value);
	}
	if (!p_reader.end_section()) {
		return p_reader.status();
	}
	if (allocator_raw < max_handle) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::SEQUENCE_OUT_OF_ORDER,
				allocator_raw);
	}

	r_tasks = std::move(decoded);
	r_allocator_raw = allocator_raw;
	return ok_status();
}

Status AbilityTaskRuntime::decode_task_entry_fields(SnapshotReader &p_reader, ActiveAbilityTask &r_task) const {
	ActiveAbilityTask task;
	std::uint64_t handle_raw = 0;
	std::uint64_t owner_raw = 0;
	std::uint64_t execution_raw = 0;
	std::uint64_t spec_raw = 0;
	std::uint32_t ability_raw = 0;
	std::uint8_t kind_raw = 0;
	std::uint8_t visibility_raw = 0;
	std::uint8_t prediction_policy_raw = 0;
	std::uint8_t provenance_raw = 0;
	if (!p_reader.read_u64(handle_raw) || !p_reader.read_u64(owner_raw) ||
			!p_reader.read_u64(execution_raw) || !p_reader.read_u64(spec_raw) ||
			!p_reader.read_u32(ability_raw) || !p_reader.read_u8(kind_raw) ||
			!p_reader.read_bool(task.request.has_deadline) ||
			!p_reader.read_u64(task.request.deadline_tick) ||
			!p_reader.read_u8(visibility_raw) ||
			!p_reader.read_u8(prediction_policy_raw) ||
			!p_reader.read_u64(task.start_tick) || !p_reader.read_u64(task.due_tick) ||
			!p_reader.read_u8(provenance_raw) ||
			!p_reader.read_u64(task.prediction_key.value)) {
		return p_reader.status();
	}
	if (handle_raw == 0 ||
			owner_raw != owner.value ||
			kind_raw > static_cast<std::uint8_t>(AbilityTaskKind::WAIT_TARGET_DATA) ||
			visibility_raw > static_cast<std::uint8_t>(AbilityTaskVisibility::INTERNAL) ||
			prediction_policy_raw > static_cast<std::uint8_t>(AbilityTaskPredictionPolicy::REQUIRES_AUTHORITY) ||
			provenance_raw > static_cast<std::uint8_t>(ChangeProvenance::PREDICTED)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, handle_raw);
	}
	task.handle = AbilityTaskHandle{ handle_raw };
	task.owner = EntityId{ owner_raw };
	task.execution = ExecutionId{ execution_raw };
	task.spec = AbilitySpecId{ spec_raw };
	task.ability = DefinitionId(ability_raw);
	task.request.kind = static_cast<AbilityTaskKind>(kind_raw);
	task.request.visibility = static_cast<AbilityTaskVisibility>(visibility_raw);
	task.request.prediction_policy = static_cast<AbilityTaskPredictionPolicy>(prediction_policy_raw);
	task.provenance = static_cast<ChangeProvenance>(provenance_raw);

	std::uint8_t event_match_raw = 0;
	std::size_t query_size = 0;
	if (!p_reader.read_u64(task.request.wait_ticks) ||
			!p_reader.read_u32(task.request.gameplay_event_tag) ||
			!p_reader.read_u8(event_match_raw) ||
			!p_reader.read_count(query_size, MAX_TASK_PAYLOAD_BYTES)) {
		return p_reader.status();
	}
	std::vector<std::uint8_t> query_bytes;
	query_bytes.reserve(query_size);
	for (std::size_t b = 0; b < query_size; ++b) {
		std::uint8_t byte = 0;
		if (!p_reader.read_u8(byte)) {
			return p_reader.status();
		}
		query_bytes.push_back(byte);
	}
	ByteReader query_reader(query_bytes);
	const Status query_status = TagQuery::decode(query_reader, task.request.tag_query);
	if (!query_status.ok() || !query_reader.at_end()) {
		return query_status.ok()
				? make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_TASK_PAYLOAD)
				: query_status;
	}
	std::uint8_t tag_edge_raw = 0;
	std::uint8_t logical_phase_raw = 0;
	if (!p_reader.read_u8(tag_edge_raw) ||
			!p_reader.read_bool(task.request.complete_if_already_satisfied) ||
			!p_reader.read_bool(task.last_tag_truth) ||
			!p_reader.read_u32(task.request.logical_input) ||
			!p_reader.read_u8(logical_phase_raw) ||
			!p_reader.read_u64(task.last_input_sequence.value) ||
			!p_reader.read_u64(task.request.authority_prediction.value) ||
			!p_reader.read_u32(task.request.target_schema)) {
		return p_reader.status();
	}
	if (event_match_raw > static_cast<std::uint8_t>(TagMatchMode::PARENT_AWARE) ||
			tag_edge_raw > static_cast<std::uint8_t>(AbilityTaskTagEdge::BECOMES_FALSE) ||
			logical_phase_raw > static_cast<std::uint8_t>(LogicalInputPhase::CANCEL)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, handle_raw);
	}
	task.request.gameplay_event_match = static_cast<TagMatchMode>(event_match_raw);
	task.request.tag_edge = static_cast<AbilityTaskTagEdge>(tag_edge_raw);
	task.request.logical_phase = static_cast<LogicalInputPhase>(logical_phase_raw);

	const Status request_status = validate_request(task.request, task.start_tick, task.provenance);
	if (!request_status.ok()) {
		return request_status;
	}

	r_task = std::move(task);
	return ok_status();
}

Status AbilityTaskRuntime::decode_task_delta_record(SnapshotReader &p_reader, ActiveAbilityTask &r_task) const {
	return decode_task_entry_fields(p_reader, r_task);
}

Status AbilityTaskRuntime::validate_records(const std::map<AbilityTaskHandle, ActiveAbilityTask> &p_tasks,
		const std::function<bool(ExecutionId, AbilitySpecId, DefinitionId)> &p_parent_exists) const {
	if (p_tasks.size() > MAX_ACTIVE_ABILITY_TASKS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_tasks.size());
	}
	std::map<ExecutionId, std::size_t> parent_counts;
	for (const auto &entry : p_tasks) {
		const ActiveAbilityTask &task = entry.second;
		if (!p_parent_exists(task.execution, task.spec, task.ability)) {
			return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::TASK_PARENT_MISSING, task.execution.value);
		}
		if (++parent_counts[task.execution] > MAX_ABILITY_TASKS_PER_EXECUTION) {
			return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, parent_counts[task.execution]);
		}
	}
	return ok_status();
}

void AbilityTaskRuntime::install_records(std::map<AbilityTaskHandle, ActiveAbilityTask> p_tasks, std::uint64_t p_allocator_raw) {
	clear_all(AbilityTaskCancelReason::AUTHORITY_CORRECTION, 0);
	tasks = std::move(p_tasks);
	// `restore_exact`, matching `restore_snapshot`'s own original behavior
	// (a full snapshot's allocator cursor is authoritative and MAY move
	// backward -- see `HandleAllocator::restore_exact`'s own doc comment).
	// A caller with no explicit wire cursor (the delta codec) is
	// responsible for computing a `p_allocator_raw` that never regresses
	// its own runtime's cursor before calling this.
	allocator.restore_exact(p_allocator_raw);
	for (const auto &entry : tasks) {
		attach_indexes(entry.second);
	}
}

} // namespace ga
