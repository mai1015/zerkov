class_name ZPlayerFacing
extends RefCounted
## Deterministic facing resolution and explicit tie-break rules.
##
## Converts continuous movement/aim directions to discrete 4-way and 8-way
## facing states, ensuring bit-for-bit determinism across all platforms.

enum Facing4 {
	NORTH = 0,
	EAST = 1,
	SOUTH = 2,
	WEST = 3,
}

enum Facing8 {
	NORTH = 0,
	NORTH_EAST = 1,
	EAST = 2,
	SOUTH_EAST = 3,
	SOUTH = 4,
	SOUTH_WEST = 5,
	WEST = 6,
	NORTH_WEST = 7,
}

enum TieBreak4 {
	HYSTERESIS_THEN_VERTICAL = 0,
	PREFER_VERTICAL = 1,
	PREFER_HORIZONTAL = 2,
}

const EPSILON: float = 0.00001

const FACING4_NAMES: PackedStringArray = [
	"north",
	"east",
	"south",
	"west",
]

const FACING8_NAMES: PackedStringArray = [
	"north",
	"north_east",
	"east",
	"south_east",
	"south",
	"south_west",
	"west",
	"north_west",
]

const VECTORS_4: Array[Vector2] = [
	Vector2(0.0, -1.0), # NORTH
	Vector2(1.0, 0.0),  # EAST
	Vector2(0.0, 1.0),  # SOUTH
	Vector2(-1.0, 0.0), # WEST
]

const VECTORS_8: Array[Vector2] = [
	Vector2(0.0, -1.0),               # NORTH
	Vector2(0.70710678, -0.70710678), # NORTH_EAST
	Vector2(1.0, 0.0),                # EAST
	Vector2(0.70710678, 0.70710678),  # SOUTH_EAST
	Vector2(0.0, 1.0),                # SOUTH
	Vector2(-0.70710678, 0.70710678), # SOUTH_WEST
	Vector2(-1.0, 0.0),               # WEST
	Vector2(-0.70710678, -0.70710678) # NORTH_WEST
]


## Resolves a 4-way cardinal facing from a 2D direction vector.
## If direction is zero, returns current_facing.
## If |x| != |y|, the dominant axis wins.
## If |x| == |y| (diagonal tie), tie_break rule determines outcome:
## - HYSTERESIS_THEN_VERTICAL: retains current_facing if it matches either
##   diagonal component; otherwise defaults to vertical.
## - PREFER_VERTICAL: chooses SOUTH (y > 0) or NORTH (y < 0).
## - PREFER_HORIZONTAL: chooses EAST (x > 0) or WEST (x < 0).
static func resolve_facing_4(
	direction: Vector2,
	current_facing: Facing4 = Facing4.SOUTH,
	tie_break: TieBreak4 = TieBreak4.HYSTERESIS_THEN_VERTICAL
) -> Facing4:
	if direction.is_zero_approx():
		return current_facing
	var ax := absf(direction.x)
	var ay := absf(direction.y)
	if ax - ay > EPSILON:
		return Facing4.EAST if direction.x > 0.0 else Facing4.WEST
	if ay - ax > EPSILON:
		return Facing4.SOUTH if direction.y > 0.0 else Facing4.NORTH

	var horiz := Facing4.EAST if direction.x > 0.0 else Facing4.WEST
	var vert := Facing4.SOUTH if direction.y > 0.0 else Facing4.NORTH
	match tie_break:
		TieBreak4.PREFER_HORIZONTAL:
			return horiz
		TieBreak4.PREFER_VERTICAL:
			return vert
		TieBreak4.HYSTERESIS_THEN_VERTICAL, _:
			if current_facing == horiz or current_facing == vert:
				return current_facing
			return vert


## Resolves an 8-way compass facing from a 2D direction vector.
## If direction is zero, returns current_facing.
## 8 sectors are centered on 0, 45, 90, 135, 180, 225, 270, 315 degrees.
## Exact boundary ties at odd multiples of 22.5 deg resolve to CARDINAL.
static func resolve_facing_8(
	direction: Vector2,
	current_facing: Facing8 = Facing8.SOUTH
) -> Facing8:
	if direction.is_zero_approx():
		return current_facing
	var angle := atan2(direction.y, direction.x)
	if angle < 0.0:
		angle += TAU

	var sector_fraction := angle * 8.0 / TAU
	var sector_index := roundi(sector_fraction)
	var diff_from_half := absf((sector_fraction - floorf(sector_fraction)) - 0.5)
	if diff_from_half <= EPSILON:
		# Boundary tie: prefer cardinal (even sector indices) over ordinal (odd)
		var lower := floori(sector_fraction) % 8
		var upper := ceili(sector_fraction) % 8
		sector_index = lower if lower % 2 == 0 else upper
	else:
		sector_index = sector_index % 8

	match sector_index:
		0: return Facing8.EAST
		1: return Facing8.SOUTH_EAST
		2: return Facing8.SOUTH
		3: return Facing8.SOUTH_WEST
		4: return Facing8.WEST
		5: return Facing8.NORTH_WEST
		6: return Facing8.NORTH
		7: return Facing8.NORTH_EAST
	return current_facing


static func facing_4_to_vector(facing: Facing4) -> Vector2:
	if int(facing) >= 0 and int(facing) < VECTORS_4.size():
		return VECTORS_4[int(facing)]
	return Vector2(0.0, 1.0)


static func facing_8_to_vector(facing: Facing8) -> Vector2:
	if int(facing) >= 0 and int(facing) < VECTORS_8.size():
		return VECTORS_8[int(facing)]
	return Vector2(0.0, 1.0)


static func facing_4_to_8(facing: Facing4) -> Facing8:
	match facing:
		Facing4.NORTH: return Facing8.NORTH
		Facing4.EAST: return Facing8.EAST
		Facing4.SOUTH: return Facing8.SOUTH
		Facing4.WEST: return Facing8.WEST
	return Facing8.SOUTH


static func facing_8_to_4(
	facing: Facing8,
	current_4: Facing4 = Facing4.SOUTH,
	tie_break: TieBreak4 = TieBreak4.HYSTERESIS_THEN_VERTICAL
) -> Facing4:
	match facing:
		Facing8.NORTH: return Facing4.NORTH
		Facing8.EAST: return Facing4.EAST
		Facing8.SOUTH: return Facing4.SOUTH
		Facing8.WEST: return Facing4.WEST
		Facing8.NORTH_EAST:
			return resolve_facing_4(Vector2(1.0, -1.0), current_4, tie_break)
		Facing8.SOUTH_EAST:
			return resolve_facing_4(Vector2(1.0, 1.0), current_4, tie_break)
		Facing8.SOUTH_WEST:
			return resolve_facing_4(Vector2(-1.0, 1.0), current_4, tie_break)
		Facing8.NORTH_WEST:
			return resolve_facing_4(Vector2(-1.0, -1.0), current_4, tie_break)
	return current_4


static func facing_name_4(facing: Facing4) -> StringName:
	if int(facing) >= 0 and int(facing) < FACING4_NAMES.size():
		return StringName(FACING4_NAMES[int(facing)])
	return &"south"


static func facing_name_8(facing: Facing8) -> StringName:
	if int(facing) >= 0 and int(facing) < FACING8_NAMES.size():
		return StringName(FACING8_NAMES[int(facing)])
	return &"south"
