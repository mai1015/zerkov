extends SceneTree
## Adversarial task-5.3 overlap, obstruction, ordering, input, and lifecycle
## contract. No Weapon System or Gameplay Abilities mutation is performed.

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
	push_error("BODY_HITBOX_ADVERSARIAL: " + message)


func run() -> void:
	_test_overlap_and_tie_policy()
	_test_obstruction_policy()
	_test_input_order_independence()
	_test_snapshot_adversaries()
	_test_obstruction_revision_lifecycle()
	_test_query_adversaries()
	_test_lifecycle_and_rebind()
	_test_query_capacity()
	print("BODY_HITBOX_ADVERSARIAL_RESULT checks=", checks,
		" failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_overlap_and_tie_policy() -> void:
	var context := _active_context("overlap", [
		_body(_entity("overlap_beta"), 1, Vector2i.ZERO),
		_body(_entity("overlap_alpha"), 1, Vector2i.ZERO),
	], [])
	var world := context["world"] as BodyHitboxWorld2D
	var actor_tie := _ray(context, _query(
		context, "actor_tie", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0))
	check(actor_tie.get("entity_id") == _entity("overlap_alpha").canonical_key(),
		"equal-distance overlapping actors use lexical stable entity ID")
	check(actor_tie.get("body_zone") == ZerkovHealthAbilityContent.ZONE_HEAD,
		"actor tie still preserves exact body-zone mapping")

	var torso_seam := _ray(context, _query(
		context, "torso_seam", Vector2i(0, 75_000),
		Vector2i(10_000, 75_000), BODY_LAYER, 0,
		[_entity("overlap_beta").canonical_key()]))
	check(torso_seam.get("entity_id") == _entity("overlap_alpha").canonical_key()
		and torso_seam.get("body_zone") == ZerkovHealthAbilityContent.ZONE_THORAX,
		"thorax wins its exact authored overlap with abdomen")
	check(torso_seam.get("hitbox_id")
		== String(ZerkovBodyHitboxProfile.HITBOX_THORAX),
		"torso overlap returns the stable winning hitbox ID")

	var limb_seam := _ray(context, _query(
		context, "limb_seam", Vector2i(-275_000, 0),
		Vector2i(-265_000, 0), BODY_LAYER, 0,
		[_entity("overlap_beta").canonical_key()]))
	check(limb_seam.get("body_zone") == ZerkovHealthAbilityContent.ZONE_THORAX,
		"torso priority deterministically wins an exact arm overlap")

	var rational := _ray(context, _query(
		context, "rational", Vector2i(-1_000_000, -600_000),
		Vector2i(2_000_000, -600_000), BODY_LAYER, 0,
		[_entity("overlap_beta").canonical_key()]))
	check(rational.get("body_zone") == ZerkovHealthAbilityContent.ZONE_HEAD,
		"non-integral entry resolves the expected head")
	check(int(rational.get("ray_fraction_numerator", -1)) == 13
		and int(rational.get("ray_fraction_denominator", -1)) == 50,
		"ray entry fraction is reduced exactly instead of float-rounded")
	check(rational.get("hit_point_raw") == Vector2i(-220_000, -600_000),
		"exact rational intersection produces the canonical integer boundary")
	var reverse := _ray(context, _query(
		context, "reverse", Vector2i(1_000_000, -600_000),
		Vector2i(-1_000_000, -600_000), BODY_LAYER, 0,
		[_entity("overlap_beta").canonical_key()]))
	check(reverse.get("hit_point_raw") == Vector2i(220_000, -600_000)
		and int(reverse.get("ray_fraction_numerator", -1)) == 39
		and int(reverse.get("ray_fraction_denominator", -1)) == 100,
		"negative-direction ray uses the same exact slab ordering")


func _test_obstruction_policy() -> void:
	var target := _entity("obstruction_target")
	var tie_context := _active_context("obstruction_tie", [
		_body(target, 1, Vector2i.ZERO),
	], [
		_obstruction("tie", 1, Vector2i(-220_000, -700_000),
			Vector2i(-100_000, -500_000)),
	])
	var tie := _ray(tie_context, _query(
		tie_context, "obstruction_body_tie", Vector2i(-1_000_000, -600_000),
		Vector2i(1_000_000, -600_000), BODY_LAYER, OBSTRUCTION_LAYER))
	check(bool(tie.get("accepted", false)) and bool(tie.get("blocked", false))
		and not bool(tie.get("hit", true)),
		"obstruction wins an exact distance tie with a body fail-closed")
	check(tie.get("obstruction_id") == "zerkov.obstruction.hitbox.tie",
		"tie result reports the stable obstruction identity")
	check(int(tie.get("ray_fraction_numerator", -1)) == 39
		and int(tie.get("ray_fraction_denominator", -1)) == 100,
		"body/obstruction tie retains exact rational distance")

	var lexical_context := _active_context("obstruction_lexical", [], [
		_obstruction("beta", 1, Vector2i(-100_000, -100_000),
			Vector2i(100_000, 100_000)),
		_obstruction("alpha", 1, Vector2i(-100_000, -100_000),
			Vector2i(100_000, 100_000)),
	])
	var lexical := _ray(lexical_context, _query(
		lexical_context, "obstruction_lexical", Vector2i(-1_000_000, 0),
		Vector2i(1_000_000, 0), 0, OBSTRUCTION_LAYER))
	check(lexical.get("obstruction_id") == "zerkov.obstruction.hitbox.alpha",
		"equal-distance obstructions use lexical stable obstruction ID")

	var behind_context := _active_context("obstruction_behind", [
		_body(target, 1, Vector2i.ZERO),
	], [
		_obstruction("behind", 1, Vector2i(300_000, -700_000),
			Vector2i(400_000, -500_000)),
	])
	var behind := _ray(behind_context, _query(
		behind_context, "obstruction_behind", Vector2i(-1_000_000, -600_000),
		Vector2i(1_000_000, -600_000), BODY_LAYER, OBSTRUCTION_LAYER))
	check(bool(behind.get("hit", false)) and not bool(behind.get("blocked", true)),
		"an obstruction behind the nearest body does not erase the body hit")

	var ahead_context := _active_context("obstruction_ahead", [
		_body(target, 1, Vector2i.ZERO),
	], [
		_obstruction("ahead", 1, Vector2i(-500_000, -700_000),
			Vector2i(-400_000, -500_000)),
	])
	var ahead := _ray(ahead_context, _query(
		ahead_context, "obstruction_ahead", Vector2i(-1_000_000, -600_000),
		Vector2i(1_000_000, -600_000), BODY_LAYER, OBSTRUCTION_LAYER))
	check(bool(ahead.get("blocked", false)) and ahead.get("outcome") == &"obstruction",
		"a nearer enabled obstruction explicitly blocks the body")

	var masked_context := _active_context("obstruction_masked", [
		_body(target, 1, Vector2i.ZERO),
	], [
		_obstruction("masked", 1, Vector2i(-500_000, -700_000),
			Vector2i(-400_000, -500_000), 4),
		_obstruction("disabled", 1, Vector2i(-600_000, -700_000),
			Vector2i(-550_000, -500_000), OBSTRUCTION_LAYER, false),
	])
	var masked := _ray(masked_context, _query(
		masked_context, "obstruction_masked", Vector2i(-1_000_000, -600_000),
		Vector2i(1_000_000, -600_000), BODY_LAYER, OBSTRUCTION_LAYER))
	check(bool(masked.get("hit", false)),
		"disabled and collision-masked obstruction geometry cannot block")

	var boundary_context := _active_context("obstruction_boundary", [], [
		_obstruction("boundary", 1, Vector2i(-10, -10), Vector2i(10, 10)),
	])
	var boundary := _ray(boundary_context, _query(
		boundary_context, "obstruction_boundary",
		Vector2i(-BodyHitboxWorld2D.MAX_COORDINATE_RAW, 0),
		Vector2i(BodyHitboxWorld2D.MAX_COORDINATE_RAW, 0),
		0, OBSTRUCTION_LAYER))
	check(bool(boundary.get("blocked", false))
		and boundary.get("hit_point_raw") == Vector2i(-10, 0),
		"maximum admitted ray span remains exact without integer overflow")


func _test_input_order_independence() -> void:
	var alpha := _entity("ordering_alpha")
	var beta := _entity("ordering_beta")
	var body_alpha := _body(alpha, 1, Vector2i.ZERO)
	var body_beta := _body(beta, 1, Vector2i.ZERO)
	var obstruction_alpha := _obstruction(
		"ordering_alpha", 1, Vector2i(900_000, 900_000), Vector2i(950_000, 950_000))
	var obstruction_beta := _obstruction(
		"ordering_beta", 1, Vector2i(1_000_000, 900_000), Vector2i(1_050_000, 950_000))
	var first := _active_context("ordering_first",
		[body_beta, body_alpha], [obstruction_beta, obstruction_alpha])
	var second := _active_context("ordering_second",
		[body_alpha, body_beta], [obstruction_alpha, obstruction_beta])
	var first_world := first["world"] as BodyHitboxWorld2D
	var second_world := second["world"] as BodyHitboxWorld2D
	check(first_world.snapshot_digest() == second_world.snapshot_digest(),
		"snapshot digest is independent of body and obstruction Array order")
	var first_result := _ray(first, _query(
		first, "ordering_first_query", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, OBSTRUCTION_LAYER))
	var second_result := _ray(second, _query(
		second, "ordering_second_query", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, OBSTRUCTION_LAYER))
	check(first_result.get("entity_id") == second_result.get("entity_id")
		and first_result.get("hitbox_id") == second_result.get("hitbox_id"),
		"selection is independent of publication and dictionary iteration order")
	check(first_result.get("entity_id") == alpha.canonical_key(),
		"stable lexical entity tie-break is the documented winner")


func _test_snapshot_adversaries() -> void:
	var context := _new_context("snapshot_adversary")
	var authority := context["authority"] as RaidAuthority
	var world := context["world"] as BodyHitboxWorld2D
	var generation := int(context["generation"])
	var token := int(context["token"])
	var target := _entity("snapshot_target")
	var initial := _body(target, 1, Vector2i.ZERO)
	_authorize_bodies(context, [initial])
	check(_publish(context, 0, 1, [initial], []),
		"adversarial fixture publishes initial snapshot")
	var initial_digest := world.snapshot_digest()

	var added_at_equal := _body(_entity("snapshot_added"), 1, Vector2i(2_000_000, 0))
	_authorize_bodies(context, [added_at_equal])
	check(not _publish(context, 0, 1, [initial, added_at_equal], [])
		and world.last_error == &"equal_snapshot_revision_divergence",
		"equal world revision cannot smuggle an additional body")
	check(world.snapshot_revision() == 1 and world.snapshot_digest() == initial_digest,
		"equal-revision divergence is fail-atomic")
	var unauthorized := _body(
		_entity("snapshot_unauthorized"), 1, Vector2i(3_000_000, 0))
	check(not _publish(context, 0, 1, [initial, unauthorized], [])
		and world.last_error == &"body_actor_not_authorized",
		"well-formed body absent from the explicit actor authorization set is rejected")
	check(not world.publish_snapshot(
		0, 1, [initial], [], generation, token,
		_entity("snapshot_stolen_publisher"), ZRaidIntent.Source.AI,
		context["capability"])
		and world.last_error == &"snapshot_publisher_mismatch",
		"binding capability cannot be presented as a different snapshot publisher")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"snapshot adversary authority activates")
	check(authority.advance_one(generation), "snapshot adversary advances to tick one")

	var malformed := initial.duplicate(true)
	malformed["unexpected"] = true
	_check_failed_publication(world, context, 1, 2, [malformed], [],
		&"body_record_schema_invalid", "extra body key")
	malformed = initial.duplicate(true)
	malformed["origin_raw"] = 1.5
	_check_failed_publication(world, context, 1, 2, [malformed], [],
		&"body_record_field_type_invalid", "floating body transform")
	malformed = initial.duplicate(true)
	malformed["entity_id"] = "forged"
	_check_failed_publication(world, context, 1, 2, [malformed], [],
		&"body_entity_id_invalid", "forged body entity")
	malformed = initial.duplicate(true)
	malformed["origin_raw"] = Vector2i(BodyHitboxWorld2D.MAX_COORDINATE_RAW, 0)
	_check_failed_publication(world, context, 1, 2, [malformed], [],
		&"body_hitbox_out_of_bounds", "body whose generated shape exceeds bounds")
	_check_failed_publication(world, context, 1, 2, [initial, initial], [],
		&"body_entity_duplicate", "duplicate body identity")

	var too_many_bodies: Array = []
	for index in BodyHitboxWorld2D.MAX_BODIES + 1:
		too_many_bodies.append(_body(
			_entity("snapshot_cap_%03d" % index), 1, Vector2i(index * 1_000_000, 0)))
	_check_failed_publication(world, context, 1, 2, too_many_bodies, [],
		&"body_capacity_exceeded", "body snapshot capacity overflow")
	var too_many_obstructions: Array = []
	for index in BodyHitboxWorld2D.MAX_OBSTRUCTIONS + 1:
		too_many_obstructions.append(_obstruction(
			"snapshot_cap_%03d" % index, 1,
			Vector2i(index * 1000, 0), Vector2i(index * 1000 + 10, 10)))
	_check_failed_publication(world, context, 1, 2, [initial], too_many_obstructions,
		&"obstruction_capacity_exceeded", "obstruction snapshot capacity overflow")

	var bad_obstruction := _obstruction(
		"bad_geometry", 1, Vector2i(10, 10), Vector2i(0, 0))
	_check_failed_publication(world, context, 1, 2, [initial], [bad_obstruction],
		&"obstruction_geometry_invalid", "reversed obstruction AABB")
	check(world.snapshot_revision() == 1 and world.snapshot_digest() == initial_digest,
		"all malformed snapshot attempts preserve the prior committed state")

	check(_publish(context, 1, 2, [initial], []),
		"valid unchanged body publishes at the next tick/revision")
	check(authority.advance_one(generation), "snapshot adversary advances to removal tick")
	check(_publish(context, 2, 3, [], []),
		"complete snapshot omission removes the body")
	check(authority.advance_one(generation), "snapshot adversary advances to re-add tick")
	check(not _publish(context, 3, 4, [initial], [])
		and world.last_error == &"body_stale_resurrection",
		"removed body cannot be resurrected with its stale revision")
	var readded := _body(target, 2, Vector2i.ZERO)
	check(_publish(context, 3, 4, [readded], []),
		"removed body may re-enter only with a newer explicit revision")
	check(authority.advance_one(generation), "snapshot adversary advances to divergence tick")
	var changed_equal := _body(target, 2, Vector2i(1, 0))
	check(not _publish(context, 4, 5, [changed_equal], [])
		and world.last_error == &"body_equal_revision_divergence",
		"changed geometry cannot reuse an equal body revision")
	var changed_new := _body(target, 3, Vector2i(1, 0))
	check(_publish(context, 4, 5, [changed_new], []),
		"new body revision admits the explicit geometry update")
	check(not _publish(context, 4, 7, [changed_new], [])
		and world.last_error == &"snapshot_revision_regressed_or_skipped",
		"world revision skips fail closed")


func _test_query_adversaries() -> void:
	var context := _active_context("query_adversary", [
		_body(_entity("query_target"), 1, Vector2i.ZERO),
	], [])
	var world := context["world"] as BodyHitboxWorld2D
	var valid := _query(
		context, "valid_base", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0)
	check(_ray(context, 7).get("reason") == &"ray_query_type_invalid",
		"non-dictionary query fails closed")
	var malformed := valid.duplicate(true)
	malformed["extra"] = true
	check(_ray(context, malformed).get("reason") == &"ray_query_schema_invalid",
		"query rejects unknown keys")
	malformed = valid.duplicate(true)
	malformed["origin_raw"] = Vector2(0.0, -600_000.0)
	check(_ray(context, malformed).get("reason") == &"ray_query_field_type_invalid",
		"floating query geometry is rejected")
	malformed = valid.duplicate(true)
	malformed["request_id"] = "forged"
	check(_ray(context, malformed).get("reason") == &"ray_query_request_id_invalid",
		"forged query identity is rejected")
	malformed = valid.duplicate(true)
	malformed["body_mask"] = 0
	check(_ray(context, malformed).get("reason") == &"ray_query_mask_invalid",
		"query with no collision domain is rejected")
	malformed = valid.duplicate(true)
	malformed["target_raw"] = malformed["origin_raw"]
	check(_ray(context, malformed).get("reason") == &"ray_query_geometry_invalid",
		"zero-length query is rejected")
	malformed = valid.duplicate(true)
	malformed["target_raw"] = Vector2i(BodyHitboxWorld2D.MAX_COORDINATE_RAW + 1, 0)
	check(_ray(context, malformed).get("reason") == &"ray_query_geometry_invalid",
		"out-of-range ray endpoint is rejected")

	var too_many_exclusions: Array = []
	for index in BodyHitboxWorld2D.MAX_EXCLUDED_ENTITIES + 1:
		too_many_exclusions.append(_entity("query_ex_%02d" % index).canonical_key())
	malformed = valid.duplicate(true)
	malformed["excluded_entity_ids"] = too_many_exclusions
	check(_ray(context, malformed).get("reason")
		== &"ray_query_exclusion_capacity_exceeded",
		"exclusion list is bounded before iteration")
	malformed = valid.duplicate(true)
	var repeated := _entity("query_repeated").canonical_key()
	malformed["excluded_entity_ids"] = [repeated, repeated]
	check(_ray(context, malformed).get("reason") == &"ray_query_exclusion_duplicate",
		"duplicate exclusion identity is rejected rather than order-normalized")
	malformed = valid.duplicate(true)
	malformed["authority_generation"] = int(context["generation"]) + 1
	check(_ray(context, malformed).get("reason") == &"authority_generation_mismatch",
		"forged authority generation is rejected")
	malformed = valid.duplicate(true)
	malformed["binding_token"] = int(context["token"]) + 1
	check(_ray(context, malformed).get("reason") == &"binding_token_mismatch",
		"forged binding token is rejected")
	malformed = valid.duplicate(true)
	malformed["world_revision"] = world.snapshot_revision() + 1
	check(_ray(context, malformed).get("reason") == &"world_revision_mismatch",
		"future world revision is rejected")
	malformed = valid.duplicate(true)
	malformed["tick"] = world.snapshot_tick() + 1
	check(_ray(context, malformed).get("reason") == &"query_tick_mismatch",
		"future query tick is rejected")
	malformed = valid.duplicate(true)
	malformed["raid_id"] = ZRaidId.from_parts(
		PackedStringArray(["hitbox", "forged_raid"])).canonical_key()
	check(_ray(context, malformed).get("reason") == &"ray_query_raid_mismatch",
		"query cannot forge captured raid provenance")
	malformed = valid.duplicate(true)
	malformed["session_id"] = ZSessionId.from_parts(
		PackedStringArray(["offline", "forged", "00000001"])).canonical_key()
	check(_ray(context, malformed).get("reason") == &"ray_query_session_mismatch",
		"query cannot forge captured session provenance")
	malformed = valid.duplicate(true)
	malformed["authority_epoch"] = int(context["authority_epoch"]) + 1
	check(_ray(context, malformed).get("reason")
		== &"ray_query_authority_epoch_mismatch",
		"query cannot forge captured authority epoch")
	malformed = valid.duplicate(true)
	malformed["owner_actor_id"] = _entity("query_forged_owner").canonical_key()
	check(_ray(context, malformed).get("reason") == &"ray_query_owner_mismatch",
		"query cannot forge binding-owner identity")
	malformed = valid.duplicate(true)
	malformed["query_actor_id"] = _entity("query_unauthorized_actor").canonical_key()
	malformed["query_actor_source"] = int(ZRaidIntent.Source.AI)
	check(_ray(context, malformed).get("reason") == &"ray_query_actor_not_authorized",
		"well-formed query actor absent from authorization set is rejected")

	var first_order := valid.duplicate(true)
	first_order["request_id"] = ZRequestId.from_parts(
		PackedStringArray(["hitbox", "exclusion_order"])).canonical_key()
	first_order["excluded_entity_ids"] = [
		_entity("query_zed").canonical_key(),
		_entity("query_able").canonical_key(),
	]
	var second_order := first_order.duplicate(true)
	second_order["excluded_entity_ids"].reverse()
	var first_result := _ray(context, first_order)
	var second_result := _ray(context, second_order)
	check(bool(first_result.get("accepted", false))
		and bool(second_result.get("duplicate", false)),
		"semantically equal exclusion orders normalize to one replay fingerprint")
	var packed_order := first_order.duplicate(true)
	packed_order["excluded_entity_ids"] = PackedStringArray([
		_entity("query_able").canonical_key(),
		_entity("query_zed").canonical_key(),
	])
	var packed_result := _ray(context, packed_order)
	check(bool(packed_result.get("accepted", false))
		and bool(packed_result.get("duplicate", false)),
		"typed PackedStringArray exclusions normalize to the same strict query")


func _test_obstruction_revision_lifecycle() -> void:
	var context := _new_context("obstruction_revision")
	var authority := context["authority"] as RaidAuthority
	var world := context["world"] as BodyHitboxWorld2D
	var generation := int(context["generation"])
	var token := int(context["token"])
	var original := _obstruction(
		"revisioned", 1, Vector2i(-100, -100), Vector2i(100, 100))
	check(_publish(context, 0, 1, [], [original]),
		"revisioned obstruction publishes")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"obstruction revision fixture activates")
	check(authority.advance_one(generation),
		"obstruction revision fixture advances to removal")
	check(_publish(context, 1, 2, [], []),
		"complete snapshot omission removes obstruction")
	check(authority.advance_one(generation),
		"obstruction revision fixture advances to re-add")
	check(not _publish(context, 2, 3, [], [original])
		and world.last_error == &"obstruction_stale_resurrection",
		"removed obstruction cannot re-enter with stale geometry revision")
	var renewed := _obstruction(
		"revisioned", 2, Vector2i(-100, -100), Vector2i(100, 100))
	check(_publish(context, 2, 3, [], [renewed]),
		"new geometry revision may reintroduce an obstruction")
	check(authority.advance_one(generation),
		"obstruction revision fixture advances to divergence")
	var changed_equal := _obstruction(
		"revisioned", 2, Vector2i(-101, -100), Vector2i(100, 100))
	check(not _publish(context, 3, 4, [], [changed_equal])
		and world.last_error == &"obstruction_equal_revision_divergence",
		"changed obstruction geometry cannot reuse an equal revision")
	var changed_new := _obstruction(
		"revisioned", 3, Vector2i(-101, -100), Vector2i(100, 100))
	check(_publish(context, 3, 4, [], [changed_new]),
		"new obstruction revision admits explicit geometry change")


func _test_lifecycle_and_rebind() -> void:
	var context := _new_context("lifecycle")
	var first_authority := context["authority"] as RaidAuthority
	var world := context["world"] as BodyHitboxWorld2D
	var generation := int(context["generation"])
	var first_token := int(context["token"])
	var first_capability: Variant = context["capability"]
	var target := _entity("lifecycle_target")
	var initial_body := _body(target, 1, Vector2i.ZERO)
	_authorize_bodies(context, [initial_body])
	check(_publish(context, 0, 1, [initial_body], []),
		"lifecycle snapshot publishes")
	var old_query := _query(
		context, "lifecycle_old", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0)
	check(_ray(context, old_query).get("reason")
		== &"authority_not_accepting_world_query",
		"preparing authority cannot be queried for a combat hit")
	check(first_authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"lifecycle authority activates")
	check(bool(_ray(context, old_query).get("hit", false)),
		"active authority admits the same captured query")
	check(first_authority.transition(RaidAuthority.Lifecycle.SETTLING, generation),
		"lifecycle authority enters settling")
	var settling_query := old_query.duplicate(true)
	settling_query["request_id"] = ZRequestId.from_parts(
		PackedStringArray(["hitbox", "lifecycle_settling"])).canonical_key()
	check(_ray(context, settling_query).get("reason")
		== &"authority_not_accepting_world_query",
		"settling authority rejects late combat queries")
	check(world.release_binding(first_capability),
		"binding releases after its authority becomes terminal to combat")
	var released_metadata := world.snapshot_metadata(first_capability)
	check(released_metadata.is_empty() and released_metadata.is_read_only(),
		"release clears all geometry and replay metadata")

	# A fresh coordinator deliberately gives the replacement generation 1 too;
	# the binding token must still prevent ABA callbacks.
	var replacement_raid := ZRaidId.from_parts(PackedStringArray(["hitbox", "replacement"] ))
	var replacement_admission := SessionCoordinator.new().open_offline(
		replacement_raid, &"replacement", &"player")
	var replacement_authority := RaidAuthority.new()
	check(replacement_authority.configure(replacement_raid, replacement_admission, 17),
		"replacement authority configures")
	check(replacement_authority.generation() == generation,
		"replacement fixture deliberately reuses the same numeric generation")
	var replacement_owner := replacement_admission.actor_id
	check(replacement_authority.authorize_actor(
		target, ZRaidIntent.Source.AI, generation),
		"replacement target actor is explicitly authorized")
	var replacement_capability := world.bind_raid_authority(
		replacement_authority, replacement_owner,
		ZRaidIntent.Source.PLAYER, generation)
	check(replacement_capability != null,
		"released world binds to replacement authority")
	var replacement_token := world.binding_token()
	check(replacement_token != first_token,
		"replacement binding receives a monotonic ABA-safe token")
	var replacement_context := {
		"authority": replacement_authority,
		"world": world,
		"generation": generation,
		"token": replacement_token,
		"capability": replacement_capability,
		"owner_actor": ZEntityId.parse(replacement_owner.canonical_key()),
		"owner_source": int(ZRaidIntent.Source.PLAYER),
		"raid_id": replacement_raid.canonical_key(),
		"session_id": replacement_admission.session_id.canonical_key(),
		"authority_epoch": replacement_admission.authority_epoch,
		"query_actor": ZEntityId.parse(replacement_owner.canonical_key()),
		"query_source": int(ZRaidIntent.Source.PLAYER),
	}
	check(_publish(replacement_context, 0, 1,
		[_body(target, 2, Vector2i.ZERO)], []), "replacement snapshot publishes")
	check(replacement_authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation),
		"replacement authority activates")
	check(world.raycast(old_query, first_capability).get("reason")
		== &"binding_capability_mismatch",
		"revoked capability cannot reach replacement state before numeric checks")
	check(not world.release_binding(first_capability)
		and world.last_error == &"binding_capability_mismatch",
		"revoked capability cannot release a replacement binding")
	var replacement_query := _query(
		replacement_context, "lifecycle_replacement", Vector2i(0, -600_000),
		Vector2i(10_000, -600_000), BODY_LAYER, 0)
	check(bool(_ray(replacement_context, replacement_query).get("hit", false)),
		"current replacement token queries replacement geometry")
	check(replacement_authority.teardown(generation),
		"replacement raid authority tears down")
	var late_query := replacement_query.duplicate(true)
	late_query["request_id"] = ZRequestId.from_parts(
		PackedStringArray(["hitbox", "lifecycle_late"])).canonical_key()
	check(_ray(replacement_context, late_query).get("reason")
		== &"binding_generation_invalidated",
		"authority teardown invalidates late world queries")
	check(not world.publish_snapshot(
		0, 1, [], [], generation, replacement_token,
		replacement_owner, ZRaidIntent.Source.PLAYER, replacement_capability)
		and world.last_error == &"binding_generation_invalidated",
		"authority teardown invalidates late snapshot publication")
	check(world.teardown(replacement_capability),
		"world teardown remains available after authority invalidation")


func _test_query_capacity() -> void:
	var context := _active_context("capacity", [], [])
	var world := context["world"] as BodyHitboxWorld2D
	var all_accepted := true
	for index in BodyHitboxWorld2D.MAX_QUERY_RESULTS:
		var result := _ray(context, _query(
			context, "capacity_%04d" % index,
			Vector2i(-10, index), Vector2i(10, index), BODY_LAYER, 0))
		if not bool(result.get("accepted", false)):
			all_accepted = false
			break
	check(all_accepted, "query ledger accepts exactly its documented bounded capacity")
	var overflow := _ray(context, _query(
		context, "capacity_overflow", Vector2i(-10, -1), Vector2i(10, -1),
		BODY_LAYER, 0))
	check(not bool(overflow.get("accepted", true))
		and overflow.get("reason") == &"query_result_capacity_exceeded",
		"query ledger overflow fails closed without evicting replay identities")
	var replay := _ray(context, _query(
		context, "capacity_0000", Vector2i(-10, 0), Vector2i(10, 0), BODY_LAYER, 0))
	check(bool(replay.get("accepted", false)) and bool(replay.get("duplicate", false)),
		"capacity saturation retains deterministic replay of existing queries")


func _check_failed_publication(
	world: BodyHitboxWorld2D,
	context: Dictionary,
	tick: int,
	revision: int,
	bodies: Array,
	obstructions: Array,
	expected_error: StringName,
	label: String
) -> void:
	var before_revision := world.snapshot_revision()
	var before_digest := world.snapshot_digest()
	var accepted := _publish(context, tick, revision, bodies, obstructions)
	check(not accepted and world.last_error == expected_error,
		"%s is rejected with stable reason" % label)
	check(world.snapshot_revision() == before_revision
		and world.snapshot_digest() == before_digest,
		"%s rejection is fail-atomic" % label)


func _new_context(label: String) -> Dictionary:
	var raid := ZRaidId.from_parts(PackedStringArray(["hitbox", label]))
	var admission := SessionCoordinator.new().open_offline(raid, StringName(label), &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid, admission, 13), "%s authority configures" % label)
	var generation := authority.generation()
	var world := BodyHitboxWorld2D.new()
	var owner_actor := admission.actor_id
	var owner_source := ZRaidIntent.Source.PLAYER
	var capability := world.bind_raid_authority(
		authority, owner_actor, owner_source, generation)
	check(capability != null,
		"%s world binds" % label)
	return {
		"authority": authority,
		"world": world,
		"generation": generation,
		"token": world.binding_token(),
		"capability": capability,
		"owner_actor": ZEntityId.parse(owner_actor.canonical_key()),
		"owner_source": int(owner_source),
		"raid_id": raid.canonical_key(),
		"session_id": admission.session_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"query_actor": ZEntityId.parse(owner_actor.canonical_key()),
		"query_source": int(owner_source),
	}


func _active_context(label: String, bodies: Array, obstructions: Array) -> Dictionary:
	var context := _new_context(label)
	var authority := context["authority"] as RaidAuthority
	_authorize_bodies(context, bodies)
	check(_publish(context, 0, 1, bodies, obstructions),
		"%s snapshot publishes" % label)
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, int(context["generation"])),
		"%s authority activates" % label)
	return context


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
		"actor_source": int(ZRaidIntent.Source.AI),
		"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1),
		"body_revision": revision,
		"origin_raw": origin,
		"facing_quarter_turns": facing,
		"collision_layer": layer,
		"targetable": targetable,
	}


func _obstruction(
	label: String,
	revision: int,
	minimum: Vector2i,
	maximum: Vector2i,
	layer: int = OBSTRUCTION_LAYER,
	enabled: bool = true
) -> Dictionary:
	return {
		"obstruction_id": "zerkov.obstruction.hitbox.%s" % label,
		"geometry_revision": revision,
		"min_raw": minimum,
		"max_raw": maximum,
		"collision_layer": layer,
		"enabled": enabled,
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
	return {
		"request_id": ZRequestId.from_parts(
			PackedStringArray(["hitbox", label])).canonical_key(),
		"raid_id": String(context["raid_id"]),
		"session_id": String(context["session_id"]),
		"authority_epoch": int(context["authority_epoch"]),
		"authority_generation": int(context["generation"]),
		"binding_token": int(context["token"]),
		"owner_actor_id": (context["owner_actor"] as ZEntityId).canonical_key(),
		"owner_actor_source": int(context["owner_source"]),
		"query_actor_id": (context["query_actor"] as ZEntityId).canonical_key(),
		"query_actor_source": int(context["query_source"]),
		"tick": world.snapshot_tick(),
		"world_revision": world.snapshot_revision(),
		"origin_raw": origin,
		"target_raw": target,
		"body_mask": body_mask,
		"obstruction_mask": obstruction_mask,
		"excluded_entity_ids": exclusions.duplicate(),
	}


func _authorize_bodies(context: Dictionary, bodies: Array) -> void:
	var authority := context["authority"] as RaidAuthority
	for body_value in bodies:
		var body := body_value as Dictionary
		var actor := ZEntityId.parse(String(body.get("entity_id", "")))
		var source: ZRaidIntent.Source = int(body.get("actor_source", -1))
		check(actor != null and authority.authorize_actor(
			actor, source, int(context["generation"])),
			"body fixture actor is explicitly authorized")


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


func _ray(context: Dictionary, query: Variant) -> Dictionary:
	return (context["world"] as BodyHitboxWorld2D).raycast(
		query, context["capability"])
