#ifndef WEAPON_SYSTEM_CORE_NUMERICS_H
#define WEAPON_SYSTEM_CORE_NUMERICS_H

#include "core/wpn_runtime.h"
#include "core/wpn_status.h"

#include <cstdint>
#include <string>
#include <vector>

// Sealed V1 numeric contract (task 3.7): the milli-MOA -> nanoradian
// conversion, versioned deterministic aim rotation, versioned seed sampling,
// and the canonical parts-per-million modifier algebra. Every algorithm here
// is engine-free, integer-only, and checked; each is named by a documented
// version constant that participates in the catalog content fingerprint
// (design.md, "Canonical numeric contract": "Numeric constants,
// quantization, sampler version, modifier algebra, limits, and tie rules all
// contribute to compatibility fingerprints").
namespace wpn {

// Version of the milli-MOA -> nanoradian conversion formula
// (round_half_up(accuracy_moa_milli * PI_NANORADIANS / MOA_MILLI_TO_NANORADIAN_DENOMINATOR)).
constexpr std::uint16_t MOA_CONVERSION_VERSION = 1;

// Version of the deterministic small-angle shear rotation that applies a
// signed nanoradian angular offset to a unit aim vector.
constexpr std::uint16_t AIM_ROTATION_ALGORITHM_VERSION = 1;

// Version of the versioned rejection-sampling seed channel used to draw a
// uniform signed offset from [-radius, +radius].
constexpr std::uint16_t DISPERSION_SEED_SAMPLER_VERSION = 1;

// Version of the canonical signed-ppm modifier folding/clamping algebra.
constexpr std::uint16_t MODIFIER_ALGEBRA_VERSION = 1;

// Distinct deterministic seed channels (design.md, "Canonical numeric
// contract": "Horizontal recoil uses a separate seed channel and the same
// bounded integer sampling rule"). Recoil consumption lands in a later task
// (4.10); this enum/API only needs to exist so that task can reuse it.
enum class SeedChannel : std::uint8_t {
	DISPERSION = 1,
	HORIZONTAL_RECOIL = 2,
};

// Converts a validated non-negative integer `accuracy_moa_milli` (1000 ==
// one MOA, full group diameter) into the non-negative integer nanoradian
// angular radius (half the diameter) using checked 128-bit-safe
// quotient/remainder integer math and round-half-up. Rejects negative or
// above-sealed-limit input before any conversion happens.
Status convert_accuracy_moa_milli_to_angular_radius_nrad(
		std::int64_t p_accuracy_moa_milli,
		std::int64_t &r_angular_radius_nrad);

// Draws one deterministic signed integer offset uniformly from the inclusive
// interval [-p_radius_nrad, +p_radius_nrad] via rejection sampling against
// `p_seed` mixed with the versioned `p_channel` salt. Bounded to
// MAX_REJECTION_SAMPLING_ATTEMPTS retries; the final attempt is used even if
// still biased (astronomically unlikely given the sealed radius bound), so
// the function always terminates deterministically. `p_radius_nrad == 0`
// yields `0` without consuming the channel. Implemented in terms of
// `sample_uniform_signed_range_nrad(p_seed, p_channel, -p_radius_nrad,
// +p_radius_nrad, r_offset_nrad)` below; bit-identical to the pre-4.10
// implementation for every existing caller/golden fixture.
Status sample_uniform_signed_offset_nrad(
		std::uint64_t p_seed,
		SeedChannel p_channel,
		std::int64_t p_radius_nrad,
		std::int64_t &r_offset_nrad);

// Draws one deterministic signed integer value uniformly from the inclusive
// interval [p_min_nrad, p_max_nrad] (not necessarily symmetric around zero)
// via the same versioned rejection-sampling channel primitive as
// `sample_uniform_signed_offset_nrad` above. Used by deterministic recoil
// kick (weapon-runtime spec, "Deterministic Recoil Kick and Recovery"):
// `RecoilProfile::horizontal_kick_min_nrad`/`horizontal_kick_max_nrad` are
// authored as an explicit bounded range, not necessarily symmetric. Rejects
// `p_min_nrad > p_max_nrad` or either bound outside
// [-MAX_ANGLE_NANORADIANS, +MAX_ANGLE_NANORADIANS]. `p_min_nrad == p_max_nrad`
// yields that fixed value without consuming the channel.
Status sample_uniform_signed_range_nrad(
		std::uint64_t p_seed,
		SeedChannel p_channel,
		std::int64_t p_min_nrad,
		std::int64_t p_max_nrad,
		std::int64_t &r_value_nrad);

// Applies a signed nanoradian angular offset to a unit aim vector using the
// V1 deterministic small-angle shear rotation (AIM_ROTATION_ALGORITHM_VERSION),
// then renormalizes to DIRECTION_SCALE. Safe without an explicit overflow
// check: inputs are bounded to |component| <= DIRECTION_SCALE (1e6) and
// |angle| <= MAX_ANGLE_NANORADIANS (~3.14e9), so the largest possible
// intermediate product (~3.14e15) is far inside the int64 range.
FixedVec2 rotate_unit_vector_by_angle_nrad(const FixedVec2 &p_unit_vector, std::int64_t p_angle_nrad);

// ModifierDelta is declared in core/wpn_runtime.h (moved there in tasks.md
// 4.11 to break a would-be circular include: wpn_runtime.h's
// AttachmentModifierDeltas helper needs it, and this header already depends
// on wpn_runtime.h for FixedVec2).

// Sums `p_deltas` in canonical (source, slot_id, definition_id,
// definition_version) order using checked arithmetic, then clamps the
// resulting aggregate multiplier once to [MIN_MODIFIER_MULTIPLIER_PPM,
// MAX_MODIFIER_MULTIPLIER_PPM] around MODIFIER_NEUTRAL_PPM. Rejects the
// complete set (leaving `r_aggregate_multiplier_ppm` at 0) if any delta is
// out of the sealed per-delta bound, the fold exceeds MAX_MODIFIER_FOLD_DELTAS,
// or checked accumulation would overflow.
Status fold_modifier_deltas_ppm(const std::vector<ModifierDelta> &p_deltas, std::int64_t &r_aggregate_multiplier_ppm);

// Multiplies `p_base_value` by `p_aggregate_multiplier_ppm` exactly once
// (checked 128-bit-safe), rounds ties away from zero, then applies the
// property's final legal clamp to [p_min_result, p_max_result].
Status apply_modifier_multiplier(
		std::int64_t p_base_value,
		std::int64_t p_aggregate_multiplier_ppm,
		std::int64_t p_min_result,
		std::int64_t p_max_result,
		std::int64_t &r_result);

// Pure checked recoil-recovery function (tasks.md 4.10; weapon-runtime spec,
// "Deterministic Recoil Kick and Recovery": "The core SHALL derive effective
// recoil as a pure checked function of stored integer-nanoradian offsets,
// their anchor tick, the sealed recovery slope, and a non-regressing
// authority tick"). Moves `p_stored_offset_nrad` toward zero at
// `p_recovery_per_tick_nrad` per elapsed tick without overshoot, using a
// saturating early-exit (rather than literally multiplying an unbounded
// elapsed-tick count) so no intermediate product can overflow even for an
// astronomically large `p_query_tick - p_anchor_tick`. Rejects
// `p_query_tick < p_anchor_tick` (the caller must only ever query at or after
// the stored anchor -- authority ticks never regress) and a non-positive
// `p_recovery_per_tick_nrad` (the sealed RecoilProfile already validates
// this positive at catalog-seal time). Calling this on an idle tick (no fire,
// no other transition) NEVER mutates canonical state; it is a read-only
// derivation the caller may use for a query or as part of deriving the next
// shot's residual.
Status compute_effective_recoil_offset_nrad(
		std::int64_t p_stored_offset_nrad,
		std::uint64_t p_anchor_tick,
		std::int64_t p_recovery_per_tick_nrad,
		std::uint64_t p_query_tick,
		std::int64_t &r_effective_offset_nrad);

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_NUMERICS_H
