class_name ZConsequenceId
extends ZStableId

const KIND: StringName = &"consequence"


static func from_parts(parts: PackedStringArray) -> ZConsequenceId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZConsequenceId:
	var result := ZConsequenceId.new()
	return result if result._initialize(KIND, raw) else null
