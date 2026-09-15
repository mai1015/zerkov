extends "res://ui/screens/utilities/utility_actions.gd"

## Authored settings screen controller.
##
## The desktop and compact control hierarchy is authored in settings.tscn. This
## controller resolves state-dependent values, style, and actions while keeping
## utility.gd's compact panes and native input behavior in charge of reflow.

const HEADER_FILL := Color(0.027, 0.035, 0.031, 0.97)
const CROSSHAIR_DARK := Color(0.0, 0.0, 0.0, 0.76)
const SETTINGS_SECTIONS := ["gameplay", "hud", "video", "audio"]


func build() -> void:
    if app.offline_bunker() != null:
        _build_offline_settings()
        return
    reset_adaptive_layout()
    route = "settings"
    var saved_scroll = _state_value("utility_settings_scroll", {})
    _compact_scroll = saved_scroll.duplicate() if saved_scroll is Dictionary else {}
    _configure_static_styles()
    _bind_chrome()
    _bind_sidebar()
    _bind_settings_controls()
    _bind_preview()
    _apply_section_state()
    _apply_preview_state()
    _configure_chrome_visibility(get_viewport_rect().size)
    queue_adaptive_layout()


## Re-rendering a generated utility screen removed and rebuilt every child. The
## authored scene keeps those children alive by remounting this scene, which
## also gives compact panes a clean source region after section changes.
func _rerender() -> void:
    for node in find_children("*", "ScrollContainer", true, false):
        _compact_scroll[str(node.name)] = node.scroll_vertical
    if app != null:
        app.fixture_set("utility_settings_scroll", _compact_scroll.duplicate())
        app.navigate("settings", false)


func layout_compact(view: Vector2) -> void:
    _configure_chrome_visibility(view)
    super.layout_compact(view)

func _configure_static_styles() -> void:
    var chrome := get_node_or_null("NavigationChrome") as ZNavigationChrome
    for node in find_children("*", "Control", true, false):
        var control := node as Control
        if chrome != null and (control == chrome or chrome.is_ancestor_of(control)):
            continue
        if control is Panel:
            var panel := control as Panel
            if panel.name == "BackdropBase":
                panel.add_theme_stylebox_override("panel", _style_box(C_BG, Color.TRANSPARENT, 0))
            elif panel.name == "Header" or panel.name == "CompactHeader":
                panel.add_theme_stylebox_override("panel", _style_box(HEADER_FILL, Color.TRANSPARENT, 0))
            else:
                panel.add_theme_stylebox_override("panel", _style_box(C_DARK, C_LINE, 1))
            panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
        elif control is Button:
            _style_button_base(control as Button)
        elif control is LineEdit:
            var field := control as LineEdit
            field.focus_mode = Control.FOCUS_ALL
            field.add_theme_font_override("font", U.font(false, true))
            field.add_theme_color_override("font_color", C_TEXT)
            field.add_theme_color_override("font_placeholder_color", C_MUTED)
            field.add_theme_color_override("caret_color", C_ACCENT)
            field.add_theme_stylebox_override("normal", _style_box(Color(0, 0, 0, 0.18), C_LINE, 1))
            field.add_theme_stylebox_override("focus", _style_box(Color(0.07, 0.08, 0.075, 0.92), C_ACCENT, 1))
        elif control is HSlider:
            (control as HSlider).focus_mode = Control.FOCUS_ALL
            _style_slider(control as HSlider)
        if control is Label:
            _style_label(control as Label)


func _style_label(label: Label) -> void:
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    if bool(label.get_meta("settings_tracked", false)):
        label.add_theme_font_override("font", U.tracked_font(false, true, 2))
    elif bool(label.get_meta("settings_tracked_mono", false)):
        label.add_theme_font_override("font", U.tracked_font(true, false, 1))
    elif bool(label.get_meta("settings_mono", false)):
        label.add_theme_font_override("font", U.font(true, true))
    else:
        label.add_theme_font_override("font", U.font(false, true))


func _style_button_base(button: Button) -> void:
    button.focus_mode = Control.FOCUS_ALL
    button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
    button.add_theme_font_override("font", U.font(false, true))
    button.add_theme_font_size_override("font_size", 11)
    button.add_theme_color_override("font_color", C_TEXT)
    button.add_theme_color_override("font_hover_color", C_HOVER)
    button.add_theme_color_override("font_pressed_color", C_BG)
    button.add_theme_stylebox_override("normal", _style_box(C_DARK, C_LINE, 1))
    button.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.05), C_TEXT, 1))
    button.add_theme_stylebox_override("pressed", _style_box(Color(0.75, 0.42, 0.12, 0.35), C_ACCENT, 1))
    button.add_theme_stylebox_override("focus", _style_box(Color(1, 1, 1, 0.06), C_ACCENT, 1))
    button.add_theme_stylebox_override("disabled", _style_box(Color(0.04, 0.05, 0.05, 0.45), Color(1, 1, 1, 0.08), 1))


func _style_nav_button(button: Button, selected: bool) -> void:
    if button == null:
        return
    button.add_theme_font_override("font", U.tracked_font(false, true, 2))
    button.add_theme_font_size_override("font_size", 13)
    button.add_theme_color_override("font_color", C_TEXT if selected else C_MUTED)
    button.add_theme_color_override("font_hover_color", C_HOVER)
    button.add_theme_stylebox_override("normal", _style_box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
    button.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.04), C_TEXT, 0))
    button.add_theme_stylebox_override("focus", _style_box(Color(1, 1, 1, 0.04), C_ACCENT, 1))


func _wire_button(button: Button, callback: Callable) -> void:
    if button == null or not callback.is_valid() or bool(button.get_meta("settings_action_bound", false)):
        return
    button.pressed.connect(callback)
    button.set_meta("settings_action_bound", true)


func _bind_chrome() -> void:
    var chrome := get_node_or_null("NavigationChrome") as ZNavigationChrome
    if chrome != null:
        chrome.active_route = "settings"
        var navigate_callback := Callable(self, "_go")
        if not chrome.navigate_requested.is_connected(navigate_callback):
            chrome.navigate_requested.connect(navigate_callback)
        var insurance_callback := Callable(self, "_settings_insurance_notice")
        if not chrome.insurance_requested.is_connected(insurance_callback):
            chrome.insurance_requested.connect(insurance_callback)
        mark_feature_action(chrome.get_node_or_null("Insurance") as Control,
            FEATURE_INSURANCE)
        var back_callback := Callable(self, "_settings_back")
        if not chrome.back_requested.is_connected(back_callback):
            chrome.back_requested.connect(back_callback)


func _configure_chrome_visibility(view: Vector2) -> void:
    var chrome := get_node_or_null("NavigationChrome") as ZNavigationChrome
    if chrome != null:
        chrome.show()
        chrome.layout_for(view)

func _settings_insurance_notice() -> void:
    notify_feature_action(FEATURE_INSURANCE)


func _settings_back() -> void:
    if app != null:
        app.back()


func _bind_sidebar() -> void:
    var selected := str(_state_value("utility_settings_section", "hud"))
    for button in find_children("Category*", "Button", false, false):
        var category := str(button.get_meta("settings_category", ""))
        if category.is_empty():
            continue
        _wire_button(button as Button, Callable(self, "_select_settings_section").bind(category))
        var active := category == selected
        var item := button as Button
        item.alignment = HORIZONTAL_ALIGNMENT_LEFT
        item.add_theme_font_size_override("font_size", 12)
        item.add_theme_color_override("font_color", C_TEXT if active else C_MUTED)
        item.add_theme_stylebox_override("normal", _style_box(Color(1, 1, 1, 0.06) if active else Color.TRANSPARENT, C_TEXT if active else Color.TRANSPARENT, 0 if not active else 1))
        item.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.04), C_TEXT, 1))
    var search := get_node_or_null("SearchField") as LineEdit
    if search != null:
        search.text = str(_state_value("utility_settings_search", ""))
        search.placeholder_text = "e.g. \"crosshair\""
        var callback := Callable(self, "_on_settings_search")
        if not search.text_changed.is_connected(callback):
            search.text_changed.connect(callback)


func _bind_settings_controls() -> void:
    for node in get_children():
        if not node.has_meta("settings_kind"):
            continue
        var kind := str(node.get_meta("settings_kind"))
        var key := str(node.get_meta("settings_key", ""))
        if kind == "slider":
            _bind_slider(node as HSlider, key)
        elif kind == "segment":
            _bind_segment(node as Button, key, str(node.get_meta("settings_value", "")))
        elif kind == "toggle":
            _bind_toggle(node as Button, key)
        elif kind == "color":
            _bind_color(node as Button, key, str(node.get_meta("settings_value", "")))


func _bind_slider(slider: HSlider, key: String) -> void:
    if slider == null:
        return
    slider.min_value = float(slider.get_meta("settings_min", slider.min_value))
    slider.max_value = float(slider.get_meta("settings_max", slider.max_value))
    slider.step = float(slider.get_meta("settings_step", slider.step))
    slider.value = clampf(float(_get_setting(key)), slider.min_value, slider.max_value)
    var changed := Callable(self, "_on_setting_slider").bind(key)
    if not slider.value_changed.is_connected(changed):
        slider.value_changed.connect(changed)
    var display := get_node_or_null(str(slider.get_meta("settings_display", ""))) as Label
    if display != null:
        var suffix := str(slider.get_meta("settings_suffix", ""))
        display.text = _format_setting_value(float(slider.value), suffix)
        var display_changed := Callable(self, "_on_setting_slider_display").bind(display, suffix)
        if not slider.value_changed.is_connected(display_changed):
            slider.value_changed.connect(display_changed)


func _bind_segment(button: Button, key: String, value: String) -> void:
    if button == null:
        return
    var active := str(_get_setting(key)) == value
    button.focus_mode = Control.FOCUS_ALL
    button.add_theme_font_size_override("font_size", 10)
    button.add_theme_color_override("font_color", C_BG if active else C_MUTED)
    button.add_theme_stylebox_override("normal", _style_box(C_TEXT if active else C_DARK, C_TEXT if active else C_LINE, 1))
    button.add_theme_stylebox_override("hover", _style_box(C_HOVER if active else Color(1, 1, 1, 0.06), C_HOVER, 1))
    var callback := Callable(self, "_on_setting_choice").bind(key, value)
    if not button.pressed.is_connected(callback):
        button.pressed.connect(callback)


func _bind_toggle(button: Button, key: String) -> void:
    if button == null:
        return
    var value := bool(_get_setting(key))
    button.focus_mode = Control.FOCUS_ALL
    button.add_theme_font_size_override("font_size", 1)
    button.add_theme_color_override("font_color", Color.TRANSPARENT)
    button.add_theme_stylebox_override("normal", _style_box(Color.TRANSPARENT, C_TEXT if value else C_LINE, 1))
    button.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.04), C_HOVER, 1))
    var state_label := get_node_or_null(str(button.get_meta("settings_state", ""))) as Label
    if state_label != null:
        state_label.text = "ON" if value else "OFF"
    var indicator := get_node_or_null(str(button.get_meta("settings_indicator", ""))) as ColorRect
    if indicator != null:
        indicator.visible = value
    var callback := Callable(self, "_on_setting_toggle").bind(key)
    if not button.pressed.is_connected(callback):
        button.pressed.connect(callback)


func _bind_color(button: Button, key: String, value: String) -> void:
    if button == null:
        return
    var active := str(_get_setting(key)) == value
    var swatch := _crosshair_color(value)
    button.focus_mode = Control.FOCUS_ALL
    button.add_theme_font_size_override("font_size", 1)
    button.add_theme_color_override("font_color", Color.TRANSPARENT)
    button.add_theme_stylebox_override("normal", _style_box(swatch, C_TEXT if active else Color.TRANSPARENT, 2 if active else 0))
    button.add_theme_stylebox_override("hover", _style_box(swatch, C_HOVER, 2))
    var callback := Callable(self, "_on_setting_choice").bind(key, value)
    if not button.pressed.is_connected(callback):
        button.pressed.connect(callback)


func _apply_section_state() -> void:
    var selected := str(_state_value("utility_settings_section", "hud"))
    for node in get_children():
        var section := str(node.get_meta("settings_section", ""))
        if section in SETTINGS_SECTIONS:
            node.visible = section == selected
    var selected_header := get_node_or_null("HudSectionHeaderTitle") as Label
    if selected == "gameplay":
        selected_header = get_node_or_null("GameplaySectionHeaderTitle") as Label
    elif selected == "video":
        selected_header = get_node_or_null("VideoSectionHeaderTitle") as Label
    elif selected == "audio":
        selected_header = get_node_or_null("AudioSectionHeaderTitle") as Label
    if selected_header != null:
        selected_header.visible = true


func _bind_preview() -> void:
    _wire_button(get_node_or_null("PreviewApply") as Button, Callable(self, "_settings_apply"))
    _wire_button(get_node_or_null("PreviewRevert") as Button, Callable(self, "_settings_revert"))
    _wire_button(get_node_or_null("PreviewDefaults") as Button, Callable(self, "_settings_defaults"))
    var apply := get_node_or_null("PreviewApply") as Button
    if apply != null:
        apply.add_theme_color_override("font_color", C_MUTED)
        apply.add_theme_stylebox_override("normal", _style_box(Color.TRANSPARENT, C_TEXT, 1))
    for node in get_children():
        if not node.has_meta("settings_preset"):
            continue
        var preset_button := node as Button
        if preset_button == null:
            continue
        var preset := str(preset_button.get_meta("settings_preset", ""))
        _wire_button(preset_button, Callable(self, "_apply_preset").bind(preset))
        var selected := preset == str(_state_value("utility_settings_preset", "DEFAULT"))
        preset_button.add_theme_stylebox_override("normal", _style_box(Color(1, 1, 1, 0.04) if selected else Color.TRANSPARENT, C_TEXT if selected else C_SUBTLE, 1))
        preset_button.add_theme_stylebox_override("hover", _style_box(Color(1, 1, 1, 0.06), C_TEXT, 1))
        var title := get_node_or_null(str(preset_button.get_meta("settings_preset_title", ""))) as Label
        if title != null:
            title.add_theme_color_override("font_color", C_TEXT if selected else C_SOFT)


func _apply_preview_state() -> void:
    var shape := str(_get_setting("hud_crosshair_shape"))
    var color := _crosshair_color(str(_get_setting("hud_crosshair_color")))
    for node in find_children("*", "Control", true, false):
        var variant := str(node.get_meta("settings_crosshair_variant", ""))
        if variant.is_empty():
            continue
        node.visible = variant == shape
        if variant == "CROSS" and shape not in ["CROSS", "OPEN", "DOT", "PIXEL", "RING"]:
            node.visible = true
        if variant == "CROSS_COLOR" or variant == "OPEN_COLOR" or variant == "DOT_COLOR" or variant == "PIXEL_COLOR":
            node.visible = variant == shape + "_COLOR"
            if variant == "CROSS_COLOR" and shape not in ["OPEN", "DOT", "PIXEL", "RING"]:
                node.visible = true
            if variant == "OPEN_COLOR":
                node.visible = shape == "OPEN"
            if variant == "DOT_COLOR":
                node.visible = shape == "DOT"
            if variant == "PIXEL_COLOR":
                node.visible = shape == "PIXEL"
            if node is ColorRect:
                (node as ColorRect).color = color
        elif node is ColorRect and (variant == "CROSS" or variant == "OPEN" or variant == "DOT" or variant == "PIXEL"):
            (node as ColorRect).color = CROSSHAIR_DARK
    var ring_outer := get_node_or_null("PreviewCrosshairRingOuter") as Panel
    var ring_inner := get_node_or_null("PreviewCrosshairRingInner") as Panel
    if ring_outer != null:
        ring_outer.visible = shape == "RING"
        ring_outer.add_theme_stylebox_override("panel", _style_box(Color.TRANSPARENT, CROSSHAIR_DARK, 3))
    if ring_inner != null:
        ring_inner.visible = shape == "RING"
        ring_inner.add_theme_stylebox_override("panel", _style_box(Color.TRANSPARENT, color, 2))


var _offline_settings_generation: int = -1

func _build_offline_settings() -> void:
    reset_adaptive_layout()
    route = "settings"
    _configure_static_styles()
    _bind_chrome()
    for node: Node in get_children():
        var section := str(node.get_meta("settings_section", ""))
        if section in SETTINGS_SECTIONS:
            node.visible = section == "audio"
    for node: Node in find_children("*", "Button", true, false):
        if node.has_meta("settings_kind") or node.has_meta("settings_category"):
            node.disabled = true
            node.tooltip_text = "Unavailable before raid integration"
    for node: Node in find_children("*", "HSlider", true, false):
        node.editable = false
        node.tooltip_text = "Unavailable before raid integration"
    for name: String in ["PreviewApply", "PreviewRevert"]:
        var button := get_node_or_null(name) as Button
        if button != null:
            button.disabled = true
    var status := app.offline_bunker().local_status()
    _offline_settings_generation = int(status.generation)
    var volume: HSlider = null
    for node: Node in find_children("*", "HSlider", true, false):
        if str(node.get_meta("settings_key", "")) == "audio_master":
            volume = node
    if volume != null:
        volume.min_value = 0
        volume.max_value = 100
        volume.step = 1
        volume.set_value_no_signal(int(status.get("master_volume", 80)))
        volume.editable = bool(status.open)
        volume.tooltip_text = "Master volume · saved on this local profile" if status.open else "Open your local profile first"
        if not volume.value_changed.is_connected(_offline_volume_changed):
            volume.value_changed.connect(_offline_volume_changed)
    var chrome := get_node_or_null("NavigationChrome") as ZNavigationChrome
    if chrome != null:
        chrome.show()
        chrome.layout_for(Vector2(1920, 1080))
    var controls := get_node_or_null("OfflineSettingsNotice") as Label
    if controls == null:
        controls = U.label(self, "Offline settings · master volume saves with this profile. Other gameplay settings are unavailable.", Rect2(380, 948, 1130, 28), 12, U.SOFT)
        controls.name = "OfflineSettingsNotice"
    var bindings := get_node_or_null("OfflineControlBindings") as Button
    if bindings == null:
        bindings = Button.new()
        bindings.name = "OfflineControlBindings"
        bindings.text = "KEYBOARD / CONTROLLER BINDINGS"
        bindings.position = Vector2(1550, 930)
        bindings.size = Vector2(322, 42)
        bindings.pressed.connect(_offline_open_controls)
        add_child(bindings)
    default_focus = get_path_to(bindings)
    queue_adaptive_layout()

func _offline_volume_changed(value: float) -> void:
    var offline := app.offline_bunker()
    if offline == null or not accepts_input():
        return
    if not offline.request(&"volume", _offline_settings_generation, int(value)):
        for node: Node in find_children("*", "HSlider", true, false):
            if str(node.get_meta("settings_key", "")) == "audio_master":
                node.set_value_no_signal(int(offline.local_status().master_volume))
        toast("Volume was not saved · " + String(offline.local_status().error))

func _offline_open_controls() -> void:
    if accepts_input():
        go("controls")
