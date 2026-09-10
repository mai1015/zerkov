extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/inventory_mutation_routing_contract.gd

const MAX_TRANSFER_DISTANCE_RAW: int = 2_000_000
const ROUTED_COMMAND_BASE: int = 1 << 32


class RoutingIdentityPort extends ZInventoryIdentityPort:
	var session_key: String = ""
	var actor_key: String = ""
	var epoch: int = 0
	var raid_generation: int = 0
	var opaque_native_actor: int = 0
	var owned_inventories: Dictionary = {}
	var ownership_enabled: bool = true

	func native_actor_id(
		p_session_id: ZSessionId,
		p_actor_id: ZEntityId,
		p_authority_epoch: int,
		p_generation: int
	) -> int:
		if p_session_id == null or p_actor_id == null:
			return 0
		if p_session_id.canonical_key() != session_key \
			or p_actor_id.canonical_key() != actor_key \
			or p_authority_epoch != epoch \
			or p_generation != raid_generation:
			return 0
		return opaque_native_actor

	func actor_owns_inventory(
		p_session_id: ZSessionId,
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_authority_epoch: int,
		p_generation: int
	) -> bool:
		return (
			ownership_enabled
			and native_actor_id(
				p_session_id, p_actor_id, p_authority_epoch, p_generation
			) == opaque_native_actor
			and owned_inventories.has(p_inventory_id)
		)


class RoutingWorldPolicyPort extends ZInventoryWorldPolicyPort:
	var expected_actor_key: String = ""
	var expected_generation: int = 0
	var world_inventories: Dictionary = {}
	var distance_raw: int = 1_000_000
	var currently_visible: bool = true
	var current_access_state: StringName = ACCESS_OPEN
	var transfer_allowed: bool = true
	var policy_calls: int = 0
	var after_first_allowed_check: Callable = Callable()
	var callback_fired: bool = false

	func is_world_inventory(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> bool:
		return _binding_matches(p_actor_id, p_generation) \
			and world_inventories.has(p_inventory_id)

	func authoritative_distance_raw(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> int:
		if not is_world_inventory(p_actor_id, p_inventory_id, p_generation):
			return -1
		return distance_raw

	func is_currently_visible(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> bool:
		return is_world_inventory(p_actor_id, p_inventory_id, p_generation) \
			and currently_visible

	func access_state(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> StringName:
		if not is_world_inventory(p_actor_id, p_inventory_id, p_generation):
			return ACCESS_UNAVAILABLE
		return current_access_state

	func allows_transfer(
		p_actor_id: ZEntityId,
		p_source_inventory_id: int,
		p_destination_inventory_id: int,
		p_item_id: int,
		p_generation: int
	) -> bool:
		policy_calls += 1
		var allowed := (
			_binding_matches(p_actor_id, p_generation)
			and p_source_inventory_id > 0
			and p_destination_inventory_id > 0
			and p_item_id > 0
			and transfer_allowed
		)
		if allowed and not callback_fired and after_first_allowed_check.is_valid():
			callback_fired = true
			after_first_allowed_check.call()
		return allowed

	func arm_callback(callback: Callable) -> void:
		after_first_allowed_check = callback
		callback_fired = false

	func clear_callback() -> void:
		after_first_allowed_check = Callable()
		callback_fired = false

	func _binding_matches(p_actor_id: ZEntityId, p_generation: int) -> bool:
		return p_actor_id != null \
			and p_actor_id.canonical_key() == expected_actor_key \
			and p_generation == expected_generation


var checks: int = 0
var failures: int = 0
var next_sequence: int = 1
var next_command_id: int = ROUTED_COMMAND_BASE

var owner: RaidInventoryOwner
var authority: InventoryAuthority
var adapter: InventoryIntentAdapter
var identity_port: RoutingIdentityPort
var world_policy_port: RoutingWorldPolicyPort
var admission: ZSessionAdmission
var session_id: ZSessionId
var actor_id: ZEntityId
var owner_generation: int = 0
var pockets_id: int = 0
var rig_id: int = 0
var backpack_id: int = 0
var unowned_inventory_id: int = 0
var reentrant_result: Dictionary = {}


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_MUTATION_ROUTING_CONTRACT: " + message)


func run() -> void:
	if not _setup():
		_finish()
		return
	_test_strict_schemas_and_authorization()
	_test_same_inventory_routes()
	_test_world_routes()
	_test_phase_dispatch_order()
	_cleanup()
	_finish()


func _setup() -> bool:
	owner = RaidInventoryOwner.new()
	owner.name = "InventoryMutationRoutingOwner"
	root.add_child(owner)
	check(owner.configure(), "inventory lifecycle owner configures")
	if owner.lifecycle != RaidInventoryOwner.Lifecycle.ACTIVE:
		return false
	owner_generation = owner.generation()
	check(owner.materialize_loot_fixture(owner_generation),
		"deterministic world loot materializes")
	authority = owner.raid_authority()
	unowned_inventory_id = authority.create_inventory(
		String(ZerkovInventoryCatalog.PROFILE_PLAYER_RAID))
	check(unowned_inventory_id > 0,
		"authorization fixture creates a distinct unowned inventory")
	pockets_id = _root_container_by_definition(ZerkovInventoryCatalog.CONTAINER_POCKETS)
	rig_id = _root_container_by_definition(ZerkovInventoryCatalog.CONTAINER_RIG)
	backpack_id = _root_container_by_definition(ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	check(pockets_id > 0 and rig_id > 0 and backpack_id > 0,
		"player mutation fixture resolves stable root containers")

	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"inventory", "mutation_routing_contract"
	]))
	session_id = ZSessionId.from_parts(PackedStringArray([
		"inventory", "mutation_routing_session"
	]))
	actor_id = ZEntityId.from_parts(PackedStringArray([
		"inventory", "mutation_routing_actor"
	]))
	var admission_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray([
			"inventory", "mutation_routing_admission"
		])),
		raid_id,
		&"routing_profile",
		&"player",
		23
	)
	admission = ZSessionAdmission.accept_local(
		admission_request, session_id, actor_id)
	check(admission != null and admission.is_usable(),
		"routing contract admission is usable")
	if admission == null or not admission.is_usable():
		return false

	identity_port = RoutingIdentityPort.new()
	identity_port.session_key = session_id.canonical_key()
	identity_port.actor_key = actor_id.canonical_key()
	identity_port.epoch = admission.authority_epoch
	identity_port.raid_generation = admission.generation
	identity_port.opaque_native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity_port.owned_inventories[owner.raid_player_inventory_id] = true

	world_policy_port = RoutingWorldPolicyPort.new()
	world_policy_port.expected_actor_key = actor_id.canonical_key()
	world_policy_port.expected_generation = admission.generation
	world_policy_port.world_inventories[owner.world_crate_inventory_id] = true
	world_policy_port.world_inventories[owner.corpse_inventory_id] = true

	adapter = InventoryIntentAdapter.new()
	check(adapter.configure(
		owner,
		admission,
		identity_port,
		world_policy_port,
		MAX_TRANSFER_DISTANCE_RAW
	), "routing adapter configures with trusted ports")
	return true


func _test_strict_schemas_and_authorization() -> void:
	var splint_id := _seed_player_item(
		ZerkovInventoryCatalog.ITEM_SPLINT, 1, _spatial(pockets_id, 0, 0, false))
	check(splint_id > 0, "player fixture seeds a rotatable item")
	var valid_move := _single_payload(
		splint_id, _spatial(pockets_id, 1, 0, false))
	_assert_rejection_atomic(
		_make_intent(
			"unsupported_kind", &"inventory_swap",
			{"inventory_command_id": _take_command_id()}),
		&"intent_kind_unsupported",
		"direct submission rejects an unsupported inventory mutation kind"
	)

	var extra_key := valid_move.duplicate(true)
	extra_key["unexpected"] = true
	_assert_rejection_atomic(
		_make_intent("move_extra_key", InventoryIntentAdapter.INTENT_KIND_MOVE, extra_key),
		&"payload_schema_invalid",
		"move schema rejects extra keys"
	)
	var malformed_location := valid_move.duplicate(true)
	malformed_location["destination_location"] = {
		"kind": "spatial", "container": pockets_id,
		"x": 1, "y": 0, "rotated": false, "unexpected": 1,
	}
	_assert_rejection_atomic(
		_make_intent(
			"move_bad_location", InventoryIntentAdapter.INTENT_KIND_MOVE,
			malformed_location),
		&"payload_schema_invalid",
		"location schema rejects unrecognized fields"
	)
	var wrong_rotate_type := {
		"inventory_command_id": _take_command_id(),
		"inventory_id": owner.raid_player_inventory_id,
		"item_id": splint_id,
		"rotated": 1,
		"expected_revision": authority.inventory_revision(owner.raid_player_inventory_id),
	}
	_assert_rejection_atomic(
		_make_intent(
			"rotate_wrong_type", InventoryIntentAdapter.INTENT_KIND_ROTATE,
			wrong_rotate_type),
		&"payload_schema_invalid",
		"rotate schema requires a boolean orientation"
	)

	var zero_command := valid_move.duplicate(true)
	zero_command["inventory_command_id"] = 0
	_assert_rejection_atomic(
		_make_intent(
			"move_zero_command", InventoryIntentAdapter.INTENT_KIND_MOVE,
			zero_command),
		&"payload_schema_invalid",
		"routed mutations forbid native auto-allocation"
	)

	var world_move := {
		"inventory_command_id": _take_command_id(),
		"inventory_id": owner.world_crate_inventory_id,
		"item_id": _first_item_id(owner.world_crate_inventory_id),
		"destination_location": _spatial(owner.world_crate_container_id(), 0, 2, false),
		"expected_revision": authority.inventory_revision(owner.world_crate_inventory_id),
	}
	_assert_rejection_atomic(
		_make_intent(
			"world_move_not_owned", InventoryIntentAdapter.INTENT_KIND_MOVE,
			world_move),
		&"destination_not_owned",
		"same-inventory mutation requires trusted ownership"
	)

	var stale_move := valid_move.duplicate(true)
	stale_move["inventory_command_id"] = _take_command_id()
	stale_move["expected_revision"] = int(stale_move["expected_revision"]) + 1
	_assert_rejection_atomic(
		_make_intent("move_stale", InventoryIntentAdapter.INTENT_KIND_MOVE, stale_move),
		&"inventory_revision_stale",
		"single-inventory mutation requires the exact revision"
	)

	var aliased_quick_revision := {
		"inventory_command_id": _take_command_id(),
		"source_inventory_id": owner.raid_player_inventory_id,
		"destination_inventory_id": owner.raid_player_inventory_id,
		"item_id": splint_id,
		"expected_source_revision": authority.inventory_revision(
			owner.raid_player_inventory_id),
		"expected_destination_revision": authority.inventory_revision(
			owner.raid_player_inventory_id) + 1,
	}
	_assert_rejection_atomic(
		_make_intent(
			"quick_alias_revision_mismatch",
			InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER,
			aliased_quick_revision),
		&"payload_schema_invalid",
		"same-inventory quick transfer requires one coherent exact revision"
	)

	var unowned_source := {
		"inventory_command_id": _take_command_id(),
		"source_inventory_id": unowned_inventory_id,
		"destination_inventory_id": owner.raid_player_inventory_id,
		"item_id": splint_id,
		"expected_source_revision": authority.inventory_revision(
			unowned_inventory_id),
		"expected_destination_revision": authority.inventory_revision(
			owner.raid_player_inventory_id),
	}
	_assert_rejection_atomic(
		_make_intent(
			"quick_unowned_source",
			InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER,
			unowned_source),
		&"source_not_owned",
		"non-world cross-inventory source requires trusted ownership"
	)

	var occupied_move := valid_move.duplicate(true)
	occupied_move["inventory_command_id"] = _take_command_id()
	occupied_move["destination_location"] = _spatial(pockets_id, 3, 1, true)
	_assert_native_rejection_atomic(
		_make_intent(
			"move_native_out_of_bounds", InventoryIntentAdapter.INTENT_KIND_MOVE,
			occupied_move),
		"native move validation rejects atomically"
	)


func _test_same_inventory_routes() -> void:
	var inventory_id := owner.raid_player_inventory_id
	var splint_id := _item_id_by_definition(
		inventory_id, ZerkovInventoryCatalog.ITEM_SPLINT)
	var move_payload := _single_payload(
		splint_id, _spatial(pockets_id, 1, 0, false))
	var move_intent := _make_intent(
		"move_accept", InventoryIntentAdapter.INTENT_KIND_MOVE, move_payload)
	var before_move_revision := authority.inventory_revision(inventory_id)
	var move_result := adapter.submit_intent(move_intent)
	_assert_typed_accept(
		move_result, InventoryIntentAdapter.INTENT_KIND_MOVE,
		int(move_payload["inventory_command_id"]), 1,
		"same-inventory move")
	check(authority.inventory_revision(inventory_id) == before_move_revision + 1,
		"move advances exactly one relevant revision")
	check(_location_matches(
		_item_location(inventory_id, splint_id),
		_spatial(pockets_id, 1, 0, false)),
		"move commits the proposed placement")

	var bytes_after_move := authority.snapshot(inventory_id).canonical_bytes()
	var move_replay := adapter.submit_intent(move_intent)
	check(bool(move_replay.get("accepted", false)) \
		and bool(move_replay.get("replayed", false)) \
		and move_replay.get("operation", &"") == InventoryIntentAdapter.INTENT_KIND_MOVE,
		"exact move replay returns the copied original outcome")
	check(authority.snapshot(inventory_id).canonical_bytes() == bytes_after_move,
		"exact move replay does not mutate canonical state")
	var replay_copy := adapter.receipt_for_request(move_intent.request_id)
	replay_copy["status"]["ok"] = false
	replay_copy["revisions"].clear()
	var pristine_copy := adapter.receipt_for_request(move_intent.request_id)
	check(bool((pristine_copy.get("status", {}) as Dictionary).get("ok", false)) \
		and (pristine_copy.get("revisions", []) as Array).size() == 1,
		"typed routed receipts are deeply copied")

	var changed_move := move_intent.snapshot()
	changed_move.payload["destination_location"] = _spatial(pockets_id, 0, 0, false)
	_assert_direct_rejection_atomic(
		changed_move, &"request_id_conflict",
		"same request id with changed placement conflicts")
	var command_conflict_payload := _single_payload(
		splint_id, _spatial(pockets_id, 0, 0, false))
	command_conflict_payload["inventory_command_id"] = int(
		move_payload["inventory_command_id"])
	_assert_rejection_atomic(
		_make_intent(
			"move_command_conflict", InventoryIntentAdapter.INTENT_KIND_MOVE,
			command_conflict_payload),
		&"inventory_command_id_conflict",
		"native command identity cannot be rebound to another request"
	)

	var rotate_payload := {
		"inventory_command_id": _take_command_id(),
		"inventory_id": inventory_id,
		"item_id": splint_id,
		"rotated": true,
		"expected_revision": authority.inventory_revision(inventory_id),
	}
	var rotate_result := adapter.submit_intent(_make_intent(
		"rotate_accept", InventoryIntentAdapter.INTENT_KIND_ROTATE,
		rotate_payload))
	_assert_typed_accept(
		rotate_result, InventoryIntentAdapter.INTENT_KIND_ROTATE,
		int(rotate_payload["inventory_command_id"]), 1,
		"same-inventory rotate")
	check(bool(_item_location(inventory_id, splint_id).get("rotated", false)),
		"rotate commits only the requested orientation")

	var ammo_source_id := _seed_player_item(
		ZerkovInventoryCatalog.ITEM_AMMO_762, 20,
		_spatial(rig_id, 0, 0, false))
	var ammo_destination_id := _seed_player_item(
		ZerkovInventoryCatalog.ITEM_AMMO_762, 10,
		_spatial(rig_id, 1, 0, false))
	check(ammo_source_id > 0 and ammo_destination_id > 0,
		"player fixture seeds compatible stacks")
	var split_payload := {
		"inventory_command_id": _take_command_id(),
		"inventory_id": inventory_id,
		"item_id": ammo_source_id,
		"quantity": 5,
		"destination_location": _spatial(rig_id, 2, 0, false),
		"expected_revision": authority.inventory_revision(inventory_id),
	}
	var split_result := adapter.submit_intent(_make_intent(
		"split_accept", InventoryIntentAdapter.INTENT_KIND_SPLIT,
		split_payload))
	_assert_typed_accept(
		split_result, InventoryIntentAdapter.INTENT_KIND_SPLIT,
		int(split_payload["inventory_command_id"]), 1,
		"same-inventory split")
	var split_item_id := int(split_result.get("new_item_id", 0))
	check(split_item_id > 0 \
		and _item_quantity(inventory_id, ammo_source_id) == 15 \
		and _item_quantity(inventory_id, split_item_id) == 5,
		"split exposes the native new item identity and conserves quantity")

	var invalid_split_payload := split_payload.duplicate(true)
	invalid_split_payload["inventory_command_id"] = _take_command_id()
	invalid_split_payload["quantity"] = 99
	invalid_split_payload["expected_revision"] = authority.inventory_revision(inventory_id)
	invalid_split_payload["destination_location"] = _spatial(rig_id, 3, 0, false)
	_assert_native_rejection_atomic(
		_make_intent(
			"split_too_large", InventoryIntentAdapter.INTENT_KIND_SPLIT,
			invalid_split_payload),
		"invalid split quantity rejects atomically"
	)

	var merge_payload := {
		"inventory_command_id": _take_command_id(),
		"inventory_id": inventory_id,
		"source_item_id": split_item_id,
		"destination_item_id": ammo_destination_id,
		"expected_revision": authority.inventory_revision(inventory_id),
	}
	var merge_result := adapter.submit_intent(_make_intent(
		"merge_accept", InventoryIntentAdapter.INTENT_KIND_MERGE,
		merge_payload))
	_assert_typed_accept(
		merge_result, InventoryIntentAdapter.INTENT_KIND_MERGE,
		int(merge_payload["inventory_command_id"]), 1,
		"same-inventory merge")
	check(not _inventory_has_item(inventory_id, split_item_id) \
		and _item_quantity(inventory_id, ammo_destination_id) == 15,
		"merge destroys the source and preserves the destination identity")

	var bandage_id := _seed_player_item(
		ZerkovInventoryCatalog.ITEM_BANDAGE, 2,
		_spatial(backpack_id, 0, 0, false))
	check(bandage_id > 0, "player fixture seeds a quick-transfer item")
	var quick_payload := {
		"inventory_command_id": _take_command_id(),
		"source_inventory_id": inventory_id,
		"destination_inventory_id": inventory_id,
		"item_id": bandage_id,
		"expected_source_revision": authority.inventory_revision(inventory_id),
		"expected_destination_revision": authority.inventory_revision(inventory_id),
	}
	var quick_result := adapter.submit_intent(_make_intent(
		"quick_same_accept", InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER,
		quick_payload))
	_assert_typed_accept(
		quick_result, InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER,
		int(quick_payload["inventory_command_id"]), 1,
		"complete-only same-inventory quick transfer")
	check(int(quick_result.get("remaining_quantity", -1)) == 0 \
		and int(quick_result.get("transferred_quantity", 0)) == 2,
		"quick transfer exposes a complete-only typed quantity outcome")


func _test_world_routes() -> void:
	var inventory_id := owner.raid_player_inventory_id
	var loot_item_id := _item_id_by_definition(
		owner.world_crate_inventory_id,
		ZerkovInventoryCatalog.ITEM_SEALED_DOCUMENTS)
	check(loot_item_id > 0, "world fixture exposes placement-aware loot")
	var loot_location := _spatial(backpack_id, 2, 0, false)
	var base_loot_payload := _loot_payload(loot_item_id, loot_location)

	var wrong_destination := base_loot_payload.duplicate(true)
	wrong_destination["inventory_command_id"] = _take_command_id()
	wrong_destination["destination_inventory_id"] = owner.corpse_inventory_id
	wrong_destination["expected_destination_revision"] = authority.inventory_revision(
		owner.corpse_inventory_id)
	_assert_rejection_atomic(
		_make_intent(
			"loot_wrong_destination", InventoryIntentAdapter.INTENT_KIND_LOOT,
			wrong_destination),
		&"destination_not_owned",
		"placement loot requires trusted destination ownership"
	)

	var non_world_source := base_loot_payload.duplicate(true)
	non_world_source["inventory_command_id"] = _take_command_id()
	world_policy_port.world_inventories.erase(owner.world_crate_inventory_id)
	_assert_rejection_atomic(
		_make_intent(
			"loot_non_world_source", InventoryIntentAdapter.INTENT_KIND_LOOT,
			non_world_source),
		&"world_target_invalid",
		"placement loot accepts only an authoritative world source"
	)
	world_policy_port.world_inventories[owner.world_crate_inventory_id] = true

	var stale_source := _loot_payload(loot_item_id, loot_location)
	stale_source["expected_source_revision"] = int(
		stale_source["expected_source_revision"]) + 1
	_assert_rejection_atomic(
		_make_intent(
			"loot_stale_source", InventoryIntentAdapter.INTENT_KIND_LOOT,
			stale_source),
		&"source_revision_stale",
		"placement loot requires the exact source revision"
	)
	var stale_destination := _loot_payload(loot_item_id, loot_location)
	stale_destination["expected_destination_revision"] = int(
		stale_destination["expected_destination_revision"]) + 1
	_assert_rejection_atomic(
		_make_intent(
			"loot_stale_destination", InventoryIntentAdapter.INTENT_KIND_LOOT,
			stale_destination),
		&"destination_revision_stale",
		"placement loot requires the exact destination revision"
	)

	world_policy_port.transfer_allowed = false
	var denied_payload := _loot_payload(loot_item_id, loot_location)
	var denied_intent := _make_intent(
		"loot_policy_denied", InventoryIntentAdapter.INTENT_KIND_LOOT,
		denied_payload)
	_assert_rejection_atomic(
		denied_intent, &"world_policy_denied",
		"placement loot applies the final world-policy gate")
	var calls_before_replay := world_policy_port.policy_calls
	world_policy_port.transfer_allowed = true
	var denied_replay := adapter.submit_intent(denied_intent)
	check(bool(denied_replay.get("replayed", false)) \
		and denied_replay.get("reason", &"") == &"world_policy_denied" \
		and world_policy_port.policy_calls == calls_before_replay,
		"rejected world receipt replays before changed policy facts")

	world_policy_port.distance_raw = MAX_TRANSFER_DISTANCE_RAW + 1
	var far_payload := _loot_payload(loot_item_id, loot_location)
	_assert_rejection_atomic(
		_make_intent(
			"loot_out_of_range", InventoryIntentAdapter.INTENT_KIND_LOOT,
			far_payload),
		&"out_of_range",
		"placement loot requires authoritative interaction range"
	)
	world_policy_port.distance_raw = 1_000_000

	var invalid_placement := _loot_payload(
		loot_item_id, _spatial(backpack_id, 99, 99, false))
	_assert_native_rejection_atomic(
		_make_intent(
			"loot_invalid_placement",
			InventoryIntentAdapter.INTENT_KIND_LOOT,
			invalid_placement),
		"native placement-aware loot validation rejects atomically"
	)

	world_policy_port.arm_callback(func() -> void:
		identity_port.ownership_enabled = false
	)
	var revoked_payload := _loot_payload(loot_item_id, loot_location)
	_assert_rejection_atomic(
		_make_intent(
			"loot_ownership_revoked", InventoryIntentAdapter.INTENT_KIND_LOOT,
			revoked_payload),
		&"destination_not_owned",
		"ownership revoked during world policy is rechecked before native mutation"
	)
	identity_port.ownership_enabled = true
	world_policy_port.clear_callback()

	var loot_payload := _loot_payload(loot_item_id, loot_location)
	var loot_intent := _make_intent(
		"loot_accept", InventoryIntentAdapter.INTENT_KIND_LOOT, loot_payload)
	var pristine_loot_replay := loot_intent.snapshot()
	world_policy_port.arm_callback(func() -> void:
		reentrant_result = adapter.submit_intent(pristine_loot_replay)
		loot_intent.kind = &"inventory_swap"
		loot_intent.payload["item_id"] = 1
		loot_intent.payload["destination_location"] = _spatial(
			backpack_id, 99, 99, true)
	)
	var source_revision_before := authority.inventory_revision(
		owner.world_crate_inventory_id)
	var destination_revision_before := authority.inventory_revision(inventory_id)
	var policy_calls_before_loot := world_policy_port.policy_calls
	var loot_result := adapter.submit_intent(loot_intent)
	world_policy_port.clear_callback()
	_assert_typed_accept(
		loot_result, InventoryIntentAdapter.INTENT_KIND_LOOT,
		int(loot_payload["inventory_command_id"]), 2,
		"placement-aware world loot")
	check(not bool(reentrant_result.get("accepted", false)) \
		and reentrant_result.get("reason", &"") == &"reentrant_submission",
		"policy callbacks cannot recursively commit or replace the in-flight receipt")
	check(authority.inventory_revision(owner.world_crate_inventory_id) \
		== source_revision_before + 1 \
		and authority.inventory_revision(inventory_id) \
		== destination_revision_before + 1,
		"placement loot advances both exact relevant revisions once")
	check(world_policy_port.policy_calls == policy_calls_before_loot + 2,
		"accepted world mutation passes both world-policy gates")
	check(not _inventory_has_item(owner.world_crate_inventory_id, loot_item_id) \
		and _location_matches(_item_location(inventory_id, loot_item_id), loot_location),
		"caller mutation during policy cannot change snapshotted placement loot")
	var calls_before_accepted_replay := world_policy_port.policy_calls
	var accepted_loot_replay := adapter.submit_intent(pristine_loot_replay)
	check(bool(accepted_loot_replay.get("accepted", false)) \
		and bool(accepted_loot_replay.get("replayed", false)) \
		and world_policy_port.policy_calls == calls_before_accepted_replay,
		"accepted routed replay returns before mutable world facts")

	var quick_item_id := _item_id_by_definition(
		owner.world_crate_inventory_id,
		ZerkovInventoryCatalog.ITEM_GOLD_WATCH)
	check(quick_item_id > 0, "world fixture exposes a quick-transfer item")
	var quick_payload := {
		"inventory_command_id": _take_command_id(),
		"source_inventory_id": owner.world_crate_inventory_id,
		"destination_inventory_id": inventory_id,
		"item_id": quick_item_id,
		"expected_source_revision": authority.inventory_revision(
			owner.world_crate_inventory_id),
		"expected_destination_revision": authority.inventory_revision(inventory_id),
	}
	var quick_result := adapter.submit_intent(_make_intent(
		"quick_world_accept", InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER,
		quick_payload))
	_assert_typed_accept(
		quick_result, InventoryIntentAdapter.INTENT_KIND_QUICK_TRANSFER,
		int(quick_payload["inventory_command_id"]), 2,
		"complete-only world quick transfer")
	check(_inventory_has_item(inventory_id, quick_item_id) \
		and not _inventory_has_item(owner.world_crate_inventory_id, quick_item_id) \
		and int(quick_result.get("remaining_quantity", -1)) == 0,
		"world quick transfer commits once without a partial remainder")


func _test_phase_dispatch_order() -> void:
	var raid_authority := RaidAuthority.new()
	check(raid_authority.configure(admission.raid_id, admission, 131),
		"RaidAuthority configures for routed phase dispatch")
	check(adapter.register_with_raid_authority(raid_authority),
		"expanded allowlist registers in the canonical interaction phase")
	check(raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, admission.generation),
		"phase routing fixture activates")

	var inventory_id := owner.raid_player_inventory_id
	var splint_id := _item_id_by_definition(
		inventory_id, ZerkovInventoryCatalog.ITEM_SPLINT)
	var expected_revision := authority.inventory_revision(inventory_id)
	var low_payload := {
		"inventory_command_id": _take_command_id(),
		"inventory_id": inventory_id,
		"item_id": splint_id,
		"destination_location": _spatial(rig_id, 3, 1, true),
		"expected_revision": expected_revision,
	}
	var high_payload := low_payload.duplicate(true)
	high_payload["inventory_command_id"] = _take_command_id()
	high_payload["destination_location"] = _spatial(rig_id, 3, 2, true)
	var low_intent := _make_intent(
		"phase_move_low", InventoryIntentAdapter.INTENT_KIND_MOVE,
		low_payload, 1, 1)
	var high_intent := _make_intent(
		"phase_move_high", InventoryIntentAdapter.INTENT_KIND_MOVE,
		high_payload, 1, 2)
	var ignored_intent := _make_intent(
		"phase_unowned_kind", &"inventory_swap",
		{"inventory_command_id": _take_command_id()}, 1, 3)
	check(raid_authority.enqueue_intent(
		high_intent, admission.generation),
		"higher-sequence routed mutation may arrive first")
	check(raid_authority.enqueue_intent(
		ignored_intent, admission.generation),
		"unowned inventory kind may share the bounded queue")
	check(raid_authority.enqueue_intent(
		low_intent, admission.generation),
		"lower-sequence routed mutation may arrive last")
	check(raid_authority.advance_one(admission.generation),
		"supported business rejection does not fail the phase handler")
	var low_receipt := adapter.receipt_for_request(low_intent.request_id)
	var high_receipt := adapter.receipt_for_request(high_intent.request_id)
	check(bool(low_receipt.get("accepted", false)) \
		and low_receipt.get("operation", &"") \
		== InventoryIntentAdapter.INTENT_KIND_MOVE,
		"canonical lower sequence wins routed mutation competition")
	check(not bool(high_receipt.get("accepted", false)) \
		and high_receipt.get("reason", &"") == &"inventory_revision_stale",
		"later routed mutation receives a stable stale-revision receipt")
	check(adapter.receipt_for_request(ignored_intent.request_id).is_empty(),
		"allowlist-only dispatch ignores unsupported inventory kinds")
	check(raid_authority.lifecycle == RaidAuthority.Lifecycle.ACTIVE \
		and raid_authority.last_processed_tick == 1,
		"business rejection leaves RaidAuthority active and advances the tick")
	check(raid_authority.teardown(admission.generation),
		"phase routing fixture tears down")


func _single_payload(item_id: int, destination_location: Dictionary) -> Dictionary:
	return {
		"inventory_command_id": _take_command_id(),
		"inventory_id": owner.raid_player_inventory_id,
		"item_id": item_id,
		"destination_location": destination_location.duplicate(true),
		"expected_revision": authority.inventory_revision(owner.raid_player_inventory_id),
	}


func _loot_payload(item_id: int, destination_location: Dictionary) -> Dictionary:
	return {
		"inventory_command_id": _take_command_id(),
		"source_inventory_id": owner.world_crate_inventory_id,
		"destination_inventory_id": owner.raid_player_inventory_id,
		"item_id": item_id,
		"destination_location": destination_location.duplicate(true),
		"expected_source_revision": authority.inventory_revision(
			owner.world_crate_inventory_id),
		"expected_destination_revision": authority.inventory_revision(
			owner.raid_player_inventory_id),
	}


func _make_intent(
	label: String,
	kind: StringName,
	payload: Dictionary,
	target_tick: int = -1,
	sequence: int = -1
) -> ZRaidIntent:
	var resolved_sequence := next_sequence if sequence < 0 else sequence
	if sequence < 0:
		next_sequence += 1
	var resolved_tick := resolved_sequence if target_tick < 0 else target_tick
	return ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["inventory", label])),
		ZRaidIntent.Source.PLAYER,
		session_id,
		actor_id,
		admission.authority_epoch,
		admission.generation,
		resolved_tick,
		resolved_sequence,
		kind,
		payload.duplicate(true)
	)


func _take_command_id() -> int:
	var value := next_command_id
	next_command_id += 1
	return value


func _spatial(
	container_id: int,
	x: int,
	y: int,
	rotated: bool
) -> Dictionary:
	return {
		"kind": "spatial",
		"container": container_id,
		"x": x,
		"y": y,
		"rotated": rotated,
	}


func _seed_player_item(
	definition_id: StringName,
	quantity: int,
	location: Dictionary
) -> int:
	var result: Dictionary = authority.insert_item(
		owner.raid_player_inventory_id,
		String(definition_id),
		quantity,
		location,
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		_take_command_id()
	)
	check(bool(result.get("accepted", false)),
		"test setup inserts " + String(definition_id))
	return int(result.get("new_item_id", 0))


func _assert_typed_accept(
	result: Dictionary,
	operation: StringName,
	command_id: int,
	revision_count: int,
	label: String
) -> void:
	check(bool(result.get("accepted", false)) \
		and not bool(result.get("replayed", true)) \
		and not bool(result.get("queued", true)),
		label + " is accepted synchronously")
	check(result.get("operation", &"") == operation,
		label + " reports its stable operation kind")
	check(int(result.get("inventory_command_id", 0)) == command_id \
		and int(result.get("command_id", 0)) == command_id \
		and int(result.get("native_command_id", 0)) == command_id,
		label + " preserves separate stable command identity")
	check(bool((result.get("status", {}) as Dictionary).get("ok", false)) \
		and int(result.get("native_status_code", -1)) == InventoryCatalog.STATUS_OK,
		label + " exposes a controller-compatible typed status")
	check((result.get("revisions", []) as Array).size() == revision_count,
		label + " exposes every relevant native revision")


func _assert_rejection_atomic(
	intent: ZRaidIntent,
	expected_reason: StringName,
	label: String
) -> Dictionary:
	var before := _canonical_state()
	var result := adapter.submit_intent(intent)
	check(not bool(result.get("accepted", false)), label + " is rejected")
	check(result.get("reason", &"") == expected_reason,
		label + " reports stable reason " + String(expected_reason))
	check(_states_equal(before, _canonical_state()),
		label + " leaves canonical bytes and revisions unchanged")
	return result


func _assert_direct_rejection_atomic(
	intent: ZRaidIntent,
	expected_reason: StringName,
	label: String
) -> Dictionary:
	return _assert_rejection_atomic(intent, expected_reason, label)


func _assert_native_rejection_atomic(
	intent: ZRaidIntent,
	label: String
) -> Dictionary:
	var result := _assert_rejection_atomic(
		intent, &"native_command_rejected", label)
	check(int((result.get("status", {}) as Dictionary).get("code", -1)) \
		!= InventoryCatalog.STATUS_OK,
		label + " preserves the native structured rejection status")
	return result


func _canonical_state() -> Dictionary:
	return {
		"player": _inventory_state(owner.raid_player_inventory_id),
		"crate": _inventory_state(owner.world_crate_inventory_id),
		"corpse": _inventory_state(owner.corpse_inventory_id),
		"unowned": _inventory_state(unowned_inventory_id),
	}


func _inventory_state(inventory_id: int) -> Dictionary:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return {"revision": -1, "bytes": PackedByteArray()}
	return {
		"revision": authority.inventory_revision(inventory_id),
		"bytes": snapshot.canonical_bytes(),
	}


func _states_equal(left: Dictionary, right: Dictionary) -> bool:
	for key in ["player", "crate", "corpse", "unowned"]:
		var left_entry := left.get(key, {}) as Dictionary
		var right_entry := right.get(key, {}) as Dictionary
		if int(left_entry.get("revision", -1)) != int(right_entry.get("revision", -2)) \
			or (left_entry.get("bytes", PackedByteArray()) as PackedByteArray) \
			!= (right_entry.get("bytes", PackedByteArray()) as PackedByteArray):
			return false
	return true


func _root_container_by_definition(definition_id: StringName) -> int:
	var snapshot := authority.snapshot(owner.raid_player_inventory_id)
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
			and StringName(container.get(
				"container_definition_identifier", &"")) == definition_id:
			return int(container.get("id", 0))
	return 0


func _first_item_id(inventory_id: int) -> int:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null or snapshot.get_items().is_empty():
		return 0
	return int((snapshot.get_items()[0] as Dictionary).get("id", 0))


func _item_id_by_definition(inventory_id: int, definition_id: StringName) -> int:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return 0
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if StringName(item.get("item_definition_identifier", &"")) == definition_id:
			return int(item.get("id", 0))
	return 0


func _inventory_has_item(inventory_id: int, item_id: int) -> bool:
	return not _item(inventory_id, item_id).is_empty()


func _item(inventory_id: int, item_id: int) -> Dictionary:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return {}
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return item
	return {}


func _item_location(inventory_id: int, item_id: int) -> Dictionary:
	return (_item(inventory_id, item_id).get("location", {}) as Dictionary).duplicate(true)


func _location_matches(actual: Dictionary, expected: Dictionary) -> bool:
	var kind := String(expected.get("kind", ""))
	if String(actual.get("kind", "")) != kind \
		or int(actual.get("container", 0)) != int(expected.get("container", -1)):
		return false
	match kind:
		"spatial":
			return int(actual.get("x", -1)) == int(expected.get("x", -2)) \
				and int(actual.get("y", -1)) == int(expected.get("y", -2)) \
				and bool(actual.get("rotated", false)) \
				== bool(expected.get("rotated", false))
		"slot":
			return String(actual.get("slot_identifier", "")) \
				== String(expected.get("slot_identifier", ""))
		"list":
			return int(actual.get("ordinal", -1)) == int(expected.get("ordinal", -2))
	return false


func _item_quantity(inventory_id: int, item_id: int) -> int:
	return int(_item(inventory_id, item_id).get("quantity", 0))


func _cleanup() -> void:
	if authority != null and unowned_inventory_id > 0 \
		and authority.has_inventory(unowned_inventory_id):
		check(bool(authority.unload_inventory(unowned_inventory_id).get("ok", false)),
			"authorization fixture unloads its unowned inventory")
	if owner != null and owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
		check(owner.teardown(owner_generation),
			"routing inventory owner tears down")
	if owner != null:
		owner.queue_free()


func _finish() -> void:
	print("INVENTORY_MUTATION_ROUTING_RESULT checks=%d failures=%d" % [
		checks, failures,
	])
	quit(0 if failures == 0 else 1)
