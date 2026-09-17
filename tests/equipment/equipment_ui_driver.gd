extends RefCounted
## Normal application, real input, real local files. The runner supplies only
## an isolated test namespace and manual raid pacing. Three fresh processes
## prove changed gear survives relaunch and is used by deployment.
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
const EXACT_SIZE := Vector2i(1920, 1080)
const PRIMARY: StringName = &"zerkov.slot.weapon_primary"
const MELEE: StringName = &"zerkov.slot.weapon_melee"
var checks: int = 0
var failures: int = 0
var game: LocalGame
var store: ProfileStore
var operations: GodotProfileFileOperations
var filming: bool = false
var cursor: ColorRect

var tree: SceneTree
var root: Window
var process_frame: Signal

func create_timer(seconds: float) -> SceneTreeTimer:
	return tree.create_timer(seconds)

func quit(code: int) -> void:
	tree.quit(code)

func check(ok: bool, text: String) -> bool:
	checks += 1
	if not ok:
		failures += 1
		push_error("EQUIPMENT_UI: " + text)
	return ok

func settle() -> void:
	for _i in range(12): await process_frame
	await create_timer(0.04).timeout

func key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.pressed = down
		root.push_input(event)
	await settle()

func linger(label: String) -> void:
	print("EQUIPMENT_UI_STAGE ", label)
	if filming:
		await RenderingServer.frame_post_draw
		check(Exact1080CaptureGuard.accepts(root, root, root.get_texture().get_image()), "native 1080p stage: " + label)
		for _i in range(30): await process_frame

func click(control: Control) -> bool:
	if not check(control != null and control.is_visible_in_tree(), "visible real input target"): return false
	var point := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point; motion.global_position = point
	root.push_input(motion)
	if cursor != null: cursor.position = point
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event)
	await settle()
	return failures == 0

func named(path: String) -> Control:
	return game._ui.screen.get_node_or_null(path) as Control

func gear(slot: StringName) -> Dictionary:
	var controller := game._character.inventory_controller() as InventoryEquipmentController
	for row: Dictionary in controller.equipment_view().slots:
		if StringName(row.slot_id) == slot: return row.item
	return {}

func item_slot(source: String, definition: String) -> Control:
	var grid: Control = game._ui.screen.call("_grid_for_source", source)
	if grid != null:
		for slot: Control in grid.get("_slots"):
			if String(slot.get("item").get("definition_id", "")) == definition: return slot
	return null

func route(expected: String) -> bool:
	return check(game._ui.current_route == expected and game.last_error.is_empty(),
		"route " + expected + " / " + String(game.last_error))

func boot() -> bool:
	game = load("res://game/bootstrap/local/local_game.tscn").instantiate() as LocalGame
	if not check(game.configure_test_store(store, false), "isolated file store injected before mount"): return false
	root.add_child(game)
	await settle()
	if not route("title"): return false
	await key(KEY_ENTER)
	if not route("main_menu"): return false
	if not await click(named("MenuPlay/Hit")) or not route("bunker"): return false
	await linger("Bunker: local campaign")
	return await click(named("BunkerHideoutView/LocalLoadout")) and route("inventory")

func assert_live() -> bool:
	var screen: Control = game._ui.screen
	check(game._ui.fixture_provider_for_test() == null, "no fixture provider in production")
	check(screen.call("_equipment_controller") != null, "authored workspace uses equipment controller")
	var secure: Control = screen.call("_grid_for_source", "secure")
	check(secure != null and secure.is_visible_in_tree(), "secure contents are reachable")
	if secure != null:
		check(secure.get_global_rect().end.y <= 1030 and secure.grid_columns == 3 and secure.grid_rows == 2,
			"secure grid fits exact canvas at native cell size")
		check(secure.items.size() == 1 and secure.items[0].definition_id == String(ZerkovInventoryCatalog.ITEM_SPLINT), "secure splints, not fixture")
	for pair: Array in [["BackSlot", "BackDetail"], ["HolsterSlot", "HolsterDetail"], ["ArmorSlot", "ArmorDetail"]]:
		var button := named("InventoryContent/CharacterColumn/" + pair[0]) as Button
		check(button.disabled and button.get_node(pair[1]).text == "UNAVAILABLE", "unsupported gear not fabricated")
	for label: Node in screen.find_children("*", "Label", true, false):
		if label.is_visible_in_tree():
			check(not ("24/30" in label.text or "5/5" in label.text or "7/7" in label.text or "M1911" in label.text or "Pump shotgun" in label.text), "visible label contains no fixture weapon/count")
	return failures == 0

func run(scene_tree: SceneTree) -> void:
	tree = scene_tree
	root = tree.root
	process_frame = tree.process_frame
	filming = OS.get_environment("ZERKOV_EQUIPMENT_MOVIE") == "1"
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args[0] not in ["create", "resume", "deploy", "cleanup"] \
		or not args[1].begins_with("equipflow_") or args[1].length() != 42 or not args[1].substr(10).is_valid_hex_number():
		push_error("EQUIPMENT_UI_INVALID_ARGUMENTS"); quit(2); return
	create_timer(180).timeout.connect(func() -> void: push_error("EQUIPMENT_UI_TIMEOUT"); quit(1))
	operations = GodotProfileFileOperations.new(StringName(args[1]))
	store = ProfileStore.new()
	if not check(store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, operations), "isolated real files"): await finish(); return
	if args[0] == "cleanup":
		for slot: StringName in ProfileFileOperations.ALL_SLOTS: check(operations.remove_slot(slot).ok, "remove test slot")
		await finish(); return
	check(root.size == EXACT_SIZE and root.get_visible_rect().size == Vector2(EXACT_SIZE), "exact 1920x1080 canvas")
	if filming:
		# Cocoa applies the physical window resize asynchronously. Do not start
		# input or accept footage until the native window agrees with the canvas.
		root.borderless = true
		root.position = Vector2i.ZERO
		root.size = EXACT_SIZE
		for _i in range(30):
			await process_frame
			if DisplayServer.window_get_size(root.get_window_id()) == EXACT_SIZE: break
		print("EQUIPMENT_RENDER_SURFACE logical=", root.size, " physical=", DisplayServer.window_get_size(root.get_window_id()), " screen=", DisplayServer.screen_get_size(), " viewport=", root.get_visible_rect().size)
		if not check(DisplayServer.get_name() != "headless" and DisplayServer.window_get_size() == EXACT_SIZE, "recording uses real exact-sized render window"):
			await finish(); return
		var overlay := CanvasLayer.new(); overlay.layer = 100; root.add_child(overlay)
		cursor = ColorRect.new(); cursor.size = Vector2(8,8); cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(cursor) # Test cursor marker only; does not intercept input.
	if args[0] == "create":
		check(store.load_profile().get("reason") == &"profile_missing", "only New Game may create content")
	else:
		if not check(args.size() == 4 and store.load_profile().fingerprint == args[3], "fresh process exact saved profile"): await finish(); return
	if not await boot() or not assert_live(): await finish(); return
	var weapon_id: int = int(args[2]) if args.size() > 2 else int(gear(PRIMARY).get("item_id", 0))
	if args[0] == "create":
		check(gear(PRIMARY).definition_id == String(ZerkovInventoryCatalog.ITEM_AKM), "canonical primary visible")
		check(gear(MELEE).definition_id == String(ZerkovInventoryCatalog.ITEM_MACHETE), "canonical melee visible")
		await linger("Canonical gear and secure container")
		if not await click(named("InventoryContent/CharacterColumn/SlingSlot")): await finish(); return
		check(gear(PRIMARY).is_empty(), "button unequips primary through intent")
		check(item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM)) != null, "same AKM appears in storage")
		await linger("Primary unequipped: no stale fixture gun")
		if not await click(item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM))): await finish(); return
		if not await click(named("InventoryContent/CharacterColumn/SlingSlot")): await finish(); return
		check(gear(PRIMARY).item_id == weapon_id, "select and activate re-equips same item")
		await linger("Re-equipped from the actual loadout")
		var gestures = load("res://tests/equipment/equipment_gesture_driver.gd").new()
		if not await gestures.run(self): await finish(); return
		if not await click(named("InventoryContent/CharacterColumn/SlingSlot")): await finish(); return
		check(gear(PRIMARY).is_empty(), "save a deliberately changed empty primary")
	elif args[0] == "resume":
		check(gear(PRIMARY).is_empty(), "empty slot survives relaunch: no starter fallback")
		var slot := item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM))
		check(slot != null and int(slot.get("item").item_id) == weapon_id, "persisted item identity in storage")
		await linger("Fresh process: saved unequipped loadout")
		if not await click(slot) or not await click(named("InventoryContent/CharacterColumn/SlingSlot")): await finish(); return
		check(gear(PRIMARY).item_id == weapon_id, "saved item equipped through input")
		var owner := game._home
		var before := owner.raid_authority().make_persistence_record(owner.raid_player_inventory_id)
		if not await click(item_slot("secure", String(ZerkovInventoryCatalog.ITEM_SPLINT))) or not await click(named("InventoryContent/CharacterColumn/LegStrapSlot")): await finish(); return
		check(before == owner.raid_authority().make_persistence_record(owner.raid_player_inventory_id), "incompatible secure item cannot replace machete")
		await linger("Incompatible equipment rejected without mutation")
	else:
		check(gear(PRIMARY).item_id == weapon_id, "second relaunch keeps equipped identity")
		await key(KEY_ESCAPE)
		if not route("bunker") or not await click(named("BunkerHideoutView/LocalDeploy")) or not route("maps"): await finish(); return
		if not check(game._session == null and game._mode == "home", "briefing preserves the saved loadout before deployment"): await finish(); return
		await linger("Raid briefing: review the saved loadout")
		if not await click(named("Deploy")) or not route("hud"): await finish(); return
		var owner := game._session.deployment.inventory
		var equipped: bool = false
		for item: Dictionary in owner.raid_authority().snapshot(owner.raid_player_inventory_id).get_items():
			if int(item.id) == weapon_id:
				equipped = item.location.kind == "slot" and StringName(item.location.slot_identifier) == PRIMARY
		check(equipped and game._session.hud_model.snapshot().has_weapon, "deployment and combat use persisted weapon")
		await key(KEY_I)
		check(route("inventory") and gear(PRIMARY).item_id == weapon_id, "same equipment in deployed UI")
		await linger("Raid receives the same saved primary")
		var deployed = load("res://tests/equipment/equipment_deploy_driver.gd").new()
		if not await deployed.run(self, weapon_id): await finish(); return
	if args[0] != "deploy":
		await key(KEY_ESCAPE)
		check(route("bunker"), "normal workspace exit saves loadout")
		await linger("Changed loadout saved locally")
	var saved := store.load_profile()
	print("EQUIPMENT_UI_SAVE item=", weapon_id, " fingerprint=", saved.fingerprint)
	await finish()

func finish() -> void:
	if game != null and is_instance_valid(game):
		check(game.shutdown(), "normal application teardown: " + String(game.last_error))
		game.queue_free(); await settle(); game = null
	if store != null and store.is_configured(): store.close()
	print("EQUIPMENT_UI_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
