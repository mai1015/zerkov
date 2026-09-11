extends SceneTree
## Task 8.6 exact-size contract. All authored authority data in this file is
## explicitly test-only; production composition never materializes it.
## Run with: godot --headless --path . --script res://tests/presentation/character_ui_binding_8_6_contract.gd

const EXACT_SIZE := Vector2i(1920, 1080)
const MAX_TRANSFER_DISTANCE_RAW := 2_000_000
const Catalog = preload("res://game/content/zerkov_inventory_catalog.gd")


class TestWorldPolicy extends ZInventoryWorldPolicyPort:
    var actor_key := ""
    var generation := 0
    var world_ids: Dictionary = {}

    func is_world_inventory(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
        return _matches(actor, p_generation) and bool(world_ids.get(inventory_id, false))

    func authoritative_distance_raw(actor: ZEntityId, inventory_id: int, p_generation: int) -> int:
        return 1_000_000 if is_world_inventory(actor, inventory_id, p_generation) else -1

    func is_currently_visible(actor: ZEntityId, inventory_id: int, p_generation: int) -> bool:
        return is_world_inventory(actor, inventory_id, p_generation)

    func access_state(actor: ZEntityId, inventory_id: int, p_generation: int) -> StringName:
        return ACCESS_OPEN if is_world_inventory(actor, inventory_id, p_generation) else ACCESS_UNAVAILABLE

    func allows_transfer(actor: ZEntityId, source_inventory_id: int, destination_inventory_id: int, item_id: int, p_generation: int) -> bool:
        return is_world_inventory(actor, source_inventory_id, p_generation) \
            and destination_inventory_id > 0 and item_id > 0

    func _matches(actor: ZEntityId, p_generation: int) -> bool:
        return actor != null and actor.canonical_key() == actor_key \
            and p_generation == generation


var checks := 0
var failures := 0


func _initialize() -> void:
    run.call_deferred()


func check(value: bool, message: String) -> void:
    checks += 1
    if not value:
        failures += 1
        push_error("CHARACTER_UI_BINDING_8_6: " + message)


func settle(frames: int = 8) -> void:
    for _index in range(frames):
        await process_frame


func run() -> void:
    root.size = EXACT_SIZE
    await _test_production_composition()

    var fixture := _build_test_runtime("primary")
    check(bool(fixture.get("ok", false)), "test-only real authority fixture configures")
    if not bool(fixture.get("ok", false)):
        _finish()
        return
    var runtime := fixture.runtime as CharacterUIRuntime
    var app: Control = load("res://ui/main.tscn").instantiate()
    app.name = "CharacterUIBinding86Host"
    app.character_runtime_override = runtime
    root.add_child(app)
    await settle()
    check(app.character_composition == null,
        "explicit test injection does not create a second production owner")
    check(app.navigate("inventory", false), "production Character route is admitted")
    await settle()
    var screen: Control = app.screen
    var profile_view := runtime.inventory_view(&"profile")
    var raid_view := runtime.inventory_view(&"raid")
    check(screen != null and screen._character_runtime == runtime,
        "existing Character screen receives the injected shared runtime")
    check(profile_view != null and profile_view.is_ready()
        and raid_view != null and raid_view.is_ready(),
        "screen consumes ready immutable InventoryView snapshots")
    check(profile_view.containers().is_read_only()
        and raid_view.containers().is_read_only(),
        "injected inventory collections remain immutable")

    var stash_grid: Control = screen._grid_for_source("stash")
    var stash_scroll := stash_grid.get_parent() as ScrollContainer
    check(stash_grid != null and stash_grid.get_cell_size() == 74,
        "accepted desktop grids retain the exact 74px cell contract")
    check(stash_scroll != null
        and stash_scroll.get_global_rect().position.is_equal_approx(Vector2(1304, 225))
        and stash_scroll.get_global_rect().size.is_equal_approx(Vector2(518, 740)),
        "right Stash/Loot pane retains exact 1920x1080 geometry")
    check(not screen.has_node("LootContainerPanel")
        and screen.get_node("InventoryContent").size.is_equal_approx(Vector2(EXACT_SIZE)),
        "binding reuses the authored workspace without a replacement panel")

    var canonical_stash := runtime.items_for(&"stash")
    check(not canonical_stash.is_empty() and stash_grid.items.size() == canonical_stash.size(),
        "stash widgets derive from the injected confirmed projection")
    app.state["inventory_data"] = {"stash": [{"id": "forged", "name": "FORGED"}]}
    screen._refresh_body()
    await settle(2)
    check(screen._items_for("stash").size() == canonical_stash.size()
        and str(screen._items_for("stash")[0].get("name", "")) != "FORGED",
        "live rendering ignores the historical app.state canonical fixture")

    var search := screen._node("StashSearch") as LineEdit
    search.text = "bat"
    search.caret_column = 2
    screen._on_search_changed(search.text)
    search.grab_focus()
    stash_scroll.scroll_vertical = 123
    await process_frame
    var assigned_scroll := stash_scroll.scroll_vertical
    var selected := canonical_stash[0].duplicate(true) as Dictionary
    selected["_binding_token"] = int(stash_grid.binding_token)
    screen._on_grid_selected(selected, "stash")
    screen._refresh_body()
    await settle(3)
    check(search.has_focus() and search.caret_column == 2 and search.text == "bat",
        "projection refresh preserves native search focus and caret")
    check((screen._grid_for_source("stash").get_parent() as ScrollContainer).scroll_vertical
        == assigned_scroll, "projection refresh preserves the exact right-pane scroll offset")
    check(int(screen._selected_live_item.get("item_id", 0))
        == int(selected.get("item_id", 0)),
        "projection refresh preserves a still-valid selected identity")

    check(app.navigate("health"), "CommonUI admits inventory to health replacement")
    await settle()
    var health_screen: Control = app.screen
    var health_area := health_screen._node("HealthColumn") as Control
    check(app.current_route == "health" and health_screen != screen
        and health_screen._character_runtime == runtime,
        "CommonUI replacement reuses the shared injected runtime")
    check((health_area.get_node("HealthValue") as Label).text == "320/440"
        and (health_area.get_node("EnergyValue") as Label).text == "64/100"
        and (health_area.get_node("HydrationValue") as Label).text == "42/100",
        "health screen renders totals from the immutable HealthView")
    check((health_area.get_node("QuickHeal") as Button).disabled,
        "live quick-heal remains unavailable until its declared intent task")
    var health_revision_two := _health_view(
        fixture.admission as ZSessionAdmission, 2, 101, 80, 70)
    check(runtime.publish_health_view(health_revision_two),
        "newer matching HealthView is accepted")
    await settle(3)
    check((health_area.get_node("EnergyValue") as Label).text == "80/100"
        and (health_area.get_node("HydrationValue") as Label).text == "70/100",
        "health screen refreshes only from the newer injected snapshot")
    check(not runtime.publish_health_view(_health_view(
        fixture.admission as ZSessionAdmission, 1, 99, 1, 1)),
        "stale HealthView revision is rejected")

    check(app.navigate("inventory"), "CommonUI admits health to inventory replacement")
    await settle()
    screen = app.screen
    search = screen._node("StashSearch") as LineEdit
    check(search.text == "bat" and search.caret_column == 2 and search.has_focus(),
        "route replacement restores semantic focus, caret, and query text=%s caret=%d focus=%s" % [
            search.text, search.caret_column, search.has_focus()])
    check(int(screen._selected_live_item.get("item_id", 0))
        == int(selected.get("item_id", 0)),
        "route replacement restores the valid selection without app.state")

    var controller := runtime.inventory_controller()
    check(controller.set_loot_container(&"crate") and controller.open_loot_container(),
        "declared live loot source opens through the accepted controller seam")
    screen._set_loot_mode(true)
    await settle(3)
    var loot_items := runtime.items_for(&"loot")
    var requests_before := (fixture.adapter as InventoryIntentAdapter).tracked_request_count()
    var transfer_result: Dictionary = {}
    if not loot_items.is_empty():
        transfer_result = controller.submit_quick(&"loot", loot_items[0])
    await settle(3)
    check(not loot_items.is_empty() and bool(transfer_result.get("accepted", false))
        and (fixture.adapter as InventoryIntentAdapter).tracked_request_count() == requests_before + 1,
        "live gesture submits exactly one declared inventory intent")

    var old_grid: Control = screen._grid_for_source("loot")
    var old_payload := old_grid.items[0].duplicate(true) as Dictionary \
        if not old_grid.items.is_empty() else {}
    var old_token := int(old_grid.binding_token)
    var old_requests := (fixture.adapter as InventoryIntentAdapter).tracked_request_count()
    (fixture.owner as RaidInventoryOwner).teardown(
        (fixture.owner as RaidInventoryOwner).generation())
    await settle(3)
    check(not runtime.is_configured() and not runtime.inventory_view(&"raid").is_ready(),
        "owner teardown publishes a typed disconnected inventory state")
    check(screen._items_for("loot").is_empty() and screen._active_binding_token == 0,
        "disconnected screen empties live rows and invalidates gestures")
    if not old_payload.is_empty():
        screen._on_item_dropped(old_payload, "loot", Vector2i.ZERO,
            screen._grid_for_source("pockets"))
    check((fixture.adapter as InventoryIntentAdapter).tracked_request_count() == old_requests,
        "captured pre-teardown payload fails closed with no request")

    var replacement := _build_test_runtime("replacement", runtime)
    check(bool(replacement.get("ok", false)), "replacement real authority fixture configures")
    await settle(4)
    var rebound_grid: Control = screen._grid_for_source("stash")
    check(runtime.is_configured() and rebound_grid.binding_token > old_token,
        "retained screen advances its binding token on runtime rebound")
    check(screen._selected_live_item.is_empty(),
        "actor/generation replacement drops stale selection identity")
    check(screen._search_query == "bat",
        "actor/generation replacement preserves presentation-only query")
    if not old_payload.is_empty():
        var replacement_requests := (replacement.adapter as InventoryIntentAdapter).tracked_request_count()
        screen._on_item_dropped(old_payload, "loot", Vector2i.ZERO,
            screen._grid_for_source("pockets"))
        check((replacement.adapter as InventoryIntentAdapter).tracked_request_count()
            == replacement_requests,
            "old-generation payload cannot submit against replacement authority")

    app.queue_free()
    _dispose_fixture(replacement)
    _dispose_fixture(fixture, false)
    await settle(3)
    _finish()


func _test_production_composition() -> void:
    var app: Control = load("res://ui/main.tscn").instantiate()
    app.name = "CharacterUIBinding86ProductionProbe"
    root.add_child(app)
    await settle()
    var composition := app.character_composition as CharacterPresentationComposition
    check(composition != null and composition.is_started(),
        "production host composes a real Character presentation owner")
    check(composition.runtime != null and composition.runtime.is_configured()
        and composition.owner() != null and composition.bridge() != null
        and composition.adapter() != null,
        "production composition injects owner, projection, and intent dependencies")
    check(composition.runtime.items_for(&"stash").is_empty()
        and composition.runtime.items_for(&"loot").is_empty(),
        "production composition has no mock or prototype item fallback")
    check(not composition.runtime.health_view().is_ready()
        and composition.runtime.health_view().diagnostic() == &"health_authority_not_connected",
        "missing health authority fails closed as a typed unavailable view")
    app.queue_free()
    await settle(3)


func _build_test_runtime(tag: String, existing_runtime: CharacterUIRuntime = null) -> Dictionary:
    var owner := RaidInventoryOwner.new()
    owner.name = "CharacterUIBinding86Owner_" + tag
    root.add_child(owner)
    if not owner.configure() or not owner.materialize_loot_fixture():
        return {"ok": false, "owner": owner}
    var stash_container := _root_container_id(owner.profile_authority(), owner.profile_inventory_id)
    var stash_insert := owner.profile_authority().insert_item(
        owner.profile_inventory_id, String(Catalog.ITEM_BATTERY), 2,
        _spatial(stash_container, 0, 0), RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 8_601)
    if not bool(stash_insert.get("accepted", false)):
        return {"ok": false, "owner": owner}
    var raid_id := ZRaidId.from_parts(PackedStringArray(["test", "character", "binding", tag]))
    var admission := SessionCoordinator.new().open_offline(
        raid_id, StringName("test_profile_" + tag), &"player")
    var identity := OfflineInventoryIdentity.new()
    if not identity.configure(admission, owner, RaidInventoryOwner.FIXTURE_ACTOR_ID):
        return {"ok": false, "owner": owner}
    var world := TestWorldPolicy.new()
    world.actor_key = admission.actor_id.canonical_key()
    world.generation = admission.generation
    world.world_ids[owner.world_crate_inventory_id] = true
    world.world_ids[owner.corpse_inventory_id] = true
    var adapter := InventoryIntentAdapter.new()
    if not adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW):
        return {"ok": false, "owner": owner}
    var bridge := InventoryProjectionBridge.new()
    bridge.name = "CharacterUIBinding86Bridge_" + tag
    root.add_child(bridge)
    if not bridge.bind_owner(owner, owner.generation()):
        return {"ok": false, "owner": owner, "bridge": bridge}
    var runtime := existing_runtime
    if runtime == null:
        runtime = CharacterUIRuntime.new()
        runtime.name = "CharacterUIBinding86Runtime"
        root.add_child(runtime)
    var health := _health_view(admission, 1, 100, 64, 42)
    var ok := runtime.configure(owner, bridge, adapter, admission, health)
    return {
        "ok": ok,
        "runtime": runtime,
        "owner": owner,
        "bridge": bridge,
        "adapter": adapter,
        "identity": identity,
        "world": world,
        "admission": admission,
    }


func _health_view(
    admission: ZSessionAdmission,
    revision: int,
    source_tick: int,
    energy: int,
    hydration: int
) -> HealthView:
    var parts: Array[HealthView.BodyPart] = [
        HealthView.BodyPart.create(&"head", "Head", 35, 35, HealthView.BodyPartState.HEALTHY),
        HealthView.BodyPart.create(&"thorax", "Thorax", 70, 85, HealthView.BodyPartState.INJURED, true),
        HealthView.BodyPart.create(&"abdomen", "Abdomen", 45, 70, HealthView.BodyPartState.INJURED),
        HealthView.BodyPart.create(&"left_arm", "Left arm", 50, 60, HealthView.BodyPartState.INJURED),
        HealthView.BodyPart.create(&"right_arm", "Right arm", 60, 60, HealthView.BodyPartState.HEALTHY),
        HealthView.BodyPart.create(&"left_leg", "Left leg", 30, 65, HealthView.BodyPartState.INJURED, false, true),
        HealthView.BodyPart.create(&"right_leg", "Right leg", 30, 65, HealthView.BodyPartState.INJURED),
    ]
    var effects: Array[HealthView.StatusEffect] = [
        HealthView.StatusEffect.create(
            &"zerkov.effect.injury.heavy_bleed", "Heavy bleed",
            HealthView.Severity.CRITICAL, 300),
    ]
    return HealthView.create(
        admission.generation, revision, source_tick, admission.actor_id,
        HealthView.LifeState.ALIVE, 75, 100, hydration, 100, energy, 100,
        parts, effects)


func _root_container_id(authority: InventoryAuthority, inventory_id: int) -> int:
    var snapshot := authority.snapshot(inventory_id)
    if snapshot == null:
        return 0
    for value in snapshot.get_containers():
        var container := value as Dictionary
        if int(container.get("provider_item", 0)) == 0:
            return int(container.get("id", 0))
    return 0


func _spatial(container_id: int, x: int, y: int) -> Dictionary:
    return {"kind": "spatial", "container": container_id, "x": x, "y": y, "rotated": false}


func _dispose_fixture(fixture: Dictionary, release_runtime: bool = true) -> void:
    var runtime := fixture.get("runtime") as CharacterUIRuntime
    if release_runtime and runtime != null and is_instance_valid(runtime):
        runtime.release(&"test_fixture_disposed", false)
        runtime.queue_free()
    var adapter := fixture.get("adapter") as InventoryIntentAdapter
    if adapter != null and adapter.is_bound():
        adapter.release_binding(&"test_fixture_disposed")
    var bridge := fixture.get("bridge") as InventoryProjectionBridge
    if bridge != null and is_instance_valid(bridge):
        bridge.release_binding()
        bridge.queue_free()
    var identity := fixture.get("identity") as OfflineInventoryIdentity
    if identity != null:
        identity.release()
    var owner := fixture.get("owner") as RaidInventoryOwner
    if owner != null and is_instance_valid(owner):
        if owner.lifecycle == RaidInventoryOwner.Lifecycle.ACTIVE:
            owner.teardown(owner.generation())
        owner.queue_free()


func _finish() -> void:
    print("CHARACTER_UI_BINDING_8_6_RESULT checks=%d failures=%d size=1920x1080" % [
        checks, failures])
    quit(0 if failures == 0 else 1)
