#include "core/lts_task_conversation_bridge.h"

#include "core/lts_hash.h"
#include "core/lts_identifier.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>

namespace lts {

namespace {

Status bridge_invalid(
		DiagnosticId p_diagnostic = DiagnosticId::GRAPH_PAYLOAD_INVALID,
		std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_ARGUMENT, p_diagnostic, p_detail);
}

Status bridge_reference(
		DiagnosticId p_diagnostic = DiagnosticId::GRAPH_NODE_REFERENCE_INVALID,
		std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_REFERENCE, p_diagnostic, p_detail);
}

Status bridge_not_found(std::uint64_t p_detail = 0) {
	return make_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, p_detail);
}

bool contains_identifier(const std::vector<std::string> &p_values, const std::string &p_value) {
	return std::find(p_values.begin(), p_values.end(), p_value) != p_values.end();
}

std::size_t encoded_value_size(const Value &p_value) {
	std::size_t result = 1; // value type
	switch (p_value.type) {
		case ValueType::NONE:
			break;
		case ValueType::BOOLEAN:
			result += 1;
			break;
		case ValueType::INTEGER:
		case ValueType::FIXED:
			result += sizeof(std::int64_t);
			break;
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
			result += sizeof(std::uint32_t);
			if (std::holds_alternative<std::string>(p_value.payload)) result += std::get<std::string>(p_value.payload).size();
			break;
		case ValueType::BYTES:
			result += sizeof(std::uint32_t);
			if (std::holds_alternative<ByteVector>(p_value.payload)) result += std::get<ByteVector>(p_value.payload).size();
			break;
	}
	return result;
}

std::size_t encoded_values_size(const std::vector<Value> &p_values) {
	std::size_t result = sizeof(std::uint32_t);
	for (const Value &value : p_values) {
		const std::size_t value_size = encoded_value_size(value);
		if (result > std::numeric_limits<std::size_t>::max() - value_size) return std::numeric_limits<std::size_t>::max();
		result += value_size;
	}
	return result;
}

bool has_task_fact_payload(const TaskConversationStartContext &p_context) {
	return p_context.write_task_facts || !p_context.task_facts.empty() || !p_context.task_facts.scope_key().empty();
}

bool same_task_request_identity(const TaskExternalRequest &p_left, const TaskExternalRequest &p_right) {
	// A task request is the complete immutable correlation envelope. Comparing
	// the full public value also rejects a replay that keeps the request ID but
	// changes its authored parameters or creation metadata.
	return p_left == p_right;
}

bool conversation_frame_changed(const ConversationInstance &p_before, const ConversationInstance &p_after) {
	return p_before.revision() != p_after.revision() ||
			p_before.status() != p_after.status() ||
			p_before.current_step_identifier() != p_after.current_step_identifier() ||
			p_before.outcome_identifier() != p_after.outcome_identifier() ||
			p_before.frame().kind != p_after.frame().kind ||
			p_before.frame().revision != p_after.frame().revision ||
			p_before.frame().step_identifier != p_after.frame().step_identifier ||
			p_before.frame().choices != p_after.frame().choices ||
			p_before.frame().line_key != p_after.frame().line_key;
}

} // namespace

Status TaskConversationCorrelation::validate() const {
	Status status = validate_identifier(task_request_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(task_instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(task_scope_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(task_node_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(conversation_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(conversation_instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(task_integration_handle);
	if (!status.ok()) return status;
	if (conversation_definition_fingerprint == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	return ok_status();
}

bool TaskConversationCorrelation::operator==(const TaskConversationCorrelation &p_other) const {
	return task_request_identifier == p_other.task_request_identifier &&
			task_instance_identifier == p_other.task_instance_identifier &&
			task_scope_identifier == p_other.task_scope_identifier &&
			task_node_identifier == p_other.task_node_identifier &&
			conversation_identifier == p_other.conversation_identifier &&
			conversation_instance_identifier == p_other.conversation_instance_identifier &&
			task_integration_handle == p_other.task_integration_handle &&
			task_request_created_revision == p_other.task_request_created_revision &&
			conversation_definition_fingerprint == p_other.conversation_definition_fingerprint;
}

Status TaskConversationStartContext::validate() const {
	Status status = task_request_identifier.empty() ? ok_status() : validate_identifier(task_request_identifier);
	if (!status.ok()) return status;
	status = conversation_instance_identifier.empty() ? ok_status() : validate_identifier(conversation_instance_identifier);
	if (!status.ok()) return status;
	status = task_integration_handle.empty() ? ok_status() : validate_identifier(task_integration_handle);
	if (!status.ok()) return status;
	status = entry_label.empty() ? ok_status() : validate_local_identifier(entry_label);
	if (!status.ok()) return status;
	if (effect_parameters.size() > MAX_NODE_PARAMETERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, effect_parameters.size());
	}
	for (const Value &parameter : effect_parameters) {
		status = parameter.validate();
		if (!status.ok()) return status;
	}
	if (encoded_values_size(effect_parameters) > MAX_PROVIDER_PAYLOAD_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, encoded_values_size(effect_parameters));
	}
	status = conversation_facts.validate();
	if (!status.ok()) return status;
	return task_facts.validate();
}

void TaskConversationResult::clear() {
	*this = TaskConversationResult{};
}

Status TaskConversationBridge::bind(
		TaskGraphInstance &p_task,
		ConversationInstance &p_conversation,
		const LevelTaskCatalog *p_catalog) {
	if (task_ == &p_task && conversation_ == &p_conversation) {
		catalog_ = p_catalog;
		return ok_status();
	}
	if (started_) return bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID);
	task_ = &p_task;
	conversation_ = &p_conversation;
	catalog_ = p_catalog;
	correlation_ = TaskConversationCorrelation{};
	task_request_ = TaskExternalRequest{};
	replay_records_.clear();
	return ok_status();
}

void TaskConversationBridge::unbind() {
	task_ = nullptr;
	conversation_ = nullptr;
	catalog_ = nullptr;
	started_ = false;
	correlation_ = TaskConversationCorrelation{};
	task_request_ = TaskExternalRequest{};
	replay_records_.clear();
}

const TaskExternalRequest *TaskConversationBridge::task_request() const {
	return started_ ? &task_request_ : nullptr;
}

const ConversationFrame *TaskConversationBridge::frame() const {
	return started_ && conversation_ != nullptr ? &conversation_->frame() : nullptr;
}

Status TaskConversationBridge::validate_bound() const {
	if (!bound()) return bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID);
	if (!task_->valid()) return bridge_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	return ok_status();
}

Status TaskConversationBridge::resolve_request(
		const TaskConversationStartContext &p_context,
		const TaskExternalRequest *p_explicit_request,
		const TaskExternalRequest *&r_request) const {
	r_request = nullptr;
	Status status = validate_bound();
	if (!status.ok()) return status;
	if (p_explicit_request != nullptr) {
		status = p_explicit_request->validate();
		if (!status.ok()) return status;
		if (!p_context.task_request_identifier.empty() &&
				p_context.task_request_identifier != p_explicit_request->request_identifier) {
			return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_context.task_request_identifier));
		}
		if (started_ && p_explicit_request->request_identifier == correlation_.task_request_identifier) {
			return same_task_request_identity(*p_explicit_request, task_request_) ?
					(r_request = p_explicit_request, ok_status()) :
					bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_explicit_request->request_identifier));
		}
		const TaskExternalRequest *pending = task_->find_pending_request(p_explicit_request->request_identifier);
		if (pending == nullptr) return bridge_not_found(hash_string(p_explicit_request->request_identifier));
		if (!same_task_request_identity(*pending, *p_explicit_request)) {
			return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_explicit_request->request_identifier));
		}
		r_request = pending;
		return ok_status();
	}

	std::string requested_identifier = p_context.task_request_identifier;
	if (requested_identifier.empty() && started_) requested_identifier = correlation_.task_request_identifier;
	if (!requested_identifier.empty()) {
		const TaskExternalRequest *pending = task_->find_pending_request(requested_identifier);
		if (pending != nullptr) {
			r_request = pending;
			return ok_status();
		}
		if (started_ && requested_identifier == task_request_.request_identifier) {
			r_request = &task_request_;
			return ok_status();
		}
		return bridge_not_found(hash_string(requested_identifier));
	}

	const TaskExternalRequest *candidate = nullptr;
	std::size_t conversation_count = 0;
	for (const TaskExternalRequest &request : task_->pending_requests()) {
		if (request.kind != TaskExternalRequestKind::CONVERSATION) continue;
		candidate = &request;
		++conversation_count;
	}
	if (conversation_count == 0) return bridge_not_found();
	if (conversation_count != 1) return bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, conversation_count);
	r_request = candidate;
	return ok_status();
}

const TaskNodeDefinition *TaskConversationBridge::task_node_definition() const {
	if (!started_ || task_ == nullptr) return nullptr;
	const CanonicalTaskNode *node = task_->graph().find_node(correlation_.task_node_identifier);
	return node == nullptr ? nullptr : &node->definition;
}

const TaskExternalRequest *TaskConversationBridge::current_task_request() const {
	if (!started_ || task_ == nullptr) return nullptr;
	const TaskExternalRequest *pending = task_->find_pending_request(correlation_.task_request_identifier);
	if (pending != nullptr) return pending;
	return task_->find_resolved_request(correlation_.task_request_identifier) == nullptr ? nullptr : &task_request_;
}

Status TaskConversationBridge::validate_mapping(
		const TaskExternalRequest &p_request,
		const ConversationDefinition &p_definition,
		const TaskConversationStartContext &p_context,
		std::string &r_entry_label,
		std::string &r_instance_identifier,
		std::string &r_integration_handle) const {
	Status status = p_request.validate();
	if (!status.ok()) return status;
	if (p_request.kind != TaskExternalRequestKind::CONVERSATION) {
		return bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, static_cast<std::uint8_t>(p_request.kind));
	}
	if (p_request.instance_identifier != task_->instance_identifier() || p_request.scope_key != task_->scope_key()) {
		return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_request.request_identifier));
	}
	const CanonicalTaskNode *node = task_->graph().find_node(p_request.node_identifier);
	if (node == nullptr || node->kind() != TaskNodeKind::CONVERSATION) {
		return bridge_reference(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, hash_string(p_request.node_identifier));
	}
	const TaskNodeDefinition &node_definition = node->definition;
	if (node_definition.conversation_identifier.empty() ||
			p_request.conversation_identifier != node_definition.conversation_identifier ||
			p_definition.identifier != node_definition.conversation_identifier) {
		return bridge_reference(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, hash_string(p_request.conversation_identifier));
	}
	status = p_definition.validate();
	if (!status.ok()) return status;
	const std::uint64_t definition_fingerprint = p_definition.fingerprint();
	if (definition_fingerprint == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	if (!p_context.entry_label.empty() && p_context.entry_label != node_definition.conversation_entry_label) {
		return bridge_reference(DiagnosticId::CONVERSATION_ENTRY_INVALID, hash_string(p_context.entry_label));
	}
	r_entry_label = p_context.entry_label.empty() ? node_definition.conversation_entry_label : p_context.entry_label;
	status = validate_local_identifier(r_entry_label);
	if (!status.ok()) return status;
	bool entry_found = false;
	for (const ConversationStepDefinition &step : p_definition.steps) {
		if (step.identifier == r_entry_label) {
			entry_found = true;
			break;
		}
	}
	if (!entry_found) return bridge_reference(DiagnosticId::CONVERSATION_ENTRY_INVALID, hash_string(r_entry_label));
	if (node_definition.accepted_outcomes.empty()) {
		return bridge_invalid(DiagnosticId::GRAPH_OUTCOME_INVALID);
	}
	for (const std::string &outcome : node_definition.accepted_outcomes) {
		if (!contains_identifier(p_definition.terminal_outcomes, outcome)) {
			return bridge_reference(DiagnosticId::CONVERSATION_OUTCOME_INVALID, hash_string(outcome));
		}
	}
	if (!p_context.effect_parameters.empty() && p_context.effect_parameters != p_request.parameters) {
		return bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_request.request_identifier));
	}
	const bool replaying_current_request = started_ &&
			p_request.request_identifier == correlation_.task_request_identifier;
	r_instance_identifier = p_context.conversation_instance_identifier.empty() ?
			(replaying_current_request ? correlation_.conversation_instance_identifier : p_request.request_identifier) :
			p_context.conversation_instance_identifier;
	r_integration_handle = p_context.task_integration_handle.empty() ?
			(replaying_current_request ? correlation_.task_integration_handle : p_request.request_identifier) :
			p_context.task_integration_handle;
	status = validate_identifier(r_instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(r_integration_handle);
	if (!status.ok()) return status;
	(void)definition_fingerprint;
	return ok_status();
}

Status TaskConversationBridge::start(
		const ConversationDefinition &p_definition,
		const TaskConversationStartContext &p_context,
		TaskConversationResult *r_result) {
	if (r_result != nullptr) r_result->clear();
	const Status context_status = p_context.validate();
	if (!context_status.ok()) return fail(r_result, TaskConversationOperation::START, context_status);
	const TaskExternalRequest *request = nullptr;
	Status status = resolve_request(p_context, nullptr, request);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
	if (catalog_ != nullptr) {
		if (!catalog_->sealed()) return fail(r_result, TaskConversationOperation::START,
				make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::NONE));
		const ConversationDefinition *catalog_definition = catalog_->find_conversation(request->conversation_identifier);
		if (catalog_definition == nullptr || catalog_definition->fingerprint() != p_definition.fingerprint()) {
			return fail(r_result, TaskConversationOperation::START,
					bridge_reference(DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(request->conversation_identifier)));
		}
	}
	return start_resolved(*request, p_definition, p_context, r_result);
}

Status TaskConversationBridge::start(
		const LevelTaskCatalog &p_catalog,
		const TaskConversationStartContext &p_context,
		TaskConversationResult *r_result) {
	if (r_result != nullptr) r_result->clear();
	Status status = p_context.validate();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
	if (!p_catalog.sealed()) {
		return fail(r_result, TaskConversationOperation::START, make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::NONE));
	}
	const TaskExternalRequest *request = nullptr;
	status = resolve_request(p_context, nullptr, request);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
	const ConversationDefinition *definition = p_catalog.find_conversation(request->conversation_identifier);
	if (definition == nullptr) {
		return fail(r_result, TaskConversationOperation::START,
				bridge_reference(DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(request->conversation_identifier)));
	}
	const LevelTaskCatalog *previous_catalog = catalog_;
	catalog_ = &p_catalog;
	status = start_resolved(*request, *definition, p_context, r_result);
	if (!status.ok()) catalog_ = previous_catalog;
	return status;
}

Status TaskConversationBridge::start_from_task_request(
		const TaskExternalRequest &p_request,
		const ConversationDefinition &p_definition,
		const TaskConversationStartContext &p_context,
		TaskConversationResult *r_result) {
	if (r_result != nullptr) r_result->clear();
	Status status = p_context.validate();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
	const TaskExternalRequest *resolved_request = nullptr;
	status = resolve_request(p_context, &p_request, resolved_request);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
	return start_resolved(*resolved_request, p_definition, p_context, r_result);
}

Status TaskConversationBridge::start_resolved(
		const TaskExternalRequest &p_request,
		const ConversationDefinition &p_definition,
		const TaskConversationStartContext &p_context,
		TaskConversationResult *r_result) {
	Status status = validate_bound();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
	std::string entry_label;
	std::string instance_identifier;
	std::string integration_handle;
	status = validate_mapping(p_request, p_definition, p_context, entry_label, instance_identifier, integration_handle);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);

	if (started_) {
		if (p_request.request_identifier != correlation_.task_request_identifier ||
				!same_task_request_identity(p_request, task_request_) ||
				!conversation_->started() || conversation_->instance_identifier() != instance_identifier ||
				conversation_->scope_identifier() != task_->scope_key() ||
				conversation_->task_integration_handle() != integration_handle ||
				conversation_->definition().identifier != p_definition.identifier ||
				conversation_->definition_fingerprint() != p_definition.fingerprint()) {
			return fail(r_result, TaskConversationOperation::START,
					bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_request.request_identifier)));
		}
		return finish(r_result, TaskConversationOperation::START, false, true);
	}
	const TaskExternalRequest *pending = task_->find_pending_request(p_request.request_identifier);
	if (pending == nullptr || !same_task_request_identity(*pending, p_request)) {
		return fail(r_result, TaskConversationOperation::START, bridge_not_found(hash_string(p_request.request_identifier)));
	}
	if (conversation_->started()) {
		return fail(r_result, TaskConversationOperation::START,
				bridge_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	}

	ConversationInstance candidate_conversation = *conversation_;
	status = candidate_conversation.start(
			p_definition,
			instance_identifier,
			task_->scope_key(),
			p_context.conversation_facts,
			entry_label,
			integration_handle);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);

	TaskGraphInstance candidate_task = *task_;
	TaskAdvanceResult task_result;
	bool has_task_result = false;
	if (has_task_fact_payload(p_context)) {
		TaskFactSnapshot normalized_task_facts;
		status = normalize_task_facts(p_context.task_facts, normalized_task_facts);
		if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
		status = candidate_task.advance(std::vector<TaskEvent>{}, normalized_task_facts, &task_result);
		if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);
		if (candidate_task.find_pending_request(p_request.request_identifier) == nullptr) {
			return fail(r_result, TaskConversationOperation::START,
					bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(p_request.request_identifier)));
		}
		has_task_result = true;
	}

	TaskConversationCorrelation candidate_correlation;
	// Keep a value copy before committing a candidate task. `p_request` commonly
	// points into task_->pending_requests(), and move-assigning candidate_task
	// invalidates that reference.
	const TaskExternalRequest request_copy = p_request;
	candidate_correlation.task_request_identifier = request_copy.request_identifier;
	candidate_correlation.task_instance_identifier = task_->instance_identifier();
	candidate_correlation.task_scope_identifier = task_->scope_key();
	candidate_correlation.task_node_identifier = request_copy.node_identifier;
	candidate_correlation.conversation_identifier = p_definition.identifier;
	candidate_correlation.conversation_instance_identifier = instance_identifier;
	candidate_correlation.task_integration_handle = integration_handle;
	candidate_correlation.task_request_created_revision = p_request.created_revision;
	candidate_correlation.conversation_definition_fingerprint = candidate_conversation.definition_fingerprint();
	status = candidate_correlation.validate();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::START, status);

	*conversation_ = std::move(candidate_conversation);
	if (has_task_result) *task_ = std::move(candidate_task);
	correlation_ = std::move(candidate_correlation);
	task_request_ = request_copy;
	started_ = true;
	if (r_result != nullptr) {
		r_result->clear();
		r_result->operation = TaskConversationOperation::START;
		r_result->status = ok_status();
		r_result->changed = true;
		r_result->correlation = correlation_;
		r_result->frame = conversation_->frame();
		r_result->has_frame = true;
		if (has_task_result) {
			r_result->task_result = task_result;
			r_result->has_task_result = true;
		}
	}
	return ok_status();
}

Status TaskConversationBridge::validate_started() const {
	Status status = validate_bound();
	if (!status.ok()) return status;
	if (!started_ || !conversation_->started()) return bridge_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	status = correlation_.validate();
	if (!status.ok()) return status;
	status = task_request_.validate();
	if (!status.ok()) return status;
	if (task_request_.request_identifier != correlation_.task_request_identifier ||
			task_request_.instance_identifier != correlation_.task_instance_identifier ||
			task_request_.scope_key != correlation_.task_scope_identifier ||
			task_request_.node_identifier != correlation_.task_node_identifier ||
			task_request_.conversation_identifier != correlation_.conversation_identifier) {
		return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(correlation_.task_request_identifier));
	}
	if (conversation_->instance_identifier() != correlation_.conversation_instance_identifier ||
			conversation_->scope_identifier() != correlation_.task_scope_identifier ||
			conversation_->task_integration_handle() != correlation_.task_integration_handle ||
			conversation_->definition().identifier != correlation_.conversation_identifier ||
			conversation_->definition_fingerprint() != correlation_.conversation_definition_fingerprint) {
		return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(correlation_.conversation_identifier));
	}
	return ok_status();
}

Status TaskConversationBridge::ensure_task_request_still_pending(const TaskGraphInstance &p_task) const {
	const TaskExternalRequest *pending = p_task.find_pending_request(correlation_.task_request_identifier);
	if (pending == nullptr) return bridge_not_found(hash_string(correlation_.task_request_identifier));
	if (!same_task_request_identity(*pending, task_request_) || pending->kind != TaskExternalRequestKind::CONVERSATION) {
		return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(correlation_.task_request_identifier));
	}
	return ok_status();
}

Status TaskConversationBridge::validate_current_request(bool p_allow_resolved) const {
	Status status = validate_started();
	if (!status.ok()) return status;
	const TaskExternalRequest *pending = task_->find_pending_request(correlation_.task_request_identifier);
	if (pending != nullptr) {
		if (pending->kind != TaskExternalRequestKind::CONVERSATION || !same_task_request_identity(*pending, task_request_)) {
			return bridge_reference(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(correlation_.task_request_identifier));
		}
		return ok_status();
	}
	if (p_allow_resolved) {
		const TaskRequestResolutionRecord *resolved = task_->find_resolved_request(correlation_.task_request_identifier);
		if (resolved != nullptr && resolved->kind == TaskExternalRequestKind::CONVERSATION) return ok_status();
	}
	return bridge_not_found(hash_string(correlation_.task_request_identifier));
}

Status TaskConversationBridge::finish(
		TaskConversationResult *r_result,
		TaskConversationOperation p_operation,
		bool p_changed,
		bool p_idempotent,
		const TaskAdvanceResult *p_task_result,
		const std::string &p_choice_identifier,
		const std::string &p_outcome_identifier) const {
	if (r_result != nullptr) {
		r_result->clear();
		r_result->status = ok_status();
		r_result->operation = p_operation;
		r_result->changed = p_changed;
		r_result->idempotent = p_idempotent;
		r_result->correlation = correlation_;
		r_result->choice_identifier = p_choice_identifier;
		r_result->outcome_identifier = p_outcome_identifier;
		if (started_ && conversation_ != nullptr && conversation_->started()) {
			r_result->frame = conversation_->frame();
			r_result->has_frame = true;
		}
		if (p_task_result != nullptr) {
			r_result->task_result = *p_task_result;
			r_result->has_task_result = true;
		}
	}
	return ok_status();
}

Status TaskConversationBridge::fail(
		TaskConversationResult *r_result,
		TaskConversationOperation p_operation,
		const Status &p_status) const {
	if (r_result != nullptr) {
		r_result->clear();
		r_result->status = p_status;
		r_result->operation = p_operation;
		r_result->correlation = correlation_;
		if (started_ && conversation_ != nullptr && conversation_->started()) {
			r_result->frame = conversation_->frame();
			r_result->has_frame = true;
		}
	}
	return p_status;
}

Status TaskConversationBridge::remember_replay(
		TaskConversationOperation p_operation,
		std::uint64_t p_frame_revision,
		const std::string &p_identifier,
		std::uint64_t p_resulting_revision) {
	for (const ReplayRecord &record : replay_records_) {
		if (record.operation == p_operation && record.frame_revision == p_frame_revision && record.identifier == p_identifier) {
			return ok_status();
		}
	}
	if (replay_records_.size() >= MAX_TASK_CONVERSATION_REPLAY_RECORDS) replay_records_.erase(replay_records_.begin());
	replay_records_.push_back({ p_operation, p_frame_revision, p_identifier, p_resulting_revision });
	return ok_status();
}

const TaskConversationBridge::ReplayRecord *TaskConversationBridge::find_replay(
		TaskConversationOperation p_operation,
		std::uint64_t p_frame_revision,
		const std::string &p_identifier) const {
	for (const ReplayRecord &record : replay_records_) {
		if (record.operation == p_operation && record.frame_revision == p_frame_revision && record.identifier == p_identifier) {
			return &record;
		}
	}
	return nullptr;
}

Status TaskConversationBridge::continue_line(
		std::uint64_t p_frame_revision,
		TaskConversationResult *r_result) {
	Status status = validate_started();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::CONTINUE_LINE, status);
	if (find_replay(TaskConversationOperation::CONTINUE_LINE, p_frame_revision, std::string()) != nullptr) {
		return finish(r_result, TaskConversationOperation::CONTINUE_LINE, false, true);
	}
	status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::CONTINUE_LINE, status);
	ConversationInstance candidate = *conversation_;
	status = candidate.continue_line(p_frame_revision);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::CONTINUE_LINE, status);
	const std::uint64_t resulting_revision = candidate.revision();
	*conversation_ = std::move(candidate);
	status = remember_replay(TaskConversationOperation::CONTINUE_LINE, p_frame_revision, std::string(), resulting_revision);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::CONTINUE_LINE, status);
	return finish(r_result, TaskConversationOperation::CONTINUE_LINE, true, false);
}

Status TaskConversationBridge::continue_line(TaskConversationResult *r_result) {
	if (!started_ || conversation_ == nullptr) return fail(r_result, TaskConversationOperation::CONTINUE_LINE,
			bridge_invalid(DiagnosticId::CONVERSATION_LINE_INVALID));
	return continue_line(conversation_->frame_revision(), r_result);
}

Status TaskConversationBridge::select_choice(
		const std::string &p_choice_identifier,
		std::uint64_t p_frame_revision,
		TaskConversationResult *r_result) {
	Status status = validate_started();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SELECT_CHOICE, status);
	const ReplayRecord *replay = find_replay(TaskConversationOperation::SELECT_CHOICE, p_frame_revision, p_choice_identifier);
	if (replay != nullptr) {
		return finish(r_result, TaskConversationOperation::SELECT_CHOICE, false, true, nullptr, p_choice_identifier);
	}
	status = validate_local_identifier(p_choice_identifier);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SELECT_CHOICE, status);
	status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SELECT_CHOICE, status);
	ConversationInstance candidate = *conversation_;
	status = candidate.select_choice(p_choice_identifier, p_frame_revision);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SELECT_CHOICE, status);
	const std::uint64_t resulting_revision = candidate.revision();
	*conversation_ = std::move(candidate);
	status = remember_replay(TaskConversationOperation::SELECT_CHOICE, p_frame_revision, p_choice_identifier, resulting_revision);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SELECT_CHOICE, status);
	return finish(r_result, TaskConversationOperation::SELECT_CHOICE, true, false, nullptr, p_choice_identifier);
}

Status TaskConversationBridge::select_choice(
		const std::string &p_choice_identifier,
		TaskConversationResult *r_result) {
	if (!started_ || conversation_ == nullptr) return fail(r_result, TaskConversationOperation::SELECT_CHOICE,
			bridge_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID));
	return select_choice(p_choice_identifier, conversation_->frame_revision(), r_result);
}

Status TaskConversationBridge::normalize_task_facts(
		const TaskFactSnapshot &p_facts,
		TaskFactSnapshot &r_normalized) const {
	Status status = p_facts.validate(task_->limits().max_facts_per_snapshot);
	if (!status.ok()) return status;
	r_normalized = p_facts;
	if (r_normalized.scope_key().empty()) return r_normalized.set_scope_key(task_->scope_key());
	if (r_normalized.scope_key() != task_->scope_key()) {
		return bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, hash_string(r_normalized.scope_key()));
	}
	return ok_status();
}

Status TaskConversationBridge::conversation_to_task_facts(
		const ConversationFactSnapshot &p_conversation_facts,
		TaskFactSnapshot &r_task_facts) const {
	ConversationFactSnapshot canonical = p_conversation_facts;
	Status status = canonical.validate_and_canonicalize();
	if (!status.ok()) return status;
	r_task_facts = TaskFactSnapshot(task_->scope_key());
	for (const ConversationFact &conversation_fact : canonical.facts) {
		TaskFact task_fact;
		task_fact.provider_identifier = conversation_fact.provider_identifier;
		task_fact.fact_identifier = conversation_fact.fact_identifier;
		task_fact.value = conversation_fact.value;
		status = r_task_facts.add(task_fact);
		if (!status.ok()) return status;
	}
	return ok_status();
}

Status TaskConversationBridge::set_facts(
		const ConversationFactSnapshot &p_facts,
		TaskConversationResult *r_result) {
	Status status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SET_FACTS, status);
	ConversationFactSnapshot canonical = p_facts;
	status = canonical.validate_and_canonicalize();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SET_FACTS, status);
	const bool same_facts = conversation_->facts() == canonical;
	if (same_facts) return finish(r_result, TaskConversationOperation::SET_FACTS, false, true);
	ConversationInstance candidate = *conversation_;
	status = candidate.set_facts(canonical);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::SET_FACTS, status);
	*conversation_ = std::move(candidate);
	return finish(r_result, TaskConversationOperation::SET_FACTS, true, false);
}

Status TaskConversationBridge::writeback_facts(
		const ConversationFactSnapshot &p_conversation_facts,
		const TaskFactSnapshot &p_task_facts,
		std::uint64_t p_tick,
		TaskConversationResult *r_result) {
	Status status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);
	ConversationFactSnapshot canonical_conversation_facts = p_conversation_facts;
	status = canonical_conversation_facts.validate_and_canonicalize();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);
	TaskFactSnapshot normalized_task_facts;
	status = normalize_task_facts(p_task_facts, normalized_task_facts);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);

	ConversationInstance candidate_conversation = *conversation_;
	TaskGraphInstance candidate_task = *task_;
	status = candidate_conversation.set_facts(canonical_conversation_facts);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);
	TaskAdvanceResult task_result;
	if (p_tick == NO_TICK) {
		status = candidate_task.advance(std::vector<TaskEvent>{}, normalized_task_facts, &task_result);
	} else {
		status = candidate_task.advance(std::vector<TaskEvent>{}, normalized_task_facts, p_tick, &task_result);
	}
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);
	status = ensure_task_request_still_pending(candidate_task);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);
	const bool conversation_changed = conversation_->facts() != canonical_conversation_facts;
	const bool changed = conversation_changed || task_result.changed;
	*conversation_ = std::move(candidate_conversation);
	*task_ = std::move(candidate_task);
	return finish(r_result, TaskConversationOperation::WRITEBACK_FACTS, changed, !changed, &task_result);
}

Status TaskConversationBridge::writeback_facts(
		const ConversationFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskConversationResult *r_result) {
	if (!bound()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS,
			bridge_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID));
	TaskFactSnapshot task_facts;
	Status status = conversation_to_task_facts(p_facts, task_facts);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_FACTS, status);
	return writeback_facts(p_facts, task_facts, p_tick, r_result);
}

Status TaskConversationBridge::acknowledge_action(
		const std::string &p_request_identifier,
		std::uint64_t p_frame_revision,
		bool p_success,
		const Value &p_response,
		TaskConversationResult *r_result) {
	Status status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::ACKNOWLEDGE_ACTION, status);
	ConversationInstance candidate = *conversation_;
	status = candidate.acknowledge_action(p_request_identifier, p_frame_revision, p_success, p_response);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::ACKNOWLEDGE_ACTION, status);
	const bool changed = conversation_frame_changed(*conversation_, candidate);
	*conversation_ = std::move(candidate);
	return finish(r_result, TaskConversationOperation::ACKNOWLEDGE_ACTION, changed, !changed, nullptr, std::string(),
			conversation_->terminal() ? conversation_->outcome_identifier() : std::string());
}

Status TaskConversationBridge::acknowledge_action(
		const std::string &p_request_identifier,
		bool p_success,
		const Value &p_response,
		TaskConversationResult *r_result) {
	return acknowledge_action(p_request_identifier, 0, p_success, p_response, r_result);
}

Status TaskConversationBridge::reject_action(
		const std::string &p_request_identifier,
		std::uint64_t p_frame_revision,
		TaskConversationResult *r_result) {
	Status status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::REJECT_ACTION, status);
	ConversationInstance candidate = *conversation_;
	status = candidate.reject_action(p_request_identifier, p_frame_revision);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::REJECT_ACTION, status);
	const bool changed = conversation_frame_changed(*conversation_, candidate);
	*conversation_ = std::move(candidate);
	return finish(r_result, TaskConversationOperation::REJECT_ACTION, changed, !changed, nullptr, std::string(),
			conversation_->terminal() ? conversation_->outcome_identifier() : std::string());
}

Status TaskConversationBridge::timeout_action(
		const std::string &p_request_identifier,
		std::uint64_t p_frame_revision,
		TaskConversationResult *r_result) {
	Status status = validate_current_request(false);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::TIMEOUT_ACTION, status);
	ConversationInstance candidate = *conversation_;
	status = candidate.timeout_action(p_request_identifier, p_frame_revision);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::TIMEOUT_ACTION, status);
	const bool changed = conversation_frame_changed(*conversation_, candidate);
	*conversation_ = std::move(candidate);
	return finish(r_result, TaskConversationOperation::TIMEOUT_ACTION, changed, !changed, nullptr, std::string(),
			conversation_->terminal() ? conversation_->outcome_identifier() : std::string());
}

Status TaskConversationBridge::writeback_outcome(
		const std::string &p_outcome_identifier,
		const Value &p_response,
		std::uint64_t p_tick,
		std::uint64_t p_expected_task_revision,
		TaskConversationResult *r_result) {
	Status status = validate_started();
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME, status);
	const std::string outcome = p_outcome_identifier.empty() ? conversation_->outcome_identifier() : p_outcome_identifier;
	status = validate_local_identifier(outcome);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME, status);
	if (!conversation_->terminal() || conversation_->outcome_identifier() != outcome) {
		return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME,
				bridge_invalid(DiagnosticId::CONVERSATION_OUTCOME_INVALID, hash_string(outcome)));
	}
	const TaskNodeDefinition *node = task_node_definition();
	if (node == nullptr || node->kind != TaskNodeKind::CONVERSATION || !contains_identifier(node->accepted_outcomes, outcome)) {
		return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME,
				bridge_reference(DiagnosticId::GRAPH_OUTCOME_INVALID, hash_string(outcome)));
	}

	const TaskRequestResolutionRecord *resolved = task_->find_resolved_request(correlation_.task_request_identifier);
	if (resolved != nullptr) {
		if (resolved->kind != TaskExternalRequestKind::CONVERSATION ||
				resolved->resolution != TaskRequestResolution::ACKNOWLEDGED ||
				resolved->outcome_identifier != outcome) {
			return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME,
					bridge_invalid(DiagnosticId::GRAPH_OUTCOME_INVALID, hash_string(outcome)));
		}
		TaskAdvanceResult prior;
		prior.status = ok_status();
		prior.idempotent = true;
		prior.changed = false;
		prior.revision = task_->revision();
		prior.graph_status = task_->status();
		prior.has_resolution = true;
		prior.resolution = *resolved;
		return finish(r_result, TaskConversationOperation::WRITEBACK_OUTCOME, false, true, &prior, std::string(), outcome);
	}
	status = ensure_task_request_still_pending(*task_);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME, status);
	const TaskExternalRequest *request = task_->find_pending_request(correlation_.task_request_identifier);
	if (request == nullptr || request->kind != TaskExternalRequestKind::CONVERSATION) {
		return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME,
				bridge_not_found(hash_string(correlation_.task_request_identifier)));
	}
	if (p_tick != NO_TICK && request->has_timeout && p_tick >= request->timeout_tick) {
		return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME,
				bridge_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, p_tick));
	}

	TaskGraphInstance candidate_task = *task_;
	TaskAdvanceResult task_result;
	status = candidate_task.acknowledge_request(
			correlation_.task_request_identifier,
			outcome,
			p_response,
			p_tick,
			p_expected_task_revision,
			&task_result);
	if (!status.ok()) return fail(r_result, TaskConversationOperation::WRITEBACK_OUTCOME, status);
	*task_ = std::move(candidate_task);
	return finish(r_result, TaskConversationOperation::WRITEBACK_OUTCOME, task_result.changed, task_result.idempotent,
			&task_result, std::string(), outcome);
}

Status TaskConversationBridge::start_task_conversation(
		TaskGraphInstance &p_task,
		ConversationInstance &p_conversation,
		const ConversationDefinition &p_definition,
		const TaskConversationStartContext &p_context,
		TaskConversationResult *r_result) {
	TaskConversationBridge bridge(p_task, p_conversation);
	return bridge.start(p_definition, p_context, r_result);
}

} // namespace lts
