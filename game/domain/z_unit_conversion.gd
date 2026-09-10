class_name ZUnitConversion
extends RefCounted
## Typed result for a checked world/unit conversion.

enum ValueKind {
	NONE,
	INTEGER,
	VECTOR2I,
	VECTOR2,
}

var ok: bool = false
var error_code: StringName = &"conversion_failed"
var kind: ValueKind = ValueKind.NONE
var integer_value: int = 0
var vector2i_value: Vector2i = Vector2i.ZERO
var vector2_value: Vector2 = Vector2.ZERO


static func failure(code: StringName) -> ZUnitConversion:
	var result := ZUnitConversion.new()
	result.error_code = code
	return result


static func integer(value: int) -> ZUnitConversion:
	var result := ZUnitConversion.new()
	result.ok = true
	result.error_code = &""
	result.kind = ValueKind.INTEGER
	result.integer_value = value
	return result


static func point_i(value: Vector2i) -> ZUnitConversion:
	var result := ZUnitConversion.new()
	result.ok = true
	result.error_code = &""
	result.kind = ValueKind.VECTOR2I
	result.vector2i_value = value
	return result


static func point_f(value: Vector2) -> ZUnitConversion:
	var result := ZUnitConversion.new()
	result.ok = true
	result.error_code = &""
	result.kind = ValueKind.VECTOR2

	result.vector2_value = value
	return result
