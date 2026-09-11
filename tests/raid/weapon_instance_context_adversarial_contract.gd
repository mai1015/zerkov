extends SceneTree
## Adversarial integration coverage for task 5.2's bounded instance lifecycle.
##
## Run with:
##   /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
##     --headless --path . --script \
##     res://tests/raid/weapon_instance_context_adversarial_contract.gd

var checks: int = 0
var failures: int = 0


class TargetedRemoveFailureAdapter extends WeaponInstanceContextAdapter:
	var failure_weapon_id: String = ""
	var injected_failures: int = 0

	func _remove_native_weapon(weapon_id: String) -> Dictionary:
		if weapon_id == failure_weapon_id and injected_failures == 0:
			injected_failures += 1
			return {
				"ok": false,
				"reservation_to_release": "",
				"injected": true,
			}
		return super._remove_native_weapon(weapon_id)


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("WEAPON_INSTANCE_CONTEXT_ADVERSARIAL: " + message)


func run() -> void:
	_run_sixteen_binding_recovery_teardown()
	_run_seventeenth_admission_byte_atomicity()
	print("WEAPON_INSTANCE_CONTEXT_ADVERSARIAL_RESULT checks=", checks,
		" failures=", failures,
		" recovery_drained=true capacity_rejection_atomic=true")
	quit(0 if failures == 0 else 1)


func _run_sixteen_binding_recovery_teardown() -> void:
	var adapter := TargetedRemoveFailureAdapter.new()
	var fixture := _build_fixture("recovery_sixteen", 5_208, adapter)
	var entries := _populate_live_akms(fixture, false, 160_000)
	check(entries.size() == WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS,
		"recovery fixture creates exactly sixteen stable live AKM identities")
	if entries.size() != WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS:
		_dispose_fixture(fixture)
		return

	var inventory: InventoryAuthority = fixture["inventory"]
	var inventory_id := int(fixture["inventory_id"])
	var pockets := int(fixture["pockets"])
	var ammo: Dictionary = inventory.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		30,
		_spatial(pockets, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		169_000)
	check(bool(ammo.get("accepted", false)),
		"recovery fixture inserts ammunition for the sixteenth active AKM")
	var active := entries[entries.size() - 1] as Dictionary
	var weapon_id := String(active["weapon_id"])
	var binding_generation := int(active["binding_generation"])
	var reload_adapter: InventoryWeaponAdapter = fixture["reload_adapter"]
	var weapon_authority: WeaponAuthority = fixture["weapon_authority"]
	var begun := reload_adapter.begin_reload({
		"request_id": ZRequestId.from_parts(PackedStringArray([
			"recovery_sixteen", "reload"])).canonical_key(),
		"weapon_id": weapon_id,
		"weapon_binding_generation": binding_generation,
		"adapter_generation": reload_adapter.adapter_generation(),
		"authority_epoch": (fixture["admission"] as ZSessionAdmission).authority_epoch,
		"inventory_id": inventory_id,
		"expected_inventory_revision": inventory.inventory_revision(inventory_id),
		"expected_weapon_revision": int(weapon_authority.snapshot(
			weapon_id).get("revision", -1)),
		"tick": 31,
	})
	var reservation_id := String(begun.get("reservation_id", ""))
	check(bool(begun.get("accepted", false)) and not reservation_id.is_empty()
		and reload_adapter.pending_reloads().size() == 1
		and inventory.active_quantity_reservation_count() == 1,
		"sixteen-binding fixture holds one exact active reload")

	var weapon_port: WeaponAuthorityReloadPort = fixture["weapon_port"]
	var original_port_token := weapon_port.identity_token()
	var replacement_authority := WeaponAuthority.new()
	root.add_child(replacement_authority)
	fixture["replacement_authority"] = replacement_authority
	check(bool(ZerkovCombatContent.configure_authority(
		replacement_authority).get("ok", false)),
		"replacement WeaponAuthority configures for provenance mismatch")
	weapon_port.clear()
	var rebound := weapon_port.configure(replacement_authority)
	var recovery_detected := not reload_adapter.validate_binding(31)
	check(rebound and weapon_port.identity_token() != original_port_token
		and recovery_detected
		and reload_adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED
		and reload_adapter.last_error == &"weapon_binding_invalid_with_live_inventory",
		"active reload enters exact fail-stop recovery after port provenance changes")

	adapter.failure_weapon_id = weapon_id
	var owner: RaidInventoryOwner = fixture["owner"]
	var owner_generation := int(fixture["owner_generation"])
	var raid_authority: RaidAuthority = fixture["raid_authority"]
	check(owner.teardown(owner_generation),
		"owner-first teardown executes across sixteen context bindings")
	var receipts := reload_adapter.get("_terminal_quarantine_receipts") as Dictionary
	var bindings := reload_adapter.get("_bindings") as Dictionary
	var retained_records := adapter.instance_records()
	check(adapter.lifecycle == WeaponInstanceContextAdapter.Lifecycle.RECOVERY_REQUIRED
		and adapter.last_error == &"weapon_instance_remove_failed"
		and adapter.injected_failures == 1
		and retained_records.size() == 1
		and String(retained_records[0].get("weapon_id", "")) == weapon_id
		and String(retained_records[0].get(
			"terminal_reload_quarantine_reservation", "")) == reservation_id,
		"one injected native failure retains only its exact retryable record and evidence")
	check(reload_adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED
		and bindings.is_empty()
		and receipts.size() == WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS
		and reload_adapter.pending_reloads().is_empty()
		and inventory.active_quantity_reservation_count() == 0
		and not inventory.has_inventory(inventory_id),
		"owner loss boundedly quarantines every exact-generation reload binding")
	check(weapon_authority.snapshots().size() == 1
		and not weapon_authority.snapshot(weapon_id).is_empty()
		and raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID,
			raid_authority.generation()),
		"only the injected native failure and provider lease remain reachable for retry")
	var quarantine_replay := reload_adapter.quarantine_weapon_after_inventory_loss(
		weapon_id, binding_generation)
	var quarantine_stale := reload_adapter.quarantine_weapon_after_inventory_loss(
		weapon_id, binding_generation + 1)
	check(bool(quarantine_replay.get("accepted", false))
		and bool(quarantine_replay.get("replayed", false))
		and String(quarantine_replay.get("reservation_id", "")) == reservation_id
		and not bool(quarantine_stale.get("accepted", true))
		and quarantine_stale.get("reason") == &"weapon_binding_generation_stale",
		"retained terminal evidence is exact-generation replay scoped")

	var due_tick := int(begun.get("due_tick", 31))
	check(adapter.release_binding(&"teardown", due_tick)
		and adapter.lifecycle == WeaponInstanceContextAdapter.Lifecycle.INVALIDATED
		and adapter.last_error == &"teardown"
		and adapter.instance_records().is_empty()
		and weapon_authority.snapshots().is_empty()
		and not raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID,
			raid_authority.generation()),
		"exact recovery retry drains the last native record and provider handler")
	check((reload_adapter.get("_terminal_quarantine_receipts") as Dictionary).size()
			== WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS
		and bool((reload_adapter.quarantine_weapon_after_inventory_loss(
			weapon_id, binding_generation)).get("replayed", false)),
		"successful retry preserves bounded terminal receipts until a true owner reset")
	check(raid_authority.advance_one(raid_authority.generation()),
		"post-retry raid tick remains healthy after provider cleanup")

	var replacement_owner := RaidInventoryOwner.new()
	root.add_child(replacement_owner)
	fixture["replacement_owner"] = replacement_owner
	check(replacement_owner.configure()
		and reload_adapter.bind_owner(
			replacement_owner,
			fixture["admission"] as ZSessionAdmission,
			weapon_port,
			replacement_owner.generation())
		and (reload_adapter.get("_terminal_quarantine_receipts") as Dictionary).is_empty(),
		"a true new-owner bind clears prior terminal quarantine receipts once")
	check(reload_adapter.release_binding(&"teardown", due_tick),
		"replacement reload binding releases without residual records")
	check(replacement_owner.teardown(replacement_owner.generation()),
		"replacement owner tears down after receipt reset")
	check(raid_authority.teardown(raid_authority.generation()),
		"sixteen-binding recovery raid authority tears down")
	_dispose_fixture(fixture)


func _run_seventeenth_admission_byte_atomicity() -> void:
	var adapter := WeaponInstanceContextAdapter.new()
	var fixture := _build_fixture("capacity_atomic", 5_209, adapter)
	var entries := _populate_live_akms(fixture, true, 170_000)
	check(entries.size() == WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS,
		"capacity fixture parks exactly sixteen stable live AKM identities")
	if entries.size() != WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS:
		_dispose_fixture(fixture)
		return
	var records_before := adapter.instance_records()
	var outcome_before := adapter.current_outcome()
	var record_bytes_before := _record_bytes(records_before)
	var outcome_bytes_before := var_to_bytes(outcome_before)
	check(records_before.all(func(record: Dictionary) -> bool:
			return int(record.get("last_reconciled_tick", -1)) == 32)
		and int(outcome_before.get("tick", -1)) == 32,
		"sixteen public records and accepted outcome agree at tick 32")

	var inventory: InventoryAuthority = fixture["inventory"]
	var inserted: Dictionary = inventory.insert_item(
		int(fixture["inventory_id"]),
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(int(fixture["equipment"]), EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		179_000)
	var seventeenth_item_id := int(inserted.get("new_item_id", 0))
	var seventeenth_mapping := (fixture["reconciler"] as EquippedItemReconciler) \
		.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	var seventeenth_weapon_id := String(seventeenth_mapping.get("weapon_id", ""))
	check(bool(inserted.get("accepted", false)) and seventeenth_item_id > 0
		and not seventeenth_weapon_id.is_empty(),
		"seventeenth stable inventory identity reaches admission preflight")
	var raid_authority: RaidAuthority = fixture["raid_authority"]
	check(not raid_authority.advance_one(raid_authority.generation())
		and raid_authority.last_error == &"phase_handler_failed"
		and adapter.last_error == &"weapon_instance_limit",
		"seventeenth native admission rejects at the explicit live-instance cap")
	var records_after := adapter.instance_records()
	var outcome_after := adapter.current_outcome()
	check(_record_bytes(records_after) == record_bytes_before
		and var_to_bytes(outcome_after) == outcome_bytes_before
		and records_after == records_before
		and outcome_after == outcome_before,
		"capacity rejection leaves every public record and accepted outcome byte-exact")
	var weapon_authority: WeaponAuthority = fixture["weapon_authority"]
	var reload_adapter: InventoryWeaponAdapter = fixture["reload_adapter"]
	check(weapon_authority.snapshots().size()
			== WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS
		and weapon_authority.snapshot(seventeenth_weapon_id).is_empty()
		and (reload_adapter.get("_bindings") as Dictionary).size()
			== WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS,
		"rejected seventeenth identity creates no native or reload binding")

	check(adapter.release_binding(&"teardown", 33)
		and adapter.instance_records().is_empty()
		and weapon_authority.snapshots().is_empty(),
		"capacity rejection fixture releases all sixteen admitted instances")
	check(reload_adapter.release_binding(&"teardown", 33),
		"capacity rejection reload adapter releases")
	(fixture["reconciler"] as EquippedItemReconciler).release_binding(&"test_teardown")
	(fixture["bridge"] as InventoryProjectionBridge).release_binding()
	var owner: RaidInventoryOwner = fixture["owner"]
	check(owner.teardown(int(fixture["owner_generation"])),
		"capacity rejection owner tears down")
	check(raid_authority.teardown(raid_authority.generation()),
		"capacity rejection raid authority tears down")
	_dispose_fixture(fixture)


func _build_fixture(
	label: String,
	authority_seed: int,
	adapter: WeaponInstanceContextAdapter
) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", label]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, StringName(label + "_profile"), &"player")
	check(admission != null and admission.is_usable(), label + " admission is usable")
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	check(owner.configure(), label + " owner configures")
	var inventory := owner.raid_authority()
	_clear_inventory(inventory, owner.world_crate_inventory_id, 150_000)
	_clear_inventory(inventory, owner.corpse_inventory_id, 151_000)

	var owner_generation := owner.generation()
	var bridge := InventoryProjectionBridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation), label + " projection binds")
	var scope_generation := bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	var reconciler := EquippedItemReconciler.new()
	root.add_child(reconciler)
	check(reconciler.bind_owner(
		owner, bridge, admission, owner_generation, scope_generation),
		label + " reconciler binds")

	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(
		weapon_authority).get("ok", false)), label + " WeaponAuthority configures")
	var weapon_port := WeaponAuthorityReloadPort.new()
	check(weapon_port.configure(weapon_authority), label + " weapon port configures")
	var reload_adapter := InventoryWeaponAdapter.new()
	root.add_child(reload_adapter)
	check(reload_adapter.bind_owner(owner, admission, weapon_port, owner_generation),
		label + " reload adapter binds")
	var raid_authority := RaidAuthority.new()
	check(raid_authority.configure(raid_id, admission, authority_seed),
		label + " raid authority configures")
	root.add_child(adapter)
	check(adapter.bind_owner(
		owner, reconciler, admission, raid_authority, weapon_authority,
		weapon_port, reload_adapter, owner_generation, scope_generation,
		raid_authority.generation()), label + " instance adapter binds")
	check(raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, raid_authority.generation()),
		label + " raid activates")

	var player_snapshot := inventory.snapshot(owner.raid_player_inventory_id)
	return {
		"label": label,
		"admission": admission,
		"owner": owner,
		"owner_generation": owner_generation,
		"inventory": inventory,
		"inventory_id": owner.raid_player_inventory_id,
		"bridge": bridge,
		"reconciler": reconciler,
		"equipment": _container(
			player_snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT),
		"backpack": _container(
			player_snapshot, ZerkovInventoryCatalog.CONTAINER_BACKPACK),
		"pockets": _container(
			player_snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS),
		"world_container": _container(
			inventory.snapshot(owner.world_crate_inventory_id),
			ZerkovInventoryCatalog.CONTAINER_WORLD_CRATE),
		"corpse_container": _container(
			inventory.snapshot(owner.corpse_inventory_id),
			ZerkovInventoryCatalog.CONTAINER_CORPSE),
		"weapon_authority": weapon_authority,
		"weapon_port": weapon_port,
		"reload_adapter": reload_adapter,
		"raid_authority": raid_authority,
		"adapter": adapter,
	}


func _populate_live_akms(
	fixture: Dictionary,
	park_final: bool,
	command_base: int
) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var inventory: InventoryAuthority = fixture["inventory"]
	var inventory_id := int(fixture["inventory_id"])
	var reconciler: EquippedItemReconciler = fixture["reconciler"]
	var adapter: WeaponInstanceContextAdapter = fixture["adapter"]
	var raid_authority: RaidAuthority = fixture["raid_authority"]
	var placements := _storage_placements(fixture)
	for index in WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS:
		var inserted: Dictionary = inventory.insert_item(
			inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM),
			1,
			_slot(int(fixture["equipment"]), EquippedItemReconciler.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
			command_base + index * 4)
		var item_id := int(inserted.get("new_item_id", 0))
		var mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
		var weapon_id := String(mapping.get("weapon_id", ""))
		if not bool(inserted.get("accepted", false)) or item_id <= 0 or weapon_id.is_empty():
			check(false, "%s AKM %d inserts into primary slot" % [fixture["label"], index])
			return entries
		if not raid_authority.advance_one(raid_authority.generation()):
			check(false, "%s AKM %d admits on its creation tick" % [fixture["label"], index])
			return entries
		var binding_generation := adapter.weapon_binding_generation(weapon_id)
		if binding_generation <= 0:
			check(false, "%s AKM %d receives a binding generation" % [fixture["label"], index])
			return entries
		entries.append({
			"item_id": item_id,
			"weapon_id": weapon_id,
			"binding_generation": binding_generation,
		})
		if park_final or index < WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS - 1:
			var moved := _move_to_storage(
				fixture, item_id, placements[index] as Dictionary,
				command_base + index * 4 + 1)
			if not bool(moved.get("accepted", false)):
				check(false, "%s AKM %d parks in stable custody" % [fixture["label"], index])
				return entries
			if not raid_authority.advance_one(raid_authority.generation()):
				check(false, "%s AKM %d reconciles as parked" % [fixture["label"], index])
				return entries
	check(adapter.instance_records().size()
		== WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS
		and (fixture["weapon_authority"] as WeaponAuthority).snapshots().size()
			== WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS
		and (fixture["reload_adapter"] as InventoryWeaponAdapter).get("_bindings").size()
			== WeaponInstanceContextAdapter.MAX_TRACKED_FIREARMS,
		fixture["label"] + " exposes sixteen coherent records, natives, and reload bindings")
	return entries


func _storage_placements(fixture: Dictionary) -> Array[Dictionary]:
	var placements: Array[Dictionary] = []
	for index in 4:
		placements.append({
			"inventory_id": int(fixture["inventory_id"]),
			"placement": _spatial_rotated(int(fixture["backpack"]), index * 2, 0),
		})
	for index in 4:
		placements.append({
			"inventory_id": (fixture["owner"] as RaidInventoryOwner).world_crate_inventory_id,
			"placement": _spatial_rotated(int(fixture["world_container"]), index * 2, 0),
		})
	for index in 8:
		placements.append({
			"inventory_id": (fixture["owner"] as RaidInventoryOwner).corpse_inventory_id,
			"placement": _spatial(
				int(fixture["corpse_container"]), (index % 2) * 5, (index / 2) * 2),
		})
	return placements


func _move_to_storage(
	fixture: Dictionary,
	item_id: int,
	storage: Dictionary,
	command_id: int
) -> Dictionary:
	var inventory: InventoryAuthority = fixture["inventory"]
	var source_id := int(fixture["inventory_id"])
	var destination_id := int(storage["inventory_id"])
	if source_id == destination_id:
		return inventory.move_item(
			source_id,
			item_id,
			(storage["placement"] as Dictionary).duplicate(true),
			RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
			command_id)
	return inventory.loot_item(
		source_id,
		destination_id,
		item_id,
		(storage["placement"] as Dictionary).duplicate(true),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		command_id)


func _clear_inventory(
	inventory: InventoryAuthority,
	inventory_id: int,
	command_base: int
) -> void:
	var snapshot := inventory.snapshot(inventory_id)
	if snapshot == null:
		check(false, "fixture inventory exists before clearing")
		return
	var item_ids: Array[int] = []
	for item_value in snapshot.get_items():
		item_ids.append(int((item_value as Dictionary).get("id", 0)))
	item_ids.sort()
	for index in item_ids.size():
		var removed: Dictionary = inventory.remove_item(
			inventory_id,
			item_ids[index],
			RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
			command_base + index)
		check(bool(removed.get("accepted", false)),
			"fixture storage item %d clears" % item_ids[index])


func _record_bytes(records: Array[Dictionary]) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for record in records:
		result.append(var_to_bytes(record))
	return result


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


func _spatial_rotated(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": y, "rotated": true}


func _dispose_fixture(fixture: Dictionary) -> void:
	for key in [
		"adapter", "reload_adapter", "reconciler", "bridge", "owner",
		"weapon_authority", "replacement_authority", "replacement_owner",
	]:
		var value: Variant = fixture.get(key)
		if value is Node and is_instance_valid(value):
			(value as Node).queue_free()
