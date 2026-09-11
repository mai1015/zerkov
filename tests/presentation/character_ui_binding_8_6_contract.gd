extends SceneTree
## Task 8.6 exact-size contract. All authored authority data in this file is
## explicitly test-only; production composition never materializes it.
## Run with: godot --headless --path . --script res://tests/presentation/character_ui_binding_8_6_contract.gd

const EXACT_SIZE := Vector2i(1920, 1080)
const MAX_TRANSFER_DISTANCE_RAW := 2_000_000
const Catalog = preload("res://game/content/zerkov_inventory_catalog.gd")
const U = preload("res://ui/theme/tokens.gd")


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
    check(app.inject_character_runtime(runtime),
        "test-only runtime is accepted through the explicit pre-tree seam")
    root.add_child(app)
    await settle()
    check(app.get_node_or_null("CharacterPresentationComposition") == null,
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
    check(app.fixture_provider_for_route(
        "inventory", ZUIRouteIntent.Origin.PRODUCTION) == null,
        "production Character route cannot acquire the developer fixture provider")
    screen._refresh_body()
    await settle(2)
    check(screen._items_for("stash").size() == canonical_stash.size()
        and str(screen._items_for("stash")[0].get("name", "")) != "FORGED",
        "live rendering remains sourced only from the injected immutable view")

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
    var notice := health_area.get_node("LiveFixtureNotice") as Label
    var first_badge := health_area.get_node("DehydratedBadge") as Panel
    var aggregate_badge := health_area.get_node("RadiationBadge") as Panel
    var body_wide := health_area.get_node("BodyWide") as Label
    var first_label := first_badge.get_node("Text") as Label
    var aggregate_label := aggregate_badge.get_node("Text") as Label
    check(first_badge.visible and aggregate_badge.visible
        and body_wide.text == "BODY-WIDE · 4"
        and aggregate_label.text == "■  3 MORE EFFECTS",
        "all four effects are represented by ordered badges plus a bounded aggregate")
    check(first_badge.tooltip_text.contains("Critical systemic inflammatory response")
        and aggregate_badge.tooltip_text.contains("Coagulant boost")
        and aggregate_badge.tooltip_text.contains("Low radiation exposure")
        and aggregate_badge.tooltip_text.contains("Dehydrated")
        and body_wide.tooltip_text.contains("Critical systemic inflammatory response")
        and body_wide.tooltip_text.contains("Coagulant boost")
        and body_wide.tooltip_text.contains("Low radiation exposure")
        and body_wide.tooltip_text.contains("Dehydrated"),
        "critical third input sorts first and aggregate tooltip exposes every remaining effect")
    check(notice.mouse_filter != Control.MOUSE_FILTER_IGNORE
        and body_wide.mouse_filter != Control.MOUSE_FILTER_IGNORE
        and first_badge.mouse_filter != Control.MOUSE_FILTER_IGNORE
        and first_label.mouse_filter != Control.MOUSE_FILTER_IGNORE,
        "health notice, body-wide summary, badge, and label are native hover targets")
    var first_edge := first_badge.get_node("Edge") as ColorRect
    var first_style := first_badge.get_theme_stylebox("panel")
    var first_source := first_style.get("source") as StyleBoxFlat
    check(first_edge.color.is_equal_approx(U.RED)
        and first_label.get_theme_color("font_color").is_equal_approx(U.RED)
        and first_source != null and first_source.border_color.is_equal_approx(U.RED),
        "critical semantic color applies to badge panel, edge, and label")
    var aggregate_edge := aggregate_badge.get_node("Edge") as ColorRect
    var aggregate_style := aggregate_badge.get_theme_stylebox("panel")
    var aggregate_source := aggregate_style.get("source") as StyleBoxFlat
    check(aggregate_edge.color.is_equal_approx(U.YELLOW)
        and aggregate_label.get_theme_color("font_color").is_equal_approx(U.YELLOW)
        and aggregate_source != null
        and aggregate_source.border_color.is_equal_approx(U.YELLOW),
        "aggregate badge panel, edge, and label surface its strongest harmful severity")
    check(first_label.clip_text
        and first_label.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS
        and first_label.get_theme_font("font").get_string_size(
            first_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
            first_label.get_theme_font_size("font_size")).x > first_label.size.x,
        "long valid effect label is ellipsized inside the authored badge bounds")
    await _hover(first_badge.get_global_rect().get_center())
    var hovered_badge := root.gui_get_hovered_control()
    check(hovered_badge != null
        and (hovered_badge == first_badge or first_badge.is_ancestor_of(hovered_badge))
        and not hovered_badge.tooltip_text.is_empty(),
        "exact-1920 pointer motion reaches the effect tooltip target")
    await _hover(notice.get_global_rect().get_center())
    check(root.gui_get_hovered_control() == notice
        and notice.tooltip_text.contains("Immutable HealthView"),
        "exact-1920 pointer motion reaches the live-health notice tooltip")
    var health_revision_two := _health_view(
        fixture.admission as ZSessionAdmission, 2, 101, 80, 70)
    check(runtime.publish_health_view(health_revision_two),
        "newer matching HealthView is accepted")
    await settle(3)
    check((health_area.get_node("EnergyValue") as Label).text == "80/100"
        and (health_area.get_node("HydrationValue") as Label).text == "70/100",
        "health screen refreshes only from the newer injected snapshot")
    var observed_health := runtime.health_view()
    var health_emissions: Array[int] = [0]
    runtime.health_view_changed.connect(func(_view: HealthView) -> void:
        health_emissions[0] += 1)
    var exact_replay := _health_view(
        fixture.admission as ZSessionAdmission, 2, 101, 80, 70)
    check(exact_replay.content_digest() == observed_health.content_digest()
        and runtime.publish_health_view(exact_replay)
        and runtime.health_view() == observed_health
        and health_emissions[0] == 0,
        "equal-version equal-content HealthView is an immutable no-op replay")
    var divergent := _health_view(
        fixture.admission as ZSessionAdmission, 2, 101, 79, 70)
    check(divergent.content_digest() != observed_health.content_digest()
        and not runtime.publish_health_view(divergent)
        and runtime.last_error == &"health_view_version_divergent"
        and runtime.health_view() == observed_health
        and health_emissions[0] == 0,
        "equal-version divergent HealthView is rejected without replacing truth")
    var regressed_tick := _health_view(
        fixture.admission as ZSessionAdmission, 3, 100, 81, 71)
    check(not runtime.publish_health_view(regressed_tick)
        and runtime.last_error == &"health_view_version_regressed"
        and runtime.health_view() == observed_health
        and health_emissions[0] == 0,
        "higher revision cannot conceal a regressed HealthView source tick")
    check(not runtime.publish_health_view(_health_view(
        fixture.admission as ZSessionAdmission, 1, 99, 1, 1)),
        "stale HealthView revision is rejected")
    var beneficial_effects: Array[HealthView.StatusEffect] = [
        HealthView.StatusEffect.create(
            &"zerkov.effect.treatment.coagulant", "Coagulant boost",
            HealthView.Severity.MAJOR, 200, true),
    ]
    var beneficial_only := HealthView.create(
        (fixture.admission as ZSessionAdmission).generation, 3, 102,
        (fixture.admission as ZSessionAdmission).actor_id,
        observed_health.life_state(), observed_health.stamina(),
        observed_health.maximum_stamina(), observed_health.hydration(),
        observed_health.maximum_hydration(), observed_health.energy(),
        observed_health.maximum_energy(), observed_health.body_parts(),
        beneficial_effects)
    check(runtime.publish_health_view(beneficial_only),
        "newer beneficial-only HealthView is accepted")
    await settle(3)
    first_style = first_badge.get_theme_stylebox("panel")
    first_source = first_style.get("source") as StyleBoxFlat
    check(first_label.text.contains("COAGULANT BOOST")
        and first_edge.color.is_equal_approx(U.GREEN)
        and first_label.get_theme_color("font_color").is_equal_approx(U.GREEN)
        and first_source != null and first_source.border_color.is_equal_approx(U.GREEN),
        "beneficial state colors the complete displayed badge semantically")

    check(app.navigate("inventory"), "CommonUI admits health to inventory replacement")
    await settle()
    screen = app.screen
    search = screen._node("StashSearch") as LineEdit
    check(search.text == "bat" and search.caret_column == 2 and search.has_focus(),
        "route replacement restores semantic focus, caret, and query text=%s caret=%d focus=%s" % [
            search.text, search.caret_column, search.has_focus()])
    check(int(screen._selected_live_item.get("item_id", 0))
        == int(selected.get("item_id", 0)),
        "route replacement restores the valid selection without fixture storage")

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
    check(runtime.last_error == runtime.health_view().diagnostic()
        and runtime.last_error == runtime.inventory_view(&"raid").diagnostic(),
        "owner invalidation keeps runtime, inventory, and health reasons coherent")
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
    await _test_composition_screen_lifecycle()
    _finish()


func _test_production_composition() -> void:
    var app: Control = load("res://ui/main.tscn").instantiate()
    app.name = "CharacterUIBinding86ProductionProbe"
    root.add_child(app)
    await settle()
    var composition := app.get_node_or_null(
        "CharacterPresentationComposition") as CharacterPresentationComposition
    check(composition != null and composition.is_started(),
        "production host starts the injection-only Character composition")
    var runtime := composition.character_runtime()
    check(runtime != null and not runtime.is_configured()
        and runtime.items_for(&"stash").is_empty()
        and runtime.items_for(&"loot").is_empty(),
        "missing product authority cannot become an empty READY parallel owner")
    check(not runtime.inventory_view(&"profile").is_ready()
        and runtime.inventory_view(&"profile").diagnostic()
            == CharacterPresentationComposition.REASON_AUTHORITY_NOT_INJECTED
        and not runtime.health_view().is_ready()
        and runtime.health_view().diagnostic()
            == CharacterPresentationComposition.REASON_AUTHORITY_NOT_INJECTED
        and runtime.last_error
            == CharacterPresentationComposition.REASON_AUTHORITY_NOT_INJECTED,
        "missing authority publishes one matching typed unavailable reason")
    check(app.find_children("*", "RaidInventoryOwner", true, false).is_empty(),
        "production UI bootstrap does not manufacture a RaidInventoryOwner")
    var public_properties: Array[StringName] = []
    for property in app.get_property_list():
        public_properties.append(StringName(property.get("name", "")))
    check(&"character_runtime_override" not in public_properties
        and &"character_composition" not in public_properties,
        "production host exposes no public raw Character runtime/composition fields")
    app.queue_free()
    await settle(3)


func _test_composition_screen_lifecycle() -> void:
    var first := _build_test_runtime("composition_first", null, false)
    check(bool(first.get("ok", false)),
        "composition lifecycle fixture builds actual external dependencies")
    if not bool(first.get("ok", false)):
        return
    var composition := CharacterPresentationComposition.new()
    composition.name = "CharacterPresentationCompositionLifecycleProbe"
    root.add_child(composition)
    check(composition.start(
        first.owner, first.bridge, first.adapter, first.admission, first.health),
        "injection-only composition accepts externally owned dependencies")
    var runtime := composition.character_runtime()
    var app: Control = load("res://ui/main.tscn").instantiate()
    app.name = "CharacterCompositionLifecycleHost"
    check(app.inject_character_runtime(runtime),
        "composition runtime enters UI through the explicit pre-tree seam")
    root.add_child(app)
    await settle()
    check(app.navigate("inventory", false),
        "composition lifecycle probe opens the existing Character workspace")
    await settle()
    var screen: Control = app.screen
    var stash_grid: Control = screen._grid_for_source("stash")
    var old_token := int(stash_grid.binding_token)
    var old_item := stash_grid.items[0].duplicate(true) as Dictionary \
        if not stash_grid.items.is_empty() else {}
    var requests_before := (first.adapter as InventoryIntentAdapter).tracked_request_count()
    composition.teardown()
    await settle(3)
    check(not runtime.is_configured()
        and screen._items_for("stash").is_empty()
        and screen._active_binding_token == 0,
        "composition teardown clears an open screen and expires its gesture lease")
    check(runtime.last_error == &"character_composition_teardown"
        and runtime.inventory_view(&"profile").diagnostic() == runtime.last_error
        and runtime.health_view().diagnostic() == runtime.last_error,
        "teardown publishes matching typed inventory, health, and runtime reasons")
    check((first.owner as RaidInventoryOwner).lifecycle
            == RaidInventoryOwner.Lifecycle.ACTIVE
        and (first.bridge as InventoryProjectionBridge).is_bound()
        and (first.adapter as InventoryIntentAdapter).is_bound(),
        "composition teardown does not tear down externally owned authorities")
    if not old_item.is_empty():
        screen._on_item_dropped(old_item, "stash", Vector2i.ZERO,
            screen._grid_for_source("pockets"))
    check((first.adapter as InventoryIntentAdapter).tracked_request_count()
            == requests_before,
        "pre-teardown payload cannot submit after composition invalidation")

    var second := _build_test_runtime("composition_second", null, false)
    check(bool(second.get("ok", false)),
        "composition replacement fixture builds external dependencies")
    if bool(second.get("ok", false)):
        check(composition.start(
            second.owner, second.bridge, second.adapter,
            second.admission, second.health),
            "stopped composition reuses and rebinds its presentation runtime")
        await settle(4)
        var rebound_grid: Control = screen._grid_for_source("stash")
        check(composition.character_runtime() == runtime
            and runtime.is_configured()
            and rebound_grid.binding_token > old_token
            and not rebound_grid.items.is_empty(),
            "open screen atomically observes rebound views and an advanced token")

    app.queue_free()
    composition.queue_free()
    await settle(3)
    _dispose_fixture(second, false)
    _dispose_fixture(first, false)


func _build_test_runtime(
    tag: String,
    existing_runtime: CharacterUIRuntime = null,
    configure_runtime: bool = true
) -> Dictionary:
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
    var health := _health_view(admission, 1, 100, 64, 42)
    var runtime := existing_runtime
    var ok := true
    if configure_runtime:
        if runtime == null:
            runtime = CharacterUIRuntime.new()
            runtime.name = "CharacterUIBinding86Runtime"
            root.add_child(runtime)
        ok = runtime.configure(owner, bridge, adapter, admission, health)
    return {
        "ok": ok,
        "runtime": runtime,
        "owner": owner,
        "bridge": bridge,
        "adapter": adapter,
        "identity": identity,
        "world": world,
        "admission": admission,
        "health": health,
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
            &"zerkov.effect.survival.dehydrated", "Dehydrated",
            HealthView.Severity.INFO, 900),
        HealthView.StatusEffect.create(
            &"zerkov.effect.environment.radiation_low", "Low radiation exposure",
            HealthView.Severity.MINOR, 700),
        HealthView.StatusEffect.create(
            &"zerkov.effect.injury.systemic_response",
            "Critical systemic inflammatory response",
            HealthView.Severity.CRITICAL, 300),
        HealthView.StatusEffect.create(
            &"zerkov.effect.treatment.coagulant", "Coagulant boost",
            HealthView.Severity.MAJOR, 240, true),
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


func _hover(point: Vector2) -> void:
    var motion := InputEventMouseMotion.new()
    motion.position = point
    motion.global_position = point
    root.push_input(motion)
    await process_frame
    await process_frame


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
