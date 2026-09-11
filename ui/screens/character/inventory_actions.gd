extends "res://ui/core/screen.gd"
## Character actions. The shared scene controller owns retained view binding.

const Adaptive = preload("res://ui/core/adaptive.gd")
const InventoryPresentationController = preload("res://game/inventory/presentation/inventory_presentation_controller.gd")

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
var _loot_container_open: bool = false
var _selected_container: String = "backpack"
var _tip_source: String = "stash"
var _compact_section: String = "loadout"
var _compact_scroll: Dictionary = {}
var _inventory_controller: InventoryPresentationController
var _live_inventory_binding := false
var _character_runtime: CharacterUIRuntime
var _shared_inventory_controller := false
var _live_health_binding := false
var _health_view: HealthView
var _pending_runtime_interaction: Dictionary = {}
var _activation_runtime_interaction: Dictionary = {}
var _selected_live_item: Dictionary = {}
var _selected_live_source: String = ""
var _live_inventory_tab: String = "gear"
var _split_dialog: Control
var _split_spin: LineEdit
var _split_item: Dictionary = {}
var _split_source: String = ""
var _split_target: String = ""
var _split_target_descriptor: Dictionary = {}
var _split_destination := Vector2i.ZERO
var _binding_token_serial: int = 0
var _active_binding_token: int = 0
var _interaction_restore_serial: int = 0
var _tearing_down: bool = false
var _local_presentation_refresh_depth: int = 0
var _drag_refresh_pending: bool = false
var _drag_refresh_serial: int = 0


func _tab_name() -> String:
    if forced_tab in ["gear", "health", "stats"]:
        return forced_tab
    var route: String = str(app.get("current_route")) if app != null else "inventory"
    if route == "health":
        return "health"
    if route == "stats":
        return "stats"
    if _live_inventory_binding:
        return _live_inventory_tab
    var state: Dictionary = _state()
    var remembered: String = str(state.get("inventory_tab", "gear"))
    return remembered if remembered in ["gear", "health", "stats"] else "gear"


func _state() -> Dictionary:
    if app != null and app.has_fixture_provider():
        return app.fixture_state()
    return _local_state


func _ensure_inventory_state() -> void:
    if _live_inventory_binding:
        return
    if app != null:
        app.prepare_fixture_route()


func _inventory_data() -> Dictionary:
    if _live_inventory_binding:
        return {}
    var state: Dictionary = _state()
    var value = state.get("inventory_data", {})
    if value is Dictionary:
        return value as Dictionary
    return {}


func _items_for(key: String) -> Array:
    if _character_runtime != null and is_instance_valid(_character_runtime):
        return _character_runtime.items_for(StringName(key))
    if _live_inventory_binding and _inventory_controller != null:
        return _inventory_controller.items_for(StringName(key))
    var source: Array = _inventory_data().get(key, [])
    var output: Array = []
    for value in source:
        if value is Dictionary:
            output.append((value as Dictionary).duplicate(true))
    return output


func _write_items(key: String, value: Array) -> void:
    if _live_inventory_binding:
        return
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
    if not _live_inventory_binding:
        _state()["inventory_search"] = _text
    # Keep the native input and its caret alive while filtering.
    var source_key: String = "loot" if _loot_mode else "stash"
    var grid: Control = _grid_for_source(source_key)
    if grid != null:
        var all_items := _items_for(source_key)
        grid.set_items(_filtered_items(all_items), all_items)


func _refresh_body() -> void:
    if _tearing_down or not is_inside_tree():
        return
    # Keep the native source slot and drag preview alive until Godot completes
    # the gesture. A newer immutable projection may make the payload stale, but
    # the binding token/controller validation will then reject it without ever
    # rebuilding the grid out from under the pointer.
    if get_viewport().gui_is_dragging():
        if not _drag_refresh_pending:
            _drag_refresh_pending = true
            _drag_refresh_serial += 1
            _refresh_after_drag.call_deferred(_drag_refresh_serial)
        return
    _interaction_restore_serial += 1
    var restore_serial := _interaction_restore_serial
    var interaction := _capture_inventory_interaction()
    _bind_content()
    _restore_inventory_interaction(interaction)
    # Compact reflow and ScrollContainer minimum sizes settle on the next
    # frame. A deferred second pass keeps offsets/caret/focus stable after
    # that native layout pass as well.
    call_deferred("_restore_inventory_interaction_deferred", interaction, restore_serial)


func _refresh_after_drag(serial: int) -> void:
    while not _tearing_down and serial == _drag_refresh_serial \
            and is_inside_tree() and get_viewport().gui_is_dragging():
        await get_tree().process_frame
    if _tearing_down or serial != _drag_refresh_serial or not is_inside_tree():
        return
    _drag_refresh_pending = false
    _refresh_body()


func _restore_inventory_interaction_deferred(state: Dictionary, restore_serial: int) -> void:
    if _tearing_down or restore_serial != _interaction_restore_serial or not is_inside_tree():
        return
    var deferred_state := state.duplicate(true)
    # A user can move focus (most importantly into search) between the immediate
    # restore and this layout-settling pass. Never let stale deferred state steal
    # that newer focus and reinterpret the next key as an inventory shortcut.
    var current_focus := get_viewport().gui_get_focus_owner()
    if is_instance_valid(current_focus) and current_focus.is_visible_in_tree() \
            and current_focus != state.get("focus", null):
        deferred_state.focus = current_focus
        deferred_state.caret = (current_focus as LineEdit).caret_column \
            if current_focus is LineEdit else -1
        deferred_state.focus_source = ""
        deferred_state.focus_item_id = 0
        var focused_grid := current_focus.get("owner_grid") as Control
        if focused_grid != null:
            deferred_state.focus_source = str(focused_grid.get("source_id"))
            var focused_item: Dictionary = current_focus.get("item") as Dictionary
            deferred_state.focus_item_id = int(focused_item.get(
                "item_id", focused_item.get("id", 0)))
            deferred_state.focus_identity = {
                "item_id": deferred_state.focus_item_id,
                "scope": focused_item.get("scope", &""),
                "owner_generation": int(focused_item.get("owner_generation", 0)),
                "item_definition_identifier": str(focused_item.get("item_definition_identifier", "")),
            }
    _restore_inventory_interaction(deferred_state)

func _bind_content() -> void:
    pass # Implemented by the retained scene controller.


func _capture_inventory_interaction() -> Dictionary:
    var state := {
        "scroll": {},
        "focus": null,
        "caret": -1,
        "focus_source": "",
        "focus_item_id": 0,
        "focus_identity": {},
        "focus_path": "",
        "tooltip": is_instance_valid(_tooltip),
        "tooltip_item": _tip_item.duplicate(true),
        "tooltip_source": _tip_source,
        "tooltip_position": _tooltip.position if is_instance_valid(_tooltip) else Vector2.ZERO,
    }
    if _surface == null:
        return state
    for pane in _surface.find_children("*", "ScrollContainer", true, false):
        state.scroll[str(pane.name)] = Vector2i(pane.scroll_horizontal, pane.scroll_vertical)
    var focus := get_viewport().gui_get_focus_owner()
    if focus != null and is_instance_valid(focus) and is_ancestor_of(focus):
        state.focus = focus
        if _surface != null and _surface.is_ancestor_of(focus):
            state.focus_path = str(_surface.get_path_to(focus))
        if focus is LineEdit:
            state.caret = (focus as LineEdit).caret_column
        var focused_grid := focus.get("owner_grid") as Control
        if focused_grid != null:
            state.focus_source = str(focused_grid.get("source_id"))
            var focused_item: Dictionary = focus.get("item") as Dictionary
            state.focus_item_id = int(focused_item.get("item_id", focused_item.get("id", 0)))
            state.focus_identity = {
                "item_id": state.focus_item_id,
                "scope": focused_item.get("scope", &""),
                "owner_generation": int(focused_item.get("owner_generation", 0)),
                "item_definition_identifier": str(focused_item.get("item_definition_identifier", "")),
            }
    return state


func _restore_inventory_interaction(state: Dictionary) -> void:
    if _surface == null or not is_inside_tree():
        return
    var scroll: Dictionary = state.get("scroll", {}) as Dictionary
    for pane in _surface.find_children("*", "ScrollContainer", true, false):
        var value: Variant = scroll.get(str(pane.name), null)
        if value is Vector2i:
            var point: Vector2i = value
            var horizontal: HScrollBar = pane.get_h_scroll_bar()
            var vertical: VScrollBar = pane.get_v_scroll_bar()
            var max_x := maxi(0, ceili(horizontal.max_value - horizontal.page))
            var max_y := maxi(0, ceili(vertical.max_value - vertical.page))
            pane.scroll_horizontal = clampi(point.x, 0, max_x)
            pane.scroll_vertical = clampi(point.y, 0, max_y)

    var focus: Variant = state.get("focus", null)
    if not is_instance_valid(focus) or not focus.is_visible_in_tree():
        var focus_source := str(state.get("focus_source", ""))
        var focus_item_id := int(state.get("focus_item_id", 0))
        if not focus_source.is_empty() and focus_item_id > 0:
            var focus_grid := _grid_for_source(focus_source)
            focus = _slot_for_item(focus_grid, focus_item_id) if focus_grid != null else null
        if not is_instance_valid(focus) and _live_inventory_binding:
            focus = _slot_for_live_identity(state.get("focus_identity", {}) as Dictionary)
        if not is_instance_valid(focus):
            var focus_path := str(state.get("focus_path", ""))
            if not focus_path.is_empty():
                focus = _surface.get_node_or_null(focus_path)
    if is_instance_valid(focus) and focus.is_visible_in_tree() and focus.focus_mode != Control.FOCUS_NONE:
        focus.grab_focus()
        if focus is LineEdit and int(state.get("caret", -1)) >= 0:
            (focus as LineEdit).caret_column = int(state.get("caret", -1))

    if _live_inventory_binding and not _selected_live_item.is_empty():
        var current_selected := _current_item_for_source(_selected_live_source, _selected_live_item)
        if current_selected.is_empty():
            var relocated := _find_live_item_across_grids(_selected_live_item)
            if relocated.is_empty():
                _selected_live_item = {}
                _selected_live_source = ""
            else:
                _selected_live_source = str(relocated.get("source", ""))
                _selected_live_item = (relocated.get("item", {}) as Dictionary).duplicate(true)
        else:
            _selected_live_item = current_selected
    # Retained grids keep their own local selected_id for fixture rendering. A
    # live selection, however, is singular across the screen and can move between
    # inventories after an accepted loot/quick-transfer. Reconcile every grid so
    # stale source rims are cleared and the preserved identity becomes visible in
    # exactly its confirmed destination.
    if _live_inventory_binding:
        var selected_item_id := str(_selected_live_item.get("item_id", 0)) \
            if not _selected_live_item.is_empty() else ""
        for grid in _grids:
            if not is_instance_valid(grid):
                continue
            var desired := selected_item_id \
                if str(grid.get("source_id")) == _selected_live_source else ""
            if grid.has_method("set_selected_item_id"):
                grid.set_selected_item_id(desired)
            else:
                grid.selected_id = desired

    if bool(state.get("tooltip", false)):
        var tip_item: Dictionary = state.get("tooltip_item", {}) as Dictionary
        var tip_source := String(state.get("tooltip_source", ""))
        var current_tip := _current_item_for_source(tip_source, tip_item)
        if current_tip.is_empty():
            _close_tip()
        else:
            if not _tip_matches(current_tip, tip_source):
                _show_item_tip(current_tip, tip_source)
            if is_instance_valid(_tooltip):
                _tooltip.position = state.get("tooltip_position", _tooltip.position)


func _tip_matches(item: Dictionary, source_key: String) -> bool:
    if not is_instance_valid(_tooltip) or _tip_source != source_key:
        return false
    for key in ["item_id", "quantity", "x", "y", "rotated", "item_definition_identifier"]:
        if _tip_item.get(key, null) != item.get(key, null):
            return false
    return true


func _current_item_for_source(source_key: String, stale_item: Dictionary) -> Dictionary:
    var item_id := int(stale_item.get("item_id", stale_item.get("id", 0)))
    if item_id <= 0:
        return {}
    for value in _items_for(source_key):
        if value is Dictionary and int((value as Dictionary).get("item_id", (value as Dictionary).get("id", 0))) == item_id:
            return (value as Dictionary).duplicate(true)
    return {}


func _slot_for_item(grid: Control, item_id: int) -> Control:
    if grid == null or item_id <= 0:
        return null
    for slot in grid.get("_slots"):
        if is_instance_valid(slot) and int(slot.item.get("item_id", slot.item.get("id", 0))) == item_id:
            return slot
    return null


func _slot_for_live_identity(identity: Dictionary) -> Control:
    var match := _find_live_item_across_grids(identity)
    if match.is_empty():
        return null
    var grid := _grid_for_source(str(match.get("source", "")))
    return _slot_for_item(grid, int(identity.get("item_id", 0))) if grid != null else null


func _find_live_item_across_grids(identity: Dictionary) -> Dictionary:
    var item_id := int(identity.get("item_id", identity.get("id", 0)))
    var expected_scope := StringName(identity.get("scope", &""))
    var expected_generation := int(identity.get("owner_generation", 0))
    var expected_definition := str(identity.get("item_definition_identifier", ""))
    if item_id <= 0:
        return {}
    for grid in _grids:
        if not is_instance_valid(grid):
            continue
        var source_key := str(grid.get("source_id"))
        for value in _items_for(source_key):
            if not value is Dictionary:
                continue
            var item: Dictionary = value
            if int(item.get("item_id", item.get("id", 0))) != item_id:
                continue
            if expected_scope != &"" and StringName(item.get("scope", &"")) != expected_scope:
                continue
            if expected_generation > 0 and int(item.get("owner_generation", 0)) != expected_generation:
                continue
            if not expected_definition.is_empty() \
                    and str(item.get("item_definition_identifier", "")) != expected_definition:
                continue
            return {"source": source_key, "item": item.duplicate(true)}
    return {}

func _select_tab(tab: String) -> void:
    if _live_inventory_binding:
        _live_inventory_tab = tab
    else:
        _state()["inventory_tab"] = tab
    var route: String = "inventory" if tab == "gear" else tab
    if app != null and app.has_method("navigate"):
        app.navigate(route)
    else:
        _refresh_body()


func _set_filter(filter_name: String) -> void:
    _current_filter = filter_name
    if not _live_inventory_binding:
        _state()["inventory_filter"] = filter_name
    _refresh_body()
    _notify("Filter: " + filter_name.to_upper())


func _set_loot_mode(show_loot: bool) -> void:
    if show_loot:
        _open_loot_container()
    else:
        _close_loot_container(false)
    if not _live_inventory_binding:
        _current_filter = "all"
        _search_query = ""
        _state()["inventory_loot_mode"] = _loot_mode
        _state()["inventory_filter"] = _current_filter
        _state()["inventory_search"] = _search_query
    _refresh_body()
    _notify("Showing " + ("loot container" if _loot_mode else "stash"))


func _open_loot_container() -> void:
    _loot_mode = true
    _loot_container_open = true
    if _live_inventory_binding:
        _binding_token_serial += 1
        _active_binding_token = _binding_token_serial
        if _inventory_controller != null:
            _inventory_controller.open_loot_container()
    _cancel_split_quantity()
    _close_tip()


func _close_loot_container(refresh: bool = true) -> void:
    if _live_inventory_binding and _inventory_controller != null:
        _inventory_controller.close_loot_container()
    _loot_container_open = false
    _loot_mode = false
    if _live_inventory_binding:
        _binding_token_serial += 1
        _active_binding_token = _binding_token_serial
    _cancel_split_quantity()
    _close_tip()
    if refresh:
        _refresh_body()
        var stash_tab: Button = call("_node", "StashTab") as Button if has_method("_node") else null
        if stash_tab != null:
            stash_tab.call_deferred("grab_focus")


func _on_grid_hovered(item: Dictionary, hovering: bool, _grid: Control) -> void:
    if _payload_is_stale(item):
        return
    if _live_inventory_binding and _inventory_controller != null and int(item.get("item_id", 0)) > 0:
        # Hover is already rendered by the retained native Button. The controller
        # still records it in the presentation model, but its synchronous
        # model_changed echo must not rebuild/reflow the screen from inside the
        # mouse-enter dispatch that discovered the slot.
        _local_presentation_refresh_depth += 1
        _inventory_controller.hover(
            StringName(str(_grid.get("source_id"))),
            int(item.get("item_id", 0)),
            hovering)
        _local_presentation_refresh_depth -= 1
    var kind: String = str(item.get("kind", ""))
    if hovering and kind == "weapon":
        var key: String = str(item.get("compatibility", ""))
        if key.is_empty():
            key = "7.62x39"
        _set_compatibility(key)
    elif not hovering and kind == "weapon":
        _clear_compatibility()


func _on_grid_selected(item: Dictionary, source_key: String) -> void:
    if _payload_is_stale(item):
        return
    if _live_inventory_binding and _inventory_controller != null:
        _selected_live_item = item.duplicate(true)
        _selected_live_source = source_key
        _reconcile_live_selection_rims()
        # The originating grid has already reconciled its selected rim. Avoid a
        # synchronous full-screen refresh while Button is still emitting `pressed`.
        _local_presentation_refresh_depth += 1
        _inventory_controller.select(StringName(source_key), int(item.get("item_id", 0)))
        _local_presentation_refresh_depth -= 1
    _show_item_tip(item, source_key)


func _on_grid_context(item: Dictionary, source_key: String) -> void:
    if _payload_is_stale(item):
        return
    if _live_inventory_binding and _inventory_controller != null:
        _selected_live_item = item.duplicate(true)
        _selected_live_source = source_key
        _reconcile_live_selection_rims()
        _local_presentation_refresh_depth += 1
        _inventory_controller.select(StringName(source_key), int(item.get("item_id", 0)))
        _local_presentation_refresh_depth -= 1
    _show_item_tip(item, source_key)


func _reconcile_live_selection_rims() -> void:
    var selected_item_id := str(_selected_live_item.get("item_id", 0)) \
        if not _selected_live_item.is_empty() else ""
    for grid in _grids:
        if not is_instance_valid(grid):
            continue
        var desired := selected_item_id \
            if str(grid.get("source_id")) == _selected_live_source else ""
        if grid.has_method("set_selected_item_id"):
            grid.set_selected_item_id(desired)


func _on_quick_move(item: Dictionary, source_key: String) -> void:
    if _payload_is_stale(item):
        _notify("Inventory gesture expired · no request submitted")
        return
    if _live_inventory_binding and _inventory_controller != null:
        _selected_live_item = item.duplicate(true)
        _selected_live_source = source_key
        _handle_live_result(_inventory_controller.submit_quick(StringName(source_key), item), "quick transfer")
        return
    _move_item(item, source_key)


func _on_item_dropped(item: Dictionary, source_key: String, destination: Vector2i, _destination_grid: Control) -> void:
    if _payload_is_stale(item):
        _notify("Inventory release expired · no request submitted")
        return
    var target_key: String = str(_destination_grid.get("source_id"))
    if _live_inventory_binding and _inventory_controller != null:
        var mode := StringName(str(item.get("_drop_mode", "move")))
        var merge_target := int(item.get("_merge_target_item_id", 0))
        _handle_live_result(_inventory_controller.submit_drop(StringName(source_key), StringName(target_key), item, destination, mode, merge_target), str(mode))
        return
    if target_key.is_empty() or source_key == target_key:
        if source_key == target_key:
            _reposition_item(item, source_key, destination)
        return
    _move_item(item, source_key, target_key, destination)


func _on_drop_rejected(item: Dictionary, _source_key: String, _destination: Vector2i) -> void:
    if _live_inventory_binding:
        _notify("Invalid release · " + str(item.get("name", "item")) + " was not submitted")
        return
    _notify("Invalid drop · " + str(item.get("name", "item")) + " does not fit here")


func _on_split_requested(item: Dictionary, source_key: String, destination: Vector2i, destination_grid: Control) -> void:
    if _payload_is_stale(item) or not _live_inventory_binding:
        if _payload_is_stale(item):
            _notify("Inventory split expired · no request submitted")
        return
    if _inventory_controller == null or not is_instance_valid(destination_grid) \
            or int(destination_grid.get("binding_token")) != _active_binding_token:
        _notify("Inventory split expired · destination changed")
        return
    var quantity := int(item.get("quantity", item.get("count", 0)))
    if quantity <= 1:
        _notify("Split unavailable · quantity must be at least 2")
        return
    var target_key := str(destination_grid.get("source_id"))
    var source_desc := _inventory_controller.descriptor(StringName(source_key))
    var target_desc := _inventory_controller.descriptor(StringName(target_key))
    if String(source_desc.get("scope", "")) != String(target_desc.get("scope", "")) \
            or int(source_desc.get("inventory_id", 0)) != int(target_desc.get("inventory_id", 0)):
        _notify("Split unavailable · source and destination must share one inventory")
        return
    if not _inventory_controller.split_available(StringName(source_key), StringName(target_key)):
        _notify("Split unavailable · world loot must transfer before stack editing")
        return
    if app == null or is_instance_valid(app.modal):
        _notify("Split unavailable · close the active dialog first")
        return
    _cancel_split_quantity()
    _split_item = item.duplicate(true)
    _split_source = source_key
    _split_target = target_key
    _split_target_descriptor = target_desc.duplicate(true)
    _split_destination = destination
    app.prompt(
        "SPLIT %s · QUANTITY 1–%d" % [str(item.get("name", "ITEM")).to_upper(), quantity - 1],
        "1",
        Callable(self, "_confirm_split_value"),
        6
    )
    _split_dialog = app.modal
    if not is_instance_valid(_split_dialog):
        _clear_split_state()
        _notify("Split unavailable · modal service did not open")
        return
    var fields := _split_dialog.find_children("*", "LineEdit", true, false)
    _split_spin = fields[0] as LineEdit if not fields.is_empty() else null
    var dismissed := Callable(self, "_on_split_dialog_dismissed")
    if not _split_dialog.is_connected(&"dismissed", dismissed):
        _split_dialog.connect(&"dismissed", dismissed, CONNECT_ONE_SHOT)


func _confirm_split_quantity() -> void:
    if not is_instance_valid(_split_dialog) or not is_instance_valid(_split_spin):
        return
    var dialog := _split_dialog
    var value := _split_spin.text
    _confirm_split_value(value)
    if is_instance_valid(dialog) and dialog.has_signal("dismissed"):
        dialog.emit_signal(&"dismissed")


func _confirm_split_value(value: String) -> void:
    if not _live_inventory_binding or _inventory_controller == null or _split_item.is_empty():
        _clear_split_state()
        return
    if not _split_target_is_current():
        _notify("Inventory split expired · destination changed")
        _clear_split_state()
        return
    var normalized := value.strip_edges()
    var maximum: int = int(_split_item.get("quantity", _split_item.get("count", 1))) - 1
    if not normalized.is_valid_int() or int(normalized) < 1 or int(normalized) > maximum:
        _notify("Split unavailable · enter a quantity from 1 to %d" % maximum)
        _clear_split_state()
        return
    var quantity := int(normalized)
    var source := _split_source
    var target := _split_target
    var split_item := _split_item.duplicate(true)
    var destination := _split_destination
    # Clear before synchronous submission: the accepted projection is allowed
    # to rebuild the screen immediately and must not dismiss/re-enter this modal.
    _clear_split_state()
    var result := _inventory_controller.submit_drop(
        StringName(source), StringName(target), split_item,
        destination, InventoryPresentationController.OP_SPLIT, 0, quantity)
    _handle_live_result(result, "split")


func _cancel_split_quantity(close_dialog: bool = true) -> void:
    var dialog := _split_dialog
    _clear_split_state()
    if close_dialog and is_instance_valid(dialog) and dialog.has_signal("dismissed"):
        dialog.emit_signal(&"dismissed")


func _on_split_dialog_dismissed() -> void:
    _clear_split_state()


func _clear_split_state() -> void:
    _split_dialog = null
    _split_spin = null
    _split_item = {}
    _split_source = ""
    _split_target = ""
    _split_target_descriptor = {}
    _split_destination = Vector2i.ZERO


func _split_target_is_current() -> bool:
    if _inventory_controller == null or _split_target.is_empty() or _split_target_descriptor.is_empty():
        return false
    var current := _inventory_controller.descriptor(StringName(_split_target))
    for key in ["scope", "inventory_id", "container_id", "owner_generation", "scope_generation", "mapping_key"]:
        if current.get(key, null) != _split_target_descriptor.get(key, null):
            return false
    return bool(current.get("available", false))


func _split_gesture_is_current() -> bool:
    if not _split_target_is_current() or _split_item.is_empty():
        return false
    var current := _current_item_for_source(_split_source, _split_item)
    if current.is_empty():
        return false
    for key in ["item_id", "inventory_id", "container_id", "scope", "owner_generation", "scope_generation", "mapping_key", "item_definition_identifier", "quantity", "x", "y", "rotated"]:
        if current.get(key, null) != _split_item.get(key, null):
            return false
    return true


func _reposition_item(item: Dictionary, source_key: String, destination: Vector2i) -> void:
    if _payload_is_stale(item):
        _notify("Inventory gesture expired · no request submitted")
        return
    if _live_inventory_binding and _inventory_controller != null:
        _handle_live_result(_inventory_controller.submit_drop(StringName(source_key), StringName(source_key), item, destination), "move")
        return
    var values: Array = _items_for(source_key)
    for value in values:
        if str(value.get("id", "")) == str(item.get("id", "")):
            value["x"] = destination.x
            value["y"] = destination.y
    _write_items(source_key, values)
    _refresh_body()
    _notify("Moved " + str(item.get("name", "item")))


func _move_item(item: Dictionary, source_key: String, target_key: String = "", destination: Vector2i = Vector2i(-1, -1)) -> void:
    if _payload_is_stale(item):
        _notify("Inventory gesture expired · no request submitted")
        return
    if _live_inventory_binding and _inventory_controller != null:
        var target := target_key
        if target.is_empty():
            target = _selected_container
        if destination.x < 0 or destination.y < 0:
            _notify("Move unavailable · choose an exact destination cell")
            return
        _handle_live_result(_inventory_controller.submit_drop(StringName(source_key), StringName(target), item, destination), "move")
        return
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
    if _tearing_down or _surface == null or not is_inside_tree():
        return
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
    if _live_inventory_binding:
        txt(_tooltip, "LIVE", Rect2(160, 8, 74, 20), 11, U.GREEN, true).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        var live_detail := "CONFIRMED PROJECTION · QTY " + str(item.get("quantity", item.get("count", 1)))
        txt(_tooltip, live_detail, Rect2(12, 37, 222, 34), 10, U.GREEN, true)
    else:
        var value_text: String = "$ 480" if str(item.get("kind", "")) == "ammo" else ("$ 3,000" if str(item.get("kind", "")) == "weapon" else "$ 120")
        txt(_tooltip, value_text, Rect2(160, 8, 74, 20), 11, U.ACCENT, true).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
        var compatibility: String = "AKM compatible · fits AK 30-rd mag" if not str(item.get("compatibility", "")).is_empty() else "Container item · local mock state"
        txt(_tooltip, compatibility, Rect2(12, 37, 222, 34), 10, U.GREEN if not str(item.get("compatibility", "")).is_empty() else U.MUTED, true)
    rule(_tooltip, 12, 80, 222)
    var move_button: Button = btn(_tooltip, "F · MOVE", Rect2(12, 90, 102, 28), Callable(self, "_tip_move"), false)
    move_button.add_theme_font_size_override("font_size", 10)
    if _live_inventory_binding and (_inventory_controller == null \
            or not _inventory_controller.quick_transfer_available(StringName(source_key))):
        move_button.text = "UNAVAILABLE"
        move_button.disabled = true
        move_button.tooltip_text = "Profile transfer is unavailable in live mode"
    var close_button: Button = btn(_tooltip, "RMB · CLOSE", Rect2(124, 90, 110, 28), Callable(self, "_close_tip"), false)
    close_button.add_theme_font_size_override("font_size", 10)


func _tip_move() -> void:
    if not _tip_item.is_empty():
        if _live_inventory_binding:
            if _inventory_controller == null \
                    or not _inventory_controller.quick_transfer_available(StringName(_tip_source)):
                _notify("Quick transfer unavailable in live mode")
                _close_tip()
                return
            _on_quick_move(_tip_item, _tip_source)
        else:
            _move_item(_tip_item, _tip_source)
    _close_tip()


func _close_tip() -> void:
    # Cancel any queued interaction restore captured while this tooltip was
    # open; otherwise a same-frame explicit close could be undone next frame.
    _interaction_restore_serial += 1
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
    if _live_inventory_binding:
        _notify("Unavailable in live raid · container changes are authority-owned")
        return
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
    if _live_inventory_binding:
        _notify("Quick heal unavailable in this inventory view")
        return
    var state: Dictionary = _state()
    state["last_quick_heal"] = "torso"
    state["quick_healed"] = true
    state["med_count"] = max(0, int(state.get("med_count", 2)) - 1)
    if _tab_name() == "health" or get_viewport_rect().size.x < 1920 or get_viewport_rect().size.y < 1080:
        _refresh_body()
    _notify("QUICK HEAL · Sanitizer used on torso")


func _gear_selected(title: String, _detail: String) -> void:
    if _live_inventory_binding:
        return
    if title == "ON SLING":
        _set_compatibility("7.62x39")
    else:
        _notify(title + " selected")


func _bank_loot() -> void:
    if _live_inventory_binding:
        _notify("Bank loot unavailable · profile↔raid transfer is not supported here")
        return
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
    if _live_inventory_binding:
        _notify("Re-insurance unavailable in live inventory mode")
        return
    _notify("Loadout re-insured for $ 340")


func _sell_junk() -> void:
    if _live_inventory_binding:
        _notify("Sell unavailable in live inventory mode")
        return
    _notify("Junk preview · +$ 620 (mock only)")


func _sort_stash() -> void:
    if _live_inventory_binding:
        _notify("Sort unavailable in live mode")
        return
    _current_filter = "all"
    _search_query = ""
    _notify("Stash sorted by value ↓")
    _refresh_body()


func _organize_stash() -> void:
    if _live_inventory_binding:
        _notify("Organize unavailable in live mode")
        return
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
    # Authority teardown can race the host's CommonUI teardown during process
    # exit. Never ask a detached feedback timer to render a late diagnostic.
    var host := app._service() if app != null else null
    var feedback := host.get("feedback") as Node if host != null else null
    if is_inside_tree() and host != null and host.is_inside_tree() \
            and feedback != null and feedback.is_inside_tree() \
            and app.has_method("toast"):
        app.toast(message)


func _unhandled_input(event: InputEvent) -> void:
    if not accepts_input(): return
    if _live_input_suspended(): return
    if event is InputEventKey and event.pressed and not event.echo:
        var key_event: InputEventKey = event as InputEventKey
        if key_event.keycode == KEY_R and _live_inventory_binding:
            if _inventory_controller != null and not _selected_live_item.is_empty():
                _handle_live_result(_inventory_controller.submit_rotate(StringName(_selected_live_source), _selected_live_item), "rotate")
            else:
                _notify("Rotate unavailable · select an item")
            get_viewport().set_input_as_handled()
        elif key_event.keycode == KEY_Y:
            _quick_heal()
            get_viewport().set_input_as_handled()
        elif key_event.keycode == KEY_F and not key_event.ctrl_pressed and not _tip_item.is_empty():
            _tip_move()
            get_viewport().set_input_as_handled()


func attach_injected_character_runtime() -> bool:
    if app == null or not app.has_method("character_runtime"):
        return false
    var runtime := app.character_runtime() as CharacterUIRuntime
    if runtime == null or not is_instance_valid(runtime):
        return false
    _character_runtime = runtime
    _inventory_controller = runtime.inventory_controller()
    _shared_inventory_controller = true
    _live_inventory_binding = true
    _live_health_binding = true
    _health_view = runtime.health_view()
    _binding_token_serial += 1
    _active_binding_token = _binding_token_serial
    _connect_inventory_controller_signals()
    if not runtime.health_view_changed.is_connected(_on_runtime_health_view_changed):
        runtime.health_view_changed.connect(_on_runtime_health_view_changed)
    if not runtime.binding_invalidated.is_connected(_on_runtime_binding_invalidated):
        runtime.binding_invalidated.connect(_on_runtime_binding_invalidated)
    if not runtime.binding_rebound.is_connected(_on_runtime_binding_rebound):
        runtime.binding_rebound.connect(_on_runtime_binding_rebound)
    _apply_runtime_interaction_state(runtime.interaction_state())
    return true


func stash_character_interaction_state() -> void:
    if _character_runtime == null or not is_instance_valid(_character_runtime):
        return
    var interaction := _capture_inventory_interaction()
    # Control references belong to this soon-to-be-replaced scene. Retain only
    # semantic focus identity/path plus the exact caret and scroll coordinates.
    interaction.erase("focus")
    interaction["current_filter"] = _current_filter
    interaction["search_query"] = _search_query
    interaction["loot_mode"] = _loot_mode
    interaction["loot_open"] = _loot_container_open
    interaction["selected_container"] = _selected_container
    interaction["selected_item"] = _selected_live_item.duplicate(true)
    interaction["selected_source"] = _selected_live_source
    interaction["live_tab"] = _live_inventory_tab
    interaction["compatibility_key"] = _compatibility_key
    _character_runtime.save_interaction_state(interaction)


func _apply_runtime_interaction_state(state: Dictionary) -> void:
    if state.is_empty():
        return
    _current_filter = str(state.get("current_filter", _current_filter))
    _search_query = str(state.get("search_query", _search_query))
    _loot_mode = bool(state.get("loot_mode", _loot_mode))
    _loot_container_open = bool(state.get("loot_open", _loot_container_open))
    _selected_container = str(state.get("selected_container", _selected_container))
    _selected_live_item = (state.get("selected_item", {}) as Dictionary).duplicate(true)
    _selected_live_source = str(state.get("selected_source", ""))
    _live_inventory_tab = str(state.get("live_tab", _live_inventory_tab))
    _compatibility_key = str(state.get("compatibility_key", _compatibility_key))
    _pending_runtime_interaction = state.duplicate(true)
    _activation_runtime_interaction = state.duplicate(true)


func restore_injected_character_interaction() -> void:
    if _pending_runtime_interaction.is_empty():
        return
    var interaction := _pending_runtime_interaction
    _pending_runtime_interaction = {}
    _restore_inventory_interaction(interaction)
    _interaction_restore_serial += 1
    call_deferred(
        "_restore_inventory_interaction_deferred",
        interaction,
        _interaction_restore_serial)


func restore_injected_character_interaction_on_activation() -> void:
    if _activation_runtime_interaction.is_empty():
        return
    # CommonUI establishes its default focus during activation. Restore the
    # semantic Character focus after that lifecycle step so a route replacement
    # cannot replace an injected search caret with the workspace default.
    var interaction := _activation_runtime_interaction
    _activation_runtime_interaction = {}
    _restore_inventory_interaction(interaction)
    _interaction_restore_serial += 1
    call_deferred(
        "_restore_inventory_interaction_deferred",
        interaction,
        _interaction_restore_serial)


func _connect_inventory_controller_signals() -> void:
    if _inventory_controller == null:
        return
    var projection := Callable(self, "_on_live_projection_changed")
    var pending := Callable(self, "_on_live_pending_changed")
    var status := Callable(self, "_on_live_status_changed")
    var rejection := Callable(self, "_on_live_rejection")
    var accepted := Callable(self, "_on_live_acceptance")
    var invalidated := Callable(self, "_on_live_binding_invalidated")
    if not _inventory_controller.projection_changed.is_connected(projection):
        _inventory_controller.projection_changed.connect(projection)
    if not _inventory_controller.pending_changed.is_connected(pending):
        _inventory_controller.pending_changed.connect(pending)
    if not _inventory_controller.status_changed.is_connected(status):
        _inventory_controller.status_changed.connect(status)
    if not _inventory_controller.rejection_feedback.is_connected(rejection):
        _inventory_controller.rejection_feedback.connect(rejection)
    if not _inventory_controller.accepted_feedback.is_connected(accepted):
        _inventory_controller.accepted_feedback.connect(accepted)
    if not _inventory_controller.binding_invalidated.is_connected(invalidated):
        _inventory_controller.binding_invalidated.connect(invalidated)


func _disconnect_inventory_controller_signals() -> void:
    if _inventory_controller == null:
        return
    for pair in [
        ["projection_changed", Callable(self, "_on_live_projection_changed")],
        ["pending_changed", Callable(self, "_on_live_pending_changed")],
        ["status_changed", Callable(self, "_on_live_status_changed")],
        ["rejection_feedback", Callable(self, "_on_live_rejection")],
        ["accepted_feedback", Callable(self, "_on_live_acceptance")],
        ["binding_invalidated", Callable(self, "_on_live_binding_invalidated")],
    ]:
        var signal_name: StringName = pair[0]
        var callback: Callable = pair[1]
        if _inventory_controller.is_connected(signal_name, callback):
            _inventory_controller.disconnect(signal_name, callback)


func _detach_character_runtime() -> void:
    if _character_runtime != null and is_instance_valid(_character_runtime):
        if _character_runtime.health_view_changed.is_connected(_on_runtime_health_view_changed):
            _character_runtime.health_view_changed.disconnect(_on_runtime_health_view_changed)
        if _character_runtime.binding_invalidated.is_connected(_on_runtime_binding_invalidated):
            _character_runtime.binding_invalidated.disconnect(_on_runtime_binding_invalidated)
        if _character_runtime.binding_rebound.is_connected(_on_runtime_binding_rebound):
            _character_runtime.binding_rebound.disconnect(_on_runtime_binding_rebound)
    _character_runtime = null
    _shared_inventory_controller = false
    _live_health_binding = false
    _health_view = null


func bind_inventory_runtime(owner, bridge, adapter, admission) -> bool:
    if _character_runtime != null:
        _disconnect_inventory_controller_signals()
        _detach_character_runtime()
    if _inventory_controller == null:
        _inventory_controller = InventoryPresentationController.new()
    # An attempted production bind is itself a fail-closed boundary. Never
    # leave fixture content interactive if dependency validation rejects it.
    _interaction_restore_serial += 1
    _active_binding_token = 0
    _live_inventory_binding = true
    _loot_mode = false
    _loot_container_open = false
    _close_tip()
    _cancel_split_quantity()
    if not _inventory_controller.bind(owner, bridge, adapter, admission):
        _notify("Inventory live binding unavailable · " + str(_inventory_controller.last_error))
        if not _tearing_down and is_inside_tree():
            _refresh_body()
        return false
    _binding_token_serial += 1
    _active_binding_token = _binding_token_serial
    _connect_inventory_controller_signals()
    _refresh_body()
    return true


func unbind_inventory_runtime() -> void:
    if _inventory_controller == null:
        return
    var was_live := _live_inventory_binding
    _interaction_restore_serial += 1
    _active_binding_token = 0
    _disconnect_inventory_controller_signals()
    if _shared_inventory_controller:
        _detach_character_runtime()
    else:
        _inventory_controller.unbind()
    _live_inventory_binding = false
    _loot_container_open = false
    _selected_live_item = {}
    _selected_live_source = ""
    _close_tip()
    _cancel_split_quantity()
    # Live presentation state is deliberately not written into fixture storage.
    # Returning to the fixture must therefore restore its own retained choices
    # instead of leaking the live loot tab/query into the preview controller.
    if was_live:
        var persisted := _state()
        _loot_mode = bool(persisted.get("inventory_loot_mode", false))
        _current_filter = str(persisted.get("inventory_filter", "all"))
        _search_query = str(persisted.get("inventory_search", ""))
        _compact_section = str(persisted.get("inventory_compact_section", "loadout"))
    if was_live and not _tearing_down and is_inside_tree():
        _refresh_body()


func _exit_tree() -> void:
    _tearing_down = true
    _interaction_restore_serial += 1
    stash_character_interaction_state()
    # Free transient native widgets immediately while the screen still owns them;
    # queue_free here can leave popup CanvasItems alive until process exit.
    if is_instance_valid(_tooltip):
        _tooltip.free()
    _tooltip = null
    _tip_item = {}
    _cancel_split_quantity()
    unbind_inventory_runtime()
    super._exit_tree()


func _on_runtime_health_view_changed(view: HealthView) -> void:
    if not _live_health_binding:
        return
    _health_view = view
    _refresh_body()


func _on_runtime_binding_invalidated(_reason: StringName) -> void:
    if _character_runtime == null:
        return
    # Runtime-level teardown/configuration failure disconnects the controller
    # before publishing this event, so invalidate the screen-local gesture lease
    # here rather than relying on a controller signal that cannot arrive.
    _active_binding_token = 0
    _cancel_split_quantity()
    _health_view = _character_runtime.health_view()
    _refresh_body()


func _on_runtime_binding_rebound(_generation: int) -> void:
    if _character_runtime == null or not _character_runtime.is_configured():
        return
    # Tokens are screen-local presentation leases. A newly injected authority
    # must never accept a drag payload captured from the former generation.
    _binding_token_serial += 1
    _active_binding_token = _binding_token_serial
    _health_view = _character_runtime.health_view()
    _apply_runtime_interaction_state(_character_runtime.interaction_state())
    _refresh_body()


func _on_live_projection_changed(_scope: StringName) -> void:
    if _live_inventory_binding and _local_presentation_refresh_depth == 0:
        if is_instance_valid(_split_dialog) and not _split_gesture_is_current():
            _cancel_split_quantity()
        _refresh_body()


func _on_live_pending_changed(_scope: StringName) -> void:
    if _live_inventory_binding:
        _refresh_body()


func _on_live_status_changed(_scope: StringName, _status: int) -> void:
    if _live_inventory_binding:
        if is_instance_valid(_split_dialog) and (_inventory_controller == null \
                or not _inventory_controller.mutation_available(StringName(_split_source)) \
                or not _inventory_controller.mutation_available(StringName(_split_target))):
            _cancel_split_quantity()
        _refresh_body()


func _on_live_rejection(info: Dictionary) -> void:
    if _live_inventory_binding:
        var status: Dictionary = info.get("status", {})
        var reason := str(status.get("reason", info.get("reason_token", "rejected")))
        # Keep the stable authority reason while presenting it as bounded,
        # human-readable toast copy.  The shared feedback layer constrains the
        # retained toast to the viewport and wraps long details safely.
        _notify("REJECTED · " + reason.replace("_", " "))
        _refresh_body()


func _on_live_acceptance(_info: Dictionary) -> void:
    if _live_inventory_binding:
        _notify("Inventory confirmed")
        _refresh_body()


func _on_live_binding_invalidated(reason: StringName) -> void:
    # Keep the screen in the explicit live/read-only state after teardown or a
    # generation change. Falling back to fixture storage here would expose sample
    # identity and re-enable mutations while the authority is disconnected.
    _active_binding_token = 0
    # Keep an already-open loot tab visible as DISCONNECTED so the retained
    # workspace does not silently fall back to fixture identity.  New gestures
    # remain fail-closed through the controller's binding checks.
    _cancel_split_quantity()
    _notify("Inventory disconnected · " + str(reason))
    _refresh_body()


func _handle_live_result(result: Dictionary, operation: String) -> void:
    if bool(result.get("replayed", false)):
        return
    # Synchronous accepted/rejected commands have already emitted the model's
    # one-shot stable feedback. Do not overwrite it with a stale "pending"
    # toast or a second raw rejection.
    if bool(result.get("ui_resolved", false)):
        return
    if bool(result.get("accepted", false)):
        _notify(operation.to_upper() + " pending authority confirmation")
    else:
        _notify("Inventory rejected · " + str(result.get("reason", "unavailable")))


func _live_input_suspended() -> bool:
    if is_instance_valid(_split_dialog):
        return true
    var focus := get_viewport().gui_get_focus_owner()
    return focus is LineEdit or focus is TextEdit


func _payload_is_stale(item: Dictionary) -> bool:
    if _tearing_down:
        return true
    var token := int(item.get("_binding_token", 0))
    if _live_inventory_binding:
        # Every live grid callback carries the binding token stamped during the
        # current bind. A token-less callback can only be a retained fixture
        # preview and must not cross into the live authority seam.
        return token != _active_binding_token
    # Fixture callbacks remain local, but a callback from a prior live bind is
    # stale even after the screen has fallen back to the preview mode.
    return token > 0
