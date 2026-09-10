#ifndef COMMON_VISION_CORE_WORLD_H
#define COMMON_VISION_CORE_WORLD_H

#include "core/cv_geometry.h"
#include "core/cv_ids.h"
#include "core/cv_spatial_grid.h"
#include "core/cv_status.h"

#include <cstdint>
#include <map>
#include <vector>

namespace cv {

enum class WorldRole : std::uint8_t {
	OFFLINE_AUTHORITY = 0,
	SERVER_AUTHORITY = 1,
	REPLICA = 2,
};

enum class SamplePolicy : std::uint8_t {
	ANY_SAMPLE = 0,
	ALL_SAMPLES = 1,
};

enum class VisibilityState : std::uint8_t {
	UNKNOWN = 0,
	REMEMBERED = 1,
	VISIBLE = 2,
};

enum class VisibilityTransition : std::uint8_t {
	NONE = 0,
	BECAME_VISIBLE = 1,
	REMAINED_VISIBLE = 2,
	BECAME_REMEMBERED = 3,
	REMAINED_REMEMBERED = 4,
	MEMORY_EXPIRED = 5,
	REMOVED = 6,
};

struct Observer {
	ObserverId id;
	Vec2 position;
	// Facing is a fixed vector, normally scaled to COORDINATE_SCALE.
	Vec2 facing{ 1000000, 0 };
	std::int64_t range = 10000000;
	// Cosine of the half-angle in millionths. Ignored for full_circle.
	std::int32_t cone_cos_million = 0;
	bool full_circle = false;
	std::uint32_t target_mask = UINT32_MAX;
	std::uint32_t occluder_mask = UINT32_MAX;
	Tick memory_ticks = 0;
	std::int32_t priority = 0;
	bool urgent = false;
	Revision revision = 1;
};

struct Target {
	TargetId id;
	Vec2 position;
	std::uint32_t mask = 1;
	SamplePolicy sample_policy = SamplePolicy::ANY_SAMPLE;
	std::vector<Vec2> sample_offsets{ Vec2{} };
	Revision revision = 1;
};

struct VisibilityRecord {
	TargetId target;
	VisibilityState state = VisibilityState::UNKNOWN;
	VisibilityTransition transition = VisibilityTransition::NONE;
	Tick first_seen_tick = 0;
	Tick last_seen_tick = 0;
	Vec2 last_known_position;
	bool has_last_known_position = false;
	Revision geometry_revision = 0;
	Revision target_revision = 0;

	bool operator==(const VisibilityRecord &p_other) const {
		return target == p_other.target && state == p_other.state &&
				transition == p_other.transition &&
				first_seen_tick == p_other.first_seen_tick &&
				last_seen_tick == p_other.last_seen_tick &&
				last_known_position == p_other.last_known_position &&
				has_last_known_position == p_other.has_last_known_position &&
				geometry_revision == p_other.geometry_revision &&
				target_revision == p_other.target_revision;
	}
};

struct ObserverProjection {
	ObserverId observer;
	Revision world_revision = 0;
	Revision geometry_revision = 0;
	Revision observer_revision = 0;
	Revision result_revision = 0;
	Tick completed_tick = 0;
	std::vector<VisibilityRecord> records;
	std::uint64_t work_units = 0;
};

struct WorkMetrics {
	std::uint64_t requested = 0;
	std::uint64_t consumed = 0;
	std::uint64_t completed = 0;
	std::uint64_t invalidated = 0;
	std::uint64_t deferred = 0;
};

class VisionWorld2D {
public:
	explicit VisionWorld2D(WorldId p_id,
			WorldRole p_role = WorldRole::SERVER_AUTHORITY,
			std::int64_t p_spatial_cell_size = 8000000,
			std::uint64_t p_max_visited_cells = MAX_VISITED_CELLS_PER_QUERY);

	WorldId id() const { return world_id; }
	WorldRole role() const { return world_role; }
	Revision world_revision() const { return current_world_revision; }
	Revision geometry_revision() const { return current_geometry_revision; }

	Status replace_geometry(
			std::vector<Segment> p_segments, Revision p_new_revision);

	Status register_observer(const Observer &p_observer);
	Status update_observer(const Observer &p_observer,
			Revision p_expected_revision);
	Status remove_observer(ObserverId p_observer);

	Status register_target(const Target &p_target);
	Status update_target(const Target &p_target, Revision p_expected_revision);
	Status remove_target(TargetId p_target);

	Status query_observer(
			ObserverId p_observer, Tick p_tick, ObserverProjection &r_projection);
	Status advance(Tick p_tick, std::uint64_t p_work_budget,
			WorkMetrics &r_metrics);

	const ObserverProjection *projection(ObserverId p_observer) const;
	VisibilityState visibility(
			ObserverId p_observer, TargetId p_target) const;

	std::size_t observer_count() const { return observers.size(); }
	std::size_t target_count() const { return targets.size(); }

private:
	struct ObserverRuntime {
		Observer definition;
		Tick last_completed_tick = 0;
		Revision result_revision = 0;
		// Contains only identities already disclosed to this observer. A target
		// that has never been visible must never acquire a record here.
		std::map<TargetId, VisibilityRecord> memory;
		// Previously disclosed targets removed from canonical state. Emitted in
		// target-id order by the next successful query, then cleared atomically.
		std::map<TargetId, VisibilityRecord> pending_removals;
		ObserverProjection latest;
	};

	WorldId world_id;
	WorldRole world_role = WorldRole::SERVER_AUTHORITY;
	Revision current_world_revision = 1;
	Revision current_geometry_revision = 0;
	std::vector<Segment> geometry;
	std::map<ObserverId, ObserverRuntime> observers;
	std::map<TargetId, Target> targets;
	TargetSpatialGrid target_grid;

	Status require_authority() const;
	Status validate_observer(const Observer &p_observer) const;
	Status validate_target(const Target &p_target) const;
	bool in_range_and_cone(const Observer &p_observer, Vec2 p_point) const;
	Status estimate_work(const Observer &p_observer,
			std::uint64_t &r_estimate) const;
	Status evaluate(const Observer &p_observer, Tick p_tick,
			std::map<TargetId, VisibilityRecord> &r_memory,
			std::map<TargetId, VisibilityRecord> &r_pending_removals,
			ObserverProjection &r_projection,
			std::uint64_t p_work_limit) const;
	Status query_observer_with_budget(ObserverId p_observer, Tick p_tick,
			std::uint64_t p_work_limit,
			ObserverProjection &r_projection);
};

} // namespace cv

#endif // COMMON_VISION_CORE_WORLD_H
