@tool
class_name LtsGraphNodeCard
extends GraphNode

## GraphNode projection for the component fixture. The data fields are
## deliberately plain values so a later document projection can own them;
## this control never mutates an authored resource.

const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var family_label := "Entry"
var family_icon_names: Array = [&"Play", &"ArrowRight", &"Node"]
var node_title := "Start level"
var stable_identifier := "node.entry"
var field_summary := "entry label: start"
var port_definitions: Array = [
	{"direction": "OUT", "name": "entry", "type": "outcome"},
]
var _state: StringName = LtsComponentState.DEFAULT
var _built := false


func _init() -> void:
	theme_type_variation = &"LevelTaskGraphNode"
	focus_mode = Control.FOCUS_ALL
	resizable = false


func _ready() -> void:
	_built = true
	_rebuild()


func setup(family: String, title_text: String, identifier: String, summary: String, ports: Array, icons: Array = []) -> LtsGraphNodeCard:
	family_label = family
	node_title = title_text
	stable_identifier = identifier
	field_summary = summary
	port_definitions = ports.duplicate(true)
	if not icons.is_empty():
		family_icon_names = icons.duplicate()
	_rebuild()
	return self


func set_state(value: Variant) -> void:
	_state = LtsComponentState.normalize(value)
	_rebuild()


func get_state() -> StringName:
	return _state


func _rebuild() -> void:
	if not _built and not is_inside_tree():
		return
	for child in get_children():
		remove_child(child)
		child.free()
	var normalized := LtsComponentState.normalize(_state)
	title = node_title
	tooltip_text = "%s (%s)" % [stable_identifier, family_label]
	set_selected(normalized == LtsComponentState.ACTIVE)
	var icon := TextureRect.new()
	icon.name = "FamilyIcon"
	icon.texture = LtsComponentTheme.resolve_icon(self, family_icon_names, &"Node")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, get_theme_font_size(&"font_size", &"Label"))
	icon.tooltip_text = family_label + " family"
	add_child(icon)

	var family := Label.new()
	family.name = "FamilyLabel"
	family.text = family_label + " family"
	family.tooltip_text = family_label
	add_child(family)

	var identifier := Label.new()
	identifier.name = "StableIdentifier"
	identifier.text = stable_identifier
	identifier.tooltip_text = stable_identifier
	add_child(identifier)

	var summary := Label.new()
	summary.name = "FieldSummary"
	summary.text = _summary_for_state(normalized)
	summary.tooltip_text = field_summary
	add_child(summary)

	var status := Label.new()
	status.name = "StatusMarker"
	status.text = _status_for_state(normalized)
	status.tooltip_text = status.text
	LtsComponentTheme.apply_state_text(status, normalized, status.text)
	add_child(status)

	var slot_color := LtsComponentTheme.graph_port_color(self)
	var slot_index := 5
	for port in port_definitions:
		var row := Label.new()
		row.name = "Port_%s" % String(port.get("name", "port"))
		var direction := String(port.get("direction", "OUT")).to_upper()
		var port_name := String(port.get("name", "outcome"))
		var port_type := String(port.get("type", "outcome"))
		row.text = "%s  %s : %s" % [direction, port_name, port_type]
		row.tooltip_text = "%s port '%s' (%s)" % [direction, port_name, port_type]
		add_child(row)
		var left_enabled := direction == "IN"
		var right_enabled := not left_enabled
		set_slot(slot_index, left_enabled, 0, slot_color, right_enabled, 0, slot_color)
		slot_index += 1
	if normalized == LtsComponentState.EMPTY:
		var empty := Label.new()
		empty.name = "EmptyPortMessage"
		empty.text = "No ports configured"
		empty.tooltip_text = "This node has no configured ports"
		add_child(empty)
	if normalized == LtsComponentState.ERROR:
		var error := Label.new()
		error.name = "ErrorCode"
		error.text = "Error LTS-GRAPH-001: inspect node"
		error.tooltip_text = error.text
		LtsComponentTheme.apply_state_text(error, normalized, error.text)
		add_child(error)
	if normalized == LtsComponentState.DISABLED:
		process_mode = Node.PROCESS_MODE_DISABLED
	else:
		process_mode = Node.PROCESS_MODE_INHERIT


func _summary_for_state(state: StringName) -> String:
	match state:
		LtsComponentState.LOADING:
			return field_summary + " | Loading..."
		LtsComponentState.EMPTY:
			return "No authored fields"
		LtsComponentState.ERROR:
			return field_summary + " | invalid"
		LtsComponentState.DISABLED:
			return field_summary + " | read-only"
		_:
			return field_summary


func _status_for_state(state: StringName) -> String:
	match state:
		LtsComponentState.HOVER:
			return "Hover target"
		LtsComponentState.ACTIVE:
			return "Selected"
		LtsComponentState.FOCUS:
			return "Keyboard focus"
		LtsComponentState.DISABLED:
			return "Read-only"
		LtsComponentState.LOADING:
			return "Loading..."
		LtsComponentState.EMPTY:
			return "Empty"
		LtsComponentState.ERROR:
			return "Error LTS-GRAPH-001"
		_:
			return "Ready"
