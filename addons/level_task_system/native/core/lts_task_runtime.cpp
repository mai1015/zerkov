#include "core/lts_task_runtime.h"

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

Status runtime_status(
		StatusCode p_code,
		DiagnosticId p_diagnostic = DiagnosticId::GRAPH_PAYLOAD_INVALID,
		std::uint64_t p_detail = 0) {
	return make_status(p_code, p_diagnostic, p_detail);
}

bool known_instance_status(TaskGraphInstanceStatus p_status) {
	switch (p_status) {
		case TaskGraphInstanceStatus::INVALID:
		case TaskGraphInstanceStatus::RUNNING:
		case TaskGraphInstanceStatus::SUCCEEDED:
		case TaskGraphInstanceStatus::FAILED:
		case TaskGraphInstanceStatus::CANCELLED:
		case TaskGraphInstanceStatus::STALLED:
			return true;
	}
	return false;
}

bool known_node_state(TaskNodeInstanceState p_state) {
	switch (p_state) {
		case TaskNodeInstanceState::INACTIVE:
		case TaskNodeInstanceState::ACTIVE:
		case TaskNodeInstanceState::PENDING:
		case TaskNodeInstanceState::COMPLETED:
		case TaskNodeInstanceState::FAILED:
			return true;
	}
	return false;
}

bool known_request_kind(TaskExternalRequestKind p_kind) {
	switch (p_kind) {
		case TaskExternalRequestKind::ACTION:
		case TaskExternalRequestKind::REWARD:
		case TaskExternalRequestKind::CONVERSATION:
		case TaskExternalRequestKind::LEVEL_TRANSITION:
			return true;
	}
	return false;
}

bool known_resolution(TaskRequestResolution p_resolution) {
	switch (p_resolution) {
		case TaskRequestResolution::ACKNOWLEDGED:
		case TaskRequestResolution::REJECTED:
		case TaskRequestResolution::TIMED_OUT:
			return true;
	}
	return false;
}

bool known_trace_kind(TaskTraceKind p_kind) {
	switch (p_kind) {
		case TaskTraceKind::EVENT_ACCEPTED:
		case TaskTraceKind::FACT_SNAPSHOT_ACCEPTED:
		case TaskTraceKind::NODE_ACTIVATED:
		case TaskTraceKind::NODE_COUNTER_CHANGED:
		case TaskTraceKind::NODE_COMPLETED:
		case TaskTraceKind::EDGE_TRAVERSED:
		case TaskTraceKind::REQUEST_EMITTED:
		case TaskTraceKind::REQUEST_RESOLVED:
		case TaskTraceKind::REQUEST_DUPLICATE:
		case TaskTraceKind::GRAPH_STATUS_CHANGED:
			return true;
	}
	return false;
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
		const std::size_t value_size = encoded_value_size(value);
		if (result > std::numeric_limits<std::size_t>::max() - value_size) return std::numeric_limits<std::size_t>::max();
		result += value_size;
	}
	return result;
}

Status validate_optional_global_identifier(const std::string &p_value) {
	return p_value.empty() ? ok_status() : validate_identifier(p_value);
}

Status validate_optional_local_identifier(const std::string &p_value) {
	return p_value.empty() ? ok_status() : validate_local_identifier(p_value);
}

bool value_compare(const Value &p_actual, const Value &p_expected, ComparisonOperator p_operator) {
	if (p_actual.type != p_expected.type) return false;
	if (p_operator == ComparisonOperator::EQUAL) return p_actual == p_expected;
	if (p_operator == ComparisonOperator::NOT_EQUAL) return p_actual != p_expected;
	if (p_actual.type == ValueType::NONE) return false;
	if (p_operator == ComparisonOperator::LESS) return p_actual < p_expected;
	if (p_operator == ComparisonOperator::LESS_OR_EQUAL) return p_actual < p_expected || p_actual == p_expected;
	if (p_operator == ComparisonOperator::GREATER) return p_expected < p_actual;
	if (p_operator == ComparisonOperator::GREATER_OR_EQUAL) return p_expected < p_actual || p_actual == p_expected;
	return false;
}

std::string request_kind_prefix(TaskExternalRequestKind p_kind) {
	switch (p_kind) {
		case TaskExternalRequestKind::ACTION:
			return "action";
		case TaskExternalRequestKind::REWARD:
			return "reward";
		case TaskExternalRequestKind::CONVERSATION:
			return "conversation";
		case TaskExternalRequestKind::LEVEL_TRANSITION:
			return "level_transition";
	}
	return "unknown";
}

std::string digest_hex(std::uint64_t p_digest) {
	static const char digits[] = "0123456789abcdef";
	std::string result(16, '0');
	for (std::size_t index = 0; index < 16; ++index) {
		const std::size_t shift = (15U - index) * 4U;
		result[index] = digits[static_cast<std::size_t>((p_digest >> shift) & 0x0fULL)];
	}
	return result;
}

// ---------------------------------------------------------------------------
// Task runtime snapshot codec
// ---------------------------------------------------------------------------

// The task runtime deliberately uses its own envelope kind while sharing the
// protocol, canonical-format, and snapshot-schema axes with the conversation
// runtime.  The payload is a fixed-order little-endian stream; vectors are
// length-prefixed and every decoded length is checked before allocation.
constexpr const char *TASK_RUNTIME_SNAPSHOT_MAGIC = "lts.task_graph.snapshot.v1";

Status snapshot_invalid(DiagnosticId p_diagnostic = DiagnosticId::TRUNCATED_PAYLOAD, std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_ARGUMENT, p_diagnostic, p_detail);
}

Status snapshot_limit(std::uint64_t p_detail) {
	return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_detail);
}

class TaskSnapshotWriter {
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

class TaskSnapshotReader {
public:
	explicit TaskSnapshotReader(const std::vector<std::uint8_t> &p_bytes) : bytes(p_bytes) {}

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
		if (length > p_limit || offset > bytes.size() || static_cast<std::size_t>(length) > bytes.size() - offset) return false;
		r_value.assign(reinterpret_cast<const char *>(bytes.data() + offset), length);
		offset += length;
		return true;
	}

	bool exhausted() const { return offset == bytes.size(); }

private:
	const std::vector<std::uint8_t> &bytes;
	std::size_t offset = 0;
};

void encode_snapshot_value(TaskSnapshotWriter &r_writer, const Value &p_value) {
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
		case ValueType::BYTES: {
			const ByteVector &value = std::get<ByteVector>(p_value.payload);
			r_writer.write_u32(static_cast<std::uint32_t>(value.size()));
			for (std::uint8_t byte : value) r_writer.write_u8(byte);
			break;
		}
	}
}

bool decode_snapshot_value(TaskSnapshotReader &r_reader, Value &r_value) {
	std::uint8_t raw_type = 0;
	if (!r_reader.read_u8(raw_type) || !is_known_value_type(static_cast<ValueType>(raw_type))) return false;
	const ValueType type = static_cast<ValueType>(raw_type);
	switch (type) {
		case ValueType::NONE:
			r_value = Value::none();
			return true;
		case ValueType::BOOLEAN: {
			std::uint8_t value = 0;
			if (!r_reader.read_u8(value) || value > 1U) return false;
			r_value = Value::boolean(value != 0U);
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

void encode_snapshot_values(TaskSnapshotWriter &r_writer, const std::vector<Value> &p_values) {
	r_writer.write_u32(static_cast<std::uint32_t>(p_values.size()));
	for (const Value &value : p_values) encode_snapshot_value(r_writer, value);
}

bool decode_snapshot_values(
		TaskSnapshotReader &r_reader,
		std::vector<Value> &r_values,
		std::size_t p_count_limit,
		std::size_t p_byte_limit) {
	std::uint32_t count = 0;
	if (!r_reader.read_u32(count) || count > p_count_limit) return false;
	r_values.clear();
	r_values.reserve(count);
	for (std::uint32_t index = 0; index < count; ++index) {
		Value value;
		if (!decode_snapshot_value(r_reader, value) || !value.validate().ok()) return false;
		r_values.push_back(std::move(value));
	}
	return encoded_values_size(r_values) <= p_byte_limit;
}

void encode_snapshot_facts(TaskSnapshotWriter &r_writer, const TaskFactSnapshot &p_facts) {
	r_writer.write_string(p_facts.scope_key());
	r_writer.write_u32(static_cast<std::uint32_t>(p_facts.facts().size()));
	for (const TaskFact &fact : p_facts.facts()) {
		r_writer.write_string(fact.provider_identifier);
		r_writer.write_string(fact.fact_identifier);
		encode_snapshot_value(r_writer, fact.value);
	}
}

bool decode_snapshot_facts(TaskSnapshotReader &r_reader, TaskFactSnapshot &r_facts) {
	std::string scope_key;
	std::uint32_t count = 0;
	if (!r_reader.read_string(scope_key, MAX_IDENTIFIER_BYTES) || !r_reader.read_u32(count) || count > MAX_FACTS_PER_SNAPSHOT) return false;
	TaskFactSnapshot candidate;
	if (!candidate.set_scope_key(scope_key).ok()) return false;
	for (std::uint32_t index = 0; index < count; ++index) {
		TaskFact fact;
		if (!r_reader.read_string(fact.provider_identifier, MAX_IDENTIFIER_BYTES) ||
				!r_reader.read_string(fact.fact_identifier, MAX_IDENTIFIER_BYTES) || !decode_snapshot_value(r_reader, fact.value)) {
			return false;
		}
		if (!candidate.add(fact).ok()) return false;
	}
	r_facts = std::move(candidate);
	return true;
}

void encode_snapshot_limits(TaskSnapshotWriter &r_writer, const TaskRuntimeLimits &p_limits) {
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_facts_per_snapshot));
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_events_per_advance));
	r_writer.write_u32(p_limits.max_transitions_per_advance);
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_pending_requests));
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_transition_records));
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_state_change_records));
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_trace_records));
	r_writer.write_u64(static_cast<std::uint64_t>(p_limits.max_resolved_request_records));
	r_writer.write_u64(p_limits.request_timeout_ticks);
}

bool decode_snapshot_limits(TaskSnapshotReader &r_reader, TaskRuntimeLimits &r_limits) {
	std::uint64_t max_facts = 0;
	std::uint64_t max_events = 0;
	std::uint32_t max_transitions = 0;
	std::uint64_t max_pending = 0;
	std::uint64_t max_transition_records = 0;
	std::uint64_t max_state_change_records = 0;
	std::uint64_t max_trace_records = 0;
	std::uint64_t max_resolved = 0;
	std::uint64_t timeout_ticks = 0;
	if (!r_reader.read_u64(max_facts) || !r_reader.read_u64(max_events) || !r_reader.read_u32(max_transitions) ||
			!r_reader.read_u64(max_pending) || !r_reader.read_u64(max_transition_records) ||
			!r_reader.read_u64(max_state_change_records) || !r_reader.read_u64(max_trace_records) ||
			!r_reader.read_u64(max_resolved) || !r_reader.read_u64(timeout_ticks)) {
		return false;
	}
	if (max_facts > std::numeric_limits<std::size_t>::max() || max_events > std::numeric_limits<std::size_t>::max() ||
			max_pending > std::numeric_limits<std::size_t>::max() || max_transition_records > std::numeric_limits<std::size_t>::max() ||
			max_state_change_records > std::numeric_limits<std::size_t>::max() || max_trace_records > std::numeric_limits<std::size_t>::max() ||
			max_resolved > std::numeric_limits<std::size_t>::max()) {
		return false;
	}
	r_limits.max_facts_per_snapshot = static_cast<std::size_t>(max_facts);
	r_limits.max_events_per_advance = static_cast<std::size_t>(max_events);
	r_limits.max_transitions_per_advance = max_transitions;
	r_limits.max_pending_requests = static_cast<std::size_t>(max_pending);
	r_limits.max_transition_records = static_cast<std::size_t>(max_transition_records);
	r_limits.max_state_change_records = static_cast<std::size_t>(max_state_change_records);
	r_limits.max_trace_records = static_cast<std::size_t>(max_trace_records);
	r_limits.max_resolved_request_records = static_cast<std::size_t>(max_resolved);
	r_limits.request_timeout_ticks = timeout_ticks;
	return true;
}

void encode_snapshot_request(TaskSnapshotWriter &r_writer, const TaskExternalRequest &p_request) {
	r_writer.write_string(p_request.request_identifier);
	r_writer.write_u8(static_cast<std::uint8_t>(p_request.kind));
	r_writer.write_string(p_request.instance_identifier);
	r_writer.write_string(p_request.scope_key);
	r_writer.write_string(p_request.node_identifier);
	r_writer.write_string(p_request.provider_identifier);
	r_writer.write_string(p_request.conversation_identifier);
	r_writer.write_string(p_request.target_level_identifier);
	r_writer.write_string(p_request.target_exit_identifier);
	r_writer.write_string(p_request.target_anchor_identifier);
	encode_snapshot_values(r_writer, p_request.parameters);
	r_writer.write_u64(p_request.created_revision);
	r_writer.write_u64(p_request.created_tick);
	r_writer.write_u64(p_request.timeout_tick);
	r_writer.write_u8(p_request.has_timeout ? 1U : 0U);
}

bool decode_snapshot_request(TaskSnapshotReader &r_reader, TaskExternalRequest &r_request) {
	std::uint8_t raw_kind = 0;
	std::uint8_t has_timeout = 0;
	if (!r_reader.read_string(r_request.request_identifier, MAX_IDENTIFIER_BYTES) || !r_reader.read_u8(raw_kind) ||
			!r_reader.read_string(r_request.instance_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.scope_key, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.node_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.provider_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.conversation_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.target_level_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.target_exit_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_request.target_anchor_identifier, MAX_IDENTIFIER_BYTES) ||
			!decode_snapshot_values(r_reader, r_request.parameters, MAX_NODE_PARAMETERS, MAX_PROVIDER_PAYLOAD_BYTES) ||
			!r_reader.read_u64(r_request.created_revision) || !r_reader.read_u64(r_request.created_tick) ||
			!r_reader.read_u64(r_request.timeout_tick) || !r_reader.read_u8(has_timeout) || has_timeout > 1U) {
		return false;
	}
	r_request.kind = static_cast<TaskExternalRequestKind>(raw_kind);
	r_request.has_timeout = has_timeout != 0U;
	return true;
}

void encode_snapshot_resolution(TaskSnapshotWriter &r_writer, const TaskRequestResolutionRecord &p_record) {
	r_writer.write_string(p_record.request_identifier);
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.kind));
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.resolution));
	r_writer.write_string(p_record.outcome_identifier);
	encode_snapshot_value(r_writer, p_record.response);
	r_writer.write_u64(p_record.revision);
}

bool decode_snapshot_resolution(TaskSnapshotReader &r_reader, TaskRequestResolutionRecord &r_record) {
	std::uint8_t raw_kind = 0;
	std::uint8_t raw_resolution = 0;
	if (!r_reader.read_string(r_record.request_identifier, MAX_IDENTIFIER_BYTES) || !r_reader.read_u8(raw_kind) ||
			!r_reader.read_u8(raw_resolution) || !r_reader.read_string(r_record.outcome_identifier, MAX_IDENTIFIER_BYTES) ||
			!decode_snapshot_value(r_reader, r_record.response) || !r_reader.read_u64(r_record.revision)) {
		return false;
	}
	r_record.kind = static_cast<TaskExternalRequestKind>(raw_kind);
	r_record.resolution = static_cast<TaskRequestResolution>(raw_resolution);
	return true;
}

void encode_snapshot_transition(TaskSnapshotWriter &r_writer, const TaskTransitionRecord &p_record) {
	r_writer.write_u64(p_record.revision);
	r_writer.write_u32(p_record.ordinal);
	r_writer.write_string(p_record.from_node_identifier);
	r_writer.write_string(p_record.to_node_identifier);
	r_writer.write_string(p_record.edge_identifier);
	r_writer.write_string(p_record.output_port_identifier);
}

bool decode_snapshot_transition(TaskSnapshotReader &r_reader, TaskTransitionRecord &r_record) {
	return r_reader.read_u64(r_record.revision) && r_reader.read_u32(r_record.ordinal) &&
			r_reader.read_string(r_record.from_node_identifier, MAX_IDENTIFIER_BYTES) &&
			r_reader.read_string(r_record.to_node_identifier, MAX_IDENTIFIER_BYTES) &&
			r_reader.read_string(r_record.edge_identifier, MAX_IDENTIFIER_BYTES) &&
			r_reader.read_string(r_record.output_port_identifier, MAX_IDENTIFIER_BYTES);
}

void encode_snapshot_state_change(TaskSnapshotWriter &r_writer, const TaskStateChangeRecord &p_record) {
	r_writer.write_u64(p_record.revision);
	r_writer.write_u32(p_record.ordinal);
	r_writer.write_string(p_record.node_identifier);
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.previous_state));
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.current_state));
	r_writer.write_u32(p_record.previous_counter);
	r_writer.write_u32(p_record.current_counter);
	r_writer.write_string(p_record.request_identifier);
	r_writer.write_string(p_record.outcome_identifier);
}

bool decode_snapshot_state_change(TaskSnapshotReader &r_reader, TaskStateChangeRecord &r_record) {
	std::uint8_t raw_previous = 0;
	std::uint8_t raw_current = 0;
	if (!r_reader.read_u64(r_record.revision) || !r_reader.read_u32(r_record.ordinal) ||
			!r_reader.read_string(r_record.node_identifier, MAX_IDENTIFIER_BYTES) || !r_reader.read_u8(raw_previous) ||
			!r_reader.read_u8(raw_current) || !r_reader.read_u32(r_record.previous_counter) ||
			!r_reader.read_u32(r_record.current_counter) || !r_reader.read_string(r_record.request_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_record.outcome_identifier, MAX_IDENTIFIER_BYTES)) {
		return false;
	}
	r_record.previous_state = static_cast<TaskNodeInstanceState>(raw_previous);
	r_record.current_state = static_cast<TaskNodeInstanceState>(raw_current);
	return true;
}

void encode_snapshot_trace(TaskSnapshotWriter &r_writer, const TaskTraceRecord &p_record) {
	r_writer.write_u64(p_record.revision);
	r_writer.write_u32(p_record.ordinal);
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.kind));
	r_writer.write_string(p_record.node_identifier);
	r_writer.write_string(p_record.request_identifier);
	r_writer.write_string(p_record.event_identifier);
	r_writer.write_string(p_record.outcome_identifier);
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.previous_state));
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.current_state));
	r_writer.write_u8(static_cast<std::uint8_t>(p_record.graph_status));
}

bool decode_snapshot_trace(TaskSnapshotReader &r_reader, TaskTraceRecord &r_record) {
	std::uint8_t raw_kind = 0;
	std::uint8_t raw_previous = 0;
	std::uint8_t raw_current = 0;
	std::uint8_t raw_status = 0;
	if (!r_reader.read_u64(r_record.revision) || !r_reader.read_u32(r_record.ordinal) || !r_reader.read_u8(raw_kind) ||
			!r_reader.read_string(r_record.node_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_record.request_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_record.event_identifier, MAX_IDENTIFIER_BYTES) ||
			!r_reader.read_string(r_record.outcome_identifier, MAX_IDENTIFIER_BYTES) || !r_reader.read_u8(raw_previous) ||
			!r_reader.read_u8(raw_current) || !r_reader.read_u8(raw_status)) {
		return false;
	}
	r_record.kind = static_cast<TaskTraceKind>(raw_kind);
	r_record.previous_state = static_cast<TaskNodeInstanceState>(raw_previous);
	r_record.current_state = static_cast<TaskNodeInstanceState>(raw_current);
	r_record.graph_status = static_cast<TaskGraphInstanceStatus>(raw_status);
	return true;
}

} // namespace

// ---------------------------------------------------------------------------
// Facts and events
// ---------------------------------------------------------------------------

Status TaskFact::validate() const {
	Status status = validate_identifier(provider_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(fact_identifier);
	if (!status.ok()) return status;
	return value.validate();
}

bool TaskFact::operator==(const TaskFact &p_other) const {
	return provider_identifier == p_other.provider_identifier && fact_identifier == p_other.fact_identifier && value == p_other.value;
}

bool TaskFact::operator<(const TaskFact &p_other) const {
	if (provider_identifier != p_other.provider_identifier) return identifier_less(provider_identifier, p_other.provider_identifier);
	if (fact_identifier != p_other.fact_identifier) return identifier_less(fact_identifier, p_other.fact_identifier);
	return value < p_other.value;
}

TaskFactSnapshot::TaskFactSnapshot(const std::string &p_scope_key) {
	set_scope_key(p_scope_key);
}

Status TaskFactSnapshot::set_scope_key(const std::string &p_scope_key) {
	Status status = validate_optional_global_identifier(p_scope_key);
	if (!status.ok()) return status;
	scope_key_ = p_scope_key;
	return ok_status();
}

Status TaskFactSnapshot::add(const TaskFact &p_fact) {
	Status status = p_fact.validate();
	if (!status.ok()) return status;
	if (facts_.size() >= MAX_FACTS_PER_SNAPSHOT) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, facts_.size() + 1);
	}
	const auto found = std::lower_bound(facts_.begin(), facts_.end(), p_fact,
			[](const TaskFact &p_left, const TaskFact &p_right) {
				if (p_left.provider_identifier != p_right.provider_identifier) {
					return identifier_less(p_left.provider_identifier, p_right.provider_identifier);
				}
				return identifier_less(p_left.fact_identifier, p_right.fact_identifier);
			});
	if (found != facts_.end() && found->provider_identifier == p_fact.provider_identifier && found->fact_identifier == p_fact.fact_identifier) {
		return runtime_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, facts_.size());
	}
	facts_.insert(found, p_fact);
	return ok_status();
}

Status TaskFactSnapshot::set(const TaskFact &p_fact) {
	Status status = p_fact.validate();
	if (!status.ok()) return status;
	const auto found = std::lower_bound(facts_.begin(), facts_.end(), p_fact,
			[](const TaskFact &p_left, const TaskFact &p_right) {
				if (p_left.provider_identifier != p_right.provider_identifier) {
					return identifier_less(p_left.provider_identifier, p_right.provider_identifier);
				}
				return identifier_less(p_left.fact_identifier, p_right.fact_identifier);
			});
	if (found != facts_.end() && found->provider_identifier == p_fact.provider_identifier && found->fact_identifier == p_fact.fact_identifier) {
		*found = p_fact;
		return ok_status();
	}
	if (facts_.size() >= MAX_FACTS_PER_SNAPSHOT) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, facts_.size() + 1);
	}
	facts_.insert(found, p_fact);
	return ok_status();
}

void TaskFactSnapshot::clear() {
	facts_.clear();
}

Status TaskFactSnapshot::validate(std::size_t p_limit) const {
	if (p_limit == 0 || p_limit > MAX_FACTS_PER_SNAPSHOT) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_limit);
	}
	Status status = validate_optional_global_identifier(scope_key_);
	if (!status.ok()) return status;
	if (facts_.size() > p_limit) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, facts_.size());
	}
	for (std::size_t index = 0; index < facts_.size(); ++index) {
		status = facts_[index].validate();
		if (!status.ok()) return status;
		if (index > 0) {
			const TaskFact &previous = facts_[index - 1];
			if (previous.provider_identifier > facts_[index].provider_identifier ||
					(previous.provider_identifier == facts_[index].provider_identifier &&
							previous.fact_identifier >= facts_[index].fact_identifier)) {
				return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::CANONICAL_ORDER_VIOLATION, index);
			}
		}
	}
	return ok_status();
}

const TaskFact *TaskFactSnapshot::find(const std::string &p_provider_identifier, const std::string &p_fact_identifier) const {
	const auto found = std::lower_bound(facts_.begin(), facts_.end(), std::make_pair(p_provider_identifier, p_fact_identifier),
			[](const TaskFact &p_fact, const std::pair<std::string, std::string> &p_key) {
				if (p_fact.provider_identifier != p_key.first) return identifier_less(p_fact.provider_identifier, p_key.first);
				return identifier_less(p_fact.fact_identifier, p_key.second);
			});
	if (found == facts_.end() || found->provider_identifier != p_provider_identifier || found->fact_identifier != p_fact_identifier) return nullptr;
	return &*found;
}

Status TaskFactSnapshot::evaluate(const FactPredicate &p_predicate, bool &r_matches) const {
	r_matches = false;
	Status status = p_predicate.validate();
	if (!status.ok()) return status;
	const TaskFact *fact = find(p_predicate.provider_identifier, p_predicate.fact_identifier);
	if (fact == nullptr) return ok_status();
	r_matches = value_compare(fact->value, p_predicate.expected, p_predicate.comparator);
	return ok_status();
}

bool TaskFactSnapshot::matches(const FactPredicate &p_predicate) const {
	bool result = false;
	return evaluate(p_predicate, result).ok() && result;
}

Status TaskFactSnapshot::evaluate_all(const std::vector<FactPredicate> &p_predicates, bool &r_matches) const {
	r_matches = true;
	if (p_predicates.size() > MAX_EVENT_FILTERS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_predicates.size());
	}
	for (const FactPredicate &predicate : p_predicates) {
		bool matches_predicate = false;
		Status status = evaluate(predicate, matches_predicate);
		if (!status.ok()) return status;
		if (!matches_predicate) {
			r_matches = false;
			return ok_status();
		}
	}
	return ok_status();
}

TaskEvent TaskEvent::make(
		const std::string &p_provider_identifier,
		const std::string &p_event_identifier,
		std::uint64_t p_sequence,
		std::uint32_t p_amount) {
	TaskEvent event;
	event.provider_identifier = p_provider_identifier;
	event.event_identifier = p_event_identifier;
	event.sequence = p_sequence;
	event.amount = p_amount;
	return event;
}

Status TaskEvent::validate() const {
	Status status = validate_identifier(provider_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(event_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(scope_key);
	if (!status.ok()) return status;
	status = value.validate();
	if (!status.ok()) return status;
	if (amount == 0 || amount > MAX_OBJECTIVE_TARGET) {
		return runtime_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE, amount);
	}
	if (filters.size() > MAX_EVENT_FILTERS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, filters.size());
	}
	for (const FactPredicate &filter : filters) {
		status = filter.validate();
		if (!status.ok()) return status;
	}
	return ok_status();
}

bool TaskEvent::operator==(const TaskEvent &p_other) const {
	return sequence == p_other.sequence && provider_identifier == p_other.provider_identifier &&
			event_identifier == p_other.event_identifier && scope_key == p_other.scope_key && value == p_other.value &&
			amount == p_other.amount && filters == p_other.filters;
}

// ---------------------------------------------------------------------------
// Runtime records and limits
// ---------------------------------------------------------------------------

Status TaskRuntimeLimits::validate() const {
	if (max_facts_per_snapshot == 0 || max_facts_per_snapshot > MAX_FACTS_PER_SNAPSHOT) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_facts_per_snapshot);
	}
	if (max_events_per_advance == 0 || max_events_per_advance > MAX_EVENTS_PER_ADVANCE) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_events_per_advance);
	}
	if (max_transitions_per_advance == 0 || max_transitions_per_advance > MAX_TRANSITIONS_PER_ADVANCE) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_transitions_per_advance);
	}
	if (max_pending_requests == 0 || max_pending_requests > MAX_PENDING_REQUESTS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_pending_requests);
	}
	if (max_transition_records == 0 || max_transition_records > MAX_TRANSITION_RECORDS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_transition_records);
	}
	if (max_state_change_records == 0 || max_state_change_records > MAX_STATE_CHANGE_RECORDS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_state_change_records);
	}
	if (max_trace_records == 0 || max_trace_records > MAX_TRACE_RECORDS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_trace_records);
	}
	if (max_resolved_request_records == 0 || max_resolved_request_records > MAX_RESOLVED_REQUEST_RECORDS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, max_resolved_request_records);
	}
	return ok_status();
}

Status TaskExternalRequest::validate() const {
	Status status = validate_identifier(request_identifier);
	if (!status.ok()) return status;
	if (!known_request_kind(kind)) return runtime_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(kind));
	status = validate_identifier(instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(scope_key);
	if (!status.ok()) return status;
	status = validate_optional_local_identifier(node_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(provider_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(conversation_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(target_level_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local_identifier(target_exit_identifier);
	if (!status.ok()) return status;
	status = validate_optional_local_identifier(target_anchor_identifier);
	if (!status.ok()) return status;
	if (parameters.size() > MAX_NODE_PARAMETERS) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, parameters.size());
	}
	for (const Value &parameter : parameters) {
		status = parameter.validate();
		if (!status.ok()) return status;
	}
	if (encoded_values_size(parameters) > MAX_PROVIDER_PAYLOAD_BYTES) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, encoded_values_size(parameters));
	}
	switch (kind) {
		case TaskExternalRequestKind::ACTION:
		case TaskExternalRequestKind::REWARD:
			if (node_identifier.empty() || provider_identifier.empty()) {
				return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
		case TaskExternalRequestKind::CONVERSATION:
			if (node_identifier.empty() || conversation_identifier.empty()) {
				return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
		case TaskExternalRequestKind::LEVEL_TRANSITION:
			if (target_level_identifier.empty() || target_exit_identifier.empty() || target_anchor_identifier.empty()) {
				return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
			break;
	}
	if (has_timeout && timeout_tick < created_tick) {
		return runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE, timeout_tick);
	}
	return ok_status();
}

bool TaskExternalRequest::operator==(const TaskExternalRequest &p_other) const {
	return request_identifier == p_other.request_identifier && kind == p_other.kind && instance_identifier == p_other.instance_identifier &&
			scope_key == p_other.scope_key && node_identifier == p_other.node_identifier && provider_identifier == p_other.provider_identifier &&
			conversation_identifier == p_other.conversation_identifier && target_level_identifier == p_other.target_level_identifier &&
			target_exit_identifier == p_other.target_exit_identifier && target_anchor_identifier == p_other.target_anchor_identifier &&
			parameters == p_other.parameters && created_revision == p_other.created_revision && created_tick == p_other.created_tick &&
			timeout_tick == p_other.timeout_tick && has_timeout == p_other.has_timeout;
}

Status TaskRequestResolutionRecord::validate() const {
	Status status = validate_identifier(request_identifier);
	if (!status.ok()) return status;
	if (!known_request_kind(kind) || !known_resolution(resolution)) return runtime_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM);
	status = validate_optional_local_identifier(outcome_identifier);
	if (!status.ok()) return status;
	return response.validate();
}

bool TaskRequestResolutionRecord::operator==(const TaskRequestResolutionRecord &p_other) const {
	return request_identifier == p_other.request_identifier && kind == p_other.kind && resolution == p_other.resolution &&
			outcome_identifier == p_other.outcome_identifier && response == p_other.response && revision == p_other.revision;
}

Status TaskTransitionRecord::validate() const {
	Status status = validate_local_identifier(from_node_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(to_node_identifier);
	if (!status.ok()) return status;
	status = validate_local_identifier(edge_identifier);
	if (!status.ok()) return status;
	return validate_local_identifier(output_port_identifier);
}

bool TaskTransitionRecord::operator==(const TaskTransitionRecord &p_other) const {
	return revision == p_other.revision && ordinal == p_other.ordinal && from_node_identifier == p_other.from_node_identifier &&
			to_node_identifier == p_other.to_node_identifier && edge_identifier == p_other.edge_identifier &&
			output_port_identifier == p_other.output_port_identifier;
}

Status TaskStateChangeRecord::validate() const {
	Status status = validate_local_identifier(node_identifier);
	if (!status.ok()) return status;
	if (!known_node_state(previous_state) || !known_node_state(current_state)) return runtime_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM);
	status = validate_optional_global_identifier(request_identifier);
	if (!status.ok()) return status;
	return validate_optional_local_identifier(outcome_identifier);
}

bool TaskStateChangeRecord::operator==(const TaskStateChangeRecord &p_other) const {
	return revision == p_other.revision && ordinal == p_other.ordinal && node_identifier == p_other.node_identifier &&
			previous_state == p_other.previous_state && current_state == p_other.current_state &&
			previous_counter == p_other.previous_counter && current_counter == p_other.current_counter &&
			request_identifier == p_other.request_identifier && outcome_identifier == p_other.outcome_identifier;
}

Status TaskTraceRecord::validate() const {
	if (!known_trace_kind(kind) || !known_node_state(previous_state) || !known_node_state(current_state) || !known_instance_status(graph_status)) {
		return runtime_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM);
	}
	Status status = validate_optional_local_identifier(node_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(request_identifier);
	if (!status.ok()) return status;
	status = validate_optional_global_identifier(event_identifier);
	if (!status.ok()) return status;
	return validate_optional_local_identifier(outcome_identifier);
}

bool TaskTraceRecord::operator==(const TaskTraceRecord &p_other) const {
	return revision == p_other.revision && ordinal == p_other.ordinal && kind == p_other.kind && node_identifier == p_other.node_identifier &&
			request_identifier == p_other.request_identifier && event_identifier == p_other.event_identifier &&
			outcome_identifier == p_other.outcome_identifier && previous_state == p_other.previous_state &&
			current_state == p_other.current_state && graph_status == p_other.graph_status;
}

void TaskAdvanceResult::clear() {
	*this = TaskAdvanceResult{};
}

// ---------------------------------------------------------------------------
// Instance construction and accessors
// ---------------------------------------------------------------------------

TaskGraphInstance::TaskGraphInstance(
		const CanonicalTaskGraph &p_graph,
		const std::string &p_instance_identifier,
		const std::string &p_scope_key,
		const TaskRuntimeLimits &p_limits) {
	(void)initialize(p_graph, p_instance_identifier, p_scope_key, p_limits, nullptr);
}

bool TaskGraphInstance::valid() const {
	return status_ != TaskGraphInstanceStatus::INVALID && graph_.valid() &&
			definition_fingerprint_ != INVALID_CATALOG_FINGERPRINT && !instance_identifier_.empty() && !scope_key_.empty();
}

bool TaskGraphInstance::terminal() const {
	return status_ == TaskGraphInstanceStatus::SUCCEEDED || status_ == TaskGraphInstanceStatus::FAILED ||
			status_ == TaskGraphInstanceStatus::CANCELLED;
}

const TaskNodeRuntimeStateRecord *TaskGraphInstance::node_state(const std::string &p_node_identifier) const {
	const std::uint32_t index = find_canonical_node_index(p_node_identifier);
	return index == std::numeric_limits<std::uint32_t>::max() || index >= node_states_.size() ? nullptr : &node_states_[index];
}

std::uint32_t TaskGraphInstance::node_counter(const std::string &p_node_identifier) const {
	const TaskNodeRuntimeStateRecord *state = node_state(p_node_identifier);
	return state == nullptr ? 0 : state->counter;
}

const TaskExternalRequest *TaskGraphInstance::find_pending_request(const std::string &p_request_identifier) const {
	for (const TaskExternalRequest &request : pending_requests_) {
		if (request.request_identifier == p_request_identifier) return &request;
	}
	return nullptr;
}

const TaskRequestResolutionRecord *TaskGraphInstance::find_resolved_request(const std::string &p_request_identifier) const {
	for (const TaskRequestResolutionRecord &record : resolved_requests_) {
		if (record.request_identifier == p_request_identifier) return &record;
	}
	return nullptr;
}

void TaskGraphInstance::clear_records() {
	transition_records_.clear();
	state_change_records_.clear();
	trace_records_.clear();
	transition_records_truncated_ = false;
	state_change_records_truncated_ = false;
	trace_records_truncated_ = false;
}

Status TaskGraphInstance::validate_start(
		const CanonicalTaskGraph &p_graph,
		const std::string &p_instance_identifier,
		const std::string &p_scope_key,
		const TaskRuntimeLimits &p_limits) const {
	if (!p_graph.valid() || p_graph.fingerprint() == INVALID_CATALOG_FINGERPRINT) {
		return runtime_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	}
	Status status = validate_identifier(p_instance_identifier);
	if (!status.ok()) return status;
	status = validate_identifier(p_scope_key);
	if (!status.ok()) return status;
	status = p_limits.validate();
	if (!status.ok()) return status;
	if (p_graph.nodes().empty() || p_graph.nodes().size() > MAX_NODES_PER_TASK_GRAPH || p_graph.edges().size() > MAX_EDGES_PER_TASK_GRAPH) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::GRAPH_NODE_LIMIT, p_graph.nodes().size());
	}
	if (p_graph.definition().max_transitions_per_advance == 0 ||
			p_graph.definition().max_transitions_per_advance > MAX_TRANSITIONS_PER_ADVANCE) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED,
				p_graph.definition().max_transitions_per_advance);
	}
	if (p_graph.definition().max_transitions_per_advance < 1 || p_limits.max_transitions_per_advance < 1) {
		return runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	return ok_status();
}

Status TaskGraphInstance::create(
		const CanonicalTaskGraph &p_graph,
		const std::string &p_instance_identifier,
		const std::string &p_scope_key,
		TaskGraphInstance &r_instance,
		const TaskRuntimeLimits &p_limits,
		TaskAdvanceResult *r_start_result) {
	TaskGraphInstance candidate;
	Status status = candidate.validate_start(p_graph, p_instance_identifier, p_scope_key, p_limits);
	if (!status.ok()) {
		if (r_start_result != nullptr) {
			r_start_result->clear();
			r_start_result->status = status;
			r_start_result->graph_status = r_instance.status_;
			r_start_result->revision = r_instance.revision_;
		}
		return status;
	}

	candidate.graph_ = p_graph;
	candidate.limits_ = p_limits;
	candidate.instance_identifier_ = p_instance_identifier;
	candidate.scope_key_ = p_scope_key;
	candidate.definition_fingerprint_ = p_graph.fingerprint();
	candidate.status_ = TaskGraphInstanceStatus::RUNNING;
	candidate.node_states_.assign(p_graph.nodes().size(), TaskNodeRuntimeStateRecord{});
	candidate.incoming_edges_arrived_.assign(p_graph.edges().size(), 0U);
	candidate.last_facts_ = TaskFactSnapshot(p_scope_key);

	TaskAdvanceResult local_result;
	status = candidate.bootstrap(local_result);
	if (!status.ok()) {
		if (r_start_result != nullptr) {
			r_start_result->clear();
			r_start_result->status = status;
			r_start_result->graph_status = r_instance.status_;
			r_start_result->revision = r_instance.revision_;
		}
		return status;
	}
	candidate.revision_ = 1;
	candidate.finish_result(local_result);
	r_instance = std::move(candidate);
	if (r_start_result != nullptr) *r_start_result = std::move(local_result);
	return ok_status();
}

Status TaskGraphInstance::initialize(
		const CanonicalTaskGraph &p_graph,
		const std::string &p_instance_identifier,
		const std::string &p_scope_key,
		const TaskRuntimeLimits &p_limits,
		TaskAdvanceResult *r_start_result) {
	return create(p_graph, p_instance_identifier, p_scope_key, *this, p_limits, r_start_result);
}

// ---------------------------------------------------------------------------
// Record helpers and request identity
// ---------------------------------------------------------------------------

std::uint32_t TaskGraphInstance::transition_budget() const {
	return std::min(graph_.definition().max_transitions_per_advance, limits_.max_transitions_per_advance);
}

std::string TaskGraphInstance::make_request_identifier(
		TaskExternalRequestKind p_kind,
		const std::string &p_node_identifier,
		std::uint64_t p_ordinal) const {
	Hasher hasher;
	hasher.write_string("lts.task-request.v1");
	hasher.write_u8(static_cast<std::uint8_t>(p_kind));
	hasher.write_u64(definition_fingerprint_);
	hasher.write_string(instance_identifier_);
	hasher.write_string(scope_key_);
	hasher.write_string(p_node_identifier);
	hasher.write_u64(p_ordinal);
	return "request." + request_kind_prefix(p_kind) + ".r" + digest_hex(hasher.digest());
}

const CanonicalTaskNode *TaskGraphInstance::find_canonical_node(const std::string &p_node_identifier) const {
	return graph_.find_node(p_node_identifier);
}

std::uint32_t TaskGraphInstance::find_canonical_node_index(const std::string &p_node_identifier) const {
	const CanonicalTaskNode *node = find_canonical_node(p_node_identifier);
	return node == nullptr ? std::numeric_limits<std::uint32_t>::max() : node->canonical_index;
}

void TaskGraphInstance::append_retained_transition(const TaskTransitionRecord &p_record) {
	if (transition_records_.size() >= limits_.max_transition_records) {
		transition_records_.erase(transition_records_.begin());
		transition_records_truncated_ = true;
	}
	transition_records_.push_back(p_record);
}

void TaskGraphInstance::append_retained_state_change(const TaskStateChangeRecord &p_record) {
	if (state_change_records_.size() >= limits_.max_state_change_records) {
		state_change_records_.erase(state_change_records_.begin());
		state_change_records_truncated_ = true;
	}
	state_change_records_.push_back(p_record);
}

void TaskGraphInstance::append_retained_trace(const TaskTraceRecord &p_record) {
	if (trace_records_.size() >= limits_.max_trace_records) {
		trace_records_.erase(trace_records_.begin());
		trace_records_truncated_ = true;
	}
	trace_records_.push_back(p_record);
}

void TaskGraphInstance::append_trace(const TaskTraceRecord &p_record, TaskAdvanceResult &r_result) {
	TaskTraceRecord record = p_record;
	record.revision = revision_ + 1;
	record.ordinal = static_cast<std::uint32_t>(r_result.trace.size());
	if (r_result.trace.size() < limits_.max_trace_records) {
		r_result.trace.push_back(record);
	} else {
		r_result.trace_truncated = true;
	}
	append_retained_trace(record);
}

Status TaskGraphInstance::append_state_change(
		std::uint32_t p_node_index,
		TaskNodeInstanceState p_previous_state,
		TaskNodeInstanceState p_current_state,
		std::uint32_t p_previous_counter,
		std::uint32_t p_current_counter,
		const std::string &p_request_identifier,
		const std::string &p_outcome_identifier,
		TaskAdvanceResult &r_result) {
	if (r_result.state_changes.size() >= limits_.max_state_change_records) {
		return runtime_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_result.state_changes.size() + 1);
	}
	if (p_node_index >= graph_.nodes().size()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	TaskStateChangeRecord record;
	record.revision = revision_ + 1;
	record.ordinal = static_cast<std::uint32_t>(r_result.state_changes.size());
	record.node_identifier = graph_.node(p_node_index).identifier();
	record.previous_state = p_previous_state;
	record.current_state = p_current_state;
	record.previous_counter = p_previous_counter;
	record.current_counter = p_current_counter;
	record.request_identifier = p_request_identifier;
	record.outcome_identifier = p_outcome_identifier;
	r_result.state_changes.push_back(record);
	append_retained_state_change(record);
	return ok_status();
}

Status TaskGraphInstance::mutate_node_state(
		std::uint32_t p_node_index,
		TaskNodeInstanceState p_new_state,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count,
		const std::string &p_request_identifier,
		const std::string &p_outcome_identifier) {
	if (p_node_index >= node_states_.size() || p_node_index >= graph_.nodes().size()) {
		return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	}
	TaskNodeRuntimeStateRecord &state = node_states_[p_node_index];
	if (state.state == p_new_state) return ok_status();
	if (r_transition_count >= transition_budget()) {
		return runtime_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_transition_count + 1);
	}
	const TaskNodeInstanceState previous_state = state.state;
	const std::uint32_t previous_counter = state.counter;
	++r_transition_count;
	Status status = append_state_change(p_node_index, previous_state, p_new_state, previous_counter, state.counter,
			p_request_identifier, p_outcome_identifier, r_result);
	if (!status.ok()) return status;
	state.state = p_new_state;
	TaskTraceRecord trace;
	trace.kind = p_new_state == TaskNodeInstanceState::ACTIVE ? TaskTraceKind::NODE_ACTIVATED : TaskTraceKind::NODE_COMPLETED;
	trace.node_identifier = graph_.node(p_node_index).identifier();
	trace.request_identifier = p_request_identifier;
	trace.outcome_identifier = p_outcome_identifier;
	trace.previous_state = previous_state;
	trace.current_state = p_new_state;
	trace.graph_status = status_;
	append_trace(trace, r_result);
	return ok_status();
}

// ---------------------------------------------------------------------------
// Graph evaluation
// ---------------------------------------------------------------------------

Status TaskGraphInstance::bootstrap(TaskAdvanceResult &r_result) {
	r_result.clear();
	if (graph_.entry_node_index() >= graph_.nodes().size()) {
		return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_ENTRY_INVALID, graph_.entry_node_index());
	}
	std::uint32_t transition_count = 0;
	Status status = activate_node(graph_.entry_node_index(), last_facts_, 0, r_result, transition_count);
	if (!status.ok()) return status;
	r_result.changed = true;
	return ok_status();
}

Status TaskGraphInstance::activate_node(
		std::uint32_t p_node_index,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count) {
	if (p_node_index >= graph_.nodes().size() || p_node_index >= node_states_.size()) {
		return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	}
	TaskNodeRuntimeStateRecord &state = node_states_[p_node_index];
	const TaskNodeDefinition &definition = graph_.node(p_node_index).definition;
	if (state.state != TaskNodeInstanceState::INACTIVE) {
		// A gate can be reached by more than one incoming edge.  It remains
		// active after the first branch and must be re-evaluated when each later
		// branch arrives; all other node families are one-shot activations.
		if (state.state != TaskNodeInstanceState::ACTIVE ||
				(definition.kind != TaskNodeKind::ALL_GATE && definition.kind != TaskNodeKind::ANY_GATE)) {
			return ok_status();
		}
		std::size_t arrived = 0;
		const std::vector<std::uint32_t> &incoming = graph_.node(p_node_index).incoming_edge_indices;
		for (std::uint32_t edge_index : incoming) {
			if (edge_index < incoming_edges_arrived_.size() && incoming_edges_arrived_[edge_index] != 0U) ++arrived;
		}
		const bool ready = definition.kind == TaskNodeKind::ANY_GATE ? arrived > 0 : arrived == incoming.size();
		return ready ? complete_node(p_node_index, definition.kind == TaskNodeKind::ANY_GATE ? "any" : "all", p_facts, p_tick,
				r_result, r_transition_count) : ok_status();
	}
	if (definition.kind == TaskNodeKind::SUBGRAPH) {
		return runtime_status(StatusCode::NOT_SUPPORTED, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	}
	Status status = mutate_node_state(p_node_index, TaskNodeInstanceState::ACTIVE, r_result, r_transition_count);
	if (!status.ok()) return status;

	switch (definition.kind) {
		case TaskNodeKind::ENTRY:
			return complete_node(p_node_index, "entry", p_facts, p_tick, r_result, r_transition_count);
		case TaskNodeKind::CONDITION: {
			bool matches = false;
			status = p_facts.evaluate_all(definition.filters, matches);
			if (!status.ok()) return status;
			return complete_node(p_node_index, matches ? "true" : "false", p_facts, p_tick, r_result, r_transition_count);
		}
		case TaskNodeKind::ALL_GATE:
		case TaskNodeKind::ANY_GATE: {
			std::size_t arrived = 0;
			const std::vector<std::uint32_t> &incoming = graph_.node(p_node_index).incoming_edge_indices;
			for (std::uint32_t edge_index : incoming) {
				if (edge_index < incoming_edges_arrived_.size() && incoming_edges_arrived_[edge_index] != 0U) ++arrived;
			}
			const bool ready = definition.kind == TaskNodeKind::ANY_GATE ? arrived > 0 : arrived == incoming.size();
			return ready ? complete_node(p_node_index, definition.kind == TaskNodeKind::ANY_GATE ? "any" : "all", p_facts, p_tick,
					r_result, r_transition_count) : ok_status();
		}
		case TaskNodeKind::EXTERNAL_ACTION:
			return emit_node_request(p_node_index, TaskExternalRequestKind::ACTION, p_tick, r_result, r_transition_count);
		case TaskNodeKind::REWARD_REQUEST:
			return emit_node_request(p_node_index, TaskExternalRequestKind::REWARD, p_tick, r_result, r_transition_count);
		case TaskNodeKind::CONVERSATION:
			return emit_node_request(p_node_index, TaskExternalRequestKind::CONVERSATION, p_tick, r_result, r_transition_count);
		case TaskNodeKind::OBJECTIVE:
			return ok_status();
		case TaskNodeKind::SUCCESS_TERMINAL:
		case TaskNodeKind::FAILURE_TERMINAL:
		case TaskNodeKind::CANCELLED_TERMINAL:
			return complete_node(p_node_index, std::string(), p_facts, p_tick, r_result, r_transition_count);
		case TaskNodeKind::SUBGRAPH:
			break;
	}
	return runtime_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(definition.kind));
}

Status TaskGraphInstance::complete_node(
		std::uint32_t p_node_index,
		const std::string &p_output_port,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count,
		const std::string &p_request_identifier,
		const std::string &p_outcome_identifier) {
	if (p_node_index >= graph_.nodes().size() || p_node_index >= node_states_.size()) {
		return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	}
	const TaskNodeDefinition &definition = graph_.node(p_node_index).definition;
	if (node_states_[p_node_index].state != TaskNodeInstanceState::ACTIVE &&
			node_states_[p_node_index].state != TaskNodeInstanceState::PENDING) {
		return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID, p_node_index);
	}
	Status status = mutate_node_state(p_node_index, TaskNodeInstanceState::COMPLETED, r_result, r_transition_count,
			p_request_identifier, p_outcome_identifier);
	if (!status.ok()) return status;
	if (definition.kind == TaskNodeKind::SUCCESS_TERMINAL || definition.kind == TaskNodeKind::FAILURE_TERMINAL ||
			definition.kind == TaskNodeKind::CANCELLED_TERMINAL) {
		const TaskGraphInstanceStatus previous_status = status_;
		if (definition.kind == TaskNodeKind::SUCCESS_TERMINAL) {
			status_ = TaskGraphInstanceStatus::SUCCEEDED;
		} else if (definition.kind == TaskNodeKind::FAILURE_TERMINAL) {
			status_ = TaskGraphInstanceStatus::FAILED;
		} else {
			status_ = TaskGraphInstanceStatus::CANCELLED;
		}
		terminal_outcome_ = definition.outcome_identifier;
		if (previous_status != status_) {
			TaskTraceRecord trace;
			trace.kind = TaskTraceKind::GRAPH_STATUS_CHANGED;
			trace.node_identifier = definition.identifier;
			trace.outcome_identifier = terminal_outcome_;
			trace.graph_status = status_;
			append_trace(trace, r_result);
		}
		return ok_status();
	}
	if (p_output_port.empty()) return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID, p_node_index);
	return route_output(p_node_index, p_output_port, p_facts, p_tick, r_result, r_transition_count);
}

Status TaskGraphInstance::route_output(
		std::uint32_t p_node_index,
		const std::string &p_output_port,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count) {
	if (p_node_index >= graph_.nodes().size()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	const std::string from_identifier = graph_.node(p_node_index).identifier();
	for (std::uint32_t edge_index : graph_.node(p_node_index).outgoing_edge_indices) {
		if (edge_index >= graph_.edges().size()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, edge_index);
		const CanonicalTaskEdge &edge = graph_.edge(edge_index);
		if (edge.definition.from_port_identifier != p_output_port) continue;
		if (r_transition_count >= transition_budget()) {
			return runtime_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_result.transitions.size() + 1);
		}
		++r_transition_count;
		TaskTransitionRecord transition;
		transition.revision = revision_ + 1;
		transition.ordinal = static_cast<std::uint32_t>(r_result.transitions.size());
		transition.from_node_identifier = from_identifier;
		transition.to_node_identifier = graph_.node(edge.to_node_index).identifier();
		transition.edge_identifier = edge.identifier();
		transition.output_port_identifier = p_output_port;
		r_result.transitions.push_back(transition);
		append_retained_transition(transition);
		TaskTraceRecord trace;
		trace.kind = TaskTraceKind::EDGE_TRAVERSED;
		trace.node_identifier = from_identifier;
		trace.outcome_identifier = p_output_port;
		trace.graph_status = status_;
		append_trace(trace, r_result);
		if (edge_index >= incoming_edges_arrived_.size()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, edge_index);
		incoming_edges_arrived_[edge_index] = 1U;
		Status status = activate_node(edge.to_node_index, p_facts, p_tick, r_result, r_transition_count);
		if (!status.ok()) return status;
	}
	return ok_status();
}

bool TaskGraphInstance::predicate_values_match(const Value &p_actual, const FactPredicate &p_predicate) const {
	return value_compare(p_actual, p_predicate.expected, p_predicate.comparator);
}

bool TaskGraphInstance::event_matches(
		const TaskEvent &p_event,
		const TaskNodeDefinition &p_node,
		const TaskFactSnapshot &p_facts) const {
	if (p_event.provider_identifier != p_node.provider_identifier) return false;
	if (!p_event.scope_key.empty() && p_event.scope_key != scope_key_) return false;
	for (const FactPredicate &filter : p_event.filters) {
		if (!p_facts.matches(filter)) return false;
	}
	for (const FactPredicate &filter : p_node.filters) {
		if (!p_facts.matches(filter)) return false;
	}
	return true;
}

Status TaskGraphInstance::process_events(
		const std::vector<TaskEvent> &p_events,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count) {
	for (const TaskEvent &event : p_events) {
		TaskTraceRecord event_trace;
		event_trace.kind = TaskTraceKind::EVENT_ACCEPTED;
		event_trace.event_identifier = event.event_identifier;
		event_trace.graph_status = status_;
		append_trace(event_trace, r_result);
		if (status_ != TaskGraphInstanceStatus::RUNNING) continue;
		for (std::uint32_t node_index : graph_.topological_order()) {
			if (status_ != TaskGraphInstanceStatus::RUNNING) break;
			if (node_index >= node_states_.size()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, node_index);
			TaskNodeRuntimeStateRecord &state = node_states_[node_index];
			if (state.state != TaskNodeInstanceState::ACTIVE || graph_.node(node_index).kind() != TaskNodeKind::OBJECTIVE) continue;
			const TaskNodeDefinition &definition = graph_.node(node_index).definition;
			if (!event_matches(event, definition, p_facts)) continue;
			std::uint32_t amount = event.amount;
			if (amount == 1 && event.value.type == ValueType::INTEGER && std::holds_alternative<std::int64_t>(event.value.payload)) {
				const std::int64_t value_amount = std::get<std::int64_t>(event.value.payload);
				if (value_amount > 0 && value_amount <= static_cast<std::int64_t>(MAX_OBJECTIVE_TARGET)) {
					amount = static_cast<std::uint32_t>(value_amount);
				}
			}
			const std::uint32_t target = definition.objective_target;
			const std::uint32_t previous_counter = state.counter;
			const std::uint64_t sum = static_cast<std::uint64_t>(state.counter) + amount;
			state.counter = sum >= target ? target : static_cast<std::uint32_t>(sum);
			if (state.counter == previous_counter) continue;
			if (r_transition_count >= transition_budget()) {
				return runtime_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_transition_count + 1);
			}
			++r_transition_count;
			Status status = append_state_change(node_index, state.state, state.state, previous_counter, state.counter, std::string(), std::string(), r_result);
			if (!status.ok()) return status;
			TaskTraceRecord counter_trace;
			counter_trace.kind = TaskTraceKind::NODE_COUNTER_CHANGED;
			counter_trace.node_identifier = definition.identifier;
			counter_trace.previous_state = state.state;
			counter_trace.current_state = state.state;
			counter_trace.graph_status = status_;
			append_trace(counter_trace, r_result);
			if (state.counter >= target) {
				status = complete_node(node_index, "success", p_facts, p_tick, r_result, r_transition_count);
				if (!status.ok()) return status;
			}
		}
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

Status TaskGraphInstance::emit_request(TaskExternalRequest p_request, TaskAdvanceResult &r_result) {
	Status status = p_request.validate();
	if (!status.ok()) return status;
	if (pending_requests_.size() >= limits_.max_pending_requests) {
		return runtime_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, pending_requests_.size() + 1);
	}
	if (find_pending_request(p_request.request_identifier) != nullptr || find_resolved_request(p_request.request_identifier) != nullptr) {
		return runtime_status(StatusCode::ALREADY_EXISTS, DiagnosticId::DEFINITION_DUPLICATE);
	}
	pending_requests_.push_back(p_request);
	r_result.requests.push_back(p_request);
	TaskTraceRecord trace;
	trace.kind = TaskTraceKind::REQUEST_EMITTED;
	trace.node_identifier = p_request.node_identifier;
	trace.request_identifier = p_request.request_identifier;
	trace.graph_status = status_;
	append_trace(trace, r_result);
	return ok_status();
}

Status TaskGraphInstance::emit_node_request(
		std::uint32_t p_node_index,
		TaskExternalRequestKind p_kind,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count) {
	if (p_node_index >= graph_.nodes().size() || p_node_index >= node_states_.size()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, p_node_index);
	const TaskNodeDefinition &definition = graph_.node(p_node_index).definition;
	TaskExternalRequest request;
	request.kind = p_kind;
	request.instance_identifier = instance_identifier_;
	request.scope_key = scope_key_;
	request.node_identifier = definition.identifier;
	request.provider_identifier = definition.kind == TaskNodeKind::CONVERSATION ? std::string() : definition.provider_identifier;
	request.conversation_identifier = definition.conversation_identifier;
	request.parameters = definition.parameters;
	request.created_revision = revision_ + 1;
	request.created_tick = p_tick;
	if (limits_.request_timeout_ticks != 0) {
		if (p_tick > std::numeric_limits<std::uint64_t>::max() - limits_.request_timeout_ticks) {
			return runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
		}
		request.has_timeout = true;
		request.timeout_tick = p_tick + limits_.request_timeout_ticks;
	}
	std::uint64_t ordinal = next_request_ordinal_;
	if (ordinal == std::numeric_limits<std::uint64_t>::max()) return runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
	for (;;) {
		request.request_identifier = make_request_identifier(p_kind, definition.identifier, ordinal);
		if (find_pending_request(request.request_identifier) == nullptr && find_resolved_request(request.request_identifier) == nullptr) break;
		if (ordinal == std::numeric_limits<std::uint64_t>::max()) return runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
		++ordinal;
	}
	next_request_ordinal_ = ordinal + 1;
	Status status = mutate_node_state(p_node_index, TaskNodeInstanceState::PENDING, r_result, r_transition_count, request.request_identifier);
	if (!status.ok()) return status;
	if (node_states_[p_node_index].request_generation == std::numeric_limits<std::uint64_t>::max()) {
		return runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	++node_states_[p_node_index].request_generation;
	return emit_request(std::move(request), r_result);
}

Status TaskGraphInstance::remember_resolution(const TaskRequestResolutionRecord &p_record) {
	Status status = p_record.validate();
	if (!status.ok()) return status;
	for (const TaskRequestResolutionRecord &record : resolved_requests_) {
		if (record.request_identifier == p_record.request_identifier) return ok_status();
	}
	if (resolved_requests_.size() >= limits_.max_resolved_request_records) resolved_requests_.erase(resolved_requests_.begin());
	resolved_requests_.push_back(p_record);
	return ok_status();
}

Status TaskGraphInstance::route_request_resolution(
		const TaskExternalRequest &p_request,
		TaskRequestResolution p_resolution,
		const std::string &p_outcome_identifier,
		const Value &p_response,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count) {
	if (!known_resolution(p_resolution)) return runtime_status(StatusCode::INVALID_ENUM, DiagnosticId::INVALID_ENUM);
	std::string outcome = p_outcome_identifier;
	if (p_resolution == TaskRequestResolution::ACKNOWLEDGED) {
		if (p_request.kind == TaskExternalRequestKind::CONVERSATION) {
			const CanonicalTaskNode *node = find_canonical_node(p_request.node_identifier);
			if (node == nullptr) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
			if (outcome.empty() && p_response.type == ValueType::IDENTIFIER && std::holds_alternative<std::string>(p_response.payload)) {
				outcome = std::get<std::string>(p_response.payload);
			}
			if (outcome.empty() && node->definition.accepted_outcomes.size() == 1) outcome = node->definition.accepted_outcomes.front();
			if (outcome.empty() || std::find(node->definition.accepted_outcomes.begin(), node->definition.accepted_outcomes.end(), outcome) == node->definition.accepted_outcomes.end()) {
				return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_OUTCOME_INVALID);
			}
		} else if (outcome.empty()) {
			outcome = "success";
		}
	} else if (p_resolution == TaskRequestResolution::REJECTED) {
		outcome = "rejected";
	} else {
		outcome = "timeout";
	}
	Status status = validate_local_identifier(outcome);
	if (!status.ok()) return status;

	for (std::size_t index = 0; index < pending_requests_.size(); ++index) {
		if (pending_requests_[index].request_identifier != p_request.request_identifier) continue;
		pending_requests_.erase(pending_requests_.begin() + static_cast<std::ptrdiff_t>(index));
		TaskRequestResolutionRecord record;
		record.request_identifier = p_request.request_identifier;
		record.kind = p_request.kind;
		record.resolution = p_resolution;
		record.outcome_identifier = outcome;
		record.response = p_response;
		record.revision = revision_ + 1;
		status = remember_resolution(record);
		if (!status.ok()) return status;
		r_result.has_resolution = true;
		r_result.resolution = record;
		TaskTraceRecord trace;
		trace.kind = TaskTraceKind::REQUEST_RESOLVED;
		trace.node_identifier = p_request.node_identifier;
		trace.request_identifier = p_request.request_identifier;
		trace.outcome_identifier = outcome;
		trace.graph_status = status_;
		append_trace(trace, r_result);
		if (!p_request.node_identifier.empty()) {
			const std::uint32_t node_index = find_canonical_node_index(p_request.node_identifier);
			if (node_index == std::numeric_limits<std::uint32_t>::max()) return runtime_status(StatusCode::INVALID_REFERENCE, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
			if (node_index >= node_states_.size() || node_states_[node_index].state != TaskNodeInstanceState::PENDING) {
				return runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID, node_index);
			}
			status = complete_node(node_index, outcome, p_facts, p_tick, r_result, r_transition_count, p_request.request_identifier, outcome);
			if (!status.ok()) return status;
		}
		return ok_status();
	}
	return runtime_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
}

Status TaskGraphInstance::expire_requests(
		std::uint64_t p_tick,
		const TaskFactSnapshot &p_facts,
		TaskAdvanceResult &r_result,
		std::uint32_t &r_transition_count) {
	std::size_t index = 0;
	while (index < pending_requests_.size()) {
		const TaskExternalRequest request = pending_requests_[index];
		if (!request.has_timeout || p_tick < request.timeout_tick) {
			++index;
			continue;
		}
		const Status status = route_request_resolution(request, TaskRequestResolution::TIMED_OUT, "timeout", Value::none(), p_facts,
				p_tick, r_result, r_transition_count);
		if (!status.ok()) return status;
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// Public advancement and request acknowledgements
// ---------------------------------------------------------------------------

Status TaskGraphInstance::advance(
		const std::vector<TaskEvent> &p_events,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult *r_result) {
	TaskAdvanceResult local_result;
	Status status = advance_internal(p_events, p_facts, p_tick, local_result, true);
	if (r_result != nullptr) *r_result = local_result;
	return status;
}

Status TaskGraphInstance::advance(
		const std::vector<TaskEvent> &p_events,
		const TaskFactSnapshot &p_facts,
		TaskAdvanceResult *r_result) {
	const std::uint64_t tick_value = has_tick_ ? last_tick_ : 0;
	TaskAdvanceResult local_result;
	Status status = advance_internal(p_events, p_facts, tick_value, local_result, false);
	if (r_result != nullptr) *r_result = local_result;
	return status;
}

Status TaskGraphInstance::tick(
		std::uint64_t p_tick,
		const TaskFactSnapshot &p_facts,
		TaskAdvanceResult *r_result) {
	return advance(std::vector<TaskEvent>{}, p_facts, p_tick, r_result);
}

Status TaskGraphInstance::advance_internal(
		const std::vector<TaskEvent> &p_events,
		const TaskFactSnapshot &p_facts,
		std::uint64_t p_tick,
		TaskAdvanceResult &r_result,
		bool p_tick_supplied) {
	r_result.clear();
	if (!valid()) {
		r_result.status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return r_result.status;
	}
	if (terminal()) {
		r_result.status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_OUTCOME_INVALID);
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return r_result.status;
	}
	if (p_events.size() > limits_.max_events_per_advance) {
		r_result.status = runtime_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_events.size());
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return r_result.status;
	}
	Status status = p_facts.validate(limits_.max_facts_per_snapshot);
	if (!status.ok()) {
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	if (!p_facts.scope_key().empty() && p_facts.scope_key() != scope_key_) {
		status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	TaskFactSnapshot normalized_facts = p_facts;
	if (normalized_facts.scope_key().empty()) {
		status = normalized_facts.set_scope_key(scope_key_);
		if (!status.ok()) {
			r_result.status = status;
			r_result.revision = revision_;
			r_result.graph_status = status_;
			return status;
		}
	}
	if (p_tick_supplied && has_tick_ && p_tick < last_tick_) {
		status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	std::vector<TaskEvent> normalized_events;
	normalized_events.reserve(p_events.size());
	std::uint64_t candidate_sequence = last_event_sequence_;
	bool candidate_has_sequence = has_event_sequence_;
	for (const TaskEvent &event : p_events) {
		status = event.validate();
		if (!status.ok()) {
			r_result.status = status;
			r_result.revision = revision_;
			r_result.graph_status = status_;
			return status;
		}
		if (!event.scope_key.empty() && event.scope_key != scope_key_) {
			status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_PAYLOAD_INVALID);
			r_result.status = status;
			r_result.revision = revision_;
			r_result.graph_status = status_;
			return status;
		}
		TaskEvent normalized = event;
		if (normalized.sequence == 0) {
			if (!candidate_has_sequence) {
				candidate_sequence = 1;
			} else {
				if (candidate_sequence == std::numeric_limits<std::uint64_t>::max()) {
					status = runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
					r_result.status = status;
					r_result.revision = revision_;
					r_result.graph_status = status_;
					return status;
				}
				++candidate_sequence;
			}
			normalized.sequence = candidate_sequence;
			candidate_has_sequence = true;
		} else {
			if (candidate_has_sequence && normalized.sequence <= candidate_sequence) {
				status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, normalized.sequence);
				r_result.status = status;
				r_result.revision = revision_;
				r_result.graph_status = status_;
				return status;
			}
			candidate_sequence = normalized.sequence;
			candidate_has_sequence = true;
		}
		normalized_events.push_back(std::move(normalized));
	}

	TaskGraphInstance candidate = *this;
	const bool facts_changed = candidate.last_facts_ != normalized_facts;
	candidate.last_facts_ = normalized_facts;
	const TaskGraphInstanceStatus previous_status = candidate.status_;
	const std::uint64_t effective_tick = p_tick_supplied ? p_tick : (candidate.has_tick_ ? candidate.last_tick_ : 0);
	if (p_tick_supplied) {
		candidate.last_tick_ = p_tick;
		candidate.has_tick_ = true;
	}
	std::uint32_t transition_count = 0;
	status = candidate.expire_requests(effective_tick, normalized_facts, r_result, transition_count);
	if (status.ok()) status = candidate.process_events(normalized_events, normalized_facts, effective_tick, r_result, transition_count);
	if (!status.ok()) {
		r_result.clear();
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	if (!normalized_events.empty()) {
		candidate.last_event_sequence_ = candidate_sequence;
		candidate.has_event_sequence_ = candidate_has_sequence;
	}
	const bool changed = facts_changed || !normalized_events.empty() || (p_tick_supplied && (!has_tick_ || p_tick != last_tick_)) ||
			!r_result.requests.empty() || !r_result.transitions.empty() || !r_result.state_changes.empty() || previous_status != candidate.status_;
	r_result.changed = changed;
	if (changed) candidate.revision_ = revision_ + 1;
	candidate.finish_result(r_result);
	if (changed) {
		// Record revisions were generated against revision_ + 1, which is the
		// candidate revision selected above.  A no-op keeps the old revision.
		for (TaskExternalRequest &request : r_result.requests) request.created_revision = candidate.revision_;
	}
	*this = std::move(candidate);
	return ok_status();
}

void TaskGraphInstance::finish_result(TaskAdvanceResult &r_result) const {
	r_result.status = ok_status();
	r_result.revision = revision_;
	r_result.graph_status = status_;
}

Status TaskGraphInstance::validate_snapshot_state() const {
	if (!graph_.valid() || graph_.fingerprint() == INVALID_CATALOG_FINGERPRINT ||
			definition_fingerprint_ != graph_.fingerprint()) {
		return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS,
				definition_fingerprint_);
	}
	Status status = limits_.validate();
	if (!status.ok()) return status;
	if (!known_instance_status(status_) || status_ == TaskGraphInstanceStatus::INVALID) {
		return snapshot_invalid(DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(status_));
	}
	if (revision_ == 0) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, revision_);
	status = validate_identifier(instance_identifier_);
	if (!status.ok()) return status;
	status = validate_identifier(scope_key_);
	if (!status.ok()) return status;
	if ((!has_tick_ && last_tick_ != 0) || (!has_event_sequence_ && last_event_sequence_ != 0)) {
		return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	if (node_states_.size() != graph_.nodes().size() || incoming_edges_arrived_.size() != graph_.edges().size()) {
		return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	}
	status = last_facts_.validate(limits_.max_facts_per_snapshot);
	if (!status.ok()) return status;
	if (last_facts_.scope_key() != scope_key_) {
		return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID);
	}

	if (status_ == TaskGraphInstanceStatus::RUNNING || status_ == TaskGraphInstanceStatus::STALLED) {
		if (!terminal_outcome_.empty()) return snapshot_invalid(DiagnosticId::GRAPH_OUTCOME_INVALID);
	} else {
		status = validate_local_identifier(terminal_outcome_);
		if (!status.ok()) return status;
		if (std::find(graph_.definition().terminal_outcomes.begin(), graph_.definition().terminal_outcomes.end(), terminal_outcome_) ==
				graph_.definition().terminal_outcomes.end()) {
			return snapshot_invalid(DiagnosticId::GRAPH_OUTCOME_INVALID);
		}
	}

	std::vector<bool> pending_node_seen(graph_.nodes().size(), false);
	for (std::size_t index = 0; index < node_states_.size(); ++index) {
		const TaskNodeRuntimeStateRecord &state = node_states_[index];
		if (!known_node_state(state.state)) return snapshot_invalid(DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(state.state));
		const TaskNodeDefinition &definition = graph_.node(index).definition;
		if (definition.kind == TaskNodeKind::OBJECTIVE) {
			if (state.counter > definition.objective_target) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, state.counter);
		} else if (state.counter != 0) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		}
		if (definition.kind != TaskNodeKind::EXTERNAL_ACTION && definition.kind != TaskNodeKind::REWARD_REQUEST &&
				definition.kind != TaskNodeKind::CONVERSATION && state.request_generation != 0) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		}
		if (state.state == TaskNodeInstanceState::PENDING &&
				definition.kind != TaskNodeKind::EXTERNAL_ACTION && definition.kind != TaskNodeKind::REWARD_REQUEST &&
				definition.kind != TaskNodeKind::CONVERSATION) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		}
	}
	for (std::uint8_t arrived : incoming_edges_arrived_) {
		if (arrived > 1U) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, arrived);
	}

	if (pending_requests_.size() > MAX_PENDING_REQUESTS || pending_requests_.size() > limits_.max_pending_requests ||
			resolved_requests_.size() > MAX_RESOLVED_REQUEST_RECORDS ||
			resolved_requests_.size() > limits_.max_resolved_request_records) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	for (const TaskExternalRequest &request : pending_requests_) {
		status = request.validate();
		if (!status.ok()) return status;
		if (request.instance_identifier != instance_identifier_ || request.scope_key != scope_key_ || request.created_revision == 0 ||
				request.created_revision > revision_ || (has_tick_ && request.created_tick > last_tick_) ||
				(request.has_timeout && request.timeout_tick < request.created_tick)) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID);
		}
		if (request.kind == TaskExternalRequestKind::LEVEL_TRANSITION) {
			if (!request.node_identifier.empty() || !request.provider_identifier.empty() || !request.conversation_identifier.empty()) {
				return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID);
			}
		} else {
			const std::uint32_t node_index = find_canonical_node_index(request.node_identifier);
			if (node_index == std::numeric_limits<std::uint32_t>::max() || node_index >= node_states_.size() ||
					node_states_[node_index].state != TaskNodeInstanceState::PENDING || node_states_[node_index].request_generation == 0 ||
					pending_node_seen[node_index]) {
				return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, node_index);
			}
			const TaskNodeDefinition &definition = graph_.node(node_index).definition;
			const bool kind_matches =
					(request.kind == TaskExternalRequestKind::ACTION && definition.kind == TaskNodeKind::EXTERNAL_ACTION) ||
					(request.kind == TaskExternalRequestKind::REWARD && definition.kind == TaskNodeKind::REWARD_REQUEST) ||
					(request.kind == TaskExternalRequestKind::CONVERSATION && definition.kind == TaskNodeKind::CONVERSATION);
			if (!kind_matches || request.parameters != definition.parameters) return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, node_index);
			if (request.kind == TaskExternalRequestKind::CONVERSATION) {
				if (!request.provider_identifier.empty() || request.conversation_identifier != definition.conversation_identifier) {
					return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, node_index);
				}
			} else if (request.provider_identifier != definition.provider_identifier ||
					request.conversation_identifier != definition.conversation_identifier) {
				return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, node_index);
			}
			if (!request.target_level_identifier.empty() || !request.target_exit_identifier.empty() ||
					!request.target_anchor_identifier.empty()) {
				return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, node_index);
			}
			pending_node_seen[node_index] = true;
		}
	}
	for (std::size_t index = 0; index < node_states_.size(); ++index) {
		if (node_states_[index].state == TaskNodeInstanceState::PENDING && !pending_node_seen[index]) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, index);
		}
	}

	for (const TaskRequestResolutionRecord &record : resolved_requests_) {
		status = record.validate();
		if (!status.ok()) return status;
		if (record.revision == 0 || record.revision > revision_ || record.outcome_identifier.empty()) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, record.revision);
		}
	}
	for (std::size_t index = 0; index < resolved_requests_.size(); ++index) {
		for (std::size_t previous = 0; previous < index; ++previous) {
			if (resolved_requests_[previous].request_identifier == resolved_requests_[index].request_identifier) {
				return snapshot_invalid(DiagnosticId::DEFINITION_DUPLICATE, index);
			}
		}
		if (find_pending_request(resolved_requests_[index].request_identifier) != nullptr) {
			return snapshot_invalid(DiagnosticId::DEFINITION_DUPLICATE, index);
		}
	}
	for (std::size_t index = 0; index < pending_requests_.size(); ++index) {
		for (std::size_t previous = 0; previous < index; ++previous) {
			if (pending_requests_[previous].request_identifier == pending_requests_[index].request_identifier) {
				return snapshot_invalid(DiagnosticId::DEFINITION_DUPLICATE, index);
			}
		}
		if (find_resolved_request(pending_requests_[index].request_identifier) != nullptr) {
			return snapshot_invalid(DiagnosticId::DEFINITION_DUPLICATE, index);
		}
	}

	if (transition_records_.size() > limits_.max_transition_records || state_change_records_.size() > limits_.max_state_change_records ||
			trace_records_.size() > limits_.max_trace_records) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	for (const TaskTransitionRecord &record : transition_records_) {
		status = record.validate();
		if (!status.ok()) return status;
		if (record.revision == 0 || record.revision > revision_) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, record.revision);
		const CanonicalTaskNode *from = graph_.find_node(record.from_node_identifier);
		const CanonicalTaskNode *to = graph_.find_node(record.to_node_identifier);
		const CanonicalTaskEdge *edge = graph_.find_edge(record.edge_identifier);
		if (from == nullptr || to == nullptr || edge == nullptr || edge->from_node_index != from->canonical_index ||
				edge->to_node_index != to->canonical_index || edge->definition.from_port_identifier != record.output_port_identifier) {
			return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		}
	}
	for (const TaskStateChangeRecord &record : state_change_records_) {
		status = record.validate();
		if (!status.ok()) return status;
		const CanonicalTaskNode *node = find_canonical_node(record.node_identifier);
		if (record.revision == 0 || record.revision > revision_ || node == nullptr) {
			return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, record.revision);
		}
		if (node->kind() == TaskNodeKind::OBJECTIVE) {
			if (record.previous_counter > node->definition.objective_target || record.current_counter > node->definition.objective_target) {
				return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, record.current_counter);
			}
		} else if (record.previous_counter != 0 || record.current_counter != 0) {
			return snapshot_invalid(DiagnosticId::GRAPH_PAYLOAD_INVALID, node->canonical_index);
		}
	}
	for (const TaskTraceRecord &record : trace_records_) {
		status = record.validate();
		if (!status.ok()) return status;
		if (record.revision > revision_) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE, record.revision);
		if (!record.node_identifier.empty() && find_canonical_node(record.node_identifier) == nullptr) {
			return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		}
	}
	if (status_ == TaskGraphInstanceStatus::SUCCEEDED || status_ == TaskGraphInstanceStatus::FAILED ||
			status_ == TaskGraphInstanceStatus::CANCELLED) {
		bool terminal_found = false;
		for (std::size_t index = 0; index < graph_.nodes().size(); ++index) {
			const TaskNodeDefinition &definition = graph_.node(index).definition;
			if ((definition.kind == TaskNodeKind::SUCCESS_TERMINAL || definition.kind == TaskNodeKind::FAILURE_TERMINAL ||
					definition.kind == TaskNodeKind::CANCELLED_TERMINAL) && node_states_[index].state == TaskNodeInstanceState::COMPLETED &&
					definition.outcome_identifier == terminal_outcome_) {
				terminal_found = true;
				break;
			}
		}
		// A graph may have parallel branches. The current runtime marks the
		// graph terminal when a terminal node is reached, while any independently
		// emitted host request remains observable until the host resolves it.
		// Preserve that state in the snapshot instead of rejecting an otherwise
		// valid runtime produced by the evaluator.
		if (!terminal_found) return snapshot_invalid(DiagnosticId::GRAPH_OUTCOME_INVALID);
	}
	return ok_status();
}

Status TaskGraphInstance::encode_snapshot(std::vector<std::uint8_t> &r_bytes) const {
	r_bytes.clear();
	Status status = validate_snapshot_state();
	if (!status.ok()) return status;

	TaskSnapshotWriter writer;
	writer.write_string(TASK_RUNTIME_SNAPSHOT_MAGIC);
	writer.write_u16(TASK_RUNTIME_SNAPSHOT_SCHEMA_VERSION);
	writer.write_u16(PROTOCOL_VERSION);
	writer.write_u16(CANONICAL_FORMAT_VERSION);
	writer.write_u8(TASK_RUNTIME_SNAPSHOT_KIND);
	writer.write_string(graph_.definition().identifier);
	writer.write_u64(definition_fingerprint_);
	writer.write_string(instance_identifier_);
	writer.write_string(scope_key_);
	encode_snapshot_limits(writer, limits_);
	writer.write_u8(static_cast<std::uint8_t>(status_));
	writer.write_u64(revision_);
	writer.write_u8(has_tick_ ? 1U : 0U);
	writer.write_u64(last_tick_);
	writer.write_u8(has_event_sequence_ ? 1U : 0U);
	writer.write_u64(last_event_sequence_);
	writer.write_u64(next_request_ordinal_);
	writer.write_string(terminal_outcome_);

	writer.write_u32(static_cast<std::uint32_t>(node_states_.size()));
	for (const TaskNodeRuntimeStateRecord &state : node_states_) {
		writer.write_u8(static_cast<std::uint8_t>(state.state));
		writer.write_u32(state.counter);
		writer.write_u64(state.request_generation);
	}
	writer.write_u32(static_cast<std::uint32_t>(incoming_edges_arrived_.size()));
	for (std::uint8_t arrived : incoming_edges_arrived_) writer.write_u8(arrived);
	encode_snapshot_facts(writer, last_facts_);

	writer.write_u32(static_cast<std::uint32_t>(pending_requests_.size()));
	for (const TaskExternalRequest &request : pending_requests_) encode_snapshot_request(writer, request);
	writer.write_u32(static_cast<std::uint32_t>(resolved_requests_.size()));
	for (const TaskRequestResolutionRecord &record : resolved_requests_) encode_snapshot_resolution(writer, record);

	writer.write_u32(static_cast<std::uint32_t>(transition_records_.size()));
	for (const TaskTransitionRecord &record : transition_records_) encode_snapshot_transition(writer, record);
	writer.write_u8(transition_records_truncated_ ? 1U : 0U);
	writer.write_u32(static_cast<std::uint32_t>(state_change_records_.size()));
	for (const TaskStateChangeRecord &record : state_change_records_) encode_snapshot_state_change(writer, record);
	writer.write_u8(state_change_records_truncated_ ? 1U : 0U);
	writer.write_u32(static_cast<std::uint32_t>(trace_records_.size()));
	for (const TaskTraceRecord &record : trace_records_) encode_snapshot_trace(writer, record);
	writer.write_u8(trace_records_truncated_ ? 1U : 0U);

	if (writer.bytes.size() > MAX_SNAPSHOT_BYTES) return snapshot_limit(writer.bytes.size());
	r_bytes = std::move(writer.bytes);
	return ok_status();
}

Status TaskGraphInstance::decode_snapshot(const std::vector<std::uint8_t> &p_bytes, TaskGraphInstance &r_instance) const {
	if (p_bytes.size() > MAX_SNAPSHOT_BYTES) return snapshot_limit(p_bytes.size());
	if (!graph_.valid() || graph_.fingerprint() == INVALID_CATALOG_FINGERPRINT || definition_fingerprint_ != graph_.fingerprint()) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	}
	TaskSnapshotReader reader(p_bytes);
	std::string magic;
	if (!reader.read_string(magic, std::string(TASK_RUNTIME_SNAPSHOT_MAGIC).size()) || magic != TASK_RUNTIME_SNAPSHOT_MAGIC) {
		return snapshot_invalid();
	}
	std::uint16_t snapshot_schema = 0;
	std::uint16_t protocol = 0;
	std::uint16_t canonical = 0;
	std::uint8_t kind = 0;
	if (!reader.read_u16(snapshot_schema) || !reader.read_u16(protocol) || !reader.read_u16(canonical) || !reader.read_u8(kind)) {
		return snapshot_invalid();
	}
	if (snapshot_schema != TASK_RUNTIME_SNAPSHOT_SCHEMA_VERSION || protocol != PROTOCOL_VERSION || canonical != CANONICAL_FORMAT_VERSION) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED,
				snapshot_schema != TASK_RUNTIME_SNAPSHOT_SCHEMA_VERSION ? snapshot_schema : (protocol != PROTOCOL_VERSION ? protocol : canonical));
	}
	if (kind != TASK_RUNTIME_SNAPSHOT_KIND) return snapshot_invalid(DiagnosticId::INVALID_ENUM, kind);

	std::string graph_identifier;
	std::uint64_t snapshot_fingerprint = INVALID_CATALOG_FINGERPRINT;
	if (!reader.read_string(graph_identifier, MAX_IDENTIFIER_BYTES) || !reader.read_u64(snapshot_fingerprint)) return snapshot_invalid();
	if (graph_identifier != graph_.definition().identifier) {
		return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(graph_identifier));
	}
	if (snapshot_fingerprint != graph_.fingerprint()) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, snapshot_fingerprint);
	}

	TaskGraphInstance decoded = r_instance;
	decoded.graph_ = graph_;
	decoded.definition_fingerprint_ = graph_.fingerprint();
	if (!reader.read_string(decoded.instance_identifier_, MAX_IDENTIFIER_BYTES) ||
			!reader.read_string(decoded.scope_key_, MAX_IDENTIFIER_BYTES) || !decode_snapshot_limits(reader, decoded.limits_)) {
		return snapshot_invalid();
	}
	std::uint8_t raw_status = 0;
	std::uint8_t has_tick = 0;
	std::uint8_t has_sequence = 0;
	if (!reader.read_u8(raw_status) || !reader.read_u64(decoded.revision_) || !reader.read_u8(has_tick) ||
			!reader.read_u64(decoded.last_tick_) || !reader.read_u8(has_sequence) || !reader.read_u64(decoded.last_event_sequence_) ||
			!reader.read_u64(decoded.next_request_ordinal_) || !reader.read_string(decoded.terminal_outcome_, MAX_IDENTIFIER_BYTES)) {
		return snapshot_invalid();
	}
	if (has_tick > 1U || has_sequence > 1U) return snapshot_invalid(DiagnosticId::VALUE_OUT_OF_RANGE);
	decoded.status_ = static_cast<TaskGraphInstanceStatus>(raw_status);
	decoded.has_tick_ = has_tick != 0U;
	decoded.has_event_sequence_ = has_sequence != 0U;

	std::uint32_t node_count = 0;
	if (!reader.read_u32(node_count) || node_count != decoded.graph_.nodes().size()) {
		return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, node_count);
	}
	decoded.node_states_.clear();
	decoded.node_states_.reserve(node_count);
	for (std::uint32_t index = 0; index < node_count; ++index) {
		TaskNodeRuntimeStateRecord state;
		std::uint8_t raw_state = 0;
		if (!reader.read_u8(raw_state) || !reader.read_u32(state.counter) || !reader.read_u64(state.request_generation)) return snapshot_invalid();
		state.state = static_cast<TaskNodeInstanceState>(raw_state);
		decoded.node_states_.push_back(state);
	}
	std::uint32_t edge_count = 0;
	if (!reader.read_u32(edge_count) || edge_count != decoded.graph_.edges().size()) {
		return snapshot_invalid(DiagnosticId::GRAPH_NODE_REFERENCE_INVALID, edge_count);
	}
	decoded.incoming_edges_arrived_.clear();
	decoded.incoming_edges_arrived_.reserve(edge_count);
	for (std::uint32_t index = 0; index < edge_count; ++index) {
		std::uint8_t arrived = 0;
		if (!reader.read_u8(arrived)) return snapshot_invalid();
		decoded.incoming_edges_arrived_.push_back(arrived);
	}
	if (!decode_snapshot_facts(reader, decoded.last_facts_)) return snapshot_invalid();

	std::uint32_t pending_count = 0;
	if (!reader.read_u32(pending_count) || pending_count > MAX_PENDING_REQUESTS || pending_count > decoded.limits_.max_pending_requests) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED, pending_count);
	}
	decoded.pending_requests_.clear();
	decoded.pending_requests_.reserve(pending_count);
	for (std::uint32_t index = 0; index < pending_count; ++index) {
		TaskExternalRequest request;
		if (!decode_snapshot_request(reader, request)) return snapshot_invalid();
		decoded.pending_requests_.push_back(std::move(request));
	}

	std::uint32_t resolved_count = 0;
	if (!reader.read_u32(resolved_count) || resolved_count > MAX_RESOLVED_REQUEST_RECORDS ||
			resolved_count > decoded.limits_.max_resolved_request_records) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED, resolved_count);
	}
	decoded.resolved_requests_.clear();
	decoded.resolved_requests_.reserve(resolved_count);
	for (std::uint32_t index = 0; index < resolved_count; ++index) {
		TaskRequestResolutionRecord record;
		if (!decode_snapshot_resolution(reader, record)) return snapshot_invalid();
		decoded.resolved_requests_.push_back(std::move(record));
	}

	std::uint32_t transition_count = 0;
	if (!reader.read_u32(transition_count) || transition_count > MAX_TRANSITION_RECORDS ||
			transition_count > decoded.limits_.max_transition_records) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED, transition_count);
	}
	decoded.transition_records_.clear();
	decoded.transition_records_.reserve(transition_count);
	for (std::uint32_t index = 0; index < transition_count; ++index) {
		TaskTransitionRecord record;
		if (!decode_snapshot_transition(reader, record)) return snapshot_invalid();
		decoded.transition_records_.push_back(std::move(record));
	}
	std::uint8_t transitions_truncated = 0;
	if (!reader.read_u8(transitions_truncated) || transitions_truncated > 1U) return snapshot_invalid();
	decoded.transition_records_truncated_ = transitions_truncated != 0U;

	std::uint32_t state_change_count = 0;
	if (!reader.read_u32(state_change_count) || state_change_count > MAX_STATE_CHANGE_RECORDS ||
			state_change_count > decoded.limits_.max_state_change_records) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED, state_change_count);
	}
	decoded.state_change_records_.clear();
	decoded.state_change_records_.reserve(state_change_count);
	for (std::uint32_t index = 0; index < state_change_count; ++index) {
		TaskStateChangeRecord record;
		if (!decode_snapshot_state_change(reader, record)) return snapshot_invalid();
		decoded.state_change_records_.push_back(std::move(record));
	}
	std::uint8_t state_changes_truncated = 0;
	if (!reader.read_u8(state_changes_truncated) || state_changes_truncated > 1U) return snapshot_invalid();
	decoded.state_change_records_truncated_ = state_changes_truncated != 0U;

	std::uint32_t trace_count = 0;
	if (!reader.read_u32(trace_count) || trace_count > MAX_TRACE_RECORDS || trace_count > decoded.limits_.max_trace_records) {
		return snapshot_invalid(DiagnosticId::COUNT_LIMIT_EXCEEDED, trace_count);
	}
	decoded.trace_records_.clear();
	decoded.trace_records_.reserve(trace_count);
	for (std::uint32_t index = 0; index < trace_count; ++index) {
		TaskTraceRecord record;
		if (!decode_snapshot_trace(reader, record)) return snapshot_invalid();
		decoded.trace_records_.push_back(std::move(record));
	}
	std::uint8_t trace_truncated = 0;
	if (!reader.read_u8(trace_truncated) || trace_truncated > 1U || !reader.exhausted()) return snapshot_invalid();
	decoded.trace_records_truncated_ = trace_truncated != 0U;

	Status status = decoded.validate_snapshot_state();
	if (!status.ok()) return status;
	r_instance = std::move(decoded);
	return ok_status();
}

Status TaskGraphInstance::restore_snapshot(const std::vector<std::uint8_t> &p_bytes) {
	return restore_snapshot(p_bytes, NO_EXPECTED_REVISION);
}

Status TaskGraphInstance::restore_snapshot(const std::vector<std::uint8_t> &p_bytes, std::uint64_t p_expected_revision) {
	if (!graph_.valid() || definition_fingerprint_ == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	}
	TaskGraphInstance candidate = *this;
	Status status = decode_snapshot(p_bytes, candidate);
	if (!status.ok()) return status;
	if (p_expected_revision != NO_EXPECTED_REVISION && candidate.revision_ != p_expected_revision) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_expected_revision);
	}
	*this = std::move(candidate);
	return ok_status();
}

Status TaskGraphInstance::restore_snapshot(
		const CanonicalTaskGraph &p_graph,
		const std::vector<std::uint8_t> &p_bytes,
		TaskGraphInstance &r_instance,
		const TaskRuntimeLimits &p_limits) {
	if (!p_graph.valid() || p_graph.fingerprint() == INVALID_CATALOG_FINGERPRINT) {
		return make_status(StatusCode::INVALID_DEFINITION, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
	}
	Status status = p_limits.validate();
	if (!status.ok()) return status;
	TaskGraphInstance candidate;
	candidate.graph_ = p_graph;
	candidate.definition_fingerprint_ = p_graph.fingerprint();
	candidate.limits_ = p_limits;
	status = candidate.decode_snapshot(p_bytes, candidate);
	if (!status.ok()) return status;
	r_instance = std::move(candidate);
	return ok_status();
}

Status TaskGraphInstance::acknowledge_request(
		const std::string &p_request_identifier,
		const std::string &p_outcome_identifier,
		const Value &p_response,
		std::uint64_t p_tick,
		std::uint64_t p_expected_revision,
		TaskAdvanceResult *r_result) {
	TaskAdvanceResult local_result;
	const bool tick_supplied = p_tick != NO_TICK;
	const std::uint64_t effective_tick = tick_supplied ? p_tick : (has_tick_ ? last_tick_ : 0);
	Status status = acknowledge_internal(p_request_identifier, TaskRequestResolution::ACKNOWLEDGED, p_outcome_identifier,
			p_response, effective_tick, p_expected_revision, local_result, tick_supplied);
	if (r_result != nullptr) *r_result = local_result;
	return status;
}

Status TaskGraphInstance::reject_request(
		const std::string &p_request_identifier,
		const Value &p_response,
		std::uint64_t p_tick,
		std::uint64_t p_expected_revision,
		TaskAdvanceResult *r_result) {
	TaskAdvanceResult local_result;
	const bool tick_supplied = p_tick != NO_TICK;
	const std::uint64_t effective_tick = tick_supplied ? p_tick : (has_tick_ ? last_tick_ : 0);
	Status status = acknowledge_internal(p_request_identifier, TaskRequestResolution::REJECTED, std::string(), p_response,
			effective_tick, p_expected_revision, local_result, tick_supplied);
	if (r_result != nullptr) *r_result = local_result;
	return status;
}

Status TaskGraphInstance::timeout_request(
		const std::string &p_request_identifier,
		std::uint64_t p_tick,
		std::uint64_t p_expected_revision,
		TaskAdvanceResult *r_result) {
	TaskAdvanceResult local_result;
	const bool tick_supplied = p_tick != NO_TICK;
	const std::uint64_t effective_tick = tick_supplied ? p_tick : (has_tick_ ? last_tick_ : 0);
	Status status = acknowledge_internal(p_request_identifier, TaskRequestResolution::TIMED_OUT, "timeout", Value::none(),
			effective_tick, p_expected_revision, local_result, tick_supplied);
	if (r_result != nullptr) *r_result = local_result;
	return status;
}

Status TaskGraphInstance::acknowledge_internal(
		const std::string &p_request_identifier,
		TaskRequestResolution p_resolution,
		const std::string &p_outcome_identifier,
		const Value &p_response,
		std::uint64_t p_tick,
		std::uint64_t p_expected_revision,
		TaskAdvanceResult &r_result,
		bool p_tick_supplied) {
	r_result.clear();
	Status status = validate_identifier(p_request_identifier);
	if (!status.ok()) {
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	const TaskRequestResolutionRecord *resolved = find_resolved_request(p_request_identifier);
	if (resolved != nullptr) {
		r_result.idempotent = true;
		r_result.has_resolution = true;
		r_result.resolution = *resolved;
		TaskTraceRecord trace;
		trace.kind = TaskTraceKind::REQUEST_DUPLICATE;
		trace.request_identifier = p_request_identifier;
		trace.outcome_identifier = resolved->outcome_identifier;
		trace.graph_status = status_;
		// A duplicate does not mutate the instance; expose a bounded transient
		// trace in the result but do not retain it or increment revision.
		trace.revision = revision_;
		trace.ordinal = 0;
		r_result.trace.push_back(trace);
		finish_result(r_result);
		return ok_status();
	}
	status = p_response.validate();
	if (!status.ok()) {
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	if (!valid()) {
			status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	if (terminal()) {
		status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_OUTCOME_INVALID);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	if (p_expected_revision != NO_EXPECTED_REVISION && p_expected_revision != revision_) {
		status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_expected_revision);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	if (p_tick_supplied && has_tick_ && p_tick < last_tick_) {
		status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	TaskGraphInstance candidate = *this;
	if (p_tick_supplied) {
		candidate.last_tick_ = p_tick;
		candidate.has_tick_ = true;
	}
	const TaskExternalRequest *request = candidate.find_pending_request(p_request_identifier);
	if (request == nullptr) {
		status = runtime_status(StatusCode::NOT_FOUND, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	const TaskExternalRequest request_copy = *request;
	std::uint32_t transition_count = 0;
	// An explicit acknowledgement at a tick also gives due automatic timeouts
	// precedence.  This keeps retries deterministic regardless of API entrypoint.
	if (p_tick_supplied) {
		status = candidate.expire_requests(p_tick, candidate.last_facts_, r_result, transition_count);
		if (!status.ok()) {
			r_result.clear();
			r_result.status = status;
			r_result.revision = revision_;
			r_result.graph_status = status_;
			return status;
		}
		if (candidate.find_pending_request(p_request_identifier) == nullptr) {
			const TaskRequestResolutionRecord *timed_out = candidate.find_resolved_request(p_request_identifier);
			if (timed_out != nullptr) {
				candidate.revision_ = revision_ + 1;
				r_result.changed = true;
				r_result.idempotent = true;
				r_result.has_resolution = true;
				r_result.resolution = *timed_out;
				candidate.finish_result(r_result);
				*this = std::move(candidate);
				return ok_status();
			}
		}
	}
	status = candidate.route_request_resolution(request_copy, p_resolution, p_outcome_identifier, p_response,
			candidate.last_facts_, p_tick, r_result, transition_count);
	if (!status.ok()) {
		r_result.clear();
		r_result.status = status;
		r_result.revision = revision_;
		r_result.graph_status = status_;
		return status;
	}
	candidate.revision_ = revision_ + 1;
	r_result.changed = true;
	candidate.finish_result(r_result);
	*this = std::move(candidate);
	return ok_status();
}

Status TaskGraphInstance::emit_level_transition_request(
		const std::string &p_target_level_identifier,
		const std::string &p_target_exit_identifier,
		const std::string &p_target_anchor_identifier,
		const std::vector<Value> &p_parameters,
		std::uint64_t p_tick,
		TaskExternalRequest *r_request,
		TaskAdvanceResult *r_result) {
	TaskAdvanceResult local_result;
	local_result.clear();
	if (!valid()) {
		const Status status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_NODE_REFERENCE_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.graph_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	if (terminal()) {
		const Status status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRAPH_OUTCOME_INVALID);
		local_result.status = status;
		local_result.revision = revision_;
		local_result.graph_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	Status status = validate_identifier(p_target_level_identifier);
	if (status.ok()) status = validate_local_identifier(p_target_exit_identifier);
	if (status.ok()) status = validate_local_identifier(p_target_anchor_identifier);
	if (status.ok() && p_parameters.size() > MAX_NODE_PARAMETERS) status = runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_parameters.size());
	if (status.ok()) {
		for (const Value &parameter : p_parameters) {
			status = parameter.validate();
			if (!status.ok()) break;
		}
	}
	if (status.ok() && encoded_values_size(p_parameters) > MAX_PROVIDER_PAYLOAD_BYTES) status = runtime_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, encoded_values_size(p_parameters));
	const bool tick_supplied = p_tick != NO_TICK;
	if (status.ok() && tick_supplied && has_tick_ && p_tick < last_tick_) status = runtime_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_tick);
	if (!status.ok()) {
		local_result.status = status;
		local_result.revision = revision_;
		local_result.graph_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	TaskGraphInstance candidate = *this;
	const std::uint64_t tick = tick_supplied ? p_tick : (candidate.has_tick_ ? candidate.last_tick_ : 0);
	if (tick_supplied) {
		candidate.last_tick_ = p_tick;
		candidate.has_tick_ = true;
	}
	TaskExternalRequest request;
	request.kind = TaskExternalRequestKind::LEVEL_TRANSITION;
	request.instance_identifier = instance_identifier_;
	request.scope_key = scope_key_;
	request.target_level_identifier = p_target_level_identifier;
	request.target_exit_identifier = p_target_exit_identifier;
	request.target_anchor_identifier = p_target_anchor_identifier;
	request.parameters = p_parameters;
	request.created_revision = revision_ + 1;
	request.created_tick = tick;
	if (candidate.limits_.request_timeout_ticks != 0) {
		if (tick > std::numeric_limits<std::uint64_t>::max() - candidate.limits_.request_timeout_ticks) {
			status = runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE, tick);
		} else {
			request.has_timeout = true;
			request.timeout_tick = tick + candidate.limits_.request_timeout_ticks;
		}
	}
	std::uint64_t ordinal = candidate.next_request_ordinal_;
	if (status.ok()) {
		if (ordinal == std::numeric_limits<std::uint64_t>::max()) status = runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
		while (status.ok()) {
			request.request_identifier = candidate.make_request_identifier(request.kind, "level_transition", ordinal);
			if (candidate.find_pending_request(request.request_identifier) == nullptr && candidate.find_resolved_request(request.request_identifier) == nullptr) break;
			if (ordinal == std::numeric_limits<std::uint64_t>::max()) {
				status = runtime_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::VALUE_OUT_OF_RANGE);
				break;
			}
			++ordinal;
		}
	}
	if (status.ok()) {
		candidate.next_request_ordinal_ = ordinal + 1;
		status = candidate.emit_request(std::move(request), local_result);
	}
	if (!status.ok()) {
		local_result.clear();
		local_result.status = status;
		local_result.revision = revision_;
		local_result.graph_status = status_;
		if (r_result != nullptr) *r_result = local_result;
		return status;
	}
	candidate.revision_ = revision_ + 1;
	local_result.changed = true;
	candidate.finish_result(local_result);
	if (r_request != nullptr && !local_result.requests.empty()) *r_request = local_result.requests.back();
	*this = std::move(candidate);
	if (r_result != nullptr) *r_result = local_result;
	return ok_status();
}

} // namespace lts
