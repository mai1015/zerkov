#include "protocol/gap_event_stream.h"

namespace ga::proto {

namespace {

// Shared shape validation used by both the header-only decoder and
// `ClientEventStream::apply_batch` (which may be handed an already-decoded
// header built directly by a test or an in-process server, never routed
// through the wire codec at all). Keeping it in one place means the
// "batch_end == predecessor + event_count" invariant is only ever spelled
// out once.
Status validate_header_shape(const EventBatchHeader &p_header) {
	if (p_header.component == INVALID_ENTITY_ID) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
	}
	if (p_header.event_count == 0 || p_header.event_count > MAX_EVENTS_PER_BATCH) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_header.event_count);
	}
	if (p_header.batch_end.value != p_header.predecessor.value + p_header.event_count) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_header.batch_end.value);
	}
	return ok_status();
}

} // namespace

// ---------------------------------------------------------------------------
// EventBatchHeader encode/decode
// ---------------------------------------------------------------------------

Status encode_event_batch_header(const EventBatchHeader &p_header, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	const Status shape_status = validate_header_shape(p_header);
	if (!shape_status.ok()) {
		return shape_status;
	}

	ByteWriter writer(EVENT_BATCH_HEADER_BYTES);
	handle_write(writer, p_header.component);
	handle_write(writer, p_header.predecessor);
	handle_write(writer, p_header.batch_end);
	writer.write_u64(p_header.authoritative_tick);
	writer.write_u32(p_header.event_count);
	writer.write_u64(p_header.payload_fingerprint);

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

Status decode_event_batch_header(const std::vector<std::uint8_t> &p_bytes, EventBatchHeader &r_header) {
	r_header = EventBatchHeader{};

	if (p_bytes.size() != EVENT_BATCH_HEADER_BYTES) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}

	ByteReader reader(p_bytes);
	EntityId component;
	EventSeq predecessor;
	EventSeq batch_end;
	std::uint64_t tick_raw = 0;
	std::uint32_t event_count = 0;
	std::uint64_t fingerprint = 0;

	if (!handle_read(reader, component) || !handle_read(reader, predecessor) || !handle_read(reader, batch_end) ||
			!reader.read_u64(tick_raw) || !reader.read_u32(event_count) || !reader.read_u64(fingerprint)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}

	EventBatchHeader candidate;
	candidate.component = component;
	candidate.predecessor = predecessor;
	candidate.batch_end = batch_end;
	candidate.authoritative_tick = tick_raw;
	candidate.event_count = event_count;
	candidate.payload_fingerprint = fingerprint;

	const Status shape_status = validate_header_shape(candidate);
	if (!shape_status.ok()) {
		return shape_status;
	}

	r_header = candidate;
	return ok_status();
}

Status encode_event_batch(const EventBatchHeader &p_header, const std::vector<std::uint8_t> &p_event_payload, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	if (p_header.payload_fingerprint != ga::hash_bytes(p_event_payload)) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, p_header.payload_fingerprint);
	}

	std::vector<std::uint8_t> header_bytes;
	const Status header_status = encode_event_batch_header(p_header, header_bytes);
	if (!header_status.ok()) {
		return header_status;
	}

	const std::size_t total = header_bytes.size() + p_event_payload.size();
	if (total > MAX_EVENT_BATCH_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, total);
	}

	r_out.reserve(total);
	r_out.insert(r_out.end(), header_bytes.begin(), header_bytes.end());
	r_out.insert(r_out.end(), p_event_payload.begin(), p_event_payload.end());
	return ok_status();
}

Status decode_event_batch(const std::vector<std::uint8_t> &p_bytes, EventBatchHeader &r_header, std::vector<std::uint8_t> &r_event_payload) {
	r_header = EventBatchHeader{};
	r_event_payload.clear();

	if (p_bytes.size() < EVENT_BATCH_HEADER_BYTES) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}
	if (p_bytes.size() > MAX_EVENT_BATCH_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}

	const std::vector<std::uint8_t> header_bytes(p_bytes.begin(), p_bytes.begin() + static_cast<std::ptrdiff_t>(EVENT_BATCH_HEADER_BYTES));
	EventBatchHeader header;
	const Status header_status = decode_event_batch_header(header_bytes, header);
	if (!header_status.ok()) {
		return header_status;
	}

	std::vector<std::uint8_t> event_payload(p_bytes.begin() + static_cast<std::ptrdiff_t>(EVENT_BATCH_HEADER_BYTES), p_bytes.end());
	if (header.payload_fingerprint != ga::hash_bytes(event_payload)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, header.payload_fingerprint);
	}

	r_header = header;
	r_event_payload = std::move(event_payload);
	return ok_status();
}

// ---------------------------------------------------------------------------
// AuthoritativeEventStream
// ---------------------------------------------------------------------------

bool event_batch_fits_stream(std::size_t p_payload_bytes) {
	// Bound (1): AuthoritativeEventStream::append_batch's own check, via
	// encode_event_batch.
	if (EVENT_BATCH_HEADER_BYTES + p_payload_bytes > MAX_EVENT_BATCH_BYTES) {
		return false;
	}
	// Bound (2): encode_message's own framing check for an EVENT_BATCH
	// message wrapping the encoded batch above.
	const std::size_t encoded_batch_bytes = EVENT_BATCH_HEADER_BYTES + p_payload_bytes;
	if (MESSAGE_HEADER_BYTES + encoded_batch_bytes > message_byte_limit(MessageType::EVENT_BATCH)) {
		return false;
	}
	return true;
}

Status AuthoritativeEventStream::append_batch(EntityId p_component, Tick p_tick, std::vector<std::uint8_t> p_payload, std::size_t p_event_count, EventBatchHeader &r_header) {
	r_header = EventBatchHeader{};

	if (p_component == INVALID_ENTITY_ID) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
	}
	if (owner == INVALID_ENTITY_ID) {
		owner = p_component;
	} else if (owner != p_component) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, p_component.value);
	}
	if (p_event_count == 0 || p_event_count > MAX_EVENTS_PER_BATCH) {
		return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_event_count);
	}

	EventBatchHeader header;
	header.component = owner;
	header.predecessor = head;
	header.batch_end = EventSeq{ head.value + p_event_count };
	header.authoritative_tick = p_tick;
	header.event_count = static_cast<std::uint32_t>(p_event_count);
	header.payload_fingerprint = ga::hash_bytes(p_payload);

	std::vector<std::uint8_t> encoded;
	const Status encode_status = encode_event_batch(header, p_payload, encoded);
	if (!encode_status.ok()) {
		return encode_status;
	}

	head = header.batch_end;

	RetainedBatch retained;
	retained.header = header;
	retained.payload = std::move(p_payload);
	history[header.predecessor.value] = std::move(retained);
	if (history.size() > MAX_RETAINED_EVENT_BATCHES) {
		history.erase(history.begin());
	}

	r_header = header;
	return ok_status();
}

const EventBatchHeader *AuthoritativeEventStream::find_batch_after(EventSeq p_since) const {
	auto it = history.find(p_since.value);
	return it == history.end() ? nullptr : &it->second.header;
}

bool AuthoritativeEventStream::try_get_payload(EventSeq p_since, std::vector<std::uint8_t> &r_payload) const {
	auto it = history.find(p_since.value);
	if (it == history.end()) {
		r_payload.clear();
		return false;
	}
	r_payload = it->second.payload;
	return true;
}

// ---------------------------------------------------------------------------
// ClientEventStream
// ---------------------------------------------------------------------------

ClientEventStream::ClientEventStream(EntityId p_component) :
		owner(p_component) {}

void ClientEventStream::establish_baseline(EventSeq p_confirmed_sequence) {
	confirmed = p_confirmed_sequence;
	current_state = ClientStreamState::SYNCED;
	applied.clear();
}

void ClientEventStream::mark_needs_snapshot() {
	if (current_state == ClientStreamState::AWAITING_BASELINE) {
		return;
	}
	current_state = ClientStreamState::NEEDS_SNAPSHOT;
}

void ClientEventStream::reset_for_new_session() {
	current_state = ClientStreamState::AWAITING_BASELINE;
	confirmed = INVALID_EVENT_SEQ;
	applied.clear();
}

void ClientEventStream::note_applied(const EventBatchHeader &p_header) {
	AppliedRange range;
	range.batch_end = p_header.batch_end.value;
	range.fingerprint = p_header.payload_fingerprint;
	applied[p_header.predecessor.value] = range;
	if (applied.size() > MAX_RETAINED_EVENT_BATCHES) {
		applied.erase(applied.begin());
	}
}

Status ClientEventStream::apply_batch(const EventBatchHeader &p_header, const std::vector<std::uint8_t> &p_payload, const ApplyEventBatchFn &p_apply) {
	if (p_header.component != owner) {
		return make_status(StatusCode::UNKNOWN_NETWORK_IDENTITY, DiagnosticId::NONE, p_header.component.value);
	}

	const Status shape_status = validate_header_shape(p_header);
	if (!shape_status.ok()) {
		return shape_status;
	}
	if (p_header.payload_fingerprint != ga::hash_bytes(p_payload)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_header.payload_fingerprint);
	}

	if (current_state != ClientStreamState::SYNCED) {
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::BASELINE_MISSING, 0);
	}

	if (p_header.predecessor == confirmed) {
		const Status apply_status = p_apply ? p_apply(p_header, p_payload) : ok_status();
		if (!apply_status.ok()) {
			mark_needs_snapshot();
			return apply_status;
		}
		confirmed = p_header.batch_end;
		note_applied(p_header);
		return ok_status();
	}

	if (p_header.predecessor.value < confirmed.value) {
		if (p_header.batch_end.value > confirmed.value) {
			// Starts in already-applied territory but claims to extend past
			// it: structurally impossible for a monotonic single stream.
			return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_header.batch_end.value);
		}

		auto it = applied.find(p_header.predecessor.value);
		if (it != applied.end()) {
			if (it->second.batch_end == p_header.batch_end.value && it->second.fingerprint == p_header.payload_fingerprint) {
				return ok_status(); // Genuine idempotent duplicate: ignored.
			}
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_header.predecessor.value);
		}
		// Outside the retained window: already superseded by `confirmed`
		// either way, so it is safely ignored as a presumed-stale duplicate
		// rather than rejected -- nothing can ever be applied twice by this
		// path since `p_apply` is never invoked here.
		return ok_status();
	}

	// p_header.predecessor.value > confirmed.value: a gap.
	mark_needs_snapshot();
	return make_status(StatusCode::SEQUENCE_GAP, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_header.predecessor.value);
}

} // namespace ga::proto
