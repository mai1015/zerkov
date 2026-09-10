extends SceneTree
## Native event and rendered-node assertions; run with --headless --script res://tests/raid_smoke.gd.
var app: Control
var checks = 0
var failures = 0

func _initialize() -> void:
    call_deferred("run")

func check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("RAID_TEST " + message)

func settle() -> void:
    await process_frame
    await process_frame

func press_key(code: Key) -> void:
    for pressed in [true, false]:
        var event = InputEventKey.new()
        event.keycode = code
        event.physical_keycode = code
        event.pressed = pressed
        root.push_input(event)
    await settle()

func texts() -> Array[String]:
    var values: Array[String] = []
    for node in app.screen.find_children("*", "Label", true, false):
        values.append(node.text)
    return values

func run() -> void:
    root.size = Vector2i(1920, 1080)
    app = load("res://ui/main.tscn").instantiate()
    root.add_child(app)
    app.qa_mode = true
    await settle()
    app.navigate("hud", false)
    await settle()
    check(texts().has("32:14"), "Solo deployment route renders complete raid timer")
    check(not texts().has("SQUAD · 3 / 4"), "Solo HUD omits squad")
    check(texts().has("24"), "Exact ammo renders initial 24 rounds")
    await press_key(KEY_H)
    check(app.state.raid_low_health and texts().has("BLEEDING"), "H renders low health effects")
    await press_key(KEY_Y)
    check(not app.state.raid_low_health and not texts().has("BLEEDING"), "Y clears bleeding preview")
    await press_key(KEY_R)
    check(app.screen._reload_active and app.screen._ring_nodes.size() == 1, "R starts overhead ring")
    check(texts().has("--"), "Reload dims ammo counter")
    await create_timer(2.6).timeout
    check(not app.screen._reload_active and app.screen._ring_nodes.is_empty(), "Reload completes and removes ring")
    check(app.state.raid_ammo == 30 and texts().has("30"), "Reload refills mock magazine")
    var shot = InputEventMouseButton.new()
    shot.button_index = MOUSE_BUTTON_LEFT
    shot.position = Vector2(960, 540)
    shot.pressed = true
    root.push_input(shot)
    shot = shot.duplicate()
    shot.pressed = false
    root.push_input(shot)
    await settle()
    check(app.state.raid_ammo == 29 and app.screen._crosshair.hit, "Click animates mock shot and hit marker")
    app.navigate("settings", false)
    await settle()
    for pair in [["hud_scale", 120.0], ["hud_opacity", 60.0], ["hud_safe_zone", 80.0], ["hud_crosshair_shape", "RING"], ["hud_crosshair_color", "BLUE"], ["hud_health_readout", "BAR + NUMBER"], ["hud_ammo_counter", "ROUGH"], ["hud_status_icons", "ICON"], ["hud_idle_fade", "3 S"], ["hud_squad_tags", false], ["hud_loot_feed", "OFF"]]:
        app.screen._set_setting(pair[0], pair[1])
    app.state.raid_low_health = true
    app.navigate("hud_coop", false)
    await settle()
    check(app.screen._crosshair.shape == "RING" and app.screen._crosshair.tint == Color("#4c8dff"), "Saved crosshair shape/color reach raid renderer")
    check(texts().has("124 / 435"), "BAR + NUMBER renders HP number")
    check(not texts().has("30") and not texts().has("/ 90"), "Rough ammo replaces exact count")
    check(not texts().has("BLEEDING"), "ICON mode omits effect label")
    check(not texts().has("SQUAD · 3 / 4") and not texts().has("Car battery ×1"), "Squad/feed switches hide groups")
    var vitals = app.screen._fade_groups[0]
    check(vitals.scale.is_equal_approx(Vector2(1.2, 1.2)), "HUD scale transforms vitals")
    check(vitals.position == Vector2(24, -24), "Safe zone insets vitals from edges")
    check(is_equal_approx(vitals.modulate.a, 0.6), "HUD opacity applied")
    await press_key(KEY_Y)
    app.screen._idle_time = 3.5
    await create_timer(0.5).timeout
    check(app.screen._fade_groups[0].modulate.a < 0.3, "Idle fade dims healthy vitals")
    await press_key(KEY_H)
    await create_timer(0.3).timeout
    check(app.screen._fade_groups[0].modulate.a > 0.5, "Damage restores faded HUD")
    await press_key(KEY_X)
    check(app.current_route == "summary_squad", "X extracts co-op to squad summary")
    check(app.screen._squad_countdown.text.contains("2 / 3"), "Squad summary shows current readiness")
    await press_key(KEY_ENTER)
    check(app.screen._squad_countdown.text.contains("3 / 3"), "Enter visibly marks everyone ready")
    await create_timer(1.4).timeout
    check(app.current_route == "bunker", "All ready returns squad to bunker")
    app.navigate("summary_squad", false)
    await settle()
    app.screen._squad_started -= 43.0
    await settle()
    check(app.current_route == "bunker", "Countdown expiry returns squad without readiness")
    app.navigate("hud", false)
    await settle()
    await press_key(KEY_X)
    check(app.current_route == "summary_solo", "X extracts solo to solo summary")
    app.screen._on_reinsure()
    await settle()
    check(is_instance_valid(app.modal), "Re-insure opens reviewable confirmation")
    for button in app.modal.find_children("*", "Button", true, false):
        if button.text == "CONFIRM": button.pressed.emit()
    await settle()
    check(app.state.get("raid_loadout_insured", false), "Confirm records insurance sample state")
    await press_key(KEY_ENTER)
    check(app.current_route == "bunker", "Enter returns solo summary to bunker")
    print("RAID_TEST_COMPLETE checks=", checks, " failures=", failures)
    quit(0 if failures == 0 else 1)
