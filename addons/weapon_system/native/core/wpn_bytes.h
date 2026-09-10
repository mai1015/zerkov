#ifndef WEAPON_SYSTEM_CORE_BYTES_H
#define WEAPON_SYSTEM_CORE_BYTES_H

#include "core/wpn_limits.h"
#include "core/wpn_status.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Canonical byte primitives for the protocol layer (tasks.md 7.2; mirrors
// addons/inventory_system/native/core/inv_bytes.h byte-for-byte in
// discipline). Canonical integers are explicitly little-endian and written
// one byte at a time so the encoding is independent of host endianness,
// struct layout, and padding. Every ByteReader collection/string/blob read
// goes through a bounded helper (read_count()/read_string()/read_blob())
// that validates the declared length against an explicit limit BEFORE the
// caller can reserve or iterate at that size, so a hostile or truncated
// payload fails closed with a stable Status before any attacker-controlled
// allocation happens (weapon-protocol spec, "Bounded Malformed Input
// Handling").
namespace wpn {

class ByteWriter {
public:
	explicit ByteWriter(std::size_t p_byte_limit = MAX_SNAPSHOT_BYTES) :
			byte_limit(p_byte_limit) {}

	void write_u8(std::uint8_t p_value) {
		if (!reserve_one()) {
			return;
		}
		buffer.push_back(p_value);
	}

	void write_u16(std::uint16_t p_value) {
		for (int i = 0; i < 2; ++i) {
			write_u8(static_cast<std::uint8_t>((p_value >> (8 * i)) & 0xFFU));
		}
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

	void write_i64(std::int64_t p_value) {
		write_u64(static_cast<std::uint64_t>(p_value));
	}

	void write_bool(bool p_value) {
		write_u8(p_value ? 1 : 0);
	}

	void write_count(std::size_t p_count, std::size_t p_limit) {
		if (p_count > p_limit || p_count > static_cast<std::size_t>(UINT32_MAX)) {
			fail(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_count);
			return;
		}
		write_u32(static_cast<std::uint32_t>(p_count));
	}

	void write_string(const std::string &p_value, std::size_t p_limit = MAX_STRING_BYTES) {
		if (p_value.size() > p_limit || p_value.size() > static_cast<std::size_t>(UINT32_MAX)) {
			fail(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_value.size());
			return;
		}
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		write_raw(reinterpret_cast<const std::uint8_t *>(p_value.data()), p_value.size());
	}

	void write_blob(const std::vector<std::uint8_t> &p_value, std::size_t p_limit = MAX_MANIFEST_ENTRY_BYTES) {
		if (p_value.size() > p_limit || p_value.size() > static_cast<std::size_t>(UINT32_MAX)) {
			fail(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_value.size());
			return;
		}
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		write_raw(p_value.data(), p_value.size());
	}

	bool ok() const { return failure.ok(); }
	std::size_t size() const { return buffer.size(); }
	const std::vector<std::uint8_t> &bytes() const { return buffer; }
	std::vector<std::uint8_t> take() { return std::move(buffer); }
	Status status() const { return failure; }

private:
	bool reserve_one() {
		if (!failure.ok()) {
			return false;
		}
		if (buffer.size() >= byte_limit) {
			fail(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, buffer.size() + 1);
			return false;
		}
		return true;
	}

	void write_raw(const std::uint8_t *p_data, std::size_t p_size) {
		for (std::size_t i = 0; i < p_size; ++i) {
			write_u8(p_data[i]);
		}
	}

	void fail(StatusCode p_code, DiagnosticId p_diagnostic, std::uint64_t p_detail) {
		if (failure.ok()) {
			failure = make_status(p_code, p_diagnostic, p_detail);
		}
	}

	std::vector<std::uint8_t> buffer;
	std::size_t byte_limit = MAX_SNAPSHOT_BYTES;
	Status failure;
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

	// Reads a length-prefixed collection count, validated against p_limit and
	// (when p_min_bytes_per_entry > 0) against the bytes actually remaining,
	// so a declared count is refused before the caller reserves any storage
	// at that size (weapon-protocol spec, "Packet declares oversized
	// snapshot").
	bool read_count(std::size_t &r_count, std::size_t p_limit, std::size_t p_min_bytes_per_entry = 0) {
		std::uint32_t raw = 0;
		if (!read_u32(raw)) {
			return false;
		}
		if (raw > p_limit) {
			fail(DiagnosticId::COUNT_LIMIT_EXCEEDED);
			return false;
		}
		if (p_min_bytes_per_entry > 0 &&
				static_cast<std::size_t>(raw) > remaining() / p_min_bytes_per_entry) {
			fail(DiagnosticId::DECODE_TRUNCATED);
			return false;
		}
		r_count = static_cast<std::size_t>(raw);
		return true;
	}

	bool read_string(std::string &r_value, std::size_t p_limit = MAX_STRING_BYTES) {
		std::uint32_t raw = 0;
		if (!read_u32(raw)) {
			return false;
		}
		if (raw > p_limit) {
			fail(DiagnosticId::BYTE_LIMIT_EXCEEDED);
			return false;
		}
		if (!require(raw)) {
			return false;
		}
		r_value.assign(reinterpret_cast<const char *>(data + cursor), raw);
		cursor += raw;
		return true;
	}

	bool read_blob(std::vector<std::uint8_t> &r_value, std::size_t p_limit = MAX_MANIFEST_ENTRY_BYTES) {
		std::uint32_t raw = 0;
		if (!read_u32(raw)) {
			return false;
		}
		if (raw > p_limit) {
			fail(DiagnosticId::BYTE_LIMIT_EXCEEDED);
			return false;
		}
		if (!require(raw)) {
			return false;
		}
		r_value.assign(data + cursor, data + cursor + raw);
		cursor += raw;
		return true;
	}

	bool at_end() const { return cursor == size; }
	std::size_t remaining() const { return size - cursor; }
	std::size_t consumed() const { return cursor; }
	bool ok() const { return failure.ok(); }
	Status status() const { return failure; }

	void fail(DiagnosticId p_diagnostic) {
		if (failure.ok()) {
			failure = make_status(StatusCode::DECODE_FAILED, p_diagnostic, cursor);
		}
	}

private:
	bool require(std::size_t p_bytes) {
		if (!failure.ok()) {
			return false;
		}
		if (p_bytes > remaining()) {
			fail(DiagnosticId::DECODE_TRUNCATED);
			return false;
		}
		return true;
	}

	const std::uint8_t *data = nullptr;
	std::size_t size = 0;
	std::size_t cursor = 0;
	Status failure;
};

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_BYTES_H
