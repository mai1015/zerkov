class_name ZerkovBodyHitboxProfile
extends RefCounted
## Sealed first-playable humanoid body geometry in canonical ZWorldUnits.
##
## Thorax and abdomen are the two health zones within the broader torso group.
## The small authored overlaps are intentional. They remove seam misses and are
## resolved by the stable priority below, never by Array or scene-tree order.

const CONTENT_VERSION: int = 1
const PROFILE_HUMANOID_V1: StringName = &"zerkov.hitbox_profile.humanoid.v1"
const SHAPE_AABB: StringName = &"aabb"

const GROUP_HEAD: StringName = &"head"
const GROUP_TORSO: StringName = &"torso"
const GROUP_ARM: StringName = &"arm"
const GROUP_LEG: StringName = &"leg"

const HITBOX_HEAD: StringName = &"zerkov.hitbox.humanoid.head"
const HITBOX_THORAX: StringName = &"zerkov.hitbox.humanoid.torso.thorax"
const HITBOX_ABDOMEN: StringName = &"zerkov.hitbox.humanoid.torso.abdomen"
const HITBOX_LEFT_ARM: StringName = &"zerkov.hitbox.humanoid.arm.left"
const HITBOX_RIGHT_ARM: StringName = &"zerkov.hitbox.humanoid.arm.right"
const HITBOX_LEFT_LEG: StringName = &"zerkov.hitbox.humanoid.leg.left"
const HITBOX_RIGHT_LEG: StringName = &"zerkov.hitbox.humanoid.leg.right"

const ZONE_PRIORITY_HEAD: int = 0
const ZONE_PRIORITY_THORAX: int = 1
const ZONE_PRIORITY_ABDOMEN: int = 2
const ZONE_PRIORITY_LEFT_ARM: int = 3
const ZONE_PRIORITY_RIGHT_ARM: int = 4
const ZONE_PRIORITY_LEFT_LEG: int = 5
const ZONE_PRIORITY_RIGHT_LEG: int = 6


## Local geometry is expressed in canonical micro-world-units. One world unit
## is one 32 px source tile. Only exact quarter turns are accepted by the world
## owner, so transforming this geometry never introduces floating-point state.
static func declarations() -> Array[Dictionary]:
	return [
		_declaration(HITBOX_HEAD, ZerkovHealthAbilityContent.ZONE_HEAD,
			GROUP_HEAD, ZONE_PRIORITY_HEAD, Vector2i(-220_000, -780_000),
			Vector2i(220_000, -400_000)),
		_declaration(HITBOX_THORAX, ZerkovHealthAbilityContent.ZONE_THORAX,
			GROUP_TORSO, ZONE_PRIORITY_THORAX, Vector2i(-340_000, -450_000),
			Vector2i(340_000, 100_000)),
		_declaration(HITBOX_ABDOMEN, ZerkovHealthAbilityContent.ZONE_ABDOMEN,
			GROUP_TORSO, ZONE_PRIORITY_ABDOMEN, Vector2i(-300_000, 50_000),
			Vector2i(300_000, 360_000)),
		_declaration(HITBOX_LEFT_ARM, ZerkovHealthAbilityContent.ZONE_LEFT_ARM,
			GROUP_ARM, ZONE_PRIORITY_LEFT_ARM, Vector2i(-520_000, -360_000),
			Vector2i(-250_000, 240_000)),
		_declaration(HITBOX_RIGHT_ARM, ZerkovHealthAbilityContent.ZONE_RIGHT_ARM,
			GROUP_ARM, ZONE_PRIORITY_RIGHT_ARM, Vector2i(250_000, -360_000),
			Vector2i(520_000, 240_000)),
		_declaration(HITBOX_LEFT_LEG, ZerkovHealthAbilityContent.ZONE_LEFT_LEG,
			GROUP_LEG, ZONE_PRIORITY_LEFT_LEG, Vector2i(-300_000, 300_000),
			Vector2i(-20_000, 800_000)),
		_declaration(HITBOX_RIGHT_LEG, ZerkovHealthAbilityContent.ZONE_RIGHT_LEG,
			GROUP_LEG, ZONE_PRIORITY_RIGHT_LEG, Vector2i(20_000, 300_000),
			Vector2i(300_000, 800_000)),
	]


static func declaration(hitbox_identifier: StringName) -> Dictionary:
	for value in declarations():
		if StringName(value["hitbox_id"]) == hitbox_identifier:
			return value.duplicate(true)
	return {}


static func declaration_digest() -> String:
	return ZCanonicalValue.sha256({
		"content_version": CONTENT_VERSION,
		"profile_id": String(PROFILE_HUMANOID_V1),
		"declarations": declarations(),
	})


static func validate() -> Dictionary:
	var findings: Array[StringName] = []
	if not ZIdentityRules.is_valid(String(PROFILE_HUMANOID_V1), &"hitbox_profile"):
		findings.append(&"profile_id_invalid")
	var hitbox_ids: Dictionary = {}
	var zone_ids: Dictionary = {}
	var priorities: Dictionary = {}
	var group_counts := {
		String(GROUP_HEAD): 0,
		String(GROUP_TORSO): 0,
		String(GROUP_ARM): 0,
		String(GROUP_LEG): 0,
	}
	for value in declarations():
		var hitbox_id := String(value.get("hitbox_id", ""))
		var zone_id := String(value.get("body_zone", ""))
		var group := String(value.get("anatomy_group", ""))
		var priority := int(value.get("priority", -1))
		var local_min := value.get("local_min_raw", Vector2i.ZERO) as Vector2i
		var local_max := value.get("local_max_raw", Vector2i.ZERO) as Vector2i
		if ZHitboxId.parse(hitbox_id) == null:
			findings.append(&"hitbox_id_invalid")
		if hitbox_ids.has(hitbox_id):
			findings.append(&"hitbox_id_duplicate")
		hitbox_ids[hitbox_id] = true
		if zone_ids.has(zone_id):
			findings.append(&"body_zone_duplicate")
		zone_ids[zone_id] = true
		if priorities.has(priority):
			findings.append(&"priority_duplicate")
		priorities[priority] = true
		if not group_counts.has(group):
			findings.append(&"anatomy_group_invalid")
		else:
			group_counts[group] = int(group_counts[group]) + 1
		if StringName(value.get("shape", &"")) != SHAPE_AABB \
				or local_min.x >= local_max.x or local_min.y >= local_max.y:
			findings.append(&"hitbox_geometry_invalid")
	var expected_zones := PackedStringArray(ZerkovHealthAbilityContent.BODY_ZONE_IDS)
	var actual_zones := PackedStringArray(zone_ids.keys())
	expected_zones.sort()
	actual_zones.sort()
	if actual_zones != expected_zones:
		findings.append(&"body_zone_set_mismatch")
	if group_counts != {"head": 1, "torso": 2, "arm": 2, "leg": 2}:
		findings.append(&"anatomy_group_count_invalid")
	if priorities.size() != 7 or not priorities.has(0) or not priorities.has(6):
		findings.append(&"priority_set_invalid")
	var digest := declaration_digest()
	if digest.is_empty():
		findings.append(&"declaration_digest_invalid")
	return {
		"ok": findings.is_empty(),
		"findings": findings.duplicate(),
		"digest": digest,
		"profile_id": String(PROFILE_HUMANOID_V1),
		"content_version": CONTENT_VERSION,
	}


## Produces detached world-space AABBs from an explicit canonical pose. This
## method never reads a Node2D or a physics body transform.
static func build_world_hitboxes(
	origin_raw: Vector2i,
	facing_quarter_turns: int
) -> Array[Dictionary]:
	if facing_quarter_turns < 0 or facing_quarter_turns > 3:
		return []
	var result: Array[Dictionary] = []
	for value in declarations():
		var local_min := value["local_min_raw"] as Vector2i
		var local_max := value["local_max_raw"] as Vector2i
		var rotated := _rotated_bounds(local_min, local_max, facing_quarter_turns)
		var world_hitbox := value.duplicate(true)
		world_hitbox.erase("local_min_raw")
		world_hitbox.erase("local_max_raw")
		world_hitbox["min_raw"] = origin_raw + (rotated["min_raw"] as Vector2i)
		world_hitbox["max_raw"] = origin_raw + (rotated["max_raw"] as Vector2i)
		result.append(world_hitbox)
	return result


static func _declaration(
	hitbox_id: StringName,
	body_zone: StringName,
	anatomy_group: StringName,
	priority: int,
	local_min_raw: Vector2i,
	local_max_raw: Vector2i
) -> Dictionary:
	return {
		"profile_id": String(PROFILE_HUMANOID_V1),
		"hitbox_id": String(hitbox_id),
		"body_zone": String(body_zone),
		"anatomy_group": String(anatomy_group),
		"priority": priority,
		"shape": String(SHAPE_AABB),
		"local_min_raw": local_min_raw,
		"local_max_raw": local_max_raw,
	}


static func _rotated_bounds(
	local_min: Vector2i,
	local_max: Vector2i,
	quarter_turns: int
) -> Dictionary:
	match quarter_turns:
		0:
			return {"min_raw": local_min, "max_raw": local_max}
		1:
			return {
				"min_raw": Vector2i(-local_max.y, local_min.x),
				"max_raw": Vector2i(-local_min.y, local_max.x),
			}
		2:
			return {
				"min_raw": Vector2i(-local_max.x, -local_max.y),
				"max_raw": Vector2i(-local_min.x, -local_min.y),
			}
		3:
			return {
				"min_raw": Vector2i(local_min.y, -local_max.x),
				"max_raw": Vector2i(local_max.y, -local_min.x),
			}
	return {}
