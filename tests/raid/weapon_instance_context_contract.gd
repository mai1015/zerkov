extends SceneTree
## Run with: /Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot \
##   --headless --path . --script \
##   res://tests/raid/weapon_instance_context_contract.gd
##
## Task 5.2 contract. Uses real InventoryAuthority and WeaponAuthority state,
## real equipment/reload adapters, and RaidAuthority's ordered tick phases.

var checks: int = 0
var failures: int = 0

var _raid_authority: RaidAuthority
var _weapon_authority: WeaponAuthority
var _instance_adapter: WeaponInstanceContextAdapter
var _reload_adapter: InventoryWeaponAdapter
var _admission: ZSessionAdmission
var _weapon_id: String = ""
var _pose_origin := Vector2(96.0, -32.0)
var _pose_aim := Vector2(3.0, 4.0)
var _contexts_by_tick: Dictionary = {}
var _fire_modes: Dictionary = {}
var _fire_outcomes: Dictionary = {}
var _status_updates: Dictionary = {}
var _duplicate_pose_proved: bool = false
var _conflicting_pose_rejected: bool = false


class OneShotRemoveFailureAdapter extends WeaponInstanceContextAdapter:
	var fail_next_remove: bool = true

	func _remove_native_weapon(weapon_id: String) -> Dictionary:
		if fail_next_remove:
			fail_next_remove = false
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
		push_error("WEAPON_INSTANCE_CONTEXT_CONTRACT: " + message)


func run() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "weapon_context_001"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	_admission = coordinator.open_offline(raid_id, &"weapon_context_profile", &"player")
	check(_admission != null and _admission.is_usable(), "offline admission is usable")

	var owner := RaidInventoryOwner.new()
	owner.name = "WeaponContextInventoryOwner"
	root.add_child(owner)
	check(owner.configure(), "raid inventory owner configures")
	var owner_generation := owner.generation()
	var bridge := InventoryProjectionBridge.new()
	bridge.name = "WeaponContextProjectionBridge"
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation), "projection bridge binds exact owner")
	var scope_generation := bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	var reconciler := EquippedItemReconciler.new()
	reconciler.name = "WeaponContextEquippedItemReconciler"
	root.add_child(reconciler)
	check(reconciler.bind_owner(
		owner, bridge, _admission, owner_generation, scope_generation),
		"equipment reconciler binds current raid projection")

	var inventory_authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var initial_snapshot := inventory_authority.snapshot(inventory_id)
	var equipment := _container(initial_snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var backpack := _container(initial_snapshot, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var pockets := _container(initial_snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	check(equipment > 0 and backpack > 0 and pockets > 0,
		"equipment, backpack, and pockets containers resolve")
	var akm_insert: Dictionary = inventory_authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_001
	)
	var machete_insert: Dictionary = inventory_authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MACHETE),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_MELEE),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_002
	)
	var ammo_insert: Dictionary = inventory_authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AMMO_762),
		30,
		_spatial(pockets, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_003
	)
	check(bool(akm_insert.get("accepted", false))
		and bool(machete_insert.get("accepted", false))
		and bool(ammo_insert.get("accepted", false)),
		"equipped AKM, equipped machete, and reload ammunition commit canonically")
	var akm_item_id := int(akm_insert.get("new_item_id", 0))
	var mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	var melee_mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_MELEE)
	_weapon_id = String(mapping.get("weapon_id", ""))
	check(akm_item_id > 0 and not _weapon_id.is_empty() and not melee_mapping.is_empty(),
		"equipment reconciliation publishes both stable weapon identities")

	_weapon_authority = WeaponAuthority.new()
	_weapon_authority.name = "WeaponContextAuthority"
	root.add_child(_weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(
		_weapon_authority).get("ok", false)), "sealed AKM runtime configures")
	var weapon_port := WeaponAuthorityReloadPort.new()
	check(weapon_port.configure(_weapon_authority),
		"reload port binds the exact real WeaponAuthority")
	_reload_adapter = InventoryWeaponAdapter.new()
	_reload_adapter.name = "WeaponContextReloadAdapter"
	root.add_child(_reload_adapter)
	check(_reload_adapter.bind_owner(
		owner, _admission, weapon_port, owner_generation),
		"reload coordinator binds the exact inventory and weapon authorities")

	_raid_authority = RaidAuthority.new()
	check(_raid_authority.configure(raid_id, _admission, 5_002),
		"raid authority configures for the same admission")
	var foreign_actor := ZEntityId.from_parts(PackedStringArray(["foreign", "actor"]))
	check(not _raid_authority.publish_weapon_actor_status(
		foreign_actor, true, true, 0, _raid_authority.generation())
		and _raid_authority.last_error == &"weapon_actor_not_authorized",
		"unapproved actor status cannot enter authoritative weapon context")
	check(_raid_authority.publish_weapon_actor_status(
		_admission.actor_id, true, true, 0, _raid_authority.generation()),
		"preparing phase initializes authoritative actor liveness and usability")
	check(_raid_authority.publish_weapon_actor_status(
		_admission.actor_id, true, true, 0, _raid_authority.generation()),
		"identical status publication is idempotent")
	check(not _raid_authority.publish_weapon_actor_status(
		_admission.actor_id, false, true, 0, _raid_authority.generation())
		and _raid_authority.last_error == &"weapon_status_tick_conflict",
		"same-tick conflicting liveness is rejected without replacing state")
	check(not _raid_authority.publish_weapon_actor_pose(
		_admission.actor_id, _pose_origin, _pose_aim, 0, _raid_authority.generation())
		and _raid_authority.last_error == &"weapon_pose_phase_invalid",
		"pose cannot be published outside authoritative movement phase")
	check(_raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		&"weapon_context_pose",
		Callable(self, "_publish_pose"),
		_raid_authority.generation()), "movement pose publisher registers")
	check(_raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
		&"weapon_context_due_work",
		Callable(self, "_advance_due_work"),
		_raid_authority.generation()), "reload/status due-work publisher registers")
	var exact_content_fingerprint := int(
		ZerkovCombatContent.validate_resource_bundle().get("fingerprint", 0))
	check(exact_content_fingerprint != 0
		and _weapon_authority.content_fingerprint() == exact_content_fingerprint,
		"task-5.2 composition pins the exact task-5.1 content fingerprint")
	var altered_runtime := ZerkovCombatContent.build_runtime_configuration()
	(altered_runtime["weapons"][0] as Dictionary)["capacity"] = \
		ZerkovCombatContent.AKM_CAPACITY - 1
	var altered_configuration: Dictionary = _weapon_authority.configure(
		altered_runtime["shot_profiles"],
		altered_runtime["weapons"],
		altered_runtime["recoil_profiles"],
		altered_runtime["attachments"],
		altered_runtime["ammo_profiles"])
	check(bool(altered_configuration.get("ok", false))
		and _weapon_authority.content_fingerprint() != exact_content_fingerprint,
		"valid but non-authored WeaponAuthority content has a different fingerprint")
	var mismatched_adapter := WeaponInstanceContextAdapter.new()
	root.add_child(mismatched_adapter)
	check(not mismatched_adapter.bind_owner(
		owner, reconciler, _admission, _raid_authority, _weapon_authority,
		weapon_port, _reload_adapter, owner_generation, scope_generation,
		_raid_authority.generation())
		and mismatched_adapter.last_error == &"weapon_content_fingerprint_mismatch",
		"adapter bind fails closed on a valid non-task-5.1 catalog")
	check(bool(ZerkovCombatContent.configure_authority(
		_weapon_authority).get("ok", false)), "exact authored content restores after bind rejection")
	mismatched_adapter.queue_free()

	_instance_adapter = WeaponInstanceContextAdapter.new()
	_instance_adapter.name = "WeaponInstanceContextAdapter"
	root.add_child(_instance_adapter)
	var publications: Array[Dictionary] = []
	var publications_read_only: Array[bool] = []
	_instance_adapter.reconciliation_published.connect(func(outcome: Dictionary):
		publications.append(outcome.duplicate(true))
		publications_read_only.append(_is_deep_read_only(outcome)))
	check(_instance_adapter.bind_owner(
		owner,
		reconciler,
		_admission,
		_raid_authority,
		_weapon_authority,
		weapon_port,
		_reload_adapter,
		owner_generation,
		scope_generation,
		_raid_authority.generation()
	), "task-5.2 adapter binds every exact authority generation")
	check(bool(_weapon_authority.configure(
		altered_runtime["shot_profiles"],
		altered_runtime["weapons"],
		altered_runtime["recoil_profiles"],
		altered_runtime["attachments"],
		altered_runtime["ammo_profiles"]).get("ok", false))
		and not _instance_adapter.is_bound()
		and _instance_adapter.authority_context(_weapon_id, 0).get("reason")
			== &"weapon_context_binding_stale",
		"bound adapter continuously fails closed when live content fingerprint changes")
	check(bool(ZerkovCombatContent.configure_authority(
		_weapon_authority).get("ok", false)) and _instance_adapter.is_bound(),
		"restoring the exact pinned content restores the still-current setup binding")
	check(_weapon_authority.snapshots().is_empty(),
		"binding is mutation-free before ordered phase-5 reconciliation")
	check(_raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"weapon_context_probe",
		Callable(self, "_probe_context_and_fire"),
		_raid_authority.generation(),
		WeaponInstanceContextAdapter.CONSUMER_PHASE_PRIORITY,
		WeaponInstanceContextAdapter.consumer_phase_dependencies()),
		"phase-5 context consumer declares the instance provider dependency")
	check(_raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, _raid_authority.generation()),
		"raid enters active lifecycle after composition")
	check(not _raid_authority.publish_weapon_actor_status(
		_admission.actor_id, false, false, 0, _raid_authority.generation())
		and _raid_authority.last_error == &"weapon_status_phase_invalid",
		"active out-of-band status mutation is rejected")

	check(_raid_authority.advance_one(_raid_authority.generation()),
		"first ordered raid tick creates equipped instances")
	var created_state := _weapon_authority.snapshot(_weapon_id)
	check(not created_state.is_empty()
		and created_state.get("definition_id", &"") == ZerkovCombatContent.WEAPON_AKM
		and int(created_state.get("loaded_rounds", -1)) == 0,
		"equipped AKM creates one empty real WeaponAuthority instance")
	check(_weapon_authority.snapshots().size() == 1
		and _weapon_authority.snapshot(String(melee_mapping["weapon_id"])).is_empty(),
		"machete is explicitly deferred instead of fabricated in firearm V1")
	var first_outcome := _instance_adapter.current_outcome()
	check((first_outcome.get("added", []) as Array).size() == 1
		and (first_outcome.get("deferred_melee", []) as Array).size() == 1,
		"first outcome names the created firearm and deferred melee mapping")
	check(not publications.is_empty() and publications_read_only.all(func(value: bool): return value),
		"instance reconciliation publications are recursively read-only")
	var tick_one_context := _contexts_by_tick.get(1, {}) as Dictionary
	var tick_one_facts := tick_one_context.get("context", {}) as Dictionary
	check(bool(tick_one_context.get("ok", false))
		and bool(tick_one_facts.get("actor_live", false))
		and bool(tick_one_facts.get("weapon_equipped", false))
		and bool(tick_one_facts.get("weapon_usable", false)),
		"context combines authoritative liveness, equipment, and usability")
	check(tick_one_facts.get("authoritative_origin", {}) == {"x": 3000, "y": -1000}
		and tick_one_facts.get("authoritative_aim", {}) == {"x": 600_000, "y": 800_000},
		"context exposes only RaidAuthority-converted pose and normalized aim")
	check(_is_deep_read_only(tick_one_context),
		"consumer context is recursively read-only")
	check(_duplicate_pose_proved and _conflicting_pose_rejected,
		"movement pose publication is idempotent and conflicting same-tick pose fails closed")
	check(_instance_adapter.authority_context(_weapon_id, 1).get("reason")
		== &"weapon_context_phase_invalid",
		"late context reads cannot reuse a completed tick pose")

	var reload_begin := _reload_adapter.begin_reload({
		"request_id": ZRequestId.from_parts(
			PackedStringArray(["weapon_context", "reload"])).canonical_key(),
		"weapon_id": _weapon_id,
		"weapon_binding_generation":
			_instance_adapter.weapon_binding_generation(_weapon_id),
		"adapter_generation": _reload_adapter.adapter_generation(),
		"authority_epoch": _admission.authority_epoch,
		"inventory_id": inventory_id,
		"expected_inventory_revision": inventory_authority.inventory_revision(inventory_id),
		"expected_weapon_revision": int(created_state.get("revision", -1)),
		"tick": 1,
	})
	check(bool(reload_begin.get("accepted", false))
		and int(reload_begin.get("due_tick", -1)) == 73,
		"real inventory/weapon reload begins against the task-5.2 instance")
	for _index in 72:
		check(_raid_authority.advance_one(_raid_authority.generation()),
			"reload progression tick advances")
	var loaded_state := _weapon_authority.snapshot(_weapon_id)
	check(int(loaded_state.get("loaded_rounds", -1)) == ZerkovCombatContent.AKM_CAPACITY
		and String(loaded_state.get("phase", "")) == "ready",
		"phase-7 coordinator commits 30 physical rounds after 72 ticks")

	_fire_modes[74] = &"matching"
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"loaded fire tick advances")
	var accepted_fire := _fire_outcomes.get(74, {}) as Dictionary
	var accepted_shot := accepted_fire.get("shot", {}) as Dictionary
	check(bool(accepted_fire.get("accepted", false))
		and not bool(accepted_fire.get("replayed", true)),
		"real WeaponAuthority accepts fire with the supplied authoritative context")
	check(accepted_shot.get("origin", {}) == {"x": 3000, "y": -1000}
		and int(_weapon_authority.snapshot(_weapon_id).get("loaded_rounds", -1)) == 29,
		"committed shot uses authoritative pose and consumes one loaded round")

	var post_fire_revision := int(_weapon_authority.snapshot(_weapon_id).get("revision", -1))
	var unequip: Dictionary = inventory_authority.move_item(
		inventory_id,
		akm_item_id,
		_spatial(backpack, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_004
	)
	check(bool(unequip.get("accepted", false)), "owned AKM unequips to backpack")
	_fire_modes[75] = &"matching"
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"unequipped weapon tick advances")
	var dormant_context := (_contexts_by_tick.get(75, {}) as Dictionary).get(
		"context", {}) as Dictionary
	check(not bool(dormant_context.get("weapon_equipped", true))
		and not _weapon_authority.snapshot(_weapon_id).is_empty()
		and int(_weapon_authority.snapshot(_weapon_id).get("revision", -1))
			== post_fire_revision,
		"unequipped-but-owned instance stays dormant without losing mechanics")
	check(_diagnostic(_fire_outcomes.get(75, {}) as Dictionary) == 77,
		"native fire rejects dormant weapon from canonical equipment=false context")

	var reequip: Dictionary = inventory_authority.equip_item(
		inventory_id,
		akm_item_id,
		equipment,
		String(EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_005
	)
	check(bool(reequip.get("accepted", false)), "same canonical AKM re-equips")
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"re-equipped weapon tick advances")
	check(bool(((_contexts_by_tick.get(76, {}) as Dictionary).get(
		"context", {}) as Dictionary).get("weapon_equipped", false))
		and _weapon_authority.snapshots().size() == 1,
		"re-equip reuses the exact native instance instead of duplicating it")

	for _index in 6:
		check(_raid_authority.advance_one(_raid_authority.generation()),
			"cadence separation tick advances")
	_fire_modes[83] = &"forged_origin"
	_status_updates[83] = {"actor_live": true, "weapon_usable": false}
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"forged presentation pose tick advances")
	check(_diagnostic(_fire_outcomes.get(83, {}) as Dictionary) == 70
		and int(_weapon_authority.snapshot(_weapon_id).get("loaded_rounds", -1)) == 29,
		"caller-claimed pose cannot replace authority pose or consume ammunition")

	_fire_modes[84] = &"matching"
	_status_updates[84] = {"actor_live": false, "weapon_usable": false}
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"unusable weapon tick advances")
	check(_diagnostic(_fire_outcomes.get(84, {}) as Dictionary) == 65,
		"native fire rejects RaidAuthority usability=false context")
	_fire_modes[85] = &"matching"
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"non-live actor tick advances")
	check(_diagnostic(_fire_outcomes.get(85, {}) as Dictionary) == 64,
		"native fire rejects RaidAuthority liveness=false context")

	var conserved_weapon_state := _weapon_authority.snapshot(_weapon_id)
	var conserved_binding_generation := _instance_adapter.weapon_binding_generation(_weapon_id)
	var world_inventory_id := owner.world_crate_inventory_id
	var world_container := _container(
		inventory_authority.snapshot(world_inventory_id),
		ZerkovInventoryCatalog.CONTAINER_WORLD_CRATE)
	check(world_container > 0, "world custody container resolves")
	var transfer_out: Dictionary = inventory_authority.loot_item(
		inventory_id,
		world_inventory_id,
		akm_item_id,
		_spatial(world_container, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_006
	)
	var transfer_out_replay: Dictionary = inventory_authority.loot_item(
		inventory_id,
		world_inventory_id,
		akm_item_id,
		_spatial(world_container, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_006
	)
	check(bool(transfer_out.get("accepted", false))
		and bool(transfer_out_replay.get("accepted", false))
		and bool(transfer_out_replay.get("replayed", false))
		and (transfer_out_replay.get("events", []) as Array).is_empty(),
		"canonical transfer-out replay preserves one stable custody change")
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"transferred-out weapon reconciliation tick advances")
	var transferred_state := _weapon_authority.snapshot(_weapon_id)
	var transfer_out_outcome := _instance_adapter.current_outcome()
	check(transferred_state == conserved_weapon_state
		and _instance_adapter.weapon_binding_generation(_weapon_id)
			== conserved_binding_generation
		and _instance_adapter.instance_records().size() == 1
		and (transfer_out_outcome.get("parked", []) as Array).size() == 1,
		"transfer out parks the exact loaded native instance and binding")
	check((_contexts_by_tick.get(86, {}) as Dictionary).get("reason")
		== &"weapon_item_not_owned",
		"external custody denies player fire context without destroying mechanics")

	var transfer_back: Dictionary = inventory_authority.loot_item(
		world_inventory_id,
		inventory_id,
		akm_item_id,
		_spatial(backpack, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_007
	)
	check(bool(transfer_back.get("accepted", false)),
		"same canonical weapon transfers back to player custody")
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"returned dormant weapon reconciliation tick advances")
	var returned_context := _contexts_by_tick.get(87, {}) as Dictionary
	check(_weapon_authority.snapshot(_weapon_id) == conserved_weapon_state
		and _instance_adapter.weapon_binding_generation(_weapon_id)
			== conserved_binding_generation
		and bool(returned_context.get("ok", false))
		and not bool((returned_context.get("context", {}) as Dictionary).get(
			"weapon_equipped", true)),
		"transfer back restores player context around the unchanged dormant instance")

	var reequip_after_transfer: Dictionary = inventory_authority.equip_item(
		inventory_id,
		akm_item_id,
		equipment,
		String(EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_008
	)
	check(bool(reequip_after_transfer.get("accepted", false))
		and _raid_authority.advance_one(_raid_authority.generation()),
		"returned canonical weapon re-equips on the next ordered tick")
	var reequipped_context := (_contexts_by_tick.get(88, {}) as Dictionary).get(
		"context", {}) as Dictionary
	check(_weapon_authority.snapshot(_weapon_id) == conserved_weapon_state
		and _instance_adapter.weapon_binding_generation(_weapon_id)
			== conserved_binding_generation
		and bool(reequipped_context.get("weapon_equipped", false)),
		"re-equip reuses conserved mechanics, native identity, and binding generation")

	var remove_akm: Dictionary = inventory_authority.remove_item(
		inventory_id,
		akm_item_id,
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_009
	)
	var remove_akm_replay: Dictionary = inventory_authority.remove_item(
		inventory_id,
		akm_item_id,
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		51_009
	)
	check(bool(remove_akm.get("accepted", false))
		and bool(remove_akm_replay.get("accepted", false))
		and bool(remove_akm_replay.get("replayed", false)),
		"canonical inventory destruction removes AKM ownership")
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"destroyed weapon reconciliation tick advances")
	check(_weapon_authority.snapshot(_weapon_id).is_empty()
		and _instance_adapter.instance_records().is_empty()
		and (_contexts_by_tick.get(89, {}) as Dictionary).get("reason")
			== &"weapon_instance_not_owned",
		"destroyed inventory item removes native instance and future context")
	var deregistration_replay := _reload_adapter.unregister_weapon(
		_weapon_id, conserved_binding_generation)
	check(bool(deregistration_replay.get("accepted", false))
		and bool(deregistration_replay.get("replayed", false)),
		"permanent destruction explicitly retired the exact reload binding once")

	var stale_phase_callback := Callable(
		_instance_adapter, "_on_weapon_phase").bind(_instance_adapter.binding_generation())
	check(_raid_authority.unregister_phase_handler(
		&"weapon_context_probe", _raid_authority.generation()),
		"phase-5 consumer releases before its declared context provider")
	check(_instance_adapter.release_binding(&"teardown", 89)
		and not _raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID, _raid_authority.generation()),
		"instance/context adapter releases before dependency teardown")
	var stale_intents: Array[ZRaidIntent] = []
	check(bool(stale_phase_callback.call(
		_raid_authority,
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		90,
		stale_intents)) and _instance_adapter.instance_records().is_empty(),
		"captured stale provider callback is an inert generation-checked no-op")
	check(_raid_authority.advance_one(_raid_authority.generation()),
		"post-release raid tick cannot invoke the deregistered provider")
	check(_reload_adapter.release_binding(&"teardown", 90),
		"reload coordinator releases after owned instances")
	reconciler.release_binding(&"test_teardown")
	bridge.release_binding()
	check(owner.teardown(owner_generation), "inventory authority owner tears down")
	check(_raid_authority.teardown(_raid_authority.generation()),
		"raid authority teardown clears actor weapon facts and handlers")
	_instance_adapter.queue_free()
	_reload_adapter.queue_free()
	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()
	_weapon_authority.queue_free()
	_run_external_owner_teardown()
	_run_missing_pose_fails_closed()
	_run_phase_handler_ordering_contract()
	_run_cleanup_failure_reachability()

	print("WEAPON_INSTANCE_CONTEXT_RESULT checks=", checks,
		" failures=", failures,
		" accepted_shot=", bool(accepted_fire.get("accepted", false)),
		" dormant_preserved=true transfer_conserved=true teardown_safe=true")
	if failures > 0:
		print("WEAPON_INSTANCE_CONTEXT_FIRE_OUTCOMES ", _fire_outcomes)
	quit(0 if failures == 0 else 1)


func _run_external_owner_teardown() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "weapon_owner_teardown"]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, &"weapon_teardown_profile", &"player")
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	check(owner.configure(), "external-teardown owner configures")
	var owner_generation := owner.generation()
	var bridge := InventoryProjectionBridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"external-teardown projection binds")
	var scope_generation := bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	var reconciler := EquippedItemReconciler.new()
	root.add_child(reconciler)
	check(reconciler.bind_owner(
		owner, bridge, admission, owner_generation, scope_generation),
		"external-teardown equipment reconciler binds")
	var inventory := owner.raid_authority()
	var equipment := _container(
		inventory.snapshot(owner.raid_player_inventory_id),
		ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var inserted: Dictionary = inventory.insert_item(
		owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		52_001)
	check(bool(inserted.get("accepted", false)), "external-teardown AKM equips")
	var weapon_id := String(reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_PRIMARY).get("weapon_id", ""))
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(
		weapon_authority).get("ok", false)),
		"external-teardown weapon authority configures")
	var weapon_port := WeaponAuthorityReloadPort.new()
	check(weapon_port.configure(weapon_authority),
		"external-teardown weapon port configures")
	var reload_adapter := InventoryWeaponAdapter.new()
	root.add_child(reload_adapter)
	check(reload_adapter.bind_owner(
		owner, admission, weapon_port, owner_generation),
		"external-teardown reload coordinator binds")
	var raid_authority := RaidAuthority.new()
	check(raid_authority.configure(raid_id, admission, 5_202),
		"external-teardown raid authority configures")
	check(raid_authority.publish_weapon_actor_status(
		admission.actor_id, true, true, 0, raid_authority.generation()),
		"external-teardown actor status initializes")
	check(raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		&"weapon_context_pose",
		func(authority: RaidAuthority, _phase: RaidAuthority.TickPhase,
				tick: int, _intents: Array[ZRaidIntent]) -> bool:
			return authority.publish_weapon_actor_pose(
				admission.actor_id, Vector2.ZERO, Vector2.RIGHT,
				tick, authority.generation()),
		raid_authority.generation()),
		"external-teardown pose publisher registers")
	var adapter := WeaponInstanceContextAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(
		owner, reconciler, admission, raid_authority, weapon_authority,
		weapon_port, reload_adapter, owner_generation, scope_generation,
		raid_authority.generation()),
		"external-teardown instance adapter binds")
	check(raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, raid_authority.generation())
		and raid_authority.advance_one(raid_authority.generation())
		and not weapon_authority.snapshot(weapon_id).is_empty(),
		"external-teardown fixture creates its real native AKM")
	check(owner.teardown(owner_generation),
		"owner-first teardown executes without adapter coordination")
	check(adapter.lifecycle == WeaponInstanceContextAdapter.Lifecycle.INVALIDATED
		and weapon_authority.snapshot(weapon_id).is_empty()
		and reload_adapter.lifecycle == InventoryWeaponAdapter.Lifecycle.INVALIDATED,
		"owner invalidation removes native instance and retires both adapters")
	check(raid_authority.teardown(raid_authority.generation()),
		"external-teardown raid authority retires after inventory owner")
	adapter.queue_free()
	reload_adapter.queue_free()
	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _run_missing_pose_fails_closed() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "missing_weapon_pose"]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, &"missing_pose_profile", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 5_203),
		"missing-pose authority configures")
	check(authority.publish_weapon_actor_status(
		admission.actor_id, true, true, 0, authority.generation()),
		"missing-pose actor status initializes")
	var observed: Array[Dictionary] = []
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"missing_pose_probe",
		func(current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				tick: int, _intents: Array[ZRaidIntent]) -> bool:
			observed.append(current.authoritative_weapon_actor_context(
				admission.actor_id, tick, current.generation()))
			return true,
		authority.generation()), "missing-pose phase-5 probe registers")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, authority.generation())
		and authority.advance_one(authority.generation()),
		"tick without a movement pose remains structurally processable")
	check(observed.size() == 1 and observed[0].get("reason") == &"weapon_pose_stale",
		"current fire context fails closed when movement did not publish this tick")
	check(authority.teardown(authority.generation()), "missing-pose authority tears down")


func _run_phase_handler_ordering_contract() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "phase_ordering"]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, &"phase_ordering_profile", &"player")
	var authority := RaidAuthority.new()
	check(authority.configure(raid_id, admission, 5_204),
		"phase-order authority configures")
	var order := PackedStringArray()
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"z_provider",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool:
			order.append("z_provider")
			return true,
		authority.generation(),
		10), "priority provider registers independently of lexical position")
	check(not authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"missing_consumer",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool: return true,
		authority.generation(),
		20,
		PackedStringArray(["missing_provider"]))
		and authority.last_error == &"handler_dependency_missing",
		"consumer cannot declare a missing same-phase provider")
	check(not authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"early_consumer",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool: return true,
		authority.generation(),
		5,
		PackedStringArray(["z_provider"]))
		and authority.last_error == &"handler_dependency_order_invalid",
		"dependency cannot be contradicted by an earlier consumer priority")
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"a_consumer",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool:
			order.append("a_consumer")
			return true,
		authority.generation(),
		20,
		PackedStringArray(["z_provider"])),
		"consumer registers with an explicit provider dependency")
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"b_tie",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool:
			order.append("b_tie")
			return true,
		authority.generation(),
		30), "later lexical tie registers first")
	check(authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"a_tie",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool:
			order.append("a_tie")
			return true,
		authority.generation(),
		30), "earlier lexical tie registers second")
	check(not authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		&"z_provider",
		func(_current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				_tick: int, _intents: Array[ZRaidIntent]) -> bool: return true,
		authority.generation(),
		10) and authority.last_error == &"handler_id_duplicate",
		"duplicate handler registration remains fail-closed")
	check(authority.transition(RaidAuthority.Lifecycle.ACTIVE, authority.generation())
		and authority.advance_one(authority.generation()),
		"priority/dependency fixture advances one complete tick")
	check(order == PackedStringArray(["z_provider", "a_consumer", "a_tie", "b_tie"]),
		"same-phase order is priority first and lexical ID as deterministic tie-break")
	check(not authority.unregister_phase_handler(&"z_provider", authority.generation())
		and authority.last_error == &"handler_has_dependents",
		"provider cannot release before a declared consumer")
	check(authority.unregister_phase_handler(&"a_consumer", authority.generation())
		and authority.unregister_phase_handler(&"z_provider", authority.generation())
		and authority.unregister_phase_handler(&"z_provider", authority.generation()),
		"consumer-first deregistration is explicit and idempotent")
	check(not authority.unregister_phase_handler(&"a_tie", authority.generation() + 1)
		and authority.last_error == &"stale_generation",
		"stale generation cannot deregister a replacement handler")
	check(authority.teardown(authority.generation()), "phase-order authority tears down")


func _run_cleanup_failure_reachability() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "cleanup_reachability"]))
	var admission := SessionCoordinator.new(OfflineSessionIngress.new()).open_offline(
		raid_id, &"cleanup_reachability_profile", &"player")
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	check(owner.configure(), "cleanup-reachability inventory owner configures")
	var owner_generation := owner.generation()
	var bridge := InventoryProjectionBridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"cleanup-reachability projection binds")
	var scope_generation := bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	var reconciler := EquippedItemReconciler.new()
	root.add_child(reconciler)
	check(reconciler.bind_owner(
		owner, bridge, admission, owner_generation, scope_generation),
		"cleanup-reachability reconciler binds")
	var inventory := owner.raid_authority()
	var equipment := _container(
		inventory.snapshot(owner.raid_player_inventory_id),
		ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var inserted: Dictionary = inventory.insert_item(
		owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		53_001)
	check(bool(inserted.get("accepted", false)),
		"cleanup-reachability AKM equips canonically")
	var mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	var weapon_id := String(mapping.get("weapon_id", ""))
	var weapon_authority := WeaponAuthority.new()
	root.add_child(weapon_authority)
	check(bool(ZerkovCombatContent.configure_authority(
		weapon_authority).get("ok", false)),
		"cleanup-reachability WeaponAuthority configures")
	var weapon_port := WeaponAuthorityReloadPort.new()
	check(weapon_port.configure(weapon_authority),
		"cleanup-reachability weapon port configures")
	var reload_adapter := InventoryWeaponAdapter.new()
	root.add_child(reload_adapter)
	check(reload_adapter.bind_owner(owner, admission, weapon_port, owner_generation),
		"cleanup-reachability reload adapter binds")
	var raid_authority := RaidAuthority.new()
	check(raid_authority.configure(raid_id, admission, 5_205),
		"cleanup-reachability raid authority configures")
	check(raid_authority.publish_weapon_actor_status(
		admission.actor_id, true, true, 0, raid_authority.generation()),
		"cleanup-reachability actor status initializes")
	check(raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.MOVEMENT,
		&"cleanup_pose",
		func(current: RaidAuthority, _phase: RaidAuthority.TickPhase,
				tick: int, _intents: Array[ZRaidIntent]) -> bool:
			return current.publish_weapon_actor_pose(
				admission.actor_id, Vector2.ZERO, Vector2.RIGHT,
				tick, current.generation()),
		raid_authority.generation()), "cleanup-reachability pose provider registers")
	var adapter := OneShotRemoveFailureAdapter.new()
	root.add_child(adapter)
	check(adapter.bind_owner(
		owner, reconciler, admission, raid_authority, weapon_authority,
		weapon_port, reload_adapter, owner_generation, scope_generation,
		raid_authority.generation()), "cleanup-reachability instance adapter binds")
	check(raid_authority.transition(
		RaidAuthority.Lifecycle.ACTIVE, raid_authority.generation())
		and raid_authority.advance_one(raid_authority.generation())
		and not weapon_authority.snapshot(weapon_id).is_empty(),
		"cleanup-reachability fixture creates one native AKM")
	var binding_generation := adapter.weapon_binding_generation(weapon_id)
	var stale_deregistration := reload_adapter.unregister_weapon(
		weapon_id, binding_generation + 1)
	check(not bool(stale_deregistration.get("accepted", true))
		and stale_deregistration.get("reason") == &"weapon_binding_generation_stale",
		"stale cleanup callback cannot retire the current reload binding")
	check(not adapter.release_binding(&"teardown", 1)
		and adapter.lifecycle == WeaponInstanceContextAdapter.Lifecycle.RECOVERY_REQUIRED,
		"injected native cleanup failure latches recoverable fail-closed state")
	var retained_records := adapter.instance_records()
	check(retained_records.size() == 1
		and String(retained_records[0].get("weapon_id", "")) == weapon_id
		and not weapon_authority.snapshot(weapon_id).is_empty(),
		"cleanup failure retains a reachable record for the still-live native weapon")
	var already_deregistered := reload_adapter.unregister_weapon(
		weapon_id, binding_generation)
	check(bool(already_deregistered.get("accepted", false))
		and bool(already_deregistered.get("replayed", false)),
		"failed native cleanup had already retired its reload binding exactly once")
	check(adapter.release_binding(&"teardown", 1)
		and adapter.instance_records().is_empty()
		and weapon_authority.snapshot(weapon_id).is_empty()
		and not raid_authority.has_phase_handler(
			WeaponInstanceContextAdapter.PHASE_HANDLER_ID, raid_authority.generation()),
		"retry from recovery removes the reachable native weapon and provider lease")
	check(reload_adapter.release_binding(&"teardown", 1),
		"cleanup-reachability reload adapter releases")
	reconciler.release_binding(&"test_teardown")
	bridge.release_binding()
	check(owner.teardown(owner_generation), "cleanup-reachability owner tears down")
	check(raid_authority.teardown(raid_authority.generation()),
		"cleanup-reachability raid authority tears down")
	adapter.queue_free()
	reload_adapter.queue_free()
	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()
	weapon_authority.queue_free()


func _publish_pose(
	authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	var accepted := authority.publish_weapon_actor_pose(
		_admission.actor_id, _pose_origin, _pose_aim, tick, authority.generation())
	if tick == 1 and accepted:
		_duplicate_pose_proved = authority.publish_weapon_actor_pose(
			_admission.actor_id, _pose_origin, _pose_aim, tick, authority.generation())
		_conflicting_pose_rejected = not authority.publish_weapon_actor_pose(
			_admission.actor_id,
			_pose_origin + Vector2(32.0, 0.0),
			_pose_aim,
			tick,
			authority.generation()) \
			and authority.last_error == &"weapon_pose_tick_conflict"
	return accepted


func _advance_due_work(
	authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	var outcomes := _reload_adapter.advance_due_reloads(tick)
	for outcome in outcomes:
		if not bool(outcome.get("accepted", false)):
			return false
	if _status_updates.has(tick):
		var update := _status_updates[tick] as Dictionary
		return authority.publish_weapon_actor_status(
			_admission.actor_id,
			bool(update["actor_live"]),
			bool(update["weapon_usable"]),
			tick,
			authority.generation())
	return true


func _probe_context_and_fire(
	_authority: RaidAuthority,
	_phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	var context_result := _instance_adapter.authority_context(_weapon_id, tick)
	_contexts_by_tick[tick] = context_result
	if not _fire_modes.has(tick):
		return true
	if not bool(context_result.get("ok", false)):
		return false
	var native_state := _weapon_authority.snapshot(_weapon_id)
	var sequence := maxi(
		int(native_state.get("admitted_sequence_high_watermark", 0)),
		int(native_state.get("last_command_sequence", 0))) + 1
	var facts := context_result["context"] as Dictionary
	var claimed_origin := (facts["authoritative_origin"] as Dictionary).duplicate(true)
	if _fire_modes[tick] == &"forged_origin":
		claimed_origin["x"] = int(claimed_origin["x"]) + 10_000
	_fire_outcomes[tick] = _weapon_authority.fire({
		"command_id": "weapon-context-fire-%d" % tick,
		"sequence": sequence,
		"instance_id": _weapon_id,
		"expected_revision": int(native_state.get("revision", -1)),
		"tick": tick,
		"authority_scope": _admission.raid_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"claimed_origin": claimed_origin,
		"claimed_aim": (facts["authoritative_aim"] as Dictionary).duplicate(true),
		"spread_seed": 7,
	}, facts)
	return true


func _diagnostic(outcome: Dictionary) -> int:
	return int((outcome.get("status", {}) as Dictionary).get("diagnostic", -1))


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


func _is_deep_read_only(value: Variant) -> bool:
	if value is Dictionary:
		var dictionary := value as Dictionary
		if not dictionary.is_read_only():
			return false
		for child in dictionary.values():
			if not _is_deep_read_only(child):
				return false
	elif value is Array:
		var array := value as Array
		if not array.is_read_only():
			return false
		for child in array:
			if not _is_deep_read_only(child):
				return false
	return true
