extends "res://docs/qa/inventory_ui_binding/astra_final_accept/native_flow.gd"
## Independent reproduction of the original 1080p real-pointer recursion case.
func run() -> void:
	root.borderless = true
	root.position = Vector2i.ZERO
	root.size = Vector2i(1920, 1080)
	flow_runtime = "1920x1080_pointer_regression"
	setup_runtime()
	app = load("res://ui/main.tscn").instantiate()
	app.initial_route = "inventory"
	root.add_child(app)
	await settle(10)
	screen = app.screen
	check(screen != null, "retained inventory route opens")
	screen._inventory_controller = controller
	check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "pointer screen binds production runtime")
	await _native_click(screen._node("LootTab"))
	var item := _find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_SEALED_DOCUMENTS))
	var source_slot := _slot_for_item(screen._grid_for_source("loot"), int(item.get("item_id", 0)))
	var rig: Control = screen._grid_for_source("rig")
	check(source_slot != null and rig != null, "real source and destination Controls exist")
	check(rig.can_place(item, Vector2i(2, 0)), "original regression destination is valid")
	await _native_click(source_slot)
	check(int(screen._selected_live_item.get("item_id", 0)) == int(item.item_id), "native pointer selects exact source identity")
	await _capture_flow("before")
	var result := await drag(source_slot, rig, Vector2i(2, 0), "")
	check(bool(result.native_dragging), "native Godot drag manager owns the gesture")
	check(int(result.request_delta) == 1, "pointer release submits exactly one request")
	check(_find_item(controller.items_for(&"loot"), int(item.item_id)).is_empty(), "accepted item leaves its canonical world source")
	var confirmed := _find_item(controller.items_for(&"rig"), int(item.item_id))
	check(int(confirmed.get("x", -1)) == 2 and int(confirmed.get("y", -1)) == 0, "authority confirms exact destination coordinates")
	var selected_count := 0
	for grid in screen._grids:
		if not str(grid.selected_id).is_empty():
			selected_count += 1
	check(selected_count == 1 and screen._selected_live_source == "rig", "one selection follows the cross-inventory move")
	check(bridge.presentation_model(&"raid").pending_ids_for_inventory(owner.world_crate_inventory_id).is_empty(), "accepted drag leaves no source pending ghost")
	await _capture_flow("after", result)
	screen.unbind_inventory_runtime()
	controller.unbind()
	bridge.release_binding()
	owner.teardown(owner.generation())
	app.queue_free()
	bridge.queue_free()
	owner.queue_free()
	await settle(10)
	print("ASTRA_NATIVE_POINTER_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
