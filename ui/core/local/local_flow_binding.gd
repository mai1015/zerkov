class_name LocalFlowBinding
extends Node
## Production-only binding for existing authored scenes. Preview controllers
## remain behind their existing explicit fixture gate; no fixture build runs here.
const ROUTES: Array[String] = ["title", "main_menu", "bunker", "deploying", "hud", "maps", "tasks", "summary_solo", "pause"]
var _screen: ZScreen
var _port: LocalGameUI
var _epoch: int = 0
var _map: LocalMapCanvas
var _commands: Dictionary = {}
var _hideout: ZBunkerHideoutView

static func supports(route: String) -> bool:
	return ROUTES.has(route)

func bind(screen: ZScreen, port: LocalGameUI) -> bool:
	if _screen != null or port == null or not supports(screen.app.current_route): return false
	_screen = screen; _port = port; _epoch = screen.app.local_epoch()
	for control: Node in screen.find_children("*", "BaseButton", true, false):
		(control as BaseButton).disabled = true
	# Suppress legacy prototype clocks and raw InputEvent mutation paths. The
	# real CommonUI logical registrations and button signals remain active.
	screen.set_process(false)
	screen.set_process_input(false)
	screen.set_process_unhandled_input(false)
	var chrome: Node = screen.get_node_or_null("NavigationChrome")
	if chrome != null:
		if chrome.has_signal("navigate_requested"): chrome.connect("navigate_requested", _navigate)
		if chrome.has_signal("back_requested"): chrome.connect("back_requested", _back)
		for button: Node in chrome.find_children("*", "BaseButton", true, false):
			if button.name != &"Insurance": (button as BaseButton).disabled = false
	var top: Node = screen.get_node_or_null("TopChrome")
	if top != null and top.has_signal("menu_requested"):
		top.connect("menu_requested", _send.bind(&"pause"))
		for button: Node in top.find_children("*", "BaseButton", true, false): (button as BaseButton).disabled = false
	if screen.app.current_route == "maps":
		var canvas := screen.get_node_or_null("RegionCanvas") as Control
		if canvas == null: return false
		for child in canvas.get_children():
			if child is CanvasItem: child.hide()
		_map = LocalMapCanvas.new()
		canvas.add_child(_map)
		_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if screen.app.current_route == "hud": screen.call("apply_local_combat", {})
	if screen.app.current_route == "bunker" and not _install_hideout(screen): return false
	port.changed.connect(refresh)
	refresh.call_deferred()
	return true

func refresh() -> void:
	if _screen == null or not is_instance_valid(_screen) or not _screen.is_inside_tree(): return
	var frame := _port.snapshot()
	if frame.is_empty() or int(frame.epoch) != _epoch:
		_screen.hide()
		return
	match _screen.app.current_route:
		"title":
			_text("ConnectionPrefix", "SAVE MODE")
			_text("ConnectionStatus", "LOCAL")
			_text("ConnectionRegion", "SOLO · STEAM CO-OP NOT ENABLED")
			_text("SignedInAs", "PROFILE")
			_text("AccountName", "LOCAL OPERATOR")
		"main_menu": _menu(frame)
		"bunker": _home(frame)
		"deploying": _deploy(frame)
		"hud": _hud(frame)
		"maps": _maps(frame)
		"tasks": _tasks(frame)
		"summary_solo": _summary(frame)
		"pause": _pause(frame)

func _menu(frame: Dictionary) -> void:
	_text("Header/Connection", "LOCAL SAVES")
	_text("Header/SignedIn", "PROFILE")
	_text("Header/AccountName", "LOCAL OPERATOR")
	_card("MenuContinue", "CONTINUE", "", &"", false)
	_show("MenuContinue", false)
	_show("MenuExtras", false)
	_show("ContinueAction", false)
	for entry: Array in [["MenuPlay", 240], ["MenuSettings", 340], ["MenuQuit", 440], ["MenuJoinFriend", 570]]:
		(_screen.get_node(entry[0]) as Control).position.y = entry[1]
	# The primary entry always leads into the playable campaign when it is safe.
	# Existing saves are continued, never overwritten or given starter gear again.
	var entry := primary_entry(frame)
	_card("MenuPlay", entry.title, entry.detail, entry.command, entry.enabled)
	var primary := _screen.get_node_or_null("MenuPlay") as Control
	if primary != null: primary.tooltip_text = entry.detail
	_card("MenuJoinFriend", "STEAM CO-OP", "Not enabled in this build", &"", false)
	_card("MenuSettings", "CONTROLS", "Keyboard / controller bindings", &"controls", true)
	_card("MenuExtras", "EXTRAS", "Unavailable in the first playable", &"", false)
	_card("MenuQuit", "QUIT", "Close the local application", &"quit", true)
	_text("ContinueCard/WorldTitle", entry.title if not entry.enabled \
		else ("LOCAL CAMPAIGN" if frame.has_profile else "NO LOCAL CAMPAIGN"))
	_text("ContinueCard/Difficulty", "OFFLINE · SOLO")
	_text("ContinueCard/LastPlayed", "PROFILE GENERATION %d" % frame.profile_generation)
	_text("ContinueCard/CloudStatus", "LOCAL ONLY · NO CLOUD SAVE")
	for path: String in ["ContinueCard/Stats", "Header/SwitchAccount", "ContinueCard/ManageSaves", "FriendsTitle", "FriendsSub", "FriendsRule", "FriendKevin", "FriendDenz", "FriendMara", "FriendCode", "PatchCard"]: _show(path, false)
	_button("ContinueAction", &"", "", false)
	# Saying the campaign is unavailable is not actionable on its own. The card
	# body is empty in that state, so spend it on the folder holding the save.
	if entry.enabled: _text("ContinueCard/CloudStatus", frame.notice)
	else: _blocked_location(String(frame.error), String(entry.detail), String(frame.get("save_location", "")))
	_focus("MenuPlay/Hit" if entry.enabled else "MenuSettings/Hit")


## The authored CloudStatus line is a single 220px strip, so a filesystem path
## clips at the card edge unread. Hand it the empty card body and let it wrap.
## Only the blocked path moves it; nothing here touches the save itself.
func _blocked_location(reason: String, detail: String, location: String) -> void:
	var card := _screen.get_node_or_null("ContinueCard") as Control
	var label := _screen.get_node_or_null("ContinueCard/CloudStatus") as Label
	if card == null or label == null: return
	# The reason has to stay readable here and not only on the disabled button,
	# and on its own it is not actionable, so the folder follows it. The button
	# already carries the full sentence, so the body keeps only what differs.
	label.text = "Cannot open the campaign: " + reason + "." if not reason.is_empty() else detail
	if not location.is_empty():
		var home := OS.get_environment("HOME")
		label.text += "\n\nTo start a new local game, move or remove the save in:\n" \
			+ (location if home.is_empty() or not location.begins_with(home) \
				else "~" + location.substr(home.length()))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.position = Vector2(14.0, 150.0)
	label.size = Vector2(maxf(card.size.x - 28.0, 1.0), maxf(card.size.y - 160.0, 1.0))

## Value-only decision; an error always wins over inconsistent availability flags.
## Exposed separately so the exact UI rule can be tested without writing a save.
static func primary_entry(frame: Dictionary) -> Dictionary:
	var reason := String(frame.get("error", ""))
	if not reason.is_empty():
		return {"title":"LOCAL SAVE UNAVAILABLE", "command":StringName(), "enabled":false,
			"detail":"Cannot open the campaign: " + reason + ". Existing save files were not replaced."}
	if frame.get("has_profile", false):
		return {"title":"CONTINUE LOCAL GAME", "command":&"continue", "enabled":true,
			"detail":"Open your saved campaign. Your existing loadout and progress are kept."}
	if frame.get("can_create", false):
		return {"title":"NEW LOCAL GAME", "command":&"create", "enabled":true,
			"detail":"Create a local campaign with starter equipment. No account or Steam connection required."}
	return {"title":"LOCAL SAVE UNAVAILABLE", "command":StringName(), "enabled":false,
		"detail":"Campaign data is unavailable. No new save was created. " + String(frame.get("notice", ""))}

## The same authored map serves the campaign and the isolated art preview.
## Retire the placeholder CanvasItems, not just their visible paint: the generic
## reflow pass must not resurrect its NavigationChrome or obsolete station UI.
func _install_hideout(screen: ZScreen) -> bool:
	var view := load("res://game/presentation/bunker/bunker_hideout_view.tscn").instantiate() as ZBunkerHideoutView
	if view == null: return false
	if not view.configure_campaign(_port.bunker_room(_epoch), _home_input_allowed):
		view.free()
		return false
	for child: Node in screen.get_children():
		if child is CanvasItem:
			screen.remove_child(child)
			child.queue_free()
	_hideout = view
	view.action_requested.connect(_send)
	view.menu_requested.connect(_send.bind(&"pause"))
	view.room_selected.connect(_remember_room)
	screen.add_child(view)
	return true

func _home_input_allowed() -> bool:
	return _screen != null and is_instance_valid(_screen) and _screen.app.accepts_input(_screen) 		and _screen.app.local_game_ui() == _port

func _remember_room(room: String) -> void:
	if _home_input_allowed(): _port.remember_bunker_room(room, _epoch)

func layout_home(viewport_size: Vector2) -> bool:
	if _hideout == null: return false
	var ratio := minf(viewport_size.x / 1920.0, viewport_size.y / 1080.0)
	_hideout.scale = Vector2.ONE * ratio
	_hideout.position = (viewport_size - Vector2(1920, 1080) * ratio) * 0.5
	return true

func _home(frame: Dictionary) -> void:
	if _hideout == null: return
	_hideout.present_home(frame)
	# Never advertise keys from a separate UI policy. Describe the same live
	# bindings that the existing CommonUI navigation actions consume.
	for entry: Array in [["LocalLoadout", ZerkovInputActions.UI_OPEN_INVENTORY, "STASH / LOADOUT"],
		["LocalDeploy", ZerkovInputActions.UI_OPEN_MAP, "RAID BRIEFING"],
		["LocalTasks", ZerkovInputActions.UI_OPEN_TASKS, "TASKS"]]:
		var binding := _screen.app.input_service().effective_binding(entry[1], CommonUIBinding.SLOT_PRIMARY)
		var shortcut := CommonBindingText.describe(binding)
		(_hideout.get_node(entry[0]) as Button).text = (shortcut + "  " if not shortcut.is_empty() else "") + String(entry[2])
	_focus("BunkerHideoutView/Select_" + _port.bunker_room(_epoch))

func _deploy(frame: Dictionary) -> void:
	_text("DeployStatus", "LOCAL DEPLOYMENT")
	_text("ZoneTitle", String(frame.get("map_title","Sawmill Yard")).to_upper())
	_text("MissionDetails", "SOLO · 15 MINUTES · "+String(frame.get("exit_title","Road Gate")).to_upper())
	_text("SquadLabel", "OPERATOR")
	_text("SquadOak", "LOCAL OPERATOR")
	_show("SquadKevin", false); _show("SquadOyo", false)
	_text("DeployCenter/Phase", "PREPARING AUTHORITATIVE RAID")
	_text("DeployCenter/Waiting", frame.notice)
	_text("DeployCenter/Value", "LOCAL SAVE")
	_show("DeployCenter/Progress", false)
	_text("TaskCard/Name", "SUPPLY RUN")
	_text("TaskCard/Detail", "Search three marked crates. Take supplies. Extract through "+String(frame.get("exit_title","Road Gate"))+".")
	_text("ExtractsCard/Detail", String(frame.get("exit_title","Road Gate"))+" · 5 second hold · requires Supply Run eligibility")
	_text("TipCard/Detail", "Reload from your own ammunition. Leaving or taking damage interrupts search and extraction.")

func _hud(frame: Dictionary) -> void:
	_screen.call("apply_local_combat", frame.combat)
	_show("BackgroundFrame", false); _show("Atmosphere", false)
	var progression: Dictionary = frame.progression
	var clock: Dictionary = progression.get("clock", {})
	_text("TimerGroup/Timer", String(clock.get("clock_text", "—")))
	var status := String(frame.get("exit_title","Road Gate")).to_upper()+" · SEARCH 3 CRATES + RETAIN SUPPLIES"
	if clock.get("counting", false): status = "EXTRACTING · %.1f s · E CANCEL" % (float(clock.countdown_remaining) / 60.0)
	elif not progression.get("searching", {}).is_empty(): status = "SEARCHING · STAY IN REACH"
	elif not frame.nearest_target.is_empty(): status = "E · " + ("OPEN LOOT" if frame.searched_ids.has(frame.nearest_target) else "SEARCH / EXTRACT")
	if frame.mode in ["settling", "save_error", "error"]: status = frame.notice
	_text("TimerGroup/Extract", status)
	_show("FeedGroup", true)
	for name: String in ["Loot", "Kill"]:
		for node in _children("FeedGroup"):
			if String(node.name).begins_with(name) and node is CanvasItem: node.hide()
	_show("FeedGroup/TaskKind",false)
	_text("FeedGroup/TaskText", "SUPPLY %d/3 · ITEM %s" % [int(progression.get("task", {}).get("searched_crates", 0)), "HELD" if progression.get("task", {}).get("holds_objective", false) else "MISSING"])

func _maps(frame: Dictionary) -> void:
	var map := _screen.app.map_view()
	if map != null and _map != null: _map.present(map,frame.get("map_geometry",[]),frame.get("map_id","sawmill")!="sawmill")
	_text("ZonesNote", "3 SOLO MAPS")
	var ids:Array[String]=["sawmill","northline","blackwater"]
	for index in range(3):
		var id:=ids[index]
		var selected:bool=frame.get("map_id","sawmill")==id
		_text("ZoneName%d"%index,SupplyRunGraph.title_for(id).to_upper())
		_text("ZoneRisk%d"%index,"SELECTED" if selected else "SCAV / MUTANT")
		_text("ZoneMeta%d"%index,"15:00 · SOLO · "+SupplyRunGraph.exit_title(id).to_upper())
		_text("ZoneTaskCount%d"%index,"SUPPLY RUN")
		_button("ZoneHit%d"%index,StringName("select_"+id),"",frame.mode=="home" and frame.error.is_empty())
	for index in range(3,5):
		_text("ZoneRisk%d"%index,"LOCKED")
		_text("ZoneMeta%d"%index,"NOT CONNECTED TO LIVE RAID")
		_text("ZoneTaskCount%d"%index,"—")
	_text("HistoryStats", "LOCAL PROFILE GENERATION %d" % frame.profile_generation)
	_text("RegionNote", "SOLO RAID BRIEFING · Check supplies and exit" if frame.mode == "home" else "Your position · task and exit markers")
	var info: Array[String] = ["15:00", "1 · SOLO", "1 · "+String(frame.get("exit_title","Road Gate")).to_upper(), "SCAV / MUTANT", "SUPPLY RUN"]
	for index in range(5): _text("MapInfoValue%d" % index, info[index])
	_text("MapTaskName0", "SUPPLY RUN")
	_text("MapTaskMeta0", "Search 3 crates · retain supplies · extract")
	_text("MapTaskStatus0", "LIVE" if frame.mode == "raid" else "RAID-SCOPED")
	for prefix: String in ["MapTaskPanel", "MapTaskHit", "MapTaskName", "MapTaskMeta", "MapTaskStatus"]: _show(prefix + "1", false)
	_text("ZoneDetailsTitle", String(frame.get("map_title","Sawmill Yard")).to_upper())
	_show("ZoneDetailsHero/HeroImage",frame.get("map_id","sawmill")=="sawmill")
	_text("ZoneDetailsRisk", "SCAV / MUTANT")
	var summary_label:=_screen.get_node_or_null("ZoneDetailsSummary") as Label
	if summary_label!=null:
		summary_label.clip_text=true
		summary_label.tooltip_text="Search three marked containers and retain supplies. Hold the marked exit for 5 seconds. Death or abandonment loses unsecured equipment."
	_text("HistoryTitle", "LOCAL PROFILE · NO CLOUD SYNC")
	for index in range(10):_show("HistoryBar%d"%index,false)
	var chrome:=_screen.get_node_or_null("NavigationChrome") as ZNavigationChrome
	if chrome!=null:
		chrome.level_text="LOCAL"
		chrome.money_text="NO ECONOMY"
		chrome.task_count=1
	for index in [1,2]:_show("SquadDot%d"%index,false)
	_text("ZoneDetailsSummary", String(frame.get("map_error","")) if not String(frame.get("map_error","")).is_empty() else "3 searches · retain supplies · "+String(frame.get("exit_title","Road Gate"))+" (5s)")
	_text("ZoneTasksTitle", "TASKS IN THIS ZONE · 1")
	_text("SquadName3", "CO-OP UNAVAILABLE")
	_text("SquadTitle", "SOLO SESSION")
	for index in range(3):
		_text("SquadName%d" % index, "LOCAL OPERATOR" if index == 0 else "")
		_text("SquadStatus%d" % index, "SOLO" if index == 0 else "")
	_text("LoadoutValue", "REVIEW EQUIPMENT IN STASH / LOADOUT")
	_text("UninsuredValue", "INSURANCE UNAVAILABLE")
	_button("Deploy", &"resume" if frame.mode == "raid" else &"deploy", "RETURN TO RAID" if frame.mode == "raid" else "DEPLOY SOLO · "+String(frame.get("map_title","Sawmill Yard")).to_upper(), frame.mode in ["home", "raid"] and frame.error.is_empty() and String(frame.get("map_error","")).is_empty())
	_focus("Deploy")

func _tasks(frame: Dictionary) -> void:
	var view := _screen.app.task_view()
	if view == null or not view.is_ready() or view.tasks().is_empty(): return
	var task: TaskView.Entry = view.tasks()[0]
	_text("TradersTitle", "LOCAL CONTRACT")
	_text("TradersNote", "Persistent task resume unavailable")
	_text("TraderName0", "SUPPLY RUN")
	_text("TraderSub0", "RAID-SCOPED · LOCAL SETTLEMENT")
	_text("TraderCount0", "1")
	for index in range(1, 5):
		for prefix: String in ["TraderCard", "TraderHit", "TraderInitial", "TraderName", "TraderSub", "TraderCountBackground", "TraderCount"]: _show(prefix + str(index), false)
	for prefix: String in ["DailyTitle", "DailyTask", "DailyProgressValue", "DailyProgressTrack", "DailyProgressFill"]: _show(prefix, false)
	_text("TaskTabActive", "SUPPLY RUN")
	_text("TaskTabAvailable", "NO OTHER CONTRACTS")
	_text("TaskTabCompleted", "COMMITTED ON EXTRACTION")
	_text("TaskName0", task.title())
	_text("TaskMeta0", "LOCAL CONTRACT · "+String(frame.get("map_title","Sawmill Yard")).to_upper())
	_text("TaskReward0", "Completion token saved locally; no currency reward")
	var total: int = 0
	var objectives := task.objectives()
	for index in range(objectives.size()):
		var objective: TaskView.Objective = objectives[index]
		total += objective.current()
		_text("TaskObjectiveText%d" % index, objective.description())
		_text("TaskObjectiveValue%d" % index, "%d / %d" % [objective.current(), objective.target()])
		_show("TaskObjectiveCheck%d" % index, objective.current() >= objective.target())
	_text("TaskProgressValue0", "%d / 4" % total)
	for index in range(1, 3):
		for prefix: String in ["TaskCard", "TaskHit", "TaskName", "TaskTag", "TaskMeta", "TaskProgressTrack", "TaskProgressFill", "TaskProgressValue", "TaskReward"]: _show(prefix + str(index), false)
	_text("TaskTraderRep", "LOCAL CONTRACT · NO TRADER REPUTATION")
	_text("TaskDescription", task.description())
	for node in _screen.get_children():
		if (String(node.name).begins_with("TaskRewardLabel") or String(node.name).begins_with("TaskRewardValue")) and node is CanvasItem: node.hide()
	_text("TaskRewardsTitle", "COMPLETION IS PART OF THE COMMITTED RAID RESULT")
	_button("TaskTurnIn", &"", "SETTLED ON EXTRACTION", false)
	_button("TaskAbandon", &"resume", "BACK")

func _summary(frame: Dictionary) -> void:
	var view := _screen.app.summary_view()
	var final: bool = frame.mode == "summary" and view != null and view.is_ready()
	_text("Verdict", "LOCAL RESULT · " + String(frame.summary.get("outcome", "SAVE PENDING")).to_upper())
	_text("Subtitle", frame.notice)
	_text("MapName", String(frame.get("map_title","Sawmill Yard")).to_upper())
	_text("MetricLoot/Title", "RETAINED ITEM TYPES")
	_text("MetricLoot/Value", str(frame.summary.get("retained", []).size()) if final else "—")
	_text("MetricLoot/Detail", "Equipment remains in your loadout")
	_text("MetricXP/Title", "SAVE GENERATION")
	_text("MetricXP/Value", str(frame.summary.profile_generation) if final else "—")
	_text("MetricXP/Detail", "Committed locally" if final else "No final receipt yet")
	_text("MetricKills/Value", str(view.kill_count()) if final and view.audit_available() else "—")
	_text("MetricKills/Detail", "Confirmed raid kills" if final and view.audit_available() else "Raid audit unavailable")
	_text("MetricDamage/Value", str(view.damage_taken()) if final and view.audit_available() else "—")
	_text("MetricDamage/Detail", "Recorded damage; recovery at home")
	for node in _screen.get_children():
		if (String(node.name).begins_with("Timeline") or String(node.name).begins_with("Skill") or String(node.name) in ["XPPanel", "ProgressTitle"]) and node is CanvasItem: node.hide()
	_text("LootTitle", "RETAINED / LOST · LOCAL SETTLEMENT")
	_text("LootTrailing", "Currency valuation unavailable")
	var lines: Array[SummaryView.LootLine] = []
	if final:
		lines.assign(view.loot())
	for index in range(9):
		for prefix: String in ["LootItem", "LootName", "LootValue"]: _show(prefix + "%02d" % index, index < lines.size())
		_show("LootIcon%02d" % index, false)
		_show("LootBadge%02d" % index, false)
		if index < lines.size():
			_text("LootName%02d" % index, lines[index].display_name() + " ×" + str(lines[index].quantity()))
			_text("LootValue%02d" % index, "RETAINED" if lines[index].disposition() == SummaryView.LootDisposition.RETAINED else "LOST")
	_text("UsedTitle", "SAVE STATUS")
	_text("UsedTrailing", "NO DOUBLE SETTLEMENT")
	_text("UsedName00", "Retained records survive relaunch" if final else "Retry saving before continuing")
	_text("UsedState00", "COMMITTED" if final else "PENDING")
	_text("UsedName01", "Steam co-op and cloud sync are not active")
	_text("UsedState01", "LOCAL ONLY")
	_text("TaskPanel/Title", "SUPPLY RUN")
	_text("TaskPanel/Detail", "COMPLETED" if frame.summary.get("task", {}).get("completion_token", false) else "NOT COMPLETED")
	for part: String in ["Torso", "Legs", "Head"]:
		_show("HealthPanel/" + part + "Label", false)
		_show("HealthPanel/" + part + "Value", false)
	for index in range(2): _show("UsedIcon%02d" % index, false)
	_text("HealthPanel/Title", "HOME RECOVERY")
	_text("HealthPanel/Detail", "Body and survival resources recover at home. Saved raid consequences remain in the receipt.")
	_text("FooterHint", frame.notice)
	_show("TurnInTask", false); _show("Reinsure", false)
	_button("BackBunker", &"return_home" if final else &"retry_save", "RETURN HOME" if final else "RETRY LOCAL SAVE")
	_focus("BackBunker")

func _pause(frame: Dictionary) -> void:
	_text("ActionsPanel/Subtitle", "SOLO PAUSED" if frame.mode == "raid" else "LOCAL HOME")
	_show("SessionPanel", false); _show("SessionStats", false)
	_button("ActionsPanel/ResumeRow/Hit", &"resume")
	_button("ActionsPanel/CharacterRow/Hit", &"loadout")
	_button("ActionsPanel/MapRow/Hit", &"maps")
	_button("ActionsPanel/SettingsRow/Hit", &"controls")
	_text("ActionsPanel/SettingsRow/Label", "CONTROLS")
	_text("ActionsPanel/SettingsRow/Detail", "Keyboard and controller bindings")
	_button("ActionsPanel/SaveQuitRow/Hit", &"abandon" if frame.mode == "raid" else &"close_profile")
	_text("ActionsPanel/SaveQuitRow/Label", "ABANDON RAID" if frame.mode == "raid" else "MAIN MENU")
	_text("ActionsPanel/SaveQuitRow/Detail", "Lose unsecured deployment equipment; uncommitted loot is not retained" if frame.mode == "raid" else "Save the loadout and return to the menu; Continue keeps your campaign")
	_button("ActionsPanel/QuitDesktopRow/Hit", &"quit")
	_focus("ActionsPanel/ResumeRow/Hit")

func _text(path: String, text: String) -> void:
	var node := _screen.get_node_or_null(path)
	if node is Label: node.text = text
	elif node is RichTextLabel: node.text = text

func _show(path: String, visible: bool) -> void:
	var node := _screen.get_node_or_null(path) as CanvasItem
	if node != null: node.visible = visible

func _button(path: String, command: StringName, title: String = "", enabled: bool = true) -> void:
	var button := _screen.get_node_or_null(path) as BaseButton
	if button == null: return
	button.disabled = not enabled or command.is_empty()
	if button is Button and not title.is_empty(): button.text = title
	var event := "triggered" if button.has_signal("triggered") else "pressed"
	var previous: StringName = _commands.get(path, &"")
	if previous == command: return
	if not previous.is_empty():
		var retired := _send.bind(previous)
		if button.is_connected(event, retired): button.disconnect(event, retired)
	_commands[path] = command
	if command.is_empty(): return
	var callback := _send.bind(command)
	if not button.is_connected(event, callback): button.connect(event, callback)

func _children(path: String) -> Array[Node]:
	var node := _screen.get_node_or_null(path)
	if node == null: return []
	return node.get_children()

func _card(path: String, title: String, detail: String, command: StringName, enabled: bool) -> void:
	var card := _screen.get_node_or_null(path) as ZMenuActionCard
	if card == null: return
	card.card_title = title; card.card_subtitle = detail; card.disabled = not enabled
	var key := "card:" + path
	var previous: StringName = _commands.get(key, &"")
	if previous != command and not previous.is_empty():
		var retired := _send.bind(previous)
		if card.activated.is_connected(retired): card.activated.disconnect(retired)
	_commands[key] = command
	if not command.is_empty():
		var callback := _send.bind(command)
		if not card.activated.is_connected(callback): card.activated.connect(callback)

func _focus(path: String) -> void:
	var target := _screen.get_node_or_null(path) as Control
	if target != null: _screen.default_focus = _screen.get_path_to(target)

func _send(command: StringName) -> void:
	if not _screen.app.accepts_input(_screen) or _screen.app.local_game_ui() != _port: return
	if command in [&"abandon", &"quit"] and _port.snapshot().mode == "raid":
		_screen.app.confirm("Abandon this raid?", "Unsecured deployment equipment is lost. New loot is not saved. There is no mid-raid resume.",
			func() -> void: _port.request(command, _epoch))
	else: _port.request(command, _epoch)

func _navigate(route: String) -> void:
	var command := LocalGameUI.route_command(route)
	if not command.is_empty(): _send(command)

func _back() -> void:
	_send(&"resume")

func _exit_tree() -> void:
	if _port != null and _port.changed.is_connected(refresh): _port.changed.disconnect(refresh)
