extends "res://ui/screens/frontflow/frontflow_actions.gd"

## Authored join-friend scene controller.
##
## The desktop hierarchy is authored in join_friend.tscn.  This controller only
## applies the state-dependent text and styles, connects the existing controls
## to the front-flow actions, and leaves compact reflow to the inherited code.

func build() -> void:
	reset_adaptive_layout()
	active_route = str(app.current_route)
	menu_entries.clear()

	var mode: String = _state_string("frontflow_join_mode", "friends")
	_configure_shared_styles()
	_bind_header_and_tabs(mode)
	_bind_friend_code()
	_bind_filters()
	_bind_friend_rows()
	_bind_invite_actions()
	_bind_detail_actions()
	_apply_validation_state()
	queue_adaptive_layout()


func _configure_shared_styles() -> void:
	# The generated screen applied these same helpers to every authored control.
	# Calling them here keeps the native font, cursor, focus, and pixel-safe style
	# behavior identical while leaving the node hierarchy in the scene file.
	var back: Button = get_node("Header/Back") as Button
	_button_style(back, false)
	_button_label(back, 10, true)
	back.alignment = HORIZONTAL_ALIGNMENT_CENTER

	var tabs: Array[Button] = [
		get_node("WorldsTab") as Button,
		get_node("FriendTab") as Button,
		get_node("CodeTab") as Button
	]
	for tab in tabs:
		_button_style(tab, false)
		_button_label(tab, 12, false)
		tab.alignment = HORIZONTAL_ALIGNMENT_LEFT

	var change: Button = get_node("ChangeAccount") as Button
	_button_style(change, false)
	_button_label(change, 9, false)

	var code_button: Button = get_node("CodeButton") as Button
	_button_style(code_button, false)
	_button_label(code_button, 9, false)

	var filters: Array[Button] = [
		get_node("FilterAll") as Button,
		get_node("FilterOpen") as Button,
		get_node("FilterStandard") as Button,
		get_node("FilterHardcore") as Button
	]
	for filter_button in filters:
		_apply_segment_style(filter_button, filter_button == filters[1])

	for row_name in ["FriendKevin", "FriendDenz", "FriendMara", "FriendSoot", "FriendPilgrim"]:
		var row: Panel = get_node(row_name) as Panel
		var action: Button = row.get_node("Action") as Button
		_button_style(action, false)
		_button_label(action, 9, false)
		if action.disabled:
			action.add_theme_color_override("font_color", U.MUTED)

	var accept: Button = get_node("InviteBar/Accept") as Button
	_button_style(accept, false)
	_button_label(accept, 9, false)
	accept.add_theme_color_override("font_color", U.GREEN)
	var decline: Button = get_node("InviteBar/Decline") as Button
	_button_style(decline, false)
	_button_label(decline, 9, false)

	var join: Button = get_node("FriendDetail/Join") as Button
	_button_style(join, true)
	_button_label(join, 14, false)
	var message: Button = get_node("FriendDetail/Message") as Button
	_button_style(message, false)
	_button_label(message, 10, false)

	var field: LineEdit = get_node("FriendCodeField") as LineEdit
	field.add_theme_font_size_override("font_size", 12)
	field.add_theme_color_override("font_color", U.TEXT)
	field.add_theme_color_override("font_placeholder_color", U.MUTED)
	field.add_theme_color_override("caret_color", U.ACCENT)
	field.add_theme_stylebox_override("normal", _style_box(Color(0.027, 0.035, 0.035, 0.9), U.LINE, 1))
	field.add_theme_stylebox_override("focus", _style_box(Color(0.07, 0.08, 0.075, 0.92), U.ACCENT, 1))
	field.clear_button_enabled = false

	_install_scale_safe_styles()


func _bind_header_and_tabs(mode: String) -> void:
	_wire_button(get_node("Header/Back") as Button, Callable(self, "_back_to_menu"))
	_wire_button(get_node("WorldsTab") as Button, Callable(self, "_open_saves"))
	var friend_tab := get_node("FriendTab") as Button
	var code_tab := get_node("CodeTab") as Button
	_wire_button(friend_tab, Callable(self, "_open_join_friend"))
	_wire_button(code_tab, Callable(self, "_open_join_code"))
	mark_feature_action(friend_tab, FEATURE_FRIENDS)
	mark_feature_action(code_tab, FEATURE_FRIENDS)
	_wire_button(get_node("ChangeAccount") as Button, Callable(self, "_switch_account"))

	_apply_tab_state(get_node("WorldsTab") as Button, false)
	_apply_tab_state(get_node("FriendTab") as Button, mode == "friends")
	_apply_tab_state(get_node("CodeTab") as Button, mode == "code")


func _bind_friend_code() -> void:
	friend_code_field = get_node("FriendCodeField") as LineEdit
	mark_feature_action(friend_code_field, FEATURE_FRIENDS)
	friend_code_field.text = ""
	friend_code_field.placeholder_text = "Search friends or paste a world code…"
	if not friend_code_field.text_submitted.is_connected(Callable(self, "_submit_friend_code")):
		friend_code_field.text_submitted.connect(Callable(self, "_submit_friend_code"))
	friend_code_error = get_node("FriendCodeError") as Label
	friend_code_error.text = ""
	var code_button := get_node("CodeButton") as Button
	_wire_button(code_button, Callable(self, "_submit_friend_code_from_field"))
	mark_feature_action(code_button, FEATURE_FRIENDS)


func _bind_filters() -> void:
	var filters: Array[Button] = [
		get_node("FilterAll") as Button,
		get_node("FilterOpen") as Button,
		get_node("FilterStandard") as Button,
		get_node("FilterHardcore") as Button
	]
	var keys: Array[String] = ["all", "open", "standard", "hardcore"]
	for index in range(filters.size()):
		filters[index].set_meta("front_filter", keys[index])
		_wire_button(filters[index], Callable(self, "_friend_filter"))
		mark_feature_action(filters[index], FEATURE_FRIENDS)


func _bind_friend_rows() -> void:
	var kevin := get_node("FriendKevin/Action") as Button
	var denz := get_node("FriendDenz/Action") as Button
	var mara := get_node("FriendMara/Action") as Button
	var soot := get_node("FriendSoot/Action") as Button
	var pilgrim := get_node("FriendPilgrim/Action") as Button
	_wire_button(kevin, Callable(self, "_join_kevin"))
	_wire_button(denz, Callable(self, "_request_denz"))
	_wire_button(mara, Callable(self, "_open_join_friend"))
	_wire_button(soot, Callable(self, "_open_join_friend"))
	_wire_button(pilgrim, Callable(self, "_open_join_friend"))
	for action in [kevin, denz, mara, soot, pilgrim]:
		mark_feature_action(action, FEATURE_FRIENDS)


func _bind_invite_actions() -> void:
	var accept := get_node("InviteBar/Accept") as Button
	var decline := get_node("InviteBar/Decline") as Button
	_wire_button(accept, Callable(self, "_join_denz"))
	_wire_button(decline, Callable(self, "_decline_invite"))
	mark_feature_action(accept, FEATURE_FRIENDS)
	mark_feature_action(decline, FEATURE_FRIENDS)


func _bind_detail_actions() -> void:
	var join := get_node("FriendDetail/Join") as Button
	var message := get_node("FriendDetail/Message") as Button
	_wire_button(join, Callable(self, "_join_kevin"))
	_wire_button(message, Callable(self, "_message_friend"))
	mark_feature_action(join, FEATURE_FRIENDS)
	mark_feature_action(message, FEATURE_FRIENDS)


func _apply_validation_state() -> void:
	if friend_code_error != null:
		friend_code_error.text = ""
	if friend_code_field != null:
		friend_code_field.add_theme_color_override("font_color", U.TEXT)


func _apply_tab_state(tab: Button, active: bool) -> void:
	if tab == null:
		return
	if active:
		tab.add_theme_color_override("font_color", U.TEXT)
		tab.add_theme_stylebox_override("normal", _style_box(Color(1.0, 1.0, 1.0, 0.03), U.TEXT, 0))
		tab.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.06), U.TEXT, 0))
	else:
		tab.add_theme_color_override("font_color", U.MUTED)
		tab.add_theme_stylebox_override("normal", _style_box(CLEAR, CLEAR, 0))


func _apply_segment_style(button: Button, active: bool, accent: Color = U.TEXT) -> void:
	if button == null:
		return
	button.add_theme_color_override("font_color", U.CANVAS if active else U.MUTED)
	button.add_theme_stylebox_override("normal", _style_box(accent if active else Color(0.027, 0.035, 0.035, 0.55), U.LINE if not active else accent, 1))
	button.add_theme_stylebox_override("hover", _style_box(Color(1.0, 1.0, 1.0, 0.08), accent, 1))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _install_scale_safe_styles() -> void:
	for node in find_children("*", "Control", true, false):
		var control: Control = node as Control
		if control is Panel:
			_wrap_style_override(control, "panel")
		elif control is Button:
			for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
				_wrap_style_override(control, style_name)
		elif control is LineEdit:
			for style_name in ["normal", "focus"]:
				_wrap_style_override(control, style_name)


func _wrap_style_override(control: Control, style_name: StringName) -> void:
	if not control.has_theme_stylebox_override(style_name):
		return
	var style: StyleBox = control.get_theme_stylebox(style_name)
	if style is StyleBoxFlat:
		control.add_theme_stylebox_override(style_name, U.scale_safe(style))
