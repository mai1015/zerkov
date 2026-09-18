extends RefCounted
## PR #3 regressions. Invoked by the existing movement authority contract;
## no new executable/display entrypoint or relaxed canonical budget.

class InvalidGeometryIdentity extends ZMovementWorld2D:
	func geometry_digest() -> String:
		return ""

var _check: Callable


func run(checker: Callable) -> void:
	_check = checker
	_expect(ZCanonicalValue.DEFAULT_MAX_NODES == 256 and ZCanonicalValue.DEFAULT_MAX_COLLECTION == 64,
		"shared canonical encoder limits remain unchanged")
	_test_large_world_digests()
	_test_read_only_placement()
	_test_bake_isolation()
	_test_final_blocker_reporting()
	_check = Callable()


func _expect(condition: bool, message: String) -> void:
	_check.call(condition, "PR3_REGRESSION: " + message)


func _id(slot: String) -> ZEntityId:
	return ZEntityId.from_parts(PackedStringArray(["pr3", slot]))


func _world() -> ZMovementWorld2D:
	var world := ZMovementWorld2D.new()
	_expect(world.configure(Rect2(0, 0, 1024, 512), 7, "pr3.bounds"), "world configures")
	return world


func _valid_hash(value: String) -> bool:
	return value.length() == 64 and value.is_valid_hex_number(false)


func _test_large_world_digests() -> void:
	for count in [0, 1, 49, 50, 61, 62, 64, 65, 256, 512, ZMovementWorld2D.MAX_STATIC_COLLIDERS]:
		var a := _world()
		var b := _world()
		var accepted := true
		for i in count:
			var rect := Rect2(800, 16 + (i % 16) * 16, 16, 8)
			accepted = a.add_static_collider_px("c%04d" % i, rect, 7) and accepted
		for i in range(count - 1, -1, -1):
			var rect := Rect2(800, 16 + (i % 16) * 16, 16, 8)
			accepted = b.add_static_collider_px("c%04d" % i, rect, 7) and accepted
		_expect(accepted and a.collider_count() == count, "accepted collider count %d" % count)
		var before := a.canonical_record()
		var digest := a.digest()
		_expect(_valid_hash(digest), "nonempty valid hash at %d colliders" % count)
		_expect(a.canonical_record() == before, "hashing does not mutate source records")
		_expect(digest == b.digest(), "collider insertion order is irrelevant")
		_expect(a.geometry_digest() == b.geometry_digest(), "geometry identity is ordered")
		# Force mixed state beyond both old collection/node thresholds.
		for i in 128:
			accepted = a.register_actor(_id("a%04d" % i), Vector2(32, 32), Vector2(8, 8), 7) and accepted
		for i in range(127, -1, -1):
			accepted = b.register_actor(_id("a%04d" % i), Vector2(32, 32), Vector2(8, 8), 7) and accepted
		_expect(accepted and a.actor_count() == 128, "128 actors accepted with %d colliders" % count)
		_expect(_valid_hash(a.digest()) and a.digest() == b.digest(), "mixed state hashes in stable order")
		_expect(a.digest() != digest, "adding actors changes full state identity")
		var geometry := a.geometry_digest()
		var state_before := a.digest()
		_expect(a.resolve_actor_step(_id("a0000"), 1, Vector2(60, 0), 7).ok, "large-world movement accepted")
		_expect(a.digest() != state_before and _valid_hash(a.digest()), "different valid states never compare as empty")
		_expect(a.geometry_digest() == geometry, "live actor movement does not change geometry identity")
		if count == ZMovementWorld2D.MAX_STATIC_COLLIDERS:
			_expect(not a.add_static_collider_px("overflow", Rect2(900, 400, 8, 8), 7)
				and a.last_error == &"collider_limit", "capacity overflow rejected")
			_expect(_valid_hash(a.digest()), "capacity rejection leaves a usable identity")

	# Last-correction identifier lists can exceed the generic collection bound.
	var contacts := _world()
	for i in 80:
		_expect(contacts.add_static_collider_px("contact%03d" % i, Rect2(64, 0, 8, 512), 7), "coincident wall accepted")
	_expect(contacts.register_actor(_id("contact"), Vector2(32, 32), Vector2(8, 8), 7), "contact actor registers")
	var hit := contacts.resolve_actor_step(_id("contact"), 1, Vector2(6000, 0), 7)
	_expect(hit.ok and hit.blocking_collider_ids.size() == 80, "all final-boundary ties reported")
	_expect(_valid_hash(hit.digest()), "long movement-result contact list hashes")
	var result_hash := hit.digest()
	hit.blocking_collider_ids.remove_at(0)
	_expect(_valid_hash(hit.digest()) and hit.digest() != result_hash, "contact list changes result identity")
	var original := contacts.corrections_snapshot()
	_expect(_valid_hash(contacts.digest()), "long correction identifier list hashes")
	_expect(contacts.corrections_snapshot() == original, "hashing preserves correction snapshot")

	var names := _world()
	var long_id := "x".repeat(257)
	var name_digest := names.digest()
	_expect(not names.add_static_collider_px(long_id, Rect2(800, 0, 16, 16), 7), "over-budget collider id rejected")
	_expect(names.digest() == name_digest, "id rejection is inert")
	_expect(names.add_static_collider_px("x".repeat(256), Rect2(800, 0, 16, 16), 7), "maximum-byte id accepted")
	_expect(_valid_hash(names.digest()), "maximum-byte id hashes")
	var bounds := ZMovementWorld2D.new()
	_expect(not bounds.configure(Rect2(0, 0, 32, 32), 7, long_id), "over-budget bounds id rejected")
	_expect(not bounds.is_configured(), "invalid bounds identity does not configure")


func _test_read_only_placement() -> void:
	var world := _world()
	_expect(world.add_static_collider_px("wall", Rect2(64, 0, 32, 160), 7), "query fixture wall")
	world.last_error = &"sentinel"
	var before := world.canonical_record()
	var samples := [
		[Vector2(32, 32), Vector2(8, 8), &""],
		[Vector2(56, 32), Vector2(8, 8), &""],
		[Vector2(64, 32), Vector2(8, 8), &"actor_spawn_blocked"],
		[Vector2(4, 32), Vector2(8, 8), &"actor_out_of_bounds"],
		[Vector2(32, 32), Vector2.ZERO, &"body_shape_invalid"],
		[Vector2(32, 32), Vector2(0.000001, 8), &"body_shape_invalid"],
		[Vector2(32, 32), Vector2.INF, &"body_shape_invalid"],
		[Vector2(NAN, 32), Vector2(8, 8), &"body_shape_invalid"],
	]
	for i in samples.size():
		var sample: Array = samples[i]
		var query := world.query_placement_px(sample[0], sample[1])
		_expect(query["reason"] == sample[2], "placement result %d" % i)
		_expect(bool(query["ok"]) == String(sample[2]).is_empty(), "placement ok agrees with reason")
		_expect(world.canonical_record() == before and world.last_error == &"sentinel", "even failed queries preserve all world state")
	# The exact query verdict is shared by registration, not a second overlap algorithm.
	for i in samples.size():
		var sample: Array = samples[i]
		var query := world.query_placement_px(sample[0], sample[1])
		var accepted := world.register_actor(_id("query%d" % i), sample[0], sample[1], 7)
		_expect(accepted == bool(query["ok"]), "registration and query agree")
		_expect(accepted or world.last_error == query["reason"], "registration preserves denial reason")
	var unconfigured := ZMovementWorld2D.new()
	_expect(unconfigured.query_placement_px(Vector2.ZERO, Vector2.ONE)["reason"] == &"world_unconfigured", "unconfigured query fails closed")


func _test_bake_isolation() -> void:
	var invalid := InvalidGeometryIdentity.new()
	_expect(invalid.configure(Rect2(0, 0, 128, 128), 7), "invalid-identity fixture configures")
	_expect(ZNavigationGrid.bake_from_movement_world(invalid, Vector2i(4, 4), 1) == null
		and ZNavigationGrid.last_error == &"movement_geometry_digest_invalid", "empty geometry identity fails closed")
	_expect(invalid.actor_count() == 0, "rejected identity creates no actors")
	var world := _world()
	_expect(world.add_static_collider_cells("block", Rect2i(2, 0, 1, 3), 7), "bake fixture blocks three cells")
	# A real actor may legitimately use the old probe namespace.
	var actor := ZEntityId.from_parts(PackedStringArray(["navprobe", "c0_0"]))
	_expect(world.register_actor(actor, Vector2(16, 16), Vector2(8, 8), 7), "existing probe-like actor registers")
	world.last_error = &"sentinel"
	var state := world.canonical_record()
	var digest := world.digest()
	var grid_hash := ""
	for repetition in 5:
		var grid := ZNavigationGrid.bake_from_movement_world(world, Vector2i(4, 4), 1, "pr3.grid")
		_expect(grid != null, "rebake %d succeeds" % repetition)
		if grid == null:
			continue
		_expect(grid.blocked_cell_count() == 3 and grid.walkable_cell_count() == 13, "bake preserves geometry truth")
		_expect(_valid_hash(grid.digest()) and _valid_hash(grid.source_digest()), "grid identity is not empty")
		if repetition == 0:
			grid_hash = grid.digest()
		_expect(grid.digest() == grid_hash, "rebakes are identical")
		_expect(world.actor_count() == 1 and world.canonical_record() == state, "bake preserves complete authoritative record")
		_expect(world.digest() == digest and world.last_error == &"sentinel", "bake preserves digest and error metadata")
	_expect(ZNavigationGrid.bake_from_movement_world(world, Vector2i(100, 100), 1) == null, "oversize bake rejected")
	_expect(world.canonical_record() == state and world.last_error == &"sentinel", "failed bake is also inert")
	_expect(world.resolve_actor_step(actor, 1, Vector2(60, 0), 7).ok, "original actor still moves")
	var after_motion := ZNavigationGrid.bake_from_movement_world(world, Vector2i(4, 4), 1, "pr3.grid")
	_expect(after_motion != null and after_motion.digest() == grid_hash, "actor ticks do not invalidate static grid identity")
	_expect(world.seal(7), "fixture world seals")
	state = world.canonical_record()
	var sealed_grid := ZNavigationGrid.bake_from_movement_world(world, Vector2i(4, 4), 1, "pr3.grid")
	_expect(sealed_grid != null and sealed_grid.digest() == grid_hash, "sealed geometry remains queryable")
	_expect(world.canonical_record() == state, "sealed-world bake is read-only")


func _test_final_blocker_reporting() -> void:
	for axis in 2:
		for direction in [-1, 1]:
			var world := _world()
			var near_rect := Rect2(64, 0, 8, 256) if direction > 0 else Rect2(160, 0, 8, 256)
			var far_rect := Rect2(160, 0, 8, 256) if direction > 0 else Rect2(64, 0, 8, 256)
			var start := Vector2(32, 32) if direction > 0 else Vector2(224, 32)
			var velocity := Vector2(direction * 60000, 0)
			if axis == 1:
				near_rect = Rect2(Vector2(near_rect.position.y, near_rect.position.x), Vector2(near_rect.size.y, near_rect.size.x))
				far_rect = Rect2(Vector2(far_rect.position.y, far_rect.position.x), Vector2(far_rect.size.y, far_rect.size.x))
				start = Vector2(start.y, start.x)
				velocity = Vector2(0, velocity.x)
			world.add_static_collider_px("a_far", far_rect, 7)
			world.add_static_collider_px("z_near", near_rect, 7)
			world.add_static_collider_px("z_tie", near_rect, 7)
			world.register_actor(_id("blocker"), start, Vector2(8, 8), 7)
			var hit := world.resolve_actor_step(_id("blocker"), 1, velocity, 7)
			_expect(hit.ok, "swept move resolves")
			_expect(hit.blocking_collider_ids == PackedStringArray(["z_near", "z_tie"]), "only nearest contacts survive, with ties, on either axis/direction")
			var position := hit.resolved_position_px.x if axis == 0 else hit.resolved_position_px.y
			_expect(position == (56.0 if direction > 0 else 176.0), "nearest physical boundary wins over farther wall and bounds")
