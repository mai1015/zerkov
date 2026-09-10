extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/inventory_intent_adapter_contract.gd

const MAX_TRANSFER_DISTANCE_RAW: int = 2_000_000


class ContractIdentityPort extends ZInventoryIdentityPort:
	var session_key: String = ""
	var actor_key: String = ""
	var epoch: int = 0
	var raid_generation: int = 0
	var opaque_native_actor: int = 0
	var owned_inventory_id: int = 0
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
			and p_inventory_id == owned_inventory_id
		)


class ContractWorldPolicyPort extends ZInventoryWorldPolicyPort:
	var expected_actor_key: String = ""
	var expected_generation: int = 0
	var world_inventory_id: int = 0
	var distance_raw: int = 0
	var currently_visible: bool = true
	var current_access_state: StringName = ACCESS_OPEN
	var transfer_allowed: bool = true
	var policy_calls: int = 0
	var after_first_allowed_check: Callable = Callable()
	var after_allowed_check_fired: bool = false

	func is_world_inventory(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> bool:
		return _binding_matches(p_actor_id, p_generation) \
			and p_inventory_id == world_inventory_id

	func authoritative_distance_raw(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> int:
		if not _binding_matches(p_actor_id, p_generation) \
			or p_inventory_id != world_inventory_id:
			return -1
		return distance_raw

	func is_currently_visible(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> bool:
		return _binding_matches(p_actor_id, p_generation) \
			and p_inventory_id == world_inventory_id \
			and currently_visible

	func access_state(
		p_actor_id: ZEntityId,
		p_inventory_id: int,
		p_generation: int
	) -> StringName:
		if not _binding_matches(p_actor_id, p_generation) \
			or p_inventory_id != world_inventory_id:
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
			and p_source_inventory_id == world_inventory_id
			and p_destination_inventory_id > 0
			and p_item_id > 0
			and transfer_allowed
		)
		if allowed and not after_allowed_check_fired \
			and after_first_allowed_check.is_valid():
			after_allowed_check_fired = true
			after_first_allowed_check.call()
		return allowed

	func arm_after_allowed_check(callback: Callable) -> void:
		after_first_allowed_check = callback
		after_allowed_check_fired = false

	func clear_after_allowed_check() -> void:
		after_first_allowed_check = Callable()
		after_allowed_check_fired = false

	func _binding_matches(p_actor_id: ZEntityId, p_generation: int) -> bool:
		return p_actor_id != null \
			and p_actor_id.canonical_key() == expected_actor_key \
			and p_generation == expected_generation


var checks: int = 0
var failures: int = 0
var native_transactions: int = 0
var next_sequence: int = 1

var owner: RaidInventoryOwner
var authority: InventoryAuthority
var adapter: InventoryIntentAdapter
var identity_port: ContractIdentityPort
var world_policy_port: ContractWorldPolicyPort
var admission: ZSessionAdmission
var session_id: ZSessionId
var actor_id: ZEntityId


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_INTENT_ADAPTER_CONTRACT: " + message)


func run() -> void:
	owner = RaidInventoryOwner.new()
	owner.name = "InventoryIntentAdapterOwner"
	root.add_child(owner)
	check(owner.configure(), "inventory lifecycle owner configures")
	var owner_generation := owner.generation()
	check(owner.materialize_loot_fixture(owner_generation),
		"deterministic world loot is materialized")
	authority = owner.raid_authority()

	var raid_id := ZRaidId.from_parts(PackedStringArray(["inventory", "intent_contract"]))
	session_id = ZSessionId.from_parts(PackedStringArray(["inventory", "session"]))
	actor_id = ZEntityId.from_parts(PackedStringArray(["inventory", "actor"]))
	var admission_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["inventory", "admission"])),
		raid_id,
		&"contract_profile",
		&"player",
		7
	)
	admission = ZSessionAdmission.accept_local(admission_request, session_id, actor_id)
	check(admission.is_usable(), "test session admission is usable")

	identity_port = ContractIdentityPort.new()
	identity_port.session_key = session_id.canonical_key()
	identity_port.actor_key = actor_id.canonical_key()
	identity_port.epoch = admission.authority_epoch
	identity_port.raid_generation = admission.generation
	identity_port.opaque_native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity_port.owned_inventory_id = owner.raid_player_inventory_id

	world_policy_port = ContractWorldPolicyPort.new()
	world_policy_port.expected_actor_key = actor_id.canonical_key()
	world_policy_port.expected_generation = admission.generation
	world_policy_port.world_inventory_id = owner.world_crate_inventory_id
	world_policy_port.distance_raw = 1_000_000

	adapter = InventoryIntentAdapter.new()
	check(adapter.configure(
		owner,
		admission,
		identity_port,
		world_policy_port,
		MAX_TRANSFER_DISTANCE_RAW
	), "adapter configures with explicit owner, identity, policy, and distance bound")
	check(adapter.tracked_request_count() == 0, "adapter request ledger starts empty")
	check(adapter.tracked_command_count() == 0, "adapter command bindings start empty")
	authority.transaction_committed.connect(_on_native_transaction)

	var crate_item_id := _first_item_id(owner.world_crate_inventory_id)
	var corpse_item_id := _first_item_id(owner.corpse_inventory_id)
	check(crate_item_id > 0 and corpse_item_id > 0, "fixture exposes stable positive item ids")
	var valid_payload := _transfer_payload(crate_item_id)

	var deny_default_adapter := InventoryIntentAdapter.new()
	check(deny_default_adapter.configure(
		owner,
		admission,
		ZInventoryIdentityPort.new(),
		ZInventoryWorldPolicyPort.new(),
		MAX_TRANSFER_DISTANCE_RAW
	), "replaceable port base implementations can be configured explicitly")
	var deny_default_state := _canonical_state()
	var deny_default_result := deny_default_adapter.submit_intent(
		_make_intent("deny_default", valid_payload))
	check(not bool(deny_default_result.get("accepted", false))
		and deny_default_result.get("reason", &"") == &"actor_identity_unresolved"
		and _states_equal(deny_default_state, _canonical_state()),
		"default identity and world-policy ports fail closed without mutation")

	_assert_rejection_atomic(
		_make_intent("wrong_session", valid_payload,
			ZSessionId.from_parts(PackedStringArray(["inventory", "other_session"]))),
		&"session_mismatch",
		"wrong session"
	)
	_assert_rejection_atomic(
		_make_intent("wrong_actor", valid_payload, null,
			ZEntityId.from_parts(PackedStringArray(["inventory", "other_actor"]))),
		&"actor_mismatch",
		"wrong actor"
	)
	_assert_rejection_atomic(
		_make_intent("wrong_epoch", valid_payload, null, null,
			admission.authority_epoch + 1),
		&"authority_epoch_mismatch",
		"wrong authority epoch"
	)
	_assert_rejection_atomic(
		_make_intent("wrong_generation", valid_payload, null, null, -1,
			admission.generation + 1),
		&"stale_generation",
		"wrong raid generation"
	)

	var stale_payload := valid_payload.duplicate(true)
	stale_payload["expected_source_revision"] = int(
		stale_payload["expected_source_revision"]
	) + 1
	_assert_rejection_atomic(
		_make_intent("stale_revision", stale_payload),
		&"source_revision_stale",
		"stale source revision"
	)
	var stale_destination_payload := valid_payload.duplicate(true)
	stale_destination_payload["expected_destination_revision"] = int(
		stale_destination_payload["expected_destination_revision"]
	) + 1
	_assert_rejection_atomic(
		_make_intent("stale_destination_revision", stale_destination_payload),
		&"destination_revision_stale",
		"stale destination revision"
	)

	world_policy_port.world_inventory_id = owner.corpse_inventory_id
	_assert_rejection_atomic(
		_make_intent("wrong_world_mapping", valid_payload),
		&"world_target_invalid",
		"source without an authoritative world mapping"
	)
	world_policy_port.world_inventory_id = owner.world_crate_inventory_id

	world_policy_port.distance_raw = -1
	_assert_rejection_atomic(
		_make_intent("distance_unavailable", valid_payload),
		&"distance_unavailable",
		"missing authoritative distance"
	)
	world_policy_port.distance_raw = 1_000_000

	world_policy_port.distance_raw = MAX_TRANSFER_DISTANCE_RAW + 1
	_assert_rejection_atomic(
		_make_intent("out_of_range", valid_payload),
		&"out_of_range",
		"authoritative distance outside the configured bound"
	)
	world_policy_port.distance_raw = 1_000_000

	world_policy_port.currently_visible = false
	_assert_rejection_atomic(
		_make_intent("invisible", valid_payload),
		&"not_visible",
		"currently invisible world inventory"
	)
	world_policy_port.currently_visible = true

	world_policy_port.current_access_state = ZInventoryWorldPolicyPort.ACCESS_CLOSED
	_assert_rejection_atomic(
		_make_intent("closed", valid_payload),
		&"access_closed",
		"closed or inaccessible world inventory"
	)
	world_policy_port.current_access_state = ZInventoryWorldPolicyPort.ACCESS_OPEN

	identity_port.ownership_enabled = false
	_assert_rejection_atomic(
		_make_intent("wrong_ownership", valid_payload),
		&"destination_not_owned",
		"destination owned by another actor"
	)
	identity_port.ownership_enabled = true

	world_policy_port.transfer_allowed = false
	_assert_rejection_atomic(
		_make_intent("policy_denied", valid_payload),
		&"world_policy_denied",
		"final world policy denial"
	)
	world_policy_port.transfer_allowed = true

	world_policy_port.arm_after_allowed_check(func() -> void:
		world_policy_port.currently_visible = false
	)
	_assert_rejection_atomic(
		_make_intent("post_policy_visibility_revoked", valid_payload),
		&"not_visible",
		"visibility revoked during policy evaluation"
	)
	world_policy_port.currently_visible = true
	world_policy_port.clear_after_allowed_check()

	world_policy_port.arm_after_allowed_check(func() -> void:
		identity_port.ownership_enabled = false
	)
	_assert_rejection_atomic(
		_make_intent("post_policy_ownership_revoked", valid_payload),
		&"destination_not_owned",
		"destination ownership revoked during policy evaluation"
	)
	identity_port.ownership_enabled = true
	world_policy_port.clear_after_allowed_check()

	var original_native_actor := identity_port.opaque_native_actor
	world_policy_port.arm_after_allowed_check(func() -> void:
		identity_port.opaque_native_actor = original_native_actor + 1
	)
	_assert_rejection_atomic(
		_make_intent("post_policy_actor_changed", valid_payload),
		&"actor_identity_changed",
		"native actor mapping changed during policy evaluation"
	)
	identity_port.opaque_native_actor = original_native_actor
	world_policy_port.clear_after_allowed_check()

	var wrong_item_payload := valid_payload.duplicate(true)
	wrong_item_payload["item_id"] = corpse_item_id
	_assert_rejection_atomic(
		_make_intent("wrong_item_owner", wrong_item_payload),
		&"item_not_owned_by_source",
		"item not canonically owned by declared source"
	)

	var malformed_payload := valid_payload.duplicate(true)
	malformed_payload["unexpected"] = 1
	_assert_rejection_atomic(
		_make_intent("malformed", malformed_payload),
		&"payload_schema_invalid",
		"malformed payload schema"
	)
	var zero_command_payload := valid_payload.duplicate(true)
	zero_command_payload["inventory_command_id"] = 0
	_assert_rejection_atomic(
		_make_intent_for(
			admission, "zero_inventory_command", zero_command_payload,
			900_000, 900_000, InventoryIntentAdapter.INTENT_KIND_TRANSFER),
		&"payload_schema_invalid",
		"zero native inventory command identity"
	)

	var unbounded_payload := valid_payload.duplicate(true)
	var oversized: Array = []
	oversized.resize(ZCanonicalValue.DEFAULT_MAX_COLLECTION + 1)
	unbounded_payload["unexpected"] = oversized
	_assert_rejection_atomic(
		_make_intent("unbounded", unbounded_payload),
		&"payload_invalid_or_unbounded",
		"unbounded hostile payload"
	)

	# The owner fixture already committed command 1001 for its first crate
	# insert. Reusing it for a different native payload must reject atomically.
	var native_collision_payload := valid_payload.duplicate(true)
	native_collision_payload["inventory_command_id"] = 1_001
	_assert_native_rejection_atomic(
		_make_intent("native_command_collision", native_collision_payload),
		&"native_transfer_rejected",
		InventoryCatalog.STATUS_DUPLICATE_COMMAND,
		"native command identity already bound to another payload"
	)

	var mutation_item_id := _item_id_at(owner.world_crate_inventory_id, 1)
	var mutation_intent := _make_intent(
		"caller_mutation_isolated", _transfer_payload(mutation_item_id))
	var immutable_mutation_replay := mutation_intent.snapshot()
	world_policy_port.arm_after_allowed_check(func() -> void:
		mutation_intent.kind = &"move"
		mutation_intent.payload["item_id"] = corpse_item_id
		mutation_intent.actor_id = ZEntityId.from_parts(PackedStringArray([
			"inventory", "mutated_actor"
		]))
	)
	var mutation_result := adapter.submit_intent(mutation_intent)
	world_policy_port.clear_after_allowed_check()
	check(bool(mutation_result.get("accepted", false))
		and _inventory_has_item(owner.raid_player_inventory_id, mutation_item_id),
		"caller mutation during policy cannot change the snapshotted command")
	var immutable_mutation_result := adapter.submit_intent(immutable_mutation_replay)
	check(bool(immutable_mutation_result.get("accepted", false))
		and bool(immutable_mutation_result.get("replayed", false)),
		"immutable original bytes still replay after the caller mutates its object")
	valid_payload = _transfer_payload(crate_item_id)

	var accepted_intent := _make_intent("accepted", valid_payload)
	var competing_intent := _make_intent("competing", valid_payload)
	var native_before_accept := native_transactions
	var state_before_accept := _canonical_state()
	var accepted_result := adapter.submit_intent(accepted_intent)
	check(bool(accepted_result.get("accepted", false)),
		"valid visible open in-range owned transfer is accepted")
	check(not bool(accepted_result.get("replayed", true)),
		"first accepted transfer is not a replay")
	check(accepted_result.get("reason", &"rejected") == &"",
		"accepted transfer has no rejection reason")
	check(int(accepted_result.get("native_status_code", -1)) == InventoryCatalog.STATUS_OK,
		"accepted transfer reports native success")
	var accepted_command_id := int(accepted_intent.payload["inventory_command_id"])
	check(accepted_command_id > 0
		and int(accepted_result.get("inventory_command_id", 0)) == accepted_command_id
		and int(accepted_result.get("command_id", 0)) == accepted_command_id
		and int(accepted_result.get("native_command_id", 0)) == accepted_command_id,
		"request, presentation, and native receipts preserve the separate command id")
	check(String(accepted_result.get("request_id", ""))
		!= str(accepted_command_id),
		"product request identity is not conflated with native command identity")
	check(int(accepted_result.get("source_predecessor_revision", -1))
		== int(accepted_intent.payload["expected_source_revision"])
		and int(accepted_result.get("destination_predecessor_revision", -1))
		== int(accepted_intent.payload["expected_destination_revision"]),
		"accepted receipt preserves both exact predecessor revisions")
	check(int(accepted_result.get("source_revision", -1))
		== authority.inventory_revision(owner.world_crate_inventory_id)
		and int(accepted_result.get("destination_revision", -1))
		== authority.inventory_revision(owner.raid_player_inventory_id),
		"accepted receipt labels both successor revisions by inventory identity")
	check(native_transactions == native_before_accept + 1,
		"all policy checks precede exactly one native authority call")
	check(not _states_equal(state_before_accept, _canonical_state()),
		"accepted transfer changes canonical inventory bytes")
	check(not _inventory_has_item(owner.world_crate_inventory_id, crate_item_id),
		"accepted transfer removes the item from the world source")
	check(_inventory_has_item(owner.raid_player_inventory_id, crate_item_id),
		"accepted transfer inserts the same canonical item in actor inventory")
	check(_item_occurrences(crate_item_id) == 1,
		"accepted cross-inventory transaction leaves exactly one canonical item")
	var stored_receipt := adapter.receipt_for_request(accepted_intent.request_id)
	check(stored_receipt == accepted_result,
		"accepted result is available as a stable per-request receipt")
	stored_receipt["accepted"] = false
	check(bool(adapter.receipt_for_request(accepted_intent.request_id).get(
		"accepted", false)), "receipt queries return mutation-isolated copies")

	var state_before_replay := _canonical_state()
	var native_before_replay := native_transactions
	var policy_before_replay := world_policy_port.policy_calls
	world_policy_port.transfer_allowed = false
	world_policy_port.distance_raw = MAX_TRANSFER_DISTANCE_RAW + 1
	var replay_result := adapter.submit_intent(accepted_intent)
	world_policy_port.transfer_allowed = true
	world_policy_port.distance_raw = 1_000_000
	check(bool(replay_result.get("accepted", false))
		and bool(replay_result.get("replayed", false)),
		"exact accepted request replay returns the original acceptance")
	check(int(replay_result.get("native_command_id", 0))
		== int(accepted_result.get("native_command_id", -1)),
		"idempotent replay retains the original native receipt")
	check(native_transactions == native_before_replay,
		"idempotent replay does not call native authority again")
	check(world_policy_port.policy_calls == policy_before_replay,
		"exact replay returns before mutable distance and world-policy checks")
	check(_states_equal(state_before_replay, _canonical_state()),
		"idempotent replay leaves canonical bytes identical")

	var conflicting_payload := valid_payload.duplicate(true)
	conflicting_payload["item_id"] = corpse_item_id
	var conflicting_reuse := _make_intent(
		"unused_label",
		conflicting_payload,
		null,
		null,
		-1,
		-1,
		accepted_intent.request_id,
		accepted_intent.sequence
	)
	_assert_rejection_atomic(
		conflicting_reuse,
		&"request_id_conflict",
		"same request id with different canonical bytes"
	)

	var conflicting_command_payload := valid_payload.duplicate(true)
	conflicting_command_payload["inventory_command_id"] = accepted_command_id
	_assert_rejection_atomic(
		_make_intent("different_request_same_command", conflicting_command_payload),
		&"inventory_command_id_conflict",
		"different request reusing a bound inventory command id"
	)

	_assert_rejection_atomic(
		competing_intent,
		&"source_revision_stale",
		"competing request prepared for the same item revision"
	)
	check(_item_occurrences(crate_item_id) == 1,
		"competing item requests transfer the canonical item at most once")
	check(native_transactions == native_before_accept + 1,
		"all hostile, stale, and duplicate cases make no extra native mutation call")
	check(world_policy_port.policy_calls > 0,
		"accepted and eligible intents reached the replaceable final policy gate")
	check(adapter.tracked_command_count() <= adapter.tracked_request_count(),
		"native command bindings remain bounded by the request receipt ledger")

	_test_phase_handler_order()
	_test_unexpected_native_replay_guard()
	_test_bounded_receipts()

	var next_crate_item_id := _first_item_id(owner.world_crate_inventory_id)
	var late_new_intent := _make_intent(
		"late_new_request", _transfer_payload(next_crate_item_id))
	check(owner.teardown(owner_generation), "inventory lifecycle owner tears down")
	var late_result := adapter.submit_intent(accepted_intent)
	check(bool(late_result.get("accepted", false))
		and bool(late_result.get("replayed", false)),
		"completed receipt replay survives later owner teardown")
	var late_new_result := adapter.submit_intent(late_new_intent)
	check(not bool(late_new_result.get("accepted", false))
		and late_new_result.get("reason", &"") == &"stale_generation",
		"owner teardown rejects a new request after immutable replay lookup")

	print("INVENTORY_INTENT_ADAPTER_RESULT checks=", checks,
		" failures=", failures,
		" native_transactions=", native_transactions)
	quit(0 if failures == 0 else 1)


func _test_phase_handler_order() -> void:
	var phase_owner := RaidInventoryOwner.new()
	phase_owner.name = "InventoryIntentPhaseOwner"
	root.add_child(phase_owner)
	if not phase_owner.configure():
		check(false, "phase fixture inventory owner configures")
		return
	var owner_generation := phase_owner.generation()
	check(phase_owner.materialize_loot_fixture(owner_generation),
		"phase fixture materializes deterministic loot")
	var phase_native_authority := phase_owner.raid_authority()

	var phase_raid_id := ZRaidId.from_parts(PackedStringArray([
		"inventory", "phase_contract"
	]))
	var phase_session_id := ZSessionId.from_parts(PackedStringArray([
		"inventory", "phase_session"
	]))
	var phase_actor_id := ZEntityId.from_parts(PackedStringArray([
		"inventory", "phase_actor"
	]))
	var phase_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["inventory", "phase_admission"])),
		phase_raid_id,
		&"phase_profile",
		&"player",
		11
	)
	var phase_admission := ZSessionAdmission.accept_local(
		phase_request, phase_session_id, phase_actor_id)
	var phase_raid_authority := RaidAuthority.new()
	check(phase_raid_authority.configure(phase_raid_id, phase_admission, 91),
		"game raid authority configures for inventory phase integration")

	var phase_identity := ContractIdentityPort.new()
	phase_identity.session_key = phase_session_id.canonical_key()
	phase_identity.actor_key = phase_actor_id.canonical_key()
	phase_identity.epoch = phase_admission.authority_epoch
	phase_identity.raid_generation = phase_admission.generation
	phase_identity.opaque_native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	phase_identity.owned_inventory_id = phase_owner.raid_player_inventory_id
	var phase_policy := ContractWorldPolicyPort.new()
	phase_policy.expected_actor_key = phase_actor_id.canonical_key()
	phase_policy.expected_generation = phase_admission.generation
	phase_policy.world_inventory_id = phase_owner.world_crate_inventory_id
	phase_policy.distance_raw = 1_000_000
	var phase_adapter := InventoryIntentAdapter.new()
	check(phase_adapter.configure(
		phase_owner, phase_admission, phase_identity, phase_policy,
		MAX_TRANSFER_DISTANCE_RAW), "phase adapter configures")
	check(phase_adapter.register_with_raid_authority(phase_raid_authority),
		"adapter registers at the canonical interaction phase")
	check(phase_raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, phase_admission.generation),
		"phase fixture raid activates")

	var phase_item_id := int((phase_native_authority.snapshot(
		phase_owner.world_crate_inventory_id).get_items()[0] as Dictionary).get("id", 0))
	var base_payload := _transfer_payload_for(
		phase_owner, phase_native_authority, phase_item_id, 31_001)
	var low_intent := _make_intent_for(
		phase_admission, "phase_low", base_payload, 1, 1,
		InventoryIntentAdapter.INTENT_KIND_TRANSFER)
	var high_payload := base_payload.duplicate(true)
	high_payload["inventory_command_id"] = 31_002
	var high_intent := _make_intent_for(
		phase_admission, "phase_high", high_payload, 1, 2,
		InventoryIntentAdapter.INTENT_KIND_TRANSFER)
	var unrelated_intent := _make_intent_for(
		phase_admission, "phase_unrelated", {"axis": Vector2i(1, 0)}, 1, 3,
		&"move")
	check(phase_raid_authority.enqueue_intent(
		high_intent, phase_admission.generation),
		"higher-sequence competing transfer may arrive first")
	check(phase_raid_authority.enqueue_intent(
		unrelated_intent, phase_admission.generation),
		"unowned intent kind enters the shared authority queue")
	check(phase_raid_authority.enqueue_intent(
		low_intent, phase_admission.generation),
		"lower-sequence competing transfer may arrive last")
	check(phase_raid_authority.advance_one(phase_admission.generation),
		"business rejection does not falsely fail the raid phase handler")
	var low_receipt := phase_adapter.receipt_for_request(low_intent.request_id)
	var high_receipt := phase_adapter.receipt_for_request(high_intent.request_id)
	check(bool(low_receipt.get("accepted", false)),
		"canonical lower sequence wins competing transfer")
	check(not bool(high_receipt.get("accepted", false))
		and high_receipt.get("reason", &"") == &"source_revision_stale",
		"later competing transfer receives a stable business rejection")
	check(phase_adapter.receipt_for_request(unrelated_intent.request_id).is_empty(),
		"explicit allowlist ignores unrelated intents without claiming them")
	check(phase_adapter.tracked_request_count() == 2
		and phase_raid_authority.lifecycle == RaidAuthority.Lifecycle.ACTIVE
		and phase_raid_authority.last_processed_tick == 1,
		"phase handler records each owned result and leaves the raid active")
	check(phase_raid_authority.teardown(phase_admission.generation),
		"phase fixture raid tears down")
	check(phase_owner.teardown(owner_generation),
		"phase fixture inventory owner tears down")
	phase_owner.queue_free()


func _test_unexpected_native_replay_guard() -> void:
	var replay_owner := RaidInventoryOwner.new()
	replay_owner.name = "InventoryIntentNativeReplayOwner"
	root.add_child(replay_owner)
	if not replay_owner.configure():
		check(false, "unexpected native replay fixture owner configures")
		return
	var owner_generation := replay_owner.generation()
	check(replay_owner.materialize_loot_fixture(owner_generation),
		"unexpected native replay fixture materializes loot")
	var replay_authority := replay_owner.raid_authority()
	var replay_item_id := int((replay_authority.snapshot(
		replay_owner.world_crate_inventory_id).get_items()[0] as Dictionary).get("id", 0))
	var first_native := replay_authority.quick_transfer_item(
		replay_owner.world_crate_inventory_id,
		replay_owner.raid_player_inventory_id,
		replay_item_id,
		false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		60_001
	)
	var return_native := replay_authority.quick_transfer_item(
		replay_owner.raid_player_inventory_id,
		replay_owner.world_crate_inventory_id,
		replay_item_id,
		false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		60_002
	)
	check(bool(first_native.get("accepted", false))
		and bool(return_native.get("accepted", false)),
		"native replay fixture restores the item after recording command identity")

	var replay_raid_id := ZRaidId.from_parts(PackedStringArray([
		"inventory", "native_replay_contract"
	]))
	var replay_session_id := ZSessionId.from_parts(PackedStringArray([
		"inventory", "native_replay_session"
	]))
	var replay_actor_id := ZEntityId.from_parts(PackedStringArray([
		"inventory", "native_replay_actor"
	]))
	var replay_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray([
			"inventory", "native_replay_admission"
		])),
		replay_raid_id,
		&"native_replay_profile",
		&"player",
		19
	)
	var replay_admission := ZSessionAdmission.accept_local(
		replay_request, replay_session_id, replay_actor_id)
	var replay_identity := ContractIdentityPort.new()
	replay_identity.session_key = replay_session_id.canonical_key()
	replay_identity.actor_key = replay_actor_id.canonical_key()
	replay_identity.epoch = replay_admission.authority_epoch
	replay_identity.raid_generation = replay_admission.generation
	replay_identity.opaque_native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	replay_identity.owned_inventory_id = replay_owner.raid_player_inventory_id
	var replay_policy := ContractWorldPolicyPort.new()
	replay_policy.expected_actor_key = replay_actor_id.canonical_key()
	replay_policy.expected_generation = replay_admission.generation
	replay_policy.world_inventory_id = replay_owner.world_crate_inventory_id
	replay_policy.distance_raw = 1_000_000
	var replay_adapter := InventoryIntentAdapter.new()
	check(replay_adapter.configure(
		replay_owner, replay_admission, replay_identity, replay_policy,
		MAX_TRANSFER_DISTANCE_RAW), "unexpected native replay adapter configures")
	var replay_payload := _transfer_payload_for(
		replay_owner, replay_authority, replay_item_id, 60_001)
	var replay_intent := _make_intent_for(
		replay_admission, "native_replay_attempt", replay_payload,
		1, 1, InventoryIntentAdapter.INTENT_KIND_TRANSFER)
	var state_before := _local_inventory_state(replay_owner, replay_authority)
	var result := replay_adapter.submit_intent(replay_intent)
	check(not bool(result.get("accepted", false))
		and result.get("reason", &"") == &"native_command_replay_unexpected"
		and _states_equal(state_before, _local_inventory_state(
			replay_owner, replay_authority)),
		"fresh product request cannot inherit a prior native accepted result")
	var exact_replay := replay_adapter.submit_intent(replay_intent)
	check(bool(exact_replay.get("replayed", false))
		and exact_replay.get("reason", &"") == &"native_command_replay_unexpected",
		"unexpected native replay rejection itself has a stable product receipt")
	check(replay_owner.teardown(owner_generation),
		"unexpected native replay fixture tears down")
	replay_owner.queue_free()


func _test_bounded_receipts() -> void:
	var bounded_owner := RaidInventoryOwner.new()
	bounded_owner.name = "InventoryIntentBoundedOwner"
	root.add_child(bounded_owner)
	if not bounded_owner.configure():
		check(false, "bounded receipt fixture owner configures")
		return
	var owner_generation := bounded_owner.generation()
	check(bounded_owner.materialize_loot_fixture(owner_generation),
		"bounded receipt fixture materializes loot")
	var bounded_authority := bounded_owner.raid_authority()
	var bounded_raid_id := ZRaidId.from_parts(PackedStringArray([
		"inventory", "bounded_contract"
	]))
	var bounded_session_id := ZSessionId.from_parts(PackedStringArray([
		"inventory", "bounded_session"
	]))
	var bounded_actor_id := ZEntityId.from_parts(PackedStringArray([
		"inventory", "bounded_actor"
	]))
	var bounded_request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["inventory", "bounded_admission"])),
		bounded_raid_id,
		&"bounded_profile",
		&"player",
		17
	)
	var bounded_admission := ZSessionAdmission.accept_local(
		bounded_request, bounded_session_id, bounded_actor_id)
	var bounded_identity := ContractIdentityPort.new()
	bounded_identity.session_key = bounded_session_id.canonical_key()
	bounded_identity.actor_key = bounded_actor_id.canonical_key()
	bounded_identity.epoch = bounded_admission.authority_epoch
	bounded_identity.raid_generation = bounded_admission.generation
	bounded_identity.opaque_native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	bounded_identity.owned_inventory_id = bounded_owner.raid_player_inventory_id
	var bounded_policy := ContractWorldPolicyPort.new()
	bounded_policy.expected_actor_key = bounded_actor_id.canonical_key()
	bounded_policy.expected_generation = bounded_admission.generation
	bounded_policy.world_inventory_id = bounded_owner.world_crate_inventory_id
	bounded_policy.distance_raw = MAX_TRANSFER_DISTANCE_RAW + 1
	var bounded_adapter := InventoryIntentAdapter.new()
	check(bounded_adapter.configure(
		bounded_owner, bounded_admission, bounded_identity, bounded_policy,
		MAX_TRANSFER_DISTANCE_RAW), "bounded receipt adapter configures")
	var bounded_item_id := int((bounded_authority.snapshot(
		bounded_owner.world_crate_inventory_id).get_items()[0] as Dictionary).get("id", 0))
	var first_intent: ZRaidIntent
	var every_rejection_stable := true
	for index in InventoryIntentAdapter.MAX_TRACKED_REQUESTS:
		var payload := _transfer_payload_for(
			bounded_owner, bounded_authority, bounded_item_id, 40_000 + index)
		var intent := _make_intent_for(
			bounded_admission, "bounded_%04d" % index, payload,
			index + 1, index + 1, InventoryIntentAdapter.INTENT_KIND_TRANSFER)
		if index == 0:
			first_intent = intent
		var result := bounded_adapter.submit_intent(intent)
		if result.get("reason", &"") != &"out_of_range":
			every_rejection_stable = false
	check(every_rejection_stable
		and bounded_adapter.tracked_request_count() == InventoryIntentAdapter.MAX_TRACKED_REQUESTS
		and bounded_adapter.tracked_command_count() == InventoryIntentAdapter.MAX_TRACKED_REQUESTS,
		"request receipts and command bindings stop at their documented bound")
	var overflow_payload := _transfer_payload_for(
		bounded_owner, bounded_authority, bounded_item_id, 90_000)
	var overflow_intent := _make_intent_for(
		bounded_admission, "bounded_overflow", overflow_payload,
		2_000, 2_000, InventoryIntentAdapter.INTENT_KIND_TRANSFER)
	var state_before_overflow := _local_inventory_state(
		bounded_owner, bounded_authority)
	var overflow_result := bounded_adapter.submit_intent(overflow_intent)
	check(overflow_result.get("reason", &"") == &"request_history_full"
		and _states_equal(state_before_overflow, _local_inventory_state(
			bounded_owner, bounded_authority)),
		"receipt exhaustion fails closed without canonical mutation")
	var policy_calls_before_replay := bounded_policy.policy_calls
	bounded_policy.distance_raw = 1_000_000
	var replay := bounded_adapter.submit_intent(first_intent)
	check(bool(replay.get("replayed", false))
		and replay.get("reason", &"") == &"out_of_range"
		and bounded_policy.policy_calls == policy_calls_before_replay,
		"existing exact receipt remains replayable after the ledger reaches capacity")
	check(bounded_owner.teardown(owner_generation),
		"bounded receipt fixture tears down")
	bounded_owner.queue_free()


func _transfer_payload_for(
	local_owner: RaidInventoryOwner,
	local_authority: InventoryAuthority,
	item_id: int,
	command_id: int
) -> Dictionary:
	return {
		"inventory_command_id": command_id,
		"source_inventory_id": local_owner.world_crate_inventory_id,
		"destination_inventory_id": local_owner.raid_player_inventory_id,
		"item_id": item_id,
		"expected_source_revision": local_authority.inventory_revision(
			local_owner.world_crate_inventory_id),
		"expected_destination_revision": local_authority.inventory_revision(
			local_owner.raid_player_inventory_id),
	}


func _make_intent_for(
	local_admission: ZSessionAdmission,
	label: String,
	payload: Dictionary,
	target_tick: int,
	sequence: int,
	kind: StringName
) -> ZRaidIntent:
	return ZRaidIntent.create(
		ZRequestId.from_parts(PackedStringArray(["inventory", label])),
		ZRaidIntent.Source.PLAYER,
		local_admission.session_id,
		local_admission.actor_id,
		local_admission.authority_epoch,
		local_admission.generation,
		target_tick,
		sequence,
		kind,
		payload
	)


func _local_inventory_state(
	local_owner: RaidInventoryOwner,
	local_authority: InventoryAuthority
) -> Dictionary:
	return {
		"player": local_authority.snapshot(
			local_owner.raid_player_inventory_id).canonical_bytes(),
		"crate": local_authority.snapshot(
			local_owner.world_crate_inventory_id).canonical_bytes(),
		"corpse": local_authority.snapshot(
			local_owner.corpse_inventory_id).canonical_bytes(),
	}


func _make_intent(
	label: String,
	payload: Dictionary,
	p_session_id: ZSessionId = null,
	p_actor_id: ZEntityId = null,
	p_authority_epoch: int = -1,
	p_generation: int = -1,
	p_request_id: ZRequestId = null,
	p_sequence: int = -1
) -> ZRaidIntent:
	var sequence := next_sequence if p_sequence < 0 else p_sequence
	if p_sequence < 0:
		next_sequence += 1
	var request_id := p_request_id
	if request_id == null:
		request_id = ZRequestId.from_parts(PackedStringArray(["inventory", label]))
	var payload_copy := payload.duplicate(true)
	if int(payload_copy.get("inventory_command_id", 0)) <= 0:
		payload_copy["inventory_command_id"] = 10_000 + sequence
	return ZRaidIntent.create(
		request_id,
		ZRaidIntent.Source.PLAYER,
		session_id if p_session_id == null else p_session_id,
		actor_id if p_actor_id == null else p_actor_id,
		admission.authority_epoch if p_authority_epoch < 0 else p_authority_epoch,
		admission.generation if p_generation < 0 else p_generation,
		sequence,
		sequence,
		InventoryIntentAdapter.INTENT_KIND_TRANSFER,
		payload_copy
	)


func _transfer_payload(item_id: int) -> Dictionary:
	return {
		"inventory_command_id": 0,
		"source_inventory_id": owner.world_crate_inventory_id,
		"destination_inventory_id": owner.raid_player_inventory_id,
		"item_id": item_id,
		"expected_source_revision": authority.inventory_revision(owner.world_crate_inventory_id),
		"expected_destination_revision": authority.inventory_revision(owner.raid_player_inventory_id),
	}


func _assert_rejection_atomic(
	intent: ZRaidIntent,
	expected_reason: StringName,
	label: String
) -> void:
	var before := _canonical_state()
	var native_before := native_transactions
	var result := adapter.submit_intent(intent)
	check(not bool(result.get("accepted", false)), label + " is rejected")
	check(result.get("reason", &"") == expected_reason,
		label + " reports stable reason " + String(expected_reason))
	check(_states_equal(before, _canonical_state()),
		label + " leaves every canonical inventory byte-identical")
	check(native_transactions == native_before,
		label + " is rejected before calling native authority")


func _assert_native_rejection_atomic(
	intent: ZRaidIntent,
	expected_reason: StringName,
	expected_status_code: int,
	label: String
) -> void:
	var before := _canonical_state()
	var native_before := native_transactions
	var result := adapter.submit_intent(intent)
	check(not bool(result.get("accepted", false)), label + " is rejected")
	check(result.get("reason", &"") == expected_reason,
		label + " reports stable reason " + String(expected_reason))
	check(int(result.get("native_status_code", -1)) == expected_status_code,
		label + " preserves the native rejection status")
	check(_states_equal(before, _canonical_state()),
		label + " leaves every canonical inventory byte-identical")
	check(native_transactions == native_before + 1,
		label + " executes exactly one fail-atomic native transaction")


func _canonical_state() -> Dictionary:
	return {
		"profile": owner.profile_authority().snapshot(
			owner.profile_inventory_id).canonical_bytes(),
		"player": authority.snapshot(owner.raid_player_inventory_id).canonical_bytes(),
		"crate": authority.snapshot(owner.world_crate_inventory_id).canonical_bytes(),
		"corpse": authority.snapshot(owner.corpse_inventory_id).canonical_bytes(),
	}


func _states_equal(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for key in left:
		if not right.has(key) or left[key] != right[key]:
			return false
	return true


func _first_item_id(inventory_id: int) -> int:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null or snapshot.get_items().is_empty():
		return 0
	return int((snapshot.get_items()[0] as Dictionary).get("id", 0))


func _item_id_at(inventory_id: int, index: int) -> int:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null or index < 0 or index >= snapshot.get_items().size():
		return 0
	return int((snapshot.get_items()[index] as Dictionary).get("id", 0))


func _inventory_has_item(inventory_id: int, item_id: int) -> bool:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return false
	for item_value in snapshot.get_items():
		if int((item_value as Dictionary).get("id", 0)) == item_id:
			return true
	return false


func _item_occurrences(item_id: int) -> int:
	var count := 0
	for inventory_id in [
		owner.raid_player_inventory_id,
		owner.world_crate_inventory_id,
		owner.corpse_inventory_id,
	]:
		if _inventory_has_item(inventory_id, item_id):
			count += 1
	return count


func _on_native_transaction(_result: Dictionary) -> void:
	native_transactions += 1
