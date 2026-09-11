extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical compact inventory QA is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

## Native compact inspection after transient toast timeouts, including corpse.
func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	await _open_bound_runtime(Vector2i(960, 540), "960x540_compact_visual")
	var stack := _find_stack_item(controller.items_for(&"corpse"))
	check(controller.submit_drop(&"corpse", &"pockets", stack, Vector2i.ZERO).accepted, "compact visual precondition seeds confirmed ammunition")
	await create_timer(3.7).timeout
	await _capture_flow("loadout_clear")
	var pockets := screen._node("PocketsGrid") as Control
	var rig := screen._node("RigContainer") as Control
	check(is_equal_approx(rig.global_position.y-pockets.get_global_rect().end.y, 16.0), "native compact loadout has the required 16px section gap")
	var slot := _slot_for_item(pockets, int(stack.item_id))
	motion(Vector2(950,530), Vector2.ZERO)
	slot.grab_focus()
	_native_key(KEY_ENTER)
	await settle(3)
	check(screen._tooltip != null and Rect2(Vector2.ZERO,Vector2(960,540)).encloses(screen._tooltip.get_global_rect()), "edge tooltip is bounded inside the real 960x540 output")
	await _capture_flow("edge_tooltip_clear")
	screen._close_tip()
	controller.set_loot_container(&"corpse")
	screen._set_loot_mode(true)
	await _native_click(screen._node("CompactWorkspace/Section_stash"))
	await create_timer(3.7).timeout
	var scroll := screen._node("CompactWorkspace/StashScroll") as ScrollContainer
	var grid := screen._node("StashGrid") as Control
	var outer := scroll.get_global_rect()
	await _capture_flow("corpse_top_left")
	for index in range(36):
		_native_wheel(scroll.get_global_rect().get_center(),MOUSE_BUTTON_WHEEL_DOWN)
		_native_wheel(scroll.get_global_rect().get_center(),MOUSE_BUTTON_WHEEL_RIGHT)
	await settle(5)
	var page := Vector2(scroll.get_h_scroll_bar().page,scroll.get_v_scroll_bar().page)
	check(grid.size == Vector2(740,592) and grid.cell_size == 74, "corpse keeps the canonical 10x8 intrinsic grid")
	check(scroll.scroll_horizontal + page.x >= 740 and scroll.scroll_vertical + page.y >= 592, "native wheel reaches both corpse terminal edges")
	check(scroll.get_global_rect() == outer, "corpse wheel leaves the outer pane unchanged")
	await _capture_flow("corpse_bottom_right", {"scroll":[scroll.scroll_horizontal,scroll.scroll_vertical],"page":str(page),"outer":str(outer)})
	await _teardown_flow_runtime()
	print("ASTRA_COMPACT_VISUAL_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
