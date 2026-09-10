extends SceneTree
## Independently authored SceneTree fixture. No promoted contract is loaded,
## subclassed, invoked, or used as a source of observations/assertions.
## The only tick driver is RaidAuthority.advance_one(). Every item mutation
## runs in its registered INTERACTIONS_AND_WEAPONS handler (phase 5).

const OUT := "res://docs/qa/inventory_ability_equipment/astra_final/"
const C = preload("res://game/content/zerkov_equipment_ability_content.gd")
const I = preload("res://game/content/zerkov_inventory_catalog.gd")


class Identity extends ZInventoryIdentityPort:
	var admission: ZSessionAdmission
	var inventory: int

	func native_actor_id(session: ZSessionId, actor: ZEntityId, epoch: int, generation: int) -> int:
		if session != null and actor != null and admission != null \
				and session.is_equal(admission.session_id) and actor.is_equal(admission.actor_id) \
				and epoch == admission.authority_epoch and generation == admission.generation:
			return RaidInventoryOwner.FIXTURE_ACTOR_ID
		return 0

	func actor_owns_inventory(session: ZSessionId, actor: ZEntityId, target: int, epoch: int, generation: int) -> bool:
		return target == inventory and native_actor_id(session, actor, epoch, generation) > 0


class RefusingRevokePort extends GameplayAbilityEquipmentPort:
	## The only fault is an explicitly rejected revoke. Configuration, grants,
	## liveness/cleanup proofs and quarantine remain the real production port.
	var refuse_revoke := false
	var rejected_revoke_calls := 0
	var quarantine_calls := 0

	func revoke(record: Dictionary, tick: int) -> Dictionary:
		if refuse_revoke:
			rejected_revoke_calls += 1
			return {"accepted": false, "reason": &"astra_injected_revoke_refusal",
				"mutation_state": MUTATION_AMBIGUOUS, "recovery_records": [record.duplicate(true)]}
		return super.revoke(record, tick)

	func quarantine(records: Array[Dictionary], tick: int) -> Dictionary:
		quarantine_calls += 1
		return super.quarantine(records, tick)


class Board extends Control:
	var rows: Array[Dictionary] = []
	var page := "Starting"
	var note := ""
	var result := "RUNNING"

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		draw_rect(Rect2(0, 0, 1280, 720), Color("111923"))
		draw_string(font, Vector2(28, 40), "AUTOMATED VALIDATION HARNESS / NOT PRODUCTION UI", HORIZONTAL_ALIGNMENT_LEFT, -1, 23, Color("b5dfff"))
		draw_string(font, Vector2(28, 76), "Task 4.10  |  " + page, HORIZONTAL_ALIGNMENT_LEFT, -1, 21, Color("eef4fa"))
		draw_string(font, Vector2(28, 108), "Real InventoryAuthority + GameplayAbilityComponent  /  native macOS Compatibility 1280 x 720", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("9cb2c6"))
		var xs := [32, 393, 455, 603, 700, 793, 902, 1020, 1137]
		var heads := ["ORDERED STATE", "TICK", "INV / APPLIED", "SOURCES", "LIVE", "REVOKED", "TERM HIST", "EFFECTS", "READY"]
		draw_rect(Rect2(24, 133, 1230, 36), Color("284154"))
		for i in heads.size():
			draw_string(font, Vector2(xs[i], 157), heads[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("dbe9f5"))
		for index in rows.size():
			var row := rows[index]
			var y := 171 + index * 33
			draw_rect(Rect2(24, y, 1230, 32), Color("1c2d3c") if index % 2 == 0 else Color("182735"))
			var cells := [String(row["label"]), str(row["tick"]), str(row["revision"]) + " / " + str(row["applied"]),
				str(row["sources"]), str(row["live"]), str(row["revoked"]), str(row["terminal_history"]),
				str(row["effects"]), str(row["ready"])]
			for i in cells.size():
				draw_string(font, Vector2(xs[i], y + 23), cells[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 17,
					Color("99e7bd") if i == 4 or i == 8 else Color("edf3f9"))
		draw_string(font, Vector2(28, 577), note, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("f2ce91"))
		draw_string(font, Vector2(28, 610), "Phase 5: inventory commits. Phase 7: native grants/revokes complete, then adapter publishes.", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("c8d8e6"))
		draw_string(font, Vector2(28, 639), "LIVE requires active execution. REVOKED and TERM HIST are retained historical rows, never live grants.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("c8d8e6"))
		draw_string(font, Vector2(28, 683), result + "  |  Automated fixture only. Human playtest approval: FALSE.  |  Offline in-memory scope.", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("99e7bd"))


var checks := 0
var failures := 0
var assertions: Array[Dictionary] = []
var events: Array[Dictionary] = []
var observations: Array[Dictionary] = []
var flow_details: Dictionary = {}
var fixtures: Dictionary = {}
var command_id := 910_000
var native := false
var board: Board
var captures: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func verify(ok: bool, label: String) -> void:
	checks += 1
	assertions.append({"check": checks, "label": label, "passed": ok})
	if not ok:
		failures += 1
		push_error("ASTRA_ABILITY_FLOW: " + label)


func run() -> void:
	native = DisplayServer.get_name() != "headless"
	if native:
		root.title = "Astra 4.10 — AUTOMATED VALIDATION HARNESS / NOT PRODUCTION UI"
		root.mode = Window.MODE_WINDOWED
		root.content_scale_size = Vector2i(1280, 720)
		root.size = Vector2i(1280, 720)
		board = Board.new()
		board.size = Vector2(1280, 720)
		root.add_child(board)
		await process_frame
	await continuous_flow()
	await recovery_flow()
	await teardown_flows()
	await terminal_first_constraint()
	verify(fixtures.is_empty(), "all six independent fixtures release their references")
	var metadata := {"engine": Engine.get_version_info(), "display_server": DisplayServer.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "native": native,
		"window_id": root.get_window_id(), "visible": root.visible,
		"window_size": [root.size.x, root.size.y], "window_position": [root.position.x, root.position.y],
		"executable": OS.get_executable_path(), "process_id": OS.get_process_id(),
		"capture_method": "four settle frames, force_draw(true), viewport framebuffer",
		"human_approval": false}
	if native:
		verify(DisplayServer.get_name() == "macOS" and root.visible, "real macOS native window is visible")
		verify(RenderingServer.get_current_rendering_method() == "gl_compatibility", "actual native rendering method is Compatibility")
		verify(root.size == Vector2i(1280, 720), "actual native window size is 1280x720")
		verify(captures.size() == 4, "four ordinary/isolation/recovery/teardown native frames are saved")
		board.free()
		board = null
	await process_frame
	await process_frame
	var result := {"checks": checks, "failures": failures, "human_approval": false,
		"independent": true, "promoted_contract_loaded": false,
		"real_inventory": true, "real_gameplay_abilities": true,
		"only_tick_driver": "RaidAuthority.advance_one", "inventory_mutation_phase": 5,
		"native_equipment_phase": 7, "fixture_count": 6, "metadata": metadata,
		"captures": captures, "observations": observations, "events": events,
		"details": flow_details, "assertions": assertions}
	var file := FileAccess.open(OUT + ("native_results.json" if native else "flow_results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t") + "\n")
	file.close()
	print("ASTRA_ABILITY_FLOW_RESULT checks=", checks, " failures=", failures, " native=", native)
	quit(0 if failures == 0 else 1)


func fixture(label: String, failing := false) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["astrafinal410", label]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(raid_id, &"qa_profile", &"player")
	verify(admission != null and admission.is_usable(), label + " trusted offline admission")
	var owner := RaidInventoryOwner.new()
	owner.name = "AstraInventory_" + label
	root.add_child(owner)
	verify(owner.configure(), label + " real inventory owner configures sealed canonical content")
	var raid := RaidAuthority.new()
	verify(raid.configure(raid_id, admission, 410_026), label + " real raid authority configures")
	var component := GameplayAbilityComponent.new()
	component.name = "AstraAbilities_" + label
	component.entity_id = RaidInventoryOwner.FIXTURE_ACTOR_ID
	component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	component.definition_catalog = C.build_definition_catalog()
	root.add_child(component)
	verify(GameplayDefinitionValidator.is_ok(component.configure()) and component.is_configured(), label + " native ability component configures")
	verify(bool(C.initialize_component(component).get("accepted", false)), label + " readied-count base initializes to zero")
	var port: GameplayAbilityEquipmentPort = RefusingRevokePort.new() if failing else GameplayAbilityEquipmentPort.new()
	verify(port.configure(component), label + " production participant captures exact native identity")
	var identity := Identity.new()
	identity.admission = admission
	identity.inventory = owner.raid_player_inventory_id
	var adapter := InventoryAbilityAdapter.new()
	var key := raid.get_instance_id()
	var f := {"key": key, "label": label, "owner": owner, "raid": raid, "component": component,
		"port": port, "identity": identity, "adapter": adapter, "admission": admission,
		"inventory": owner.raid_player_inventory_id, "native_inventory": owner.raid_authority(),
		"items": {}, "commands": [], "results": [], "external_action": "", "external_spec": 0,
		"in_tick": false, "publication_count": 0, "recovery_count": 0, "cached_revision": 0,
		"clean_publications": [], "last_component_state": {}, "last_command": 0}
	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	for definition in [I.CONTAINER_EQUIPMENT, I.CONTAINER_BACKPACK, I.CONTAINER_RIG, I.CONTAINER_POCKETS]:
		f[String(definition)] = root_container(snapshot, definition)
		verify(int(f[String(definition)]) > 0, label + " required root container " + String(definition))
	fixtures[key] = f
	verify(raid.register_phase_handler(RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"astra_inventory_mutator", Callable(self, "phase_five"), raid.generation()), label + " phase-5 mutator registers")
	verify(raid.register_phase_handler(RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
		&"aa_astra_external", Callable(self, "phase_seven_external"), raid.generation()), label + " controlled external phase-7 source registers")
	verify(adapter.bind_owner(owner, admission, identity, port, raid, owner.generation()), label + " exact owner/actor/raid adapter bind")
	component.ability_granted.connect(on_native.bind("grant", key))
	component.ability_revoked.connect(on_native.bind("revoke", key))
	adapter.reconciliation_applied.connect(on_publication.bind(key))
	adapter.recovery_latched.connect(on_recovery.bind(key))
	owner.raid_authority().transaction_committed.connect(on_inventory.bind(key))
	verify(adapter.current_revision() == -1 and adapter.current_sources().is_empty()
		and component.granted_specs().is_empty() and component.active_effect_handles().is_empty(), label + " binding is mutation-free before the initial full snapshot")
	verify(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()), label + " activation follows all handler registration")
	return f


func phase_five(raid: RaidAuthority, phase: RaidAuthority.TickPhase, _tick: int, _intents: Array[ZRaidIntent]) -> bool:
	var f := fixtures[raid.get_instance_id()] as Dictionary
	verify(phase == RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS and raid.last_phase_trace.size() == 5, String(f["label"]) + " canonical callback is phase 5")
	var before := component_state(f)
	f["phase5_before"] = before
	for command_value in f["commands"] as Array:
		var operation := command_value as Dictionary
		var result := execute_inventory_operation(f, operation)
		(f["results"] as Array).append(result.duplicate(true))
		verify(bool(result.get("accepted", false)), String(f["label"]) + " phase-5 command accepted: " + String(operation["op"]))
	verify(component_state(f) == before, String(f["label"]) + " all accepted phase-5 results defer native ability state")
	f["commands"] = []
	return true


func phase_seven_external(raid: RaidAuthority, phase: RaidAuthority.TickPhase, tick: int, _intents: Array[ZRaidIntent]) -> bool:
	var f := fixtures[raid.get_instance_id()] as Dictionary
	var action := String(f["external_action"])
	if action.is_empty():
		return true
	verify(phase == RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK and raid.last_phase_trace.size() == 7, "external source is confined to canonical phase 7")
	var component := f["component"] as GameplayAbilityComponent
	var result: Dictionary
	if action == "grant":
		result = component.grant_ability(String(C.ABILITY_AKM_EQUIPPED), 1, "astra.foreign.same_tag", tick)
		f["external_spec"] = int(result.get("spec", 0))
	else:
		result = component.revoke_ability(int(f["external_spec"]), tick, GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
	verify(bool((result.get("status", {}) as Dictionary).get("ok", false)), "real independent same-tag source " + action + " succeeds")
	f["external_action"] = ""
	return true


func execute_inventory_operation(f: Dictionary, op: Dictionary) -> Dictionary:
	var inv := f["native_inventory"] as InventoryAuthority
	var inventory := int(f["inventory"])
	var name := String(op.get("name", ""))
	var equipment := int(f[String(I.CONTAINER_EQUIPMENT)])
	var actor := RaidInventoryOwner.FIXTURE_ACTOR_ID
	command_id += 1
	var command := int(op.get("command", command_id))
	var result: Dictionary
	match String(op["op"]):
		"insert":
			result = inv.insert_item(inventory, String(op["definition"]), 1,
				slot(equipment, StringName(op["slot"])), actor, command)
			if bool(result.get("accepted", false)) and not bool(result.get("replayed", false)):
				(f["items"] as Dictionary)[name] = int(result.get("new_item_id", 0))
		"move":
			result = inv.move_item(inventory, int(f["items"][name]),
				spatial(int(f[String(I.CONTAINER_BACKPACK)]), int(op.get("x", 0)), int(op.get("y", 0))), actor, command)
		"equip":
			result = inv.equip_item(inventory, int(f["items"][name]), equipment, String(op["slot"]), actor, command)
		"destroy":
			result = inv.remove_item(inventory, int(f["items"][name]), actor, command)
		"hint":
			var adapter := f["adapter"] as InventoryAbilityAdapter
			var revision := adapter.current_revision()
			var predecessor := revision + int(op.get("offset", 0))
			var successor := predecessor if bool(op.get("replayed", false)) else predecessor + 1
			var hint := {"accepted": true, "queued": false, "replayed": bool(op.get("replayed", false)),
				"command_id": command, "revisions": [{"inventory": inventory, "predecessor": predecessor, "successor": successor}]}
			result = {"accepted": adapter.observe_inventory_result(hint), "hint": hint}
			var pending := adapter.pending_result_count()
			verify(adapter.observe_inventory_result(hint) and adapter.pending_result_count() == pending,
				"identical receipt hint deduplicates inside the bounded pending queue")
	f["last_command"] = command
	return result


func on_inventory(receipt: Dictionary, key: int) -> void:
	var f := fixtures[key] as Dictionary
	var raid := f["raid"] as RaidAuthority
	verify(bool(f["in_tick"]) and raid.last_phase_trace.size() == 5, "native inventory publication occurs in phase 5")
	verify(component_state(f) == f["phase5_before"], "native inventory signal sees exactly the pre-phase ability state")
	events.append({"order": events.size() + 1, "fixture": f["label"], "kind": "inventory",
		"phase": 5, "receipt": receipt.duplicate(true), "abilities": component_state(f)})


func on_native(record: Dictionary, kind: String, key: int) -> void:
	var f := fixtures[key] as Dictionary
	var raid := f["raid"] as RaidAuthority
	var phase := raid.last_phase_trace.size() if bool(f["in_tick"]) else 0
	if bool(f["in_tick"]):
		verify(phase == 7, "native " + kind + " occurs only in phase 7 during canonical advancement")
	events.append({"order": events.size() + 1, "fixture": f["label"], "kind": kind,
		"phase": phase, "record": record.duplicate(true), "abilities": component_state(f)})


func on_publication(outcome: Dictionary, key: int) -> void:
	var f := fixtures[key] as Dictionary
	var raid := f["raid"] as RaidAuthority
	var component := component_state(f)
	f["publication_count"] = int(f["publication_count"]) + 1
	verify(deep_read_only(outcome), "adapter outcome is recursively read-only at publication")
	if bool(outcome.get("accepted", false)):
		verify(bool(f["in_tick"]) and raid.last_phase_trace.size() == 7, "accepted reconciliation publishes in phase 7")
		verify(int(component["effects"]) == int(component["executions"])
			and int(component["effects"]) == int(component["ready"]), "published native effects/executions/modifier agree")
	else:
		var clean := int(component["effects"]) == 0 and int(component["executions"]) == 0 \
			and int(component["ready"]) == 0 and not bool(component["akm_tag"]) and not bool(component["melee_tag"])
		(f["clean_publications"] as Array).append(clean)
		f["last_component_state"] = component.duplicate(true)
	events.append({"order": events.size() + 1, "fixture": f["label"], "kind": "adapter",
		"phase": raid.last_phase_trace.size() if bool(f["in_tick"]) else 0,
		"outcome": outcome.duplicate(true), "abilities": component})


func on_recovery(reason: StringName, details: Dictionary, key: int) -> void:
	var f := fixtures[key] as Dictionary
	f["recovery_count"] = int(f["recovery_count"]) + 1
	verify(deep_read_only(details), "recovery details are recursively read-only")
	events.append({"order": events.size() + 1, "fixture": f["label"], "kind": "recovery",
		"reason": reason, "details": details.duplicate(true), "abilities": component_state(f)})


func tick(f: Dictionary, operations: Array = [], expected := true, external_action := "") -> void:
	f["commands"] = operations
	f["results"] = []
	f["external_action"] = external_action
	f["in_tick"] = true
	var raid := f["raid"] as RaidAuthority
	var previous_tick := raid.last_processed_tick
	var was_active := raid.lifecycle == RaidAuthority.Lifecycle.ACTIVE
	var ok := raid.advance_one(raid.generation())
	f["in_tick"] = false
	verify(ok == expected, String(f["label"]) + " advance_one result at tick " + str(previous_tick + 1))
	if was_active:
		verify(raid.last_processed_tick == previous_tick + 1, "canonical processed tick advances exactly once even on a terminal phase failure")
	if expected:
		verify(raid.last_phase_trace == RaidAuthority.PHASE_NAMES, "successful canonical tick traverses all nine ordered phases")
	var inv: Variant = f["native_inventory"]
	if is_instance_valid(inv) and inv.has_inventory(int(f["inventory"])):
		f["cached_revision"] = inv.inventory_revision(int(f["inventory"]))


func component_state(f: Dictionary) -> Dictionary:
	var value: Variant = f.get("component")
	if not is_instance_valid(value):
		var cached := (f["last_component_state"] as Dictionary).duplicate(true)
		cached["component_alive"] = false
		cached["evidence"] = "last synchronous cleanup publication before Node destruction"
		return cached
	var component := value as GameplayAbilityComponent
	var live := 0
	var revoked := 0
	var terminal_history := 0
	var inactive_history := 0
	var active_specs: Dictionary = {}
	for execution_id in component.active_executions():
		active_specs[int(component.get_execution(execution_id).get("spec", 0))] = true
	var grants: Array[Dictionary] = []
	for spec in component.granted_specs():
		var grant := component.get_grant(spec)
		grants.append(grant.duplicate(true))
		if bool(grant.get("revoked", true)):
			revoked += 1
		elif component.is_torn_down():
			terminal_history += 1
		elif active_specs.has(int(spec)):
			live += 1
		else:
			inactive_history += 1
	return {"component_alive": true, "torn_down": component.is_torn_down(),
		"owner_valid": component.is_owner_valid(), "live": live, "revoked": revoked,
		"terminal_history": terminal_history, "inactive_history": inactive_history, "grants": grants,
		"effects": component.active_effect_handles().size(), "effect_handles": Array(component.active_effect_handles()),
		"executions": component.active_executions().size(), "execution_ids": Array(component.active_executions()),
		"ready": component.get_attribute_current(String(C.ATTRIBUTE_READIED_WEAPON_COUNT)),
		"akm_tag": component.has_tag_exact(String(C.TAG_AKM_EQUIPPED)),
		"melee_tag": component.has_tag_exact(String(C.TAG_MACHETE_EQUIPPED))}


func observe(f: Dictionary, label: String, expected_sources: int, expected_effects: int) -> Dictionary:
	var adapter := f["adapter"] as InventoryAbilityAdapter
	var raid := f["raid"] as RaidAuthority
	var state := component_state(f)
	verify(adapter.current_sources().size() == expected_sources, label + " exact adapter source count")
	verify(int(state["effects"]) == expected_effects and int(state["executions"]) == expected_effects
		and is_equal_approx(float(state["ready"]), float(expected_effects)), label + " exact native effect/execution/readied count")
	var row := {"fixture": f["label"], "label": label, "tick": raid.last_processed_tick,
		"revision": f["cached_revision"], "applied": adapter.current_revision(),
		"sources": adapter.current_sources().size(), "live": state["live"], "revoked": state["revoked"],
		"terminal_history": state["terminal_history"], "effects": state["effects"], "ready": state["ready"],
		"raid_lifecycle": raid.lifecycle_name(), "adapter_lifecycle": adapter.lifecycle,
		"state": state, "outcome": adapter.current_outcome()}
	observations.append(row)
	return row


func continuous_flow() -> void:
	var f := fixture("continuous")
	var a := f["adapter"] as InventoryAbilityAdapter
	var c := f["component"] as GameplayAbilityComponent
	var p := f["port"] as GameplayAbilityEquipmentPort
	var rows: Array[Dictionary] = []
	rows.append(observe(f, "Bind: no mutation", 0, 0))
	tick(f)
	rows.append(observe(f, "Initial full snapshot", 0, 0))
	verify(a.current_revision() == 0 and bool(a.current_outcome().get("initial", false)), "initial full snapshot establishes exact revision zero")
	tick(f, [insert_op("rig", I.ITEM_RIG_BASIC, C.SLOT_RIG), insert_op("bag", I.ITEM_BACKPACK_DAYPACK, C.SLOT_BACKPACK)])
	rows.append(observe(f, "Rig + backpack: no grants", 0, 0))
	verify(int((a.current_outcome()["result_hints"] as Dictionary)["accepted_edges"]) == 2, "two accepted no-grant gear revisions coalesce from full after-state")
	var first_insert := insert_op("akm", I.ITEM_AKM, C.SLOT_PRIMARY)
	first_insert["command"] = 990_001
	tick(f, [first_insert])
	rows.append(observe(f, "Equip AKM", 1, 1))
	var original := first_record(a.source_for_native_item(int(f["items"]["akm"])))
	verify(p.grant_record_is_live(original) and bool(component_state(f)["akm_tag"]), "equipped AKM has exact live production grant and tag")
	var original_key := String(a.source_for_native_item(int(f["items"]["akm"]))["source_item_key"])
	var exact_before := component_state(f)
	var publications := int(f["publication_count"])
	tick(f)
	rows.append(observe(f, "Duplicate full: same spec", 1, 1))
	verify(component_state(f) == exact_before and int(f["publication_count"]) == publications, "duplicate full snapshot changes no handle, history, tag, modifier or publication")
	tick(f, [first_insert])
	rows.append(observe(f, "Recorded replay: same spec", 1, 1))
	verify(bool((f["results"][0] as Dictionary).get("replayed", false))
		and component_state(f) == exact_before and int(f["publication_count"]) == publications,
		"real recorded receipt replay preserves the exact native state")
	tick(f, [{"op": "hint", "replayed": true}])
	rows.append(observe(f, "Normalized replay: same spec", 1, 1))
	verify(component_state(f) == exact_before and a.pending_result_count() == 0 and not a.resync_required(), "normalized p-to-p replay is consumed idempotently")
	tick(f, [{"op": "hint", "offset": 8}, insert_op("machete", I.ITEM_MACHETE, C.SLOT_MELEE)])
	rows.append(observe(f, "Gap heals full; equip machete", 2, 2))
	var gap_hints := a.current_outcome()["result_hints"] as Dictionary
	verify(int(gap_hints["invalid_edges"]) == 1 and bool(gap_hints["resync_required_before_pull"])
		and not a.resync_required() and a.current_revision() == int(f["cached_revision"]), "detected forward gap heals to exact native full snapshot and clears resync")
	tick(f, [{"op": "move", "name": "akm"}])
	rows.append(observe(f, "Unequip AKM: exact revoke", 1, 1))
	verify(p.grant_record_is_absent(original) and not bool(component_state(f)["akm_tag"]), "unequip removes only the old AKM spec/effect/tag/modifier")
	tick(f, [{"op": "equip", "name": "akm", "slot": C.SLOT_PRIMARY}])
	rows.append(observe(f, "Re-equip: stable source/new spec", 2, 2))
	var reequipped := first_record(a.source_for_native_item(int(f["items"]["akm"])))
	verify(String(a.source_for_native_item(int(f["items"]["akm"]))["source_item_key"]) == original_key
		and int(reequipped["spec"]) != int(original["spec"]) and p.grant_record_is_live(reequipped), "re-equip retains canonical item identity and creates one new live spec")
	var start := events.size()
	tick(f, [{"op": "move", "name": "akm"}, insert_op("replacement", I.ITEM_AKM, C.SLOT_PRIMARY)])
	rows.append(observe(f, "Replacement: add before remove", 2, 2))
	var order := event_kinds_since(start)
	var replacement := first_record(a.source_for_native_item(int(f["items"]["replacement"])))
	verify(order == ["inventory", "inventory", "grant", "revoke", "adapter"], "two-revision replacement orders commits, native add, native remove, then one publication")
	verify(p.grant_record_is_absent(reequipped) and p.grant_record_is_live(replacement)
		and int(replacement["spec"]) != int(reequipped["spec"]), "replacement records exact new and revoked native specs")
	verify(int((a.current_outcome()["result_hints"] as Dictionary)["accepted_edges"]) == 2, "replacement consumes both accepted revision edges")
	await capture("ordinary_flow_1280x720.png", "Ordinary canonical flow", rows,
		"Two weapon sources are live; two earlier revoked specs remain historical tombstones.")
	tick(f, [], true, "grant")
	rows.append(observe(f, "Independent same-tag grant", 2, 3))
	var foreign_spec := int(f["external_spec"])
	verify(foreign_spec > 0 and not bool(c.get_grant(foreign_spec)["revoked"]), "independent same-tag source has its own native spec")
	tick(f, [{"op": "destroy", "name": "replacement"}])
	rows.append(observe(f, "Destroy equipped AKM; foreign lives", 1, 2))
	verify(p.grant_record_is_absent(replacement) and not bool(c.get_grant(foreign_spec)["revoked"])
		and bool(component_state(f)["akm_tag"]), "destroying adapter equipment leaves independent same-tag effect and contribution intact")
	tick(f, [], true, "revoke")
	rows.append(observe(f, "Foreign revoke: AKM tag clears", 1, 1))
	verify(not bool(component_state(f)["akm_tag"]), "final independent revoke removes the final AKM tag contribution")
	var machete := first_record(a.source_for_native_item(int(f["items"]["machete"])))
	tick(f, [{"op": "destroy", "name": "machete"}])
	rows.append(observe(f, "Destroy equipped machete: clean", 0, 0))
	verify(p.grant_record_is_absent(machete) and not bool(component_state(f)["melee_tag"])
		and int(component_state(f)["live"]) == 0 and int(component_state(f)["revoked"]) == 5,
		"destruction leaves zero live specs, effects, tags and modifiers with five honest tombstones")
	await capture("external_isolation_1280x720.png", "Independent grant isolation and destruction", rows.slice(-11),
		"The foreign same-tag source survived adapter removal; final destruction unwound all live state.")
	flow_details["continuous"] = {"rows": rows, "replacement_order": order, "gap_hints": gap_hints,
		"original_record": original, "replacement_record": replacement, "foreign_spec": foreign_spec}
	dispose(f)
	await process_frame


func recovery_flow() -> void:
	var f := fixture("recovery", true)
	var a := f["adapter"] as InventoryAbilityAdapter
	var raid := f["raid"] as RaidAuthority
	var port := f["port"] as RefusingRevokePort
	var rows: Array[Dictionary] = []
	tick(f)
	rows.append(observe(f, "Initial full: no grants", 0, 0))
	tick(f, [insert_op("akm", I.ITEM_AKM, C.SLOT_PRIMARY), insert_op("machete", I.ITEM_MACHETE, C.SLOT_MELEE)])
	rows.append(observe(f, "Two equipped live native grants", 2, 2))
	var applied_before := a.current_revision()
	port.refuse_revoke = true
	tick(f, [{"op": "move", "name": "akm"}], false)
	rows.append(observe(f, "Revoke refused: native quarantine", 0, 0))
	var details := a.current_outcome()["details"] as Dictionary
	verify(raid.lifecycle == RaidAuthority.Lifecycle.FAILED and a.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED,
		"injected revoke refusal fails real raid and latches adapter recovery")
	verify(a.current_revision() == applied_before and a.current_outcome()["reason"] == &"equipment_ability_revoke_failed",
		"quarantine publishes no successful revision after failed native reconciliation")
	verify(port.rejected_revoke_calls >= 2 and port.quarantine_calls == 1
		and bool((details["quarantine_result"] as Dictionary)["accepted"])
		and (details["unresolved_records"] as Array).is_empty(), "production quarantine runs exactly once and positively proves every supplied record clean")
	verify(bool(component_state(f)["torn_down"]) and not bool(component_state(f)["owner_valid"])
		and int(component_state(f)["live"]) == 0 and int(component_state(f)["terminal_history"]) == 2,
		"terminal native component retains history but no live equipment contribution")
	verify(int(f["recovery_count"]) == 1 and f["clean_publications"] == [true], "one immutable recovery publication observes already-clean native state")
	var exact_after := component_state(f)
	tick(f, [], false)
	verify(component_state(f) == exact_after and int(f["recovery_count"]) == 1, "failed raid cannot silently retry or reopen native grants")
	await capture("recovery_1280x720.png", "Injected failure to production quarantine", rows,
		"Raid FAILED / adapter RECOVERY_REQUIRED. Unresolved records: 0. Terminal history is not live state.")
	flow_details["recovery"] = {"outcome": a.current_outcome(), "rows": rows,
		"rejected_revoke_calls": port.rejected_revoke_calls, "quarantine_calls": port.quarantine_calls}
	dispose(f)
	await process_frame


func teardown_flows() -> void:
	var rows: Array[Dictionary] = []
	for mode in ["explicit_release", "owner_node_first", "component_node_first"]:
		var f := fixture(mode)
		var a := f["adapter"] as InventoryAbilityAdapter
		var raid := f["raid"] as RaidAuthority
		var owner := f["owner"] as RaidInventoryOwner
		var component := f["component"] as GameplayAbilityComponent
		var owner_id := owner.get_instance_id()
		var component_id := component.get_instance_id()
		tick(f, [insert_op("akm", I.ITEM_AKM, C.SLOT_PRIMARY), insert_op("machete", I.ITEM_MACHETE, C.SLOT_MELEE)])
		rows.append(observe(f, mode.replace("_", " ") + ": live", 2, 2))
		if mode == "explicit_release":
			var released := a.release_binding(&"astra_release_before_raid_terminal", a.current_tick())
			verify(bool(released.get("invalidated", false)), "explicit release acknowledges invalidation")
		elif mode == "owner_node_first":
			owner.queue_free()
			await process_frame
			await process_frame
			verify(not is_instance_id_valid(owner_id), "actual owner Node is destroyed before component Node")
			verify(is_instance_id_valid(component_id), "owner-first cleanup leaves the component queryable")
		else:
			component.queue_free()
			await process_frame
			await process_frame
			verify(not is_instance_id_valid(component_id), "actual component Node is destroyed before owner Node")
			verify(is_instance_id_valid(owner_id), "component-first cleanup leaves inventory owner queryable")
		verify(a.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED
			and a.current_sources().is_empty() and f["clean_publications"] == [true],
			mode + " invalidates exactly once after synchronous cleanup proof")
		rows.append(observe(f, mode.replace("_", " ") + ": clean", 0, 0))
		tick(f)
		verify(raid.lifecycle == RaidAuthority.Lifecycle.ACTIVE, mode + " invalidated phase handler is inert and safe")
		verify(raid.teardown(raid.generation()), mode + " raid terminalizes only after equipment cleanup")
		flow_details[mode] = {"owner_instance": owner_id, "component_instance": component_id,
			"cleanup_at_publication": f["last_component_state"], "outcome": a.current_outcome(),
			"actual_node_destruction": mode != "explicit_release"}
		dispose(f)
		await process_frame
	await capture("teardown_1280x720.png", "Explicit release and actual Node teardown orders", rows,
		"All three orders prove zero effects/tags/modifiers before RaidAuthority terminalization.")


func terminal_first_constraint() -> void:
	var f := fixture("terminal_first_probe")
	var raid := f["raid"] as RaidAuthority
	var a := f["adapter"] as InventoryAbilityAdapter
	tick(f, [insert_op("akm", I.ITEM_AKM, C.SLOT_PRIMARY)])
	verify(raid.teardown(raid.generation()), "P2 probe deliberately terminalizes the raid before composition cleanup")
	var state_before_release := component_state(f)
	verify(a.lifecycle == InventoryAbilityAdapter.Lifecycle.BOUND and int(state_before_release["effects"]) == 1,
		"accepted P2 constraint: raid terminalization alone does not automatically clean adapter equipment")
	a.release_binding(&"astra_p2_probe_cleanup", a.current_tick())
	verify(a.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED and int(component_state(f)["effects"]) == 0,
		"P2 probe explicitly releases its retained live native state")
	flow_details["terminal_first_constraint"] = {"severity": "P2 accepted follow-up", "tasks": ["4.12", "7.1"],
		"before_explicit_release": state_before_release, "after_release": component_state(f),
		"constraint": "Composition releases adapter or tears down inventory owner/component before raid terminalization.",
		"automatic_raid_terminal_cleanup_claimed": false}
	dispose(f)
	await process_frame


func capture(filename: String, page: String, rows: Array[Dictionary], note: String) -> void:
	if not native:
		return
	board.page = page
	board.rows = rows
	board.note = note
	board.result = "PASS SO FAR" if failures == 0 else "FAIL"
	board.queue_redraw()
	for _frame in range(4):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame
	RenderingServer.force_draw(true)
	var frame := root.get_texture().get_image()
	verify(frame != null and frame.get_size() == Vector2i(1280, 720), filename + " framebuffer has exact 1280x720 pixels")
	verify(frame.save_png(OUT + filename) == OK, filename + " readable native framebuffer saved")
	captures.append({"file": filename, "page": page, "rows": rows.size(), "visible": root.visible,
		"renderer": RenderingServer.get_current_rendering_method(), "display_server": DisplayServer.get_name(),
		"size": [frame.get_width(), frame.get_height()], "settle_frames": 4, "force_draw": true})
	await create_timer(2.0).timeout


func dispose(f: Dictionary) -> void:
	var a := f["adapter"] as InventoryAbilityAdapter
	var raid := f["raid"] as RaidAuthority
	var owner: Variant = f.get("owner")
	var component: Variant = f.get("component")
	var port := f["port"] as GameplayAbilityEquipmentPort
	if a.lifecycle == InventoryAbilityAdapter.Lifecycle.BOUND:
		a.release_binding(&"astra_fixture_dispose", a.current_tick())
	if is_instance_valid(owner) and owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
		verify(owner.teardown(owner.generation()), String(f["label"]) + " inventory owner releases canonical inventories")
	if is_instance_valid(component) and not component.is_torn_down():
		component.queue_teardown(maxi(component.get_current_tick(), a.current_tick()))
	if raid.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		verify(raid.teardown(raid.generation()), String(f["label"]) + " raid releases phase callbacks")
	verify(port.clear(), String(f["label"]) + " participant releases native references")
	if is_instance_valid(component):
		component.free()
	if is_instance_valid(owner):
		owner.free()
	fixtures.erase(int(f["key"]))
	f.clear()


func root_container(snapshot: InventorySnapshotResource, definition: StringName) -> int:
	for value in snapshot.get_containers():
		var row := value as Dictionary
		if int(row.get("provider_item", 0)) == 0 and StringName(row.get("container_definition_identifier", &"")) == definition:
			return int(row["id"])
	return 0


func insert_op(name: String, definition: StringName, slot_name: StringName) -> Dictionary:
	return {"op": "insert", "name": name, "definition": definition, "slot": slot_name}


func first_record(source: Dictionary) -> Dictionary:
	var records := source.get("grant_records", []) as Array
	return (records[0] as Dictionary).duplicate(true) if not records.is_empty() else {}


func event_kinds_since(start: int) -> Array[String]:
	var result: Array[String] = []
	for event in events.slice(start):
		result.append(String(event["kind"]))
	return result


func slot(container: int, identifier: StringName) -> Dictionary:
	return {"kind": "slot", "container": container, "slot_identifier": String(identifier)}


func spatial(container: int, x: int, y: int) -> Dictionary:
	return {"kind": "spatial", "container": container, "x": x, "y": y, "rotated": false}


func deep_read_only(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only():
			return false
		for child in value.values():
			if not deep_read_only(child):
				return false
	elif value is Array:
		if not value.is_read_only():
			return false
		for child in value:
			if not deep_read_only(child):
				return false
	return true
