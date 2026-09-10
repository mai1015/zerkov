class_name ZStableId
extends RefCounted
## Base value object. Concrete ID types expose only validated constructors.

var _kind: StringName = &""
var _value: StringName = &""


func _initialize(expected_kind: StringName, raw: String) -> bool:
	if is_initialized() or _declared_kind() != expected_kind:
		return false
	if not ZIdentityRules.is_valid(raw, expected_kind):
		return false
	_kind = expected_kind
	_value = StringName(raw)
	return true


func kind() -> StringName:
	return _kind


func value() -> StringName:
	return _value


func canonical_key() -> String:
	return String(_value)


func is_equal(other: ZStableId) -> bool:
	return other != null and _kind == other._kind and _value == other._value


func is_initialized() -> bool:
	return not _value.is_empty()


func _to_string() -> String:
	return canonical_key()


func _declared_kind() -> StringName:
	var script: Script = get_script() as Script
	if script == null:
		return &""
	var constants: Dictionary = script.get_script_constant_map()
	return StringName(constants.get("KIND", &""))
