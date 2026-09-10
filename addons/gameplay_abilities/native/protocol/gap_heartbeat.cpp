#include "protocol/gap_heartbeat.h"

namespace ga::proto {

Status encode_heartbeat(const HeartbeatPayload &p_heartbeat, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	ByteWriter writer(HEARTBEAT_PAYLOAD_BYTES);
	writer.write_u64(p_heartbeat.authoritative_tick);
	handle_write(writer, p_heartbeat.stream_head_sequence);

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

Status decode_heartbeat(const std::vector<std::uint8_t> &p_bytes, HeartbeatPayload &r_heartbeat) {
	r_heartbeat = HeartbeatPayload{};

	if (p_bytes.size() != HEARTBEAT_PAYLOAD_BYTES) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}

	ByteReader reader(p_bytes);
	std::uint64_t tick_raw = 0;
	EventSeq head;
	if (!reader.read_u64(tick_raw) || !handle_read(reader, head)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	// Redundant with the exact-length check above given today's fixed field
	// set (matching `decode_resync_request`'s own identical redundancy,
	// gap_resync.cpp) -- kept anyway as defense in depth against a future
	// field being added to the struct without updating
	// `HEARTBEAT_PAYLOAD_BYTES` to match.
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}

	r_heartbeat.authoritative_tick = tick_raw;
	r_heartbeat.stream_head_sequence = head;
	return ok_status();
}

} // namespace ga::proto
