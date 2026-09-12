extends "res://tests/raid/inventory_ui_binding_contract.gd"
## 1920x1080-only visual evidence for task 4.11.  This extends the existing
## Astra harness and captures the retained right-hand pane through the real
## bridge/adapter/controller binding; it does not instantiate a replacement
## loot screen or a discovery clock.

const OUTPUT_411 := "res://docs/qa/inventory_loot_ui_4_11/captures"
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
const Model = preload("res://addons/inventory_system/runtime/inventory_presentation_model.gd")
const LootController = preload("res://game/inventory/presentation/inventory_presentation_controller.gd")
var records_411: Array[Dictionary] = []
var app: Control
var screen: Control


func setup_runtime() -> void:
    owner = RaidInventoryOwner.new()
    root.add_child(owner)
    check(owner.configure(), "gate owner configures")
    check(owner.materialize_loot_fixture(), "gate loot materializes")
    var request := ZSessionRequest.create_offline(
        ZRequestId.from_parts(PackedStringArray(["astra", "gate", "admission"])),
        ZRaidId.from_parts(PackedStringArray(["astra", "gate", "raid"])),
        &"astra_gate_profile", &"player", 7)
    var session := ZSessionId.from_parts(
        PackedStringArray(["astra", "gate", "session"]))
    var actor := ZEntityId.from_parts(
        PackedStringArray(["astra", "gate", "actor"]))
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
    check(adapter.configure(owner, admission, identity, world,
        MAX_TRANSFER_DISTANCE_RAW), "gate adapter configures")
    bridge = Bridge.new()
    root.add_child(bridge)
    check(bridge.bind_owner(owner, owner.generation()), "gate bridge binds")
    controller = Controller.new()
    check(controller.bind(owner, bridge, adapter, admission),
        "gate controller binds")


func settle(count: int = 5) -> void:
    for _index in range(count):
        await process_frame


func _initialize() -> void:
    # This is the sole current inventory visual runner. Every capture below is
    # asserted at the exact first-playable 1920x1080 canvas.
    run.call_deferred()


class LootStateProbeController extends LootController:
    ## Capture-only provider for deterministic noncanonical state frames. The
    ## production controller has no public state override surface.
    var forced_loot_state: StringName = &""

    func force_loot_state(state: StringName) -> void:
        forced_loot_state = state
        projection_changed.emit(SCOPE_RAID)

    func clear_forced_loot_state() -> void:
        forced_loot_state = &""
        projection_changed.emit(SCOPE_RAID)

    func loot_container_state() -> StringName:
        if not forced_loot_state.is_empty() and is_loot_container_open():
            return forced_loot_state
        return super.loot_container_state()


func _capture_411(state: String, extra: Dictionary = {}) -> bool:
    await settle()
    RenderingServer.force_draw(true)
    var rendered := root.get_texture().get_image()
    var file_name := "1920x1080_" + state + ".png"
    var root_exact := root.get_visible_rect().size == Vector2(1920, 1080)
    if not root_exact:
        check(false, "1920x1080 native capture for " + state)
        push_error("INVENTORY_LOOT_UI_4_11_CAPTURE: nonexact frame rejected before write: " + state)
        quit(2)
        return false
    var exact_frame := rendered != null \
        and rendered.get_size() == Vector2i(1920, 1080)
    check(exact_frame, "1920x1080 native capture for " + state)
    if not exact_frame:
        push_error("INVENTORY_LOOT_UI_4_11_CAPTURE: nonexact frame rejected before write: " + state)
        quit(2)
        return false
    if not Exact1080CaptureGuard.accepts(root, root, rendered):
        push_error("INVENTORY_LOOT_UI_4_11_CAPTURE: physical output changed before PNG write")
        quit(2)
        return false
    var save_error := rendered.save_png(OUTPUT_411 + "/" + file_name)
    check(save_error == OK, "save " + file_name)
    if save_error != OK:
        quit(1)
        return false
    var loot_grid: Control = screen._grid_for_source("loot")
    var loot_status := screen._node("StashCompatible") as Label
    var record := {
        "image": file_name,
        "state": state,
        "dimensions": [rendered.get_width(), rendered.get_height()],
        "route": app.current_route,
        "layout": app.ui_layout_mode,
        "compact": screen._adaptive_applied,
        "loot_open": controller.is_loot_container_open(),
        "loot_state": str(controller.loot_container_state()),
        "loot_status": controller.loot_status_text(),
        "replacement_panel_present": screen.has_node("LootContainerPanel"),
        "grid_parent": loot_grid.get_parent().name if loot_grid != null else "",
        "grid_rect": str(loot_grid.get_global_rect()) if loot_grid != null else "",
        "grid_cell": loot_grid.cell_size if loot_grid != null else 0,
        "grid_columns": loot_grid.grid_columns if loot_grid != null else 0,
        "grid_rows": loot_grid.grid_rows if loot_grid != null else 0,
        "mutation": loot_grid.mutation_enabled if loot_grid != null else false,
        "status_hit_target": {
            "rect": str(loot_status.get_global_rect()) if loot_status != null else "",
            "point_1701_144_inside": loot_status != null and loot_status.get_global_rect().has_point(Vector2(1701, 144)),
            "mouse_filter": loot_status.mouse_filter if loot_status != null else -1,
            "focus_mode": loot_status.focus_mode if loot_status != null else -1,
            "tooltip": loot_status.tooltip_text if loot_status != null else "",
        },
        "selected_item": screen._selected_live_item.get("item_id", 0),
        "search": (screen._node("StashSearch") as LineEdit).text,
        "caret": (screen._node("StashSearch") as LineEdit).caret_column,
        "scroll": [
            (screen._node("DesktopStashScroll") as ScrollContainer).scroll_horizontal,
            (screen._node("DesktopStashScroll") as ScrollContainer).scroll_vertical,
        ],
        "geometry": {
            "inventory_content": str(screen._surface.get_global_rect()),
            "stash_scroll": str((screen._node("DesktopStashScroll") as Control).get_global_rect()),
            "loot_tab": str((screen._node("LootTab") as Control).get_global_rect()),
            "loot_close": str((screen._node("LootClose") as Control).get_global_rect()),
        },
        "extra": extra,
    }
    records_411.append(record)
    print("INVENTORY_LOOT_UI_4_11_CAPTURE ", file_name, " ", JSON.stringify(extra))
    return true


func run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("Task 4.11 native captures require the graphical renderer")
        quit(1)
        return
    root.borderless = true
    root.position = Vector2i.ZERO
    root.size = Vector2i(1920, 1080)
    await process_frame
    RenderingServer.force_draw(true)
    var preflight := root.get_texture().get_image()
    var root_exact := root.get_visible_rect().size == Vector2(1920, 1080)
    if not root_exact:
        check(false, "root and framebuffer are exact 1920x1080 before setup")
        push_error("INVENTORY_LOOT_UI_4_11_CAPTURE: nonexact framebuffer rejected before paths or writes")
        quit(2)
        return
    var exact_preflight := preflight != null and preflight.get_size() == Vector2i(1920, 1080)
    check(exact_preflight, "root and framebuffer are exact 1920x1080 before setup")
    if not exact_preflight:
        push_error("INVENTORY_LOOT_UI_4_11_CAPTURE: nonexact framebuffer rejected before paths or writes")
        quit(2)
        return
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_411))
    setup_runtime()
    var production_controller := controller
    production_controller.unbind()
    controller = LootStateProbeController.new()
    check(controller.bind(owner, bridge, adapter, admission), "capture-only state probe binds the injected production dependencies")
    app = load("res://ui/main.tscn").instantiate()
    app.initial_route = "inventory"
    root.add_child(app)
    await settle(8)
    screen = app.screen
    screen._inventory_controller = controller
    check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "native retained screen binds production loot seam")
    screen._set_loot_mode(true)
    await settle(15)
    check(controller.is_loot_container_open(), "loot tab opens the selected crate")
    if not await _capture_411("ready", {"source": str(controller.loot_container())}): return

    var search := screen._node("StashSearch") as LineEdit
    search.text = "battery"
    screen._on_search_changed(search.text)
    search.grab_focus()
    search.caret_column = 3
    var stash_scroll := screen._node("DesktopStashScroll") as ScrollContainer
    stash_scroll.scroll_vertical = 123
    if not await _capture_411("searching", {"search_presentation_only": true}): return

    controller.force_loot_state(Model.STATE_INACCESSIBLE)
    if not await _capture_411("inaccessible"): return
    controller.clear_forced_loot_state()
    controller.force_loot_state(Model.STATE_STALE_CORRECTED)
    if not await _capture_411("stale"): return
    controller.clear_forced_loot_state()
    controller.force_loot_state(Model.STATE_OVERWEIGHT)
    if not await _capture_411("overweight"): return
    controller.clear_forced_loot_state()

    bridge.begin_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid"))
    if not await _capture_411("resynchronizing"): return
    bridge.complete_resynchronization(&"raid", owner.generation(), bridge.scope_generation(&"raid"))
    await settle()

    search.text = ""
    screen._on_search_changed("")
    await settle()
    var loot_grid: Control = screen._grid_for_source("loot")
    var item := controller.items_for(&"loot")[0] if not controller.items_for(&"loot").is_empty() else {}
    var slot: Control = _slot_for_item(loot_grid, int(item.get("item_id", 0))) if loot_grid != null else null
    if slot != null:
        slot._on_pressed()
    var focus_owner := screen.get_viewport().gui_get_focus_owner()
    var focus_path := str(screen.get_path_to(focus_owner)) if focus_owner != null and screen.is_ancestor_of(focus_owner) else ""
    if not await _capture_411("selection_scroll", {"focus": focus_path, "selection_preserved": screen._selected_live_item.get("item_id", 0)}): return

    screen._set_loot_mode(false)
    if not await _capture_411("close"): return
    screen._set_loot_mode(true)
    await settle()
    bridge.release_binding()
    if not await _capture_411("disconnected"): return

    var report := {
        "engine": Engine.get_version_info(),
        "display": DisplayServer.get_name(),
        "dimensions": [1920, 1080],
        "checks": checks,
        "failures": failures,
        "replacement_route": false,
        "records": records_411,
    }
    var report_image := root.get_texture().get_image()
    if not Exact1080CaptureGuard.accepts(root, root, report_image):
        push_error("INVENTORY_LOOT_UI_4_11_CAPTURE: physical output changed before report write")
        quit(2)
        return
    var file := FileAccess.open(OUTPUT_411 + "/captures.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(report, "\t") + "\n")
    file.close()
    print("INVENTORY_LOOT_UI_4_11_CAPTURE_COMPLETE checks=%d failures=%d" % [checks, failures])
    quit(1 if failures > 0 else 0)
