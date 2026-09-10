#ifndef GAMEPLAY_ABILITIES_CORE_FIXED_H
#define GAMEPLAY_ABILITIES_CORE_FIXED_H

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"

#include <cstdint>
#include <type_traits>

// Checked signed 64-bit fixed-point value, scale `FIXED_SCALE` (one million
// subunits per whole unit). This is the ONLY numeric representation allowed in
// authoritative gameplay state; `double`/`float` may appear only at the two
// edges documented on `fixed_quantize` and `fixed_to_double` below.
//
// Rounding: multiplication, division, and the tick/second conversions in
// `ga_tick.h` all round HALF AWAY FROM ZERO -- a tie (exact .5 fractional
// subunit) rounds to the larger-magnitude representable value, identically
// for positive and negative operands, so every peer replays to the same
// integer regardless of platform.
//
// Overflow: every checked entry point below detects overflow/underflow BEFORE
// it would occur and returns `StatusCode::ARITHMETIC_ERROR` with
// `DiagnosticId::OVERFLOW_DETECTED` (or `DiagnosticId::DIVIDE_BY_ZERO`)
// instead of ever relying on signed integer overflow, which is undefined
// behavior in C++. The shared primitive `fixed_mul_div_round` uses `__int128`
// where the toolchain defines it (`__SIZEOF_INT128__`, true for every
// GCC/Clang desktop, mobile, and wasm32/Emscripten target this addon ships
// for) and falls back to a portable manual 128-bit long-multiply/long-divide
// otherwise; both paths implement the identical rounding and range rule, so
// behavior never depends on which path a given target compiles.
namespace ga {

struct Fixed {
	std::int64_t raw = 0;

	static Fixed from_raw(std::int64_t p_raw) { return Fixed{ p_raw }; }

	// Saturates instead of invoking UB on overflow. This factory has no
	// `Status` channel by design (it exists for small literal constants such
	// as `Fixed::one()`); callers that must reject rather than saturate an
	// adversarial or extreme integer should route through `fixed_quantize` or
	// `fixed_mul`, which report `Status` failures.
	static Fixed from_int(std::int64_t p_value);

	static Fixed zero() { return Fixed{ 0 }; }
	static Fixed one() { return Fixed{ FIXED_SCALE }; }

	bool operator==(const Fixed &p_other) const { return raw == p_other.raw; }
	bool operator!=(const Fixed &p_other) const { return raw != p_other.raw; }
	bool operator<(const Fixed &p_other) const { return raw < p_other.raw; }
	bool operator<=(const Fixed &p_other) const { return raw <= p_other.raw; }
	bool operator>(const Fixed &p_other) const { return raw > p_other.raw; }
	bool operator>=(const Fixed &p_other) const { return raw >= p_other.raw; }
};

static_assert(std::is_trivially_copyable<Fixed>::value, "Fixed must stay a trivially-copyable value type");

// Shared checked primitive: computes round_half_away_from_zero(p_x * p_y / p_z)
// treating all three as plain (not pre-scaled) 64-bit integers, without ever
// relying on signed-overflow UB. `fixed_mul`, `fixed_div`, and the tick/second
// conversions in `ga_tick.h` all build on this single primitive so their
// overflow and rounding behavior can never drift apart. `p_z` of zero returns
// `DiagnosticId::DIVIDE_BY_ZERO`; a result outside the int64 range returns
// `DiagnosticId::OVERFLOW_DETECTED`.
Status fixed_mul_div_round(std::int64_t p_x, std::int64_t p_y, std::int64_t p_z, std::int64_t &r_result);

Status fixed_add(Fixed p_a, Fixed p_b, Fixed &r_out);
Status fixed_sub(Fixed p_a, Fixed p_b, Fixed &r_out);
Status fixed_mul(Fixed p_a, Fixed p_b, Fixed &r_out);
Status fixed_div(Fixed p_a, Fixed p_b, Fixed &r_out);
Status fixed_neg(Fixed p_value, Fixed &r_out);
// Checked because negating/abs-ing `INT64_MIN` is not representable.
Status fixed_abs(Fixed p_value, Fixed &r_out);

// Pure integer conversions; the magnitude of the result never exceeds the
// magnitude of `p_value.raw`, so these never overflow and need no `Status`.
std::int64_t fixed_round_to_int(Fixed p_value);
std::int64_t fixed_floor_to_int(Fixed p_value);
std::int64_t fixed_ceil_to_int(Fixed p_value);

// The ONLY place a `double` may enter authoritative gameplay state: quantizes
// an authoring-time decimal into the canonical fixed-point integer, rounding
// half away from zero. Rejects NaN, +-infinity, and magnitudes outside the
// representable int64 raw range with `DiagnosticId::VALUE_NOT_REPRESENTABLE`.
// Locale-independent: it never goes through string formatting or parsing.
Status fixed_quantize(double p_value, Fixed &r_out);

// Editor/presentation convenience ONLY -- never feed the result back into
// authoritative state. Round-trip through `fixed_quantize` first if a
// presentation-computed value must re-enter core simulation.
double fixed_to_double(Fixed p_value);

Fixed fixed_clamp(Fixed p_value, Fixed p_min, Fixed p_max);
Fixed fixed_min(Fixed p_a, Fixed p_b);
Fixed fixed_max(Fixed p_a, Fixed p_b);

// Canonical little-endian serialization shared by manifests, snapshots, and
// every network packet that carries a fixed-point value.
void fixed_write(ByteWriter &p_writer, Fixed p_value);
bool fixed_read(ByteReader &p_reader, Fixed &r_out);
void fixed_hash(Hasher &p_hasher, Fixed p_value);

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_FIXED_H
