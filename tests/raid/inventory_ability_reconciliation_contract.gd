extends SceneTree
## Run with: /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
##   --headless --path . --script \
##   res://tests/raid/inventory_ability_reconciliation_contract.gd
##
## Task 4.10 contract. The primary flow drives a real InventoryAuthority in a
## real RaidAuthority phase-5 callback and observes a real vendored
## GameplayAbilityComponent only changing in phase 7. Fault wrappers below
## exercise the game-owned fail-stop seam; they are not substitutes for that
## real-add-on proof.


class ContractIdentityPort extends ZInventoryIdentityPort:
	var session_key: String = ""
	var actor_key: String = ""
	var epoch: int = 0
	var generation: int = 0
	var native_actor: int = 0
	var inventory_id: int = 0
	var owns_inventory: bool = true

	func native_actor_id(
		p_session: ZSessionId,
		p_actor: ZEntityId,
		p_epoch: int,
		p_generation: int
	) -> int:
		if p_session == null or p_actor == null \
				or p_session.canonical_key() != session_key \
				or p_actor.canonical_key() != actor_key \
				or p_epoch != epoch or p_generation != generation:
			return 0
		return native_actor

	func actor_owns_inventory(
		p_session: ZSessionId,
		p_actor: ZEntityId,
		p_inventory_id: int,
		p_epoch: int,
		p_generation: int
	) -> bool:
		return owns_inventory \
			and native_actor_id(p_session, p_actor, p_epoch, p_generation) > 0 \
			and p_inventory_id == inventory_id


class FaultPort extends EquipmentAbilityParticipantPort:
	var inner: GameplayAbilityEquipmentPort
	var grant_fault: StringName = &""
	var revoke_fault: StringName = &""
	var preflight_fault: bool = false
	var unavailable: bool = false
	var block_revoke: bool = false
	var block_quarantine: bool = false
	var simulated_lingering_modifier_micros: int = 0
	var simulated_lingering_tag: bool = false
	var lingering_native_grant: Dictionary = {}
	var quarantine_calls: int = 0
	var last_quarantine_records: Array[Dictionary] = []

	func is_ready() -> bool:
		return not unavailable and inner != null and inner.is_ready()

	func identity_token() -> String:
		return inner.identity_token() if inner != null else ""

	func entity_id() -> int:
		return inner.entity_id() if inner != null else 0

	func current_tick() -> int:
		return inner.current_tick() if inner != null else 0

	func owner_node() -> Node:
		return inner.owner_node() if inner != null else null

	func validate_content(declarations: Array[Dictionary]) -> Dictionary:
		return inner.validate_content(declarations)

	func preflight(
		addition_plans: Array[Dictionary],
		revocation_records: Array[Dictionary]
	) -> Dictionary:
		if preflight_fault:
			preflight_fault = false
			return _fault(&"fixture_preflight_failure", MUTATION_NONE)
		return inner.preflight(addition_plans, revocation_records) \
			if is_ready() else _fault(&"fixture_unavailable", MUTATION_NONE)

	func grant(plan: Dictionary, tick: int) -> Dictionary:
		if unavailable:
			return _fault(&"fixture_unavailable", MUTATION_AMBIGUOUS)
		if grant_fault == &"before":
			grant_fault = &""
			return _fault(&"fixture_grant_before", MUTATION_NONE)
		var result := inner.grant(plan, tick)
		if grant_fault == &"after":
			grant_fault = &""
			return _fault(&"fixture_grant_after", MUTATION_COMMITTED,
				[_as_mutation_recovery(result)])
		return result

	func revoke(record: Dictionary, tick: int) -> Dictionary:
		if unavailable or block_revoke:
			return _fault(&"fixture_revoke_blocked", MUTATION_AMBIGUOUS, [record])
		if revoke_fault == &"before":
			revoke_fault = &""
			return _fault(&"fixture_revoke_before", MUTATION_NONE,
				[_as_revoke_mutation_recovery(record, false)])
		var result := inner.revoke(record, tick)
		if revoke_fault == &"after":
			revoke_fault = &""
			var recovery := _as_revoke_mutation_recovery(record, true)
			if simulated_lingering_modifier_micros != 0 or simulated_lingering_tag:
				lingering_native_grant = _inject_lingering_grant(record, tick)
			return _fault(&"fixture_revoke_after", MUTATION_COMMITTED,
				[recovery])
		return result

	func grant_record_is_live(record: Dictionary) -> bool:
		return inner != null and inner.grant_record_is_live(record)

	func grant_record_is_absent(record: Dictionary) -> bool:
		return inner != null and inner.grant_record_is_absent(record)

	func recovery_record_is_clean(record: Dictionary) -> bool:
		return inner != null and inner.recovery_record_is_clean(record)

	func grant_record_is_terminally_clean(record: Dictionary) -> bool:
		return inner != null and inner.grant_record_is_terminally_clean(record)

	func quarantine(records: Array[Dictionary], tick: int) -> Dictionary:
		quarantine_calls += 1
		last_quarantine_records.clear()
		for record in records:
			last_quarantine_records.append(record.duplicate(true))
		if unavailable or block_quarantine:
			return _fault(&"fixture_quarantine_blocked", MUTATION_AMBIGUOUS, records)
		var result := inner.quarantine(records, tick)
		if bool(result.get("accepted", false)):
			simulated_lingering_modifier_micros = 0
			simulated_lingering_tag = false
		return result

	func clear() -> bool:
		return not unavailable and inner.clear()

	func _fault(
		reason: StringName,
		mutation_state: StringName,
		recovery_records: Array = []
	) -> Dictionary:
		return {
			"accepted": false,
			"reason": reason,
			"mutation_state": mutation_state,
			"recovery_records": recovery_records.duplicate(true),
		}

	func _as_mutation_recovery(record: Dictionary) -> Dictionary:
		var recovery := record.duplicate(true)
		recovery["record_kind"] = &"mutation_recovery"
		return recovery

	func _as_revoke_mutation_recovery(
		record: Dictionary,
		already_committed: bool
	) -> Dictionary:
		var recovery := _as_mutation_recovery(record)
		var component := inner.owner_node() as GameplayAbilityComponent
		var expected_attributes: Dictionary = {}
		for key in (record.get("modifier_delta_micros", {}) as Dictionary).keys():
			var current := component.get_attribute_current(String(key))
			expected_attributes[String(key)] = current if already_committed else \
				current - float(record["modifier_delta_micros"][key]) \
					/ float(ZerkovEquipmentAbilityContent.FIXED_SCALE)
		recovery["modifier_values_before"] = expected_attributes
		recovery["fixture_partial_revoke"] = true
		return recovery

	func _inject_lingering_grant(record: Dictionary, tick: int) -> Dictionary:
		var effects := PackedStringArray()
		for value in record.get("effects", []) as Array:
			effects.append(String((value as Dictionary).get(
				"definition_identifier", &"")))
		return inner.grant({
			"ability_identifier": record.get("ability_identifier", &""),
			"level": int(record.get("level", 1)),
			"input_id": "fixture.lingering.%d" % int(record.get("spec", 0)),
			"effect_identifiers": effects,
			"tag_identifiers": PackedStringArray(
				record.get("tag_identifiers", PackedStringArray())),
			"modifier_delta_micros": (record.get(
				"modifier_delta_micros", {}) as Dictionary).duplicate(true),
		}, tick)


var checks: int = 0
var failures: int = 0
var _phase_actions: Dictionary = {}
var _phase_results: Dictionary = {}
var _command_id: int = 40_000


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_ABILITY_RECONCILIATION_CONTRACT: " + message)


func run() -> void:
	_test_content_and_manifest_contract()
	await _test_real_phase_reconciliation()
	await _test_binding_trust_boundaries()
	await _test_lifecycle_orders()
	await _test_persistence_generation_invalidation()
	await _test_explicit_release_before_raid_terminal()
	await _test_declared_destruction_and_external_revoke()
	await _test_failure_and_quarantine_contracts()
	await _test_grant_history_capacity()
	await process_frame
	await process_frame
	print("INVENTORY_ABILITY_RECONCILIATION_RESULT checks=", checks,
		" failures=", failures, " real_inventory=true real_gameplay_abilities=true")
	quit(0 if failures == 0 else 1)


func _test_content_and_manifest_contract() -> void:
	var declarations := ZerkovEquipmentAbilityContent.equipment_declarations()
	var no_grant := ZerkovEquipmentAbilityContent.no_grant_equipment_declarations()
	var mapping := ZerkovEquipmentAbilityContent.integration_mapping_bytes()
	var digest := ZerkovEquipmentAbilityContent.declaration_digest()
	check(declarations.size() == 2 and no_grant.size() == 2,
		"AKM/machete grant declarations and rig/backpack no-grant scope are explicit")
	check(not mapping.is_empty() and digest.length() == 64,
		"equipment declaration mapping has non-empty canonical bytes and SHA-256")
	var encoded := mapping.get_string_from_utf8()
	check(not encoded.is_empty() and not encoded.contains("1.0"),
		"manifest mapping uses fixed-point integers instead of floats")
	for declaration in declarations + no_grant:
		check(typeof(declaration.get("item_definition_identifier")) == TYPE_STRING
			and declaration.get("allowed_slots") is Array,
			"manifest declarations use canonical plain string/Array forms")

	var ability_catalog := ZerkovEquipmentAbilityContent.build_definition_catalog()
	var validator := GameplayDefinitionValidator.new()
	var findings: Array = validator.validate_catalog(ability_catalog)
	check(GameplayDefinitionValidator.is_ok(findings)
		and validator.get_last_manifest_ok()
		and validator.get_last_manifest_fingerprint() != 0,
		"real Gameplay Abilities validator seals the equipment content catalog")

	var canonical_inventory := ZerkovInventoryCatalog.build_sealed_catalog()
	var no_mapping_inventory := _build_inventory_catalog_without_mapping()
	check(canonical_inventory != null and no_mapping_inventory != null
		and canonical_inventory.manifest_algorithm()
			== no_mapping_inventory.manifest_algorithm()
		and canonical_inventory.manifest_fingerprint()
			!= no_mapping_inventory.manifest_fingerprint(),
		"registered equipment mapping changes the real sealed inventory manifest")


func _test_real_phase_reconciliation() -> void:
	var fixture := _build_fixture("main")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var port := fixture["port"] as GameplayAbilityEquipmentPort
	var inventory := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var equipment := int(fixture["equipment"])
	var backpack := int(fixture["backpack"])
	var rig := int(fixture["rig"])
	check(component.get_definition_catalog().get_tag_definitions().size() == 3,
		"canonical equipment subset binds inside a larger validated GA catalog")

	var publications: Array[Dictionary] = []
	var publications_read_only: Array[bool] = []
	var native_order: Array[String] = []
	var inventory_callback_effect_counts: Array[int] = []
	adapter.reconciliation_applied.connect(func(outcome: Dictionary):
		publications.append(outcome.duplicate(true))
		publications_read_only.append(_deep_read_only(outcome))
		native_order.append("adapter"))
	component.ability_granted.connect(func(_record: Dictionary):
		native_order.append("grant"))
	component.ability_revoked.connect(func(_record: Dictionary):
		native_order.append("revoke"))
	inventory.transaction_committed.connect(func(_result: Dictionary):
		inventory_callback_effect_counts.append(
			int(component.get_diagnostics().get("active_effect_count", -1))))

	check(adapter.current_revision() == -1
		and component.granted_specs().is_empty()
		and component.active_effect_handles().is_empty(),
		"bind registers phase work without mutating from the initial snapshot")
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"real raid authority activates after every phase handler registers")
	check(_advance(fixture), "first real raid tick reaches the phase-7 adapter")
	check(adapter.current_revision() == 0 and publications.size() == 1
		and bool(publications[0].get("initial", false))
		and component.granted_specs().is_empty(),
		"first phase-7 full snapshot establishes empty canonical state")

	# Rig and backpack are canonical capacity-gear slots but intentionally
	# carry no Gameplay Abilities declarations in the first-playable slice.
	var rig_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_RIG_BASIC), 1,
			_slot(equipment, ZerkovEquipmentAbilityContent.SLOT_RIG),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	var rig_item := int(rig_result.get("new_item_id", 0))
	check(bool(rig_result.get("accepted", false)) and rig_item > 0
		and adapter.current_sources().is_empty()
		and component.granted_specs().is_empty(),
		"accepted rig equipment delta is an intentional no-grant transition")
	var rig_hints := adapter.current_outcome().get("result_hints", {}) as Dictionary
	check(int(rig_hints.get("accepted_edges", -1)) == 1
		and int(rig_hints.get("hint_successor", -1)) == adapter.current_revision()
		and int(rig_hints.get("maximum_successor", -1)) == adapter.current_revision(),
		"one accepted delta edge is consumed before the authoritative full pull")
	var backpack_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_BACKPACK_DAYPACK), 1,
			_slot(equipment, ZerkovEquipmentAbilityContent.SLOT_BACKPACK),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(backpack_result.get("accepted", false))
		and adapter.current_sources().is_empty()
		and component.granted_specs().is_empty(),
		"accepted backpack equipment delta produces no ability grant churn")

	var phase_trace_at_transaction: Array[int] = []
	inventory.transaction_committed.connect(func(_result: Dictionary):
		phase_trace_at_transaction.append(raid.last_phase_trace.size()))
	var equip_command := _next_command()
	var akm_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(equipment, ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, equip_command))
	var akm_item := int(akm_result.get("new_item_id", 0))
	var akm_source := adapter.source_for_native_item(akm_item)
	var akm_record := _first_grant_record(akm_source)
	var akm_spec := int(akm_record.get("spec", 0))
	var akm_effect := _first_effect_handle(akm_record)
	check(bool(akm_result.get("accepted", false)) and akm_item > 0
		and not akm_source.is_empty() and port.grant_record_is_live(akm_record),
		"real equipped AKM grants one live native passive ability record")
	check(not inventory_callback_effect_counts.is_empty()
		and inventory_callback_effect_counts.back() == 0
		and not phase_trace_at_transaction.is_empty()
		and phase_trace_at_transaction.back()
			== int(RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS) + 1,
		"inventory transaction callback observes no grant before phase 7")
	check(component.active_executions().size() == 1
		and component.active_effect_handles().size() == 1
		and component.has_tag_exact(String(ZerkovEquipmentAbilityContent.TAG_AKM_EQUIPPED))
		and is_equal_approx(component.get_attribute_current(
			String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)), 1.0),
		"PASSIVE_ON_GRANT owns the exact active effect, tag, and +1 modifier")
	check(akm_spec > 0 and akm_effect > 0 and native_order.find("grant") >= 0
		and native_order.rfind("adapter") > native_order.find("grant"),
		"native grant lifecycle completes before the adapter publication")

	var grant_count_before_duplicate := component.granted_specs().size()
	var publications_before_duplicate := publications.size()
	check(_advance(fixture), "duplicate full snapshot tick succeeds")
	check(component.granted_specs().size() == grant_count_before_duplicate
		and int(_first_grant_record(adapter.source_for_native_item(
			akm_item)).get("spec", 0)) == akm_spec
		and publications.size() == publications_before_duplicate,
		"duplicate full snapshot preserves the exact spec without publication churn")

	# Pinned native receipt replay carries its original p->p+1 edge. It is a
	# sequencing no-op once that successor is already applied.
	var replay_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(equipment, ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, equip_command))
	check(bool(replay_result.get("accepted", false))
		and bool(replay_result.get("replayed", false))
		and component.granted_specs().size() == grant_count_before_duplicate
		and int(_first_grant_record(adapter.source_for_native_item(
			akm_item)).get("spec", 0)) == akm_spec,
		"recorded accepted replay edge is an exact no-op")
	var revision := adapter.current_revision()
	check(adapter.observe_inventory_result({
		"accepted": true, "queued": false, "replayed": true,
		"command_id": 99_001,
		"revisions": [{
			"inventory": inventory_id,
			"predecessor": revision,
			"successor": revision,
		}],
	}), "normalized accepted replay p->p is explicitly accepted")
	check(_advance(fixture) and not adapter.resync_required()
		and int(_first_grant_record(adapter.source_for_native_item(
			akm_item)).get("spec", 0)) == akm_spec,
		"normalized replay is consumed without grant or resync churn")
	check(adapter.observe_inventory_result({
		"accepted": true, "queued": false, "replayed": false,
		"command_id": 99_002,
		"revisions": [{
			"inventory": inventory_id,
			"predecessor": revision + 4,
			"successor": revision + 5,
		}],
	}), "well-formed but out-of-order forward hint is queued without mutation")
	check(_advance(fixture) and not adapter.resync_required()
		and int(_first_grant_record(adapter.source_for_native_item(
			akm_item)).get("spec", 0)) == akm_spec,
		"phase consumer detects the gap and exact full snapshot repairs without regrant")
	check(adapter.observe_inventory_result({
		"accepted": true, "queued": true, "replayed": false,
		"revisions": [{"inventory": inventory_id, "predecessor": -1, "successor": 9}],
	}) and adapter.observe_inventory_result({
		"accepted": false, "queued": false, "replayed": false,
		"revisions": [{"inventory": inventory_id, "predecessor": revision,
			"successor": revision}],
	}), "queued and rejected results are bounded no-op hints")

	# A magazine provider cascade changes multiple native records in one
	# accepted after-state but remains unrelated to the retained AKM grant.
	var magazine_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_MAGAZINE_AKM), 1,
			_spatial(rig, 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	var magazine_item := int(magazine_result.get("new_item_id", 0))
	var magazine_container := _provided_container(
		inventory.snapshot(inventory_id), magazine_item)
	var ammo_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_AMMO_762), 7,
			{"kind": "list", "container": magazine_container, "ordinal": 0},
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(magazine_result.get("accepted", false))
		and bool(ammo_result.get("accepted", false)) and magazine_container > 0,
		"real magazine provider contains child ammunition before cascade removal")
	var grants_before_cascade := component.granted_specs().size()
	var cascade_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.remove_item(
			inventory_id, magazine_item, RaidInventoryOwner.FIXTURE_ACTOR_ID,
			_next_command()))
	check(bool(cascade_result.get("accepted", false))
		and component.granted_specs().size() == grants_before_cascade
		and int(_first_grant_record(adapter.source_for_native_item(
			akm_item)).get("spec", 0)) == akm_spec,
		"provider cascade retains the exact unrelated equipment grant")

	# A foreign same-ability grant is neither adopted nor revoked. The adapter
	# records and revokes only its own spec and exact effect handle.
	var foreign_result: Dictionary = component.grant_ability(
		String(ZerkovEquipmentAbilityContent.ABILITY_AKM_EQUIPPED), 1,
		"foreign.akm.grant", adapter.current_tick())
	var foreign_spec := int(foreign_result.get("spec", 0))
	check(bool((foreign_result.get("status", {}) as Dictionary).get("ok", false))
		and foreign_spec > 0 and component.active_effect_handles().size() == 2,
		"real component accepts an independent same-ability multi-grant")
	var unequip_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.move_item(
			inventory_id, akm_item, _spatial(backpack, 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(unequip_result.get("accepted", false))
		and bool(component.get_grant(akm_spec).get("revoked", false))
		and component.get_active_effect(akm_effect).is_empty()
		and not bool(component.get_grant(foreign_spec).get("revoked", true))
		and component.active_effect_handles().size() == 1
		and is_equal_approx(component.get_attribute_current(
			String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)), 1.0),
		"unequip removes the exact adapter effect/modifier while foreign grant survives")
	check(bool((component.revoke_ability(
		foreign_spec, adapter.current_tick(),
		GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE).get("status", {})
		as Dictionary).get("ok", false))
		and component.active_effect_handles().is_empty()
		and not component.has_tag_exact(
			String(ZerkovEquipmentAbilityContent.TAG_AKM_EQUIPPED))
		and is_zero_approx(component.get_attribute_current(
			String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"final foreign revoke proves the declared tag and modifier fully unwind")

	# Replacement in one phase-5 after-state is planned add-before-remove.
	var re_equip := _advance_action(fixture, func() -> Dictionary:
		return inventory.equip_item(
			inventory_id, akm_item, equipment,
			String(ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(re_equip.get("accepted", false)), "canonical AKM re-equips")
	var old_replacement_record := _first_grant_record(
		adapter.source_for_native_item(akm_item))
	var order_start := native_order.size()
	var replacement_box: Array[Dictionary] = []
	var replacement_result := _advance_action(fixture, func() -> Dictionary:
		var moved: Dictionary = inventory.move_item(
			inventory_id, akm_item, _spatial(backpack, 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command())
		if not bool(moved.get("accepted", false)):
			return moved
		var inserted: Dictionary = inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(equipment, ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command())
		replacement_box.append(inserted)
		return inserted)
	var replacement_item := int(replacement_result.get("new_item_id", 0))
	var replacement_record := _first_grant_record(
		adapter.source_for_native_item(replacement_item))
	var replacement_order := native_order.slice(order_start)
	check(not replacement_box.is_empty() and replacement_item > 0
		and int(replacement_record.get("spec", 0))
			!= int(old_replacement_record.get("spec", 0))
		and port.grant_record_is_live(replacement_record)
		and port.grant_record_is_absent(old_replacement_record),
		"full after-state replacement owns a distinct exact spec")
	check(replacement_order.find("grant") >= 0
		and replacement_order.find("revoke") > replacement_order.find("grant")
		and replacement_order.rfind("adapter") > replacement_order.find("revoke"),
		"replacement executes native grant then revoke and publishes only afterward")
	var replacement_hints := adapter.current_outcome().get(
		"result_hints", {}) as Dictionary
	check(int(replacement_hints.get("accepted_edges", -1)) == 2
		and int(replacement_hints.get("invalid_edges", -1)) == 0
		and int(replacement_hints.get("hint_successor", -1))
			== adapter.current_revision()
		and int(replacement_hints.get("maximum_successor", -1))
			== adapter.current_revision(),
		"two accepted replacement deltas chain deterministically before the full pull")

	# Directly retained production port rejects grant reentry while the native
	# ability_granted signal fires before passive activation completes.
	var reentrant_results: Array[Dictionary] = []
	var reentrant_plan := (ZerkovEquipmentAbilityContent.declaration_for_item(
		ZerkovEquipmentAbilityContent.ITEM_MACHETE)["ability_grants"] as Array)[0] \
		as Dictionary
	reentrant_plan = reentrant_plan.duplicate(true)
	reentrant_plan["input_id"] = "reentrant.direct.port"
	var reentry_callback := func(grant_record: Dictionary):
		if StringName(grant_record.get("ability_identifier", &"")) \
				== ZerkovEquipmentAbilityContent.ABILITY_MACHETE_EQUIPPED \
				and reentrant_results.is_empty():
			reentrant_results.append(port.grant(reentrant_plan, adapter.current_tick()))
	component.ability_granted.connect(reentry_callback)
	var machete_result := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			inventory_id, String(ZerkovInventoryCatalog.ITEM_MACHETE), 1,
			_slot(equipment, ZerkovEquipmentAbilityContent.SLOT_MELEE),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	component.ability_granted.disconnect(reentry_callback)
	check(bool(machete_result.get("accepted", false))
		and reentrant_results.size() == 1
		and reentrant_results[0].get("reason", &"")
			== &"equipment_ability_port_reentrant"
		and adapter.current_sources().size() == 2,
		"port mutation guard rejects signal reentry without harming adapter grant")

	check(not publications_read_only.has(false),
		"every adapter reconciliation publication is recursively read-only")
	_cleanup_fixture(fixture)
	await process_frame


func _test_binding_trust_boundaries() -> void:
	var lookalike := _build_inventory_catalog_without_mapping()
	var catalog_fixture := _build_fixture("catalog_mismatch", lookalike, false)
	if not catalog_fixture.is_empty():
		var catalog_adapter := catalog_fixture["adapter"] as InventoryAbilityAdapter
		check(catalog_adapter.last_error == &"inventory_catalog_manifest_mismatch"
			and (catalog_fixture["component"] as GameplayAbilityComponent)
				.granted_specs().is_empty(),
			"sealed same-resource catalog without integration mapping is rejected")
		_cleanup_fixture(catalog_fixture)

	var wrong_entity_fixture := _build_fixture("wrong_entity", null, false, 7_202)
	if not wrong_entity_fixture.is_empty():
		var wrong_adapter := wrong_entity_fixture["adapter"] as InventoryAbilityAdapter
		check(wrong_adapter.last_error == &"equipment_ability_actor_mismatch"
			and (wrong_entity_fixture["component"] as GameplayAbilityComponent)
				.granted_specs().is_empty(),
			"inventory actor cannot bind a different authoritative component entity")
		_cleanup_fixture(wrong_entity_fixture)

	var altered_mapping := _build_inventory_catalog_with_mapping(
		PackedByteArray([0x61, 0x6c, 0x74, 0x65, 0x72, 0x65, 0x64]))
	var altered_fixture := _build_fixture(
		"catalog_altered", altered_mapping, false)
	if not altered_fixture.is_empty():
		check((altered_fixture["adapter"] as InventoryAbilityAdapter).last_error
			== &"inventory_catalog_manifest_mismatch"
			and (altered_fixture["component"] as GameplayAbilityComponent)
				.granted_specs().is_empty(),
			"sealed catalog with altered integration bytes is rejected")
		_cleanup_fixture(altered_fixture)

	var wrong_policy_fixture := _build_fixture(
		"wrong_ability_policy", null, false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"real", false,
		_build_wrong_policy_catalog())
	if not wrong_policy_fixture.is_empty():
		check((wrong_policy_fixture["adapter"] as InventoryAbilityAdapter).last_error
			== &"equipment_ability_semantics_mismatch"
			and (wrong_policy_fixture["component"] as GameplayAbilityComponent)
				.granted_specs().is_empty(),
			"same ability identifiers with ends_on_commit=true fail closed at bind")
		var wrong_component := wrong_policy_fixture["component"] \
			as GameplayAbilityComponent
		var bad_grant: Dictionary = wrong_component.grant_ability(
			String(ZerkovEquipmentAbilityContent.ABILITY_AKM_EQUIPPED), 1,
			"contract.wrong.ends_on_commit", wrong_component.get_current_tick())
		var bad_spec := int(bad_grant.get("spec", 0))
		check(bool((bad_grant.get("status", {}) as Dictionary).get("ok", false))
			and bad_spec > 0
			and wrong_component.active_executions().is_empty()
			and wrong_component.active_effect_handles().size() == 1,
			"real wrong-policy grant commits an effect after its execution ends")
		var bad_revoke: Dictionary = wrong_component.revoke_ability(
			bad_spec, wrong_component.get_current_tick(),
			GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
		check(bool((bad_revoke.get("status", {}) as Dictionary).get("ok", false))
			and wrong_component.active_effect_handles().size() == 1
			and wrong_component.has_tag_exact(String(
				ZerkovEquipmentAbilityContent.TAG_AKM_EQUIPPED))
			and is_equal_approx(wrong_component.get_attribute_current(String(
				ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)), 1.0),
			"real revoke cannot remove the ended execution's orphan effect/tag/modifier")
		wrong_component.queue_teardown(wrong_component.get_current_tick())
		check(wrong_component.is_torn_down()
			and wrong_component.active_effect_handles().size() == 1
			and wrong_component.has_tag_exact(String(
				ZerkovEquipmentAbilityContent.TAG_AKM_EQUIPPED))
			and is_equal_approx(wrong_component.get_attribute_current(String(
				ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)), 1.0),
			"even owner teardown cannot reclaim the non-execution-owned orphan")
		_cleanup_fixture(wrong_policy_fixture)

	var one_micro_fixture := _build_fixture(
		"one_micro_semantics", null, false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"real", false,
		_build_one_micro_mismatch_catalog())
	if not one_micro_fixture.is_empty():
		check((one_micro_fixture["adapter"] as InventoryAbilityAdapter).last_error
			== &"equipment_ability_semantics_mismatch",
			"one authoritative fixed-point micro of modifier drift is rejected")
		_cleanup_fixture(one_micro_fixture)

	var repaired_resource_fixture := _build_fixture(
		"configured_wrong_then_repaired", null, false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"real", false,
		_build_wrong_policy_catalog(),
		Callable(self, "_restore_akm_policy_after_configure"))
	if not repaired_resource_fixture.is_empty():
		check((repaired_resource_fixture["adapter"] as InventoryAbilityAdapter).last_error
			== &"ability_catalog_changed_after_configure"
			and (repaired_resource_fixture["component"] as GameplayAbilityComponent)
				.granted_specs().is_empty(),
			"post-config Resource repair cannot disguise different sealed native semantics")
		_cleanup_fixture(repaired_resource_fixture)

	var duplicate_registration := _build_fixture(
		"duplicate_handler", null, false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"real", true)
	if not duplicate_registration.is_empty():
		var duplicate_raid := duplicate_registration["raid"] as RaidAuthority
		var duplicate_adapter := duplicate_registration["adapter"] as InventoryAbilityAdapter
		var duplicate_owner := duplicate_registration["owner"] as RaidInventoryOwner
		check(duplicate_adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.UNBOUND
			and duplicate_adapter.last_error == &"handler_id_duplicate",
			"duplicate phase registration fully resets the half-bound adapter")
		check(duplicate_raid.transition(
			RaidAuthority.Lifecycle.ACTIVE, duplicate_raid.generation()),
			"duplicate-registration raid activates with its original handler")
		var duplicate_insert := _advance_action(
			duplicate_registration, func() -> Dictionary:
				return duplicate_owner.raid_authority().insert_item(
					duplicate_owner.raid_player_inventory_id,
					String(ZerkovInventoryCatalog.ITEM_AKM), 1,
					_slot(int(duplicate_registration["equipment"]),
						ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
					RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		check(bool(duplicate_insert.get("accepted", false))
			and (duplicate_registration["component"] as GameplayAbilityComponent)
				.granted_specs().is_empty(),
			"failed registration leaves no inventory callback or ability mutation")
		_cleanup_fixture(duplicate_registration)

	var repoint_fixture := _build_fixture("identity_repoint")
	if repoint_fixture.is_empty():
		return
	var repoint_owner := repoint_fixture["owner"] as RaidInventoryOwner
	var repoint_inventory := repoint_owner.raid_authority()
	var repoint_adapter := repoint_fixture["adapter"] as InventoryAbilityAdapter
	var repoint_component := repoint_fixture["component"] as GameplayAbilityComponent
	var identity := repoint_fixture["identity"] as ContractIdentityPort
	check((repoint_fixture["raid"] as RaidAuthority).transition(
		RaidAuthority.Lifecycle.ACTIVE,
		(repoint_fixture["raid"] as RaidAuthority).generation()),
		"identity-repoint raid activates")
	var inserted := _advance_action(repoint_fixture, func() -> Dictionary:
		return repoint_inventory.insert_item(
			repoint_owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(repoint_fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(inserted.get("accepted", false))
		and repoint_component.active_effect_handles().size() == 1,
		"identity-repoint fixture starts with one real owned effect")
	identity.native_actor = 7_202
	check(_advance(repoint_fixture)
		and repoint_adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED
		and repoint_component.active_effect_handles().is_empty()
		and is_zero_approx(repoint_component.get_attribute_current(
			String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"identity repoint cleans captured component and invalidates without granting another")
	check(_advance(repoint_fixture),
		"registered phase handler remains an inert success after invalidation")
	_cleanup_fixture(repoint_fixture)
	await process_frame


func _test_lifecycle_orders() -> void:
	var component_first := _build_fixture("component_first")
	if not component_first.is_empty():
		var owner := component_first["owner"] as RaidInventoryOwner
		var component := component_first["component"] as GameplayAbilityComponent
		var adapter := component_first["adapter"] as InventoryAbilityAdapter
		var raid := component_first["raid"] as RaidAuthority
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"component-first raid activates")
		var inserted := _advance_action(component_first, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_AKM), 1,
				_slot(int(component_first["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		check(bool(inserted.get("accepted", false))
			and component.active_effect_handles().size() == 1,
			"component-first fixture grants before teardown")
		component.queue_teardown(adapter.current_tick())
		check(component.active_effect_handles().is_empty()
			and component.active_executions().is_empty(),
			"real component teardown synchronously cancels execution-owned effect")
		check(owner.teardown(owner.generation())
			and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED,
			"component-first then owner teardown uses positive absence proof")
		check(_advance(component_first),
			"component-first invalidated handler remains harmless")
		_cleanup_fixture(component_first, false)

	var owner_first := _build_fixture("owner_first")
	if not owner_first.is_empty():
		var owner := owner_first["owner"] as RaidInventoryOwner
		var component := owner_first["component"] as GameplayAbilityComponent
		var adapter := owner_first["adapter"] as InventoryAbilityAdapter
		var raid := owner_first["raid"] as RaidAuthority
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"owner-first raid activates")
		var inserted := _advance_action(owner_first, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_AKM), 1,
				_slot(int(owner_first["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		check(bool(inserted.get("accepted", false)),
			"owner-first fixture grants before teardown")
		check(owner.teardown(owner.generation())
			and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED
			and component.active_effect_handles().is_empty()
			and component.active_executions().is_empty()
			and is_zero_approx(component.get_attribute_current(
				String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
			"owner-first teardown explicitly revokes exact spec/effect/tag modifier")
		component.queue_teardown(adapter.current_tick())
		check(_advance(owner_first), "owner-first invalidated handler remains harmless")
		_cleanup_fixture(owner_first, false)

	var component_node_exit := _build_fixture("component_node_exit")
	if not component_node_exit.is_empty():
		var owner := component_node_exit["owner"] as RaidInventoryOwner
		var component := component_node_exit["component"] as GameplayAbilityComponent
		var adapter := component_node_exit["adapter"] as InventoryAbilityAdapter
		var raid := component_node_exit["raid"] as RaidAuthority
		var clean_at_publication: Array[bool] = []
		adapter.reconciliation_applied.connect(func(outcome: Dictionary):
			if bool(outcome.get("invalidated", false)):
				clean_at_publication.append(
					component.active_effect_handles().is_empty()
					and component.active_executions().is_empty()
					and is_zero_approx(component.get_attribute_current(String(
						ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)))))
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"component-node-exit raid activates")
		var inserted := _advance_action(component_node_exit, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_AKM), 1,
				_slot(int(component_node_exit["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		check(bool(inserted.get("accepted", false))
			and component.active_effect_handles().size() == 1,
			"component node-exit fixture grants")
		root.remove_child(component)
		check(adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED
			and component.active_effect_handles().is_empty()
			and component.active_executions().is_empty()
			and not component.has_tag_exact(
				String(ZerkovEquipmentAbilityContent.TAG_AKM_EQUIPPED))
			and is_zero_approx(component.get_attribute_current(
				String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)))
			and clean_at_publication == [true],
			"actual component tree exit cleans exact state before invalidation publication")
		check(_advance(component_node_exit),
			"component node-exit leaves a stable inert phase handler")
		check(owner.teardown(owner.generation()),
			"component-node-exit owner tears down later")
		if raid.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
			raid.teardown(raid.generation())
		component.free()
		owner.queue_free()

	var owner_node_exit := _build_fixture("owner_node_exit")
	if not owner_node_exit.is_empty():
		var owner := owner_node_exit["owner"] as RaidInventoryOwner
		var component := owner_node_exit["component"] as GameplayAbilityComponent
		var adapter := owner_node_exit["adapter"] as InventoryAbilityAdapter
		var raid := owner_node_exit["raid"] as RaidAuthority
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"owner-node-exit raid activates")
		var inserted := _advance_action(owner_node_exit, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_AKM), 1,
				_slot(int(owner_node_exit["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		check(bool(inserted.get("accepted", false)), "owner node-exit fixture grants")
		root.remove_child(owner)
		check(adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED
			and component.active_effect_handles().is_empty()
			and component.active_executions().is_empty()
			and is_zero_approx(component.get_attribute_current(
				String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
			"actual owner tree exit revokes before native inventories disappear")
		check(_advance(owner_node_exit),
			"owner node-exit leaves a stable inert phase handler")
		component.queue_teardown(component.get_current_tick())
		if raid.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
			raid.teardown(raid.generation())
		component.queue_free()
		owner.free()
	await process_frame


func _test_declared_destruction_and_external_revoke() -> void:
	var destruction := _build_fixture("declared_destroy")
	if not destruction.is_empty():
		var owner := destruction["owner"] as RaidInventoryOwner
		var raid := destruction["raid"] as RaidAuthority
		var adapter := destruction["adapter"] as InventoryAbilityAdapter
		var component := destruction["component"] as GameplayAbilityComponent
		var port := destruction["port"] as GameplayAbilityEquipmentPort
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"declared-destroy raid activates")
		var inserted := _advance_action(destruction, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_MACHETE), 1,
				_slot(int(destruction["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_MELEE),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		var item_id := int(inserted.get("new_item_id", 0))
		var record := _first_grant_record(adapter.source_for_native_item(item_id))
		var effect := _first_effect_handle(record)
		var removed := _advance_action(destruction, func() -> Dictionary:
			return owner.raid_authority().remove_item(
				owner.raid_player_inventory_id, item_id,
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		check(bool(removed.get("accepted", false))
			and adapter.source_for_native_item(item_id).is_empty()
			and port.grant_record_is_absent(record)
			and component.get_active_effect(effect).is_empty()
			and not component.has_tag_exact(
				String(ZerkovEquipmentAbilityContent.TAG_MACHETE_EQUIPPED))
			and is_zero_approx(component.get_attribute_current(
				String(ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
			"destroying declared equipped item revokes exact spec/effect/tag/modifier/source")
		_cleanup_fixture(destruction)

	var external := _build_fixture("external_revoke")
	if not external.is_empty():
		var owner := external["owner"] as RaidInventoryOwner
		var raid := external["raid"] as RaidAuthority
		var adapter := external["adapter"] as InventoryAbilityAdapter
		var component := external["component"] as GameplayAbilityComponent
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"external-revoke raid activates")
		var inserted := _advance_action(external, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_AKM), 1,
				_slot(int(external["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		var record := _first_grant_record(
			adapter.source_for_native_item(int(inserted.get("new_item_id", 0))))
		var direct: Dictionary = component.revoke_ability(
			int(record.get("spec", 0)), adapter.current_tick(),
			GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
		check(bool((direct.get("status", {}) as Dictionary).get("ok", false)),
			"external actor can invalidate the adapter-owned native spec")
		check(not _advance(external, false)
			and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
			and adapter.current_outcome().get("reason", &"")
				== &"equipment_grant_externally_invalidated"
			and component.active_effect_handles().is_empty()
			and component.active_executions().is_empty(),
			"external revoke fails the phase, latches recovery, and never silently regrants")
		_cleanup_fixture(external)
	await process_frame


func _test_explicit_release_before_raid_terminal() -> void:
	var fixture := _build_fixture("explicit_raid_release")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"explicit-release raid activates")
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(inserted.get("accepted", false))
		and component.active_effect_handles().size() == 1,
		"explicit-release fixture starts with a live equipment effect")
	var released := adapter.prepare_for_raid_terminalization(
		raid, raid.generation(), adapter.current_tick())
	check(released and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED
		and component.active_effect_handles().is_empty()
		and component.active_executions().is_empty()
		and is_zero_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"explicit pre-terminal seam revokes the ability binding before raid terminalization")
	var clean_tick := component.get_current_tick()
	var clean_spec_count := component.granted_specs().size()
	check(raid.transition(RaidAuthority.Lifecycle.SETTLING, raid.generation()) \
		and raid.transition(RaidAuthority.Lifecycle.COMPLETED, raid.generation()) \
		and raid.lifecycle == RaidAuthority.Lifecycle.COMPLETED,
		"raid terminalization follows explicit equipment cleanup")
	check(not adapter.prepare_for_raid_terminalization(
		raid, raid.generation(), adapter.current_tick())
		and adapter.last_error == &"raid_already_terminal"
		and component.get_current_tick() == clean_tick
		and component.granted_specs().size() == clean_spec_count
		and component.active_effect_handles().is_empty()
		and component.active_executions().is_empty()
		and is_zero_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"late pre-terminal callback cannot mutate after RaidAuthority terminalization " \
		+ str({"tick": component.get_current_tick(), "clean_tick": clean_tick,
			"specs": component.granted_specs().size(),
			"effects": component.active_effect_handles().size(),
			"executions": component.active_executions().size(),
			"attribute": component.get_attribute_current(String(
				ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)),
			"adapter_error": adapter.last_error}))
	_cleanup_fixture(fixture)
	await process_frame


func _test_persistence_generation_invalidation() -> void:
	var fixture := _build_fixture("persistence_generation")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"persistence-generation raid activates")
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(inserted.get("accepted", false)) \
		and component.active_effect_handles().size() == 1,
		"persistence-generation fixture starts with a live equipment contribution")
	var record := owner.raid_authority().make_persistence_record(
		owner.raid_player_inventory_id)
	var invalidations: Array[StringName] = []
	adapter.binding_invalidated.connect(func(reason: StringName) -> void:
		invalidations.append(reason))
	var replacement: Dictionary = owner.raid_authority().apply_persistence_record(
		record, true)
	check(bool(replacement.get("ok", false)) \
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.INVALIDATED \
		and invalidations == [&"raid_player_inventory_generation_changing"],
		"same-id persistence generation synchronously invalidates the ability adapter")
	check(component.active_effect_handles().is_empty() \
		and component.active_executions().is_empty() \
		and is_zero_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"ability contributions are revoked before the replacement becomes usable")
	var clean_tick := component.get_current_tick()
	var clean_specs := component.granted_specs().size()
	check(_advance(fixture) \
		and component.get_current_tick() == clean_tick \
		and component.granted_specs().size() == clean_specs \
		and component.active_effect_handles().is_empty(),
		"retained phase callback is a no-op after persistence invalidation")
	_cleanup_fixture(fixture)
	await process_frame


func _test_failure_and_quarantine_contracts() -> void:
	await _run_fault_case("grant_before", &"before", &"", false)
	await _run_fault_case("grant_after", &"after", &"", false)
	await _run_fault_case("revoke_before", &"", &"before", false)
	await _run_fault_case("revoke_after", &"", &"after", false)
	await _run_fault_case("cleanup_blocked", &"after", &"", true)
	await _run_adapter_quarantine_success_case()
	await _run_lingering_contribution_case()
	await _run_lifecycle_partial_revoke_case()
	await _run_recovery_retry_partial_revoke_case()
	await _run_replacement_fault_case("replacement_grant_after", true)
	await _run_replacement_fault_case("replacement_revoke_before", false)

	var unavailable_fixture := _build_fixture(
		"unready_unproven", null, true,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if not unavailable_fixture.is_empty():
		var owner := unavailable_fixture["owner"] as RaidInventoryOwner
		var raid := unavailable_fixture["raid"] as RaidAuthority
		var adapter := unavailable_fixture["adapter"] as InventoryAbilityAdapter
		var component := unavailable_fixture["component"] as GameplayAbilityComponent
		var fault := unavailable_fixture["port"] as FaultPort
		var native_port := unavailable_fixture["native_port"] \
			as GameplayAbilityEquipmentPort
		check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
			"unready-unproven raid activates")
		var inserted := _advance_action(unavailable_fixture, func() -> Dictionary:
			return owner.raid_authority().insert_item(
				owner.raid_player_inventory_id,
				String(ZerkovInventoryCatalog.ITEM_AKM), 1,
				_slot(int(unavailable_fixture["equipment"]),
					ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		var record := _first_grant_record(
			adapter.source_for_native_item(int(inserted.get("new_item_id", 0))))
		fault.unavailable = true
		fault.block_revoke = true
		fault.block_quarantine = true
		check(owner.teardown(owner.generation())
			and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
			and adapter.current_outcome().get("reason", &"")
				== &"ability_component_cleanup_unproven"
			and component.active_effect_handles().size() == 1
			and not (adapter.current_outcome().get("details", {}) as Dictionary)
				.get("unresolved_records", []).is_empty(),
			"generic unready port cannot pretend a live record was terminally cleaned")
		fault.unavailable = false
		fault.block_revoke = false
		fault.block_quarantine = false
		var cleanup := native_port.quarantine([record], component.get_current_tick())
		check(bool(cleanup.get("accepted", false))
			and component.active_effect_handles().is_empty(),
			"test fixture explicitly quarantines its intentionally leaked native state")
		_cleanup_fixture(unavailable_fixture, false)
	await process_frame


func _run_adapter_quarantine_success_case() -> void:
	var fixture := _build_fixture(
		"adapter_quarantine_success", null, true,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var fault := fixture["port"] as FaultPort
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"adapter-quarantine raid activates")
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	fault.block_revoke = true
	var removed := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().move_item(
			owner.raid_player_inventory_id,
			int(inserted.get("new_item_id", 0)),
			_spatial(int(fixture["backpack"]), 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()), false)
	var details := adapter.current_outcome().get("details", {}) as Dictionary
	var quarantine_result := details.get("quarantine_result", {}) as Dictionary
	check(bool(removed.get("accepted", false))
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED
		and bool(quarantine_result.get("accepted", false))
		and (details.get("unresolved_records", []) as Array).is_empty()
		and component.is_torn_down() and not component.is_owner_valid()
		and component.active_effect_handles().is_empty()
		and component.active_executions().is_empty()
		and is_zero_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"adapter invokes terminal native quarantine when per-spec revoke stays blocked")
	_cleanup_fixture(fixture)
	await process_frame


func _run_lingering_contribution_case() -> void:
	var fixture := _build_fixture(
		"lingering_contribution", null, true,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var fault := fixture["port"] as FaultPort
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"lingering-contribution raid activates")
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	var record := _first_grant_record(adapter.source_for_native_item(
		int(inserted.get("new_item_id", 0))))
	fault.revoke_fault = &"after"
	fault.simulated_lingering_modifier_micros = \
		ZerkovEquipmentAbilityContent.MODIFIER_READY_COUNT_MICROS
	fault.simulated_lingering_tag = true
	fault.block_quarantine = true
	_advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().move_item(
			owner.raid_player_inventory_id,
			int(inserted.get("new_item_id", 0)),
			_spatial(int(fixture["backpack"]), 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()), false)
	var details := adapter.current_outcome().get("details", {}) as Dictionary
	var unresolved := details.get("unresolved_records", []) as Array
	var partial_revoke_record := _first_partial_revoke_record(unresolved)
	check(fault.grant_record_is_absent(record)
		and not partial_revoke_record.is_empty()
		and not fault.recovery_record_is_clean(partial_revoke_record)
		and bool(fault.lingering_native_grant.get("accepted", false))
		and component.active_effect_handles().size() == 1
		and component.has_tag_exact(String(
			ZerkovEquipmentAbilityContent.TAG_AKM_EQUIPPED))
		and is_equal_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)), 1.0)
		and fault.simulated_lingering_modifier_micros
			== ZerkovEquipmentAbilityContent.MODIFIER_READY_COUNT_MICROS
		and fault.simulated_lingering_tag
		and not unresolved.is_empty()
		and not bool((details.get("quarantine_result", {}) as Dictionary)
			.get("accepted", false))
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED,
		"absent spec/handles cannot hide an ambiguous lingering modifier or tag")
	fault.block_quarantine = false
	var cleanup := fault.quarantine([record], component.get_current_tick())
	check(bool(cleanup.get("accepted", false))
		and fault.simulated_lingering_modifier_micros == 0
		and not fault.simulated_lingering_tag
		and component.active_effect_handles().is_empty()
		and is_zero_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		"terminal quarantine explicitly clears the simulated ambiguous contribution")
	_cleanup_fixture(fixture, false)
	await process_frame


func _run_lifecycle_partial_revoke_case() -> void:
	var fixture := _build_fixture(
		"lifecycle_partial_revoke", null, true,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var fault := fixture["port"] as FaultPort
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"lifecycle partial-revoke raid activates")
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	fault.revoke_fault = &"after"
	fault.simulated_lingering_modifier_micros = \
		ZerkovEquipmentAbilityContent.MODIFIER_READY_COUNT_MICROS
	fault.simulated_lingering_tag = true
	check(bool(inserted.get("accepted", false))
		and owner.teardown(owner.generation())
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED,
		"lifecycle partial revoke enters fail-stop recovery")
	var details := adapter.current_outcome().get("details", {}) as Dictionary
	check(fault.quarantine_calls == 1
		and not _first_partial_revoke_record(fault.last_quarantine_records).is_empty()
		and bool((details.get("quarantine_result", {}) as Dictionary)
			.get("accepted", false))
		and (details.get("unresolved_records", []) as Array).is_empty()
		and bool(fault.lingering_native_grant.get("accepted", false))
		and fault.simulated_lingering_modifier_micros == 0
		and not fault.simulated_lingering_tag
		and component.is_torn_down() and not component.is_owner_valid()
		and component.active_effect_handles().is_empty(),
		"lifecycle cleanup unions partial-revoke provenance before quarantine")
	check(not _advance(fixture, false)
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED,
		"lifecycle partial-revoke recovery fails the registered raid phase")
	_cleanup_fixture(fixture, false)
	await process_frame


func _run_recovery_retry_partial_revoke_case() -> void:
	var fixture := _build_fixture(
		"recovery_retry_partial_revoke", null, true,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var fault := fixture["port"] as FaultPort
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"recovery-retry partial-revoke raid activates")
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	fault.preflight_fault = true
	fault.revoke_fault = &"after"
	fault.simulated_lingering_modifier_micros = \
		ZerkovEquipmentAbilityContent.MODIFIER_READY_COUNT_MICROS
	fault.simulated_lingering_tag = true
	var unrelated := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_RIG_BASIC), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_RIG),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()), false)
	var details := adapter.current_outcome().get("details", {}) as Dictionary
	check(bool(inserted.get("accepted", false))
		and bool(unrelated.get("accepted", false))
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED,
		"preflight recovery invokes an ambiguous revoke retry and fails the raid")
	check(fault.quarantine_calls == 1
		and not _first_partial_revoke_record(fault.last_quarantine_records).is_empty()
		and bool((details.get("quarantine_result", {}) as Dictionary)
			.get("accepted", false))
		and (details.get("unresolved_records", []) as Array).is_empty()
		and bool(fault.lingering_native_grant.get("accepted", false))
		and fault.simulated_lingering_modifier_micros == 0
		and not fault.simulated_lingering_tag
		and component.is_torn_down() and not component.is_owner_valid()
		and component.active_effect_handles().is_empty(),
		"recovery retry unions its partial-revoke record before terminal quarantine")
	_cleanup_fixture(fixture)
	await process_frame


func _run_replacement_fault_case(label: String, fail_new_grant_after: bool) -> void:
	var fixture := _build_fixture(
		label, null, true, RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var fault := fixture["port"] as FaultPort
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		label + " raid activates")
	var old_insert := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	var melee_insert := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_MACHETE), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_MELEE),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(old_insert.get("accepted", false))
		and bool(melee_insert.get("accepted", false))
		and adapter.current_sources().size() == 2
		and component.active_effect_handles().size() == 2,
		label + " starts with two adapter-owned active contributors")
	var foreign_spec := 0
	if fail_new_grant_after:
		var foreign: Dictionary = component.grant_ability(
			String(ZerkovEquipmentAbilityContent.ABILITY_AKM_EQUIPPED), 1,
			"foreign." + label, adapter.current_tick())
		foreign_spec = int(foreign.get("spec", 0))
		check(bool((foreign.get("status", {}) as Dictionary).get("ok", false)),
			label + " adds an isolated foreign same-attribute contributor")
	var revision_before := adapter.current_revision()
	var successful_publications: Array[Dictionary] = []
	adapter.reconciliation_applied.connect(func(outcome: Dictionary):
		if bool(outcome.get("accepted", false)):
			successful_publications.append(outcome.duplicate(true)))
	var native_grants: Array[int] = [0]
	component.ability_granted.connect(func(_record: Dictionary):
		native_grants[0] += 1)
	if fail_new_grant_after:
		fault.grant_fault = &"after"
	else:
		fault.revoke_fault = &"before"
	var replacement_results: Array[Dictionary] = []
	var replacement := _advance_action(fixture, func() -> Dictionary:
		var moved: Dictionary = owner.raid_authority().move_item(
			owner.raid_player_inventory_id,
			int(old_insert.get("new_item_id", 0)),
			_spatial(int(fixture["backpack"]), 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command())
		if not bool(moved.get("accepted", false)):
			return moved
		var inserted: Dictionary = owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command())
		replacement_results.append(inserted)
		return inserted, false)
	var details := adapter.current_outcome().get("details", {}) as Dictionary
	var unresolved := details.get("unresolved_records", []) as Array
	var quarantine_result := details.get("quarantine_result", {}) as Dictionary
	var expected_live_effects := 1 if foreign_spec > 0 else 0
	check(bool(replacement.get("accepted", false))
		and not replacement_results.is_empty()
		and adapter.current_revision() == revision_before
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED
		and successful_publications.is_empty()
		and native_grants[0] == 1
		and unresolved.is_empty()
		and int(details.get("owned_record_count", 0)) >= 3
		and component.active_effect_handles().size() == expected_live_effects
		and component.active_executions().size() == expected_live_effects,
		label + " accounts old/new/two-active records without a false success claim")
	if foreign_spec > 0:
		check(quarantine_result.is_empty() and not component.is_torn_down()
			and not bool(component.get_grant(foreign_spec).get("revoked", true))
			and is_equal_approx(component.get_attribute_current(String(
				ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT)), 1.0),
			label + " proves the partial record before ordinary cleanup and preserves foreign state")
		component.revoke_ability(foreign_spec, component.get_current_tick(),
			GameplayAbilityComponent.PROVENANCE_AUTHORITATIVE)
	else:
		check(bool(quarantine_result.get("accepted", false))
			and component.is_torn_down() and not component.is_owner_valid(),
			label + " conservatively quarantines when boolean tag counts cannot prove cleanup")
	check(component.active_effect_handles().is_empty()
		and component.active_executions().is_empty()
		and is_zero_approx(component.get_attribute_current(String(
			ZerkovEquipmentAbilityContent.ATTRIBUTE_READIED_WEAPON_COUNT))),
		label + " leaves no unaccounted live native equipment state")
	_cleanup_fixture(fixture)
	await process_frame


func _run_fault_case(
	label: String,
	grant_fault: StringName,
	revoke_fault: StringName,
	block_cleanup: bool
) -> void:
	var fixture := _build_fixture(
		"fault_" + label, null, true,
		RaidInventoryOwner.FIXTURE_ACTOR_ID, &"fault")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var fault := fixture["port"] as FaultPort
	var native_port := fixture["native_port"] as GameplayAbilityEquipmentPort
	var recovery_signals: Array[StringName] = []
	adapter.recovery_latched.connect(func(reason: StringName, _details: Dictionary):
		recovery_signals.append(reason))
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		label + " fault raid activates")
	fault.grant_fault = grant_fault
	fault.block_revoke = block_cleanup
	fault.block_quarantine = block_cleanup
	var inserted := _advance_action(fixture, func() -> Dictionary:
		return owner.raid_authority().insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()),
		grant_fault.is_empty())
	var record: Dictionary = {}
	if grant_fault.is_empty():
		record = _first_grant_record(
			adapter.source_for_native_item(int(inserted.get("new_item_id", 0))))
		fault.revoke_fault = revoke_fault
		fault.block_revoke = block_cleanup
		fault.block_quarantine = block_cleanup
		_advance_action(fixture, func() -> Dictionary:
			return owner.raid_authority().move_item(
				owner.raid_player_inventory_id,
				int(inserted.get("new_item_id", 0)),
				_spatial(int(fixture["backpack"]), 0, 0),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()), false)
	check(adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
		and recovery_signals.size() == 1
		and raid.lifecycle == RaidAuthority.Lifecycle.FAILED,
		label + " unexpected native boundary failure latches and fails phase once")
	var details := adapter.current_outcome().get("details", {}) as Dictionary
	var unresolved := details.get("unresolved_records", []) as Array
	if block_cleanup:
		check(not unresolved.is_empty()
			and component.active_effect_handles().size() == 1
			and not bool((details.get("quarantine_result", {}) as Dictionary)
				.get("accepted", false)),
			label + " exposes ambiguous live state when cleanup and quarantine fail")
		if record.is_empty() and not unresolved.is_empty():
			record = (unresolved[0] as Dictionary).duplicate(true)
		fault.block_revoke = false
		fault.block_quarantine = false
		var terminal_cleanup := native_port.quarantine(
			[record], component.get_current_tick())
		check(bool(terminal_cleanup.get("accepted", false))
			and component.active_effect_handles().is_empty()
			and component.active_executions().is_empty(),
			label + " manual test cleanup proves no leaked real native state")
	else:
		check(unresolved.is_empty()
			and component.active_effect_handles().is_empty()
			and component.active_executions().is_empty(),
			label + " recovery accounts for and cleans every native record")
	_cleanup_fixture(fixture)
	await process_frame


func _test_grant_history_capacity() -> void:
	var fixture := _build_fixture("capacity")
	if fixture.is_empty():
		return
	var owner := fixture["owner"] as RaidInventoryOwner
	var raid := fixture["raid"] as RaidAuthority
	var adapter := fixture["adapter"] as InventoryAbilityAdapter
	var component := fixture["component"] as GameplayAbilityComponent
	var inventory := owner.raid_authority()
	check(raid.transition(RaidAuthority.Lifecycle.ACTIVE, raid.generation()),
		"capacity raid activates")
	var insert := _advance_action(fixture, func() -> Dictionary:
		return inventory.insert_item(
			owner.raid_player_inventory_id,
			String(ZerkovInventoryCatalog.ITEM_AKM), 1,
			_slot(int(fixture["equipment"]),
				ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	var item_id := int(insert.get("new_item_id", 0))
	check(item_id > 0, "capacity fixture starts with one canonical item")
	for cycle in range(GameplayAbilityEquipmentPort.MAX_ABILITY_GRANTS - 1):
		var moved := _advance_action(fixture, func() -> Dictionary:
			return inventory.move_item(
				owner.raid_player_inventory_id, item_id,
				_spatial(int(fixture["backpack"]), 0, 0),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		var equipped := _advance_action(fixture, func() -> Dictionary:
			return inventory.equip_item(
				owner.raid_player_inventory_id, item_id,
				int(fixture["equipment"]),
				String(ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
				RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
		if not bool(moved.get("accepted", false)) \
				or not bool(equipped.get("accepted", false)):
			check(false, "capacity churn cycle %d commits" % cycle)
			break
	check(component.granted_specs().size()
		== GameplayAbilityEquipmentPort.MAX_ABILITY_GRANTS
		and component.active_effect_handles().size() == 1,
		"64 grant/revoke histories expose the native tombstone capacity honestly")
	var final_move := _advance_action(fixture, func() -> Dictionary:
		return inventory.move_item(
			owner.raid_player_inventory_id, item_id,
			_spatial(int(fixture["backpack"]), 0, 0),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()))
	check(bool(final_move.get("accepted", false))
		and component.active_effect_handles().is_empty(),
		"64th live grant can still revoke before capacity boundary")
	var failed_re_equip := _advance_action(fixture, func() -> Dictionary:
		return inventory.equip_item(
			owner.raid_player_inventory_id, item_id,
			int(fixture["equipment"]),
			String(ZerkovEquipmentAbilityContent.SLOT_PRIMARY),
			RaidInventoryOwner.FIXTURE_ACTOR_ID, _next_command()), false)
	check(bool(failed_re_equip.get("accepted", false))
		and adapter.lifecycle == InventoryAbilityAdapter.Lifecycle.RECOVERY_REQUIRED
		and adapter.current_outcome().get("reason", &"")
			== &"equipment_ability_grant_capacity"
		and component.granted_specs().size()
			== GameplayAbilityEquipmentPort.MAX_ABILITY_GRANTS
		and component.active_effect_handles().is_empty(),
		"65th re-equip fails in preflight, latches recovery, and leaves no live effect")
	_cleanup_fixture(fixture)
	await process_frame


func _build_fixture(
	label: String,
	inventory_catalog: InventoryCatalog = null,
	expect_bind: bool = true,
	component_entity_id: int = RaidInventoryOwner.FIXTURE_ACTOR_ID,
	participant_kind: StringName = &"real",
	occupy_adapter_handler: bool = false,
	ability_catalog: GameplayDefinitionCatalog = null,
	post_configure_mutation: Callable = Callable()
) -> Dictionary:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["ability", label]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, StringName(label + "_profile"), &"player")
	check(admission != null and admission.is_usable(), label + " admission is usable")
	var owner := RaidInventoryOwner.new()
	owner.name = "InventoryAbilityOwner_" + label
	root.add_child(owner)
	check(owner.configure(inventory_catalog), label + " inventory owner configures")
	if owner.lifecycle != RaidInventoryOwner.Lifecycle.ACTIVE:
		return {}
	var raid := RaidAuthority.new()
	check(raid.configure(raid_id, admission, 901), label + " raid authority configures")
	var raid_key := raid.get_instance_id()
	_phase_actions[raid_key] = []
	check(raid.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"inventory_ability_mutator",
		Callable(self, "_inventory_phase_handler"),
		raid.generation()), label + " phase-5 inventory mutator registers")
	if occupy_adapter_handler:
		check(raid.register_phase_handler(
			RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
			InventoryAbilityAdapter.DEFAULT_PHASE_HANDLER_ID,
			Callable(self, "_noop_phase_handler"),
			raid.generation()), label + " duplicate phase id fixture registers")

	var component := GameplayAbilityComponent.new()
	component.name = "InventoryAbilityComponent_" + label
	component.role = GameplayAbilityComponent.ROLE_OFFLINE_AUTHORITY
	component.entity_id = component_entity_id
	component.definition_catalog = ability_catalog if ability_catalog != null \
		else _build_combined_equipment_catalog()
	root.add_child(component)
	var findings: Array = component.configure()
	check(GameplayDefinitionValidator.is_ok(findings)
		and component.is_configured()
		and component.get_content_manifest_fingerprint() != 0,
		label + " real gameplay component configures")
	if post_configure_mutation.is_valid():
		post_configure_mutation.call(component)
	var initialization := ZerkovEquipmentAbilityContent.initialize_component(component, 0)
	check(bool(initialization.get("accepted", false)),
		label + " equipment attribute initializes")
	var port := GameplayAbilityEquipmentPort.new()
	check(port.configure(component), label + " production ability port configures")
	var participant: EquipmentAbilityParticipantPort = port
	if participant_kind == &"fault":
		var fault := FaultPort.new()
		fault.inner = port
		participant = fault
	var identity := ContractIdentityPort.new()
	identity.session_key = admission.session_id.canonical_key()
	identity.actor_key = admission.actor_id.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.inventory_id = owner.raid_player_inventory_id
	var adapter := InventoryAbilityAdapter.new()
	var bound := adapter.bind_owner(
		owner, admission, identity, participant, raid, owner.generation(), 0)
	check(bound == expect_bind, label + " adapter bind expectation")

	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	return {
		"owner": owner,
		"raid": raid,
		"admission": admission,
		"component": component,
		"port": participant,
		"native_port": port,
		"identity": identity,
		"adapter": adapter,
		"equipment": _root_container(snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT),
		"pockets": _root_container(snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS),
		"rig": _root_container(snapshot, ZerkovInventoryCatalog.CONTAINER_RIG),
		"backpack": _root_container(snapshot, ZerkovInventoryCatalog.CONTAINER_BACKPACK),
	}


func _inventory_phase_handler(
	raid: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	_tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	var key := raid.get_instance_id()
	var actions := _phase_actions.get(key, []) as Array
	if actions.is_empty():
		return true
	var action := actions.pop_front() as Callable
	_phase_actions[key] = actions
	_phase_results[key] = action.call()
	return true


func _noop_phase_handler(
	_raid: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	_tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	return true


func _advance(fixture: Dictionary, expect_success: bool = true) -> bool:
	var raid := fixture["raid"] as RaidAuthority
	var result := raid.advance_one(raid.generation())
	check(result == expect_success,
		"raid tick success expectation at tick %d" % (raid.last_processed_tick + 1))
	return result


func _advance_action(
	fixture: Dictionary,
	action: Callable,
	expect_tick_success: bool = true
) -> Dictionary:
	var raid := fixture["raid"] as RaidAuthority
	var key := raid.get_instance_id()
	var actions := _phase_actions.get(key, []) as Array
	actions.append(action)
	_phase_actions[key] = actions
	_phase_results.erase(key)
	_advance(fixture, expect_tick_success)
	return (_phase_results.get(key, {}) as Dictionary).duplicate(true)


func _cleanup_fixture(fixture: Dictionary, teardown_owner: bool = true) -> void:
	if fixture.is_empty():
		return
	var raid := fixture.get("raid") as RaidAuthority
	var owner := fixture.get("owner") as RaidInventoryOwner
	var component := fixture.get("component") as GameplayAbilityComponent
	var adapter := fixture.get("adapter") as InventoryAbilityAdapter
	if teardown_owner and owner != null \
			and owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
		owner.teardown(owner.generation())
	if component != null and is_instance_valid(component) and not component.is_torn_down():
		component.queue_teardown(
			mini(ZerkovEquipmentAbilityContent.MAX_AUTHORITY_TICK,
				maxi(component.get_current_tick(), adapter.current_tick())))
	if raid != null and raid.lifecycle != RaidAuthority.Lifecycle.TORN_DOWN:
		raid.teardown(raid.generation())
	if component != null and is_instance_valid(component):
		component.queue_free()
	if owner != null and is_instance_valid(owner):
		owner.queue_free()
	_phase_actions.erase(raid.get_instance_id() if raid != null else 0)
	_phase_results.erase(raid.get_instance_id() if raid != null else 0)


func _build_inventory_catalog_without_mapping() -> InventoryCatalog:
	return _build_inventory_catalog_with_mapping(PackedByteArray(), false)


func _build_combined_equipment_catalog() -> GameplayDefinitionCatalog:
	var catalog := ZerkovEquipmentAbilityContent.build_definition_catalog()
	var extra_tag := GameplayTagDefinition.new()
	extra_tag.identifier = &"zerkov.tag.contract.combined_extra"
	extra_tag.description = "Unrelated combined-catalog definition."
	extra_tag.source_label = "Zerkov contract combined content"
	var tags: Array[GameplayTagDefinition] = []
	for value in catalog.get_tag_definitions():
		tags.append(value as GameplayTagDefinition)
	tags.append(extra_tag)
	catalog.tag_definitions = tags
	return catalog


func _build_wrong_policy_catalog() -> GameplayDefinitionCatalog:
	var catalog := _build_combined_equipment_catalog()
	for value in catalog.get_ability_definitions():
		var ability := value as GameplayAbilityDefinition
		if ability.get_identifier() \
				== ZerkovEquipmentAbilityContent.ABILITY_AKM_EQUIPPED:
			ability.ends_on_commit = true
	return catalog


func _build_one_micro_mismatch_catalog() -> GameplayDefinitionCatalog:
	var catalog := _build_combined_equipment_catalog()
	for value in catalog.get_effect_definitions():
		var effect := value as GameplayEffectDefinition
		if effect.get_identifier() != ZerkovEquipmentAbilityContent.EFFECT_AKM_EQUIPPED:
			continue
		var modifiers: Array = effect.get_modifiers()
		if not modifiers.is_empty():
			var modifier := modifiers[0] as GameplayModifierDeclaration
			modifier.get_magnitude().coefficient = 1.000001
	return catalog


func _restore_akm_policy_after_configure(component: GameplayAbilityComponent) -> void:
	var catalog := component.get_definition_catalog()
	if catalog == null:
		return
	for value in catalog.get_ability_definitions():
		var ability := value as GameplayAbilityDefinition
		if ability.get_identifier() \
				== ZerkovEquipmentAbilityContent.ABILITY_AKM_EQUIPPED:
			ability.ends_on_commit = false


func _build_inventory_catalog_with_mapping(
	mapping_bytes: PackedByteArray,
	register_mapping: bool = true
) -> InventoryCatalog:
	var catalog := InventoryCatalog.new()
	var builtins: Dictionary = catalog.register_builtin_definitions()
	if int(builtins.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
		return null
	var resource := ZerkovInventoryCatalog.build_resource()
	for finding_value in catalog.validate_resource(resource):
		if int((finding_value as Dictionary).get("status_code", -1)) \
				!= InventoryCatalog.STATUS_OK:
			return null
	for finding_value in catalog.register_catalog_resource(resource):
		if int((finding_value as Dictionary).get("status_code", -1)) \
				!= InventoryCatalog.STATUS_OK:
			return null
	if register_mapping:
		var mapping_result: Dictionary = catalog.register_integration_mapping(
			String(ZerkovEquipmentAbilityContent.INTEGRATION_MAPPING_ID),
			mapping_bytes,
			"res://tests/raid/inventory_ability_reconciliation_contract.gd")
		if int(mapping_result.get("status_code", -1)) != InventoryCatalog.STATUS_OK:
			return null
	var sealed: Dictionary = catalog.seal()
	return catalog if int(sealed.get("status_code", -1)) \
		== InventoryCatalog.STATUS_OK else null


func _root_container(
	snapshot: InventorySnapshotResource,
	definition_identifier: StringName
) -> int:
	if snapshot == null:
		return 0
	for value in snapshot.get_containers():
		var container := value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get(
					"container_definition_identifier", &"")) == definition_identifier:
			return int(container.get("id", 0))
	return 0


func _provided_container(snapshot: InventorySnapshotResource, provider_item: int) -> int:
	if snapshot == null:
		return 0
	for value in snapshot.get_containers():
		var container := value as Dictionary
		if int(container.get("provider_item", 0)) == provider_item:
			return int(container.get("id", 0))
	return 0


func _slot(container: int, identifier: StringName) -> Dictionary:
	return {
		"kind": "slot",
		"container": container,
		"slot_identifier": String(identifier),
	}


func _spatial(container: int, x: int, y: int) -> Dictionary:
	return {
		"kind": "spatial",
		"container": container,
		"x": x,
		"y": y,
		"rotated": false,
	}


func _next_command() -> int:
	_command_id += 1
	return _command_id


func _first_grant_record(source: Dictionary) -> Dictionary:
	var records := source.get("grant_records", []) as Array
	return (records[0] as Dictionary).duplicate(true) if not records.is_empty() else {}


func _first_partial_revoke_record(records: Array) -> Dictionary:
	for value in records:
		if value is Dictionary \
				and bool((value as Dictionary).get("fixture_partial_revoke", false)):
			return (value as Dictionary).duplicate(true)
	return {}


func _first_effect_handle(record: Dictionary) -> int:
	var effects := record.get("effects", []) as Array
	return int((effects[0] as Dictionary).get("handle", 0)) \
		if not effects.is_empty() else 0


func _deep_read_only(value: Variant) -> bool:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			if not dictionary.is_read_only():
				return false
			for child in dictionary.values():
				if not _deep_read_only(child):
					return false
		TYPE_ARRAY:
			var array := value as Array
			if not array.is_read_only():
				return false
			for child in array:
				if not _deep_read_only(child):
					return false
	return true
