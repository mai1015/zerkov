extends SceneTree
## Regressions for ownership, retained composition and cross-layer input.
var app: Control
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("UI_COMPOSITION: " + message)

func settle() -> void:
	for i in range(8): await process_frame

func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		root.push_input(event)
	await settle()

func run() -> void:
	root.size = Vector2i(1920, 1080)
	app = load("res://ui/main.tscn").instantiate()
	app.name = "IsolatedUIHost"
	root.add_child(app)
	app.qa_mode = true
	await settle()
	check(ZRouteCatalog.ROUTES.size() == 28, "all stable route IDs remain registered")
	for route in ZRouteCatalog.ROUTES:
		check(ZRouteCatalog.scene_for(route) != null, "catalog resolves " + route)
	var previous: Control = app.screen
	var rejected: Array = []
	app.navigator.rejected.connect(func(route, _reason): rejected.append(route))
	app.navigate("not-a-route")
	await settle()
	check(app.screen == previous and app.current_route == "title", "invalid navigation leaves committed screen intact")
	check(rejected == ["not-a-route"], "invalid navigation reports rejection once")
	# Cancel the queued CommonUI transaction before its deferred drain runs.
	# This exercises navigator rollback without changing any vendored code.
	app.navigate("maps", false)
	app.navigator.call("_drain")
	app.common_ui_root.menu_layer()._cancel_pending_queue("Injected UI acceptance cancellation")
	await settle()
	check(app.screen == previous and app.current_route == "title", "canceled navigation keeps committed caller")
	check(previous.is_visible_in_tree() and previous.is_routing_active(), "canceled navigation keeps caller visible and active")
	check(rejected == ["not-a-route", "maps"], "canceled navigation reports rejection once")

	app.navigate("hud", false)
	await settle()
	var hud: Control = app.screen
	var screen_root: CommonUIScreenRoot = app.common_ui_root
	var handle: CommonUIContextHandle = hud.get_context_handle()
	check(screen_root.hud_layer().get_top_screen() == hud, "HUD is mounted in the HUD layer")
	check(screen_root.menu_layer().get_depth() == 0, "HUD does not occupy the menu layer")
	app.state.raid_ammo = 17
	await key(KEY_ESCAPE)
	check(app.current_route == "pause", "physical Back opens pause")
	check(screen_root.hud_layer().get_top_screen() == hud, "pause retains the HUD instance")
	check(handle.is_suspended(), "pause suspends HUD routing")
	check(hud.process_mode == Node.PROCESS_MODE_DISABLED, "pause stops HUD preview timers")
	await key(KEY_R)
	check(not bool(app.state.get("raid_reloading", false)), "covered HUD ignores physical reload")

	app.screen.app.confirm("Nested modal", "UI-only confirmation", func(): pass)
	await settle()
	check(app.modal != null and handle.is_suspended(), "modal keeps the covered HUD suspended")
	await key(KEY_ESCAPE)
	check(app.modal == null and app.current_route == "pause", "Back dismisses just the modal")
	check(handle.is_suspended(), "closing nested modal does not resume HUD beneath pause")
	app.navigate("inventory")
	await settle()
	var inventory: Control = app.screen
	check(handle.is_suspended(), "workspace over pause keeps HUD suspended")
	app.back()
	await settle()
	check(app.current_route == "pause", "workspace Back restores pause")
	check(handle.is_suspended(), "workspace Back keeps the HUD suspended beneath pause")
	app.back()
	await settle()
	check(app.screen == hud and app.current_route == "hud", "resume returns the same HUD")
	check(not handle.is_suspended(), "resume restores HUD routing")
	check(hud.process_mode != Node.PROCESS_MODE_DISABLED, "resume restarts HUD preview timers")
	check(app.state.raid_ammo == 17, "pause and modal preserve HUD model state")

	app.navigate("inventory")
	await settle()
	inventory = app.screen
	var shell: Control = inventory.get_node("InventoryContent")
	var chrome: Control = inventory.get_node("NavigationChrome")
	var search: LineEdit = inventory.find_child("StashSearch", true, false)
	var grid: Control = inventory._grid_for_source("stash")
	search.text = "ammo"
	search.text_changed.emit(search.text)
	search.grab_focus()
	search.caret_column = 2
	inventory._set_filter("ammo")
	await settle()
	check(inventory.get_node("InventoryContent") == shell, "filter retains authored shell")
	check(inventory._grid_for_source("stash") == grid, "filter retains the stash grid")
	check(root.gui_get_focus_owner() == search and search.caret_column == 2, "filter preserves input focus and caret")
	check(search.text == "ammo", "filter preserves the search query")
	inventory._set_loot_mode(true)
	await settle()
	check(inventory._grid_for_source("loot") == grid, "loot mode reuses the grid instance")
	check(grid.item_selected.get_connections().size() == 1, "mode changes do not duplicate selection handlers")
	inventory._set_loot_mode(false)
	await settle()
	check(inventory._grid_for_source("stash") == grid, "returning to stash reuses the grid")
	check(grid.context_requested.get_connections().size() == 1, "mode changes do not duplicate context handlers")
	for dimensions in [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1920, 1080)]:
		app.ui_layout_mode = "compact" if dimensions.x < 1920 else "desktop"
		root.size = dimensions
		app._sync_window_scale()
		await settle()
		inventory.reflow(root.get_visible_rect().size)
		await settle()
		check(app.screen == inventory and inventory.get_node("InventoryContent") == shell, "reflow retains workspace at " + str(dimensions))
		check(inventory.get_node("NavigationChrome") == chrome and chrome.is_visible_in_tree(), "reflow retains shared chrome at " + str(dimensions))
		check(inventory._grid_for_source("stash") == grid, "reflow retains grid at " + str(dimensions))

	app.toggle_picker()
	await settle()
	var picker: Control = app.picker
	check(screen_root.popup_layer().get_top_screen() == picker, "catalog is a CommonUI popup")
	var med_count: int = int(app.state.get("med_count", 2))
	await key(KEY_Y)
	check(int(app.state.get("med_count", 2)) == med_count, "catalog blocks underlying quick-heal input")
	for i in range(32):
		await key(KEY_TAB)
		var focus := root.gui_get_focus_owner()
		check(focus != null and picker.is_ancestor_of(focus), "catalog traps focus")
	await key(KEY_ESCAPE)
	check(app.picker == null and app.screen == inventory, "Back dismisses catalog without navigating")
	check(handle.is_suspended(), "catalog close keeps HUD suspended beneath inventory")
	var pocket_grid: Control = inventory._grid_for_source("pockets")
	var drag_item: Dictionary = pocket_grid.items[0].duplicate(true)
	var payload := {"type": "inventory_item", "source": "pockets", "item_id": drag_item.id, "item": drag_item}
	pocket_grid.force_drag(payload, Label.new())
	check(root.gui_is_dragging(), "inventory drag starts before resize")
	app.ui_layout_mode = "compact"
	root.size = Vector2i(960, 540)
	app._sync_window_scale()
	await settle()
	inventory.reflow(root.get_visible_rect().size)
	await settle()
	check(root.gui_is_dragging() and root.gui_get_drag_data() == payload, "reflow preserves active drag intent")
	root.gui_cancel_drag()

	var card: ZMenuActionCard = load("res://ui/screens/frontflow/components/menu_action_card.tscn").instantiate()
	root.add_child(card)
	card.card_title = "RUNTIME TITLE"
	card.card_subtitle = "Runtime detail"
	card.disabled = true
	check(card.get_node("Title").text == "RUNTIME TITLE", "card configuration updates after ready")
	check(card.get_focus_target().disabled, "card owns disabled input state")
	card.queue_free()
	var row: ZWorldRow = load("res://ui/screens/frontflow/components/world_row.tscn").instantiate()
	root.add_child(row)
	var data := {"id": "test-world", "name": "Test World", "difficulty": "STANDARD"}
	row.world = data
	data.name = "Caller changed"
	check(row.world.name == "Test World", "world row owns a copy of its presentation data")
	row.queue_free()

	print("UI_COMPOSITION_COMPLETE checks=", checks, " failures=", failures)
	app.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
