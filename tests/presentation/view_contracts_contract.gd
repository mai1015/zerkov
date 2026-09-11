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
