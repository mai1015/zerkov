class_name ZTaskId
extends ZStableId

const KIND: StringName = &"task"


static func from_parts(parts: PackedStringArray) -> ZTaskId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZTaskId:
	var result := ZTaskId.new()
	return result if result._initialize(KIND, raw) else null
