class_name ZSessionId
extends ZStableId

const KIND: StringName = &"session"


static func from_parts(parts: PackedStringArray) -> ZSessionId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZSessionId:
	var result := ZSessionId.new()
	return result if result._initialize(KIND, raw) else null
