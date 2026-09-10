class_name ZRaidId
extends ZStableId

const KIND: StringName = &"raid"


static func from_parts(parts: PackedStringArray) -> ZRaidId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZRaidId:
	var result := ZRaidId.new()
	return result if result._initialize(KIND, raw) else null
