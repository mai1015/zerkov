#ifndef COMMON_UI_CORE_IDS_H
#define COMMON_UI_CORE_IDS_H

#include <cstddef>
#include <cstdint>

// The core boundary deliberately has no godot-cpp dependency. Everything the
// engine layer passes in is reduced to one of these stable value types so the
// core can be compiled and tested as an ordinary C++ library.
namespace cu {

// Interned identifier for a name (action, context, layer, glyph, ...).
using Id = std::uint32_t;

// Identity of an engine object. The Godot layer supplies a Godot ObjectID; the
// core never dereferences it and only asks the invoker whether it is alive.
using OwnerId = std::uint64_t;

// Identity of a registration or context handle handed back to consumers.
using HandleId = std::uint64_t;

// UI user scope. Convenience APIs default to user 0.
using UserId = std::uint32_t;

// Identity of the Viewport a scope belongs to.
using ViewportId = std::uint64_t;

// Physical input device identifier as reported by the platform, or
// INVALID_DEVICE when the platform exposes none.
using DeviceId = std::int32_t;

// Monotonic time in microseconds. The core never reads a clock itself; callers
// pass the current time into every entry point so behaviour stays reproducible.
using TimeUsec = std::uint64_t;

constexpr Id INVALID_ID = 0;
constexpr HandleId INVALID_HANDLE = 0;
constexpr OwnerId INVALID_OWNER = 0;
constexpr UserId DEFAULT_USER = 0;
constexpr DeviceId INVALID_DEVICE = -1;

// A routing scope. All mutable routing state is keyed by this pair so state in
// one scope can never affect another.
struct ScopeKey {
	UserId user = DEFAULT_USER;
	ViewportId viewport = 0;

	bool operator==(const ScopeKey &p_other) const {
		return user == p_other.user && viewport == p_other.viewport;
	}

	bool operator!=(const ScopeKey &p_other) const { return !(*this == p_other); }
};

struct ScopeKeyHash {
	std::size_t operator()(const ScopeKey &p_key) const {
		// Mix the two fields; viewport ids are pointer-derived and sparse.
		std::uint64_t mixed = p_key.viewport * 0x9E3779B97F4A7C15ULL;
		mixed ^= static_cast<std::uint64_t>(p_key.user) + 0x165667B19E3779F9ULL + (mixed << 6) + (mixed >> 2);
		return static_cast<std::size_t>(mixed);
	}
};

} // namespace cu

#endif // COMMON_UI_CORE_IDS_H
