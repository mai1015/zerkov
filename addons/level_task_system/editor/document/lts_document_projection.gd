class_name LtsDocumentProjection
extends RefCounted

## Pure projections from bound LevelTask Resources (or plain fixture
## dictionaries) into the document model's serializable data shape.
##
## Resource conversion is deliberately defensive.  The editor can load this
## projection in a headless process, in a project where the GDExtension is not
## registered, or with a test double that only implements the documented
## getter/property names.  No projection calls EditorInterface or stores a
## live Object in the returned data.

const Fixtures := preload("res://addons/level_task_system/editor/document/lts_document_fixtures.gd")

const KIND_LEVEL := "level"
const KIND_TASK_GRAPH := "task_graph"
const KIND_CONVERSATION := "conversation"
const KIND_SPEAKER := "speaker"
const KIND_PROVIDER := "provider"
const KIND_UNKNOWN := "unknown"

const COLLECTION_ORDER: PackedStringArray = [
	"levels", "task_graphs", "conversations", "speakers", "providers",
]

const COLLECTION_KIND: Dictionary = {
	"levels": KIND_LEVEL,
	"task_graphs": KIND_TASK_GRAPH,
	"conversations": KIND_CONVERSATION,
	"speakers": KIND_SPEAKER,
	"providers": KIND_PROVIDER,
}

const COLLECTION_ALIASES: Dictionary = {
	"levels": ["levels", "level_definitions", "level_definition"],
	"task_graphs": ["task_graphs", "graph_definitions", "task_graph_definitions", "graphs"],
	"conversations": ["conversations", "conversation_definitions", "conversation_definition"],
	"speakers": ["speakers", "speaker_definitions", "speaker_definition"],
	"providers": ["providers", "provider_declarations", "provider_definitions", "provider_declaration"],
}

const GRAPH_CLASS_NAMES: PackedStringArray = [
	"LevelTaskGraphDefinition", "TaskGraphDefinition", "task_graph",
]
const CONVERSATION_CLASS_NAMES: PackedStringArray = [
	"LevelTaskConversationDefinition", "ConversationDefinition", "conversation",
]
const LEVEL_CLASS_NAMES: PackedStringArray = [
	"LevelTaskLevelDefinition", "LevelDefinition", "level",
]
const SPEAKER_CLASS_NAMES: PackedStringArray = [
	"LevelTaskSpeakerDefinition", "SpeakerDefinition", "speaker",
]
const PROVIDER_CLASS_NAMES: PackedStringArray = [
	"LevelTaskProviderDeclaration", "ProviderDeclaration", "provider",
]


static func project_resource(resource: Variant, source_path: String = "") -> Dictionary:
	if resource == null:
		return Fixtures.malformed_resource(source_path, "Cannot project a null resource")
	if resource is Dictionary:
		return _project_dictionary(resource, source_path)

	var type_name := _class_name(resource)
	if GRAPH_CLASS_NAMES.has(type_name) or _has_member(resource, "nodes") and _has_member(resource, "edges"):
		return project_task_graph(resource, source_path)
	if CONVERSATION_CLASS_NAMES.has(type_name) or _has_member(resource, "steps") and _has_member(resource, "entry_label"):
		return project_conversation(resource, source_path)
	if LEVEL_CLASS_NAMES.has(type_name) or _has_member(resource, "scene_resource") and _has_member(resource, "entry_graph_identifiers"):
		return project_level(resource, source_path)
	if SPEAKER_CLASS_NAMES.has(type_name) or _has_member(resource, "portrait_key") and _has_member(resource, "display_name_key"):
		return project_speaker(resource, source_path)
	if PROVIDER_CLASS_NAMES.has(type_name) or _has_member(resource, "request_type") and _has_member(resource, "response_type"):
		return project_provider(resource, source_path)
	return Fixtures.malformed_resource(source_path, "Unsupported resource class '%s'" % type_name)


static func project_task_graph(resource: Variant, source_path: String = "") -> Dictionary:
	var nodes: Array = []
	for item in _as_array(_read(resource, "nodes", [])):
		nodes.append(project_task_node(item))
	var edges: Array = []
	for item in _as_array(_read(resource, "edges", [])):
		edges.append(project_task_edge(item))
	return {
		"kind": KIND_TASK_GRAPH,
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"entry_node_identifier": _text(_read(resource, "entry_node_identifier", "")),
		"terminal_outcomes": _plain(_read(resource, "terminal_outcomes", [])),
		"nodes": nodes,
		"edges": edges,
		"max_transitions_per_advance": int(_read(resource, "max_transitions_per_advance", 0)),
		"source_path": source_path,
	}


static func project_task_node(resource: Variant) -> Dictionary:
	var ports: Array = []
	for item in _as_array(_read(resource, "ports", [])):
		ports.append(project_port(item))
	var filters: Array = []
	for item in _as_array(_read(resource, "filters", [])):
		filters.append(project_fact_predicate(item))
	var parameters: Array = []
	for item in _as_array(_read(resource, "parameters", [])):
		parameters.append(project_value(item))
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"kind": int(_read(resource, "kind", 0)),
		"ports": ports,
		"provider_identifier": _text(_read(resource, "provider_identifier", "")),
		"objective_target": int(_read(resource, "objective_target", 1)),
		"filters": filters,
		"parameters": parameters,
		"conversation_identifier": _text(_read(resource, "conversation_identifier", "")),
		"conversation_entry_label": _text(_read(resource, "conversation_entry_label", "")),
		"accepted_outcomes": _plain(_read(resource, "accepted_outcomes", [])),
		"subgraph_identifier": _text(_read(resource, "subgraph_identifier", "")),
		"outcome_identifier": _text(_read(resource, "outcome_identifier", "")),
	}


static func project_task_edge(resource: Variant) -> Dictionary:
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"from_node_identifier": _text(_read(resource, "from_node_identifier", "")),
		"from_port_identifier": _text(_read(resource, "from_port_identifier", "")),
		"to_node_identifier": _text(_read(resource, "to_node_identifier", "")),
		"to_port_identifier": _text(_read(resource, "to_port_identifier", "")),
	}


static func project_port(resource: Variant) -> Dictionary:
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"direction": int(_read(resource, "direction", 1)),
		"value_type": int(_read(resource, "value_type", 0)),
		"required": bool(_read(resource, "required", false)),
	}


static func project_fact_predicate(resource: Variant) -> Dictionary:
	return {
		"provider_identifier": _text(_read(resource, "provider_identifier", "")),
		"fact_identifier": _text(_read(resource, "fact_identifier", "")),
		"comparator": int(_read(resource, "comparator", 0)),
		"expected": project_value(_read(resource, "expected", null)),
	}


static func project_value(resource: Variant) -> Variant:
	if resource == null:
		return null
	if resource is Dictionary:
		if resource.has("type") or resource.has("value_type"):
			var result := {}
			for key in resource:
				result[String(key)] = _plain(resource[key])
			return result
		return _plain(resource)
	var type_name := _class_name(resource)
	if type_name == "LevelTaskValue" or type_name == "Value":
		return {
			"type": int(_read(resource, "type", 0)),
			"boolean_value": bool(_read(resource, "boolean_value", false)),
			"integer_value": int(_read(resource, "integer_value", 0)),
			"fixed_raw": int(_read(resource, "fixed_raw", 0)),
			"string_value": _text(_read(resource, "string_value", "")),
			"text_value": _text(_read(resource, "text_value", "")),
			"bytes_value": _plain(_read(resource, "bytes_value", [])),
		}
	return _plain(resource)


static func project_level(resource: Variant, source_path: String = "") -> Dictionary:
	var rules: Array = []
	for item in _as_array(_read(resource, "availability_rules", [])):
		rules.append(project_fact_predicate(item))
	var anchors: Array = []
	for item in _as_array(_read(resource, "anchors", [])):
		anchors.append(project_anchor(item))
	var exits: Array = []
	for item in _as_array(_read(resource, "exits", [])):
		exits.append(project_exit(item))
	return {
		"kind": KIND_LEVEL,
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"display_name_key": _text(_read(resource, "display_name_key", "")),
		"description_key": _text(_read(resource, "description_key", "")),
		"scene_resource": _text(_read(resource, "scene_resource", "")),
		"availability_rules": rules,
		"entry_graph_identifiers": _plain(_read(resource, "entry_graph_identifiers", [])),
		"anchors": anchors,
		"exits": exits,
		"source_path": source_path,
	}


static func project_anchor(resource: Variant) -> Dictionary:
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"kind": int(_read(resource, "kind", 0)),
		"required": bool(_read(resource, "required", true)),
		"binding_label": _text(_read(resource, "binding_label", "")),
	}


static func project_exit(resource: Variant) -> Dictionary:
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"target_level_identifier": _text(_read(resource, "target_level_identifier", "")),
		"target_anchor_identifier": _text(_read(resource, "target_anchor_identifier", "")),
		"outcome_identifier": _text(_read(resource, "outcome_identifier", "")),
	}


static func project_conversation(resource: Variant, source_path: String = "") -> Dictionary:
	var steps: Array = []
	for item in _as_array(_read(resource, "steps", [])):
		steps.append(project_conversation_step(item))
	return {
		"kind": KIND_CONVERSATION,
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"entry_label": _text(_read(resource, "entry_label", "")),
		"speaker_identifiers": _plain(_read(resource, "speaker_identifiers", [])),
		"terminal_outcomes": _plain(_read(resource, "terminal_outcomes", [])),
		"steps": steps,
		"max_steps_per_advance": int(_read(resource, "max_steps_per_advance", 0)),
		"max_jumps_per_advance": int(_read(resource, "max_jumps_per_advance", 0)),
		"source_path": source_path,
	}


static func project_conversation_step(resource: Variant) -> Dictionary:
	var parameters: Array = []
	for item in _as_array(_read(resource, "parameters", [])):
		parameters.append(project_localized_parameter(item))
	var conditions: Array = []
	for item in _as_array(_read(resource, "conditions", [])):
		conditions.append(project_fact_predicate(item))
	var choices: Array = []
	for item in _as_array(_read(resource, "choices", [])):
		choices.append(project_conversation_choice(item))
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"kind": int(_read(resource, "kind", 0)),
		"speaker_identifier": _text(_read(resource, "speaker_identifier", "")),
		"line_key": _text(_read(resource, "line_key", "")),
		"parameters": parameters,
		"next_step_identifier": _text(_read(resource, "next_step_identifier", "")),
		"provider_identifier": _text(_read(resource, "provider_identifier", "")),
		"conditions": conditions,
		"true_step_identifier": _text(_read(resource, "true_step_identifier", "")),
		"false_step_identifier": _text(_read(resource, "false_step_identifier", "")),
		"success_step_identifier": _text(_read(resource, "success_step_identifier", "")),
		"failure_step_identifier": _text(_read(resource, "failure_step_identifier", "")),
		"choices": choices,
		"target_step_identifier": _text(_read(resource, "target_step_identifier", "")),
		"outcome_identifier": _text(_read(resource, "outcome_identifier", "")),
	}


static func project_conversation_choice(resource: Variant) -> Dictionary:
	var conditions: Array = []
	for item in _as_array(_read(resource, "conditions", [])):
		conditions.append(project_fact_predicate(item))
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"label_key": _text(_read(resource, "label_key", "")),
		"target_step_identifier": _text(_read(resource, "target_step_identifier", "")),
		"conditions": conditions,
	}


static func project_localized_parameter(resource: Variant) -> Dictionary:
	return {
		"identifier": _text(_read(resource, "identifier", "")),
		"value": project_value(_read(resource, "value", null)),
	}


static func project_speaker(resource: Variant, source_path: String = "") -> Dictionary:
	return {
		"kind": KIND_SPEAKER,
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"display_name_key": _text(_read(resource, "display_name_key", "")),
		"portrait_key": _text(_read(resource, "portrait_key", "")),
		"source_path": source_path,
	}


static func project_provider(resource: Variant, source_path: String = "") -> Dictionary:
	return {
		"kind": KIND_PROVIDER,
		"identifier": _text(_read(resource, "identifier", "")),
		"schema_version": int(_read(resource, "schema_version", 1)),
		"kind_value": int(_read(resource, "kind", 0)),
		"request_type": int(_read(resource, "request_type", 0)),
		"response_type": int(_read(resource, "response_type", 0)),
		"max_request_bytes": int(_read(resource, "max_request_bytes", 0)),
		"max_response_bytes": int(_read(resource, "max_response_bytes", 0)),
		"deterministic": bool(_read(resource, "deterministic", true)),
		"authority_only": bool(_read(resource, "authority_only", true)),
		"source_path": source_path,
	}


static func project_catalog(catalog: Variant, source_path: String = "") -> Dictionary:
	var result := {
		"kind": "catalog",
		"identifier": _text(_read(catalog, "identifier", "")),
		"schema_version": int(_read(catalog, "schema_version", 1)),
		"source_path": source_path,
		"documents": {
			"levels": {},
			"task_graphs": {},
			"conversations": {},
			"speakers": {},
			"providers": {},
		},
		"entries": [],
	}
	for collection in COLLECTION_ORDER:
		var items := _catalog_collection(catalog, collection)
		for item in items:
			var item_path := _text(_read(item, "source_path", _read(item, "resource_path", "")))
			var projected := project_resource(item, item_path)
			var kind := String(COLLECTION_KIND[collection])
			var storage_kind := collection
			if projected.get("kind", KIND_UNKNOWN) != kind:
				# A test catalog may use a generic collection key while the item
				# still carries the domain kind.  Keep the explicit item kind.
				storage_kind = _storage_kind(String(projected.get("kind", kind)))
			var identifier := _text(projected.get("identifier", ""))
			if not identifier.is_empty():
				result["documents"][storage_kind][identifier] = projected
				result["entries"].append({
					"kind": String(projected.get("kind", kind)),
					"collection": storage_kind,
					"identifier": identifier,
					"source_path": item_path,
				})
	return _sort_catalog_result(result)


static func navigation_projection(state: Variant, query: String = "", selected_path: String = "") -> Dictionary:
	var plain_state: Dictionary = state.call("snapshot") if state is Object and state.has_method("snapshot") else state
	if not plain_state is Dictionary:
		plain_state = {"documents": {}}
	var documents: Dictionary = plain_state.get("documents", {})
	var needle := query.strip_edges().to_lower()
	var entries: Array = []
	for collection in COLLECTION_ORDER:
		var bucket: Dictionary = documents.get(collection, {})
		var identifiers := bucket.keys()
		identifiers.sort()
		for identifier in identifiers:
			var item: Dictionary = bucket[identifier]
			var path := document_path(String(item.get("kind", COLLECTION_KIND.get(collection, "resource"))), String(identifier))
			var source_path := String(item.get("source_path", ""))
			var label := String(item.get("display_name_key", item.get("line_key", identifier)))
			var haystack := "%s %s %s" % [identifier, label, source_path]
			if not needle.is_empty() and haystack.to_lower().find(needle) == -1:
				continue
			entries.append({
				"kind": String(item.get("kind", COLLECTION_KIND.get(collection, "resource"))),
				"collection": collection,
				"identifier": String(identifier),
				"label": label,
				"source_path": source_path,
				"path": path,
				"selected": path == selected_path,
			})
	var groups: Array = []
	for collection in COLLECTION_ORDER:
		var group_entries: Array = []
		for entry in entries:
			if entry["collection"] == collection:
				group_entries.append(entry)
		groups.append({
			"collection": collection,
			"kind": COLLECTION_KIND.get(collection, "resource"),
			"label": _collection_label(collection),
			"entries": group_entries,
			"empty": group_entries.is_empty(),
		})
	return {
		"query": query,
		"entries": entries,
		"groups": groups,
		"selected_path": selected_path,
		"empty": entries.is_empty(),
		"read_only": bool(plain_state.get("read_only", false)),
		"diagnostic": plain_state.get("diagnostic", {}).duplicate(true),
	}


static func document_path(kind: String, identifier: String) -> String:
	var canonical_kind := _canonical_kind(kind)
	var prefix := {
		KIND_LEVEL: "level",
		KIND_TASK_GRAPH: "task",
		KIND_CONVERSATION: "conversation",
		KIND_SPEAKER: "speaker",
		KIND_PROVIDER: "provider",
	}.get(canonical_kind, "resource")
	return "%s.%s" % [prefix, identifier]


static func element_path(kind: String, identifier: String, element_kind: String, element_identifier: String, field_path: String = "") -> String:
	var path := document_path(kind, identifier)
	var element_label := element_kind.strip_edges().to_lower()
	if not element_label.is_empty() and not element_identifier.is_empty():
		path += ".%s.%s" % [element_label, element_identifier]
	if not field_path.strip_edges().is_empty():
		path += ".%s" % field_path.strip_edges().replace("/", ".")
	return path


static func finding_path(kind: String, identifier: String, element_kind: String = "", element_identifier: String = "", field_path: String = "") -> String:
	return element_path(kind, identifier, element_kind, element_identifier, field_path)


static func _project_dictionary(resource: Dictionary, source_path: String) -> Dictionary:
	var kind := _canonical_kind(String(resource.get("kind", resource.get("resource_kind", ""))))
	if kind == KIND_TASK_GRAPH:
		return project_task_graph(resource, source_path)
	if kind == KIND_CONVERSATION:
		return project_conversation(resource, source_path)
	if kind == KIND_LEVEL:
		return project_level(resource, source_path)
	if kind == KIND_SPEAKER:
		return project_speaker(resource, source_path)
	if kind == KIND_PROVIDER:
		return project_provider(resource, source_path)
	return Fixtures.malformed_resource(source_path, "Dictionary is missing a supported resource kind")


static func _catalog_collection(catalog: Variant, collection: String) -> Array:
	for alias in COLLECTION_ALIASES.get(collection, []):
		var direct := _read(catalog, String(alias), null)
		if direct != null:
			return _as_array(direct)
		var getter := "get_" + String(alias)
		if _has_member(catalog, getter):
			return _as_array(_read_method(catalog, getter, []))
	return []


static func _sort_catalog_result(result: Dictionary) -> Dictionary:
	var entries: Array = result["entries"]
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_key := "%s|%s" % [a.get("kind", ""), a.get("identifier", "")]
		var b_key := "%s|%s" % [b.get("kind", ""), b.get("identifier", "")]
		return a_key < b_key
	)
	result["entries"] = entries
	return result


static func _storage_kind(kind: String) -> String:
	match _canonical_kind(kind):
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
			return "resources"


static func _canonical_kind(kind: String) -> String:
	var normalized := kind.strip_edges().to_lower()
	match normalized:
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
		_:
			return normalized if not normalized.is_empty() else KIND_UNKNOWN


static func _collection_label(collection: String) -> String:
	return {
		"levels": "Levels",
		"task_graphs": "Task Graphs",
		"conversations": "Conversations",
		"speakers": "Speakers",
		"providers": "Providers",
	}.get(collection, collection.capitalize())


static func _class_name(value: Variant) -> String:
	if value is Dictionary:
		return String(value.get("class_name", value.get("kind", "")))
	if value is Object and value.has_method("get_class"):
		return String(value.get_class())
	return ""


static func _has_member(value: Variant, member: String) -> bool:
	if value is Dictionary:
		return value.has(member)
	if value is Object:
		if value.has_method(member):
			return true
		if value.has_method("get_" + member):
			return true
		for property in value.get_property_list():
			if String(property.get("name", "")) == member:
				return true
	return false


static func _read(value: Variant, property: String, default: Variant = null) -> Variant:
	if value is Dictionary:
		return value.get(property, default)
	if value is Object:
		var getter := "get_" + property
		if value.has_method(getter):
			return value.call(getter)
		for item in value.get_property_list():
			if String(item.get("name", "")) == property:
				return value.get(property)
	return default


static func _read_method(value: Variant, method_name: String, default: Variant = null) -> Variant:
	if value is Dictionary:
		return default
	if value is Object and value.has_method(method_name):
		return value.call(method_name)
	return default


static func _as_array(value: Variant) -> Array:
	if value == null:
		return []
	if value is Array:
		return value.duplicate()
	if value is PackedStringArray:
		var strings: Array = []
		for item in value:
			strings.append(String(item))
		return strings
	if value is PackedByteArray:
		var bytes: Array = []
		for item in value:
			bytes.append(int(item))
		return bytes
	var result: Array = []
	if value is Object and value.has_method("size"):
		for item in value:
			result.append(item)
	return result


static func _plain(value: Variant) -> Variant:
	if value == null:
		return null
	if value is StringName:
		return String(value)
	if value is PackedStringArray or value is PackedByteArray:
		return _as_array(value)
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_plain(item))
		return result
	if value is Dictionary:
		var result_dict: Dictionary = {}
		for key in value:
			result_dict[String(key)] = _plain(value[key])
		return result_dict
	if value is Vector2:
		return [float(value.x), float(value.y)]
	if value is Vector2i:
		return [int(value.x), int(value.y)]
	if value is Object:
		var type_name := _class_name(value)
		if type_name == "LevelTaskValue" or type_name == "Value":
			return project_value(value)
		if _has_member(value, "identifier"):
			return project_resource(value)
		return null
	return value


static func _text(value: Variant) -> String:
	if value is StringName:
		return String(value)
	return String(value)
