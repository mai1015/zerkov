#include "protocol/gap_resync.h"

#include <utility>

namespace ga::proto {

// ---------------------------------------------------------------------------
// ResyncRequest
// ---------------------------------------------------------------------------

Status encode_resync_request(const ResyncRequest &p_request, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	if (!is_valid_resync_reason(static_cast<std::uint8_t>(p_request.reason))) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, static_cast<std::uint64_t>(p_request.reason));
	}

	ByteWriter writer(RESYNC_REQUEST_BYTES);
	writer.write_u32(p_request.session);
	handle_write(writer, p_request.component);
	handle_write(writer, p_request.confirmed_sequence);
	writer.write_u8(static_cast<std::uint8_t>(p_request.reason));

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

Status decode_resync_request(const std::vector<std::uint8_t> &p_bytes, ResyncRequest &r_request) {
	r_request = ResyncRequest{};

	if (p_bytes.size() != RESYNC_REQUEST_BYTES) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}

	ByteReader reader(p_bytes);
	std::uint32_t session_raw = 0;
	EntityId component;
	EventSeq confirmed;
	std::uint8_t reason_raw = 0;

	if (!reader.read_u32(session_raw) || !handle_read(reader, component) || !handle_read(reader, confirmed) || !reader.read_u8(reason_raw)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	if (!is_valid_resync_reason(reason_raw)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, reason_raw);
	}

	r_request.session = session_raw;
	r_request.component = component;
	r_request.confirmed_sequence = confirmed;
	r_request.reason = static_cast<ResyncReason>(reason_raw);
	return ok_status();
}

// ---------------------------------------------------------------------------
// SnapshotEnvelope
// ---------------------------------------------------------------------------

Status encode_snapshot_envelope(const SnapshotEnvelope &p_envelope, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	if (p_envelope.payload.size() > MAX_SNAPSHOT_BYTES) {
		// Fail closed rather than truncate: "the bridge does not emit a
		// truncated authoritative state."
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_envelope.payload.size());
	}

	ByteWriter writer(SNAPSHOT_ENVELOPE_FIXED_BYTES + MAX_SNAPSHOT_BYTES);
	handle_write(writer, p_envelope.component);
	writer.write_u64(p_envelope.authoritative_tick);
	handle_write(writer, p_envelope.valid_as_of);
	writer.write_u64(p_envelope.manifest_fingerprint);
	writer.write_u64(p_envelope.payload_fingerprint);
	writer.write_u32(static_cast<std::uint32_t>(p_envelope.payload.size()));
	for (std::uint8_t byte : p_envelope.payload) {
		writer.write_u8(byte);
	}

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

Status decode_snapshot_envelope(const std::vector<std::uint8_t> &p_bytes, SnapshotEnvelope &r_envelope) {
	r_envelope = SnapshotEnvelope{};

	if (p_bytes.size() < SNAPSHOT_ENVELOPE_FIXED_BYTES) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}

	ByteReader reader(p_bytes);
	EntityId component;
	std::uint64_t tick_raw = 0;
	EventSeq valid_as_of;
	std::uint64_t manifest_fingerprint = 0;
	std::uint64_t payload_fingerprint = 0;
	std::uint32_t payload_length = 0;

	if (!handle_read(reader, component) || !reader.read_u64(tick_raw) || !handle_read(reader, valid_as_of) ||
			!reader.read_u64(manifest_fingerprint) || !reader.read_u64(payload_fingerprint) || !reader.read_u32(payload_length)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}

	if (payload_length > MAX_SNAPSHOT_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, payload_length);
	}
	if (static_cast<std::size_t>(payload_length) != reader.remaining()) {
		// Rejects a declared length either longer OR shorter than what
		// actually follows -- never guessed, never zero-padded.
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, payload_length);
	}

	std::vector<std::uint8_t> payload;
	payload.reserve(payload_length); // Safe: payload_length was bounds-checked above before this reserve.
	for (std::uint32_t i = 0; i < payload_length; ++i) {
		std::uint8_t byte = 0;
		if (!reader.read_u8(byte)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
		}
		payload.push_back(byte);
	}

	if (payload_fingerprint != ga::hash_bytes(payload)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, payload_fingerprint);
	}

	r_envelope.component = component;
	r_envelope.authoritative_tick = tick_raw;
	r_envelope.valid_as_of = valid_as_of;
	r_envelope.manifest_fingerprint = manifest_fingerprint;
	r_envelope.payload_fingerprint = payload_fingerprint;
	r_envelope.payload = std::move(payload);
	return ok_status();
}

// ---------------------------------------------------------------------------
// Client-side snapshot application
// ---------------------------------------------------------------------------

Status apply_snapshot_envelope(const SnapshotEnvelope &p_envelope, std::uint64_t p_expected_manifest_fingerprint, ClientEventStream &r_stream, const ApplySnapshotFn &p_apply) {
	if (p_envelope.component != r_stream.component()) {
		r_stream.mark_needs_snapshot();
		return make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY, DiagnosticId::NONE, p_envelope.component.value);
	}
	if (p_envelope.manifest_fingerprint != p_expected_manifest_fingerprint) {
		r_stream.mark_needs_snapshot();
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_envelope.manifest_fingerprint);
	}

	const Status apply_status = p_apply ? p_apply(p_envelope) : ok_status();
	if (!apply_status.ok()) {
		r_stream.mark_needs_snapshot();
		return apply_status;
	}

	r_stream.establish_baseline(p_envelope.valid_as_of);
	return ok_status();
}

// ---------------------------------------------------------------------------
// ResyncCoordinator
// ---------------------------------------------------------------------------

Status ResyncCoordinator::finalize_envelope(EntityId p_component, const SnapshotProducer &p_producer, SnapshotEnvelope &r_envelope) {
	r_envelope = SnapshotEnvelope{};

	if (!p_producer) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, 0);
	}

	SnapshotProductionResult production;
	const Status production_status = p_producer(p_component, production);
	if (!production_status.ok()) {
		return production_status;
	}

	SnapshotEnvelope envelope;
	envelope.component = p_component;
	envelope.authoritative_tick = production.authoritative_tick;
	envelope.valid_as_of = production.valid_as_of;
	envelope.manifest_fingerprint = production.manifest_fingerprint;
	envelope.payload_fingerprint = ga::hash_bytes(production.payload);
	envelope.payload = std::move(production.payload);

	// Reuses encode_snapshot_envelope's own MAX_SNAPSHOT_BYTES check rather
	// than duplicating it a second place; the encoded bytes themselves are
	// discarded here (a caller that wants wire bytes calls
	// encode_snapshot_envelope itself).
	std::vector<std::uint8_t> encoded_probe;
	const Status size_status = encode_snapshot_envelope(envelope, encoded_probe);
	if (!size_status.ok()) {
		return size_status;
	}

	r_envelope = std::move(envelope);
	return ok_status();
}

Status ResyncCoordinator::produce_unconditional(EntityId p_component, ResyncTrigger p_trigger, const SnapshotProducer &p_producer, SnapshotEnvelope &r_envelope) {
	(void)p_trigger; // Informational only today; every trigger shares one production path (see class comment).
	return finalize_envelope(p_component, p_producer, r_envelope);
}

Status ResyncCoordinator::produce_for_request(PeerId p_peer, const ResyncRequest &p_request, Tick p_now, const SessionTiming &p_timing, const SnapshotProducer &p_producer, SnapshotEnvelope &r_envelope) {
	r_envelope = SnapshotEnvelope{};

	const Status rate_status = rate.admit_resync(p_peer, p_now, p_timing);
	if (!rate_status.ok()) {
		if (strikes != nullptr) {
			strikes->on_rejection(p_peer, rate_status.code, rate_status.detail);
		}
		// p_producer is never invoked: no snapshot work for a flooding peer.
		return rate_status;
	}

	return finalize_envelope(p_request.component, p_producer, r_envelope);
}

} // namespace ga::proto
