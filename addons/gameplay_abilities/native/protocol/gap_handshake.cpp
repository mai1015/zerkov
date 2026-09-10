#include "protocol/gap_handshake.h"

namespace ga::proto {

namespace {

// Both DTOs share an identical field set (see the on-wire layout comment in
// gap_handshake.h), so one templated encode/decode pair serves both public
// entry points below instead of duplicating the same thirteen field
// reads/writes twice.
template <typename T>
Status encode_fields(const T &p_value, std::vector<std::uint8_t> &r_out) {
	r_out.clear();

	ByteWriter writer(MAX_HANDSHAKE_BYTES);
	writer.write_u16(p_value.protocol_version);
	writer.write_u8(p_value.api_version_major);
	writer.write_u8(p_value.api_version_minor);
	writer.write_u8(p_value.api_version_patch);
	writer.write_u32(p_value.required_features);
	writer.write_u32(p_value.tick_rate);
	writer.write_i64(p_value.fixed_point_scale);
	writer.write_u64(p_value.identifier_dictionary_fingerprint);
	writer.write_u64(p_value.content_manifest_fingerprint);
	writer.write_u32(p_value.max_command_packet_bytes);
	writer.write_u32(p_value.max_event_batch_bytes);
	writer.write_u32(p_value.max_snapshot_bytes);
	writer.write_u32(p_value.max_handshake_bytes);
	writer.write_string(p_value.manifest_algorithm);

	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ok_status();
}

template <typename T>
Status decode_fields(const std::vector<std::uint8_t> &p_bytes, T &r_value) {
	r_value = T{};

	// Reject an oversized buffer before a single field is parsed -- the
	// handshake byte limit is a hard cap on the whole message, not just an
	// artifact of individual field bounds.
	if (p_bytes.size() > MAX_HANDSHAKE_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}

	ByteReader reader(p_bytes);
	T value;
	if (!reader.read_u16(value.protocol_version) ||
			!reader.read_u8(value.api_version_major) ||
			!reader.read_u8(value.api_version_minor) ||
			!reader.read_u8(value.api_version_patch) ||
			!reader.read_u32(value.required_features) ||
			!reader.read_u32(value.tick_rate) ||
			!reader.read_i64(value.fixed_point_scale) ||
			!reader.read_u64(value.identifier_dictionary_fingerprint) ||
			!reader.read_u64(value.content_manifest_fingerprint) ||
			!reader.read_u32(value.max_command_packet_bytes) ||
			!reader.read_u32(value.max_event_batch_bytes) ||
			!reader.read_u32(value.max_snapshot_bytes) ||
			!reader.read_u32(value.max_handshake_bytes) ||
			!reader.read_string(value.manifest_algorithm)) {
		return reader.status();
	}
	// Every declared field consumed, and nothing left over: a payload with
	// trailing bytes beyond the last declared field is internally
	// inconsistent and must fail closed rather than be silently ignored.
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}

	r_value = value;
	return ok_status();
}

Status fail_with(HandshakeResult &r_result, StatusCode p_code, DiagnosticId p_diagnostic, std::uint64_t p_detail, HandshakeIncompatibilityReason p_reason) {
	r_result.compatible = false;
	r_result.reason = p_reason;
	r_result.status = make_status(p_code, p_diagnostic, p_detail);
	return r_result.status;
}

// Shared field-copy pattern (matching encode_fields<T>/decode_fields<T>
// above): `HandshakeRequest`/`HandshakeResponse` are layout-identical, so one
// templated copy serves both `to_response`/`to_request` directions instead
// of duplicating the same thirteen field assignments twice.
template <typename To, typename From>
To convert_fields(const From &p_value) {
	To out;
	out.protocol_version = p_value.protocol_version;
	out.api_version_major = p_value.api_version_major;
	out.api_version_minor = p_value.api_version_minor;
	out.api_version_patch = p_value.api_version_patch;
	out.required_features = p_value.required_features;
	out.tick_rate = p_value.tick_rate;
	out.fixed_point_scale = p_value.fixed_point_scale;
	out.identifier_dictionary_fingerprint = p_value.identifier_dictionary_fingerprint;
	out.content_manifest_fingerprint = p_value.content_manifest_fingerprint;
	out.max_command_packet_bytes = p_value.max_command_packet_bytes;
	out.max_event_batch_bytes = p_value.max_event_batch_bytes;
	out.max_snapshot_bytes = p_value.max_snapshot_bytes;
	out.max_handshake_bytes = p_value.max_handshake_bytes;
	out.manifest_algorithm = p_value.manifest_algorithm;
	return out;
}

} // namespace

Status encode_handshake_request(const HandshakeRequest &p_request, std::vector<std::uint8_t> &r_out) {
	return encode_fields(p_request, r_out);
}

Status decode_handshake_request(const std::vector<std::uint8_t> &p_bytes, HandshakeRequest &r_request) {
	return decode_fields(p_bytes, r_request);
}

Status encode_handshake_response(const HandshakeResponse &p_response, std::vector<std::uint8_t> &r_out) {
	return encode_fields(p_response, r_out);
}

Status decode_handshake_response(const std::vector<std::uint8_t> &p_bytes, HandshakeResponse &r_response) {
	return decode_fields(p_bytes, r_response);
}

HandshakeResponse to_response(const HandshakeRequest &p_request) {
	return convert_fields<HandshakeResponse>(p_request);
}

HandshakeRequest to_request(const HandshakeResponse &p_response) {
	return convert_fields<HandshakeRequest>(p_response);
}

Status evaluate_handshake(const HandshakeRequest &p_remote, const HandshakeRequest &p_local, HandshakeResult &r_result) {
	r_result = HandshakeResult{};

	if (p_remote.protocol_version != p_local.protocol_version) {
		return fail_with(r_result, StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS,
				p_remote.protocol_version, HandshakeIncompatibilityReason::PROTOCOL_VERSION);
	}

	// Checked via ga::negotiate_features rather than a hand-rolled bitmask
	// comparison so this stays byte-for-byte consistent with every other
	// caller of that function (see ga_version.h): an unrecognized required
	// bit is exactly as unsupported as a recognized one this build lacks.
	std::uint32_t missing = 0;
	const Status feature_status = negotiate_features(p_local.required_features, p_remote.required_features, missing);
	if (!feature_status.ok()) {
		r_result.missing_required_features = missing;
		return fail_with(r_result, feature_status.code, feature_status.diagnostic, missing,
				HandshakeIncompatibilityReason::REQUIRED_FEATURE);
	}

	if (p_remote.tick_rate != p_local.tick_rate) {
		return fail_with(r_result, StatusCode::MANIFEST_MISMATCH, DiagnosticId::TICK_RATE_UNSUPPORTED,
				p_remote.tick_rate, HandshakeIncompatibilityReason::TICK_RATE);
	}
	if (p_remote.fixed_point_scale != p_local.fixed_point_scale) {
		return fail_with(r_result, StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS,
				static_cast<std::uint64_t>(p_remote.fixed_point_scale), HandshakeIncompatibilityReason::FIXED_POINT_SCALE);
	}
	if (p_remote.identifier_dictionary_fingerprint != p_local.identifier_dictionary_fingerprint) {
		return fail_with(r_result, StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS,
				p_remote.identifier_dictionary_fingerprint, HandshakeIncompatibilityReason::IDENTIFIER_DICTIONARY);
	}
	if (p_remote.content_manifest_fingerprint != p_local.content_manifest_fingerprint) {
		return fail_with(r_result, StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS,
				p_remote.content_manifest_fingerprint, HandshakeIncompatibilityReason::CONTENT_MANIFEST);
	}
	if (p_remote.max_command_packet_bytes != p_local.max_command_packet_bytes ||
			p_remote.max_event_batch_bytes != p_local.max_event_batch_bytes ||
			p_remote.max_snapshot_bytes != p_local.max_snapshot_bytes ||
			p_remote.max_handshake_bytes != p_local.max_handshake_bytes) {
		return fail_with(r_result, StatusCode::MANIFEST_MISMATCH, DiagnosticId::BYTE_LIMIT_EXCEEDED,
				p_remote.max_command_packet_bytes, HandshakeIncompatibilityReason::PACKET_LIMITS);
	}

	r_result.compatible = true;
	r_result.reason = HandshakeIncompatibilityReason::NONE;
	r_result.status = ok_status();
	return ok_status();
}

} // namespace ga::proto
