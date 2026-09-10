extends "res://ui/core/screen.gd"
## Character actions. The shared scene controller owns retained view binding.

const InventoryFixture = preload("res://ui/dev/fixtures/inventory_fixture.gd")
const Adaptive = preload("res://ui/core/adaptive.gd")

@export var forced_tab: String = ""

var _surface: Control
var _tooltip: Panel
var _tip_item: Dictionary = {}
var _grids: Array = []
var _local_state: Dictionary = {}
var _compatibility_key: String = "7.62x39"
var _current_filter: String = "all"
var _search_query: String = ""
var _loot_mode: bool = false
var _selected_container: String = "backpack"
var _tip_source: String = "stash"
var _compact_section: String = "loadout"
var _compact_scroll: Dictionary = {}


func _tab_name() -> String:
    if forced_tab in ["gear", "health", "stats"]:
        return forced_tab
    var route: String = str(app.get("current_route")) if app != null else "inventory"
    if route == "health":
        return "health"
    if route == "stats":
        return "stats"
    var state: Dictionary = _state()
    var remembered: String = str(state.get("inventory_tab", "gear"))
    return remembered if remembered in ["gear", "health", "stats"] else "gear"


func _state() -> Dictionary:
    if app != null:
        var value = app.get("state")
        if value is Dictionary:
            return value as Dictionary
    return _local_state


func _ensure_inventory_state() -> void:
    var state: Dictionary = _state()
    if not state.has("inventory_data"):
        state["inventory_data"] = InventoryFixture.create()
    if not state.has("inventory_tab"):
        state["inventory_tab"] = "gear"


func _inventory_data() -> Dictionary:
    var state: Dictionary = _state()
    var value = state.get("inventory_data", {})
    if value is Dictionary:
        return value as Dictionary
    var fresh: Dictionary = InventoryFixture.create()
    state["inventory_data"] = fresh
    return fresh


func _items_for(key: String) -> Array:
    var source: Array = _inventory_data().get(key, [])
    var output: Array = []
    for value in source:
        if value is Dictionary:
            output.append((value as Dictionary).duplicate(true))
    return output


func _write_items(key: String, value: Array) -> void:
    _inventory_data()[key] = value


func _filtered_items(items: Array) -> Array:
    var output: Array = []
    for value in items:
        if not value is Dictionary:
            continue
        var item: Dictionary = value as Dictionary
        if _current_filter != "all" and str(item.get("category", "all")) != _current_filter:
            continue
        if not _search_query.is_empty() and not str(item.get("name", "")).to_lower().contains(_search_query.to_lower()):
            continue
        output.append(item)
    return output


func _on_search_changed(_text: String) -> void:
    _search_query = _text
    _state()["inventory_search"] = _text
    # Keep the native input and its caret alive while filtering.
    var source_key: String = "loot" if _loot_mode else "stash"
    var grid: Control = _grid_for_source(source_key)
    if grid != null:
        grid.set_items(_filtered_items(_items_for(source_key)))


func _refresh_body() -> void:
    _bind_content()

func _bind_content() -> void:
    pass # Implemented by the retained scene controller.

func _select_tab(tab: String) -> void:
    _state()["inventory_tab"] = tab
    var route: String = "inventory" if tab == "gear" else tab
    if app != null and app.has_method("navigate"):
        app.navigate(route)
    else:
        _refresh_body()


func _set_filter(filter_name: String) -> void:
    _current_filter = filter_name
    _state()["inventory_filter"] = filter_name
    _refresh_body()
    _notify("Filter: " + filter_name.to_upper())


func _set_loot_mode(show_loot: bool) -> void:
    _loot_mode = show_loot
    _state()["inventory_loot_mode"] = show_loot
    _current_filter = "all"
    _search_query = ""
    _state()["inventory_filter"] = "all"
    _state()["inventory_search"] = ""
    _refresh_body()
    _notify("Showing " + ("loot container" if show_loot else "stash"))


func _on_grid_hovered(item: Dictionary, hovering: bool, _grid: Control) -> void:
    var kind: String = str(item.get("kind", ""))
    if hovering and kind == "weapon":
        var key: String = str(item.get("compatibility", ""))
        if key.is_empty():
            key = "7.62x39"
        _set_compatibility(key)
    elif not hovering and kind == "weapon":
        _clear_compatibility()


func _on_grid_selected(item: Dictionary, source_key: String) -> void:
    _show_item_tip(item, source_key)


func _on_grid_context(item: Dictionary, source_key: String) -> void:
    _show_item_tip(item, source_key)


func _on_quick_move(item: Dictionary, source_key: String) -> void:
    _move_item(item, source_key)


func _on_item_dropped(item: Dictionary, source_key: String, destination: Vector2i, _destination_grid: Control) -> void:
    var target_key: String = str(_destination_grid.get("source_id"))
    if target_key.is_empty() or source_key == target_key:
        if source_key == target_key:
            _reposition_item(item, source_key, destination)
        return
    _move_item(item, source_key, target_key, destination)


func _on_drop_rejected(item: Dictionary, _source_key: String, _destination: Vector2i) -> void:
    _notify("Invalid drop · " + str(item.get("name", "item")) + " does not fit here")


func _reposition_item(item: Dictionary, source_key: String, destination: Vector2i) -> void:
    var values: Array = _items_for(source_key)
    for value in values:
        if str(value.get("id", "")) == str(item.get("id", "")):
            value["x"] = destination.x
            value["y"] = destination.y
    _write_items(source_key, values)
    _refresh_body()
    _notify("Moved " + str(item.get("name", "item")))


func _move_item(item: Dictionary, source_key: String, target_key: String = "", destination: Vector2i = Vector2i(-1, -1)) -> void:
    var source: String = source_key
    var target: String = target_key
    if target.is_empty():
        if source == "stash" or source == "loot":
            target = _selected_container
        else:
            target = "stash"
    if target == source:
        return
    var target_grid: Control = _grid_for_source(target)
    var item_copy: Dictionary = item.duplicate(true)
    var cell: Vector2i = destination
    if cell.x < 0 or target_grid == null or not target_grid.can_place(item_copy, cell, str(item_copy.get("id", ""))):
        if target_grid == null:
            _notify("No destination container")
            return
        cell = target_grid.find_first_fit(item_copy)
    if cell.x < 0:
        _notify("No free slots in " + target.to_upper())
        return
    var source_values: Array = _items_for(source)
    var moved: Dictionary = {}
    var remaining: Array = []
    for value in source_values:
        if str(value.get("id", "")) == str(item.get("id", "")):
            moved = value
        else:
            remaining.append(value)
    if moved.is_empty():
        return
    moved["x"] = cell.x
    moved["y"] = cell.y
    var target_values: Array = _items_for(target)
    target_values.append(moved)
    _write_items(source, remaining)
    _write_items(target, target_values)
    _refresh_body()
    _notify(str(moved.get("name", "Item")) + " → " + target.to_upper())


func _grid_for_source(source_key: String) -> Control:
    for candidate in _grids:
        if is_instance_valid(candidate) and str(candidate.get("source_id")) == source_key:
            return candidate
    return null


func _show_item_tip(item: Dictionary, source_key: String) -> void:
    if is_instance_valid(_tooltip):
        _tooltip.queue_free()
    _tip_item = item.duplicate(true)
    _tip_source = source_key
    _tooltip = Panel.new()
    _tooltip.name = "ItemTooltip"
    _tooltip.add_theme_stylebox_override("panel", U.style(Color(0.027, 0.035, 0.035, 0.98), U.GREEN if str(item.get("compatibility", "")) == _compatibility_key else U.LINE))
    _tooltip.position = Vector2(1454, 454) if source_key in ["stash", "loot"] else Vector2(748, 700)
    _tooltip.size = Vector2(246, 132)
    var view: Vector2 = get_viewport_rect().size
    if view.x < 1920 or view.y < 1080:
        var pointer: Vector2 = get_local_mouse_position() + Vector2(16, 16)
        _tooltip.position = Vector2(clampf(pointer.x, 16, view.x - 262), clampf(pointer.y, 64, view.y - 180))
    _tooltip.z_index = 20
    _surface.add_child(_tooltip)
    txt(_tooltip, str(item.get("name", "ITEM")), Rect2(12, 8, 150, 20), 13, U.TEXT)
    var value_text: String = "$ 480" if str(item.get("kind", "")) == "ammo" else ("$ 3,000" if str(item.get("kind", "")) == "weapon" else "$ 120")
    txt(_tooltip, value_text, Rect2(160, 8, 74, 20), 11, U.ACCENT, true).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    var compatibility: String = "AKM compatible · fits AK 30-rd mag" if not str(item.get("compatibility", "")).is_empty() else "Container item · local mock state"
    txt(_tooltip, compatibility, Rect2(12, 37, 222, 34), 10, U.GREEN if not str(item.get("compatibility", "")).is_empty() else U.MUTED, true)
    rule(_tooltip, 12, 80, 222)
    var move_button: Button = btn(_tooltip, "F · MOVE", Rect2(12, 90, 102, 28), Callable(self, "_tip_move"), false)
    move_button.add_theme_font_size_override("font_size", 10)
    var close_button: Button = btn(_tooltip, "RMB · CLOSE", Rect2(124, 90, 110, 28), Callable(self, "_close_tip"), false)
    close_button.add_theme_font_size_override("font_size", 10)


func _tip_move() -> void:
    if not _tip_item.is_empty():
        _move_item(_tip_item, _tip_source)
    _close_tip()


func _close_tip() -> void:
    if is_instance_valid(_tooltip):
        _tooltip.queue_free()
    _tooltip = null
    _tip_item = {}


func _set_compatibility(key: String) -> void:
    _compatibility_key = key
    for grid in _grids:
        if is_instance_valid(grid):
            grid.set_compatibility(key)


func _clear_compatibility() -> void:
    # Keep the approved hover state on screen when the weapon itself is not
    # under the pointer; a second hover can still replace this key.
    _set_compatibility("7.62x39")


func _swap_container(container_key: String) -> void:
    if container_key == "rig":
        var rig_size: Array = _inventory_data().get("rig_size", [6, 2])
        _inventory_data()["rig_size"] = [5, 3] if int(rig_size[0]) == 6 else [6, 2]
        _notify("Rig swapped · capacity resized")
    elif container_key == "backpack":
        var pack_size: Array = _inventory_data().get("backpack_size", [6, 5])
        _inventory_data()["backpack_size"] = [7, 6] if int(pack_size[0]) == 6 else [6, 5]
        _notify("Backpack swapped · capacity resized")
    _refresh_body()


func _container_selected(container_key: String) -> void:
    _selected_container = container_key
    _notify(container_key.to_upper() + " selected as quick-move destination")


func _quick_slot_used(index: int) -> void:
    if index == 0:
        _quick_heal()
    else:
        _notify("Quick slot " + str(index + 5) + " is empty")


func _quick_heal() -> void:
    var state: Dictionary = _state()
    state["last_quick_heal"] = "torso"
    state["quick_healed"] = true
    state["med_count"] = max(0, int(state.get("med_count", 2)) - 1)
    if _tab_name() == "health" or get_viewport_rect().size.x < 1920 or get_viewport_rect().size.y < 1080:
        _refresh_body()
    _notify("QUICK HEAL · Sanitizer used on torso")


func _gear_selected(title: String, _detail: String) -> void:
    if title == "ON SLING":
        _set_compatibility("7.62x39")
    else:
        _notify(title + " selected")


func _bank_loot() -> void:
    var loot_values: Array = _items_for("loot")
    var stash_values: Array = _items_for("stash")
    for item in loot_values:
        var cell: Vector2i = _first_fit_in_items(stash_values, item, 7, 10)
        if cell.x < 0:
            break
        item["x"] = cell.x
        item["y"] = cell.y
        stash_values.append(item)
    _write_items("stash", stash_values)
    _write_items("loot", [])
    _loot_mode = false
    _refresh_body()
    _notify("Loot moved to stash · loadout kept")


func _first_fit_in_items(existing_items: Array, item: Dictionary, columns: int, rows: int) -> Vector2i:
    var item_w: int = max(1, int(item.get("w", 1)))
    var item_h: int = max(1, int(item.get("h", 1)))
    for y in range(rows):
        for x in range(columns):
            if x + item_w > columns or y + item_h > rows:
                continue
            var occupied: bool = false
            for other_value in existing_items:
                if not other_value is Dictionary:
                    continue
                var other: Dictionary = other_value as Dictionary
                if _rect_overlap(x, y, item_w, item_h, int(other.get("x", 0)), int(other.get("y", 0)), max(1, int(other.get("w", 1))), max(1, int(other.get("h", 1)))):
                    occupied = true
                    break
            if not occupied:
                return Vector2i(x, y)
    return Vector2i(-1, -1)
func _rect_overlap(ax: int, ay: int, aw: int, ah: int, bx: int, by: int, bw: int, bh: int) -> bool:
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


func _reinsure() -> void:
    _notify("Loadout re-insured for $ 340")


func _sell_junk() -> void:
    _notify("Junk preview · +$ 620 (mock only)")


func _sort_stash() -> void:
    _current_filter = "all"
    _search_query = ""
    _notify("Stash sorted by value ↓")
    _refresh_body()


func _organize_stash() -> void:
    var values: Array = _items_for("stash")
    var organized: Array = []
    for item in values:
        var cell: Vector2i = _first_fit_in_items(organized, item, 7, 10)
        if cell.x < 0:
            # Keep an item visible and report capacity through the same toast
            # path rather than letting an organize click place it out of bounds.
            cell = Vector2i(0, 9)
        item["x"] = cell.x
        item["y"] = cell.y
        organized.append(item)
    _write_items("stash", organized)
    _notify("Stash organized")
    _refresh_body()


func _notify(message: String) -> void:
    if app != null and app.has_method("toast"):
        app.toast(message)


func _unhandled_input(event: InputEvent) -> void:
    if not accepts_input(): return
    if event is InputEventKey and event.pressed and not event.echo:
        var key_event: InputEventKey = event as InputEventKey
        if key_event.keycode == KEY_Y:
            _quick_heal()
            get_viewport().set_input_as_handled()
        elif key_event.keycode == KEY_F and not key_event.ctrl_pressed and not _tip_item.is_empty():
            _tip_move()
            get_viewport().set_input_as_handled()
