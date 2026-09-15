extends SceneTree
## Real phase execution: canonical inventory, weapon mechanics, GAS, hitboxes,
## locomotion and root combat composition. Test-only loadout seed is explicit.
var checks: int = 0
var failures: int = 0
var _owners: Array[RaidInventoryOwner] = []
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
	create_timer(45.0).timeout.connect(_watchdog)
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
	var held_reserve: int = _frame().reserve_rounds
	var stale_cancel_payload := ZCombatInputBinding.payload_for(&"cancel_reload", _frame())
	stale_cancel_payload.expected_weapon_revision += 1
	var stale_cancel := _submit(&"cancel_reload", stale_cancel_payload)
	if not _tick(): await _finish(); return
	check(_receipt(stale_cancel).reason == &"weapon_revision_stale" and not _receipt(stale_cancel).committed, "cancel checks weapon revision at execution")
	check(_frame().weapon.phase == "reloading" and _frame().reserve_rounds == held_reserve, "stale cancel cannot release the hold")
	var wrong_reservation_payload := ZCombatInputBinding.payload_for(&"cancel_reload", _frame())
	wrong_reservation_payload.reservation_id = "zerkov.reservation.not_current"
	var wrong_reservation := _submit(&"cancel_reload", wrong_reservation_payload)
	if not _tick(): await _finish(); return
	check(_receipt(wrong_reservation).reason == &"reload_reservation_stale" and _frame().weapon.phase == "reloading", "cancel checks reservation identity independently")
	var cancel := _submit(&"cancel_reload", ZCombatInputBinding.payload_for(&"cancel_reload", _frame()))
	if not _tick(): await _finish(); return
	check(_session.execution.receipt(cancel.request_id).committed and _frame().weapon.loaded_rounds == 29, "cancel returns real quantity hold without refill")
	check(not _session.execution.receipt(second.request_id).committed, "cancelled reload not reported completed")
	var prior_hp := _total_hp(_session.health.actor_snapshot(_enemy))
	var stamina: int = _frame().health.stamina_micros
	var stale_melee_payload := ZCombatInputBinding.payload_for(&"melee", _frame())
	stale_melee_payload.expected_equipment_revision += 1
	var stale_melee := _submit(&"melee", stale_melee_payload)
	if not _tick(): await _finish(); return
	check(_receipt(stale_melee).reason == &"melee_equipment_stale", "melee revalidates equipment revision")
	check(_frame().health.stamina_micros == stamina and _frame().melee.phase == &"ready", "stale melee neither spends nor starts")
	var producer_frame := _frame().duplicate(true)
	producer_frame.inventory_revision = int(producer_frame.melee_equipment.revision) + 100
	var melee_payload := ZCombatInputBinding.payload_for(&"melee", producer_frame)
	check(melee_payload.expected_equipment_revision == _frame().melee_equipment.revision and not melee_payload.has("expected_inventory_revision"), "producer does not substitute inventory revision for equipment revision")
	var melee := _submit(&"melee", melee_payload)
	if not _tick(): await _finish(); return
	check(_session.execution.receipt(melee.request_id).committed, "swing cost admitted in real health phase")
	check(_frame().health.stamina_micros == stamina - ZerkovCombatContent.MACHETE_STAMINA_COST_MICROUNITS, "stamina paid once through GAS")
	check(_frame().melee.phase == &"windup", "windup starts at authoritative tick")
	var busy := _submit(&"melee", ZCombatInputBinding.payload_for(&"melee", _frame()))
	for i in range(ZMeleePolicy.MACHETE_WINDUP - 1):
		if not _tick(): await _finish(); return
		check(_total_hp(_session.health.actor_snapshot(_enemy)) == prior_hp, "no animation-driven early melee damage")
	if not _tick(): await _finish(); return
	check(_receipt(busy).reason == &"melee_busy", "second swing rejected during windup")
	check(_total_hp(_session.health.actor_snapshot(_enemy)) < prior_hp, "real active sweep applies health consequence")
	check(_frame().melee.phase == &"active", "active starts at exact authority tick")
	check(_frame().health.stamina_micros == stamina - ZerkovCombatContent.MACHETE_STAMINA_COST_MICROUNITS, "busy retry and active contact cannot spend again")
	var contact_hp := _total_hp(_session.health.actor_snapshot(_enemy))
	for i in range(3):
		if not _tick(): await _finish(); return
	check(_total_hp(_session.health.actor_snapshot(_enemy)) == contact_hp, "one damage per swing")
	check(_frame().melee.phase == &"recovery", "active end enters recovery")
	var recovery_busy := _submit(&"melee", ZCombatInputBinding.payload_for(&"melee", _frame()))
	if not _tick(): await _finish(); return
	check(_receipt(recovery_busy).reason == &"melee_busy", "recovery blocks a new swing")
	var ready_tick: int = _frame().melee.swing.ready_tick
	while _raid.last_processed_tick < ready_tick - 1:
		if not _tick(): await _finish(); return
	check(_frame().melee.phase == &"recovery", "last recovery tick remains blocked")
	if not _tick(): await _finish(); return
	check(_frame().melee.phase == &"ready", "recovery ends at exact ready tick")
	if failures == 0: print("NATIVE_COMBAT_EXECUTION_STAGE melee_timing_cost_contact_recovery_passed")
	if not _test_quick_heal(): await _finish(); return
	if not _test_miss_and_duplicate(): await _finish(); return
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
func _submit(kind: StringName, payload: Dictionary, router: ZCombatActionRouter = null) -> Dictionary:
	var target: ZCombatActionRouter = _router if router == null else router
	check(ZCombatActionCodec.validate_payload(kind, payload).is_empty(), "production payload validates: " + String(kind))
	var outcome := target.submit_action(kind,payload,_raid.last_processed_tick+1,1)
	check(outcome.get("admitted")==true,"input admission " + String(kind) + ": " + str(outcome))
	if router == null: _model.predict(outcome)
	return outcome
func _tick() -> bool:
	# Stop before dereferencing a rejected admission or cascading phase failure.
	if failures > 0: return false
	var ok := _raid.advance_one(1)
	check(ok,"authority tick " + str(_raid.last_processed_tick)+": "+String(_raid.last_error)+" / "+String(_session.execution.last_error)+" / "+String(_session.health.last_error)+" / "+String(_session.fire.last_error))
	return ok and failures == 0
func _frame() -> Dictionary:
	return _session.execution.frame_for(_player.canonical_key())
func _fire_payload() -> Dictionary:
	return ZCombatInputBinding.payload_for(&"fire", _frame())
func _reload_payload() -> Dictionary:
	return ZCombatInputBinding.payload_for(&"reload", _frame())
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
	var definitions: Array = [ZerkovInventoryCatalog.ITEM_AKM,ZerkovInventoryCatalog.ITEM_MACHETE,ZerkovInventoryCatalog.ITEM_AMMO_762,ZerkovInventoryCatalog.ITEM_BANDAGE,ZerkovInventoryCatalog.ITEM_SPLINT]
	for item in range(definitions.size()):
		var placement := {"kind":"slot","container":equipment,"slot_identifier":String(EquippedItemReconciler.SLOT_PRIMARY if item==0 else EquippedItemReconciler.SLOT_MELEE)} \
			if item<2 else {"kind":"spatial","container":pockets,"x":item-2,"y":0,"rotated":false}
		var result := a.insert_item(id,String(definitions[item]),1 if item<2 else (60 if item==2 else 2),placement,RaidInventoryOwner.FIXTURE_INSERT_ACTOR_ID, 2000+index*100+item)
		check(result.get("accepted",false), "canonical fixture insert " + String(definitions[item]))
		if not result.get("accepted",false): return null
	return owner
func _cleanup() -> void:
	if _session != null:
		check(_session.release(), "combat release: " + String(_session.last_error))
		_session.queue_free()
	if _raid != null: check(_raid.teardown(1),"raid teardown")
	for owner in _owners:
		owner.queue_free()
	await process_frame

func _receipt(admission: Dictionary) -> Dictionary:
	var result := _session.execution.receipt(String(admission.get("request_id", "")))
	check(not result.is_empty(), "admitted action has an execution receipt")
	return result

func _quantity(index: int, definition: StringName) -> int:
	var owner: RaidInventoryOwner = _owners[index]
	var snapshot := owner.raid_authority().snapshot(owner.raid_player_inventory_id)
	var count: int = 0
	for item: Dictionary in snapshot.get_items():
		if StringName(item.item_definition_identifier) == definition: count += int(item.quantity)
	return count

func _test_quick_heal() -> bool:
	var enemy_frame := _session.execution.frame_for(_enemy.canonical_key())
	var payload := ZCombatInputBinding.payload_for(&"quick_heal", enemy_frame)
	check(not payload.is_empty(), "real damage produced a treatable injury")
	if failures > 0: return false
	check(typeof(payload.body_zone) == TYPE_STRING and typeof(payload.treatment) == TYPE_STRING, "quick-heal emits codec string types")
	var before := _quantity(1, ZerkovInventoryCatalog.ITEM_BANDAGE)
	check(payload.treatment == "bandage", "heavy bleeding takes priority")
	var stale := payload.duplicate()
	stale.expected_health_revision += 1
	var rejection := _submit(&"quick_heal", stale, _enemy_router)
	if not _tick(): return false
	check(not _receipt(rejection).committed and _receipt(rejection).terminal, "stale treatment rejects in health authority")
	check(_quantity(1, ZerkovInventoryCatalog.ITEM_BANDAGE) == before, "stale treatment cannot consume inventory")
	enemy_frame = _session.execution.frame_for(_enemy.canonical_key())
	payload = ZCombatInputBinding.payload_for(&"quick_heal", enemy_frame)
	stale = payload.duplicate()
	stale.expected_inventory_revision += 1
	rejection = _submit(&"quick_heal", stale, _enemy_router)
	if not _tick(): return false
	check(not _receipt(rejection).committed and _receipt(rejection).terminal, "stale inventory treatment rejects independently")
	check(_quantity(1, ZerkovInventoryCatalog.ITEM_BANDAGE) == before, "stale inventory treatment cannot consume inventory")
	# Treat each actual injury, including fractures, through production selection.
	# This avoids mistaking later periodic bleed for damage from a missed swing.
	var treated: int = 0
	for attempt in range(14):
		enemy_frame = _session.execution.frame_for(_enemy.canonical_key())
		payload = ZCombatInputBinding.payload_for(&"quick_heal", enemy_frame)
		if payload.is_empty(): break
		var definition: StringName = ZerkovInventoryCatalog.ITEM_BANDAGE if payload.treatment == "bandage" else ZerkovInventoryCatalog.ITEM_SPLINT
		var quantity_before := _quantity(1, definition)
		var heal := _submit(&"quick_heal", payload, _enemy_router)
		if not _tick(): return false
		check(_receipt(heal).committed and _receipt(heal).terminal, "production quick-heal commits through native health and inventory")
		check(_quantity(1, definition) == quantity_before - 1, "medical item consumed exactly once")
		enemy_frame = _session.execution.frame_for(_enemy.canonical_key())
		for zone: Dictionary in enemy_frame.health.body_parts:
			if String(zone.zone_identifier) == payload.body_zone:
				check(not bool(zone.heavy_bleed if payload.treatment == "bandage" else zone.fractured), "selected real injury removed")
		treated += 1
	check(treated > 0 and ZCombatInputBinding.payload_for(&"quick_heal", enemy_frame).is_empty(), "all real injuries treated without direct state writes")
	if failures == 0: print("NATIVE_COMBAT_EXECUTION_STAGE quick_heal_native_commit_passed")
	return failures == 0

func _test_miss_and_duplicate() -> bool:
	# Rotate through admitted aim, not by writing canonical transforms.
	var aim := _submit(&"aim", ZCombatInputBinding.payload_for(&"aim", _frame(), Vector2.LEFT, true))
	if not _tick(): return false
	check(_receipt(aim).committed, "aim executes before pose publication")
	var before := _total_hp(_session.health.actor_snapshot(_enemy))
	var stamina: int = _frame().health.stamina_micros
	var swing := _submit(&"melee", ZCombatInputBinding.payload_for(&"melee", _frame()))
	var duplicate := _router.submit_action(&"melee", ZCombatInputBinding.payload_for(&"melee", _frame()),
		_raid.last_processed_tick + 1, 1, ZRequestId.parse(String(swing.get("request_id", ""))))
	check(duplicate.get("admitted") == false and duplicate.get("reason") == &"duplicate_request", "duplicate swing request rejected before execution")
	if not _tick(): return false
	var ready_tick: int = _frame().melee.swing.ready_tick
	while _raid.last_processed_tick < ready_tick:
		if not _tick(): return false
	check(_total_hp(_session.health.actor_snapshot(_enemy)) == before, "swing away cannot fabricate contact")
	check(not _frame().melee.contact_committed, "miss remains a miss")
	check(_frame().health.stamina_micros == stamina - ZerkovCombatContent.MACHETE_STAMINA_COST_MICROUNITS, "miss and duplicate spend only one swing cost")
	if failures == 0: print("NATIVE_COMBAT_EXECUTION_STAGE miss_duplicate_passed")
	return failures == 0

func _watchdog() -> void:
	push_error("NATIVE_COMBAT_EXECUTION: contract aborted or timed out before completion")
	quit(1)
