#include "core/ga_fixed.h"

#include <cmath>
#include <limits>

namespace ga {

namespace {

constexpr std::int64_t kInt64Max = std::numeric_limits<std::int64_t>::max();
constexpr std::int64_t kInt64Min = std::numeric_limits<std::int64_t>::min();

#if !defined(__SIZEOF_INT128__)

// ---------------------------------------------------------------------------
// Portable fallback: manual 128-bit long multiplication/division used only on
// toolchains that do not provide `__int128`. This path must produce results
// bit-for-bit identical to the `__int128` path below for every input.
// ---------------------------------------------------------------------------

struct Wide128 {
	std::uint64_t hi = 0;
	std::uint64_t lo = 0;
};

// Two's complement magnitude via unsigned arithmetic, which is well-defined
// (wraps rather than overflows) for every int64 value including INT64_MIN.
std::uint64_t to_magnitude(std::int64_t p_value) {
	if (p_value >= 0) {
		return static_cast<std::uint64_t>(p_value);
	}
	return (~static_cast<std::uint64_t>(p_value)) + 1ULL;
}

// Reconstructs a signed int64 from a magnitude and sign, rejecting a
// magnitude that does not fit (i.e. an overflow) rather than wrapping.
bool from_magnitude(std::uint64_t p_magnitude, bool p_negative, std::int64_t &r_value) {
	constexpr std::uint64_t kMinMagnitude = static_cast<std::uint64_t>(kInt64Max) + 1ULL; // 2^63
	if (!p_negative) {
		if (p_magnitude > static_cast<std::uint64_t>(kInt64Max)) {
			return false;
		}
		r_value = static_cast<std::int64_t>(p_magnitude);
		return true;
	}
	if (p_magnitude > kMinMagnitude) {
		return false;
	}
	if (p_magnitude == kMinMagnitude) {
		r_value = kInt64Min;
		return true;
	}
	r_value = -static_cast<std::int64_t>(p_magnitude);
	return true;
}

// 64x64 -> 128 unsigned multiply built from 32-bit partial products. This is
// well-defined on every platform because no operand or partial product ever
// exceeds 64 bits.
Wide128 umul128(std::uint64_t p_a, std::uint64_t p_b) {
	const std::uint64_t a_lo = p_a & 0xFFFFFFFFULL;
	const std::uint64_t a_hi = p_a >> 32;
	const std::uint64_t b_lo = p_b & 0xFFFFFFFFULL;
	const std::uint64_t b_hi = p_b >> 32;

	const std::uint64_t lo_lo = a_lo * b_lo;
	const std::uint64_t hi_lo = a_hi * b_lo;
	const std::uint64_t lo_hi = a_lo * b_hi;
	const std::uint64_t hi_hi = a_hi * b_hi;

	const std::uint64_t cross = (lo_lo >> 32) + (hi_lo & 0xFFFFFFFFULL) + (lo_hi & 0xFFFFFFFFULL);

	Wide128 result;
	result.lo = (cross << 32) | (lo_lo & 0xFFFFFFFFULL);
	result.hi = hi_hi + (hi_lo >> 32) + (lo_hi >> 32) + (cross >> 32);
	return result;
}

// Schoolbook binary long division of a 128-bit magnitude by any nonzero
// 64-bit magnitude. `p_divisor` is never zero here (checked by the caller).
void udiv128(Wide128 p_value, std::uint64_t p_divisor, Wide128 &r_quotient, std::uint64_t &r_remainder) {
	Wide128 quotient{ 0, 0 };
	std::uint64_t remainder = 0;
	for (int bit = 127; bit >= 0; --bit) {
		remainder <<= 1;
		const std::uint64_t bit_value = (bit >= 64) ? ((p_value.hi >> (bit - 64)) & 1ULL) : ((p_value.lo >> bit) & 1ULL);
		remainder |= bit_value;
		if (remainder >= p_divisor) {
			remainder -= p_divisor;
			if (bit >= 64) {
				quotient.hi |= (1ULL << (bit - 64));
			} else {
				quotient.lo |= (1ULL << bit);
			}
		}
	}
	r_quotient = quotient;
	r_remainder = remainder;
}

void wide128_increment(Wide128 &p_value) {
	if (p_value.lo == std::numeric_limits<std::uint64_t>::max()) {
		p_value.lo = 0;
		p_value.hi += 1;
	} else {
		p_value.lo += 1;
	}
}

#endif // !defined(__SIZEOF_INT128__)

} // namespace

Status fixed_mul_div_round(std::int64_t p_x, std::int64_t p_y, std::int64_t p_z, std::int64_t &r_result) {
	if (p_z == 0) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::DIVIDE_BY_ZERO, 0);
	}

#if defined(__SIZEOF_INT128__)
	const __int128 x = p_x;
	const __int128 y = p_y;
	const __int128 z = p_z;

	const __int128 product = x * y;
	__int128 quotient = product / z; // truncates toward zero (C++11 semantics)
	const __int128 remainder = product % z; // sign follows the dividend

	const __int128 abs_remainder = (remainder < 0) ? -remainder : remainder;
	const __int128 abs_z = (z < 0) ? -z : z;
	// abs_remainder < abs_z always holds (property of `%`), so this subtraction
	// never underflows; it is algebraically `2 * abs_remainder >= abs_z`
	// without needing headroom for the doubling.
	if (abs_remainder != 0 && abs_remainder >= abs_z - abs_remainder) {
		quotient += (product < 0) ? -1 : 1;
	}

	constexpr __int128 kMax128 = static_cast<__int128>(kInt64Max);
	constexpr __int128 kMin128 = static_cast<__int128>(kInt64Min);
	if (quotient > kMax128 || quotient < kMin128) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	r_result = static_cast<std::int64_t>(quotient);
	return ok_status();
#else
	bool negative = false;
	if (p_x < 0) {
		negative = !negative;
	}
	if (p_y < 0) {
		negative = !negative;
	}
	if (p_z < 0) {
		negative = !negative;
	}

	const std::uint64_t mag_x = to_magnitude(p_x);
	const std::uint64_t mag_y = to_magnitude(p_y);
	const std::uint64_t mag_z = to_magnitude(p_z);

	const Wide128 product = umul128(mag_x, mag_y);
	Wide128 quotient;
	std::uint64_t remainder = 0;
	udiv128(product, mag_z, quotient, remainder);

	if (remainder != 0 && remainder >= mag_z - remainder) {
		wide128_increment(quotient);
	}

	if (quotient.hi != 0) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	std::int64_t signed_result = 0;
	if (!from_magnitude(quotient.lo, negative, signed_result)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	r_result = signed_result;
	return ok_status();
#endif
}

Fixed Fixed::from_int(std::int64_t p_value) {
	constexpr std::int64_t kMaxUnits = kInt64Max / FIXED_SCALE;
	constexpr std::int64_t kMinUnits = kInt64Min / FIXED_SCALE;
	if (p_value > kMaxUnits) {
		return Fixed{ kInt64Max };
	}
	if (p_value < kMinUnits) {
		return Fixed{ kInt64Min };
	}
	return Fixed{ p_value * FIXED_SCALE };
}

Status fixed_add(Fixed p_a, Fixed p_b, Fixed &r_out) {
	const std::int64_t a = p_a.raw;
	const std::int64_t b = p_b.raw;
	if (b > 0 && a > kInt64Max - b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	if (b < 0 && a < kInt64Min - b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	r_out.raw = a + b;
	return ok_status();
}

Status fixed_sub(Fixed p_a, Fixed p_b, Fixed &r_out) {
	const std::int64_t a = p_a.raw;
	const std::int64_t b = p_b.raw;
	// `MIN + b` (b >= 0) and `MAX + b` (b < 0) never overflow: both sum to a
	// value in [MIN, MAX] because the operands have opposite-enough signs.
	if (b >= 0 && a < kInt64Min + b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	if (b < 0 && a > kInt64Max + b) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	r_out.raw = a - b;
	return ok_status();
}

Status fixed_mul(Fixed p_a, Fixed p_b, Fixed &r_out) {
	std::int64_t result = 0;
	const Status status = fixed_mul_div_round(p_a.raw, p_b.raw, FIXED_SCALE, result);
	if (!status.ok()) {
		return status;
	}
	r_out.raw = result;
	return ok_status();
}

Status fixed_div(Fixed p_a, Fixed p_b, Fixed &r_out) {
	if (p_b.raw == 0) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::DIVIDE_BY_ZERO, 0);
	}
	std::int64_t result = 0;
	const Status status = fixed_mul_div_round(p_a.raw, FIXED_SCALE, p_b.raw, result);
	if (!status.ok()) {
		return status;
	}
	r_out.raw = result;
	return ok_status();
}

Status fixed_neg(Fixed p_value, Fixed &r_out) {
	if (p_value.raw == kInt64Min) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	r_out.raw = -p_value.raw;
	return ok_status();
}

Status fixed_abs(Fixed p_value, Fixed &r_out) {
	if (p_value.raw == kInt64Min) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}
	r_out.raw = (p_value.raw < 0) ? -p_value.raw : p_value.raw;
	return ok_status();
}

std::int64_t fixed_floor_to_int(Fixed p_value) {
	const std::int64_t q = p_value.raw / FIXED_SCALE;
	const std::int64_t r = p_value.raw % FIXED_SCALE;
	return (r != 0 && p_value.raw < 0) ? (q - 1) : q;
}

std::int64_t fixed_ceil_to_int(Fixed p_value) {
	const std::int64_t q = p_value.raw / FIXED_SCALE;
	const std::int64_t r = p_value.raw % FIXED_SCALE;
	return (r != 0 && p_value.raw > 0) ? (q + 1) : q;
}

std::int64_t fixed_round_to_int(Fixed p_value) {
	const std::int64_t q = p_value.raw / FIXED_SCALE;
	const std::int64_t r = p_value.raw % FIXED_SCALE;
	if (r == 0) {
		return q;
	}
	const std::int64_t abs_r = (r < 0) ? -r : r; // |r| < FIXED_SCALE, safe to negate
	if (abs_r * 2 >= FIXED_SCALE) {
		return (p_value.raw < 0) ? (q - 1) : (q + 1);
	}
	return q;
}

Status fixed_quantize(double p_value, Fixed &r_out) {
	if (!std::isfinite(p_value)) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE, 0);
	}

	const double scaled = p_value * static_cast<double>(FIXED_SCALE);
	// Round half away from zero without going through locale-sensitive string
	// formatting.
	const double rounded = (scaled < 0.0) ? -std::floor(-scaled + 0.5) : std::floor(scaled + 0.5);

	// Both bounds are exact powers of two (2^63), so this comparison never
	// suffers the classic "cast INT64_MAX to double" rounding pitfall: any
	// value in [kMinRepresentable, kMaxRepresentableExclusive) maps to a
	// representable int64 and vice versa.
	constexpr double kMinRepresentable = -9223372036854775808.0; // -2^63 == INT64_MIN
	constexpr double kMaxRepresentableExclusive = 9223372036854775808.0; // 2^63
	if (rounded < kMinRepresentable || rounded >= kMaxRepresentableExclusive) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_NOT_REPRESENTABLE, 0);
	}

	r_out.raw = static_cast<std::int64_t>(rounded);
	return ok_status();
}

double fixed_to_double(Fixed p_value) {
	// Editor/presentation only -- see the header comment.
	return static_cast<double>(p_value.raw) / static_cast<double>(FIXED_SCALE);
}

Fixed fixed_clamp(Fixed p_value, Fixed p_min, Fixed p_max) {
	if (p_value.raw < p_min.raw) {
		return p_min;
	}
	if (p_value.raw > p_max.raw) {
		return p_max;
	}
	return p_value;
}

Fixed fixed_min(Fixed p_a, Fixed p_b) {
	return (p_a.raw <= p_b.raw) ? p_a : p_b;
}

Fixed fixed_max(Fixed p_a, Fixed p_b) {
	return (p_a.raw >= p_b.raw) ? p_a : p_b;
}

void fixed_write(ByteWriter &p_writer, Fixed p_value) {
	p_writer.write_i64(p_value.raw);
}

bool fixed_read(ByteReader &p_reader, Fixed &r_out) {
	return p_reader.read_i64(r_out.raw);
}

void fixed_hash(Hasher &p_hasher, Fixed p_value) {
	p_hasher.write_i64(p_value.raw);
}

} // namespace ga
