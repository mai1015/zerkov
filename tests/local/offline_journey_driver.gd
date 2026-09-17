extends RefCounted
## Real-input excursion and deployment/debrief coverage, hosted by the existing
## isolated-file test. No fake loadout, native substitute, or forced routes.
var _loading_capture_done := false

func run(h, initial: Dictionary) -> bool:
	var game: LocalGame = h._game
	var home_id: int = game._home.get_instance_id()
	var epoch: int = game._epoch
	if not h.hub("storage"): return false
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
	if route != "deploying" or h._capture_dir.is_empty(): return
	await h.process_frame
	await RenderingServer.frame_post_draw
	if not h.check(h._game._ui.current_route == "deploying", "loading is visible before actual raid startup"): return
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
