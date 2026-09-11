extends "res://ui/screens/bunker/bunker_actions.gd"

## Authored desktop bunker controller.
##
## bunker.tscn contains the complete desktop hierarchy emitted by the shared
## bunker controller.  This script keeps only the route state, text values,
## styles and callbacks dynamic; bunker.gd still owns the compact reflow and
## all of the other bunker routes.

func build() -> void:
	reset_adaptive_layout()
	_bind_top_chrome()
	_route = str(app.current_route)
	if _route.is_empty():
		_route = "bunker"
	_ensure_state()
	if app.fixture_has("bunker_selected_station"):
		_selected_station = clampi(int(app.fixture_get("bunker_selected_station", _selected_station)), 1, 6)
	_install_scale_safe_styles()
	_bind_static_scene()
	queue_adaptive_layout()


func _bind_static_scene() -> void:
	var station_names: Array[String] = [
		"Storage unit",
		"Medical station",
		"Utilities",
		"Ammunition bench",
		"Food supplies",
		"Equipment"
	]
	var station_levels: Array[String] = ["LVL 2", "LVL 2", "LVL 1", "LVL 1", "LVL 1", "LVL —"]
	for station_id in range(1, 7):
		var selected: bool = station_id == _selected_station
		var row: Panel = get_node("Stations/Row%d" % station_id) as Panel
		_set_panel_style(row, Color(0.027, 0.035, 0.035, 0.8), ACCENT if selected else Color(1.0, 1.0, 1.0, 0.14))
		(row.get_node("Number") as Label).add_theme_color_override("font_color", ACCENT if selected else MUTED)
		(row.get_node("Name") as Label).add_theme_color_override("font_color", TEXT if station_id != 6 else MUTED)
		(row.get_node("Level") as Label).text = station_levels[station_id - 1]
		var row_hit := row.get_node("Hit") as Button
		_wire_button(row_hit, Callable(self, "_on_station").bind(station_id))
		mark_feature_action(row_hit, FEATURE_BUNKER)

	var marker_titles: Array[String] = [
		"STORAGE UNIT",
		"MEDICAL STATION",
		"UTILITIES",
		"AMMUNITION BENCH",
		"FOOD SUPPLIES",
		"EQUIPMENT"
	]
	var marker_subtitles: Array[String] = [
		"61 / 70 · upgrade → 90 slots",
		"Crafting · Bandage ×4 · 02:14",
		"Power 3 / 5 · generator idle",
		"Upgrade available",
		"Water collector · full",
		"Requires Bunker LVL 4"
	]
	var marker_accents: Array[Color] = [MUTED, ACCENT, YELLOW, GREEN, GREEN, MUTED]
	for station_id in range(1, 7):
		var selected: bool = station_id == _selected_station
		var badge: Panel = get_node("Marker%dBadge" % station_id) as Panel
		(badge.get_node("Number") as Label).text = str(station_id)
		var card: Panel = get_node("Marker%dCard" % station_id) as Panel
		_set_panel_style(badge, Color(0.91, 0.59, 0.18, 0.2) if selected else DARK, ACCENT if selected else TEXT)
		_set_panel_style(card, DARK, ACCENT if selected else LINE)
		(badge.get_node("Number") as Label).add_theme_color_override("font_color", ACCENT if selected else TEXT)
		(card.get_node("Sub") as Label).add_theme_color_override("font_color", marker_accents[station_id - 1])
		var heading: Label = card.get_node("Heading") as Label
		var level: Label = card.get_node("Level") as Label
		var heading_font: Font = heading.get_theme_font("font")
		if heading_font != null:
			level.position.x = 20.0 + heading_font.get_string_size(marker_titles[station_id - 1], HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		level.text = "LOCKED" if station_id == 6 else ("LVL 2" if station_id <= 2 else "LVL 1")
		card.modulate.a = 0.5 if station_id == 6 else 1.0
		badge.modulate.a = 0.5 if station_id == 6 else 1.0
		var card_hit := card.get_node("Hit") as Button
		var badge_hit := badge.get_node("Hit") as Button
		_wire_button(card_hit, Callable(self, "_on_station").bind(station_id))
		_wire_button(badge_hit, Callable(self, "_on_station").bind(station_id))
		mark_feature_action(card_hit, FEATURE_BUNKER)
		mark_feature_action(badge_hit, FEATURE_BUNKER)

	_sync_station_details()


func _sync_station_details() -> void:
	var base_nodes: Array[String] = [
		"SectionTitle",
		"SectionDetail",
		"SectionRule",
		"Description1",
		"Description2",
		"StatCard1",
		"StatCard2",
		"StatCard3",
		"StatCard4",
		"UpgradeRequirements",
		"RequirementRow1",
		"RequirementRow2",
		"RequirementRow3",
		"RequirementRow4",
		"BuildTimeLabel",
		"BuildTimeValue",
		"RequiresLabel",
		"RequiresValue",
		"Missing",
		"UpgradeAction",
		"UseAction"
	]
	var alternate_nodes: Array[String] = ["AltTitle", "AltDetail", "AltRule", "AltDescription", "AltUseAction"]
	var alternate: bool = _selected_station != 4
	for node_name in base_nodes:
		(get_node("StationDetails/" + node_name) as CanvasItem).visible = not alternate
	for node_name in alternate_nodes:
		(get_node("StationDetails/" + node_name) as CanvasItem).visible = alternate
	var upgrade := get_node("StationDetails/UpgradeAction") as Button
	var use := get_node("StationDetails/UseAction") as Button
	var alternate_use := get_node("StationDetails/AltUseAction") as Button
	_wire_button(upgrade, Callable(self, "_on_upgrade_station"))
	_wire_button(use, Callable(self, "_on_use_station"))
	_wire_button(alternate_use, Callable(self, "_on_use_station"))
	mark_feature_action(upgrade, FEATURE_BUNKER)
	mark_feature_action(use, FEATURE_BUNKER)
	mark_feature_action(alternate_use, FEATURE_BUNKER)
	mark_feature_label(get_node("StationDetails/Missing/Market") as Control,
		FEATURE_MARKETPLACE)
	if not alternate:
		return
	var station_names: Array[String] = ["", "STORAGE UNIT", "MEDICAL STATION", "UTILITIES", "AMMUNITION BENCH", "FOOD SUPPLIES"]
	var descriptions: Dictionary = {
		1: "Your stash · 61 / 70 slots used",
		2: "Craft medical supplies. Two queue slots available.",
		3: "Power 3 / 5 · generator idle",
		5: "Water collector is full · collect 4 clean water"
	}
	(get_node("StationDetails/AltTitle") as Label).text = station_names[_selected_station]
	(get_node("StationDetails/AltDetail") as Label).text = "LVL 2" if _selected_station <= 2 else "LVL 1"
	(get_node("StationDetails/AltDescription") as Label).text = str(descriptions.get(_selected_station, ""))


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


func _panel_style(fill: Color, border: Color, width: int = 1) -> StyleBox:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	return U.scale_safe(style)


func _set_panel_style(panel: Panel, fill: Color, border: Color, width: int = 1) -> void:
	if panel != null:
		panel.add_theme_stylebox_override("panel", _panel_style(fill, border, width))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)
