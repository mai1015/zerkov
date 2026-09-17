extends SceneTree
## Real application and actual input; only file namespace and tick pacing are
## isolated. This is functional acceptance, not a frame-rate or human playtest.
# Only one write failure is injected; every other operation uses actual files.
class FailOnceFileOperations:
	extends GodotProfileFileOperations
	var fail_next_write: bool = false
	var injected_count: int = 0
	func _init(test_namespace: StringName) -> void:
		super(test_namespace)
	func write_temp(slot: StringName, bytes: PackedByteArray) -> Dictionary:
		if fail_next_write:
			fail_next_write = false
			injected_count += 1
			return {"ok": false, "reason": &"injected_local_write_failure"}
		return super.write_temp(slot, bytes)

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
	root.size = EXACT_SIZE
	print("LOCAL_FLOW_SCENARIO ", OS.get_environment("ZERKOV_TEST_SCENARIO"))
	create_timer(600.0).timeout.connect(func() -> void: push_error("LOCAL_FLOW_TIMEOUT"); quit(1))
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args[0] not in ["run", "verify", "cleanup"] \
		or not args[1].begins_with("localflow_") or args[1].length() != 42 or not args[1].substr(10).is_valid_hex_number():
		push_error("LOCAL_FLOW_INVALID_NAMESPACE"); quit(2); return
	_namespace = args[1]
	_operations = FailOnceFileOperations.new(StringName(_namespace))
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
		# A newly created campaign has no raid progression record yet. Production
		# LocalCampaign uses the same initial-state default before first deployment.
		var state: Dictionary = loaded.get("payload", {}).get("project", {}).get(
			RaidProgressionValues.STATE_KEY, RaidProgressionValues.initial_state())
		check(RaidProgressionValues.valid_state(state) and state.active.is_empty(), "no live escrow after acknowledged outcomes")
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
	if OS.get_environment("ZERKOV_TEST_SCENARIO") == "launch":
		await _verify_launch_menu()
		await finish(); return
	if not await click("MenuPlay/Hit") or not route("bunker"): await finish(); return
	check(_store.load_profile().generation == 1, "explicit new game committed once")
	check(not _game._ui_port.request(&"create", _game._epoch - 1), "retired UI epoch cannot issue a new profile")
	if not await click("BunkerHideoutView/LocalLoadout") or not route("inventory"): await finish(); return
	check(_game._character.inventory_view(&"raid").is_ready(), "existing inventory workspace consumes native loadout")
	await key(KEY_ESCAPE)
	if not route("bunker"): await finish(); return
	if not await click("BunkerHideoutView/LocalDeploy") or not route("hud"): await finish(); return
	check(_game._session.rows.size() == 3 and _game._session.ai != null, "player Scav and mutant in real runtime")
	check(not _store.load_profile().payload.project[RaidProgressionValues.STATE_KEY].active.is_empty(), "deployment escrow precedes gameplay")
	if OS.get_environment("ZERKOV_TEST_SCENARIO") == "clock":
		var probe = load("res://tests/local/local_clock_driver.gd").new()
		if not await probe.run(_game, self, Callable(self, "check")): await finish(); return
		# The smoke ends a live raid by ordinary application shutdown, then uses
		# the existing recovery path. It never manufactures an extraction result.
		if not check(_game.shutdown(), "normal-clock application shutdown"): await finish(); return
		_game.queue_free(); await settle(); _game = null
		_store = ProfileStore.new()
		_operations = GodotProfileFileOperations.new(StringName(_namespace))
		if not check(_store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, _operations), "clock reopen real local files"): await finish(); return
		var campaign := LocalCampaign.new()
		if not check(campaign.open(_store), "clock recover interrupted raid"): await finish(); return
		print("LOCAL_FLOW_FINGERPRINT ", _store.load_profile().fingerprint)
		await finish(); return
	if OS.get_environment("ZERKOV_TEST_SCENARIO") == "death":
		var probe = load("res://tests/local/local_flow_player_driver.gd").new()
		if not await probe.die_from_enemy(_game, self, Callable(self, "check")): await finish(); return
		var committed := _store.load_profile()
		check(committed.ok and committed.payload.project[RaidProgressionValues.STATE_KEY].active.is_empty(), "targeted death committed locally")
		print("LOCAL_FLOW_FINGERPRINT ", committed.fingerprint)
		await finish(); return
	var presentation_before := _game.presentation_work_counts()
	var health_work_before := _game._session.combat.health.work_counts()
	for _i in range(70):
		if not check(_game.advance(), "all native phases and after-tick closeout"): await finish(); return
	var presentation_after := _game.presentation_work_counts()
	var health_work_after := _game._session.combat.health.work_counts()
	check(int(presentation_after.raid_view_builds) == int(presentation_before.raid_view_builds) + 70
		and int(presentation_after.bunker_view_builds) == int(presentation_before.bunker_view_builds)
		and int(presentation_after.task_view_builds) == int(presentation_before.task_view_builds)
		and int(presentation_after.map_view_builds) == int(presentation_before.map_view_builds)
		and int(presentation_after.summary_view_builds) == int(presentation_before.summary_view_builds),
		"idle raid rebuilds only the clock-bearing raid view")
	check(int(presentation_after.health_view_builds) == int(presentation_before.health_view_builds),
		"unchanged player health does not rebuild or republish HealthView")
	check(int(health_work_after.full_actor_audits) == int(health_work_before.full_actor_audits)
		and int(health_work_after.snapshot_builds) == int(health_work_before.snapshot_builds)
		and int(health_work_after.runtime_guards) == int(health_work_before.runtime_guards) + 210,
		"three idle actors use bounded guards without full audits or snapshot rebuilds")
	var timer: String = (_game._ui.screen.get_node("TimerGroup/Timer") as Label).text
	check(timer != "—" and timer != "15:00", "HUD clock derives from completed canonical ticks")
	var prior_tick: int = _game._session.raid.last_processed_tick
	await key(KEY_ESCAPE)
	if not route("pause"): await finish(); return
	check(not _game.advance() and _game._session.raid.last_processed_tick == prior_tick, "solo pause does not secretly advance raid")
	if not await click("ActionsPanel/ResumeRow/Hit") or not route("hud"): await finish(); return
	check(_game.advance(), "resume keeps the same live authority")
	var driver = load("res://tests/local/local_flow_player_driver.gd").new()
	# Fail the first settlement write AFTER traversing the map, then exercise
	# Retry through the actual pending-summary button, not service methods.
	_operations.set("fail_next_write", true)
	if not await driver.extract(_game, self, Callable(self, "check"), true): await finish(); return
	check(_operations.get("injected_count") == 1, "exactly one actual-file write failure injected")
	if not route("summary_solo"): await finish(); return
	var extract_generation: int = _store.load_profile().generation
	if not await click("BackBunker") or not route("bunker"): await finish(); return
	check(_store.load_profile().generation == extract_generation, "return after extract does not settle twice")
	if not await click("BunkerHideoutView/LocalDeploy") or not route("hud"): await finish(); return
	check(_game._session.hud_model.snapshot().has_weapon, "extraction retains actual equipped weapon")
	await key(KEY_ESCAPE)
	if not await click("ActionsPanel/SaveQuitRow/Hit"): await finish(); return
	var modal: Control = _game._ui.modal
	if not check(is_instance_valid(modal), "abandon requires explicit confirmation"): await finish(); return
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
	check(_game._summary.outcome == "abandoned", "real abandonment settlement")
	check(_game._provider.summary_view(_game._epoch).is_ready(), "receipt converted to established SummaryView")
	var generation: int = _store.load_profile().generation
	if not await click("BackBunker") or not route("bunker"): await finish(); return
	check(_store.load_profile().generation == generation, "return does not settle twice")
	if not await click("BunkerHideoutView/LocalDeploy") or not route("hud"): await finish(); return
	check(_game._session.combat.health.actor_snapshot(_game._session.raid.admission().actor_id).alive, "new raid creates recovered live GAS actor")
	check(not _game._session.hud_model.snapshot().has_weapon, "loss does not trigger weapon seed")
	var death_driver = load("res://tests/local/local_flow_player_driver.gd").new()
	if not await death_driver.die_from_enemy(_game, self, Callable(self, "check")): await finish(); return
	if not route("summary_solo"): await finish(); return
	var death_generation: int = _store.load_profile().generation
	check(not _game._summary.health.alive and _game._summary.stats.damage_received_micros > 0, "death summary uses actual committed health and damage")
	if not await click("BackBunker") or not route("bunker"): await finish(); return
	check(_store.load_profile().generation == death_generation, "home recovery does not rewrite historical death settlement")
	if not await click("BunkerHideoutView/LocalDeploy") or not route("hud"): await finish(); return
	check(_game._session.combat.health.actor_snapshot(_game._session.raid.admission().actor_id).alive, "post-death deployment creates live recovered health")
	check(not _game._session.hud_model.snapshot().has_weapon, "death recovery does not recreate lost firearm")
	check(_game.shutdown(), "shutdown leaves live escrow, not fabricated results")
	_game.queue_free(); await settle(); _game = null
	_store = ProfileStore.new()
	_operations = GodotProfileFileOperations.new(StringName(_namespace))
	check(_store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, _operations), "reopen isolated store")
	var campaign := LocalCampaign.new()
	check(campaign.open(_store), "interrupted raid recovered on local open")
	var recovered := _store.load_profile()
	check(recovered.payload.project[RaidProgressionValues.STATE_KEY].active.is_empty(), "recovery closes escrow")
	print("LOCAL_FLOW_FINGERPRINT ", recovered.fingerprint)
	await finish()

func finish() -> void:
	if _game != null and is_instance_valid(_game):
		var stopped := _game.shutdown()
		check(stopped, "root shutdown: " + String(_game.last_error))
		_game.queue_free(); await settle(); _game = null
	if _store != null and _store.is_configured(): _store.close()
	print("NATIVE_LOCAL_FLOW_RESULT checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

## Reopens the actual root on empty, valid and corrupt local files. The test
## namespace is an isolated UUID, never the production `profiles` namespace.
func _verify_launch_menu() -> void:
	var entry: Dictionary = LocalFlowBinding.primary_entry({"has_profile":true, "can_create":true, "error":"read_failed"})
	check(not entry.enabled and entry.command.is_empty(), "save error wins over stale availability flags")
	entry = LocalFlowBinding.primary_entry({"has_profile":false, "can_create":false, "error":"", "notice":"not injected"})
	check(not entry.enabled and not entry.detail.is_empty(), "unavailable data never enables fixture creation")
	var play := _game._ui.screen.get_node("MenuPlay") as ZMenuActionCard
	if not check(not play.disabled and not play.get_focus_target().disabled and play.card_title == "NEW LOCAL GAME", "empty local profile enables real New Game"): return
	if not check((_game._ui.screen.get_node("MenuContinue") as ZMenuActionCard).disabled, "no Continue before a campaign exists"): return
	if not await click("MenuPlay/Hit") or not route("bunker"): return
	var created := _store.load_profile()
	if not check(created.ok and created.generation == 1, "New Game creates exactly one local generation"): return
	if not await _close_launch_root(): return
	if not await _mount_launch_root(): return
	await key(KEY_ENTER)
	if not route("main_menu"): return
	play = _game._ui.screen.get_node("MenuPlay") as ZMenuActionCard
	check(not play.disabled and not play.get_focus_target().disabled and play.card_title == "CONTINUE LOCAL GAME", "existing save leaves the primary entry enabled as Continue")
	check(play.card_subtitle.contains("kept") and not play.tooltip_text.is_empty(), "primary entry explains save preservation")
	var bound := _game._ui.screen.get("_local_binding") as LocalFlowBinding
	# Same-screen re-publication must retire the earlier command, not retain two
	# callbacks. Restore the real frame before physical input; no save is mutated.
	bound.call("_card", "MenuPlay", "NEW LOCAL GAME", "test transition", &"create", true)
	bound.refresh()
	var callbacks := play.get_signal_connection_list(&"activated")
	var ours: int = 0
	for row: Dictionary in callbacks:
		var callback: Callable = row.callable
		if callback.get_object() == bound:
			ours += 1
			check(callback.get_bound_arguments() == [&"continue"], "old create callback was retired")
	check(ours == 1, "one current primary action after rebinding")
	if not await click("MenuPlay/Hit") or not route("bunker"): return
	var continued := _store.load_profile()
	check(continued.fingerprint == created.fingerprint and continued.generation == 1, "primary Continue preserves exact saved bytes and never reissues starter content")
	if not await _close_launch_root(): return
	# Save originals before creating a corruption scenario in this private namespace.
	var originals: Dictionary = {}
	for slot: StringName in [ProfileFileOperations.SLOT_PRIMARY, ProfileFileOperations.SLOT_BACKUP]:
		originals[slot] = _operations.read_slot(slot, ProfileStore.MAX_PROFILE_FILE_BYTES)
	var corrupt := "not a valid profile envelope".to_utf8_buffer()
	var injected: bool = true
	for pair: Array in [[ProfileFileOperations.SLOT_WRITE_TEMP, ProfileFileOperations.SLOT_PRIMARY],
		[ProfileFileOperations.SLOT_BACKUP_TEMP, ProfileFileOperations.SLOT_BACKUP]]:
		injected = check(_operations.write_temp(pair[0], corrupt).get("ok", false), "isolated corruption write") and injected
		injected = check(_operations.replace_slot(pair[0], pair[1]).get("ok", false), "isolated corruption replacement") and injected
	if injected and await _mount_launch_root():
		await key(KEY_ENTER)
		check(_game._ui.current_route == "main_menu" and not _game.last_error.is_empty(), "corrupt save reaches a diagnostic menu")
		play = _game._ui.screen.get_node("MenuPlay") as ZMenuActionCard
		check(play.disabled and play.get_focus_target().disabled, "corrupt save cannot be silently replaced")
		check(play.card_title == "LOCAL SAVE UNAVAILABLE" and play.card_subtitle.contains(String(_game.last_error)), "disabled primary visibly explains the actual failure")
		var notices := (_game._ui.screen.get_node("ContinueCard/CloudStatus") as Label).text
		check(notices.contains(String(_game.last_error)), "save failure remains visible outside the disabled button")
		await click("MenuPlay/Hit")
		check(_game._ui.current_route == "main_menu", "disabled New Game cannot navigate or create")
		for slot: StringName in originals:
			check(_operations.read_slot(slot, ProfileStore.MAX_PROFILE_FILE_BYTES).get("bytes") == corrupt, "launch did not overwrite the corrupt file")
		await _close_launch_root()
	# Restore only this test's files, regardless of the corrupt-state assertions.
	for pair: Array in [[ProfileFileOperations.SLOT_WRITE_TEMP, ProfileFileOperations.SLOT_PRIMARY],
		[ProfileFileOperations.SLOT_BACKUP_TEMP, ProfileFileOperations.SLOT_BACKUP]]:
		var original: Dictionary = originals[pair[1]]
		if original.get("state") == ProfileFileOperations.STATE_MISSING:
			check(_operations.remove_slot(pair[1]).get("ok", false), "remove isolated test backup that did not originally exist")
		else:
			check(_operations.write_temp(pair[0], original.bytes).get("ok", false), "restore isolated original bytes")
			check(_operations.replace_slot(pair[0], pair[1]).get("ok", false), "restore isolated original slot")
	if not await _mount_launch_root(): return
	var restored := _store.load_profile()
	check(restored.ok and restored.fingerprint == created.fingerprint, "all launch cases preserve the original campaign")
	print("LOCAL_LAUNCH_MENU_COMPLETE fresh_create=true existing_continue=true corrupt_preserved=true")
	print("LOCAL_FLOW_FINGERPRINT ", restored.fingerprint)

func _close_launch_root() -> bool:
	if not check(_game.shutdown(), "launch scenario closes local writer"): return false
	_game.queue_free(); await settle(); _game = null
	return true

func _mount_launch_root() -> bool:
	_operations = GodotProfileFileOperations.new(StringName(_namespace))
	_store = ProfileStore.new()
	if not check(_store.configure_with_trusted_operations(LocalCampaignContent.PROFILE_ID, _operations), "launch scenario reopens isolated real file store"): return false
	_game = load("res://game/bootstrap/local/local_game.tscn").instantiate() as LocalGame
	if not check(_game.configure_test_store(_store, false), "launch store injection before mount"): return false
	root.add_child(_game)
	await settle()
	return check(_game._ui != null and _game._ui.current_route == "title", "normal local root mounts the title")
