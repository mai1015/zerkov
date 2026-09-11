extends SceneTree
## Promoted task-5.3 contract.
## Run with:
## godot --headless --path . --audio-driver Dummy --script \
##   res://tests/combat/body_hitbox_contract.gd

const BODY_LAYER: int = 1
const OBSTRUCTION_LAYER: int = 2

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("BODY_HITBOX_CONTRACT: " + message)


func run() -> void:
	_test_profile_contract()
	_test_authoritative_world_contract()
	_test_rotation_and_mask_contract()
	print("BODY_HITBOX_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_profile_contract() -> void:
	var report := ZerkovBodyHitboxProfile.validate()
	check(bool(report.get("ok", false)), "sealed humanoid profile validates")
	check((report.get("findings", []) as Array).is_empty(),
		"profile validation has no findings")
	check(String(report.get("digest", "")).length() == 64,
		"profile has a stable SHA-256 declaration digest")
	check(ZIdentityRules.is_valid(
		String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1), &"hitbox_profile"),
		"humanoid profile identifier uses the stable identity grammar")

	var declarations := ZerkovBodyHitboxProfile.declarations()
	check(declarations.size() == 7, "profile authors all seven health zones")
	var zone_ids := PackedStringArray()
	var hitbox_ids := PackedStringArray()
	var groups: Dictionary = {}
	var priorities := PackedInt32Array()
	for declaration in declarations:
		zone_ids.append(String(declaration["body_zone"]))
		hitbox_ids.append(String(declaration["hitbox_id"]))
		priorities.append(int(declaration["priority"]))
		var group := String(declaration["anatomy_group"])
		groups[group] = int(groups.get(group, 0)) + 1
		check(ZHitboxId.parse(String(declaration["hitbox_id"])) != null,
			"each authored hitbox has a typed stable identity")
		check(StringName(declaration["shape"]) == ZerkovBodyHitboxProfile.SHAPE_AABB,
			"each authoritative body shape is an integer AABB")
	zone_ids.sort()
	var expected_zones := PackedStringArray(ZerkovHealthAbilityContent.BODY_ZONE_IDS)
	expected_zones.sort()
	check(zone_ids == expected_zones,
		"hitbox zones exactly match Gameplay Abilities health-zone identifiers")
	check(groups == {"head": 1, "torso": 2, "arm": 2, "leg": 2},
		"head, torso, arms, and legs have the declared group cardinality")
	check(priorities == PackedInt32Array([0, 1, 2, 3, 4, 5, 6]),
		"overlap priorities are exact and contiguous")
	check(hitbox_ids.size() == 7, "all stable hitbox identifiers are exposed")
	check(ZObstructionId.parse("zerkov.obstruction.sawmill.wall_001") != null,
		"combat obstruction identities use a separate typed namespace")

	var detached := ZerkovBodyHitboxProfile.declarations()
	detached[0]["body_zone"] = "forged"
	check(StringName(ZerkovBodyHitboxProfile.declarations()[0]["body_zone"])
		== ZerkovHealthAbilityContent.ZONE_HEAD,
		"callers cannot mutate the sealed profile through returned dictionaries")


func _test_authoritative_world_contract() -> void:
	var context := _new_context("promoted")
	var authority := context["authority"] as RaidAuthority
	var world := context["world"] as BodyHitboxWorld2D
	var generation := int(context["generation"])
	var token := int(context["token"])
	var target := _entity("promoted_target")
	var decoy := _entity("promoted_decoy")
	var target_origin := Vector2i(5_000_000, 0)
	var bodies: Array = [
		_body(target, 1, target_origin),
		_body(decoy, 1, Vector2i(8_000_000, 0), 0, 4, false),
	]
	check(world.publish_snapshot(0, 1, bodies, [], generation, token),
		"complete tick-zero body snapshot publishes while preparing")
	var digest := world.snapshot_digest()
	check(digest.length() == 64, "published world snapshot has a stable digest")
	var metadata := world.snapshot_metadata()
	check(int(metadata.get("body_count", -1)) == 2
		and int(metadata.get("obstruction_count", -1)) == 0,
		"metadata reports bounded body and obstruction counts")
	check(not metadata.has("origin_raw") and not metadata.has("bodies"),
		"metadata does not expose hidden live pose geometry")
	check(String(metadata.get("profile_digest", ""))
		== ZerkovBodyHitboxProfile.declaration_digest(),
		"snapshot is sealed against the exact hitbox profile")

	# Input mutation after publication cannot change the stored snapshot.
	bodies[0]["origin_raw"] = Vector2i(500_000_000, 500_000_000)
	check(world.snapshot_digest() == digest,
		"caller mutation cannot alter published authoritative geometry")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"fixture authority activates after world publication")

	var zone_points := [
		[ZerkovHealthAbilityContent.ZONE_HEAD, Vector2i(0, -600_000),
			ZerkovBodyHitboxProfile.HITBOX_HEAD, ZerkovBodyHitboxProfile.GROUP_HEAD],
		[ZerkovHealthAbilityContent.ZONE_THORAX, Vector2i(0, -200_000),
			ZerkovBodyHitboxProfile.HITBOX_THORAX, ZerkovBodyHitboxProfile.GROUP_TORSO],
		[ZerkovHealthAbilityContent.ZONE_ABDOMEN, Vector2i(0, 200_000),
			ZerkovBodyHitboxProfile.HITBOX_ABDOMEN, ZerkovBodyHitboxProfile.GROUP_TORSO],
		[ZerkovHealthAbilityContent.ZONE_LEFT_ARM, Vector2i(-450_000, 0),
			ZerkovBodyHitboxProfile.HITBOX_LEFT_ARM, ZerkovBodyHitboxProfile.GROUP_ARM],
		[ZerkovHealthAbilityContent.ZONE_RIGHT_ARM, Vector2i(450_000, 0),
			ZerkovBodyHitboxProfile.HITBOX_RIGHT_ARM, ZerkovBodyHitboxProfile.GROUP_ARM],
		[ZerkovHealthAbilityContent.ZONE_LEFT_LEG, Vector2i(-150_000, 600_000),
			ZerkovBodyHitboxProfile.HITBOX_LEFT_LEG, ZerkovBodyHitboxProfile.GROUP_LEG],
		[ZerkovHealthAbilityContent.ZONE_RIGHT_LEG, Vector2i(150_000, 600_000),
			ZerkovBodyHitboxProfile.HITBOX_RIGHT_LEG, ZerkovBodyHitboxProfile.GROUP_LEG],
	]
	for index in zone_points.size():
		var row := zone_points[index] as Array
		var start := target_origin + (row[1] as Vector2i)
		var result := world.raycast(_query(
			context, "zone_%02d" % index, start, start + Vector2i(10_000, 0),
			BODY_LAYER, 0))
		check(bool(result.get("accepted", false)) and bool(result.get("hit", false)),
			"zone %s produces an authoritative body hit" % String(row[0]))
		check(StringName(result.get("body_zone", &"")) == StringName(row[0]),
			"zone %s maps to the exact health identifier" % String(row[0]))
		check(StringName(result.get("hitbox_id", &"")) == StringName(row[2]),
			"zone %s returns its stable hitbox identifier" % String(row[0]))
		check(StringName(result.get("anatomy_group", &"")) == StringName(row[3]),
			"zone %s returns its broader anatomy group" % String(row[0]))
		check(result.get("hit_point_raw") == start,
			"origin-inside hit uses exact zero-distance point")
		check(int(result.get("ray_fraction_numerator", -1)) == 0
			and int(result.get("ray_fraction_denominator", 0)) == 1,
			"origin-inside hit returns normalized exact rational distance")

	var replay_query := _query(
		context, "replay", target_origin + Vector2i(0, -600_000),
		target_origin + Vector2i(10_000, -600_000), BODY_LAYER, 0)
	var first := world.raycast(replay_query)
	var first_digest := String(first.get("resolution_digest", ""))
	first["body_zone"] = &"forged"
	var replay := world.raycast(replay_query)
	check(bool(replay.get("accepted", false)) and bool(replay.get("duplicate", false)),
		"identical query-ID replay returns the recorded result")
	check(StringName(replay.get("body_zone", &"")) == ZerkovHealthAbilityContent.ZONE_HEAD,
		"mutating a returned result cannot corrupt replay state")
	check(String(replay.get("resolution_digest", "")) == first_digest,
		"query replay retains the original resolution digest")
	check(world.last_query_duplicate, "world exposes the duplicate-query diagnostic")

	var divergent := replay_query.duplicate(true)
	divergent["target_raw"] = target_origin + Vector2i(20_000, -600_000)
	var divergent_result := world.raycast(divergent)
	check(not bool(divergent_result.get("accepted", true))
		and divergent_result.get("reason") == &"request_id_reused_with_different_query",
		"same query identity with divergent geometry fails closed")

	var excluded_query := _query(
		context, "excluded", target_origin + Vector2i(0, -600_000),
		target_origin + Vector2i(10_000, -600_000), BODY_LAYER, 0,
		[target.canonical_key()])
	var excluded_result := world.raycast(excluded_query)
	check(bool(excluded_result.get("accepted", false))
		and excluded_result.get("outcome") == &"miss",
		"explicit stable entity exclusion removes that body from selection")

	var miss := world.raycast(_query(
		context, "miss", Vector2i(-1_000_000, -1_000_000),
		Vector2i(-500_000, -1_000_000), BODY_LAYER, 0))
	check(bool(miss.get("accepted", false)) and not bool(miss.get("hit", true))
		and not bool(miss.get("blocked", true)) and miss.get("outcome") == &"miss",
		"a clear ray returns one explicit accepted miss")
	check(String(miss.get("resolution_digest", "")).length() == 64,
		"misses have replay-safe resolution digests")

	# Equal publication with reversed input order is an idempotent no-op.
	var canonical_bodies: Array = [
		_body(decoy, 1, Vector2i(8_000_000, 0), 0, 4, false),
		_body(target, 1, target_origin),
	]
	check(world.publish_snapshot(0, 1, canonical_bodies, [], generation, token),
		"same snapshot accepts reordered input as a duplicate")
	check(world.last_publication_duplicate and world.snapshot_digest() == digest,
		"snapshot input ordering cannot change canonical digest")


func _test_rotation_and_mask_contract() -> void:
	var context := _new_context("rotation")
	var authority := context["authority"] as RaidAuthority
	var world := context["world"] as BodyHitboxWorld2D
	var generation := int(context["generation"])
	var token := int(context["token"])
	var rotated := _entity("rotation_target")
	var hidden := _entity("rotation_hidden")
	var origin := Vector2i(2_000_000, 2_000_000)
	check(world.publish_snapshot(0, 1, [
		_body(rotated, 1, origin, 1, 4, true),
		_body(hidden, 1, origin, 0, BODY_LAYER, false),
	], [], generation, token), "rotated/masked fixture publishes")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"rotated fixture activates")
	var rotated_head_point := origin + Vector2i(600_000, 0)
	var masked_out := world.raycast(_query(
		context, "masked_out", rotated_head_point,
		rotated_head_point + Vector2i(10_000, 0), BODY_LAYER, 0))
	check(masked_out.get("outcome") == &"miss",
		"collision masks and targetable state both fail closed")
	var rotated_hit := world.raycast(_query(
		context, "rotated_head", rotated_head_point,
		rotated_head_point + Vector2i(10_000, 0), 4, 0))
	check(bool(rotated_hit.get("hit", false))
		and rotated_hit.get("body_zone") == ZerkovHealthAbilityContent.ZONE_HEAD,
		"quarter-turn pose rotates head geometry with exact integer coordinates")
	check(rotated_hit.get("entity_id") == rotated.canonical_key(),
		"masked query returns only its eligible stable entity")


func _new_context(label: String) -> Dictionary:
	var raid := ZRaidId.from_parts(PackedStringArray(["hitbox", label]))
	var admission := SessionCoordinator.new().open_offline(raid, StringName(label), &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 11), "%s authority configures" % label)
	var generation := authority.generation()
	var world := BodyHitboxWorld2D.new()
	check(world.bind_raid_authority(authority, generation),
		"%s body world binds during preparing" % label)
	return {
		"authority": authority,
		"world": world,
		"generation": generation,
		"token": world.binding_token(),
	}


func _entity(label: String) -> ZEntityId:
	return ZEntityId.from_parts(PackedStringArray(["hitbox", label]))


func _body(
	entity: ZEntityId,
	revision: int,
	origin: Vector2i,
	facing: int = 0,
	layer: int = BODY_LAYER,
	targetable: bool = true
) -> Dictionary:
	return {
		"entity_id": entity.canonical_key(),
		"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1),
		"body_revision": revision,
		"origin_raw": origin,
		"facing_quarter_turns": facing,
		"collision_layer": layer,
		"targetable": targetable,
	}


func _query(
	context: Dictionary,
	label: String,
	origin: Vector2i,
	target: Vector2i,
	body_mask: int,
	obstruction_mask: int,
	exclusions: Array = []
) -> Dictionary:
	var world := context["world"] as BodyHitboxWorld2D
	var request := ZRequestId.from_parts(PackedStringArray(["hitbox", label]))
	return {
		"request_id": request.canonical_key(),
		"authority_generation": int(context["generation"]),
		"binding_token": int(context["token"]),
		"tick": world.snapshot_tick(),
		"world_revision": world.snapshot_revision(),
		"origin_raw": origin,
		"target_raw": target,
		"body_mask": body_mask,
		"obstruction_mask": obstruction_mask,
		"excluded_entity_ids": exclusions.duplicate(),
	}
