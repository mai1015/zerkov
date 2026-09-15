extends SceneTree
## Real phase execution: canonical inventory, weapon mechanics, GAS, hitboxes,
## locomotion and root combat composition. Test-only loadout seed is explicit.
var checks: int = 0
var failures: int = 0
var serial: int = 0
var _owners: Array[Node] = []
var _raid: RaidAuthority
var _session: RaidCombatSession
var _player: ZEntityId
var _enemy: ZEntityId
var _router: ZCombatActionRouter
var _enemy_router: ZCombatActionRouter
var _model: ZCombatHudModel
var _moves: Array[ZPlayerLocomotion] = []
func _initialize() -> void:
	run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("NATIVE_COMBAT_EXECUTION: " + message)
func run() -> void:
	# Test watchdog only; never advances the authoritative simulation.
	create_timer(15.0).timeout.connect(_watchdog)
	if not ClassDB.class_exists("WeaponAuthority") or not ClassDB.class_exists("GameplayAbilityComponent"):
		print("NATIVE_COMBAT_EXECUTION_BLOCKED missing_native_addons")
		quit(2); return
	if not await _setup():
		await _cleanup(); quit(1); return
	var frame := _frame()
	check(frame.weapon.loaded_rounds == 0, "weapon initialized from empty loadout state, no fake rounds")
	var empty := _submit(&"fire", _fire_payload())
	if not _tick(): await _finish(); return
	check(not _session.execution.receipt(empty.request_id).committed, "out-of-ammo is ordinary rejection")
	check(_raid.lifecycle == RaidAuthority.Lifecycle.ACTIVE, "empty weapon does not fail raid")
	var begin := _submit(&"reload", _reload_payload())
	if not _tick(): await _finish(); return
	frame = _frame()
	check(frame.weapon.phase == "reloading", "real reload begun")
	print("NATIVE_COMBAT_EXECUTION_RELOAD ", frame.weapon.reload)
	var due: int = _raid.last_processed_tick + ZerkovCombatContent.AKM_RELOAD_TICKS
	for i in range(ZerkovCombatContent.AKM_RELOAD_TICKS):
		if not _tick(): await _finish(); return
	frame = _frame()
	check(frame.weapon.loaded_rounds == 30 and frame.reserve_rounds == 30, "reload committed actual inventory quantities")
	check(_session.execution.receipt(begin.request_id).committed, "queue receipt becomes committed only at native due work")
	var before := _total_hp(_session.health.actor_snapshot(_enemy))
	var shot := _submit(&"fire", _fire_payload())
	if not _tick(): await _finish(); return
	check(_frame().weapon.loaded_rounds == 29, "shot consumed one round")
	check(_total_hp(_session.health.actor_snapshot(_enemy)) < before, "shot applies real GAS zone damage")
	check(_session.execution.receipt(shot.request_id).committed, "resolved shot terminal receipt")
	check(_session.execution.committed_noise(_raid.last_processed_tick).size() == 1, "committed shot produces hearing event")
	var early := _submit(&"fire", _fire_payload())
	if not _tick(): await _finish(); return
	check(not _session.execution.receipt(early.request_id).committed and _frame().weapon.loaded_rounds == 29, "cadence rejection preserves ammo")
	# Native reload uses a sequence after fire, not a separate stale allocator.
	var second := _submit(&"reload", _reload_payload())
	if not _tick(): await _finish(); return
	check(_frame().weapon.phase == "reloading", "fire -> reload shares native command watermark")
	var cancel := _submit(&"cancel_reload", {"weapon_id":_frame().weapon.instance_id,
		"expected_weapon_revision":_frame().weapon.revision,"reservation_id":_frame().weapon.reload.reservation_id})
	if not _tick(): await _finish(); return
	check(_session.execution.receipt(cancel.request_id).committed and _frame().weapon.loaded_rounds == 29, "cancel returns real quantity hold without refill")
	check(not _session.execution.receipt(second.request_id).committed, "cancelled reload not reported completed")
	var prior_hp := _total_hp(_session.health.actor_snapshot(_enemy))
	var stamina: int = _frame().health.stamina_micros
	var melee := _submit(&"melee", {"weapon_id":_frame().melee_equipment.weapon_id,
		"expected_equipment_revision":_frame().melee_equipment.revision})
	if not _tick(): await _finish(); return
	check(_session.execution.receipt(melee.request_id).committed, "swing cost admitted in real health phase")
	check(_frame().health.stamina_micros == stamina - ZerkovCombatContent.MACHETE_STAMINA_COST_MICROUNITS, "stamina paid once through GAS")
	check(_frame().melee.phase == &"windup", "windup starts at authoritative tick")
	for i in range(9):
		if not _tick(): await _finish(); return
		check(_total_hp(_session.health.actor_snapshot(_enemy)) == prior_hp, "no animation-driven early melee damage")
	if not _tick(): await _finish(); return
	check(_total_hp(_session.health.actor_snapshot(_enemy)) < prior_hp, "real active sweep applies health consequence")
	var contact_hp := _total_hp(_session.health.actor_snapshot(_enemy))
	for i in range(3):
		if not _tick(): await _finish(); return
	check(_total_hp(_session.health.actor_snapshot(_enemy)) == contact_hp, "one damage per swing")
	check(_model.snapshot().ammo == _frame().weapon.loaded_rounds, "HUD reads confirmed native ammo")
	check(_model.snapshot().health_micros == _total_hp(_frame().health), "HUD reads confirmed body health")
	await _finish()
func _finish() -> void:
	await _cleanup()
	print("NATIVE_COMBAT_EXECUTION_RESULT checks=",checks," failures=",failures)
	quit(0 if failures == 0 else 1)
func _setup() -> bool:
	var raid_id := ZRaidId.parse("zerkov.raid.combat.execution")
	var coordinator := SessionCoordinator.new()
	var admission := coordinator.open_offline(raid_id, &"combat_profile", &"player")
	_player = admission.actor_id
	_enemy = ZEntityId.parse("zerkov.entity.combat.scav")
	_raid = RaidAuthority.new()
	check(_raid.configure(raid_id, admission, 33), "raid configures")
	check(_raid.authorize_actor(_enemy, ZRaidIntent.Source.AI, 1), "AI source authorized")
	var roster: Array[Dictionary] = []
	for index in range(2):
		var actor: ZEntityId = _player if index == 0 else _enemy
		var source: ZRaidIntent.Source = ZRaidIntent.Source.PLAYER if index == 0 else ZRaidIntent.Source.AI
		var owner := _inventory(index)
		if owner == null: return false
		var move := ZPlayerLocomotion.new()
		var handler := StringName("combat_test_move_%d" % index)
		move.configure(actor, Vector2.ZERO if index == 0 else Vector2(48,0), ZPlayerFacing.Facing4.EAST if index == 0 else ZPlayerFacing.Facing4.NORTH, source, handler)
		check(move.register_with_authority(_raid, 1), "actual movement phase registered")
		_moves.append(move)
		roster.append({"actor_id":actor,"source":int(source),"movement":move,"movement_handler":handler,"inventory":owner,"natural_melee":false})
	_session = RaidCombatSession.new()
	root.add_child(_session)
	var ready := _session.start(_raid, roster)
	check(ready, "real combat composition startup: " + String(_session.last_error))
	if not ready: return false
	_model = ZCombatHudModel.new()
	_model.configure(_player.canonical_key(),1)
	_session.execution.frame_published.connect(_publish_player)
	_router = _make_router(_player,ZRaidIntent.Source.PLAYER)
	_enemy_router = _make_router(_enemy,ZRaidIntent.Source.AI)
	check(_raid.transition(RaidAuthority.Lifecycle.ACTIVE,1), "raid activated")
	return _tick()
func _publish_player(frame: Dictionary) -> void:
	if frame.actor_id == _player.canonical_key(): check(_model.publish(frame), "confirmed HUD frame")
func _make_router(actor: ZEntityId, source: ZRaidIntent.Source) -> ZCombatActionRouter:
	var encoder := ZCombatInputAdapter.new()
	encoder.configure_source(_raid.admission().session_id, actor, _raid.admission().authority_epoch, 1, source)
	var sink := RaidCombatIntentSink.new()
	check(sink.bind(_raid,actor,source,1), "real intent sink")
	var router := ZCombatActionRouter.new()
	check(router.bind(encoder,sink), "router bound")
	return router
func _submit(kind: StringName, payload: Dictionary) -> Dictionary:
	var outcome := _router.submit_action(kind,payload,_raid.last_processed_tick+1,1)
	check(outcome.get("admitted")==true,"input admission " + String(kind) + ": " + str(outcome))
	_model.predict(outcome)
	return outcome
func _tick() -> bool:
	var ok := _raid.advance_one(1)
	check(ok,"authority tick " + str(_raid.last_processed_tick)+": "+String(_raid.last_error)+" / "+String(_session.execution.last_error)+" / "+String(_session.health.last_error)+" / "+String(_session.fire.last_error))
	return ok
func _frame() -> Dictionary:
	return _session.execution.frame_for(_player.canonical_key())
func _fire_payload() -> Dictionary:
	return {"weapon_id":_frame().weapon.instance_id,"expected_weapon_revision":_frame().weapon.revision}
func _reload_payload() -> Dictionary:
	var payload := _fire_payload()
	payload["expected_inventory_revision"] = _frame().inventory_revision
	return payload
func _total_hp(state: Dictionary) -> int:
	var total: int = 0
	for zone: Dictionary in state.body_parts: total += int(zone.health_micros)
	return total
func _inventory(index: int) -> RaidInventoryOwner:
	var owner := RaidInventoryOwner.new()
	root.add_child(owner)
	_owners.append(owner)
	check(owner.configure(), "test-only prepared inventory")
	var a := owner.raid_authority()
	var id := owner.raid_player_inventory_id
	var snapshot := a.snapshot(id)
	var equipment: int = 0
	var pockets: int = 0
	for c in snapshot.get_containers():
		if int(c.provider_item) != 0: continue
		if c.container_definition_identifier == ZerkovInventoryCatalog.CONTAINER_EQUIPMENT: equipment = c.id
		if c.container_definition_identifier == ZerkovInventoryCatalog.CONTAINER_POCKETS: pockets = c.id
	var definitions: Array = [ZerkovInventoryCatalog.ITEM_AKM,ZerkovInventoryCatalog.ITEM_MACHETE,ZerkovInventoryCatalog.ITEM_AMMO_762]
	for item in range(3):
		var placement := {"kind":"slot","container":equipment,"slot_identifier":String(EquippedItemReconciler.SLOT_PRIMARY if item==0 else EquippedItemReconciler.SLOT_MELEE)} 			if item<2 else {"kind":"spatial","container":pockets,"x":0,"y":0,"rotated":false}
		var result := a.insert_item(id,String(definitions[item]),1 if item<2 else 60,placement,RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 2000+index*100+item)
		check(result.get("accepted",false), "canonical fixture insert " + str(result))
	return owner
func _cleanup() -> void:
	if _session != null:
		check(_session.release(), "combat release: " + String(_session.last_error))
		_session.queue_free()
	if _raid != null: check(_raid.teardown(1),"raid teardown")
	for owner in _owners:
		owner.queue_free()
	await process_frame

func _watchdog() -> void:
	push_error("NATIVE_COMBAT_EXECUTION: contract aborted or timed out before completion")
	quit(1)
