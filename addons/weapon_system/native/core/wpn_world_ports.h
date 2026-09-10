#ifndef WEAPON_SYSTEM_CORE_WORLD_PORTS_H
#define WEAPON_SYSTEM_CORE_WORLD_PORTS_H

// Task 6.1: bounded, engine-free port interfaces for the world integration
// the weapon-world-integration spec ("Requirement: Game-Owned Authoritative
// World Ports") requires. A game supplies concrete adapters implementing
// these five abstract interfaces; core never imports a game-specific actor,
// physics, or scene type. Every exchanged coordinate/radius/distance is a
// finite bounded integer under the one sealed world-milliunit scale defined
// in wpn_limits.h (MAX_WORLD_MILLIUNITS, DIRECTION_SCALE,
// WORLD_QUANTIZATION_VERSION/WORLD_TIE_RULE_VERSION).

#include "core/wpn_hitscan.h"
#include "core/wpn_runtime.h"
#include "core/wpn_status.h"

#include <cstdint>
#include <string>
#include <type_traits>
#include <vector>

namespace wpn {

// Port: authoritative actor pose provider. Supplies the server-owned origin/
// aim a fire transition resolves from (design.md, "Fire transaction and
// world resolution": "The runtime validates ... before mutation"; the
// weapon-world-integration spec's "Authoritative Pose Compatibility"
// requirement). Games back this with their own actor/physics model.
class ActorPoseProvider {
public:
	virtual ~ActorPoseProvider() = default;

	// Returns false when p_actor_id is unknown, dead, or its authoritative
	// pose cannot be resolved this tick, leaving r_origin/r_aim unspecified.
	// A caller MUST treat false as "do not attempt to fire" and never fall
	// back to a client-claimed pose.
	virtual bool query_actor_pose(
			const std::string &p_actor_id,
			FixedVec2 &r_origin,
			FixedVec2 &r_aim) const = 0;
};

// Port: bounded eligible-target query. The game is the sole authority for
// actor liveness, faction, and targetability; core never sees a target this
// port did not already consider eligible.
class EligibleTargetQuery {
public:
	virtual ~EligibleTargetQuery() = default;

	// Fills r_targets with at most MAX_TARGET_CANDIDATES eligible targets
	// (already excluding dead/ineligible actors) that have a positive radius
	// and a stable target ID; the coordinator re-sorts them by stable ID
	// before resolution, so the returned order does not need to be stable.
	// Returns false when the query cannot be answered this tick (adapter
	// fault); r_targets is then unspecified and the shot resolves as
	// unresolved/faulted rather than a guessed miss.
	virtual bool query_eligible_targets(
			const std::string &p_source_actor_id,
			const FixedVec2 &p_origin,
			std::int64_t p_range_milliunits,
			std::vector<HitTarget> &r_targets) const = 0;
};

// Port: 2D obstruction query along the whole bounded ray (task 6.8's
// "independently query the nearest authoritative obstruction along the
// complete bounded ray", as distinct from any single target's entry
// distance). A game typically backs this with tile/physics raycasting or a
// sibling addon such as common_vision; core has no opinion on how the
// obstruction distance is produced, only that it is already quantized to
// the sealed world-milliunit scale.
class ObstructionQuery {
public:
	virtual ~ObstructionQuery() = default;

	// Returns true when the query itself succeeded, filling r_hit/
	// r_distance_milliunits with whether an obstruction exists within
	// [0, p_range_milliunits] and, if so, its canonical distance. Returns
	// false when the query cannot be answered this tick (adapter fault).
	virtual bool query_nearest_obstruction(
			const FixedVec2 &p_origin,
			const FixedVec2 &p_direction,
			std::int64_t p_range_milliunits,
			bool &r_hit,
			std::int64_t &r_distance_milliunits) const = 0;
};

// A committed shot's damage consequence, keyed by the shot's own versioned
// ConsequenceIdentity (CommittedShot::consequence_identity; task 6.7/6.8's
// "Adopt the versioned ConsequenceIdentity in the world layer"). Full-value
// equality (ConsequenceIdentity::operator==) is authoritative for identity
// decisions here exactly as it is on CommittedShot -- compact_hash() may
// index this value but MUST NOT replace it. The legacy compact string id
// stays only on CommittedShot itself (native/godot and native/protocol
// still read it there); DamageRequest/NoiseRequest/ShotResolution are
// engine-free core/tests-only types with no such caller, so they carry the
// canonical value directly rather than a derived string projection of it.
//
// Fields otherwise mirror the weapon-world-integration spec's "At-Most-Once
// Consequence Dispatch" scenario text verbatim: "stable consequence,
// source, target, weapon, tick, and magnitude values".
struct DamageRequest {
	ConsequenceIdentity consequence_identity;
	std::string source_actor_id;
	std::string target_id;
	std::string weapon_id;
	std::uint16_t weapon_version = 1;
	// Exact ammunition-ballistic profile ID/version this shot consumed
	// (tasks.md 6.7; design.md "Bullet profile and penetration ownership":
	// "Fire consumes a round of that profile, copies its identity onto the
	// committed shot and damage request"), copied verbatim from
	// CommittedShot::consumed_profile. A game with no penetration system at
	// all still receives this identity -- the Weapon System never invents a
	// penetration result of its own; a game that DOES support penetration
	// resolves it by looking this identity up in its own bullet/armor
	// content, never from a value defined here or on any weapon/attachment
	// definition (design.md: "Attachments and weapon modifiers cannot
	// overwrite bullet penetration in V1").
	BallisticProfileIdentity profile;
	std::uint64_t tick = 0;
	std::int64_t damage_milliunits = 0;
	FixedVec2 impact;
};

namespace world_ports_detail {
template <typename T, typename = void>
struct has_penetration_member : std::false_type {};
template <typename T>
struct has_penetration_member<T, std::void_t<decltype(std::declval<T>().penetration)>> : std::true_type {};
} // namespace world_ports_detail

// World-side compile-time assertion (tasks.md 6.7c; weapon-world-integration
// spec, "Bullet-Owned Penetration Boundary": "Weapon and attachment
// definitions SHALL NOT supply or modify penetration"). Weapon/attachment
// definitions already have no penetration field and are validated to reject
// one (wpn_definitions.h/.cpp, out of this task's core/world scope); this is
// the matching guarantee at the WORLD boundary DamageRequest crosses into a
// game's own damage/armor authority. If a future change ever adds a
// `penetration` member to DamageRequest, this fails to compile rather than
// silently letting the Weapon System invent a penetration result -- the only
// bullet identity a game may resolve penetration from is `profile` above,
// looked up against the game's own sealed bullet/armor content.
static_assert(!world_ports_detail::has_penetration_member<DamageRequest>::value,
		"DamageRequest must never gain a penetration field -- penetration is bullet/world-owned, never Weapon System's (design.md, \"Bullet profile and penetration ownership\")");

// A sink that cannot answer synchronously and does not support an
// idempotency key MUST report AMBIGUOUS rather than silently guessing
// ACCEPTED/REJECTED; the coordinator never retries a dispatch within the
// same resolve() call regardless of the result (task 6.5: "an ambiguous
// unkeyed sink failure is never retried automatically").
enum class SinkDispatchResult : std::uint8_t {
	ACCEPTED = 0,
	REJECTED = 1,
	AMBIGUOUS = 2,
};

// Port: the exactly-one configured canonical damage sink for a configured
// authority runtime (task 6.1's "A game MUST select exactly one damage sink
// for a configured authority runtime"). p_request.consequence_identity is
// the idempotency key (full-value equality) a sink that supports
// resumption/idempotent replies keys its own state by.
class DamageSink {
public:
	virtual ~DamageSink() = default;
	virtual SinkDispatchResult dispatch_damage(const DamageRequest &p_request) = 0;
};

struct NoiseRequest {
	// Full versioned canonical value (see DamageRequest::consequence_identity
	// above); full-value equality is authoritative.
	ConsequenceIdentity consequence_identity;
	std::string source_actor_id;
	FixedVec2 origin;
	std::int64_t radius_milliunits = 0;
	std::uint64_t tick = 0;
};

// Port: positional noise sink. Invoked for every committed shot the
// coordinator processes, including misses and obstructions, because
// ammunition and cadence were already committed by WeaponRuntime::fire()
// (task 6.4).
class PositionalNoiseSink {
public:
	virtual ~PositionalNoiseSink() = default;
	virtual void publish_noise(const NoiseRequest &p_request) = 0;
};

// Task 6.3's ordering requirement extends one step earlier than
// WeaponRuntime::fire()'s existing origin/aim tolerance check (see
// cadence_and_pose_are_authoritative in wpn_test_runtime.cpp, which already
// verifies fire() rejects an out-of-tolerance claimed pose before consuming
// ammunition): a caller must be able to obtain the authoritative pose *at
// all* before even attempting to fire, rather than defaulting to a claimed
// or stale pose when the world adapter cannot answer for the actor. This
// thin forwarding helper is the single, testable seam a Godot-facing
// orchestrator (or a native test) uses to do that -- when it returns false,
// the caller MUST reject the fire attempt without calling
// WeaponRuntime::fire() at all, so ammunition is never mutated.
inline bool resolve_authoritative_pose(
		const ActorPoseProvider &p_provider,
		const std::string &p_actor_id,
		FixedVec2 &r_origin,
		FixedVec2 &r_aim) {
	return p_provider.query_actor_pose(p_actor_id, r_origin, r_aim);
}

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_WORLD_PORTS_H
