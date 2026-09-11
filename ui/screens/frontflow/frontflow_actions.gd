extends ZScreen

## Front-flow screens: title, launch menu, world saves, friend join, deployment,
## and pause.  The scene wrappers all use this script; the active route is read
## from the app so navigation remains owned by the main UI host.

const CLEAR: Color = Color(0.0, 0.0, 0.0, 0.0)
const BLACK_GLASS: Color = Color(0.027, 0.035, 0.035, 0.90)
const SOFT_GLASS: Color = Color(0.027, 0.035, 0.035, 0.72)
const A = preload("res://ui/core/adaptive.gd")

var active_route: String = ""
var selected_world: int = 0
var world_name_field: LineEdit
var world_seed_field: LineEdit
var friend_code_field: LineEdit
var friend_code_error: Label
var deploy_bar: ProgressBar
var deploy_value_label: Label
var deploy_phase_label: Label
var menu_entries: Array[Button] = []


func _install_authored_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control := node as Control
		var style_names: Array[StringName] = []
		if control is Panel:
			style_names = [&"panel"]
		elif control is Button:
			style_names = [&"normal", &"hover", &"pressed", &"focus", &"disabled"]
		elif control is LineEdit:
			style_names = [&"normal", &"focus", &"read_only"]
		for style_name in style_names:
			if not control.has_theme_stylebox_override(style_name):
				continue
			var style := control.get_theme_stylebox(style_name)
			if style is StyleBoxFlat:
				control.add_theme_stylebox_override(style_name, U.scale_safe(style))


func _compact_section(section: String) -> void:
	app.fixture_set("frontflow_compact_" + active_route, section)
	go(active_route)


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


func _copy_button(parent: Control, button_text: String, rect: Rect2, callback: Callable, primary: bool = false) -> Button:
	var button: Button = btn(parent, button_text, rect, callback, primary)
	_button_style(button, primary)
	return button


func _hit_button(parent: Control, rect: Rect2, callback: Callable) -> Button:
	var hit: Button = _copy_button(parent, "", rect, callback, false)
	hit.flat = true
	hit.add_theme_stylebox_override("normal", _style_box(CLEAR, CLEAR, 0))
	hit.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.04), U.LINE, 1))
	hit.add_theme_stylebox_override("pressed", _style_box(Color(0.91, 0.59, 0.18, 0.16), U.ACCENT, 1))
	return hit


func _button_label(button: Button, font_size: int = 12, mono: bool = false) -> void:
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_font_override("font", U.tracked_font(mono, not mono, 2 if not mono else 1))


func _rule(parent: Control, x: float, y: float, width: float, color: Color = U.LINE) -> ColorRect:
	var line: ColorRect = rule(parent, x, y, width)
	line.color = color
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _state_string(key: String, fallback: String) -> String:
	var value: Variant = app.fixture_get(key, fallback)
	return str(value)


func _worlds() -> Array[Dictionary]:
	var stored: Variant = app.fixture_get("frontflow_worlds", [])
	if stored is Array:
		var worlds: Array[Dictionary] = []
		for item in stored:
			if item is Dictionary:
				worlds.append(item)
		return worlds
	return []

func _selected_world_data() -> Dictionary:
	var worlds = _worlds()
	if worlds.is_empty(): return {"name": "NO WORLD YET", "bunker": "—", "character": "—", "playtime": "—", "last": "never", "difficulty": "STANDARD"}
	return worlds[clampi(int(app.fixture_get("frontflow_selected_world", 0)), 0, worlds.size() - 1)]

func _advance_deploy() -> void:
	if deploy_bar == null:
		return
	var progress: float = float(app.fixture_get("frontflow_deploy_percent", 68.0)) + 8.0
	if progress >= 100.0:
		progress = 100.0
	deploy_bar.value = progress
	deploy_value_label.text = "%d%%" % int(progress)
	app.fixture_set("frontflow_deploy_percent", progress)
	if progress < 80.0:
		deploy_phase_label.text = "MATCHING SQUAD   ›   LOADING ZONE   ›   SPAWNING"
	elif progress < 96.0:
		deploy_phase_label.text = "MATCHING SQUAD   ✓   LOADING ZONE   ›   SPAWNING"
	else:
		deploy_phase_label.text = "MATCHING SQUAD   ✓   LOADING ZONE   ✓   SPAWNING"
	if progress >= 100.0:
		app.fixture_set("frontflow_deploy_percent", 0.0)
		go("hud")


func _back_to_menu() -> void:
	go("main_menu")


func _continue_world() -> void:
	if _worlds().is_empty() and (get_viewport_rect().size.x < 1920 or get_viewport_rect().size.y < 1080):
		app.fixture_set("frontflow_compact_saves", "new")
	go("saves" if _worlds().is_empty() else "session")


func _open_saves() -> void:
	app.fixture_set("frontflow_save_tab", "worlds")
	app.fixture_set("frontflow_compact_saves", "worlds")
	go("saves")


func _open_join_friend() -> void:
	app.fixture_set("frontflow_join_mode", "friends")
	app.fixture_set("frontflow_compact_join_friend", "friends")
	go("join_friend")


func _open_join_code() -> void:
	app.fixture_set("frontflow_join_mode", "code")
	app.fixture_set("frontflow_compact_join_friend", "friends")
	go("join_friend")


func _open_settings() -> void:
	go("settings")


func _open_controls() -> void:
	go("controls")


func _open_extras() -> void:
	toast("EXTRAS · PATCH NOTES AND CREDITS ARE LOCAL MOCK CONTENT")


func _switch_account() -> void:
	toast("ACCOUNT SWITCHING IS DISABLED IN THE UI PROTOTYPE")


func _quit_to_desktop() -> void:
	toast("QUIT TO DESKTOP · SAVED LOCALLY FOR THE PROTOTYPE")


func _join_kevin() -> void:
	app.fixture_set("frontflow_joined_friend", "KEVIN_J")
	toast("JOINING KEV'S HOLE · SESSION READY")
	go("session")


func _request_denz() -> void:
	app.fixture_set("frontflow_denz_requested", true)
	toast("REQUEST SENT TO DENZ · INVITE ONLY")

func _join_denz() -> void:
	app.fixture_set("frontflow_join_mode", "friend")
	app.fixture_set("frontflow_join_host", "DENZ")
	go("session")


func _decline_invite() -> void:
	toast("INVITE DECLINED")


func _message_friend() -> void:
	toast("MESSAGE COMPOSER IS A LOCAL MOCK")


func _friend_filter() -> void:
	toast("FRIEND FILTER UPDATED")


func _submit_friend_code_from_field() -> void:
	_submit_friend_code(friend_code_field.text if not friend_code_field == null else "")


func _submit_friend_code(code: String) -> void:
	var normalized: String = code.strip_edges().to_upper()
	var pattern = RegEx.new()
	pattern.compile("^ZK-[A-Z0-9]{2,8}(-[A-Z0-9]{2,8})?$")
	var valid: bool = pattern.search(normalized) != null
	if not valid:
		if friend_code_field != null:
			friend_code_field.add_theme_color_override("font_color", U.RED)
		if friend_code_error != null:
			friend_code_error.text = "INVALID WORLD CODE · USE ZK-XXXX"
		toast("INVALID WORLD CODE · USE ZK-XXXX")
		return
	if friend_code_field != null:
		friend_code_field.add_theme_color_override("font_color", U.TEXT)
	if friend_code_error != null:
		friend_code_error.text = ""
	app.fixture_set("frontflow_join_code", normalized)
	app.fixture_set("frontflow_join_mode", "code")
	toast("WORLD CODE ACCEPTED · JOINING %s" % normalized)
	go("session")


func _select_world(index: int) -> void:
	selected_world = index
	app.fixture_set("frontflow_selected_world", index)
	go("saves")


func _new_world_hint() -> void:
	if get_viewport_rect().size.x < 1920 or get_viewport_rect().size.y < 1080:
		_compact_section("new")
		return
	world_name_field.grab_focus()
	world_name_field.select_all()


func _load_selected_world() -> void:
	if _worlds().is_empty():
		_new_world_hint()
		return
	app.fixture_set("frontflow_selected_world", selected_world)
	toast("LOADING %s" % str(_worlds()[selected_world].get("name", "WORLD")))
	go("session")


func _rename_world() -> void:
	var worlds = _worlds()
	if worlds.is_empty(): return
	app.prompt("RENAME WORLD", str(worlds[selected_world].name), func(value: String):
		if value.is_empty():
			toast("WORLD NAME REQUIRED")
			return
		worlds[selected_world].name = value.to_upper()
		app.fixture_set("frontflow_worlds", worlds)
		go("saves"))


func _duplicate_world() -> void:
	var worlds = _worlds()
	if worlds.is_empty() or worlds.size() >= 8: return
	var copy: Dictionary = worlds[selected_world].duplicate(true)
	copy.name = str(copy.name).left(17) + " (COPY)"
	copy.last = "just now"
	worlds.append(copy)
	app.fixture_set("frontflow_worlds", worlds)
	app.fixture_set("frontflow_selected_world", worlds.size() - 1)
	go("saves")
	toast("WORLD DUPLICATED")


func _delete_world() -> void:
	app.confirm("DELETE WORLD", "Delete this local world slot? This mock action cannot be undone.", Callable(self, "_delete_world_confirmed"))


func _delete_world_confirmed() -> void:
	var worlds: Array[Dictionary] = _worlds()
	if worlds.is_empty():
		return
	worlds.remove_at(clampi(selected_world, 0, worlds.size() - 1))
	app.fixture_set("frontflow_worlds", worlds)
	selected_world = 0
	app.fixture_set("frontflow_selected_world", 0)
	toast("WORLD SLOT DELETED")
	go("saves")


func _world_name_changed(value: String) -> void:
	app.fixture_set("frontflow_new_world_name", value)


func _world_seed_changed(value: String) -> void:
	app.fixture_set("frontflow_new_seed", value)


func _set_world_choice(key: String, value: String) -> void:
	app.fixture_set("frontflow_new_%s" % key, value)
	go("saves")


func _create_world_pressed() -> void:
	if _worlds().size() >= 8:
		toast("ALL 8 WORLD SLOTS ARE IN USE")
		return
	var name: String = world_name_field.text.strip_edges() if not world_name_field == null else ""
	if name.is_empty():
		toast("WORLD NAME REQUIRED")
		return
	app.confirm("CREATE NEW WORLD", "Create %s and enter its bunker?" % name.to_upper(), Callable(self, "_create_world_confirmed").bind(name))


func _create_world_confirmed(name: String) -> void:
	var worlds: Array[Dictionary] = _worlds()
	var created: Dictionary = {
		"name": name.to_upper(),
		"difficulty": _state_string("frontflow_new_difficulty", "STANDARD"),
		"bunker": "LVL 1",
		"character": "LVL 1",
		"playtime": "0 h",
		"last": "now",
		"cloud": "pending upload",
		"privacy": _state_string("frontflow_new_join_mode", "INVITE ONLY"),
		"max_players": int(_state_string("frontflow_new_max_players", "4")),
		"seed": _state_string("frontflow_new_seed", "ZK-4A91-KX")
	}
	worlds.append(created)
	app.fixture_set("frontflow_worlds", worlds)
	app.fixture_set("frontflow_selected_world", worlds.size() - 1)
	toast("WORLD CREATED · ENTERING BUNKER")
	go("session")


func layout_compact(view: Vector2) -> void:
	preload("res://ui/screens/frontflow/components/frontflow_layout.gd").new(self).apply(view)
