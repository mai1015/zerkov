extends SceneTree
## Exact 1920x1080-only task 8.6 evidence. This runner is intentionally
## standalone and never loads the deferred inventory_ui_binding visual packet.
## All populated authority data below is capture-only.

const EXACT_SIZE := Vector2i(1920, 1080)
const OUTPUT := "res://docs/qa/live_character_ui_8_6/captures"
const MAX_TRANSFER_DISTANCE_RAW := 2_000_000
const Catalog = preload("res://game/content/zerkov_inventory_catalog.gd")


class CaptureWorldPolicy extends ZInventoryWorldPolicyPort:
    var actor_key := ""
    var generation := 0
    var inventory_id := 0

    func is_world_inventory(actor: ZEntityId, candidate: int, p_generation: int) -> bool:
        return actor != null and actor.canonical_key() == actor_key \
            and candidate == inventory_id and p_generation == generation

    func authoritative_distance_raw(actor: ZEntityId, candidate: int, p_generation: int) -> int:
        return 1_000_000 if is_world_inventory(actor, candidate, p_generation) else -1

    func is_currently_visible(actor: ZEntityId, candidate: int, p_generation: int) -> bool:
        return is_world_inventory(actor, candidate, p_generation)

    func access_state(actor: ZEntityId, candidate: int, p_generation: int) -> StringName:
        return ACCESS_OPEN if is_world_inventory(actor, candidate, p_generation) else ACCESS_UNAVAILABLE

    func allows_transfer(actor: ZEntityId, source: int, destination: int, item_id: int, p_generation: int) -> bool:
        return is_world_inventory(actor, source, p_generation) \
            and destination > 0 and item_id > 0


var checks := 0
var failures := 0
var records: Array[Dictionary] = []
var app: Control
var runtime: CharacterUIRuntime
var owner: RaidInventoryOwner
var bridge: InventoryProjectionBridge
var adapter: InventoryIntentAdapter
var identity: OfflineInventoryIdentity
var admission: ZSessionAdmission


func _initialize() -> void:
    run.call_deferred()


func check(value: bool, message: String) -> void:
    checks += 1
    if not value:
        failures += 1
        push_error("LIVE_CHARACTER_UI_8_6_CAPTURE: " + message)


func settle(frames: int = 24) -> void:
    for _index in range(frames):
        await process_frame
    # Graphical capture runs uncapped; frame count alone may advance less wall
    # time than the accepted CommonUI activation transition requires.
    await create_timer(0.35).timeout


func run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("Task 8.6 captures require a graphical renderer")
        quit(1)
        return
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
    root.borderless = true
    root.position = Vector2i.ZERO
    root.size = EXACT_SIZE
    check(root.size == EXACT_SIZE, "capture root is exact 1920x1080")
    check(_setup_capture_runtime(), "capture-only real authority runtime configures")
    if failures > 0:
        _finish()
        return
    app = load("res://ui/main.tscn").instantiate()
    app.name = "LiveCharacterUI86CaptureHost"
    check(app.inject_character_runtime(runtime),
        "test-only runtime injection is accepted before tree entry")
    if failures > 0:
        _finish()
        return
    root.add_child(app)
    await settle()

    app.navigate("inventory", false)
    await settle()
    var screen: Control = app.screen
    screen._set_loot_mode(true)
    await settle()
    await _capture("inventory_ready", screen)

    app.navigate("health")
    await settle()
    screen = app.screen
    await _capture("health_ready", screen)
    var aggregate_badge := screen._node("HealthColumn/RadiationBadge") as Panel
    await _hover(aggregate_badge.get_global_rect().get_center())
    var hovered := root.gui_get_hovered_control()
    check(hovered != null
        and (hovered == aggregate_badge or aggregate_badge.is_ancestor_of(hovered))
        and hovered.tooltip_text.contains("Low radiation exposure")
        and hovered.tooltip_text.contains("Dehydrated"),
        "native hover reaches the truthful aggregate effect tooltip")
    await create_timer(0.8).timeout
    await _capture("health_effects_hover", screen)

    owner.teardown(owner.generation())
    await settle()
    await _capture("health_disconnected", screen)
    _finish()


func _capture(state: String, screen: Control) -> void:
    RenderingServer.force_draw(true)
    await process_frame
    var image := root.get_texture().get_image()
    var file_name := "1920x1080_%s.png" % state
    check(image.get_size() == EXACT_SIZE, state + " image is exact 1920x1080")
    check(image.save_png(OUTPUT + "/" + file_name) == OK, "save " + file_name)
    var stash_scroll := screen._node("DesktopStashScroll") as ScrollContainer
    var grid: Control = screen._grid_for_source("loot" if screen._loot_mode else "stash")
    var first_badge := screen._node("HealthColumn/DehydratedBadge") as Panel
    var aggregate_badge := screen._node("HealthColumn/RadiationBadge") as Panel
    var first_label := first_badge.get_node("Text") as Label
    records.append({
        "image": file_name,
        "state": state,
        "dimensions": [image.get_width(), image.get_height()],
        "route": app.current_route,
        "runtime_configured": runtime.is_configured(),
        "inventory_sync": str(runtime.inventory_view(&"raid").sync_state_name()),
        "health_sync": str(runtime.health_view().sync_state_name()),
        "inventory_content": str(screen._surface.get_global_rect()),
        "stash_scroll": str(stash_scroll.get_global_rect()),
        "grid_cell": int(grid.cell_size) if grid != null else 0,
        "grid_parent": str(grid.get_parent().name) if grid != null else "",
        "replacement_panel_present": screen.has_node("LootContainerPanel"),
        "quick_heal_disabled": bool((screen._node("HealthColumn/QuickHeal") as Button).disabled),
        "effects": {
            "count_label": str((screen._node("HealthColumn/BodyWide") as Label).text),
            "first_text": first_label.text,
            "first_tooltip": first_badge.tooltip_text,
            "first_clip": first_label.clip_text,
            "first_overrun": first_label.text_overrun_behavior,
            "first_mouse_filter": first_badge.mouse_filter,
            "aggregate_text": str((aggregate_badge.get_node("Text") as Label).text),
            "aggregate_tooltip": aggregate_badge.tooltip_text,
            "aggregate_mouse_filter": aggregate_badge.mouse_filter,
        },
    })


func _setup_capture_runtime() -> bool:
    owner = RaidInventoryOwner.new()
    owner.name = "LiveCharacterUI86CaptureOwner"
    root.add_child(owner)
    if not owner.configure() or not owner.materialize_loot_fixture():
        return false
    var stash_container := _root_container_id(owner.profile_authority(), owner.profile_inventory_id)
    var stash_insert := owner.profile_authority().insert_item(
        owner.profile_inventory_id, String(Catalog.ITEM_BATTERY), 2,
        _spatial(stash_container, 0, 0), RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 8_611)
    if not bool(stash_insert.get("accepted", false)):
        return false
    admission = SessionCoordinator.new().open_offline(
        ZRaidId.from_parts(PackedStringArray(["capture", "character", "binding"])),
        &"capture_profile", &"player")
    identity = OfflineInventoryIdentity.new()
    if not identity.configure(admission, owner, RaidInventoryOwner.FIXTURE_ACTOR_ID):
        return false
    var world := CaptureWorldPolicy.new()
    world.actor_key = admission.actor_id.canonical_key()
    world.generation = admission.generation
    world.inventory_id = owner.world_crate_inventory_id
    adapter = InventoryIntentAdapter.new()
    if not adapter.configure(owner, admission, identity, world, MAX_TRANSFER_DISTANCE_RAW):
        return false
    bridge = InventoryProjectionBridge.new()
    bridge.name = "LiveCharacterUI86CaptureBridge"
    root.add_child(bridge)
    if not bridge.bind_owner(owner, owner.generation()):
        return false
    runtime = CharacterUIRuntime.new()
    runtime.name = "LiveCharacterUI86CaptureRuntime"
    root.add_child(runtime)
    return runtime.configure(owner, bridge, adapter, admission, _health_view())


func _health_view() -> HealthView:
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
        admission.generation, 1, 100, admission.actor_id,
        HealthView.LifeState.ALIVE, 75, 100, 42, 100, 64, 100,
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


func _finish() -> void:
    var report := {
        "engine": Engine.get_version_info(),
        "display": DisplayServer.get_name(),
        "dimensions": [1920, 1080],
        "checks": checks,
        "failures": failures,
        "records": records,
    }
    var file := FileAccess.open(OUTPUT + "/captures.json", FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "\t") + "\n")
        file.close()
    print("LIVE_CHARACTER_UI_8_6_CAPTURE_RESULT checks=%d failures=%d size=1920x1080" % [
        checks, failures])
    quit(0 if failures == 0 else 1)
