class_name ZInventoryId
extends ZStableId

const KIND: StringName = &"inventory"


static func from_parts(parts: PackedStringArray) -> ZInventoryId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZInventoryId:
	var result := ZInventoryId.new()
	return result if result._initialize(KIND, raw) else null
