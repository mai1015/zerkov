#include "protocol/gap_target_messages.h"

#include <algorithm>
#include <set>

namespace ga::proto {

namespace {

bool valid_command_kind(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(
			TargetSessionCommandKind::CANCEL);
}

bool valid_lifecycle_kind(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(
			TargetSessionLifecycleKind::CORRECTED);
}

bool valid_outcome_kind(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(
			TargetEntityOutcomeKind::EFFECT_REJECTED);
}

bool valid_visibility(std::uint8_t p_raw) {
	return p_raw <= static_cast<std::uint8_t>(
			TargetResultVisibility::INTERNAL);
}

void write_status(ByteWriter &p_writer, Status p_status) {
	p_writer.write_u16(static_cast<std::uint16_t>(p_status.code));
	p_writer.write_u16(
			static_cast<std::uint16_t>(p_status.diagnostic));
	p_writer.write_u64(p_status.detail);
}

Status read_status(ByteReader &p_reader, Status &r_status) {
	std::uint16_t code = 0;
	std::uint16_t diagnostic = 0;
	if (!p_reader.read_u16(code) ||
			!p_reader.read_u16(diagnostic) ||
			!p_reader.read_u64(r_status.detail)) {
		return p_reader.status();
	}
	if (!is_known_status_code(code) ||
			!is_known_diagnostic_id(diagnostic)) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_ENUM, code);
	}
	r_status.code = static_cast<StatusCode>(code);
	r_status.diagnostic =
			static_cast<DiagnosticId>(diagnostic);
	return ok_status();
}

bool visible_to(TargetResultVisibility p_visibility,
		TargetResultVisibility p_audience) {
	switch (p_audience) {
		case TargetResultVisibility::OWNER_ONLY:
			return p_visibility !=
					TargetResultVisibility::INTERNAL;
		case TargetResultVisibility::OBSERVABLE:
			return p_visibility ==
					TargetResultVisibility::OBSERVABLE;
		case TargetResultVisibility::INTERNAL:
			return true;
	}
	return false;
}

Status malformed(ByteReader &p_reader,
		DiagnosticId p_diagnostic =
				DiagnosticId::TRUNCATED_PAYLOAD) {
	return p_reader.ok() ?
			make_status(StatusCode::DECODE_FAILED, p_diagnostic,
					p_reader.consumed()) :
			p_reader.status();
}

} // namespace

Status encode_target_command(const TargetCommandDto &p_command,
		const TargetSchemaRegistry &p_schemas,
		std::vector<std::uint8_t> &r_bytes) {
	r_bytes.clear();
	const TargetSchema *schema = p_schemas.find(p_command.schema);
	if (schema == nullptr || !p_command.owner ||
			!p_command.execution || !p_command.task ||
			!p_command.target_session ||
			!p_command.command_sequence ||
			!p_command.session_sequence ||
			p_command.schema_version != schema->desc.schema_version ||
			!valid_command_kind(static_cast<std::uint8_t>(
					p_command.kind)) ||
			(p_command.kind == TargetSessionCommandKind::SUBMIT &&
					!p_command.has_intent)) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	TargetValue canonical;
	if (p_command.has_intent) {
		Status status = normalize_target_value(p_command.intent,
				*schema, true, p_command.owner, canonical);
		if (!status.ok() || canonical != p_command.intent) {
			return status.ok() ?
					make_status(StatusCode::INVALID_TARGET_DATA,
							DiagnosticId::INVALID_TARGET_COORDINATE) :
					status;
		}
	}
	ByteWriter writer(MAX_COMMAND_PACKET_BYTES);
	writer.write_u16(TARGET_MESSAGE_VERSION);
	handle_write(writer, p_command.owner);
	handle_write(writer, p_command.execution);
	handle_write(writer, p_command.task);
	handle_write(writer, p_command.target_session);
	writer.write_u32(p_command.schema);
	writer.write_u16(p_command.schema_version);
	writer.write_u8(static_cast<std::uint8_t>(p_command.kind));
	handle_write(writer, p_command.command_sequence);
	handle_write(writer, p_command.session_sequence);
	handle_write(writer, p_command.prediction_key);
	writer.write_u64(p_command.issued_tick);
	writer.write_bool(p_command.has_intent);
	if (p_command.has_intent) {
		Status status = write_target_value(writer, p_command.intent,
				*schema, true);
		if (!status.ok()) {
			return status;
		}
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_bytes = writer.take();
	return ok_status();
}

Status decode_target_command(const std::vector<std::uint8_t> &p_bytes,
		const TargetSchemaRegistry &p_schemas,
		TargetCommandDto &r_command) {
	r_command = TargetCommandDto{};
	if (p_bytes.size() > MAX_COMMAND_PACKET_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}
	ByteReader reader(p_bytes);
	std::uint16_t version = 0;
	std::uint8_t kind = 0;
	TargetCommandDto command;
	if (!reader.read_u16(version) ||
			!handle_read(reader, command.owner) ||
			!handle_read(reader, command.execution) ||
			!handle_read(reader, command.task) ||
			!handle_read(reader, command.target_session) ||
			!reader.read_u32(command.schema) ||
			!reader.read_u16(command.schema_version) ||
			!reader.read_u8(kind) ||
			!handle_read(reader, command.command_sequence) ||
			!handle_read(reader, command.session_sequence) ||
			!handle_read(reader, command.prediction_key) ||
			!reader.read_u64(command.issued_tick) ||
			!reader.read_bool(command.has_intent)) {
		return malformed(reader);
	}
	if (version != TARGET_MESSAGE_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH,
				DiagnosticId::PROTOCOL_VERSION_DIFFERS, version);
	}
	if (!valid_command_kind(kind)) {
		return malformed(reader, DiagnosticId::INVALID_ENUM);
	}
	command.kind =
			static_cast<TargetSessionCommandKind>(kind);
	const TargetSchema *schema = p_schemas.find(command.schema);
	if (schema == nullptr ||
			command.schema_version != schema->desc.schema_version) {
		return make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::INVALID_TARGET_SCHEMA,
				command.schema);
	}
	if (command.has_intent) {
		Status status = read_target_value(reader, *schema, true,
				command.intent);
		if (!status.ok()) {
			return status;
		}
		status = validate_canonical_target_value(command.intent,
				*schema, true, command.owner);
		if (!status.ok()) {
			return status;
		}
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				reader.remaining());
	}
	if (!command.owner || !command.execution || !command.task ||
			!command.target_session ||
			!command.command_sequence ||
			!command.session_sequence ||
			(command.kind == TargetSessionCommandKind::SUBMIT &&
					!command.has_intent)) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	r_command = std::move(command);
	return ok_status();
}

Status encode_target_outcome(const TargetOutcomeDto &p_outcome,
		const TargetSchemaRegistry &p_schemas,
		TargetResultVisibility p_audience,
		std::vector<std::uint8_t> &r_bytes) {
	r_bytes.clear();
	if (!valid_lifecycle_kind(static_cast<std::uint8_t>(
					p_outcome.event.kind)) ||
			!valid_visibility(static_cast<std::uint8_t>(p_audience)) ||
			p_outcome.outcomes.size() > MAX_TARGETS_PER_COMMAND) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_TARGET_PROVENANCE);
	}
	const TargetSchema *schema =
			p_schemas.find(p_outcome.event.schema);
	if (schema == nullptr) {
		return make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				p_outcome.event.schema);
	}
	const bool include_data = p_outcome.has_validated_data &&
			visible_to(schema->desc.visibility, p_audience);
	ByteWriter writer(MAX_EVENT_BATCH_BYTES);
	writer.write_u16(TARGET_MESSAGE_VERSION);
	writer.write_u8(static_cast<std::uint8_t>(
			p_outcome.event.kind));
	handle_write(writer, p_outcome.event.session);
	handle_write(writer, p_outcome.event.owner);
	handle_write(writer, p_outcome.event.execution);
	handle_write(writer, p_outcome.event.task);
	writer.write_u32(p_outcome.event.schema);
	writer.write_u64(p_outcome.event.tick);
	write_status(writer, p_outcome.event.status);
	handle_write(writer, p_outcome.event.command_sequence);
	writer.write_bool(p_outcome.event.has_intent);
	writer.write_u64(
			p_outcome.event.canonical_intent_hash);
	writer.write_bool(include_data);
	if (include_data) {
		writer.write_u16(schema->desc.schema_version);
		Status status = write_target_value(writer,
				p_outcome.canonical_intent.value, *schema, true);
		if (!status.ok()) {
			return status;
		}
		status = write_target_value(writer, p_outcome.result,
				*schema, false);
		if (!status.ok()) {
			return status;
		}
		std::vector<TargetEntityOutcome> outcomes =
				p_outcome.outcomes;
		std::stable_sort(outcomes.begin(), outcomes.end(),
				[](const TargetEntityOutcome &p_a,
						const TargetEntityOutcome &p_b) {
					if (p_a.rank != p_b.rank) {
						return p_a.rank < p_b.rank;
					}
					return p_a.entity < p_b.entity;
				});
		writer.write_count(outcomes.size(),
				MAX_TARGETS_PER_COMMAND);
		for (const TargetEntityOutcome &outcome : outcomes) {
			handle_write(writer, outcome.entity);
			writer.write_u16(outcome.rank);
			writer.write_u8(static_cast<std::uint8_t>(
					outcome.kind));
			write_status(writer, outcome.status);
		}
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_bytes = writer.take();
	return ok_status();
}

Status decode_target_outcome(const std::vector<std::uint8_t> &p_bytes,
		const TargetSchemaRegistry &p_schemas,
		TargetOutcomeDto &r_outcome) {
	r_outcome = TargetOutcomeDto{};
	if (p_bytes.size() > MAX_EVENT_BATCH_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE,
				DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}
	ByteReader reader(p_bytes);
	std::uint16_t version = 0;
	std::uint8_t kind = 0;
	TargetOutcomeDto outcome;
	if (!reader.read_u16(version) || !reader.read_u8(kind) ||
			!handle_read(reader, outcome.event.session) ||
			!handle_read(reader, outcome.event.owner) ||
			!handle_read(reader, outcome.event.execution) ||
			!handle_read(reader, outcome.event.task) ||
			!reader.read_u32(outcome.event.schema) ||
			!reader.read_u64(outcome.event.tick)) {
		return malformed(reader);
	}
	if (version != TARGET_MESSAGE_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH,
				DiagnosticId::PROTOCOL_VERSION_DIFFERS, version);
	}
	if (!valid_lifecycle_kind(kind)) {
		return malformed(reader, DiagnosticId::INVALID_ENUM);
	}
	outcome.event.kind =
			static_cast<TargetSessionLifecycleKind>(kind);
	Status status = read_status(reader, outcome.event.status);
	if (!status.ok() ||
			!handle_read(reader,
					outcome.event.command_sequence) ||
			!reader.read_bool(outcome.event.has_intent) ||
			!reader.read_u64(
					outcome.event.canonical_intent_hash) ||
			!reader.read_bool(outcome.has_validated_data)) {
		return status.ok() ? malformed(reader) : status;
	}
	const TargetSchema *schema =
			p_schemas.find(outcome.event.schema);
	if (schema == nullptr) {
		return make_status(StatusCode::UNKNOWN_TARGET_SCHEMA,
				DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
				outcome.event.schema);
	}
	if (outcome.has_validated_data) {
		std::uint16_t schema_version = 0;
		if (!reader.read_u16(schema_version) ||
				schema_version != schema->desc.schema_version) {
			return make_status(StatusCode::PROTOCOL_MISMATCH,
					DiagnosticId::INVALID_TARGET_SCHEMA,
					schema_version);
		}
		status = read_target_value(reader, *schema, true,
				outcome.canonical_intent.value);
		if (!status.ok()) {
			return status;
		}
		status = read_target_value(reader, *schema, false,
				outcome.result);
		if (!status.ok()) {
			return status;
		}
		outcome.canonical_intent.source =
				outcome.event.owner;
		outcome.canonical_intent.execution =
				outcome.event.execution;
		outcome.canonical_intent.session =
				outcome.event.session;
		outcome.canonical_intent.schema =
				outcome.event.schema;
		outcome.canonical_intent.schema_version =
				schema_version;
		status = hash_target_value(
				outcome.canonical_intent.value, *schema, true,
				outcome.canonical_intent.canonical_hash);
		if (!status.ok()) {
			return status;
		}
		std::size_t count = 0;
		if (!reader.read_count(count, MAX_TARGETS_PER_COMMAND,
					23)) {
			return reader.status();
		}
		outcome.outcomes.reserve(count);
		std::set<EntityId> entities;
		std::uint16_t previous_rank = 0;
		for (std::size_t i = 0; i < count; ++i) {
			TargetEntityOutcome entity_outcome;
			std::uint8_t outcome_kind = 0;
			if (!handle_read(reader, entity_outcome.entity) ||
					!reader.read_u16(entity_outcome.rank) ||
					!reader.read_u8(outcome_kind)) {
				return malformed(reader);
			}
			status = read_status(reader,
					entity_outcome.status);
			if (!status.ok()) {
				return status;
			}
			if (!entity_outcome.entity ||
					!valid_outcome_kind(outcome_kind) ||
					!entities.insert(
							entity_outcome.entity).second ||
					(i > 0 &&
							entity_outcome.rank < previous_rank)) {
				return malformed(reader,
						DiagnosticId::TARGET_RULE_REJECTED);
			}
			entity_outcome.kind =
					static_cast<TargetEntityOutcomeKind>(
							outcome_kind);
			previous_rank = entity_outcome.rank;
			outcome.outcomes.push_back(entity_outcome);
		}
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED,
				DiagnosticId::INVALID_TARGET_PROVENANCE,
				reader.remaining());
	}
	r_outcome = std::move(outcome);
	return ok_status();
}

Status admit_and_apply_target_command(
		const TargetCommandDto &p_command, PeerId p_peer,
		SessionId p_session, Tick p_authority_tick,
		const SessionTiming &p_timing, CommandGate &p_gate,
		CommandSequenceTracker &p_sequences,
		GameplayAbilityWorldCoordinator &p_coordinator,
		AbilityComponent &p_component,
		InboundCommandVerdict &r_verdict,
		TargetSessionCommandResult &r_result) {
	r_result = TargetSessionCommandResult{};
	if (p_command.owner != p_component.entity()) {
		r_verdict = InboundCommandVerdict{};
		r_verdict.kind = CommandOutcomeKind::REJECTED;
		r_verdict.status = make_status(StatusCode::PERMISSION_DENIED,
				DiagnosticId::TARGET_SESSION_STALE,
				p_command.owner.value);
		return r_verdict.status;
	}
	InboundCommandContext context;
	context.peer = p_peer;
	context.session = p_session;
	context.component = p_command.owner;
	context.command_sequence = p_command.command_sequence;
	context.prediction_key = p_command.prediction_key;
	context.current_tick = p_authority_tick;
	Status status = p_gate.admit(context, p_timing, r_verdict);
	if (!status.ok() ||
			r_verdict.kind ==
					CommandOutcomeKind::DUPLICATE_REPLAY) {
		r_result.status = r_verdict.status;
		return status;
	}
	TargetSessionCommand command;
	command.kind = p_command.kind;
	command.owner = p_command.owner;
	command.execution = p_command.execution;
	command.task = p_command.task;
	command.session = p_command.target_session;
	command.schema = p_command.schema;
	command.schema_version = p_command.schema_version;
	command.sequence = p_command.session_sequence;
	command.tick = p_authority_tick;
	command.has_intent = p_command.has_intent;
	command.intent = p_command.intent;
	command.prediction_key = p_command.prediction_key;
	r_result = p_coordinator.submit_session_command(command);
	p_sequences.record_command_result(p_session, p_command.owner,
			p_command.command_sequence, r_result.status);
	r_verdict.status = r_result.status;
	if (!r_result.status.ok()) {
		r_verdict.kind = CommandOutcomeKind::REJECTED;
	}
	return r_result.status;
}

} // namespace ga::proto
