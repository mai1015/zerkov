class_name ZHitboxId
extends ZStableId
## Stable identity for a game-owned authoritative body hitbox definition.

const KIND: StringName = &"hitbox"


static func from_parts(parts: PackedStringArray) -> ZHitboxId:
	return parse(ZIdentityRules.compose(KIND, parts))


static func parse(raw: String) -> ZHitboxId:
	var result := ZHitboxId.new()
	return result if result._initialize(KIND, raw) else null
