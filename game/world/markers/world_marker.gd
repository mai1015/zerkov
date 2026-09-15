class_name ZWorldMarker
extends Resource
## Base resource for typed world markers with validated stable identities.

@export var marker_id: StringName = &""
@export var cell: Vector2i = Vector2i.ZERO
@export var approach_cell: Vector2i = Vector2i.ZERO
@export var display_name: String = ""
@export var tile: String = ""
@export var label_offset_px: Vector2i = Vector2i.ZERO


func marker_kind() -> StringName:
	return &"marker"


func matches_kind(target_kind: Variant) -> bool:
	if target_kind is GDScript:
		return is_instance_of(self, target_kind)
	var kind_str := String(target_kind).to_lower()
	return kind_str == String(marker_kind()) or kind_str == "marker"


func expected_id_kinds() -> PackedStringArray:
	return PackedStringArray()


func validate() -> Array[String]:
	var problems: Array[String] = []
	var raw_id := String(marker_id)
	if raw_id.is_empty():
		problems.append("marker_id is empty")
	else:
		if raw_id != raw_id.to_lower():
			problems.append("marker_id contains upper-case characters: %s" % raw_id)
		if raw_id.strip_edges() != raw_id or " " in raw_id or "\t" in raw_id or "\n" in raw_id:
			problems.append("marker_id contains whitespace: %s" % raw_id)
		var expected := expected_id_kinds()
		if expected.is_empty():
			var slice := raw_id.get_slice(".", 1)
			if not ZIdentityRules.is_valid(raw_id, StringName(slice)):
				problems.append("marker_id violates identity grammar: %s" % raw_id)
		else:
			var valid_for_any := false
			for exp_k in expected:
				if ZIdentityRules.is_valid(raw_id, StringName(exp_k)):
					valid_for_any = true
					break
			if not valid_for_any:
				problems.append("marker_id '%s' violates identity grammar for expected kinds %s" % [raw_id, str(expected)])
	if display_name.is_empty():
		problems.append("display_name is empty for marker %s" % raw_id)
	return problems
