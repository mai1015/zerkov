extends RefCounted
## Native application smoke for the normal physics callback, not only manual
## authority stepping. Elapsed timings never affect canonical state or pass/fail.
var _game: LocalGame
var _tree: SceneTree
var _check: Callable

func run(game: LocalGame, tree: SceneTree, check_callback: Callable) -> bool:
	_game = game; _tree = tree; _check = check_callback
	var raid := _game._session.raid
	var actor := _game._session.player_movement
	var start_position: Vector2 = actor.position_px
	var instance: int = raid.get_instance_id()
	if not _assert(ProjectSettings.get_setting("application/run/main_scene") == "res://game/bootstrap/local/local_game.tscn", "normal entrypoint is the composed application"): return false
	if not _assert(Engine.physics_ticks_per_second == 60, "engine scheduling uses canonical 60 Hz"): return false
	# Exercise the same callback that runs after F6/F5/exported normal launch.
	# Tests still isolate storage. They do not change physics frequency or delta.
	var tick: int = raid.last_processed_tick
	_key(KEY_D, true)
	_game.set_physics_process(true)
	if not await _wait_ticks(tick + 12): _stop(); return false
	_key(KEY_D, false)
	if not _assert(actor.position_px.x > start_position.x, "physical D input moves through production physics callback"): _stop(); return false
	if not _views_agree(): _stop(); return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	if not await _wait_route("pause"): _stop(); return false
	var paused_tick: int = raid.last_processed_tick
	for _index in range(8): await _tree.process_frame
	if not _assert(_game.is_physics_processing() and raid.last_processed_tick == paused_tick, "pause gates the running callback without advancing authority"): _stop(); return false
	_key(KEY_ESCAPE, true); _key(KEY_ESCAPE, false)
	if not await _wait_route("hud"): _stop(); return false
	if not await _wait_ticks(paused_tick + 12): _stop(); return false
	_stop()
	if not _assert(raid.get_instance_id() == instance, "resume retains the same raid authority"): return false
	if not _views_agree(): return false
	# Measure only synchronous application advancement; no imports, sleeps, input
	# driver pathfinding or deliberate frame waits are included in these samples.
	var samples: Array[int] = []
	for _index in range(64):
		var before := Time.get_ticks_usec()
		var advanced := _game.advance()
		var elapsed := Time.get_ticks_usec() - before
		if not _assert(advanced, "measured application tick completed"): return false
		samples.append(elapsed)
		if not _views_agree(): return false
	samples.sort()
	print("LOCAL_CLOCK_TIMING samples=64 median_us=", samples[32],
		" p95_us=", samples[60], " max_us=", samples[63], " target_us=16667",
		" budget_met=", samples[60] <= 16667)
	print("LOCAL_CLOCK_DRIVER_COMPLETE physics_callback=true pause_resume=true view_ticks_current=true")
	return true

func _views_agree() -> bool:
	var tick: int = _game._session.raid.last_processed_tick
	var snapshot := _game._session.progression.snapshot()
	var view := _game._provider.raid_view(_game._epoch)
	var task := _game._provider.task_view(_game._epoch)
	var expected := LocalGameViews.task_identity(_game._session.raid.raid_id().canonical_key())
	return _assert(view.is_ready() and view.source_tick() == tick and snapshot.tick == tick, "published raid clock follows completed authority tick") \
		and _assert(_game._ui.screen.get_node("TimerGroup/Timer").text == snapshot.clock.clock_text, "HUD uses canonical clock text") \
		and _assert(task.tasks()[0].task_id().is_equal(expected) and task.selected_task_id().is_equal(expected), "active task selection uses this raid identity, not preview")

func _wait_ticks(target: int) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if not _game.last_error.is_empty(): break
		if _game._session.raid.last_processed_tick >= target: return true
		await _tree.process_frame
	return _assert(false, "normal physics loop advances: " + String(_game.last_error))

func _wait_route(route: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if not _game.last_error.is_empty(): break
		if _game._ui.current_route == route and _game._ui.screen.is_routing_active(): return true
		await _tree.process_frame
	return _assert(false, "input reaches route " + route)

func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code; event.physical_keycode = code; event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _stop() -> void:
	_game.set_physics_process(false)
	_key(KEY_D, false)

func _assert(ok: bool, label: String) -> bool:
	return bool(_check.call(ok, "local clock: " + label))
