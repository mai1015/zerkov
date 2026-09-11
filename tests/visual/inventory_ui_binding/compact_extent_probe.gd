extends "res://tests/visual/inventory_ui_binding/capture.gd"
## HISTORICAL / DEFERRED compact extent probe; do not run from current
## first-playable verification until task 11.8 or a later approved proposal.
## Independent extent and reachability assertions against automatic compact.

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: compact_extent_probe is historical; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

func run() -> void:
	root.size = Vector2i(960, 540)
	setup_runtime()
	app = load("res://ui/main.tscn").instantiate()
	app.initial_route = "inventory"
	root.add_child(app)
	await settle(15)
	screen = app.screen
	screen._inventory_controller = controller
	check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "extent screen binds")
	await settle()
	check(screen._adaptive_applied and app.ui_layout_mode == "auto", "960x540 uses automatic compact")
	var pockets: Control = screen._node("PocketsGrid")
	var rig_header: Control = screen._node("RigContainer")
	var intersection := pockets.get_global_rect().intersection(rig_header.get_global_rect())
	check(intersection.size == Vector2.ZERO, "canonical pockets and rig header do not overlap")
	print("ASTRA_COMPACT_P2 pockets=", pockets.get_global_rect(), " rig_header=", rig_header.get_global_rect(), " overlap=", intersection)
	screen._select_compact_section("stash")
	await settle()
	var scroll: ScrollContainer = screen._node("CompactWorkspace/StashScroll")
	var grid: Control = screen._node("StashGrid")
	var outer_rect := scroll.get_global_rect()
	check(grid.grid_columns == 12 and grid.grid_rows == 20 and grid.cell_size == 74, "stash keeps canonical 12x20 at 74px")
	check(grid.get_parent().size.is_equal_approx(grid.size), "stash scroll content mirrors the canonical grid extent")
	scroll.scroll_horizontal = 123
	scroll.scroll_vertical = 456
	await settle()
	screen._refresh_body()
	await settle()
	check(scroll.scroll_horizontal == 123 and scroll.scroll_vertical == 456, "reachable compact offsets survive retained refresh")
	scroll.scroll_vertical = 2000
	scroll.scroll_horizontal = 2000
	await settle()
	var viewport_size := Vector2(scroll.get_h_scroll_bar().page, scroll.get_v_scroll_bar().page)
	print("ASTRA_COMPACT stash_grid=", grid.size, " content=", grid.get_parent().size, " maximum_scroll=", Vector2i(scroll.scroll_horizontal, scroll.scroll_vertical), " page=", viewport_size)
	check(float(scroll.scroll_vertical) + viewport_size.y >= grid.size.y, "last canonical stash row is reachable")
	check(float(scroll.scroll_horizontal) + viewport_size.x >= grid.size.x, "last canonical stash column is reachable")
	controller.set_loot_container(&"corpse")
	screen._set_loot_mode(true)
	await settle()
	grid = screen._node("StashGrid")
	check(grid.grid_columns == 10 and grid.grid_rows == 8 and grid.cell_size == 74, "corpse keeps canonical 10x8 at 74px")
	check(grid.get_parent().size.is_equal_approx(grid.size), "corpse scroll content mirrors the canonical grid extent")
	var max_x := maxi(0, ceili(scroll.get_h_scroll_bar().max_value - scroll.get_h_scroll_bar().page))
	var max_y := maxi(0, ceili(scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page))
	check(scroll.scroll_horizontal <= max_x and scroll.scroll_vertical <= max_y, "source resize clamps retained offsets to the new native range")
	scroll.scroll_vertical = 2000
	scroll.scroll_horizontal = 2000
	await settle()
	viewport_size = Vector2(scroll.get_h_scroll_bar().page, scroll.get_v_scroll_bar().page)
	print("ASTRA_COMPACT corpse_grid=", grid.size, " content=", grid.get_parent().size, " maximum_scroll=", Vector2i(scroll.scroll_horizontal, scroll.scroll_vertical), " page=", viewport_size)
	check(float(scroll.scroll_vertical) + viewport_size.y >= grid.size.y, "last canonical corpse row is reachable")
	check(float(scroll.scroll_horizontal) + viewport_size.x >= grid.size.x, "last canonical corpse column is reachable")
	check(root.size == Vector2i(960, 540) and scroll.get_global_rect().is_equal_approx(outer_rect), "canonical extent does not alter the 960x540 outer pane geometry")
	app.queue_free()
	controller.unbind()
	owner.teardown(owner.generation())
	bridge.queue_free()
	owner.queue_free()
	await settle()
	print("ASTRA_COMPACT_EXTENT_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
