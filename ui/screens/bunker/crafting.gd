extends "res://ui/screens/bunker/bunker_actions.gd"

## Authored crafting screen controller.
##
## crafting.tscn contains the complete desktop hierarchy emitted by the shared
## bunker controller. This script keeps the recipe selection, quantity and
## absolute-time queue state dynamic while retaining bunker.gd's compact
## reflow and keyboard actions.

const RECIPE_NAMES: Array[String] = ["Bandage", "Splint", "Painkillers", "Antiseptic", "MedKit", "Water"]
const RECIPE_TITLES: Array[String] = ["Bandage", "Splint", "Painkillers", "Antiseptic", "Med kit · field", "Clean water"]
const RECIPE_DURATIONS: Array[String] = ["00:45 · ×2 per craft", "01:30", "02:00", "03:00", "08:00", "00:20"]
const RECIPE_AVAILABLE: Array[bool] = [true, true, true, false, false, true]


func build() -> void:
	reset_adaptive_layout()
	_bind_top_chrome()
	_route = str(app.current_route)
	if _route.is_empty():
		_route = "crafting"
	_ensure_state()
	_selected_recipe = clampi(_selected_recipe, 0, 5)
	_craft_quantity = clampi(_craft_quantity, 1, 3)
	_install_scale_safe_styles()
	_bind_dynamic_data()
	_wire_actions()
	_build_focus_graph()
	queue_adaptive_layout()


func _bind_dynamic_data() -> void:
	var recipe_panel: Control = get_node("RecipePanel") as Control
	var filters: Array = [
		["FilterAll", "ALL"],
		["FilterCraftable", "CRAFTABLE"],
		["FilterMeds", "MEDS"],
		["FilterTools", "TOOLS"]
	]
	for filter_data in filters:
		var segment: Panel = recipe_panel.get_node(str(filter_data[0])) as Panel
		var active: bool = _recipe_filter == str(filter_data[1])
		_set_panel_style(segment, TEXT if active else Color.TRANSPARENT, TEXT if active else Color(1.0, 1.0, 1.0, 0.14))
		(segment.get_node("Label") as Label).add_theme_color_override("font_color", BG if active else MUTED)

	var recipe_y: float = 77.0
	for index in range(RECIPE_NAMES.size()):
		var visible: bool = not (_recipe_filter == "MEDS" and index == 5) and not (_recipe_filter == "TOOLS" and index != 1)
		var row: Panel = recipe_panel.get_node("Recipe" + RECIPE_NAMES[index]) as Panel
		row.visible = visible
		if visible:
			row.position.y = recipe_y
			recipe_y += 76.0
		var selected: bool = index == _selected_recipe
		_set_panel_style(row, Color(1.0, 1.0, 1.0, 0.06) if selected else Color(0.027, 0.035, 0.035, 0.72), TEXT if selected else Color(1.0, 1.0, 1.0, 0.14))
		row.modulate.a = 0.55 if not RECIPE_AVAILABLE[index] else 1.0
		(row.get_node("Name") as Label).text = RECIPE_TITLES[index]
		(row.get_node("Name") as Label).add_theme_color_override("font_color", TEXT if selected else SOFT)
		(row.get_node("Duration") as Label).text = RECIPE_DURATIONS[index]
		(row.get_node("Availability") as ColorRect).color = GREEN if RECIPE_AVAILABLE[index] else RED
	(recipe_panel.get_node("UpgradePanel") as Panel).position.y = 883.0

	_bind_detail()
	_bind_queue()


func _bind_detail() -> void:
	var detail: Control = get_node("DetailPanel") as Control
	var recipe: Array = _recipe_data()
	(detail.get_node("Title") as Label).text = str(recipe[0]).to_upper()
	(detail.get_node("Description") as Label).text = str(recipe[3])

	var mats: Array = [
		["item_tape.png", "Duct tape", "3/1", false],
		["item_fish.png", "Cloth", "2/2", false],
		["item_cup.png", "Clean water", "0/1", true]
	]
	if _selected_recipe == 1:
		mats = [["item_tape.png", "Duct tape", "3/1", false], ["item_fish.png", "Cloth", "2/1", false]]
	elif _selected_recipe == 5:
		mats = [["item_cup.png", "Unfiltered water", "4/1", false]]
	var cells: Array[Panel] = [
		detail.get_node("Ingredients/DuctTape") as Panel,
		detail.get_node("Ingredients/Cloth") as Panel,
		detail.get_node("Ingredients/Water") as Panel
	]
	var names: Array[Label] = [
		detail.get_node("Ingredients/DuctTapeName") as Label,
		detail.get_node("Ingredients/ClothName") as Label,
		detail.get_node("Ingredients/WaterName") as Label
	]
	for index in range(cells.size()):
		var present: bool = index < mats.size()
		cells[index].visible = present
		names[index].visible = present
		if not present:
			continue
		var mat: Array = mats[index]
		var x: float = 176.0 + index * 106.0
		cells[index].position = Vector2(x, 50.0)
		names[index].position = Vector2(x - 10.0, 130.0)
		(cells[index].get_node("Icon") as TextureRect).texture = _asset_texture(str(mat[0]))
		var count: Label = cells[index].get_node("Count") as Label
		count.text = str(mat[2])
		count.add_theme_color_override("font_color", RED if bool(mat[3]) else TEXT)
		_set_panel_style(cells[index], Color(1.0, 1.0, 1.0, 0.045), RED if bool(mat[3]) else Color(1.0, 1.0, 1.0, 0.22))
		names[index].text = str(mat[1])

	var output: Panel = detail.get_node("Ingredients/Output") as Panel
	(output.get_node("Icon") as TextureRect).texture = _asset_texture(str(recipe[1]))
	(output.get_node("Count") as Label).text = "×%d" % int(recipe[4])
	(detail.get_node("Ingredients/OutputName") as Label).text = str(recipe[0]).to_upper()
	(detail.get_node("StatTime/Value") as Label).text = _format_remaining(int(recipe[2]))
	(detail.get_node("StatQuantity/Value") as Label).text = "    %d     max 3" % _craft_quantity
	(detail.get_node("StatTotal/Value") as Label).text = "%s · %d %s" % [_format_remaining(int(recipe[2]) * _craft_quantity), int(recipe[4]) * _craft_quantity, str(recipe[0]).to_lower()]
	var missing: bool = _selected_recipe == 0 or _selected_recipe in [3, 4]
	var missing_text: String = "MISSING · CLEAN WATER ×1" if _selected_recipe == 0 else ("REQUIRES STATION UPGRADE" if _selected_recipe in [3, 4] else "INGREDIENTS AVAILABLE")
	(detail.get_node("MissingPanel/Label") as Label).text = missing_text
	(detail.get_node("MissingPanel/Label") as Label).add_theme_color_override("font_color", RED if missing else GREEN)
	(detail.get_node("CraftFooter/Label") as Label).text = "SPACE  CRAFT ×%d%s" % [_craft_quantity, " · 1 MISSING" if _selected_recipe == 0 else ""]
	(detail.get_node("CraftNow") as Button).text = "CRAFT ×2 NOW" if _selected_recipe == 0 else "CRAFT NOW"
	(detail.get_node("CraftNow") as Button).tooltip_text = (detail.get_node("CraftNow") as Button).text


func _bind_queue() -> void:
	var panel: Panel = get_node("QueuePanel") as Panel
	var queue: Array = _craft_queue()
	var cards: Array[Panel] = [get_node("QueuePanel/QueueBandage") as Panel, get_node("QueuePanel/QueueSplint") as Panel]
	_craft_status_labels.clear()
	_craft_progress_bars.clear()
	for index in range(cards.size()):
		var card: Panel = cards[index]
		var present: bool = index < queue.size()
		card.visible = present
		if not present:
			continue
		var data: Dictionary = queue[index]
		card.position.y = 38.0 + index * 76.0
		(card.get_node("Icon") as TextureRect).texture = _asset_texture(str(data.get("asset", "item_bottle.png")))
		(card.get_node("Name") as Label).text = str(data.get("name", "Craft"))
		var remaining: int = int(data.get("finish_at", 0)) - Time.get_ticks_msec()
		var done: bool = remaining <= 0
		var status: Label = card.get_node("Status") as Label
		status.position.x = 250.0 if done else 332.0
		status.text = "READY" if done else "%s left" % _format_remaining(remaining)
		status.add_theme_color_override("font_color", GREEN if done else MUTED)
		var progress: ProgressBar = card.get_node("Progress") as ProgressBar
		progress.size.x = 314.0 if done else 400.0
		progress.value = 100.0 if done else clampf(100.0 - float(remaining) / float(maxi(1, int(data.get("duration", 1)))) * 100.0, 0.0, 100.0)
		progress.add_theme_stylebox_override("fill", _progress_style(GREEN if done else ACCENT))
		_craft_status_labels.append(status)
		_craft_progress_bars.append(progress)
		var collect: Button = card.get_node_or_null("Collect") as Button
		if collect != null:
			collect.visible = done
			collect.tooltip_text = "COLLECT"
			_set_collect_style(collect)
	var next_slot: Panel = panel.get_node("Slot") as Panel
	var slot_y: float = 38.0 + queue.size() * 76.0
	next_slot.position.y = slot_y
	(next_slot.get_node("Label") as Label).text = "slot %d · unlock at LVL 3" % (queue.size() + 1)
	var stash_title_y: float = slot_y + 63.0
	(panel.get_node("StashTitle") as Label).position.y = stash_title_y - 3.0
	(panel.get_node("StashDetail") as Label).position.y = stash_title_y - 2.0
	panel.get_node("StashRule").position.y = stash_title_y + 25.0
	(panel.get_node("Stash") as Panel).position.y = stash_title_y + 43.0


func _wire_actions() -> void:
	for item in [["FilterAll", "ALL"], ["FilterCraftable", "CRAFTABLE"], ["FilterMeds", "MEDS"], ["FilterTools", "TOOLS"]]:
		_wire_button(get_node("RecipePanel/%s/Hit" % item[0]) as Button, Callable(self, "_on_recipe_filter").bind(item[1]))
	for index in range(RECIPE_NAMES.size()):
		_wire_button(get_node("RecipePanel/Recipe%s/Hit" % RECIPE_NAMES[index]) as Button, Callable(self, "_on_recipe_selected").bind(index))
	_wire_button(get_node("RecipePanel/UpgradePanel/Action") as Button, Callable(self, "_on_upgrade_recipe"))
	_wire_button(get_node("DetailPanel/QuantityMinus") as Button, Callable(self, "_on_quantity").bind(-1))
	_wire_button(get_node("DetailPanel/QuantityPlus") as Button, Callable(self, "_on_quantity").bind(1))
	_wire_button(get_node("DetailPanel/MissingPanel/CraftWater") as Button, Callable(self, "_on_craft_water"))
	_wire_button(get_node("DetailPanel/CraftNow") as Button, Callable(self, "_on_craft_now"))
	for index in range(2):
		var collect: Button = get_node("QueuePanel/%s/Collect" % ("QueueBandage" if index == 0 else "QueueSplint")) as Button
		_wire_button(collect, Callable(self, "_on_collect_queue").bind(str(_craft_queue()[index].get("id", "")) if index < _craft_queue().size() else ""))
	_wire_button(get_node("QueuePanel/Stash/Hit") as Button, Callable(self, "_on_stash_click"))


func _build_focus_graph() -> void:
	var entries: Array[Button] = []
	for index in range(RECIPE_NAMES.size()):
		var button: Button = get_node("RecipePanel/Recipe%s/Hit" % RECIPE_NAMES[index]) as Button
		if button.visible and not button.disabled:
			entries.append(button)
	if entries.is_empty():
		return
	for index in range(entries.size()):
		entries[index].focus_neighbor_top = entries[index].get_path_to(entries[posmod(index - 1, entries.size())])
		entries[index].focus_neighbor_bottom = entries[index].get_path_to(entries[(index + 1) % entries.size()])
	entries[mini(_selected_recipe, entries.size() - 1)].grab_focus()


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


func _set_panel_style(panel: Panel, fill: Color, border: Color, width: int = 1) -> void:
	if panel != null:
		panel.add_theme_stylebox_override("panel", U.style(fill, border, width))


func _set_collect_style(button: Button) -> void:
	if button == null:
		return
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color.TRANSPARENT
	normal.border_color = GREEN
	normal.set_border_width_all(1)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(1.0, 1.0, 1.0, 0.08)
	hover.border_color = TEXT
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.91, 0.59, 0.18, 0.14)
	button.add_theme_stylebox_override("normal", U.scale_safe(normal))
	button.add_theme_stylebox_override("hover", U.scale_safe(hover))
	button.add_theme_stylebox_override("pressed", U.scale_safe(pressed))
	button.add_theme_stylebox_override("focus", U.scale_safe(hover))
	button.add_theme_color_override("font_color", GREEN)
	button.add_theme_color_override("font_hover_color", TEXT)


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _asset_texture(asset: String) -> Texture2D:
	var path: String = "res://assets/handoff/" + asset
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

