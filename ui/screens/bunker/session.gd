extends "res://ui/screens/bunker/bunker_actions.gd"

## Authored session scene controller.
##
## The desktop surface is authored in session.tscn.  This controller keeps the
## stateful parts of the handoff (world metadata, occupancy, privacy, invite
## status and callbacks) in sync while retaining bunker.gd's compact layout and
## shared input behavior.

func build() -> void:
	reset_adaptive_layout()
	_bind_top_chrome()
	_route = str(app.current_route)
	if _route.is_empty():
		_route = "session"
	_ensure_state()
	_install_valid_styles()
	_bind_dynamic_data()
	_wire_actions()
	queue_adaptive_layout()


func _bind_dynamic_data() -> void:
	var worlds: Array = app.fixture_get("frontflow_worlds", [])
	var selected: int = int(app.fixture_get("frontflow_selected_world", 0))
	var world_name: String = "OAK'S BUNKER"
	if selected >= 0 and selected < worlds.size():
		world_name = str(worlds[selected].get("name", world_name)).to_upper()
	var privacy: String = str(app.fixture_get("bunker_privacy", "INVITE ONLY")).to_upper()
	var guest_present: bool = bool(app.fixture_get("bunker_guest_present", true))
	var max_players: int = _max_players()
	var player_count: int = 2 if guest_present else 1

	var chrome: ZTopChrome = get_node("TopChrome") as ZTopChrome
	chrome.title = world_name
	chrome.world_status = "■  WORLD %s · %s · %d / %d" % [
		"CLOSED" if privacy == "CLOSED" else "OPEN", privacy, player_count, max_players
	]

	var guest_sprite: Control = get_node("GuestSprite") as Control
	var guest_name: Control = get_node("GuestName") as Control
	guest_sprite.visible = guest_present
	guest_name.visible = guest_present
	var join_toast: Control = get_node("JoinToast") as Control
	join_toast.visible = guest_present
	(join_toast.get_node("Detail") as Label).text = "%d / %d · they arrive at the bunker door" % [player_count, max_players]

	var panel: Control = get_node("SessionPanel") as Control
	_update_privacy_segments(panel, privacy)
	var policy_copy: Dictionary = {
		"FRIENDS": "Friends can join while the world is open.",
		"CLOSED": "This world is closed to new guests.",
		"INVITE ONLY": "Friends: anyone on your list can walk in while the world is open."
	}
	(panel.get_node("Policy") as Label).text = str(policy_copy.get(privacy, "")) + " Progress they earn stays on their character; loot goes where they extract it."
	(panel.get_node("Occupancy") as Label).text = "IN THIS WORLD · %d / %d" % [player_count, max_players]
	(panel.get_node("Players/Guest") as Control).visible = guest_present
	(panel.get_node("Players/EmptySlot/Label") as Label).text = "□  %d EMPTY SLOTS · INVITE" % maxi(0, max_players - player_count)
	(panel.get_node("CodeRow/Code") as Label).text = str(app.fixture_get("bunker_code", "ZK-7F2Q"))

	var invited: Array = app.fixture_get("bunker_invited", [])
	for friend in [["Denz", "DENZ"], ["Pilgrim", "PILGRIM_88"], ["Soot", "SOOT"]]:
		var invite: Button = panel.get_node("FriendsBox/%s/Invite" % friend[0]) as Button
		invite.text = "INVITED" if invited.has(friend[1]) else "INVITE"


func _update_privacy_segments(panel: Control, privacy: String) -> void:
	for item in [["PrivacyClosed", "CLOSED"], ["PrivacyInviteOnly", "INVITE ONLY"], ["PrivacyFriends", "FRIENDS"]]:
		var segment: Panel = panel.get_node(item[0]) as Panel
		var selected: bool = privacy == item[1]
		segment.add_theme_stylebox_override("panel", U.style(TEXT if selected else Color.TRANSPARENT, TEXT if selected else Color(1.0, 1.0, 1.0, 0.14)))
		(segment.get_node("Label") as Label).add_theme_color_override("font_color", BG if selected else MUTED)


func _install_valid_styles() -> void:
	# Packed authored scenes cannot serialize PixelStyle's private source box.
	# Recreate the source boxes at runtime before the first frame so the static
	# hierarchy keeps the same fills and one-pixel rims as bunker.gd.
	for marker_name in ["StorageMarker", "MedicalMarker", "UtilitiesMarker", "AmmoMarker", "FoodMarker"]:
		_set_panel_style(get_node(marker_name) as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	_set_panel_style(get_node("JoinToast") as Panel, Color(0.027, 0.035, 0.035, 0.92), Color(0.37, 0.83, 0.42, 0.52))
	_set_panel_style(get_node("SessionPanel") as Panel, Color(0.027, 0.035, 0.035, 0.68), Color.TRANSPARENT)
	_set_panel_style(get_node("SessionPanel/Players") as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	for row_name in ["Host", "Guest"]:
		_set_panel_style(get_node("SessionPanel/Players/" + row_name) as Panel, Color.TRANSPARENT, Color(1.0, 1.0, 1.0, 0.08))
	_set_panel_style(get_node("SessionPanel/Players/EmptySlot") as Panel, Color.TRANSPARENT, Color.TRANSPARENT)
	_set_panel_style(get_node("SessionPanel/CodeRow") as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	_set_panel_style(get_node("SessionPanel/FriendsBox") as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	for friend_name in ["Denz", "Pilgrim", "Soot", "Mara", "Halvard"]:
		_set_panel_style(get_node("SessionPanel/FriendsBox/" + friend_name) as Panel, Color.TRANSPARENT, Color(1.0, 1.0, 1.0, 0.08))
	_set_panel_style(get_node("SessionPanel/SquadRules") as Panel, Color(0.027, 0.035, 0.035, 0.82), Color(1.0, 1.0, 1.0, 0.14))
	for privacy_name in ["PrivacyClosed", "PrivacyInviteOnly", "PrivacyFriends"]:
		_set_panel_style(get_node("SessionPanel/" + privacy_name) as Panel, Color.TRANSPARENT, Color(1.0, 1.0, 1.0, 0.14))
	_set_outlined_button(get_node("SessionPanel/NewCode") as Button)
	for friend_name in ["Denz", "Pilgrim", "Soot"]:
		_set_outlined_button(get_node("SessionPanel/FriendsBox/" + friend_name + "/Invite") as Button)


func _set_panel_style(panel: Panel, fill: Color, border: Color) -> void:
	if panel != null:
		panel.add_theme_stylebox_override("panel", U.style(fill, border))


func _set_outlined_button(button: Button) -> void:
	if button == null:
		return
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = Color.TRANSPARENT
	normal.border_color = Color(1.0, 1.0, 1.0, 0.38)
	normal.set_border_width_all(1)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(1.0, 1.0, 1.0, 0.08)
	hover.border_color = TEXT
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.91, 0.59, 0.18, 0.14)
	button.add_theme_stylebox_override("normal", U.scale_safe(normal))
	button.add_theme_stylebox_override("hover", U.scale_safe(hover))
	button.add_theme_stylebox_override("pressed", U.scale_safe(pressed))
	button.add_theme_stylebox_override("focus", U.scale_safe(hover))


func _wire_actions() -> void:
	var chrome: ZTopChrome = get_node("TopChrome")
	if not chrome.world_back_requested.is_connected(_on_world_back):
		chrome.world_back_requested.connect(_on_world_back)
	var privacy_closed := get_node("SessionPanel/PrivacyClosed/Hit") as Button
	var privacy_invite := get_node("SessionPanel/PrivacyInviteOnly/Hit") as Button
	var privacy_friends := get_node("SessionPanel/PrivacyFriends/Hit") as Button
	_wire_button(privacy_closed, Callable(self, "_on_privacy").bind("CLOSED"))
	_wire_button(privacy_invite, Callable(self, "_on_privacy").bind("INVITE ONLY"))
	_wire_button(privacy_friends, Callable(self, "_on_privacy").bind("FRIENDS"))
	mark_feature_action(privacy_closed, FEATURE_BUNKER)
	mark_feature_action(privacy_invite, FEATURE_BUNKER)
	mark_feature_action(privacy_friends, FEATURE_BUNKER)
	var empty_slot := get_node("SessionPanel/Players/EmptySlot/Hit") as Button
	var copy_code := get_node("SessionPanel/CodeRow/Copy") as Button
	var new_code := get_node("SessionPanel/NewCode") as Button
	var kick := get_node("SessionPanel/Players/Guest/Kick") as Button
	_wire_button(empty_slot, Callable(self, "_on_empty_slot"))
	_wire_button(copy_code, Callable(self, "_on_copy_code"))
	_wire_button(new_code, Callable(self, "_on_new_code"))
	_wire_button(kick, Callable(self, "_on_kick_guest"))
	mark_feature_action(empty_slot, FEATURE_FRIENDS)
	mark_feature_action(copy_code, FEATURE_FRIENDS)
	mark_feature_action(new_code, FEATURE_FRIENDS)
	mark_feature_action(kick, FEATURE_FRIENDS)
	for friend in [["Denz", "DENZ"], ["Pilgrim", "PILGRIM_88"], ["Soot", "SOOT"]]:
		var invite := get_node("SessionPanel/FriendsBox/%s/Invite" % friend[0]) as Button
		_wire_button(invite, Callable(self, "_on_invite").bind(friend[1]))
		mark_feature_action(invite, FEATURE_FRIENDS)


func _wire_button(button: Button, callback: Callable) -> void:
	if button == null or not callback.is_valid():
		return
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)


func _on_world_back() -> void:
	go("bunker")
