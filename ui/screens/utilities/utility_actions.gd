extends ZScreen

## Shared native-Control implementation for the in-raid utility pages.
##
## The approved handoff uses one visual shell for Maps, Tasks, Settings and
## Controls.  Keeping the pages here means local state survives a route change
## without introducing a second UI framework or screenshot-like overlays.

const C_BG := Color("#0a0b0a")
const C_PANEL := Color("#0e100f")
const C_CANVAS := Color("#141414")
const C_DARK := Color(0.027, 0.035, 0.035, 0.86)
const C_TEXT := Color("#E6E8E3")
const C_MUTED := Color("#8B918A")
const C_SOFT := Color("#B7BCB4")
const C_BORDER := Color("#2a2a2a")
const C_LINE := Color(1.0, 1.0, 1.0, 0.12)
const C_SUBTLE := Color(1.0, 1.0, 1.0, 0.08)
const C_ACCENT := Color("#E8962E")
const C_HOVER := Color("#F2B15A")
const C_GREEN := Color("#5FD36B")
const C_RED := Color("#D9483B")
const C_YELLOW := Color("#E9D35A")
const C_BLUE := Color("#4C8DFF")

const SETTINGS_DEFAULTS := {
	"hud_scale": 100.0,
	"hud_opacity": 90.0,
	"hud_idle_fade": "3 S",
	"hud_safe_zone": 56.0,
	"hud_crosshair_shape": "CROSS",
	"hud_crosshair_color": "WHITE",
	"hud_dynamic_spread": true,
	"hud_hit_marker": "ON",
	"hud_health_readout": "BAR",
	"hud_ammo_counter": "EXACT",
	"hud_squad_tags": true,
	"hud_loot_feed": "FULL",
	"hud_tracked_task": true,
	"hud_overhead_reload": true,
	"hud_status_icons": "ICON + LABEL",
	"gameplay_auto_sprint": false,
	"gameplay_hold_crouch": true,
	"gameplay_contextual_lean": true,
	"gameplay_confirm_extract": true,
	"gameplay_show_tips": true,
	"gameplay_pause_on_focus_loss": true,
	"gameplay_sort_mode": "VALUE",
	"gameplay_prompt_style": "FULL",
	"video_display_mode": "BORDERLESS",
	"video_resolution": "1920 × 1080",
	"video_frame_limit": 60.0,
	"video_brightness": 50.0,
	"video_vsync": true,
	"video_pixel_filter": true,
	"video_reduce_flashes": false,
	"audio_master": 80.0,
	"audio_sfx": 85.0,
	"audio_music": 35.0,
	"audio_voice": 75.0,
	"audio_dynamic_range": "FULL",
	"audio_push_to_talk": true,
	"controller_aim_assist": true,
	"controller_deadzone": 8.0,
	"controller_look_sensitivity": 5.0,
	"controller_vibration": true,
	"controller_invert_y": false
}

const Fixture = preload("res://ui/dev/fixtures/utility_fixture.gd")
const ZONES = Fixture.ZONES
const TASKS = Fixture.TASKS
const TRADERS = Fixture.TRADERS
const CONTROL_GROUPS = Fixture.CONTROL_GROUPS
const DEFAULT_BINDINGS = Fixture.DEFAULT_BINDINGS

var route: String = ""
var capture_action: String = ""
var capture_column: String = ""
var _skip_next_input: bool = false
var _compact_scroll: Dictionary = {}


# Authored utility scenes expose their route through scene metadata when a
# controller needs the shared route value during its initial build.
func _screen_route() -> String:
	return str(get_meta("utility_route", ""))


# Route controllers own their state refresh, while shared actions call this
# hook so the inherited state helpers remain available to every utility page.
func _rerender() -> void:
	pass


func _restore_compact_scroll() -> void:
	for node in find_children("*", "ScrollContainer", true, false):
		if _compact_scroll.has(str(node.name)):
			node.scroll_vertical = int(_compact_scroll[str(node.name)])


func _compact_tab(key: String, value: String) -> void:
	_set_state(key, value)
	_rerender()


func _state_value(key: String, fallback: Variant) -> Variant:
	if app == null:
		return fallback
	return app.state.get(key, fallback)


func _set_state(key: String, value: Variant) -> void:
	if app != null:
		app.state[key] = value


func _dictionary_state(key: String) -> Dictionary:
	var result: Dictionary = {}
	if app == null:
		return result
	var raw = app.state.get(key, {})
	if raw is Dictionary:
		result = raw
	else:
		app.state[key] = result
	return result


func _settings_state() -> Dictionary:
	var result: Dictionary = _dictionary_state("utility_settings")
	for key in SETTINGS_DEFAULTS.keys():
		if not result.has(key):
			result[key] = SETTINGS_DEFAULTS[key]
	if app != null:
		app.state["utility_settings"] = result
	return result


func _set_setting(key: String, value: Variant) -> void:
	var settings: Dictionary = _settings_state()
	settings[key] = value
	if app != null:
		app.state["utility_settings"] = settings
		if key.begins_with("hud_"):
			app.state[key] = value
			var hud: Dictionary = _dictionary_state("hud_settings")
			hud[key] = value
			app.state["hud_settings"] = hud


func _get_setting(key: String) -> Variant:
	return _settings_state().get(key, SETTINGS_DEFAULTS.get(key, ""))


func _toast(message: String) -> void:
	if app != null:
		app.toast(message)


func _go(target: String) -> void:
	if app != null:
		app.navigate(target)


func _style_box(fill: Color, border: Color, border_width: int = 1) -> StyleBox:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(border_width)
	style.corner_radius_top_left = 0
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return U.scale_safe(style)


func _solid(parent: Control, rect: Rect2, color: Color) -> ColorRect:
	var item := ColorRect.new()
	item.position = rect.position
	item.size = rect.size
	item.color = color
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(item)
	return item


func _panel(parent: Control, rect: Rect2, fill: Color = C_PANEL, border: Color = C_LINE) -> Panel:
	var item: Panel = box(parent, rect, fill, border)
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item


func _label(parent: Control, value: String, rect: Rect2, size: int = 14, color: Color = C_TEXT, mono: bool = false) -> Label:
	var item: Label = txt(parent, value, rect, size, color, mono)
	item.add_theme_font_override("font", U.font(mono, true))
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item


func _button(parent: Control, value: String, rect: Rect2, callback: Callable, primary: bool = false, danger: bool = false) -> Button:
	var item: Button = btn(parent, value, rect, callback, primary)
	item.focus_mode = Control.FOCUS_ALL
	item.add_theme_font_size_override("font_size", 11)
	item.add_theme_color_override("font_color", C_RED if danger else (C_BG if primary else C_TEXT))
	item.add_theme_color_override("font_hover_color", C_BG if primary else C_HOVER)
	item.add_theme_color_override("font_pressed_color", C_BG)
	item.add_theme_stylebox_override("normal", _style_box(C_ACCENT if primary else C_DARK, C_ACCENT if primary else C_LINE, 1))
	item.add_theme_stylebox_override("hover", _style_box(C_HOVER if primary else Color(1, 1, 1, 0.05), C_HOVER if primary else C_TEXT, 1))
	item.add_theme_stylebox_override("pressed", _style_box(Color(0.75, 0.42, 0.12, 0.35), C_ACCENT, 1))
	item.add_theme_stylebox_override("focus", _style_box(C_ACCENT if primary else Color(1, 1, 1, 0.06), C_ACCENT, 1))
	item.add_theme_stylebox_override("disabled", _style_box(Color(0.04, 0.05, 0.05, 0.45), Color(1, 1, 1, 0.08), 1))
	if danger:
		item.add_theme_color_override("font_color", C_RED)
		item.add_theme_stylebox_override("normal", _style_box(Color(0.15, 0.04, 0.035, 0.20), Color(0.85, 0.20, 0.16, 0.65), 1))
		item.add_theme_stylebox_override("hover", _style_box(Color(0.25, 0.08, 0.06, 0.28), C_RED, 1))
	return item


func _style_slider(slider: HSlider) -> void:
	# The handoff uses a 3px white progress track and a narrow rectangular
	# grabber.  Godot's default HSlider theme is deliberately orange and
	# circular, so keep the native control but replace only its primitives.
	var track := StyleBoxLine.new()
	track.color = Color(1, 1, 1, 0.12)
	track.thickness = 3
	track.grow_begin = 0.0
	track.grow_end = 0.0
	var filled := StyleBoxLine.new()
	filled.color = C_TEXT
	filled.thickness = 3
	filled.grow_begin = 0.0
	filled.grow_end = 0.0
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([C_TEXT, C_TEXT])
	var grabber := GradientTexture2D.new()
	grabber.gradient = gradient
	grabber.width = 3
	grabber.height = 13
	grabber.fill_from = Vector2(0.0, 0.0)
	grabber.fill_to = Vector2(1.0, 0.0)
	slider.add_theme_icon_override("grabber", grabber)
	slider.add_theme_icon_override("grabber_highlight", grabber)


func _value_color(name: String) -> Color:
	match name:
		"green": return C_GREEN
		"yellow": return C_YELLOW
		"red": return C_RED
		"blue": return C_BLUE
		"accent": return C_ACCENT
		_: return C_MUTED


func _select_settings_section(section: String) -> void:
	if section == "controls":
		_go("controls")
		return
	if section == "accessibility" or section == "account":
		_toast(section.to_upper() + " options are reserved for the prototype build")
		return
	_set_state("utility_settings_section", section)
	_rerender()


func _on_settings_search(value: String) -> void:
	_set_state("utility_settings_search", value)


func _on_setting_slider(value: float, key: String) -> void:
	_set_setting(key, value)


func _on_setting_slider_display(value: float, display: Label, suffix: String) -> void:
	display.text = _format_setting_value(value, suffix)


func _format_setting_value(value: float, suffix: String) -> String:
	var text_value := str(int(round(value)))
	return text_value + suffix


func _on_setting_choice(key: String, value: String) -> void:
	_set_setting(key, value)
	_rerender()


func _on_setting_toggle(key: String) -> void:
	_set_setting(key, not bool(_get_setting(key)))
	_rerender()


func _apply_preset(preset: String) -> void:
	var settings: Dictionary = _settings_state()
	if preset == "DEFAULT":
		for key in SETTINGS_DEFAULTS.keys():
			settings[key] = SETTINGS_DEFAULTS[key]
	elif preset == "MINIMAL":
		settings["hud_loot_feed"] = "OFF"
		settings["hud_ammo_counter"] = "ROUGH"
		settings["hud_health_readout"] = "BAR"
		settings["hud_idle_fade"] = "3 S"
		settings["hud_crosshair_shape"] = "CROSS"
	elif preset == "COMPETITIVE":
		settings["hud_idle_fade"] = "OFF"
		settings["hud_ammo_counter"] = "EXACT"
		settings["hud_crosshair_shape"] = "DOT"
		settings["hud_hit_marker"] = "KILL ONLY"
	for key in settings.keys():
		if str(key).begins_with("hud_"):
			_set_setting(str(key), settings[key])
	_set_state("utility_settings_preset", preset)
	_toast(preset + " preset loaded")
	_rerender()


func _settings_apply() -> void:
	_set_state("utility_settings_applied", true)
	_toast("Graphics preview applied")


func _settings_revert() -> void:
	var section := str(_state_value("utility_settings_section", "hud"))
	var settings: Dictionary = _settings_state()
	var prefix := section + "_"
	if section == "video":
		prefix = "video_"
	if section == "hud":
		prefix = "hud_"
	for key in SETTINGS_DEFAULTS.keys():
		if str(key).begins_with(prefix):
			settings[key] = SETTINGS_DEFAULTS[key]
			_set_setting(str(key), SETTINGS_DEFAULTS[key])
	_toast(section.to_upper() + " settings reverted")
	_rerender()


func _settings_defaults() -> void:
	var settings: Dictionary = _settings_state()
	for key in SETTINGS_DEFAULTS.keys():
		settings[key] = SETTINGS_DEFAULTS[key]
		if str(key).begins_with("hud_"):
			_set_setting(str(key), SETTINGS_DEFAULTS[key])
	_set_state("utility_settings_preset", "DEFAULT")
	_toast("All settings restored to defaults")
	_rerender()


func _map_zone_index() -> int:
	var result := int(_state_value("utility_map_zone", 0))
	return clampi(result, 0, ZONES.size() - 1)


func _map_zone_color(zone: Dictionary) -> Color:
	return _value_color(str(zone.get("risk_color", "muted")))


func _select_map_zone(index: int) -> void:
	_set_state("utility_map_zone", index)
	_set_state("utility_map_marker", "zone")
	_rerender()


func _map_zoom(delta: int) -> void:
	var value := clampi(int(_state_value("utility_map_zoom", 100)) + delta, 60, 160)
	_set_state("utility_map_zoom", value)
	_toast("Region zoom " + str(value) + "%")
	_rerender()


func _select_map_marker(kind: String, index: int) -> void:
	_set_state("utility_map_marker", kind + ":" + str(index))
	_toast(kind.to_upper() + " marker selected")
	_rerender()


func _set_map_time(value: String) -> void:
	_set_state("utility_map_time", value)
	_rerender()


func _select_map_task(task_id: String) -> void:
	_set_state("utility_map_task", task_id)
	_set_state("hud_tracked_task_id", task_id)
	_toast("Tracking " + task_id.replace("_", " ").capitalize())
	_rerender()


func _deploy_zone(zone_index: int) -> void:
	_set_state("utility_last_deploy_zone", zone_index)
	_toast("Deployment staged · local prototype only")
	_go("deploying")


func _task_record(task_id: String) -> Dictionary:
	for task_variant in TASKS:
		var task: Dictionary = task_variant
		if str(task.get("id", "")) == task_id:
			return task
	return {}


func _task_progress(task_id: String, objective_index: int, task: Dictionary) -> int:
	var progress: Dictionary = _dictionary_state("utility_task_progress")
	var raw = progress.get(task_id, [])
	var row: Array = raw if raw is Array else []
	var objectives: Array = task.get("objectives", [])
	if row.size() != objectives.size():
		row.clear()
		for objective_variant in objectives:
			var objective: Dictionary = objective_variant
			row.append(int(objective.get("current", 0)))
		progress[task_id] = row
	return int(row[objective_index])


func _set_task_progress(task_id: String, objective_index: int, task: Dictionary) -> void:
	var progress: Dictionary = _dictionary_state("utility_task_progress")
	var raw = progress.get(task_id, [])
	var row: Array = raw if raw is Array else []
	var objectives: Array = task.get("objectives", [])
	if row.size() != objectives.size():
		row.clear()
		for objective_variant in objectives:
			var objective: Dictionary = objective_variant
			row.append(int(objective.get("current", 0)))
	var objective: Dictionary = objectives[objective_index]
	row[objective_index] = mini(int(objective.get("target", 1)), int(row[objective_index]) + 1)
	progress[task_id] = row
	_set_state("utility_task_progress", progress)


func _task_complete(task: Dictionary) -> bool:
	var objectives: Array = task.get("objectives", [])
	for index in range(objectives.size()):
		var objective: Dictionary = objectives[index]
		if _task_progress(str(task.get("id", "")), index, task) < int(objective.get("target", 1)):
			return false
	return true


func _task_list_for_tab(tab: String) -> Array:
	var result: Array = []
	for task_variant in TASKS:
		var task: Dictionary = task_variant
		if tab == "all" or str(task.get("status", "")) == tab:
			result.append(task)
	return result


func _task_tab() -> String:
	var tab := str(_state_value("utility_task_tab", "active"))
	if tab != "active" and tab != "available" and tab != "completed":
		tab = "active"
	return tab


func _selected_task_id(tab: String) -> String:
	var stored := str(_state_value("utility_task_selected", "supply_run"))
	var selected := _task_record(stored)
	if not selected.is_empty() and (tab == "all" or str(selected.get("status", "")) == tab):
		return stored
	var records := _task_list_for_tab(tab)
	if records.is_empty():
		return ""
	return str(records[0].get("id", ""))


func _select_trader(index: int) -> void:
	_set_state("utility_task_trader", index)
	_rerender()


func _select_task_tab(tab: String) -> void:
	_set_state("utility_task_tab", tab)
	var records := _task_list_for_tab(tab)
	if not records.is_empty():
		_set_state("utility_task_selected", records[0].get("id", ""))
	_rerender()


func _task_tag_color(task: Dictionary) -> Color:
	return _value_color(str(task.get("tag_color", "muted")))


func _select_task(task_id: String) -> void:
	_set_state("utility_task_selected", task_id)
	_rerender()


func _advance_objective(task_id: String, objective_index: int) -> void:
	var task := _task_record(task_id)
	if task.is_empty():
		return
	_set_task_progress(task_id, objective_index, task)
	_toast("Objective progress updated")
	_rerender()


func _toggle_task_tracking(task_id: String) -> void:
	var current := str(_state_value("hud_tracked_task_id", "supply_run"))
	_set_state("hud_tracked_task_id", "" if current == task_id else task_id)
	_set_setting("hud_tracked_task", current != task_id)
	_rerender()


func _turn_in_task(task_id: String) -> void:
	var task := _task_record(task_id)
	if task.is_empty() or not _task_complete(task):
		_toast("Complete every objective before turning in")
		return
	var completed: Dictionary = _dictionary_state("utility_tasks_completed")
	completed[task_id] = true
	_set_state("utility_tasks_completed", completed)
	_toast(str(task.get("title", "TASK")) + " turned in · rewards banked")
	_rerender()


func _abandon_task(task_id: String) -> void:
	if app != null and app.has_method("confirm"):
		app.confirm("ABANDON TASK", "This local prototype action cannot be undone.", Callable(self, "_confirm_abandon").bind(task_id))
	else:
		_confirm_abandon(task_id)


func _confirm_abandon(task_id: String) -> void:
	_set_state("utility_task_abandoned", task_id)
	_toast("Task abandoned in local state")
	_rerender()


func _bindings_state() -> Dictionary:
	var bindings: Dictionary = _dictionary_state("utility_bindings")
	for key in DEFAULT_BINDINGS.keys():
		if not bindings.has(key):
			var defaults: Dictionary = DEFAULT_BINDINGS[key]
			bindings[key] = defaults.duplicate(true)
	if app != null:
		app.state["utility_bindings"] = bindings
	return bindings


func _binding_value(action: String, column: String) -> String:
	var bindings := _bindings_state()
	var raw = bindings.get(action, {})
	if raw is Dictionary:
		return str(raw.get(column, "—"))
	return "—"


func _set_binding(action: String, column: String, value: String) -> void:
	var bindings := _bindings_state()
	var raw = bindings.get(action, {})
	var row: Dictionary = raw if raw is Dictionary else {}
	row[column] = value
	bindings[action] = row
	_set_state("utility_bindings", bindings)


func _binding_conflicts(action: String, column: String) -> Array:
	var value := _binding_value(action, column)
	var result: Array = []
	if value.is_empty() or value == "—":
		return result
	var bindings := _bindings_state()
	for other_key in bindings.keys():
		var other := str(other_key)
		if other == action:
			continue
		# Reload and hold-interact intentionally share the same controller
		# chord in the Xbox layout; unlike a keyboard duplicate this is one
		# physical action surfaced in two contextual rows in the handoff.
		var shared_controller_chord := column == "controller" and value == "X · HOLD" and ((action == "hold_interact" and other == "reload") or (action == "reload" and other == "hold_interact"))
		if _binding_value(other, column) == value and not shared_controller_chord:
			result.append(other)
	return result


func _conflict_pairs() -> Array:
	var pairs: Array = []
	var seen: Dictionary = {}
	for action_key in _bindings_state().keys():
		var action := str(action_key)
		for column in ["primary", "secondary", "controller"]:
			var conflicts := _binding_conflicts(action, column)
			for other_variant in conflicts:
				var other := str(other_variant)
				var pair_key: String = action + "|" + other + "|" + column
				var reverse_key: String = other + "|" + action + "|" + column
				if not seen.has(pair_key) and not seen.has(reverse_key):
					seen[pair_key] = true
					pairs.append({"action": action, "other": other, "column": column, "value": _binding_value(action, column)})
	return pairs


func _set_control_input(mode: String) -> void:
	_set_state("utility_control_input", mode)
	_rerender()


func _apply_control_preset(preset: String) -> void:
	var bindings := _bindings_state()
	if preset == "DEFAULT":
		bindings = DEFAULT_BINDINGS.duplicate(true)
	elif preset == "LEFT-HANDED":
		bindings["move"]["primary"] = "ARROWS"
		bindings["quick_heal"]["primary"] = "Q"
		bindings["melee"]["primary"] = "X"
	elif preset == "TARKOV-LIKE":
		bindings["interact"]["primary"] = "F"
		bindings["quick_heal"]["primary"] = "4"
		bindings["push_to_talk"]["primary"] = "CAPS"
	_set_state("utility_bindings", bindings)
	_set_state("utility_controls_custom", preset == "CUSTOM ·")
	_toast(preset + " preset loaded")
	_rerender()


func _binding_label(action: String) -> String:
	for group_variant in CONTROL_GROUPS:
		var group: Dictionary = group_variant
		for action_variant in group.get("actions", []):
			var record: Dictionary = action_variant
			if str(record.get("id", "")) == action:
				return str(record.get("label", action)).to_upper()
	return action.to_upper()


func _begin_capture(action: String, column: String) -> void:
	capture_action = action
	capture_column = column
	_rerender()


func _cancel_capture() -> void:
	capture_action = ""
	capture_column = ""
	_rerender()


func _event_key_name(event: InputEventKey) -> String:
	var code := event.physical_keycode if event.physical_keycode != 0 else event.keycode
	var result := OS.get_keycode_string(code)
	if result.is_empty():
		result = event.as_text()
	return result.to_upper()


func _mouse_button_name(button_index: int) -> String:
	match button_index:
		MOUSE_BUTTON_LEFT:
			return "LMB"
		MOUSE_BUTTON_RIGHT:
			return "RMB"
		MOUSE_BUTTON_MIDDLE:
			return "MMB"
		MOUSE_BUTTON_XBUTTON1:
			return "MOUSE 4"
		MOUSE_BUTTON_XBUTTON2:
			return "MOUSE 5"
		MOUSE_BUTTON_WHEEL_UP:
			return "MWHEEL UP"
		MOUSE_BUTTON_WHEEL_DOWN:
			return "MWHEEL DOWN"
		MOUSE_BUTTON_WHEEL_LEFT:
			return "MWHEEL LEFT"
		MOUSE_BUTTON_WHEEL_RIGHT:
			return "MWHEEL RIGHT"
		_:
			return "MOUSE " + str(button_index)


func _input(event: InputEvent) -> void:
	if not accepts_input(): return
	if capture_action.is_empty():
		return
	# _input runs before Control GUI dispatch.  While listening, consume the
	# mouse click as well as keyboard/controller input so a rebind cannot also
	# activate the row button that opened capture.
	if event is InputEventMouseButton and event.is_pressed():
		var mouse_event: InputEventMouseButton = event
		_assign_capture(_mouse_button_name(mouse_event.button_index))
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.is_pressed():
		var joy_button: InputEventJoypadButton = event
		_assign_capture("JOY " + str(joy_button.button_index))
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion and abs(event.axis_value) > 0.7:
		var motion: InputEventJoypadMotion = event
		_assign_capture("JOY AXIS " + str(motion.axis))
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if not accepts_input(): return
	if capture_action.is_empty() or not event.is_pressed() or event.is_echo():
		return
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null:
		return
	if key_event.keycode == KEY_ESCAPE:
		_cancel_capture()
	elif key_event.keycode == KEY_BACKSPACE:
		_assign_capture("—")
	else:
		_assign_capture(_event_key_name(key_event))
	get_viewport().set_input_as_handled()


func _assign_capture(value: String) -> void:
	if capture_action.is_empty():
		return
	_set_binding(capture_action, capture_column, value)
	_set_state("utility_controls_custom", true)
	var conflicts := _binding_conflicts(capture_action, capture_column)
	if not conflicts.is_empty():
		_toast("Conflict: " + value + " is already bound to " + _binding_label(str(conflicts[0])))
	capture_action = ""
	capture_column = ""
	_rerender()


func _reset_bindings() -> void:
	_set_state("utility_bindings", DEFAULT_BINDINGS.duplicate(true))
	_set_state("utility_controls_custom", false)
	capture_action = ""
	capture_column = ""
	_toast("Default controls restored")
	_rerender()


func _resolve_conflict(keep: String, clear: String, column: String) -> void:
	_set_binding(clear, column, "—")
	_toast(_binding_label(keep) + " kept on " + column)
	_rerender()


func _save_controls() -> void:
	if not _conflict_pairs().is_empty():
		_toast("Resolve every conflict before saving")
		return
	_set_state("utility_controls_saved", true)
	_toast("Controls saved")


func _crosshair_color(name: String) -> Color:
	match name:
		"GREEN": return C_GREEN
		"BLUE": return C_BLUE
		"ORANGE": return C_ACCENT
		"RED": return C_RED
		"YELLOW": return C_YELLOW
		_: return C_TEXT


func _select_crosshair(shape: String) -> void:
	_set_setting("hud_crosshair_shape", shape)
	_toast(shape + " crosshair selected")
	_rerender()

func layout_compact(view: Vector2) -> void:
	preload("res://ui/screens/utilities/components/utility_layout.gd").new(self).apply(view)
