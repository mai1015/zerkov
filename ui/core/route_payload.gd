class_name ZUIRoutePayload
extends RefCounted

## Typed, detached data carried by a UI route intent.
##
## Task 8.2 does not introduce feature-specific route data. Existing routes
## therefore accept only EMPTY_TYPE with no values; later presentation tasks
## can add explicit payload classes/types without falling back to an untyped
## Dictionary at the navigation boundary.

const EMPTY_TYPE := &"empty"

var type_id: StringName = EMPTY_TYPE
var _values: Dictionary = {}


func _init(p_type_id: StringName = EMPTY_TYPE, p_values: Dictionary = {}) -> void:
	type_id = p_type_id
	_values = p_values.duplicate(true)


func values() -> Dictionary:
	return _values.duplicate(true)


func is_empty() -> bool:
	return _values.is_empty()


static func empty() -> ZUIRoutePayload:
	return ZUIRoutePayload.new()
