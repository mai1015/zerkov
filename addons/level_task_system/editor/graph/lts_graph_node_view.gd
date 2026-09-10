@tool
class_name LtsGraphNodeView
extends GraphNode

## Native GraphNode projection for one task-node dictionary.
##
## Node data and layout are copied from the document projection.  This view
## never edits either dictionary; port activation and subgraph navigation are
## signals for LtsGraphCanvas to turn into document-command intents.

signal port_activated(node_identifier: String, port_identifier: String, direction: String)
signal subgraph_open_requested(node_identifier: String, subgraph_identifier: String)

const Logic := preload("res://addons/level_task_system/editor/graph/lts_graph_canvas_logic.gd")
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const ComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")
const PortRow := preload("res://addons/level_task_system/editor/components/lts_port_row.gd")

var node_data: Dictionary = {}
var node_identifier := ""
var family: Dictionary = {}
var port_definitions: Array = []
var validation_message := ""
var activity_message := ""

var _state: StringName = ComponentState.DEFAULT
var _built := false
var _port_rows: Dictionary = {}
var _input_port_identifiers: Array = []
var _output_port_identifiers: Array = []
var _subgraph_identifier := ""


func _init() -> void:
	theme_type_variation = &"LevelTaskGraphNode"
	custom_minimum_size.x = 280.0
	focus_mode = Control.FOCUS_ALL
	resizable = false
	selectable = true
	draggable = true
	ignore_invalid_connection_type = true


func _ready() -> void:
	_built = true
	_rebuild()


func setup(document_node: Dictionary, state: Variant = ComponentState.DEFAULT, detail: String = "") -> LtsGraphNodeView:
	node_data = document_node.duplicate(true)
	node_identifier = String(node_data.get("identifier", ""))
	family = Logic.family_for_node(node_data)
	port_definitions = _effective_ports(node_data, family)
	_state = ComponentState.normalize(state)
	validation_message = detail
	_subgraph_identifier = String(node_data.get("subgraph_identifier", ""))
	_rebuild()
	return self


func set_node_data(document_node: Dictionary) -> void:
	setup(document_node, _state, validation_message)


func get_node_data() -> Dictionary:
	return node_data.duplicate(true)


func set_state(value: Variant, detail: String = "") -> void:
	_state = ComponentState.normalize(value)
	if not detail.is_empty():
		validation_message = detail
	_rebuild()


func get_state() -> StringName:
	return _state


func set_validation(detail: String, state: Variant = ComponentState.ERROR) -> void:
	validation_message = detail
	set_state(state)


func set_activity(detail: String, state: Variant = ComponentState.LOADING) -> void:
	activity_message = detail
	set_state(state)


func clear_activity() -> void:
	activity_message = ""
	if _state == ComponentState.LOADING:
		set_state(ComponentState.DEFAULT)


func get_port_identifier(direction: Variant, port_index: int) -> String:
	var identifiers := _input_port_identifiers if Logic.port_direction(direction) == "IN" else _output_port_identifiers
	if port_index < 0 or port_index >= identifiers.size():
		return ""
	return String(identifiers[port_index])


func get_port_index(direction: Variant, port_identifier: String) -> int:
	var identifiers := _input_port_identifiers if Logic.port_direction(direction) == "IN" else _output_port_identifiers
	return identifiers.find(port_identifier)


func get_port_definition(port_identifier: String) -> Dictionary:
	for raw_port in port_definitions:
		if not raw_port is Dictionary:
			continue
		var port := Logic.normalize_port(raw_port)
		if String(port.get("identifier", "")) == port_identifier:
			return port
	return {}


func get_port_definition_by_index(direction: Variant, port_index: int) -> Dictionary:
	var identifier := get_port_identifier(direction, port_index)
	return get_port_definition(identifier)


func get_port_count(direction: Variant) -> int:
	return _input_port_identifiers.size() if Logic.port_direction(direction) == "IN" else _output_port_identifiers.size()


func get_port_rows() -> Dictionary:
	return _port_rows.duplicate()


func set_port_feedback(port_identifier: String, state: Variant, detail: String = "") -> void:
	var row = _port_rows.get(port_identifier, null)
	if row == null:
		return
	row.call("set_state", state, detail)


func clear_port_feedback() -> void:
	for port_identifier in _port_rows:
		var row = _port_rows[port_identifier]
		if row != null:
			row.call("set_state", ComponentState.DEFAULT)


func _rebuild() -> void:
	if not _built and not is_inside_tree():
		return
	for child in get_children():
		remove_child(child)
		child.free()
	clear_all_slots()
	_port_rows.clear()
	_input_port_identifiers.clear()
	_output_port_identifiers.clear()

	var normalized := ComponentState.normalize(_state)
	var family_label := String(family.get("label", node_data.get("family", "Task node")))
	var title_text := _title_for_node(node_data)
	title = title_text
	tooltip_text = "%s (%s)" % [node_identifier, family_label]
	set_selected(normalized == ComponentState.ACTIVE)
	process_mode = Node.PROCESS_MODE_DISABLED if normalized == ComponentState.DISABLED else Node.PROCESS_MODE_INHERIT

	var header := HBoxContainer.new()
	header.name = "FamilyHeader"
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(header)
	var icon := TextureRect.new()
	icon.name = "FamilyIcon"
	icon.texture = ComponentTheme.resolve_icon(self, family.get("icons", [&"Node"]), &"Node")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(get_theme_font_size(&"font_size", &"Label"), get_theme_font_size(&"font_size", &"Label"))
	icon.tooltip_text = family_label + " family"
	header.add_child(icon)
	var family_name := Label.new()
	family_name.name = "FamilyLabel"
	family_name.text = family_label
	family_name.tooltip_text = family_label
	family_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	family_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	family_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(family_name)
	var status := Label.new()
	status.name = "StatusMarker"
	status.text = _status_text(normalized)
	status.tooltip_text = status.text
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ComponentTheme.apply_state_text(status, normalized, status.text)
	header.add_child(status)

	var identifier_label := Label.new()
	identifier_label.name = "StableIdentifier"
	identifier_label.text = node_identifier
	identifier_label.tooltip_text = node_identifier
	identifier_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(identifier_label)

	var summary := Label.new()
	summary.name = "FieldSummary"
	summary.text = _summary_text(normalized)
	summary.tooltip_text = _summary_text(normalized)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(summary)

	if not activity_message.is_empty():
		var activity := Label.new()
		activity.name = "ActivityMarker"
		activity.text = activity_message
		activity.tooltip_text = activity_message
		activity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ComponentTheme.apply_state_text(activity, ComponentState.LOADING, activity.text)
		add_child(activity)

	if not validation_message.is_empty() or normalized == ComponentState.ERROR:
		var diagnostic := Label.new()
		diagnostic.name = "Diagnostic"
		diagnostic.text = "[error] " + (validation_message if not validation_message.is_empty() else "LTS-GRAPH-NODE-001: inspect node")
		diagnostic.tooltip_text = diagnostic.text
		diagnostic.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		diagnostic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ComponentTheme.apply_state_text(diagnostic, ComponentState.ERROR, diagnostic.text)
		add_child(diagnostic)

	if not _subgraph_identifier.is_empty():
		var open_button := Button.new()
		open_button.name = "OpenSubgraph"
		open_button.text = "Open subgraph"
		open_button.tooltip_text = "Open subgraph %s" % _subgraph_identifier
		open_button.icon = ComponentTheme.resolve_icon(self, [&"Instance", &"Folder", &"Node"], &"Node")
		open_button.focus_mode = Control.FOCUS_ALL
		open_button.pressed.connect(_on_open_subgraph)
		add_child(open_button)

	if port_definitions.is_empty():
		var no_ports := Label.new()
		no_ports.name = "NoPorts"
		no_ports.text = "TERMINAL — no outgoing ports"
		no_ports.tooltip_text = "This node has no configured ports"
		no_ports.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(no_ports)
	else:
		for raw_port in port_definitions:
			if not raw_port is Dictionary:
				continue
			var port := Logic.normalize_port(raw_port)
			var port_identifier := String(port.get("identifier", "port"))
			var direction := String(port.get("direction", "OUT"))
			if direction == "IN":
				_input_port_identifiers.append(port_identifier)
			else:
				_output_port_identifiers.append(port_identifier)
			var row := PortRow.new()
			row.name = "Port_%s" % _safe_name(port_identifier)
			row.call("setup", direction, port.get("name", port_identifier), Logic.value_type_name(port.get("value_type", Logic.VALUE_NONE)), ComponentState.DEFAULT, _port_tooltip(port))
			row.focus_mode = Control.FOCUS_NONE
			row.mouse_filter = Control.MOUSE_FILTER_PASS
			row.connect("port_activated", _on_port_row_activated.bind(port_identifier, direction))
			add_child(row)
			_port_rows[port_identifier] = row
			var slot_index := get_child_count() - 1
			var type_id := int(port.get("value_type", Logic.VALUE_NONE))
			var slot_color := ComponentTheme.graph_port_color(self)
			set_slot(slot_index, direction == "IN", type_id, slot_color, direction == "OUT", type_id, slot_color)

	if normalized == ComponentState.EMPTY:
		var empty := Label.new()
		empty.name = "EmptyMessage"
		empty.text = "No authored fields"
		empty.tooltip_text = empty.text
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(empty)


func _effective_ports(document_node: Dictionary, node_family: Dictionary) -> Array:
	var raw_ports = document_node.get("ports", [])
	if raw_ports is Array and not raw_ports.is_empty():
		return raw_ports.duplicate(true)
	return node_family.get("ports", []).duplicate(true)


func _title_for_node(document_node: Dictionary) -> String:
	for key in ["title", "display_name", "name"]:
		var value := String(document_node.get(key, ""))
		if not value.is_empty():
			return value
	var identifier := String(document_node.get("identifier", "Task node"))
	var pieces := identifier.split(".", false)
	return String(pieces[pieces.size() - 1]) if not pieces.is_empty() else identifier


func _summary_text(state: StringName) -> String:
	var base := String(family.get("summary", "Task node"))
	for key in ["provider_identifier", "conversation_identifier", "subgraph_identifier", "outcome_identifier"]:
		var value := String(node_data.get(key, ""))
		if not value.is_empty():
			base += " | %s: %s" % [key.trim_suffix("_identifier"), value]
	if node_data.has("objective_target"):
		base += " | target: %d" % int(node_data.get("objective_target", 1))
	match state:
		ComponentState.DISABLED:
			return base + " | read-only"
		ComponentState.LOADING:
			return base + " | Loading..."
		ComponentState.ERROR:
			return base + " | invalid"
		ComponentState.EMPTY:
			return "No authored fields"
		_:
			return base


func _status_text(state: StringName) -> String:
	match state:
		ComponentState.ACTIVE:
			return "[selected]"
		ComponentState.FOCUS:
			return "[keyboard focus]"
		ComponentState.DISABLED:
			return "[read-only]"
		ComponentState.LOADING:
			return "[loading]"
		ComponentState.EMPTY:
			return "[empty]"
		ComponentState.ERROR:
			return "[error]"
		_:
			return "[ready]"


func _port_tooltip(port: Dictionary) -> String:
	var direction := String(port.get("direction", "OUT"))
	var identifier := String(port.get("identifier", "port"))
	return "%s port '%s' (%s)%s" % [direction, identifier, Logic.value_type_name(port.get("value_type", Logic.VALUE_NONE)), " — required" if bool(port.get("required", false)) else ""]


func _on_port_row_activated(port_identifier: String, direction: String) -> void:
	port_activated.emit(node_identifier, port_identifier, direction)


func _on_open_subgraph() -> void:
	if not _subgraph_identifier.is_empty():
		subgraph_open_requested.emit(node_identifier, _subgraph_identifier)


func _safe_name(value: String) -> String:
	var result := value.replace("/", "_").replace(" ", "_").replace(":", "_")
	return result if not result.is_empty() else "port"
