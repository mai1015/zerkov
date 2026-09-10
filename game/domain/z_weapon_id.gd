class_name ZWeaponId
extends ZStableId

const KIND: StringName = &"weapon"


static func from_parts(parts: PackedStringArray) -> ZWeaponId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZWeaponId:
	var result := ZWeaponId.new()
	return result if result._initialize(KIND, raw) else null
