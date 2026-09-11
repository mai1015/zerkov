extends "res://tests/raid/inventory_ui_binding_contract.gd"

func _initialize() -> void:
	push_error("DEFERRED_DISPLAY_SUITE: historical multi-resolution inventory QA is retired; reopen only through task 11.8 or an approved display-support proposal")
	quit(2)
	return

## Independent Astra gate evidence. Graphical Godot only. This reuses identity
## and world-policy test ports, but dispatches native viewport input itself.
const OUTPUT := "res://docs/qa/inventory_ui_binding/astra_final_accept/core"
var app: Control
var screen: Control
var records: Array[Dictionary] = []
var capture_key := ""

func setup_runtime() -> void:
	owner = RaidInventoryOwner.new()
	root.add_child(owner)
	check(owner.configure(), "gate owner configures")
	check(owner.materialize_loot_fixture(), "gate loot materializes")
	var request := ZSessionRequest.create_offline(ZRequestId.from_parts(PackedStringArray(["astra", "gate", "admission"])), ZRaidId.from_parts(PackedStringArray(["astra", "gate", "raid"])), &"astra_gate_profile", &"player", 7)
	var session := ZSessionId.from_parts(PackedStringArray(["astra", "gate", "session"]))
	var actor := ZEntityId.from_parts(PackedStringArray(["astra", "gate", "actor"]))
	admission = ZSessionAdmission.accept_local(request, session, actor)
	var identity := BindingIdentityPort.new()
	identity.session_key = session.canonical_key()
	identity.actor_key = actor.canonical_key()
	identity.epoch = admission.authority_epoch
	identity.generation = admission.generation
	identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
	identity.owned[owner.raid_player_inventory_id] = true
	var world := BindingWorldPolicyPort.new()
	world.actor_key = actor.canonical_key()
	world.generation = admission.generation
	world.world_ids[owner.world_crate_inventory_id] = true
	world.world_ids[owner.corpse_inventory_id] = true
	adapter = Adapter.new()
	check(adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW), "gate adapter configures")
	bridge = Bridge.new()
	root.add_child(bridge)
	check(bridge.bind_owner(owner, owner.generation()), "gate bridge binds")
	controller = Controller.new()
	check(controller.bind(owner, bridge, adapter, admission), "gate controller binds")

func settle(count: int = 5) -> void:
	for i in range(count):
		await process_frame

func capture(state: String, extra: Dictionary = {}) -> void:
	await settle()
	# Final validator capture: explicitly draw the graphical viewport before
	# reading it. A frame_post_draw wait can stall indefinitely when the window
	# is idle; the stopped attempt and its log remain in this evidence packet.
	RenderingServer.force_draw(true)
	var rendered := root.get_texture().get_image()
	var file_name := capture_key + "_" + state + ".png"
	check(rendered.get_size() == root.size, "native capture matches the current output")
	check(rendered.save_png(OUTPUT + "/" + file_name) == OK, "save " + file_name)
	var record := {"image": file_name, "state": state, "dimensions": [rendered.get_width(), rendered.get_height()], "layout": app.ui_layout_mode, "compact": screen._adaptive_applied, "logical_size": str(root.get_visible_rect().size), "toast": app.toast_label.text, "section": screen._compact_section, "grids": {}, "geometry": {}, "extra": extra}
	for source in ["pockets", "rig", "backpack", "stash", "loot"]:
		var grid: Control = screen._grid_for_source(source)
		if grid == null:
			continue
		var icon_count := 0
		for slot in grid._slots:
			if slot._icon.texture != null:
				icon_count += 1
		record.grids[source] = {"global_rect": str(grid.get_global_rect()), "size": str(grid.size), "slots": grid._slots.size(), "icons": icon_count, "rows": grid.grid_rows, "columns": grid.grid_columns, "mutation": grid.mutation_enabled, "items": grid.items}
	for key in ["PostRaidBar", "CharacterColumn", "DesktopPocketsScroll", "DesktopRigScroll", "DesktopPackScroll", "DesktopStashScroll", "RigContainer", "CompactWorkspace/LoadoutScroll", "CompactWorkspace/StashScroll"]:
		var node: Control = screen._node(key)
		if node != null:
			record.geometry[key] = {"rect": str(node.get_global_rect()), "visible": node.is_visible_in_tree()}
			if node is ScrollContainer:
				record.geometry[key]["scroll"] = [node.scroll_horizontal, node.scroll_vertical]
	records.append(record)
	print("ASTRA_CAPTURE ", file_name, " ", JSON.stringify(extra))

func pointer(position: Vector2, pressed: bool, ctrl: bool = false, button: int = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = pressed
	event.ctrl_pressed = ctrl
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	root.push_input(event, true)

func motion(position: Vector2, relative: Vector2, held: bool = false, ctrl: bool = false) -> void:
	root.warp_mouse(position)
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	event.ctrl_pressed = ctrl
	root.push_input(event, true)

func drag(source_slot: Control, target_grid: Control, cell: Vector2i, state: String, ctrl: bool = false) -> Dictionary:
	screen._close_tip()
	await settle()
	var start := source_slot.get_global_rect().get_center()
	var target := target_grid.global_position + Vector2(cell) * 74 + Vector2(20, 20)
	var before := adapter.tracked_request_count()
	motion(start, Vector2.ZERO)
	pointer(start, true, ctrl)
	await settle(1)
	motion(start + Vector2(20, 0), Vector2(20, 0), true, ctrl)
	await settle(1)
	motion(target, target - start - Vector2(20, 0), true, ctrl)
	await settle(1)
	var was_dragging := root.gui_is_dragging()
	var data: Variant = root.gui_get_drag_data()
	if not state.is_empty():
		await capture(state, {"native_dragging": was_dragging, "payload_present": data is Dictionary, "from": str(start), "to": str(target)})
	pointer(target, false, ctrl)
	await settle()
	return {"native_dragging": was_dragging, "request_delta": adapter.tracked_request_count() - before, "toast": app.toast_label.text}

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Astra native captures require the graphical renderer")
		quit(1)
		return
	root.borderless = true
	root.position = Vector2i.ZERO
	for dimensions in [Vector2i(1920, 1080), Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		print("ASTRA_OUTPUT requested=", dimensions, " actual=", root.size, " usable=", DisplayServer.screen_get_usable_rect())
		setup_runtime()
		var ammo := _find_definition(controller.items_for(&"corpse"), str(Catalog.ITEM_AMMO_762))
		if ammo.is_empty():
			ammo = _find_stack_item(controller.items_for(&"corpse"))
		check(controller.submit_drop(&"corpse", &"pockets", ammo, Vector2i.ZERO).accepted, "seed confirmed 60-round stack")
		app = load("res://ui/main.tscn").instantiate()
		app.initial_route = "inventory"
		root.add_child(app)
		await settle()
		screen = app.screen
		screen._inventory_controller = controller
		check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "native screen binds")
		screen._set_loot_mode(true)
		for source in ["pockets", "rig", "backpack", "loot"]:
			var grid: Control = screen._grid_for_source(source)
			grid.drop_rejected.connect(func(item: Dictionary, from_source: String, cell: Vector2i):
				print("NATIVE_REJECT target=", grid.source_id, " from=", from_source, " cell=", cell, " mutation=", grid.mutation_enabled, " fit=", grid.can_place(item, cell, str(item.item_id)), " quantity=", item.quantity))
		await settle(15)
		capture_key = "%dx%d" % [dimensions.x, dimensions.y]
		await capture("ready")
		var pockets: Control = screen._grid_for_source("pockets")
		var stack := _find_stack_item(controller.items_for(&"pockets"))
		var stack_slot := _slot_for_item(pockets, int(stack.item_id))
		stack_slot.grab_focus()
		var key := InputEventKey.new()
		key.keycode = KEY_ENTER
		key.pressed = true
		root.push_input(key)
		key.pressed = false
		root.push_input(key)
		await capture("focused_tooltip", {"selected": screen._selected_live_item.get("item_id", 0)})
		screen._close_tip()
		var model := bridge.presentation_model(&"raid")
		var revision := bridge.confirmed_revision(&"raid", owner.raid_player_inventory_id)
		var pending := bridge.begin_pending_intent(&"raid", &"move", {"inventory_id": owner.raid_player_inventory_id, "items": [int(stack.item_id)], "ghost_placement": {"kind": "spatial", "container": pockets.container_id, "x": 2, "y": 0, "rotated": false}}, owner.generation(), bridge.scope_generation(&"raid"))
		await capture("pending", {"pending_id": pending, "confirmed_revision": revision, "method": "public bridge pending presentation probe; synchronous adapter has no artificial delay"})
		model.apply_result({"accepted": false, "command_id": pending, "status": {"code": &"command_rejected", "reason": &"qa_stale_revision"}})
		await capture("rejected_restored", {"confirmed_revision": bridge.confirmed_revision(&"raid", owner.raid_player_inventory_id), "method": "model rejection presentation probe"})
		var split_result := controller.submit_drop(&"pockets", &"rig", controller.items_for(&"pockets")[0], Vector2i(0, 0), Controller.OP_SPLIT, 0, 10)
		await capture("accepted_split_50_10", {"accepted": split_result.accepted})
		var rig_stack := _find_stack_item(controller.items_for(&"rig"))
		var target_stack := _find_stack_item(controller.items_for(&"pockets"))
		var merged := controller.submit_drop(&"rig", &"pockets", rig_stack, Vector2i.ZERO, Controller.OP_MERGE, int(target_stack.item_id))
		await capture("accepted_merge_60", {"accepted": merged.accepted})
		if dimensions.x == 960:
			screen._select_compact_section("stash")
			await settle()
		var search: LineEdit = screen._node("StashSearch")
		screen._set_filter("util")
		search.text = "band"
		screen._on_search_changed(search.text)
		search.grab_focus()
		search.caret_column = 2
		await capture("filter_search")
		search.text = "no-match-999"
		screen._on_search_changed(search.text)
		await capture("no_match")
		screen._set_filter("all")
		search.text = ""
		screen._on_search_changed("")
		search.release_focus()
		if dimensions.x != 960:
			var loot_grid: Control = screen._grid_for_source("loot")
			var item: Dictionary = controller.items_for(&"loot")[0]
			var slot := _slot_for_item(loot_grid, int(item.item_id))
			var result := await drag(slot, screen._grid_for_source("rig"), Vector2i(2, 0), "native_drag")
			await capture("native_drag_result", result)
			var quick_item := _find_stack_item(controller.items_for(&"loot"))
			var quick_slot := _slot_for_item(loot_grid, int(quick_item.item_id))
			if quick_slot != null:
				var start := quick_slot.get_global_rect().get_center()
				var before := adapter.tracked_request_count()
				motion(start, Vector2.ZERO)
				pointer(start, true, true)
				pointer(start, false, true)
				await settle()
				await capture("quick_transfer", {"request_delta": adapter.tracked_request_count() - before, "source_quantity": quick_item.quantity})
		bridge.begin_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid"))
		await capture("resynchronizing")
		bridge.complete_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid"))
		if dimensions.x == 960:
			screen._set_loot_mode(false)
			await settle()
			await capture("stash_top")
			var scroll: ScrollContainer = screen._node("CompactWorkspace/StashScroll")
			scroll.scroll_horizontal = 2000
			scroll.scroll_vertical = 2000
			await capture("stash_bottom")
			screen._select_compact_section("loadout")
			await settle()
			await capture("loadout_top")
			var loadout: ScrollContainer = screen._node("CompactWorkspace/LoadoutScroll")
			loadout.scroll_vertical = 300
			await capture("loadout_scroll_300")
			loadout.scroll_vertical = 2000
			await capture("loadout_bottom")
			loadout.scroll_vertical = 0
			await settle()
			var edge_stack := _slot_for_item(screen._grid_for_source("pockets"), int(target_stack.item_id))
			motion(Vector2(950, 530), Vector2.ZERO)
			edge_stack.grab_focus()
			edge_stack._on_pressed()
			await capture("edge_tooltip")
			screen._close_tip()
			var wheel_at := edge_stack.get_global_rect().get_center()
			var scroll_before := loadout.scroll_vertical
			pointer(wheel_at, true, false, MOUSE_BUTTON_WHEEL_DOWN)
			await capture("wheel_over_item", {"before": scroll_before, "after": loadout.scroll_vertical})
		bridge.release_binding()
		await capture("disconnected")
		app.queue_free()
		controller.unbind()
		owner.teardown(owner.generation())
		bridge.queue_free()
		owner.queue_free()
		await settle()
	var report := {"engine": Engine.get_version_info(), "display": DisplayServer.get_name(), "checks": checks, "failures": failures, "human_approval": false, "records": records}
	var file := FileAccess.open(OUTPUT + "/captures.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("ASTRA_CAPTURE_COMPLETE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
