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
	return _ack("accept", false)

func update_facts(holds_objective: bool) -> bool:
	if not _active(): return false
	_holds = holds_objective
	var result: Dictionary = _native.call("set_task_facts", {"facts":[{"provider_identifier":"zerkov.fact.inventory", "fact_identifier":"zerkov.fact.holds_supply", "value":{"type":"boolean","value":holds_objective}}]})
	return true if result.get("ok") == true else _reject(&"task_fact_rejected")

func crate_committed(crate_id: String, audit_sequence: int, tick: int) -> bool:
	if not _active() or audit_sequence <= _sequence or tick < 1: return _reject(&"task_event_order_invalid")
	_sequence = audit_sequence
	var index := SupplyRunGraph.crates_for(_map_id).find(crate_id)
	if index < 0: return _reject(&"task_crate_unknown")
	if _seen_crates.has(crate_id): return true
	if not _event("zerkov.event.crate_"+str(index), audit_sequence, tick): return false
	_seen_crates[crate_id] = true
	return true

func ready_to_extract() -> bool:
	return _active() and _holds and _seen_crates.size() == 3 and not _request("extract").is_empty()

## Completion authorization is backed by the canonical Road Gate outcome.
## RewardRequest means a completion token in this settlement, not invented money.
func extracted(road_gate: String) -> bool:
	if road_gate != SupplyRunGraph.exit_for(_map_id) or not ready_to_extract(): return _reject(&"task_extraction_ineligible")
	if not _ack("extract", false): return false
	_reward_authorized = true
	if not _ack("reward", true): return false
	return snapshot().status == "succeeded"

func fail_raid(sequence: int, tick: int) -> bool:
	if not _active() or sequence <= _sequence: return false
	_sequence = sequence
	return _event("zerkov.event.raid_failed", sequence, tick)

func snapshot() -> Dictionary:
	if _native == null: return RaidProgressionValues.freeze({"status":"unavailable","resume_enabled":false})
	var native: Dictionary = _native.call("get_task_summary")
	return RaidProgressionValues.freeze({"task_id":SupplyRunGraph.task_id(_map_id), "raid_id":_raid,
		"status":String(native.get("status_name","unavailable")), "native_revision":int(native.get("revision",0)),
		"searched_crates":_seen_crates.size(), "holds_objective":_holds, "resume_enabled":false,
		"completion_token":_reward_authorized and native.get("terminal_outcome")=="success",
		"pending_requests":int(native.get("pending_request_count",0)), "host_failed":_failed})

func release() -> void:
	if _native != null:
		# RefCounted bridge needs no manual free; dispose last owning reference.
		_native = null

func _request(node_id: String) -> Dictionary:
	var summary: Dictionary = _native.call("get_task_summary")
	for request: Dictionary in summary.get("pending_requests", []):
		if request.get("node_identifier") == node_id: return request
	return {}

func _ack(node_id: String, reward: bool) -> bool:
	var request := _request(node_id)
	if request.is_empty() or (reward and not _reward_authorized): return _reject(&"task_ack_without_authorization")
	var result: Dictionary = _native.call("acknowledge_task_request", String(request.get("request_identifier","")), "accepted", {"type":"none"})
	return true if result.get("ok") == true else _reject(&"task_ack_rejected")

func _event(provider: String, sequence: int, tick: int) -> bool:
	var summary: Dictionary = _native.call("get_task_summary")
	var result: Dictionary = _native.call("inject_task_event", {"provider_identifier":provider,
		"event_identifier":"zerkov.event.s"+str(sequence),"sequence":sequence,"amount":1,
		"scope_key":String(summary.scope_key),"value":{"type":"none"},"filters":[]})
	if result.get("ok") != true: return _reject(&"task_event_rejected")
	result = _native.call("step_task", tick)
	return true if result.get("ok") == true else _reject(&"task_advance_rejected")

func _active() -> bool:
	if _native == null or _failed: return false
	var summary: Dictionary = _native.call("get_task_summary")
	return summary.get("running",false)

func _reject(reason: StringName) -> bool:
	last_error = reason
	_failed = true
	return false
