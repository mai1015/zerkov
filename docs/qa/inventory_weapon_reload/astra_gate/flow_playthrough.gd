extends SceneTree
## Independent Astra real-addon flow. Validation harness, not production UI.

const OUTPUT := "res://docs/qa/inventory_weapon_reload/astra_gate/"
var checks := 0
var failures := 0
var failed_checks: Array[String] = []
var timeline: Array[Dictionary] = []
var cases: Array[Dictionary] = []

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical 1280x720 QA flow is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

func verify(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		failed_checks.append(message)
		push_error("ASTRA_RELOAD_FLOW: " + message)

func run() -> void:
	var rollback_methods: Array[String] = []
	var reload_methods: Array[String] = []
	for entry in ClassDB.class_get_method_list(&"WeaponAuthority", true):
		var method := String((entry as Dictionary).get("name", ""))
		if method.contains("reload"):
			reload_methods.append(method)
		if method.contains("rollback"):
			rollback_methods.append(method)
	verify(rollback_methods.is_empty(), "installed binary exposes no weapon rollback method")
	verify(reload_methods.has("commit_due_reload") and reload_methods.has("publish_reload_completion"),
		"installed binary exposes split silent completion and publication")
	write_json("native_api.json", {"reload_methods": reload_methods, "rollback_methods": rollback_methods})
	continuous_flow()
	for mode in ["death", "swap", "teardown"]:
		same_tick_interrupt(mode)
	external_cancel()
	external_completion()
	port_replacement()
	forged_identity()
	rejected_begin_teardown()
	ledger_pressure()
	await process_frame
	await process_frame
	var native := DisplayServer.get_name() != "headless"
	if native:
		await capture_timeline()
	write_json("native_flow_results.json" if native else "flow_results.json", {
		"checks": checks, "failures": failures, "failed_checks": failed_checks,
		"human_approval": false, "real_addons": true,
		"mode": "native_validation_harness" if native else "headless",
		"timeline": timeline, "cases": cases,
		"scope": "Serialized in-memory offline single-writer/no-yield reload coordination",
		"excluded": ["crash/restart recovery", "physical magazine-object swapping", "production weapon lifecycle", "input gameplay", "human playtest"]})
	print("ASTRA_RELOAD_FLOW_RESULT checks=", checks, " failures=", failures, " real_addons=true")
	quit(0 if failures == 0 else 1)

func fixture(label: String, loaded: int = 6) -> Dictionary:
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		ZRaidId.from_parts(PackedStringArray(["astra", "reload", label])), &"astra_profile", &"player")
	verify(admission != null and admission.is_usable(), label + " trusted admission")
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	verify(owner.configure(), label + " real inventory setup")
	var inv := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var equipment := container_id(inv.snapshot(inventory_id), ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var rig := container_id(inv.snapshot(inventory_id), ZerkovInventoryCatalog.CONTAINER_RIG)
	var pocket := container_id(inv.snapshot(inventory_id), ZerkovInventoryCatalog.CONTAINER_POCKETS)
	var backpack := container_id(inv.snapshot(inventory_id), ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var akm: Dictionary = inv.insert_item(inventory_id, String(ZerkovInventoryCatalog.ITEM_AKM), 1,
		{"kind": "slot", "container": equipment, "slot_identifier": String(EquippedItemReconciler.SLOT_PRIMARY)}, 701, 1)
	verify(akm.get("accepted", false), label + " real equipped AKM")
	# Magazine provider construction is independently rejected in magazine_probe.gd.
	# This continuous flow deliberately uses three honest loose-ammo stacks.
	var mag_ammo: Dictionary = inv.insert_item(inventory_id, String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		12, spatial(rig, 1, 0), 701, 3)
	var rig_ammo: Dictionary = inv.insert_item(inventory_id, String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		18, spatial(rig, 0, 0), 701, 4)
	var pocket_ammo: Dictionary = inv.insert_item(inventory_id, String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		15, spatial(pocket, 0, 0), 701, 5)
	verify(mag_ammo.get("accepted", false) and rig_ammo.get("accepted", false) and pocket_ammo.get("accepted", false),
		label + " exact 45-round three-source ammo fixture")
	var identities := EquippedItemReconciler.derive_identity_keys(admission, owner.generation(), inventory_id,
		int(akm.get("new_item_id", 0)), ZerkovInventoryCatalog.ITEM_AKM)
	var mapping := {
		"slot_identifier": EquippedItemReconciler.SLOT_PRIMARY, "native_inventory_id": inventory_id,
		"native_item_id": int(akm.get("new_item_id", 0)), "item_definition_identifier": ZerkovInventoryCatalog.ITEM_AKM,
		"combat_definition_identifier": ZerkovCombatContent.WEAPON_AKM, "weapon_kind": EquippedItemReconciler.WEAPON_KIND_FIREARM,
		"weapon_id": String(identities.get("weapon_id", "")), "entity_id": String(identities.get("entity_id", ""))}
	var weapon := WeaponAuthority.new()
	root.add_child(weapon)
	verify(ZerkovCombatContent.configure_authority(weapon).get("ok", false), label + " real weapon setup")
	verify(weapon.create_weapon(mapping["weapon_id"], String(ZerkovCombatContent.WEAPON_AKM), 1, loaded,
		{"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD), "version": 1} if loaded > 0 else {},
		admission.raid_id.canonical_key(), admission.authority_epoch).get("ok", false), label + " native weapon instance")
	var port := WeaponAuthorityReloadPort.new()
	verify(port.configure(weapon), label + " real reload port")
	var adapter := InventoryWeaponAdapter.new()
	root.add_child(adapter)
	verify(adapter.bind_owner(owner, admission, port, owner.generation()), label + " binds current authority")
	verify(adapter.register_weapon(mapping, 1).get("accepted", false), label + " registers derived equipped mapping")
	return {"label": label, "owner": owner, "admission": admission, "inv": inv, "inventory_id": inventory_id,
		"weapon": weapon, "port": port, "adapter": adapter, "mapping": mapping, "weapon_id": mapping["weapon_id"],
		"mag_ammo_id": int(mag_ammo.get("new_item_id", 0)),
		"rig_ammo_id": int(rig_ammo.get("new_item_id", 0)), "pocket": pocket, "backpack": backpack,
		"initial_total": 45 + loaded, "initial_inventory_revision": inv.inventory_revision(inventory_id)}

func continuous_flow() -> void:
	var start_checks := checks
	var f := fixture("continuous")
	var inv: InventoryAuthority = f["inv"]
	var weapon: WeaponAuthority = f["weapon"]
	var port: WeaponAuthorityReloadPort = f["port"]
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var observed: Array[String] = []
	var recursive_publications: Array[Dictionary] = []
	var callback_states: Array[Dictionary] = []
	var reentrant_begins: Array[Dictionary] = []
	inv.quantity_reservation_published.connect(func(_value: Dictionary):
		observed.append("inventory")
		callback_states.append(state(f))
		reentrant_begins.append(adapter.begin_reload(begin_intent(f, "during_publication", 155))))
	weapon.reload_completed.connect(func(value: Dictionary):
		observed.append("weapon")
		if recursive_publications.is_empty():
			recursive_publications.append({"guard": true})
			recursive_publications[0] = port.publish_reload(String(value.get("reservation_id", ""))))
	record_step(f, "Initial / equipped AKM", 0, 45, 6, 4, 0, 0, "ready")
	var first := begin_intent(f, "first_begin", 10)
	var begun := adapter.begin_reload(first)
	verify(begun.get("accepted", false) and int(begun.get("quantity", 0)) == 24 and int(begun.get("due_tick", 0)) == 82,
		"continuous reserve is exact missing capacity with authored deadline")
	var first_reservation := String(begun.get("reservation_id", ""))
	var held: Dictionary = inv.health_quantity_reservation(first_reservation)
	verify(int(held.get("stage", -1)) == 1 and int(held.get("quantity", 0)) == 24, "continuous real HELD stage")
	var lines := held.get("lines", []) as Array
	verify(lines.size() == 2 and int(lines[0].get("item", 0)) == int(f["mag_ammo_id"])
		and int(lines[0].get("quantity", 0)) == 12 and int(lines[1].get("item", 0)) == int(f["rig_ammo_id"])
		and int(lines[1].get("quantity", 0)) == 12, "rig loose-ammo stacks selected in stable item order")
	record_step(f, "Reserve + begin", 10, 45, 6, 4, 1, 1, "reloading")
	verify(adapter.advance_due_reloads(81).is_empty(), "continuous pre-due sweep does not complete")
	record_step(f, "One tick before due", 81, 45, 6, 4, 1, 1, "reloading")
	var cancellation := cancel_intent(f, "at_due", 82)
	var cancelled := adapter.cancel_reload(cancellation)
	verify(cancelled.get("accepted", false) and cancelled.get("stage") == &"released", "explicit cancel wins when ordered before due sweep")
	verify(inv.health_quantity_reservation(first_reservation).get("stage") == 3, "native cancelled hold is RELEASED")
	verify(adapter.advance_due_reloads(82).is_empty(), "same-tick cancelled reload cannot subsequently commit")
	record_step(f, "Cancel at due tick", 82, 45, 6, 4, 2, 0, "ready")
	var second := begin_intent(f, "second_begin", 83)
	var begun_again := adapter.begin_reload(second)
	verify(begun_again.get("accepted", false) and String(begun_again.get("reservation_id", "")) != first_reservation,
		"new intentional reload uses a distinct reservation")
	record_step(f, "Reserve again", 83, 45, 6, 4, 3, 1, "reloading")
	var unrelated: Dictionary = inv.insert_item(f["inventory_id"], String(ZerkovInventoryCatalog.ITEM_BANDAGE),
		1, spatial(f["pocket"], 3, 1), 701, 10)
	verify(unrelated.get("accepted", false), "unrelated inventory revision can advance beside held ammo")
	var blocked: Dictionary = inv.remove_item(f["inventory_id"], f["mag_ammo_id"], 701, 11)
	verify(not blocked.get("accepted", true), "held loose ammo cannot be removed through canonical inventory")
	record_step(f, "Unrelated inventory change", 84, 45, 6, 5, 3, 1, "reloading")
	verify(adapter.advance_due_reloads(154).is_empty(), "second reload unchanged before due")
	var completed := adapter.advance_due_reloads(155)
	verify(completed.size() == 1 and completed[0].get("accepted", false)
		and completed[0].get("kind") == &"reload_committed" and completed[0].get("stage") == &"committed", "continuous due completion commits")
	var second_reservation := String(begun_again.get("reservation_id", ""))
	verify(inv.health_quantity_reservation(second_reservation).get("stage") == 4, "native terminal reservation is PUBLISHED")
	record_step(f, "Due commit", 155, 21, 30, 6, 4, 0, "ready")
	verify(observed == ["inventory", "weapon"], "inventory then weapon notification occurs once")
	verify(callback_states.size() == 1 and int(callback_states[0].get("inventory_ammo", 0)) == 21
		and int(callback_states[0].get("loaded", 0)) == 30 and callback_states[0].get("phase") == "ready",
		"inventory observer sees both committed domains")
	verify(recursive_publications.size() == 1 and recursive_publications[0].get("accepted", false)
		and recursive_publications[0].get("replayed", false), "recursive port publish returns terminal replay")
	verify(reentrant_begins.size() == 1 and reentrant_begins[0].get("reason") == &"reload_transaction_active",
		"publication callback cannot begin new authority mutation")
	var replay := adapter.begin_reload(second)
	verify(replay.get("accepted", false) and replay.get("replayed", false), "completed begin replays original receipt")
	verify(adapter.cancel_reload(cancellation).get("replayed", false), "earlier cancellation replays without touching newer state")
	verify(port.publish_reload(second_reservation).get("replayed", false), "explicit publication replay is idempotent")
	verify(adapter.advance_due_reloads(156).is_empty() and observed.size() == 2, "replays emit no duplicate completion")
	record_step(f, "Replay + late due sweep", 156, 21, 30, 6, 4, 0, "ready")
	verify(adapter.pending_reloads().is_empty(), "continuous flow has no orphan pending reload")
	close_fixture(f)
	cases.append({"name": "continuous_real_addon_flow", "checks": checks-start_checks, "notification_order": observed})

func same_tick_interrupt(mode: String) -> void:
	var before := checks
	var f := fixture("same_tick_" + mode)
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var inv: InventoryAuthority = f["inv"]
	var begun := adapter.begin_reload(begin_intent(f, "begin", 20))
	verify(begun.get("accepted", false), mode + " begin")
	var due := int(begun.get("due_tick", -1))
	if mode == "death":
		verify(adapter.interrupt_reload(f["weapon_id"], &"death", due).get("accepted", false), "death wins at due tick")
	elif mode == "swap":
		var moved: Dictionary = inv.move_item(f["inventory_id"], f["mapping"]["native_item_id"], spatial(f["backpack"], 2, 3), 701, 20)
		verify(moved.get("accepted", false), "canonical swap at due tick")
		var outcomes := adapter.advance_due_reloads(due)
		verify(outcomes.size() == 1 and outcomes[0].get("kind") == &"reload_cancelled", "swap inspection precedes due completion")
	else:
		verify(adapter.release_binding(&"teardown", due), "explicit teardown wins at due tick")
	var after := state(f)
	verify(int(after["inventory_ammo"]) == 45 and int(after["loaded"]) == 6 and int(after["holds"]) == 0,
		mode + " all ammunition conserved and hold released")
	verify(after["phase"] == "ready" and int(after["weapon_revision"]) == 2 and adapter.pending_reloads().is_empty(),
		mode + " weapon cancel advances one revision with no pending reload")
	close_fixture(f)
	cases.append({"name": "same_tick_"+mode, "checks": checks-before, "after": after})

func external_cancel() -> void:
	var before := checks
	var f := fixture("external_cancel")
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var weapon: WeaponAuthority = f["weapon"]
	var begun := adapter.begin_reload(begin_intent(f, "begin", 20))
	var raw := raw_cancel(f, 100, 21)
	verify(raw.get("accepted", false), "external exact native cancellation succeeds")
	verify(f["inv"].active_quantity_reservation_count() == 1, "native cancellation alone retains inventory hold")
	var result := adapter.cancel_reload(cancel_intent(f, "reconcile", 21))
	verify(result.get("accepted", false) and result.get("weapon", {}).get("proof") == &"externally_cancelled_unchanged",
		"adapter proves external cancellation from exact native identity/revision/rounds")
	verify(ammo(f) == 45 and weapon.snapshot(f["weapon_id"]).get("loaded_rounds") == 6
		and f["inv"].active_quantity_reservation_count() == 0, "external cancellation conserves ammo and releases hold")
	verify(f["inv"].health_quantity_reservation(begun.get("reservation_id")).get("stage") == 3,
		"external cancellation ends in native RELEASED")
	close_fixture(f)
	cases.append({"name": "external_cancel_proof", "checks": checks-before})

func external_completion() -> void:
	var before := checks
	var f := fixture("external_completion")
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var weapon: WeaponAuthority = f["weapon"]
	var inv: InventoryAuthority = f["inv"]
	var begun := adapter.begin_reload(begin_intent(f, "begin", 20))
	var rid := String(begun.get("reservation_id", ""))
	var due := int(begun.get("due_tick", -1))
	verify(weapon.advance_tick(due).size() == 1, "quarantine challenge bypasses coordinator through real weapon facade")
	var outcome := adapter.cancel_reload(cancel_intent(f, "reconcile", due))
	verify(not outcome.get("accepted", true) and outcome.get("reason") == &"weapon_completed_outside_reload_transaction",
		"externally loaded weapon cannot be refunded as a cancelled reload")
	verify(adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED, "out-of-band completion is quarantined")
	var health: Dictionary = inv.health_quantity_reservation(rid)
	verify(health.get("stage") == 1 and health.get("quantity") == 24 and adapter.pending_reloads().size() == 1,
		"quarantine retains exact HELD transaction evidence")
	var quarantined := state(f)
	verify(int(quarantined["inventory_ammo"]) - int(health["quantity"]) + int(quarantined["loaded"]) == int(f["initial_total"]),
		"quarantine spendable inventory plus loaded rounds conserves initial total")
	verify(adapter.begin_reload(begin_intent(f, "new_id_forbidden", due+1)).get("reason") == &"reload_recovery_required",
		"quarantine cannot mint a new reload identity")
	verify(adapter.interrupt_reload(f["weapon_id"], &"death", due+1).get("reason") == &"reload_recovery_required",
		"quarantine death cannot release already loaded ammo")
	verify(not adapter.release_binding(&"teardown", due+1), "quarantine ordinary release cannot clear evidence")
	verify(inv.health_quantity_reservation(rid).get("stage") == 1, "failed retries preserve HELD state")
	cases.append({"name": "out_of_band_completion_quarantine", "checks": checks-before, "state": quarantined,
		"accounting": "45 inventory - 24 quarantined + 30 loaded = 51 initial", "recovery_is_disposal_only": true})
	close_fixture(f)

func port_replacement() -> void:
	var before := checks
	for mode in ["cleared", "replaced"]:
		var f := fixture("port_" + mode)
		var adapter: InventoryWeaponAdapter = f["adapter"]
		var port: WeaponAuthorityReloadPort = f["port"]
		var begun := adapter.begin_reload(begin_intent(f, "begin", 0))
		port.clear()
		var replacement: WeaponAuthority = null
		if mode == "replaced":
			replacement = WeaponAuthority.new()
			root.add_child(replacement)
			verify(ZerkovCombatContent.configure_authority(replacement).get("ok", false) and port.configure(replacement),
				"valid replacement port configures")
		verify(not adapter.validate_binding(1) and adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED,
			mode + " port cannot orphan a live hold")
		verify(f["inv"].health_quantity_reservation(begun.get("reservation_id")).get("stage") == 1
			and adapter.pending_reloads().size() == 1 and ammo(f) == 45, mode + " retains evidence and ammunition")
		close_fixture(f)
		if replacement != null:
			replacement.queue_free()
	cases.append({"name": "cleared_and_replaced_port", "checks": checks-before})

func forged_identity() -> void:
	var before := checks
	var f := fixture("forged")
	var mapping: Dictionary = f["mapping"].duplicate(true)
	mapping["weapon_id"] = ZWeaponId.from_parts(PackedStringArray(["astra", "forged"])).canonical_key()
	mapping["entity_id"] = ZEntityId.from_parts(PackedStringArray(["astra", "forged"])).canonical_key()
	verify(f["weapon"].create_weapon(mapping["weapon_id"], String(ZerkovCombatContent.WEAPON_AKM), 1, 0, {},
		f["admission"].raid_id.canonical_key(), f["admission"].authority_epoch).get("ok", false), "forged IDs match actual native weapon")
	verify(f["adapter"].register_weapon(mapping, 1).get("reason") == &"weapon_mapping_identity_not_authoritative",
		"valid-looking IDs do not bypass exact derived provenance")
	verify(ammo(f) == 45 and f["inv"].active_quantity_reservation_count() == 0, "forged identity mutates neither domain")
	close_fixture(f)
	cases.append({"name": "forged_valid_identity", "checks": checks-before})

func rejected_begin_teardown() -> void:
	var before := checks
	var f := fixture("rejected_begin")
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var owner: RaidInventoryOwner = f["owner"]
	var intent := begin_intent(f, "begin", 0)
	var rid := InventoryWeaponAdapter.derive_reservation_id(f["admission"], owner.generation(),
		adapter.adapter_generation(), f["inventory_id"], f["mapping"], 1, intent["request_id"])
	var digest := ZCanonicalValue.sha256({"schema": "zerkov.reload.command.v1", "kind": "begin",
		"reservation_id": rid, "request_id": intent["request_id"]})
	var seeded: Dictionary = f["weapon"].begin_reload({"command_id": "zerkov.reload_begin." + digest.substr(0, 32),
		"sequence": 1, "instance_id": f["weapon_id"], "expected_revision": 999, "tick": 0,
		"authority_scope": f["admission"].raid_id.canonical_key(), "authority_epoch": f["admission"].authority_epoch,
		"reservation_id": "astra.seeded.conflict", "reserved_rounds": 1,
		"profile": {"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD), "version": 1}})
	verify(not seeded.get("accepted", true), "real rejected receipt seeds begin conflict")
	var callbacks: Array[bool] = []
	f["weapon"].command_rejected.connect(func(_v: Dictionary):
		if callbacks.is_empty():
			callbacks.append(owner.teardown(owner.generation())))
	var result := adapter.begin_reload(intent)
	verify(not result.get("accepted", true) and callbacks == [true], "rejected-begin synchronous teardown executed")
	verify(adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED and adapter.pending_reloads().is_empty(),
		"rejected-begin deferred invalidation settles before return")
	verify(f["inv"].active_quantity_reservation_count() == 0 and not f["inv"].has_inventory(f["inventory_id"])
		and f["weapon"].snapshot(f["weapon_id"]).get("phase") == "ready", "rejected-begin leaves no orphan state")
	close_fixture(f)
	cases.append({"name": "rejected_begin_sync_teardown", "checks": checks-before})

func ledger_pressure() -> void:
	var before := checks
	var f := fixture("ledger")
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var active := begin_intent(f, "pinned", 0)
	verify(adapter.begin_reload(active).get("accepted", false), "ledger begins pinned active request")
	for index in range(300):
		var invalid := begin_intent(f, "flood_%d" % index, 0)
		invalid["unexpected"] = index
		verify(adapter.begin_reload(invalid).get("reason") == &"reload_intent_schema_invalid", "malformed pressure rejected %d" % index)
	verify(adapter.begin_reload(active).get("replayed", false), "active request survives receipt pressure")
	verify(adapter._request_receipts.size() <= InventoryWeaponAdapter.MAX_REQUEST_RECEIPTS,
		"request receipt memory remains bounded")
	verify(adapter.cancel_reload(cancel_intent(f, "cancel_pinned", 1)).get("accepted", false), "pressure does not prevent cancellation")
	for index in range(270):
		var tick := 2 + index * 2
		verify(adapter.begin_reload(begin_intent(f, "cycle_%d" % index, tick)).get("accepted", false), "ledger cycle begins %d" % index)
		verify(adapter.cancel_reload(cancel_intent(f, "cycle_%d" % index, tick+1)).get("accepted", false), "ledger cycle cancels %d" % index)
		verify(ammo(f) == 45 and f["weapon"].snapshot(f["weapon_id"]).get("loaded_rounds") == 6
			and f["inv"].active_quantity_reservation_count() == 0 and adapter.pending_reloads().is_empty(),
			"ledger cycle conserves quantity and clears holds %d" % index)
	var before_replay := state(f)
	var old_replay := adapter.begin_reload(active)
	verify(not old_replay.get("accepted", true) and old_replay.get("reason") == &"weapon_revision_stale",
		"evicted old request fails closed against current native revision")
	verify(state(f) == before_replay and adapter._request_receipts.size() <= InventoryWeaponAdapter.MAX_REQUEST_RECEIPTS,
		"evicted replay cannot mutate or grow ledger without bound")
	close_fixture(f)
	cases.append({"name": "ledger_pressure_replay", "checks": checks-before, "malformed_commands": 300, "cancelled_reload_cycles": 270})

func begin_intent(f: Dictionary, suffix: String, tick: int) -> Dictionary:
	return {"request_id": ZRequestId.from_parts(PackedStringArray(["astra", f["label"], suffix])).canonical_key(),
		"weapon_id": f["weapon_id"], "weapon_binding_generation": 1, "adapter_generation": f["adapter"].adapter_generation(),
		"authority_epoch": f["admission"].authority_epoch, "inventory_id": f["inventory_id"],
		"expected_inventory_revision": f["inv"].inventory_revision(f["inventory_id"]),
		"expected_weapon_revision": f["weapon"].snapshot(f["weapon_id"]).get("revision"), "tick": tick}

func cancel_intent(f: Dictionary, suffix: String, tick: int) -> Dictionary:
	var result := begin_intent(f, "cancel_"+suffix, tick)
	result.erase("expected_inventory_revision")
	result["reason"] = &"user_cancel"
	return result

func raw_cancel(f: Dictionary, sequence: int, tick: int) -> Dictionary:
	return f["weapon"].cancel_reload({"command_id": "astra.external.cancel."+str(sequence), "sequence": sequence,
		"instance_id": f["weapon_id"], "expected_revision": f["weapon"].snapshot(f["weapon_id"]).get("revision"),
		"tick": tick, "authority_scope": f["admission"].raid_id.canonical_key(), "authority_epoch": f["admission"].authority_epoch})

func state(f: Dictionary) -> Dictionary:
	var weapon: Dictionary = f["weapon"].snapshot(f["weapon_id"])
	return {"inventory_ammo": ammo(f), "loaded": int(weapon.get("loaded_rounds", -1)),
		"inventory_revision": f["inv"].inventory_revision(f["inventory_id"]), "weapon_revision": int(weapon.get("revision", -1)),
		"holds": f["inv"].active_quantity_reservation_count(), "phase": String(weapon.get("phase", ""))}

func record_step(f: Dictionary, label: String, tick: int, inventory_ammo: int, loaded: int,
		inventory_revision: int, weapon_revision: int, holds: int, phase: String) -> void:
	var actual := state(f)
	var expected := {"inventory_ammo": inventory_ammo, "loaded": loaded, "inventory_revision": inventory_revision,
		"weapon_revision": weapon_revision, "holds": holds, "phase": phase}
	verify(actual == expected, label + " exact cross-domain state " + JSON.stringify(actual))
	verify(int(actual["inventory_ammo"]) + int(actual["loaded"]) == int(f["initial_total"]), label + " total conservation")
	actual["label"] = label
	actual["tick"] = tick
	timeline.append(actual)

func ammo(f: Dictionary) -> int:
	var total := 0
	var snapshot: InventorySnapshotResource = f["inv"].snapshot(f["inventory_id"])
	if snapshot == null:
		return 0
	for value in snapshot.get_items():
		if String(value.get("item_definition_identifier", "")) == String(ZerkovInventoryCatalog.ITEM_AMMO_762):
			total += int(value.get("quantity", 0))
	return total

func container_id(snapshot: InventorySnapshotResource, definition: StringName, provider: int = 0) -> int:
	for value in snapshot.get_containers():
		if String(value.get("container_definition_identifier", "")) == String(definition) and int(value.get("provider_item", 0)) == provider:
			return int(value.get("id", 0))
	return 0

func spatial(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": y, "rotated": false}

func close_fixture(f: Dictionary) -> void:
	var adapter: InventoryWeaponAdapter = f["adapter"]
	var owner: RaidInventoryOwner = f["owner"]
	if adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.BOUND:
		verify(adapter.release_binding(&"teardown", 10000), String(f["label"])+" adapter releases")
	if owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
		verify(owner.teardown(owner.generation()), String(f["label"])+" inventory owner teardown")
	adapter.queue_free()
	owner.queue_free()
	f["weapon"].queue_free()
	f["port"].clear()

func write_json(filename: String, value: Dictionary) -> void:
	var file := FileAccess.open(OUTPUT + filename, FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t")+"\n")
	file.close()

func capture_timeline() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	var canvas := Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(canvas)
	var background := ColorRect.new()
	background.color = Color("121820")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(background)
	add_label(canvas, "ZERKOV / RELOAD AUTHORITY FLOW", Vector2(40, 25), 28, Color("f3f6f7"))
	add_label(canvas, "VALIDATION HARNESS / NOT PRODUCTION UI    •    Real InventoryAuthority + WeaponAuthority", Vector2(40, 67), 17, Color("e0b973"))
	add_label(canvas, "STEP", Vector2(42,116), 15, Color("a2acbb"))
	add_label(canvas, "TICK", Vector2(433,116), 15, Color("a2acbb"))
	add_label(canvas, "INVENTORY", Vector2(545,116), 15, Color("a2acbb"))
	add_label(canvas, "LOADED", Vector2(691,116), 15, Color("a2acbb"))
	add_label(canvas, "TOTAL", Vector2(807,116), 15, Color("a2acbb"))
	add_label(canvas, "INV REV / WPN REV", Vector2(944,116), 15, Color("a2acbb"))
	add_label(canvas, "HOLDS", Vector2(1160,116), 15, Color("a2acbb"))
	for index in range(timeline.size()):
		var row := timeline[index]
		var y := 154 + index*48
		var stripe := ColorRect.new()
		stripe.position = Vector2(32, y-7)
		stripe.size = Vector2(1216, 42)
		stripe.color = Color("1c2630") if index%2 == 0 else Color("161f28")
		canvas.add_child(stripe)
		add_label(canvas, "%02d  %s" % [index+1, row["label"]], Vector2(42,y), 17)
		add_label(canvas, str(row["tick"]), Vector2(433,y), 17)
		add_label(canvas, str(row["inventory_ammo"]), Vector2(545,y), 17)
		add_label(canvas, str(row["loaded"]), Vector2(691,y), 17)
		add_label(canvas, str(int(row["inventory_ammo"])+int(row["loaded"])), Vector2(807,y), 17, Color("92d2b0"))
		add_label(canvas, "%s / %s" % [row["inventory_revision"],row["weapon_revision"]], Vector2(944,y), 17)
		add_label(canvas, str(row["holds"]), Vector2(1160,y), 17)
	add_label(canvas, "%d machine checks / %d failures    •    Inventory → Weapon publication    •    Recursive publish: one signal" % [checks,failures], Vector2(40,566), 18, Color("92d2b0"))
	add_label(canvas, "Quarantine challenge: 45 inventory − 24 held + 30 loaded = 51 spendable rounds. New reloads blocked.", Vector2(40,606), 16, Color("e0b973"))
	add_label(canvas, "Offline in-memory single writer. No crash recovery, magazine-object swapping, production input, or human approval claimed.", Vector2(40,643), 15, Color("a2acbb"))
	await process_frame
	await RenderingServer.frame_post_draw
	var captured := root.get_texture().get_image()
	verify(captured.get_width() == 1280 and captured.get_height() == 720, "native validation canvas exact size")
	verify(captured.save_png(OUTPUT+"native_flow_1280x720.png") == OK, "native validation screenshot saved")
	canvas.queue_free()
	await process_frame
	await process_frame

func add_label(parent: Control, text: String, position: Vector2, size: int, color := Color("dde4ed")) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
