extends SceneTree
## Fresh independent real-addon flow. No promoted test is loaded or subclassed.
## This is a validation display, not production UI or production input routing.

const OUT: String = "res://docs/qa/inventory_weapon_reload/astra_final/"
const INITIAL_SOURCES: Array[int] = [11, 8, 19]
const INITIAL_LOADED: int = 3
const TOTAL: int = 41

class TimelineBoard extends Control:
	var rows: Array[Dictionary] = []
	var status_text: String = "RUNNING"

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		draw_rect(Rect2(0, 0, 1280, 720), Color("101923"))
		draw_string(font, Vector2(32, 40), "VALIDATION HARNESS / NOT PRODUCTION UI", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color("a4d5ff"))
		draw_string(font, Vector2(32, 75), "Task 4.9  |  Real Inventory + Weapon addons  |  Canonical magazine -> rig -> pockets", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("e1eaf3"))
		draw_string(font, Vector2(32, 105), "Native macOS Compatibility 1280 x 720  /  Automated flow, not a human playtest", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("93a8bb"))
		var headings: Array[String] = ["ORDERED STATE", "TICK", "MAG", "RIG", "POCKET", "LOADED", "HOLDS / QTY", "I / W REV", "TOTAL"]
		var xs: Array[int] = [32, 372, 463, 548, 625, 733, 849, 1005, 1158]
		draw_rect(Rect2(24, 130, 1230, 39), Color("233748"))
		for i in headings.size():
			draw_string(font, Vector2(xs[i], 156), headings[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("c2d5e6"))
		for index in rows.size():
			var row: Dictionary = rows[index]
			var y: int = 169 + index * 44
			draw_rect(Rect2(24, y, 1230, 43), Color("1a2b39") if index % 2 == 0 else Color("152431"))
			var cells: Array[String] = [str(index + 1) + ". " + String(row["label"]), str(row["tick"]),
				str(row["magazine"]), str(row["rig"]), str(row["pockets"]), str(row["loaded"]),
				str(row["holds"]) + " / " + str(row["held_quantity"]),
				str(row["inventory_revision"]) + " / " + str(row["weapon_revision"]), str(row["total"])]
			for i in cells.size():
				draw_string(font, Vector2(xs[i], y + 29), cells[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
					Color("91e6b8") if i == 8 else Color("ecf1f6"))
		draw_string(font, Vector2(32, 552), "Reservation: exact source IDs, [11 mag + 8 rig + 8 pocket] = 27 rounds. Initial loaded: 3.", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("c2d5e6"))
		draw_string(font, Vector2(32, 580), "Publication: inventory -> weapon. Both coherent; recursive publication emits one completion.", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("c2d5e6"))
		draw_string(font, Vector2(32, 608), "Same-due-tick death / swap / teardown: sources unchanged. Empty magazine shell + child retained.", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("c2d5e6"))
		draw_string(font, Vector2(32, 636), "External completion quarantined: 38 inventory - 27 held + 30 loaded = 41 spendable total; refund blocked.", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("f1c885"))
		draw_string(font, Vector2(32, 680), status_text + "  |  Scope: in-memory single writer. Crash/restart and detachable-magazine identity excluded.", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("91e6b8"))


var checks: int = 0
var failures: int = 0
var assertions: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var details: Dictionary = {}
var native: bool = false
var board: TimelineBoard


func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical 1280x720 QA flow is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return


func verify(condition: bool, message: String) -> void:
	checks += 1
	assertions.append({"check": checks, "label": message, "passed": condition})
	if not condition:
		failures += 1
		push_error("ASTRA_FLOW: " + message)


func run() -> void:
	native = DisplayServer.get_name() != "headless"
	if native:
		root.title = "Astra 4.9 — VALIDATION HARNESS / NOT PRODUCTION UI"
		root.mode = Window.MODE_WINDOWED
		root.content_scale_size = Vector2i(1280, 720)
		root.size = Vector2i(1280, 720)
		board = TimelineBoard.new()
		board.size = Vector2(1280, 720)
		root.add_child(board)
		await process_frame
	verify(ClassDB.class_has_method(&"WeaponAuthority", &"commit_due_reload"), "native Weapon facade has due commit")
	verify(not ClassDB.class_has_method(&"WeaponAuthority", &"rollback_reload_completion"), "native facade exposes no symmetric reload rollback")
	await continuous_flow()
	for kind in [&"death", &"weapon_swap", &"teardown"]:
		interruption_flow(kind)
	quarantine_flow()
	var native_metadata: Dictionary = {"display_server": DisplayServer.get_name(), "native": native,
		"engine": Engine.get_version_info(), "renderer": RenderingServer.get_current_rendering_method(),
		"window_size": {"x": root.size.x, "y": root.size.y}}
	if native:
		verify(DisplayServer.get_name() == "macOS" and root.visible, "actual native macOS window is visible")
		verify(RenderingServer.get_current_rendering_method() == "gl_compatibility", "native flow uses Compatibility renderer")
		verify(root.size == Vector2i(1280, 720), "native window is 1280x720")
		board.status_text = "PASS" if failures == 0 else "FAIL"
		board.queue_redraw()
		await process_frame
		await RenderingServer.frame_post_draw
		var capture: Image = root.get_texture().get_image()
		verify(capture.get_size() == Vector2i(1280, 720), "native framebuffer capture is 1280x720")
		verify(capture.save_png(OUT + "native_timeline_1280x720.png") == OK, "native framebuffer screenshot saved")
		await create_timer(1.0).timeout
		board.free()
		board = null
		await process_frame
	var result: Dictionary = {"checks": checks, "failures": failures, "human_approval": false,
		"canonical_catalog": true, "real_addons": true, "same_flow_repeated_in_native": native,
		"unique_flow_cases": 5, "main_timeline_states": 8,
		"crash_restart_atomic": false, "physical_detachable_magazine_identity": false,
		"native_metadata": native_metadata, "timeline": timeline, "details": details, "assertions": assertions}
	var file: FileAccess = FileAccess.open(OUT + ("native_results.json" if native else "flow_results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t") + "\n")
	file.close()
	print("ASTRA_FLOW_RESULT checks=", checks, " failures=", failures, " native=", native)
	quit(0 if failures == 0 else 1)


func continuous_flow() -> void:
	var f: Dictionary = fixture("continuous")
	var a: InventoryWeaponAdapter = f["adapter"]
	var inv: InventoryAuthority = f["inventory_authority"]
	var w: WeaponAuthority = f["weapon"]
	inv.quantity_reservation_published.connect(_inventory_publication.bind(f))
	w.reload_completed.connect(_weapon_publication.bind(f))
	w.reload_cancelled.connect(_cancel_publication.bind(f))
	var original_bytes: PackedByteArray = inv.make_persistence_record(int(f["inventory"]))
	await record_state(f, "Initial equipped AKM", 0, INITIAL_SOURCES, 3, 0, 5, 0)
	var first_intent: Dictionary = begin_intent(f, "first", 17)
	var first: Dictionary = a.begin_reload(first_intent)
	verify(bool(first.get("accepted", false)) and String(first.get("kind", "")) == "reload_started", "continuous first reserve succeeds")
	var first_reservation: String = String(first.get("reservation_id", ""))
	var due: int = int(first.get("due_tick", -1))
	verify(due == 89, "first deadline is exact authored seventy-two tick interval")
	exact_reservation(f, first_reservation, 1)
	await record_state(f, "Reserve / begin", 17, INITIAL_SOURCES, 3, 1, 5, 1)
	var before_hold_mutation: Dictionary = canonical_state(f)
	var rejected: Dictionary = inv.remove_item(int(f["inventory"]), int(f["source_ids"][0]), 8842, next_command(f))
	verify(not bool(rejected.get("accepted", true)), "native removal of magazine-contained held stack rejects")
	verify(canonical_state(f) == before_hold_mutation, "held-stack rejection preserves exact source state and both revisions")
	verify(a.advance_due_reloads(due - 1).is_empty(), "pre-due sweep cannot complete")
	await record_state(f, "Before due", due - 1, INITIAL_SOURCES, 3, 1, 5, 1)
	var cancel_intent: Dictionary = cancellation_intent(f, "first", due)
	var cancelled: Dictionary = a.cancel_reload(cancel_intent)
	verify(bool(cancelled.get("accepted", false)) and String(cancelled.get("kind", "")) == "reload_cancelled", "cancellation ordered before commit at exact due tick succeeds")
	verify(a.advance_due_reloads(due).is_empty(), "same tick sweep after cancellation cannot resurrect reload")
	verify(inv.make_persistence_record(int(f["inventory"])) == original_bytes, "due-tick cancellation preserves exact inventory persistence bytes")
	verify(int(inv.health_quantity_reservation(first_reservation).get("stage", -1)) == 3, "first reservation is native RELEASED")
	verify(f["cancel_saw_hold"] == [true], "cancel notification runs before inventory releases the hold")
	verify(int(f["completion_count"]) == 0 and (f["order"] as Array).is_empty(), "cancel produces no completion publication")
	await record_state(f, "Cancel ordered at due", due, INITIAL_SOURCES, 3, 0, 5, 2)
	var cancelled_replay: Dictionary = a.cancel_reload(cancel_intent)
	verify(bool(cancelled_replay.get("replayed", false)) and bool(cancelled_replay.get("accepted", false)), "cancel request replays terminal receipt")
	var second_intent: Dictionary = begin_intent(f, "second", due + 1)
	var second: Dictionary = a.begin_reload(second_intent)
	verify(bool(second.get("accepted", false)), "second reservation starts after cancellation")
	var second_reservation: String = String(second.get("reservation_id", ""))
	verify(second_reservation != first_reservation, "fresh request has a distinct exact reservation identity")
	exact_reservation(f, second_reservation, 2)
	f["committing_reservation"] = second_reservation
	await record_state(f, "Reserve again", due + 1, INITIAL_SOURCES, 3, 1, 5, 3)
	var unrelated: Dictionary = insert(f, ZerkovInventoryCatalog.ITEM_BANDAGE, 1, spatial(int(f["pockets"]), 3, 1))
	verify(bool(unrelated.get("accepted", false)), "unrelated bandage insert accepted while all ammo holds remain")
	exact_reservation(f, second_reservation, 2)
	await record_state(f, "Unrelated accepted revision", due + 2, INITIAL_SOURCES, 3, 1, 6, 3)
	var second_due: int = int(second.get("due_tick", -1))
	verify(second_due == 162, "second exact native deadline follows continuous clock")
	var completion: Array[Dictionary] = a.advance_due_reloads(second_due)
	verify(completion.size() == 1 and bool(completion[0].get("accepted", false))
		and String(completion[0].get("kind", "")) == "reload_committed", "due sweep commits exactly one coherent transaction")
	verify(f["order"] == ["inventory", "weapon"], "inventory notification precedes weapon completion notification")
	verify(int(f["completion_count"]) == 1, "recursive publication produces one completion signal")
	var recursive: Dictionary = f["recursive_result"]
	verify(bool(recursive.get("accepted", false)) and bool(recursive.get("replayed", false))
		and String(recursive.get("stage", "")) == "published", "recursive port publication only replays terminal state")
	verify(int(inv.health_quantity_reservation(second_reservation).get("stage", -1)) == 4, "committed reservation is native PUBLISHED")
	verify(a.pending_reloads().is_empty() and inv.active_quantity_reservation_count() == 0, "commit leaves no pending reload or native hold")
	verify(quantity(f, int(f["shell"])) == 1 and container_id(f, ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM,
		int(f["shell"])) == int(f["magazine_container"]), "drained magazine shell and exact child identity remain")
	verify(container_members(f, int(f["magazine_container"])).is_empty(), "drained magazine child is an empty canonical list")
	await record_state(f, "Due commit", second_due, [0, 0, 11], 30, 0, 7, 4)
	var before_replay: Dictionary = canonical_state(f)
	var replay: Dictionary = a.begin_reload(second_intent)
	verify(bool(replay.get("accepted", false)) and bool(replay.get("replayed", false)), "completed original begin request replays")
	verify(a.advance_due_reloads(second_due + 1).is_empty()
		and a.advance_due_reloads(second_due + 4000).is_empty(), "late sweeps including reservation TTL horizon do nothing")
	verify(canonical_state(f) == before_replay, "replay and late sweeps preserve both canonical states byte for byte")
	verify(int(f["completion_count"]) == 1, "late sweeps and request replay never publish another completion")
	await record_state(f, "Replay / late sweep", second_due + 4000, [0, 0, 11], 30, 0, 7, 4)
	details["continuous"] = {"source_ids": f["source_ids"], "shell": f["shell"],
		"child_container": f["magazine_container"], "first_reservation": first_reservation,
		"second_reservation": second_reservation, "notification_order": f["order"],
		"completion_count": f["completion_count"], "publication_observations": f["publication_observations"],
		"recursive_publication": recursive, "final_commit": completion}
	dispose(f, second_due + 4001)


func _inventory_publication(result: Dictionary, f: Dictionary) -> void:
	(f["order"] as Array).append("inventory")
	var observed: Dictionary = observe(f)
	(f["publication_observations"] as Array).append({"domain": "inventory", "state": observed})
	verify(observed["sources"] == [0, 0, 11] and int(observed["loaded"]) == 30
		and int(observed["total"]) == TOTAL and int(observed["holds"]) == 0,
		"inventory callback sees exact committed source quantities and thirty loaded coherently")
	verify(int(result.get("quantity", 0)) == 27 and int(result.get("predecessor_revision", -1)) == 6
		and int(result.get("successor_revision", -1)) == 7, "inventory publication carries immediate predecessor revision after unrelated mutation")
	var a: InventoryWeaponAdapter = f["adapter"]
	var reentry: Dictionary = a.begin_reload(begin_intent(f, "during_publish", 162))
	verify(String(reentry.get("reason", "")) == "reload_transaction_active", "publication callback cannot reenter the transaction")


func _weapon_publication(result: Dictionary, f: Dictionary) -> void:
	(f["order"] as Array).append("weapon")
	f["completion_count"] = int(f["completion_count"]) + 1
	(f["publication_observations"] as Array).append({"domain": "weapon", "state": observe(f)})
	verify(observe(f)["sources"] == [0, 0, 11] and int(observe(f)["loaded"]) == 30,
		"weapon callback sees coherent inventory and loaded state")
	# Guard makes a faulty publisher fail with a duplicate count instead of stack overflow.
	if int(f["completion_count"]) == 1:
		var port: WeaponAuthorityReloadPort = f["port"]
		f["recursive_result"] = port.publish_reload(String(result.get("reservation_id", "")))


func _cancel_publication(result: Dictionary, f: Dictionary) -> void:
	var inv: InventoryAuthority = f["inventory_authority"]
	var health: Dictionary = inv.health_quantity_reservation(String(result.get("reservation_to_release", "")))
	(f["cancel_saw_hold"] as Array).append(int(health.get("stage", -1)) == 1 and sources(f) == INITIAL_SOURCES)


func interruption_flow(kind: StringName) -> void:
	var f: Dictionary = fixture(String(kind))
	var a: InventoryWeaponAdapter = f["adapter"]
	var inv: InventoryAuthority = f["inventory_authority"]
	var w: WeaponAuthority = f["weapon"]
	var before: Dictionary = canonical_state(f)
	var begun: Dictionary = a.begin_reload(begin_intent(f, String(kind), 23))
	verify(bool(begun.get("accepted", false)), String(kind) + " fixture reserves real magazine ammunition")
	var due: int = int(begun.get("due_tick", -1))
	verify(due == 95, String(kind) + " fixture uses exact due tick")
	exact_reservation(f, String(begun.get("reservation_id", "")), 1)
	if kind == &"weapon_swap":
		var moved: Dictionary = inv.move_item(int(f["inventory"]), int(f["akm"]),
			spatial(int(f["backpack"]), 2, 3), 8842, next_command(f))
		verify(bool(moved.get("accepted", false)), "same-due-tick swap actually moves equipped native AKM")
		var outcomes: Array[Dictionary] = a.advance_due_reloads(due)
		verify(outcomes.size() == 1 and String(outcomes[0].get("kind", "")) == "reload_cancelled", "same-due-tick equipment validation cancels before due work")
	elif kind == &"teardown":
		verify(a.release_binding(&"teardown", due), "same-due-tick explicit adapter teardown cancels")
	else:
		var stopped: Dictionary = a.interrupt_reload(String(f["weapon_id"]), &"death", due)
		verify(bool(stopped.get("accepted", false)), "same-due-tick death interruption cancels")
		verify(a.advance_due_reloads(due).is_empty(), "same-due-tick death leaves no due completion")
	var after: Dictionary = observe(f)
	verify(sources(f) == INITIAL_SOURCES and int(after["loaded"]) == INITIAL_LOADED
		and int(after["total"]) == TOTAL, String(kind) + " preserves every source quantity and ammunition conservation")
	verify(inv.active_quantity_reservation_count() == 0 and a.pending_reloads().is_empty(), String(kind) + " leaves no hold or pending transaction")
	verify(String(w.snapshot(String(f["weapon_id"])).get("phase", "")) == "ready", String(kind) + " leaves native weapon ready")
	verify(int(inv.health_quantity_reservation(String(begun["reservation_id"])).get("stage", -1)) == 3, String(kind) + " releases native reservation")
	if kind != &"weapon_swap":
		verify(inv.make_persistence_record(int(f["inventory"])) == before["inventory_bytes"], String(kind) + " retains exact inventory persistence bytes")
	verify(w.due_reloads(due + 100).is_empty(), String(kind) + " cannot mechanically complete later")
	details[String(kind)] = {"due_tick": due, "state": after, "reservation_id": begun["reservation_id"]}
	dispose(f, due + 101)


func quarantine_flow() -> void:
	var f: Dictionary = fixture("quarantine")
	var a: InventoryWeaponAdapter = f["adapter"]
	var inv: InventoryAuthority = f["inventory_authority"]
	var w: WeaponAuthority = f["weapon"]
	var begun: Dictionary = a.begin_reload(begin_intent(f, "quarantine", 31))
	verify(bool(begun.get("accepted", false)), "quarantine fixture starts one real exact reservation")
	var reservation: String = String(begun.get("reservation_id", ""))
	var due: int = int(begun.get("due_tick", -1))
	exact_reservation(f, reservation, 1)
	# Deliberate out-of-band authority call is confined to this QA harness.
	var direct: Array = w.advance_tick(due)
	verify(direct.size() == 1 and int(w.snapshot(String(f["weapon_id"])).get("loaded_rounds", 0)) == 30,
		"external native completion deliberately violates the single-writer contract")
	var quarantined: Array[Dictionary] = a.advance_due_reloads(due)
	verify(quarantined.size() == 1 and String(quarantined[0].get("reason", "")) == "weapon_completed_outside_reload_transaction"
		and a.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED, "out-of-band completion latches explicit fail-stop quarantine")
	var health: Dictionary = inv.health_quantity_reservation(reservation)
	var after: Dictionary = observe(f)
	verify(sources(f) == INITIAL_SOURCES and int(health.get("stage", -1)) == 1
		and int(health.get("quantity", -1)) == 27 and inv.active_quantity_reservation_count() == 1,
		"quarantine retains exact source quantities and twenty-seven held rounds")
	verify(int(after["inventory_rounds"]) - int(health["quantity"]) + int(after["loaded"]) == TOTAL,
		"quarantine spendable ammunition conserves 38 minus 27 held plus 30 loaded equals 41")
	verify(a.pending_reloads().size() == 1 and String(a.pending_reloads()[0].get("reservation_id", "")) == reservation
		and String(a.pending_reloads()[0].get("stage", "")) == "recovery_required", "quarantine retains exact transaction identity and recovery record")
	verify(String(a.interrupt_reload(String(f["weapon_id"]), &"death", due + 1).get("reason", "")) == "reload_recovery_required", "death cannot refund quarantined ammo")
	verify(String(a.begin_reload(begin_intent(f, "replacement_forbidden", due + 1)).get("reason", "")) == "reload_recovery_required", "new reload cannot bypass quarantine")
	verify(not a.release_binding(&"teardown", due + 1), "ordinary release cannot clear quarantine hold")
	verify(inv.active_quantity_reservation_count() == 1 and sources(f) == INITIAL_SOURCES,
		"failed recovery operations preserve the quarantined hold and sources")
	details["quarantine"] = {"tick": due, "state": after, "health": health,
		"spendable_total": int(after["inventory_rounds"]) - 27 + int(after["loaded"]),
		"recovery": a.recovery_details(), "limitation": "fail-stop accounting, not production recovery or restart"}
	dispose(f, due + 2)


func fixture(label: String) -> Dictionary:
	var session: SessionCoordinator = SessionCoordinator.new(OfflineSessionIngress.new())
	var admission: ZSessionAdmission = session.open_offline(ZRaidId.from_parts(PackedStringArray(["astrafinal", label])), &"validation_profile", &"player")
	verify(admission != null and admission.is_usable(), label + " trusted session admission is usable")
	var owner: RaidInventoryOwner = RaidInventoryOwner.new()
	root.add_child(owner)
	verify(owner.configure(), label + " real inventory owner seals canonical catalog and starts")
	var f: Dictionary = {"label": label, "owner": owner, "admission": admission,
		"inventory_authority": owner.raid_authority(), "inventory": owner.raid_player_inventory_id,
		"command": 93000, "order": [], "completion_count": 0, "publication_observations": [],
		"recursive_result": {}, "cancel_saw_hold": []}
	f["backpack"] = container_id(f, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	f["rig"] = container_id(f, ZerkovInventoryCatalog.CONTAINER_RIG)
	f["pockets"] = container_id(f, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	var equipment: int = container_id(f, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var akm: Dictionary = insert(f, ZerkovInventoryCatalog.ITEM_AKM, 1,
		{"kind": "slot", "container": equipment, "slot_identifier": String(EquippedItemReconciler.SLOT_PRIMARY)})
	f["akm"] = int(akm.get("new_item_id", 0))
	verify(bool(akm.get("accepted", false)) and int(f["akm"]) > 0, label + " canonical AKM is equipped")
	var shell_result: Dictionary = insert(f, ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM, 1, spatial(int(f["backpack"]), 0, 0))
	f["shell"] = int(shell_result.get("new_item_id", 0))
	f["magazine_container"] = container_id(f, ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM, int(f["shell"]))
	verify(bool(shell_result.get("accepted", false)) and int(f["magazine_container"]) > 0,
		label + " real magazine provider materializes its canonical child list")
	var magazine_ammo: Dictionary = insert(f, ZerkovInventoryCatalog.ITEM_AMMO_762, 11,
		{"kind": "list", "container": int(f["magazine_container"]), "ordinal": 0})
	var rig_ammo: Dictionary = insert(f, ZerkovInventoryCatalog.ITEM_AMMO_762, 8, spatial(int(f["rig"]), 3, 0))
	var pocket_ammo: Dictionary = insert(f, ZerkovInventoryCatalog.ITEM_AMMO_762, 19, spatial(int(f["pockets"]), 1, 0))
	f["source_ids"] = [int(magazine_ammo.get("new_item_id", 0)), int(rig_ammo.get("new_item_id", 0)), int(pocket_ammo.get("new_item_id", 0))]
	verify(bool(magazine_ammo.get("accepted", false)) and bool(rig_ammo.get("accepted", false))
		and bool(pocket_ammo.get("accepted", false)), label + " real magazine, rig and pocket stacks insert")
	var identities: Dictionary = EquippedItemReconciler.derive_identity_keys(admission, owner.generation(),
		int(f["inventory"]), int(f["akm"]), ZerkovInventoryCatalog.ITEM_AKM)
	var mapping: Dictionary = {"slot_identifier": EquippedItemReconciler.SLOT_PRIMARY,
		"native_inventory_id": int(f["inventory"]), "native_item_id": int(f["akm"]),
		"item_definition_identifier": ZerkovInventoryCatalog.ITEM_AKM,
		"combat_definition_identifier": ZerkovCombatContent.WEAPON_AKM,
		"weapon_kind": EquippedItemReconciler.WEAPON_KIND_FIREARM,
		"weapon_id": identities.get("weapon_id", ""), "entity_id": identities.get("entity_id", "")}
	f["weapon_id"] = String(mapping["weapon_id"])
	var weapon: WeaponAuthority = WeaponAuthority.new()
	root.add_child(weapon)
	f["weapon"] = weapon
	verify(bool(ZerkovCombatContent.configure_authority(weapon).get("ok", false)), label + " real WeaponAuthority configures sealed content")
	verify(bool(weapon.create_weapon(String(f["weapon_id"]), String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION, INITIAL_LOADED,
		{"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD), "version": 1},
		admission.raid_id.canonical_key(), admission.authority_epoch).get("ok", false)), label + " real AKM starts with three loaded rounds")
	var port: WeaponAuthorityReloadPort = WeaponAuthorityReloadPort.new()
	f["port"] = port
	verify(port.configure(weapon), label + " actual WeaponAuthorityReloadPort configures")
	verify(port.commit_capability() == WeaponReloadParticipantPort.CommitCapability.FACADE_SINGLE_WRITER,
		label + " actual port reports its limited single-writer capability")
	var adapter: InventoryWeaponAdapter = InventoryWeaponAdapter.new()
	root.add_child(adapter)
	f["adapter"] = adapter
	verify(adapter.bind_owner(owner, admission, port, owner.generation())
		and bool(adapter.register_weapon(mapping, 7).get("accepted", false)), label + " actual adapter binds exact equipped identity")
	verify(sources(f) == INITIAL_SOURCES and int(observe(f)["total"]) == TOTAL, label + " initial exact quantities conserve forty-one rounds")
	return f


func exact_reservation(f: Dictionary, reservation: String, generation: int) -> void:
	var a: InventoryWeaponAdapter = f["adapter"]
	var inv: InventoryAuthority = f["inventory_authority"]
	var pending: Array[Dictionary] = a.pending_reloads()
	verify(pending.size() == 1 and String(pending[0].get("reservation_id", "")) == reservation
		and int(pending[0].get("quantity", -1)) == 27, String(f["label"]) + " pending reservation identity and total are exact")
	var health: Dictionary = inv.health_quantity_reservation(reservation)
	var expected: Array = []
	for i in 3:
		expected.append({"item": int(f["source_ids"][i]), "quantity": [11, 8, 8][i], "generation": generation})
	verify(health.get("lines", []) == expected and pending[0].get("reservation_lines", []) == expected,
		String(f["label"]) + " magazine then rig then pockets exact native item IDs, quantities and hold generations")
	verify(int(health.get("stage", -1)) == 1 and int(health.get("inventory_id", 0)) == int(f["inventory"]),
		String(f["label"]) + " exact native reservation is HELD in the bound inventory")
	verify(sources(f) == INITIAL_SOURCES and int(observe(f)["total"]) == TOTAL,
		String(f["label"]) + " every reservation preserves physical ammunition conservation")


func record_state(f: Dictionary, label: String, tick: int, expected_sources: Array,
	loaded: int, holds: int, inventory_revision: int, weapon_revision: int) -> void:
	var state: Dictionary = observe(f)
	verify(state["sources"] == expected_sources, label + " exact magazine/rig/pocket quantities")
	verify(int(state["loaded"]) == loaded, label + " exact loaded rounds")
	verify(int(state["holds"]) == holds, label + " exact hold count")
	verify(int(state["inventory_revision"]) == inventory_revision and int(state["weapon_revision"]) == weapon_revision,
		label + " exact inventory and weapon revisions")
	verify(int(state["total"]) == TOTAL, label + " ammunition conservation")
	var row: Dictionary = {"label": label, "tick": tick, "magazine": state["sources"][0],
		"rig": state["sources"][1], "pockets": state["sources"][2], "loaded": loaded,
		"holds": holds, "held_quantity": 27 if holds == 1 else 0,
		"inventory_revision": state["inventory_revision"], "weapon_revision": state["weapon_revision"], "total": state["total"]}
	timeline.append(row)
	if native:
		board.rows = timeline
		board.queue_redraw()
		await create_timer(0.1).timeout


func observe(f: Dictionary) -> Dictionary:
	var inv: InventoryAuthority = f["inventory_authority"]
	var w: WeaponAuthority = f["weapon"]
	var ws: Dictionary = w.snapshot(String(f["weapon_id"]))
	var ammo: int = 0
	for item in inv.snapshot(int(f["inventory"])).get_items():
		if StringName(item.get("item_definition_identifier", "")) == ZerkovInventoryCatalog.ITEM_AMMO_762:
			ammo += int(item.get("quantity", 0))
	return {"sources": sources(f), "inventory_rounds": ammo, "loaded": int(ws.get("loaded_rounds", -1)),
		"total": ammo + int(ws.get("loaded_rounds", -1)), "holds": inv.active_quantity_reservation_count(),
		"inventory_revision": inv.inventory_revision(int(f["inventory"])), "weapon_revision": int(ws.get("revision", -1))}


func canonical_state(f: Dictionary) -> Dictionary:
	var inv: InventoryAuthority = f["inventory_authority"]
	var w: WeaponAuthority = f["weapon"]
	var snapshot: InventorySnapshotResource = inv.snapshot(int(f["inventory"]))
	return {"inventory_bytes": inv.make_persistence_record(int(f["inventory"])),
		"items": snapshot.get_items(), "containers": snapshot.get_containers(),
		"weapon": w.snapshot(String(f["weapon_id"])), "inventory_revision": snapshot.get_revision()}


func sources(f: Dictionary) -> Array[int]:
	var result: Array[int] = []
	for id in f["source_ids"]:
		result.append(quantity(f, int(id)))
	return result


func quantity(f: Dictionary, id: int) -> int:
	var inv: InventoryAuthority = f["inventory_authority"]
	for item in inv.snapshot(int(f["inventory"])).get_items():
		if int(item.get("id", 0)) == id:
			return int(item.get("quantity", 0))
	return 0


func container_id(f: Dictionary, definition: StringName, provider: int = 0) -> int:
	var inv: InventoryAuthority = f["inventory_authority"]
	for container in inv.snapshot(int(f["inventory"])).get_containers():
		if int(container.get("provider_item", 0)) == provider \
			and StringName(container.get("container_definition_identifier", "")) == definition:
			return int(container.get("id", 0))
	return 0


func container_members(f: Dictionary, id: int) -> Array:
	var inv: InventoryAuthority = f["inventory_authority"]
	var result: Array = []
	for item in inv.snapshot(int(f["inventory"])).get_items():
		if int((item.get("location", {}) as Dictionary).get("container", 0)) == id:
			result.append(item)
	return result


func next_command(f: Dictionary) -> int:
	f["command"] = int(f["command"]) + 1
	return int(f["command"])


func insert(f: Dictionary, definition: StringName, count: int, location: Dictionary) -> Dictionary:
	var inv: InventoryAuthority = f["inventory_authority"]
	return inv.insert_item(int(f["inventory"]), String(definition), count, location, 8842, next_command(f))


func spatial(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": y, "rotated": false}


func begin_intent(f: Dictionary, label: String, tick: int) -> Dictionary:
	var a: InventoryWeaponAdapter = f["adapter"]
	var admission: ZSessionAdmission = f["admission"]
	var state: Dictionary = observe(f)
	return {"request_id": ZRequestId.from_parts(PackedStringArray(["astrafinal", label])).canonical_key(),
		"weapon_id": String(f["weapon_id"]), "weapon_binding_generation": 7,
		"adapter_generation": a.adapter_generation(), "authority_epoch": admission.authority_epoch,
		"inventory_id": int(f["inventory"]), "expected_inventory_revision": int(state["inventory_revision"]),
		"expected_weapon_revision": int(state["weapon_revision"]), "tick": tick}


func cancellation_intent(f: Dictionary, label: String, tick: int) -> Dictionary:
	var result: Dictionary = begin_intent(f, "cancel_" + label, tick)
	result.erase("expected_inventory_revision")
	result["reason"] = &"user_cancel"
	return result


func dispose(f: Dictionary, tick: int) -> void:
	var a: InventoryWeaponAdapter = f["adapter"]
	var owner: RaidInventoryOwner = f["owner"]
	var inv: InventoryAuthority = f["inventory_authority"]
	var w: WeaponAuthority = f["weapon"]
	var port: WeaponAuthorityReloadPort = f["port"]
	if a.lifecycle == InventoryWeaponAdapter.Lifecycle.BOUND:
		verify(a.release_binding(&"teardown", tick), String(f["label"]) + " adapter releases before owner teardown")
	verify(owner.teardown(owner.generation()), String(f["label"]) + " explicit owner teardown succeeds")
	verify(inv.active_quantity_reservation_count() == 0, String(f["label"]) + " owner teardown leaves zero native holds")
	a.free()
	port.clear()
	w.free()
	owner.free()
	f.clear()
