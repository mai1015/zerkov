extends RefCounted
## White-box automation, real player input. Reads authored paths and visible
## actor state to steer; never teleports, inserts items, or selects an outcome.
## This is not a blind-human or visual-readability acceptance test.
var _game: LocalGame
var _tree: SceneTree
var _check: Callable
var _held: Dictionary = {}
var _last_shot: int = -100
var _last_reload: int = -100
var ticks: int = 0
var fired: int = 0
var searched: int = 0
var transferred: bool = false
var _started_ms: int = 0

func extract(game: LocalGame, tree: SceneTree, check_callback: Callable) -> bool:
	_game = game; _tree = tree; _check = check_callback
	_started_ms = Time.get_ticks_msec()
	print("LOCAL_FLOW_DRIVER start tick=", _game._session.raid.last_processed_tick)
	_profile_read_only_costs()
	# Reload through the actual logical R action before leaving the entry.
	_key(KEY_R, true); _key(KEY_R, false)
	for _i in range(ZerkovCombatContent.AKM_RELOAD_TICKS + 2):
		if not await _tick(Vector2.ZERO): return false
	if not _assert(_game._session.hud_model.snapshot().ammo > 0, "physical reload loads real ammunition"): return false
	for id: String in SupplyRunGraph.CRATES:
		if not await _walk_to(_game._session.layout.cell_center(_game._session.layout.anchor(id).cell)): return false
		_stop()
		for _i in range(10):
			if not await _tick(Vector2.ZERO): return false
		if not _assert(_game._session.nearest_target() == id, "input traversal reaches " + id): return false
		_key(KEY_E, true); _key(KEY_E, false)
		await _tree.process_frame
		var completed: bool = false
		for _i in range(120):
			if not await _tick(Vector2.ZERO): return false
			if _game._session.progression.was_crate_searched(id): completed = true; break
		if not _assert(completed, "timed native search completes " + id): return false
		searched += 1
		print("LOCAL_FLOW_SEARCH tick=", ticks, " crate=", id)
		if id == SupplyRunGraph.CRATES[0]:
			if not await _take_objective(): return false
	var clock_before: int = _game._session.raid.last_processed_tick
	_key(KEY_M, true); _key(KEY_M, false)
	if not await _wait_route("maps"): return false
	if not _assert(_game._provider.map_view(_game._epoch).is_ready(), "real map provider ready after searches"): return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	if not await _wait_route("hud"): return false
	if not _assert(_game._session.raid.last_processed_tick == clock_before, "map navigation does not advance paused solo clock"): return false
	var exit_point := _game._session.layout.cell_center(_game._session.layout.anchor(SupplyRunGraph.ROAD_GATE).cell)
	if not await _walk_to(exit_point): return false
	_stop()
	for _i in range(10):
		if not await _tick(Vector2.ZERO): return false
	_key(KEY_E, true); _key(KEY_E, false)
	await _tree.process_frame
	if not await _tick(Vector2.ZERO): return false
	if not _assert(_game._session.progression.snapshot().clock.counting, "physical interact starts eligible extraction"): return false
	for _i in range(LocalCampaignContent.EXTRACTION_TICKS + 4):
		if _game._mode != "raid": break
		if not await _tick(Vector2.ZERO): return false
	if not await _wait_route("summary_solo"): return false
	var result: Dictionary = _game._summary
	if not _assert(_game._mode == "summary" and result.get("outcome") == "extracted", "input-driven extraction produces a committed summary"): return false
	if not _assert(result.get("task", {}).get("completion_token") == true, "three searches and actual retained supply complete native task"): return false
	var retained: bool = false
	for row: Dictionary in result.get("retained", []):
		if StringName(row.definition) == ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE and row.quantity == 1: retained = true
	if not _assert(retained and transferred and searched == 3, "one UI-transferred supply is retained in committed receipt"): return false
	print("LOCAL_FLOW_EXTRACT ticks=", ticks, " fire_inputs=", fired, " searched=", searched,
		" kills=", result.get("stats", {}).get("kills", 0), " outcome=", result.outcome)
	return true

func _walk_to(goal: Vector2) -> bool:
	print("LOCAL_FLOW_WALK goal=", goal, " ticks=", ticks)
	var session := _game._session
	var start: Vector2i = ZWorldUnits.godot_to_tile(session.player_movement.position_px).vector2i_value
	var target: Vector2i = ZWorldUnits.godot_to_tile(goal).vector2i_value
	var path := session._navigation.request_path(start, target, session._navigation.revision())
	if not _assert(path.is_ok(), "authored navigation provides walking route to " + str(target)): return false
	for cell: Vector2i in path.cells:
		var waypoint := ZWorldUnits.tile_center_to_godot(cell).vector2_value
		var reached: bool = false
		for _i in range(160):
			var delta := waypoint - session.player_movement.position_px
			if delta.length() <= 4.0: reached = true; break
			var direction := Vector2(signf(delta.x) if absf(delta.x) > 3.0 else 0.0,
				signf(delta.y) if absf(delta.y) > 3.0 else 0.0)
			if not await _tick(direction): return false
		if not _assert(reached, "physical movement reaches waypoint " + str(cell)): return false
	return true

func _tick(direction: Vector2) -> bool:
	if not _assert(_game._mode == "raid" and _game.can_advance(), "live input tick available: " + _game._mode): return false
	for code: Key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		var down: bool = (code == KEY_W and direction.y < 0) or (code == KEY_S and direction.y > 0) \
			or (code == KEY_A and direction.x < 0) or (code == KEY_D and direction.x > 0)
		if bool(_held.get(code, false)) != down: _key(code, down); _held[code] = down
	_fight_visible()
	if ticks % 32 == 0:
		print("LOCAL_FLOW_TICK begin=", ticks, " pos=", _game._session.player_movement.position_px, " ms=", Time.get_ticks_msec() - _started_ms)
	var ok := _game.advance()
	ticks += 1
	if ticks % 32 == 1: print("LOCAL_FLOW_TICK completed=", ticks)
	if not _assert(ok, "production tick: " + String(_game.last_error)): return false
	if ticks % 8 == 0: await _tree.process_frame
	return true

func _fight_visible() -> void:
	var session := _game._session
	var origin: Vector2 = session.player_movement.position_px
	var candidates: Array[Dictionary] = []
	for key: String in session.rows:
		var row: Dictionary = session.rows[key]
		if row.archetype == "player" or not session.combat.health.actor_snapshot(row.actor_id).alive: continue
		var position: Vector2 = row.movement.position_px
		var screen := ZWorldViewportPolicy.world_to_screen(position, session.camera.global_position)
		if Rect2(8, 8, 1904, 1064).has_point(screen) and _clear_segment(origin, position):
			candidates.append({"key":key,"position":position,"screen":screen,"distance":origin.distance_squared_to(position)})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.distance < b.distance if a.distance != b.distance else a.key < b.key)
	if candidates.is_empty(): return
	var motion := InputEventMouseMotion.new()
	motion.position = candidates[0].screen
	motion.global_position = motion.position
	_tree.root.push_input(motion)
	var state := session.hud_model.snapshot()
	var tick: int = session.raid.last_processed_tick
	if state.reloading: return
	if state.ammo == 0:
		if state.reserve > 0 and tick - _last_reload > ZerkovCombatContent.AKM_RELOAD_TICKS + 2:
			_key(KEY_R, true); _key(KEY_R, false); _last_reload = tick
		return
	if tick - _last_shot < ZerkovCombatContent.AKM_CADENCE_TICKS + 1: return
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = motion.position; event.global_position = motion.position
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		_tree.root.push_input(event)
	_last_shot = tick; fired += 1

func _clear_segment(start: Vector2, end: Vector2) -> bool:
	for collider: Dictionary in _game._session.layout.structures:
		if collider.layer != "Obstacles": continue
		var cells: Rect2i = collider.rect
		var box := Rect2(Vector2(cells.position) * float(ZWorldUnits.SOURCE_TILE_PIXELS), Vector2(cells.size) * float(ZWorldUnits.SOURCE_TILE_PIXELS))
		if box.has_point(start) or box.has_point(end): return false
		var a := box.position; var b := Vector2(box.end.x, box.position.y)
		var c := box.end; var d := Vector2(box.position.x, box.end.y)
		for edge: Array in [[a,b],[b,c],[c,d],[d,a]]:
			if Geometry2D.segment_intersects_segment(start, end, edge[0], edge[1]) != null: return false
	return true

func _take_objective() -> bool:
	_stop()
	_key(KEY_E, true); _key(KEY_E, false)
	if not await _wait_route("inventory"): return false
	var screen: Control = _game._ui.screen
	var items: Array = screen.call("_items_for", "loot")
	var item_id: int = 0
	for item: Dictionary in items:
		if StringName(item.get("definition_id", "")) == ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE:
			item_id = int(item.item_id)
	var grid: Control = screen.call("_grid_for_source", "loot")
	var target: Control
	if grid != null:
		for slot: Control in grid.get("_slots"):
			if int(slot.get("item").get("item_id", 0)) == item_id and item_id > 0: target = slot; break
	if not _assert(target != null and target.is_visible_in_tree(), "searched objective has a visible real inventory slot"): return false
	var point := target.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new(); motion.position = point; motion.global_position = point
	_tree.root.push_input(motion)
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point; event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down; event.ctrl_pressed = true
		_tree.root.push_input(event)
	for _i in range(8): await _tree.process_frame
	var owner := _game._session.deployment.inventory
	for item: Dictionary in owner.raid_authority().snapshot(owner.raid_player_inventory_id).get_items():
		if StringName(item.get("item_definition_identifier", "")) == ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE: transferred = true
	if not _assert(transferred, "physical Ctrl-click transfers objective through existing inventory UI"): return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	return await _wait_route("hud")

func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code; event.physical_keycode = code; event.pressed = down
	_tree.root.push_input(event)

func _stop() -> void:
	for code: Key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		if _held.get(code, false): _key(code, false)
	_held.clear()

func _wait_route(expected: String) -> bool:
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		if not _game.last_error.is_empty(): break
		if _game._ui.current_route == expected and _game._ui.screen.is_routing_active(): return true
		await _tree.create_timer(0.02).timeout
	return _assert(false, "await real route " + expected + ": " + _game._ui.current_route + " / " + String(_game.last_error))

func _assert(ok: bool, message: String) -> bool:
	return bool(_check.call(ok, message))

func _profile_read_only_costs() -> void:
	var start: int = Time.get_ticks_usec()
	_game._publish()
	print("LOCAL_FLOW_PROFILE publish_usec=", Time.get_ticks_usec() - start)
	var raid := _game._session.raid
	var keys := raid._handler_ids.keys(); keys.sort()
	for key in keys:
		var entry: Dictionary = raid._handler_ids[key]
		start = Time.get_ticks_usec()
		var safe := raid.phase_handler_callback_is_safe(entry.callback)
		print("LOCAL_FLOW_PROFILE handler=", key, " safety_usec=", Time.get_ticks_usec() - start, " safe=", safe)
