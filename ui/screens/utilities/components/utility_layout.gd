extends RefCounted
const ZAdaptive = preload("res://ui/core/adaptive.gd")

var screen: Control

func _init(owner_screen: Control) -> void:
	screen = owner_screen

func apply(view: Vector2) -> void:
	if screen.route == "crosshairs":
		var content = ZAdaptive.pane(screen, Rect2((view.x - 816) / 2, 80, 816, view.y - 104), Vector2(800, 520), "CrosshairPane")
		ZAdaptive.move_group(screen, "CrosshairPane", Vector2(550, 240), content)
		for child in content.get_children():
			child.position += Vector2(-10, -4)
		return
	if screen.route == "settings":
		_compact_settings(view)
	elif screen.route == "controls":
		_compact_controls(view)
	elif screen.route == "maps":
		_compact_maps(view)
	elif screen.route == "tasks":
		_compact_tasks(view)
	screen.call_deferred("_restore_compact_scroll")


func _compact_tabs(values: Array, key: String, selected: String, bounds: Rect2) -> void:
	var width: float = bounds.size.x / values.size()
	for index in range(values.size()):
		var value: String = str(values[index])
		var button = screen._button(screen, value, Rect2(bounds.position + Vector2(index * width, 0), Vector2(width, bounds.size.y)), Callable(screen, "_compact_tab").bind(key, value))
		button.add_theme_font_size_override("font_size", 11)
		if selected == value:
			button.add_theme_stylebox_override("normal", screen._style_box(Color(1, 1, 1, 0.06), screen.C_TEXT))


func _compact_region(bounds: Rect2, target: Rect2, content_size: Vector2, pane_name: String) -> Control:
	var content = ZAdaptive.pane(screen, target, content_size, pane_name)
	content.get_parent().horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	ZAdaptive.move_group(screen, pane_name, bounds.position, content)
	return content


static func fit_labels(content: Control, width: float) -> void:
	for node in content.get_children():
		if node is Label:
			node.clip_text = true
			node.size.x = maxf(8, minf(node.size.x, width - node.position.x))
			node.tooltip_text = node.text


func _compact_prepare_labels(content: Control) -> void:
	# Clear Label's text minimum before resizing, but retain its original width
	# until right-aligned values have moved into the compact column.
	for node in content.get_children():
		if node is Label:
			node.clip_text = true


func _compact_sidebar(view: Vector2) -> void:
	var side = _compact_region(Rect2(48, 92, 280, 950), Rect2(16, 80, 200, view.y - 112), Vector2(184, 730), "UtilitySidebar")
	_compact_prepare_labels(side)
	for node in side.get_children():
		if node.position.y > 850:
			node.position.y -= 460 if screen.route == "settings" else 190
		node.size.x = maxf(8, minf(node.size.x, 184 - node.position.x))
		if node.position.x > 130:
			node.position.x -= 94
		if node is Button and node.position.y == 386:
			node.position.x = 14 if node.text == "KB + MOUSE" else 97
			node.size.x = 83
	fit_labels(side, 184)
	var bottom := 0.0
	for node in side.get_children():
		bottom = maxf(bottom, node.position.y + node.size.y)
	side.custom_minimum_size.y = bottom + 8


func _compact_settings(view: Vector2) -> void:
	_compact_sidebar(view)
	var x := 232.0
	var width := view.x - x - 16
	var selected := str(screen._state_value("utility_compact_settings", "OPTIONS"))
	var options = _compact_region(Rect2(368, 92, 984, 880), Rect2(x, 128, width, view.y - 224), Vector2(width - 16, 850), "SettingsOptions")
	var inner := width - 16
	_compact_prepare_labels(options)
	for node in options.get_children():
		var px: float = node.position.x
		if px >= 670:
			node.position.x += inner - 984
		elif node is Label and node.position.y < 34 and px > 0:
			node.position.x = 180
			node.size.x = inner - 180
		elif node is Label:
			node.size.x = minf(node.size.x, inner - 328 - px)
			if px == 0 and node.text.length() > 45 and node.get_theme_font_size("font_size") == 10:
				node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				node.vertical_alignment = VERTICAL_ALIGNMENT_TOP
				node.add_theme_constant_override("line_spacing", -2)
				node.size.y = 30
		elif node is ColorRect:
			node.size.x = maxf(1, inner - px)
	fit_labels(options, inner)
	var preview = _compact_region(Rect2(1392, 92, 480, 880), Rect2(x, 128, width, view.y - 224), Vector2(width - 16, 854), "SettingsPreview")
	for node in preview.get_children():
		node.position.x += maxf(0, (inner - 480) / 2)
	preview.get_parent().visible = selected == "PREVIEW"
	options.get_parent().visible = selected == "OPTIONS"
	_compact_tabs(["OPTIONS", "PREVIEW"], "utility_compact_settings", selected, Rect2(x, 80, width, 32))
	_compact_actions(Rect2(1392, 980, 480, 60), Rect2(x, view.y - 80, width, 48))


func _compact_actions(source: Rect2, target: Rect2) -> void:
	var actions: Array = []
	for node in screen.get_children():
		if node is Button and source.has_point(node.position):
			actions.append(node)
	var total := 0.0
	for node in actions:
		total += node.size.x
	var cursor := target.position.x
	for node in actions:
		var width: float = (target.size.x - maxf(0, actions.size() - 1) * 8) * node.size.x / maxf(total, 1)
		node.position = Vector2(cursor, target.position.y)
		node.size = Vector2(width, target.size.y)
		node.add_theme_font_size_override("font_size", 11)
		cursor += width + 8


func _compact_controls(view: Vector2) -> void:
	_compact_sidebar(view)
	var x := 232.0
	var width := view.x - x - 16
	var selected := str(screen._state_value("utility_compact_controls", "BINDINGS"))
	for node in screen.get_children():
		if node is ScrollContainer and node.position.x == 368:
			node.name = "BindingsPane"
			node.position = Vector2(x, 128)
			node.size = Vector2(width, view.y - 224)
			node.follow_focus = true
			node.visible = selected == "BINDINGS"
			var body: Control = node.get_child(0)
			var inner := width - 16
			body.custom_minimum_size.x = inner
			body.size.x = inner
			_compact_prepare_labels(body)
			for item in body.get_children():
				if item.position.x >= 590:
					item.position.x += inner - 930
				elif item is Label and item.position.y < 34 and item.position.x > 0:
					item.position.x = 160
					item.size.x = inner - 160
				elif item is Label:
					item.size.x = minf(item.size.x, inner - 352)
				elif item is ColorRect or item is Panel:
					item.size.x = inner
			fit_labels(body, inner)
			node.size = Vector2(width, view.y - 224)
	var detail = _compact_region(Rect2(1392, 92, 480, 880), Rect2(x, 128, width, view.y - 224), Vector2(width - 16, 730), "ControllerPane")
	if screen._conflict_pairs().is_empty():
		for node in detail.get_children():
			if node.position.y >= 190:
				node.position.y -= 144
		detail.custom_minimum_size.y -= 144
	detail.get_parent().visible = selected == "CONTROLLER / CONFLICTS"
	_compact_tabs(["BINDINGS", "CONTROLLER / CONFLICTS"], "utility_compact_controls", selected, Rect2(x, 80, width, 32))
	_compact_actions(Rect2(1392, 980, 480, 60), Rect2(x, view.y - 80, width, 48))


func _compact_maps(view: Vector2) -> void:
	var left_width := 320.0
	var zones = _compact_region(Rect2(48, 92, 400, 960), Rect2(16, 80, left_width, view.y - 112), Vector2(left_width - 16, 580), "ZonesPane")
	for node in zones.get_children():
		if node.position.y > 800:
			node.position.y -= 430
		if node.position.x >= 300:
			node.position.x -= 96
		else:
			node.size.x = minf(node.size.x, left_width - 16 - node.position.x)
		if node is Label and node.position.x == 16:
			node.size.x = 204
	fit_labels(zones, left_width - 16)
	var x := 352.0
	var width := view.x - x - 16
	var selected := str(screen._state_value("utility_compact_maps", "ZONE DETAILS"))
	var detail = _compact_region(Rect2(1392, 92, 480, 880), Rect2(x, 128, width, view.y - 224), Vector2(width - 16, 880), "ZoneDetailsPane")
	var ratio := (width - 16) / 480
	for node in detail.get_children():
		node.position.x *= ratio
		node.size.x *= ratio
		if node is Panel and node.clip_contents:
			for child in node.get_children():
				if child is ColorRect:
					child.size.x = node.size.x
	detail.get_parent().visible = selected == "ZONE DETAILS"
	var map_content = _compact_region(Rect2(488, 92, 864, 980), Rect2(x, 128, width, view.y - 224), Vector2(880, 1000), "RegionMapPane")
	map_content.get_parent().horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	map_content.get_parent().visible = selected == "REGION MAP"
	_compact_tabs(["ZONE DETAILS", "REGION MAP"], "utility_compact_maps", selected, Rect2(x, 80, width, 32))
	_compact_actions(Rect2(1392, 972, 480, 64), Rect2(x, view.y - 80, width, 48))


func _compact_tasks(view: Vector2) -> void:
	# Trader filtering and status stay fixed above a scrollable list.
	for node in screen.get_children():
		if node is Control and node.position.x >= 48 and node.position.x < 1088 and node.position.y >= 90:
			node.hide()
	var trader := OptionButton.new()
	trader.position = Vector2(16, 80)
	trader.size = Vector2(320, 32)
	trader.add_theme_font_size_override("font_size", 12)
	for record in screen.TRADERS:
		trader.add_item(str(record.name))
		trader.get_popup().set_item_tooltip(trader.item_count - 1, str(record.sub))
	trader.select(int(screen._state_value("utility_task_trader", 0)))
	trader.item_selected.connect(Callable(screen, "_select_trader"))
	screen.add_child(trader)
	var list = ZAdaptive.pane(screen, Rect2(16, 160, 320, view.y - 192), Vector2(304, 620), "TasksListPane")
	var tab: String = screen._task_tab()
	var records: Array = screen._task_list_for_tab(tab)
	var tabs := ["active", "available", "completed"]
	for index in range(tabs.size()):
		var button = screen._button(screen, tabs[index].to_upper(), Rect2(16 + index * 107, 120, 106, 32), Callable(screen, "_select_task_tab").bind(tabs[index]))
		button.add_theme_font_size_override("font_size", 10)
		if tabs[index] == tab:
			button.add_theme_color_override("font_color", screen.C_ACCENT)
	var y := 0.0
	for record in records:
		var hit = screen._button(list, "", Rect2(0, y, 304, 112), Callable(screen, "_select_task").bind(str(record.id)))
		if str(record.id) == str(screen._state_value("utility_task_selected", "")):
			hit.add_theme_stylebox_override("normal", screen._style_box(Color(1, 1, 1, 0.06), screen.C_TEXT))
		screen._label(list, str(record.list_title), Rect2(12, y + 10, 280, 22), 14)
		screen._label(list, str(record.trader) + " · " + str(record.zone), Rect2(12, y + 38, 280, 18), 10, screen.C_MUTED, true)
		screen._label(list, str(record.tag), Rect2(12, y + 64, 280, 18), 10, screen._task_tag_color(record))
		screen._label(list, str(record.xp) + " XP · " + str(record.cash), Rect2(12, y + 86, 280, 18), 11, screen.C_SOFT, true)
		y += 124
	if records.is_empty():
		screen._label(list, "No tasks in this tab", Rect2(12, 16, 280, 24), 13, screen.C_MUTED)
		y = 72
	screen._panel(list, Rect2(0, y, 304, 80), screen.C_DARK, screen.C_LINE)
	screen._label(list, "DAILY · RESETS 14:22:08", Rect2(12, y + 10, 280, 18), 10, screen.C_MUTED)
	screen._label(list, "Extract twice · 1 / 2", Rect2(12, y + 36, 280, 22), 12)
	screen._solid(list, Rect2(12, y + 64, 280, 3), screen.C_SUBTLE)
	screen._solid(list, Rect2(12, y + 64, 140, 3), screen.C_TEXT)
	list.custom_minimum_size.y = y + 88
	fit_labels(list, 304)
	var x := 352.0
	var width := view.x - x - 16
	var detail = _compact_region(Rect2(1088, 90, 784, 880), Rect2(x, 80, width, view.y - 176), Vector2(width - 16, 780), "TaskDetailsPane")
	var inner := width - 16
	_compact_prepare_labels(detail)
	var reward_y := -1.0
	for node in detail.get_children():
		if node is Label and node.text == "REWARDS":
			reward_y = node.position.y + 26
	for node in detail.get_children():
		var px: float = node.position.x
		var py: float = node.position.y
		if reward_y >= 0 and py >= reward_y and py < reward_y + 56:
			var column := mini(3, int(px / 190))
			var cell_width := (inner - 8) / 2
			node.position.x = (column % 2) * (cell_width + 8) + fmod(px, 190)
			node.position.y += 64 if column >= 2 else 0
			node.size.x = cell_width - (24 if node is Label else 0)
			continue
		if reward_y >= 0 and py >= reward_y + 72:
			node.position.y += 64
		if px >= 650:
			node.position.x += inner - 784
		elif node is Label or node is Panel or node is Button or node is ColorRect:
			node.size.x = minf(node.size.x, inner - px)
		if node is Label and px == 30:
			node.size.x = inner - 130
	fit_labels(detail, inner)
	_compact_actions(Rect2(1088, 980, 784, 60), Rect2(x, view.y - 80, width, 48))
