#ifndef GAMEPLAY_ABILITIES_CORE_ABILITY_COMPONENT_H
#define GAMEPLAY_ABILITIES_CORE_ABILITY_COMPONENT_H

#include "core/ga_abilities.h"
#include "core/ga_ability_tasks.h"
#include "core/ga_attribute_state.h"
#include "core/ga_attributes.h"
#include "core/ga_change_tracking.h"
#include "core/ga_delta.h"
#include "core/ga_effect_hooks.h"
#include "core/ga_effect_runtime.h"
#include "core/ga_effect_spec.h"
#include "core/ga_effects.h"
#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_tag_container.h"
#include "core/ga_tag_query.h"
#include "core/ga_tag_reactions.h"
#include "core/ga_tags.h"
#include "core/ga_tick.h"
#include "core/ga_transaction.h"

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

// The engine-independent core of `GameplayAbilityComponent` (tasks 6.2-6.8).
// Owns one entity's ability grants, in-flight executions, and the
// attribute/tag/effect runtime state those executions mutate. The Godot
// `Node` wrapper (built later, out of this file's scope) is a thin adapter:
// every gameplay decision -- validation, cost/cooldown/tag application,
// cancellation, snapshotting -- happens here, never in engine glue.
//
// -----------------------------------------------------------------------
// Composing with `TagContainer`'s transaction participation
// -----------------------------------------------------------------------
// `TagContainer::apply_mutations` participates in a CALLER-SUPPLIED
// `Transaction&` exactly like `AttributeSet`/`EffectRuntime` (see
// ga_tag_container.h / ga_effect_runtime.h file comments): any tag batch
// this class itself issues (granting/removing an execution's `owned_tags`)
// registers its undo on the SAME transaction as every other step of the
// call, so a later failure anywhere in that transaction rolls the tag batch
// back too. There is no "tags last" ordering requirement to maintain.
//
// -----------------------------------------------------------------------
// Role enforcement (normative)
// -----------------------------------------------------------------------
// `OFFLINE_AUTHORITY` and `SERVER_AUTHORITY` share the identical validation
// and mutation path and only ever accept `ChangeProvenance::AUTHORITATIVE`
// on a mutating call. `NETWORK_CLIENT` is never authoritative and only ever
// accepts `ChangeProvenance::PREDICTED` (the seam section 8's prediction
// journal will drive); an `AUTHORITATIVE` call against a `NETWORK_CLIENT`
// component -- and a `PREDICTED` call against an authority component --
// fails with `StatusCode::ROLE_VIOLATION` before touching any state.
//
// -----------------------------------------------------------------------
// Reentrancy and dispatch (task 6.8)
// -----------------------------------------------------------------------
// Every mutating entry point below runs its own atomic `Transaction`, commits
// it, and dispatches `notification_queue()` before returning. A listener that
// reacts to a dispatched record by calling `request_activation` reentrantly
// (i.e. while `notification_queue().is_dispatching()` is still true) is
// transparently deferred through `NotificationQueue::request_mutation` and
// receives `ActivationResult{ queued = true }` immediately; the deferred
// call actually runs once the OUTERMOST entry point finishes its own
// dispatch and drains `take_pending_requests()` (bounded by
// `MAX_EVENT_RECURSION` pump iterations). This file's own internal listeners
// (the cooldown-expiry and cancel-tag watchers registered in the
// constructor) always defer through `request_mutation` unconditionally --
// they never assume the reader is calling from a non-dispatching context.
namespace ga {

// Forward-declared only: `GameplayAbilityWorldCoordinator` (ga_targeting.h)
// itself includes THIS file (it holds `AbilityComponent*` registrations), so
// this file cannot include ga_targeting.h back without a circular include.
// `AbilityComponent::write_delta_batch`/`apply_delta_batch` only ever need a
// pointer to it (to reach the TARGET_SESSION section's content, which this
// class does not own -- see ga_targeting.h's own file comment); the .cpp
// includes ga_targeting.h to actually call it.
class GameplayAbilityWorldCoordinator;

// ---------------------------------------------------------------------------
// Addon-internal authoring/runtime bounds (mirrors the same
// "small bound owned by the file that needs it" precedent as
// ga_transaction.h's MAX_TRANSACTION_UNDO_OPS; not part of the wire contract
// in ga_limits.h).
// ---------------------------------------------------------------------------

// Commands a single hook invocation may submit through its `AbilityCommandBuilder`.
constexpr std::size_t MAX_ABILITY_HOOK_COMMANDS = 8;

// Reserved base so this component's own owned-tag `SourceToken` allocator
// can never collide with `EffectRuntime`'s independent, privately-allocated
// source tokens in the SAME shared `TagContainer` (both this class and its
// owned `EffectRuntime` mutate one container). Practical headroom: either
// allocator would need on the order of 2^32 grants before values could
// approach the other's range, far beyond any bounded session this addon
// supports (`MAX_ACTIVE_EFFECTS` / `MAX_ACTIVE_EXECUTIONS` cap concurrent
// instances).
constexpr std::uint64_t GA_ABILITY_OWNED_TAG_SOURCE_BASE = (std::uint64_t(1) << 32);

// Task 4.5 (design.md decision 5, "Reject static cycles and bound dynamic
// chains" -- the RUNTIME half; static cycle rejection is task 3.4,
// `TagReactionRegistry::seal`). Default hard maximum for a dynamic
// reaction-effect chain: reaction A's target effect commits a tag
// transaction whose edges trigger reaction B, whose own target effect
// commits a transaction triggering reaction C, and so on. Counted the same
// way `handle_gameplay_event_internal` counts `MAX_EVENT_RECURSION` (see
// ga_limits.h): the FIRST reaction batch triggered by a non-reaction-caused
// transaction is depth 1; a batch would-be dispatched at depth >=
// `MAX_REACTION_CHAIN_DEPTH` is stopped instead (see
// `AbilityComponent::flush_tag_reactions`). "Configurable" per design.md --
// this is only the DEFAULT; `AbilityComponent`'s constructor accepts an
// override. Addon-internal runtime bound, not part of the wire contract
// (mirrors `MAX_ABILITY_HOOK_COMMANDS` above), because it governs how much
// LOCAL dispatch work one commit can trigger, not any encoded/replicated
// value.
constexpr std::size_t MAX_REACTION_CHAIN_DEPTH = 8;

// ---------------------------------------------------------------------------
// Component role (normative "Role enforcement" requirement)
// ---------------------------------------------------------------------------

enum class ComponentRole : std::uint8_t {
	OFFLINE_AUTHORITY = 0,
	SERVER_AUTHORITY = 1,
	NETWORK_CLIENT = 2,
};

// ---------------------------------------------------------------------------
// Gameplay events (the in-process "validated gameplay event" the abilities
// spec names -- a bounded, declarative value, matching the same "v1 does not
// define a generic target-data schema" posture `EffectSpec::target_data`
// already takes; a fuller authoritative event STREAM/wire encoding is the
// protocol layer's `gap_event_stream.*`, out of this file's scope).
// ---------------------------------------------------------------------------

struct GameplayEventContext {
	DefinitionId event_tag = INVALID_DEFINITION_ID; // a registered tag identifier naming this event
	EntityId instigator = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	Fixed magnitude = Fixed::zero();
	std::uint64_t payload_tag = 0; // opaque additional context, like EffectSpec::context_tag
};

// ---------------------------------------------------------------------------
// Execution phases and lifecycle-ending reasons
// ---------------------------------------------------------------------------

// The one activation state machine every ability follows: request ->
// validate -> begin -> optional commit -> active -> ended | cancelled.
// `REQUESTED`/`VALIDATING`/`COMMITTED` are signal-only transient phases
// (never the value of `ActiveExecution::phase`, which only ever rests at
// `BEGUN`, `ACTIVE`, `ENDED`, or `CANCELLED`); they exist so
// `AbilityLifecycleEvent::phase` can name exactly which step a signal
// reports.
enum class ExecutionPhase : std::uint8_t {
	REQUESTED = 0,
	VALIDATING = 1,
	BEGUN = 2,
	COMMITTED = 3,
	ACTIVE = 4,
	ENDED = 5,
	CANCELLED = 6,
};

enum class ExecutionEndReason : std::uint8_t {
	NONE = 0,
	EXPLICIT_SUCCESS = 1,
	EXPLICIT_CANCEL = 2,
	CANCEL_TAG = 3,
	REVOKED = 4,
	OWNER_TEARDOWN = 5,
	AUTHORITY_CORRECTION = 6,
	HOOK_FAILURE = 7,
};

// ---------------------------------------------------------------------------
// Constrained behavior hooks (task 6.6)
// ---------------------------------------------------------------------------

// Immutable, read-only view a hook receives -- never a pointer/reference to
// this component's live containers (see file comment). Built fresh, from a
// stable transaction snapshot, for each hook invocation.
struct AbilityExecutionContext {
	EntityId owner = INVALID_ENTITY_ID;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	std::int32_t level = 1;
	Tick tick = 0;
	ComponentRole role = ComponentRole::OFFLINE_AUTHORITY;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;

	std::vector<std::pair<DefinitionId, Fixed>> owner_attributes; // ascending DefinitionId
	std::vector<DefinitionId> owner_tags; // ascending, exact-owned
	std::vector<EntityId> targets; // <= MAX_TARGETS_PER_COMMAND, from the activation request
	std::vector<SetByCallerMagnitude> set_by_caller; // forwarded from the activation request
	std::vector<AbilityTaskHandle> active_tasks; // ascending handle, immutable snapshot

	bool has_event = false;
	GameplayEventContext event;

	Status find_owner_attribute(DefinitionId p_id, Fixed &r_out) const;
};

// One command a hook may submit instead of mutating a container directly.
// `APPLY_TARGET_EFFECT` and `EMIT_GAMEPLAY_EVENT` are authority-only (see
// `AbilityCommandBuilder`); `APPLY_SELF_EFFECT` is available to a
// prediction-safe hook only when the referenced effect itself declares
// `prediction_safe` and has no period.
enum class AbilityHookCommandKind : std::uint8_t {
	APPLY_SELF_EFFECT = 0,
	APPLY_TARGET_EFFECT = 1,
	EMIT_GAMEPLAY_EVENT = 2,
	START_TASK = 3,
	CANCEL_TASK = 4,
	COMMIT_EXECUTION = 5,
	END_EXECUTION = 6,
	CANCEL_EXECUTION = 7,
};

struct AbilityHookCommand {
	AbilityHookCommandKind kind = AbilityHookCommandKind::APPLY_SELF_EFFECT;

	// APPLY_SELF_EFFECT / APPLY_TARGET_EFFECT:
	DefinitionId effect_definition = INVALID_DEFINITION_ID;
	EntityId explicit_target = INVALID_ENTITY_ID; // APPLY_TARGET_EFFECT only; must be in the context's `targets`
	std::vector<SetByCallerMagnitude> set_by_caller;

	// EMIT_GAMEPLAY_EVENT:
	GameplayEventContext event;

	// START_TASK / CANCEL_TASK:
	AbilityTaskRequest task_request;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	AbilityTaskCancelReason task_cancel_reason = AbilityTaskCancelReason::EXPLICIT;
};

// ---------------------------------------------------------------------------
// Task 6.13 -- surfaced (not silently dropped) remote-target hook commands
// ---------------------------------------------------------------------------
//
// The "Authority hook applies a validated target effect" scenario requires
// that a validated `APPLY_TARGET_EFFECT` command actually gets applied, but
// this class only ever owns ONE entity's containers (`owner_entity`'s
// `AttributeSet`/`TagContainer`/`EffectRuntime`) -- it structurally cannot
// reach into another component's state, and that is a correct boundary, not
// a bug (see `commit_execution_body`'s own comment). So instead of silently
// discarding a command whose `explicit_target != owner_entity` (the previous
// behavior -- validated, then dropped, no error, no diagnostic), this file
// surfaces it as a fully-resolved, ordered, immutable value: the caller
// (network/game layer, which DOES know how to reach the target's own
// component) applies it there via `AbilityComponent::apply_remote_effect`,
// through that component's own normal validated `EffectRuntime::apply` path
// -- never by reaching into this component's internals.
//
// This struct carries everything `apply_remote_effect` needs and nothing a
// hook could use to inject an authority handle or bypass an effect
// requirement: no `EffectHandle` field exists (mirrors `AbilityHookCommand`
// itself), and `effect_definition`/`level`/`set_by_caller` are exactly the
// SAME validated fields `AbilityCommandBuilder::submit` already accepted --
// this struct is a read-out of that decision, not a new capability.
struct PendingRemoteEffectCommand {
	EntityId source = INVALID_ENTITY_ID; // always the originating component's owner
	EntityId target = INVALID_ENTITY_ID; // != source; the entity that must apply this
	DefinitionId effect_definition = INVALID_DEFINITION_ID;
	std::int32_t level = 1;
	std::vector<SetByCallerMagnitude> set_by_caller;
	TargetEffectContext target_context;

	// Informational only -- captured from the originating execution for
	// correlation/diagnostics. `apply_remote_effect` never trusts these for
	// its own authority decision (see that method's doc comment): a remote-
	// target effect is never predicted (task 8.4 keeps remote-target effects
	// server-only), so applying one is ALWAYS an authoritative operation on
	// the target's own component regardless of what is recorded here.
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	AbilitySpecId originating_spec = INVALID_ABILITY_SPEC_ID;
	ExecutionId originating_execution = INVALID_EXECUTION_ID;
	Tick tick = 0;
};

// Accumulates the bounded command list a single hook invocation submits.
// `submit` validates CAPABILITY (what kind of command this mode may emit,
// and -- for a prediction-safe self-effect -- that the target effect is
// itself prediction-safe) but never applies anything itself: the owning
// `AbilityComponent` applies every accepted command through the SAME core
// path (`EffectRuntime::apply` / `handle_gameplay_event`) any other caller
// would use, inside the current atomic commit transaction, which is what
// makes "a hook must not be able to inject an authority handle or bypass
// effect requirements" a structural property rather than a convention.
//
// A rejected `submit` is STICKY: once `violation_status()` is non-OK, it
// never changes back, so a hook cannot work around a rejected submission by
// ignoring this call's return value -- the caller checks
// `violation_status()` unconditionally after the hook returns and fails the
// whole commit if it is set (see "Hook attempts direct mutation" scenario).
class AbilityCommandBuilder {
public:
	AbilityCommandBuilder(const EffectRegistry &p_effects, const std::vector<EntityId> &p_valid_targets,
			bool p_prediction_safe_mode, std::uint64_t p_next_task_raw = 0) :
			effects(&p_effects), valid_targets(&p_valid_targets),
			prediction_safe_mode(p_prediction_safe_mode), next_task_raw(p_next_task_raw) {}

	Status submit(const AbilityHookCommand &p_command);
	Status request_task(const AbilityTaskRequest &p_request, AbilityTaskHandle &r_requested_task);

	Status violation_status() const { return violation; }
	const std::vector<AbilityHookCommand> &commands() const { return recorded; }

private:
	const EffectRegistry *effects = nullptr;
	const std::vector<EntityId> *valid_targets = nullptr;
	bool prediction_safe_mode = false;
	std::uint64_t next_task_raw = 0;
	std::vector<AbilityHookCommand> recorded;
	Status violation;
};

// Authority-only hook: may consult validated game state (via the context)
// and submit any documented command kind. Structurally distinct from
// `PredictionSafeAbilityHook` -- exactly like `ga_effect_hooks.h`'s
// `AuthorityCalculationHook`/`PredictionSafeCalculationHook` split -- so
// "register an authority-only hook where prediction-safe is required" is a
// compile error, not a runtime policy check that could be forgotten.
class AuthorityAbilityHook {
public:
	virtual ~AuthorityAbilityHook() = default;
	virtual Status execute(const AbilityExecutionContext &p_context, AbilityCommandBuilder &p_commands) = 0;
	virtual Status on_task_event(const AbilityExecutionContext &p_context,
			const AbilityTaskEvent &p_event, AbilityCommandBuilder &p_commands) {
		(void)p_context;
		(void)p_event;
		(void)p_commands;
		return ok_status();
	}
};

// Prediction-safe hook: MUST be a pure function of `AbilityExecutionContext`
// alone (no wall clock, RNG, scene/physics query, or unrestricted callback)
// and may submit only `APPLY_SELF_EFFECT` commands naming a prediction-safe,
// non-periodic effect (enforced by `AbilityCommandBuilder::submit`). The
// capability flags below are how an implementation self-declares whether it
// meets that bar; `validate_prediction_safe_hook` is the enforcement point
// `AbilityComponent::bind_prediction_safe_hook` calls before ever trusting
// one of these.
class PredictionSafeAbilityHook {
public:
	virtual ~PredictionSafeAbilityHook() = default;
	virtual Status execute(const AbilityExecutionContext &p_context, AbilityCommandBuilder &p_commands) = 0;
	virtual Status on_task_event(const AbilityExecutionContext &p_context,
			const AbilityTaskEvent &p_event, AbilityCommandBuilder &p_commands) {
		(void)p_context;
		(void)p_event;
		(void)p_commands;
		return ok_status();
	}

	virtual bool depends_on_time() const { return false; }
	virtual bool depends_on_randomness() const { return false; }
	virtual bool depends_on_scene_or_physics() const { return false; }
	virtual bool uses_unrestricted_callback() const { return false; }
};

// Rejects `p_hook` if it declares ANY forbidden dependency, with
// `StatusCode::PREDICTION_NOT_SAFE` / `DiagnosticId::HOOK_CAPABILITY_DENIED`
// and `detail` set to the OR of every `PREDICTION_UNSAFE_*` flag (see
// ga_effect_hooks.h) it declared.
Status validate_prediction_safe_hook(const PredictionSafeAbilityHook &p_hook);

// ---------------------------------------------------------------------------
// Grants (task 6.2)
// ---------------------------------------------------------------------------

struct AbilityGrant {
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	std::int32_t level = 1;
	std::string input_id;
	bool revoked = false;
	// Authoritative cooldown gate: valid only while the cooldown effect's
	// active instance still exists in `effects()` (see
	// "Ability Costs and Cooldowns as Effects" -- cooldown eligibility is
	// ALWAYS re-derived from this live handle, never a cached boolean or
	// presentation timer).
	EffectHandle cooldown_handle = INVALID_EFFECT_HANDLE;
	CommandSeq last_command_sequence = INVALID_COMMAND_SEQ; // highest accepted sequence, for staleness checks
	std::uint64_t revision = 0;
};

// ---------------------------------------------------------------------------
// Executions (tasks 6.3, 6.4, 6.7)
// ---------------------------------------------------------------------------

struct ActiveExecution {
	ExecutionId id = INVALID_EXECUTION_ID;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionPhase phase = ExecutionPhase::BEGUN;
	Tick begin_tick = 0;
	Tick commit_tick = INVALID_TICK;
	// This execution's own tag ownership token for `owned_tags` (see
	// ga_tag_container.h); INVALID until commit grants them.
	SourceToken owned_tag_source = INVALID_SOURCE_TOKEN;
	// Handles this execution's own commit created (declared `commit_effects`
	// plus any hook-applied effect) -- torn down atomically when this
	// execution ends or cancels. The cooldown effect handle is NEVER in this
	// list: cooldown is spec-level state that deliberately outlives the
	// execution.
	std::vector<EffectHandle> owned_effect_handles;
	std::vector<EntityId> targets;
	// Captured from the originating `ActivationRequest` so a later, separate
	// `commit_activation` call (auto_commit == false) applies cost/cooldown/
	// commit-effect magnitudes with the SAME caller-supplied values begin saw.
	std::vector<SetByCallerMagnitude> set_by_caller;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	// Set only when this execution was triggered by `handle_gameplay_event`
	// (as opposed to a manual request or passive-on-grant), so the bound
	// hook's `AbilityExecutionContext::event` can carry it.
	bool has_triggering_event = false;
	GameplayEventContext triggering_event;
	std::uint64_t revision = 0;
};

// ---------------------------------------------------------------------------
// Activation requests and results (task 6.3)
// ---------------------------------------------------------------------------

struct ActivationRequest {
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	std::vector<EntityId> targets; // <= MAX_TARGETS_PER_COMMAND
	std::vector<SetByCallerMagnitude> set_by_caller; // forwarded to cost/cooldown/commit-effect specs
	CommandSeq command_sequence = INVALID_COMMAND_SEQ; // caller-supplied ordering/staleness key
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
};

// The structured activation result the spec requires. `status` is the
// existing, additive `ga::Status`/`StatusCode` type (per the shared
// contract, "map these onto the existing StatusCode values"): OK on
// success; otherwise one of `UNKNOWN_ABILITY`, `ABILITY_NOT_GRANTED`,
// `ABILITY_ALREADY_ACTIVE`, `ABILITY_MISSING_TAG`, `ABILITY_BLOCKED_TAG`,
// `ABILITY_ON_COOLDOWN`, `ABILITY_COST_UNAFFORDABLE`, `ABILITY_INVALID_TARGET`,
// `NOT_OWNER`, `RATE_LIMITED`, `STALE_COMMAND`, `ABILITY_REVOKED`,
// `ROLE_VIOLATION`, `CAPABILITY_VIOLATION`, `RECURSION_LIMIT`, or a
// permission/prediction-rejection code, matching whichever layer produced
// the rejection (see file comment: `NOT_OWNER`/`RATE_LIMITED` are reserved
// for the network/protocol boundary above this component; this component
// never produces them itself).
struct ActivationResult {
	Status status;
	ExecutionId execution = INVALID_EXECUTION_ID; // valid once BEGUN
	Tick cooldown_ready_tick = INVALID_TICK; // meaningful when status.code == ABILITY_ON_COOLDOWN
	// True when this request was deferred (reentrant call during dispatch);
	// `status`/`execution` are not yet meaningful -- the eventual outcome
	// arrives later via an `AbilityLifecycleEvent`.
	bool queued = false;
	// Task 6.13: every `APPLY_TARGET_EFFECT` command this commit validated
	// and accepted but could not apply itself because its target was not
	// `owner` -- see `PendingRemoteEffectCommand`'s own doc comment. Bounded
	// by `MAX_ABILITY_HOOK_COMMANDS` (one hook invocation's own cap). Empty
	// for a deferred (`queued == true`) result -- the eventual commit's own
	// list arrives, if any, on whatever later call actually performs it.
	std::vector<PendingRemoteEffectCommand> pending_remote_effects;
};

struct CancellationResult {
	Status status; // OK the first time this call performs the transition; ABILITY_ALREADY_ENDED for a later duplicate
	ExecutionId execution = INVALID_EXECUTION_ID;
};

// Opaque-ish value capture used only by the per-world typed-target
// coordinator. Canonical snapshot bytes restore gameplay containers; the
// trailing cursors restore local monotonic identities and driver state that
// canonical snapshots intentionally do not expose.
struct AbilityComponentBatchCapture {
	std::vector<std::uint8_t> snapshot;
	std::uint64_t attribute_modifier_next = 0;
	EffectRuntimeAllocatorState effect_allocators;
	std::uint64_t spec_next = 0;
	std::uint64_t execution_next = 0;
	std::uint64_t transaction_next = 0;
	std::uint64_t event_next = 0;
	std::uint64_t owned_tag_source_next = 0;
	Tick last_known_tick = 0;
	bool task_tag_state_dirty = false;
};

struct PreparedAbilityComponentMutation {
	std::unique_ptr<Transaction> transaction;
	std::uint64_t attribute_modifier_next = 0;
	EffectRuntimeAllocatorState effect_allocators;
	std::uint64_t transaction_next = 0;
	Tick last_known_tick = 0;
	bool committed = false;
	bool finished = false;
};

// ---------------------------------------------------------------------------
// Signals (task 6.8) -- new ability-specific DTOs only; effect/attribute/tag
// records are reused as-is via the pass-through listener registration below.
// ---------------------------------------------------------------------------

enum class AbilityLifecycleKind : std::uint8_t {
	GRANTED = 0,
	REVOKED = 1,
	REQUESTED = 2,
	PHASE_CHANGED = 3,
	COMMITTED = 4,
	ENDED = 5,
	CANCELLED = 6,
	FAILED = 7,
	SNAPSHOT_RESTORED = 8,
};

struct AbilityLifecycleEvent {
	GameplayEventId id = INVALID_GAMEPLAY_EVENT_ID;
	AbilityLifecycleKind kind = AbilityLifecycleKind::REQUESTED;
	EntityId owner = INVALID_ENTITY_ID;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	ExecutionPhase phase = ExecutionPhase::REQUESTED;
	ExecutionEndReason end_reason = ExecutionEndReason::NONE;
	Status status;
	Tick tick = 0;
	TransactionId transaction = INVALID_TRANSACTION_ID;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	std::size_t cleaned_task_count = 0;
};

using AbilityLifecycleListener = std::function<void(const AbilityLifecycleEvent &, NotificationQueue &)>;

enum class AbilityDiagnosticKind : std::uint8_t {
	RECURSION_LIMIT_REACHED = 0,
	CAPABILITY_VIOLATION_DETECTED = 1,
	ROLE_VIOLATION_DETECTED = 2,
	// Task 6.13: `commit_execution_body` produced one or more
	// `PendingRemoteEffectCommand`s (a hook's validated `APPLY_TARGET_EFFECT`
	// naming a genuinely remote target) and the caller that drove this commit
	// passed no place for them to go (`commit_activation`'s optional out-
	// param was null). The commit itself still succeeded -- this is not a
	// failure -- but the accepted remote command has nowhere to be applied,
	// so this diagnostic makes that silent-drop failure mode observable
	// instead of invisible (see the struct's own doc comment). Never fired
	// for `request_activation`/`process_activation_batch`, which always
	// return the list on `ActivationResult` itself and therefore can never
	// drop it this way.
	PENDING_REMOTE_EFFECT_DROPPED = 3,
	// Spec "Bounded Task Runtime" / scenario "Event fan-out reaches its work
	// budget": `AbilityTaskRuntime::advance_to`/`notify_gameplay_event`/
	// `notify_tag_state_changed` stopped waking further tasks this call
	// because `MAX_TASK_TERMINAL_EVENTS_PER_TICK` was reached. Recovery is
	// already deterministic (every task the cap left untouched stays fully
	// indexed and is reconsidered on the next due tick/event/tag edge -- see
	// each method's own bounded loop); this diagnostic only makes the
	// truncation itself observable. Fired at most once per call that
	// truncates (never once per skipped task), so it stays bounded exactly
	// like the truncation it reports.
	TASK_FANOUT_TRUNCATED = 4,
};

struct AbilityDiagnosticEvent {
	AbilityDiagnosticKind kind = AbilityDiagnosticKind::RECURSION_LIMIT_REACHED;
	EntityId owner = INVALID_ENTITY_ID;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	Status status;
	Tick tick = 0;
};

using AbilityDiagnosticListener = std::function<void(const AbilityDiagnosticEvent &)>;

// ---------------------------------------------------------------------------
// Tag-reaction runtime signals (task 4.x -- design.md decision 4 "Dispatch
// after commit in canonical order" / decision 5 "Reject static cycles and
// bound dynamic chains"; specs/gameplay-effects/spec.md "Isolated Reaction
// Effect Failures", "While-Present Effect Binding"). Distinct from
// `AbilityDiagnosticEvent` because a reaction diagnostic needs to name a
// `TagReactionDefinition` (or, for a chain-bound diagnostic, a whole stable
// PATH of reaction identifiers) rather than an `AbilitySpecId`/`ExecutionId`
// -- reusing that struct would leave no field for either.
// ---------------------------------------------------------------------------

enum class TagReactionDiagnosticKind : std::uint8_t {
	// ON_ADDED/ON_REMOVED apply, or a WHILE_PRESENT false-to-true apply,
	// failed a requirement/immunity/preflight check (`status` carries the
	// underlying failure). No handle or partial effect state was created;
	// no retry happens until a later matching edge (spec "While-present
	// application fails" / "One of two added reactions fails").
	APPLICATION_FAILED = 0,
	// A WHILE_PRESENT true-to-false edge found its bound handle no longer
	// active (removed by something other than this reaction's own
	// true-to-false edge). The stale binding was cleared; nothing else was
	// touched (spec "Bound handle was removed externally" / "While-present
	// removal references a stale handle"). `status` is always `ok_status()`.
	STALE_HANDLE_CLEARED = 1,
	// Task 4.5: a dynamic reaction chain reached `max_reaction_chain_depth`.
	// The remaining chain (this batch's edges) was stopped; `reaction_path`
	// carries the stable path of reaction identifiers from the chain's root
	// to the reaction whose effect application produced the now-too-deep
	// batch. `reaction`/`status` are not meaningful (a batch, not a single
	// reaction, was stopped).
	CHAIN_LIMIT_REACHED = 2,
};

struct TagReactionDiagnosticEvent {
	TagReactionDiagnosticKind kind = TagReactionDiagnosticKind::APPLICATION_FAILED;
	EntityId owner = INVALID_ENTITY_ID;
	// The reaction this diagnostic is about. `INVALID_DEFINITION_ID` for
	// `CHAIN_LIMIT_REACHED` (see `reaction_path` instead).
	DefinitionId reaction = INVALID_DEFINITION_ID;
	Status status; // meaningful for APPLICATION_FAILED only; ok_status() otherwise
	Tick tick = 0;
	// CHAIN_LIMIT_REACHED only: reaction identifiers in dispatch order, root
	// first. Empty for every other kind.
	std::vector<std::string> reaction_path;
};

using TagReactionDiagnosticListener = std::function<void(const TagReactionDiagnosticEvent &)>;

// One active `WHILE_PRESENT` binding: the reaction's own stable identity plus
// the authority `EffectHandle` its false-to-true edge applied and bound (task
// 4.4). Exposed read-only so a future snapshot writer (section 5, out of this
// task's scope) can serialize exactly this pair per active binding without
// reaching into this component's private state.
struct TagReactionBinding {
	DefinitionId reaction = INVALID_DEFINITION_ID;
	EffectHandle handle = INVALID_EFFECT_HANDLE;
};

// Snapshot section kinds this file writes/reads (scoped to this file only --
// see ga_snapshot.h: a kind is only ever compared against the matching
// `begin_section` call decoding the exact bytes this file itself wrote).
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_COMPONENT = 1;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_GRANTS = 2;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_GRANT_ENTRY = 3;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_EXECUTIONS = 4;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_EXECUTION_ENTRY = 5;
// Task 5.3 (design.md decision 6, "Execute only on authority and restore
// without replay"): active `WHILE_PRESENT` reaction bindings, written/read
// right after the nested `effects()` section (so a restoring reader can
// already validate a binding's handle against the just-restored
// `EffectRuntime`) and before this file's own grants/executions sections.
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDINGS = 6;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_REACTION_BINDING_ENTRY = 7;

// ---------------------------------------------------------------------------
// AbilityComponent
// ---------------------------------------------------------------------------

class AbilityComponent {
public:
	// Every registry must already be sealed (like `EffectRuntime`'s own
	// constructor precedent). Non-owning references; they must outlive this
	// component.
	//
	// Task 4.1 (design.md decision 4): `p_reactions`, mirroring how every
	// other registry above is wired in, is an OPTIONAL non-owning pointer to
	// an already-sealed `TagReactionRegistry` -- `nullptr` (the default)
	// means this component has no reactions at all. Trailing default
	// arguments (rather than a required parameter) so the ~100 existing call
	// sites across native/tests/ and native/godot/ that predate this task
	// keep compiling unchanged. "Empty registry = zero overhead" (task 4.1)
	// is decided ONCE here and extends to "absent registry" and to a
	// `NETWORK_CLIENT` role too (task 4.6: "NETWORK_CLIENT components never
	// evaluate reaction edges") -- see `reactions_enabled`: when false, this
	// component never registers the tag-change observer `flush_tag_reactions`
	// needs, so a reaction-less or non-authority component pays nothing
	// beyond the one boolean check at construction. `p_max_reaction_chain_depth`
	// is design.md's "configurable hard maximum" for task 4.5's dynamic
	// chain bound; defaults to `MAX_REACTION_CHAIN_DEPTH`.
	AbilityComponent(const AbilityRegistry &p_abilities, const EffectRegistry &p_effects,
			const AttributeRegistry &p_attributes, const TagRegistry &p_tags,
			EntityId p_entity, ComponentRole p_role,
			const TagReactionRegistry *p_reactions = nullptr,
			std::size_t p_max_reaction_chain_depth = MAX_REACTION_CHAIN_DEPTH);

	EntityId entity() const { return owner_entity; }
	ComponentRole role() const { return component_role; }

	AttributeSet &attributes() { return attribute_set; }
	const AttributeSet &attributes() const { return attribute_set; }
	TagContainer &tags() { return tag_container; }
	const TagContainer &tags() const { return tag_container; }
	EffectRuntime &effects() { return effect_runtime; }
	const EffectRuntime &effects() const { return effect_runtime; }
	AbilityTaskRuntime &ability_tasks() { return task_runtime; }
	const AbilityTaskRuntime &ability_tasks() const { return task_runtime; }
	NotificationQueue &notification_queue() { return queue; }

	// -----------------------------------------------------------------
	// Per-audience change tracking
	// (add-granular-delta-replication-2026-07-27, tasks 1.1-1.4)
	// -----------------------------------------------------------------

	// The per-audience revision/dirty-ring ledger for this component -- see
	// ga_change_tracking.h. Listeners installed by this class's own
	// constructor (on `attributes()`, `tags()`, `effects()`, ability
	// lifecycle/task notifications) keep it current; a caller never marks it
	// directly except through `record_target_session_change` below, which
	// `GameplayAbilityWorldCoordinator` uses for retained target-session
	// state (task 1.4).
	ChangeTracker &change_tracker() { return change_tracker_; }
	const ChangeTracker &change_tracker() const { return change_tracker_; }

	// The engine-free PUBLIC-audience visibility predicate for the sections
	// that have no visibility marker of their own -- see
	// `AudienceVisibilityConfig`'s own doc comment. A later wave's bridge
	// populates this from its `hidden_*` Godot-side sets; tests populate it
	// directly. Mutating this does NOT itself mark anything dirty -- a caller
	// that changes what is hidden must call `change_tracker().
	// force_full_resync()` afterward (see that method's own doc comment) so
	// every audience a peer already synced is told its view may now be
	// stale.
	AudienceVisibilityConfig &visibility_config() { return visibility_config_; }
	const AudienceVisibilityConfig &visibility_config() const { return visibility_config_; }

	// Records a change to this component's retained target-session state
	// (owned by `GameplayAbilityWorldCoordinator`, not this class -- see
	// ga_targeting.h) under the SAME per-audience change tracking as every
	// other section (task 1.4). `p_public_visible` is already resolved by
	// the caller (the coordinator derives it from the session's schema --
	// `TargetSchemaDesc::visibility` via `visible_to`, exactly like a task's
	// own `AbilityTaskRequest::visibility` decides `ABILITY_TASK`). Not
	// gated by a `Transaction`: the coordinator mutates session state
	// synchronously with no rollback machinery of its own (see
	// ga_targeting.h's file comment), so there is nothing here to defer or
	// undo either.
	void record_target_session_change(TargetSessionId p_session, bool p_public_visible);

	// Drains dirty facts accumulated since the last call into
	// `change_tracker()`, at most one `ChangeTracker::commit_change` call per
	// audience (task 1.3: "advance happens at most once per commit"). Every
	// mutating entry point this class defines already calls this itself,
	// immediately after its own `notification_queue().dispatch()` -- a
	// caller that exclusively uses THOSE entry points never needs to call
	// this. It is public only for the caller who instead drives this
	// component's `attributes()`/`tags()`/`effects()` directly through their
	// OWN `Transaction` and calls `notification_queue().dispatch()`
	// themselves (the same low-level escape hatch existing test helpers use,
	// e.g. `initialize_health`/`add_target_tag` in ga_test_targeting.cpp) --
	// that caller must call this immediately afterward for those changes to
	// reach the ledger, exactly as they already must call this class's own
	// (private) `flush_tag_reactions` equivalent to observe reaction edges
	// from such a call. Idempotent/cheap when nothing is pending (see
	// `ChangeTracker::commit_change`'s own empty-input no-op).
	void flush_change_tracking();

	// -----------------------------------------------------------------
	// Tag reactions (tasks 4.1-4.6)
	// -----------------------------------------------------------------

	// True iff this component was constructed with a sealed
	// `TagReactionRegistry` AND holds an authority role -- see the
	// constructor's own doc comment. When false, every method below is a
	// harmless no-op/empty-read; no tag-change observer is registered.
	bool tag_reactions_enabled() const { return reactions_enabled; }

	// Task 4.1's "(re)initialize baselines from current container state
	// WITHOUT emitting edges": (re)computes every registered reaction
	// operand's effective-truth baseline directly from THIS component's
	// current `tags()` state, discards any not-yet-dispatched accumulated
	// tag changes, and never enqueues or dispatches a single edge. Called
	// once internally at construction (baselining an empty container to all
	// "false"); a caller restoring tag state some other way (section 5's
	// snapshot restore, out of this task's scope) calls this again
	// afterward so the FIRST real post-restore transaction diffs against the
	// restored truth, not a stale pre-restore baseline (design.md decision 6:
	// "restore also reinitializes every reaction operand's truth baseline
	// from the restored tag state"). A no-op if `!tag_reactions_enabled()`.
	void reinitialize_tag_reaction_baselines();

	// Every currently active `WHILE_PRESENT` binding, ascending by reaction
	// `DefinitionId` (canonical order). Empty if `!tag_reactions_enabled()`.
	std::vector<TagReactionBinding> active_tag_reaction_bindings() const;

	// Task 5.3's core setter: RESTORE PATH ONLY (see `restore_snapshot`'s own
	// call site, the only intended caller besides a test exercising this
	// method directly). Validates `p_bindings` as a whole BEFORE installing
	// any of it -- matching the "Snapshot contains an invalid reaction
	// binding" scenario's "bounded snapshot validation rejects it before
	// partial restoration" -- then wholesale-replaces `while_present_bindings`
	// in one shot. Rejects (leaving `while_present_bindings` COMPLETELY
	// unchanged) if any entry:
	//   - names a reaction this component has no sealed registry for, or that
	//     is absent from it -- `StatusCode::UNKNOWN_DEFINITION` /
	//     `DiagnosticId::INVALID_REACTION_BINDING`, `detail == p_bindings[i].reaction`.
	//   - names a reaction whose registered mode is not `WHILE_PRESENT` (only
	//     a `WHILE_PRESENT` reaction can ever have bound a handle -- task
	//     4.4) -- `StatusCode::INVALID_REFERENCE` / `DiagnosticId::INVALID_REACTION_BINDING`.
	//   - names a handle `effects()` does not currently recognize as active --
	//     `StatusCode::UNKNOWN_EFFECT_HANDLE` / `DiagnosticId::INVALID_REACTION_BINDING`,
	//     `detail == p_bindings[i].handle.value`.
	//   - names a handle whose active effect's definition does not match that
	//     reaction's OWN registered target effect -- `StatusCode::INVALID_REFERENCE` /
	//     `DiagnosticId::INVALID_REACTION_BINDING`.
	//   - repeats a reaction id already validated earlier in `p_bindings` --
	//     `StatusCode::DECODE_FAILED` / `DiagnosticId::INVALID_ENUM` (mirrors
	//     `TagContainer::restore_snapshot`'s own "reject a non-canonical/
	//     duplicate entry" stance -- a well-formed snapshot never encodes a
	//     reaction bound twice).
	// Validates against `effects()`'s CURRENT state, so the caller must
	// restore effects BEFORE calling this (see `restore_snapshot`'s own
	// section ordering). Never emits a `TagReactionDiagnosticEvent`,
	// applies/removes an effect, or touches `reaction_truth_baseline` -- a
	// caller (this file's own `restore_snapshot`) calls
	// `reinitialize_tag_reaction_baselines()` SEPARATELY, once, after every
	// restored section (tags included) has committed, so the baseline
	// reflects the FULLY restored state rather than a partial one (design.md
	// decision 6). `p_bindings.empty()` unconditionally clears
	// `while_present_bindings` and succeeds -- the overwhelmingly common case
	// (a component with no active `WHILE_PRESENT` bindings, or none at all)
	// never needs a `reaction_registry` to restore correctly.
	Status restore_tag_reaction_bindings(const std::vector<TagReactionBinding> &p_bindings);

	void add_tag_reaction_diagnostic_listener(TagReactionDiagnosticListener p_listener);

	// -----------------------------------------------------------------
	// Owner teardown seam (see file comment; model matches
	// addons/common_ui/native/core/cu_handler_invoker.h's `is_owner_valid`).
	// The Godot adapter calls `queue_teardown` from the owning Node's
	// predelete/tree-exiting notification instead of ever letting this core
	// object outlive (or be asked to dereference) a freed scene object --
	// this core never holds a scene pointer at all, so the guarantee is
	// structural, not just documented.
	// -----------------------------------------------------------------

	bool is_owner_valid() const { return owner_alive; }
	bool is_torn_down() const { return torn_down; }

	// Marks the owner freed and deterministically cancels every active
	// execution (reason `OWNER_TEARDOWN`). Idempotent: a second call is a
	// no-op returning `ok_status()`. Deferred like every other mutating
	// entry point if called while a dispatch is already in progress.
	Status queue_teardown(Tick p_tick);

	// -----------------------------------------------------------------
	// Hook binding
	// -----------------------------------------------------------------

	// `p_hook` must outlive this component (or be unbound before it is
	// destroyed -- pass `nullptr` to unbind). Fails with
	// `StatusCode::UNKNOWN_ABILITY` if `p_ability` is not sealed, or
	// `StatusCode::INVALID_ARGUMENT` if the definition's `hook_binding`
	// does not name this hook kind.
	Status bind_authority_hook(DefinitionId p_ability, AuthorityAbilityHook *p_hook);

	// As above, but additionally runs `validate_prediction_safe_hook` and
	// rejects a nonconforming hook with `StatusCode::PREDICTION_NOT_SAFE`
	// before binding it (the "Prediction-safe hook uses non-deterministic
	// input" scenario).
	Status bind_prediction_safe_hook(DefinitionId p_ability, PredictionSafeAbilityHook *p_hook);

	// -----------------------------------------------------------------
	// Grants (task 6.2)
	// -----------------------------------------------------------------

	Status grant_ability(DefinitionId p_ability, std::int32_t p_level, const std::string &p_input_id,
			Tick p_tick, AbilitySpecId &r_spec, ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);
	Status revoke_ability(AbilitySpecId p_spec, Tick p_tick, ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	bool has_grant(AbilitySpecId p_spec) const;
	const AbilityGrant *find_grant(AbilitySpecId p_spec) const;
	std::vector<AbilitySpecId> granted_specs() const; // ascending AbilitySpecId (== stable spec order)

	// -----------------------------------------------------------------
	// Activation (tasks 6.3, 6.4, 6.5)
	// -----------------------------------------------------------------

	// Immediate path: processes `p_request` right away UNLESS called
	// reentrantly (see file comment), in which case it is deferred and
	// `ActivationResult{ queued = true }` is returned immediately.
	ActivationResult request_activation(const ActivationRequest &p_request, Tick p_tick);

	// Batched path for the "two eligible requests share a tick" scenario:
	// sorts `p_requests` by `(command_sequence, spec)` ascending (stable)
	// and processes each through the identical internal path
	// `request_activation` uses, returning results in that deterministic
	// processing order.
	std::vector<ActivationResult> process_activation_batch(const std::vector<ActivationRequest> &p_requests, Tick p_tick);

	// Explicit commit for an execution sitting in `BEGUN` phase (an ability
	// definition with `auto_commit == false`). Revalidates every commit-time
	// requirement and atomically applies cost, cooldown, owned tags, and
	// declared/hook-applied effects in one transaction.
	//
	// `r_pending_remote_effects`, if non-null, receives every
	// `PendingRemoteEffectCommand` this commit produced (see that struct's
	// doc comment) -- the explicit-commit path's equivalent of
	// `ActivationResult::pending_remote_effects`, since this method returns a
	// plain `Status` rather than a full result struct. Passing `nullptr`
	// (the default) is a caller's explicit choice to not receive them; if the
	// commit produces any anyway, a `PENDING_REMOTE_EFFECT_DROPPED`
	// diagnostic fires (see `AbilityDiagnosticKind`) so that choice is never
	// silently wrong.
	Status commit_activation(ExecutionId p_execution, Tick p_tick,
			std::vector<PendingRemoteEffectCommand> *r_pending_remote_effects = nullptr);

	// Evaluates every non-revoked grant whose ability declares a
	// GAMEPLAY_EVENT trigger matching `p_event.event_tag`, in stable spec
	// order (ascending `AbilitySpecId`), each receiving the SAME immutable
	// `p_event`. Bounded by `MAX_EVENT_RECURSION`: an event chain (a
	// triggered ability's hook emitting a further `EMIT_GAMEPLAY_EVENT`
	// command) beyond that depth fails the remaining links with
	// `StatusCode::RECURSION_LIMIT` while every already-committed
	// transaction from earlier links stays valid.
	Status handle_gameplay_event(const GameplayEventContext &p_event, Tick p_tick);

	// -----------------------------------------------------------------
	// Deterministic execution-owned ability tasks
	// -----------------------------------------------------------------

	AbilityTaskStartResult start_ability_task(ExecutionId p_execution,
			const AbilityTaskRequest &p_request, Tick p_tick,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE,
			AbilityTaskHandle p_reserved_handle = INVALID_ABILITY_TASK_HANDLE);
	AbilityTaskTransitionResult cancel_ability_task(AbilityTaskHandle p_task, Tick p_tick,
			AbilityTaskCancelReason p_reason = AbilityTaskCancelReason::EXPLICIT,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);
	AbilityTaskTransitionResult submit_logical_input(
			const AbilityTaskLogicalInputCommand &p_command, Tick p_tick,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);
	AbilityTaskTransitionResult complete_target_task(
			AbilityTaskHandle p_task, TargetSessionId p_session, Tick p_tick,
			Status p_status = ok_status(),
			const TargetEffectContext *p_context = nullptr);
	Status acknowledge_task_authority(PredictionKey p_prediction_key, Tick p_tick);
	void notify_restored_ability_tasks(Tick p_tick);
	void add_ability_task_listener(std::function<void(const AbilityTaskEvent &, NotificationQueue &)> p_listener);

	// -----------------------------------------------------------------
	// Task 6.13 -- applying a PendingRemoteEffectCommand on its real target
	// -----------------------------------------------------------------

	// MUST be called on the `AbilityComponent` whose `entity() ==
	// p_command.target` -- i.e. the caller (network/game layer) resolves the
	// target entity to ITS OWN component and calls this on THAT instance,
	// never on the originating component. Fails, before any mutation, with:
	//   - `StatusCode::ROLE_VIOLATION` if THIS component is not an authority
	//     role (`OFFLINE_AUTHORITY`/`SERVER_AUTHORITY`). A remote-target
	//     effect is never predicted (task 8.4 keeps remote-target effects
	//     server-only), so this call is UNCONDITIONALLY treated as
	//     `ChangeProvenance::AUTHORITATIVE` regardless of
	//     `p_command.provenance` -- a `NETWORK_CLIENT` target component
	//     structurally cannot be driven through this path no matter what a
	//     caller puts in `p_command`.
	//   - `StatusCode::CAPABILITY_VIOLATION` / `DiagnosticId::TARGET_NOT_RELEVANT`
	//     if `p_command.target != entity()` -- a caller cannot apply a
	//     command against the wrong component by mistake.
	//   - whatever `EffectRuntime::apply` itself fails with otherwise (unknown
	//     effect, requirements not met, immune, capacity) -- this method adds
	//     no new gameplay rule; it only adds the missing "who may call this
	//     and on what" boundary.
	//
	// `p_source_attributes`/`p_source_tags`, exactly like
	// `EffectRuntime::apply`'s own parameters of the same name, are the
	// ORIGINATING entity's read-only state (e.g. the originating component's
	// own `attributes()`/`tags()`) -- pass `nullptr` for either if the caller
	// has none available (a magnitude declaration that then needs a live
	// source-attribute read fails exactly as `apply` already documents for a
	// null source).
	//
	// Commits as its OWN independent, atomic `Transaction` scoped to THIS
	// component only -- seeing this command's effect applied is never
	// bundled with the ORIGINATING component's own commit into one
	// cross-component atomic unit (this addon's `Transaction` type is
	// intentionally single-component; see design.md and this method's own
	// report). What IS guaranteed: this call's own mutation (attribute/tag/
	// effect state on `entity()`) either fully commits or fully rolls back,
	// exactly like every other mutating entry point in this file.
	Status apply_remote_effect(const PendingRemoteEffectCommand &p_command, Tick p_tick,
			const AttributeSet *p_source_attributes, const TagContainer *p_source_tags, EffectHandle &r_handle);

	// Read-only preflight twin of `apply_remote_effect` (task 6.14 -- see
	// `EffectRuntime::preflight_apply`'s own doc comment for the full
	// atomicity-policy motivation). Runs the EXACT SAME "who may call this
	// and on what" checks `apply_remote_effect` runs, in the same order --
	// `StatusCode::ROLE_VIOLATION` if this component is not an authority role
	// (a remote-target effect is ALWAYS authoritative regardless of
	// `p_command.provenance`, exactly like `apply_remote_effect` itself), then
	// `StatusCode::CAPABILITY_VIOLATION`/`DiagnosticId::TARGET_NOT_RELEVANT`
	// if `p_command.target != entity()` -- and then delegates the
	// effect-spec-level checks to `EffectRuntime::preflight_apply`. Commits no
	// `Transaction`, allocates no handle, and (unlike its mutating twin) never
	// touches `last_known_tick` -- this is a const, side-effect-free query.
	// Advisory only: see `EffectRuntime::preflight_apply` for exactly what
	// `ok_status()` does and does not promise.
	Status preflight_remote_effect(const PendingRemoteEffectCommand &p_command, Tick p_tick,
			const AttributeSet *p_source_attributes, const TagContainer *p_source_tags) const;
	Status prepare_remote_effect(
			const PendingRemoteEffectCommand &p_command, Tick p_tick,
			const AttributeSet *p_source_attributes,
			const TagContainer *p_source_tags,
			PreparedEffectApplication &r_prepared) const;

	// Lower-level multi-component transaction seam used only by the typed
	// targeting coordinator. Unlike `apply_remote_effect`, these methods do
	// not commit or dispatch per call: one transaction accumulates every
	// effect for this component, then all participants are committed and
	// published together.
	Status begin_prepared_effect_mutation(Tick p_tick,
			PreparedAbilityComponentMutation &r_mutation);
	Status apply_prepared_effect(
			const PreparedEffectApplication &p_prepared, Tick p_tick,
			const AttributeSet *p_source_attributes,
			const TagContainer *p_source_tags,
			PreparedAbilityComponentMutation &p_mutation,
			EffectHandle &r_handle);
	bool can_commit_prepared_effect_mutation(
			const PreparedAbilityComponentMutation &p_mutation) const;
	Status commit_prepared_effect_mutation(
			PreparedAbilityComponentMutation &p_mutation);
	Status rollback_prepared_effect_mutation(
			PreparedAbilityComponentMutation &p_mutation);

	// -----------------------------------------------------------------
	// Ending & cancellation (task 6.7)
	// -----------------------------------------------------------------

	// Explicit successful completion of an ACTIVE execution.
	Status end_execution(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE);

	// Idempotent: the FIRST valid call transitions the execution to
	// CANCELLED and cleans up its owned tags/effects atomically; a later
	// call (or a call naming an already-ended execution) returns
	// `StatusCode::ABILITY_ALREADY_ENDED` and changes nothing. Never
	// cancels any OTHER execution. `p_reason` is the seam a network/
	// prediction bridge names the cause through (e.g. `AUTHORITY_CORRECTION`
	// when reconciling a rejected predicted activation); the resulting
	// `AbilityLifecycleEvent::end_reason` carries it, and `prediction_key`
	// carries the execution's own prediction identity so observers can tie
	// the correction back to it.
	CancellationResult cancel_execution(ExecutionId p_execution, Tick p_tick,
			ChangeProvenance p_provenance = ChangeProvenance::AUTHORITATIVE,
			ExecutionEndReason p_reason = ExecutionEndReason::EXPLICIT_CANCEL);

	bool has_execution(ExecutionId p_execution) const;
	const ActiveExecution *find_execution(ExecutionId p_execution) const;
	std::vector<ExecutionId> active_executions() const; // ascending ExecutionId

	// -----------------------------------------------------------------
	// Tick driver
	// -----------------------------------------------------------------

	// Drives `effects().advance_to(p_tick, ...)` (expiration/periodic
	// execution, which also naturally clears an expired cooldown's
	// authoritative handle via this component's own internal effect
	// lifecycle listener) and drains any reentrant pending requests.
	Status advance_to(Tick p_tick);

	// -----------------------------------------------------------------
	// Signals
	// -----------------------------------------------------------------

	void add_ability_listener(AbilityLifecycleListener p_listener);
	void add_diagnostic_listener(AbilityDiagnosticListener p_listener);

	// Pass-through convenience so a caller does not need to reach into
	// `attributes()`/`tags()`/`effects()` separately to observe the
	// existing record types (task 6.8: "Reuse the effect/attribute/tag
	// record types where they already exist").
	void add_effect_lifecycle_listener(EffectLifecycleListener p_listener) { effect_runtime.add_lifecycle_listener(std::move(p_listener)); }
	void add_effect_cue_listener(EffectCueListener p_listener) { effect_runtime.add_cue_listener(std::move(p_listener)); }
	void add_tag_listener(TagChangeListener p_listener) { tag_container.add_listener(std::move(p_listener)); }
	void add_attribute_listener(std::function<void(const AttributeChangeRecord &, NotificationQueue &)> p_listener) { attribute_set.add_listener(std::move(p_listener)); }

	// -----------------------------------------------------------------
	// Canonical snapshots
	// -----------------------------------------------------------------

	// Composes, in one outer section: entity/role identity, then (nested)
	// `attributes().write_snapshot`, `tags().write_snapshot`,
	// `effects().write_snapshot` (each already self-contained, per their own
	// files' conventions), then (task 5.3) this component's active
	// `WHILE_PRESENT` reaction bindings (`active_tag_reaction_bindings()`,
	// canonical order -- empty, and cheap, for a component with no reactions
	// or none currently bound), then this file's own grants and executions
	// sections, then (spec "Task Snapshot Visibility and Restore")
	// `task_runtime.write_snapshot()`. `p_task_audience` is forwarded
	// unchanged to that call -- it never touches the sections above, which
	// have no owner/observer visibility split of their own. Defaults to
	// `INTERNAL` (every task included) so every pre-existing caller (local
	// persistence, digest/consistency checks, rollback baselines on
	// authority) is unaffected; a network bridge encoding a wire snapshot for
	// a specific remote peer must pass that peer's own role-appropriate
	// audience instead (see `AbilityTaskVisibility`/`task_visible_to`) so an
	// owner-only or observer-only peer is never handed INTERNAL task state.
	//
	// `p_target_context_audience` is likewise forwarded unchanged to
	// `effects().write_snapshot()` (see that method's own doc comment): it
	// governs ONLY retained `TargetEffectContext` values inside the effects
	// section and defaults to `INTERNAL` (full fidelity, matching every
	// pre-existing caller). The same network bridge passes that peer's
	// audience here too, alongside `p_task_audience`.
	Status write_snapshot(SnapshotWriter &p_writer,
			AbilityTaskVisibility p_task_audience = AbilityTaskVisibility::INTERNAL,
			TargetResultVisibility p_target_context_audience = TargetResultVisibility::INTERNAL) const;

	// Replaces this component's ENTIRE state (attributes, tags, effects,
	// reaction bindings, grants, executions, and every internal allocator)
	// from a previously written snapshot, restoring section by section:
	// attributes, then tags, then effects, then (task 5.3) reaction bindings
	// (validated against the just-restored `effects()` and this component's
	// own sealed `reaction_registry` via `restore_tag_reaction_bindings` --
	// see that method's own doc comment for the full validate-before-install
	// contract and the "Snapshot contains an invalid reaction binding"
	// scenario it enforces), then this file's own grants/executions. Finally,
	// once every section above has committed, calls
	// `reinitialize_tag_reaction_baselines()` exactly once so the FIRST
	// post-restore transaction diffs every reaction operand against the
	// restored tag state instead of a stale pre-restore baseline (design.md
	// decision 6; specs/gameplay-ability-networking/spec.md "First
	// transaction after restore") -- this is the ONE place that call is
	// required, since every restore path in this addon (plain restore,
	// rollback-on-failure, and `PredictionReconciler::reconcile`) converges
	// on THIS method. EACH section individually decodes into local
	// temporaries first and only swaps them into ITS OWN live state once ITS
	// OWN decoding fully succeeds -- but that atomicity is per-SECTION, not
	// whole-component: a failure on a LATER section (e.g. effects) does NOT
	// undo an EARLIER section (e.g. attributes) that already committed, so a
	// non-OK return here can leave this component in inconsistent MIXED
	// state across those section boundaries. See
	// `restore_snapshot(SnapshotReader&)`'s own definition comment for
	// exactly which sections build into temporaries and commit at their own
	// tail. Never invokes a hook or emits any lifecycle/cue event or
	// notification -- matching every sibling subsystem's `restore_snapshot`.
	// A caller that wants an observable "this execution was restored" signal
	// calls `make_snapshot_restored_event` explicitly afterward and
	// dispatches it itself.
	//
	// Whole-component ATOMIC replacement (never leave mixed state installed)
	// is enforced one layer up, not here: `native/godot/
	// gameplay_ability_component.cpp`'s `GameplayAbilityComponent::
	// restore_snapshot`/`reconcile_snapshot` capture this component's
	// pre-restore state via `write_snapshot()` first and roll back to it (or
	// quarantine the Godot-level wrapper if even that fails) on a non-OK
	// result from THIS method -- see that pair's own doc comments for the
	// full rollback-then-quarantine contract. A caller at THIS core layer
	// with no such wrapper (there is none in `native/core/` itself) must
	// still treat any non-OK result as "this component may be mid-mixed-
	// state" and discard/rebuild it, exactly as documented here.
	Status restore_snapshot(SnapshotReader &p_reader);

	AbilityLifecycleEvent make_snapshot_restored_event(const ActiveExecution &p_execution, Tick p_tick) const;

	// -----------------------------------------------------------------
	// Canonical delta codec
	// (add-granular-delta-replication-2026-07-27, task 2.1-2.4)
	// -----------------------------------------------------------------
	//
	// This section's public surface splits into three layers, matching
	// `ga_delta.h`'s own file comment:
	//   - per-record codecs for the two sections THIS class owns directly
	//     (ABILITY_GRANT, ACTIVE_EXECUTION) -- `write_grant_delta_record`/
	//     `decode_grant_delta_record` and their execution counterparts,
	//     mirroring `AttributeSet`/`TagContainer`/`EffectRuntime`/
	//     `AbilityTaskRuntime`'s own equivalents;
	//   - whole-section filtered/unfiltered re-encode + pure decode pairs
	//     for the SAME two sections' `DeltaSectionMode::FULL_REENCODE`
	//     fallback (`write_grants_section`/`decode_grants_section`,
	//     `write_executions_section`/`decode_executions_section`);
	//   - the top-level composer/applier (`write_delta_batch`/
	//     `apply_delta_batch`) that assembles/consumes ALL SEVEN canonical
	//     sections (delegating the five it does not own directly to
	//     `attributes()`/`tags()`/`effects()`/`ability_tasks()`'s own
	//     equivalents, and TARGET_SESSION to an optional
	//     `GameplayAbilityWorldCoordinator*`).

	// Task 2.1's per-record delta body for the ABILITY_GRANT section: the
	// SAME fields `write_snapshot`'s own per-grant entry writes, in the SAME
	// order. Fails, without writing anything, if `p_spec` is not currently
	// granted.
	Status write_grant_delta_record(SnapshotWriter &p_writer, AbilitySpecId p_spec) const;

	// Decodes one record `write_grant_delta_record` wrote, WITHOUT touching
	// live state: fails closed on an unregistered ability, matching
	// `restore_snapshot`'s own per-entry validation.
	Status decode_grant_delta_record(SnapshotReader &p_reader, AbilityGrant &r_grant) const;

	// Same section shape `write_snapshot` writes for its
	// `GA_SNAPSHOT_KIND_ABILITY_GRANTS` section (identical framing and
	// ascending-`AbilitySpecId` order, decodable by `decode_grants_section`
	// below), restricted to grants whose `ability` passes `p_is_public`.
	// The delta codec's OWNER-audience `DeltaSectionMode::FULL_REENCODE`
	// fallback passes a predicate that always returns true.
	Status write_grants_section(SnapshotWriter &p_writer, const std::function<bool(DefinitionId)> &p_is_public) const;

	// The pure-decode counterpart of `write_grants_section` -- reads a
	// COMPLETE `GA_SNAPSHOT_KIND_ABILITY_GRANTS` section into `r_grants`
	// WITHOUT installing anything (see `AttributeSet::decode_snapshot_section`'s
	// doc comment for why this split exists).
	Status decode_grants_section(SnapshotReader &p_reader, std::map<AbilitySpecId, AbilityGrant> &r_grants) const;

	// Task 2.1's per-record delta body for the ACTIVE_EXECUTION section: the
	// SAME fields `write_snapshot`'s own per-execution entry writes, in the
	// SAME order. Fails, without writing anything, if `p_execution` is not
	// currently active. ACTIVE_EXECUTION has no PUBLIC exposure today (see
	// `AudienceVisibilityConfig`'s own comment), so unlike grants there is
	// no filtered writer -- every caller of this codec only ever builds an
	// ACTIVE_EXECUTION section for the OWNER audience.
	Status write_execution_delta_record(SnapshotWriter &p_writer, ExecutionId p_execution) const;

	// Decodes one record `write_execution_delta_record` wrote, WITHOUT
	// touching live state: fails closed on an unregistered ability or an
	// out-of-range `ExecutionPhase`/`ChangeProvenance`, matching
	// `restore_snapshot`'s own per-entry validation.
	Status decode_execution_delta_record(SnapshotReader &p_reader, ActiveExecution &r_execution) const;

	// Same section shape `write_snapshot` writes for its
	// `GA_SNAPSHOT_KIND_ABILITY_EXECUTIONS` section (identical framing and
	// ascending-`ExecutionId` order, decodable by `decode_executions_section`
	// below). Unfiltered -- see `write_execution_delta_record`'s own
	// comment on why this section has no PUBLIC variant.
	Status write_executions_section(SnapshotWriter &p_writer) const;

	// The pure-decode counterpart of `write_executions_section`.
	Status decode_executions_section(SnapshotReader &p_reader, std::map<ExecutionId, ActiveExecution> &r_executions) const;

	// Task 2.1: builds ONE canonical delta batch payload for `p_audience` --
	// an ordered list of section deltas covering every `ChangeSection` with
	// at least one `p_audience`-visible dirty identity in `p_dirty`
	// (ascending `ChangeSection` order, TARGET_SESSION last -- see
	// ga_ability_component.cpp for why). `p_dirty` is normally
	// `change_tracker().dirty_since(p_audience, <peer's last-confirmed
	// revision>)` (that method's own doc comment documents the
	// `cursor_overflowed` precondition a caller must check first);
	// `p_baseline` labels each touched, still-live identity ADD vs. UPDATE
	// (see `DeltaBaseline`'s own comment -- an empty baseline is always
	// safe, if less informative). Each section independently applies task
	// 2.2's deterministic `choose_delta_section_mode` rule. A section with
	// no `p_audience`-visible dirty identities is OMITTED entirely -- an
	// idle section costs zero bytes. `p_session_coordinator`, if non-null,
	// supplies the TARGET_SESSION section's content
	// (`GameplayAbilityWorldCoordinator::write_snapshot`, owner-filtered to
	// `entity()`) for any TARGET_SESSION identity in `p_dirty`; a null
	// coordinator with a dirty TARGET_SESSION identity fails closed rather
	// than silently omitting that section.
	Status write_delta_batch(SnapshotWriter &p_writer, ChangeAudience p_audience,
			const std::vector<DirtyRecord> &p_dirty, const DeltaBaseline &p_baseline,
			const GameplayAbilityWorldCoordinator *p_session_coordinator = nullptr) const;

	// Task 2.3/2.4: decodes AND applies a delta batch `write_delta_batch`
	// wrote onto THIS component's current (confirmed-baseline) state,
	// exactly like `restore_snapshot` -- no gameplay hook, cue, or
	// notification fires (same "restore without replay" contract; see
	// `restore_snapshot`'s own doc comment). Decoding is untrusted input:
	// an unknown section kind, an unknown op kind, an out-of-bound record-op
	// count, an invalid record identity, or a malformed record body fails
	// closed with the SAME bounded diagnostics each section's own snapshot
	// decoder already uses.
	//
	// Validation-then-mutation: every ChangeSection this class owns
	// directly (ATTRIBUTE, TAG_SOURCE, ABILITY_GRANT, ACTIVE_EXECUTION,
	// ACTIVE_EFFECT, ABILITY_TASK) is fully decoded and validated into a
	// local temporary -- including ABILITY_TASK's cross-section parent
	// (execution/spec/ability) check against this SAME batch's
	// not-yet-installed grant/execution content -- BEFORE any of the six is
	// installed onto `this`; a batch with NO TARGET_SESSION section keeps
	// the full guarantee: a failure on any one of the six leaves every one
	// of them untouched. TARGET_SESSION, if present, is applied LAST (it
	// sorts last in ascending `ChangeSection` order) via
	// `p_session_coordinator->restore_owner_snapshot` -- a null coordinator
	// with a TARGET_SESSION section present fails closed before touching
	// the six sections above. `restore_owner_snapshot` validates each
	// session against THIS component's LIVE execution/task state (a
	// referential check, not a pure decode -- see ga_targeting.cpp), so the
	// six sections above are installed onto `this` immediately BEFORE
	// TARGET_SESSION is attempted, not deferred until after: a batch that
	// DOES carry a TARGET_SESSION section therefore installs its six other
	// sections even if TARGET_SESSION itself then fails. This mirrors how
	// full-state replication already keeps target-session restore as its
	// own top-level call, independent from component restore (see the
	// proposal's own "both receive full target-session state" wording);
	// TARGET_SESSION's own success/failure is never covered by the six
	// sections' validate-before-install guarantee, only sequenced after it.
	Status apply_delta_batch(SnapshotReader &p_reader, GameplayAbilityWorldCoordinator *p_session_coordinator = nullptr);

	// Prepared cross-component batch support. Publication holds keep all
	// listener/cue/task callbacks invisible until every participant has
	// committed. A failed batch restores both state and identity allocators,
	// then discards held records.
	Status capture_target_batch_state(AbilityComponentBatchCapture &r_capture) const;
	Status restore_target_batch_state(
			const AbilityComponentBatchCapture &p_capture);
	Status begin_target_batch_publication();
	Status commit_target_batch_publication(Tick p_tick);
	// Removes the innermost publication hold without dispatching any
	// pre-existing queued records. Used by authority-provider preparation,
	// where the hold is a read-only capability guard rather than a batch
	// publication boundary.
	Status release_target_batch_publication_hold();
	Status rollback_target_batch_publication();
	bool target_batch_publication_hold_changed() const;

private:
	Status check_role(ChangeProvenance p_provenance) const;
	TransactionId next_transaction_id() { return transaction_allocator.allocate(); }

	// -----------------------------------------------------------------
	// Canonical delta codec internals (task 2.1-2.4)
	// -----------------------------------------------------------------
	//
	// Each `decode_*_record_ops` helper implements `apply_delta_batch`'s
	// RECORD_OPS-mode decode for exactly one section: it starts from a COPY
	// of this component's CURRENT live content for that section (built by
	// round-tripping through that section's own `write_snapshot`/
	// `decode_snapshot_section` pair -- reusing the SAME encode/decode this
	// codec already trusts, rather than a second, independently maintained
	// "list everything" accessor), reads the op list (`GA_SNAPSHOT_KIND_
	// DELTA_RECORD_OP` entries, ascending identity, no duplicates), and
	// applies each op to that copy: REMOVE erases; ADD/UPDATE decode a
	// record body via that section's own per-record decoder and upsert it,
	// after cross-checking the record body's OWN embedded identity (where
	// the section's record shape carries one -- see
	// `AttributeSet::decode_attribute_delta_record`'s own doc comment)
	// against the op header's identity. Returns the merged copy WITHOUT
	// installing it -- exactly like a `FULL_REENCODE`-mode section's own
	// `decode_snapshot_section` call, so `apply_delta_batch` treats both
	// modes identically from this point on.
	Status decode_attribute_record_ops(SnapshotReader &p_reader,
			std::map<DefinitionId, AttributeValue> &r_attributes, std::vector<AttributeModifier> &r_modifiers) const;
	Status decode_tag_source_record_ops(SnapshotReader &p_reader,
			std::map<DefinitionId, std::set<SourceToken>> &r_owners, std::uint64_t &r_revision) const;
	Status decode_grant_record_ops(SnapshotReader &p_reader, std::map<AbilitySpecId, AbilityGrant> &r_grants) const;
	Status decode_execution_record_ops(SnapshotReader &p_reader, std::map<ExecutionId, ActiveExecution> &r_executions) const;
	Status decode_effect_record_ops(SnapshotReader &p_reader, std::map<EffectHandle, ActiveEffect> &r_effects) const;
	Status decode_task_record_ops(SnapshotReader &p_reader, std::map<AbilityTaskHandle, ActiveAbilityTask> &r_tasks) const;

	void drain_pending_requests(Tick p_tick);

	ActivationResult request_activation_immediate(const ActivationRequest &p_request, Tick p_tick, std::size_t p_event_depth,
			const GameplayEventContext *p_triggering_event = nullptr);
	// `r_pending_remote_effects`: see `commit_activation`'s own doc comment.
	// `request_activation_immediate`'s auto-commit call site always passes a
	// non-null pointer (straight into its own `ActivationResult`), so only
	// the explicit `commit_activation` path can ever pass `nullptr` here.
	Status commit_execution_immediate(ExecutionId p_execution, Tick p_tick, std::size_t p_event_depth,
			std::vector<PendingRemoteEffectCommand> *r_pending_remote_effects = nullptr);
	Status commit_execution_body(ActiveExecution &p_execution, AbilityGrant &p_grant, const AbilityDefinition &p_definition,
			Tick p_tick, Transaction &p_txn, std::vector<GameplayEventContext> &r_emitted_events,
			std::vector<PendingRemoteEffectCommand> &r_pending_remote_effects,
			std::vector<AbilityHookCommand> &r_post_commit_commands);
	Status end_execution_immediate(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance);
	CancellationResult cancel_execution_immediate(ExecutionId p_execution, Tick p_tick, ChangeProvenance p_provenance, ExecutionEndReason p_reason);
	Status handle_gameplay_event_internal(const GameplayEventContext &p_event, Tick p_tick, std::size_t p_depth);
	void enqueue_task_event(const AbilityTaskEvent &p_event);
	void enqueue_task_events(const std::vector<AbilityTaskEvent> &p_events);
	void dispatch_task_event(const AbilityTaskEvent &p_event);
	void apply_task_callback_commands(ExecutionId p_execution, std::vector<AbilityHookCommand> p_commands,
			Tick p_tick);
	void flush_task_tag_edges(Tick p_tick);

	AbilityExecutionContext build_execution_context(const ActiveExecution &p_execution, const AbilityGrant &p_grant,
			const AbilityDefinition &p_definition, Tick p_tick) const;

	// Best-effort, read-only affordability peek used both as begin's cost
	// preflight and commit's revalidation (see "Cost becomes insufficient
	// before commit" scenario -- the SAME real atomic apply happens only at
	// commit, via `EffectRuntime::apply`, which does not itself reject
	// insufficiency; this method is therefore the ONLY gate). Deliberately
	// scoped to `ModifierOp::ADD` declarations only (the overwhelmingly
	// common "cost N of attribute X" shape) and assumes a zero floor per
	// attribute (matching the common convention of declaring a spendable
	// resource with `has_min = true, min_value = 0`); a cost effect built
	// from MULTIPLY/OVERRIDE modifiers or targeting a non-zero-floor
	// attribute still applies exactly as declared at commit, it just is not
	// reasoned about by this preflight.
	Status check_cost_affordable(const EffectDefinition &p_cost_definition, std::int32_t p_level,
			const std::vector<SetByCallerMagnitude> &p_set_by_caller) const;

	void watch_cancel_tags();

	// -----------------------------------------------------------------
	// Per-audience change tracking
	// (add-granular-delta-replication-2026-07-27, tasks 1.1-1.4)
	// -----------------------------------------------------------------
	//
	// Mirrors `flush_tag_reactions`'s own established shape for the SAME
	// underlying problem (see that method's doc comment and
	// ga_change_tracking.h's class comment on `ChangeTracker`): listeners
	// installed once in the constructor, on every subsystem whose own
	// notification already only fires post-commit, accumulate already
	// audience-resolved dirty facts into `pending_owner_dirty_`/
	// `pending_public_dirty_` via `note_dirty`; `flush_change_tracking`,
	// called right after EVERY one of this class's own `queue.dispatch()`
	// call sites (never on its own), drains them into `change_tracker_` as
	// AT MOST one `ChangeTracker::commit_change` per audience -- so a commit
	// touching five attributes still advances OWNER_FACING exactly once
	// (task 1.3).

	// Registers the change-tracking listeners on `attributes()`/`tags()`/
	// `effects()`/ability-task notifications -- called once from the
	// constructor, unconditionally (unlike `watch_tag_reactions`, change
	// tracking is not opt-in: every component, on every role, keeps a
	// ledger).
	void watch_change_tracking();

	// Appends one already-resolved dirty fact to the pending accumulator(s)
	// for whichever audience(s) it is visible to. Called only from a
	// notification closure (i.e. only for state that has already committed
	// -- see the section comment above), never from a mutating call itself.
	void note_dirty(ChangeSection p_section, std::uint64_t p_identity, bool p_owner_visible, bool p_public_visible);

	// `note_dirty` specialized for one `AbilityLifecycleEvent`: GRANTED/
	// REVOKED mark ABILITY_GRANT (identity = spec, PUBLIC iff
	// `visibility_config_.ability_public(event.ability)`); PHASE_CHANGED/
	// COMMITTED/ENDED/CANCELLED mark ACTIVE_EXECUTION (identity = execution,
	// OWNER_FACING only -- see `AudienceVisibilityConfig`'s own comment on
	// why executions have no public exposure yet). REQUESTED, FAILED (no
	// persisted record changed), and SNAPSHOT_RESTORED (replays prior state,
	// not a new change) mark nothing.
	void note_ability_lifecycle_dirty(const AbilityLifecycleEvent &p_event);

	Status emit_ability_event(const AbilityLifecycleEvent &p_event, Transaction &p_txn);
	void emit_diagnostic(AbilityDiagnosticKind p_kind, AbilitySpecId p_spec, ExecutionId p_execution, Status p_status, Tick p_tick);
	// Reports `AbilityDiagnosticKind::TASK_FANOUT_TRUNCATED` -- see that
	// enumerator's own doc comment. Owner-wide (not tied to one execution),
	// so it uses the same `INVALID_ABILITY_SPEC_ID`/`INVALID_EXECUTION_ID`
	// convention `handle_gameplay_event_internal`'s own recursion-limit
	// diagnostic already uses.
	void emit_task_fanout_truncated(Tick p_tick);

	// -----------------------------------------------------------------
	// Tag reactions (tasks 4.1-4.6) -- see file comment for the queue/
	// reentrancy contract every method below relies on, and
	// `flush_tag_reactions`'s own doc comment for why the batch boundary is
	// tied to THIS class's own commit-and-dispatch call sites rather than to
	// `TagChangeRecord`/`TagContainer` revision boundaries.
	// -----------------------------------------------------------------

	// One resolved, immutable predicate-edge record for one reaction within
	// one committed tag transaction -- already carries the direction
	// decision (apply vs. release) so canonical sorting and dispatch never
	// re-derive it. `truth_now == true` means the operand went false->true
	// (the mode's "apply" action for ON_ADDED/WHILE_PRESENT); `false` means
	// true->false (the "apply" action for ON_REMOVED, the "release" action
	// for WHILE_PRESENT).
	struct TagReactionEdge {
		DefinitionId reaction_id = INVALID_DEFINITION_ID;
		bool truth_now = false;
	};

	// Registers the tag-change observer that feeds `pending_reaction_tags`.
	// Only called from the constructor, and only when `reactions_enabled`
	// (see that field's doc comment) -- "empty/absent registry or
	// non-authority role = zero overhead" (task 4.1/4.6) means this observer
	// is never installed at all in that case, not merely a no-op once
	// installed.
	void watch_tag_reactions();

	// Task 4.1/4.2: called once right after EVERY one of this class's own
	// commit-and-`queue.dispatch()` call sites (see each such call site's
	// own added call). By the time ANY of this transaction's
	// `TagChangeRecord`s reached `watch_tag_reactions`'s listener (during
	// THAT `dispatch()` call, which just returned), `tags()` already
	// reflects the transaction's FINAL state (`TagContainer::apply_mutations`
	// applies its whole batch before any of its notifications are even
	// queued, and nothing may mutate tags reentrantly from a tag
	// notification -- see ga_tag_container.h/ga_transaction.h) -- so tying
	// this flush to "right after dispatch() returns" (rather than trying to
	// detect a batch boundary from inside the per-record listener itself,
	// which `TagChangeRecord` carries no transaction identity to do
	// reliably) both (a) reads fully-final truth for every affected operand
	// and (b) enqueues this transaction's reaction-effect work, via
	// `queue.request_mutation`, strictly AFTER every blocking-tag
	// cancellation `watch_cancel_tags` queued from the SAME transaction
	// (which happened DURING that same `dispatch()` call) -- task 4.6's
	// "cancellation before reactions" ordering falls out of this placement
	// rather than needing a second explicit ordering mechanism.
	//
	// Computes old/new effective truth ONLY for `reactions->affected_reactions`
	// of `pending_reaction_tags` (the exact tags this transaction changed --
	// task 4.1's "overlapping sources and additional matching descendants
	// must NOT produce edges while the operand's truth is unchanged"),
	// updates `reaction_truth_baseline` for EVERY diffed operand immediately
	// (even one the chain bound below ends up dropping -- the underlying tag
	// transaction stays committed regardless, so the baseline must track
	// real truth unconditionally), then either:
	//   - emits one `CHAIN_LIMIT_REACHED` diagnostic and drops every edge, if
	//     `active_reaction_chain_depth >= max_reaction_chain_depth` (task 4.5);
	//   - or sorts surviving edges into canonical order (operand tag,
	//     EXACT-before-PARENT_AWARE, ON_REMOVED/ON_ADDED/WHILE_PRESENT,
	//     reaction identifier) and hands them to `queue.request_mutation`
	//     as ONE `dispatch_reaction_batch` closure carrying the CURRENT
	//     `active_reaction_chain_depth`/`active_reaction_chain_path` (task 4.2).
	// A no-op if `!reactions_enabled`, `torn_down` (task 4.6 teardown: never
	// even accumulate/diff, let alone dispatch), or `pending_reaction_tags`
	// is empty.
	void flush_tag_reactions(Tick p_tick);

	// Runs every edge in `p_edges` (already canonically sorted), each
	// through `dispatch_single_reaction_edge`, temporarily setting
	// `active_reaction_chain_depth`/`active_reaction_chain_path` to
	// `p_chain_depth + 1` / `p_chain_path + [this edge's reaction
	// identifier]` for the DURATION of that one edge's dispatch (restored
	// before the next sibling edge) -- so a tag transaction THAT edge's
	// effect application causes propagates the incremented depth/path into
	// its own `flush_tag_reactions` call, while independent sibling edges in
	// THIS batch each start their own subtree at the same `p_chain_depth + 1`
	// rather than accumulating across siblings. Discards the WHOLE batch
	// without applying anything if `torn_down` (task 4.6: "pending queued
	// reaction work is discarded without applying effects"), re-checked
	// before each edge since teardown could begin partway through.
	void dispatch_reaction_batch(std::vector<TagReactionEdge> p_edges, std::size_t p_chain_depth, std::vector<std::string> p_chain_path, Tick p_tick);

	// Applies (ON_ADDED/ON_REMOVED, or WHILE_PRESENT's false-to-true) or
	// removes (WHILE_PRESENT's true-to-false) `p_definition`'s target effect
	// from this component to itself exactly once, through the existing
	// atomic effect-transaction path (`effect_runtime.apply`/`remove_effect`,
	// each in their own `Transaction` + `queue.dispatch()`, immediately
	// followed by this class's own `flush_tag_reactions` so a tag change
	// THIS application causes is itself observed -- task 4.3/4.4). A failed
	// apply records one `APPLICATION_FAILED` diagnostic, creates nothing, and
	// -- for WHILE_PRESENT -- binds no handle (no continuous retry; a later
	// false-to-true edge may retry). A WHILE_PRESENT release whose bound
	// handle is no longer active (`!effect_runtime.has_effect(handle)`)
	// clears the stale binding with a `STALE_HANDLE_CLEARED` diagnostic
	// instead of attempting removal.
	void dispatch_single_reaction_edge(const TagReactionDefinition &p_definition, bool p_truth_now, Tick p_tick);

	void emit_tag_reaction_diagnostic(TagReactionDiagnosticKind p_kind, DefinitionId p_reaction, Status p_status, Tick p_tick, std::vector<std::string> p_reaction_path = {});

	const AbilityRegistry *ability_registry = nullptr;
	const EffectRegistry *effect_registry = nullptr;
	EntityId owner_entity = INVALID_ENTITY_ID;
	ComponentRole component_role = ComponentRole::OFFLINE_AUTHORITY;

	// Declaration order matters: `effect_runtime` holds references to
	// `attribute_set`/`tag_container` and must be constructed after them.
	AttributeSet attribute_set;
	TagContainer tag_container;
	AbilityTaskRuntime task_runtime;
	EffectRuntime effect_runtime;
	NotificationQueue queue;

	std::map<AbilitySpecId, AbilityGrant> grants;
	std::map<ExecutionId, ActiveExecution> executions;
	std::map<DefinitionId, AuthorityAbilityHook *> authority_hooks;
	std::map<DefinitionId, PredictionSafeAbilityHook *> prediction_hooks;

	HandleAllocator<AbilitySpecId> spec_allocator;
	HandleAllocator<ExecutionId> execution_allocator;
	HandleAllocator<TransactionId> transaction_allocator;
	HandleAllocator<GameplayEventId> event_allocator;
	HandleAllocator<SourceToken> owned_tag_source_allocator;

	std::vector<AbilityLifecycleListener> ability_listeners;
	std::vector<AbilityDiagnosticListener> diagnostic_listeners;
	std::vector<std::function<void(const AbilityTaskEvent &, NotificationQueue &)>> task_listeners;
	bool task_tag_state_dirty = false;

	// -----------------------------------------------------------------
	// Per-audience change tracking
	// (add-granular-delta-replication-2026-07-27, tasks 1.1-1.4)
	// -----------------------------------------------------------------
	ChangeTracker change_tracker_;
	AudienceVisibilityConfig visibility_config_;
	// Accumulated since the last `flush_change_tracking()` call by the
	// listeners `watch_change_tracking()` installs -- see that method and
	// `note_dirty`'s own doc comments.
	std::vector<DirtyRecord> pending_owner_dirty_;
	std::vector<DirtyRecord> pending_public_dirty_;

	// -----------------------------------------------------------------
	// Tag reactions (tasks 4.1-4.6)
	// -----------------------------------------------------------------
	const TagReactionRegistry *reaction_registry = nullptr;
	// Decided ONCE at construction: `reaction_registry != nullptr &&
	// reaction_registry->sealed() && component_role is an authority role`
	// (task 4.6). See the constructor's own doc comment.
	bool reactions_enabled = false;
	std::size_t max_reaction_chain_depth = MAX_REACTION_CHAIN_DEPTH;

	// Exact tag ids the CURRENT (in-flight) committed transaction changed,
	// accumulated by the listener `watch_tag_reactions` installs and
	// consumed by `flush_tag_reactions` right after that transaction's own
	// `dispatch()` call returns -- see that method's own doc comment for why
	// this pairing is safe without a `TagChangeRecord`-carried transaction
	// identity.
	std::set<DefinitionId> pending_reaction_tags;
	// Per-reaction-operand effective-truth baseline (task 4.1), keyed by
	// `TagReactionDefinition::id`. Absent == not yet baselined (treated as
	// `false`, matching a fresh/empty `TagContainer`); every entry a sealed
	// `reaction_registry` names is populated by `reinitialize_tag_reaction_
	// baselines` before any real diff can run.
	std::map<DefinitionId, bool> reaction_truth_baseline;
	// Active `WHILE_PRESENT` bindings (task 4.4), keyed by
	// `TagReactionDefinition::id`. `std::map` iterates ascending == canonical
	// order for `active_tag_reaction_bindings()`.
	std::map<DefinitionId, EffectHandle> while_present_bindings;

	std::vector<TagReactionDiagnosticListener> tag_reaction_diagnostic_listeners;

	// Task 4.5: the chain depth/path a reaction edge currently being
	// dispatched (inside `dispatch_reaction_batch`) is running at; `0`/empty
	// while no reaction edge is on the call stack (a top-level, non-reaction
	// -caused transaction's own `flush_tag_reactions` call reads these as its
	// new batch's depth/path, unincremented). Save/restored around each
	// sibling edge in `dispatch_reaction_batch` -- see that method's doc
	// comment.
	std::size_t active_reaction_chain_depth = 0;
	std::vector<std::string> active_reaction_chain_path;

	bool owner_alive = true;
	bool torn_down = false;
	bool draining = false;
	// Stamped by every public mutating entry point so the cancel-tags
	// watcher (which reacts to a `TagChangeRecord` that carries no tick of
	// its own) has a tick to pass to a deferred cancellation.
	Tick last_known_tick = 0;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_ABILITY_COMPONENT_H
