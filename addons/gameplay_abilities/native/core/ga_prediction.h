#ifndef GAMEPLAY_ABILITIES_CORE_PREDICTION_H
#define GAMEPLAY_ABILITIES_CORE_PREDICTION_H

#include "core/ga_abilities.h"
#include "core/ga_ability_component.h"
#include "core/ga_effect_hooks.h"
#include "core/ga_effect_runtime.h"
#include "core/ga_effects.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_targeting.h"
#include "core/ga_tick.h"
#include "protocol/gap_event_stream.h"

#include <cstdint>
#include <functional>
#include <map>
#include <vector>

// Section 8, tasks 8.1-8.4: the v1 prediction-safe set and the local
// component that predicts exactly it. This file never edits
// `ga_ability_component.h`/.cpp -- every predicted mutation goes through the
// EXISTING public `AbilityComponent` API with `ChangeProvenance::PREDICTED`;
// this file only decides WHETHER/WHEN that call happens and journals what it
// did, matching the shared contract's "compose, do not edit" rule.
//
// This file (like ga_reconciliation.h) deliberately depends on
// `protocol/gap_event_stream.h` for `ga::proto::ClientEventStream`: the
// spec's "Restricted Owning-Client Prediction" requirement names the
// confirmed baseline as the single gate on prediction, and the shared
// contract is explicit that `ClientEventStream` is "the baseline authority
// -- do not track a second confirmed sequence." Every other `native/core/`
// file stays protocol-independent; this pair is the documented exception
// for exactly that seam.
namespace ga {

// ---------------------------------------------------------------------------
// Task 8.1 -- Restricted Owning-Client Prediction eligibility
// ---------------------------------------------------------------------------

// Standalone, reusable re-derivation of the "Prediction declaration is
// unsafe" rule `AbilityRegistry::register_ability` already enforces inline
// at registration time (see ga_abilities.h's own doc comment on
// `register_ability`). Exposed here as its own function, separate from the
// registry, so that:
//
//   (a) authoring-time validation can run it directly over a resolved
//       ability + the sealed effect registry it was built against --
//       this is the exact seam `native/godot/gameplay_definition_validator.h`
//       reserved and left unimplemented as
//       `GameplayDefinitionValidator::validate_prediction_eligibility_seam()`
//       (see that header's doc comment: "a real implementation needs
//       [ability/behavior-hook] shape to check that a prediction-safe-
//       declared effect/ability only uses the v1 prediction-safe operation
//       set"). A future ability-authoring validator resource wires THIS
//       function in at that seam once ability resources exist in
//       `native/resources/`; this file does not implement that Godot-layer
//       wiring itself (out of `native/core/`'s scope and off limits per the
//       shared contract -- `native/godot/` is concurrently owned).
//   (b) `PredictingComponent::request` (below) re-verifies eligibility at
//       REQUEST time as its own local, structural refusal gate: an ability
//       outside the v1 safe set is refused HERE, before ever calling into
//       `AbilityComponent::request_activation`, so nothing is predicted and
//       later rolled back -- see the "Predictable Dash is requested" /
//       "Remote poison application is requested" scenarios.
//
// Checks, in this order, failing closed on the first violation with
// `StatusCode::PREDICTION_NOT_SAFE` (diagnostic `HOOK_CAPABILITY_DENIED` for
// every capability-shaped violation, `detail` naming the offending
// `DefinitionId`; `DiagnosticId::NONE` / `detail == p_ability.id` for the
// bare "not opted in" case):
//
//   1. `p_ability.prediction_policy != PREDICTABLE` -- prediction is
//      opt-in; a structurally-safe-looking ability that never declared
//      itself predictable is still refused.
//   2. `p_ability.hook_binding == AUTHORITY_ONLY` -- an authority-only hook
//      (unrestricted server logic, may query scene/physics state, may use
//      randomness) may never run during predicted execution.
//   3. The declared self cost effect, self cooldown effect, and every
//      declared self commit effect (each resolved against `p_effects`)
//      must have `prediction_safe == true` and `has_period == false`. A
//      periodic outcome is never predictable. "Targets a remote entity"
//      cannot arise from this declarative shape at all: an ability's own
//      cost/cooldown/commit effects are ALWAYS applied source == target ==
//      the owner by `AbilityComponent::commit_execution_body` (design.md
//      "Ability Costs and Cooldowns as Effects") -- `AbilityDefinitionDesc`
//      has no field that could declare a targeted cost/cooldown/commit
//      effect, so this clause of the v1 safe set is a structural, not a
//      checked, guarantee here.
//   4. If any of those effects declares
//      `StackOverflowPolicy::APPLY_OVERFLOW_EFFECT`, its `overflow_effect`
//      must ALSO pass check 3 (bounded to exactly one level, matching
//      `EffectRuntime`'s own `apply_internal`'s
//      `p_allow_overflow_trigger = false` recursion guard on the overflow
//      application itself): the overflow effect can execute synchronously,
//      still tagged `ChangeProvenance::PREDICTED`, inside the very same
//      predicted `EffectRuntime::apply` call that stacked past capacity, so
//      an unsafe overflow effect would otherwise smuggle a periodic or
//      non-prediction-safe outcome into predicted execution undetected.
//   5. If `p_hook` is supplied (the concrete bound `PredictionSafeAbilityHook`
//      instance, when one has already been bound), also runs the EXISTING
//      `validate_prediction_safe_hook` (ga_ability_component.h) and
//      propagates its failure unchanged -- reused, never reimplemented.
//      `p_hook == nullptr` (the common case at authoring time, before any
//      hook instance exists) only validates the declarative half, exactly
//      the same limitation `AbilityRegistry::register_ability` already
//      documents for itself.
//
// Never mutates anything; pure validation over already-resolved,
// already-sealed content.
Status validate_prediction_eligibility(const AbilityDefinition &p_ability, const EffectRegistry &p_effects,
		const PredictionSafeAbilityHook *p_hook = nullptr);

// ---------------------------------------------------------------------------
// Task 8.2 -- Prediction journal: ordered predicted-safe operation record
// ---------------------------------------------------------------------------

// Which permitted v1 operation one journaled step represents. Mirrors the
// v1 prediction-safe set's own bullet list exactly -- there is no fifth
// kind, by construction (see `PredictingComponent::predict_full`, the only
// place that ever calls `record_op`).
enum class PredictedOpKind : std::uint8_t {
	ACTIVATION_BEGUN = 0, // the local execution transitioned through its declared activation phases
	SELF_COST_APPLIED = 1, // the declared self-target instant cost effect applied
	SELF_COOLDOWN_APPLIED = 2, // the declared self-target cooldown/owned-tag effect applied
	SELF_EFFECT_APPLIED = 3, // an explicitly prediction-safe self commit effect applied
	TASK_STARTED = 4, // a deterministic task created by this command's hook continuation
	TASK_INPUT_COMPLETED = 5, // a prediction-safe logical input advanced a task
	TARGET_INTENT_SUBMITTED = 6,
	TARGET_SESSION_COMPLETED = 7,
};

// One recorded prediction-safe operation, in the exact order it was applied
// locally. `temp_handle` is the LOCAL (client-issued) `EffectHandle` this
// operation produced, or `INVALID_EFFECT_HANDLE` for an operation that
// created no durable handle (activation-begin, an instant cost, or an
// instant self effect) -- durability, not operation kind, decides whether a
// handle exists, matching `EffectRuntime::apply`'s own INSTANT-vs-DURATION
// handle rule.
struct PredictedOp {
	PredictedOpKind kind = PredictedOpKind::ACTIVATION_BEGUN;
	DefinitionId effect_definition = INVALID_DEFINITION_ID; // INVALID for ACTIVATION_BEGUN
	EffectHandle temp_handle = INVALID_EFFECT_HANDLE;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	AbilityTaskKind task_kind = AbilityTaskKind::WAIT_TICKS;
};

enum class PredictionCommandKind : std::uint8_t {
	ACTIVATION = 0,
	TASK_INPUT = 1,
	TARGET_INTENT = 2,
};

// One predicted command's full local record: the command identity, the
// ability/spec it targeted, the local execution it produced (if any), and
// every prediction-safe operation applied for it, in order. Also retains
// the ORIGINAL (caller-supplied, pre-stamping) `ActivationRequest` so
// reconciliation (ga_reconciliation.h, task 8.6) can replay it later via
// `PredictingComponent::repredict` against restored state, PRESERVING this
// same entry's own `command_sequence`/`prediction_key` rather than
// allocating a fresh pair -- see `repredict`'s own doc comment for why a
// replayed command must keep its original identity (fix for
// "Reconciliation can execute a pending ability twice").
struct PendingPrediction {
	PredictionCommandKind command_kind = PredictionCommandKind::ACTIVATION;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId temp_execution = INVALID_EXECUTION_ID;
	Tick issued_tick = 0;
	ActivationRequest original_request; // provenance/command_sequence/prediction_key are sanitized to AUTHORITATIVE/INVALID here -- always re-stamped from THIS entry's own command_sequence/prediction_key (fresh or preserved, per the caller) at (re)predict time, never read back from this field.
	AbilityTaskLogicalInputCommand original_task_input;
	TargetSessionCommand original_target_command;
	std::vector<PredictedOp> ops; // <= MAX_PREDICTION_JOURNAL_OPS total across every pending entry combined
};

// Per-component, bounded, pure bookkeeping (task 8.2 / "Prediction Journal
// Bounds and Recovery"): monotonic `CommandSeq`/`PredictionKey` allocation,
// the ordered prediction-safe operations recorded per pending command, and
// the `MAX_PENDING_PREDICTIONS` / `MAX_PREDICTION_JOURNAL_OPS` /
// `MAX_PREDICTION_AGE_TICKS` bounds already defined in `ga_limits.h` --
// no second literal is introduced for any of the three. This class never
// calls into `AbilityComponent`, `EffectRuntime`, or anything else that
// mutates gameplay state; see `PredictingComponent` for the composing
// behavior that does.
class PredictionJournal {
public:
	// Allocates the next `CommandSeq`/`PredictionKey` pair and opens a new
	// pending entry for `p_ability`/`p_request`. Fails with
	// `StatusCode::PREDICTION_JOURNAL_FULL` (task 8.8's "Too many commands
	// remain pending") once `MAX_PENDING_PREDICTIONS` entries are already
	// outstanding -- the journal never grows past this bound; the caller
	// must fall back to server-confirmed mode or fail the request instead.
	// `r_entry` points into this journal's own live storage (stable across
	// further `begin()`/`record_op()` calls, invalidated only by `close()`/
	// `clear()`/`expire_older_than()` removing THAT entry).
	Status begin(Tick p_tick, DefinitionId p_ability, const ActivationRequest &p_request, PendingPrediction *&r_entry);

	// Identity-preserving sibling of `begin()`: opens a new pending entry for
	// `p_ability`/`p_request` under an ALREADY-ISSUED `p_command_sequence`/
	// `p_prediction_key` instead of minting fresh ones from
	// `sequence_allocator`/`key_allocator` -- neither allocator is touched,
	// so a later `begin()` still hands out strictly-increasing values with no
	// risk of ever colliding with an identity preserved here (a preserved
	// identity was, by construction, already consumed from these same
	// allocators when it was first issued, so it is always <= their current
	// `next`).
	//
	// This exists for exactly one caller: `PredictingComponent::repredict`,
	// replaying a still-pending journal entry across reconciliation. Per the
	// shared contract's "Reconciliation can execute a pending ability twice"
	// fix, a replayed command MUST keep its ORIGINAL `CommandSeq`/
	// `PredictionKey` -- allocating fresh ones (the old behavior) is exactly
	// what let a resent-but-already-executed command evade the server's
	// `ga::proto::CommandSequenceTracker` duplicate detection and re-execute.
	//
	// Fails with `StatusCode::PREDICTION_JOURNAL_FULL` at
	// `MAX_PENDING_PREDICTIONS`, same as `begin()`, or
	// `StatusCode::ALREADY_EXISTS` if `p_prediction_key` already names a
	// currently pending entry (defense in depth: `reconcile()`'s own call
	// discipline -- clear the whole journal, then repredict each still-
	// pending entry exactly once -- never actually produces this, but a
	// live journal slot must never be silently resurrected/overwritten under
	// an identity already in use).
	Status begin_with_identity(Tick p_tick, DefinitionId p_ability, const ActivationRequest &p_request,
			CommandSeq p_command_sequence, PredictionKey p_prediction_key, PendingPrediction *&r_entry);

	Status begin_task_input(Tick p_tick, DefinitionId p_ability,
			AbilitySpecId p_spec,
			const AbilityTaskLogicalInputCommand &p_command,
			PendingPrediction *&r_entry);
	Status begin_task_input_with_identity(Tick p_tick,
			DefinitionId p_ability, AbilitySpecId p_spec,
			const AbilityTaskLogicalInputCommand &p_command,
			CommandSeq p_command_sequence, PredictionKey p_prediction_key,
			PendingPrediction *&r_entry);
	Status begin_target_intent(Tick p_tick, DefinitionId p_ability,
			AbilitySpecId p_spec,
			const TargetSessionCommand &p_command,
			PendingPrediction *&r_entry);
	Status begin_target_intent_with_identity(Tick p_tick,
			DefinitionId p_ability, AbilitySpecId p_spec,
			const TargetSessionCommand &p_command,
			CommandSeq p_command_sequence,
			PredictionKey p_prediction_key,
			PendingPrediction *&r_entry);

	// Appends one more op to the pending entry named by `p_key`. Fails with
	// `StatusCode::PREDICTION_UNKNOWN_KEY` if `p_key` is not currently
	// pending, or `StatusCode::CAPACITY_EXCEEDED` past
	// `MAX_PREDICTION_JOURNAL_OPS` total ops journaled across EVERY
	// currently pending command combined.
	Status record_op(PredictionKey p_key, const PredictedOp &p_op);

	// Records the local `ExecutionId` a successful predicted
	// `request_activation` produced. A no-op if `p_key` is not pending.
	void set_execution(PredictionKey p_key, ExecutionId p_execution);

	bool has_pending(PredictionKey p_key) const;
	const PendingPrediction *find_pending(PredictionKey p_key) const;
	const PendingPrediction *find_pending_by_sequence(CommandSeq p_sequence) const;

	// Every still-pending entry, ascending `command_sequence` -- the
	// original-order replay rule task 8.6 requires.
	std::vector<PendingPrediction> pending_in_order() const;
	std::size_t pending_count() const { return pending.size(); }
	std::size_t total_op_count() const { return op_count; }

	// Removes and returns the entry named by `p_key`.
	// `StatusCode::PREDICTION_UNKNOWN_KEY` (never mutates anything) if
	// `p_key` is not currently pending -- covers task 8.5's "acknowledgement
	// whose identity is unknown or stale (e.g. referencing a journal
	// discarded by a newer snapshot)."
	Status close(PredictionKey p_key, PendingPrediction &r_entry);

	// Removes and returns every pending entry whose `issued_tick` is more
	// than `MAX_PREDICTION_AGE_TICKS` behind `p_now`, ascending
	// `command_sequence`. Bound-exceeding age is one of task 8.8's trigger
	// conditions; see `PredictingComponent::sweep_expired`, which treats a
	// non-empty result as a full bound violation (disable + clear
	// everything), not just the aged entries.
	std::vector<PendingPrediction> expire_older_than(Tick p_now);

	// Clears every pending entry (task 8.8's "clear temporary state
	// safely"). Returns everything that was pending, ascending
	// `command_sequence`, so the caller can still account for/cancel each
	// one. Never fails.
	std::vector<PendingPrediction> clear();

	// Task 8.12 fix ("reconnect STALE_COMMAND" defect, tasks.md 8.12): raises
	// `sequence_allocator`'s counter so the NEXT `begin()` allocates a
	// `CommandSeq` strictly greater than `p_at_least` -- idempotent (a no-op
	// if the allocator is already at or past this value) and ONLY EVER
	// RAISES, never rewinds.
	//
	// WHY this exists: a fresh `PredictingComponent` (and therefore a fresh
	// `sequence_allocator`) is constructed for EVERY `ROLE_NETWORK_CLIENT`
	// component (`GameplayAbilityComponent::configure()`), including one
	// rebuilt after a reconnect. That fresh allocator starts counting
	// `CommandSeq` from 1 regardless of what the RESTORED snapshot's grants
	// say -- but `AbilityGrant::last_command_sequence` (the same field
	// `AbilityComponent::request_activation`'s staleness check reads,
	// ga_ability_component.cpp) is part of that snapshot and reflects
	// whatever this entity's authoritative grant last accepted, possibly long
	// before this reconnect. Without seeding, the first fresh prediction's
	// `CommandSeq` (1) is almost always `<= grant.last_command_sequence`, so
	// `request_activation`'s own staleness check
	// (`command_sequence <= grant.last_command_sequence` ->
	// `STALE_COMMAND`) rejects it locally, deterministically, for every grant
	// this client used before disconnecting. Calling this once per restored
	// grant (see `PredictingComponent::seed_from_owning_component`, the
	// actual caller) closes that gap.
	//
	// WHY only ever raise, never rewind: rewinding `sequence_allocator`
	// backward would let a FUTURE `begin()` re-mint a `CommandSeq` value this
	// component (or an earlier incarnation of it, across the SAME session)
	// already issued -- indistinguishable, to both this journal's own
	// `find_pending_by_sequence` and the server's
	// `ga::proto::CommandSequenceTracker`, from the ORIGINAL command that
	// value named. That is exactly the collision the Phase-1 identity-
	// preservation fix (`begin_with_identity`, this file's own header
	// comment above) was written to prevent for a REPLAYED command's
	// preserved identity -- a rewound allocator would reopen the same class
	// of bug for a freshly-allocated one instead. A restored snapshot's
	// `last_command_sequence` can only ever be less than or equal to what
	// THIS session has already locally issued (the confirmed baseline is
	// always at least as old as anything still pending, and this method is
	// only ever called with a value read from that same restored snapshot --
	// see `seed_from_owning_component`), so in practice this never NEEDS to
	// rewind; the guard exists to fail closed (silently no-op, per
	// `HandleAllocator::restore_from`) rather than trust that invariant
	// blindly.
	void ensure_sequence_above(CommandSeq p_at_least);

private:
	std::map<std::uint64_t, PendingPrediction> pending; // keyed by raw PredictionKey value -- ascending key == ascending allocation order == ascending command_sequence.
	HandleAllocator<CommandSeq> sequence_allocator;
	HandleAllocator<PredictionKey> key_allocator;
	std::size_t op_count = 0;
};

// ---------------------------------------------------------------------------
// Task 8.7 (declared here, used by both this file and ga_reconciliation.h)
// -- Prediction-aware presentation events, reusing the EXISTING `CuePhase`
// and `CueDedupId` rather than a parallel enum/identity.
// ---------------------------------------------------------------------------

// One presentation-facing notification a predicted command's lifecycle
// produces. `dedup` and `phase` deliberately reuse `ga::CueDedupId`/
// `ga::CuePhase` (ga_effect_runtime.h) unchanged. Scoped per COMMAND (not
// per underlying effect): `dedup.handle` is always `INVALID_EFFECT_HANDLE`
// and `dedup.occurrence` is the command's own `PredictionKey` raw value, so
// a PREDICT/CONFIRM/CORRECT/CANCEL quadruple for the SAME predicted command
// always carries the identical `dedup` an adapter matches on.
struct PredictionPresentationEvent {
	CueDedupId dedup;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY; // INVALID_PREDICTION_KEY for a presentation-only anticipation cue (task 8.4)
	CuePhase phase = CuePhase::PREDICT;
	DefinitionId ability = INVALID_DEFINITION_ID;
	EntityId target = INVALID_ENTITY_ID;
	Tick tick = 0;
};

using PredictionPresentationListener = std::function<void(const PredictionPresentationEvent &)>;

// ---------------------------------------------------------------------------
// Tasks 8.3 / 8.4 -- predicting only the permitted operation set
// ---------------------------------------------------------------------------

// Every distinct outcome `PredictingComponent::request` can produce. Exactly
// one of these per call -- never a mix.
enum class PredictionMode : std::uint8_t {
	// Baseline unavailable (replication gap / unresolved manifest / no
	// confirmed snapshot -- the "Baseline is missing" scenario): prediction
	// is disabled for this component; the request must use server-confirmed
	// behavior. Nothing local happened; `status` is `ok_status()` (this is
	// not a rejection, just "not predicted").
	NOT_PREDICTED_NO_BASELINE = 0,
	// The referenced spec/ability could not be resolved locally at all
	// (unknown grant or unknown ability id) -- treated the same as "cannot
	// predict this," falling back to server-confirmed behavior.
	NOT_PREDICTED_UNKNOWN_ABILITY = 1,
	// `MAX_PENDING_PREDICTIONS` already reached (task 8.8's "Too many
	// commands remain pending"): falls back to server-confirmed behavior
	// rather than growing the journal.
	NOT_PREDICTED_JOURNAL_FULL = 2,
	// The ability is not declared `PREDICTABLE`, or fails
	// `validate_prediction_eligibility`: the gameplay MUTATION is refused
	// locally (status == PREDICTION_NOT_SAFE) -- `AbilityComponent::
	// request_activation` is never called, so nothing is predicted and
	// later rolled back. `anticipation_dedup` is populated so the caller
	// MAY (per the "Remote poison application is requested" scenario --
	// this is optional, presentation-only, and carries no gameplay state)
	// play a local anticipation cue; the real effect/periodic gameplay stay
	// entirely server-authoritative.
	PRESENTATION_ONLY = 3,
	// Full local prediction ran: `AbilityComponent::request_activation`
	// executed with `ChangeProvenance::PREDICTED`, exactly the permitted
	// operation set was applied and journaled, and a command
	// sequence/prediction key were assigned. `status` carries whatever the
	// real activation itself returned (OK on success; a structured
	// activation failure -- e.g. locally-stale cost/cooldown/tag state --
	// otherwise, in which case nothing was journaled as pending, matching
	// `request_activation`'s own all-or-nothing commit).
	PREDICTED = 4,
};

struct PredictionOutcome {
	PredictionMode mode = PredictionMode::NOT_PREDICTED_NO_BASELINE;
	Status status;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	ExecutionId execution = INVALID_EXECUTION_ID; // meaningful only for PREDICTED
	CueDedupId anticipation_dedup; // meaningful only for PRESENTATION_ONLY
};

struct TaskPredictionOutcome {
	PredictionMode mode = PredictionMode::NOT_PREDICTED_NO_BASELINE;
	Status status;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	ExecutionId execution = INVALID_EXECUTION_ID;
	bool transitioned = false;
};

struct TargetPredictionOutcome {
	PredictionMode mode =
			PredictionMode::NOT_PREDICTED_NO_BASELINE;
	Status status;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	TargetSessionId session = INVALID_TARGET_SESSION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	bool transitioned = false;
	bool terminal = false;
	std::uint64_t canonical_intent_hash = 0;
};

// Composes over an existing `AbilityComponent` (role MUST already be
// `ComponentRole::NETWORK_CLIENT` -- this class never changes a component's
// role) to predict only the v1 prediction-safe operation set locally while
// a caller (the network bridge, entirely out of this file's scope) sends
// intent to authority. Never modifies `ga_ability_component.h`/.cpp: every
// predicted mutation goes through the component's EXISTING public API with
// `ChangeProvenance::PREDICTED`; this class only decides WHETHER to call it
// and journals what happened.
class PredictingComponent {
public:
	PredictingComponent(AbilityComponent &p_component, const AbilityRegistry &p_abilities, const EffectRegistry &p_effects) :
			owning_component(&p_component), abilities(&p_abilities), effects(&p_effects) {}

	// True only when this component has not been despawned, is not
	// currently disabled pending recovery (task 8.8), AND `p_stream.state()
	// == ga::proto::ClientStreamState::SYNCED` -- `ClientEventStream` is the
	// single baseline authority (see file comment); this class never tracks
	// a second confirmed sequence of its own.
	bool prediction_available(const proto::ClientEventStream &p_stream) const;

	// The local request entry point (tasks 8.3/8.4). See `PredictionMode`
	// for the four possible outcomes. A `PREDICTED` outcome only ever
	// applies, in order: activation-phase transition, the declared self
	// cost, the declared self cooldown/owned-tag effect, and declared self
	// commit effects that are each individually prediction-safe -- exactly
	// the operations `AbilityComponent::commit_execution_body` already
	// performs atomically for ANY activation; this method changes WHETHER/
	// WHEN that call happens, never what it does.
	PredictionOutcome request(const ActivationRequest &p_request, Tick p_tick, const proto::ClientEventStream &p_stream);

	// The reconciliation-replay entry point (`ga_reconciliation.h`'s
	// `PredictionReconciler::reconcile` is the only intended caller): re-runs
	// `p_old`'s original request against this component's just-restored
	// confirmed baseline, exactly like `request(p_old.original_request, ...)`
	// would (same baseline-availability check, same grant/ability
	// resolution, same `validate_prediction_eligibility` re-check -- nothing
	// about WHETHER/WHAT is predicted changes), EXCEPT the resulting journal
	// entry (when a `PREDICTED` outcome is reached) keeps `p_old`'s own
	// `command_sequence`/`prediction_key` instead of allocating fresh ones.
	//
	// WHY: the caller (the network bridge's `reconcile_and_resend`) resends
	// a `PREDICTED` replay outcome to the server using `outcome.
	// command_sequence`/`outcome.prediction_key`. If those were freshly
	// allocated (the pre-fix behavior), a command the server had ALREADY
	// executed under its original identity (its acknowledgement simply not
	// yet received when reconciliation ran) would arrive again under a
	// brand-new sequence number the server's `ga::proto::
	// CommandSequenceTracker` has never seen -- indistinguishable from a
	// genuinely new command, so it would execute a second time. Preserving
	// identity instead means the resend is recognized as an EXACT DUPLICATE
	// (idempotent replay of the already-decided result, no re-mutation), and
	// a late-arriving ack for the original command still finds this
	// re-created journal entry by the SAME preserved key. See
	// `ga_reconciliation.cpp`'s `reconcile()` for the invariant that makes
	// replaying the preserved sequence against the restored baseline safe
	// (it re-checks `AbilityComponent::request_activation_immediate`'s own
	// per-grant staleness gate exactly as any activation would).
	PredictionOutcome repredict(const PendingPrediction &p_old, Tick p_tick, const proto::ClientEventStream &p_stream);

	// Predicts one logical input as its own journaled command. The referenced
	// task must be active, owned by this component, and explicitly
	// PREDICTION_SAFE. The caller sends the returned sequence/key in the task
	// DTO; reconciliation replays this value command, never a physical
	// InputEvent or callback.
	TaskPredictionOutcome predict_task_input(
			const AbilityTaskLogicalInputCommand &p_command, Tick p_tick,
			const proto::ClientEventStream &p_stream);
	TargetPredictionOutcome predict_target_intent(
			GameplayAbilityWorldCoordinator &p_coordinator,
			const TargetSessionCommand &p_command, Tick p_tick,
			const proto::ClientEventStream &p_stream);
	TargetPredictionOutcome repredict_target_intent(
			GameplayAbilityWorldCoordinator &p_coordinator,
			const PendingPrediction &p_old, Tick p_tick,
			const proto::ClientEventStream &p_stream);

	PredictionJournal &journal() { return prediction_journal; }
	const PredictionJournal &journal() const { return prediction_journal; }

	AbilityComponent &component() { return *owning_component; }
	const AbilityComponent &component() const { return *owning_component; }

	// Task 8.12 fix ("reconnect STALE_COMMAND" defect): scans EVERY grant
	// currently on `owning_component()` (see `AbilityComponent::granted_specs`/
	// `find_grant`) for the maximum `AbilityGrant::last_command_sequence`,
	// then calls `journal().ensure_sequence_above(...)` with it -- a no-op if
	// no grant has a non-zero `last_command_sequence` yet (a brand-new
	// component, nothing to seed from). See `PredictionJournal::
	// ensure_sequence_above`'s own doc comment for the full "why" and why
	// this only ever raises the allocator, never rewinds it.
	//
	// Callers (both on the Godot bridge layer, native/godot/
	// gameplay_ability_component.cpp -- NOT this file, which stays engine-
	// independent per the shared contract): every point a
	// ROLE_NETWORK_CLIENT component adopts a CONFIRMED baseline for the
	// first time after (re)constructing its `PredictingComponent`, i.e. right
	// after a successful `GameplayAbilityComponent::restore_snapshot()` and
	// right after `GameplayAbilityComponent::reconcile_snapshot()` reaches
	// `ReconciliationOutcomeKind::REPLAYED` -- both seams the Phase-2
	// prediction-lifecycle wiring already created (`apply_confirmed_payload`/
	// `reconcile_snapshot`). Calling this on EVERY such adoption (not just
	// once after a reconnect specifically) is deliberately cheap and
	// idempotent -- see `ensure_sequence_above` -- so no separate
	// "is this a reconnect" detection is needed anywhere.
	//
	// WHY `key_allocator` (PredictionKey) is deliberately NOT seeded here,
	// unlike `sequence_allocator`: `AbilityGrant::last_command_sequence` is
	// PERSISTENT authoritative state -- part of the canonical component
	// snapshot, restored across a reconnect onto whatever fresh component the
	// bridge builds. `PredictionKey` uniqueness, in contrast, is enforced by
	// `ga::proto::CommandSequenceTracker::claim_prediction_key`
	// (gap_command_gate.h) SCOPED PER SESSION (`prediction_states` is keyed
	// by `SessionId` alone, never by component or a persistent identity), and
	// a reconnect always establishes a brand-new session (this bridge's
	// `SessionId` defaults to the ENet peer id, which a fresh connection
	// never reuses -- see gameplay_ability_network_bridge.cpp's own file
	// comment). The OLD session's claimed keys therefore live in a
	// DIFFERENT, now-orphaned map entry the new session's `PredictionState`
	// never consults; reusing PredictionKey values a prior session already
	// claimed cannot collide with anything under the NEW session, and this
	// component's own journal is freshly constructed (never restored from
	// the snapshot -- it is pure client-side, ephemeral bookkeeping, see
	// this file's own class comment), so there is no live pending entry a
	// freshly-issued key could collide with via `begin_with_identity`'s
	// ALREADY_EXISTS guard either. Seeding `key_allocator` would therefore be
	// pure ceremony with no bug to close.
	void seed_from_owning_component();

	void add_presentation_listener(PredictionPresentationListener p_listener);

	// Dispatches `p_event` to every registered presentation listener,
	// synchronously, in registration order. Public so `ga_reconciliation.h`'s
	// `PredictionReconciler` (a separate collaborator, not a subclass) can
	// emit the CONFIRM/CORRECT/CANCEL phases this same predicted command's
	// PREDICT phase was emitted through, via the identical dispatch point --
	// there is exactly one presentation-listener registry per component,
	// never two.
	void emit_presentation(const PredictionPresentationEvent &p_event);

	// ---------------------------------------------------------------
	// Task 8.8 -- bounds/recovery hooks. Every one of these clears the
	// journal's pending state (never the component's already-committed
	// state -- restoring THAT is `ga_reconciliation.h`'s `reconcile`, once a
	// fresh snapshot is available) and disables prediction until the caller
	// calls `resume_after_recovery` with a freshly re-synced baseline.
	// Each dropped pending entry gets exactly one `CuePhase::CANCEL`
	// presentation event.
	// ---------------------------------------------------------------
	std::vector<PendingPrediction> on_baseline_lost();
	std::vector<PendingPrediction> on_disconnected();
	std::vector<PendingPrediction> on_manifest_changed();
	// Permanent: `prediction_available` never returns true again for this
	// component afterward, regardless of `resume_after_recovery` -- "late
	// acknowledgements cannot recreate the component."
	std::vector<PendingPrediction> on_despawned();

	// Sweeps `MAX_PREDICTION_AGE_TICKS`-abandoned entries as of `p_now`. If
	// any existed, this is treated as a full bound violation (matching
	// `MAX_PENDING_PREDICTIONS`/`MAX_PREDICTION_JOURNAL_OPS` overflow): the
	// ENTIRE journal is disabled and cleared, not just the aged entries, so
	// a stale command can never be replayed against since-diverged local
	// state. Returns every entry dropped as a result (aged or not).
	std::vector<PendingPrediction> sweep_expired(Tick p_now);

	// Re-enables prediction after `on_baseline_lost`/`on_disconnected`/
	// `on_manifest_changed`/`sweep_expired` disabled it, once the caller has
	// re-established a confirmed baseline (fresh snapshot applied,
	// `p_stream` back to SYNCED). A no-op (prediction stays permanently
	// disabled) if this component was despawned.
	void resume_after_recovery();

	bool is_despawned() const { return despawned; }
	bool is_disabled_pending_recovery() const { return prediction_disabled; }

	// Public (not just the `on_*` wrappers above) so a collaborator that is
	// NOT one of this class's own recovery hooks -- specifically
	// `ga_reconciliation.h`'s `PredictionReconciler::reconcile`, on its own
	// `COMPONENT_MUST_BE_REBUILT` restore-failure leg -- can drop every
	// pending entry WITH the same cancellation-cue/disable guarantee instead
	// of reaching past it into `journal().clear()` (which drops entries with
	// NO cues and leaves prediction enabled against a component whose
	// restore just failed). See that call site's own doc comment for why a
	// restore failure must disable prediction, not just clear its
	// bookkeeping.
	std::vector<PendingPrediction> disable_and_clear();

private:
	// Shared grant -> ability -> eligibility resolution for `request()`'s
	// fresh path and `repredict()`'s replay path -- both need the IDENTICAL
	// resolution (only how the eventual `PREDICTED` outcome's identity is
	// obtained differs). Returns the resolved `AbilityDefinition` on success
	// (`r_outcome` untouched); on any resolution/eligibility failure, returns
	// `nullptr` with `r_outcome` already fully populated (NOT_PREDICTED_
	// UNKNOWN_ABILITY or PRESENTATION_ONLY, including the anticipation
	// presentation event for the latter) so the caller can return it as-is.
	const AbilityDefinition *resolve_for_prediction(const ActivationRequest &p_request, Tick p_tick, PredictionOutcome &r_outcome);

	// `p_preserve_sequence`/`p_preserve_key` both valid (non-INVALID_*) means
	// "this is a reconciliation replay -- open the journal entry via
	// `PredictionJournal::begin_with_identity` under these preserved values";
	// otherwise (the fresh-request path) opens it via `PredictionJournal::
	// begin`, allocating new ones as always. Everything else about applying
	// the v1 prediction-safe operation set is identical either way.
	PredictionOutcome predict_full(const ActivationRequest &p_request, Tick p_tick, const AbilityDefinition &p_ability,
			CommandSeq p_preserve_sequence = INVALID_COMMAND_SEQ, PredictionKey p_preserve_key = INVALID_PREDICTION_KEY);
	TaskPredictionOutcome predict_task_input_full(
			const AbilityTaskLogicalInputCommand &p_command, Tick p_tick,
			DefinitionId p_ability, AbilitySpecId p_spec,
			CommandSeq p_preserve_sequence = INVALID_COMMAND_SEQ,
			PredictionKey p_preserve_key = INVALID_PREDICTION_KEY);
	TargetPredictionOutcome predict_target_intent_full(
			GameplayAbilityWorldCoordinator &p_coordinator,
			const TargetSessionCommand &p_command, Tick p_tick,
			DefinitionId p_ability, AbilitySpecId p_spec,
			CommandSeq p_preserve_sequence = INVALID_COMMAND_SEQ,
			PredictionKey p_preserve_key =
					INVALID_PREDICTION_KEY);
	void record_execution_tasks(PredictionKey p_key,
			ExecutionId p_execution,
			const std::vector<AbilityTaskHandle> &p_before = {});

	AbilityComponent *owning_component;
	const AbilityRegistry *abilities;
	const EffectRegistry *effects;
	PredictionJournal prediction_journal;
	std::vector<PredictionPresentationListener> presentation_listeners;
	bool despawned = false;
	bool prediction_disabled = false;
	std::uint64_t anticipation_counter = 0; // dedup occurrence source for PRESENTATION_ONLY (no PredictionKey exists for those)
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_PREDICTION_H
