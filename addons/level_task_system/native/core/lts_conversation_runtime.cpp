#include "core/lts_conversation_runtime.h"

#include "core/lts_hash.h"
#include "core/lts_identifier.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>

namespace lts {

namespace {

constexpr std::size_t MAX_REQUEST_HISTORY = MAX_PENDING_REQUESTS;
constexpr const char *SNAPSHOT_MAGIC = "lts.conversation.snapshot.v1";
constexpr std::uint8_t SNAPSHOT_KIND_CONVERSATION = 1;
constexpr std::uint8_t REQUEST_SUCCESS = 1;
constexpr std::uint8_t REQUEST_FAILURE = 2;
constexpr std::uint8_t REQUEST_TIMEOUT = 3;

Status runtime_invalid(DiagnosticId p_diagnostic = DiagnosticId::NONE, std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_ARGUMENT, p_diagnostic, p_detail);
}

Status conversation_invalid(DiagnosticId p_diagnostic, std::uint64_t p_detail = 0) {
	return make_status(StatusCode::CONVERSATION_INVALID, p_diagnostic, p_detail);
}

Status snapshot_invalid(DiagnosticId p_diagnostic, std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_ARGUMENT, p_diagnostic, p_detail);
}

Status snapshot_limit(std::uint64_t p_detail) {
	return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_detail);
}

bool is_known_frame_kind(ConversationFrameKind p_kind) {
	switch (p_kind) {
		case ConversationFrameKind::NONE:
		case ConversationFrameKind::LINE:
		case ConversationFrameKind::CHOICE:
		case ConversationFrameKind::EXTERNAL_ACTION:
		case ConversationFrameKind::OUTCOME:
			return true;
	}
	return false;
}

bool is_known_instance_status(ConversationInstanceStatus p_status) {
	switch (p_status) {
		case ConversationInstanceStatus::INACTIVE:
		case ConversationInstanceStatus::LINE:
		case ConversationInstanceStatus::CHOICE:
		case ConversationInstanceStatus::WAITING_FOR_ACTION:
		case ConversationInstanceStatus::TERMINAL:
			return true;
	}
	return false;
}

bool is_known_request_outcome(std::uint8_t p_outcome) {
	return p_outcome == REQUEST_SUCCESS || p_outcome == REQUEST_FAILURE || p_outcome == REQUEST_TIMEOUT;
}

Status validate_text(const std::string &p_value, std::size_t p_limit, DiagnosticId p_diagnostic = DiagnosticId::BYTE_LIMIT_EXCEEDED) {
	if (p_value.size() > p_limit) return make_status(StatusCode::LIMIT_EXCEEDED, p_diagnostic, p_value.size());
	return ok_status();
}

Status validate_optional_global_identifier(const std::string &p_value) {
	return p_value.empty() ? ok_status() : validate_identifier(p_value);
}

std::size_t value_encoded_size(const Value &p_value) {
	std::size_t size = 1; // value type
	switch (p_value.type) {
		case ValueType::NONE:
			break;
		case ValueType::BOOLEAN:
			size += 1;
			break;
		case ValueType::INTEGER:
		case ValueType::FIXED:
			size += sizeof(std::int64_t);
			break;
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
			size += sizeof(std::uint32_t);
			if (std::holds_alternative<std::string>(p_value.payload)) size += std::get<std::string>(p_value.payload).size();
			break;
		case ValueType::BYTES:
			size += sizeof(std::uint32_t);
			if (std::holds_alternative<ByteVector>(p_value.payload)) size += std::get<ByteVector>(p_value.payload).size();
			break;
	}
	return size;
}

std::size_t localized_parameters_encoded_size(const std::vector<LocalizedParameter> &p_parameters) {
	std::size_t size = sizeof(std::uint32_t);
	for (const LocalizedParameter &parameter : p_parameters) {
		const std::size_t value_size = value_encoded_size(parameter.value);
		if (size > std::numeric_limits<std::size_t>::max() - sizeof(std::uint32_t) - parameter.identifier.size() - value_size) {
			return std::numeric_limits<std::size_t>::max();
		}
		size += sizeof(std::uint32_t) + parameter.identifier.size() + value_size;
	}
	return size;
}

Status validate_parameters(const std::vector<LocalizedParameter> &p_parameters) {
	if (p_parameters.size() > MAX_LINE_PARAMETERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_parameters.size());
	}
	for (const LocalizedParameter &parameter : p_parameters) {
		const Status status = parameter.validate();
		if (!status.ok()) return status;
	}
	for (std::size_t index = 1; index < p_parameters.size(); ++index) {
		if (p_parameters[index - 1].identifier == p_parameters[index].identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::CONVERSATION_LINE_INVALID, index);
		}
	}
	if (localized_parameters_encoded_size(p_parameters) > MAX_PARAMETERS_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED,
				localized_parameters_encoded_size(p_parameters));
	}
	return ok_status();
}

const ConversationStepDefinition *find_step(const ConversationDefinition &p_definition, const std::string &p_identifier) {
	for (const ConversationStepDefinition &step : p_definition.steps) {
		if (step.identifier == p_identifier) return &step;
	}
	return nullptr;
}

bool contains_identifier(const std::vector<std::string> &p_values, const std::string &p_value) {
	return std::find(p_values.begin(), p_values.end(), p_value) != p_values.end();
}

bool compare_values(const Value &p_actual, const Value &p_expected, ComparisonOperator p_comparator) {
	if (p_actual.type != p_expected.type) return false;
	switch (p_comparator) {
		case ComparisonOperator::EQUAL:
			return p_actual == p_expected;
		case ComparisonOperator::NOT_EQUAL:
			return p_actual != p_expected;
		case ComparisonOperator::LESS:
			return p_actual < p_expected;
		case ComparisonOperator::LESS_OR_EQUAL:
			return p_actual < p_expected || p_actual == p_expected;
		case ComparisonOperator::GREATER:
			return p_expected < p_actual;
		case ComparisonOperator::GREATER_OR_EQUAL:
			return p_expected < p_actual || p_actual == p_expected;
	}
	return false;
}

bool predicate_matches(const FactPredicate &p_predicate, const ConversationFactSnapshot &p_facts) {
	const Value *actual = p_facts.find(p_predicate.provider_identifier, p_predicate.fact_identifier);
	// A missing fact is deliberately false even for NOT_EQUAL. This keeps a
	// newly introduced/missing host fact from exposing a choice by accident.
	return actual != nullptr && compare_values(*actual, p_predicate.expected, p_predicate.comparator);
}

bool predicates_match(const std::vector<FactPredicate> &p_predicates, const ConversationFactSnapshot &p_facts) {
	for (const FactPredicate &predicate : p_predicates) {
		if (!predicate_matches(predicate, p_facts)) return false;
	}
	return true;
}

std::uint64_t request_hash(
		const ConversationDefinition &p_definition,
		const std::string &p_instance_identifier,
		const std::string &p_scope_identifier,
		const std::string &p_current_step_identifier,
		std::uint64_t p_revision) {
	Hasher hasher;
	hasher.write_string("lts.conversation.request.v1");
	hasher.write_string(p_definition.identifier);
	hasher.write_string(p_instance_identifier);
	hasher.write_string(p_scope_identifier);
	hasher.write_string(p_current_step_identifier);
	hasher.write_u64(p_revision);
	return hasher.digest();
}

std::string hex_u64(std::uint64_t p_value) {
	static const char *digits = "0123456789abcdef";
	std::string result(16, '0');
	for (std::size_t index = result.size(); index > 0; --index) {
		result[index - 1] = digits[p_value & 0xfU];
		p_value >>= 4;
	}
	return result;
}

std::string make_request_identifier(
		const ConversationDefinition &p_definition,
		const std::string &p_instance_identifier,
		const std::string &p_scope_identifier,
		const std::string &p_current_step_identifier,
		std::uint64_t p_revision) {
	// Identifier segments must begin with a lowercase letter. Prefix the digest
	// so every deterministic request ID remains valid even when its first hex
	// digit is numeric.
	return std::string("request.r") + hex_u64(request_hash(p_definition, p_instance_identifier, p_scope_identifier,
			p_current_step_identifier, p_revision));
}

class SnapshotWriter {
public:
	void write_u8(std::uint8_t p_value) { bytes.push_back(p_value); }

	void write_u16(std::uint16_t p_value) {
		for (int index = 0; index < 2; ++index) write_u8(static_cast<std::uint8_t>((p_value >> (index * 8)) & 0xffU));
	}

	void write_u32(std::uint32_t p_value) {
		for (int index = 0; index < 4; ++index) write_u8(static_cast<std::uint8_t>((p_value >> (index * 8)) & 0xffU));
	}

	void write_u64(std::uint64_t p_value) {
		for (int index = 0; index < 8; ++index) write_u8(static_cast<std::uint8_t>((p_value >> (index * 8)) & 0xffULL));
	}

	void write_string(const std::string &p_value) {
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		bytes.insert(bytes.end(), p_value.begin(), p_value.end());
	}

	std::vector<std::uint8_t> bytes;
};

class SnapshotReader {
public:
	explicit SnapshotReader(const std::vector<std::uint8_t> &p_bytes) : bytes(p_bytes) {}

	bool read_u8(std::uint8_t &r_value) {
		if (offset >= bytes.size()) return false;
		r_value = bytes[offset++];
		return true;
	}

	bool read_u16(std::uint16_t &r_value) {
		std::uint8_t b0 = 0;
		std::uint8_t b1 = 0;
		if (!read_u8(b0) || !read_u8(b1)) return false;
		r_value = static_cast<std::uint16_t>(b0) | (static_cast<std::uint16_t>(b1) << 8);
		return true;
	}

	bool read_u32(std::uint32_t &r_value) {
		std::uint32_t result = 0;
		for (int index = 0; index < 4; ++index) {
			std::uint8_t byte = 0;
			if (!read_u8(byte)) return false;
			result |= static_cast<std::uint32_t>(byte) << (index * 8);
		}
		r_value = result;
		return true;
	}

	bool read_u64(std::uint64_t &r_value) {
		std::uint64_t result = 0;
		for (int index = 0; index < 8; ++index) {
			std::uint8_t byte = 0;
			if (!read_u8(byte)) return false;
			result |= static_cast<std::uint64_t>(byte) << (index * 8);
		}
		r_value = result;
		return true;
	}

	bool read_string(std::string &r_value, std::size_t p_limit) {
		std::uint32_t length = 0;
		if (!read_u32(length)) return false;
		if (length > p_limit || static_cast<std::size_t>(length) > bytes.size() - offset) return false;
		r_value.assign(reinterpret_cast<const char *>(bytes.data() + offset), length);
		offset += length;
		return true;
	}

	bool exhausted() const { return offset == bytes.size(); }

private:
	const std::vector<std::uint8_t> &bytes;
	std::size_t offset = 0;
};

void encode_value(SnapshotWriter &r_writer, const Value &p_value) {
	r_writer.write_u8(static_cast<std::uint8_t>(p_value.type));
	switch (p_value.type) {
		case ValueType::NONE:
			break;
		case ValueType::BOOLEAN:
			r_writer.write_u8(std::get<bool>(p_value.payload) ? 1U : 0U);
			break;
		case ValueType::INTEGER:
			r_writer.write_u64(static_cast<std::uint64_t>(std::get<std::int64_t>(p_value.payload)));
			break;
		case ValueType::FIXED:
			r_writer.write_u64(static_cast<std::uint64_t>(std::get<FixedPoint>(p_value.payload).raw));
			break;
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
			r_writer.write_string(std::get<std::string>(p_value.payload));
			break;
		case ValueType::BYTES:
			r_writer.write_u32(static_cast<std::uint32_t>(std::get<ByteVector>(p_value.payload).size()));
			for (const std::uint8_t byte : std::get<ByteVector>(p_value.payload)) r_writer.write_u8(byte);
			break;
	}
}

bool decode_value(SnapshotReader &r_reader, Value &r_value) {
	std::uint8_t raw_type = 0;
	if (!r_reader.read_u8(raw_type) || !is_known_value_type(static_cast<ValueType>(raw_type))) return false;
	const ValueType type = static_cast<ValueType>(raw_type);
	switch (type) {
		case ValueType::NONE:
			r_value = Value::none();
			return true;
		case ValueType::BOOLEAN: {
			std::uint8_t value = 0;
			if (!r_reader.read_u8(value) || value > 1) return false;
			r_value = Value::boolean(value != 0);
			return true;
		}
		case ValueType::INTEGER: {
			std::uint64_t raw = 0;
			if (!r_reader.read_u64(raw)) return false;
			r_value = Value::integer(static_cast<std::int64_t>(raw));
			return true;
		}
		case ValueType::FIXED: {
			std::uint64_t raw = 0;
			if (!r_reader.read_u64(raw)) return false;
			r_value = Value::fixed(FixedPoint::from_raw(static_cast<std::int64_t>(raw)));
			return true;
		}
		case ValueType::STRING: {
			std::string value;
			if (!r_reader.read_string(value, MAX_STRING_BYTES)) return false;
			r_value = Value::string(value);
			return true;
		}
		case ValueType::IDENTIFIER: {
			std::string value;
			if (!r_reader.read_string(value, MAX_IDENTIFIER_BYTES)) return false;
			r_value = Value::identifier(value);
			return true;
		}
		case ValueType::BYTES: {
			std::uint32_t size = 0;
			if (!r_reader.read_u32(size) || size > MAX_VALUE_BYTES) return false;
			ByteVector value;
			value.reserve(size);
			for (std::uint32_t index = 0; index < size; ++index) {
				std::uint8_t byte = 0;
				if (!r_reader.read_u8(byte)) return false;
				value.push_back(byte);
			}
			r_value = Value::bytes(value);
			return true;
		}
	}
	return false;
}

void encode_facts(SnapshotWriter &r_writer, const ConversationFactSnapshot &p_facts) {
	r_writer.write_u32(static_cast<std::uint32_t>(p_facts.facts.size()));
	for (const ConversationFact &fact : p_facts.facts) {
		r_writer.write_string(fact.provider_identifier);
		r_writer.write_string(fact.fact_identifier);
		encode_value(r_writer, fact.value);
	}
}

bool decode_facts(SnapshotReader &r_reader, ConversationFactSnapshot &r_facts) {
	std::uint32_t count = 0;
	if (!r_reader.read_u32(count) || count > MAX_CONVERSATION_FACTS) return false;
	r_facts.facts.clear();
	r_facts.facts.reserve(count);
	for (std::uint32_t index = 0; index < count; ++index) {
		ConversationFact fact;
		if (!r_reader.read_string(fact.provider_identifier, MAX_IDENTIFIER_BYTES) ||
				!r_reader.read_string(fact.fact_identifier, MAX_IDENTIFIER_BYTES) || !decode_value(r_reader, fact.value)) {
			return false;
		}
		r_facts.facts.push_back(std::move(fact));
	}
	return r_facts.validate_and_canonicalize().ok();
}

} // namespace

Status ConversationFact::validate() const {
	Status status = validate_identifier(provider_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(fact_identifier);
	if (!status.ok()) return status;
	return value.validate();
}

bool ConversationFact::operator<(const ConversationFact &p_other) const {
	if (provider_identifier != p_other.provider_identifier) return identifier_less(provider_identifier, p_other.provider_identifier);
	if (fact_identifier != p_other.fact_identifier) return identifier_less(fact_identifier, p_other.fact_identifier);
	return value < p_other.value;
}

Status ConversationFactSnapshot::add(const ConversationFact &p_fact) {
	ConversationFactSnapshot candidate = *this;
	candidate.facts.push_back(p_fact);
	const Status status = candidate.validate_and_canonicalize();
	if (!status.ok()) return status;
	*this = std::move(candidate);
	return ok_status();
}

Status ConversationFactSnapshot::set(const ConversationFact &p_fact) {
	Status status = p_fact.validate();
	if (!status.ok()) return status;
	ConversationFactSnapshot candidate = *this;
	bool replaced = false;
	for (ConversationFact &fact : candidate.facts) {
		if (fact.provider_identifier == p_fact.provider_identifier && fact.fact_identifier == p_fact.fact_identifier) {
			fact = p_fact;
			replaced = true;
			break;
		}
	}
	if (!replaced) candidate.facts.push_back(p_fact);
	status = candidate.validate_and_canonicalize();
	if (!status.ok()) return status;
	*this = std::move(candidate);
	return ok_status();
}

Status ConversationFactSnapshot::validate() const {
	ConversationFactSnapshot copy = *this;
	return copy.validate_and_canonicalize();
}

Status ConversationFactSnapshot::validate_and_canonicalize() {
	ConversationFactSnapshot candidate = *this;
	if (candidate.facts.size() > MAX_CONVERSATION_FACTS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, candidate.facts.size());
	}
	for (const ConversationFact &fact : candidate.facts) {
		const Status status = fact.validate();
		if (!status.ok()) return status;
	}
	std::sort(candidate.facts.begin(), candidate.facts.end());
	for (std::size_t index = 1; index < candidate.facts.size(); ++index) {
		if (candidate.facts[index - 1].provider_identifier == candidate.facts[index].provider_identifier &&
				candidate.facts[index - 1].fact_identifier == candidate.facts[index].fact_identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, index);
		}
	}
	*this = std::move(candidate);
	return ok_status();
}

const Value *ConversationFactSnapshot::find(
		const std::string &p_provider_identifier,
		const std::string &p_fact_identifier) const {
	for (const ConversationFact &fact : facts) {
		if (fact.provider_identifier == p_provider_identifier && fact.fact_identifier == p_fact_identifier) return &fact.value;
	}
	return nullptr;
}

bool ConversationFactSnapshot::matches(const FactPredicate &p_predicate) const {
	return p_predicate.validate().ok() && predicate_matches(p_predicate, *this);
}

Status ConversationFactSnapshot::evaluate(const FactPredicate &p_predicate, bool &r_matches) const {
	r_matches = false;
	const Status status = p_predicate.validate();
	if (!status.ok()) return status;
	r_matches = predicate_matches(p_predicate, *this);
	return ok_status();
}

Status ConversationFactSnapshot::evaluate_all(const std::vector<FactPredicate> &p_predicates, bool &r_matches) const {
	r_matches = false;
	if (p_predicates.size() > MAX_CHOICE_CONDITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_predicates.size());
	}
	for (const FactPredicate &predicate : p_predicates) {
		const Status status = predicate.validate();
		if (!status.ok()) return status;
		if (!predicate_matches(predicate, *this)) return ok_status();
	}
	r_matches = true;
	return ok_status();
}

Status validate_and_canonicalize(ConversationFact &r_fact) {
	return r_fact.validate();
}

Status validate_and_canonicalize(ConversationFactSnapshot &r_snapshot) {
	return r_snapshot.validate_and_canonicalize();
}

Status ConversationChoiceFrame::validate() const {
	Status status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(label_key);
	if (!status.ok()) return status;
	return validate_text(label_key, MAX_LOCALIZATION_KEY_BYTES);
}

Status ConversationActionRequest::validate() const {
	Status status = validate_identifier(request_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(conversation_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(scope_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(step_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(provider_identifier);
	if (!status.ok()) return status;
	if (frame_revision == 0) return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
	return validate_parameters(parameters);
}

bool ConversationActionRequest::operator==(const ConversationActionRequest &p_other) const {
	return request_identifier == p_other.request_identifier && conversation_identifier == p_other.conversation_identifier &&
			instance_identifier == p_other.instance_identifier && scope_identifier == p_other.scope_identifier &&
			step_identifier == p_other.step_identifier && provider_identifier == p_other.provider_identifier &&
			frame_revision == p_other.frame_revision && parameters == p_other.parameters;
}

Status ConversationFrame::validate() const {
	if (!is_known_frame_kind(kind)) return runtime_invalid(DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(kind));
	if (kind == ConversationFrameKind::NONE) {
		return revision == 0 ? ok_status() : runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, revision);
	}
	if (revision == 0) return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
	Status status = validate_local_identifier(step_identifier);
	if (!status.ok()) return status;
	if (kind == ConversationFrameKind::LINE) {
		status = validate_identifier(speaker_identifier);
		if (!status.ok()) return status;
		status = validate_local_identifier(line_key);
		if (!status.ok()) return status;
		status = validate_text(line_key, MAX_LOCALIZATION_KEY_BYTES);
		if (!status.ok()) return status;
		if (terminal || !choices.empty() || action_request.has_value() || !outcome_identifier.empty()) {
			return conversation_invalid(DiagnosticId::CONVERSATION_LINE_INVALID);
		}
		return validate_parameters(parameters);
	}
	if (kind == ConversationFrameKind::CHOICE) {
		if (terminal || action_request.has_value() || !outcome_identifier.empty() || !parameters.empty() ||
				!speaker_identifier.empty() || !line_key.empty()) {
			return conversation_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID);
		}
		if (choices.size() > MAX_CHOICES_PER_CONVERSATION_STEP) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_CHOICE_LIMIT, choices.size());
		}
		for (std::size_t index = 0; index < choices.size(); ++index) {
			status = choices[index].validate();
			if (!status.ok()) return status;
			for (std::size_t previous = 0; previous < index; ++previous) {
				if (choices[previous].identifier == choices[index].identifier) {
					return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::CONVERSATION_CHOICE_INVALID, index);
				}
			}
		}
		return ok_status();
	}
	if (kind == ConversationFrameKind::EXTERNAL_ACTION) {
		if (terminal || !choices.empty() || !outcome_identifier.empty() || !parameters.empty() ||
				!speaker_identifier.empty() || !line_key.empty() || !action_request.has_value()) {
			return conversation_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
		}
		if (action_request->frame_revision != revision) return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
		return action_request->validate();
	}
	if (!terminal || !choices.empty() || action_request.has_value() || !parameters.empty() || !speaker_identifier.empty() ||
				!line_key.empty() || outcome_identifier.empty()) {
		return conversation_invalid(DiagnosticId::CONVERSATION_OUTCOME_INVALID);
	}
	status = validate_local_identifier(outcome_identifier);
	return status;
}

Status ConversationInstance::validate_runtime_definition(const ConversationDefinition &p_definition) const {
	ConversationDefinition copy = p_definition;
	Status status = copy.validate_and_canonicalize();
	if (!status.ok()) return status;
	if (find_step(copy, copy.entry_label) == nullptr) {
		return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_ENTRY_INVALID,
				hash_string(copy.entry_label));
	}
	for (const ConversationStepDefinition &step : copy.steps) {
		if (!step.speaker_identifier.empty() && !contains_identifier(copy.speaker_identifiers, step.speaker_identifier)) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_SPEAKER_INVALID,
					hash_string(step.speaker_identifier));
		}
		auto check_target = [&](const std::string &p_target) -> Status {
			if (p_target.empty() || find_step(copy, p_target) != nullptr) return ok_status();
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID,
					hash_string(p_target));
		};
		status = check_target(step.next_step_identifier);
		if (!status.ok()) return status;
		status = check_target(step.true_step_identifier);
		if (!status.ok()) return status;
		status = check_target(step.false_step_identifier);
		if (!status.ok()) return status;
		status = check_target(step.success_step_identifier);
		if (!status.ok()) return status;
		status = check_target(step.failure_step_identifier);
		if (!status.ok()) return status;
		status = check_target(step.target_step_identifier);
		if (!status.ok()) return status;
		if (step.kind == ConversationStepKind::OUTCOME && !contains_identifier(copy.terminal_outcomes, step.outcome_identifier)) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_OUTCOME_INVALID,
					hash_string(step.outcome_identifier));
		}
		for (const ConversationChoiceDefinition &choice : step.choices) {
			if (find_step(copy, choice.target_step_identifier) == nullptr) {
				return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID,
						hash_string(choice.target_step_identifier));
			}
		}
	}
	for (const std::string &outcome : copy.terminal_outcomes) {
		bool found = false;
		for (const ConversationStepDefinition &step : copy.steps) {
			if (step.kind == ConversationStepKind::OUTCOME && step.outcome_identifier == outcome) {
				found = true;
				break;
			}
		}
		if (!found) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_OUTCOME_INVALID,
					hash_string(outcome));
		}
	}
	return ok_status();
}

Status ConversationInstance::configure(const ConversationDefinition &p_definition) {
	ConversationDefinition candidate_definition = p_definition;
	Status status = candidate_definition.validate_and_canonicalize();
	if (!status.ok()) return status;
	status = validate_runtime_definition(candidate_definition);
	if (!status.ok()) return status;
	const std::uint64_t candidate_fingerprint = candidate_definition.fingerprint();
	if (candidate_fingerprint == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	definition_ = std::move(candidate_definition);
	definition_fingerprint_ = candidate_fingerprint;
	definition_valid_ = true;
	RuntimeState candidate_state;
	publish(candidate_state);
	return ok_status();
}

Status ConversationInstance::start(
		const std::string &p_instance_identifier,
		const std::string &p_scope_identifier,
		const ConversationFactSnapshot &p_facts,
		const std::string &p_entry_label,
		const std::string &p_task_integration_handle) {
	if (!definition_valid_) return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	return start_with_definition(definition_, p_instance_identifier, p_scope_identifier, p_facts, p_entry_label,
			p_task_integration_handle);
}

Status ConversationInstance::start(
		const ConversationDefinition &p_definition,
		const std::string &p_instance_identifier,
		const std::string &p_scope_identifier,
		const ConversationFactSnapshot &p_facts,
		const std::string &p_entry_label,
		const std::string &p_task_integration_handle) {
	return start_with_definition(p_definition, p_instance_identifier, p_scope_identifier, p_facts, p_entry_label,
			p_task_integration_handle);
}

Status ConversationInstance::start_with_definition(
		const ConversationDefinition &p_definition,
		const std::string &p_instance_identifier,
		const std::string &p_scope_identifier,
		const ConversationFactSnapshot &p_facts,
		const std::string &p_entry_label,
		const std::string &p_task_integration_handle) {
	ConversationDefinition candidate_definition = p_definition;
	Status status = candidate_definition.validate_and_canonicalize();
	if (!status.ok()) return status;
	status = validate_runtime_definition(candidate_definition);
	if (!status.ok()) return status;
	status = validate_identifier(p_instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(p_scope_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(p_task_integration_handle);
	if (!status.ok()) return status;
	ConversationFactSnapshot candidate_facts = p_facts;
	status = candidate_facts.validate_and_canonicalize();
	if (!status.ok()) return status;
	const std::string entry_label = p_entry_label.empty() ? candidate_definition.entry_label : p_entry_label;
	status = validate_local_identifier(entry_label);
	if (!status.ok()) return status;
	if (find_step(candidate_definition, entry_label) == nullptr) {
		return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_ENTRY_INVALID, hash_string(entry_label));
	}
	const std::uint64_t candidate_fingerprint = candidate_definition.fingerprint();
	if (candidate_fingerprint == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}

	RuntimeState candidate;
	candidate.instance_status = ConversationInstanceStatus::LINE;
	candidate.instance_identifier = p_instance_identifier;
	candidate.scope_identifier = p_scope_identifier;
	candidate.task_integration_handle = p_task_integration_handle;
	candidate.current_step_identifier = entry_label;
	candidate.facts = std::move(candidate_facts);
	// The first yielded frame is revision one.  No state is published until
	// every control-flow step up to that frame is bounded and valid.
	candidate.revision = 1;
	status = process_until_yield_for_definition(candidate_definition, candidate);
	if (!status.ok()) return status;
	definition_ = std::move(candidate_definition);
	definition_fingerprint_ = candidate_fingerprint;
	definition_valid_ = true;
	publish(candidate);
	return ok_status();
}

ConversationInstance::RuntimeState ConversationInstance::capture_state() const {
	RuntimeState state;
	state.instance_status = instance_status_;
	state.revision = revision_;
	state.instance_identifier = instance_identifier_;
	state.scope_identifier = scope_identifier_;
	state.task_integration_handle = task_integration_handle_;
	state.current_step_identifier = current_step_identifier_;
	state.terminal_outcome_identifier = terminal_outcome_identifier_;
	state.facts = facts_;
	state.frame = frame_;
	state.pending_request = pending_request_;
	state.resolved_requests = resolved_requests_;
	return state;
}

void ConversationInstance::publish(const RuntimeState &p_state) {
	instance_status_ = p_state.instance_status;
	revision_ = p_state.revision;
	instance_identifier_ = p_state.instance_identifier;
	scope_identifier_ = p_state.scope_identifier;
	task_integration_handle_ = p_state.task_integration_handle;
	current_step_identifier_ = p_state.current_step_identifier;
	terminal_outcome_identifier_ = p_state.terminal_outcome_identifier;
	facts_ = p_state.facts;
	frame_ = p_state.frame;
	pending_request_ = p_state.pending_request;
	resolved_requests_ = p_state.resolved_requests;
}

Status ConversationInstance::advance_revision(RuntimeState &r_state) const {
	if (r_state.revision == std::numeric_limits<std::uint64_t>::max()) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	++r_state.revision;
	return ok_status();
}

Status ConversationInstance::enter_next_step(RuntimeState &r_state, const std::string &p_step_identifier) const {
	Status status = validate_local_identifier(p_step_identifier);
	if (!status.ok()) return status;
	if (find_step(definition_, p_step_identifier) == nullptr) {
		return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID,
				hash_string(p_step_identifier));
	}
	r_state.current_step_identifier = p_step_identifier;
	r_state.terminal_outcome_identifier.clear();
	r_state.frame = ConversationFrame{};
	return ok_status();
}

Status ConversationInstance::build_frame_for_step(RuntimeState &r_state, const ConversationStepDefinition &p_step) const {
	ConversationFrame frame;
	frame.revision = r_state.revision;
	frame.step_identifier = p_step.identifier;
	switch (p_step.kind) {
		case ConversationStepKind::LINE:
			frame.kind = ConversationFrameKind::LINE;
			frame.speaker_identifier = p_step.speaker_identifier;
			frame.line_key = p_step.line_key;
			frame.parameters = p_step.parameters;
			r_state.instance_status = ConversationInstanceStatus::LINE;
			break;
		case ConversationStepKind::CHOICE:
			frame.kind = ConversationFrameKind::CHOICE;
			for (const ConversationChoiceDefinition &choice : p_step.choices) {
				if (!predicates_match(choice.conditions, r_state.facts)) continue;
				frame.choices.push_back({ choice.identifier, choice.label_key });
			}
			r_state.instance_status = ConversationInstanceStatus::CHOICE;
			break;
		case ConversationStepKind::EXTERNAL_ACTION: {
			if (r_state.pending_request.has_value()) {
				return conversation_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
			}
			frame.kind = ConversationFrameKind::EXTERNAL_ACTION;
			ConversationActionRequest request;
			request.conversation_identifier = definition_.identifier;
			request.instance_identifier = r_state.instance_identifier;
			request.scope_identifier = r_state.scope_identifier;
			request.step_identifier = p_step.identifier;
			request.provider_identifier = p_step.provider_identifier;
			request.frame_revision = r_state.revision;
			request.parameters = p_step.parameters;
			request.request_identifier = make_request_identifier(definition_, r_state.instance_identifier, r_state.scope_identifier,
					r_state.current_step_identifier, r_state.revision);
			Status status = request.validate();
			if (!status.ok()) return status;
			r_state.pending_request = request;
			frame.action_request = request;
			r_state.instance_status = ConversationInstanceStatus::WAITING_FOR_ACTION;
			break;
		}
		case ConversationStepKind::OUTCOME:
			frame.kind = ConversationFrameKind::OUTCOME;
			frame.outcome_identifier = p_step.outcome_identifier;
			frame.terminal = true;
			r_state.terminal_outcome_identifier = p_step.outcome_identifier;
			r_state.instance_status = ConversationInstanceStatus::TERMINAL;
			break;
		case ConversationStepKind::CONDITION:
		case ConversationStepKind::JUMP:
			return conversation_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	Status status = frame.validate();
	if (!status.ok()) return status;
	r_state.frame = std::move(frame);
	return ok_status();
}

Status ConversationInstance::process_until_yield(RuntimeState &r_state) const {
	return process_until_yield_for_definition(definition_, r_state);
}

// This member helper lets start() validate and traverse a candidate definition
// before publishing it as the active definition.
Status ConversationInstance::process_until_yield_for_definition(
		const ConversationDefinition &p_definition,
		RuntimeState &r_state) const {
	const std::uint32_t step_budget = std::min(p_definition.max_steps_per_advance,
			static_cast<std::uint32_t>(MAX_CONVERSATION_STEPS_PER_ADVANCE));
	const std::uint32_t jump_budget = std::min(p_definition.max_jumps_per_advance,
			static_cast<std::uint32_t>(MAX_JUMPS_PER_ADVANCE));
	std::uint32_t steps = 0;
	std::uint32_t jumps = 0;
	r_state.frame = ConversationFrame{};
	for (;;) {
		if (steps >= step_budget) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_STEP_LIMIT, steps);
		}
		const ConversationStepDefinition *step = find_step(p_definition, r_state.current_step_identifier);
		if (step == nullptr) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID,
				hash_string(r_state.current_step_identifier));
		}
		++steps;
		switch (step->kind) {
			case ConversationStepKind::LINE: {
				ConversationFrame frame;
				frame.kind = ConversationFrameKind::LINE;
				frame.revision = r_state.revision;
				frame.step_identifier = step->identifier;
				frame.speaker_identifier = step->speaker_identifier;
				frame.line_key = step->line_key;
				frame.parameters = step->parameters;
				Status status = frame.validate();
				if (!status.ok()) return status;
				r_state.instance_status = ConversationInstanceStatus::LINE;
				r_state.frame = std::move(frame);
				return ok_status();
			}
			case ConversationStepKind::CHOICE: {
				ConversationFrame frame;
				frame.kind = ConversationFrameKind::CHOICE;
				frame.revision = r_state.revision;
				frame.step_identifier = step->identifier;
				for (const ConversationChoiceDefinition &choice : step->choices) {
					if (predicates_match(choice.conditions, r_state.facts)) {
						frame.choices.push_back({ choice.identifier, choice.label_key });
					}
				}
				Status status = frame.validate();
				if (!status.ok()) return status;
				r_state.instance_status = ConversationInstanceStatus::CHOICE;
				r_state.frame = std::move(frame);
				return ok_status();
			}
			case ConversationStepKind::CONDITION:
				r_state.current_step_identifier = predicates_match(step->conditions, r_state.facts) ?
						step->true_step_identifier : step->false_step_identifier;
				continue;
			case ConversationStepKind::EXTERNAL_ACTION: {
				if (r_state.pending_request.has_value()) {
					return conversation_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
				}
				ConversationActionRequest request;
				request.request_identifier = make_request_identifier(p_definition, r_state.instance_identifier, r_state.scope_identifier,
						r_state.current_step_identifier, r_state.revision);
				request.conversation_identifier = p_definition.identifier;
				request.instance_identifier = r_state.instance_identifier;
				request.scope_identifier = r_state.scope_identifier;
				request.step_identifier = step->identifier;
				request.provider_identifier = step->provider_identifier;
				request.frame_revision = r_state.revision;
				request.parameters = step->parameters;
				Status status = request.validate();
				if (!status.ok()) return status;
				ConversationFrame frame;
				frame.kind = ConversationFrameKind::EXTERNAL_ACTION;
				frame.revision = r_state.revision;
				frame.step_identifier = step->identifier;
				frame.action_request = request;
				status = frame.validate();
				if (!status.ok()) return status;
				r_state.pending_request = std::move(request);
				r_state.instance_status = ConversationInstanceStatus::WAITING_FOR_ACTION;
				r_state.frame = std::move(frame);
				return ok_status();
			}
			case ConversationStepKind::JUMP:
				if (jumps >= jump_budget) {
					return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_STEP_LIMIT, jumps);
				}
				++jumps;
				r_state.current_step_identifier = step->target_step_identifier;
				continue;
			case ConversationStepKind::OUTCOME: {
				ConversationFrame frame;
				frame.kind = ConversationFrameKind::OUTCOME;
				frame.revision = r_state.revision;
				frame.step_identifier = step->identifier;
				frame.outcome_identifier = step->outcome_identifier;
				frame.terminal = true;
				Status status = frame.validate();
				if (!status.ok()) return status;
				r_state.terminal_outcome_identifier = step->outcome_identifier;
				r_state.instance_status = ConversationInstanceStatus::TERMINAL;
				r_state.frame = std::move(frame);
				return ok_status();
			}
		}
	}
}

Status ConversationInstance::rebuild_current_frame(RuntimeState &r_state) const {
	const ConversationStepDefinition *step = find_step(definition_, r_state.current_step_identifier);
	if (step == nullptr) return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	if (r_state.instance_status == ConversationInstanceStatus::LINE && step->kind == ConversationStepKind::LINE) {
		return build_frame_for_step(r_state, *step);
	}
	if (r_state.instance_status == ConversationInstanceStatus::CHOICE && step->kind == ConversationStepKind::CHOICE) {
		return build_frame_for_step(r_state, *step);
	}
	if (r_state.instance_status == ConversationInstanceStatus::WAITING_FOR_ACTION &&
			step->kind == ConversationStepKind::EXTERNAL_ACTION && r_state.pending_request.has_value()) {
		ConversationFrame frame;
		frame.kind = ConversationFrameKind::EXTERNAL_ACTION;
		frame.revision = r_state.revision;
		frame.step_identifier = step->identifier;
		frame.action_request = r_state.pending_request;
		Status status = frame.validate();
		if (!status.ok()) return status;
		r_state.frame = std::move(frame);
		return ok_status();
	}
	if (r_state.instance_status == ConversationInstanceStatus::TERMINAL && step->kind == ConversationStepKind::OUTCOME) {
		ConversationFrame frame;
		frame.kind = ConversationFrameKind::OUTCOME;
		frame.revision = r_state.revision;
		frame.step_identifier = step->identifier;
		frame.outcome_identifier = step->outcome_identifier;
		frame.terminal = true;
		Status status = frame.validate();
		if (!status.ok()) return status;
		r_state.terminal_outcome_identifier = step->outcome_identifier;
		r_state.frame = std::move(frame);
		return ok_status();
	}
	return conversation_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
}

Status ConversationInstance::continue_line(std::uint64_t p_frame_revision) {
	if (!definition_valid_ || instance_status_ != ConversationInstanceStatus::LINE || !frame_.is_line()) {
		return runtime_invalid(DiagnosticId::CONVERSATION_LINE_INVALID);
	}
	if (p_frame_revision != frame_.revision) return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, p_frame_revision);
	const ConversationStepDefinition *step = find_step(definition_, current_step_identifier_);
	if (step == nullptr || step->kind != ConversationStepKind::LINE) return conversation_invalid(DiagnosticId::CONVERSATION_LINE_INVALID);
	RuntimeState candidate = capture_state();
	Status status = candidate.current_step_identifier.empty() ? runtime_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID) :
			enter_next_step(candidate, step->next_step_identifier);
	if (!status.ok()) return status;
	status = advance_revision(candidate);
	if (!status.ok()) return status;
	status = process_until_yield(candidate);
	if (!status.ok()) return status;
	publish(candidate);
	return ok_status();
}

Status ConversationInstance::select_choice(const std::string &p_choice_identifier, std::uint64_t p_frame_revision) {
	if (!definition_valid_ || instance_status_ != ConversationInstanceStatus::CHOICE || !frame_.is_choice()) {
		return runtime_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID);
	}
	if (p_frame_revision != frame_.revision) return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, p_frame_revision);
	const ConversationStepDefinition *step = find_step(definition_, current_step_identifier_);
	if (step == nullptr || step->kind != ConversationStepKind::CHOICE) return conversation_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID);
	const ConversationChoiceDefinition *selected = nullptr;
	for (const ConversationChoiceDefinition &choice : step->choices) {
		if (choice.identifier == p_choice_identifier) {
			selected = &choice;
			break;
		}
	}
	if (selected == nullptr) return runtime_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID);
	bool exposed = false;
	for (const ConversationChoiceFrame &choice : frame_.choices) {
		if (choice.identifier == p_choice_identifier) {
			exposed = true;
			break;
		}
	}
	if (!exposed || !predicates_match(selected->conditions, facts_)) {
		return runtime_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID);
	}
	RuntimeState candidate = capture_state();
	Status status = enter_next_step(candidate, selected->target_step_identifier);
	if (!status.ok()) return status;
	status = advance_revision(candidate);
	if (!status.ok()) return status;
	status = process_until_yield(candidate);
	if (!status.ok()) return status;
	publish(candidate);
	return ok_status();
}

Status ConversationInstance::set_facts(const ConversationFactSnapshot &p_facts) {
	ConversationFactSnapshot candidate_facts = p_facts;
	Status status = candidate_facts.validate_and_canonicalize();
	if (!status.ok()) return status;
	if (!definition_valid_ || instance_status_ == ConversationInstanceStatus::INACTIVE) {
		RuntimeState candidate = capture_state();
		candidate.facts = std::move(candidate_facts);
		publish(candidate);
		return ok_status();
	}
	if (facts_ == candidate_facts) return ok_status();
	RuntimeState candidate = capture_state();
	candidate.facts = std::move(candidate_facts);
	// Facts may change while a host-owned action is pending. The action
	// request identity/frame revision remain unchanged; the updated snapshot
	// is then used when the acknowledged branch is traversed.
	if (instance_status_ == ConversationInstanceStatus::WAITING_FOR_ACTION) {
		publish(candidate);
		return ok_status();
	}
	if (instance_status_ == ConversationInstanceStatus::TERMINAL) {
		publish(candidate);
		return ok_status();
	}
	status = advance_revision(candidate);
	if (!status.ok()) return status;
	status = rebuild_current_frame(candidate);
	if (!status.ok()) return status;
	publish(candidate);
	return ok_status();
}

Status ConversationInstance::remember_resolved(
		RuntimeState &r_state,
		const std::string &p_request_identifier,
		std::uint8_t p_outcome) const {
	if (!is_known_request_outcome(p_outcome)) return runtime_invalid(DiagnosticId::INVALID_ENUM, p_outcome);
	for (const ResolvedRequest &resolved : r_state.resolved_requests) {
		if (resolved.request_identifier == p_request_identifier) {
			return resolved.outcome == p_outcome ? ok_status() : runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
		}
	}
	if (r_state.resolved_requests.size() >= MAX_REQUEST_HISTORY) r_state.resolved_requests.erase(r_state.resolved_requests.begin());
	r_state.resolved_requests.push_back({ p_request_identifier, p_outcome });
	return ok_status();
}

Status ConversationInstance::validate_action_request_match(
		const RuntimeState &p_state,
		const std::string &p_request_identifier,
		std::uint64_t p_frame_revision,
		bool p_revision_supplied,
		std::uint8_t p_outcome) const {
	if (!is_known_request_outcome(p_outcome)) return runtime_invalid(DiagnosticId::INVALID_ENUM, p_outcome);
	for (const ResolvedRequest &resolved : p_state.resolved_requests) {
		if (resolved.request_identifier == p_request_identifier) {
			return resolved.outcome == p_outcome ? ok_status() : runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
		}
	}
	if (!p_state.pending_request.has_value()) return make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	if (p_state.pending_request->request_identifier != p_request_identifier) {
		return runtime_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	if (p_revision_supplied && p_frame_revision != p_state.pending_request->frame_revision) {
		return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, p_frame_revision);
	}
	return ok_status();
}

Status ConversationInstance::acknowledge_action_internal(
		const std::string &p_request_identifier,
		std::uint64_t p_frame_revision,
		std::uint8_t p_outcome,
		const Value &p_response) {
	RuntimeState before = capture_state();
	const bool revision_supplied = p_frame_revision != 0;
	Status status = validate_action_request_match(before, p_request_identifier, p_frame_revision, revision_supplied, p_outcome);
	if (!status.ok()) return status;
	// A recognized duplicate is complete and idempotent. It must not validate
	// or replay the provider response, nor mutate the current frame.
	for (const ResolvedRequest &resolved : before.resolved_requests) {
		if (resolved.request_identifier == p_request_identifier) return ok_status();
	}
	status = p_response.validate();
	if (!status.ok()) return status;
	if (before.instance_status != ConversationInstanceStatus::WAITING_FOR_ACTION || !before.pending_request.has_value()) {
		return runtime_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	const ConversationStepDefinition *step = find_step(definition_, before.current_step_identifier);
	if (step == nullptr || step->kind != ConversationStepKind::EXTERNAL_ACTION) {
		return conversation_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	const std::string &target = p_outcome == REQUEST_SUCCESS ? step->success_step_identifier : step->failure_step_identifier;
	RuntimeState candidate = before;
	candidate.pending_request.reset();
	candidate.frame = ConversationFrame{};
	status = enter_next_step(candidate, target);
	if (!status.ok()) return status;
	status = advance_revision(candidate);
	if (!status.ok()) return status;
	status = process_until_yield(candidate);
	if (!status.ok()) return status;
	status = remember_resolved(candidate, p_request_identifier, p_outcome);
	if (!status.ok()) return status;
	publish(candidate);
	return ok_status();
}

Status ConversationInstance::acknowledge_action(
		const std::string &p_request_identifier,
		bool p_success,
		const Value &p_response) {
	return acknowledge_action_internal(p_request_identifier, 0, p_success ? REQUEST_SUCCESS : REQUEST_FAILURE, p_response);
}

Status ConversationInstance::acknowledge_action(
		const std::string &p_request_identifier,
		std::uint64_t p_frame_revision,
		bool p_success,
		const Value &p_response) {
	return acknowledge_action_internal(p_request_identifier, p_frame_revision, p_success ? REQUEST_SUCCESS : REQUEST_FAILURE, p_response);
}

Status ConversationInstance::reject_action(const std::string &p_request_identifier) {
	return acknowledge_action_internal(p_request_identifier, 0, REQUEST_FAILURE, Value::none());
}

Status ConversationInstance::reject_action(const std::string &p_request_identifier, std::uint64_t p_frame_revision) {
	return acknowledge_action_internal(p_request_identifier, p_frame_revision, REQUEST_FAILURE, Value::none());
}

Status ConversationInstance::timeout_action(const std::string &p_request_identifier) {
	return acknowledge_action_internal(p_request_identifier, 0, REQUEST_TIMEOUT, Value::none());
}

Status ConversationInstance::timeout_action(const std::string &p_request_identifier, std::uint64_t p_frame_revision) {
	return acknowledge_action_internal(p_request_identifier, p_frame_revision, REQUEST_TIMEOUT, Value::none());
}

Status ConversationInstance::encode_snapshot(std::vector<std::uint8_t> &r_bytes) const {
	r_bytes.clear();
	if (!definition_valid_ || definition_fingerprint_ == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	Status status = facts_.validate();
	if (!status.ok()) return status;
	status = frame_.validate();
	if (!status.ok()) return status;
	if (!is_known_instance_status(instance_status_)) return runtime_invalid(DiagnosticId::INVALID_ENUM);
	if (revision_ != frame_.revision && instance_status_ != ConversationInstanceStatus::INACTIVE) {
		return runtime_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	SnapshotWriter writer;
	writer.write_string(SNAPSHOT_MAGIC);
	writer.write_u16(SNAPSHOT_SCHEMA_VERSION);
	writer.write_u16(PROTOCOL_VERSION);
	writer.write_u16(CANONICAL_FORMAT_VERSION);
	writer.write_u8(SNAPSHOT_KIND_CONVERSATION);
	writer.write_string(definition_.identifier);
	writer.write_u64(definition_fingerprint_);
	writer.write_string(instance_identifier_);
	writer.write_string(scope_identifier_);
	writer.write_string(task_integration_handle_);
	writer.write_u8(static_cast<std::uint8_t>(instance_status_));
	writer.write_u64(revision_);
	writer.write_u64(frame_.revision);
	writer.write_u8(static_cast<std::uint8_t>(frame_.kind));
	writer.write_string(current_step_identifier_);
	writer.write_string(terminal_outcome_identifier_);
	encode_facts(writer, facts_);
	writer.write_u8(pending_request_.has_value() ? 1U : 0U);
	if (pending_request_.has_value()) {
		writer.write_string(pending_request_->request_identifier);
		writer.write_u64(pending_request_->frame_revision);
	}
	writer.write_u32(static_cast<std::uint32_t>(resolved_requests_.size()));
	for (const ResolvedRequest &resolved : resolved_requests_) {
		writer.write_string(resolved.request_identifier);
		writer.write_u8(resolved.outcome);
	}
	if (writer.bytes.size() > MAX_SNAPSHOT_BYTES) return snapshot_limit(writer.bytes.size());
	r_bytes = std::move(writer.bytes);
	return ok_status();
}

Status ConversationInstance::decode_snapshot(const std::vector<std::uint8_t> &p_bytes, RuntimeState &r_state) const {
	if (p_bytes.size() > MAX_SNAPSHOT_BYTES) return snapshot_limit(p_bytes.size());
	SnapshotReader reader(p_bytes);
	std::string magic;
	if (!reader.read_string(magic, std::string(SNAPSHOT_MAGIC).size()) || magic != SNAPSHOT_MAGIC) {
		return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
	}
	std::uint16_t snapshot_schema = 0;
	std::uint16_t protocol = 0;
	std::uint16_t canonical = 0;
	std::uint8_t kind = 0;
	if (!reader.read_u16(snapshot_schema) || !reader.read_u16(protocol) || !reader.read_u16(canonical) || !reader.read_u8(kind)) {
		return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
	}
	if (snapshot_schema != SNAPSHOT_SCHEMA_VERSION || protocol != PROTOCOL_VERSION || canonical != CANONICAL_FORMAT_VERSION) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED,
				snapshot_schema != SNAPSHOT_SCHEMA_VERSION ? snapshot_schema : (protocol != PROTOCOL_VERSION ? protocol : canonical));
	}
	if (kind != SNAPSHOT_KIND_CONVERSATION) return snapshot_invalid(DiagnosticId::INVALID_ENUM, kind);
	std::string definition_identifier;
	std::uint64_t fingerprint = INVALID_CATALOG_FINGERPRINT;
	if (!reader.read_string(definition_identifier, MAX_IDENTIFIER_BYTES) || !reader.read_u64(fingerprint)) {
		return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
	}
	if (!definition_valid_ || definition_identifier != definition_.identifier) {
		return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				hash_string(definition_identifier));
	}
	if (fingerprint != definition_fingerprint_) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, fingerprint);
	}

	RuntimeState candidate;
	std::uint8_t raw_status = 0;
	std::uint64_t frame_revision = 0;
	std::uint8_t raw_frame_kind = 0;
	if (!reader.read_string(candidate.instance_identifier, MAX_IDENTIFIER_BYTES) ||
			!reader.read_string(candidate.scope_identifier, MAX_IDENTIFIER_BYTES) ||
			!reader.read_string(candidate.task_integration_handle, MAX_IDENTIFIER_BYTES) || !reader.read_u8(raw_status) ||
			!reader.read_u64(candidate.revision) || !reader.read_u64(frame_revision) || !reader.read_u8(raw_frame_kind) ||
			!reader.read_string(candidate.current_step_identifier, MAX_IDENTIFIER_BYTES) ||
			!reader.read_string(candidate.terminal_outcome_identifier, MAX_IDENTIFIER_BYTES)) {
		return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
	}
	candidate.instance_status = static_cast<ConversationInstanceStatus>(raw_status);
	const ConversationFrameKind encoded_frame_kind = static_cast<ConversationFrameKind>(raw_frame_kind);
	if (!is_known_instance_status(candidate.instance_status) || !is_known_frame_kind(encoded_frame_kind)) {
		return snapshot_invalid(DiagnosticId::INVALID_ENUM);
	}
	if (candidate.instance_status != ConversationInstanceStatus::INACTIVE) {
		if (candidate.revision == 0 || frame_revision != candidate.revision) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
		if (validate_identifier(candidate.instance_identifier).ok() == false || validate_identifier(candidate.scope_identifier).ok() == false) {
			return snapshot_invalid(DiagnosticId::IDENTIFIER_BAD_CHARACTER);
		}
	}
	if (!candidate.task_integration_handle.empty() && !validate_identifier(candidate.task_integration_handle).ok()) {
		return snapshot_invalid(DiagnosticId::IDENTIFIER_BAD_CHARACTER);
	}
	if (!decode_facts(reader, candidate.facts)) return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
	std::uint8_t has_pending = 0;
	if (!reader.read_u8(has_pending) || has_pending > 1) return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
	if (has_pending != 0) {
		ConversationActionRequest pending;
		if (!reader.read_string(pending.request_identifier, MAX_IDENTIFIER_BYTES) || !reader.read_u64(pending.frame_revision)) {
			return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
		}
		candidate.pending_request = std::move(pending);
	}
	std::uint32_t resolved_count = 0;
	if (!reader.read_u32(resolved_count) || resolved_count > MAX_REQUEST_HISTORY) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED, resolved_count);
	}
	candidate.resolved_requests.reserve(resolved_count);
	for (std::uint32_t index = 0; index < resolved_count; ++index) {
		ResolvedRequest resolved;
		if (!reader.read_string(resolved.request_identifier, MAX_IDENTIFIER_BYTES) || !reader.read_u8(resolved.outcome) ||
				!is_known_request_outcome(resolved.outcome) || !validate_identifier(resolved.request_identifier).ok()) {
			return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);
		}
		for (const ResolvedRequest &previous : candidate.resolved_requests) {
			if (previous.request_identifier == resolved.request_identifier) return snapshot_invalid(DiagnosticId::DEFINITION_DUPLICATE);
		}
		candidate.resolved_requests.push_back(std::move(resolved));
	}
	if (!reader.exhausted()) return snapshot_invalid(DiagnosticId::TRUNCATED_PAYLOAD);

	candidate.frame = ConversationFrame{};
	if (candidate.instance_status == ConversationInstanceStatus::INACTIVE) {
		if (candidate.revision != 0 || frame_revision != 0 || encoded_frame_kind != ConversationFrameKind::NONE ||
				!candidate.current_step_identifier.empty() || !candidate.terminal_outcome_identifier.empty() ||
				candidate.pending_request.has_value()) {
			return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
		}
		return ok_status();
	}
	if (candidate.current_step_identifier.empty()) return snapshot_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	const ConversationStepDefinition *step = find_step(definition_, candidate.current_step_identifier);
	if (step == nullptr) return snapshot_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	if (candidate.instance_status == ConversationInstanceStatus::WAITING_FOR_ACTION) {
		if (step->kind != ConversationStepKind::EXTERNAL_ACTION || !candidate.pending_request.has_value() ||
				candidate.pending_request->frame_revision != candidate.revision) {
			return snapshot_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
		}
		candidate.pending_request->conversation_identifier = definition_.identifier;
		candidate.pending_request->instance_identifier = candidate.instance_identifier;
		candidate.pending_request->scope_identifier = candidate.scope_identifier;
		candidate.pending_request->step_identifier = step->identifier;
		candidate.pending_request->provider_identifier = step->provider_identifier;
		candidate.pending_request->parameters = step->parameters;
		if (candidate.pending_request->request_identifier != make_request_identifier(definition_, candidate.instance_identifier,
				candidate.scope_identifier, candidate.current_step_identifier, candidate.revision)) {
			return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
		}
	} else if (candidate.pending_request.has_value()) {
		return snapshot_invalid(DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	}
	Status status;
	if (candidate.instance_status == ConversationInstanceStatus::LINE) {
		if (step->kind != ConversationStepKind::LINE) return snapshot_invalid(DiagnosticId::CONVERSATION_LINE_INVALID);
		ConversationFrame frame;
		frame.kind = ConversationFrameKind::LINE;
		frame.revision = candidate.revision;
		frame.step_identifier = step->identifier;
		frame.speaker_identifier = step->speaker_identifier;
		frame.line_key = step->line_key;
		frame.parameters = step->parameters;
		candidate.frame = std::move(frame);
	} else if (candidate.instance_status == ConversationInstanceStatus::CHOICE) {
		if (step->kind != ConversationStepKind::CHOICE) return snapshot_invalid(DiagnosticId::CONVERSATION_CHOICE_INVALID);
		ConversationFrame frame;
		frame.kind = ConversationFrameKind::CHOICE;
		frame.revision = candidate.revision;
		frame.step_identifier = step->identifier;
		for (const ConversationChoiceDefinition &choice : step->choices) {
			if (predicates_match(choice.conditions, candidate.facts)) frame.choices.push_back({ choice.identifier, choice.label_key });
		}
		candidate.frame = std::move(frame);
	} else if (candidate.instance_status == ConversationInstanceStatus::WAITING_FOR_ACTION) {
		ConversationFrame frame;
		frame.kind = ConversationFrameKind::EXTERNAL_ACTION;
		frame.revision = candidate.revision;
		frame.step_identifier = step->identifier;
		frame.action_request = candidate.pending_request;
		candidate.frame = std::move(frame);
	} else if (candidate.instance_status == ConversationInstanceStatus::TERMINAL) {
		if (step->kind != ConversationStepKind::OUTCOME || candidate.terminal_outcome_identifier != step->outcome_identifier) {
			return snapshot_invalid(DiagnosticId::CONVERSATION_OUTCOME_INVALID);
		}
		ConversationFrame frame;
		frame.kind = ConversationFrameKind::OUTCOME;
		frame.revision = candidate.revision;
		frame.step_identifier = step->identifier;
		frame.outcome_identifier = step->outcome_identifier;
		frame.terminal = true;
		candidate.frame = std::move(frame);
	}
	if (candidate.frame.kind != encoded_frame_kind) return snapshot_invalid(DiagnosticId::INVALID_ENUM);
	status = candidate.frame.validate();
	if (!status.ok()) return status;
	r_state = std::move(candidate);
	return ok_status();
}

Status ConversationInstance::restore_snapshot(const std::vector<std::uint8_t> &p_bytes) {
	if (!definition_valid_) return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID);
	RuntimeState candidate;
	Status status = decode_snapshot(p_bytes, candidate);
	if (!status.ok()) return status;
	publish(candidate);
	return ok_status();
}

Status ConversationInstance::restore_snapshot(
		const ConversationDefinition &p_definition,
		const std::vector<std::uint8_t> &p_bytes,
		ConversationInstance &r_instance) {
	ConversationInstance candidate;
	Status status = candidate.configure(p_definition);
	if (!status.ok()) return status;
	status = candidate.restore_snapshot(p_bytes);
	if (!status.ok()) return status;
	r_instance = std::move(candidate);
	return ok_status();
}

} // namespace lts
