class_name ZAIValues
extends RefCounted
## Small shared value checks for AI. No scene, actor, clock, or native handles.

const MAX_TICK: int = 2_147_483_647
const LIMIT: int = ZWorldUnits.MAX_VISION_CANONICAL_RAW
const UNIT: int = ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT


static func position(value: Variant) -> bool:
	return typeof(value) == TYPE_VECTOR2I \
		and absi(int(value.x)) <= LIMIT and absi(int(value.y)) <= LIMIT


static func point(value: Variant) -> bool:
	return value is Dictionary and value.size() == 2 \
		and typeof(value.get("x")) == TYPE_INT and typeof(value.get("y")) == TYPE_INT \
		and absi(int(value.x)) <= LIMIT and absi(int(value.y)) <= LIMIT


static func encode_point(value: Vector2i) -> Dictionary:
	return {"x": int(value.x), "y": int(value.y)}


static func decode_point(value: Dictionary) -> Vector2i:
	return Vector2i(int(value.x), int(value.y))


static func entity(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and ZIdentityRules.is_valid(value, &"entity")


static func integer(value: Variant, minimum: int, maximum: int) -> bool:
	return typeof(value) == TYPE_INT and value >= minimum and value <= maximum


static func keys(value: Dictionary, names: Array) -> bool:
	if value.size() != names.size():
		return false
	for key: String in names:
		if not value.has(key):
			return false
	return true


static func frozen(value: Variant) -> Variant:
	# Only call on locally constructed, bounded value records, never arbitrary
	# caller objects. Arrays/dictionaries are detached before publication.
	var copy: Variant = value.duplicate(true) if value is Dictionary or value is Array else value
	_freeze(copy)
	return copy


static func _freeze(value: Variant) -> void:
	if value is Dictionary:
		for child: Variant in value.values():
			_freeze(child)
		value.make_read_only()
	elif value is Array:
		for child: Variant in value:
			_freeze(child)
		value.make_read_only()


static func within(a: Vector2i, b: Vector2i, radius: int) -> bool:
	# First compare 64-bit scalar differences; Vector2i subtraction can wrap.
	var dx: int = absi(int(a.x) - int(b.x))
	var dy: int = absi(int(a.y) - int(b.y))
	if radius < 0 or radius > 128 * UNIT or dx > radius or dy > radius:
		return false
	return dx * dx + dy * dy <= radius * radius


static func distance_key(a: Vector2i, b: Vector2i) -> int:
	# Manhattan distance is bounded even at opposite signed-coordinate limits.
	return absi(int(a.x) - int(b.x)) + absi(int(a.y) - int(b.y))


static func direction(a: Vector2i, b: Vector2i) -> Vector2i:
	# Bounded Chebyshev direction. Movement's existing normalization owns speed.
	var dx: int = int(b.x) - int(a.x)
	var dy: int = int(b.y) - int(a.y)
	var scale: int = maxi(absi(dx), absi(dy))
	if scale == 0:
		return Vector2i.ZERO
	@warning_ignore("integer_division")
	var x: int = dx * 1000 / scale
	@warning_ignore("integer_division")
	var y: int = dy * 1000 / scale
	return Vector2i(x, y)
