extends "res://tests/visual/inventory_ui_binding/native_drag_probe.gd"
## HISTORICAL / DEFERRED compact native selection probe; not a current runner.
## Regression for compact pointer continuity across model-driven refresh.
## One native 960x540 runtime reaches both canonical terminal scroll extents,
## returns to the corpse origin, then selects Bandage through a real Button click.

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: compact_native_selection_probe is historical; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)


func _wheel_to(scroll: ScrollContainer, vertical: int, horizontal: int) -> void:
	var position := scroll.get_global_rect().get_center()
	var focus_before := root.gui_get_focus_owner()
	var hover_before := root.gui_get_hovered_control()
	for _index in range(36):
		_native_wheel(position, vertical)
		_native_wheel(position, horizontal)
	var visible_every_frame := true
	for _frame in range(6):
		await process_frame
		visible_every_frame = visible_every_frame and scroll.is_visible_in_tree()
	check(visible_every_frame,
		"compact scroller remains visible across every rendered settle frame")
	check(root.gui_get_focus_owner() == focus_before,
		"compact wheel travel preserves the prior keyboard focus owner")
	check(root.gui_get_hovered_control() == hover_before,
		"compact wheel capture release restores the prior physical-pointer hover owner")


func _assert_terminal(scroll: ScrollContainer, grid: Control, expected_size: Vector2) -> void:
	var page := Vector2(
		scroll.get_h_scroll_bar().page,
		scroll.get_v_scroll_bar().page)
	check(grid.size == expected_size and grid.cell_size == 74,
		"compact native selection keeps canonical extent " + str(expected_size))
	check(Vector2(scroll.scroll_horizontal, scroll.scroll_vertical) + page == expected_size,
		"native wheel reaches exact terminal without assigned offsets " + str(expected_size))
	var last_cell_center := grid.global_position + expected_size - Vector2(37, 37)
	check(scroll.get_global_rect().has_point(last_cell_center),
		"native terminal exposes final canonical cell center " + str(expected_size))


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Compact native selection regression requires the graphical renderer")
		quit(1)
		return
	root.borderless = true
	root.position = Vector2i.ZERO
	var opened: bool = await _open_bound_runtime(
		Vector2i(960, 540), "960x540_compact_native_selection")
	check(opened and is_instance_valid(screen),
		"compact native selection runtime opens with production dependencies")
	if opened and is_instance_valid(screen):
		check(app.ui_layout_mode == "auto" and screen._adaptive_applied,
			"960x540 uses the automatic compact policy")
		var request_count := adapter.tracked_request_count()
		var corpse_bytes := bridge.confirmed_snapshot(
			&"raid", owner.corpse_inventory_id).canonical_bytes()

		await _native_click(screen._node("CompactWorkspace/Section_stash"))
		var scroll := screen._node("CompactWorkspace/StashScroll") as ScrollContainer
		var grid := screen._node("StashGrid") as Control
		check(is_instance_valid(scroll) and is_instance_valid(grid),
			"compact stash exposes its retained native scroll and grid controls")
		if is_instance_valid(scroll) and is_instance_valid(grid):
			await _wheel_to(scroll, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT)
			_assert_terminal(scroll, grid, Vector2(888, 1480))

			# Source selection is explicit lifecycle configuration; tab selection and
			# every scroll/click below still travel through native Godot Controls.
			controller.set_loot_container(&"corpse")
			var loot_tab := screen._node("LootTab") as Control
			await _native_click(loot_tab)
			check(screen._loot_mode and str(grid.source_id) == "loot",
				"native Loot tab switches the retained grid to the selected corpse source")
			await _wheel_to(scroll, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT)
			check(scroll.scroll_horizontal == 0 and scroll.scroll_vertical == 0,
				"native wheel returns the corpse grid to its origin")
			await _wheel_to(scroll, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT)
			_assert_terminal(scroll, grid, Vector2(740, 592))
			await _wheel_to(scroll, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT)

			var bandage := _find_definition(
				controller.items_for(&"corpse"), str(Catalog.ITEM_BANDAGE))
			var bandage_id := int(bandage.get("item_id", 0))
			var slot := _slot_for_item(grid, bandage_id)
			check(is_instance_valid(slot)
				and scroll.get_global_rect().has_point(slot.get_global_rect().get_center()),
				"native return travel exposes the exact Bandage slot")
			if is_instance_valid(slot):
				await _native_click(slot)
			check(int(screen._selected_live_item.get("item_id", 0)) == bandage_id,
				"native compact click selects the exact Bandage identity")
			check(root.gui_get_focus_owner() == slot,
				"native compact Bandage click retains usable slot focus")
			check(is_instance_valid(screen._tooltip)
				and Rect2(Vector2.ZERO, Vector2(960, 540)).encloses(
					screen._tooltip.get_global_rect()),
				"native compact Bandage click opens an on-screen tooltip")
			check(adapter.tracked_request_count() == request_count
				and bridge.confirmed_snapshot(
					&"raid", owner.corpse_inventory_id).canonical_bytes() == corpse_bytes,
				"compact scroll, selection, focus, and tooltip remain presentation-only")

	await _teardown_flow_runtime()
	print("COMPACT_NATIVE_SELECTION_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
