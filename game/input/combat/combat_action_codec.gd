class_name ZCombatActionCodec
extends RefCounted
## Task 5.7 payload vocabulary. No native mutation, world query, or RNG here.
## Revisions and equipment identifiers are claims for domain consumers to recheck.

const ACTION_PREFIX: String = "common_ui/zerkov/gameplay/"
const INTENT_PREFIX: String = "combat_"
const ACTIONS: PackedStringArray = ["aim", "fire", "reload", "cancel_reload", "melee", "quick_heal"]
const BODY_ZONES: PackedStringArray = ["head", "thorax", "abdomen", "left_arm", "right_arm", "left_leg", "right_leg"]
const MAX_COUNTER: int = 2_147_483_647
const DIRECTION_SCALE: int = 1000
const MAX_ID_BYTES: int = 128


static func action_for_logical(action_id: StringName) -> StringName:
	var name := String(action_id)
	if not name.begins_with(ACTION_PREFIX):
		return &""
	var action := name.trim_prefix(ACTION_PREFIX)
	return StringName(action) if ACTIONS.has(action) else &""


static func action_for_intent(kind: StringName) -> StringName:
	var name := String(kind)
	if not name.begins_with(INTENT_PREFIX):
		return &""
	var action := name.trim_prefix(INTENT_PREFIX)
	return StringName(action) if ACTIONS.has(action) else &""


static func validate_payload(action: StringName, payload: Dictionary) -> StringName:
	# Check boundedness before copying or walking caller-owned nested values.
	if not ZCanonicalValue.is_bounded(payload):
		return &"combat_payload_unbounded"
	match action:
		&"aim":
			if not _keys(payload, ["direction_milli", "aiming"]) \
				or typeof(payload.direction_milli) != TYPE_VECTOR2I or typeof(payload.aiming) != TYPE_BOOL:
				return &"combat_aim_payload_invalid"
			var direction: Vector2i = payload.direction_milli
			if direction == Vector2i.ZERO or absi(int(direction.x)) > DIRECTION_SCALE \
				or absi(int(direction.y)) > DIRECTION_SCALE:
				return &"combat_aim_direction_invalid"
		&"fire":
			if not _keys(payload, ["weapon_id", "expected_weapon_revision"]) \
				or not _weapon(payload.weapon_id) or not _revision(payload.expected_weapon_revision):
				return &"combat_fire_payload_invalid"
		&"reload":
			if not _keys(payload, ["weapon_id", "expected_weapon_revision", "expected_inventory_revision"]) \
				or not _weapon(payload.weapon_id) or not _revision(payload.expected_weapon_revision) \
				or not _revision(payload.expected_inventory_revision):
				return &"combat_reload_payload_invalid"
		&"cancel_reload":
			if not _keys(payload, ["weapon_id", "reservation_id"]) or not _weapon(payload.weapon_id) \
				or not _identifier(payload.reservation_id):
				return &"combat_cancel_payload_invalid"
		&"melee":
			if not _keys(payload, ["weapon_id", "expected_inventory_revision"]) \
				or not _weapon(payload.weapon_id) or not _revision(payload.expected_inventory_revision):
				return &"combat_melee_payload_invalid"
		&"quick_heal":
			if not _keys(payload, ["body_zone", "treatment", "expected_health_revision", "expected_inventory_revision"]) \
				or typeof(payload.body_zone) != TYPE_STRING or not BODY_ZONES.has(payload.body_zone) \
				or typeof(payload.treatment) != TYPE_STRING or payload.treatment not in ["bandage", "splint"] \
				or not _revision(payload.expected_health_revision) or not _revision(payload.expected_inventory_revision):
				return &"combat_heal_payload_invalid"
		_:
			return &"combat_action_unsupported"
	return &""


static func validate_intent(intent: ZRaidIntent) -> StringName:
	if intent == null or intent.source not in [ZRaidIntent.Source.PLAYER, ZRaidIntent.Source.AI]:
		return &"combat_source_invalid"
	var action := action_for_intent(intent.kind)
	if action.is_empty():
		return &"combat_action_unsupported"
	return validate_payload(action, intent.payload)


static func _keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key: String in expected:
		if not value.has(key):
			return false
	return true


static func _revision(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and value >= 0 and value <= MAX_COUNTER


static func _identifier(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or value.is_empty() or value.to_utf8_buffer().size() > MAX_ID_BYTES:
		return false
	for code: int in value.to_utf8_buffer():
		if code < 33 or code > 126:
			return false
	return true


static func _weapon(value: Variant) -> bool:
	return _identifier(value) and ZIdentityRules.is_valid(value, &"weapon")
