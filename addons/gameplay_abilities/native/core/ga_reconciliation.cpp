#include "core/ga_reconciliation.h"

#include <algorithm>
#include <utility>

namespace ga {

// ---------------------------------------------------------------------------
// PredictionAck codec
// ---------------------------------------------------------------------------

Status encode_prediction_ack(const PredictionAck &p_ack, std::vector<std::uint8_t> &r_out) {
	r_out.clear();
	if (p_ack.temp_handles.size() != p_ack.authority_handles.size()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, p_ack.temp_handles.size());
	}
	if (p_ack.temp_handles.size() > MAX_PENDING_PREDICTIONS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_ack.temp_handles.size());
	}

	ByteWriter writer(MAX_COMMAND_PACKET_BYTES);
	writer.write_u64(p_ack.command_sequence.value);
	writer.write_u64(p_ack.prediction_key.value);
	writer.write_u8(static_cast<std::uint8_t>(p_ack.kind));
	writer.write_count(p_ack.temp_handles.size(), MAX_PENDING_PREDICTIONS);
	for (std::size_t i = 0; i < p_ack.temp_handles.size(); ++i) {
		writer.write_u64(p_ack.temp_handles[i].value);
		writer.write_u64(p_ack.authority_handles[i].value);
	}
	writer.write_u16(static_cast<std::uint16_t>(p_ack.rejection_status.code));
	writer.write_u16(static_cast<std::uint16_t>(p_ack.rejection_status.diagnostic));
	writer.write_u64(p_ack.rejection_status.detail);

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

Status decode_prediction_ack(const std::vector<std::uint8_t> &p_bytes, PredictionAck &r_ack) {
	r_ack = PredictionAck();
	ByteReader reader(p_bytes);

	std::uint64_t sequence_raw = 0;
	std::uint64_t key_raw = 0;
	std::uint8_t kind_raw = 0;
	if (!reader.read_u64(sequence_raw) || !reader.read_u64(key_raw) || !reader.read_u8(kind_raw)) {
		return reader.status();
	}
	if (kind_raw > static_cast<std::uint8_t>(PredictionAckKind::REJECTED)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, kind_raw);
	}

	std::size_t mapping_count = 0;
	// Each element is 16 bytes (two u64s).
	if (!reader.read_count(mapping_count, MAX_PENDING_PREDICTIONS, 16)) {
		return reader.status();
	}

	PredictionAck out;
	out.command_sequence = CommandSeq{ sequence_raw };
	out.prediction_key = PredictionKey{ key_raw };
	out.kind = static_cast<PredictionAckKind>(kind_raw);
	out.temp_handles.reserve(mapping_count);
	out.authority_handles.reserve(mapping_count);
	for (std::size_t i = 0; i < mapping_count; ++i) {
		std::uint64_t temp_raw = 0;
		std::uint64_t authority_raw = 0;
		if (!reader.read_u64(temp_raw) || !reader.read_u64(authority_raw)) {
			return reader.status();
		}
		out.temp_handles.push_back(EffectHandle{ temp_raw });
		out.authority_handles.push_back(EffectHandle{ authority_raw });
	}

	std::uint16_t code_raw = 0;
	std::uint16_t diagnostic_raw = 0;
	std::uint64_t detail_raw = 0;
	if (!reader.read_u16(code_raw) || !reader.read_u16(diagnostic_raw) || !reader.read_u64(detail_raw)) {
		return reader.status();
	}
	out.rejection_status = make_status(static_cast<StatusCode>(code_raw), static_cast<DiagnosticId>(diagnostic_raw), detail_raw);

	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.remaining());
	}

	r_ack = std::move(out);
	return ok_status();
}

// ---------------------------------------------------------------------------
// PredictionHandleMap
// ---------------------------------------------------------------------------

void PredictionHandleMap::map(EffectHandle p_temp, EffectHandle p_authority) {
	if (!p_temp || !p_authority) {
		return;
	}
	if (by_temp.find(p_temp.value) != by_temp.end()) {
		return; // already mapped -- never duplicate/overwrite an existing mapping.
	}
	if (by_temp.size() >= MAX_PENDING_PREDICTIONS) {
		// Bounded FIFO eviction of the oldest-inserted mapping.
		if (!insertion_order.empty()) {
			const std::uint64_t oldest = insertion_order.front();
			insertion_order.erase(insertion_order.begin());
			const auto it = by_temp.find(oldest);
			if (it != by_temp.end()) {
				by_authority.erase(it->second);
				by_temp.erase(it);
			}
		}
	}
	by_temp[p_temp.value] = p_authority.value;
	by_authority[p_authority.value] = p_temp.value;
	insertion_order.push_back(p_temp.value);
}

bool PredictionHandleMap::authority_to_temp(EffectHandle p_authority, EffectHandle &r_temp) const {
	const auto it = by_authority.find(p_authority.value);
	if (it == by_authority.end()) {
		return false;
	}
	r_temp = EffectHandle{ it->second };
	return true;
}

bool PredictionHandleMap::temp_to_authority(EffectHandle p_temp, EffectHandle &r_authority) const {
	const auto it = by_temp.find(p_temp.value);
	if (it == by_temp.end()) {
		return false;
	}
	r_authority = EffectHandle{ it->second };
	return true;
}

void PredictionHandleMap::erase_temp(EffectHandle p_temp) {
	const auto it = by_temp.find(p_temp.value);
	if (it == by_temp.end()) {
		return;
	}
	by_authority.erase(it->second);
	by_temp.erase(it);
	const auto order_it = std::find(insertion_order.begin(), insertion_order.end(), p_temp.value);
	if (order_it != insertion_order.end()) {
		insertion_order.erase(order_it);
	}
}

// ---------------------------------------------------------------------------
// PredictionReconciler
// ---------------------------------------------------------------------------

PredictionReconciler::PredictionReconciler(PredictingComponent &p_predicting) :
		predicting(&p_predicting) {
	predicting->component().add_effect_lifecycle_listener([this](const EffectLifecycleEvent &p_event, NotificationQueue &p_queue) {
		on_effect_lifecycle(p_event, p_queue);
	});
}

void PredictionReconciler::on_effect_lifecycle(const EffectLifecycleEvent &p_event, NotificationQueue &) {
	// Purely bounded-footprint pruning: once an effect this map maps (e.g. a
	// confirmed predicted cooldown) is finally removed/expired, its mapping
	// entry no longer refers to anything live and is forgotten.
	if (p_event.kind == EffectLifecycleKind::REMOVED || p_event.kind == EffectLifecycleKind::EXPIRED) {
		handles.erase_temp(p_event.handle);
	}
}

Status PredictionReconciler::handle_acknowledgement(const PredictionAck &p_ack, PendingPrediction *r_rejected) {
	PendingPrediction entry;
	const Status close_status = predicting->journal().close(p_ack.prediction_key, entry);
	if (!close_status.ok()) {
		return close_status; // unknown/stale identity -- never mutates anything, never resurrects temporary state.
	}
	if (entry.command_sequence != p_ack.command_sequence) {
		// Defensive: the key matched but the paired sequence did not. Treat
		// exactly like an unknown/stale ack -- the entry is already gone
		// (closed above) and nothing else is touched.
		return make_status(StatusCode::PREDICTION_UNKNOWN_KEY, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_ack.command_sequence.value);
	}

	const CueDedupId dedup{ predicting->component().entity(), entry.ability, INVALID_EFFECT_HANDLE, entry.prediction_key.value };

	if (p_ack.kind == PredictionAckKind::ACCEPTED) {
		for (std::size_t i = 0; i < p_ack.temp_handles.size() && i < p_ack.authority_handles.size(); ++i) {
			handles.map(p_ack.temp_handles[i], p_ack.authority_handles[i]);
		}
		predicting->emit_presentation(PredictionPresentationEvent{ dedup, entry.prediction_key, CuePhase::CONFIRM,
				entry.ability, predicting->component().entity(), entry.issued_tick });
		return ok_status();
	}

	// REJECTED.
	if (r_rejected != nullptr) {
		*r_rejected = entry;
	}
	predicting->emit_presentation(PredictionPresentationEvent{ dedup, entry.prediction_key, CuePhase::CORRECT,
			entry.ability, predicting->component().entity(), entry.issued_tick });
	return ok_status();
}

ReconciliationResult PredictionReconciler::reconcile(const std::vector<std::uint8_t> &p_confirmed_snapshot, Tick p_tick,
		const proto::ClientEventStream &p_stream,
		const AuthoritativeEventApplier &p_apply_events,
		GameplayAbilityWorldCoordinator *p_target_coordinator) {
	ReconciliationResult result;

	SnapshotReader reader(p_confirmed_snapshot);
	const Status restore_status = predicting->component().restore_snapshot(reader);
	if (!restore_status.ok()) {
		result.outcome = ReconciliationOutcomeKind::COMPONENT_MUST_BE_REBUILT;
		result.status = restore_status;
		// The component may now hold inconsistent mixed state. Originally
		// this just called `journal().clear()` directly: every pending
		// entry was silently dropped with NO cancellation cue, and
		// prediction was left ENABLED against a component whose restore
		// just failed -- a caller that did not immediately discard/rebuild
		// (the pre-Finding-5 reality: the Godot bridge only ever emitted a
		// diagnostic and kept using this same component) would then let a
		// caller keep predicting new commands on top of unknown/inconsistent
		// state, and every in-flight prediction vanished with no CANCEL a
		// presentation layer could ever observe. `disable_and_clear()` is
		// the SAME bounds-violation recovery hook `on_baseline_lost`/
		// `on_disconnected`/`on_manifest_changed`/`sweep_expired` already use
		// for every other "this journal's contents are no longer trustworthy"
		// condition: it emits exactly one `CuePhase::CANCEL` per dropped
		// entry AND disables prediction until an explicit
		// `resume_after_recovery()` (which the Godot layer now drives once a
		// fresh confirmed baseline actually lands -- see
		// `GameplayAbilityNetworkBridge`'s owner-path snapshot handling). A
		// restore failure is exactly as severe as those other conditions
		// (arguably more so -- the component itself may be mid-mixed-state),
		// so it gets the identical treatment rather than a quieter one.
		predicting->disable_and_clear();
		return result;
	}

	if (p_apply_events) {
		const Status apply_status = p_apply_events(predicting->component());
		if (!apply_status.ok()) {
			result.outcome = ReconciliationOutcomeKind::EVENT_APPLICATION_FAILED;
			result.status = apply_status;
			return result;
		}
	}

	// Read before clearing: these are exactly the entries this reconciler's
	// OWN journal still considers pending (an already-acknowledged --
	// accepted or rejected -- command is already gone via
	// `handle_acknowledgement`'s `close()`, so it is never redundantly
	// replayed here).
	const std::vector<PendingPrediction> still_pending = predicting->journal().pending_in_order();
	predicting->journal().clear();

	result.outcome = ReconciliationOutcomeKind::REPLAYED;
	result.status = ok_status();
	for (const PendingPrediction &old_entry : still_pending) {
		// `repredict`, NOT `request`: a replayed command must keep its
		// ORIGINAL `command_sequence`/`prediction_key` rather than allocate a
		// fresh identity. This is the fix for "Reconciliation can execute a
		// pending ability twice" -- the release-review finding that a client
		// predicting commands 1/2/3, having command 1 rejected while command
		// 2 has ALREADY executed on the server (its acknowledgement simply
		// not yet received here), would previously resend command 2 under a
		// brand-new sequence number once replayed. The server's
		// `ga::proto::CommandSequenceTracker` has no way to recognize a
		// fresh sequence as a repeat of anything, so it would execute the
		// same logical action a second time (an instant Heal/damage ability
		// with no cooldown has nothing else to stop it). Preserving identity
		// means the resend the bridge issues (`GameplayAbilityNetworkBridge::
		// reconcile_and_resend` forwards `outcome.command_sequence`/
		// `outcome.prediction_key` unchanged) is recognized as an EXACT
		// DUPLICATE and replayed idempotently instead of re-executed; a
		// late-arriving ack for the original command still finds THIS
		// re-created journal entry, closing it normally.
		//
		// Invariant this depends on -- replaying a preserved sequence against
		// the just-restored baseline must not spuriously fail
		// `AbilityComponent::request_activation_immediate`'s own per-grant
		// staleness gate (`p_request.command_sequence <= grant.
		// last_command_sequence` -> STALE_COMMAND): `still_pending` above is
		// read from THIS reconciler's own journal, which only ever holds
		// entries `handle_acknowledgement` has NOT yet closed -- i.e. neither
		// an ACCEPTED nor a REJECTED decision has reached this client for
		// `old_entry` yet. `p_confirmed_snapshot` is therefore necessarily a
		// baseline captured/adopted strictly BEFORE that still-outstanding
		// decision (a server only ever advances a grant's confirmed
		// `last_command_sequence` -- and so only ever lets that advance show
		// up in any snapshot this client could have been given -- at the
		// exact moment it decides a command's fate, which is the same moment
		// it sends the very ack `old_entry` is still waiting on). So the
		// restored baseline's `grant.last_command_sequence` for this spec is
		// always strictly less than `old_entry.command_sequence`, and the
		// staleness check passes exactly like a normal fresh activation
		// would. Should this invariant ever be violated in practice (e.g. a
		// caller feeds `reconcile` a newer snapshot than the one that
		// accompanied the decision still pending here), `request_activation_
		// immediate` fails closed with `STALE_COMMAND` instead of double-
		// applying the command locally -- which is the CORRECT outcome in
		// that case too, since it would mean the baseline already reflects
		// this exact command's effect. Either way, `repredict`'s outcome
		// still carries the preserved identity (stamped before the
		// activation call resolves), so the bridge can still resend it for
		// the server's own duplicate detection to settle idempotently.
		PredictionOutcome outcome;
		if (old_entry.command_kind ==
						PredictionCommandKind::TARGET_INTENT &&
				p_target_coordinator != nullptr) {
			const TargetPredictionOutcome target =
					predicting->repredict_target_intent(
							*p_target_coordinator, old_entry,
							p_tick, p_stream);
			outcome.mode = target.mode;
			outcome.status = target.status;
			outcome.command_sequence =
					target.command_sequence;
			outcome.prediction_key =
					target.prediction_key;
		} else {
			outcome = predicting->repredict(old_entry, p_tick,
					p_stream);
		}
		result.replayed.push_back(old_entry);
		result.replay_results.push_back(outcome);
	}
	return result;
}

// ---------------------------------------------------------------------------
// ServerTickEstimator
// ---------------------------------------------------------------------------

void ServerTickEstimator::observe(Tick p_local_tick, Tick p_authoritative_tick) {
	const std::int64_t new_offset = static_cast<std::int64_t>(p_authoritative_tick) - static_cast<std::int64_t>(p_local_tick);
	if (!sampled) {
		offset = new_offset;
		sampled = true;
		return;
	}
	const std::int64_t drift = new_offset - offset;
	const std::int64_t abs_drift = drift < 0 ? -drift : drift;
	if (static_cast<std::uint64_t>(abs_drift) > TICK_ESTIMATOR_SNAP_THRESHOLD_TICKS) {
		offset = new_offset; // snap immediately -- bounded to one sample's worth of latency, never a slow crawl.
	} else {
		offset += drift / TICK_ESTIMATOR_SMOOTH_DENOMINATOR; // truncates toward zero -- deterministic, integer-only.
	}
}

Tick ServerTickEstimator::estimate(Tick p_local_tick) const {
	const std::int64_t result = static_cast<std::int64_t>(p_local_tick) + offset;
	return result < 0 ? Tick(0) : Tick(result);
}

} // namespace ga
