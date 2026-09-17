class_name LocalGame
extends Node
## Product composition for the local first-playable. Screens receive immutable
## values and intent-only UI context; this root alone owns persistence and raids.
signal published(frame: Dictionary)
var last_error: StringName = &""
var _campaign := LocalCampaign.new()
var _provider := ZUIPresentationProvider.new()
var _ui_port := LocalGameUI.new()
var _character := LocalCharacterRuntime.new()
var _character_binding: LocalCharacterBinding
var _home: RaidInventoryOwner
var _home_admission: ZSessionAdmission
var _session: LocalRaidSession
var _input_binding: ZCombatInputBinding
var _interaction_handle: RefCounted
var _ui: Control
var _world: SubViewport
var _world_image: TextureRect
var _test_store: ProfileStore
var _mode: String = "menu"
var _epoch: int = 1
var _serial: int = 0
var _home_sequence: int = 0
var _notice: String = ""
var _summary: Dictionary = {}
var _busy: bool = false
var _closed: bool = false
var _auto_advance: bool = true
var _last_route: String = "title"
var _preparation_return: String = "bunker"
const CHARACTER_ROUTES: Array[String] = ["inventory", "health", "stats"]
var _quit_pending: bool = false
var _map_layout: ZSawmillYardLayout
var _save_location: String = ""
var _view_cache: Array[ZReadOnlyView] = []
var _view_dependencies: Array = []
var _view_build_counts := PackedInt64Array([0, 0, 0, 0, 0])
var _static_map_markers: Array = []
var _map_markers: Array = []
var _map_marker_actor: String = ""
var _map_marker_position := Vector2(1.0e30, 1.0e30)
var _health_projection_actor: String = ""
var _health_projection_revision: int = -1
var _health_projection_digest: String = ""
var _health_projection_builds: int = 0

## Test storage overrides are only accepted before mounting. Normal launch
## always uses the fixed local profile path and the production file adapter.
func configure_test_store(store: ProfileStore, auto_advance: bool = false) -> bool:
	if is_inside_tree() or store == null or not store.is_configured(): return false
	_test_store = store
	_auto_advance = auto_advance
	return true

func _ready() -> void:
	get_tree().auto_accept_quit = false
	# Allow at most one bounded catch-up step after a transient render stall.
	# The authoritative simulation remains 60 Hz; two steps prevent permanent
	# slow motion without restoring the old multi-step catch-up spiral. This is
	# a scheduling safety valve, not a substitute for meeting the tick budget.
	Engine.max_physics_steps_per_frame = 2
	if not _campaign.open(_test_store):
		last_error = _campaign.last_error
		# A present-but-unreadable save disables Continue and New alike, so name
		# the folder that holds it. Recovering is the operator's explicit act;
		# nothing here rewrites or discards the file on their behalf.
		if _test_store == null:
			_save_location = ProjectSettings.globalize_path("%s/%s" % [GodotProfileFileOperations.ROOT_PATH,
				GodotProfileFileOperations.DEFAULT_NAMESPACE]).simplify_path()
		_notice = "Save unavailable: " + String(last_error) + ". Existing files were not replaced."
	elif not _campaign.recovered_result.is_empty():
		_summary = _campaign.recovered_result.get("receipt", {})
		_notice = "Interrupted raid recovered. Only committed results are restored."
	else:
		_notice = "Progress is saved on this computer. Steam co-op is not enabled in this build."
	add_child(_provider)
	add_child(_ui_port)
	add_child(_character)
	_provider.start_unavailable(_epoch)
	_ui_port.requested.connect(_request)
	_character.inventory_view_changed.connect(_home_inventory_changed)
	_world = SubViewport.new()
	_world.name = "AuthoritativeWorldViewport"
	_world.size = ZWorldViewportPolicy.BASE_SURFACE_SIZE
	_world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_world.handle_input_locally = false
	add_child(_world)
	_world_image = TextureRect.new()
	_world_image.name = "WorldPresentation"
	_world_image.texture = _world.get_texture()
	_world_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_world_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_image.size = Vector2(1920, 1080)
	_world_image.visible = false
	add_child(_world_image)
	_publish()
	_ui = load("res://ui/main.tscn").instantiate() as Control
	_ui.set_script(load("res://ui/core/local/local_ui_host.gd"))
	_ui.name = "Main"
	if not _ui.inject_presentation_provider(_provider) or not _ui.inject_character_runtime(_character) \
		or not _ui.inject_local_game_ui(_ui_port):
		_error(&"local_ui_injection_failed")
		return
	add_child(_ui)
	_ui.navigator.committed.connect(_route_changed)
	set_physics_process(_auto_advance)

func _physics_process(_delta: float) -> void:
	if can_advance(): advance()

func can_advance() -> bool:
	return not _closed and not _busy and _mode == "raid" and _session != null \
		and _input_binding != null and _ui != null and _ui.current_route == "hud" and not is_instance_valid(_ui.modal) and not is_instance_valid(_ui.picker)

## Product physics and native tests share this path. Screens cannot call it.
func advance() -> bool:
	if not can_advance(): return false
	var cursor := ZWorldViewportPolicy.screen_to_world(_ui.get_viewport().get_mouse_position(), _session.camera.global_position)
	if cursor.ok:
		_input_binding.set_aim_direction(cursor.world_position - _session.player_movement.position_px)
	var receipt := _input_binding.flush_movement(_session.raid.last_processed_tick + 1)
	if not receipt.is_empty() and receipt.get("admitted") != true: return _error(&"local_movement_admission_failed")
	if not _session.advance(): return _error(_session.last_error)
	if not _publish_changed_health():
		return _error(&"local_health_projection_failed")
	if _session.raid.lifecycle == RaidAuthority.Lifecycle.SETTLING:
		_mode = "settling"
		_notice = "Saving the authoritative raid result locally…"
		_release_input()
		_publish()
		_finish.call_deferred()
	else: _publish()
	return true

func _request(command: StringName, epoch: int) -> void:
	_consume.call_deferred(command, epoch)

func _consume(command: StringName, epoch: int) -> void:
	if _closed or epoch != _epoch or _busy: return
	match command:
		&"create":
			if _mode != "menu" or not _campaign.create(self):
				_error(_campaign.last_error if not _campaign.last_error.is_empty() else &"local_create_wrong_phase")
				return
			_open_home()
		&"continue":
			if _mode != "menu" or not _campaign.has_profile(): return
			if not _summary.is_empty():
				_mode = "summary"; _epoch += 1; _publish(); _navigate("summary_solo", false)
			else: _open_home()
		&"loadout", &"health", &"maps", &"tasks", &"controls", &"pause":
			if _mode in ["home", "raid"] or (command == &"controls" and _mode == "menu"):
				_navigate({&"loadout":"inventory", &"health":"health", &"maps":"maps", &"tasks":"tasks", &"controls":"controls", &"pause":"pause"}[command])
		&"crafting", &"build_mode", &"session":
			if _mode == "home" and _home != null:
				_navigate(String(command))
		&"deploy":
			# The hub opens a briefing, never a raid. Only its explicit final action
			# may deploy; retained hub controls cannot skip loadout/exit review.
			if _mode == "home" and _ui != null and _ui.current_route == "maps" and last_error.is_empty(): _deploy()
		&"close_profile":
			if _mode == "home": _close_profile()
		&"resume":
			if _mode == "raid": _navigate("hud", false)
			elif _mode == "home":
				_navigate(_preparation_return if _ui != null and _ui.current_route in CHARACTER_ROUTES else "bunker", false)
			elif _mode == "menu": _navigate("main_menu", false)
		&"interact":
			if can_advance(): _interact()
		&"cancel":
			if can_advance(): _session.cancel_interaction()
		&"return_home":
			if _mode == "summary": _open_home()
			elif _mode == "home": _navigate("bunker", false)
		&"retry_save":
			if _mode == "save_error" and _session != null: _finish()
			elif _mode == "home" and _home != null:
				if _campaign.save_home(_home): last_error = &""; _notice = "Loadout saved locally."; _publish()
				else:
					last_error = _campaign.last_error
					_notice = "Local save failed: " + String(last_error) + ". The stored loadout is unchanged; retry."
					_publish()
		&"abandon":
			if _mode == "raid": _abandon()
		&"quit":
			_quit()

func _open_home() -> void:
	_preparation_return = "bunker"
	_busy = true
	_release_input()
	_release_character()
	if _session != null:
		if not _session.release(): _busy = false; _error(_session.last_error); return
		_session.queue_free(); _session = null
	if _home != null:
		_home.teardown(_home.generation()); _home.queue_free(); _home = null
	if not _campaign.reload(): _busy = false; _error(_campaign.last_error); return
	_home = _campaign.instantiate_home(self)
	if _home == null: _busy = false; _error(&"local_home_inventory_failed"); return
	_home_sequence += 1
	var id := ZRaidId.from_parts(PackedStringArray(["local", "home", "v" + str(_home_sequence)]))
	_home_admission = SessionCoordinator.new().open_offline(id, StringName("home" + str(_home_sequence)))
	_character_binding = LocalCharacterBinding.new()
	add_child(_character_binding)
	if not _character_binding.bind(_character, _home, _home_admission, LocalHealthProjection.recovered_home(_home_admission), ZInventoryWorldPolicyPort.new()):
		_busy = false; _error(_character_binding.last_error); return
	_mode = "home"; _epoch += 1; _summary = {}; last_error = &""
	_notice = "Saved locally · body and survival resources recover at home. Equipment is not replenished."
	_world_image.hide()
	_busy = false
	_publish()
	_navigate("bunker", false)

func _close_profile() -> void:
	# A failed save leaves the same home and bindings available for retry.
	if _home == null or not _campaign.save_home(_home):
		_error(_campaign.last_error if not _campaign.last_error.is_empty() else &"local_home_missing")
		return
	_release_character()
	if not _home.teardown(_home.generation()): _error(&"local_home_teardown_failed"); return
	_home.queue_free(); _home = null
	_home_admission = null
	_mode = "menu"; _epoch += 1; last_error = &""
	_preparation_return = "bunker"
	_notice = "Campaign saved on this computer. Continue returns to your bunker."
	_world_image.hide()
	_publish()
	_navigate("main_menu", false)


func _deploy() -> void:
	_preparation_return = "bunker"
	_busy = true
	if not _campaign.save_home(_home): _busy = false; _error(_campaign.last_error); return
	_release_character()
	if not _home.teardown(_home.generation()): _busy = false; _error(&"local_home_teardown_failed"); return
	_home.queue_free(); _home = null
	_mode = "deploying"; _epoch += 1
	_notice = "Recording deployment identity and loading Sawmill. Interrupted loading is recovered as an abandoned raid."
	_publish()
	_navigate("deploying", false)

func _start_raid() -> void:
	if _closed or _mode != "deploying" or _session != null: return
	_session = LocalRaidSession.new()
	_world.add_child(_session)
	var sequence: int = _campaign.loaded.payload.project.get(RaidProgressionValues.STATE_KEY, RaidProgressionValues.initial_state()).next_sequence
	var request := ZRequestId.from_parts(PackedStringArray(["local", "deploy", "g" + str(_campaign.loaded.generation), "r" + str(sequence)]))
	if not _session.start(_campaign.store, request.canonical_key(), _campaign.loaded.generation, sequence):
		_busy = false; _error(_session.last_error); return
	var policy := LocalInventoryWorldPolicy.new()
	policy.configure(_session)
	_character_binding = LocalCharacterBinding.new()
	add_child(_character_binding)
	var health_snapshot := _session.combat.health.actor_snapshot(
		_session.raid.admission().actor_id)
	var health := LocalHealthProjection.from_combat(
		_session.raid.admission(), health_snapshot)
	if not _character_binding.bind(_character, _session.deployment.inventory,
			_session.raid.admission(), health, policy):
		_busy = false; _error(_character_binding.last_error); return
	_remember_health_projection(health_snapshot)
	_health_projection_builds += 1
	_mode = "raid"; _world_image.show(); _busy = false; last_error = &""
	_notice = "WASD move · mouse aim · LMB fire · R reload · V melee · E search/open/extract · Tab inventory · M map · Esc pause"
	_publish()
	_navigate("hud", false)

func _route_changed(route: String, _screen: Control) -> void:
	_release_input()
	if _mode == "home":
		if route in CHARACTER_ROUTES:
			if _last_route not in CHARACTER_ROUTES:
				_preparation_return = "maps" if _last_route == "maps" else "bunker"
		else:
			_preparation_return = "bunker"
	if _mode == "home" and _home != null and _last_route in ["inventory", "health", "stats"]:
		if not _campaign.save_home(_home): _error(_campaign.last_error)
	if _mode == "raid" and route == "hud":
		_input_binding = ZCombatInputBinding.new()
		add_child(_input_binding)
		var native := get_node_or_null("/root/CommonUI") as CommonUIRuntime
		if not _input_binding.bind(native, _ui.input_service, _session.player_router, _session.hud_model, _session.raid.generation()):
			_error(&"local_gameplay_input_failed"); return
		_interaction_handle = native.register_action(ZerkovInputActions.GAME_INTERACT, Callable(self, "_handle_interact"),
			{"owner":self,"context":ZerkovInputActions.GAMEPLAY_CONTEXT,"priority":1,"ui_user":0})
		if _interaction_handle == null: _error(&"local_interaction_input_failed"); return
	_last_route = route
	_publish()
	if _mode == "deploying" and route == "deploying": _present_deployment.call_deferred()

## Give the real loading screen one rendered frame before synchronous raid setup.
## No cosmetic timer or manufactured percentage delays a ready operation.
func _present_deployment() -> void:
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
	if not _closed and _mode == "deploying": _start_raid.call_deferred()

func _home_inventory_changed(_scope: StringName, _view: InventoryView) -> void:
	if not _closed and not _busy and _mode == "home": _publish()


func _handle_interact(event: Dictionary) -> int:
	if not can_advance(): return CommonUIRuntime.ROUTE_UNHANDLED
	if event.get("phase") == CommonUIRuntime.PHASE_PRESSED: _consume.call_deferred(&"interact", _epoch)
	return CommonUIRuntime.ROUTE_HANDLED

func _interact() -> void:
	var target := _session.nearest_target()
	if target.is_empty(): _notice = "Move within reach of a marked crate or Road Gate."; _publish(); return
	if _session.crate_ids.has(target) and _session.progression.was_crate_searched(target):
		if not _character.open_world_loot(InventoryPresentationController.SOURCE_CRATE, _session.crate_ids[target]):
			_error(&"local_loot_workspace_failed"); return
		_navigate("inventory")
	elif target == SupplyRunGraph.ROAD_GATE and _session.progression.snapshot().get("clock", {}).get("counting", false):
		_session.cancel_interaction()
	else:
		if not _session.interact(target): _notice = "Interaction was not admitted. Move closer and retry."
		_publish()

func _finish() -> void:
	if _closed or _session == null: return
	_busy = true
	_release_input(); _release_character()
	var result := _session.finish()
	_busy = false
	if result.get("ok") != true or result.get("committed") != true:
		last_error = StringName(result.get("reason", &"local_settlement_failed"))
		_mode = "save_error"; _notice = "Result not acknowledged. Retry local save; do not start another raid. " + String(result.get("reason", "unknown"))
		_publish(); _navigate("summary_solo", false); return
	_summary = result.receipt
	last_error = &""
	_mode = "summary"; _epoch += 1
	_notice = "Raid result committed locally. Returning home will not apply it again."
	_publish(); _navigate("summary_solo", false)

func _abandon() -> void:
	_release_input(); _release_character()
	if not _session.release(): _error(_session.last_error); return
	_session.queue_free(); _session = null
	if not _campaign.reload(true): _error(_campaign.last_error); return
	_summary = _campaign.recovered_result.get("receipt", {})
	_mode = "summary"; _epoch += 1
	_notice = "Raid abandoned. Only deployment-time secure contents were recovered."
	_publish(); _navigate("summary_solo", false)

func _publish() -> void:
	# A teardown error must not publish into an already-retired provider, nor
	# into one the SceneTree already freed while an exit path was still failing.
	if _closed or not is_instance_valid(_provider) or not _provider.is_active(): return
	_serial += 1
	var frame := {"epoch":_epoch,"serial":_serial,"mode":_mode,"has_profile":_campaign.has_profile(),
		"can_create":_campaign.loaded.get("reason") == &"profile_missing" and _campaign.last_error.is_empty(),
		"profile_generation":int(_campaign.loaded.get("generation", 0)),"notice":_notice,"error":String(last_error),
		"summary":_summary,"progression":{},"combat":{},"tick":0,"map_markers":[],"searched_ids":[],"nearest_target":"",
		"save_location":_save_location,"preparation_return":_preparation_return,"home_equipment":{},"home_available":_mode == "home" and _home != null and _home.is_current_generation(_home.generation())}
	if frame.home_available:
		frame.home_equipment = LocalPreparationView.equipment_from_snapshot(
			_home.raid_authority().snapshot(_home.raid_player_inventory_id))
	if _session != null and _session.progression != null:
		frame.progression = _session.progression.snapshot()
		frame.lifecycle = int(_session.raid.lifecycle)
		frame.exit_distance = roundi(_session.player_movement.position_px.distance_to(_session.layout.cell_center(_session.layout.anchor(SupplyRunGraph.ROAD_GATE).cell)) / ZWorldUnits.GODOT_PIXELS_PER_WORLD_UNIT)
		frame.tick = int(frame.progression.get("tick", 0))
		frame.searched_ids = frame.progression.get("searched_ids", [])
		frame.nearest_target = _session.nearest_target() if _mode == "raid" else ""
		if _session.hud_model != null:
			frame.combat = _session.hud_model.snapshot()
			frame.actor_id = _session.raid.admission().actor_id.canonical_key()
			frame.weapon_id = String(_session.hud_model.confirmed_frame().get("weapon", {}).get("instance_id", ""))
	frame.map_markers = _map_markers_for_frame(String(frame.get(
		"actor_id", "zerkov.entity.local.player")), _last_route == "maps")
	var projection := LocalGameViews.build_incremental(
		frame, _view_cache, _view_dependencies)
	var views := projection.get("views", []) as Array[ZReadOnlyView]
	for index in projection.get("rebuilt", PackedInt32Array()) as PackedInt32Array:
		_view_build_counts[index] += 1
	for view: ZReadOnlyView in views:
		if view == null:
			last_error = &"local_typed_view_invalid"
			push_error(last_error)
			return
	var ok: bool = _provider.replace_views(_epoch, views[0], views[1], views[2], views[3], views[4]) if _epoch > _provider.generation() \
		else _provider.publish_views(_epoch, views[0], views[1], views[2], views[3], views[4])
	if not ok: last_error = _provider.last_error; push_error(last_error); return
	_view_cache = views
	_view_dependencies = projection.get("dependencies", []) as Array
	_ui_port.publish(frame)
	published.emit(_ui_port.snapshot())

func presentation_work_counts() -> Dictionary:
	return RaidProgressionValues.freeze({
		"bunker_view_builds": _view_build_counts[LocalGameViews.DOMAIN_BUNKER],
		"raid_view_builds": _view_build_counts[LocalGameViews.DOMAIN_RAID],
		"task_view_builds": _view_build_counts[LocalGameViews.DOMAIN_TASKS],
		"map_view_builds": _view_build_counts[LocalGameViews.DOMAIN_MAP],
		"summary_view_builds": _view_build_counts[LocalGameViews.DOMAIN_SUMMARY],
		"health_view_builds": _health_projection_builds,
	})


func _publish_changed_health() -> bool:
	var admission := _session.raid.admission()
	var snapshot := _session.combat.health.actor_snapshot(admission.actor_id)
	if snapshot.is_empty():
		return false
	var actor_key := String(snapshot.get("actor_id", ""))
	var revision := int(snapshot.get("health_revision", -1))
	var digest := String(snapshot.get("state_digest", ""))
	if actor_key == _health_projection_actor \
			and revision == _health_projection_revision \
			and digest == _health_projection_digest:
		return true
	var health := LocalHealthProjection.from_combat(admission, snapshot)
	if health == null or not _character.publish_health_view(health):
		return false
	_remember_health_projection(snapshot)
	_health_projection_builds += 1
	return true


func _remember_health_projection(snapshot: Dictionary) -> void:
	_health_projection_actor = String(snapshot.get("actor_id", ""))
	_health_projection_revision = int(snapshot.get("health_revision", -1))
	_health_projection_digest = String(snapshot.get("state_digest", ""))


func _map_markers_for_frame(actor_key: String, refresh_player: bool) -> Array:
	if _map_layout == null:
		_map_layout = load(
			"res://game/world/sawmill/sawmill_yard_layout.tres") as ZSawmillYardLayout
	var layout := _map_layout
	if layout == null:
		return []
	if _static_map_markers.is_empty():
		for id: String in SupplyRunGraph.CRATES + [SupplyRunGraph.ROAD_GATE]:
			_static_map_markers.append(RaidProgressionValues.freeze({
				"id": id,
				"label": LocalGameViews.display_item(id),
				"kind": "exit" if id == SupplyRunGraph.ROAD_GATE else "crate",
				"position": layout.cell_center(layout.anchor(id).cell) \
					/ layout.world_bounds().size,
			}))
		_static_map_markers.make_read_only()
	# The map route pauses the solo authority clock. Preserve its last immutable
	# projection while hidden instead of rebuilding a screen nobody can see on
	# every movement tick; opening the map refreshes the player marker first.
	if not refresh_player and not _map_markers.is_empty():
		return _map_markers
	var player_position := Vector2(1.0e30, 1.0e30)
	var player_actor := ""
	if _session != null and _session.player_movement != null:
		player_actor = actor_key
		player_position = _session.player_movement.position_px \
			/ layout.world_bounds().size
	if not _map_markers.is_empty() and player_actor == _map_marker_actor \
			and player_position == _map_marker_position:
		return _map_markers
	var markers: Array = []
	for marker in _static_map_markers:
		markers.append(marker)
	if not player_actor.is_empty():
		markers.append(RaidProgressionValues.freeze({
			"id": player_actor,
			"label": "You",
			"kind": "player",
			"position": player_position,
		}))
	markers.make_read_only()
	_map_markers = markers
	_map_marker_actor = player_actor
	_map_marker_position = player_position
	return _map_markers


func _navigate(route: String, record: bool = true) -> void:
	if _ui != null and not _ui.request_route(route, record): _error(&"local_route_rejected")

func _release_character() -> void:
	if _character_binding != null:
		_character_binding.release(); _character_binding.queue_free(); _character_binding = null
	_health_projection_actor = ""
	_health_projection_revision = -1
	_health_projection_digest = ""

func _release_input() -> void:
	if _interaction_handle != null: _interaction_handle.call("release"); _interaction_handle = null
	if _input_binding != null: _input_binding.release(); _input_binding.queue_free(); _input_binding = null

func shutdown() -> bool:
	if _closed: return true
	_release_input()
	if _home != null and not _campaign.save_home(_home): return _error(_campaign.last_error)
	_release_character()
	if _session != null and not _session.release(): return _error(_session.last_error)
	if _home != null and not _home.teardown(_home.generation()): return _error(&"local_home_teardown_failed")
	if not _campaign.close(): return _error(&"local_profile_close_failed")
	_closed = true
	_ui_port.release()
	return true

## A failed local write must never trap the operator inside the window. The
## first request surfaces the error and keeps the unsaved state on disk; an
## explicit second request exits without inventing a successful save.
func _quit() -> void:
	if shutdown() or _quit_pending:
		get_tree().quit()
		return
	_quit_pending = true
	_notice = "Local save failed: " + String(last_error) \
		+ ". Retry the save, or request quit again to exit without saving."
	_publish()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST: _quit()

func _exit_tree() -> void:
	if not _closed: shutdown()

func _error(reason: StringName) -> bool:
	last_error = reason
	_notice = "Local session stopped: " + String(reason) + ". No sample state was substituted."
	if _mode in ["raid", "deploying", "settling"]: _mode = "error"
	_busy = false
	_publish()
	return false
