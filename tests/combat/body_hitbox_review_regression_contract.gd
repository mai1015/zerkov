extends SceneTree
## Permanent reviewer-regression coverage for exact binding provenance,
## same-world metadata isolation, authorized actor ownership, and recursively
## immutable publications.

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
	push_error("BODY_HITBOX_REVIEW_REGRESSION: " + message)


func run() -> void:
	_test_cross_instance_capability_aba()
	_test_same_world_metadata_rebind()
	_test_authorized_actor_and_publisher_port()
	_test_immutable_publication_families()
	print("BODY_HITBOX_REVIEW_REGRESSION_RESULT checks=", checks,
		" failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_cross_instance_capability_aba() -> void:
	# Independent coordinators deliberately reproduce every stable public ID and
	# both numeric counters. Exact capability identity is the differentiator.
	var first := _new_context("review_aba")
	var second := _new_context("review_aba")
	var first_world := first["world"] as BodyHitboxWorld2D
	var second_world := second["world"] as BodyHitboxWorld2D
	var target := _entity("review_aba_target")
	check(not first_world.has_method(&"binding_capability"),
		"stale world holders cannot look up the active bearer after rebind")
	_authorize_actor(first, target, ZRaidIntent.Source.AI)
	_authorize_actor(second, target, ZRaidIntent.Source.AI)
	check(first["raid_id"] == second["raid_id"]
		and first["session_id"] == second["session_id"]
		and first["owner_actor_id"] == second["owner_actor_id"]
		and first["authority_epoch"] == second["authority_epoch"]
		and first["generation"] == 1 and second["generation"] == 1
		and first["token"] == 1 and second["token"] == 1,
		"ABA fixture repeats raid/session/owner/epoch/generation/token exactly")
	var first_provenance := first_world.binding_provenance(first["capability"])
	var second_provenance := second_world.binding_provenance(second["capability"])
	check(first_provenance.is_read_only() and second_provenance.is_read_only(),
		"binding provenance publications are immutable")
	check(first_provenance.get("world_instance_id")
		!= second_provenance.get("world_instance_id")
		and first_provenance.get("authority_instance_id")
		!= second_provenance.get("authority_instance_id")
		and first_provenance.get("capability_instance_id")
		!= second_provenance.get("capability_instance_id"),
		"capability provenance records concrete world/authority/bearer instances")

	var first_body := _body(target, 1, Vector2i(5_000_000, 0))
	var second_body := _body(target, 1, Vector2i.ZERO)
	check(_publish(first, 0, 1, [first_body], []),
		"first same-ID world publishes with its own capability")
	check(not second_world.publish_snapshot(
		0, 1, [second_body], [], int(second["generation"]), int(second["token"]),
		second["owner_actor"], int(second["owner_source"]), first["capability"])
		and second_world.last_error == &"binding_capability_mismatch"
		and int(_snapshot_metadata(second).get("world_revision", -1)) == 0,
		"world-A capability cannot publish into same-numbered world B")
	check(_publish(second, 0, 1, [second_body], []),
		"second same-ID world publishes with its own capability")
	check(not second_world.publish_snapshot(
		0, 1, [], [], int(second["generation"]), int(second["token"]),
		second["owner_actor"], int(second["owner_source"]), first["capability"])
		and second_world.last_error == &"binding_capability_mismatch"
		and int(_snapshot_metadata(second).get("world_revision", 0)) == 1,
		"foreign capability cannot remove geometry from the current binding")
	check((first["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(first["generation"])),
		"first ABA authority activates")
	check((second["authority"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE, int(second["generation"])),
		"second ABA authority activates")

	var query := _query(
		second, "review_aba_query", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0)
	var stolen_result := second_world.raycast(query, first["capability"])
	check(not bool(stolen_result.get("accepted", true))
		and stolen_result.get("reason") == &"binding_capability_mismatch"
		and stolen_result.is_read_only(),
		"stolen foreign capability cannot query same-ID replacement geometry")
	var forged_result := second_world.raycast(query, RefCounted.new())
	check(not bool(forged_result.get("accepted", true))
		and forged_result.get("reason") == &"binding_capability_mismatch",
		"newly forged capability object cannot authenticate")
	var accepted := _ray(second, query)
	check(bool(accepted.get("hit", false))
		and accepted.get("entity_id") == target.canonical_key(),
		"current exact capability reaches only its world geometry")
	var stolen_replay := second_world.raycast(query, first["capability"])
	check(not bool(stolen_replay.get("accepted", true))
		and stolen_replay.get("reason") == &"binding_capability_mismatch",
		"foreign capability cannot replay a recorded current-binding result")
	var replay := _ray(second, query)
	check(bool(replay.get("duplicate", false))
		and replay.get("resolution_digest") == accepted.get("resolution_digest"),
		"current capability replays the exact recorded result")

	# Dropping the first world leaves its capability alive, then proves that a
	# capability outliving its issuer still cannot authenticate to world B.
	first["world"] = null
	first_world = null
	var freed_world_capability := second_world.raycast(query, first["capability"])
	check(freed_world_capability.get("reason") == &"binding_capability_mismatch",
		"capability retained after issuer destruction cannot authenticate elsewhere")


func _test_same_world_metadata_rebind() -> void:
	var first := _new_context("review_metadata_first")
	var world := first["world"] as BodyHitboxWorld2D
	var first_capability: Variant = first["capability"]
	var first_target := _entity("review_metadata_first_target")
	_authorize_actor(first, first_target, ZRaidIntent.Source.AI)
	check(_publish(first, 0, 1, [_body(first_target, 1, Vector2i.ZERO)], []),
		"first metadata binding publishes")
	var first_metadata := world.snapshot_metadata(first_capability)
	check(int(first_metadata.get("world_revision", 0)) == 1
		and String(first_metadata.get("snapshot_digest", "")).length() == 64,
		"first metadata is readable only with its exact capability")
	check(world.release_binding(first_capability),
		"first metadata binding releases before same-world replacement")

	var replacement_raid := ZRaidId.from_parts(
		PackedStringArray(["hitbox", "review_metadata_replacement"]))
	var replacement_admission := SessionCoordinator.new().open_offline(
		replacement_raid, &"review_metadata_replacement", &"player")
	var replacement_authority := RaidAuthority.new()
	check(replacement_authority.configure(
		replacement_raid, replacement_admission, 41),
		"replacement metadata authority configures")
	var replacement_generation := replacement_authority.generation()
	var replacement_owner := ZEntityId.parse(
		replacement_admission.actor_id.canonical_key())
	var replacement_capability := world.bind_raid_authority(
		replacement_authority, replacement_owner, ZRaidIntent.Source.PLAYER,
		replacement_generation)
	check(replacement_capability != null,
		"same world binds a replacement raid with a new exact capability")
	var replacement_provenance := world.binding_provenance(replacement_capability)
	var replacement := {
		"authority": replacement_authority,
		"world": world,
		"generation": replacement_generation,
		"token": int(replacement_provenance.get("binding_token", 0)),
		"capability": replacement_capability,
		"owner_actor": replacement_owner,
		"owner_actor_id": replacement_owner.canonical_key(),
		"owner_source": int(ZRaidIntent.Source.PLAYER),
		"raid_id": replacement_raid.canonical_key(),
		"session_id": replacement_admission.session_id.canonical_key(),
		"authority_epoch": replacement_admission.authority_epoch,
		"query_actor": replacement_owner,
		"query_source": int(ZRaidIntent.Source.PLAYER),
	}
	var replacement_target := _entity("review_metadata_replacement_target")
	_authorize_actor(replacement, replacement_target, ZRaidIntent.Source.AI)
	check(_publish(replacement, 0, 1, [
		_body(replacement_target, 1, Vector2i(4_000_000, 0))], []),
		"same-world replacement publishes distinct geometry")
	var replacement_metadata := world.snapshot_metadata(replacement_capability)
	check(String(replacement_metadata.get("raid_id", ""))
		== replacement_raid.canonical_key()
		and String(replacement_metadata.get("snapshot_digest", ""))
			!= String(first_metadata.get("snapshot_digest", "")),
		"current capability reads the replacement raid metadata")

	for method_name in PackedStringArray([
		"is_bound",
		"binding_token",
		"authority_generation",
		"snapshot_tick",
		"snapshot_revision",
		"snapshot_digest",
	]):
		check(not world.has_method(StringName(method_name)),
			"redundant unauthenticated metadata getter is not public: %s" % method_name)
	var stale_metadata := world.snapshot_metadata(first_capability)
	check(stale_metadata.is_empty() and stale_metadata.is_read_only()
		and world.last_error == &"binding_capability_mismatch",
		"stale same-world capability cannot observe replacement snapshot metadata")
	var stale_provenance := world.binding_provenance(first_capability)
	check(stale_provenance.is_empty() and stale_provenance.is_read_only()
		and world.last_error == &"binding_capability_mismatch",
		"stale same-world capability cannot observe replacement binding metadata")


func _test_authorized_actor_and_publisher_port() -> void:
	var rejected_raid := ZRaidId.from_parts(
		PackedStringArray(["hitbox", "review_rejected_owner"]))
	var rejected_admission := SessionCoordinator.new().open_offline(
		rejected_raid, &"review_rejected_owner", &"player")
	var rejected_authority := RaidAuthority.new()
	check(rejected_authority.configure(rejected_raid, rejected_admission, 39),
		"rejected-owner authority configures")
	var rejected_world := BodyHitboxWorld2D.new()
	var rejected_capability := rejected_world.bind_raid_authority(
		rejected_authority, _entity("review_foreign_owner"),
		ZRaidIntent.Source.AI, rejected_authority.generation())
	check(rejected_capability == null
		and rejected_world.last_error == &"binding_owner_not_authorized",
		"world binding owner must belong to the authority actor/source set")

	var context := _new_context("review_authorization")
	var world := context["world"] as BodyHitboxWorld2D
	var authority := context["authority"] as RaidAuthority
	var authorized := _entity("review_authorized")
	var unauthorized := _entity("review_unauthorized")
	_authorize_actor(context, authorized, ZRaidIntent.Source.AI)
	check(authority.has_authorized_actor_source(
		authorized, ZRaidIntent.Source.AI, int(context["generation"])),
		"RaidAuthority exposes an exact side-effect-free actor/source check")
	check(not authority.has_authorized_actor_source(
		unauthorized, ZRaidIntent.Source.AI, int(context["generation"])),
		"authorization port fails closed for an absent actor")
	check(not _publish(context, 0, 1, [_body(unauthorized, 1, Vector2i.ZERO)], [])
		and world.last_error == &"body_actor_not_authorized",
		"well-formed unauthorized entity cannot publish authoritative hitboxes")
	check(not _publish(context, 0, 1, [
		_body(authorized, 1, Vector2i.ZERO, ZRaidIntent.Source.SYSTEM)], [])
		and world.last_error == &"body_actor_not_authorized",
		"authorization is exact across actor/source pairs")
	check(not world.publish_snapshot(
		0, 1, [_body(authorized, 1, Vector2i.ZERO)], [],
		int(context["generation"]), int(context["token"]),
		unauthorized, ZRaidIntent.Source.AI, context["capability"])
		and world.last_error == &"snapshot_publisher_mismatch",
		"valid capability cannot forge a different publisher identity")
	check(_publish(context, 0, 1, [_body(authorized, 1, Vector2i.ZERO)], []),
		"authorized entity publishes through the exact binding owner")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, int(context["generation"])),
		"authorization fixture activates")
	var forged_query := _query(
		context, "review_forged_actor", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0)
	forged_query["query_actor_id"] = unauthorized.canonical_key()
	forged_query["query_actor_source"] = int(ZRaidIntent.Source.AI)
	var rejection := _ray(context, forged_query)
	check(rejection.get("reason") == &"ray_query_actor_not_authorized"
		and rejection.is_read_only(),
		"query actor must belong to the explicit authorization set")


func _test_immutable_publication_families() -> void:
	var declarations := ZerkovBodyHitboxProfile.declarations()
	var declaration := ZerkovBodyHitboxProfile.declaration(
		ZerkovBodyHitboxProfile.HITBOX_HEAD)
	var missing_declaration := ZerkovBodyHitboxProfile.declaration(&"missing")
	var validation := ZerkovBodyHitboxProfile.validate()
	var hitboxes := ZerkovBodyHitboxProfile.build_world_hitboxes(Vector2i.ZERO, 0)
	var invalid_hitboxes := ZerkovBodyHitboxProfile.build_world_hitboxes(Vector2i.ZERO, 9)
	check(_is_deep_read_only(declarations),
		"profile declarations and every nested entry are immutable")
	check(declaration.is_read_only() and missing_declaration.is_read_only(),
		"single and missing profile declaration results are immutable")
	check(_is_deep_read_only(validation),
		"profile validation and nested findings are immutable")
	check(_is_deep_read_only(hitboxes) and invalid_hitboxes.is_read_only(),
		"valid and rejected world-hitbox publications are immutable")

	var context := _new_context("review_immutable")
	var authority := context["authority"] as RaidAuthority
	var target := _entity("review_immutable_target")
	_authorize_actor(context, target, ZRaidIntent.Source.AI)
	var obstruction := {
		"obstruction_id": "zerkov.obstruction.hitbox.review_immutable",
		"geometry_revision": 1,
		"min_raw": Vector2i(-100, 900_000),
		"max_raw": Vector2i(100, 1_100_000),
		"collision_layer": OBSTRUCTION_LAYER,
		"enabled": true,
	}
	check(_publish(context, 0, 1, [_body(target, 1, Vector2i.ZERO)], [obstruction]),
		"immutable-publication fixture publishes")
	var metadata := (context["world"] as BodyHitboxWorld2D).snapshot_metadata(
		context["capability"])
	check(_is_deep_read_only(metadata),
		"snapshot metadata and nested provenance are recursively immutable")
	var metadata_probe := metadata.duplicate(true)
	metadata_probe["snapshot_digest"] = String("0").repeat(64)
	(metadata_probe["binding_provenance"] as Dictionary)["raid_id"] = "forged"
	var metadata_again := (context["world"] as BodyHitboxWorld2D).snapshot_metadata(
		context["capability"])
	check(metadata_again.get("snapshot_digest") == metadata.get("snapshot_digest")
		and (metadata_again["binding_provenance"] as Dictionary).get("raid_id")
			== context["raid_id"],
		"detached metadata mutation probe cannot rewrite snapshot or provenance")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, int(context["generation"])),
		"immutable-publication fixture activates")

	var hit_query := _query(
		context, "review_immutable_hit", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0)
	var hit := _ray(context, hit_query)
	check(hit.is_read_only() and bool(hit.get("hit", false)),
		"accepted hit publication is immutable")
	var expected_entity := String(hit.get("entity_id", ""))
	var expected_zone := StringName(hit.get("body_zone", &""))
	var expected_digest := String(hit.get("resolution_digest", ""))
	var mutation_probe := hit.duplicate(true)
	mutation_probe["accepted"] = false
	mutation_probe["entity_id"] = "zerkov.entity.hitbox.forged"
	mutation_probe["body_zone"] = &"forged"
	mutation_probe["resolution_digest"] = String("0").repeat(64)
	var replay := _ray(context, hit_query)
	check(replay.is_read_only() and bool(replay.get("duplicate", false)),
		"replay result publication is immutable")
	check(bool(replay.get("accepted", false))
		and String(replay.get("entity_id", "")) == expected_entity
		and StringName(replay.get("body_zone", &"")) == expected_zone
		and String(replay.get("resolution_digest", "")) == expected_digest,
		"detached mutation probe cannot rewrite accepted/entity/zone/digest in ledger")

	var miss := _ray(context, _query(
		context, "review_immutable_miss", Vector2i(1_000_000, -1_000_000),
		Vector2i(1_100_000, -1_000_000), BODY_LAYER, 0))
	check(miss.is_read_only() and miss.get("outcome") == &"miss",
		"accepted miss publication is immutable")
	var blocked := _ray(context, _query(
		context, "review_immutable_obstruction", Vector2i(0, 800_000),
		Vector2i(0, 1_200_000), 0, OBSTRUCTION_LAYER))
	check(blocked.is_read_only() and bool(blocked.get("blocked", false)),
		"accepted obstruction publication is immutable")
	var malformed := _ray(context, 7)
	check(malformed.is_read_only()
		and malformed.get("reason") == &"ray_query_type_invalid",
		"malformed-input rejection publication is immutable")
	var divergent_query := hit_query.duplicate(true)
	divergent_query["target_raw"] = Vector2i(20_000, -600_000)
	var replay_rejection := _ray(context, divergent_query)
	check(replay_rejection.is_read_only()
		and replay_rejection.get("reason") == &"request_id_reused_with_different_query",
		"replay-divergence rejection publication is immutable")


func _new_context(label: String) -> Dictionary:
	var raid := ZRaidId.from_parts(PackedStringArray(["hitbox", label]))
	var admission := SessionCoordinator.new().open_offline(raid, StringName(label), &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 37), "%s authority configures" % label)
	var generation := authority.generation()
	var owner_actor := ZEntityId.parse(admission.actor_id.canonical_key())
	var owner_source := ZRaidIntent.Source.PLAYER
	var world := BodyHitboxWorld2D.new()
	var capability := world.bind_raid_authority(
		authority, owner_actor, owner_source, generation)
	check(capability != null, "%s world binds" % label)
	var provenance := world.binding_provenance(capability)
	return {
		"authority": authority,
		"world": world,
		"generation": generation,
		"token": int(provenance.get("binding_token", 0)),
		"capability": capability,
		"owner_actor": owner_actor,
		"owner_actor_id": owner_actor.canonical_key(),
		"owner_source": int(owner_source),
		"raid_id": raid.canonical_key(),
		"session_id": admission.session_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"query_actor": owner_actor,
		"query_source": int(owner_source),
	}


func _authorize_actor(
	context: Dictionary,
	actor: ZEntityId,
	source: ZRaidIntent.Source
) -> void:
	check((context["authority"] as RaidAuthority).authorize_actor(
		actor, source, int(context["generation"])),
		"fixture actor/source authorization succeeds")


func _entity(label: String) -> ZEntityId:
	return ZEntityId.from_parts(PackedStringArray(["hitbox", label]))


func _body(
	entity: ZEntityId,
	revision: int,
	origin: Vector2i,
	actor_source: ZRaidIntent.Source = ZRaidIntent.Source.AI
) -> Dictionary:
	return {
		"entity_id": entity.canonical_key(),
		"actor_source": int(actor_source),
		"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1),
		"body_revision": revision,
		"origin_raw": origin,
		"facing_quarter_turns": 0,
		"collision_layer": BODY_LAYER,
		"targetable": true,
	}


func _publish(
	context: Dictionary,
	tick: int,
	revision: int,
	bodies: Array,
	obstructions: Array
) -> bool:
	return (context["world"] as BodyHitboxWorld2D).publish_snapshot(
		tick, revision, bodies, obstructions,
		int(context["generation"]), int(context["token"]),
		context["owner_actor"], int(context["owner_source"]),
		context["capability"])


func _query(
	context: Dictionary,
	label: String,
	origin: Vector2i,
	target: Vector2i,
	body_mask: int,
	obstruction_mask: int
) -> Dictionary:
	var metadata := _snapshot_metadata(context)
	return {
		"request_id": ZRequestId.from_parts(
			PackedStringArray(["hitbox", label])).canonical_key(),
		"raid_id": String(context["raid_id"]),
		"session_id": String(context["session_id"]),
		"authority_epoch": int(context["authority_epoch"]),
		"authority_generation": int(context["generation"]),
		"binding_token": int(context["token"]),
		"owner_actor_id": String(context["owner_actor_id"]),
		"owner_actor_source": int(context["owner_source"]),
		"query_actor_id": (context["query_actor"] as ZEntityId).canonical_key(),
		"query_actor_source": int(context["query_source"]),
		"tick": int(metadata.get("tick", -1)),
		"world_revision": int(metadata.get("world_revision", 0)),
		"origin_raw": origin,
		"target_raw": target,
		"body_mask": body_mask,
		"obstruction_mask": obstruction_mask,
		"excluded_entity_ids": [],
	}


func _ray(context: Dictionary, query: Variant) -> Dictionary:
	return (context["world"] as BodyHitboxWorld2D).raycast(
		query, context["capability"])


func _snapshot_metadata(context: Dictionary) -> Dictionary:
	return (context["world"] as BodyHitboxWorld2D).snapshot_metadata(
		context["capability"])


func _is_deep_read_only(value: Variant) -> bool:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			if not dictionary.is_read_only():
				return false
			for key in dictionary.keys():
				if not _is_deep_read_only(dictionary[key]):
					return false
		TYPE_ARRAY:
			var array := value as Array
			if not array.is_read_only():
				return false
			for entry in array:
				if not _is_deep_read_only(entry):
					return false
	return true
