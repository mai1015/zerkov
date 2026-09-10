@tool
class_name LtsComponentShowcase
extends Control

## Executable visual fixture for the Level Task System editor design contract.
##
## The showcase is intentionally built from the same reusable controls that a
## future main-screen editor will use. It owns no authored resource state;
## each sample receives plain display data and an explicit component state.
## The public static catalog and state matrix keep the fixture headless-testable
## without EditorInterface.

const CommandButton := preload("res://addons/level_task_system/editor/components/lts_command_button.gd")
const IconButton := preload("res://addons/level_task_system/editor/components/lts_icon_button.gd")
const SearchField := preload("res://addons/level_task_system/editor/components/lts_search_field.gd")
const ResourceRow := preload("res://addons/level_task_system/editor/components/lts_resource_row.gd")
const BreadcrumbItem := preload("res://addons/level_task_system/editor/components/lts_breadcrumb_item.gd")
const GraphNodeCard := preload("res://addons/level_task_system/editor/components/lts_graph_node_card.gd")
const PortRow := preload("res://addons/level_task_system/editor/components/lts_port_row.gd")
const InspectorField := preload("res://addons/level_task_system/editor/components/lts_inspector_field.gd")
const FindingRow := preload("res://addons/level_task_system/editor/components/lts_finding_row.gd")
const StatusBadge := preload("res://addons/level_task_system/editor/components/lts_status_badge.gd")
const Drawer := preload("res://addons/level_task_system/editor/components/lts_drawer.gd")
const EmptyState := preload("res://addons/level_task_system/editor/components/lts_empty_state.gd")
const DegradedState := preload("res://addons/level_task_system/editor/components/lts_degraded_state.gd")
const LtsComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const LtsComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

const COMPONENT_IDS: PackedStringArray = [
	"command_button",
	"icon_button",
	"search_field",
	"resource_row",
	"breadcrumb",
	"graph_node",
	"port_edge",
	"inspector_field",
	"finding_row",
	"status_badge",
	"drawer",
	"empty_state",
	"degraded_state",
]

var _built := false
var _tabs: TabContainer


static func component_ids() -> PackedStringArray:
	return COMPONENT_IDS.duplicate()


static func state_matrix() -> Array[StringName]:
	return LtsComponentState.all_states()


static func component_catalog() -> Array[Dictionary]:
	return [
		{"id": "command_button", "label": "Command button", "description": "Save, validate, simulate, retry, and explicit decisions."},
		{"id": "icon_button", "label": "Icon button", "description": "Native editor icon action with accessible tooltip."},
		{"id": "search_field", "label": "Search / filter field", "description": "Resource and finding filtering with preserved query."},
		{"id": "resource_row", "label": "Resource tree row", "description": "Keyboard-reachable catalog and recent-resource navigation."},
		{"id": "breadcrumb", "label": "Breadcrumb item", "description": "Catalog, resource, and subgraph context."},
		{"id": "graph_node", "label": "Graph node card", "description": "Typed family, stable ID, summary, named ports, and status."},
		{"id": "port_edge", "label": "Port / edge affordance", "description": "Direction, named outcome/type, and connection feedback."},
		{"id": "inspector_field", "label": "Inspector field row", "description": "Contextual field, help text, and safe loading/error behavior."},
		{"id": "finding_row", "label": "Finding row", "description": "Severity, stable diagnostic code, path, and explanation."},
		{"id": "status_badge", "label": "Status badge / inline message", "description": "Dirty, pending, accepted, warning, error, and read-only status."},
		{"id": "drawer", "label": "Drawer tabs and content", "description": "Findings, simulation, trace, and conversation preview."},
		{"id": "empty_state", "label": "Empty state", "description": "Intentional absence with explanation and next action."},
		{"id": "degraded_state", "label": "Degraded native-extension panel", "description": "Bounded read-only diagnostic with build guidance and recovery."},
	]


func _ready() -> void:
	if _built:
		return
	_built = true
	LtsComponentTheme.inherit_editor_theme(self)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_shell()


func _build_shell() -> void:
	var root_column := VBoxContainer.new()
	root_column.name = "ShowcaseColumn"
	root_column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_column.add_theme_constant_override(&"separation", LtsComponentTheme.theme_separation(self, &"VBoxContainer"))
	add_child(root_column)

	var command_bar := VBoxContainer.new()
	command_bar.name = "CommandBar"
	root_column.add_child(command_bar)
	var context_row := HBoxContainer.new()
	context_row.name = "ContextRow"
	command_bar.add_child(context_row)
	var title := Label.new()
	title.name = "Title"
	title.text = "Level Task System / Component showcase"
	title.tooltip_text = title.text
	context_row.add_child(title)
	context_row.add_spacer(false)
	var theme_status := StatusBadge.new()
	theme_status.name = "ThemeStatus"
	theme_status.call("setup", _theme_source_text(), LtsComponentState.DEFAULT)
	context_row.add_child(theme_status)
	var action_row := FlowContainer.new()
	action_row.name = "ActionRow"
	command_bar.add_child(action_row)
	var save := CommandButton.new()
	save.name = "Save"
	save.call("setup", "Save", [&"Save"], "Save document (Ctrl+S)")
	save.connect("command_requested", _on_command_requested.bind("save"))
	action_row.add_child(save)
	var validate := CommandButton.new()
	validate.name = "Validate"
	validate.call("setup", "Validate", [&"Validation", &"Check"], "Validate the complete catalog")
	validate.connect("command_requested", _on_command_requested.bind("validate"))
	action_row.add_child(validate)
	var simulate := CommandButton.new()
	simulate.name = "Simulate"
	simulate.call("setup", "Simulate", [&"Play"], "Run the isolated editor simulator")
	simulate.connect("command_requested", _on_command_requested.bind("simulate"))
	action_row.add_child(simulate)
	var severity := StatusBadge.new()
	severity.name = "SeverityCount"
	severity.call("setup", "2 findings", LtsComponentState.ERROR)
	action_row.add_child(severity)

	var separator := HSeparator.new()
	separator.name = "CommandBarSeparator"
	root_column.add_child(separator)

	_tabs = TabContainer.new()
	_tabs.name = "ShowcaseTabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_column.add_child(_tabs)
	_tabs.add_child(_build_primitive_page())
	_tabs.add_child(_build_graph_page())
	_tabs.add_child(_build_degraded_page())
	_tabs.set_tab_title(0, "Primitives")
	_tabs.set_tab_title(1, "Graph grammar")
	_tabs.set_tab_title(2, "Degraded extension")


func _build_primitive_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "PrimitiveStates"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var column := VBoxContainer.new()
	column.name = "PrimitiveStateColumn"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	var intro := Label.new()
	intro.name = "StateMatrixIntro"
	intro.text = "Native-theme state matrix. Each cell keeps its label, tooltip, and non-color cue."
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.tooltip_text = intro.text
	column.add_child(intro)
	for spec in component_catalog():
		column.add_child(_build_component_section(spec))
	return scroll


func _build_component_section(spec: Dictionary) -> Control:
	var section := PanelContainer.new()
	section.name = String(spec["id"]).capitalize()
	section.theme_type_variation = &"LevelTaskDrawer"
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var column := VBoxContainer.new()
	column.name = "SectionColumn"
	section.add_child(column)
	var heading := Label.new()
	heading.name = "SectionHeading"
	heading.text = String(spec["label"])
	heading.tooltip_text = heading.text
	column.add_child(heading)
	var description := Label.new()
	description.name = "SectionDescription"
	description.text = String(spec["description"])
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.tooltip_text = description.text
	column.add_child(description)
	var matrix := GridContainer.new()
	matrix.name = "StateMatrix"
	# Two columns keep all eight states readable at the 1152 px default
	# viewport. A later product workspace can choose a wider grid when its
	# pane budget allows it; the fixture intentionally never clips a cell.
	matrix.columns = 2
	matrix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(matrix)
	for state in state_matrix():
		matrix.add_child(_build_state_cell(String(spec["id"]), state))
	return section


func _build_state_cell(component_id: String, state: StringName) -> Control:
	var cell := VBoxContainer.new()
	cell.name = "%s_%s" % [component_id, String(state)]
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.tooltip_text = "%s: %s" % [component_id, LtsComponentState.label(state)]
	var state_label := Label.new()
	state_label.text = LtsComponentState.label(state)
	state_label.tooltip_text = state_label.text
	cell.add_child(state_label)
	var sample := _sample_for(component_id, state)
	if sample != null:
		sample.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(sample)
	return cell


func _sample_for(component_id: String, state: StringName) -> Control:
	match component_id:
		"command_button":
			var button := CommandButton.new()
			button.call("setup", "Validate", [&"Validation", &"Check"], "Validate task graph")
			button.call("set_state", state)
			return button
		"icon_button":
			var icon_button := IconButton.new()
			icon_button.call("setup", "Zoom in", [&"ZoomIn", &"Add"], state)
			return icon_button
		"search_field":
			var search := SearchField.new()
			search.call("setup", "Search resources", state)
			if state == LtsComponentState.ACTIVE or state == LtsComponentState.ERROR:
				search.text = "task_graph.main"
			if state == LtsComponentState.ERROR:
				search.call("set_state", state, "Provider failed at catalog/facts: LTS-SEARCH-001")
			return search
		"resource_row":
			var row := ResourceRow.new()
			row.call("setup", "task_graph.main", "res://content/task_graph.main.tres", [&"Graph", &"Node"], state)
			return row
		"breadcrumb":
			var breadcrumb := HBoxContainer.new()
			var root_item := BreadcrumbItem.new()
			root_item.call("setup", "Catalog", "Catalog", state)
			breadcrumb.add_child(root_item)
			var slash := Label.new()
			slash.text = "/"
			slash.tooltip_text = "Breadcrumb separator"
			breadcrumb.add_child(slash)
			var leaf := BreadcrumbItem.new()
			leaf.call("setup", "task_graph.main", "Catalog / Task graphs / task_graph.main", state)
			breadcrumb.add_child(leaf)
			return breadcrumb
		"graph_node":
			var graph_node = GraphNodeCard.new()
			graph_node.name = "StateGraphNode"
			graph_node.call("setup",
				"Condition",
				"Has key",
				"node.condition.has_key",
				"fact: player.key_count >= 1",
				[
					{"direction": "IN", "name": "input", "type": "event"},
					{"direction": "OUT", "name": "true", "type": "outcome"},
					{"direction": "OUT", "name": "false", "type": "outcome"},
				],
				[&"Branch", &"Split", &"Node"]
			)
			graph_node.call("set_state", state)
			graph_node.custom_minimum_size = Vector2(0, 152)
			return graph_node
		"port_edge":
			var port := PortRow.new()
			port.call("setup", "OUT", "success", "outcome", state, "Compatible target: Reward request.accepted")
			return port
		"inspector_field":
			var field := InspectorField.new()
			field.call("setup", "Graph reference", "task_graph.main", "Stable graph identifier", state)
			if state == LtsComponentState.ERROR:
				field.call("set_state", state, "Unknown graph identifier at node.conversation.graph_id")
			return field
		"finding_row":
			var finding := FindingRow.new()
			finding.call("setup", "Warning", "LTS-GRAPH-004", "task_graph.main/node.condition", "Condition has no reachable false outcome", state)
			return finding
		"status_badge":
			var badge := StatusBadge.new()
			badge.call("setup", "Catalog status", state)
			return badge
		"drawer":
			var drawer := Drawer.new()
			drawer.call("setup", state)
			return drawer
		"empty_state":
			var empty := EmptyState.new()
			empty.call("setup", "No task graph selected", "Choose a resource from the navigator or create a task graph.", "Create task graph", state)
			return empty
		"degraded_state":
			var degraded := DegradedState.new()
			degraded.call("setup", "Native extension unavailable", "Build and load the GDExtension before editing definitions.", "Required: LevelTaskSystemVersion | path: addons/level_task_system/level_task_system.gdextension | code: LTS-NATIVE-001", state)
			return degraded
	return null


func _build_graph_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "GraphGrammar"
	var heading := Label.new()
	heading.text = "Representative task graph / named ports and non-color cues"
	heading.tooltip_text = heading.text
	page.add_child(heading)
	var toolbar := HBoxContainer.new()
	toolbar.name = "GraphToolbar"
	page.add_child(toolbar)
	var grid := IconButton.new()
	grid.call("setup", "Toggle grid", [&"grid_toggle", &"Grid"], LtsComponentState.ACTIVE)
	toolbar.add_child(grid)
	var snap := IconButton.new()
	snap.call("setup", "Toggle snapping", [&"snapping_toggle", &"Snap"], LtsComponentState.DEFAULT)
	toolbar.add_child(snap)
	var arrange := CommandButton.new()
	arrange.call("setup", "Auto-arrange", [&"layout", &"Arrange"], "Deterministically arrange the graph")
	toolbar.add_child(arrange)
	var graph_note := Label.new()
	graph_note.text = "GraphEdit owns grid, zoom, minimap, snapping, and port hotzones."
	graph_note.tooltip_text = graph_note.text
	toolbar.add_child(graph_note)

	var graph := GraphEdit.new()
	graph.name = "RepresentativeGraph"
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# These are native GraphEdit properties; no custom grid or connection
	# drawing is introduced by the showcase.
	graph.set("show_grid", true)
	graph.set("use_snap", true)
	graph.set("snapping_distance", 16)
	page.add_child(graph)
	_build_representative_graph(graph)
	var drawer := Drawer.new()
	drawer.name = "GraphTraceDrawer"
	drawer.call("setup", LtsComponentState.ACTIVE)
	drawer.custom_minimum_size = Vector2(0, 84)
	page.add_child(drawer)
	return page


func _build_representative_graph(graph: GraphEdit) -> void:
	var nodes: Array[Dictionary] = [
		{"name": "Entry", "family": "Entry", "title": "Start", "id": "node.entry", "summary": "entry label: start", "ports": [{"direction": "OUT", "name": "entry", "type": "outcome"}], "icons": [&"Play", &"ArrowRight", &"Node"], "position": Vector2(40, 180), "state": LtsComponentState.DEFAULT},
		{"name": "Objective", "family": "Objective", "title": "Collect key", "id": "node.objective.collect_key", "summary": "event: item.collected | 0 / 1", "ports": [{"direction": "IN", "name": "input", "type": "event"}, {"direction": "OUT", "name": "success", "type": "outcome"}], "icons": [&"Target", &"Flag", &"Node"], "position": Vector2(300, 80), "state": LtsComponentState.ACTIVE},
		{"name": "Condition", "family": "Condition", "title": "Has key", "id": "node.condition.has_key", "summary": "fact: player.key_count >= 1", "ports": [{"direction": "IN", "name": "input", "type": "event"}, {"direction": "OUT", "name": "true", "type": "outcome"}, {"direction": "OUT", "name": "false", "type": "outcome"}], "icons": [&"Branch", &"Split", &"Node"], "position": Vector2(560, 80), "state": LtsComponentState.ERROR},
		{"name": "AllGate", "family": "All gate", "title": "All objectives", "id": "node.gate.all", "summary": "2 inputs converge", "ports": [{"direction": "IN", "name": "objective_a", "type": "outcome"}, {"direction": "IN", "name": "objective_b", "type": "outcome"}, {"direction": "OUT", "name": "all", "type": "outcome"}], "icons": [&"Merge", &"Join", &"Node"], "position": Vector2(820, 20), "state": LtsComponentState.FOCUS},
		{"name": "AnyGate", "family": "Any gate", "title": "Any objective", "id": "node.gate.any", "summary": "first matching input wins", "ports": [{"direction": "IN", "name": "objective", "type": "outcome"}, {"direction": "OUT", "name": "any", "type": "outcome"}], "icons": [&"Merge", &"Join", &"Node"], "position": Vector2(820, 260), "state": LtsComponentState.DEFAULT},
		{"name": "External", "family": "External action", "title": "Open door", "id": "node.action.open_door", "summary": "request / acknowledgement", "ports": [{"direction": "IN", "name": "input", "type": "outcome"}, {"direction": "OUT", "name": "accepted", "type": "outcome"}, {"direction": "OUT", "name": "rejected", "type": "outcome"}], "icons": [&"Link", &"Gear", &"Node"], "position": Vector2(1080, 90), "state": LtsComponentState.LOADING},
		{"name": "Conversation", "family": "Conversation", "title": "Guard dialogue", "id": "node.conversation.guard", "summary": "conversation.guard | entry: start", "ports": [{"direction": "IN", "name": "input", "type": "outcome"}, {"direction": "OUT", "name": "accepted", "type": "outcome"}, {"direction": "OUT", "name": "declined", "type": "outcome"}], "icons": [&"Script", &"Chat", &"Node"], "position": Vector2(1080, 300), "state": LtsComponentState.DEFAULT},
		{"name": "Subgraph", "family": "Subgraph", "title": "Extraction branch", "id": "node.subgraph.extraction", "summary": "graph: graph.extraction", "ports": [{"direction": "IN", "name": "input", "type": "outcome"}, {"direction": "OUT", "name": "success", "type": "outcome"}], "icons": [&"Instance", &"Folder", &"Node"], "position": Vector2(1330, 40), "state": LtsComponentState.DEFAULT},
		{"name": "Reward", "family": "Reward request", "title": "Grant cache", "id": "node.reward.cache", "summary": "provider: inventory | request", "ports": [{"direction": "IN", "name": "input", "type": "outcome"}, {"direction": "OUT", "name": "accepted", "type": "outcome"}, {"direction": "OUT", "name": "rejected", "type": "outcome"}], "icons": [&"Add", &"Package", &"Node"], "position": Vector2(1580, 170), "state": LtsComponentState.DEFAULT},
		{"name": "Success", "family": "Success terminal", "title": "Success", "id": "node.terminal.success", "summary": "terminal outcome", "ports": [], "icons": [&"Check", &"StatusSuccess", &"Node"], "position": Vector2(1830, 130), "state": LtsComponentState.DEFAULT},
		{"name": "Failure", "family": "Failure terminal", "title": "Failure", "id": "node.terminal.failure", "summary": "terminal outcome", "ports": [], "icons": [&"Error", &"StatusError", &"Node"], "position": Vector2(1830, 300), "state": LtsComponentState.DEFAULT},
		{"name": "Cancelled", "family": "Cancelled terminal", "title": "Cancelled", "id": "node.terminal.cancelled", "summary": "terminal outcome", "ports": [], "icons": [&"Stop", &"Cancel", &"Node"], "position": Vector2(1830, 470), "state": LtsComponentState.DEFAULT},
	]
	var controls: Dictionary = {}
	for data in nodes:
		var node = GraphNodeCard.new()
		node.name = String(data["name"])
		node.call("setup", String(data["family"]), String(data["title"]), String(data["id"]), String(data["summary"]), data["ports"], data["icons"])
		node.call("set_state", data["state"])
		node.position_offset = data["position"]
		graph.add_child(node)
		controls[node.name] = node

	# GraphEdit ports are ordered by each node's enabled output/input slots.
	# The visible port labels on every card remain the source for authoring.
	graph.connect_node("Entry", 0, "Objective", 0)
	graph.connect_node("Objective", 0, "Condition", 0)
	graph.connect_node("Condition", 0, "AllGate", 0)
	graph.connect_node("Condition", 1, "AnyGate", 0)
	graph.connect_node("AllGate", 0, "External", 0)
	graph.connect_node("AnyGate", 0, "Conversation", 0)
	graph.connect_node("External", 0, "Subgraph", 0)
	graph.connect_node("External", 1, "Failure", 0)
	graph.connect_node("Conversation", 0, "Reward", 0)
	graph.connect_node("Conversation", 1, "Cancelled", 0)
	graph.connect_node("Subgraph", 0, "Reward", 0)
	graph.connect_node("Reward", 0, "Success", 0)
	graph.connect_node("Reward", 1, "Failure", 0)


func _build_degraded_page() -> Control:
	var page := VBoxContainer.new()
	page.name = "DegradedExtension"
	var heading := Label.new()
	heading.text = "Native-extension availability / bounded read-only state"
	heading.tooltip_text = heading.text
	page.add_child(heading)
	var explanation := Label.new()
	explanation.text = "Semantic fields and graph mutations remain disabled until the registered class set is compatible."
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.tooltip_text = explanation.text
	page.add_child(explanation)
	var degraded := DegradedState.new()
	degraded.name = "NativeExtensionDiagnostic"
	degraded.size_flags_vertical = Control.SIZE_EXPAND_FILL
	degraded.call("setup",
		"Native extension unavailable",
		"Build the pinned GDExtension for this platform, then refresh the editor.",
		"Required: LevelTaskSystemVersion | detected: unavailable | path: addons/level_task_system/level_task_system.gdextension | code: LTS-NATIVE-001",
		LtsComponentState.ERROR
	)
	page.add_child(degraded)
	return page


func _theme_source_text() -> String:
	if Engine.is_editor_hint():
		return "Theme: active Godot editor theme"
	return "Theme: inherited project fallback"


func _on_command_requested(command: String) -> void:
	# This is a visual fixture: commands report intent without mutating a
	# document, preserving the model/source-of-truth boundary.
	var badge = get_node_or_null("ShowcaseColumn/CommandBar/ContextRow/ThemeStatus")
	if badge != null:
		badge.call("setup", "Requested " + command, LtsComponentState.ACTIVE)
