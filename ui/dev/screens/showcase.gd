extends ZScreen

## Controller for the authored component-state showcase.
##
## All controls live in showcase.tscn. This script supplies the small amount of
## behavior that cannot be serialized in a scene: mock callbacks, the disabled
## state, desktop focus, and compact geometry for the authored scroll pane.

const DESIGN_SIZE := Vector2(1920.0, 1080.0)
const STATE_BUTTONS := ["StateDefaultButton", "StatePrimaryButton", "StateDisabledButton", "StateFocusedButton"]
const CARD_NAMES := ["ReadyCard", "WaitingCard", "UnavailableCard"]


func build() -> void:
	reset_adaptive_layout()
	_install_scale_safe_styles()
	_bind_dynamic_state()
	_wire_actions()
	_set_display_mode(_is_compact_view())
	_set_desktop_focus()
	queue_adaptive_layout()


func _bind_dynamic_state() -> void:
	for host_path in ["Desktop", "ComponentStates/Content"]:
		var host: Control = get_node(host_path) as Control
		for index in range(STATE_BUTTONS.size()):
			var state_button: Button = host.get_node(STATE_BUTTONS[index]) as Button
			state_button.disabled = index == 2
			state_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		for card_name in CARD_NAMES:
			var action: Button = host.get_node(card_name + "/Action") as Button
			action.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var confirmation: Button = host.get_node("Confirmation") as Button
		confirmation.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var compact_back: Button = get_node("CompactBack") as Button
	compact_back.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _wire_actions() -> void:
	var button_activated := Callable(self, "_button_activated")
	var preview_action := Callable(self, "_preview_action")
	var reset_action := Callable(self, "_confirm_reset")
	for host_path in ["Desktop", "ComponentStates/Content"]:
		var host: Node = get_node(host_path)
		for button_name in STATE_BUTTONS:
			_wire_button(host.get_node(button_name) as Button, button_activated)
		for card_name in CARD_NAMES:
			_wire_button(host.get_node(card_name + "/Action") as Button, preview_action)
		_wire_button(host.get_node("Confirmation") as Button, reset_action)
	_wire_button(get_node("CompactBack") as Button, Callable(self, "_go_back"))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _button_activated() -> void:
	toast("Button activated")


func _preview_action() -> void:
	toast("Preview action")


func _confirm_reset() -> void:
	if app == null:
		return
	app.confirm("Reset mock world?", "This only resets the current UI preview.", Callable(self, "_confirmed_reset"))


func _confirmed_reset() -> void:
	toast("Confirmed")


func _go_back() -> void:
	if app != null:
		app.back()


func _is_compact_view() -> bool:
	var view: Vector2 = get_viewport_rect().size
	return view.x < DESIGN_SIZE.x or view.y < DESIGN_SIZE.y


func _set_display_mode(compact: bool) -> void:
	var desktop: Control = get_node("Desktop") as Control
	desktop.visible = not compact
	for node_name in ["CompactHeaderTitle", "CompactBack", "CompactSubtitle", "ComponentStates", "CompactFooter"]:
		var node: Control = get_node(node_name) as Control
		node.visible = compact


func _set_desktop_focus() -> void:
	if _is_compact_view():
		var focused: Control = get_viewport().gui_get_focus_owner() as Control
		if focused != null and not focused.is_visible_in_tree():
			focused.release_focus()
		return
	var focused_button: Button = get_node("Desktop/StateFocusedButton") as Button
	focused_button.grab_focus()


func layout_compact(view: Vector2) -> void:
	_set_display_mode(true)
	ZAdaptive.backdrop(self, view)

	var title: Control = get_node("CompactHeaderTitle") as Control
	title.position = Vector2(24, 20)
	title.size = Vector2(view.x - 180, 40)
	var back: Control = get_node("CompactBack") as Control
	back.position = Vector2(view.x - 132, 24)
	back.size = Vector2(108, 36)
	var subtitle: Control = get_node("CompactSubtitle") as Control
	subtitle.position = Vector2(24, 64)
	subtitle.size = Vector2(view.x - 48, 24)
	var footer: Control = get_node("CompactFooter") as Control
	footer.position = Vector2(24, view.y - 36)
	footer.size = Vector2(view.x - 48, 24)

	var columns: int = 2 if view.x >= 1200 else 1
	var width: float = view.x - 64
	var column_width: float = (width - (columns - 1) * 16) / columns
	var button_rows: int = ceili(4.0 / columns)
	var card_rows: int = ceili(3.0 / columns)
	var content_height: float = button_rows * 108 + card_rows * 232 + 224
	var scroll: ScrollContainer = get_node("ComponentStates") as ScrollContainer
	scroll.position = Vector2(24, 104)
	scroll.size = Vector2(view.x - 48, view.y - 152)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.clip_contents = true
	_style_scrollbars(scroll)
	var content: Control = scroll.get_node("Content") as Control
	content.custom_minimum_size = Vector2(width, content_height)
	content.size = Vector2(width, content_height)

	for index in range(STATE_BUTTONS.size()):
		var x: float = (index % columns) * (column_width + 16)
		var y: float = int(index / columns) * 108
		var state_label: Control = content.get_node(STATE_BUTTONS[index].trim_suffix("Button") + "Label") as Control
		state_label.position = Vector2(x, y)
		state_label.size = Vector2(column_width, 24)
		var state_button: Control = content.get_node(STATE_BUTTONS[index]) as Control
		state_button.position = Vector2(x, y + 32)
		state_button.size = Vector2(column_width, 48)

	for index in range(CARD_NAMES.size()):
		var x: float = (index % columns) * (column_width + 16)
		var y: float = button_rows * 108 + int(index / columns) * 232
		var card: Control = content.get_node(CARD_NAMES[index]) as Control
		card.position = Vector2(x, y)
		card.size = Vector2(column_width, 216)
		var status: Control = card.get_node("Status") as Control
		status.position = Vector2(20, 20)
		status.size = Vector2(column_width - 40, 32)
		var description: Control = card.get_node("Description") as Control
		description.position = Vector2(20, 68)
		description.size = Vector2(column_width - 40, 28)
		var progress: Control = card.get_node("Progress") as Control
		progress.position = Vector2(20, 116)
		progress.size = Vector2(column_width - 40, 6)
		var action: Control = card.get_node("Action") as Control
		action.position = Vector2(20, 152)
		action.size = Vector2(240, 44)

	var y: float = button_rows * 108 + card_rows * 232
	var empty_stash: Control = content.get_node("EmptyStash") as Control
	empty_stash.position = Vector2(0, y)
	empty_stash.size = Vector2(width, 32)
	var empty_description: Control = content.get_node("EmptyDescription") as Control
	empty_description.position = Vector2(0, y + 40)
	empty_description.size = Vector2(width, 28)
	var invitation_field: Control = content.get_node("InvitationField") as Control
	invitation_field.position = Vector2(0, y + 88)
	invitation_field.size = Vector2(minf(440, width), 44)
	var confirmation: Control = content.get_node("Confirmation") as Control
	confirmation.position = Vector2(0, y + 148)
	confirmation.size = Vector2(320, 44)


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
