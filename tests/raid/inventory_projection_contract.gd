extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/inventory_projection_contract.gd
##
## Task 4.6 contract: immutable native snapshots feed separate profile/raid
## presentation scopes; pending placement never changes confirmed placement;
## result refresh, rejection rollback, monotonic revisions, replacement
## generations, resynchronization, and teardown all fail closed.

const InventoryProjectionBridge := preload(
	"res://game/inventory/presentation/inventory_projection_bridge.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_PROJECTION_CONTRACT: " + message)


func run() -> void:
	var owner := RaidInventoryOwner.new()
	owner.name = "InventoryProjectionOwner"
	root.add_child(owner)
	check(owner.configure(), "inventory owner configures")
	var owner_generation := owner.generation()
	check(owner.materialize_loot_fixture(owner_generation), "loot fixture materializes")

	var bridge := InventoryProjectionBridge.new() as InventoryProjectionBridge
	bridge.name = "InventoryProjectionBridge"
	root.add_child(bridge)
	var status_history: Array[Dictionary] = []
	var ignored_history: Array[Dictionary] = []
	bridge.projection_status_changed.connect(func(scope: StringName, status: int):
		status_history.append({"scope": scope, "status": status}))
	bridge.snapshot_ignored.connect(func(scope: StringName, inventory_id: int, revision: int, reason: StringName):
		ignored_history.append({"scope": scope, "inventory_id": inventory_id,
			"revision": revision, "reason": reason}))
	check(bridge.bind_owner(owner, owner_generation),
		"bridge binds the exact active owner generation")
	check(_saw_status(status_history, InventoryProjectionBridge.SCOPE_PROFILE,
		InventoryProjectionBridge.ProjectionStatus.LOADING),
		"profile binding exposes loading before its initial snapshot")
	check(_saw_status(status_history, InventoryProjectionBridge.SCOPE_RAID,
		InventoryProjectionBridge.ProjectionStatus.LOADING),
		"raid binding exposes loading before its initial snapshots")
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_PROFILE)
		== InventoryProjectionBridge.ProjectionStatus.READY,
		"profile projection becomes ready")
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.READY,
		"raid projection becomes ready")

	var profile_model := bridge.presentation_model(InventoryProjectionBridge.SCOPE_PROFILE)
	var raid_model := bridge.presentation_model(InventoryProjectionBridge.SCOPE_RAID)
	var accepted_feedback := {"count": 0}
	var raid_model_changes := {"count": 0}
	raid_model.accepted_feedback.connect(func(_info: Dictionary):
		accepted_feedback["count"] = int(accepted_feedback["count"]) + 1)
	raid_model.model_changed.connect(func():
		raid_model_changes["count"] = int(raid_model_changes["count"]) + 1)
	check(profile_model != null and raid_model != null and profile_model != raid_model,
		"independent authorities receive separate presentation models")
	check(owner.profile_inventory_id == owner.raid_player_inventory_id,
		"fixture proves native ids collide across independent authority allocators")
	check(profile_model.has_snapshot(owner.profile_inventory_id)
		and raid_model.has_snapshot(owner.raid_player_inventory_id),
		"colliding ids remain valid in their explicit scopes")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_PROFILE,
		owner.profile_inventory_id) == owner.profile_authority().inventory_revision(
		owner.profile_inventory_id), "initial profile snapshot revision matches authority")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID,
		owner.world_crate_inventory_id) == owner.raid_authority().inventory_revision(
		owner.world_crate_inventory_id), "initial raid snapshot revision matches authority")

	var crate_id := owner.world_crate_inventory_id
	var authority := owner.raid_authority()
	var initial_snapshot := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id)
	var initial_bytes := initial_snapshot.canonical_bytes()
	var crate_container_id := owner.world_crate_container_id()
	var inserted: Dictionary = authority.insert_item(
		crate_id,
		String(ZerkovInventoryCatalog.ITEM_BOLTS),
		1,
		{"kind": "spatial", "container": crate_container_id,
			"x": 7, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_001
	)
	check(bool(inserted.get("accepted", false)), "untracked authority insert is accepted")
	var refreshed_snapshot := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id)
	check(refreshed_snapshot != null and refreshed_snapshot.get_revision()
		== initial_snapshot.get_revision() + 1,
		"accepted authority result refreshes the immutable projection")
	check(initial_snapshot.canonical_bytes() == initial_bytes,
		"previous snapshot remains an immutable value copy after authority mutation")
	check(initial_snapshot.get_items().size() + 1 == refreshed_snapshot.get_items().size(),
		"old and refreshed snapshots do not alias")
	var public_items := refreshed_snapshot.get_items()
	var public_bytes_before := refreshed_snapshot.canonical_bytes()
	if not public_items.is_empty():
		(public_items[0] as Dictionary)["quantity"] = 9_999_999
		public_items.clear()
	check(refreshed_snapshot.canonical_bytes() == public_bytes_before,
		"public snapshot collections are detached copies of immutable native state")

	var item_id := _item_id_by_definition(
		refreshed_snapshot, ZerkovInventoryCatalog.ITEM_SEALED_DOCUMENTS)
	var confirmed_before_drag := _item_location(refreshed_snapshot, item_id)
	var raid_scope_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	var ghost_destination := {
		"kind": "spatial", "container": crate_container_id,
		"x": 6, "y": 1, "rotated": false,
	}
	var accepted_pending_id := bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"move",
		{"inventory_id": crate_id, "items": [item_id],
			"ghost_placement": ghost_destination},
		owner_generation,
		raid_scope_generation
	)
	check(accepted_pending_id > 0, "drag intent receives a presentation command id")
	check(raid_model.get_pending_ghost(crate_id, item_id) == ghost_destination,
		"pending placement is available only as a ghost")
	check(_item_location(bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id), item_id) == confirmed_before_drag,
		"pending drag does not mutate confirmed placement")
	check(raid_model.item_state(crate_id, item_id) == InventoryPresentationModel.STATE_PENDING,
		"item reports pending without masquerading as confirmed placement")
	var before_queued_bytes := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id).canonical_bytes()
	authority.transaction_committed.emit({
		"queued": true,
		"command_id": accepted_pending_id,
		"accepted": false,
	})
	check(not raid_model.get_pending(accepted_pending_id).is_empty(),
		"queued admission receipt does not resolve pending presentation intent")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID,
		crate_id).canonical_bytes() == before_queued_bytes,
		"queued admission receipt cannot alter confirmed projection")

	var accepted_move: Dictionary = authority.move_item(
		crate_id,
		item_id,
		ghost_destination,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		accepted_pending_id
	)
	check(bool(accepted_move.get("accepted", false)), "pending move commits authoritatively")
	check(raid_model.get_pending(accepted_pending_id).is_empty(),
		"accepted result clears pending state")
	check(_location_matches(_item_location(bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id), item_id), ghost_destination),
		"accepted refresh alone changes confirmed placement")
	check(raid_model.item_state(crate_id, item_id) == InventoryPresentationModel.STATE_ACCEPTED,
		"accepted result exposes presentation feedback")
	check(int(accepted_feedback["count"]) == 1,
		"final accepted result emits feedback exactly once")
	var changes_before_duplicate := int(raid_model_changes["count"])
	var bytes_before_duplicate := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id).canonical_bytes()
	authority.transaction_committed.emit(accepted_move.duplicate(true))
	check(int(accepted_feedback["count"]) == 1,
		"duplicate final result is deduplicated")
	check(int(raid_model_changes["count"]) == changes_before_duplicate,
		"duplicate final result produces no model churn")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID,
		crate_id).canonical_bytes() == bytes_before_duplicate,
		"duplicate final result leaves confirmed bytes unchanged")

	var accepted_location := _item_location(bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id), item_id)
	var accepted_revision := bridge.confirmed_revision(
		InventoryProjectionBridge.SCOPE_RAID, crate_id)
	var rejected_destination := {
		"kind": "spatial", "container": crate_container_id,
		"x": 99, "y": 99, "rotated": false,
	}
	var rejected_pending_id := bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"move",
		{"inventory_id": crate_id, "items": [item_id],
			"ghost_placement": rejected_destination},
		owner_generation,
		raid_scope_generation
	)
	check(_item_location(bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id), item_id) == accepted_location,
		"invalid pending proposal still leaves confirmed placement unchanged")
	var rejected_move: Dictionary = authority.move_item(
		crate_id,
		item_id,
		rejected_destination,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		rejected_pending_id
	)
	check(not bool(rejected_move.get("accepted", false)), "invalid move is rejected")
	check(raid_model.get_pending(rejected_pending_id).is_empty(),
		"rejected result clears the ghost")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, crate_id)
		== accepted_revision, "rejected result rolls back to the latest authority revision")
	check(_item_location(bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id), item_id) == accepted_location,
		"rejected result restores the latest authoritative placement")
	check(raid_model.item_state(crate_id, item_id) == InventoryPresentationModel.STATE_REJECTED,
		"rejection remains presentation feedback, not canonical placement")
	check(not raid_model.get_last_rejection().is_empty(),
		"stable rejection information is available to the view")

	var stale_snapshot := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id)
	var later_move: Dictionary = authority.move_item(
		crate_id,
		item_id,
		{"kind": "spatial", "container": crate_container_id,
			"x": 5, "y": 1, "rotated": false},
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		3_002
	)
	check(bool(later_move.get("accepted", false)), "later authority move advances revision")
	var latest_revision := bridge.confirmed_revision(
		InventoryProjectionBridge.SCOPE_RAID, crate_id)
	check(not bridge.apply_authoritative_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		authority,
		stale_snapshot,
		owner_generation,
		raid_scope_generation
	), "out-of-order older snapshot is rejected")
	check(bridge.last_error == &"stale_or_duplicate_revision",
		"stale snapshot reports a stable ignore reason")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, crate_id)
		== latest_revision, "out-of-order snapshot cannot regress confirmed revision")
	var equal_snapshot := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id)
	var changes_before_equal := int(raid_model_changes["count"])
	check(not bridge.apply_authoritative_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		authority,
		equal_snapshot,
		owner_generation,
		raid_scope_generation
	), "duplicate equal snapshot is a no-op")
	check(bridge.last_error == &"stale_or_duplicate_revision"
		and int(raid_model_changes["count"]) == changes_before_equal,
		"duplicate equal snapshot neither diverges nor churns the model")

	check(bridge.begin_resynchronization(
		InventoryProjectionBridge.SCOPE_RAID, owner_generation, raid_scope_generation),
		"explicit resynchronization begins for current tokens")
	check(raid_model.is_resynchronizing(), "model exposes resynchronizing state")
	check(bridge.complete_resynchronization(
		InventoryProjectionBridge.SCOPE_RAID, owner_generation, raid_scope_generation),
		"full native refresh completes resynchronization: " + String(bridge.last_error)
		+ " " + str(ignored_history.back() if not ignored_history.is_empty() else {}))
	check(not raid_model.is_resynchronizing()
		and bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.READY,
		"successful refresh returns the scope to ready")

	# The public authority parameter cannot prove where a Resource originated.
	# Build colliding-id snapshots in another native authority and verify that
	# equal divergence and forged forward revisions fail closed.
	var profile_scope_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_PROFILE)
	var profile_authority := owner.profile_authority()
	var profile_container_id := _root_container_id(profile_authority,
		owner.profile_inventory_id)
	var profile_insert: Dictionary = profile_authority.insert_item(
		owner.profile_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_BOLTS),
		1,
		{"kind": "spatial", "container": profile_container_id,
			"x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		6_001
	)
	check(bool(profile_insert.get("accepted", false)),
		"bound profile authority advances to a projection fixture revision")
	var bound_profile_snapshot := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_PROFILE, owner.profile_inventory_id)

	var foreign_authority := InventoryAuthority.new()
	foreign_authority.name = "ForeignProjectionAuthority"
	foreign_authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	foreign_authority.set_catalog(owner.catalog())
	root.add_child(foreign_authority)
	var foreign_id := foreign_authority.create_inventory(
		String(RaidInventoryOwner.PROFILE_STASH_PROFILE))
	check(foreign_id == owner.profile_inventory_id,
		"foreign authority deliberately collides with the profile inventory id")
	var foreign_container_id := _root_container_id(foreign_authority, foreign_id)
	var foreign_insert: Dictionary = foreign_authority.insert_item(
		foreign_id,
		String(ZerkovInventoryCatalog.ITEM_BANDAGE),
		1,
		{"kind": "spatial", "container": foreign_container_id,
			"x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		7_001
	)
	check(bool(foreign_insert.get("accepted", false)),
		"foreign equal-revision snapshot fixture is valid")
	var foreign_equal_snapshot := foreign_authority.snapshot(foreign_id)
	check(foreign_equal_snapshot.get_revision() == bound_profile_snapshot.get_revision(),
		"foreign divergence uses the same revision")
	check(not bridge.apply_authoritative_snapshot(
		InventoryProjectionBridge.SCOPE_PROFILE,
		profile_authority,
		foreign_equal_snapshot,
		owner_generation,
		profile_scope_generation
	), "same-id equal-revision content from another authority is rejected")
	check(bridge.last_error == &"equal_revision_divergence",
		"equal-revision content divergence has a stable diagnostic")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_PROFILE,
		owner.profile_inventory_id).canonical_bytes()
		== bound_profile_snapshot.canonical_bytes(),
		"equal-revision divergence cannot overwrite confirmed profile bytes")
	check(bridge.complete_resynchronization(
		InventoryProjectionBridge.SCOPE_PROFILE,
		owner_generation,
		profile_scope_generation
	), "trusted pull clears equal-revision divergence without changing content")

	# InventoryPresentationModel intentionally owns mutable local view state and
	# is not canonical. If a consumer misuses its public apply_snapshot method,
	# the bridge's immutable registry remains authoritative and a trusted refresh
	# repairs the model at the same revision.
	profile_model.apply_snapshot(foreign_equal_snapshot)
	check(_snapshot_has_definition(profile_model.get_snapshot(foreign_id),
		ZerkovInventoryCatalog.ITEM_BANDAGE),
		"test fixture can corrupt only the noncanonical presentation model")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_PROFILE,
		owner.profile_inventory_id).canonical_bytes()
		== bound_profile_snapshot.canonical_bytes(),
		"public presentation-model mutation cannot alter bridge-confirmed bytes")
	check(bridge.refresh_inventory(
		InventoryProjectionBridge.SCOPE_PROFILE,
		owner.profile_inventory_id,
		owner_generation,
		profile_scope_generation
	), "trusted equal-revision refresh repairs a modified presentation model")
	check(_snapshot_has_definition(profile_model.get_snapshot(owner.profile_inventory_id),
		ZerkovInventoryCatalog.ITEM_BOLTS)
		and not _snapshot_has_definition(profile_model.get_snapshot(owner.profile_inventory_id),
			ZerkovInventoryCatalog.ITEM_BANDAGE),
		"presentation repair restores the confirmed profile projection")

	var foreign_newer_insert: Dictionary = foreign_authority.insert_item(
		foreign_id,
		String(ZerkovInventoryCatalog.ITEM_BOLTS),
		1,
		{"kind": "spatial", "container": foreign_container_id,
			"x": 4, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		7_002
	)
	check(bool(foreign_newer_insert.get("accepted", false)),
		"foreign newer-revision fixture is valid")
	check(not bridge.apply_authoritative_snapshot(
		InventoryProjectionBridge.SCOPE_PROFILE,
		profile_authority,
		foreign_authority.snapshot(foreign_id),
		owner_generation,
		profile_scope_generation
	), "forward snapshot not sourced from the exact bound authority is rejected")
	check(bridge.last_error == &"snapshot_authority_mismatch",
		"forged forward revision has a stable provenance diagnostic")
	check(bridge.complete_resynchronization(
		InventoryProjectionBridge.SCOPE_PROFILE,
		owner_generation,
		profile_scope_generation
	), "trusted profile pull recovers after provenance rejection")

	# One accepted transfer changes two inventories. Every model callback must
	# see both bridge revisions matching the already-committed native authority.
	var coherence := {"samples": 0, "incoherent": false}
	raid_model.model_changed.connect(func():
		coherence["samples"] = int(coherence["samples"]) + 1
		if bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, crate_id) \
				!= authority.inventory_revision(crate_id) \
				or bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID,
					owner.raid_player_inventory_id) \
				!= authority.inventory_revision(owner.raid_player_inventory_id):
			coherence["incoherent"] = true)
	var transfer_pending_id := bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"quick_transfer",
		{"inventory_id": crate_id, "items": [item_id]},
		owner_generation,
		raid_scope_generation
	)
	var transfer_result: Dictionary = authority.quick_transfer_item(
		crate_id,
		owner.raid_player_inventory_id,
		item_id,
		false,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		transfer_pending_id
	)
	check(bool(transfer_result.get("accepted", false)),
		"cross-inventory quick transfer commits")
	check(int(coherence["samples"]) > 0 and not bool(coherence["incoherent"]),
		"multi-inventory refresh is coherent at every published model edge")
	check(_item_location(bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id), item_id).is_empty()
		and not _item_location(bridge.confirmed_snapshot(
			InventoryProjectionBridge.SCOPE_RAID,
			owner.raid_player_inventory_id), item_id).is_empty(),
		"transferred item appears in exactly one confirmed inventory")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, crate_id)
		== authority.inventory_revision(crate_id)
		and bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID,
			owner.raid_player_inventory_id)
		== authority.inventory_revision(owner.raid_player_inventory_id),
		"both sides publish their final native revisions together")
	var replay_args := {
		"inventory_id": owner.raid_player_inventory_id,
		"items": [item_id],
		"ghost_placement": {"kind": "spatial", "container": 123,
			"x": 4, "y": 4, "rotated": false},
	}
	var replay_pending_id := bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"move",
		replay_args,
		owner_generation,
		raid_scope_generation
	)
	(replay_args["ghost_placement"] as Dictionary)["x"] = 999
	check(int((raid_model.get_pending(replay_pending_id).get(
		"ghost_placement", {}) as Dictionary).get("x", -1)) == 4,
		"pending intent captures a deep copy of caller-owned input")
	var feedback_before_replay := int(accepted_feedback["count"])
	var player_bytes_before_replay := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID,
		owner.raid_player_inventory_id).canonical_bytes()
	authority.transaction_committed.emit({
		"accepted": true,
		"replayed": true,
		"queued": false,
		"command_id": replay_pending_id,
		"revisions": [{"inventory": owner.raid_player_inventory_id,
			"predecessor": authority.inventory_revision(owner.raid_player_inventory_id),
			"successor": authority.inventory_revision(owner.raid_player_inventory_id)}],
	})
	check(raid_model.get_pending(replay_pending_id).is_empty(),
		"replayed final result clears its pending presentation record")
	check(int(accepted_feedback["count"]) == feedback_before_replay,
		"replayed final result remains feedback-silent")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID,
		owner.raid_player_inventory_id).canonical_bytes() == player_bytes_before_replay,
		"replayed result does not alter confirmed state")
	check(bool(foreign_authority.unload_inventory(foreign_id).get("ok", false)),
		"foreign fixture authority unloads")
	foreign_authority.queue_free()

	var replacement_observations: Array[Dictionary] = []
	bridge.model_replaced.connect(func(scope: StringName, model: InventoryPresentationModel,
		_scope_generation: int):
		if scope == InventoryProjectionBridge.SCOPE_RAID:
			replacement_observations.append({
				"player": model.has_snapshot(owner.raid_player_inventory_id),
				"crate": model.has_snapshot(crate_id),
				"corpse": model.has_snapshot(owner.corpse_inventory_id),
			}))
	var replacement_record := authority.make_persistence_record(crate_id)
	check(not replacement_record.is_empty(), "authority produces replacement fixture bytes")
	var pre_replacement_model := bridge.presentation_model(
		InventoryProjectionBridge.SCOPE_RAID)
	var pre_replacement_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	var replacement: Dictionary = authority.apply_persistence_record(replacement_record, true)
	check(bool(replacement.get("ok", false)), "same-id authority replacement succeeds")
	check(bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
		> pre_replacement_generation, "replacement advances presentation scope generation")
	check(pre_replacement_model.is_resynchronizing(),
		"old model reference is invalidated at the replacement edge")
	check(not replacement_observations.is_empty()
		and bool(replacement_observations.back().get("player", false))
		and bool(replacement_observations.back().get("corpse", false)),
		"replacement publishes its complete retained-inventory set atomically")
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.RESYNCHRONIZING,
		"replacement enters resynchronizing before the new runtime is projected")
	check(bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"move",
		{"inventory_id": crate_id, "items": [item_id]},
		owner_generation,
		pre_replacement_generation
	) == 0 and bridge.last_error == &"stale_projection_binding",
		"pre-replacement generation cannot create pending intent")
	await process_frame
	var replacement_model := bridge.presentation_model(
		InventoryProjectionBridge.SCOPE_RAID)
	check(replacement_model != pre_replacement_model,
		"replacement installs a fresh presentation model")
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.READY,
		"deferred full snapshot heals replacement resynchronization")
	check(bridge.confirmed_revision(InventoryProjectionBridge.SCOPE_RAID, crate_id)
		== authority.inventory_revision(crate_id),
		"replacement projection binds the new authoritative generation")

	var corpse_id := owner.corpse_inventory_id
	var pre_unload_model := bridge.presentation_model(
		InventoryProjectionBridge.SCOPE_RAID)
	var pre_unload_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	var retained_crate_bytes := bridge.confirmed_snapshot(
		InventoryProjectionBridge.SCOPE_RAID, crate_id).canonical_bytes()
	var unload_result: Dictionary = authority.unload_inventory(corpse_id)
	check(bool(unload_result.get("ok", false)),
		"explicit inventory unload succeeds")
	check(bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
		> pre_unload_generation,
		"unload advances the presentation generation")
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.STALE,
		"unload leaves the incomplete scope stale")
	check(pre_unload_model.is_resynchronizing(),
		"unload invalidates retained references to the previous model")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID, corpse_id) == null,
		"unloaded inventory is absent from confirmed projection")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID,
		crate_id).canonical_bytes() == retained_crate_bytes,
		"unload preserves other inventory projections byte-for-byte")
	check(not replacement_observations.is_empty()
		and bool(replacement_observations.back().get("player", false))
		and bool(replacement_observations.back().get("crate", false))
		and not bool(replacement_observations.back().get("corpse", true)),
		"unload publishes every retained inventory together")
	var post_unload_generation := bridge.scope_generation(
		InventoryProjectionBridge.SCOPE_RAID)
	authority.transaction_committed.emit({
		"accepted": true,
		"queued": false,
		"command_id": 8_001,
		"revisions": [{"inventory": corpse_id,
			"predecessor": 0, "successor": 1}],
	})
	check(bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
		== post_unload_generation
		and bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.STALE,
		"late result naming an unloaded inventory is ignored without lifecycle churn")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID,
		crate_id).canonical_bytes() == retained_crate_bytes,
		"late unloaded-inventory result cannot alter retained confirmed state")

	check(owner.teardown(owner_generation), "inventory owner tears down")
	check(not bridge.validate_binding(), "teardown invalidates the owner-generation binding")
	check(bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.DISCONNECTED,
		"teardown marks presentation disconnected")
	check(bridge.presentation_model(InventoryProjectionBridge.SCOPE_RAID).is_disconnected(),
		"teardown invalidates the current model for retained UI references")
	var disconnected_model := bridge.presentation_model(
		InventoryProjectionBridge.SCOPE_RAID)
	var disconnected_changes := {"count": 0}
	disconnected_model.model_changed.connect(func():
		disconnected_changes["count"] = int(disconnected_changes["count"]) + 1)
	authority.transaction_committed.emit({
		"accepted": true,
		"queued": false,
		"command_id": 8_002,
		"revisions": [{"inventory": crate_id,
			"predecessor": 0, "successor": 1}],
	})
	check(int(disconnected_changes["count"]) == 0
		and bridge.scope_status(InventoryProjectionBridge.SCOPE_RAID)
		== InventoryProjectionBridge.ProjectionStatus.DISCONNECTED,
		"late authority callback after teardown is disconnected and ignored")
	check(bridge.confirmed_snapshot(InventoryProjectionBridge.SCOPE_RAID, crate_id) == null,
		"teardown exposes no confirmed snapshot through the bridge")
	check(bridge.begin_pending_intent(
		InventoryProjectionBridge.SCOPE_RAID,
		&"move",
		{"inventory_id": crate_id, "items": [item_id]},
		owner_generation,
		bridge.scope_generation(InventoryProjectionBridge.SCOPE_RAID)
	) == 0, "teardown rejects new presentation intent")

	bridge.queue_free()
	owner.queue_free()
	print("INVENTORY_PROJECTION_RESULT checks=", checks, " failures=", failures,
		" latest_revision=", latest_revision)
	quit(0 if failures == 0 else 1)


func _saw_status(history: Array[Dictionary], scope: StringName, status: int) -> bool:
	for entry in history:
		if entry.get("scope", &"") == scope and int(entry.get("status", -1)) == status:
			return true
	return false


func _item_id_by_definition(
	snapshot: InventorySnapshotResource,
	definition_id: StringName
) -> int:
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if StringName(item.get("item_definition_identifier", "")) == definition_id:
			return int(item.get("id", 0))
	return 0


func _item_location(snapshot: InventorySnapshotResource, item_id: int) -> Dictionary:
	if snapshot == null:
		return {}
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return (item.get("location", {}) as Dictionary).duplicate(true)
	return {}


func _location_matches(actual: Dictionary, expected: Dictionary) -> bool:
	return String(actual.get("kind", "")) == String(expected.get("kind", "")) \
		and int(actual.get("container", 0)) == int(expected.get("container", 0)) \
		and int(actual.get("x", -1)) == int(expected.get("x", -1)) \
		and int(actual.get("y", -1)) == int(expected.get("y", -1)) \
		and bool(actual.get("rotated", false)) == bool(expected.get("rotated", false))


func _root_container_id(authority: InventoryAuthority, inventory_id: int) -> int:
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0:
			return int(container.get("id", 0))
	return 0


func _snapshot_has_definition(
	snapshot: InventorySnapshotResource,
	definition_id: StringName
) -> bool:
	if snapshot == null:
		return false
	return _item_id_by_definition(snapshot, definition_id) > 0
