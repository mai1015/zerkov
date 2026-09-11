extends SceneTree
## DEFERRED / HISTORICAL SUITE: compact utility regression.
## Do not invoke or regenerate smaller-window evidence until task 11.8 or a
## later approved display-support proposal explicitly reopens this suite.
## Historical runs were native PNG evidence or headless input/state checks.
var app: Control
var failures := 0
var checks := 0
var capture_dir := "/tmp/zerkov-compact-utility"

func _initialize() -> void:
    push_error("DEFERRED_DISPLAY_SUITE: compact_utility_smoke is historical; reopen only through task 11.8 or an approved display-support proposal")
    quit(2)
    return

func check(value: bool, message: String) -> void:
    checks += 1
    if not value:
        failures += 1
        push_error("COMPACT_UTILITY: " + message)

func settle() -> void:
    for index in range(6):
        await process_frame

func click(button: Button) -> void:
    check(button != null, "button exists")
    if button == null:
        return
    var position := button.get_global_rect().get_center()
    var motion := InputEventMouseMotion.new()
    motion.position = position
    motion.global_position = position
    root.push_input(motion)
    for down in [true, false]:
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_LEFT
        event.position = position
        event.global_position = position
        event.pressed = down
        event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
        root.push_input(event)
    await settle()

func button_named(text: String) -> Button:
    for button in app.screen.find_children("*", "Button", true, false):
        if button.text == text and button.is_visible_in_tree():
            return button
    return null

func wheel(pane: ScrollContainer) -> void:
    var position := pane.get_global_rect().get_center()
    var motion := InputEventMouseMotion.new()
    motion.position = position
    motion.global_position = position
    root.push_input(motion)
    for index in range(5):
        var event := InputEventMouseButton.new()
        event.button_index = MOUSE_BUTTON_WHEEL_DOWN
        event.position = position
        event.global_position = position
        event.pressed = true
        root.push_input(event)
        event = event.duplicate()
        event.pressed = false
        root.push_input(event)
    await settle()

func capture(name: String) -> void:
    if DisplayServer.get_name() != "headless":
        await RenderingServer.frame_post_draw
        root.get_texture().get_image().save_png(capture_dir.path_join(name + ".png"))

func run() -> void:
    DirAccess.make_dir_recursive_absolute(capture_dir)
    root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
    root.content_scale_size = Vector2i.ZERO
    root.size = Vector2i(1280, 720)
    app = load("res://ui/main.tscn").instantiate()
    app.ui_layout_mode = "compact"
    root.add_child(app)
    app.qa_mode = true
    await settle()
    for viewport in [Vector2i(1280, 720), Vector2i(960, 540)]:
        root.size = viewport
        await settle()
        app.state.clear()
        for route in ["settings", "maps", "tasks", "controls", "crosshairs"]:
            app.navigate(route, false)
            await settle()
            check(app.screen.scale == Vector2.ONE, route + " retains native scale")
            check(app.screen.get_viewport_rect().size == Vector2(viewport), route + " uses real pixel viewport")
            await capture(route + "-" + str(viewport.x))
            for pane in app.screen.find_children("*", "ScrollContainer", true, false):
                check(pane.get_global_rect().end.x <= viewport.x + 1, route + " pane fits window width")
                check(pane.get_global_rect().end.y <= viewport.y + 1, route + " pane fits window height")
                if pane.name != "RegionMapPane":
                    check(not pane.get_h_scroll_bar().visible, route + " avoids horizontal menu scrolling")
            if route == "settings":
                for label in app.screen.find_children("*", "Label", true, false):
                    if label.text in ["100%", "90%", "56 px"] and label.is_visible_in_tree():
                        check(label.size.x >= 50, "Setting numeric value retains readable width")
        app.navigate("settings", false)
        await settle()
        var pane: ScrollContainer = app.screen.get_node("SettingsOptions")
        await wheel(pane)
        check(pane.scroll_vertical > 0, "Settings scrolls with mouse wheel")
        var before := pane.scroll_vertical
        app.screen._on_setting_toggle("hud_dynamic_spread")
        await settle()
        check(app.screen.get_node("SettingsOptions").scroll_vertical == before, "Setting change preserves scroll position")
        await click(button_named("PREVIEW"))
        check(app.screen.get_node("SettingsPreview").visible, "Preview tab opens")
        await capture("settings-preview-" + str(viewport.x))
        await click(button_named("CONTROLS"))
        check(app.current_route == "controls", "Settings sidebar navigates to controls")
        pane = app.screen.get_node("BindingsPane")
        await wheel(pane)
        check(pane.scroll_vertical > 0, "Controls scrolls with mouse wheel")
        app.screen._begin_capture("melee", "primary")
        await settle()
        var key := InputEventKey.new()
        key.keycode = KEY_Q
        key.physical_keycode = KEY_Q
        key.pressed = true
        root.push_input(key)
        await settle()
        check(app.screen._binding_value("melee", "primary") == "Q", "Compact controls preserves key capture")
        await click(button_named("CONTROLLER / CONFLICTS"))
        check(app.screen.get_node("ControllerPane").visible, "Controller tab opens")
        await capture("controls-options-" + str(viewport.x))
        app.navigate("maps", false)
        await settle()
        await click(button_named("REGION MAP"))
        check(app.screen.get_node("RegionMapPane").visible, "Bounded region map opens")
        await capture("maps-region-" + str(viewport.x))
        app.navigate("tasks", false)
        await settle()
        pane = app.screen.get_node("TaskDetailsPane")
        await wheel(pane)
        check(pane.scroll_vertical > 0, "Task detail scrolls with wheel")
        await capture("tasks-scroll-" + str(viewport.x))
        await click(button_named("AVAILABLE"))
        check(app.state.get("utility_task_tab", "") == "available", "Task status tab updates list")
        check(app.screen.get_node("TaskDetailsPane").visible, "Task detail survives list rebuild")
    print("COMPACT_UTILITY_RESULT checks=%d failures=%d" % [checks, failures])
    quit(1 if failures else 0)
