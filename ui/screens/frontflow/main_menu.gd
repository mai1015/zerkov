extends "res://ui/screens/frontflow/frontflow_actions.gd"

## Authored main-menu scene controller.
##
## The desktop hierarchy lives in main_menu.tscn. This script owns the small
## amount of state that cannot be authored there: world text, callbacks,
## keyboard focus, parallax motion, and the inherited compact reflow.

func build() -> void:
	reset_adaptive_layout()
	active_route = str(app.current_route)
	menu_entries.clear()

	var worlds: Array[Dictionary] = _worlds()
	var world: Dictionary = _selected_world_data()
	_install_scale_safe_styles()
	_populate_world_data(worlds, world)
	_wire_actions()
	_build_focus_graph()

	var parallax: ZParallaxBackground = get_node_or_null("ParallaxBackground") as ZParallaxBackground
	if parallax != null:
		parallax.set_motion_enabled(not app.qa_mode)
	queue_adaptive_layout()


func _populate_world_data(worlds: Array[Dictionary], world: Dictionary) -> void:
	var has_world: bool = not worlds.is_empty()
	var menu_card: ZMenuActionCard = get_node("MenuContinue")
	menu_card.card_title = "CONTINUE" if has_world else "CREATE WORLD"
	menu_card.card_subtitle = "%s · Bunker %s · %s · %s" % [world.name, world.bunker, world.character, world.last]

	var card: Control = get_node("ContinueCard") as Control
	var last_played: Label = card.get_node("LastPlayed") as Label
	last_played.text = "LAST PLAYED · " + str(world.last).to_upper()
	var world_title: Label = card.get_node("WorldTitle") as Label
	world_title.text = str(world.name)
	var difficulty: Label = card.get_node("Difficulty") as Label
	difficulty.text = str(world.difficulty)
	var values: Array[String] = [str(world.bunker), str(world.character), str(world.playtime)]
	var stat_values: Array[Node] = [
		card.get_node("Stats/BunkerValue"),
		card.get_node("Stats/CharacterValue"),
		card.get_node("Stats/PlaytimeValue")
	]
	for index in range(stat_values.size()):
		(stat_values[index] as Label).text = values[index]

	var continue_action: Button = get_node("ContinueAction") as Button
	continue_action.text = "ENTER   CONTINUE · " + str(world.name)


func _wire_actions() -> void:
	_wire_button(get_node("Header/SwitchAccount") as Button, Callable(self, "_switch_account"))

	var menu_callbacks: Array[Callable] = [
		Callable(self, "_continue_world"),
		Callable(self, "_open_saves"),
		Callable(self, "_open_join_friend"),
		Callable(self, "_open_settings"),
		Callable(self, "_open_extras"),
		Callable(self, "_quit_to_desktop")
	]
	var menu_rows: Array[Node] = [
		get_node("MenuContinue"),
		get_node("MenuPlay"),
		get_node("MenuJoinFriend"),
		get_node("MenuSettings"),
		get_node("MenuExtras"),
		get_node("MenuQuit")
	]
	for index in range(menu_rows.size()):
		var menu_card := menu_rows[index] as ZMenuActionCard
		if not menu_card.activated.is_connected(menu_callbacks[index]):
			menu_card.activated.connect(menu_callbacks[index])
		menu_entries.append(menu_card.get_focus_target())

	var card: Control = get_node("ContinueCard") as Control
	_wire_button(card.get_node("ManageSaves") as Button, Callable(self, "_open_saves"))
	_wire_button(get_node("FriendKevin/Action") as Button, Callable(self, "_join_kevin"))
	_wire_button(get_node("FriendDenz/Action") as Button, Callable(self, "_request_denz"))
	_wire_button(get_node("FriendMara/Hit") as Button, Callable(self, "_open_join_friend"))
	_wire_button(get_node("FriendCode/JoinByCode") as Button, Callable(self, "_open_join_code"))
	_wire_button(get_node("ContinueAction") as Button, Callable(self, "_continue_world"))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if button is CommonButton:
		var common_button := button as CommonButton
		if not common_button.triggered.is_connected(callback):
			common_button.triggered.connect(callback)
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


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


func _build_focus_graph() -> void:
	if menu_entries.is_empty():
		return
	for index in range(menu_entries.size()):
		var previous: Button = menu_entries[posmod(index - 1, menu_entries.size())]
		var next: Button = menu_entries[(index + 1) % menu_entries.size()]
		menu_entries[index].focus_neighbor_top = menu_entries[index].get_path_to(previous)
		menu_entries[index].focus_neighbor_bottom = menu_entries[index].get_path_to(next)
	menu_entries[0].grab_focus()
