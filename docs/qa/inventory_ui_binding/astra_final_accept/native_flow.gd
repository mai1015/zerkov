extends "res://docs/qa/inventory_ui_binding/astra_final_accept/capture.gd"
## One coherent graphical playthrough of the production 4.7b binding. Every
## inventory gesture below goes through Viewport input/Godot's native Controls;
## the only direct calls are fixture admission, explicit bridge lifecycle
## transitions, and a documented concurrent-authority
## injection used to force a real adapter rejection.

const FLOW_OUTPUT := "res://docs/qa/inventory_ui_binding/astra_final_accept/flow"

var flow_records: Array[Dictionary] = []
var flow_runtime := ""


func _ensure_flow_output() -> bool:
	var absolute := ProjectSettings.globalize_path(FLOW_OUTPUT)
	var error := DirAccess.make_dir_recursive_absolute(absolute)
	check(error == OK or error == ERR_ALREADY_EXISTS, "native flow evidence directory is available")
	return error == OK or error == ERR_ALREADY_EXISTS


func _capture_flow(state: String, extra: Dictionary = {}) -> void:
	await settle(2)
	RenderingServer.force_draw(true)
	var rendered := root.get_texture().get_image()
	var file_name := flow_runtime + "_" + state + ".png"
	check(rendered.get_size() == root.size, "flow capture matches the current output for " + state)
	check(rendered.save_png(FLOW_OUTPUT + "/" + file_name) == OK, "save flow capture " + file_name)
	var inventory_state := {}
	if controller != null:
		for source in ["pockets", "rig", "backpack", "stash", "loot"]:
			var grid: Control = screen._grid_for_source(source) if is_instance_valid(screen) else null
			inventory_state[source] = {
				"items": controller.items_for(StringName(source)),
				"grid": str(grid.get_global_rect()) if is_instance_valid(grid) else "",
				"scroll_parent": str(grid.get_parent().name) if is_instance_valid(grid) else "",
			}
	flow_records.append({
		"runtime": flow_runtime,
		"state": state,
		"image": file_name,
		"dimensions": [rendered.get_width(), rendered.get_height()],
		"compact": bool(screen._adaptive_applied) if is_instance_valid(screen) else false,
		"layout": str(app.ui_layout_mode) if is_instance_valid(app) else "",
		"toast": str(app.toast_label.text) if is_instance_valid(app) else "",
		"inventory": inventory_state,
		"extra": extra.duplicate(true),
	})
	print("ASTRA_NATIVE_FLOW_CAPTURE state=", state, " runtime=", flow_runtime, " extra=", JSON.stringify(extra))


func _native_click(control: Control, ctrl: bool = false) -> void:
	if not is_instance_valid(control):
		check(false, "native click target exists")
		return
	var position := control.get_global_rect().get_center()
	motion(position, Vector2.ZERO, false, ctrl)
	pointer(position, true, ctrl)
	await settle(1)
	pointer(position, false, ctrl)
	await settle(3)


func _native_key(keycode: int, echo: bool = false) -> void:
	var pressed := InputEventKey.new()
	pressed.keycode = keycode
	pressed.pressed = true
	pressed.echo = echo
	root.push_input(pressed, true)
	if not echo:
		var released := InputEventKey.new()
		released.keycode = keycode
		released.pressed = false
		root.push_input(released, true)


func _native_type(value: String) -> void:
	for index in range(value.length()):
		var character := value.substr(index, 1)
		var unicode_value := value.unicode_at(index)
		var keycode_value := character.to_upper().unicode_at(0)
		var pressed := InputEventKey.new()
		pressed.keycode = keycode_value
		pressed.unicode = unicode_value
		pressed.pressed = true
		root.push_input(pressed, true)
		var released := InputEventKey.new()
		released.keycode = keycode_value
		released.unicode = unicode_value
		released.pressed = false
		root.push_input(released, true)
		await settle(1)


func _native_wheel(position: Vector2, button: int, shift: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = true
	event.shift_pressed = shift
	event.factor = 4.0
	root.push_input(event, true)


func _find_player_item(item_id: int) -> Dictionary:
	for source in [&"pockets", &"rig", &"backpack"]:
		var item := _find_item(controller.items_for(source), item_id)
		if not item.is_empty():
			var result := item.duplicate(true)
			result["source"] = String(source)
			return result
	return {}


func _teardown_flow_runtime() -> void:
	var app_ref = weakref(app) if is_instance_valid(app) else null
	var owner_ref = weakref(owner) if is_instance_valid(owner) else null
	var bridge_ref = weakref(bridge) if is_instance_valid(bridge) else null
	if is_instance_valid(screen):
		screen.unbind_inventory_runtime()
	if controller != null:
		controller.unbind()
	if is_instance_valid(bridge):
		bridge.release_binding()
	if is_instance_valid(owner):
		owner.teardown(owner.generation())
	if is_instance_valid(app):
		app.queue_free()
	if is_instance_valid(bridge):
		bridge.queue_free()
	if is_instance_valid(owner):
		owner.queue_free()
	await settle(6)
	check(app_ref == null or app_ref.get_ref() == null, "flow app is freed before the next runtime")
	check(owner_ref == null or owner_ref.get_ref() == null, "flow owner is freed before the next runtime")
	check(bridge_ref == null or bridge_ref.get_ref() == null, "flow bridge is freed before the next runtime")
	app = null
	screen = null
	controller = null
	adapter = null
	admission = null
	owner = null
	bridge = null


func _open_bound_runtime(dimensions: Vector2i, runtime_name: String) -> bool:
	flow_runtime = runtime_name
	root.size = dimensions
	setup_runtime()
	app = load("res://ui/main.tscn").instantiate()
	app.initial_route = "inventory"
	root.add_child(app)
	await settle(10)
	screen = app.screen
	if not is_instance_valid(screen):
		check(false, "native flow inventory route opens")
		return false
	screen._inventory_controller = controller
	var bound: bool = screen.bind_inventory_runtime(owner, bridge, adapter, admission)
	check(bound, "native flow screen binds explicit production dependencies")
	await settle(10)
	return bound


func _run_desktop_flow() -> void:
	# Seed one canonical stack through the same controller/adapter/authority seam.
	# This is the only precondition; every subsequent record belongs to this one
	# owner/session/runtime and advances from the prior confirmed state.
	flow_runtime = "1280x720_live_flow"
	root.size = Vector2i(1280, 720)
	setup_runtime()
	var corpse_stack := _find_stack_item(controller.items_for(&"corpse"))
	var seeded := controller.submit_drop(&"corpse", &"pockets", corpse_stack, Vector2i.ZERO)
	check(seeded.accepted, "flow precondition seeds one confirmed actor-owned stack")
	var seeded_stack_id := int(corpse_stack.get("item_id", 0))
	app = load("res://ui/main.tscn").instantiate()
	app.initial_route = "inventory"
	root.add_child(app)
	await settle(10)
	screen = app.screen
	check(is_instance_valid(screen), "native flow opens the retained inventory route")
	if not is_instance_valid(screen):
		return
	screen._inventory_controller = controller
	var bound: bool = screen.bind_inventory_runtime(owner, bridge, adapter, admission)
	check(bound, "native flow binds production owner/bridge/adapter/admission")
	if not bound:
		return
	screen._set_loot_mode(true)
	await settle(10)
	var initial_loot_grid: Control = screen._grid_for_source("loot")
	check(screen._live_inventory_binding and initial_loot_grid != null \
		and initial_loot_grid.mutation_enabled, "bound flow exposes live mutable world loot")
	if initial_loot_grid == null:
		return
	await _capture_flow("01_bound", {"precondition_command": seeded.get("command_id", 0)})

	# Select and search through retained native controls. Search remains a pure
	# presentation projection: neither adapter ledger nor confirmed revisions move.
	var loot_grid: Control = screen._grid_for_source("loot")
	if loot_grid == null:
		check(false, "coherent flow exposes the live loot grid")
		return
	var docs := _find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_SEALED_DOCUMENTS))
	var docs_id := int(docs.get("item_id", 0))
	var docs_slot := _slot_for_item(loot_grid, docs_id)
	check(docs_slot != null, "coherent flow exposes sealed documents in live loot")
	if docs_slot != null:
		await _native_click(docs_slot)
	check(int(screen._selected_live_item.get("item_id", 0)) == docs_id and screen._selected_live_source == "loot", "native selection resolves exact live item identity")
	var search: LineEdit = screen._node("StashSearch") as LineEdit
	var search_requests := adapter.tracked_request_count()
	var search_crate_revision := bridge.confirmed_revision(&"raid", owner.world_crate_inventory_id)
	var search_player_revision := bridge.confirmed_revision(&"raid", owner.raid_player_inventory_id)
	check(search != null, "native flow exposes the retained search field")
	if search != null:
		search.grab_focus()
		await settle(2)
		await _native_type("sealed")
		await settle(2)
	check(adapter.tracked_request_count() == search_requests \
		and bridge.confirmed_revision(&"raid", owner.world_crate_inventory_id) == search_crate_revision \
		and bridge.confirmed_revision(&"raid", owner.raid_player_inventory_id) == search_player_revision,
		"search changes no request or canonical revision")
	check(search != null and search.text == "sealed" and screen._search_query == "sealed" \
		and loot_grid._slots.size() == 1 \
		and int(loot_grid._slots[0].item.get("item_id", 0)) == docs_id,
		"native search input filters only the visible slot layer")
	await _capture_flow("02_selected_search", {"query": "sealed", "selected_item_id": docs_id, "request_delta": adapter.tracked_request_count() - search_requests})
	if search != null:
		search.text = ""
		search.text_changed.emit("")
		search.release_focus()
	await settle(3)

	# One actual Viewport drag enters Godot's drag manager and submits exactly one
	# exact-coordinate loot intent. The confirmed item and selection both move.
	docs_slot = _slot_for_item(loot_grid, docs_id)
	var rig_grid: Control = screen._grid_for_source("rig")
	var docs_destination := Vector2i(2, 0)
	check(docs_slot != null and rig_grid != null \
		and rig_grid.can_place(docs, docs_destination, str(docs_id)), "native drag has an exact valid rig destination")
	if rig_grid == null:
		return
	if docs_slot != null:
		var drag_result := await drag(docs_slot, rig_grid, docs_destination, "")
		var moved_docs := _find_item(controller.items_for(&"rig"), docs_id)
		check(drag_result.native_dragging and int(drag_result.request_delta) == 1, "real pointer drag submits exactly one authority request")
		check(int(moved_docs.get("x", -1)) == 2 and int(moved_docs.get("y", -1)) == 0, "confirmed projection uses the exact dragged rig coordinate")
		check(screen._selected_live_source == "rig" and int(screen._selected_live_item.get("item_id", 0)) == docs_id, "selection follows the confirmed cross-container move")
	await _capture_flow("03_drag_confirmed", {"item_id": docs_id, "destination": [2, 0]})

	# Native R rotates the currently selected item once. A repeated/echoed R must
	# not submit another command.
	var current_docs := _find_item(controller.items_for(&"rig"), docs_id)
	var current_docs_slot := _slot_for_item(rig_grid, docs_id)
	if current_docs_slot != null:
		await _native_click(current_docs_slot)
	var rotate_before := adapter.tracked_request_count()
	var was_rotated := bool(current_docs.get("rotated", false))
	_native_key(KEY_R)
	await settle(5)
	var rotated_docs := _find_item(controller.items_for(&"rig"), docs_id)
	check(adapter.tracked_request_count() == rotate_before + 1 and bool(rotated_docs.get("rotated", was_rotated)) != was_rotated, "native R submits one exact rotate intent")
	_native_key(KEY_R, true)
	await settle(2)
	check(adapter.tracked_request_count() == rotate_before + 1, "key-repeat echo submits no duplicate rotate intent")
	await _capture_flow("04_rotated", {"item_id": docs_id, "rotated": rotated_docs.get("rotated", false), "requests": 1})

	# Ctrl-drag opens the CommonUI quantity modal. First cancel it through its
	# native button and prove both modal-suspended R and cancel submit nothing.
	var pockets_grid: Control = screen._grid_for_source("pockets")
	if pockets_grid == null:
		check(false, "coherent flow exposes the live pockets grid")
		return
	var actor_stack := _find_item(controller.items_for(&"pockets"), seeded_stack_id)
	var actor_stack_slot := _slot_for_item(pockets_grid, seeded_stack_id)
	var split_destination := Vector2i(4, 0)
	check(actor_stack_slot != null and rig_grid.can_place(actor_stack, split_destination, str(seeded_stack_id)), "ctrl-drag stack has an exact empty rig cell")
	var split_before := adapter.tracked_request_count()
	if actor_stack_slot != null:
		var split_drag := await drag(actor_stack_slot, rig_grid, split_destination, "", true)
		check(split_drag.native_dragging and int(split_drag.request_delta) == 0, "ctrl-drag opens quantity arbitration without early submission")
	check(is_instance_valid(screen._split_dialog) and screen._split_dialog == app.modal, "ctrl-drag opens the CommonUI modal in the same live flow")
	_native_key(KEY_R)
	await settle(2)
	check(adapter.tracked_request_count() == split_before, "modal-suspended R submits no inventory command")
	await _capture_flow("05_split_modal", {"source_item_id": seeded_stack_id, "destination": [4, 0]})
	var cancel_button: Control = app.modal.find_child("CancelButton", true, false) if is_instance_valid(app.modal) else null
	if cancel_button != null:
		await _native_click(cancel_button)
	check(adapter.tracked_request_count() == split_before and not is_instance_valid(app.modal), "native modal cancel submits zero commands and closes cleanly")

	# Repeat the exact Ctrl-drag, enter ten, and confirm through the authored
	# CommonUI button. The authority creates the new stack at exactly (4, 0).
	actor_stack_slot = _slot_for_item(pockets_grid, seeded_stack_id)
	if actor_stack_slot != null:
		await drag(actor_stack_slot, rig_grid, split_destination, "", true)
	check(is_instance_valid(screen._split_spin), "split modal can reopen after cancellation")
	if is_instance_valid(screen._split_spin):
		await _native_click(screen._split_spin)
		_native_key(KEY_BACKSPACE)
		_native_key(KEY_DELETE)
		await _native_type("10")
		check(screen._split_spin.text == "10", "native quantity keyboard input sets exactly ten")
	var confirm_button: Control = app.modal.find_child("ConfirmButton", true, false) if is_instance_valid(app.modal) else null
	if confirm_button != null:
		await _native_click(confirm_button)
	await settle(5)
	var split_stack := _find_quantity(controller.items_for(&"rig"), str(actor_stack.get("definition_id", "")), 10)
	var remaining_stack := _find_item(controller.items_for(&"pockets"), seeded_stack_id)
	check(adapter.tracked_request_count() == split_before + 1 \
		and int(split_stack.get("x", -1)) == split_destination.x \
		and int(split_stack.get("y", -1)) == split_destination.y \
		and int(remaining_stack.get("quantity", 0)) == 50,
		"confirmed modal split submits one exact quantity/container/cell command")
	await _capture_flow("06_split_confirmed", {"source_item_id": seeded_stack_id, "new_item_id": split_stack.get("item_id", 0), "quantity": 10, "destination": [4, 0]})

	# A normal native drag over the compatible occupied stack becomes one merge,
	# preserves the target identity, and removes only the split source identity.
	var split_stack_id := int(split_stack.get("item_id", 0))
	var split_stack_slot := _slot_for_item(rig_grid, split_stack_id)
	var remaining_slot := _slot_for_item(pockets_grid, seeded_stack_id)
	var merge_before := adapter.tracked_request_count()
	if split_stack_slot != null and remaining_slot != null:
		var merge_result := await drag(split_stack_slot, pockets_grid, Vector2i(int(remaining_stack.get("x", 0)), int(remaining_stack.get("y", 0))), "")
		check(merge_result.native_dragging and int(merge_result.request_delta) == 1, "native compatible occupied-cell release submits exactly one merge")
	var merged_stack := _find_item(controller.items_for(&"pockets"), seeded_stack_id)
	check(adapter.tracked_request_count() == merge_before + 1 \
		and int(merged_stack.get("quantity", 0)) == 60 \
		and _find_item(controller.items_for(&"rig"), split_stack_id).is_empty(),
		"merge preserves target identity and canonical total quantity")
	await _capture_flow("07_merged", {"target_item_id": seeded_stack_id, "removed_source_item_id": split_stack_id, "quantity": 60})

	# Native Ctrl-click performs one complete-only quick transfer. No UI-selected
	# first-fit coordinate is supplied; the confirmed authority projection chooses
	# the destination container/location.
	loot_grid = screen._grid_for_source("loot")
	var quick_item := _find_definition(controller.items_for(&"loot"), str(Catalog.ITEM_DUCT_TAPE))
	if quick_item.is_empty() and not controller.items_for(&"loot").is_empty():
		quick_item = controller.items_for(&"loot")[0]
	var quick_id := int(quick_item.get("item_id", 0))
	var quick_slot := _slot_for_item(loot_grid, quick_id)
	var quick_slot_existed := quick_slot != null
	var quick_before := adapter.tracked_request_count()
	if quick_slot != null:
		await _native_click(quick_slot, true)
	var quick_destination := _find_player_item(quick_id)
	check(quick_slot_existed and adapter.tracked_request_count() == quick_before + 1 \
		and _find_item(controller.items_for(&"loot"), quick_id).is_empty() \
		and not quick_destination.is_empty(),
		"native Ctrl-click submits one complete-only transfer and renders its confirmed authority-selected destination")
	await _capture_flow("08_quick_transferred", {"item_id": quick_id, "confirmed_source": quick_destination.get("source", ""), "confirmed_location": quick_destination.get("location", {})})

	# Force a genuine adapter rejection in the same runtime: after the UI captures
	# its destination revision and creates pending state, a separate authoritative
	# rotation advances that destination exactly once. The submitted quick transfer
	# is therefore rejected as destination_revision_stale and the world placement
	# remains the latest canonical placement (no locally invented move).
	var rejected_item: Dictionary = {}
	for candidate in controller.items_for(&"loot"):
		if int(candidate.get("item_id", 0)) != quick_id:
			rejected_item = candidate
			break
	var rejected_id := int(rejected_item.get("item_id", 0))
	var rejected_location: Dictionary = (rejected_item.get("location", {}) as Dictionary).duplicate(true)
	var rejected_slot := _slot_for_item(loot_grid, rejected_id)
	var injection := {"armed": true, "result": {}}
	var inject_callback := func(scope: StringName):
		if scope != &"raid" or not bool(injection.armed):
			return
		injection.armed = false
		var concurrent_docs := _find_item(controller.items_for(&"rig"), docs_id)
		injection.result = owner.raid_authority().rotate_item(
			owner.raid_player_inventory_id,
			docs_id,
			not bool(concurrent_docs.get("rotated", false)),
			RaidInventoryOwner.FIXTURE_ACTOR_ID,
			991_407)
	controller.pending_changed.connect(inject_callback)
	var reject_before := adapter.tracked_request_count()
	if rejected_slot != null:
		await _native_click(rejected_slot, true)
	if controller.pending_changed.is_connected(inject_callback):
		controller.pending_changed.disconnect(inject_callback)
	await settle(5)
	var restored := _find_item(controller.items_for(&"loot"), rejected_id)
	check(rejected_slot != null and bool((injection.result as Dictionary).get("accepted", false)), "rejection probe advances the real destination authority after pending begins")
	check(adapter.tracked_request_count() == reject_before + 1 \
		and not restored.is_empty() \
		and restored.get("location", {}) == rejected_location \
		and str(app.toast_label.text).to_lower().contains("destination revision stale"),
		"real rejected command restores canonical world placement and exposes the stable reason")
	await _capture_flow("09_rejected_restored", {"item_id": rejected_id, "location": rejected_location, "reason": app.toast_label.text, "concurrent_command": injection.result})

	# Finish the same runtime through resync, disconnect, and explicit recovery.
	var raid_generation := bridge.scope_generation(&"raid")
	check(bridge.begin_resynchronization(&"raid", owner.generation(), raid_generation), "flow enters explicit raid resynchronization")
	await settle(4)
	check(not screen._grid_for_source("loot").mutation_enabled, "resynchronization disables native mutation controls")
	await _capture_flow("10_resynchronizing")
	check(bridge.complete_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid")), "flow completes resynchronization from latest authority state")
	await settle(4)
	check(screen._grid_for_source("loot").mutation_enabled, "completed resynchronization restores native mutation controls")
	bridge.release_binding()
	await settle(4)
	check(not controller.is_bound() and not screen._grid_for_source("loot").mutation_enabled, "disconnect invalidates controller and every native mutation target")
	await _capture_flow("11_disconnected")
	check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "same retained screen explicitly recovers its production binding")
	screen._set_loot_mode(true)
	await settle(8)
	var recovered_docs := _find_item(controller.items_for(&"rig"), docs_id)
	var recovered_slot := _slot_for_item(screen._grid_for_source("rig"), docs_id)
	if recovered_slot != null:
		await _native_click(recovered_slot)
	var recover_before := adapter.tracked_request_count()
	var recovered_was_rotated := bool(recovered_docs.get("rotated", false))
	_native_key(KEY_R)
	await settle(5)
	var recovered_after := _find_item(controller.items_for(&"rig"), docs_id)
	check(recovered_slot != null and adapter.tracked_request_count() == recover_before + 1 \
		and bool(recovered_after.get("rotated", recovered_was_rotated)) != recovered_was_rotated,
		"fresh native command succeeds after recovery without replay collision")
	await _capture_flow("12_recovered", {"item_id": docs_id, "request_delta": adapter.tracked_request_count() - recover_before})


func _run_compact_scroll_flow() -> void:
	var opened: bool = await _open_bound_runtime(Vector2i(960, 540), "960x540_compact_scroll")
	check(opened, "isolated compact runtime opens")
	if not opened or not is_instance_valid(screen):
		return
	screen._set_loot_mode(false)
	screen._select_compact_section("stash")
	await settle(10)
	var stash_grid: Control = screen._grid_for_source("stash")
	var scroll: ScrollContainer = screen._node("CompactWorkspace/StashScroll") as ScrollContainer
	check(screen._adaptive_applied and is_instance_valid(scroll) and scroll.is_visible_in_tree(), "960 critical path exposes the compact native stash scroller")
	if not is_instance_valid(stash_grid) or not is_instance_valid(scroll):
		check(false, "compact canonical grid and scroller both exist")
		return
	check(stash_grid.cell_size == 74 and stash_grid.size.is_equal_approx(Vector2(12 * 74, 20 * 74)), "compact grid retains exact 74px canonical 12x20 extent")
	await _capture_flow("01_top_left", {"scroll": [scroll.scroll_horizontal, scroll.scroll_vertical]})
	var start_x := scroll.scroll_horizontal
	var start_y := scroll.scroll_vertical
	var wheel_position := scroll.get_global_rect().get_center()
	for index in range(36):
		_native_wheel(wheel_position, MOUSE_BUTTON_WHEEL_DOWN)
		_native_wheel(wheel_position, MOUSE_BUTTON_WHEEL_RIGHT)
	await settle(8)
	var native_x := scroll.scroll_horizontal
	var native_y := scroll.scroll_vertical
	check(native_x > start_x and native_y > start_y, "native compact wheel input advances both scroll axes")
	# Clamp through the public native ScrollContainer properties, then prove the
	# final canonical cell is actually inside the clip at the terminal offsets.
	scroll.scroll_horizontal = 2_000_000
	scroll.scroll_vertical = 2_000_000
	await settle(5)
	var max_x := maxi(0, ceili(scroll.get_h_scroll_bar().max_value - scroll.get_h_scroll_bar().page))
	var max_y := maxi(0, ceili(scroll.get_v_scroll_bar().max_value - scroll.get_v_scroll_bar().page))
	check(abs(scroll.scroll_horizontal - max_x) <= 1 and abs(scroll.scroll_vertical - max_y) <= 1, "compact scroller clamps at both canonical terminal extents")
	var last_cell_center := stash_grid.global_position + Vector2((stash_grid.grid_columns - 0.5) * 74.0, (stash_grid.grid_rows - 0.5) * 74.0)
	check(scroll.get_global_rect().grow(2.0).has_point(last_cell_center), "compact terminal offsets reveal the final canonical row and column")
	await _capture_flow("02_bottom_right", {"native_scroll": [native_x, native_y], "terminal_scroll": [scroll.scroll_horizontal, scroll.scroll_vertical], "terminal_max": [max_x, max_y], "last_cell_center": str(last_cell_center)})


func _write_flow_report() -> void:
	var file := FileAccess.open(FLOW_OUTPUT + "/native_flow.json", FileAccess.WRITE)
	check(file != null, "native flow JSON evidence opens")
	var report := {
		"engine": Engine.get_version_info(),
		"display": DisplayServer.get_name(),
		"flow": "one isolated authoritative runtime: open/bind -> select/search -> drag -> rotate -> split cancel/confirm -> merge -> quick transfer -> real rejection restore -> resync -> disconnect -> recover; followed by a separately torn-down 960 compact scroll runtime",
		"checks": checks,
		"failures": failures,
		"records": flow_records,
	}
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Native inventory flow requires the graphical renderer")
		quit(1)
		return
	root.borderless = true
	root.position = Vector2i.ZERO
	if not _ensure_flow_output():
		quit(1)
		return
	await _run_desktop_flow()
	await _teardown_flow_runtime()
	await _run_compact_scroll_flow()
	await _teardown_flow_runtime()
	_write_flow_report()
	print("ASTRA_NATIVE_FLOW_COMPLETE checks=%d failures=%d records=%d" % [checks, failures, flow_records.size()])
	quit(1 if failures > 0 else 0)
