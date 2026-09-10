#ifndef LEVEL_TASK_SYSTEM_CORE_LEVEL_SESSION_H
#define LEVEL_TASK_SYSTEM_CORE_LEVEL_SESSION_H

#include "core/lts_catalog.h"
#include "core/lts_level_binding.h"
#include "core/lts_task_runtime.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

constexpr std::uint64_t NO_LEVEL_SESSION_EXPECTED_REVISION = UINT64_MAX;
constexpr std::uint64_t NO_LEVEL_SESSION_TICK = UINT64_MAX;

enum class LevelSessionStatus : std::uint8_t {
	INVALID = 0,
	RUNNING = 1,
	TRANSITION_PENDING = 2,
	WAITING_FOR_BINDING = 3,
	COMPLETED = 4,
	FAILED = 5,
};

using LevelSessionState = LevelSessionStatus;

enum class LevelTransitionResolution : std::uint8_t {
	ACKNOWLEDGED = 1,
	REJECTED = 2,
	TIMED_OUT = 3,
};

using LevelTransitionResultKind = LevelTransitionResolution;

// A host-facing transition DTO.  It carries intent only; scene loading,
// unloading, streaming, and actor placement remain host responsibilities.
struct LevelTransitionRequest {
	std::string request_identifier;
	std::string session_identifier;
	std::string scope_key;
	std::string source_level_identifier;
	std::string source_exit_identifier;
	std::string target_level_identifier;
	std::string target_anchor_identifier;
	std::vector<Value> parameters;
	CatalogFingerprint catalog_fingerprint = INVALID_CATALOG_FINGERPRINT;
	CatalogFingerprint source_level_fingerprint = INVALID_CATALOG_FINGERPRINT;
	CatalogFingerprint target_level_fingerprint = INVALID_CATALOG_FINGERPRINT;
	std::uint64_t created_revision = 0;
	std::uint64_t created_tick = 0;
	std::uint64_t timeout_tick = 0;
	bool has_timeout = false;

	Status validate() const;
	bool operator==(const LevelTransitionRequest &p_other) const;
	bool operator!=(const LevelTransitionRequest &p_other) const { return !(*this == p_other); }
};

using LevelSessionTransitionRequest = LevelTransitionRequest;
using LevelTransitionIntent = LevelTransitionRequest;

// An acknowledgement is a value from the host back to one request.  A
// repeated acknowledgement for a resolved identifier is explicitly idempotent.
struct LevelTransitionAcknowledgement {
	std::string request_identifier;
	std::string session_identifier;
	LevelTransitionResolution resolution = LevelTransitionResolution::ACKNOWLEDGED;
	std::string outcome_identifier;
	Value response = Value::none();
	CatalogFingerprint catalog_fingerprint = INVALID_CATALOG_FINGERPRINT;
	std::uint64_t expected_revision = NO_LEVEL_SESSION_EXPECTED_REVISION;
	std::uint64_t tick = NO_LEVEL_SESSION_TICK;
	std::uint64_t revision = 0;

	Status validate() const;
	bool operator==(const LevelTransitionAcknowledgement &p_other) const;
	bool operator!=(const LevelTransitionAcknowledgement &p_other) const { return !(*this == p_other); }
};

using LevelTransitionAck = LevelTransitionAcknowledgement;
using LevelSessionAcknowledgement = LevelTransitionAcknowledgement;
using LevelTransitionHostAcknowledgement = LevelTransitionAcknowledgement;

struct LevelSessionLimits {
	std::size_t max_pending_transitions = MAX_PENDING_REQUESTS;
	std::size_t max_resolved_transitions = MAX_RESOLVED_REQUEST_RECORDS;
	std::uint64_t request_timeout_ticks = 0;
	TaskRuntimeLimits task_runtime_limits;

	Status validate() const;
};

struct LevelSessionStartOptions {
	const LevelBinding *binding = nullptr;
	const LevelSceneRegistry *scene_registry = nullptr;
	bool require_binding = true;
	TaskRuntimeLimits task_runtime_limits;
	LevelSessionLimits limits;

	Status validate() const;
};

struct LevelSessionResult {
	Status status;
	bool changed = false;
	bool idempotent = false;
	std::uint64_t revision = 0;
	LevelSessionStatus session_status = LevelSessionStatus::INVALID;
	std::string level_identifier;
	bool has_acknowledgement = false;
	LevelTransitionAcknowledgement acknowledgement;
	std::vector<LevelTransitionRequest> transition_requests;
	std::vector<TaskExternalRequest> task_requests;
	std::vector<TaskAdvanceResult> task_results;
	bool transition_requests_truncated = false;

	bool ok() const { return status.ok(); }
	void clear();
};

// One explicit level/session owner.  The object owns copies of the sealed
// catalog and its task instances, so two sessions can use one definition in
// one process without sharing mutable progress.  No method loads or unloads
// a scene; the host attaches a validated LevelBinding after it has done so.
class LevelSession {
public:
	LevelSession() = default;

	static Status create(
			const LevelTaskCatalog &p_catalog,
			const std::string &p_level_identifier,
			const std::string &p_session_identifier,
			const std::string &p_scope_key,
			LevelSession &r_session,
			const LevelSessionStartOptions &p_options = LevelSessionStartOptions{},
			LevelSessionResult *r_result = nullptr);
	static Status start(
			const LevelTaskCatalog &p_catalog,
			const std::string &p_level_identifier,
			const std::string &p_session_identifier,
			const std::string &p_scope_key,
			LevelSession &r_session,
			const LevelSessionStartOptions &p_options = LevelSessionStartOptions{},
			LevelSessionResult *r_result = nullptr) {
		return create(p_catalog, p_level_identifier, p_session_identifier, p_scope_key, r_session, p_options, r_result);
	}
	static Status start(
			const LevelTaskCatalog &p_catalog,
			const std::string &p_level_identifier,
			const std::string &p_session_identifier,
			const std::string &p_scope_key,
			const LevelBinding &p_binding,
			LevelSession &r_session,
			const LevelSceneRegistry *p_scene_registry = nullptr,
			const LevelSessionLimits &p_limits = LevelSessionLimits{},
			LevelSessionResult *r_result = nullptr);
	static Status create_session(
			const LevelTaskCatalog &p_catalog,
			const std::string &p_session_identifier,
			const std::string &p_scope_key,
			const std::string &p_level_identifier,
			LevelSession &r_session,
			const LevelSessionStartOptions &p_options = LevelSessionStartOptions{},
			LevelSessionResult *r_result = nullptr) {
		return create(p_catalog, p_level_identifier, p_session_identifier, p_scope_key, r_session, p_options, r_result);
	}

	Status initialize(
			const LevelTaskCatalog &p_catalog,
			const std::string &p_level_identifier,
			const std::string &p_session_identifier,
			const std::string &p_scope_key,
			const LevelSessionStartOptions &p_options = LevelSessionStartOptions{},
			LevelSessionResult *r_result = nullptr);

	bool valid() const { return status_ != LevelSessionStatus::INVALID && catalog_.sealed() && !session_identifier_.empty() && !scope_key_.empty(); }
	bool is_valid() const { return valid(); }
	bool running() const { return status_ == LevelSessionStatus::RUNNING || status_ == LevelSessionStatus::TRANSITION_PENDING; }
	bool transition_pending() const { return !pending_transitions_.empty(); }
	bool waiting_for_binding() const { return status_ == LevelSessionStatus::WAITING_FOR_BINDING; }
	bool terminal() const { return status_ == LevelSessionStatus::COMPLETED || status_ == LevelSessionStatus::FAILED; }

	const LevelTaskCatalog &catalog() const { return catalog_; }
	CatalogFingerprint catalog_fingerprint() const { return catalog_.fingerprint(); }
	const LevelDefinition *definition() const;
	const LevelDefinition *level_definition() const { return definition(); }
	const std::string &level_identifier() const { return level_identifier_; }
	const std::string &current_level_identifier() const { return level_identifier_; }
	const std::string &session_identifier() const { return session_identifier_; }
	const std::string &session_id() const { return session_identifier_; }
	const std::string &scope_key() const { return scope_key_; }
	const std::string &host_scope_key() const { return scope_key_; }
	std::uint64_t revision() const { return revision_; }
	LevelSessionStatus status() const { return status_; }
	LevelSessionStatus session_status() const { return status_; }

	bool has_binding() const { return has_binding_; }
	const LevelBinding *binding() const { return has_binding_ ? &binding_ : nullptr; }

	std::size_t task_graph_count() const { return task_instances_.size(); }
	const TaskGraphInstance *task_graph(std::size_t p_index) const;
	TaskGraphInstance *task_graph(std::size_t p_index);
	const std::vector<TaskGraphInstance> &task_graphs() const { return task_instances_; }

	const std::vector<LevelTransitionRequest> &pending_transition_requests() const { return pending_transitions_; }
	const std::vector<LevelTransitionAcknowledgement> &resolved_transition_acknowledgements() const { return resolved_transitions_; }
	const LevelTransitionRequest *find_pending_transition(const std::string &p_request_identifier) const;
	const LevelTransitionAcknowledgement *find_resolved_transition(const std::string &p_request_identifier) const;

	Status attach_binding(
			const LevelBinding &p_binding,
			const LevelSceneRegistry *p_scene_registry = nullptr,
			LevelSessionResult *r_result = nullptr);
	Status set_binding(
			const LevelBinding &p_binding,
			const LevelSceneRegistry *p_scene_registry = nullptr,
			LevelSessionResult *r_result = nullptr) {
		return attach_binding(p_binding, p_scene_registry, r_result);
	}
	void clear_binding();

	Status advance(
			const std::vector<TaskEvent> &p_events,
			const TaskFactSnapshot &p_facts,
			std::uint64_t p_tick,
			LevelSessionResult *r_result = nullptr);
	Status advance(
			const std::vector<TaskEvent> &p_events,
			const TaskFactSnapshot &p_facts,
			LevelSessionResult *r_result = nullptr);
	Status tick(
			std::uint64_t p_tick,
			const TaskFactSnapshot &p_facts = TaskFactSnapshot{},
			LevelSessionResult *r_result = nullptr);

	// The preferred transition API resolves a named exit from the current
	// LevelDefinition, then emits a typed request for the host.  The request is
	// pending until acknowledge/reject/timeout is called.
	Status emit_transition_request(
			const std::string &p_exit_identifier,
			const std::vector<Value> &p_parameters = std::vector<Value>{},
			std::uint64_t p_tick = NO_LEVEL_SESSION_TICK,
			LevelTransitionRequest *r_request = nullptr,
			LevelSessionResult *r_result = nullptr);
	Status request_transition(
			const std::string &p_exit_identifier,
			const std::vector<Value> &p_parameters = std::vector<Value>{},
			std::uint64_t p_tick = NO_LEVEL_SESSION_TICK,
			LevelTransitionRequest *r_request = nullptr,
			LevelSessionResult *r_result = nullptr) {
		return emit_transition_request(p_exit_identifier, p_parameters, p_tick, r_request, r_result);
	}
	Status emit_level_transition_request(
			const std::string &p_exit_identifier,
			const std::vector<Value> &p_parameters = std::vector<Value>{},
			std::uint64_t p_tick = NO_LEVEL_SESSION_TICK,
			LevelTransitionRequest *r_request = nullptr,
			LevelSessionResult *r_result = nullptr) {
		return emit_transition_request(p_exit_identifier, p_parameters, p_tick, r_request, r_result);
	}

	Status acknowledge_transition(
			const LevelTransitionAcknowledgement &p_acknowledgement,
			const LevelBinding *p_target_binding = nullptr,
			const LevelSceneRegistry *p_scene_registry = nullptr,
			LevelSessionResult *r_result = nullptr);
	Status acknowledge_transition(
			const std::string &p_request_identifier,
			LevelTransitionResolution p_resolution = LevelTransitionResolution::ACKNOWLEDGED,
			const std::string &p_outcome_identifier = std::string(),
			const Value &p_response = Value::none(),
			std::uint64_t p_tick = NO_LEVEL_SESSION_TICK,
			std::uint64_t p_expected_revision = NO_LEVEL_SESSION_EXPECTED_REVISION,
			const LevelBinding *p_target_binding = nullptr,
			const LevelSceneRegistry *p_scene_registry = nullptr,
			LevelSessionResult *r_result = nullptr);
	Status acknowledge_request(
			const std::string &p_request_identifier,
			const std::string &p_outcome_identifier = std::string(),
			const Value &p_response = Value::none(),
			LevelSessionResult *r_result = nullptr) {
		return acknowledge_transition(p_request_identifier, LevelTransitionResolution::ACKNOWLEDGED,
				p_outcome_identifier, p_response, NO_LEVEL_SESSION_TICK, NO_LEVEL_SESSION_EXPECTED_REVISION, nullptr, nullptr, r_result);
	}
	Status reject_transition(
			const std::string &p_request_identifier,
			const Value &p_response = Value::none(),
			LevelSessionResult *r_result = nullptr);
	Status reject_request(
			const std::string &p_request_identifier,
			const Value &p_response = Value::none(),
			LevelSessionResult *r_result = nullptr) {
		return reject_transition(p_request_identifier, p_response, r_result);
	}
	Status timeout_transition(
			const std::string &p_request_identifier,
			LevelSessionResult *r_result = nullptr);
	Status timeout_request(
			const std::string &p_request_identifier,
			LevelSessionResult *r_result = nullptr) {
		return timeout_transition(p_request_identifier, r_result);
	}

private:
	LevelTaskCatalog catalog_;
	std::string level_identifier_;
	std::string session_identifier_;
	std::string scope_key_;
	std::uint64_t revision_ = 0;
	std::uint64_t next_transition_ordinal_ = 0;
	std::uint64_t last_tick_ = 0;
	bool has_tick_ = false;
	LevelSessionStatus status_ = LevelSessionStatus::INVALID;
	LevelBinding binding_;
	bool has_binding_ = false;
	LevelSceneRegistry scene_registry_;
	bool has_scene_registry_ = false;
	LevelSessionLimits limits_;
	std::vector<TaskGraphInstance> task_instances_;
	std::vector<LevelTransitionRequest> pending_transitions_;
	std::vector<LevelTransitionAcknowledgement> resolved_transitions_;

	Status validate_start(
			const LevelTaskCatalog &p_catalog,
			const std::string &p_level_identifier,
			const std::string &p_session_identifier,
			const std::string &p_scope_key,
			const LevelSessionStartOptions &p_options,
			const LevelDefinition *&r_level) const;
	Status start_entry_graphs(LevelSessionResult &r_result);
	Status start_level(
			const std::string &p_level_identifier,
			const LevelBinding *p_binding,
			const LevelSceneRegistry *p_scene_registry,
			LevelSessionResult &r_result);
	void update_status_from_graphs();
	std::string make_transition_identifier(const std::string &p_exit_identifier, std::uint64_t p_ordinal) const;
	Status emit_transition_request_internal(
			const LevelExitDefinition &p_exit,
			const LevelDefinition &p_target_level,
			const std::vector<Value> &p_parameters,
			std::uint64_t p_tick,
			LevelTransitionRequest &r_request,
			LevelSessionResult &r_result);
	Status resolve_transition_internal(
			const LevelTransitionRequest &p_request,
			LevelTransitionResolution p_resolution,
			const std::string &p_outcome_identifier,
			const Value &p_response,
			const LevelBinding *p_target_binding,
			const LevelSceneRegistry *p_scene_registry,
			std::uint64_t p_tick,
			std::uint64_t p_expected_revision,
			LevelSessionResult &r_result);
	Status expire_transitions(
			std::uint64_t p_tick,
			LevelSessionResult &r_result);
};

using LevelTaskSession = LevelSession;
using LevelSessionRuntime = LevelSession;

const char *level_session_status_name(LevelSessionStatus p_status);
const char *level_transition_resolution_name(LevelTransitionResolution p_resolution);

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_LEVEL_SESSION_H
