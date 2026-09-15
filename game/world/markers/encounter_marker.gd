class_name ZEncounterMarker
extends ZWorldMarker
## Enemy / scav / mutant staging anchor.


func marker_kind() -> StringName:
	return &"encounter"


func expected_id_kinds() -> PackedStringArray:
	return PackedStringArray(["encounter"])
