#ifndef WEAPON_SYSTEM_CORE_HITSCAN_H
#define WEAPON_SYSTEM_CORE_HITSCAN_H

#include "core/wpn_runtime.h"
#include "core/wpn_status.h"

#include <optional>
#include <string>
#include <vector>

namespace wpn {

struct HitTarget {
	std::string entity_id;
	FixedVec2 position;
	std::int64_t radius_milliunits = 0;
};

struct HitCandidate {
	std::string entity_id;
	FixedVec2 impact;
	std::int64_t distance_milliunits = 0;
};

// Deterministic checked-integer point at exactly p_distance_milliunits along
// the ray from p_origin toward p_direction. Every quantity here is sealed
// integer world-milliunit arithmetic (task 6.8, "Canonical World Geometry
// Values") -- no floating point participates, so the result is identical on
// every supported platform. Faults with StatusCode::ARITHMETIC_ERROR /
// DiagnosticId::OVERFLOW_DETECTED instead of guessing when p_direction
// cannot be safely normalized (zero vector or an out-of-bounds component)
// or when the origin/distance/resulting point cannot be represented within
// the sealed +/-MAX_WORLD_MILLIUNITS coordinate bound.
Status point_along_ray(
		const FixedVec2 &p_origin,
		const FixedVec2 &p_direction,
		std::int64_t p_distance_milliunits,
		FixedVec2 &r_point);

// The canonical miss impact point when nothing is found within range: the
// point exactly p_range_milliunits from p_origin along p_direction.
Status range_limit_point(
		const FixedVec2 &p_origin,
		const FixedVec2 &p_direction,
		std::int64_t p_range_milliunits,
		FixedVec2 &r_point);

// Resolves the nearest positive-radius target whose ray-circle ENTRY point
// (task 6.8's key semantic: entry, not center) lies within
// [0, p_range_milliunits], scanning targets in canonical stable-ID order
// (wpn::canonical_identifier_less) so equal-distance target entries are
// deterministically broken by the lower stable target ID regardless of the
// order p_targets arrives in. Targets with a non-positive or out-of-bounds
// radius, an invalid identifier, or an out-of-bounds position are treated
// as ineligible and skipped rather than faulted -- callers are expected to
// have already filtered dead/ineligible targets through the eligible-target
// world port. r_candidate is reset to std::nullopt when no target qualifies.
// This function does not know about obstruction; combining a target
// candidate with an independently queried obstruction distance is the
// world coordinator's job (see wpn_world_coordinator.h).
Status first_hitscan_candidate(
		const FixedVec2 &p_origin,
		const FixedVec2 &p_direction,
		std::int64_t p_range_milliunits,
		const std::vector<HitTarget> &p_targets,
		std::optional<HitCandidate> &r_candidate);

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_HITSCAN_H
