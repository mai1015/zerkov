extends "res://tests/local/native_local_flow_contract.gd"
## Real campaign + native inventory and actual input. No fixture home screen,
## fake loadout or route forcing. Reuses the established isolated-store harness.
const BUNKER_SIZE := Vector2i(1920, 1080)
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
var _capture_dir := ""
var _run_mode := ""

func run() -> void:
	# The existing native capture contract uses borderless output to avoid OS
	# title-bar clamping on a 1080-line display. This never rescales an image.
	root.borderless = true
	root.size = BUNKER_SIZE
	await process_frame
	if root.get_visible_rect().size != Vector2(BUNKER_SIZE):
		push_error("BUNKER_FLOW_OUTPUT_SIZE"); quit(2); return
	create_timer(150.0).timeout.connect(func(): push_error("BUNKER_FLOW_TIMEOUT"); quit(1))
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args[0] not in ["new", "continue", "cleanup"] \
		or not args[1].begins_with("localflow_") or args[1].length() != 42 or not args[1].substr(10).is_valid_hex_number():
		push_error("BUNKER_FLOW_INVALID_NAMESPACE"); quit(2); return
	_run_mode = args[0]
	_namespace = args[1]
	if args.size() > 3: _capture_dir = args[3]
	_operations = GodotProfileFileOperations.new(StringName(_namespace))
	_store = ProfileStore.new()
	if not check(_store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, _operations), "isolated real-file store"): await finish(); return
	if _run_mode == "cleanup":
		for slot in ProfileFileOperations.ALL_SLOTS: check(_operations.remove_slot(slot).get("ok", false), "isolated cleanup")
		_store.close()
		print("BUNKER_FLOW_CLEANUP checks=", checks, " failures=", failures)
		quit(failures); return
	if not _capture_dir.is_empty() and DisplayServer.get_name() == "headless":
		push_error("BUNKER_FLOW_CAPTURE_REQUIRES_GRAPHICS"); await finish(); return
	var saved := _store.load_profile()
	if _run_mode == "new":
		if not check(saved.get("reason") == &"profile_missing", "new namespace has no seeded kit"): await finish(); return
	else:
		if not check(args.size() >= 3 and saved.get("ok") and saved.fingerprint == args[2], "independent process reads exact previous save"): await finish(); return
	var scene_path: String = ProjectSettings.get_setting("application/run/main_scene")
	check(scene_path == "res://game/bootstrap/local/local_game.tscn", "normal project startup uses campaign root")
	_game = load(scene_path).instantiate() as LocalGame
	_game.configure_test_store(_store, false)
	root.add_child(_game)
	if not _capture_dir.is_empty():
		# A real viewport render target permits readback without fixture data.
		# Direct canvas-item output can report a zero-sized root texture.
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		root.content_scale_size = BUNKER_SIZE
		_game._ui.exact_capture_mode = true
	await settle()
	if not route("title"): await finish(); return
	await key(KEY_ENTER)
	if not route("main_menu"): await finish(); return
	var main: Control = _game._ui.screen
	check(not main.get_node("MenuContinue").visible and not main.get_node("ContinueAction").visible, "one campaign-entry action, no duplicate Continue")
	check(not (main.get_node("MenuPlay") as ZMenuActionCard).disabled, "New or Continue is enabled")
	await capture("01-main-menu.png")
	if not await click("MenuPlay/Hit") or not route("bunker"): await finish(); return
	var initial := _store.load_profile()
	if not check(initial.ok and (initial.generation == 1 if _run_mode == "new" else initial.fingerprint == saved.fingerprint), "entry never reseeds existing progress"): await finish(); return
	if OS.get_environment("ZERKOV_BUNKER_WORKSPACES") == "1":
		var driver = load("res://tests/local/bunker_workspaces_driver.gd").new()
		if not await driver.run(self, initial): await finish(); return
		print("BUNKER_WORKSPACES_COMPLETE native=true")
		print("BUNKER_FLOW_FINGERPRINT ", initial.fingerprint)
		await finish()
		return
	var owner_id: int = _game._home.get_instance_id()
	if not hub("storage"): await finish(); return
	await capture("02-bunker-storage.png")
	# The old reflow pass used to show a second NavigationChrome over the map.
	_game._ui.screen.queue_adaptive_layout()
	await settle()
	if not hub("storage"): await finish(); return
	var view := hideout()
	for entry: Array in [["LocalLoadout", ZerkovInputActions.UI_OPEN_INVENTORY],
		["LocalDeploy", ZerkovInputActions.UI_OPEN_MAP], ["LocalTasks", ZerkovInputActions.UI_OPEN_TASKS]]:
		var binding: CommonUIBinding = _game._ui.input_service.effective_binding(entry[1], CommonUIBinding.SLOT_PRIMARY)
		check(String(view.get_node(entry[0]).text).begins_with(CommonBindingText.describe(binding)), "hint comes from actual effective binding")
	check(view.get_node("FacilityAction").text == "OPEN STASH / LOADOUT", "storage explains its real destination")
	if not await click("BunkerHideoutView/FacilityAction") or not route("inventory"): await finish(); return
	check(_game._character.inventory_view(&"raid").is_ready(), "same native inventory workspace")
	check(_game._home.get_instance_id() == owner_id, "opening a room never constructs a second inventory owner")
	await capture("03-loadout.png")
	await key(KEY_ESCAPE)
	if not route("bunker") or not hub("storage"): await finish(); return
	# Map clicks and sidebar controls select the same room/action model.
	await room_click("medical")
	if not hub("medical"): await finish(); return
	if not await click("BunkerHideoutView/FacilityAction") or not route("health"): await finish(); return
	await key(KEY_ESCAPE)
	if not route("bunker") or not hub("medical"): await finish(); return
	if not await click("BunkerHideoutView/Select_utilities"): await finish(); return
	check(hideout().get_node("FacilityAction").disabled, "unimplemented utilities have no pretend gameplay action")
	await capture("04-unavailable-facility.png")
	await room_click("workshop")
	if not hub("workshop"): await finish(); return
	# Root defense: no retained or forged hub command may skip the briefing.
	_game._ui_port.request(&"deploy", _game._epoch)
	await settle()
	if not check(_game._session == null and _game._mode == "home" and _game._ui.current_route == "bunker", "direct hub deployment rejected"): await finish(); return
	await capture("05-bunker-planning.png")
	if not await click("BunkerHideoutView/FacilityAction") or not route("maps"): await finish(); return
	check(_game._session == null and _game._home.get_instance_id() == owner_id, "planning opens briefing without starting a raid")
	check((_game._ui.screen.get_node("Deploy") as Button).text == "DEPLOY SOLO TO SAWMILL", "only briefing contains explicit deployment action")
	await capture("06-raid-briefing.png")
	await key(KEY_ESCAPE)
	if not route("bunker") or not hub("workshop"): await finish(); return
	await key(KEY_M)
	if not route("maps"): await finish(); return
	await key(KEY_ESCAPE)
	if not route("bunker") or not hub("workshop"): await finish(); return
	await key(KEY_J)
	if not route("tasks"): await finish(); return
	await key(KEY_ESCAPE)
	if not route("bunker") or not hub("workshop"): await finish(); return
	await key(KEY_I)
	if not route("inventory"): await finish(); return
	await key(KEY_ESCAPE)
	if not route("bunker") or not hub("workshop"): await finish(); return
	check(_store.load_profile().fingerprint == initial.fingerprint, "room and shortcut navigation cannot change save data")
	await key(KEY_ESCAPE)
	if not route("pause"): await finish(); return
	await capture("07-home-menu.png")
	if not await click("ActionsPanel/SettingsRow/Hit") or not route("controls"): await finish(); return
	await key(KEY_ESCAPE)
	if not route("bunker"): await finish(); return
	await key(KEY_ESCAPE)
	if not route("pause"): await finish(); return
	var retired_epoch: int = _game._epoch
	if not await click("ActionsPanel/SaveQuitRow/Hit") or not route("main_menu"): await finish(); return
	check(_game._home == null and _game._session == null, "main menu closes live bunker without creating a raid")
	check(not _game._ui_port.request(&"deploy", retired_epoch), "old home epoch cannot deploy after closing")
	check(_store.load_profile().fingerprint == initial.fingerprint, "menu return preserves exact saved campaign")
	if not await click("MenuPlay/Hit") or not route("bunker") or not hub("storage"): await finish(); return
	check(_store.load_profile().fingerprint == initial.fingerprint, "same-process Continue does not reissue starter items")
	print("BUNKER_FLOW_FINGERPRINT ", initial.fingerprint)
	await finish()

func hideout() -> ZBunkerHideoutView:
	return _game._ui.screen.get_node("BunkerHideoutView") as ZBunkerHideoutView

func hub(room: String) -> bool:
	var screen: Control = _game._ui.screen
	var old_nodes := ["NavigationChrome", "TopChrome", "Stations", "StationDetails", "Marker1Card"]
	for name: String in old_nodes:
		if not check(screen.get_node_or_null(name) == null, "placeholder node absent: " + name): return false
	var views: int = 0
	for child: Node in screen.get_children():
		if child is CanvasItem: views += 1
	check(views == 1, "exactly one rendered bunker root")
	check(hideout().current_room == room and hideout().surface.size == Vector2i(640, 360), "room selection preserved and authored raster retained")
	check(hideout().get_node("SessionStatus").text == "LOCAL SAVE  /  SOLO", "bound home is not labelled a visual preview")
	check(_game._session == null, "no active raid while inspecting home")
	return failures == 0

func room_click(room_id: String) -> void:
	for room: Dictionary in hideout().world.layout.rooms:
		if room.id != room_id: continue
		var bounds: Array = room.rect
		var local := Vector2(bounds[0] + bounds[2] * 0.5, bounds[1] + bounds[3] * 0.5) * 3.0
		var at := hideout().get_global_transform() * local
		for pressed: bool in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = at; event.button_index = MOUSE_BUTTON_LEFT; event.pressed = pressed
			root.push_input(event)
		await settle()
		return
	check(false, "room exists in authored layout")

func capture(filename: String) -> void:
	if _capture_dir.is_empty() or failures > 0: return
	await settle()
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_capture_dir)
	if not Exact1080CaptureGuard.accepts(root, root, image):
		check(false, "physical exact-1080 capture guard: window=%s root=%s viewport=%s texture=%s image=%s" % [DisplayServer.window_get_size(root.get_window_id()), root.size, root.get_visible_rect().size, root.get_texture().get_size(), image.get_size()])
		return
	var result := image.save_png(_capture_dir.path_join(filename))
	check(result == OK, "save actual application image")

func finish() -> void:
	if _game != null and is_instance_valid(_game):
		check(_game.shutdown(), "application closes local writer: " + String(_game.last_error))
		_game.queue_free(); await settle(); _game = null
	if _store != null and _store.is_configured(): _store.close()
	print("BUNKER_FLOW_RESULT checks=", checks, " failures=", failures, " mode=", _run_mode)
	quit(0 if failures == 0 else 1)
