extends SceneTree
## Actual application entrypoint, native owners and real input. Only storage
## namespace and physics pacing are isolated; new-game content is issued by UI.
const EXACT_SIZE := Vector2i(1920, 1080)
var checks: int = 0
var failures: int = 0
var _game: LocalGame
var _store: ProfileStore
var _operations: GodotProfileFileOperations
var _namespace: String

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> bool:
	checks += 1
	if not ok:
		failures += 1
		push_error("NATIVE_LOCAL_FLOW: " + message)
	return ok

func settle() -> void:
	for _i in range(8): await process_frame
	await create_timer(0.03).timeout

func key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.pressed = down
		root.push_input(event)
	await settle()

func click(path: String) -> bool:
	var control := _game._ui.screen.get_node_or_null(path) as Control
	if not check(control != null and control.is_visible_in_tree(), "visible input target " + path): return false
	var point := control.get_global_rect().get_center()
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event)
	await settle()
	return failures == 0

func route(expected: String) -> bool:
	print("LOCAL_FLOW_STAGE route=", _game._ui.current_route, " mode=", _game._mode, " error=", _game.last_error)
	return check(_game._ui.current_route == expected and _game.last_error.is_empty(), "production route " + expected) \
		and check(not _game._ui.screen.get("_production_state_locked") and _game._ui.fixture_provider_for_test() == null,
			"ready production screen without fixtures")

func run() -> void:
	# Headless display setup occurs after _initialize and resets Window.size.
	# Establish the approved canvas here, before any scene mount.
	root.size = EXACT_SIZE
	create_timer(100.0).timeout.connect(func() -> void: push_error("LOCAL_FLOW_TIMEOUT"); quit(1))
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args[0] not in ["run", "verify", "cleanup"] \
		or not args[1].begins_with("localflow_") or args[1].length() != 42 or not args[1].substr(10).is_valid_hex_number():
		push_error("LOCAL_FLOW_INVALID_NAMESPACE"); quit(2); return
	_namespace = args[1]
	_operations = GodotProfileFileOperations.new(StringName(_namespace))
	_store = ProfileStore.new()
	if not check(_store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, _operations), "isolated real store configures"):
		quit(1); return
	if args[0] == "cleanup":
		for slot in ProfileFileOperations.ALL_SLOTS: check(_operations.remove_slot(slot).get("ok", false), "isolated cleanup slot")
		_store.close()
		print("LOCAL_FLOW_CLEANUP checks=", checks, " failures=", failures)
		quit(failures); return
	if args[0] == "verify":
		var loaded := _store.load_profile()
		check(args.size() == 3 and loaded.get("ok") == true and loaded.get("fingerprint") == args[2], "fresh process exact local envelope")
		check(loaded.payload.project[RaidProgressionValues.STATE_KEY].active.is_empty(), "no live escrow after acknowledged outcomes")
		_store.close()
		print("LOCAL_FLOW_VERIFY checks=", checks, " failures=", failures)
		quit(failures); return
	if not check(root.size == EXACT_SIZE and root.get_visible_rect().size == Vector2(EXACT_SIZE), "exact 1920x1080 before mount"):
		quit(1); return
	if not check(_store.load_profile().get("reason") == &"profile_missing", "new namespace, no fixtures seeded"):
		quit(1); return
	_game = load("res://game/bootstrap/local/local_game.tscn").instantiate() as LocalGame
	_game.configure_test_store(_store, false)
	root.add_child(_game)
	await settle()
	if not route("title"): await finish(); return
	await key(KEY_ENTER)
	if not route("main_menu"): await finish(); return
	if not await click("MenuPlay/Hit") or not route("bunker"): await finish(); return
	check(_store.load_profile().generation == 1, "explicit new game committed once")
	check(not _game._ui_port.request(&"create", _game._epoch - 1), "retired UI epoch cannot issue a new profile")
	if not await click("StationDetails/AltUseAction") or not route("inventory"): await finish(); return
	check(_game._character.inventory_view(&"raid").is_ready(), "existing inventory workspace consumes native loadout")
	await key(KEY_ESCAPE)
	if not route("bunker"): await finish(); return
	if not await click("StationDetails/UpgradeAction") or not route("hud"): await finish(); return
	check(_game._session.rows.size() == 3 and _game._session.ai != null, "player Scav and mutant in real runtime")
	check(not _store.load_profile().payload.project[RaidProgressionValues.STATE_KEY].active.is_empty(), "deployment escrow precedes gameplay")
	for _i in range(70):
		if not check(_game.advance(), "all native phases and after-tick closeout"): await finish(); return
	var timer: String = (_game._ui.screen.get_node("TimerGroup/Timer") as Label).text
	check(timer != "—" and timer != "15:00", "HUD clock derives from completed canonical ticks")
	var prior_tick: int = _game._session.raid.last_processed_tick
	await key(KEY_ESCAPE)
	if not route("pause"): await finish(); return
	check(not _game.advance() and _game._session.raid.last_processed_tick == prior_tick, "solo pause does not secretly advance raid")
	if not await click("ActionsPanel/ResumeRow/Hit") or not route("hud"): await finish(); return
	check(_game.advance(), "resume keeps the same live authority")
	# This first root regression exercises explicit abandonment and redeployment.
	# It does not claim extraction traversal or a human-controlled combat session.
	await key(KEY_ESCAPE)
	if not await click("ActionsPanel/SaveQuitRow/Hit"): await finish(); return
	var modal: Control = _game._ui.modal
	if not check(is_instance_valid(modal), "abandon requires explicit UI confirmation"): await finish(); return
	var confirm: BaseButton
	for node: Node in modal.find_children("*", "BaseButton", true, false):
		if node is Button and (node.text.to_upper().contains("CONFIRM") or node.text.to_upper().contains("CONTINUE")): confirm = node
	if confirm == null:
		for node: Node in modal.find_children("*", "BaseButton", true, false):
			if node is Button and not node.text.to_upper().contains("CANCEL"): confirm = node
	if not check(confirm != null, "visible confirmation action"): await finish(); return
	var center := confirm.get_global_rect().get_center()
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = center; event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event)
	await settle()
	if not route("summary_solo"): await finish(); return
	check(_game._summary.outcome == "abandoned", "real abandonment settlement, not sample result")
	check(_game._provider.summary_view(_game._epoch).is_ready(), "receipt converted to established SummaryView")
	var generation: int = _store.load_profile().generation
	if not await click("BackBunker") or not route("bunker"): await finish(); return
	check(_store.load_profile().generation == generation, "return home does not apply settlement twice")
	if not await click("StationDetails/UpgradeAction") or not route("hud"): await finish(); return
	check(_game._session.combat.health.actor_snapshot(_game._session.raid.admission().actor_id).alive, "second raid creates recovered live GAS actor")
	check(_game._session.hud_model.snapshot().has_weapon == false, "loss does not trigger fallback weapon seed")
	# Closing a live second raid leaves escrow for the genuine fresh-process recovery test.
	check(_game.shutdown(), "normal shutdown releases owners, not committed save bytes")
	_game.queue_free(); await settle(); _game = null
	_store = ProfileStore.new()
	_operations = GodotProfileFileOperations.new(StringName(_namespace))
	check(_store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, _operations), "reopen isolated store")
	var campaign := LocalCampaign.new()
	check(campaign.open(_store), "interrupted second raid recovers on local open")
	var recovered := _store.load_profile()
	check(recovered.payload.project[RaidProgressionValues.STATE_KEY].active.is_empty(), "recovery closes the second escrow")
	print("LOCAL_FLOW_FINGERPRINT ", recovered.fingerprint)
	await finish()

func finish() -> void:
	if _game != null and is_instance_valid(_game):
		check(_game.shutdown(), "root shutdown")
		_game.queue_free(); await settle(); _game = null
	if _store != null and _store.is_configured(): _store.close()
	print("NATIVE_LOCAL_FLOW_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
