extends "res://ui/screens/character/inventory_actions.gd"
## One authored workspace shared by inventory, health and stats.
const CompactLayout = preload("res://ui/screens/character/components/character_layout.gd")
const InventoryPresentationModel = preload("res://addons/inventory_system/runtime/inventory_presentation_model.gd")
var _nodes: Dictionary = {}
var _bound := false
var _compact_reflow_queued := false
var _compact_scroll_release_queued := false


func _on_activated() -> void:
	super._on_activated()
	restore_injected_character_interaction_on_activation()

func build() -> void:
	_surface = $InventoryContent
	if not _bound:
		attach_injected_character_runtime()
		if not _live_inventory_binding:
			_ensure_inventory_state()
			var persisted := _state()
			_loot_mode = bool(persisted.get("inventory_loot_mode", false))
			_current_filter = str(persisted.get("inventory_filter", "all"))
			_search_query = str(persisted.get("inventory_search", ""))
			_compact_section = _tab_name() if _tab_name() in ["health", "stats"] else str(persisted.get("inventory_compact_section", "loadout"))
		else:
			_compact_section = _tab_name() if _tab_name() in ["health", "stats"] else _compact_section
		for node in _surface.find_children("*", "Control", true, false):
			_nodes[str(_surface.get_path_to(node))] = node
		for section in ["loadout", "stash", "gear", "health", "stats"]:
			var button: Button = _node("CompactWorkspace/Section_" + section)
			_wire_button_deferred(button, _select_compact_section.bind(section))
		var compact_stash_scroll := _node("CompactWorkspace/StashScroll") as ScrollContainer
		if compact_stash_scroll != null and not compact_stash_scroll.gui_input.is_connected(_on_compact_stash_scroll_input):
			compact_stash_scroll.gui_input.connect(_on_compact_stash_scroll_input)
		_bound = true
	ZThemeAdapter.apply_controls(self)
	_bind_header()
	_bind_content()
	restore_injected_character_interaction()
	queue_adaptive_layout()

func _node(path: String) -> Control:
	var direct := _nodes.get(path) as Control
	if direct != null:
		return direct
	# Scene wrappers may move a retained grid between the authored desktop
	# parent and the compact scroll content. Resolve by leaf name as a bounded
	# fallback, never by an array index or fixture identity.
	var leaf := path.get_file()
	for node in _surface.find_children(leaf, "Control", true, false):
		return node as Control
	return null

func _bind_content() -> void:
	_grids.clear()
	_bind_post_raid()
	_bind_tabs()
	_bind_gear()
	_bind_health()
	_bind_stats()
	_bind_loadout()
	_bind_stash()
	_bind_live_status()
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
	if not _live_inventory_binding:
		_state()["inventory_compact_section"] = section
	# A section Button emits `pressed` from inside Godot's mouse-release
	# dispatch. Reparenting and resizing the control tree synchronously from that
	# callback leaves the viewport's GUI mouse capture on the old hierarchy. The
	# next native tab/wheel gesture can then be swallowed even though the target
	# is visible. Coalesce the reflow onto the next idle turn so the current
	# native gesture always completes against one stable tree.
	_queue_compact_reflow()


func _queue_compact_reflow() -> void:
	if _compact_reflow_queued or _tearing_down or not is_inside_tree():
		return
	_compact_reflow_queued = true
	call_deferred("_apply_queued_compact_reflow")


func _apply_queued_compact_reflow() -> void:
	_compact_reflow_queued = false
	if _tearing_down or not is_inside_tree() or not _adaptive_applied:
		return
	CompactLayout.apply(self, get_viewport_rect().size)


func _on_compact_stash_scroll_input(event: InputEvent) -> void:
	if not _adaptive_applied or not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed or mouse_event.button_index not in [
		MOUSE_BUTTON_WHEEL_UP,
		MOUSE_BUTTON_WHEEL_DOWN,
		MOUSE_BUTTON_WHEEL_LEFT,
		MOUSE_BUTTON_WHEEL_RIGHT,
	]:
		return
	if _compact_scroll_release_queued:
		return
	_compact_scroll_release_queued = true
	call_deferred("_release_compact_scroll_capture")


func _release_compact_scroll_capture() -> void:
	_compact_scroll_release_queued = false
	var viewport := get_viewport()
	if _tearing_down or not is_inside_tree() or not _adaptive_applied \
			or viewport.gui_is_dragging() \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	var scroll := _node("CompactWorkspace/StashScroll") as ScrollContainer
	if scroll == null or not scroll.is_visible_in_tree():
		return
	var scroll_position := Vector2i(scroll.scroll_horizontal, scroll.scroll_vertical)
	var focus_owner := viewport.gui_get_focus_owner()
	# Wheel buttons are instantaneous, but Godot can retain their GUI capture on
	# a child at a terminal boundary. Toggling only the retained scroller within
	# one deferred idle turn clears that completed capture without rendering a
	# hidden frame or rebuilding slots. Restore the two presentation coordinates
	# explicitly, then ask the viewport to recompute native hover/cursor state at
	# the unchanged physical pointer position.
	scroll.hide()
	scroll.show()
	scroll.scroll_horizontal = scroll_position.x
	scroll.scroll_vertical = scroll_position.y
	if is_instance_valid(focus_owner) and focus_owner.is_visible_in_tree() \
			and focus_owner.focus_mode != Control.FOCUS_NONE:
		focus_owner.grab_focus()
	viewport.update_mouse_cursor_state()

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
	post.visible = true if _live_inventory_binding else bool(_state().get("post_raid", true))
	var move_loot := post.get_node_or_null("MoveLoot") as Button
	var reinsure := post.get_node_or_null("Reinsure") as Button
	var sell_junk := post.get_node_or_null("SellJunk") as Button
	var title := post.get_node_or_null("Title") as Label
	var details := post.get_node_or_null("Details") as Label
	var loot_value := post.get_node_or_null("LootValue") as Label
	_wire_button(move_loot, Callable(self, "_bank_loot"))
	_wire_button(reinsure, Callable(self, "_reinsure"))
	_wire_button(sell_junk, Callable(self, "_sell_junk"))
	_set_live_unavailable(move_loot, "Move the post-raid fixture loot to stash")
	_set_live_unavailable(reinsure, "Re-insure the fixture loadout")
	_set_live_unavailable(sell_junk, "Sell fixture junk")
	if move_loot != null:
		move_loot.text = "MOVE LOOT · UNAVAILABLE" if _live_inventory_binding else "G  MOVE LOOT TO STASH"
	if reinsure != null:
		reinsure.text = "RE-INSURE · UNAVAILABLE" if _live_inventory_binding else "RE-INSURE LOADOUT   $ 340"
	if sell_junk != null:
		sell_junk.text = "SELL JUNK · UNAVAILABLE" if _live_inventory_binding else "SELL JUNK   $ 620"
	if title != null:
		title.text = "LIVE INVENTORY" if _live_inventory_binding else "FIXTURE PREVIEW · SURVIVED"
		title.clip_text = false
		title.autowrap_mode = TextServer.AUTOWRAP_OFF
	if details != null:
		details.text = "POST-RAID ACTIONS UNAVAILABLE" if _live_inventory_binding else "Rail bridge · 24:10 · 2 kills · loot"
	if loot_value != null:
		loot_value.text = "—" if _live_inventory_binding else "$ 8,420"


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
		["HeadSlot", "HEAD", "— empty", "HeadDetail", ""],
		["FaceSlot", "FACE", "— empty", "FaceDetail", ""],
		["ArmorSlot", "ARMOR", "— empty", "ArmorDetail", ""],
		["HeadsetSlot", "HEADSET", "— empty", "HeadsetDetail", ""],
		["SlingSlot", "ON SLING", "AKM · 7.62×39 · 24/30", "SlingDetail", "SlingIcon"],
		["BackSlot", "ON BACK", "Pump shotgun · 12ga · 5/5", "BackDetail", "BackIcon"],
		["LegStrapSlot", "LEG STRAP", "Machete", "LegStrapDetail", "LegStrapIcon"],
		["HolsterSlot", "HOLSTER", "M1911 · .45 · 7/7", "HolsterDetail", "HolsterIcon"],
	]
	var character: Control = _node("CharacterColumn") as Control
	if character == null:
		return
	for entry in slots:
		var slot: Button = character.get_node_or_null(str(entry[0])) as Button
		if slot == null:
			continue
		_wire_button(slot, Callable(self, "_gear_selected").bind(str(entry[1]), str(entry[2])))
		var fixture_detail := str(entry[2])
		if _live_inventory_binding:
			slot.disabled = true
			slot.tooltip_text = "Unavailable in live mode · no confirmed equipment projection"
		else:
			slot.disabled = false
			slot.tooltip_text = ""
		var detail: Label = slot.get_node_or_null(str(entry[3])) as Label
		if detail != null:
			var showing_fixture := _live_inventory_binding and fixture_detail != "— empty"
			detail.text = "FIXTURE · LIVE UNAVAILABLE" if showing_fixture else fixture_detail
			if showing_fixture:
				detail.add_theme_color_override("font_color", U.YELLOW)
			else:
				detail.remove_theme_color_override("font_color")
		if not str(entry[4]).is_empty():
			var icon: TextureRect = slot.get_node_or_null(str(entry[4])) as TextureRect
			if icon != null:
				icon.modulate = Color(1, 1, 1, 0.28) if _live_inventory_binding and fixture_detail != "— empty" else Color.WHITE

	var sling: Button = character.get_node_or_null("SlingSlot") as Button
	if sling != null:
		var compatibility_enter := Callable(self, "_set_compatibility").bind("7.62x39")
		var compatibility_exit := Callable(self, "_clear_compatibility")
		if _live_inventory_binding:
			if sling.mouse_entered.is_connected(compatibility_enter):
				sling.mouse_entered.disconnect(compatibility_enter)
			if sling.mouse_exited.is_connected(compatibility_exit):
				sling.mouse_exited.disconnect(compatibility_exit)
			sling.mouse_default_cursor_shape = Control.CURSOR_ARROW
			sling.tooltip_text = "Unavailable in live mode · no confirmed equipment projection"
		else:
			if not sling.mouse_entered.is_connected(compatibility_enter):
				sling.mouse_entered.connect(compatibility_enter)
			if not sling.mouse_exited.is_connected(compatibility_exit):
				sling.mouse_exited.connect(compatibility_exit)
			sling.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			sling.tooltip_text = "AKM\nShowing compatible ammo + mags\nF · move to stash   RMB · options"
	var gear_hint := character.get_node_or_null("GearHint") as Label
	if gear_hint != null:
		gear_hint.text = "FIXTURE PREVIEW · LIVE EQUIPMENT UNAVAILABLE · HOVER DISABLED" if _live_inventory_binding else "FIXTURE PREVIEW · F QUICK MOVE · R ROTATE · RMB OPTIONS"
		gear_hint.tooltip_text = "No confirmed equipment projection is available; retained gear art is preview-only." if _live_inventory_binding else "FIXTURE PREVIEW · local gear actions are presentation-only; authority state is not connected."
		gear_hint.clip_text = false
		gear_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
		gear_hint.add_theme_color_override("font_color", U.YELLOW if _live_inventory_binding else U.MUTED)


func _bind_loadout() -> void:
	var pockets_size := Vector2i(4, 1)
	var rig_size := Vector2i(6, 2)
	var pack_size := Vector2i(6, 5)
	if _live_inventory_binding and _inventory_controller != null:
		pockets_size = _inventory_controller.grid_size(&"pockets")
		rig_size = _inventory_controller.grid_size(&"rig")
		pack_size = _inventory_controller.grid_size(&"backpack")
	else:
		var inventory: Dictionary = _inventory_data()
		var fixture_rig: Array = inventory.get("rig_size", [6, 2])
		var fixture_pack: Array = inventory.get("backpack_size", [6, 5])
		rig_size = Vector2i(int(fixture_rig[0]), int(fixture_rig[1]))
		pack_size = Vector2i(int(fixture_pack[0]), int(fixture_pack[1]))
	var rig_title: Label = _node("RigTitle") as Label
	if rig_title != null:
		if _live_inventory_binding:
			rig_title.text = "RIG · LIVE · EQUIPMENT PANEL UNAVAILABLE"
		else:
			rig_title.text = "Scav vest   %d×%d · %d slots · 0.8 kg" % [rig_size.x, rig_size.y, rig_size.x * rig_size.y]
	var pack_title: Label = _node("PackTitle") as Label
	if pack_title != null:
		if _live_inventory_binding:
			pack_title.text = "BACKPACK · LIVE · EQUIPMENT PANEL UNAVAILABLE"
		else:
			pack_title.text = "Field pack   %d×%d · %d slots · 11 used · 1.2 kg" % [pack_size.x, pack_size.y, pack_size.x * pack_size.y]
	var pockets_title := _node("PocketsTitle") as Label
	if pockets_title != null:
		pockets_title.text = ("POCKETS · %d×%d · LIVE" % [pockets_size.x, pockets_size.y]) if _live_inventory_binding else "POCKETS · 4 · always on you"
	var weight := _node("LoadoutWeight") as Label
	var value := _node("LoadoutValue") as Label
	if weight != null:
		weight.text = "WEIGHT — · LIVE PROJECTION" if _live_inventory_binding else "WEIGHT 14.2 / 32 kg · VALUE "
	if value != null:
		value.text = "—" if _live_inventory_binding else "$ 9,860"
	_wire_button(_node("RigContainer") as Button, Callable(self, "_container_selected").bind("rig"))
	_wire_button(_node("PackContainer") as Button, Callable(self, "_container_selected").bind("backpack"))
	_wire_button(_node("RigSwap") as Button, Callable(self, "_swap_container").bind("rig"))
	_wire_button(_node("PackSwap") as Button, Callable(self, "_swap_container").bind("backpack"))
	var rig_swap := _node("RigSwap") as Button
	var pack_swap := _node("PackSwap") as Button
	_set_live_unavailable(rig_swap, "Swap the fixture rig")
	_set_live_unavailable(pack_swap, "Swap the fixture backpack")
	if rig_swap != null:
		rig_swap.text = "RIG SWAP · UNAVAILABLE IN LIVE" if _live_inventory_binding else "⇄ SWAP · 3 in stash"
	if pack_swap != null:
		pack_swap.text = "PACK SWAP · UNAVAILABLE IN LIVE" if _live_inventory_binding else "⇄ SWAP · Hiker 7×6 in stash"

	_bind_grid(_node("PocketsGrid") as Control, pockets_size.x, pockets_size.y, "pockets", "pockets")
	_bind_grid(_node("RigGrid") as Control, rig_size.x, rig_size.y, "rig", "rig")
	_bind_grid(_node("PackGrid") as Control, pack_size.x, pack_size.y, "backpack", "backpack")

	var quick_title := _node("QuickUseTitle") as Label
	if quick_title != null:
		quick_title.text = "QUICK USE · LIVE UNAVAILABLE" if _live_inventory_binding else "QUICK USE"
	for index in range(4):
		var slot: Button = _node("QuickSlot%d" % (index + 5)) as Button
		_wire_button(slot, Callable(self, "_quick_slot_used").bind(index))
		if slot != null:
			slot.disabled = _live_inventory_binding
			slot.tooltip_text = "Unavailable in live mode · no confirmed quick item" if _live_inventory_binding else ""
	var count: Label = _node("QuickSlot5/Count") as Label
	if count != null:
		count.text = "—" if _live_inventory_binding else str(_state().get("med_count", 2))


func _bind_stash() -> void:
	var stash_tab: Button = _node("StashTab") as Button
	var loot_tab: Button = _node("LootTab") as Button
	var loot_close: Button = _node("LootClose") as Button
	# Both callbacks rebuild the retained grid and compact geometry. Dispatch
	# them only after Button has completed its native release bookkeeping; doing
	# that work from inside `pressed` can strand GUI mouse capture on the tab.
	_wire_button_deferred(stash_tab, Callable(self, "_set_loot_mode").bind(false))
	_wire_button_deferred(loot_tab, Callable(self, "_set_loot_mode").bind(true))
	_wire_button_deferred(loot_close, Callable(self, "_close_loot_container"))
	if loot_close != null:
		loot_close.visible = _loot_mode
		loot_close.tooltip_text = "Close the current loot container; canonical inventory remains unchanged."
	_apply_mode_style(stash_tab, not _loot_mode)
	_apply_mode_style(loot_tab, _loot_mode)

	var search: LineEdit = _node("StashSearch") as LineEdit
	if search != null:
		if search.text != _search_query: search.text = _search_query
		search.placeholder_text = "Search loot…" if _loot_mode else "Search stash…"
		if not search.text_changed.is_connected(Callable(self, "_on_search_changed")):
			search.text_changed.connect(Callable(self, "_on_search_changed"))
	_wire_button(_node("SortStash") as Button, Callable(self, "_sort_stash"))
	_wire_button(_node("OrganizeStash") as Button, Callable(self, "_organize_stash"))
	_set_live_unavailable(_node("SortStash") as Button, "Sort the fixture stash by value")
	_set_live_unavailable(_node("OrganizeStash") as Button, "Organize the fixture stash")
	var source_key := "loot" if _loot_mode else "stash"
	var source_size := _inventory_controller.grid_size(StringName(source_key)) if _live_inventory_binding and _inventory_controller != null else Vector2i(7, 10)
	var stash_title := _node("StashTitle") as Label
	if stash_title != null:
		# Keep the authored 70px title column intact. The selected crate/corpse is
		# named in the adjacent status label, so the retained title never collides
		# with the summary or the header close affordance.
		stash_title.text = "LOOT" if _loot_mode else "STASH"
	var compatible := _node("StashCompatible") as Label
	if compatible != null:
		compatible.offset_right = 1774.0 if _loot_mode else 1872.0
	var summary := _node("StashSummary") as Label
	if summary != null:
		summary.text = "%d×%d · %s" % [source_size.x, source_size.y, ("LIVE" if _loot_mode else "READ-ONLY")] if _live_inventory_binding else ("LOOT · OPEN" if _loot_mode else "LV 2 · 61 / 70")

	var filter_names: Array[String] = ["all", "guns", "ammo", "armor", "clothing", "food", "util"]
	var filter_nodes: Array[String] = ["All", "Guns", "Ammo", "Armor", "Cloth", "Food", "Util"]
	for index in range(filter_names.size()):
		var filter_button: Button = _node("Filter" + filter_nodes[index]) as Button
		if filter_button == null:
			continue
		filter_button.tooltip_text = "Filter " + filter_names[index]
		filter_button.add_theme_color_override("font_color", U.TEXT if _current_filter == filter_names[index] else U.MUTED)
		_wire_button(filter_button, Callable(self, "_set_filter").bind(filter_names[index]))
	_bind_grid(_node("StashGrid") as Control, 12 if _live_inventory_binding else 7, 20 if _live_inventory_binding else 10, source_key, source_key)


func _bind_grid(grid: Control, columns: int, rows: int, source_key: String, data_key: String) -> void:
	if grid == null or not grid.has_method("set_grid_size"):
		return
	grid.set("source_id", source_key)
	grid.set("binding_token", _active_binding_token if _live_inventory_binding else 0)
	if _live_inventory_binding and _inventory_controller != null:
		var descriptor := _inventory_controller.descriptor(StringName(source_key))
		grid.set("inventory_id", int(descriptor.get("inventory_id", 0)))
		grid.set("container_id", int(descriptor.get("container_id", 0)))
		grid.set("scope", StringName(descriptor.get("scope", "")))
		grid.set("owner_generation", int(descriptor.get("owner_generation", 0)))
		grid.set("scope_generation", int(descriptor.get("scope_generation", 0)))
		var live_size := _inventory_controller.grid_size(StringName(source_key))
		columns = live_size.x
		rows = live_size.y
	grid.set_grid_size(columns, rows, 74)
	var values: Array = _items_for(data_key)
	if source_key in ["stash", "loot"]:
		values = _filtered_items(values)
	grid.set_items(values, _items_for(data_key))
	grid.set_compatibility(_compatibility_key)
	if grid.has_method("set_mutation_enabled"):
		var mutations_available := not _live_inventory_binding or (_inventory_controller != null and (_inventory_controller.loot_mutation_available() if source_key == "loot" else _inventory_controller.mutation_available(StringName(source_key))))
		grid.set_mutation_enabled(mutations_available)
	if grid.has_method("set_operation_availability"):
		var quick_available := not _live_inventory_binding or (_inventory_controller != null and (_inventory_controller.quick_transfer_available(StringName(source_key))))
		var split_available := not _live_inventory_binding or (_inventory_controller != null and _inventory_controller.split_available(StringName(source_key), StringName(source_key)))
		grid.set_operation_availability(quick_available, split_available)
	var hover := Callable(self, "_on_grid_hovered").bind(grid)
	var selected := Callable(self, "_selected_from_grid").bind(grid)
	var context := Callable(self, "_context_from_grid").bind(grid)
	var quick := Callable(self, "_on_quick_move")
	var dropped := Callable(self, "_on_item_dropped").bind(grid)
	var rejected := Callable(self, "_on_drop_rejected")
	var split := Callable(self, "_on_split_requested").bind(grid)
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
	if not grid.split_requested.is_connected(split):
		grid.split_requested.connect(split)
	_grids.append(grid)


func _bind_live_status() -> void:
	var status_label := _node("StashCompatible") as Label
	var compact_hint := _node("CompactWorkspace/InventoryHints") as Label
	if not _live_inventory_binding or _inventory_controller == null:
		if status_label != null:
			# Fixture mode is intentionally interactive, but it must never look like
			# a restored live authority surface. Keep this short enough for the
			# authored 244px desktop label and explicitly replace any retained live
			# tooltip/overflow settings from the bound presentation.
			status_label.text = "FIXTURE PREVIEW"
			status_label.clip_text = false
			status_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			status_label.tooltip_text = "FIXTURE PREVIEW · local authored inventory; authority state is not connected."
			status_label.add_theme_color_override("font_color", U.YELLOW)
			status_label.remove_theme_font_size_override("font_size")
		if compact_hint != null:
			compact_hint.text = "FIXTURE PREVIEW · LOCAL INVENTORY"
			compact_hint.clip_text = false
			compact_hint.autowrap_mode = TextServer.AUTOWRAP_OFF
			compact_hint.tooltip_text = "FIXTURE PREVIEW · local authored inventory; authority state is not connected."
			compact_hint.add_theme_color_override("font_color", U.YELLOW)
		return
	if _loot_mode:
		var loot_status_text := _inventory_controller.loot_status_text()
		var loot_status_detail := _inventory_controller.loot_status_detail()
		var loot_status_color := U.GREEN
		var loot_state := _inventory_controller.loot_container_state()
		if _loot_container_open and not _inventory_controller.is_bound():
			loot_status_text = "DISCONNECTED"
			loot_status_detail = "Inventory authority is disconnected; existing loot data is informational only."
			loot_status_color = U.RED
		else:
			match loot_state:
				InventoryPresentationModel.STATE_NORMAL:
					loot_status_text = "READY · %s" % String(_inventory_controller.loot_container()).to_upper()
				InventoryPresentationModel.STATE_INACCESSIBLE, InventoryPresentationModel.STATE_STALE_CORRECTED, InventoryPresentationModel.STATE_OVERWEIGHT:
					loot_status_color = U.YELLOW
					loot_status_text = "INACCESSIBLE" if loot_state == InventoryPresentationModel.STATE_INACCESSIBLE else ("STALE" if loot_state == InventoryPresentationModel.STATE_STALE_CORRECTED else "OVERWEIGHT")
				InventoryPresentationModel.STATE_RESYNCHRONIZING, InventoryPresentationModel.STATE_DISCONNECTED:
					loot_status_color = U.RED
					loot_status_text = "RESYNC · MUTATIONS DISABLED" if loot_state == InventoryPresentationModel.STATE_RESYNCHRONIZING else "DISCONNECTED"
				InventoryPresentationModel.STATE_LOADING:
					loot_status_text = "LOADING"
		if status_label != null:
			status_label.add_theme_font_size_override("font_size", 9)
		if status_label != null:
			status_label.text = loot_status_text
			status_label.clip_text = true
			status_label.tooltip_text = loot_status_detail
			status_label.add_theme_color_override("font_color", loot_status_color)
		if compact_hint != null:
			compact_hint.text = loot_status_text + "   ·   SEARCH / INSPECT READ-ONLY"
			compact_hint.clip_text = true
			compact_hint.tooltip_text = loot_status_detail
			compact_hint.add_theme_color_override("font_color", loot_status_color)
		return
	var raid_ready := _inventory_controller.mutation_available(&"pockets")
	var profile_ready := _inventory_controller.scope_ready(&"stash")
	var profile_mutable := _inventory_controller.mutation_available(&"stash")
	var available := raid_ready
	var reason := ""
	if not raid_ready:
		reason = str(_inventory_controller.status_reason(&"pockets"))
	elif not profile_ready:
		reason = str(_inventory_controller.status_reason(&"stash"))
	var status_text := ""
	var status_detail := ""
	var status_color := U.RED
	if available and profile_ready and not profile_mutable:
		status_text = "READY · PROFILE READ-ONLY"
		status_detail = "LIVE · RAID MUTATIONS AVAILABLE · PROFILE READ-ONLY"
		status_color = U.GREEN
	elif available and not profile_ready:
		status_text = "READY · PROFILE " + _live_status_short(reason)
		status_detail = "LIVE · RAID MUTATIONS AVAILABLE · PROFILE " + _live_status_detail(reason)
		status_color = U.GREEN
	else:
		status_text = "READY · MUTATIONS AVAILABLE" if available else "MUTATIONS DISABLED · " + _live_status_short(reason)
		status_detail = "LIVE · MUTATIONS AVAILABLE" if available else "LIVE · MUTATIONS DISABLED · " + _live_status_detail(reason)
		status_color = U.GREEN if available else U.RED
	if status_label != null:
		status_label.text = status_text
		status_label.clip_text = true
		status_label.tooltip_text = status_detail
		status_label.add_theme_color_override("font_color", status_color)
		status_label.remove_theme_font_size_override("font_size")
	if compact_hint != null:
		compact_hint.text = status_text + "   ·   FILTER / SEARCH / TOOLTIP READ-ONLY"
		compact_hint.clip_text = true
		compact_hint.tooltip_text = status_detail
		compact_hint.add_theme_color_override("font_color", status_color)


func _live_status_short(reason: String) -> String:
	match reason.to_lower():
		"inventory_loading":
			return "LOADING"
		"inventory_resynchronizing":
			return "RESYNC"
		"inventory_stale":
			return "STALE"
		"inventory_disconnected", "inventory_runtime_unbound":
			return "DISCONNECTED"
		"profile_inventory_read_only":
			return "PROFILE READ-ONLY"
	return "UNAVAILABLE"


func _live_status_detail(reason: String) -> String:
	match reason.to_lower():
		"inventory_loading":
			return "inventory is loading; mutations are paused"
		"inventory_resynchronizing":
			return "inventory is resynchronizing; mutations are paused"
		"inventory_stale":
			return "inventory data is stale; mutations are paused"
		"inventory_disconnected", "inventory_runtime_unbound":
			return "inventory is disconnected; authority state is unavailable"
		"profile_inventory_read_only":
			return "profile inventory is read-only"
	return "inventory is unavailable; authority state is unchanged"


func _set_live_unavailable(button: Button, fixture_tooltip: String) -> void:
	if button == null:
		return
	button.disabled = _live_inventory_binding
	button.tooltip_text = "Unavailable in live mode" if _live_inventory_binding else fixture_tooltip


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
	for path in ["HealthTab", "GearTab", "StatsTab", "StashTab", "LootTab", "LootClose", "SortStash", "OrganizeStash"]:
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


func _wire_button_deferred(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback, CONNECT_DEFERRED)


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
	var live_notice := area.get_node_or_null("LiveFixtureNotice") as Label
	if _live_health_binding:
		_bind_live_health(area, live_notice)
		return
	if live_notice != null:
		live_notice.visible = _live_inventory_binding
	var treated: bool = bool(_state().get("quick_healed", false))
	_set_health_card(area, "HeadCard", "HEAD", "55%", "Concussed · 0:42", U.YELLOW, 55.0)
	_set_health_card(area, "TorsoCard", "TORSO", "68%" if treated else "20%", "Stabilized · 0:18" if treated else "Heavy bleed · −3/s", U.GREEN if treated else U.RED, 68.0 if treated else 20.0)
	_set_health_card(area, "ArmsCard", "ARMS", "92%", "No effects", U.GREEN, 92.0)
	_set_health_card(area, "LegsCard", "LEGS", "50%", "Fracture · slowed", U.YELLOW, 50.0)
	_set_meter(area, "Health", "HEALTH", "476/700" if treated else "190/700", 68.0 if treated else 27.0, U.GREEN if treated else U.RED)
	_set_meter(area, "Energy", "ENERGY", "64/100", 64.0, U.YELLOW)
	_set_meter(area, "Hydration", "HYDRATION", "22/100", 22.0, U.BLUE)
	var quick_heal := _node("HealthColumn/QuickHeal") as Button
	_wire_button(quick_heal, Callable(self, "_quick_heal"))
	_set_live_unavailable(quick_heal, "Use the fixture quick-heal preview")


func _bind_live_health(area: Control, live_notice: Label) -> void:
	var view := _health_view
	var ready := view != null and view.is_ready()
	if live_notice != null:
		live_notice.visible = true
		live_notice.mouse_filter = Control.MOUSE_FILTER_STOP
		live_notice.mouse_default_cursor_shape = Control.CURSOR_HELP
		live_notice.text = "LIVE HEALTH · CONFIRMED" if ready else "LIVE HEALTH · %s" % (
			String(view.sync_state_name()).to_upper() if view != null else "UNAVAILABLE")
		live_notice.tooltip_text = "Immutable HealthView · generation %d · revision %d" % [
			view.generation(), view.revision()] if ready else (
			String(view.diagnostic()).replace("_", " ") if view != null else "Health projection unavailable")
		live_notice.add_theme_color_override("font_color", U.GREEN if ready else U.RED)
	var quick_heal := area.get_node_or_null("QuickHeal") as Button
	if quick_heal != null:
		quick_heal.disabled = true
		quick_heal.tooltip_text = "Unavailable · task 5.7 has not connected a quick-heal intent"
	if not ready:
		var reason := String(view.sync_state_name()).to_upper() if view != null else "UNAVAILABLE"
		for card in ["HeadCard", "TorsoCard", "ArmsCard", "LegsCard"]:
			_set_health_card(area, card, card.trim_suffix("Card").to_upper(), "—", reason, U.RED, 0.0)
		_set_meter(area, "Health", "HEALTH", "—/—", 0.0, U.RED)
		_set_meter(area, "Energy", "ENERGY", "—/—", 0.0, U.YELLOW)
		_set_meter(area, "Hydration", "HYDRATION", "—/—", 0.0, U.BLUE)
		_set_health_effect_badges(area, [])
		return

	var groups := {
		"HeadCard": _aggregate_health_parts(view, [&"head"]),
		"TorsoCard": _aggregate_health_parts(view, [&"thorax", &"abdomen"]),
		"ArmsCard": _aggregate_health_parts(view, [&"left_arm", &"right_arm"]),
		"LegsCard": _aggregate_health_parts(view, [&"left_leg", &"right_leg"]),
	}
	var labels := {
		"HeadCard": "HEAD",
		"TorsoCard": "TORSO",
		"ArmsCard": "ARMS",
		"LegsCard": "LEGS",
	}
	for card in groups:
		var group := groups[card] as Dictionary
		var maximum := int(group.get("maximum", 0))
		var current := int(group.get("current", 0))
		var percent := 100.0 * float(current) / float(maximum) if maximum > 0 else 0.0
		var color := U.RED if percent < 30.0 else (U.YELLOW if percent < 70.0 else U.GREEN)
		_set_health_card(
			area, card, labels[card], "%d%%" % roundi(percent),
			str(group.get("detail", "No effects")), color, percent)
	var total_percent := 100.0 * float(view.current_health()) / float(view.maximum_health())
	_set_meter(area, "Health", "HEALTH", "%d/%d" % [
		view.current_health(), view.maximum_health()], total_percent,
		U.RED if total_percent < 30.0 else (U.YELLOW if total_percent < 70.0 else U.GREEN))
	var energy_percent := 100.0 * float(view.energy()) / float(view.maximum_energy())
	_set_meter(area, "Energy", "ENERGY", "%d/%d" % [
		view.energy(), view.maximum_energy()], energy_percent, U.YELLOW)
	var hydration_percent := 100.0 * float(view.hydration()) / float(view.maximum_hydration())
	_set_meter(area, "Hydration", "HYDRATION", "%d/%d" % [
		view.hydration(), view.maximum_hydration()], hydration_percent, U.BLUE)
	_set_health_effect_badges(area, view.effects())


func _aggregate_health_parts(view: HealthView, identifiers: Array[StringName]) -> Dictionary:
	var current := 0
	var maximum := 0
	var heavy_bleed := false
	var fractured := false
	var destroyed := false
	var injured := false
	for part in view.body_parts():
		if not identifiers.has(part.part_id()):
			continue
		current += part.current_health()
		maximum += part.maximum_health()
		heavy_bleed = heavy_bleed or part.has_heavy_bleed()
		fractured = fractured or part.is_fractured()
		destroyed = destroyed or part.state() == HealthView.BodyPartState.DESTROYED
		injured = injured or part.state() == HealthView.BodyPartState.INJURED
	var details: Array[String] = []
	if destroyed:
		details.append("Destroyed")
	if heavy_bleed:
		details.append("Heavy bleed")
	if fractured:
		details.append("Fracture")
	if injured and details.is_empty():
		details.append("Injured")
	return {
		"current": current,
		"maximum": maximum,
		"detail": " · ".join(PackedStringArray(details)) if not details.is_empty() else "No effects",
	}


func _set_health_effect_badges(area: Control, effects: Array) -> void:
	var ordered := effects.duplicate()
	ordered.sort_custom(_health_effect_precedes)
	var badge_names := ["DehydratedBadge", "RadiationBadge"]
	var body_wide := area.get_node_or_null("BodyWide") as Label
	if body_wide != null:
		body_wide.text = "BODY-WIDE · %d" % ordered.size() if not ordered.is_empty() \
			else "BODY-WIDE"
		body_wide.mouse_filter = Control.MOUSE_FILTER_STOP
		body_wide.mouse_default_cursor_shape = Control.CURSOR_HELP
		body_wide.tooltip_text = _health_effects_tooltip(ordered) \
			if not ordered.is_empty() else "No body-wide effects"
	for index in range(badge_names.size()):
		var badge := area.get_node_or_null(badge_names[index]) as Panel
		if badge == null:
			continue
		badge.visible = index < ordered.size()
		badge.mouse_filter = Control.MOUSE_FILTER_STOP
		badge.mouse_default_cursor_shape = Control.CURSOR_HELP
		if not badge.visible:
			badge.tooltip_text = ""
			continue
		var effect := ordered[index] as HealthView.StatusEffect
		var displayed_effects: Array = [effect]
		var aggregate := index == badge_names.size() - 1 \
			and ordered.size() > badge_names.size()
		if aggregate:
			displayed_effects = ordered.slice(index)
		var tooltip := _health_effects_tooltip(displayed_effects)
		var color := _health_effect_aggregate_color(displayed_effects)
		badge.tooltip_text = tooltip
		badge.add_theme_stylebox_override(
			"panel", U.style(U.PANEL.lerp(color, 0.08), color, 1))
		var label := badge.get_node_or_null("Text") as Label
		if label != null:
			label.text = "■  %d MORE EFFECTS" % displayed_effects.size() if aggregate \
				else "■  %s" % effect.display_name().to_upper()
			label.tooltip_text = tooltip
			label.mouse_filter = Control.MOUSE_FILTER_PASS
			label.mouse_default_cursor_shape = Control.CURSOR_HELP
			label.clip_text = true
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			label.offset_right = badge.size.x - 8.0
			label.add_theme_color_override("font_color", color)
		var edge := badge.get_node_or_null("Edge") as ColorRect
		if edge != null:
			edge.color = color


func _health_effect_precedes(left: HealthView.StatusEffect, right: HealthView.StatusEffect) -> bool:
	if left.severity() != right.severity():
		return left.severity() > right.severity()
	if left.is_beneficial() != right.is_beneficial():
		return not left.is_beneficial()
	return String(left.effect_id()) < String(right.effect_id())


func _health_effects_tooltip(effects: Array) -> String:
	var lines: Array[String] = []
	for value in effects:
		var effect := value as HealthView.StatusEffect
		if effect == null:
			continue
		lines.append("%s · %s · %d ticks remaining%s" % [
			effect.display_name(),
			_health_effect_severity_name(effect.severity()),
			effect.remaining_ticks(),
			" · beneficial" if effect.is_beneficial() else "",
		])
	return "\n".join(PackedStringArray(lines))


func _health_effect_severity_name(severity: HealthView.Severity) -> String:
	match severity:
		HealthView.Severity.CRITICAL:
			return "Critical"
		HealthView.Severity.MAJOR:
			return "Major"
		HealthView.Severity.MINOR:
			return "Minor"
	return "Info"


func _health_effect_aggregate_color(effects: Array) -> Color:
	var has_beneficial := false
	var harmful_severity := -1
	for value in effects:
		var effect := value as HealthView.StatusEffect
		if effect == null:
			continue
		if effect.is_beneficial():
			has_beneficial = true
		else:
			harmful_severity = maxi(harmful_severity, int(effect.severity()))
	if harmful_severity >= HealthView.Severity.MAJOR:
		return U.RED
	if harmful_severity == HealthView.Severity.MINOR:
		return U.YELLOW
	if harmful_severity == HealthView.Severity.INFO:
		return U.BLUE
	return U.GREEN if has_beneficial else U.MUTED


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
	var live_notice := stats.get_node_or_null("LiveFixtureNotice") as Label
	if live_notice != null:
		live_notice.visible = _live_inventory_binding
	# Stats are authored presentation values in this prototype. Keep the
	# authored hierarchy stable while allowing the shared state to control the
	# compact section and all actions around it.
