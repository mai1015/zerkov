#include "core/lts_level_session.h"

#include "core/lts_hash.h"
#include "core/lts_identifier.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace lts {

namespace {

bool known_resolution(LevelTransitionResolution p_resolution) {
	switch (p_resolution) {
		case LevelTransitionResolution::ACKNOWLEDGED:
		case LevelTransitionResolution::REJECTED:
		case LevelTransitionResolution::TIMED_OUT:
			return true;
	}
	return false;
}

std::string digest_hex(std::uint64_t p_digest) {
	static const char digits[] = "0123456789abcdef";
	std::string result(16, '0');
	for (std::size_t index = 0; index < result.size(); ++index) {
		const std::size_t shift = (result.size() - 1U - index) * 4U;
		result[index] = digits[static_cast<std::size_t>((p_digest >> shift) & 0x0fULL)];
	}
	return result;
}

std::size_t encoded_value_size(const Value &p_value) {
	std::size_t result = 1;
	switch (p_value.type) {
		case ValueType::NONE:
			return result;
		case ValueType::BOOLEAN:
			return result + 1;
		case ValueType::INTEGER:
		case ValueType::FIXED:
			return result + sizeof(std::int64_t);
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
			if (!std::holds_alternative<std::string>(p_value.payload)) return result;
			return result + sizeof(std::uint32_t) + std::get<std::string>(p_value.payload).size();
		case ValueType::BYTES:
			if (!std::holds_alternative<ByteVector>(p_value.payload)) return result;
			return result + sizeof(std::uint32_t) + std::get<ByteVector>(p_value.payload).size();
	}
	return result;
}

std::size_t encoded_values_size(const std::vector<Value> &p_values) {
	std::size_t result = sizeof(std::uint32_t);
	for (const Value &value : p_values) {
		const std::size_t item_size = encoded_value_size(value);
		if (result > std::numeric_limits<std::size_t>::max() - item_size) return std::numeric_limits<std::size_t>::max();
		result += item_size;
	}
	return result;
}

bool same_task_runtime_limits(const TaskRuntimeLimits &p_left, const TaskRuntimeLimits &p_right) {
	return p_left.max_facts_per_snapshot == p_right.max_facts_per_snapshot &&
			p_left.max_events_per_advance == p_right.max_events_per_advance &&
			p_left.max_transitions_per_advance == p_right.max_transitions_per_advance &&
			p_left.max_pending_requests == p_right.max_pending_requests &&
			p_left.max_transition_records == p_right.max_transition_records &&
			p_left.max_state_change_records == p_right.max_state_change_records &&
			p_left.max_trace_records == p_right.max_trace_records &&
			p_left.max_resolved_request_records == p_right.max_resolved_request_records &&
			p_left.request_timeout_ticks == p_right.request_timeout_ticks;
}

Status validate_optional_local_identifier(const std::string &p_value) {
	return p_value.empty() ? ok_status() : validate_local_identifier(p_value);
}

const LevelExitDefinition *find_exit(const LevelDefinition &p_level, const std::string &p_identifier) {
	for (const LevelExitDefinition &exit : p_level.exits) {
		if (exit.identifier == p_identifier) return &exit;
	}
	return nullptr;
}

void finish_result(const LevelSession &p_session, LevelSessionResult &r_result) {
	r_result.status = ok_status();
	r_result.revision = p_session.revision();
	r_result.session_status = p_session.status();
	r_result.level_identifier = p_session.current_level_identifier();
}

} // namespace

const char *level_session_status_name(LevelSessionStatus p_status) {
	switch (p_status) {
		case LevelSessionStatus::INVALID:
			return "invalid";
		case LevelSessionStatus::RUNNING:
			return "running";
		case LevelSessionStatus::TRANSITION_PENDING:
			return "transition_pending";
		case LevelSessionStatus::WAITING_FOR_BINDING:
			return "waiting_for_binding";
		case LevelSessionStatus::COMPLETED:
			return "completed";
		case LevelSessionStatus::FAILED:
			return "failed";
	}
	return "invalid";
}

const char *level_transition_resolution_name(LevelTransitionResolution p_resolution) {
	switch (p_resolution) {
		case LevelTransitionResolution::ACKNOWLEDGED:
			return "acknowledged";
		case LevelTransitionResolution::REJECTED:
			return "rejected";
		case LevelTransitionResolution::TIMED_OUT:
			return "timed_out";
	}
	return "invalid";
}

Status LevelTransitionRequest::validate() const {
	Status status = validate_identifier(request_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(session_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(scope_key);
	if (!status.ok()) return status;
	status = validate_identifier(source_level_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(source_exit_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(target_level_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(target_anchor_identifier);
	if (!status.ok()) return status;
	if (parameters.size() > MAX_NODE_PARAMETERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, parameters.size());
	}
	for (const Value &parameter : parameters) {
		status = parameter.validate();
		if (!status.ok()) return status;
	}
	if (encoded_values_size(parameters) > MAX_PROVIDER_PAYLOAD_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, encoded_values_size(parameters));
	}
	if (has_timeout && timeout_tick < created_tick) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE, timeout_tick);
	}
	return ok_status();
}

bool LevelTransitionRequest::operator==(const LevelTransitionRequest &p_other) const {
	return request_identifier == p_other.request_identifier && session_identifier == p_other.session_identifier &&
			scope_key == p_other.scope_key && source_level_identifier == p_other.source_level_identifier &&
			source_exit_identifier == p_other.source_exit_identifier && target_level_identifier == p_other.target_level_identifier &&
			target_anchor_identifier == p_other.target_anchor_identifier && parameters == p_other.parameters &&
			catalog_fingerprint == p_other.catalog_fingerprint && source_level_fingerprint == p_other.source_level_fingerprint &&
			target_level_fingerprint == p_other.target_level_fingerprint && created_revision == p_other.created_revision &&
			created_tick == p_other.created_tick && timeout_tick == p_other.timeout_tick && has_timeout == p_other.has_timeout;
}

Status LevelTransitionAcknowledgement::validate() const {
	Status status = validate_identifier(request_identifier);
	if (!status.ok()) return status;
	if (!session_identifier.empty()) {
		status = validate_identifier(session_identifier);
		if (!status.ok()) return status;
	}
	if (!known_resolution(resolution)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(resolution));
	}
	status = validate_optional_local_identifier(outcome_identifier);
	if (!status.ok()) return status;
	return response.validate();
}

bool LevelTransitionAcknowledgement::operator==(const LevelTransitionAcknowledgement &p_other) const {
	return request_identifier == p_other.request_identifier && session_identifier == p_other.session_identifier &&
			resolution == p_other.resolution && outcome_identifier == p_other.outcome_identifier && response == p_other.response &&
			catalog_fingerprint == p_other.catalog_fingerprint && expected_revision == p_other.expected_revision &&
			tick == p_other.tick && revision == p_other.revision;
}

Status LevelSessionLimits::validate() const {
	if (max_pending_transitions == 0 || max_pending_transitions > MAX_PENDING_REQUESTS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_pending_transitions);
	}
	if (max_resolved_transitions == 0 || max_resolved_transitions > MAX_RESOLVED_REQUEST_RECORDS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_resolved_transitions);
	}
	return task_runtime_limits.validate();
}

Status LevelSessionStartOptions::validate() const {
	Status status = limits.validate();
	if (!status.ok()) return status;
	// Keep the top-level field as an ergonomic alias for callers that do not
	// need the rest of LevelSessionLimits.  Both values must remain bounded.
	return task_runtime_limits.validate();
}

void LevelSessionResult::clear() {
	*this = LevelSessionResult{};
}

Status LevelSession::validate_start(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const std::string &p_session_identifier,
		const std::string &p_scope_key,
		const LevelSessionStartOptions &p_options,
		const LevelDefinition *&r_level) const {
	r_level = nullptr;
	if (!p_catalog.sealed()) return make_status(StatusCode::CATALOG_NOT_SEALED);
	Status status = p_options.validate();
	if (!status.ok()) return status;
	status = validate_identifier(p_level_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(p_session_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(p_scope_key);
	if (!status.ok()) return status;
	status = p_catalog.resolve_level(p_level_identifier, r_level);
	if (!status.ok() || r_level == nullptr) return status.ok() ? make_status(StatusCode::UNKNOWN_DEFINITION,
			DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_level_identifier)) : status;
	if (p_options.scene_registry != nullptr) {
		status = p_options.scene_registry->validate();
		if (!status.ok()) return status;
		if (!p_options.scene_registry->has_scene(r_level->scene_resource)) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID,
					hash_string(r_level->scene_resource));
		}
	}
	if (p_options.binding != nullptr) {
		LevelBindingValidationReport report;
		status = p_options.binding->validate(*r_level, report);
		if (!status.ok()) return status;
	} else if (p_options.require_binding) {
		return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_ANCHOR_INVALID,
				hash_string(r_level->identifier));
	}
	return ok_status();
}

Status LevelSession::create(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const std::string &p_session_identifier,
		const std::string &p_scope_key,
		LevelSession &r_session,
		const LevelSessionStartOptions &p_options,
		LevelSessionResult *r_result) {
	LevelSession candidate;
	const LevelDefinition *level = nullptr;
	Status status = candidate.validate_start(p_catalog, p_level_identifier, p_session_identifier, p_scope_key, p_options, level);
	LevelSessionResult local_result;
	local_result.clear();
	if (!status.ok()) {
		local_result.status = status;
		local_result.session_status = r_session.status_;
		local_result.level_identifier = r_session.level_identifier_;
		local_result.revision = r_session.revision_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	candidate.catalog_ = p_catalog;
	candidate.level_identifier_ = p_level_identifier;
	candidate.session_identifier_ = p_session_identifier;
	candidate.scope_key_ = p_scope_key;
	candidate.limits_ = p_options.limits;
	// The nested value is canonical.  Honor the top-level convenience alias
	// when it is the only value customized, so both forms remain useful without
	// making an unspecified default overwrite a nested budget.
	const TaskRuntimeLimits default_task_limits;
	if (same_task_runtime_limits(candidate.limits_.task_runtime_limits, default_task_limits) &&
			!same_task_runtime_limits(p_options.task_runtime_limits, default_task_limits)) {
		candidate.limits_.task_runtime_limits = p_options.task_runtime_limits;
	}
	if (p_options.scene_registry != nullptr) {
		candidate.scene_registry_ = *p_options.scene_registry;
		candidate.has_scene_registry_ = true;
	}
	if (p_options.binding != nullptr) {
		status = candidate.start_level(p_level_identifier, p_options.binding, p_options.scene_registry, local_result);
		if (!status.ok()) {
			local_result.clear();
			local_result.status = status;
			local_result.session_status = r_session.status_;
			local_result.level_identifier = r_session.level_identifier_;
			local_result.revision = r_session.revision_;
			if (r_result != nullptr) *r_result = local_result;
			return status;
		}
	} else {
		candidate.status_ = LevelSessionStatus::WAITING_FOR_BINDING;
	}
	candidate.revision_ = 1;
	local_result.changed = true;
	local_result.status = ok_status();
	local_result.revision = candidate.revision_;
	local_result.session_status = candidate.status_;
	local_result.level_identifier = candidate.level_identifier_;
	r_session = std::move(candidate);
	if (r_result != nullptr) *r_result = std::move(local_result);
	return ok_status();
}

Status LevelSession::start(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const std::string &p_session_identifier,
		const std::string &p_scope_key,
		const LevelBinding &p_binding,
		LevelSession &r_session,
		const LevelSceneRegistry *p_scene_registry,
		const LevelSessionLimits &p_limits,
		LevelSessionResult *r_result) {
	LevelSessionStartOptions options;
	options.binding = &p_binding;
	options.scene_registry = p_scene_registry;
	options.limits = p_limits;
	options.task_runtime_limits = p_limits.task_runtime_limits;
	return create(p_catalog, p_level_identifier, p_session_identifier, p_scope_key, r_session, options, r_result);
}

Status LevelSession::initialize(
		const LevelTaskCatalog &p_catalog,
		const std::string &p_level_identifier,
		const std::string &p_session_identifier,
		const std::string &p_scope_key,
		const LevelSessionStartOptions &p_options,
		LevelSessionResult *r_result) {
	return create(p_catalog, p_level_identifier, p_session_identifier, p_scope_key, *this, p_options, r_result);
}

const LevelDefinition *LevelSession::definition() const {
	if (!catalog_.sealed() || level_identifier_.empty()) return nullptr;
	return catalog_.find_level(level_identifier_);
}

const TaskGraphInstance *LevelSession::task_graph(std::size_t p_index) const {
	return p_index < task_instances_.size() ? &task_instances_[p_index] : nullptr;
}

TaskGraphInstance *LevelSession::task_graph(std::size_t p_index) {
	return p_index < task_instances_.size() ? &task_instances_[p_index] : nullptr;
}

const LevelTransitionRequest *LevelSession::find_pending_transition(const std::string &p_request_identifier) const {
	for (const LevelTransitionRequest &request : pending_transitions_) {
		if (request.request_identifier == p_request_identifier) return &request;
	}
	return nullptr;
}

const LevelTransitionAcknowledgement *LevelSession::find_resolved_transition(const std::string &p_request_identifier) const {
	for (const LevelTransitionAcknowledgement &acknowledgement : resolved_transitions_) {
		if (acknowledgement.request_identifier == p_request_identifier) return &acknowledgement;
	}
	return nullptr;
}

Status LevelSession::start_entry_graphs(LevelSessionResult &r_result) {
	const LevelDefinition *level = definition();
	if (level == nullptr) return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
			hash_string(level_identifier_));
	std::vector<TaskGraphInstance> candidate_instances;
	candidate_instances.reserve(level->entry_graph_identifiers.size());
	for (const std::string &graph_identifier : level->entry_graph_identifiers) {
		const TaskGraphDefinition *graph_definition = nullptr;
		Status status = catalog_.resolve_task_graph(graph_identifier, graph_definition);
		if (!status.ok() || graph_definition == nullptr) {
			return status.ok() ? make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID,
					hash_string(graph_identifier)) : status;
		}
		CanonicalTaskGraph compiled;
		std::vector<Diagnostic> diagnostics;
		status = TaskGraphCompiler().compile(*graph_definition, compiled, &diagnostics);
		if (!status.ok()) return status;
		Hasher hasher;
		hasher.write_string("lts.level-session-task.v1");
		hasher.write_u64(catalog_.fingerprint());
		hasher.write_string(session_identifier_);
		hasher.write_string(scope_key_);
		hasher.write_string(level_identifier_);
		hasher.write_string(graph_identifier);
		// Every identifier segment must begin with a letter; the digest is
		// prefixed so a leading hexadecimal digit cannot make a malformed ID.
		const std::string instance_identifier = "task.instance.r" + digest_hex(hasher.digest());
		TaskGraphInstance instance;
		TaskAdvanceResult start_result;
		status = TaskGraphInstance::start(compiled, instance_identifier, scope_key_, instance, limits_.task_runtime_limits, &start_result);
		if (!status.ok()) return status;
		candidate_instances.push_back(std::move(instance));
		r_result.task_results.push_back(std::move(start_result));
	}
	task_instances_ = std::move(candidate_instances);
	update_status_from_graphs();
	return ok_status();
}

Status LevelSession::start_level(
		const std::string &p_level_identifier,
		const LevelBinding *p_binding,
		const LevelSceneRegistry *p_scene_registry,
		LevelSessionResult &r_result) {
	const LevelSceneRegistry *scene_registry = p_scene_registry != nullptr ? p_scene_registry :
			(has_scene_registry_ ? &scene_registry_ : nullptr);
	const LevelDefinition *level = nullptr;
	Status status = catalog_.resolve_level(p_level_identifier, level);
	if (!status.ok() || level == nullptr) return status.ok() ? make_status(StatusCode::UNKNOWN_DEFINITION,
			DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_level_identifier)) : status;
	if (scene_registry != nullptr && !scene_registry->has_scene(level->scene_resource)) {
		return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID,
				hash_string(level->scene_resource));
	}
	if (p_binding == nullptr) {
		level_identifier_ = p_level_identifier;
		has_binding_ = false;
		binding_.clear_anchors();
		task_instances_.clear();
		status_ = LevelSessionStatus::WAITING_FOR_BINDING;
		return ok_status();
	}
	LevelBindingValidationReport report;
	status = p_binding->validate(*level, report);
	if (!status.ok()) return status;
	level_identifier_ = p_level_identifier;
	binding_ = *p_binding;
	has_binding_ = true;
	task_instances_.clear();
	status = start_entry_graphs(r_result);
	if (!status.ok()) return status;
	return ok_status();
}

void LevelSession::update_status_from_graphs() {
	if (!has_binding_) {
		status_ = LevelSessionStatus::WAITING_FOR_BINDING;
		return;
	}
	if (task_instances_.empty()) {
		status_ = LevelSessionStatus::RUNNING;
		return;
	}
	bool all_succeeded = true;
	for (const TaskGraphInstance &instance : task_instances_) {
		if (instance.status() == TaskGraphInstanceStatus::FAILED || instance.status() == TaskGraphInstanceStatus::CANCELLED ||
				instance.status() == TaskGraphInstanceStatus::STALLED || !instance.valid()) {
			status_ = LevelSessionStatus::FAILED;
			return;
		}
		if (instance.status() != TaskGraphInstanceStatus::SUCCEEDED) all_succeeded = false;
	}
	status_ = all_succeeded ? LevelSessionStatus::COMPLETED :
			(pending_transitions_.empty() ? LevelSessionStatus::RUNNING : LevelSessionStatus::TRANSITION_PENDING);
}

std::string LevelSession::make_transition_identifier(const std::string &p_exit_identifier, std::uint64_t p_ordinal) const {
	Hasher hasher;
	hasher.write_string("lts.level-transition.v1");
	hasher.write_u64(catalog_.fingerprint());
	hasher.write_string(session_identifier_);
	hasher.write_string(scope_key_);
	hasher.write_string(level_identifier_);
	hasher.write_string(p_exit_identifier);
	hasher.write_u64(p_ordinal);
	// Every identifier segment must begin with a letter; prefix the digest
	// segment so values beginning with 0-9 remain valid stable identifiers.
	return "request.level.r" + digest_hex(hasher.digest());
}

Status LevelSession::emit_transition_request_internal(
		const LevelExitDefinition &p_exit,
		const LevelDefinition &p_target_level,
		const std::vector<Value> &p_parameters,
		std::uint64_t p_tick,
		LevelTransitionRequest &r_request,
		LevelSessionResult &r_result) {
	if (pending_transitions_.size() >= limits_.max_pending_transitions) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, pending_transitions_.size() + 1);
	}
	std::uint64_t ordinal = next_transition_ordinal_;
	if (ordinal == std::numeric_limits<std::uint64_t>::max()) return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
	LevelTransitionRequest request;
	request.session_identifier = session_identifier_;
	request.scope_key = scope_key_;
	request.source_level_identifier = level_identifier_;
	request.source_exit_identifier = p_exit.identifier;
	request.target_level_identifier = p_exit.target_level_identifier;
	request.target_anchor_identifier = p_exit.target_anchor_identifier;
	request.parameters = p_parameters;
	request.catalog_fingerprint = catalog_.fingerprint();
	request.source_level_fingerprint = definition() == nullptr ? INVALID_CATALOG_FINGERPRINT : definition()->fingerprint();
	request.target_level_fingerprint = p_target_level.fingerprint();
	request.request_identifier = make_transition_identifier(p_exit.identifier, ordinal);
	request.created_revision = revision_ + 1;
	request.created_tick = p_tick;
	if (limits_.request_timeout_ticks != 0) {
		if (p_tick > std::numeric_limits<std::uint64_t>::max() - limits_.request_timeout_ticks) {
			return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
		}
		request.has_timeout = true;
		request.timeout_tick = p_tick + limits_.request_timeout_ticks;
	}
	Status status = request.validate();
	if (!status.ok()) return status;
	pending_transitions_.push_back(request);
	next_transition_ordinal_ = ordinal + 1;
	status_ = LevelSessionStatus::TRANSITION_PENDING;
	r_request = request;
	r_result.transition_requests.push_back(request);
	r_result.changed = true;
	return ok_status();
}

Status LevelSession::emit_transition_request(
		const std::string &p_exit_identifier,
		const std::vector<Value> &p_parameters,
		std::uint64_t p_tick,
		LevelTransitionRequest *r_request,
		LevelSessionResult *r_result) {
	LevelSessionResult local_result;
	local_result.clear();
	if (!valid() || status_ == LevelSessionStatus::WAITING_FOR_BINDING || terminal()) {
		const Status status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_EXIT_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	const LevelDefinition *level = definition();
	if (level == nullptr) {
		const Status status = make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(level_identifier_));
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	const LevelExitDefinition *exit = find_exit(*level, p_exit_identifier);
	if (exit == nullptr) {
		const Status status = make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_EXIT_INVALID, hash_string(p_exit_identifier));
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	const LevelDefinition *target_level = nullptr;
	Status status = catalog_.resolve_level(exit->target_level_identifier, target_level);
	if (!status.ok() || target_level == nullptr) {
		status = status.ok() ? make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_EXIT_INVALID,
				hash_string(exit->target_level_identifier)) : status;
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	bool target_anchor_found = false;
	for (const LevelAnchorDefinition &anchor : target_level->anchors) {
		if (anchor.identifier == exit->target_anchor_identifier) {
			target_anchor_found = true;
			break;
		}
	}
	if (!target_anchor_found) {
		status = make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_ANCHOR_INVALID,
				hash_string(exit->target_anchor_identifier));
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	if (p_parameters.size() > MAX_NODE_PARAMETERS) status = make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_parameters.size());
	if (status.ok()) {
		for (const Value &parameter : p_parameters) {
			status = parameter.validate();
			if (!status.ok()) break;
		}
	}
	if (status.ok() && encoded_values_size(p_parameters) > MAX_PROVIDER_PAYLOAD_BYTES) {
		status = make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, encoded_values_size(p_parameters));
	}
	const bool tick_supplied = p_tick != NO_LEVEL_SESSION_TICK;
	const std::uint64_t tick = tick_supplied ? p_tick : (has_tick_ ? last_tick_ : 0);
	if (status.ok() && tick_supplied && has_tick_ && p_tick < last_tick_) {
		status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
	}
	if (!status.ok()) {
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	LevelSession candidate = *this;
	if (tick_supplied) {
		candidate.last_tick_ = p_tick;
		candidate.has_tick_ = true;
	}
	LevelTransitionRequest request;
	status = candidate.emit_transition_request_internal(*exit, *target_level, p_parameters, tick, request, local_result);
	if (!status.ok()) {
		local_result.clear();
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	candidate.revision_ = revision_ + 1;
	finish_result(candidate, local_result);
	local_result.changed = true;
	if (r_request != nullptr) *r_request = request;
	*this = std::move(candidate);
	if (r_result != nullptr) *r_result = local_result;
	return ok_status();
}

Status LevelSession::attach_binding(
		const LevelBinding &p_binding,
		const LevelSceneRegistry *p_scene_registry,
		LevelSessionResult *r_result) {
	LevelSessionResult local_result;
	local_result.clear();
	if (!valid()) {
		const Status status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_ANCHOR_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	if (has_binding_ && status_ != LevelSessionStatus::WAITING_FOR_BINDING) {
		const Status status = make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::LEVEL_ANCHOR_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	LevelSession candidate = *this;
	if (p_scene_registry != nullptr) {
		Status status = p_scene_registry->validate();
		if (!status.ok()) {
			local_result.status = status;
			local_result.revision = revision_;
			local_result.session_status = status_;
			if (r_result != nullptr) *r_result = local_result;
			return status;
		}
		candidate.scene_registry_ = *p_scene_registry;
		candidate.has_scene_registry_ = true;
	}
	Status status = candidate.start_level(candidate.level_identifier_, &p_binding, p_scene_registry, local_result);
	if (!status.ok()) {
		local_result.clear();
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	candidate.revision_ = revision_ + 1;
	local_result.changed = true;
	finish_result(candidate, local_result);
	*this = std::move(candidate);
	if (r_result != nullptr) *r_result = local_result;
	return ok_status();
}

void LevelSession::clear_binding() {
	has_binding_ = false;
	binding_.clear_anchors();
	status_ = LevelSessionStatus::WAITING_FOR_BINDING;
}

Status LevelSession::advance(
		const std::vector<TaskEvent> &p_events,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		LevelSessionResult *r_result) {
	LevelSessionResult local_result;
	local_result.clear();
	if (!valid() || status_ == LevelSessionStatus::WAITING_FOR_BINDING || terminal()) {
		const Status status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	if (has_tick_ && p_tick < last_tick_) {
		const Status status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	LevelSession candidate = *this;
	if (p_tick >= candidate.last_tick_ || !candidate.has_tick_) {
		candidate.last_tick_ = p_tick;
		candidate.has_tick_ = true;
	}
	Status status = candidate.expire_transitions(p_tick, local_result);
	if (!status.ok()) {
		local_result.clear();
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		local_result.level_identifier = level_identifier_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	bool task_changed = false;
	for (TaskGraphInstance &instance : candidate.task_instances_) {
		TaskAdvanceResult task_result;
		status = instance.advance(p_events, p_facts, p_tick, &task_result);
		if (!status.ok()) {
			local_result.clear();
			local_result.status = status;
			local_result.revision = revision_;
			local_result.session_status = status_;
			local_result.level_identifier = level_identifier_;
			if (r_result != nullptr) *r_result = local_result;
			return status;
		}
		for (const TaskExternalRequest &request : task_result.requests) {
			if (local_result.task_requests.size() < limits_.max_pending_transitions) local_result.task_requests.push_back(request);
		}
		task_changed = task_changed || task_result.changed;
		local_result.task_results.push_back(std::move(task_result));
	}
	const LevelSessionStatus previous_session_status = candidate.status_;
	candidate.update_status_from_graphs();
	const bool changed = local_result.changed || task_changed || candidate.last_tick_ != last_tick_ ||
			candidate.status_ != previous_session_status;
	// A supplied facts snapshot is intentionally delegated to each graph.  A
	// no-op with no graph instances is still represented by the tick change.
	local_result.changed = changed;
	if (changed) candidate.revision_ = revision_ + 1;
	local_result.status = ok_status();
	local_result.revision = candidate.revision_;
	local_result.session_status = candidate.status_;
	local_result.level_identifier = candidate.level_identifier_;
	*this = std::move(candidate);
	if (r_result != nullptr) *r_result = local_result;
	return ok_status();
}

Status LevelSession::advance(
		const std::vector<TaskEvent> &p_events,
		const TaskFactSnapshot &p_facts,
		LevelSessionResult *r_result) {
	return advance(p_events, p_facts, has_tick_ ? last_tick_ : 0, r_result);
}

Status LevelSession::tick(
		std::uint64_t p_tick,
		const TaskFactSnapshot &p_facts,
		LevelSessionResult *r_result) {
	return advance(std::vector<TaskEvent>{}, p_facts, p_tick, r_result);
}

Status LevelSession::resolve_transition_internal(
		const LevelTransitionRequest &p_request,
		LevelTransitionResolution p_resolution,
		const std::string &p_outcome_identifier,
		const Value &p_response,
		const LevelBinding *p_target_binding,
		const LevelSceneRegistry *p_scene_registry,
		std::uint64_t p_tick,
		std::uint64_t p_expected_revision,
		LevelSessionResult &r_result) {
	if (!known_resolution(p_resolution)) return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM,
			static_cast<std::uint8_t>(p_resolution));
	if (!p_request.validate().ok()) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_EXIT_INVALID);
	if (!p_request.session_identifier.empty() && p_request.session_identifier != session_identifier_) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
	}
	if (p_request.catalog_fingerprint != INVALID_CATALOG_FINGERPRINT && p_request.catalog_fingerprint != catalog_.fingerprint()) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::CATALOG_FINGERPRINT_DIFFERS,
				p_request.catalog_fingerprint);
	}
	if (p_expected_revision != NO_LEVEL_SESSION_EXPECTED_REVISION && p_expected_revision != revision_) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_expected_revision);
	}
	if (p_tick != NO_LEVEL_SESSION_TICK && has_tick_ && p_tick < last_tick_) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
	}
	std::string outcome = p_outcome_identifier;
	if (p_resolution == LevelTransitionResolution::REJECTED) outcome = "rejected";
	if (p_resolution == LevelTransitionResolution::TIMED_OUT) outcome = "timeout";
	if (p_resolution == LevelTransitionResolution::ACKNOWLEDGED && outcome.empty()) {
		const LevelDefinition *source = catalog_.find_level(p_request.source_level_identifier);
		const LevelExitDefinition *exit = source == nullptr ? nullptr : find_exit(*source, p_request.source_exit_identifier);
		outcome = exit == nullptr || exit->outcome_identifier.empty() ? "success" : exit->outcome_identifier;
	}
	Status status = validate_local_identifier(outcome);
	if (!status.ok()) return status;
	status = p_response.validate();
	if (!status.ok()) return status;
	const LevelSceneRegistry *scene_registry = p_scene_registry != nullptr ? p_scene_registry :
			(has_scene_registry_ ? &scene_registry_ : nullptr);
	if (p_scene_registry != nullptr) {
		status = p_scene_registry->validate();
		if (!status.ok()) return status;
		scene_registry_ = *p_scene_registry;
		has_scene_registry_ = true;
		scene_registry = &scene_registry_;
	}
	if (p_resolution == LevelTransitionResolution::ACKNOWLEDGED) {
		const LevelDefinition *target = catalog_.find_level(p_request.target_level_identifier);
		if (target == nullptr) return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_EXIT_INVALID,
				hash_string(p_request.target_level_identifier));
		if (scene_registry != nullptr && !scene_registry->has_scene(target->scene_resource)) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID,
				hash_string(target->scene_resource));
		}
		if (p_target_binding != nullptr) {
			LevelBindingValidationReport report;
			status = p_target_binding->validate(*target, report);
			if (!status.ok()) return status;
		}
	}
	const std::uint64_t tick = p_tick == NO_LEVEL_SESSION_TICK ? (has_tick_ ? last_tick_ : p_request.created_tick) : p_tick;
	if (p_tick != NO_LEVEL_SESSION_TICK) {
		last_tick_ = tick;
		has_tick_ = true;
	}
	for (std::size_t index = 0; index < pending_transitions_.size(); ++index) {
		if (pending_transitions_[index].request_identifier != p_request.request_identifier) continue;
		pending_transitions_.erase(pending_transitions_.begin() + static_cast<std::ptrdiff_t>(index));
		LevelTransitionAcknowledgement acknowledgement;
		acknowledgement.request_identifier = p_request.request_identifier;
		acknowledgement.session_identifier = session_identifier_;
		acknowledgement.resolution = p_resolution;
		acknowledgement.outcome_identifier = outcome;
		acknowledgement.response = p_response;
		acknowledgement.catalog_fingerprint = catalog_.fingerprint();
		acknowledgement.tick = p_tick;
		acknowledgement.revision = revision_ + 1;
		status = acknowledgement.validate();
		if (!status.ok()) return status;
		if (resolved_transitions_.size() >= limits_.max_resolved_transitions) resolved_transitions_.erase(resolved_transitions_.begin());
		resolved_transitions_.push_back(acknowledgement);
		r_result.has_acknowledgement = true;
		r_result.acknowledgement = acknowledgement;
		r_result.changed = true;
		if (p_resolution == LevelTransitionResolution::ACKNOWLEDGED) {
			// The host's acknowledgement is the authority to change session
			// metadata.  This does not load or unload a scene.  If no target
			// binding was supplied, the session explicitly waits for the host to
			// attach one after its own scene orchestration.
			level_identifier_ = p_request.target_level_identifier;
			task_instances_.clear();
			if (p_target_binding != nullptr) {
				status = start_level(level_identifier_, p_target_binding, scene_registry, r_result);
				if (!status.ok()) return status;
			} else {
				has_binding_ = false;
				binding_.clear_anchors();
				status_ = LevelSessionStatus::WAITING_FOR_BINDING;
			}
		} else {
			update_status_from_graphs();
		}
		if (status_ != LevelSessionStatus::WAITING_FOR_BINDING && !pending_transitions_.empty()) status_ = LevelSessionStatus::TRANSITION_PENDING;
		return ok_status();
	}
	return make_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_request.request_identifier));
}

Status LevelSession::acknowledge_transition(
		const LevelTransitionAcknowledgement &p_acknowledgement,
		const LevelBinding *p_target_binding,
		const LevelSceneRegistry *p_scene_registry,
		LevelSessionResult *r_result) {
	LevelSessionResult local_result;
	local_result.clear();
	Status status = p_acknowledgement.validate();
	if (!status.ok()) {
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	const LevelTransitionAcknowledgement *resolved = find_resolved_transition(p_acknowledgement.request_identifier);
	if (resolved != nullptr) {
		local_result.idempotent = true;
		local_result.changed = false;
		local_result.has_acknowledgement = true;
		local_result.acknowledgement = *resolved;
		finish_result(*this, local_result);
		if (r_result != nullptr) *r_result = local_result;
		return ok_status();
	}
	const LevelTransitionRequest *pending = find_pending_transition(p_acknowledgement.request_identifier);
	if (pending == nullptr) {
		status = make_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				hash_string(p_acknowledgement.request_identifier));
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	if (!p_acknowledgement.session_identifier.empty() && p_acknowledgement.session_identifier != session_identifier_) {
		status = make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	if (p_acknowledgement.catalog_fingerprint != INVALID_CATALOG_FINGERPRINT &&
			p_acknowledgement.catalog_fingerprint != catalog_.fingerprint()) {
		status = make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::CATALOG_FINGERPRINT_DIFFERS,
				p_acknowledgement.catalog_fingerprint);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	LevelSession candidate = *this;
	status = candidate.resolve_transition_internal(*pending, p_acknowledgement.resolution, p_acknowledgement.outcome_identifier,
			p_acknowledgement.response, p_target_binding, p_scene_registry, p_acknowledgement.tick,
			p_acknowledgement.expected_revision, local_result);
	if (!status.ok()) {
		local_result.clear();
		local_result.status = status;
		local_result.revision = revision_;
		local_result.session_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	candidate.revision_ = revision_ + 1;
	local_result.changed = true;
	finish_result(candidate, local_result);
	*this = std::move(candidate);
	if (r_result != nullptr) *r_result = local_result;
	return ok_status();
}

Status LevelSession::acknowledge_transition(
		const std::string &p_request_identifier,
		LevelTransitionResolution p_resolution,
		const std::string &p_outcome_identifier,
		const Value &p_response,
		std::uint64_t p_tick,
		std::uint64_t p_expected_revision,
		const LevelBinding *p_target_binding,
		const LevelSceneRegistry *p_scene_registry,
		LevelSessionResult *r_result) {
	LevelTransitionAcknowledgement acknowledgement;
	acknowledgement.request_identifier = p_request_identifier;
	acknowledgement.session_identifier = session_identifier_;
	acknowledgement.resolution = p_resolution;
	acknowledgement.outcome_identifier = p_outcome_identifier;
	acknowledgement.response = p_response;
	acknowledgement.expected_revision = p_expected_revision;
	acknowledgement.tick = p_tick;
	LevelSessionResult local_result;
	Status status = acknowledge_transition(acknowledgement, p_target_binding, p_scene_registry, &local_result);
	if (status.ok() && p_tick != NO_LEVEL_SESSION_TICK && !local_result.idempotent) {
		// The value overload validates and applies an explicit host tick before
		// committing.  Re-run is deliberately avoided: a tick is only metadata
		// for the session request, not a scene operation.
	}
	if (r_result != nullptr) *r_result = local_result;
	return status;
}

Status LevelSession::reject_transition(
		const std::string &p_request_identifier,
		const Value &p_response,
		LevelSessionResult *r_result) {
	return acknowledge_transition(p_request_identifier, LevelTransitionResolution::REJECTED, "rejected", p_response,
			NO_LEVEL_SESSION_TICK, NO_LEVEL_SESSION_EXPECTED_REVISION, nullptr, nullptr, r_result);
}

Status LevelSession::timeout_transition(const std::string &p_request_identifier, LevelSessionResult *r_result) {
	return acknowledge_transition(p_request_identifier, LevelTransitionResolution::TIMED_OUT, "timeout", Value::none(),
			NO_LEVEL_SESSION_TICK, NO_LEVEL_SESSION_EXPECTED_REVISION, nullptr, nullptr, r_result);
}

Status LevelSession::expire_transitions(std::uint64_t p_tick, LevelSessionResult &r_result) {
	if (has_tick_ && p_tick < last_tick_) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
	std::size_t index = 0;
	while (index < pending_transitions_.size()) {
		const LevelTransitionRequest request = pending_transitions_[index];
		if (!request.has_timeout || p_tick < request.timeout_tick) {
			++index;
			continue;
		}
		const Status status = resolve_transition_internal(request, LevelTransitionResolution::TIMED_OUT, "timeout", Value::none(),
				nullptr, nullptr, p_tick, NO_LEVEL_SESSION_EXPECTED_REVISION, r_result);
		if (!status.ok()) return status;
	}
	return ok_status();
}

} // namespace lts
