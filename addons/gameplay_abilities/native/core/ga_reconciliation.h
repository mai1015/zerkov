#ifndef GAMEPLAY_ABILITIES_CORE_RECONCILIATION_H
#define GAMEPLAY_ABILITIES_CORE_RECONCILIATION_H

#include "core/ga_ability_component.h"
#include "core/ga_bytes.h"
#include "core/ga_effect_runtime.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_prediction.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "protocol/gap_event_stream.h"

#include <cstdint>
#include <functional>
#include <map>
#include <vector>

// Section 8, tasks 8.5-8.7 (acknowledgement/handle mapping, component-local
// reconciliation, prediction-aware presentation) plus the Authoritative Tick
// Alignment requirement. Composes over `PredictingComponent`
// (ga_prediction.h) -- never edits `ga_ability_component.h`/.cpp or any
// other existing file.
namespace ga {

// ---------------------------------------------------------------------------
// Task 8.5 -- Prediction acknowledgement and handle mapping
// ---------------------------------------------------------------------------

enum class PredictionAckKind : std::uint8_t {
	ACCEPTED = 0,
	REJECTED = 1,
};

// One authority decision about a previously predicted command, identified
// by (command sequence, prediction key) -- the identity tuple the
// "Prediction Acknowledgement and Handle Mapping" requirement names (the
// third element, session identity, is the transport/bridge's concern above
// this component-local file: this client's own journal is already scoped to
// its own session, so a component-local ack only needs to match ITS OWN
// pending entries by (sequence, key)).
struct PredictionAck {
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	PredictionAckKind kind = PredictionAckKind::ACCEPTED;
	// ACCEPTED only: authority-issued handle for each of the prediction's
	// own temporary (locally-issued) effect handles that received a durable
	// authority counterpart (e.g. the predicted cooldown). Parallel arrays,
	// same length; an op that never had a handle (an instant cost, or an
	// instant self effect) is simply absent from both. Bounded by
	// `MAX_PENDING_PREDICTIONS` (a generous per-ack cap on how many durable
	// handles one predicted command could plausibly produce -- no second,
	// differently-named bound is introduced for this).
	std::vector<EffectHandle> temp_handles;
	std::vector<EffectHandle> authority_handles;
	Status rejection_status; // meaningful only when kind == REJECTED
};

// Canonical little-endian encoding of `PredictionAck`, following the
// shared contract's encoding rules (explicit byte shifts, length-prefixed
// counts, fail-closed decoding). This is a component-local bookkeeping
// message, not yet the wire-final `MessageType::COMMAND_ACK` payload (task
// 7.x, a separate agent's scope owns that DTO); it exists so
// `PredictionReconciler::handle_acknowledgement` can be driven through
// `ga::proto::FakeTransport` in tests exactly like a real network message,
// proving reordering/duplication handling is real rather than
// hand-simulated.
Status encode_prediction_ack(const PredictionAck &p_ack, std::vector<std::uint8_t> &r_out);
Status decode_prediction_ack(const std::vector<std::uint8_t> &p_bytes, PredictionAck &r_ack);

// Bounded temp -> authority `EffectHandle` translation table. A mapping is
// added only when a `PredictionAck::ACCEPTED` names it (via
// `PredictionReconciler::handle_acknowledgement`) and pruned automatically
// once its underlying effect is removed/expired (see
// `PredictionReconciler`'s constructor, which wires an effect-lifecycle
// listener purely for this pruning) -- so its footprint is tied to real
// effect lifetime, never to unmapped growth. Additionally hard-capped at
// `MAX_PENDING_PREDICTIONS` entries (evicting the oldest-inserted mapping
// first) as defense in depth.
class PredictionHandleMap {
public:
	void map(EffectHandle p_temp, EffectHandle p_authority);
	bool authority_to_temp(EffectHandle p_authority, EffectHandle &r_temp) const;
	bool temp_to_authority(EffectHandle p_temp, EffectHandle &r_authority) const;
	void erase_temp(EffectHandle p_temp);
	std::size_t size() const { return by_temp.size(); }

private:
	std::map<std::uint64_t, std::uint64_t> by_temp; // temp.value -> authority.value
	std::map<std::uint64_t, std::uint64_t> by_authority; // authority.value -> temp.value
	std::vector<std::uint64_t> insertion_order; // temp.value, oldest first -- bounded FIFO eviction
};

// ---------------------------------------------------------------------------
// Task 8.6 -- Component-local reconciliation
// ---------------------------------------------------------------------------

enum class ReconciliationOutcomeKind : std::uint8_t {
	OK = 0,
	// `AbilityComponent::restore_snapshot` itself failed. Per that method's
	// own documented contract, a non-OK result may leave the component in
	// inconsistent MIXED state across subsystem boundaries (an earlier
	// section already replaced, a later one not) -- the component MUST be
	// discarded and rebuilt by whoever owns its construction (this file
	// never owns that; it only ever receives an `AbilityComponent&`). No
	// replay is attempted in this case. `reconcile()` also calls
	// `predicting->disable_and_clear()` before returning this outcome: every
	// still-pending entry is dropped with exactly one `CuePhase::CANCEL`
	// each, and prediction is disabled until an explicit
	// `resume_after_recovery()`, so a caller that (per the Godot bridge's
	// own rollback-then-quarantine contract -- see
	// `GameplayAbilityComponent::restore_snapshot`/`reconcile_snapshot`)
	// keeps this same component installed after rolling it back never
	// silently keeps predicting against a baseline this reconciliation
	// attempt could not actually establish.
	COMPONENT_MUST_BE_REBUILT = 1,
	// The confirmed authoritative-events callback itself failed. The
	// component's attribute/tag/effect/grant/execution state reflects the
	// restored snapshot but not every authoritative delta; no replay is
	// attempted (replaying predicted commands on top of a KNOWN-incomplete
	// baseline would compound the divergence rather than resolve it).
	EVENT_APPLICATION_FAILED = 2,
	// Snapshot restored and events applied; every still-pending journaled
	// command was replayed (see `ReconciliationResult::replay_results` for
	// each one's own outcome, which may itself be a rejection -- that is
	// not a failure of reconciliation itself).
	REPLAYED = 3,
};

struct ReconciliationResult {
	ReconciliationOutcomeKind outcome = ReconciliationOutcomeKind::OK;
	Status status; // meaningful when outcome != REPLAYED
	std::vector<PendingPrediction> replayed; // still-pending commands, in original command-sequence order
	std::vector<PredictionOutcome> replay_results; // parallel to `replayed`
};

// Optional seam: applies whatever valid authoritative events arrived after
// the confirmed snapshot but before reconciliation, directly against
// `p_component`. This file never decodes a real event batch itself (task
// 7.8's `ga::proto::ClientEventStream`/`ApplyEventBatchFn` own that); a
// caller that has such deltas supplies them here so the documented order
// (restore snapshot, THEN apply valid authoritative events, THEN replay
// still-pending commands) holds structurally rather than by caller
// discipline alone.
using AuthoritativeEventApplier = std::function<Status(AbilityComponent &p_component)>;

// ---------------------------------------------------------------------------
// Task 8.7 -- Prediction-aware presentation events (declared in
// ga_prediction.h as `PredictionPresentationEvent`, reusing the existing
// `CuePhase`/`CueDedupId`) plus acknowledgement/reconciliation.
// ---------------------------------------------------------------------------

// Collaborator that owns handle mapping (8.5), reconciliation (8.6), and the
// CONFIRM/CORRECT/CANCEL half of prediction-aware presentation (8.7) for one
// `PredictingComponent`. The PREDICT phase is emitted by
// `PredictingComponent` itself (ga_prediction.h) at request time; this class
// emits the matching later phase through the SAME
// `PredictingComponent::emit_presentation` dispatch point, reusing the
// identical per-command `CueDedupId` so an adapter can match a
// PREDICT/CONFIRM/CORRECT/CANCEL quadruple by dedup alone.
class PredictionReconciler {
public:
	explicit PredictionReconciler(PredictingComponent &p_predicting);

	// `StatusCode::PREDICTION_UNKNOWN_KEY` (never mutates anything -- no
	// state change, no presentation event, no resurrection of dropped
	// temporary state) if `p_ack`'s `prediction_key` is not a currently
	// pending journal entry: covers "acknowledgement arrives after resync"
	// (the journal was discarded by a newer snapshot / disconnect / despawn
	// / age-out) and duplicate/reordered redelivery of an already-handled
	// ack (the first delivery already closed the entry).
	//
	// Also fails the SAME way, WITHOUT closing anything, if the entry IS
	// still pending but its recorded `command_sequence` does not match
	// `p_ack.command_sequence` (a corrupted or spoofed ack naming a stale
	// sequence under a colliding key) -- defense in depth beyond what a
	// `PredictionKey` collision could plausibly produce in practice.
	//
	// ACCEPTED: closes the journal entry, records every declared
	// temp -> authority handle mapping (no re-application -- the effect was
	// already applied at PREDICT time), and emits exactly one
	// `CuePhase::CONFIRM` presentation event reusing that command's PREDICT
	// dedup id.
	//
	// REJECTED: closes the journal entry, emits exactly one
	// `CuePhase::CORRECT` presentation event, and (if `r_rejected` is
	// non-null) returns the closed entry so the caller can immediately
	// drive `reconcile` below with it excluded from further replay (it has
	// already been authoritatively decided, not merely abandoned).
	Status handle_acknowledgement(const PredictionAck &p_ack, PendingPrediction *r_rejected = nullptr);

	const PredictionHandleMap &handle_map() const { return handles; }

	// `p_confirmed_snapshot`: the latest CONFIRMED (authoritative) component
	// snapshot bytes (e.g. a `ga::proto::SnapshotEnvelope::payload` -- this
	// file never decodes the envelope itself, see gap_resync.h). Restores
	// it via `AbilityComponent::restore_snapshot`; a non-OK result means
	// "discard and rebuild the whole component" per that method's own
	// contract, so this call stops there (see
	// `ReconciliationOutcomeKind::COMPONENT_MUST_BE_REBUILT`) without
	// touching the journal or attempting any replay.
	//
	// On a successful restore, invokes `p_apply_events` (if supplied)
	// against the now-restored component, THEN replays every entry
	// `journal().pending_in_order()` still holds (read before this call
	// clears them) by re-running `PredictingComponent::repredict` with each
	// entry's ORIGINAL `ActivationRequest`, in original command-sequence
	// order, at `p_tick` -- "a refreshed local result" per the "Two
	// predictions are pending" scenario. A command already closed via
	// `handle_acknowledgement` (accepted or rejected) is no longer in the
	// journal and is therefore never redundantly replayed.
	//
	// `repredict` (NOT `request`) is used deliberately: the replayed entry's
	// ORIGINAL `command_sequence`/`prediction_key` are preserved rather than
	// letting a fresh identity be allocated, so that (a) a resend of a
	// command the server already executed under its original identity is
	// recognized as an exact DUPLICATE by `ga::proto::
	// CommandSequenceTracker` instead of executing a second time, and (b) a
	// late-arriving acknowledgement for that original command still matches
	// this re-created journal entry by the same preserved key. See
	// `ga_reconciliation.cpp`'s `reconcile()` for the full invariant
	// (this is the fix for "Reconciliation can execute a pending ability
	// twice").
	//
	// Scope: this call only ever mutates `predicting->component()`'s
	// gameplay-ability-component state (attributes/tags/effects/grants/
	// executions) and this reconciler's own bookkeeping. It never claims to
	// roll back scene, physics, projectile, animation, or world state --
	// see the "Predicted ability moved the character" scenario.
	ReconciliationResult reconcile(const std::vector<std::uint8_t> &p_confirmed_snapshot, Tick p_tick,
			const proto::ClientEventStream &p_stream,
			const AuthoritativeEventApplier &p_apply_events = nullptr,
			GameplayAbilityWorldCoordinator *p_target_coordinator =
					nullptr);

private:
	void on_effect_lifecycle(const EffectLifecycleEvent &p_event, NotificationQueue &p_queue);

	PredictingComponent *predicting;
	PredictionHandleMap handles;
};

// ---------------------------------------------------------------------------
// Authoritative Tick Alignment
// ---------------------------------------------------------------------------

// Any single-sample drift whose absolute value exceeds this many ticks snaps
// the estimate immediately to the newly observed offset instead of
// smoothing gradually -- this bounds how long a large one-time correction
// (e.g. right after a reconnect/resync) takes to become visible, instead of
// converging slowly sample by sample.
constexpr std::uint64_t TICK_ESTIMATOR_SNAP_THRESHOLD_TICKS = 30;
// Otherwise, the estimate moves this fraction of the way toward the newly
// observed drift per sample (rounding toward zero via truncating integer
// division) -- a bounded, deterministic, integer-only smoothing step.
constexpr std::int64_t TICK_ESTIMATOR_SMOOTH_DENOMINATOR = 4;

// Bounded estimator of the authoritative gameplay tick from acknowledged
// server messages and round-trip samples (design.md "Clock alignment and
// latency"; spec "Authoritative Tick Alignment"). Presentation-only: this
// class has no way to feed its estimate back into `AbilityComponent` even if
// misused -- it only ever stores/returns plain `Tick` values, never calls
// into any mutating API. Server ticks alone govern effect expiration,
// periodic execution, cooldown eligibility, and validation; a client tick
// (and this estimate) is always advisory. No wall clock: every sample is a
// caller-supplied pair of (this client's own advisory local tick, the
// authoritative tick a server message named).
//
// `observe()`'s signature already has no dependency on WHICH message
// supplied its `p_authoritative_tick` -- a snapshot, an event batch, or the
// bounded liveness-only heartbeat (add-granular-delta-replication-2026-07-27
// task 4.4; `ga::proto::HeartbeatPayload`, protocol/gap_heartbeat.h) all
// feed this SAME entry point identically, so "Tick estimation survives
// suppression" (a peer receiving only heartbeats for an extended idle
// period keeps correcting within these documented smoothing bounds) needs
// no dedicated heartbeat-shaped overload here.
class ServerTickEstimator {
public:
	// Records one sample. The very first call establishes the initial
	// offset outright (nothing to smooth against yet); every later call
	// applies the documented snap/smoothing rule above.
	void observe(Tick p_local_tick, Tick p_authoritative_tick);

	// Best current estimate of the authoritative tick "now" (at
	// `p_local_tick`), i.e. `p_local_tick + current_offset()`, floored at 0.
	// Returns `p_local_tick` unmodified (offset 0) before any sample has
	// ever been observed.
	Tick estimate(Tick p_local_tick) const;

	std::int64_t current_offset() const { return offset; }
	bool has_sample() const { return sampled; }

private:
	bool sampled = false;
	std::int64_t offset = 0; // authoritative - local, as of the last observed sample
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_RECONCILIATION_H
