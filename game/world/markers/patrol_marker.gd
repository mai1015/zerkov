class_name ZPatrolMarker
extends ZWorldMarker
## Deterministically derived route patrol waypoint.

@export var route_id: StringName = &""
@export var ordinal: int = 0


func marker_kind() -> StringName:
	return &"patrol"


func matches_kind(target_kind: Variant) -> bool:
	if super.matches_kind(target_kind):
		return true
	if target_kind is GDScript:
		return is_instance_of(self, target_kind)
	var kind_str := String(target_kind).to_lower()
	return kind_str == "patrol" or kind_str == "patrol_marker" or kind_str == "waypoint"


func expected_id_kinds() -> PackedStringArray:
	return PackedStringArray(["patrol"])


func validate() -> Array[String]:
	var problems := super.validate()
	if route_id.is_empty():
		problems.append("route_id cannot be empty")
	else:
		var raw_route := String(route_id)
		if not ZIdentityRules.is_valid(raw_route, &"route"):
			problems.append("route_id violates identity grammar: %s" % raw_route)
	if ordinal < 0:
		problems.append("ordinal cannot be negative: %d" % ordinal)
	return problems
