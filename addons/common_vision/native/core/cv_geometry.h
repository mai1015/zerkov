#ifndef COMMON_VISION_CORE_GEOMETRY_H
#define COMMON_VISION_CORE_GEOMETRY_H

#include "core/cv_ids.h"
#include "core/cv_status.h"

#include <cstdint>
#include <vector>

namespace cv {

struct Vec2 {
	std::int64_t x = 0;
	std::int64_t y = 0;

	bool operator==(const Vec2 &p_other) const {
		return x == p_other.x && y == p_other.y;
	}
	bool operator!=(const Vec2 &p_other) const { return !(*this == p_other); }
	bool operator<(const Vec2 &p_other) const {
		return x < p_other.x || (x == p_other.x && y < p_other.y);
	}
};

struct Cell {
	std::int64_t x = 0;
	std::int64_t y = 0;

	bool operator==(const Cell &p_other) const {
		return x == p_other.x && y == p_other.y;
	}
	bool operator<(const Cell &p_other) const {
		return x < p_other.x || (x == p_other.x && y < p_other.y);
	}
};

struct Segment {
	SegmentId id;
	Vec2 a;
	Vec2 b;
	std::uint32_t mask = 1;
	bool two_sided = true;

	bool operator==(const Segment &p_other) const {
		return id == p_other.id && a == p_other.a && b == p_other.b &&
				mask == p_other.mask && two_sided == p_other.two_sided;
	}
};

enum class IntersectionKind : std::uint8_t {
	NONE = 0,
	ENDPOINT_TOUCH = 1,
	PROPER_CROSSING = 2,
	COLLINEAR_OVERLAP = 3,
	TARGET_ON_OCCLUDER = 4,
	ORIGIN_TOUCH = 5,
};

Status validate_point(Vec2 p_point);
Status validate_segment(const Segment &p_segment);
Status validate_segments(const std::vector<Segment> &p_segments);

// Implements the contract documented in docs/vision/contracts.md. An isolated
// occluder endpoint touch is clear, positive-length overlap and proper
// crossings block, the observer origin is exempt, and a target point on an
// occluder is blocked.
IntersectionKind classify_sight_intersection(
		Vec2 p_origin, Vec2 p_target, const Segment &p_occluder);

bool segment_blocks_sight(
		Vec2 p_origin, Vec2 p_target, const Segment &p_occluder);

bool is_clear(Vec2 p_origin, Vec2 p_target,
		const std::vector<Segment> &p_occluders,
		std::uint32_t p_occluder_mask = UINT32_MAX,
		SegmentId *r_first_blocker = nullptr,
		std::uint64_t *r_work_units = nullptr);

// Budget-aware form used by authority queries. Each mask-eligible segment test
// consumes one unit. It stops before exceeding p_work_limit and leaves clear
// in r_is_clear only when evaluation completes.
Status is_clear_bounded(Vec2 p_origin, Vec2 p_target,
		const std::vector<Segment> &p_occluders,
		std::uint32_t p_occluder_mask, std::uint64_t p_work_limit,
		bool &r_is_clear, SegmentId *r_first_blocker = nullptr,
		std::uint64_t *r_work_units = nullptr);

// Convert filled cells to exposed, canonical, axis-aligned boundary segments.
// Shared internal edges cancel. Output ids are assigned from p_first_id in
// canonical endpoint order.
Status extract_cell_boundaries(const std::vector<Cell> &p_cells,
		std::int64_t p_cell_size, SegmentId p_first_id,
		std::uint32_t p_mask, std::vector<Segment> &r_segments);

} // namespace cv

#endif // COMMON_VISION_CORE_GEOMETRY_H
