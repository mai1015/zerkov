extends SceneTree
## Run with: /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
##   --headless --path . --script res://tests/raid/inventory_weapon_reload_contract.gd
##
## Task 4.9 contract. The primary flow uses both real vendored authorities.
## Fake participant cases exercise the game-owned rollback/fail-stop seam but
## are never presented as proof of the production WeaponAuthority integration.

class FakeRollbackableWeaponPort extends WeaponReloadParticipantPort:
	var state: Dictionary
	var due_tick: int = 5
	var fail_commit_without_mutation: bool = false
	var commit_interleave: Callable
	var _prepared: Dictionary = {}
	var _predecessor: Dictionary = {}
	var _committed: Dictionary = {}

	func setup(instance_id: String, scope: String, epoch: int, loaded_rounds: int = 10) -> void:
		state = {
			"instance_id": instance_id,
			"definition_id": String(ZerkovCombatContent.WEAPON_AKM),
			"definition_version": ZerkovCombatContent.CONTENT_VERSION,
			"revision": 0,
			"loaded_rounds": loaded_rounds,
			"loaded_profile": {
				"has_profile": loaded_rounds > 0,
				"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD)
					if loaded_rounds > 0 else "",
				"version": ZerkovCombatContent.CONTENT_VERSION if loaded_rounds > 0 else 0,
			},
			"phase": "ready",
			"reload": {},
			"authority_scope": scope,
			"authority_epoch": epoch,
			"authority_tick_floor": 0,
			"admitted_sequence_high_watermark": 0,
			"last_command_sequence": 0,
			"tick_unhealthy": false,
		}

	func commit_capability() -> CommitCapability:
		return CommitCapability.ROLLBACKABLE_PARTICIPANT

	func is_ready() -> bool:
		return not state.is_empty()

	func identity_token() -> String:
		return "fake-rollbackable:%s" % String(state.get("instance_id", ""))

	func snapshot(instance_id: String) -> Dictionary:
		return state.duplicate(true) if String(state.get("instance_id", "")) == instance_id else {}

	func begin_reload(command: Dictionary) -> Dictionary:
		if String(state.get("phase", "")) != "ready" \
				or int(command.get("expected_revision", -1)) != int(state.get("revision", -2)):
			return {"accepted": false, "mutation_state": MUTATION_NONE}
		state["revision"] = int(state["revision"]) + 1
		state["phase"] = "reloading"
		state["last_command_sequence"] = int(command["sequence"])
		state["admitted_sequence_high_watermark"] = int(command["sequence"])
		due_tick = int(command["tick"]) + 5
		state["reload"] = {
			"reservation_id": String(command["reservation_id"]),
			"reserved_rounds": int(command["reserved_rounds"]),
			"start_tick": int(command["tick"]),
			"due_tick": due_tick,
			"reserved_profile": {
				"has_profile": true,
				"id": String((command["profile"] as Dictionary)["id"]),
				"version": int((command["profile"] as Dictionary)["version"]),
			},
		}
		return {
			"accepted": true,
			"replayed": false,
			"revision": int(state["revision"]),
			"loaded_rounds": int(state["loaded_rounds"]),
		}

	func cancel_reload(command: Dictionary) -> Dictionary:
		if String(state.get("phase", "")) != "reloading" \
				or int(command.get("expected_revision", -1)) != int(state.get("revision", -2)):
			return {"accepted": false, "mutation_state": MUTATION_NONE}
		var reservation_id := String((state["reload"] as Dictionary)["reservation_id"])
		state["revision"] = int(state["revision"]) + 1
		state["phase"] = "ready"
		state["reload"] = {}
		state["last_command_sequence"] = int(command["sequence"])
		state["admitted_sequence_high_watermark"] = int(command["sequence"])
		return {
			"accepted": true,
			"replayed": false,
			"revision": int(state["revision"]),
			"loaded_rounds": int(state["loaded_rounds"]),
			"reservation_to_release": reservation_id,
		}

	func due_reloads(tick: int) -> Array:
		if String(state.get("phase", "")) != "reloading" or tick < due_tick:
			return []
		return [_completion()]

	func prepare_due_reload(tick: int, instance_id: String, reservation_id: String) -> Dictionary:
		var completion := _completion()
		if tick < due_tick or String(completion.get("instance_id", "")) != instance_id \
				or String(completion.get("reservation_id", "")) != reservation_id:
			return {"accepted": false, "mutation_state": MUTATION_NONE}
		_prepared = completion.duplicate(true)
		return {
			"accepted": true,
			"stage": &"prepared",
			"completion": completion,
			"mutation_state": MUTATION_NONE,
		}

	func commit_reload_silent(reservation_id: String) -> Dictionary:
		if _prepared.is_empty() or String(_prepared["reservation_id"]) != reservation_id:
			return {"accepted": false, "mutation_state": MUTATION_NONE}
		if commit_interleave.is_valid():
			commit_interleave.call()
		if fail_commit_without_mutation:
			return {
				"accepted": false,
				"reason": &"fixture_commit_failure",
				"mutation_state": MUTATION_NONE,
			}
		_predecessor = state.duplicate(true)
		_committed = _prepared.duplicate(true)
		state["revision"] = int(_committed["revision"])
		state["loaded_rounds"] = int(_committed["loaded_rounds"])
		state["loaded_profile"] = (_committed["profile"] as Dictionary).duplicate(true)
		state["phase"] = "ready"
		state["reload"] = {}
		return {
			"accepted": true,
			"stage": &"committed",
			"completion": _committed.duplicate(true),
			"mutation_state": MUTATION_COMMITTED,
		}

	func rollback_reload(reservation_id: String) -> Dictionary:
		if _committed.is_empty() or String(_committed["reservation_id"]) != reservation_id \
				or _predecessor.is_empty():
			return {"accepted": false, "mutation_state": MUTATION_AMBIGUOUS}
		state = _predecessor.duplicate(true)
		_prepared.clear()
		_predecessor.clear()
		_committed.clear()
		return {"accepted": true, "stage": &"rolled_back", "mutation_state": MUTATION_NONE}

	func publish_reload(reservation_id: String) -> Dictionary:
		if _committed.is_empty() or String(_committed["reservation_id"]) != reservation_id:
			return {"accepted": false, "mutation_state": MUTATION_AMBIGUOUS}
		return {
			"accepted": true,
			"stage": &"published",
			"completion": _committed.duplicate(true),
			"mutation_state": MUTATION_COMMITTED,
		}

	func clear() -> void:
		state.clear()
		_prepared.clear()
		_predecessor.clear()
		_committed.clear()

	func _completion() -> Dictionary:
		var reload := state.get("reload", {}) as Dictionary
		var added := int(reload.get("reserved_rounds", 0))
		return {
			"instance_id": String(state.get("instance_id", "")),
			"reservation_id": String(reload.get("reservation_id", "")),
			"added_rounds": added,
			"revision": int(state.get("revision", 0)) + 1,
			"loaded_rounds": int(state.get("loaded_rounds", 0)) + added,
			"profile": (reload.get("reserved_profile", {}) as Dictionary).duplicate(true),
		}


var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_WEAPON_RELOAD_CONTRACT: " + message)


func run() -> void:
	check(ClassDB.class_has_method(&"WeaponAuthority", &"commit_due_reload"),
		"installed WeaponAuthority exposes commit_due_reload")
	check(not ClassDB.class_has_method(&"WeaponAuthority", &"rollback_reload_completion"),
		"installed WeaponAuthority honestly lacks public reload rollback")
	_run_real_addon_flow()
	_run_real_active_teardown_flow()
	_run_real_persistence_generation_replay_flow()
	_run_real_external_owner_teardown_flow()
	_run_real_external_completion_fail_stop_flow()
	_run_real_weapon_port_token_invalidation_flow()
	_run_real_rejected_begin_teardown_flow()
	_run_known_failure_rollback_flow()
	_run_unproven_rollback_fail_stop_flow()
	print("INVENTORY_WEAPON_RELOAD_RESULT checks=", checks, " failures=", failures,
		" real_addons=true facade_rollback=false")
	quit(0 if failures == 0 else 1)


func _run_real_addon_flow() -> void:
	var fixture := _build_inventory_fixture("real", 0)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var weapon_authority := WeaponAuthority.new()
	weapon_authority.name = "ReloadContractWeaponAuthority"
	root.add_child(weapon_authority)
	var configured := ZerkovCombatContent.configure_authority(weapon_authority)
	check(bool(configured.get("ok", false)), "real WeaponAuthority configures from sealed Zerkov content")
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var created: Dictionary = weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		0,
		{},
		admission.raid_id.canonical_key(),
		admission.authority_epoch
	)
	check(bool(created.get("ok", false)), "real AKM instance is created outside task-4.9 adapter")
	var forged_mapping := mapping.duplicate(true)
	forged_mapping["weapon_id"] = ZWeaponId.from_parts(
		PackedStringArray(["reload", "forged", "weapon"])).canonical_key()
	forged_mapping["entity_id"] = ZEntityId.from_parts(
		PackedStringArray(["reload", "forged", "entity"])).canonical_key()
	check(bool(weapon_authority.create_weapon(
		String(forged_mapping["weapon_id"]),
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		0,
		{},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"valid-looking forged mapping has a matching real weapon fixture")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority), "real WeaponAuthority compatibility port configures")
	check(port.commit_capability() \
		== WeaponReloadParticipantPort.CommitCapability.FACADE_SINGLE_WRITER,
		"real port reports single-writer facade capability, not rollbackable 2PC")
	var adapter := InventoryWeaponAdapter.new()
	adapter.name = "InventoryWeaponAdapterReal"
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()),
		"adapter binds exact owner/admission/real weapon port")
	check(adapter.register_weapon(forged_mapping, 1).get("reason") \
		== &"weapon_mapping_identity_not_authoritative",
		"mapping IDs must exactly re-derive from the equipped inventory item context")
	var registered := adapter.register_weapon(mapping, 1)
	check(bool(registered.get("accepted", false)), "equipped AKM mapping registers")

	var native_order: Array[String] = []
	var coherent_at_inventory_publish: Array[bool] = []
	var cancel_saw_held_inventory: Array[bool] = []
	var publish_signal_count: Array[int] = [0]
	var publish_reentry_results: Array[Dictionary] = []
	owner.raid_authority().quantity_reservation_published.connect(func(_result: Dictionary):
		native_order.append("inventory")
		var state := weapon_authority.snapshot(weapon_id)
		coherent_at_inventory_publish.append(
			String(state.get("phase", "")) == "ready"
			and int(state.get("loaded_rounds", -1)) == ZerkovCombatContent.AKM_CAPACITY))
	weapon_authority.reload_completed.connect(func(completion: Dictionary):
		native_order.append("weapon")
		publish_signal_count[0] += 1
		if publish_signal_count[0] == 1:
			publish_reentry_results.append(
				port.publish_reload(String(completion.get("reservation_id", "")))))
	weapon_authority.reload_cancelled.connect(func(outcome: Dictionary):
		var reservation_id := String(outcome.get("reservation_to_release", ""))
		var health := owner.raid_authority().health_quantity_reservation(reservation_id)
		cancel_saw_held_inventory.append(
			bool(health.get("accepted", false)) and int(health.get("stage", -1)) == 1))

	# A native begin signal listener tries to re-enter the game-owned adapter.
	# The call observes a rejection and cannot reserve, sequence, or mutate.
	var reentrant_results: Array[Dictionary] = []
	var reentrant_intent := _begin_intent(fixture, adapter, weapon_authority.snapshot(weapon_id),
		"real_reentrant", 0)
	weapon_authority.reload_started.connect(func(_outcome: Dictionary):
		if reentrant_results.is_empty():
			reentrant_results.append(adapter.begin_reload(reentrant_intent)))

	var ammo_before := _ammo_quantity(owner)
	var begin_one := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "real_cancel", 0)
	var begun_one := adapter.begin_reload(begin_one)
	check(bool(begun_one.get("accepted", false)) and begun_one.get("kind") == &"reload_started",
		"real flow reserves ammunition and begins reload")
	check(reentrant_results.size() == 1 \
		and reentrant_results[0].get("reason") == &"reload_transaction_active",
		"reload_started signal cannot re-enter adapter mutation")
	var pending := adapter.pending_reloads()
	check(pending.size() == 1 and int(pending[0].get("quantity", 0)) == 30,
		"empty AKM reserves exactly its missing capacity")
	var lines := pending[0].get("reservation_lines", []) as Array
	var source_policy := pending[0].get("container_priority", []) as Array
	check(source_policy[0] == String(ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM)
		and source_policy[1] == String(ZerkovInventoryCatalog.CONTAINER_RIG)
		and source_policy[2] == String(ZerkovInventoryCatalog.CONTAINER_POCKETS),
		"reservation exposes exact magazine, rig, pockets source policy")
	check(lines.size() == 3 \
		and int((lines[0] as Dictionary).get("item", 0)) == int(fixture["magazine_ammo_item"])
		and int((lines[0] as Dictionary).get("quantity", 0)) == 7
		and int((lines[1] as Dictionary).get("item", 0)) == int(fixture["rig_ammo_item"])
		and int((lines[1] as Dictionary).get("quantity", 0)) == 8
		and int((lines[2] as Dictionary).get("item", 0)) == int(fixture["pockets_ammo_item"])
		and int((lines[2] as Dictionary).get("quantity", 0)) == 15,
		"real magazine ammunition selects before rig then pockets by exact policy")
	check(owner.raid_authority().inventory_revision(owner.raid_player_inventory_id)
		== int(begin_one["expected_inventory_revision"]),
		"reservation hold does not change inventory revision")
	check(_ammo_quantity(owner) == ammo_before, "reservation hold consumes no ammunition")
	var conflicting_begin := begin_one.duplicate(true)
	conflicting_begin["tick"] = 1
	check(adapter.begin_reload(conflicting_begin).get("reason") == &"request_id_payload_conflict",
		"same request identity with different payload fails closed")
	check(adapter.advance_due_reloads(1).is_empty(),
		"pre-deadline due sweep cannot commit held ammunition")

	var cancel_one := _cancel_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "real_cancel", 1)
	var cancelled_one := adapter.cancel_reload(cancel_one)
	check(bool(cancelled_one.get("accepted", false)) \
		and cancelled_one.get("kind") == &"reload_cancelled",
		"user cancellation stops weapon before releasing inventory hold")
	check(owner.raid_authority().active_quantity_reservation_count() == 0 \
		and _ammo_quantity(owner) == ammo_before,
		"cancel releases hold without ammunition loss")
	check(_item_quantity(owner, int(fixture["magazine_ammo_item"])) == 7
		and _item_quantity(owner, int(fixture["rig_ammo_item"])) == 8
		and _item_quantity(owner, int(fixture["pockets_ammo_item"])) == 20,
		"cancel preserves exact magazine, rig, and pockets source quantities")
	check(cancel_saw_held_inventory == [true],
		"weapon cancellation occurs before inventory reservation release")
	var cancel_replay := adapter.cancel_reload(cancel_one)
	check(bool(cancel_replay.get("accepted", false)) and bool(cancel_replay.get("replayed", false)),
		"identical cancel request replays its original terminal receipt")

	var begin_death := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "real_death", 2)
	check(bool(adapter.begin_reload(begin_death).get("accepted", false)),
		"second real reservation begins")
	var death := adapter.interrupt_reload(weapon_id, &"death", 3)
	check(bool(death.get("accepted", false)) and death.get("kind") == &"reload_cancelled",
		"death interruption cancels and releases")
	check(_ammo_quantity(owner) == ammo_before, "death before commit loses no ammunition")

	var begin_swap := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "real_swap", 4)
	check(bool(adapter.begin_reload(begin_swap).get("accepted", false)),
		"third real reservation begins before equipment swap")
	var authority := owner.raid_authority()
	var backpack := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var move: Dictionary = authority.move_item(
		owner.raid_player_inventory_id,
		int(mapping["native_item_id"]),
		_spatial(backpack, 2, 3),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		9_101
	)
	check(bool(move.get("accepted", false)), "equipped AKM can leave primary slot")
	var swap_outcomes := adapter.advance_due_reloads(5)
	check(swap_outcomes.size() == 1 \
		and bool(swap_outcomes[0].get("accepted", false)) \
		and swap_outcomes[0].get("kind") == &"reload_cancelled",
		"equipment validation cancels swapped weapon before due commit")
	check(_ammo_quantity(owner) == ammo_before, "weapon swap before commit loses no ammunition")
	var equipment := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var re_equip: Dictionary = authority.equip_item(
		owner.raid_player_inventory_id,
		int(mapping["native_item_id"]),
		equipment,
		String(EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		9_102
	)
	check(bool(re_equip.get("accepted", false)), "same canonical AKM re-equips for final flow")

	var final_begin_intent := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "real_commit", 6)
	var final_begun := adapter.begin_reload(final_begin_intent)
	check(bool(final_begun.get("accepted", false)), "final real reservation begins")
	var due_tick := int(final_begun.get("due_tick", -1))
	check(due_tick == 6 + ZerkovCombatContent.AKM_RELOAD_TICKS,
		"real add-on exposes the exact authored reload deadline")
	var final_outcomes := adapter.advance_due_reloads(due_tick)
	check(final_outcomes.size() == 1 \
		and bool(final_outcomes[0].get("accepted", false)) \
		and final_outcomes[0].get("kind") == &"reload_committed",
		"real due flow commits both authorities")
	check(_ammo_quantity(owner) == ammo_before - 30 \
		and int(weapon_authority.snapshot(weapon_id).get("loaded_rounds", -1)) == 30,
		"real due commit consumes exactly once and loads exactly once")
	check(_item_quantity(owner, int(fixture["magazine_ammo_item"])) == 0
		and _item_quantity(owner, int(fixture["rig_ammo_item"])) == 0
		and _item_quantity(owner, int(fixture["pockets_ammo_item"])) == 5,
		"commit drains magazine then rig and consumes only the reserved pockets remainder")
	var committed_snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	check(_item_quantity(owner, int(fixture["magazine_item"])) == 1
		and _provided_container(
			committed_snapshot,
			int(fixture["magazine_item"]),
			ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM) \
			== int(fixture["magazine_container"]),
		"reload consumption leaves the canonical magazine item and empty child container intact")
	check(native_order == ["inventory", "weapon"] \
		and coherent_at_inventory_publish == [true],
		"both canonical states are coherent before inventory then weapon notifications")
	check(publish_signal_count[0] == 1 \
		and publish_reentry_results.size() == 1 \
		and bool(publish_reentry_results[0].get("accepted", false)) \
		and bool(publish_reentry_results[0].get("replayed", false)),
		"same-reservation publication reentry replays without recursion or a duplicate signal")
	check(owner.raid_authority().active_quantity_reservation_count() == 0 \
		and adapter.pending_reloads().is_empty(),
		"successful commit leaves no active hold or pending coordinator record")

	var inventory_revision_after := authority.inventory_revision(owner.raid_player_inventory_id)
	var weapon_revision_after := int(weapon_authority.snapshot(weapon_id).get("revision", -1))
	var begin_replay := adapter.begin_reload(final_begin_intent)
	check(bool(begin_replay.get("accepted", false)) and bool(begin_replay.get("replayed", false)),
		"completed begin request replays original receipt")
	check(_ammo_quantity(owner) == ammo_before - 30 \
		and authority.inventory_revision(owner.raid_player_inventory_id) == inventory_revision_after \
		and int(weapon_authority.snapshot(weapon_id).get("revision", -1)) == weapon_revision_after \
		and _item_quantity(owner, int(fixture["pockets_ammo_item"])) == 5,
		"replay cannot duplicate ammunition or weapon revision")
	var stale_intent := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "real_stale", due_tick + 1)
	stale_intent["expected_inventory_revision"] = inventory_revision_after - 1
	check(adapter.begin_reload(stale_intent).get("reason") == &"inventory_revision_stale",
		"stale inventory revision fails before reload-not-needed or mutation")
	check(adapter.release_binding(&"teardown", due_tick + 2),
		"adapter releases cleanly before owner teardown")
	check(owner.teardown(owner.generation()), "real inventory owner tears down after adapter")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_real_active_teardown_flow() -> void:
	var fixture := _build_inventory_fixture("real_teardown", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(weapon_authority).get("ok", false)),
		"active-teardown real WeaponAuthority configures")
	check(bool(weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		10,
		{
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"active-teardown real AKM creates with ten loaded rounds")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority), "active-teardown real port configures")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()) \
		and bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"active-teardown adapter binds registered weapon")
	var ammo_before := _ammo_quantity(owner)
	var intent := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "active_teardown", 0)
	check(bool(adapter.begin_reload(intent).get("accepted", false)) \
		and owner.raid_authority().active_quantity_reservation_count() == 1,
		"active-teardown fixture has one real held reservation")
	check(adapter.release_binding(&"teardown", 1),
		"explicit adapter teardown cancels active real reload")
	check(_ammo_quantity(owner) == ammo_before \
		and owner.raid_authority().active_quantity_reservation_count() == 0 \
		and String(weapon_authority.snapshot(weapon_id).get("phase", "")) == "ready",
		"active teardown releases ammo and leaves weapon ready without loss")
	check(owner.teardown(owner.generation()), "active-teardown inventory owner tears down")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_real_persistence_generation_replay_flow() -> void:
	var fixture := _build_inventory_fixture("persistence_generation", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(weapon_authority).get(
		"ok", false)),
		"persistence-generation real WeaponAuthority configures")
	check(bool(weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		10,
		{
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"persistence-generation real AKM creates with ten loaded rounds")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority),
		"persistence-generation real port configures")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()) \
		and bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"persistence-generation adapter binds registered weapon")
	var authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var record := authority.make_persistence_record(inventory_id)
	var intent := _begin_intent(
		fixture,
		adapter,
		weapon_authority.snapshot(weapon_id),
		"persistence_generation",
		17)
	var begun := adapter.begin_reload(intent)
	check(bool(begun.get("accepted", false)) \
		and begun.get("kind", &"") == &"reload_started" \
		and adapter.pending_reloads().size() == 1 \
		and authority.active_quantity_reservation_count() == 1,
		"persistence-generation fixture owns one pending reload and native hold")
	var invalidations: Array[StringName] = []
	adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		invalidations.append(reason))
	var replacement: Dictionary = authority.apply_persistence_record(record, true)
	check(bool(replacement.get("ok", false)) \
		and adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED \
		and invalidations == [&"authority_invalidation"],
		"same-ID persistence replacement invalidates reload coordination exactly once")
	check(adapter.pending_reloads().is_empty() \
		and authority.active_quantity_reservation_count() == 0 \
		and String(weapon_authority.snapshot(weapon_id).get("phase", "")) == "ready",
		"replacement cancels the weapon and clears pending and held ammunition state")
	check((adapter.get("_request_receipts") as Dictionary).is_empty() \
		and (adapter.get("_receipt_order") as PackedStringArray).is_empty(),
		"generation invalidation clears reload request receipt and order ledgers")
	var stale_replay := adapter.begin_reload(intent)
	check(not bool(stale_replay.get("accepted", true)) \
		and not bool(stale_replay.get("replayed", true)) \
		and stale_replay.get("reason", &"") == &"adapter_not_bound" \
		and stale_replay.get("kind", &"") != &"reload_started",
		"invalidated adapter cannot replay the old accepted begin receipt")
	check(adapter.pending_reloads().is_empty() \
		and authority.active_quantity_reservation_count() == 0 \
		and String(weapon_authority.snapshot(weapon_id).get("phase", "")) == "ready",
		"stale exact replay leaves pending, hold, and weapon state unchanged")
	check(owner.teardown(owner.generation()),
		"persistence-generation inventory owner tears down")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_real_external_owner_teardown_flow() -> void:
	var fixture := _build_inventory_fixture("external_teardown", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(weapon_authority).get("ok", false)),
		"external-teardown real WeaponAuthority configures")
	check(bool(weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		10,
		{
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"external-teardown real AKM creates")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority), "external-teardown real port configures")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()) \
		and bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"external-teardown adapter binds registered weapon")
	var bound_generation := adapter.adapter_generation()
	var authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var intent := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "external_teardown", 17)
	check(bool(adapter.begin_reload(intent).get("accepted", false)) \
		and authority.active_quantity_reservation_count() == 1,
		"external-teardown fixture has one real held reservation at a nonzero tick")
	check(owner.teardown(owner.generation()),
		"inventory owner teardown unloads while reload is active")
	check(adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED \
		and adapter.adapter_generation() > bound_generation,
		"inventory unload synchronously invalidates the adapter and advances generation")
	var weapon_after := weapon_authority.snapshot(weapon_id)
	check(String(weapon_after.get("phase", "")) == "ready" \
		and (weapon_after.get("reload", {}) as Dictionary).is_empty(),
		"inventory unload cancels the real weapon using a monotonic authority tick")
	check(not authority.has_inventory(inventory_id) \
		and authority.active_quantity_reservation_count() == 0 \
		and adapter.pending_reloads().is_empty(),
		"inventory lifecycle clears the exact hold and leaves no coordinator record")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_real_external_completion_fail_stop_flow() -> void:
	var fixture := _build_inventory_fixture("external_completion", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(weapon_authority).get("ok", false)),
		"external-completion real WeaponAuthority configures")
	check(bool(weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		10,
		{
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"external-completion real AKM creates with ten loaded rounds")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority), "external-completion real port configures")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()) \
		and bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"external-completion adapter binds registered weapon")
	var ammo_before := _ammo_quantity(owner)
	var loaded_before := int(weapon_authority.snapshot(weapon_id).get("loaded_rounds", -1))
	var intent := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "external_completion", 0)
	var begun := adapter.begin_reload(intent)
	check(bool(begun.get("accepted", false)) and int(begun.get("quantity", 0)) == 20,
		"external-completion reload begins with one exact twenty-round hold")
	var reservation_id := String(begun.get("reservation_id", ""))
	var due_tick := int(begun.get("due_tick", -1))
	var direct: Array = weapon_authority.advance_tick(due_tick)
	check(direct.size() == 1 \
		and int(weapon_authority.snapshot(weapon_id).get("loaded_rounds", -1)) == 30,
		"raw WeaponAuthority bypass completes the held reload mechanically")
	check(_ammo_quantity(owner) == ammo_before \
		and owner.raid_authority().active_quantity_reservation_count() == 1,
		"raw weapon completion cannot silently consume or release inventory")
	var cancel := _cancel_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "external_completion", due_tick)
	var outcome := adapter.cancel_reload(cancel)
	check(not bool(outcome.get("accepted", true)) \
		and outcome.get("reason") == &"weapon_completed_outside_reload_transaction" \
		and adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED,
		"ready weapon with changed rounds latches recovery instead of refunding ammunition")
	var health := owner.raid_authority().health_quantity_reservation(reservation_id)
	var loaded_after := int(weapon_authority.snapshot(weapon_id).get("loaded_rounds", -1))
	check(bool(health.get("accepted", false)) and int(health.get("stage", -1)) == 1 \
		and int(health.get("quantity", 0)) == 20 \
		and owner.raid_authority().active_quantity_reservation_count() == 1,
		"external completion retains the exact HELD reservation under recovery")
	check(_ammo_quantity(owner) - int(health.get("quantity", 0)) + loaded_after \
		== ammo_before + loaded_before,
		"spendable inventory plus loaded rounds remains exactly conserved")
	check(adapter.pending_reloads().size() == 1 \
		and adapter.pending_reloads()[0].get("stage") == &"recovery_required",
		"recovery retains the transaction identity and canonical evidence")
	check(adapter.interrupt_reload(weapon_id, &"death", due_tick + 1).get("reason") \
		== &"reload_recovery_required" \
		and owner.raid_authority().active_quantity_reservation_count() == 1,
		"later interruption cannot refund or mint past the recovery latch")
	check(owner.teardown(owner.generation()),
		"external-completion inventory lifecycle clears the quarantined hold")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_real_weapon_port_token_invalidation_flow() -> void:
	var fixture := _build_inventory_fixture("port_token", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(weapon_authority).get("ok", false)),
		"port-token original WeaponAuthority configures")
	check(bool(weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		10,
		{
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"port-token original AKM creates")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority), "port-token original port configures")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()) \
		and bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"port-token adapter binds registered weapon")
	var ammo_before := _ammo_quantity(owner)
	var begun := adapter.begin_reload(_begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "port_token", 0))
	check(bool(begun.get("accepted", false)) \
		and owner.raid_authority().active_quantity_reservation_count() == 1,
		"port-token fixture begins with one exact live hold")
	var original_token := port.identity_token()
	var replacement_authority := WeaponAuthority.new()
	root.add_child(replacement_authority)
	check(bool(ZerkovCombatContent.configure_authority(replacement_authority).get("ok", false)),
		"port-token replacement WeaponAuthority configures")
	port.clear()
	check(port.configure(replacement_authority) and port.identity_token() != original_token,
		"real compatibility port changes to a distinct valid authority token")
	check(not adapter.validate_binding(1) \
		and adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED,
		"changed weapon port with live inventory latches recovery")
	var health := owner.raid_authority().health_quantity_reservation(
		String(begun.get("reservation_id", "")))
	check(bool(health.get("accepted", false)) and int(health.get("stage", -1)) == 1 \
		and adapter.pending_reloads().size() == 1 \
		and _ammo_quantity(owner) == ammo_before,
		"token invalidation retains the hold and pending evidence without refund")
	check(String(weapon_authority.snapshot(weapon_id).get("phase", "")) == "reloading",
		"original weapon state remains explicitly ambiguous after port replacement")
	check(owner.teardown(owner.generation()),
		"port-token inventory lifecycle clears the quarantined hold")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()
	replacement_authority.queue_free()


func _run_real_rejected_begin_teardown_flow() -> void:
	var fixture := _build_inventory_fixture("rejected_begin_teardown", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var weapon_id := String(mapping["weapon_id"])
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(weapon_authority).get("ok", false)),
		"rejected-begin WeaponAuthority configures")
	check(bool(weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		10,
		{
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
		admission.raid_id.canonical_key(),
		admission.authority_epoch).get("ok", false)),
		"rejected-begin AKM creates")
	var port := WeaponAuthorityReloadPort.new()
	check(port.configure(weapon_authority), "rejected-begin port configures")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, port, owner.generation()) \
		and bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"rejected-begin adapter binds registered weapon")
	var intent := _begin_intent(
		fixture, adapter, weapon_authority.snapshot(weapon_id), "rejected_begin_teardown", 0)
	var reservation_id := InventoryWeaponAdapter.derive_reservation_id(
		admission,
		owner.generation(),
		adapter.adapter_generation(),
		owner.raid_player_inventory_id,
		mapping,
		1,
		String(intent["request_id"]))
	var command_id: String = adapter._derive_command_id(
		"begin", reservation_id, String(intent["request_id"]))
	var seeded: Dictionary = weapon_authority.begin_reload({
		"command_id": command_id,
		"sequence": 1,
		"instance_id": weapon_id,
		"expected_revision": 999,
		"tick": 0,
		"authority_scope": admission.raid_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"reservation_id": "rejected-begin-conflict",
		"reserved_rounds": 1,
		"profile": {
			"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
			"version": ZerkovCombatContent.CONTENT_VERSION,
		},
	})
	check(not bool(seeded.get("accepted", true)),
		"rejected-begin conflicting native command receipt is seeded")
	var inventory_authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var teardown_results: Array[bool] = []
	weapon_authority.command_rejected.connect(func(_outcome: Dictionary):
		if teardown_results.is_empty():
			teardown_results.append(owner.teardown(owner.generation())))
	var begun := adapter.begin_reload(intent)
	check(not bool(begun.get("accepted", true)) and teardown_results == [true],
		"owner teardown runs synchronously from the real rejected begin callback")
	check(adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED \
		and adapter.pending_reloads().is_empty(),
		"rejected begin settles deferred invalidation before returning")
	check(not inventory_authority.has_inventory(inventory_id) \
		and inventory_authority.active_quantity_reservation_count() == 0 \
		and String(weapon_authority.snapshot(weapon_id).get("phase", "")) == "ready",
		"rejected begin teardown leaves neither an orphan hold nor a started weapon")
	adapter.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_known_failure_rollback_flow() -> void:
	var fixture := _build_inventory_fixture("rollback", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var fake := FakeRollbackableWeaponPort.new()
	fake.setup(String(mapping["weapon_id"]), admission.raid_id.canonical_key(),
		admission.authority_epoch, 10)
	fake.fail_commit_without_mutation = true
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, fake, owner.generation()),
		"rollback fixture binds full participant seam")
	check(bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"rollback fixture registers weapon")
	var ammo_before := _ammo_quantity(owner)
	var inventory_revision_before := owner.raid_authority().inventory_revision(
		owner.raid_player_inventory_id)
	var intent := _begin_intent(fixture, adapter, fake.snapshot(String(mapping["weapon_id"])),
		"known_failure", 0)
	check(bool(adapter.begin_reload(intent).get("accepted", false)),
		"rollback fixture reserves and begins")
	var outcomes := adapter.advance_due_reloads(5)
	check(outcomes.size() == 1 \
		and not bool(outcomes[0].get("accepted", true)) \
		and outcomes[0].get("kind") == &"reload_commit_rolled_back",
		"known weapon pre-mutation failure rolls inventory back")
	check(_ammo_quantity(owner) == ammo_before \
		and owner.raid_authority().inventory_revision(owner.raid_player_inventory_id)
			== inventory_revision_before,
		"proven rollback restores exact inventory quantity and revision")
	check(String(fake.state.get("phase", "")) == "ready" \
		and int(fake.state.get("loaded_rounds", -1)) == 10 \
		and owner.raid_authority().active_quantity_reservation_count() == 0,
		"failed commit cancels weapon and leaves no active reservation")
	check(adapter.pending_reloads().is_empty(), "failed transaction is terminal, not retryable")
	check(adapter.release_binding(&"teardown", 6), "rollback fixture adapter releases")
	check(owner.teardown(owner.generation()), "rollback fixture owner tears down")
	adapter.queue_free()
	owner.queue_free()


func _run_unproven_rollback_fail_stop_flow() -> void:
	var fixture := _build_inventory_fixture("fail_stop", 10)
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	var fake := FakeRollbackableWeaponPort.new()
	fake.setup(String(mapping["weapon_id"]), admission.raid_id.canonical_key(),
		admission.authority_epoch, 10)
	fake.fail_commit_without_mutation = true
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(owner, admission, fake, owner.generation()),
		"fail-stop fixture binds")
	check(bool(adapter.register_weapon(mapping, 1).get("accepted", false)),
		"fail-stop fixture registers weapon")
	var authority := owner.raid_authority()
	var pockets := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	fake.commit_interleave = func():
		# Deliberate single-writer contract violation after inventory silent
		# commit. This advances aggregate revision so rollback cannot be proven.
		authority.insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_BANDAGE),
			1,
			_spatial(pockets, 3, 1),
			RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
			9_901)
	var intent := _begin_intent(fixture, adapter, fake.snapshot(String(mapping["weapon_id"])),
		"rollback_unproven", 0)
	check(bool(adapter.begin_reload(intent).get("accepted", false)),
		"fail-stop fixture begins before adversarial interleave")
	var outcomes := adapter.advance_due_reloads(5)
	check(outcomes.size() == 1 \
		and not bool(outcomes[0].get("accepted", true)) \
		and outcomes[0].get("kind") == &"reload_recovery_required" \
		and adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED,
		"unprovable inventory rollback latches terminal recovery")
	var second := _begin_intent(fixture, adapter, fake.snapshot(String(mapping["weapon_id"])),
		"forbidden_after_recovery", 6)
	check(adapter.begin_reload(second).get("reason") == &"reload_recovery_required",
		"recovery latch forbids minting a replacement reload identity")
	check(bool(adapter.recovery_details().get("new_reload_forbidden", false)),
		"recovery diagnostics explicitly require authoritative recovery")
	# Recovery ownership is intentionally outside task 4.9. Unloading the
	# inventory clears the unpublished native participant before disposal.
	check(owner.teardown(owner.generation()), "fail-stop owner lifecycle clears scoped hold")
	adapter.queue_free()
	owner.queue_free()


func _build_inventory_fixture(label: String, _loaded_rounds: int) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["reload", label]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid_id, &"reload_profile", &"player")
	check(admission != null and admission.is_usable(), label + " admission is usable")
	var owner := RaidInventoryOwner.new()
	owner.name = "ReloadInventoryOwner_" + label
	root.add_child(owner)
	check(owner.configure(), label + " inventory owner configures")
	var authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var equipment := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var backpack := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var rig := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_RIG)
	var pockets := _root_container(owner, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	check(equipment > 0 and backpack > 0 and rig > 0 and pockets > 0,
		label + " required inventory containers resolve")
	var akm: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		8_001
	)
	check(bool(akm.get("accepted", false)), label + " AKM equips")
	var magazine: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM),
		1,
		_spatial(rig, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		8_002
	)
	var magazine_item_id := int(magazine.get("new_item_id", 0))
	var magazine_container_id := _provided_container(
		authority.snapshot(inventory_id),
		magazine_item_id,
		ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM)
	check(bool(magazine.get("accepted", false))
		and magazine_item_id > 0
		and magazine_container_id > 0,
		label + " real AKM magazine materializes its ammunition container")
	var magazine_ammo: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		7,
		{"kind": "list", "container": magazine_container_id, "ordinal": 0},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		8_003
	)
	var rig_ammo: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		8,
		_spatial(rig, 1, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		8_004
	)
	var pockets_ammo: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		20,
		_spatial(pockets, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		8_005
	)
	check(bool(magazine_ammo.get("accepted", false)) \
		and bool(rig_ammo.get("accepted", false)) \
		and bool(pockets_ammo.get("accepted", false)),
		label + " magazine, rig, and pockets ammunition fixture inserts")
	var native_item_id := int(akm.get("new_item_id", 0))
	var identities := EquippedItemReconciler.derive_identity_keys(
		admission, owner.generation(), inventory_id, native_item_id,
		ZerkovInventoryCatalog.ITEM_AKM)
	var mapping := {
		"slot_identifier": EquippedItemReconciler.SLOT_PRIMARY,
		"native_inventory_id": inventory_id,
		"native_item_id": native_item_id,
		"item_definition_identifier": ZerkovInventoryCatalog.ITEM_AKM,
		"combat_definition_identifier": ZerkovCombatContent.WEAPON_AKM,
		"weapon_kind": EquippedItemReconciler.WEAPON_KIND_FIREARM,
		"weapon_id": String(identities.get("weapon_id", "")),
		"entity_id": String(identities.get("entity_id", "")),
	}
	return {
		"owner": owner,
		"admission": admission,
		"mapping": mapping,
		"magazine_item": magazine_item_id,
		"magazine_container": magazine_container_id,
		"magazine_ammo_item": int(magazine_ammo.get("new_item_id", 0)),
		"rig_ammo_item": int(rig_ammo.get("new_item_id", 0)),
		"pockets_ammo_item": int(pockets_ammo.get("new_item_id", 0)),
	}


func _begin_intent(
	fixture: Dictionary,
	adapter: InventoryWeaponAdapter,
	weapon_snapshot: Dictionary,
	label: String,
	tick: int
) -> Dictionary:
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	return {
		"request_id": ZRequestId.from_parts(
			PackedStringArray(["reload", label])).canonical_key(),
		"weapon_id": String(mapping["weapon_id"]),
		"weapon_binding_generation": 1,
		"adapter_generation": adapter.adapter_generation(),
		"authority_epoch": admission.authority_epoch,
		"inventory_id": owner.raid_player_inventory_id,
		"expected_inventory_revision": owner.raid_authority().inventory_revision(
			owner.raid_player_inventory_id),
		"expected_weapon_revision": int(weapon_snapshot.get("revision", -1)),
		"tick": tick,
	}


func _cancel_intent(
	fixture: Dictionary,
	adapter: InventoryWeaponAdapter,
	weapon_snapshot: Dictionary,
	label: String,
	tick: int
) -> Dictionary:
	var owner := fixture["owner"] as RaidInventoryOwner
	var admission := fixture["admission"] as ZSessionAdmission
	var mapping := fixture["mapping"] as Dictionary
	return {
		"request_id": ZRequestId.from_parts(
			PackedStringArray(["reload_cancel", label])).canonical_key(),
		"weapon_id": String(mapping["weapon_id"]),
		"weapon_binding_generation": 1,
		"adapter_generation": adapter.adapter_generation(),
		"authority_epoch": admission.authority_epoch,
		"inventory_id": owner.raid_player_inventory_id,
		"expected_weapon_revision": int(weapon_snapshot.get("revision", -1)),
		"tick": tick,
		"reason": &"user_cancel",
	}


func _ammo_quantity(owner: RaidInventoryOwner) -> int:
	var result := 0
	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	if snapshot == null:
		return 0
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if StringName(item.get("item_definition_identifier", &"")) \
				== ZerkovInventoryCatalog.ITEM_AMMO_762:
			result += int(item.get("quantity", 0))
	return result


func _item_quantity(owner: RaidInventoryOwner, item_id: int) -> int:
	if item_id <= 0:
		return 0
	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	if snapshot == null:
		return 0
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return int(item.get("quantity", 0))
	return 0


func _root_container(owner: RaidInventoryOwner, definition: StringName) -> int:
	return _container_by_definition(
		owner.raid_authority().snapshot(owner.raid_player_inventory_id), definition, 0)


func _provided_container(
	snapshot: InventorySnapshotResource,
	provider_item: int,
	definition: StringName
) -> int:
	return _container_by_definition(snapshot, definition, provider_item)


func _container_by_definition(
	snapshot: InventorySnapshotResource,
	definition: StringName,
	provider_item: int
) -> int:
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == provider_item \
				and StringName(container.get("container_definition_identifier", &"")) == definition:
			return int(container.get("id", 0))
	return 0


func _slot(container: int, slot: StringName) -> Dictionary:
	return {"kind": "slot", "container": container, "slot_identifier": String(slot)}


func _spatial(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": y, "rotated": false}
