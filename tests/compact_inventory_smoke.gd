extends SceneTree
## DEFERRED / HISTORICAL SUITE: native compact inventory regression.
## Do not invoke or regenerate smaller-window evidence until task 11.8 or a
## later approved display-support proposal explicitly reopens this suite.

var failures: int = 0
var checks: int = 0
var app: Control

func _initialize() -> void:
    push_error("DEFERRED_DISPLAY_SUITE: compact_inventory_smoke is historical; reopen only through task 11.8 or an approved display-support proposal")
    quit(2)

func check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("COMPACT_INVENTORY: " + message)

func settle() -> void:
    for frame in range(5):
        await process_frame

func snapshot(label: String) -> void:
    if DisplayServer.get_name() == "headless":
        return
    if is_instance_valid(app.toast_label):
        app.toast_label.hide()
    await RenderingServer.frame_post_draw
    var image: Image = root.get_texture().get_image()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/qa/compact_inventory"))
    image.save_png("res://docs/qa/compact_inventory/" + label + ".png")

func wheel_at(point: Vector2) -> void:
    var motion: InputEventMouseMotion = InputEventMouseMotion.new()
    motion.position = point
    motion.global_position = point
    root.push_input(motion)
    var wheel: InputEventMouseButton = InputEventMouseButton.new()
    wheel.position = point
    wheel.global_position = point
    wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
    wheel.factor = 3.0
    wheel.pressed = true
    root.push_input(wheel)
    await settle()

func run() -> void:
    root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
    root.content_scale_size = Vector2i.ZERO
    root.size = Vector2i(1280, 720)
    app = load("res://ui/main.tscn").instantiate()
    app.ui_layout_mode = "compact"
    root.add_child(app)
    await create_timer(0.2).timeout
    await settle()
    for view in [Vector2i(1280, 720), Vector2i(960, 540)]:
        root.size = view
        await create_timer(0.2).timeout
        await settle()
        app.state["inventory_compact_section"] = "loadout"
        app.state["inventory_tab"] = "gear"
        app.navigate("inventory", false)
        await settle()
        var screen: Control = app.screen
        check(screen._grids.size() == 4, "all transfer containers exist at " + str(view))
        for grid in screen._grids:
            check(grid.get_cell_size() == 74, "74px item cells at " + str(view))
        var loadout: ScrollContainer = screen.find_child("LoadoutScroll", true, false)
        check(loadout != null, "native loadout pane exists")
        check(loadout.get_v_scroll_bar().max_value > loadout.get_v_scroll_bar().page, "loadout overflows vertically")
        await snapshot("inventory_" + str(view.x))
        await wheel_at(loadout.global_position + Vector2(100, 104))
        check(loadout.scroll_vertical > 0, "wheel over an item scrolls native loadout pane")
        if view.x < 1180:
            screen._select_compact_section("stash")
            await settle()
        var stash: ScrollContainer = screen.find_child("StashScroll", true, false)
        check(stash.is_visible_in_tree(), "stash is accessible")
        await wheel_at(stash.global_position + Vector2(36, 36))
        check(stash.scroll_vertical > 0, "wheel over item scrolls native stash pane")
        await snapshot("stash_" + str(view.x))
        var search: LineEdit = screen.find_child("StashSearch", true, false)
        search.grab_focus()
        screen._on_search_changed("Tin")
        check(is_instance_valid(search) and search.has_focus(), "search retains native input and caret")
        screen._on_search_changed("")
        var first_item: Dictionary = screen._items_for("stash")[0]
        screen._show_item_tip(first_item, "stash")
        var tooltip_rect: Rect2 = screen._tooltip.get_global_rect()
        check(Rect2(Vector2.ZERO, Vector2(view)).encloses(tooltip_rect), "item options stay inside viewport")
        screen._close_tip()
        var count_before: int = screen._items_for("stash").size()
        screen._grid_for_source("stash")._slot_quick_move(first_item)
        await settle()
        check(screen._items_for("stash").size() == count_before - 1, "deferred quick transfer survives compact rebuild")
        check(screen.find_child("StashScroll", true, false) != null, "compact panes return after transfer")
        for section in ["health", "stats"]:
            screen._select_compact_section(section)
            await settle()
            var character: ScrollContainer = screen.find_child("CharacterScroll", true, false)
            check(character != null and character.is_visible_in_tree(), section + " accessible by section tab")
            await snapshot(section + "_" + str(view.x))
            await wheel_at(character.global_position + Vector2(240, 100))
            check(character.scroll_vertical > 0, section + " supports native wheel scrolling")
            if section == "health":
                var heal: Button = screen.find_child("PinnedQuickHeal", true, false)
                check(heal != null and Rect2(Vector2.ZERO, Vector2(view)).encloses(heal.get_global_rect()), "quick heal remains pinned after scrolling")
                var meds_before: int = int(app.state.get("med_count", 2))
                heal.pressed.emit()
                await settle()
                check(int(app.state.get("med_count", 0)) == max(0, meds_before - 1), "pinned quick heal performs its action")
                check(screen.find_child("CharacterScroll", true, false) != null, "quick heal restores compact health view")
    print("COMPACT_INVENTORY_COMPLETE checks=", checks, " failures=", failures)
    app.queue_free()
    await settle()
    quit(0 if failures == 0 else 1)
