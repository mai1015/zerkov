extends "res://tests/combat/native_combat_execution_contract.gd"
## Task 5.10: full composition death races. All lethal events originate from
## admitted native firearm commands; no direct health/tag/snapshot writes.
var scenarios: int = 0

func run() -> void:
	create_timer(90.0).timeout.connect(_watchdog)
	for scenario: String in ["queued_start", "windup", "active_contact", "reload_due"]:
		if not await _setup(): break
		if not _arm_enemy(): break
		var ok: bool = _death_during_reload() if scenario == "reload_due" else _death_during_melee(scenario)
		if ok: ok = _reject_dead_actions()
		if not ok: break
		scenarios += 1
		print("NATIVE_COMBAT_DEATH_STAGE ", scenario, " passed")
		await _reset_fixture()
	if _session != null: await _reset_fixture()
	check(scenarios == 4, "all native death scenarios executed to completion")
	print("NATIVE_COMBAT_DEATH_RESULT checks=", checks, " failures=", failures, " scenarios=", scenarios)
	quit(0 if failures == 0 else 1)

func _reset_fixture() -> void:
	await _cleanup()
	_session = null
	_raid = null
	_owners.clear()
	_moves.clear()
	_router = null
	_enemy_router = null
	_model = null

func _arm_enemy() -> bool:
	var frame: Dictionary = _session.execution.frame_for(_enemy.canonical_key())
	var reload: Dictionary = _submit(&"reload", ZCombatInputBinding.payload_for(&"reload", frame), _enemy_router)
	var aim: Dictionary = _submit(&"aim", ZCombatInputBinding.payload_for(&"aim", frame, Vector2.LEFT, true), _enemy_router)
	if not _tick(): return false
	for _i in range(ZerkovCombatContent.AKM_RELOAD_TICKS):
		if not _tick(): return false
	check(_receipt(reload).committed and _receipt(aim).committed, "enemy reload and aim are actual committed actions")
	check(_frame().health.alive, "player alive before race")
	return failures == 0

func _lethal_shot() -> Dictionary:
	var frame: Dictionary = _session.execution.frame_for(_enemy.canonical_key())
	# Player faces east; the shot arrives at the front/head hitbox from the east.
	return _submit(&"fire", ZCombatInputBinding.payload_for(&"fire", frame, Vector2.LEFT, true), _enemy_router)

func _death_during_melee(scenario: String) -> bool:
	var enemy_hp: int = _total_hp(_session.health.actor_snapshot(_enemy))
	var stamina: int = _frame().health.stamina_micros
	var swing: Dictionary = _submit(&"melee", ZCombatInputBinding.payload_for(&"melee", _frame()))
	var shot: Dictionary
	if scenario == "queued_start":
		shot = _lethal_shot()
	else:
		if not _tick(): return false
		check(_receipt(swing).committed and _frame().melee.phase == &"windup", "swing started before lethal tick")
		check(_frame().health.stamina_micros == stamina - ZerkovCombatContent.MACHETE_STAMINA_COST_MICROUNITS, "one authoritative startup cost")
		if scenario == "active_contact":
			var active_tick: int = _frame().melee.swing.active_tick
			while _raid.last_processed_tick < active_tick - 1:
				if not _tick(): return false
		shot = _lethal_shot()
	if not _tick(): return false
	check(_receipt(shot).committed and not _frame().health.alive, "native headshot kills player at scheduled tick")
	check(_total_hp(_session.health.actor_snapshot(_enemy)) == enemy_hp, "dead attacker's melee cannot damage shooter")
	var expected: int = stamina if scenario == "queued_start" else stamina - ZerkovCombatContent.MACHETE_STAMINA_COST_MICROUNITS
	check(_frame().health.stamina_micros == expected, "lethal tick neither adds nor repeats stamina cost")
	if scenario == "queued_start":
		check(_receipt(swing).terminal and not _receipt(swing).committed and _receipt(swing).reason == &"health_actor_dead", "queued melee startup is rejected after same-tick lethal damage")
	elif scenario == "active_contact":
		# A real swept contact exists, but health explicitly suppresses its outcome.
		check(_frame().melee.contact_committed, "same-tick test actually reached contact, not an aim-away miss")
	var death_tick: int = _raid.last_processed_tick
	for _i in range(ZMeleePolicy.MACHETE_WINDUP + 8):
		if not _tick(): return false
		check(_total_hp(_session.health.actor_snapshot(_enemy)) == enemy_hp, "no delayed corpse damage")
		check(_frame().health.stamina_micros == expected, "no delayed corpse stamina spend")
	if scenario != "queued_start": check(_frame().melee.interrupted, "death interrupts retained swing timeline")
	var deaths: int = 0
	for event: Dictionary in _raid.journal.records():
		if String(event.get("kind", "")) == "death" and int(event.get("tick", -1)) == death_tick:
			deaths += 1
	check(deaths == 1, "one death audit event, no duplicate on later ticks")
	return failures == 0

func _death_during_reload() -> bool:
	var begin: Dictionary = _submit(&"reload", _reload_payload())
	if not _tick(): return false
	check(_frame().weapon.phase == "reloading", "real player reservation active")
	var due: int = _raid.last_processed_tick + ZerkovCombatContent.AKM_RELOAD_TICKS
	while _raid.last_processed_tick < due - 1:
		if not _tick(): return false
	var shot: Dictionary = _lethal_shot()
	if not _tick(): return false
	check(_receipt(shot).committed and not _frame().health.alive, "lethal hit coincides with reload due tick")
	check(_receipt(begin).terminal and not _receipt(begin).committed and _receipt(begin).reason == &"reload_interrupted", "death wins over due reload and terminalizes receipt")
	check(_frame().weapon.loaded_rounds == 0 and _frame().reserve_rounds == 60, "all 60 rounds conserved, reservation released")
	for _i in range(12):
		if not _tick(): return false
		check(_frame().weapon.loaded_rounds == 0 and _frame().reserve_rounds == 60, "no late reload commit or duplicate refund")
	return failures == 0

func _reject_dead_actions() -> bool:
	var before: Dictionary = _frame()
	var enemy_hp: int = _total_hp(_session.health.actor_snapshot(_enemy))
	var bandages: int = _quantity(0, ZerkovInventoryCatalog.ITEM_BANDAGE)
	var actions: Array[Dictionary] = []
	for kind: StringName in [&"fire", &"reload", &"melee"]:
		actions.append(_submit(kind, ZCombatInputBinding.payload_for(kind, before)))
	actions.append(_submit(&"quick_heal", {"body_zone":String(ZerkovHealthAbilityContent.ZONE_HEAD), "treatment":"bandage",
		"expected_health_revision":before.health.health_revision, "expected_inventory_revision":before.inventory_revision}))
	if not _tick(): return false
	for request: Dictionary in actions:
		var result: Dictionary = _receipt(request)
		check(result.terminal and not result.committed and result.reason == &"actor_dead", "admitted dead-actor command rejected by production executor")
	check(_frame().weapon.loaded_rounds == before.weapon.loaded_rounds and _frame().reserve_rounds == before.reserve_rounds, "dead commands preserve ammo")
	check(_frame().health.stamina_micros == before.health.stamina_micros, "dead commands preserve stamina")
	check(_quantity(0, ZerkovInventoryCatalog.ITEM_BANDAGE) == bandages and _total_hp(_session.health.actor_snapshot(_enemy)) == enemy_hp, "dead commands cannot consume medicine or damage anyone")
	return failures == 0
