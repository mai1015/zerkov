class_name SupplyRunTask
extends RefCounted
## Game host for the installed native runtime. It only receives verified audit
## facts from raid composition. No inventory, health, UI or scene reference.
var last_error: StringName = &""
var _native: Object
var _raid: String = ""
var _seen_crates: Dictionary = {}
var _sequence: int = 0
var _reward_authorized: bool = false
var _failed: bool = false
var _holds: bool = false
var _map_id: String = "sawmill"
var _facts_initialized: bool = false
var _running: bool = false
var _scope_key: String = ""
var _pending_requests: Array = []
var _snapshot_cache: Dictionary = {}
var _summary_reads: int = 0
var _fact_updates: int = 0
var _snapshot_reuses: int = 0

func configure(raid_id: String, map_id: String = "sawmill") -> bool:
	if not SupplyRunGraph.is_map(map_id): return _reject(&"task_map_unknown")
	_map_id=map_id
	if _native != null or not ZIdentityRules.is_valid(raid_id, &"raid") or not ClassDB.class_exists("LevelTaskRuntimeBridge"):
		return _reject(&"task_native_runtime_unavailable")
	_native = ClassDB.instantiate("LevelTaskRuntimeBridge")
	for method: String in ["compile_task_graph","start_task_graph","set_task_facts","inject_task_event","step_task","acknowledge_task_request","reject_task_request","get_task_summary"]:
		if not _native.has_method(method): return _reject(&"task_native_api_missing")
	_raid = raid_id
	var compiled: Dictionary = _native.call("compile_task_graph", SupplyRunGraph.definition(_map_id))
	if compiled.get("ok") != true: return _reject(&"task_definition_rejected")
	# Native IDs have stricter grammar than product IDs. Hash scope without
	# exposing or truncating the canonical raid identity at the host boundary.
	var suffix := "h" + raid_id.sha256_text().substr(0,24)
	var started: Dictionary = _native.call("start_task_graph", SupplyRunGraph.definition(_map_id), "zerkov.task."+suffix, "zerkov.raid."+suffix, {})
	if started.get("ok") != true: return _reject(&"task_start_failed")
	if not _refresh_snapshot(): return false
	return _ack("accept", false)

func update_facts(holds_objective: bool) -> bool:
	if not _active(): return false
	if _facts_initialized and _holds == holds_objective:
		return true
	var result: Dictionary = _native.call("set_task_facts", {"facts":[{"provider_identifier":"zerkov.fact.inventory", "fact_identifier":"zerkov.fact.holds_supply", "value":{"type":"boolean","value":holds_objective}}]})
	if result.get("ok") != true: return _reject(&"task_fact_rejected")
	_holds = holds_objective
	_facts_initialized = true
	_fact_updates += 1
	return _refresh_snapshot()

func crate_committed(crate_id: String, audit_sequence: int, tick: int) -> bool:
	if not _active() or audit_sequence <= _sequence or tick < 1: return _reject(&"task_event_order_invalid")
	_sequence = audit_sequence
	var index := SupplyRunGraph.crates_for(_map_id).find(crate_id)
	if index < 0: return _reject(&"task_crate_unknown")
	if _seen_crates.has(crate_id): return true
	if not _event("zerkov.event.crate_"+str(index), audit_sequence, tick): return false
	_seen_crates[crate_id] = true
	return _refresh_snapshot()

func ready_to_extract() -> bool:
	return _active() and _holds and _seen_crates.size() == 3 and not _request("extract").is_empty()

## Completion authorization is backed by the canonical Road Gate outcome.
## RewardRequest means a completion token in this settlement, not invented money.
func extracted(road_gate: String) -> bool:
	if road_gate != SupplyRunGraph.exit_for(_map_id) or not ready_to_extract(): return _reject(&"task_extraction_ineligible")
	if not _ack("extract", false): return false
	_reward_authorized = true
	if not _ack("reward", true): return false
	return String(snapshot().get("status", "")) == "succeeded"

func fail_raid(sequence: int, tick: int) -> bool:
	if not _active() or sequence <= _sequence: return false
	_sequence = sequence
	if not _event("zerkov.event.raid_failed", sequence, tick): return false
	return _refresh_snapshot()

func snapshot() -> Dictionary:
	if _native == null:
		return RaidProgressionValues.freeze({"status":"unavailable","resume_enabled":false})
	if _snapshot_cache.is_empty() and not _refresh_snapshot():
		return RaidProgressionValues.freeze({"status":"unavailable","resume_enabled":false,"host_failed":true})
	_snapshot_reuses += 1
	return _snapshot_cache

func work_counts() -> Dictionary:
	return RaidProgressionValues.freeze({
		"summary_reads": _summary_reads,
		"fact_updates": _fact_updates,
		"snapshot_reuses": _snapshot_reuses,
	})

func release() -> void:
	if _native != null:
		# RefCounted bridge needs no manual free; dispose last owning reference.
		_native = null
	_running = false
	_scope_key = ""
	_pending_requests = []
	_snapshot_cache = {}

func _request(node_id: String) -> Dictionary:
	for request_value in _pending_requests:
		var request := request_value as Dictionary
		if request.get("node_identifier") == node_id: return request
	return {}

func _ack(node_id: String, reward: bool) -> bool:
	var request := _request(node_id)
	if request.is_empty() or (reward and not _reward_authorized): return _reject(&"task_ack_without_authorization")
	var result: Dictionary = _native.call("acknowledge_task_request", String(request.get("request_identifier","")), "accepted", {"type":"none"})
	if result.get("ok") != true: return _reject(&"task_ack_rejected")
	return _refresh_snapshot()

func _event(provider: String, sequence: int, tick: int) -> bool:
	if _scope_key.is_empty(): return _reject(&"task_scope_missing")
	var result: Dictionary = _native.call("inject_task_event", {"provider_identifier":provider,
		"event_identifier":"zerkov.event.s"+str(sequence),"sequence":sequence,"amount":1,
		"scope_key":_scope_key,"value":{"type":"none"},"filters":[]})
	if result.get("ok") != true: return _reject(&"task_event_rejected")
	result = _native.call("step_task", tick)
	return true if result.get("ok") == true else _reject(&"task_advance_rejected")

func _active() -> bool:
	return _native != null and not _failed and _running

func _refresh_snapshot() -> bool:
	if _native == null:
		last_error = &"task_native_runtime_unavailable"
		_failed = true
		return false
	var native: Dictionary = _native.call("get_task_summary")
	_summary_reads += 1
	if native.is_empty():
		last_error = &"task_summary_unavailable"
		_failed = true
		return false
	_running = bool(native.get("running", false))
	_scope_key = String(native.get("scope_key", ""))
	_pending_requests = (native.get("pending_requests", []) as Array).duplicate(true)
	_pending_requests.make_read_only()
	_snapshot_cache = RaidProgressionValues.freeze({
		"task_id": SupplyRunGraph.task_id(_map_id),
		"raid_id": _raid,
		"status": String(native.get("status_name", "unavailable")),
		"native_revision": int(native.get("revision", 0)),
		"searched_crates": _seen_crates.size(),
		"holds_objective": _holds,
		"resume_enabled": false,
		"completion_token": _reward_authorized
			and native.get("terminal_outcome") == "success",
		"pending_requests": int(native.get("pending_request_count", 0)),
		"host_failed": _failed,
	})
	return true

func _reject(reason: StringName) -> bool:
	last_error = reason
	_failed = true
	if not _snapshot_cache.is_empty():
		var failed_snapshot := _snapshot_cache.duplicate(true)
		failed_snapshot["host_failed"] = true
		_snapshot_cache = RaidProgressionValues.freeze(failed_snapshot)
	return false
