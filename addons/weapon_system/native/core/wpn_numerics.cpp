#include "core/wpn_numerics.h"

#include "core/wpn_checked_math.h"
#include "core/wpn_limits.h"

#include <algorithm>
#include <cstdlib>
#include <limits>

namespace wpn {

namespace {

std::uint64_t splitmix64_step(std::uint64_t &r_state) {
	r_state += UINT64_C(0x9e3779b97f4a7c15);
	std::uint64_t z = r_state;
	z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
	z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
	return z ^ (z >> 31);
}

constexpr std::uint64_t DISPERSION_CHANNEL_SALT = UINT64_C(0x5745504e2d444953); // "WPN-DIS"
constexpr std::uint64_t HORIZONTAL_RECOIL_CHANNEL_SALT = UINT64_C(0x5745504e2d524543); // "WPN-REC"

std::int64_t clamp_i64(std::int64_t p_value, std::int64_t p_min, std::int64_t p_max) {
	if (p_value < p_min) return p_min;
	if (p_value > p_max) return p_max;
	return p_value;
}

} // namespace

Status convert_accuracy_moa_milli_to_angular_radius_nrad(
		std::int64_t p_accuracy_moa_milli,
		std::int64_t &r_angular_radius_nrad) {
	r_angular_radius_nrad = 0;
	if (p_accuracy_moa_milli < 0 || p_accuracy_moa_milli > MAX_ACCURACY_MOA_MILLI) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(p_accuracy_moa_milli));
	}
	const __int128_t product = static_cast<__int128_t>(p_accuracy_moa_milli) * static_cast<__int128_t>(PI_NANORADIANS);
	const __int128_t denom = static_cast<__int128_t>(MOA_MILLI_TO_NANORADIAN_DENOMINATOR);
	__int128_t quotient = product / denom;
	const __int128_t remainder = product % denom;
	// Both operands are non-negative, so remainder is non-negative: round
	// half up by comparing 2*remainder against the denominator.
	if (remainder * 2 >= denom) {
		quotient += 1;
	}
	constexpr __int128_t k_max = static_cast<__int128_t>(std::numeric_limits<std::int64_t>::max());
	if (quotient > k_max) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_angular_radius_nrad = static_cast<std::int64_t>(quotient);
	return ok_status();
}

Status sample_uniform_signed_range_nrad(
		std::uint64_t p_seed,
		SeedChannel p_channel,
		std::int64_t p_min_nrad,
		std::int64_t p_max_nrad,
		std::int64_t &r_value_nrad) {
	r_value_nrad = 0;
	if (p_min_nrad < -MAX_ANGLE_NANORADIANS || p_max_nrad > MAX_ANGLE_NANORADIANS || p_min_nrad > p_max_nrad) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(p_max_nrad));
	}
	if (p_channel != SeedChannel::DISPERSION && p_channel != SeedChannel::HORIZONTAL_RECOIL) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM);
	}
	if (p_min_nrad == p_max_nrad) {
		r_value_nrad = p_min_nrad;
		return ok_status();
	}
	const std::uint64_t channel_salt =
			p_channel == SeedChannel::DISPERSION ? DISPERSION_CHANNEL_SALT : HORIZONTAL_RECOIL_CHANNEL_SALT;
	std::uint64_t state = p_seed ^ channel_salt ^ (static_cast<std::uint64_t>(DISPERSION_SEED_SAMPLER_VERSION) << 32);
	// Prime the state once so the first draw is not a trivial function of a
	// low-entropy caller seed.
	(void)splitmix64_step(state);

	// Both bounds are within +/-MAX_ANGLE_NANORADIANS (~3.14e9), so the span
	// fits comfortably in std::uint64_t with no overflow risk.
	const std::uint64_t span = static_cast<std::uint64_t>(p_max_nrad - p_min_nrad) + 1ULL;
	constexpr std::uint64_t k_max_u64 = std::numeric_limits<std::uint64_t>::max();
	const std::uint64_t limit = k_max_u64 - (k_max_u64 % span);

	std::uint64_t draw = 0;
	std::size_t attempts = 0;
	do {
		draw = splitmix64_step(state);
		++attempts;
	} while (draw >= limit && attempts < MAX_REJECTION_SAMPLING_ATTEMPTS);

	const std::uint64_t bucket = draw % span;
	r_value_nrad = p_min_nrad + static_cast<std::int64_t>(bucket);
	return ok_status();
}

Status sample_uniform_signed_offset_nrad(
		std::uint64_t p_seed,
		SeedChannel p_channel,
		std::int64_t p_radius_nrad,
		std::int64_t &r_offset_nrad) {
	r_offset_nrad = 0;
	if (p_radius_nrad < 0 || p_radius_nrad > MAX_ANGLE_NANORADIANS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(p_radius_nrad));
	}
	// Delegates to the general asymmetric-range sampler with a symmetric
	// [-radius, +radius] range: span/bucket/offset arithmetic is identical to
	// the pre-4.10 standalone implementation, so this is bit-identical for
	// every existing caller and golden fixture.
	return sample_uniform_signed_range_nrad(p_seed, p_channel, -p_radius_nrad, p_radius_nrad, r_offset_nrad);
}

FixedVec2 rotate_unit_vector_by_angle_nrad(const FixedVec2 &p_unit_vector, std::int64_t p_angle_nrad) {
	if (p_angle_nrad == 0) return p_unit_vector;
	const std::int64_t x = p_unit_vector.x;
	const std::int64_t y = p_unit_vector.y;
	std::int64_t rotated_x = x - (y * p_angle_nrad) / NANORADIANS_PER_RADIAN;
	std::int64_t rotated_y = y + (x * p_angle_nrad) / NANORADIANS_PER_RADIAN;
	const std::int64_t max_component = std::max(std::llabs(rotated_x), std::llabs(rotated_y));
	if (max_component > DIRECTION_SCALE) {
		rotated_x = (rotated_x * DIRECTION_SCALE) / max_component;
		rotated_y = (rotated_y * DIRECTION_SCALE) / max_component;
	}
	return { rotated_x, rotated_y };
}

Status fold_modifier_deltas_ppm(const std::vector<ModifierDelta> &p_deltas, std::int64_t &r_aggregate_multiplier_ppm) {
	r_aggregate_multiplier_ppm = 0;
	if (p_deltas.size() > MAX_MODIFIER_FOLD_DELTAS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_deltas.size());
	}
	std::vector<const ModifierDelta *> ordered;
	ordered.reserve(p_deltas.size());
	for (const ModifierDelta &delta : p_deltas) {
		if (delta.delta_ppm < -MAX_MODIFIER_DELTA_PPM || delta.delta_ppm > MAX_MODIFIER_DELTA_PPM) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
					static_cast<std::uint64_t>(delta.delta_ppm));
		}
		ordered.push_back(&delta);
	}
	// Canonical source, slot-ID, then definition-ID/version order so callers
	// with equivalent modifiers in different insertion order fold to the
	// same aggregate multiplier.
	std::sort(ordered.begin(), ordered.end(), [](const ModifierDelta *p_a, const ModifierDelta *p_b) {
		if (p_a->source != p_b->source) return p_a->source < p_b->source;
		if (p_a->slot_id != p_b->slot_id) return p_a->slot_id < p_b->slot_id;
		if (p_a->definition_id != p_b->definition_id) return p_a->definition_id < p_b->definition_id;
		return p_a->definition_version < p_b->definition_version;
	});

	std::int64_t sum = 0;
	for (const ModifierDelta *delta : ordered) {
		Status status = checked_add_i64(sum, delta->delta_ppm, sum);
		if (!status.ok()) return status;
	}
	std::int64_t aggregate = 0;
	Status status = checked_add_i64(MODIFIER_NEUTRAL_PPM, sum, aggregate);
	if (!status.ok()) return status;
	r_aggregate_multiplier_ppm = clamp_i64(aggregate, MIN_MODIFIER_MULTIPLIER_PPM, MAX_MODIFIER_MULTIPLIER_PPM);
	return ok_status();
}

Status apply_modifier_multiplier(
		std::int64_t p_base_value,
		std::int64_t p_aggregate_multiplier_ppm,
		std::int64_t p_min_result,
		std::int64_t p_max_result,
		std::int64_t &r_result) {
	r_result = 0;
	if (p_min_result > p_max_result) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	const __int128_t product = static_cast<__int128_t>(p_base_value) * static_cast<__int128_t>(p_aggregate_multiplier_ppm);
	const __int128_t denom = static_cast<__int128_t>(MODIFIER_NEUTRAL_PPM);
	__int128_t quotient = product / denom;
	const __int128_t remainder = product % denom; // same sign as product (or zero) per C++ truncating division
	__int128_t abs_remainder = remainder < 0 ? -remainder : remainder;
	if (abs_remainder * 2 >= denom) {
		quotient += (product < 0) ? -1 : 1;
	}
	constexpr __int128_t k_max = static_cast<__int128_t>(std::numeric_limits<std::int64_t>::max());
	constexpr __int128_t k_min = static_cast<__int128_t>(std::numeric_limits<std::int64_t>::min());
	if (quotient > k_max || quotient < k_min) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_result = clamp_i64(static_cast<std::int64_t>(quotient), p_min_result, p_max_result);
	return ok_status();
}

Status compute_effective_recoil_offset_nrad(
		std::int64_t p_stored_offset_nrad,
		std::uint64_t p_anchor_tick,
		std::int64_t p_recovery_per_tick_nrad,
		std::uint64_t p_query_tick,
		std::int64_t &r_effective_offset_nrad) {
	r_effective_offset_nrad = 0;
	if (p_query_tick < p_anchor_tick) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED, p_anchor_tick);
	}
	if (p_recovery_per_tick_nrad <= 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE,
				static_cast<std::uint64_t>(p_recovery_per_tick_nrad));
	}
	if (p_stored_offset_nrad == 0) {
		return ok_status();
	}
	const std::int64_t magnitude = std::llabs(p_stored_offset_nrad);
	const std::int64_t sign = p_stored_offset_nrad < 0 ? -1 : 1;
	// Elapsed ticks since the stored anchor; safe because p_query_tick >=
	// p_anchor_tick is already enforced above.
	const std::uint64_t elapsed = p_query_tick - p_anchor_tick;
	// Ceiling division to find how many ticks fully recover the stored
	// magnitude, computed BEFORE the final multiply so an astronomically
	// large `elapsed` never needs to actually participate in a wide product:
	// once elapsed reaches this bound the effective offset is saturated at
	// zero regardless of how much further elapsed still has to go.
	const std::int64_t ticks_to_zero = (magnitude + p_recovery_per_tick_nrad - 1) / p_recovery_per_tick_nrad;
	if (elapsed >= static_cast<std::uint64_t>(ticks_to_zero)) {
		r_effective_offset_nrad = 0;
		return ok_status();
	}
	// elapsed < ticks_to_zero <= magnitude (bounded by MAX_RECOIL_OFFSET_NRAD),
	// so this multiply is always well within std::int64_t range; checked
	// anyway for defense-in-depth consistency with the rest of this file.
	std::int64_t recovered = 0;
	Status status = checked_mul_i64(p_recovery_per_tick_nrad, static_cast<std::int64_t>(elapsed), recovered);
	if (!status.ok()) return status;
	std::int64_t remaining_magnitude = 0;
	status = checked_add_i64(magnitude, -recovered, remaining_magnitude);
	if (!status.ok()) return status;
	r_effective_offset_nrad = sign * remaining_magnitude;
	return ok_status();
}

} // namespace wpn
