extends "res://ui/screens/utilities/utility_actions.gd"

## Controller for the authored crosshair preview.
##
## The complete preview hierarchy is serialized in crosshairs.tscn. Runtime
## state only selects styles, primitive geometry, and the actions attached to
## the existing controls.

const DESIGN_SIZE := Vector2(1920.0, 1080.0)
const OPTION_SHAPES := ["DOT", "CROSS", "OPEN", "RING", "RETICLE", "PIXEL"]
const OPTION_PREFIXES := ["Option0", "Option1", "Option2", "Option3", "Option4", "Option5"]
const STATE_PREFIXES := ["State0", "State1", "State2", "State3", "State4", "State5"]
const STATE_NAMES := ["IDLE", "MOVING / FIRING", "ON ENEMY", "HIT", "ON SQUADMATE", "ON CONTAINER"]
const STATE_COLOR_NAMES := ["WHITE", "WHITE", "RED", "WHITE", "GREEN", "YELLOW"]
const PRIMITIVE_ROLES := [
	"DarkTop", "DarkBottom", "DarkLeft", "DarkRight",
	"ColorTop", "ColorBottom", "ColorLeft", "ColorRight",
	"DarkDot", "ColorDot", "DarkPixel", "ColorPixel",
	"RingDark", "RingColor", "ColorCenter"
]


func build() -> void:
	route = _screen_route()
	reset_adaptive_layout()
	_install_scale_safe_styles()
	_bind_dynamic_state()
	_wire_actions()
	_refresh_crosshairs()
	_set_display_mode(_is_compact_view())
	queue_adaptive_layout()


func _bind_dynamic_state() -> void:
	var back := _static_node("BackButton") as Button
	if back != null:
		back.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for prefix in OPTION_PREFIXES:
		var hit := _static_node(prefix + "Hit") as Button
		if hit != null:
			hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _wire_actions() -> void:
	_wire_button(_static_node("BackButton") as Button, Callable(self, "_go_settings"))
	for index in range(OPTION_SHAPES.size()):
		var hit := _static_node(OPTION_PREFIXES[index] + "Hit") as Button
		_wire_button(hit, Callable(self, "_select_crosshair").bind(OPTION_SHAPES[index]))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _go_settings() -> void:
	_go("settings")


func _select_crosshair(shape: String) -> void:
	_set_setting("hud_crosshair_shape", shape)
	_toast(shape + " crosshair selected")
	_refresh_crosshairs()


func _rerender() -> void:
	_refresh_crosshairs()


func _refresh_crosshairs() -> void:
	var selected := str(_get_setting("hud_crosshair_shape"))
	var selected_color := _crosshair_color(str(_get_setting("hud_crosshair_color")))
	for index in range(OPTION_SHAPES.size()):
		var prefix: String = OPTION_PREFIXES[index]
		var panel := _static_node(prefix + "Panel") as Panel
		if panel == null:
			continue
		_set_panel_border(panel, C_TEXT if selected == OPTION_SHAPES[index] else C_LINE)
		_set_tile(prefix, panel.position + Vector2(55, 55), OPTION_SHAPES[index], selected_color, "IDLE", 1.0)

	var states_title := _static_node("StatesTitle") as Label
	if states_title != null:
		states_title.text = "STATES · " + selected
	for index in range(STATE_NAMES.size()):
		var prefix: String = STATE_PREFIXES[index]
		var panel := _static_node(prefix + "Panel") as Panel
		if panel == null:
			continue
		_set_tile(prefix, panel.position + Vector2(55, 52), selected, _crosshair_color(STATE_COLOR_NAMES[index]), STATE_NAMES[index], 0.92)


func _set_tile(prefix: String, center: Vector2, shape: String, color: Color, state: String, scale_value: float) -> void:
	for role in PRIMITIVE_ROLES:
		var hidden := _static_node(prefix + "_" + role) as Control
		if hidden != null:
			hidden.visible = false
	_draw_crosshair_static(prefix, center, shape, color, state, scale_value)


func _draw_crosshair_static(prefix: String, center: Vector2, shape: String, color: Color, state: String, scale_value: float) -> void:
	var dark := Color(0, 0, 0, 0.76)
	var size := 30.0 * scale_value
	var arm := 10.0 * scale_value
	var stroke := maxf(2.0, 2.0 * scale_value)
	var gap := 5.0 * scale_value
	if state == "MOVING / FIRING":
		gap += 6.0 * scale_value
	if shape == "DOT":
		_set_rect(prefix + "_DarkDot", Rect2(center.x - 2.0, center.y - 2.0, 4.0, 4.0), dark)
		_set_rect(prefix + "_ColorDot", Rect2(center.x - 1.0, center.y - 1.0, 2.0, 2.0), color)
	elif shape == "PIXEL":
		_set_rect(prefix + "_DarkPixel", Rect2(center.x - 5.0, center.y - 5.0, 10.0, 10.0), dark)
		_set_rect(prefix + "_ColorPixel", Rect2(center.x - 3.0, center.y - 3.0, 6.0, 6.0), color)
	elif shape == "RING":
		_set_ring(prefix + "_RingDark", Rect2(center.x - 15.0, center.y - 15.0, 30.0, 30.0), dark, 3)
		_set_ring(prefix + "_RingColor", Rect2(center.x - 12.0, center.y - 12.0, 24.0, 24.0), color, 2)
	else:
		if shape == "OPEN":
			_set_rect(prefix + "_DarkTop", Rect2(center.x - stroke / 2.0, center.y - size, stroke, arm), dark)
			_set_rect(prefix + "_DarkBottom", Rect2(center.x - stroke / 2.0, center.y + gap, stroke, arm), dark)
			_set_rect(prefix + "_DarkLeft", Rect2(center.x - size, center.y - stroke / 2.0, arm, stroke), dark)
			_set_rect(prefix + "_DarkRight", Rect2(center.x + gap, center.y - stroke / 2.0, arm, stroke), dark)
			_set_rect(prefix + "_ColorTop", Rect2(center.x - stroke / 2.0, center.y - size + stroke, stroke, arm - stroke), color)
			_set_rect(prefix + "_ColorBottom", Rect2(center.x - stroke / 2.0, center.y + gap, stroke, arm - stroke), color)
			_set_rect(prefix + "_ColorLeft", Rect2(center.x - size + stroke, center.y - stroke / 2.0, arm - stroke, stroke), color)
			_set_rect(prefix + "_ColorRight", Rect2(center.x + gap, center.y - stroke / 2.0, arm - stroke, stroke), color)
		else:
			var top := gap + (2.0 if shape == "RETICLE" else 0.0)
			_set_rect(prefix + "_DarkTop", Rect2(center.x - stroke / 2.0, center.y - top - arm, stroke, arm), dark)
			_set_rect(prefix + "_DarkBottom", Rect2(center.x - stroke / 2.0, center.y + top, stroke, arm), dark)
			_set_rect(prefix + "_DarkLeft", Rect2(center.x - top - arm, center.y - stroke / 2.0, arm, stroke), dark)
			_set_rect(prefix + "_DarkRight", Rect2(center.x + top, center.y - stroke / 2.0, arm, stroke), dark)
			_set_rect(prefix + "_ColorTop", Rect2(center.x - stroke / 2.0, center.y - top - arm + 1, stroke, arm - 2), color)
			_set_rect(prefix + "_ColorBottom", Rect2(center.x - stroke / 2.0, center.y + top + 1, stroke, arm - 2), color)
			_set_rect(prefix + "_ColorLeft", Rect2(center.x - top - arm + 1, center.y - stroke / 2.0, arm - 2, stroke), color)
			_set_rect(prefix + "_ColorRight", Rect2(center.x + top + 1, center.y - stroke / 2.0, arm - 2, stroke), color)
			if shape == "RETICLE":
				_set_rect(prefix + "_ColorCenter", Rect2(center.x - 2, center.y - 2, 4, 4), color)
			elif shape == "CROSS":
				_set_rect(prefix + "_ColorCenter", Rect2(center.x - 1, center.y - 1, 2, 2), color)


func _set_rect(node_name: String, rect: Rect2, color: Color) -> void:
	var item := _static_node(node_name) as ColorRect
	if item == null:
		return
	item.position = rect.position
	item.size = rect.size
	item.color = color
	item.visible = true


func _set_ring(node_name: String, rect: Rect2, color: Color, width: int) -> void:
	var item := _static_node(node_name) as Panel
	if item == null:
		return
	item.position = rect.position
	item.size = rect.size
	var style := _style_source(item, "panel")
	if style != null:
		style.bg_color = Color(0, 0, 0, 0)
		style.border_color = color
		style.set_border_width_all(width)
		item.add_theme_stylebox_override("panel", U.scale_safe(style))
	item.visible = true


func _set_panel_border(panel: Panel, color: Color) -> void:
	var style := _style_source(panel, "panel")
	if style == null:
		return
	style.border_color = color
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", U.scale_safe(style))


func _style_source(control: Control, style_name: StringName) -> StyleBoxFlat:
	var style: StyleBox = control.get_theme_stylebox(style_name)
	var source: Variant = style.get("source") if style != null else null
	if source is StyleBoxFlat:
		return (source as StyleBoxFlat).duplicate(true) as StyleBoxFlat
	if style is StyleBoxFlat:
		return (style as StyleBoxFlat).duplicate(true) as StyleBoxFlat
	return null


func _static_node(node_name: String) -> Node:
	return find_child(node_name, true, false)


func _is_compact_view() -> bool:
	var view: Vector2 = get_viewport_rect().size
	return view.x < DESIGN_SIZE.x or view.y < DESIGN_SIZE.y


func _set_display_mode(compact: bool) -> void:
	var pane := _static_node("CrosshairPane") as ScrollContainer
	if pane != null:
		pane.visible = compact


func layout_compact(view: Vector2) -> void:
	var pane := _static_node("CrosshairPane") as ScrollContainer
	var content := _static_node("Content") as Control
	if pane == null or content == null:
		return
	pane.position = Vector2((view.x - 816) / 2, 80)
	pane.size = Vector2(816, view.y - 104)
	pane.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	pane.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	pane.follow_focus = true
	pane.clip_contents = true
	_style_scrollbars(pane)
	content.custom_minimum_size = Vector2(800, 520)
	content.size = Vector2(800, 520)
	if content.get_child_count() == 0:
		ZAdaptive.move_group(self, "CrosshairPane", Vector2(550, 240), content)
		for child in content.get_children():
			child.position += Vector2(-10, -4)


func _style_scrollbars(scroll: ScrollContainer) -> void:
	var styles: Dictionary = {
		"scroll": scroll.get_meta("scroll_track") as StyleBox,
		"grabber": scroll.get_meta("scroll_grabber") as StyleBox,
		"grabber_highlight": scroll.get_meta("scroll_highlight") as StyleBox,
		"grabber_pressed": scroll.get_meta("scroll_pressed") as StyleBox
	}
	for scrollbar in [scroll.get_v_scroll_bar(), scroll.get_h_scroll_bar()]:
		for style_name in styles:
			var style: StyleBox = styles[style_name]
			if style != null:
				scrollbar.add_theme_stylebox_override(style_name, style)


func _install_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control: Control = node as Control
		if control is Panel:
			_wrap_style_override(control, "panel")
		elif control is Button:
			for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
				_wrap_style_override(control, style_name)


func _wrap_style_override(control: Control, style_name: StringName) -> void:
	if not control.has_theme_stylebox_override(style_name):
		return
	var style: StyleBox = control.get_theme_stylebox(style_name)
	if style is StyleBoxFlat:
		control.add_theme_stylebox_override(style_name, U.scale_safe(style as StyleBoxFlat))
