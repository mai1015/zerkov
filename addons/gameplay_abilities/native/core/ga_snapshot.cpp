#include "core/ga_snapshot.h"

#include <limits>

namespace ga {

// ---------------------------------------------------------------------------
// SnapshotWriter
// ---------------------------------------------------------------------------

bool SnapshotWriter::begin_section(std::uint8_t p_kind) {
	if (!ok()) {
		return false;
	}
	if (stack.size() >= MAX_SNAPSHOT_SECTION_DEPTH) {
		mark_failed(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, stack.size());
		return false;
	}
	hasher.write_byte(p_kind);
	stack.push_back(Scope{ p_kind, ByteWriter(byte_limit) });
	return true;
}

bool SnapshotWriter::end_section() {
	if (!ok()) {
		return false;
	}
	if (stack.empty()) {
		mark_failed(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, 0);
		return false;
	}

	Scope scope = std::move(stack.back());
	stack.pop_back();

	if (!scope.buffer.ok()) {
		mark_failed(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, scope.buffer.size());
		return false;
	}

	std::vector<std::uint8_t> payload = scope.buffer.take();
	if (payload.size() > std::numeric_limits<std::uint32_t>::max()) {
		mark_failed(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, payload.size());
		return false;
	}

	const std::uint32_t length = static_cast<std::uint32_t>(payload.size());
	// The payload's own bytes were already folded into `hasher` as each
	// primitive was originally written; only the (kind, length) framing is
	// hashed here, at the moment it is structurally emitted.
	hasher.write_u32(length);

	ByteWriter &target = current();
	target.write_u8(scope.kind);
	target.write_u32(length);
	for (std::uint8_t byte : payload) {
		target.write_u8(byte);
	}

	if (!target.ok()) {
		mark_failed(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, target.size());
		return false;
	}
	return true;
}

void SnapshotWriter::write_u8(std::uint8_t p_value) {
	hasher.write_byte(p_value);
	current().write_u8(p_value);
}

void SnapshotWriter::write_u16(std::uint16_t p_value) {
	hasher.write_u16(p_value);
	current().write_u16(p_value);
}

void SnapshotWriter::write_u32(std::uint32_t p_value) {
	hasher.write_u32(p_value);
	current().write_u32(p_value);
}

void SnapshotWriter::write_u64(std::uint64_t p_value) {
	hasher.write_u64(p_value);
	current().write_u64(p_value);
}

void SnapshotWriter::write_i32(std::int32_t p_value) {
	hasher.write_u32(static_cast<std::uint32_t>(p_value));
	current().write_i32(p_value);
}

void SnapshotWriter::write_i64(std::int64_t p_value) {
	hasher.write_i64(p_value);
	current().write_i64(p_value);
}

void SnapshotWriter::write_bool(bool p_value) {
	hasher.write_byte(p_value ? 1 : 0);
	current().write_bool(p_value);
}

void SnapshotWriter::write_string(const std::string &p_value) {
	hasher.write_string(p_value);
	current().write_string(p_value);
}

void SnapshotWriter::write_fixed(Fixed p_value) {
	fixed_hash(hasher, p_value);
	fixed_write(current(), p_value);
}

void SnapshotWriter::write_count(std::size_t p_count, std::size_t p_limit) {
	if (!ok()) {
		return;
	}
	if (p_count > p_limit || p_count > MAX_COLLECTION_COUNT) {
		mark_failed(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_count);
		return;
	}
	hasher.write_u16(static_cast<std::uint16_t>(p_count));
	current().write_count(p_count, p_limit);
}

// ---------------------------------------------------------------------------
// SnapshotReader
// ---------------------------------------------------------------------------

bool SnapshotReader::begin_section(std::uint8_t p_expected_kind) {
	if (!ok()) {
		return false;
	}

	std::uint8_t kind = 0;
	if (!reader.read_u8(kind)) {
		return false;
	}
	if (kind != p_expected_kind) {
		return fail(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, kind);
	}
	hasher.write_byte(kind);

	std::uint32_t length = 0;
	if (!reader.read_u32(length)) {
		return false;
	}
	if (length > reader.remaining()) {
		return fail(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, length);
	}
	// NOT hashed here: `SnapshotWriter` cannot know a section's length until
	// its content has already been written and hashed (see
	// `SnapshotWriter::end_section`), so the reader folds `length` into the
	// digest at the matching `end_section` call instead, to reproduce the
	// identical (kind, content..., length) hash order.
	stack.push_back(Bound{ reader.consumed() + length, length });
	return true;
}

bool SnapshotReader::end_section() {
	if (!ok()) {
		return false;
	}
	if (stack.empty()) {
		return fail(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	const Bound bound = stack.back();
	stack.pop_back();
	if (reader.consumed() != bound.end_cursor) {
		return fail(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	hasher.write_u32(bound.length);
	return true;
}

bool SnapshotReader::read_u8(std::uint8_t &r_value) {
	if (!ok() || !reader.read_u8(r_value)) {
		return false;
	}
	hasher.write_byte(r_value);
	return check_bound();
}

bool SnapshotReader::read_u16(std::uint16_t &r_value) {
	if (!ok() || !reader.read_u16(r_value)) {
		return false;
	}
	hasher.write_u16(r_value);
	return check_bound();
}

bool SnapshotReader::read_u32(std::uint32_t &r_value) {
	if (!ok() || !reader.read_u32(r_value)) {
		return false;
	}
	hasher.write_u32(r_value);
	return check_bound();
}

bool SnapshotReader::read_u64(std::uint64_t &r_value) {
	if (!ok() || !reader.read_u64(r_value)) {
		return false;
	}
	hasher.write_u64(r_value);
	return check_bound();
}

bool SnapshotReader::read_i32(std::int32_t &r_value) {
	if (!ok() || !reader.read_i32(r_value)) {
		return false;
	}
	hasher.write_u32(static_cast<std::uint32_t>(r_value));
	return check_bound();
}

bool SnapshotReader::read_i64(std::int64_t &r_value) {
	if (!ok() || !reader.read_i64(r_value)) {
		return false;
	}
	hasher.write_i64(r_value);
	return check_bound();
}

bool SnapshotReader::read_bool(bool &r_value) {
	if (!ok() || !reader.read_bool(r_value)) {
		return false;
	}
	hasher.write_byte(r_value ? 1 : 0);
	return check_bound();
}

bool SnapshotReader::read_string(std::string &r_value) {
	if (!ok() || !reader.read_string(r_value)) {
		return false;
	}
	hasher.write_string(r_value);
	return check_bound();
}

bool SnapshotReader::read_fixed(Fixed &r_value) {
	if (!ok() || !fixed_read(reader, r_value)) {
		return false;
	}
	fixed_hash(hasher, r_value);
	return check_bound();
}

bool SnapshotReader::read_count(std::size_t &r_count, std::size_t p_limit, std::size_t p_min_bytes_per_element) {
	if (!ok() || !reader.read_count(r_count, p_limit, p_min_bytes_per_element)) {
		return false;
	}
	hasher.write_u16(static_cast<std::uint16_t>(r_count));
	return check_bound();
}

} // namespace ga
