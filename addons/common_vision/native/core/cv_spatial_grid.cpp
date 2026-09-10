#include "core/cv_spatial_grid.h"

#include "core/cv_limits.h"

#include <algorithm>
#include <limits>
#include <set>
#include <utility>

namespace cv {

TargetSpatialGrid::TargetSpatialGrid(std::int64_t p_cell_size,
		std::uint64_t p_max_visited_cells) :
		grid_cell_size(p_cell_size),
		visited_cell_limit(p_max_visited_cells) {}

std::int64_t TargetSpatialGrid::coordinate_to_cell(
		std::int64_t p_coordinate) const {
	std::int64_t quotient = p_coordinate / grid_cell_size;
	const std::int64_t remainder = p_coordinate % grid_cell_size;
	if (remainder < 0) {
		--quotient;
	}
	return quotient;
}

TargetSpatialGrid::CellKey TargetSpatialGrid::key_for(Vec2 p_position) const {
	return { coordinate_to_cell(p_position.x),
		coordinate_to_cell(p_position.y) };
}

void TargetSpatialGrid::add_to_bucket(CellKey p_key, TargetId p_target) {
	std::vector<TargetId> &bucket = buckets[p_key];
	auto insertion = std::lower_bound(bucket.begin(), bucket.end(), p_target);
	bucket.insert(insertion, p_target);
}

void TargetSpatialGrid::remove_from_bucket(CellKey p_key, TargetId p_target) {
	auto found = buckets.find(p_key);
	if (found == buckets.end()) {
		return;
	}
	std::vector<TargetId> &bucket = found->second;
	auto target = std::lower_bound(bucket.begin(), bucket.end(), p_target);
	if (target != bucket.end() && *target == p_target) {
		bucket.erase(target);
	}
	if (bucket.empty()) {
		buckets.erase(found);
	}
}

Status TargetSpatialGrid::insert(TargetId p_target, Vec2 p_position) {
	if (grid_cell_size <= 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::COORDINATE_OUT_OF_RANGE);
	}
	if (visited_cell_limit == 0 ||
			visited_cell_limit > MAX_VISITED_CELLS_PER_QUERY) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, visited_cell_limit);
	}
	if (!p_target) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_IDENTITY);
	}
	Status status = validate_point(p_position);
	if (!status.ok()) {
		return status;
	}
	if (positions.size() >= MAX_TARGETS) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, positions.size());
	}
	if (!positions.emplace(p_target, p_position).second) {
		return make_status(StatusCode::ALREADY_EXISTS,
				DiagnosticId::INVALID_IDENTITY, p_target.value);
	}
	add_to_bucket(key_for(p_position), p_target);
	return ok_status();
}

Status TargetSpatialGrid::update(TargetId p_target, Vec2 p_position) {
	if (grid_cell_size <= 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::COORDINATE_OUT_OF_RANGE);
	}
	if (visited_cell_limit == 0 ||
			visited_cell_limit > MAX_VISITED_CELLS_PER_QUERY) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, visited_cell_limit);
	}
	Status status = validate_point(p_position);
	if (!status.ok()) {
		return status;
	}
	auto found = positions.find(p_target);
	if (found == positions.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_target.value);
	}
	const CellKey old_key = key_for(found->second);
	const CellKey new_key = key_for(p_position);
	found->second = p_position;
	if (old_key != new_key) {
		remove_from_bucket(old_key, p_target);
		add_to_bucket(new_key, p_target);
	}
	return ok_status();
}

Status TargetSpatialGrid::remove(TargetId p_target) {
	if (grid_cell_size <= 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::COORDINATE_OUT_OF_RANGE);
	}
	if (visited_cell_limit == 0 ||
			visited_cell_limit > MAX_VISITED_CELLS_PER_QUERY) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, visited_cell_limit);
	}
	auto found = positions.find(p_target);
	if (found == positions.end()) {
		return make_status(StatusCode::NOT_FOUND,
				DiagnosticId::INVALID_IDENTITY, p_target.value);
	}
	remove_from_bucket(key_for(found->second), p_target);
	positions.erase(found);
	return ok_status();
}

void TargetSpatialGrid::clear() {
	positions.clear();
	buckets.clear();
}

Status TargetSpatialGrid::query_bounds(Vec2 p_center, std::int64_t p_radius,
		std::int64_t &r_min_x, std::int64_t &r_max_x,
		std::int64_t &r_min_y, std::int64_t &r_max_y) const {
	if (grid_cell_size <= 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::COORDINATE_OUT_OF_RANGE);
	}
	if (visited_cell_limit == 0 ||
			visited_cell_limit > MAX_VISITED_CELLS_PER_QUERY) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, visited_cell_limit);
	}
	Status status = validate_point(p_center);
	if (!status.ok()) {
		return status;
	}
	if (p_radius < 0 || p_radius > MAX_ABS_COORDINATE) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::NON_POSITIVE_RANGE);
	}

	using Wide = __int128_t;
	const Wide min_world_x = Wide(p_center.x) - Wide(p_radius);
	const Wide max_world_x = Wide(p_center.x) + Wide(p_radius);
	const Wide min_world_y = Wide(p_center.y) - Wide(p_radius);
	const Wide max_world_y = Wide(p_center.y) + Wide(p_radius);
	if (min_world_x < std::numeric_limits<std::int64_t>::min() ||
			max_world_x > std::numeric_limits<std::int64_t>::max() ||
			min_world_y < std::numeric_limits<std::int64_t>::min() ||
			max_world_y > std::numeric_limits<std::int64_t>::max()) {
		return make_status(StatusCode::ARITHMETIC_ERROR,
				DiagnosticId::COORDINATE_OVERFLOW);
	}

	r_min_x = coordinate_to_cell(static_cast<std::int64_t>(min_world_x));
	r_max_x = coordinate_to_cell(static_cast<std::int64_t>(max_world_x));
	r_min_y = coordinate_to_cell(static_cast<std::int64_t>(min_world_y));
	r_max_y = coordinate_to_cell(static_cast<std::int64_t>(max_world_y));

	const Wide width = Wide(r_max_x) - Wide(r_min_x) + 1;
	const Wide height = Wide(r_max_y) - Wide(r_min_y) + 1;
	const Wide limit = Wide(visited_cell_limit);
	if (width <= 0 || height <= 0 || width > limit || height > limit ||
			width > limit / height) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, visited_cell_limit);
	}
	return ok_status();
}

Status TargetSpatialGrid::validate_query(
		Vec2 p_center, std::int64_t p_radius) const {
	std::int64_t min_x = 0;
	std::int64_t max_x = 0;
	std::int64_t min_y = 0;
	std::int64_t max_y = 0;
	return query_bounds(p_center, p_radius, min_x, max_x, min_y, max_y);
}

Status TargetSpatialGrid::query_square(Vec2 p_center, std::int64_t p_radius,
		std::vector<TargetId> &r_targets) const {
	std::int64_t min_x = 0;
	std::int64_t max_x = 0;
	std::int64_t min_y = 0;
	std::int64_t max_y = 0;
	Status status = query_bounds(
			p_center, p_radius, min_x, max_x, min_y, max_y);
	if (!status.ok()) {
		return status;
	}

	std::vector<TargetId> result;
	std::uint64_t visited = 0;
	for (std::int64_t y = min_y;; ++y) {
		for (std::int64_t x = min_x;; ++x) {
			if (visited >= visited_cell_limit) {
				return make_status(StatusCode::LIMIT_EXCEEDED,
						DiagnosticId::COUNT_LIMIT_EXCEEDED, visited);
			}
			++visited;
			auto found = buckets.find({ x, y });
			if (found != buckets.end()) {
				result.insert(
						result.end(), found->second.begin(), found->second.end());
			}
			if (x == max_x) {
				break;
			}
		}
		if (y == max_y) {
			break;
		}
	}
	std::sort(result.begin(), result.end());
	result.erase(std::unique(result.begin(), result.end()), result.end());
	r_targets = std::move(result);
	return ok_status();
}

std::vector<TargetId> TargetSpatialGrid::query_square(
		Vec2 p_center, std::int64_t p_radius) const {
	std::vector<TargetId> result;
	query_square(p_center, p_radius, result);
	return result;
}

} // namespace cv
