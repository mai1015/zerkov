extends SceneTree
## Normal production root, no fixture provider or injected session/loadout.
const EXACT := Vector2i(1920, 1080)
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
var checks := 0
var failures := 0
var product: Node
var app: Control
var mode := "create"
var output := ""

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	print("OFFLINE_CHECK ", checks, " ", label, " ok=", ok)
	if not ok:
		failures += 1
		push_error("OFFLINE_FLOW_ASSERTION: " + label)

func settle() -> void:
	for _i: int in range(12):
		await process_frame
	await create_timer(0.12).timeout

func key(code: Key) -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = down
		root.push_input(event)
	await settle()

func click(node: Control, control := false) -> void:
	check(node != null and node.is_visible_in_tree(), "visible input target")
	if node == null:
		return
	var at := node.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.ctrl_pressed = control
		event.pressed = down
		root.push_input(event)
	await settle()

func slot_for(definition: String) -> Control:
	var grid := app.screen._grid_for_source("stash") as Control
	if grid == null:
		return null
	for slot: Control in grid._slots:
		if slot.item.get("definition_id", "") == definition:
			return slot
	return null

func capture(name: String) -> void:
	if output.is_empty() or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if not Exact1080CaptureGuard.accepts(root, root, image):
		check(false, "exact physical capture")
		return
	check(image.save_png(output.path_join(name + ".png")) == OK, "native capture " + name)

func run() -> void:
	create_timer(65.0).timeout.connect(func(): check(false, "flow watchdog"); finish())
	root.size = EXACT
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--offline-case="):
			mode = arg.trim_prefix("--offline-case=")
		elif arg.begins_with("--capture-dir="):
			output = arg.trim_prefix("--capture-dir=")
	if DisplayServer.get_name() != "headless":
		root.borderless = true
		root.position = Vector2i.ZERO
		root.size = EXACT
	await settle()
	print("OFFLINE_OUTPUT_PREFLIGHT window=", root.size, " viewport=", root.get_visible_rect().size)
	var exact := root.size == EXACT and root.get_visible_rect().size == Vector2(EXACT)
	check(exact, "exact output")
	if not exact:
		finish()
		return
	if DisplayServer.get_name() != "headless":
		print("OFFLINE_PHYSICAL_DISPLAY window=", DisplayServer.window_get_size(root.get_window_id()), " screen=", DisplayServer.screen_get_size())
		await RenderingServer.frame_post_draw
		var preflight := root.get_texture().get_image()
		check(Exact1080CaptureGuard.accepts(root, root, preflight), "physical output before product mount")
		if not Exact1080CaptureGuard.accepts(root, root, preflight):
			finish()
			return
	product = load("res://game/bootstrap/offline_application.tscn").instantiate()
	root.add_child(product)
	await settle()
	app = product.get_node("Main")
	check(app.current_route == "title", "normal title")
	check(not app.qa_mode and not app.prototype_fixture_mode, "no preview flags")
	check(app.fixture_provider_for_test() == null, "no fixture provider")
	await capture("offline-title-1080")
	await key(KEY_ENTER)
	check(app.current_route == "main_menu" and app.screen.accepts_input(), "unlocked offline menu")
	await capture("offline-menu-1080")
	var session: OfflineBunkerSession = product.session
	check(session.status().steam_required == false and not session.is_open(), "no Steam or active profile required at menu")
	check(session.status().disk_status == ("missing" if mode == "create" else "available"), "expected initial disk state " + str(session.status()))
	await click(app.screen.get_node("ContinueAction"))
	check(app.current_route == "bunker" and session.is_open(), "normal New/Continue enters bunker")
	if not session.is_open() or app.current_route != "bunker":
		finish()
		return
	check(not session.status().deployment_ready, "deployment remains disabled")
	check(product.find_children("*", "RaidAuthority", true, false).is_empty(), "no hidden RaidAuthority")
	await capture("offline-bunker-1080")
	await key(KEY_I)
	check(app.current_route == "inventory", "normal Inventory action enters existing inventory")
	if app.current_route != "inventory":
		finish()
		return
	var controller := app.screen._inventory_controller as OfflineInventoryController
	check(controller != null and controller.is_bound(), "pre-raid controller bound")
	check(controller.inventory_view(&"profile").is_ready(), "ready immutable stash projection")
	if mode == "create":
		check(controller.items_for(&"stash").size() == 5, "one versioned starter kit")
		var initial_revision := session.revision()
		# CTRL click is handled by the real retained inventory widget, not its callback.
		await click(slot_for(String(ZerkovInventoryCatalog.ITEM_AMMO_762)), true)
		check(controller.items_for(&"pockets").size() == 1, "native CTRL click transfers ammo to pockets")
		check(session.revision() > initial_revision, "accepted edit changes confirmed native revision")
		await click(slot_for(String(ZerkovInventoryCatalog.ITEM_AKM)))
		await click(app.screen._node("CharacterColumn/SlingSlot"))
		check(not controller.equipment("zerkov.slot.weapon_primary").is_empty(), "native click equips AKM")
		await click(app.screen._node("CharacterColumn/SlingSlot"))
		check(controller.equipment("zerkov.slot.weapon_primary").is_empty(), "native click unequips to stash")
		# Leave a persisted equipped weapon for the independent Continue process.
		await click(slot_for(String(ZerkovInventoryCatalog.ITEM_AKM)))
		await click(app.screen._node("CharacterColumn/SlingSlot"))
		check(not controller.equipment("zerkov.slot.weapon_primary").is_empty(), "equipped final loadout")
	else:
		check(controller.items_for(&"pockets").size() == 1, "fresh process restores moved ammo")
		check(not controller.equipment("zerkov.slot.weapon_primary").is_empty(), "fresh process restores equipped weapon")
		check(controller.items_for(&"stash").size() == 3, "Continue did not reseed starter items")
	await capture("offline-inventory-1080")
	var item := controller.items_for(&"stash")[0].duplicate(true)
	item.offline_revision -= 1
	var before := session.revision()
	check(not controller.submit_rotate(&"stash", item).accepted and session.revision() == before, "stale drag rejection is mutation-free")
	await key(KEY_I)
	check(app.current_route == "bunker", "Inventory action returns to same bunker")
	await key(KEY_ESCAPE)
	check(app.current_route == "pause", "normal Escape pause")
	await click(app.screen.get_node("ActionsPanel/SettingsRow/Hit"))
	check(app.current_route == "settings" and app.screen.accepts_input(), "local settings available")
	var master: HSlider = null
	for child: Node in app.screen.find_children("*", "HSlider", true, false):
		if str(child.get_meta("settings_key", "")) == "audio_master":
			master = child
	check(master != null and master.editable, "real local master-volume control")
	if mode == "create" and master != null:
		await click(master)
	check(session.status().master_volume != 80, "master volume changed and restored with profile")
	check(is_equal_approx(AudioServer.get_bus_volume_linear(0), float(session.status().master_volume) / 100.0), "audio follows saved setting")
	check(app.screen.get_node("SettingAudioMasterValue").text == "%d%%" % int(session.status().master_volume), "visible volume label matches saved value")
	await capture("offline-settings-1080")
	await click(app.screen.get_node("OfflineControlBindings"))
	check(app.current_route == "controls", "existing rebind controls available")
	await key(KEY_ESCAPE)
	check(app.current_route == "pause", "workspace replacement restores original pause caller")
	await key(KEY_ESCAPE)
	check(app.current_route == "bunker", "back stack restores bunker")
	check(app.fixture_provider_for_test() == null, "entire normal flow remains fixture-free")
	check(session._payload.project.keys() == ["offline_bunker"] and session._payload.domains.keys() == [OfflineBunkerCatalog.DOMAIN], "no raid, escrow or settlement records")
	var accepted_fingerprint := RaidProgressionValues.digest(session._payload)
	var old_generation := session.generation()
	await key(KEY_ESCAPE)
	check(app.current_route == "pause", "pause before local close")
	await click(app.screen.get_node("ActionsPanel/SaveQuitRow/Hit"))
	check(app.modal != null, "closing bunker requires confirmation")
	if app.modal != null:
		await click(app.modal.get_node("DialogPanel/Margin/Content/Actions/ConfirmButton"))
	check(app.current_route == "main_menu" and not session.is_open(), "confirmed close returns to local menu")
	await click(app.screen.get_node("ContinueAction"))
	check(app.current_route == "bunker" and session.is_open(), "normal Continue reopens in the same application")
	check(session.generation() > old_generation and RaidProgressionValues.digest(session._payload) == accepted_fingerprint, "reopened lease preserves accepted bytes")
	await click(app.screen.get_node("BunkerHideoutView/OpenLocalInventory"))
	check(app.current_route == "inventory" and app.screen._inventory_controller.is_bound(), "bunker mouse action opens a fresh inventory binding")
	await key(KEY_I)
	check(app.current_route == "bunker", "fresh inventory returns to bunker")
	print("OFFLINE_PROFILE_FINGERPRINT ", RaidProgressionValues.digest(session._payload))
	product.queue_free()
	await settle()
	product = null
	# Fault injection has its own trusted namespace, never the normal profile.
	await failure_contract()
	finish()

func failure_contract() -> void:
	var ops = load("res://tests/raid/profile_store_contract.gd").FakeFileOperations.new("offline-fault-" + mode)
	var store := ProfileStore.new()
	check(store.configure_with_trusted_operations("zerkov.profile.offline.fault", ops), "fault store configured")
	var session := OfflineBunkerSession.new()
	root.add_child(session)
	check(session.start_for_test(store) and session.open_profile(true), "native test inventory with fake IO")
	var controller := OfflineInventoryController.new()
	controller.attach(session)
	var ammo := controller.items_for(&"stash")[2]
	for value: Dictionary in controller.items_for(&"stash"):
		if value.definition_id == String(ZerkovInventoryCatalog.ITEM_AMMO_762):
			ammo = value
	var previous := session._native.make_persistence_record(1)
	var primary: PackedByteArray = ops.slots[ProfileFileOperations.SLOT_PRIMARY].duplicate()
	ops.fail_before("write:write_temp")
	check(not controller.submit_quick(&"stash", ammo).accepted, "failed save does not accept edit")
	check(session._native.make_persistence_record(1) == previous, "failed save preserves native truth")
	check(ops.slots[ProfileFileOperations.SLOT_PRIMARY] == primary, "failed save preserves disk truth")
	check(controller.submit_quick(&"stash", ammo).accepted, "retry saves exactly once")
	check(not controller.submit_quick(&"stash", ammo).accepted, "duplicate stale gesture cannot move twice")
	check(not session.open_profile(true), "New cannot overwrite existing profile")
	check(session.close_profile() and session.open_profile(false), "close and reopen restores the native record")
	check(not controller.submit_quick(&"stash", ammo).accepted, "retired controller generation rejects")
	var future_payload := session._payload.duplicate(true)
	var previous_generation := int(session.status().save_generation)
	check(session.close_profile(), "close before incompatible-file probe")
	future_payload.project.offline_bunker.schema = "zerkov.offline.future.v2"
	check(store.save_profile(future_payload, previous_generation, previous_generation + 1).committed, "fixture creates outer-valid future schema")
	var future_bytes: Dictionary = ops.slots.duplicate(true)
	check(not session.open_profile(false) and not session.open_profile(true), "future schema cannot Continue or reseed")
	check(ops.slots == future_bytes, "future schema bytes are preserved")
	ops.slots[ProfileFileOperations.SLOT_PRIMARY] = PackedByteArray([1, 2, 3])
	ops.slots[ProfileFileOperations.SLOT_BACKUP] = PackedByteArray([4, 5, 6])
	var corrupt_bytes: Dictionary = ops.slots.duplicate(true)
	check(not session.open_profile(false) and not session.open_profile(true), "corrupt files never become a new profile")
	check(ops.slots == corrupt_bytes, "corrupt files are preserved for recovery")
	session.queue_free()
	await settle()

func finish() -> void:
	print("OFFLINE_BUNKER_RESULT checks=%d failures=%d mode=%s" % [checks, failures, mode])
	quit(0 if failures == 0 else 1)
