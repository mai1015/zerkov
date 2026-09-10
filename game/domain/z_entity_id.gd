class_name ZEntityId
extends ZStableId

const KIND: StringName = &"entity"


static func from_parts(parts: PackedStringArray) -> ZEntityId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZEntityId:
	var result := ZEntityId.new()
	return result if result._initialize(KIND, raw) else null
