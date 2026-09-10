class_name ZRequestId
extends ZStableId

const KIND: StringName = &"request"


static func from_parts(parts: PackedStringArray) -> ZRequestId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZRequestId:
	var result := ZRequestId.new()
	return result if result._initialize(KIND, raw) else null
