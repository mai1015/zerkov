class_name LtsDocumentCommand
extends RefCounted

## Serializable, EditorInterface-free document command.
##
## A command carries only a deterministic operation, mutation class, and plain
## payload.  The document model validates and applies it atomically and
## returns serializable inverse command data.  LtsDocumentHistory registers
## those command dictionaries with EditorUndoRedoManager (or UndoRedo in a
## headless process) without making the model depend on the editor.

const COMMAND_SCHEMA_VERSION := 1
const MUTATION_SEMANTIC := "semantic"
const MUTATION_LAYOUT := "layout"
const MUTATION_MIXED := "semantic_and_layout"

const MIXED_OPERATIONS: PackedStringArray = [
	"paste", "paste_fragment", "graph.paste", "duplicate_nodes", "graph.duplicate",
]

const LAYOUT_OPERATIONS: PackedStringArray = [
	"navigate_catalog", "catalog.navigate", "set_selection", "select",
	"set_layout", "layout.set", "set_node_position", "move_node", "node.move",
	"set_frame_membership", "frame.set", "node.frame", "set_layout_batch",
	"layout.batch", "restore_layout", "layout.restore", "auto_arrange", "arrange",
	"layout.auto_arrange",
]

var operation: String = ""
var mutation: String = MUTATION_SEMANTIC
var payload: Dictionary = {}


func _init(p_operation: Variant = "", p_mutation: String = "", p_payload: Dictionary = {}) -> void:
	if p_operation is Dictionary:
		var data: Dictionary = p_operation
		operation = String(data.get("operation", data.get("type", "")))
		mutation = String(data.get("mutation", data.get("mutation_class", "")))
		payload = _serializable(data.get("payload", {}))
		if mutation.is_empty():
			mutation = infer_mutation(operation)
		return
	operation = String(p_operation)
	mutation = p_mutation if not p_mutation.is_empty() else infer_mutation(operation)
	payload = _serializable(p_payload)


static func infer_mutation(p_operation: String) -> String:
	if MIXED_OPERATIONS.has(p_operation):
		return MUTATION_MIXED
	if LAYOUT_OPERATIONS.has(p_operation):
		return MUTATION_LAYOUT
	return MUTATION_SEMANTIC


func to_dict() -> Dictionary:
	return {
		"schema_version": COMMAND_SCHEMA_VERSION,
		"operation": operation,
		"mutation": mutation,
		"payload": payload.duplicate(true),
	}


func serialize() -> Dictionary:
	return to_dict()


func to_json() -> String:
	return JSON.stringify(to_dict())


static func from_dict(data: Dictionary):
	return load("res://addons/level_task_system/editor/document/lts_document_command.gd").new(data)


static func from_json(text: String):
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return load("res://addons/level_task_system/editor/document/lts_document_command.gd").new()
	return from_dict(_normalize_json_numbers(parsed))


func duplicate_command():
	return load("res://addons/level_task_system/editor/document/lts_document_command.gd").new(to_dict())


func is_valid_shape() -> bool:
	return not operation.strip_edges().is_empty() and mutation in [MUTATION_SEMANTIC, MUTATION_LAYOUT, MUTATION_MIXED] and payload is Dictionary


func is_semantic() -> bool:
	return mutation == MUTATION_SEMANTIC or mutation == MUTATION_MIXED


func is_layout() -> bool:
	return mutation == MUTATION_LAYOUT or mutation == MUTATION_MIXED


func is_mixed() -> bool:
	return mutation == MUTATION_MIXED


func apply_to(model: Object) -> Dictionary:
	if model == null or not model.has_method("apply_command"):
		return {
			"ok": false,
			"applied": false,
			"error": {"code": "LTS-DOCUMENT-002", "message": "Command target is not a document model"},
			"inverse": null,
		}
	return model.call("apply_command", self)


static func navigate_catalog(path: String, resource_kind: String = "", resource_identifier: String = "", query: String = ""):
	return _new("navigate_catalog", MUTATION_LAYOUT, {
		"path": path,
		"resource_kind": resource_kind,
		"resource_identifier": resource_identifier,
		"query": query,
	})


static func catalog_navigation(path: String, resource_kind: String = "", resource_identifier: String = "", query: String = ""):
	return navigate_catalog(path, resource_kind, resource_identifier, query)


static func set_selection(selection: Dictionary):
	return _new("set_selection", MUTATION_LAYOUT, {"selection": selection.duplicate(true)})


static func select(selection: Dictionary):
	return set_selection(selection)


static func edit_field(document_kind: String, document_identifier: String, field_path: Variant, value: Variant):
	return set_field(document_kind, document_identifier, field_path, value)


static func set_field(document_kind: String, document_identifier: String, field_path: Variant, value: Variant):
	return _new("set_field", MUTATION_SEMANTIC, {
		"document_kind": document_kind,
		"document_identifier": document_identifier,
		"field_path": field_path,
		"value": value,
	})


static func set_node_field(graph_identifier: String, node_identifier: String, field_name: String, value: Variant):
	return _new("set_field", MUTATION_SEMANTIC, {
		"document_kind": "task_graph",
		"document_identifier": graph_identifier,
		"field_path": ["nodes", node_identifier, field_name],
		"value": value,
	})


static func set_step_field(conversation_identifier: String, step_identifier: String, field_name: String, value: Variant):
	return _new("set_field", MUTATION_SEMANTIC, {
		"document_kind": "conversation",
		"document_identifier": conversation_identifier,
		"field_path": ["steps", step_identifier, field_name],
		"value": value,
	})


static func set_choice_field(conversation_identifier: String, step_identifier: String, choice_identifier: String, field_name: String, value: Variant):
	return _new("set_field", MUTATION_SEMANTIC, {
		"document_kind": "conversation",
		"document_identifier": conversation_identifier,
		"field_path": ["steps", step_identifier, "choices", choice_identifier, field_name],
		"value": value,
	})


static func add_task_node(graph_identifier: String, node: Dictionary):
	return _new("add_node", MUTATION_SEMANTIC, {
		"graph_identifier": graph_identifier,
		"node": node.duplicate(true),
	})


static func create_task_node(graph_identifier: String, node: Dictionary):
	return add_task_node(graph_identifier, node)


static func remove_task_node(graph_identifier: String, node_identifier: String):
	return remove_task_nodes(graph_identifier, [node_identifier])


static func remove_task_nodes(graph_identifier: String, node_identifiers: Array):
	return _new("remove_nodes", MUTATION_SEMANTIC, {
		"graph_identifier": graph_identifier,
		"node_identifiers": node_identifiers.duplicate(),
	})


static func add_task_edge(graph_identifier: String, edge: Dictionary):
	return _new("add_edge", MUTATION_SEMANTIC, {
		"graph_identifier": graph_identifier,
		"edge": edge.duplicate(true),
	})


static func connect_edge(graph_identifier: String, edge: Dictionary):
	return add_task_edge(graph_identifier, edge)


static func connect_nodes(graph_identifier: String, from_node_identifier: String, from_port_identifier: String, to_node_identifier: String, to_port_identifier: String, edge_identifier: String = ""):
	return add_task_edge(graph_identifier, {
		"identifier": edge_identifier,
		"from_node_identifier": from_node_identifier,
		"from_port_identifier": from_port_identifier,
		"to_node_identifier": to_node_identifier,
		"to_port_identifier": to_port_identifier,
	})


static func remove_task_edge(graph_identifier: String, edge_identifier: String):
	return _new("remove_edge", MUTATION_SEMANTIC, {
		"graph_identifier": graph_identifier,
		"edge_identifier": edge_identifier,
	})


static func disconnect_edge(graph_identifier: String, edge_identifier: String):
	return remove_task_edge(graph_identifier, edge_identifier)


static func add_conversation_step(conversation_identifier: String, step: Dictionary):
	return _new("add_step", MUTATION_SEMANTIC, {
		"conversation_identifier": conversation_identifier,
		"step": step.duplicate(true),
	})


static func remove_conversation_step(conversation_identifier: String, step_identifier: String):
	return _new("remove_step", MUTATION_SEMANTIC, {
		"conversation_identifier": conversation_identifier,
		"step_identifier": step_identifier,
	})


static func add_conversation_choice(conversation_identifier: String, step_identifier: String, choice: Dictionary):
	return _new("add_choice", MUTATION_SEMANTIC, {
		"conversation_identifier": conversation_identifier,
		"step_identifier": step_identifier,
		"choice": choice.duplicate(true),
	})


static func add_choice(conversation_identifier: String, step_identifier: String, choice: Dictionary):
	return add_conversation_choice(conversation_identifier, step_identifier, choice)


static func remove_conversation_choice(conversation_identifier: String, step_identifier: String, choice_identifier: String):
	return _new("remove_choice", MUTATION_SEMANTIC, {
		"conversation_identifier": conversation_identifier,
		"step_identifier": step_identifier,
		"choice_identifier": choice_identifier,
	})


static func remove_choice(conversation_identifier: String, step_identifier: String, choice_identifier: String):
	return remove_conversation_choice(conversation_identifier, step_identifier, choice_identifier)


static func set_layout(resource_kind: String, resource_identifier: String, element_kind: String = "", element_identifier: String = "", value: Variant = null, field_name: String = ""):
	return _new("set_layout", MUTATION_LAYOUT, {
		"resource_kind": resource_kind,
		"resource_identifier": resource_identifier,
		"element_kind": element_kind,
		"element_identifier": element_identifier,
		"field_name": field_name,
		"value": value,
	})


static func set_layout_batch(resource_kind: String, resource_identifier: String, values: Dictionary):
	return _new("set_layout_batch", MUTATION_LAYOUT, {
		"resource_kind": resource_kind,
		"resource_identifier": resource_identifier,
		"values": values.duplicate(true),
	})


static func set_node_position(graph_identifier: String, node_identifier: String, position: Variant):
	return set_layout("task_graph", graph_identifier, "node", node_identifier, position, "position")


static func move_node(graph_identifier: String, node_identifier: String, position: Variant):
	return set_node_position(graph_identifier, node_identifier, position)


static func set_frame_membership(graph_identifier: String, node_identifier: String, frame_identifier: String):
	return set_layout("task_graph", graph_identifier, "node", node_identifier, frame_identifier, "frame_identifier")


static func set_pane_layout(pane_identifier: String, value: Variant):
	return set_layout("", "", "pane", pane_identifier, value)


static func restore_layout(layout_snapshot: Dictionary):
	return _new("restore_layout", MUTATION_LAYOUT, {"layout": layout_snapshot.duplicate(true)})


static func auto_arrange(graph_identifier: String, positions: Dictionary):
	return _new("auto_arrange", MUTATION_LAYOUT, {
		"graph_identifier": graph_identifier,
		"positions": positions.duplicate(true),
	})


static func set_resource_reference(document_kind: String, document_identifier: String, field_path: Variant, referenced_identifier: String):
	return set_field(document_kind, document_identifier, field_path, referenced_identifier)


static func paste_graph_fragment(graph_identifier: String, fragment: Dictionary, position_offset: Variant = null, suffix: String = "_copy", preserve_identifiers: bool = false):
	return _new("paste_fragment", MUTATION_MIXED, {
		"graph_identifier": graph_identifier,
		"fragment": fragment.duplicate(true),
		"position_offset": position_offset,
		"suffix": suffix,
		"preserve_identifiers": preserve_identifiers,
	})


static func paste_fragment(graph_identifier: String, fragment: Dictionary, position_offset: Variant = null, suffix: String = "_copy", preserve_identifiers: bool = false):
	return paste_graph_fragment(graph_identifier, fragment, position_offset, suffix, preserve_identifiers)


static func duplicate_nodes(graph_identifier: String, fragment: Dictionary, position_offset: Variant = null, suffix: String = "_copy"):
	return paste_graph_fragment(graph_identifier, fragment, position_offset, suffix, false)


static func batch(commands: Array):
	var serialized: Array = []
	for item in commands:
		if item is Object and item.has_method("to_dict"):
			serialized.append(item.to_dict())
		elif item is Dictionary:
			serialized.append(item.duplicate(true))
	var mutation := MUTATION_SEMANTIC
	var saw_layout := false
	var saw_semantic := false
	for item in serialized:
		var child = _new_from_data(item)
		saw_layout = saw_layout or child.is_layout()
		saw_semantic = saw_semantic or child.is_semantic()
	if saw_layout and saw_semantic:
		mutation = MUTATION_MIXED
	elif saw_layout:
		mutation = MUTATION_LAYOUT
	return _new("batch", mutation, {"commands": serialized})


static func restore_state(state: Dictionary, mutation_class: String = MUTATION_MIXED):
	return _new("restore_state", mutation_class, {"state": state.duplicate(true)})


static func _new(p_operation: String, p_mutation: String, p_payload: Dictionary):
	return load("res://addons/level_task_system/editor/document/lts_document_command.gd").new(p_operation, p_mutation, p_payload)


static func _new_from_data(data: Dictionary):
	return load("res://addons/level_task_system/editor/document/lts_document_command.gd").new(data)


static func _serializable(value: Variant) -> Variant:
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
			packed.append(_serializable(item))
		return packed
	if value is Array:
		var array: Array = []
		for item in value:
			array.append(_serializable(item))
		return array
	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key in value:
			dictionary[String(key)] = _serializable(value[key])
		return dictionary
	if value is Object:
		# A command must never retain a Resource, Node, Callable, or other
		# live engine object.  The model reports the invalid payload atomically.
		return {"__non_serializable_object__": String(value.get_class()) if value.has_method("get_class") else "Object"}
	return value


static func _normalize_json_numbers(value: Variant) -> Variant:
	if value is Array:
		var array: Array = []
		for item in value:
			array.append(_normalize_json_numbers(item))
		return array
	if value is Dictionary:
		var dictionary: Dictionary = {}
		for key in value:
			dictionary[key] = _normalize_json_numbers(value[key])
		return dictionary
	if value is float and is_equal_approx(value, float(int(value))):
		return int(value)
	return value
