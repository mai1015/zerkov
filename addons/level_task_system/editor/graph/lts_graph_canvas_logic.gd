class_name LtsGraphCanvasLogic
extends RefCounted

## Editor-independent graph rules used by the task canvas.
##
## The canvas is a projection of LtsDocumentModel.  This helper deliberately
## contains no Control, GraphEdit, EditorInterface, Resource, or UndoRedo
## dependency, so quick-add filtering, port compatibility, cycle checks, and
## layout can be exercised in a headless process.

const PORT_INPUT := 0
const PORT_OUTPUT := 1

const VALUE_NONE := 0
const VALUE_BOOLEAN := 1
const VALUE_INTEGER := 2
const VALUE_FIXED := 3
const VALUE_STRING := 4
const VALUE_IDENTIFIER := 5
const VALUE_BYTES := 6

const CONNECTION_OK := ""
const CONNECTION_PORT_MISSING := "LTS-GRAPH-CONNECTION-PORT"
const CONNECTION_DIRECTION := "LTS-GRAPH-CONNECTION-DIRECTION"
const CONNECTION_TYPE := "LTS-GRAPH-CONNECTION-TYPE"
const CONNECTION_DUPLICATE := "LTS-GRAPH-CONNECTION-DUPLICATE"
const CONNECTION_INPUT_OCCUPIED := "LTS-GRAPH-CONNECTION-INPUT-OCCUPIED"
const CONNECTION_CYCLE := "LTS-GRAPH-CONNECTION-CYCLE"
const CONNECTION_NODE_MISSING := "LTS-GRAPH-CONNECTION-NODE"
const CONNECTION_GRAPH_MISSING := "LTS-GRAPH-CONNECTION-GRAPH"

const VALUE_TYPE_NAMES := {
	VALUE_NONE: "control",
	VALUE_BOOLEAN: "boolean",
	VALUE_INTEGER: "integer",
	VALUE_FIXED: "fixed",
	VALUE_STRING: "string",
	VALUE_IDENTIFIER: "identifier",
	VALUE_BYTES: "bytes",
}

# The resource-side enum is zero based (NODE_ENTRY = 0).  Keep this table in
# the same order as LevelTaskNodeDefinition::NodeKind so quick-add payloads
# can be passed directly to LtsDocumentCommand.add_task_node().
const NODE_FAMILIES := [
	{
		"identifier": "entry",
		"kind": 0,
		"category": "Flow",
		"label": "Entry",
		"summary": "Graph start; one entry output.",
		"search_terms": ["start", "begin", "flow"],
		"icons": [&"Play", &"ArrowRight", &"Node"],
		"ports": [
			{"identifier": "entry", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "objective",
		"kind": 1,
		"category": "Progress",
		"label": "Objective / event counter",
		"summary": "Count a bounded host event or fact.",
		"search_terms": ["event", "counter", "goal", "progress", "target"],
		"icons": [&"Target", &"Flag", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
			{"identifier": "success", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
		"fields": {"objective_target": 1},
	},
	{
		"identifier": "condition",
		"kind": 2,
		"category": "Logic",
		"label": "Condition branch",
		"summary": "Branch on a typed fact snapshot.",
		"search_terms": ["if", "branch", "split", "true", "false"],
		"icons": [&"Branch", &"Split", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
			{"identifier": "true", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
			{"identifier": "false", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "all_gate",
		"kind": 3,
		"category": "Logic",
		"label": "All gate",
		"summary": "Wait until every input outcome is complete.",
		"search_terms": ["all", "and", "join", "merge", "gate"],
		"icons": [&"Merge", &"Join", &"Node"],
		"ports": [
			{"identifier": "input_a", "direction": "IN", "value_type": VALUE_NONE, "required": false},
			{"identifier": "input_b", "direction": "IN", "value_type": VALUE_NONE, "required": false},
			{"identifier": "all", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "any_gate",
		"kind": 4,
		"category": "Logic",
		"label": "Any gate",
		"summary": "Continue on the first matching input outcome.",
		"search_terms": ["any", "or", "first", "join", "merge", "gate"],
		"icons": [&"Merge", &"Join", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": false},
			{"identifier": "any", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "external_action",
		"kind": 5,
		"category": "Integration",
		"label": "External action",
		"summary": "Emit a host request and await acknowledgement.",
		"search_terms": ["action", "request", "ack", "acknowledgement", "host"],
		"icons": [&"Link", &"Gear", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
			{"identifier": "accepted", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
			{"identifier": "rejected", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
			{"identifier": "timeout", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "conversation",
		"kind": 6,
		"category": "Integration",
		"label": "Conversation",
		"summary": "Await a named, render-neutral conversation outcome.",
		"search_terms": ["dialogue", "dialog", "talk", "speaker", "choice"],
		"icons": [&"Script", &"Chat", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
			{"identifier": "accepted", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
			{"identifier": "declined", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
		"fields": {"accepted_outcomes": ["accepted", "declined"]},
	},
	{
		"identifier": "subgraph",
		"kind": 7,
		"category": "Flow",
		"label": "Subgraph",
		"summary": "Enter another task graph by stable identifier.",
		"search_terms": ["instance", "nested", "graph", "branch", "open"],
		"icons": [&"Instance", &"Folder", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
			{"identifier": "success", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "reward_request",
		"kind": 8,
		"category": "Integration",
		"label": "Reward request",
		"summary": "Ask a host provider to grant a reward.",
		"search_terms": ["reward", "grant", "inventory", "claim", "provider"],
		"icons": [&"Add", &"Package", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
			{"identifier": "accepted", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
			{"identifier": "rejected", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
			{"identifier": "timeout", "direction": "OUT", "value_type": VALUE_NONE, "required": false},
		],
	},
	{
		"identifier": "success_terminal",
		"kind": 9,
		"category": "Terminals",
		"label": "Success terminal",
		"summary": "Finish the graph with a SUCCESS outcome.",
		"search_terms": ["success", "complete", "finish", "terminal", "done"],
		"icons": [&"Check", &"StatusSuccess", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
		],
		"fields": {"outcome_identifier": "success"},
		"terminal": true,
	},
	{
		"identifier": "failure_terminal",
		"kind": 10,
		"category": "Terminals",
		"label": "Failure terminal",
		"summary": "Finish the graph with a FAILURE outcome.",
		"search_terms": ["failure", "fail", "error", "terminal"],
		"icons": [&"Error", &"StatusError", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
		],
		"fields": {"outcome_identifier": "failure"},
		"terminal": true,
	},
	{
		"identifier": "cancelled_terminal",
		"kind": 11,
		"category": "Terminals",
		"label": "Cancelled terminal",
		"summary": "Finish the graph with a CANCELLED outcome.",
		"search_terms": ["cancel", "cancelled", "stop", "terminal"],
		"icons": [&"Stop", &"Cancel", &"Node"],
		"ports": [
			{"identifier": "input", "direction": "IN", "value_type": VALUE_NONE, "required": true},
		],
		"fields": {"outcome_identifier": "cancelled"},
		"terminal": true,
		},
]

const _FAMILY_ALIASES := {
	"entry": "entry",
	"start": "entry",
	"objective": "objective",
	"event": "objective",
	"event_counter": "objective",
	"condition": "condition",
	"branch": "condition",
	"all": "all_gate",
	"all_gate": "all_gate",
	"any": "any_gate",
	"any_gate": "any_gate",
	"external": "external_action",
	"external_action": "external_action",
	"action": "external_action",
	"conversation": "conversation",
	"dialogue": "conversation",
	"subgraph": "subgraph",
	"reward": "reward_request",
	"reward_request": "reward_request",
	"success": "success_terminal",
	"success_terminal": "success_terminal",
	"failure": "failure_terminal",
	"failure_terminal": "failure_terminal",
	"cancelled": "cancelled_terminal",
	"canceled": "cancelled_terminal",
	"cancelled_terminal": "cancelled_terminal",
}


static func family_catalog() -> Array:
	return NODE_FAMILIES.duplicate(true)


static func node_family_catalog() -> Array:
	return family_catalog()


static func families() -> Array:
	return family_catalog()


static func family_for_kind(kind: Variant) -> Dictionary:
	var identifier := _family_identifier(kind)
	for family in NODE_FAMILIES:
		if String(family.get("identifier", "")) == identifier:
			return family.duplicate(true)
	return {}


static func get_family(kind: Variant) -> Dictionary:
	return family_for_kind(kind)


static func family_for_node(node: Dictionary) -> Dictionary:
	if node.has("family"):
		var family := family_for_kind(node.get("family", ""))
		if not family.is_empty():
			return family
	if node.has("type"):
		var by_type := family_for_kind(node.get("type", ""))
		if not by_type.is_empty():
			return by_type
	return family_for_kind(node.get("kind", 0))


static func quick_add_items(query: String = "", source_port: Dictionary = {}, target_port: Dictionary = {}) -> Array:
	var needle := query.strip_edges().to_lower()
	var result: Array = []
	for family in NODE_FAMILIES:
		if not needle.is_empty() and not _family_matches(family, needle):
			continue
		if not source_port.is_empty() and not _family_accepts(family, source_port, true):
			continue
		if not target_port.is_empty() and not _family_accepts(family, target_port, false):
			continue
		result.append(family.duplicate(true))
	return result


static func get_quick_add_items(query: String = "", source_port: Dictionary = {}, target_port: Dictionary = {}) -> Array:
	return quick_add_items(query, source_port, target_port)


static func quick_add_model(query: String = "", source_port: Dictionary = {}, target_port: Dictionary = {}) -> Dictionary:
	var items := quick_add_items(query, source_port, target_port)
	var grouped: Dictionary = {}
	var category_order: Array = []
	for family in items:
		var category := String(family.get("category", "Other"))
		if not grouped.has(category):
			grouped[category] = []
			category_order.append(category)
		grouped[category].append(family)
	var categories: Array = []
	for category in category_order:
		categories.append({"identifier": category.to_lower().replace(" ", "_"), "label": category, "items": grouped[category].duplicate(true)})
	return {
		"query": query,
		"source_port": source_port.duplicate(true),
		"target_port": target_port.duplicate(true),
		"categories": categories,
		"items": items,
		"empty": items.is_empty(),
	}


static func build_quick_add_model(query: String = "", source_port: Dictionary = {}, target_port: Dictionary = {}) -> Dictionary:
	return quick_add_model(query, source_port, target_port)


static func port_definitions_for_family(kind: Variant) -> Array:
	var family := family_for_kind(kind)
	return family.get("ports", []).duplicate(true) if not family.is_empty() else []


static func ports_for_family(kind: Variant) -> Array:
	return port_definitions_for_family(kind)


static func make_node_payload(kind: Variant, identifier: String = "", overrides: Dictionary = {}) -> Dictionary:
	var family := family_for_kind(kind)
	if family.is_empty():
		return {}
	var node_identifier := identifier.strip_edges()
	if node_identifier.is_empty():
		node_identifier = String(family.get("identifier", "node"))
	var ports: Array = []
	for raw_port in family.get("ports", []):
		if not raw_port is Dictionary:
			continue
		var port := normalize_port(raw_port)
		ports.append({
			"identifier": String(port.get("identifier", "port")),
			"direction": PORT_INPUT if is_input_port(port) else PORT_OUTPUT,
			"value_type": int(port.get("value_type", VALUE_NONE)),
			"required": bool(port.get("required", false)),
		})
	var node := {
		"identifier": node_identifier,
		"schema_version": 1,
		"kind": int(family.get("kind", 0)),
		"ports": ports,
	}
	var fields: Dictionary = family.get("fields", {})
	for field_name in fields:
		node[String(field_name)] = fields[field_name].duplicate(true) if fields[field_name] is Array or fields[field_name] is Dictionary else fields[field_name]
	for key in overrides:
		if key == "ports":
			continue
		node[String(key)] = overrides[key].duplicate(true) if overrides[key] is Array or overrides[key] is Dictionary else overrides[key]
	return node


static func create_node_payload(kind: Variant, identifier: String = "", overrides: Dictionary = {}) -> Dictionary:
	return make_node_payload(kind, identifier, overrides)


static func unique_identifier(base: String, existing_identifiers: Variant = [], suffix: String = "") -> String:
	var candidate_base := base.strip_edges()
	if candidate_base.is_empty():
		candidate_base = "node"
	var used: Dictionary = {}
	if existing_identifiers is Dictionary:
		for key in existing_identifiers:
			used[String(key)] = true
	elif existing_identifiers is Array or existing_identifiers is PackedStringArray:
		for value in existing_identifiers:
			used[String(value)] = true
	if not used.has(candidate_base):
		return candidate_base
	var copy_suffix := suffix if not suffix.is_empty() else "_copy"
	var candidate := candidate_base + copy_suffix
	var index := 2
	while used.has(candidate):
		candidate = "%s%s_%d" % [candidate_base, copy_suffix, index]
		index += 1
	return candidate


static func make_edge_identifier(from_node: String, from_port: String, to_node: String, to_port: String, existing_identifiers: Variant = []) -> String:
	var base := "edge.%s.%s.%s.%s" % [from_node, from_port, to_node, to_port]
	return unique_identifier(base, existing_identifiers, "")


static func normalize_port(port: Dictionary) -> Dictionary:
	var result := port.duplicate(true)
	var identifier := String(result.get("identifier", result.get("name", result.get("id", "port"))))
	result["identifier"] = identifier
	result["name"] = String(result.get("name", identifier))
	result["direction"] = port_direction(result.get("direction", result.get("side", PORT_OUTPUT)))
	var value_type = result.get("value_type", result.get("type", VALUE_NONE))
	result["value_type"] = value_type_id(value_type)
	result["required"] = bool(result.get("required", false))
	return result


static func port_direction(direction: Variant) -> String:
	if direction is String or direction is StringName:
		var text := String(direction).strip_edges().to_lower()
		return "IN" if text in ["in", "input", "left"] else "OUT"
	# Resource enums use 0=input and 1=output.  2 is accepted for callers
	# handing us the engine-independent enum (INPUT=1, OUTPUT=2); an explicit
	# String is preferred whenever the two numeric domains are ambiguous.
	return "IN" if int(direction) == PORT_INPUT else "OUT"


static func is_input_port(port: Dictionary) -> bool:
	return port_direction(port.get("direction", PORT_OUTPUT)) == "IN"


static func is_output_port(port: Dictionary) -> bool:
	return not is_input_port(port)


static func value_type_id(value_type: Variant) -> int:
	if value_type is String or value_type is StringName:
		match String(value_type).strip_edges().to_lower():
			"none", "control", "outcome", "flow", "any", "wildcard":
				return VALUE_NONE
			"bool", "boolean":
				return VALUE_BOOLEAN
			"int", "integer", "event":
				return VALUE_INTEGER
			"fixed", "number":
				return VALUE_FIXED
			"string", "text":
				return VALUE_STRING
			"identifier", "id":
				return VALUE_IDENTIFIER
			"bytes", "blob":
				return VALUE_BYTES
			_:
				return VALUE_NONE
	return clampi(int(value_type), VALUE_NONE, VALUE_BYTES)


static func value_type_name(value_type: Variant) -> String:
	return String(VALUE_TYPE_NAMES.get(value_type_id(value_type), "control"))


static func type_name(value_type: Variant) -> String:
	return value_type_name(value_type)


static func port_compatibility(source_port: Dictionary, target_port: Dictionary) -> Dictionary:
	var source := normalize_port(source_port)
	var target := normalize_port(target_port)
	if source_port.is_empty() or target_port.is_empty() or String(source.get("identifier", "")).is_empty() or String(target.get("identifier", "")).is_empty():
		return _connection_feedback(false, CONNECTION_PORT_MISSING, "Both connection endpoints must be named ports.", source, target)
	if not is_output_port(source) or not is_input_port(target):
		return _connection_feedback(false, CONNECTION_DIRECTION, "Connections require an OUT port feeding an IN port.", source, target)
	var source_type := value_type_id(source.get("value_type", VALUE_NONE))
	var target_type := value_type_id(target.get("value_type", VALUE_NONE))
	if source_type != VALUE_NONE and target_type != VALUE_NONE and source_type != target_type:
		return _connection_feedback(false, CONNECTION_TYPE, "%s (%s) cannot feed %s (%s)." % [String(source.get("name", source.get("identifier", "source"))), value_type_name(source_type), String(target.get("name", target.get("identifier", "target"))), value_type_name(target_type)], source, target)
	return _connection_feedback(true, CONNECTION_OK, "Compatible: %s → %s." % [value_type_name(source_type), value_type_name(target_type)], source, target)


static func check_port_compatibility(source_port: Dictionary, target_port: Dictionary) -> Dictionary:
	return port_compatibility(source_port, target_port)


static func ports_compatible(source_port: Dictionary, target_port: Dictionary) -> bool:
	return bool(port_compatibility(source_port, target_port).get("compatible", false))


static func validate_connection(graph: Dictionary, from_node_identifier: String, from_port_identifier: String, to_node_identifier: String, to_port_identifier: String) -> Dictionary:
	if graph.is_empty():
		return _connection_feedback(false, CONNECTION_GRAPH_MISSING, "No task graph is open.")
	var nodes: Array = graph.get("nodes", []) if graph.get("nodes", []) is Array else []
	var from_node := _find_by_identifier(nodes, from_node_identifier)
	var to_node := _find_by_identifier(nodes, to_node_identifier)
	if from_node.is_empty() or to_node.is_empty():
		return _connection_feedback(false, CONNECTION_NODE_MISSING, "Connection endpoints must refer to nodes in the open graph.")
	var source_port := _find_port(from_node.get("ports", []), from_port_identifier)
	var target_port := _find_port(to_node.get("ports", []), to_port_identifier)
	var compatibility := port_compatibility(source_port, target_port)
	if not bool(compatibility.get("compatible", false)):
		compatibility["from_node_identifier"] = from_node_identifier
		compatibility["to_node_identifier"] = to_node_identifier
		return compatibility
	var edges: Array = graph.get("edges", []) if graph.get("edges", []) is Array else []
	for edge in edges:
		if not edge is Dictionary:
			continue
		if String(edge.get("from_node_identifier", "")) == from_node_identifier \
				and String(edge.get("from_port_identifier", "")) == from_port_identifier \
				and String(edge.get("to_node_identifier", "")) == to_node_identifier \
				and String(edge.get("to_port_identifier", "")) == to_port_identifier:
			return _connection_feedback(false, CONNECTION_DUPLICATE, "That named connection already exists.", source_port, target_port)
	var max_connections := int(target_port.get("max_connections", 1))
	if max_connections > 0:
		var connection_count := 0
		for edge in edges:
			if edge is Dictionary and String(edge.get("to_node_identifier", "")) == to_node_identifier and String(edge.get("to_port_identifier", "")) == to_port_identifier:
				connection_count += 1
		if connection_count >= max_connections and not bool(target_port.get("allow_multiple", false)):
			return _connection_feedback(false, CONNECTION_INPUT_OCCUPIED, "Input port '%s' already has its maximum connections." % String(target_port.get("name", to_port_identifier)), source_port, target_port)
	if would_create_cycle(graph, from_node_identifier, to_node_identifier):
		return _connection_feedback(false, CONNECTION_CYCLE, "This connection would create a cycle; task graphs are acyclic.", source_port, target_port)
	var result := _connection_feedback(true, CONNECTION_OK, "Compatible connection.", source_port, target_port)
	result["from_node_identifier"] = from_node_identifier
	result["from_port_identifier"] = from_port_identifier
	result["to_node_identifier"] = to_node_identifier
	result["to_port_identifier"] = to_port_identifier
	return result


static func check_connection(graph: Dictionary, from_node_identifier: String, from_port_identifier: String, to_node_identifier: String, to_port_identifier: String) -> Dictionary:
	return validate_connection(graph, from_node_identifier, from_port_identifier, to_node_identifier, to_port_identifier)


static func connection_feedback(graph: Dictionary, from_node_identifier: String, from_port_identifier: String, to_node_identifier: String, to_port_identifier: String) -> Dictionary:
	return validate_connection(graph, from_node_identifier, from_port_identifier, to_node_identifier, to_port_identifier)


static func would_create_cycle(graph: Dictionary, from_node_identifier: String, to_node_identifier: String) -> bool:
	if from_node_identifier == to_node_identifier:
		return true
	var adjacency: Dictionary = {}
	var nodes: Array = graph.get("nodes", []) if graph.get("nodes", []) is Array else []
	for node in nodes:
		if node is Dictionary:
			adjacency[String(node.get("identifier", ""))] = []
	var edges: Array = graph.get("edges", []) if graph.get("edges", []) is Array else []
	for edge in edges:
		if not edge is Dictionary:
			continue
		var source := String(edge.get("from_node_identifier", ""))
		var target := String(edge.get("to_node_identifier", ""))
		if not adjacency.has(source):
			adjacency[source] = []
		if not adjacency[source].has(target):
			adjacency[source].append(target)
	var pending: Array = [to_node_identifier]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var current := String(pending.pop_front())
		if current == from_node_identifier:
			return true
		if visited.has(current):
			continue
		visited[current] = true
		var next_nodes: Array = adjacency.get(current, [])
		for next in next_nodes:
			if not visited.has(String(next)):
				pending.append(String(next))
	return false


static func connection_would_cycle(graph: Dictionary, from_node_identifier: String, to_node_identifier: String) -> bool:
	return would_create_cycle(graph, from_node_identifier, to_node_identifier)


static func compatible_ports_for(source_port: Dictionary, graph: Dictionary, as_input: bool = true) -> Array:
	var result: Array = []
	var nodes: Array = graph.get("nodes", []) if graph.get("nodes", []) is Array else []
	for node in nodes:
		if not node is Dictionary:
			continue
		for raw_port in node.get("ports", []):
			if not raw_port is Dictionary:
				continue
			var port := normalize_port(raw_port)
			var compatible := port_compatibility(source_port, port) if as_input else port_compatibility(port, source_port)
			if bool(compatible.get("compatible", false)):
				result.append({"node_identifier": String(node.get("identifier", "")), "port": port.duplicate(true)})
	return result


static func deterministic_layout(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	var node_values: Array = graph.get("nodes", []) if graph.get("nodes", []) is Array else []
	var node_ids: Array = []
	var adjacency: Dictionary = {}
	var indegree: Dictionary = {}
	for raw_node in node_values:
		if not raw_node is Dictionary:
			continue
		var identifier := String(raw_node.get("identifier", ""))
		if identifier.is_empty() or adjacency.has(identifier):
			continue
		node_ids.append(identifier)
		adjacency[identifier] = []
		indegree[identifier] = 0
	for raw_edge in graph.get("edges", []):
		if not raw_edge is Dictionary:
			continue
		var source := String(raw_edge.get("from_node_identifier", ""))
		var target := String(raw_edge.get("to_node_identifier", ""))
		if not adjacency.has(source) or not adjacency.has(target) or adjacency[source].has(target):
			continue
		adjacency[source].append(target)
		indegree[target] = int(indegree.get(target, 0)) + 1
	for source in adjacency:
		adjacency[source].sort()
	node_ids.sort()
	var queue: Array = []
	for identifier in node_ids:
		if int(indegree.get(identifier, 0)) == 0:
			queue.append(identifier)
	queue.sort()
	var topo: Array = []
	var levels: Dictionary = {}
	for identifier in node_ids:
		levels[identifier] = 0
	while not queue.is_empty():
		var current := String(queue.pop_front())
		topo.append(current)
		for target in adjacency.get(current, []):
			levels[target] = maxi(int(levels.get(target, 0)), int(levels.get(current, 0)) + 1)
			indegree[target] = int(indegree[target]) - 1
			if int(indegree[target]) == 0:
				queue.append(String(target))
		queue.sort()
	# A malformed/cyclic document still gets a stable projection.  Native
	# validation remains responsible for reporting that cycle; this fallback
	# only prevents a layout operation from becoming nondeterministic.
	var remaining: Array = []
	for identifier in node_ids:
		if not topo.has(identifier):
			remaining.append(identifier)
	remaining.sort()
	for identifier in remaining:
		topo.append(identifier)
		levels[identifier] = int(levels.get(identifier, 0))
	var origin := _vector2_option(options.get("origin", Vector2(80, 80)), Vector2(80, 80))
	var horizontal_gap := float(options.get("horizontal_gap", options.get("column_gap", 280.0)))
	var vertical_gap := float(options.get("vertical_gap", options.get("row_gap", 150.0)))
	var row_by_level: Dictionary = {}
	for identifier in topo:
		var level := int(levels.get(identifier, 0))
		if not row_by_level.has(level):
			row_by_level[level] = []
		row_by_level[level].append(identifier)
	for level in row_by_level:
		row_by_level[level].sort()
	var positions: Dictionary = {}
	for level in row_by_level:
		var row: Array = row_by_level[level]
		for row_index in row.size():
			positions[String(row[row_index])] = origin + Vector2(float(level) * horizontal_gap, float(row_index) * vertical_gap)
	return {
		"positions": positions,
		"order": topo,
		"levels": levels,
		"origin": origin,
		"horizontal_gap": horizontal_gap,
		"vertical_gap": vertical_gap,
	}


static func calculate_layout(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	return deterministic_layout(graph, options)


static func layout_graph(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	return deterministic_layout(graph, options)


static func auto_arrange(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	var layout := deterministic_layout(graph, options)
	return serialize_positions(layout.get("positions", {}))


static func arrange_graph(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	return auto_arrange(graph, options)


static func layout_positions(graph: Dictionary, options: Dictionary = {}) -> Dictionary:
	return deterministic_layout(graph, options).get("positions", {}).duplicate(true)


static func serialize_positions(positions: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var keys := positions.keys()
	keys.sort()
	for identifier in keys:
		result[String(identifier)] = serialize_position(positions[identifier])
	return result


static func serialize_position(value: Variant) -> Variant:
	if value is Vector2:
		return [float(value.x), float(value.y)]
	if value is Vector2i:
		return [int(value.x), int(value.y)]
	if value is Array:
		return [float(value[0]), float(value[1])] if value.size() >= 2 else [0.0, 0.0]
	return [0.0, 0.0]


static func frame_rect_for_positions(positions: Dictionary, node_sizes: Dictionary = {}, options: Dictionary = {}) -> Rect2:
	if positions.is_empty():
		return Rect2()
	var padding := float(options.get("padding", 32.0))
	var default_size := _vector2_option(options.get("node_size", Vector2(220, 96)), Vector2(220, 96))
	var first := true
	var bounds := Rect2()
	for identifier in positions:
		var position := _vector2_option(positions[identifier], Vector2.ZERO)
		var size := _vector2_option(node_sizes.get(identifier, default_size), default_size)
		var rect := Rect2(position, size)
		if first:
			bounds = rect
			first = false
		else:
			bounds = bounds.merge(rect)
	return bounds.grow(padding)


static func frame_rect(graph: Dictionary, options: Dictionary = {}) -> Rect2:
	var layout := deterministic_layout(graph, options)
	return frame_rect_for_positions(layout.get("positions", {}), {}, options)


static func _connection_feedback(compatible: bool, code: String, reason: String, source: Dictionary = {}, target: Dictionary = {}) -> Dictionary:
	return {
		"ok": compatible,
		"compatible": compatible,
		"accepted": compatible,
		"code": code,
		"reason_code": code,
		"reason": reason,
		"message": reason,
		"source_port": source.duplicate(true),
		"target_port": target.duplicate(true),
		"validation_scope": "graph_canvas_local",
	}


static func _family_identifier(kind: Variant) -> String:
	if kind is String or kind is StringName:
		var candidate := String(kind).strip_edges().to_lower()
		if _FAMILY_ALIASES.has(candidate):
			return String(_FAMILY_ALIASES[candidate])
		for family in NODE_FAMILIES:
			if String(family.get("identifier", "")) == candidate:
				return candidate
		return candidate
	var kind_int := int(kind)
	for family in NODE_FAMILIES:
		if int(family.get("kind", -1)) == kind_int:
			return String(family.get("identifier", ""))
	return ""


static func _family_matches(family: Dictionary, needle: String) -> bool:
	for value in [family.get("identifier", ""), family.get("category", ""), family.get("label", ""), family.get("summary", "")]:
		if String(value).to_lower().find(needle) >= 0:
			return true
	for term in family.get("search_terms", []):
		if String(term).to_lower().find(needle) >= 0:
			return true
	return false


static func _family_accepts(family: Dictionary, context_port: Dictionary, context_is_source: bool) -> bool:
	var context := normalize_port(context_port)
	for raw_port in family.get("ports", []):
		if not raw_port is Dictionary:
			continue
		var candidate := normalize_port(raw_port)
		var result := port_compatibility(context, candidate) if context_is_source else port_compatibility(candidate, context)
		if bool(result.get("compatible", false)):
			return true
	return false


static func _find_by_identifier(values: Variant, identifier: String) -> Dictionary:
	if not values is Array:
		return {}
	for value in values:
		if value is Dictionary and String(value.get("identifier", "")) == identifier:
			return value.duplicate(true)
	return {}


static func _find_port(ports: Variant, identifier: String) -> Dictionary:
	if not ports is Array:
		return {}
	for value in ports:
		if value is Dictionary and String(value.get("identifier", value.get("name", ""))) == identifier:
			return value.duplicate(true)
	return {}


static func _vector2_option(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback
