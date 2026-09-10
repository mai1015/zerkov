#ifndef WEAPON_SYSTEM_CORE_WORLD_COORDINATOR_H
#define WEAPON_SYSTEM_CORE_WORLD_COORDINATOR_H

// Task 6.8 (final resolution semantics), 6.4 (at-most-once dispatch), 6.5
// (explicit adapter-health/fault outcomes), and the "exactly one canonical
// damage sink" gate from task 6.1 all live here. This is the engine-free 2D
// world coordinator design.md describes under "Fire transaction and world
// resolution": it takes an already-committed CommittedShot (produced by
// WeaponRuntime::fire(), which already validated pose/cadence/ammunition and
// consumed the round) and resolves it against the bounded world ports.

#include "core/wpn_runtime.h"
#include "core/wpn_status.h"
#include "core/wpn_world_ports.h"

#include <cstdint>
#include <string>
#include <vector>

namespace wpn {

struct DamageSinkRegistration {
	// A short stable label identifying the candidate sink's source (e.g.
	// "game", "gameplay_abilities"), surfaced only for diagnostics.
	std::string source_id;
	DamageSink *sink = nullptr;
};

// Every port a configured authority runtime needs before firing becomes
// ready (task 6.1). canonical_damage_sinks MUST contain exactly one
// non-null entry: zero means no sink was ever selected, more than one means
// two canonical sinks are both trying to be authoritative (weapon-world-
// integration spec's "Two damage sinks are configured" scenario) -- both
// fail configure() before readiness rather than picking one silently.
struct WorldPortConfig {
	ActorPoseProvider *pose_provider = nullptr;
	EligibleTargetQuery *target_query = nullptr;
	ObstructionQuery *obstruction_query = nullptr;
	std::vector<DamageSinkRegistration> canonical_damage_sinks;
	PositionalNoiseSink *noise_sink = nullptr;
};

enum class ShotOutcomeKind : std::uint8_t {
	MISS = 0,
	HIT = 1,
	// The coordinator could not resolve this shot at all (a world query
	// failed, or a value could not be quantized safely). Distinct from MISS:
	// a MISS is a resolved, canonical outcome; FAULTED means no guessed
	// impact was recorded (task 6.5).
	FAULTED = 2,
};

struct ShotResolution {
	// Full versioned canonical value (task 6.7/6.8's "Adopt the versioned
	// ConsequenceIdentity in the world layer"); full-value equality is
	// authoritative, exactly as on CommittedShot/DamageRequest/NoiseRequest.
	ConsequenceIdentity consequence_identity;
	ShotOutcomeKind kind = ShotOutcomeKind::MISS;
	// Populated only when kind == HIT.
	std::string target_id;
	FixedVec2 impact;
	std::int64_t distance_milliunits = 0;
	bool damage_dispatched = false;
	// True when the configured sink itself reported SinkDispatchResult::
	// AMBIGUOUS (see wpn_world_ports.h) rather than a definite REJECTED.
	bool damage_ambiguous = false;
	bool noise_dispatched = false;
	// OK unless something about this resolution is worth surfacing: a fault
	// reason (kind == FAULTED) or a non-fatal damage-dispatch problem on an
	// otherwise-resolved HIT (kind stays HIT, damage_dispatched is false).
	Status status;
};

// Task 6.8 remainder / weapon-world-integration spec, "Explicit World
// Adapter Failure" -> "Committed shot is restored before consequence
// completion": a committed shot whose consequence could not be confirmed by
// the most recent resolve()/resume_unresolved_consequence() attempt -- a
// world-query/quantization FAULT before resolution completed, or a HIT
// whose damage-sink response came back AMBIGUOUS -- is retained here,
// bounded (MAX_UNRESOLVED_CONSEQUENCES), keyed by its own versioned
// ConsequenceIdentity (full-value equality; never the compact hash). This
// is engine-free and snapshot/restorable exactly like WeaponRuntime's own
// instance snapshots (WeaponRuntime::snapshots() / replace_from_snapshots):
// a coordinator torn down and rebuilt from a restored snapshot resumes or
// queries THIS SAME identity rather than inventing a replacement one, and
// never refunds the shot -- WorldCoordinator has no access to WeaponRuntime
// instance state to do so even if it wanted to.
struct UnresolvedConsequence {
	ConsequenceIdentity consequence_identity;
	std::string source_actor_id;
	// The exact committed shot resolve() was originally given. Retained so
	// a FAULTED entry (has_damage_request == false) can be re-resolved from
	// its own original geometry rather than needing a fresh commit.
	CommittedShot shot;
	// The most recent resolution attempt's outcome, exactly as resolve()
	// (or a prior resume) produced it.
	ShotResolution last_result;
	// True once world resolution itself succeeded (kind == HIT) and a
	// DamageRequest was actually built and dispatched with an AMBIGUOUS
	// response -- a resume then only re-dispatches that exact retained
	// request (same idempotency key) rather than re-running geometry.
	bool has_damage_request = false;
	DamageRequest damage_request;
};

// The engine-free 2D world coordinator. Owns no actors, physics bodies,
// health, armor, navigation, or scenes -- only the bounded port pointers a
// game supplies through configure().
class WorldCoordinator {
public:
	// Validates the exactly-one-canonical-damage-sink rule and that every
	// other required port is present. Fails closed (ready() stays false, any
	// previous configuration is discarded) rather than partially adopting an
	// invalid configuration.
	Status configure(const WorldPortConfig &p_config);

	bool ready() const { return configured; }
	// Latched false by any world-query failure, quantization fault, or
	// ambiguous damage-sink response since the last successful configure().
	// A fresh configure() call is the explicit recovery/resync point (mirrors
	// WeaponRuntime's tick-fault-until-new-epoch pattern in design.md).
	bool healthy() const { return adapter_healthy; }

	// Resolves one mechanically committed shot: range-limits the ray,
	// queries eligible targets and the whole-ray obstruction independently,
	// picks the smallest canonical distance (obstruction wins an equal-
	// distance tie; the lower stable target ID wins an equal target-entry-
	// distance tie), dispatches at most one damage request on a HIT, and
	// always publishes positional noise for a structurally valid committed
	// shot -- including misses, obstructions, and query/quantization faults,
	// since ammunition and cadence were already committed by
	// WeaponRuntime::fire() before this ever runs.
	//
	// p_source_actor_id identifies the firing actor for target-query scoping
	// and as the damage/noise request's source identity.
	Status resolve(
			const std::string &p_source_actor_id,
			const CommittedShot &p_shot,
			ShotResolution &r_result);

	// --- Bounded unresolved-consequence retention (task 6.8 remainder) ---

	std::size_t unresolved_consequence_count() const { return unresolved.size(); }
	// Bounded snapshot of every currently retained unresolved consequence.
	std::vector<UnresolvedConsequence> unresolved_consequences() const { return unresolved; }
	// Read-only query by full identity equality (never the compact hash) --
	// the "queries that same consequence identity" half of the restore
	// scenario. Returns nullptr when no unresolved entry matches.
	const UnresolvedConsequence *find_unresolved_consequence(const ConsequenceIdentity &p_identity) const;
	// Trusted wholesale replacement of retained unresolved-consequence state
	// -- the exact restore point after a coordinator snapshot/restore
	// cycle, mirroring WeaponRuntime::replace_from_snapshots. Adopts
	// exactly the identities it is given; it never invents or drops one.
	// Fails closed (state unchanged) on an over-bound payload rather than
	// silently truncating it.
	Status restore_unresolved_consequences(const std::vector<UnresolvedConsequence> &p_unresolved);
	// Resumes/queries the SAME retained consequence identity: re-dispatches
	// an already-resolved HIT's retained damage request, or re-runs
	// geometry resolution for a shot that never got that far -- in both
	// cases without re-publishing noise (already sent by the original
	// attempt) and without ever generating a replacement identity or
	// touching ammunition (WorldCoordinator has no access to WeaponRuntime
	// instance state to refund a round even if it wanted to). Never called
	// automatically by resolve() itself: only an explicit caller decision
	// triggers a resume, so an ambiguous unkeyed sink failure is never
	// auto-retried. Fails with StatusCode::NOT_FOUND when p_identity has no
	// retained entry (already resolved, evicted, or never tracked).
	Status resume_unresolved_consequence(const ConsequenceIdentity &p_identity, ShotResolution &r_result);

private:
	void dispatch_noise(const std::string &p_source_actor_id, const CommittedShot &p_shot);
	// Core geometry + damage-dispatch resolution shared by resolve() and
	// resume_unresolved_consequence(); assumes `configured` and the shot's
	// own structural validity have already been checked by the caller, and
	// never touches the noise sink itself.
	Status resolve_targets_and_damage(
			const std::string &p_source_actor_id,
			const CommittedShot &p_shot,
			ShotResolution &r_result,
			bool &r_has_damage_request,
			DamageRequest &r_damage_request);
	// Records/updates or clears the retained unresolved-consequence entry
	// for p_shot.consequence_identity based on the just-produced result.
	void track_or_clear_unresolved(
			const std::string &p_source_actor_id,
			const CommittedShot &p_shot,
			const ShotResolution &p_result,
			bool p_has_damage_request,
			const DamageRequest &p_damage_request);
	void clear_unresolved(const ConsequenceIdentity &p_identity);

	bool configured = false;
	bool adapter_healthy = true;
	WorldPortConfig config;
	std::vector<UnresolvedConsequence> unresolved;
};

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_WORLD_COORDINATOR_H
