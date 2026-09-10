#ifndef INVENTORY_SYSTEM_CORE_PLACEMENT_H
#define INVENTORY_SYSTEM_CORE_PLACEMENT_H

#include <cstdint>

// Pure SPATIAL_GRID footprint math. No state, no allocation, no catalog or
// runtime-state dependency, so it stays trivially unit-testable and reusable
// by both mutation primitives and the future invariant/snapshot layers.
namespace inv {

struct GridRect {
	std::uint32_t x = 0;
	std::uint32_t y = 0;
	std::uint32_t width = 0;
	std::uint32_t height = 0;
};

// Builds the occupied rectangle for an item placed at (p_x, p_y). Rotation
// swaps width/height; callers gate whether rotation is permitted before
// calling this.
GridRect effective_footprint(
		std::uint32_t p_x,
		std::uint32_t p_y,
		std::uint32_t p_base_width,
		std::uint32_t p_base_height,
		bool p_rotated);

// Zero-size rectangles never fit; coordinates and size are compared without
// forming an out-of-range sum.
bool grid_rect_in_bounds(const GridRect &p_rect, std::uint32_t p_grid_width, std::uint32_t p_grid_height);

bool grid_rects_overlap(const GridRect &p_a, const GridRect &p_b);

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_PLACEMENT_H
