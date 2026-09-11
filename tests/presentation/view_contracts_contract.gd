extends SceneTree
## Run with: godot --headless --path . --script res://tests/presentation/view_contracts_contract.gd

const RaidViewContract = preload("res://game/presentation/views/raid_view.gd")
const InventoryViewContract = preload("res://game/presentation/views/inventory_view.gd")
const HealthViewContract = preload("res://game/presentation/views/health_view.gd")
const TaskViewContract = preload("res://game/presentation/views/task_view.gd")
const MapViewContract = preload("res://game/presentation/views/map_view.gd")
const BunkerViewContract = preload("res://game/presentation/views/bunker_view.gd")
const SummaryViewContract = preload("res://game/presentation/views/summary_view.gd")

var checks: int = 0
var failures: int = 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("VIEW_CONTRACTS_CONTRACT: " + message)


func run() -> void:
	_test_common_contract()
	_test_raid_view()
	_test_inventory_view()
	_test_health_view()
	_test_task_view()
	_test_map_view()
	_test_bunker_view()
	_test_summary_view()
	_test_rejections()
	_test_adversarial_children()
	print("VIEW_CONTRACTS_CONTRACT_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)


func _test_common_contract() -> void:
	var loading := RaidViewContract.unavailable(
		ZReadOnlyView.SyncState.LOADING, &"awaiting_authority")
	check(loading != null and loading.is_initialized(), "unavailable raid view constructs")
	check(not loading.is_ready(), "unavailable raid view is not ready")
	check(loading.sync_state_name() == &"loading", "sync state has a stable name")
	check(loading.diagnostic() == &"awaiting_authority", "sync diagnostic is explicit")
	var metadata := loading.metadata()
	check(metadata.is_read_only(), "projection metadata is read-only")
	check(metadata["generation"] == 0 and metadata["revision"] == 0,
		"unavailable metadata preserves zero provenance")
	check(RaidViewContract.unavailable(
		ZReadOnlyView.SyncState.READY, &"invalid") == null,
		"unavailable factory rejects READY")
	check(ZReadOnlyView.content_id_is_valid(&"zerkov.level.sawmill_yard"),
		"canonical content id is accepted")
	check(not ZReadOnlyView.content_id_is_valid(&"Zerkov.Level.Bad"),
		"noncanonical content id is rejected")
	var subject_actor := ZEntityId.from_parts(PackedStringArray(["view", "sync_actor"]))
	var subject_raid := ZRaidId.from_parts(PackedStringArray(["view", "sync_raid"]))
	var subject_settlement := ZSettlementId.from_parts(
		PackedStringArray(["view", "sync_settlement"]))
	check(HealthViewContract.unavailable(ZReadOnlyView.SyncState.STALE, &"lag", 2, 3, 4,
		subject_actor).actor_id().is_equal(subject_actor),
		"health unavailable state retains actor identity")
	check(InventoryViewContract.unavailable(InventoryViewContract.Scope.RAID,
		ZReadOnlyView.SyncState.RESYNCHRONIZING, &"gap", 2, 3, 4,
		subject_actor).actor_id().is_equal(subject_actor),
		"inventory unavailable state retains actor identity")
	check(MapViewContract.unavailable(ZReadOnlyView.SyncState.DISCONNECTED, &"offline",
		2, 3, 4, &"zerkov.map.sawmill").map_id() == &"zerkov.map.sawmill",
		"map unavailable state retains map identity")
	check(BunkerViewContract.unavailable(ZReadOnlyView.SyncState.STALE, &"lag",
		2, 3, 4, &"zerkov.profile.local").profile_id() == &"zerkov.profile.local",
		"bunker unavailable state retains profile identity")
	check(TaskViewContract.unavailable(ZReadOnlyView.SyncState.STALE, &"lag",
		2, 3, 4, null, &"zerkov.task_scope.profile").scope_id() \
		== &"zerkov.task_scope.profile",
		"task unavailable state retains scope identity")
	check(SummaryViewContract.unavailable(ZReadOnlyView.SyncState.STALE, &"lag",
		2, 3, 4, subject_raid, subject_settlement).settlement_id().is_equal(
		subject_settlement), "summary unavailable state retains settlement identity")


func _test_raid_view() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["view", "raid_01"]))
	var actor_id := ZEntityId.from_parts(PackedStringArray(["view", "oak_johnson"]))
	var weapon_id := ZWeaponId.from_parts(PackedStringArray(["view", "akm_01"]))
	var event_id := ZConsequenceId.from_parts(PackedStringArray(["view", "loot_01"]))
	var weapon := RaidViewContract.WeaponState.create(
		weapon_id, &"zerkov.weapon.akm", "AKM", RaidViewContract.WeaponStatus.READY,
		27, 30, 41, &"automatic")
	var extraction := RaidViewContract.Extraction.create(
		&"zerkov.extract.sawmill.road_gate", "Road Gate",
		RaidViewContract.ExtractionStatus.AVAILABLE, 340_000, 0, 180)
	var feed := RaidViewContract.FeedEntry.create(
		event_id, RaidViewContract.FeedKind.LOOT, "Battery x1", 119)
	var extractions: Array[RaidViewContract.Extraction] = [extraction]
	var feed_entries: Array[RaidViewContract.FeedEntry] = [feed]
	var view := RaidViewContract.create(
		7, 12, 120, raid_id, actor_id, RaidViewContract.Lifecycle.ACTIVE,
		&"zerkov.level.sawmill_yard", "Sawmill Yard", 120, 2100,
		weapon, extractions, feed_entries)
	check(view != null and view.is_ready(), "ready raid view constructs")
	check(view.raid_id().is_equal(raid_id) and view.raid_id() != raid_id,
		"raid identity is typed and detached")
	check(view.actor_id().is_equal(actor_id), "raid actor identity is retained")
	check(view.lifecycle() == RaidViewContract.Lifecycle.ACTIVE,
		"raid lifecycle is typed")
	check(view.remaining_ticks() == 1980, "raid remaining ticks are derived")
	check(view.weapon().magazine_rounds() == 27, "weapon state is typed")
	check(view.extractions().is_read_only() and view.feed().is_read_only(),
		"raid collections are read-only")
	var detached_weapon := view.weapon()
	detached_weapon._magazine_rounds = 0
	check(view.weapon().magazine_rounds() == 27,
		"mutating a detached weapon cannot alter the raid view")
	var detached_extract := view.extractions()[0]
	detached_extract._display_name = "Changed"
	check(view.extractions()[0].display_name() == "Road Gate",
		"mutating a detached extraction cannot alter the raid view")
	view._weapon._magazine_rounds = 0
	view._extractions[0]._display_name = "Changed retained"
	check(view.weapon().magazine_rounds() == 27
		and view.extractions()[0].display_name() == "Road Gate",
		"retained raid child state is sealed")


func _test_inventory_view() -> void:
	var actor_id := ZEntityId.from_parts(PackedStringArray(["view", "inventory_actor"]))
	var item := InventoryViewContract.ItemRecord.create(
		101, &"zerkov.item.junk.battery", "Battery", 2,
		Vector2i(1, 1), Vector2i(1, 2), false, &"battery", &"utility", true)
	var items: Array[InventoryViewContract.ItemRecord] = [item]
	var container := InventoryViewContract.ContainerRecord.create(
		11, 21, 3, InventoryViewContract.ContainerKind.BACKPACK,
		&"zerkov.container.player.backpack", "Backpack", Vector2i(6, 5), false, items)
	var containers: Array[InventoryViewContract.ContainerRecord] = [container]
	var view := InventoryViewContract.create(
		8, 3, 220, InventoryViewContract.Scope.RAID, actor_id, containers)
	check(view != null and view.scope() == InventoryViewContract.Scope.RAID,
		"raid inventory scope is typed")
	check(view.containers().is_read_only(), "inventory container list is read-only")
	check(view.containers()[0].items().is_read_only(), "inventory item list is read-only")
	check(view.containers()[0].items()[0].quantity() == 2,
		"inventory item values are retained")
	check(view.containers()[0].inventory_revision() == 3,
		"inventory revision is retained per authoritative inventory")
	check(view.containers()[0].items()[0].uses_placeholder_art(),
		"placeholder disclosure is explicit")
	var detached := view.containers()[0]
	detached._display_name = "Changed"
	detached._items[0]._quantity = 99
	check(view.containers()[0].display_name() == "Backpack"
		and view.containers()[0].items()[0].quantity() == 2,
		"detached inventory records cannot alter the view")
	view._containers[0]._items[0]._quantity = 99
	check(view.containers()[0].items()[0].quantity() == 2,
		"retained inventory child state is sealed")
	check(InventoryViewContract.unavailable(
		InventoryViewContract.Scope.PROFILE, ZReadOnlyView.SyncState.DISCONNECTED,
		&"profile_store_offline", 8, 3, 220, actor_id).scope() \
		== InventoryViewContract.Scope.PROFILE,
		"unavailable inventory preserves its typed scope")


func _test_health_view() -> void:
	var actor_id := ZEntityId.from_parts(PackedStringArray(["view", "health_actor"]))
	var head := HealthViewContract.BodyPart.create(
		&"head", "Head", 35, 35, HealthViewContract.BodyPartState.HEALTHY)
	var torso := HealthViewContract.BodyPart.create(
		&"torso", "Torso", 60, 85, HealthViewContract.BodyPartState.INJURED, true)
	var parts: Array[HealthViewContract.BodyPart] = [head, torso]
	var bleed := HealthViewContract.StatusEffect.create(
		&"zerkov.effect.injury.heavy_bleed", "Heavy bleed",
		HealthViewContract.Severity.CRITICAL, 600)
	var effects: Array[HealthViewContract.StatusEffect] = [bleed]
	var view := HealthViewContract.create(
		9, 4, 300, actor_id, HealthViewContract.LifeState.ALIVE,
		80, 100, 70, 100, 65, 100, parts, effects)
	check(view != null and view.current_health() == 95 and view.maximum_health() == 120,
		"health totals derive from typed body parts")
	check(view.life_state() == HealthViewContract.LifeState.ALIVE,
		"health life state is typed")
	check(view.body_parts().is_read_only() and view.effects().is_read_only(),
		"health collections are read-only")
	check(view.body_parts()[1].has_heavy_bleed(), "body-part injury flags are explicit")
	var detached := view.body_parts()[1]
	detached._current_health = 0
	check(view.body_parts()[1].current_health() == 60,
		"detached body-part mutation cannot alter the health view")
	view._body_parts[1]._current_health = 0
	check(view.body_parts()[1].current_health() == 60,
		"retained health child state is sealed")
	var replay := HealthViewContract.create(
		9, 4, 300, actor_id, HealthViewContract.LifeState.ALIVE,
		80, 100, 70, 100, 65, 100, parts, effects)
	var newer_same_content := HealthViewContract.create(
		9, 5, 301, actor_id, HealthViewContract.LifeState.ALIVE,
		80, 100, 70, 100, 65, 100, parts, effects)
	var divergent := HealthViewContract.create(
		9, 4, 300, actor_id, HealthViewContract.LifeState.ALIVE,
		80, 100, 69, 100, 65, 100, parts, effects)
	check(view.content_digest().length() == 64
		and replay.content_digest() == view.content_digest()
		and newer_same_content.content_digest() == view.content_digest(),
		"health content digest is stable and independent of version metadata")
	check(divergent.content_digest() != view.content_digest(),
		"health content digest identifies same-version payload divergence")
	var sealed_digest := view.content_digest()
	view._content_digest = "forged"
	check(view.content_digest() == sealed_digest,
		"health content identity is immutable after construction")
	var unavailable_a := HealthViewContract.unavailable(
		ZReadOnlyView.SyncState.DISCONNECTED, &"authority_a", 9, 4, 300, actor_id)
	var unavailable_b := HealthViewContract.unavailable(
		ZReadOnlyView.SyncState.DISCONNECTED, &"authority_b", 9, 4, 300, actor_id)
	check(not unavailable_a.content_digest().is_empty()
		and unavailable_a.content_digest() != unavailable_b.content_digest(),
		"health content identity includes unavailable state and diagnostic truth")


func _test_task_view() -> void:
	var task_id := ZTaskId.from_parts(PackedStringArray(["sawmill", "supply_run"]))
	var objective := TaskViewContract.Objective.create(
		&"search_crate", "Search a wooden crate", 1, 3)
	var objectives: Array[TaskViewContract.Objective] = [objective]
	var reward := TaskViewContract.Reward.create(
		&"rubles", TaskViewContract.RewardKind.CURRENCY,
		&"zerkov.currency.rubles", "Rubles", 3000)
	var rewards: Array[TaskViewContract.Reward] = [reward]
	var entry := TaskViewContract.Entry.create(
		task_id, "Supply Run", "Search the Sawmill crates.", "Fence",
		&"zerkov.level.sawmill_yard", TaskViewContract.Status.ACTIVE,
		true, objectives, rewards)
	var entries: Array[TaskViewContract.Entry] = [entry]
	var view := TaskViewContract.create(10, 5, 400, entries, task_id)
	check(view != null and view.tasks().size() == 1, "task view constructs")
	check(view.selected_task_id().is_equal(task_id), "selected task id is typed")
	check(view.tasks().is_read_only() and view.tasks()[0].objectives().is_read_only(),
		"task and objective collections are read-only")
	check(view.tasks()[0].objectives()[0].current() == 1,
		"task objective progress is retained")
	var detached := view.tasks()[0]
	detached._title = "Changed"
	check(view.tasks()[0].title() == "Supply Run",
		"detached task mutation cannot alter the task view")
	view._tasks[0]._title = "Changed retained"
	check(view.tasks()[0].title() == "Supply Run",
		"retained task child state is sealed")


func _test_map_view() -> void:
	var zone := MapViewContract.Zone.create(
		&"zerkov.level.sawmill_yard", "Sawmill Yard", "Abandoned timber yard.",
		"LOW", 2100, 1, 4, Vector2(0.3, 0.42), MapViewContract.ZoneState.SELECTED)
	var zones: Array[MapViewContract.Zone] = [zone]
	var marker := MapViewContract.Marker.create(
		&"road_gate", MapViewContract.MarkerKind.EXTRACTION,
		&"zerkov.extract.sawmill.road_gate", "Road Gate", Vector2(0.8, 0.5),
		true, true)
	var markers: Array[MapViewContract.Marker] = [marker]
	var view := MapViewContract.create(
		11, 6, 500, &"zerkov.map.sawmill", "Sawmill Region",
		&"zerkov.level.sawmill_yard", &"day", 1000, zones, markers)
	check(view != null and view.selected_zone_id() == &"zerkov.level.sawmill_yard",
		"map selection is typed")
	check(view.zones().is_read_only() and view.markers().is_read_only(),
		"map collections are read-only")
	check(view.markers()[0].kind() == MapViewContract.MarkerKind.EXTRACTION,
		"map marker kind is typed")
	var detached := view.zones()[0]
	detached._risk_label = "HIGH"
	check(view.zones()[0].risk_label() == "LOW",
		"detached zone mutation cannot alter the map view")
	view._zones[0]._risk_label = "HIGH"
	check(view.zones()[0].risk_label() == "LOW",
		"retained map child state is sealed")


func _test_bunker_view() -> void:
	var storage := BunkerViewContract.Station.create(
		&"zerkov.bunker.station.storage", "Storage Unit", 2, 5,
		BunkerViewContract.StationState.AVAILABLE, "61 / 70 slots", &"open_stash")
	var crafting := BunkerViewContract.Station.create(
		&"zerkov.bunker.station.crafting", "Crafting", 1, 5,
		BunkerViewContract.StationState.FEATURE_GATED, "Prototype only", &"",
		&"feature_not_authoritative")
	var stations: Array[BunkerViewContract.Station] = [storage, crafting]
	var view := BunkerViewContract.create(
		12, 7, 600, "Oak Johnson", 14, 3, 22_450, 61, 70,
		true, &"", &"zerkov.bunker.station.storage", stations)
	check(view != null and view.is_deployment_ready(), "bunker deployment readiness is explicit")
	check(view.stations().is_read_only(), "bunker station collection is read-only")
	check(view.stations()[1].state() == BunkerViewContract.StationState.FEATURE_GATED
		and view.stations()[1].gate_reason() == &"feature_not_authoritative",
		"unimplemented bunker actions are visibly gated")
	var detached := view.stations()[0]
	detached._level = 5
	check(view.stations()[0].level() == 2,
		"detached station mutation cannot alter the bunker view")
	view._stations[0]._level = 5
	check(view.stations()[0].level() == 2,
		"retained bunker child state is sealed")


func _test_summary_view() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["view", "summary_raid"]))
	var settlement_id := ZSettlementId.from_parts(PackedStringArray(["view", "settlement_01"]))
	var task_id := ZTaskId.from_parts(PackedStringArray(["sawmill", "supply_run"]))
	var correction_id := ZConsequenceId.from_parts(PackedStringArray(["view", "correction_01"]))
	var loot_line := SummaryViewContract.LootLine.create(
		&"zerkov.item.junk.battery", "Battery", 2, 1200,
		SummaryViewContract.LootDisposition.RETAINED)
	var loot: Array[SummaryViewContract.LootLine] = [loot_line]
	var task_result := SummaryViewContract.TaskResult.create(
		task_id, "Supply Run", 4, 4, true, 3000)
	var task_results: Array[SummaryViewContract.TaskResult] = [task_result]
	var correction := SummaryViewContract.Correction.create(
		correction_id, &"journal_reconciled", "Duplicate presentation event ignored.")
	var corrections: Array[SummaryViewContract.Correction] = [correction]
	var injuries: Array[StringName] = [&"zerkov.effect.injury.heavy_bleed"]
	var digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	var view := SummaryViewContract.create(
		13, 8, 700, raid_id, settlement_id, SummaryViewContract.Outcome.EXTRACTED,
		1900, 2, 540, 85, injuries, loot, task_results, 3000, 0, digest, corrections)
	check(view != null and view.outcome() == SummaryViewContract.Outcome.EXTRACTED,
		"summary outcome is typed")
	check(view.raid_id().is_equal(raid_id) and view.settlement_id().is_equal(settlement_id),
		"summary exposes stable raid and settlement identities")
	check(view.loot_value() == 2400 and view.reward_value() == 3000,
		"summary exposes reconciled loot and reward values")
	check(view.injuries().is_read_only() and view.loot().is_read_only()
		and view.task_results().is_read_only() and view.corrections().is_read_only(),
		"summary collections are read-only")
	check(view.audit_digest() == digest, "summary exposes its audit digest")
	var detached := view.loot()[0]
	detached._quantity = 99
	check(view.loot_value() == 2400,
		"detached loot mutation cannot alter the summary view")
	view._revision = 999
	view._loot[0]._quantity = 99
	view._raid_key = "invalid"
	check(view.revision() == 8 and view.loot_value() == 2400
		and view.raid_id().is_equal(raid_id),
		"sealed provenance and retained child state reject external mutation")


func _test_rejections() -> void:
	var actor_id := ZEntityId.from_parts(PackedStringArray(["view", "invalid_actor"]))
	var empty_containers: Array[InventoryViewContract.ContainerRecord] = []
	check(InventoryViewContract.create(
		0, 0, 0, InventoryViewContract.Scope.RAID, actor_id, empty_containers) == null,
		"ready views require a positive generation")
	check(InventoryViewContract.ItemRecord.create(
		0, &"zerkov.item.invalid", "Invalid", 1, Vector2i.ZERO,
		Vector2i.ONE, false, &"", &"") == null,
		"inventory rejects nonpositive item identity")
	var no_items: Array[InventoryViewContract.ItemRecord] = []
	var revision_a := InventoryViewContract.ContainerRecord.create(
		7, 1, 3, InventoryViewContract.ContainerKind.POCKETS,
		&"zerkov.container.player.pockets", "Pockets", Vector2i.ONE, false, no_items)
	var revision_b := InventoryViewContract.ContainerRecord.create(
		7, 2, 4, InventoryViewContract.ContainerKind.RIG,
		&"zerkov.container.player.rig", "Rig", Vector2i.ONE, false, no_items)
	var mixed_revisions: Array[InventoryViewContract.ContainerRecord] = [revision_a, revision_b]
	check(InventoryViewContract.create(
		1, 1, 1, InventoryViewContract.Scope.RAID, actor_id, mixed_revisions) == null,
		"inventory rejects conflicting revisions for one authoritative inventory")
	check(HealthViewContract.BodyPart.create(
		&"head", "Head", 1, 0, HealthViewContract.BodyPartState.HEALTHY) == null,
		"health rejects invalid bounds")
	check(MapViewContract.Zone.create(
		&"zerkov.level.invalid", "Invalid", "Invalid", "LOW", 1, 1, 1,
		Vector2(1.1, 0.5), MapViewContract.ZoneState.AVAILABLE) == null,
		"map rejects out-of-range normalized positions")
	check(BunkerViewContract.Station.create(
		&"zerkov.bunker.station.invalid", "Invalid", 1, 1,
		BunkerViewContract.StationState.FEATURE_GATED, "Invalid", &"") == null,
		"feature-gated bunker station requires a reason")
	check(SummaryViewContract.LootLine.create(
		&"zerkov.item.invalid", "Invalid", 0, 1,
		SummaryViewContract.LootDisposition.LOST) == null,
		"summary rejects invalid loot quantities")
	var bare := RaidViewContract.new()
	check(not bare._initialize_view(1, 0, 0, ZReadOnlyView.SyncState.READY),
		"bare subtype cannot initialize arbitrary READY state")
	var raid_id := ZRaidId.from_parts(PackedStringArray(["view", "stale_raid"]))
	var stale_actor := ZEntityId.from_parts(PackedStringArray(["view", "stale_actor"]))
	check(RaidViewContract.unavailable(
		ZReadOnlyView.SyncState.STALE, &"projection_lag", 2, 4, 8) == null,
		"subject-bearing sync states reject missing identity")
	var stale := RaidViewContract.unavailable(
		ZReadOnlyView.SyncState.STALE, &"projection_lag", 2, 4, 8,
		raid_id, stale_actor)
	check(stale != null and stale.raid_id().is_equal(raid_id)
		and stale.actor_id().is_equal(stale_actor),
		"stale projection preserves stable subject identity")
	check(HealthViewContract.BodyPart.create(
		&"head", "Head", 10, 35, HealthViewContract.BodyPartState.HEALTHY) == null,
		"healthy body part rejects reduced health")
	var destroyed := HealthViewContract.BodyPart.create(
		&"head", "Head", 0, 35, HealthViewContract.BodyPartState.DESTROYED)
	var destroyed_parts: Array[HealthViewContract.BodyPart] = [destroyed]
	var no_effects: Array[HealthViewContract.StatusEffect] = []
	check(HealthViewContract.create(
		1, 0, 0, stale_actor, HealthViewContract.LifeState.ALIVE,
		1, 1, 1, 1, 1, 1, destroyed_parts, no_effects) == null,
		"alive health projection rejects zero aggregate health")
	check(HealthViewContract.BodyPart.create(
		&"arm", "Arm", 0, 40, HealthViewContract.BodyPartState.INJURED) == null,
		"zero-health body part must be destroyed")
	var healthy_torso := HealthViewContract.BodyPart.create(
		&"torso", "Torso", 85, 85, HealthViewContract.BodyPartState.HEALTHY)
	var lethal_parts: Array[HealthViewContract.BodyPart] = [destroyed, healthy_torso]
	check(HealthViewContract.create(
		1, 1, 1, stale_actor, HealthViewContract.LifeState.DEAD,
		1, 1, 1, 1, 1, 1, lethal_parts, no_effects) != null,
		"dead state permits positive aggregate health without inventing lethal-zone policy")


func _test_adversarial_children() -> void:
	var raid_id := ZRaidId.from_parts(PackedStringArray(["view", "child_raid"]))
	var actor_id := ZEntityId.from_parts(PackedStringArray(["view", "child_actor"]))
	var no_extractions: Array[RaidViewContract.Extraction] = []
	var no_feed: Array[RaidViewContract.FeedEntry] = []
	check(RaidViewContract.create(1, 1, 1, raid_id, actor_id,
		RaidViewContract.Lifecycle.ACTIVE, &"zerkov.level.sawmill_yard", "Sawmill",
		0, 60, RaidViewContract.WeaponState.new(), no_extractions, no_feed) == null,
		"uninitialized weapon fails cleanly")
	var weapon_id := ZWeaponId.from_parts(PackedStringArray(["view", "forged_weapon"]))
	var forged_weapon := RaidViewContract.WeaponState.new()
	forged_weapon._weapon_key = weapon_id.canonical_key()
	forged_weapon._content_id = &"zerkov.weapon.rifle.ak74"
	forged_weapon._display_name = "AK-74"
	forged_weapon._status = RaidViewContract.WeaponStatus.READY
	forged_weapon._magazine_rounds = 30
	forged_weapon._magazine_capacity = 30
	forged_weapon._reserve_rounds = 60
	forged_weapon._fire_mode = &"auto"
	check(forged_weapon.snapshot() != null and RaidViewContract.create(
		1, 1, 1, raid_id, actor_id, RaidViewContract.Lifecycle.ACTIVE,
		&"zerkov.level.sawmill_yard", "Sawmill", 0, 60, forged_weapon,
		no_extractions, no_feed) == null,
		"snapshot-able but factory-uninitialized weapon is rejected")
	var bad_feed: Array[RaidViewContract.FeedEntry] = [RaidViewContract.FeedEntry.new()]
	check(RaidViewContract.create(1, 1, 1, raid_id, actor_id,
		RaidViewContract.Lifecycle.ACTIVE, &"zerkov.level.sawmill_yard", "Sawmill",
		0, 60, null, no_extractions, bad_feed) == null,
		"uninitialized feed entry fails cleanly")
	var event_id := ZConsequenceId.from_parts(PackedStringArray(["view", "forged_feed"]))
	var forged_feed_entry := RaidViewContract.FeedEntry.new()
	forged_feed_entry._event_key = event_id.canonical_key()
	forged_feed_entry._kind = RaidViewContract.FeedKind.SYSTEM
	forged_feed_entry._text = "Forged"
	forged_feed_entry._tick = 1
	var forged_feed: Array[RaidViewContract.FeedEntry] = [forged_feed_entry]
	check(forged_feed_entry.snapshot() != null and RaidViewContract.create(
		1, 1, 1, raid_id, actor_id, RaidViewContract.Lifecycle.ACTIVE,
		&"zerkov.level.sawmill_yard", "Sawmill", 0, 60, null,
		no_extractions, forged_feed) == null,
		"snapshot-able but factory-uninitialized feed entry is rejected")
	var bad_extractions: Array[RaidViewContract.Extraction] = [RaidViewContract.Extraction.new()]
	check(RaidViewContract.create(1, 1, 1, raid_id, actor_id,
		RaidViewContract.Lifecycle.ACTIVE, &"zerkov.level.sawmill_yard", "Sawmill",
		0, 60, null, bad_extractions, no_feed) == null,
		"uninitialized extraction fails cleanly")
	var forged_extraction := RaidViewContract.Extraction.new()
	forged_extraction._extract_id = &"zerkov.extraction.gate"
	forged_extraction._display_name = "Gate"
	forged_extraction._status = RaidViewContract.ExtractionStatus.AVAILABLE
	forged_extraction._required_ticks = 1
	var forged_extractions: Array[RaidViewContract.Extraction] = [forged_extraction]
	check(forged_extraction.snapshot() != null and RaidViewContract.create(
		1, 1, 1, raid_id, actor_id, RaidViewContract.Lifecycle.ACTIVE,
		&"zerkov.level.sawmill_yard", "Sawmill", 0, 60, null,
		forged_extractions, no_feed) == null,
		"snapshot-able but factory-uninitialized extraction is rejected")

	var bad_items: Array[InventoryViewContract.ItemRecord] = [
		InventoryViewContract.ItemRecord.new()]
	check(InventoryViewContract.ContainerRecord.create(1, 1, 1,
		InventoryViewContract.ContainerKind.POCKETS, &"zerkov.container.player.pockets",
		"Pockets", Vector2i.ONE, false, bad_items) == null,
		"uninitialized item fails cleanly")
	var forged_item := InventoryViewContract.ItemRecord.new()
	forged_item._instance_id = 45
	forged_item._content_id = &"zerkov.item.junk.battery"
	forged_item._display_name = "Battery"
	forged_item._quantity = 1
	forged_item._size = Vector2i.ONE
	var forged_items: Array[InventoryViewContract.ItemRecord] = [forged_item]
	check(forged_item.snapshot() != null and InventoryViewContract.ContainerRecord.create(
		1, 1, 1, InventoryViewContract.ContainerKind.POCKETS,
		&"zerkov.container.player.pockets", "Pockets", Vector2i.ONE,
		false, forged_items) == null,
		"snapshot-able but factory-uninitialized item is rejected")
	var bad_containers: Array[InventoryViewContract.ContainerRecord] = [
		InventoryViewContract.ContainerRecord.new()]
	check(InventoryViewContract.create(1, 1, 1, InventoryViewContract.Scope.RAID,
		actor_id, bad_containers) == null, "uninitialized container fails cleanly")
	var forged_container := InventoryViewContract.ContainerRecord.new()
	forged_container._inventory_id = 1
	forged_container._container_id = 1
	forged_container._inventory_revision = 1
	forged_container._kind = InventoryViewContract.ContainerKind.POCKETS
	forged_container._content_id = &"zerkov.container.player.pockets"
	forged_container._display_name = "Pockets"
	forged_container._grid_size = Vector2i.ONE
	var forged_containers: Array[InventoryViewContract.ContainerRecord] = [forged_container]
	check(forged_container.snapshot() != null and InventoryViewContract.create(
		1, 1, 1, InventoryViewContract.Scope.RAID, actor_id,
		forged_containers) == null,
		"snapshot-able but factory-uninitialized container is rejected")
	var duplicate_item := InventoryViewContract.ItemRecord.create(44,
		&"zerkov.item.junk.battery", "Battery", 1, Vector2i.ZERO, Vector2i.ONE,
		false, &"battery", &"utility")
	var duplicated_items: Array[InventoryViewContract.ItemRecord] = [duplicate_item]
	var first_container := InventoryViewContract.ContainerRecord.create(7, 1, 3,
		InventoryViewContract.ContainerKind.POCKETS, &"zerkov.container.player.pockets",
		"Pockets", Vector2i.ONE, false, duplicated_items)
	var second_container := InventoryViewContract.ContainerRecord.create(7, 2, 3,
		InventoryViewContract.ContainerKind.RIG, &"zerkov.container.player.rig",
		"Rig", Vector2i.ONE, false, duplicated_items)
	var duplicate_containers: Array[InventoryViewContract.ContainerRecord] = [
		first_container, second_container]
	check(InventoryViewContract.create(1, 1, 1, InventoryViewContract.Scope.RAID,
		actor_id, duplicate_containers) == null,
		"item instance identity is unique across one inventory")
	var foreign_container := InventoryViewContract.ContainerRecord.create(8, 1, 9,
		InventoryViewContract.ContainerKind.CRATE, &"zerkov.container.world.crate",
		"Crate", Vector2i.ONE, true, duplicated_items)
	var distinct_inventory_containers: Array[InventoryViewContract.ContainerRecord] = [
		first_container, foreign_container]
	check(InventoryViewContract.create(1, 1, 1, InventoryViewContract.Scope.RAID,
		actor_id, distinct_inventory_containers) != null,
		"same native item number is valid in distinct inventories")

	var bad_parts: Array[HealthViewContract.BodyPart] = [HealthViewContract.BodyPart.new()]
	var no_effects: Array[HealthViewContract.StatusEffect] = []
	check(HealthViewContract.create(1, 1, 1, actor_id, HealthViewContract.LifeState.ALIVE,
		1, 1, 1, 1, 1, 1, bad_parts, no_effects) == null,
		"uninitialized body part fails cleanly")
	var forged_part := HealthViewContract.BodyPart.new()
	forged_part._part_id = &"torso"
	forged_part._display_name = "Torso"
	forged_part._current_health = 85
	forged_part._maximum_health = 85
	forged_part._state = HealthViewContract.BodyPartState.HEALTHY
	var forged_parts: Array[HealthViewContract.BodyPart] = [forged_part]
	check(forged_part.snapshot() != null and HealthViewContract.create(
		1, 1, 1, actor_id, HealthViewContract.LifeState.ALIVE,
		1, 1, 1, 1, 1, 1, forged_parts, no_effects) == null,
		"snapshot-able but factory-uninitialized body part is rejected")
	var good_part := HealthViewContract.BodyPart.create(
		&"torso", "Torso", 85, 85, HealthViewContract.BodyPartState.HEALTHY)
	var good_parts: Array[HealthViewContract.BodyPart] = [good_part]
	var bad_effects: Array[HealthViewContract.StatusEffect] = [
		HealthViewContract.StatusEffect.new()]
	check(HealthViewContract.create(1, 1, 1, actor_id, HealthViewContract.LifeState.ALIVE,
		1, 1, 1, 1, 1, 1, good_parts, bad_effects) == null,
		"uninitialized health effect fails cleanly")
	var forged_effect := HealthViewContract.StatusEffect.new()
	forged_effect._effect_id = &"zerkov.effect.test"
	forged_effect._display_name = "Test"
	forged_effect._severity = HealthViewContract.Severity.INFO
	var forged_effects: Array[HealthViewContract.StatusEffect] = [forged_effect]
	check(forged_effect.snapshot() != null and HealthViewContract.create(
		1, 1, 1, actor_id, HealthViewContract.LifeState.ALIVE,
		1, 1, 1, 1, 1, 1, good_parts, forged_effects) == null,
		"snapshot-able but factory-uninitialized health effect is rejected")

	var task_id := ZTaskId.from_parts(PackedStringArray(["view", "child_task"]))
	var bad_objectives: Array[TaskViewContract.Objective] = [TaskViewContract.Objective.new()]
	var no_rewards: Array[TaskViewContract.Reward] = []
	check(TaskViewContract.Entry.create(task_id, "Task", "Description", "Fence",
		&"zerkov.level.sawmill_yard", TaskViewContract.Status.ACTIVE, false,
		bad_objectives, no_rewards) == null, "uninitialized objective fails cleanly")
	var forged_objective := TaskViewContract.Objective.new()
	forged_objective._objective_id = &"objective"
	forged_objective._description = "Do it"
	forged_objective._target = 1
	var forged_objectives: Array[TaskViewContract.Objective] = [forged_objective]
	check(forged_objective.snapshot() != null and TaskViewContract.Entry.create(
		task_id, "Task", "Description", "Fence", &"zerkov.level.sawmill_yard",
		TaskViewContract.Status.ACTIVE, false, forged_objectives,
		no_rewards) == null,
		"snapshot-able but factory-uninitialized objective is rejected")
	var good_objective := TaskViewContract.Objective.create(&"objective", "Do it", 0, 1)
	var good_objectives: Array[TaskViewContract.Objective] = [good_objective]
	var bad_rewards: Array[TaskViewContract.Reward] = [TaskViewContract.Reward.new()]
	check(TaskViewContract.Entry.create(task_id, "Task", "Description", "Fence",
		&"zerkov.level.sawmill_yard", TaskViewContract.Status.ACTIVE, false,
		good_objectives, bad_rewards) == null, "uninitialized reward fails cleanly")
	var forged_reward := TaskViewContract.Reward.new()
	forged_reward._reward_id = &"reward"
	forged_reward._kind = TaskViewContract.RewardKind.CURRENCY
	forged_reward._content_id = &"zerkov.currency.rouble"
	forged_reward._display_name = "Roubles"
	forged_reward._amount = 1
	var forged_rewards: Array[TaskViewContract.Reward] = [forged_reward]
	check(forged_reward.snapshot() != null and TaskViewContract.Entry.create(
		task_id, "Task", "Description", "Fence", &"zerkov.level.sawmill_yard",
		TaskViewContract.Status.ACTIVE, false, good_objectives,
		forged_rewards) == null,
		"snapshot-able but factory-uninitialized reward is rejected")
	var bad_tasks: Array[TaskViewContract.Entry] = [TaskViewContract.Entry.new()]
	check(TaskViewContract.create(1, 1, 1, bad_tasks) == null,
		"uninitialized task entry fails cleanly")
	var forged_task := TaskViewContract.Entry.new()
	forged_task._task_key = task_id.canonical_key()
	forged_task._title = "Task"
	forged_task._description = "Description"
	forged_task._trader_name = "Fence"
	forged_task._zone_id = &"zerkov.level.sawmill_yard"
	forged_task._status = TaskViewContract.Status.ACTIVE
	var forged_tasks: Array[TaskViewContract.Entry] = [forged_task]
	check(forged_task.snapshot() != null and TaskViewContract.create(
		1, 1, 1, forged_tasks) == null,
		"snapshot-able but factory-uninitialized task entry is rejected")

	var bad_zones: Array[MapViewContract.Zone] = [MapViewContract.Zone.new()]
	var no_markers: Array[MapViewContract.Marker] = []
	check(MapViewContract.create(1, 1, 1, &"zerkov.map.sawmill", "Sawmill",
		&"zerkov.level.sawmill_yard", &"day", 1000, bad_zones, no_markers) == null,
		"uninitialized map zone fails cleanly")
	var forged_zone := MapViewContract.Zone.new()
	forged_zone._zone_id = &"zerkov.level.sawmill_yard"
	forged_zone._display_name = "Sawmill"
	forged_zone._summary = "Yard"
	forged_zone._risk_label = "LOW"
	forged_zone._duration_ticks = 60
	forged_zone._state = MapViewContract.ZoneState.SELECTED
	var forged_zones: Array[MapViewContract.Zone] = [forged_zone]
	check(forged_zone.snapshot() != null and MapViewContract.create(
		1, 1, 1, &"zerkov.map.sawmill", "Sawmill",
		&"zerkov.level.sawmill_yard", &"day", 1000,
		forged_zones, no_markers) == null,
		"snapshot-able but factory-uninitialized map zone is rejected")
	var good_zone := MapViewContract.Zone.create(&"zerkov.level.sawmill_yard", "Sawmill",
		"Yard", "LOW", 60, 1, 1, Vector2.ZERO, MapViewContract.ZoneState.SELECTED)
	var good_zones: Array[MapViewContract.Zone] = [good_zone]
	var bad_markers: Array[MapViewContract.Marker] = [MapViewContract.Marker.new()]
	check(MapViewContract.create(1, 1, 1, &"zerkov.map.sawmill", "Sawmill",
		&"zerkov.level.sawmill_yard", &"day", 1000, good_zones, bad_markers) == null,
		"uninitialized map marker fails cleanly")
	var forged_marker := MapViewContract.Marker.new()
	forged_marker._marker_id = &"marker"
	forged_marker._kind = MapViewContract.MarkerKind.PLAYER
	forged_marker._content_id = &"zerkov.marker.player"
	forged_marker._label = "Player"
	var forged_markers: Array[MapViewContract.Marker] = [forged_marker]
	check(forged_marker.snapshot() != null and MapViewContract.create(
		1, 1, 1, &"zerkov.map.sawmill", "Sawmill",
		&"zerkov.level.sawmill_yard", &"day", 1000,
		good_zones, forged_markers) == null,
		"snapshot-able but factory-uninitialized map marker is rejected")

	var bad_stations: Array[BunkerViewContract.Station] = [BunkerViewContract.Station.new()]
	check(BunkerViewContract.create(1, 1, 1, "Profile", 1, 1, 0, 0, 1,
		true, &"", &"", bad_stations) == null,
		"uninitialized bunker station fails cleanly")
	var forged_station := BunkerViewContract.Station.new()
	forged_station._station_id = &"zerkov.station.generator"
	forged_station._display_name = "Generator"
	forged_station._maximum_level = 1
	forged_station._state = BunkerViewContract.StationState.AVAILABLE
	forged_station._summary = "Ready"
	var forged_stations: Array[BunkerViewContract.Station] = [forged_station]
	check(forged_station.snapshot() != null and BunkerViewContract.create(
		1, 1, 1, "Profile", 1, 1, 0, 0, 1, true, &"", &"",
		forged_stations) == null,
		"snapshot-able but factory-uninitialized bunker station is rejected")

	var settlement_id := ZSettlementId.from_parts(PackedStringArray(["view", "child_settlement"]))
	var digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	var no_injuries: Array[StringName] = []
	var bad_loot: Array[SummaryViewContract.LootLine] = [SummaryViewContract.LootLine.new()]
	var no_task_results: Array[SummaryViewContract.TaskResult] = []
	var no_corrections: Array[SummaryViewContract.Correction] = []
	check(SummaryViewContract.create(1, 1, 1, raid_id, settlement_id,
		SummaryViewContract.Outcome.EXTRACTED, 1, 0, 0, 0, no_injuries, bad_loot,
		no_task_results, 0, 0, digest, no_corrections) == null,
		"uninitialized summary loot line fails cleanly")
	var forged_loot_line := SummaryViewContract.LootLine.new()
	forged_loot_line._content_id = &"zerkov.item.junk.battery"
	forged_loot_line._display_name = "Battery"
	forged_loot_line._quantity = 1
	forged_loot_line._disposition = SummaryViewContract.LootDisposition.RETAINED
	var forged_loot: Array[SummaryViewContract.LootLine] = [forged_loot_line]
	check(forged_loot_line.snapshot() != null and SummaryViewContract.create(
		1, 1, 1, raid_id, settlement_id, SummaryViewContract.Outcome.EXTRACTED,
		1, 0, 0, 0, no_injuries, forged_loot, no_task_results,
		0, 0, digest, no_corrections) == null,
		"snapshot-able but factory-uninitialized summary loot line is rejected")
	var no_loot: Array[SummaryViewContract.LootLine] = []
	var bad_task_results: Array[SummaryViewContract.TaskResult] = [
		SummaryViewContract.TaskResult.new()]
	check(SummaryViewContract.create(1, 1, 1, raid_id, settlement_id,
		SummaryViewContract.Outcome.EXTRACTED, 1, 0, 0, 0, no_injuries, no_loot,
		bad_task_results, 0, 0, digest, no_corrections) == null,
		"uninitialized summary task result fails cleanly")
	var forged_task_result := SummaryViewContract.TaskResult.new()
	forged_task_result._task_key = task_id.canonical_key()
	forged_task_result._title = "Task"
	forged_task_result._total_objectives = 1
	var forged_task_results: Array[SummaryViewContract.TaskResult] = [forged_task_result]
	check(forged_task_result.snapshot() != null and SummaryViewContract.create(
		1, 1, 1, raid_id, settlement_id, SummaryViewContract.Outcome.EXTRACTED,
		1, 0, 0, 0, no_injuries, no_loot, forged_task_results,
		0, 0, digest, no_corrections) == null,
		"snapshot-able but factory-uninitialized summary task result is rejected")
	var bad_corrections: Array[SummaryViewContract.Correction] = [
		SummaryViewContract.Correction.new()]
	check(SummaryViewContract.create(1, 1, 1, raid_id, settlement_id,
		SummaryViewContract.Outcome.EXTRACTED, 1, 0, 0, 0, no_injuries, no_loot,
		no_task_results, 0, 0, digest, bad_corrections) == null,
		"uninitialized summary correction fails cleanly")
	var forged_correction := SummaryViewContract.Correction.new()
	forged_correction._correction_key = event_id.canonical_key()
	forged_correction._code = &"test"
	forged_correction._description = "Test"
	var forged_corrections: Array[SummaryViewContract.Correction] = [forged_correction]
	check(forged_correction.snapshot() != null and SummaryViewContract.create(
		1, 1, 1, raid_id, settlement_id, SummaryViewContract.Outcome.EXTRACTED,
		1, 0, 0, 0, no_injuries, no_loot, no_task_results,
		0, 0, digest, forged_corrections) == null,
		"snapshot-able but factory-uninitialized summary correction is rejected")
