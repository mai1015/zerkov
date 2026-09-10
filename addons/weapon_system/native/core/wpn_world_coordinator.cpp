#include "core/wpn_world_coordinator.h"

#include "core/wpn_hitscan.h"
#include "core/wpn_limits.h"

namespace wpn {

Status WorldCoordinator::configure(const WorldPortConfig &p_config) {
	configured = false;
	if (p_config.pose_provider == nullptr || p_config.target_query == nullptr ||
			p_config.obstruction_query == nullptr || p_config.noise_sink == nullptr) {
		return make_status(StatusCode::SINK_MISCONFIGURED, DiagnosticId::WORLD_PORT_MISSING);
	}
	// Task 6.1: "A game MUST select exactly one damage sink for a configured
	// authority runtime." Zero canonical sinks means firing was never wired
	// to a consequence; more than one means two candidates (e.g. a game
	// world sink and a GAS sink) are both trying to be canonical. Both fail
	// here, before firing becomes ready, instead of picking one implicitly.
	if (p_config.canonical_damage_sinks.size() != 1) {
		return make_status(StatusCode::SINK_MISCONFIGURED, DiagnosticId::DAMAGE_SINK_COUNT_INVALID,
				p_config.canonical_damage_sinks.size());
	}
	if (p_config.canonical_damage_sinks.front().sink == nullptr) {
		return make_status(StatusCode::SINK_MISCONFIGURED, DiagnosticId::WORLD_PORT_MISSING);
	}
	config = p_config;
	configured = true;
	adapter_healthy = true;
	// Deliberately does NOT clear `unresolved`: a fresh configure() (e.g. a
	// game rewiring its adapters after a restart) must not silently forget a
	// committed shot whose consequence is still outstanding -- that is
	// exactly the "guess/forget" behavior task 6.5/6.8 forbid. Only an
	// explicit restore_unresolved_consequences() or a successful
	// resolve()/resume_unresolved_consequence() call ever changes it.
	return ok_status();
}

void WorldCoordinator::dispatch_noise(const std::string &p_source_actor_id, const CommittedShot &p_shot) {
	NoiseRequest request;
	request.consequence_identity = p_shot.consequence_identity;
	request.source_actor_id = p_source_actor_id;
	request.origin = p_shot.origin;
	request.radius_milliunits = p_shot.noise_radius_milliunits;
	request.tick = p_shot.tick;
	config.noise_sink->publish_noise(request);
}

Status WorldCoordinator::resolve_targets_and_damage(
		const std::string &p_source_actor_id,
		const CommittedShot &p_shot,
		ShotResolution &r_result,
		bool &r_has_damage_request,
		DamageRequest &r_damage_request) {
	r_has_damage_request = false;

	std::vector<HitTarget> targets;
	const bool target_query_ok = config.target_query->query_eligible_targets(
			p_source_actor_id, p_shot.origin, p_shot.range_milliunits, targets);

	bool obstruction_hit = false;
	std::int64_t obstruction_distance = 0;
	const bool obstruction_query_ok = config.obstruction_query->query_nearest_obstruction(
			p_shot.origin, p_shot.direction, p_shot.range_milliunits, obstruction_hit, obstruction_distance);

	std::optional<HitCandidate> candidate;
	Status geometry_status = ok_status();
	if (target_query_ok) {
		geometry_status = first_hitscan_candidate(p_shot.origin, p_shot.direction, p_shot.range_milliunits, targets, candidate);
	}

	// Task 6.5: a world query failure after mechanical commit produces an
	// unresolved/faulted shot and an unhealthy adapter. The consumed round is
	// never touched here (WorldCoordinator has no access to WeaponRuntime's
	// instance state), so "not silently restored" is satisfied structurally.
	if (!target_query_ok || !obstruction_query_ok || !geometry_status.ok()) {
		adapter_healthy = false;
		r_result.kind = ShotOutcomeKind::FAULTED;
		if (!geometry_status.ok()) {
			r_result.status = geometry_status;
		} else {
			r_result.status = make_status(StatusCode::WORLD_QUERY_FAILED,
					target_query_ok ? DiagnosticId::WORLD_OBSTRUCTION_QUERY_FAILED : DiagnosticId::WORLD_TARGET_QUERY_FAILED);
		}
		return r_result.status;
	}

	// A port-supplied obstruction distance is untrusted input; bound it to
	// the sealed scale/range the same way target geometry already is.
	if (obstruction_hit && (obstruction_distance < 0 || obstruction_distance > p_shot.range_milliunits)) {
		adapter_healthy = false;
		r_result.kind = ShotOutcomeKind::FAULTED;
		r_result.status = make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
		return r_result.status;
	}

	// Task 6.8's canonical comparison: smallest distance wins, obstruction
	// wins an equal-distance tie (so the target branch requires a strict
	// "<", never "<="), nothing in range misses at the range limit.
	Status impact_status;
	if (candidate.has_value() && (!obstruction_hit || candidate->distance_milliunits < obstruction_distance)) {
		r_result.kind = ShotOutcomeKind::HIT;
		r_result.target_id = candidate->entity_id;
		r_result.impact = candidate->impact;
		r_result.distance_milliunits = candidate->distance_milliunits;
		impact_status = ok_status();
	} else if (obstruction_hit) {
		r_result.kind = ShotOutcomeKind::MISS;
		r_result.distance_milliunits = obstruction_distance;
		impact_status = point_along_ray(p_shot.origin, p_shot.direction, obstruction_distance, r_result.impact);
	} else {
		r_result.kind = ShotOutcomeKind::MISS;
		r_result.distance_milliunits = p_shot.range_milliunits;
		impact_status = range_limit_point(p_shot.origin, p_shot.direction, p_shot.range_milliunits, r_result.impact);
	}

	if (!impact_status.ok()) {
		adapter_healthy = false;
		r_result.kind = ShotOutcomeKind::FAULTED;
		r_result.status = impact_status;
		return r_result.status;
	}

	if (r_result.kind == ShotOutcomeKind::HIT) {
		DamageRequest request;
		request.consequence_identity = p_shot.consequence_identity;
		request.source_actor_id = p_source_actor_id;
		request.target_id = r_result.target_id;
		request.weapon_id = p_shot.weapon_id;
		request.weapon_version = p_shot.weapon_version;
		// Task 6.7: carry the exact consumed ammunition-ballistic profile
		// identity through to the damage request, independent of weapon/
		// attachment mechanical accounting above -- see the
		// has_penetration_member static_assert in wpn_world_ports.h for the
		// matching compile-time guarantee that this is never a penetration
		// value the Weapon System invented itself.
		request.profile = p_shot.consumed_profile;
		request.tick = p_shot.tick;
		request.damage_milliunits = p_shot.damage_milliunits;
		request.impact = r_result.impact;

		// At most one damage dispatch per committed shot (task 6.4), never
		// retried within this call regardless of the outcome (task 6.5).
		const SinkDispatchResult dispatch = config.canonical_damage_sinks.front().sink->dispatch_damage(request);
		r_has_damage_request = true;
		r_damage_request = request;
		if (dispatch == SinkDispatchResult::ACCEPTED) {
			r_result.damage_dispatched = true;
		} else {
			r_result.damage_ambiguous = dispatch == SinkDispatchResult::AMBIGUOUS;
			// An ambiguous response means we cannot tell whether the
			// consequence landed, so the adapter is latched unhealthy until
			// an explicit reconfigure/resync; a definite REJECTED is not an
			// adapter malfunction by itself and does not latch health.
			if (r_result.damage_ambiguous) adapter_healthy = false;
			r_result.status = make_status(StatusCode::SINK_DISPATCH_FAILED,
					r_result.damage_ambiguous ? DiagnosticId::DAMAGE_SINK_AMBIGUOUS : DiagnosticId::DAMAGE_SINK_REJECTED);
		}
	}

	return r_result.status;
}

void WorldCoordinator::clear_unresolved(const ConsequenceIdentity &p_identity) {
	for (auto it = unresolved.begin(); it != unresolved.end(); ++it) {
		if (it->consequence_identity == p_identity) {
			unresolved.erase(it);
			return;
		}
	}
}

void WorldCoordinator::track_or_clear_unresolved(
		const std::string &p_source_actor_id,
		const CommittedShot &p_shot,
		const ShotResolution &p_result,
		bool p_has_damage_request,
		const DamageRequest &p_damage_request) {
	// Full-value equality is authoritative for identity lookups (never the
	// compact hash) -- ConsequenceIdentity::operator==, exactly as the
	// weapon-world-integration spec requires.
	const bool still_unresolved =
			p_result.kind == ShotOutcomeKind::FAULTED ||
			(p_result.kind == ShotOutcomeKind::HIT && p_result.damage_ambiguous);
	if (!still_unresolved) {
		clear_unresolved(p_shot.consequence_identity);
		return;
	}
	for (UnresolvedConsequence &existing : unresolved) {
		if (existing.consequence_identity == p_shot.consequence_identity) {
			existing.source_actor_id = p_source_actor_id;
			existing.shot = p_shot;
			existing.last_result = p_result;
			existing.has_damage_request = p_has_damage_request;
			if (p_has_damage_request) existing.damage_request = p_damage_request;
			return;
		}
	}
	// Bounded FIFO eviction, oldest first, mirroring
	// WeaponRuntime::record_command's MAX_IDEMPOTENCY_RECORDS discipline.
	while (unresolved.size() >= MAX_UNRESOLVED_CONSEQUENCES) {
		unresolved.erase(unresolved.begin());
	}
	UnresolvedConsequence entry;
	entry.consequence_identity = p_shot.consequence_identity;
	entry.source_actor_id = p_source_actor_id;
	entry.shot = p_shot;
	entry.last_result = p_result;
	entry.has_damage_request = p_has_damage_request;
	if (p_has_damage_request) entry.damage_request = p_damage_request;
	unresolved.push_back(entry);
}

Status WorldCoordinator::resolve(
		const std::string &p_source_actor_id,
		const CommittedShot &p_shot,
		ShotResolution &r_result) {
	r_result = ShotResolution{};
	r_result.consequence_identity = p_shot.consequence_identity;

	if (!configured) {
		r_result.kind = ShotOutcomeKind::FAULTED;
		r_result.status = make_status(StatusCode::SINK_MISCONFIGURED, DiagnosticId::WORLD_PORT_MISSING);
		return r_result.status;
	}

	// Structural pre-validation of the committed shot record itself (origin/
	// direction/range under the sealed coordinate scale), reusing
	// first_hitscan_candidate's own bound checks against an empty target
	// list rather than duplicating them. If this is malformed the shot
	// record cannot be trusted at all, so no port is touched and no noise
	// is published -- this is a defensive path: WeaponRuntime::fire()
	// already validates origin/direction bounds and the shot profile's
	// range is validated content, so reaching this in production would
	// itself indicate a deeper bug rather than a normal gameplay outcome.
	// Not retained as an unresolved consequence for the same reason: a shot
	// record this untrustworthy is not something a later resume could act
	// on meaningfully.
	{
		std::vector<HitTarget> probe;
		std::optional<HitCandidate> unused;
		Status structural = first_hitscan_candidate(p_shot.origin, p_shot.direction, p_shot.range_milliunits, probe, unused);
		if (!structural.ok()) {
			r_result.kind = ShotOutcomeKind::FAULTED;
			r_result.status = structural;
			return r_result.status;
		}
	}

	bool has_damage_request = false;
	DamageRequest damage_request;
	const Status status = resolve_targets_and_damage(p_source_actor_id, p_shot, r_result, has_damage_request, damage_request);

	// Task 6.4: noise publishes for every committed shot this coordinator
	// resolves, hit or miss, because ammunition/cadence were already
	// committed before resolve() was ever called.
	dispatch_noise(p_source_actor_id, p_shot);
	r_result.noise_dispatched = true;

	track_or_clear_unresolved(p_source_actor_id, p_shot, r_result, has_damage_request, damage_request);

	return status;
}

const UnresolvedConsequence *WorldCoordinator::find_unresolved_consequence(const ConsequenceIdentity &p_identity) const {
	for (const UnresolvedConsequence &entry : unresolved) {
		if (entry.consequence_identity == p_identity) return &entry;
	}
	return nullptr;
}

Status WorldCoordinator::restore_unresolved_consequences(const std::vector<UnresolvedConsequence> &p_unresolved) {
	if (p_unresolved.size() > MAX_UNRESOLVED_CONSEQUENCES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_unresolved.size());
	}
	// Exact wholesale replacement -- never invents an identity that was not
	// in p_unresolved, never silently drops one that was.
	unresolved = p_unresolved;
	return ok_status();
}

Status WorldCoordinator::resume_unresolved_consequence(
		const ConsequenceIdentity &p_identity,
		ShotResolution &r_result) {
	r_result = ShotResolution{};
	r_result.consequence_identity = p_identity;

	if (!configured) {
		r_result.kind = ShotOutcomeKind::FAULTED;
		r_result.status = make_status(StatusCode::SINK_MISCONFIGURED, DiagnosticId::WORLD_PORT_MISSING);
		return r_result.status;
	}

	UnresolvedConsequence *entry = nullptr;
	for (UnresolvedConsequence &candidate : unresolved) {
		if (candidate.consequence_identity == p_identity) {
			entry = &candidate;
			break;
		}
	}
	if (entry == nullptr) {
		r_result.status = make_status(StatusCode::NOT_FOUND, DiagnosticId::UNRESOLVED_CONSEQUENCE_UNKNOWN);
		return r_result.status;
	}

	if (entry->has_damage_request) {
		// Resolution itself already completed (a HIT); only the damage-sink
		// confirmation is outstanding. Copy out everything needed before the
		// dispatch, since track_or_clear_unresolved below may erase `entry`
		// from `unresolved` and invalidate the pointer.
		const std::string source_actor_id = entry->source_actor_id;
		const CommittedShot shot = entry->shot;
		const DamageRequest damage_request = entry->damage_request;
		r_result = entry->last_result;
		entry = nullptr;

		// Re-dispatch the EXACT retained request -- same idempotency key,
		// same target/impact/damage -- so an idempotent sink resumes/
		// answers by that identity rather than seeing a fresh, unrelated
		// request. Noise is never re-published here: the original resolve()
		// call already sent it for this identity.
		const SinkDispatchResult dispatch = config.canonical_damage_sinks.front().sink->dispatch_damage(damage_request);
		if (dispatch == SinkDispatchResult::ACCEPTED) {
			r_result.damage_dispatched = true;
			r_result.damage_ambiguous = false;
			r_result.status = ok_status();
		} else {
			r_result.damage_dispatched = false;
			r_result.damage_ambiguous = dispatch == SinkDispatchResult::AMBIGUOUS;
			if (r_result.damage_ambiguous) adapter_healthy = false;
			r_result.status = make_status(StatusCode::SINK_DISPATCH_FAILED,
					r_result.damage_ambiguous ? DiagnosticId::DAMAGE_SINK_AMBIGUOUS : DiagnosticId::DAMAGE_SINK_REJECTED);
		}
		track_or_clear_unresolved(source_actor_id, shot, r_result, true, damage_request);
		return r_result.status;
	}

	// Resolution itself never completed originally (a world-query/
	// quantization fault before any damage request existed). Re-run
	// resolution on the SAME retained committed shot -- never a re-derived
	// or replacement one -- without re-publishing noise, which the original
	// resolve() attempt already sent for this identity.
	const std::string source_actor_id = entry->source_actor_id;
	const CommittedShot shot = entry->shot;
	entry = nullptr;

	bool has_damage_request = false;
	DamageRequest damage_request;
	const Status status = resolve_targets_and_damage(source_actor_id, shot, r_result, has_damage_request, damage_request);
	r_result.noise_dispatched = true; // already sent by the original resolve() attempt
	track_or_clear_unresolved(source_actor_id, shot, r_result, has_damage_request, damage_request);
	return status;
}

} // namespace wpn
