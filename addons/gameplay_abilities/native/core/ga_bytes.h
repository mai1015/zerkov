#ifndef GAMEPLAY_ABILITIES_CORE_BYTES_H
#define GAMEPLAY_ABILITIES_CORE_BYTES_H

#include "core/ga_limits.h"
#include "core/ga_status.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Canonical byte encoding shared by manifests, snapshots, and every network
// packet.
//
// Two rules make this deterministic across every supported architecture:
//   1. Integers are written little-endian through explicit shifts, never by
//      copying object representation.
//   2. Reading treats every byte as untrusted: the reader checks remaining
//      length before each field and checks a collection count against its limit
//      before the caller reserves anything.
namespace ga {

class ByteWriter {
public:
	explicit ByteWriter(std::size_t p_byte_limit = MAX_SNAPSHOT_BYTES) :
			byte_limit(p_byte_limit) {}

	void write_u8(std::uint8_t p_value) {
		if (overflowed_limit()) {
			return;
		}
		buffer.push_back(p_value);
	}

	void write_u16(std::uint16_t p_value) {
		write_u8(static_cast<std::uint8_t>(p_value & 0xFFU));
		write_u8(static_cast<std::uint8_t>((p_value >> 8) & 0xFFU));
	}

	void write_u32(std::uint32_t p_value) {
		for (int i = 0; i < 4; ++i) {
			write_u8(static_cast<std::uint8_t>((p_value >> (8 * i)) & 0xFFU));
		}
	}

	void write_u64(std::uint64_t p_value) {
		for (int i = 0; i < 8; ++i) {
			write_u8(static_cast<std::uint8_t>((p_value >> (8 * i)) & 0xFFULL));
		}
	}

	// Two's complement is converted explicitly so signed encoding does not
	// depend on the host representation.
	void write_i64(std::int64_t p_value) {
		write_u64(static_cast<std::uint64_t>(p_value));
	}

	void write_i32(std::int32_t p_value) {
		write_u32(static_cast<std::uint32_t>(p_value));
	}

	void write_bool(bool p_value) { write_u8(p_value ? 1 : 0); }

	// Length-prefixed UTF-8. Strings longer than the limit mark the writer
	// failed rather than truncating authoritative state.
	void write_string(const std::string &p_value) {
		if (p_value.size() > MAX_STRING_BYTES) {
			failed = true;
			return;
		}
		write_u16(static_cast<std::uint16_t>(p_value.size()));
		for (char c : p_value) {
			write_u8(static_cast<std::uint8_t>(c));
		}
	}

	// Collection headers always carry their declared limit so encoder and
	// decoder agree on the bound without duplicating the constant.
	void write_count(std::size_t p_count, std::size_t p_limit) {
		if (p_count > p_limit || p_count > MAX_COLLECTION_COUNT) {
			failed = true;
			return;
		}
		write_u16(static_cast<std::uint16_t>(p_count));
	}

	bool ok() const { return !failed; }
	std::size_t size() const { return buffer.size(); }
	const std::vector<std::uint8_t> &bytes() const { return buffer; }
	std::vector<std::uint8_t> take() { return std::move(buffer); }

	Status status() const {
		return failed ? make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, buffer.size())
					  : ok_status();
	}

private:
	bool overflowed_limit() {
		if (failed) {
			return true;
		}
		if (buffer.size() >= byte_limit) {
			failed = true;
			return true;
		}
		return false;
	}

	std::vector<std::uint8_t> buffer;
	std::size_t byte_limit = MAX_SNAPSHOT_BYTES;
	bool failed = false;
};

class ByteReader {
public:
	ByteReader(const std::uint8_t *p_data, std::size_t p_size) :
			data(p_data), size(p_size) {}

	explicit ByteReader(const std::vector<std::uint8_t> &p_bytes) :
			data(p_bytes.data()), size(p_bytes.size()) {}

	bool read_u8(std::uint8_t &r_value) {
		if (!require(1)) {
			return false;
		}
		r_value = data[cursor++];
		return true;
	}

	bool read_u16(std::uint16_t &r_value) {
		if (!require(2)) {
			return false;
		}
		r_value = static_cast<std::uint16_t>(data[cursor]) |
				static_cast<std::uint16_t>(static_cast<std::uint16_t>(data[cursor + 1]) << 8);
		cursor += 2;
		return true;
	}

	bool read_u32(std::uint32_t &r_value) {
		if (!require(4)) {
			return false;
		}
		r_value = 0;
		for (int i = 0; i < 4; ++i) {
			r_value |= static_cast<std::uint32_t>(data[cursor + i]) << (8 * i);
		}
		cursor += 4;
		return true;
	}

	bool read_u64(std::uint64_t &r_value) {
		if (!require(8)) {
			return false;
		}
		r_value = 0;
		for (int i = 0; i < 8; ++i) {
			r_value |= static_cast<std::uint64_t>(data[cursor + i]) << (8 * i);
		}
		cursor += 8;
		return true;
	}

	bool read_i64(std::int64_t &r_value) {
		std::uint64_t raw = 0;
		if (!read_u64(raw)) {
			return false;
		}
		r_value = static_cast<std::int64_t>(raw);
		return true;
	}

	bool read_i32(std::int32_t &r_value) {
		std::uint32_t raw = 0;
		if (!read_u32(raw)) {
			return false;
		}
		r_value = static_cast<std::int32_t>(raw);
		return true;
	}

	// Rejects any byte other than 0 or 1 so a malformed payload cannot smuggle
	// an out-of-range value into a bool-shaped field.
	bool read_bool(bool &r_value) {
		std::uint8_t raw = 0;
		if (!read_u8(raw)) {
			return false;
		}
		if (raw > 1) {
			fail(DiagnosticId::INVALID_ENUM);
			return false;
		}
		r_value = raw != 0;
		return true;
	}

	bool read_string(std::string &r_value) {
		std::uint16_t length = 0;
		if (!read_u16(length)) {
			return false;
		}
		if (length > MAX_STRING_BYTES) {
			fail(DiagnosticId::BYTE_LIMIT_EXCEEDED);
			return false;
		}
		if (!require(length)) {
			return false;
		}
		r_value.assign(reinterpret_cast<const char *>(data + cursor), length);
		cursor += length;
		return true;
	}

	// Validates the count against its declared limit *and* against the bytes
	// still available, so a hostile count cannot drive an allocation.
	bool read_count(std::size_t &r_count, std::size_t p_limit, std::size_t p_min_bytes_per_element = 1) {
		std::uint16_t raw = 0;
		if (!read_u16(raw)) {
			return false;
		}
		if (raw > p_limit || raw > MAX_COLLECTION_COUNT) {
			fail(DiagnosticId::COUNT_LIMIT_EXCEEDED);
			return false;
		}
		if (p_min_bytes_per_element > 0 &&
				static_cast<std::size_t>(raw) * p_min_bytes_per_element > remaining()) {
			fail(DiagnosticId::TRUNCATED_PAYLOAD);
			return false;
		}
		r_count = raw;
		return true;
	}

	bool at_end() const { return cursor == size; }
	std::size_t remaining() const { return size - cursor; }
	std::size_t consumed() const { return cursor; }
	bool ok() const { return !failed; }

	Status status() const {
		return failed ? make_status(StatusCode::DECODE_FAILED, diagnostic, cursor) : ok_status();
	}

	void fail(DiagnosticId p_diagnostic) {
		if (!failed) {
			failed = true;
			diagnostic = p_diagnostic;
		}
	}

private:
	bool require(std::size_t p_bytes) {
		if (failed) {
			return false;
		}
		if (remaining() < p_bytes) {
			fail(DiagnosticId::TRUNCATED_PAYLOAD);
			return false;
		}
		return true;
	}

	const std::uint8_t *data = nullptr;
	std::size_t size = 0;
	std::size_t cursor = 0;
	bool failed = false;
	DiagnosticId diagnostic = DiagnosticId::NONE;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_BYTES_H
