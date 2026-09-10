class_name LtsGraphDebugModel
extends RefCounted

## Editor-only breakpoint and activity state for one task-graph simulator.
##
## The model owns no Resource and never mutates the supplied graph.  A caller
## may keep using the authored dictionary (or Resource projection) while this
## model accumulates breakpoints, trace records, and runtime observations.
## Breakpoints and activity are intentionally not part of the runtime
## fingerprint or any document command.

signal projection_changed(projection: Dictionary)
signal activity_changed(projection: Dictionary)
signal breakpoints_changed(breakpoints: Dictionary)
signal breakpoint_hit(kind: String, identifier: String, hit: Dictionary)
signal execution_changed(semantics: Dictionary)

const Logic := preload("res://addons/level_task_system/editor/simulation/lts_graph_debug_logic.gd")

const SCHEMA_VERSION := Logic.SCHEMA_VERSION
const BREAKPOINT_NODE := Logic.BREAKPOINT_NODE
const BREAKPOINT_EDGE := Logic.BREAKPOINT_EDGE
const RUN_MODE_RUNNING := Logic.RUN_MODE_RUNNING
const RUN_MODE_PAUSED := Logic.RUN_MODE_PAUSED
const RUN_MODE_STEP := Logic.RUN_MODE_STEP

var _graph_document: Dictionary = {}
var _graph_identifier := ""
var _breakpoints: Dictionary = {"node": {}, "edge": {}}
var _runtime_state: Dictionary = {}
var _trace_records: Array = []
var _execution_input: Dictionary = {}
var _execution_state: Dictionary = {
	"run_mode": RUN_MODE_PAUSED,
	"paused": true,
	"step_requested": false,
	"pause_reason": "",
}
var _projection: Dictionary = {}


func _init(graph_document: Dictionary = {}) -> void:
	if not graph_document.is_empty():
		set_graph_document(graph_document)
	else:
		_rebuild_projection()


func set_graph_document(graph_document: Dictionary, preserve_debug_state = true) -> Dictionary:
	## Copy the graph before retaining it.  This is the only graph value the
	## model sees, so debug metadata cannot leak into the authored document.
	var next_identifier := String(graph_document.get("identifier", "")).strip_edges()
	var changed_graph := next_identifier != _graph_identifier or _graph_document != graph_document
	_graph_document = graph_document.duplicate(true)
	_graph_identifier = next_identifier
	if changed_graph and not preserve_debug_state:
		_clear_debug_activity()
	if changed_graph and preserve_debug_state and not _graph_identifier.is_empty():
		# A breakpoint belongs to an open graph.  Breakpoints that point to a
		# different graph are not carried across a document switch.
		_prune_breakpoints_to_graph()
	_rebuild_projection()
	return get_projection()


func set_graph(graph_document: Dictionary, preserve_debug_state = true) -> Dictionary:
	return set_graph_document(graph_document, preserve_debug_state)


func open_graph(graph_document: Dictionary, preserve_debug_state = true) -> Dictionary:
	return set_graph_document(graph_document, preserve_debug_state)


func get_graph_document() -> Dictionary:
	return _graph_document.duplicate(true)


func authored_document() -> Dictionary:
	return get_graph_document()


func get_graph_identifier() -> String:
	return _graph_identifier


func has_graph() -> bool:
	return not _graph_document.is_empty()


func set_runtime_state(runtime_state: Dictionary) -> Dictionary:
	_runtime_state = runtime_state.duplicate(true)
	_rebuild_projection()
	return get_projection()


func update_runtime_state(runtime_state: Dictionary) -> Dictionary:
	return set_runtime_state(runtime_state)


func get_runtime_state() -> Dictionary:
	return _runtime_state.duplicate(true)


func set_trace_records(trace_records: Variant) -> Dictionary:
	_trace_records = _bounded_trace_copy(trace_records)
	_rebuild_projection()
	return get_projection()


func set_trace(trace_records: Variant) -> Dictionary:
	return set_trace_records(trace_records)


func get_trace_records() -> Array:
	return _trace_records.duplicate(true)


func append_trace_record(trace_record: Dictionary) -> Dictionary:
	if trace_record.is_empty():
		return get_projection()
	_trace_records.append(trace_record.duplicate(true))
	if _trace_records.size() > Logic.MAX_TRACE_RECORDS:
		_trace_records = _trace_records.slice(_trace_records.size() - Logic.MAX_TRACE_RECORDS)
	_rebuild_projection()
	return get_projection()


func append_trace(trace_record: Dictionary) -> Dictionary:
	return append_trace_record(trace_record)


func update_activity(
		runtime_state: Dictionary = {},
		trace_records: Variant = [],
		execution_input: Dictionary = {}) -> Dictionary:
	## Apply a read-only runtime result and project it for the canvas.  The
	## method intentionally copies both inputs before rebuilding.
	if not runtime_state.is_empty():
		_runtime_state = runtime_state.duplicate(true)
	if not (trace_records is Array and trace_records.is_empty()) and trace_records != null:
		_trace_records = _bounded_trace_copy(trace_records)
	if not execution_input.is_empty():
		_execution_input = execution_input.duplicate(true)
	_rebuild_projection()
	return get_projection()


func apply_activity(
		runtime_state: Dictionary = {},
		trace_records: Variant = [],
		execution_input: Dictionary = {}) -> Dictionary:
	return update_activity(runtime_state, trace_records, execution_input)


func project_activity(
		runtime_state: Dictionary = {},
		trace_records: Variant = [],
		execution_input: Dictionary = {}) -> Dictionary:
	return update_activity(runtime_state, trace_records, execution_input)


func refresh() -> Dictionary:
	_rebuild_projection()
	return get_projection()


func get_projection() -> Dictionary:
	return _projection.duplicate(true)


func get_activity_projection() -> Dictionary:
	return get_projection()


func activity_projection() -> Dictionary:
	return get_projection()


func get_node_activity(node_identifier: String) -> Dictionary:
	var activity: Dictionary = _projection.get("node_activity", {})
	return activity.get(node_identifier, {}).duplicate(true)


func node_activity(node_identifier: String) -> Dictionary:
	return get_node_activity(node_identifier)


func get_edge_activity(edge_identifier: String) -> Dictionary:
	var activity: Dictionary = _projection.get("edge_activity", {})
	return activity.get(edge_identifier, {}).duplicate(true)


func edge_activity(edge_identifier: String) -> Dictionary:
	return get_edge_activity(edge_identifier)


func set_breakpoint(first: Variant, second: Variant = true, third: Variant = "node") -> Dictionary:
	## Supports both ergonomic forms:
	##   set_breakpoint("node_1", true, "node")
	##   set_breakpoint("node", "node_1", true)
	var parsed := _parse_breakpoint_arguments(first, second, third)
	if not bool(parsed.get("ok", false)):
		return parsed
	var kind := String(parsed.get("kind", BREAKPOINT_NODE))
	var identifier := String(parsed.get("identifier", ""))
	var enabled := bool(parsed.get("enabled", true))
	var bucket: Dictionary = _breakpoints.get(kind, {})
	if enabled:
		bucket[identifier] = true
	else:
		bucket.erase(identifier)
	_breakpoints[kind] = bucket
	_prune_breakpoints_to_limit()
	_rebuild_projection()
	breakpoints_changed.emit(get_breakpoints())
	return {
		"ok": true,
		"kind": kind,
		"identifier": identifier,
		"enabled": enabled,
		"breakpoints": get_breakpoints(),
	}


func add_breakpoint(identifier: String, kind: String = BREAKPOINT_NODE) -> Dictionary:
	return set_breakpoint(identifier, true, kind)


func add_node_breakpoint(identifier: String) -> Dictionary:
	return set_breakpoint(identifier, true, BREAKPOINT_NODE)


func add_edge_breakpoint(identifier: String) -> Dictionary:
	return set_breakpoint(identifier, true, BREAKPOINT_EDGE)


func set_node_breakpoint(identifier: String, enabled = true) -> Dictionary:
	return set_breakpoint(identifier, enabled, BREAKPOINT_NODE)


func set_edge_breakpoint(identifier: String, enabled = true) -> Dictionary:
	return set_breakpoint(identifier, enabled, BREAKPOINT_EDGE)


func toggle_breakpoint(first: Variant, second: Variant = BREAKPOINT_NODE) -> Dictionary:
	var parsed := _parse_kind_identifier(first, second)
	if not bool(parsed.get("ok", false)):
		return parsed
	var kind := String(parsed["kind"])
	var identifier := String(parsed["identifier"])
	return set_breakpoint(kind, identifier, not has_breakpoint(identifier, kind))


func toggle_node_breakpoint(identifier: String) -> Dictionary:
	return toggle_breakpoint(identifier, BREAKPOINT_NODE)


func toggle_edge_breakpoint(identifier: String) -> Dictionary:
	return toggle_breakpoint(identifier, BREAKPOINT_EDGE)


func clear_breakpoint(first: Variant, second: Variant = BREAKPOINT_NODE) -> Dictionary:
	var parsed := _parse_kind_identifier(first, second)
	if not bool(parsed.get("ok", false)):
		return parsed
	return set_breakpoint(String(parsed["kind"]), String(parsed["identifier"]), false)


func remove_breakpoint(first: Variant, second: Variant = BREAKPOINT_NODE) -> Dictionary:
	return clear_breakpoint(first, second)


func clear_breakpoints(kind: String = "") -> Dictionary:
	var normalized := Logic.canonical_breakpoint_kind(kind)
	if kind.is_empty():
		_breakpoints = {BREAKPOINT_NODE: {}, BREAKPOINT_EDGE: {}}
	elif not normalized.is_empty():
		_breakpoints[normalized] = {}
	else:
		return _failure("LTS-GRAPH-DEBUG-001", "Unknown breakpoint kind", "debug.breakpoints")
	_rebuild_projection()
	breakpoints_changed.emit(get_breakpoints())
	return {"ok": true, "breakpoints": get_breakpoints()}


func set_breakpoints(value: Variant) -> Dictionary:
	var normalized := Logic.normalize_breakpoints(value)
	_breakpoints = {
		"nodes": Logic._array_to_set(normalized.get("nodes", [])),
		"edges": Logic._array_to_set(normalized.get("edges", [])),
	}
	_prune_breakpoints_to_limit()
	_rebuild_projection()
	breakpoints_changed.emit(get_breakpoints())
	return {"ok": true, "breakpoints": get_breakpoints()}


func get_breakpoints() -> Dictionary:
	return Logic.normalize_breakpoints(_breakpoints)


func breakpoints() -> Dictionary:
	return get_breakpoints()


func get_breakpoint_identifiers(kind: String = BREAKPOINT_NODE) -> Array:
	var normalized := Logic.canonical_breakpoint_kind(kind)
	if normalized.is_empty():
		return []
	return get_breakpoints().get("nodes" if normalized == BREAKPOINT_NODE else "edges", []).duplicate()


func has_breakpoint(first: Variant, second: Variant = BREAKPOINT_NODE) -> bool:
	var parsed := _parse_kind_identifier(first, second)
	if not bool(parsed.get("ok", false)):
		return false
	var bucket: Dictionary = _breakpoints.get(String(parsed["kind"]), {})
	return bucket.has(String(parsed["identifier"]))


func is_breakpoint(first: Variant, second: Variant = BREAKPOINT_NODE) -> bool:
	return has_breakpoint(first, second)


func get_breakpoint_hits() -> Array:
	return Array(_projection.get("breakpoint_hits", [])).duplicate(true)


func clear_breakpoint_hits() -> Dictionary:
	# Hits are derived from trace records.  Clearing them also clears the
	# observed trace so a future event can stop at the breakpoint again.
	_trace_records.clear()
	_projection["breakpoint_hits"] = []
	_rebuild_projection()
	return get_projection()


func set_execution_input(execution_input: Dictionary) -> Dictionary:
	_execution_input = execution_input.duplicate(true)
	_update_execution_state()
	_rebuild_projection()
	return get_execution_semantics()


func get_execution_input() -> Dictionary:
	return _execution_input.duplicate(true)


func get_execution_semantics() -> Dictionary:
	return _projection.get("execution", _execution_state).duplicate(true)


func execution_semantics() -> Dictionary:
	return get_execution_semantics()


func set_paused(paused: bool, reason: String = "") -> Dictionary:
	_execution_input["paused"] = paused
	_execution_input["run_mode"] = RUN_MODE_PAUSED if paused else RUN_MODE_RUNNING
	_execution_input["pause_reason"] = reason if paused else ""
	_execution_input["step_requested"] = false
	_update_execution_state()
	_rebuild_projection()
	return get_execution_semantics()


func pause(reason: String = "user") -> Dictionary:
	return set_paused(true, reason)


func request_pause(reason: String = "user") -> Dictionary:
	_execution_input["pause_requested"] = true
	_execution_input["pause_reason"] = reason
	return set_paused(true, reason)


func resume() -> Dictionary:
	_execution_input["resume_requested"] = true
	_execution_input["pause_requested"] = false
	_execution_input["step_requested"] = false
	_execution_input["run_mode"] = RUN_MODE_RUNNING
	_execution_input["paused"] = false
	_update_execution_state()
	_rebuild_projection()
	return get_execution_semantics()


func run() -> Dictionary:
	return resume()


func request_run() -> Dictionary:
	return resume()


func is_paused() -> bool:
	return bool(_execution_state.get("paused", true))


func is_running() -> bool:
	return not is_paused() and String(_execution_state.get("run_mode", "")) == RUN_MODE_RUNNING


func request_step() -> Dictionary:
	_execution_input["step_requested"] = true
	_execution_input["run_mode"] = RUN_MODE_STEP
	_execution_input["paused"] = true
	_execution_input["pause_reason"] = "step"
	_update_execution_state()
	_rebuild_projection()
	return get_execution_semantics()


func step() -> Dictionary:
	return request_step()


func begin_step() -> Dictionary:
	return request_step()


func consume_step_request() -> bool:
	var requested := bool(_execution_input.get("step_requested", false))
	_execution_input["step_requested"] = false
	if requested:
		_execution_state["step_requested"] = false
		_execution_state["paused"] = true
		_execution_state["run_mode"] = RUN_MODE_PAUSED
		_execution_state["pause_reason"] = "step_complete"
		_rebuild_projection()
	return requested


func complete_step() -> Dictionary:
	consume_step_request()
	return get_execution_semantics()


func end_step() -> Dictionary:
	return complete_step()


func can_advance(execution_input: Dictionary = {}) -> bool:
	return bool(_evaluate_execution(execution_input).get("can_advance", false))


func should_advance(execution_input: Dictionary = {}) -> bool:
	return can_advance(execution_input)


func may_advance(execution_input: Dictionary = {}) -> bool:
	return can_advance(execution_input)


func should_pause(execution_input: Dictionary = {}) -> bool:
	return not can_advance(execution_input)


func reset(clear_editor_breakpoints = false) -> Dictionary:
	_runtime_state = {}
	_trace_records.clear()
	_execution_input = {}
	_execution_state = {
		"run_mode": RUN_MODE_PAUSED,
		"paused": true,
		"step_requested": false,
		"pause_reason": "reset",
	}
	if clear_editor_breakpoints:
		_breakpoints = {BREAKPOINT_NODE: {}, BREAKPOINT_EDGE: {}}
	_rebuild_projection()
	return get_projection()


func reset_activity() -> Dictionary:
	return reset(false)


func get_debug_snapshot() -> Dictionary:
	## This is intentionally debug-only data.  It contains no graph definition
	## and is not suitable as a runtime save or canonical Resource projection.
	return {
		"schema_version": SCHEMA_VERSION,
		"graph_identifier": _graph_identifier,
		"breakpoints": get_breakpoints(),
		"runtime_state": _runtime_state.duplicate(true),
		"trace": _trace_records.duplicate(true),
		"execution": get_execution_semantics(),
		"projection": get_projection(),
		"persistable": false,
	}


func debug_snapshot() -> Dictionary:
	return get_debug_snapshot()


func is_authored_definition_unchanged(before: Dictionary) -> bool:
	return _graph_document == before


func _clear_debug_activity() -> void:
	_runtime_state = {}
	_trace_records.clear()
	_execution_input = {}
	_execution_state = {
		"run_mode": RUN_MODE_PAUSED,
		"paused": true,
		"step_requested": false,
		"pause_reason": "",
	}


func _rebuild_projection() -> void:
	_update_execution_state()
	var input := _execution_input.duplicate(true)
	input.merge({
		"run_mode": _execution_state.get("run_mode", RUN_MODE_PAUSED),
		"paused": _execution_state.get("paused", true),
		"step_requested": _execution_state.get("step_requested", false),
		"pause_reason": _execution_state.get("pause_reason", ""),
	}, false)
	_projection = Logic.project(_graph_document, _runtime_state, _trace_records, get_breakpoints(), input)
	var execution: Dictionary = _projection.get("execution", {})
	_execution_state.merge(execution, true)
	# A breakpoint is an observation of a committed trace.  It pauses the
	# simulator for the next advance but never changes the runtime result.
	if not Array(_projection.get("breakpoint_hits", [])).is_empty():
		_execution_state["paused"] = true
		_execution_state["run_mode"] = RUN_MODE_PAUSED
		_execution_state["pause_reason"] = "breakpoint"
		_execution_state["step_requested"] = false
		_projection["execution"] = Logic.step_semantics({
			"paused": true,
			"run_mode": RUN_MODE_PAUSED,
			"pause_reason": "breakpoint",
			"breakpoint_hit": true,
			"breakpoint_identifier": String(_projection["breakpoint_hits"][0].get("identifier", "")),
		})
	projection_changed.emit(get_projection())
	activity_changed.emit(get_projection())
	for hit in _projection.get("breakpoint_hits", []):
		if hit is Dictionary:
			breakpoint_hit.emit(String(hit.get("kind", "")), String(hit.get("identifier", "")), hit.duplicate(true))


func _update_execution_state() -> void:
	var current := _execution_state.duplicate(true)
	var semantics := Logic.step_semantics(_execution_input, current)
	_execution_state.merge(semantics, true)
	# A consumed one-shot request is retained only until the caller commits the
	# corresponding runtime advance.  The model itself does not mutate runtime.


func _evaluate_execution(extra: Dictionary = {}) -> Dictionary:
	var input := _execution_input.duplicate(true)
	input.merge(extra, true)
	return Logic.step_semantics(input, _execution_state)


func _parse_breakpoint_arguments(first: Variant, second: Variant, third: Variant) -> Dictionary:
	var first_kind := Logic.canonical_breakpoint_kind(first)
	var second_kind := Logic.canonical_breakpoint_kind(second)
	var kind := ""
	var identifier := ""
	var enabled := true
	if not first_kind.is_empty():
		kind = first_kind
		identifier = String(second).strip_edges()
		enabled = bool(third)
	else:
		identifier = String(first).strip_edges()
		if not second_kind.is_empty():
			kind = second_kind
			enabled = bool(third)
		else:
			kind = Logic.canonical_breakpoint_kind(third)
			enabled = bool(second)
	if kind.is_empty():
		return _failure("LTS-GRAPH-DEBUG-002", "Breakpoint kind must be node or edge", "debug.breakpoints")
	if identifier.is_empty():
		return _failure("LTS-GRAPH-DEBUG-003", "Breakpoint identifier is required", "debug.breakpoints.%s" % kind)
	return {"ok": true, "kind": kind, "identifier": identifier, "enabled": enabled}


func _parse_kind_identifier(first: Variant, second: Variant) -> Dictionary:
	var first_kind := Logic.canonical_breakpoint_kind(first)
	var second_kind := Logic.canonical_breakpoint_kind(second)
	var kind := first_kind if not first_kind.is_empty() else second_kind
	var identifier := String(second if not first_kind.is_empty() else first).strip_edges()
	if kind.is_empty():
		return _failure("LTS-GRAPH-DEBUG-002", "Breakpoint kind must be node or edge", "debug.breakpoints")
	if identifier.is_empty():
		return _failure("LTS-GRAPH-DEBUG-003", "Breakpoint identifier is required", "debug.breakpoints.%s" % kind)
	return {"ok": true, "kind": kind, "identifier": identifier}


func _prune_breakpoints_to_graph() -> void:
	var node_ids: Dictionary = {}
	var edge_ids: Dictionary = {}
	for node in _graph_document.get("nodes", []):
		if node is Dictionary:
			node_ids[String(node.get("identifier", ""))] = true
	for edge in _graph_document.get("edges", []):
		if edge is Dictionary:
			edge_ids[String(edge.get("identifier", ""))] = true
	for raw_identifier in _breakpoints.get(BREAKPOINT_NODE, {}).keys():
		if not node_ids.has(String(raw_identifier)):
			_breakpoints[BREAKPOINT_NODE].erase(raw_identifier)
	for raw_identifier in _breakpoints.get(BREAKPOINT_EDGE, {}).keys():
		if not edge_ids.has(String(raw_identifier)):
			_breakpoints[BREAKPOINT_EDGE].erase(raw_identifier)


func _prune_breakpoints_to_limit() -> void:
	var all: Array = []
	for kind in [BREAKPOINT_NODE, BREAKPOINT_EDGE]:
		for raw_identifier in _breakpoints.get(kind, {}).keys():
			all.append({"kind": kind, "identifier": String(raw_identifier)})
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return "%s|%s" % [a.get("kind", ""), a.get("identifier", "")] < "%s|%s" % [b.get("kind", ""), b.get("identifier", "")]
	)
	if all.size() <= Logic.MAX_BREAKPOINTS:
		return
	for item in all.slice(Logic.MAX_BREAKPOINTS):
		_breakpoints[String(item["kind"])].erase(String(item["identifier"]))


func _bounded_trace_copy(value: Variant) -> Array:
	var source: Variant = value
	if source is Dictionary:
		if source.has("trace"):
			source = source.get("trace", [])
		elif source.has("records"):
			source = source.get("records", [])
		else:
			source = []
	var result: Array = []
	if source is Array:
		for record in source:
			if record is Dictionary:
				result.append(record.duplicate(true))
	if result.size() > Logic.MAX_TRACE_RECORDS:
		result = result.slice(result.size() - Logic.MAX_TRACE_RECORDS)
	return result


func _failure(code: String, message: String, path: String) -> Dictionary:
	return {
		"ok": false,
		"error": {"code": code, "message": message, "path": path},
	}
