@tool
class_name LtsLiveRuntimeDebugger
extends PanelContainer

## Read-only live runtime observation surface.
##
## This Control is intentionally fed with plain dictionaries by a host-owned
## adapter.  It does not inspect a TaskGraphInstance, connect to an authority,
## or create input/acknowledgement controls.  Filtering, selection, and
## clearing a local query only change this projection's view.

signal instance_selected(instance_identifier: String)
signal trace_selected(trace: Dictionary)
signal filter_changed(query: String, status: String)

const ModelScript := preload("res://addons/level_task_system/editor/debug/lts_live_runtime_debugger_model.gd")
const ComponentState := preload("res://addons/level_task_system/editor/components/lts_component_state.gd")
const ComponentTheme := preload("res://addons/level_task_system/editor/components/lts_component_theme.gd")

var _model
var _built := false
var _refreshing := false

var _title_label: Label
var _read_only_label: Label
var _status_label: Label
var _instance_filter: LineEdit
var _status_filter: OptionButton
var _clear_filters: Button
var _content: HSplitContainer
var _instance_tree: Tree
var _instance_empty_label: Label
var _trace_tree: Tree
var _trace_empty_label: Label
var _summary_label: Label
var _detail_label: Label
var _empty_panel: PanelContainer
var _empty_title: Label
var _empty_message: Label
var _empty_icon: TextureRect


func _init() -> void:
	theme_type_variation = &"LevelTaskDrawer"
	focus_mode = Control.FOCUS_ALL
	_model = ModelScript.new()


func _ready() -> void:
	_built = true
	_build()
	_refresh()


func _build() -> void:
	if not _built and not is_inside_tree():
		return
	if _title_label != null:
		return
	var column := VBoxContainer.new()
	column.name = "LiveRuntimeDebuggerColumn"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(column)

	var header := HBoxContainer.new()
	header.name = "DebuggerHeader"
	column.add_child(header)
	_title_label = Label.new()
	_title_label.name = "DebuggerTitle"
	_title_label.text = "Live runtime debugger"
	_title_label.tooltip_text = "Observe recipient-safe task runtime summaries and bounded trace records"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_read_only_label = Label.new()
	_read_only_label.name = "ReadOnlyBadge"
	_read_only_label.text = "Read-only observation"
	_read_only_label.tooltip_text = "This view cannot change the running authority instance"
	header.add_child(_read_only_label)
	_status_label = Label.new()
	_status_label.name = "DebuggerStatus"
	_status_label.tooltip_text = "Live feed state"
	header.add_child(_status_label)

	var filters := HBoxContainer.new()
	filters.name = "DebuggerFilters"
	column.add_child(filters)
	_instance_filter = LineEdit.new()
	_instance_filter.name = "InstanceFilter"
	_instance_filter.placeholder_text = "Filter instances and trace"
	_instance_filter.tooltip_text = "Filter by instance, graph, node, request, event, outcome, or status"
	_instance_filter.clear_button_enabled = true
	_instance_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_instance_filter.focus_mode = Control.FOCUS_ALL
	_instance_filter.text_changed.connect(_on_filter_text_changed)
	filters.add_child(_instance_filter)
	_status_filter = OptionButton.new()
	_status_filter.name = "StatusFilter"
	_status_filter.tooltip_text = "Filter runtime instances by graph status"
	_status_filter.focus_mode = Control.FOCUS_ALL
	_status_filter.add_item("All statuses")
	_status_filter.set_item_metadata(0, ModelScript.STATUS_ALL)
	for status in ModelScript.GRAPH_STATUSES:
		_status_filter.add_item(ModelScript.status_label(status))
		_status_filter.set_item_metadata(_status_filter.item_count - 1, status)
	_status_filter.item_selected.connect(_on_status_filter_selected)
	filters.add_child(_status_filter)
	_clear_filters = Button.new()
	_clear_filters.name = "ClearFilters"
	_clear_filters.text = "Clear filters"
	_clear_filters.tooltip_text = "Clear local debugger filters"
	_clear_filters.focus_mode = Control.FOCUS_ALL
	_clear_filters.pressed.connect(_on_clear_filters)
	filters.add_child(_clear_filters)

	_content = HSplitContainer.new()
	_content.name = "DebuggerContent"
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_content)

	var instance_panel := PanelContainer.new()
	instance_panel.name = "InstancePanel"
	instance_panel.custom_minimum_size = Vector2(240, 0)
	_content.add_child(instance_panel)
	var instance_column := VBoxContainer.new()
	instance_column.name = "InstanceColumn"
	instance_panel.add_child(instance_column)
	var instance_heading := Label.new()
	instance_heading.name = "InstanceHeading"
	instance_heading.text = "Runtime instances"
	instance_heading.tooltip_text = "Recipient-safe instance summaries published by the host"
	instance_column.add_child(instance_heading)
	_instance_tree = Tree.new()
	_instance_tree.name = "InstanceList"
	_instance_tree.columns = 2
	_instance_tree.hide_root = true
	_instance_tree.select_mode = Tree.SELECT_ROW
	_instance_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_instance_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_instance_tree.focus_mode = Control.FOCUS_ALL
	_instance_tree.set_column_title(0, "Instance")
	_instance_tree.set_column_title(1, "Status")
	_instance_tree.item_selected.connect(_on_instance_item_selected)
	instance_column.add_child(_instance_tree)
	_instance_empty_label = Label.new()
	_instance_empty_label.name = "InstanceEmptyMessage"
	_instance_empty_label.text = "No instances match the active filter."
	_instance_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_instance_empty_label.visible = false
	instance_column.add_child(_instance_empty_label)

	var detail_panel := PanelContainer.new()
	detail_panel.name = "DetailPanel"
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(detail_panel)
	var detail_column := VBoxContainer.new()
	detail_column.name = "DetailColumn"
	detail_panel.add_child(detail_column)
	_summary_label = Label.new()
	_summary_label.name = "InstanceSummary"
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.tooltip_text = "Selected recipient-safe instance summary"
	detail_column.add_child(_summary_label)
	var trace_heading := Label.new()
	trace_heading.name = "TraceHeading"
	trace_heading.text = "Bounded trace"
	trace_heading.tooltip_text = "Retained TaskTraceRecord projections; newest records remain within the feed cap"
	detail_column.add_child(trace_heading)
	_trace_tree = Tree.new()
	_trace_tree.name = "TraceList"
	_trace_tree.columns = 3
	_trace_tree.hide_root = true
	_trace_tree.select_mode = Tree.SELECT_ROW
	_trace_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_trace_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trace_tree.focus_mode = Control.FOCUS_ALL
	_trace_tree.set_column_title(0, "Revision")
	_trace_tree.set_column_title(1, "Kind")
	_trace_tree.set_column_title(2, "Activity")
	_trace_tree.item_selected.connect(_on_trace_item_selected)
	detail_column.add_child(_trace_tree)
	_trace_empty_label = Label.new()
	_trace_empty_label.name = "TraceEmptyMessage"
	_trace_empty_label.text = "No trace records for the selected instance."
	_trace_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trace_empty_label.visible = false
	detail_column.add_child(_trace_empty_label)
	_detail_label = Label.new()
	_detail_label.name = "TraceDetails"
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_label.tooltip_text = "Selected trace record"
	detail_column.add_child(_detail_label)

	_empty_panel = PanelContainer.new()
	_empty_panel.name = "EmptyState"
	_empty_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var empty_column := VBoxContainer.new()
	empty_column.name = "EmptyStateColumn"
	empty_column.alignment = BoxContainer.ALIGNMENT_CENTER
	_empty_panel.add_child(empty_column)
	_empty_icon = TextureRect.new()
	_empty_icon.name = "EmptyIcon"
	_empty_icon.custom_minimum_size = Vector2(0, 28)
	_empty_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_empty_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_empty_icon.tooltip_text = "Live runtime observation state"
	empty_column.add_child(_empty_icon)
	_empty_title = Label.new()
	_empty_title.name = "EmptyTitle"
	_empty_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_column.add_child(_empty_title)
	_empty_message = Label.new()
	_empty_message.name = "EmptyMessage"
	_empty_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	empty_column.add_child(_empty_message)
	column.add_child(_empty_panel)


## Bind an already-created pure model.  The model remains the source of truth
## for feed data; this method only changes which projection is rendered.
func set_model(p_model: RefCounted) -> void:
	if p_model == null:
		return
	if not p_model.has_method("get_projection") or not p_model.has_method("ingest"):
		return
	_model = p_model
	_refresh()


func get_model() -> RefCounted:
	return _model


func set_feed(p_feed: Variant) -> Dictionary:
	var result: Dictionary = _model.ingest(p_feed)
	_refresh()
	return result


func ingest(p_feed: Variant) -> Dictionary:
	return set_feed(p_feed)


func consume(p_feed: Variant) -> Dictionary:
	return set_feed(p_feed)


func apply_feed(p_feed: Variant) -> Dictionary:
	return set_feed(p_feed)


func set_available(p_available: bool, p_reason: String = "") -> Dictionary:
	var result: Dictionary = _model.set_available(p_available, p_reason)
	_refresh()
	return result


func set_loading(p_loading: bool) -> Dictionary:
	var result: Dictionary = _model.set_loading(p_loading)
	_refresh()
	return result


func clear_feed() -> Dictionary:
	var result: Dictionary = _model.clear()
	_refresh()
	return result


func set_filter(p_query: String) -> Dictionary:
	var result: Dictionary = _model.set_filter(p_query)
	_refresh()
	return result


func set_status_filter(p_status: String) -> Dictionary:
	var result: Dictionary = _model.set_status_filter(p_status)
	_refresh()
	return result


func get_projection() -> Dictionary:
	return _model.get_projection()


func get_visible_instances() -> Array:
	return _model.get_visible_instances()


func get_visible_traces() -> Array:
	return _model.get_visible_traces()


func get_state() -> StringName:
	return _model.get_state()


func is_read_only() -> bool:
	return true


func has_authority_controls() -> bool:
	return false


func get_authority_actions() -> Array:
	return []


func get_mutation_commands() -> Array:
	return []


func select_instance(p_identifier: String) -> Dictionary:
	var result: Dictionary = _model.select_instance(p_identifier)
	_refresh()
	return result


func select_trace(p_selection: Variant) -> Dictionary:
	var result: Dictionary = _model.select_trace(p_selection)
	_refresh()
	return result


func _refresh() -> void:
	if _refreshing:
		return
	if _instance_tree == null:
		return
	_refreshing = true
	var projection: Dictionary = _model.get_projection()
	_instance_filter.text = String(projection.get("filter_query", "")) if _instance_filter.text != String(projection.get("filter_query", "")) else _instance_filter.text
	_sync_status_filter(projection)
	_update_status(projection)
	_rebuild_instance_tree(projection)
	_rebuild_trace_tree(projection)
	_update_details(projection)
	_update_state_surface(projection)
	_refreshing = false


func _sync_status_filter(p_projection: Dictionary) -> void:
	if _status_filter == null:
		return
	var wanted := String(p_projection.get("status_filter", ModelScript.STATUS_ALL))
	for index in range(_status_filter.item_count):
		if String(_status_filter.get_item_metadata(index)) == wanted:
			if _status_filter.selected != index:
				_status_filter.select(index)
			return


func _update_status(p_projection: Dictionary) -> void:
	var state := StringName(String(p_projection.get("state", "empty")))
	var state_label := String(p_projection.get("state_label", "Live runtime observation"))
	var counts: Dictionary = p_projection.get("counts", {})
	var status_text := "%s · %d instance(s) · %d trace(s)" % [
		state_label,
		int(counts.get("instances", 0)),
		int(counts.get("traces", 0)),
	]
	if bool(p_projection.get("trace_truncated", false)):
		status_text += " · trace capped"
	_status_label.text = status_text
	_status_label.tooltip_text = status_text
	_status_label.remove_theme_color_override(&"font_color")
	if state == ModelScript.STATE_ERROR or state == ModelScript.STATE_DEGRADED:
		_status_label.add_theme_color_override(&"font_color", ComponentTheme.state_color(self, ComponentState.ERROR))
	elif state == ModelScript.STATE_LOADING:
		_status_label.add_theme_color_override(&"font_color", ComponentTheme.state_color(self, ComponentState.LOADING))
	elif state == ModelScript.STATE_READY:
		_status_label.add_theme_color_override(&"font_color", ComponentTheme.state_color(self, ComponentState.ACTIVE))
	_read_only_label.tooltip_text = "No authority event, acknowledgement, request, or state mutation controls are available"


func _rebuild_instance_tree(p_projection: Dictionary) -> void:
	_instance_tree.clear()
	var root := _instance_tree.create_item()
	var instances: Array = p_projection.get("instances", [])
	for summary_value in instances:
		if not summary_value is Dictionary:
			continue
		var summary: Dictionary = summary_value
		var item := _instance_tree.create_item(root)
		var identifier := String(summary.get("instance_identifier", ""))
		var status := String(summary.get("status", "invalid"))
		item.set_text(0, identifier)
		item.set_text(1, ModelScript.status_label(status))
		item.set_tooltip_text(0, ModelScript.instance_row_text(summary))
		item.set_tooltip_text(1, "Graph status: " + ModelScript.status_label(status))
		item.set_icon(0, ComponentTheme.state_icon(self, ComponentState.ACTIVE if status == "running" else ComponentState.DEFAULT))
		item.set_metadata(0, identifier)
		if identifier == String(p_projection.get("selected_instance_identifier", "")):
			item.select(0)
			item.set_custom_bg_color(0, ComponentTheme.state_color(self, ComponentState.ACTIVE))
	_instance_empty_label.visible = instances.is_empty()


func _rebuild_trace_tree(p_projection: Dictionary) -> void:
	_trace_tree.clear()
	var root := _trace_tree.create_item()
	var traces: Array = p_projection.get("traces", [])
	var selected_key := String(p_projection.get("selected_trace_key", ""))
	for trace_value in traces:
		if not trace_value is Dictionary:
			continue
		var trace: Dictionary = trace_value
		var item := _trace_tree.create_item(root)
		item.set_text(0, str(int(trace.get("revision", 0))))
		item.set_text(1, ModelScript.trace_kind_label(String(trace.get("kind", "trace"))))
		item.set_text(2, _trace_activity_text(trace))
		item.set_tooltip_text(2, ModelScript.trace_row_text(trace))
		item.set_metadata(0, ModelScript.trace_row_text(trace))
		item.set_metadata(1, _trace_key(trace))
		item.set_icon(1, ComponentTheme.state_icon(self, ComponentState.ACTIVE))
		if _trace_key(trace) == selected_key:
			item.select(0)
	_trace_empty_label.visible = traces.is_empty()


func _update_details(p_projection: Dictionary) -> void:
	var summary: Dictionary = p_projection.get("selected_instance", {})
	if summary.is_empty():
		_summary_label.text = "No runtime instance selected."
		_detail_label.text = "Select a recipient-safe instance summary to inspect its bounded node and request state."
		return
	var lines := PackedStringArray()
	lines.append("Instance: %s" % String(summary.get("instance_identifier", "(unknown)")))
	lines.append("Graph: %s" % String(summary.get("graph_identifier", "(unknown)")))
	lines.append("Status: %s" % ModelScript.status_label(String(summary.get("status", "invalid"))))
	lines.append("Revision: %d" % int(summary.get("revision", 0)))
	var scope := String(summary.get("scope_key", ""))
	if not scope.is_empty():
		lines.append("Scope: %s" % scope)
	var fingerprint := String(summary.get("definition_fingerprint", ""))
	if not fingerprint.is_empty():
		lines.append("Definition fingerprint: %s" % fingerprint)
	var outcome := String(summary.get("terminal_outcome", ""))
	if not outcome.is_empty():
		lines.append("Outcome: %s" % outcome)
	lines.append("Nodes: %d · Pending requests: %d" % [
		int(summary.get("node_count", 0)),
		int(summary.get("pending_request_count", 0)),
	])
	_summary_label.text = "\n".join(lines)
	_summary_label.tooltip_text = _summary_label.text
	var trace: Dictionary = p_projection.get("selected_trace", {})
	if trace.is_empty():
		_detail_label.text = "No trace record selected. Trace rows are observation-only and contain no private payloads."
		return
	var detail_lines := PackedStringArray()
	detail_lines.append(ModelScript.trace_row_text(trace))
	detail_lines.append("Instance: %s" % String(trace.get("instance_identifier", "")))
	detail_lines.append("Graph status: %s" % ModelScript.status_label(String(trace.get("graph_status", "invalid"))))
	var node := String(trace.get("node_identifier", ""))
	if not node.is_empty():
		detail_lines.append("Node: %s" % node)
	var event := String(trace.get("event_identifier", ""))
	if not event.is_empty():
		detail_lines.append("Event: %s" % event)
	var request := String(trace.get("request_identifier", ""))
	if not request.is_empty():
		detail_lines.append("Request: %s" % request)
	var outcome_detail := String(trace.get("outcome_identifier", ""))
	if not outcome_detail.is_empty():
		detail_lines.append("Outcome: %s" % outcome_detail)
	_detail_label.text = "\n".join(detail_lines)
	_detail_label.tooltip_text = _detail_label.text


func _update_state_surface(p_projection: Dictionary) -> void:
	var state := StringName(String(p_projection.get("state", "empty")))
	var has_instances := not (p_projection.get("instances", []) as Array).is_empty()
	var show_panel := state == ModelScript.STATE_EMPTY or state == ModelScript.STATE_LOADING or state == ModelScript.STATE_DEGRADED \
			or (state == ModelScript.STATE_ERROR and not has_instances)
	_empty_panel.visible = show_panel
	if _content != null:
		_content.visible = not show_panel
	var title := "No live runtime activity"
	var message := String(p_projection.get("empty_message", "The host has not published a recipient-safe runtime summary or trace."))
	var panel_state: Variant = ComponentState.EMPTY
	if state == ModelScript.STATE_DEGRADED:
		title = "Live runtime unavailable"
		message = String(p_projection.get("degraded_message", "The live runtime feed is unavailable.")) + "\nObservation remains read-only; wait for a compatible host feed."
		panel_state = ComponentState.ERROR
	elif state == ModelScript.STATE_ERROR:
		title = "Live runtime feed rejected"
		var diagnostic: Dictionary = p_projection.get("diagnostic", {})
		message = "%s\nCode: %s · Path: %s" % [
			String(diagnostic.get("message", "The feed could not be displayed.")),
			String(diagnostic.get("code", "LTS-LIVE-000")),
			String(diagnostic.get("path", "live_runtime")),
		]
		panel_state = ComponentState.ERROR
	elif state == ModelScript.STATE_LOADING:
		title = "Waiting for live runtime feed"
		message = "The editor is preserving the current observation context while the host feed is loading."
		panel_state = ComponentState.LOADING
	_empty_title.text = title
	_empty_message.text = message
	_empty_title.tooltip_text = title
	_empty_message.tooltip_text = message
	_empty_icon.texture = ComponentTheme.state_icon(self, panel_state)
	_empty_icon.tooltip_text = title
	ComponentTheme.apply_state_text(_empty_title, panel_state, title)
	ComponentTheme.apply_state_text(_empty_message, panel_state, message)


func _trace_activity_text(p_trace: Dictionary) -> String:
	var parts := PackedStringArray()
	var node := String(p_trace.get("node_identifier", ""))
	if not node.is_empty():
		parts.append(node)
	var event := String(p_trace.get("event_identifier", ""))
	if not event.is_empty():
		parts.append("event=" + event)
	var request := String(p_trace.get("request_identifier", ""))
	if not request.is_empty():
		parts.append("request=" + request)
	var outcome := String(p_trace.get("outcome_identifier", ""))
	if not outcome.is_empty():
		parts.append("outcome=" + outcome)
	return " · ".join(parts) if not parts.is_empty() else "runtime state"


func _trace_key(p_trace: Dictionary) -> String:
	return "%s|%d|%d|%s|%s|%s" % [
		String(p_trace.get("instance_identifier", "")),
		int(p_trace.get("revision", 0)),
		int(p_trace.get("ordinal", 0)),
		String(p_trace.get("kind", "")),
		String(p_trace.get("node_identifier", "")),
		String(p_trace.get("request_identifier", p_trace.get("event_identifier", ""))) \
				+ "|" + String(p_trace.get("event_identifier", "")) \
				+ "|" + String(p_trace.get("outcome_identifier", "")),
	]


func _on_filter_text_changed(value: String) -> void:
	if _refreshing:
		return
	_model.set_filter(value)
	_refresh()
	filter_changed.emit(value, _model.get_status_filter())


func _on_status_filter_selected(index: int) -> void:
	if _refreshing:
		return
	var status := String(_status_filter.get_item_metadata(index))
	_model.set_status_filter(status)
	_refresh()
	filter_changed.emit(_model.get_filter_query(), status)


func _on_clear_filters() -> void:
	if _refreshing:
		return
	_model.set_filter("")
	_model.set_status_filter(ModelScript.STATUS_ALL)
	_refresh()
	filter_changed.emit("", ModelScript.STATUS_ALL)


func _on_instance_item_selected() -> void:
	if _refreshing or _instance_tree == null:
		return
	var item := _instance_tree.get_selected()
	if item == null:
		return
	var identifier := String(item.get_metadata(0))
	if identifier.is_empty():
		return
	_model.select_instance(identifier)
	_refresh()
	instance_selected.emit(identifier)


func _on_trace_item_selected() -> void:
	if _refreshing or _trace_tree == null:
		return
	var item := _trace_tree.get_selected()
	if item == null:
		return
	var key := String(item.get_metadata(1))
	if key.is_empty():
		return
	var result: Dictionary = _model.select_trace(key)
	if not result.get("ok", false):
		return
	_refresh()
	trace_selected.emit(_model.get_selected_trace())
