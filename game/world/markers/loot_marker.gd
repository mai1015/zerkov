class_name ZLootMarker
extends ZWorldMarker
## World loot container, cache or corpse marker.

@export var content_profile_id: StringName = &""
@export var is_corpse: bool = false


func marker_kind() -> StringName:
	return &"corpse" if is_corpse else &"loot"


func matches_kind(target_kind: Variant) -> bool:
	if super.matches_kind(target_kind):
		return true
	if target_kind is GDScript:
		return is_instance_of(self, target_kind)
	var kind_str := String(target_kind).to_lower()
	if is_corpse and (kind_str == "loot" or kind_str == "corpse"):
		return true
	if not is_corpse and kind_str == "loot":
		return true
	return false


func expected_id_kinds() -> PackedStringArray:
	return PackedStringArray(["loot"])


func validate() -> Array[String]:
	var problems := super.validate()
	if not content_profile_id.is_empty():
		var raw_profile := String(content_profile_id)
		if not ZIdentityRules.is_valid(raw_profile, &"profile"):
			problems.append("content_profile_id violates identity grammar: %s" % raw_profile)
	return problems
