class_name LtsDocumentValidator
extends RefCounted

## Headless validation projection for immediate editor feedback.
##
## The native compiler remains authoritative for full catalog validation. This
## validator covers safe, local authoring checks and emits the same stable path
## shape used by the document model. It never mutates the source document.

const MAX_FINDINGS := 256

const KIND_LEVEL := "level"
const KIND_TASK_GRAPH := "task_graph"
const KIND_CONVERSATION := "conversation"
const KIND_SPEAKER := "speaker"
const KIND_PROVIDER := "provider"

const STORAGE_KIND: Dictionary = {
	"levels": KIND_LEVEL,
	"task_graphs": KIND_TASK_GRAPH,
	"conversations": KIND_CONVERSATION,
	"speakers": KIND_SPEAKER,
	"providers": KIND_PROVIDER,
}

const SEVERITY_RANK: Dictionary = {
	"error": 0,
	"warning": 1,
	"info": 2,
}


static func validate(source: Variant, changed_paths: PackedStringArray = PackedStringArray()) -> Array:
	var state := _state_from(source)
	var findings: Array = []
	var documents: Dictionary = state.get("documents", {})
	for storage_name in STORAGE_KIND:
		var bucket: Dictionary = documents.get(storage_name, {})
		var identifiers := bucket.keys()
		identifiers.sort()
		for raw_identifier in identifiers:
			var identifier := String(raw_identifier)
			var document: Dictionary = bucket.get(raw_identifier, {})
			_validate_resource(String(STORAGE_KIND[storage_name]), identifier, document, documents, findings)
	_sort_findings(findings)
	if not changed_paths.is_empty():
		findings = _filter_changed(findings, changed_paths)
	if findings.size() > MAX_FINDINGS:
		findings.resize(MAX_FINDINGS)
	return findings


static func validate_paths(source: Variant, changed_paths: PackedStringArray) -> Array:
	return validate(source, changed_paths)


static func summary(findings: Array) -> Dictionary:
	var result := {"error": 0, "warning": 0, "info": 0, "total": 0}
	for value in findings:
		if not value is Dictionary:
			continue
		var severity := String(value.get("severity", "info")).to_lower()
		if not result.has(severity):
			severity = "info"
		result[severity] = int(result[severity]) + 1
		result["total"] = int(result["total"]) + 1
	return result


static func navigation_target(finding: Dictionary) -> Dictionary:
	return {
		"resource_kind": String(finding.get("resource_kind", "")),
		"resource_identifier": String(finding.get("resource_identifier", "")),
		"element_kind": String(finding.get("element_kind", "")),
		"element_identifier": String(finding.get("element_identifier", "")),
		"field_path": String(finding.get("field_path", "")),
		"path": String(finding.get("path", "")),
	}


static func _state_from(source: Variant) -> Dictionary:
	if source is Dictionary:
		return source.duplicate(true)
	if source != null and source.has_method("snapshot"):
		var value: Variant = source.call("snapshot")
		if value is Dictionary:
			return value
	return {"documents": {}}


static func _validate_resource(kind: String, identifier: String, document: Dictionary, documents: Dictionary, findings: Array) -> void:
	var root_path := _path(kind, identifier)
	if not _valid_stable_identifier(identifier):
		_add(findings, "error", "LTS-IDENTIFIER-001", "Use a lowercase namespaced identifier such as 'quest.harbor.rescue'.", root_path + ".identifier", kind, identifier, "", "", "identifier")
	match kind:
		KIND_TASK_GRAPH:
			_validate_task_graph(identifier, document, findings)
		KIND_CONVERSATION:
			_validate_conversation(identifier, document, findings)
		KIND_LEVEL:
			_validate_level(identifier, document, documents, findings)
		KIND_SPEAKER:
			_validate_localization_field(kind, identifier, document, "display_name_key", findings)
		KIND_PROVIDER:
			_validate_provider(identifier, document, findings)


static func _validate_task_graph(identifier: String, document: Dictionary, findings: Array) -> void:
	var nodes: Array = _array(document.get("nodes", []))
	var edges: Array = _array(document.get("edges", []))
	var node_index: Dictionary = {}
	var entry_nodes: Array[String] = []
	var terminal_nodes: Array[String] = []
	for index in range(nodes.size()):
		if not nodes[index] is Dictionary:
			_add(findings, "error", "LTS-GRAPH-001", "Node entry is not a document object.", _path(KIND_TASK_GRAPH, identifier, "node", str(index)), KIND_TASK_GRAPH, identifier, "node", str(index))
			continue
		var node: Dictionary = nodes[index]
		var node_id := String(node.get("identifier", ""))
		var node_path := _path(KIND_TASK_GRAPH, identifier, "node", node_id if not node_id.is_empty() else str(index))
		if not _valid_local_identifier(node_id):
			_add(findings, "error", "LTS-GRAPH-002", "Node identifiers use lowercase ASCII segments.", node_path + ".identifier", KIND_TASK_GRAPH, identifier, "node", node_id, "identifier")
		elif node_index.has(node_id):
			_add(findings, "error", "LTS-GRAPH-003", "Node identifier is duplicated in this graph.", node_path + ".identifier", KIND_TASK_GRAPH, identifier, "node", node_id, "identifier")
		else:
			node_index[node_id] = node
		var kind := int(node.get("kind", -1))
		if kind == 0:
			entry_nodes.append(node_id)
		if kind in [9, 10, 11]:
			terminal_nodes.append(node_id)
		var ports_seen: Dictionary = {}
		for port_value in _array(node.get("ports", [])):
			if not port_value is Dictionary:
				continue
			var port: Dictionary = port_value
			var port_id := String(port.get("identifier", ""))
			var port_path := node_path + ".port." + (port_id if not port_id.is_empty() else "missing")
			if not _valid_local_identifier(port_id):
				_add(findings, "error", "LTS-GRAPH-004", "Port identifiers use lowercase ASCII segments.", port_path + ".identifier", KIND_TASK_GRAPH, identifier, "port", port_id, "identifier")
			elif ports_seen.has(port_id):
				_add(findings, "error", "LTS-GRAPH-005", "Port identifier is duplicated on this node.", port_path + ".identifier", KIND_TASK_GRAPH, identifier, "port", port_id, "identifier")
			ports_seen[port_id] = true
	if entry_nodes.size() != 1:
		_add(findings, "error", "LTS-GRAPH-006", "A task graph requires exactly one entry node.", _path(KIND_TASK_GRAPH, identifier, "", "", "entry_node_identifier"), KIND_TASK_GRAPH, identifier, "", "", "entry_node_identifier")
	var declared_entry := String(document.get("entry_node_identifier", ""))
	if declared_entry.is_empty() or not node_index.has(declared_entry):
		_add(findings, "error", "LTS-GRAPH-007", "The declared entry node does not exist.", _path(KIND_TASK_GRAPH, identifier, "", "", "entry_node_identifier"), KIND_TASK_GRAPH, identifier, "", "", "entry_node_identifier")
	elif entry_nodes.size() == 1 and entry_nodes[0] != declared_entry:
		_add(findings, "error", "LTS-GRAPH-008", "The declared entry must reference the entry-kind node.", _path(KIND_TASK_GRAPH, identifier, "node", declared_entry, "kind"), KIND_TASK_GRAPH, identifier, "node", declared_entry, "kind")
	if terminal_nodes.is_empty():
		_add(findings, "error", "LTS-GRAPH-009", "Add at least one terminal outcome node.", _path(KIND_TASK_GRAPH, identifier, "", "", "terminal_outcomes"), KIND_TASK_GRAPH, identifier, "", "", "terminal_outcomes")
	var edge_ids: Dictionary = {}
	for index in range(edges.size()):
		if not edges[index] is Dictionary:
			continue
		var edge: Dictionary = edges[index]
		var edge_id := String(edge.get("identifier", ""))
		var edge_path := _path(KIND_TASK_GRAPH, identifier, "edge", edge_id if not edge_id.is_empty() else str(index))
		if not _valid_local_identifier(edge_id):
			_add(findings, "error", "LTS-GRAPH-010", "Edge identifiers use lowercase ASCII segments.", edge_path + ".identifier", KIND_TASK_GRAPH, identifier, "edge", edge_id, "identifier")
		elif edge_ids.has(edge_id):
			_add(findings, "error", "LTS-GRAPH-011", "Edge identifier is duplicated in this graph.", edge_path + ".identifier", KIND_TASK_GRAPH, identifier, "edge", edge_id, "identifier")
		edge_ids[edge_id] = true
		_validate_edge_endpoint(identifier, edge, node_index, true, edge_path, findings)
		_validate_edge_endpoint(identifier, edge, node_index, false, edge_path, findings)


static func _validate_edge_endpoint(graph_id: String, edge: Dictionary, node_index: Dictionary, from_side: bool, edge_path: String, findings: Array) -> void:
	var node_field := "from_node_identifier" if from_side else "to_node_identifier"
	var port_field := "from_port_identifier" if from_side else "to_port_identifier"
	var node_id := String(edge.get(node_field, ""))
	var port_id := String(edge.get(port_field, ""))
	if not node_index.has(node_id):
		_add(findings, "error", "LTS-GRAPH-012", "Connection endpoint references a missing node.", edge_path + "." + node_field, KIND_TASK_GRAPH, graph_id, "edge", String(edge.get("identifier", "")), node_field)
		return
	var node: Dictionary = node_index[node_id]
	var expected_direction := 1 if from_side else 0
	var matching_port: Dictionary = {}
	for port_value in _array(node.get("ports", [])):
		if port_value is Dictionary and String(port_value.get("identifier", "")) == port_id:
			matching_port = port_value
			break
	if matching_port.is_empty():
		_add(findings, "error", "LTS-GRAPH-013", "Connection endpoint references a missing named port.", edge_path + "." + port_field, KIND_TASK_GRAPH, graph_id, "edge", String(edge.get("identifier", "")), port_field)
	elif int(matching_port.get("direction", -1)) != expected_direction:
		_add(findings, "error", "LTS-GRAPH-014", "Connection endpoint uses a port in the wrong direction.", edge_path + "." + port_field, KIND_TASK_GRAPH, graph_id, "edge", String(edge.get("identifier", "")), port_field)


static func _validate_conversation(identifier: String, document: Dictionary, findings: Array) -> void:
	var steps: Array = _array(document.get("steps", []))
	var step_index: Dictionary = {}
	for index in range(steps.size()):
		if not steps[index] is Dictionary:
			continue
		var step: Dictionary = steps[index]
		var step_id := String(step.get("identifier", ""))
		var step_path := _path(KIND_CONVERSATION, identifier, "step", step_id if not step_id.is_empty() else str(index))
		if not _valid_local_identifier(step_id):
			_add(findings, "error", "LTS-CONVERSATION-001", "Step identifiers use lowercase ASCII segments.", step_path + ".identifier", KIND_CONVERSATION, identifier, "step", step_id, "identifier")
		elif step_index.has(step_id):
			_add(findings, "error", "LTS-CONVERSATION-002", "Step identifier is duplicated.", step_path + ".identifier", KIND_CONVERSATION, identifier, "step", step_id, "identifier")
		step_index[step_id] = step
		if int(step.get("kind", -1)) == 0:
			_validate_localization_field(KIND_CONVERSATION, identifier, step, "line_key", findings, "step", step_id)
		var choice_ids: Dictionary = {}
		for choice_value in _array(step.get("choices", [])):
			if not choice_value is Dictionary:
				continue
			var choice: Dictionary = choice_value
			var choice_id := String(choice.get("identifier", ""))
			var choice_path := _path(KIND_CONVERSATION, identifier, "choice", choice_id if not choice_id.is_empty() else "missing")
			if not _valid_local_identifier(choice_id) or choice_ids.has(choice_id):
				_add(findings, "error", "LTS-CONVERSATION-003", "Choice identifier is missing, invalid, or duplicated on this step.", choice_path + ".identifier", KIND_CONVERSATION, identifier, "choice", choice_id, "identifier")
			choice_ids[choice_id] = true
			_validate_localization_field(KIND_CONVERSATION, identifier, choice, "label_key", findings, "choice", choice_id)
	var entry := String(document.get("entry_label", ""))
	if entry.is_empty() or not step_index.has(entry):
		_add(findings, "error", "LTS-CONVERSATION-004", "The conversation entry label must reference an existing step.", _path(KIND_CONVERSATION, identifier, "", "", "entry_label"), KIND_CONVERSATION, identifier, "", "", "entry_label")


static func _validate_level(identifier: String, document: Dictionary, documents: Dictionary, findings: Array) -> void:
	_validate_localization_field(KIND_LEVEL, identifier, document, "display_name_key", findings)
	var scene_path := String(document.get("scene_resource", ""))
	if scene_path.is_empty() or not scene_path.begins_with("res://") or not scene_path.ends_with(".tscn"):
		_add(findings, "error", "LTS-LEVEL-001", "Scene resource must be a project .tscn path.", _path(KIND_LEVEL, identifier, "", "", "scene_resource"), KIND_LEVEL, identifier, "", "", "scene_resource")
	var graph_bucket: Dictionary = documents.get("task_graphs", {})
	for graph_id_value in _array(document.get("entry_graph_identifiers", [])):
		var graph_id := String(graph_id_value)
		if not graph_bucket.has(graph_id):
			_add(findings, "error", "LTS-LEVEL-002", "Entry graph is not present in the open catalog.", _path(KIND_LEVEL, identifier, "", "", "entry_graph_identifiers"), KIND_LEVEL, identifier, "", "", "entry_graph_identifiers")
	var anchors := _index_local_values(KIND_LEVEL, identifier, "anchor", _array(document.get("anchors", [])), findings, "LTS-LEVEL-003")
	var exits := _index_local_values(KIND_LEVEL, identifier, "exit", _array(document.get("exits", [])), findings, "LTS-LEVEL-004")
	var levels: Dictionary = documents.get("levels", {})
	for exit_id in exits:
		var exit_value: Dictionary = exits[exit_id]
		var target_level_id := String(exit_value.get("target_level_identifier", ""))
		var target_anchor_id := String(exit_value.get("target_anchor_identifier", ""))
		if not levels.has(target_level_id):
			_add(findings, "error", "LTS-LEVEL-005", "Exit target level is not present in the open catalog.", _path(KIND_LEVEL, identifier, "exit", String(exit_id), "target_level_identifier"), KIND_LEVEL, identifier, "exit", String(exit_id), "target_level_identifier")
		elif not target_anchor_id.is_empty():
			var target_doc: Dictionary = levels[target_level_id]
			var found_anchor := false
			for target_anchor_value in _array(target_doc.get("anchors", [])):
				if target_anchor_value is Dictionary and String(target_anchor_value.get("identifier", "")) == target_anchor_id:
					found_anchor = true
					break
			if not found_anchor:
				_add(findings, "error", "LTS-LEVEL-006", "Exit target anchor does not exist on the target level.", _path(KIND_LEVEL, identifier, "exit", String(exit_id), "target_anchor_identifier"), KIND_LEVEL, identifier, "exit", String(exit_id), "target_anchor_identifier")
	# Referencing the local anchor map keeps duplicate validation explicit even
	# when the level has no exits yet.
	if anchors.is_empty() and not _array(document.get("anchors", [])).is_empty():
		pass


static func _validate_provider(identifier: String, document: Dictionary, findings: Array) -> void:
	if int(document.get("max_request_bytes", 0)) < 0:
		_add(findings, "error", "LTS-PROVIDER-001", "Request byte limit cannot be negative.", _path(KIND_PROVIDER, identifier, "", "", "max_request_bytes"), KIND_PROVIDER, identifier, "", "", "max_request_bytes")
	if int(document.get("max_response_bytes", 0)) < 0:
		_add(findings, "error", "LTS-PROVIDER-002", "Response byte limit cannot be negative.", _path(KIND_PROVIDER, identifier, "", "", "max_response_bytes"), KIND_PROVIDER, identifier, "", "", "max_response_bytes")


static func _validate_localization_field(kind: String, identifier: String, value: Dictionary, field: String, findings: Array, element_kind: String = "", element_id: String = "") -> void:
	var key := String(value.get(field, ""))
	if not _valid_stable_identifier(key):
		_add(findings, "error", "LTS-LOCALIZATION-001", "Localization keys use lowercase namespaced identifiers.", _path(kind, identifier, element_kind, element_id, field), kind, identifier, element_kind, element_id, field)


static func _index_local_values(kind: String, identifier: String, element_kind: String, values: Array, findings: Array, code: String) -> Dictionary:
	var result: Dictionary = {}
	for index in range(values.size()):
		if not values[index] is Dictionary:
			continue
		var value: Dictionary = values[index]
		var local_id := String(value.get("identifier", ""))
		if not _valid_local_identifier(local_id) or result.has(local_id):
			_add(findings, "error", code, "%s identifier is missing, invalid, or duplicated." % element_kind.capitalize(), _path(kind, identifier, element_kind, local_id if not local_id.is_empty() else str(index), "identifier"), kind, identifier, element_kind, local_id, "identifier")
		else:
			result[local_id] = value
	return result


static func _filter_changed(findings: Array, changed_paths: PackedStringArray) -> Array:
	var result: Array = []
	for finding_value in findings:
		if not finding_value is Dictionary:
			continue
		var finding_path := String(finding_value.get("path", ""))
		for changed_path in changed_paths:
			var path := String(changed_path)
			if path.is_empty() or finding_path == path or finding_path.begins_with(path + ".") or path.begins_with(finding_path + "."):
				result.append(finding_value)
				break
	return result


static func _add(findings: Array, severity: String, code: String, message: String, path: String, resource_kind: String, resource_identifier: String, element_kind: String = "", element_identifier: String = "", field_path: String = "", fix_id: String = "", fix_label: String = "") -> void:
	if findings.size() >= MAX_FINDINGS:
		return
	findings.append({
		"severity": severity,
		"code": code,
		"message": message,
		"path": path,
		"resource_kind": resource_kind,
		"resource_identifier": resource_identifier,
		"element_kind": element_kind,
		"element_identifier": element_identifier,
		"field_path": field_path,
		"fix_id": fix_id,
		"fix_label": fix_label,
	})


static func _sort_findings(findings: Array) -> void:
	findings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_rank := int(SEVERITY_RANK.get(String(a.get("severity", "info")), 2))
		var b_rank := int(SEVERITY_RANK.get(String(b.get("severity", "info")), 2))
		if a_rank != b_rank:
			return a_rank < b_rank
		var a_path := String(a.get("path", ""))
		var b_path := String(b.get("path", ""))
		if a_path != b_path:
			return a_path < b_path
		return String(a.get("code", "")) < String(b.get("code", ""))
	)


static func _path(kind: String, identifier: String, element_kind: String = "", element_identifier: String = "", field_path: String = "") -> String:
	var prefix := "task" if kind == KIND_TASK_GRAPH else kind
	var parts: Array[String] = [prefix, identifier]
	if not element_kind.is_empty():
		parts.append(element_kind)
	if not element_identifier.is_empty():
		parts.append(element_identifier)
	if not field_path.is_empty():
		parts.append(field_path)
	return ".".join(parts)


static func _valid_stable_identifier(value: String) -> bool:
	if value.length() < 3 or not value.contains("."):
		return false
	for segment in value.split("."):
		if not _valid_segment(String(segment)):
			return false
	return true


static func _valid_local_identifier(value: String) -> bool:
	if value.is_empty():
		return false
	for segment in value.split("."):
		if not _valid_segment(String(segment)):
			return false
	return true


static func _valid_segment(value: String) -> bool:
	if value.is_empty():
		return false
	var first := value.unicode_at(0)
	if first < 97 or first > 122:
		return false
	for index in range(1, value.length()):
		var code := value.unicode_at(index)
		if code >= 97 and code <= 122:
			continue
		if code >= 48 and code <= 57:
			continue
		if code == 95:
			continue
		return false
	return true


static func _array(value: Variant) -> Array:
	if value is Array:
		return value
	if value is PackedStringArray:
		var result: Array = []
		for item in value:
			result.append(item)
		return result
	return []
