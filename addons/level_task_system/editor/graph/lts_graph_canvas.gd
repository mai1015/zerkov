@tool
class_name LtsGraphCanvas
extends GraphEdit

## Reusable task-graph authoring surface.
##
## LtsGraphCanvas is intentionally a projection.  It reads a graph and its
## editor layout from LtsDocumentModel, renders native GraphNode/GraphFrame
## elements, and turns author gestures into serializable
## LtsDocumentCommand intents.  When a model is supplied, commands are
## applied through that model and the canvas is refreshed from the committed
## projection.  Without a model, commands are emitted for a workspace to
## route; this class never becomes the source of truth.

signal command_requested(command: Dictionary)
signal document_command_requested(command: Dictionary)
signal command_applied(command: Dictionary, result: Dictionary)
signal command_rejected(command: Dictionary, error: Dictionary)
signal mutation_rejected(error: Dictionary)

signal graph_opened(graph_identifier: String)
signal graph_projection_changed(graph_identifier: String)
signal selection_changed(node_identifiers: Array)
signal selection_projection_changed(node_identifiers: Array)
signal view_state_changed(view_state: Dictionary)

signal connection_feedback_changed(feedback: Dictionary)
signal connection_rejected(feedback: Dictionary)
signal quick_add_menu_opened(context: Dictionary)
signal quick_add_node_requested(node: Dictionary, edge: Dictionary, context: Dictionary)
signal clipboard_changed(fragment: Dictionary)

signal breadcrumb_changed(items: Array)
signal breadcrumb_requested(index: int, item: Dictionary)
signal subgraph_navigation_requested(graph_identifier: String, node_identifier: String, subgraph_identifier: String)

signal frame_command_requested(frame_identifier: String, command: Dictionary)
signal frame_changed(frame_identifier: String, rect: Rect2)
signal debug_breakpoint_toggled(kind: String, identifier: String, enabled: bool)

const Logic := preload("res://addons/level_task_system/editor/graph/lts_graph_canvas_logic.gd")
const NodeView := preload("res://addons/level_task_system/editor/graph/lts_graph_node_view.gd")
const DocumentCommand := preload("res://addons/level_task_system/editor/document/lts_document_command.gd")
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const ComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")
const CommandButton := preload("res://addons/level_task_system/editor/components/lts_command_button.gd")
const BreadcrumbItem := preload("res://addons/level_task_system/editor/components/lts_breadcrumb_item.gd")
const EmptyState := preload("res://addons/level_task_system/editor/components/lts_empty_state.gd")
const DegradedState := preload("res://addons/level_task_system/editor/components/lts_degraded_state.gd")

@export var route_commands_through_model := true
@export var default_snapping_distance := 16
@export var default_minimap_size := Vector2(180, 120)

var graph_identifier := ""

var _document_model: Object
var _graph_document: Dictionary = {}
var _graph_layout: Dictionary = {}
var _node_views: Dictionary = {}
var _frame_views: Dictionary = {}
var _owned_elements: Array[Node] = []
var _last_positions: Dictionary = {}
var _move_start_positions: Dictionary = {}
var _move_in_progress := false
var _refresh_in_progress := false

var _validation_by_node: Dictionary = {}
var _validation_by_edge: Dictionary = {}
var _edge_activity: Dictionary = {}
var _debug_model: Object
var _debug_projection: Dictionary = {}
var _last_connection_feedback: Dictionary = {}
var _pending_connection: Dictionary = {}
var _clipboard_fragment: Dictionary = {}

var _selection_flush_queued := false
var _suppress_projection_events := false
var _built := false

var _command_overlay: PanelContainer
var _command_row: HBoxContainer
var _quick_add_button: Button
var _arrange_button: Button
var _breakpoint_button: Button
var _feedback_label: Label
var _breadcrumb_bar: HBoxContainer
var _empty_overlay: EmptyState
var _degraded_overlay: DegradedState

var _quick_add_popup: PopupPanel
var _quick_add_tree: Tree
var _quick_add_search: LineEdit
var _quick_add_title: Label

var _breadcrumbs: Array = []


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	if _built:
		return
	_built = true
	ComponentTheme.inherit_editor_theme(self)
	_configure_native_graph()
	_build_command_overlay()
	_build_quick_add_popup()
	_connect_graph_signals()
	resized.connect(_update_overlay_layout)
	_update_native_state()
	_update_empty_state()
	_refresh_projection()
	_update_overlay_layout()


## Attach a document model.  The model may be LtsDocumentModel or a headless
## double implementing get_document/get_layout/apply_command/is_degraded.
func set_document_model(model: Object) -> void:
	_document_model = model
	_refresh_projection()


func get_document_model() -> Object:
	return _document_model


func set_graph_identifier(identifier: String) -> void:
	graph_identifier = identifier
	_refresh_projection()


func get_graph_identifier() -> String:
	return graph_identifier


## Set a projection directly for previews/tests.  The supplied dictionaries
## remain owned by the caller; the canvas keeps a deep copy only for paint and
## command construction.
func set_graph_document(document: Dictionary, layout: Dictionary = {}) -> void:
	_graph_document = document.duplicate(true)
	_graph_layout = layout.duplicate(true)
	if graph_identifier.is_empty():
		graph_identifier = String(_graph_document.get("identifier", ""))
	_refresh_projection()


func set_document(document: Dictionary, layout: Dictionary = {}) -> void:
	set_graph_document(document, layout)


func open_graph(document: Dictionary, layout: Dictionary = {}) -> void:
	set_graph_document(document, layout)
	graph_opened.emit(graph_identifier)


func refresh_from_document() -> void:
	_refresh_projection()


func refresh() -> void:
	_refresh_projection()


func get_graph_document() -> Dictionary:
	return _graph_document.duplicate(true)


func get_graph_layout() -> Dictionary:
	return _graph_layout.duplicate(true)


func is_graph_read_only() -> bool:
	return _is_read_only()


func get_last_connection_feedback() -> Dictionary:
	return _last_connection_feedback.duplicate(true)


func get_selected_node_identifiers() -> Array:
	var result: Array = []
	for identifier in _node_views:
		var view = _node_views[identifier]
		if view != null and bool(view.selected):
			result.append(String(identifier))
	result.sort()
	return result


## Attach editor-only simulation state. Breakpoints and activity stay outside
## the authored document and are never routed through document commands.
func set_debug_model(model: Object) -> void:
	if _debug_model != null and _debug_model.has_signal("activity_changed"):
		var previous := Callable(self, "_on_debug_projection_changed")
		if _debug_model.is_connected("activity_changed", previous):
			_debug_model.disconnect("activity_changed", previous)
	_debug_model = model
	if _debug_model != null and _debug_model.has_signal("activity_changed"):
		_debug_model.connect("activity_changed", Callable(self, "_on_debug_projection_changed"))
	if _debug_model != null and _debug_model.has_method("get_projection"):
		apply_debug_projection(_debug_model.call("get_projection"))
	else:
		apply_debug_projection({})


func get_debug_model() -> Object:
	return _debug_model


func apply_debug_projection(projection: Dictionary) -> void:
	_debug_projection = projection.duplicate(true)
	for identifier in _node_views:
		var view = _node_views[identifier]
		if view != null and view.has_method("clear_activity"):
			view.call("clear_activity")
	for edge_identifier in _edge_activity.keys():
		clear_edge_activity(String(edge_identifier))
	_edge_activity.clear()
	var node_activity: Dictionary = projection.get("node_activity", {}) if projection.get("node_activity", {}) is Dictionary else {}
	for identifier_value in node_activity:
		var identifier := String(identifier_value)
		var activity: Dictionary = node_activity[identifier_value] if node_activity[identifier_value] is Dictionary else {}
		var view = _node_views.get(identifier, null)
		if view == null or not view.has_method("set_activity"):
			continue
		var detail := String(activity.get("text", activity.get("label", "")))
		if detail.is_empty() and not bool(activity.get("breakpoint", false)):
			continue
		view.call("set_activity", detail if not detail.is_empty() else "◆ Breakpoint armed", _component_state_for_debug(activity))
	var edge_activity: Dictionary = projection.get("edge_activity", {}) if projection.get("edge_activity", {}) is Dictionary else {}
	for identifier_value in edge_activity:
		var activity: Dictionary = edge_activity[identifier_value] if edge_activity[identifier_value] is Dictionary else {}
		set_edge_activity(String(identifier_value), float(activity.get("amount", 1.0)), String(activity.get("state", "active")))
	_update_breakpoint_button()


func toggle_selected_breakpoint() -> Dictionary:
	var selected := get_selected_node_identifiers()
	if selected.is_empty():
		return {"ok": false, "error": {"code": "LTS-DEBUG-001", "message": "Select a node before toggling a breakpoint.", "path": "graph.selection"}}
	if _debug_model == null or not _debug_model.has_method("toggle_node_breakpoint"):
		return {"ok": false, "error": {"code": "LTS-DEBUG-002", "message": "No graph debug model is attached.", "path": "graph.debug"}}
	var identifier := String(selected[0])
	var result: Dictionary = _debug_model.call("toggle_node_breakpoint", identifier)
	if bool(result.get("ok", false)):
		var enabled := bool(_debug_model.call("has_breakpoint", identifier, "node")) if _debug_model.has_method("has_breakpoint") else false
		debug_breakpoint_toggled.emit("node", identifier, enabled)
		if _debug_model.has_method("get_projection"):
			apply_debug_projection(_debug_model.call("get_projection"))
	return result


func set_selected_node_identifiers(identifiers: Array, emit_intent := false) -> void:
	_suppress_projection_events = true
	for identifier in _node_views:
		var view = _node_views[identifier]
		if view != null:
			view.set_selected(identifiers.has(String(identifier)))
	_suppress_projection_events = false
	if emit_intent:
		_flush_selection_projection()


func select_all_nodes() -> void:
	set_selected_node_identifiers(_node_views.keys(), true)


func get_view_state() -> Dictionary:
	return {
		"zoom": get_zoom(),
		"scroll_offset": get_scroll_offset(),
		"show_grid": is_showing_grid(),
		"snapping_enabled": is_snapping_enabled(),
		"snapping_distance": get_snapping_distance(),
		"minimap_enabled": is_minimap_enabled(),
	}


func set_view_state(state: Dictionary) -> void:
	if state.has("zoom"):
		set_zoom(clampf(float(state["zoom"]), get_zoom_min(), get_zoom_max()))
	if state.has("scroll_offset"):
		set_scroll_offset(_vector2_from_variant(state["scroll_offset"]))
	if state.has("show_grid"):
		set_show_grid(bool(state["show_grid"]))
	if state.has("snapping_enabled"):
		set_snapping_enabled(bool(state["snapping_enabled"]))
	if state.has("snapping_distance"):
		set_snapping_distance(maxi(1, int(state["snapping_distance"])))
	if state.has("minimap_enabled"):
		set_minimap_enabled(bool(state["minimap_enabled"]))
	view_state_changed.emit(get_view_state())


func zoom_in() -> void:
	set_zoom(minf(get_zoom_max(), get_zoom() + get_zoom_step()))
	view_state_changed.emit(get_view_state())


func zoom_out() -> void:
	set_zoom(maxf(get_zoom_min(), get_zoom() - get_zoom_step()))
	view_state_changed.emit(get_view_state())


func zoom_reset() -> void:
	set_zoom(1.0)
	view_state_changed.emit(get_view_state())


func toggle_grid() -> void:
	set_show_grid(not is_showing_grid())
	view_state_changed.emit(get_view_state())


func toggle_snapping() -> void:
	set_snapping_enabled(not is_snapping_enabled())
	view_state_changed.emit(get_view_state())


func toggle_minimap() -> void:
	set_minimap_enabled(not is_minimap_enabled())
	view_state_changed.emit(get_view_state())


func graph_position_from_viewport(viewport_position: Vector2) -> Vector2:
	var zoom := maxf(get_zoom(), 0.001)
	return (viewport_position + get_scroll_offset()) / zoom


func viewport_position_from_graph(graph_position: Vector2) -> Vector2:
	return graph_position * get_zoom() - get_scroll_offset()


func set_validation_findings(findings: Array) -> void:
	_validation_by_node.clear()
	_validation_by_edge.clear()
	for finding in findings:
		if not finding is Dictionary:
			continue
		var element_kind := String(finding.get("element_kind", finding.get("kind", ""))).to_lower()
		var element_identifier := String(finding.get("element_identifier", finding.get("identifier", "")))
		if element_kind in ["node", "nodes"] and not element_identifier.is_empty():
			_validation_by_node[element_identifier] = finding.duplicate(true)
		elif element_kind in ["edge", "connection", "edges"] and not element_identifier.is_empty():
			_validation_by_edge[element_identifier] = finding.duplicate(true)
	_refresh_projection()


func set_edge_activity(edge_identifier: String, amount: float, state: String = "pending") -> void:
	_edge_activity[edge_identifier] = {"amount": clampf(amount, 0.0, 1.0), "state": state}
	var edge := _edge_by_identifier(edge_identifier)
	if edge.is_empty():
		return
	var from_view = _node_views.get(String(edge.get("from_node_identifier", "")), null)
	var to_view = _node_views.get(String(edge.get("to_node_identifier", "")), null)
	if from_view == null or to_view == null:
		return
	var from_index: int = from_view.get_port_index("OUT", String(edge.get("from_port_identifier", "")))
	var to_index: int = to_view.get_port_index("IN", String(edge.get("to_port_identifier", "")))
	# The first lookup above intentionally tolerates adapters that return a
	# slot index; the normal view returns the ordinal directly.
	if from_index < 0 or to_index < 0:
		return
	set_connection_activity(StringName(from_view.name), from_index, StringName(to_view.name), to_index, float(amount))


func clear_edge_activity(edge_identifier: String) -> void:
	_edge_activity.erase(edge_identifier)
	var edge := _edge_by_identifier(edge_identifier)
	if edge.is_empty():
		return
	var from_view = _node_views.get(String(edge.get("from_node_identifier", "")), null)
	var to_view = _node_views.get(String(edge.get("to_node_identifier", "")), null)
	if from_view == null or to_view == null:
		return
	var from_index: int = from_view.get_port_index("OUT", String(edge.get("from_port_identifier", "")))
	var to_index: int = to_view.get_port_index("IN", String(edge.get("to_port_identifier", "")))
	if from_index >= 0 and to_index >= 0:
		set_connection_activity(StringName(from_view.name), from_index, StringName(to_view.name), to_index, 0.0)


func set_breadcrumb(items: Array) -> void:
	_breadcrumbs = items.duplicate(true)
	if _breadcrumb_bar == null:
		return
	for child in _breadcrumb_bar.get_children():
		_breadcrumb_bar.remove_child(child)
		child.free()
	for index in _breadcrumbs.size():
		if index > 0:
			var separator := Label.new()
			separator.text = "/"
			separator.tooltip_text = "Breadcrumb separator"
			separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_breadcrumb_bar.add_child(separator)
		var raw_item = _breadcrumbs[index]
		var item: Dictionary = raw_item.duplicate(true) if raw_item is Dictionary else {"label": String(raw_item), "path": String(raw_item)}
		var label := String(item.get("label", item.get("title", item.get("identifier", "Catalog"))))
		var path := String(item.get("path", item.get("full_path", label)))
		var breadcrumb := BreadcrumbItem.new()
		breadcrumb.name = "Breadcrumb_%d" % index
		breadcrumb.call("setup", label, path, ComponentState.ACTIVE if index == _breadcrumbs.size() - 1 else ComponentState.DEFAULT)
		breadcrumb.connect("breadcrumb_activated", _on_breadcrumb_activated.bind(index))
		_breadcrumb_bar.add_child(breadcrumb)
	_update_overlay_layout()
	breadcrumb_changed.emit(_breadcrumbs.duplicate(true))


func get_breadcrumb() -> Array:
	return _breadcrumbs.duplicate(true)


func navigate_into_subgraph(subgraph_identifier: String, node_identifier: String = "") -> void:
	subgraph_navigation_requested.emit(graph_identifier, node_identifier, subgraph_identifier)


func open_subgraph(subgraph_identifier: String, node_identifier: String = "") -> void:
	navigate_into_subgraph(subgraph_identifier, node_identifier)


func open_quick_add(graph_position: Vector2 = Vector2.ZERO, source_port: Dictionary = {}, target_port: Dictionary = {}, query: String = "") -> void:
	if _quick_add_popup == null or _is_read_only():
		return
	_pending_connection = {
		"graph_position": graph_position,
		"source_port": source_port.duplicate(true),
		"target_port": target_port.duplicate(true),
	}
	if _quick_add_search != null:
		_quick_add_search.text = query
	_rebuild_quick_add_tree()
	quick_add_menu_opened.emit(_pending_connection.duplicate(true))
	var viewport_position := viewport_position_from_graph(graph_position)
	var popup_position := global_position + viewport_position + Vector2(12, 12)
	var popup_rect := Rect2(popup_position, Vector2(360, 340))
	_quick_add_popup.popup(popup_rect)
	if _quick_add_search != null:
		_quick_add_search.grab_focus()


func show_quick_add(graph_position: Vector2 = Vector2.ZERO, source_port: Dictionary = {}, target_port: Dictionary = {}, query: String = "") -> void:
	open_quick_add(graph_position, source_port, target_port, query)


func quick_add_items(query: String = "") -> Array:
	var source := _pending_connection.get("source_port", {}) if _pending_connection.get("source_port", {}) is Dictionary else {}
	var target := _pending_connection.get("target_port", {}) if _pending_connection.get("target_port", {}) is Dictionary else {}
	return Logic.quick_add_items(query, _port_descriptor(source), _port_descriptor(target))


func build_quick_add_model(query: String = "") -> Dictionary:
	var source := _pending_connection.get("source_port", {}) if _pending_connection.get("source_port", {}) is Dictionary else {}
	var target := _pending_connection.get("target_port", {}) if _pending_connection.get("target_port", {}) is Dictionary else {}
	return Logic.quick_add_model(query, _port_descriptor(source), _port_descriptor(target))


func request_quick_add(family_identifier: String, graph_position: Vector2, context: Dictionary = {}) -> Dictionary:
	var source := context.get("source_port", {}) if context.get("source_port", {}) is Dictionary else {}
	var target := context.get("target_port", {}) if context.get("target_port", {}) is Dictionary else {}
	if not source.is_empty() and not source.has("node_identifier") and context.has("source_node_identifier"):
		source = source.duplicate(true)
		source["node_identifier"] = String(context.get("source_node_identifier", ""))
	if not target.is_empty() and not target.has("node_identifier") and context.has("target_node_identifier"):
		target = target.duplicate(true)
		target["node_identifier"] = String(context.get("target_node_identifier", ""))
	var built := _build_quick_add_command(family_identifier, graph_position, source, target)
	if not bool(built.get("ok", false)):
		var error: Dictionary = built.get("error", {"code": "LTS-GRAPH-QUICK-ADD", "message": "Quick add was rejected"})
		mutation_rejected.emit(error)
		return {"ok": false, "error": error}
	var result := _dispatch_command(built["command"], "quick_add")
	if bool(result.get("ok", false)):
		quick_add_node_requested.emit(built["node"].duplicate(true), built.get("edge", {}).duplicate(true), context.duplicate(true))
	return result


func add_node_intent(family_identifier: String, graph_position: Vector2, context: Dictionary = {}) -> Dictionary:
	return request_quick_add(family_identifier, graph_position, context)


func request_delete_selected() -> Dictionary:
	return _request_delete_nodes(get_selected_node_identifiers())


func request_auto_arrange(options: Dictionary = {}) -> Dictionary:
	if graph_identifier.is_empty() or _graph_document.is_empty():
		return _reject_simple("LTS-GRAPH-ARRANGE-001", "Auto-arrange requires an open task graph.", "graph")
	var resolved_options := {"horizontal_gap": 380.0, "vertical_gap": 190.0}
	resolved_options.merge(options, true)
	var positions := Logic.auto_arrange(_graph_document, resolved_options)
	var command = DocumentCommand.auto_arrange(graph_identifier, positions)
	return _dispatch_command(command, "auto_arrange")


func auto_arrange(options: Dictionary = {}) -> Dictionary:
	return request_auto_arrange(options)


func arrange(options: Dictionary = {}) -> Dictionary:
	return request_auto_arrange(options)


func create_frame(frame_identifier: String, title_text: String, rect: Rect2) -> Dictionary:
	if frame_identifier.strip_edges().is_empty() or graph_identifier.is_empty():
		return _reject_simple("LTS-GRAPH-FRAME-001", "A frame identifier and open graph are required.", "frame")
	var value := {"title": title_text, "rect": _rect_to_array(rect)}
	var command = DocumentCommand.set_layout("task_graph", graph_identifier, "frame", frame_identifier, value)
	var result := _dispatch_command(command, "create_frame")
	frame_command_requested.emit(frame_identifier, command.to_dict())
	return result


func add_frame(frame_identifier: String, title_text: String, rect: Rect2) -> Dictionary:
	return create_frame(frame_identifier, title_text, rect)


func get_selected_fragment() -> Dictionary:
	var selected := get_selected_node_identifiers()
	var nodes: Array = []
	for node in _graph_document.get("nodes", []):
		if node is Dictionary and selected.has(String(node.get("identifier", ""))):
			nodes.append(node.duplicate(true))
	var edges: Array = []
	for edge in _graph_document.get("edges", []):
		if not edge is Dictionary:
			continue
		if selected.has(String(edge.get("from_node_identifier", ""))) and selected.has(String(edge.get("to_node_identifier", ""))):
			edges.append(edge.duplicate(true))
	var layout_nodes: Dictionary = {}
	var stored_nodes: Dictionary = _graph_layout.get("nodes", {}) if _graph_layout.get("nodes", {}) is Dictionary else {}
	for identifier in selected:
		if stored_nodes.has(identifier):
			layout_nodes[identifier] = stored_nodes[identifier].duplicate(true) if stored_nodes[identifier] is Dictionary else stored_nodes[identifier]
	return {"nodes": nodes, "edges": edges, "layout": {"nodes": layout_nodes}}


func copy_selected_nodes() -> Dictionary:
	_clipboard_fragment = get_selected_fragment()
	clipboard_changed.emit(_clipboard_fragment.duplicate(true))
	return _clipboard_fragment.duplicate(true)


func paste_fragment(fragment: Dictionary, graph_position: Vector2 = Vector2.ZERO) -> Dictionary:
	if graph_identifier.is_empty() or fragment.is_empty():
		return _reject_simple("LTS-GRAPH-CLIPBOARD-001", "Paste requires an open graph and a non-empty fragment.", "clipboard")
	var command = DocumentCommand.paste_graph_fragment(graph_identifier, fragment, graph_position)
	return _dispatch_command(command, "paste_fragment")


func paste_clipboard(graph_position: Vector2 = Vector2.ZERO) -> Dictionary:
	return paste_fragment(_clipboard_fragment, graph_position)


func duplicate_selected_nodes(position_offset := Vector2(48, 48)) -> Dictionary:
	var fragment := get_selected_fragment()
	if fragment.get("nodes", []).is_empty():
		return _reject_simple("LTS-GRAPH-CLIPBOARD-002", "Select at least one node to duplicate.", "selection")
	var command = DocumentCommand.duplicate_nodes(graph_identifier, fragment, position_offset)
	return _dispatch_command(command, "duplicate_nodes")


func execute_document_command(command: Variant) -> Dictionary:
	return _dispatch_command(command, "external")


func apply_external_command_result(_result: Dictionary) -> void:
	_refresh_projection()


func _configure_native_graph() -> void:
	set_show_menu(true)
	set_show_zoom_label(true)
	set_show_zoom_buttons(true)
	set_show_grid_buttons(true)
	set_show_minimap_button(true)
	# GraphEdit's arrange button calls its own non-document layout.  It is
	# hidden so the command button below can emit deterministic positions.
	set_show_arrange_button(false)
	set_show_grid(true)
	set_snapping_enabled(true)
	set_snapping_distance(maxi(1, default_snapping_distance))
	set_minimap_enabled(true)
	set_minimap_size(default_minimap_size)
	set_minimap_opacity(0.72)
	set("right_disconnects", true)
	set_type_names(Logic.VALUE_TYPE_NAMES)
	# GraphEdit uses these types for native drag affordance.  Local validation
	# still checks the same pair and adds cycle/duplicate/cardinality reasons.
	for source_type in range(Logic.VALUE_BYTES + 1):
		for target_type in range(Logic.VALUE_BYTES + 1):
			if source_type == target_type or source_type == Logic.VALUE_NONE or target_type == Logic.VALUE_NONE:
				add_valid_connection_type(source_type, target_type)


func _build_command_overlay() -> void:
	_command_overlay = PanelContainer.new()
	_command_overlay.name = "GraphCommandOverlay"
	_command_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_command_overlay.position = Vector2(8, 8)
	_command_overlay.z_index = 100
	_command_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_command_overlay.theme_type_variation = &"LevelTaskDrawer"
	add_child(_command_overlay)
	_command_row = HBoxContainer.new()
	_command_row.name = "CommandRow"
	_command_row.add_theme_constant_override(&"separation", ComponentTheme.theme_separation(self, &"HBoxContainer"))
	_command_overlay.add_child(_command_row)
	_quick_add_button = CommandButton.new()
	_quick_add_button.name = "QuickAdd"
	_quick_add_button.call("setup", "Quick add", [&"Add", &"CreateNew"], "Add a compatible task node")
	_quick_add_button.connect("command_requested", _on_quick_add_button)
	_command_row.add_child(_quick_add_button)
	_arrange_button = CommandButton.new()
	_arrange_button.name = "AutoArrange"
	_arrange_button.call("setup", "Auto-arrange", [&"layout", &"Arrange"], "Deterministically arrange the open task graph")
	_arrange_button.connect("command_requested", _on_arrange_button)
	_command_row.add_child(_arrange_button)
	_breakpoint_button = CommandButton.new()
	_breakpoint_button.name = "ToggleBreakpoint"
	_breakpoint_button.call("setup", "Breakpoint", [&"DebugSkipBreakpointsOff", &"Breakpoint"], "Toggle an editor-only breakpoint on the selected node")
	_breakpoint_button.connect("command_requested", _on_breakpoint_button)
	_command_row.add_child(_breakpoint_button)
	_feedback_label = Label.new()
	_feedback_label.name = "ConnectionFeedback"
	_feedback_label.text = "Ready — named ports and typed connections"
	_feedback_label.tooltip_text = _feedback_label.text
	_feedback_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_command_row.add_child(_feedback_label)
	_breadcrumb_bar = HBoxContainer.new()
	_breadcrumb_bar.name = "Breadcrumbs"
	_breadcrumb_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_breadcrumb_bar.visible = false
	_command_row.add_child(_breadcrumb_bar)

	var center := CenterContainer.new()
	center.name = "EmptyStateCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.z_index = 80
	add_child(center)
	_empty_overlay = EmptyState.new()
	_empty_overlay.name = "EmptyGraphState"
	_empty_overlay.custom_minimum_size = Vector2(280, 150)
	_empty_overlay.call("setup", "No task nodes", "Add a node to begin authoring this graph.", "Quick add node", ComponentState.EMPTY)
	_empty_overlay.connect("action_requested", _on_empty_state_action)
	_empty_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_empty_overlay)

	var degraded_center := CenterContainer.new()
	degraded_center.name = "DegradedStateCenter"
	degraded_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	degraded_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	degraded_center.z_index = 90
	add_child(degraded_center)
	_degraded_overlay = DegradedState.new()
	_degraded_overlay.name = "NativeExtensionDiagnostic"
	_degraded_overlay.custom_minimum_size = Vector2(360, 190)
	_degraded_overlay.call("setup", "Native extension unavailable", "Build and load the Level Task System GDExtension before editing definitions.", "code: LTS-NATIVE-001", ComponentState.ERROR)
	_degraded_overlay.connect("refresh_requested", _on_degraded_refresh_requested)
	_degraded_overlay.visible = false
	degraded_center.add_child(_degraded_overlay)


func _build_quick_add_popup() -> void:
	_quick_add_popup = PopupPanel.new()
	_quick_add_popup.name = "QuickAddPopup"
	if Engine.is_editor_hint():
		_quick_add_popup.theme = EditorInterface.get_editor_theme()
	var column := VBoxContainer.new()
	column.name = "QuickAddColumn"
	column.custom_minimum_size = Vector2(340, 0)
	_quick_add_popup.add_child(column)
	_quick_add_title = Label.new()
	_quick_add_title.name = "QuickAddTitle"
	_quick_add_title.text = "Add task node"
	_quick_add_title.tooltip_text = _quick_add_title.text
	column.add_child(_quick_add_title)
	_quick_add_search = LineEdit.new()
	_quick_add_search.name = "QuickAddSearch"
	_quick_add_search.placeholder_text = "Search node families"
	_quick_add_search.tooltip_text = "Filter categorized task node families"
	_quick_add_search.focus_mode = Control.FOCUS_ALL
	_quick_add_search.text_changed.connect(_on_quick_add_query_changed)
	column.add_child(_quick_add_search)
	_quick_add_tree = Tree.new()
	_quick_add_tree.name = "QuickAddTree"
	_quick_add_tree.hide_root = true
	_quick_add_tree.columns = 1
	_quick_add_tree.custom_minimum_size = Vector2(340, 240)
	_quick_add_tree.focus_mode = Control.FOCUS_ALL
	_quick_add_tree.item_activated.connect(_on_quick_add_item_activated)
	column.add_child(_quick_add_tree)
	add_child(_quick_add_popup)
	_quick_add_popup.hide()


func _connect_graph_signals() -> void:
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	connection_to_empty.connect(_on_connection_to_empty)
	connection_from_empty.connect(_on_connection_from_empty)
	connection_drag_started.connect(_on_connection_drag_started)
	connection_drag_ended.connect(_on_connection_drag_ended)
	copy_nodes_request.connect(_on_copy_nodes_request)
	cut_nodes_request.connect(_on_cut_nodes_request)
	paste_nodes_request.connect(_on_paste_nodes_request)
	duplicate_nodes_request.connect(_on_duplicate_nodes_request)
	delete_nodes_request.connect(_on_delete_nodes_request)
	node_selected.connect(_on_node_selected)
	node_deselected.connect(_on_node_deselected)
	popup_request.connect(_on_popup_request)
	begin_node_move.connect(_on_begin_node_move)
	end_node_move.connect(_on_end_node_move)
	frame_rect_changed.connect(_on_frame_rect_changed)
	graph_elements_linked_to_frame_request.connect(_on_graph_elements_linked_to_frame_request)
	scroll_offset_changed.connect(_on_scroll_offset_changed)


func _refresh_projection() -> void:
	if _document_model != null and not graph_identifier.is_empty():
		if _document_model.has_method("get_document"):
			_graph_document = _document_model.call("get_document", "task_graph", graph_identifier)
		if _document_model.has_method("get_layout"):
			_graph_layout = _document_model.call("get_layout", "task_graph", graph_identifier)
	# Loading the projection is useful before the Control enters a tree (for
	# headless command tests and workspace setup). Only the native view build
	# waits for _ready().
	if not _built:
		return
	_refresh_in_progress = true
	_suppress_projection_events = true
	if _graph_document is Dictionary:
		_graph_document = _graph_document.duplicate(true)
	else:
		_graph_document = {}
	if _graph_layout is Dictionary:
		_graph_layout = _graph_layout.duplicate(true)
	else:
		_graph_layout = {}
	_clear_owned_elements()
	_node_views.clear()
	_frame_views.clear()
	_last_positions.clear()
	if not _graph_document.is_empty():
		_build_frames()
		_build_nodes()
		_build_connections()
		_apply_frame_memberships()
		_apply_model_selection()
	_suppress_projection_events = false
	_refresh_in_progress = false
	_update_native_state()
	_update_empty_state()
	_update_feedback_ready()
	apply_debug_projection(_debug_projection)
	graph_projection_changed.emit(graph_identifier)


func _clear_owned_elements() -> void:
	for element in _owned_elements:
		if element == null or not is_instance_valid(element):
			continue
		if element.get_parent() == self:
			remove_child(element)
		element.free()
	_owned_elements.clear()


func _build_frames() -> void:
	var frames: Dictionary = _graph_layout.get("frames", {}) if _graph_layout.get("frames", {}) is Dictionary else {}
	var frame_ids := frames.keys()
	frame_ids.sort()
	for raw_identifier in frame_ids:
		var identifier := String(raw_identifier)
		var definition = frames[raw_identifier]
		if not definition is Dictionary:
			definition = {}
		var frame := GraphFrame.new()
		frame.name = _safe_element_name("frame", identifier)
		frame.set_meta("lts_frame_identifier", identifier)
		frame.title = String(definition.get("title", identifier))
		frame.autoshrink_enabled = false
		frame.draggable = true
		frame.selectable = true
		var rect := _rect_from_variant(definition.get("rect", definition.get("position", [])), definition)
		frame.position_offset = rect.position
		frame.size = rect.size
		add_child(frame)
		_owned_elements.append(frame)
		_frame_views[identifier] = frame


func _build_nodes() -> void:
	var nodes: Array = _graph_document.get("nodes", []) if _graph_document.get("nodes", []) is Array else []
	var layout_nodes: Dictionary = _graph_layout.get("nodes", {}) if _graph_layout.get("nodes", {}) is Dictionary else {}
	# A resource can be semantically complete before any editor layout has been
	# saved. Use the deterministic arranger as a projection-only fallback so a
	# first open is readable without silently dirtying the document.
	var fallback_positions := Logic.auto_arrange(_graph_document, {"horizontal_gap": 380.0, "vertical_gap": 190.0})
	for raw_node in nodes:
		if not raw_node is Dictionary:
			continue
		var identifier := String(raw_node.get("identifier", ""))
		if identifier.is_empty():
			continue
		var finding: Dictionary = _validation_by_node.get(identifier, {})
		var state := ComponentState.ERROR if not finding.is_empty() else ComponentState.DEFAULT
		var detail := String(finding.get("message", finding.get("detail", "")))
		var view := NodeView.new()
		view.name = _safe_element_name("node", identifier)
		view.set_meta("lts_node_identifier", identifier)
		view.call("setup", raw_node, state, detail)
		var layout_value = layout_nodes.get(identifier, {})
		var raw_position: Variant = fallback_positions.get(identifier, Vector2.ZERO)
		if layout_value is Dictionary and layout_value.has("position"):
			raw_position = layout_value.get("position")
		elif not layout_value is Dictionary and layout_nodes.has(identifier):
			raw_position = layout_value
		var position := _vector2_from_variant(raw_position)
		view.position_offset = position
		view.connect("subgraph_open_requested", _on_subgraph_open_requested)
		view.connect("port_activated", _on_node_port_activated)
		view.set_block_signals(false)
		add_child(view)
		_owned_elements.append(view)
		_node_views[identifier] = view
		_last_positions[identifier] = position


func _update_overlay_layout() -> void:
	if _command_overlay == null:
		return
	# The workspace already exposes a resource breadcrumb. The graph-local trail
	# becomes useful only when the canvas has enough room for nested subgraphs.
	if _breadcrumb_bar != null:
		_breadcrumb_bar.visible = not _breadcrumbs.is_empty() and size.x >= 1100.0
	if _feedback_label != null:
		_feedback_label.visible = size.x >= 560.0
	if _arrange_button != null:
		_arrange_button.visible = size.x >= 420.0
	if _breakpoint_button != null:
		_breakpoint_button.visible = size.x >= 720.0


func _build_connections() -> void:
	clear_connections()
	var edges: Array = _graph_document.get("edges", []) if _graph_document.get("edges", []) is Array else []
	for raw_edge in edges:
		if not raw_edge is Dictionary:
			continue
		var edge: Dictionary = raw_edge
		var from_identifier := String(edge.get("from_node_identifier", ""))
		var to_identifier := String(edge.get("to_node_identifier", ""))
		var from_view = _node_views.get(from_identifier, null)
		var to_view = _node_views.get(to_identifier, null)
		if from_view == null or to_view == null:
			continue
		var from_port: int = from_view.get_port_index("OUT", String(edge.get("from_port_identifier", "")))
		var to_port: int = to_view.get_port_index("IN", String(edge.get("to_port_identifier", "")))
		if from_port < 0 or to_port < 0:
			continue
		# Existing malformed authored edges remain in the document projection;
		# GraphEdit is asked to render only resolvable endpoints.  Full native
		# catalog validation is not claimed by this canvas.
		connect_node(StringName(from_view.name), from_port, StringName(to_view.name), to_port, true)
		var activity: Dictionary = _edge_activity.get(String(edge.get("identifier", "")), {})
		if not activity.is_empty():
			set_connection_activity(StringName(from_view.name), from_port, StringName(to_view.name), to_port, float(activity.get("amount", 0.0)))
		if _validation_by_edge.has(String(edge.get("identifier", ""))):
			var finding: Dictionary = _validation_by_edge[String(edge.get("identifier", ""))]
			_set_feedback({
				"ok": false,
				"compatible": false,
				"code": String(finding.get("code", "LTS-GRAPH-EDGE-001")),
				"reason": String(finding.get("message", finding.get("detail", "Connection requires attention."))),
				"edge_identifier": String(edge.get("identifier", "")),
				"validation_scope": "document_projection",
			})


func _apply_frame_memberships() -> void:
	var layout_nodes: Dictionary = _graph_layout.get("nodes", {}) if _graph_layout.get("nodes", {}) is Dictionary else {}
	for identifier in layout_nodes:
		var layout_value = layout_nodes[identifier]
		if not layout_value is Dictionary:
			continue
		var frame_identifier := String(layout_value.get("frame_identifier", ""))
		var view = _node_views.get(String(identifier), null)
		var frame = _frame_views.get(frame_identifier, null)
		if view != null and frame != null:
			attach_graph_element_to_frame(StringName(view.name), StringName(frame.name))


func _apply_model_selection() -> void:
	if _document_model == null or not _document_model.has_method("get_selection"):
		return
	var selection: Dictionary = _document_model.call("get_selection")
	var selected_identifier := String(selection.get("element_identifier", ""))
	if not selected_identifier.is_empty() and _node_views.has(selected_identifier):
		var view = _node_views[selected_identifier]
		if view != null:
			view.set_selected(true)


func _update_native_state() -> void:
	var degraded := _is_degraded()
	var read_only := _is_read_only()
	if _quick_add_button != null:
		_quick_add_button.disabled = read_only or degraded
	if _arrange_button != null:
		_arrange_button.disabled = read_only or degraded
	if _degraded_overlay != null:
		_degraded_overlay.visible = degraded
	if read_only or degraded:
		set_process_unhandled_key_input(false)
	else:
		set_process_unhandled_key_input(true)
	for identifier in _node_views:
		var view = _node_views[identifier]
		if view != null:
			view.draggable = not (read_only or degraded)
			view.selectable = true
	if _feedback_label != null and (read_only or degraded):
		_feedback_label.text = "Read-only — native extension unavailable (LTS-NATIVE-001)"
		_feedback_label.tooltip_text = _feedback_label.text
		ComponentTheme.apply_state_text(_feedback_label, ComponentState.ERROR, _feedback_label.text)


func _update_empty_state() -> void:
	if _empty_overlay == null:
		return
	var is_empty: bool = _graph_document.is_empty() or not (_graph_document.get("nodes", []) is Array) or _graph_document.get("nodes", []).is_empty()
	_empty_overlay.visible = is_empty and not _is_degraded()
	if _degraded_overlay != null:
		_degraded_overlay.visible = _is_degraded()


func _update_feedback_ready() -> void:
	if _feedback_label == null or _is_read_only() or _is_degraded():
		return
	var node_count: int = (_graph_document.get("nodes", []).size() if _graph_document.get("nodes", []) is Array else 0)
	var edge_count: int = (_graph_document.get("edges", []).size() if _graph_document.get("edges", []) is Array else 0)
	_feedback_label.text = "Ready — %d nodes, %d named connections" % [node_count, edge_count]
	_feedback_label.tooltip_text = _feedback_label.text
	ComponentTheme.apply_state_text(_feedback_label, ComponentState.DEFAULT, _feedback_label.text)


func _on_quick_add_button() -> void:
	open_quick_add(graph_position_from_viewport(size * 0.5))


func _on_arrange_button() -> void:
	request_auto_arrange()


func _on_breakpoint_button() -> void:
	var result := toggle_selected_breakpoint()
	if not bool(result.get("ok", false)):
		var error: Dictionary = result.get("error", {})
		_set_feedback({"ok": false, "compatible": false, "code": error.get("code", "LTS-DEBUG-000"), "reason": error.get("message", "Breakpoint unavailable"), "path": error.get("path", "graph.debug")})


func _on_debug_projection_changed(projection: Dictionary) -> void:
	apply_debug_projection(projection)


func _component_state_for_debug(activity: Dictionary) -> StringName:
	if bool(activity.get("breakpoint_hit", false)):
		return ComponentState.FOCUS
	match String(activity.get("state", "inactive")):
		"failed", "error":
			return ComponentState.ERROR
		"pending":
			return ComponentState.LOADING
		"active", "completed", "traversed":
			return ComponentState.ACTIVE
	return ComponentState.DEFAULT


func _update_breakpoint_button() -> void:
	if _breakpoint_button == null:
		return
	var selected := get_selected_node_identifiers()
	var armed := false
	if not selected.is_empty() and _debug_model != null and _debug_model.has_method("has_breakpoint"):
		armed = bool(_debug_model.call("has_breakpoint", String(selected[0]), "node"))
	_breakpoint_button.call("set_state", ComponentState.ACTIVE if armed else ComponentState.DEFAULT)


func _on_empty_state_action() -> void:
	open_quick_add(graph_position_from_viewport(size * 0.5))


func _on_degraded_refresh_requested() -> void:
	_refresh_projection()


func _on_popup_request(at_position: Vector2) -> void:
	open_quick_add(graph_position_from_viewport(at_position))


func _on_quick_add_query_changed(_query: String) -> void:
	_rebuild_quick_add_tree()


func _rebuild_quick_add_tree() -> void:
	if _quick_add_tree == null:
		return
	_quick_add_tree.clear()
	var query := _quick_add_search.text if _quick_add_search != null else ""
	var model := build_quick_add_model(query)
	if _quick_add_title != null:
		var source: Dictionary = _pending_connection.get("source_port", {})
		var target: Dictionary = _pending_connection.get("target_port", {})
		if not source.is_empty():
			var source_descriptor: Dictionary = source.get("port", source)
			_quick_add_title.text = "Add node after OUT %s" % String(source_descriptor.get("name", source_descriptor.get("identifier", "port")))
		elif not target.is_empty():
			var target_descriptor: Dictionary = target.get("port", target)
			_quick_add_title.text = "Add node before IN %s" % String(target_descriptor.get("name", target_descriptor.get("identifier", "port")))
		else:
			_quick_add_title.text = "Add task node"
		_quick_add_title.tooltip_text = _quick_add_title.text
	var root := _quick_add_tree.create_item()
	var categories: Array = model.get("categories", [])
	for category in categories:
		if not category is Dictionary:
			continue
		var category_item := _quick_add_tree.create_item(root)
		category_item.set_text(0, String(category.get("label", "Other")))
		category_item.set_selectable(0, false)
		category_item.set_collapsed(false)
		for family in category.get("items", []):
			if not family is Dictionary:
				continue
			var item := _quick_add_tree.create_item(category_item)
			var label := String(family.get("label", family.get("identifier", "Task node")))
			var summary := String(family.get("summary", ""))
			item.set_text(0, "%s — %s" % [label, summary])
			item.set_tooltip_text(0, "%s\n%s" % [label, summary])
			item.set_metadata(0, String(family.get("identifier", "")))
			var icon := ComponentTheme.resolve_icon(self, family.get("icons", [&"Node"]), &"Node")
			if icon != null:
				item.set_icon(0, icon)
	if categories.is_empty():
		var empty_item := _quick_add_tree.create_item(root)
		empty_item.set_text(0, "No compatible node families")
		empty_item.set_selectable(0, false)


func _on_quick_add_item_activated(item: TreeItem, _column: int) -> void:
	if item == null:
		return
	var family_identifier := String(item.get_metadata(0))
	if family_identifier.is_empty() or _pending_connection.is_empty():
		return
	var graph_position := _vector2_from_variant(_pending_connection.get("graph_position", Vector2.ZERO))
	var context := {
		"source_port": _pending_connection.get("source_port", {}).duplicate(true),
		"target_port": _pending_connection.get("target_port", {}).duplicate(true),
	}
	var result := request_quick_add(family_identifier, graph_position, context)
	if bool(result.get("ok", false)):
		_pending_connection.clear()
		_quick_add_popup.hide()


func _build_quick_add_command(family_identifier: String, graph_position: Vector2, source_port: Dictionary, target_port: Dictionary) -> Dictionary:
	if _is_read_only() or _is_degraded():
		return {"ok": false, "error": {"code": "LTS-NATIVE-001", "message": "Native extension unavailable; graph is read-only.", "path": "native.level_task_system"}}
	if graph_identifier.is_empty() or _graph_document.is_empty():
		return {"ok": false, "error": {"code": "LTS-GRAPH-QUICK-ADD-001", "message": "Quick add requires an open task graph.", "path": "graph"}}
	var family := Logic.family_for_kind(family_identifier)
	if family.is_empty():
		return {"ok": false, "error": {"code": "LTS-GRAPH-QUICK-ADD-002", "message": "Unknown task node family '%s'." % family_identifier, "path": "graph.quick_add"}}
	var existing_ids: Array = []
	var existing_edge_ids: Array = []
	for node in _graph_document.get("nodes", []):
		if node is Dictionary:
			existing_ids.append(String(node.get("identifier", "")))
	for edge in _graph_document.get("edges", []):
		if edge is Dictionary:
			existing_edge_ids.append(String(edge.get("identifier", "")))
	var identifier := Logic.unique_identifier(String(family.get("identifier", "node")), existing_ids)
	var node := Logic.make_node_payload(family_identifier, identifier)
	var commands: Array = [DocumentCommand.add_task_node(graph_identifier, node)]
	var graph_after_add := _graph_document.duplicate(true)
	var nodes_after_add: Array = graph_after_add.get("nodes", []).duplicate(true)
	nodes_after_add.append(node.duplicate(true))
	graph_after_add["nodes"] = nodes_after_add
	var edge: Dictionary = {}
	if not source_port.is_empty():
		var source_descriptor: Dictionary = source_port.get("port", source_port)
		var input_port := _first_compatible_port(family, source_descriptor, true)
		if input_port.is_empty():
			return {"ok": false, "error": {"code": Logic.CONNECTION_TYPE, "message": "No compatible input on '%s'." % String(family.get("label", family_identifier)), "path": "graph.quick_add.%s" % family_identifier}}
		edge = _make_edge_for_endpoints(source_port, {"node_identifier": identifier, "port": input_port}, existing_edge_ids)
	elif not target_port.is_empty():
		var target_descriptor: Dictionary = target_port.get("port", target_port)
		var output_port := _first_compatible_port(family, target_descriptor, false)
		if output_port.is_empty():
			return {"ok": false, "error": {"code": Logic.CONNECTION_TYPE, "message": "No compatible output on '%s'." % String(family.get("label", family_identifier)), "path": "graph.quick_add.%s" % family_identifier}}
		edge = _make_edge_for_endpoints({"node_identifier": identifier, "port": output_port}, target_port, existing_edge_ids)
	if not edge.is_empty():
		var from_id := String(edge.get("from_node_identifier", ""))
		var from_port_id := String(edge.get("from_port_identifier", ""))
		var to_id := String(edge.get("to_node_identifier", ""))
		var to_port_id := String(edge.get("to_port_identifier", ""))
		var feedback := Logic.validate_connection(graph_after_add, from_id, from_port_id, to_id, to_port_id)
		if not bool(feedback.get("compatible", false)):
			return {"ok": false, "error": feedback}
		commands.append(DocumentCommand.add_task_edge(graph_identifier, edge))
	commands.append(DocumentCommand.set_node_position(graph_identifier, identifier, graph_position))
	return {"ok": true, "command": DocumentCommand.batch(commands), "node": node, "edge": edge}


func _first_compatible_port(family: Dictionary, context_port: Dictionary, want_input: bool) -> Dictionary:
	for raw_port in family.get("ports", []):
		if not raw_port is Dictionary:
			continue
		var candidate := Logic.normalize_port(raw_port)
		var feedback := Logic.port_compatibility(context_port, candidate) if want_input else Logic.port_compatibility(candidate, context_port)
		if bool(feedback.get("compatible", false)):
			return candidate
	return {}


func _make_edge_for_endpoints(source: Dictionary, target: Dictionary, existing_edge_ids: Array) -> Dictionary:
	var source_port: Dictionary = source.get("port", source)
	var target_port: Dictionary = target.get("port", target)
	var from_id := String(source.get("node_identifier", ""))
	var from_port_id := String(source_port.get("identifier", source_port.get("name", "")))
	var to_id := String(target.get("node_identifier", ""))
	var to_port_id := String(target_port.get("identifier", target_port.get("name", "")))
	var edge_id := Logic.make_edge_identifier(from_id, from_port_id, to_id, to_port_id, existing_edge_ids)
	return {
		"identifier": edge_id,
		"schema_version": 1,
		"from_node_identifier": from_id,
		"from_port_identifier": from_port_id,
		"to_node_identifier": to_id,
		"to_port_identifier": to_port_id,
	}


func _on_connection_drag_started(from_node: StringName, from_port: int, is_output: bool) -> void:
	var endpoint := _resolve_endpoint(from_node, from_port, is_output)
	if endpoint.is_empty():
		return
	var port: Dictionary = endpoint.get("port", {})
	var compatible_targets := Logic.compatible_ports_for(port, _graph_document, is_output)
	_set_feedback({
		"ok": true,
		"compatible": true,
		"state": "dragging",
		"source": endpoint,
		"compatible_targets": compatible_targets,
		"reason": "Release on a compatible named port or empty canvas to insert a node.",
		"validation_scope": "graph_canvas_local",
	})


func _on_connection_drag_ended() -> void:
	if _pending_connection.is_empty():
		_update_feedback_ready()


func _on_connection_to_empty(from_node: StringName, from_port: int, release_position: Vector2) -> void:
	var endpoint := _resolve_endpoint(from_node, from_port, true)
	if endpoint.is_empty():
		return
	_pending_connection = {
		"graph_position": graph_position_from_viewport(release_position),
		"source_port": endpoint.duplicate(true),
		"source_node_identifier": String(endpoint.get("node_identifier", "")),
		"source_port_identifier": String(endpoint.get("port_identifier", "")),
		"target_port": {},
	}
	open_quick_add(_pending_connection["graph_position"], _pending_connection["source_port"], {})


func _on_connection_from_empty(to_node: StringName, to_port: int, release_position: Vector2) -> void:
	var endpoint := _resolve_endpoint(to_node, to_port, false)
	if endpoint.is_empty():
		return
	_pending_connection = {
		"graph_position": graph_position_from_viewport(release_position),
		"target_port": endpoint.duplicate(true),
		"target_node_identifier": String(endpoint.get("node_identifier", "")),
		"target_port_identifier": String(endpoint.get("port_identifier", "")),
		"source_port": {},
	}
	open_quick_add(_pending_connection["graph_position"], {}, _pending_connection["target_port"])


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var from_endpoint := _resolve_endpoint(from_node, from_port, true)
	var to_endpoint := _resolve_endpoint(to_node, to_port, false)
	if from_endpoint.is_empty() or to_endpoint.is_empty():
		_reject_connection({"ok": false, "compatible": false, "code": Logic.CONNECTION_PORT_MISSING, "reason": "Both connection endpoints must be named ports."})
		return
	# Godot normally reports output → input regardless of drag origin.  The
	# swap keeps keyboard/programmatic adapters tolerant of the reverse order.
	if Logic.is_input_port(from_endpoint.get("port", {})) and Logic.is_output_port(to_endpoint.get("port", {})):
		var swap := from_endpoint
		from_endpoint = to_endpoint
		to_endpoint = swap
	var from_id := String(from_endpoint.get("node_identifier", ""))
	var from_port_id := String(from_endpoint.get("port_identifier", ""))
	var to_id := String(to_endpoint.get("node_identifier", ""))
	var to_port_id := String(to_endpoint.get("port_identifier", ""))
	var feedback := Logic.validate_connection(_graph_document, from_id, from_port_id, to_id, to_port_id)
	_set_feedback(feedback)
	if not bool(feedback.get("compatible", false)):
		_reject_connection(feedback)
		return
	var existing_edge_ids: Array = []
	for edge in _graph_document.get("edges", []):
		if edge is Dictionary:
			existing_edge_ids.append(String(edge.get("identifier", "")))
	var edge := {
		"identifier": Logic.make_edge_identifier(from_id, from_port_id, to_id, to_port_id, existing_edge_ids),
		"schema_version": 1,
		"from_node_identifier": from_id,
		"from_port_identifier": from_port_id,
		"to_node_identifier": to_id,
		"to_port_identifier": to_port_id,
	}
	var result := _dispatch_command(DocumentCommand.add_task_edge(graph_identifier, edge), "connect_edge")
	if bool(result.get("ok", false)):
		_set_feedback({"ok": true, "compatible": true, "code": "", "reason": "Connection intent accepted: %s → %s." % [from_port_id, to_port_id], "edge": edge, "validation_scope": "graph_canvas_local"})


func _is_node_hover_valid(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> bool:
	var from_endpoint := _resolve_endpoint(from_node, from_port, true)
	var to_endpoint := _resolve_endpoint(to_node, to_port, false)
	if from_endpoint.is_empty() or to_endpoint.is_empty():
		return false
	if Logic.is_input_port(from_endpoint.get("port", {})) and Logic.is_output_port(to_endpoint.get("port", {})):
		var swap := from_endpoint
		from_endpoint = to_endpoint
		to_endpoint = swap
	var feedback := Logic.validate_connection(_graph_document, String(from_endpoint.get("node_identifier", "")), String(from_endpoint.get("port_identifier", "")), String(to_endpoint.get("node_identifier", "")), String(to_endpoint.get("port_identifier", "")))
	return bool(feedback.get("compatible", false))


func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var from_endpoint := _resolve_endpoint(from_node, from_port, true)
	var to_endpoint := _resolve_endpoint(to_node, to_port, false)
	if from_endpoint.is_empty() or to_endpoint.is_empty():
		return
	var edge := _find_edge(String(from_endpoint.get("node_identifier", "")), String(from_endpoint.get("port_identifier", "")), String(to_endpoint.get("node_identifier", "")), String(to_endpoint.get("port_identifier", "")))
	if edge.is_empty():
		return
	_dispatch_command(DocumentCommand.remove_task_edge(graph_identifier, String(edge.get("identifier", ""))), "disconnect_edge")


func _on_node_port_activated(_node_identifier: String, _port_identifier: String, _direction: String) -> void:
	# Port labels remain readable and keyboard focusable; GraphEdit owns the drag gesture.
	return


func _port_descriptor(endpoint: Dictionary) -> Dictionary:
	if endpoint.has("port") and endpoint.get("port") is Dictionary:
		return endpoint.get("port").duplicate(true)
	return endpoint.duplicate(true)


func _resolve_endpoint(view_name: StringName, port_index: int, prefer_output: bool) -> Dictionary:
	var view := _view_for_name(view_name)
	if view == null:
		return {}
	var direction := "OUT" if prefer_output else "IN"
	var identifier := String(view.get_port_identifier(direction, port_index))
	if identifier.is_empty():
		# A programmatic adapter may provide the opposite ordinal.  This fallback
		# never invents a port; it only resolves a named port already rendered.
		direction = "IN" if prefer_output else "OUT"
		identifier = String(view.get_port_identifier(direction, port_index))
	if identifier.is_empty():
		return {}
	return {
		"node_identifier": String(view.get_meta("lts_node_identifier", "")),
		"port_identifier": identifier,
		"port": view.get_port_definition(identifier),
		"direction": direction,
	}


func _view_for_name(view_name: StringName) -> NodeView:
	for identifier in _node_views:
		var view = _node_views[identifier]
		if view != null and StringName(view.name) == view_name:
			return view
	return null


func _on_node_selected(_node: Node) -> void:
	_schedule_selection_projection()


func _on_node_deselected(_node: Node) -> void:
	_schedule_selection_projection()


func _schedule_selection_projection() -> void:
	if _suppress_projection_events or _selection_flush_queued:
		return
	_selection_flush_queued = true
	call_deferred("_flush_selection_projection")


func _flush_selection_projection() -> void:
	_selection_flush_queued = false
	if _suppress_projection_events:
		return
	var identifiers := get_selected_node_identifiers()
	selection_changed.emit(identifiers.duplicate())
	selection_projection_changed.emit(identifiers.duplicate())
	if graph_identifier.is_empty():
		return
	var primary := String(identifiers[identifiers.size() - 1]) if not identifiers.is_empty() else ""
	var selection := {
		"resource_kind": "task_graph",
		"resource_identifier": graph_identifier,
		"element_kind": "node" if not primary.is_empty() else "",
		"element_identifier": primary,
	}
	_dispatch_command(DocumentCommand.set_selection(selection), "selection")


func _on_delete_nodes_request(nodes: PackedStringArray) -> void:
	var identifiers: Array = []
	for raw_identifier in nodes:
		var view := _view_for_name(StringName(raw_identifier))
		if view != null:
			identifiers.append(String(view.get_meta("lts_node_identifier", "")))
		elif _node_views.has(String(raw_identifier)):
			identifiers.append(String(raw_identifier))
	_request_delete_nodes(identifiers)


func _request_delete_nodes(identifiers: Array) -> Dictionary:
	var normalized: Array = []
	for identifier in identifiers:
		var value := String(identifier)
		if not value.is_empty() and not normalized.has(value):
			normalized.append(value)
	normalized.sort()
	if normalized.is_empty():
		return _reject_simple("LTS-GRAPH-DELETE-001", "Select at least one node to delete.", "selection")
	return _dispatch_command(DocumentCommand.remove_task_nodes(graph_identifier, normalized), "remove_nodes")


func _on_copy_nodes_request() -> void:
	copy_selected_nodes()


func _on_cut_nodes_request() -> void:
	copy_selected_nodes()
	request_delete_selected()


func _on_paste_nodes_request() -> void:
	paste_clipboard(graph_position_from_viewport(size * 0.5))


func _on_duplicate_nodes_request() -> void:
	duplicate_selected_nodes()


func _on_begin_node_move() -> void:
	_move_in_progress = true
	_move_start_positions.clear()
	for identifier in _node_views:
		var view = _node_views[identifier]
		if view != null:
			_move_start_positions[String(identifier)] = view.position_offset


func _on_end_node_move() -> void:
	if not _move_in_progress:
		return
	_move_in_progress = false
	if _suppress_projection_events or _is_read_only() or _is_degraded():
		return
	var commands: Array = []
	var identifiers := _node_views.keys()
	identifiers.sort()
	for identifier in identifiers:
		var view = _node_views[identifier]
		if view == null:
			continue
		var current: Vector2 = view.position_offset
		var previous: Vector2 = _vector2_from_variant(_move_start_positions.get(String(identifier), _last_positions.get(String(identifier), current)))
		if not current.is_equal_approx(previous):
			commands.append(DocumentCommand.set_node_position(graph_identifier, String(identifier), current))
			_last_positions[String(identifier)] = current
	if not commands.is_empty():
		_dispatch_command(DocumentCommand.batch(commands), "move_nodes")


func _on_frame_rect_changed(frame: GraphFrame, new_rect: Rect2) -> void:
	if frame == null or _suppress_projection_events or _is_read_only() or _is_degraded():
		return
	var identifier := String(frame.get_meta("lts_frame_identifier", ""))
	if identifier.is_empty() or graph_identifier.is_empty():
		return
	var command = DocumentCommand.set_layout("task_graph", graph_identifier, "frame", identifier, _rect_to_array(new_rect), "rect")
	frame_changed.emit(identifier, new_rect)
	frame_command_requested.emit(identifier, command.to_dict())
	_dispatch_command(command, "frame_rect")


func _on_graph_elements_linked_to_frame_request(elements: Array, frame: StringName) -> void:
	if _is_read_only() or _is_degraded():
		return
	var frame_identifier := String(_frame_identifier_from_name(frame))
	if frame_identifier.is_empty():
		return
	var commands: Array = []
	for element in elements:
		var view := _view_for_name(StringName(element))
		if view == null:
			continue
		var identifier := String(view.get_meta("lts_node_identifier", ""))
		if not identifier.is_empty():
			commands.append(DocumentCommand.set_frame_membership(graph_identifier, identifier, frame_identifier))
	if not commands.is_empty():
		_dispatch_command(DocumentCommand.batch(commands), "frame_membership")


func _on_subgraph_open_requested(node_identifier: String, subgraph_identifier: String) -> void:
	navigate_into_subgraph(subgraph_identifier, node_identifier)


func _on_breadcrumb_activated(index: int) -> void:
	if index < 0 or index >= _breadcrumbs.size():
		return
	var item = _breadcrumbs[index]
	breadcrumb_requested.emit(index, item.duplicate(true) if item is Dictionary else {"label": String(item)})


func _on_scroll_offset_changed(_offset: Vector2) -> void:
	view_state_changed.emit(get_view_state())


func _dispatch_command(command: Variant, context: String = "") -> Dictionary:
	var data := _command_dictionary(command)
	if data.is_empty():
		return _reject_simple("LTS-GRAPH-COMMAND-001", "Graph command is not serializable.", "command")
	if _is_read_only() or _is_degraded():
		var error := {"code": "LTS-NATIVE-001", "message": "Native extension unavailable; graph is read-only.", "path": "native.level_task_system"}
		command_rejected.emit(data, error)
		mutation_rejected.emit(error)
		return {"ok": false, "applied": false, "error": error, "command": data}
	command_requested.emit(data.duplicate(true))
	document_command_requested.emit(data.duplicate(true))
	if route_commands_through_model and _document_model != null and _document_model.has_method("apply_command"):
		var result: Dictionary = _document_model.call("apply_command", command)
		if bool(result.get("ok", false)):
			command_applied.emit(data.duplicate(true), result.duplicate(true))
			_refresh_projection()
			return result
		var error: Dictionary = result.get("error", {"code": "LTS-GRAPH-COMMAND-002", "message": "Document model rejected the command.", "path": context})
		command_rejected.emit(data.duplicate(true), error.duplicate(true))
		mutation_rejected.emit(error.duplicate(true))
		_set_feedback({"ok": false, "compatible": false, "code": String(error.get("code", "LTS-GRAPH-COMMAND-002")), "reason": String(error.get("message", "Command rejected.")), "path": String(error.get("path", context)), "validation_scope": "document_model"})
		return result
	return {"ok": true, "applied": false, "intent": true, "context": context, "command": data}


func _reject_connection(feedback: Dictionary) -> void:
	var normalized := feedback.duplicate(true)
	normalized["ok"] = false
	normalized["compatible"] = false
	_set_feedback(normalized)
	connection_rejected.emit(normalized.duplicate(true))
	mutation_rejected.emit(normalized.duplicate(true))


func _set_feedback(feedback: Dictionary) -> void:
	_last_connection_feedback = feedback.duplicate(true)
	if _feedback_label != null:
		var compatible := bool(feedback.get("compatible", feedback.get("ok", false)))
		var code := String(feedback.get("code", feedback.get("reason_code", "")))
		var reason := String(feedback.get("reason", feedback.get("message", "Ready")))
		if compatible:
			_feedback_label.text = "[compatible] " + reason
			ComponentTheme.apply_state_text(_feedback_label, ComponentState.ACTIVE, _feedback_label.text)
		else:
			_feedback_label.text = "[rejected%s] %s" % [" " + code if not code.is_empty() else "", reason]
			ComponentTheme.apply_state_text(_feedback_label, ComponentState.ERROR, _feedback_label.text)
		_feedback_label.tooltip_text = _feedback_label.text
	connection_feedback_changed.emit(feedback.duplicate(true))


func _reject_simple(code: String, message: String, path: String) -> Dictionary:
	var error := {"code": code, "message": message, "path": path}
	mutation_rejected.emit(error.duplicate(true))
	return {"ok": false, "applied": false, "error": error}


func _command_dictionary(command: Variant) -> Dictionary:
	if command is Dictionary:
		return command.duplicate(true)
	if command is Object and command.has_method("to_dict"):
		var value = command.call("to_dict")
		return value.duplicate(true) if value is Dictionary else {}
	return {}


func _is_degraded() -> bool:
	if _document_model == null:
		return false
	if _document_model.has_method("is_degraded"):
		return bool(_document_model.call("is_degraded"))
	return false


func _is_read_only() -> bool:
	if _document_model == null:
		return false
	if _document_model.has_method("is_read_only") and bool(_document_model.call("is_read_only")):
		return true
	return _is_degraded()


func _edge_by_identifier(identifier: String) -> Dictionary:
	for edge in _graph_document.get("edges", []):
		if edge is Dictionary and String(edge.get("identifier", "")) == identifier:
			return edge.duplicate(true)
	return {}


func _find_edge(from_node: String, from_port: String, to_node: String, to_port: String) -> Dictionary:
	for edge in _graph_document.get("edges", []):
		if not edge is Dictionary:
			continue
		if String(edge.get("from_node_identifier", "")) == from_node and String(edge.get("from_port_identifier", "")) == from_port and String(edge.get("to_node_identifier", "")) == to_node and String(edge.get("to_port_identifier", "")) == to_port:
			return edge.duplicate(true)
	return {}


func _frame_identifier_from_name(frame_name: StringName) -> String:
	for identifier in _frame_views:
		var frame = _frame_views[identifier]
		if frame != null and StringName(frame.name) == frame_name:
			return String(identifier)
	return String(frame_name)


func _safe_element_name(prefix: String, identifier: String) -> String:
	var value := identifier.replace("/", "_").replace(" ", "_").replace(":", "_").replace("-", "_")
	if value.is_empty():
		value = "item"
	if value[0].is_valid_int():
		value = "_" + value
	return "lts_%s_%s" % [prefix, value]


func _vector2_from_variant(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


func _rect_from_variant(value: Variant, definition: Dictionary = {}) -> Rect2:
	if value is Rect2:
		return value
	if value is Array and value.size() >= 4:
		return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	var position := _vector2_from_variant(value)
	var size := _vector2_from_variant(definition.get("size", Vector2(360, 220)))
	if size == Vector2.ZERO:
		size = Vector2(360, 220)
	return Rect2(position, size)


func _rect_to_array(rect: Rect2) -> Array:
	return [float(rect.position.x), float(rect.position.y), float(rect.size.x), float(rect.size.y)]
