#include "godot/lts_runtime_bridge.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace godot {

namespace {

using lts::ComparisonOperator;
using lts::ConversationChoiceDefinition;
using lts::ConversationDefinition;
using lts::ConversationFrame;
using lts::ConversationFrameKind;
using lts::ConversationInstance;
using lts::ConversationInstanceStatus;
using lts::ConversationStepDefinition;
using lts::ConversationStepKind;
using lts::Diagnostic;
using lts::DiagnosticId;
using lts::FactPredicate;
using lts::LocalizedParameter;
using lts::Status;
using lts::StatusCode;
using lts::TaskAdvanceResult;
using lts::TaskEvent;
using lts::TaskExternalRequest;
using lts::TaskExternalRequestKind;
using lts::TaskFact;
using lts::TaskFactSnapshot;
using lts::TaskGraphDefinition;
using lts::TaskGraphInstance;
using lts::TaskGraphInstanceStatus;
using lts::TaskNodeDefinition;
using lts::TaskNodeInstanceState;
using lts::TaskNodeKind;
using lts::TaskPortDefinition;
using lts::TaskPortDirection;
using lts::TaskRequestResolution;
using lts::TaskRuntimeLimits;
using lts::TaskStateChangeRecord;
using lts::TaskTraceKind;
using lts::TaskTraceRecord;
using lts::TaskTransitionRecord;
using lts::Value;
using lts::ValueType;

constexpr std::size_t MAX_BRIDGE_ARRAY = 1024;
constexpr std::size_t MAX_BRIDGE_TRACE = lts::MAX_TRACE_RECORDS;

Status invalid_payload(DiagnosticId p_diagnostic = DiagnosticId::GRAPH_PAYLOAD_INVALID,

		std::uint64_t p_detail = 0) {

	return lts::make_status(StatusCode::INVALID_ARGUMENT, p_diagnostic, p_detail);
}

Status missing_payload() {
	return lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
}

Variant field(const Dictionary &p_dictionary, const char *p_name) {
	return p_dictionary.get(StringName(p_name), Variant());
}

bool has_field(const Dictionary &p_dictionary, const char *p_name) {
	return p_dictionary.has(StringName(p_name));
}

String to_godot_string(const std::string &p_value) {
	return String(p_value.c_str());
}

Status read_string(const Variant &p_value, std::size_t p_limit, std::string &r_value,
		DiagnosticId p_diagnostic = DiagnosticId::GRAPH_PAYLOAD_INVALID) {
	if (p_value.get_type() != Variant::STRING && p_value.get_type() != Variant::STRING_NAME) {
		return invalid_payload(p_diagnostic);
	}
	String value;
	if (p_value.get_type() == Variant::STRING_NAME) {
		value = String(static_cast<StringName>(p_value));
	} else {
		value = static_cast<String>(p_value);
	}
	const CharString utf8 = value.utf8();
	const std::size_t length = static_cast<std::size_t>(utf8.length());
	if (length > p_limit) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, length);
	}
	r_value.assign(utf8.get_data(), length);
	return lts::ok_status();
}

Status read_required_string(const Dictionary &p_dictionary, const char *p_name,
		std::size_t p_limit, std::string &r_value,
		DiagnosticId p_diagnostic = DiagnosticId::GRAPH_PAYLOAD_INVALID) {
	if (!has_field(p_dictionary, p_name)) return missing_payload();
	return read_string(field(p_dictionary, p_name), p_limit, r_value, p_diagnostic);
}

Status read_optional_string(const Dictionary &p_dictionary, const char *p_name,
		std::size_t p_limit, std::string &r_value,
		DiagnosticId p_diagnostic = DiagnosticId::GRAPH_PAYLOAD_INVALID) {
	if (!has_field(p_dictionary, p_name)) return lts::ok_status();
	return read_string(field(p_dictionary, p_name), p_limit, r_value, p_diagnostic);
}

Status read_int(const Variant &p_value, std::int64_t &r_value) {
	if (p_value.get_type() != Variant::INT) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
	r_value = static_cast<std::int64_t>(p_value);
	return lts::ok_status();
}

Status read_required_int(const Dictionary &p_dictionary, const char *p_name, std::int64_t &r_value) {
	if (!has_field(p_dictionary, p_name)) return missing_payload();
	return read_int(field(p_dictionary, p_name), r_value);
}

Status read_optional_int(const Dictionary &p_dictionary, const char *p_name, std::int64_t p_default,
		std::int64_t &r_value) {
	if (!has_field(p_dictionary, p_name)) {
		r_value = p_default;
		return lts::ok_status();
	}
	return read_int(field(p_dictionary, p_name), r_value);
}

Status read_required_uint32(const Dictionary &p_dictionary, const char *p_name, std::uint32_t &r_value) {
	std::int64_t value = 0;
	Status status = read_required_int(p_dictionary, p_name, value);
	if (!status.ok()) return status;
	if (value < 0 || static_cast<std::uint64_t>(value) > std::numeric_limits<std::uint32_t>::max()) {
		return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE, value < 0 ? 0 : static_cast<std::uint64_t>(value));
	}
	r_value = static_cast<std::uint32_t>(value);
	return lts::ok_status();
}

Status read_optional_uint32(const Dictionary &p_dictionary, const char *p_name, std::uint32_t p_default,
		std::uint32_t &r_value) {
	std::int64_t value = 0;
	Status status = read_optional_int(p_dictionary, p_name, p_default, value);
	if (!status.ok()) return status;
	if (value < 0 || static_cast<std::uint64_t>(value) > std::numeric_limits<std::uint32_t>::max()) {
		return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE, value < 0 ? 0 : static_cast<std::uint64_t>(value));
	}
	r_value = static_cast<std::uint32_t>(value);
	return lts::ok_status();
}

Status read_optional_uint64(const Dictionary &p_dictionary, const char *p_name, std::uint64_t p_default,
		std::uint64_t &r_value) {
	std::int64_t value = 0;
	Status status = read_optional_int(p_dictionary, p_name,
			p_default > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())
					? std::numeric_limits<std::int64_t>::max()
					: static_cast<std::int64_t>(p_default),
			value);
	if (!status.ok()) return status;
	if (value < 0) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
	r_value = static_cast<std::uint64_t>(value);
	return lts::ok_status();
}

Status read_required_bool(const Dictionary &p_dictionary, const char *p_name, bool &r_value) {
	if (!has_field(p_dictionary, p_name)) return missing_payload();
	const Variant value = field(p_dictionary, p_name);
	if (value.get_type() != Variant::BOOL) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
	r_value = static_cast<bool>(value);
	return lts::ok_status();
}

Status read_optional_bool(const Dictionary &p_dictionary, const char *p_name, bool p_default, bool &r_value) {
	if (!has_field(p_dictionary, p_name)) {
		r_value = p_default;
		return lts::ok_status();
	}
	return read_required_bool(p_dictionary, p_name, r_value);
}

std::string lower_ascii(std::string p_value) {
	for (char &character : p_value) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
	return p_value;
}

Status read_enum_raw(const Variant &p_value, std::int64_t &r_value) {
	if (p_value.get_type() == Variant::INT) return read_int(p_value, r_value);
	std::string text;
	Status status = read_string(p_value, lts::MAX_IDENTIFIER_BYTES, text, DiagnosticId::INVALID_ENUM);
	if (!status.ok()) return status;
	text = lower_ascii(std::move(text));
	// The caller translates names; this helper only reserves the string path.
	if (text.empty()) return invalid_payload(DiagnosticId::INVALID_ENUM);
	r_value = -1;
	return lts::ok_status();
}

Status read_array(const Dictionary &p_dictionary, const char *p_name, Array &r_array,
		bool p_required = false, std::size_t p_limit = MAX_BRIDGE_ARRAY) {
	if (!has_field(p_dictionary, p_name)) {
		if (p_required) return missing_payload();
		r_array = Array();
		return lts::ok_status();
	}
	const Variant value = field(p_dictionary, p_name);
	if (value.get_type() != Variant::ARRAY) return invalid_payload(DiagnosticId::COUNT_LIMIT_EXCEEDED);
	r_array = static_cast<Array>(value);
	if (static_cast<std::size_t>(r_array.size()) > p_limit) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(r_array.size()));
	}
	return lts::ok_status();
}

Status read_string_array(const Dictionary &p_dictionary, const char *p_name, std::size_t p_limit,
		std::vector<std::string> &r_values, bool p_required = false) {
	if (!has_field(p_dictionary, p_name)) {
		if (p_required) return missing_payload();
		r_values.clear();
		return lts::ok_status();
	}
	const Variant value = field(p_dictionary, p_name);
	std::vector<std::string> values;
	if (value.get_type() == Variant::PACKED_STRING_ARRAY) {
		const PackedStringArray names = static_cast<PackedStringArray>(value);
		if (static_cast<std::size_t>(names.size()) > p_limit) {
			return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
					static_cast<std::uint64_t>(names.size()));
		}
		values.reserve(static_cast<std::size_t>(names.size()));
		for (int64_t index = 0; index < names.size(); ++index) {
			std::string name;
			Status status = read_string(names[index], lts::MAX_IDENTIFIER_BYTES, name);
			if (!status.ok()) return status;
			values.push_back(std::move(name));
		}
	} else if (value.get_type() == Variant::ARRAY) {
		const Array names = static_cast<Array>(value);
		if (static_cast<std::size_t>(names.size()) > p_limit) {
			return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
					static_cast<std::uint64_t>(names.size()));
		}
		values.reserve(static_cast<std::size_t>(names.size()));
		for (int64_t index = 0; index < names.size(); ++index) {
			std::string name;
			Status status = read_string(names[index], lts::MAX_IDENTIFIER_BYTES, name);
			if (!status.ok()) return status;
			values.push_back(std::move(name));
		}
	} else {
		return invalid_payload(DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	r_values = std::move(values);
	return lts::ok_status();
}

Status parse_value(const Variant &p_input, Value &r_value);

Status parse_value_field(const Dictionary &p_dictionary, const char *p_name, Value &r_value) {
	if (!has_field(p_dictionary, p_name)) return missing_payload();
	return parse_value(field(p_dictionary, p_name), r_value);
}

Status parse_value(const Variant &p_input, Value &r_value) {
	Value value;
	switch (p_input.get_type()) {
		case Variant::NIL:
			value = Value::none();
			break;
		case Variant::BOOL:
			value = Value::boolean(static_cast<bool>(p_input));
			break;
		case Variant::INT:
			value = Value::integer(static_cast<std::int64_t>(p_input));
			break;
		case Variant::STRING:
			{
				std::string text;
				Status status = read_string(p_input, lts::MAX_STRING_BYTES, text);
				if (!status.ok()) return status;
				value = Value::string(text);
			}
			break;
		case Variant::STRING_NAME:
			{
				std::string text;
				Status status = read_string(p_input, lts::MAX_IDENTIFIER_BYTES, text);
				if (!status.ok()) return status;
				value = Value::identifier(text);
			}
			break;
		case Variant::PACKED_BYTE_ARRAY:
			{
				const PackedByteArray bytes = static_cast<PackedByteArray>(p_input);
				if (static_cast<std::size_t>(bytes.size()) > lts::MAX_VALUE_BYTES) {
					return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED,
							static_cast<std::uint64_t>(bytes.size()));
				}
				lts::ByteVector native_bytes;
				native_bytes.reserve(static_cast<std::size_t>(bytes.size()));
				for (int64_t index = 0; index < bytes.size(); ++index) native_bytes.push_back(bytes[index]);
				value = Value::bytes(native_bytes);
			}
			break;
		case Variant::DICTIONARY:
			{
				const Dictionary dictionary = static_cast<Dictionary>(p_input);
				if (!has_field(dictionary, "type")) return invalid_payload(DiagnosticId::INVALID_ENUM);
				const Variant type_input = field(dictionary, "type");
				std::int64_t type_raw = -1;
				if (type_input.get_type() == Variant::INT) {
					type_raw = static_cast<std::int64_t>(type_input);
				} else {
					std::string type_name;
					Status status = read_string(type_input, lts::MAX_IDENTIFIER_BYTES, type_name, DiagnosticId::INVALID_ENUM);
					if (!status.ok()) return status;
					type_name = lower_ascii(std::move(type_name));
					if (type_name == "none") type_raw = 0;
					else if (type_name == "boolean" || type_name == "bool") type_raw = 1;
					else if (type_name == "integer" || type_name == "int") type_raw = 2;
					else if (type_name == "fixed") type_raw = 3;
					else if (type_name == "string") type_raw = 4;
					else if (type_name == "identifier" || type_name == "id") type_raw = 5;
					else if (type_name == "bytes" || type_name == "byte_vector") type_raw = 6;
				}
				if (type_raw < 0 || type_raw > static_cast<std::int64_t>(ValueType::BYTES)) {
					return invalid_payload(DiagnosticId::INVALID_ENUM, type_raw < 0 ? 0 : static_cast<std::uint64_t>(type_raw));
				}
				const char *payload_name = "value";
				switch (static_cast<ValueType>(type_raw)) {
					case ValueType::BOOLEAN: payload_name = "boolean_value"; break;
					case ValueType::INTEGER: payload_name = "integer_value"; break;
					case ValueType::FIXED: payload_name = "fixed_raw"; break;
					case ValueType::STRING: payload_name = "string_value"; break;
					case ValueType::IDENTIFIER: payload_name = "identifier_value"; break;
					case ValueType::BYTES: payload_name = "bytes_value"; break;
					case ValueType::NONE: payload_name = "value"; break;
				}
				const char *selected_name = has_field(dictionary, payload_name) ? payload_name : "value";
				const ValueType type = static_cast<ValueType>(type_raw);
				if (type == ValueType::NONE) {
					value = Value::none();
				} else if (!has_field(dictionary, selected_name)) {
					return missing_payload();
				} else {
					const Variant payload = field(dictionary, selected_name);
					switch (type) {
						case ValueType::BOOLEAN:
							if (payload.get_type() != Variant::BOOL) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
							value = Value::boolean(static_cast<bool>(payload));
							break;
						case ValueType::INTEGER:
							if (payload.get_type() != Variant::INT) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
							value = Value::integer(static_cast<std::int64_t>(payload));
							break;
						case ValueType::FIXED:
							if (payload.get_type() != Variant::INT) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
							value = Value::fixed(lts::FixedPoint::from_raw(static_cast<std::int64_t>(payload)));
							break;
						case ValueType::STRING:
							{
								std::string text;
								Status status = read_string(payload, lts::MAX_STRING_BYTES, text);
								if (!status.ok()) return status;
								value = Value::string(text);
							}
							break;
						case ValueType::IDENTIFIER:
							{
								std::string text;
								Status status = read_string(payload, lts::MAX_IDENTIFIER_BYTES, text);
								if (!status.ok()) return status;
								value = Value::identifier(text);
							}
							break;
						case ValueType::BYTES:
							if (payload.get_type() != Variant::PACKED_BYTE_ARRAY) return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
							{
								const PackedByteArray bytes = static_cast<PackedByteArray>(payload);
								if (static_cast<std::size_t>(bytes.size()) > lts::MAX_VALUE_BYTES) {
									return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED,
											static_cast<std::uint64_t>(bytes.size()));
								}
								lts::ByteVector native_bytes;
								native_bytes.reserve(static_cast<std::size_t>(bytes.size()));
								for (int64_t index = 0; index < bytes.size(); ++index) native_bytes.push_back(bytes[index]);
								value = Value::bytes(native_bytes);
							}
							break;
						case ValueType::NONE:
							value = Value::none();
							break;
					}
				}
			}
			break;
		default:
			return invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	Status status = value.validate();
	if (!status.ok()) return status;
	r_value = std::move(value);
	return lts::ok_status();
}

Status parse_predicate(const Dictionary &p_dictionary, FactPredicate &r_predicate) {
	FactPredicate predicate;
	Status status = read_required_string(p_dictionary, "provider_identifier", lts::MAX_IDENTIFIER_BYTES,
			predicate.provider_identifier);
	if (!status.ok() && has_field(p_dictionary, "provider")) {
		status = read_required_string(p_dictionary, "provider", lts::MAX_IDENTIFIER_BYTES, predicate.provider_identifier);
	}
	if (!status.ok()) return status;
	status = read_required_string(p_dictionary, "fact_identifier", lts::MAX_IDENTIFIER_BYTES, predicate.fact_identifier);
	if (!status.ok() && has_field(p_dictionary, "fact")) {
		status = read_required_string(p_dictionary, "fact", lts::MAX_IDENTIFIER_BYTES, predicate.fact_identifier);
	}
	if (!status.ok()) return status;
	std::int64_t comparator = 0;
	if (has_field(p_dictionary, "comparator")) {
		const Variant value = field(p_dictionary, "comparator");
		if (value.get_type() == Variant::INT) {
			comparator = static_cast<std::int64_t>(value);
		} else {
			std::string name;
			status = read_string(value, lts::MAX_IDENTIFIER_BYTES, name, DiagnosticId::INVALID_ENUM);
			if (!status.ok()) return status;
			name = lower_ascii(std::move(name));
			if (name == "equal" || name == "eq") comparator = 0;
			else if (name == "not_equal" || name == "not equal" || name == "ne") comparator = 1;
			else if (name == "less" || name == "lt") comparator = 2;
			else if (name == "less_or_equal" || name == "less or equal" || name == "le") comparator = 3;
			else if (name == "greater" || name == "gt") comparator = 4;
			else if (name == "greater_or_equal" || name == "greater or equal" || name == "ge") comparator = 5;
			else return invalid_payload(DiagnosticId::INVALID_ENUM);
		}
	}
	if (comparator < 0 || comparator > 5) return invalid_payload(DiagnosticId::INVALID_ENUM, comparator < 0 ? 0 : static_cast<std::uint64_t>(comparator));
	predicate.comparator = static_cast<ComparisonOperator>(comparator);
	if (!has_field(p_dictionary, "expected")) return missing_payload();
	status = parse_value_field(p_dictionary, "expected", predicate.expected);
	if (!status.ok()) return status;
	status = predicate.validate();
	if (!status.ok()) return status;
	r_predicate = std::move(predicate);
	return lts::ok_status();
}

Status parse_predicates(const Dictionary &p_dictionary, const char *p_name, std::size_t p_limit,
		std::vector<FactPredicate> &r_predicates) {
	Array values;
	Status status = read_array(p_dictionary, p_name, values, false, p_limit);
	if (!status.ok()) return status;
	std::vector<FactPredicate> predicates;
	predicates.reserve(static_cast<std::size_t>(values.size()));
	for (int64_t index = 0; index < values.size(); ++index) {
		if (values[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		FactPredicate predicate;
		status = parse_predicate(static_cast<Dictionary>(values[index]), predicate);
		if (!status.ok()) return status;
		predicates.push_back(std::move(predicate));
	}
	r_predicates = std::move(predicates);
	return lts::ok_status();
}

Status parse_value_array(const Dictionary &p_dictionary, const char *p_name, std::size_t p_limit,
		std::vector<Value> &r_values) {
	Array values;
	Status status = read_array(p_dictionary, p_name, values, false, p_limit);
	if (!status.ok()) return status;
	std::vector<Value> native_values;
	native_values.reserve(static_cast<std::size_t>(values.size()));
	for (int64_t index = 0; index < values.size(); ++index) {
		Value value;
		status = parse_value(values[index], value);
		if (!status.ok()) return status;
		native_values.push_back(std::move(value));
	}
	r_values = std::move(native_values);
	return lts::ok_status();
}

Status parse_parameter(const Dictionary &p_dictionary, LocalizedParameter &r_parameter) {
	LocalizedParameter parameter;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, parameter.identifier);
	if (!status.ok()) return status;
	if (!has_field(p_dictionary, "value")) return missing_payload();
	status = parse_value_field(p_dictionary, "value", parameter.value);
	if (!status.ok()) return status;
	status = parameter.validate();
	if (!status.ok()) return status;
	r_parameter = std::move(parameter);
	return lts::ok_status();
}

Status parse_parameters(const Dictionary &p_dictionary, const char *p_name, std::size_t p_limit,
		std::vector<LocalizedParameter> &r_parameters) {
	Array values;
	Status status = read_array(p_dictionary, p_name, values, false, p_limit);
	if (!status.ok()) return status;
	std::vector<LocalizedParameter> parameters;
	parameters.reserve(static_cast<std::size_t>(values.size()));
	for (int64_t index = 0; index < values.size(); ++index) {
		if (values[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		LocalizedParameter parameter;
		status = parse_parameter(static_cast<Dictionary>(values[index]), parameter);
		if (!status.ok()) return status;
		parameters.push_back(std::move(parameter));
	}
	r_parameters = std::move(parameters);
	return lts::ok_status();
}

Status parse_port(const Dictionary &p_dictionary, TaskPortDefinition &r_port) {
	TaskPortDefinition port;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, port.identifier);
	if (!status.ok()) return status;
	std::int64_t direction = 1;
	if (has_field(p_dictionary, "direction")) {
		const Variant value = field(p_dictionary, "direction");
		if (value.get_type() == Variant::INT) direction = static_cast<std::int64_t>(value) + 1;
		else {
			std::string name;
			status = read_string(value, lts::MAX_IDENTIFIER_BYTES, name, DiagnosticId::INVALID_ENUM);
			if (!status.ok()) return status;
			name = lower_ascii(std::move(name));
			if (name == "input" || name == "in") direction = 1;
			else if (name == "output" || name == "out") direction = 2;
			else return invalid_payload(DiagnosticId::INVALID_ENUM);
		}
	}
	if (direction < 1 || direction > 2) return invalid_payload(DiagnosticId::INVALID_ENUM);
	port.direction = static_cast<TaskPortDirection>(direction);
	std::int64_t value_type = 0;
	if (has_field(p_dictionary, "value_type")) {
		const Variant value = field(p_dictionary, "value_type");
		if (value.get_type() == Variant::INT) value_type = static_cast<std::int64_t>(value);
		else {
			std::string name;
			status = read_string(value, lts::MAX_IDENTIFIER_BYTES, name, DiagnosticId::INVALID_ENUM);
			if (!status.ok()) return status;
			name = lower_ascii(std::move(name));
			if (name == "none") value_type = 0;
			else if (name == "boolean" || name == "bool") value_type = 1;
			else if (name == "integer" || name == "int") value_type = 2;
			else if (name == "fixed") value_type = 3;
			else if (name == "string") value_type = 4;
			else if (name == "identifier" || name == "id") value_type = 5;
			else if (name == "bytes") value_type = 6;
			else return invalid_payload(DiagnosticId::INVALID_ENUM);
		}
	}
	if (value_type < 0 || value_type > 6) return invalid_payload(DiagnosticId::INVALID_ENUM);
	port.value_type = static_cast<ValueType>(value_type);
	status = read_optional_bool(p_dictionary, "required", false, port.required);
	if (!status.ok()) return status;
	status = port.validate();
	if (!status.ok()) return status;
	r_port = std::move(port);
	return lts::ok_status();
}

Status parse_task_node(const Dictionary &p_dictionary, TaskNodeDefinition &r_node) {
	TaskNodeDefinition node;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, node.identifier);
	if (!status.ok()) return status;
	std::int64_t schema = 1;
	status = read_optional_int(p_dictionary, "schema_version", 1, schema);
	if (!status.ok() || schema <= 0 || schema > std::numeric_limits<std::uint16_t>::max()) return status.ok() ? invalid_payload(DiagnosticId::SCHEMA_VERSION_UNSUPPORTED) : status;
	node.schema_version = static_cast<std::uint16_t>(schema);
	std::int64_t kind = 0;
	if (has_field(p_dictionary, "kind")) {
		const Variant value = field(p_dictionary, "kind");
		if (value.get_type() == Variant::INT) kind = static_cast<std::int64_t>(value) + 1;
		else {
			std::string name;
			status = read_string(value, lts::MAX_IDENTIFIER_BYTES, name, DiagnosticId::INVALID_ENUM);
			if (!status.ok()) return status;
			name = lower_ascii(std::move(name));
			if (name == "entry") kind = 1;
			else if (name == "objective") kind = 2;
			else if (name == "condition") kind = 3;
			else if (name == "all_gate" || name == "all gate") kind = 4;
			else if (name == "any_gate" || name == "any gate") kind = 5;
			else if (name == "external_action" || name == "external action") kind = 6;
			else if (name == "conversation") kind = 7;
			else if (name == "subgraph") kind = 8;
			else if (name == "reward_request" || name == "reward request") kind = 9;
			else if (name == "success" || name == "success_terminal") kind = 10;
			else if (name == "failure" || name == "failure_terminal") kind = 11;
			else if (name == "cancelled" || name == "cancelled_terminal") kind = 12;
			else return invalid_payload(DiagnosticId::INVALID_ENUM);
		}
	}
	if (kind < 1 || kind > 12) return invalid_payload(DiagnosticId::INVALID_ENUM);
	node.kind = static_cast<TaskNodeKind>(kind);
	Array ports;
	status = read_array(p_dictionary, "ports", ports, false, lts::MAX_PORTS_PER_TASK_NODE);
	if (!status.ok()) return status;
	node.ports.reserve(static_cast<std::size_t>(ports.size()));
	for (int64_t index = 0; index < ports.size(); ++index) {
		if (ports[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PORT_INVALID, index);
		TaskPortDefinition port;
		status = parse_port(static_cast<Dictionary>(ports[index]), port);
		if (!status.ok()) return status;
		node.ports.push_back(std::move(port));
	}
	status = read_optional_string(p_dictionary, "provider_identifier", lts::MAX_IDENTIFIER_BYTES, node.provider_identifier);
	if (!status.ok()) return status;
	std::int64_t target = 1;
	if (has_field(p_dictionary, "objective_target")) status = read_optional_int(p_dictionary, "objective_target", 1, target);
	else if (has_field(p_dictionary, "target")) status = read_optional_int(p_dictionary, "target", 1, target);
	if (!status.ok() || target < 0 || static_cast<std::uint64_t>(target) > lts::MAX_OBJECTIVE_TARGET) return status.ok() ? invalid_payload(DiagnosticId::VALUE_OUT_OF_RANGE) : status;
	node.objective_target = static_cast<std::uint32_t>(target);
	status = parse_predicates(p_dictionary, "filters", lts::MAX_NODE_FILTERS, node.filters);
	if (!status.ok()) return status;
	status = parse_value_array(p_dictionary, "parameters", lts::MAX_NODE_PARAMETERS, node.parameters);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "conversation_identifier", lts::MAX_IDENTIFIER_BYTES, node.conversation_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "conversation_entry_label", lts::MAX_IDENTIFIER_BYTES, node.conversation_entry_label);
	if (!status.ok()) return status;
	status = read_string_array(p_dictionary, "accepted_outcomes", lts::MAX_TERMINAL_OUTCOMES, node.accepted_outcomes);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "subgraph_identifier", lts::MAX_IDENTIFIER_BYTES, node.subgraph_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "outcome_identifier", lts::MAX_IDENTIFIER_BYTES, node.outcome_identifier);
	if (!status.ok()) return status;
	status = node.validate();
	if (!status.ok()) return status;
	r_node = std::move(node);
	return lts::ok_status();
}

Status parse_task_edge(const Dictionary &p_dictionary, lts::TaskEdgeDefinition &r_edge) {
	lts::TaskEdgeDefinition edge;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, edge.identifier);
	if (!status.ok()) return status;
	std::int64_t schema = 1;
	status = read_optional_int(p_dictionary, "schema_version", 1, schema);
	if (!status.ok() || schema <= 0 || schema > std::numeric_limits<std::uint16_t>::max()) return status.ok() ? invalid_payload(DiagnosticId::SCHEMA_VERSION_UNSUPPORTED) : status;
	edge.schema_version = static_cast<std::uint16_t>(schema);
	status = read_required_string(p_dictionary, "from_node_identifier", lts::MAX_IDENTIFIER_BYTES, edge.from_node_identifier);
	if (!status.ok() && has_field(p_dictionary, "from_node")) status = read_required_string(p_dictionary, "from_node", lts::MAX_IDENTIFIER_BYTES, edge.from_node_identifier);
	if (!status.ok()) return status;
	status = read_required_string(p_dictionary, "from_port_identifier", lts::MAX_IDENTIFIER_BYTES, edge.from_port_identifier);
	if (!status.ok() && has_field(p_dictionary, "from_port")) status = read_required_string(p_dictionary, "from_port", lts::MAX_IDENTIFIER_BYTES, edge.from_port_identifier);
	if (!status.ok()) return status;
	status = read_required_string(p_dictionary, "to_node_identifier", lts::MAX_IDENTIFIER_BYTES, edge.to_node_identifier);
	if (!status.ok() && has_field(p_dictionary, "to_node")) status = read_required_string(p_dictionary, "to_node", lts::MAX_IDENTIFIER_BYTES, edge.to_node_identifier);
	if (!status.ok()) return status;
	status = read_required_string(p_dictionary, "to_port_identifier", lts::MAX_IDENTIFIER_BYTES, edge.to_port_identifier);
	if (!status.ok() && has_field(p_dictionary, "to_port")) status = read_required_string(p_dictionary, "to_port", lts::MAX_IDENTIFIER_BYTES, edge.to_port_identifier);
	if (!status.ok()) return status;
	status = edge.validate();
	if (!status.ok()) return status;
	r_edge = std::move(edge);
	return lts::ok_status();
}

Status parse_task_graph(const Dictionary &p_dictionary, TaskGraphDefinition &r_definition) {
	TaskGraphDefinition definition;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, definition.identifier);
	if (!status.ok()) return status;
	std::int64_t schema = 1;
	status = read_optional_int(p_dictionary, "schema_version", 1, schema);
	if (!status.ok() || schema <= 0 || schema > std::numeric_limits<std::uint16_t>::max()) return status.ok() ? invalid_payload(DiagnosticId::SCHEMA_VERSION_UNSUPPORTED) : status;
	definition.schema_version = static_cast<std::uint16_t>(schema);
	status = read_required_string(p_dictionary, "entry_node_identifier", lts::MAX_IDENTIFIER_BYTES, definition.entry_node_identifier);
	if (!status.ok() && has_field(p_dictionary, "entry_node")) status = read_required_string(p_dictionary, "entry_node", lts::MAX_IDENTIFIER_BYTES, definition.entry_node_identifier);
	if (!status.ok()) return status;
	status = read_string_array(p_dictionary, "terminal_outcomes", lts::MAX_TERMINAL_OUTCOMES, definition.terminal_outcomes, true);
	if (!status.ok()) return status;
	Array nodes;
	status = read_array(p_dictionary, "nodes", nodes, true, lts::MAX_NODES_PER_TASK_GRAPH);
	if (!status.ok()) return status;
	definition.nodes.reserve(static_cast<std::size_t>(nodes.size()));
	for (int64_t index = 0; index < nodes.size(); ++index) {
		if (nodes[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		TaskNodeDefinition node;
		status = parse_task_node(static_cast<Dictionary>(nodes[index]), node);
		if (!status.ok()) return status;
		definition.nodes.push_back(std::move(node));
	}
	Array edges;
	status = read_array(p_dictionary, "edges", edges, false, lts::MAX_EDGES_PER_TASK_GRAPH);
	if (!status.ok()) return status;
	definition.edges.reserve(static_cast<std::size_t>(edges.size()));
	for (int64_t index = 0; index < edges.size(); ++index) {
		if (edges[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		lts::TaskEdgeDefinition edge;
		status = parse_task_edge(static_cast<Dictionary>(edges[index]), edge);
		if (!status.ok()) return status;
		definition.edges.push_back(std::move(edge));
	}
	status = read_optional_uint32(p_dictionary, "max_transitions_per_advance",
			lts::MAX_TRANSITIONS_PER_ADVANCE, definition.max_transitions_per_advance);
	if (!status.ok()) return status;
	status = definition.validate_and_canonicalize();
	if (!status.ok()) return status;
	r_definition = std::move(definition);
	return lts::ok_status();
}

Status parse_choice(const Dictionary &p_dictionary, ConversationChoiceDefinition &r_choice) {
	ConversationChoiceDefinition choice;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, choice.identifier);
	if (!status.ok()) return status;
	status = read_required_string(p_dictionary, "label_key", lts::MAX_LOCALIZATION_KEY_BYTES, choice.label_key);
	if (!status.ok()) return status;
	status = read_required_string(p_dictionary, "target_step_identifier", lts::MAX_IDENTIFIER_BYTES, choice.target_step_identifier);
	if (!status.ok() && has_field(p_dictionary, "target")) status = read_required_string(p_dictionary, "target", lts::MAX_IDENTIFIER_BYTES, choice.target_step_identifier);
	if (!status.ok()) return status;
	status = parse_predicates(p_dictionary, "conditions", lts::MAX_CHOICE_CONDITIONS, choice.conditions);
	if (!status.ok()) return status;
	status = choice.validate();
	if (!status.ok()) return status;
	r_choice = std::move(choice);
	return lts::ok_status();
}

Status parse_conversation_step(const Dictionary &p_dictionary, ConversationStepDefinition &r_step) {
	ConversationStepDefinition step;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, step.identifier);
	if (!status.ok()) return status;
	std::int64_t kind = 0;
	if (has_field(p_dictionary, "kind")) {
		const Variant value = field(p_dictionary, "kind");
		if (value.get_type() == Variant::INT) kind = static_cast<std::int64_t>(value) + 1;
		else {
			std::string name;
			status = read_string(value, lts::MAX_IDENTIFIER_BYTES, name, DiagnosticId::INVALID_ENUM);
			if (!status.ok()) return status;
			name = lower_ascii(std::move(name));
			if (name == "line") kind = 1;
			else if (name == "choice") kind = 2;
			else if (name == "condition") kind = 3;
			else if (name == "external_action" || name == "external action" || name == "action") kind = 4;
			else if (name == "jump") kind = 5;
			else if (name == "outcome" || name == "terminal") kind = 6;
			else return invalid_payload(DiagnosticId::INVALID_ENUM);
		}
	}
	if (kind < 1 || kind > 6) return invalid_payload(DiagnosticId::INVALID_ENUM);
	step.kind = static_cast<ConversationStepKind>(kind);
	status = read_optional_string(p_dictionary, "speaker_identifier", lts::MAX_IDENTIFIER_BYTES, step.speaker_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "line_key", lts::MAX_LOCALIZATION_KEY_BYTES, step.line_key);
	if (!status.ok()) return status;
	status = parse_parameters(p_dictionary, "parameters", lts::MAX_LINE_PARAMETERS, step.parameters);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "next_step_identifier", lts::MAX_IDENTIFIER_BYTES, step.next_step_identifier);
	if (!status.ok() && has_field(p_dictionary, "next")) status = read_optional_string(p_dictionary, "next", lts::MAX_IDENTIFIER_BYTES, step.next_step_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "provider_identifier", lts::MAX_IDENTIFIER_BYTES, step.provider_identifier);
	if (!status.ok()) return status;
	status = parse_predicates(p_dictionary, "conditions", lts::MAX_CHOICE_CONDITIONS, step.conditions);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "true_step_identifier", lts::MAX_IDENTIFIER_BYTES, step.true_step_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "false_step_identifier", lts::MAX_IDENTIFIER_BYTES, step.false_step_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "success_step_identifier", lts::MAX_IDENTIFIER_BYTES, step.success_step_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "failure_step_identifier", lts::MAX_IDENTIFIER_BYTES, step.failure_step_identifier);
	if (!status.ok()) return status;
	Array choices;
	status = read_array(p_dictionary, "choices", choices, false, lts::MAX_CHOICES_PER_CONVERSATION_STEP);
	if (!status.ok()) return status;
	step.choices.reserve(static_cast<std::size_t>(choices.size()));
	for (int64_t index = 0; index < choices.size(); ++index) {
		if (choices[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::CONVERSATION_CHOICE_INVALID, index);
		ConversationChoiceDefinition choice;
		status = parse_choice(static_cast<Dictionary>(choices[index]), choice);
		if (!status.ok()) return status;
		step.choices.push_back(std::move(choice));
	}
	status = read_optional_string(p_dictionary, "target_step_identifier", lts::MAX_IDENTIFIER_BYTES, step.target_step_identifier);
	if (!status.ok() && has_field(p_dictionary, "target")) status = read_optional_string(p_dictionary, "target", lts::MAX_IDENTIFIER_BYTES, step.target_step_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "outcome_identifier", lts::MAX_IDENTIFIER_BYTES, step.outcome_identifier);
	if (!status.ok()) return status;
	status = step.validate();
	if (!status.ok()) return status;
	r_step = std::move(step);
	return lts::ok_status();
}

Status parse_conversation(const Dictionary &p_dictionary, ConversationDefinition &r_definition) {
	ConversationDefinition definition;
	Status status = read_required_string(p_dictionary, "identifier", lts::MAX_IDENTIFIER_BYTES, definition.identifier);
	if (!status.ok()) return status;
	std::int64_t schema = 1;
	status = read_optional_int(p_dictionary, "schema_version", 1, schema);
	if (!status.ok() || schema <= 0 || schema > std::numeric_limits<std::uint16_t>::max()) return status.ok() ? invalid_payload(DiagnosticId::SCHEMA_VERSION_UNSUPPORTED) : status;
	definition.schema_version = static_cast<std::uint16_t>(schema);
	status = read_required_string(p_dictionary, "entry_label", lts::MAX_IDENTIFIER_BYTES, definition.entry_label);
	if (!status.ok()) return status;
	status = read_string_array(p_dictionary, "speaker_identifiers", lts::MAX_SPEAKERS_PER_CONVERSATION, definition.speaker_identifiers, false);
	if (!status.ok()) return status;
	status = read_string_array(p_dictionary, "terminal_outcomes", lts::MAX_TERMINAL_OUTCOMES, definition.terminal_outcomes, true);
	if (!status.ok()) return status;
	Array steps;
	status = read_array(p_dictionary, "steps", steps, true, lts::MAX_STEPS_PER_CONVERSATION);
	if (!status.ok()) return status;
	definition.steps.reserve(static_cast<std::size_t>(steps.size()));
	for (int64_t index = 0; index < steps.size(); ++index) {
		if (steps[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		ConversationStepDefinition step;
		status = parse_conversation_step(static_cast<Dictionary>(steps[index]), step);
		if (!status.ok()) return status;
		definition.steps.push_back(std::move(step));
	}
	status = read_optional_uint32(p_dictionary, "max_steps_per_advance", lts::MAX_CONVERSATION_STEPS_PER_ADVANCE,
			definition.max_steps_per_advance);
	if (!status.ok()) return status;
	status = read_optional_uint32(p_dictionary, "max_jumps_per_advance", lts::MAX_JUMPS_PER_ADVANCE,
			definition.max_jumps_per_advance);
	if (!status.ok()) return status;
	status = definition.validate_and_canonicalize();
	if (!status.ok()) return status;
	r_definition = std::move(definition);
	return lts::ok_status();
}

Status parse_facts(const Dictionary &p_input, const std::string &p_expected_scope,
		TaskFactSnapshot &r_task_facts, lts::ConversationFactSnapshot &r_conversation_facts) {
	TaskFactSnapshot task_facts;
	if (!p_expected_scope.empty()) {
		Status status = task_facts.set_scope_key(p_expected_scope);
		if (!status.ok()) return status;
	}
	lts::ConversationFactSnapshot conversation_facts;
	Variant source;
	if (has_field(p_input, "facts")) source = field(p_input, "facts");
	else if (has_field(p_input, "values")) source = field(p_input, "values");
	else if (has_field(p_input, "provider_identifier") || has_field(p_input, "provider")) source = Variant(p_input);
	else {
		r_task_facts = std::move(task_facts);
		r_conversation_facts = std::move(conversation_facts);
		return lts::ok_status();
	}
	std::vector<Dictionary> records;
	if (source.get_type() == Variant::ARRAY) {
		const Array values = static_cast<Array>(source);
		if (static_cast<std::size_t>(values.size()) > lts::MAX_FACTS_PER_SNAPSHOT) {
			return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
					static_cast<std::uint64_t>(values.size()));
		}
		for (int64_t index = 0; index < values.size(); ++index) {
			if (values[index].get_type() != Variant::DICTIONARY) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
			records.push_back(static_cast<Dictionary>(values[index]));
		}
	} else if (source.get_type() == Variant::DICTIONARY) {
		const Dictionary values = static_cast<Dictionary>(source);
		if (has_field(values, "provider_identifier") || has_field(values, "provider")) {
			records.push_back(values);
		} else {
			const Array keys = values.keys();
			if (static_cast<std::size_t>(keys.size()) > lts::MAX_FACTS_PER_SNAPSHOT) {
				return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
						static_cast<std::uint64_t>(keys.size()));
			}
			std::vector<std::pair<std::string, Variant>> entries;
			entries.reserve(static_cast<std::size_t>(keys.size()));
			for (int64_t index = 0; index < keys.size(); ++index) {
				std::string key;
				Status status = read_string(keys[index], lts::MAX_IDENTIFIER_BYTES * 2, key);
				if (!status.ok()) return status;
				entries.emplace_back(std::move(key), values.get(keys[index], Variant()));
			}
			std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
			for (const auto &entry : entries) {
				const std::size_t separator = entry.first.find_first_of("/|");
				if (separator == std::string::npos || separator == 0 || separator + 1 >= entry.first.size()) return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID);
				Dictionary record;
				record["provider_identifier"] = String(entry.first.substr(0, separator).c_str());
				record["fact_identifier"] = String(entry.first.substr(separator + 1).c_str());
				record["value"] = entry.second;
				records.push_back(std::move(record));
			}
		}
	} else {
		return invalid_payload(DiagnosticId::GRAPH_PAYLOAD_INVALID);
	}
	if (records.size() > lts::MAX_FACTS_PER_SNAPSHOT) return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, records.size());
	for (const Dictionary &record : records) {
		std::string provider;
		Status status = read_required_string(record, "provider_identifier", lts::MAX_IDENTIFIER_BYTES, provider);
		if (!status.ok() && has_field(record, "provider")) status = read_required_string(record, "provider", lts::MAX_IDENTIFIER_BYTES, provider);
		if (!status.ok()) return status;
		std::string fact;
		status = read_required_string(record, "fact_identifier", lts::MAX_IDENTIFIER_BYTES, fact);
		if (!status.ok() && has_field(record, "fact")) status = read_required_string(record, "fact", lts::MAX_IDENTIFIER_BYTES, fact);
		if (!status.ok()) return status;
		if (!has_field(record, "value")) return missing_payload();
		Value value;
		status = parse_value(field(record, "value"), value);
		if (!status.ok()) return status;
		TaskFact task_fact{ provider, fact, value };
		status = task_facts.add(task_fact);
		if (!status.ok()) return status;
		lts::ConversationFact conversation_fact{ provider, fact, value };
		status = conversation_facts.add(conversation_fact);
		if (!status.ok()) return status;
	}
	r_task_facts = std::move(task_facts);
	r_conversation_facts = std::move(conversation_facts);
	return lts::ok_status();
}

Status parse_task_event(const Dictionary &p_dictionary, const std::string &p_default_scope, TaskEvent &r_event) {
	TaskEvent event;
	Status status = read_required_string(p_dictionary, "provider_identifier", lts::MAX_IDENTIFIER_BYTES, event.provider_identifier);
	if (!status.ok() && has_field(p_dictionary, "provider")) status = read_required_string(p_dictionary, "provider", lts::MAX_IDENTIFIER_BYTES, event.provider_identifier);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "event_identifier", lts::MAX_IDENTIFIER_BYTES, event.event_identifier);
	if (!status.ok() && has_field(p_dictionary, "event")) status = read_optional_string(p_dictionary, "event", lts::MAX_IDENTIFIER_BYTES, event.event_identifier);
	if (!status.ok()) return status;
	status = read_optional_uint64(p_dictionary, "sequence", 0, event.sequence);
	if (!status.ok()) return status;
	status = read_optional_string(p_dictionary, "scope_key", lts::MAX_IDENTIFIER_BYTES, event.scope_key);
	if (!status.ok() && has_field(p_dictionary, "scope_identifier")) status = read_optional_string(p_dictionary, "scope_identifier", lts::MAX_IDENTIFIER_BYTES, event.scope_key);
	if (!status.ok()) return status;
	if (event.scope_key.empty()) event.scope_key = p_default_scope;
	if (has_field(p_dictionary, "value")) {
		status = parse_value(field(p_dictionary, "value"), event.value);
		if (!status.ok()) return status;
	}
	status = read_optional_uint32(p_dictionary, "amount", 1, event.amount);
	if (!status.ok()) return status;
	status = parse_predicates(p_dictionary, "filters", lts::MAX_EVENT_FILTERS, event.filters);
	if (!status.ok()) return status;
	status = event.validate();
	if (!status.ok()) return status;
	r_event = std::move(event);
	return lts::ok_status();
}

const char *status_code_name(StatusCode p_code) {
	switch (p_code) {
		case StatusCode::OK: return "ok";
		case StatusCode::INVALID_ARGUMENT: return "invalid_argument";
		case StatusCode::NOT_FOUND: return "not_found";
		case StatusCode::ALREADY_EXISTS: return "already_exists";
		case StatusCode::OUT_OF_BOUNDS: return "out_of_bounds";
		case StatusCode::ARITHMETIC_ERROR: return "arithmetic_error";
		case StatusCode::CAPACITY_EXCEEDED: return "capacity_exceeded";
		case StatusCode::NOT_SUPPORTED: return "not_supported";
		case StatusCode::INTERNAL_ERROR: return "internal_error";
		case StatusCode::INVALID_IDENTIFIER: return "invalid_identifier";
		case StatusCode::DUPLICATE_DEFINITION: return "duplicate_definition";
		case StatusCode::UNKNOWN_DEFINITION: return "unknown_definition";
		case StatusCode::INVALID_REFERENCE: return "invalid_reference";
		case StatusCode::SCHEMA_MISMATCH: return "schema_mismatch";
		case StatusCode::CATALOG_SEALED: return "catalog_sealed";
		case StatusCode::CATALOG_NOT_SEALED: return "catalog_not_sealed";
		case StatusCode::INCOMPATIBLE_DEFINITION: return "incompatible_definition";
		case StatusCode::INVALID_DEFINITION: return "invalid_definition";
		case StatusCode::MANIFEST_MISMATCH: return "manifest_mismatch";
		case StatusCode::INVALID_ENUM: return "invalid_enum";
		case StatusCode::VALUE_OUT_OF_RANGE: return "value_out_of_range";
		case StatusCode::INVALID_VALUE: return "invalid_value";
		case StatusCode::GRAPH_INVALID: return "graph_invalid";
		case StatusCode::CONVERSATION_INVALID: return "conversation_invalid";
		case StatusCode::PROVIDER_INVALID: return "provider_invalid";
		case StatusCode::ANCHOR_INVALID: return "anchor_invalid";
		case StatusCode::EXIT_INVALID: return "exit_invalid";
	}
	return "unknown";
}

const char *diagnostic_name(DiagnosticId p_diagnostic) {
	switch (p_diagnostic) {
		case DiagnosticId::NONE: return "none";
		case DiagnosticId::IDENTIFIER_EMPTY: return "identifier_empty";
		case DiagnosticId::IDENTIFIER_BAD_CHARACTER: return "identifier_bad_character";
		case DiagnosticId::IDENTIFIER_NOT_NAMESPACED: return "identifier_not_namespaced";
		case DiagnosticId::IDENTIFIER_TOO_LONG: return "identifier_too_long";
		case DiagnosticId::IDENTIFIER_TOO_MANY_SEGMENTS: return "identifier_too_many_segments";
		case DiagnosticId::IDENTIFIER_SEGMENT_TOO_LONG: return "identifier_segment_too_long";
		case DiagnosticId::SCHEMA_VERSION_UNSUPPORTED: return "schema_version_unsupported";
		case DiagnosticId::COUNT_LIMIT_EXCEEDED: return "count_limit_exceeded";
		case DiagnosticId::BYTE_LIMIT_EXCEEDED: return "byte_limit_exceeded";
		case DiagnosticId::VALUE_OUT_OF_RANGE: return "value_out_of_range";
		case DiagnosticId::BOUNDS_INVERTED: return "bounds_inverted";
		case DiagnosticId::INVALID_ENUM: return "invalid_enum";
		case DiagnosticId::VALUE_NOT_REPRESENTABLE: return "value_not_representable";
		case DiagnosticId::DEFINITION_DUPLICATE: return "definition_duplicate";
		case DiagnosticId::DEFINITION_UNKNOWN_REFERENCE: return "definition_unknown_reference";
		case DiagnosticId::CANONICAL_ORDER_VIOLATION: return "canonical_order_violation";
		case DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS: return "manifest_fingerprint_differs";
		case DiagnosticId::PROTOCOL_VERSION_DIFFERS: return "protocol_version_differs";
		case DiagnosticId::TRUNCATED_PAYLOAD: return "truncated_payload";
		case DiagnosticId::GRAPH_IDENTIFIER_INVALID: return "graph_identifier_invalid";
		case DiagnosticId::GRAPH_ENTRY_INVALID: return "graph_entry_invalid";
		case DiagnosticId::GRAPH_NODE_LIMIT: return "graph_node_limit";
		case DiagnosticId::GRAPH_EDGE_LIMIT: return "graph_edge_limit";
		case DiagnosticId::GRAPH_PORT_LIMIT: return "graph_port_limit";
		case DiagnosticId::GRAPH_NODE_DUPLICATE: return "graph_node_duplicate";
		case DiagnosticId::GRAPH_EDGE_DUPLICATE: return "graph_edge_duplicate";
		case DiagnosticId::GRAPH_NODE_REFERENCE_INVALID: return "graph_node_reference_invalid";
		case DiagnosticId::GRAPH_PORT_INVALID: return "graph_port_invalid";
		case DiagnosticId::GRAPH_OUTCOME_INVALID: return "graph_outcome_invalid";
		case DiagnosticId::GRAPH_PAYLOAD_INVALID: return "graph_payload_invalid";
		case DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID: return "level_scene_reference_invalid";
		case DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID: return "level_entry_graph_invalid";
		case DiagnosticId::LEVEL_ANCHOR_INVALID: return "level_anchor_invalid";
		case DiagnosticId::LEVEL_EXIT_INVALID: return "level_exit_invalid";
		case DiagnosticId::LEVEL_AVAILABILITY_INVALID: return "level_availability_invalid";
		case DiagnosticId::CONVERSATION_ENTRY_INVALID: return "conversation_entry_invalid";
		case DiagnosticId::CONVERSATION_STEP_LIMIT: return "conversation_step_limit";
		case DiagnosticId::CONVERSATION_STEP_DUPLICATE: return "conversation_step_duplicate";
		case DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID: return "conversation_step_reference_invalid";
		case DiagnosticId::CONVERSATION_SPEAKER_INVALID: return "conversation_speaker_invalid";
		case DiagnosticId::CONVERSATION_LINE_INVALID: return "conversation_line_invalid";
		case DiagnosticId::CONVERSATION_CHOICE_INVALID: return "conversation_choice_invalid";
		case DiagnosticId::CONVERSATION_CHOICE_LIMIT: return "conversation_choice_limit";
		case DiagnosticId::CONVERSATION_OUTCOME_INVALID: return "conversation_outcome_invalid";
		case DiagnosticId::PROVIDER_IDENTIFIER_INVALID: return "provider_identifier_invalid";
		case DiagnosticId::PROVIDER_KIND_INVALID: return "provider_kind_invalid";
		case DiagnosticId::PROVIDER_PAYLOAD_LIMIT: return "provider_payload_limit";
	}
	return "unknown";
}

const char *value_type_name(ValueType p_type) {
	switch (p_type) {
		case ValueType::NONE: return "none";
		case ValueType::BOOLEAN: return "boolean";
		case ValueType::INTEGER: return "integer";
		case ValueType::FIXED: return "fixed";
		case ValueType::STRING: return "string";
		case ValueType::IDENTIFIER: return "identifier";
		case ValueType::BYTES: return "bytes";
	}
	return "unknown";
}

const char *task_status_name(TaskGraphInstanceStatus p_status) {
	switch (p_status) {
		case TaskGraphInstanceStatus::INVALID: return "invalid";
		case TaskGraphInstanceStatus::RUNNING: return "running";
		case TaskGraphInstanceStatus::SUCCEEDED: return "succeeded";
		case TaskGraphInstanceStatus::FAILED: return "failed";
		case TaskGraphInstanceStatus::CANCELLED: return "cancelled";
		case TaskGraphInstanceStatus::STALLED: return "stalled";
	}
	return "unknown";
}

const char *node_state_name(TaskNodeInstanceState p_state) {
	switch (p_state) {
		case TaskNodeInstanceState::INACTIVE: return "inactive";
		case TaskNodeInstanceState::ACTIVE: return "active";
		case TaskNodeInstanceState::PENDING: return "pending";
		case TaskNodeInstanceState::COMPLETED: return "completed";
		case TaskNodeInstanceState::FAILED: return "failed";
	}
	return "unknown";
}

const char *request_kind_name(TaskExternalRequestKind p_kind) {
	switch (p_kind) {
		case TaskExternalRequestKind::ACTION: return "action";
		case TaskExternalRequestKind::REWARD: return "reward";
		case TaskExternalRequestKind::CONVERSATION: return "conversation";
		case TaskExternalRequestKind::LEVEL_TRANSITION: return "level_transition";
	}
	return "unknown";
}

const char *resolution_name(TaskRequestResolution p_resolution) {
	switch (p_resolution) {
		case TaskRequestResolution::ACKNOWLEDGED: return "acknowledged";
		case TaskRequestResolution::REJECTED: return "rejected";
		case TaskRequestResolution::TIMED_OUT: return "timed_out";
	}
	return "unknown";
}

const char *task_trace_name(TaskTraceKind p_kind) {
	switch (p_kind) {
		case TaskTraceKind::EVENT_ACCEPTED: return "event_accepted";
		case TaskTraceKind::FACT_SNAPSHOT_ACCEPTED: return "fact_snapshot_accepted";
		case TaskTraceKind::NODE_ACTIVATED: return "node_activated";
		case TaskTraceKind::NODE_COUNTER_CHANGED: return "node_counter_changed";
		case TaskTraceKind::NODE_COMPLETED: return "node_completed";
		case TaskTraceKind::EDGE_TRAVERSED: return "edge_traversed";
		case TaskTraceKind::REQUEST_EMITTED: return "request_emitted";
		case TaskTraceKind::REQUEST_RESOLVED: return "request_resolved";
		case TaskTraceKind::REQUEST_DUPLICATE: return "request_duplicate";
		case TaskTraceKind::GRAPH_STATUS_CHANGED: return "graph_status_changed";
	}
	return "unknown";
}

const char *conversation_status_name(ConversationInstanceStatus p_status) {
	switch (p_status) {
		case ConversationInstanceStatus::INACTIVE: return "inactive";
		case ConversationInstanceStatus::LINE: return "line";
		case ConversationInstanceStatus::CHOICE: return "choice";
		case ConversationInstanceStatus::WAITING_FOR_ACTION: return "waiting_for_action";
		case ConversationInstanceStatus::TERMINAL: return "terminal";
	}
	return "unknown";
}

const char *frame_kind_name(ConversationFrameKind p_kind) {
	switch (p_kind) {
		case ConversationFrameKind::NONE: return "none";
		case ConversationFrameKind::LINE: return "line";
		case ConversationFrameKind::CHOICE: return "choice";
		case ConversationFrameKind::EXTERNAL_ACTION: return "external_action";
		case ConversationFrameKind::OUTCOME: return "outcome";
	}
	return "unknown";
}

Variant value_payload(const Value &p_value) {
	switch (p_value.type) {
		case ValueType::NONE: return Variant();
		case ValueType::BOOLEAN: return Variant(std::get<bool>(p_value.payload));
		case ValueType::INTEGER: return Variant(static_cast<int64_t>(std::get<std::int64_t>(p_value.payload)));
		case ValueType::FIXED: return Variant(static_cast<int64_t>(std::get<lts::FixedPoint>(p_value.payload).raw));
		case ValueType::STRING:
		case ValueType::IDENTIFIER: return Variant(to_godot_string(std::get<std::string>(p_value.payload)));
		case ValueType::BYTES:
			{
				PackedByteArray bytes;
				for (std::uint8_t byte : std::get<lts::ByteVector>(p_value.payload)) bytes.push_back(byte);
				return Variant(bytes);
			}
	}
	return Variant();
}

Dictionary value_dictionary(const Value &p_value) {
	Dictionary result;
	result["type"] = static_cast<int>(p_value.type);
	result["type_name"] = String(value_type_name(p_value.type));
	result["value"] = value_payload(p_value);
	switch (p_value.type) {
		case ValueType::BOOLEAN: result["boolean_value"] = value_payload(p_value); break;
		case ValueType::INTEGER: result["integer_value"] = value_payload(p_value); break;
		case ValueType::FIXED: result["fixed_raw"] = value_payload(p_value); break;
		case ValueType::STRING: result["string_value"] = value_payload(p_value); break;
		case ValueType::IDENTIFIER: result["identifier_value"] = value_payload(p_value); break;
		case ValueType::BYTES: result["bytes_value"] = value_payload(p_value); break;
		case ValueType::NONE: break;
	}
	return result;
}

Array values_array(const std::vector<Value> &p_values) {
	Array result;
	for (const Value &value : p_values) result.push_back(value_dictionary(value));
	return result;
}

Dictionary fact_dictionary(const TaskFact &p_fact) {
	Dictionary result;
	result["provider_identifier"] = to_godot_string(p_fact.provider_identifier);
	result["fact_identifier"] = to_godot_string(p_fact.fact_identifier);
	result["value"] = value_dictionary(p_fact.value);
	return result;
}

Dictionary fact_dictionary(const lts::ConversationFact &p_fact) {
	Dictionary result;
	result["provider_identifier"] = to_godot_string(p_fact.provider_identifier);
	result["fact_identifier"] = to_godot_string(p_fact.fact_identifier);
	result["value"] = value_dictionary(p_fact.value);
	return result;
}

Array task_facts_array(const TaskFactSnapshot &p_facts) {
	Array result;
	for (const TaskFact &fact : p_facts.facts()) result.push_back(fact_dictionary(fact));
	return result;
}

Array conversation_facts_array(const lts::ConversationFactSnapshot &p_facts) {
	Array result;
	for (const lts::ConversationFact &fact : p_facts.facts) result.push_back(fact_dictionary(fact));
	return result;
}

Array localized_parameters_array(const std::vector<LocalizedParameter> &p_parameters) {
	Array result;
	for (const LocalizedParameter &parameter : p_parameters) {
		Dictionary item;
		item["identifier"] = to_godot_string(parameter.identifier);
		item["value"] = value_dictionary(parameter.value);
		result.push_back(item);
	}
	return result;
}

Dictionary task_request_dictionary(const TaskExternalRequest &p_request) {
	Dictionary result;
	result["request_identifier"] = to_godot_string(p_request.request_identifier);
	result["kind"] = static_cast<int>(p_request.kind);
	result["kind_name"] = String(request_kind_name(p_request.kind));
	result["instance_identifier"] = to_godot_string(p_request.instance_identifier);
	result["scope_key"] = to_godot_string(p_request.scope_key);
	result["node_identifier"] = to_godot_string(p_request.node_identifier);
	result["provider_identifier"] = to_godot_string(p_request.provider_identifier);
	result["conversation_identifier"] = to_godot_string(p_request.conversation_identifier);
	result["target_level_identifier"] = to_godot_string(p_request.target_level_identifier);
	result["target_exit_identifier"] = to_godot_string(p_request.target_exit_identifier);
	result["target_anchor_identifier"] = to_godot_string(p_request.target_anchor_identifier);
	result["parameters"] = values_array(p_request.parameters);
	result["created_revision"] = static_cast<int64_t>(p_request.created_revision);
	result["created_tick"] = static_cast<int64_t>(p_request.created_tick);
	result["has_timeout"] = p_request.has_timeout;
	result["timeout_tick"] = static_cast<int64_t>(p_request.timeout_tick);
	return result;
}

Dictionary task_transition_dictionary(const TaskTransitionRecord &p_record) {
	Dictionary result;
	result["revision"] = static_cast<int64_t>(p_record.revision);
	result["ordinal"] = static_cast<int>(p_record.ordinal);
	result["from_node_identifier"] = to_godot_string(p_record.from_node_identifier);
	result["to_node_identifier"] = to_godot_string(p_record.to_node_identifier);
	result["edge_identifier"] = to_godot_string(p_record.edge_identifier);
	result["output_port_identifier"] = to_godot_string(p_record.output_port_identifier);
	return result;
}

Dictionary task_state_change_dictionary(const TaskStateChangeRecord &p_record) {
	Dictionary result;
	result["revision"] = static_cast<int64_t>(p_record.revision);
	result["ordinal"] = static_cast<int>(p_record.ordinal);
	result["node_identifier"] = to_godot_string(p_record.node_identifier);
	result["previous_state"] = static_cast<int>(p_record.previous_state);
	result["previous_state_name"] = String(node_state_name(p_record.previous_state));
	result["current_state"] = static_cast<int>(p_record.current_state);
	result["current_state_name"] = String(node_state_name(p_record.current_state));
	result["previous_counter"] = static_cast<int>(p_record.previous_counter);
	result["current_counter"] = static_cast<int>(p_record.current_counter);
	result["request_identifier"] = to_godot_string(p_record.request_identifier);
	result["outcome_identifier"] = to_godot_string(p_record.outcome_identifier);
	return result;
}

Dictionary task_trace_dictionary(const TaskTraceRecord &p_record) {
	Dictionary result;
	result["revision"] = static_cast<int64_t>(p_record.revision);
	result["ordinal"] = static_cast<int>(p_record.ordinal);
	result["kind"] = static_cast<int>(p_record.kind);
	result["kind_name"] = String(task_trace_name(p_record.kind));
	result["node_identifier"] = to_godot_string(p_record.node_identifier);
	result["request_identifier"] = to_godot_string(p_record.request_identifier);
	result["event_identifier"] = to_godot_string(p_record.event_identifier);
	result["outcome_identifier"] = to_godot_string(p_record.outcome_identifier);
	result["previous_state"] = static_cast<int>(p_record.previous_state);
	result["current_state"] = static_cast<int>(p_record.current_state);
	result["graph_status"] = static_cast<int>(p_record.graph_status);
	result["graph_status_name"] = String(task_status_name(p_record.graph_status));
	return result;
}

Dictionary task_resolution_dictionary(const lts::TaskRequestResolutionRecord &p_record) {
	Dictionary result;
	result["request_identifier"] = to_godot_string(p_record.request_identifier);
	result["kind"] = static_cast<int>(p_record.kind);
	result["kind_name"] = String(request_kind_name(p_record.kind));
	result["resolution"] = static_cast<int>(p_record.resolution);
	result["resolution_name"] = String(resolution_name(p_record.resolution));
	result["outcome_identifier"] = to_godot_string(p_record.outcome_identifier);
	result["response"] = value_dictionary(p_record.response);
	result["revision"] = static_cast<int64_t>(p_record.revision);
	return result;
}

Dictionary conversation_request_dictionary(const lts::ConversationActionRequest &p_request) {
	Dictionary result;
	result["request_identifier"] = to_godot_string(p_request.request_identifier);
	result["conversation_identifier"] = to_godot_string(p_request.conversation_identifier);
	result["instance_identifier"] = to_godot_string(p_request.instance_identifier);
	result["scope_identifier"] = to_godot_string(p_request.scope_identifier);
	result["step_identifier"] = to_godot_string(p_request.step_identifier);
	result["provider_identifier"] = to_godot_string(p_request.provider_identifier);
	result["frame_revision"] = static_cast<int64_t>(p_request.frame_revision);
	result["parameters"] = localized_parameters_array(p_request.parameters);
	return result;
}

Dictionary conversation_frame_dictionary(const ConversationFrame &p_frame) {
	Dictionary result;
	result["kind"] = static_cast<int>(p_frame.kind);
	result["kind_name"] = String(frame_kind_name(p_frame.kind));
	result["revision"] = static_cast<int64_t>(p_frame.revision);
	result["step_identifier"] = to_godot_string(p_frame.step_identifier);
	result["speaker_identifier"] = to_godot_string(p_frame.speaker_identifier);
	result["line_key"] = to_godot_string(p_frame.line_key);
	result["parameters"] = localized_parameters_array(p_frame.parameters);
	Array choices;
	for (const lts::ConversationChoiceFrame &choice : p_frame.choices) {
		Dictionary item;
		item["identifier"] = to_godot_string(choice.identifier);
		item["label_key"] = to_godot_string(choice.label_key);
		choices.push_back(item);
	}
	result["choices"] = choices;
	if (p_frame.action_request.has_value()) result["action_request"] = conversation_request_dictionary(p_frame.action_request.value());
	else result["action_request"] = Variant();
	result["outcome_identifier"] = to_godot_string(p_frame.outcome_identifier);
	result["terminal"] = p_frame.terminal;
	return result;
}

Array diagnostics_array(const std::vector<Diagnostic> &p_diagnostics) {
	Array result;
	for (const Diagnostic &diagnostic : p_diagnostics) {
		Dictionary item;
		item["id"] = static_cast<int>(diagnostic.id);
		item["id_name"] = String(diagnostic_name(diagnostic.id));
		item["detail"] = static_cast<int64_t>(diagnostic.detail);
		item["path"] = to_godot_string(diagnostic.path);
		result.push_back(item);
	}
	return result;
}

} // namespace

namespace {

Status native_string(const String &p_value, std::size_t p_limit, std::string &r_value) {
	const CharString utf8 = p_value.utf8();
	const std::size_t length = static_cast<std::size_t>(utf8.length());
	if (length > p_limit) return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, length);
	r_value.assign(utf8.get_data(), length);
	return lts::ok_status();
}

Dictionary event_dictionary(const TaskEvent &p_event) {
	Dictionary result;
	result["sequence"] = static_cast<int64_t>(p_event.sequence);
	result["provider_identifier"] = to_godot_string(p_event.provider_identifier);
	result["event_identifier"] = to_godot_string(p_event.event_identifier);
	result["scope_key"] = to_godot_string(p_event.scope_key);
	result["value"] = value_dictionary(p_event.value);
	result["amount"] = static_cast<int>(p_event.amount);
	return result;
}

} // namespace

Dictionary LevelTaskRuntimeBridge::status_dictionary(const Status &p_status) {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["code"] = static_cast<int>(p_status.code);
	result["code_name"] = String(status_code_name(p_status.code));
	result["diagnostic"] = static_cast<int>(p_status.diagnostic);
	result["diagnostic_name"] = String(diagnostic_name(p_status.diagnostic));
	result["detail"] = static_cast<int64_t>(p_status.detail);
	return result;
}

Dictionary LevelTaskRuntimeBridge::failure_result(const Status &p_status) {
	return status_dictionary(p_status);
}

Dictionary LevelTaskRuntimeBridge::task_summary_for(const TaskGraphInstance *p_instance) const {
	Dictionary result;
	result["configured"] = task_graph != nullptr && task_graph->valid();
	result["isolated"] = true;
	result["authority_bound"] = false;
	result["live_game_access"] = false;
	if (task_graph != nullptr && task_graph->valid()) {
		const TaskGraphDefinition &definition = task_graph->definition();
		result["graph_identifier"] = to_godot_string(definition.identifier);
		result["definition_fingerprint"] = static_cast<int64_t>(task_graph->fingerprint());
		result["node_count"] = static_cast<int64_t>(task_graph->nodes().size());
		result["edge_count"] = static_cast<int64_t>(task_graph->edges().size());
		result["entry_node_identifier"] = to_godot_string(definition.entry_node_identifier);
	}
	if (p_instance == nullptr) {
		result["status"] = static_cast<int>(TaskGraphInstanceStatus::INVALID);
		result["status_name"] = String(task_status_name(TaskGraphInstanceStatus::INVALID));
		result["running"] = false;
		result["terminal"] = false;
		result["revision"] = static_cast<int64_t>(0);
		result["facts"] = task_facts_array(task_facts);
		result["pending_requests"] = Array();
		result["resolved_requests"] = Array();
		result["node_states"] = Array();
		result["terminal_outcome"] = String();
		return result;
	}
	result["instance_identifier"] = to_godot_string(p_instance->instance_identifier());
	result["scope_key"] = to_godot_string(p_instance->scope_key());
	result["status"] = static_cast<int>(p_instance->status());
	result["status_name"] = String(task_status_name(p_instance->status()));
	result["running"] = p_instance->running();
	result["terminal"] = p_instance->terminal();
	result["revision"] = static_cast<int64_t>(p_instance->revision());
	result["terminal_outcome"] = to_godot_string(p_instance->terminal_outcome());
	result["facts"] = task_facts_array(p_instance->last_facts());
	result["pending_request_count"] = static_cast<int64_t>(p_instance->pending_requests().size());
	result["resolved_request_count"] = static_cast<int64_t>(p_instance->resolved_requests().size());
	result["pending_requests_truncated"] = false;
	Array requests;
	for (const TaskExternalRequest &request : p_instance->pending_requests()) requests.push_back(task_request_dictionary(request));
	result["pending_requests"] = requests;
	Array resolved;
	for (const lts::TaskRequestResolutionRecord &resolution : p_instance->resolved_requests()) resolved.push_back(task_resolution_dictionary(resolution));
	result["resolved_requests"] = resolved;
	Array states;
	const std::vector<lts::CanonicalTaskNode> &nodes = p_instance->graph().nodes();
	const std::vector<lts::TaskNodeRuntimeStateRecord> &node_states = p_instance->node_states();
	for (std::size_t index = 0; index < node_states.size() && index < nodes.size(); ++index) {
		Dictionary state;
		state["node_identifier"] = to_godot_string(nodes[index].identifier());
		state["state"] = static_cast<int>(node_states[index].state);
		state["state_name"] = String(node_state_name(node_states[index].state));
		state["counter"] = static_cast<int>(node_states[index].counter);
		state["request_generation"] = static_cast<int64_t>(node_states[index].request_generation);
		states.push_back(state);
	}
	result["node_states"] = states;
	result["transition_count"] = static_cast<int64_t>(p_instance->transition_records().size());
	result["state_change_count"] = static_cast<int64_t>(p_instance->state_change_records().size());
	result["trace_count"] = static_cast<int64_t>(p_instance->trace_records().size());
	result["transitions_truncated"] = p_instance->transition_records_truncated();
	result["state_changes_truncated"] = p_instance->state_change_records_truncated();
	result["trace_truncated"] = p_instance->trace_records_truncated();
	return result;
}

Dictionary LevelTaskRuntimeBridge::conversation_summary_for(const ConversationInstance *p_instance) const {
	Dictionary result;
	result["configured"] = conversation_configured;
	result["isolated"] = true;
	result["authority_bound"] = false;
	result["live_game_access"] = false;
	if (conversation_configured) {
		result["conversation_identifier"] = to_godot_string(conversation_definition.identifier);
		result["definition_fingerprint"] = static_cast<int64_t>(conversation_definition.fingerprint());
		result["entry_label"] = to_godot_string(conversation_definition.entry_label);
		result["step_count"] = static_cast<int64_t>(conversation_definition.steps.size());
	}
	if (p_instance == nullptr) {
		result["status"] = static_cast<int>(ConversationInstanceStatus::INACTIVE);
		result["status_name"] = String(conversation_status_name(ConversationInstanceStatus::INACTIVE));
		result["running"] = false;
		result["terminal"] = false;
		result["revision"] = static_cast<int64_t>(0);
		result["frame_revision"] = static_cast<int64_t>(0);
		result["facts"] = conversation_facts_array(conversation_facts);
		result["frame"] = conversation_frame_dictionary(ConversationFrame());
		result["available_choices"] = Array();
		result["pending_request"] = Variant();
		result["trace_count"] = static_cast<int64_t>(conversation_trace_entries.size());
		result["trace_truncated"] = conversation_trace_truncated;
		return result;
	}
	result["instance_identifier"] = to_godot_string(p_instance->instance_identifier());
	result["scope_identifier"] = to_godot_string(p_instance->scope_identifier());
	result["task_integration_handle"] = to_godot_string(p_instance->task_integration_handle());
	result["current_step_identifier"] = to_godot_string(p_instance->current_step_identifier());
	result["outcome_identifier"] = to_godot_string(p_instance->outcome_identifier());
	result["status"] = static_cast<int>(p_instance->status());
	result["status_name"] = String(conversation_status_name(p_instance->status()));
	result["running"] = p_instance->active();
	result["terminal"] = p_instance->terminal();
	result["revision"] = static_cast<int64_t>(p_instance->revision());
	result["frame_revision"] = static_cast<int64_t>(p_instance->frame_revision());
	result["facts"] = conversation_facts_array(p_instance->facts());
	result["frame"] = conversation_frame_dictionary(p_instance->frame());
	Array choices;
	for (const lts::ConversationChoiceFrame &choice : p_instance->available_choices()) {
		Dictionary item;
		item["identifier"] = to_godot_string(choice.identifier);
		item["label_key"] = to_godot_string(choice.label_key);
		choices.push_back(item);
	}
	result["available_choices"] = choices;
	if (p_instance->pending_request() != nullptr) result["pending_request"] = conversation_request_dictionary(*p_instance->pending_request());
	else result["pending_request"] = Variant();
	result["trace_count"] = static_cast<int64_t>(conversation_trace_entries.size());
	result["trace_truncated"] = conversation_trace_truncated;
	return result;
}

void LevelTaskRuntimeBridge::append_conversation_trace(const char *p_kind,
		const std::string &p_step_identifier, const std::string &p_choice_identifier,
		const std::string &p_outcome_identifier, const std::string &p_request_identifier) {
	ConversationTraceEntry entry;
	entry.kind = p_kind == nullptr ? std::string() : std::string(p_kind);
	entry.step_identifier = p_step_identifier;
	entry.choice_identifier = p_choice_identifier;
	entry.outcome_identifier = p_outcome_identifier;
	entry.request_identifier = p_request_identifier;
	entry.revision = conversation_instance == nullptr ? 0 : conversation_instance->revision();
	entry.ordinal = conversation_trace_entries.empty() ? 0 : conversation_trace_entries.back().ordinal + 1;
	if (conversation_trace_entries.size() >= MAX_BRIDGE_TRACE) {
		conversation_trace_entries.erase(conversation_trace_entries.begin());
		conversation_trace_truncated = true;
	}
	conversation_trace_entries.push_back(std::move(entry));
}

void LevelTaskRuntimeBridge::clear_conversation_trace() {
	conversation_trace_entries.clear();
	conversation_trace_truncated = false;
}

Dictionary LevelTaskRuntimeBridge::task_result(const TaskAdvanceResult &p_result) const {
	Dictionary result = status_dictionary(p_result.status);
	result["changed"] = p_result.changed;
	result["idempotent"] = p_result.idempotent;
	result["revision"] = static_cast<int64_t>(p_result.revision);
	result["graph_status"] = static_cast<int>(p_result.graph_status);
	result["graph_status_name"] = String(task_status_name(p_result.graph_status));
	result["has_resolution"] = p_result.has_resolution;
	if (p_result.has_resolution) result["resolution"] = task_resolution_dictionary(p_result.resolution);
	else result["resolution"] = Variant();
	Array requests;
	for (const TaskExternalRequest &request : p_result.requests) requests.push_back(task_request_dictionary(request));
	result["requests"] = requests;
	Array transitions;
	for (const TaskTransitionRecord &record : p_result.transitions) transitions.push_back(task_transition_dictionary(record));
	result["transitions"] = transitions;
	Array state_changes;
	for (const TaskStateChangeRecord &record : p_result.state_changes) state_changes.push_back(task_state_change_dictionary(record));
	result["state_changes"] = state_changes;
	Array trace;
	for (const TaskTraceRecord &record : p_result.trace) trace.push_back(task_trace_dictionary(record));
	result["trace"] = trace;
	result["transitions_truncated"] = p_result.transitions_truncated;
	result["trace_truncated"] = p_result.trace_truncated;
	result["summary"] = task_summary_for(task_instance.get());
	return result;
}

Dictionary LevelTaskRuntimeBridge::conversation_result(const Status &p_status) const {
	Dictionary result = status_dictionary(p_status);
	result["summary"] = conversation_summary_for(conversation_instance.get());
	result["trace"] = get_conversation_trace();
	result["trace_truncated"] = conversation_trace_truncated;
	return result;
}

Dictionary LevelTaskRuntimeBridge::get_task_summary() const {
	return task_summary_for(task_instance.get());
}

Array LevelTaskRuntimeBridge::get_task_trace() const {
	Array result;
	if (task_instance == nullptr) return result;
	for (const TaskTraceRecord &record : task_instance->trace_records()) result.push_back(task_trace_dictionary(record));
	return result;
}

Array LevelTaskRuntimeBridge::get_conversation_trace() const {
	Array result;
	for (const ConversationTraceEntry &entry : conversation_trace_entries) {
		Dictionary item;
		item["revision"] = static_cast<int64_t>(entry.revision);
		item["ordinal"] = static_cast<int>(entry.ordinal);
		item["kind"] = to_godot_string(entry.kind);
		item["step_identifier"] = to_godot_string(entry.step_identifier);
		item["choice_identifier"] = to_godot_string(entry.choice_identifier);
		item["outcome_identifier"] = to_godot_string(entry.outcome_identifier);
		item["request_identifier"] = to_godot_string(entry.request_identifier);
		result.push_back(item);
	}
	return result;
}

Dictionary LevelTaskRuntimeBridge::get_conversation_summary() const {
	return conversation_summary_for(conversation_instance.get());
}

Dictionary LevelTaskRuntimeBridge::compile_task_graph(const Dictionary &p_definition) {
	TaskGraphDefinition definition;
	Status status = parse_task_graph(p_definition, definition);
	if (!status.ok()) return failure_result(status);
	lts::CanonicalTaskGraph compiled;
	std::vector<Diagnostic> diagnostics;
	status = lts::TaskGraphCompiler().compile(definition, compiled, &diagnostics);
	Dictionary result = status_dictionary(status);
	result["diagnostics"] = diagnostics_array(diagnostics);
	result["compiled"] = status.ok() && compiled.valid();
	if (!status.ok() || !compiled.valid()) return result;
	const std::shared_ptr<const lts::CanonicalTaskGraph> candidate =
			std::make_shared<const lts::CanonicalTaskGraph>(std::move(compiled));
	result["graph_identifier"] = to_godot_string(candidate->definition().identifier);
	result["definition_fingerprint"] = static_cast<int64_t>(candidate->fingerprint());
	result["node_count"] = static_cast<int64_t>(candidate->nodes().size());
	result["edge_count"] = static_cast<int64_t>(candidate->edges().size());
	result["entry_node_identifier"] = to_godot_string(candidate->definition().entry_node_identifier);
	// Compilation is a session reset. The old graph is never used for a
	// partially compiled or invalid definition.
	task_graph = candidate;
	task_instance.reset();
	task_facts.clear();
	task_event_queue.clear();
	task_instance_identifier.clear();
	task_scope_key.clear();
	task_tick = 0;
	task_has_tick = false;
	return result;
}

Dictionary LevelTaskRuntimeBridge::start_task_graph(const Dictionary &p_definition,
		const String &p_instance_identifier, const String &p_scope_key, const Dictionary &p_facts) {
	std::shared_ptr<const lts::CanonicalTaskGraph> candidate_graph = task_graph;
	Dictionary compilation;
	if (!p_definition.is_empty()) {
		TaskGraphDefinition definition;
		Status status = parse_task_graph(p_definition, definition);
		if (!status.ok()) return failure_result(status);
		lts::CanonicalTaskGraph compiled;
		std::vector<Diagnostic> diagnostics;
		status = lts::TaskGraphCompiler().compile(definition, compiled, &diagnostics);
		compilation = status_dictionary(status);
		compilation["diagnostics"] = diagnostics_array(diagnostics);
		compilation["compiled"] = status.ok() && compiled.valid();
		if (!status.ok() || !compiled.valid()) return compilation;
		candidate_graph = std::make_shared<const lts::CanonicalTaskGraph>(std::move(compiled));
	} else if (candidate_graph == nullptr || !candidate_graph->valid()) {
		return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	}
	std::string instance_identifier;
	std::string scope_key;
	Status status = native_string(p_instance_identifier, lts::MAX_IDENTIFIER_BYTES, instance_identifier);
	if (!status.ok()) return failure_result(status);
	status = native_string(p_scope_key, lts::MAX_IDENTIFIER_BYTES, scope_key);
	if (!status.ok()) return failure_result(status);
	if (instance_identifier.empty()) instance_identifier = "preview.task.instance";
	if (scope_key.empty()) scope_key = "preview.task.scope";
	TaskFactSnapshot candidate_facts;
	lts::ConversationFactSnapshot unused_conversation_facts;
	status = parse_facts(p_facts, scope_key, candidate_facts, unused_conversation_facts);
	if (!status.ok()) return failure_result(status);
	std::unique_ptr<TaskGraphInstance> candidate_instance = std::make_unique<TaskGraphInstance>();
	TaskAdvanceResult start_result;
	status = TaskGraphInstance::start(*candidate_graph, instance_identifier, scope_key, *candidate_instance,
			task_limits, &start_result);
	if (!status.ok()) {
		Dictionary result = task_result(start_result);
		result["compiled"] = true;
		result["started"] = false;
		return result;
	}
	// Apply the requested facts as part of the initial start, preserving the
	// core's fail-atomic behavior if the fact snapshot is malformed.
	if (!candidate_facts.empty()) {
		TaskAdvanceResult fact_result;
		status = candidate_instance->advance({}, candidate_facts, 0, &fact_result);
		if (!status.ok()) return task_result(fact_result);
		start_result = std::move(fact_result);
	}
	task_graph = candidate_graph;
	task_instance = std::move(candidate_instance);
	task_facts = std::move(candidate_facts);
	task_instance_identifier = instance_identifier;
	task_scope_key = scope_key;
	task_event_queue.clear();
	task_tick = 0;
	task_has_tick = false;
	Dictionary result = task_result(start_result);
	result["started"] = true;
	result["compiled"] = true;
	result["graph_identifier"] = to_godot_string(candidate_graph->definition().identifier);
	result["definition_fingerprint"] = static_cast<int64_t>(candidate_graph->fingerprint());
	return result;
}

Dictionary LevelTaskRuntimeBridge::set_task_facts(const Dictionary &p_facts) {
	const std::string expected_scope = task_instance != nullptr ? task_instance->scope_key() : task_scope_key;
	TaskFactSnapshot candidate_facts;
	lts::ConversationFactSnapshot unused_conversation_facts;
	Status status = parse_facts(p_facts, expected_scope, candidate_facts, unused_conversation_facts);
	if (!status.ok()) return failure_result(status);
	if (task_instance == nullptr) {
		task_facts = std::move(candidate_facts);
		Dictionary result = status_dictionary(lts::ok_status());
		result["changed"] = true;
		result["summary"] = task_summary_for(nullptr);
		return result;
	}
	TaskGraphInstance candidate = *task_instance;
	TaskAdvanceResult advance_result;
	const std::uint64_t tick = task_has_tick ? task_tick : 0;
	status = candidate.advance({}, candidate_facts, tick, &advance_result);
	if (!status.ok()) return task_result(advance_result);
	task_instance = std::make_unique<TaskGraphInstance>(std::move(candidate));
	task_facts = std::move(candidate_facts);
	return task_result(advance_result);
}

Dictionary LevelTaskRuntimeBridge::inject_task_event(const Dictionary &p_event) {
	if (task_event_queue.size() >= task_limits.max_events_per_advance ||
			task_event_queue.size() >= lts::MAX_EVENTS_PER_ADVANCE) {
		return failure_result(lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(task_event_queue.size())));
	}
	TaskEvent event;
	Status status = parse_task_event(p_event, task_scope_key, event);
	if (!status.ok()) return failure_result(status);
	if (!task_scope_key.empty() && event.scope_key != task_scope_key) {
		return failure_result(lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	}
	task_event_queue.push_back(std::move(event));
	Dictionary result = status_dictionary(lts::ok_status());
	result["queued_count"] = static_cast<int64_t>(task_event_queue.size());
	result["event"] = event_dictionary(task_event_queue.back());
	result["summary"] = task_summary_for(task_instance.get());
	return result;
}

Dictionary LevelTaskRuntimeBridge::step_task(int64_t p_tick) {
	if (task_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	if (p_tick < -1) return failure_result(lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE));
	std::uint64_t tick = 0;
	if (p_tick >= 0) {
		tick = static_cast<std::uint64_t>(p_tick);
	} else {
		if (task_has_tick && task_tick == std::numeric_limits<std::uint64_t>::max()) {
			return failure_result(lts::make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE));
		}
		tick = task_has_tick ? task_tick + 1 : 0;
	}
	TaskGraphInstance candidate = *task_instance;
	TaskAdvanceResult advance_result;
	Status status = candidate.advance(task_event_queue, task_facts, tick, &advance_result);
	if (!status.ok()) return task_result(advance_result);
	task_instance = std::make_unique<TaskGraphInstance>(std::move(candidate));
	task_event_queue.clear();
	task_tick = tick;
	task_has_tick = true;
	return task_result(advance_result);
}

Dictionary LevelTaskRuntimeBridge::run_task(int64_t p_max_steps) {
	if (p_max_steps <= 0 || p_max_steps > 1024) return failure_result(lts::make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE));
	if (task_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	int64_t steps = 0;
	while (steps < p_max_steps && task_instance->running()) {
		bool has_work = !task_event_queue.empty();
		if (!has_work) {
			for (const TaskExternalRequest &request : task_instance->pending_requests()) {
				if (request.has_timeout) {
					has_work = true;
					break;
				}
			}
		}
		if (!has_work) break;
		Dictionary one = step_task(-1);
		++steps;
		if (!static_cast<bool>(one.get("ok", false))) {
			one["steps"] = steps;
			return one;
		}
	}
	Dictionary result = status_dictionary(lts::ok_status());
	result["steps"] = steps;
	result["bounded"] = steps < p_max_steps;
	result["trace"] = get_task_trace();
	result["trace_truncated"] = task_instance->trace_records_truncated();
	result["summary"] = task_summary_for(task_instance.get());
	return result;
}

Dictionary LevelTaskRuntimeBridge::acknowledge_task_request(const String &p_request_identifier,
		const String &p_outcome_identifier, const Dictionary &p_response) {
	if (task_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	std::string request_identifier;
	std::string outcome_identifier;
	Status status = native_string(p_request_identifier, lts::MAX_IDENTIFIER_BYTES, request_identifier);
	if (!status.ok()) return failure_result(status);
	status = native_string(p_outcome_identifier, lts::MAX_IDENTIFIER_BYTES, outcome_identifier);
	if (!status.ok()) return failure_result(status);
	Value response = Value::none();
	if (!p_response.is_empty()) {
		status = parse_value(Variant(p_response), response);
		if (!status.ok()) return failure_result(status);
	}
	TaskGraphInstance candidate = *task_instance;
	TaskAdvanceResult advance_result;
	status = candidate.acknowledge_request(request_identifier, outcome_identifier, response,
			task_has_tick ? task_tick : lts::NO_TICK, lts::NO_EXPECTED_REVISION, &advance_result);
	if (!status.ok()) return task_result(advance_result);
	task_instance = std::make_unique<TaskGraphInstance>(std::move(candidate));
	return task_result(advance_result);
}

Dictionary LevelTaskRuntimeBridge::reject_task_request(const String &p_request_identifier, const Dictionary &p_response) {
	if (task_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	std::string request_identifier;
	Status status = native_string(p_request_identifier, lts::MAX_IDENTIFIER_BYTES, request_identifier);
	if (!status.ok()) return failure_result(status);
	Value response = Value::none();
	if (!p_response.is_empty()) {
		status = parse_value(Variant(p_response), response);
		if (!status.ok()) return failure_result(status);
	}
	TaskGraphInstance candidate = *task_instance;
	TaskAdvanceResult advance_result;
	status = candidate.reject_request(request_identifier, response, task_has_tick ? task_tick : lts::NO_TICK,
			lts::NO_EXPECTED_REVISION, &advance_result);
	if (!status.ok()) return task_result(advance_result);
	task_instance = std::make_unique<TaskGraphInstance>(std::move(candidate));
	return task_result(advance_result);
}

Dictionary LevelTaskRuntimeBridge::timeout_task_request(const String &p_request_identifier) {
	if (task_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	std::string request_identifier;
	Status status = native_string(p_request_identifier, lts::MAX_IDENTIFIER_BYTES, request_identifier);
	if (!status.ok()) return failure_result(status);
	TaskGraphInstance candidate = *task_instance;
	TaskAdvanceResult advance_result;
	status = candidate.timeout_request(request_identifier, task_has_tick ? task_tick : lts::NO_TICK,
			lts::NO_EXPECTED_REVISION, &advance_result);
	if (!status.ok()) return task_result(advance_result);
	task_instance = std::make_unique<TaskGraphInstance>(std::move(candidate));
	return task_result(advance_result);
}

Dictionary LevelTaskRuntimeBridge::reset_task() {
	if (task_graph == nullptr || !task_graph->valid() || task_instance_identifier.empty() || task_scope_key.empty()) {
		return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::GRAPH_PAYLOAD_INVALID));
	}
	std::unique_ptr<TaskGraphInstance> candidate = std::make_unique<TaskGraphInstance>();
	TaskAdvanceResult start_result;
	Status status = TaskGraphInstance::start(*task_graph, task_instance_identifier, task_scope_key, *candidate,
			task_limits, &start_result);
	if (!status.ok()) return task_result(start_result);
	if (!task_facts.empty()) {
		TaskAdvanceResult fact_result;
		status = candidate->advance({}, task_facts, 0, &fact_result);
		if (!status.ok()) return task_result(fact_result);
		start_result = std::move(fact_result);
	}
	task_instance = std::move(candidate);
	task_event_queue.clear();
	task_tick = 0;
	task_has_tick = false;
	return task_result(start_result);
}

Dictionary LevelTaskRuntimeBridge::compile_conversation(const Dictionary &p_definition) {
	ConversationDefinition definition;
	Status status = parse_conversation(p_definition, definition);
	if (!status.ok()) return failure_result(status);
	ConversationInstance candidate;
	status = candidate.configure(definition);
	Dictionary result = status_dictionary(status);
	result["compiled"] = status.ok() && candidate.has_definition();
	if (!status.ok()) return result;
	conversation_definition = candidate.definition();
	conversation_configured = true;
	conversation_instance.reset();
	conversation_facts.clear();
	conversation_instance_identifier.clear();
	conversation_scope_identifier.clear();
	conversation_entry_label.clear();
	conversation_task_integration_handle.clear();
	clear_conversation_trace();
	result["conversation_identifier"] = to_godot_string(conversation_definition.identifier);
	result["definition_fingerprint"] = static_cast<int64_t>(candidate.definition_fingerprint());
	result["step_count"] = static_cast<int64_t>(conversation_definition.steps.size());
	return result;
}

Dictionary LevelTaskRuntimeBridge::start_conversation(const Dictionary &p_definition,
		const String &p_instance_identifier, const String &p_scope_identifier, const Dictionary &p_facts,
		const String &p_entry_label, const String &p_task_integration_handle) {
	ConversationDefinition candidate_definition = conversation_definition;
	if (!p_definition.is_empty()) {
		Status status = parse_conversation(p_definition, candidate_definition);
		if (!status.ok()) return failure_result(status);
	}
	if (candidate_definition.identifier.empty()) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	std::string instance_identifier;
	std::string scope_identifier;
	std::string entry_label;
	std::string task_handle;
	Status status = native_string(p_instance_identifier, lts::MAX_IDENTIFIER_BYTES, instance_identifier);
	if (!status.ok()) return failure_result(status);
	status = native_string(p_scope_identifier, lts::MAX_IDENTIFIER_BYTES, scope_identifier);
	if (!status.ok()) return failure_result(status);
	status = native_string(p_entry_label, lts::MAX_IDENTIFIER_BYTES, entry_label);
	if (!status.ok()) return failure_result(status);
	status = native_string(p_task_integration_handle, lts::MAX_IDENTIFIER_BYTES, task_handle);
	if (!status.ok()) return failure_result(status);
	if (instance_identifier.empty()) instance_identifier = "preview.conversation.instance";
	if (scope_identifier.empty()) scope_identifier = "preview.conversation.scope";
	lts::TaskFactSnapshot unused_task_facts;
	lts::ConversationFactSnapshot candidate_facts;
	status = parse_facts(p_facts, scope_identifier, unused_task_facts, candidate_facts);
	if (!status.ok()) return failure_result(status);
	ConversationInstance candidate;
	status = candidate.start(candidate_definition, instance_identifier, scope_identifier, candidate_facts,
			entry_label, task_handle);
	if (!status.ok()) return conversation_result(status);
	conversation_definition = candidate.definition();
	conversation_configured = true;
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	conversation_facts = std::move(candidate_facts);
	conversation_instance_identifier = instance_identifier;
	conversation_scope_identifier = scope_identifier;
	conversation_entry_label = entry_label.empty() ? conversation_definition.entry_label : entry_label;
	conversation_task_integration_handle = task_handle;
	clear_conversation_trace();
	append_conversation_trace("started", conversation_instance->current_step_identifier(), std::string(),
			conversation_instance->outcome_identifier());
	Dictionary result = conversation_result(lts::ok_status());
	result["started"] = true;
	result["compiled"] = true;
	result["conversation_identifier"] = to_godot_string(conversation_definition.identifier);
	result["definition_fingerprint"] = static_cast<int64_t>(conversation_instance->definition_fingerprint());
	return result;
}

Dictionary LevelTaskRuntimeBridge::set_conversation_facts(const Dictionary &p_facts) {
	lts::TaskFactSnapshot unused_task_facts;
	lts::ConversationFactSnapshot candidate_facts;
	Status status = parse_facts(p_facts, conversation_scope_identifier, unused_task_facts, candidate_facts);
	if (!status.ok()) return failure_result(status);
	if (conversation_instance == nullptr) {
		conversation_facts = std::move(candidate_facts);
		return conversation_result(lts::ok_status());
	}
	ConversationInstance candidate = *conversation_instance;
	status = candidate.set_facts(candidate_facts);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	conversation_facts = std::move(candidate_facts);
	append_conversation_trace("facts_updated", conversation_instance->current_step_identifier());
	return conversation_result(lts::ok_status());
}

Dictionary LevelTaskRuntimeBridge::step_conversation(int64_t p_frame_revision) {
	if (conversation_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	if (p_frame_revision < -1) return failure_result(lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE));
	const std::uint64_t frame_revision = p_frame_revision < 0 ? conversation_instance->frame_revision() : static_cast<std::uint64_t>(p_frame_revision);
	ConversationInstance candidate = *conversation_instance;
	Status status = candidate.continue_line(frame_revision);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	append_conversation_trace("line_advanced", conversation_instance->current_step_identifier());
	return conversation_result(lts::ok_status());
}

Dictionary LevelTaskRuntimeBridge::run_conversation(int64_t p_max_steps) {
	if (p_max_steps <= 0 || p_max_steps > 1024) return failure_result(lts::make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE));
	if (conversation_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	ConversationInstance candidate = *conversation_instance;
	int64_t steps = 0;
	while (steps < p_max_steps && candidate.status() == ConversationInstanceStatus::LINE) {
		const std::string before = candidate.current_step_identifier();
		const std::uint64_t revision = candidate.frame_revision();
		Status status = candidate.continue_line(revision);
		if (!status.ok()) return conversation_result(status);
		++steps;
		(void)before;
	}
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	append_conversation_trace("run", conversation_instance->current_step_identifier());
	Dictionary result = conversation_result(lts::ok_status());
	result["steps"] = steps;
	result["bounded"] = steps < p_max_steps;
	return result;
}

Dictionary LevelTaskRuntimeBridge::select_conversation_choice(const String &p_choice_identifier,
		int64_t p_frame_revision) {
	if (conversation_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	if (p_frame_revision < -1) return failure_result(lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE));
	std::string choice_identifier;
	Status status = native_string(p_choice_identifier, lts::MAX_IDENTIFIER_BYTES, choice_identifier);
	if (!status.ok()) return failure_result(status);
	const std::uint64_t frame_revision = p_frame_revision < 0 ? conversation_instance->frame_revision() : static_cast<std::uint64_t>(p_frame_revision);
	ConversationInstance candidate = *conversation_instance;
	status = candidate.select_choice(choice_identifier, frame_revision);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	append_conversation_trace("choice_selected", conversation_instance->current_step_identifier(), choice_identifier);
	return conversation_result(lts::ok_status());
}

Status parse_response_dictionary(const Dictionary &p_response, Value &r_response) {
	if (p_response.is_empty()) {
		r_response = Value::none();
		return lts::ok_status();
	}
	return parse_value(Variant(p_response), r_response);
}

Dictionary LevelTaskRuntimeBridge::acknowledge_conversation_action(const String &p_request_identifier,
		bool p_success, const Dictionary &p_response) {
	if (conversation_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	std::string request_identifier;
	Status status = native_string(p_request_identifier, lts::MAX_IDENTIFIER_BYTES, request_identifier);
	if (!status.ok()) return failure_result(status);
	Value response;
	status = parse_response_dictionary(p_response, response);
	if (!status.ok()) return failure_result(status);
	ConversationInstance candidate = *conversation_instance;
	status = candidate.acknowledge_action(request_identifier, p_success, response);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	append_conversation_trace("action_resolved", conversation_instance->current_step_identifier(), std::string(),
			conversation_instance->outcome_identifier(), request_identifier);
	return conversation_result(lts::ok_status());
}

Dictionary LevelTaskRuntimeBridge::reject_conversation_action(const String &p_request_identifier) {
	if (conversation_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	std::string request_identifier;
	Status status = native_string(p_request_identifier, lts::MAX_IDENTIFIER_BYTES, request_identifier);
	if (!status.ok()) return failure_result(status);
	ConversationInstance candidate = *conversation_instance;
	status = candidate.reject_action(request_identifier);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	append_conversation_trace("action_rejected", conversation_instance->current_step_identifier(), std::string(),
			conversation_instance->outcome_identifier(), request_identifier);
	return conversation_result(lts::ok_status());
}

Dictionary LevelTaskRuntimeBridge::timeout_conversation_action(const String &p_request_identifier) {
	if (conversation_instance == nullptr) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	std::string request_identifier;
	Status status = native_string(p_request_identifier, lts::MAX_IDENTIFIER_BYTES, request_identifier);
	if (!status.ok()) return failure_result(status);
	ConversationInstance candidate = *conversation_instance;
	status = candidate.timeout_action(request_identifier);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	append_conversation_trace("action_timed_out", conversation_instance->current_step_identifier(), std::string(),
			conversation_instance->outcome_identifier(), request_identifier);
	return conversation_result(lts::ok_status());
}

Dictionary LevelTaskRuntimeBridge::restart_conversation(const String &p_entry_label) {
	if (!conversation_configured || conversation_definition.identifier.empty()) return failure_result(lts::make_status(StatusCode::NOT_FOUND, DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID));
	std::string entry_label;
	Status status = native_string(p_entry_label, lts::MAX_IDENTIFIER_BYTES, entry_label);
	if (!status.ok()) return failure_result(status);
	const std::string instance_identifier = conversation_instance_identifier.empty() ? "preview.conversation.instance" : conversation_instance_identifier;
	const std::string scope_identifier = conversation_scope_identifier.empty() ? "preview.conversation.scope" : conversation_scope_identifier;
	ConversationInstance candidate;
	status = candidate.start(conversation_definition, instance_identifier, scope_identifier, conversation_facts,
			entry_label, conversation_task_integration_handle);
	if (!status.ok()) return conversation_result(status);
	conversation_instance = std::make_unique<ConversationInstance>(std::move(candidate));
	conversation_entry_label = entry_label.empty() ? conversation_definition.entry_label : entry_label;
	clear_conversation_trace();
	append_conversation_trace("restarted", conversation_instance->current_step_identifier());
	return conversation_result(lts::ok_status());
}

void LevelTaskRuntimeBridge::_bind_methods() {
	ClassDB::bind_method(D_METHOD("compile_task_graph", "definition"), &LevelTaskRuntimeBridge::compile_task_graph);
	ClassDB::bind_method(D_METHOD("start_task_graph", "definition", "instance_identifier", "scope_key", "facts"), &LevelTaskRuntimeBridge::start_task_graph,
			DEFVAL(String()), DEFVAL(String()), DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("set_task_facts", "facts"), &LevelTaskRuntimeBridge::set_task_facts);
	ClassDB::bind_method(D_METHOD("set_synthetic_facts", "facts"), &LevelTaskRuntimeBridge::set_synthetic_facts);
	ClassDB::bind_method(D_METHOD("inject_task_event", "event"), &LevelTaskRuntimeBridge::inject_task_event);
	ClassDB::bind_method(D_METHOD("inject_event", "event"), &LevelTaskRuntimeBridge::inject_event);
	ClassDB::bind_method(D_METHOD("step_task", "tick"), &LevelTaskRuntimeBridge::step_task, DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("run_task", "max_steps"), &LevelTaskRuntimeBridge::run_task, DEFVAL(int64_t(64)));
	ClassDB::bind_method(D_METHOD("acknowledge_task_request", "request_identifier", "outcome_identifier", "response"), &LevelTaskRuntimeBridge::acknowledge_task_request,
			DEFVAL(String()), DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("reject_task_request", "request_identifier", "response"), &LevelTaskRuntimeBridge::reject_task_request, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("timeout_task_request", "request_identifier"), &LevelTaskRuntimeBridge::timeout_task_request);
	ClassDB::bind_method(D_METHOD("reset_task"), &LevelTaskRuntimeBridge::reset_task);
	ClassDB::bind_method(D_METHOD("reset"), &LevelTaskRuntimeBridge::reset);
	ClassDB::bind_method(D_METHOD("get_task_summary"), &LevelTaskRuntimeBridge::get_task_summary);
	ClassDB::bind_method(D_METHOD("get_task_trace"), &LevelTaskRuntimeBridge::get_task_trace);
	ClassDB::bind_method(D_METHOD("task_summary"), &LevelTaskRuntimeBridge::task_summary);
	ClassDB::bind_method(D_METHOD("task_trace"), &LevelTaskRuntimeBridge::task_trace);

	ClassDB::bind_method(D_METHOD("compile_conversation", "definition"), &LevelTaskRuntimeBridge::compile_conversation);
	ClassDB::bind_method(D_METHOD("start_conversation", "definition", "instance_identifier", "scope_identifier", "facts", "entry_label", "task_integration_handle"), &LevelTaskRuntimeBridge::start_conversation,
			DEFVAL(String()), DEFVAL(String()), DEFVAL(Dictionary()), DEFVAL(String()), DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("set_conversation_facts", "facts"), &LevelTaskRuntimeBridge::set_conversation_facts);
	ClassDB::bind_method(D_METHOD("set_preview_facts", "facts"), &LevelTaskRuntimeBridge::set_preview_facts);
	ClassDB::bind_method(D_METHOD("step_conversation", "frame_revision"), &LevelTaskRuntimeBridge::step_conversation, DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("continue_conversation", "frame_revision"), &LevelTaskRuntimeBridge::continue_conversation, DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("run_conversation", "max_steps"), &LevelTaskRuntimeBridge::run_conversation, DEFVAL(int64_t(64)));
	ClassDB::bind_method(D_METHOD("select_conversation_choice", "choice_identifier", "frame_revision"), &LevelTaskRuntimeBridge::select_conversation_choice, DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("select_choice", "choice_identifier", "frame_revision"), &LevelTaskRuntimeBridge::select_choice, DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("acknowledge_conversation_action", "request_identifier", "success", "response"), &LevelTaskRuntimeBridge::acknowledge_conversation_action, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("reject_conversation_action", "request_identifier"), &LevelTaskRuntimeBridge::reject_conversation_action);
	ClassDB::bind_method(D_METHOD("timeout_conversation_action", "request_identifier"), &LevelTaskRuntimeBridge::timeout_conversation_action);
	ClassDB::bind_method(D_METHOD("restart_conversation", "entry_label"), &LevelTaskRuntimeBridge::restart_conversation, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("restart", "entry_label"), &LevelTaskRuntimeBridge::restart, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("get_conversation_summary"), &LevelTaskRuntimeBridge::get_conversation_summary);
	ClassDB::bind_method(D_METHOD("get_conversation_trace"), &LevelTaskRuntimeBridge::get_conversation_trace);
	ClassDB::bind_method(D_METHOD("conversation_summary"), &LevelTaskRuntimeBridge::conversation_summary);
	ClassDB::bind_method(D_METHOD("conversation_trace"), &LevelTaskRuntimeBridge::conversation_trace);
}

} // namespace godot
