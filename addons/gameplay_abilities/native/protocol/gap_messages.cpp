#include "protocol/gap_messages.h"

namespace ga::proto {

std::size_t message_byte_limit(MessageType p_type) {
	// Every limit below is an existing ga_limits.h constant reused for its
	// closest-matching message shape, so this table never introduces a
	// second literal for a bound ga_limits.h already governs:
	//   - HANDSHAKE_REQUEST/RESPONSE carry the full compatibility DTO ->
	//     MAX_HANDSHAKE_BYTES, the constant ga_limits.h names for exactly
	//     this purpose.
	//   - ACTIVATION_COMMAND -> MAX_COMMAND_PACKET_BYTES (its own named
	//     bound).
	//   - COMMAND_ACK/COMMAND_REJECT/RESYNC_REQUEST/HEARTBEAT carry a handful
	//     of scalar ids plus at most one bounded diagnostic and never a bulk
	//     gameplay payload, so they reuse MAX_DIAGNOSTIC_BYTES -- the
	//     constant ga_limits.h already defines for "a bounded diagnostic
	//     message". HEARTBEAT is the smallest of the four (16 fixed bytes,
	//     see gap_heartbeat.h's `HEARTBEAT_PAYLOAD_BYTES`) but shares the
	//     same shape/size class, so it reuses the same constant rather than
	//     introducing a dedicated one for an even smaller bound.
	//   - EVENT_BATCH -> MAX_EVENT_BATCH_BYTES. Task 5.2 (add-granular-
	//     delta-replication-2026-07-27): an owner EVENT_BATCH payload is now
	//     a canonical granular delta (`ga::proto::encode_delta_batch`,
	//     gap_delta_messages.h) rather than a full snapshot, but this bound
	//     still governs it unchanged -- a delta is, by construction, no
	//     larger than the section-by-section canonical bytes it re-encodes
	//     on the `DeltaSectionMode::FULL_REENCODE` fallback path, so it
	//     never needs MORE room than the pre-existing full-snapshot-as-batch
	//     shape did; `GameplayAbilityNetworkBridge::send_owner_event_batch`
	//     still checks `event_batch_fits_stream` before ever appending one,
	//     falling back to a fresh `SNAPSHOT` (`ResyncTrigger::DELTA_OVERFLOW`)
	//     for the rare delta that does not fit, exactly like the pre-existing
	//     `BATCH_OVERFLOW` fallback did.
	//   - SNAPSHOT -> MAX_SNAPSHOT_BYTES.
	//   - PRESENTATION_EVENT carries an event identity plus small context,
	//     the same shape/size class as an activation command, so it reuses
	//     MAX_COMMAND_PACKET_BYTES rather than inventing a new constant.
	switch (p_type) {
		case MessageType::HANDSHAKE_REQUEST:
		case MessageType::HANDSHAKE_RESPONSE:
			return MAX_HANDSHAKE_BYTES;
		case MessageType::ACTIVATION_COMMAND:
		case MessageType::TASK_INPUT_COMMAND:
		case MessageType::TARGET_COMMAND:
			return MAX_COMMAND_PACKET_BYTES;
		case MessageType::COMMAND_ACK:
		case MessageType::COMMAND_REJECT:
		case MessageType::RESYNC_REQUEST:
		case MessageType::HEARTBEAT:
			return MAX_DIAGNOSTIC_BYTES;
		case MessageType::EVENT_BATCH:
			return MAX_EVENT_BATCH_BYTES;
		case MessageType::SNAPSHOT:
		case MessageType::TARGET_STATE:
			return MAX_SNAPSHOT_BYTES;
		case MessageType::PRESENTATION_EVENT:
		case MessageType::TASK_STATE:
		case MessageType::TARGET_OUTCOME:
			return MAX_COMMAND_PACKET_BYTES;
	}
	// Unreachable for any value that passed is_valid_message_type(); a
	// defensive zero refuses to treat an unrecognized type as "unbounded".
	return 0;
}

Status encode_message(MessageType p_type, SessionId p_session_id, const std::vector<std::uint8_t> &p_payload, std::size_t p_byte_limit, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	if (!is_valid_message_type(static_cast<std::uint8_t>(p_type))) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, static_cast<std::uint64_t>(p_type));
	}

	const std::size_t type_limit = message_byte_limit(p_type);
	if (p_payload.size() > type_limit) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_payload.size());
	}

	const std::size_t framed_size = MESSAGE_HEADER_BYTES + p_payload.size();
	if (framed_size > p_byte_limit) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, framed_size);
	}

	ByteWriter writer(framed_size);
	writer.write_u16(protocol_version());
	writer.write_u8(static_cast<std::uint8_t>(p_type));
	writer.write_u8(0); // reserved
	writer.write_u32(p_session_id);
	writer.write_u32(static_cast<std::uint32_t>(p_payload.size()));
	for (std::uint8_t byte : p_payload) {
		writer.write_u8(byte);
	}

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

Status encode_message(MessageType p_type, const std::vector<std::uint8_t> &p_payload, std::size_t p_byte_limit, std::vector<std::uint8_t> &r_out) {
	return encode_message(p_type, INVALID_SESSION_ID, p_payload, p_byte_limit, r_out);
}

Status decode_message(const std::vector<std::uint8_t> &p_bytes, std::size_t p_byte_limit, MessageHeader &r_header, std::vector<std::uint8_t> &r_payload) {
	r_header = MessageHeader{};
	r_payload.clear();

	if (p_bytes.size() < MESSAGE_HEADER_BYTES) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}

	ByteReader reader(p_bytes);
	std::uint16_t version = 0;
	std::uint8_t type_raw = 0;
	std::uint8_t reserved = 0;
	std::uint32_t session_id_raw = 0;
	std::uint32_t declared_length = 0;

	// Every field is read before any of them is validated: a truncated
	// buffer (fewer than 12 bytes, already excluded above, but also a
	// mid-field cut cannot happen since we already checked the full header
	// length) fails via ByteReader's own bounds checks first.
	if (!reader.read_u16(version) || !reader.read_u8(type_raw) || !reader.read_u8(reserved) ||
			!reader.read_u32(session_id_raw) || !reader.read_u32(declared_length)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}

	if (version != protocol_version()) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, version);
	}
	if (!is_valid_message_type(type_raw)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, type_raw);
	}
	if (reserved != 0) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, reserved);
	}

	const MessageType type = static_cast<MessageType>(type_raw);
	const std::size_t remaining = reader.remaining();
	if (static_cast<std::size_t>(declared_length) != remaining) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, declared_length);
	}

	const std::size_t type_limit = message_byte_limit(type);
	if (static_cast<std::size_t>(declared_length) > type_limit) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, declared_length);
	}
	if (MESSAGE_HEADER_BYTES + static_cast<std::size_t>(declared_length) > p_byte_limit) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, declared_length);
	}

	// Only now, after every validation above, do we copy payload bytes --
	// a hostile declared_length can never reach this line without first
	// passing the exact-match check against the bytes actually present.
	r_header.protocol_version = version;
	r_header.message_type = type;
	r_header.session_id = session_id_raw;
	r_header.payload_length = declared_length;
	r_payload.assign(p_bytes.begin() + static_cast<std::ptrdiff_t>(MESSAGE_HEADER_BYTES), p_bytes.end());
	return ok_status();
}

} // namespace ga::proto
