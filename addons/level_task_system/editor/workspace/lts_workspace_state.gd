extends RefCounted

## Pure helpers for the Level Task System main-screen workspace.
##
## This seam deliberately contains no EditorInterface, Control, Resource, or
## native-extension dependency.  The main screen can therefore reuse the
## same deterministic projections in a headless smoke test and in the editor.

const KIND_LEVEL := "level"
const KIND_TASK_GRAPH := "task_graph"
const KIND_CONVERSATION := "conversation"
const KIND_SPEAKER := "speaker"
const KIND_PROVIDER := "provider"
const KIND_PROJECT := "project"
const KIND_SIMULATION := "simulation"
const KIND_DIAGNOSTICS := "diagnostics"

const COLLECTION_ORDER: PackedStringArray = [
	"levels", "task_graphs", "conversations", "speakers", "providers",
]

const COLLECTION_LABELS: Dictionary = {
	"levels": "Levels",
	"task_graphs": "Task Graphs",
	"conversations": "Conversations",
	"speakers": "Speakers",
	"providers": "Providers",
}

const KIND_FROM_COLLECTION: Dictionary = {
	"levels": KIND_LEVEL,
	"task_graphs": KIND_TASK_GRAPH,
	"conversations": KIND_CONVERSATION,
	"speakers": KIND_SPEAKER,
	"providers": KIND_PROVIDER,
}

const KIND_LABELS: Dictionary = {
	KIND_LEVEL: "Level",
	KIND_TASK_GRAPH: "Task graph",
	KIND_CONVERSATION: "Conversation",
	KIND_SPEAKER: "Speaker",
	KIND_PROVIDER: "Provider",
}

const KIND_CLASS_NAMES: Dictionary = {
	KIND_LEVEL: ["LevelTaskLevelDefinition", "LevelDefinition"],
	KIND_TASK_GRAPH: ["LevelTaskGraphDefinition", "TaskGraphDefinition"],
	KIND_CONVERSATION: ["LevelTaskConversationDefinition", "ConversationDefinition"],
	KIND_SPEAKER: ["LevelTaskSpeakerDefinition", "SpeakerDefinition"],
	KIND_PROVIDER: ["LevelTaskProviderDeclaration", "ProviderDeclaration"],
}

const KIND_FILE_PREFIXES: Dictionary = {
	KIND_LEVEL: "level",
	KIND_TASK_GRAPH: "task_graph",
	KIND_CONVERSATION: "conversation",
	KIND_SPEAKER: "speaker",
	KIND_PROVIDER: "provider",
}

const NODE_FAMILIES: Dictionary = {
	0: {"label": "Entry", "icons": [&"Play", &"ArrowRight", &"Node"]},
	1: {"label": "Objective / event counter", "icons": [&"Target", &"Flag", &"Node"]},
	2: {"label": "Condition branch", "icons": [&"Branch", &"Split", &"Node"]},
	3: {"label": "All gate", "icons": [&"Merge", &"Layers", &"Node"]},
	4: {"label": "Any gate", "icons": [&"Merge", &"Layers", &"Node"]},
	5: {"label": "External action", "icons": [&"Link", &"Gear", &"Node"]},
	6: {"label": "Conversation", "icons": [&"Dialogue", &"SpeechBubble", &"Node"]},
	7: {"label": "Subgraph", "icons": [&"Instance", &"Folder", &"Node"]},
	8: {"label": "Reward request", "icons": [&"Check", &"Package", &"Node"]},
	9: {"label": "Success terminal", "icons": [&"Check", &"Flag", &"Node"]},
	10: {"label": "Failure terminal", "icons": [&"Error", &"Cross", &"Node"]},
	11: {"label": "Cancelled terminal", "icons": [&"Stop", &"Cancel", &"Node"]},
}

const VALUE_TYPE_LABELS: Dictionary = {
	0: "none",
	1: "boolean",
	2: "integer",
	3: "fixed",
	4: "string",
	5: "identifier",
	6: "bytes",
}

const DIAGNOSTIC_SEVERITIES: PackedStringArray = ["error", "warning", "info"]


static func normalize_kind(kind: String) -> String:
	match kind.strip_edges().to_lower():
		"level", "levels", "level_definition":
			return KIND_LEVEL
		"task_graph", "task_graphs", "graph", "graphs", "task_graph_definition":
			return KIND_TASK_GRAPH
		"conversation", "conversations", "conversation_definition":
			return KIND_CONVERSATION
		"speaker", "speakers", "speaker_definition":
			return KIND_SPEAKER
		"provider", "providers", "provider_declaration", "provider_definition":
			return KIND_PROVIDER
		"project":
			return KIND_PROJECT
		"simulation":
			return KIND_SIMULATION
		"diagnostics", "findings":
			return KIND_DIAGNOSTICS
		_:
			return kind.strip_edges().to_lower()


static func collection_for_kind(kind: String) -> String:
	match normalize_kind(kind):
		KIND_LEVEL:
			return "levels"
		KIND_TASK_GRAPH:
			return "task_graphs"
		KIND_CONVERSATION:
			return "conversations"
		KIND_SPEAKER:
			return "speakers"
		KIND_PROVIDER:
			return "providers"
		_:
			return ""


static func kind_label(kind: String) -> String:
	var normalized := normalize_kind(kind)
	if KIND_LABELS.has(normalized):
		return String(KIND_LABELS[normalized])
	if normalized.is_empty():
		return "Resource"
	return normalized.replace("_", " ").capitalize()


static func collection_label(collection: String) -> String:
	return String(COLLECTION_LABELS.get(collection, collection.replace("_", " ").capitalize()))


static func class_names_for_kind(kind: String) -> Array:
	return Array(KIND_CLASS_NAMES.get(normalize_kind(kind), [])).duplicate()


static func kind_for_class_name(class_name_value: String) -> String:
	for kind in [KIND_LEVEL, KIND_TASK_GRAPH, KIND_CONVERSATION, KIND_SPEAKER, KIND_PROVIDER]:
		if class_names_for_kind(kind).has(class_name_value):
			return kind
	return ""


static func supported_resource_kind(resource: Variant) -> String:
	if resource == null:
		return ""
	if resource is Dictionary:
		return normalize_kind(String(resource.get("kind", resource.get("resource_kind", ""))))
	if resource is Object:
		var class_name_value := String(resource.get_class()) if resource.has_method("get_class") else ""
		var from_class := kind_for_class_name(class_name_value)
		if not from_class.is_empty():
			return from_class
		# Test doubles and older bindings may expose the shape before a class
		# name is stabilized.  Shape checks stay read-only and bounded.
		if resource.has_method("get_nodes") or resource.has_method("get_edges"):
			return KIND_TASK_GRAPH
		if resource.has_method("get_steps") and resource.has_method("get_entry_label"):
			return KIND_CONVERSATION
		if resource.has_method("get_scene_resource") and resource.has_method("get_entry_graph_identifiers"):
			return KIND_LEVEL
	return ""


static func is_supported_path(path: String) -> bool:
	var normalized := path.strip_edges().to_lower()
	return normalized.ends_with(".tres") or normalized.ends_with(".res")


static func resource_display_name(document: Dictionary, fallback_identifier: String = "") -> String:
	var identifier := String(document.get("identifier", fallback_identifier))
	for field in ["display_name_key", "line_key"]:
		var candidate := String(document.get(field, ""))
		if not candidate.is_empty():
			return candidate
	return identifier if not identifier.is_empty() else "Unnamed resource"


static func resource_entry(kind: String, identifier: String, source_path: String = "", label: String = "") -> Dictionary:
	var normalized := normalize_kind(kind)
	var resource_label := label if not label.is_empty() else identifier
	return {
		"kind": normalized,
		"collection": collection_for_kind(normalized),
		"identifier": identifier,
		"label": resource_label,
		"source_path": source_path,
		"path": document_path(normalized, identifier),
	}


static func filter_entries(entries: Array, query: String) -> Array:
	var needle := query.strip_edges().to_lower()
	var result: Array = []
	for raw_entry in entries:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry
		if needle.is_empty():
			result.append(entry.duplicate(true))
			continue
		var haystack := "%s %s %s %s" % [
			String(entry.get("identifier", "")),
			String(entry.get("label", "")),
			String(entry.get("source_path", "")),
			String(entry.get("kind", "")),
		]
		if haystack.to_lower().find(needle) >= 0:
			result.append(entry.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%s|%s|%s" % [a.get("kind", ""), a.get("identifier", ""), a.get("source_path", "")]
		var b_key := "%s|%s|%s" % [b.get("kind", ""), b.get("identifier", ""), b.get("source_path", "")]
		return a_key < b_key
	)
	return result


static func flatten_navigation(model_projection: Dictionary) -> Array:
	var result: Array = []
	for group in model_projection.get("groups", []):
		if not group is Dictionary:
			continue
		for entry in group.get("entries", []):
			if entry is Dictionary:
				result.append(entry.duplicate(true))
	return result


static func document_path(kind: String, identifier: String) -> String:
	var prefix := {
		KIND_LEVEL: "level",
		KIND_TASK_GRAPH: "task",
		KIND_CONVERSATION: "conversation",
		KIND_SPEAKER: "speaker",
		KIND_PROVIDER: "provider",
	}.get(normalize_kind(kind), "resource")
	return "%s.%s" % [prefix, identifier]


static func breadcrumbs(kind: String = "", identifier: String = "", subgraph_identifier: String = "") -> Array:
	var result: Array = [{"label": "Project", "kind": KIND_PROJECT, "path": "project", "current": kind.is_empty()}]
	var normalized := normalize_kind(kind)
	if normalized.is_empty():
		return result
	var collection := collection_for_kind(normalized)
	result.append({
		"label": collection_label(collection),
		"kind": normalized,
		"path": collection,
		"current": identifier.is_empty(),
	})
	if not identifier.is_empty():
		result.append({
			"label": identifier,
			"kind": normalized,
			"identifier": identifier,
			"path": document_path(normalized, identifier),
			"current": subgraph_identifier.is_empty(),
		})
	if not subgraph_identifier.is_empty():
		result.append({
			"label": subgraph_identifier,
			"kind": KIND_TASK_GRAPH,
			"identifier": subgraph_identifier,
			"path": document_path(KIND_TASK_GRAPH, subgraph_identifier),
			"current": true,
		})
	return result


static func node_family(kind_value: Variant) -> Dictionary:
	var family := NODE_FAMILIES.get(int(kind_value), null)
	if family is Dictionary:
		return family.duplicate(true)
	return {"label": "Unknown node", "icons": [&"Node"]}


static func value_type_label(value_type: Variant) -> String:
	return String(VALUE_TYPE_LABELS.get(int(value_type), "type_%s" % int(value_type)))


static func port_projection(port: Dictionary) -> Dictionary:
	var direction_value := int(port.get("direction", 1))
	return {
		"name": String(port.get("identifier", port.get("name", "port"))),
		"direction": "IN" if direction_value == 0 else "OUT",
		"type": value_type_label(port.get("value_type", port.get("type", 0))),
		"value_type": int(port.get("value_type", port.get("type", 0))),
		"required": bool(port.get("required", false)),
	}


static func node_summary(node: Dictionary) -> String:
	var kind := int(node.get("kind", 0))
	match kind:
		1:
			return "Target: %d" % int(node.get("objective_target", 1))
		5, 8:
			var provider := String(node.get("provider_identifier", ""))
			return "Provider: %s" % (provider if not provider.is_empty() else "not configured")
		6:
			var conversation := String(node.get("conversation_identifier", ""))
			return "Conversation: %s" % (conversation if not conversation.is_empty() else "not configured")
		7:
			var graph := String(node.get("subgraph_identifier", ""))
			return "Subgraph: %s" % (graph if not graph.is_empty() else "not configured")
		_:
			return "Ports: %d" % Array(node.get("ports", [])).size()


static func default_node_position(index: int, unit: float = 8.0) -> Array:
	var column := index % 3
	var row := int(index / 3)
	return [float(unit * (8.0 + column * 24.0)), float(unit * (8.0 + row * 18.0))]


static func severity_counts(findings: Array) -> Dictionary:
	var result := {"error": 0, "warning": 0, "info": 0, "total": 0}
	for finding in findings:
		if not finding is Dictionary:
			continue
		var severity := String(finding.get("severity", "info")).to_lower()
		if not result.has(severity):
			severity = "info"
		result[severity] = int(result[severity]) + 1
		result["total"] = int(result["total"]) + 1
	return result


static func findings_for_document(kind: String, identifier: String, document: Dictionary, native_available: bool = true) -> Array:
	var findings: Array = []
	if not native_available:
		findings.append(_finding("error", "LTS-NATIVE-001", "native", "Native extension unavailable; authoring is read-only."))
		return findings
	var normalized := normalize_kind(kind)
	if identifier.is_empty():
		findings.append(_finding("error", "LTS-DOCUMENT-001", document_path(normalized, identifier), "Resource has no stable identifier."))
		return findings
	match normalized:
		KIND_TASK_GRAPH:
			var nodes: Array = document.get("nodes", [])
			var edges: Array = document.get("edges", [])
			if nodes.is_empty():
				findings.append(_finding("warning", "LTS-GRAPH-001", document_path(normalized, identifier), "Task graph has no authored nodes."))
			var entry := String(document.get("entry_node_identifier", ""))
			if entry.is_empty():
				findings.append(_finding("error", "LTS-GRAPH-002", document_path(normalized, identifier) + ".entry_node_identifier", "Task graph has no entry node."))
			elif not _contains_identifier(nodes, entry):
				findings.append(_finding("error", "LTS-GRAPH-003", document_path(normalized, identifier) + ".entry_node_identifier", "Entry node does not exist."))
			for node in nodes:
				if not node is Dictionary:
					continue
				var node_id := String(node.get("identifier", ""))
				if node_id.is_empty():
					findings.append(_finding("error", "LTS-GRAPH-004", document_path(normalized, identifier) + ".nodes", "Node is missing a stable identifier."))
				if Array(node.get("ports", [])).is_empty() and int(node.get("kind", 0)) not in [9, 10, 11]:
					findings.append(_finding("warning", "LTS-GRAPH-007", document_path(normalized, identifier) + ".node." + node_id, "Node has no named ports."))
			for edge in edges:
				if not edge is Dictionary:
					continue
				var from_id := String(edge.get("from_node_identifier", ""))
				var to_id := String(edge.get("to_node_identifier", ""))
				if not _contains_identifier(nodes, from_id) or not _contains_identifier(nodes, to_id):
					findings.append(_finding("error", "LTS-GRAPH-005", document_path(normalized, identifier) + ".edge." + String(edge.get("identifier", "")), "Connection references a missing node."))
			if _terminal_nodes(nodes).is_empty():
				findings.append(_finding("warning", "LTS-GRAPH-006", document_path(normalized, identifier), "Task graph has no terminal outcome node."))
		KIND_CONVERSATION:
			var steps: Array = document.get("steps", [])
			if steps.is_empty():
				findings.append(_finding("warning", "LTS-CONVERSATION-001", document_path(normalized, identifier), "Conversation has no authored steps."))
			if String(document.get("entry_label", "")).is_empty():
				findings.append(_finding("error", "LTS-CONVERSATION-002", document_path(normalized, identifier) + ".entry_label", "Conversation has no entry label."))
			for step in steps:
				if step is Dictionary and String(step.get("line_key", "")).is_empty() and int(step.get("kind", 0)) == 0:
					findings.append(_finding("warning", "LTS-CONVERSATION-003", document_path(normalized, identifier) + ".step." + String(step.get("identifier", "")), "Line step has no localization key."))
		KIND_LEVEL:
			if String(document.get("scene_resource", "")).is_empty():
				findings.append(_finding("warning", "LTS-LEVEL-001", document_path(normalized, identifier) + ".scene_resource", "Level has no scene resource."))
			if Array(document.get("entry_graph_identifiers", [])).is_empty():
				findings.append(_finding("warning", "LTS-LEVEL-002", document_path(normalized, identifier) + ".entry_graph_identifiers", "Level has no entry task graph."))
	return findings


static func _finding(severity: String, code: String, path: String, message: String) -> Dictionary:
	return {"severity": severity, "code": code, "path": path, "message": message}


static func _contains_identifier(values: Array, identifier: String) -> bool:
	if identifier.is_empty():
		return false
	for value in values:
		if value is Dictionary and String(value.get("identifier", "")) == identifier:
			return true
	return false


static func _terminal_nodes(values: Array) -> Array:
	var result: Array = []
	for value in values:
		if value is Dictionary and int(value.get("kind", -1)) in [9, 10, 11]:
			result.append(value)
	return result


static func creation_spec(kind: String, identifier: String = "", directory: String = "res://") -> Dictionary:
	var normalized := normalize_kind(kind)
	var safe_identifier := identifier if not identifier.is_empty() else "new.%s" % normalized
	var prefix := String(KIND_FILE_PREFIXES.get(normalized, normalized))
	var filename := "%s_%s.tres" % [prefix, safe_identifier.replace(".", "_")]
	return {
		"kind": normalized,
		"label": kind_label(normalized),
		"class_names": class_names_for_kind(normalized),
		"identifier": safe_identifier,
		"path": directory.path_join(filename),
	}


static func creation_kinds() -> PackedStringArray:
	return PackedStringArray([KIND_LEVEL, KIND_TASK_GRAPH, KIND_CONVERSATION, KIND_SPEAKER, KIND_PROVIDER])


static func collapse_order() -> PackedStringArray:
	return PackedStringArray(["navigator", "inspector", "drawer"])


static func minimum_width_units() -> Dictionary:
	return {"navigator": 18, "center": 36, "inspector": 22, "drawer": 18}
