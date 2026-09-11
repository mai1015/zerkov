extends "res://ui/screens/bunker/bunker_actions.gd"

## Authored build-mode scene controller.
##
## The desktop construction surface is authored in build_mode.tscn.  This
## controller keeps selection, preview validity, rotation and placed-count
## state in sync while retaining bunker.gd's compact layout and input rules.

func build() -> void:
	reset_adaptive_layout()
	_bind_top_chrome()
	_route = str(app.current_route)
	if _route.is_empty():
		_route = "build_mode"
	_ensure_state()
	_install_valid_styles()
	_bind_dynamic_data()
	_wire_actions()
	queue_adaptive_layout()


func _bind_dynamic_data() -> void:
	var placement: Control = get_node("PlacementPanel") as Control
	(placement.get_node("Title") as Label).text = "PLACING · %s" % _build_selection
	(get_node("PlacedHint") as Label).text = "Placed %d / 12 · space unlocks with Bunker LVL" % int(app.fixture_get("bunker_placed", 7))

	var preview_size: Vector2 = Vector2(124, 84) if _build_rotation % 2 == 0 else Vector2(84, 124)
	var preview: Panel = get_node("Preview") as Panel
	preview.size = preview_size
	_set_panel_style(preview, Color(0.10, 0.42, 0.18, 0.24) if _preview_valid else Color(0.42, 0.08, 0.05, 0.20), GREEN if _preview_valid else RED)
	var status: Label = preview.get_node("Status") as Label
	status.text = "✓ valid · near power" if _preview_valid else "× blocked · wall"
	status.add_theme_color_override("font_color", GREEN if _preview_valid else RED)
	var selection: Label = preview.get_node("Selection") as Label
	selection.text = "%s · 3×2" % _build_selection
	selection.position.y = preview_size.y / 2.0 - 9.0
	selection.add_theme_color_override("font_color", GREEN if _preview_valid else RED)
	(preview.get_node("Hit") as Button).size = Vector2(126, 84)

	for item in [["All", "ALL"], ["Stations", "STATIONS"], ["Power", "POWER"], ["Storage", "STORAGE"], ["Comfort", "COMFORT"], ["Decor", "DECOR"]]:
		var category: Panel = get_node("Category" + item[0]) as Panel
		var selected: bool = _build_category == item[1]
		_set_panel_style(category, TEXT if selected else Color.TRANSPARENT, TEXT if selected else Color(1.0, 1.0, 1.0, 0.18))
		(category.get_node("Label") as Label).add_theme_color_override("font_color", BG if selected else MUTED)

	var cards = [
		["Workbench", "WORKBENCH", "STATIONS", false], ["Generator", "GENERATOR", "POWER", false], ["Watercollector", "WATER COLLECTOR", "STATIONS", false],
		["Shelves", "SHELVES", "STORAGE", false], ["Bunk", "BUNK", "COMFORT", false], ["Radio", "RADIO", "DECOR", false],
		["Armoryrack", "ARMORY RACK", "STORAGE", true], ["Greenhouse", "GREENHOUSE", "COMFORT", true]
	]
	var card_x: float = 48.0
	var show_all_cards: bool = _build_category in ["ALL", "STATIONS"]
	for item in cards:
		var card: Panel = get_node("Card" + item[0]) as Panel
		var visible: bool = show_all_cards or item[2] == _build_category
		card.visible = visible
		_set_panel_style(card, Color(0.027, 0.035, 0.035, 0.78), TEXT if _build_selection == item[1] else LINE)
		card.modulate.a = (0.4 if item[3] else 1.0) if visible else 0.0
		if visible:
			card.position.x = card_x
			card_x += 226.0


func _install_valid_styles() -> void:
	# PixelStyle's private source box is not serialized into a packed scene.
	# Recreate the authored source boxes before the first frame so every static
	# panel and outlined action renders with its original fill and rim.
	_set_panel_style(get_node("StorageMarker") as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	_set_panel_style(get_node("UtilitiesMarker") as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	_set_panel_style(get_node("PlacementPanel") as Panel, Color(0.027, 0.035, 0.035, 0.64), Color.TRANSPARENT)
	_set_panel_style(get_node("InvalidPreview") as Panel, Color(0.42, 0.08, 0.05, 0.18), RED)
	for category in ["All", "Stations", "Power", "Storage", "Comfort", "Decor"]:
		_set_panel_style(get_node("Category" + category) as Panel, Color.TRANSPARENT, Color(1.0, 1.0, 1.0, 0.18))
	for item in ["Workbench", "Generator", "Watercollector", "Shelves", "Bunk", "Radio", "Armoryrack", "Greenhouse"]:
		_set_panel_style(get_node("Card" + item) as Panel, Color(0.027, 0.035, 0.035, 0.78), LINE)
		_set_panel_style(get_node("Card%s/Sprite" % item) as Panel, Color.TRANSPARENT, LINE)
	_set_outlined_button(get_node("PlacementPanel/Place") as Button, true)
	_set_outlined_button(get_node("PlacementPanel/Rotate") as Button, false)


func _set_panel_style(panel: Panel, fill: Color, border: Color) -> void:
	if panel != null:
		panel.add_theme_stylebox_override("panel", U.style(fill, border))


func _set_outlined_button(button: Button, primary: bool) -> void:
	if button == null:
		return
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = GREEN if primary else Color.TRANSPARENT
	normal.border_color = GREEN if primary else Color(1.0, 1.0, 1.0, 0.38)
	normal.set_border_width_all(1)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = HOVER if primary else Color(1.0, 1.0, 1.0, 0.08)
	hover.border_color = HOVER if primary else TEXT
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.85, 0.46, 0.08, 1.0) if primary else Color(0.91, 0.59, 0.18, 0.14)
	pressed.border_color = ACCENT if primary else TEXT
	button.add_theme_stylebox_override("normal", U.scale_safe(normal))
	button.add_theme_stylebox_override("hover", U.scale_safe(hover))
	button.add_theme_stylebox_override("pressed", U.scale_safe(pressed))
	button.add_theme_stylebox_override("focus", U.scale_safe(hover))


func _wire_actions() -> void:
	_wire_button(get_node("PlacementPanel/Place") as Button, Callable(self, "_on_place_building"))
	_wire_button(get_node("PlacementPanel/Rotate") as Button, Callable(self, "_on_rotate_building"))
	_wire_button(get_node("Preview/Hit") as Button, Callable(self, "_on_toggle_preview"))
	for category in ["All", "Stations", "Power", "Storage", "Comfort", "Decor"]:
		_wire_button(get_node("Category" + category + "/Hit") as Button, Callable(self, "_on_build_category").bind((get_node("Category" + category + "/Label") as Label).text))
	for item in [
		["Workbench", "WORKBENCH"], ["Generator", "GENERATOR"], ["Watercollector", "WATER COLLECTOR"], ["Shelves", "SHELVES"],
		["Bunk", "BUNK"], ["Radio", "RADIO"], ["Armoryrack", "ARMORY RACK"], ["Greenhouse", "GREENHOUSE"]
	]:
		_wire_button(get_node("Card%s/Hit" % item[0]) as Button, Callable(self, "_on_build_item").bind(item[1]))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)
