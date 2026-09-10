#include "core/lts_definitions.h"

#include "core/lts_hash.h"

#include <algorithm>
#include <cstddef>
#include <tuple>
#include <utility>

namespace lts {

namespace {

Status validate_schema(std::uint16_t p_version, std::uint16_t p_supported) {
	if (!schema_version_supported(p_version, p_supported)) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED, p_version);
	}
	return ok_status();
}

Status validate_optional_local(const std::string &p_value) {
	return p_value.empty() ? ok_status() : validate_local_identifier(p_value);
}

Status validate_optional_identifier(const std::string &p_value) {
	return p_value.empty() ? ok_status() : validate_identifier(p_value);
}

Status validate_text(const std::string &p_value, std::size_t p_limit, DiagnosticId p_diagnostic = DiagnosticId::BYTE_LIMIT_EXCEEDED) {
	if (p_value.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, p_diagnostic, p_value.size());
	}
	return ok_status();
}

template <typename T, typename Validator, typename Less>
Status canonicalize_records(std::vector<T> &r_values, std::size_t p_limit, Validator p_validator, Less p_less, DiagnosticId p_limit_diagnostic) {
	if (r_values.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, p_limit_diagnostic, r_values.size());
	}
	for (T &value : r_values) {
		const Status status = p_validator(value);
		if (!status.ok()) return status;
	}
	std::sort(r_values.begin(), r_values.end(), p_less);
	for (std::size_t index = 1; index < r_values.size(); ++index) {
		if (!(p_less(r_values[index - 1], r_values[index])) && !(p_less(r_values[index], r_values[index - 1]))) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, index);
		}
	}
	return ok_status();
}

Status canonicalize_identifiers(std::vector<std::string> &r_values, std::size_t p_limit, bool p_namespaced, DiagnosticId p_limit_diagnostic = DiagnosticId::COUNT_LIMIT_EXCEEDED) {
	if (r_values.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, p_limit_diagnostic, r_values.size());
	}
	for (const std::string &value : r_values) {
		const Status status = p_namespaced ? validate_identifier(value) : validate_local_identifier(value);
		if (!status.ok()) return status;
	}
	std::sort(r_values.begin(), r_values.end(), identifier_less);
	for (std::size_t index = 1; index < r_values.size(); ++index) {
		if (r_values[index - 1] == r_values[index]) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, index);
		}
	}
	return ok_status();
}

Status canonicalize_predicates(std::vector<FactPredicate> &r_values, std::size_t p_limit, DiagnosticId p_limit_diagnostic) {
	return canonicalize_records(
			r_values,
			p_limit,
			[](FactPredicate &p_value) { return p_value.validate(); },
			[](const FactPredicate &p_a, const FactPredicate &p_b) { return p_a < p_b; },
			p_limit_diagnostic);
}

Status canonicalize_local_parameters(std::vector<LocalizedParameter> &r_values, std::size_t p_limit) {
	Status status = canonicalize_records(
			r_values,
			p_limit,
			[](LocalizedParameter &p_value) { return p_value.validate(); },
			[](const LocalizedParameter &p_a, const LocalizedParameter &p_b) { return p_a < p_b; },
			DiagnosticId::COUNT_LIMIT_EXCEEDED);
	if (!status.ok()) return status;
	for (std::size_t index = 1; index < r_values.size(); ++index) {
		if (r_values[index - 1].identifier == r_values[index].identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::CONVERSATION_LINE_INVALID, index);
		}
	}
	return ok_status();
}

void hash_value(Hasher &p_hasher, const Value &p_value) {
	p_hasher.write_u8(static_cast<std::uint8_t>(p_value.type));
	switch (p_value.type) {
		case ValueType::NONE:
			break;
		case ValueType::BOOLEAN:
			p_hasher.write_bool(std::get<bool>(p_value.payload));
			break;
		case ValueType::INTEGER:
			p_hasher.write_i64(std::get<std::int64_t>(p_value.payload));
			break;
		case ValueType::FIXED:
			p_hasher.write_i64(std::get<FixedPoint>(p_value.payload).raw);
			break;
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
			p_hasher.write_string(std::get<std::string>(p_value.payload));
			break;
		case ValueType::BYTES:
			p_hasher.write_bytes(std::get<ByteVector>(p_value.payload));
			break;
	}
}

void hash_predicate(Hasher &p_hasher, const FactPredicate &p_predicate) {
	p_hasher.write_string(p_predicate.provider_identifier);
	p_hasher.write_string(p_predicate.fact_identifier);
	p_hasher.write_u8(static_cast<std::uint8_t>(p_predicate.comparator));
	hash_value(p_hasher, p_predicate.expected);
}

void hash_port(Hasher &p_hasher, const TaskPortDefinition &p_port) {
	p_hasher.write_string(p_port.identifier);
	p_hasher.write_u8(static_cast<std::uint8_t>(p_port.direction));
	p_hasher.write_u8(static_cast<std::uint8_t>(p_port.value_type));
	p_hasher.write_bool(p_port.required);
}

void hash_node(Hasher &p_hasher, const TaskNodeDefinition &p_node) {
	p_hasher.write_string(p_node.identifier);
	p_hasher.write_u16(p_node.schema_version);
	p_hasher.write_u8(static_cast<std::uint8_t>(p_node.kind));
	p_hasher.write_u32(static_cast<std::uint32_t>(p_node.ports.size()));
	for (const TaskPortDefinition &port : p_node.ports) hash_port(p_hasher, port);
	p_hasher.write_string(p_node.provider_identifier);
	p_hasher.write_u32(p_node.objective_target);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_node.filters.size()));
	for (const FactPredicate &filter : p_node.filters) hash_predicate(p_hasher, filter);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_node.parameters.size()));
	for (const Value &parameter : p_node.parameters) hash_value(p_hasher, parameter);
	p_hasher.write_string(p_node.conversation_identifier);
	p_hasher.write_string(p_node.conversation_entry_label);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_node.accepted_outcomes.size()));
	for (const std::string &outcome : p_node.accepted_outcomes) p_hasher.write_string(outcome);
	p_hasher.write_string(p_node.subgraph_identifier);
	p_hasher.write_string(p_node.outcome_identifier);
}

void hash_edge(Hasher &p_hasher, const TaskEdgeDefinition &p_edge) {
	p_hasher.write_string(p_edge.identifier);
	p_hasher.write_u16(p_edge.schema_version);
	p_hasher.write_string(p_edge.from_node_identifier);
	p_hasher.write_string(p_edge.from_port_identifier);
	p_hasher.write_string(p_edge.to_node_identifier);
	p_hasher.write_string(p_edge.to_port_identifier);
}

void hash_anchor(Hasher &p_hasher, const LevelAnchorDefinition &p_anchor) {
	p_hasher.write_string(p_anchor.identifier);
	p_hasher.write_u8(static_cast<std::uint8_t>(p_anchor.kind));
	p_hasher.write_bool(p_anchor.required);
	p_hasher.write_string(p_anchor.binding_label);
}

void hash_exit(Hasher &p_hasher, const LevelExitDefinition &p_exit) {
	p_hasher.write_string(p_exit.identifier);
	p_hasher.write_string(p_exit.target_level_identifier);
	p_hasher.write_string(p_exit.target_anchor_identifier);
	p_hasher.write_string(p_exit.outcome_identifier);
}

void hash_choice(Hasher &p_hasher, const ConversationChoiceDefinition &p_choice) {
	p_hasher.write_string(p_choice.identifier);
	p_hasher.write_string(p_choice.label_key);
	p_hasher.write_string(p_choice.target_step_identifier);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_choice.conditions.size()));
	for (const FactPredicate &condition : p_choice.conditions) hash_predicate(p_hasher, condition);
}

void hash_step(Hasher &p_hasher, const ConversationStepDefinition &p_step) {
	p_hasher.write_string(p_step.identifier);
	p_hasher.write_u8(static_cast<std::uint8_t>(p_step.kind));
	p_hasher.write_string(p_step.speaker_identifier);
	p_hasher.write_string(p_step.line_key);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_step.parameters.size()));
	for (const LocalizedParameter &parameter : p_step.parameters) {
		p_hasher.write_string(parameter.identifier);
		hash_value(p_hasher, parameter.value);
	}
	p_hasher.write_string(p_step.next_step_identifier);
	p_hasher.write_string(p_step.provider_identifier);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_step.conditions.size()));
	for (const FactPredicate &condition : p_step.conditions) hash_predicate(p_hasher, condition);
	p_hasher.write_string(p_step.true_step_identifier);
	p_hasher.write_string(p_step.false_step_identifier);
	p_hasher.write_string(p_step.success_step_identifier);
	p_hasher.write_string(p_step.failure_step_identifier);
	p_hasher.write_u32(static_cast<std::uint32_t>(p_step.choices.size()));
	for (const ConversationChoiceDefinition &choice : p_step.choices) hash_choice(p_hasher, choice);
	p_hasher.write_string(p_step.target_step_identifier);
	p_hasher.write_string(p_step.outcome_identifier);
}

std::size_t value_encoded_size(const Value &p_value) {
	// This is the size budget used before a parameter collection is admitted.
	// It mirrors the closed value tags and fixed-width scalar encodings; the
	// canonical hash adds length prefixes to strings/bytes as well.
	std::size_t size = 1;
	switch (p_value.type) {
		case ValueType::NONE:
			return size;
		case ValueType::BOOLEAN:
			return size + 1;
		case ValueType::INTEGER:
		case ValueType::FIXED:
			return size + sizeof(std::int64_t);
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
			return size + sizeof(std::uint32_t) + std::get<std::string>(p_value.payload).size();
		case ValueType::BYTES:
			return size + sizeof(std::uint32_t) + std::get<ByteVector>(p_value.payload).size();
	}
	return size;
}

std::size_t localized_parameters_encoded_size(const std::vector<LocalizedParameter> &p_values) {
	std::size_t size = sizeof(std::uint32_t);
	for (const LocalizedParameter &parameter : p_values) {
		size += sizeof(std::uint32_t) + parameter.identifier.size() + value_encoded_size(parameter.value);
	}
	return size;
}

std::size_t values_encoded_size(const std::vector<Value> &p_values) {
	std::size_t size = sizeof(std::uint32_t);
	for (const Value &value : p_values) size += value_encoded_size(value);
	return size;
}

template <typename T>
std::uint64_t invalid_fingerprint() {
	return static_cast<std::uint64_t>(INVALID_CATALOG_FINGERPRINT);
}

Status canonicalize_node(TaskNodeDefinition &r_node) {
	Status status = validate_schema(r_node.schema_version, TASK_GRAPH_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = r_node.validate();
	if (!status.ok()) return status;
	std::sort(r_node.ports.begin(), r_node.ports.end());
	for (std::size_t index = 1; index < r_node.ports.size(); ++index) {
		if (r_node.ports[index - 1].identifier == r_node.ports[index].identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID, index);
		}
	}
	std::sort(r_node.filters.begin(), r_node.filters.end());
	for (std::size_t index = 1; index < r_node.filters.size(); ++index) {
		if (r_node.filters[index - 1] == r_node.filters[index]) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		}
	}
	std::sort(r_node.accepted_outcomes.begin(), r_node.accepted_outcomes.end(), local_identifier_less);
	for (std::size_t index = 1; index < r_node.accepted_outcomes.size(); ++index) {
		if (r_node.accepted_outcomes[index - 1] == r_node.accepted_outcomes[index]) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_OUTCOME_INVALID, index);
		}
	}
	return ok_status();
}

Status validate_choice(ConversationChoiceDefinition &r_choice) {
	Status status = validate_local_identifier(r_choice.identifier);
	if (!status.ok()) return status;
	status = validate_localization_key(r_choice.label_key);
	if (!status.ok()) return status;
	status = validate_local_identifier(r_choice.target_step_identifier);
	if (!status.ok()) return status;
	return canonicalize_predicates(r_choice.conditions, MAX_CHOICE_CONDITIONS, DiagnosticId::CONVERSATION_CHOICE_LIMIT);
}

Status validate_step(ConversationStepDefinition &r_step) {
	Status status = validate_local_identifier(r_step.identifier);
	if (!status.ok()) return status;
	if (!is_known_conversation_step_kind(r_step.kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(r_step.kind));
	}

	status = validate_optional_identifier(r_step.speaker_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.line_key);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.next_step_identifier);
	if (!status.ok()) return status;
	status = validate_optional_identifier(r_step.provider_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.true_step_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.false_step_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.success_step_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.failure_step_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.target_step_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(r_step.outcome_identifier);
	if (!status.ok()) return status;

	// Keep the required LINE payload diagnostic below for an omitted key, while
	// still applying the strict localization grammar whenever an authored key
	// is present.  Other step kinds may legitimately leave line_key empty.
	if (!r_step.line_key.empty()) {
		status = validate_localization_key(r_step.line_key);
		if (!status.ok()) return status;
	}
	status = canonicalize_local_parameters(r_step.parameters, MAX_LINE_PARAMETERS);
	if (!status.ok()) return status;
	if (localized_parameters_encoded_size(r_step.parameters) > MAX_PARAMETERS_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED,
				localized_parameters_encoded_size(r_step.parameters));
	}
	status = canonicalize_predicates(r_step.conditions, MAX_CHOICE_CONDITIONS, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	if (!status.ok()) return status;
	if (r_step.choices.size() > MAX_CHOICES_PER_CONVERSATION_STEP) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_CHOICE_LIMIT, r_step.choices.size());
	}
	for (ConversationChoiceDefinition &choice : r_step.choices) {
		status = validate_choice(choice);
		if (!status.ok()) return status;
	}
	for (std::size_t index = 0; index < r_step.choices.size(); ++index) {
		for (std::size_t other = index + 1; other < r_step.choices.size(); ++other) {
			if (r_step.choices[index].identifier == r_step.choices[other].identifier) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::CONVERSATION_STEP_DUPLICATE, other);
			}
		}
	}

	switch (r_step.kind) {
		case ConversationStepKind::LINE:
			if (r_step.speaker_identifier.empty() || r_step.line_key.empty() || r_step.next_step_identifier.empty()) {
				return make_status(StatusCode::CONVERSATION_INVALID, DiagnosticId::CONVERSATION_LINE_INVALID);
			}
			break;
		case ConversationStepKind::CHOICE:
			if (r_step.choices.empty()) {
				return make_status(StatusCode::CONVERSATION_INVALID, DiagnosticId::CONVERSATION_CHOICE_INVALID);
			}
			break;
		case ConversationStepKind::CONDITION:
			if (r_step.provider_identifier.empty() || r_step.true_step_identifier.empty() || r_step.false_step_identifier.empty()) {
				return make_status(StatusCode::CONVERSATION_INVALID, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
			}
			break;
		case ConversationStepKind::EXTERNAL_ACTION:
			if (r_step.provider_identifier.empty() || r_step.success_step_identifier.empty() || r_step.failure_step_identifier.empty()) {
				return make_status(StatusCode::CONVERSATION_INVALID, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
			}
			break;
		case ConversationStepKind::JUMP:
			if (r_step.target_step_identifier.empty()) {
				return make_status(StatusCode::CONVERSATION_INVALID, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
			}
			break;
		case ConversationStepKind::OUTCOME:
			if (r_step.outcome_identifier.empty()) {
				return make_status(StatusCode::CONVERSATION_INVALID, DiagnosticId::CONVERSATION_OUTCOME_INVALID);
			}
			break;
	}
	return ok_status();
}

} // namespace

Status DefinitionCompatibility::validate() const {
	Status status = validate_schema(schema_version, RESOURCE_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_schema(protocol_version, PROTOCOL_VERSION);
	if (!status.ok()) return status;
	status = validate_schema(snapshot_schema_version, SNAPSHOT_SCHEMA_VERSION);
	if (!status.ok()) return status;
	return validate_schema(canonical_format_version, CANONICAL_FORMAT_VERSION);
}

bool DefinitionCompatibility::compatible_with(const DefinitionCompatibility &p_other) const {
	return schema_version_compatible(schema_version, p_other.schema_version) &&
			protocol_version == p_other.protocol_version && snapshot_schema_version == p_other.snapshot_schema_version &&
			canonical_format_version == p_other.canonical_format_version && fingerprint == p_other.fingerprint;
}

bool is_known_task_node_kind(TaskNodeKind p_kind) {
	switch (p_kind) {
		case TaskNodeKind::ENTRY:
		case TaskNodeKind::OBJECTIVE:
		case TaskNodeKind::CONDITION:
		case TaskNodeKind::ALL_GATE:
		case TaskNodeKind::ANY_GATE:
		case TaskNodeKind::EXTERNAL_ACTION:
		case TaskNodeKind::CONVERSATION:
		case TaskNodeKind::SUBGRAPH:
		case TaskNodeKind::REWARD_REQUEST:
		case TaskNodeKind::SUCCESS_TERMINAL:
		case TaskNodeKind::FAILURE_TERMINAL:
		case TaskNodeKind::CANCELLED_TERMINAL:
			return true;
	}
	return false;
}

bool is_known_task_port_direction(TaskPortDirection p_direction) {
	return p_direction == TaskPortDirection::INPUT || p_direction == TaskPortDirection::OUTPUT;
}

bool is_known_anchor_kind(SceneAnchorKind p_kind) {
	return p_kind == SceneAnchorKind::POINT || p_kind == SceneAnchorKind::TRANSFORM || p_kind == SceneAnchorKind::AREA;
}

bool is_known_conversation_step_kind(ConversationStepKind p_kind) {
	switch (p_kind) {
		case ConversationStepKind::LINE:
		case ConversationStepKind::CHOICE:
		case ConversationStepKind::CONDITION:
		case ConversationStepKind::EXTERNAL_ACTION:
		case ConversationStepKind::JUMP:
		case ConversationStepKind::OUTCOME:
			return true;
	}
	return false;
}

bool is_known_provider_kind(ProviderKind p_kind) {
	switch (p_kind) {
		case ProviderKind::FACT:
		case ProviderKind::EVENT:
		case ProviderKind::CONDITION:
		case ProviderKind::ACTION:
		case ProviderKind::REWARD:
		case ProviderKind::LEVEL_TRANSITION:
		case ProviderKind::CONVERSATION:
			return true;
	}
	return false;
}

Status TaskPortDefinition::validate() const {
	Status status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	if (!is_known_task_port_direction(direction) || !is_known_value_type(value_type)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::GRAPH_PORT_INVALID);
	}
	return ok_status();
}

bool TaskPortDefinition::operator<(const TaskPortDefinition &p_other) const {
	return std::tie(identifier, direction, value_type, required) <
			std::tie(p_other.identifier, p_other.direction, p_other.value_type, p_other.required);
}

Status TaskNodeDefinition::validate() const {
	Status status = validate_schema(schema_version, TASK_GRAPH_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	if (!is_known_task_node_kind(kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(kind));
	}
	if (ports.size() > MAX_PORTS_PER_TASK_NODE) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT, ports.size());
	}
	for (const TaskPortDefinition &port : ports) {
		status = port.validate();
		if (!status.ok()) return status;
	}
	for (std::size_t index = 0; index < ports.size(); ++index) {
		for (std::size_t other = index + 1; other < ports.size(); ++other) {
			if (ports[index].identifier == ports[other].identifier) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PORT_INVALID, other);
			}
		}
	}

	status = validate_optional_identifier(provider_identifier);
	if (!status.ok()) return status;
	status = validate_optional_identifier(conversation_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(conversation_entry_label);
	if (!status.ok()) return status;
	status = validate_optional_identifier(subgraph_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local(outcome_identifier);
	if (!status.ok()) return status;
	if (kind == TaskNodeKind::OBJECTIVE && (objective_target == 0 || objective_target > MAX_OBJECTIVE_TARGET)) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE, objective_target);
	}
	if (accepted_outcomes.size() > MAX_TERMINAL_OUTCOMES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_OUTCOME_INVALID, accepted_outcomes.size());
	}
	for (const std::string &outcome : accepted_outcomes) {
		status = validate_local_identifier(outcome);
		if (!status.ok()) return status;
	}
	for (std::size_t index = 0; index < accepted_outcomes.size(); ++index) {
		for (std::size_t other = index + 1; other < accepted_outcomes.size(); ++other) {
			if (accepted_outcomes[index] == accepted_outcomes[other]) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_OUTCOME_INVALID, other);
			}
		}
	}
	if (filters.size() > MAX_NODE_FILTERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, filters.size());
	}
	for (const FactPredicate &filter : filters) {
		status = filter.validate();
		if (!status.ok()) return status;
	}
	for (std::size_t index = 0; index < filters.size(); ++index) {
		for (std::size_t other = index + 1; other < filters.size(); ++other) {
			if (filters[index] == filters[other]) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_PAYLOAD_INVALID, other);
			}
		}
	}
	if (parameters.size() > MAX_NODE_PARAMETERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, parameters.size());
	}
	for (const Value &parameter : parameters) {
		status = parameter.validate();
		if (!status.ok()) return status;
	}
	if (values_encoded_size(parameters) > MAX_PARAMETERS_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, values_encoded_size(parameters));
	}

	switch (kind) {
		case TaskNodeKind::ENTRY:
		case TaskNodeKind::ALL_GATE:
		case TaskNodeKind::ANY_GATE:
			break;
		case TaskNodeKind::OBJECTIVE:
			if (provider_identifier.empty()) {
				return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
		case TaskNodeKind::CONDITION:
		case TaskNodeKind::EXTERNAL_ACTION:
		case TaskNodeKind::REWARD_REQUEST:
			if (provider_identifier.empty()) {
				return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
		case TaskNodeKind::CONVERSATION:
			if (conversation_identifier.empty() || conversation_entry_label.empty() || accepted_outcomes.empty()) {
				return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
		case TaskNodeKind::SUBGRAPH:
			if (subgraph_identifier.empty()) {
				return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
		case TaskNodeKind::SUCCESS_TERMINAL:
		case TaskNodeKind::FAILURE_TERMINAL:
		case TaskNodeKind::CANCELLED_TERMINAL:
			if (outcome_identifier.empty()) {
				return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_OUTCOME_INVALID);
			}
			break;
	}
	return ok_status();
}

std::uint64_t TaskNodeDefinition::fingerprint() const {
	TaskNodeDefinition copy = *this;
	if (!canonicalize_node(copy).ok()) return invalid_fingerprint<TaskNodeDefinition>();
	Hasher hasher;
	hasher.write_string("lts.task-node.v1");
	hash_node(hasher, copy);
	return hasher.digest();
}

bool TaskNodeDefinition::operator==(const TaskNodeDefinition &p_other) const {
	return identifier == p_other.identifier && schema_version == p_other.schema_version && kind == p_other.kind &&
			ports == p_other.ports && provider_identifier == p_other.provider_identifier &&
			objective_target == p_other.objective_target && filters == p_other.filters && parameters == p_other.parameters &&
			conversation_identifier == p_other.conversation_identifier && conversation_entry_label == p_other.conversation_entry_label &&
			accepted_outcomes == p_other.accepted_outcomes && subgraph_identifier == p_other.subgraph_identifier &&
			outcome_identifier == p_other.outcome_identifier;
}

bool TaskNodeDefinition::operator<(const TaskNodeDefinition &p_other) const {
	return std::tie(identifier, schema_version, kind, ports, provider_identifier, objective_target, filters, parameters,
			conversation_identifier, conversation_entry_label, accepted_outcomes, subgraph_identifier, outcome_identifier) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.kind, p_other.ports, p_other.provider_identifier,
					p_other.objective_target, p_other.filters, p_other.parameters, p_other.conversation_identifier,
					p_other.conversation_entry_label, p_other.accepted_outcomes, p_other.subgraph_identifier, p_other.outcome_identifier);
}

Status TaskEdgeDefinition::validate() const {
	Status status = validate_schema(schema_version, TASK_GRAPH_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(from_node_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(from_port_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(to_node_identifier);
	if (!status.ok()) return status;
	return validate_local_identifier(to_port_identifier);
}

std::uint64_t TaskEdgeDefinition::fingerprint() const {
	if (!validate().ok()) return invalid_fingerprint<TaskEdgeDefinition>();
	Hasher hasher;
	hasher.write_string("lts.task-edge.v1");
	hash_edge(hasher, *this);
	return hasher.digest();
}

bool TaskEdgeDefinition::operator==(const TaskEdgeDefinition &p_other) const {
	return identifier == p_other.identifier && schema_version == p_other.schema_version &&
			from_node_identifier == p_other.from_node_identifier && from_port_identifier == p_other.from_port_identifier &&
			to_node_identifier == p_other.to_node_identifier && to_port_identifier == p_other.to_port_identifier;
}

bool TaskEdgeDefinition::operator<(const TaskEdgeDefinition &p_other) const {
	return std::tie(identifier, schema_version, from_node_identifier, from_port_identifier, to_node_identifier, to_port_identifier) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.from_node_identifier, p_other.from_port_identifier,
					p_other.to_node_identifier, p_other.to_port_identifier);
}

Status TaskGraphDefinition::validate() const {
	TaskGraphDefinition copy = *this;
	return copy.validate_and_canonicalize();
}

Status TaskGraphDefinition::validate_and_canonicalize() {
	TaskGraphDefinition candidate = *this;
	const Status status = candidate.validate_and_canonicalize_in_place();
	if (!status.ok()) return status;
	*this = std::move(candidate);
	return ok_status();
}

Status TaskGraphDefinition::validate_and_canonicalize_in_place() {
	Status status = validate_schema(schema_version, TASK_GRAPH_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(entry_node_identifier);
	if (!status.ok()) return status;
	if (terminal_outcomes.empty() || terminal_outcomes.size() > MAX_TERMINAL_OUTCOMES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_OUTCOME_INVALID, terminal_outcomes.size());
	}
	status = canonicalize_identifiers(terminal_outcomes, MAX_TERMINAL_OUTCOMES, false, DiagnosticId::GRAPH_OUTCOME_INVALID);
	if (!status.ok()) return status;
	if (nodes.empty() || nodes.size() > MAX_NODES_PER_TASK_GRAPH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_LIMIT, nodes.size());
	}
	for (TaskNodeDefinition &node : nodes) {
		status = canonicalize_node(node);
		if (!status.ok()) return status;
	}
	std::sort(nodes.begin(), nodes.end());
	for (std::size_t index = 1; index < nodes.size(); ++index) {
		if (nodes[index - 1].identifier == nodes[index].identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_NODE_DUPLICATE, index);
		}
	}
	if (edges.size() > MAX_EDGES_PER_TASK_GRAPH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_EDGE_LIMIT, edges.size());
	}
	for (const TaskEdgeDefinition &edge : edges) {
		status = edge.validate();
		if (!status.ok()) return status;
	}
	// Edge order is semantically authored port order (it determines the
	// deterministic order in which a future compiler visits same-port fan-out),
	// so preserve it. Duplicate IDs are still rejected independent of order.
	for (std::size_t index = 0; index < edges.size(); ++index) {
		for (std::size_t other = index + 1; other < edges.size(); ++other) {
			if (edges[index].identifier == edges[other].identifier) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::GRAPH_EDGE_DUPLICATE, other);
			}
		}
	}
	if (max_transitions_per_advance == 0 || max_transitions_per_advance > MAX_TRANSITIONS_PER_ADVANCE) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE, max_transitions_per_advance);
	}
	return ok_status();
}

std::uint64_t TaskGraphDefinition::fingerprint() const {
	TaskGraphDefinition copy = *this;
	if (!copy.validate_and_canonicalize().ok()) return invalid_fingerprint<TaskGraphDefinition>();
	Hasher hasher;
	hasher.write_string("lts.task-graph.v1");
	hasher.write_string(copy.identifier);
	hasher.write_u16(copy.schema_version);
	hasher.write_string(copy.entry_node_identifier);
	hasher.write_u32(static_cast<std::uint32_t>(copy.terminal_outcomes.size()));
	for (const std::string &outcome : copy.terminal_outcomes) hasher.write_string(outcome);
	hasher.write_u32(static_cast<std::uint32_t>(copy.nodes.size()));
	for (const TaskNodeDefinition &node : copy.nodes) hash_node(hasher, node);
	hasher.write_u32(static_cast<std::uint32_t>(copy.edges.size()));
	for (const TaskEdgeDefinition &edge : copy.edges) hash_edge(hasher, edge);
	hasher.write_u32(copy.max_transitions_per_advance);
	return hasher.digest();
}

bool TaskGraphDefinition::operator==(const TaskGraphDefinition &p_other) const {
	return identifier == p_other.identifier && schema_version == p_other.schema_version &&
			entry_node_identifier == p_other.entry_node_identifier && terminal_outcomes == p_other.terminal_outcomes &&
			nodes == p_other.nodes && edges == p_other.edges && max_transitions_per_advance == p_other.max_transitions_per_advance;
}

bool TaskGraphDefinition::operator<(const TaskGraphDefinition &p_other) const {
	return std::tie(identifier, schema_version, entry_node_identifier, terminal_outcomes, nodes, edges, max_transitions_per_advance) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.entry_node_identifier, p_other.terminal_outcomes,
					p_other.nodes, p_other.edges, p_other.max_transitions_per_advance);
}

Status LevelAnchorDefinition::validate() const {
	Status status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	if (!is_known_anchor_kind(kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::LEVEL_ANCHOR_INVALID, static_cast<std::uint8_t>(kind));
	}
	return validate_text(binding_label, MAX_ANCHOR_BINDING_LABEL_BYTES);
}

bool LevelAnchorDefinition::operator<(const LevelAnchorDefinition &p_other) const {
	return std::tie(identifier, kind, required, binding_label) < std::tie(p_other.identifier, p_other.kind, p_other.required, p_other.binding_label);
}

Status LevelExitDefinition::validate() const {
	Status status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_identifier(target_level_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(target_anchor_identifier);
	if (!status.ok()) return status;
	return validate_local_identifier(outcome_identifier);
}

bool LevelExitDefinition::operator<(const LevelExitDefinition &p_other) const {
	return std::tie(identifier, target_level_identifier, target_anchor_identifier, outcome_identifier) <
			std::tie(p_other.identifier, p_other.target_level_identifier, p_other.target_anchor_identifier, p_other.outcome_identifier);
}

Status LevelDefinition::validate() const {
	LevelDefinition copy = *this;
	return copy.validate_and_canonicalize();
}

Status LevelDefinition::validate_and_canonicalize() {
	LevelDefinition candidate = *this;
	const Status status = candidate.validate_and_canonicalize_in_place();
	if (!status.ok()) return status;
	*this = std::move(candidate);
	return ok_status();
}

Status LevelDefinition::validate_and_canonicalize_in_place() {
	Status status = validate_schema(schema_version, LEVEL_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_localization_key(display_name_key);
	if (!status.ok()) return status;
	status = validate_optional_localization_key(description_key);
	if (!status.ok()) return status;
	if (scene_resource.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID);
	}
	status = validate_text(scene_resource, MAX_SCENE_RESOURCE_BYTES, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID);
	if (!status.ok()) return status;
	status = canonicalize_predicates(availability_rules, MAX_AVAILABILITY_RULES, DiagnosticId::LEVEL_AVAILABILITY_INVALID);
	if (!status.ok()) return status;
	if (entry_graph_identifiers.empty() || entry_graph_identifiers.size() > MAX_ENTRY_GRAPHS_PER_LEVEL) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID, entry_graph_identifiers.size());
	}
	status = canonicalize_identifiers(entry_graph_identifiers, MAX_ENTRY_GRAPHS_PER_LEVEL, true, DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID);
	if (!status.ok()) return status;
	status = canonicalize_records(
			anchors,
			MAX_ANCHORS_PER_LEVEL,
			[](LevelAnchorDefinition &p_anchor) { return p_anchor.validate(); },
			[](const LevelAnchorDefinition &p_a, const LevelAnchorDefinition &p_b) { return p_a < p_b; },
			DiagnosticId::LEVEL_ANCHOR_INVALID);
	if (!status.ok()) return status;
	for (std::size_t index = 1; index < anchors.size(); ++index) {
		if (anchors[index - 1].identifier == anchors[index].identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::LEVEL_ANCHOR_INVALID, index);
		}
	}
	status = canonicalize_records(
			exits,
			MAX_EXITS_PER_LEVEL,
			[](LevelExitDefinition &p_exit) { return p_exit.validate(); },
			[](const LevelExitDefinition &p_a, const LevelExitDefinition &p_b) { return p_a < p_b; },
			DiagnosticId::LEVEL_EXIT_INVALID);
	if (status.ok()) {
		for (std::size_t index = 1; index < exits.size(); ++index) {
			if (exits[index - 1].identifier == exits[index].identifier) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::LEVEL_EXIT_INVALID, index);
			}
		}
	}
	return status;
}

std::uint64_t LevelDefinition::fingerprint() const {
	LevelDefinition copy = *this;
	if (!copy.validate_and_canonicalize().ok()) return invalid_fingerprint<LevelDefinition>();
	Hasher hasher;
	hasher.write_string("lts.level.v1");
	hasher.write_string(copy.identifier);
	hasher.write_u16(copy.schema_version);
	hasher.write_string(copy.display_name_key);
	hasher.write_string(copy.description_key);
	hasher.write_string(copy.scene_resource);
	hasher.write_u32(static_cast<std::uint32_t>(copy.availability_rules.size()));
	for (const FactPredicate &predicate : copy.availability_rules) hash_predicate(hasher, predicate);
	hasher.write_u32(static_cast<std::uint32_t>(copy.entry_graph_identifiers.size()));
	for (const std::string &entry : copy.entry_graph_identifiers) hasher.write_string(entry);
	hasher.write_u32(static_cast<std::uint32_t>(copy.anchors.size()));
	for (const LevelAnchorDefinition &anchor : copy.anchors) hash_anchor(hasher, anchor);
	hasher.write_u32(static_cast<std::uint32_t>(copy.exits.size()));
	for (const LevelExitDefinition &exit : copy.exits) hash_exit(hasher, exit);
	return hasher.digest();
}

bool LevelDefinition::operator==(const LevelDefinition &p_other) const {
	return identifier == p_other.identifier && schema_version == p_other.schema_version &&
			display_name_key == p_other.display_name_key && description_key == p_other.description_key &&
			scene_resource == p_other.scene_resource && availability_rules == p_other.availability_rules &&
			entry_graph_identifiers == p_other.entry_graph_identifiers && anchors == p_other.anchors && exits == p_other.exits;
}

bool LevelDefinition::operator<(const LevelDefinition &p_other) const {
	return std::tie(identifier, schema_version, display_name_key, description_key, scene_resource, availability_rules,
			entry_graph_identifiers, anchors, exits) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.display_name_key, p_other.description_key,
					p_other.scene_resource, p_other.availability_rules, p_other.entry_graph_identifiers, p_other.anchors, p_other.exits);
}

Status ConversationChoiceDefinition::validate() const {
	ConversationChoiceDefinition copy = *this;
	return validate_choice(copy);
}

bool ConversationChoiceDefinition::operator<(const ConversationChoiceDefinition &p_other) const {
	return std::tie(identifier, label_key, target_step_identifier, conditions) <
			std::tie(p_other.identifier, p_other.label_key, p_other.target_step_identifier, p_other.conditions);
}

Status ConversationStepDefinition::validate() const {
	ConversationStepDefinition copy = *this;
	return validate_step(copy);
}

bool ConversationStepDefinition::operator==(const ConversationStepDefinition &p_other) const {
	return identifier == p_other.identifier && kind == p_other.kind && speaker_identifier == p_other.speaker_identifier &&
			line_key == p_other.line_key && parameters == p_other.parameters && next_step_identifier == p_other.next_step_identifier &&
			provider_identifier == p_other.provider_identifier && conditions == p_other.conditions &&
			true_step_identifier == p_other.true_step_identifier && false_step_identifier == p_other.false_step_identifier &&
		success_step_identifier == p_other.success_step_identifier && failure_step_identifier == p_other.failure_step_identifier &&
			choices == p_other.choices && target_step_identifier == p_other.target_step_identifier && outcome_identifier == p_other.outcome_identifier;
}

bool ConversationStepDefinition::operator<(const ConversationStepDefinition &p_other) const {
	return std::tie(identifier, kind, speaker_identifier, line_key, parameters, next_step_identifier, provider_identifier,
			conditions, true_step_identifier, false_step_identifier, success_step_identifier, failure_step_identifier, choices,
			target_step_identifier, outcome_identifier) <
			std::tie(p_other.identifier, p_other.kind, p_other.speaker_identifier, p_other.line_key, p_other.parameters,
					p_other.next_step_identifier, p_other.provider_identifier, p_other.conditions, p_other.true_step_identifier,
					p_other.false_step_identifier, p_other.success_step_identifier, p_other.failure_step_identifier, p_other.choices,
					p_other.target_step_identifier, p_other.outcome_identifier);
}

Status SpeakerDefinition::validate() const {
	Status status = validate_schema(schema_version, SPEAKER_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_localization_key(display_name_key);
	if (!status.ok()) return status;
	return validate_optional_localization_key(portrait_key);
}

std::uint64_t SpeakerDefinition::fingerprint() const {
	if (!validate().ok()) return invalid_fingerprint<SpeakerDefinition>();
	Hasher hasher;
	hasher.write_string("lts.speaker.v1");
	hasher.write_string(identifier);
	hasher.write_u16(schema_version);
	hasher.write_string(display_name_key);
	hasher.write_string(portrait_key);
	return hasher.digest();
}

bool SpeakerDefinition::operator<(const SpeakerDefinition &p_other) const {
	return std::tie(identifier, schema_version, display_name_key, portrait_key) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.display_name_key, p_other.portrait_key);
}

Status ConversationDefinition::validate() const {
	ConversationDefinition copy = *this;
	return copy.validate_and_canonicalize();
}

Status ConversationDefinition::validate_and_canonicalize() {
	ConversationDefinition candidate = *this;
	const Status status = candidate.validate_and_canonicalize_in_place();
	if (!status.ok()) return status;
	*this = std::move(candidate);
	return ok_status();
}

Status ConversationDefinition::validate_and_canonicalize_in_place() {
	Status status = validate_schema(schema_version, CONVERSATION_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(entry_label);
	if (!status.ok()) return status;
	status = canonicalize_identifiers(speaker_identifiers, MAX_SPEAKERS_PER_CONVERSATION, true);
	if (!status.ok()) return status;
	if (terminal_outcomes.empty() || terminal_outcomes.size() > MAX_TERMINAL_OUTCOMES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_OUTCOME_INVALID, terminal_outcomes.size());
	}
	status = canonicalize_identifiers(terminal_outcomes, MAX_TERMINAL_OUTCOMES, false, DiagnosticId::CONVERSATION_OUTCOME_INVALID);
	if (!status.ok()) return status;
	if (steps.empty() || steps.size() > MAX_STEPS_PER_CONVERSATION) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_STEP_LIMIT, steps.size());
	}
	for (ConversationStepDefinition &step : steps) {
		status = validate_step(step);
		if (!status.ok()) return status;
	}
	std::sort(steps.begin(), steps.end());
	for (std::size_t index = 1; index < steps.size(); ++index) {
		if (steps[index - 1].identifier == steps[index].identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::CONVERSATION_STEP_DUPLICATE, index);
		}
	}
	if (max_steps_per_advance == 0 || max_steps_per_advance > MAX_CONVERSATION_STEPS_PER_ADVANCE ||
			max_jumps_per_advance == 0 || max_jumps_per_advance > MAX_JUMPS_PER_ADVANCE) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	return ok_status();
}

std::uint64_t ConversationDefinition::fingerprint() const {
	ConversationDefinition copy = *this;
	if (!copy.validate_and_canonicalize().ok()) return invalid_fingerprint<ConversationDefinition>();
	Hasher hasher;
	hasher.write_string("lts.conversation.v1");
	hasher.write_string(copy.identifier);
	hasher.write_u16(copy.schema_version);
	hasher.write_string(copy.entry_label);
	hasher.write_u32(static_cast<std::uint32_t>(copy.speaker_identifiers.size()));
	for (const std::string &speaker : copy.speaker_identifiers) hasher.write_string(speaker);
	hasher.write_u32(static_cast<std::uint32_t>(copy.terminal_outcomes.size()));
	for (const std::string &outcome : copy.terminal_outcomes) hasher.write_string(outcome);
	hasher.write_u32(static_cast<std::uint32_t>(copy.steps.size()));
	for (const ConversationStepDefinition &step : copy.steps) hash_step(hasher, step);
	hasher.write_u32(copy.max_steps_per_advance);
	hasher.write_u32(copy.max_jumps_per_advance);
	return hasher.digest();
}

bool ConversationDefinition::operator==(const ConversationDefinition &p_other) const {
	return identifier == p_other.identifier && schema_version == p_other.schema_version && entry_label == p_other.entry_label &&
			speaker_identifiers == p_other.speaker_identifiers && terminal_outcomes == p_other.terminal_outcomes && steps == p_other.steps &&
			max_steps_per_advance == p_other.max_steps_per_advance && max_jumps_per_advance == p_other.max_jumps_per_advance;
}

bool ConversationDefinition::operator<(const ConversationDefinition &p_other) const {
	return std::tie(identifier, schema_version, entry_label, speaker_identifiers, terminal_outcomes, steps, max_steps_per_advance,
			max_jumps_per_advance) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.entry_label, p_other.speaker_identifiers,
					p_other.terminal_outcomes, p_other.steps, p_other.max_steps_per_advance, p_other.max_jumps_per_advance);
}

Status ProviderDeclaration::validate() const {
	Status status = validate_schema(schema_version, PROVIDER_DEFINITION_SCHEMA_VERSION);
	if (!status.ok()) return status;
	status = validate_identifier(identifier);
	if (!status.ok()) return status;
	if (!is_known_provider_kind(kind)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::PROVIDER_KIND_INVALID, static_cast<std::uint8_t>(kind));
	}
	if (!is_known_value_type(request_type) || !is_known_value_type(response_type)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM);
	}
	if (max_request_bytes > MAX_PROVIDER_PAYLOAD_BYTES || max_response_bytes > MAX_PROVIDER_PAYLOAD_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::PROVIDER_PAYLOAD_LIMIT);
	}
	return ok_status();
}

std::uint64_t ProviderDeclaration::fingerprint() const {
	if (!validate().ok()) return invalid_fingerprint<ProviderDeclaration>();
	Hasher hasher;
	hasher.write_string("lts.provider.v1");
	hasher.write_string(identifier);
	hasher.write_u16(schema_version);
	hasher.write_u8(static_cast<std::uint8_t>(kind));
	hasher.write_u8(static_cast<std::uint8_t>(request_type));
	hasher.write_u8(static_cast<std::uint8_t>(response_type));
	hasher.write_u32(max_request_bytes);
	hasher.write_u32(max_response_bytes);
	hasher.write_bool(deterministic);
	hasher.write_bool(authority_only);
	return hasher.digest();
}

bool ProviderDeclaration::operator==(const ProviderDeclaration &p_other) const {
	return identifier == p_other.identifier && schema_version == p_other.schema_version && kind == p_other.kind &&
			request_type == p_other.request_type && response_type == p_other.response_type &&
			max_request_bytes == p_other.max_request_bytes && max_response_bytes == p_other.max_response_bytes &&
			deterministic == p_other.deterministic && authority_only == p_other.authority_only;
}

bool ProviderDeclaration::operator<(const ProviderDeclaration &p_other) const {
	return std::tie(identifier, schema_version, kind, request_type, response_type, max_request_bytes, max_response_bytes,
			deterministic, authority_only) <
			std::tie(p_other.identifier, p_other.schema_version, p_other.kind, p_other.request_type, p_other.response_type,
					p_other.max_request_bytes, p_other.max_response_bytes, p_other.deterministic, p_other.authority_only);
}

Status validate_and_canonicalize(TaskGraphDefinition &r_definition) {
	return r_definition.validate_and_canonicalize();
}

Status validate_and_canonicalize(Value &r_value) {
	return r_value.validate();
}

Status validate_and_canonicalize(FactPredicate &r_predicate) {
	return r_predicate.validate();
}

Status validate_and_canonicalize(TaskPortDefinition &r_port) {
	return r_port.validate();
}

Status validate_and_canonicalize(TaskNodeDefinition &r_node) {
	return canonicalize_node(r_node);
}

Status validate_and_canonicalize(TaskEdgeDefinition &r_edge) {
	return r_edge.validate();
}

Status validate_and_canonicalize(LevelDefinition &r_definition) {
	return r_definition.validate_and_canonicalize();
}

Status validate_and_canonicalize(LevelAnchorDefinition &r_anchor) {
	return r_anchor.validate();
}

Status validate_and_canonicalize(LevelExitDefinition &r_exit) {
	return r_exit.validate();
}

Status validate_and_canonicalize(ConversationChoiceDefinition &r_choice) {
	return validate_choice(r_choice);
}

Status validate_and_canonicalize(ConversationStepDefinition &r_step) {
	return validate_step(r_step);
}

Status validate_and_canonicalize(ConversationDefinition &r_definition) {
	return r_definition.validate_and_canonicalize();
}

Status validate_and_canonicalize(ProviderDeclaration &r_definition) {
	return r_definition.validate();
}

Status validate_and_canonicalize(SpeakerDefinition &r_definition) {
	return r_definition.validate();
}

} // namespace lts
