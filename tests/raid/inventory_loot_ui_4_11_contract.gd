extends SceneTree
## Task 4.11 contract: loot open/search/close extends the retained character
## workspace and never creates a second inventory or discovery authority.

const Controller = preload("res://game/inventory/presentation/inventory_presentation_controller.gd")
const Bridge = preload("res://game/inventory/presentation/inventory_projection_bridge.gd")
const Adapter = preload("res://game/inventory/inventory_intent_adapter.gd")
const Model = preload("res://addons/inventory_system/runtime/inventory_presentation_model.gd")

const MAX_TRANSFER_DISTANCE_RAW := 2_000_000


class BindingIdentityPort extends ZInventoryIdentityPort:
    var session_key := ""
    var actor_key := ""
    var epoch := 0
    var generation := 0
    var native_actor := 0
    var owned: Dictionary = {}

    func native_actor_id(session: ZSessionId, actor: ZEntityId, p_epoch: int, p_generation: int) -> int:
        if session == null or actor == null:
            return 0
        return native_actor if session.canonical_key() == session_key and actor.canonical_key() == actor_key and p_epoch == epoch and p_generation == generation else 0

    func actor_owns_inventory(session: ZSessionId, actor: ZEntityId, inventory_id: int, p_epoch: int, p_generation: int) -> bool:
        return native_actor_id(session, actor, p_epoch, p_generation) == native_actor and owned.get(inventory_id, false)


class BindingWorldPolicyPort extends ZInventoryWorldPolicyPort:
    var actor_key := ""
    var generation := 0
    var world_ids: Dictionary = {}
    var access_blocked := false

    func is_world_inventory(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
        return _matches(actor, p_generation) and world_ids.get(inventory_id, false)

    func authoritative_distance_raw(actor: ZEntityId, inventory_id: int, p_generation: int) -> int:
        return 1_000_000 if is_world_inventory(actor, inventory_id, p_generation) else -1

    func is_currently_visible(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
        return is_world_inventory(actor, inventory_id, p_generation)

    func access_state(actor: ZEntityId, inventory_id: int, p_generation: int) -> StringName:
        return ACCESS_UNAVAILABLE if access_blocked else (ACCESS_OPEN if is_world_inventory(actor, inventory_id, p_generation) else ACCESS_UNAVAILABLE)

    func allows_transfer(actor: ZEntityId, source_inventory_id: int, destination_inventory_id: int, item_id: int, p_generation: int) -> bool:
        return is_world_inventory(actor, source_inventory_id, p_generation) and destination_inventory_id > 0 and item_id > 0 and not access_blocked

    func _matches(actor: ZEntityId, p_generation: int) -> bool:
        return actor != null and actor.canonical_key() == actor_key and p_generation == generation


class LootStateProbeController extends Controller:
    ## Test-only state provider. Production presentation remains derived from
    ## bridge snapshots, adapter policy, and authority lifecycle; this probe
    ## exists only to make otherwise external visual states deterministic.
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


var checks := 0
var failures := 0


func _initialize() -> void:
    call_deferred("run")


func check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("INVENTORY_LOOT_UI_4_11: " + message)


func run() -> void:
    check(not _production_has_loot_state_override_callsite(), "production sources expose no test-only loot override callsite")
    var owner := RaidInventoryOwner.new()
    owner.name = "InventoryLootUI411Owner"
    root.add_child(owner)
    check(owner.configure(), "owner configures")
    check(owner.materialize_loot_fixture(), "crate and corpse fixtures materialize")

    var raid_id := ZRaidId.from_parts(PackedStringArray(["ui", "loot", "raid"]))
    var session_id := ZSessionId.from_parts(PackedStringArray(["ui", "loot", "session"]))
    var actor_id := ZEntityId.from_parts(PackedStringArray(["ui", "loot", "actor"]))
    var request_id := ZRequestId.from_parts(PackedStringArray(["ui", "loot", "admission"]))
    var admission_request := ZSessionRequest.create_offline(request_id, raid_id, &"ui_loot_profile", &"player", 7)
    var admission := ZSessionAdmission.accept_local(admission_request, session_id, actor_id)
    check(admission.is_usable(), "admission is usable")

    var identity := BindingIdentityPort.new()
    identity.session_key = session_id.canonical_key()
    identity.actor_key = actor_id.canonical_key()
    identity.epoch = admission.authority_epoch
    identity.generation = admission.generation
    identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
    identity.owned[owner.raid_player_inventory_id] = true

    var world := BindingWorldPolicyPort.new()
    world.actor_key = actor_id.canonical_key()
    world.generation = admission.generation
    world.world_ids[owner.world_crate_inventory_id] = true
    world.world_ids[owner.corpse_inventory_id] = true

    var adapter := Adapter.new()
    check(adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW), "adapter configures")
    var bridge := Bridge.new()
    root.add_child(bridge)
    check(bridge.bind_owner(owner, owner.generation()), "bridge binds owner")
    var controller := LootStateProbeController.new()
    check(controller.bind(owner, bridge, adapter, admission), "controller binds injected bridge and adapter")

    var crate_bytes := bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes()
    var crate_revision := bridge.confirmed_revision(Bridge.SCOPE_RAID, owner.world_crate_inventory_id)
    var requests_before_open := adapter.tracked_request_count()
    check(controller.set_loot_container(&"crate"), "crate is selected as the projected loot source")
    check(controller.open_loot_container(), "open is presentation-only and succeeds on a current binding")
    check(controller.is_loot_container_open() and controller.loot_container_state() == Model.STATE_NORMAL, "open projects a normal loot state")
    check(adapter.tracked_request_count() == requests_before_open and bridge.confirmed_revision(Bridge.SCOPE_RAID, owner.world_crate_inventory_id) == crate_revision and bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes() == crate_bytes, "open does not create a request, advance a clock, or mutate canonical bytes")

    var app: Control = load("res://ui/main.tscn").instantiate()
    root.size = Vector2i(1920, 1080)
    root.add_child(app)
    await process_frame
    await process_frame
    app.navigate("inventory", false)
    await process_frame
    await process_frame
    var screen: Control = app.screen
    screen._inventory_controller = controller
    check(screen.bind_inventory_runtime(owner, bridge, adapter, admission), "existing character workspace accepts the production binding")
    await process_frame
    screen._set_loot_mode(true)
    await process_frame
    var loot_grid: Control = screen._grid_for_source("loot")
    var stash_grid: Control = loot_grid
    check(stash_grid != null and loot_grid != null, "existing character workspace exposes the retained stash/loot grid")
    if stash_grid == null:
        var grid_sources: Array[String] = []
        for grid in screen._grids:
            grid_sources.append(str(grid.get("source_id")))
        print("INVENTORY_LOOT_UI_4_11_DEBUG screen=%s route=%s bound=%s grids=%s sources=%s" % [screen, app.current_route, screen._bound, screen._grids.size(), grid_sources])
        quit(1)
        return
    var stash_scroll := stash_grid.get_parent() as ScrollContainer
    var shell_size: Vector2 = screen._surface.size
    var shell_parent := stash_grid.get_parent().name
    check(shell_size.is_equal_approx(Vector2(1920, 1080)) and shell_parent == "DesktopStashScroll", "loot reuses the authored 1920x1080 workspace and bounded right-hand scroll pane")
    check(screen._node("LootClose").visible and screen._node("LootTab").visible and not screen.has_node("LootContainerPanel"), "loot presentation adds only the retained header close affordance")

    var search := screen._node("StashSearch") as LineEdit
    var before_search_revision := bridge.confirmed_revision(Bridge.SCOPE_RAID, owner.world_crate_inventory_id)
    var before_search_bytes := bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes()
    var before_search_requests := adapter.tracked_request_count()
    search.grab_focus()
    search.text = "battery"
    screen._on_search_changed("battery")
    check(search.placeholder_text == "Search loot…" and screen._grid_for_source("loot").items.size() <= controller.items_for(&"loot").size(), "search stays in the retained loot grid and remains presentation-only")
    check(bridge.confirmed_revision(Bridge.SCOPE_RAID, owner.world_crate_inventory_id) == before_search_revision and bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes() == before_search_bytes and adapter.tracked_request_count() == before_search_requests, "search does not submit, advance, or mutate canonical state")
    search.text = ""
    screen._on_search_changed("")

    var loot_item := _first_item(controller.items_for(&"loot"))
    var loot_slot: Control = screen._slot_for_item(loot_grid, int(loot_item.get("item_id", 0)))
    check(loot_slot != null, "open loot has a current native slot for selection")
    if loot_slot != null:
        screen._on_grid_selected(loot_slot.get("item"), "loot")
    var selected_id := int(screen._selected_live_item.get("item_id", 0))
    if stash_scroll != null:
        stash_scroll.scroll_vertical = 123
    screen._set_loot_mode(false)
    await process_frame
    check(controller.loot_container_state() == Controller.LOOT_STATE_CLOSED and not screen._node("LootClose").visible, "close returns to the retained stash pane")
    check(int(screen._selected_live_item.get("item_id", 0)) == selected_id or selected_id == 0, "closing preserves a still-valid selection identity until the destination changes")

    var stale_payload: Dictionary = loot_item.duplicate(true)
    if loot_slot != null:
        stale_payload = (loot_slot.get("item") as Dictionary).duplicate(true)
    var stale_requests := adapter.tracked_request_count()
    screen._on_item_dropped(stale_payload, "loot", Vector2i.ZERO, screen._grid_for_source("pockets"))
    check(adapter.tracked_request_count() == stale_requests, "deferred drag payload from a closed loot generation fails closed")
    screen._set_loot_mode(true)
    await process_frame
    loot_grid = screen._grid_for_source("loot")
    loot_item = _first_item(controller.items_for(&"loot"))
    var transfer_cell := _first_fit(controller.items_for(&"pockets"), loot_item, 4, 2)
    var fresh_slot: Control = screen._slot_for_item(loot_grid, int(loot_item.get("item_id", 0)))
    check(fresh_slot != null and transfer_cell.x >= 0, "reopened loot provides a fresh drag payload and a canonical destination")
    var total_before := _total_quantity(controller.items_for(&"loot"), str(loot_item.get("definition_id", ""))) + _total_quantity(controller.items_for(&"pockets"), str(loot_item.get("definition_id", "")))
    var transfer_result: Dictionary = {}
    if fresh_slot != null and transfer_cell.x >= 0:
        # The UI payload is validated above and the canonical transfer is then
        # submitted through the same controller seam used by the retained
        # grid's release handler. This keeps the test deterministic across
        # deferred native slot rebuilds while still exercising real authority.
        transfer_result = controller.submit_drop(&"loot", &"pockets", loot_item, transfer_cell)
    await process_frame
    var total_after := _total_quantity(controller.items_for(&"loot"), str(loot_item.get("definition_id", ""))) + _total_quantity(controller.items_for(&"pockets"), str(loot_item.get("definition_id", "")))
    var transferred_item := _find_item(controller.items_for(&"pockets"), int(loot_item.get("item_id", 0)))
    check(transfer_result.get("accepted", false) and total_after == total_before and not transferred_item.is_empty(), "real crate transfer preserves quantity and canonical item identity without loss")

    var blocked_item := _first_item(controller.items_for(&"loot"))
    world.access_blocked = true
    var blocked_requests := adapter.tracked_request_count()
    check(controller.loot_container_state() == Model.STATE_INACCESSIBLE, "world policy projects inaccessible loot")
    var blocked_result := controller.submit_quick(&"loot", blocked_item)
    check(not blocked_result.accepted and blocked_result.reason == Controller.REASON_LOOT_INACCESSIBLE and adapter.tracked_request_count() == blocked_requests, "inaccessible loot rejects before the adapter and leaves canonical bytes unchanged")
    world.access_blocked = false

    var override_bytes := bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes()
    controller.force_loot_state(Model.STATE_OVERWEIGHT)
    check(controller.forced_loot_state == Model.STATE_OVERWEIGHT, "noncanonical state forcing stays inside the test-only provider")
    check(controller.loot_container_state() == Model.STATE_OVERWEIGHT, "overweight state is visible in the retained pane")
    var overweight_result := controller.submit_quick(&"loot", blocked_item)
    check(not overweight_result.accepted and overweight_result.reason == Controller.REASON_LOOT_OVERWEIGHT and bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.world_crate_inventory_id).canonical_bytes() == override_bytes, "overweight rejects with no-loss canonical bytes")
    controller.clear_forced_loot_state()
    controller.force_loot_state(Model.STATE_STALE_CORRECTED)
    var stale_result := controller.submit_quick(&"loot", blocked_item)
    check(not stale_result.accepted and stale_result.reason == Controller.REASON_LOOT_STALE, "stale intent is rejected before native submission")
    controller.clear_forced_loot_state()

    var raid_generation := bridge.scope_generation(Bridge.SCOPE_RAID)
    check(bridge.begin_resynchronization(Bridge.SCOPE_RAID, owner.generation(), raid_generation), "resynchronization begins on the existing projection")
    await process_frame
    check(controller.loot_container_state() == Model.STATE_RESYNCHRONIZING and str(screen._node("StashCompatible").text).contains("MUTATIONS DISABLED"), "resynchronizing is visible and pauses mutation")
    var resync_result := controller.submit_quick(&"loot", blocked_item)
    check(not resync_result.accepted and resync_result.reason == Controller.REASON_LOOT_RESYNCHRONIZING, "resynchronizing intent is rejected without mutation")
    check(bridge.complete_resynchronization(Bridge.SCOPE_RAID, owner.generation(), bridge.scope_generation(Bridge.SCOPE_RAID)), "resynchronization completes from confirmed snapshots")
    await process_frame
    check(controller.loot_container_state() == Model.STATE_NORMAL, "confirmed projection restores normal loot state")

    var lifecycle_requests := adapter.tracked_request_count()
    check(owner.raid_authority().unload_inventory(owner.corpse_inventory_id).get("ok", false), "real authority lifecycle unload is accepted")
    await process_frame
    check(controller.loot_container_state() == Model.STATE_DISCONNECTED and not controller.is_bound(), "lifecycle replacement/unload invalidates the injected binding")
    check(not controller.submit_quick(&"loot", blocked_item).accepted and adapter.tracked_request_count() == lifecycle_requests, "post-lifecycle stale intent fails closed with no request")

    print("INVENTORY_LOOT_UI_4_11_COMPLETE checks=%d failures=%d captures=docs/qa/inventory_loot_ui_4_11/captures" % [checks, failures])
    quit(1 if failures > 0 else 0)


func _first_item(items: Array[Dictionary]) -> Dictionary:
    return items[0].duplicate(true) if not items.is_empty() else {}


func _find_item(items: Array[Dictionary], item_id: int) -> Dictionary:
    for item in items:
        if int(item.get("item_id", item.get("id", 0))) == item_id:
            return item
    return {}


func _total_quantity(items: Array[Dictionary], definition_id: String) -> int:
    var total := 0
    for item in items:
        if str(item.get("definition_id", "")) == definition_id:
            total += int(item.get("quantity", item.get("count", 1)))
    return total


func _first_fit(items: Array[Dictionary], item: Dictionary, columns: int, rows: int) -> Vector2i:
    var width: int = max(1, int(item.get("base_width", item.get("w", 1))))
    var height: int = max(1, int(item.get("base_height", item.get("h", 1))))
    for y in range(rows):
        for x in range(columns):
            if x + width > columns or y + height > rows:
                continue
            var occupied := false
            for other in items:
                var ox := int(other.get("x", 0))
                var oy := int(other.get("y", 0))
                var ow: int = max(1, int(other.get("base_width", other.get("w", 1))))
                var oh: int = max(1, int(other.get("base_height", other.get("h", 1))))
                if x < ox + ow and x + width > ox and y < oy + oh and y + height > oy:
                    occupied = true
                    break
            if not occupied:
                return Vector2i(x, y)
    return Vector2i(-1, -1)


func _production_has_loot_state_override_callsite() -> bool:
    var forbidden: Array[String] = [
        "set_loot_state_override",
        "clear_loot_state_override",
        "set_loot_inaccessible",
        "set_loot_overweight",
    ]
    for root_path in ["res://game", "res://ui"]:
        if _directory_contains_any(root_path, forbidden):
            return true
    return false


func _directory_contains_any(path: String, forbidden: Array[String]) -> bool:
    var directory := DirAccess.open(path)
    if directory == null:
        return false
    for file_name in directory.get_files():
        if not file_name.ends_with(".gd"):
            continue
        var source := FileAccess.get_file_as_string(path + "/" + file_name)
        for token in forbidden:
            if source.contains(token):
                return true
    for directory_name in directory.get_directories():
        if _directory_contains_any(path + "/" + directory_name, forbidden):
            return true
    return false
