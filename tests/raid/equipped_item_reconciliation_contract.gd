extends SceneTree
## Run with: godot --headless --path . --script \
##   res://tests/raid/equipped_item_reconciliation_contract.gd
##
## Task 4.8 contract: exact raid inventory projections reconcile canonical
## equipment slots into stable typed weapon/entity identities without creating
## Weapon System runtime instances.

const EquippedItemReconcilerScript := preload(
	"res://game/inventory/equipment/equipped_item_reconciler.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("EQUIPPED_ITEM_RECONCILIATION_CONTRACT: " + message)


func run() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["fixture", "equipment_001"]))
	var coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var admission := coordinator.open_offline(raid_id, &"equipment_profile", &"player")
	var canonical_admission := admission.snapshot()
	check(canonical_admission != null and canonical_admission.is_usable(),
		"fixture admission is a usable immutable context")

	var owner := RaidInventoryOwner.new()
	owner.name = "EquipmentInventoryOwner"
	root.add_child(owner)
	check(owner.configure(), "raid inventory owner configures")
	var owner_generation := owner.generation()
	var bridge := InventoryProjectionBridge.new()
	bridge.name = "EquipmentProjectionBridge"
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"inventory projection bridge binds before reconciliation")
	var raid_scope_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)

	var reconciler := EquippedItemReconcilerScript.new() as EquippedItemReconciler
	reconciler.name = "EquippedItemReconciler"
	root.add_child(reconciler)
	var publications: Array[Dictionary] = []
	var publication_immutability: Array[bool] = []
	var invalidations: Array[StringName] = []
	reconciler.reconciliation_published.connect(func(outcome: Dictionary):
		publications.append(outcome.duplicate(true))
		publication_immutability.append(_publication_is_deep_read_only(outcome)))
	reconciler.binding_invalidated.connect(func(reason: StringName):
		invalidations.append(reason))
	check(reconciler.bind_owner(
		owner, bridge, admission, owner_generation, raid_scope_generation),
		"reconciler binds exact owner, admission, and raid projection generations")
	check(reconciler.is_bound(), "reconciler reports a current binding")
	check(reconciler.current_revision() == 0, "initial empty snapshot revision is accepted")
	check(reconciler.current_mappings().is_empty(),
		"initial equipment projection has no live weapon mappings")
	check(publications.size() == 1
		and bool(publications[0].get("initial", false))
		and not bool(publications[0].get("changed", true)),
		"initial empty reconciliation publishes once without a false equipment change")

	# The reconciler snapshots the admission. Later caller mutation cannot rename
	# equipment identities or alter published principal context.
	admission.generation = 999
	admission.authority_epoch = 999
	admission.session_id = ZSessionId.from_parts(
		PackedStringArray(["offline", "mutated", "00000999"]))
	check(reconciler.is_bound(), "caller mutation of admission cannot alter captured binding")

	var authority := owner.raid_authority()
	var player_inventory_id := owner.raid_player_inventory_id
	var initial_snapshot := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, player_inventory_id)
	var initial_outcome_bytes := _outcome_digest(reconciler.current_outcome())

	# A different authority can reuse native numeric ids. Even with matching
	# owner/scope token numbers, its newer bytes are not the current projection.
	var foreign_owner := RaidInventoryOwner.new()
	foreign_owner.name = "ForeignEquipmentInventoryOwner"
	root.add_child(foreign_owner)
	check(foreign_owner.configure(), "foreign owner configures with colliding native ids")
	var foreign_snapshot_before := foreign_owner.raid_authority().snapshot(
		foreign_owner.raid_player_inventory_id)
	check(foreign_snapshot_before.canonical_bytes()
		== initial_snapshot.canonical_bytes(),
		"independent native authorities can produce byte-identical initial snapshots")
	var identical_foreign_result := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		foreign_snapshot_before,
		owner_generation,
		raid_scope_generation
	)
	check(not bool(identical_foreign_result.get("accepted", true))
		and identical_foreign_result.get("reason", &"")
			== &"snapshot_not_current_projection",
		"byte-identical foreign snapshot is rejected by exact Resource provenance")
	check(_outcome_digest(reconciler.current_outcome()) == initial_outcome_bytes,
		"byte-identical foreign rejection leaves reconciled state unchanged")
	var foreign_pockets := _root_container_by_definition(
		foreign_snapshot_before, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	var foreign_insert: Dictionary = foreign_owner.raid_authority().insert_item(
		foreign_owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_GOLD_WATCH),
		1,
		_spatial(foreign_pockets, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		901
	)
	check(bool(foreign_insert.get("accepted", false)),
		"foreign fixture advances a same-numbered inventory")
	var foreign_snapshot := foreign_owner.raid_authority().snapshot(
		foreign_owner.raid_player_inventory_id)
	var foreign_result := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		foreign_snapshot,
		owner_generation,
		raid_scope_generation
	)
	check(not bool(foreign_result.get("accepted", true))
		and foreign_result.get("reason", &"") == &"snapshot_not_current_projection",
		"foreign authority snapshot is rejected despite colliding native scope numbers")
	check(_outcome_digest(reconciler.current_outcome()) == initial_outcome_bytes,
		"foreign snapshot rejection leaves reconciled state byte-identical")
	check(foreign_owner.teardown(foreign_owner.generation()), "foreign owner tears down")
	foreign_owner.queue_free()

	var profile_scope_result := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_PROFILE,
		bridge.confirmed_snapshot(
			InventoryProjectionBridge.SCOPE_PROFILE, owner.profile_inventory_id),
		owner_generation,
		bridge.scope_generation(InventoryProjectionBridge.SCOPE_PROFILE)
	)
	check(not bool(profile_scope_result.get("accepted", true))
		and profile_scope_result.get("reason", &"") == &"scope_mismatch",
		"profile projection is rejected even though native inventory ids collide")
	var wrong_owner_generation := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		initial_snapshot,
		owner_generation + 1,
		raid_scope_generation
	)
	check(wrong_owner_generation.get("reason", &"") == &"owner_generation_mismatch",
		"foreign owner generation is rejected")
	var wrong_scope_generation := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		initial_snapshot,
		owner_generation,
		raid_scope_generation + 1
	)
	check(wrong_scope_generation.get("reason", &"") == &"scope_generation_mismatch",
		"foreign raid projection generation is rejected")
	check(_outcome_digest(reconciler.current_outcome()) == initial_outcome_bytes,
		"scope and generation rejections are fail-atomic")

	var equipment_container := _root_container_by_definition(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var backpack_container := _root_container_by_definition(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_BACKPACK)
	var pockets_container := _root_container_by_definition(
		initial_snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	check(equipment_container > 0 and backpack_container > 0 and pockets_container > 0,
		"canonical equipment, backpack, and pockets roots resolve by definition")

	var primary_insert: Dictionary = authority.insert_item(
		player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment_container, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_001
	)
	check(bool(primary_insert.get("accepted", false)), "AKM equips in the canonical primary slot")
	var first_akm_item_id := int(primary_insert.get("new_item_id", 0))
	var primary_mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	var first_weapon_key := String(primary_mapping.get("weapon_id", ""))
	var first_entity_key := String(primary_mapping.get("entity_id", ""))
	check(first_akm_item_id > 0 and not primary_mapping.is_empty(),
		"accepted equipment revision creates one primary mapping")
	check(primary_mapping.get("native_item_id", 0) == first_akm_item_id
		and primary_mapping.get("item_definition_identifier", &"")
			== ZerkovInventoryCatalog.ITEM_AKM,
		"mapping retains the canonical native item and inventory definition")
	check(primary_mapping.get("combat_definition_identifier", &"")
		== ZerkovCombatContent.WEAPON_AKM
		and primary_mapping.get("weapon_kind", &"")
			== EquippedItemReconciler.WEAPON_KIND_FIREARM,
		"AKM mapping exposes the canonical combat definition and firearm kind")
	var typed_weapon := reconciler.weapon_id_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	var typed_entity := reconciler.entity_id_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	check(typed_weapon != null and typed_weapon.kind() == ZWeaponId.KIND
		and typed_weapon.canonical_key() == first_weapon_key,
		"primary mapping exposes a validated typed ZWeaponId")
	check(typed_entity != null and typed_entity.kind() == ZEntityId.KIND
		and typed_entity.canonical_key() == first_entity_key,
		"primary mapping exposes a validated typed ZEntityId")
	check(String(reconciler.current_outcome().get("session_id", ""))
		== canonical_admission.session_id.canonical_key()
		and int(reconciler.current_outcome().get("authority_epoch", 0))
			== canonical_admission.authority_epoch,
		"published identity context uses the captured admission copy")
	var first_mapping_for_replay := primary_mapping.duplicate(true)
	var first_state_digest_for_replay := _mapping_state_digest(reconciler.current_outcome())

	var equal_divergent_result := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		foreign_snapshot,
		owner_generation,
		raid_scope_generation
	)
	check(not bool(equal_divergent_result.get("accepted", true))
		and equal_divergent_result.get("reason", &"")
			== &"equal_revision_divergence",
		"equal-revision foreign bytes are rejected as divergence before provenance")
	check(String(reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_PRIMARY).get("weapon_id", "")) == first_weapon_key,
		"equal-revision divergence cannot alter the accepted equipment mapping")

	var publications_before_duplicate := publications.size()
	var duplicate_result := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID, player_inventory_id),
		owner_generation,
		raid_scope_generation
	)
	check(bool(duplicate_result.get("accepted", false))
		and bool(duplicate_result.get("duplicate", false))
		and not bool(duplicate_result.get("changed", true)),
		"duplicate snapshot is an accepted idempotent no-op")
	check(publications.size() == publications_before_duplicate,
		"duplicate snapshot creates no publication churn")
	bridge.snapshot_projected.emit(
		InventoryProjectionBridge.SCOPE_RAID,
		player_inventory_id,
		reconciler.current_revision()
	)
	check(publications.size() == publications_before_duplicate,
		"duplicate bridge callback is also a no-op")

	var state_after_primary := _outcome_digest(reconciler.current_outcome())
	var stale_result := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		initial_snapshot,
		owner_generation,
		raid_scope_generation
	)
	check(not bool(stale_result.get("accepted", true))
		and stale_result.get("reason", &"") == &"stale_snapshot_revision",
		"out-of-order older snapshot is rejected")
	check(_outcome_digest(reconciler.current_outcome()) == state_after_primary,
		"stale snapshot cannot regress a live mapping")

	# Getter and signal payloads are detached deep copies. Caller mutation never
	# reaches the reconciler's internal mapping registry.
	var exposed_outcome := reconciler.current_outcome()
	var exposed_mappings := exposed_outcome.get("mappings", []) as Array
	if not exposed_mappings.is_empty():
		(exposed_mappings[0] as Dictionary)["weapon_id"] = "mutated"
		exposed_mappings.clear()
	exposed_outcome["revision"] = 999_999
	var exposed_mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	exposed_mapping["entity_id"] = "mutated"
	check(reconciler.current_revision() != 999_999
		and reconciler.current_mappings().size() == 1
		and String(reconciler.mapping_for_slot(
			EquippedItemReconciler.SLOT_PRIMARY).get("weapon_id", "")) == first_weapon_key
		and String(reconciler.mapping_for_slot(
			EquippedItemReconciler.SLOT_PRIMARY).get("entity_id", "")) == first_entity_key,
		"caller mutation of outcomes and mappings is isolated")

	var melee_insert: Dictionary = authority.insert_item(
		player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MACHETE),
		1,
		_slot(equipment_container, EquippedItemReconciler.SLOT_MELEE),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_002
	)
	check(bool(melee_insert.get("accepted", false)),
		"machete equips in the canonical melee slot")
	var machete_item_id := int(melee_insert.get("new_item_id", 0))
	var melee_mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_MELEE)
	check(reconciler.current_mappings().size() == 2,
		"primary and melee slots coexist as two live weapon mappings")
	check(melee_mapping.get("native_item_id", 0) == machete_item_id
		and melee_mapping.get("combat_definition_identifier", &"")
			== ZerkovCombatContent.WEAPON_MACHETE
		and melee_mapping.get("weapon_kind", &"")
			== EquippedItemReconciler.WEAPON_KIND_MELEE,
		"machete mapping identifies game-owned melee content")
	check(String(melee_mapping.get("weapon_id", "")) != first_weapon_key
		and String(melee_mapping.get("entity_id", "")) != first_entity_key,
		"two native weapon items cannot collide in either stable identity domain")

	var retained_weapon_keys := _weapon_keys(reconciler.current_mappings())
	var irrelevant_insert: Dictionary = authority.insert_item(
		player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_BANDAGE),
		1,
		_spatial(pockets_container, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_003
	)
	check(bool(irrelevant_insert.get("accepted", false)),
		"non-equipment player inventory revision commits")
	var irrelevant_outcome := reconciler.current_outcome()
	check(not bool(irrelevant_outcome.get("changed", true))
		and (irrelevant_outcome.get("retained", []) as Array).size() == 2,
		"irrelevant accepted revision retains mappings without false churn")
	check(_weapon_keys(reconciler.current_mappings()) == retained_weapon_keys,
		"irrelevant inventory mutation cannot rename equipped items")

	var unequip_result: Dictionary = authority.move_item(
		player_inventory_id,
		first_akm_item_id,
		_spatial(backpack_container, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_004
	)
	check(bool(unequip_result.get("accepted", false)), "AKM unequips into the backpack")
	check(reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY).is_empty()
		and reconciler.current_mappings().size() == 1,
		"unequip removes the live primary mapping")
	var unequip_outcome := reconciler.current_outcome()
	check((unequip_outcome.get("removed", []) as Array).size() == 1
		and String(((unequip_outcome.get("removed", []) as Array)[0]
			as Dictionary).get("weapon_id", "")) == first_weapon_key,
		"unequip publishes the exact removed identity")

	var reequip_result: Dictionary = authority.equip_item(
		player_inventory_id,
		first_akm_item_id,
		equipment_container,
		String(EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_005
	)
	check(bool(reequip_result.get("accepted", false)), "same canonical AKM re-equips")
	var reequip_mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	check(String(reequip_mapping.get("weapon_id", "")) == first_weapon_key
		and String(reequip_mapping.get("entity_id", "")) == first_entity_key,
		"re-equipping the same item recreates identical slot-independent IDs")

	var move_for_replacement: Dictionary = authority.move_item(
		player_inventory_id,
		first_akm_item_id,
		_spatial(backpack_container, 0, 0),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_006
	)
	check(bool(move_for_replacement.get("accepted", false)),
		"old primary unequips before replacement")
	var replacement_insert: Dictionary = authority.insert_item(
		player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment_container, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_007
	)
	check(bool(replacement_insert.get("accepted", false)), "replacement AKM equips")
	var replacement_item_id := int(replacement_insert.get("new_item_id", 0))
	var replacement_mapping := reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_PRIMARY)
	check(replacement_item_id != first_akm_item_id
		and replacement_mapping.get("native_item_id", 0) == replacement_item_id,
		"replacement maps the new canonical item instance")
	check(String(replacement_mapping.get("weapon_id", "")) != first_weapon_key
		and String(replacement_mapping.get("entity_id", "")) != first_entity_key,
		"replacement native item receives distinct collision-resistant identities")

	var destroy_melee: Dictionary = authority.remove_item(
		player_inventory_id,
		machete_item_id,
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_008
	)
	check(bool(destroy_melee.get("accepted", false)), "equipped machete is destroyed canonically")
	check(reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_MELEE).is_empty()
		and reconciler.current_mappings().size() == 1,
		"destruction removes the melee mapping")
	check((reconciler.current_outcome().get("removed", []) as Array).size() == 1,
		"destruction publishes one removal")
	var replacement_melee_insert: Dictionary = authority.insert_item(
		player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_MACHETE),
		1,
		_slot(equipment_container, EquippedItemReconciler.SLOT_MELEE),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_009
	)
	check(bool(replacement_melee_insert.get("accepted", false)),
		"a new canonical machete can equip after destruction")
	var replacement_melee_item_id := int(replacement_melee_insert.get("new_item_id", 0))
	var replacement_melee_mapping := reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_MELEE)
	check(replacement_melee_item_id != machete_item_id
		and String(replacement_melee_mapping.get("weapon_id", ""))
			!= String(melee_mapping.get("weapon_id", ""))
		and String(replacement_melee_mapping.get("entity_id", ""))
			!= String(melee_mapping.get("entity_id", "")),
		"post-destruction replacement receives distinct non-resurrected identities")
	var remove_replacement_melee: Dictionary = authority.remove_item(
		player_inventory_id,
		replacement_melee_item_id,
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_010
	)
	check(bool(remove_replacement_melee.get("accepted", false))
		and reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_MELEE).is_empty(),
		"replacement melee destruction reconciles before persistence replacement")

	_test_identity_collision_boundaries(
		canonical_admission,
		owner_generation,
		player_inventory_id,
		first_akm_item_id
	)

	# Same-id persistence replacement is a canonical runtime generation edge.
	# The bridge advances its projection generation; the old equipment mapping
	# must disappear before the replacement snapshot becomes visible.
	var pre_replace_mapping := replacement_mapping.duplicate(true)
	var pre_replace_record := authority.make_persistence_record(player_inventory_id)
	check(not pre_replace_record.is_empty(), "equipped inventory persistence record is available")
	var publications_before_replace := publications.size()
	var replacement_result: Dictionary = authority.apply_persistence_record(
		pre_replace_record, true)
	check(bool(replacement_result.get("ok", false)),
		"same-id inventory generation replacement commits")
	check(reconciler.lifecycle == EquippedItemReconciler.Lifecycle.INVALIDATED
		and reconciler.current_mappings().is_empty(),
		"generation replacement invalidates and clears every live mapping")
	check(publications.size() == publications_before_replace + 1
		and bool(publications.back().get("invalidated", false))
		and (publications.back().get("removed", []) as Array).size() == 1,
		"generation replacement publishes one removal boundary")
	var invalidated_digest := _outcome_digest(reconciler.current_outcome())
	bridge.snapshot_projected.emit(
		InventoryProjectionBridge.SCOPE_RAID,
		player_inventory_id,
		int(pre_replace_mapping.get("native_item_id", 0))
	)
	check(_outcome_digest(reconciler.current_outcome()) == invalidated_digest,
		"late callback from the retired projection cannot restore mappings")
	await process_frame
	await process_frame
	var replacement_scope_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	check(replacement_scope_generation > raid_scope_generation
		and bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
			== InventoryProjectionBridge.ProjectionStatus.READY,
		"bridge publishes a fresh ready generation after replacement")
	check(reconciler.bind_owner(
		owner,
		bridge,
		canonical_admission,
		owner_generation,
		replacement_scope_generation
	), "invalidated reconciler rebinds to the replacement projection generation")
	var rebound_mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_PRIMARY)
	check(String(rebound_mapping.get("weapon_id", ""))
		== String(pre_replace_mapping.get("weapon_id", ""))
		and String(rebound_mapping.get("entity_id", ""))
			== String(pre_replace_mapping.get("entity_id", "")),
		"projection generation replacement does not rename the same canonical item")

	# Independent replay with identical raid/admission/owner/native identity
	# recreates the exact initial AKM mapping despite different Node instances.
	var replay_owner := RaidInventoryOwner.new()
	replay_owner.name = "ReplayEquipmentInventoryOwner"
	root.add_child(replay_owner)
	check(replay_owner.configure(), "replay inventory owner configures")
	var replay_snapshot := replay_owner.raid_authority().snapshot(
		replay_owner.raid_player_inventory_id)
	var replay_equipment := _root_container_by_definition(
		replay_snapshot, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var replay_insert: Dictionary = replay_owner.raid_authority().insert_item(
		replay_owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(replay_equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_001
	)
	check(bool(replay_insert.get("accepted", false))
		and int(replay_insert.get("new_item_id", 0)) == first_akm_item_id,
		"replay recreates the same native item identity")
	var replay_bridge := InventoryProjectionBridge.new()
	replay_bridge.name = "ReplayEquipmentProjectionBridge"
	root.add_child(replay_bridge)
	check(replay_bridge.bind_owner(replay_owner, replay_owner.generation()),
		"replay bridge binds")
	var replay_reconciler := EquippedItemReconcilerScript.new() as EquippedItemReconciler
	replay_reconciler.name = "ReplayEquippedItemReconciler"
	root.add_child(replay_reconciler)
	check(replay_reconciler.bind_owner(
		replay_owner,
		replay_bridge,
		canonical_admission,
		replay_owner.generation(),
		replay_bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	), "replay reconciler binds")
	var replay_mapping := replay_reconciler.mapping_for_slot(
		EquippedItemReconciler.SLOT_PRIMARY)
	check(String(replay_mapping.get("weapon_id", ""))
		== String(first_mapping_for_replay.get("weapon_id", ""))
			and String(replay_mapping.get("entity_id", ""))
				== String(first_mapping_for_replay.get("entity_id", "")),
		"deterministic replay produces identical weapon/entity mappings")
	check(_mapping_state_digest(replay_reconciler.current_outcome())
		== first_state_digest_for_replay,
		"independent runs produce byte-identical authoritative mapping state")

	var replay_generation := replay_owner.generation()
	check(replay_owner.teardown(replay_generation), "replay owner tears down")
	check(replay_reconciler.current_mappings().is_empty(),
		"replay teardown removes its live mapping")
	replay_reconciler.queue_free()
	replay_bridge.queue_free()
	replay_owner.queue_free()

	var before_teardown_publications := publications.size()
	check(owner.teardown(owner_generation), "primary inventory owner tears down")
	check(reconciler.lifecycle == EquippedItemReconciler.Lifecycle.INVALIDATED
		and not reconciler.is_bound() and reconciler.current_mappings().is_empty(),
		"owner teardown invalidates the rebound reconciler")
	check(publications.size() == before_teardown_publications + 1
		and (reconciler.current_outcome().get("removed", []) as Array).size() == 1,
		"teardown publishes the remaining equipment removal exactly once")
	var terminal_outcome := _outcome_digest(reconciler.current_outcome())
	bridge.snapshot_projected.emit(
		InventoryProjectionBridge.SCOPE_RAID,
		player_inventory_id,
		9_999
	)
	var late_manual := reconciler.reconcile_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		initial_snapshot,
		owner_generation,
		replacement_scope_generation
	)
	check(not bool(late_manual.get("accepted", true))
		and late_manual.get("reason", &"") == &"reconciler_not_bound",
		"manual late snapshot is rejected after teardown")
	check(_outcome_digest(reconciler.current_outcome()) == terminal_outcome,
		"late bridge/manual callbacks cannot mutate terminal reconciliation state")
	check(not invalidations.is_empty(), "lifecycle invalidation is observable")
	check(not publication_immutability.has(false),
		"every signal projection is recursively read-only for all listeners")

	# A rejected replacement bind preserves the terminal invalidation record.
	# This keeps teardown/removal evidence queryable until a complete new binding
	# has passed every validation gate.
	var terminal_owner_generation := reconciler.owner_generation()
	var terminal_scope_generation := reconciler.scope_generation()
	check(not reconciler.bind_owner(
		owner,
		bridge,
		canonical_admission,
		owner_generation,
		replacement_scope_generation
	), "torn-down owner cannot replace an invalidated reconciliation binding")
	check(reconciler.lifecycle == EquippedItemReconciler.Lifecycle.INVALIDATED
		and reconciler.owner_generation() == terminal_owner_generation
		and reconciler.scope_generation() == terminal_scope_generation
		and _outcome_digest(reconciler.current_outcome()) == terminal_outcome,
		"failed rebind preserves the complete terminal outcome and binding tokens")

	await _test_reentrant_publication_order(canonical_admission)
	await _test_initial_publication_release(canonical_admission)

	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()
	await process_frame
	print("EQUIPPED_ITEM_RECONCILIATION_RESULT checks=", checks,
		" failures=", failures, " publications=", publications.size())
	quit(0 if failures == 0 else 1)


func _test_identity_collision_boundaries(
	admission: ZSessionAdmission,
	owner_generation: int,
	inventory_id: int,
	native_item_id: int
) -> void:
	var base := EquippedItemReconciler.derive_identity_keys(
		admission,
		owner_generation,
		inventory_id,
		native_item_id,
		ZerkovInventoryCatalog.ITEM_AKM
	)
	check(not base.is_empty(), "identity helper derives the base typed keys")
	var alternate_raid := ZRaidId.from_parts(PackedStringArray(["fixture", "equipment_002"]))
	var alternate_coordinator := SessionCoordinator.new(OfflineSessionIngress.new())
	var alternate_admission := alternate_coordinator.open_offline(
		alternate_raid, &"equipment_profile", &"player")
	var changed_admission := EquippedItemReconciler.derive_identity_keys(
		alternate_admission,
		owner_generation,
		inventory_id,
		native_item_id,
		ZerkovInventoryCatalog.ITEM_AKM
	)
	var next_session := SessionCoordinator.new(OfflineSessionIngress.new())
	var different_principal := next_session.open_offline(
		admission.raid_id, &"equipment_profile_b", &"player")
	var changed_principal := EquippedItemReconciler.derive_identity_keys(
		different_principal,
		owner_generation,
		inventory_id,
		native_item_id,
		ZerkovInventoryCatalog.ITEM_AKM
	)
	var changed_session_admission := admission.snapshot()
	changed_session_admission.session_id = ZSessionId.from_parts(PackedStringArray([
		"offline", "equipment_session_b", "00000001"]))
	var changed_actor_admission := admission.snapshot()
	changed_actor_admission.actor_id = ZEntityId.from_parts(PackedStringArray([
		"offline", "equipment_profile", "alternate", "00000001"]))
	var changed_epoch_admission := admission.snapshot()
	changed_epoch_admission.authority_epoch += 1
	var changed_generation_admission := admission.snapshot()
	changed_generation_admission.generation += 1
	var variants: Array[Dictionary] = [
		changed_admission,
		changed_principal,
		EquippedItemReconciler.derive_identity_keys(
			changed_session_admission, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			changed_actor_admission, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			changed_epoch_admission, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			changed_generation_admission, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation + 1, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation, inventory_id + 1, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation, inventory_id, native_item_id + 1,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_MACHETE),
	]
	var seen_weapon_ids: Dictionary = {String(base.get("weapon_id", "")): true}
	var seen_entity_ids: Dictionary = {String(base.get("entity_id", "")): true}
	for variant in variants:
		check(not variant.is_empty()
			and String(variant.get("weapon_id", "")) != String(base.get("weapon_id", ""))
			and String(variant.get("entity_id", "")) != String(base.get("entity_id", "")),
			"each authoritative identity boundary changes both stable domains")
		check(not seen_weapon_ids.has(String(variant.get("weapon_id", "")))
			and not seen_entity_ids.has(String(variant.get("entity_id", ""))),
			"authoritative boundary variants do not collide with each other")
		seen_weapon_ids[String(variant.get("weapon_id", ""))] = true
		seen_entity_ids[String(variant.get("entity_id", ""))] = true
	check(ZWeaponId.parse(String(base.get("weapon_id", ""))) != null
		and ZEntityId.parse(String(base.get("entity_id", ""))) != null,
		"derived keys conform to the canonical typed identity grammar")
	check(EquippedItemReconciler.derive_identity_keys(
		admission, owner_generation, inventory_id, native_item_id,
		&"zerkov.item.weapon.unknown").is_empty(),
		"identity derivation rejects content outside the canonical weapon allowlist")
	var repeated := EquippedItemReconciler.derive_identity_keys(
		admission,
		owner_generation,
		inventory_id,
		native_item_id,
		ZerkovInventoryCatalog.ITEM_AKM
	)
	check(repeated == base,
		"identity derivation is deterministic and has no mutable slot/revision input")
	var weapon_keys: Dictionary = {}
	var entity_keys: Dictionary = {}
	var bulk_valid := true
	for offset in range(256):
		var keys := EquippedItemReconciler.derive_identity_keys(
			admission,
			owner_generation,
			inventory_id,
			native_item_id + offset,
			ZerkovInventoryCatalog.ITEM_AKM
		)
		var weapon_key := String(keys.get("weapon_id", ""))
		var entity_key := String(keys.get("entity_id", ""))
		if keys.is_empty() or weapon_keys.has(weapon_key) or entity_keys.has(entity_key) \
				or ZWeaponId.parse(weapon_key) == null \
				or ZEntityId.parse(entity_key) == null:
			bulk_valid = false
			break
		weapon_keys[weapon_key] = true
		entity_keys[entity_key] = true
	check(bulk_valid and weapon_keys.size() == 256 and entity_keys.size() == 256,
		"bounded collision fixture yields 256 unique typed identities per domain")
	var weapon_key := String(base.get("weapon_id", ""))
	var entity_key := String(base.get("entity_id", ""))
	check(weapon_key.to_utf8_buffer().size() <= ZIdentityRules.MAX_IDENTIFIER_BYTES
		and entity_key.to_utf8_buffer().size() <= ZIdentityRules.MAX_IDENTIFIER_BYTES
		and weapon_key.get_slice(".", 3).to_utf8_buffer().size()
			== EquippedItemReconciler.IDENTITY_HASH_SEGMENT_BYTES
		and entity_key.get_slice(".", 3).to_utf8_buffer().size()
			== EquippedItemReconciler.IDENTITY_HASH_SEGMENT_BYTES,
		"runtime identities stay inside canonical identifier and hash-segment bounds")
	var invalid_identity_inputs: Array[Dictionary] = [
		EquippedItemReconciler.derive_identity_keys(
			null, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, 0, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation, 0, native_item_id,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation, inventory_id, 0,
			ZerkovInventoryCatalog.ITEM_AKM),
		EquippedItemReconciler.derive_identity_keys(
			admission, owner_generation, inventory_id, native_item_id,
			ZerkovInventoryCatalog.ITEM_BANDAGE),
	]
	var invalid_inputs_rejected := true
	for invalid in invalid_identity_inputs:
		if not invalid.is_empty():
			invalid_inputs_rejected = false
	check(invalid_inputs_rejected,
		"identity derivation rejects missing, nonpositive, and nonweapon inputs")


func _test_reentrant_publication_order(admission: ZSessionAdmission) -> void:
	var owner := RaidInventoryOwner.new()
	owner.name = "ReentrantEquipmentInventoryOwner"
	root.add_child(owner)
	check(owner.configure(), "reentrant publication fixture owner configures")
	var owner_generation := owner.generation()
	var authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var initial := authority.snapshot(inventory_id)
	var equipment := _root_container_by_definition(
		initial, ZerkovInventoryCatalog.CONTAINER_EQUIPMENT)
	var bridge := InventoryProjectionBridge.new()
	bridge.name = "ReentrantEquipmentProjectionBridge"
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"reentrant publication fixture bridge binds")
	var reconciler := EquippedItemReconcilerScript.new() as EquippedItemReconciler
	reconciler.name = "ReentrantEquippedItemReconciler"
	root.add_child(reconciler)

	var release_state := {
		"fired": false,
	}
	var observer_revisions: Array[int] = []
	var observer_edges: Array[StringName] = []
	reconciler.reconciliation_published.connect(func(outcome: Dictionary):
		if bool(release_state["fired"]) \
				or (outcome.get("added", []) as Array).is_empty():
			return
		release_state["fired"] = true
		reconciler.release_binding(&"fixture_reentrant_release"))
	reconciler.reconciliation_published.connect(func(outcome: Dictionary):
		observer_revisions.append(int(outcome.get("revision", -1)))
		if bool(outcome.get("invalidated", false)):
			observer_edges.append(&"invalidated")
		elif not (outcome.get("added", []) as Array).is_empty():
			observer_edges.append(&"added")
		elif not (outcome.get("removed", []) as Array).is_empty():
			observer_edges.append(&"removed")
		else:
			observer_edges.append(&"retained"))
	check(reconciler.bind_owner(
		owner,
		bridge,
		admission,
		owner_generation,
		bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	), "reentrant publication fixture reconciler binds")
	var insert: Dictionary = authority.insert_item(
		inventory_id,
		String(ZerkovInventoryCatalog.ITEM_AKM),
		1,
		_slot(equipment, EquippedItemReconciler.SLOT_PRIMARY),
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		2_001
	)
	check(bool(insert.get("accepted", false)) and bool(release_state["fired"]),
		"an equipment listener can request release during publication")
	check(observer_revisions == [0, 1, 1],
		"all listeners observe accepted state before its deferred invalidation")
	check(observer_edges == [&"retained", &"added", &"invalidated"]
		and reconciler.lifecycle == EquippedItemReconciler.Lifecycle.INVALIDATED
		and reconciler.current_mappings().is_empty(),
		"reentrant release publishes add before removal and converges invalidated")

	check(owner.teardown(owner_generation), "reentrant publication fixture tears down")
	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()


func _test_initial_publication_release(admission: ZSessionAdmission) -> void:
	var owner := RaidInventoryOwner.new()
	owner.name = "InitialReleaseEquipmentInventoryOwner"
	root.add_child(owner)
	check(owner.configure(), "initial-release fixture owner configures")
	var owner_generation := owner.generation()
	var bridge := InventoryProjectionBridge.new()
	bridge.name = "InitialReleaseEquipmentProjectionBridge"
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner_generation),
		"initial-release fixture bridge binds")
	var reconciler := EquippedItemReconcilerScript.new() as EquippedItemReconciler
	reconciler.name = "InitialReleaseEquippedItemReconciler"
	root.add_child(reconciler)
	var release_state := {"fired": false}
	reconciler.reconciliation_published.connect(func(outcome: Dictionary):
		if bool(release_state["fired"]) or bool(outcome.get("invalidated", false)):
			return
		release_state["fired"] = true
		reconciler.release_binding(&"fixture_initial_release"))
	var bound := reconciler.bind_owner(
		owner,
		bridge,
		admission,
		owner_generation,
		bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	)
	check(not bound and bool(release_state["fired"])
		and reconciler.lifecycle == EquippedItemReconciler.Lifecycle.INVALIDATED
		and reconciler.last_error == &"fixture_initial_release",
		"bind cannot report success after its initial publication tears down")
	check(reconciler.current_mappings().is_empty()
		and bool(reconciler.current_outcome().get("invalidated", false)),
		"initial-publication release leaves one coherent terminal projection")

	check(owner.teardown(owner_generation), "initial-release fixture tears down")
	reconciler.queue_free()
	bridge.queue_free()
	owner.queue_free()


func _root_container_by_definition(
	snapshot: InventorySnapshotResource,
	definition_identifier: StringName
) -> int:
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get("container_definition_identifier", "")) \
					== definition_identifier:
			return int(container.get("id", 0))
	return 0


func _slot(container_id: int, slot_identifier: StringName) -> Dictionary:
	return {
		"kind": "slot",
		"container": container_id,
		"slot_identifier": String(slot_identifier),
	}


func _spatial(container_id: int, x: int, y: int) -> Dictionary:
	return {
		"kind": "spatial",
		"container": container_id,
		"x": x,
		"y": y,
		"rotated": false,
	}


func _weapon_keys(mappings: Array[Dictionary]) -> PackedStringArray:
	var result := PackedStringArray()
	for mapping in mappings:
		result.append(String(mapping.get("weapon_id", "")))
	return result


func _outcome_digest(outcome: Dictionary) -> String:
	return ZCanonicalValue.sha256(outcome)


func _mapping_state_digest(outcome: Dictionary) -> String:
	return ZCanonicalValue.sha256({
		"raid_id": outcome.get("raid_id", ""),
		"session_id": outcome.get("session_id", ""),
		"actor_id": outcome.get("actor_id", ""),
		"authority_epoch": outcome.get("authority_epoch", 0),
		"admission_generation": outcome.get("admission_generation", 0),
		"owner_generation": outcome.get("owner_generation", 0),
		"scope_generation": outcome.get("scope_generation", 0),
		"inventory_id": outcome.get("inventory_id", 0),
		"revision": outcome.get("revision", -1),
		"snapshot_digest": outcome.get("snapshot_digest", ""),
		"mappings": outcome.get("mappings", []),
	})


func _publication_is_deep_read_only(outcome: Dictionary) -> bool:
	if not outcome.is_read_only():
		return false
	for field in [&"mappings", &"added", &"removed", &"updated", &"retained"]:
		var values := outcome.get(field, []) as Array
		if not values.is_read_only():
			return false
		for value in values:
			if value is Dictionary:
				var mapping := value as Dictionary
				if not mapping.is_read_only():
					return false
				for nested in mapping.values():
					if nested is Dictionary and not (nested as Dictionary).is_read_only():
						return false
	return true
