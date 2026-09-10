class_name ZSettlementId
extends ZStableId

const KIND: StringName = &"settlement"


static func from_parts(parts: PackedStringArray) -> ZSettlementId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZSettlementId:
	var result := ZSettlementId.new()
	return result if result._initialize(KIND, raw) else null
