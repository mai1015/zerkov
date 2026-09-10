#ifndef WEAPON_SYSTEM_CORE_HASH_H
#define WEAPON_SYSTEM_CORE_HASH_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace wpn {

constexpr std::uint64_t FNV1A64_OFFSET = UINT64_C(0xcbf29ce484222325);
constexpr std::uint64_t FNV1A64_PRIME = UINT64_C(0x100000001b3);

class Hasher {
public:
	void write_u8(std::uint8_t p_value) {
		state ^= p_value;
		state *= FNV1A64_PRIME;
	}
	void write_u16(std::uint16_t p_value) {
		for (int i = 0; i < 2; ++i) write_u8(static_cast<std::uint8_t>((p_value >> (i * 8)) & 0xffU));
	}
	void write_u32(std::uint32_t p_value) {
		for (int i = 0; i < 4; ++i) write_u8(static_cast<std::uint8_t>((p_value >> (i * 8)) & 0xffU));
	}
	void write_u64(std::uint64_t p_value) {
		for (int i = 0; i < 8; ++i) write_u8(static_cast<std::uint8_t>((p_value >> (i * 8)) & 0xffULL));
	}
	void write_i64(std::int64_t p_value) { write_u64(static_cast<std::uint64_t>(p_value)); }
	void write_bool(bool p_value) { write_u8(p_value ? 1 : 0); }
	void write_string(const std::string &p_value) {
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		for (char c : p_value) write_u8(static_cast<std::uint8_t>(c));
	}
	void write_bytes(const std::vector<std::uint8_t> &p_value) {
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

// fnv1a64 over a raw byte sequence exactly as written (no length prefix),
// used by the protocol layer (protocol/wpn_protocol_codec.h) to hash an
// already-canonically-encoded DTO's byte buffer for golden fixtures and
// idempotent-command-identity payload comparison.
inline std::uint64_t hash_bytes(const std::vector<std::uint8_t> &p_value) {
	Hasher hasher;
	hasher.write_bytes(p_value);
	return hasher.digest();
}

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_HASH_H
