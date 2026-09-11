extends SceneTree
## Permanent regression for the stale-world reflective capability escape.
##
## A holder of raid A's world and capability must not be able to discover the
## exact raid B bearer through standard Godot reflection after release/rebind.

const BODY_LAYER: int = 1
const LEGACY_CAPABILITY_PROPERTY: StringName = &"_active_binding_capability"
const COMMITMENT_PROPERTY: StringName = &"_active_binding_commitment"
const LEASE_SECRET_PROPERTY: StringName = &"_lease_secret"

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures += 1
	push_error("BODY_HITBOX_CAPABILITY_ENCAPSULATION: " + message)


func run() -> void:
	var fixture := _replacement_fixture()
	var world := fixture.get("world") as BodyHitboxWorld2D
	var current_capability: Variant = fixture.get("current_capability")
	var stale_capability: Variant = fixture.get("stale_capability")
	var query := fixture.get("query", {}) as Dictionary
	check(bool(fixture.get("ok", false)),
		"release/rebind fixture reaches an active replacement snapshot")
	if not bool(fixture.get("ok", false)):
		print("BODY_HITBOX_CAPABILITY_ENCAPSULATION_RESULT checks=", checks,
			" failures=", failures)
		quit(1)
		return

	var property_names := _property_names(world)
	var leaked_capability: Variant = null
	if property_names.has(LEGACY_CAPABILITY_PROPERTY):
		# This is the exact standard Godot operation from the rejected build.
		leaked_capability = world.get(LEGACY_CAPABILITY_PROPERTY)
	check(not property_names.has(LEGACY_CAPABILITY_PROPERTY),
		"property discovery omits the former live active-bearer member")
	check(leaked_capability == null,
		"Object.get cannot recover the replacement binding bearer")

	var secret := _packed_byte_property(
		current_capability, LEASE_SECRET_PROPERTY)
	var reflection_snapshot := _reflection_snapshot(world)
	check(not _contains_exact_object(reflection_snapshot, current_capability),
		"recursive world-property reflection contains no exact bearer")
	check(secret.is_empty() or not _contains_packed_bytes(reflection_snapshot, secret),
		"recursive world-property reflection contains no raw lease secret")
	check(not _contains_authorization_material(
		fixture.get("provenance", {}) as Dictionary),
		"binding provenance contains no bearer, secret, commitment, or instance ID")
	check(not _contains_authorization_material(
		world.snapshot_metadata(current_capability)),
		"snapshot metadata contains no bearer, secret, commitment, or instance ID")
	check(_has_no_capability_lookup_method(world),
		"method discovery exposes no zero-argument bearer or secret lookup")

	var stale_metadata := world.snapshot_metadata(stale_capability)
	check(stale_metadata.is_empty()
		and world.last_error == &"binding_capability_mismatch",
		"released raid-A bearer cannot read raid-B metadata")
	var empty_forger := BodyHitboxWorld2D.BindingCapability.new()
	var forged_metadata := world.snapshot_metadata(empty_forger)
	check(forged_metadata.is_empty()
		and world.last_error == &"binding_capability_mismatch",
		"new same-class bearer cannot forge replacement metadata access")

	var copied_forger := BodyHitboxWorld2D.BindingCapability.new()
	if not secret.is_empty() and _has_property(copied_forger, LEASE_SECRET_PROPERTY):
		copied_forger.set(LEASE_SECRET_PROPERTY, secret.duplicate())
	var copied_query := world.raycast(query, copied_forger)
	var copied_release := world.release_binding(copied_forger)
	var commitment_candidate: Variant = null
	if _has_property(world, COMMITMENT_PROPERTY):
		commitment_candidate = world.get(COMMITMENT_PROPERTY)
	var commitment_query := world.raycast(query, commitment_candidate)
	check(not bool(copied_query.get("accepted", true))
		and copied_query.get("reason") == &"binding_capability_mismatch"
		and not copied_release
		and not bool(commitment_query.get("accepted", true))
		and commitment_query.get("reason") == &"binding_capability_mismatch",
		"copied secret or reflected commitment cannot query or release")

	# If the rejected member existed, this candidate is the newly stolen exact
	# raid-B object. On the repair it falls back to the legitimately stale raid-A
	# object, so both paths exercise the same hostile call sequence.
	var reflected_candidate: Variant = leaked_capability
	if reflected_candidate == null:
		reflected_candidate = stale_capability
	var reflected_metadata := world.snapshot_metadata(reflected_candidate)
	var reflected_query := world.raycast(query, reflected_candidate)
	check(reflected_metadata.is_empty()
		and not bool(reflected_query.get("accepted", true))
		and world.last_error == &"binding_capability_mismatch",
		"reflected/stale candidate cannot read metadata or query replacement state")

	var duplicate_body := _body(fixture.get("target") as ZEntityId)
	var reflected_publish := world.publish_snapshot(
		0, 1, [duplicate_body], [], int(fixture.get("generation", 0)),
		int(fixture.get("token", 0)), fixture.get("owner_actor"),
		int(ZRaidIntent.Source.PLAYER), reflected_candidate)
	var reflected_release := world.release_binding(reflected_candidate)
	check(not reflected_publish and not reflected_release
		and world.lifecycle == BodyHitboxWorld2D.Lifecycle.BOUND,
		"reflected/stale candidate cannot publish or release replacement state")

	var accepted := world.raycast(query, current_capability)
	var post_query_snapshot := _reflection_snapshot(world)
	var valid_release := world.release_binding(current_capability)
	check(bool(accepted.get("accepted", false))
		and bool(accepted.get("hit", false))
		and not _contains_authorization_material(accepted)
		and not _contains_exact_object(post_query_snapshot, current_capability)
		and (secret.is_empty()
			or not _contains_packed_bytes(post_query_snapshot, secret))
		and valid_release
		and world.lifecycle == BodyHitboxWorld2D.Lifecycle.RELEASED
		and _packed_byte_property(
			current_capability, LEASE_SECRET_PROPERTY).is_empty(),
		"unexposed exact replacement bearer remains usable then releases cleanly")

	print("BODY_HITBOX_CAPABILITY_ENCAPSULATION_RESULT checks=", checks,
		" failures=", failures)
	quit(0 if failures == 0 else 1)


func _replacement_fixture() -> Dictionary:
	var first_raid := ZRaidId.from_parts(
		PackedStringArray(["hitbox", "capability_encapsulation_first"]))
	var first_admission := SessionCoordinator.new().open_offline(
		first_raid, &"capability_encapsulation_first", &"player")
	var first_authority := RaidAuthority.new()
	if not first_authority.configure(first_raid, first_admission, 71):
		return {}
	var world := BodyHitboxWorld2D.new()
	var stale_capability := world.bind_raid_authority(
		first_authority, first_admission.actor_id, ZRaidIntent.Source.PLAYER,
		first_authority.generation())
	if stale_capability == null:
		print("BODY_HITBOX_CAPABILITY_FIXTURE_FIRST_BIND_ERROR reason=", world.last_error)
		return {"error": world.last_error}
	if not world.release_binding(stale_capability):
		return {}

	var raid := ZRaidId.from_parts(
		PackedStringArray(["hitbox", "capability_encapsulation_replacement"]))
	var admission := SessionCoordinator.new().open_offline(
		raid, &"capability_encapsulation_replacement", &"player")
	var authority := RaidAuthority.new()
	if not authority.configure(raid, admission, 73):
		return {}
	var generation := authority.generation()
	var owner_actor := ZEntityId.parse(admission.actor_id.canonical_key())
	var current_capability := world.bind_raid_authority(
		authority, owner_actor, ZRaidIntent.Source.PLAYER, generation)
	if current_capability == null:
		print("BODY_HITBOX_CAPABILITY_FIXTURE_BIND_ERROR reason=", world.last_error)
		return {"error": world.last_error}
	var provenance := world.binding_provenance(current_capability)
	var token := int(provenance.get("binding_token", 0))
	var target := ZEntityId.from_parts(
		PackedStringArray(["hitbox", "capability_encapsulation_target"]))
	if not authority.authorize_actor(target, ZRaidIntent.Source.AI, generation):
		return {}
	if not world.publish_snapshot(
		0, 1, [_body(target)], [], generation, token, owner_actor,
		ZRaidIntent.Source.PLAYER, current_capability):
		return {}
	if not authority.transition(RaidAuthority.Lifecycle.ACTIVE, generation):
		return {}
	return {
		"ok": true,
		"world": world,
		"stale_capability": stale_capability,
		"current_capability": current_capability,
		"provenance": provenance,
		"generation": generation,
		"token": token,
		"owner_actor": owner_actor,
		"target": target,
		"query": {
			"request_id": ZRequestId.from_parts(PackedStringArray([
				"hitbox", "capability_encapsulation_query"])).canonical_key(),
			"raid_id": raid.canonical_key(),
			"session_id": admission.session_id.canonical_key(),
			"authority_epoch": admission.authority_epoch,
			"authority_generation": generation,
			"binding_token": token,
			"owner_actor_id": owner_actor.canonical_key(),
			"owner_actor_source": int(ZRaidIntent.Source.PLAYER),
			"query_actor_id": owner_actor.canonical_key(),
			"query_actor_source": int(ZRaidIntent.Source.PLAYER),
			"tick": 0,
			"world_revision": 1,
			"origin_raw": Vector2i(0, -600_000),
			"target_raw": Vector2i(10_000, -600_000),
			"body_mask": BODY_LAYER,
			"obstruction_mask": 0,
			"excluded_entity_ids": [],
		},
	}


func _body(target: ZEntityId) -> Dictionary:
	return {
		"entity_id": target.canonical_key(),
		"actor_source": int(ZRaidIntent.Source.AI),
		"profile_id": String(ZerkovBodyHitboxProfile.PROFILE_HUMANOID_V1),
		"body_revision": 1,
		"origin_raw": Vector2i.ZERO,
		"facing_quarter_turns": 0,
		"collision_layer": BODY_LAYER,
		"targetable": true,
	}


func _property_names(value: Object) -> Array[StringName]:
	var names: Array[StringName] = []
	for descriptor_value in value.get_property_list():
		var descriptor := descriptor_value as Dictionary
		names.append(StringName(descriptor.get("name", "")))
	return names


func _has_property(value: Object, property_name: StringName) -> bool:
	return _property_names(value).has(property_name)


func _packed_byte_property(
	value: Object,
	property_name: StringName
) -> PackedByteArray:
	if not _has_property(value, property_name):
		return PackedByteArray()
	var candidate: Variant = value.get(property_name)
	if typeof(candidate) != TYPE_PACKED_BYTE_ARRAY:
		return PackedByteArray()
	return (candidate as PackedByteArray).duplicate()


func _reflection_snapshot(value: Object) -> Dictionary:
	var snapshot: Dictionary = {}
	for descriptor_value in value.get_property_list():
		var descriptor := descriptor_value as Dictionary
		var property_name := StringName(descriptor.get("name", ""))
		if property_name.is_empty():
			continue
		snapshot[property_name] = value.get(property_name)
	for metadata_name in value.get_meta_list():
		snapshot["@metadata:%s" % String(metadata_name)] = value.get_meta(metadata_name)
	return snapshot


func _contains_exact_object(value: Variant, target: Object) -> bool:
	return _contains_exact_object_recursive(value, target, {}, [2048], 0)


func _contains_exact_object_recursive(
	value: Variant,
	target: Object,
	visited: Dictionary,
	budget: Array[int],
	depth: int
) -> bool:
	if budget[0] <= 0:
		# Exhaustion fails the proof closed instead of silently skipping members.
		return true
	budget[0] -= 1
	if typeof(value) == TYPE_CALLABLE:
		var callable := value as Callable
		if callable.get_object() == target:
			return true
		for bound in callable.get_bound_arguments():
			if _contains_exact_object_recursive(
				bound, target, visited, budget, depth + 1):
				return true
		return false
	if value is Object:
		var object_value := value as Object
		if object_value == target:
			return true
		if object_value is WeakRef:
			return _contains_exact_object_recursive(
				(object_value as WeakRef).get_ref(), target,
				visited, budget, depth + 1)
		if depth >= 8:
			return true
		var identity := str(object_value.get_instance_id())
		if visited.has(identity):
			return false
		visited[identity] = true
		for descriptor_value in object_value.get_property_list():
			var descriptor := descriptor_value as Dictionary
			if int(descriptor.get("usage", 0)) \
					& PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			var property_name := StringName(descriptor.get("name", ""))
			if not property_name.is_empty() and _contains_exact_object_recursive(
				object_value.get(property_name), target,
				visited, budget, depth + 1):
				return true
		for metadata_name in object_value.get_meta_list():
			if _contains_exact_object_recursive(
				object_value.get_meta(metadata_name), target,
				visited, budget, depth + 1):
				return true
		return false
	match typeof(value):
		TYPE_DICTIONARY:
			for key in (value as Dictionary).keys():
				if _contains_exact_object_recursive(
					(value as Dictionary)[key], target,
					visited, budget, depth + 1):
					return true
		TYPE_ARRAY:
			for entry in value as Array:
				if _contains_exact_object_recursive(
					entry, target, visited, budget, depth + 1):
					return true
	return false


func _contains_packed_bytes(value: Variant, target: PackedByteArray) -> bool:
	return _contains_packed_bytes_recursive(value, target, {}, [2048], 0)


func _contains_packed_bytes_recursive(
	value: Variant,
	target: PackedByteArray,
	visited: Dictionary,
	budget: Array[int],
	depth: int
) -> bool:
	if target.is_empty():
		return false
	if budget[0] <= 0:
		return true
	budget[0] -= 1
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		return value == target
	if typeof(value) == TYPE_CALLABLE:
		for bound in (value as Callable).get_bound_arguments():
			if _contains_packed_bytes_recursive(
				bound, target, visited, budget, depth + 1):
				return true
		return false
	if value is Object:
		var object_value := value as Object
		if object_value is WeakRef:
			return _contains_packed_bytes_recursive(
				(object_value as WeakRef).get_ref(), target,
				visited, budget, depth + 1)
		if depth >= 8:
			return true
		var identity := str(object_value.get_instance_id())
		if visited.has(identity):
			return false
		visited[identity] = true
		for descriptor_value in object_value.get_property_list():
			var descriptor := descriptor_value as Dictionary
			if int(descriptor.get("usage", 0)) \
					& PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			var property_name := StringName(descriptor.get("name", ""))
			if not property_name.is_empty() and _contains_packed_bytes_recursive(
				object_value.get(property_name), target,
				visited, budget, depth + 1):
				return true
		for metadata_name in object_value.get_meta_list():
			if _contains_packed_bytes_recursive(
				object_value.get_meta(metadata_name), target,
				visited, budget, depth + 1):
				return true
		return false
	if typeof(value) == TYPE_DICTIONARY:
		for key in (value as Dictionary).keys():
			if _contains_packed_bytes_recursive(
				(value as Dictionary)[key], target,
				visited, budget, depth + 1):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for entry in value as Array:
			if _contains_packed_bytes_recursive(
				entry, target, visited, budget, depth + 1):
				return true
	return false


func _contains_authorization_material(value: Variant) -> bool:
	if value is BodyHitboxWorld2D.BindingCapability \
			or typeof(value) == TYPE_PACKED_BYTE_ARRAY \
			or typeof(value) == TYPE_CALLABLE:
		return true
	if typeof(value) == TYPE_DICTIONARY:
		for key in (value as Dictionary).keys():
			var normalized_key := String(key).to_lower()
			if "capability" in normalized_key or "secret" in normalized_key \
					or "commitment" in normalized_key or "lease" in normalized_key:
				return true
			if _contains_authorization_material((value as Dictionary)[key]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for entry in value as Array:
			if _contains_authorization_material(entry):
				return true
	return false


func _has_no_capability_lookup_method(value: Object) -> bool:
	for descriptor_value in value.get_method_list():
		var descriptor := descriptor_value as Dictionary
		var method_name := String(descriptor.get("name", "")).to_lower()
		if not ("capability" in method_name or "secret" in method_name \
				or "commitment" in method_name or "lease" in method_name):
			continue
		if (descriptor.get("args", []) as Array).is_empty():
			return false
	return true
