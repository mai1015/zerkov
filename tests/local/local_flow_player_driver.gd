extends RefCounted
## White-box automation through actual Input events. Authored navigation and
## visible actor positions guide input; no teleports, item seeding or forced outcome.
var _game: LocalGame
var _tree: SceneTree
var _check: Callable
var _held: Dictionary = {}
var _last_shot: int = -100
var _last_reload: int = -100
var _started_ms: int = 0
var ticks: int = 0
var fired: int = 0
var searched: int = 0
var transferred: bool = false
var _death_run: bool = false

func extract(game: LocalGame, tree: SceneTree, check_callback: Callable, expect_save_retry: bool = false) -> bool:
	_game = game; _tree = tree; _check = check_callback
	_started_ms = Time.get_ticks_msec()
	var capture_contract = load("res://tests/local/runtime_capture_contract.gd").new()
	if not capture_contract.run(_game._session.raid, _check): return false
	_profile_read_only_costs()
	_key(KEY_R, true); _key(KEY_R, false)
	for _i in range(ZerkovCombatContent.AKM_RELOAD_TICKS + 2):
		if not await _tick(Vector2.ZERO): return false
	if not _assert(_game._session.hud_model.snapshot().ammo > 0, "physical reload loads real ammunition"): return false
	for id: String in SupplyRunGraph.CRATES:
		if not await _walk_to(_game._session.layout.cell_center(_game._session.layout.anchor(id).approach_cell)): return false
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
		if id == SupplyRunGraph.CRATES[0] and not await _take_objective(): return false
	var clock_before: int = _game._session.raid.last_processed_tick
	_key(KEY_J, true); _key(KEY_J, false)
	if not await _wait_route("tasks"): return false
	var task_screen: Control = _game._ui.screen
	for index in range(3):
		if not _assert(task_screen.get_node("TaskObjectiveValue%d" % index).text == "1 / 1", "Tasks renders committed crate progress"): return false
	if not _assert(task_screen.get_node("TaskTurnIn").disabled, "no unsupported persistent turn-in"): return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	if not await _wait_route("hud"): return false
	_key(KEY_M, true); _key(KEY_M, false)
	if not await _wait_route("maps"): return false
	if not _assert(_game._provider.map_view(_game._epoch).is_ready(), "real map provider ready after searches"): return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	if not await _wait_route("hud"): return false
	if not _assert(_game._session.raid.last_processed_tick == clock_before, "map pauses solo clock"): return false
	var exit_point := _game._session.layout.cell_center(_game._session.layout.anchor(SupplyRunGraph.ROAD_GATE).approach_cell)
	if not await _walk_to(exit_point): return false
	_stop()
	for _i in range(10):
		if not await _tick(Vector2.ZERO): return false
	_key(KEY_E, true); _key(KEY_E, false)
	await _tree.process_frame
	if not await _tick(Vector2.ZERO): return false
	if not _assert(_game._session.progression.snapshot().clock.counting, "physical interact starts extraction"): return false
	for _i in range(LocalCampaignContent.EXTRACTION_TICKS + 4):
		if _game._mode != "raid": break
		if not await _tick(Vector2.ZERO): return false
	if not await _wait_route("summary_solo", expect_save_retry): return false
	if expect_save_retry:
		if not await _retry_pending_save(): return false
	var result: Dictionary = _game._summary
	if not _assert(_game._mode == "summary" and result.get("outcome") == "extracted", "committed extracted summary: " + _game._notice): return false
	if not _assert(result.get("task", {}).get("completion_token") == true, "native Supply Run completed"): return false
	var retained: bool = false
	for row: Dictionary in result.get("retained", []):
		if StringName(row.definition) == ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE and row.quantity == 1: retained = true
	if not _assert(retained and transferred and searched == 3, "one UI-transferred supply retained"): return false
	if not _assert(_game._ui.screen.get_node("MetricKills/Value").text == str(result.stats.kills), "summary renders actual kill count"): return false
	if not _assert(_game._campaign.store.load_profile().generation == result.profile_generation, "debrief receipt matches the committed file generation"): return false
	var lost_count: int = 0
	for row: Dictionary in result.get("lost", []): lost_count += int(row.quantity)
	if not _assert(_game._ui.screen.get_node("MetricXP/Title").text == "ITEMS LOST" and _game._ui.screen.get_node("MetricXP/Value").text == str(lost_count), "debrief renders actual losses instead of a profile debug counter"): return false
	print("LOCAL_FLOW_EXTRACT ticks=", ticks, " fire_inputs=", fired, " searched=", searched,
		" kills=", result.get("stats", {}).get("kills", 0), " outcome=", result.outcome)
	return true

func _walk_to(goal: Vector2) -> bool:
	var session := _game._session
	var map_builds_before := int(_game.presentation_work_counts().map_view_builds)
	var start: Vector2i = ZWorldUnits.godot_to_tile(session.player_movement.position_px).vector2i_value
	var target: Vector2i = ZWorldUnits.godot_to_tile(goal).vector2i_value
	var path := session._navigation.request_path(start, target, session._navigation.revision())
	if not _assert(path.is_ok(), "navigation route to " + str(target)): return false
	for cell: Vector2i in path.cells:
		var waypoint := ZWorldUnits.tile_center_to_godot(cell).vector2_value
		var reached: bool = false
		for _i in range(160):
			if _death_run and _game._mode != "raid": return true
			var delta := waypoint - session.player_movement.position_px
			if delta.length() <= 4.0: reached = true; break
			var direction := Vector2(signf(delta.x) if absf(delta.x) > 3.0 else 0.0,
				signf(delta.y) if absf(delta.y) > 3.0 else 0.0)
			if not await _tick(direction): return false
		if not _assert(reached, "physical movement reaches waypoint " + str(cell)): return false
	if not _assert(int(_game.presentation_work_counts().map_view_builds) == map_builds_before,
			"hidden map projection remains unchanged during player movement"):
		return false
	return true

func _tick(direction: Vector2) -> bool:
	if not _assert(_game._mode == "raid" and _game.can_advance(), "live input tick: " + _game._mode): return false
	for code: Key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		var down: bool = (code == KEY_W and direction.y < 0) or (code == KEY_S and direction.y > 0) \
			or (code == KEY_A and direction.x < 0) or (code == KEY_D and direction.x > 0)
		if bool(_held.get(code, false)) != down: _key(code, down); _held[code] = down
	_face_visible_threat()
	if ticks % 32 == 0:
		print("LOCAL_FLOW_TICK begin=", ticks, " pos=", _game._session.player_movement.position_px,
			" ms=", Time.get_ticks_msec() - _started_ms, " held=", _game._input_binding._held,
			" active=", _game._input_binding._active(), " move_error=", _game._session.player_movement.last_error)
	var ok := _game.advance()
	ticks += 1
	if not _assert(ok, "production tick: " + String(_game.last_error)): return false
	if ticks % 8 == 0: await _tree.process_frame
	return true

func _face_visible_threat() -> void:
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
	motion.position = candidates[0].screen; motion.global_position = motion.position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	# Explicit input posture makes the lethal test independent of the cursor
	# left behind by the previous menu. Face the visible attacker, never fire.
	# Repeated hits to a zero-health nonlethal limb do not currently spill over.
	if _death_run: return
	var state := session.hud_model.snapshot()
	var tick: int = session.raid.last_processed_tick
	if state.reloading: return
	if state.ammo == 0:
		if state.reserve > 0 and tick - _last_reload > ZerkovCombatContent.AKM_RELOAD_TICKS + 2:
			_key(KEY_R, true); _key(KEY_R, false); _last_reload = tick
		return
	if tick - _last_shot < ZerkovCombatContent.AKM_CADENCE_TICKS + 1: return
	_mouse(motion.position)
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
		if StringName(item.get("definition_id", "")) == ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE: item_id = int(item.item_id)
	var grid: Control = screen.call("_grid_for_source", "loot")
	var target: Control
	if grid != null:
		for slot: Control in grid.get("_slots"):
			if int(slot.get("item").get("item_id", 0)) == item_id and item_id > 0: target = slot; break
	if not _assert(target != null and target.is_visible_in_tree(), "visible real inventory objective slot"): return false
	_mouse(target.get_global_rect().get_center(), true)
	for _i in range(8): await _tree.process_frame
	var owner := _game._session.deployment.inventory
	for item: Dictionary in owner.raid_authority().snapshot(owner.raid_player_inventory_id).get_items():
		if StringName(item.get("item_definition_identifier", "")) == ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE: transferred = true
	if not _assert(transferred, "Ctrl-click transfers through existing inventory UI"): return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	return await _wait_route("hud")

func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code; event.physical_keycode = code; event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _mouse(point: Vector2, control: bool = false) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point; motion.global_position = point
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point; event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down; event.ctrl_pressed = control
		Input.parse_input_event(event)
		Input.flush_buffered_events()

func _stop() -> void:
	for code: Key in [KEY_W, KEY_A, KEY_S, KEY_D]:
		if _held.get(code, false): _key(code, false)
	_held.clear()

func _wait_route(expected: String, allow_save_error: bool = false) -> bool:
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		if not _game.last_error.is_empty() and not (allow_save_error and _game._mode == "save_error"): break
		if _game._ui.current_route == expected and _game._ui.screen.is_routing_active() \
			and _game._ui.screen.is_visible_in_tree() \
			and _game._ui.screen.app.local_epoch() == _game._epoch: return true
		await _tree.create_timer(0.02).timeout
	return _assert(false, "await route " + expected + ": " + _game._ui.current_route + " / " + String(_game.last_error))

func _assert(ok: bool, message: String) -> bool:
	return bool(_check.call(ok, message))

func _profile_read_only_costs() -> void:
	var session := _game._session
	for owner in [session.combat, session.combat.execution, session.combat.health, session.ai]:
		var callback := Callable(owner, "get_instance_id")
		var start := Time.get_ticks_usec()
		var safe := session.raid.phase_handler_callback_is_safe(callback)
		var elapsed := Time.get_ticks_usec() - start
		var reference := not session.raid._variant_graph_contains_hitbox_bearer(callback, 0, {session.raid.get_instance_id():true})
		_assert(safe == reference, "runtime/reference capture agreement")
		print("LOCAL_FLOW_PROFILE runtime_capture_usec=", elapsed, " safe=", safe)


func _retry_pending_save() -> bool:
	if not _assert(_game._mode == "save_error" and not _game.last_error.is_empty(), "failed write is explicitly pending, not successful extraction"): return false
	if not _assert(_game._summary.is_empty() and not _game._provider.summary_view(_game._epoch).is_ready(), "no committed summary before successful write"): return false
	var button: Button = _game._ui.screen.get_node("BackBunker") as Button
	if not _assert(button.text == "RETRY LOCAL SAVE" and not button.disabled, "pending-summary retry control is usable"): return false
	var pending_epoch: int = _game._epoch
	var before := _game._campaign.store.load_profile()
	var raid_id: String = _game._session.raid.raid_id().canonical_key()
	if not _assert(not before.payload.project[RaidProgressionValues.STATE_KEY].history.has(raid_id), "failed prepare cannot publish history"): return false
	_mouse(button.get_global_rect().get_center())
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and _game._mode == "save_error":
		await _tree.create_timer(0.02).timeout
	if not await _wait_route("summary_solo"): return false
	if not _assert(_game._mode == "summary" and _game._summary.raid_id == raid_id, "same raid commits once after physical retry"): return false
	if not _assert(_game._epoch > pending_epoch and _game._ui.screen.accepts_input(), "committed summary has a fresh usable UI context"): return false
	if not _assert(not _game._ui_port.request(&"retry_save", pending_epoch), "retired pending-summary commands are rejected"): return false
	print("LOCAL_FLOW_SAVE_RETRY committed=true injected_writes=1")
	return true


func die_from_enemy(game: LocalGame, tree: SceneTree, check_callback: Callable) -> bool:
	_game = game; _tree = tree; _check = check_callback
	_death_run = true
	_started_ms = Time.get_ticks_msec()
	# Walk into the existing mutant encounter, without shooting or modifying AI,
	# damage, position, inventory, health, clock limits or the outcome controller.
	var anchor: Dictionary = _game._session.layout.anchor("zerkov.encounter.sawmill.mutant_verge")
	var goal := _game._session.layout.cell_center(anchor.approach_cell + Vector2i(2, 0))
	if not await _walk_to(goal): return false
	_stop()
	for _i in range(650):
		if _game._mode != "raid": break
		if not await _tick(Vector2.ZERO): return false
	if not await _wait_route("summary_solo"): return false
	if not _assert(_game._mode == "summary" and _game._summary.get("outcome") == "dead", "production enemy causes committed death summary"): return false
	if not _assert(not _game._summary.health.alive and _game._summary.stats.damage_received_micros > 0, "death receipt records actual damage and health"): return false
	var summary: SummaryView = _game._provider.summary_view(_game._epoch)
	if not _assert(summary.is_ready() and summary.outcome() == SummaryView.Outcome.DIED, "death mapped to established SummaryView"): return false
	print("LOCAL_FLOW_DEATH ticks=", ticks, " outcome=dead damage_received=", _game._summary.stats.damage_received_micros)
	return true
