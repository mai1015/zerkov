#ifndef GAMEPLAY_ABILITIES_CORE_TICK_H
#define GAMEPLAY_ABILITIES_CORE_TICK_H

#include "core/ga_fixed.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"

#include <cstdint>

// Core simulation uses an unsigned 64-bit gameplay tick as the only
// authoritative unit of time. Core code never reads a wall clock: every
// conversion below is a pure, checked, integer-only function of its inputs.
namespace ga {

using Tick = std::uint64_t;

// Reserved sentinel meaning "no tick" / "not yet set". A real tick value must
// never equal this, so `tick_advance` refuses to produce it.
constexpr Tick INVALID_TICK = UINT64_MAX;

// Ticks per second for one session. Immutable once a session starts: every
// peer must agree on this value before gameplay commands are accepted (it is
// part of the handshake and the content manifest -- see `ga_manifest.h`).
struct SessionTiming {
	std::uint32_t tick_rate = DEFAULT_TICK_RATE;
};

// Validates `p_tick_rate` against [`MIN_TICK_RATE`, `MAX_TICK_RATE`].
Status validate_tick_rate(std::uint32_t p_tick_rate);

// ticks = round_half_away_from_zero(seconds * tick_rate). Negative durations
// are rejected outright -- a duration in ticks can never be negative.
Status ticks_from_seconds(const SessionTiming &p_timing, Fixed p_seconds, std::uint64_t &r_ticks);

// milliseconds -> ticks, same rounding rule as `ticks_from_seconds`.
Status ticks_from_milliseconds(const SessionTiming &p_timing, std::uint64_t p_milliseconds, std::uint64_t &r_ticks);

// ticks -> seconds as a `Fixed`. This conversion cannot fail for any tick
// count reachable by a real session (see the .cpp for the saturation policy
// used on the practically-unreachable extreme/corrupt input), so it has no
// `Status` channel by design, matching `Fixed::from_int`.
Fixed seconds_from_ticks(const SessionTiming &p_timing, std::uint64_t p_ticks);

// Advances `p_current` by `p_delta` ticks, detecting wraparound/overflow and
// refusing to ever produce `INVALID_TICK`.
Status tick_advance(Tick p_current, std::uint64_t p_delta, Tick &r_next);

// Duration/period validation shared by effect scheduling (section 5). A
// duration or period of zero ticks or of `INVALID_TICK` is rejected here so
// downstream code never has to special-case those values: a zero-length
// "duration" effect is an Instant effect, not a Duration-policy effect, and a
// period must always advance the schedule.
Status validate_duration_ticks(std::uint64_t p_duration_ticks);
Status validate_period_ticks(std::uint64_t p_period_ticks);

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TICK_H
