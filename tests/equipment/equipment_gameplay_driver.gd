extends "res://tests/local/local_flow_player_driver.gd"
## Normal deployed application + real CommonUI input. The inherited route uses
## authored navigation and white-box aim guidance; native combat alone decides
## hit, obstruction, ammunition and health. No teleports or fixture outcomes.
const Exact1080CaptureGuard = preload("res://game/presentation/exact_1080_capture_guard.gd")
var _driver: RefCounted
var _damage_seen: bool = false
var _damage_capture: bool = false
var _qa_label: Label
var _capture_index: int = 0

func run(driver: RefCounted, item_id: int) -> bool:
	_driver = driver
	_game = driver.game; _tree = driver.tree; _check = driver.check
	_started_ms = Time.get_ticks_msec()
	_capture_shot_geometry()
	await driver.key(KEY_ESCAPE)
	if not driver.route("hud"): return false
	var initial := _game._session.hud_model.confirmed_frame()
	var weapon_key: String = initial.weapon.instance_id
	if not _assert(initial.weapon.loaded_rounds == 0, "newly deployed persisted AKM starts genuinely empty"): return false
	if not visual(LocalWeaponPresenter.AKM, weapon_key): return false
	await capture("Deployed: original AK-and-arms pose, no duplicated arms")
	aim_at(_game._session.player_movement.position_px + Vector2(-100, 0))
	if not await advance_ticks(1): return false
	await capture("Original holding pose: left-facing character and attached arms")
	var shot_count: int = weapon_view().shot_count
	aim_at(_game._session.player_movement.position_px + Vector2(100, 0))
	trigger()
	if not await advance_ticks(1): return false
	if not _assert(_game._session.hud_model.snapshot().ammo == 0 and weapon_view().shot_count == shot_count,
		"dry trigger neither consumes ammunition nor creates muzzle feedback"): return false
	var receipt: Dictionary = _game._session.combat.execution.receipt(_game._input_binding.last_receipt.request_id)
	if not _assert(receipt.terminal and not receipt.committed, "dry trigger receives an actual rejected combat receipt"): return false
	if not _assert(_game._session.player_movement.facing_direction.dot(Vector2.RIGHT) > 0.99,
		"ordinary screen-space pointer aims the actual actor toward the intended world point"): return false
	await capture("Empty magazine: trigger rejected, no shot or muzzle flash")
	await driver.key(KEY_R)
	if not await advance_ticks(1): return false
	if not _assert(weapon_view().reloading and _game._session.hud_model.snapshot().reloading, "world weapon and HUD share the actual reload"): return false
	await capture("Reload: the real reserve is reserved; world weapon shows progress")
	trigger()
	if not await advance_ticks(1): return false
	if not _assert(weapon_view().shot_count == shot_count, "trigger during reload does not fabricate a shot"): return false
	if not await advance_ticks(ZerkovCombatContent.AKM_RELOAD_TICKS + 1): return false
	if not _assert(_game._session.hud_model.snapshot().ammo == 30 and not weapon_view().reloading,
		"native reload completes with 30 real loaded rounds"): return false
	await capture("Reload complete: 30 rounds loaded from the carried inventory")
	aim_at(_game._session.player_movement.position_px + Vector2(100, 0))
	trigger()
	if not await advance_ticks(1): return false
	if not _assert(_game._session.hud_model.snapshot().ammo == 29 and weapon_view().shot_count == shot_count + 1
		and weapon_view().effect_count == 1, "ordinary fire consumes one round and presents one committed shot"): return false
	await capture("Fire: 30 to 29 rounds; committed muzzle flash and resolved trace")
	trigger()
	if not await advance_ticks(1): return false
	if not _assert(_game._session.hud_model.snapshot().ammo == 29 and weapon_view().shot_count == shot_count + 1,
		"early cadence rejection creates neither another round nor another effect"): return false
	# Sample the bright second muzzle cell from the original seven-frame strip.
	if not await advance_ticks(2): return false
	await capture("Original muzzle flash: source animation at the actual barrel")
	# Changes are actual authored Character controls. The pause view is not
	# allowed to mutate the world presenter or native abilities directly.
	await driver.key(KEY_I)
	if not driver.route("inventory") or not await driver.click(driver.named("InventoryContent/CharacterColumn/SlingSlot")): return false
	if not _assert(driver.gear(driver.PRIMARY).is_empty() and weapon_view().held_definition == LocalWeaponPresenter.AKM,
		"paused equipment input waits for canonical reconciliation before changing world gun"): return false
	await driver.key(KEY_ESCAPE)
	if not driver.route("hud") or not await advance_ticks(1): return false
	if not visual(LocalWeaponPresenter.MACHETE): return false
	if not _assert(not _game._session.hud_model.snapshot().has_weapon and weapon_view().effect_count == 0, "unequip removes firearm context and old shot effects"): return false
	trigger()
	if not await advance_ticks(1): return false
	if not _assert(weapon_view().shot_count == shot_count + 1 and _game._session.combat.weapons.snapshot(weapon_key).loaded_rounds == 29,
		"no equipped primary means no firing and no hidden ammo loss"): return false
	await capture("AKM unequipped: only the actual machete is held; firing is disabled")
	await driver.key(KEY_V)
	if not await advance_ticks(1): return false
	if not _assert(_game._session.hud_model.confirmed_frame().melee.phase == &"windup", "ordinary melee input begins the authoritative machete timeline"): return false
	await capture("Machete: actual melee input starts its committed swing")
	if not await advance_ticks(10): return false
	await capture("Original melee: source arm/body active frame with the actual machete")
	if not await advance_ticks(30): return false
	await driver.key(KEY_I)
	if not driver.route("inventory") or not await driver.click(driver.named("InventoryContent/CharacterColumn/LegStrapSlot")): return false
	await driver.key(KEY_ESCAPE)
	if not driver.route("hud") or not await advance_ticks(1): return false
	if not _assert(not weapon_view().visible and weapon_view().held_definition.is_empty(), "both supported slots empty means empty hands in the world"): return false
	await capture("Both weapons unequipped: empty hands, no fixture firearm")
	await driver.key(KEY_I)
	if not driver.route("inventory"): return false
	var rifle: Control = driver.item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_AKM))
	if not _assert(rifle != null and rifle.get("item").item_id == item_id, "same persisted AKM is still carried"): return false
	if not await driver.click(rifle) or not await driver.click(driver.named("InventoryContent/CharacterColumn/SlingSlot")): return false
	var blade: Control = driver.item_slot("backpack", String(ZerkovInventoryCatalog.ITEM_MACHETE))
	if not await driver.click(blade) or not await driver.click(driver.named("InventoryContent/CharacterColumn/LegStrapSlot")): return false
	await driver.key(KEY_ESCAPE)
	if not driver.route("hud") or not await advance_ticks(1): return false
	if not visual(LocalWeaponPresenter.AKM, weapon_key): return false
	if not _assert(_game._session.hud_model.snapshot().ammo == 29, "re-equipping same weapon preserves 29 rounds; no ammo refill"): return false
	await capture("Same AKM re-equipped: world gun returns with exactly 29 rounds")
	# Inherited ordinary movement and fire input toward authored targets. The
	# test uses canonical head guidance, not an invisible damage command. This
	# proves combat; bespoke sprite-to-seven-zone art alignment is not claimed.
	for key: String in _game._session.crate_keys():
		if not await _walk_to(_game._session.target_approach(key)): return false
		_stop()
		if _damage_seen: break
	if not _assert(_damage_seen and _damage_capture, "actual traversal/fire hits a real enemy and lowers native health"): return false
	if not _assert(weapon_view().shot_count > shot_count + 1, "restored same weapon successfully fires again in the encounter"): return false
	await capture("Real encounter: confirmed player shots changed enemy health")
	print("EQUIPMENT_GAMEPLAY_RESULT shots=", weapon_view().shot_count, " damage_confirmed=", _damage_seen,
		" weapon_instance=", weapon_key, " loaded_rounds=", _game._session.hud_model.snapshot().ammo)
	if _qa_label != null:
		_qa_label.get_parent().queue_free(); _qa_label = null
	await driver.key(KEY_I)
	return driver.route("inventory")

func weapon_view() -> Dictionary:
	var actor: LocalActorPresenter = _game._session._actors[_game._session.raid.admission().actor_id.canonical_key()]
	return actor._weapon.snapshot()

func visual(definition: String, instance: String = "") -> bool:
	var value := weapon_view()
	return _assert(value.visible and value.held_definition == definition and (instance.is_empty() or value.held_instance_id == instance),
		"world weapon agrees with committed equipment: " + definition)

func aim_at(point: Vector2) -> void:
	var screen := ZWorldViewportPolicy.world_to_screen(point, _game._session.camera.global_position)
	if _driver.filming: _tree.root.warp_mouse(screen)
	var motion := InputEventMouseMotion.new(); motion.position = screen; motion.global_position = screen
	Input.parse_input_event(motion); Input.flush_buffered_events()
	if _driver.cursor != null: _driver.cursor.position = screen

func _mouse(point: Vector2, control: bool = false) -> void:
	# Actual gameplay samples viewport mouse position at the canonical tick.
	# Keep the physical pointer aligned with the ordinary injected click.
	if _driver.filming: _tree.root.warp_mouse(point)
	if _driver.cursor != null: _driver.cursor.position = point
	super._mouse(point, control)

func trigger() -> void:
	_mouse(_tree.root.get_mouse_position())

func advance_ticks(count: int) -> bool:
	for i in range(count):
		if not _assert(_game.can_advance() and _game.advance(), "actual gameplay tick: " + String(_game.last_error)): return false
		if i % 4 == 0: await _tree.process_frame
	return true

func _tick(direction: Vector2) -> bool:
	var before := enemy_health()
	if not await super._tick(direction): return false
	var after := enemy_health()
	for event: Dictionary in _game._session.hud_model.confirmed_frame().feedback:
		if event.kind != &"shot" or not event.get("damage_confirmed", false): continue
		var damaged: bool = false
		for id: String in before:
			if after.has(id) and after[id] < before[id]: damaged = true
		if not _assert(damaged, "committed shot health confirmation corresponds to actual enemy HP loss"): return false
		_damage_seen = true
		if not _assert(weapon_view().effect_count > 0, "real damaging shot reaches the world presenter"): return false
		if not _damage_capture:
			_damage_capture = true
			print("EQUIPMENT_ENEMY_DAMAGE before=", before, " after=", after, " consequence=", event.id)
			await capture("Hit confirmed: this real shot reduced the enemy's authoritative health")
	if _driver.filming and ticks % 8 == 4: await _tree.process_frame
	return true

func enemy_health() -> Dictionary:
	var result: Dictionary = {}
	for id: String in _game._session.rows:
		var row: Dictionary = _game._session.rows[id]
		if row.archetype == "player": continue
		var total: int = 0
		for part: Dictionary in _game._session.combat.health.actor_snapshot(row.actor_id).body_parts: total += part.health_micros
		result[id] = total
	return result

func capture(label: String) -> void:
	if _driver.filming:
		if _qa_label == null:
			var layer := CanvasLayer.new(); layer.layer = 99; _tree.root.add_child(layer)
			_qa_label = Label.new(); layer.add_child(_qa_label)
			_qa_label.position = Vector2(32, 80)
			_qa_label.add_theme_font_size_override("font_size", 22)
			_qa_label.add_theme_color_override("font_outline_color", Color.BLACK)
			_qa_label.add_theme_constant_override("outline_size", 6)
			_qa_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_qa_label.text = "QA EVIDENCE | " + label
	await _driver.linger(label)
	# Let the authored cosmetic HUD process the same pointer used by gameplay.
	await _tree.process_frame
	await _tree.process_frame
	var hud: Control = _game._ui.screen
	var crosshair := hud.get_node("CrosshairGroup/Crosshair") as Control
	_assert(crosshair.get_global_rect().get_center().distance_to(_tree.root.get_mouse_position()) <= 1.0,
		"rendered crosshair center agrees with the actual gameplay pointer")
	var frame := _game._session.hud_model.confirmed_frame()
	var actor: LocalActorPresenter = _game._session._actors[_game._session.raid.admission().actor_id.canonical_key()]
	var world_view := weapon_view()
	_assert(actor._layers._layers[2].visible != world_view.arms_overridden, "no duplicate ordinary arms under the authored holding pose")
	if world_view.held_definition == LocalWeaponPresenter.AKM:
		_assert(actor._weapon._sprite.texture.resource_path == "res://assets/original/ally/arms+ak.png", "live world rifle uses exact supplied holding artwork")
	_assert(hud.get_node("WeaponGroup/PrimaryIcon").visible == (frame.health.alive and not frame.weapon.is_empty())
		and not hud.get_node("WeaponGroup/SecondaryIcon").visible
		and hud.get_node("WeaponGroup/MeleeIcon").visible == (frame.health.alive and not frame.melee_equipment.is_empty()),
		"HUD weapon icons follow confirmed gear; unsupported secondary is not a fixture")
	if _driver.filming:
		var output := OS.get_environment("ZERKOV_EQUIPMENT_STILLS")
		if not output.is_empty():
			_capture_index += 1
			var image := _tree.root.get_texture().get_image()
			if not Exact1080CaptureGuard.accepts(_tree.root, _tree.root, image):
				_assert(false, "raw gameplay capture failed physical exact-1080 guard")
				return
			var saved := image.save_png(output.path_join("gameplay-%02d.png" % _capture_index))
			_assert(saved == OK, "raw capture written")
