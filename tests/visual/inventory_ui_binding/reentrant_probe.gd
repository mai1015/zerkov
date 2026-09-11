extends "res://tests/visual/inventory_ui_binding/capture.gd"
## HISTORICAL / DEFERRED reentrant visual packet; not a current runner.
## Negative lifecycle probe. Expected contract: fail closed with a typed result,
## no stale authority submission, no script diagnostics, no pending leak.

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: reentrant_probe is historical; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)

func run() -> void:
	setup_runtime()
	var item: Dictionary = _find_rotatable(controller.items_for(&"crate"))
	var reentered := {"called": false, "rebound": false, "nested": {}}
	controller.pending_changed.connect(func(_scope: StringName):
		if not reentered.called:
			reentered.called = true
			reentered.nested = controller.submit_drop(&"crate", &"rig", item, Vector2i(2, 0))
			controller.unbind()
			reentered.rebound = controller.bind(owner, bridge, adapter, admission)
	)
	print("ASTRA_REENTRANT_PROBE submitting with a synchronous pending listener that unbinds/rebinds")
	var result: Variant = controller.submit_drop(&"crate", &"rig", item, Vector2i.ZERO)
	print("ASTRA_REENTRANT_OBSERVED result=", result, " requests=", adapter.tracked_request_count(), " pending=", bridge.presentation_model(&"raid").pending_ids_for_inventory(owner.world_crate_inventory_id))
	check(reentered.called, "pending listener ran")
	check(reentered.rebound and controller.is_bound(), "pending listener replacement binding succeeds")
	check(reentered.nested is Dictionary and reentered.nested.reason == Controller.REASON_REENTRANT_SUBMISSION, "nested submission is rejected before pending or adapter side effects")
	check(result is Dictionary and result.has("reason") and not bool(result.get("accepted", false)), "lifecycle invalidation returns a typed rejection")
	check(adapter.tracked_request_count() == 0, "lifecycle invalidation submits no request")
	check(bridge.presentation_model(&"raid").pending_ids_for_inventory(owner.world_crate_inventory_id).is_empty(), "lifecycle invalidation clears the pending record")

	var seed := controller.submit_drop(&"crate", &"rig", item, Vector2i(2, 0))
	check(seed.accepted, "result-listener fixture seeds one rotatable item through authority")
	var original_item := _find_item(controller.items_for(&"rig"), int(item.item_id))
	var original_model: InventoryPresentationModel = bridge.presentation_model(&"raid")
	var replacement := _create_runtime("replacement")
	var replacement_owner: RaidInventoryOwner = replacement.owner
	var replacement_bridge: Bridge = replacement.bridge
	var replacement_adapter: Adapter = replacement.adapter
	var replacement_admission: ZSessionAdmission = replacement.admission
	var replacement_world: BindingWorldPolicyPort = replacement.world
	var replacement_bytes := replacement_bridge.confirmed_snapshot(
		&"raid", replacement_owner.raid_player_inventory_id).canonical_bytes()
	var result_rebind := {"called": false, "rebound": false}
	controller.accepted_feedback.connect(func(_info: Dictionary):
		if not result_rebind.called:
			result_rebind.called = true
			controller.unbind()
			result_rebind.rebound = controller.bind(
				replacement_owner, replacement_bridge, replacement_adapter,
				replacement_admission)
	)
	var requests_before_result := adapter.tracked_request_count()
	print("ASTRA_REENTRANT_PROBE submitting with a synchronous result listener that unbinds/rebinds")
	var accepted := controller.submit_rotate(&"rig", original_item)
	check(result_rebind.called and result_rebind.rebound and controller.is_bound(), "result listener installs the replacement binding")
	check(accepted.accepted and not accepted.ui_binding_current, "captured authoritative result returns safely after result-listener rebind")
	check(adapter.tracked_request_count() == requests_before_result + 1, "original adapter receives exactly one result-listener command")
	check(replacement_adapter.tracked_request_count() == 0, "old command never targets the replacement adapter")
	check(replacement_bridge.confirmed_snapshot(&"raid", replacement_owner.raid_player_inventory_id).canonical_bytes() == replacement_bytes, "old command cannot mutate the replacement owner")
	check(original_model.pending_ids_for_inventory(owner.raid_player_inventory_id).is_empty(), "result-listener rebind leaves no original pending record")

	# Direct adapter validation failures are applied to the captured model after
	# submit_intent returns, which is a second synchronous result boundary.
	var rejected_item := _find_rotatable(controller.items_for(&"crate"))
	var replacement_model: InventoryPresentationModel = replacement_bridge.presentation_model(&"raid")
	var replacement_player_bytes := replacement_bridge.confirmed_snapshot(
		&"raid", replacement_owner.raid_player_inventory_id).canonical_bytes()
	replacement_world.world_ids.erase(replacement_owner.world_crate_inventory_id)
	var rejection_rebind := {"called": false, "rebound": false}
	controller.rejection_feedback.connect(func(_info: Dictionary):
		if not rejection_rebind.called:
			rejection_rebind.called = true
			controller.unbind()
			rejection_rebind.rebound = controller.bind(owner, bridge, adapter, admission)
	)
	var original_requests_before_rejection := adapter.tracked_request_count()
	var replacement_requests_before_rejection := replacement_adapter.tracked_request_count()
	var rejected := controller.submit_drop(&"crate", &"rig", rejected_item, Vector2i(2, 0))
	check(rejection_rebind.called and rejection_rebind.rebound and controller.is_bound(), "rejection listener safely restores the original binding")
	check(not rejected.accepted and not rejected.ui_binding_current and rejected.ui_resolved, "captured rejection returns typed and resolved after result-listener rebind")
	check(replacement_adapter.tracked_request_count() == replacement_requests_before_rejection + 1, "replacement adapter processes exactly one rejected request")
	check(adapter.tracked_request_count() == original_requests_before_rejection, "rejected replacement command never targets the rebound original adapter")
	check(replacement_bridge.confirmed_snapshot(&"raid", replacement_owner.raid_player_inventory_id).canonical_bytes() == replacement_player_bytes, "adapter rejection cannot mutate either owner")
	check(replacement_model.pending_ids_for_inventory(replacement_owner.world_crate_inventory_id).is_empty(), "rejection-listener rebind leaves no captured pending record")
	controller.unbind()
	owner.teardown(owner.generation())
	bridge.queue_free()
	owner.queue_free()
	replacement_owner.teardown(replacement_owner.generation())
	replacement_bridge.queue_free()
	replacement_owner.queue_free()
	await settle()
	print("ASTRA_REENTRANT_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _create_runtime(tag: String) -> Dictionary:
	var next_owner := RaidInventoryOwner.new()
	root.add_child(next_owner)
	check(next_owner.configure(), tag + " owner configures")
	check(next_owner.materialize_loot_fixture(), tag + " loot materializes")
	var request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["astra", "reentrant", tag, "admission"])),
		ZRaidId.from_parts(PackedStringArray(["astra", "reentrant", tag, "raid"])),
		StringName("astra_reentrant_" + tag), &"player", 7)
	var session := ZSessionId.from_parts(PackedStringArray(["astra", "reentrant", tag, "session"]))
	var actor := ZEntityId.from_parts(PackedStringArray(["astra", "reentrant", tag, "actor"]))
	var next_admission := ZSessionAdmission.accept_local(request, session, actor)
	var identity := BindingIdentityPort.new()
	identity.session_key = session.canonical_key()
	identity.actor_key = actor.canonical_key()
	identity.epoch = next_admission.authority_epoch
	identity.generation = next_admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned[next_owner.raid_player_inventory_id] = true
	var world := BindingWorldPolicyPort.new()
	world.actor_key = actor.canonical_key()
	world.generation = next_admission.generation
	world.world_ids[next_owner.world_crate_inventory_id] = true
	world.world_ids[next_owner.corpse_inventory_id] = true
	var next_adapter := Adapter.new()
	check(next_adapter.configure(next_owner, next_admission, identity, world, MAX_TRANSFER_DISTANCE_RAW), tag + " adapter configures")
	var next_bridge := Bridge.new()
	root.add_child(next_bridge)
	check(next_bridge.bind_owner(next_owner, next_owner.generation()), tag + " bridge binds")
	return {
		"owner": next_owner,
		"bridge": next_bridge,
		"adapter": next_adapter,
		"admission": next_admission,
		"world": world,
	}
