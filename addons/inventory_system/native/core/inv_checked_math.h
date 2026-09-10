#ifndef INVENTORY_SYSTEM_CORE_CHECKED_MATH_H
#define INVENTORY_SYSTEM_CORE_CHECKED_MATH_H

#include "core/inv_status.h"

#include <cstdint>
#include <limits>

// Checked signed/unsigned integer arithmetic for authoritative canonical
// numeric state: mass in milligrams (checked signed 64-bit per
// inventory-runtime spec, "Checked Canonical Numeric State"), and quantity/
// count/capacity aggregation elsewhere in the core.
//
// Every entry point detects overflow BEFORE it happens and fails closed with
// StatusCode::ARITHMETIC_ERROR / DiagnosticId::OVERFLOW_DETECTED instead of
// ever relying on signed-integer-overflow UB or silently wrapping/
// saturating. This mirrors two existing sibling-addon idioms so the checks
// stay auditable against known-good precedent:
//   - the add/sub bounds-check idiom in
//     addons/gameplay_abilities/native/core/ga_fixed.cpp (fixed_add/
//     fixed_sub);
//   - the __int128_t widen-then-range-check multiply idiom in
//     addons/common_vision/native/core/cv_geometry.cpp (checked_mul).
// __int128_t is already relied on elsewhere in this repository's native
// code, so it is not a new portability assumption.
namespace inv {

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

inline Status checked_sub_i64(std::int64_t p_a, std::int64_t p_b, std::int64_t &r_out) {
	constexpr std::int64_t k_min = std::numeric_limits<std::int64_t>::min();
	constexpr std::int64_t k_max = std::numeric_limits<std::int64_t>::max();
	// `MIN + b` (b >= 0) and `MAX + b` (b < 0) never overflow: both sum to a
	// value in [MIN, MAX] because the operands have opposite-enough signs.
	if (p_b >= 0 && p_a < k_min + p_b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	if (p_b < 0 && p_a > k_max + p_b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a - p_b;
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

inline Status checked_add_u64(std::uint64_t p_a, std::uint64_t p_b, std::uint64_t &r_out) {
	constexpr std::uint64_t k_max = std::numeric_limits<std::uint64_t>::max();
	if (p_a > k_max - p_b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a + p_b;
	return ok_status();
}

inline Status checked_mul_u64(std::uint64_t p_a, std::uint64_t p_b, std::uint64_t &r_out) {
	constexpr std::uint64_t k_max = std::numeric_limits<std::uint64_t>::max();
	if (p_a != 0 && p_b > k_max / p_a) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a * p_b;
	return ok_status();
}

inline Status checked_add_u32(std::uint32_t p_a, std::uint32_t p_b, std::uint32_t &r_out) {
	constexpr std::uint32_t k_max = std::numeric_limits<std::uint32_t>::max();
	if (p_a > k_max - p_b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_out = p_a + p_b;
	return ok_status();
}

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_CHECKED_MATH_H
