#ifndef INVENTORY_SYSTEM_CORE_HASH_H
#define INVENTORY_SYSTEM_CORE_HASH_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace inv {

constexpr std::uint64_t FNV1A64_OFFSET = 0xcbf29ce484222325ULL;
constexpr std::uint64_t FNV1A64_PRIME = 0x100000001b3ULL;

class Hasher {
public:
	void write_u8(std::uint8_t p_value) {
		state ^= static_cast<std::uint64_t>(p_value);
		state *= FNV1A64_PRIME;
	}

	void write_bytes(const std::uint8_t *p_data, std::size_t p_size) {
		for (std::size_t i = 0; i < p_size; ++i) {
			write_u8(p_data[i]);
		}
	}

	void write_bytes(const std::vector<std::uint8_t> &p_data) {
		write_bytes(p_data.data(), p_data.size());
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

	void write_string(const std::string &p_value) {
		write_u32(static_cast<std::uint32_t>(p_value.size()));
		for (char c : p_value) {
			write_u8(static_cast<std::uint8_t>(c));
		}
	}

	std::uint64_t digest() const { return state; }

private:
	std::uint64_t state = FNV1A64_OFFSET;
};

inline std::uint64_t hash_bytes(const std::vector<std::uint8_t> &p_bytes) {
	Hasher hasher;
	hasher.write_bytes(p_bytes);
	return hasher.digest();
}

inline std::uint64_t hash_string(const std::string &p_value) {
	Hasher hasher;
	hasher.write_string(p_value);
	return hasher.digest();
}

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_HASH_H
