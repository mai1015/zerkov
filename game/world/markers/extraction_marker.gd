class_name ZExtractionMarker
extends ZWorldMarker
## Raid extraction boundary and interaction marker.

@export var zone_cells: Rect2i = Rect2i()


func marker_kind() -> StringName:
	return &"extract"


func matches_kind(target_kind: Variant) -> bool:
	if super.matches_kind(target_kind):
		return true
	if target_kind is GDScript:
		return is_instance_of(self, target_kind)
	var kind_str := String(target_kind).to_lower()
	return kind_str == "extract" or kind_str == "extraction"


func expected_id_kinds() -> PackedStringArray:
	return PackedStringArray(["extract", "extraction"])


func validate() -> Array[String]:
	var problems := super.validate()
	if zone_cells.size.x <= 0 or zone_cells.size.y <= 0:
		problems.append("zone_cells has non-positive dimensions: %s" % str(zone_cells))
	elif not zone_cells.has_point(cell):
		problems.append("zone_cells %s does not contain extraction cell %s" % [str(zone_cells), str(cell)])
	return problems
