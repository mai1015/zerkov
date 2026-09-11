extends "res://ui/screens/utilities/utility_actions.gd"

## Authored controls screen controller.
##
## controls.tscn owns the complete desktop surface, including every binding
## row and the controller diagram. This controller updates the binding values,
## conflict state, capture prompt and controller options while retaining the
## utility screen's compact layout and input capture behavior.

const ACTION_GROUPS: Array = [
	["Movement", ["move", "sprint", "crouch", "interact", "hold_interact"]],
	["Combat", ["fire", "aim", "reload", "fire_mode", "melee", "grenade", "weapon_cycle"]],
	["Survival", ["quick_heal", "quick_use", "eat_drink"]],
	["Interface", ["inventory", "map", "push_to_talk"]]
]

const ZerkovActions = preload("res://game/input/zerkov_input_actions.gd")

## The authored controls rows remain the visual contract.  This table only
## maps those rows to the product-owned logical actions; CommonUI's binding
## registry remains the source of truth for values, conflicts and persistence.
const LIVE_ACTIONS := {
	"move": ZerkovActions.GAME_MOVE,
	"sprint": ZerkovActions.GAME_SPRINT,
	"crouch": ZerkovActions.GAME_CROUCH,
	"interact": ZerkovActions.GAME_INTERACT,
	"hold_interact": ZerkovActions.GAME_HOLD_INTERACT,
	"fire": ZerkovActions.GAME_FIRE,
	"aim": ZerkovActions.GAME_AIM,
	"reload": ZerkovActions.GAME_RELOAD,
	"fire_mode": ZerkovActions.GAME_FIRE_MODE,
	"melee": ZerkovActions.GAME_MELEE,
	"grenade": ZerkovActions.GAME_GRENADE,
	"weapon_cycle": ZerkovActions.GAME_WEAPON_CYCLE,
	"quick_heal": ZerkovActions.GAME_QUICK_HEAL,
	"quick_use": ZerkovActions.GAME_QUICK_USE,
	"eat_drink": ZerkovActions.GAME_EAT_DRINK,
	"inventory": ZerkovActions.UI_OPEN_INVENTORY,
	"map": ZerkovActions.UI_OPEN_MAP,
	"push_to_talk": ZerkovActions.GAME_PUSH_TO_TALK,
}

const LIVE_CONTROLLER_ACTIONS := {
	"weapon_cycle": ZerkovActions.GAME_WEAPON_CYCLE_CONTROLLER,
}

var _capture_generation: int = 0
var _live_refresh_queued: bool = false


func build() -> void:
	reset_adaptive_layout()
	route = "controls"
	_bindings_state()
	_settings_state()
	_install_scale_safe_styles()
	_bind_static_data()
	_wire_actions()
	_build_focus_graph()
	queue_adaptive_layout()


func _live_input_service() -> ZerkovInputService:
	if app == null:
		return null
	var service := app.input_service()
	return service if service != null and service.is_configured() else null


func _uses_live_bindings() -> bool:
	return _live_input_service() != null


func _live_action(action: String, column: String = "") -> StringName:
	if column == "controller" and LIVE_CONTROLLER_ACTIONS.has(action):
		return LIVE_CONTROLLER_ACTIONS[action] as StringName
	return LIVE_ACTIONS.get(action, &"") as StringName


func _live_slot(column: String) -> int:
	return CommonUIBinding.SLOT_PRIMARY if column == "primary" \
		else CommonUIBinding.SLOT_SECONDARY


func _request_id(operation: String) -> StringName:
	_capture_generation += 1
	return StringName("controls_%s_%d" % [operation, _capture_generation])


func _bindings_state() -> Dictionary:
	# The live screen deliberately does not hydrate or write the old fixture
	# table.  Keep the inherited table only for isolated preview hosts where
	# CommonUI's product input service is not installed.
	if _uses_live_bindings():
		return {}
	return super._bindings_state()


func _binding_value(action: String, column: String) -> String:
	var service := _live_input_service()
	var logical_action := _live_action(action, column)
	if service == null or logical_action == &"":
		return super._binding_value(action, column)

	# Move is authored as one row but intentionally has four keyboard direction
	# actions in the catalog.  Keep its compact display useful while resolving
	# every shown value from the same live registry.
	if action == "move" and column == "primary":
		var directions: Array[String] = []
		for direction in [ZerkovActions.GAME_MOVE_UP, ZerkovActions.GAME_MOVE_LEFT,
				ZerkovActions.GAME_MOVE_DOWN, ZerkovActions.GAME_MOVE_RIGHT]:
			var direction_binding := service.effective_binding(direction, CommonUIBinding.SLOT_PRIMARY)
			var direction_text := CommonBindingText.describe(direction_binding)
			if not direction_text.is_empty():
				directions.append(direction_text)
		return " ".join(directions) if not directions.is_empty() else "—"

	var binding := service.effective_binding(logical_action, _live_slot(column))
	var text := CommonBindingText.describe(binding)
	return text if not text.is_empty() else "—"


func _set_binding(action: String, column: String, value: String) -> void:
	if _uses_live_bindings():
		return
	super._set_binding(action, column, value)


func _binding_conflicts(action: String, column: String) -> Array:
	var service := _live_input_service()
	var logical_action := _live_action(action, column)
	if service == null or logical_action == &"":
		return super._binding_conflicts(action, column)
	var candidate := service.effective_binding(logical_action, _live_slot(column))
	if candidate == null:
		return []
	var result: Array = []
	for conflict_variant in service.preview_conflicts(logical_action, _live_slot(column), candidate):
		var conflict: Dictionary = conflict_variant
		var other := str(conflict.get("action", ""))
		if not other.is_empty():
			result.append(other)
	return result


func _conflict_pairs() -> Array:
	if not _uses_live_bindings():
		return super._conflict_pairs()
	var pairs: Array = []
	var seen: Dictionary = {}
	for group_variant in ACTION_GROUPS:
		var group: Array = group_variant[1]
		for action_variant in group:
			var action := str(action_variant)
			for column in ["primary", "secondary", "controller"]:
				for other_variant in _binding_conflicts(action, column):
					var other := str(other_variant)
					var key: String = action + "|" + other + "|" + column
					var reverse: String = other + "|" + action + "|" + column
					if not seen.has(key) and not seen.has(reverse):
						seen[key] = true
						pairs.append({"action": action, "other": other, "column": column,
							"value": _binding_value(action, column)})
	return pairs


func layout_compact(view: Vector2) -> void:
	# The authored desktop chrome is made of root-level siblings so its
	# geometry stays identical at 1920×1080. Compact controls owns its tabs,
	# panes and actions; hide those desktop siblings before the inherited reflow
	# moves the bindings and controller regions into their compact workspaces.
	super.layout_compact(view)


func _bind_static_data() -> void:
	_bind_sidebar()
	_bind_capture_banner()
	_bind_binding_rows()
	_bind_conflicts()
	_bind_controller_options()


func _bind_sidebar() -> void:
	var categories: Array = [
		["SidebarGameplay", "gameplay"], ["SidebarHud", "hud"], ["SidebarControls", "controls"],
		["SidebarGraphics", "video"], ["SidebarAudio", "audio"], ["SidebarAccessibility", "accessibility"], ["SidebarAccount", "account"]
	]
	for item in categories:
		var button: Button = get_node(str(item[0])) as Button
		var active: bool = str(item[1]) == "controls"
		button.add_theme_color_override("font_color", C_TEXT if active else C_MUTED)
		button.add_theme_stylebox_override("normal", _style_box(Color(1.0, 1.0, 1.0, 0.06) if active else Color.TRANSPARENT, C_TEXT if active else Color.TRANSPARENT, 0 if not active else 1))
		button.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.04), C_TEXT, 1))

	var input_mode: String = str(_state_value("utility_control_input", "KB + MOUSE"))
	_configure_input_button(get_node("InputKeyboard") as Button, input_mode == "KB + MOUSE")
	_configure_input_button(get_node("InputController") as Button, input_mode == "CONTROLLER")
	var custom: bool = bool(_state_value("utility_controls_custom", false))
	var presets: Array[String] = ["PresetDefault", "PresetLeftHanded", "PresetTarkov", "PresetCustom"]
	for index in range(presets.size()):
		(get_node(presets[index]) as Button).add_theme_color_override("font_color", C_TEXT if index == 0 and not custom else C_MUTED)


func _configure_input_button(button: Button, active: bool) -> void:
	if button == null:
		return
	button.add_theme_color_override("font_color", C_BG if active else C_MUTED)
	button.add_theme_stylebox_override("normal", _style_box(C_TEXT if active else C_DARK, C_TEXT if active else C_LINE, 1))
	button.add_theme_stylebox_override("hover", _style_box(C_HOVER if active else Color(1.0, 1.0, 1.0, 0.06), C_HOVER, 1))


func _bind_capture_banner() -> void:
	var body: Control = get_node("BindingsPane/BindingsBody") as Control
	var banner: Panel = body.get_node("CaptureBanner") as Panel
	var active: bool = not capture_action.is_empty()
	banner.visible = active
	_set_panel_style(banner, Color(0.28, 0.16, 0.05, 0.35), C_ACCENT)
	if active:
		(banner.get_node("Prompt") as Label).text = "PRESS A KEY FOR · " + _binding_label(capture_action)
	# The authored scene is packed in the default no-capture state. Match the
	# generated route's 50px insertion by shifting the table below the prompt.
	for child in body.get_children():
		if child != banner and active:
			child.position.y += 50.0
	body.custom_minimum_size.y = 1260.0 + (50.0 if active else 0.0)


func _bind_binding_rows() -> void:
	var body: Control = get_node("BindingsPane/BindingsBody") as Control
	for group_variant in CONTROL_GROUPS:
		var group: Dictionary = group_variant
		for action_variant in group.get("actions", []):
			var action: Dictionary = action_variant
			var action_id: String = str(action.get("id", ""))
			var suffix: String = _action_suffix(action_id)
			(body.get_node("Action" + suffix) as Label).text = str(action.get("label", action_id))
			for column in ["primary", "secondary", "controller"]:
				var button: Button = body.get_node(suffix + _column_suffix(column)) as Button
				var value: String = _binding_value(action_id, column)
				var listening: bool = capture_action == action_id and capture_column == column
				var conflict: bool = not _binding_conflicts(action_id, column).is_empty()
				button.text = "PRESS KEY" if listening else value
				button.tooltip_text = "Rebind " + str(action.get("label", action_id)) + " · " + column
				button.add_theme_font_size_override("font_size", 10 if column == "controller" else 11)
				_set_binding_button_style(button, column == "controller", listening, conflict)


func _action_suffix(action_id: String) -> String:
	var result: String = ""
	for part in action_id.split("_"):
		result += str(part).capitalize()
	return result


func _column_suffix(column: String) -> String:
	match column:
		"primary": return "Primary"
		"secondary": return "Secondary"
		_: return "Controller"


func _set_binding_button_style(button: Button, controller: bool, listening: bool, conflict: bool) -> void:
	if button == null:
		return
	button.add_theme_color_override("font_color", C_RED if conflict else C_TEXT)
	button.add_theme_color_override("font_hover_color", C_HOVER)
	button.add_theme_color_override("font_pressed_color", C_BG)
	button.add_theme_stylebox_override("normal", _style_box(C_DARK, C_RED if conflict else C_LINE, 1))
	button.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.05), C_TEXT, 1))
	button.add_theme_stylebox_override("pressed", _style_box(Color(0.75, 0.42, 0.12, 0.35), C_ACCENT, 1))
	button.add_theme_stylebox_override("focus", _style_box(Color(1.0, 1.0, 1.0, 0.06), C_ACCENT, 1))
	if controller:
		button.add_theme_stylebox_override("normal", _style_box(C_DARK, C_RED if conflict else C_LINE, 1))
		button.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.05), C_TEXT, 1))
	if listening:
		button.add_theme_color_override("font_color", C_BG)
		button.add_theme_stylebox_override("normal", _style_box(C_ACCENT, C_ACCENT, 1))
	elif conflict:
		button.add_theme_color_override("font_color", C_RED)
		button.add_theme_stylebox_override("normal", _style_box(Color(0.22, 0.04, 0.035, 0.24), C_RED, 1))
		if controller:
			button.add_theme_stylebox_override("normal", _style_box(C_DARK, C_RED, 1))


func _bind_conflicts() -> void:
	var pairs: Array = _conflict_pairs()
	var count: int = pairs.size()
	(get_node("ConflictTitle") as Label).text = "CONFLICTS · %d" % count
	var visible: bool = count > 0
	for node_name in ["ConflictPanel", "ConflictSummary", "ConflictDescription", "KeepAction", "KeepOther"]:
		(get_node(node_name) as CanvasItem).visible = visible
	_set_panel_style(get_node("ConflictPanel") as Panel, Color(0.20, 0.05, 0.04, 0.45), C_RED)
	var save: Button = get_node("SaveControls") as Button
	save.disabled = visible
	save.text = "SAVE · RESOLVE CONFLICT" if visible else "SAVE"
	if visible:
		var pair: Dictionary = pairs[0]
		(get_node("ConflictSummary") as Label).text = "%s · %s and %s" % [str(pair.get("value", "")), _binding_label(str(pair.get("action", ""))), _binding_label(str(pair.get("other", "")))]
		(get_node("ConflictDescription") as Label).text = "Both fire on " + str(pair.get("value", "")) + ". Keep one, or rebind either."
		(get_node("KeepAction") as Button).text = "KEEP " + _binding_label(str(pair.get("action", "")))
		(get_node("KeepOther") as Button).text = "KEEP " + _binding_label(str(pair.get("other", "")))


func _bind_controller_options() -> void:
	var aim: bool = bool(_get_setting("controller_aim_assist"))
	var vibration: bool = bool(_get_setting("controller_vibration"))
	var invert: bool = bool(_get_setting("controller_invert_y"))
	_configure_option_toggle("AimAssistState", "AimAssistToggle", "AimAssistOn", aim, "controller_aim_assist")
	_configure_option_toggle("VibrationState", "VibrationToggle", "VibrationOn", vibration, "controller_vibration")
	_configure_option_toggle("InvertState", "InvertToggle", "", invert, "controller_invert_y")
	var deadzone: HSlider = get_node("DeadzoneSlider") as HSlider
	deadzone.value = float(_get_setting("controller_deadzone"))
	(get_node("DeadzoneValue") as Label).text = _format_setting_value(float(deadzone.value), "%")
	var sensitivity: HSlider = get_node("SensitivitySlider") as HSlider
	sensitivity.value = float(_get_setting("controller_look_sensitivity"))
	(get_node("SensitivityValue") as Label).text = _format_setting_value(float(sensitivity.value), "")


func _configure_option_toggle(state_name: String, button_name: String, indicator_name: String, enabled: bool, _key: String) -> void:
	(get_node(state_name) as Label).text = "ON" if enabled else "OFF"
	(get_node(state_name) as Label).add_theme_color_override("font_color", C_MUTED)
	var button: Button = get_node(button_name) as Button
	button.add_theme_stylebox_override("normal", _style_box(Color.TRANSPARENT, C_TEXT if enabled else C_LINE, 1))
	button.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.04), C_HOVER, 1))
	if not indicator_name.is_empty():
		(get_node(indicator_name) as CanvasItem).visible = enabled


func _wire_actions() -> void:
	var chrome := get_node_or_null("NavigationChrome") as ZNavigationChrome
	if chrome != null:
		chrome.active_route = "settings"
		var navigate_callback := Callable(self, "_go")
		if not chrome.navigate_requested.is_connected(navigate_callback):
			chrome.navigate_requested.connect(navigate_callback)
		var insurance_callback := Callable(self, "_insurance_notice")
		if not chrome.insurance_requested.is_connected(insurance_callback):
			chrome.insurance_requested.connect(insurance_callback)
		var back_callback := Callable(self, "_go_back")
		if not chrome.back_requested.is_connected(back_callback):
			chrome.back_requested.connect(back_callback)

	for item in [
		["SidebarGameplay", "gameplay"], ["SidebarHud", "hud"], ["SidebarControls", "controls"],
		["SidebarGraphics", "video"], ["SidebarAudio", "audio"], ["SidebarAccessibility", "accessibility"], ["SidebarAccount", "account"]
	]:
		_wire_button(get_node(str(item[0])) as Button, Callable(self, "_select_settings_section").bind(str(item[1])))
	_wire_button(get_node("InputKeyboard") as Button, Callable(self, "_set_control_input").bind("KB + MOUSE"))
	_wire_button(get_node("InputController") as Button, Callable(self, "_set_control_input").bind("CONTROLLER"))
	for item in [["PresetDefault", "DEFAULT"], ["PresetLeftHanded", "LEFT-HANDED"], ["PresetTarkov", "TARKOV-LIKE"], ["PresetCustom", "CUSTOM ·"]]:
		_wire_button(get_node(str(item[0])) as Button, Callable(self, "_apply_control_preset").bind(str(item[1])))

	var body: Control = get_node("BindingsPane/BindingsBody") as Control
	for group_variant in CONTROL_GROUPS:
		var group: Dictionary = group_variant
		for action_variant in group.get("actions", []):
			var action: Dictionary = action_variant
			var suffix: String = _action_suffix(str(action.get("id", "")))
			for column in ["primary", "secondary", "controller"]:
				_wire_button(body.get_node(suffix + _column_suffix(column)) as Button, Callable(self, "_begin_capture").bind(str(action.get("id", "")), column))
	_wire_button(body.get_node("ResetAll") as Button, Callable(self, "_reset_bindings"))

	var pairs: Array = _conflict_pairs()
	if not pairs.is_empty():
		var pair: Dictionary = pairs[0]
		_wire_button(get_node("KeepAction") as Button, Callable(self, "_resolve_conflict").bind(str(pair.get("action", "")), str(pair.get("other", "")), str(pair.get("column", ""))))
		_wire_button(get_node("KeepOther") as Button, Callable(self, "_resolve_conflict").bind(str(pair.get("other", "")), str(pair.get("action", "")), str(pair.get("column", ""))))
	_wire_button(get_node("ControllerDpad") as Button, Callable(self, "_toast").bind("D-pad focus preview"))
	_wire_button(get_node("AimAssistToggle") as Button, Callable(self, "_on_setting_toggle").bind("controller_aim_assist"))
	_wire_button(get_node("VibrationToggle") as Button, Callable(self, "_on_setting_toggle").bind("controller_vibration"))
	_wire_button(get_node("InvertToggle") as Button, Callable(self, "_on_setting_toggle").bind("controller_invert_y"))
	_wire_slider(get_node("DeadzoneSlider") as HSlider, "controller_deadzone")
	_wire_slider(get_node("SensitivitySlider") as HSlider, "controller_look_sensitivity")
	_wire_button(get_node("SaveControls") as Button, Callable(self, "_save_controls"))
	_wire_button(get_node("RevertControls") as Button, Callable(self, "_reset_bindings"))


func _wire_slider(slider: HSlider, key: String) -> void:
	if slider == null:
		return
	_wire_signal(slider.value_changed, Callable(self, "_on_setting_slider").bind(key))
	var display_name: String = "DeadzoneValue" if key == "controller_deadzone" else "SensitivityValue"
	var suffix: String = "%" if key == "controller_deadzone" else ""
	_wire_signal(slider.value_changed, Callable(self, "_on_setting_slider_display").bind(get_node(display_name), suffix))


func _wire_signal(signal_value: Signal, callback: Callable) -> void:
	if not signal_value.is_connected(callback):
		signal_value.connect(callback)


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _build_focus_graph() -> void:
	var buttons: Array[Button] = []
	var body: Control = get_node("BindingsPane/BindingsBody") as Control
	for group_variant in CONTROL_GROUPS:
		var group: Dictionary = group_variant
		for action_variant in group.get("actions", []):
			var action: Dictionary = action_variant
			var suffix: String = _action_suffix(str(action.get("id", "")))
			for column in ["primary", "secondary", "controller"]:
				buttons.append(body.get_node(suffix + _column_suffix(column)) as Button)
	buttons.append(body.get_node("ResetAll") as Button)
	if buttons.is_empty():
		return
	for index in range(buttons.size()):
		buttons[index].focus_neighbor_top = buttons[index].get_path_to(buttons[posmod(index - 1, buttons.size())])
		buttons[index].focus_neighbor_bottom = buttons[index].get_path_to(buttons[(index + 1) % buttons.size()])
	var focus_target: Button = buttons[0]
	if not capture_action.is_empty():
		var suffix: String = _action_suffix(capture_action)
		focus_target = body.get_node(suffix + _column_suffix(capture_column)) as Button
	# Desktop captures are reference images rather than an active keyboard
	# session. Keep the focus graph for compact input, but leave the desktop
	# surface without a focused WASD button and its orange focus outline.
	var view := get_viewport_rect().size
	if view.x >= 1920.0 and view.y >= 1080.0:
		return
	focus_target.grab_focus()


func _install_scale_safe_styles() -> void:
	var chrome := get_node_or_null("NavigationChrome") as ZNavigationChrome
	for node in find_children("*", "Control", true, false):
		var control := node as Control
		if chrome != null and (control == chrome or chrome.is_ancestor_of(control)):
			continue
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


func _set_panel_style(panel: Panel, fill: Color, border: Color, width: int = 1) -> void:
	if panel != null:
		panel.add_theme_stylebox_override("panel", U.style(fill, border, width))


func _insurance_notice() -> void:
	_toast("Insurance claims are outside the approved design set.")


func _go_back() -> void:
	if app != null:
		app.back()


func _rerender() -> void:
	refresh_view()


# --- CommonUI-backed binding surface --------------------------------------

func _apply_control_preset(preset: String) -> void:
	var service := _live_input_service()
	if service != null:
		if preset == "DEFAULT":
			var result := service.restore_defaults(_request_id("preset"))
			_toast("Default controls restored" if bool(result.get("ok", false)) \
				else "Default controls failed · " + str(result.get("error", "unknown error")))
		else:
			_toast("Custom live bindings do not support fixture presets")
		_rerender()
		return
	super._apply_control_preset(preset)


func _begin_capture(action: String, column: String) -> void:
	if _uses_live_bindings() and _live_action(action, column) == &"":
		return
	_capture_generation += 1
	capture_action = action
	capture_column = column
	_rerender()


func _cancel_capture() -> void:
	_capture_generation += 1
	capture_action = ""
	capture_column = ""
	_rerender()


func _binding_from_event(event: InputEvent) -> CommonUIBinding:
	var binding := CommonUIBinding.new()
	if event is InputEventKey:
		var key_event := event as InputEventKey
		binding.set_device_kind(CommonUIBinding.DEVICE_KEYBOARD)
		binding.set_code(key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode)
		binding.set_shift_pressed(key_event.shift_pressed)
		binding.set_ctrl_pressed(key_event.ctrl_pressed)
		binding.set_alt_pressed(key_event.alt_pressed)
		binding.set_meta_pressed(key_event.meta_pressed)
	elif event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		binding.set_device_kind(CommonUIBinding.DEVICE_MOUSE)
		binding.set_code(mouse_event.button_index)
		binding.set_shift_pressed(mouse_event.shift_pressed)
		binding.set_ctrl_pressed(mouse_event.ctrl_pressed)
		binding.set_alt_pressed(mouse_event.alt_pressed)
		binding.set_meta_pressed(mouse_event.meta_pressed)
	elif event is InputEventJoypadButton:
		binding.set_device_kind(CommonUIBinding.DEVICE_GAMEPAD_BUTTON)
		binding.set_code((event as InputEventJoypadButton).button_index)
	elif event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		if absf(motion.axis_value) < 0.5:
			return null
		binding.set_device_kind(CommonUIBinding.DEVICE_GAMEPAD_AXIS)
		binding.set_code(motion.axis)
		binding.set_axis_direction(CommonUIBinding.AXIS_DIRECTION_NEGATIVE \
			if motion.axis_value < 0.0 else CommonUIBinding.AXIS_DIRECTION_POSITIVE)
	else:
		return null
	binding.set_slot(_live_slot(capture_column))
	return binding


func _input(event: InputEvent) -> void:
	if not accepts_input() or capture_action.is_empty():
		return
	# Capture runs before GUI/CommonUI dispatch. This makes Escape a capture
	# cancel and consumes every accepted candidate so a rebind never also fires
	# the row action or an overlapping route action.
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_ESCAPE:
			_cancel_capture()
		elif key_event.keycode == KEY_BACKSPACE:
			_clear_live_capture()
		else:
			_assign_capture(_binding_from_event(key_event))
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.is_pressed():
		_assign_capture(_binding_from_event(event))
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.is_pressed():
		_assign_capture(_binding_from_event(event))
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion and absf(event.axis_value) >= 0.5:
		_assign_capture(_binding_from_event(event))
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	# Live capture is deliberately handled in _input, before CommonUI.  The
	# inherited fixture path remains available only for isolated previews.
	if not _uses_live_bindings():
		super._unhandled_key_input(event)


func _clear_live_capture() -> void:
	var service := _live_input_service()
	if service == null or capture_action.is_empty():
		return
	var action := _live_action(capture_action, capture_column)
	var slot := _live_slot(capture_column)
	var result := service.clear_binding(action, slot, false, _request_id("clear"))
	if bool(result.get("ok", false)):
		_toast("Binding cleared")
	else:
		_toast("Binding could not be cleared · " + str(result.get("error", "unknown error")))
	_capture_generation += 1
	capture_action = ""
	capture_column = ""
	_rerender()


func _assign_capture(candidate: Variant) -> void:
	if capture_action.is_empty() or not accepts_input():
		return
	var service := _live_input_service()
	if service == null:
		super._assign_capture(str(candidate))
		return
	var binding := candidate as CommonUIBinding
	if binding == null:
		return
	var action := _live_action(capture_action, capture_column)
	var slot := _live_slot(capture_column)
	var result := service.rebind(action, slot, binding,
		CommonInputBindingRegistry.CONFLICT_REJECT, false, _request_id("rebind"))
	if not bool(result.get("ok", false)):
		var conflicts: Array = result.get("conflicts", [])
		_toast("Binding conflict · choose a free binding" if not conflicts.is_empty() \
			else "Binding rejected · " + str(result.get("error", "unknown error")))
		return
	_toast("Binding updated")
	_capture_generation += 1
	capture_action = ""
	capture_column = ""
	_rerender()


func _reset_bindings() -> void:
	var service := _live_input_service()
	if service != null:
		var result := service.restore_defaults(_request_id("reset"))
		_toast("Default controls restored" if bool(result.get("ok", false)) \
			else "Default controls failed · " + str(result.get("error", "unknown error")))
		_capture_generation += 1
		capture_action = ""
		capture_column = ""
		_rerender()
		return
	super._reset_bindings()


func _save_controls() -> void:
	if not _conflict_pairs().is_empty():
		_toast("Resolve every conflict before saving")
		return
	if _uses_live_bindings():
		_toast("Controls saved")
		return
	super._save_controls()


func _on_deactivated() -> void:
	# A queued physical event must not mutate a retained controls screen after
	# its CommonUI context has been released. Invalidate the capture before the
	# screen can be reused or torn down.
	var service := _live_input_service()
	var callback := Callable(self, "_on_live_bindings_published")
	if service != null and service.bindings_published.is_connected(callback):
		service.bindings_published.disconnect(callback)
	_capture_generation += 1
	capture_action = ""
	capture_column = ""
	super._on_deactivated()


func _on_activated() -> void:
	super._on_activated()
	var service := _live_input_service()
	var callback := Callable(self, "_on_live_bindings_published")
	if service != null and not service.bindings_published.is_connected(callback):
		service.bindings_published.connect(callback)


func _on_live_bindings_published(_snapshot: Dictionary) -> void:
	if _live_refresh_queued or not is_inside_tree():
		return
	_live_refresh_queued = true
	call_deferred("_refresh_live_bindings")


func _refresh_live_bindings() -> void:
	_live_refresh_queued = false
	if is_inside_tree() and accepts_input() and _uses_live_bindings():
		refresh_view()
