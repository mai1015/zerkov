extends "res://ui/screens/frontflow/frontflow_actions.gd"

## Authored worlds/saves screen controller.
##
## The fixed desktop layout, row templates, form controls, and action buttons
## live in saves.tscn. This script refreshes local mock state, connects those
## authored controls to the existing front-flow callbacks, and leaves compact
## reflow to the inherited implementation.

const WORLD_ROW_COUNT: int = 8

func build() -> void:
	reset_adaptive_layout()
	active_route = str(app.current_route)

	var worlds: Array[Dictionary] = _worlds()
	var selected_value: Variant = app.fixture_get("frontflow_selected_world", 0)
	selected_world = clampi(int(selected_value), 0, maxi(0, worlds.size() - 1))
	_populate_screen(worlds)
	_install_authored_scale_safe_styles()
	_wire_actions()
	_build_focus_graph(worlds)
	queue_adaptive_layout()


func _populate_screen(worlds: Array[Dictionary]) -> void:
	var mode: String = _state_string("frontflow_save_tab", "worlds")
	var my_worlds: Button = get_node("MyWorldsTab") as Button
	my_worlds.text = "MY WORLDS  %d" % worlds.size()
	_set_tab_state(my_worlds, mode == "worlds")
	_set_tab_state(get_node("JoinFriendTab") as Button, false)
	_set_tab_state(get_node("JoinCodeTab") as Button, false)

	var summary: Label = get_node("SlotSummary") as Label
	summary.text = "%d / 8 slots · a world = bunker + stash + character" % worlds.size()

	var content: Control = get_node("WorldList/Content") as Control
	var content_height: float = float(worlds.size() * 112 + 84)
	content.custom_minimum_size = Vector2(1248, content_height)
	content.size = Vector2(1264, content_height)
	var row_width: float = 1248.0 if worlds.size() > 6 else 1264.0
	for index in range(WORLD_ROW_COUNT):
		var row: ZWorldRow = get_node("WorldList/Content/WorldRow%d" % (index + 1)) as ZWorldRow
		row.position = Vector2(0, index * 112)
		row.size = Vector2(row_width, 98)
		row.visible = index < worlds.size()
		row.disabled = not row.visible
		if row.visible:
			row.world = worlds[index]
			row.index = index
			row.selected = index == selected_world

	var new_row: ZNewWorldRow = get_node("WorldList/Content/NewWorldRow")
	new_row.position = Vector2(0, worlds.size() * 112)
	new_row.size = Vector2(row_width, 68)
	new_row.disabled = worlds.size() >= WORLD_ROW_COUNT

	var form: Panel = get_node("NewWorldForm") as Panel
	form.visible = true
	world_name_field = form.get_node("WorldName") as LineEdit
	world_seed_field = form.get_node("WorldSeed") as LineEdit
	world_name_field.text = _state_string("frontflow_new_world_name", "Rust belt")
	world_seed_field.text = _state_string("frontflow_new_seed", "ZK-4A91-KX")
	var name_field: LineEdit = world_name_field
	var seed_field: LineEdit = world_seed_field
	(get_node("NewWorldForm/NameCount") as Label).text = "%d / 24" % name_field.text.length()
	_set_segment_state(get_node("NewWorldForm/StandardDifficulty") as Button, _state_string("frontflow_new_difficulty", "STANDARD") == "STANDARD")
	_set_segment_state(get_node("NewWorldForm/HardcoreDifficulty") as Button, _state_string("frontflow_new_difficulty", "STANDARD") == "HARDCORE", U.RED)
	var join_mode: String = _state_string("frontflow_new_join_mode", "INVITE ONLY")
	_set_segment_state(get_node("NewWorldForm/ClosedJoin") as Button, join_mode == "CLOSED")
	_set_segment_state(get_node("NewWorldForm/InviteJoin") as Button, join_mode == "INVITE ONLY")
	_set_segment_state(get_node("NewWorldForm/FriendsJoin") as Button, join_mode == "FRIENDS")
	var max_players: String = _state_string("frontflow_new_max_players", "4")
	for index in range(4):
		_set_segment_state(get_node("NewWorldForm/MaxPlayers%d" % (index + 1)) as Button, max_players == str(index + 1))

	var load_button: Button = get_node("LoadSelected") as Button
	var selected_name: String = str(worlds[selected_world].get("name", "WORLD")) if not worlds.is_empty() else "CREATE YOUR FIRST WORLD"
	load_button.text = "ENTER   LOAD · " + selected_name
	load_button.disabled = worlds.is_empty()
	var rename_button: Button = get_node("RenameWorld") as Button
	var duplicate_button: Button = get_node("DuplicateWorld") as Button
	var delete_button: Button = get_node("DeleteWorld") as Button
	rename_button.disabled = worlds.is_empty()
	duplicate_button.disabled = worlds.is_empty() or worlds.size() >= WORLD_ROW_COUNT
	delete_button.disabled = worlds.is_empty()


func _set_tab_state(button: Button, active: bool) -> void:
	if button == null:
		return
	var active_style: Variant = button.get_meta("active_style", null)
	var inactive_style: Variant = button.get_meta("inactive_style", null)
	if active and active_style is StyleBox:
		button.add_theme_stylebox_override("normal", active_style)
	elif not active and inactive_style is StyleBox:
		button.add_theme_stylebox_override("normal", inactive_style)
	button.add_theme_color_override("font_color", U.TEXT if active else U.MUTED)


func _set_segment_state(button: Button, active: bool, accent: Color = U.TEXT) -> void:
	if button == null:
		return
	var active_style: Variant = button.get_meta("active_style", null)
	var inactive_style: Variant = button.get_meta("inactive_style", null)
	var hover_style: Variant = button.get_meta("hover_style", null)
	var red_hover_style: Variant = button.get_meta("red_hover_style", null)
	if active and active_style is StyleBox:
		button.add_theme_stylebox_override("normal", active_style)
	elif not active and inactive_style is StyleBox:
		button.add_theme_stylebox_override("normal", inactive_style)
	if hover_style is StyleBox:
		button.add_theme_stylebox_override("hover", red_hover_style if accent == U.RED and red_hover_style is StyleBox else hover_style)
	button.add_theme_color_override("font_color", U.CANVAS if active else U.MUTED)


func _wire_actions() -> void:
	_wire_button(get_node("Header/Back") as Button, Callable(self, "_back_to_menu"))
	_wire_button(get_node("MyWorldsTab") as Button, Callable(self, "_open_saves"))
	_wire_button(get_node("JoinFriendTab") as Button, Callable(self, "_open_join_friend"))
	_wire_button(get_node("JoinCodeTab") as Button, Callable(self, "_open_join_code"))

	for index in range(WORLD_ROW_COUNT):
		var row: ZWorldRow = get_node("WorldList/Content/WorldRow%d" % (index + 1))
		if not row.activated.is_connected(_world_activated):
			row.activated.connect(_world_activated)
	var new_row: ZNewWorldRow = get_node("WorldList/Content/NewWorldRow")
	if not new_row.activated.is_connected(_new_world_hint):
		new_row.activated.connect(_new_world_hint)

	var form: Panel = get_node("NewWorldForm") as Panel
	_wire_button(form.get_node("StandardDifficulty") as Button, Callable(self, "_set_world_choice").bind("difficulty", "STANDARD"))
	_wire_button(form.get_node("HardcoreDifficulty") as Button, Callable(self, "_set_world_choice").bind("difficulty", "HARDCORE"))
	_wire_button(form.get_node("ClosedJoin") as Button, Callable(self, "_set_world_choice").bind("join_mode", "CLOSED"))
	_wire_button(form.get_node("InviteJoin") as Button, Callable(self, "_set_world_choice").bind("join_mode", "INVITE ONLY"))
	_wire_button(form.get_node("FriendsJoin") as Button, Callable(self, "_set_world_choice").bind("join_mode", "FRIENDS"))
	for index in range(4):
		_wire_button(form.get_node("MaxPlayers%d" % (index + 1)) as Button, Callable(self, "_set_world_choice").bind("max_players", str(index + 1)))
	_wire_button(form.get_node("CreateAndEnter") as Button, Callable(self, "_create_world_pressed"))
	_wire_button(form.get_node("Cancel") as Button, Callable(self, "_back_to_menu"))

	var name_field: LineEdit = form.get_node("WorldName") as LineEdit
	var seed_field: LineEdit = form.get_node("WorldSeed") as LineEdit
	if not name_field.text_changed.is_connected(Callable(self, "_world_name_changed")):
		name_field.text_changed.connect(Callable(self, "_world_name_changed"))
	if not seed_field.text_changed.is_connected(Callable(self, "_world_seed_changed")):
		seed_field.text_changed.connect(Callable(self, "_world_seed_changed"))

	_wire_button(get_node("LoadSelected") as Button, Callable(self, "_load_selected_world"))
	_wire_button(get_node("RenameWorld") as Button, Callable(self, "_rename_world"))
	_wire_button(get_node("DuplicateWorld") as Button, Callable(self, "_duplicate_world"))
	_wire_button(get_node("DeleteWorld") as Button, Callable(self, "_delete_world"))


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _build_focus_graph(worlds: Array[Dictionary]) -> void:
	var focus_nodes: Array[Button] = []
	for index in range(worlds.size()):
		if index >= WORLD_ROW_COUNT:
			break
		focus_nodes.append(get_node("WorldList/Content/WorldRow%d" % (index + 1)).get_focus_target())
	var new_world_hit := get_node("WorldList/Content/NewWorldRow").get_focus_target() as Button
	if not new_world_hit.disabled:
		focus_nodes.append(new_world_hit)
	for index in range(focus_nodes.size()):
		var current: Button = focus_nodes[index]
		var previous: Button = focus_nodes[posmod(index - 1, focus_nodes.size())]
		var next: Button = focus_nodes[(index + 1) % focus_nodes.size()]
		current.focus_neighbor_top = current.get_path_to(previous)
		current.focus_neighbor_bottom = current.get_path_to(next)


func _world_activated(_world_id: String, index: int) -> void:
	_select_world(index)
