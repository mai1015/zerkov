#include "core/wpn_hitscan.h"

#include "core/wpn_identifier.h"
#include "core/wpn_limits.h"

#include <algorithm>
#include <limits>

namespace wpn {

namespace {

// Widened intermediate for checked integer arithmetic. Every input this
// module accepts is bounded to +/-MAX_WORLD_MILLIUNITS (1e9) or
// +/-MAX_DIRECTION_COMPONENT (1e6), so every product/sum used below stays
// many orders of magnitude below the ~1.7e38 capacity of a 128-bit
// intermediate; only the final, narrowed results are bounds-checked. This
// mirrors the existing __int128_t "Wide" idiom in
// addons/common_vision/native/core/cv_geometry.cpp and the widen-then-range-
// check multiply idiom documented in
// addons/inventory_system/native/core/inv_checked_math.h.
using Wide = __int128_t;

bool in_world_bounds(std::int64_t p_value) {
	return p_value >= -MAX_WORLD_MILLIUNITS && p_value <= MAX_WORLD_MILLIUNITS;
}

bool point_in_world_bounds(const FixedVec2 &p_point) {
	return in_world_bounds(p_point.x) && in_world_bounds(p_point.y);
}

// Deterministic bit-by-bit (digit-by-digit) floor integer square root. Pure
// integer arithmetic only, so it is exact and identical on every platform,
// unlike a floating-point std::sqrt. p_value must be non-negative.
std::int64_t isqrt_floor(Wide p_value) {
	using UWide = unsigned __int128;
	if (p_value <= 0) return 0;
	UWide x = static_cast<UWide>(p_value);
	UWide result = 0;
	UWide bit = UWide(1) << 126;
	while (bit > x) bit >>= 2;
	while (bit != 0) {
		if (x >= result + bit) {
			x -= result + bit;
			result = (result >> 1) + bit;
		} else {
			result >>= 1;
		}
		bit >>= 2;
	}
	return static_cast<std::int64_t>(result);
}

// Computes round_half_away_from_zero(p_value * p_scale / p_denom) with a
// 128-bit intermediate, matching this repository's sealed "round ties away
// from zero" convention (see design.md, "Canonical numeric contract").
// Returns false only if the rounded quotient cannot be represented as a
// signed 64-bit value, which cannot occur for any bounded input this module
// passes to it but is still checked rather than assumed.
bool scale_round(std::int64_t p_value, std::int64_t p_scale, std::int64_t p_denom, std::int64_t &r_out) {
	const Wide numerator = Wide(p_value) * Wide(p_scale);
	Wide quotient = numerator / Wide(p_denom);
	const Wide remainder = numerator % Wide(p_denom);
	if (remainder != 0) {
		const Wide twice_abs_remainder = (remainder < 0 ? -remainder : remainder) * 2;
		if (twice_abs_remainder >= Wide(p_denom)) {
			quotient += (numerator < 0) ? -1 : 1;
		}
	}
	if (quotient < Wide(std::numeric_limits<std::int64_t>::min()) ||
			quotient > Wide(std::numeric_limits<std::int64_t>::max())) {
		return false;
	}
	r_out = static_cast<std::int64_t>(quotient);
	return true;
}

// Normalizes p_direction to a fixed-point unit vector whose magnitude is
// exactly DIRECTION_SCALE (the sealed V1 representation of 1.0), using the
// deterministic integer sqrt above rather than a platform std::sqrt.
Status normalize_direction(const FixedVec2 &p_direction, FixedVec2 &r_unit) {
	if (p_direction.x < -MAX_DIRECTION_COMPONENT || p_direction.x > MAX_DIRECTION_COMPONENT ||
			p_direction.y < -MAX_DIRECTION_COMPONENT || p_direction.y > MAX_DIRECTION_COMPONENT) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	if (p_direction.x == 0 && p_direction.y == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	const Wide length_squared = Wide(p_direction.x) * Wide(p_direction.x) + Wide(p_direction.y) * Wide(p_direction.y);
	const std::int64_t length = isqrt_floor(length_squared);
	if (length <= 0) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	std::int64_t ux = 0;
	std::int64_t uy = 0;
	if (!scale_round(p_direction.x, DIRECTION_SCALE, length, ux) ||
			!scale_round(p_direction.y, DIRECTION_SCALE, length, uy)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_unit = { ux, uy };
	return ok_status();
}

} // namespace

Status point_along_ray(
		const FixedVec2 &p_origin,
		const FixedVec2 &p_direction,
		std::int64_t p_distance_milliunits,
		FixedVec2 &r_point) {
	if (!point_in_world_bounds(p_origin)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	if (p_distance_milliunits < 0 || p_distance_milliunits > MAX_WORLD_MILLIUNITS) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	FixedVec2 unit;
	Status status = normalize_direction(p_direction, unit);
	if (!status.ok()) return status;

	std::int64_t offset_x = 0;
	std::int64_t offset_y = 0;
	if (!scale_round(unit.x, p_distance_milliunits, DIRECTION_SCALE, offset_x) ||
			!scale_round(unit.y, p_distance_milliunits, DIRECTION_SCALE, offset_y)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	const Wide result_x = Wide(p_origin.x) + Wide(offset_x);
	const Wide result_y = Wide(p_origin.y) + Wide(offset_y);
	if (result_x < -Wide(MAX_WORLD_MILLIUNITS) || result_x > Wide(MAX_WORLD_MILLIUNITS) ||
			result_y < -Wide(MAX_WORLD_MILLIUNITS) || result_y > Wide(MAX_WORLD_MILLIUNITS)) {
		// The intersection/impact point itself exceeds the sealed coordinate
		// bound even though every input was individually in range. Fault
		// instead of recording a guessed impact (task 6.8's "a coordinate,
		// radius, direction, or intersection exceeds sealed numeric limits"
		// clause).
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	r_point = { static_cast<std::int64_t>(result_x), static_cast<std::int64_t>(result_y) };
	return ok_status();
}

Status range_limit_point(
		const FixedVec2 &p_origin,
		const FixedVec2 &p_direction,
		std::int64_t p_range_milliunits,
		FixedVec2 &r_point) {
	return point_along_ray(p_origin, p_direction, p_range_milliunits, r_point);
}

Status first_hitscan_candidate(
		const FixedVec2 &p_origin,
		const FixedVec2 &p_direction,
		std::int64_t p_range_milliunits,
		const std::vector<HitTarget> &p_targets,
		std::optional<HitCandidate> &r_candidate) {
	r_candidate.reset();
	if (p_targets.size() > MAX_TARGET_CANDIDATES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_targets.size());
	}
	if (p_range_milliunits <= 0 || p_range_milliunits > MAX_WORLD_MILLIUNITS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (!point_in_world_bounds(p_origin)) {
		return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
	}
	FixedVec2 unit;
	Status normalize_status = normalize_direction(p_direction, unit);
	if (!normalize_status.ok()) return normalize_status;

	// Stable target-ID order first (task 6.8's "in stable target-ID order"),
	// independent of the order the eligible-target world port returned them
	// in, so equal-distance ties always resolve to the lower ID below.
	std::vector<const HitTarget *> ordered;
	ordered.reserve(p_targets.size());
	for (const HitTarget &target : p_targets) ordered.push_back(&target);
	std::sort(ordered.begin(), ordered.end(), [](const HitTarget *p_a, const HitTarget *p_b) {
		return canonical_identifier_less(p_a->entity_id, p_b->entity_id);
	});

	std::optional<std::int64_t> best_distance;
	const HitTarget *best_target = nullptr;
	for (const HitTarget *target_ptr : ordered) {
		const HitTarget &target = *target_ptr;
		if (!validate_identifier(target.entity_id).ok() ||
				target.radius_milliunits <= 0 || target.radius_milliunits > MAX_WORLD_MILLIUNITS ||
				!point_in_world_bounds(target.position)) {
			// Not a valid/eligible candidate. The eligible-target world port
			// is expected to have already excluded dead/ineligible targets;
			// this is a defensive skip for malformed data, not a fault.
			continue;
		}

		const Wide vx = Wide(target.position.x) - Wide(p_origin.x);
		const Wide vy = Wide(target.position.y) - Wide(p_origin.y);
		const Wide center_squared = vx * vx + vy * vy;
		const Wide radius_squared = Wide(target.radius_milliunits) * Wide(target.radius_milliunits);

		std::int64_t hit_distance = 0;
		if (center_squared > radius_squared) {
			// Origin is outside the target circle: find the near (entry)
			// intersection of the ray with the circle, if any.
			const Wide closest_scaled = vx * Wide(unit.x) + vy * Wide(unit.y);
			Wide closest = closest_scaled / Wide(DIRECTION_SCALE);
			const Wide closest_remainder = closest_scaled % Wide(DIRECTION_SCALE);
			if (closest_remainder != 0) {
				const Wide twice_abs = (closest_remainder < 0 ? -closest_remainder : closest_remainder) * 2;
				if (twice_abs >= Wide(DIRECTION_SCALE)) {
					closest += (closest_scaled < 0) ? -1 : 1;
				}
			}
			if (closest < 0) continue; // Target lies behind the ray origin.
			const Wide half_chord_squared = radius_squared - center_squared + closest * closest;
			if (half_chord_squared < 0) continue; // Ray misses the circle entirely.
			const std::int64_t half_chord = isqrt_floor(half_chord_squared);
			const Wide entry = closest - Wide(half_chord);
			if (entry < 0) continue;
			if (entry > Wide(p_range_milliunits)) continue; // Beyond range: not a candidate.
			hit_distance = static_cast<std::int64_t>(entry);
		}
		// else: origin is inside/on the circle, entry distance is 0.

		if (!best_distance.has_value() || hit_distance < *best_distance) {
			best_distance = hit_distance;
			best_target = &target;
		}
	}

	if (best_target == nullptr) return ok_status();

	FixedVec2 impact;
	Status impact_status = point_along_ray(p_origin, p_direction, *best_distance, impact);
	if (!impact_status.ok()) return impact_status;
	r_candidate = HitCandidate{ best_target->entity_id, impact, *best_distance };
	return ok_status();
}

} // namespace wpn
