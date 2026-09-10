class_name LtsGraphDebugLogic
extends RefCounted

## Pure, editor-only projections used by the task-graph simulator.
##
## Runtime records are deliberately accepted as dictionaries.  The native
## runtime and the GDScript simulator can therefore share this seam without
## giving the editor a reference to an authority object.  All values returned
## by this file are newly allocated projections; the authored graph is never
## annotated with debug state.

const SCHEMA_VERSION := 1
const MAX_TRACE_RECORDS := 1024
const MAX_BREAKPOINTS := 512

const BREAKPOINT_NODE := "node"
const BREAKPOINT_EDGE := "edge"

const STATE_INACTIVE := "inactive"
const STATE_ACTIVE := "active"
const STATE_PENDING := "pending"
const STATE_COMPLETED := "completed"
const STATE_FAILED := "failed"
const STATE_UNKNOWN := "unknown"

const EDGE_INACTIVE := "inactive"
const EDGE_PENDING := "pending"
const EDGE_TRAVERSED := "traversed"
const EDGE_UNKNOWN := "unknown"

const RUN_MODE_RUNNING := "running"
const RUN_MODE_PAUSED := "paused"
const RUN_MODE_STEP := "step"

const STATE_LABELS := {
	STATE_INACTIVE: "Inactive",
	STATE_ACTIVE: "Active",
	STATE_PENDING: "Pending",
	STATE_COMPLETED: "Completed",
	STATE_FAILED: "Failed",
	STATE_UNKNOWN: "Unknown",
	EDGE_TRAVERSED: "Traversed",
}

# These are stable editor fallback roles, not a source of runtime identity.
# Consumers may replace the visual value with the active Godot editor theme;
# the role, label, and glyph remain deterministic in headless tests.
const STATE_COLOR_HEX := {
	STATE_INACTIVE: "#697586",
	STATE_ACTIVE: "#2f80ed",
	STATE_PENDING: "#c77700",
	STATE_COMPLETED: "#2f9e44",
	STATE_FAILED: "#d64550",
	STATE_UNKNOWN: "#697586",
	EDGE_TRAVERSED: "#2f80ed",
	BREAKPOINT_NODE: "#9b51e0",
	BREAKPOINT_EDGE: "#9b51e0",
}

const STATE_GLYPHS := {
	STATE_INACTIVE: "○",
	STATE_ACTIVE: "●",
	STATE_PENDING: "◌",
	STATE_COMPLETED: "✓",
	STATE_FAILED: "×",
	STATE_UNKNOWN: "?",
}

const EDGE_STATE_GLYPHS := {
	EDGE_INACTIVE: "→",
	EDGE_PENDING: "⇢",
	EDGE_TRAVERSED: "✓",
	EDGE_UNKNOWN: "?",
}

const TRACE_EVENT_ACCEPTED := "event_accepted"
const TRACE_FACT_SNAPSHOT_ACCEPTED := "fact_snapshot_accepted"
const TRACE_NODE_ACTIVATED := "node_activated"
const TRACE_NODE_COUNTER_CHANGED := "node_counter_changed"
const TRACE_NODE_COMPLETED := "node_completed"
const TRACE_EDGE_TRAVERSED := "edge_traversed"
const TRACE_REQUEST_EMITTED := "request_emitted"
const TRACE_REQUEST_RESOLVED := "request_resolved"
const TRACE_REQUEST_DUPLICATE := "request_duplicate"
const TRACE_GRAPH_STATUS_CHANGED := "graph_status_changed"
const TRACE_UNKNOWN := "unknown"

const TRACE_KIND_BY_INT := {
	1: TRACE_EVENT_ACCEPTED,
	2: TRACE_FACT_SNAPSHOT_ACCEPTED,
	3: TRACE_NODE_ACTIVATED,
	4: TRACE_NODE_COUNTER_CHANGED,
	5: TRACE_NODE_COMPLETED,
	6: TRACE_EDGE_TRAVERSED,
	7: TRACE_REQUEST_EMITTED,
	8: TRACE_REQUEST_RESOLVED,
	9: TRACE_REQUEST_DUPLICATE,
	10: TRACE_GRAPH_STATUS_CHANGED,
}

const NODE_STATE_BY_INT := {
	0: STATE_INACTIVE,
	1: STATE_ACTIVE,
	2: STATE_PENDING,
	3: STATE_COMPLETED,
	4: STATE_FAILED,
}

const GRAPH_STATUS_BY_INT := {
	0: "invalid",
	1: RUN_MODE_RUNNING,
	2: "succeeded",
	3: STATE_FAILED,
	4: "cancelled",
	5: "stalled",
}


static func canonical_breakpoint_kind(value: Variant) -> String:
	var text := str(value).strip_edges().to_lower()
	match text:
		"node", "nodes", "task_node":
			return BREAKPOINT_NODE
		"edge", "edges", "connection", "connections":
			return BREAKPOINT_EDGE
		_:
			return ""


static func breakpoint_kind(value: Variant) -> String:
	return canonical_breakpoint_kind(value)


static func canonical_node_state(value: Variant) -> String:
	if value is StringName:
		value = String(value)
	if value is String:
		var text := String(value).strip_edges().to_lower()
		match text:
			"inactive", "idle", "not_started", "not-started", "0":
				return STATE_INACTIVE
			"active", "running", "1":
				return STATE_ACTIVE
			"pending", "waiting", "blocked", "2":
				return STATE_PENDING
			"completed", "complete", "done", "success", "3":
				return STATE_COMPLETED
			"failed", "failure", "error", "4":
				return STATE_FAILED
			"":
				return STATE_UNKNOWN
			_:
				return STATE_UNKNOWN
	if value is int or value is float:
		return String(NODE_STATE_BY_INT.get(int(value), STATE_UNKNOWN))
	return STATE_UNKNOWN


static func node_state(value: Variant) -> String:
	return canonical_node_state(value)


static func canonical_edge_state(value: Variant) -> String:
	if value is StringName:
		value = String(value)
	if value is String:
		var text := String(value).strip_edges().to_lower()
		match text:
			"inactive", "idle", "0":
				return EDGE_INACTIVE
			"pending", "waiting", "1":
				return EDGE_PENDING
			"traversed", "active", "completed", "complete", "hit", "2":
				return EDGE_TRAVERSED
			"":
				return EDGE_UNKNOWN
			_:
				return EDGE_UNKNOWN
	if value is int or value is float:
		return String({0: EDGE_INACTIVE, 1: EDGE_PENDING, 2: EDGE_TRAVERSED}.get(int(value), EDGE_UNKNOWN))
	return EDGE_UNKNOWN


static func canonical_graph_status(value: Variant) -> String:
	if value is StringName:
		value = String(value)
	if value is String:
		var text := String(value).strip_edges().to_lower()
		match text:
			"invalid", "0":
				return "invalid"
			"running", "active", "1":
				return RUN_MODE_RUNNING
			"succeeded", "success", "completed", "2":
				return "succeeded"
			"failed", "failure", "error", "3":
				return STATE_FAILED
			"cancelled", "canceled", "4":
				return "cancelled"
			"stalled", "5":
				return "stalled"
			"":
				return ""
			_:
				return text
	if value is int or value is float:
		return String(GRAPH_STATUS_BY_INT.get(int(value), ""))
	return ""


static func canonical_trace_kind(value: Variant) -> String:
	if value is StringName:
		value = String(value)
	if value is int or value is float:
		return String(TRACE_KIND_BY_INT.get(int(value), TRACE_UNKNOWN))
	var text := String(value).strip_edges().to_lower()
	text = text.replace("-", "_").replace(" ", "_")
	if text.begins_with("task_trace_kind_"):
		text = text.trim_prefix("task_trace_kind_")
	var aliases := {
		"eventaccepted": TRACE_EVENT_ACCEPTED,
		"factsnapshotaccepted": TRACE_FACT_SNAPSHOT_ACCEPTED,
		"nodeactivated": TRACE_NODE_ACTIVATED,
		"nodecounterchanged": TRACE_NODE_COUNTER_CHANGED,
		"nodecompleted": TRACE_NODE_COMPLETED,
		"edgetraversed": TRACE_EDGE_TRAVERSED,
		"requestemitted": TRACE_REQUEST_EMITTED,
		"requestresolved": TRACE_REQUEST_RESOLVED,
		"requestduplicate": TRACE_REQUEST_DUPLICATE,
		"graphstatuschanged": TRACE_GRAPH_STATUS_CHANGED,
	}
	if aliases.has(text):
		return aliases[text]
	return text if not text.is_empty() else TRACE_UNKNOWN


static func trace_kind(value: Variant) -> String:
	return canonical_trace_kind(value)


static func state_label(value: Variant) -> String:
	var state := canonical_node_state(value)
	if String(value) == EDGE_TRAVERSED:
		state = EDGE_TRAVERSED
	return String(STATE_LABELS.get(state, STATE_LABELS[STATE_UNKNOWN]))


static func edge_state_label(value: Variant) -> String:
	var state := canonical_edge_state(value)
	return String(STATE_LABELS.get(state, STATE_LABELS[STATE_UNKNOWN]))


static func state_glyph(value: Variant, edge: bool = false) -> String:
	var state := canonical_edge_state(value) if edge else canonical_node_state(value)
	var glyphs: Dictionary = EDGE_STATE_GLYPHS if edge else STATE_GLYPHS
	return String(glyphs.get(state, glyphs[EDGE_UNKNOWN] if edge else glyphs[STATE_UNKNOWN]))


static func state_color_hex(value: Variant, edge: bool = false, is_breakpoint: bool = false) -> String:
	if is_breakpoint:
		return String(STATE_COLOR_HEX.get(BREAKPOINT_EDGE if edge else BREAKPOINT_NODE, "#9b51e0"))
	var state := canonical_edge_state(value) if edge else canonical_node_state(value)
	return String(STATE_COLOR_HEX.get(state, STATE_COLOR_HEX[STATE_UNKNOWN]))


static func state_color(value: Variant, edge: bool = false, is_breakpoint: bool = false) -> Color:
	return Color(state_color_hex(value, edge, is_breakpoint))


static func colors() -> Dictionary:
	return STATE_COLOR_HEX.duplicate(true)


static func labels() -> Dictionary:
	return STATE_LABELS.duplicate(true)


static func glyphs() -> Dictionary:
	return STATE_GLYPHS.duplicate(true)


static func normalize_breakpoints(value: Variant) -> Dictionary:
	var nodes: Dictionary = {}
	var edges: Dictionary = {}
	var source: Variant = value
	if source is Dictionary and source.has("breakpoints"):
		source = source.get("breakpoints", {})
	if source is Dictionary:
		_collect_breakpoint_values(nodes, source.get("nodes", source.get("node", [])))
		_collect_breakpoint_values(edges, source.get("edges", source.get("edge", [])))
		# A map of element ID -> kind is also convenient for serialized editor
		# settings.  Explicit nodes/edges above take precedence.
		for raw_key in source.keys():
			var key := String(raw_key)
			if key in ["nodes", "node", "edges", "edge"]:
				continue
			var raw_kind = source[raw_key]
			var kind := canonical_breakpoint_kind(raw_kind)
			if kind == BREAKPOINT_NODE:
				nodes[key] = true
			elif kind == BREAKPOINT_EDGE:
				edges[key] = true
	elif source is Array:
		for item in source:
			if item is Dictionary:
				var identifier := String(item.get("identifier", item.get("element_identifier", ""))).strip_edges()
				var kind := canonical_breakpoint_kind(item.get("kind", item.get("element_kind", BREAKPOINT_NODE)))
				if identifier.is_empty() or kind.is_empty() or not bool(item.get("enabled", true)):
					continue
				if kind == BREAKPOINT_NODE:
					nodes[identifier] = true
				else:
					edges[identifier] = true
			elif item is String or item is StringName:
				nodes[String(item)] = true
	return {
		"nodes": _sorted_identifiers(nodes.keys()),
		"edges": _sorted_identifiers(edges.keys()),
	}


static func _collect_breakpoint_values(target: Dictionary, value: Variant) -> void:
	if value is Array or value is PackedStringArray:
		for item in value:
			if item is Dictionary:
				var identifier := String(item.get("identifier", item.get("element_identifier", ""))).strip_edges()
				if not identifier.is_empty() and bool(item.get("enabled", true)):
					target[identifier] = true
			elif item is String or item is StringName:
				var identifier := String(item).strip_edges()
				if not identifier.is_empty():
					target[identifier] = true
	elif value is Dictionary:
		for raw_key in value.keys():
			var identifier := String(raw_key).strip_edges()
			if not identifier.is_empty() and bool(value[raw_key]):
				target[identifier] = true
	elif value is String or value is StringName:
		var identifier := String(value).strip_edges()
		if not identifier.is_empty():
			target[identifier] = true


static func _sorted_identifiers(values: Array) -> Array:
	var result: Array = []
	for value in values:
		var identifier := String(value).strip_edges()
		if not identifier.is_empty() and not result.has(identifier):
			result.append(identifier)
	result.sort()
	return result


static func step_semantics(execution_input: Dictionary = {}, current_state: Dictionary = {}) -> Dictionary:
	## Decide whether the simulator may perform one production-runtime advance.
	## This function has no side effects.  A single step is granted only for the
	## current call and asks the caller to pause again after the commit.
	var merged: Dictionary = current_state.duplicate(true)
	merged.merge(execution_input, true)
	var mode := _normalize_run_mode(merged.get("run_mode", merged.get("mode", "")))
	var paused := bool(merged.get("paused", mode == RUN_MODE_PAUSED))
	var step_requested := bool(merged.get("step_requested", merged.get("request_step", false)))
	var pause_requested := bool(merged.get("pause_requested", false))
	var resume_requested := bool(merged.get("resume_requested", merged.get("request_resume", false)))
	var breakpoint_hit := bool(merged.get("breakpoint_hit", merged.get("hit_breakpoint", false)))
	var breakpoint_identifier := String(merged.get("breakpoint_identifier", ""))
	var reason := String(merged.get("pause_reason", ""))

	if resume_requested:
		paused = false
		mode = RUN_MODE_RUNNING
		reason = ""
	if pause_requested:
		paused = true
		mode = RUN_MODE_PAUSED
		reason = "pause_requested"
	if breakpoint_hit:
		paused = true
		mode = RUN_MODE_PAUSED
		reason = "breakpoint" if breakpoint_identifier.is_empty() else "breakpoint:%s" % breakpoint_identifier

	var advance := false
	var pause_after := false
	var state_text := "Paused"
	if breakpoint_hit:
		advance = false
		state_text = "Paused at breakpoint"
	elif mode == RUN_MODE_RUNNING and not paused:
		advance = true
		state_text = "Running"
	elif step_requested:
		advance = true
		pause_after = true
		state_text = "Step ready"
		mode = RUN_MODE_STEP
		paused = true
	else:
		paused = true
		mode = RUN_MODE_PAUSED
		state_text = "Paused"

	return {
		"schema_version": SCHEMA_VERSION,
		"run_mode": mode,
		"mode": mode,
		"paused": paused,
		"advance": advance,
		"can_advance": advance,
		"should_advance": advance,
		"pause_before": not advance,
		"pause_after": pause_after,
		"step_requested": step_requested,
		"consume_step": advance and step_requested,
		"breakpoint_hit": breakpoint_hit,
		"breakpoint_identifier": breakpoint_identifier,
		"pause_reason": reason,
		"state": "paused" if paused else "running",
		"label": state_text,
		"text": state_text,
		"glyph": "Ⅱ" if paused else "▶",
	}


static func evaluate_step(execution_input: Dictionary = {}, current_state: Dictionary = {}) -> Dictionary:
	return step_semantics(execution_input, current_state)


static func _normalize_run_mode(value: Variant) -> String:
	var text := String(value).strip_edges().to_lower()
	match text:
		"run", "running", "play", "playing":
			return RUN_MODE_RUNNING
		"step", "stepping", "single_step", "single-step":
			return RUN_MODE_STEP
		"pause", "paused", "stop", "stopped", "":
			return RUN_MODE_PAUSED
		_:
			return RUN_MODE_PAUSED


static func project(
		graph_document: Dictionary,
		runtime_state: Dictionary = {},
		trace_records: Variant = [],
		breakpoints: Variant = {},
		execution_input: Dictionary = {}) -> Dictionary:
	## Build a deterministic activity projection from graph + read-only records.
	var node_by_identifier: Dictionary = {}
	for raw_node in graph_document.get("nodes", []):
		if not raw_node is Dictionary:
			continue
		var node_identifier := String(raw_node.get("identifier", "")).strip_edges()
		if not node_identifier.is_empty() and not node_by_identifier.has(node_identifier):
			node_by_identifier[node_identifier] = raw_node.duplicate(true)

	var edge_by_identifier: Dictionary = {}
	var edge_by_endpoints: Dictionary = {}
	for raw_edge in graph_document.get("edges", []):
		if not raw_edge is Dictionary:
			continue
		var edge_identifier := String(raw_edge.get("identifier", "")).strip_edges()
		if edge_identifier.is_empty() or edge_by_identifier.has(edge_identifier):
			continue
		var edge: Dictionary = raw_edge.duplicate(true)
		edge_by_identifier[edge_identifier] = edge
		var endpoint_key := _endpoint_key(edge.get("from_node_identifier", ""), edge.get("from_port_identifier", ""), edge.get("to_node_identifier", ""), edge.get("to_port_identifier", ""))
		if not edge_by_endpoints.has(endpoint_key):
			edge_by_endpoints[endpoint_key] = edge_identifier

	var normalized_breakpoints := normalize_breakpoints(breakpoints)
	var node_breakpoints: Dictionary = _array_to_set(normalized_breakpoints.get("nodes", []))
	var edge_breakpoints: Dictionary = _array_to_set(normalized_breakpoints.get("edges", []))
	var node_activity: Dictionary = {}
	var edge_activity: Dictionary = {}
	for raw_identifier in _sorted_identifiers(node_by_identifier.keys()):
		var identifier := String(raw_identifier)
		node_activity[identifier] = _new_node_activity(identifier, node_by_identifier[identifier], node_breakpoints.has(identifier))
	for raw_identifier in _sorted_identifiers(edge_by_identifier.keys()):
		var identifier := String(raw_identifier)
		edge_activity[identifier] = _new_edge_activity(identifier, edge_by_identifier[identifier], edge_breakpoints.has(identifier))

	var graph_status := canonical_graph_status(runtime_state.get("graph_status", runtime_state.get("status", "")))
	if graph_status.is_empty():
		graph_status = RUN_MODE_RUNNING
	var runtime_nodes := _runtime_node_records(runtime_state)
	for raw_identifier in runtime_nodes.keys():
		var identifier := String(raw_identifier)
		if not node_activity.has(identifier):
			continue
		_apply_node_record(node_activity[identifier], runtime_nodes[raw_identifier])
	_apply_identifier_state_list(node_activity, runtime_state.get("active_node_identifiers", runtime_state.get("active_nodes", [])), STATE_ACTIVE)
	_apply_identifier_state_list(node_activity, runtime_state.get("pending_node_identifiers", runtime_state.get("pending_nodes", [])), STATE_PENDING)
	_apply_identifier_state_list(node_activity, runtime_state.get("completed_node_identifiers", runtime_state.get("completed_nodes", [])), STATE_COMPLETED)
	_apply_identifier_state_list(node_activity, runtime_state.get("failed_node_identifiers", runtime_state.get("failed_nodes", [])), STATE_FAILED)
	_apply_pending_requests(node_activity, runtime_state.get("pending_requests", []))
	var breakpoint_hits: Array = []
	var hit_keys: Dictionary = {}

	var records := _normalize_records(trace_records)
	# A runtime result often carries transitions next to its trace array.
	var transition_records: Array = _as_array(runtime_state.get("transitions", runtime_state.get("transition_records", [])))
	for raw_transition in transition_records:
		if raw_transition is Dictionary:
			_apply_transition(edge_activity, edge_by_identifier, edge_by_endpoints, raw_transition, node_activity)
			var transition_nodes: Array = []
			var transition_from := String(raw_transition.get("from_node_identifier", "")).strip_edges()
			var transition_to := String(raw_transition.get("to_node_identifier", "")).strip_edges()
			if node_breakpoints.has(transition_from) and node_activity.has(transition_from):
				transition_nodes.append(transition_from)
			if node_breakpoints.has(transition_to) and node_activity.has(transition_to):
				transition_nodes.append(transition_to)
			for transition_node in transition_nodes:
				var transition_node_key: String = BREAKPOINT_NODE + ":" + String(transition_node)
				if hit_keys.has(transition_node_key):
					continue
				hit_keys[transition_node_key] = true
				breakpoint_hits.append(_breakpoint_hit(BREAKPOINT_NODE, String(transition_node), raw_transition, 0))
				node_activity[String(transition_node)]["breakpoint_hit"] = true
			for transition_edge in _edges_for_transition(raw_transition, edge_by_identifier, edge_by_endpoints):
				if not edge_breakpoints.has(transition_edge) or not edge_activity.has(transition_edge):
					continue
				var transition_edge_key: String = BREAKPOINT_EDGE + ":" + String(transition_edge)
				if hit_keys.has(transition_edge_key):
					continue
				hit_keys[transition_edge_key] = true
				breakpoint_hits.append(_breakpoint_hit(BREAKPOINT_EDGE, String(transition_edge), raw_transition, 0))
				edge_activity[String(transition_edge)]["breakpoint_hit"] = true
	for wrapped in records:
		var record: Dictionary = wrapped.get("record", {})
		var kind := canonical_trace_kind(record.get("kind", record.get("trace_kind", record.get("type", ""))))
		var node_identifier := String(record.get("node_identifier", record.get("node_id", ""))).strip_edges()
		var edge_identifier := String(record.get("edge_identifier", record.get("edge_id", ""))).strip_edges()
		if record.has("transition") and record.get("transition") is Dictionary:
			var nested_transition: Dictionary = record.get("transition")
			_apply_transition(edge_activity, edge_by_identifier, edge_by_endpoints, nested_transition, node_activity)
			if edge_identifier.is_empty():
				edge_identifier = String(nested_transition.get("edge_identifier", ""))
		if not node_identifier.is_empty() and node_activity.has(node_identifier):
			_apply_trace_to_node(node_activity[node_identifier], record, kind)
		if kind == TRACE_EDGE_TRAVERSED or not edge_identifier.is_empty():
			var matched_edges := _edges_for_trace(edge_identifier, record, edge_by_identifier, edge_by_endpoints)
			for matched_identifier in matched_edges:
				if edge_activity.has(matched_identifier):
					_apply_trace_to_edge(edge_activity[matched_identifier], record, kind)
		if kind == TRACE_GRAPH_STATUS_CHANGED:
			var traced_status := canonical_graph_status(record.get("graph_status", record.get("status", "")))
			if not traced_status.is_empty():
				graph_status = traced_status
		# Breakpoint evaluation is based only on touched stable IDs, never on
		# wall-clock time or object identity.
		var touched_nodes: Array = []
		if not node_identifier.is_empty() and node_activity.has(node_identifier):
			touched_nodes.append(node_identifier)
		var touched_edges := _edges_for_trace(edge_identifier, record, edge_by_identifier, edge_by_endpoints)
		for touched_node in touched_nodes:
			if node_breakpoints.has(touched_node):
				var node_key: String = BREAKPOINT_NODE + ":" + String(touched_node)
				if not hit_keys.has(node_key):
					hit_keys[node_key] = true
					breakpoint_hits.append(_breakpoint_hit(BREAKPOINT_NODE, touched_node, record, wrapped.get("index", 0)))
					node_activity[touched_node]["breakpoint_hit"] = true
		for touched_edge in touched_edges:
			if edge_breakpoints.has(touched_edge):
				var edge_key: String = BREAKPOINT_EDGE + ":" + String(touched_edge)
				if not hit_keys.has(edge_key):
					hit_keys[edge_key] = true
					breakpoint_hits.append(_breakpoint_hit(BREAKPOINT_EDGE, touched_edge, record, wrapped.get("index", 0)))
					edge_activity[touched_edge]["breakpoint_hit"] = true

	for raw_identifier in node_activity.keys():
		_finalize_node_activity(node_activity[raw_identifier], execution_input)
	for raw_identifier in edge_activity.keys():
		_finalize_edge_activity(edge_activity[raw_identifier], execution_input)
	breakpoint_hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%012d|%012d|%s|%s" % [int(a.get("revision", 0)), int(a.get("ordinal", 0)), String(a.get("kind", "")), String(a.get("identifier", ""))]
		var b_key := "%012d|%012d|%s|%s" % [int(b.get("revision", 0)), int(b.get("ordinal", 0)), String(b.get("kind", "")), String(b.get("identifier", ""))]
		return a_key < b_key
	)

	var semantics_input := execution_input.duplicate(true)
	if not breakpoint_hits.is_empty():
		semantics_input["breakpoint_hit"] = true
		semantics_input["breakpoint_identifier"] = String(breakpoint_hits[0].get("identifier", ""))
	var execution := step_semantics(semantics_input)
	var node_array: Array = []
	for raw_identifier in _sorted_identifiers(node_activity.keys()):
		node_array.append(node_activity[raw_identifier].duplicate(true))
	var edge_array: Array = []
	for raw_identifier in _sorted_identifiers(edge_activity.keys()):
		edge_array.append(edge_activity[raw_identifier].duplicate(true))
	var trace_truncated := records.size() > MAX_TRACE_RECORDS
	if trace_truncated:
		records = records.slice(records.size() - MAX_TRACE_RECORDS)
	var plain_trace: Array = []
	for wrapped in records:
		plain_trace.append(wrapped.get("record", {}).duplicate(true))
	return {
		"schema_version": SCHEMA_VERSION,
		"graph_identifier": String(graph_document.get("identifier", "")),
		"graph_status": graph_status,
		"nodes": node_array,
		"edges": edge_array,
		"node_activity": _copy_map(node_activity),
		"edge_activity": _copy_map(edge_activity),
		"activity": {"nodes": _copy_map(node_activity), "edges": _copy_map(edge_activity)},
		"breakpoints": normalized_breakpoints,
		"breakpoint_hits": breakpoint_hits.duplicate(true),
		"execution": execution,
		"trace": plain_trace,
		"trace_count": plain_trace.size(),
		"trace_truncated": trace_truncated,
		"deterministic": true,
	}


static func project_activity(
		graph_document: Dictionary,
		runtime_state: Dictionary = {},
		trace_records: Variant = [],
		breakpoints: Variant = {},
		execution_input: Dictionary = {}) -> Dictionary:
	return project(graph_document, runtime_state, trace_records, breakpoints, execution_input)


static func _new_node_activity(identifier: String, node: Dictionary, is_breakpoint: bool = false) -> Dictionary:
	var state := STATE_INACTIVE
	return {
		"identifier": identifier,
		"kind": int(node.get("kind", 0)),
		"state": state,
		"display_state": state,
		"label": state_label(state),
		"state_label": state_label(state),
		"status_text": state_label(state),
		"text": state_label(state),
		"activity_text": state_label(state),
		"glyph": state_glyph(state),
		"color": state_color(state),
		"color_hex": state_color_hex(state),
		"color_role": state,
		"amount": 0.0,
		"active": false,
		"pending": false,
		"completed": false,
		"failed": false,
		"counter": 0,
		"target": maxi(0, int(node.get("objective_target", node.get("target", 0)))),
		"request_identifier": "",
		"outcome_identifier": "",
		"last_revision": 0,
		"last_ordinal": 0,
		"event_count": 0,
		"trace_count": 0,
		"breakpoint": is_breakpoint,
		"breakpoint_hit": false,
		"marker": "Breakpoint armed" if is_breakpoint else "",
		"node": node.duplicate(true),
	}


static func _new_edge_activity(identifier: String, edge: Dictionary, is_breakpoint: bool = false) -> Dictionary:
	var state := EDGE_INACTIVE
	return {
		"identifier": identifier,
		"from_node_identifier": String(edge.get("from_node_identifier", "")),
		"from_port_identifier": String(edge.get("from_port_identifier", "")),
		"to_node_identifier": String(edge.get("to_node_identifier", "")),
		"to_port_identifier": String(edge.get("to_port_identifier", "")),
		"state": state,
		"display_state": state,
		"label": edge_state_label(state),
		"state_label": edge_state_label(state),
		"status_text": edge_state_label(state),
		"text": edge_state_label(state),
		"activity_text": edge_state_label(state),
		"glyph": state_glyph(state, true),
		"color": state_color(state, true),
		"color_hex": state_color_hex(state, true),
		"color_role": state,
		"amount": 0.0,
		"active": false,
		"pending": false,
		"traversed": false,
		"traversal_count": 0,
		"last_revision": 0,
		"last_ordinal": 0,
		"trace_count": 0,
		"breakpoint": is_breakpoint,
		"breakpoint_hit": false,
		"marker": "Breakpoint armed" if is_breakpoint else "",
		"edge": edge.duplicate(true),
	}


static func _runtime_node_records(runtime_state: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in ["node_states", "nodes", "node_activity"]:
		var source: Variant = runtime_state.get(key, null)
		if source is Dictionary:
			for raw_identifier in source.keys():
				var identifier := String(raw_identifier).strip_edges()
				if identifier.is_empty():
					continue
				var raw_value = source[raw_identifier]
				result[identifier] = _record_with_identifier(identifier, raw_value)
		elif source is Array:
			for raw_value in source:
				if not raw_value is Dictionary:
					continue
				var identifier := String(raw_value.get("node_identifier", raw_value.get("identifier", raw_value.get("node_id", "")))).strip_edges()
				if not identifier.is_empty():
					result[identifier] = raw_value.duplicate(true)
		if not result.is_empty():
			# node_states is authoritative when supplied; do not let an alias
			# overwrite it merely because it is iterated later.
			break
	return result


static func _record_with_identifier(identifier: String, raw_value: Variant) -> Dictionary:
	if raw_value is Dictionary:
		var record: Dictionary = raw_value.duplicate(true)
		record["node_identifier"] = String(record.get("node_identifier", identifier))
		return record
	return {"node_identifier": identifier, "state": raw_value}


static func _apply_identifier_state_list(activity: Dictionary, values: Variant, state: String) -> void:
	for raw_identifier in _as_array(values):
		var identifier := String(raw_identifier.get("identifier", raw_identifier) if raw_identifier is Dictionary else raw_identifier).strip_edges()
		if activity.has(identifier):
			_apply_node_state(activity[identifier], state)


static func _apply_pending_requests(activity: Dictionary, values: Variant) -> void:
	for raw_request in _as_array(values):
		if not raw_request is Dictionary:
			continue
		var identifier := String(raw_request.get("node_identifier", "")).strip_edges()
		if activity.has(identifier):
			_apply_node_state(activity[identifier], STATE_PENDING)
			activity[identifier]["request_identifier"] = String(raw_request.get("request_identifier", raw_request.get("identifier", "")))


static func _apply_node_record(activity: Dictionary, record: Dictionary) -> void:
	var state_value = record.get("state", record.get("current_state", record.get("status", "")))
	var state := canonical_node_state(state_value)
	if state != STATE_UNKNOWN:
		_apply_node_state(activity, state)
	if record.has("counter"):
		activity["counter"] = maxi(0, int(record.get("counter", 0)))
	elif record.has("current_counter"):
		activity["counter"] = maxi(0, int(record.get("current_counter", 0)))
	if record.has("target") or record.has("objective_target"):
		activity["target"] = maxi(0, int(record.get("target", record.get("objective_target", 0))))
	for key in ["request_identifier", "outcome_identifier"]:
		if record.has(key):
			activity[key] = String(record.get(key, ""))
	if record.has("revision"):
		activity["last_revision"] = int(record.get("revision", 0))
	if record.has("ordinal"):
		activity["last_ordinal"] = int(record.get("ordinal", 0))
	_finalize_node_amount(activity)


static func _apply_trace_to_node(activity: Dictionary, record: Dictionary, kind: String) -> void:
	var state_value = record.get("current_state", record.get("state", ""))
	var state := canonical_node_state(state_value)
	# Native trace structs carry an INACTIVE default in current_state for edge,
	# request, and graph records. Infer the event's semantic state first so a
	# default field cannot erase a more useful runtime projection.
	match kind:
		TRACE_NODE_ACTIVATED:
			_apply_node_state(activity, state if state not in [STATE_UNKNOWN, STATE_INACTIVE] else STATE_ACTIVE)
		TRACE_REQUEST_EMITTED:
			_apply_node_state(activity, state if state not in [STATE_UNKNOWN, STATE_INACTIVE] else STATE_PENDING)
		TRACE_NODE_COMPLETED:
			_apply_node_state(activity, state if state not in [STATE_UNKNOWN, STATE_INACTIVE] else STATE_COMPLETED)
		TRACE_REQUEST_RESOLVED:
			if state not in [STATE_UNKNOWN, STATE_INACTIVE]:
				_apply_node_state(activity, state)
			else:
				var resolution := str(record.get("resolution", record.get("result", "acknowledged"))).to_lower()
				_apply_node_state(activity, STATE_FAILED if resolution in ["rejected", "timed_out", "timeout", "failed"] else STATE_COMPLETED)
		TRACE_NODE_COUNTER_CHANGED:
			if state not in [STATE_UNKNOWN, STATE_INACTIVE]:
				_apply_node_state(activity, state)
		TRACE_REQUEST_DUPLICATE:
			# A duplicate acknowledgement is observation-only; preserve the
			# node's existing state while retaining the request identity.
			pass
		_:
			# Event, edge, and graph records do not own node state transitions.
			pass
	if kind == TRACE_NODE_COUNTER_CHANGED:
		if record.has("current_counter"):
			activity["counter"] = maxi(0, int(record.get("current_counter", 0)))
		elif record.has("counter"):
			activity["counter"] = maxi(0, int(record.get("counter", 0)))
		else:
			activity["counter"] = maxi(0, int(activity.get("counter", 0)) + maxi(1, int(record.get("amount", 1))))
		activity["event_count"] = int(activity.get("event_count", 0)) + 1
	if kind == TRACE_EVENT_ACCEPTED:
		activity["event_count"] = int(activity.get("event_count", 0)) + 1
	for key in ["request_identifier", "outcome_identifier"]:
		if record.has(key):
			activity[key] = String(record.get(key, ""))
	if record.has("revision"):
		activity["last_revision"] = int(record.get("revision", 0))
	if record.has("ordinal"):
		activity["last_ordinal"] = int(record.get("ordinal", 0))
	activity["trace_count"] = int(activity.get("trace_count", 0)) + 1
	_finalize_node_amount(activity)


static func _apply_node_state(activity: Dictionary, state: String) -> void:
	activity["state"] = state
	activity["display_state"] = state
	activity["label"] = state_label(state)
	activity["state_label"] = state_label(state)
	activity["status_text"] = state_label(state)
	activity["text"] = state_label(state)
	activity["activity_text"] = state_label(state)
	activity["glyph"] = state_glyph(state)
	activity["color"] = state_color(state)
	activity["color_hex"] = state_color_hex(state)
	activity["color_role"] = state
	activity["amount"] = 1.0 if state in [STATE_ACTIVE, STATE_PENDING, STATE_COMPLETED, STATE_FAILED] else 0.0
	activity["active"] = state == STATE_ACTIVE
	activity["pending"] = state == STATE_PENDING
	activity["completed"] = state == STATE_COMPLETED
	activity["failed"] = state == STATE_FAILED


static func _finalize_node_amount(activity: Dictionary) -> void:
	var state := String(activity.get("state", STATE_UNKNOWN))
	var target := int(activity.get("target", 0))
	var counter := maxi(0, int(activity.get("counter", 0)))
	if target > 0:
		activity["amount"] = clampf(float(counter) / float(target), 0.0, 1.0)
	elif state in [STATE_ACTIVE, STATE_PENDING, STATE_COMPLETED, STATE_FAILED]:
		activity["amount"] = 1.0
	else:
		activity["amount"] = 0.0


static func _apply_transition(edge_activity: Dictionary, edge_by_identifier: Dictionary, edge_by_endpoints: Dictionary, transition: Dictionary, node_activity: Dictionary) -> void:
	var matched := _edges_for_transition(transition, edge_by_identifier, edge_by_endpoints)
	for edge_identifier in matched:
		if edge_activity.has(edge_identifier):
			_apply_trace_to_edge(edge_activity[edge_identifier], transition, TRACE_EDGE_TRAVERSED)
	var from_identifier := String(transition.get("from_node_identifier", ""))
	var to_identifier := String(transition.get("to_node_identifier", ""))
	if node_activity.has(from_identifier):
		node_activity[from_identifier]["last_revision"] = int(transition.get("revision", node_activity[from_identifier].get("last_revision", 0)))
	if node_activity.has(to_identifier) and String(node_activity[to_identifier].get("state", STATE_INACTIVE)) == STATE_INACTIVE:
		_apply_node_state(node_activity[to_identifier], STATE_ACTIVE)


static func _edges_for_transition(transition: Dictionary, edge_by_identifier: Dictionary, edge_by_endpoints: Dictionary) -> Array:
	var edge_identifier := String(transition.get("edge_identifier", transition.get("identifier", ""))).strip_edges()
	if not edge_identifier.is_empty() and edge_by_identifier.has(edge_identifier):
		return [edge_identifier]
	var endpoint_key := _endpoint_key(
		transition.get("from_node_identifier", ""),
		transition.get("output_port_identifier", transition.get("from_port_identifier", "")),
		transition.get("to_node_identifier", ""),
		transition.get("to_port_identifier", ""))
	return [edge_by_endpoints[endpoint_key]] if edge_by_endpoints.has(endpoint_key) else []


static func _apply_trace_to_edge(activity: Dictionary, record: Dictionary, kind: String) -> void:
	var state := canonical_edge_state(record.get("current_state", record.get("state", "")))
	if state == EDGE_UNKNOWN or (kind == TRACE_EDGE_TRAVERSED and state == EDGE_INACTIVE):
		state = EDGE_TRAVERSED if kind == TRACE_EDGE_TRAVERSED else EDGE_PENDING
	activity["state"] = state
	activity["display_state"] = state
	activity["label"] = edge_state_label(state)
	activity["state_label"] = edge_state_label(state)
	activity["status_text"] = edge_state_label(state)
	activity["text"] = edge_state_label(state)
	activity["activity_text"] = edge_state_label(state)
	activity["glyph"] = state_glyph(state, true)
	activity["color"] = state_color(state, true)
	activity["color_hex"] = state_color_hex(state, true)
	activity["color_role"] = state
	activity["amount"] = 1.0 if state in [EDGE_PENDING, EDGE_TRAVERSED] else 0.0
	activity["active"] = state == EDGE_PENDING
	activity["pending"] = state == EDGE_PENDING
	activity["traversed"] = state == EDGE_TRAVERSED
	if state == EDGE_TRAVERSED:
		activity["traversal_count"] = int(activity.get("traversal_count", 0)) + 1
	if record.has("revision"):
		activity["last_revision"] = int(record.get("revision", 0))
	if record.has("ordinal"):
		activity["last_ordinal"] = int(record.get("ordinal", 0))
	activity["trace_count"] = int(activity.get("trace_count", 0)) + 1


static func _finalize_node_activity(activity: Dictionary, execution_input: Dictionary) -> void:
	_finalize_node_amount(activity)
	var execution := step_semantics(execution_input)
	activity["execution_state"] = String(execution.get("state", "paused"))
	activity["execution_label"] = String(execution.get("label", "Paused"))
	activity["paused"] = bool(execution.get("paused", true))
	activity["display_state"] = String(activity.get("state", STATE_UNKNOWN))
	activity["display_label"] = String(activity.get("label", "Unknown"))
	activity["display_text"] = String(activity.get("text", "Unknown"))
	activity["display_glyph"] = String(activity.get("glyph", "?"))
	if bool(execution.get("paused", true)) and String(activity.get("state", STATE_UNKNOWN)) in [STATE_ACTIVE, STATE_PENDING]:
		activity["display_state"] = "paused"
		activity["display_label"] = "Paused"
		activity["display_text"] = "Paused — %s" % String(activity.get("label", "Active"))
		activity["display_glyph"] = "Ⅱ"
	if bool(activity.get("breakpoint_hit", false)):
		activity["marker"] = "Breakpoint hit"
		activity["breakpoint_text"] = "Breakpoint hit"
		activity["status_text"] = "%s · Breakpoint hit" % String(activity.get("label", "Unknown"))
		activity["text"] = activity["status_text"]
		activity["color"] = state_color(activity.get("state", STATE_UNKNOWN), false, true)
		activity["color_hex"] = state_color_hex(activity.get("state", STATE_UNKNOWN), false, true)
		activity["color_role"] = BREAKPOINT_NODE


static func _finalize_edge_activity(activity: Dictionary, execution_input: Dictionary) -> void:
	var execution := step_semantics(execution_input)
	activity["execution_state"] = String(execution.get("state", "paused"))
	activity["execution_label"] = String(execution.get("label", "Paused"))
	activity["paused"] = bool(execution.get("paused", true))
	activity["display_state"] = String(activity.get("state", EDGE_UNKNOWN))
	activity["display_label"] = String(activity.get("label", "Unknown"))
	activity["display_text"] = String(activity.get("text", "Unknown"))
	activity["display_glyph"] = String(activity.get("glyph", "?"))
	if bool(execution.get("paused", true)) and String(activity.get("state", EDGE_UNKNOWN)) == EDGE_PENDING:
		activity["display_state"] = "paused"
		activity["display_label"] = "Paused"
		activity["display_text"] = "Paused — %s" % String(activity.get("label", "Pending"))
		activity["display_glyph"] = "Ⅱ"
	if bool(activity.get("breakpoint_hit", false)):
		activity["marker"] = "Breakpoint hit"
		activity["breakpoint_text"] = "Breakpoint hit"
		activity["status_text"] = "%s · Breakpoint hit" % String(activity.get("label", "Unknown"))
		activity["text"] = activity["status_text"]
		activity["color"] = state_color(activity.get("state", EDGE_UNKNOWN), true, true)
		activity["color_hex"] = state_color_hex(activity.get("state", EDGE_UNKNOWN), true, true)
		activity["color_role"] = BREAKPOINT_EDGE


static func _edges_for_trace(edge_identifier: String, record: Dictionary, edge_by_identifier: Dictionary, edge_by_endpoints: Dictionary) -> Array:
	if not edge_identifier.is_empty() and edge_by_identifier.has(edge_identifier):
		return [edge_identifier]
	var kind := canonical_trace_kind(record.get("kind", record.get("trace_kind", record.get("type", ""))))
	if kind != TRACE_EDGE_TRAVERSED and not record.has("from_node_identifier") and not record.has("to_node_identifier"):
		return []
	var from_identifier := String(record.get("from_node_identifier", record.get("node_identifier", "")))
	var to_identifier := String(record.get("to_node_identifier", ""))
	var from_port := String(record.get("from_port_identifier", record.get("output_port_identifier", record.get("outcome_identifier", ""))))
	var to_port := String(record.get("to_port_identifier", ""))
	if not to_identifier.is_empty():
		var endpoint_key := _endpoint_key(from_identifier, from_port, to_identifier, to_port)
		if edge_by_endpoints.has(endpoint_key):
			return [edge_by_endpoints[endpoint_key]]
	var result: Array = []
	for raw_identifier in _sorted_identifiers(edge_by_identifier.keys()):
		var edge: Dictionary = edge_by_identifier[raw_identifier]
		if String(edge.get("from_node_identifier", "")) != from_identifier:
			continue
		if not from_port.is_empty() and String(edge.get("from_port_identifier", "")) != from_port:
			continue
		result.append(String(raw_identifier))
	return result


static func _breakpoint_hit(kind: String, identifier: String, record: Dictionary, source_index: int) -> Dictionary:
	return {
		"kind": kind,
		"identifier": identifier,
		"revision": int(record.get("revision", 0)),
		"ordinal": int(record.get("ordinal", source_index)),
		"trace_kind": canonical_trace_kind(record.get("kind", record.get("trace_kind", record.get("type", "")))),
		"text": "Breakpoint hit: %s %s" % [kind.capitalize(), identifier],
		"label": "Breakpoint hit",
		"glyph": "●",
		"color": state_color(STATE_ACTIVE, false, true),
		"color_hex": STATE_COLOR_HEX[BREAKPOINT_NODE],
	}


static func _endpoint_key(from_node: Variant, from_port: Variant, to_node: Variant, to_port: Variant) -> String:
	return "%s|%s|%s|%s" % [String(from_node), String(from_port), String(to_node), String(to_port)]


static func _array_to_set(values: Variant) -> Dictionary:
	var result: Dictionary = {}
	for value in _as_array(values):
		var identifier := String(value).strip_edges()
		if not identifier.is_empty():
			result[identifier] = true
	return result


static func _normalize_records(value: Variant) -> Array:
	var source: Variant = value
	if source is Dictionary:
		if source.has("trace"):
			source = source.get("trace", [])
		elif source.has("records"):
			source = source.get("records", [])
		else:
			source = []
	var result: Array = []
	var index := 0
	for raw_record in _as_array(source):
		if raw_record is Dictionary:
			result.append({"record": raw_record.duplicate(true), "index": index})
		index += 1
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ar: Dictionary = a.get("record", {})
		var br: Dictionary = b.get("record", {})
		var a_revision := int(ar.get("revision", 0))
		var b_revision := int(br.get("revision", 0))
		if a_revision != b_revision:
			return a_revision < b_revision
		var a_ordinal := int(ar.get("ordinal", a.get("index", 0)))
		var b_ordinal := int(br.get("ordinal", b.get("index", 0)))
		if a_ordinal != b_ordinal:
			return a_ordinal < b_ordinal
		return int(a.get("index", 0)) < int(b.get("index", 0))
	)
	return result


static func _copy_map(value: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for raw_key in value.keys():
		result[String(raw_key)] = value[raw_key].duplicate(true) if value[raw_key] is Array or value[raw_key] is Dictionary else value[raw_key]
	return result


static func _as_array(value: Variant) -> Array:
	if value == null:
		return []
	if value is Array:
		return value
	if value is PackedStringArray:
		return Array(value)
	return []
