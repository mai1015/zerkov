#ifndef GAMEPLAY_ABILITIES_CORE_HASH_H
#define GAMEPLAY_ABILITIES_CORE_HASH_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// FNV-1a 64-bit over canonical bytes is the single hash used for content
// manifests, snapshot fingerprints, and test equality. It is defined by
// arithmetic on explicit octets, so it produces identical results on every
// supported architecture, endianness, and locale.
namespace ga {

constexpr std::uint64_t FNV1A64_OFFSET = 0xcbf29ce484222325ULL;
constexpr std::uint64_t FNV1A64_PRIME = 0x100000001b3ULL;

// Incremental hasher. Feed it the same canonical byte stream you would encode
// and two peers agree without materializing the whole buffer.
class Hasher {
public:
	void write_byte(std::uint8_t p_byte) {
		state ^= static_cast<std::uint64_t>(p_byte);
		state *= FNV1A64_PRIME;
	}

	void write_bytes(const std::uint8_t *p_data, std::size_t p_size) {
		for (std::size_t i = 0; i < p_size; ++i) {
			write_byte(p_data[i]);
		}
	}

	void write_bytes(const std::vector<std::uint8_t> &p_data) {
		write_bytes(p_data.data(), p_data.size());
	}

	// Little-endian octets so the hash never depends on host byte order.
	void write_u64(std::uint64_t p_value) {
		for (int i = 0; i < 8; ++i) {
			write_byte(static_cast<std::uint8_t>(p_value & 0xFFULL));
			p_value >>= 8;
		}
	}

	void write_u32(std::uint32_t p_value) {
		for (int i = 0; i < 4; ++i) {
			write_byte(static_cast<std::uint8_t>(p_value & 0xFFU));
			p_value >>= 8;
		}
	}

	void write_u16(std::uint16_t p_value) {
		write_byte(static_cast<std::uint8_t>(p_value & 0xFFU));
		write_byte(static_cast<std::uint8_t>((p_value >> 8) & 0xFFU));
	}

	void write_i64(std::int64_t p_value) {
		write_u64(static_cast<std::uint64_t>(p_value));
	}

	// Length-prefixed so "ab" + "c" never hashes like "a" + "bc".
	void write_string(const std::string &p_value) {
		write_u16(static_cast<std::uint16_t>(p_value.size()));
		for (char c : p_value) {
			write_byte(static_cast<std::uint8_t>(c));
		}
	}

	std::uint64_t digest() const { return state; }

private:
	std::uint64_t state = FNV1A64_OFFSET;
};

inline std::uint64_t hash_bytes(const std::uint8_t *p_data, std::size_t p_size) {
	Hasher hasher;
	hasher.write_bytes(p_data, p_size);
	return hasher.digest();
}

inline std::uint64_t hash_bytes(const std::vector<std::uint8_t> &p_data) {
	return hash_bytes(p_data.data(), p_data.size());
}

inline std::uint64_t hash_string(const std::string &p_value) {
	Hasher hasher;
	hasher.write_string(p_value);
	return hasher.digest();
}

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_HASH_H
