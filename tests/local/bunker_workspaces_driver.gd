extends RefCounted
## Shared real-input driver hosted by the registered native bunker flow test.
## No standalone SceneTree, fake domain state or additional capture writer.
func run(h, initial: Dictionary) -> bool:
	var home_id: int = h._game._home.get_instance_id()
	var epoch: int = h._game._epoch
	await h.room_click("medical")
	if not h.hub("medical"): return false
	for entry: Array in [["CraftingWorkspace", "crafting"], ["BuildWorkspace", "build_mode"], ["SessionWorkspace", "session"]]:
		if not await h.click("BunkerHideoutView/" + String(entry[0])) or not h.route(entry[1]): return false
		var screen: ZScreen = h._game._ui.screen
		var binding := screen.get("_local_binding") as LocalBunkerWorkspaceBinding
		if not h.check(binding != null, "production workspace binding installed"): return false
		h.check(not screen.is_processing() and not screen.is_processing_input(), "sample clocks/input handlers are disabled")
		h.check(h._game._home.get_instance_id() == home_id and h._game._session == null, "same native inventory owner, no raid created")
		h.check(screen.app.fixture_generation() == 0 and screen.app.fixture_state().is_empty(), "no mutable fixture state")
		var stock := LocalBunkerWorkspaceBinding.stock_from_views(h._game._character.inventory_view(&"profile"), h._game._character.inventory_view(&"raid"))
		h.check(stock.ready and stock.stacks > 0, "live stock projected from real native inventory")
		h.check(not LocalBunkerWorkspaceBinding.stock_from_views(null, null).ready, "missing stock is unknown, never zero availability")
		match String(entry[1]):
			"crafting":
				h.check(not (screen.get_node("LocalWorkspaceCanvas/QueuePanel/QueueBandage") as Control).is_visible_in_tree(), "sample queue is not shown")
				h.check((screen.get_node("LocalWorkspaceCanvas/DetailPanel/CraftNow") as Button).disabled, "craft remains disabled")
				h.check((screen.get_node("LocalWorkspaceCanvas/DetailPanel/SupplyStock") as Label).text.begins_with(str(stock.quantities.get(String(ZerkovInventoryCatalog.ITEM_BANDAGE), 0))), "displayed supply quantity matches confirmed stock")
				await h.click("LocalWorkspaceCanvas/RecipePanel/RecipeSplint/Hit")
				h.check((screen.get_node("LocalWorkspaceCanvas/DetailPanel/Title") as Label).text == "SPLINT", "supply selection uses authored browser")
				await h.capture("02-workshop.png")
				await h.key(KEY_SPACE); await h.key(KEY_F)
				h.check(h._store.load_profile().fingerprint == initial.fingerprint, "craft and collect keys cannot mutate campaign")
				if not await h.click("LocalWorkspaceCanvas/DetailPanel/OpenLoadout") or not h.route("inventory"): return false
				await h.key(KEY_ESCAPE)
			"build_mode":
				h.check((screen.get_node("LocalWorkspaceCanvas/PlacementPanel/Place") as Button).disabled, "construction is not enabled")
				h.check((screen.get_node("LocalWorkspaceCanvas/PlacementPanel/Rotate") as Button).disabled, "rotation is not enabled")
				await h.click("LocalWorkspaceCanvas/CardWatercollector/Hit")
				h.check((screen.get_node("LocalWorkspaceCanvas/PlacementPanel/Title") as Label).text == "MEDICAL CORNER", "facility selection shows actual authored room")
				await h.capture("03-facilities.png")
				await h.key(KEY_R); await h.key(KEY_DELETE)
				h.check(h._store.load_profile().fingerprint == initial.fingerprint, "placement/rotation/dismantling keys cannot change save")
				if not await h.click("LocalWorkspaceCanvas/PlacementPanel/FacilityRoute") or not h.route("health"): return false
				await h.key(KEY_ESCAPE)
			"session":
				h.check(not (screen.get_node("LocalWorkspaceCanvas/SessionPanel/Players/Guest") as Control).is_visible_in_tree(), "no fictional co-op guest")
				h.check(not (screen.get_node("LocalWorkspaceCanvas/SessionPanel/CodeRow") as Control).is_visible_in_tree(), "no nonfunctional invite code")
				h.check((screen.get_node("LocalWorkspaceCanvas/SessionPanel/LocalProfile") as Label).text.contains("PROFILE GENERATION %d" % int(initial.generation)), "current local generation shown")
				await h.capture("04-session.png")
				if not await h.click("LocalWorkspaceCanvas/SessionPanel/OpenWorkshop") or not h.route("crafting"): return false
				await h.key(KEY_ESCAPE)
		if not h.route("bunker") or not h.hub("medical"): return false
		h.check(h._store.load_profile().fingerprint == initial.fingerprint, "opening/closing workspaces preserves save")
	# Existing CommonUI modal ownership must block a background workspace action.
	if not await h.click("BunkerHideoutView/SessionWorkspace") or not h.route("session"): return false
	h.check(h._game._ui.screen.app.confirm("Input ownership check", "Cancel returns to the workspace.", func(): pass), "real CommonUI modal opened")
	await h.settle()
	await h.click("LocalWorkspaceCanvas/SessionPanel/PlanRaid")
	h.check(h._game._ui.current_route == "session" and h._game._session == null, "covered button cannot navigate through modal")
	await h.key(KEY_ESCAPE)
	await h.key(KEY_ESCAPE)
	if not h.route("bunker"): return false
	h.check(h._game._home.get_instance_id() == home_id, "all screens shared one home owner")
	await h.key(KEY_ESCAPE)
	if not h.route("pause"): return false
	if not await h.click("ActionsPanel/SaveQuitRow/Hit") or not h.route("main_menu"): return false
	h.check(not h._game._ui_port.request(&"session", epoch), "retired home epoch cannot reopen session")
	h.check(h._store.load_profile().fingerprint == initial.fingerprint, "closing campaign preserves stock and profile")
	return h.failures == 0
