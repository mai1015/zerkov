extends "res://ui/screens/bunker/bunker.gd"
## Retain the existing CommonActivatableScreen lifecycle and navigation owner.
## Replace only the desktop bunker presentation; other bunker-family routes
## and their feature gates remain unchanged. No fixture mutation is introduced.
const HIDEOUT = preload("res://game/presentation/bunker/bunker_hideout_view.tscn")

func build() -> void:
	if app.offline_bunker() != null:
		_build_local_bunker()
		return
	super.build()
	for child: Node in get_children():
		if child is CanvasItem:
			child.visible = false
	var view := get_node_or_null("BunkerHideoutView")
	if view == null:
		view = HIDEOUT.instantiate()
		add_child(view)
		view.menu_requested.connect(_on_menu)
	view.visible = true


func _build_local_bunker() -> void:
	for child: Node in get_children():
		if child is CanvasItem:
			child.hide()
	var view := get_node_or_null("BunkerHideoutView") as ZBunkerHideoutView
	if view == null:
		view = HIDEOUT.instantiate()
		add_child(view)
		view.menu_requested.connect(_on_menu)
		for node: Node in view.find_children("*", "Label", true, false):
			if node.text == "OFFLINE  /  VISUAL PREVIEW":
				node.text = "OFFLINE  /  LOCAL PROFILE"
			elif node.text == "Click a room or facility to inspect":
				node.hide()
		var stash := view.button("STASH / LOADOUT", Rect2(390, 1015, 230, 38))
		stash.name = "OpenLocalInventory"
		stash.pressed.connect(func(): go("inventory"))
		var settings := view.button("SETTINGS", Rect2(636, 1015, 140, 38))
		settings.name = "OpenLocalSettings"
		settings.pressed.connect(func(): go("settings"))
		var deploy := view.button("DEPLOY · LOCKED", Rect2(792, 1015, 230, 38))
		deploy.name = "OfflineDeploymentLocked"
		deploy.disabled = true
		deploy.tooltip_text = "No raid will be started in this milestone."
		var status := view.label("", Rect2(1110, 978, 690, 20), 11, view.MUTED)
		status.name = "LocalSaveStatus"
		app.offline_bunker().local_changed.connect(_sync_local_status)
	view.show()
	default_focus = get_path_to(view.get_node("OpenLocalInventory"))
	_sync_local_status()

func _sync_local_status() -> void:
	if not is_inside_tree() or app.offline_bunker() == null:
		return
	var state := app.offline_bunker().local_status()
	var label := get_node_or_null("BunkerHideoutView/LocalSaveStatus") as Label
	if label != null:
		label.text = "SAVED LOCALLY · REVISION %d" % int(state.save_generation) if state.error.is_empty() else "SAVE STATUS · " + String(state.error).replace("_", " ")
