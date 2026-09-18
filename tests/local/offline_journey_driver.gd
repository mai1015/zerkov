extends RefCounted
## Real-input excursion and deployment/debrief coverage, hosted by the existing
## isolated-file test. No fake loadout, native substitute, or forced routes.
var _loading_capture_done := false

func run(h, initial: Dictionary) -> bool:
	var game: LocalGame = h._game
	var home_id: int = game._home.get_instance_id()
	var epoch: int = game._epoch
	if not h.hub("storage"): return false
	if not _sections(h, "home", "bunker"): return false
	# Presentation-only error-state probe: it never writes or changes the port.
	var bunker: ZBunkerHideoutView = game._ui.screen.get_node("BunkerHideoutView")
	var error_frame: Dictionary = game._ui_port.snapshot().duplicate(true)
	error_frame.error = "test_write_failed"
	bunker.present_home(error_frame)
	var retry: Control = bunker.get_node("RetrySave")
	for name: String in ["CraftingWorkspace", "BuildWorkspace", "SessionWorkspace", "NavigationChrome"]:
		h.check(not retry.get_global_rect().intersects(bunker.get_node(name).get_global_rect()), "save retry cannot overlap section or facility actions")
	bunker.present_home(game._ui_port.snapshot())
	game._ui.screen.get_node("JourneyUX").refresh()
	h.check(bunker._outline.get_theme_stylebox("panel").bg_color.a == 0.0, "room selection outline remains transparent over bunker art")

	await h.capture("02-bunker.png")
	await h.key(KEY_M)
	if not h.route("maps"): return false
	if not _briefing(h): return false
	var card: Node = game._ui.screen.get_node("JourneyOverlay/PreparationCard")
	h.check(game._ui.get_viewport().gui_get_focus_owner() == card.get_node("EditLoadout"), "briefing entry focuses preparation, not irreversible deployment")
	var projected := LocalPreparationView.from_views(game._character.inventory_view(&"raid"), game._character.health_view(), game._ui_port.snapshot().home_equipment)
	h.check(projected.ready and projected.equipment_ready, "native equipped slots are available, not inferred empty from spatial grids")
	h.check(projected.is_read_only() and projected.equipment.is_read_only(), "preparation is recursively immutable")
	var unavailable := LocalPreparationView.from_views(null, game._character.health_view())
	h.check(not unavailable.ready and not unavailable.equipment_ready, "missing inventory is unavailable, not an empty kit")
	var stale: Dictionary = game._ui_port.snapshot().home_equipment.duplicate(true)
	stale.revision += 1
	var rejected := LocalPreparationView.from_views(game._character.inventory_view(&"raid"), game._character.health_view(), stale)
	h.check(not rejected.equipment_ready, "different native revision cannot impersonate current equipment")
	if h._run_mode == "new":
		h.check(projected.equipment.has("AKM") and projected.loose_rounds == 60 and projected.medical_items == 4, "explicit new campaign has actual known kit, loose rounds exclude loaded ammo")
	else:
		h.check(projected.equipment.is_empty(), "Continue after abandonment shows the real empty equipment, not the starter kit")
		h.check(projected.warnings.has("No rifle equipped. You can still deploy."), "empty rifle warning is advisory, not a new deployment rule")
	h.check(game._ui.character_runtime_for_route("maps", ZUIRouteIntent.Origin.REVIEW) == null, "review-origin briefing cannot acquire campaign runtime")
	await h.capture("03-briefing.png")
	if not await h.click("JourneyOverlay/PreparationCard/EditLoadout") or not h.route("inventory"): return false
	h.check(game._ui_port.snapshot().preparation_return == "maps", "root remembers briefing-origin preparation")
	h.check((game._ui.screen.get_node("NavigationChrome/Close") as Button).text == "ESC / BRIEFING", "back button explains actual destination")
	if not _sections(h, "home", "inventory"): return false
	await h.capture("04-loadout.png")
	if not await h.click("InventoryContent/HealthTab") or not h.route("health"): return false
	h.check(game._ui_port.snapshot().preparation_return == "maps", "health tab retains preparation return context")
	await h.capture("05-health.png")
	if not await h.click("InventoryContent/StatsTab") or not h.route("stats"): return false
	h.check(game._ui_port.snapshot().preparation_return == "maps", "stats tab retains preparation return context")
	await h.key(KEY_ESCAPE)
	if not h.route("maps") or not _briefing(h): return false
	# Opening health directly from briefing follows the same rule.
	if not await h.click("JourneyOverlay/PreparationCard/InspectHealth") or not h.route("health"): return false
	await h.key(KEY_ESCAPE)
	if not h.route("maps"): return false
	h.check(game._home.get_instance_id() == home_id and game._session == null, "preparation uses one native owner and starts no raid")
	h.check(h._store.load_profile().fingerprint == initial.fingerprint, "read-only preparation excursion preserves exact saved profile")
	# Real modal blocks the new preparation buttons just as it blocks old actions.
	game._ui.screen.app.confirm("Stay in the briefing", "Input ownership control", func(): pass)
	await h.settle()
	await h.click("JourneyOverlay/PreparationCard/EditLoadout")
	h.check(game._ui.current_route == "maps" and game._session == null, "modal blocks covered preparation action")
	await h.key(KEY_ESCAPE)
	await h.capture("06-briefing-return.png")
	await h.key(KEY_ESCAPE)
	if not h.route("bunker"): return false
	await h.key(KEY_I)
	if not h.route("inventory"): return false
	h.check(game._ui_port.snapshot().preparation_return == "bunker", "normal home excursion does not retain the previous briefing destination")
	await h.key(KEY_ESCAPE)
	if not h.route("bunker"): return false
	# Top navigation selects Settings; Controls stays in the main settings body.
	if not await h.click("BunkerHideoutView/NavigationChrome/Settings") or not h.route("controls"): return false
	if not _sections(h, "home", "settings"): return false
	if not await _settings_capture_cancel(h): return false
	await h.capture("06a-settings.png")
	await h.key(KEY_ESCAPE)
	if not h.route("bunker"): return false
	if h._run_mode == "new":
		await h.key(KEY_M)
		if not h.route("maps"): return false
		game._ui.navigator.committed.connect(_capture_loading.bind(h))
		if not await h.click("Deploy") or not h.route("hud"): return false
		h.check(game._ui_port.snapshot().preparation_return == "bunker", "deployment retires preparation return context")
		h.check(not game._ui_port.request(&"loadout", epoch), "retired home epoch cannot reopen equipment in the raid")
		h.check(game._ui.character_runtime_for_route("maps", ZUIRouteIntent.Origin.PRODUCTION) == null, "raid map does not acquire a home equipment capability")
		h.check(game._session.hud_model.snapshot().has_weapon, "actual deployed weapon matches the reviewed kit")
		for i in range(8):
			if not h.check(game.advance(), "canonical raid tick succeeds through styled HUD"): return false
		await h.capture("08-raid.png")
		var tick: int = game._session.raid.last_processed_tick
		await h.key(KEY_I)
		if not h.route("inventory") or not _sections(h, "raid", "inventory"): return false
		# The authored workspace may be specialised (live equipment); a subclass of
		# the same screen still satisfies "one Character interface", a separate
		# raid-only inventory screen does not.
		var screen_script: Script = game._ui.screen.get_script()
		var authored_character := false
		while screen_script != null:
			if screen_script.resource_path == "res://ui/screens/character/character_screen.gd":
				authored_character = true
				break
			screen_script = screen_script.get_base_script()
		h.check(authored_character, "same authored Character screen is used in the raid")
		h.check(not game._ui.screen.get_node("InventoryContent/StashTab").visible, "raid Character does not advertise bunker stash")
		h.check(game._ui.screen.get_node("InventoryContent/DesktopStashScroll/StashGrid").source_id == "loot", "raid right pane uses existing nearby-loot source, never stash")
		h.check(not game._ui.screen.get_node("InventoryContent/PostRaidBar/MoveLoot").visible, "ordinary Character has no post-raid action strip")
		h.check(game._home == null and game._character.inventory_view(&"raid").is_ready(), "raid Character reads the live raid, not the retired home")
		var controller: InventoryPresentationController = game._character.inventory_controller()
		h.check(not controller.is_loot_container_open(), "opening Character is not a world loot interaction")
		h.check(game._ui.screen.call("_items_for", "loot").is_empty() and game._ui.screen.call("_items_for", "stash").is_empty(), "closed raid pane discloses neither retained crate contents nor bunker stash")
		h.check(not game._ui.screen.get_node("InventoryContent/DesktopStashScroll").visible and game._ui.screen.get_node_or_null("InventoryContent/LocalLootEmpty") == null, "closed raid loot has no irrelevant empty workspace")
		h.check(not game._ui.screen.get_node("InventoryContent/LootTab").visible and game._ui.screen.get_node("InventoryContent/LootTab").disabled, "no closed loot tab can open the default crate")
		h.check(not game._ui.screen.get_node("InventoryContent/StashSearch").visible and not game._ui.screen.get_node("InventoryContent/FilterAll").visible, "inapplicable loot search and filters are absent")
		game._ui.screen.call("_set_loot_mode", true)
		h.check(not controller.is_loot_container_open(), "retained tab callback cannot admit a world interaction")
		await h.capture("08a-character-raid.png")
		if not await h.click("InventoryContent/HealthTab") or not h.route("health"): return false
		if not _sections(h, "raid", "inventory"): return false
		if not await h.click("NavigationChrome/Tasks") or not h.route("tasks"): return false
		if not _sections(h, "raid", "tasks"): return false
		await h.capture("08b-tasks-raid.png")
		if not await h.click("NavigationChrome/Maps") or not h.route("maps"): return false
		if not _sections(h, "raid", "maps"): return false
		h.check(game._ui.screen.get_node_or_null("JourneyOverlay/PreparationCard") == null, "field map does not acquire a bunker preparation card")
		await h.capture("08c-map-raid.png")
		if not await h.click("NavigationChrome/Settings") or not h.route("controls"): return false
		if not _sections(h, "raid", "settings"): return false
		if not await _settings_capture_cancel(h): return false
		await h.capture("08d-settings-raid.png")
		h.check(not game.advance() and game._session.raid.last_processed_tick == tick, "offline simulation stays paused while browsing raid sections")
		await h.key(KEY_ESCAPE)
		if not h.route("hud"): return false
		if not h._capture_dir.is_empty():
			h.check(_loading_capture_done, "captured real loading screen before authority startup")
		await h.key(KEY_ESCAPE)
		if not h.route("pause"): return false
		if not await h.click("ActionsPanel/SaveQuitRow/Hit"): return false
		var modal: Control = game._ui.modal
		if not h.check(is_instance_valid(modal), "abandonment still requires real CommonUI confirmation"): return false
		var button: Button
		for node: Node in modal.find_children("*", "Button", true, false):
			if not node.text.to_upper().contains("CANCEL"): button = node
		if not h.check(button != null, "confirmation button is present"): return false
		await _click_control(h, button)
		if not h.route("summary_solo"): return false
		h.check(game._summary.outcome == "abandoned", "debrief reflects actual committed abandonment, not a simulated victory")
		h.check((game._ui.screen.get_node("JourneyOverlay/ResultCard/Outcome") as Label).text == "RAID ABANDONED", "styled result matches authoritative receipt")
		await h.capture("09-result.png")
		var settled: Dictionary = h._store.load_profile()
		if not await h.click("BackBunker") or not h.route("bunker"): return false
		h.check(h._store.load_profile().fingerprint == settled.fingerprint, "returning home does not reapply settlement")
		await h.capture("10-home-return.png")
		await h.key(KEY_M)
		if not h.route("maps"): return false
		var empty := LocalPreparationView.from_views(game._character.inventory_view(&"raid"), game._character.health_view(), game._ui_port.snapshot().home_equipment)
		h.check(empty.equipment_ready and empty.equipment.is_empty(), "post-loss preparation accurately shows no equipped weapon")
		h.check(not (game._ui.screen.get_node("Deploy") as Button).disabled, "unarmed loadout remains an advisory, no invented restriction")
		await h.key(KEY_ESCAPE)
		if not h.route("bunker"): return false
	var current: Dictionary = h._store.load_profile()
	await h.key(KEY_ESCAPE)
	if not h.route("pause"): return false
	if not await h.click("ActionsPanel/SaveQuitRow/Hit") or not h.route("main_menu"): return false
	h.check(h._store.load_profile().fingerprint == current.fingerprint, "closing campaign preserves the final committed profile")
	return h.failures == 0

func _briefing(h) -> bool:
	var screen: ZScreen = h._game._ui.screen
	var card := screen.get_node_or_null("JourneyOverlay/PreparationCard")
	if not h.check(card != null, "authored preparation card is mounted in the existing briefing"): return false
	var frame: Dictionary = h._game._ui_port.snapshot()
	h.check((card.get_node("Equipment") as Label).text == ("\n".join(frame.home_equipment.names) if not frame.home_equipment.names.is_empty() else "Nothing equipped"), "rendered equipment agrees with current owner snapshot")
	h.check((card.get_node("Ammo") as Label).text == str(frame.home_equipment.loose_rounds), "rendered reserves match current authoritative item quantity")
	h.check(not (screen.get_node("ZoneCard1") as Control).is_visible_in_tree(), "unconnected sample destinations are not deployment choices")
	return h.failures == 0

func _capture_loading(route: String, _screen: Control, h) -> void:
	if route != "deploying": return
	await h.process_frame
	if not h.check(h._game._ui.current_route == "deploying", "loading is visible before actual raid startup"): return
	var timer := h._game._ui.screen.get_node_or_null("FrontflowDeployTimer") as Timer
	h.check(timer == null or timer.is_stopped(), "production loading never uses the fixture auto-advance timer")
	if h._capture_dir.is_empty(): return
	await RenderingServer.frame_post_draw
	await h.capture("07-deploying.png", false)
	_loading_capture_done = true

func _click_control(h, control: Control) -> void:
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = control.get_global_rect().get_center()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		h.root.push_input(event)
	await h.settle()


func _sections(h, mode: String, section: String) -> bool:
	var screen: Control = h._game._ui.screen
	var chrome := screen.get_node_or_null("NavigationChrome") as ZNavigationChrome
	if h._game._ui.current_route == "bunker": chrome = screen.get_node("BunkerHideoutView/NavigationChrome") as ZNavigationChrome
	if not h.check(chrome != null, "same shared section component is mounted"): return false
	h.check(not chrome.get_node("Insurance").visible and chrome.get_node("Insurance").disabled, "unavailable insurance is not a top-level section")
	h.check(chrome.get_node("Settings").text == "SETTINGS" and chrome.get_node("Character").text == "CHARACTER" and chrome.get_node("Tasks").text == "TASKS", "top row names sections, never detail controls")
	h.check(chrome.get_node("Bunker").visible == (mode == "home"), "Bunker section exists only at home")
	h.check(chrome.get_node("Maps").text == ("MAP" if mode == "raid" else "BRIEFING"), "operation section follows actual context")
	var expected := {"inventory":"Character", "tasks":"Tasks", "maps":"Maps", "settings":"Settings", "bunker":"Bunker"}
	var active := chrome.get_node(expected[section]) as Button
	h.check(active.get_theme_stylebox("normal").border_width_bottom == 2, "current section has a selected underline")
	h.check(active.get_theme_stylebox("normal").border_width_top == 0, "sections are not boxed actions")
	var right: float = 0.0
	for button: Control in chrome.get_focus_targets():
		h.check(button.position.x >= right and button.position.y >= 0 and button.get_rect().end.y <= 56, "section hit areas align and do not overlap")
		right = button.get_rect().end.x
	h.check(chrome.get_node("Header").get_theme_stylebox("panel").bg_color == LocalJourneyStyle.BG, "home and raid headers share one palette")
	chrome.layout_for(Vector2(1920, 1080))
	h.check(not chrome.get_node("Insurance").visible and chrome.get_node("Settings").text == "SETTINGS", "reflow cannot restore legacy header details")
	return h.failures == 0

func _settings_capture_cancel(h) -> bool:
	var screen: Control = h._game._ui.screen
	h.check(screen.get_node("SidebarTitle").text == "SETTINGS" and screen.get_node("BindingsPane/BindingsBody/SectionTitle").text == "CONTROLS", "settings details live in main content")
	h.check(screen.get_node("SidebarGraphics").disabled, "no fictional graphics backend is enabled")
	if not await h.click("BindingsPane/BindingsBody/SprintPrimary"): return false
	await h.key(KEY_ESCAPE)
	h.check(h._game._ui.current_route == "controls" and screen.capture_action.is_empty(), "Escape cancels key capture before leaving Settings")
	return h.failures == 0
