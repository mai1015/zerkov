class_name ZObjectiveMarker
extends ZWorldMarker
## Objective interaction marker (e.g. supply crates).

@export var landmark_id: StringName = &""
@export var content_profile_id: StringName = &""


func marker_kind() -> StringName:
	return &"objective"


func matches_kind(target_kind: Variant) -> bool:
	if super.matches_kind(target_kind):
		return true
	if target_kind is GDScript:
		return is_instance_of(self, target_kind)
	var kind_str := String(target_kind).to_lower()
	return kind_str == "objective_crate" or kind_str == "objective" or kind_str == "loot"


func expected_id_kinds() -> PackedStringArray:
	# Authored crate anchors use zerkov.loot.sawmill.crate.*
	return PackedStringArray(["loot", "objective"])


func validate() -> Array[String]:
	var problems := super.validate()
	if not landmark_id.is_empty():
		var raw_landmark := String(landmark_id)
		if not ZIdentityRules.is_valid(raw_landmark, &"landmark"):
			problems.append("landmark_id violates identity grammar: %s" % raw_landmark)
	if not content_profile_id.is_empty():
		var raw_profile := String(content_profile_id)
		if not ZIdentityRules.is_valid(raw_profile, &"profile"):
			problems.append("content_profile_id violates identity grammar: %s" % raw_profile)
	return problems
