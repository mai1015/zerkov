extends SceneTree
## Task 3.8 gate: bounded proximity/line interaction policy for doors, crates,
## corpses, healing targets and extraction zones.
##
## Every range comparison is driven through `evaluate_micro` with exact
## canonical microunits so an "at the boundary" / "one unit beyond" pair is a
## true integer boundary test with no float rounding anywhere in the call.

const MICRO: int = ZWorldUnits.VISION_MICROUNITS_PER_WORLD_UNIT
const LAYOUT_PATH := "res://game/world/sawmill/sawmill_yard_layout.tres"

var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INTERACTION_POLICY: " + message)


func run() -> void:
	_test_kind_vocabulary()
	_test_range_table_is_per_kind()
	_test_point_kind_boundaries()
	_test_extraction_zone_containment()
	_test_line_of_interaction()
	_test_unknown_and_wrong_kind()
	_test_eligibility_predicates()
	_test_invalid_requests()
	_test_determinism()
	_test_target_index_from_authored_layout()
	_test_owner_generation_and_phase()

	print("INTERACTION_POLICY_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)


# --- helpers ---------------------------------------------------------------

func _no_occluders() -> Array[ZerkovOccluderSegment]:
	var empty: Array[ZerkovOccluderSegment] = []
	return empty


func _point_target(
	id: String, kind: StringName, px: Vector2, elig: Dictionary = {}
) -> Dictionary:
	var state := ZInteractionTargetState.create_point(StringName(id), kind, px, elig)
	return {id: state}


## Actor microunit position exactly `offset_micro` to the east of `target_px`.
func _actor_micro_east_of(target_px: Vector2, offset_micro: int) -> Vector2i:
	var target := ZWorldUnits.godot_to_canonical(target_px)
	return Vector2i(target.vector2i_value.x + offset_micro, target.vector2i_value.y)


# --- tests -----------------------------------------------------------------

func _test_kind_vocabulary() -> void:
	check(ZInteractionKind.ALL.size() == 5, "exactly five first-playable kinds")
	for kind in ZInteractionKind.ALL:
		check(ZInteractionKind.is_valid(kind), "kind is valid: " + String(kind))
	check(not ZInteractionKind.is_valid(&"teleporter"), "unknown kind rejected")
	check(not ZInteractionKind.is_valid(&""), "empty kind rejected")


func _test_range_table_is_per_kind() -> void:
	# The task forbids one global radius: each point kind must carry its own
	# authored range, and they must not all collapse to a single value.
	var door := ZInteractionPolicy.range_micro_for_kind(ZInteractionKind.DOOR)
	var crate := ZInteractionPolicy.range_micro_for_kind(ZInteractionKind.CRATE)
	var corpse := ZInteractionPolicy.range_micro_for_kind(ZInteractionKind.CORPSE)
	var heal := ZInteractionPolicy.range_micro_for_kind(ZInteractionKind.HEAL_TARGET)
	var zone := ZInteractionPolicy.range_micro_for_kind(ZInteractionKind.EXTRACTION_ZONE)

	check(door == 3 * MICRO / 2, "door range is 1.5 world units in micro")
	check(crate == 5 * MICRO / 4, "crate range is 1.25 world units in micro")
	check(corpse == 3 * MICRO / 2, "corpse range is 1.5 world units in micro")
	check(heal == 2 * MICRO, "heal target range is 2.0 world units in micro")
	check(zone == ZInteractionPolicy.NO_RANGE_MICRO,
		"extraction zone declares no radius (area containment instead)")
	check({door: true, crate: true, heal: true}.size() == 3,
		"point kinds do not share one global radius")


func _test_point_kind_boundaries() -> void:
	var target_px := Vector2(320.0, 320.0)
	var cases := [
		[ZInteractionKind.DOOR, {}],
		[ZInteractionKind.CRATE, {}],
		[ZInteractionKind.CORPSE, {}],
		[ZInteractionKind.HEAL_TARGET, {"alive": true, "injured": true}],
	]
	for case in cases:
		var kind: StringName = case[0]
		var elig: Dictionary = case[1]
		var targets := _point_target("t", kind, target_px, elig)
		var range_micro := ZInteractionPolicy.range_micro_for_kind(kind)

		var at_boundary := ZInteractionPolicy.evaluate_micro(
			_actor_micro_east_of(target_px, range_micro), &"t", kind,
			targets, _no_occluders()
		)
		check(at_boundary.allowed,
			"allowed exactly at the authored boundary: " + String(kind))
		check(at_boundary.reason == ZInteractionResult.REASON_NONE,
			"boundary allow carries no denial reason: " + String(kind))
		check(at_boundary.distance_micro == range_micro,
			"boundary allow reports the exact resolved distance: " + String(kind))

		var one_beyond := ZInteractionPolicy.evaluate_micro(
			_actor_micro_east_of(target_px, range_micro + 1), &"t", kind,
			targets, _no_occluders()
		)
		check(not one_beyond.allowed,
			"denied one microunit beyond the boundary: " + String(kind))
		check(one_beyond.reason == ZInteractionResult.REASON_OUT_OF_RANGE,
			"one-beyond denial reason is out_of_range: " + String(kind))
		check(one_beyond.distance_micro == range_micro + 1,
			"out_of_range denial still reports the real distance: " + String(kind))
		check(one_beyond.kind == kind,
			"denial reports the resolved target kind: " + String(kind))


func _test_extraction_zone_containment() -> void:
	# Extraction uses authored zone_cells containment, NOT a radius. Mirrors the
	# real Road Gate authoring: Rect2i(36, 9, 3, 3) with anchor cell (37, 10).
	var zone := Rect2i(36, 9, 3, 3)
	var anchor_px := ZWorldUnits.tile_center_to_godot(Vector2i(37, 10)).vector2_value
	var state := ZInteractionTargetState.create_zone(&"x", anchor_px, zone)
	var targets := {"x": state}
	check(state.validate().is_empty(), "authored extraction zone state validates")

	for cell in [Vector2i(36, 9), Vector2i(37, 10), Vector2i(38, 11)]:
		var inside_px := ZWorldUnits.tile_center_to_godot(cell).vector2_value
		var inside_micro := ZWorldUnits.godot_to_canonical(inside_px).vector2i_value
		var inside := ZInteractionPolicy.evaluate_micro(
			inside_micro, &"x", ZInteractionKind.EXTRACTION_ZONE,
			targets, _no_occluders()
		)
		check(inside.allowed, "allowed inside zone_cells at cell " + str(cell))

	for cell in [Vector2i(35, 10), Vector2i(39, 10), Vector2i(37, 8), Vector2i(37, 12)]:
		var outside_px := ZWorldUnits.tile_center_to_godot(cell).vector2_value
		var outside_micro := ZWorldUnits.godot_to_canonical(outside_px).vector2i_value
		var outside := ZInteractionPolicy.evaluate_micro(
			outside_micro, &"x", ZInteractionKind.EXTRACTION_ZONE,
			targets, _no_occluders()
		)
		check(not outside.allowed, "denied outside zone_cells at cell " + str(cell))
		check(outside.reason == ZInteractionResult.REASON_OUT_OF_RANGE,
			"outside-zone denial reason is out_of_range at " + str(cell))

	# A cell one tile outside is still adjacent: containment, not distance,
	# is what denied it.
	var adjacent_px := ZWorldUnits.tile_center_to_godot(Vector2i(35, 10)).vector2_value
	var adjacent := ZInteractionPolicy.evaluate_micro(
		ZWorldUnits.godot_to_canonical(adjacent_px).vector2i_value,
		&"x", ZInteractionKind.EXTRACTION_ZONE, targets, _no_occluders()
	)
	check(adjacent.distance_micro < MICRO,
		"adjacent-but-outside actor is nearer than one world unit, proving "
		+ "the denial came from containment rather than a radius")


func _test_line_of_interaction() -> void:
	# Actor and crate one world unit apart on the same row, with a structure
	# occluder segment standing exactly between them.
	var crate_px := Vector2(320.0, 320.0)
	var targets := _point_target("c", ZInteractionKind.CRATE, crate_px)
	var actor_micro := _actor_micro_east_of(crate_px, MICRO)
	var crate_micro := ZWorldUnits.godot_to_canonical(crate_px).vector2i_value

	var clear := ZInteractionPolicy.evaluate_micro(
		actor_micro, &"c", ZInteractionKind.CRATE, targets, _no_occluders()
	)
	check(clear.allowed, "crate reachable with no occluder between")

	var wall_x: int = crate_micro.x + MICRO / 2
	var blocking := ZerkovOccluderSegment.new()
	blocking.a = Vector2i(wall_x, crate_micro.y - MICRO)
	blocking.b = Vector2i(wall_x, crate_micro.y + MICRO)
	blocking.mask = ZOccluderBake.MASK_STRUCTURE
	blocking.source_ids = ["zerkov.structure.sawmill.test_wall"]
	var walls: Array[ZerkovOccluderSegment] = [blocking]

	var blocked := ZInteractionPolicy.evaluate_micro(
		actor_micro, &"c", ZInteractionKind.CRATE, targets, walls
	)
	check(not blocked.allowed, "wall between actor and crate denies the interaction")
	check(blocked.reason == ZInteractionResult.REASON_LINE_BLOCKED,
		"blocked denial reason is line_blocked")
	check(blocked.distance_micro == MICRO,
		"line_blocked denial still reports the real resolved distance")

	# A vegetation-only occluder blocks sight but not physical reach.
	var canopy := ZerkovOccluderSegment.new()
	canopy.a = blocking.a
	canopy.b = blocking.b
	canopy.mask = ZOccluderBake.MASK_VEGETATION
	canopy.source_ids = ["zerkov.structure.sawmill.test_trees"]
	var foliage: Array[ZerkovOccluderSegment] = [canopy]
	var through_canopy := ZInteractionPolicy.evaluate_micro(
		actor_micro, &"c", ZInteractionKind.CRATE, targets, foliage
	)
	check(through_canopy.allowed,
		"vegetation-only occluder does not block physical reach")

	# A segment contributed by the target itself must not block reaching it.
	var own_edge := ZerkovOccluderSegment.new()
	own_edge.a = blocking.a
	own_edge.b = blocking.b
	own_edge.mask = ZOccluderBake.MASK_STRUCTURE
	own_edge.source_ids = ["c"]
	var self_edges: Array[ZerkovOccluderSegment] = [own_edge]
	var own := ZInteractionPolicy.evaluate_micro(
		actor_micro, &"c", ZInteractionKind.CRATE, targets, self_edges
	)
	check(own.allowed, "the target's own occluder edge does not block it")

	# A degenerate segment is inert rather than a spurious block.
	var degenerate := ZerkovOccluderSegment.new()
	degenerate.a = blocking.a
	degenerate.b = blocking.a
	degenerate.mask = ZOccluderBake.MASK_STRUCTURE
	degenerate.source_ids = ["zerkov.structure.sawmill.test_degenerate"]
	var degenerates: Array[ZerkovOccluderSegment] = [degenerate]
	var past_degenerate := ZInteractionPolicy.evaluate_micro(
		actor_micro, &"c", ZInteractionKind.CRATE, targets, degenerates
	)
	check(past_degenerate.allowed, "degenerate occluder segment is inert")

	# Range is checked before line: a blocked AND far target reports range.
	var far_blocked := ZInteractionPolicy.evaluate_micro(
		_actor_micro_east_of(crate_px, 8 * MICRO), &"c", ZInteractionKind.CRATE,
		targets, walls
	)
	check(far_blocked.reason == ZInteractionResult.REASON_OUT_OF_RANGE,
		"an out-of-range blocked target reports out_of_range, not line_blocked")


func _test_unknown_and_wrong_kind() -> void:
	var targets := _point_target("c", ZInteractionKind.CRATE, Vector2(320.0, 320.0))
	var near := _actor_micro_east_of(Vector2(320.0, 320.0), 0)

	var unknown := ZInteractionPolicy.evaluate_micro(
		near, &"nope", ZInteractionKind.CRATE, targets, _no_occluders()
	)
	check(not unknown.allowed, "unknown target id is denied")
	check(unknown.reason == ZInteractionResult.REASON_UNKNOWN_TARGET,
		"unknown target denial reason is unknown_target")
	check(unknown.distance_micro == -1,
		"unknown target resolves no distance")

	var empty_id := ZInteractionPolicy.evaluate_micro(
		near, &"", ZInteractionKind.CRATE, targets, _no_occluders()
	)
	check(empty_id.reason == ZInteractionResult.REASON_UNKNOWN_TARGET,
		"empty target id denial reason is unknown_target")

	var wrong := ZInteractionPolicy.evaluate_micro(
		near, &"c", ZInteractionKind.DOOR, targets, _no_occluders()
	)
	check(not wrong.allowed, "requesting the wrong verb for a target is denied")
	check(wrong.reason == ZInteractionResult.REASON_WRONG_KIND,
		"wrong-kind denial reason is wrong_kind")
	check(wrong.kind == ZInteractionKind.CRATE,
		"wrong-kind denial reports the target's real kind")


func _test_eligibility_predicates() -> void:
	var px := Vector2(320.0, 320.0)
	var touching := _actor_micro_east_of(px, 0)

	# Door: default unlocked, explicit locked denies.
	var unlocked := ZInteractionPolicy.evaluate_micro(
		touching, &"d", ZInteractionKind.DOOR,
		_point_target("d", ZInteractionKind.DOOR, px), _no_occluders()
	)
	check(unlocked.allowed, "door default is unlocked")
	var locked := ZInteractionPolicy.evaluate_micro(
		touching, &"d", ZInteractionKind.DOOR,
		_point_target("d", ZInteractionKind.DOOR, px, {"locked": true}),
		_no_occluders()
	)
	check(not locked.allowed, "locked door is denied")
	check(locked.reason == ZInteractionResult.REASON_INELIGIBLE,
		"locked door denial reason is ineligible")
	check(locked.distance_micro == 0,
		"ineligible denial still reports the resolved distance")

	# Crate / corpse: default lootable, explicit lootable:false denies.
	for kind in [ZInteractionKind.CRATE, ZInteractionKind.CORPSE]:
		var lootable := ZInteractionPolicy.evaluate_micro(
			touching, &"k", kind, _point_target("k", kind, px), _no_occluders()
		)
		check(lootable.allowed, "default lootable: " + String(kind))
		var emptied := ZInteractionPolicy.evaluate_micro(
			touching, &"k", kind,
			_point_target("k", kind, px, {"lootable": false}), _no_occluders()
		)
		check(not emptied.allowed, "non-lootable denied: " + String(kind))
		check(emptied.reason == ZInteractionResult.REASON_INELIGIBLE,
			"non-lootable denial reason is ineligible: " + String(kind))

	# Heal target fails closed: default is alive but NOT injured.
	var healthy := ZInteractionPolicy.evaluate_micro(
		touching, &"h", ZInteractionKind.HEAL_TARGET,
		_point_target("h", ZInteractionKind.HEAL_TARGET, px), _no_occluders()
	)
	check(not healthy.allowed, "heal target fails closed when not injured")
	check(healthy.reason == ZInteractionResult.REASON_INELIGIBLE,
		"uninjured heal denial reason is ineligible")
	var injured := ZInteractionPolicy.evaluate_micro(
		touching, &"h", ZInteractionKind.HEAL_TARGET,
		_point_target("h", ZInteractionKind.HEAL_TARGET, px,
			{"alive": true, "injured": true}), _no_occluders()
	)
	check(injured.allowed, "alive and injured heal target is allowed")
	var dead := ZInteractionPolicy.evaluate_micro(
		touching, &"h", ZInteractionKind.HEAL_TARGET,
		_point_target("h", ZInteractionKind.HEAL_TARGET, px,
			{"alive": false, "injured": true}), _no_occluders()
	)
	check(not dead.allowed, "dead heal target is denied")

	# Extraction zone: default open, explicit open:false denies.
	var zone := Rect2i(36, 9, 3, 3)
	var anchor_px := ZWorldUnits.tile_center_to_godot(Vector2i(37, 10)).vector2_value
	var anchor_micro := ZWorldUnits.godot_to_canonical(anchor_px).vector2i_value
	var open := ZInteractionPolicy.evaluate_micro(
		anchor_micro, &"x", ZInteractionKind.EXTRACTION_ZONE,
		{"x": ZInteractionTargetState.create_zone(&"x", anchor_px, zone)},
		_no_occluders()
	)
	check(open.allowed, "extraction zone default is open")
	var closed := ZInteractionPolicy.evaluate_micro(
		anchor_micro, &"x", ZInteractionKind.EXTRACTION_ZONE,
		{"x": ZInteractionTargetState.create_zone(
			&"x", anchor_px, zone, {"open": false})},
		_no_occluders()
	)
	check(not closed.allowed, "closed extraction zone is denied")
	check(closed.reason == ZInteractionResult.REASON_INELIGIBLE,
		"closed extraction denial reason is ineligible")


func _test_invalid_requests() -> void:
	var targets := _point_target("c", ZInteractionKind.CRATE, Vector2(320.0, 320.0))
	var null_request := ZInteractionPolicy.evaluate(null, targets, _no_occluders())
	check(not null_request.allowed, "null request is denied")
	check(null_request.reason == ZInteractionResult.REASON_INVALID_REQUEST,
		"null request denial reason is invalid_request")

	var far_out := ZWorldUnits.MAX_VISION_CANONICAL_RAW + 1
	var unbounded := ZInteractionPolicy.evaluate_micro(
		Vector2i(far_out, 0), &"c", ZInteractionKind.CRATE, targets, _no_occluders()
	)
	check(not unbounded.allowed, "out-of-Vision-bound actor position is denied")
	check(unbounded.reason == ZInteractionResult.REASON_INVALID_REQUEST,
		"unbounded actor denial reason is invalid_request")

	# The px entry point agrees with the micro entry point.
	var crate_px := Vector2(320.0, 320.0)
	var actor_px := crate_px + Vector2(float(ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT), 0.0)
	var via_px := ZInteractionPolicy.evaluate(
		ZInteractionRequest.create(null, actor_px, &"c", ZInteractionKind.CRATE),
		targets, _no_occluders()
	)
	var via_micro := ZInteractionPolicy.evaluate_micro(
		ZWorldUnits.godot_to_canonical(actor_px).vector2i_value,
		&"c", ZInteractionKind.CRATE, targets, _no_occluders()
	)
	check(via_px.is_equal_to(via_micro),
		"px and micro entry points produce identical results")


func _test_determinism() -> void:
	var px := Vector2(320.0, 320.0)
	var targets := _point_target("c", ZInteractionKind.CRATE, px)
	var actor := _actor_micro_east_of(px, MICRO)
	var first := ZInteractionPolicy.evaluate_micro(
		actor, &"c", ZInteractionKind.CRATE, targets, _no_occluders()
	)
	for i in range(8):
		var again := ZInteractionPolicy.evaluate_micro(
			actor, &"c", ZInteractionKind.CRATE, targets, _no_occluders()
		)
		check(first.is_equal_to(again), "repeated evaluation is identical (%d)" % i)
		check(first.digest() == again.digest(),
			"repeated evaluation digest is bit-identical (%d)" % i)

	# A denial digest differs from an allow digest for the same target.
	var denied := ZInteractionPolicy.evaluate_micro(
		_actor_micro_east_of(px, 8 * MICRO), &"c", ZInteractionKind.CRATE,
		targets, _no_occluders()
	)
	check(first.digest() != denied.digest(),
		"allow and denial digests differ for the same target")


func _test_target_index_from_authored_layout() -> void:
	var layout := load(LAYOUT_PATH) as Resource
	check(layout != null, "authored Sawmill layout loads")
	if layout == null:
		return
	var built := ZInteractionTargetIndex.build_from_sawmill_layout(layout)
	check(bool(built.get("ok", false)), "target index builds from authored layout")
	var targets: Dictionary = built["targets"]

	# Authored crates, cache, corpse and the Road Gate extract all resolve.
	var expected := {
		"zerkov.loot.sawmill.crate.log_racks": ZInteractionKind.CRATE,
		"zerkov.loot.sawmill.crate.saw_house": ZInteractionKind.CRATE,
		"zerkov.loot.sawmill.crate.settling_dock": ZInteractionKind.CRATE,
		"zerkov.loot.sawmill.service_cache": ZInteractionKind.CRATE,
		"zerkov.loot.sawmill.corpse.haul_lane": ZInteractionKind.CORPSE,
		"zerkov.extract.sawmill.road_gate": ZInteractionKind.EXTRACTION_ZONE,
	}
	for id in expected.keys():
		var state: Variant = targets.get(id, null)
		check(state is ZInteractionTargetState, "authored target indexed: " + id)
		if state is ZInteractionTargetState:
			check((state as ZInteractionTargetState).kind == expected[id],
				"authored target kind resolved: " + id)
			check((state as ZInteractionTargetState).validate().is_empty(),
				"authored target state validates: " + id)

	# Both authored road-gate structures become doors.
	for id in ["zerkov.structure.sawmill.road_gate_north",
			"zerkov.structure.sawmill.road_gate_south"]:
		var door: Variant = targets.get(id, null)
		check(door is ZInteractionTargetState, "authored gate indexed as a door: " + id)
		if door is ZInteractionTargetState:
			check((door as ZInteractionTargetState).kind == ZInteractionKind.DOOR,
				"authored gate kind is door: " + id)

	# Spawn / patrol / encounter markers are not interaction targets.
	for id in ["zerkov.spawn.sawmill.west_service",
			"zerkov.encounter.sawmill.scav_cover",
			"zerkov.patrol.sawmill.haul_lane.0"]:
		check(not targets.has(id), "non-interactable marker is not indexed: " + id)

	# The index is a pure read: building twice yields identical digests.
	var rebuilt := ZInteractionTargetIndex.build_from_sawmill_layout(layout)
	var rebuilt_targets: Dictionary = rebuilt["targets"]
	check(rebuilt_targets.size() == targets.size(),
		"rebuilt index has the same target count")
	for id in targets.keys():
		var a := targets[id] as ZInteractionTargetState
		var b := rebuilt_targets.get(id, null) as ZInteractionTargetState
		check(b != null and a.digest() == b.digest(),
			"rebuilt target digest is identical: " + str(id))

	# A fail-closed build on bad input.
	var bad := ZInteractionTargetIndex.build_from_sawmill_layout(null)
	check(not bool(bad.get("ok", true)), "null layout fails closed")
	check(ZInteractionTargetIndex.last_error == &"layout_missing",
		"null layout names the fail-closed reason")


func _test_owner_generation_and_phase() -> void:
	var raid_id := ZRaidId.from_parts(
		PackedStringArray(["fixture", "interaction", "policy_gate"])
	)
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid_id, &"interaction_profile", &"player")
	check(admission != null, "offline admission created for the owner test")
	if admission == null:
		return

	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 20260914), "authority configured")
	var generation := authority.generation()

	var owner := ZInteractionPolicyOwner.new()
	check(owner.configure(generation), "owner configured at current generation")
	check(owner.register_with_authority(authority, generation),
		"owner registers an INTERACTIONS_AND_WEAPONS phase handler")
	check(authority.has_phase_handler(
			ZInteractionPolicyOwner.DEFAULT_PHASE_HANDLER_ID, generation),
		"the phase handler is present under its stable id")

	# A stale generation must be inert for every mutating entry point.
	var stale := generation + 1
	var state := ZInteractionTargetState.create_point(
		&"zerkov.loot.sawmill.stale", ZInteractionKind.CRATE, Vector2(320.0, 320.0)
	)
	var before := owner.target_count()
	check(not owner.upsert_target(state, stale), "stale-generation upsert is rejected")
	check(owner.target_count() == before, "stale-generation upsert mutated nothing")
	check(not owner.remove_target(&"zerkov.loot.sawmill.stale", stale),
		"stale-generation remove is rejected")
	check(not owner.attach_movement_world(ZMovementWorld2D.new(), stale),
		"stale-generation movement-world attach is rejected")

	# A current-generation upsert works, and an invalid state is refused.
	check(owner.upsert_target(state, generation), "current-generation upsert accepted")
	check(owner.target_count() == before + 1, "accepted upsert added one target")
	var invalid := ZInteractionTargetState.create_point(
		&"", ZInteractionKind.CRATE, Vector2(320.0, 320.0)
	)
	check(not owner.upsert_target(invalid, generation),
		"invalid target state is refused by the owner")
	check(owner.target_count() == before + 1, "refused upsert mutated nothing")

	# The owner never grants interaction range by itself: an unknown actor has
	# no authoritative position and must fail closed.
	var unknown_actor := ZEntityId.parse("zerkov.actor.player.not_in_world")
	var no_pose := owner.evaluate_for_actor(
		unknown_actor, &"zerkov.loot.sawmill.stale", ZInteractionKind.CRATE, generation
	)
	check(no_pose != null and not no_pose.allowed,
		"an actor with no authoritative pose is denied")
	check(no_pose != null and no_pose.reason == ZInteractionResult.REASON_ACTOR_UNKNOWN,
		"missing-pose denial reason is actor_unknown")

	# After teardown the raid is terminal and evaluation is inert.
	check(authority.teardown(generation), "authority torn down")
	var after_teardown := owner.evaluate_for_actor(
		admission.actor_id, &"zerkov.loot.sawmill.stale",
		ZInteractionKind.CRATE, generation
	)
	check(after_teardown != null and not after_teardown.allowed,
		"evaluation after teardown is denied rather than granted")
