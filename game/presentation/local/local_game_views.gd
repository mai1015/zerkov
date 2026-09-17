class_name LocalGameViews
extends RefCounted
## Converts closed, value-only local application frames into the established UI
## contracts. UI generation is a presentation lineage, not a raid authority epoch.
const MAP: StringName = &"zerkov.level.sawmill_yard"
const TASK_CONTENT: StringName = &"zerkov.task.supply_run"
const MISSING = ZReadOnlyView.SyncState.UNBOUND
const DOMAIN_BUNKER: int = 0
const DOMAIN_RAID: int = 1
const DOMAIN_TASKS: int = 2
const DOMAIN_MAP: int = 3
const DOMAIN_SUMMARY: int = 4
const DOMAIN_COUNT: int = 5


static func build(frame: Dictionary) -> Array[ZReadOnlyView]:
	return build_incremental(frame).get("views", []) as Array[ZReadOnlyView]


## Reuses exact immutable domain views when their complete semantic inputs did
## not change. A reused view deliberately keeps the source tick at which that
## domain last changed; the live raid view still advances every authority tick.
static func build_incremental(
	frame: Dictionary,
	previous_views: Array[ZReadOnlyView] = [],
	previous_dependencies: Array = []
) -> Dictionary:
	var dependencies := _domain_dependencies(frame)
	var views: Array[ZReadOnlyView] = []
	var rebuilt := PackedInt32Array()
	for index in DOMAIN_COUNT:
		var previous: ZReadOnlyView = previous_views[index] \
			if index < previous_views.size() else null
		var reusable := previous != null and previous.is_initialized() \
			and previous.generation() == int(frame.get("epoch", 0)) \
			and index < previous_dependencies.size() \
			and previous_dependencies[index] == dependencies[index]
		if reusable:
			views.append(previous)
		else:
			views.append(_build_domain(index, frame))
			rebuilt.append(index)
	views.make_read_only()
	dependencies.make_read_only()
	return {
		"views": views,
		"dependencies": dependencies,
		"rebuilt": rebuilt,
	}


static func _domain_dependencies(frame: Dictionary) -> Array:
	var epoch := int(frame.get("epoch", 0))
	var mode := String(frame.get("mode", ""))
	var progression := frame.get("progression", {}) as Dictionary
	var combat := frame.get("combat", {}) as Dictionary
	var task_value: Dictionary = progression.get(
		"task", frame.get("summary", {}).get("task", {}))
	var task_raid := String(progression.get(
		"raid_id", frame.get("summary", {}).get("raid_id", "")))
	var searched_mask := 0
	var searched := frame.get("searched_ids", []) as Array
	for index in range(SupplyRunGraph.CRATES.size()):
		if searched.has(SupplyRunGraph.CRATES[index]):
			searched_mask |= 1 << index
	var raid_dependency: Array = [epoch, false]
	if not progression.is_empty() and not combat.is_empty():
		var clock := progression.get("clock", {}) as Dictionary
		var task := progression.get("task", {}) as Dictionary
		raid_dependency = [epoch, true, int(frame.get("tick", 0)),
			String(progression.get("raid_id", "")), int(frame.get("lifecycle", 0)),
			int(frame.get("exit_distance", 0)), String(clock.get("outcome", "")),
			bool(clock.get("counting", false)), int(clock.get("countdown_remaining", 0)),
			int(task.get("searched_crates", 0)), bool(task.get("holds_objective", false)),
			bool(combat.get("has_weapon", false)), bool(combat.get("reloading", false)),
			int(combat.get("ammo", 0)), int(combat.get("reserve", 0)),
			float(combat.get("reload_progress", 0.0)), String(frame.get("actor_id", "")),
			String(frame.get("weapon_id", ""))]
	return [
		RaidProgressionValues.freeze([epoch, bool(frame.get("has_profile", false)), mode]),
		RaidProgressionValues.freeze(raid_dependency),
		RaidProgressionValues.freeze([epoch, mode, task_raid, searched_mask,
			bool(task_value.get("completion_token", false))]),
		RaidProgressionValues.freeze([epoch, frame.get("map_markers", [])]),
		RaidProgressionValues.freeze([epoch, frame.get("summary", {})]),
	]


static func _build_domain(index: int, frame: Dictionary) -> ZReadOnlyView:
	var epoch := int(frame.get("epoch", 0))
	var revision := int(frame.get("serial", 0))
	var tick := int(frame.get("tick", 0))
	match index:
		DOMAIN_BUNKER:
			return _bunker(epoch, revision, tick, frame)
		DOMAIN_RAID:
			return _raid(epoch, revision, tick, frame)
		DOMAIN_TASKS:
			var progression := frame.get("progression", {}) as Dictionary
			var task_value: Dictionary = progression.get(
				"task", frame.get("summary", {}).get("task", {}))
			var task_raid := String(progression.get(
				"raid_id", frame.get("summary", {}).get("raid_id", "")))
			return _tasks(epoch, revision, tick, task_value,
				frame.get("searched_ids", []), String(frame.get("mode", "")), task_raid)
		DOMAIN_MAP:
			return _map(epoch, revision, tick, frame.get("map_markers", []))
		DOMAIN_SUMMARY:
			return _summary(epoch, revision, tick, frame.get("summary", {}))
	return null


static func _bunker(
	epoch: int,
	revision: int,
	tick: int,
	frame: Dictionary
) -> BunkerView:
	if not bool(frame.get("has_profile", false)):
		return BunkerView.unavailable(
			MISSING, &"local_profile_missing", epoch, revision, tick)
	var mode := String(frame.get("mode", ""))
	return BunkerView.create(epoch, revision, tick, "Local operator", 1, 1, 0, 0, 0,
		mode == "home", &"raid_in_progress" if mode != "home" else &"", &"", [])


static func _raid(
	epoch: int,
	revision: int,
	tick: int,
	frame: Dictionary
) -> RaidView:
	var progression := frame.get("progression", {}) as Dictionary
	var combat := frame.get("combat", {}) as Dictionary
	if progression.is_empty() or combat.is_empty():
		return RaidView.unavailable(
			MISSING, &"local_raid_not_active", epoch, revision, tick)
	var clock := progression.get("clock", {}) as Dictionary
	var weapon: RaidView.WeaponState
	if bool(combat.get("has_weapon", false)):
		weapon = RaidView.WeaponState.create(
			ZWeaponId.parse(String(frame.get("weapon_id", ""))),
			ZerkovInventoryCatalog.ITEM_AKM, "AKM",
			RaidView.WeaponStatus.RELOADING if bool(combat.get("reloading", false)) \
				else RaidView.WeaponStatus.READY,
			int(combat.get("ammo", 0)), 30, int(combat.get("reserve", 0)), &"semi",
			int(float(combat.get("reload_progress", 0.0)) * 1000.0))
	var extraction_status := RaidView.ExtractionStatus.LOCKED
	if String(clock.get("outcome", "")) == "extracted":
		extraction_status = RaidView.ExtractionStatus.COMPLETED
	elif bool(clock.get("counting", false)):
		extraction_status = RaidView.ExtractionStatus.COUNTING_DOWN
	elif int((progression.get("task", {}) as Dictionary).get("searched_crates", 0)) == 3 \
			and bool((progression.get("task", {}) as Dictionary).get(
				"holds_objective", false)):
		extraction_status = RaidView.ExtractionStatus.AVAILABLE
	var extracts: Array[RaidView.Extraction] = [RaidView.Extraction.create(
		StringName(SupplyRunGraph.ROAD_GATE), "Road Gate", extraction_status,
		int(frame.get("exit_distance", 0)),
		LocalCampaignContent.EXTRACTION_TICKS - int(clock.get("countdown_remaining", 0)) \
			if bool(clock.get("counting", false)) else 0,
		LocalCampaignContent.EXTRACTION_TICKS,
		&"supply_run_required" if extraction_status == RaidView.ExtractionStatus.LOCKED \
			else &"")]
	return RaidView.create(epoch, revision, tick,
		ZRaidId.parse(String(progression.get("raid_id", ""))),
		ZEntityId.parse(String(frame.get("actor_id", ""))),
		int(frame.get("lifecycle", RaidView.Lifecycle.ACTIVE)), MAP, "Sawmill Yard",
		mini(tick, LocalCampaignContent.RAID_LIMIT_TICKS),
		LocalCampaignContent.RAID_LIMIT_TICKS, weapon, extracts, [])


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
