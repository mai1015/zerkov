#include "core/cv_geometry.h"

#include "core/cv_limits.h"

#include <algorithm>
#include <cstdlib>
#include <limits>
#include <map>
#include <set>

namespace cv {
namespace {

using Wide = __int128_t;

int sign(Wide p_value) {
	return (p_value > 0) - (p_value < 0);
}

Wide orient(Vec2 p_a, Vec2 p_b, Vec2 p_c) {
	return Wide(p_b.x - p_a.x) * Wide(p_c.y - p_a.y) -
			Wide(p_b.y - p_a.y) * Wide(p_c.x - p_a.x);
}

bool between(std::int64_t p_value, std::int64_t p_a, std::int64_t p_b) {
	return p_value >= std::min(p_a, p_b) && p_value <= std::max(p_a, p_b);
}

bool point_on_segment(Vec2 p_point, Vec2 p_a, Vec2 p_b) {
	return orient(p_a, p_b, p_point) == 0 &&
			between(p_point.x, p_a.x, p_b.x) &&
			between(p_point.y, p_a.y, p_b.y);
}

bool opposite(int p_a, int p_b) {
	return (p_a < 0 && p_b > 0) || (p_a > 0 && p_b < 0);
}

struct Edge {
	Vec2 a;
	Vec2 b;

	Edge(Vec2 p_a, Vec2 p_b) : a(p_a), b(p_b) {
		if (b < a) {
			std::swap(a, b);
		}
	}

	bool operator<(const Edge &p_other) const {
		return a < p_other.a || (!(p_other.a < a) && b < p_other.b);
	}
};

bool checked_mul(std::int64_t p_a, std::int64_t p_b, std::int64_t &r_value) {
	const Wide value = Wide(p_a) * Wide(p_b);
	if (value < std::numeric_limits<std::int64_t>::min() ||
			value > std::numeric_limits<std::int64_t>::max()) {
		return false;
	}
	r_value = static_cast<std::int64_t>(value);
	return true;
}

} // namespace

Status validate_point(Vec2 p_point) {
	if (p_point.x < -MAX_ABS_COORDINATE ||
			p_point.x > MAX_ABS_COORDINATE ||
			p_point.y < -MAX_ABS_COORDINATE ||
			p_point.y > MAX_ABS_COORDINATE) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::COORDINATE_OUT_OF_RANGE);
	}
	return ok_status();
}

Status validate_segment(const Segment &p_segment) {
	if (!p_segment.id) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_IDENTITY);
	}
	Status status = validate_point(p_segment.a);
	if (!status.ok()) {
		return status;
	}
	status = validate_point(p_segment.b);
	if (!status.ok()) {
		return status;
	}
	if (p_segment.a == p_segment.b) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::ZERO_LENGTH_SEGMENT, p_segment.id.value);
	}
	if (p_segment.mask == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_MASK, p_segment.id.value);
	}
	// Algorithm contract v1 supports two-sided blockers only. Keep the field
	// in the canonical record for forward-compatible codecs, but fail closed
	// instead of silently treating a one-sided authored wall as two-sided.
	if (!p_segment.two_sided) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_ENUM, p_segment.id.value);
	}
	return ok_status();
}

Status validate_segments(const std::vector<Segment> &p_segments) {
	if (p_segments.size() > MAX_OCCLUDER_SEGMENTS) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, p_segments.size());
	}
	std::set<std::uint64_t> identities;
	for (const Segment &segment : p_segments) {
		Status status = validate_segment(segment);
		if (!status.ok()) {
			return status;
		}
		if (!identities.insert(segment.id.value).second) {
			return make_status(StatusCode::ALREADY_EXISTS,
					DiagnosticId::DUPLICATE_SEGMENT, segment.id.value);
		}
	}
	return ok_status();
}

IntersectionKind classify_sight_intersection(
		Vec2 p_origin, Vec2 p_target, const Segment &p_occluder) {
	if (p_origin == p_target) {
		return IntersectionKind::NONE;
	}

	const Vec2 a = p_occluder.a;
	const Vec2 b = p_occluder.b;

	// The target-on-wall rule is stronger than the generic endpoint-touch rule.
	if (point_on_segment(p_target, a, b)) {
		return IntersectionKind::TARGET_ON_OCCLUDER;
	}

	const int o1 = sign(orient(p_origin, p_target, a));
	const int o2 = sign(orient(p_origin, p_target, b));
	const int o3 = sign(orient(a, b, p_origin));
	const int o4 = sign(orient(a, b, p_target));

	if (opposite(o1, o2) && opposite(o3, o4)) {
		return IntersectionKind::PROPER_CROSSING;
	}

	// Collinear rays block only when they overlap for positive length. A lone
	// shared origin is exempt.
	if (o1 == 0 && o2 == 0) {
		const bool use_x =
				std::llabs(p_target.x - p_origin.x) >=
				std::llabs(p_target.y - p_origin.y);
		const std::int64_t ray_min = use_x ?
				std::min(p_origin.x, p_target.x) :
				std::min(p_origin.y, p_target.y);
		const std::int64_t ray_max = use_x ?
				std::max(p_origin.x, p_target.x) :
				std::max(p_origin.y, p_target.y);
		const std::int64_t wall_min =
				use_x ? std::min(a.x, b.x) : std::min(a.y, b.y);
		const std::int64_t wall_max =
				use_x ? std::max(a.x, b.x) : std::max(a.y, b.y);
		const std::int64_t overlap_min = std::max(ray_min, wall_min);
		const std::int64_t overlap_max = std::min(ray_max, wall_max);
		if (overlap_max > overlap_min) {
			return IntersectionKind::COLLINEAR_OVERLAP;
		}
		if (point_on_segment(p_origin, a, b)) {
			return IntersectionKind::ORIGIN_TOUCH;
		}
		return IntersectionKind::ENDPOINT_TOUCH;
	}

	const bool origin_on_wall = point_on_segment(p_origin, a, b);
	if (origin_on_wall) {
		return IntersectionKind::ORIGIN_TOUCH;
	}

	// One occluder endpoint touching the ray has zero measure and is clear by
	// contract. This includes lattice corners composed from multiple segments.
	if ((o1 == 0 && point_on_segment(a, p_origin, p_target)) ||
			(o2 == 0 && point_on_segment(b, p_origin, p_target))) {
		return IntersectionKind::ENDPOINT_TOUCH;
	}

	return IntersectionKind::NONE;
}

bool segment_blocks_sight(
		Vec2 p_origin, Vec2 p_target, const Segment &p_occluder) {
	const IntersectionKind kind =
			classify_sight_intersection(p_origin, p_target, p_occluder);
	return kind == IntersectionKind::PROPER_CROSSING ||
			kind == IntersectionKind::COLLINEAR_OVERLAP ||
			kind == IntersectionKind::TARGET_ON_OCCLUDER;
}

bool is_clear(Vec2 p_origin, Vec2 p_target,
		const std::vector<Segment> &p_occluders,
		std::uint32_t p_occluder_mask,
		SegmentId *r_first_blocker,
		std::uint64_t *r_work_units) {
	bool clear = false;
	const Status status = is_clear_bounded(p_origin, p_target, p_occluders,
			p_occluder_mask, UINT64_MAX, clear, r_first_blocker, r_work_units);
	return status.ok() && clear;
}

Status is_clear_bounded(Vec2 p_origin, Vec2 p_target,
		const std::vector<Segment> &p_occluders,
		std::uint32_t p_occluder_mask, std::uint64_t p_work_limit,
		bool &r_is_clear, SegmentId *r_first_blocker,
		std::uint64_t *r_work_units) {
	r_is_clear = false;
	if (r_first_blocker != nullptr) {
		*r_first_blocker = {};
	}
	std::uint64_t work_units = 0;
	for (const Segment &segment : p_occluders) {
		if ((segment.mask & p_occluder_mask) == 0) {
			continue;
		}
		if (work_units >= p_work_limit) {
			if (r_work_units != nullptr) {
				*r_work_units = work_units;
			}
			return make_status(StatusCode::LIMIT_EXCEEDED,
					DiagnosticId::WORK_BUDGET_EXCEEDED, p_work_limit);
		}
		++work_units;
		if (segment_blocks_sight(p_origin, p_target, segment)) {
			if (r_first_blocker != nullptr) {
				*r_first_blocker = segment.id;
			}
			if (r_work_units != nullptr) {
				*r_work_units = work_units;
			}
			return ok_status();
		}
	}
	if (r_work_units != nullptr) {
		*r_work_units = work_units;
	}
	r_is_clear = true;
	return ok_status();
}

Status extract_cell_boundaries(const std::vector<Cell> &p_cells,
		std::int64_t p_cell_size, SegmentId p_first_id,
		std::uint32_t p_mask, std::vector<Segment> &r_segments) {
	if (p_cell_size <= 0 || !p_first_id || p_mask == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				p_cell_size <= 0 ? DiagnosticId::COORDINATE_OUT_OF_RANGE :
									  (!p_first_id ? DiagnosticId::INVALID_IDENTITY :
														   DiagnosticId::INVALID_MASK));
	}
	if (p_cells.size() > MAX_OCCLUDER_SEGMENTS / 2) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, p_cells.size());
	}

	std::set<Cell> unique_cells;
	for (const Cell &cell : p_cells) {
		if (!unique_cells.insert(cell).second) {
			continue;
		}
	}

	std::map<Edge, bool> exposed;
	for (const Cell &cell : unique_cells) {
		std::int64_t x0 = 0;
		std::int64_t y0 = 0;
		std::int64_t x1 = 0;
		std::int64_t y1 = 0;
		if (!checked_mul(cell.x, p_cell_size, x0) ||
				!checked_mul(cell.y, p_cell_size, y0) ||
				!checked_mul(cell.x + 1, p_cell_size, x1) ||
				!checked_mul(cell.y + 1, p_cell_size, y1)) {
			return make_status(StatusCode::ARITHMETIC_ERROR,
					DiagnosticId::COORDINATE_OVERFLOW);
		}
		for (const Vec2 point : {
					 Vec2{ x0, y0 }, Vec2{ x1, y0 },
					 Vec2{ x1, y1 }, Vec2{ x0, y1 } }) {
			Status status = validate_point(point);
			if (!status.ok()) {
				return status;
			}
		}
		const Edge edges[] = {
			Edge({ x0, y0 }, { x1, y0 }),
			Edge({ x1, y0 }, { x1, y1 }),
			Edge({ x1, y1 }, { x0, y1 }),
			Edge({ x0, y1 }, { x0, y0 }),
		};
		for (const Edge &edge : edges) {
			auto found = exposed.find(edge);
			if (found == exposed.end()) {
				exposed.emplace(edge, true);
			} else {
				found->second = !found->second;
			}
		}
	}

	std::vector<Segment> output;
	output.reserve(exposed.size());
	std::uint64_t next_id = p_first_id.value;
	for (const auto &entry : exposed) {
		if (!entry.second) {
			continue;
		}
		if (next_id == 0) {
			return make_status(StatusCode::ARITHMETIC_ERROR,
					DiagnosticId::COORDINATE_OVERFLOW);
		}
		output.push_back({
			SegmentId{ next_id },
			entry.first.a,
			entry.first.b,
			p_mask,
			true,
		});
		if (next_id == UINT64_MAX && output.size() < exposed.size()) {
			return make_status(StatusCode::ARITHMETIC_ERROR,
					DiagnosticId::COORDINATE_OVERFLOW);
		}
		++next_id;
	}
	Status status = validate_segments(output);
	if (!status.ok()) {
		return status;
	}
	r_segments = std::move(output);
	return ok_status();
}

} // namespace cv
