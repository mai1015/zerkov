#include "core/cv_world.h"

#include "core/cv_limits.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <tuple>

namespace cv {
namespace {

using Wide = __int128_t;
using UWide = __uint128_t;

std::uint64_t integer_sqrt(UWide p_value) {
	UWide result = 0;
	UWide bit = UWide(1) << 126;
	while (bit > p_value) {
		bit >>= 2;
	}
	while (bit != 0) {
		if (p_value >= result + bit) {
			p_value -= result + bit;
			result = (result >> 1) + bit;
		} else {
			result >>= 1;
		}
		bit >>= 2;
	}
	return static_cast<std::uint64_t>(result);
}

bool checked_add(std::int64_t p_a, std::int64_t p_b, std::int64_t &r_value) {
	const Wide value = Wide(p_a) + Wide(p_b);
	if (value < std::numeric_limits<std::int64_t>::min() ||
			value > std::numeric_limits<std::int64_t>::max()) {
		return false;
	}
	r_value = static_cast<std::int64_t>(value);
	return true;
}

} // namespace

VisionWorld2D::VisionWorld2D(WorldId p_id, WorldRole p_role,
		std::int64_t p_spatial_cell_size,
		std::uint64_t p_max_visited_cells) :
		world_id(p_id),
		world_role(p_role),
		target_grid(p_spatial_cell_size, p_max_visited_cells) {}

Status VisionWorld2D::require_authority() const {
	if (world_role == WorldRole::REPLICA) {
		return make_status(StatusCode::ROLE_VIOLATION,
				DiagnosticId::ROLE_IS_REPLICA);
	}
	return ok_status();
}

Status VisionWorld2D::validate_observer(const Observer &p_observer) const {
	if (!p_observer.id) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_IDENTITY);
	}
	Status status = validate_point(p_observer.position);
	if (!status.ok()) {
		return status;
	}
	status = validate_point(p_observer.facing);
	if (!status.ok()) {
		return status;
	}
	if (p_observer.facing == Vec2{}) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_DIRECTION, p_observer.id.value);
	}
	if (p_observer.range <= 0 || p_observer.range > MAX_ABS_COORDINATE) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::NON_POSITIVE_RANGE, p_observer.id.value);
	}
	status = target_grid.validate_query(p_observer.position, p_observer.range);
	if (!status.ok()) {
		return status;
	}
	if (p_observer.cone_cos_million < 0 ||
			p_observer.cone_cos_million > COORDINATE_SCALE) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_CONE, p_observer.id.value);
	}
	if (p_observer.target_mask == 0 || p_observer.occluder_mask == 0 ||
			p_observer.revision == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				p_observer.revision == 0 ? DiagnosticId::OBSERVER_REVISION_STALE :
											 DiagnosticId::INVALID_MASK,
				p_observer.id.value);
	}
	return ok_status();
}

Status VisionWorld2D::validate_target(const Target &p_target) const {
	if (!p_target.id || p_target.revision == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				!p_target.id ? DiagnosticId::INVALID_IDENTITY :
								 DiagnosticId::TARGET_REVISION_STALE);
	}
	Status status = validate_point(p_target.position);
	if (!status.ok()) {
		return status;
	}
	if (p_target.mask == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_MASK, p_target.id.value);
	}
	if (p_target.sample_policy != SamplePolicy::ANY_SAMPLE &&
			p_target.sample_policy != SamplePolicy::ALL_SAMPLES) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_SAMPLE_POLICY, p_target.id.value);
	}
	if (p_target.sample_offsets.empty() ||
			p_target.sample_offsets.size() > MAX_SAMPLES_PER_TARGET) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				p_target.sample_offsets.size());
	}
	for (Vec2 offset : p_target.sample_offsets) {
		status = validate_point(offset);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status VisionWorld2D::replace_geometry(
		std::vector<Segment> p_segments, Revision p_new_revision) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	status = validate_segments(p_segments);
	if (!status.ok()) {
		return status;
	}
	if (p_new_revision <= current_geometry_revision) {
		return make_status(StatusCode::REVISION_MISMATCH,
				DiagnosticId::GEOMETRY_REVISION_STALE, p_new_revision);
	}
	std::sort(p_segments.begin(), p_segments.end(),
			[](const Segment &p_a, const Segment &p_b) {
				return p_a.id < p_b.id;
			});
	geometry = std::move(p_segments);
	current_geometry_revision = p_new_revision;
	++current_world_revision;
	return ok_status();
}

Status VisionWorld2D::register_observer(const Observer &p_observer) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	status = validate_observer(p_observer);
	if (!status.ok()) {
		return status;
	}
	if (observers.size() >= MAX_OBSERVERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, observers.size());
	}
	ObserverRuntime runtime;
	runtime.definition = p_observer;
	if (!observers.emplace(p_observer.id, std::move(runtime)).second) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::INVALID_IDENTITY, p_observer.id.value);
	}
	++current_world_revision;
	return ok_status();
}

Status VisionWorld2D::update_observer(
		const Observer &p_observer, Revision p_expected_revision) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	status = validate_observer(p_observer);
	if (!status.ok()) {
		return status;
	}
	auto found = observers.find(p_observer.id);
	if (found == observers.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_observer.id.value);
	}
	if (found->second.definition.revision != p_expected_revision ||
			p_observer.revision != p_expected_revision + 1) {
		return make_status(StatusCode::REVISION_MISMATCH,
				DiagnosticId::OBSERVER_REVISION_STALE, p_expected_revision);
	}
	found->second.definition = p_observer;
	++current_world_revision;
	return ok_status();
}

Status VisionWorld2D::remove_observer(ObserverId p_observer) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	if (observers.erase(p_observer) == 0) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_observer.value);
	}
	++current_world_revision;
	return ok_status();
}

Status VisionWorld2D::register_target(const Target &p_target) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	status = validate_target(p_target);
	if (!status.ok()) {
		return status;
	}
	if (targets.size() >= MAX_TARGETS) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, targets.size());
	}
	if (!targets.emplace(p_target.id, p_target).second) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::INVALID_IDENTITY, p_target.id.value);
	}
	status = target_grid.insert(p_target.id, p_target.position);
	if (!status.ok()) {
		targets.erase(p_target.id);
		return status;
	}
	++current_world_revision;
	return ok_status();
}

Status VisionWorld2D::update_target(
		const Target &p_target, Revision p_expected_revision) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	status = validate_target(p_target);
	if (!status.ok()) {
		return status;
	}
	auto found = targets.find(p_target.id);
	if (found == targets.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_target.id.value);
	}
	if (found->second.revision != p_expected_revision ||
			p_target.revision != p_expected_revision + 1) {
		return make_status(StatusCode::REVISION_MISMATCH,
				DiagnosticId::TARGET_REVISION_STALE, p_expected_revision);
	}
	status = target_grid.update(p_target.id, p_target.position);
	if (!status.ok()) {
		return status;
	}
	found->second = p_target;
	++current_world_revision;
	return ok_status();
}

Status VisionWorld2D::remove_target(TargetId p_target) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	auto found = targets.find(p_target);
	if (found == targets.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_target.value);
	}
	target_grid.remove(p_target);
	targets.erase(found);
	for (auto &observer_entry : observers) {
		ObserverRuntime &runtime = observer_entry.second;
		auto disclosed = runtime.memory.find(p_target);
		if (disclosed == runtime.memory.end()) {
			continue;
		}
		VisibilityRecord tombstone = disclosed->second;
		tombstone.state = VisibilityState::UNKNOWN;
		tombstone.transition = VisibilityTransition::REMOVED;
		tombstone.last_known_position = {};
		tombstone.has_last_known_position = false;
		// Preserve only the last revision this observer was allowed to know;
		// removal must not disclose hidden canonical updates.
		runtime.pending_removals[p_target] = tombstone;
		runtime.memory.erase(disclosed);
	}
	++current_world_revision;
	return ok_status();
}

bool VisionWorld2D::in_range_and_cone(
		const Observer &p_observer, Vec2 p_point) const {
	const Wide dx = Wide(p_point.x) - Wide(p_observer.position.x);
	const Wide dy = Wide(p_point.y) - Wide(p_observer.position.y);
	const UWide distance_squared = UWide(dx * dx + dy * dy);
	const UWide range_squared =
			UWide(p_observer.range) * UWide(p_observer.range);
	if (distance_squared > range_squared) {
		return false;
	}
	if (p_observer.full_circle || distance_squared == 0) {
		return true;
	}
	const Wide dot =
			dx * Wide(p_observer.facing.x) +
			dy * Wide(p_observer.facing.y);
	if (dot <= 0) {
		return false;
	}
	const UWide facing_squared =
			UWide(Wide(p_observer.facing.x) * p_observer.facing.x +
					Wide(p_observer.facing.y) * p_observer.facing.y);
	const std::uint64_t distance = integer_sqrt(distance_squared);
	const std::uint64_t facing_length = integer_sqrt(facing_squared);
	const Wide lhs = dot * Wide(COORDINATE_SCALE);
	const Wide rhs = Wide(distance) * Wide(facing_length) *
			Wide(p_observer.cone_cos_million);
	return lhs >= rhs;
}

Status VisionWorld2D::estimate_work(const Observer &p_observer,
		std::uint64_t &r_estimate) const {
	std::vector<TargetId> candidates;
	Status status = target_grid.query_square(
			p_observer.position, p_observer.range, candidates);
	if (!status.ok()) {
		return status;
	}
	std::uint64_t estimate = candidates.size();
	for (TargetId id : candidates) {
		auto target = targets.find(id);
		if (target == targets.end() ||
				(target->second.mask & p_observer.target_mask) == 0) {
			continue;
		}
		const std::uint64_t samples = target->second.sample_offsets.size();
		const std::uint64_t segment_work = geometry.size();
		if (samples > 0 &&
				segment_work >
						(MAX_WORK_PER_TICK - estimate) / samples) {
			r_estimate = MAX_WORK_PER_TICK;
			return ok_status();
		}
		estimate += samples * segment_work;
	}
	r_estimate = std::min(estimate, MAX_WORK_PER_TICK);
	return ok_status();
}

Status VisionWorld2D::evaluate(const Observer &p_observer, Tick p_tick,
		std::map<TargetId, VisibilityRecord> &r_memory,
		std::map<TargetId, VisibilityRecord> &r_pending_removals,
		ObserverProjection &r_projection,
		std::uint64_t p_work_limit) const {
	r_projection = {};
	r_projection.observer = p_observer.id;
	r_projection.world_revision = current_world_revision;
	r_projection.geometry_revision = current_geometry_revision;
	r_projection.observer_revision = p_observer.revision;
	r_projection.completed_tick = p_tick;

	std::vector<TargetId> candidate_ids;
	Status status = target_grid.query_square(
			p_observer.position, p_observer.range, candidate_ids);
	if (!status.ok()) {
		return status;
	}
	if (r_pending_removals.size() > MAX_MEMORY_RECORDS_PER_OBSERVER) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				r_pending_removals.size());
	}
	std::map<TargetId, bool> currently_visible;
	for (TargetId id : candidate_ids) {
		auto target_it = targets.find(id);
		if (target_it == targets.end()) {
			continue;
		}
		const Target &target = target_it->second;
		if (r_projection.work_units >= p_work_limit) {
			return make_status(StatusCode::LIMIT_EXCEEDED,
					DiagnosticId::WORK_BUDGET_EXCEEDED, p_work_limit);
		}
		++r_projection.work_units;
		if ((target.mask & p_observer.target_mask) == 0 ||
				!in_range_and_cone(p_observer, target.position)) {
			currently_visible[id] = false;
			continue;
		}

		std::size_t clear_samples = 0;
		std::size_t checked_samples = 0;
		for (Vec2 offset : target.sample_offsets) {
			Vec2 sample;
			if (!checked_add(target.position.x, offset.x, sample.x) ||
					!checked_add(target.position.y, offset.y, sample.y) ||
					!validate_point(sample).ok()) {
				return make_status(StatusCode::ARITHMETIC_ERROR,
						DiagnosticId::COORDINATE_OVERFLOW, target.id.value);
			}
			std::uint64_t sample_work = 0;
			bool clear = false;
			status = is_clear_bounded(p_observer.position, sample, geometry,
					p_observer.occluder_mask,
					p_work_limit - r_projection.work_units, clear,
					nullptr, &sample_work);
			r_projection.work_units += sample_work;
			if (!status.ok()) {
				return make_status(StatusCode::LIMIT_EXCEEDED,
						DiagnosticId::WORK_BUDGET_EXCEEDED, p_work_limit);
			}
			++checked_samples;
			if (clear) {
				++clear_samples;
				if (target.sample_policy == SamplePolicy::ANY_SAMPLE) {
					break;
				}
			} else if (target.sample_policy == SamplePolicy::ALL_SAMPLES) {
				break;
			}
		}
		currently_visible[id] =
				target.sample_policy == SamplePolicy::ANY_SAMPLE ?
				clear_samples > 0 :
				clear_samples == target.sample_offsets.size() &&
						checked_samples == target.sample_offsets.size();
	}

	// Only identities already disclosed to this observer need a hidden-state
	// transition when they leave the broadphase. Iterating canonical targets
	// here would create recipient-visible records for actors the observer has
	// never discovered.
	for (const auto &memory_entry : r_memory) {
		currently_visible.emplace(memory_entry.first, false);
	}

	for (const auto &entry : currently_visible) {
		const TargetId id = entry.first;
		const bool visible_now = entry.second;
		auto target_it = targets.find(id);
		if (target_it == targets.end()) {
			continue;
		}
		const Target &target = target_it->second;
		auto existing = r_memory.find(id);
		if (!visible_now && existing == r_memory.end()) {
			// Masked, out-of-range, or occluded targets that have never been
			// visible are not part of this recipient's state at all.
			continue;
		}
		if (visible_now && existing == r_memory.end() &&
				r_memory.size() >= MAX_MEMORY_RECORDS_PER_OBSERVER -
						r_pending_removals.size()) {
			// Tombstones have priority: disclose them this query and defer a new
			// identity until the following query rather than exceeding the wire
			// record bound or losing a removal transition.
			continue;
		}
		VisibilityRecord &record = existing == r_memory.end()
				? r_memory[id]
				: existing->second;
		record.target = id;
		record.geometry_revision = current_geometry_revision;
		if (visible_now) {
			record.target_revision = target.revision;
			const bool was_visible = record.state == VisibilityState::VISIBLE;
			if (record.first_seen_tick == 0) {
				record.first_seen_tick = p_tick;
			}
			record.state = VisibilityState::VISIBLE;
			record.transition = was_visible ?
					VisibilityTransition::REMAINED_VISIBLE :
					VisibilityTransition::BECAME_VISIBLE;
			record.last_seen_tick = p_tick;
			record.last_known_position = target.position;
			record.has_last_known_position = true;
		} else if (record.state == VisibilityState::VISIBLE) {
			if (p_observer.memory_ticks > 0) {
				record.state = VisibilityState::REMEMBERED;
				record.transition = VisibilityTransition::BECAME_REMEMBERED;
			} else {
				record.state = VisibilityState::UNKNOWN;
				record.transition = VisibilityTransition::MEMORY_EXPIRED;
				record.last_known_position = {};
				record.has_last_known_position = false;
			}
		} else if (record.state == VisibilityState::REMEMBERED) {
			if (p_tick - record.last_seen_tick > p_observer.memory_ticks) {
				record.state = VisibilityState::UNKNOWN;
				record.transition = VisibilityTransition::MEMORY_EXPIRED;
				record.last_known_position = {};
				record.has_last_known_position = false;
			} else {
				record.transition = VisibilityTransition::REMAINED_REMEMBERED;
			}
		} else {
			record.transition = VisibilityTransition::NONE;
		}
	}

	if (r_memory.size() > MAX_MEMORY_RECORDS_PER_OBSERVER -
			r_pending_removals.size()) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				r_memory.size() + r_pending_removals.size());
	}

	// Merge active/memory records with one-shot removals in canonical target-id
	// order. UNKNOWN is never retained: MEMORY_EXPIRED is emitted once for an
	// already disclosed identity, then that identity is purged just like a
	// removal tombstone.
	std::map<TargetId, VisibilityRecord> projected_records;
	std::vector<TargetId> expired;
	for (const auto &entry : r_memory) {
		if (entry.second.state == VisibilityState::UNKNOWN &&
				entry.second.transition == VisibilityTransition::NONE) {
			expired.push_back(entry.first);
			continue;
		}
		projected_records[entry.first] = entry.second;
		if (entry.second.state == VisibilityState::UNKNOWN) {
			expired.push_back(entry.first);
		}
	}
	for (const auto &entry : r_pending_removals) {
		projected_records[entry.first] = entry.second;
	}
	for (const auto &entry : projected_records) {
		r_projection.records.push_back(entry.second);
	}
	for (TargetId id : expired) {
		r_memory.erase(id);
	}
	r_pending_removals.clear();
	return ok_status();
}

Status VisionWorld2D::query_observer(
		ObserverId p_observer, Tick p_tick, ObserverProjection &r_projection) {
	return query_observer_with_budget(
			p_observer, p_tick, MAX_WORK_PER_TICK, r_projection);
}

Status VisionWorld2D::query_observer_with_budget(ObserverId p_observer,
		Tick p_tick, std::uint64_t p_work_limit,
		ObserverProjection &r_projection) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	if (p_work_limit > MAX_WORK_PER_TICK) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::WORK_BUDGET_EXCEEDED, p_work_limit);
	}
	auto found = observers.find(p_observer);
	if (found == observers.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_observer.value);
	}
	if (found->second.result_revision != 0 &&
			p_tick < found->second.last_completed_tick) {
		return make_status(StatusCode::REVISION_MISMATCH,
				DiagnosticId::WORLD_REVISION_STALE, p_tick);
	}
	std::map<TargetId, VisibilityRecord> next_memory = found->second.memory;
	std::map<TargetId, VisibilityRecord> next_removals =
			found->second.pending_removals;
	status = evaluate(found->second.definition, p_tick, next_memory,
			next_removals, r_projection, p_work_limit);
	if (!status.ok()) {
		return status;
	}
	found->second.memory = std::move(next_memory);
	found->second.pending_removals = std::move(next_removals);
	found->second.last_completed_tick = p_tick;
	++found->second.result_revision;
	r_projection.result_revision = found->second.result_revision;
	found->second.latest = r_projection;
	return ok_status();
}

Status VisionWorld2D::advance(
		Tick p_tick, std::uint64_t p_work_budget, WorkMetrics &r_metrics) {
	Status status = require_authority();
	if (!status.ok()) {
		return status;
	}
	if (p_work_budget > MAX_WORK_PER_TICK) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::WORK_BUDGET_EXCEEDED, p_work_budget);
	}
	r_metrics = {};
	std::vector<ObserverId> order;
	order.reserve(observers.size());
	for (const auto &entry : observers) {
		order.push_back(entry.first);
	}
	std::sort(order.begin(), order.end(), [this](ObserverId p_a, ObserverId p_b) {
		const ObserverRuntime &a = observers.at(p_a);
		const ObserverRuntime &b = observers.at(p_b);
		return std::make_tuple(!a.definition.urgent, a.last_completed_tick,
					   -std::int64_t(a.definition.priority), p_a.value) <
				std::make_tuple(!b.definition.urgent, b.last_completed_tick,
						-std::int64_t(b.definition.priority), p_b.value);
	});

	for (ObserverId id : order) {
		ObserverRuntime &runtime = observers.at(id);
		std::uint64_t estimate = 0;
		status = estimate_work(runtime.definition, estimate);
		if (!status.ok()) {
			return status;
		}
		r_metrics.requested += estimate;
		if (estimate > p_work_budget - r_metrics.consumed) {
			++r_metrics.deferred;
			continue;
		}
		ObserverProjection projection_result;
		status = query_observer_with_budget(id, p_tick,
				p_work_budget - r_metrics.consumed, projection_result);
		if (!status.ok()) {
			if (status.code == StatusCode::LIMIT_EXCEEDED &&
					status.diagnostic == DiagnosticId::WORK_BUDGET_EXCEEDED) {
				r_metrics.consumed += projection_result.work_units;
				++r_metrics.deferred;
				continue;
			}
			return status;
		}
		r_metrics.consumed += projection_result.work_units;
		++r_metrics.completed;
	}
	return ok_status();
}

const ObserverProjection *VisionWorld2D::projection(
		ObserverId p_observer) const {
	auto found = observers.find(p_observer);
	if (found == observers.end() || found->second.result_revision == 0) {
		return nullptr;
	}
	return &found->second.latest;
}

VisibilityState VisionWorld2D::visibility(
		ObserverId p_observer, TargetId p_target) const {
	auto observer = observers.find(p_observer);
	if (observer == observers.end()) {
		return VisibilityState::UNKNOWN;
	}
	auto record = observer->second.memory.find(p_target);
	return record == observer->second.memory.end() ?
			VisibilityState::UNKNOWN :
			record->second.state;
}

} // namespace cv
