extends SceneTree
## Combined task 4.12/5.2 generation-lifecycle regression.
## Run with: /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
##   --headless --path . --audio-driver Dummy --script \
##   res://tests/raid/weapon_persistence_integration_contract.gd

const Boundary = preload("res://game/inventory/inventory_persistence_boundary.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("WEAPON_PERSISTENCE_INTEGRATION_CONTRACT: " + message)


func run() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray([
		"fixture", "weapon_persistence_integration"]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, &"weapon_persistence_profile", &"player")
	check(admission != null and admission.is_usable(),
		"offline admission is usable")

	var owner := RaidInventoryOwner.new()
	owner.name = "WeaponPersistenceInventoryOwner"
	root.add_child(owner)
	check(owner.configure(), "inventory owner configures")
	var owner_generation := owner.generation()
	var inventory := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id

	var bridge := InventoryProjectionBridge.new()
	bridge.name = "WeaponPersistenceProjectionBridge"
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"projection bridge binds the exact owner generation")
	var initial_snapshot := inventory.snapshot(inventory_id)
	var equipment := _container(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var backpack := _container(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var pockets := _container(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	check(equipment > 0 and backpack > 0 and pockets > 0,
		"required player containers resolve")

	var akm_insert: Dictionary = inventory.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		61_001)
	var ammo_insert: Dictionary = inventory.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		30,
		_spatial(pockets, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		61_002)
	check(bool(akm_insert.get("accepted", false))
		and bool(ammo_insert.get("accepted", false)),
		"equipped AKM and physical ammunition commit canonically")
	var akm_item_id := int(akm_insert.get("new_item_id", 0))

	var persistence_boundary := Boundary.new()
	check(persistence_boundary.bind_owner(owner, owner_generation),
		"persistence boundary binds before context composition")
	var envelope := persistence_boundary.capture_record(
		Boundary.SCOPE_RAID, inventory_id, owner_generation)
	var captured_snapshot := inventory.snapshot(inventory_id)
	check(not envelope.is_empty() and captured_snapshot != null,
		"equipped player inventory captures as a sealed persistence record")

	# Force a non-duplicate same-id replacement while retaining the exact captured
	# AKM identity and ammunition in the record that will be restored.
	var drift_insert: Dictionary = inventory.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_BOLTS),
		1,
		_spatial(backpack, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		61_003)
	check(bool(drift_insert.get("accepted", false))
		and inventory.snapshot(inventory_id).canonical_bytes()
			!= captured_snapshot.canonical_bytes(),
		"post-capture inventory drift requires a real replacement")

	var reconciler := EquippedItemReconciler.new()
	reconciler.name = "WeaponPersistenceEquippedReconciler"
	root.add_child(reconciler)
	var initial_scope_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	check(reconciler.bind_owner(
		owner, bridge, admission, owner_generation, initial_scope_generation),
		"equipment reconciler binds the live drifted projection")
	var initial_mapping := reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_PRIMARY)
	var weapon_id := String(initial_mapping.get("weapon_id", ""))
	check(akm_item_id > 0 and not weapon_id.is_empty()
		and int(initial_mapping.get("native_item_id", 0)) == akm_item_id,
		"equipped item resolves one stable weapon identity")

	var weapon_authority := WeaponAuthority.new()
	weapon_authority.name = "WeaponPersistenceWeaponAuthority"
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(
		weapon_authority).get("ok", false)),
		"sealed AKM runtime configures")
	var weapon_port := WeaponAuthorityReloadPort.new()
	check(weapon_port.configure(weapon_authority),
		"reload port binds the exact WeaponAuthority")
	var reload_adapter := InventoryWeaponAdapter.new()
	reload_adapter.name = "WeaponPersistenceReloadAdapter"
	root.add_child(reload_adapter)
	check(reload_adapter.bind_owner(
		owner, admission, weapon_port, owner_generation),
		"reload adapter binds the exact inventory generation")

	var first_raid_authority := RaidAuthority.new()
	check(first_raid_authority.configure(raid_id, admission, 6_101),
		"first raid authority configures")
	var context_adapter := WeaponInstanceContextAdapter.new()
	context_adapter.name = "WeaponPersistenceContextAdapter"
	root.add_child(context_adapter)
	check(context_adapter.bind_owner(
		owner,
		reconciler,
		admission,
		first_raid_authority,
		weapon_authority,
		weapon_port,
		reload_adapter,
		owner_generation,
		initial_scope_generation,
		first_raid_authority.generation()),
		"weapon context binds every first-generation authority")
	check(first_raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, first_raid_authority.generation())
		and first_raid_authority.advance_one(first_raid_authority.generation())
		and not weapon_authority.snapshot(weapon_id).is_empty(),
		"phase 5 creates the equipped native weapon")
	var first_context_generation := context_adapter.binding_generation()
	var first_weapon_binding_generation := context_adapter.weapon_binding_generation(
		weapon_id)
	var stale_phase_callback := Callable(
		context_adapter, "_on_weapon_phase").bind(first_context_generation)

	var old_model := bridge.presentation_model(InventoryProjectionBridge.SCOPE_RAID)
	var pending_id := bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"move",
		{"inventory_id": inventory_id, "items": [akm_item_id]},
		owner_generation,
		initial_scope_generation)
	check(pending_id > 0 and not old_model.get_pending(pending_id).is_empty(),
		"old projection generation owns one pending presentation intent")

	var old_begin_intent := _begin_reload_intent(
		admission,
		reload_adapter,
		inventory,
		inventory_id,
		weapon_authority,
		weapon_id,
		first_weapon_binding_generation,
		"weapon_persistence_reused_request",
		1)
	var old_begin := reload_adapter.begin_reload(old_begin_intent)
	check(bool(old_begin.get("accepted", false))
		and not bool(old_begin.get("replayed", true))
		and reload_adapter.pending_reloads().size() == 1
		and inventory.active_quantity_reservation_count() == 1
		and String(weapon_authority.snapshot(weapon_id).get("phase", ""))
			== "reloading",
		"old context owns one active native reload and inventory hold")
	check((reload_adapter.get("_request_receipts") as Dictionary).size() == 1
		and (reload_adapter.get("_receipt_order") as PackedStringArray).size() == 1,
		"accepted old begin is replayable only in its current generation")

	var context_invalidations: Array[StringName] = []
	context_adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		context_invalidations.append(reason))
	var reload_invalidations: Array[StringName] = []
	reload_adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		reload_invalidations.append(reason))
	var before_replacement := inventory.snapshot(inventory_id)
	var replacement := persistence_boundary.replace_live(
		envelope,
		owner_generation,
		_sha256_bytes(before_replacement.canonical_bytes()))
	var restored_snapshot := inventory.snapshot(inventory_id)
	check(bool(replacement.get("ok", false))
		and bool(replacement.get("replaced", false))
		and bool(replacement.get("committed", false))
		and bool(replacement.get("verified", false))
		and not bool(replacement.get("recovery_required", true)),
		"same-id replacement reports one truthful verified commit")
	check(_snapshots_visible_equal(restored_snapshot, captured_snapshot)
		and _sha256_bytes(restored_snapshot.canonical_bytes())
			== String(replacement.get("restored_canonical_sha256", "")),
		"replacement restores the captured visible inventory and exact reported bytes")
	check(context_adapter.lifecycle
			== WeaponInstanceContextAdapter.Lifecycle.INVALIDATED
		and reload_adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED
		and context_invalidations.size() == 1
		and reload_invalidations == [&"authority_invalidation"],
		"projection-first invalidation settles context before retiring reload generation")
	check(reload_adapter.pending_reloads().is_empty()
		and inventory.active_quantity_reservation_count() == 0
		and weapon_authority.snapshot(weapon_id).is_empty()
		and context_adapter.instance_records().is_empty()
		and not first_raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID,
			first_raid_authority.generation()),
		"replacement leaves no pending reload, hold, native instance, record, or handler")
	check((reload_adapter.get("_request_receipts") as Dictionary).is_empty()
		and (reload_adapter.get("_receipt_order") as PackedStringArray).is_empty()
		and (reload_adapter.get(
			"_terminal_quarantine_receipts") as Dictionary).is_empty(),
		"ordinary generation invalidation retires only its now-settled receipt ledgers")
	check(old_model.is_resynchronizing()
		and old_model.get_pending(pending_id).is_empty()
		and bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
			> initial_scope_generation,
		"replacement cancels old presentation pending state and advances scope generation")

	var stale_old_begin := reload_adapter.begin_reload(old_begin_intent)
	check(not bool(stale_old_begin.get("accepted", true))
		and not bool(stale_old_begin.get("replayed", true))
		and stale_old_begin.get("reason", &"") == &"adapter_not_bound"
		and reload_adapter.pending_reloads().is_empty()
		and inventory.active_quantity_reservation_count() == 0
		and (reload_adapter.get("_request_receipts") as Dictionary).is_empty(),
		"exact old begin rejects without stale success, pending state, hold, or ledger entry")
	var no_stale_intents: Array[ZRaidIntent] = []
	check(bool(stale_phase_callback.call(
		first_raid_authority,
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		2,
		no_stale_intents))
		and weapon_authority.snapshots().is_empty(),
		"captured old phase callback is inert after replacement")

	await process_frame
	await process_frame
	var rebound_scope_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
			== InventoryProjectionBridge.ProjectionStatus.READY
		and bridge.confirmed_snapshot(
			InventoryProjectionBridge.SCOPE_RAID, inventory_id).canonical_bytes()
			== restored_snapshot.canonical_bytes(),
		"deferred projection resync converges to only the restored generation")
	check(first_raid_authority.teardown(first_raid_authority.generation()),
		"first raid authority tears down after its provider handler is gone")

	check(reconciler.bind_owner(
		owner, bridge, admission, owner_generation, rebound_scope_generation),
		"reconciler rebinds the restored projection generation")
	var rebound_mapping := reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_PRIMARY)
	check(String(rebound_mapping.get("weapon_id", "")) == weapon_id
		and int(rebound_mapping.get("native_item_id", 0)) == akm_item_id,
		"restored item rebinds the same stable inventory and weapon identity")
	check(reload_adapter.bind_owner(
		owner, admission, weapon_port, owner_generation),
		"reload adapter resets onto the restored owner binding")
	var second_raid_authority := RaidAuthority.new()
	check(second_raid_authority.configure(raid_id, admission, 6_102),
		"replacement raid authority configures")
	check(context_adapter.bind_owner(
		owner,
		reconciler,
		admission,
		second_raid_authority,
		weapon_authority,
		weapon_port,
		reload_adapter,
		owner_generation,
		rebound_scope_generation,
		second_raid_authority.generation()),
		"weapon context rebinds after same-id replacement")
	check(second_raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, second_raid_authority.generation())
		and second_raid_authority.advance_one(second_raid_authority.generation())
		and weapon_authority.snapshots().size() == 1
		and not weapon_authority.snapshot(weapon_id).is_empty(),
		"rebound phase 5 creates exactly one native instance")
	var rebound_weapon_binding_generation := context_adapter.weapon_binding_generation(
		weapon_id)
	check(context_adapter.binding_generation() > first_context_generation
		and rebound_weapon_binding_generation > first_weapon_binding_generation
		and second_raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID,
			second_raid_authority.generation()),
		"rebind advances both context and reload-binding generations without handler loss")

	# Reuse the retired request identity with current generation facts. If the old
	# ledger survived replacement/reset, this would return a payload conflict.
	var fresh_begin_intent := old_begin_intent.duplicate(true)
	fresh_begin_intent["weapon_binding_generation"] = rebound_weapon_binding_generation
	fresh_begin_intent["adapter_generation"] = reload_adapter.adapter_generation()
	fresh_begin_intent["expected_inventory_revision"] = inventory.inventory_revision(
		inventory_id)
	fresh_begin_intent["expected_weapon_revision"] = int(weapon_authority.snapshot(
		weapon_id).get("revision", -1))
	fresh_begin_intent["tick"] = 1
	var fresh_begin := reload_adapter.begin_reload(fresh_begin_intent)
	check(bool(fresh_begin.get("accepted", false))
		and not bool(fresh_begin.get("replayed", true))
		and reload_adapter.pending_reloads().size() == 1
		and inventory.active_quantity_reservation_count() == 1,
		"current rebind reuses the retired request identity without ledger poisoning")

	var fresh_context_invalidations := context_invalidations.size()
	var fresh_reload_invalidations := reload_invalidations.size()
	check(owner.teardown(owner_generation),
		"owner-first teardown executes with the rebound reload active")
	check(context_adapter.lifecycle
			== WeaponInstanceContextAdapter.Lifecycle.INVALIDATED
		and reload_adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED
		and context_invalidations.size() == fresh_context_invalidations + 1
		and reload_invalidations.size() == fresh_reload_invalidations + 1,
		"owner-first teardown invalidates rebound context and reload binding once")
	check(reload_adapter.pending_reloads().is_empty()
		and inventory.active_quantity_reservation_count() == 0
		and not inventory.has_inventory(inventory_id)
		and weapon_authority.snapshots().is_empty()
		and context_adapter.instance_records().is_empty()
		and not second_raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID,
			second_raid_authority.generation()),
		"owner-first teardown leaves no pending, hold, inventory, native, record, or handler leak")
	var deregistration_replay := reload_adapter.unregister_weapon(
		weapon_id, rebound_weapon_binding_generation)
	var stale_fresh_begin := reload_adapter.begin_reload(fresh_begin_intent)
	check(bool(deregistration_replay.get("accepted", false))
		and bool(deregistration_replay.get("replayed", false))
		and not bool(stale_fresh_begin.get("accepted", true))
		and not bool(stale_fresh_begin.get("replayed", true))
		and (reload_adapter.get("_request_receipts") as Dictionary).is_empty()
		and (reload_adapter.get("_receipt_order") as PackedStringArray).is_empty(),
		"exact deregistration replays while torn-down request replay stays inert")
	check(second_raid_authority.advance_one(second_raid_authority.generation())
		and second_raid_authority.lifecycle == RaidAuthority.Lifecycle.ACTIVE,
		"owner-first cleanup leaves the next raid tick healthy")
	check(second_raid_authority.teardown(second_raid_authority.generation()),
		"replacement raid authority tears down after owner-first cleanup")

	context_adapter.queue_free()
	reload_adapter.queue_free()
	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()
	await process_frame
	await process_frame
	print("WEAPON_PERSISTENCE_INTEGRATION_RESULT checks=", checks,
		" failures=", failures,
		" replacement_verified=", bool(replacement.get("verified", false)),
		" stable_weapon_rebound=true owner_first_clean=true")
	quit(0 if failures == 0 else 1)


func _begin_reload_intent(
	admission: ZSessionAdmission,
	reload_adapter: InventoryWeaponAdapter,
	inventory: InventoryAuthority,
	inventory_id: int,
	weapon_authority: WeaponAuthority,
	weapon_id: String,
	weapon_binding_generation: int,
	request_label: String,
	tick: int
) -> Dictionary:
	return {
		"request_id": ZRequestId.from_parts(
			PackedStringArray(["reload", request_label])).canonical_key(),
		"weapon_id": weapon_id,
		"weapon_binding_generation": weapon_binding_generation,
		"adapter_generation": reload_adapter.adapter_generation(),
		"authority_epoch": admission.authority_epoch,
		"inventory_id": inventory_id,
		"expected_inventory_revision": inventory.inventory_revision(inventory_id),
		"expected_weapon_revision": int(weapon_authority.snapshot(
			weapon_id).get("revision", -1)),
		"tick": tick,
	}


func _container(snapshot: InventorySnapshotResource, definition: StringName) -> int:
	if snapshot == null:
		return 0
	for value in snapshot.get_containers():
		var container := value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get("container_definition_identifier", &"")) \
					== definition:
			return int(container.get("id", 0))
	return 0


func _slot(container: int, slot: StringName) -> Dictionary:
	return {"kind": "slot", "container": container, "slot_identifier": String(slot)}


func _spatial(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": y, "rotated": false}


func _snapshots_visible_equal(
	left: InventorySnapshotResource,
	right: InventorySnapshotResource
) -> bool:
	return left != null and right != null \
		and left.get_inventory_id() == right.get_inventory_id() \
		and left.get_profile_identifier() == right.get_profile_identifier() \
		and left.get_revision() == right.get_revision() \
		and left.get_manifest_fingerprint() == right.get_manifest_fingerprint() \
		and left.get_manifest_algorithm() == right.get_manifest_algorithm() \
		and left.get_visibility() == right.get_visibility() \
		and left.get_containers() == right.get_containers() \
		and left.get_items() == right.get_items() \
		and left.get_references() == right.get_references()


func _sha256_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()
