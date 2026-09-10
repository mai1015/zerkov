#ifndef COMMON_VISION_CORE_SPATIAL_GRID_H
#define COMMON_VISION_CORE_SPATIAL_GRID_H

#include "core/cv_geometry.h"
#include "core/cv_ids.h"
#include "core/cv_limits.h"
#include "core/cv_status.h"

#include <cstdint>
#include <map>
#include <utility>
#include <vector>

namespace cv {

// Deterministic broadphase keyed by fixed-size canonical cells. Buckets and
// returned identities are stable-sorted; hash iteration never affects results.
class TargetSpatialGrid {
public:
	explicit TargetSpatialGrid(std::int64_t p_cell_size,
			std::uint64_t p_max_visited_cells = MAX_VISITED_CELLS_PER_QUERY);

	Status insert(TargetId p_target, Vec2 p_position);
	Status update(TargetId p_target, Vec2 p_position);
	Status remove(TargetId p_target);
	void clear();

	// Validates the complete cell rectangle with wide intermediates before any
	// bucket is visited. The output is replaced only on success.
	Status query_square(Vec2 p_center, std::int64_t p_radius,
			std::vector<TargetId> &r_targets) const;
	// Source/binary-compatible convenience retained for 0.1 callers. A bounded
	// query failure is represented by an empty result; authority code uses the
	// status-returning overload above so it can propagate the diagnostic.
	std::vector<TargetId> query_square(
			Vec2 p_center, std::int64_t p_radius) const;
	Status validate_query(Vec2 p_center, std::int64_t p_radius) const;
	std::size_t size() const { return positions.size(); }
	std::int64_t cell_size() const { return grid_cell_size; }
	std::uint64_t max_visited_cells() const { return visited_cell_limit; }

private:
	using CellKey = std::pair<std::int64_t, std::int64_t>;

	std::int64_t grid_cell_size = 1;
	std::uint64_t visited_cell_limit = MAX_VISITED_CELLS_PER_QUERY;
	std::map<TargetId, Vec2> positions;
	std::map<CellKey, std::vector<TargetId>> buckets;

	std::int64_t coordinate_to_cell(std::int64_t p_coordinate) const;
	Status query_bounds(Vec2 p_center, std::int64_t p_radius,
			std::int64_t &r_min_x, std::int64_t &r_max_x,
			std::int64_t &r_min_y, std::int64_t &r_max_y) const;
	CellKey key_for(Vec2 p_position) const;
	void add_to_bucket(CellKey p_key, TargetId p_target);
	void remove_from_bucket(CellKey p_key, TargetId p_target);
};

} // namespace cv

#endif // COMMON_VISION_CORE_SPATIAL_GRID_H
