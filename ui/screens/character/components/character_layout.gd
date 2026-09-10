extends RefCounted
## Reflow the same authored controls into native, intrinsic-size scroll panes.
## Membership is explicit: no coordinate-based discovery or replacement trees.

static func place(view: Control, path: String, parent: Control, rect: Rect2) -> Control:
	var node: Control = view._node(path)
	if node.get_parent() != parent: node.reparent(parent, false)
	node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	node.position = rect.position
	node.size = rect.size
	node.show()
	return node

static func apply(view: Control, bounds: Vector2) -> void:
	var surface: Control = view._surface
	var workspace: Control = view._node("CompactWorkspace")
	for node in surface.get_children():
		# The retained compact workspace owns active native pointer gestures. A live
		# projection refresh can arrive between mouse-down and mouse-up (for example,
		# when hover selection changes). Hiding and immediately re-showing that same
		# ancestor cancels Godot's Button press even though the slot keeps focus.
		# Only hide authored desktop siblings; keep the active workspace continuously
		# visible so repeated compact reflow is an idempotent geometry reconciliation.
		# The tooltip is a retained overlay owned by the screen, not an authored
		# desktop sibling. Keep this one explicit overlay visible across an accepted
		# projection refresh so its selection/position can be restored below. Closed
		# or invalid tooltips have already been nulled by _close_tip and remain hidden.
		if node is Control and node != workspace and node != view._tooltip:
			node.hide()
	if not workspace.visible:
		workspace.show()
	workspace.size = bounds
	var wide := bounds.x >= 1180
	var margin: float = 24 if wide else 16
	var width := bounds.x - margin * 2
	var post := place(view, "PostRaidBar", surface, Rect2(margin, 68, width, 36))
	post.visible = true if view._live_inventory_binding else bool(view._state().get("post_raid", true))
	view._node("PostRaidBar/Details").hide()
	var raid_title := place(view, "PostRaidBar/Title", post, Rect2(12, 4, 290, 28))
	ZLayoutSnapshot.layout_value(raid_title, "text", "LIVE INVENTORY · ACTIONS UNAVAILABLE" if view._live_inventory_binding else "FIXTURE PREVIEW · SURVIVED")
	ZLayoutSnapshot.layout_value(raid_title, "theme_override_font_sizes/font_size", 12)
	raid_title.clip_text = false
	raid_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	view._node("PostRaidBar/LootValue").hide()
	for i in range(3):
		place(view, "PostRaidBar/" + ["MoveLoot", "Reinsure", "SellJunk"][i], post, Rect2(width - 544 + i * 180, 4, 172, 28))
	if not wide:
		width = minf(width, 640)
		margin = (bounds.x - width) / 2
	var left_width := floorf((width - 16) / 2) if wide else width
	var right_width := width - left_width - 16 if wide else width
	var right_x := margin + left_width + 16 if wide else margin
	var bottom := bounds.y - 48
	# On a wide compact layout the stash is already visible beside loadout. Use
	# loadout as the effective left pane without destroying the remembered stash
	# section needed when the viewport becomes narrow again.
	var active_section: String = "loadout" if wide and view._compact_section == "stash" else view._compact_section
	var sections := ["loadout", "gear", "health", "stats"] if wide else ["loadout", "stash", "gear", "health", "stats"]
	for section in ["loadout", "stash", "gear", "health", "stats"]:
		var tab: Button = view._node("CompactWorkspace/Section_" + section)
		tab.visible = sections.has(section)
		var step: float = 104 if wide else 92
		tab.position = Vector2(margin + sections.find(section) * step, 116)
		tab.size = Vector2(step - 4, 36)
		tab.variant = "primary" if section == active_section else "secondary"
	var loadout_scroll: ScrollContainer = place(view, "CompactWorkspace/LoadoutScroll", workspace, Rect2(margin, 164, left_width, bottom - 164))
	var loadout: Control = view._node("CompactWorkspace/LoadoutScroll/Content")
	loadout_scroll.visible = active_section == "loadout"
	var weight := place(view, "LoadoutWeight", loadout, Rect2(0, 0, 240, 24))
	ZLayoutSnapshot.layout_value(weight, "text", "WEIGHT — · LIVE PROJECTION" if view._live_inventory_binding else "WEIGHT 14.2 / 32 kg")
	ZLayoutSnapshot.layout_value(weight, "horizontal_alignment", HORIZONTAL_ALIGNMENT_LEFT)
	ZLayoutSnapshot.layout_value(weight, "theme_override_font_sizes/font_size", 11)
	var value := place(view, "LoadoutValue", loadout, Rect2(320, 0, 198, 24))
	ZLayoutSnapshot.layout_value(value, "text", "VALUE —" if view._live_inventory_binding else "VALUE $ 9,860")
	ZLayoutSnapshot.layout_value(value, "theme_override_font_sizes/font_size", 11)
	place(view, "PocketsTitle", loadout, Rect2(0, 36, 300, 24))
	var pockets_grid: Control = view._node("PocketsGrid")
	place(view, "PocketsGrid", loadout, Rect2(0, 68, 296, pockets_grid.custom_minimum_size.y if pockets_grid != null else 74))
	# Pockets are canonical 4x2 at 74px cells in live mode.  Follow their
	# actual intrinsic extent and retain the authored compact 16px section gap;
	# never derive the next header from the former one-row fixture height.
	var pockets_extent := pockets_grid.size.y if pockets_grid != null else 74.0
	var cursor := 68.0 + pockets_extent + 16.0
	for prefix in ["Rig", "Pack"]:
		var grid: Control = view._node(prefix + "Grid")
		var select: Button = place(view, prefix + "Container", loadout, Rect2(0, cursor, 340, 36))
		ZLayoutSnapshot.button_variant(select, "secondary")
		for child in view._node(prefix + "Container").get_children():
			if child is Control: child.hide()
		var title := place(view, prefix + "Title", loadout, Rect2(10, cursor, 324, 36))
		var container_name := ("LIVE · UNAVAILABLE" if view._live_inventory_binding else ("Scav vest" if prefix == "Rig" else "Field pack"))
		ZLayoutSnapshot.layout_value(title, "text", ("%s · %s   %d×%d" % ["RIG" if prefix == "Rig" else "PACK", container_name, grid.grid_columns, grid.grid_rows]))
		ZLayoutSnapshot.layout_value(title, "theme_override_font_sizes/font_size", 12)
		title.clip_text = true
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var swap: Button = place(view, prefix + "Swap", loadout, Rect2(352, cursor, 166, 36))
		ZLayoutSnapshot.button_variant(swap, "secondary")
		ZLayoutSnapshot.layout_value(swap, "text", "UNAVAILABLE · LIVE" if view._live_inventory_binding else "SWAP CONTAINER")
		ZLayoutSnapshot.layout_value(swap, "theme_override_font_sizes/font_size", 10)
		cursor += 44
		place(view, prefix + "Grid", loadout, Rect2(Vector2(0, cursor), grid.custom_minimum_size))
		cursor += grid.custom_minimum_size.y + 24
	place(view, "QuickUseTitle", loadout, Rect2(0, cursor, 180, 24))
	for i in range(4):
		place(view, "QuickSlot%d" % (i + 5), loadout, Rect2(i * 76, cursor + 32, 68, 68))
	loadout.custom_minimum_size = Vector2(518, cursor + 120)
	var character_scroll := place(view, "CompactWorkspace/CharacterScroll", workspace, Rect2(margin, 164, left_width, bottom - 164))
	var character: Control = view._node("CompactWorkspace/CharacterScroll/Content")
	character_scroll.visible = active_section in ["gear", "health", "stats"]
	for entry in [["gear", "CharacterColumn"], ["health", "HealthColumn"], ["stats", "StatsColumn"]]:
		var column := place(view, entry[1], character, Rect2(maxf(0, (left_width - 496) / 2), 0, 480, 836))
		column.visible = active_section == entry[0]
	var heal := place(view, "HealthColumn/QuickHeal", workspace, Rect2(margin + left_width - 154, 116, 154, 36))
	heal.name = "PinnedQuickHeal"
	heal.visible = active_section == "health"
	var stash := place(view, "CompactWorkspace/CompactStash", workspace, Rect2(right_x, 116 if wide else 164, right_width, bottom - (116 if wide else 164)))
	stash.visible = wide or view._compact_section == "stash"
	place(view, "StashTitle", stash, Rect2(0, 0, 100, 28))
	place(view, "StashSummary", stash, Rect2(right_width - 200, 0, 184, 28))
	place(view, "StashTab", stash, Rect2(0, 40, 76, 32))
	place(view, "LootTab", stash, Rect2(84, 40, 76, 32))
	place(view, "StashSearch", stash, Rect2(168, 40, right_width - 168, 32))
	place(view, "SortStash", stash, Rect2(0, 80, 152, 32))
	place(view, "OrganizeStash", stash, Rect2(160, 80, 120, 32))
	place(view, "StashCompatible", stash, Rect2(296, 80, right_width - 296, 32))
	var categories := ["All", "Guns", "Ammo", "Armor", "Cloth", "Food", "Util"]
	var category_width := minf(80, (right_width - 24) / 7)
	for i in range(categories.size()):
		var button := place(view, "Filter" + categories[i], stash, Rect2(i * (category_width + 4), 124, category_width, 28))
		button.icon = null
	var stash_scroll := place(view, "CompactWorkspace/StashScroll", stash, Rect2(0, 164, right_width, stash.size.y - 164))
	var stash_grid: Control = view._node("StashGrid")
	var stash_size := stash_grid.custom_minimum_size if stash_grid != null else Vector2(518, 740)
	var stash_content: Control = view._node("CompactWorkspace/StashScroll/Content")
	# ScrollContainer derives its native range from its direct child's minimum,
	# not a grandchild's size. Mirror the exact canonical grid extent here so
	# both axes can reach the final stash/crate/corpse cell without changing the
	# retained outer pane geometry.
	stash_content.custom_minimum_size = stash_size
	stash_content.size = stash_size
	place(view, "StashGrid", stash_content, Rect2(Vector2.ZERO, stash_size))
	stash_scroll.show()
	place(view, "CompactWorkspace/InventoryHints", workspace, Rect2(margin, bounds.y - 36, width, 24))
