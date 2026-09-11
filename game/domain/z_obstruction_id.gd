class_name ZObstructionId
extends ZStableId
## Stable identity for game-owned authoritative combat obstruction geometry.

const KIND: StringName = &"obstruction"


static func from_parts(parts: PackedStringArray) -> ZObstructionId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZObstructionId:
	var result := ZObstructionId.new()
	return result if result._initialize(KIND, raw) else null
