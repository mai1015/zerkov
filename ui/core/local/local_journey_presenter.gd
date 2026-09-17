class_name LocalJourneyPresenter
extends Node
## The authored screens keep their controllers and owners. This layer supplies
## consistent presentation and context after the existing live bindings update.
const Style = preload("res://ui/theme/local_journey_style.gd")
const BRIEFING = preload("res://ui/components/journey/briefing_card.tscn")
const RESULT = preload("res://ui/components/journey/result_card.tscn")
const MASTHEAD = preload("res://ui/components/journey/masthead.tscn")
const ROUTES := ["hud", "bunker", "inventory", "health", "stats", "maps", "tasks", "deploying", "summary_solo", "pause", "crafting", "build_mode", "session", "controls"]
var _screen: ZScreen
var _port: LocalGameUI
var _runtime: CharacterUIRuntime
var _epoch: int
var _route: String
var _canvas: Control
var _card: Control
var _masthead: Control
var _last_preparation: Dictionary = {}

func bind(screen: ZScreen, port: LocalGameUI) -> void:
	_screen = screen
	_port = port
	_epoch = screen.app.local_epoch()
	_route = screen.app.current_route
	_runtime = screen.app.character_runtime()
	if _route != "hud": Style.apply_screen(screen)
	# Management panels read cleanly against the same neutral shelter palette.
	# Keep the authored panels, their contents and input handlers intact.
	if _route != "bunker":
		for path: String in ["BackdropImage", "BackgroundImage", "BackdropArt", "BackgroundFrame", "Background"]:
			var image := screen.get_node_or_null(path) as CanvasItem
			if image is TextureRect: image.modulate = Color(0.48, 0.50, 0.46, 0.16)
		for path: String in ["BackdropShade", "BackdropDim", "BackdropTint", "DeployTint", "BackgroundShade", "Atmosphere"]:
			var shade := screen.get_node_or_null(path) as ColorRect
			if shade != null: shade.color = Color(0.03, 0.045, 0.05, 0.76)
	if _route in ["maps", "deploying", "summary_solo"]:
		# A real Control parent preserves the screen's visibility/input lifetime.
		# CanvasItems directly below a plain Node escape CanvasItem inheritance.
		_canvas = Control.new()
		_canvas.name = "JourneyOverlay"
		_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
		screen.add_child(_canvas)
		_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	match _route:
		"hud": _layout_hud()
		"maps": _layout_briefing()
		"deploying": _layout_loading()
		"summary_solo": _layout_result()
	port.changed.connect(refresh)
	if _runtime != null:
		_runtime.inventory_view_changed.connect(_inventory_changed)
		_runtime.health_view_changed.connect(_health_changed)
		_runtime.binding_invalidated.connect(_invalidated)
	refresh()
	# Existing bindings schedule their first value refresh while mounting.
	# Run after it, not before it, without polling or rebuilding the screen.
	refresh.call_deferred()

func refresh() -> void:
	if not is_instance_valid(_screen) or not _screen.is_inside_tree(): return
	var frame := _port.snapshot()
	if frame.is_empty() or frame.get("epoch") != _epoch: return
	_refresh_navigation(frame)
	match _route:
		"bunker":
			var preparation := _preparation()
			if preparation.ready:
				_text("BunkerHideoutView/LocalProfile", "%s  /  %d medical items" % [preparation.health, preparation.medical_items])
			if String(frame.get("error", "")).is_empty():
				_text("BunkerHideoutView/LocalNotice", "Prepare your loadout, review the operation, then deploy. Progress stays on this computer.")
		"maps": _refresh_briefing(frame)
		"deploying":
			_text("ZoneTitle", _operation_name().to_upper())
			_text("DeployStatus", "DEPLOYMENT / 02")
			_text("MissionDetails", "SUPPLY RUN  /  SOLO  /  " + String(frame.get("exit_title", "Road Gate")).to_upper())
			_text("DeployCenter/Phase", "PREPARING YOUR RAID")
			_text("DeployCenter/Waiting", "Saving deployment and loading the operation.")
			_text("DeployCenter/Value", "")
			_text("TipCard/Detail", "Bring supplies back through " + String(frame.get("exit_title", "Road Gate")) + ". Death or abandonment loses unsecured equipment.")
		"summary_solo": _refresh_result(frame)
		"pause":
			_text("ActionsPanel/Subtitle", "RAID PAUSED" if frame.mode == "raid" else "BUNKER MENU")

func _refresh_navigation(frame: Dictionary) -> void:
	var chrome := _screen.get_node_or_null("NavigationChrome") as ZNavigationChrome
	if chrome != null:
		chrome.level_text = "SOLO / LOCAL"
		chrome.money_text = ""
		var tasks := _screen.app.task_view()
		chrome.task_count = tasks.tasks().size() if tasks != null and tasks.is_ready() else 0
		_text("NavigationChrome/Maps", "FIELD MAP" if frame.mode == "raid" else "BRIEFING")
		_text("NavigationChrome/Settings", "CONTROLS")
		var back := "BACK"
		if frame.mode == "home":
			back = "BRIEFING" if frame.get("preparation_return", "") == "maps" and _route in ["inventory", "health", "stats"] else "BUNKER"
		elif frame.mode == "raid": back = "RAID"
		var close := chrome.get_node("Close") as Button
		close.text = "ESC / " + back
		close.position.x = 1672
		close.size.x = 200
		(chrome.get_node("Level") as Control).position.x = 1460
		(chrome.get_node("Level") as Control).size.x = 196
		for name: String in ["Money"]: (chrome.get_node(name) as CanvasItem).hide()
		for name: String in ["CharacterUnderline", "MapsUnderline", "TasksUnderline", "SettingsUnderline"]:
			(chrome.get_node(name) as ColorRect).color = Style.ACCENT
		Style.button(close)

func _layout_briefing() -> void:
	# Keep the map and zone detail composition. Retire fake history and locked
	# sample zones, using the existing left column for actual preparation.
	for index in range(1, 5):
		for prefix: String in ["ZoneCard", "ZoneHit", "ZoneName", "ZoneRisk", "ZoneMeta", "ZoneTaskCount"]: _hide(prefix + str(index))
	for child: Node in _screen.get_children():
		var name := String(child.name)
		if name.begins_with("History") or name.begins_with("Squad") or name.begins_with("TimeButton"):
			if child is CanvasItem: child.hide()
	for path: String in ["RaidHistory", "ZoomLabel", "ZoomMinus", "ZoomPlus", "TimeOfDayTitle", "UninsuredValue", "LoadoutValue", "ZoneRisk0", "ZoneTaskCount0"]: _hide(path)
	_place("ZonesTitle", Rect2(48, 86, 280, 36), 24)
	_place("ZonesNote", Rect2(312, 94, 136, 24), 11)
	_place("ZoneName0", Rect2(64, 146, 368, 28), 22)
	_place("ZoneMeta0", Rect2(64, 178, 368, 24), 13)
	# Reuse the three live-map intent controls rather than revive the discarded
	# sample-zone column. Keep preparation and Edit Loadout focus unchanged.
	for index in range(3):
		_place("ZoneHit%d" % index, Rect2(64 + index * 122, 210, 116, 32), 12)
		(_screen.get_node("ZoneHit%d" % index) as Button).show()
	_place("RegionTitle", Rect2(488, 86, 520, 36), 24)
	_place("RegionNote", Rect2(1128, 94, 224, 24), 11)
	_place("RegionCanvas", Rect2(488, 134, 864, 834))
	_place("ZoneDetailsHero", Rect2(1392, 134, 480, 170))
	_place("ZoneDetailsTitle", Rect2(1416, 246, 432, 42), 32)
	_place("ZoneDetailsRisk", Rect2(1416, 153, 432, 22), 12)
	_place("ZoneDetailsSummary", Rect2(1416, 328, 432, 96), 16)
	for index in range(5):
		_place("MapInfoLabel%d" % index, Rect2(1416, 450 + index * 36, 128, 28), 12)
		_place("MapInfoValue%d" % index, Rect2(1556, 450 + index * 36, 292, 28), 15)
		_place("MapInfoRule%d" % index, Rect2(1416, 482 + index * 36, 432, 1))
	_place("ZoneTasksTitle", Rect2(1416, 667, 432, 28), 17)
	_place("MapTaskPanel0", Rect2(1416, 706, 432, 164))
	_place("MapTaskName0", Rect2(1434, 724, 396, 30), 22)
	_place("MapTaskMeta0", Rect2(1434, 766, 396, 82), 15)
	_hide("MapTaskStatus0")
	_hide("MapTaskHit0")
	if _port.snapshot().get("mode") == "home":
		_card = BRIEFING.instantiate()
		_canvas.add_child(_card)
		_wire(_card.get_node("EditLoadout"), &"loadout")
		_wire(_card.get_node("InspectHealth"), &"health")
		var edit := _card.get_node("EditLoadout") as Button
		var health := _card.get_node("InspectHealth") as Button
		var deploy := _screen.get_node("Deploy") as Button
		edit.focus_neighbor_right = edit.get_path_to(health)
		health.focus_neighbor_left = health.get_path_to(edit)
		edit.focus_neighbor_bottom = edit.get_path_to(deploy)
		health.focus_neighbor_bottom = health.get_path_to(deploy)
		deploy.focus_neighbor_top = deploy.get_path_to(edit)
		# Opening a briefing must not make an accidental second Enter deploy.
		_focus_edit.call_deferred()
	_note("MapLegend", "AMBER / OBJECTIVES     GREEN / EXTRACTION     WHITE / YOU", Rect2(512, 984, 810, 28))
	_note("DeploymentRisk", "Unsecured equipment is lost on death or abandonment.", Rect2(1416, 894, 432, 64))

func _refresh_briefing(frame: Dictionary) -> void:
	_text("ZonesTitle", "OPERATION / 01")
	_text("ZonesNote", "SOLO / LOCAL")
	_text("RegionTitle", _operation_name().to_upper())
	_text("RegionNote", "TACTICAL OVERVIEW")
	_text("ZoneDetailsTitle", "SUPPLY RUN")
	var map_id := String(frame.get("map_id", "sawmill"))
	var exit_title := String(frame.get("exit_title", "Road Gate"))
	_text("ZoneName0", _operation_name().to_upper())
	_text("ZoneMeta0", "15:00 / SOLO / " + exit_title.to_upper())
	var map_ids := ["sawmill", "northline", "blackwater"]
	for index in range(map_ids.size()):
		var button := _screen.get_node("ZoneHit%d" % index) as Button
		button.text = String(map_ids[index]).to_upper()
		button.tooltip_text = SupplyRunGraph.title_for(map_ids[index])
		button.disabled = frame.mode != "home" or not String(frame.get("error", "")).is_empty()
		Style.button(button, map_id == map_ids[index])
		button.add_theme_font_size_override("font_size", 12)
	_text("ZoneDetailsSummary", "Search the three marked crates, retain the supplies and extract through " + exit_title + ".")
	_text("MapInfoLabel4", "OBJECTIVE")
	_text("MapTaskMeta0", "Search 3 marked caches; retain supplies.\nHold " + exit_title + " for 5 seconds.")
	# The original binding updates these values before this callback, so hide
	# retired sections again without rebuilding controls or stealing focus.
	for path: String in ["SquadTitle", "SquadPanel", "MapTaskStatus0", "LoadoutValue", "UninsuredValue"]: _hide(path)
	if _card == null: return
	_screen.default_focus = _screen.get_path_to(_card.get_node("EditLoadout"))
	var preparation := _preparation()
	if preparation != _last_preparation:
		_last_preparation = preparation
		var equipment: Array = preparation.equipment
		var visible_names := PackedStringArray()
		for index in range(mini(4, equipment.size())): visible_names.append(String(equipment[index]))
		var names := "\n".join(visible_names)
		if equipment.size() > 4: names += "\n+ %d more in equipment" % (equipment.size() - 4)
		_set_label(_card, "Equipment", ("Nothing equipped" if names.is_empty() else names) if preparation.equipment_ready else "Equipment unavailable")
		_set_label(_card, "Health", preparation.health)
		_set_label(_card, "Ammo", str(preparation.loose_rounds) if preparation.ready else "—")
		_set_label(_card, "Meds", str(preparation.medical_items) if preparation.ready else "—")
		var warnings := PackedStringArray(preparation.warnings)
		_set_label(_card, "Advisory", "\n".join(warnings) if not warnings.is_empty() else "Reserve rounds exclude loaded ammunition. Medical supplies include your secure storage.")
		(_card.get_node("Advisory") as Label).add_theme_color_override("font_color", Style.ACCENT if not warnings.is_empty() else Style.MUTED)
	var map_error := String(frame.get("map_error", ""))
	var error := String(frame.get("error", ""))
	if not map_error.is_empty(): error = "Map unavailable: " + map_error
	if not error.is_empty():
		_set_label(_card, "Advisory", ("Map preflight failed. Your gear has not been deployed.\n\n" if not map_error.is_empty() else "Your loadout could not be saved. Return to the bunker to retry.\n\n") + error)
		(_card.get_node("Advisory") as Label).add_theme_color_override("font_color", Style.DANGER)
		_last_preparation = {} # Refresh normal guidance after a successful retry.
	for name: String in ["EditLoadout", "InspectHealth"]:
		(_card.get_node(name) as Button).disabled = frame.mode != "home" or frame.get("home_available") != true

func _layout_hud() -> void:
	# Small readability plates, not the management shell over gameplay.
	for entry: Array in [["TimerGroup", Rect2(676, 16, 568, 94)], ["FeedGroup", Rect2(1468, 32, 408, 98)],
		["VitalsGroup", Rect2(40, 948, 390, 86)], ["WeaponGroup", Rect2(1710, 880, 166, 154)]]:
		var group := _screen.get_node(entry[0]) as Control
		var plate := Panel.new()
		plate.name = "JourneyPlate"
		plate.position = entry[1].position
		plate.size = entry[1].size
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plate.add_theme_stylebox_override("panel", Style.panel(Color(0.04, 0.07, 0.07, 0.84)))
		group.add_child(plate)
		group.move_child(plate, 0)
	_place("TimerGroup/Extract", Rect2(696, 64, 528, 38), 12)
	_place("FeedGroup/TaskText", Rect2(1484, 62, 376, 54), 14)
	_hide("FeedGroup/TaskKind")
	var title := Label.new()
	title.name = "OperationTitle"
	title.text = _operation_name().to_upper()
	title.position = Vector2(1484, 42)
	title.size = Vector2(376, 24)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_override("font", Style.MONO)
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Style.ACCENT)
	_screen.get_node("FeedGroup").add_child(title)

func _layout_loading() -> void:
	_masthead = MASTHEAD.instantiate()
	_canvas.add_child(_masthead)
	_place("DeployStatus", Rect2(48, 86, 640, 24), 12)
	_place("ZoneTitle", Rect2(48, 124, 1050, 70), 48)
	_place("MissionDetails", Rect2(48, 206, 1050, 28), 16)
	for name: String in ["SquadLabel", "SquadOak", "SquadKevin", "SquadOyo"]: _hide(name)
	_place("DeployCenter", Rect2(488, 410, 864, 250))
	(_screen.get_node("DeployCenter") as Panel).add_theme_stylebox_override("panel", Style.panel())
	_place("DeployCenter/Phase", Rect2(32, 40, 800, 44), 30)
	_place("DeployCenter/Waiting", Rect2(32, 114, 800, 80), 18)
	_hide("DeployCenter/Progress")
	_hide("DeployCenter/Value")
	_set_label(_masthead, "Stage", "01  PREPARE     /     [02  DEPLOY]     /     03  RETURN")
	for name: String in ["TaskCard", "ExtractsCard", "TipCard"]:
		var card := _screen.get_node(name) as Control
		card.position.y = 856
		card.size.y = 176
		_place(name + "/Title", Rect2(20, 14, card.size.x - 40, 26), 13)
		_place(name + "/Name", Rect2(20, 48, card.size.x - 40, 28), 20)
		_place(name + "/Detail", Rect2(20, 84 if name == "TaskCard" else 54, card.size.x - 40, 78), 15)

func _layout_result() -> void:
	_masthead = MASTHEAD.instantiate()
	_canvas.add_child(_masthead)
	_set_label(_masthead, "Stage", "01  PREPARE     /     02  DEPLOY     /     [03  RETURN]")
	_hide("VerdictDot")
	_place("Verdict", Rect2(48, 86, 1040, 28), 16)
	_place("MapName", Rect2(48, 126, 1040, 62), 42)
	_place("Subtitle", Rect2(48, 198, 1040, 28), 15)
	var names := ["MetricLoot", "MetricXP", "MetricKills", "MetricDamage"]
	for index in range(names.size()):
		_place(names[index], Rect2(1140 + index * 183, 116, 178, 102))
		var metric := _screen.get_node(names[index]) as Control
		for child: Node in metric.get_children():
			if child is Label:
				child.size.x = 170
				if child.name == &"Title":
					child.add_theme_font_size_override("font_size", 11)
					child.size.x = 150
				elif child.name == &"Value":
					child.position.y = 40
					child.add_theme_font_size_override("font_size", 28)
				elif child.name == &"Detail": child.hide()
	_card = RESULT.instantiate()
	_canvas.add_child(_card)
	_place("LootTitle", Rect2(648, 236, 620, 30), 22)
	_hide("LootTrailing")
	for index in range(9):
		_place("LootName%02d" % index, Rect2(680, 284 + index * 59, 468, 42), 16)
		_place("LootValue%02d" % index, Rect2(1168, 284 + index * 59, 184, 42), 14)
	_place("TaskPanel", Rect2(1392, 279, 480, 136))
	_place("HealthPanel", Rect2(1392, 435, 480, 166))
	for path: String in ["TaskPanel/Detail", "HealthPanel/Detail"]: _place(path, Rect2(20, 57, 440, 92), 16)
	_place("FooterHint", Rect2(48, 998, 1220, 36), 14)
	for index in range(2):
		_place("UsedName%02d" % index, Rect2(648, 861 + index * 47, 690, 34), 14)
		_hide("UsedState%02d" % index)
		_hide("UsedItem%02d" % index)

func _refresh_result(frame: Dictionary) -> void:
	var summary := _screen.app.summary_view()
	var committed: bool = frame.get("mode") == "summary" and summary != null and summary.is_ready()
	var outcome := "SAVE PENDING"
	var detail := "Your result has not been saved. Retry the local save before continuing."
	var kept := 0
	var lost := 0
	var elapsed := "—"
	if committed:
		outcome = {"extracted":"EXTRACTED", "dead":"KILLED IN ACTION", "abandoned":"RAID ABANDONED", "timeout":"TIME EXPIRED"}.get(frame.summary.get("outcome"), "RAID ENDED")
		detail = "You made it out. Your retained equipment and supplies are saved." if summary.outcome() == SummaryView.Outcome.EXTRACTED else "The raid is over. Review what was retained and lost before returning home."
		for line: SummaryView.LootLine in summary.loot():
			if line.disposition() == SummaryView.LootDisposition.RETAINED: kept += line.quantity()
			else: lost += line.quantity()
		if summary.audit_available():
			var seconds := summary.duration_ticks() / 60
			elapsed = "%02d:%02d" % [seconds / 60, seconds % 60]
	_text("Verdict", "RAID DEBRIEF / " + outcome)
	_text("Subtitle", "SUPPLY RUN  /  " + ((elapsed + " IN RAID" if elapsed != "—" else "RAID TIME NOT RECORDED") if committed else "LOCAL SAVE NEEDS ATTENTION"))
	_text("MetricLoot/Title", "ITEMS RETAINED")
	_text("MetricLoot/Value", str(kept) if committed else "—")
	_text("MetricXP/Title", "ITEMS LOST")
	_text("MetricXP/Value", str(lost) if committed else "—")
	_text("LootTitle", "RETAINED & LOST")
	_text("UsedTitle", "LOCAL SAVE")
	_text("UsedTrailing", "")
	_text("UsedName00", "Result saved on this computer." if committed else "Save pending. Retry before returning to the bunker.")
	_text("UsedName01", "Returning to the bunker will not apply the result again.")
	_text("FooterHint", "Review your equipment at home before the next raid." if committed else String(frame.get("notice", "Save pending")))
	_set_label(_card, "Outcome", outcome)
	_set_label(_card, "Detail", detail)
	_set_label(_card, "Duration", elapsed)
	_set_label(_card, "Objective", ("COMPLETED" if frame.summary.get("task", {}).get("completion_token", false) else "NOT COMPLETED") if committed else "PENDING")
	_set_label(_card, "NextTitle", "BACK TO THE BUNKER" if committed else "SAVE BEFORE CONTINUING")
	_set_label(_card, "Next", "Body and survival resources recover at home. Lost equipment is not replaced." if committed else "Your campaign has not acknowledged this result. Retry the save; no successful outcome is assumed.")
	(_card.get_node("Outcome") as Label).add_theme_color_override("font_color", Style.ACCENT if committed and outcome == "EXTRACTED" else Style.DANGER)
	_hide("LootTrailing")
	(_screen.get_node("Verdict") as Label).add_theme_color_override("font_color", Style.ACCENT if outcome == "EXTRACTED" else Style.DANGER)
	_text("HealthPanel/Detail", "Body and survival resources recover at home. Lost equipment is not restored.")
	for index in range(9):
		_hide("LootItem%02d" % index)
		if committed and index < summary.loot().size():
			var line: SummaryView.LootLine = summary.loot()[index]
			var name := line.display_name()
			if line.content_id() == ZerkovInventoryCatalog.ITEM_AKM: name = "AKM"
			elif line.content_id() == ZerkovInventoryCatalog.ITEM_AMMO_762: name = "7.62×39 mm"
			_text("LootName%02d" % index, name + " ×" + str(line.quantity()))
			(_screen.get_node("LootValue%02d" % index) as Label).add_theme_color_override("font_color", Style.ACCENT if line.disposition() == SummaryView.LootDisposition.RETAINED else Style.DANGER)

func _preparation() -> Dictionary:
	return LocalPreparationView.from_views(_runtime.inventory_view(&"raid") if is_instance_valid(_runtime) else null,
		_runtime.health_view() if is_instance_valid(_runtime) else null, _port.snapshot().get("home_equipment", {}))

func _operation_name() -> String:
	var map := _screen.app.map_view()
	return map.display_name() if map != null and map.is_ready() else "Operation unavailable"

func _focus_edit() -> void:
	if is_instance_valid(_screen) and _screen.accepts_input() and _card != null:
		(_card.get_node("EditLoadout") as Control).grab_focus()

func _request(command: StringName) -> void:
	if _screen.accepts_input() and _screen.app.local_game_ui() == _port: _port.request(command, _epoch)

func _wire(button: Button, command: StringName) -> void:
	button.connect("triggered" if button.has_signal("triggered") else "pressed", _request.bind(command))
	Style.button(button)

func _text(path: String, value: String) -> void:
	_set_label(_screen, path, value)

func _set_label(parent: Node, path: String, value: String) -> void:
	var target := parent.get_node_or_null(path)
	if target is Label or target is Button:
		if target.text != value: target.text = value

func _hide(path: String) -> void:
	var node := _screen.get_node_or_null(path) as CanvasItem
	if node != null: node.hide()

func _place(path: String, rect: Rect2, font_size: int = 0) -> void:
	var node := _screen.get_node_or_null(path) as Control
	if node == null: return
	# Set wrapping/font first: an old unwrapped Label's minimum width otherwise
	# prevents the requested size from shrinking to the authored panel bounds.
	if node is Label:
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if font_size > 0: node.add_theme_font_size_override("font_size", font_size)
	node.position = rect.position
	node.size = rect.size

func _note(name: String, text: String, rect: Rect2) -> void:
	var label := Label.new()
	label.name = name
	label.text = text
	label.position = rect.position
	label.size = rect.size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_override("font", Style.MONO)
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Style.MUTED)
	_canvas.add_child(label)

func _inventory_changed(_scope: StringName, _view: InventoryView) -> void:
	refresh()
func _health_changed(_view: HealthView) -> void:
	refresh()
func _invalidated(_reason: StringName) -> void:
	refresh()

func _exit_tree() -> void:
	if is_instance_valid(_port) and _port.changed.is_connected(refresh): _port.changed.disconnect(refresh)
	if is_instance_valid(_runtime):
		if _runtime.inventory_view_changed.is_connected(_inventory_changed): _runtime.inventory_view_changed.disconnect(_inventory_changed)
		if _runtime.health_view_changed.is_connected(_health_changed): _runtime.health_view_changed.disconnect(_health_changed)
		if _runtime.binding_invalidated.is_connected(_invalidated): _runtime.binding_invalidated.disconnect(_invalidated)
