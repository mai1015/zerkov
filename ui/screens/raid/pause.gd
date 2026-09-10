extends ZScreen

var active_route := "pause"
var menu_entries: Array[Button] = []
const BLACK_GLASS: Color = Color(0.027, 0.035, 0.035, 0.90)
const CLEAR := Color.TRANSPARENT

## Authored pause-screen controller.
##
## The desktop hierarchy lives in pause.tscn. This script keeps the scene
## stateful: privacy reflects the shared bunker state, actions stay connected
## after compact reflow, and the left-hand menu retains keyboard focus order.

func build() -> void:
	reset_adaptive_layout()
	active_route = str(app.current_route)
	menu_entries.clear()
	_install_scale_safe_styles()
	_bind_pause_state()
	_wire_actions()
	_build_focus_graph()
	queue_adaptive_layout()


func _bind_pause_state() -> void:
	var privacy: String = str(app.state.get("bunker_privacy", "INVITE ONLY"))
	_configure_segment(get_node("SessionPanel/Closed") as Button, privacy == "CLOSED")
	_configure_segment(get_node("SessionPanel/Invite") as Button, privacy == "INVITE ONLY")
	_configure_segment(get_node("SessionPanel/Friends") as Button, privacy == "FRIENDS")


func _install_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control := node as Control
		if control is Panel:
			_wrap_style_override(control, "panel")
		elif control is Button:
			for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
				_wrap_style_override(control, style_name)


func _wrap_style_override(control: Control, style_name: StringName) -> void:
	if not control.has_theme_stylebox_override(style_name):
		return
	var style := control.get_theme_stylebox(style_name)
	if style is StyleBoxFlat:
		control.add_theme_stylebox_override(style_name, U.scale_safe(style))


func _configure_segment(button: Button, active: bool, accent: Color = U.TEXT) -> void:
	if button == null:
		return
	_button_style(button, false)
	_button_label(button, 10, false)
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_color_override("font_color", U.CANVAS if active else U.MUTED)
	button.add_theme_stylebox_override("normal", _style_box(accent if active else Color(0.027, 0.035, 0.035, 0.55), U.LINE if not active else accent, 1))
	button.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.08), accent, 1))


func _wire_actions() -> void:
	_wire_button(get_node("ActionsPanel/ResumeRow/Hit") as Button, Callable(self, "_resume_pause"))
	_wire_button(get_node("ActionsPanel/SessionRow/Hit") as Button, Callable(self, "_open_session"))
	_wire_button(get_node("ActionsPanel/CharacterRow/Hit") as Button, Callable(self, "_open_character"))
	_wire_button(get_node("ActionsPanel/MapRow/Hit") as Button, Callable(self, "_open_map"))
	_wire_button(get_node("ActionsPanel/SettingsRow/Hit") as Button, Callable(self, "_open_settings"))
	_wire_button(get_node("ActionsPanel/SaveQuitRow/Hit") as Button, Callable(self, "_save_quit_menu"))
	_wire_button(get_node("ActionsPanel/QuitDesktopRow/Hit") as Button, Callable(self, "_quit_to_desktop"))
	_wire_button(get_node("SessionPanel/Closed") as Button, Callable(self, "_privacy_closed"))
	_wire_button(get_node("SessionPanel/Invite") as Button, Callable(self, "_privacy_invite"))
	_wire_button(get_node("SessionPanel/Friends") as Button, Callable(self, "_privacy_friends"))
	_wire_button(get_node("ControlsButton") as Button, Callable(self, "_open_controls"))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _build_focus_graph() -> void:
	var entries: Array[Button] = [
		get_node("ActionsPanel/ResumeRow/Hit") as Button,
		get_node("ActionsPanel/SessionRow/Hit") as Button,
		get_node("ActionsPanel/CharacterRow/Hit") as Button,
		get_node("ActionsPanel/MapRow/Hit") as Button,
		get_node("ActionsPanel/SettingsRow/Hit") as Button,
		get_node("ActionsPanel/SaveQuitRow/Hit") as Button,
		get_node("ActionsPanel/QuitDesktopRow/Hit") as Button
	]
	menu_entries.assign(entries)
	for index in range(entries.size()):
		entries[index].focus_neighbor_top = entries[index].get_path_to(entries[posmod(index - 1, entries.size())])
		entries[index].focus_neighbor_bottom = entries[index].get_path_to(entries[(index + 1) % entries.size()])
	entries[0].grab_focus()

func _button_style(button: Button, primary: bool = false) -> void:
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", U.TEXT if not primary else U.CANVAS)
	button.add_theme_color_override("font_hover_color", U.CANVAS if primary else U.TEXT)
	button.add_theme_color_override("font_pressed_color", U.CANVAS)
	button.add_theme_color_override("font_focus_color", U.TEXT if not primary else U.CANVAS)
	button.add_theme_color_override("font_disabled_color", U.MUTED)
	var normal: StyleBox = _style_box(U.ACCENT if primary else CLEAR, U.ACCENT if primary else U.LINE, 1)
	var hover: StyleBox = _style_box(U.HOVER if primary else Color(1.0, 1.0, 1.0, 0.07), U.HOVER if primary else U.TEXT, 1)
	var pressed: StyleBox = _style_box(U.HOVER if primary else Color(1.0, 1.0, 1.0, 0.12), U.ACCENT, 1)
	var focus: StyleBox = _style_box(U.ACCENT if primary else Color(1.0, 1.0, 1.0, 0.04), U.ACCENT, 1)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", focus)
	button.add_theme_stylebox_override("disabled", _style_box(Color(0.12, 0.13, 0.12, 0.7), U.BORDER, 1))
	button.add_theme_constant_override("outline_size", 0)



func _button_label(button: Button, font_size: int = 12, mono: bool = false) -> void:
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_font_override("font", U.tracked_font(mono, not mono, 2 if not mono else 1))



func _style_box(fill: Color, border: Color = CLEAR, width: int = 0, left_width: int = -1) -> StyleBox:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	style.corner_radius_top_left = 0
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	if left_width >= 0:
		style.border_width_left = left_width
	return U.scale_safe(style)



func _resume_pause() -> void:
	app.back()



func _open_session() -> void:
	go("session")



func _open_character() -> void:
	go("inventory")



func _open_map() -> void:
	go("maps")



func _open_settings() -> void:
	go("settings")



func _open_controls() -> void:
	go("controls")



func _save_quit_menu() -> void:
	app.confirm("SAVE & QUIT", "Close this world and return to the main menu?", Callable(self, "_save_quit_confirmed"))



func _save_quit_confirmed() -> void:
	toast("WORLD SAVED · RETURNING TO MENU")
	go("main_menu")



func _quit_to_desktop() -> void:
	toast("QUIT TO DESKTOP · SAVED LOCALLY FOR THE PROTOTYPE")



func _privacy_closed() -> void:
	_set_pause_privacy("CLOSED")



func _privacy_invite() -> void:
	_set_pause_privacy("INVITE ONLY")



func _privacy_friends() -> void:
	_set_pause_privacy("FRIENDS")



func _set_pause_privacy(value: String) -> void:
	app.state["bunker_privacy"] = value
	var worlds: Array = app.state.get("frontflow_worlds", [])
	var selected: int = int(app.state.get("frontflow_selected_world", 0))
	if selected >= 0 and selected < worlds.size():
		worlds[selected]["privacy"] = value
	app.navigate("pause", false)
	toast("SESSION PRIVACY · " + value)


func layout_compact(view: Vector2) -> void:
	preload("res://ui/screens/frontflow/components/frontflow_layout.gd").new(self).apply(view)
