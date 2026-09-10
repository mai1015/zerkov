#ifndef LEVEL_TASK_SYSTEM_CORE_TASK_RUNTIME_H
#define LEVEL_TASK_SYSTEM_CORE_TASK_RUNTIME_H

#include "core/lts_graph_compiler.h"
#include "core/lts_limits.h"
#include "core/lts_status.h"
#include "core/lts_values.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// Runtime-only bounds are kept next to the runtime API and snapshot codec.
// They are deliberately no larger than the existing V1 core ceilings. A host
// may choose a smaller value for a particular instance.
constexpr std::size_t MAX_FACTS_PER_SNAPSHOT = 256;
constexpr std::size_t MAX_TRANSITION_RECORDS = MAX_STATE_CHANGE_RECORDS;
constexpr std::size_t MAX_RESOLVED_REQUEST_RECORDS = MAX_TRACE_RECORDS;
// Task snapshots use the shared protocol/schema compatibility axes. Keep an
// explicit task-runtime alias so adapters can advertise the exact envelope
// they persist without depending on an implementation detail of lts_limits.h.
constexpr std::uint16_t TASK_RUNTIME_SNAPSHOT_SCHEMA_VERSION = SNAPSHOT_SCHEMA_VERSION;
constexpr std::uint8_t TASK_RUNTIME_SNAPSHOT_KIND = 2;
constexpr std::uint64_t NO_EXPECTED_REVISION = UINT64_MAX;
constexpr std::uint64_t NO_TICK = UINT64_MAX;

enum class TaskGraphInstanceStatus : std::uint8_t {
	INVALID = 0,
	RUNNING = 1,
	SUCCEEDED = 2,
	FAILED = 3,
	CANCELLED = 4,
	STALLED = 5,
};

using TaskGraphStatus = TaskGraphInstanceStatus;
using TaskInstanceStatus = TaskGraphInstanceStatus;

enum class TaskNodeInstanceState : std::uint8_t {
	INACTIVE = 0,
	ACTIVE = 1,
	PENDING = 2,
	COMPLETED = 3,
	FAILED = 4,
};

using TaskNodeRuntimeState = TaskNodeInstanceState;
using TaskNodeState = TaskNodeInstanceState;

enum class TaskExternalRequestKind : std::uint8_t {
	ACTION = 1,
	REWARD = 2,
	CONVERSATION = 3,
	LEVEL_TRANSITION = 4,
};

using TaskRequestKind = TaskExternalRequestKind;

enum class TaskRequestResolution : std::uint8_t {
	ACKNOWLEDGED = 1,
	REJECTED = 2,
	TIMED_OUT = 3,
};

using TaskRequestResultKind = TaskRequestResolution;

enum class TaskTraceKind : std::uint8_t {
	EVENT_ACCEPTED = 1,
	FACT_SNAPSHOT_ACCEPTED = 2,
	NODE_ACTIVATED = 3,
	NODE_COUNTER_CHANGED = 4,
	NODE_COMPLETED = 5,
	EDGE_TRAVERSED = 6,
	REQUEST_EMITTED = 7,
	REQUEST_RESOLVED = 8,
	REQUEST_DUPLICATE = 9,
	GRAPH_STATUS_CHANGED = 10,
};

// A fact is a closed typed value addressed by a provider and a stable key.
// The runtime never stores a host object or callback in this record.
struct TaskFact {
	std::string provider_identifier;
	std::string fact_identifier;
	Value value = Value::none();

	Status validate() const;
	bool operator==(const TaskFact &p_other) const;
	bool operator!=(const TaskFact &p_other) const { return !(*this == p_other); }
	bool operator<(const TaskFact &p_other) const;
};

using Fact = TaskFact;
using TaskFactRecord = TaskFact;

// A snapshot is copied into an instance for the duration of an advance.  It
// is sorted by its two stable keys, making lookup and replay deterministic.
class TaskFactSnapshot {
public:
	TaskFactSnapshot() = default;
	explicit TaskFactSnapshot(const std::string &p_scope_key);

	Status set_scope_key(const std::string &p_scope_key);
	const std::string &scope_key() const { return scope_key_; }

	Status add(const TaskFact &p_fact);
	Status add_fact(const TaskFact &p_fact) { return add(p_fact); }
	Status set(const TaskFact &p_fact);
	Status set_fact(const TaskFact &p_fact) { return set(p_fact); }
	Status upsert(const TaskFact &p_fact) { return set(p_fact); }
	void clear();

	Status validate(std::size_t p_limit = MAX_FACTS_PER_SNAPSHOT) const;
	const std::vector<TaskFact> &facts() const { return facts_; }
	std::size_t size() const { return facts_.size(); }
	bool empty() const { return facts_.empty(); }
	const TaskFact *find(const std::string &p_provider_identifier, const std::string &p_fact_identifier) const;

	// Missing facts and type mismatches evaluate to false.  The Status overload
	// is available when an adapter also wants to distinguish malformed input.
	bool matches(const FactPredicate &p_predicate) const;
	Status evaluate(const FactPredicate &p_predicate, bool &r_matches) const;
	Status evaluate_all(const std::vector<FactPredicate> &p_predicates, bool &r_matches) const;

	bool operator==(const TaskFactSnapshot &p_other) const {
		return scope_key_ == p_other.scope_key_ && facts_ == p_other.facts_;
	}
	bool operator!=(const TaskFactSnapshot &p_other) const { return !(*this == p_other); }

private:
	std::string scope_key_;
	std::vector<TaskFact> facts_;
};

// Ordered host event.  A zero sequence is accepted as an implicit sequence;
// the instance assigns the next deterministic sequence number.  Non-zero
// sequences must be strictly increasing across advances.
struct TaskEvent {
	std::uint64_t sequence = 0;
	std::string provider_identifier;
	std::string event_identifier;
	std::string scope_key;
	Value value = Value::none();
	std::uint32_t amount = 1;
	std::vector<FactPredicate> filters;

	Status validate() const;
	static TaskEvent make(
			const std::string &p_provider_identifier,
			const std::string &p_event_identifier = std::string(),
			std::uint64_t p_sequence = 0,
			std::uint32_t p_amount = 1);
	bool operator==(const TaskEvent &p_other) const;
	bool operator!=(const TaskEvent &p_other) const { return !(*this == p_other); }
};

struct TaskRuntimeLimits {
	std::size_t max_facts_per_snapshot = MAX_FACTS_PER_SNAPSHOT;
	std::size_t max_events_per_advance = MAX_EVENTS_PER_ADVANCE;
	std::uint32_t max_transitions_per_advance = MAX_TRANSITIONS_PER_ADVANCE;
	std::size_t max_pending_requests = MAX_PENDING_REQUESTS;
	std::size_t max_transition_records = MAX_TRANSITION_RECORDS;
	std::size_t max_state_change_records = MAX_STATE_CHANGE_RECORDS;
	std::size_t max_trace_records = MAX_TRACE_RECORDS;
	std::size_t max_resolved_request_records = MAX_RESOLVED_REQUEST_RECORDS;
	// Zero disables automatic expiry.  Otherwise a request expires when the
	// owning instance is advanced at or beyond created_tick + this value.
	std::uint64_t request_timeout_ticks = 0;

	Status validate() const;
};

struct TaskNodeRuntimeStateRecord {
	TaskNodeInstanceState state = TaskNodeInstanceState::INACTIVE;
	std::uint32_t counter = 0;
	std::uint64_t request_generation = 0;

	bool operator==(const TaskNodeRuntimeStateRecord &p_other) const {
		return state == p_other.state && counter == p_other.counter && request_generation == p_other.request_generation;
	}
	bool operator!=(const TaskNodeRuntimeStateRecord &p_other) const { return !(*this == p_other); }
};

using TaskNodeStateRecord = TaskNodeRuntimeStateRecord;

struct TaskExternalRequest {
	std::string request_identifier;
	TaskExternalRequestKind kind = TaskExternalRequestKind::ACTION;
	std::string instance_identifier;
	std::string scope_key;
	std::string node_identifier;
	std::string provider_identifier;
	std::string conversation_identifier;
	std::string target_level_identifier;
	std::string target_exit_identifier;
	std::string target_anchor_identifier;
	std::vector<Value> parameters;
	std::uint64_t created_revision = 0;
	std::uint64_t created_tick = 0;
	std::uint64_t timeout_tick = 0;
	bool has_timeout = false;

	Status validate() const;
	bool operator==(const TaskExternalRequest &p_other) const;
	bool operator!=(const TaskExternalRequest &p_other) const { return !(*this == p_other); }
};

using TaskRequest = TaskExternalRequest;

struct TaskRequestResolutionRecord {
	std::string request_identifier;
	TaskExternalRequestKind kind = TaskExternalRequestKind::ACTION;
	TaskRequestResolution resolution = TaskRequestResolution::ACKNOWLEDGED;
	std::string outcome_identifier;
	Value response = Value::none();
	std::uint64_t revision = 0;

	Status validate() const;
	bool operator==(const TaskRequestResolutionRecord &p_other) const;
	bool operator!=(const TaskRequestResolutionRecord &p_other) const { return !(*this == p_other); }
};

using TaskRequestResult = TaskRequestResolutionRecord;

struct TaskTransitionRecord {
	std::uint64_t revision = 0;
	std::uint32_t ordinal = 0;
	std::string from_node_identifier;
	std::string to_node_identifier;
	std::string edge_identifier;
	std::string output_port_identifier;

	Status validate() const;
	bool operator==(const TaskTransitionRecord &p_other) const;
	bool operator!=(const TaskTransitionRecord &p_other) const { return !(*this == p_other); }
};

struct TaskStateChangeRecord {
	std::uint64_t revision = 0;
	std::uint32_t ordinal = 0;
	std::string node_identifier;
	TaskNodeInstanceState previous_state = TaskNodeInstanceState::INACTIVE;
	TaskNodeInstanceState current_state = TaskNodeInstanceState::INACTIVE;
	std::uint32_t previous_counter = 0;
	std::uint32_t current_counter = 0;
	std::string request_identifier;
	std::string outcome_identifier;

	Status validate() const;
	bool operator==(const TaskStateChangeRecord &p_other) const;
	bool operator!=(const TaskStateChangeRecord &p_other) const { return !(*this == p_other); }
};

struct TaskTraceRecord {
	std::uint64_t revision = 0;
	std::uint32_t ordinal = 0;
	TaskTraceKind kind = TaskTraceKind::EVENT_ACCEPTED;
	std::string node_identifier;
	std::string request_identifier;
	std::string event_identifier;
	std::string outcome_identifier;
	TaskNodeInstanceState previous_state = TaskNodeInstanceState::INACTIVE;
	TaskNodeInstanceState current_state = TaskNodeInstanceState::INACTIVE;
	TaskGraphInstanceStatus graph_status = TaskGraphInstanceStatus::RUNNING;

	Status validate() const;
	bool operator==(const TaskTraceRecord &p_other) const;
	bool operator!=(const TaskTraceRecord &p_other) const { return !(*this == p_other); }
};

// All records in this result describe one committed mutation.  On a rejected
// input the result is cleared and the instance remains byte-for-byte intact.
struct TaskAdvanceResult {
	Status status;
	bool changed = false;
	bool idempotent = false;
	std::uint64_t revision = 0;
	TaskGraphInstanceStatus graph_status = TaskGraphInstanceStatus::INVALID;
	bool has_resolution = false;
	TaskRequestResolutionRecord resolution;
	std::vector<TaskExternalRequest> requests;
	std::vector<TaskTransitionRecord> transitions;
	std::vector<TaskStateChangeRecord> state_changes;
	std::vector<TaskTraceRecord> trace;
	bool transitions_truncated = false;
	bool trace_truncated = false;

	bool ok() const { return status.ok(); }
	void clear();
};

class TaskGraphInstance {
public:
	TaskGraphInstance() = default;
	TaskGraphInstance(
			const CanonicalTaskGraph &p_graph,
			const std::string &p_instance_identifier,
			const std::string &p_scope_key,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{});

	// A constructor cannot report a failed definition/identifier check, so
	// callers that need the exact Status should use create()/start().
	static Status create(
			const CanonicalTaskGraph &p_graph,
			const std::string &p_instance_identifier,
			const std::string &p_scope_key,
			TaskGraphInstance &r_instance,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{},
			TaskAdvanceResult *r_start_result = nullptr);
	static Status start(
			const CanonicalTaskGraph &p_graph,
			const std::string &p_instance_identifier,
			const std::string &p_scope_key,
			TaskGraphInstance &r_instance,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{},
			TaskAdvanceResult *r_start_result = nullptr) {
		return create(p_graph, p_instance_identifier, p_scope_key, r_instance, p_limits, r_start_result);
	}

	Status initialize(
			const CanonicalTaskGraph &p_graph,
			const std::string &p_instance_identifier,
			const std::string &p_scope_key,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{},
			TaskAdvanceResult *r_start_result = nullptr);

	bool valid() const;
	bool is_valid() const { return valid(); }
	bool running() const { return status_ == TaskGraphInstanceStatus::RUNNING; }
	bool terminal() const;

	const CanonicalTaskGraph &graph() const { return graph_; }
	const CanonicalTaskGraph &compiled_graph() const { return graph_; }
	const std::string &instance_identifier() const { return instance_identifier_; }
	const std::string &instance_id() const { return instance_identifier_; }
	const std::string &scope_key() const { return scope_key_; }
	const std::string &host_scope_key() const { return scope_key_; }
	std::uint64_t definition_fingerprint() const { return definition_fingerprint_; }
	std::uint64_t fingerprint() const { return definition_fingerprint_; }
	std::uint64_t revision() const { return revision_; }
	TaskGraphInstanceStatus status() const { return status_; }
	TaskGraphInstanceStatus graph_status() const { return status_; }
	const std::string &terminal_outcome() const { return terminal_outcome_; }
	const TaskRuntimeLimits &limits() const { return limits_; }

	const std::vector<TaskNodeRuntimeStateRecord> &node_states() const { return node_states_; }
	const TaskNodeRuntimeStateRecord *node_state(const std::string &p_node_identifier) const;
	std::uint32_t node_counter(const std::string &p_node_identifier) const;

	const TaskFactSnapshot &last_facts() const { return last_facts_; }
	const std::vector<TaskExternalRequest> &pending_requests() const { return pending_requests_; }
	const std::vector<TaskRequestResolutionRecord> &resolved_requests() const { return resolved_requests_; }
	const TaskExternalRequest *find_pending_request(const std::string &p_request_identifier) const;
	const TaskRequestResolutionRecord *find_resolved_request(const std::string &p_request_identifier) const;

	const std::vector<TaskTransitionRecord> &transition_records() const { return transition_records_; }
	const std::vector<TaskStateChangeRecord> &state_change_records() const { return state_change_records_; }
	const std::vector<TaskTraceRecord> &trace_records() const { return trace_records_; }
	bool transition_records_truncated() const { return transition_records_truncated_; }
	bool state_change_records_truncated() const { return state_change_records_truncated_; }
	bool trace_records_truncated() const { return trace_records_truncated_; }
	void clear_records();

	// Snapshot encoding is a bounded little-endian V1 envelope. It includes
	// every mutable value required for deterministic resume (including event
	// sequence/tick cursors, request idempotency history, and retained records).
	// Decode validates a complete temporary instance before publishing it, so a
	// malformed, stale, or incompatible snapshot cannot partially mutate this
	// instance.
	Status encode_snapshot(std::vector<std::uint8_t> &r_bytes) const;
	Status snapshot(std::vector<std::uint8_t> &r_bytes) const { return encode_snapshot(r_bytes); }
	Status save_snapshot(std::vector<std::uint8_t> &r_bytes) const { return encode_snapshot(r_bytes); }
	Status restore_snapshot(const std::vector<std::uint8_t> &p_bytes);
	Status restore_snapshot(const std::vector<std::uint8_t> &p_bytes, std::uint64_t p_expected_revision);
	Status restore(const std::vector<std::uint8_t> &p_bytes) { return restore_snapshot(p_bytes); }
	Status restore(const std::vector<std::uint8_t> &p_bytes, std::uint64_t p_expected_revision) {
		return restore_snapshot(p_bytes, p_expected_revision);
	}

	// Static convenience for restoring into a fresh owner. The graph is the
	// resolved active definition; its fingerprint must match the envelope. The
	// optional limits argument is retained as a caller-side default for API
	// symmetry, while the validated limits encoded in the snapshot are restored
	// to preserve the original deterministic runtime configuration.
	static Status restore_snapshot(
			const CanonicalTaskGraph &p_graph,
			const std::vector<std::uint8_t> &p_bytes,
			TaskGraphInstance &r_instance,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{});
	static Status from_snapshot(
			const CanonicalTaskGraph &p_graph,
			const std::vector<std::uint8_t> &p_bytes,
			TaskGraphInstance &r_instance,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{}) {
		return restore_snapshot(p_graph, p_bytes, r_instance, p_limits);
	}
	static Status restore(
			const CanonicalTaskGraph &p_graph,
			const std::vector<std::uint8_t> &p_bytes,
			TaskGraphInstance &r_instance,
			const TaskRuntimeLimits &p_limits = TaskRuntimeLimits{}) {
		return restore_snapshot(p_graph, p_bytes, r_instance, p_limits);
	}

	Status advance(
			const std::vector<TaskEvent> &p_events,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult *r_result = nullptr);
	Status advance(
			const std::vector<TaskEvent> &p_events,
			const TaskFactSnapshot &p_facts,
			TaskAdvanceResult *r_result = nullptr);
	Status advance(
			const TaskFactSnapshot &p_facts,
			const std::vector<TaskEvent> &p_events,
			std::uint64_t p_tick,
			TaskAdvanceResult *r_result = nullptr) {
		return advance(p_events, p_facts, p_tick, r_result);
	}
	Status advance(
			const TaskFactSnapshot &p_facts,
			const std::vector<TaskEvent> &p_events,
			TaskAdvanceResult *r_result = nullptr) {
		return advance(p_events, p_facts, r_result);
	}

	Status tick(
			std::uint64_t p_tick,
			const TaskFactSnapshot &p_facts = TaskFactSnapshot{},
			TaskAdvanceResult *r_result = nullptr);

	// Acknowledgement/rejection/timeout are intentionally separate entry
	// points so a host cannot accidentally treat a request as complete merely
	// because it was emitted.  Replaying a resolved request is idempotent.
	Status acknowledge_request(
			const std::string &p_request_identifier,
			const std::string &p_outcome_identifier = std::string(),
			const Value &p_response = Value::none(),
			std::uint64_t p_tick = NO_TICK,
			std::uint64_t p_expected_revision = NO_EXPECTED_REVISION,
			TaskAdvanceResult *r_result = nullptr);
	Status acknowledge_request(
			const std::string &p_request_identifier,
			const std::string &p_outcome_identifier,
			const Value &p_response,
			TaskAdvanceResult *r_result) {
		return acknowledge_request(p_request_identifier, p_outcome_identifier, p_response, NO_TICK, NO_EXPECTED_REVISION, r_result);
	}
	Status reject_request(
			const std::string &p_request_identifier,
			const Value &p_response = Value::none(),
			std::uint64_t p_tick = NO_TICK,
			std::uint64_t p_expected_revision = NO_EXPECTED_REVISION,
			TaskAdvanceResult *r_result = nullptr);
	Status reject_request(
			const std::string &p_request_identifier,
			const Value &p_response,
			TaskAdvanceResult *r_result) {
		return reject_request(p_request_identifier, p_response, NO_TICK, NO_EXPECTED_REVISION, r_result);
	}
	Status timeout_request(
			const std::string &p_request_identifier,
			std::uint64_t p_tick = NO_TICK,
			std::uint64_t p_expected_revision = NO_EXPECTED_REVISION,
			TaskAdvanceResult *r_result = nullptr);
	Status timeout_request(const std::string &p_request_identifier, TaskAdvanceResult *r_result) {
		return timeout_request(p_request_identifier, NO_TICK, NO_EXPECTED_REVISION, r_result);
	}

	// Level transition requests have no task node in V1 (LevelDefinition owns
	// exits), but use the same stable request/ack boundary as action/reward/
	// conversation nodes.  The host still owns scene loading and binding.
	Status emit_level_transition_request(
			const std::string &p_target_level_identifier,
			const std::string &p_target_exit_identifier,
			const std::string &p_target_anchor_identifier,
			const std::vector<Value> &p_parameters = std::vector<Value>{},
			std::uint64_t p_tick = NO_TICK,
			TaskExternalRequest *r_request = nullptr,
			TaskAdvanceResult *r_result = nullptr);
	Status emit_level_transition_request(
			const std::string &p_target_level_identifier,
			const std::string &p_target_exit_identifier,
			const std::string &p_target_anchor_identifier,
			const std::vector<Value> &p_parameters,
			TaskExternalRequest *r_request,
			TaskAdvanceResult *r_result) {
		return emit_level_transition_request(p_target_level_identifier, p_target_exit_identifier, p_target_anchor_identifier,
				p_parameters, NO_TICK, r_request, r_result);
	}

private:
	CanonicalTaskGraph graph_;
	TaskRuntimeLimits limits_;
	std::string instance_identifier_;
	std::string scope_key_;
	std::uint64_t definition_fingerprint_ = INVALID_CATALOG_FINGERPRINT;
	std::uint64_t revision_ = 0;
	std::uint64_t last_tick_ = 0;
	bool has_tick_ = false;
	std::uint64_t last_event_sequence_ = 0;
	bool has_event_sequence_ = false;
	TaskGraphInstanceStatus status_ = TaskGraphInstanceStatus::INVALID;
	std::string terminal_outcome_;
	std::vector<TaskNodeRuntimeStateRecord> node_states_;
	std::vector<std::uint8_t> incoming_edges_arrived_;
	std::vector<TaskExternalRequest> pending_requests_;
	std::vector<TaskRequestResolutionRecord> resolved_requests_;
	std::vector<TaskTransitionRecord> transition_records_;
	std::vector<TaskStateChangeRecord> state_change_records_;
	std::vector<TaskTraceRecord> trace_records_;
	bool transition_records_truncated_ = false;
	bool state_change_records_truncated_ = false;
	bool trace_records_truncated_ = false;
	TaskFactSnapshot last_facts_;
	std::uint64_t next_request_ordinal_ = 0;

	Status validate_start(
			const CanonicalTaskGraph &p_graph,
			const std::string &p_instance_identifier,
			const std::string &p_scope_key,
			const TaskRuntimeLimits &p_limits) const;
	Status bootstrap(TaskAdvanceResult &r_result);
	Status advance_internal(
			const std::vector<TaskEvent> &p_events,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			bool p_tick_supplied);
	Status acknowledge_internal(
			const std::string &p_request_identifier,
			TaskRequestResolution p_resolution,
			const std::string &p_outcome_identifier,
			const Value &p_response,
			std::uint64_t p_tick,
			std::uint64_t p_expected_revision,
			TaskAdvanceResult &r_result,
			bool p_tick_supplied);

	Status activate_node(
			std::uint32_t p_node_index,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count);
	Status complete_node(
			std::uint32_t p_node_index,
			const std::string &p_output_port,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count,
			const std::string &p_request_identifier = std::string(),
			const std::string &p_outcome_identifier = std::string());
	Status route_output(
			std::uint32_t p_node_index,
			const std::string &p_output_port,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count);
	Status process_events(
			const std::vector<TaskEvent> &p_events,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count);
	Status expire_requests(
			std::uint64_t p_tick,
			const TaskFactSnapshot &p_facts,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count);
	Status emit_node_request(
			std::uint32_t p_node_index,
			TaskExternalRequestKind p_kind,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count);
	Status emit_request(
			TaskExternalRequest p_request,
			TaskAdvanceResult &r_result);

	Status mutate_node_state(
			std::uint32_t p_node_index,
			TaskNodeInstanceState p_new_state,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count,
			const std::string &p_request_identifier = std::string(),
			const std::string &p_outcome_identifier = std::string());
	Status append_state_change(
			std::uint32_t p_node_index,
			TaskNodeInstanceState p_previous_state,
			TaskNodeInstanceState p_current_state,
			std::uint32_t p_previous_counter,
			std::uint32_t p_current_counter,
			const std::string &p_request_identifier,
			const std::string &p_outcome_identifier,
			TaskAdvanceResult &r_result);
	void append_trace(const TaskTraceRecord &p_record, TaskAdvanceResult &r_result);
	void append_retained_transition(const TaskTransitionRecord &p_record);
	void append_retained_state_change(const TaskStateChangeRecord &p_record);
	void append_retained_trace(const TaskTraceRecord &p_record);

	std::uint32_t transition_budget() const;
	std::string make_request_identifier(TaskExternalRequestKind p_kind, const std::string &p_node_identifier,
			std::uint64_t p_ordinal) const;
	const CanonicalTaskNode *find_canonical_node(const std::string &p_node_identifier) const;
	std::uint32_t find_canonical_node_index(const std::string &p_node_identifier) const;
	bool event_matches(const TaskEvent &p_event, const TaskNodeDefinition &p_node, const TaskFactSnapshot &p_facts) const;
	bool predicate_values_match(const Value &p_actual, const FactPredicate &p_predicate) const;
	Status route_request_resolution(
			const TaskExternalRequest &p_request,
			TaskRequestResolution p_resolution,
			const std::string &p_outcome_identifier,
			const Value &p_response,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			TaskAdvanceResult &r_result,
			std::uint32_t &r_transition_count);
	Status remember_resolution(const TaskRequestResolutionRecord &p_record);
	void finish_result(TaskAdvanceResult &r_result) const;
	Status validate_snapshot_state() const;
	Status decode_snapshot(const std::vector<std::uint8_t> &p_bytes, TaskGraphInstance &r_instance) const;
};

using TaskRuntime = TaskGraphInstance;

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_TASK_RUNTIME_H
