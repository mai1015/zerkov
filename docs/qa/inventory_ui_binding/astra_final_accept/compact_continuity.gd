extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"
## One independently constructed compact runtime: both native scroll ranges,
## then native selection/search/tooltip with unchanged authoritative state.

func wheel_to(scroll: ScrollContainer, vertical: int, horizontal: int) -> void:
	for index in range(36):
		_native_wheel(scroll.get_global_rect().get_center(), vertical)
		_native_wheel(scroll.get_global_rect().get_center(), horizontal)
	await settle(6)

func assert_terminal(scroll: ScrollContainer, grid: Control, size: Vector2) -> void:
	var page := Vector2(scroll.get_h_scroll_bar().page, scroll.get_v_scroll_bar().page)
	check(grid.size == size and grid.cell_size == 74, "independent compact canonical cell extent " + str(size))
	check(Vector2(scroll.scroll_horizontal,scroll.scroll_vertical) + page == size, "native wheel reaches exact terminal x/y without assigned offsets " + str(size))
	var last_cell := grid.global_position + size - Vector2(37,37)
	check(scroll.get_global_rect().has_point(last_cell), "native terminal contains final canonical cell center " + str(size))

func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	await _open_bound_runtime(Vector2i(960,540), "960x540_compact_continuity")
	check(app.ui_layout_mode == "auto" and screen._adaptive_applied, "fresh compact runtime uses automatic policy")
	var requests := adapter.tracked_request_count()
	var corpse_bytes := bridge.confirmed_snapshot(&"raid",owner.corpse_inventory_id).canonical_bytes()
	await _native_click(screen._node("CompactWorkspace/Section_stash"))
	var scroll := screen._node("CompactWorkspace/StashScroll") as ScrollContainer
	var grid := screen._node("StashGrid") as Control
	var outer := scroll.get_global_rect()
	await wheel_to(scroll,MOUSE_BUTTON_WHEEL_DOWN,MOUSE_BUTTON_WHEEL_RIGHT)
	assert_terminal(scroll,grid,Vector2(888,1480))
	await _capture_flow("stash_terminal",{"scroll":[scroll.scroll_horizontal,scroll.scroll_vertical],"page":[scroll.get_h_scroll_bar().page,scroll.get_v_scroll_bar().page]})
	# Corpse selection is explicit source/lifecycle configuration. The following
	# tab click and all travel use the retained native Controls and wheel events.
	controller.set_loot_container(&"corpse")
	await _native_click(screen._node("LootTab"))
	await wheel_to(scroll,MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_LEFT)
	check(scroll.scroll_horizontal == 0 and scroll.scroll_vertical == 0, "corpse native wheel resets both axes before terminal proof")
	await _capture_flow("corpse_origin")
	await wheel_to(scroll,MOUSE_BUTTON_WHEEL_DOWN,MOUSE_BUTTON_WHEEL_RIGHT)
	assert_terminal(scroll,grid,Vector2(740,592))
	check(scroll.get_global_rect() == outer, "stash/corpse travel preserves one retained outer pane")
	await _capture_flow("corpse_terminal",{"scroll":[scroll.scroll_horizontal,scroll.scroll_vertical],"page":[scroll.get_h_scroll_bar().page,scroll.get_v_scroll_bar().page]})
	await wheel_to(scroll,MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_LEFT)
	var bandage := _find_definition(controller.items_for(&"corpse"),str(Catalog.ITEM_BANDAGE))
	var slot := _slot_for_item(grid,int(bandage.get("item_id",0)))
	check(slot != null and scroll.get_global_rect().has_point(slot.get_global_rect().get_center()), "native return travel exposes exact bandage slot")
	await _native_click(slot)
	check(int(screen._selected_live_item.get("item_id",0)) == int(bandage.item_id) and root.gui_get_focus_owner() == slot, "native compact selection retains exact item and usable focus")
	check(screen._tooltip != null and Rect2(Vector2.ZERO,Vector2(960,540)).encloses(screen._tooltip.get_global_rect()), "native compact selected tooltip remains within output after both scroll flows")
	await create_timer(3.7).timeout
	await _capture_flow("selected_tooltip")
	screen._close_tip()
	await _native_click(screen._node("StashSearch"))
	await _native_type("bandage")
	check(screen._search_query == "bandage" and grid.items.size() == 1 and grid.occupancy_items.size() == controller.items_for(&"corpse").size(), "native compact search preserves full canonical occupancy")
	check(root.gui_get_focus_owner() == screen._node("StashSearch") and int(screen._selected_live_item.get("item_id",0)) == int(bandage.item_id), "native compact search focus and exact selection remain usable")
	check(adapter.tracked_request_count() == requests and bridge.confirmed_snapshot(&"raid",owner.corpse_inventory_id).canonical_bytes() == corpse_bytes, "compact scrolling/selection/search/tooltip submit zero commands and change no authority bytes")
	await _capture_flow("typed_search")
	await _teardown_flow_runtime()
	var file := FileAccess.open(FLOW_OUTPUT + "/compact_continuity.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"failures":failures,"records":flow_records},"\t") + "\n")
	file.close()
	print("ASTRA_COMPACT_CONTINUITY_COMPLETE checks=%d failures=%d" % [checks,failures])
	quit(1 if failures > 0 else 0)
