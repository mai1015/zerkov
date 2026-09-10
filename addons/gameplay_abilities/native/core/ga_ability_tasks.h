#ifndef GAMEPLAY_ABILITIES_CORE_ABILITY_TASKS_H
#define GAMEPLAY_ABILITIES_CORE_ABILITY_TASKS_H

#include "core/ga_attribute_state.h"
#include "core/ga_fixed.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_tag_container.h"
#include "core/ga_tag_query.h"
#include "core/ga_tags.h"
#include "core/ga_target_types.h"
#include "core/ga_tick.h"

#include <cstdint>
#include <functional>
#include <map>
#include <set>
#include <vector>

namespace ga {

// Closed, wire-versioned v1 task set. WAIT_TARGET_DATA is implemented by the
// typed-targeting layer but deliberately shares this lifecycle and identity.
enum class AbilityTaskKind : std::uint8_t {
	WAIT_TICKS = 0,
	WAIT_GAMEPLAY_EVENT = 1,
	WAIT_TAG_QUERY = 2,
	WAIT_LOGICAL_INPUT = 3,
	WAIT_AUTHORITY = 4,
	WAIT_TARGET_DATA = 5,
};

enum class AbilityTaskOutcome : std::uint8_t {
	ACTIVE = 0,
	COMPLETED = 1,
	FAILED = 2,
	TIMED_OUT = 3,
	CANCELLED = 4,
};

enum class AbilityTaskCancelReason : std::uint8_t {
	NONE = 0,
	EXPLICIT = 1,
	PARENT_ENDED = 2,
	PARENT_CANCELLED = 3,
	SPEC_REVOKED = 4,
	OWNER_TEARDOWN = 5,
	AUTHORITY_CORRECTION = 6,
	TARGET_SESSION_CANCELLED = 7,
};

enum class AbilityTaskVisibility : std::uint8_t {
	OWNER_ONLY = 0,
	OBSERVABLE = 1,
	INTERNAL = 2,
};

// The one audience filter every task-state encoder evaluates against a
// task's own authored `AbilityTaskRequest::visibility` -- the core snapshot
// section (`AbilityTaskRuntime::write_snapshot`), the standalone `TASK_STATE`
// DTO codec (`gap_task_messages.cpp`), and the observer task section
// (`gap_task_messages.cpp`'s `encode_observer_task_section` caller,
// `GameplayAbilityNetworkBridge::encode_public_state`) all call this SAME
// exported function rather than each keeping their own private copy, so the
// filtering rule can never drift between wire paths. `p_audience` names the
// RECEIVING peer's role, never the task's own:
//   OWNER_ONLY audience admits everything except INTERNAL (the task's own
//     owner sees OWNER_ONLY and OBSERVABLE tasks, never authority-internal
//     implementation state);
//   OBSERVABLE audience admits only OBSERVABLE tasks (a non-owner observer
//     never sees an OWNER_ONLY or INTERNAL task, count or byte);
//   INTERNAL audience (the canonical authority snapshot/reconciliation
//     baseline) admits everything.
bool task_visible_to(AbilityTaskVisibility p_task_visibility, AbilityTaskVisibility p_audience);

enum class AbilityTaskPredictionPolicy : std::uint8_t {
	AUTHORITY_ONLY = 0,
	PREDICTION_SAFE = 1,
	REQUIRES_AUTHORITY = 2,
};

enum class AbilityTaskTagEdge : std::uint8_t {
	BECOMES_TRUE = 0,
	BECOMES_FALSE = 1,
};

enum class LogicalInputPhase : std::uint8_t {
	PRESS = 0,
	RELEASE = 1,
	CONFIRM = 2,
	CANCEL = 3,
};

// Kind-specific request fields are carried in one closed value. Fields not
// used by a kind must retain their defaults; validation rejects ambiguous
// payloads rather than silently ignoring behavior-shaped data.
struct AbilityTaskRequest {
	AbilityTaskKind kind = AbilityTaskKind::WAIT_TICKS;
	bool has_deadline = false;
	Tick deadline_tick = INVALID_TICK;
	AbilityTaskVisibility visibility = AbilityTaskVisibility::OWNER_ONLY;
	AbilityTaskPredictionPolicy prediction_policy = AbilityTaskPredictionPolicy::AUTHORITY_ONLY;

	// WAIT_TICKS
	Tick wait_ticks = 0;

	// WAIT_GAMEPLAY_EVENT
	DefinitionId gameplay_event_tag = INVALID_DEFINITION_ID;
	TagMatchMode gameplay_event_match = TagMatchMode::EXACT;

	// WAIT_TAG_QUERY
	TagQuery tag_query;
	AbilityTaskTagEdge tag_edge = AbilityTaskTagEdge::BECOMES_TRUE;
	bool complete_if_already_satisfied = false;

	// WAIT_LOGICAL_INPUT. Logical input identities use registered definition
	// ids (normally tags in an `input.*` namespace), never physical events.
	DefinitionId logical_input = INVALID_DEFINITION_ID;
	LogicalInputPhase logical_phase = LogicalInputPhase::PRESS;

	// WAIT_AUTHORITY
	PredictionKey authority_prediction = INVALID_PREDICTION_KEY;

	// WAIT_TARGET_DATA (validated further by TargetingCoordinator).
	DefinitionId target_schema = INVALID_DEFINITION_ID;
};

struct ActiveAbilityTask {
	AbilityTaskHandle handle = INVALID_ABILITY_TASK_HANDLE;
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	AbilityTaskRequest request;
	Tick start_tick = 0;
	Tick due_tick = INVALID_TICK;
	bool last_tag_truth = false;
	CommandSeq last_input_sequence = INVALID_COMMAND_SEQ;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
};

// Immutable terminal/restored notification payload. Event-specific fields are
// copied as values; no mutable component or scene object crosses this seam.
struct AbilityTaskEvent {
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilitySpecId spec = INVALID_ABILITY_SPEC_ID;
	DefinitionId ability = INVALID_DEFINITION_ID;
	AbilityTaskKind kind = AbilityTaskKind::WAIT_TICKS;
	AbilityTaskOutcome outcome = AbilityTaskOutcome::ACTIVE;
	AbilityTaskCancelReason cancel_reason = AbilityTaskCancelReason::NONE;
	Status status;
	Tick tick = 0;
	ChangeProvenance provenance = ChangeProvenance::AUTHORITATIVE;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
	bool restored = false;
	// Copied from the task's own `AbilityTaskRequest::visibility` at event
	// construction time (`AbilityTaskRuntime::make_event`) -- the SAME
	// "denormalize the fields a consumer needs so it never has to re-look the
	// task up" convention every other field on this struct already follows
	// (see file comment). This one specifically exists so a listener can
	// decide PUBLIC-audience change-tracking visibility (`task_visible_to`,
	// above) for a TERMINAL event, whose task may already be gone from
	// `AbilityTaskRuntime`'s live index by the time a queued notification
	// dispatches (see `AbilityComponent::dispatch_task_event`, called only
	// after `queue.dispatch()`).
	AbilityTaskVisibility task_visibility = AbilityTaskVisibility::OWNER_ONLY;

	DefinitionId matched_definition = INVALID_DEFINITION_ID;
	EntityId instigator = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	Fixed magnitude = Fixed::zero();
	std::uint64_t payload_tag = 0;
	LogicalInputPhase logical_phase = LogicalInputPhase::PRESS;
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	TargetSessionId target_session = INVALID_TARGET_SESSION_ID;
	TargetEffectContext target_context;
};

struct AbilityTaskStartResult {
	Status status;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	bool queued = false;
	bool terminal = false;
	AbilityTaskEvent event;
};

struct AbilityTaskTransitionResult {
	Status status;
	bool queued = false;
	bool transitioned = false;
	AbilityTaskEvent event;
};

struct AbilityTaskGameplayEvent {
	DefinitionId event_tag = INVALID_DEFINITION_ID;
	EntityId instigator = INVALID_ENTITY_ID;
	EntityId target = INVALID_ENTITY_ID;
	Fixed magnitude = Fixed::zero();
	std::uint64_t payload_tag = 0;
};

struct AbilityTaskLogicalInputCommand {
	EntityId owner = INVALID_ENTITY_ID;
	ExecutionId execution = INVALID_EXECUTION_ID;
	AbilityTaskHandle task = INVALID_ABILITY_TASK_HANDLE;
	DefinitionId logical_input = INVALID_DEFINITION_ID;
	LogicalInputPhase phase = LogicalInputPhase::PRESS;
	CommandSeq sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY;
};

constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_TASKS = 30;
constexpr std::uint8_t GA_SNAPSHOT_KIND_ABILITY_TASK_ENTRY = 31;

class AbilityTaskRuntime {
public:
	AbilityTaskRuntime(const TagRegistry &p_tags, const TagContainer &p_container, EntityId p_owner) :
			tag_registry(&p_tags), tag_container(&p_container), owner(p_owner) {}

	AbilityTaskStartResult start(const AbilityTaskRequest &p_request, ExecutionId p_execution,
			AbilitySpecId p_spec, DefinitionId p_ability, Tick p_tick,
			ChangeProvenance p_provenance, PredictionKey p_prediction_key,
			AbilityTaskHandle p_reserved_handle = INVALID_ABILITY_TASK_HANDLE);

	AbilityTaskTransitionResult cancel(AbilityTaskHandle p_task, Tick p_tick,
			AbilityTaskCancelReason p_reason = AbilityTaskCancelReason::EXPLICIT);
	AbilityTaskTransitionResult fail(AbilityTaskHandle p_task, Tick p_tick, Status p_status);
	AbilityTaskTransitionResult complete_target(AbilityTaskHandle p_task, Tick p_tick,
			TargetSessionId p_session, Status p_status = ok_status(),
			const TargetEffectContext *p_context = nullptr);

	// `r_truncated`, when non-null, is set to true if -- and only if -- this
	// call's own bounded loop(s) hit `MAX_TASK_TERMINAL_EVENTS_PER_TICK` and
	// stopped waking further tasks (spec "Bounded Task Runtime" / "Event
	// fan-out reaches its work budget"); left untouched otherwise, so callers
	// that pass a freshly zero-initialized flag can check it directly. Never
	// set more than once per call regardless of how many internal loops
	// truncate, keeping the resulting diagnostic bounded the same way the
	// truncation itself is.
	std::vector<AbilityTaskEvent> advance_to(Tick p_tick, bool *r_truncated = nullptr);
	std::vector<AbilityTaskEvent> notify_gameplay_event(const AbilityTaskGameplayEvent &p_event, Tick p_tick,
			bool *r_truncated = nullptr);
	std::vector<AbilityTaskEvent> notify_tag_state_changed(Tick p_tick, bool *r_truncated = nullptr);
	AbilityTaskTransitionResult submit_logical_input(const AbilityTaskLogicalInputCommand &p_command, Tick p_tick);
	std::vector<AbilityTaskEvent> acknowledge_authority(PredictionKey p_prediction_key, Tick p_tick);

	// Parent cleanup intentionally returns no per-task callback events. The
	// parent lifecycle event carries the bounded count; this avoids a callback
	// storm while guaranteeing every index is detached first.
	std::size_t cleanup_execution(ExecutionId p_execution, AbilityTaskCancelReason p_reason, Tick p_tick);
	void clear_all(AbilityTaskCancelReason p_reason, Tick p_tick);

	bool has(AbilityTaskHandle p_task) const;
	const ActiveAbilityTask *find(AbilityTaskHandle p_task) const;
	std::vector<AbilityTaskHandle> active_handles() const;
	std::vector<AbilityTaskHandle> tasks_for_execution(ExecutionId p_execution) const;
	std::size_t size() const { return tasks.size(); }
	std::uint64_t allocator_next_raw() const { return allocator.next_raw(); }
	Status validate_start_request(const AbilityTaskRequest &p_request, Tick p_start_tick,
			ChangeProvenance p_provenance) const {
		return validate_request(p_request, p_start_tick, p_provenance);
	}

	Status write_snapshot(SnapshotWriter &p_writer, AbilityTaskVisibility p_max_visibility = AbilityTaskVisibility::INTERNAL) const;
	Status restore_snapshot(SnapshotReader &p_reader,
			const std::function<bool(ExecutionId, AbilitySpecId, DefinitionId)> &p_parent_exists);

	// Task 2.1's per-record delta body for the ABILITY_TASK section: writes
	// exactly the fields `write_snapshot`'s own per-task entry writes, in the
	// SAME order. Unlike ACTIVE_EFFECT's target-context sanitization, no
	// field here varies by audience -- an audience only decides WHICH task
	// handles are eligible identities in the first place (`task_visible_to`,
	// already applied wherever this codec's caller derives its dirty/live
	// identity set -- see `AudienceVisibilityConfig`'s own comment) -- so
	// this takes no visibility parameter. Fails, without writing anything,
	// if `p_task` is not currently active.
	Status write_task_delta_record(SnapshotWriter &p_writer, AbilityTaskHandle p_task) const;

	// Decodes one record `write_task_delta_record` wrote, WITHOUT touching
	// live state: validates every RECORD-LOCAL field `restore_snapshot`
	// itself validates per entry (kind/visibility/prediction-policy/
	// provenance/tag-match/tag-edge/logical-phase enums, the encoded tag
	// query, and `validate_request`). Deliberately does NOT check parent
	// (execution/spec/ability) existence or the per-execution task-count cap
	// -- those are AGGREGATE checks over the whole proposed task set (a
	// batch may add the owning execution and one of its tasks together),
	// performed once by `validate_records` after every section in the same
	// batch has been decoded (see `AbilityComponent::apply_delta_batch`,
	// ga_ability_component.cpp).
	Status decode_task_delta_record(SnapshotReader &p_reader, ActiveAbilityTask &r_task) const;

	// The pure-decode half of `restore_snapshot` -- see
	// `AttributeSet::decode_snapshot_section`'s doc comment for why this
	// exists.
	Status decode_snapshot_section(SnapshotReader &p_reader, std::map<AbilityTaskHandle, ActiveAbilityTask> &r_tasks, std::uint64_t &r_allocator_raw) const;

	// Validates a COMPLETE proposed task map (current live state with this
	// batch's ops already applied) WITHOUT mutating this runtime: checks the
	// record count against `MAX_ACTIVE_ABILITY_TASKS`, `p_parent_exists` and
	// the per-execution `MAX_ABILITY_TASKS_PER_EXECUTION` cap for every
	// entry, exactly like `restore_snapshot`'s own tail.
	Status validate_records(const std::map<AbilityTaskHandle, ActiveAbilityTask> &p_tasks,
			const std::function<bool(ExecutionId, AbilitySpecId, DefinitionId)> &p_parent_exists) const;

	// Replaces this runtime's ENTIRE task state from an already-validated map
	// (`validate_records` must have already succeeded for it) -- the shared
	// install tail `restore_snapshot` and the delta codec's
	// `apply_delta_batch` both converge on (clears every derived index, then
	// rebuilds each via `attach_indexes`, exactly like `restore_snapshot`).
	// Trusts its input completely; never called directly on untrusted input.
	// `p_allocator_raw` becomes this runtime's allocator cursor EXACTLY
	// (`HandleAllocator::restore_exact`, matching `restore_snapshot`'s own
	// original behavior -- see that method's own doc comment on why a
	// canonical restore may move the cursor backward). A caller with no
	// explicit wire cursor (the delta codec) is responsible for computing a
	// value that never regresses ITS OWN runtime's cursor before calling
	// this -- see `allocator_next_raw()`.
	void install_records(std::map<AbilityTaskHandle, ActiveAbilityTask> p_tasks, std::uint64_t p_allocator_raw);

private:
	Status validate_request(const AbilityTaskRequest &p_request, Tick p_start_tick, ChangeProvenance p_provenance) const;
	void attach_indexes(const ActiveAbilityTask &p_task);
	void detach_indexes(const ActiveAbilityTask &p_task);
	AbilityTaskTransitionResult transition(AbilityTaskHandle p_task, AbilityTaskOutcome p_outcome,
			Tick p_tick, AbilityTaskCancelReason p_cancel_reason, Status p_status);
	AbilityTaskEvent make_event(const ActiveAbilityTask &p_task, AbilityTaskOutcome p_outcome,
			Tick p_tick, AbilityTaskCancelReason p_cancel_reason, Status p_status) const;
	std::vector<AbilityTaskHandle> canonical_candidates(const std::set<AbilityTaskHandle> &p_handles) const;
	Status encode_query(const TagQuery &p_query, std::vector<std::uint8_t> &r_bytes) const;
	// Shared by `write_snapshot`'s own per-entry loop and
	// `write_task_delta_record` -- see that public method's own doc comment.
	Status write_task_entry_fields(SnapshotWriter &p_writer, const ActiveAbilityTask &p_task) const;
	// Shared by `restore_snapshot`'s own per-entry loop and
	// `decode_task_delta_record` -- see that public method's own doc
	// comment. Decodes and validates every RECORD-LOCAL field ONLY; the
	// caller is responsible for any cross-record (aggregate or ordering)
	// check.
	Status decode_task_entry_fields(SnapshotReader &p_reader, ActiveAbilityTask &r_task) const;

	const TagRegistry *tag_registry = nullptr;
	const TagContainer *tag_container = nullptr;
	EntityId owner = INVALID_ENTITY_ID;

	std::map<AbilityTaskHandle, ActiveAbilityTask> tasks;
	std::map<ExecutionId, std::set<AbilityTaskHandle>> by_execution;
	std::map<Tick, std::set<AbilityTaskHandle>> due_index;
	std::map<Tick, std::set<AbilityTaskHandle>> deadline_index;
	std::map<DefinitionId, std::set<AbilityTaskHandle>> gameplay_event_index;
	std::set<AbilityTaskHandle> tag_query_index;
	std::map<DefinitionId, std::set<AbilityTaskHandle>> logical_input_index;
	std::map<PredictionKey, std::set<AbilityTaskHandle>> authority_index;
	HandleAllocator<AbilityTaskHandle> allocator;

	// `MAX_TASK_INPUTS_PER_TICK` budget for `submit_logical_input`'s local
	// (non-network) path -- see that method's own comment. Resets whenever a
	// call arrives for a tick different from `input_budget_tick`; ticks are
	// authoritative and monotonic in normal operation, so this is simply
	// "a new tick, a fresh budget" rather than a sliding window.
	Tick input_budget_tick = INVALID_TICK;
	std::size_t input_budget_used = 0;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_ABILITY_TASKS_H
