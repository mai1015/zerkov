#include "resources/level_task_definition_resources.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/char_string.hpp>

#include <cstddef>
#include <cstdint>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace godot {

namespace {

using lts::DiagnosticId;
using lts::Status;
using lts::StatusCode;

Status invalid_resource() {
	return lts::make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
}

Status invalid_enum(int p_value) {
	return lts::make_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM,
			static_cast<std::uint64_t>(p_value < 0 ? 0 : p_value));
}

Status invalid_integer(int p_value) {
	return lts::make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE,
			static_cast<std::uint64_t>(p_value < 0 ? 0 : p_value));
}

Status copy_string(const String &p_value, std::size_t p_limit, std::string &r_value,
		DiagnosticId p_diagnostic = DiagnosticId::BYTE_LIMIT_EXCEEDED) {
	const CharString utf8 = p_value.utf8();
	if (static_cast<std::size_t>(utf8.length()) > p_limit) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, p_diagnostic,
				static_cast<std::uint64_t>(utf8.length()));
	}
	r_value.assign(utf8.get_data(), static_cast<std::size_t>(utf8.length()));
	return lts::ok_status();
}

Status copy_name(const StringName &p_value, std::string &r_value) {
	return copy_string(String(p_value), lts::MAX_IDENTIFIER_BYTES, r_value);
}

Status copy_local_name(const StringName &p_value, std::string &r_value) {
	return copy_name(p_value, r_value);
}

Status copy_scene_resource(const String &p_value, std::string &r_value) {
	return copy_string(p_value, lts::MAX_SCENE_RESOURCE_BYTES,
			r_value, DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID);
}

Status copy_localization_key(const StringName &p_value, std::string &r_value) {
	return copy_string(String(p_value), lts::MAX_LOCALIZATION_KEY_BYTES,
			r_value);
}

Status copy_text(const String &p_value, std::size_t p_limit, std::string &r_value,
		DiagnosticId p_diagnostic = DiagnosticId::BYTE_LIMIT_EXCEEDED) {
	return copy_string(p_value, p_limit, r_value, p_diagnostic);
}

Status copy_bytes(const PackedByteArray &p_value, lts::ByteVector &r_value) {
	if (static_cast<std::size_t>(p_value.size()) > lts::MAX_VALUE_BYTES) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::BYTE_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(p_value.size()));
	}
	lts::ByteVector value;
	value.reserve(static_cast<std::size_t>(p_value.size()));
	for (int index = 0; index < p_value.size(); ++index) {
		value.push_back(p_value[index]);
	}
	r_value = std::move(value);
	return lts::ok_status();
}

template <typename T>
Status copy_name_array(const PackedStringArray &p_values, std::size_t p_limit,
		std::vector<T> &r_values,
		DiagnosticId p_limit_diagnostic = DiagnosticId::COUNT_LIMIT_EXCEEDED) {
	static_assert(std::is_same_v<T, std::string>, "name arrays contain strings");
	if (static_cast<std::size_t>(p_values.size()) > p_limit) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, p_limit_diagnostic,
				static_cast<std::uint64_t>(p_values.size()));
	}
	std::vector<T> values;
	values.reserve(static_cast<std::size_t>(p_values.size()));
	for (int index = 0; index < p_values.size(); ++index) {
		T value;
		const Status status = copy_name(StringName(p_values[index]), value);
		if (!status.ok()) return status;
		values.push_back(std::move(value));
	}
	r_values = std::move(values);
	return lts::ok_status();
}

Status copy_schema_version(int p_version, std::uint16_t &r_version) {
	if (p_version < 1 || p_version > 65535) return invalid_integer(p_version);
	r_version = static_cast<std::uint16_t>(p_version);
	return lts::ok_status();
}

template <typename T>
Status require_resource(const Ref<T> &p_resource) {
	return p_resource.is_null() ? invalid_resource() : lts::ok_status();
}

Status copy_value_resource(const Ref<LevelTaskValue> &p_resource, lts::Value &r_value) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_value(r_value);
}

Status copy_predicate_resource(const Ref<LevelTaskFactPredicate> &p_resource,
		lts::FactPredicate &r_predicate) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_predicate(r_predicate);
}

Status copy_parameter_resource(const Ref<LevelTaskLocalizedParameter> &p_resource,
		lts::LocalizedParameter &r_parameter) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_parameter(r_parameter);
}

Status copy_port_resource(const Ref<LevelTaskPortDefinition> &p_resource,
		lts::TaskPortDefinition &r_port) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_port(r_port);
}

Status copy_node_resource(const Ref<LevelTaskNodeDefinition> &p_resource,
		lts::TaskNodeDefinition &r_node) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_node(r_node);
}

Status copy_edge_resource(const Ref<LevelTaskEdgeDefinition> &p_resource,
		lts::TaskEdgeDefinition &r_edge) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_edge(r_edge);
}

Status copy_anchor_resource(const Ref<LevelTaskLevelAnchorDefinition> &p_resource,
		lts::LevelAnchorDefinition &r_anchor) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_anchor(r_anchor);
}

Status copy_exit_resource(const Ref<LevelTaskLevelExitDefinition> &p_resource,
		lts::LevelExitDefinition &r_exit) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_exit(r_exit);
}

Status copy_choice_resource(const Ref<LevelTaskConversationChoiceDefinition> &p_resource,
		lts::ConversationChoiceDefinition &r_choice) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_choice(r_choice);
}

Status copy_step_resource(const Ref<LevelTaskConversationStepDefinition> &p_resource,
		lts::ConversationStepDefinition &r_step) {
	if (p_resource.is_null()) return invalid_resource();
	return p_resource->to_core_step(r_step);
}

} // namespace

// -------------------------------------------------------------------------
// LevelTaskValue
// -------------------------------------------------------------------------

void LevelTaskValue::set_type(ValueType p_type) {
	type = p_type;
	notify_property_list_changed();
	emit_changed();
}

void LevelTaskValue::set_boolean_value(bool p_value) {
	boolean_value = p_value;
	emit_changed();
}

void LevelTaskValue::set_integer_value(int64_t p_value) {
	integer_value = p_value;
	emit_changed();
}

void LevelTaskValue::set_fixed_raw(int64_t p_value) {
	fixed_raw = p_value;
	emit_changed();
}

void LevelTaskValue::set_string_value(const String &p_value) {
	string_value = p_value;
	emit_changed();
}

void LevelTaskValue::set_text_value(const String &p_value) {
	text_value = p_value;
	emit_changed();
}

void LevelTaskValue::set_bytes_value(const PackedByteArray &p_value) {
	bytes_value = p_value;
	emit_changed();
}

Status LevelTaskValue::to_core_value(lts::Value &r_value) const {
	lts::Value value;
	Status status = lts::ok_status();
	switch (type) {
		case VALUE_NONE:
			value = lts::Value::none();
			break;
		case VALUE_BOOLEAN:
			value = lts::Value::boolean(boolean_value);
			break;
		case VALUE_INTEGER:
			value = lts::Value::integer(integer_value);
			break;
		case VALUE_FIXED:
			value = lts::Value::fixed(lts::FixedPoint::from_raw(fixed_raw));
			break;
		case VALUE_STRING: {
			std::string text;
			status = copy_text(string_value, lts::MAX_STRING_BYTES, text);
			if (!status.ok()) return status;
			value = lts::Value::string(text);
			break;
		}
		case VALUE_IDENTIFIER: {
			// `text_value` is the Inspector-facing identifier field.  Accept
			// string_value as a compatibility fallback for scripts authored
			// before the explicit field was introduced.
			const String &source = text_value.is_empty() ? string_value : text_value;
			std::string text;
			status = copy_name(StringName(source), text);
			if (!status.ok()) return status;
			value = lts::Value::identifier(text);
			break;
		}
		case VALUE_BYTES: {
			lts::ByteVector bytes;
			status = copy_bytes(bytes_value, bytes);
			if (!status.ok()) return status;
			value = lts::Value::bytes(bytes);
			break;
		}
		default:
			return invalid_enum(static_cast<int>(type));
	}
	status = value.validate();
	if (!status.ok()) return status;
	r_value = std::move(value);
	return lts::ok_status();
}

Status LevelTaskValue::validate_core() const {
	lts::Value value;
	return to_core_value(value);
}

void LevelTaskValue::_validate_property(PropertyInfo &p_property) const {
	const StringName name = p_property.name;
	if (name == StringName("boolean_value") && type != VALUE_BOOLEAN) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("integer_value") && type != VALUE_INTEGER) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("fixed_raw") && type != VALUE_FIXED) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("string_value") && type != VALUE_STRING) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("text_value") && type != VALUE_IDENTIFIER) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("bytes_value") && type != VALUE_BYTES) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void LevelTaskValue::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_type", "type"), &LevelTaskValue::set_type);
	ClassDB::bind_method(D_METHOD("get_type"), &LevelTaskValue::get_type);
	ClassDB::bind_method(D_METHOD("set_boolean_value", "value"), &LevelTaskValue::set_boolean_value);
	ClassDB::bind_method(D_METHOD("get_boolean_value"), &LevelTaskValue::get_boolean_value);
	ClassDB::bind_method(D_METHOD("set_integer_value", "value"), &LevelTaskValue::set_integer_value);
	ClassDB::bind_method(D_METHOD("get_integer_value"), &LevelTaskValue::get_integer_value);
	ClassDB::bind_method(D_METHOD("set_fixed_raw", "value"), &LevelTaskValue::set_fixed_raw);
	ClassDB::bind_method(D_METHOD("get_fixed_raw"), &LevelTaskValue::get_fixed_raw);
	ClassDB::bind_method(D_METHOD("set_string_value", "value"), &LevelTaskValue::set_string_value);
	ClassDB::bind_method(D_METHOD("get_string_value"), &LevelTaskValue::get_string_value);
	ClassDB::bind_method(D_METHOD("set_text_value", "value"), &LevelTaskValue::set_text_value);
	ClassDB::bind_method(D_METHOD("get_text_value"), &LevelTaskValue::get_text_value);
	ClassDB::bind_method(D_METHOD("set_identifier_value", "value"), &LevelTaskValue::set_identifier_value);
	ClassDB::bind_method(D_METHOD("get_identifier_value"), &LevelTaskValue::get_identifier_value);
	ClassDB::bind_method(D_METHOD("set_bytes_value", "value"), &LevelTaskValue::set_bytes_value);
	ClassDB::bind_method(D_METHOD("get_bytes_value"), &LevelTaskValue::get_bytes_value);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "type", PROPERTY_HINT_ENUM,
			"None,Boolean,Integer,Fixed,String,Identifier,Bytes"),
			"set_type", "get_type");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "boolean_value"), "set_boolean_value", "get_boolean_value");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "integer_value"), "set_integer_value", "get_integer_value");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "fixed_raw"), "set_fixed_raw", "get_fixed_raw");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "string_value", PROPERTY_HINT_MULTILINE_TEXT),
			"set_string_value", "get_string_value");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "text_value", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"global.identifier.value"), "set_text_value", "get_text_value");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_BYTE_ARRAY, "bytes_value"),
			"set_bytes_value", "get_bytes_value");

	BIND_ENUM_CONSTANT(VALUE_NONE);
	BIND_ENUM_CONSTANT(VALUE_BOOLEAN);
	BIND_ENUM_CONSTANT(VALUE_INTEGER);
	BIND_ENUM_CONSTANT(VALUE_FIXED);
	BIND_ENUM_CONSTANT(VALUE_STRING);
	BIND_ENUM_CONSTANT(VALUE_IDENTIFIER);
	BIND_ENUM_CONSTANT(VALUE_BYTES);
}

// -------------------------------------------------------------------------
// Shared predicate/parameter/port resources
// -------------------------------------------------------------------------

void LevelTaskFactPredicate::set_provider_identifier(const StringName &p_identifier) {
	provider_identifier = p_identifier;
	emit_changed();
}

void LevelTaskFactPredicate::set_fact_identifier(const StringName &p_identifier) {
	fact_identifier = p_identifier;
	emit_changed();
}

void LevelTaskFactPredicate::set_comparator(ComparisonOperator p_comparator) {
	comparator = p_comparator;
	emit_changed();
}

void LevelTaskFactPredicate::set_expected(const Ref<LevelTaskValue> &p_expected) {
	expected = p_expected;
	emit_changed();
}

Status LevelTaskFactPredicate::to_core_predicate(lts::FactPredicate &r_predicate) const {
	lts::FactPredicate predicate;
	Status status = copy_name(provider_identifier, predicate.provider_identifier);
	if (!status.ok()) return status;
	status = copy_name(fact_identifier, predicate.fact_identifier);
	if (!status.ok()) return status;
	if (comparator < COMPARISON_EQUAL || comparator > COMPARISON_GREATER_OR_EQUAL) {
		return invalid_enum(static_cast<int>(comparator));
	}
	predicate.comparator = static_cast<lts::ComparisonOperator>(static_cast<int>(comparator));
	status = copy_value_resource(expected, predicate.expected);
	if (!status.ok()) return status;
	status = predicate.validate();
	if (!status.ok()) return status;
	r_predicate = std::move(predicate);
	return lts::ok_status();
}

Status LevelTaskFactPredicate::validate_core() const {
	lts::FactPredicate predicate;
	return to_core_predicate(predicate);
}

void LevelTaskFactPredicate::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_provider_identifier", "identifier"), &LevelTaskFactPredicate::set_provider_identifier);
	ClassDB::bind_method(D_METHOD("get_provider_identifier"), &LevelTaskFactPredicate::get_provider_identifier);
	ClassDB::bind_method(D_METHOD("set_fact_identifier", "identifier"), &LevelTaskFactPredicate::set_fact_identifier);
	ClassDB::bind_method(D_METHOD("get_fact_identifier"), &LevelTaskFactPredicate::get_fact_identifier);
	ClassDB::bind_method(D_METHOD("set_comparator", "comparator"), &LevelTaskFactPredicate::set_comparator);
	ClassDB::bind_method(D_METHOD("get_comparator"), &LevelTaskFactPredicate::get_comparator);
	ClassDB::bind_method(D_METHOD("set_expected", "value"), &LevelTaskFactPredicate::set_expected);
	ClassDB::bind_method(D_METHOD("get_expected"), &LevelTaskFactPredicate::get_expected);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "provider_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.provider.fact"), "set_provider_identifier", "get_provider_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "fact_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.fact.progress"), "set_fact_identifier", "get_fact_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "comparator", PROPERTY_HINT_ENUM,
			"Equal,Not Equal,Less,Less or Equal,Greater,Greater or Equal"),
			"set_comparator", "get_comparator");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "expected", PROPERTY_HINT_RESOURCE_TYPE,
			"LevelTaskValue"), "set_expected", "get_expected");

	BIND_ENUM_CONSTANT(COMPARISON_EQUAL);
	BIND_ENUM_CONSTANT(COMPARISON_NOT_EQUAL);
	BIND_ENUM_CONSTANT(COMPARISON_LESS);
	BIND_ENUM_CONSTANT(COMPARISON_LESS_OR_EQUAL);
	BIND_ENUM_CONSTANT(COMPARISON_GREATER);
	BIND_ENUM_CONSTANT(COMPARISON_GREATER_OR_EQUAL);
}

void LevelTaskLocalizedParameter::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskLocalizedParameter::set_value(const Ref<LevelTaskValue> &p_value) {
	value = p_value;
	emit_changed();
}

Status LevelTaskLocalizedParameter::to_core_parameter(lts::LocalizedParameter &r_parameter) const {
	lts::LocalizedParameter parameter;
	Status status = copy_local_name(identifier, parameter.identifier);
	if (!status.ok()) return status;
	status = copy_value_resource(value, parameter.value);
	if (!status.ok()) return status;
	status = parameter.validate();
	if (!status.ok()) return status;
	r_parameter = std::move(parameter);
	return lts::ok_status();
}

Status LevelTaskLocalizedParameter::validate_core() const {
	lts::LocalizedParameter parameter;
	return to_core_parameter(parameter);
}

void LevelTaskLocalizedParameter::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskLocalizedParameter::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskLocalizedParameter::get_identifier);
	ClassDB::bind_method(D_METHOD("set_value", "value"), &LevelTaskLocalizedParameter::set_value);
	ClassDB::bind_method(D_METHOD("get_value"), &LevelTaskLocalizedParameter::get_value);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"count"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "value", PROPERTY_HINT_RESOURCE_TYPE,
			"LevelTaskValue"), "set_value", "get_value");
}

void LevelTaskPortDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskPortDefinition::set_direction(PortDirection p_direction) {
	direction = p_direction;
	emit_changed();
}

void LevelTaskPortDefinition::set_value_type(LevelTaskValue::ValueType p_value_type) {
	value_type = p_value_type;
	emit_changed();
}

void LevelTaskPortDefinition::set_required(bool p_required) {
	required = p_required;
	emit_changed();
}

Status LevelTaskPortDefinition::to_core_port(lts::TaskPortDefinition &r_port) const {
	lts::TaskPortDefinition port;
	Status status = copy_local_name(identifier, port.identifier);
	if (!status.ok()) return status;
	if (direction != PORT_INPUT && direction != PORT_OUTPUT) {
		return invalid_enum(static_cast<int>(direction));
	}
	if (value_type < LevelTaskValue::VALUE_NONE || value_type > LevelTaskValue::VALUE_BYTES) {
		return invalid_enum(static_cast<int>(value_type));
	}
	port.direction = direction == PORT_INPUT ? lts::TaskPortDirection::INPUT : lts::TaskPortDirection::OUTPUT;
	port.value_type = static_cast<lts::ValueType>(static_cast<int>(value_type));
	port.required = required;
	status = port.validate();
	if (!status.ok()) return status;
	r_port = std::move(port);
	return lts::ok_status();
}

Status LevelTaskPortDefinition::validate_core() const {
	lts::TaskPortDefinition port;
	return to_core_port(port);
}

void LevelTaskPortDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskPortDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskPortDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_direction", "direction"), &LevelTaskPortDefinition::set_direction);
	ClassDB::bind_method(D_METHOD("get_direction"), &LevelTaskPortDefinition::get_direction);
	ClassDB::bind_method(D_METHOD("set_value_type", "type"), &LevelTaskPortDefinition::set_value_type);
	ClassDB::bind_method(D_METHOD("get_value_type"), &LevelTaskPortDefinition::get_value_type);
	ClassDB::bind_method(D_METHOD("set_required", "required"), &LevelTaskPortDefinition::set_required);
	ClassDB::bind_method(D_METHOD("get_required"), &LevelTaskPortDefinition::get_required);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"in"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "direction", PROPERTY_HINT_ENUM, "Input,Output"),
			"set_direction", "get_direction");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "value_type", PROPERTY_HINT_ENUM,
			"None,Boolean,Integer,Fixed,String,Identifier,Bytes"),
			"set_value_type", "get_value_type");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "required"), "set_required", "get_required");

	BIND_ENUM_CONSTANT(PORT_INPUT);
	BIND_ENUM_CONSTANT(PORT_OUTPUT);
}

// -------------------------------------------------------------------------
// Task node, edge, and graph resources
// -------------------------------------------------------------------------

void LevelTaskNodeDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskNodeDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskNodeDefinition::set_kind(NodeKind p_kind) {
	kind = p_kind;
	notify_property_list_changed();
	emit_changed();
}

void LevelTaskNodeDefinition::set_ports(const TypedArray<LevelTaskPortDefinition> &p_ports) {
	ports = p_ports;
	emit_changed();
}

void LevelTaskNodeDefinition::set_provider_identifier(const StringName &p_identifier) {
	provider_identifier = p_identifier;
	emit_changed();
}

void LevelTaskNodeDefinition::set_objective_target(int p_target) {
	objective_target = p_target;
	emit_changed();
}

void LevelTaskNodeDefinition::set_filters(const TypedArray<LevelTaskFactPredicate> &p_filters) {
	filters = p_filters;
	emit_changed();
}

void LevelTaskNodeDefinition::set_parameters(const TypedArray<LevelTaskValue> &p_parameters) {
	parameters = p_parameters;
	emit_changed();
}

void LevelTaskNodeDefinition::set_conversation_identifier(const StringName &p_identifier) {
	conversation_identifier = p_identifier;
	emit_changed();
}

void LevelTaskNodeDefinition::set_conversation_entry_label(const StringName &p_label) {
	conversation_entry_label = p_label;
	emit_changed();
}

void LevelTaskNodeDefinition::set_accepted_outcomes(const PackedStringArray &p_outcomes) {
	accepted_outcomes = p_outcomes;
	emit_changed();
}

void LevelTaskNodeDefinition::set_subgraph_identifier(const StringName &p_identifier) {
	subgraph_identifier = p_identifier;
	emit_changed();
}

void LevelTaskNodeDefinition::set_outcome_identifier(const StringName &p_identifier) {
	outcome_identifier = p_identifier;
	emit_changed();
}

Status LevelTaskNodeDefinition::to_core_node(lts::TaskNodeDefinition &r_node) const {
	lts::TaskNodeDefinition node;
	Status status = copy_local_name(identifier, node.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, node.schema_version);
	if (!status.ok()) return status;
	if (kind < NODE_ENTRY || kind > NODE_CANCELLED_TERMINAL) {
		return invalid_enum(static_cast<int>(kind));
	}
	node.kind = static_cast<lts::TaskNodeKind>(static_cast<int>(kind) + 1);

	if (ports.size() > static_cast<int>(lts::MAX_PORTS_PER_TASK_NODE)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_PORT_LIMIT,
				static_cast<std::uint64_t>(ports.size()));
	}
	node.ports.reserve(static_cast<std::size_t>(ports.size()));
	for (int index = 0; index < ports.size(); ++index) {
		const Ref<LevelTaskPortDefinition> port = ports[index];
		lts::TaskPortDefinition core_port;
		status = copy_port_resource(port, core_port);
		if (!status.ok()) return status;
		node.ports.push_back(std::move(core_port));
	}

	status = copy_name(provider_identifier, node.provider_identifier);
	if (!status.ok()) return status;
	if (objective_target < 0) return invalid_integer(objective_target);
	node.objective_target = static_cast<std::uint32_t>(objective_target);

	if (filters.size() > static_cast<int>(lts::MAX_NODE_FILTERS)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(filters.size()));
	}
	node.filters.reserve(static_cast<std::size_t>(filters.size()));
	for (int index = 0; index < filters.size(); ++index) {
		const Ref<LevelTaskFactPredicate> filter = filters[index];
		lts::FactPredicate core_filter;
		status = copy_predicate_resource(filter, core_filter);
		if (!status.ok()) return status;
		node.filters.push_back(std::move(core_filter));
	}

	if (parameters.size() > static_cast<int>(lts::MAX_NODE_PARAMETERS)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(parameters.size()));
	}
	node.parameters.reserve(static_cast<std::size_t>(parameters.size()));
	for (int index = 0; index < parameters.size(); ++index) {
		const Ref<LevelTaskValue> parameter = parameters[index];
		lts::Value core_parameter;
		status = copy_value_resource(parameter, core_parameter);
		if (!status.ok()) return status;
		node.parameters.push_back(std::move(core_parameter));
	}

	status = copy_name(conversation_identifier, node.conversation_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(conversation_entry_label, node.conversation_entry_label);
	if (!status.ok()) return status;
	status = copy_name_array<std::string>(accepted_outcomes, lts::MAX_TERMINAL_OUTCOMES,
			node.accepted_outcomes, DiagnosticId::GRAPH_OUTCOME_INVALID);
	if (!status.ok()) return status;
	status = copy_name(subgraph_identifier, node.subgraph_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(outcome_identifier, node.outcome_identifier);
	if (!status.ok()) return status;

	status = lts::validate_and_canonicalize(node);
	if (!status.ok()) return status;
	r_node = std::move(node);
	return lts::ok_status();
}

Status LevelTaskNodeDefinition::validate_core() const {
	lts::TaskNodeDefinition node;
	return to_core_node(node);
}

void LevelTaskNodeDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskNodeDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskNodeDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskNodeDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskNodeDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_kind", "kind"), &LevelTaskNodeDefinition::set_kind);
	ClassDB::bind_method(D_METHOD("get_kind"), &LevelTaskNodeDefinition::get_kind);
	ClassDB::bind_method(D_METHOD("set_ports", "ports"), &LevelTaskNodeDefinition::set_ports);
	ClassDB::bind_method(D_METHOD("get_ports"), &LevelTaskNodeDefinition::get_ports);
	ClassDB::bind_method(D_METHOD("set_provider_identifier", "identifier"), &LevelTaskNodeDefinition::set_provider_identifier);
	ClassDB::bind_method(D_METHOD("get_provider_identifier"), &LevelTaskNodeDefinition::get_provider_identifier);
	ClassDB::bind_method(D_METHOD("set_objective_target", "target"), &LevelTaskNodeDefinition::set_objective_target);
	ClassDB::bind_method(D_METHOD("get_objective_target"), &LevelTaskNodeDefinition::get_objective_target);
	ClassDB::bind_method(D_METHOD("set_filters", "filters"), &LevelTaskNodeDefinition::set_filters);
	ClassDB::bind_method(D_METHOD("get_filters"), &LevelTaskNodeDefinition::get_filters);
	ClassDB::bind_method(D_METHOD("set_parameters", "parameters"), &LevelTaskNodeDefinition::set_parameters);
	ClassDB::bind_method(D_METHOD("get_parameters"), &LevelTaskNodeDefinition::get_parameters);
	ClassDB::bind_method(D_METHOD("set_conversation_identifier", "identifier"), &LevelTaskNodeDefinition::set_conversation_identifier);
	ClassDB::bind_method(D_METHOD("get_conversation_identifier"), &LevelTaskNodeDefinition::get_conversation_identifier);
	ClassDB::bind_method(D_METHOD("set_conversation_entry_label", "label"), &LevelTaskNodeDefinition::set_conversation_entry_label);
	ClassDB::bind_method(D_METHOD("get_conversation_entry_label"), &LevelTaskNodeDefinition::get_conversation_entry_label);
	ClassDB::bind_method(D_METHOD("set_accepted_outcomes", "outcomes"), &LevelTaskNodeDefinition::set_accepted_outcomes);
	ClassDB::bind_method(D_METHOD("get_accepted_outcomes"), &LevelTaskNodeDefinition::get_accepted_outcomes);
	ClassDB::bind_method(D_METHOD("set_subgraph_identifier", "identifier"), &LevelTaskNodeDefinition::set_subgraph_identifier);
	ClassDB::bind_method(D_METHOD("get_subgraph_identifier"), &LevelTaskNodeDefinition::get_subgraph_identifier);
	ClassDB::bind_method(D_METHOD("set_outcome_identifier", "identifier"), &LevelTaskNodeDefinition::set_outcome_identifier);
	ClassDB::bind_method(D_METHOD("get_outcome_identifier"), &LevelTaskNodeDefinition::get_outcome_identifier);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"node_identifier"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM,
			"Entry,Objective,Condition,All Gate,Any Gate,External Action,Conversation,Subgraph,Reward Request,Success,Failure,Cancelled"),
			"set_kind", "get_kind");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "ports", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskPortDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_ports", "get_ports");
	ADD_GROUP("Provider and Objective", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "provider_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.provider.event"), "set_provider_identifier", "get_provider_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "objective_target", PROPERTY_HINT_RANGE,
			"1,1000000,1,or_greater"), "set_objective_target", "get_objective_target");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "filters", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskFactPredicate", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_filters", "get_filters");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "parameters", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskValue", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_parameters", "get_parameters");
	ADD_GROUP("Conversation", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "conversation_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.conversation.example"), "set_conversation_identifier", "get_conversation_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "conversation_entry_label", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"intro"), "set_conversation_entry_label", "get_conversation_entry_label");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "accepted_outcomes"),
			"set_accepted_outcomes", "get_accepted_outcomes");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "subgraph_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.task.subgraph"), "set_subgraph_identifier", "get_subgraph_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "outcome_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"success"), "set_outcome_identifier", "get_outcome_identifier");

	BIND_ENUM_CONSTANT(NODE_ENTRY);
	BIND_ENUM_CONSTANT(NODE_OBJECTIVE);
	BIND_ENUM_CONSTANT(NODE_CONDITION);
	BIND_ENUM_CONSTANT(NODE_ALL_GATE);
	BIND_ENUM_CONSTANT(NODE_ANY_GATE);
	BIND_ENUM_CONSTANT(NODE_EXTERNAL_ACTION);
	BIND_ENUM_CONSTANT(NODE_CONVERSATION);
	BIND_ENUM_CONSTANT(NODE_SUBGRAPH);
	BIND_ENUM_CONSTANT(NODE_REWARD_REQUEST);
	BIND_ENUM_CONSTANT(NODE_SUCCESS_TERMINAL);
	BIND_ENUM_CONSTANT(NODE_FAILURE_TERMINAL);
	BIND_ENUM_CONSTANT(NODE_CANCELLED_TERMINAL);
}

void LevelTaskNodeDefinition::_validate_property(PropertyInfo &p_property) const {
	const StringName name = p_property.name;
	const bool provider_node = kind == NODE_OBJECTIVE || kind == NODE_CONDITION ||
			kind == NODE_EXTERNAL_ACTION || kind == NODE_REWARD_REQUEST;
	const bool objective_node = kind == NODE_OBJECTIVE;
	const bool condition_node = kind == NODE_OBJECTIVE || kind == NODE_CONDITION;
	const bool conversation_node = kind == NODE_CONVERSATION;
	const bool subgraph_node = kind == NODE_SUBGRAPH;
	const bool terminal_node = kind == NODE_SUCCESS_TERMINAL || kind == NODE_FAILURE_TERMINAL ||
			kind == NODE_CANCELLED_TERMINAL;
	if (name == StringName("provider_identifier") && !provider_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("objective_target") && !objective_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("filters") && !condition_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("parameters") && !provider_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if ((name == StringName("conversation_identifier") || name == StringName("conversation_entry_label") ||
			name == StringName("accepted_outcomes")) && !conversation_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("subgraph_identifier") && !subgraph_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("outcome_identifier") && !terminal_node) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void LevelTaskEdgeDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskEdgeDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskEdgeDefinition::set_from_node_identifier(const StringName &p_identifier) {
	from_node_identifier = p_identifier;
	emit_changed();
}

void LevelTaskEdgeDefinition::set_from_port_identifier(const StringName &p_identifier) {
	from_port_identifier = p_identifier;
	emit_changed();
}

void LevelTaskEdgeDefinition::set_to_node_identifier(const StringName &p_identifier) {
	to_node_identifier = p_identifier;
	emit_changed();
}

void LevelTaskEdgeDefinition::set_to_port_identifier(const StringName &p_identifier) {
	to_port_identifier = p_identifier;
	emit_changed();
}

Status LevelTaskEdgeDefinition::to_core_edge(lts::TaskEdgeDefinition &r_edge) const {
	lts::TaskEdgeDefinition edge;
	Status status = copy_local_name(identifier, edge.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, edge.schema_version);
	if (!status.ok()) return status;
	status = copy_local_name(from_node_identifier, edge.from_node_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(from_port_identifier, edge.from_port_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(to_node_identifier, edge.to_node_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(to_port_identifier, edge.to_port_identifier);
	if (!status.ok()) return status;
	status = edge.validate();
	if (!status.ok()) return status;
	r_edge = std::move(edge);
	return lts::ok_status();
}

Status LevelTaskEdgeDefinition::validate_core() const {
	lts::TaskEdgeDefinition edge;
	return to_core_edge(edge);
}

void LevelTaskEdgeDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskEdgeDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskEdgeDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskEdgeDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskEdgeDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_from_node_identifier", "identifier"), &LevelTaskEdgeDefinition::set_from_node_identifier);
	ClassDB::bind_method(D_METHOD("get_from_node_identifier"), &LevelTaskEdgeDefinition::get_from_node_identifier);
	ClassDB::bind_method(D_METHOD("set_from_port_identifier", "identifier"), &LevelTaskEdgeDefinition::set_from_port_identifier);
	ClassDB::bind_method(D_METHOD("get_from_port_identifier"), &LevelTaskEdgeDefinition::get_from_port_identifier);
	ClassDB::bind_method(D_METHOD("set_to_node_identifier", "identifier"), &LevelTaskEdgeDefinition::set_to_node_identifier);
	ClassDB::bind_method(D_METHOD("get_to_node_identifier"), &LevelTaskEdgeDefinition::get_to_node_identifier);
	ClassDB::bind_method(D_METHOD("set_to_port_identifier", "identifier"), &LevelTaskEdgeDefinition::set_to_port_identifier);
	ClassDB::bind_method(D_METHOD("get_to_port_identifier"), &LevelTaskEdgeDefinition::get_to_port_identifier);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"edge"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_GROUP("From", "from_");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "from_node_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"source_node"), "set_from_node_identifier", "get_from_node_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "from_port_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"success"), "set_from_port_identifier", "get_from_port_identifier");
	ADD_GROUP("To", "to_");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "to_node_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"target_node"), "set_to_node_identifier", "get_to_node_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "to_port_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"in"), "set_to_port_identifier", "get_to_port_identifier");
}

void LevelTaskGraphDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskGraphDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskGraphDefinition::set_entry_node_identifier(const StringName &p_identifier) {
	entry_node_identifier = p_identifier;
	emit_changed();
}

void LevelTaskGraphDefinition::set_terminal_outcomes(const PackedStringArray &p_outcomes) {
	terminal_outcomes = p_outcomes;
	emit_changed();
}

void LevelTaskGraphDefinition::set_nodes(const TypedArray<LevelTaskNodeDefinition> &p_nodes) {
	nodes = p_nodes;
	emit_changed();
}

void LevelTaskGraphDefinition::set_edges(const TypedArray<LevelTaskEdgeDefinition> &p_edges) {
	edges = p_edges;
	emit_changed();
}

void LevelTaskGraphDefinition::set_max_transitions_per_advance(int p_limit) {
	max_transitions_per_advance = p_limit;
	emit_changed();
}

Status LevelTaskGraphDefinition::to_core_graph(lts::TaskGraphDefinition &r_graph) const {
	lts::TaskGraphDefinition graph;
	Status status = copy_name(identifier, graph.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, graph.schema_version);
	if (!status.ok()) return status;
	status = copy_local_name(entry_node_identifier, graph.entry_node_identifier);
	if (!status.ok()) return status;
	status = copy_name_array<std::string>(terminal_outcomes, lts::MAX_TERMINAL_OUTCOMES,
			graph.terminal_outcomes, DiagnosticId::GRAPH_OUTCOME_INVALID);
	if (!status.ok()) return status;
	if (nodes.size() > static_cast<int>(lts::MAX_NODES_PER_TASK_GRAPH)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_LIMIT,
				static_cast<std::uint64_t>(nodes.size()));
	}
	graph.nodes.reserve(static_cast<std::size_t>(nodes.size()));
	for (int index = 0; index < nodes.size(); ++index) {
		const Ref<LevelTaskNodeDefinition> node = nodes[index];
		lts::TaskNodeDefinition core_node;
		status = copy_node_resource(node, core_node);
		if (!status.ok()) return status;
		graph.nodes.push_back(std::move(core_node));
	}
	if (edges.size() > static_cast<int>(lts::MAX_EDGES_PER_TASK_GRAPH)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_EDGE_LIMIT,
				static_cast<std::uint64_t>(edges.size()));
	}
	graph.edges.reserve(static_cast<std::size_t>(edges.size()));
	for (int index = 0; index < edges.size(); ++index) {
		const Ref<LevelTaskEdgeDefinition> edge = edges[index];
		lts::TaskEdgeDefinition core_edge;
		status = copy_edge_resource(edge, core_edge);
		if (!status.ok()) return status;
		graph.edges.push_back(std::move(core_edge));
	}
	if (max_transitions_per_advance < 0) return invalid_integer(max_transitions_per_advance);
	graph.max_transitions_per_advance = static_cast<std::uint32_t>(max_transitions_per_advance);
	status = graph.validate_and_canonicalize();
	if (!status.ok()) return status;
	r_graph = std::move(graph);
	return lts::ok_status();
}

Status LevelTaskGraphDefinition::validate_core() const {
	lts::TaskGraphDefinition graph;
	return to_core_graph(graph);
}

std::uint64_t LevelTaskGraphDefinition::get_core_fingerprint() const {
	lts::TaskGraphDefinition graph;
	if (!to_core_graph(graph).ok()) return lts::INVALID_CATALOG_FINGERPRINT;
	return graph.fingerprint();
}

void LevelTaskGraphDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskGraphDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskGraphDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskGraphDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskGraphDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_entry_node_identifier", "identifier"), &LevelTaskGraphDefinition::set_entry_node_identifier);
	ClassDB::bind_method(D_METHOD("get_entry_node_identifier"), &LevelTaskGraphDefinition::get_entry_node_identifier);
	ClassDB::bind_method(D_METHOD("set_terminal_outcomes", "outcomes"), &LevelTaskGraphDefinition::set_terminal_outcomes);
	ClassDB::bind_method(D_METHOD("get_terminal_outcomes"), &LevelTaskGraphDefinition::get_terminal_outcomes);
	ClassDB::bind_method(D_METHOD("set_nodes", "nodes"), &LevelTaskGraphDefinition::set_nodes);
	ClassDB::bind_method(D_METHOD("get_nodes"), &LevelTaskGraphDefinition::get_nodes);
	ClassDB::bind_method(D_METHOD("set_edges", "edges"), &LevelTaskGraphDefinition::set_edges);
	ClassDB::bind_method(D_METHOD("get_edges"), &LevelTaskGraphDefinition::get_edges);
	ClassDB::bind_method(D_METHOD("set_max_transitions_per_advance", "limit"), &LevelTaskGraphDefinition::set_max_transitions_per_advance);
	ClassDB::bind_method(D_METHOD("get_max_transitions_per_advance"), &LevelTaskGraphDefinition::get_max_transitions_per_advance);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.task.example"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "entry_node_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"entry"), "set_entry_node_identifier", "get_entry_node_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "terminal_outcomes"),
			"set_terminal_outcomes", "get_terminal_outcomes");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "nodes", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskNodeDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_nodes", "get_nodes");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "edges", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskEdgeDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_edges", "get_edges");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_transitions_per_advance", PROPERTY_HINT_RANGE,
			"1,1024,1,or_greater"), "set_max_transitions_per_advance", "get_max_transitions_per_advance");
}

// -------------------------------------------------------------------------
// Level resources
// -------------------------------------------------------------------------

void LevelTaskLevelAnchorDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskLevelAnchorDefinition::set_kind(AnchorKind p_kind) {
	kind = p_kind;
	emit_changed();
}

void LevelTaskLevelAnchorDefinition::set_required(bool p_required) {
	required = p_required;
	emit_changed();
}

void LevelTaskLevelAnchorDefinition::set_binding_label(const String &p_label) {
	binding_label = p_label;
	emit_changed();
}

Status LevelTaskLevelAnchorDefinition::to_core_anchor(lts::LevelAnchorDefinition &r_anchor) const {
	lts::LevelAnchorDefinition anchor;
	Status status = copy_local_name(identifier, anchor.identifier);
	if (!status.ok()) return status;
	if (kind < ANCHOR_POINT || kind > ANCHOR_AREA) return invalid_enum(static_cast<int>(kind));
	anchor.kind = static_cast<lts::SceneAnchorKind>(static_cast<int>(kind) + 1);
	anchor.required = required;
	status = copy_text(binding_label, lts::MAX_ANCHOR_BINDING_LABEL_BYTES,
			anchor.binding_label);
	if (!status.ok()) return status;
	status = anchor.validate();
	if (!status.ok()) return status;
	r_anchor = std::move(anchor);
	return lts::ok_status();
}

Status LevelTaskLevelAnchorDefinition::validate_core() const {
	lts::LevelAnchorDefinition anchor;
	return to_core_anchor(anchor);
}

void LevelTaskLevelAnchorDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskLevelAnchorDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskLevelAnchorDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_kind", "kind"), &LevelTaskLevelAnchorDefinition::set_kind);
	ClassDB::bind_method(D_METHOD("get_kind"), &LevelTaskLevelAnchorDefinition::get_kind);
	ClassDB::bind_method(D_METHOD("set_required", "required"), &LevelTaskLevelAnchorDefinition::set_required);
	ClassDB::bind_method(D_METHOD("get_required"), &LevelTaskLevelAnchorDefinition::get_required);
	ClassDB::bind_method(D_METHOD("set_binding_label", "label"), &LevelTaskLevelAnchorDefinition::set_binding_label);
	ClassDB::bind_method(D_METHOD("get_binding_label"), &LevelTaskLevelAnchorDefinition::get_binding_label);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"spawn"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM,
			"Point,Transform,Area"), "set_kind", "get_kind");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "required"), "set_required", "get_required");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "binding_label", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"player_spawn"), "set_binding_label", "get_binding_label");

	BIND_ENUM_CONSTANT(ANCHOR_POINT);
	BIND_ENUM_CONSTANT(ANCHOR_TRANSFORM);
	BIND_ENUM_CONSTANT(ANCHOR_AREA);
}

void LevelTaskLevelExitDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskLevelExitDefinition::set_target_level_identifier(const StringName &p_identifier) {
	target_level_identifier = p_identifier;
	emit_changed();
}

void LevelTaskLevelExitDefinition::set_target_anchor_identifier(const StringName &p_identifier) {
	target_anchor_identifier = p_identifier;
	emit_changed();
}

void LevelTaskLevelExitDefinition::set_outcome_identifier(const StringName &p_identifier) {
	outcome_identifier = p_identifier;
	emit_changed();
}

Status LevelTaskLevelExitDefinition::to_core_exit(lts::LevelExitDefinition &r_exit) const {
	lts::LevelExitDefinition exit;
	Status status = copy_local_name(identifier, exit.identifier);
	if (!status.ok()) return status;
	status = copy_name(target_level_identifier, exit.target_level_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(target_anchor_identifier, exit.target_anchor_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(outcome_identifier, exit.outcome_identifier);
	if (!status.ok()) return status;
	status = exit.validate();
	if (!status.ok()) return status;
	r_exit = std::move(exit);
	return lts::ok_status();
}

Status LevelTaskLevelExitDefinition::validate_core() const {
	lts::LevelExitDefinition exit;
	return to_core_exit(exit);
}

void LevelTaskLevelExitDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskLevelExitDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskLevelExitDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_target_level_identifier", "identifier"), &LevelTaskLevelExitDefinition::set_target_level_identifier);
	ClassDB::bind_method(D_METHOD("get_target_level_identifier"), &LevelTaskLevelExitDefinition::get_target_level_identifier);
	ClassDB::bind_method(D_METHOD("set_target_anchor_identifier", "identifier"), &LevelTaskLevelExitDefinition::set_target_anchor_identifier);
	ClassDB::bind_method(D_METHOD("get_target_anchor_identifier"), &LevelTaskLevelExitDefinition::get_target_anchor_identifier);
	ClassDB::bind_method(D_METHOD("set_outcome_identifier", "identifier"), &LevelTaskLevelExitDefinition::set_outcome_identifier);
	ClassDB::bind_method(D_METHOD("get_outcome_identifier"), &LevelTaskLevelExitDefinition::get_outcome_identifier);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"leave"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_level_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.level.next"), "set_target_level_identifier", "get_target_level_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_anchor_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"spawn"), "set_target_anchor_identifier", "get_target_anchor_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "outcome_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"success"), "set_outcome_identifier", "get_outcome_identifier");
}

void LevelTaskLevelDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskLevelDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskLevelDefinition::set_display_name_key(const StringName &p_key) {
	display_name_key = p_key;
	emit_changed();
}

void LevelTaskLevelDefinition::set_description_key(const StringName &p_key) {
	description_key = p_key;
	emit_changed();
}

void LevelTaskLevelDefinition::set_scene_resource(const String &p_resource) {
	scene_resource = p_resource;
	emit_changed();
}

void LevelTaskLevelDefinition::set_availability_rules(const TypedArray<LevelTaskFactPredicate> &p_rules) {
	availability_rules = p_rules;
	emit_changed();
}

void LevelTaskLevelDefinition::set_entry_graph_identifiers(const PackedStringArray &p_identifiers) {
	entry_graph_identifiers = p_identifiers;
	emit_changed();
}

void LevelTaskLevelDefinition::set_anchors(const TypedArray<LevelTaskLevelAnchorDefinition> &p_anchors) {
	anchors = p_anchors;
	emit_changed();
}

void LevelTaskLevelDefinition::set_exits(const TypedArray<LevelTaskLevelExitDefinition> &p_exits) {
	exits = p_exits;
	emit_changed();
}

Status LevelTaskLevelDefinition::to_core_level(lts::LevelDefinition &r_level) const {
	lts::LevelDefinition level;
	Status status = copy_name(identifier, level.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, level.schema_version);
	if (!status.ok()) return status;
	status = copy_localization_key(display_name_key, level.display_name_key);
	if (!status.ok()) return status;
	status = copy_localization_key(description_key, level.description_key);
	if (!status.ok()) return status;
	status = copy_scene_resource(scene_resource, level.scene_resource);
	if (!status.ok()) return status;

	if (availability_rules.size() > static_cast<int>(lts::MAX_AVAILABILITY_RULES)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_AVAILABILITY_INVALID,
				static_cast<std::uint64_t>(availability_rules.size()));
	}
	level.availability_rules.reserve(static_cast<std::size_t>(availability_rules.size()));
	for (int index = 0; index < availability_rules.size(); ++index) {
		const Ref<LevelTaskFactPredicate> rule = availability_rules[index];
		lts::FactPredicate core_rule;
		status = copy_predicate_resource(rule, core_rule);
		if (!status.ok()) return status;
		level.availability_rules.push_back(std::move(core_rule));
	}

	status = copy_name_array<std::string>(entry_graph_identifiers, lts::MAX_ENTRY_GRAPHS_PER_LEVEL,
			level.entry_graph_identifiers, DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID);
	if (!status.ok()) return status;
	if (anchors.size() > static_cast<int>(lts::MAX_ANCHORS_PER_LEVEL)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_ANCHOR_INVALID,
				static_cast<std::uint64_t>(anchors.size()));
	}
	level.anchors.reserve(static_cast<std::size_t>(anchors.size()));
	for (int index = 0; index < anchors.size(); ++index) {
		const Ref<LevelTaskLevelAnchorDefinition> anchor = anchors[index];
		lts::LevelAnchorDefinition core_anchor;
		status = copy_anchor_resource(anchor, core_anchor);
		if (!status.ok()) return status;
		level.anchors.push_back(std::move(core_anchor));
	}
	if (exits.size() > static_cast<int>(lts::MAX_EXITS_PER_LEVEL)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LEVEL_EXIT_INVALID,
				static_cast<std::uint64_t>(exits.size()));
	}
	level.exits.reserve(static_cast<std::size_t>(exits.size()));
	for (int index = 0; index < exits.size(); ++index) {
		const Ref<LevelTaskLevelExitDefinition> exit = exits[index];
		lts::LevelExitDefinition core_exit;
		status = copy_exit_resource(exit, core_exit);
		if (!status.ok()) return status;
		level.exits.push_back(std::move(core_exit));
	}

	status = level.validate_and_canonicalize();
	if (!status.ok()) return status;
	r_level = std::move(level);
	return lts::ok_status();
}

Status LevelTaskLevelDefinition::validate_core() const {
	lts::LevelDefinition level;
	return to_core_level(level);
}

std::uint64_t LevelTaskLevelDefinition::get_core_fingerprint() const {
	lts::LevelDefinition level;
	if (!to_core_level(level).ok()) return lts::INVALID_CATALOG_FINGERPRINT;
	return level.fingerprint();
}

void LevelTaskLevelDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskLevelDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskLevelDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskLevelDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskLevelDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_display_name_key", "key"), &LevelTaskLevelDefinition::set_display_name_key);
	ClassDB::bind_method(D_METHOD("get_display_name_key"), &LevelTaskLevelDefinition::get_display_name_key);
	ClassDB::bind_method(D_METHOD("set_description_key", "key"), &LevelTaskLevelDefinition::set_description_key);
	ClassDB::bind_method(D_METHOD("get_description_key"), &LevelTaskLevelDefinition::get_description_key);
	ClassDB::bind_method(D_METHOD("set_scene_resource", "resource"), &LevelTaskLevelDefinition::set_scene_resource);
	ClassDB::bind_method(D_METHOD("get_scene_resource"), &LevelTaskLevelDefinition::get_scene_resource);
	ClassDB::bind_method(D_METHOD("set_availability_rules", "rules"), &LevelTaskLevelDefinition::set_availability_rules);
	ClassDB::bind_method(D_METHOD("get_availability_rules"), &LevelTaskLevelDefinition::get_availability_rules);
	ClassDB::bind_method(D_METHOD("set_entry_graph_identifiers", "identifiers"), &LevelTaskLevelDefinition::set_entry_graph_identifiers);
	ClassDB::bind_method(D_METHOD("get_entry_graph_identifiers"), &LevelTaskLevelDefinition::get_entry_graph_identifiers);
	ClassDB::bind_method(D_METHOD("set_anchors", "anchors"), &LevelTaskLevelDefinition::set_anchors);
	ClassDB::bind_method(D_METHOD("get_anchors"), &LevelTaskLevelDefinition::get_anchors);
	ClassDB::bind_method(D_METHOD("set_exits", "exits"), &LevelTaskLevelDefinition::set_exits);
	ClassDB::bind_method(D_METHOD("get_exits"), &LevelTaskLevelDefinition::get_exits);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.level.example"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_GROUP("Localized Metadata", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "display_name_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"level.example.title"), "set_display_name_key", "get_display_name_key");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "description_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"level.example.description"), "set_description_key", "get_description_key");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "scene_resource", PROPERTY_HINT_FILE, "*.tscn,*.scn,*.res"),
			"set_scene_resource", "get_scene_resource");
	ADD_GROUP("Availability and Entry", "");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "availability_rules", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskFactPredicate", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_availability_rules", "get_availability_rules");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "entry_graph_identifiers"),
			"set_entry_graph_identifiers", "get_entry_graph_identifiers");
	ADD_GROUP("Scene Anchors and Exits", "");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "anchors", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskLevelAnchorDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_anchors", "get_anchors");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "exits", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskLevelExitDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_exits", "get_exits");
}

// -------------------------------------------------------------------------
// Conversation resources
// -------------------------------------------------------------------------

void LevelTaskConversationChoiceDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationChoiceDefinition::set_label_key(const StringName &p_key) {
	label_key = p_key;
	emit_changed();
}

void LevelTaskConversationChoiceDefinition::set_target_step_identifier(const StringName &p_identifier) {
	target_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationChoiceDefinition::set_conditions(const TypedArray<LevelTaskFactPredicate> &p_conditions) {
	conditions = p_conditions;
	emit_changed();
}

Status LevelTaskConversationChoiceDefinition::to_core_choice(lts::ConversationChoiceDefinition &r_choice) const {
	lts::ConversationChoiceDefinition choice;
	Status status = copy_local_name(identifier, choice.identifier);
	if (!status.ok()) return status;
	status = copy_local_name(label_key, choice.label_key);
	if (!status.ok()) return status;
	status = copy_local_name(target_step_identifier, choice.target_step_identifier);
	if (!status.ok()) return status;
	if (conditions.size() > static_cast<int>(lts::MAX_CHOICE_CONDITIONS)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_CHOICE_LIMIT,
				static_cast<std::uint64_t>(conditions.size()));
	}
	choice.conditions.reserve(static_cast<std::size_t>(conditions.size()));
	for (int index = 0; index < conditions.size(); ++index) {
		const Ref<LevelTaskFactPredicate> condition = conditions[index];
		lts::FactPredicate core_condition;
		status = copy_predicate_resource(condition, core_condition);
		if (!status.ok()) return status;
		choice.conditions.push_back(std::move(core_condition));
	}
	status = lts::validate_and_canonicalize(choice);
	if (!status.ok()) return status;
	r_choice = std::move(choice);
	return lts::ok_status();
}

Status LevelTaskConversationChoiceDefinition::validate_core() const {
	lts::ConversationChoiceDefinition choice;
	return to_core_choice(choice);
}

void LevelTaskConversationChoiceDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskConversationChoiceDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskConversationChoiceDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_label_key", "key"), &LevelTaskConversationChoiceDefinition::set_label_key);
	ClassDB::bind_method(D_METHOD("get_label_key"), &LevelTaskConversationChoiceDefinition::get_label_key);
	ClassDB::bind_method(D_METHOD("set_target_step_identifier", "identifier"), &LevelTaskConversationChoiceDefinition::set_target_step_identifier);
	ClassDB::bind_method(D_METHOD("get_target_step_identifier"), &LevelTaskConversationChoiceDefinition::get_target_step_identifier);
	ClassDB::bind_method(D_METHOD("set_conditions", "conditions"), &LevelTaskConversationChoiceDefinition::set_conditions);
	ClassDB::bind_method(D_METHOD("get_conditions"), &LevelTaskConversationChoiceDefinition::get_conditions);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"accept"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "label_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"conversation.example.accept"), "set_label_key", "get_label_key");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"accepted"), "set_target_step_identifier", "get_target_step_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "conditions", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskFactPredicate", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_conditions", "get_conditions");
}

void LevelTaskConversationStepDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_kind(StepKind p_kind) {
	kind = p_kind;
	notify_property_list_changed();
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_speaker_identifier(const StringName &p_identifier) {
	speaker_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_line_key(const StringName &p_key) {
	line_key = p_key;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_parameters(const TypedArray<LevelTaskLocalizedParameter> &p_parameters) {
	parameters = p_parameters;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_next_step_identifier(const StringName &p_identifier) {
	next_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_provider_identifier(const StringName &p_identifier) {
	provider_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_conditions(const TypedArray<LevelTaskFactPredicate> &p_conditions) {
	conditions = p_conditions;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_true_step_identifier(const StringName &p_identifier) {
	true_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_false_step_identifier(const StringName &p_identifier) {
	false_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_success_step_identifier(const StringName &p_identifier) {
	success_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_failure_step_identifier(const StringName &p_identifier) {
	failure_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_choices(const TypedArray<LevelTaskConversationChoiceDefinition> &p_choices) {
	choices = p_choices;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_target_step_identifier(const StringName &p_identifier) {
	target_step_identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationStepDefinition::set_outcome_identifier(const StringName &p_identifier) {
	outcome_identifier = p_identifier;
	emit_changed();
}

Status LevelTaskConversationStepDefinition::to_core_step(lts::ConversationStepDefinition &r_step) const {
	lts::ConversationStepDefinition step;
	Status status = copy_local_name(identifier, step.identifier);
	if (!status.ok()) return status;
	if (kind < STEP_LINE || kind > STEP_OUTCOME) return invalid_enum(static_cast<int>(kind));
	step.kind = static_cast<lts::ConversationStepKind>(static_cast<int>(kind) + 1);

	status = copy_name(speaker_identifier, step.speaker_identifier);
	if (!status.ok()) return status;
	status = copy_localization_key(line_key, step.line_key);
	if (!status.ok()) return status;
	status = copy_local_name(next_step_identifier, step.next_step_identifier);
	if (!status.ok()) return status;
	status = copy_name(provider_identifier, step.provider_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(true_step_identifier, step.true_step_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(false_step_identifier, step.false_step_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(success_step_identifier, step.success_step_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(failure_step_identifier, step.failure_step_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(target_step_identifier, step.target_step_identifier);
	if (!status.ok()) return status;
	status = copy_local_name(outcome_identifier, step.outcome_identifier);
	if (!status.ok()) return status;

	if (parameters.size() > static_cast<int>(lts::MAX_LINE_PARAMETERS)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(parameters.size()));
	}
	step.parameters.reserve(static_cast<std::size_t>(parameters.size()));
	for (int index = 0; index < parameters.size(); ++index) {
		const Ref<LevelTaskLocalizedParameter> parameter = parameters[index];
		lts::LocalizedParameter core_parameter;
		status = copy_parameter_resource(parameter, core_parameter);
		if (!status.ok()) return status;
		step.parameters.push_back(std::move(core_parameter));
	}
	if (conditions.size() > static_cast<int>(lts::MAX_CHOICE_CONDITIONS)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				static_cast<std::uint64_t>(conditions.size()));
	}
	step.conditions.reserve(static_cast<std::size_t>(conditions.size()));
	for (int index = 0; index < conditions.size(); ++index) {
		const Ref<LevelTaskFactPredicate> condition = conditions[index];
		lts::FactPredicate core_condition;
		status = copy_predicate_resource(condition, core_condition);
		if (!status.ok()) return status;
		step.conditions.push_back(std::move(core_condition));
	}
	if (choices.size() > static_cast<int>(lts::MAX_CHOICES_PER_CONVERSATION_STEP)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_CHOICE_LIMIT,
				static_cast<std::uint64_t>(choices.size()));
	}
	step.choices.reserve(static_cast<std::size_t>(choices.size()));
	for (int index = 0; index < choices.size(); ++index) {
		const Ref<LevelTaskConversationChoiceDefinition> choice = choices[index];
		lts::ConversationChoiceDefinition core_choice;
		status = copy_choice_resource(choice, core_choice);
		if (!status.ok()) return status;
		step.choices.push_back(std::move(core_choice));
	}

	status = lts::validate_and_canonicalize(step);
	if (!status.ok()) return status;
	r_step = std::move(step);
	return lts::ok_status();
}

Status LevelTaskConversationStepDefinition::validate_core() const {
	lts::ConversationStepDefinition step;
	return to_core_step(step);
}

void LevelTaskConversationStepDefinition::_validate_property(PropertyInfo &p_property) const {
	const StringName name = p_property.name;
	const bool line = kind == STEP_LINE;
	const bool choice = kind == STEP_CHOICE;
	const bool condition = kind == STEP_CONDITION;
	const bool action = kind == STEP_EXTERNAL_ACTION;
	const bool jump = kind == STEP_JUMP;
	const bool outcome = kind == STEP_OUTCOME;
	if ((name == StringName("speaker_identifier") || name == StringName("line_key") ||
			name == StringName("parameters") || name == StringName("next_step_identifier")) && !line) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if ((name == StringName("provider_identifier") || name == StringName("conditions") ||
			name == StringName("true_step_identifier") || name == StringName("false_step_identifier")) && !condition) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if ((name == StringName("success_step_identifier") || name == StringName("failure_step_identifier")) && !action) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("choices") && !choice) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("target_step_identifier") && !jump) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
	if (name == StringName("outcome_identifier") && !outcome) {
		p_property.usage &= ~PROPERTY_USAGE_EDITOR;
	}
}

void LevelTaskConversationStepDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskConversationStepDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_kind", "kind"), &LevelTaskConversationStepDefinition::set_kind);
	ClassDB::bind_method(D_METHOD("get_kind"), &LevelTaskConversationStepDefinition::get_kind);
	ClassDB::bind_method(D_METHOD("set_speaker_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_speaker_identifier);
	ClassDB::bind_method(D_METHOD("get_speaker_identifier"), &LevelTaskConversationStepDefinition::get_speaker_identifier);
	ClassDB::bind_method(D_METHOD("set_line_key", "key"), &LevelTaskConversationStepDefinition::set_line_key);
	ClassDB::bind_method(D_METHOD("get_line_key"), &LevelTaskConversationStepDefinition::get_line_key);
	ClassDB::bind_method(D_METHOD("set_parameters", "parameters"), &LevelTaskConversationStepDefinition::set_parameters);
	ClassDB::bind_method(D_METHOD("get_parameters"), &LevelTaskConversationStepDefinition::get_parameters);
	ClassDB::bind_method(D_METHOD("set_next_step_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_next_step_identifier);
	ClassDB::bind_method(D_METHOD("get_next_step_identifier"), &LevelTaskConversationStepDefinition::get_next_step_identifier);
	ClassDB::bind_method(D_METHOD("set_provider_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_provider_identifier);
	ClassDB::bind_method(D_METHOD("get_provider_identifier"), &LevelTaskConversationStepDefinition::get_provider_identifier);
	ClassDB::bind_method(D_METHOD("set_conditions", "conditions"), &LevelTaskConversationStepDefinition::set_conditions);
	ClassDB::bind_method(D_METHOD("get_conditions"), &LevelTaskConversationStepDefinition::get_conditions);
	ClassDB::bind_method(D_METHOD("set_true_step_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_true_step_identifier);
	ClassDB::bind_method(D_METHOD("get_true_step_identifier"), &LevelTaskConversationStepDefinition::get_true_step_identifier);
	ClassDB::bind_method(D_METHOD("set_false_step_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_false_step_identifier);
	ClassDB::bind_method(D_METHOD("get_false_step_identifier"), &LevelTaskConversationStepDefinition::get_false_step_identifier);
	ClassDB::bind_method(D_METHOD("set_success_step_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_success_step_identifier);
	ClassDB::bind_method(D_METHOD("get_success_step_identifier"), &LevelTaskConversationStepDefinition::get_success_step_identifier);
	ClassDB::bind_method(D_METHOD("set_failure_step_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_failure_step_identifier);
	ClassDB::bind_method(D_METHOD("get_failure_step_identifier"), &LevelTaskConversationStepDefinition::get_failure_step_identifier);
	ClassDB::bind_method(D_METHOD("set_choices", "choices"), &LevelTaskConversationStepDefinition::set_choices);
	ClassDB::bind_method(D_METHOD("get_choices"), &LevelTaskConversationStepDefinition::get_choices);
	ClassDB::bind_method(D_METHOD("set_target_step_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_target_step_identifier);
	ClassDB::bind_method(D_METHOD("get_target_step_identifier"), &LevelTaskConversationStepDefinition::get_target_step_identifier);
	ClassDB::bind_method(D_METHOD("set_outcome_identifier", "identifier"), &LevelTaskConversationStepDefinition::set_outcome_identifier);
	ClassDB::bind_method(D_METHOD("get_outcome_identifier"), &LevelTaskConversationStepDefinition::get_outcome_identifier);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"line_intro"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM,
			"Line,Choice,Condition,External Action,Jump,Outcome"), "set_kind", "get_kind");
	ADD_GROUP("Line", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "speaker_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.speaker.example"), "set_speaker_identifier", "get_speaker_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "line_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"conversation.example.line"), "set_line_key", "get_line_key");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "parameters", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskLocalizedParameter", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_parameters", "get_parameters");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "next_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"next_line"), "set_next_step_identifier", "get_next_step_identifier");
	ADD_GROUP("Condition and Action", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "provider_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.provider.condition"), "set_provider_identifier", "get_provider_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "conditions", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskFactPredicate", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_conditions", "get_conditions");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "true_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"when_true"), "set_true_step_identifier", "get_true_step_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "false_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"when_false"), "set_false_step_identifier", "get_false_step_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "success_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"on_success"), "set_success_step_identifier", "get_success_step_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "failure_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"on_failure"), "set_failure_step_identifier", "get_failure_step_identifier");
	ADD_GROUP("Choice, Jump, and Outcome", "");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "choices", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskConversationChoiceDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_choices", "get_choices");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "target_step_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"target"), "set_target_step_identifier", "get_target_step_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "outcome_identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"success"), "set_outcome_identifier", "get_outcome_identifier");

	BIND_ENUM_CONSTANT(STEP_LINE);
	BIND_ENUM_CONSTANT(STEP_CHOICE);
	BIND_ENUM_CONSTANT(STEP_CONDITION);
	BIND_ENUM_CONSTANT(STEP_EXTERNAL_ACTION);
	BIND_ENUM_CONSTANT(STEP_JUMP);
	BIND_ENUM_CONSTANT(STEP_OUTCOME);
}

void LevelTaskSpeakerDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskSpeakerDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskSpeakerDefinition::set_display_name_key(const StringName &p_key) {
	display_name_key = p_key;
	emit_changed();
}

void LevelTaskSpeakerDefinition::set_portrait_key(const StringName &p_key) {
	portrait_key = p_key;
	emit_changed();
}

Status LevelTaskSpeakerDefinition::to_core_speaker(lts::SpeakerDefinition &r_speaker) const {
	lts::SpeakerDefinition speaker;
	Status status = copy_name(identifier, speaker.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, speaker.schema_version);
	if (!status.ok()) return status;
	status = copy_localization_key(display_name_key, speaker.display_name_key);
	if (!status.ok()) return status;
	status = copy_localization_key(portrait_key, speaker.portrait_key);
	if (!status.ok()) return status;
	status = speaker.validate();
	if (!status.ok()) return status;
	r_speaker = std::move(speaker);
	return lts::ok_status();
}

Status LevelTaskSpeakerDefinition::validate_core() const {
	lts::SpeakerDefinition speaker;
	return to_core_speaker(speaker);
}

std::uint64_t LevelTaskSpeakerDefinition::get_core_fingerprint() const {
	lts::SpeakerDefinition speaker;
	if (!to_core_speaker(speaker).ok()) return lts::INVALID_CATALOG_FINGERPRINT;
	return speaker.fingerprint();
}

void LevelTaskSpeakerDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskSpeakerDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskSpeakerDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskSpeakerDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskSpeakerDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_display_name_key", "key"), &LevelTaskSpeakerDefinition::set_display_name_key);
	ClassDB::bind_method(D_METHOD("get_display_name_key"), &LevelTaskSpeakerDefinition::get_display_name_key);
	ClassDB::bind_method(D_METHOD("set_portrait_key", "key"), &LevelTaskSpeakerDefinition::set_portrait_key);
	ClassDB::bind_method(D_METHOD("get_portrait_key"), &LevelTaskSpeakerDefinition::get_portrait_key);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.speaker.example"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "display_name_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"speaker.example.name"), "set_display_name_key", "get_display_name_key");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "portrait_key", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"speaker.example.portrait"), "set_portrait_key", "get_portrait_key");
}

void LevelTaskConversationDefinition::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskConversationDefinition::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskConversationDefinition::set_entry_label(const StringName &p_label) {
	entry_label = p_label;
	emit_changed();
}

void LevelTaskConversationDefinition::set_speaker_identifiers(const PackedStringArray &p_identifiers) {
	speaker_identifiers = p_identifiers;
	emit_changed();
}

void LevelTaskConversationDefinition::set_terminal_outcomes(const PackedStringArray &p_outcomes) {
	terminal_outcomes = p_outcomes;
	emit_changed();
}

void LevelTaskConversationDefinition::set_steps(const TypedArray<LevelTaskConversationStepDefinition> &p_steps) {
	steps = p_steps;
	emit_changed();
}

void LevelTaskConversationDefinition::set_max_steps_per_advance(int p_limit) {
	max_steps_per_advance = p_limit;
	emit_changed();
}

void LevelTaskConversationDefinition::set_max_jumps_per_advance(int p_limit) {
	max_jumps_per_advance = p_limit;
	emit_changed();
}

Status LevelTaskConversationDefinition::to_core_conversation(lts::ConversationDefinition &r_conversation) const {
	lts::ConversationDefinition conversation;
	Status status = copy_name(identifier, conversation.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, conversation.schema_version);
	if (!status.ok()) return status;
	status = copy_local_name(entry_label, conversation.entry_label);
	if (!status.ok()) return status;
	status = copy_name_array<std::string>(speaker_identifiers, lts::MAX_SPEAKERS_PER_CONVERSATION,
			conversation.speaker_identifiers);
	if (!status.ok()) return status;
	status = copy_name_array<std::string>(terminal_outcomes, lts::MAX_TERMINAL_OUTCOMES,
			conversation.terminal_outcomes, DiagnosticId::CONVERSATION_OUTCOME_INVALID);
	if (!status.ok()) return status;
	if (steps.size() > static_cast<int>(lts::MAX_STEPS_PER_CONVERSATION)) {
		return lts::make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::CONVERSATION_STEP_LIMIT,
				static_cast<std::uint64_t>(steps.size()));
	}
	conversation.steps.reserve(static_cast<std::size_t>(steps.size()));
	for (int index = 0; index < steps.size(); ++index) {
		const Ref<LevelTaskConversationStepDefinition> step = steps[index];
		lts::ConversationStepDefinition core_step;
		status = copy_step_resource(step, core_step);
		if (!status.ok()) return status;
		conversation.steps.push_back(std::move(core_step));
	}
	if (max_steps_per_advance < 0 || max_jumps_per_advance < 0) {
		return invalid_integer(max_steps_per_advance < 0 ? max_steps_per_advance : max_jumps_per_advance);
	}
	conversation.max_steps_per_advance = static_cast<std::uint32_t>(max_steps_per_advance);
	conversation.max_jumps_per_advance = static_cast<std::uint32_t>(max_jumps_per_advance);
	status = conversation.validate_and_canonicalize();
	if (!status.ok()) return status;
	r_conversation = std::move(conversation);
	return lts::ok_status();
}

Status LevelTaskConversationDefinition::validate_core() const {
	lts::ConversationDefinition conversation;
	return to_core_conversation(conversation);
}

std::uint64_t LevelTaskConversationDefinition::get_core_fingerprint() const {
	lts::ConversationDefinition conversation;
	if (!to_core_conversation(conversation).ok()) return lts::INVALID_CATALOG_FINGERPRINT;
	return conversation.fingerprint();
}

void LevelTaskConversationDefinition::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskConversationDefinition::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskConversationDefinition::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskConversationDefinition::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskConversationDefinition::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_entry_label", "label"), &LevelTaskConversationDefinition::set_entry_label);
	ClassDB::bind_method(D_METHOD("get_entry_label"), &LevelTaskConversationDefinition::get_entry_label);
	ClassDB::bind_method(D_METHOD("set_speaker_identifiers", "identifiers"), &LevelTaskConversationDefinition::set_speaker_identifiers);
	ClassDB::bind_method(D_METHOD("get_speaker_identifiers"), &LevelTaskConversationDefinition::get_speaker_identifiers);
	ClassDB::bind_method(D_METHOD("set_terminal_outcomes", "outcomes"), &LevelTaskConversationDefinition::set_terminal_outcomes);
	ClassDB::bind_method(D_METHOD("get_terminal_outcomes"), &LevelTaskConversationDefinition::get_terminal_outcomes);
	ClassDB::bind_method(D_METHOD("set_steps", "steps"), &LevelTaskConversationDefinition::set_steps);
	ClassDB::bind_method(D_METHOD("get_steps"), &LevelTaskConversationDefinition::get_steps);
	ClassDB::bind_method(D_METHOD("set_max_steps_per_advance", "limit"), &LevelTaskConversationDefinition::set_max_steps_per_advance);
	ClassDB::bind_method(D_METHOD("get_max_steps_per_advance"), &LevelTaskConversationDefinition::get_max_steps_per_advance);
	ClassDB::bind_method(D_METHOD("set_max_jumps_per_advance", "limit"), &LevelTaskConversationDefinition::set_max_jumps_per_advance);
	ClassDB::bind_method(D_METHOD("get_max_jumps_per_advance"), &LevelTaskConversationDefinition::get_max_jumps_per_advance);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.conversation.example"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "entry_label", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"intro"), "set_entry_label", "get_entry_label");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "speaker_identifiers"),
			"set_speaker_identifiers", "get_speaker_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "terminal_outcomes"),
			"set_terminal_outcomes", "get_terminal_outcomes");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "steps", PROPERTY_HINT_ARRAY_TYPE,
			vformat("%d/%d:LevelTaskConversationStepDefinition", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE)),
			"set_steps", "get_steps");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_steps_per_advance", PROPERTY_HINT_RANGE,
			"1,1024,1,or_greater"), "set_max_steps_per_advance", "get_max_steps_per_advance");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_jumps_per_advance", PROPERTY_HINT_RANGE,
			"1,256,1,or_greater"), "set_max_jumps_per_advance", "get_max_jumps_per_advance");
}

// -------------------------------------------------------------------------
// Provider declarations
// -------------------------------------------------------------------------

void LevelTaskProviderDeclaration::set_identifier(const StringName &p_identifier) {
	identifier = p_identifier;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_schema_version(int p_schema_version) {
	schema_version = p_schema_version;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_kind(ProviderKind p_kind) {
	kind = p_kind;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_request_type(LevelTaskValue::ValueType p_type) {
	request_type = p_type;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_response_type(LevelTaskValue::ValueType p_type) {
	response_type = p_type;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_max_request_bytes(int p_bytes) {
	max_request_bytes = p_bytes;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_max_response_bytes(int p_bytes) {
	max_response_bytes = p_bytes;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_deterministic(bool p_deterministic) {
	deterministic = p_deterministic;
	emit_changed();
}

void LevelTaskProviderDeclaration::set_authority_only(bool p_authority_only) {
	authority_only = p_authority_only;
	emit_changed();
}

Status LevelTaskProviderDeclaration::to_core_provider(lts::ProviderDeclaration &r_provider) const {
	lts::ProviderDeclaration provider;
	Status status = copy_name(identifier, provider.identifier);
	if (!status.ok()) return status;
	status = copy_schema_version(schema_version, provider.schema_version);
	if (!status.ok()) return status;
	if (kind < PROVIDER_FACT || kind > PROVIDER_CONVERSATION) return invalid_enum(static_cast<int>(kind));
	if (request_type < LevelTaskValue::VALUE_NONE || request_type > LevelTaskValue::VALUE_BYTES) {
		return invalid_enum(static_cast<int>(request_type));
	}
	if (response_type < LevelTaskValue::VALUE_NONE || response_type > LevelTaskValue::VALUE_BYTES) {
		return invalid_enum(static_cast<int>(response_type));
	}
	if (max_request_bytes < 0 || max_response_bytes < 0) {
		return invalid_integer(max_request_bytes < 0 ? max_request_bytes : max_response_bytes);
	}
	provider.kind = static_cast<lts::ProviderKind>(static_cast<int>(kind) + 1);
	provider.request_type = static_cast<lts::ValueType>(static_cast<int>(request_type));
	provider.response_type = static_cast<lts::ValueType>(static_cast<int>(response_type));
	provider.max_request_bytes = static_cast<std::uint32_t>(max_request_bytes);
	provider.max_response_bytes = static_cast<std::uint32_t>(max_response_bytes);
	provider.deterministic = deterministic;
	provider.authority_only = authority_only;
	status = provider.validate();
	if (!status.ok()) return status;
	r_provider = std::move(provider);
	return lts::ok_status();
}

Status LevelTaskProviderDeclaration::validate_core() const {
	lts::ProviderDeclaration provider;
	return to_core_provider(provider);
}

std::uint64_t LevelTaskProviderDeclaration::get_core_fingerprint() const {
	lts::ProviderDeclaration provider;
	if (!to_core_provider(provider).ok()) return lts::INVALID_CATALOG_FINGERPRINT;
	return provider.fingerprint();
}

void LevelTaskProviderDeclaration::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_identifier", "identifier"), &LevelTaskProviderDeclaration::set_identifier);
	ClassDB::bind_method(D_METHOD("get_identifier"), &LevelTaskProviderDeclaration::get_identifier);
	ClassDB::bind_method(D_METHOD("set_schema_version", "schema_version"), &LevelTaskProviderDeclaration::set_schema_version);
	ClassDB::bind_method(D_METHOD("get_schema_version"), &LevelTaskProviderDeclaration::get_schema_version);
	ClassDB::bind_method(D_METHOD("set_kind", "kind"), &LevelTaskProviderDeclaration::set_kind);
	ClassDB::bind_method(D_METHOD("get_kind"), &LevelTaskProviderDeclaration::get_kind);
	ClassDB::bind_method(D_METHOD("set_request_type", "type"), &LevelTaskProviderDeclaration::set_request_type);
	ClassDB::bind_method(D_METHOD("get_request_type"), &LevelTaskProviderDeclaration::get_request_type);
	ClassDB::bind_method(D_METHOD("set_response_type", "type"), &LevelTaskProviderDeclaration::set_response_type);
	ClassDB::bind_method(D_METHOD("get_response_type"), &LevelTaskProviderDeclaration::get_response_type);
	ClassDB::bind_method(D_METHOD("set_max_request_bytes", "bytes"), &LevelTaskProviderDeclaration::set_max_request_bytes);
	ClassDB::bind_method(D_METHOD("get_max_request_bytes"), &LevelTaskProviderDeclaration::get_max_request_bytes);
	ClassDB::bind_method(D_METHOD("set_max_response_bytes", "bytes"), &LevelTaskProviderDeclaration::set_max_response_bytes);
	ClassDB::bind_method(D_METHOD("get_max_response_bytes"), &LevelTaskProviderDeclaration::get_max_response_bytes);
	ClassDB::bind_method(D_METHOD("set_deterministic", "deterministic"), &LevelTaskProviderDeclaration::set_deterministic);
	ClassDB::bind_method(D_METHOD("get_deterministic"), &LevelTaskProviderDeclaration::get_deterministic);
	ClassDB::bind_method(D_METHOD("set_authority_only", "authority_only"), &LevelTaskProviderDeclaration::set_authority_only);
	ClassDB::bind_method(D_METHOD("get_authority_only"), &LevelTaskProviderDeclaration::get_authority_only);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "identifier", PROPERTY_HINT_PLACEHOLDER_TEXT,
			"game.provider.action"), "set_identifier", "get_identifier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "schema_version", PROPERTY_HINT_RANGE,
			"1,65535,1,or_greater"), "set_schema_version", "get_schema_version");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "kind", PROPERTY_HINT_ENUM,
			"Fact,Event,Condition,Action,Reward,Level Transition,Conversation"),
			"set_kind", "get_kind");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "request_type", PROPERTY_HINT_ENUM,
			"None,Boolean,Integer,Fixed,String,Identifier,Bytes"),
			"set_request_type", "get_request_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "response_type", PROPERTY_HINT_ENUM,
			"None,Boolean,Integer,Fixed,String,Identifier,Bytes"),
			"set_response_type", "get_response_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_request_bytes", PROPERTY_HINT_RANGE,
			"0,4096,1,or_greater"), "set_max_request_bytes", "get_max_request_bytes");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_response_bytes", PROPERTY_HINT_RANGE,
			"0,4096,1,or_greater"), "set_max_response_bytes", "get_max_response_bytes");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "deterministic"), "set_deterministic", "get_deterministic");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "authority_only"), "set_authority_only", "get_authority_only");

	BIND_ENUM_CONSTANT(PROVIDER_FACT);
	BIND_ENUM_CONSTANT(PROVIDER_EVENT);
	BIND_ENUM_CONSTANT(PROVIDER_CONDITION);
	BIND_ENUM_CONSTANT(PROVIDER_ACTION);
	BIND_ENUM_CONSTANT(PROVIDER_REWARD);
	BIND_ENUM_CONSTANT(PROVIDER_LEVEL_TRANSITION);
	BIND_ENUM_CONSTANT(PROVIDER_CONVERSATION);
}

} // namespace godot
