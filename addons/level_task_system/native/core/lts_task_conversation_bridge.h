#ifndef LEVEL_TASK_SYSTEM_CORE_TASK_CONVERSATION_BRIDGE_H
#define LEVEL_TASK_SYSTEM_CORE_TASK_CONVERSATION_BRIDGE_H

#include "core/lts_catalog.h"
#include "core/lts_conversation_runtime.h"
#include "core/lts_task_runtime.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// A bridge is a host-owned orchestration seam. It never owns a renderer,
// Node, Object, callback, or provider. The limits deliberately match the
// existing task/conversation request-history ceilings so replay bookkeeping
// remains bounded as well.
constexpr std::size_t MAX_TASK_CONVERSATION_REPLAY_RECORDS = MAX_PENDING_REQUESTS;

enum class TaskConversationOperation : std::uint8_t {
	NONE = 0,
	START = 1,
	CONTINUE_LINE = 2,
	SELECT_CHOICE = 3,
	SET_FACTS = 4,
	WRITEBACK_FACTS = 5,
	ACKNOWLEDGE_ACTION = 6,
	REJECT_ACTION = 7,
	TIMEOUT_ACTION = 8,
	WRITEBACK_OUTCOME = 9,
};

// Stable identity tying one task request to one conversation instance. The
// request identifier is the idempotency key; the derived conversation
// instance/handle identifiers make the relationship explicit in snapshots.
struct TaskConversationCorrelation {
	std::string task_request_identifier;
	std::string task_instance_identifier;
	std::string task_scope_identifier;
	std::string task_node_identifier;
	std::string conversation_identifier;
	std::string conversation_instance_identifier;
	std::string task_integration_handle;
	std::uint64_t task_request_created_revision = 0;
	std::uint64_t conversation_definition_fingerprint = INVALID_CATALOG_FINGERPRINT;

	Status validate() const;
	bool operator==(const TaskConversationCorrelation &p_other) const;
	bool operator!=(const TaskConversationCorrelation &p_other) const { return !(*this == p_other); }
};

// Input supplied by the host when a pending task conversation request is
// materialized. Empty identifiers derive the stable request identity for a
// fresh start (or reuse the established correlation on replay). Non-empty
// identifiers are host-chosen stable values and must remain unchanged for a
// replay of the same task request; the bridge never silently remaps a request.
struct TaskConversationStartContext {
	std::string task_request_identifier;
	std::string conversation_instance_identifier;
	std::string task_integration_handle;
	std::string entry_label;
	std::vector<Value> effect_parameters;
	ConversationFactSnapshot conversation_facts;

	// Optional task-side fact snapshot. When non-empty (or when its scope key
	// is set), start() advances the task with this snapshot transactionally with
	// conversation start. This is explicit writeback; conversation facts are
	// never guessed to be task facts.
	TaskFactSnapshot task_facts;
	bool write_task_facts = false;

	Status validate() const;
};

// One bounded result shape is shared by all host-facing bridge operations.
// `task_result` is present only when the bridge advanced the task runtime;
// `frame` is the current render-neutral conversation projection.
struct TaskConversationResult {
	Status status;
	TaskConversationOperation operation = TaskConversationOperation::NONE;
	bool changed = false;
	bool idempotent = false;
	bool has_frame = false;
	bool has_task_result = false;
	ConversationFrame frame;
	TaskAdvanceResult task_result;
	TaskConversationCorrelation correlation;
	std::string choice_identifier;
	std::string outcome_identifier;

	bool ok() const { return status.ok(); }
	void clear();
};

// Coordinates one externally-owned TaskGraphInstance and one
// ConversationInstance. A bridge object is intentionally not a runtime
// owner: callers retain ownership and must keep the bound objects alive until
// unbind(). All mutation delegates to the public, validated runtime APIs.
class TaskConversationBridge {
public:
	TaskConversationBridge() = default;
	TaskConversationBridge(
			TaskGraphInstance &p_task,
			ConversationInstance &p_conversation,
			const LevelTaskCatalog *p_catalog = nullptr) {
		bind(p_task, p_conversation, p_catalog);
	}

	Status bind(
			TaskGraphInstance &p_task,
			ConversationInstance &p_conversation,
			const LevelTaskCatalog *p_catalog = nullptr);
	Status attach(
			TaskGraphInstance &p_task,
			ConversationInstance &p_conversation,
			const LevelTaskCatalog *p_catalog = nullptr) {
		return bind(p_task, p_conversation, p_catalog);
	}
	void unbind();

	bool bound() const { return task_ != nullptr && conversation_ != nullptr; }
	bool started() const { return started_; }
	bool active() const { return started_ && conversation_ != nullptr && conversation_->active(); }
	bool terminal() const { return started_ && conversation_ != nullptr && conversation_->terminal(); }

	TaskGraphInstance *task_instance() { return task_; }
	const TaskGraphInstance *task_instance() const { return task_; }
	ConversationInstance *conversation_instance() { return conversation_; }
	const ConversationInstance *conversation_instance() const { return conversation_; }
	const TaskConversationCorrelation &correlation() const { return correlation_; }
	const TaskExternalRequest *task_request() const;
	const ConversationFrame *frame() const;

	// Starts from a direct, already-resolved definition. The catalog overload
	// below resolves by stable identifier and requires a sealed catalog.
	Status start(
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr);
	Status start(
			const LevelTaskCatalog &p_catalog,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr);
	Status start_from_task(
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr) {
		return start(p_definition, p_context, r_result);
	}
	Status start_pending(
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr) {
		return start(p_definition, p_context, r_result);
	}
	Status start_pending(
			const LevelTaskCatalog &p_catalog,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr) {
		return start(p_catalog, p_context, r_result);
	}

	// Convenience for adapters that already copied the emitted task request.
	// The request must still be pending on the bound task instance unless this
	// is an idempotent replay of the same already-started bridge.
	Status start_from_task_request(
			const TaskExternalRequest &p_request,
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr);

	// Render-neutral conversation operations. Choice/line replay is recorded
	// by frame revision so a duplicate cannot run the transition twice while a
	// different operation at that revision remains a stale-input failure.
	Status continue_line(
			std::uint64_t p_frame_revision,
			TaskConversationResult *r_result = nullptr);
	Status continue_line(TaskConversationResult *r_result = nullptr);
	Status advance_line(
			std::uint64_t p_frame_revision,
			TaskConversationResult *r_result = nullptr) {
		return continue_line(p_frame_revision, r_result);
	}
	Status advance_line(TaskConversationResult *r_result = nullptr) { return continue_line(r_result); }

	Status select_choice(
			const std::string &p_choice_identifier,
			std::uint64_t p_frame_revision,
			TaskConversationResult *r_result = nullptr);
	Status select_choice(
			const std::string &p_choice_identifier,
			TaskConversationResult *r_result = nullptr);
	Status choose(
			const std::string &p_choice_identifier,
			std::uint64_t p_frame_revision,
			TaskConversationResult *r_result = nullptr) {
		return select_choice(p_choice_identifier, p_frame_revision, r_result);
	}
	Status choose(
			const std::string &p_choice_identifier,
			TaskConversationResult *r_result = nullptr) {
		return select_choice(p_choice_identifier, r_result);
	}

	// Conversation facts are copied and validated by ConversationInstance.
	// `writeback_facts` additionally advances the task with an explicit task
	// snapshot using a two-copy commit, so a rejected operation mutates neither
	// runtime. The one-argument writeback converts the same closed facts into a
	// task snapshot under the bound task scope.
	Status set_facts(
			const ConversationFactSnapshot &p_facts,
			TaskConversationResult *r_result = nullptr);
	Status update_facts(
			const ConversationFactSnapshot &p_facts,
			TaskConversationResult *r_result = nullptr) {
		return set_facts(p_facts, r_result);
	}
	Status writeback_facts(
			const ConversationFactSnapshot &p_conversation_facts,
			const TaskFactSnapshot &p_task_facts,
			std::uint64_t p_tick = NO_TICK,
			TaskConversationResult *r_result = nullptr);
	Status writeback_facts(
			const ConversationFactSnapshot &p_facts,
			std::uint64_t p_tick = NO_TICK,
			TaskConversationResult *r_result = nullptr);
	Status write_facts_to_task(
			const ConversationFactSnapshot &p_facts,
			std::uint64_t p_tick = NO_TICK,
			TaskConversationResult *r_result = nullptr) {
		return writeback_facts(p_facts, p_tick, r_result);
	}

	// Conversation external actions retain their own request identity and
	// revision checks. These wrappers do not execute a provider and do not
	// write to the task until the conversation reaches a named outcome.
	Status acknowledge_action(
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision,
			bool p_success,
			const Value &p_response = Value::none(),
			TaskConversationResult *r_result = nullptr);
	Status acknowledge_action(
			const std::string &p_request_identifier,
			bool p_success,
			const Value &p_response = Value::none(),
			TaskConversationResult *r_result = nullptr);
	Status acknowledge(
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision,
			bool p_success,
			const Value &p_response = Value::none(),
			TaskConversationResult *r_result = nullptr) {
		return acknowledge_action(p_request_identifier, p_frame_revision, p_success, p_response, r_result);
	}
	Status reject_action(
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision = 0,
			TaskConversationResult *r_result = nullptr);
	Status timeout_action(
			const std::string &p_request_identifier,
			std::uint64_t p_frame_revision = 0,
			TaskConversationResult *r_result = nullptr);

	// Explicit outcome writeback is the only operation that acknowledges the
	// task's pending conversation request. The outcome must equal the terminal
	// conversation frame and be listed by the task node. Replaying an already
	// resolved request returns the prior task result idempotently.
	Status writeback_outcome(
			const std::string &p_outcome_identifier = std::string(),
			const Value &p_response = Value::none(),
			std::uint64_t p_tick = NO_TICK,
			std::uint64_t p_expected_task_revision = NO_EXPECTED_REVISION,
			TaskConversationResult *r_result = nullptr);
	Status acknowledge_outcome(
			const std::string &p_outcome_identifier = std::string(),
			const Value &p_response = Value::none(),
			std::uint64_t p_tick = NO_TICK,
			std::uint64_t p_expected_task_revision = NO_EXPECTED_REVISION,
			TaskConversationResult *r_result = nullptr) {
		return writeback_outcome(p_outcome_identifier, p_response, p_tick, p_expected_task_revision, r_result);
	}

	// Stateless convenience for hosts that do not need to retain a bridge
	// object after the initial start. The returned runtimes remain owned by the
	// caller, just as with the stateful API.
	static Status start_task_conversation(
			TaskGraphInstance &p_task,
			ConversationInstance &p_conversation,
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context = TaskConversationStartContext{},
			TaskConversationResult *r_result = nullptr);

private:
	struct ReplayRecord {
		TaskConversationOperation operation = TaskConversationOperation::NONE;
		std::uint64_t frame_revision = 0;
		std::string identifier;
		std::uint64_t resulting_revision = 0;
	};

	TaskGraphInstance *task_ = nullptr;
	ConversationInstance *conversation_ = nullptr;
	const LevelTaskCatalog *catalog_ = nullptr;
	bool started_ = false;
	TaskConversationCorrelation correlation_;
	TaskExternalRequest task_request_;
	std::vector<ReplayRecord> replay_records_;

	Status validate_bound() const;
	Status resolve_request(
			const TaskConversationStartContext &p_context,
			const TaskExternalRequest *p_explicit_request,
			const TaskExternalRequest *&r_request) const;
	Status validate_mapping(
			const TaskExternalRequest &p_request,
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context,
			std::string &r_entry_label,
			std::string &r_instance_identifier,
			std::string &r_integration_handle) const;
	Status start_resolved(
			const TaskExternalRequest &p_request,
			const ConversationDefinition &p_definition,
			const TaskConversationStartContext &p_context,
			TaskConversationResult *r_result);
	Status validate_started() const;
	Status validate_current_request(bool p_allow_resolved) const;
	Status finish(
			TaskConversationResult *r_result,
			TaskConversationOperation p_operation,
			bool p_changed,
			bool p_idempotent,
			const TaskAdvanceResult *p_task_result = nullptr,
			const std::string &p_choice_identifier = std::string(),
			const std::string &p_outcome_identifier = std::string()) const;
	Status fail(
			TaskConversationResult *r_result,
			TaskConversationOperation p_operation,
			const Status &p_status) const;

	const TaskNodeDefinition *task_node_definition() const;
	const TaskExternalRequest *current_task_request() const;
	Status normalize_task_facts(const TaskFactSnapshot &p_facts, TaskFactSnapshot &r_normalized) const;
	Status conversation_to_task_facts(
			const ConversationFactSnapshot &p_conversation_facts,
			TaskFactSnapshot &r_task_facts) const;
	Status ensure_task_request_still_pending(const TaskGraphInstance &p_task) const;
	Status remember_replay(
			TaskConversationOperation p_operation,
			std::uint64_t p_frame_revision,
			const std::string &p_identifier,
			std::uint64_t p_resulting_revision);
	const ReplayRecord *find_replay(
			TaskConversationOperation p_operation,
			std::uint64_t p_frame_revision,
			const std::string &p_identifier) const;
};

using TaskConversationOrchestrator = TaskConversationBridge;
using TaskConversationIntegration = TaskConversationBridge;
using TaskConversationContext = TaskConversationStartContext;

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_TASK_CONVERSATION_BRIDGE_H
