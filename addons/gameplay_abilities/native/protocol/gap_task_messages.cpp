#include "protocol/gap_task_messages.h"

#include <algorithm>
#include <limits>

namespace ga::proto {

namespace {

bool valid_task_kind(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(AbilityTaskKind::WAIT_TARGET_DATA);
}

bool valid_visibility(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(AbilityTaskVisibility::INTERNAL);
}

bool valid_prediction_policy(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(AbilityTaskPredictionPolicy::REQUIRES_AUTHORITY);
}

bool valid_input_phase(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(LogicalInputPhase::CANCEL);
}

bool valid_tag_match(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(TagMatchMode::PARENT_AWARE);
}

bool valid_tag_edge(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(AbilityTaskTagEdge::BECOMES_FALSE);
}

// `task_visible_to` itself is `ga::task_visible_to` (ga_ability_tasks.h) --
// exported so this file, the core snapshot section, and the observer task
// section below all evaluate the identical predicate instead of each keeping
// a private copy. Resolved unqualified via the enclosing `ga` namespace
// (this file lives in `ga::proto`).

Status malformed(ByteReader &p_reader, DiagnosticId p_diag = DiagnosticId::TRUNCATED_PAYLOAD) {
	if (!p_reader.ok()) {
		return p_reader.status();
	}
	return make_status(StatusCode::DECODE_FAILED, p_diag, p_reader.consumed());
}

Status encode_request(ByteWriter &p_writer, const AbilityTaskRequest &p_request) {
	const std::uint8_t kind = static_cast<std::uint8_t>(p_request.kind);
	const std::uint8_t visibility = static_cast<std::uint8_t>(p_request.visibility);
	const std::uint8_t prediction = static_cast<std::uint8_t>(p_request.prediction_policy);
	if (!valid_task_kind(kind) || !valid_visibility(visibility) ||
			!valid_prediction_policy(prediction)) {
		return make_status(StatusCode::INVALID_ABILITY_TASK, DiagnosticId::INVALID_ENUM);
	}

	p_writer.write_u8(kind);
	p_writer.write_bool(p_request.has_deadline);
	p_writer.write_u64(p_request.deadline_tick);
	p_writer.write_u8(visibility);
	p_writer.write_u8(prediction);
	p_writer.write_u64(p_request.wait_ticks);
	p_writer.write_u32(p_request.gameplay_event_tag);
	p_writer.write_u8(static_cast<std::uint8_t>(p_request.gameplay_event_match));
	const Status query_status = p_request.tag_query.encode(p_writer);
	if (!query_status.ok()) {
		return query_status;
	}
	p_writer.write_u8(static_cast<std::uint8_t>(p_request.tag_edge));
	p_writer.write_bool(p_request.complete_if_already_satisfied);
	p_writer.write_u32(p_request.logical_input);
	p_writer.write_u8(static_cast<std::uint8_t>(p_request.logical_phase));
	handle_write(p_writer, p_request.authority_prediction);
	p_writer.write_u32(p_request.target_schema);
	return p_writer.ok() ? ok_status() : p_writer.status();
}

Status decode_request(ByteReader &p_reader, AbilityTaskRequest &r_request) {
	std::uint8_t kind = 0;
	std::uint8_t visibility = 0;
	std::uint8_t prediction = 0;
	std::uint8_t event_match = 0;
	std::uint8_t tag_edge = 0;
	std::uint8_t input_phase = 0;
	AbilityTaskRequest request;
	if (!p_reader.read_u8(kind) || !p_reader.read_bool(request.has_deadline) ||
			!p_reader.read_u64(request.deadline_tick) ||
			!p_reader.read_u8(visibility) || !p_reader.read_u8(prediction) ||
			!p_reader.read_u64(request.wait_ticks) ||
			!p_reader.read_u32(request.gameplay_event_tag) ||
			!p_reader.read_u8(event_match)) {
		return malformed(p_reader);
	}
	if (!valid_task_kind(kind) || !valid_visibility(visibility) ||
			!valid_prediction_policy(prediction) || !valid_tag_match(event_match)) {
		return malformed(p_reader, DiagnosticId::INVALID_ENUM);
	}
	request.kind = static_cast<AbilityTaskKind>(kind);
	request.visibility = static_cast<AbilityTaskVisibility>(visibility);
	request.prediction_policy = static_cast<AbilityTaskPredictionPolicy>(prediction);
	request.gameplay_event_match = static_cast<TagMatchMode>(event_match);
	const Status query_status = TagQuery::decode(p_reader, request.tag_query);
	if (!query_status.ok()) {
		return query_status;
	}
	if (!p_reader.read_u8(tag_edge) ||
			!p_reader.read_bool(request.complete_if_already_satisfied) ||
			!p_reader.read_u32(request.logical_input) ||
			!p_reader.read_u8(input_phase) ||
			!handle_read(p_reader, request.authority_prediction) ||
			!p_reader.read_u32(request.target_schema)) {
		return malformed(p_reader);
	}
	if (!valid_tag_edge(tag_edge) || !valid_input_phase(input_phase)) {
		return malformed(p_reader, DiagnosticId::INVALID_ENUM);
	}
	request.tag_edge = static_cast<AbilityTaskTagEdge>(tag_edge);
	request.logical_phase = static_cast<LogicalInputPhase>(input_phase);
	r_request = std::move(request);
	return ok_status();
}

} // namespace

Status encode_task_input(const TaskInputCommandDto &p_command,
		std::vector<std::uint8_t> &r_bytes) {
	r_bytes.clear();
	if (!p_command.owner || !p_command.execution || !p_command.task ||
			!p_command.command_sequence ||
			p_command.expected_kind != AbilityTaskKind::WAIT_LOGICAL_INPUT ||
			p_command.logical_input == INVALID_DEFINITION_ID ||
			!valid_input_phase(static_cast<std::uint8_t>(p_command.phase))) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_TASK_PAYLOAD);
	}
	ByteWriter writer(MAX_COMMAND_PACKET_BYTES);
	writer.write_u16(TASK_MESSAGE_VERSION);
	handle_write(writer, p_command.owner);
	handle_write(writer, p_command.execution);
	handle_write(writer, p_command.task);
	writer.write_u8(static_cast<std::uint8_t>(p_command.expected_kind));
	writer.write_u32(p_command.logical_input);
	writer.write_u8(static_cast<std::uint8_t>(p_command.phase));
	handle_write(writer, p_command.command_sequence);
	handle_write(writer, p_command.prediction_key);
	writer.write_u64(p_command.issued_tick);
	if (!writer.ok()) {
		return writer.status();
	}
	r_bytes = writer.take();
	return ok_status();
}

Status decode_task_input(const std::vector<std::uint8_t> &p_bytes,
		TaskInputCommandDto &r_command) {
	r_command = TaskInputCommandDto{};
	if (p_bytes.size() > MAX_COMMAND_PACKET_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}
	ByteReader reader(p_bytes);
	std::uint16_t version = 0;
	std::uint8_t kind = 0;
	std::uint8_t phase = 0;
	TaskInputCommandDto decoded;
	if (!reader.read_u16(version) || !handle_read(reader, decoded.owner) ||
			!handle_read(reader, decoded.execution) ||
			!handle_read(reader, decoded.task) || !reader.read_u8(kind) ||
			!reader.read_u32(decoded.logical_input) || !reader.read_u8(phase) ||
			!handle_read(reader, decoded.command_sequence) ||
			!handle_read(reader, decoded.prediction_key) ||
			!reader.read_u64(decoded.issued_tick)) {
		return malformed(reader);
	}
	if (version != TASK_MESSAGE_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH,
				DiagnosticId::PROTOCOL_VERSION_DIFFERS, version);
	}
	// Fix (decode diagnostics mislabel): checked as two SEPARATE conditions,
	// each with its own diagnostic, matching the convention every other
	// decoder in this directory uses (see `decode_task_states` below,
	// `decode_resync_request` in gap_resync.cpp, and the fixed-field decoders
	// in gap_handshake.cpp/gap_event_stream.cpp): leftover bytes after every
	// declared field decoded cleanly is a framing-size problem
	// (TRUNCATED_PAYLOAD), never an enum problem, and is checked FIRST so it
	// is never masked by a coincidentally-also-invalid enum byte. A raw
	// kind/phase value with no matching enum member is checked separately
	// and reported as INVALID_ENUM. A single combined condition with a
	// re-derived ternary for the diagnostic made this easy to misread even
	// though it happened to agree with this ordering.
	if (!reader.at_end()) {
		return malformed(reader, DiagnosticId::TRUNCATED_PAYLOAD);
	}
	if (!valid_task_kind(kind) || !valid_input_phase(phase)) {
		return malformed(reader, DiagnosticId::INVALID_ENUM);
	}
	decoded.expected_kind = static_cast<AbilityTaskKind>(kind);
	decoded.phase = static_cast<LogicalInputPhase>(phase);
	if (!decoded.owner || !decoded.execution || !decoded.task ||
			!decoded.command_sequence ||
			decoded.expected_kind != AbilityTaskKind::WAIT_LOGICAL_INPUT ||
			decoded.logical_input == INVALID_DEFINITION_ID) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_TASK_PAYLOAD);
	}
	r_command = decoded;
	return ok_status();
}

Status encode_task_states(const std::vector<TaskStateDto> &p_states,
		AbilityTaskVisibility p_max_visibility, std::vector<std::uint8_t> &r_bytes) {
	r_bytes.clear();
	if (!valid_visibility(static_cast<std::uint8_t>(p_max_visibility)) ||
			p_states.size() > MAX_ACTIVE_ABILITY_TASKS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, p_states.size());
	}
	std::vector<const ActiveAbilityTask *> included;
	included.reserve(p_states.size());
	for (const TaskStateDto &state : p_states) {
		if (task_visible_to(state.task.request.visibility, p_max_visibility)) {
			included.push_back(&state.task);
		}
	}
	std::sort(included.begin(), included.end(),
			[](const ActiveAbilityTask *p_a, const ActiveAbilityTask *p_b) {
				return p_a->handle < p_b->handle;
			});

	ByteWriter writer(MAX_COMMAND_PACKET_BYTES);
	writer.write_u16(TASK_MESSAGE_VERSION);
	writer.write_count(included.size(), MAX_ACTIVE_ABILITY_TASKS);
	for (const ActiveAbilityTask *task : included) {
		if (!task->handle || !task->owner || !task->execution || !task->spec ||
				task->ability == INVALID_DEFINITION_ID) {
			return make_status(StatusCode::INVALID_ABILITY_TASK,
					DiagnosticId::TASK_PARENT_MISSING, task->handle.value);
		}
		handle_write(writer, task->handle);
		handle_write(writer, task->owner);
		handle_write(writer, task->execution);
		handle_write(writer, task->spec);
		writer.write_u32(task->ability);
		const Status request_status = encode_request(writer, task->request);
		if (!request_status.ok()) {
			return request_status;
		}
		writer.write_u64(task->start_tick);
		writer.write_u64(task->due_tick);
		writer.write_bool(task->last_tag_truth);
		handle_write(writer, task->last_input_sequence);
		writer.write_u8(static_cast<std::uint8_t>(task->provenance));
		handle_write(writer, task->prediction_key);
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_bytes = writer.take();
	return ok_status();
}

Status decode_task_states(const std::vector<std::uint8_t> &p_bytes,
		std::vector<TaskStateDto> &r_states) {
	r_states.clear();
	if (p_bytes.size() > MAX_COMMAND_PACKET_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}
	ByteReader reader(p_bytes);
	std::uint16_t version = 0;
	std::size_t count = 0;
	if (!reader.read_u16(version)) {
		return malformed(reader);
	}
	if (version != TASK_MESSAGE_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH,
				DiagnosticId::PROTOCOL_VERSION_DIFFERS, version);
	}
	if (!reader.read_count(count, MAX_ACTIVE_ABILITY_TASKS, 64)) {
		return reader.status();
	}
	std::vector<TaskStateDto> decoded;
	decoded.reserve(count);
	std::uint64_t previous_handle = 0;
	for (std::size_t i = 0; i < count; ++i) {
		ActiveAbilityTask task;
		std::uint8_t provenance = 0;
		if (!handle_read(reader, task.handle) || !handle_read(reader, task.owner) ||
				!handle_read(reader, task.execution) ||
				!handle_read(reader, task.spec) || !reader.read_u32(task.ability)) {
			return malformed(reader);
		}
		const Status request_status = decode_request(reader, task.request);
		if (!request_status.ok()) {
			return request_status;
		}
		if (!reader.read_u64(task.start_tick) || !reader.read_u64(task.due_tick) ||
				!reader.read_bool(task.last_tag_truth) ||
				!handle_read(reader, task.last_input_sequence) ||
				!reader.read_u8(provenance) ||
				!handle_read(reader, task.prediction_key)) {
			return malformed(reader);
		}
		if (!task.handle || task.handle.value <= previous_handle || !task.owner ||
				!task.execution || !task.spec ||
				task.ability == INVALID_DEFINITION_ID ||
				provenance > static_cast<std::uint8_t>(ChangeProvenance::PREDICTED)) {
			return malformed(reader, DiagnosticId::INVALID_TASK_PAYLOAD);
		}
		task.provenance = static_cast<ChangeProvenance>(provenance);
		previous_handle = task.handle.value;
		decoded.push_back(TaskStateDto{ std::move(task) });
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::TRUNCATED_PAYLOAD, reader.remaining());
	}
	r_states = std::move(decoded);
	return ok_status();
}

Status encode_observer_task_section(const std::vector<ObserverTaskRecord> &p_records, ByteWriter &p_writer) {
	if (p_records.size() > MAX_ACTIVE_ABILITY_TASKS) {
		return make_status(StatusCode::CAPACITY_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, p_records.size());
	}
	std::vector<const ObserverTaskRecord *> ordered;
	ordered.reserve(p_records.size());
	for (const ObserverTaskRecord &record : p_records) {
		if (!record.task || !record.execution || record.ability_identifier.empty() ||
				!valid_task_kind(static_cast<std::uint8_t>(record.kind))) {
			return make_status(StatusCode::INVALID_ABILITY_TASK,
					DiagnosticId::INVALID_TASK_PAYLOAD, record.task.value);
		}
		ordered.push_back(&record);
	}
	// Canonical ordering (matching `encode_task_states` above): sorted here,
	// once, rather than trusting the caller's own iteration order, so two
	// encodes of the same underlying task set are byte-identical regardless
	// of how the bridge happened to walk its active-task collection.
	std::sort(ordered.begin(), ordered.end(),
			[](const ObserverTaskRecord *p_a, const ObserverTaskRecord *p_b) {
				return p_a->task < p_b->task;
			});

	p_writer.write_count(ordered.size(), MAX_ACTIVE_ABILITY_TASKS);
	for (const ObserverTaskRecord *record : ordered) {
		handle_write(p_writer, record->task);
		handle_write(p_writer, record->execution);
		p_writer.write_string(record->ability_identifier);
		p_writer.write_u8(static_cast<std::uint8_t>(record->kind));
		p_writer.write_u64(record->start_tick);
		p_writer.write_bool(record->has_deadline);
		p_writer.write_u64(record->has_deadline ? record->deadline_tick : 0);
	}
	return p_writer.ok() ? ok_status() : p_writer.status();
}

void select_observer_task_records(const std::vector<ActiveAbilityTask> &p_tasks,
		const std::function<bool(const ActiveAbilityTask &, std::string &)> &p_resolve_ability_identifier,
		std::vector<ObserverTaskRecord> &r_records) {
	r_records.clear();
	if (!p_resolve_ability_identifier) {
		return;
	}
	for (const ActiveAbilityTask &task : p_tasks) {
		if (!task_visible_to(task.request.visibility, AbilityTaskVisibility::OBSERVABLE)) {
			continue;
		}
		// Defensive authoritative-only check -- see this function's own doc
		// comment; spec scenario "Predicted task is not shown to observers".
		if (task.provenance != ChangeProvenance::AUTHORITATIVE) {
			continue;
		}
		std::string identifier;
		if (!p_resolve_ability_identifier(task, identifier) || identifier.empty()) {
			continue;
		}
		ObserverTaskRecord record;
		record.task = task.handle;
		record.execution = task.execution;
		record.ability_identifier = std::move(identifier);
		record.kind = task.request.kind;
		record.start_tick = task.start_tick;
		record.has_deadline = task.request.has_deadline;
		record.deadline_tick = task.request.deadline_tick;
		r_records.push_back(std::move(record));
	}
}

Status decode_observer_task_section(ByteReader &p_reader, std::vector<ObserverTaskRecord> &r_records) {
	r_records.clear();
	std::size_t count = 0;
	// Minimum per-record size, a safe LOWER bound even though the
	// zero-length-identifier case it technically admits is itself rejected
	// explicitly below: task(8) + execution(8) + identifier length prefix(2)
	// + kind(1) + start_tick(8) + has_deadline(1) + deadline_tick(8) = 36.
	if (!p_reader.read_count(count, MAX_ACTIVE_ABILITY_TASKS, 36)) {
		return p_reader.status();
	}
	std::vector<ObserverTaskRecord> decoded;
	decoded.reserve(count);
	std::uint64_t previous_handle = 0;
	for (std::size_t i = 0; i < count; ++i) {
		ObserverTaskRecord record;
		std::uint8_t kind_raw = 0;
		if (!handle_read(p_reader, record.task) || !handle_read(p_reader, record.execution) ||
				!p_reader.read_string(record.ability_identifier) ||
				!p_reader.read_u8(kind_raw) ||
				!p_reader.read_u64(record.start_tick) ||
				!p_reader.read_bool(record.has_deadline) ||
				!p_reader.read_u64(record.deadline_tick)) {
			return malformed(p_reader);
		}
		if (!record.task || record.task.value <= previous_handle || !record.execution ||
				record.ability_identifier.empty()) {
			return malformed(p_reader, DiagnosticId::INVALID_TASK_PAYLOAD);
		}
		if (!valid_task_kind(kind_raw)) {
			return malformed(p_reader, DiagnosticId::INVALID_ENUM);
		}
		record.kind = static_cast<AbilityTaskKind>(kind_raw);
		if (!record.has_deadline) {
			record.deadline_tick = 0;
		}
		previous_handle = record.task.value;
		decoded.push_back(std::move(record));
	}
	r_records = std::move(decoded);
	return ok_status();
}

Status admit_and_apply_task_input(const TaskInputCommandDto &p_command,
		PeerId p_peer, SessionId p_session, Tick p_authority_tick,
		const SessionTiming &p_timing, CommandGate &p_gate,
		CommandSequenceTracker &p_sequences, AbilityComponent &p_component,
		InboundCommandVerdict &r_verdict, AbilityTaskTransitionResult &r_result) {
	r_result = AbilityTaskTransitionResult{};
	if (p_command.owner != p_component.entity()) {
		r_verdict = InboundCommandVerdict{};
		r_verdict.kind = CommandOutcomeKind::REJECTED;
		r_verdict.status = make_status(StatusCode::PERMISSION_DENIED,
				DiagnosticId::TASK_PARENT_MISSING, p_command.owner.value);
		return r_verdict.status;
	}

	InboundCommandContext context;
	context.peer = p_peer;
	context.session = p_session;
	context.component = p_command.owner;
	context.command_sequence = p_command.command_sequence;
	// A predicted task input is its own command and therefore owns a fresh
	// prediction key. CommandGate claims it exactly like an activation key;
	// exact retransmission is recognized by sequence before key claiming.
	context.prediction_key = p_command.prediction_key;
	context.current_tick = p_authority_tick;
	const Status gate_status = p_gate.admit(context, p_timing, r_verdict);
	if (!gate_status.ok() || r_verdict.kind == CommandOutcomeKind::DUPLICATE_REPLAY) {
		r_result.status = r_verdict.status;
		return gate_status;
	}

	const ActiveExecution *execution = p_component.find_execution(p_command.execution);
	const ActiveAbilityTask *task = p_component.ability_tasks().find(p_command.task);
	Status validation = ok_status();
	if (execution == nullptr || task == nullptr || task->execution != p_command.execution) {
		validation = make_status(StatusCode::UNKNOWN_ABILITY_TASK,
				DiagnosticId::TASK_PARENT_MISSING, p_command.task.value);
	} else if (task->request.kind != p_command.expected_kind ||
			task->request.kind != AbilityTaskKind::WAIT_LOGICAL_INPUT ||
			task->request.logical_input != p_command.logical_input ||
			task->request.logical_phase != p_command.phase) {
		validation = make_status(StatusCode::ABILITY_TASK_INPUT_REJECTED,
				DiagnosticId::INVALID_TASK_PAYLOAD, p_command.task.value);
	} else if (task->request.has_deadline &&
			task->request.deadline_tick <= p_authority_tick) {
		validation = make_status(StatusCode::ABILITY_TASK_TIMED_OUT,
				DiagnosticId::TASK_DEADLINE_INVALID,
				task->request.deadline_tick);
	}
	if (!validation.ok()) {
		p_sequences.record_command_result(p_session, p_command.owner,
				p_command.command_sequence, validation);
		r_verdict.kind = CommandOutcomeKind::REJECTED;
		r_verdict.status = validation;
		r_result.status = validation;
		return validation;
	}

	AbilityTaskLogicalInputCommand command;
	command.owner = p_command.owner;
	command.execution = p_command.execution;
	command.task = p_command.task;
	command.logical_input = p_command.logical_input;
	command.phase = p_command.phase;
	command.sequence = p_command.command_sequence;
	command.prediction_key = p_command.prediction_key;
	r_result = p_component.submit_logical_input(command, p_authority_tick,
			ChangeProvenance::AUTHORITATIVE);
	p_sequences.record_command_result(p_session, p_command.owner,
			p_command.command_sequence, r_result.status);
	r_verdict.status = r_result.status;
	if (!r_result.status.ok()) {
		r_verdict.kind = CommandOutcomeKind::REJECTED;
	}
	return r_result.status;
}

} // namespace ga::proto
