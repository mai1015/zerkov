#include "core/lts_values.h"

#include "core/lts_identifier.h"

#include <variant>

namespace lts {

namespace {

template <typename T>
bool holds(const Value::Payload &p_payload, ValueType p_type) {
	return p_payload.index() != 0 && std::holds_alternative<T>(p_payload) && p_type != ValueType::NONE;
}

} // namespace

bool is_known_value_type(ValueType p_type) {
	switch (p_type) {
		case ValueType::NONE:
		case ValueType::BOOLEAN:
		case ValueType::INTEGER:
		case ValueType::FIXED:
		case ValueType::STRING:
		case ValueType::IDENTIFIER:
		case ValueType::BYTES:
			return true;
	}
	return false;
}

bool is_known_comparison_operator(ComparisonOperator p_operator) {
	switch (p_operator) {
		case ComparisonOperator::EQUAL:
		case ComparisonOperator::NOT_EQUAL:
		case ComparisonOperator::LESS:
		case ComparisonOperator::LESS_OR_EQUAL:
		case ComparisonOperator::GREATER:
		case ComparisonOperator::GREATER_OR_EQUAL:
			return true;
	}
	return false;
}

Status BoundedString::validate(std::size_t p_limit) const {
	if (value.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, value.size());
	}
	return ok_status();
}

Status BoundedBytes::validate(std::size_t p_limit) const {
	if (bytes.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, bytes.size());
	}
	return ok_status();
}

Status Value::validate() const {
	if (!is_known_value_type(type)) {
		return make_status(StatusCode::INVALID_VALUE, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(type));
	}

	switch (type) {
		case ValueType::NONE:
			if (!std::holds_alternative<std::monostate>(payload)) {
				return make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
			}
			return ok_status();
		case ValueType::BOOLEAN:
			return holds<bool>(payload, type) ? ok_status() : make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
		case ValueType::INTEGER:
			return holds<std::int64_t>(payload, type) ? ok_status() : make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
		case ValueType::FIXED:
			return holds<FixedPoint>(payload, type) ? ok_status() : make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
		case ValueType::STRING:
			if (!holds<std::string>(payload, type)) {
				return make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
			}
			if (std::get<std::string>(payload).size() > MAX_STRING_BYTES) {
				return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, std::get<std::string>(payload).size());
			}
			return ok_status();
		case ValueType::IDENTIFIER:
			if (!holds<std::string>(payload, type)) {
				return make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
			}
			return validate_identifier(std::get<std::string>(payload));
		case ValueType::BYTES:
			if (!holds<ByteVector>(payload, type)) {
				return make_status(StatusCode::INVALID_VALUE, DiagnosticId::VALUE_OUT_OF_RANGE);
			}
			return BoundedBytes{ std::get<ByteVector>(payload) }.validate();
	}
	return make_status(StatusCode::INVALID_VALUE, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(type));
}

bool Value::operator<(const Value &p_other) const {
	if (type != p_other.type) {
		return static_cast<std::uint8_t>(type) < static_cast<std::uint8_t>(p_other.type);
	}
	// `std::variant` has a deterministic index/value ordering. The type check
	// above prevents a malformed mismatched payload from affecting ordering.
	return payload < p_other.payload;
}

Status LocalizedParameter::validate() const {
	Status status = validate_local_identifier(identifier);
	if (!status.ok()) return status;
	return value.validate();
}

Status FactPredicate::validate() const {
	Status status = validate_identifier(provider_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(fact_identifier);
	if (!status.ok()) return status;
	if (!is_known_comparison_operator(comparator)) {
		return make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(comparator));
	}
	return expected.validate();
}

bool FactPredicate::operator<(const FactPredicate &p_other) const {
	if (provider_identifier != p_other.provider_identifier) return identifier_less(provider_identifier, p_other.provider_identifier);
	if (fact_identifier != p_other.fact_identifier) return identifier_less(fact_identifier, p_other.fact_identifier);
	if (comparator != p_other.comparator) {
		return static_cast<std::uint8_t>(comparator) < static_cast<std::uint8_t>(p_other.comparator);
	}
	return expected < p_other.expected;
}

} // namespace lts
