extends "res://ui/screens/character/inventory_actions.gd"
## One authored workspace shared by inventory, health and stats.
const CompactLayout = preload("res://ui/screens/character/components/character_layout.gd")
var _nodes: Dictionary = {}
var _bound := false

func build() -> void:
	_surface = $InventoryContent
	if not _bound:
		_ensure_inventory_state()
		var persisted := _state()
		_loot_mode = bool(persisted.get("inventory_loot_mode", false))
		_current_filter = str(persisted.get("inventory_filter", "all"))
		_search_query = str(persisted.get("inventory_search", ""))
		_compact_section = _tab_name() if _tab_name() in ["health", "stats"] else str(persisted.get("inventory_compact_section", "loadout"))
		for node in _surface.find_children("*", "Control", true, false):
			_nodes[str(_surface.get_path_to(node))] = node
		for section in ["loadout", "stash", "gear", "health", "stats"]:
			var button: Button = _node("CompactWorkspace/Section_" + section)
			_wire_button(button, _select_compact_section.bind(section))
		_bound = true
	ZThemeAdapter.apply_controls(self)
	_bind_header()
	_bind_content()
	queue_adaptive_layout()

func _node(path: String) -> Control:
	return _nodes.get(path) as Control

func _bind_content() -> void:
	_grids.clear()
	_bind_post_raid()
	_bind_tabs()
	_bind_gear()
	_bind_health()
	_bind_stats()
	_bind_loadout()
	_bind_stash()
	_build_focus_graph()
	if _adaptive_applied:
		CompactLayout.apply(self, get_viewport_rect().size)
	else:
		_node("CharacterColumn").visible = _tab_name() == "gear"
		_node("HealthColumn").visible = _tab_name() == "health"
		_node("StatsColumn").visible = _tab_name() == "stats"

func layout_compact(view: Vector2) -> void:
	CompactLayout.apply(self, view)

func _select_compact_section(section: String) -> void:
	_compact_section = section
	_state()["inventory_compact_section"] = section
	CompactLayout.apply(self, get_viewport_rect().size)

func _selected_from_grid(item: Dictionary, grid: Control) -> void:
	_on_grid_selected(item, str(grid.source_id))

func _context_from_grid(item: Dictionary, grid: Control) -> void:
	_on_grid_context(item, str(grid.source_id))

func _bind_header() -> void:
	var chrome: ZNavigationChrome = get_node_or_null("NavigationChrome") as ZNavigationChrome
	if chrome == null:
		push_error("Inventory scene is missing its NavigationChrome component")
		return
	chrome.active_route = app.current_route
	var navigate := Callable(self, "_open_route")
	var insurance := Callable(self, "_insurance_hint")
	var back := Callable(self, "_close_screen")
	if not chrome.navigate_requested.is_connected(navigate):
		chrome.navigate_requested.connect(navigate)
	if not chrome.insurance_requested.is_connected(insurance):
		chrome.insurance_requested.connect(insurance)
	if not chrome.back_requested.is_connected(back):
		chrome.back_requested.connect(back)


func _bind_post_raid() -> void:
	var post: Panel = _node("PostRaidBar") as Panel
	if post == null:
		return
	post.visible = bool(_state().get("post_raid", true))
	_wire_button(post.get_node_or_null("MoveLoot") as Button, Callable(self, "_bank_loot"))
	_wire_button(post.get_node_or_null("Reinsure") as Button, Callable(self, "_reinsure"))
	_wire_button(post.get_node_or_null("SellJunk") as Button, Callable(self, "_sell_junk"))


func _bind_tabs() -> void:
	var current: String = _tab_name()
	var health: Button = _node("HealthTab") as Button
	var gear: Button = _node("GearTab") as Button
	var stats: Button = _node("StatsTab") as Button
	_wire_button(health, Callable(self, "_select_tab").bind("health"))
	_wire_button(gear, Callable(self, "_select_tab").bind("gear"))
	_wire_button(stats, Callable(self, "_select_tab").bind("stats"))
	_apply_tab_style(health, current == "health")
	_apply_tab_style(gear, current == "gear")
	_apply_tab_style(stats, current == "stats")
	var tag: Label = _node("TabTag/Text") as Label
	if tag != null:
		tag.text = current.to_upper()


func _bind_gear() -> void:
	var slots: Array[Array] = [
		["HeadSlot", "HEAD", "— empty"],
		["FaceSlot", "FACE", "— empty"],
		["ArmorSlot", "ARMOR", "— empty"],
		["HeadsetSlot", "HEADSET", "— empty"],
		["SlingSlot", "ON SLING", "AKM · 7.62×39 · 24/30"],
		["BackSlot", "ON BACK", "Pump shotgun · 12ga · 5/5"],
		["LegStrapSlot", "LEG STRAP", "Machete"],
		["HolsterSlot", "HOLSTER", "M1911 · .45 · 7/7"],
	]
	var character: Control = _node("CharacterColumn") as Control
	if character == null:
		return
	for entry in slots:
		var slot: Button = character.get_node_or_null(str(entry[0])) as Button
		if slot == null:
			continue
		_wire_button(slot, Callable(self, "_gear_selected").bind(str(entry[1]), str(entry[2])))

	var sling: Button = character.get_node_or_null("SlingSlot") as Button
	if sling != null:
		var compatibility_enter := Callable(self, "_set_compatibility").bind("7.62x39")
		var compatibility_exit := Callable(self, "_clear_compatibility")
		if not sling.mouse_entered.is_connected(compatibility_enter):
			sling.mouse_entered.connect(compatibility_enter)
		if not sling.mouse_exited.is_connected(compatibility_exit):
			sling.mouse_exited.connect(compatibility_exit)
		sling.tooltip_text = "AKM\nShowing compatible ammo + mags\nF · move to stash   RMB · options"


func _bind_loadout() -> void:
	var inventory: Dictionary = _inventory_data()
	var rig_size: Array = inventory.get("rig_size", [6, 2])
	var pack_size: Array = inventory.get("backpack_size", [6, 5])
	var rig_title: Label = _node("RigTitle") as Label
	if rig_title != null:
		rig_title.text = "Scav vest   %d×%d · %d slots · 0.8 kg" % [int(rig_size[0]), int(rig_size[1]), int(rig_size[0]) * int(rig_size[1])]
	var pack_title: Label = _node("PackTitle") as Label
	if pack_title != null:
		pack_title.text = "Field pack   %d×%d · %d slots · 11 used · 1.2 kg" % [int(pack_size[0]), int(pack_size[1]), int(pack_size[0]) * int(pack_size[1])]
	_wire_button(_node("RigContainer") as Button, Callable(self, "_container_selected").bind("rig"))
	_wire_button(_node("PackContainer") as Button, Callable(self, "_container_selected").bind("backpack"))
	_wire_button(_node("RigSwap") as Button, Callable(self, "_swap_container").bind("rig"))
	_wire_button(_node("PackSwap") as Button, Callable(self, "_swap_container").bind("backpack"))

	_bind_grid(_node("PocketsGrid") as Control, 4, 1, "pockets", "pockets")
	_bind_grid(_node("RigGrid") as Control, int(rig_size[0]), int(rig_size[1]), "rig", "rig")
	_bind_grid(_node("PackGrid") as Control, int(pack_size[0]), int(pack_size[1]), "backpack", "backpack")

	for index in range(4):
		var slot: Button = _node("QuickSlot%d" % (index + 5)) as Button
		_wire_button(slot, Callable(self, "_quick_slot_used").bind(index))
	var count: Label = _node("QuickSlot5/Count") as Label
	if count != null:
		count.text = str(_state().get("med_count", 2))


func _bind_stash() -> void:
	var stash_tab: Button = _node("StashTab") as Button
	var loot_tab: Button = _node("LootTab") as Button
	_wire_button(stash_tab, Callable(self, "_set_loot_mode").bind(false))
	_wire_button(loot_tab, Callable(self, "_set_loot_mode").bind(true))
	_apply_mode_style(stash_tab, not _loot_mode)
	_apply_mode_style(loot_tab, _loot_mode)

	var search: LineEdit = _node("StashSearch") as LineEdit
	if search != null:
		if search.text != _search_query: search.text = _search_query
		if not search.text_changed.is_connected(Callable(self, "_on_search_changed")):
			search.text_changed.connect(Callable(self, "_on_search_changed"))
	_wire_button(_node("SortStash") as Button, Callable(self, "_sort_stash"))
	_wire_button(_node("OrganizeStash") as Button, Callable(self, "_organize_stash"))

	var filter_names: Array[String] = ["all", "guns", "ammo", "armor", "clothing", "food", "util"]
	var filter_nodes: Array[String] = ["All", "Guns", "Ammo", "Armor", "Cloth", "Food", "Util"]
	for index in range(filter_names.size()):
		var filter_button: Button = _node("Filter" + filter_nodes[index]) as Button
		if filter_button == null:
			continue
		filter_button.tooltip_text = "Filter " + filter_names[index]
		filter_button.add_theme_color_override("font_color", U.TEXT if _current_filter == filter_names[index] else U.MUTED)
		_wire_button(filter_button, Callable(self, "_set_filter").bind(filter_names[index]))
	_bind_grid(_node("StashGrid") as Control, 7, 10, "loot" if _loot_mode else "stash", "loot" if _loot_mode else "stash")


func _bind_grid(grid: Control, columns: int, rows: int, source_key: String, data_key: String) -> void:
	if grid == null or not grid.has_method("set_grid_size"):
		return
	grid.set("source_id", source_key)
	grid.set_grid_size(columns, rows, 74)
	var values: Array = _items_for(data_key)
	if source_key in ["stash", "loot"]:
		values = _filtered_items(values)
	grid.set_items(values)
	grid.set_compatibility(_compatibility_key)
	var hover := Callable(self, "_on_grid_hovered").bind(grid)
	var selected := Callable(self, "_selected_from_grid").bind(grid)
	var context := Callable(self, "_context_from_grid").bind(grid)
	var quick := Callable(self, "_on_quick_move")
	var dropped := Callable(self, "_on_item_dropped").bind(grid)
	var rejected := Callable(self, "_on_drop_rejected")
	if not grid.item_hovered.is_connected(hover):
		grid.item_hovered.connect(hover)
	if not grid.item_selected.is_connected(selected):
		grid.item_selected.connect(selected)
	if not grid.context_requested.is_connected(context):
		grid.context_requested.connect(context)
	if not grid.quick_moved.is_connected(quick):
		grid.quick_moved.connect(quick, CONNECT_DEFERRED)
	if not grid.item_dropped.is_connected(dropped):
		grid.item_dropped.connect(dropped, CONNECT_DEFERRED)
	if not grid.drop_rejected.is_connected(rejected):
		grid.drop_rejected.connect(rejected)
	_grids.append(grid)


func _apply_tab_style(button: Button, active: bool) -> void:
	if button == null:
		return
	button.add_theme_color_override("font_color", U.TEXT if active else U.MUTED)
	button.add_theme_stylebox_override("normal", U.style(U.SUBTLE, Color.TRANSPARENT, 0) if active else U.style(Color.TRANSPARENT, Color.TRANSPARENT, 0))


func _apply_mode_style(button: Button, active: bool) -> void:
	if button == null:
		return
	if active:
		button.add_theme_stylebox_override("normal", U.style(U.ACCENT, U.ACCENT))
		button.add_theme_stylebox_override("hover", U.style(U.HOVER, U.HOVER))
		button.add_theme_color_override("font_color", U.BG)
	else:
		button.add_theme_stylebox_override("normal", U.style(U.DARK, U.LINE))
		button.add_theme_color_override("font_color", U.TEXT)


func _build_focus_graph() -> void:
	var focus_nodes: Array[Button] = []
	for path in ["HealthTab", "GearTab", "StatsTab", "StashTab", "LootTab", "SortStash", "OrganizeStash"]:
		var button: Button = _node(path) as Button
		if button != null and not button.disabled:
			focus_nodes.append(button)
	if focus_nodes.is_empty():
		return
	for index in range(focus_nodes.size()):
		var current: Button = focus_nodes[index]
		current.focus_neighbor_left = current.get_path_to(focus_nodes[posmod(index - 1, focus_nodes.size())])
		current.focus_neighbor_right = current.get_path_to(focus_nodes[(index + 1) % focus_nodes.size()])


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _open_route(route: String) -> void:
	if app != null and app.has_method("navigate"):
		app.navigate(route)


func _insurance_hint() -> void:
	_notify("Insurance claims are outside the approved design set.")


func _close_screen() -> void:
	if app != null and app.has_method("back"):
		app.back()
func _bind_health() -> void:
	var area: Control = _node("HealthColumn") as Control
	if area == null:
		return
	var treated: bool = bool(_state().get("quick_healed", false))
	_set_health_card(area, "HeadCard", "HEAD", "55%", "Concussed · 0:42", U.YELLOW, 55.0)
	_set_health_card(area, "TorsoCard", "TORSO", "68%" if treated else "20%", "Stabilized · 0:18" if treated else "Heavy bleed · −3/s", U.GREEN if treated else U.RED, 68.0 if treated else 20.0)
	_set_health_card(area, "ArmsCard", "ARMS", "92%", "No effects", U.GREEN, 92.0)
	_set_health_card(area, "LegsCard", "LEGS", "50%", "Fracture · slowed", U.YELLOW, 50.0)
	_set_meter(area, "Health", "HEALTH", "476/700" if treated else "190/700", 68.0 if treated else 27.0, U.GREEN if treated else U.RED)
	_set_meter(area, "Energy", "ENERGY", "64/100", 64.0, U.YELLOW)
	_set_meter(area, "Hydration", "HYDRATION", "22/100", 22.0, U.BLUE)
	_wire_button(_node("HealthColumn/QuickHeal") as Button, Callable(self, "_quick_heal"))


func _set_health_card(area: Control, card_name: String, limb: String, percent: String, detail: String, color: Color, value: float) -> void:
	var panel: Panel = area.get_node_or_null(card_name) as Panel
	if panel == null:
		return
	panel.add_theme_stylebox_override("panel", U.style(Color(0.027, 0.035, 0.035, 0.88), color if value < 30.0 else U.LINE, 1))
	var limb_label: Label = panel.get_node_or_null("Limb") as Label
	if limb_label != null:
		limb_label.text = limb
	var percent_label: Label = panel.get_node_or_null("Percent") as Label
	if percent_label != null:
		percent_label.text = percent
		percent_label.add_theme_color_override("font_color", color)
	var meter: ProgressBar = panel.get_node_or_null("Meter") as ProgressBar
	if meter != null:
		meter.value = value
		meter.add_theme_stylebox_override("fill", U.style(color, Color.TRANSPARENT, 0))
	var detail_label: Label = panel.get_node_or_null("Detail") as Label
	if detail_label != null:
		detail_label.text = detail
		detail_label.add_theme_color_override("font_color", color if value < 30.0 else U.SOFT)


func _set_meter(area: Control, prefix: String, title: String, value_text: String, value: float, color: Color) -> void:
	var title_label: Label = area.get_node_or_null(prefix + "Title") as Label
	if title_label != null:
		title_label.text = title
	var bar: ProgressBar = area.get_node_or_null(prefix + "Bar") as ProgressBar
	if bar != null:
		bar.value = value
		bar.add_theme_stylebox_override("fill", U.style(color, Color.TRANSPARENT, 0))
	var value_label: Label = area.get_node_or_null(prefix + "Value") as Label
	if value_label != null:
		value_label.text = value_text
		value_label.add_theme_color_override("font_color", color if value < 30.0 else U.TEXT)


func _bind_stats() -> void:
	var stats: Control = _node("StatsColumn") as Control
	if stats == null:
		return
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Stats are authored presentation values in this prototype. Keep the
	# authored hierarchy stable while allowing the shared state to control the
	# compact section and all actions around it.
