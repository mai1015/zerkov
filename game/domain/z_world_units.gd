class_name ZWorldUnits
extends RefCounted
## The only supported conversion boundary for authoritative spatial values.

const SOURCE_TILE_PIXELS: int = 32
const GODOT_PIXELS_PER_WORLD_UNIT: int = 32
const VISION_MICROUNITS_PER_WORLD_UNIT: int = 1_000_000
const ABILITY_MICROUNITS_PER_WHOLE: int = 1_000_000
const WEAPON_MILLIUNITS_PER_WORLD_UNIT: int = 1_000
const WEAPON_DAMAGE_MILLIUNITS_PER_WHOLE: int = 1_000
# Godot's Vector2i components are signed 32-bit values.  Keep the accepted
# floating-point domain at an exact power-of-two pixel boundary whose canonical
# representation (2,048,000,000) leaves explicit headroom below INT32_MAX.
# Conversion validates the rounded scalars before constructing Vector2i, so an
# out-of-domain input can never wrap or partially publish a point.
const MAX_GODOT_COORDINATE_PX: float = 65_536.0
const MAX_CANONICAL_RAW: int = 2_048_000_000


static func godot_to_canonical(point_px: Vector2) -> ZUnitConversion:
	if not _is_valid_godot_point(point_px):
		return ZUnitConversion.failure(&"invalid_godot_position")
	var raw_x := _round_half_away_from_zero(
		point_px.x * VISION_MICROUNITS_PER_WORLD_UNIT / GODOT_PIXELS_PER_WORLD_UNIT
	)
	var raw_y := _round_half_away_from_zero(
		point_px.y * VISION_MICROUNITS_PER_WORLD_UNIT / GODOT_PIXELS_PER_WORLD_UNIT
	)
	if absi(raw_x) > MAX_CANONICAL_RAW or absi(raw_y) > MAX_CANONICAL_RAW:
		return ZUnitConversion.failure(&"canonical_position_out_of_range")
	return ZUnitConversion.point_i(Vector2i(raw_x, raw_y))


static func canonical_to_godot(point_raw: Vector2i) -> ZUnitConversion:
	if not _is_valid_canonical_point(point_raw):
		return ZUnitConversion.failure(&"canonical_position_out_of_range")
	return ZUnitConversion.point_f(Vector2(
		float(point_raw.x) * GODOT_PIXELS_PER_WORLD_UNIT / VISION_MICROUNITS_PER_WORLD_UNIT,
		float(point_raw.y) * GODOT_PIXELS_PER_WORLD_UNIT / VISION_MICROUNITS_PER_WORLD_UNIT
	))


static func godot_to_vision(point_px: Vector2) -> ZUnitConversion:
	return godot_to_canonical(point_px)


static func vision_to_godot(point_raw: Vector2i) -> ZUnitConversion:
	return canonical_to_godot(point_raw)


static func godot_to_weapon(point_px: Vector2) -> ZUnitConversion:
	if not _is_valid_godot_point(point_px):
		return ZUnitConversion.failure(&"invalid_godot_position")
	return ZUnitConversion.point_i(Vector2i(
		_round_half_away_from_zero(
			point_px.x * WEAPON_MILLIUNITS_PER_WORLD_UNIT / GODOT_PIXELS_PER_WORLD_UNIT
		),
		_round_half_away_from_zero(
			point_px.y * WEAPON_MILLIUNITS_PER_WORLD_UNIT / GODOT_PIXELS_PER_WORLD_UNIT
		)
	))


static func weapon_to_godot(point_raw: Vector2i) -> ZUnitConversion:
	var limit := MAX_CANONICAL_RAW / 1000
	if absi(point_raw.x) > limit or absi(point_raw.y) > limit:
		return ZUnitConversion.failure(&"weapon_position_out_of_range")
	return ZUnitConversion.point_f(Vector2(
		float(point_raw.x) * GODOT_PIXELS_PER_WORLD_UNIT / WEAPON_MILLIUNITS_PER_WORLD_UNIT,
		float(point_raw.y) * GODOT_PIXELS_PER_WORLD_UNIT / WEAPON_MILLIUNITS_PER_WORLD_UNIT
	))


static func godot_to_tile(point_px: Vector2) -> ZUnitConversion:
	if not _is_valid_godot_point(point_px):
		return ZUnitConversion.failure(&"invalid_godot_position")
	return ZUnitConversion.point_i(Vector2i(
		floori(point_px.x / SOURCE_TILE_PIXELS),
		floori(point_px.y / SOURCE_TILE_PIXELS)
	))


static func tile_origin_to_godot(tile: Vector2i) -> ZUnitConversion:
	var point := Vector2(tile) * SOURCE_TILE_PIXELS
	if not _is_valid_godot_point(point):
		return ZUnitConversion.failure(&"tile_position_out_of_range")
	return ZUnitConversion.point_f(point)


static func tile_center_to_godot(tile: Vector2i) -> ZUnitConversion:
	var point := Vector2(tile) * SOURCE_TILE_PIXELS + Vector2.ONE * (SOURCE_TILE_PIXELS / 2.0)
	if not _is_valid_godot_point(point):
		return ZUnitConversion.failure(&"tile_position_out_of_range")
	return ZUnitConversion.point_f(point)


static func weapon_damage_to_ability(damage_milliunits: int) -> ZUnitConversion:
	if damage_milliunits < -9_000_000_000_000 or damage_milliunits > 9_000_000_000_000:
		return ZUnitConversion.failure(&"damage_out_of_range")
	return ZUnitConversion.integer(
		damage_milliunits * ABILITY_MICROUNITS_PER_WHOLE / WEAPON_DAMAGE_MILLIUNITS_PER_WHOLE
	)


static func _is_valid_godot_point(point: Vector2) -> bool:
	return (
		not is_nan(point.x)
		and not is_nan(point.y)
		and not is_inf(point.x)
		and not is_inf(point.y)
		and absf(point.x) <= MAX_GODOT_COORDINATE_PX
		and absf(point.y) <= MAX_GODOT_COORDINATE_PX
	)


static func _is_valid_canonical_point(point: Vector2i) -> bool:
	return absi(point.x) <= MAX_CANONICAL_RAW and absi(point.y) <= MAX_CANONICAL_RAW


static func _round_half_away_from_zero(value: float) -> int:
	# Vector2 is single-precision in the pinned build, so an authored mathematical
	# half can arrive a few ulps below 0.5 after scaling. Normalize only that
	# narrow tie band, then apply the documented away-from-zero rule.
	var magnitude := absf(value)
	var whole := floori(magnitude)
	var fraction := magnitude - whole
	var rounded := whole + 1 if absf(fraction - 0.5) <= 0.00001 else floori(magnitude + 0.5)
	return rounded if value >= 0.0 else -rounded
