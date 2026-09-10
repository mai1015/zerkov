#include "core/ga_tick.h"

#include <limits>

namespace ga {

namespace {

constexpr std::int64_t kInt64Max = std::numeric_limits<std::int64_t>::max();

std::uint32_t effective_rate(const SessionTiming &p_timing) {
	// A default-constructed `SessionTiming` is already a valid rate; this
	// guards only against a hand-built zero, which would otherwise divide by
	// zero below.
	return (p_timing.tick_rate == 0) ? DEFAULT_TICK_RATE : p_timing.tick_rate;
}

} // namespace

Status validate_tick_rate(std::uint32_t p_tick_rate) {
	if (p_tick_rate < MIN_TICK_RATE || p_tick_rate > MAX_TICK_RATE) {
		return make_status(StatusCode::NOT_SUPPORTED, DiagnosticId::TICK_RATE_UNSUPPORTED, p_tick_rate);
	}
	return ok_status();
}

Status ticks_from_seconds(const SessionTiming &p_timing, Fixed p_seconds, std::uint64_t &r_ticks) {
	if (p_seconds.raw < 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DURATION_INVALID, 0);
	}

	const std::uint32_t rate = effective_rate(p_timing);
	std::int64_t result = 0;
	const Status status = fixed_mul_div_round(p_seconds.raw, static_cast<std::int64_t>(rate), FIXED_SCALE, result);
	if (!status.ok()) {
		return status;
	}
	// `p_seconds.raw >= 0` and `rate > 0`, so `result` cannot be negative;
	// this is defensive rather than reachable.
	if (result < 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DURATION_INVALID, 0);
	}
	r_ticks = static_cast<std::uint64_t>(result);
	return ok_status();
}

Status ticks_from_milliseconds(const SessionTiming &p_timing, std::uint64_t p_milliseconds, std::uint64_t &r_ticks) {
	if (p_milliseconds > static_cast<std::uint64_t>(kInt64Max)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, 0);
	}

	const std::uint32_t rate = effective_rate(p_timing);
	std::int64_t result = 0;
	const Status status = fixed_mul_div_round(static_cast<std::int64_t>(p_milliseconds), static_cast<std::int64_t>(rate), 1000, result);
	if (!status.ok()) {
		return status;
	}
	if (result < 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DURATION_INVALID, 0);
	}
	r_ticks = static_cast<std::uint64_t>(result);
	return ok_status();
}

Fixed seconds_from_ticks(const SessionTiming &p_timing, std::uint64_t p_ticks) {
	const std::uint32_t rate = effective_rate(p_timing);

	if (p_ticks > static_cast<std::uint64_t>(kInt64Max)) {
		// No `Status` channel here (see header); saturate rather than invoke
		// UB on a tick value far beyond any real session (this would require
		// billions of years of continuous simulation at the minimum tick
		// rate).
		return Fixed::from_raw(kInt64Max);
	}

	std::int64_t result = 0;
	const Status status = fixed_mul_div_round(static_cast<std::int64_t>(p_ticks), FIXED_SCALE, static_cast<std::int64_t>(rate), result);
	if (!status.ok()) {
		return Fixed::from_raw(kInt64Max);
	}
	return Fixed::from_raw(result);
}

Status tick_advance(Tick p_current, std::uint64_t p_delta, Tick &r_next) {
	if (p_current == INVALID_TICK) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, p_current);
	}
	// `INVALID_TICK - 1` is the largest tick value a real session may reach;
	// `p_current <= INVALID_TICK - 1` here, so this subtraction never
	// underflows.
	const Tick max_delta = (INVALID_TICK - 1) - p_current;
	if (p_delta > max_delta) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, p_current);
	}
	r_next = p_current + p_delta;
	return ok_status();
}

Status validate_duration_ticks(std::uint64_t p_duration_ticks) {
	if (p_duration_ticks == 0 || p_duration_ticks == INVALID_TICK) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DURATION_INVALID, p_duration_ticks);
	}
	return ok_status();
}

Status validate_period_ticks(std::uint64_t p_period_ticks) {
	if (p_period_ticks == 0 || p_period_ticks == INVALID_TICK) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PERIOD_INVALID, p_period_ticks);
	}
	return ok_status();
}

} // namespace ga
