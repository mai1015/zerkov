extends SceneTree
## Run with: godot --headless --path . --script res://tests/raid/inventory_authority_contract.gd
##
## Covers tasks 4.2-4.4 at the game boundary: two explicitly owned
## InventoryAuthority Nodes, deterministic fixture materialization, and the
## staged container-search lifecycle through the public native API.

class PartialBootstrapOwner extends RaidInventoryOwner:
	var authority_factory_calls: int = 0
	var first_authority: InventoryAuthority
	var first_inventory_id: int = 0

	func _new_authority(node_name: StringName) -> InventoryAuthority:
		authority_factory_calls += 1
		if authority_factory_calls == 2:
			first_inventory_id = profile_inventory_id
			return null
		first_authority = super._new_authority(node_name)
		return first_authority

var checks: int = 0
var failures: int = 0
var owner: RaidInventoryOwner


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("INVENTORY_AUTHORITY_CONTRACT: " + message)


func run() -> void:
	var partial_owner := PartialBootstrapOwner.new()
	partial_owner.name = "PartialBootstrapInventoryOwner"
	root.add_child(partial_owner)
	check(not partial_owner.configure(), "partial multi-authority bootstrap fails closed")
	check(partial_owner.last_error == &"raid_authority_create_failed",
		"partial bootstrap reports the stable failure reason")
	check(partial_owner.get_child_count() == 0,
		"partial bootstrap detaches every authority child")
	check(partial_owner.profile_authority() == null and partial_owner.raid_authority() == null,
		"partial bootstrap clears authority references")
	check(partial_owner.profile_inventory_id == 0 and partial_owner.raid_player_inventory_id == 0
		and partial_owner.world_crate_inventory_id == 0 and partial_owner.corpse_inventory_id == 0,
		"partial bootstrap clears published inventory ids")
	check(partial_owner.catalog() == null, "partial bootstrap releases the retained catalog")
	check(partial_owner.first_authority != null and partial_owner.first_inventory_id > 0
		and not partial_owner.first_authority.has_inventory(partial_owner.first_inventory_id),
		"partial bootstrap explicitly unloads an already-created canonical runtime")
	partial_owner.queue_free()

	owner = RaidInventoryOwner.new()
	owner.name = "InventoryAuthorityFixtureOwner"
	root.add_child(owner)
	check(owner.configure(), "scene-owned profile and raid authorities configure")
	check(owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE, "owner enters active lifecycle")
	var captured_generation := owner.generation()
	check(captured_generation > 0, "owner publishes a positive generation")
	check(owner.profile_authority() != null, "profile authority is explicitly owned")
	check(owner.raid_authority() != null, "raid authority is explicitly owned")
	check(owner.profile_authority() != owner.raid_authority(),
		"profile and raid canonical state use separate authority instances")
	check(owner.profile_inventory_id > 0, "profile stash inventory is created")
	check(owner.raid_player_inventory_id > 0, "raid player inventory is created")
	check(owner.world_crate_inventory_id > 0, "world crate inventory is created")
	check(owner.corpse_inventory_id > 0, "corpse inventory is created")
	check(owner.profile_authority().has_inventory(owner.profile_inventory_id),
		"profile authority owns only its profile inventory")
	check(not owner.profile_authority().has_inventory(owner.world_crate_inventory_id),
		"profile authority cannot see raid world-crate state")
	check(owner.raid_authority().has_inventory(owner.world_crate_inventory_id),
		"raid authority owns world-crate state")

	var player_snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	var secure_container_id := _root_container_by_definition(
		player_snapshot, ZerkovInventoryCatalog.CONTAINER_SECURE)
	var pockets_container_id := _root_container_by_definition(
		player_snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	check(secure_container_id > 0 and pockets_container_id > 0,
		"player profile materializes secure and unsecured root containers")
	var secure_insert: Dictionary = owner.raid_authority().insert_item(
		owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_GOLD_WATCH),
		1,
		{"kind": "spatial", "container": secure_container_id, "x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_001
	)
	check(bool(secure_insert.get("accepted", false)) and int(secure_insert.get("new_item_id", 0)) > 0,
		"secure-retention fixture item inserts authoritatively")
	var secure_item_id := int(secure_insert.get("new_item_id", 0))
	var retain_secure: Dictionary = owner.raid_authority().settle_inventory(
		owner.raid_player_inventory_id,
		[{"item": secure_item_id, "disposition": "retain"}],
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_002
	)
	check(bool(retain_secure.get("accepted", false)),
		"settlement accepts retain for an item already in the protected container")
	check(_snapshot_has_item(owner.raid_authority().snapshot(owner.raid_player_inventory_id),
		secure_item_id), "protected item remains canonically owned after retain settlement")
	var unsecured_insert: Dictionary = owner.raid_authority().insert_item(
		owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_BATTERY),
		1,
		{"kind": "spatial", "container": pockets_container_id, "x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_003
	)
	check(bool(unsecured_insert.get("accepted", false))
		and int(unsecured_insert.get("new_item_id", 0)) > 0,
		"unsecured comparison item inserts authoritatively")
	var before_bad_retain := owner.raid_authority().snapshot(
		owner.raid_player_inventory_id).canonical_bytes()
	var retain_unsecured: Dictionary = owner.raid_authority().settle_inventory(
		owner.raid_player_inventory_id,
		[{"item": int(unsecured_insert.get("new_item_id", 0)), "disposition": "retain"}],
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_004
	)
	check(not bool(retain_unsecured.get("accepted", false)),
		"settlement rejects retain outside protected retention")
	check(before_bad_retain == owner.raid_authority().snapshot(
		owner.raid_player_inventory_id).canonical_bytes(),
		"rejected unsecured retain leaves canonical bytes unchanged")

	check(owner.materialize_loot_fixture(captured_generation),
		"deterministic crate and corpse rows materialize")
	check(owner.loot_fixture_ready(captured_generation), "loot fixture is ready")
	check(owner.materialize_loot_fixture(captured_generation),
		"fixture materialization is idempotent")
	var crate_snapshot := owner.raid_authority().snapshot(owner.world_crate_inventory_id)
	var corpse_snapshot := owner.raid_authority().snapshot(owner.corpse_inventory_id)
	check(crate_snapshot != null and crate_snapshot.get_items().size() == 4,
		"crate has four deterministic item instances")
	check(corpse_snapshot != null and corpse_snapshot.get_items().size() == 4,
		"corpse has four deterministic item instances")
	check(_snapshot_definitions(crate_snapshot) == PackedStringArray([
		"zerkov.item.quest.sealed_documents",
		"zerkov.item.valuable.encrypted_drive",
		"zerkov.item.valuable.gold_watch",
		"zerkov.item.junk.duct_tape",
	]), "crate definitions and order are deterministic")
	check(_snapshot_definitions(corpse_snapshot) == PackedStringArray([
		"zerkov.item.weapon.akm",
		"zerkov.item.ammo.caliber_762x39_standard",
		"zerkov.item.medical.bandage",
		"zerkov.item.junk.bolts",
	]), "corpse definitions and order are deterministic")
	check(_snapshot_quantities(crate_snapshot) == PackedInt64Array([1, 1, 1, 2]),
		"crate quantities are deterministic")
	check(_snapshot_quantities(corpse_snapshot) == PackedInt64Array([1, 60, 2, 4]),
		"corpse quantities are deterministic")
	check(_snapshot_locations(crate_snapshot) == PackedVector3Array([
		Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(3, 0, 0), Vector3(4, 0, 0),
	]), "crate positions are deterministic")
	check(_snapshot_locations(corpse_snapshot) == PackedVector3Array([
		Vector3(0, 0, 0), Vector3(5, 0, 0), Vector3(6, 0, 0), Vector3(7, 0, 0),
	]), "corpse positions are deterministic")
	var crate_bytes_before_replay := crate_snapshot.canonical_bytes()
	var replayed_insert: Dictionary = owner.raid_authority().insert_item(
		owner.world_crate_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_SEALED_DOCUMENTS),
		1,
		{"kind": "spatial", "container": owner.world_crate_container_id(),
			"x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_001
	)
	check(bool(replayed_insert.get("accepted", false))
		and bool(replayed_insert.get("replayed", false)),
		"exact fixed command-id replay returns the recorded result")
	check((replayed_insert.get("events", []) as Array).is_empty(),
		"idempotent replay does not re-emit one-shot events")
	check(crate_bytes_before_replay == owner.raid_authority().snapshot(
		owner.world_crate_inventory_id).canonical_bytes(),
		"idempotent replay leaves deterministic crate bytes unchanged")
	var conflicting_reuse: Dictionary = owner.raid_authority().insert_item(
		owner.world_crate_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_SEALED_DOCUMENTS),
		2,
		{"kind": "spatial", "container": owner.world_crate_container_id(),
			"x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		1_001
	)
	check(not bool(conflicting_reuse.get("accepted", false))
		and int((conflicting_reuse.get("status", {}) as Dictionary).get("code", -1))
		== InventoryCatalog.STATUS_DUPLICATE_COMMAND,
		"same command id with a different payload fails closed")
	check(crate_bytes_before_replay == owner.raid_authority().snapshot(
		owner.world_crate_inventory_id).canonical_bytes(),
		"conflicting command-id reuse leaves canonical bytes unchanged")

	var second_owner := RaidInventoryOwner.new()
	second_owner.name = "InventoryAuthorityFixtureOwnerSecond"
	root.add_child(second_owner)
	check(second_owner.configure(), "second owner configures independently")
	var second_generation := second_owner.generation()
	check(_mirror_retention_sequence(second_owner),
		"second owner receives the same preceding deterministic command sequence")
	check(second_owner.materialize_loot_fixture(second_generation),
		"second owner materializes the same fixture")
	var second_crate := second_owner.raid_authority().snapshot(second_owner.world_crate_inventory_id)
	var second_corpse := second_owner.raid_authority().snapshot(second_owner.corpse_inventory_id)
	check(crate_snapshot.canonical_bytes() == second_crate.canonical_bytes(),
		"independent owners produce byte-identical crate state")
	check(corpse_snapshot.canonical_bytes() == second_corpse.canonical_bytes(),
		"independent owners produce byte-identical corpse state")
	var second_discovery_view := second_owner.loot_discovery_view(
		second_owner.world_crate_inventory_id)
	check(second_discovery_view != null, "materialization registers recipient-scoped discovery state")
	check(second_owner.raid_authority().discovery_revision(
		RaidInventoryOwner.FIXTURE_SESSION_ID,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		second_owner.world_crate_inventory_id) >= 0,
		"registered recipient has bounded discovery revision state")
	var recipient_teardown: Dictionary = second_owner.raid_authority().teardown_discovery_recipient(
		RaidInventoryOwner.FIXTURE_SESSION_ID,
		RaidInventoryOwner.FIXTURE_ACTOR_ID
	)
	check(bool(recipient_teardown.get("ok", false)),
		"discovery recipient teardown explicitly succeeds")
	check(second_owner.raid_authority().discovery_revision(
		RaidInventoryOwner.FIXTURE_SESSION_ID,
		RaidInventoryOwner.FIXTURE_ACTOR_ID,
		second_owner.world_crate_inventory_id) == -1,
		"recipient teardown removes its discovery inventory state")
	var recipient_reregister: Dictionary = second_owner.raid_authority().register_discovery_recipient(
		RaidInventoryOwner.FIXTURE_SESSION_ID,
		RaidInventoryOwner.FIXTURE_ACTOR_ID
	)
	check(bool(recipient_reregister.get("ok", false)),
		"recipient can be re-registered as a fresh scope before owner teardown")
	check(second_owner.teardown(second_generation), "second owner tears down independently")

	var view := owner.loot_discovery_view(owner.world_crate_inventory_id)
	check(view != null, "crate exposes a recipient-bound discovery view")
	check(view != null and view.get_containers().size() == 1,
		"crate discovery view exposes one shell")
	var crate_view: InventoryDiscoveryContainerViewResource = null
	if view != null and not view.get_containers().is_empty():
		crate_view = view.get_containers()[0]
	check(crate_view != null and crate_view.get_stage()
		== InventoryDiscoveryContainerViewResource.STAGE_UNSEARCHED,
		"crate starts unsearched")
	check(crate_view != null and crate_view.get_token() > 0,
		"crate shell uses an opaque positive token")
	check(view != null and view.get_projected_snapshot().get_items().is_empty(),
		"unsearched view redacts crate item rows")
	if crate_view != null:
		var search := owner.raid_authority().begin_container_search(
			RaidInventoryOwner.FIXTURE_SESSION_ID,
			RaidInventoryOwner.FIXTURE_ACTOR_ID,
			owner.world_crate_inventory_id,
			crate_view.get_token()
		)
		check(search != null and search.is_accepted(), "crate search intent is accepted")
		check(search != null and not search.is_completed(), "crate search is staged")
		var searching_view := owner.loot_discovery_view(owner.world_crate_inventory_id)
		check(searching_view != null and searching_view.get_containers()[0].get_stage()
			== InventoryDiscoveryContainerViewResource.STAGE_SEARCHING,
			"crate reports searching while elapsed work is pending")
		var completed := owner.advance_loot_discovery(900)
		check(completed != null and completed.is_accepted() and completed.is_completed(),
			"trusted elapsed time completes crate search")
		var indexed_view := owner.loot_discovery_view(owner.world_crate_inventory_id)
		check(indexed_view != null and indexed_view.get_containers()[0].get_stage()
			== InventoryDiscoveryContainerViewResource.STAGE_INDEXED,
			"crate becomes indexed after the sealed search duration")
		check(indexed_view != null and indexed_view.get_containers()[0].get_item_count() == 4,
			"indexed crate discloses deterministic item count")
		check(indexed_view != null and indexed_view.get_projected_snapshot().get_items().is_empty(),
			"indexed crate still redacts unrevealed item rows")

	var corpse_view := owner.loot_discovery_view(owner.corpse_inventory_id)
	check(corpse_view != null and corpse_view.get_containers().size() == 1,
		"corpse exposes a recipient-bound discovery shell")
	var corpse_container_view: InventoryDiscoveryContainerViewResource = null
	if corpse_view != null and not corpse_view.get_containers().is_empty():
		corpse_container_view = corpse_view.get_containers()[0]
	check(corpse_container_view != null and corpse_container_view.get_stage()
		== InventoryDiscoveryContainerViewResource.STAGE_UNSEARCHED,
		"corpse starts unsearched")
	if corpse_container_view != null:
		var corpse_search := owner.raid_authority().begin_container_search(
			RaidInventoryOwner.FIXTURE_SESSION_ID,
			RaidInventoryOwner.FIXTURE_ACTOR_ID,
			owner.corpse_inventory_id,
			corpse_container_view.get_token()
		)
		check(corpse_search != null and corpse_search.is_accepted(),
			"corpse search intent is accepted")
		var corpse_completed := owner.advance_loot_discovery(900)
		check(corpse_completed != null and corpse_completed.is_accepted()
			and corpse_completed.is_completed(), "trusted elapsed time completes corpse search")
		var indexed_corpse_view := owner.loot_discovery_view(owner.corpse_inventory_id)
		check(indexed_corpse_view != null and indexed_corpse_view.get_containers()[0].get_stage()
			== InventoryDiscoveryContainerViewResource.STAGE_INDEXED,
			"corpse becomes indexed after the sealed search duration")
		check(indexed_corpse_view != null
			and indexed_corpse_view.get_containers()[0].get_item_count() == 4,
			"indexed corpse discloses deterministic item count")

	check(not owner.teardown(captured_generation + 1), "stale owner teardown is rejected")
	check(owner.teardown(captured_generation), "owner tears down authorities explicitly")
	check(owner.lifecycle == RaidInventoryOwner.Lifecycle.TORN_DOWN,
		"owner enters terminal torn-down lifecycle")
	check(owner.generation() == captured_generation + 1,
		"teardown advances owner generation")
	check(not owner.is_current_generation(captured_generation),
		"captured generation is invalid after teardown")
	check(not owner.materialize_loot_fixture(captured_generation),
		"late fixture callback cannot mutate torn-down authorities")
	check(owner.profile_authority() == null and owner.raid_authority() == null,
		"authority nodes are released after teardown")

	print("INVENTORY_AUTHORITY_RESULT checks=", checks, " failures=", failures,
		" crate_items=4 corpse_items=4")
	quit(0 if failures == 0 else 1)


func _snapshot_definitions(snapshot: InventorySnapshotResource) -> PackedStringArray:
	var result := PackedStringArray()
	if snapshot == null:
		return result
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		result.append(String(item.get("item_definition_identifier", "")))
	return result


func _snapshot_quantities(snapshot: InventorySnapshotResource) -> PackedInt64Array:
	var result := PackedInt64Array()
	if snapshot == null:
		return result
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		result.append(int(item.get("quantity", 0)))
	return result


func _snapshot_locations(snapshot: InventorySnapshotResource) -> PackedVector3Array:
	var result := PackedVector3Array()
	if snapshot == null:
		return result
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		var location := item.get("location", {}) as Dictionary
		result.append(Vector3(int(location.get("x", -1)), int(location.get("y", -1)),
			1 if bool(location.get("rotated", false)) else 0))
	return result


func _root_container_by_definition(
	snapshot: InventorySnapshotResource,
	definition_identifier: StringName
) -> int:
	if snapshot == null:
		return 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
			and String(container.get("container_definition_identifier", "")) \
			== String(definition_identifier):
			return int(container.get("id", 0))
	return 0


func _snapshot_has_item(snapshot: InventorySnapshotResource, item_id: int) -> bool:
	if snapshot == null:
		return false
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return true
	return false


func _mirror_retention_sequence(target_owner: RaidInventoryOwner) -> bool:
	var snapshot := target_owner.raid_authority().snapshot(target_owner.raid_player_inventory_id)
	var secure_id := _root_container_by_definition(
		snapshot, ZerkovInventoryCatalog.CONTAINER_SECURE)
	var pockets_id := _root_container_by_definition(
		snapshot, ZerkovInventoryCatalog.CONTAINER_POCKETS)
	if secure_id <= 0 or pockets_id <= 0:
		return false
	var secure_insert: Dictionary = target_owner.raid_authority().insert_item(
		target_owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_GOLD_WATCH),
		1,
		{"kind": "spatial", "container": secure_id, "x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_001
	)
	if not bool(secure_insert.get("accepted", false)):
		return false
	var secure_retain: Dictionary = target_owner.raid_authority().settle_inventory(
		target_owner.raid_player_inventory_id,
		[{"item": int(secure_insert.get("new_item_id", 0)), "disposition": "retain"}],
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_002
	)
	if not bool(secure_retain.get("accepted", false)):
		return false
	var unsecured_insert: Dictionary = target_owner.raid_authority().insert_item(
		target_owner.raid_player_inventory_id,
		String(ZerkovInventoryCatalog.ITEM_BATTERY),
		1,
		{"kind": "spatial", "container": pockets_id, "x": 0, "y": 0, "rotated": false},
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_003
	)
	if not bool(unsecured_insert.get("accepted", false)):
		return false
	var unsecured_retain: Dictionary = target_owner.raid_authority().settle_inventory(
		target_owner.raid_player_inventory_id,
		[{"item": int(unsecured_insert.get("new_item_id", 0)), "disposition": "retain"}],
		RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
		3_004
	)
	return not bool(unsecured_retain.get("accepted", false))
