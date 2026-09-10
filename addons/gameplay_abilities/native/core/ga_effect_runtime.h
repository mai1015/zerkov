#ifndef GAMEPLAY_ABILITIES_CORE_EFFECT_RUNTIME_H
#define GAMEPLAY_ABILITIES_CORE_EFFECT_RUNTIME_H

#include "core/ga_attribute_state.h"
#include "core/ga_effect_hooks.h"
#include "core/ga_effect_spec.h"
#include "core/ga_effects.h"
#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_tag_container.h"
#include "core/ga_tick.h"
#include "core/ga_transaction.h"

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

// The gameplay-effect runtime (tasks 5.2, 5.3, 5.5, 5.6, 5.8): one
// `EffectRuntime` per component/entity, owning that entity's active-effect
// records and driving their application, stacking, scheduling, and removal
// against that SAME entity's `AttributeSet`/`TagContainer`. Designed to be
// owned later by `GameplayAbilityComponent` (section 6), which resolves
// `EntityId` -> concrete component and hands this runtime the concrete
// `AttributeSet&`/`TagContainer&` references it needs.
//
// -----------------------------------------------------------------------
// Composing with `TagContainer`'s transaction participation
// -----------------------------------------------------------------------
// `TagContainer::apply_mutations` (like `AttributeSet::add_modifier`,
// `remove_modifier`, ...) participates in a CALLER-SUPPLIED `Transaction&`:
// it mutates optimistically and registers its own undo onto that SAME
// transaction, so the caller's `TransactionScope` rolls it back along with
// every other subsystem's changes if anything later fails. Every mutating
// method below passes its own `p_txn` straight through to
// `tags->apply_mutations`, so there is no ordering requirement left to
// maintain: a tag batch failing, or ANY other step in the same transaction
// failing after a tag batch already applied, undoes the WHOLE transaction --
// including that tag batch -- exactly like an attribute modifier would.
//
// This also closes what used to be a narrow, explicitly accepted residual
// gap here: `advance_to` may process several due effects inside ONE caller
// transaction, and previously, if effect #1's tag removal succeeded and
// effect #3's tag removal then failed, effect #1's tag removal could not be
// rolled back (only the attribute/bookkeeping side could be), because
// `TagContainer::apply_mutations` used to commit its own internal
// transaction eagerly. Now that it registers undo on the SAME `p_txn`
// `advance_to` is already using, failing the shared transaction rolls back
// every effect's tag removal processed by that call, not just the one that
// failed.
namespace ga {

// ---------------------------------------------------------------------------
// Active effect
// ---------------------------------------------------------------------------

// One applied duration/infinite effect instance. INSTANT effects never
// produce one of these (see `EffectRuntime::apply`).
struct ActiveEffect {
	EffectHandle handle = INVALID_EFFECT_HANDLE;
	DefinitionId definition = INVALID_DEFINITION_ID;
	EntityId source = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;

	std::uint32_t stack_count = 1;

	Tick start_tick = 0;
	Tick end_tick = INVALID_TICK; // exclusive; INVALID_TICK == never expires on its own
	bool has_period = false;
	Tick next_period_tick = INVALID_TICK;

	// One resolved magnitude per declared modifier (index == declaration
	// index), captured ONCE when this instance was first created (or last
	// REPLACEd) from the stable transaction snapshot. Every additional stack
	// of this SAME instance reuses these values rather than re-resolving --
	// see design note on `EffectRuntime::apply`.
	std::vector<Fixed> resolved_magnitudes;

	// This instance's OWN source token for its granted tags (see
	// ga_tag_container.h: ownership is per-SourceToken, so two active
	// effects granting the same tag do not remove each other's grant).
	SourceToken tag_source = INVALID_SOURCE_TOKEN;

	// Persistent (non-periodic) modifier handles, indexed
	// [declaration_index][stack unit]. Empty for a periodic effect (periodic
	// modifiers execute as instant deltas -- see `advance_to` -- and are
	// never added to `AttributeSet` persistently).
	std::vector<std::vector<ModifierHandle>> modifier_handles;

	std::uint64_t context_tag = 0; // carried from the originating EffectSpec
	TargetEffectContext target_context;

	std::uint64_t revision = 0;
};

struct EffectRuntimeAllocatorState {
	std::uint64_t effect_handle_next = 0;
	std::uint64_t tag_source_next = 0;
	std::uint64_t event_next = 0;
	std::uint64_t occurrence = 0;
};

class EffectRuntime;

// An authority-prepared, immutable effect application. The resolved
// magnitudes are intentionally private: only the EffectRuntime that created
// this value can consume it, so callers cannot replace preflight output or
// manufacture a "prepared" application. Cross-component target batches use
// this to freeze every source/target attribute-derived magnitude before any
// participant is mutated.
class PreparedEffectApplication {
public:
	bool valid() const { return prepared_by != nullptr; }

private:
	friend class EffectRuntime;

	const EffectRuntime *prepared_by = nullptr;
	EffectSpec spec;
	std::vector<Fixed> resolved_magnitudes;
	// Present only when the prepared stack state would trigger an overflow
	// effect. Its magnitudes are resolved during the same read-only
	// preparation pass. If commit reaches an overflow that preparation did
	// not observe, the prepared path fails and the enclosing world batch
	// rolls back instead of reading live attributes mid-commit.
	bool has_prepared_overflow = false;
	std::vector<Fixed> overflow_resolved_magnitudes;
};

// ---------------------------------------------------------------------------
// Lifecycle events
// ---------------------------------------------------------------------------

enum class EffectLifecycleKind : std::uint8_t {
	APPLIED = 0,
	STACK_CHANGED = 1,
	PERIODIC_EXECUTED = 2,
	REMOVED = 3,
	EXPIRED = 4,
};

enum class EffectRemovalReason : std::uint8_t {
	NONE = 0,
	EXPLICIT_REMOVAL = 1,
	EXPIRED = 2,
	REPLACED_BY_STACK_POLICY = 3,
};

// Immutable, stable-identity record of one committed effect lifecycle
// change. Captured BY VALUE into a `Transaction` notification closure, like
// every other change record in this addon.
struct EffectLifecycleEvent {
	GameplayEventId id = INVALID_GAMEPLAY_EVENT_ID;
	EffectLifecycleKind kind = EffectLifecycleKind::APPLIED;
	DefinitionId definition = INVALID_DEFINITION_ID;
	EffectHandle handle = INVALID_EFFECT_HANDLE;
	EntityId source = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	std::uint32_t stack_count_after = 0;
	Tick tick = 0;
	TransactionId transaction = INVALID_TRANSACTION_ID;
	EffectRemovalReason removal_reason = EffectRemovalReason::NONE;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;

	// Set only when an `AuthorityCalculationHook` ran for this application
	// (see `ga_effect_hooks.h`) -- its resolved result is recorded here so it
	// replicates instead of being recomputed on a client.
	bool has_hook_result = false;
	Fixed hook_result = Fixed::zero();
	TargetEffectContext target_context;
};

// ---------------------------------------------------------------------------
// Cue events (presentation-facing, logical -- never gameplay-authoritative)
// ---------------------------------------------------------------------------

enum class CuePhase : std::uint8_t {
	PREDICT = 0,
	CONFIRM = 1,
	CORRECT = 2,
	CANCEL = 3,
	AUTHORITY_ONLY = 4,
	SNAPSHOT_RESTORED = 5,
};

// Stable identity a presentation adapter dedupes AUTHORITATIVE occurrences
// by (e.g. a resync re-delivering the same event). `occurrence` disambiguates
// repeated firings (stack changes, periodic executions) of the SAME handle.
// This is deliberately separate from `EffectCueEvent::prediction_key`, which
// is the mechanism a presentation adapter uses to match a PREDICT phase to
// its later CONFIRM/CORRECT/CANCEL -- a predicted application has no
// authoritative `EffectHandle` yet, so dedup-by-handle cannot serve both
// purposes at once.
struct CueDedupId {
	EntityId target = INVALID_ENTITY_ID;
	DefinitionId definition = INVALID_DEFINITION_ID;
	EffectHandle handle = INVALID_EFFECT_HANDLE;
	std::uint64_t occurrence = 0;

	bool operator==(const CueDedupId &p_other) const {
		return target == p_other.target && definition == p_other.definition &&
				handle == p_other.handle && occurrence == p_other.occurrence;
	}
};

struct EffectCueEvent {
	GameplayEventId id = INVALID_GAMEPLAY_EVENT_ID;
	CueDedupId dedup;
	// Set (non-INVALID) only when this cue traces back to a client's
	// predicted command; see file comment on `CueDedupId`.
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	CuePhase phase = CuePhase::AUTHORITY_ONLY;
	DefinitionId definition = INVALID_DEFINITION_ID;
	EffectHandle handle = INVALID_EFFECT_HANDLE;
	EntityId source = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	Tick tick = 0;
	std::vector<std::string> cue_identifiers; // copied from the definition at commit time
	TargetEffectContext target_context;
};

using EffectLifecycleListener = std::function<void(const EffectLifecycleEvent &, NotificationQueue &)>;
using EffectCueListener = std::function<void(const EffectCueEvent &, NotificationQueue &)>;

// Snapshot section kinds this file writes/reads (scoped to this file only --
// see ga_snapshot.h).
constexpr std::uint8_t GA_SNAPSHOT_KIND_EFFECT_RUNTIME = 10;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ACTIVE_EFFECT = 11;

class EffectRuntime {
public:
	// `p_owner` is the entity this runtime's active effects always target;
	// `p_attributes`/`p_tags` are that SAME entity's attribute/tag state.
	// Both are non-owning references that must outlive this `EffectRuntime`.
	EffectRuntime(const EffectRegistry &p_registry, EntityId p_owner, AttributeSet &p_attributes, TagContainer &p_tags) :
			registry(&p_registry), owner(p_owner), attributes(&p_attributes), tags(&p_tags) {}

	// ---------------------------------------------------------------
	// Application
	// ---------------------------------------------------------------

	// Applies `p_spec` (`p_spec.target` MUST equal this runtime's owner).
	// `p_source_attributes`/`p_source_tags` are read-only access to the
	// SOURCE entity's state (pass the same objects as this runtime's own for
	// a self-effect; pass `nullptr` for a source-less/system-applied effect,
	// in which case only a trivial -- always-true -- source requirement
	// query and a magnitude source that never reads a source attribute may
	// succeed). `p_hook`, if non-null, is invoked once, before any mutation,
	// with a read-only `CalculationContext` built from the SAME stable
	// snapshot magnitude resolution uses; its resolved value is recorded on
	// the `APPLIED`/`STACK_CHANGED` lifecycle event. `p_prediction_key`, if
	// not `INVALID_PREDICTION_KEY`, marks the resulting cue event as tracing
	// back to that client prediction (see `EffectCueEvent`).
	//
	// Evaluates immunity BEFORE anything else that could allocate a handle,
	// modifier, tag, or schedule: an immune application fails with
	// `StatusCode::EFFECT_IMMUNE` and creates NOTHING (see class file
	// comment on ordering/atomicity for why tags are always applied last on
	// the SUCCESS path, which is orthogonal to this early-exit check).
	//
	// INSTANT effects mutate `attributes`' base atomically (one call per
	// declared modifier, via `AttributeSet::set_base`) and leave NO active
	// instance; `r_handle` is set to `INVALID_EFFECT_HANDLE`.
	// DURATION/INFINITE effects receive a fresh (or, for a stacking REPLACE,
	// reused) authority-issued `r_handle`.
	//
	// Fails, before any mutation, with:
	//   - `StatusCode::UNKNOWN_EFFECT` if `p_spec.definition` is unregistered.
	//   - `validate_effect_spec`'s own `Status` (UNDECLARED/MISSING set-by-
	//     caller, capacity).
	//   - `StatusCode::INVALID_ARGUMENT` if `p_spec.target != owner`.
	//   - `StatusCode::EFFECT_REQUIREMENTS_FAILED` if source/target
	//     requirements are not satisfied.
	//   - `StatusCode::EFFECT_IMMUNE` if the immunity query is satisfied.
	//   - `StatusCode::UNKNOWN_ATTRIBUTE` if a magnitude source's referenced
	//     attribute is not initialized on the relevant entity.
	//   - `StatusCode::HOOK_FAILED` if `p_hook` returns a non-OK `Status`.
	//   - `StatusCode::EFFECT_STACK_REJECTED` if at max stacks under the
	//     REJECT overflow policy.
	//   - `StatusCode::CAPACITY_EXCEEDED` / `DiagnosticId::BYTE_LIMIT_EXCEEDED`
	//     if `p_spec.definition` retains its target context
	//     (`retain_target_context`) and doing so would push this runtime's
	//     `retained_target_context_bytes()` past
	//     `MAX_RETAINED_TARGET_CONTEXT_BYTES` (ga_limits.h) -- checked before
	//     any mutation, exactly like the checks above.
	//   - any `AttributeSet::add_modifier`/`TagContainer::apply_mutations`
	//     failure (arithmetic overflow, capacity) -- rolls back completely.
	Status apply(const EffectSpec &p_spec, Tick p_tick,
			const AttributeSet *p_source_attributes, const TagContainer *p_source_tags,
			Transaction &p_txn, NotificationQueue &p_queue, EffectHandle &r_handle,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE,
			PredictionKey p_prediction_key = INVALID_PREDICTION_KEY,
			AuthorityCalculationHook *p_hook = nullptr);

	// Produces an unforgeable application plan after running the complete
	// read-only preflight chain and resolving every modifier magnitude. The
	// returned value owns copies of the normalized spec and fixed-point
	// magnitudes and is valid only for this EffectRuntime.
	//
	// Also preflights the retained-context byte budget (see `apply`'s own
	// doc comment above): a plan that would push
	// `retained_target_context_bytes()` past
	// `MAX_RETAINED_TARGET_CONTEXT_BYTES` fails here,
	// `StatusCode::CAPACITY_EXCEEDED` / `DiagnosticId::BYTE_LIMIT_EXCEEDED`,
	// exactly like `apply` would at commit time -- this is what lets the
	// cross-component prepared-batch preflight
	// (`GameplayAbilityWorldCoordinator::prepare_batch`) surface the
	// rejection as a per-target outcome before anything commits.
	Status prepare_apply(const EffectSpec &p_spec, Tick p_tick,
			const AttributeSet *p_source_attributes,
			const TagContainer *p_source_tags,
			PreparedEffectApplication &r_prepared) const;

	// Applies a plan produced by `prepare_apply` without re-reading source or
	// target attributes for magnitude resolution. Requirements/stack state
	// were checked during preparation; an unexpected stack invariant failure
	// during this call still fails the surrounding transaction closed.
	Status apply_prepared(const PreparedEffectApplication &p_prepared,
			Tick p_tick, const AttributeSet *p_source_attributes,
			const TagContainer *p_source_tags, Transaction &p_txn,
			NotificationQueue &p_queue, EffectHandle &r_handle,
			ChangeProvenance p_provenance =
					ChangeProvenance::AUTHORITATIVE,
			PredictionKey p_prediction_key =
					INVALID_PREDICTION_KEY);

	// Read-only preflight twin of `apply` (task 6.14's atomicity-policy
	// support -- see `GameplayAbilityComponent::preflight_pending_remote_effect`
	// for the game-facing motivation: cross-entity effects are not applied
	// atomically with the source's own cost/cooldown, so a game that wants to
	// avoid charging a cost for a strike that cannot land needs a way to ask
	// "would this land" BEFORE committing anything). Runs EXACTLY the same
	// pre-mutation failure checks `apply` runs, in the SAME order (see
	// `apply`'s own doc comment above, and `validate_apply_preconditions`,
	// which both now share): unknown effect, `validate_effect_spec`,
	// `p_spec.target != owner`, source/target requirements, immunity,
	// magnitude-source attribute existence, `EFFECT_STACK_REJECTED` at
	// max stacks under the REJECT overflow policy, and the
	// `MAX_RETAINED_TARGET_CONTEXT_BYTES` budget check (see `prepare_apply`,
	// which this delegates to) -- but performs NO mutation whatsoever:
	// allocates no handle, adds no modifier/tag, emits no lifecycle/cue
	// event or notification, and starts no `Transaction`.
	//
	// Deliberately never invokes an `AuthorityCalculationHook`, unlike
	// `apply` (which accepts one and fails with `StatusCode::HOOK_FAILED` if
	// it returns non-OK): calling one here would run arbitrary authority-side
	// gameplay logic under a contract that promises never to mutate or
	// commit anything, which the hook interface does not make. This means
	// this method is advisory, NOT a reservation: `ok_status()` means "as of
	// THIS call's snapshot of source/target attribute and tag state, `apply`
	// would not fail any of the checks listed above" -- nothing more.
	// `StatusCode::HOOK_FAILED`, and any `AttributeSet::add_modifier`/
	// `TagContainer::apply_mutations` arithmetic/capacity failure `apply`
	// documents on its own mutating paths, can therefore still only ever
	// surface at a REAL later `apply()` call, never here. Nothing prevents
	// state from changing between this call and a later `apply()` either --
	// this checks current state once, it does not lock or reserve it.
	//
	// `p_tick` is accepted for signature symmetry with `apply` (and in case a
	// future precondition needs it); none of the checks above are
	// tick-dependent today.
	Status preflight_apply(const EffectSpec &p_spec, Tick p_tick,
			const AttributeSet *p_source_attributes, const TagContainer *p_source_tags) const;

	// Explicit removal by handle (task 5.2/5.3). Idempotent: an unknown or
	// already-removed handle returns `ok_status()` and changes nothing (see
	// spec scenario "Infinite effect is removed"). Honors the definition's
	// `StackRemovalRule`: `REMOVE_SINGLE_STACK` decrements the stack count
	// (only fully tearing down modifiers/tags once it reaches zero);
	// `REMOVE_ALL_STACKS` always tears down the whole instance immediately.
	// `p_force_remove_all_stacks`, if true, tears down immediately regardless
	// of the declared rule (for a caller that explicitly wants "clear this
	// no matter how many stacks remain").
	Status remove_effect(EffectHandle p_handle, Tick p_tick, Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE,
			bool p_force_remove_all_stacks = false);

	// ---------------------------------------------------------------
	// Scheduling (task 5.6)
	// ---------------------------------------------------------------

	// Deterministically processes every expiration and periodic execution
	// due at or before `p_tick`, all within the ONE `Transaction&` given
	// (see class file comment): if anything fails, the WHOLE call rolls
	// back, including earlier steps already processed by THIS call.
	//
	// Algorithm (documented bounded catch-up policy): repeatedly find, among
	// every active effect, the single candidate with the smallest
	// `(due_tick, definition id, effect handle)` where `due_tick` is either
	// this effect's `end_tick` (if `end_tick <= p_tick`: an EXPIRATION,
	// unconditionally preferred over that same effect's own periodic
	// execution -- a periodic tick is only a candidate while
	// `next_period_tick < end_tick`, so an effect never executes AT or past
	// its own exclusive end tick) or its `next_period_tick` (if
	// `has_period && next_period_tick <= p_tick`: a PERIODIC EXECUTION).
	// Process that one candidate, then repeat. Expirations are uncapped
	// (bounded naturally by `MAX_ACTIVE_EFFECTS`); periodic executions are
	// capped at `MAX_PERIODIC_CATCHUP` TOTAL per call -- once reached, the
	// loop stops even if further periodic executions are due. Any periodic
	// effect left behind by the cap keeps its (still-due) `next_period_tick`
	// unchanged, so it is immediately due again on the NEXT `advance_to`
	// call, which resumes catch-up (bounded again). This bounds the amount
	// of work -- and therefore the size of the one transaction -- any
	// single call can perform, which is precisely why the cap exists.
	//
	// A periodic execution applies each declared modifier as an instant
	// delta against `attributes`' base (new_base = base OP resolved
	// magnitude, computed the same way INSTANT effects are applied -- see
	// `apply`), computed from `resolved_magnitudes` captured at apply/stack
	// time (NEVER re-read from a live source attribute). For `ModifierOp::ADD`
	// only, the applied delta scales linearly with the CURRENT stack count
	// (`resolved_magnitude * stack_count`); `MULTIPLY`/`OVERRIDE` periodic
	// modifiers use the resolved magnitude unscaled (repeated multiplicative
	// or override execution has no single well-defined per-stack scaling,
	// and v1 does not attempt to guess one).
	Status advance_to(Tick p_tick, Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// ---------------------------------------------------------------
	// Reads
	// ---------------------------------------------------------------

	bool has_effect(EffectHandle p_handle) const;
	const ActiveEffect *find(EffectHandle p_handle) const;

	// Every active effect, ascending `EffectHandle` (this runtime's own
	// canonical order -- see class file comment on why cross-component,
	// different-external-call-order byte identity is not claimed for fresh
	// `apply()` histories, only for `restore_snapshot` round trips).
	std::vector<EffectHandle> active_handles() const;
	std::size_t active_count() const { return active_effects.size(); }

	// Sum of `measure_target_effect_context_bytes` over every active
	// effect's `target_context` right now (ga_target_types.h) -- bounded by
	// `MAX_RETAINED_TARGET_CONTEXT_BYTES` (ga_limits.h), enforced at
	// effect-application preflight (see `apply`/`apply_prepared`/
	// `preflight_apply`'s own doc comments below). Maintained incrementally
	// on every mutation that changes a stored `target_context` (apply,
	// stack update, removal/expiry), each paired with the SAME
	// `Transaction` undo the mutation itself registers, so a rolled-back
	// transaction restores this exactly like every other piece of state it
	// touched. Recomputed wholesale (not trusted from a manually-maintained
	// invariant) by `restore_snapshot`, which also rejects a hand-crafted
	// snapshot whose restored total would exceed the limit.
	std::size_t retained_target_context_bytes() const {
		return retained_target_context_bytes_total;
	}

	void add_lifecycle_listener(EffectLifecycleListener p_listener);
	void add_cue_listener(EffectCueListener p_listener);

	// Builds a `SNAPSHOT_RESTORED` cue for one currently-active effect
	// (task 5.8's "may emit a snapshot-restored presentation phase"). Never
	// called internally by `restore_snapshot` itself (which never emits any
	// event -- see below); a caller that wants this presentation phase after
	// a late-join restore builds and dispatches it explicitly, per effect,
	// using this factory.
	EffectCueEvent make_snapshot_restored_cue(const ActiveEffect &p_effect, Tick p_tick);

	// ---------------------------------------------------------------
	// Canonical snapshots (task 5.8)
	// ---------------------------------------------------------------

	// Writes every active effect, ascending `EffectHandle`, with definition
	// identity, handle, source/target, stack state, start/end/next-period
	// ticks, resolved persistent magnitudes, context tag, revision, and the
	// granted source token, in one self-contained section.
	//
	// Fix (info-leak: retained `TargetEffectContext` on the wire): each
	// active effect's retained `target_context` (present only when its
	// definition set `retain_target_context`) is written UNTOUCHED when
	// `p_target_context_audience` is `INTERNAL` (the default -- every
	// pre-existing caller: local persistence, digest/consistency checks,
	// rollback baselines on authority). A caller encoding an owner-facing
	// wire snapshot for a specific remote peer passes that peer's own
	// audience instead; see the derivation and its accepted edge case in
	// this method's own `.cpp` comment.
	Status write_snapshot(SnapshotWriter &p_writer,
			TargetResultVisibility p_target_context_audience = TargetResultVisibility::INTERNAL) const;

	// Replaces this runtime's entire active-effect state from a previously
	// written snapshot. Decodes into a local temporary map first and only
	// swaps it into live state once decoding fully succeeds (never leaves a
	// partially-restored state on failure). Reconstructs equivalent state
	// WITHOUT running any application hook or emitting any lifecycle/cue
	// event or notification -- matching every sibling subsystem's
	// `restore_snapshot`. Does NOT touch `attributes`/`tags`; a caller
	// restoring a full component snapshot restores those independently and
	// is responsible for restoring them consistently with this runtime's
	// restored bookkeeping (this file does not own that cross-subsystem
	// ordering).
	//
	// `retained_target_context_bytes()` is NOT itself encoded on the wire --
	// it is re-derived from the decoded active-effect set (summing
	// `measure_target_effect_context_bytes` over every restored
	// `target_context`) rather than trusted from a manually-maintained
	// invariant, so this can never drift from live state. If that recomputed
	// total exceeds `MAX_RETAINED_TARGET_CONTEXT_BYTES`, restore fails with
	// `StatusCode::CAPACITY_EXCEEDED` / `DiagnosticId::BYTE_LIMIT_EXCEEDED`
	// and leaves prior state untouched (a hand-crafted or corrupted snapshot
	// over the limit is rejected here, not silently accepted) -- a snapshot
	// this SAME file ever wrote always satisfies the limit, since every path
	// that stores a `target_context` already enforces it before committing.
	Status restore_snapshot(SnapshotReader &p_reader);

	// Task 2.1's per-record delta body for the ACTIVE_EFFECT section: writes
	// exactly the fields `write_snapshot`'s own per-effect entry writes, in
	// the SAME order, including the SAME `p_target_context_audience`
	// sanitization rule (see `write_snapshot`'s own doc comment) -- there is
	// no separate PUBLIC-audience path for this section (it has no public
	// exposure at all today, see `AudienceVisibilityConfig`'s own comment),
	// so every caller of this codec passes `TargetResultVisibility::INTERNAL`
	// in practice; the parameter exists so this stays byte-identical to
	// `write_snapshot` if that ever changes rather than silently diverging.
	// Fails, without writing anything, if `p_handle` is not currently active.
	Status write_active_effect_delta_record(SnapshotWriter &p_writer, EffectHandle p_handle,
			TargetResultVisibility p_target_context_audience = TargetResultVisibility::INTERNAL) const;

	// Decodes one record `write_active_effect_delta_record` wrote, WITHOUT
	// touching live state: fails closed on an unregistered effect
	// definition or a malformed target context, exactly like
	// `restore_snapshot`'s own per-entry validation. `r_context_bytes`
	// receives this ONE record's own measured retained-context byte cost
	// (`measure_target_effect_context_bytes`) so a caller can accumulate the
	// SECTION-WIDE total across every record before calling
	// `validate_records` -- the budget is a whole-section bound, not a
	// per-record one (see `MAX_RETAINED_TARGET_CONTEXT_BYTES`, ga_limits.h).
	Status decode_active_effect_delta_record(SnapshotReader &p_reader, ActiveEffect &r_effect, std::size_t &r_context_bytes) const;

	// The pure-decode half of `restore_snapshot` -- see
	// `AttributeSet::decode_snapshot_section`'s doc comment for why this
	// exists (the delta codec's FULL_REENCODE apply path needs a decode
	// step that does not itself install anything).
	Status decode_snapshot_section(SnapshotReader &p_reader, std::map<EffectHandle, ActiveEffect> &r_effects) const;

	// Validates a COMPLETE proposed active-effect map (the delta codec's
	// "copy of current live state with this batch's ops already applied" --
	// see `AbilityComponent::apply_delta_batch`, ga_ability_component.cpp)
	// WITHOUT mutating this runtime: checks the record count against
	// `MAX_ACTIVE_EFFECTS` and the aggregate retained-context byte total
	// against `MAX_RETAINED_TARGET_CONTEXT_BYTES`, exactly like
	// `restore_snapshot`'s own tail. `r_retained_bytes` receives the
	// validated aggregate total on success, ready to hand to
	// `install_records` without recomputing it.
	Status validate_records(const std::map<EffectHandle, ActiveEffect> &p_effects, std::size_t &r_retained_bytes) const;

	// Replaces this runtime's ENTIRE active-effect state from an
	// already-validated map (`validate_records` must have already
	// succeeded for it) -- the shared install tail `restore_snapshot` and
	// the delta codec's `apply_delta_batch` both converge on. Trusts its
	// input completely; never called directly on untrusted input.
	void install_records(std::map<EffectHandle, ActiveEffect> p_effects, std::size_t p_retained_bytes);

	EffectRuntimeAllocatorState capture_allocator_state() const {
		return EffectRuntimeAllocatorState{
			handle_allocator.next_raw(), tag_source_allocator.next_raw(),
			event_allocator.next_raw(), occurrence_counter
		};
	}
	void restore_allocator_state_exact(
			const EffectRuntimeAllocatorState &p_state) {
		handle_allocator.restore_exact(p_state.effect_handle_next);
		tag_source_allocator.restore_exact(p_state.tag_source_next);
		event_allocator.restore_exact(p_state.event_next);
		occurrence_counter = p_state.occurrence;
	}

private:
	// Shared by `write_snapshot`'s own per-entry loop and
	// `write_active_effect_delta_record` -- see that public method's own doc
	// comment.
	Status write_active_effect_fields(SnapshotWriter &p_writer, const ActiveEffect &p_effect,
			TargetResultVisibility p_target_context_audience) const;
	// Shared by `restore_snapshot`'s own per-entry loop and
	// `decode_active_effect_delta_record` -- see that public method's own
	// doc comment. `r_context_bytes` is this ONE decoded record's own
	// `measure_target_effect_context_bytes` result; the aggregate budget
	// check happens in `validate_records`, not here.
	Status decode_active_effect_fields(SnapshotReader &p_reader, ActiveEffect &r_effect, std::size_t &r_context_bytes) const;

	struct MagnitudeResolution {
		std::vector<Fixed> values; // one per declaration
	};

	Status resolve_magnitudes(const EffectDefinition &p_definition, const EffectSpec &p_spec,
			const AttributeSet *p_source_attributes, MagnitudeResolution &r_out) const;

	// Shared pre-mutation validation chain `apply_internal` and
	// `preflight_apply` BOTH run, in this exact order, so the two can never
	// silently drift apart (see `preflight_apply`'s own doc comment above):
	// unknown effect, `p_spec.target != owner`, `validate_effect_spec`,
	// source requirements, immunity + target requirements, then magnitude
	// resolution. On success, `r_definition` is the resolved
	// `EffectDefinition*` and `r_resolution` the resolved persistent
	// magnitudes -- both needed by whichever mutation path the caller takes
	// next; `r_definition` is left null on any failure.
	//
	// Deliberately does NOT check `EFFECT_STACK_REJECTED`: that check needs
	// to know WHICH existing stack-group instance (if any) was found, and
	// `apply_internal`'s own stacking switch already resolves that for its
	// OWN subsequent branching (update-in-place vs. REFRESH/REPLACE/
	// APPLY_OVERFLOW_EFFECT), so threading it back out through this helper
	// would only ever serve `preflight_apply`'s much narrower yes/no need.
	// `preflight_apply` instead re-derives just that one condition directly
	// from `EffectDefinition::stacking` and the SAME `stack_index`/
	// `active_effects` lookup `apply_internal` uses -- see that method's own
	// body for the mirrored condition.
	Status validate_apply_preconditions(const EffectSpec &p_spec,
			const AttributeSet *p_source_attributes, const TagContainer *p_source_tags,
			const EffectDefinition *&r_definition, MagnitudeResolution &r_resolution) const;

	// Retained-context byte-budget preflight, shared by the mutating
	// `apply_internal` and the read-only `prepare_apply`/`preflight_apply`
	// so the two can never diverge on which bytes an application would
	// commit (mirrors `validate_apply_preconditions`'s own sharing
	// rationale above). `p_existing`, when non-null, is the SAME active-
	// effect record this application's stack resolution already found and
	// would overwrite (update-in-place, REFRESH, or REPLACE); pass `nullptr`
	// when this application would create a brand-new record instead. The
	// "new" context is derived the SAME way `apply_internal`'s own
	// `if (p_definition.retain_target_context)` gates decide it on both its
	// update-in-place and fresh-instance paths: `p_spec.target_context` when
	// the definition retains it, otherwise whatever `p_existing` already
	// held (unchanged) or the default absent context for a brand-new
	// record. Never called for an INSTANT effect or the
	// APPLY_OVERFLOW_EFFECT early-return case (see `apply_internal`): neither
	// ever stores a `target_context` for the PRIMARY spec being checked.
	// Returns `StatusCode::CAPACITY_EXCEEDED` /
	// `DiagnosticId::BYTE_LIMIT_EXCEEDED` (detail = the prospective total)
	// if committing would exceed `MAX_RETAINED_TARGET_CONTEXT_BYTES`;
	// `r_prospective_total` is always the value the running counter would
	// become on success, so a mutating caller can commit it directly rather
	// than recomputing.
	Status preflight_retained_context_bytes(
			const EffectDefinition &p_definition, const EffectSpec &p_spec,
			const ActiveEffect *p_existing,
			std::size_t &r_prospective_total) const;

	Status apply_internal(const EffectSpec &p_spec, Tick p_tick,
			const AttributeSet *p_source_attributes, const TagContainer *p_source_tags,
			Transaction &p_txn, NotificationQueue &p_queue, EffectHandle &r_handle,
			ChangeProvenance p_provenance, PredictionKey p_prediction_key,
			AuthorityCalculationHook *p_hook, bool p_allow_overflow_trigger,
			const MagnitudeResolution *p_prepared_resolution = nullptr,
			const MagnitudeResolution *p_prepared_overflow_resolution =
					nullptr);

	Status teardown_instance(EffectHandle p_handle, Tick p_tick, EffectLifecycleKind p_kind,
			EffectRemovalReason p_reason, Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance);

	// Executes one due periodic tick for `p_handle` (called only from
	// `advance_to`): applies its declared modifiers as instant deltas (see
	// `apply_instant_deltas`) using its already-resolved persistent
	// magnitudes, then advances `next_period_tick` by the declared period.
	Status execute_periodic(EffectHandle p_handle, Tick p_due_tick, Transaction &p_txn, NotificationQueue &p_queue,
			ChangeProvenance p_provenance);

	// Adds ONE new persistent modifier instance per declared modifier
	// (target attribute, op, resolved magnitude, priority, this instance's
	// own tag_source/handle as tie-breakers) for a fresh stack unit. Never
	// called for a periodic effect (see `ActiveEffect::modifier_handles`).
	Status add_persistent_modifiers(ActiveEffect &p_effect, const EffectDefinition &p_definition,
			Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance);

	// Applies every declared modifier of `p_definition` as an instant base
	// delta (new_base = base OP magnitude) via `AttributeSet::set_base`,
	// using `p_resolved` (captured persistent magnitudes, never re-read from
	// a live source). Used by both INSTANT application and periodic
	// execution -- see file comment on `advance_to` for the stack-scaling
	// rule `p_scale_add_by_stack` controls.
	Status apply_instant_deltas(const EffectDefinition &p_definition, const std::vector<Fixed> &p_resolved,
			std::uint32_t p_stack_count, bool p_scale_add_by_stack,
			Transaction &p_txn, NotificationQueue &p_queue, ChangeProvenance p_provenance);

	// Registers a lifecycle/cue notification onto `p_txn`, dispatched (via
	// `p_queue`) only after `p_txn` commits. Returns `add_notification`'s own
	// `Status` (`StatusCode::CAPACITY_EXCEEDED` past
	// `MAX_TRANSACTION_NOTIFICATIONS`) so a caller can fail the whole
	// transaction rather than silently dropping the event.
	Status emit_lifecycle(const EffectLifecycleEvent &p_event, Transaction &p_txn, NotificationQueue &p_queue);
	Status emit_cue(const EffectCueEvent &p_event, Transaction &p_txn, NotificationQueue &p_queue);
	std::uint64_t next_occurrence();

	const EffectRegistry *registry = nullptr;
	EntityId owner = INVALID_ENTITY_ID;
	AttributeSet *attributes = nullptr;
	TagContainer *tags = nullptr;

	std::map<EffectHandle, ActiveEffect> active_effects;
	// Stack group key: (stack_key, source-scoped-source-value-or-0) -> handle.
	std::map<std::pair<std::string, std::uint64_t>, EffectHandle> stack_index;

	// Sum of `measure_target_effect_context_bytes` over every entry in
	// `active_effects`' own `target_context` -- see
	// `retained_target_context_bytes()`'s own doc comment above for the
	// maintenance/rollback/restore contract.
	std::size_t retained_target_context_bytes_total = 0;

	HandleAllocator<EffectHandle> handle_allocator;
	HandleAllocator<SourceToken> tag_source_allocator;
	HandleAllocator<GameplayEventId> event_allocator;
	std::uint64_t occurrence_counter = 0;

	std::vector<EffectLifecycleListener> lifecycle_listeners;
	std::vector<EffectCueListener> cue_listeners;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_EFFECT_RUNTIME_H
