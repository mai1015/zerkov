#include "core/ga_effect_runtime.h"

#include <algorithm>
#include <utility>

namespace ga {

namespace {

Status fail_txn(Transaction &p_txn, Status p_status) {
	p_txn.fail(p_status);
	return p_status;
}

// Task 5.10: cue-phase selection MUST consult `ChangeProvenance`, not just
// whether a prediction key happens to be attached. Before this helper
// existed, every `apply_internal` cue site used
// `(p_prediction_key != INVALID) ? CONFIRM : AUTHORITY_ONLY` unconditionally,
// so a client's own local `ChangeProvenance::PREDICTED` application (which
// always carries the prediction key it is predicting under) was
// indistinguishable from the authority's later confirming application of
// that SAME key -- both produced CONFIRM, and `CuePhase::PREDICT` could
// never be produced by this file at all. Rule (see
// specs/gameplay-effects/spec.md "Effect Lifecycle and Cue Events" and
// specs/gameplay-ability-networking/spec.md "Prediction-Aware Presentation
// Events"):
//   - PREDICTED                                   -> PREDICT
//   - AUTHORITATIVE with a prediction key attached -> CONFIRM (the authority
//     application IS the confirmation of that outstanding prediction)
//   - AUTHORITATIVE with no prediction key         -> AUTHORITY_ONLY (never
//     predicted at all; behavior unchanged from before this fix)
// `CORRECT`/`CANCEL` are never produced here: they describe a REJECTED or
// superseded prediction, which this function -- an in-progress APPLICATION
// -- structurally never represents. Those phases are produced by the
// prediction/reconciliation layer (`ga_prediction.cpp`/`ga_reconciliation.cpp`)
// over the separate, command-scoped `PredictionPresentationEvent` channel.
CuePhase cue_phase_for(ChangeProvenance p_provenance, PredictionKey p_prediction_key) {
	if (p_provenance == ChangeProvenance::PREDICTED) {
		return CuePhase::PREDICT;
	}
	return (p_prediction_key != INVALID_PREDICTION_KEY) ? CuePhase::CONFIRM : CuePhase::AUTHORITY_ONLY;
}

Status resolve_one_magnitude(const MagnitudeSource &p_source, const EffectSpec &p_spec,
		const AttributeSet *p_source_attributes, const AttributeSet *p_target_attributes, Fixed &r_out) {
	switch (p_source.kind) {
		case MagnitudeSourceKind::CONSTANT: {
			r_out = p_source.coefficient;
			return ok_status();
		}
		case MagnitudeSourceKind::ABILITY_LEVEL: {
			const Fixed level = Fixed::from_int(p_spec.level);
			return fixed_mul(p_source.coefficient, level, r_out);
		}
		case MagnitudeSourceKind::SOURCE_ATTRIBUTE: {
			if (p_source_attributes == nullptr) {
				return make_status(StatusCode::UNKNOWN_ATTRIBUTE, DiagnosticId::NONE, p_source.attribute);
			}
			Fixed raw;
			const Status status = p_source_attributes->get_current(p_source.attribute, raw);
			if (!status.ok()) {
				return status;
			}
			return fixed_mul(p_source.coefficient, raw, r_out);
		}
		case MagnitudeSourceKind::TARGET_ATTRIBUTE: {
			Fixed raw;
			const Status status = p_target_attributes->get_current(p_source.attribute, raw);
			if (!status.ok()) {
				return status;
			}
			return fixed_mul(p_source.coefficient, raw, r_out);
		}
		case MagnitudeSourceKind::SET_BY_CALLER: {
			Fixed raw = Fixed::zero();
			for (const SetByCallerMagnitude &supplied : p_spec.set_by_caller) {
				if (supplied.field == p_source.set_by_caller_field) {
					raw = supplied.value;
					break;
				}
			}
			return fixed_mul(p_source.coefficient, raw, r_out);
		}
	}
	return make_status(StatusCode::INTERNAL_ERROR);
}

} // namespace

Status EffectRuntime::resolve_magnitudes(const EffectDefinition &p_definition, const EffectSpec &p_spec,
		const AttributeSet *p_source_attributes, MagnitudeResolution &r_out) const {
	r_out.values.clear();
	r_out.values.reserve(p_definition.modifiers.size());
	for (const ModifierDeclaration &decl : p_definition.modifiers) {
		Fixed value;
		const Status status = resolve_one_magnitude(decl.magnitude, p_spec, p_source_attributes, attributes, value);
		if (!status.ok()) {
			return status;
		}
		r_out.values.push_back(value);
	}
	return ok_status();
}

Status EffectRuntime::apply_instant_deltas(const EffectDefinition &p_definition, const std::vector<Fixed> &p_resolved,
		std::uint32_t p_stack_count, bool p_scale_add_by_stack,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	for (std::size_t i = 0; i < p_definition.modifiers.size(); ++i) {
		const ModifierDeclaration &decl = p_definition.modifiers[i];
		Fixed base;
		Status status = attributes->get_base(decl.target_attribute, base);
		if (!status.ok()) {
			return status;
		}

		Fixed magnitude = p_resolved[i];
		if (p_scale_add_by_stack && decl.op == ModifierOp::ADD && p_stack_count > 1) {
			Fixed scaled;
			status = fixed_mul(magnitude, Fixed::from_int(static_cast<std::int64_t>(p_stack_count)), scaled);
			if (!status.ok()) {
				return status;
			}
			magnitude = scaled;
		}

		Fixed new_base;
		switch (decl.op) {
			case ModifierOp::ADD:
				status = fixed_add(base, magnitude, new_base);
				break;
			case ModifierOp::MULTIPLY:
				status = fixed_mul(base, magnitude, new_base);
				break;
			case ModifierOp::OVERRIDE:
				new_base = magnitude;
				status = ok_status();
				break;
		}
		if (!status.ok()) {
			return status;
		}

		status = attributes->set_base(decl.target_attribute, new_base, p_txn, p_queue, p_provenance);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status EffectRuntime::add_persistent_modifiers(ActiveEffect &p_effect, const EffectDefinition &p_definition,
		Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	for (std::size_t i = 0; i < p_definition.modifiers.size(); ++i) {
		const ModifierDeclaration &decl = p_definition.modifiers[i];
		AttributeModifier modifier;
		modifier.target_attribute = decl.target_attribute;
		modifier.op = decl.op;
		modifier.magnitude = p_effect.resolved_magnitudes[i];
		modifier.priority = decl.priority;
		modifier.source = p_effect.tag_source;
		modifier.effect = p_effect.handle;
		modifier.declaration_index = static_cast<std::uint32_t>(i);

		ModifierHandle handle;
		const Status status = attributes->add_modifier(modifier, handle, p_txn, p_queue, p_provenance);
		if (!status.ok()) {
			return status;
		}
		p_effect.modifier_handles[i].push_back(handle);
	}
	return ok_status();
}

Status EffectRuntime::emit_lifecycle(const EffectLifecycleEvent &p_event, Transaction &p_txn, NotificationQueue &p_queue) {
	return p_txn.add_notification([this, p_event, &p_queue]() {
		for (const EffectLifecycleListener &listener : lifecycle_listeners) {
			listener(p_event, p_queue);
		}
	});
}

Status EffectRuntime::emit_cue(const EffectCueEvent &p_event, Transaction &p_txn, NotificationQueue &p_queue) {
	return p_txn.add_notification([this, p_event, &p_queue]() {
		for (const EffectCueListener &listener : cue_listeners) {
			listener(p_event, p_queue);
		}
	});
}

std::uint64_t EffectRuntime::next_occurrence() {
	return ++occurrence_counter;
}

// ---------------------------------------------------------------------------
// apply / apply_internal
// ---------------------------------------------------------------------------

Status EffectRuntime::apply(const EffectSpec &p_spec, Tick p_tick,
		const AttributeSet *p_source_attributes, const TagContainer *p_source_tags,
		Transaction &p_txn, NotificationQueue &p_queue, EffectHandle &r_handle,
		ChangeProvenance p_provenance, PredictionKey p_prediction_key, AuthorityCalculationHook *p_hook) {
	return apply_internal(p_spec, p_tick, p_source_attributes, p_source_tags, p_txn, p_queue, r_handle,
			p_provenance, p_prediction_key, p_hook,
			/*p_allow_overflow_trigger=*/true);
}

Status EffectRuntime::validate_apply_preconditions(const EffectSpec &p_spec,
		const AttributeSet *p_source_attributes, const TagContainer *p_source_tags,
		const EffectDefinition *&r_definition, MagnitudeResolution &r_resolution) const {
	r_definition = nullptr;

	const EffectDefinition *definition = registry->find(p_spec.definition);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_spec.definition);
	}
	if (p_spec.target != owner) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}

	Status status = validate_effect_spec(p_spec, *registry);
	if (!status.ok()) {
		return status;
	}

	// Source requirements (against a stable snapshot: whatever `p_source_tags`
	// pointed to at the moment this call was made).
	if (p_source_tags != nullptr) {
		if (!definition->source_requirements.evaluate(*p_source_tags)) {
			return make_status(StatusCode::EFFECT_REQUIREMENTS_FAILED);
		}
	} else if (!(definition->source_requirements == TagQuery())) {
		return make_status(StatusCode::EFFECT_REQUIREMENTS_FAILED);
	}

	// Immunity + target requirements, against this runtime's own (target's)
	// tags. Immunity is checked FIRST and rejects before anything is created.
	//
	// An UNDECLARED immunity query (`TagQuery()`, the trivial always-true
	// query -- see ga_tag_query.h) must mean "never immune," not "always
	// immune": `build_requirements({}, {}, {})` deliberately produces that
	// same trivial query for an empty requirement list too, where "always
	// satisfied" IS the correct reading. Immunity is the one query in this
	// file where an empty declaration and a vacuously-true declaration must
	// be told apart, so the trivial query is treated as "no immunity" here.
	if (!(definition->immunity_query == TagQuery()) && definition->immunity_query.evaluate(*tags)) {
		return make_status(StatusCode::EFFECT_IMMUNE);
	}
	if (!definition->target_requirements.evaluate(*tags)) {
		return make_status(StatusCode::EFFECT_REQUIREMENTS_FAILED);
	}

	// Magnitude resolution: read once, here, before any mutation -- this IS
	// the "stable transaction input snapshot" the spec requires (a later
	// source change cannot retroactively perturb this application, because
	// nothing downstream ever re-reads source/target attributes again).
	status = resolve_magnitudes(*definition, p_spec, p_source_attributes, r_resolution);
	if (!status.ok()) {
		return status;
	}

	r_definition = definition;
	return ok_status();
}

Status EffectRuntime::preflight_retained_context_bytes(
		const EffectDefinition &p_definition, const EffectSpec &p_spec,
		const ActiveEffect *p_existing,
		std::size_t &r_prospective_total) const {
	// The context that would actually be STORED for the slot this
	// application touches -- mirrors `apply_internal`'s own
	// `if (definition->retain_target_context)` gates exactly (see this
	// method's own doc comment, ga_effect_runtime.h).
	TargetEffectContext new_context;
	if (p_definition.retain_target_context) {
		new_context = p_spec.target_context;
	} else if (p_existing != nullptr) {
		new_context = p_existing->target_context;
	}

	std::size_t old_bytes = 0;
	if (p_existing != nullptr) {
		const Status old_status = measure_target_effect_context_bytes(
				p_existing->target_context, old_bytes);
		if (!old_status.ok()) {
			return old_status;
		}
	}
	std::size_t new_bytes = 0;
	const Status new_status =
			measure_target_effect_context_bytes(new_context, new_bytes);
	if (!new_status.ok()) {
		return new_status;
	}

	r_prospective_total =
			retained_target_context_bytes_total - old_bytes + new_bytes;
	if (r_prospective_total > MAX_RETAINED_TARGET_CONTEXT_BYTES) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, r_prospective_total);
	}
	return ok_status();
}

Status EffectRuntime::apply_internal(const EffectSpec &p_spec, Tick p_tick,
		const AttributeSet *p_source_attributes, const TagContainer *p_source_tags,
		Transaction &p_txn, NotificationQueue &p_queue, EffectHandle &r_handle,
		ChangeProvenance p_provenance, PredictionKey p_prediction_key,
		AuthorityCalculationHook *p_hook, bool p_allow_overflow_trigger,
		const MagnitudeResolution *p_prepared_resolution,
		const MagnitudeResolution *p_prepared_overflow_resolution) {
	r_handle = INVALID_EFFECT_HANDLE;

	// Shared pre-mutation validation chain -- see `validate_apply_preconditions`'s
	// own doc comment (ga_effect_runtime.h) for exactly what it checks and why
	// `preflight_apply` shares it instead of duplicating it.
	const EffectDefinition *definition = nullptr;
	MagnitudeResolution resolution;
	Status status;
	if (p_prepared_resolution != nullptr) {
		// The complete read-only validation chain already ran in
		// `prepare_apply`. The runtime identity check happens in the public
		// `apply_prepared` entry point, so this branch only resolves the
		// stable definition and consumes the frozen fixed-point values.
		definition = registry->find(p_spec.definition);
		if (definition == nullptr ||
				p_prepared_resolution->values.size() !=
						definition->modifiers.size() ||
				p_spec.target != owner) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_TARGET_PROVENANCE,
					p_spec.definition);
		}
		resolution = *p_prepared_resolution;
	} else {
		status = validate_apply_preconditions(p_spec, p_source_attributes,
				p_source_tags, definition, resolution);
		if (!status.ok()) {
			return status;
		}
	}

	// Optional authority-only hook: gates the whole application and records
	// its result for replication (see ga_effect_hooks.h).
	bool has_hook_result = false;
	Fixed hook_result = Fixed::zero();
	if (p_hook != nullptr) {
		CalculationContext context;
		context.source = p_spec.source;
		context.target = p_spec.target;
		context.level = p_spec.level;
		context.tick = p_tick;
		context.effect_definition = definition->id;
		if (p_source_attributes != nullptr) {
			for (DefinitionId id : p_source_attributes->initialized_attributes()) {
				Fixed value;
				if (p_source_attributes->get_current(id, value).ok()) {
					context.source_attributes.emplace_back(id, value);
				}
			}
		}
		for (DefinitionId id : attributes->initialized_attributes()) {
			Fixed value;
			if (attributes->get_current(id, value).ok()) {
				context.target_attributes.emplace_back(id, value);
			}
		}
		for (const SetByCallerMagnitude &supplied : p_spec.set_by_caller) {
			context.set_by_caller.emplace_back(supplied.field, supplied.value);
		}
		context.target_context = p_spec.target_context;
		const Status hook_status = p_hook->calculate(context, hook_result);
		if (!hook_status.ok()) {
			return make_status(StatusCode::HOOK_FAILED, hook_status.diagnostic, hook_status.detail);
		}
		has_hook_result = true;
	}

	// -----------------------------------------------------------------
	// INSTANT: apply deltas atomically, no active instance survives.
	// -----------------------------------------------------------------
	if (definition->duration_policy == EffectDuration::INSTANT) {
		status = apply_instant_deltas(*definition, resolution.values, 1, false, p_txn, p_queue, p_provenance);
		if (!status.ok()) {
			return fail_txn(p_txn, status);
		}

		EffectLifecycleEvent event;
		event.id = event_allocator.allocate();
		event.kind = EffectLifecycleKind::APPLIED;
		event.definition = definition->id;
		event.handle = INVALID_EFFECT_HANDLE;
		event.source = p_spec.source;
		event.target = p_spec.target;
		event.stack_count_after = 0;
		event.tick = p_tick;
		event.transaction = p_txn.id();
		event.provenance = p_provenance;
		event.has_hook_result = has_hook_result;
		event.hook_result = hook_result;
		event.target_context = p_spec.target_context;
		status = emit_lifecycle(event, p_txn, p_queue);
		if (!status.ok()) {
			return fail_txn(p_txn, status);
		}

		EffectCueEvent cue;
		cue.id = event_allocator.allocate();
		cue.dedup = CueDedupId{ p_spec.target, definition->id, INVALID_EFFECT_HANDLE, next_occurrence() };
		cue.prediction_key = p_prediction_key;
		cue.phase = cue_phase_for(p_provenance, p_prediction_key);
		cue.definition = definition->id;
		cue.handle = INVALID_EFFECT_HANDLE;
		cue.source = p_spec.source;
		cue.target = p_spec.target;
		cue.tick = p_tick;
		cue.cue_identifiers = definition->cue_identifiers;
		cue.target_context = p_spec.target_context;
		status = emit_cue(cue, p_txn, p_queue);
		if (!status.ok()) {
			return fail_txn(p_txn, status);
		}

		r_handle = INVALID_EFFECT_HANDLE;
		return ok_status();
	}

	// -----------------------------------------------------------------
	// DURATION / INFINITE: resolve stacking outcome.
	// -----------------------------------------------------------------
	ActiveEffect *existing = nullptr;
	std::pair<std::string, std::uint64_t> group_key;
	if (definition->stacking.stackable) {
		const std::uint64_t scope_value = (definition->stacking.source_scope == StackSourceScope::SOURCE_SCOPED)
				? p_spec.source.value
				: 0;
		group_key = std::make_pair(definition->stacking.stack_key, scope_value);
		const auto found = stack_index.find(group_key);
		if (found != stack_index.end()) {
			existing = &active_effects.at(found->second);
		}
	}

	bool update_in_place = false;
	bool increment_stack = false;
	bool reuse_handle = false;
	EffectHandle handle_to_use = INVALID_EFFECT_HANDLE;

	if (existing != nullptr && existing->stack_count < definition->stacking.max_stacks) {
		update_in_place = true;
		increment_stack = true;
		handle_to_use = existing->handle;
	} else if (existing != nullptr) {
		switch (definition->stacking.overflow_policy) {
			case StackOverflowPolicy::REJECT: {
				return make_status(StatusCode::EFFECT_STACK_REJECTED, DiagnosticId::STACK_LIMIT_REACHED, existing->handle.value);
			}
			case StackOverflowPolicy::REFRESH: {
				update_in_place = true;
				increment_stack = false;
				handle_to_use = existing->handle;
				break;
			}
			case StackOverflowPolicy::REPLACE: {
				reuse_handle = true;
				handle_to_use = existing->handle;
				break;
			}
			case StackOverflowPolicy::APPLY_OVERFLOW_EFFECT: {
				r_handle = existing->handle;
				if (!p_allow_overflow_trigger || !definition->stacking.has_overflow_effect) {
					return ok_status();
				}
				if (p_prepared_resolution != nullptr &&
						p_prepared_overflow_resolution == nullptr) {
					// The stack topology changed after the read-only batch
					// preparation. Resolving an overflow magnitude now would
					// violate the frozen-input contract; fail closed so the
					// coordinator can roll every participant back.
					return fail_txn(p_txn,
							make_status(StatusCode::INTERNAL_ERROR,
									DiagnosticId::TARGET_BATCH_ROLLED_BACK,
									definition->id));
				}
				EffectSpec overflow_spec;
				overflow_spec.definition = definition->stacking.overflow_effect;
				overflow_spec.source = p_spec.source;
				overflow_spec.target = p_spec.target;
				overflow_spec.level = p_spec.level;
				overflow_spec.context_tag = p_spec.context_tag;
				overflow_spec.target_context = p_spec.target_context;
				EffectHandle overflow_handle;
				const Status overflow_status = apply_internal(overflow_spec, p_tick, p_source_attributes, p_source_tags,
						p_txn, p_queue, overflow_handle, p_provenance,
						INVALID_PREDICTION_KEY, nullptr, false,
						p_prepared_overflow_resolution);
				if (!overflow_status.ok()) {
					return fail_txn(p_txn, overflow_status);
				}
				return ok_status();
			}
		}
	}

	// -----------------------------------------------------------------
	// Update an existing active instance in place (stack add or refresh).
	// -----------------------------------------------------------------
	if (update_in_place) {
		const ActiveEffect before = *existing;
		ActiveEffect updated = before;
		if (increment_stack) {
			updated.stack_count += 1;
		}
		if (definition->stacking.refresh_duration_on_add && definition->duration_policy == EffectDuration::DURATION) {
			Tick new_end;
			status = tick_advance(p_tick, definition->duration_ticks, new_end);
			if (!status.ok()) {
				return status;
			}
			updated.end_tick = new_end;
		}
		if (definition->stacking.reset_period_on_add && definition->has_period) {
			Tick new_period;
			status = tick_advance(p_tick, definition->period_ticks, new_period);
			if (!status.ok()) {
				return status;
			}
			updated.next_period_tick = new_period;
		}
		updated.revision += 1;
		if (definition->retain_target_context) {
			updated.target_context = p_spec.target_context;
		}

		// Retained-context byte budget: still before any mutation (see
		// `preflight_retained_context_bytes`'s own doc comment).
		std::size_t prospective_total = 0;
		status = preflight_retained_context_bytes(*definition, p_spec, existing, prospective_total);
		if (!status.ok()) {
			return status;
		}

		const std::size_t bytes_before_update = retained_target_context_bytes_total;
		retained_target_context_bytes_total = prospective_total;
		active_effects[handle_to_use] = updated;
		p_txn.add_undo([this, handle_to_use, before, bytes_before_update]() {
			active_effects[handle_to_use] = before;
			retained_target_context_bytes_total = bytes_before_update;
		});

		if (increment_stack && !definition->has_period) {
			ActiveEffect &live = active_effects.at(handle_to_use);
			status = add_persistent_modifiers(live, *definition, p_txn, p_queue, p_provenance);
			if (!status.ok()) {
				return fail_txn(p_txn, status);
			}
		}

		EffectLifecycleEvent event;
		event.id = event_allocator.allocate();
		event.kind = EffectLifecycleKind::STACK_CHANGED;
		event.definition = definition->id;
		event.handle = handle_to_use;
		event.source = p_spec.source;
		event.target = p_spec.target;
		event.stack_count_after = active_effects.at(handle_to_use).stack_count;
		event.tick = p_tick;
		event.transaction = p_txn.id();
		event.provenance = p_provenance;
		event.has_hook_result = has_hook_result;
		event.hook_result = hook_result;
		event.target_context = p_spec.target_context;
		status = emit_lifecycle(event, p_txn, p_queue);
		if (!status.ok()) {
			return fail_txn(p_txn, status);
		}

		EffectCueEvent cue;
		cue.id = event_allocator.allocate();
		cue.dedup = CueDedupId{ p_spec.target, definition->id, handle_to_use, next_occurrence() };
		cue.prediction_key = p_prediction_key;
		cue.phase = cue_phase_for(p_provenance, p_prediction_key);
		cue.definition = definition->id;
		cue.handle = handle_to_use;
		cue.source = p_spec.source;
		cue.target = p_spec.target;
		cue.tick = p_tick;
		cue.cue_identifiers = definition->cue_identifiers;
		cue.target_context = p_spec.target_context;
		status = emit_cue(cue, p_txn, p_queue);
		if (!status.ok()) {
			return fail_txn(p_txn, status);
		}

		// No tag mutation here: granted tags remain owned via the SAME
		// tag_source regardless of stack count, so there is nothing further
		// that could fail (see class file comment on why tags are only ever
		// the LAST, unconditionally-atomic step on paths that DO touch them).
		r_handle = handle_to_use;
		return ok_status();
	}

	// -----------------------------------------------------------------
	// Fresh instance creation (not stackable, no existing group, or a
	// REPLACE tearing down the previous instance under the SAME handle).
	// -----------------------------------------------------------------
	if (!reuse_handle && active_effects.size() >= MAX_ACTIVE_EFFECTS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				active_effects.size());
	}
	ActiveEffect fresh;
	fresh.definition = definition->id;
	fresh.source = p_spec.source;
	fresh.target = p_spec.target;
	fresh.stack_count = 1;
	fresh.start_tick = p_tick;
	if (definition->duration_policy == EffectDuration::DURATION) {
		Tick end_tick;
		status = tick_advance(p_tick, definition->duration_ticks, end_tick);
		if (!status.ok()) {
			return status;
		}
		fresh.end_tick = end_tick;
	} else {
		fresh.end_tick = INVALID_TICK;
	}
	fresh.has_period = definition->has_period;
	if (definition->has_period) {
		Tick next_period;
		status = tick_advance(p_tick, definition->period_ticks, next_period);
		if (!status.ok()) {
			return status;
		}
		fresh.next_period_tick = next_period;
	} else {
		fresh.next_period_tick = INVALID_TICK;
	}
	fresh.resolved_magnitudes = resolution.values;
	fresh.context_tag = p_spec.context_tag;
	if (definition->retain_target_context) {
		fresh.target_context = p_spec.target_context;
	}
	fresh.revision = 0;
	fresh.modifier_handles.assign(definition->modifiers.size(), {});

	// Retained-context byte budget: still before any mutation (see
	// `preflight_retained_context_bytes`'s own doc comment). `existing` is
	// non-null here only for a REPLACE (`reuse_handle`), in which case its
	// own `target_context` bytes are about to be replaced by `fresh`'s.
	std::size_t prospective_total = 0;
	status = preflight_retained_context_bytes(*definition, p_spec, existing, prospective_total);
	if (!status.ok()) {
		return status;
	}
	const std::size_t bytes_before_fresh = retained_target_context_bytes_total;

	SourceToken old_tag_source = INVALID_SOURCE_TOKEN;
	bool tearing_down_existing = false;

	if (reuse_handle) {
		old_tag_source = existing->tag_source;
		tearing_down_existing = true;
		fresh.handle = handle_to_use;

		for (const std::vector<ModifierHandle> &per_decl : existing->modifier_handles) {
			for (ModifierHandle h : per_decl) {
				status = attributes->remove_modifier(h, p_txn, p_queue, p_provenance);
				if (!status.ok()) {
					return fail_txn(p_txn, status);
				}
			}
		}

		const ActiveEffect before = *existing;
		p_txn.add_undo([this, handle_to_use, before, bytes_before_fresh]() {
			active_effects[handle_to_use] = before;
			retained_target_context_bytes_total = bytes_before_fresh;
		});
	} else {
		fresh.handle = handle_allocator.allocate();
	}
	fresh.tag_source = tag_source_allocator.allocate();

	retained_target_context_bytes_total = prospective_total;
	active_effects[fresh.handle] = fresh;
	if (!reuse_handle) {
		const EffectHandle allocated = fresh.handle;
		p_txn.add_undo([this, allocated, bytes_before_fresh]() {
			active_effects.erase(allocated);
			retained_target_context_bytes_total = bytes_before_fresh;
		});
	}
	if (definition->stacking.stackable) {
		stack_index[group_key] = fresh.handle;
		if (!reuse_handle) {
			const std::pair<std::string, std::uint64_t> key_copy = group_key;
			p_txn.add_undo([this, key_copy]() {
				stack_index.erase(key_copy);
			});
		}
	}

	if (!definition->has_period) {
		ActiveEffect &live = active_effects.at(fresh.handle);
		status = add_persistent_modifiers(live, *definition, p_txn, p_queue, p_provenance);
		if (!status.ok()) {
			return fail_txn(p_txn, status);
		}
	}

	EffectLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = EffectLifecycleKind::APPLIED;
	event.definition = definition->id;
	event.handle = fresh.handle;
	event.source = p_spec.source;
	event.target = p_spec.target;
	event.stack_count_after = 1;
	event.tick = p_tick;
	event.transaction = p_txn.id();
	event.provenance = p_provenance;
	event.has_hook_result = has_hook_result;
	event.hook_result = hook_result;
	event.target_context = p_spec.target_context;
	status = emit_lifecycle(event, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	EffectCueEvent cue;
	cue.id = event_allocator.allocate();
	cue.dedup = CueDedupId{ p_spec.target, definition->id, fresh.handle, next_occurrence() };
	cue.prediction_key = p_prediction_key;
	cue.phase = cue_phase_for(p_provenance, p_prediction_key);
	cue.definition = definition->id;
	cue.handle = fresh.handle;
	cue.source = p_spec.source;
	cue.target = p_spec.target;
	cue.tick = p_tick;
	cue.cue_identifiers = definition->cue_identifiers;
	cue.target_context = p_spec.target_context;
	status = emit_cue(cue, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	// Tags: participates in the SAME `p_txn` as everything above (see class
	// file comment) -- one combined batch: remove-old + add-new for REPLACE,
	// add-new only otherwise.
	std::vector<TagMutationOp> ops;
	if (tearing_down_existing) {
		for (DefinitionId tag : definition->granted_tags) {
			ops.push_back(TagMutationOp{ TagMutationOp::Kind::REMOVE, tag, old_tag_source });
		}
	}
	for (DefinitionId tag : definition->granted_tags) {
		ops.push_back(TagMutationOp{ TagMutationOp::Kind::ADD, tag, fresh.tag_source });
	}
	if (!ops.empty()) {
		const Status tag_status = tags->apply_mutations(ops, p_txn, p_queue);
		if (!tag_status.ok()) {
			return fail_txn(p_txn, tag_status);
		}
	}

	r_handle = fresh.handle;
	return ok_status();
}

Status EffectRuntime::preflight_apply(const EffectSpec &p_spec, Tick p_tick,
		const AttributeSet *p_source_attributes, const TagContainer *p_source_tags) const {
	PreparedEffectApplication prepared;
	return prepare_apply(p_spec, p_tick, p_source_attributes, p_source_tags,
			prepared);
}

Status EffectRuntime::prepare_apply(const EffectSpec &p_spec, Tick p_tick,
		const AttributeSet *p_source_attributes,
		const TagContainer *p_source_tags,
		PreparedEffectApplication &r_prepared) const {
	(void)p_tick;
	r_prepared = PreparedEffectApplication{};
	const EffectDefinition *definition = nullptr;
	MagnitudeResolution resolution;
	const Status status = validate_apply_preconditions(p_spec, p_source_attributes, p_source_tags, definition, resolution);
	if (!status.ok()) {
		return status;
	}
	bool prepares_overflow = false;
	bool creates_active =
			definition->duration_policy != EffectDuration::INSTANT;
	// Whether THIS application would store a `target_context` for its own
	// (primary) active-effect record at all -- mirrors `apply_internal`'s
	// own paths: an INSTANT effect never creates one, and the
	// APPLY_OVERFLOW_EFFECT-at-max-stacks case returns early without ever
	// touching the existing record, regardless of `has_overflow_effect`
	// (see that function's own switch).
	bool primary_touches_context =
			definition->duration_policy != EffectDuration::INSTANT;
	const ActiveEffect *existing_for_budget = nullptr;
	if (definition->duration_policy != EffectDuration::INSTANT &&
			definition->stacking.stackable) {

		// Mirrors `apply_internal`'s own stacking switch (see that function,
		// above): a REJECT overflow policy fails closed once the matching
		// stack-group instance is already at max stacks.
		const std::uint64_t scope_value =
				(definition->stacking.source_scope ==
								StackSourceScope::SOURCE_SCOPED)
				? p_spec.source.value
				: 0;
		const auto group_key =
				std::make_pair(definition->stacking.stack_key,
						scope_value);
		const auto found = stack_index.find(group_key);
		if (found != stack_index.end()) {
			const ActiveEffect &existing =
					active_effects.at(found->second);
			// Any existing stack is updated, refreshed, replaced under the
			// same handle, or triggers an overflow; none creates another
			// primary active-effect entry.
			creates_active = false;
			existing_for_budget = &existing;
			if (existing.stack_count >=
					definition->stacking.max_stacks) {
				if (definition->stacking.overflow_policy ==
						StackOverflowPolicy::REJECT) {
					return make_status(
							StatusCode::EFFECT_STACK_REJECTED,
							DiagnosticId::STACK_LIMIT_REACHED,
							existing.handle.value);
				}
				if (definition->stacking.overflow_policy ==
						StackOverflowPolicy::APPLY_OVERFLOW_EFFECT) {
					primary_touches_context = false;
					existing_for_budget = nullptr;
					prepares_overflow =
							definition->stacking.has_overflow_effect;
				}
			}
		}
	}
	if (creates_active && active_effects.size() >= MAX_ACTIVE_EFFECTS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				active_effects.size());
	}
	if (primary_touches_context) {
		std::size_t prospective_total = 0;
		const Status budget_status = preflight_retained_context_bytes(
				*definition, p_spec, existing_for_budget, prospective_total);
		if (!budget_status.ok()) {
			return budget_status;
		}
	}

	MagnitudeResolution overflow_resolution;
	if (prepares_overflow) {
		EffectSpec overflow_spec;
		overflow_spec.definition =
				definition->stacking.overflow_effect;
		overflow_spec.source = p_spec.source;
		overflow_spec.target = p_spec.target;
		overflow_spec.level = p_spec.level;
		overflow_spec.context_tag = p_spec.context_tag;
		overflow_spec.target_context = p_spec.target_context;
		const EffectDefinition *overflow_definition = nullptr;
		const Status overflow_status = validate_apply_preconditions(
				overflow_spec, p_source_attributes, p_source_tags,
				overflow_definition, overflow_resolution);
		if (!overflow_status.ok()) {
			return overflow_status;
		}
		// The recursive commit deliberately disables a second overflow
		// trigger, but ordinary REJECT stack behavior still applies.
		bool overflow_creates_active =
				overflow_definition->duration_policy !=
				EffectDuration::INSTANT;
		bool overflow_touches_context =
				overflow_definition->duration_policy !=
				EffectDuration::INSTANT;
		const ActiveEffect *overflow_existing_for_budget = nullptr;
		if (overflow_definition->duration_policy !=
						EffectDuration::INSTANT &&
				overflow_definition->stacking.stackable) {
			const std::uint64_t scope_value =
					(overflow_definition->stacking.source_scope ==
									StackSourceScope::SOURCE_SCOPED)
					? overflow_spec.source.value
					: 0;
			const auto group_key = std::make_pair(
					overflow_definition->stacking.stack_key,
					scope_value);
			const auto found = stack_index.find(group_key);
			if (found != stack_index.end()) {
				overflow_creates_active = false;
				const ActiveEffect &existing =
						active_effects.at(found->second);
				overflow_existing_for_budget = &existing;
				if (existing.stack_count >=
								overflow_definition->stacking.max_stacks &&
						overflow_definition->stacking.overflow_policy ==
								StackOverflowPolicy::REJECT) {
					return make_status(
							StatusCode::EFFECT_STACK_REJECTED,
							DiagnosticId::STACK_LIMIT_REACHED,
							existing.handle.value);
				}
				if (existing.stack_count >=
								overflow_definition->stacking.max_stacks &&
						overflow_definition->stacking.overflow_policy ==
								StackOverflowPolicy::
										APPLY_OVERFLOW_EFFECT) {
					// `apply_internal`'s own recursive call below always
					// passes `p_allow_overflow_trigger=false`, so if the
					// overflow effect's OWN stack group is ALSO already at
					// max under this policy, it too returns early without
					// ever touching this existing record (a second-level
					// overflow trigger is never modeled).
					overflow_touches_context = false;
					overflow_existing_for_budget = nullptr;
				}
			}
		}
		if (overflow_creates_active &&
				active_effects.size() >= MAX_ACTIVE_EFFECTS) {
			return make_status(StatusCode::CAPACITY_EXCEEDED,
					DiagnosticId::COUNT_LIMIT_EXCEEDED,
					active_effects.size());
		}
		if (overflow_touches_context) {
			std::size_t overflow_prospective_total = 0;
			const Status overflow_budget_status =
					preflight_retained_context_bytes(*overflow_definition,
							overflow_spec, overflow_existing_for_budget,
							overflow_prospective_total);
			if (!overflow_budget_status.ok()) {
				return overflow_budget_status;
			}
		}
	}
	r_prepared.prepared_by = this;
	r_prepared.spec = p_spec;
	r_prepared.resolved_magnitudes = std::move(resolution.values);
	r_prepared.has_prepared_overflow = prepares_overflow;
	r_prepared.overflow_resolved_magnitudes =
			std::move(overflow_resolution.values);
	return ok_status();
}

Status EffectRuntime::apply_prepared(
		const PreparedEffectApplication &p_prepared, Tick p_tick,
		const AttributeSet *p_source_attributes,
		const TagContainer *p_source_tags, Transaction &p_txn,
		NotificationQueue &p_queue, EffectHandle &r_handle,
		ChangeProvenance p_provenance,
		PredictionKey p_prediction_key) {
	if (p_prepared.prepared_by != this) {
		r_handle = INVALID_EFFECT_HANDLE;
		return make_status(StatusCode::PERMISSION_DENIED,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	MagnitudeResolution resolution;
	resolution.values = p_prepared.resolved_magnitudes;
	MagnitudeResolution overflow_resolution;
	const MagnitudeResolution *prepared_overflow = nullptr;
	if (p_prepared.has_prepared_overflow) {
		overflow_resolution.values =
				p_prepared.overflow_resolved_magnitudes;
		prepared_overflow = &overflow_resolution;
	}
	return apply_internal(p_prepared.spec, p_tick, p_source_attributes,
			p_source_tags, p_txn, p_queue, r_handle, p_provenance,
			p_prediction_key, nullptr,
			/*p_allow_overflow_trigger=*/true, &resolution,
			prepared_overflow);
}

// ---------------------------------------------------------------------------
// Removal / expiration
// ---------------------------------------------------------------------------

Status EffectRuntime::teardown_instance(EffectHandle p_handle, Tick p_tick, EffectLifecycleKind p_kind,
		EffectRemovalReason p_reason, Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	const auto it = active_effects.find(p_handle);
	if (it == active_effects.end()) {
		return ok_status(); // idempotent
	}
	const ActiveEffect before = it->second;
	const EffectDefinition *definition = registry->find(before.definition);

	active_effects.erase(it);
	std::pair<std::string, std::uint64_t> group_key;
	bool had_group_key = false;
	if (definition != nullptr && definition->stacking.stackable) {
		const std::uint64_t scope_value = (definition->stacking.source_scope == StackSourceScope::SOURCE_SCOPED)
				? before.source.value
				: 0;
		group_key = std::make_pair(definition->stacking.stack_key, scope_value);
		const auto group_it = stack_index.find(group_key);
		if (group_it != stack_index.end() && group_it->second == p_handle) {
			stack_index.erase(group_it);
			had_group_key = true;
		}
	}

	// Retained-context byte budget: `before` is leaving `active_effects`, so
	// its own contribution to the running total is freed up for later
	// applications (see `retained_target_context_bytes()`'s own doc
	// comment).
	std::size_t removed_context_bytes = 0;
	const Status measure_status = measure_target_effect_context_bytes(before.target_context, removed_context_bytes);
	if (!measure_status.ok()) {
		return fail_txn(p_txn, measure_status);
	}
	const std::size_t bytes_before_removal = retained_target_context_bytes_total;
	retained_target_context_bytes_total -= removed_context_bytes;

	p_txn.add_undo([this, p_handle, before, group_key, had_group_key, bytes_before_removal]() {
		active_effects[p_handle] = before;
		if (had_group_key) {
			stack_index[group_key] = p_handle;
		}
		retained_target_context_bytes_total = bytes_before_removal;
	});

	for (const std::vector<ModifierHandle> &per_decl : before.modifier_handles) {
		for (ModifierHandle h : per_decl) {
			const Status status = attributes->remove_modifier(h, p_txn, p_queue, p_provenance);
			if (!status.ok()) {
				return fail_txn(p_txn, status);
			}
		}
	}

	EffectLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = p_kind;
	event.definition = before.definition;
	event.handle = p_handle;
	event.source = before.source;
	event.target = before.target;
	event.stack_count_after = 0;
	event.tick = p_tick;
	event.transaction = p_txn.id();
	event.removal_reason = p_reason;
	event.provenance = p_provenance;
	event.target_context = before.target_context;
	Status status = emit_lifecycle(event, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	EffectCueEvent cue;
	cue.id = event_allocator.allocate();
	cue.dedup = CueDedupId{ before.target, before.definition, p_handle, next_occurrence() };
	cue.phase = CuePhase::AUTHORITY_ONLY;
	cue.definition = before.definition;
	cue.handle = p_handle;
	cue.source = before.source;
	cue.target = before.target;
	cue.tick = p_tick;
	if (definition != nullptr) {
		cue.cue_identifiers = definition->cue_identifiers;
	}
	cue.target_context = before.target_context;
	status = emit_cue(cue, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	if (definition != nullptr && !definition->granted_tags.empty()) {
		std::vector<TagMutationOp> ops;
		ops.reserve(definition->granted_tags.size());
		for (DefinitionId tag : definition->granted_tags) {
			ops.push_back(TagMutationOp{ TagMutationOp::Kind::REMOVE, tag, before.tag_source });
		}
		const Status tag_status = tags->apply_mutations(ops, p_txn, p_queue);
		if (!tag_status.ok()) {
			return fail_txn(p_txn, tag_status);
		}
	}

	return ok_status();
}

Status EffectRuntime::remove_effect(EffectHandle p_handle, Tick p_tick, Transaction &p_txn, NotificationQueue &p_queue,
		ChangeProvenance p_provenance, bool p_force_remove_all_stacks) {
	const auto it = active_effects.find(p_handle);
	if (it == active_effects.end()) {
		return ok_status(); // idempotent: unknown/already-removed handle
	}

	const EffectDefinition *definition = registry->find(it->second.definition);
	const bool remove_all = p_force_remove_all_stacks || definition == nullptr ||
			definition->stacking.removal_rule == StackRemovalRule::REMOVE_ALL_STACKS ||
			it->second.stack_count <= 1;
	if (remove_all) {
		return teardown_instance(p_handle, p_tick, EffectLifecycleKind::REMOVED,
				EffectRemovalReason::EXPLICIT_REMOVAL, p_txn, p_queue, p_provenance);
	}

	const ActiveEffect before = it->second;
	ActiveEffect updated = before;
	updated.stack_count -= 1;
	for (std::vector<ModifierHandle> &per_decl : updated.modifier_handles) {
		if (!per_decl.empty()) {
			per_decl.pop_back();
		}
	}
	updated.revision += 1;
	active_effects[p_handle] = updated;
	p_txn.add_undo([this, p_handle, before]() {
		active_effects[p_handle] = before;
	});

	for (const std::vector<ModifierHandle> &per_decl : before.modifier_handles) {
		if (!per_decl.empty()) {
			const Status status = attributes->remove_modifier(per_decl.back(), p_txn, p_queue, p_provenance);
			if (!status.ok()) {
				return fail_txn(p_txn, status);
			}
		}
	}

	EffectLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = EffectLifecycleKind::STACK_CHANGED;
	event.definition = before.definition;
	event.handle = p_handle;
	event.source = before.source;
	event.target = before.target;
	event.stack_count_after = updated.stack_count;
	event.tick = p_tick;
	event.transaction = p_txn.id();
	event.removal_reason = EffectRemovalReason::EXPLICIT_REMOVAL;
	event.provenance = p_provenance;
	event.target_context = before.target_context;
	const Status status = emit_lifecycle(event, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	// No tag mutation for a partial stack decrement: tags stay granted while
	// stack_count > 0, so nothing further can fail on this path.
	return ok_status();
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

Status EffectRuntime::execute_periodic(EffectHandle p_handle, Tick p_due_tick, Transaction &p_txn,
		NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	const auto it = active_effects.find(p_handle);
	if (it == active_effects.end()) {
		return ok_status();
	}
	const EffectDefinition *definition = registry->find(it->second.definition);
	if (definition == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, it->second.definition);
	}

	const ActiveEffect before = it->second;
	Tick new_next_period;
	Status status = tick_advance(before.next_period_tick, definition->period_ticks, new_next_period);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	status = apply_instant_deltas(*definition, before.resolved_magnitudes, before.stack_count, true, p_txn, p_queue, p_provenance);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	ActiveEffect updated = before;
	updated.next_period_tick = new_next_period;
	updated.revision += 1;
	active_effects[p_handle] = updated;
	p_txn.add_undo([this, p_handle, before]() {
		active_effects[p_handle] = before;
	});

	EffectLifecycleEvent event;
	event.id = event_allocator.allocate();
	event.kind = EffectLifecycleKind::PERIODIC_EXECUTED;
	event.definition = before.definition;
	event.handle = p_handle;
	event.source = before.source;
	event.target = before.target;
	event.stack_count_after = before.stack_count;
	event.tick = p_due_tick;
	event.transaction = p_txn.id();
	event.provenance = p_provenance;
	event.target_context = before.target_context;
	status = emit_lifecycle(event, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	EffectCueEvent cue;
	cue.id = event_allocator.allocate();
	cue.dedup = CueDedupId{ before.target, before.definition, p_handle, next_occurrence() };
	cue.phase = CuePhase::AUTHORITY_ONLY;
	cue.definition = before.definition;
	cue.handle = p_handle;
	cue.source = before.source;
	cue.target = before.target;
	cue.tick = p_due_tick;
	cue.cue_identifiers = definition->cue_identifiers;
	cue.target_context = before.target_context;
	status = emit_cue(cue, p_txn, p_queue);
	if (!status.ok()) {
		return fail_txn(p_txn, status);
	}

	return ok_status();
}

Status EffectRuntime::advance_to(Tick p_tick, Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance) {
	std::size_t periodic_executed = 0;

	for (;;) {
		EffectHandle best_handle = INVALID_EFFECT_HANDLE;
		bool best_is_expire = false;
		Tick best_due = INVALID_TICK;
		DefinitionId best_definition = INVALID_DEFINITION_ID;

		for (const auto &entry : active_effects) {
			const ActiveEffect &effect = entry.second;
			bool candidate_is_expire = false;
			Tick candidate_due = INVALID_TICK;

			// A periodic tick is always chronologically earlier than this
			// SAME effect's expiration whenever it is legitimately due (the
			// `next_period_tick < end_tick` precondition guarantees that),
			// so periodic due-ness must be checked FIRST: checking expiry
			// first would let an effect "skip" its last one or two periods
			// and jump straight to expiring the moment `p_tick` reaches or
			// passes `end_tick`.
			const bool periodic_due = effect.has_period && effect.next_period_tick <= p_tick &&
					(effect.end_tick == INVALID_TICK || effect.next_period_tick < effect.end_tick);
			const bool expire_due = effect.end_tick != INVALID_TICK && effect.end_tick <= p_tick;

			if (periodic_due) {
				if (periodic_executed >= MAX_PERIODIC_CATCHUP) {
					continue; // capped for this call -- resumes on the next advance_to
				}
				candidate_is_expire = false;
				candidate_due = effect.next_period_tick;
			} else if (expire_due) {
				candidate_is_expire = true;
				candidate_due = effect.end_tick;
			} else {
				continue;
			}

			const bool better = (best_handle == INVALID_EFFECT_HANDLE) ||
					(candidate_due < best_due) ||
					(candidate_due == best_due && effect.definition < best_definition) ||
					(candidate_due == best_due && effect.definition == best_definition && entry.first.value < best_handle.value);
			if (better) {
				best_handle = entry.first;
				best_is_expire = candidate_is_expire;
				best_due = candidate_due;
				best_definition = effect.definition;
			}
		}

		if (best_handle == INVALID_EFFECT_HANDLE) {
			break;
		}

		if (best_is_expire) {
			const Status status = teardown_instance(best_handle, best_due, EffectLifecycleKind::EXPIRED,
					EffectRemovalReason::EXPIRED, p_txn, p_queue, p_provenance);
			if (!status.ok()) {
				return status;
			}
		} else {
			const Status status = execute_periodic(best_handle, best_due, p_txn, p_queue, p_provenance);
			if (!status.ok()) {
				return status;
			}
			++periodic_executed;
		}
	}

	return ok_status();
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

bool EffectRuntime::has_effect(EffectHandle p_handle) const {
	return active_effects.find(p_handle) != active_effects.end();
}

const ActiveEffect *EffectRuntime::find(EffectHandle p_handle) const {
	const auto it = active_effects.find(p_handle);
	return it == active_effects.end() ? nullptr : &it->second;
}

std::vector<EffectHandle> EffectRuntime::active_handles() const {
	std::vector<EffectHandle> result;
	result.reserve(active_effects.size());
	for (const auto &entry : active_effects) {
		result.push_back(entry.first);
	}
	return result;
}

void EffectRuntime::add_lifecycle_listener(EffectLifecycleListener p_listener) {
	lifecycle_listeners.push_back(std::move(p_listener));
}

void EffectRuntime::add_cue_listener(EffectCueListener p_listener) {
	cue_listeners.push_back(std::move(p_listener));
}

EffectCueEvent EffectRuntime::make_snapshot_restored_cue(const ActiveEffect &p_effect, Tick p_tick) {
	EffectCueEvent cue;
	cue.id = event_allocator.allocate();
	cue.dedup = CueDedupId{ p_effect.target, p_effect.definition, p_effect.handle, 0 };
	cue.phase = CuePhase::SNAPSHOT_RESTORED;
	cue.definition = p_effect.definition;
	cue.handle = p_effect.handle;
	cue.source = p_effect.source;
	cue.target = p_effect.target;
	cue.tick = p_tick;
	const EffectDefinition *definition = registry->find(p_effect.definition);
	if (definition != nullptr) {
		cue.cue_identifiers = definition->cue_identifiers;
	}
	cue.target_context = p_effect.target_context;
	return cue;
}

// ---------------------------------------------------------------------------
// Canonical snapshots
// ---------------------------------------------------------------------------

Status EffectRuntime::write_snapshot(SnapshotWriter &p_writer,
		TargetResultVisibility p_target_context_audience) const {
	if (!p_writer.begin_section(GA_SNAPSHOT_KIND_EFFECT_RUNTIME)) {
		return p_writer.status();
	}
	p_writer.write_count(active_effects.size(), MAX_ACTIVE_EFFECTS);

	for (const auto &entry : active_effects) {
		if (!p_writer.begin_section(GA_SNAPSHOT_KIND_ACTIVE_EFFECT)) {
			return p_writer.status();
		}
		const Status field_status = write_active_effect_fields(p_writer, entry.second, p_target_context_audience);
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
// `write_active_effect_delta_record` (task 2.1: "reusing the existing
// snapshot record codecs") -- exactly the field sequence `write_snapshot`
// always wrote, unchanged, so both callers stay byte-identical for this
// content by construction rather than by convention.
Status EffectRuntime::write_active_effect_fields(SnapshotWriter &p_writer, const ActiveEffect &effect,
		TargetResultVisibility p_target_context_audience) const {
	p_writer.write_u32(effect.definition);
	p_writer.write_u64(effect.handle.value);
	p_writer.write_u64(effect.source.value);
	p_writer.write_u64(effect.target.value);
	p_writer.write_u32(effect.stack_count);
	p_writer.write_u64(effect.start_tick);
	p_writer.write_u64(effect.end_tick);
	p_writer.write_bool(effect.has_period);
	p_writer.write_u64(effect.next_period_tick);

	p_writer.write_count(effect.resolved_magnitudes.size(), MAX_EFFECT_MODIFIERS);
	for (Fixed magnitude : effect.resolved_magnitudes) {
		p_writer.write_fixed(magnitude);
	}

	p_writer.write_u64(effect.tag_source.value);
	p_writer.write_u64(effect.context_tag);
	// Fix (info-leak: retained `TargetEffectContext` on the wire): a
	// retained context embeds the attacker's exact canonical intent
	// (quantized aim positions, hit data) behind its own
	// schema-declared `visibility`. `INTERNAL` (the default) writes it
	// untouched -- the fast path every pre-existing caller keeps. Any
	// other audience means this snapshot is being encoded for ONE
	// specific remote peer, so each retained context is sanitized for
	// that peer individually: `context.source == owner` means this
	// runtime's OWN entity produced the context (e.g. a self-applied
	// effect), so the peer -- which owns this component and therefore
	// owns that source -- gets `OWNER_ONLY`-audience fidelity (still
	// redacted if the schema itself marked the context `INTERNAL`).
	// Any other source is foreign: the peer is only ever an OBSERVER of
	// that attacker's private aim data, so it is sanitized with the
	// `OBSERVABLE` audience instead, surviving only if the schema
	// opted into `OBSERVABLE` visibility. Known accepted edge: a single
	// peer that owns BOTH the attacker's component and this (target)
	// component still gets the sanitized foreign-source copy here --
	// it gets full fidelity from the attacker's OWN component
	// snapshot instead, where `context.source == owner` holds there.
	Status target_context_status =
			p_target_context_audience == TargetResultVisibility::INTERNAL ?
					write_target_effect_context(p_writer,
							effect.target_context) :
					write_target_effect_context(p_writer,
							sanitize_target_effect_context(
									effect.target_context,
									effect.target_context.source == owner ?
											TargetResultVisibility::OWNER_ONLY :
											TargetResultVisibility::OBSERVABLE));
	if (!target_context_status.ok()) {
		return target_context_status;
	}
	p_writer.write_u64(effect.revision);

	p_writer.write_count(effect.modifier_handles.size(), MAX_EFFECT_MODIFIERS);
	for (const std::vector<ModifierHandle> &per_decl : effect.modifier_handles) {
		p_writer.write_count(per_decl.size(), MAX_STACK_COUNT);
		for (ModifierHandle handle : per_decl) {
			p_writer.write_u64(handle.value);
		}
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status EffectRuntime::write_active_effect_delta_record(SnapshotWriter &p_writer, EffectHandle p_handle,
		TargetResultVisibility p_target_context_audience) const {
	auto it = active_effects.find(p_handle);
	if (it == active_effects.end()) {
		return make_status(StatusCode::UNKNOWN_EFFECT_HANDLE, DiagnosticId::NONE, p_handle.value);
	}
	return write_active_effect_fields(p_writer, it->second, p_target_context_audience);
}

Status EffectRuntime::restore_snapshot(SnapshotReader &p_reader) {
	std::map<EffectHandle, ActiveEffect> new_active_effects;
	const Status decode_status = decode_snapshot_section(p_reader, new_active_effects);
	if (!decode_status.ok()) {
		return decode_status;
	}

	std::size_t validated_retained_bytes = 0;
	const Status validate_status = validate_records(new_active_effects, validated_retained_bytes);
	if (!validate_status.ok()) {
		return validate_status;
	}

	install_records(std::move(new_active_effects), validated_retained_bytes);
	return ok_status();
}

// The pure-decode half of `restore_snapshot`: reads a COMPLETE
// `GA_SNAPSHOT_KIND_EFFECT_RUNTIME` section into `r_effects` without
// installing or even validating the aggregate retained-context budget (see
// `validate_records`) -- both `restore_snapshot` and the delta codec's
// `DeltaSectionMode::FULL_REENCODE` apply path
// (`AbilityComponent::apply_delta_batch`, ga_ability_component.cpp) call
// this and then `validate_records` before ever calling `install_records`,
// so a full-reencode section decodes into a local temporary just like a
// RECORD_OPS section does.
Status EffectRuntime::decode_snapshot_section(SnapshotReader &p_reader, std::map<EffectHandle, ActiveEffect> &r_effects) const {
	if (!p_reader.begin_section(GA_SNAPSHOT_KIND_EFFECT_RUNTIME)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_ACTIVE_EFFECTS)) {
		return p_reader.status();
	}

	std::map<EffectHandle, ActiveEffect> new_active_effects;
	for (std::size_t i = 0; i < count; ++i) {
		if (!p_reader.begin_section(GA_SNAPSHOT_KIND_ACTIVE_EFFECT)) {
			return p_reader.status();
		}
		ActiveEffect effect;
		std::size_t effect_context_bytes = 0;
		const Status entry_status = decode_active_effect_fields(p_reader, effect, effect_context_bytes);
		if (!entry_status.ok()) {
			return entry_status;
		}
		if (!p_reader.end_section()) {
			return p_reader.status();
		}
		new_active_effects[effect.handle] = std::move(effect);
	}

	if (!p_reader.end_section()) {
		return p_reader.status();
	}

	r_effects = std::move(new_active_effects);
	return ok_status();
}

Status EffectRuntime::decode_active_effect_fields(SnapshotReader &p_reader, ActiveEffect &r_effect, std::size_t &r_context_bytes) const {
	ActiveEffect effect;
	std::uint32_t definition_id = 0;
	std::uint64_t handle_value = 0;
	std::uint64_t source_value = 0;
	std::uint64_t target_value = 0;
	std::uint64_t tag_source_value = 0;

	if (!p_reader.read_u32(definition_id) ||
			!p_reader.read_u64(handle_value) ||
			!p_reader.read_u64(source_value) ||
			!p_reader.read_u64(target_value) ||
			!p_reader.read_u32(effect.stack_count) ||
			!p_reader.read_u64(effect.start_tick) ||
			!p_reader.read_u64(effect.end_tick) ||
			!p_reader.read_bool(effect.has_period) ||
			!p_reader.read_u64(effect.next_period_tick)) {
		return p_reader.status();
	}
	effect.definition = DefinitionId(definition_id);
	effect.handle = EffectHandle{ handle_value };
	effect.source = EntityId{ source_value };
	effect.target = EntityId{ target_value };

	if (registry->find(effect.definition) == nullptr) {
		return make_status(StatusCode::UNKNOWN_EFFECT, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, definition_id);
	}

	std::size_t magnitude_count = 0;
	if (!p_reader.read_count(magnitude_count, MAX_EFFECT_MODIFIERS)) {
		return p_reader.status();
	}
	effect.resolved_magnitudes.reserve(magnitude_count);
	for (std::size_t m = 0; m < magnitude_count; ++m) {
		Fixed value;
		if (!p_reader.read_fixed(value)) {
			return p_reader.status();
		}
		effect.resolved_magnitudes.push_back(value);
	}

	if (!p_reader.read_u64(tag_source_value) ||
			!p_reader.read_u64(effect.context_tag)) {
		return p_reader.status();
	}
	Status target_context_status =
			read_target_effect_context(p_reader,
					effect.target_context);
	if (!target_context_status.ok()) {
		return target_context_status;
	}
	std::size_t effect_context_bytes = 0;
	const Status measure_status = measure_target_effect_context_bytes(
			effect.target_context, effect_context_bytes);
	if (!measure_status.ok()) {
		return measure_status;
	}
	if (!p_reader.read_u64(effect.revision)) {
		return p_reader.status();
	}
	effect.tag_source = SourceToken{ tag_source_value };

	std::size_t decl_count = 0;
	if (!p_reader.read_count(decl_count, MAX_EFFECT_MODIFIERS)) {
		return p_reader.status();
	}
	effect.modifier_handles.resize(decl_count);
	for (std::size_t d = 0; d < decl_count; ++d) {
		std::size_t stack_units = 0;
		if (!p_reader.read_count(stack_units, MAX_STACK_COUNT)) {
			return p_reader.status();
		}
		effect.modifier_handles[d].reserve(stack_units);
		for (std::size_t u = 0; u < stack_units; ++u) {
			std::uint64_t modifier_handle_value = 0;
			if (!p_reader.read_u64(modifier_handle_value)) {
				return p_reader.status();
			}
			effect.modifier_handles[d].push_back(ModifierHandle{ modifier_handle_value });
		}
	}
	if (!p_reader.ok()) {
		return p_reader.status();
	}

	r_effect = std::move(effect);
	r_context_bytes = effect_context_bytes;
	return ok_status();
}

Status EffectRuntime::decode_active_effect_delta_record(SnapshotReader &p_reader, ActiveEffect &r_effect, std::size_t &r_context_bytes) const {
	return decode_active_effect_fields(p_reader, r_effect, r_context_bytes);
}

Status EffectRuntime::validate_records(const std::map<EffectHandle, ActiveEffect> &p_effects, std::size_t &r_retained_bytes) const {
	if (p_effects.size() > MAX_ACTIVE_EFFECTS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_effects.size());
	}
	std::size_t total_bytes = 0;
	for (const auto &entry : p_effects) {
		std::size_t context_bytes = 0;
		const Status measure_status = measure_target_effect_context_bytes(entry.second.target_context, context_bytes);
		if (!measure_status.ok()) {
			return measure_status;
		}
		total_bytes += context_bytes;
	}
	// Fail closed on a hand-crafted or corrupted set whose retained
	// contexts, summed, exceed the budget -- BEFORE swapping anything into
	// live state (see `restore_snapshot`'s own doc comment,
	// ga_effect_runtime.h). Content this file ever wrote always satisfies
	// this, since every path that stores a `target_context` already
	// enforces the SAME bound before committing.
	if (total_bytes > MAX_RETAINED_TARGET_CONTEXT_BYTES) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, total_bytes);
	}
	r_retained_bytes = total_bytes;
	return ok_status();
}

void EffectRuntime::install_records(std::map<EffectHandle, ActiveEffect> p_effects, std::size_t p_retained_bytes) {
	std::map<std::pair<std::string, std::uint64_t>, EffectHandle> new_stack_index;
	std::uint64_t max_handle_value = 0;
	std::uint64_t max_tag_source_value = 0;
	for (const auto &entry : p_effects) {
		const ActiveEffect &effect = entry.second;
		max_handle_value = std::max(max_handle_value, effect.handle.value);
		max_tag_source_value = std::max(max_tag_source_value, effect.tag_source.value);
		const EffectDefinition *definition = registry->find(effect.definition);
		if (definition != nullptr && definition->stacking.stackable) {
			const std::uint64_t scope_value = (definition->stacking.source_scope == StackSourceScope::SOURCE_SCOPED)
					? effect.source.value
					: 0;
			new_stack_index[std::make_pair(definition->stacking.stack_key, scope_value)] = effect.handle;
		}
	}
	active_effects = std::move(p_effects);
	stack_index = std::move(new_stack_index);
	handle_allocator.restore_from(max_handle_value + 1);
	tag_source_allocator.restore_from(max_tag_source_value + 1);
	retained_target_context_bytes_total = p_retained_bytes;
}

} // namespace ga
