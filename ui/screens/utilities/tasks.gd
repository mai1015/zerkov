extends "res://ui/screens/utilities/utility_actions.gd"

## Authored tasks screen controller.
##
## The desktop composition lives in tasks.tscn. This script resolves those
## controls, wires their actions, and keeps the utility state reflected in the
## authored hierarchy. The inherited compact layout still owns the responsive
## panes; compact task cards are rebuilt inside their pane while the authored
## detail controls stay alive and retain focus and scroll behavior.

var _trader_cards: Array = []
var _trader_hits: Array = []
var _trader_initials: Array = []
var _trader_names: Array = []
var _trader_subs: Array = []
var _trader_count_backgrounds: Array = []
var _trader_counts: Array = []

var _task_cards: Array = []
var _task_hits: Array = []
var _task_names: Array = []
var _task_tags: Array = []
var _task_meta: Array = []
var _task_progress_tracks: Array = []
var _task_progress_fills: Array = []
var _task_progress_values: Array = []
var _task_rewards: Array = []
var _task_ids: Array = []

var _objective_hits: Array = []
var _objective_rules: Array = []
var _objective_boxes: Array = []
var _objective_box_tops: Array = []
var _objective_box_bottoms: Array = []
var _objective_box_lefts: Array = []
var _objective_box_rights: Array = []
var _objective_checks: Array = []
var _objective_texts: Array = []
var _objective_values: Array = []

var _detail_nodes: Array = []
var _authored_controls: Array = []
var _desktop_rects: Dictionary = {}
var _compact_ready: bool = false
var _compact_view := Vector2.ZERO
var _desktop_shape_default: bool = true
var _navigation_chrome: ZNavigationChrome


func build() -> void:
	reset_adaptive_layout()
	route = "tasks"
	_resolve_static_nodes()
	_capture_desktop_rects()
	_install_scale_safe_styles()
	_bind_navigation_chrome()
	_wire_task_actions()
	_bind_task_state()
	_build_focus_graph()
	queue_adaptive_layout()


func _resolve_static_nodes() -> void:
	_trader_cards.clear()
	_trader_hits.clear()
	_trader_initials.clear()
	_trader_names.clear()
	_trader_subs.clear()
	_trader_count_backgrounds.clear()
	_trader_counts.clear()
	for index in range(TRADERS.size()):
		_trader_cards.append(get_node_or_null("TraderCard%d" % index) as Panel)
		_trader_hits.append(get_node_or_null("TraderHit%d" % index) as Button)
		_trader_initials.append(get_node_or_null("TraderInitial%d" % index) as Label)
		_trader_names.append(get_node_or_null("TraderName%d" % index) as Label)
		_trader_subs.append(get_node_or_null("TraderSub%d" % index) as Label)
		_trader_count_backgrounds.append(get_node_or_null("TraderCountBackground%d" % index) as ColorRect)
		_trader_counts.append(get_node_or_null("TraderCount%d" % index) as Label)

	_task_cards.clear()
	_task_hits.clear()
	_task_names.clear()
	_task_tags.clear()
	_task_meta.clear()
	_task_progress_tracks.clear()
	_task_progress_fills.clear()
	_task_progress_values.clear()
	_task_rewards.clear()
	for index in range(3):
		_task_cards.append(get_node_or_null("TaskCard%d" % index) as Panel)
		_task_hits.append(get_node_or_null("TaskHit%d" % index) as Button)
		_task_names.append(get_node_or_null("TaskName%d" % index) as Label)
		_task_tags.append(get_node_or_null("TaskTag%d" % index) as Label)
		_task_meta.append(get_node_or_null("TaskMeta%d" % index) as Label)
		_task_progress_tracks.append(get_node_or_null("TaskProgressTrack%d" % index) as ColorRect)
		_task_progress_fills.append(get_node_or_null("TaskProgressFill%d" % index) as ColorRect)
		_task_progress_values.append(get_node_or_null("TaskProgressValue%d" % index) as Label)
		_task_rewards.append(get_node_or_null("TaskReward%d" % index) as Label)

	_objective_hits.clear()
	_objective_rules.clear()
	_objective_boxes.clear()
	_objective_box_tops.clear()
	_objective_box_bottoms.clear()
	_objective_box_lefts.clear()
	_objective_box_rights.clear()
	_objective_checks.clear()
	_objective_texts.clear()
	_objective_values.clear()
	for index in range(4):
		_objective_hits.append(get_node_or_null("TaskObjectiveHit%d" % index) as Button)
		_objective_rules.append(get_node_or_null("TaskObjectiveRule%d" % index) as ColorRect)
		_objective_boxes.append(get_node_or_null("TaskObjectiveBox%d" % index) as ColorRect)
		_objective_box_tops.append(get_node_or_null("TaskObjectiveBoxTop%d" % index) as ColorRect)
		_objective_box_bottoms.append(get_node_or_null("TaskObjectiveBoxBottom%d" % index) as ColorRect)
		_objective_box_lefts.append(get_node_or_null("TaskObjectiveBoxLeft%d" % index) as ColorRect)
		_objective_box_rights.append(get_node_or_null("TaskObjectiveBoxRight%d" % index) as ColorRect)
		_objective_checks.append(get_node_or_null("TaskObjectiveCheck%d" % index) as Label)
		_objective_texts.append(get_node_or_null("TaskObjectiveText%d" % index) as Label)
		_objective_values.append(get_node_or_null("TaskObjectiveValue%d" % index) as Label)

	_detail_nodes = [
		get_node_or_null("TaskMerchantPanel"), get_node_or_null("TaskMerchantImage"),
		get_node_or_null("TaskTraderRep"), get_node_or_null("TaskDetailTitle"),
		get_node_or_null("TaskDetailZone"), get_node_or_null("TaskTrackedPanel"),
		get_node_or_null("TaskTrackedLabel"), get_node_or_null("TaskTrackedHit"),
		get_node_or_null("TaskDetailRule"), get_node_or_null("TaskDescription"),
		get_node_or_null("TaskObjectivesTitle")
	]
	for index in range(4):
		_detail_nodes.append(_objective_hits[index])
		_detail_nodes.append(_objective_rules[index])
		_detail_nodes.append(_objective_boxes[index])
		_detail_nodes.append(_objective_box_tops[index])
		_detail_nodes.append(_objective_box_bottoms[index])
		_detail_nodes.append(_objective_box_lefts[index])
		_detail_nodes.append(_objective_box_rights[index])
		_detail_nodes.append(_objective_checks[index])
		_detail_nodes.append(_objective_texts[index])
		_detail_nodes.append(_objective_values[index])
	_detail_nodes.append(get_node_or_null("TaskRewardsTitle"))
	for key in ["XP", "Cash", "Item", "Rep"]:
		_detail_nodes.append(get_node_or_null("TaskRewardPanel" + key))
		_detail_nodes.append(get_node_or_null("TaskRewardLabel" + key))
		_detail_nodes.append(get_node_or_null("TaskRewardValue" + key))
	_detail_nodes.append(get_node_or_null("TaskTrackPanel"))
	_detail_nodes.append(get_node_or_null("TaskTrackTitle"))
	_detail_nodes.append(get_node_or_null("TaskTrackSubtitle"))
	_detail_nodes.append(get_node_or_null("TaskTrackToggle"))
	_detail_nodes.append(get_node_or_null("TaskTrackFill"))


func _capture_desktop_rects() -> void:
	_desktop_rects.clear()
	_authored_controls.clear()
	for node in find_children("*", "Control", true, false):
		if node is Control:
			var control: Control = node
			_authored_controls.append(control)
			_desktop_rects[control.get_instance_id()] = Rect2(control.position, control.size)


func _desktop_rect(node: Control) -> Rect2:
	if node == null:
		return Rect2()
	return _desktop_rects.get(node.get_instance_id(), Rect2(node.position, node.size))


func _find_static(node_name: String) -> Control:
	return find_child(node_name, true, false) as Control


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


func _wire_task_actions() -> void:
	for index in range(_trader_hits.size()):
		_wire_task_button(_trader_hits[index], Callable(self, "_select_trader").bind(index), "trader_%d" % index)
	for index in range(_task_hits.size()):
		_wire_task_button(_task_hits[index], Callable(self, "_select_static_task").bind(index), "task_%d" % index)
	_wire_task_button(get_node_or_null("TaskTabActive") as Button, Callable(self, "_select_task_tab").bind("active"), "tab_active")
	_wire_task_button(get_node_or_null("TaskTabAvailable") as Button, Callable(self, "_select_task_tab").bind("available"), "tab_available")
	_wire_task_button(get_node_or_null("TaskTabCompleted") as Button, Callable(self, "_select_task_tab").bind("completed"), "tab_completed")

	for index in range(_objective_hits.size()):
		_wire_task_button(_objective_hits[index], Callable(self, "_advance_visible_objective").bind(index), "objective_%d" % index)
	_wire_task_button(get_node_or_null("TaskTrackedHit") as Button, Callable(self, "_toggle_visible_tracking"), "tracked_header")
	_wire_task_button(get_node_or_null("TaskTrackToggle") as Button, Callable(self, "_toggle_visible_tracking"), "tracked_hud")
	_wire_task_button(get_node_or_null("TaskTurnIn") as Button, Callable(self, "_turn_in_visible"), "turn_in")
	_wire_task_button(get_node_or_null("TaskAbandon") as Button, Callable(self, "_abandon_visible"), "abandon")


func _bind_navigation_chrome() -> void:
	_navigation_chrome = get_node_or_null("NavigationChrome") as ZNavigationChrome
	if _navigation_chrome == null:
		push_error("Tasks scene is missing its NavigationChrome component")
		return
	_navigation_chrome.active_route = "tasks"
	var navigate := Callable(self, "_go")
	var insurance := Callable(self, "_tasks_insurance_notice")
	var back := Callable(self, "_tasks_back")
	if not _navigation_chrome.navigate_requested.is_connected(navigate):
		_navigation_chrome.navigate_requested.connect(navigate)
	if not _navigation_chrome.insurance_requested.is_connected(insurance):
		_navigation_chrome.insurance_requested.connect(insurance)
	if not _navigation_chrome.back_requested.is_connected(back):
		_navigation_chrome.back_requested.connect(back)
	mark_feature_action(_navigation_chrome.get_node_or_null("Insurance") as Control,
		FEATURE_INSURANCE)


func _wire_task_button(button: Button, callback: Callable, key: String) -> void:
	if button == null or not callback.is_valid() or bool(button.get_meta("tasks_action_bound_" + key, false)):
		return
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(callback)
	button.set_meta("tasks_action_bound_" + key, true)


func _bind_task_state() -> void:
	var tab := _task_tab()
	var selected_id := _selected_task_id(tab)
	_set_state("utility_task_selected", selected_id)
	if _compact_ready and get_node_or_null("TaskDetailsPane") != null:
		_bind_compact_task_state(tab, selected_id)
	else:
		_bind_desktop_task_state(tab, selected_id)


func _bind_desktop_task_state(tab: String, selected_id: String) -> void:
	var default_shape := tab == "active" and selected_id == "supply_run"
	if default_shape and not _desktop_shape_default:
		_restore_desktop_geometry()
	var preserve_default_shape := default_shape
	_bind_traders()
	_bind_desktop_task_list(tab, selected_id, preserve_default_shape)
	_bind_desktop_detail(selected_id, preserve_default_shape)
	_desktop_shape_default = default_shape


func _restore_desktop_geometry() -> void:
	for control in _authored_controls:
		if control is Control:
			_set_rect(control, _desktop_rect(control))


func _bind_traders() -> void:
	var selected_index := int(_state_value("utility_task_trader", 0))
	for index in range(TRADERS.size()):
		var trader: Dictionary = TRADERS[index]
		var selected := index == selected_index
		var card: Panel = _trader_cards[index]
		if card != null:
			card.add_theme_stylebox_override("panel", _style_box(Color(1, 1, 1, 0.06) if selected else C_DARK, C_TEXT if selected else C_LINE))
		var initial: Label = _trader_initials[index]
		if initial != null:
			initial.text = str(trader.get("initial", ""))
		var name_label: Label = _trader_names[index]
		if name_label != null:
			name_label.text = str(trader.get("name", ""))
		var sub_label: Label = _trader_subs[index]
		if sub_label != null:
			sub_label.text = str(trader.get("sub", ""))
		var count_text := str(trader.get("count", ""))
		var count_background: ColorRect = _trader_count_backgrounds[index]
		var count_label: Label = _trader_counts[index]
		var has_count := not count_text.is_empty()
		if count_background != null:
			count_background.visible = has_count
		if count_label != null:
			count_label.visible = has_count
			count_label.text = count_text


func _bind_desktop_task_list(tab: String, selected_id: String, preserve_default_shape: bool = false) -> void:
	var tab_values := [["ACTIVE", "active", "3"], ["AVAILABLE", "available", "4"], ["COMPLETED", "completed", "12"]]
	var tab_buttons := [get_node_or_null("TaskTabActive") as Button, get_node_or_null("TaskTabAvailable") as Button, get_node_or_null("TaskTabCompleted") as Button]
	for index in range(tab_buttons.size()):
		var button: Button = tab_buttons[index]
		if button == null:
			continue
		var item: Array = tab_values[index]
		var active: bool = tab == str(item[1])
		button.text = str(item[0]) + "  " + str(item[2])
		button.add_theme_color_override("font_color", C_TEXT if active else C_MUTED)
		button.add_theme_stylebox_override("normal", _style_box(Color(0, 0, 0, 0), C_TEXT if active else Color(0, 0, 0, 0), 0 if not active else 1))
		button.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.04), C_TEXT, 1))

	_task_ids.clear()
	var records := _task_list_for_tab(tab)
	var y := 174.0
	for index in range(_task_cards.size()):
		var visible_row := index < records.size()
		_task_ids.append(str(records[index].get("id", "")) if visible_row else "")
		var task: Dictionary = records[index] if visible_row else {}
		_bind_task_card(index, task, y, visible_row, preserve_default_shape)
		if visible_row:
			y += 136.0 if str(task.get("status", "")) == "active" else 104.0


func _bind_task_card(index: int, task: Dictionary, y: float, visible_row: bool, preserve_default_shape: bool = false) -> void:
	var card: Panel = _task_cards[index]
	var hit: Button = _task_hits[index]
	var name_label: Label = _task_names[index]
	var tag_label: Label = _task_tags[index]
	var meta_label: Label = _task_meta[index]
	var progress_track: ColorRect = _task_progress_tracks[index]
	var progress_fill: ColorRect = _task_progress_fills[index]
	var progress_value: Label = _task_progress_values[index]
	var reward_label: Label = _task_rewards[index]
	var controls: Array = [card, hit, name_label, tag_label, meta_label, progress_track, progress_fill, progress_value, reward_label]
	for control in controls:
		if control != null:
			control.visible = visible_row
	if not visible_row:
		return

	var status := str(task.get("status", ""))
	var active := status == "active"
	var card_height := 118.0 if active else 86.0
	var selected := str(task.get("id", "")) == str(_state_value("utility_task_selected", ""))
	if not preserve_default_shape:
		_set_rect(card, Rect2(408, y, 640, card_height))
		_set_rect(hit, Rect2(408, y, 640, card_height))
		_set_rect(name_label, Rect2(424, y + 14, 320, 20))
		_set_rect(tag_label, Rect2(850, y + 14, 180, 18))
		_set_rect(meta_label, Rect2(424, y + 40, 560, 16))
		_set_rect(progress_track, Rect2(424, y + 70, 560, 3))
		_set_rect(progress_fill, Rect2(424, y + 70, 0, 3))
		_set_rect(progress_value, Rect2(992, y + 64, 38, 18))
		_set_rect(reward_label, Rect2(424, y + (92 if active else 60), 560, 16))
	if card != null:
		card.add_theme_stylebox_override("panel", _style_box(Color(1, 1, 1, 0.06) if selected else C_DARK, C_TEXT if selected else C_LINE))
	if name_label != null:
		name_label.text = str(task.get("list_title", ""))
	if tag_label != null:
		var tag := str(task.get("tag", ""))
		tag_label.text = tag
		tag_label.visible = not tag.is_empty()
		tag_label.add_theme_color_override("font_color", _task_tag_color(task))
		tag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tag_label.clip_text = true
	if meta_label != null:
		meta_label.text = str(task.get("trader", "")) + "   ·   " + str(task.get("zone", ""))
	if reward_label != null:
		reward_label.text = str(task.get("xp", "")) + " XP    " + str(task.get("cash", "")) + "    " + str(task.get("item", ""))
	if progress_track != null:
		progress_track.visible = active
		progress_track.color = C_SUBTLE
	if progress_fill != null:
		progress_fill.visible = active
		progress_fill.color = C_TEXT
	if progress_value != null:
		progress_value.visible = active
	if active:
		var objectives: Array = task.get("objectives", [])
		var done := 0
		var total := 0
		for objective_index in range(objectives.size()):
			var objective: Dictionary = objectives[objective_index]
			done += _task_progress(str(task.get("id", "")), objective_index, task)
			total += int(objective.get("target", 1))
		var amount: float = 0.0 if total <= 0 else float(done) / float(total)
		if preserve_default_shape:
			progress_fill.size.x = 560.0 * amount
		else:
			_set_rect(progress_fill, Rect2(424, y + 70, 560.0 * amount, 3))
		if progress_value != null:
			progress_value.text = str(done) + " / " + str(total)
			progress_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _bind_desktop_detail(selected_id: String, preserve_default_shape: bool = false) -> void:
	var task := _task_record(selected_id)
	var has_task := not task.is_empty()
	for node in _detail_nodes:
		if node is Control:
			(node as Control).visible = has_task
	if not has_task:
		return

	var merchant_panel := _find_static("TaskMerchantPanel") as Panel
	var merchant_image := _find_static("TaskMerchantImage") as TextureRect
	var rep_label := _find_static("TaskTraderRep") as Label
	var title_label := _find_static("TaskDetailTitle") as Label
	var zone_label := _find_static("TaskDetailZone") as Label
	var tracked_panel := _find_static("TaskTrackedPanel") as Panel
	var tracked_label := _find_static("TaskTrackedLabel") as Label
	var tracked_hit := _find_static("TaskTrackedHit") as Button
	var detail_rule := _find_static("TaskDetailRule") as ColorRect
	var description := _find_static("TaskDescription") as Label
	var objectives_title := _find_static("TaskObjectivesTitle") as Label
	if not preserve_default_shape:
		if merchant_panel != null: _set_rect(merchant_panel, Rect2(1088, 94, 64, 64))
		if merchant_image != null: _set_rect(merchant_image, Rect2(1089, 95, 62, 62))
	if rep_label != null:
		if not preserve_default_shape: _set_rect(rep_label, Rect2(1168, 90, 300, 18))
		rep_label.text = str(task.get("trader", "")) + " · REP " + str(task.get("rep", ""))
	if title_label != null:
		if not preserve_default_shape: _set_rect(title_label, Rect2(1168, 108, 680, 30))
		title_label.text = str(task.get("title", ""))
	if zone_label != null:
		if not preserve_default_shape: _set_rect(zone_label, Rect2(1168, 140, 96, 22))
		zone_label.text = str(task.get("zone", ""))
	var tracked := str(_state_value("hud_tracked_task_id", "supply_run")) == selected_id
	if tracked_panel != null:
		if not preserve_default_shape: _set_rect(tracked_panel, Rect2(1270, 140, 66, 22))
		tracked_panel.add_theme_stylebox_override("panel", _style_box(Color(0, 0, 0, 0), C_ACCENT if tracked else C_LINE))
	if tracked_label != null:
		if not preserve_default_shape: _set_rect(tracked_label, Rect2(1274, 141, 58, 20))
		tracked_label.text = "TRACKED" if tracked else "TRACK"
		tracked_label.add_theme_color_override("font_color", C_ACCENT if tracked else C_MUTED)
		tracked_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if tracked_hit != null and not preserve_default_shape: _set_rect(tracked_hit, Rect2(1270, 140, 66, 22))
	if detail_rule != null and not preserve_default_shape: _set_rect(detail_rule, Rect2(1088, 176, 784, 1))
	if description != null:
		if not preserve_default_shape: _set_rect(description, Rect2(1088, 194, 784, 62))
		description.text = "\"" + str(task.get("description", "")) + "\""
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		description.clip_text = true
	if objectives_title != null:
		if not preserve_default_shape: _set_rect(objectives_title, Rect2(1088, 268, 784, 18))

	var objectives: Array = task.get("objectives", [])
	for index in range(_objective_hits.size()):
		var visible_row := index < objectives.size()
		var objective: Dictionary = objectives[index] if visible_row else {}
		_bind_objective_row(index, task, objective, visible_row, 292.0 + index * 42.0, preserve_default_shape)

	_bind_rewards_and_actions(task, objectives.size(), false, preserve_default_shape)


func _bind_objective_row(index: int, task: Dictionary, objective: Dictionary, visible_row: bool, y: float, preserve_default_shape: bool = false) -> void:
	var nodes: Array = [_objective_hits[index], _objective_rules[index], _objective_boxes[index], _objective_box_tops[index], _objective_box_bottoms[index], _objective_box_lefts[index], _objective_box_rights[index], _objective_checks[index], _objective_texts[index], _objective_values[index]]
	for node in nodes:
		if node is Control:
			(node as Control).visible = visible_row
	if not visible_row:
		return
	if not preserve_default_shape:
		_set_rect(_objective_hits[index], Rect2(1088, y, 784, 34))
		_set_rect(_objective_rules[index], Rect2(1088, y + 33, 784, 1))
		_set_rect(_objective_boxes[index], Rect2(1088, y + 9, 15, 15))
		_set_rect(_objective_box_tops[index], Rect2(1088, y + 9, 15, 1))
		_set_rect(_objective_box_bottoms[index], Rect2(1088, y + 23, 15, 1))
		_set_rect(_objective_box_lefts[index], Rect2(1088, y + 9, 1, 15))
		_set_rect(_objective_box_rights[index], Rect2(1102, y + 9, 1, 15))
		_set_rect(_objective_checks[index], Rect2(1088, y + 5, 15, 20))
		_set_rect(_objective_texts[index], Rect2(1118, y + 5, 620, 22))
		_set_rect(_objective_values[index], Rect2(1780, y + 5, 78, 22))
	var current := _task_progress(str(task.get("id", "")), index, task)
	var target := int(objective.get("target", 1))
	var complete := current >= target
	var box_color := C_GREEN if complete else C_LINE
	if _objective_boxes[index] != null:
		_objective_boxes[index].color = box_color if complete else Color(0, 0, 0, 0)
	if _objective_box_tops[index] != null: _objective_box_tops[index].color = box_color
	if _objective_box_bottoms[index] != null: _objective_box_bottoms[index].color = box_color
	if _objective_box_lefts[index] != null: _objective_box_lefts[index].color = box_color
	if _objective_box_rights[index] != null: _objective_box_rights[index].color = box_color
	if _objective_checks[index] != null:
		_objective_checks[index].visible = complete
		_objective_checks[index].text = "✓"
		_objective_checks[index].add_theme_color_override("font_color", C_BG)
	if _objective_texts[index] != null:
		_objective_texts[index].text = str(objective.get("text", ""))
		_objective_texts[index].add_theme_color_override("font_color", C_MUTED if complete else C_TEXT)
	if _objective_values[index] != null:
		_objective_values[index].text = str(current) + " / " + str(target)
		_objective_values[index].add_theme_color_override("font_color", C_MUTED if complete else C_SOFT)


func _bind_rewards_and_actions(task: Dictionary, objective_count: int, compact: bool, preserve_default_shape: bool = false) -> void:
	var reward_title_y := 292.0 + objective_count * 42.0 + 16.0
	var cards_y := reward_title_y + 26.0
	var track_y := cards_y + 72.0
	var rewards_title := _find_static("TaskRewardsTitle") as Label
	if rewards_title != null and not preserve_default_shape:
		_set_rect(rewards_title, Rect2(1088, reward_title_y, 784, 18))
	var reward_specs := [
		["XP", str(task.get("xp", "")), Rect2(1088, cards_y, 188, 56), C_TEXT, "XP"],
		["CASH", str(task.get("cash", "")), Rect2(1278, cards_y, 188, 56), C_ACCENT, "Cash"],
		["ITEM", str(task.get("item", "")), Rect2(1468, cards_y, 188, 56), C_TEXT, "Item"],
		["REP", str(task.get("reward_rep", "")), Rect2(1658, cards_y, 214, 56), C_TEXT, "Rep"]
	]
	for spec in reward_specs:
		var key := str(spec[4])
		var panel := _find_static("TaskRewardPanel" + key) as Panel
		var label := _find_static("TaskRewardLabel" + key) as Label
		var value := _find_static("TaskRewardValue" + key) as Label
		var rect: Rect2 = spec[2]
		if panel != null:
			if not preserve_default_shape: _set_rect(panel, rect)
			panel.visible = true
		if label != null:
			if not preserve_default_shape: _set_rect(label, Rect2(rect.position + Vector2(12, 8), Vector2(rect.size.x - 24, 14)))
			label.text = str(spec[0])
			label.visible = true
		if value != null:
			if not preserve_default_shape: _set_rect(value, Rect2(rect.position + Vector2(12, 27), Vector2(rect.size.x - 24, 20)))
			value.text = str(spec[1])
			value.add_theme_color_override("font_color", spec[3])
			value.visible = true

	var track_panel := _find_static("TaskTrackPanel") as Panel
	var track_title := _find_static("TaskTrackTitle") as Label
	var track_subtitle := _find_static("TaskTrackSubtitle") as Label
	var track_toggle := _find_static("TaskTrackToggle") as Button
	var track_fill := _find_static("TaskTrackFill") as ColorRect
	if track_panel != null and not preserve_default_shape:
		_set_rect(track_panel, Rect2(1088, track_y, 784, 56))
	if track_title != null and not preserve_default_shape:
		_set_rect(track_title, Rect2(1102, track_y + 10, 220, 18))
	if track_subtitle != null and not preserve_default_shape:
		_set_rect(track_subtitle, Rect2(1102, track_y + 30, 560, 14))
	if track_toggle != null:
		if not preserve_default_shape: _set_rect(track_toggle, Rect2(1818, track_y + 19, 36, 18))
		var tracked := str(_state_value("hud_tracked_task_id", "supply_run")) == str(task.get("id", ""))
		track_toggle.add_theme_stylebox_override("normal", _style_box(Color(0, 0, 0, 0), C_TEXT if tracked else C_LINE, 1))
		track_toggle.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.04), C_HOVER, 1))
	if track_fill != null:
		if not preserve_default_shape: _set_rect(track_fill, Rect2(1838, track_y + 22, 14, 12))
		track_fill.visible = str(_state_value("hud_tracked_task_id", "supply_run")) == str(task.get("id", ""))

	var turned_in: bool = bool(_dictionary_state("utility_tasks_completed").get(str(task.get("id", "")), false))
	var complete := _task_complete(task)
	var turn := _find_static("TaskTurnIn") as Button
	if turn != null:
		if not preserve_default_shape: _set_rect(turn, Rect2(1088, 985, 656, 47))
		turn.text = "TURNED IN" if turned_in else ("TURN IN · READY" if complete else "TURN IN · OBJECTIVES INCOMPLETE")
		turn.disabled = turned_in or not complete
		turn.add_theme_color_override("font_color", C_GREEN if complete else C_MUTED)
		turn.add_theme_stylebox_override("normal", _style_box(Color(0, 0, 0, 0), C_GREEN if complete else C_LINE, 1))
	var abandon := _find_static("TaskAbandon") as Button
	if abandon != null:
		if not preserve_default_shape: _set_rect(abandon, Rect2(1755, 985, 117, 47))
		abandon.text = "ABANDON"

	if compact:
		_apply_compact_detail_layout(objective_count, reward_title_y, cards_y, track_y)


func _set_rect(control: Control, rect: Rect2) -> void:
	if control == null:
		return
	control.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	control.position = rect.position
	control.size = rect.size


func _compact_base_rect(control: Control) -> Rect2:
	var rect := _desktop_rect(control)
	return Rect2(rect.position - Vector2(1088, 90), rect.size)


func _apply_compact_detail_layout(objective_count: int, reward_title_y: float, cards_y: float, track_y: float) -> void:
	var pane := get_node_or_null("TaskDetailsPane") as ScrollContainer
	if pane == null or pane.get_child_count() == 0:
		return
	var detail := pane.get_child(0) as Control
	if detail == null:
		return
	var inner := _compact_view.x - 384.0
	var source_origin := Vector2(1088, 90)
	var detail_nodes := _detail_nodes.duplicate()
	var reward_y := cards_y - source_origin.y
	for node_variant in detail_nodes:
		if not node_variant is Control:
			continue
		var node: Control = node_variant
		var base := _desktop_rect(node)
		var local := Rect2(base.position - source_origin, base.size)
		_set_rect(node, local)
		var px: float = local.position.x
		var py: float = local.position.y
		if py >= reward_y and py < reward_y + 56:
			var column := mini(3, int(px / 190.0))
			var cell_width := (inner - 8.0) / 2.0
			node.position.x = (column % 2) * (cell_width + 8.0) + fmod(px, 190.0)
			node.position.y += 64.0 if column >= 2 else 0.0
			node.size.x = cell_width - (24.0 if node is Label else 0.0)
			continue
		if py >= reward_y + 72.0:
			node.position.y += 64.0
		if px >= 650.0:
			node.position.x += inner - 784.0
		elif node is Label or node is Panel or node is Button or node is ColorRect:
			node.size.x = minf(node.size.x, inner - px)
		if node is Label and is_equal_approx(px, 30.0):
			node.size.x = inner - 130.0
	preload("res://ui/screens/utilities/components/utility_layout.gd").fit_labels(detail, inner)
	if pane.get_parent() != null:
		pane.get_parent().visible = true


func _bind_compact_task_state(tab: String, selected_id: String) -> void:
	_bind_traders()
	_sync_compact_picker(tab)
	_rebuild_compact_task_list(tab, selected_id)
	_bind_compact_detail(selected_id)
	_sync_compact_actions()


func _sync_compact_picker(tab: String) -> void:
	var picker: OptionButton = null
	for child in get_children():
		if child is OptionButton:
			picker = child
			break
	if picker != null:
		picker.name = "TaskTraderPicker"
		picker.select(int(_state_value("utility_task_trader", 0)))
	var values := ["active", "available", "completed"]
	for child in get_children():
		if not child is Button:
			continue
		var button: Button = child
		if button.position.y < 119 or button.position.y > 153:
			continue
		var value := button.text.to_lower()
		if value == "active" or value == "available" or value == "completed":
			button.add_theme_color_override("font_color", C_ACCENT if value == tab else C_TEXT)
			button.add_theme_stylebox_override("normal", _style_box(Color(1, 1, 1, 0.06), C_TEXT) if value == tab else _style_box(C_DARK, C_LINE))


func _rebuild_compact_task_list(tab: String, selected_id: String) -> void:
	var pane := get_node_or_null("TasksListPane") as ScrollContainer
	if pane == null or pane.get_child_count() == 0:
		return
	var content := pane.get_child(0) as Control
	if content == null:
		return
	var previous_scroll := pane.scroll_vertical
	for child in content.get_children():
		content.remove_child(child)
		child.queue_free()
	var records := _task_list_for_tab(tab)
	var y := 0.0
	for record_variant in records:
		var record: Dictionary = record_variant
		var hit := _button(content, "", Rect2(0, y, 304, 112), Callable(self, "_select_task").bind(str(record.get("id", ""))))
		if str(record.get("id", "")) == selected_id:
			hit.add_theme_stylebox_override("normal", _style_box(Color(1, 1, 1, 0.06), C_TEXT))
		_label(content, str(record.get("list_title", "")), Rect2(12, y + 10, 280, 22), 14)
		_label(content, str(record.get("trader", "")) + " · " + str(record.get("zone", "")), Rect2(12, y + 38, 280, 18), 10, C_MUTED, true)
		_label(content, str(record.get("tag", "")), Rect2(12, y + 64, 280, 18), 10, _task_tag_color(record))
		_label(content, str(record.get("xp", "")) + " XP · " + str(record.get("cash", "")), Rect2(12, y + 86, 280, 18), 11, C_SOFT, true)
		y += 124.0
	if records.is_empty():
		_label(content, "No tasks in this tab", Rect2(12, 16, 280, 24), 13, C_MUTED)
		y = 72.0
	_panel(content, Rect2(0, y, 304, 80), C_DARK, C_LINE)
	_label(content, "DAILY · RESETS 14:22:08", Rect2(12, y + 10, 280, 18), 10, C_MUTED)
	_label(content, "Extract twice · 1 / 2", Rect2(12, y + 36, 280, 22), 12)
	_solid(content, Rect2(12, y + 64, 280, 3), C_SUBTLE)
	_solid(content, Rect2(12, y + 64, 140, 3), C_TEXT)
	content.custom_minimum_size.y = y + 88
	preload("res://ui/screens/utilities/components/utility_layout.gd").fit_labels(content, 304)
	pane.scroll_vertical = previous_scroll
	call_deferred("_restore_compact_scroll")


func _bind_compact_detail(selected_id: String) -> void:
	var task := _task_record(selected_id)
	var has_task := not task.is_empty()
	for node in _detail_nodes:
		if node is Control:
			(node as Control).visible = has_task
	if not has_task:
		return

	var rep_label := _find_static("TaskTraderRep") as Label
	var title_label := _find_static("TaskDetailTitle") as Label
	var zone_label := _find_static("TaskDetailZone") as Label
	var tracked_panel := _find_static("TaskTrackedPanel") as Panel
	var tracked_label := _find_static("TaskTrackedLabel") as Label
	var description := _find_static("TaskDescription") as Label
	var tracked := str(_state_value("hud_tracked_task_id", "supply_run")) == selected_id
	if rep_label != null: rep_label.text = str(task.get("trader", "")) + " · REP " + str(task.get("rep", ""))
	if title_label != null: title_label.text = str(task.get("title", ""))
	if zone_label != null: zone_label.text = str(task.get("zone", ""))
	if tracked_panel != null:
		tracked_panel.add_theme_stylebox_override("panel", _style_box(Color(0, 0, 0, 0), C_ACCENT if tracked else C_LINE))
	if tracked_label != null:
		tracked_label.text = "TRACKED" if tracked else "TRACK"
		tracked_label.add_theme_color_override("font_color", C_ACCENT if tracked else C_MUTED)
	if description != null: description.text = "\"" + str(task.get("description", "")) + "\""
	var objectives: Array = task.get("objectives", [])
	for index in range(_objective_hits.size()):
		_bind_objective_row(index, task, objectives[index] if index < objectives.size() else {}, index < objectives.size(), 292.0 + index * 42.0)
	_bind_rewards_and_actions(task, objectives.size(), true)


func _sync_compact_actions() -> void:
	if _compact_view == Vector2.ZERO:
		return
	var actions := [get_node_or_null("TaskTurnIn") as Button, get_node_or_null("TaskAbandon") as Button]
	var target_width := _compact_view.x - 352.0 - 16.0
	var total := 773.0
	var cursor := 352.0
	for action in actions:
		if action == null:
			continue
		var original_width := 656.0 if action.name == "TaskTurnIn" else 117.0
		var width := (target_width - 8.0) * original_width / total
		_set_rect(action, Rect2(cursor, _compact_view.y - 80.0, width, 48.0))
		action.add_theme_font_size_override("font_size", 11)
		cursor += width + 8.0


func _build_focus_graph() -> void:
	_link_vertical(_trader_hits)
	_link_vertical(_task_hits)
	_link_vertical(_objective_hits)
	_link_horizontal([get_node_or_null("TaskTabActive") as Button, get_node_or_null("TaskTabAvailable") as Button, get_node_or_null("TaskTabCompleted") as Button])


func _link_vertical(buttons: Array) -> void:
	var valid: Array = []
	for button_variant in buttons:
		if button_variant is Button:
			valid.append(button_variant)
	for index in range(valid.size()):
		var button: Button = valid[index]
		var previous: Button = valid[posmod(index - 1, valid.size())]
		var next: Button = valid[(index + 1) % valid.size()]
		button.focus_neighbor_top = button.get_path_to(previous)
		button.focus_neighbor_bottom = button.get_path_to(next)


func _link_horizontal(buttons: Array) -> void:
	var valid: Array = []
	for button_variant in buttons:
		if button_variant is Button:
			valid.append(button_variant)
	for index in range(valid.size()):
		var button: Button = valid[index]
		var previous: Button = valid[posmod(index - 1, valid.size())]
		var next: Button = valid[(index + 1) % valid.size()]
		button.focus_neighbor_left = button.get_path_to(previous)
		button.focus_neighbor_right = button.get_path_to(next)


func _select_static_task(index: int) -> void:
	if index >= 0 and index < _task_ids.size() and not str(_task_ids[index]).is_empty():
		_select_task(str(_task_ids[index]))


func _advance_visible_objective(index: int) -> void:
	var selected_id := str(_state_value("utility_task_selected", ""))
	if not selected_id.is_empty():
		_advance_objective(selected_id, index)


func _toggle_visible_tracking() -> void:
	var selected_id := str(_state_value("utility_task_selected", ""))
	if not selected_id.is_empty():
		_toggle_task_tracking(selected_id)


func _turn_in_visible() -> void:
	var selected_id := str(_state_value("utility_task_selected", ""))
	if not selected_id.is_empty():
		_turn_in_task(selected_id)


func _abandon_visible() -> void:
	var selected_id := str(_state_value("utility_task_selected", ""))
	if not selected_id.is_empty():
		_abandon_task(selected_id)


func _tasks_insurance_notice() -> void:
	notify_feature_action(FEATURE_INSURANCE)


func _tasks_back() -> void:
	if app != null:
		app.back()


func layout_compact(view: Vector2) -> void:
	_compact_view = view
	_compact_ready = true
	super.layout_compact(view)
	var picker := get_node_or_null("TaskTraderPicker") as OptionButton
	if picker == null:
		for child in get_children():
			if child is OptionButton:
				child.name = "TaskTraderPicker"
				break
	_bind_task_state()


func _rerender() -> void:
	# Keep the authored controls and compact panes alive so focus, selection and
	# scroll offsets survive every task state transition.
	_bind_task_state()
