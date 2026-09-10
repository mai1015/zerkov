extends "res://tests/raid/inventory_ui_binding_contract.gd"
## Adversarial 4.7b command-correlation contract. Two supported controllers use
## distinct bridges/presentation models while sharing one owner and adapter.
## A synchronous pending callback submits through the other controller.


func run() -> void:
	owner = RaidInventoryOwner.new()
	owner.name = "InventoryMultiControllerOwner"
	root.add_child(owner)
	check(owner.configure(), "multi-controller owner configures")
	check(owner.materialize_loot_fixture(), "multi-controller loot materializes")

	var raid_id := ZRaidId.from_parts(PackedStringArray(["ui", "multi", "raid"]))
	var session_id := ZSessionId.from_parts(PackedStringArray(["ui", "multi", "session"]))
	var actor_id := ZEntityId.from_parts(PackedStringArray(["ui", "multi", "actor"]))
	var request := ZSessionRequest.create_offline(
		ZRequestId.from_parts(PackedStringArray(["ui", "multi", "admission"])),
		raid_id,
		&"ui_multi_profile",
		&"player",
		7
	)
	admission = ZSessionAdmission.accept_local(request, session_id, actor_id)
	check(admission.is_usable(), "multi-controller admission is usable")

	var identity := BindingIdentityPort.new()
	identity.session_key = session_id.canonical_key()
	identity.actor_key = actor_id.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned[owner.raid_player_inventory_id] = true
	var world := BindingWorldPolicyPort.new()
	world.actor_key = actor_id.canonical_key()
	world.generation = admission.generation
	world.world_ids[owner.world_crate_inventory_id] = true
	world.world_ids[owner.corpse_inventory_id] = true

	adapter = Adapter.new()
	check(adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW), "shared adapter configures")
	bridge = Bridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner.generation()), "first bridge binds owner")
	controller = Controller.new()
	check(controller.bind(owner, bridge, adapter, admission), "first controller binds first model")
	var second_bridge := Bridge.new()
	root.add_child(second_bridge)
	check(second_bridge.bind_owner(owner, owner.generation()), "second bridge binds the same owner")
	var second_controller := Controller.new()
	check(second_controller.bind(owner, second_bridge, adapter, admission), "second controller binds a distinct model and shared adapter")

	var first_item := _find_definition(controller.items_for(&"crate"), str(Catalog.ITEM_SEALED_DOCUMENTS))
	var second_item := _find_definition(second_controller.items_for(&"crate"), str(Catalog.ITEM_DUCT_TAPE))
	check(not first_item.is_empty() and not second_item.is_empty(), "two distinct canonical item identities are available")
	var observed := {
		"armed": true,
		"nested": {},
		"first_accepted": [],
		"first_rejected": [],
		"second_accepted": [],
		"second_rejected": [],
	}
	controller.accepted_feedback.connect(func(info: Dictionary):
		(observed.first_accepted as Array).append(info.duplicate(true)))
	controller.rejection_feedback.connect(func(info: Dictionary):
		(observed.first_rejected as Array).append(info.duplicate(true)))
	second_controller.accepted_feedback.connect(func(info: Dictionary):
		(observed.second_accepted as Array).append(info.duplicate(true)))
	second_controller.rejection_feedback.connect(func(info: Dictionary):
		(observed.second_rejected as Array).append(info.duplicate(true)))
	controller.pending_changed.connect(func(_scope: StringName):
		if not bool(observed.armed):
			return
		observed.armed = false
		observed.nested = second_controller.submit_quick(&"crate", second_item)
	)

	var outer := controller.submit_drop(&"crate", &"rig", first_item, Vector2i(2, 0))
	var nested: Dictionary = observed.nested as Dictionary
	var outer_id := int(outer.get("inventory_command_id", 0))
	var nested_id := int(nested.get("inventory_command_id", 0))
	check(bool(nested.get("accepted", false)) and not bool(nested.get("replayed", false)), "nested controller commits its distinct item once")
	check(not bool(outer.get("accepted", false)) and outer.get("reason", &"") == &"source_revision_stale", "outer command observes the legitimate concurrent source revision")
	check(outer_id >= Controller.PRODUCT_COMMAND_ID_BASE and nested_id == outer_id + 1 \
		and nested_id <= Controller.PRODUCT_COMMAND_ID_MAX,
		"different models reserve bounded monotonic IDs before synchronous publication")
	check(int(outer.get("ui_pending_command_id", -1)) == outer_id \
		and int(nested.get("ui_pending_command_id", -1)) == nested_id \
		and int(nested.get("native_command_id", 0)) == nested_id,
		"each result remains correlated to its exact presentation/native identity")
	check((observed.first_accepted as Array).is_empty() \
		and (observed.first_rejected as Array).size() == 1 \
		and (observed.second_accepted as Array).size() == 1 \
		and (observed.second_rejected as Array).is_empty(),
		"unrelated accepted feedback cannot resolve the first model")
	var first_rejection: Dictionary = (observed.first_rejected as Array)[0]
	var second_acceptance: Dictionary = (observed.second_accepted as Array)[0]
	check(int(first_rejection.get("command_id", 0)) == outer_id \
		and (first_rejection.get("items", []) as Array) == [int(first_item.item_id)] \
		and StringName((first_rejection.get("status", {}) as Dictionary).get("reason", &"")) == &"source_revision_stale",
		"first model emits only its own exact rejection correlation")
	check(int(second_acceptance.get("command_id", 0)) == nested_id \
		and (second_acceptance.get("items", []) as Array) == [int(second_item.item_id)],
		"second model emits only its own exact acceptance correlation")
	check(bridge.presentation_model(&"raid").pending_ids_for_inventory(owner.world_crate_inventory_id).is_empty() \
		and second_bridge.presentation_model(&"raid").pending_ids_for_inventory(owner.world_crate_inventory_id).is_empty(),
		"both independent pending ledgers finish clean")
	check(adapter.tracked_request_count() == 2 and adapter.tracked_command_count() == 2, "shared adapter records two unique requests and command bindings")

	# Exercise the actual shared allocator boundary in O(1), without padding it
	# toward the limit. The last bounded ID must remain usable and increment-safe;
	# the next submission must fail before pending publication or adapter entry.
	var first_model: InventoryPresentationModel = bridge.presentation_model(&"raid")
	Controller._next_product_command_id = Controller.PRODUCT_COMMAND_ID_MAX
	var requests_before_boundary := adapter.tracked_request_count()
	var boundary_item := _find_definition(controller.items_for(&"crate"), str(Catalog.ITEM_SEALED_DOCUMENTS))
	var boundary := controller.submit_quick(&"crate", boundary_item)
	check(bool(boundary.get("accepted", false)) \
		and int(boundary.get("inventory_command_id", 0)) == Controller.PRODUCT_COMMAND_ID_MAX \
		and int(boundary.get("native_command_id", 0)) == Controller.PRODUCT_COMMAND_ID_MAX,
		"last bounded product command ID remains valid and exactly correlated")
	check(adapter.tracked_request_count() == requests_before_boundary + 1 \
		and first_model.pending_ids_for_inventory(owner.world_crate_inventory_id).is_empty(),
		"last bounded reservation resolves without leaving pending state")
	var requests_before_exhaustion := adapter.tracked_request_count()
	var exhausted_item := _find_definition(controller.items_for(&"crate"), str(Catalog.ITEM_ENCRYPTED_DRIVE))
	var exhausted := controller.submit_quick(&"crate", exhausted_item)
	check(Controller.PRODUCT_COMMAND_ID_BASE > 0 \
		and Controller.PRODUCT_COMMAND_ID_BASE < Controller.PRODUCT_COMMAND_ID_MAX \
		and Controller.PRODUCT_COMMAND_ID_MAX + 1 > Controller.PRODUCT_COMMAND_ID_MAX,
		"reserved command range is positive, ordered, and increment-safe")
	check(not bool(exhausted.get("accepted", false)) \
		and exhausted.get("reason", &"") == Controller.REASON_MUTATION_UNAVAILABLE \
		and int(exhausted.get("command_id", -1)) == 0,
		"exhausted allocator fails closed with no command identity")
	check(adapter.tracked_request_count() == requests_before_exhaustion \
		and first_model.pending_ids_for_inventory(owner.world_crate_inventory_id).is_empty(),
		"allocator exhaustion publishes no pending record or adapter request")

	controller.unbind()
	second_controller.unbind()
	bridge.release_binding()
	second_bridge.release_binding()
	owner.teardown(owner.generation())
	bridge.queue_free()
	second_bridge.queue_free()
	owner.queue_free()
	await process_frame
	await process_frame
	print("INVENTORY_MULTI_CONTROLLER_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
