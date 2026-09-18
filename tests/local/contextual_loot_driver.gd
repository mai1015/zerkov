extends RefCounted
const PlayerDriver = preload("res://tests/local/local_flow_player_driver.gd")
var player := PlayerDriver.new()
var _game: LocalGame
## Native input only. Navigation/visible actors guide the existing play driver;
## no teleports, seeded loot, forced search completion or fake inventories.
var h
var _near_id := ""
var _own_positions: Array[Vector2] = []

func run(harness, initial: Dictionary) -> bool:
	h = harness
	_game = h._game
	player._game = _game; player._tree = h; player._check = Callable(h, "check")
	player._started_ms = Time.get_ticks_msec()
	_game._ui_port.request(&"inspect_nearby", _game._epoch)
	await h.settle()
	if not _assert(_game._mode == "home" and _game._session == null, "nearby intent cannot deploy or interact at home"): return false
	await _press_key(KEY_I)
	if not h.route("inventory"): return false
	if not _assert(not _node("LootTab").visible and _node("StashTab").visible, "home keeps stash without a fictional Loot tab"): return false
	_assert(_node("StashGrid").get("source_id") == "stash", "home counterpart remains actual stash")
	await _press_key(KEY_ESCAPE)
	if not h.route("bunker"): return false
	if h._run_mode == "continue":
		_assert(h._store.load_profile().fingerprint == initial.fingerprint, "independent Continue preserves committed real raid result")
		return h.failures == 0
	await _press_key(KEY_M)
	if not h.route("maps") or not await h.click("Deploy") or not h.route("hud"): return false
	player._capture_shot_geometry()
	var spawn: Vector2 = _game._session.player_movement.position_px
	await _press_key(KEY_I)
	if not h.route("inventory") or not _closed(false): return false
	_own_positions = [_node("CharacterColumn").position, _node("PackGrid").get_global_rect().position]
	_game._ui_port.request(&"inspect_nearby", _game._epoch)
	await h.settle()
	if not _closed(false): return false
	_game._ui.screen.queue_adaptive_layout()
	await h.settle()
	if not _closed(false): return false
	await h.capture("02-gear-only.png")
	await _press_key(KEY_ESCAPE)
	if not h.route("hud"): return false
	player._key(KEY_R, true); player._key(KEY_R, false)
	for _i in range(ZerkovCombatContent.AKM_RELOAD_TICKS + 2):
		if not await player._tick(Vector2.ZERO): return false
	_near_id = _game._session.crate_keys()[0]
	if not await player._walk_to(_game._session.target_approach(_near_id)): return false
	player._stop()
	for _i in range(10):
		if not await player._tick(Vector2.ZERO): return false
	await _press_key(KEY_I)
	if not h.route("inventory") or not _closed(true): return false
	var near: Dictionary = _game._ui_port.snapshot().nearby_loot
	_assert(near.is_read_only() and near.target_id == _near_id and not near.searched, "nearby is frozen, current, unsearched public metadata")
	var allowed := ["target_id", "inventory_id", "label", "searched", "searching"]
	_assert(near.size() == allowed.size(), "nearby metadata has no item counts, contents, value or native handles")
	for field: String in near: _assert(allowed.has(field), "bounded nearby field " + field)
	_assert(_node("NearbyLootCard/Title").text == String(near.label).to_upper(), "public map name labels the nearby card")
	_assert(_node("NearbyLootCard/Action").text == "SEARCH CONTAINER", "unsearched target offers Search rather than contents")
	# A target captured in a different frame must not open whichever is nearest now.
	_game._consume(&"inspect_nearby", _game._epoch, "zerkov.crate.not-the-selected-target")
	await h.settle()
	if not _closed(true): return false
	_game._ui.screen.app.confirm("Pause test", "Covered actions stay inactive.", func(): pass)
	await h.settle()
	_game._ui_port.request(&"inspect_nearby", _game._epoch)
	await h.settle()
	_assert(not _game._character.inventory_controller().is_loot_container_open() and _game._ui.current_route == "inventory", "modal prevents nearby intent admission")
	await _press_key(KEY_ESCAPE)
	if not h.route("inventory"): return false
	await h.capture("03-nearby-unsearched.png")
	if not await h.click("InventoryContent/NearbyLootCard/Action") or not h.route("hud"): return false
	if not await player._tick(Vector2.ZERO): return false
	await _press_key(KEY_I)
	if not h.route("inventory") or not _closed(true): return false
	_assert(_game._ui_port.snapshot().nearby_loot.searching, "Search queues the canonical search, not immediate contents")
	_assert(_node("NearbyLootCard/Action").text == "RESUME SEARCH", "opening Character during search offers resume, not duplicate work")
	await h.capture("04-searching.png")
	if not await h.click("InventoryContent/NearbyLootCard/Action") or not h.route("hud"): return false
	var completed := false
	var attempts := 1
	for _i in range(360):
		if not await player._tick(Vector2.ZERO): return false
		if _game._session.progression.was_crate_searched(_near_id): completed = true; break
		if _game._session.progression.snapshot().get("searching", "").is_empty():
			if not _assert(attempts < 3 and _game._session.nearest_target() == _near_id, "bounded real-damage interruption retry"): return false
			if not await player._stabilize_bleeding(): return false
			attempts += 1
			player._key(KEY_E, true); player._key(KEY_E, false)
			await h.process_frame
	if not _assert(completed, "native timed search completes without forcing progression"): return false
	await _press_key(KEY_I)
	if not h.route("inventory") or not _closed(true): return false
	_assert(_node("NearbyLootCard/Action").text == "OPEN CONTAINER", "searched target offers explicit Open")
	if not await h.click("InventoryContent/NearbyLootCard/Action") or not h.route("inventory"): return false
	if not _open(): return false
	await h.capture("05-open-container.png")
	# Subpages preserve the current world context, not an unbounded default crate.
	if not await h.click("InventoryContent/HealthTab") or not h.route("health"): return false
	_assert(_game._character.inventory_controller().is_loot_container_open(), "health detour preserves the active container")
	if not await h.click("InventoryContent/GearTab") or not h.route("inventory") or not _open(): return false
	if not await h.click("InventoryContent/StashSearch"): return false
	await _type_filter("zzzznomatch")
	_assert(_node("OpenLootEmpty").visible and _node("OpenLootEmpty").text == "NO MATCHING ITEMS", "nonempty filtered container is not called empty")
	_assert(_node("ClearLootFilters").visible, "filter empty state offers recovery")
	for name: String in ["FilterAll", "FilterGuns", "FilterAmmo", "FilterArmor", "FilterCloth", "FilterFood", "FilterUtil"]:
		_assert(not _node("OpenLootEmpty").get_global_rect().intersects(_node(name).get_global_rect()) and not _node("ClearLootFilters").get_global_rect().intersects(_node(name).get_global_rect()), "empty/filter recovery never covers existing filter controls")
	await h.capture("06-filter-no-match.png")
	if not await h.click("InventoryContent/ClearLootFilters"): return false
	_assert(_node("StashSearch").text.is_empty() and not _node("OpenLootEmpty").visible, "clear filters restores existing real rows")
	var before := _loot_items().size()
	if not _assert(before > 0, "opened real crate starts with loot"): return false
	for _i in range(20):
		var items := _loot_items()
		if items.is_empty(): break
		var grid: Control = _game._ui.screen.call("_grid_for_source", "loot")
		var slot: Control
		for entry: Control in grid.get("_slots"):
			if entry.is_visible_in_tree(): slot = entry; break
		if not _assert(slot != null, "real visible source slot can be quick transferred"): return false
		var id: int = slot.get("item").item_id
		player._mouse(slot.get_global_rect().get_center(), true)
		await h.settle()
		var still_present := false
		for item: Dictionary in _loot_items(): still_present = still_present or int(item.item_id) == id
		if not _assert(not still_present, "Ctrl-click commits a real transfer through native owner"): return false
	if not _assert(_loot_items().is_empty(), "all opened contents transferred without a fabricated empty view"): return false
	_assert(_node("DesktopStashScroll").visible and _node("OpenLootEmpty").text == "CONTAINER EMPTY" and _node("OpenLootEmpty").visible, "genuinely empty open container keeps its valid destination grid")
	_assert(not _node("ClearLootFilters").visible, "genuine empty does not suggest a useless filter reset")
	await h.capture("07-empty-container.png")
	var owner := _game._session.deployment.inventory
	var player_revision: int = owner.raid_authority().snapshot(owner.raid_player_inventory_id).get_revision()
	if not await h.click("InventoryContent/LootClose") or not _closed(true): return false
	_assert(owner.raid_authority().snapshot(owner.raid_player_inventory_id).get_revision() == player_revision, "Close does not mutate or remove retained player inventory")
	_assert(_game._ui.get_viewport().gui_get_focus_owner().is_visible_in_tree(), "Close leaves focus on a visible control")
	await h.capture("08-closed-container.png")
	if not await h.click("InventoryContent/NearbyLootCard/Action") or not _open(): return false
	if not await h.click("NavigationChrome/Tasks") or not h.route("tasks"): return false
	_assert(not _game._character.inventory_controller().is_loot_container_open(), "leaving Character retires the presentation context")
	await _press_key(KEY_ESCAPE)
	if not h.route("hud"): return false
	if not await player._walk_to(spawn): return false
	player._stop()
	for _i in range(4):
		if not await player._tick(Vector2.ZERO): return false
	await _press_key(KEY_I)
	if not h.route("inventory") or not _closed(false): return false
	_game._consume(&"inspect_nearby", _game._epoch, _near_id)
	await h.settle()
	if not _closed(false): return false
	_assert(h._store.load_profile().payload.project[RaidProgressionValues.STATE_KEY].active.size() > 0, "live loot is not falsely settled by opening or closing UI")
	if not await player._wait_route("inventory"): return false
	# Test global Back, not native tooltip dismissal. The world driver's aim
	# pointer can rest on a diagnostic tooltip while assertions await frames;
	# Godot correctly lets a displayed tooltip consume the first Escape.
	# Move the actual pointer to neutral content before asserting navigation.
	var neutral := InputEventMouseMotion.new()
	neutral.position = Vector2(940, 78)
	neutral.global_position = neutral.position
	Input.parse_input_event(neutral)
	Input.flush_buffered_events()
	await h.settle()
	await _press_key(KEY_ESCAPE)
	if not await player._wait_route("hud") or not h.route("hud"): return false
	await _press_key(KEY_ESCAPE)
	if not h.route("pause") or not await h.click("ActionsPanel/SaveQuitRow/Hit"): return false
	var modal: Control = _game._ui.modal
	if not _assert(is_instance_valid(modal), "real abandonment needs confirmation"): return false
	var confirm: Button
	for node: Node in modal.find_children("*", "Button", true, false):
		if not node.text.to_upper().contains("CANCEL"): confirm = node
	if not _assert(confirm != null, "visible abandonment confirm"): return false
	player._mouse(confirm.get_global_rect().get_center())
	await h.settle()
	if not h.route("summary_solo"): return false
	_assert(_game._summary.outcome == "abandoned", "normal committed result closes the actual tested raid")
	var settled: String = h._store.load_profile().fingerprint
	var old_epoch: int = _game._epoch
	if not await h.click("BackBunker") or not h.route("bunker"): return false
	_assert(not _game._ui_port.request(&"inspect_nearby", old_epoch), "retired epoch cannot reacquire world loot")
	_assert(h._store.load_profile().fingerprint == settled, "return home does not repeat settlement")
	return h.failures == 0

func _node(path: String) -> Control:
	if path.begins_with("NearbyLootCard"):
		return _game._ui.screen.get_node("InventoryContent/" + path) as Control
	return _game._ui.screen.call("_node", path) as Control

func _loot_items() -> Array:
	return _game._ui.screen.call("_items_for", "loot")

func _closed(nearby: bool) -> bool:
	var screen: Control = _game._ui.screen
	_assert(not _game._character.inventory_controller().is_loot_container_open(), "context really closed")
	for name: String in screen.LOOT_SURFACE:
		_assert(not _node(name).is_visible_in_tree(), "closed control absent: " + name)
	_assert(not _node("LootTab").visible and _node("LootTab").disabled, "loot is not a permanent tab")
	_assert(not _node("StashTab").visible, "home stash stays out of raid")
	_assert(_loot_items().is_empty(), "retained native projection does not disclose closed contents")
	_assert(_node("NearbyLootCard").visible == nearby, "Nearby appears only for a current in-reach target")
	_assert(not _node("OpenLootEmpty").visible and screen.get_node_or_null("InventoryContent/LocalLootEmpty") == null, "no no-container error or empty workspace")
	return h.failures == 0

func _open() -> bool:
	_assert(_game._character.inventory_controller().is_loot_container_open(), "actual container admitted open")
	_assert(_node("DesktopStashScroll").visible and _node("StashSearch").visible and _node("LootClose").visible, "opened grid tools are present")
	_assert(not _node("NearbyLootCard").visible and not _node("LootTab").visible, "open source replaces nearby prompt, not another tab")
	_assert(_node("StashTitle").text == String(_game._ui_port.snapshot().nearby_loot.label).to_upper(), "named source matches current open inventory")
	_assert(_node("CharacterColumn").position == _own_positions[0] and _node("PackGrid").get_global_rect().position == _own_positions[1], "own equipment and backpack never jump when loot opens")
	return h.failures == 0

func _type_filter(text: String) -> void:
	for letter in text:
		for down: bool in [true, false]:
			var event := InputEventKey.new()
			event.keycode = letter.to_upper().unicode_at(0)
			event.physical_keycode = event.keycode
			event.unicode = letter.unicode_at(0)
			event.pressed = down
			h.root.push_input(event)
	await h.settle()

func _assert(value: bool, message: String) -> bool:
	return h.check(value, message)

func _press_key(code: Key) -> void:
	# Use the same Input singleton path as the world traversal driver, keeping
	# physical key state coherent with CommonUI's release reconciliation.
	player._key(code, true)
	player._key(code, false)
	await h.settle()
