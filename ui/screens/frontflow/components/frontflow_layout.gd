extends RefCounted
const U = preload("res://ui/theme/tokens.gd")
const A = preload("res://ui/core/adaptive.gd")

var screen: Control

func _init(owner_screen: Control) -> void:
	screen = owner_screen

func _compact_rect(node: Control, bounds: Rect2) -> void:
	if node == null:
		return
	if node is Label:
		node.clip_text = true
	node.position = bounds.position
	node.size = bounds.size


func _compact_pane(bounds: Rect2, content_size: Vector2, pane_name: String) -> Control:
	var content: Control = A.pane(screen, bounds, content_size, pane_name)
	content.get_parent().horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	return content


func apply(view: Vector2) -> void:
	A.backdrop(screen, view)
	match screen.active_route:
		"title": _compact_title(view)
		"main_menu": _compact_menu(view)
		"saves": _compact_saves(view)
		"join_friend": _compact_join(view)
		"deploying": _compact_deploy(view)
		"pause": _compact_pause(view)


func _compact_title(view: Vector2) -> void:
	var logo: Control = screen.get_node("Logo")
	var logo_width: float = minf(1020, view.x - 160)
	_compact_rect(logo, Rect2((view.x - logo_width) / 2, view.y * 0.22, logo_width, logo_width * 203 / 1020))
	_compact_rect(screen.get_node("StartPrompt"), Rect2((view.x - 308) / 2, view.y - 170, 308, 36))
	for child in screen.get_children():
		if child is Control and child.position.y == 865:
			child.position += Vector2((view.x - 1920) / 2, view.y - 980)
		elif child is Control and child.position.y >= 1030:
			child.position.y += view.y - 1080
			if child.position.x > 1500:
				child.position.x += view.x - 1920


func _compact_header(view: Vector2) -> void:
	var header: Control = screen.get_node("Header")
	header.size.x = view.x
	for child in header.get_children():
		if child is Control:
			if child.position.x >= 1500:
				child.position.x += view.x - 1920
			elif child.position.x == 48:
				child.position.x = 24
	# The page tabs stay outside every content pane.
	for child in screen.get_children():
		if child is Button and child.position.y == 96:
			child.position += Vector2(-24, -24)
		elif child is ColorRect and child.position.y == 130:
			_compact_rect(child, Rect2(24, 108, view.x - 48, 1))


func _compact_menu(view: Vector2) -> void:
	_compact_header(view)
	var right_x: float = view.x - 480
	var menu_width: float = right_x - 48
	var menu: Control = _compact_pane(Rect2(24, 88, menu_width + 12, view.y - 144), Vector2(menu_width, 476), "MenuNavigation")
	var entries: Array = A.move_group(screen, "MenuNavigation", Vector2(48, 240), menu)
	for entry in entries:
		entry.size.x = menu_width
	var cards: Control = _compact_pane(Rect2(right_x, 80, 456, view.y - 172), Vector2(440, 566), "MenuWorlds")
	A.move_group(screen, "MenuWorlds", Vector2(1432, 92), cards)
	var continue_action: Button = screen.get_node("ContinueAction") as Button
	_compact_rect(continue_action, Rect2(right_x, view.y - 76, 440, 52))
	if screen._worlds().is_empty():
		continue_action.text = "CREATE YOUR FIRST WORLD"
	for child in screen.get_children():
		if child is Label and child.position.y == 1026:
			child.position += Vector2(-24, view.y - 1062)
	# Reparenting changes relative paths used for arrow-key navigation.
	for i in range(screen.menu_entries.size()):
		screen.menu_entries[i].focus_neighbor_top = screen.menu_entries[i].get_path_to(screen.menu_entries[posmod(i - 1, screen.menu_entries.size())])
		screen.menu_entries[i].focus_neighbor_bottom = screen.menu_entries[i].get_path_to(screen.menu_entries[(i + 1) % screen.menu_entries.size()])
	screen.menu_entries[0].grab_focus()


func _compact_detail(panel: Control, view: Vector2, pane_name: String) -> void:
	var left: float = (view.x - 536) / 2
	if panel.name == pane_name:
		panel.name = pane_name + "Content"
	var content: Control = _compact_pane(Rect2(left, 124, 536, view.y - 212), Vector2(520, 678), pane_name)
	var actions: Array = []
	for child in panel.get_children():
		if child is Button and child.position.y >= 874:
			actions.append(child)
	A.move_nodes(actions, screen, Vector2(-left, 874 - (view.y - 72)))
	panel.reparent(content, false)
	panel.position = Vector2.ZERO
	panel.size.y = 678
	# Its inputs and choices retain their original native-pixel geometry.
	if pane_name == "NewWorldForm":
		content.custom_minimum_size.y = 590
		panel.size.y = 590


func _compact_saves(view: Vector2) -> void:
	_compact_header(view)
	var form: Control = screen.get_node("NewWorldForm")
	var show_form: bool = screen._state_string("frontflow_compact_saves", "worlds") == "new"
	var section: Button = screen._copy_button(screen, "MY WORLDS" if show_form else "+ NEW WORLD", Rect2(view.x - 190, 72, 166, 34), Callable(screen, "_compact_section").bind("worlds" if show_form else "new"), not show_form)
	section.name = "CompactWorldSection"
	var list: ScrollContainer = screen.get_node("WorldList") as ScrollContainer
	list.name = "WorldList"
	list.visible = not show_form
	list.follow_focus = true
	_compact_rect(list, Rect2(24, 128, view.x - 48, view.y - 228))
	var rows: Control = list.get_child(0)
	var row_width: float = view.x - 64
	rows.custom_minimum_size.x = row_width
	rows.size.x = row_width
	for row in rows.get_children():
		row.size.x = row_width
		if row is ZWorldRow:
			row.layout_for(row_width, true)
	var actions: Array = []
	for child in screen.get_children():
		if child is Label and child.position.y == 108:
			child.visible = false
		elif child is Button and child.position.y == 980:
			actions.append(child)
	var x: float = 24
	for i in range(actions.size()):
		var width: float = view.x - 398 if i == 0 else [100, 122, 96][i - 1]
		_compact_rect(actions[i], Rect2(x, view.y - 76, width, 52))
		actions[i].visible = not show_form
		x += width + 10
	if show_form:
		_compact_detail(form, view, "NewWorldForm")
	else:
		form.visible = false


func _compact_join(view: Vector2) -> void:
	_compact_header(view)
	var detail: Control = screen.get_node("FriendDetail")
	var show_detail: bool = screen._state_string("frontflow_compact_join_friend", "friends") == "detail"
	var section: Button = screen._copy_button(screen, "FRIENDS LIST" if show_detail else "WORLD DETAILS", Rect2(view.x - 190, 72, 166, 34), Callable(screen, "_compact_section").bind("friends" if show_detail else "detail"))
	section.name = "CompactFriendSection"
	var invite: Control = screen.get_node("InviteBar")
	var list_nodes: Array = []
	for child in screen.get_children():
		if not child is Control or child == detail or child == section or child == invite:
			continue
		if child.position.y >= 146 and child.position.y < 700:
			list_nodes.append(child)
		elif child.position.x >= 982 and child.position.y >= 100 and child.position.y <= 108:
			child.visible = false
	if show_detail:
		for child in list_nodes:
			child.visible = false
		invite.visible = false
		_compact_detail(detail, view, "FriendDetail")
		return
	detail.visible = false
	_compact_rect(screen.friend_code_field, Rect2(24, 124, view.x - 222, 36))
	_compact_rect(screen.get_node("CodeButton"), Rect2(view.x - 186, 124, 162, 36))
	_compact_rect(screen.friend_code_error, Rect2(24, 163, view.x - 48, 18))
	for child in list_nodes:
		if child is Button and child.has_meta("front_filter"):
			child.position += Vector2(24 - 874, 38)
	var content: Control = _compact_pane(Rect2(24, 230, view.x - 48, view.y - 316), Vector2(view.x - 64, 526), "FriendList")
	var rows: Array = A.move_group(screen, "FriendList", Vector2(48, 192), content)
	for row in rows:
		if row is Panel:
			row.size.x = view.x - 64
			for child in row.get_children():
				if child is Button:
					child.position.x = row.size.x - child.size.x - 16
				elif child is Label:
					child.clip_text = true
					if child.position.y == 39:
						child.size.x = row.size.x - 250
	_compact_rect(invite, Rect2(24, view.y - 72, view.x - 48, 48))
	for child in invite.get_children():
		if child is Button:
			child.position.x += view.x - 1312
		elif child is Label:
			child.clip_text = true
			child.size.x = view.x - 248


func _compact_deploy(view: Vector2) -> void:
	var center: Control = screen.get_node("DeployCenter")
	center.position = Vector2((view.x - 720) / 2, view.y * 0.40)
	for child in screen.get_children():
		if child is Label and child.position.x >= 1662:
			child.position += Vector2(view.x - 1920, -24)
		elif child is Label and child.position.x == 48:
			child.position += Vector2(-24, -24)
	var content: Control = _compact_pane(Rect2(24, view.y - 156, view.x - 48, 132), Vector2(view.x - 64, 352), "DeploymentBriefing")
	var cards: Array = A.move_group(screen, "DeploymentBriefing", Vector2(48, 928), content)
	for i in range(cards.size()):
		var card: Control = cards[i]
		card.position = Vector2(0, i * 120)
		card.size.x = view.x - 64
		for child in card.get_children():
			if child is Label:
				child.size.x = card.size.x - 28


func _compact_pause(view: Vector2) -> void:
	var offset: Vector2 = Vector2((view.x - 864) / 2, maxf(24, (view.y - 429) / 2))
	var left: Control = _compact_pane(Rect2(offset, Vector2(436, view.y - offset.y - 24)), Vector2(420, 429), "PauseActions")
	A.move_group(screen, "PauseActions", Vector2(528, 326), left)
	var right: Control = _compact_pane(Rect2(offset + Vector2(444, 0), Vector2(436, view.y - offset.y - 24)), Vector2(420, 368), "PauseSession")
	A.move_group(screen, "PauseSession", Vector2(972, 326), right)
	var resume: Button = left.find_children("*", "Button", true, false)[0]
	resume.grab_focus()


# -----------------------------------------------------------------------------
# Shared native primitives used only by this screen family.
