#include "core/ga_prediction.h"

#include <algorithm>
#include <utility>

namespace ga {

namespace {

// Task 8.1, checks 3/4: one effect (and, bounded to one level, its overflow
// effect) must be declared prediction-safe and non-periodic. Shared by
// `validate_prediction_eligibility`'s cost/cooldown/commit-effect checks so
// the rule is written exactly once.
Status check_effect_prediction_safe(DefinitionId p_effect_id, const EffectRegistry &p_effects, bool p_check_overflow) {
	const EffectDefinition *definition = p_effects.find(p_effect_id);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_effect_id);
	}
	if (!definition->prediction_safe || definition->has_period) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, p_effect_id);
	}
	if (p_check_overflow && definition->stacking.overflow_policy == StackOverflowPolicy::APPLY_OVERFLOW_EFFECT &&
			definition->stacking.has_overflow_effect) {
		// Bounded to exactly one level, matching EffectRuntime::apply_internal's
		// own p_allow_overflow_trigger=false guard on the overflow application
		// itself -- an overflow effect can never itself overflow.
		return check_effect_prediction_safe(definition->stacking.overflow_effect, p_effects, false);
	}
	return ok_status();
}

} // namespace

Status validate_prediction_eligibility(const AbilityDefinition &p_ability, const EffectRegistry &p_effects,
		const PredictionSafeAbilityHook *p_hook) {
	if (p_ability.prediction_policy != AbilityPredictionPolicy::PREDICTABLE) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::NONE, p_ability.id);
	}
	if (p_ability.hook_binding == AbilityHookBinding::AUTHORITY_ONLY) {
		return make_status(StatusCode::PREDICTION_NOT_SAFE, DiagnosticId::HOOK_CAPABILITY_DENIED, p_ability.id);
	}
	if (p_ability.has_cost_effect) {
		const Status status = check_effect_prediction_safe(p_ability.cost_effect, p_effects, true);
		if (!status.ok()) {
			return status;
		}
	}
	if (p_ability.has_cooldown_effect) {
		const Status status = check_effect_prediction_safe(p_ability.cooldown_effect, p_effects, true);
		if (!status.ok()) {
			return status;
		}
	}
	for (const DefinitionId commit_effect : p_ability.commit_effects) {
		const Status status = check_effect_prediction_safe(commit_effect, p_effects, true);
		if (!status.ok()) {
			return status;
		}
	}
	if (p_hook != nullptr) {
		const Status status = validate_prediction_safe_hook(*p_hook);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// PredictionJournal
// ---------------------------------------------------------------------------

Status PredictionJournal::begin(Tick p_tick, DefinitionId p_ability, const ActivationRequest &p_request, PendingPrediction *&r_entry) {
	r_entry = nullptr;
	if (pending.size() >= MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::PREDICTION_JOURNAL_FULL, DiagnosticId::COUNT_LIMIT_EXCEEDED, pending.size());
	}
	const CommandSeq sequence = sequence_allocator.allocate();
	const PredictionKey key = key_allocator.allocate();

	PendingPrediction entry;
	entry.command_kind = PredictionCommandKind::ACTIVATION;
	entry.command_sequence = sequence;
	entry.prediction_key = key;
	entry.spec = p_request.spec;
	entry.ability = p_ability;
	entry.issued_tick = p_tick;
	entry.original_request = p_request;
	// Sanitize the stored template: provenance/command_sequence/prediction_key
	// are stamped fresh every time this entry is (re)predicted, never read
	// back from here.
	entry.original_request.provenance = ChangeProvenance::AUTHORITATIVE;
	entry.original_request.command_sequence = INVALID_COMMAND_SEQ;
	entry.original_request.prediction_key = INVALID_PREDICTION_KEY;

	const auto inserted = pending.emplace(key.value, std::move(entry));
	r_entry = &inserted.first->second;
	return ok_status();
}

Status PredictionJournal::begin_with_identity(Tick p_tick, DefinitionId p_ability, const ActivationRequest &p_request,
		CommandSeq p_command_sequence, PredictionKey p_prediction_key, PendingPrediction *&r_entry) {
	r_entry = nullptr;
	if (pending.size() >= MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::PREDICTION_JOURNAL_FULL, DiagnosticId::COUNT_LIMIT_EXCEEDED, pending.size());
	}
	if (pending.find(p_prediction_key.value) != pending.end()) {
		// See the header doc comment: this never happens via `reconcile()`'s
		// own call discipline, but a live slot must never be silently
		// resurrected/overwritten under an identity already in use.
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::NONE, p_prediction_key.value);
	}

	PendingPrediction entry;
	entry.command_kind = PredictionCommandKind::ACTIVATION;
	entry.command_sequence = p_command_sequence;
	entry.prediction_key = p_prediction_key;
	entry.spec = p_request.spec;
	entry.ability = p_ability;
	entry.issued_tick = p_tick;
	entry.original_request = p_request;
	// Sanitize the stored template exactly like `begin()` does: provenance/
	// command_sequence/prediction_key are stamped fresh every time this
	// entry is (re)predicted, never read back from here.
	entry.original_request.provenance = ChangeProvenance::AUTHORITATIVE;
	entry.original_request.command_sequence = INVALID_COMMAND_SEQ;
	entry.original_request.prediction_key = INVALID_PREDICTION_KEY;

	const auto inserted = pending.emplace(p_prediction_key.value, std::move(entry));
	r_entry = &inserted.first->second;
	return ok_status();
}

Status PredictionJournal::begin_task_input(Tick p_tick, DefinitionId p_ability,
		AbilitySpecId p_spec,
		const AbilityTaskLogicalInputCommand &p_command,
		PendingPrediction *&r_entry) {
	r_entry = nullptr;
	if (pending.size() >= MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::PREDICTION_JOURNAL_FULL,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, pending.size());
	}
	const CommandSeq sequence = sequence_allocator.allocate();
	const PredictionKey key = key_allocator.allocate();
	PendingPrediction entry;
	entry.command_kind = PredictionCommandKind::TASK_INPUT;
	entry.command_sequence = sequence;
	entry.prediction_key = key;
	entry.spec = p_spec;
	entry.ability = p_ability;
	entry.temp_execution = p_command.execution;
	entry.issued_tick = p_tick;
	entry.original_task_input = p_command;
	entry.original_task_input.sequence = INVALID_COMMAND_SEQ;
	entry.original_task_input.prediction_key = INVALID_PREDICTION_KEY;
	const auto inserted = pending.emplace(key.value, std::move(entry));
	r_entry = &inserted.first->second;
	return ok_status();
}

Status PredictionJournal::begin_task_input_with_identity(Tick p_tick,
		DefinitionId p_ability, AbilitySpecId p_spec,
		const AbilityTaskLogicalInputCommand &p_command,
		CommandSeq p_command_sequence, PredictionKey p_prediction_key,
		PendingPrediction *&r_entry) {
	r_entry = nullptr;
	if (pending.size() >= MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::PREDICTION_JOURNAL_FULL,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, pending.size());
	}
	if (!p_command_sequence || !p_prediction_key ||
			pending.find(p_prediction_key.value) != pending.end()) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::NONE,
				p_prediction_key.value);
	}
	PendingPrediction entry;
	entry.command_kind = PredictionCommandKind::TASK_INPUT;
	entry.command_sequence = p_command_sequence;
	entry.prediction_key = p_prediction_key;
	entry.spec = p_spec;
	entry.ability = p_ability;
	entry.temp_execution = p_command.execution;
	entry.issued_tick = p_tick;
	entry.original_task_input = p_command;
	entry.original_task_input.sequence = INVALID_COMMAND_SEQ;
	entry.original_task_input.prediction_key = INVALID_PREDICTION_KEY;
	const auto inserted =
			pending.emplace(p_prediction_key.value, std::move(entry));
	r_entry = &inserted.first->second;
	return ok_status();
}

Status PredictionJournal::begin_target_intent(Tick p_tick,
		DefinitionId p_ability, AbilitySpecId p_spec,
		const TargetSessionCommand &p_command,
		PendingPrediction *&r_entry) {
	r_entry = nullptr;
	if (pending.size() >= MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::PREDICTION_JOURNAL_FULL,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				pending.size());
	}
	const CommandSeq sequence = sequence_allocator.allocate();
	const PredictionKey key = key_allocator.allocate();
	PendingPrediction entry;
	entry.command_kind = PredictionCommandKind::TARGET_INTENT;
	entry.command_sequence = sequence;
	entry.prediction_key = key;
	entry.spec = p_spec;
	entry.ability = p_ability;
	entry.temp_execution = p_command.execution;
	entry.issued_tick = p_tick;
	entry.original_target_command = p_command;
	entry.original_target_command.prediction_key =
			INVALID_PREDICTION_KEY;
	const auto inserted =
			pending.emplace(key.value, std::move(entry));
	r_entry = &inserted.first->second;
	return ok_status();
}

Status PredictionJournal::begin_target_intent_with_identity(
		Tick p_tick, DefinitionId p_ability, AbilitySpecId p_spec,
		const TargetSessionCommand &p_command,
		CommandSeq p_command_sequence,
		PredictionKey p_prediction_key,
		PendingPrediction *&r_entry) {
	r_entry = nullptr;
	if (pending.size() >= MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::PREDICTION_JOURNAL_FULL,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				pending.size());
	}
	if (!p_command_sequence || !p_prediction_key ||
			pending.find(p_prediction_key.value) != pending.end()) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::NONE, p_prediction_key.value);
	}
	PendingPrediction entry;
	entry.command_kind = PredictionCommandKind::TARGET_INTENT;
	entry.command_sequence = p_command_sequence;
	entry.prediction_key = p_prediction_key;
	entry.spec = p_spec;
	entry.ability = p_ability;
	entry.temp_execution = p_command.execution;
	entry.issued_tick = p_tick;
	entry.original_target_command = p_command;
	entry.original_target_command.prediction_key =
			INVALID_PREDICTION_KEY;
	const auto inserted = pending.emplace(
			p_prediction_key.value, std::move(entry));
	r_entry = &inserted.first->second;
	return ok_status();
}

Status PredictionJournal::record_op(PredictionKey p_key, const PredictedOp &p_op) {
	const auto it = pending.find(p_key.value);
	if (it == pending.end()) {
		return make_status(StatusCode::PREDICTION_UNKNOWN_KEY, DiagnosticId::NONE, p_key.value);
	}
	if (op_count >= MAX_PREDICTION_JOURNAL_OPS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, op_count);
	}
	it->second.ops.push_back(p_op);
	++op_count;
	return ok_status();
}

void PredictionJournal::set_execution(PredictionKey p_key, ExecutionId p_execution) {
	const auto it = pending.find(p_key.value);
	if (it != pending.end()) {
		it->second.temp_execution = p_execution;
	}
}

bool PredictionJournal::has_pending(PredictionKey p_key) const {
	return pending.find(p_key.value) != pending.end();
}

const PendingPrediction *PredictionJournal::find_pending(PredictionKey p_key) const {
	const auto it = pending.find(p_key.value);
	return it == pending.end() ? nullptr : &it->second;
}

const PendingPrediction *PredictionJournal::find_pending_by_sequence(CommandSeq p_sequence) const {
	for (const auto &entry : pending) {
		if (entry.second.command_sequence == p_sequence) {
			return &entry.second;
		}
	}
	return nullptr;
}

namespace {
std::vector<PendingPrediction> sorted_by_sequence(std::vector<PendingPrediction> p_entries) {
	std::sort(p_entries.begin(), p_entries.end(), [](const PendingPrediction &p_a, const PendingPrediction &p_b) {
		return p_a.command_sequence.value < p_b.command_sequence.value;
	});
	return p_entries;
}
} // namespace

std::vector<PendingPrediction> PredictionJournal::pending_in_order() const {
	std::vector<PendingPrediction> out;
	out.reserve(pending.size());
	for (const auto &entry : pending) {
		out.push_back(entry.second);
	}
	return sorted_by_sequence(std::move(out));
}

Status PredictionJournal::close(PredictionKey p_key, PendingPrediction &r_entry) {
	const auto it = pending.find(p_key.value);
	if (it == pending.end()) {
		return make_status(StatusCode::PREDICTION_UNKNOWN_KEY, DiagnosticId::NONE, p_key.value);
	}
	r_entry = it->second;
	op_count -= it->second.ops.size();
	pending.erase(it);
	return ok_status();
}

std::vector<PendingPrediction> PredictionJournal::expire_older_than(Tick p_now) {
	std::vector<PendingPrediction> expired;
	std::vector<std::uint64_t> keys_to_erase;
	for (const auto &entry : pending) {
		const std::uint64_t age = (p_now >= entry.second.issued_tick) ? (p_now - entry.second.issued_tick) : 0;
		if (age > MAX_PREDICTION_AGE_TICKS) {
			expired.push_back(entry.second);
			keys_to_erase.push_back(entry.first);
		}
	}
	for (const std::uint64_t key : keys_to_erase) {
		op_count -= pending[key].ops.size();
		pending.erase(key);
	}
	return sorted_by_sequence(std::move(expired));
}

std::vector<PendingPrediction> PredictionJournal::clear() {
	std::vector<PendingPrediction> all;
	all.reserve(pending.size());
	for (const auto &entry : pending) {
		all.push_back(entry.second);
	}
	pending.clear();
	op_count = 0;
	return sorted_by_sequence(std::move(all));
}

void PredictionJournal::ensure_sequence_above(CommandSeq p_at_least) {
	// `HandleAllocator::restore_from` already implements exactly the
	// "raise-only, silently no-op if this would rewind" contract this method
	// documents -- see its own doc comment (ga_ids.h). Reusing it here (never
	// touching `key_allocator`, per this method's own header doc comment)
	// means there is exactly one place that ever decides whether a raise is
	// safe.
	(void)sequence_allocator.restore_from(p_at_least.value);
}

// ---------------------------------------------------------------------------
// PredictingComponent
// ---------------------------------------------------------------------------

bool PredictingComponent::prediction_available(const proto::ClientEventStream &p_stream) const {
	return !despawned && !prediction_disabled && p_stream.state() == proto::ClientStreamState::SYNCED;
}

void PredictingComponent::add_presentation_listener(PredictionPresentationListener p_listener) {
	presentation_listeners.push_back(std::move(p_listener));
}

void PredictingComponent::emit_presentation(const PredictionPresentationEvent &p_event) {
	for (const auto &listener : presentation_listeners) {
		listener(p_event);
	}
}

const AbilityDefinition *PredictingComponent::resolve_for_prediction(const ActivationRequest &p_request, Tick p_tick, PredictionOutcome &r_outcome) {
	const AbilityGrant *grant = owning_component->find_grant(p_request.spec);
	if (grant == nullptr) {
		r_outcome.mode = PredictionMode::NOT_PREDICTED_UNKNOWN_ABILITY;
		r_outcome.status = make_status(StatusCode::ABILITY_NOT_GRANTED, DiagnosticId::NONE, p_request.spec.value);
		return nullptr;
	}
	const AbilityDefinition *ability = abilities->find(grant->ability);
	if (ability == nullptr) {
		r_outcome.mode = PredictionMode::NOT_PREDICTED_UNKNOWN_ABILITY;
		r_outcome.status = make_status(StatusCode::UNKNOWN_ABILITY, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, grant->ability);
		return nullptr;
	}

	const Status eligibility = validate_prediction_eligibility(*ability, *effects);
	if (!eligibility.ok()) {
		r_outcome.mode = PredictionMode::PRESENTATION_ONLY;
		r_outcome.status = eligibility;
		r_outcome.anticipation_dedup = CueDedupId{ owning_component->entity(), ability->id, INVALID_EFFECT_HANDLE, ++anticipation_counter };
		emit_presentation(PredictionPresentationEvent{ r_outcome.anticipation_dedup, INVALID_PREDICTION_KEY, CuePhase::PREDICT,
				ability->id, owning_component->entity(), p_tick });
		return nullptr;
	}
	return ability;
}

PredictionOutcome PredictingComponent::request(const ActivationRequest &p_request, Tick p_tick, const proto::ClientEventStream &p_stream) {
	PredictionOutcome outcome;

	if (!prediction_available(p_stream)) {
		outcome.mode = PredictionMode::NOT_PREDICTED_NO_BASELINE;
		outcome.status = ok_status();
		return outcome;
	}

	const AbilityDefinition *ability = resolve_for_prediction(p_request, p_tick, outcome);
	if (ability == nullptr) {
		return outcome;
	}

	return predict_full(p_request, p_tick, *ability);
}

PredictionOutcome PredictingComponent::repredict(const PendingPrediction &p_old, Tick p_tick, const proto::ClientEventStream &p_stream) {
	PredictionOutcome outcome;

	if (!prediction_available(p_stream)) {
		outcome.mode = PredictionMode::NOT_PREDICTED_NO_BASELINE;
		outcome.status = ok_status();
		return outcome;
	}

	if (p_old.command_kind == PredictionCommandKind::TASK_INPUT) {
		const ActiveAbilityTask *task =
				owning_component->ability_tasks().find(
						p_old.original_task_input.task);
		if (task == nullptr || task->execution !=
						p_old.original_task_input.execution ||
				task->spec != p_old.spec || task->ability != p_old.ability) {
			outcome.mode = PredictionMode::PRESENTATION_ONLY;
			outcome.status = make_status(StatusCode::PREDICTION_REJECTED,
					DiagnosticId::TASK_PARENT_MISSING,
					p_old.original_task_input.task.value);
			outcome.command_sequence = p_old.command_sequence;
			outcome.prediction_key = p_old.prediction_key;
			return outcome;
		}
		const TaskPredictionOutcome task_outcome =
				predict_task_input_full(p_old.original_task_input, p_tick,
						p_old.ability, p_old.spec,
						p_old.command_sequence, p_old.prediction_key);
		outcome.mode = task_outcome.mode;
		outcome.status = task_outcome.status;
		outcome.command_sequence = task_outcome.command_sequence;
		outcome.prediction_key = task_outcome.prediction_key;
		outcome.execution = task_outcome.execution;
		return outcome;
	}
	if (p_old.command_kind != PredictionCommandKind::ACTIVATION) {
		outcome.mode = PredictionMode::PRESENTATION_ONLY;
		outcome.status = make_status(StatusCode::PREDICTION_NOT_SAFE,
				DiagnosticId::FEATURE_UNSUPPORTED,
				static_cast<std::uint64_t>(p_old.command_kind));
		return outcome;
	}

	const AbilityDefinition *ability = resolve_for_prediction(p_old.original_request, p_tick, outcome);
	if (ability == nullptr) {
		return outcome;
	}

	// The only difference from `request()`'s fresh path: preserve `p_old`'s
	// own identity instead of letting `predict_full` allocate a new one --
	// see this method's header doc comment and `ga_reconciliation.cpp`'s
	// `reconcile()` for why that is both necessary (server-side duplicate
	// detection) and safe (the restored baseline this runs against always
	// predates `p_old`'s own confirmation).
	return predict_full(p_old.original_request, p_tick, *ability, p_old.command_sequence, p_old.prediction_key);
}

void PredictingComponent::record_execution_tasks(PredictionKey p_key,
		ExecutionId p_execution,
		const std::vector<AbilityTaskHandle> &p_before) {
	for (AbilityTaskHandle handle :
			owning_component->ability_tasks().tasks_for_execution(p_execution)) {
		if (std::find(p_before.begin(), p_before.end(), handle) !=
				p_before.end()) {
			continue;
		}
		const ActiveAbilityTask *task =
				owning_component->ability_tasks().find(handle);
		if (task == nullptr ||
				task->provenance != ChangeProvenance::PREDICTED) {
			continue;
		}
		PredictedOp op;
		op.kind = PredictedOpKind::TASK_STARTED;
		op.task = handle;
		op.task_kind = task->request.kind;
		(void)prediction_journal.record_op(p_key, op);
	}
}

PredictionOutcome PredictingComponent::predict_full(const ActivationRequest &p_request, Tick p_tick, const AbilityDefinition &p_ability,
		CommandSeq p_preserve_sequence, PredictionKey p_preserve_key) {
	PredictionOutcome outcome;
	outcome.mode = PredictionMode::PREDICTED;

	PendingPrediction *entry = nullptr;
	const Status begin_status = (p_preserve_sequence && p_preserve_key)
			? prediction_journal.begin_with_identity(p_tick, p_ability.id, p_request, p_preserve_sequence, p_preserve_key, entry)
			: prediction_journal.begin(p_tick, p_ability.id, p_request, entry);
	if (!begin_status.ok()) {
		outcome.mode = PredictionMode::NOT_PREDICTED_JOURNAL_FULL;
		outcome.status = begin_status;
		return outcome;
	}
	outcome.command_sequence = entry->command_sequence;
	outcome.prediction_key = entry->prediction_key;

	// Best-effort bookkeeping below: MAX_PREDICTION_JOURNAL_OPS (256) can
	// never realistically be reached by MAX_PENDING_PREDICTIONS (16) pending
	// commands each recording at most a handful of ops, so a `record_op`
	// failure here is not specially recovered -- it would indicate a
	// pre-existing bound violation the caller should already have reacted
	// to (see `sweep_expired`/the on_* recovery hooks).
	(void)prediction_journal.record_op(entry->prediction_key, PredictedOp{ PredictedOpKind::ACTIVATION_BEGUN, INVALID_DEFINITION_ID, INVALID_EFFECT_HANDLE });

	EffectHandle cooldown_before = INVALID_EFFECT_HANDLE;
	if (const AbilityGrant *grant_before = owning_component->find_grant(p_request.spec)) {
		cooldown_before = grant_before->cooldown_handle;
	}

	ActivationRequest predicted_request = p_request;
	predicted_request.provenance = ChangeProvenance::PREDICTED;
	predicted_request.command_sequence = entry->command_sequence;
	predicted_request.prediction_key = entry->prediction_key;

	const ActivationResult result = owning_component->request_activation(predicted_request, p_tick);
	outcome.status = result.status;
	outcome.execution = result.execution;

	if (result.queued) {
		// Deferred (reentrant) activation: this top-level call never runs
		// reentrantly against its own component (nothing above it on the
		// call stack is dispatching), so this branch is defensive only --
		// there is no real outcome yet to journal. Discard the shell entry
		// rather than leaving an empty pending record with no eventual
		// resolution this file would ever observe.
		PendingPrediction discarded;
		(void)prediction_journal.close(entry->prediction_key, discarded);
		return outcome;
	}

	if (!result.status.ok()) {
		// The component's own atomic commit rejected the request (stale
		// cost/cooldown/tag state, etc.): nothing was mutated, so nothing is
		// left pending to reconcile later.
		PendingPrediction discarded;
		(void)prediction_journal.close(entry->prediction_key, discarded);
		return outcome;
	}

	prediction_journal.set_execution(entry->prediction_key, result.execution);
	record_execution_tasks(entry->prediction_key, result.execution);

	if (p_ability.has_cost_effect) {
		(void)prediction_journal.record_op(entry->prediction_key,
				PredictedOp{ PredictedOpKind::SELF_COST_APPLIED, p_ability.cost_effect, INVALID_EFFECT_HANDLE });
	}
	if (p_ability.has_cooldown_effect) {
		EffectHandle cooldown_after = INVALID_EFFECT_HANDLE;
		if (const AbilityGrant *grant_after = owning_component->find_grant(p_request.spec)) {
			cooldown_after = grant_after->cooldown_handle;
		}
		if (cooldown_after && cooldown_after != cooldown_before) {
			(void)prediction_journal.record_op(entry->prediction_key,
					PredictedOp{ PredictedOpKind::SELF_COOLDOWN_APPLIED, p_ability.cooldown_effect, cooldown_after });
		}
	}
	for (const DefinitionId commit_effect : p_ability.commit_effects) {
		(void)prediction_journal.record_op(entry->prediction_key,
				PredictedOp{ PredictedOpKind::SELF_EFFECT_APPLIED, commit_effect, INVALID_EFFECT_HANDLE });
	}

	const CueDedupId dedup{ owning_component->entity(), p_ability.id, INVALID_EFFECT_HANDLE, entry->prediction_key.value };
	emit_presentation(PredictionPresentationEvent{ dedup, entry->prediction_key, CuePhase::PREDICT, p_ability.id, owning_component->entity(), p_tick });

	return outcome;
}

TaskPredictionOutcome PredictingComponent::predict_task_input(
		const AbilityTaskLogicalInputCommand &p_command, Tick p_tick,
		const proto::ClientEventStream &p_stream) {
	TaskPredictionOutcome outcome;
	outcome.task = p_command.task;
	outcome.execution = p_command.execution;
	if (!prediction_available(p_stream)) {
		outcome.mode = PredictionMode::NOT_PREDICTED_NO_BASELINE;
		outcome.status = ok_status();
		return outcome;
	}
	const ActiveAbilityTask *task =
			owning_component->ability_tasks().find(p_command.task);
	if (task == nullptr || task->owner != owning_component->entity() ||
			task->execution != p_command.execution ||
			task->request.kind != AbilityTaskKind::WAIT_LOGICAL_INPUT ||
			task->request.logical_input != p_command.logical_input ||
			task->request.logical_phase != p_command.phase) {
		outcome.mode = PredictionMode::PRESENTATION_ONLY;
		outcome.status = make_status(StatusCode::ABILITY_TASK_INPUT_REJECTED,
				DiagnosticId::INVALID_TASK_PAYLOAD,
				p_command.task.value);
		return outcome;
	}
	if (task->request.prediction_policy !=
			AbilityTaskPredictionPolicy::PREDICTION_SAFE ||
			task->provenance != ChangeProvenance::PREDICTED) {
		outcome.mode = PredictionMode::PRESENTATION_ONLY;
		outcome.status = make_status(StatusCode::PREDICTION_NOT_SAFE,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_command.task.value);
		return outcome;
	}
	return predict_task_input_full(p_command, p_tick, task->ability,
			task->spec);
}

TaskPredictionOutcome PredictingComponent::predict_task_input_full(
		const AbilityTaskLogicalInputCommand &p_command, Tick p_tick,
		DefinitionId p_ability, AbilitySpecId p_spec,
		CommandSeq p_preserve_sequence, PredictionKey p_preserve_key) {
	TaskPredictionOutcome outcome;
	outcome.mode = PredictionMode::PREDICTED;
	outcome.task = p_command.task;
	outcome.execution = p_command.execution;

	PendingPrediction *entry = nullptr;
	const Status begin_status =
			(p_preserve_sequence && p_preserve_key)
			? prediction_journal.begin_task_input_with_identity(
					  p_tick, p_ability, p_spec, p_command,
					  p_preserve_sequence, p_preserve_key, entry)
			: prediction_journal.begin_task_input(
					  p_tick, p_ability, p_spec, p_command, entry);
	if (!begin_status.ok()) {
		outcome.mode = PredictionMode::NOT_PREDICTED_JOURNAL_FULL;
		outcome.status = begin_status;
		return outcome;
	}
	outcome.command_sequence = entry->command_sequence;
	outcome.prediction_key = entry->prediction_key;

	const std::vector<AbilityTaskHandle> before =
			owning_component->ability_tasks().tasks_for_execution(
					p_command.execution);
	AbilityTaskLogicalInputCommand predicted = p_command;
	predicted.owner = owning_component->entity();
	predicted.sequence = entry->command_sequence;
	predicted.prediction_key = entry->prediction_key;
	const AbilityTaskTransitionResult result =
			owning_component->submit_logical_input(
					predicted, p_tick, ChangeProvenance::PREDICTED);
	outcome.status = result.status;
	outcome.transitioned = result.transitioned;
	if (result.queued || !result.status.ok()) {
		PendingPrediction discarded;
		(void)prediction_journal.close(entry->prediction_key, discarded);
		return outcome;
	}

	PredictedOp input_op;
	input_op.kind = PredictedOpKind::TASK_INPUT_COMPLETED;
	input_op.task = p_command.task;
	input_op.task_kind = AbilityTaskKind::WAIT_LOGICAL_INPUT;
	(void)prediction_journal.record_op(entry->prediction_key, input_op);
	record_execution_tasks(entry->prediction_key, p_command.execution,
			before);

	const CueDedupId dedup{ owning_component->entity(), p_ability,
		INVALID_EFFECT_HANDLE, entry->prediction_key.value };
	emit_presentation(PredictionPresentationEvent{ dedup,
			entry->prediction_key, CuePhase::PREDICT, p_ability,
			owning_component->entity(), p_tick });
	return outcome;
}

TargetPredictionOutcome PredictingComponent::predict_target_intent(
		GameplayAbilityWorldCoordinator &p_coordinator,
		const TargetSessionCommand &p_command, Tick p_tick,
		const proto::ClientEventStream &p_stream) {
	TargetPredictionOutcome outcome;
	outcome.session = p_command.session;
	outcome.task = p_command.task;
	if (!prediction_available(p_stream)) {
		outcome.mode =
				PredictionMode::NOT_PREDICTED_NO_BASELINE;
		outcome.status = ok_status();
		return outcome;
	}
	const ActiveTargetSession *session =
			p_coordinator.find_session(p_command.session);
	const ActiveAbilityTask *task =
			owning_component->ability_tasks().find(p_command.task);
	if (session == nullptr || task == nullptr ||
			session->owner != owning_component->entity() ||
			session->execution != p_command.execution ||
			session->task != p_command.task ||
			task->execution != p_command.execution ||
			task->request.kind !=
					AbilityTaskKind::WAIT_TARGET_DATA ||
			task->request.target_schema != p_command.schema) {
		outcome.mode = PredictionMode::PRESENTATION_ONLY;
		outcome.status = make_status(
				StatusCode::PREDICTION_REJECTED,
				DiagnosticId::TARGET_SESSION_STALE,
				p_command.session.value);
		return outcome;
	}
	const TargetSchema *schema =
			p_coordinator.schema_registry().find(
					p_command.schema);
	if (schema == nullptr ||
			schema->desc.prediction_policy !=
					TargetPredictionPolicy::PREDICTION_SAFE ||
			task->request.prediction_policy !=
					AbilityTaskPredictionPolicy::PREDICTION_SAFE) {
		outcome.mode = PredictionMode::PRESENTATION_ONLY;
		outcome.status = make_status(
				StatusCode::PREDICTION_NOT_SAFE,
				DiagnosticId::HOOK_CAPABILITY_DENIED,
				p_command.schema);
		return outcome;
	}
	return predict_target_intent_full(p_coordinator, p_command,
			p_tick, task->ability, task->spec);
}

TargetPredictionOutcome
PredictingComponent::repredict_target_intent(
		GameplayAbilityWorldCoordinator &p_coordinator,
		const PendingPrediction &p_old, Tick p_tick,
		const proto::ClientEventStream &p_stream) {
	TargetPredictionOutcome outcome;
	if (p_old.command_kind !=
			PredictionCommandKind::TARGET_INTENT) {
		outcome.mode = PredictionMode::PRESENTATION_ONLY;
		outcome.status = make_status(
				StatusCode::PREDICTION_NOT_SAFE,
				DiagnosticId::FEATURE_UNSUPPORTED);
		return outcome;
	}
	if (!prediction_available(p_stream)) {
		outcome.mode =
				PredictionMode::NOT_PREDICTED_NO_BASELINE;
		outcome.status = ok_status();
		return outcome;
	}
	return predict_target_intent_full(p_coordinator,
			p_old.original_target_command, p_tick, p_old.ability,
			p_old.spec, p_old.command_sequence,
			p_old.prediction_key);
}

TargetPredictionOutcome
PredictingComponent::predict_target_intent_full(
		GameplayAbilityWorldCoordinator &p_coordinator,
		const TargetSessionCommand &p_command, Tick p_tick,
		DefinitionId p_ability, AbilitySpecId p_spec,
		CommandSeq p_preserve_sequence,
		PredictionKey p_preserve_key) {
	TargetPredictionOutcome outcome;
	outcome.mode = PredictionMode::PREDICTED;
	outcome.session = p_command.session;
	outcome.task = p_command.task;
	PendingPrediction *entry = nullptr;
	const Status begin_status =
			(p_preserve_sequence && p_preserve_key) ?
			prediction_journal
					.begin_target_intent_with_identity(
							p_tick, p_ability, p_spec,
							p_command, p_preserve_sequence,
							p_preserve_key, entry) :
			prediction_journal.begin_target_intent(p_tick,
					p_ability, p_spec, p_command, entry);
	if (!begin_status.ok()) {
		outcome.mode =
				PredictionMode::NOT_PREDICTED_JOURNAL_FULL;
		outcome.status = begin_status;
		return outcome;
	}
	outcome.command_sequence = entry->command_sequence;
	outcome.prediction_key = entry->prediction_key;
	TargetSessionCommand predicted = p_command;
	predicted.owner = owning_component->entity();
	predicted.tick = p_tick;
	predicted.prediction_key = entry->prediction_key;
	const TargetSessionCommandResult result =
			p_coordinator.submit_session_command(predicted);
	outcome.status = result.status;
	outcome.transitioned = result.transitioned;
	outcome.terminal = result.terminal;
	outcome.canonical_intent_hash =
			result.event.canonical_intent_hash;
	if (!result.status.ok()) {
		PendingPrediction discarded;
		(void)prediction_journal.close(
				entry->prediction_key, discarded);
		return outcome;
	}
	PredictedOp intent_op;
	intent_op.kind = PredictedOpKind::TARGET_INTENT_SUBMITTED;
	intent_op.task = p_command.task;
	intent_op.task_kind =
			AbilityTaskKind::WAIT_TARGET_DATA;
	(void)prediction_journal.record_op(entry->prediction_key,
			intent_op);
	if (result.terminal) {
		PredictedOp completion;
		completion.kind =
				PredictedOpKind::TARGET_SESSION_COMPLETED;
		completion.task = p_command.task;
		completion.task_kind =
				AbilityTaskKind::WAIT_TARGET_DATA;
		(void)prediction_journal.record_op(
				entry->prediction_key, completion);
	}
	const CueDedupId dedup{ owning_component->entity(),
		p_ability, INVALID_EFFECT_HANDLE,
		entry->prediction_key.value };
	emit_presentation(PredictionPresentationEvent{ dedup,
			entry->prediction_key, CuePhase::PREDICT, p_ability,
			owning_component->entity(), p_tick });
	return outcome;
}

std::vector<PendingPrediction> PredictingComponent::disable_and_clear() {
	prediction_disabled = true;
	std::vector<PendingPrediction> dropped = prediction_journal.clear();
	for (const PendingPrediction &entry : dropped) {
		const CueDedupId dedup{ owning_component->entity(), entry.ability, INVALID_EFFECT_HANDLE, entry.prediction_key.value };
		emit_presentation(PredictionPresentationEvent{ dedup, entry.prediction_key, CuePhase::CANCEL, entry.ability, owning_component->entity(), entry.issued_tick });
	}
	return dropped;
}

std::vector<PendingPrediction> PredictingComponent::on_baseline_lost() { return disable_and_clear(); }
std::vector<PendingPrediction> PredictingComponent::on_disconnected() { return disable_and_clear(); }
std::vector<PendingPrediction> PredictingComponent::on_manifest_changed() { return disable_and_clear(); }

std::vector<PendingPrediction> PredictingComponent::on_despawned() {
	despawned = true;
	return disable_and_clear();
}

std::vector<PendingPrediction> PredictingComponent::sweep_expired(Tick p_now) {
	// `expire_older_than` already removes the aged entries from the journal
	// as it identifies them; emit their CANCEL here (before `clear()` below
	// touches only whatever is left) so every dropped entry -- aged or not
	// -- gets exactly one.
	const std::vector<PendingPrediction> aged = prediction_journal.expire_older_than(p_now);
	if (aged.empty()) {
		return aged;
	}
	for (const PendingPrediction &entry : aged) {
		const CueDedupId dedup{ owning_component->entity(), entry.ability, INVALID_EFFECT_HANDLE, entry.prediction_key.value };
		emit_presentation(PredictionPresentationEvent{ dedup, entry.prediction_key, CuePhase::CANCEL, entry.ability, owning_component->entity(), entry.issued_tick });
	}
	// Age-exceeded is a full bound violation, same as pending/op overflow:
	// disable and clear EVERYTHING ELSE still pending too, so a
	// still-pending-but-not-yet-aged command is never replayed against
	// state that has since diverged from what its sibling's abandonment
	// implies.
	std::vector<PendingPrediction> dropped = disable_and_clear();
	dropped.insert(dropped.begin(), aged.begin(), aged.end());
	return dropped;
}

void PredictingComponent::resume_after_recovery() {
	// This method's own header doc comment promises "a no-op (prediction
	// stays permanently disabled) if this component was despawned" -- but
	// nothing here actually checked `despawned` before now, so a caller
	// calling this on a despawned component would incorrectly clear
	// `prediction_disabled`, making `is_disabled_pending_recovery()` report
	// false (not disabled) for a component that is, in fact, permanently
	// dead. `prediction_available()` independently re-checks `!despawned`
	// too, so a `request()`/`repredict()` call was never actually able to
	// predict again through this bug alone -- but `is_disabled_pending_recovery()`
	// itself (a public accessor a caller like `GameplayAbilityNetworkBridge`
	// reasonably uses to decide WHETHER to call this method at all -- see
	// Finding 2f) was silently wrong. Found via direct test coverage of this
	// method (previously untested); fixed to match the documented contract.
	if (despawned) {
		return;
	}
	prediction_disabled = false;
}

void PredictingComponent::seed_from_owning_component() {
	CommandSeq highest = INVALID_COMMAND_SEQ;
	for (const AbilitySpecId spec : owning_component->granted_specs()) {
		const AbilityGrant *grant = owning_component->find_grant(spec);
		if (grant != nullptr && grant->last_command_sequence.value > highest.value) {
			highest = grant->last_command_sequence;
		}
	}
	if (highest) {
		prediction_journal.ensure_sequence_above(highest);
	}
}

} // namespace ga
