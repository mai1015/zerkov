#ifndef LEVEL_TASK_SYSTEM_CORE_HASH_H
#define LEVEL_TASK_SYSTEM_CORE_HASH_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace lts {

// FNV-1a is used here because it is small, specified over bytes, and already
// used by the repository's other engine-independent cores. Every multi-byte
// scalar is written little-endian and every string/byte collection is length
// prefixed before its contents are hashed. Definition encoders therefore do
// not depend on host endianness or allocator/container iteration order.
constexpr std::uint64_t FNV1A64_OFFSET = UINT64_C(0xcbf29ce484222325);
constexpr std::uint64_t FNV1A64_PRIME = UINT64_C(0x100000001b3);

class Hasher {
public:
	void write_u8(std::uint8_t p_value) {
		state ^= static_cast<std::uint64_t>(p_value);
		state *= FNV1A64_PRIME;
	}

	void write_u16(std::uint16_t p_value) {
		for (int i = 0; i < 2; ++i) {
			write_u8(static_cast<std::uint8_t>((p_value >> (i * 8)) & 0xffU));
		}
	}

	void write_u32(std::uint32_t p_value) {
		for (int i = 0; i < 4; ++i) {
			write_u8(static_cast<std::uint8_t>((p_value >> (i * 8)) & 0xffU));
		}
	}

	void write_u64(std::uint64_t p_value) {
		for (int i = 0; i < 8; ++i) {
			write_u8(static_cast<std::uint8_t>((p_value >> (i * 8)) & 0xffULL));
		}
	}

	void write_i8(std::int8_t p_value) { write_u8(static_cast<std::uint8_t>(p_value)); }
	void write_i16(std::int16_t p_value) { write_u16(static_cast<std::uint16_t>(p_value)); }
	void write_i32(std::int32_t p_value) { write_u32(static_cast<std::uint32_t>(p_value)); }
	void write_i64(std::int64_t p_value) { write_u64(static_cast<std::uint64_t>(p_value)); }
	void write_bool(bool p_value) { write_u8(p_value ? 1U : 0U); }

	void write_string(const std::string &p_value) {
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		for (unsigned char byte : p_value) write_u8(byte);
	}

	void write_bytes(const std::vector<std::uint8_t> &p_value) {
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		for (std::uint8_t byte : p_value) write_u8(byte);
	}

	std::uint64_t digest() const { return state; }

private:
	std::uint64_t state = FNV1A64_OFFSET;
};

inline std::uint64_t hash_string(const std::string &p_value) {
	Hasher hasher;
	hasher.write_string(p_value);
	return hasher.digest();
}

inline std::uint64_t hash_bytes(const std::vector<std::uint8_t> &p_value) {
	Hasher hasher;
	hasher.write_bytes(p_value);
	return hasher.digest();
}

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_HASH_H
