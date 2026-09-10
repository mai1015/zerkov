#ifndef WEAPON_SYSTEM_CORE_CHECKED_MATH_H
#define WEAPON_SYSTEM_CORE_CHECKED_MATH_H

#include "core/wpn_status.h"

#include <cstdint>
#include <limits>

// Checked signed 64-bit integer arithmetic for authoritative canonical
// numeric state: milli-MOA/nanoradian conversion, deterministic aim
// quantization, and the canonical parts-per-million modifier algebra
// (weapon-authoring spec, "Unambiguous Integer MOA Authoring" and "Canonical
// Modifier Algebra"; weapon-runtime spec, "Deterministic Shot Direction").
//
// Every entry point detects overflow BEFORE it happens and fails closed with
// StatusCode::ARITHMETIC_ERROR / DiagnosticId::OVERFLOW_DETECTED instead of
// ever relying on signed-integer-overflow UB or silently wrapping/
// saturating. This mirrors the sibling `inv_checked_math.h` /
// `ga_fixed.cpp` / `cv_geometry.cpp` idioms: bounds-check add/sub, and an
// `__int128_t` widen-then-range-check multiply. `__int128_t` is already
// relied on elsewhere in this repository's native code, so it is not a new
// portability assumption.
namespace wpn {

inline Status checked_add_i64(std::int64_t p_a, std::int64_t p_b, std::int64_t &r_out) {
	constexpr std::int64_t k_min = std::numeric_limits<std::int64_t>::min();
	constexpr std::int64_t k_max = std::numeric_limits<std::int64_t>::max();
	if (p_b > 0 && p_a > k_max - p_b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	if (p_b < 0 && p_a < k_min - p_b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a + p_b;
	return ok_status();
}

inline Status checked_mul_i64(std::int64_t p_a, std::int64_t p_b, std::int64_t &r_out) {
	constexpr std::int64_t k_min = std::numeric_limits<std::int64_t>::min();
	constexpr std::int64_t k_max = std::numeric_limits<std::int64_t>::max();
	const __int128_t wide = static_cast<__int128_t>(p_a) * static_cast<__int128_t>(p_b);
	if (wide < static_cast<__int128_t>(k_min) || wide > static_cast<__int128_t>(k_max)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = static_cast<std::int64_t>(wide);
	return ok_status();
}

// Unsigned 64-bit checked add, used by the authority scope/epoch/tick
// envelope (tasks.md 4.13) for tick arithmetic: authority ticks are unsigned
// 64-bit values scoped to an epoch that "MUST NOT regress or wrap"
// (weapon-runtime spec, "Canonical Revision and Authority-Tick Semantics").
// Any addition that would wrap fails closed instead of relying on unsigned
// wraparound, which is well-defined in C++ but semantically wrong here.
inline Status checked_add_u64(std::uint64_t p_a, std::uint64_t p_b, std::uint64_t &r_out) {
	constexpr std::uint64_t k_max = std::numeric_limits<std::uint64_t>::max();
	if (p_b > k_max - p_a) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a + p_b;
	return ok_status();
}

// Unsigned 64-bit checked subtract (p_a - p_b), fails closed on underflow
// rather than wrapping. Used wherever tick arithmetic must subtract an
// earlier tick from a later one under an invariant that may not always hold
// defensively (e.g. a caller-supplied tick that has not yet been proven
// non-regressing).
inline Status checked_sub_u64(std::uint64_t p_a, std::uint64_t p_b, std::uint64_t &r_out) {
	if (p_b > p_a) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a - p_b;
	return ok_status();
}

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_CHECKED_MATH_H
