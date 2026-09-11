extends "res://ui/screens/utilities/utility_actions.gd"

## Authored maps screen controller.
##
## The desktop composition is authored in maps.tscn. This controller keeps the
## utility state and callbacks live while the inherited compact layout owns
## its responsive panes.

var _zone_cards: Array = []
var _zone_hits: Array = []
var _zone_names: Array = []
var _zone_risks: Array = []
var _zone_meta: Array = []
var _zone_task_counts: Array = []
var _map_info_values: Array = []
var _map_task_panels: Array = []
var _map_task_hits: Array = []
var _map_task_names: Array = []
var _map_task_meta: Array = []
var _map_task_status: Array = []
var _zone_markers: Array = []
var _zone_marker_labels: Array = []
var _extract_markers: Array = []
var _extract_marker_labels: Array = []
var _task_markers: Array = []
var _task_marker_labels: Array = []
var _squad_markers: Array = []
var _squad_marker_labels: Array = []
var _navigation_chrome: ZNavigationChrome


func build() -> void:
	reset_adaptive_layout()
	route = "maps"
	_resolve_static_nodes()
	_install_scale_safe_styles()
	_bind_navigation_chrome()
	_wire_map_actions()
	_bind_map_state()
	_build_focus_graph()
	queue_adaptive_layout()


func layout_compact(view: Vector2) -> void:
	# Compact maps owns its own tabs, panes and actions; hide the authored
	# desktop component before the inherited reflow moves map regions into
	# their compact workspaces.
	_hide_desktop_header_controls()
	super.layout_compact(view)


func _hide_desktop_header_controls() -> void:
	if _navigation_chrome != null:
		_navigation_chrome.hide()


func _bind_navigation_chrome() -> void:
	_navigation_chrome = get_node_or_null("NavigationChrome") as ZNavigationChrome
	if _navigation_chrome == null:
		push_error("Maps scene is missing its NavigationChrome component")
		return
	_navigation_chrome.active_route = "maps"
	var navigate := Callable(self, "_go")
	var insurance := Callable(self, "_maps_insurance_notice")
	var back := Callable(self, "_maps_back")
	if not _navigation_chrome.navigate_requested.is_connected(navigate):
		_navigation_chrome.navigate_requested.connect(navigate)
	if not _navigation_chrome.insurance_requested.is_connected(insurance):
		_navigation_chrome.insurance_requested.connect(insurance)
	if not _navigation_chrome.back_requested.is_connected(back):
		_navigation_chrome.back_requested.connect(back)
	mark_feature_action(_navigation_chrome.get_node_or_null("Insurance") as Control,
		FEATURE_INSURANCE)


func _install_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control := node as Control
		if control is Panel:
			_wrap_style_override(control, "panel")
		elif control is Button:
			for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
				_wrap_style_override(control, style_name)


func _wrap_style_override(control: Control, style_name: StringName) -> void:
	if not control.has_theme_stylebox_override(style_name):
		return
	var style := control.get_theme_stylebox(style_name)
	if style is StyleBoxFlat:
		control.add_theme_stylebox_override(style_name, U.scale_safe(style))


func _resolve_static_nodes() -> void:
	_zone_cards.clear()
	_zone_hits.clear()
	_zone_names.clear()
	_zone_risks.clear()
	_zone_meta.clear()
	_zone_task_counts.clear()
	for index in range(ZONES.size()):
		_zone_cards.append(get_node_or_null("ZoneCard%d" % index) as Panel)
		_zone_hits.append(get_node_or_null("ZoneHit%d" % index) as Button)
		_zone_names.append(get_node_or_null("ZoneName%d" % index) as Label)
		_zone_risks.append(get_node_or_null("ZoneRisk%d" % index) as Label)
		_zone_meta.append(get_node_or_null("ZoneMeta%d" % index) as Label)
		_zone_task_counts.append(get_node_or_null("ZoneTaskCount%d" % index) as Label)

	_map_info_values.clear()
	for index in range(5):
		_map_info_values.append(get_node_or_null("MapInfoValue%d" % index) as Label)

	_map_task_panels.clear()
	_map_task_hits.clear()
	_map_task_names.clear()
	_map_task_meta.clear()
	_map_task_status.clear()
	for index in range(2):
		_map_task_panels.append(get_node_or_null("MapTaskPanel%d" % index) as Panel)
		_map_task_hits.append(get_node_or_null("MapTaskHit%d" % index) as Button)
		_map_task_names.append(get_node_or_null("MapTaskName%d" % index) as Label)
		_map_task_meta.append(get_node_or_null("MapTaskMeta%d" % index) as Label)
		_map_task_status.append(get_node_or_null("MapTaskStatus%d" % index) as Label)

	_zone_markers.clear()
	_zone_marker_labels.clear()
	_extract_markers.clear()
	_extract_marker_labels.clear()
	_task_markers.clear()
	_task_marker_labels.clear()
	_squad_markers.clear()
	_squad_marker_labels.clear()
	for index in range(ZONES.size()):
		_zone_markers.append(get_node_or_null("RegionCanvas/ZoneMarker%d" % index) as Button)
		_zone_marker_labels.append(get_node_or_null("RegionCanvas/ZoneMarkerLabel%d" % index) as Label)
	for index in range(2):
		_extract_markers.append(get_node_or_null("RegionCanvas/ExtractMarker%d" % index) as Button)
		_extract_marker_labels.append(get_node_or_null("RegionCanvas/ExtractMarkerLabel%d" % index) as Label)
		_task_markers.append(get_node_or_null("RegionCanvas/TaskMarker%d" % index) as Button)
		_task_marker_labels.append(get_node_or_null("RegionCanvas/TaskMarkerLabel%d" % index) as Label)
		_squad_markers.append(get_node_or_null("RegionCanvas/SquadMarker%d" % index) as Button)
		_squad_marker_labels.append(get_node_or_null("RegionCanvas/SquadMarkerLabel%d" % index) as Label)


func _wire_map_actions() -> void:
	for index in range(_zone_hits.size()):
		_wire_map_button(_zone_hits[index], Callable(self, "_select_map_zone").bind(index), "zone_hit_%d" % index)

	_wire_map_button(get_node_or_null("ZoomMinus") as Button, Callable(self, "_map_zoom").bind(-10), "zoom_minus")
	_wire_map_button(get_node_or_null("ZoomPlus") as Button, Callable(self, "_map_zoom").bind(10), "zoom_plus")
	_wire_map_button(get_node_or_null("TimeButton_DAY") as Button, Callable(self, "_set_map_time").bind("DAY"), "time_day")
	_wire_map_button(get_node_or_null("TimeButton_DUSK") as Button, Callable(self, "_set_map_time").bind("DUSK"), "time_dusk")
	_wire_map_button(get_node_or_null("TimeButton_NIGHT") as Button, Callable(self, "_set_map_time").bind("NIGHT"), "time_night")
	for index in range(_map_task_hits.size()):
		_wire_map_button(_map_task_hits[index], Callable(self, "_select_map_task_row").bind(index), "map_task_%d" % index)
	_wire_map_button(get_node_or_null("Deploy") as Button, Callable(self, "_deploy_current_zone"), "deploy")

	for index in range(_zone_markers.size()):
		_wire_map_button(_zone_markers[index], Callable(self, "_select_map_marker").bind("zone", index), "zone_marker_%d" % index)
	for index in range(_extract_markers.size()):
		_wire_map_button(_extract_markers[index], Callable(self, "_select_map_marker").bind("extract", index), "extract_marker_%d" % index)
		_wire_map_button(_task_markers[index], Callable(self, "_select_map_marker").bind("task", index), "task_marker_%d" % index)
		_wire_map_button(_squad_markers[index], Callable(self, "_select_map_marker").bind("squad", index), "squad_marker_%d" % index)


func _wire_map_button(button: Button, callback: Callable, key: String) -> void:
	if button == null or not callback.is_valid() or bool(button.get_meta("maps_action_bound_" + key, false)):
		return
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(callback)
	button.set_meta("maps_action_bound_" + key, true)


func _bind_map_state() -> void:
	var zone_index := _map_zone_index()
	var selected_zone: Dictionary = ZONES[zone_index]
	var task_ids: Array = selected_zone.get("tasks", [])
	for index in range(ZONES.size()):
		var zone: Dictionary = ZONES[index]
		var selected: bool = index == zone_index
		var card: Panel = _zone_cards[index]
		if card != null:
			card.add_theme_stylebox_override("panel", _style_box(Color(1, 1, 1, 0.06) if selected else C_DARK, C_TEXT if selected else C_LINE))
		var name_label: Label = _zone_names[index]
		if name_label != null:
			name_label.text = str(zone.get("name", ""))
		var risk_label: Label = _zone_risks[index]
		if risk_label != null:
			risk_label.text = str(zone.get("risk", ""))
			risk_label.add_theme_color_override("font_color", _map_zone_color(zone))
		var meta_label: Label = _zone_meta[index]
		if meta_label != null:
			meta_label.text = str(zone.get("duration", "")) + " · " + str(zone.get("squad", "")) + " · " + str(str(zone.get("extracts", "")).split(" · ")[0]) + " extracts"
		var task_count_label: Label = _zone_task_counts[index]
		if task_count_label != null:
			var zone_tasks: Array = zone.get("tasks", [])
			task_count_label.text = (str(zone_tasks.size()) + " tasks") if not zone_tasks.is_empty() else "—"
			task_count_label.add_theme_color_override("font_color", C_ACCENT if not zone_tasks.is_empty() else C_MUTED)

	var marker_state := str(_state_value("utility_map_marker", "zone"))
	for index in range(_zone_markers.size()):
		_update_marker(_zone_markers[index], _zone_marker_labels[index], index == zone_index, C_ACCENT if index == zone_index else C_TEXT)
	for index in range(_extract_markers.size()):
		_update_marker(_extract_markers[index], _extract_marker_labels[index], false, C_GREEN)
		_update_marker(_task_markers[index], _task_marker_labels[index], false, C_ACCENT)
		_update_marker(_squad_markers[index], _squad_marker_labels[index], false, C_BLUE)

	var detail_title := str(selected_zone.get("name", ""))
	var detail_summary := str(selected_zone.get("summary", ""))
	var detail_risk := str(selected_zone.get("risk", "")) + " RISK"
	if marker_state.begins_with("task:"):
		var marker_task_index := int(marker_state.get_slice(":", 1))
		if marker_task_index >= 0 and marker_task_index < task_ids.size():
			var marker_task: Dictionary = _task_record(str(task_ids[marker_task_index]))
			detail_title = str(marker_task.get("title", "TASK"))
			detail_summary = str(marker_task.get("description", ""))
			detail_risk = "TASK BRIEF"
	elif marker_state.begins_with("extract:"):
		detail_title = "EXTRACT POINT"
		detail_summary = "Selectable route marker · squad readiness is shown below."
		detail_risk = "EXTRACT"
	elif marker_state.begins_with("squad:"):
		detail_title = "SQUAD POSITION"
		detail_summary = "Friendly squad marker · names are always readable in co-op."
		detail_risk = "FRIENDLY"
	var title_label := get_node_or_null("ZoneDetailsTitle") as Label
	if title_label != null:
		title_label.text = detail_title
	var summary_label := get_node_or_null("ZoneDetailsSummary") as Label
	if summary_label != null:
		summary_label.text = detail_summary
	var detail_risk_label := get_node_or_null("ZoneDetailsRisk") as Label
	if detail_risk_label != null:
		detail_risk_label.text = detail_risk
		detail_risk_label.add_theme_color_override("font_color", _map_zone_color(selected_zone))

	var info_values: Array[String] = [str(selected_zone.get("duration", "")), str(selected_zone.get("squad", "")), str(selected_zone.get("extracts", "")), str(selected_zone.get("threats", "")), str(selected_zone.get("loot", ""))]
	for index in range(mini(_map_info_values.size(), info_values.size())):
		var value_label: Label = _map_info_values[index]
		if value_label != null:
			value_label.text = info_values[index]

	var time_choice := str(_state_value("utility_map_time", "DAY"))
	for value in ["DAY", "DUSK", "NIGHT"]:
		var time_button := get_node_or_null("TimeButton_" + value) as Button
		if time_button == null:
			continue
		var active: bool = value == time_choice
		time_button.add_theme_color_override("font_color", C_BG if active else C_MUTED)
		time_button.add_theme_stylebox_override("normal", _style_box(C_TEXT if active else C_DARK, C_TEXT if active else C_LINE, 1))

	var zone_tasks_title := get_node_or_null("ZoneTasksTitle") as Label
	if zone_tasks_title != null:
		zone_tasks_title.text = "TASKS IN THIS ZONE · " + str(task_ids.size())
	for index in range(_map_task_panels.size()):
		var visible_row: bool = index < task_ids.size()
		var panel: Panel = _map_task_panels[index]
		var hit: Button = _map_task_hits[index]
		var name_label: Label = _map_task_names[index]
		var meta_label: Label = _map_task_meta[index]
		var status_label: Label = _map_task_status[index]
		for item in [panel, hit, name_label, meta_label, status_label]:
			if item != null:
				item.visible = visible_row
		if not visible_row:
			continue
		var task: Dictionary = _task_record(str(task_ids[index]))
		var selected_task: bool = str(_state_value("utility_map_task", "supply_run")) == str(task.get("id", ""))
		if panel != null:
			panel.add_theme_stylebox_override("panel", _style_box(Color(1, 1, 1, 0.04) if selected_task else C_DARK, C_TEXT if selected_task else C_LINE))
		if name_label != null:
			name_label.text = str(task.get("list_title", ""))
		if meta_label != null:
			meta_label.text = str(task.get("trader", "")) + " · " + str(task.get("zone", ""))
		if status_label != null:
			status_label.text = "TRACKED" if bool(_state_value("hud_tracked_task_id", "supply_run") == task.get("id", "")) else "TRACK"
			status_label.add_theme_color_override("font_color", C_ACCENT if selected_task else C_MUTED)

	var zoom_label := get_node_or_null("ZoomLabel") as Label
	if zoom_label != null:
		zoom_label.text = "ZOOM " + str(int(_state_value("utility_map_zoom", 100))) + "%"
	var deploy_button := get_node_or_null("Deploy") as Button
	if deploy_button != null:
		deploy_button.text = "F   DEPLOY · " + str(selected_zone.get("name", ""))
	_sync_compact_map_state()


func _update_marker(marker: Button, label: Label, selected: bool, color: Color) -> void:
	if marker != null:
		marker.add_theme_color_override("font_color", color)
		marker.add_theme_stylebox_override("normal", _style_box(Color(0.03, 0.04, 0.04, 0.80), color, 2 if selected else 1))
		marker.add_theme_stylebox_override("hover", _style_box(Color(0.15, 0.10, 0.04, 0.90), C_HOVER, 2))
	if label != null:
		label.add_theme_color_override("font_color", color)


func _sync_compact_map_state() -> void:
	var selected := str(_state_value("utility_compact_maps", "ZONE DETAILS"))
	var details := get_node_or_null("ZoneDetailsPane") as ScrollContainer
	if details != null:
		details.visible = selected == "ZONE DETAILS"
	var region := get_node_or_null("RegionMapPane") as ScrollContainer
	if region != null:
		region.visible = selected == "REGION MAP"
	for child in get_children():
		if child is Button and child.text in ["ZONE DETAILS", "REGION MAP"]:
			var active: bool = child.text == selected
			child.add_theme_stylebox_override("normal", _style_box(Color(1, 1, 1, 0.06), C_TEXT) if active else _style_box(C_DARK, C_LINE))


func _rerender() -> void:
	# Map interactions update authored controls in place so compact panes keep
	# their scroll offsets and do not lose their static scene ownership.
	_bind_map_state()


func _select_map_task_row(index: int) -> void:
	var zone: Dictionary = ZONES[_map_zone_index()]
	var task_ids: Array = zone.get("tasks", [])
	if index >= 0 and index < task_ids.size():
		_select_map_task(str(task_ids[index]))


func _deploy_current_zone() -> void:
	_deploy_zone(_map_zone_index())


func _maps_insurance_notice() -> void:
	notify_feature_action(FEATURE_INSURANCE)


func _maps_back() -> void:
	if app != null:
		app.back()


func _build_focus_graph() -> void:
	for index in range(_zone_hits.size()):
		var button: Button = _zone_hits[index]
		if button == null:
			continue
		var previous: Button = _zone_hits[posmod(index - 1, _zone_hits.size())]
		var next: Button = _zone_hits[(index + 1) % _zone_hits.size()]
		button.focus_neighbor_top = button.get_path_to(previous)
		button.focus_neighbor_bottom = button.get_path_to(next)
	for buttons in [[get_node_or_null("TimeButton_DAY") as Button, get_node_or_null("TimeButton_DUSK") as Button, get_node_or_null("TimeButton_NIGHT") as Button], [_map_task_hits[0], _map_task_hits[1]]]:
		for index in range(buttons.size()):
			var button: Button = buttons[index]
			if button == null:
				continue
			var previous: Button = buttons[posmod(index - 1, buttons.size())]
			var next: Button = buttons[(index + 1) % buttons.size()]
			button.focus_neighbor_left = button.get_path_to(previous)
			button.focus_neighbor_right = button.get_path_to(next)
