#ifndef LEVEL_TASK_SYSTEM_CORE_VALUES_H
#define LEVEL_TASK_SYSTEM_CORE_VALUES_H

#include "core/lts_identifier.h"
#include "core/lts_limits.h"
#include "core/lts_status.h"

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

namespace lts {

// Closed value set for authored facts, filters, and localization parameters.
// There is deliberately no Object, pointer, callable, script, map, or
// floating-point alternative: values can be copied, bounded, and encoded
// identically by an engine adapter and a headless/server process.
enum class ValueType : std::uint8_t {
	NONE = 0,
	BOOLEAN = 1,
	INTEGER = 2,
	FIXED = 3,
	STRING = 4,
	IDENTIFIER = 5,
	BYTES = 6,
};

struct FixedPoint {
	std::int64_t raw = 0;

	static FixedPoint from_raw(std::int64_t p_raw) { return FixedPoint{ p_raw }; }
	static FixedPoint zero() { return FixedPoint{ 0 }; }

	bool operator==(const FixedPoint &p_other) const { return raw == p_other.raw; }
	bool operator!=(const FixedPoint &p_other) const { return !(*this == p_other); }
	bool operator<(const FixedPoint &p_other) const { return raw < p_other.raw; }
	bool operator<=(const FixedPoint &p_other) const { return raw <= p_other.raw; }
	bool operator>(const FixedPoint &p_other) const { return raw > p_other.raw; }
	bool operator>=(const FixedPoint &p_other) const { return raw >= p_other.raw; }
};

using Fixed = FixedPoint;
using ByteVector = std::vector<std::uint8_t>;

struct BoundedString {
	std::string value;

	Status validate(std::size_t p_limit = MAX_STRING_BYTES) const;
	bool operator==(const BoundedString &p_other) const { return value == p_other.value; }
	bool operator!=(const BoundedString &p_other) const { return !(*this == p_other); }
	bool operator<(const BoundedString &p_other) const { return value < p_other.value; }
};

struct BoundedBytes {
	ByteVector bytes;

	Status validate(std::size_t p_limit = MAX_VALUE_BYTES) const;
	bool operator==(const BoundedBytes &p_other) const { return bytes == p_other.bytes; }
	bool operator!=(const BoundedBytes &p_other) const { return !(*this == p_other); }
	bool operator<(const BoundedBytes &p_other) const { return bytes < p_other.bytes; }
};

struct Value {
	using Payload = std::variant<std::monostate, bool, std::int64_t, FixedPoint, std::string, ByteVector>;

	ValueType type = ValueType::NONE;
	Payload payload = std::monostate{};

	static Value none() { return Value{}; }
	static Value boolean(bool p_value) { return Value{ ValueType::BOOLEAN, p_value }; }
	static Value integer(std::int64_t p_value) { return Value{ ValueType::INTEGER, p_value }; }
	static Value fixed(FixedPoint p_value) { return Value{ ValueType::FIXED, p_value }; }
	static Value string(const std::string &p_value) { return Value{ ValueType::STRING, p_value }; }
	static Value identifier(const std::string &p_value) { return Value{ ValueType::IDENTIFIER, p_value }; }
	static Value bytes(const ByteVector &p_value) { return Value{ ValueType::BYTES, p_value }; }

	Status validate() const;
	bool is_none() const { return type == ValueType::NONE; }

	bool operator==(const Value &p_other) const { return type == p_other.type && payload == p_other.payload; }
	bool operator!=(const Value &p_other) const { return !(*this == p_other); }
	bool operator<(const Value &p_other) const;
};

// A localization key plus bounded substitution values. The key itself is a
// local canonical identifier because a project may choose any namespaced
// localization convention; the runtime still treats it as opaque text.
struct LocalizedParameter {
	std::string identifier;
	Value value;

	Status validate() const;
	bool operator==(const LocalizedParameter &p_other) const {
		return identifier == p_other.identifier && value == p_other.value;
	}
	bool operator!=(const LocalizedParameter &p_other) const { return !(*this == p_other); }
	bool operator<(const LocalizedParameter &p_other) const {
		if (identifier != p_other.identifier) return identifier_less(identifier, p_other.identifier);
		return value < p_other.value;
	}
};

enum class ComparisonOperator : std::uint8_t {
	EQUAL = 0,
	NOT_EQUAL = 1,
	LESS = 2,
	LESS_OR_EQUAL = 3,
	GREATER = 4,
	GREATER_OR_EQUAL = 5,
};

// Declarative fact/event filter shared by level availability, objective
// nodes, condition nodes, and conversation choice conditions.
struct FactPredicate {
	std::string provider_identifier;
	std::string fact_identifier;
	ComparisonOperator comparator = ComparisonOperator::EQUAL;
	Value expected;

	Status validate() const;
	bool operator==(const FactPredicate &p_other) const {
		return provider_identifier == p_other.provider_identifier &&
				fact_identifier == p_other.fact_identifier && comparator == p_other.comparator && expected == p_other.expected;
	}
	bool operator!=(const FactPredicate &p_other) const { return !(*this == p_other); }
	bool operator<(const FactPredicate &p_other) const;
};

bool is_known_value_type(ValueType p_type);
bool is_known_comparison_operator(ComparisonOperator p_operator);

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_VALUES_H
