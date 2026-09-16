class_name LocalGameViews
extends RefCounted
## Converts closed, value-only local application frames into the established UI
## contracts. UI generation is a presentation lineage, not a raid authority epoch.
const MAP: StringName = &"zerkov.level.sawmill_yard"
const TASK_CONTENT: StringName = &"zerkov.task.supply_run"
const MISSING = ZReadOnlyView.SyncState.UNBOUND

static func build(frame: Dictionary) -> Array[ZReadOnlyView]:
	var epoch: int = frame.epoch
	var revision: int = frame.serial
	var tick: int = frame.get("tick", 0)
	var bunker: BunkerView = BunkerView.unavailable(MISSING, &"local_profile_missing", epoch, revision, tick)
	if frame.get("has_profile", false):
		bunker = BunkerView.create(epoch, revision, tick, "Local operator", 1, 1, 0, 0, 0,
			frame.mode == "home", &"raid_in_progress" if frame.mode != "home" else &"", &"", [])
	var raid: RaidView = RaidView.unavailable(MISSING, &"local_raid_not_active", epoch, revision, tick)
	var progression: Dictionary = frame.get("progression", {})
	var combat: Dictionary = frame.get("combat", {})
	if not progression.is_empty() and not combat.is_empty():
		var clock: Dictionary = progression.clock
		var weapon: RaidView.WeaponState
		if combat.get("has_weapon", false):
			weapon = RaidView.WeaponState.create(ZWeaponId.parse(String(frame.weapon_id)), ZerkovInventoryCatalog.ITEM_AKM,
				"AKM", RaidView.WeaponStatus.RELOADING if combat.reloading else RaidView.WeaponStatus.READY,
				combat.ammo, 30, combat.reserve, &"semi", int(combat.reload_progress * 1000))
		var extraction_status := RaidView.ExtractionStatus.LOCKED
		if clock.get("outcome") == "extracted": extraction_status = RaidView.ExtractionStatus.COMPLETED
		elif clock.counting: extraction_status = RaidView.ExtractionStatus.COUNTING_DOWN
		elif int(progression.task.get("searched_crates", 0)) == 3 and progression.task.get("holds_objective", false): extraction_status = RaidView.ExtractionStatus.AVAILABLE
		var extracts: Array[RaidView.Extraction] = [RaidView.Extraction.create(StringName(SupplyRunGraph.ROAD_GATE), "Road Gate",
			extraction_status, int(frame.get("exit_distance", 0)),
			LocalCampaignContent.EXTRACTION_TICKS - int(clock.countdown_remaining) if clock.counting else 0,
			LocalCampaignContent.EXTRACTION_TICKS, &"supply_run_required" if extraction_status == RaidView.ExtractionStatus.LOCKED else &"")]
		raid = RaidView.create(epoch, revision, tick, ZRaidId.parse(progression.raid_id), ZEntityId.parse(frame.actor_id),
			int(frame.get("lifecycle", RaidView.Lifecycle.ACTIVE)),
			MAP, "Sawmill Yard", mini(tick, LocalCampaignContent.RAID_LIMIT_TICKS), LocalCampaignContent.RAID_LIMIT_TICKS, weapon, extracts, [])
	var task_value: Dictionary = progression.get("task", frame.get("summary", {}).get("task", {}))
	var task_raid := String(progression.get("raid_id", frame.get("summary", {}).get("raid_id", "")))
	var tasks := _tasks(epoch, revision, tick, task_value, frame.get("searched_ids", []), frame.mode, task_raid)
	var map := _map(epoch, revision, tick, frame.get("map_markers", []))
	var summary := _summary(epoch, revision, tick, frame.get("summary", {}))
	return [bunker, raid, tasks, map, summary]

static func task_identity(raid_key: String = "") -> ZTaskId:
	# The native graph definition ID is content, not a canonical instance ID.
	var suffix := "preview" if raid_key.is_empty() else "r" + raid_key.sha256_text().substr(0, 32)
	return ZTaskId.from_parts(PackedStringArray(["supply_run", suffix]))

static func _tasks(epoch: int, revision: int, tick: int, value: Dictionary, searched: Array, mode: String, raid_key: String) -> TaskView:
	var objectives: Array[TaskView.Objective] = []
	for index in range(3):
		objectives.append(TaskView.Objective.create(StringName("zerkov.objective.local.crate%d" % index),
			["Search Log Racks crate", "Search Saw House crate", "Search Settling Dock crate"][index],
			1 if searched.has(SupplyRunGraph.CRATES[index]) else 0, 1))
	objectives.append(TaskView.Objective.create(&"zerkov.objective.local.extract", "Retain supplies and extract through Road Gate",
		1 if value.get("completion_token", false) else 0, 1))
	var status: TaskView.Status = TaskView.Status.AVAILABLE
	if mode in ["raid", "settling", "save_error"]: status = TaskView.Status.ACTIVE
	if mode == "summary": status = TaskView.Status.COMPLETED if value.get("completion_token", false) else TaskView.Status.FAILED
	var entries: Array[TaskView.Entry] = [TaskView.Entry.create(task_identity(raid_key), "Supply Run",
		"Search three marked crates, take the supply crate, and hold Road Gate for five seconds. Damage, leaving or losing supplies interrupts extraction.",
		"Local contract", MAP, status, true, objectives, [])]
	return TaskView.create(epoch, revision, tick, entries, task_identity(raid_key))

static func _map(epoch: int, revision: int, tick: int, points: Array) -> MapView:
	var zones: Array[MapView.Zone] = [MapView.Zone.create(MAP, "Sawmill Yard", "Supply Run · three marked crates and Road Gate",
		"Scav / mutant", LocalCampaignContent.RAID_LIMIT_TICKS, 1, 1, Vector2(0.5, 0.5), MapView.ZoneState.SELECTED)]
	var markers: Array[MapView.Marker] = []
	for point: Dictionary in points:
		markers.append(MapView.Marker.create(StringName(point.id), MapView.MarkerKind.PLAYER if point.kind == "player" else (
			MapView.MarkerKind.EXTRACTION if point.kind == "exit" else MapView.MarkerKind.TASK),
			StringName(point.id), point.label, point.position, true, true))
	return MapView.create(epoch, revision, tick, &"zerkov.map.sawmill", "Sawmill Yard", MAP, &"day", 1000, zones, markers)

static func _summary(epoch: int, revision: int, tick: int, receipt: Dictionary) -> SummaryView:
	if receipt.is_empty(): return SummaryView.unavailable(MISSING, &"settlement_not_committed", epoch, revision, tick)
	if not RaidProgressionValues.valid_receipt(receipt):
		return SummaryView.unavailable(ZReadOnlyView.SyncState.UNBOUND, &"settlement_receipt_invalid", epoch, revision, tick)
	var lines: Array[SummaryView.LootLine] = []
	for group: String in ["retained", "lost"]:
		for row: Dictionary in receipt.get(group, []):
			lines.append(SummaryView.LootLine.create(StringName(row.definition), display_item(row.definition), row.quantity, 0,
				SummaryView.LootDisposition.RETAINED if group == "retained" else SummaryView.LootDisposition.LOST))
	var outcome: SummaryView.Outcome = SummaryView.Outcome.EXTRACTED if receipt.outcome == "extracted" else (
		SummaryView.Outcome.DIED if receipt.outcome == "dead" else SummaryView.Outcome.FAILED)
	var stats: Dictionary = receipt.get("stats", {})
	var injuries: Array[StringName] = []
	for part: Dictionary in receipt.health.get("body_parts", []):
		var zone := String(part.get("zone", ""))
		if part.get("bleeding", false): injuries.append(StringName("zerkov.injury." + zone + ".bleeding"))
		if part.get("fractured", false): injuries.append(StringName("zerkov.injury." + zone + ".fracture"))
		if int(part.get("health_micros", 0)) == 0: injuries.append(StringName("zerkov.injury." + zone + ".destroyed"))
	var task_results: Array[SummaryView.TaskResult] = []
	if not receipt.task.is_empty():
		var completed: bool = receipt.task.get("completion_token", false)
		var count := 4 if completed else clampi(int(receipt.task.get("searched_crates", 0)), 0, 3)
		task_results.append(SummaryView.TaskResult.create(task_identity(receipt.raid_id), "Supply Run", count, 4, completed, 0))
	return SummaryView.create(epoch, revision, tick, ZRaidId.parse(receipt.raid_id), ZSettlementId.parse(receipt.settlement_id),
		outcome, receipt.duration_ticks, stats.get("kills", 0), int(stats.get("damage_dealt_micros", 0)) / 1_000_000,
		int(stats.get("damage_received_micros", 0)) / 1_000_000, injuries, lines, task_results, 0, 0,
		receipt.audit_digest, [], receipt.audit_available, false)

static func display_item(identifier: String) -> String:
	return identifier.get_slice(".", identifier.get_slice_count(".") - 1).replace("_", " ").capitalize()
