class_name ZSpawnMarker
extends ZWorldMarker
## Player or actor spawn point marker.


func marker_kind() -> StringName:
	return &"spawn"


func expected_id_kinds() -> PackedStringArray:
	return PackedStringArray(["spawn"])
