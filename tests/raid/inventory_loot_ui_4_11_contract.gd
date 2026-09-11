extends SceneTree
## Task 4.11 contract: loot open/search/close extends the retained character
## workspace and never creates a second inventory or discovery authority.

const Controller = preload("res://game/inventory/presentation/inventory_presentation_controller.gd")
const Bridge = preload("res://game/inventory/presentation/inventory_projection_bridge.gd")
const Adapter = preload("res://game/inventory/inventory_intent_adapter.gd")
const Model = preload("res://addons/inventory_system/runtime/inventory_presentation_model.gd")
const Catalog = preload("res://game/content/zerkov_inventory_catalog.gd")

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
    var reentrant_stage: StringName = &""
    var reentrant_callback: Callable = Callable()
    var reentrant_denial := false
    var reentrant_denial_stage: StringName = &""

    func is_world_inventory(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
        var result: bool = _matches(actor, p_generation) and bool(world_ids.get(inventory_id, false))
        if reentrant_denial and reentrant_denial_stage == &"is_world_inventory":
            result = false
        _fire_reentrant(&"is_world_inventory")
        return result

    func authoritative_distance_raw(actor: ZEntityId, inventory_id: int, p_generation: int) -> int:
        var result := 1_000_000 if _matches(actor, p_generation) and world_ids.get(inventory_id, false) else -1
        if reentrant_denial and reentrant_denial_stage == &"authoritative_distance_raw":
            result = -1
        _fire_reentrant(&"authoritative_distance_raw")
        return result

    func is_currently_visible(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
        var result: bool = _matches(actor, p_generation) and bool(world_ids.get(inventory_id, false))
        if reentrant_denial and reentrant_denial_stage == &"is_currently_visible":
            result = false
        _fire_reentrant(&"is_currently_visible")
        return result

    func access_state(actor: ZEntityId, inventory_id: int, p_generation: int) -> StringName:
        var result := ACCESS_UNAVAILABLE if access_blocked else (ACCESS_OPEN if _matches(actor, p_generation) and world_ids.get(inventory_id, false) else ACCESS_UNAVAILABLE)
        if reentrant_denial and reentrant_denial_stage == &"access_state":
            result = ACCESS_CLOSED
        _fire_reentrant(&"access_state")
        return result

    func allows_transfer(actor: ZEntityId, source_inventory_id: int, destination_inventory_id: int, item_id: int, p_generation: int) -> bool:
        return is_world_inventory(actor, source_inventory_id, p_generation) and destination_inventory_id > 0 and item_id > 0 and not access_blocked

    func _matches(actor: ZEntityId, p_generation: int) -> bool:
        return actor != null and actor.canonical_key() == actor_key and p_generation == generation

    func arm_reentrant(stage: StringName, callback: Callable) -> void:
        reentrant_stage = stage
        reentrant_callback = callback

    func _fire_reentrant(stage: StringName) -> void:
        if stage != reentrant_stage or not reentrant_callback.is_valid():
            return
        var callback := reentrant_callback
        reentrant_stage = &""
        reentrant_callback = Callable()
        callback.call()


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
    var loot_status := screen._node("StashCompatible") as Label
    check(loot_status != null and loot_status.mouse_filter == Control.MOUSE_FILTER_PASS and loot_status.focus_mode == Control.FOCUS_NONE, "loot status detail accepts pointer hover without becoming a focus target")
    check(loot_status != null and loot_status.get_global_rect().has_point(Vector2(1701, 144)) and loot_status.tooltip_text == controller.loot_status_detail(), "exact 1920 status hit point exposes the full presentation detail")

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

    # Real native capacity rejection: five authored 5 kg supply crates leave
    # the 25 kg backpack below its 28 kg limit, so an AKM loot attempt is
    # rejected synchronously by InventoryAuthority without mutating either
    # inventory.  The controller must retain the causal hint across a
    # close/open cycle, but clear it when only the destination advances.
    var backpack_desc := controller.descriptor(&"backpack")
    var backpack_container_id := int(backpack_desc.get("container_id", 0))
    var capacity_positions := [
        Vector2i(0, 0), Vector2i(2, 0), Vector2i(4, 0),
        Vector2i(6, 0), Vector2i(0, 2),
    ]
    var inserted_capacity_ids: Array[int] = []
    var capacity_fixture_ok := backpack_container_id > 0
    for index in range(capacity_positions.size()):
        var capacity_insert: Dictionary = owner.raid_authority().insert_item(
            owner.raid_player_inventory_id,
            String(Catalog.ITEM_SUPPLY_CRATE),
            1,
            _spatial(backpack_container_id, capacity_positions[index].x, capacity_positions[index].y),
            RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
            9_100 + index
        )
        if bool(capacity_insert.get("accepted", false)):
            inserted_capacity_ids.append(int(capacity_insert.get("new_item_id", 0)))
        else:
            capacity_fixture_ok = false
    await process_frame
    var backpack_mass := owner.raid_authority().container_mass(
        owner.raid_player_inventory_id, backpack_container_id)
    var backpack_capacity := owner.raid_authority().container_mass_capacity(
        owner.raid_player_inventory_id, backpack_container_id)
    check(capacity_fixture_ok and inserted_capacity_ids.size() == 5
        and int(backpack_mass.get("mass_mg", -1)) == 25_000_000
        and int(backpack_capacity.get("mass_capacity_mg", -1)) == 28_000_000,
        "real capacity fixture establishes a 25 kg backpack against the authored 28 kg limit")

    world.access_blocked = false
    check(controller.set_loot_container(&"corpse"), "corpse becomes the exact live loot source for capacity proof")
    check(controller.open_loot_container(), "capacity proof opens the selected corpse without clearing canonical state")
    var akm_item := _first_definition(controller.items_for(&"loot"), String(Catalog.ITEM_AKM))
    var capacity_destination := _first_fit(controller.items_for(&"backpack"), akm_item, 8, 5)
    var capacity_source_revision := bridge.confirmed_revision(
        Bridge.SCOPE_RAID, owner.corpse_inventory_id)
    var capacity_destination_revision := bridge.confirmed_revision(
        Bridge.SCOPE_RAID, owner.raid_player_inventory_id)
    var capacity_source_bytes := bridge.confirmed_snapshot(
        Bridge.SCOPE_RAID, owner.corpse_inventory_id).canonical_bytes()
    var capacity_destination_bytes := bridge.confirmed_snapshot(
        Bridge.SCOPE_RAID, owner.raid_player_inventory_id).canonical_bytes()
    var capacity_rejection := controller.submit_drop(
        &"loot", &"backpack", akm_item, capacity_destination)
    await process_frame
    var capacity_receipt_revisions := capacity_rejection.get("revisions", []) as Array
    check(not bool(capacity_rejection.get("accepted", true))
        and int(capacity_rejection.get("status", {}).get("diagnostic", 0)) == 123
        and int(capacity_rejection.get("source_predecessor_revision", -1)) == capacity_source_revision
        and int(capacity_rejection.get("destination_predecessor_revision", -1)) == capacity_destination_revision
        and _receipt_revision(capacity_receipt_revisions, owner.corpse_inventory_id) == capacity_source_revision
        and _receipt_revision(capacity_receipt_revisions, owner.raid_player_inventory_id) == capacity_destination_revision
        and bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.corpse_inventory_id).canonical_bytes() == capacity_source_bytes
        and bridge.confirmed_snapshot(Bridge.SCOPE_RAID, owner.raid_player_inventory_id).canonical_bytes() == capacity_destination_bytes,
        "native capacity receipt preserves source/destination causal revisions and no-loss canonical bytes")
    check(controller.loot_container_state() == Model.STATE_OVERWEIGHT,
        "native capacity rejection latches overweight only for its exact causal pair")
    var captured_causal := controller.get("_loot_state_hint_causal") as Dictionary
    var captured_causal_revisions := captured_causal.get("revisions", {}) as Dictionary
    check(int(captured_causal.get("source_inventory_id", 0)) == owner.corpse_inventory_id
        and int(captured_causal.get("destination_inventory_id", 0)) == owner.raid_player_inventory_id
        and int(captured_causal_revisions.get(owner.corpse_inventory_id, -1)) == capacity_source_revision
        and int(captured_causal_revisions.get(owner.raid_player_inventory_id, -1)) == capacity_destination_revision
        and int(captured_causal.get("owner_generation", 0)) == owner.generation()
        and int(captured_causal.get("scope_generation", 0)) == bridge.scope_generation(Bridge.SCOPE_RAID)
        and int(captured_causal.get("binding_serial", 0)) == int(controller.get("_binding_serial")),
        "persistent hint stores exact source/destination ids, revisions, binding serial, and scope generation")
    controller._on_model_rejection({
        "inventory_id": owner.corpse_inventory_id,
        "items": [int(akm_item.get("item_id", 0))],
        "reason_token": "inventory.presentation.reason.overweight",
        "status": {"reason": "overweight"},
    }, Bridge.SCOPE_RAID)
    check(controller.loot_container_state() == Model.STATE_OVERWEIGHT,
        "generic model rejection feedback cannot replace the native causal hint")

    screen._set_loot_mode(false)
    await process_frame
    screen._set_loot_mode(true)
    await process_frame
    check(controller.loot_container_state() == Model.STATE_OVERWEIGHT,
        "close/open of the unchanged loot source retains a still-causal rejection hint")

    world.access_blocked = true
    var policy_blocked_requests := adapter.tracked_request_count()
    check(controller.loot_container_state() == Model.STATE_INACCESSIBLE,
        "live inaccessible policy outranks a causal overweight hint")
    var policy_blocked_retry := controller.submit_quick(&"loot", akm_item)
    check(not bool(policy_blocked_retry.get("accepted", true))
        and policy_blocked_retry.get("reason", &"") == Controller.REASON_LOOT_INACCESSIBLE
        and adapter.tracked_request_count() == policy_blocked_requests,
        "inaccessible policy prevents a retry without creating a request")
    world.access_blocked = false

    check(controller.set_loot_container(&"crate"), "switching loot source discards only the old source hint")
    check(controller.open_loot_container() and controller.loot_container_state() == Model.STATE_NORMAL,
        "switched crate source is evaluated from its live projection")
    check(controller.set_loot_container(&"corpse"), "switching back selects the exact corpse source")
    check(controller.open_loot_container() and controller.loot_container_state() == Model.STATE_NORMAL,
        "discarded source hint does not reappear after a source switch")

    # Recreate the rejection so a destination-only revision can prove the
    # causal tuple is not source-only.  Removing one crate advances the player
    # projection while corpse revision stays unchanged and must clear the hint.
    var second_capacity_destination := _first_fit(controller.items_for(&"backpack"), akm_item, 8, 5)
    var second_rejection := controller.submit_drop(
        &"loot", &"backpack", akm_item, second_capacity_destination)
    await process_frame
    check(not bool(second_rejection.get("accepted", true))
        and controller.loot_container_state() == Model.STATE_OVERWEIGHT,
        "second native capacity rejection restores the exact causal hint")
    var destination_only_source_revision := bridge.confirmed_revision(
        Bridge.SCOPE_RAID, owner.corpse_inventory_id)
    var destination_only_revision := bridge.confirmed_revision(
        Bridge.SCOPE_RAID, owner.raid_player_inventory_id)
    var removed_capacity := owner.raid_authority().remove_item(
        owner.raid_player_inventory_id,
        inserted_capacity_ids[0],
        RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID,
        9_200)
    await process_frame
    check(bool(removed_capacity.get("accepted", false))
        and bridge.confirmed_revision(Bridge.SCOPE_RAID, owner.raid_player_inventory_id) > destination_only_revision
        and bridge.confirmed_revision(Bridge.SCOPE_RAID, owner.corpse_inventory_id) == destination_only_source_revision
        and controller.loot_container_state() == Model.STATE_NORMAL,
        "destination-only revision advancement clears the stale overweight hint and recomputes live policy")
    var retry_after_destination_revision := controller.submit_drop(
        &"loot", &"backpack", akm_item, second_capacity_destination)
    await process_frame
    check(bool(retry_after_destination_revision.get("accepted", false)),
        "retry after destination-only advancement reaches native authority with current revisions")

    check(controller.set_loot_container(&"crate") and controller.open_loot_container(),
        "capacity proof restores the crate source before resynchronization")

    await _run_reentrant_policy_state_probes()
    await _run_controller_reentrant_policy_probe()

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


func _first_definition(items: Array[Dictionary], definition_id: String) -> Dictionary:
    for item in items:
        if str(item.get("definition_id", item.get("item_definition_identifier", ""))) == definition_id:
            return item.duplicate(true)
    return {}


func _spatial(container_id: int, x: int, y: int, rotated: bool = false) -> Dictionary:
    return {
        "kind": "spatial",
        "container": container_id,
        "x": x,
        "y": y,
        "rotated": rotated,
    }


func _receipt_revision(revisions: Array, inventory_id: int) -> int:
    for value in revisions:
        if not value is Dictionary:
            continue
        var revision := value as Dictionary
        if int(revision.get("inventory", 0)) == inventory_id:
            return int(revision.get("predecessor", -1))
    return -1


func _run_reentrant_policy_state_probes() -> void:
    for stage in [&"is_world_inventory", &"authoritative_distance_raw", &"is_currently_visible", &"access_state"]:
        for denial in [false, true]:
            var probe_owner := RaidInventoryOwner.new()
            var stage_key := String(stage) + ("_denial" if denial else "_success")
            probe_owner.name = "InventoryLootUI411PolicyProbe_%s" % stage_key
            root.add_child(probe_owner)
            var configured := probe_owner.configure()
            check(configured, "reentrant policy %s owner configures" % stage_key)
            if not configured:
                probe_owner.queue_free()
                await process_frame
                continue
            var raid_id := ZRaidId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key]))
            var session_id := ZSessionId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key, "session"]))
            var actor_id := ZEntityId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key, "actor"]))
            var admission_request := ZSessionRequest.create_offline(
                ZRequestId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key, "admission"])),
                raid_id, &"ui_loot_policy_profile", &"player", 7)
            var admission := ZSessionAdmission.accept_local(admission_request, session_id, actor_id)
            var identity := BindingIdentityPort.new()
            identity.session_key = session_id.canonical_key()
            identity.actor_key = actor_id.canonical_key()
            identity.epoch = admission.authority_epoch
            identity.generation = admission.generation
            identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
            identity.owned[probe_owner.raid_player_inventory_id] = true
            var world := BindingWorldPolicyPort.new()
            world.actor_key = actor_id.canonical_key()
            world.generation = admission.generation
            world.world_ids[probe_owner.world_crate_inventory_id] = true
            world.reentrant_denial = denial
            world.reentrant_denial_stage = stage
            var probe_adapter := Adapter.new()
            check(probe_adapter.configure(probe_owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW),
                "reentrant policy %s adapter configures" % stage_key)
            var captured_owner := probe_owner
            var captured_generation := probe_owner.generation()
            world.arm_reentrant(stage, func() -> void:
                captured_owner.teardown(captured_generation)
            )
            var policy := probe_adapter.world_policy_state(probe_owner.world_crate_inventory_id)
            check(not bool(policy.get("available", true))
                and policy.get("reason", &"") == &"inventory_runtime_stale_binding",
                "policy %s callback fails closed before interpreting its returned value" % stage_key)
            probe_owner.queue_free()
            await process_frame


func _run_controller_reentrant_policy_probe() -> void:
    var probe_owner := RaidInventoryOwner.new()
    probe_owner.name = "InventoryLootUI411ControllerPolicyProbe"
    root.add_child(probe_owner)
    check(probe_owner.configure(), "controller reentrant policy owner configures")
    var stage_key := "controller"
    var raid_id := ZRaidId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key]))
    var session_id := ZSessionId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key, "session"]))
    var actor_id := ZEntityId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key, "actor"]))
    var admission_request := ZSessionRequest.create_offline(
        ZRequestId.from_parts(PackedStringArray(["ui", "loot", "policy", stage_key, "admission"])),
        raid_id, &"ui_loot_policy_profile", &"player", 7)
    var admission := ZSessionAdmission.accept_local(admission_request, session_id, actor_id)
    var identity := BindingIdentityPort.new()
    identity.session_key = session_id.canonical_key()
    identity.actor_key = actor_id.canonical_key()
    identity.epoch = admission.authority_epoch
    identity.generation = admission.generation
    identity.native_actor = RaidInventoryOwner.FIXTURE_ACTOR_ID
    identity.owned[probe_owner.raid_player_inventory_id] = true
    var world := BindingWorldPolicyPort.new()
    world.actor_key = actor_id.canonical_key()
    world.generation = admission.generation
    world.world_ids[probe_owner.world_crate_inventory_id] = true
    var probe_adapter := Adapter.new()
    check(probe_adapter.configure(probe_owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW),
        "controller reentrant policy adapter configures")
    var probe_bridge := Bridge.new()
    root.add_child(probe_bridge)
    check(probe_bridge.bind_owner(probe_owner, probe_owner.generation()),
        "controller reentrant policy bridge binds")
    var probe_controller := Controller.new()
    check(probe_controller.bind(probe_owner, probe_bridge, probe_adapter, admission),
        "controller reentrant policy controller binds")
    check(probe_controller.open_loot_container(), "controller reentrant policy opens loot")
    var captured_owner := probe_owner
    var captured_generation := probe_owner.generation()
    world.arm_reentrant(&"is_world_inventory", func() -> void:
        captured_owner.teardown(captured_generation)
    )
    var requests_before := probe_adapter.tracked_request_count()
    var state := probe_controller.loot_container_state()
    check(state == Model.STATE_DISCONNECTED and not probe_controller.is_bound()
        and probe_adapter.tracked_request_count() == requests_before,
        "controller rechecks binding after policy teardown and projects disconnected without submissions")
    var rejected := probe_controller.submit_quick(&"loot", {})
    check(not bool(rejected.get("accepted", true))
        and rejected.get("reason", &"") == Controller.REASON_UNBOUND
        and probe_adapter.tracked_request_count() == requests_before,
        "controller rejection agrees with disconnected state and keeps request delta at zero")
    probe_controller.unbind()
    probe_bridge.queue_free()
    probe_owner.queue_free()
    await process_frame


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
