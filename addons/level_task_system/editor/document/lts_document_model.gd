class_name LtsDocumentModel
extends RefCounted

## Pure/headless-testable source-of-truth for the level/task editor.
##
## The model is a serializable projection, not a second Resource graph and not
## a GraphEdit owner.  Semantic definitions live under `documents`; editor
## layout, navigator context, and selection live in separate branches.  Every
## mutation is represented by LtsDocumentCommand and is applied to a deep
## candidate before the model commits it.  The returned inverse command is
## safe to register with LtsDocumentHistory and a Godot UndoRedo backend.

const DocumentCommand := preload("res://addons/level_task_system/editor/document/lts_document_command.gd")
const DocumentProjection := preload("res://addons/level_task_system/editor/document/lts_document_projection.gd")
const DocumentFixtures := preload("res://addons/level_task_system/editor/document/lts_document_fixtures.gd")

const DOCUMENT_SCHEMA_VERSION := 1
const MUTATION_SEMANTIC := DocumentCommand.MUTATION_SEMANTIC
const MUTATION_LAYOUT := DocumentCommand.MUTATION_LAYOUT
const MUTATION_MIXED := DocumentCommand.MUTATION_MIXED

const KIND_LEVEL := "level"
const KIND_TASK_GRAPH := "task_graph"
const KIND_CONVERSATION := "conversation"
const KIND_SPEAKER := "speaker"
const KIND_PROVIDER := "provider"

const COLLECTION_ORDER: PackedStringArray = [
	"levels", "task_graphs", "conversations", "speakers", "providers",
]

const EMPTY_SELECTION: Dictionary = {
	"resource_kind": "",
	"resource_identifier": "",
	"element_kind": "",
	"element_identifier": "",
	"field_path": "",
}

var _state: Dictionary = {}
var _revision := 0


func _init(source: Variant = null, native_extension_available: bool = true) -> void:
	_state = _empty_state()
	if source is Dictionary:
		_state = _normalize_state(source)
	if not native_extension_available:
		_state = DocumentFixtures.native_extension_unavailable()
	_revision = int(_state.get("revision", 0))


static func from_resource(resource: Variant, source_path: String = "", native_extension_available: bool = true):
	var model = load("res://addons/level_task_system/editor/document/lts_document_model.gd").new()
	if not native_extension_available:
		model._state = DocumentFixtures.native_extension_unavailable()
		return model
	var projection := DocumentProjection.project_resource(resource, source_path)
	model.load_projection(projection)
	return model


static func from_catalog(catalog: Variant, source_path: String = "", native_extension_available: bool = true):
	var model = load("res://addons/level_task_system/editor/document/lts_document_model.gd").new()
	if not native_extension_available:
		model._state = DocumentFixtures.native_extension_unavailable()
		return model
	model.load_catalog(catalog, source_path)
	return model


static func degraded_fixture(reason: String = "") -> Dictionary:
	return DocumentFixtures.native_extension_unavailable(reason)


static func native_extension_unavailable_fixture(reason: String = "") -> Dictionary:
	return DocumentFixtures.native_extension_unavailable(reason)


func load_projection(projection: Dictionary) -> Dictionary:
	var candidate := _empty_state()
	var incoming := projection.duplicate(true)
	if incoming.has("documents"):
		candidate = _normalize_state(incoming)
	else:
		var kind := _storage_kind(String(incoming.get("kind", "")))
		var identifier := String(incoming.get("identifier", ""))
		if identifier.is_empty() or kind.is_empty():
			_state = DocumentFixtures.malformed_resource(String(incoming.get("source_path", "")), "Projection has no supported identifier")
			_revision = 0
			return {"ok": false, "applied": false, "error": _state.get("diagnostic", {}).duplicate(true)}
		candidate["documents"][kind][identifier] = incoming
		candidate["catalog"]["entries"].append(_navigation_entry(incoming, kind, identifier))
		candidate["catalog"]["source_path"] = String(incoming.get("source_path", ""))
	_state = candidate
	_revision = 0
	_state["revision"] = _revision
	return {"ok": true, "applied": true, "revision": _revision, "state": snapshot()}


func load_catalog(catalog: Variant, source_path: String = "") -> Dictionary:
	var projected := DocumentProjection.project_catalog(catalog, source_path)
	var candidate := _empty_state()
	candidate["catalog"]["identifier"] = String(projected.get("identifier", ""))
	candidate["catalog"]["source_path"] = String(projected.get("source_path", source_path))
	candidate["catalog"]["entries"] = projected.get("entries", []).duplicate(true)
	candidate["documents"] = _normalize_documents(projected.get("documents", {}))
	_state = candidate
	_revision = 0
	_state["revision"] = 0
	return {"ok": true, "applied": true, "revision": 0, "state": snapshot()}


func snapshot() -> Dictionary:
	var result := _state.duplicate(true)
	result["revision"] = _revision
	return result


func get_state() -> Dictionary:
	return snapshot()


func to_dict() -> Dictionary:
	return snapshot()


func serialize() -> Dictionary:
	return snapshot()


func to_json() -> String:
	return JSON.stringify(snapshot())


func get_revision() -> int:
	return _revision


func is_native_extension_available() -> bool:
	return bool(_state.get("native_extension_available", true))


func is_degraded() -> bool:
	return bool(_state.get("degraded", false)) or not is_native_extension_available()


func is_read_only() -> bool:
	return bool(_state.get("read_only", false))


func can_mutate() -> bool:
	return not is_read_only() and not is_degraded()


func get_diagnostic() -> Dictionary:
	return _state.get("diagnostic", {}).duplicate(true)


func get_document(document_kind: String, document_identifier: String) -> Dictionary:
	var storage_kind := _storage_kind(document_kind)
	var bucket: Dictionary = _state.get("documents", {}).get(storage_kind, {})
	if not bucket.has(document_identifier):
		return {}
	return bucket[document_identifier].duplicate(true)


func get_resource_document(document_kind: String, document_identifier: String) -> Dictionary:
	return get_document(document_kind, document_identifier)


func has_document(document_kind: String, document_identifier: String) -> bool:
	var storage_kind := _storage_kind(document_kind)
	return _state.get("documents", {}).get(storage_kind, {}).has(document_identifier)


func semantic_snapshot() -> Dictionary:
	var result: Dictionary = {"schema_version": DOCUMENT_SCHEMA_VERSION, "documents": {}}
	var documents: Dictionary = _state.get("documents", {})
	for collection in COLLECTION_ORDER:
		var bucket: Dictionary = documents.get(collection, {})
		var ids := bucket.keys()
		ids.sort()
		var sorted_bucket: Dictionary = {}
		for identifier in ids:
			sorted_bucket[String(identifier)] = _without_editor_metadata(bucket[identifier])
		result["documents"][collection] = sorted_bucket
	return result


func runtime_projection() -> Dictionary:
	return semantic_snapshot()


## Returns the same result shape as apply_command without changing the model
## or its revision.  History adapters use this to build a reversible Godot
## action before registering it with EditorUndoRedoManager.
func preview_command(command: Variant) -> Dictionary:
	var data := _command_data(command)
	if data.is_empty():
		return _failure("LTS-DOCUMENT-003", "Command is not serializable", "command")
	var operation := _canonical_operation(String(data.get("operation", data.get("type", ""))))
	var mutation := String(data.get("mutation", data.get("mutation_class", "")))
	if mutation.is_empty():
		mutation = DocumentCommand.infer_mutation(operation)
	var payload: Dictionary = data.get("payload", {})
	if not payload is Dictionary or operation.is_empty():
		return _failure("LTS-DOCUMENT-004", "Command shape is invalid", "command")
	if mutation not in [MUTATION_SEMANTIC, MUTATION_LAYOUT, MUTATION_MIXED]:
		return _failure("LTS-DOCUMENT-005", "Unknown mutation class", "command.mutation")
	if is_read_only() or is_degraded():
		return _failure(String(get_diagnostic().get("code", "LTS-NATIVE-001")), String(get_diagnostic().get("message", "Document is read-only")), String(get_diagnostic().get("path", "native")))
	var candidate := _state.duplicate(true)
	var operation_result := _apply_operation(candidate, operation, payload, mutation)
	if not bool(operation_result.get("ok", false)):
		return _failure(
			String(operation_result.get("code", "LTS-DOCUMENT-006")),
			String(operation_result.get("message", "Command rejected")),
			String(operation_result.get("path", "document")),
			data
		)
	var inverse_data: Dictionary = operation_result.get("inverse", {})
	return {
		"ok": true,
		"applied": false,
		"operation": operation,
		"mutation": mutation,
		"revision": _revision,
		"command": data.duplicate(true),
		"inverse": inverse_data.duplicate(true),
		"inverse_command": DocumentCommand.from_dict(inverse_data) if not inverse_data.is_empty() else null,
		"state": snapshot(),
	}


func preview(command: Variant) -> Dictionary:
	return preview_command(command)


func layout_snapshot() -> Dictionary:
	return {
		"layout": _state.get("layout", {}).duplicate(true),
		"selection": _state.get("selection", EMPTY_SELECTION).duplicate(true),
		"navigator": _state.get("navigator", {}).duplicate(true),
	}


func get_layout(document_kind: String, document_identifier: String) -> Dictionary:
	var collection := _layout_collection(document_kind)
	var bucket: Dictionary = _state.get("layout", {}).get(collection, {})
	return bucket.get(document_identifier, {}).duplicate(true)


func get_selection() -> Dictionary:
	return _state.get("selection", EMPTY_SELECTION).duplicate(true)


func get_navigator() -> Dictionary:
	return _state.get("navigator", {}).duplicate(true)


func navigation_projection(query: String = "") -> Dictionary:
	return DocumentProjection.navigation_projection(self, query, String(_state.get("navigator", {}).get("path", "")))


func project_navigation(query: String = "") -> Dictionary:
	return navigation_projection(query)


func apply_command(command: Variant) -> Dictionary:
	var data := _command_data(command)
	if data.is_empty():
		return _failure("LTS-DOCUMENT-003", "Command is not serializable", "command")
	var operation := _canonical_operation(String(data.get("operation", data.get("type", ""))))
	var mutation := String(data.get("mutation", data.get("mutation_class", "")))
	if mutation.is_empty():
		mutation = DocumentCommand.infer_mutation(operation)
	var payload: Dictionary = data.get("payload", {})
	if not payload is Dictionary or operation.is_empty():
		return _failure("LTS-DOCUMENT-004", "Command shape is invalid", "command")
	if mutation not in [MUTATION_SEMANTIC, MUTATION_LAYOUT, MUTATION_MIXED]:
		return _failure("LTS-DOCUMENT-005", "Unknown mutation class", "command.mutation")
	if is_read_only() or is_degraded():
		return _failure(String(get_diagnostic().get("code", "LTS-NATIVE-001")), String(get_diagnostic().get("message", "Document is read-only")), String(get_diagnostic().get("path", "native")))

	var candidate := _state.duplicate(true)
	var operation_result := _apply_operation(candidate, operation, payload, mutation)
	if not bool(operation_result.get("ok", false)):
		return _failure(
			String(operation_result.get("code", "LTS-DOCUMENT-006")),
			String(operation_result.get("message", "Command rejected")),
			String(operation_result.get("path", "document")),
			data
		)

	_state = candidate
	_revision += 1
	_state["revision"] = _revision
	var inverse_data: Dictionary = operation_result.get("inverse", {})
	var result := {
		"ok": true,
		"applied": true,
		"operation": operation,
		"mutation": mutation,
		"revision": _revision,
		"command": data.duplicate(true),
		"inverse": inverse_data.duplicate(true),
		"inverse_command": DocumentCommand.from_dict(inverse_data) if not inverse_data.is_empty() else null,
		"state": snapshot(),
	}
	return result


func apply_serialized_command(data: Dictionary) -> Dictionary:
	return apply_command(data)


func execute(command: Variant) -> Dictionary:
	return apply_command(command)


## Replace only the canonical document branch, preserving editor layout,
## selection, and navigator context by default.  This is intentionally a
## load/reload seam, not an editor mutation; callers should clear their
## history and establish a new save checkpoint after a successful reload.
func load_semantic_snapshot(source: Dictionary, preserve_layout: bool = true) -> Dictionary:
	var incoming: Dictionary = source.duplicate(true)
	if incoming.has("semantic") and incoming.get("semantic") is Dictionary:
		incoming = incoming["semantic"].duplicate(true)
	var replacement: Dictionary = {}
	if incoming.has("documents"):
		replacement = incoming
	else:
		return {
			"ok": false,
			"applied": false,
			"error": {"code": "LTS-DOCUMENT-067", "path": "documents", "severity": "error", "message": "Semantic snapshot has no documents"},
		}
	var layout_before: Dictionary = _state.get("layout", {}).duplicate(true)
	var selection_before: Dictionary = _state.get("selection", EMPTY_SELECTION).duplicate(true)
	var navigator_before: Dictionary = _state.get("navigator", {}).duplicate(true)
	var candidate := _empty_state()
	candidate["documents"] = _normalize_documents(replacement.get("documents", {}))
	candidate["catalog"] = _state.get("catalog", candidate["catalog"]).duplicate(true)
	candidate["native_extension_available"] = bool(_state.get("native_extension_available", true))
	candidate["read_only"] = bool(_state.get("read_only", false))
	candidate["degraded"] = bool(_state.get("degraded", false))
	candidate["diagnostic"] = _state.get("diagnostic", {}).duplicate(true)
	if preserve_layout:
		candidate["layout"] = layout_before
		candidate["selection"] = selection_before
		candidate["navigator"] = navigator_before
	_state = candidate
	_revision = 0
	_state["revision"] = _revision
	return {"ok": true, "applied": true, "revision": _revision, "state": snapshot()}


func load_external_snapshot(source: Dictionary, preserve_layout: bool = true) -> Dictionary:
	return load_semantic_snapshot(source, preserve_layout)


## Restore editor-only layout without touching semantic documents.  Opening a
## persisted layout uses this method directly; a user-triggered layout change
## should instead use LtsDocumentCommand.restore_layout through history.
func load_layout_snapshot(source: Dictionary) -> Dictionary:
	var incoming := source.duplicate(true)
	if incoming.has("layout") and incoming.get("layout") is Dictionary:
		var wrapped_layout: Dictionary = incoming["layout"]
		_state["layout"] = wrapped_layout.duplicate(true)
		if incoming.has("selection") and incoming.get("selection") is Dictionary:
			_state["selection"] = _normalize_selection(incoming["selection"])
		if incoming.has("navigator") and incoming.get("navigator") is Dictionary:
			_state["navigator"] = incoming["navigator"].duplicate(true)
	else:
		_state["layout"] = incoming
	_revision = 0
	_state["revision"] = _revision
	return {"ok": true, "applied": true, "revision": _revision, "state": snapshot()}


func replace_layout_snapshot(source: Dictionary) -> Dictionary:
	return load_layout_snapshot(source)


func undo_result(result: Dictionary) -> Dictionary:
	if not result.get("ok", false) or not result.get("inverse", {}) is Dictionary:
		return _failure("LTS-DOCUMENT-007", "Result has no inverse command", "command.inverse")
	return apply_command(result["inverse"])


func get_path_for(document_kind: String, document_identifier: String, element_kind: String = "", element_identifier: String = "", field_path: String = "") -> String:
	return DocumentProjection.element_path(document_kind, document_identifier, element_kind, element_identifier, field_path)


static func path_for(document_kind: String, document_identifier: String, element_kind: String = "", element_identifier: String = "", field_path: String = "") -> String:
	return DocumentProjection.element_path(document_kind, document_identifier, element_kind, element_identifier, field_path)


static func finding_path(document_kind: String, document_identifier: String, element_kind: String = "", element_identifier: String = "", field_path: String = "") -> String:
	return DocumentProjection.finding_path(document_kind, document_identifier, element_kind, element_identifier, field_path)


static func remap_identifier(identifier: String, existing_identifiers: Variant = [], suffix: String = "_copy") -> String:
	var used := _identifier_set(existing_identifiers)
	var base := identifier if not identifier.is_empty() else "item"
	var candidate := base + suffix
	var index := 2
	while used.has(candidate):
		candidate = "%s%s_%d" % [base, suffix, index]
		index += 1
	return candidate


static func remap_identifiers(identifiers: Variant, existing_identifiers: Variant = [], suffix: String = "_copy") -> Dictionary:
	var result: Dictionary = {}
	var used := _identifier_set(existing_identifiers)
	var values: Array = []
	if identifiers is Array or identifiers is PackedStringArray:
		for value in identifiers:
			values.append(String(value))
	elif identifiers is Dictionary:
		for value in identifiers.keys():
			values.append(String(value))
	values.sort()
	for identifier in values:
		if result.has(identifier):
			continue
		var candidate: String = identifier if not identifier.is_empty() else "item"
		candidate += suffix
		var index := 2
		while used.has(candidate):
			candidate = "%s%s_%d" % [identifier if not identifier.is_empty() else "item", suffix, index]
			index += 1
		result[identifier] = candidate
		used[candidate] = true
	return result


static func remap_fragment(fragment: Dictionary, existing_node_identifiers: Variant = [], existing_edge_identifiers: Variant = [], suffix: String = "_copy") -> Dictionary:
	var result := fragment.duplicate(true)
	var nodes: Array = result.get("nodes", []).duplicate(true)
	var edges: Array = result.get("edges", []).duplicate(true)
	var node_ids: Array = []
	var edge_ids: Array = []
	for node in nodes:
		if node is Dictionary:
			node_ids.append(String(node.get("identifier", "")))
	for edge in edges:
		if edge is Dictionary:
			edge_ids.append(String(edge.get("identifier", "")))
	var node_map := remap_identifiers(node_ids, existing_node_identifiers, suffix)
	var edge_map := remap_identifiers(edge_ids, existing_edge_identifiers, suffix)
	for node in nodes:
		if not node is Dictionary:
			continue
		var old_id := String(node.get("identifier", ""))
		if node_map.has(old_id):
			node["identifier"] = node_map[old_id]
	for edge in edges:
		if not edge is Dictionary:
			continue
		var old_edge_id := String(edge.get("identifier", ""))
		if edge_map.has(old_edge_id):
			edge["identifier"] = edge_map[old_edge_id]
		var from_id := String(edge.get("from_node_identifier", ""))
		var to_id := String(edge.get("to_node_identifier", ""))
		if node_map.has(from_id):
			edge["from_node_identifier"] = node_map[from_id]
		if node_map.has(to_id):
			edge["to_node_identifier"] = node_map[to_id]
	result["nodes"] = nodes
	result["edges"] = edges
	result["node_id_map"] = node_map
	result["edge_id_map"] = edge_map
	result["id_map"] = {"nodes": node_map, "edges": edge_map}
	return result


static func remap_conversation_fragment(fragment: Dictionary, existing_step_identifiers: Variant = [], suffix: String = "_copy") -> Dictionary:
	var result := fragment.duplicate(true)
	var steps: Array = result.get("steps", []).duplicate(true)
	var step_ids: Array = []
	for step in steps:
		if step is Dictionary:
			step_ids.append(String(step.get("identifier", "")))
	var step_map := remap_identifiers(step_ids, existing_step_identifiers, suffix)
	for step in steps:
		if not step is Dictionary:
			continue
		var old_id := String(step.get("identifier", ""))
		if step_map.has(old_id):
			step["identifier"] = step_map[old_id]
		for key in ["next_step_identifier", "true_step_identifier", "false_step_identifier", "success_step_identifier", "failure_step_identifier", "target_step_identifier"]:
			var target := String(step.get(key, ""))
			if step_map.has(target):
				step[key] = step_map[target]
		var choices: Array = step.get("choices", []).duplicate(true)
		for choice in choices:
			if choice is Dictionary:
				var target := String(choice.get("target_step_identifier", ""))
				if step_map.has(target):
					choice["target_step_identifier"] = step_map[target]
			step["choices"] = choices
	result["steps"] = steps
	result["step_id_map"] = step_map
	result["id_map"] = {"steps": step_map}
	return result


func _empty_state() -> Dictionary:
	return {
		"schema_version": DOCUMENT_SCHEMA_VERSION,
		"native_extension_available": true,
		"read_only": false,
		"degraded": false,
		"diagnostic": {},
		"catalog": {
			"identifier": "",
			"schema_version": 1,
			"source_path": "",
			"entries": [],
		},
		"documents": {
			"levels": {},
			"task_graphs": {},
			"conversations": {},
			"speakers": {},
			"providers": {},
		},
		"selection": EMPTY_SELECTION.duplicate(true),
		"navigator": {
			"query": "",
			"path": "",
			"resource_kind": "",
			"resource_identifier": "",
		},
		"layout": {
			"graphs": {},
			"conversations": {},
			"levels": {},
			"resources": {},
			"panes": {},
		},
		"revision": 0,
	}


func _normalize_state(source: Dictionary) -> Dictionary:
	var candidate := _empty_state()
	for key in ["schema_version", "native_extension_available", "read_only", "degraded", "diagnostic", "catalog", "selection", "navigator", "layout"]:
		if source.has(key):
			candidate[key] = source[key].duplicate(true) if source[key] is Array or source[key] is Dictionary else source[key]
	candidate["documents"] = _normalize_documents(source.get("documents", {}))
	candidate["revision"] = int(source.get("revision", 0))
	if bool(candidate.get("degraded", false)) or not bool(candidate.get("native_extension_available", true)):
		candidate["read_only"] = true
	return candidate


func _normalize_documents(source: Variant) -> Dictionary:
	var documents: Dictionary = {
		"levels": {},
		"task_graphs": {},
		"conversations": {},
		"speakers": {},
		"providers": {},
	}
	if not source is Dictionary:
		return documents
	for key in source:
		var storage_kind := _storage_kind(String(key))
		if not documents.has(storage_kind):
			continue
		var bucket = source[key]
		if bucket is Dictionary:
			for identifier in bucket:
				var document: Dictionary = bucket[identifier]
				if document is Dictionary:
					documents[storage_kind][String(identifier)] = document.duplicate(true)
		elif bucket is Array:
			for document in bucket:
				if not document is Dictionary:
					continue
				var identifier := String(document.get("identifier", ""))
				if not identifier.is_empty():
					documents[storage_kind][identifier] = document.duplicate(true)
	return documents


func _command_data(command: Variant) -> Dictionary:
	if command is DocumentCommand:
		return command.to_dict()
	if command is Dictionary:
		return command.duplicate(true)
	if command is Object and command.has_method("to_dict"):
		var value = command.call("to_dict")
		return value.duplicate(true) if value is Dictionary else {}
	return {}


func _canonical_operation(operation: String) -> String:
	match operation:
		"catalog.navigate", "catalog_navigation", "navigate":
			return "navigate_catalog"
		"select", "selection.set":
			return "set_selection"
		"edit_field", "field.set", "set_document_field":
			return "set_field"
		"create_node", "add_task_node", "node.add":
			return "add_node"
		"delete_node", "remove_node", "node.remove":
			return "remove_nodes"
		"connect", "add_task_edge", "edge.add":
			return "add_edge"
		"disconnect", "delete_edge", "edge.remove":
			return "remove_edge"
		"create_step", "add_conversation_step", "step.add":
			return "add_step"
		"delete_step", "step.remove":
			return "remove_step"
		"create_choice", "add_conversation_choice", "choice.add":
			return "add_choice"
		"delete_choice", "choice.remove":
			return "remove_choice"
		"move_node", "node.move", "layout.set":
			return "set_layout"
		"frame.set", "node.frame":
			return "set_layout"
		"layout.batch", "set_layout_batch":
			return "set_layout_batch"
		"layout.restore", "restore_layout":
			return "restore_layout"
		"arrange", "auto_arrange", "layout.auto_arrange":
			return "auto_arrange"
		"paste", "paste_fragment", "graph.paste", "duplicate_nodes", "graph.duplicate":
			return "paste_fragment"
		_:
			return operation


func _apply_operation(state: Dictionary, operation: String, payload: Dictionary, mutation: String) -> Dictionary:
	match operation:
		"batch":
			return _apply_batch(state, payload)
		"restore_state":
			return _apply_restore_state(state, payload)
		"navigate_catalog":
			return _apply_navigate(state, payload)
		"set_selection":
			return _apply_selection(state, payload)
		"set_field":
			return _apply_set_field(state, payload)
		"add_node":
			return _apply_add_node(state, payload)
		"remove_nodes":
			return _apply_remove_nodes(state, payload)
		"restore_graph_document":
			return _apply_restore_graph_document(state, payload)
		"add_edge":
			return _apply_add_edge(state, payload)
		"remove_edge":
			return _apply_remove_edge(state, payload)
		"add_step":
			return _apply_add_step(state, payload)
		"remove_step":
			return _apply_remove_step(state, payload)
		"restore_conversation_document":
			return _apply_restore_conversation_document(state, payload)
		"add_choice":
			return _apply_add_choice(state, payload)
		"remove_choice":
			return _apply_remove_choice(state, payload)
		"set_layout":
			return _apply_layout(state, payload)
		"set_layout_batch":
			return _apply_layout_batch(state, payload)
		"restore_layout":
			return _apply_restore_layout(state, payload)
		"auto_arrange":
			return _apply_auto_arrange(state, payload)
		"paste_fragment":
			return _apply_paste_fragment(state, payload)
		_:
			return _op_failure("LTS-DOCUMENT-008", "Unsupported document command '%s'" % operation, "command.operation")


func _apply_batch(state: Dictionary, payload: Dictionary) -> Dictionary:
	var commands = payload.get("commands", [])
	if not commands is Array or commands.is_empty():
		return _op_failure("LTS-DOCUMENT-009", "Batch command has no commands", "command.payload.commands")
	var inverses: Array = []
	for item in commands:
		var data := _command_data(item)
		if data.is_empty():
			return _op_failure("LTS-DOCUMENT-010", "Batch contains a non-serializable command", "command.payload.commands")
		var op := _canonical_operation(String(data.get("operation", data.get("type", ""))))
		var child_payload: Dictionary = data.get("payload", {})
		if not child_payload is Dictionary:
			return _op_failure("LTS-DOCUMENT-011", "Batch child payload is invalid", "command.payload.commands")
		var child_mutation := String(data.get("mutation", data.get("mutation_class", "")))
		if child_mutation.is_empty():
			child_mutation = DocumentCommand.infer_mutation(op)
		var result := _apply_operation(state, op, child_payload, child_mutation)
		if not result.get("ok", false):
			return result
		inverses.push_front(result.get("inverse", {}))
	return {
		"ok": true,
		"inverse": DocumentCommand.batch(inverses).to_dict(),
	}


func _apply_restore_state(state: Dictionary, payload: Dictionary) -> Dictionary:
	var replacement = payload.get("state", null)
	if not replacement is Dictionary or not replacement.has("documents"):
		return _op_failure("LTS-DOCUMENT-012", "Restore payload has no document state", "command.payload.state")
	var previous := state.duplicate(true)
	# Do not mutate `state` in place before the outer candidate is committed.
	state.clear()
	for key in replacement:
		state[key] = replacement[key].duplicate(true) if replacement[key] is Array or replacement[key] is Dictionary else replacement[key]
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous).to_dict()}


func _apply_navigate(state: Dictionary, payload: Dictionary) -> Dictionary:
	var path := String(payload.get("path", payload.get("selected_path", "")))
	var old: Dictionary = state.get("navigator", {}).duplicate(true)
	var navigator: Dictionary = state["navigator"].duplicate(true)
	navigator["path"] = path
	navigator["query"] = String(payload.get("query", navigator.get("query", "")))
	navigator["resource_kind"] = String(payload.get("resource_kind", navigator.get("resource_kind", "")))
	navigator["resource_identifier"] = String(payload.get("resource_identifier", navigator.get("resource_identifier", "")))
	state["navigator"] = navigator
	return {
		"ok": true,
		"inverse": DocumentCommand.navigate_catalog(old.get("path", ""), old.get("resource_kind", ""), old.get("resource_identifier", ""), old.get("query", "")).to_dict(),
	}


func _apply_selection(state: Dictionary, payload: Dictionary) -> Dictionary:
	var old: Dictionary = state.get("selection", EMPTY_SELECTION).duplicate(true)
	var selection: Dictionary = payload.get("selection", payload)
	if not selection is Dictionary:
		return _op_failure("LTS-DOCUMENT-013", "Selection payload is invalid", "selection")
	var normalized := _normalize_selection(selection)
	var validation := _validate_selection(state, normalized)
	if not validation.get("ok", false):
		return validation
	state["selection"] = normalized
	return {"ok": true, "inverse": DocumentCommand.set_selection(old).to_dict()}


func _apply_set_field(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var kind := _storage_kind(String(payload.get("document_kind", payload.get("kind", ""))))
	var identifier := String(payload.get("document_identifier", payload.get("identifier", "")))
	var bucket: Dictionary = state.get("documents", {}).get(kind, {})
	if kind.is_empty() or identifier.is_empty() or not bucket.has(identifier):
		return _op_failure("LTS-DOCUMENT-014", "Document is not open", DocumentProjection.document_path(kind, identifier))
	var raw_path = payload.get("field_path", payload.get("path", []))
	var path := _path_segments(raw_path)
	if path.is_empty():
		return _op_failure("LTS-DOCUMENT-015", "Field path is empty", DocumentProjection.document_path(kind, identifier))
	var document: Dictionary = bucket[identifier].duplicate(true)
	var expanded := _expand_selector_path(document, path)
	if not expanded.get("ok", false):
		return _op_failure("LTS-DOCUMENT-016", String(expanded.get("message", "Field path is invalid")), DocumentProjection.element_path(kind, identifier, "", "", str(payload.get("field_path", ""))))
	var path_values: Array = expanded["path"]
	if path_values.is_empty() or String(path_values[0]) == "layout":
		return _op_failure("LTS-DOCUMENT-017", "Layout fields must use a layout command", DocumentProjection.element_path(kind, identifier, "", "", str(payload.get("field_path", ""))))
	if _contains_non_serializable_marker(payload.get("value", null)):
		return _op_failure("LTS-DOCUMENT-062", "Field values cannot contain live engine objects", DocumentProjection.element_path(kind, identifier, "", "", str(payload.get("field_path", ""))))
	var set_result := _set_mutable_path(document, path_values, _serializable_value(payload.get("value", null)))
	if not set_result.get("ok", false):
		return _op_failure("LTS-DOCUMENT-018", String(set_result.get("message", "Field does not exist")), DocumentProjection.element_path(kind, identifier, "", "", str(payload.get("field_path", ""))))
	bucket[identifier] = document
	state["documents"][kind] = bucket
	var inverse: Dictionary
	if bool(set_result.get("had_value", true)):
		inverse = DocumentCommand.set_field(String(kind), identifier, path_values, set_result.get("old_value", null)).to_dict()
	else:
		inverse = DocumentCommand.restore_state(previous_state).to_dict()
	return {"ok": true, "inverse": inverse}


func _apply_add_node(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var graph_identifier := String(payload.get("graph_identifier", payload.get("document_identifier", "")))
	var graph: Dictionary = state.get("documents", {}).get("task_graphs", {}).get(graph_identifier, {})
	if graph.is_empty():
		return _op_failure("LTS-DOCUMENT-019", "Task graph is not open", DocumentProjection.document_path("task_graph", graph_identifier))
	var node = payload.get("node", {})
	if not node is Dictionary:
		return _op_failure("LTS-DOCUMENT-020", "Node payload is invalid", DocumentProjection.document_path("task_graph", graph_identifier))
	if _contains_non_serializable_marker(node):
		return _op_failure("LTS-DOCUMENT-063", "Node payload cannot contain live engine objects", DocumentProjection.document_path("task_graph", graph_identifier))
	node = _serializable_value(node)
	var node_identifier := String(node.get("identifier", ""))
	if node_identifier.is_empty():
		return _op_failure("LTS-DOCUMENT-021", "Node identifier is required", DocumentProjection.document_path("task_graph", graph_identifier))
	if _find_by_identifier(graph.get("nodes", []), node_identifier) != -1:
		return _op_failure("LTS-DOCUMENT-022", "Node identifier already exists", DocumentProjection.element_path("task_graph", graph_identifier, "node", node_identifier))
	if not node.has("ports"):
		node["ports"] = []
	graph["nodes"] = graph.get("nodes", []).duplicate(true)
	graph["nodes"].append(node)
	state["documents"]["task_graphs"][graph_identifier] = graph
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_remove_nodes(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var graph_identifier := String(payload.get("graph_identifier", payload.get("document_identifier", "")))
	var graph: Dictionary = state.get("documents", {}).get("task_graphs", {}).get(graph_identifier, {})
	if graph.is_empty():
		return _op_failure("LTS-DOCUMENT-023", "Task graph is not open", DocumentProjection.document_path("task_graph", graph_identifier))
	var requested: Array = []
	var raw_requested = payload.get("node_identifiers", null)
	if not raw_requested is Array:
		raw_requested = [payload.get("node_identifier", "")]
	for value in raw_requested:
		var id := String(value)
		if not id.is_empty() and not requested.has(id):
			requested.append(id)
	if requested.is_empty():
		return _op_failure("LTS-DOCUMENT-024", "No nodes selected", DocumentProjection.document_path("task_graph", graph_identifier))
	var old_graph := graph.duplicate(true)
	var existing: Dictionary = {}
	for node in graph.get("nodes", []):
		if node is Dictionary:
			existing[String(node.get("identifier", ""))] = true
	for id in requested:
		if not existing.has(id):
			return _op_failure("LTS-DOCUMENT-025", "Node does not exist", DocumentProjection.element_path("task_graph", graph_identifier, "node", id))
	var remaining_nodes: Array = []
	for node in graph.get("nodes", []):
		if not requested.has(String(node.get("identifier", ""))):
			remaining_nodes.append(node)
	var removed_edges: Array = []
	var remaining_edges: Array = []
	for edge in graph.get("edges", []):
		var from_id := String(edge.get("from_node_identifier", ""))
		var to_id := String(edge.get("to_node_identifier", ""))
		if requested.has(from_id) or requested.has(to_id):
			removed_edges.append(edge)
		else:
			remaining_edges.append(edge)
	graph["nodes"] = remaining_nodes
	graph["edges"] = remaining_edges
	state["documents"]["task_graphs"][graph_identifier] = graph
	var old_layout: Dictionary = state.get("layout", {}).get("graphs", {}).get(graph_identifier, {}).duplicate(true)
	var graph_layout := old_layout.duplicate(true)
	var layout_nodes: Dictionary = graph_layout.get("nodes", {})
	for id in requested:
		layout_nodes.erase(id)
	graph_layout["nodes"] = layout_nodes
	state["layout"]["graphs"][graph_identifier] = graph_layout
	var old_selection: Dictionary = state.get("selection", EMPTY_SELECTION).duplicate(true)
	if old_selection.get("resource_kind", "") in [KIND_TASK_GRAPH, "task_graphs"] and old_selection.get("resource_identifier", "") == graph_identifier and requested.has(String(old_selection.get("element_identifier", ""))):
		state["selection"] = EMPTY_SELECTION.duplicate(true)
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_restore_graph_document(state: Dictionary, payload: Dictionary) -> Dictionary:
	var graph_identifier := String(payload.get("graph_identifier", ""))
	var old_graph: Dictionary = state.get("documents", {}).get("task_graphs", {}).get(graph_identifier, {}).duplicate(true)
	var old_layout: Dictionary = state.get("layout", {}).get("graphs", {}).get(graph_identifier, {}).duplicate(true)
	var old_selection: Dictionary = state.get("selection", EMPTY_SELECTION).duplicate(true)
	var graph = payload.get("graph", null)
	if not graph is Dictionary:
		return _op_failure("LTS-DOCUMENT-026", "Graph restore payload is invalid", DocumentProjection.document_path("task_graph", graph_identifier))
	state["documents"]["task_graphs"][graph_identifier] = graph.duplicate(true)
	state["layout"]["graphs"][graph_identifier] = payload.get("layout", {}).duplicate(true)
	state["selection"] = payload.get("selection", EMPTY_SELECTION).duplicate(true)
	return {
		"ok": true,
		"inverse": DocumentCommand.restore_state(_state_with_graph_replacement(state, graph_identifier, old_graph, old_layout, old_selection)).to_dict(),
	}


func _state_with_graph_replacement(state: Dictionary, graph_identifier: String, graph: Dictionary, layout: Dictionary, selection: Dictionary) -> Dictionary:
	var replacement := state.duplicate(true)
	replacement["documents"]["task_graphs"][graph_identifier] = graph.duplicate(true)
	replacement["layout"]["graphs"][graph_identifier] = layout.duplicate(true)
	replacement["selection"] = selection.duplicate(true)
	return replacement


func _apply_add_edge(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var graph_identifier := String(payload.get("graph_identifier", payload.get("document_identifier", "")))
	var graph: Dictionary = state.get("documents", {}).get("task_graphs", {}).get(graph_identifier, {})
	if graph.is_empty():
		return _op_failure("LTS-DOCUMENT-027", "Task graph is not open", DocumentProjection.document_path("task_graph", graph_identifier))
	var edge = payload.get("edge", {})
	if not edge is Dictionary:
		return _op_failure("LTS-DOCUMENT-028", "Edge payload is invalid", DocumentProjection.document_path("task_graph", graph_identifier))
	if _contains_non_serializable_marker(edge):
		return _op_failure("LTS-DOCUMENT-064", "Edge payload cannot contain live engine objects", DocumentProjection.document_path("task_graph", graph_identifier))
	edge = _serializable_value(edge)
	var edge_identifier := String(edge.get("identifier", ""))
	if edge_identifier.is_empty():
		return _op_failure("LTS-DOCUMENT-029", "Edge identifier is required", DocumentProjection.document_path("task_graph", graph_identifier))
	if _find_by_identifier(graph.get("edges", []), edge_identifier) != -1:
		return _op_failure("LTS-DOCUMENT-030", "Edge identifier already exists", DocumentProjection.element_path("task_graph", graph_identifier, "edge", edge_identifier))
	var endpoint_result := _validate_edge_endpoints(graph, edge, graph_identifier)
	if not endpoint_result.get("ok", false):
		return endpoint_result
	var duplicate_result := _edge_duplicate_result(graph.get("edges", []), edge, graph_identifier)
	if not duplicate_result.get("ok", false):
		return duplicate_result
	var edges: Array = graph.get("edges", []).duplicate(true)
	var index := int(payload.get("index", edges.size()))
	index = clampi(index, 0, edges.size())
	edges.insert(index, edge)
	graph["edges"] = edges
	state["documents"]["task_graphs"][graph_identifier] = graph
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_remove_edge(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var graph_identifier := String(payload.get("graph_identifier", payload.get("document_identifier", "")))
	var edge_identifier := String(payload.get("edge_identifier", payload.get("identifier", "")))
	var graph: Dictionary = state.get("documents", {}).get("task_graphs", {}).get(graph_identifier, {})
	if graph.is_empty():
		return _op_failure("LTS-DOCUMENT-031", "Task graph is not open", DocumentProjection.document_path("task_graph", graph_identifier))
	var edges: Array = graph.get("edges", [])
	var index := _find_by_identifier(edges, edge_identifier)
	if index < 0:
		return _op_failure("LTS-DOCUMENT-032", "Edge does not exist", DocumentProjection.element_path("task_graph", graph_identifier, "edge", edge_identifier))
	var removed: Dictionary = edges[index].duplicate(true)
	edges = edges.duplicate(true)
	edges.remove_at(index)
	graph["edges"] = edges
	state["documents"]["task_graphs"][graph_identifier] = graph
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_add_step(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var conversation_identifier := String(payload.get("conversation_identifier", payload.get("document_identifier", "")))
	var conversation: Dictionary = state.get("documents", {}).get("conversations", {}).get(conversation_identifier, {})
	if conversation.is_empty():
		return _op_failure("LTS-DOCUMENT-033", "Conversation is not open", DocumentProjection.document_path("conversation", conversation_identifier))
	var step = payload.get("step", {})
	if not step is Dictionary:
		return _op_failure("LTS-DOCUMENT-034", "Conversation step payload is invalid", DocumentProjection.document_path("conversation", conversation_identifier))
	if _contains_non_serializable_marker(step):
		return _op_failure("LTS-DOCUMENT-065", "Conversation step payload cannot contain live engine objects", DocumentProjection.document_path("conversation", conversation_identifier))
	step = _serializable_value(step)
	var step_identifier := String(step.get("identifier", ""))
	if step_identifier.is_empty():
		return _op_failure("LTS-DOCUMENT-035", "Step identifier is required", DocumentProjection.document_path("conversation", conversation_identifier))
	if _find_by_identifier(conversation.get("steps", []), step_identifier) != -1:
		return _op_failure("LTS-DOCUMENT-036", "Step identifier already exists", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	if not step.has("choices"):
		step["choices"] = []
	var steps: Array = conversation.get("steps", []).duplicate(true)
	var index := clampi(int(payload.get("index", steps.size())), 0, steps.size())
	steps.insert(index, step)
	conversation["steps"] = steps
	state["documents"]["conversations"][conversation_identifier] = conversation
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_remove_step(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var conversation_identifier := String(payload.get("conversation_identifier", payload.get("document_identifier", "")))
	var step_identifier := String(payload.get("step_identifier", payload.get("identifier", "")))
	var conversation: Dictionary = state.get("documents", {}).get("conversations", {}).get(conversation_identifier, {})
	if conversation.is_empty():
		return _op_failure("LTS-DOCUMENT-037", "Conversation is not open", DocumentProjection.document_path("conversation", conversation_identifier))
	var index := _find_by_identifier(conversation.get("steps", []), step_identifier)
	if index < 0:
		return _op_failure("LTS-DOCUMENT-038", "Conversation step does not exist", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	var steps: Array = conversation.get("steps", []).duplicate(true)
	steps.remove_at(index)
	conversation["steps"] = steps
	state["documents"]["conversations"][conversation_identifier] = conversation
	var old_layout: Dictionary = state.get("layout", {}).get("conversations", {}).get(conversation_identifier, {}).duplicate(true)
	var conversation_layout := old_layout.duplicate(true)
	var step_layout: Dictionary = conversation_layout.get("steps", {})
	step_layout.erase(step_identifier)
	conversation_layout["steps"] = step_layout
	state["layout"]["conversations"][conversation_identifier] = conversation_layout
	var old_selection: Dictionary = state.get("selection", EMPTY_SELECTION).duplicate(true)
	if old_selection.get("resource_kind", "") in [KIND_CONVERSATION, "conversations"] and old_selection.get("resource_identifier", "") == conversation_identifier and old_selection.get("element_identifier", "") == step_identifier:
		state["selection"] = EMPTY_SELECTION.duplicate(true)
	return {
		"ok": true,
		"inverse": DocumentCommand.restore_state(previous_state).to_dict(),
	}


func _apply_restore_conversation_document(state: Dictionary, payload: Dictionary) -> Dictionary:
	var conversation_identifier := String(payload.get("conversation_identifier", ""))
	var conversation = payload.get("conversation", null)
	if not conversation is Dictionary:
		return _op_failure("LTS-DOCUMENT-039", "Conversation restore payload is invalid", DocumentProjection.document_path("conversation", conversation_identifier))
	var old_conversation: Dictionary = state.get("documents", {}).get("conversations", {}).get(conversation_identifier, {}).duplicate(true)
	var old_layout: Dictionary = state.get("layout", {}).get("conversations", {}).get(conversation_identifier, {}).duplicate(true)
	var old_selection: Dictionary = state.get("selection", EMPTY_SELECTION).duplicate(true)
	state["documents"]["conversations"][conversation_identifier] = conversation.duplicate(true)
	state["layout"]["conversations"][conversation_identifier] = payload.get("layout", {}).duplicate(true)
	state["selection"] = payload.get("selection", EMPTY_SELECTION).duplicate(true)
	return {
		"ok": true,
		"inverse": DocumentCommand.restore_state(_state_with_conversation_replacement(state, conversation_identifier, old_conversation, old_layout, old_selection)).to_dict(),
	}


func _state_with_conversation_replacement(state: Dictionary, conversation_identifier: String, conversation: Dictionary, layout: Dictionary, selection: Dictionary) -> Dictionary:
	var replacement := state.duplicate(true)
	replacement["documents"]["conversations"][conversation_identifier] = conversation.duplicate(true)
	replacement["layout"]["conversations"][conversation_identifier] = layout.duplicate(true)
	replacement["selection"] = selection.duplicate(true)
	return replacement


func _apply_add_choice(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var conversation_identifier := String(payload.get("conversation_identifier", payload.get("document_identifier", "")))
	var step_identifier := String(payload.get("step_identifier", ""))
	var conversation: Dictionary = state.get("documents", {}).get("conversations", {}).get(conversation_identifier, {})
	if conversation.is_empty():
		return _op_failure("LTS-DOCUMENT-040", "Conversation is not open", DocumentProjection.document_path("conversation", conversation_identifier))
	var step_index := _find_by_identifier(conversation.get("steps", []), step_identifier)
	if step_index < 0:
		return _op_failure("LTS-DOCUMENT-041", "Conversation step does not exist", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	var choice = payload.get("choice", {})
	if not choice is Dictionary:
		return _op_failure("LTS-DOCUMENT-042", "Conversation choice payload is invalid", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	if _contains_non_serializable_marker(choice):
		return _op_failure("LTS-DOCUMENT-066", "Conversation choice payload cannot contain live engine objects", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	choice = _serializable_value(choice)
	var choice_identifier := String(choice.get("identifier", ""))
	if choice_identifier.is_empty():
		return _op_failure("LTS-DOCUMENT-043", "Choice identifier is required", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	var step: Dictionary = conversation["steps"][step_index]
	var choices: Array = step.get("choices", [])
	if _find_by_identifier(choices, choice_identifier) != -1:
		return _op_failure("LTS-DOCUMENT-044", "Choice identifier already exists", DocumentProjection.element_path("conversation", conversation_identifier, "choice", choice_identifier))
	if not choice.has("conditions"):
		choice["conditions"] = []
	choices = choices.duplicate(true)
	var index := clampi(int(payload.get("index", choices.size())), 0, choices.size())
	choices.insert(index, choice)
	step["choices"] = choices
	conversation["steps"][step_index] = step
	state["documents"]["conversations"][conversation_identifier] = conversation
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_remove_choice(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var conversation_identifier := String(payload.get("conversation_identifier", payload.get("document_identifier", "")))
	var step_identifier := String(payload.get("step_identifier", ""))
	var choice_identifier := String(payload.get("choice_identifier", payload.get("identifier", "")))
	var conversation: Dictionary = state.get("documents", {}).get("conversations", {}).get(conversation_identifier, {})
	if conversation.is_empty():
		return _op_failure("LTS-DOCUMENT-045", "Conversation is not open", DocumentProjection.document_path("conversation", conversation_identifier))
	var step_index := _find_by_identifier(conversation.get("steps", []), step_identifier)
	if step_index < 0:
		return _op_failure("LTS-DOCUMENT-046", "Conversation step does not exist", DocumentProjection.element_path("conversation", conversation_identifier, "step", step_identifier))
	var step: Dictionary = conversation["steps"][step_index]
	var choice_index := _find_by_identifier(step.get("choices", []), choice_identifier)
	if choice_index < 0:
		return _op_failure("LTS-DOCUMENT-047", "Conversation choice does not exist", DocumentProjection.element_path("conversation", conversation_identifier, "choice", choice_identifier))
	var old_choice: Dictionary = step["choices"][choice_index].duplicate(true)
	var choices: Array = step["choices"].duplicate(true)
	choices.remove_at(choice_index)
	step["choices"] = choices
	conversation["steps"][step_index] = step
	state["documents"]["conversations"][conversation_identifier] = conversation
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_layout(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var resource_kind := String(payload.get("resource_kind", payload.get("document_kind", "")))
	var resource_identifier := String(payload.get("resource_identifier", payload.get("document_identifier", "")))
	var element_kind := String(payload.get("element_kind", "")).to_lower()
	var element_identifier := String(payload.get("element_identifier", ""))
	var field_name := String(payload.get("field_name", ""))
	var value := _serializable_value(payload.get("value", null))
	var layout: Dictionary = state.get("layout", {}).duplicate(true)
	var collection := _layout_collection(resource_kind)
	if element_kind == "pane" or (resource_kind.is_empty() and element_identifier != ""):
		var panes: Dictionary = layout.get("panes", {})
		panes[element_identifier] = value
		layout["panes"] = panes
	else:
		if resource_identifier.is_empty():
			return _op_failure("LTS-DOCUMENT-048", "Layout resource identifier is required", "layout.resource_identifier")
		var resources: Dictionary = layout.get(collection, {})
		var resource_layout: Dictionary = resources.get(resource_identifier, {}).duplicate(true)
		if element_kind.is_empty():
			if value is Dictionary:
				resource_layout = value.duplicate(true)
			else:
				return _op_failure("LTS-DOCUMENT-049", "Resource layout must be a dictionary", DocumentProjection.document_path(resource_kind, resource_identifier))
		else:
			var category := _layout_element_category(element_kind)
			var category_values: Dictionary = resource_layout.get(category, {}).duplicate(true)
			if element_identifier.is_empty():
				return _op_failure("LTS-DOCUMENT-050", "Layout element identifier is required", DocumentProjection.document_path(resource_kind, resource_identifier))
			var element_layout: Dictionary = category_values.get(element_identifier, {}).duplicate(true)
			if field_name.is_empty():
				if value is Dictionary:
					element_layout = value.duplicate(true)
				else:
					return _op_failure("LTS-DOCUMENT-051", "Element layout must be a dictionary", DocumentProjection.element_path(resource_kind, resource_identifier, element_kind, element_identifier))
			else:
				element_layout[field_name] = value
			category_values[element_identifier] = element_layout
			resource_layout[category] = category_values
		resources[resource_identifier] = resource_layout
		layout[collection] = resources
	state["layout"] = layout
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_layout_batch(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var resource_kind := String(payload.get("resource_kind", payload.get("document_kind", "")))
	var resource_identifier := String(payload.get("resource_identifier", payload.get("document_identifier", "")))
	if resource_identifier.is_empty():
		return _op_failure("LTS-DOCUMENT-068", "Layout resource identifier is required", "layout.resource_identifier")
	var values = payload.get("values", {})
	if not values is Dictionary:
		return _op_failure("LTS-DOCUMENT-069", "Layout batch values must be a dictionary", DocumentProjection.document_path(resource_kind, resource_identifier))
	var layout: Dictionary = state.get("layout", {}).duplicate(true)
	var collection := _layout_collection(resource_kind)
	var resources: Dictionary = layout.get(collection, {}).duplicate(true)
	var resource_layout: Dictionary = resources.get(resource_identifier, {}).duplicate(true)
	for category_key in values:
		var category_name := String(category_key)
		var category_values = values[category_key]
		if not category_values is Dictionary:
			continue
		var category: Dictionary = resource_layout.get(category_name, {}).duplicate(true)
		for element_identifier in category_values:
			var element_value = category_values[element_identifier]
			var serialized_value = _serializable_value(element_value)
			if category_name in ["nodes", "steps", "edges", "frames"] and not serialized_value is Dictionary:
				serialized_value = {"position": serialized_value}
			category[String(element_identifier)] = serialized_value
		resource_layout[category_name] = category
	resources[resource_identifier] = resource_layout
	layout[collection] = resources
	state["layout"] = layout
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_restore_layout(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var replacement = payload.get("layout", null)
	if not replacement is Dictionary:
		return _op_failure("LTS-DOCUMENT-070", "Layout restore payload is invalid", "command.payload.layout")
	if replacement.has("layout") and replacement.get("layout") is Dictionary:
		state["layout"] = replacement["layout"].duplicate(true)
		if replacement.has("selection") and replacement.get("selection") is Dictionary:
			state["selection"] = _normalize_selection(replacement["selection"])
		if replacement.has("navigator") and replacement.get("navigator") is Dictionary:
			state["navigator"] = replacement["navigator"].duplicate(true)
	else:
		state["layout"] = replacement.duplicate(true)
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _apply_auto_arrange(state: Dictionary, payload: Dictionary) -> Dictionary:
	var graph_identifier := String(payload.get("graph_identifier", payload.get("resource_identifier", "")))
	var positions = payload.get("positions", {})
	if graph_identifier.is_empty() or not positions is Dictionary:
		return _op_failure("LTS-DOCUMENT-071", "Auto-arrange requires a graph and position map", "layout.auto_arrange")
	return _apply_layout_batch(state, {
		"resource_kind": "task_graph",
		"resource_identifier": graph_identifier,
		"values": {"nodes": positions},
	})


func _apply_paste_fragment(state: Dictionary, payload: Dictionary) -> Dictionary:
	var previous_state := state.duplicate(true)
	var graph_identifier := String(payload.get("graph_identifier", payload.get("document_identifier", "")))
	var graphs: Dictionary = state.get("documents", {}).get("task_graphs", {})
	var graph: Dictionary = graphs.get(graph_identifier, {})
	if graph.is_empty():
		return _op_failure("LTS-DOCUMENT-072", "Task graph is not open", DocumentProjection.document_path("task_graph", graph_identifier))
	var source = payload.get("fragment", {})
	if not source is Dictionary:
		return _op_failure("LTS-DOCUMENT-073", "Clipboard fragment is invalid", DocumentProjection.document_path("task_graph", graph_identifier))
	var fragment: Dictionary = source.duplicate(true)
	var source_nodes: Array = fragment.get("nodes", []) if fragment.get("nodes", []) is Array else []
	var source_edges: Array = fragment.get("edges", []) if fragment.get("edges", []) is Array else []
	if source_nodes.is_empty():
		return _op_failure("LTS-DOCUMENT-074", "Clipboard fragment contains no nodes", DocumentProjection.document_path("task_graph", graph_identifier))
	var existing_nodes: Array = []
	var existing_edges: Array = []
	for item in graph.get("nodes", []):
		if item is Dictionary:
			existing_nodes.append(String(item.get("identifier", "")))
	for item in graph.get("edges", []):
		if item is Dictionary:
			existing_edges.append(String(item.get("identifier", "")))
	var remapped: Dictionary
	if bool(payload.get("preserve_identifiers", false)):
		var node_map: Dictionary = {}
		var edge_map: Dictionary = {}
		for item in source_nodes:
			if item is Dictionary:
				var node_id := String(item.get("identifier", ""))
				node_map[node_id] = node_id
		for item in source_edges:
			if item is Dictionary:
				var edge_id := String(item.get("identifier", ""))
				edge_map[edge_id] = edge_id
		remapped = fragment.duplicate(true)
		remapped["node_id_map"] = node_map
		remapped["edge_id_map"] = edge_map
	else:
		remapped = remap_fragment(fragment, existing_nodes, existing_edges, String(payload.get("suffix", "_copy")))
	var node_map: Dictionary = remapped.get("node_id_map", {})
	var edge_map: Dictionary = remapped.get("edge_id_map", {})
	var nodes: Array = graph.get("nodes", []).duplicate(true)
	var edges: Array = graph.get("edges", []).duplicate(true)
	var added_node_ids: Array = []
	for item in remapped.get("nodes", []):
		if not item is Dictionary:
			return _op_failure("LTS-DOCUMENT-075", "Clipboard node is invalid", DocumentProjection.document_path("task_graph", graph_identifier))
		var node: Dictionary = item.duplicate(true)
		var node_id := String(node.get("identifier", ""))
		if node_id.is_empty() or _find_by_identifier(nodes, node_id) != -1 or added_node_ids.has(node_id):
			return _op_failure("LTS-DOCUMENT-076", "Clipboard node identifier collides", DocumentProjection.element_path("task_graph", graph_identifier, "node", node_id))
		nodes.append(node)
		added_node_ids.append(node_id)
	for item in remapped.get("edges", []):
		if not item is Dictionary:
			return _op_failure("LTS-DOCUMENT-077", "Clipboard edge is invalid", DocumentProjection.document_path("task_graph", graph_identifier))
		var edge: Dictionary = item.duplicate(true)
		var edge_id := String(edge.get("identifier", ""))
		var from_id := String(edge.get("from_node_identifier", ""))
		var to_id := String(edge.get("to_node_identifier", ""))
		if edge_id.is_empty() or _find_by_identifier(edges, edge_id) != -1:
			return _op_failure("LTS-DOCUMENT-078", "Clipboard edge identifier collides", DocumentProjection.element_path("task_graph", graph_identifier, "edge", edge_id))
		if _find_by_identifier(nodes, from_id) < 0 or _find_by_identifier(nodes, to_id) < 0:
			return _op_failure("LTS-DOCUMENT-079", "Clipboard edge has a dangling endpoint", DocumentProjection.element_path("task_graph", graph_identifier, "edge", edge_id))
		var endpoint_result := _validate_edge_endpoints({"nodes": nodes, "edges": edges}, edge, graph_identifier)
		if not endpoint_result.get("ok", false):
			return endpoint_result
		edges.append(edge)
	graph["nodes"] = nodes
	graph["edges"] = edges
	state["documents"]["task_graphs"][graph_identifier] = graph
	var layout: Dictionary = state.get("layout", {}).duplicate(true)
	var graph_layout: Dictionary = layout.get("graphs", {}).get(graph_identifier, {}).duplicate(true)
	var layout_nodes: Dictionary = graph_layout.get("nodes", {}).duplicate(true)
	var offset := _vector2_from_variant(payload.get("position_offset", null))
	var source_layout = fragment.get("layout", {})
	if source_layout is Dictionary:
		var source_layout_nodes = source_layout.get("nodes", {})
		if source_layout_nodes is Dictionary:
			for old_id in source_layout_nodes:
				var new_id := String(node_map.get(String(old_id), String(old_id)))
				var node_layout = source_layout_nodes[old_id]
				if node_layout is Dictionary:
					var copied_layout: Dictionary = node_layout.duplicate(true)
					if copied_layout.has("position"):
						copied_layout["position"] = _offset_position(copied_layout["position"], offset)
					layout_nodes[new_id] = copied_layout
	for node_id in added_node_ids:
		if not layout_nodes.has(node_id):
			layout_nodes[node_id] = {"position": [float(offset.x), float(offset.y)]}
	graph_layout["nodes"] = layout_nodes
	layout["graphs"][graph_identifier] = graph_layout
	state["layout"] = layout
	var selection: Dictionary = state.get("selection", EMPTY_SELECTION).duplicate(true)
	if added_node_ids.size() == 1:
		selection = _normalize_selection({
			"resource_kind": "task_graph",
			"resource_identifier": graph_identifier,
			"element_kind": "node",
			"element_identifier": added_node_ids[0],
		})
	state["selection"] = selection
	return {"ok": true, "inverse": DocumentCommand.restore_state(previous_state).to_dict()}


func _validate_selection(state: Dictionary, selection: Dictionary) -> Dictionary:
	var resource_kind := String(selection.get("resource_kind", ""))
	var resource_identifier := String(selection.get("resource_identifier", ""))
	if resource_kind.is_empty() and resource_identifier.is_empty():
		return {"ok": true}
	var storage_kind := _storage_kind(resource_kind)
	var bucket: Dictionary = state.get("documents", {}).get(storage_kind, {})
	if not bucket.has(resource_identifier):
		return _op_failure("LTS-DOCUMENT-052", "Selected resource is not open", DocumentProjection.document_path(resource_kind, resource_identifier))
	var element_kind := String(selection.get("element_kind", "")).to_lower()
	var element_identifier := String(selection.get("element_identifier", ""))
	if element_kind.is_empty() or element_identifier.is_empty():
		return {"ok": true}
	var document: Dictionary = bucket[resource_identifier]
	var collection := _element_collection(element_kind)
	if collection.is_empty():
		return {"ok": true}
	if collection == "choices" and storage_kind == "conversations":
		for step in document.get("steps", []):
			if step is Dictionary and _find_by_identifier(step.get("choices", []), element_identifier) != -1:
				return {"ok": true}
		return _op_failure("LTS-DOCUMENT-053", "Selected conversation choice does not exist", DocumentProjection.element_path(resource_kind, resource_identifier, "choice", element_identifier))
	var values: Array = document.get(collection, [])
	if _find_by_identifier(values, element_identifier) == -1:
		return _op_failure("LTS-DOCUMENT-053", "Selected element does not exist", DocumentProjection.element_path(resource_kind, resource_identifier, element_kind, element_identifier))
	return {"ok": true}


func _normalize_selection(selection: Dictionary) -> Dictionary:
	var result := EMPTY_SELECTION.duplicate(true)
	for key in result.keys():
		if selection.has(key):
			result[key] = String(selection[key])
	# Accept the shorter names used by GraphEdit/timeline adapters.
	if result["resource_kind"].is_empty() and selection.has("kind"):
		result["resource_kind"] = String(selection["kind"])
	if result["resource_identifier"].is_empty() and selection.has("identifier"):
		result["resource_identifier"] = String(selection["identifier"])
	if result["element_kind"].is_empty() and selection.has("type"):
		result["element_kind"] = String(selection["type"])
	if result["element_identifier"].is_empty() and selection.has("element_id"):
		result["element_identifier"] = String(selection["element_id"])
	return result


func _validate_edge_endpoints(graph: Dictionary, edge: Dictionary, graph_identifier: String) -> Dictionary:
	var from_id := String(edge.get("from_node_identifier", ""))
	var from_port := String(edge.get("from_port_identifier", ""))
	var to_id := String(edge.get("to_node_identifier", ""))
	var to_port := String(edge.get("to_port_identifier", ""))
	if from_id.is_empty() or from_port.is_empty() or to_id.is_empty() or to_port.is_empty():
		return _op_failure("LTS-DOCUMENT-054", "Edge endpoints are required", DocumentProjection.element_path("task_graph", graph_identifier, "edge", String(edge.get("identifier", ""))))
	var from_index := _find_by_identifier(graph.get("nodes", []), from_id)
	var to_index := _find_by_identifier(graph.get("nodes", []), to_id)
	if from_index < 0:
		return _op_failure("LTS-DOCUMENT-055", "Edge source node does not exist", DocumentProjection.element_path("task_graph", graph_identifier, "node", from_id))
	if to_index < 0:
		return _op_failure("LTS-DOCUMENT-056", "Edge target node does not exist", DocumentProjection.element_path("task_graph", graph_identifier, "node", to_id))
	var from_node: Dictionary = graph["nodes"][from_index]
	var to_node: Dictionary = graph["nodes"][to_index]
	var source_port := _find_port(from_node.get("ports", []), from_port)
	var target_port := _find_port(to_node.get("ports", []), to_port)
	if source_port.is_empty():
		return _op_failure("LTS-DOCUMENT-057", "Edge source port does not exist", DocumentProjection.element_path("task_graph", graph_identifier, "node", from_id, "ports.%s" % from_port))
	if target_port.is_empty():
		return _op_failure("LTS-DOCUMENT-058", "Edge target port does not exist", DocumentProjection.element_path("task_graph", graph_identifier, "node", to_id, "ports.%s" % to_port))
	if not source_port.is_empty() and not target_port.is_empty():
		var source_direction := _port_direction(source_port)
		var target_direction := _port_direction(target_port)
		if source_direction == target_direction:
			return _op_failure("LTS-DOCUMENT-059", "Connections require an output and an input port", DocumentProjection.element_path("task_graph", graph_identifier, "edge", String(edge.get("identifier", ""))))
		var source_type := int(source_port.get("value_type", 0))
		var target_type := int(target_port.get("value_type", 0))
		if source_type != 0 and target_type != 0 and source_type != target_type:
			return _op_failure("LTS-DOCUMENT-060", "Connection port value types are incompatible", DocumentProjection.element_path("task_graph", graph_identifier, "edge", String(edge.get("identifier", ""))))
	return {"ok": true}


func _edge_duplicate_result(edges: Array, edge: Dictionary, graph_identifier: String) -> Dictionary:
	for existing in edges:
		if not existing is Dictionary:
			continue
		if String(existing.get("from_node_identifier", "")) == String(edge.get("from_node_identifier", "")) and String(existing.get("from_port_identifier", "")) == String(edge.get("from_port_identifier", "")) and String(existing.get("to_node_identifier", "")) == String(edge.get("to_node_identifier", "")) and String(existing.get("to_port_identifier", "")) == String(edge.get("to_port_identifier", "")):
			return _op_failure("LTS-DOCUMENT-061", "Connection already exists", DocumentProjection.element_path("task_graph", graph_identifier, "edge", String(edge.get("identifier", ""))))
	return {"ok": true}


func _find_port(ports: Variant, identifier: String) -> Dictionary:
	var values: Array = ports if ports is Array else []
	for port in values:
		if port is Dictionary and String(port.get("identifier", "")) == identifier:
			return port
	return {}


func _port_direction(port: Dictionary) -> int:
	var direction = port.get("direction", 1)
	if direction is String:
		return 0 if String(direction).to_lower() in ["input", "in"] else 1
	return int(direction)


func _find_by_identifier(values: Variant, identifier: String) -> int:
	if not values is Array:
		return -1
	for index in values.size():
		var value = values[index]
		if value is Dictionary and String(value.get("identifier", "")) == identifier:
			return index
	return -1


func _path_segments(raw_path: Variant) -> Array:
	if raw_path is Array:
		var result: Array = []
		for item in raw_path:
			# `str` accepts the mixed String/int selector produced by inverse
			# commands on every supported Godot 4.x build.  String(value) may
			# reject a Variant whose runtime value is a typed selector.
			result.append(str(item))
		return result
	var text := String(raw_path)
	if text.is_empty():
		return []
	if text.find("/") != -1:
		return text.split("/", false)
	return text.split(".", false)


func _expand_selector_path(root: Dictionary, path: Array) -> Dictionary:
	var expanded: Array = []
	var current: Variant = root
	var index := 0
	while index < path.size():
		if current is Dictionary:
			var key := String(path[index])
			if not current.has(key):
				if index == path.size() - 1:
					expanded.append(key)
					index += 1
					continue
				return {"ok": false, "message": "Field '%s' does not exist" % key}
			expanded.append(key)
			current = current[key]
			index += 1
			continue
		if current is Array:
			var match_index := -1
			var consumed := 0
			# Local identifiers may contain dots.  Choose the longest existing
			# identifier prefix so `nodes.node.alpha.field` remains unambiguous.
			for candidate_index in current.size():
				var item = current[candidate_index]
				if not item is Dictionary:
					continue
				var item_identifier := String(item.get("identifier", ""))
				if item_identifier.is_empty():
					continue
				var item_segments := item_identifier.split(".", false)
				if index + item_segments.size() > path.size():
					continue
				var matches := true
				for offset in item_segments.size():
					if String(path[index + offset]) != String(item_segments[offset]):
						matches = false
						break
				if matches and item_segments.size() > consumed:
					match_index = candidate_index
					consumed = item_segments.size()
			if match_index < 0:
				# Also accept an explicit numeric array index for adapters that
				# already resolved local identifiers.
				var numeric := int(path[index]) if String(path[index]).is_valid_int() else -1
				if numeric < 0 or numeric >= current.size():
					return {"ok": false, "message": "Collection item '%s' does not exist" % String(path[index])}
				match_index = numeric
				consumed = 1
			expanded.append(match_index)
			current = current[match_index]
			index += consumed
			continue
		return {"ok": false, "message": "Field path cannot continue"}
	return {"ok": true, "path": expanded}


func _set_mutable_path(root: Dictionary, path: Array, value: Variant) -> Dictionary:
	if path.is_empty():
		return {"ok": false, "message": "Field path is empty"}
	var owner: Variant = root
	for index in path.size() - 1:
		var key = path[index]
		if owner is Dictionary:
			if not owner.has(key):
				return {"ok": false, "message": "Field '%s' does not exist" % String(key)}
			owner = owner[key]
		elif owner is Array:
			var numeric := int(key)
			if numeric < 0 or numeric >= owner.size():
				return {"ok": false, "message": "Collection index is out of range"}
			owner = owner[numeric]
		else:
			return {"ok": false, "message": "Field path cannot continue"}
	var final_key = path[path.size() - 1]
	if owner is Dictionary:
		var had_value: bool = owner.has(final_key)
		var old_value = owner.get(final_key, null)
		owner[final_key] = value
		return {"ok": true, "had_value": had_value, "old_value": old_value.duplicate(true) if old_value is Array or old_value is Dictionary else old_value}
	if owner is Array:
		var numeric := int(final_key)
		if numeric < 0 or numeric >= owner.size():
			return {"ok": false, "message": "Collection index is out of range"}
		var old_value = owner[numeric]
		owner[numeric] = value
		return {"ok": true, "old_value": old_value.duplicate(true) if old_value is Array or old_value is Dictionary else old_value}
	return {"ok": false, "message": "Field owner is invalid"}


func _storage_kind(kind: String) -> String:
	var normalized := kind.strip_edges().to_lower()
	match normalized:
		"level", "levels", "level_definition":
			return "levels"
		"task_graph", "task_graphs", "graph", "graphs", "task_graph_definition":
			return "task_graphs"
		"conversation", "conversations", "conversation_definition":
			return "conversations"
		"speaker", "speakers", "speaker_definition":
			return "speakers"
		"provider", "providers", "provider_declaration", "provider_definition":
			return "providers"
		"resource", "resources":
			return "resources"
		_:
			return normalized


func _layout_collection(kind: String) -> String:
	match _storage_kind(kind):
		"task_graphs":
			return "graphs"
		"conversations":
			return "conversations"
		"levels":
			return "levels"
		_:
			return "resources"


func _layout_element_category(element_kind: String) -> String:
	match element_kind:
		"node", "nodes":
			return "nodes"
		"edge", "edges", "connection", "connections":
			return "edges"
		"frame", "frames":
			return "frames"
		"step", "steps", "line", "lines":
			return "steps"
		"choice", "choices":
			return "choices"
		_:
			return element_kind + "s" if not element_kind.ends_with("s") else element_kind


func _element_collection(element_kind: String) -> String:
	match element_kind:
		"node", "nodes", "edge", "edges", "connection", "connections":
			return "nodes" if element_kind in ["node", "nodes"] else "edges"
		"step", "steps", "line", "lines":
			return "steps"
		"choice", "choices":
			return "choices"
		"port", "ports":
			return "ports"
		"anchor", "anchors":
			return "anchors"
		"exit", "exits":
			return "exits"
		_:
			return ""


func _navigation_entry(document: Dictionary, storage_kind: String, identifier: String) -> Dictionary:
	return {
		"kind": String(document.get("kind", _kind_from_storage(storage_kind))),
		"collection": storage_kind,
		"identifier": identifier,
		"source_path": String(document.get("source_path", "")),
	}


func _kind_from_storage(storage_kind: String) -> String:
	match storage_kind:
		"levels":
			return KIND_LEVEL
		"task_graphs":
			return KIND_TASK_GRAPH
		"conversations":
			return KIND_CONVERSATION
		"speakers":
			return KIND_SPEAKER
		"providers":
			return KIND_PROVIDER
		_:
			return "resource"


func _serializable_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is StringName:
		return String(value)
	if value is Vector2:
		return [float(value.x), float(value.y)]
	if value is Vector2i:
		return [int(value.x), int(value.y)]
	if value is PackedStringArray or value is PackedByteArray:
		var packed: Array = []
		for item in value:
			packed.append(_serializable_value(item))
		return packed
	if value is Array:
		var array: Array = []
		for item in value:
			array.append(_serializable_value(item))
		return array
	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key in value:
			dictionary[String(key)] = _serializable_value(value[key])
		return dictionary
	if value is Object:
		return null
	return value


func _vector2_from_variant(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO


func _offset_position(value: Variant, offset: Vector2) -> Array:
	var position := _vector2_from_variant(value) + offset
	return [float(position.x), float(position.y)]


func _contains_non_serializable_marker(value: Variant) -> bool:
	if value is Dictionary:
		if value.has("__non_serializable_object__"):
			return true
		for key in value:
			if _contains_non_serializable_marker(value[key]):
				return true
		return false
	if value is Array:
		for item in value:
			if _contains_non_serializable_marker(item):
				return true
	return false


func _without_editor_metadata(value: Variant) -> Variant:
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_without_editor_metadata(item))
		return result
	if value is Dictionary:
		var result_dict: Dictionary = {}
		for key in value:
			var name := String(key)
			if name in ["source_path", "resource_path", "layout", "editor_layout", "selection", "navigator"]:
				continue
			result_dict[name] = _without_editor_metadata(value[key])
		return result_dict
	return value


static func _identifier_set(values: Variant) -> Dictionary:
	var result: Dictionary = {}
	if values is Dictionary:
		for value in values.keys():
			result[String(value)] = true
	elif values is Array or values is PackedStringArray:
		for value in values:
			result[String(value)] = true
	elif values is String:
		result[String(values)] = true
	return result


func _failure(code: String, message: String, path: String, command: Dictionary = {}) -> Dictionary:
	return {
		"ok": false,
		"applied": false,
		"revision": _revision,
		"command": command.duplicate(true),
		"inverse": null,
		"inverse_command": null,
		"error": {
			"code": code,
			"path": path,
			"severity": "error",
			"message": message,
		},
		"state": snapshot(),
	}


func _op_failure(code: String, message: String, path: String) -> Dictionary:
	return {
		"ok": false,
		"code": code,
		"message": message,
		"path": path,
	}
