#include "core/inv_placement.h"

namespace inv {

GridRect effective_footprint(
		std::uint32_t p_x,
		std::uint32_t p_y,
		std::uint32_t p_base_width,
		std::uint32_t p_base_height,
		bool p_rotated) {
	GridRect rect;
	rect.x = p_x;
	rect.y = p_y;
	rect.width = p_rotated ? p_base_height : p_base_width;
	rect.height = p_rotated ? p_base_width : p_base_height;
	return rect;
}

bool grid_rect_in_bounds(const GridRect &p_rect, std::uint32_t p_grid_width, std::uint32_t p_grid_height) {
	if (p_rect.width == 0 || p_rect.height == 0) {
		return false;
	}
	if (p_rect.x >= p_grid_width || p_rect.y >= p_grid_height) {
		return false;
	}
	return p_rect.width <= p_grid_width - p_rect.x && p_rect.height <= p_grid_height - p_rect.y;
}

bool grid_rects_overlap(const GridRect &p_a, const GridRect &p_b) {
	if (p_a.width == 0 || p_a.height == 0 || p_b.width == 0 || p_b.height == 0) {
		return false;
	}
	const bool separated_x = p_a.x + p_a.width <= p_b.x || p_b.x + p_b.width <= p_a.x;
	const bool separated_y = p_a.y + p_a.height <= p_b.y || p_b.y + p_b.height <= p_a.y;
	return !(separated_x || separated_y);
}

} // namespace inv
