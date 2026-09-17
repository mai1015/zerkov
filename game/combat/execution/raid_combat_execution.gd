class_name RaidCombatExecution
extends RefCounted
## Tasks 5.7-5.10: consumes admitted intents and composes EXISTING canonical
## weapon, inventory, spatial and GAS owners. No replacement simulation/clock.
## Configure before the firearm adapter seals the world's transient bearer.
signal frame_published(frame: Dictionary)

const COMMANDS: StringName = &"combat_execution_commands"
const CONTACTS: StringName = &"combat_melee_contacts"
const DUE: StringName = &"combat_execution_due"
const PUBLISH: StringName = &"combat_execution_publish"
const MAX_ACTORS: int = 16
const RECEIPT_TICKS: int = 120
var last_error: StringName = &""
var _raid: RaidAuthority
var _weapons: WeaponAuthority
var _fire: WeaponCombatAdapter
var _health: HealthConsequenceAdapter
var _world: BodyHitboxWorld2D
var _generation: int = 0
var _admission: ZSessionAdmission
var _registrations: Dictionary = {}
var _actors: Dictionary = {}
var _poses: Dictionary = {}
var _pending_starts: Dictionary = {}
var _pending: Dictionary = {}
var _receipts: Dictionary = {}
var _contact_records: Dictionary = {}
var _frames: Dictionary = {}
var _noise: Array[Dictionary] = []
var _feedback: Array[Dictionary] = []
var _inside: bool = false
var _released: bool = false
var _tick: int = 0
var _contact_phase_entries: int = 0
var _contact_idle_skips: int = 0
var _contact_actor_advances: int = 0
var _due_phase_entries: int = 0
var _due_idle_skips: int = 0
var _reload_due_scans: int = 0

func bind(raid: RaidAuthority, weapons: WeaponAuthority, fire: WeaponCombatAdapter,
	health: HealthConsequenceAdapter, world: BodyHitboxWorld2D, capability: Variant,
	generation: int, context_handlers: PackedStringArray = PackedStringArray()) -> bool:
	if _generation != 0 or raid == null or weapons == null or fire == null or health == null or world == null \
		or raid.lifecycle != RaidAuthority.Lifecycle.PREPARING or raid.generation() != generation \
		or not weapons.is_ready() or not health.is_bound():
		return _fail(&"combat_execution_binding_invalid")
	var provenance := world.binding_provenance(capability)
	if provenance.get("authority_generation") != generation or provenance.get("authority_instance_id") != raid.get_instance_id():
		return _fail(&"combat_execution_world_mismatch")
	_raid = raid
	_weapons = weapons
	_fire = fire
	_health = health
	_world = world
	_generation = generation
	_admission = raid.admission()
	var rows: Array = [
		[RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS, COMMANDS, Callable(self, "_commands"), 150, context_handlers],
		[RaidAuthority.TickPhase.WORLD_CONSEQUENCES, CONTACTS, Callable(self, "_contacts"), 200, PackedStringArray()],
		[RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK, DUE, Callable(self, "_due"), 50, PackedStringArray([HealthConsequenceAdapter.PHASE_HANDLER_ID])],
		[RaidAuthority.TickPhase.PUBLISH_PROJECTIONS, PUBLISH, Callable(self, "_publish"), 0, PackedStringArray()],
	]
	for row: Array in rows:
		var registered: bool = raid.register_phase_handler(
			row[0], row[1], row[2], generation, row[3], row[4]) \
			if row[1] == COMMANDS else raid.register_phase_handler_without_intents(
				row[0], row[1], row[2], generation, row[3], row[4])
		if not registered:
			last_error = raid.last_error
			_rollback_handlers()
			return false
		_registrations[row[1]] = raid.phase_handler_registration_id(row[1], generation)
	if not world.authorize_melee_consumer(capability, CONTACTS, _registrations[CONTACTS], Callable(self, "_contacts")) \
		or not health.bind_melee_executor(self, _registrations[DUE]):
		last_error = &"combat_execution_grant_failed"
		_rollback_handlers()
		return false
	return true

## Inventory and health actors must already exist. Mutation owners stay in the
## root, never in HUD/controllers/brains. A mutant uses an explicit natural ID.
func register_actor(actor_id: ZEntityId, source: ZRaidIntent.Source,
	owner: RaidInventoryOwner, reconciler: EquippedItemReconciler,
	context: WeaponInstanceContextAdapter, reload: InventoryWeaponAdapter,
	natural_melee: bool = false) -> bool:
	if _inside or _released or _raid == null or _raid.lifecycle != RaidAuthority.Lifecycle.PREPARING \
		or actor_id == null or _actors.size() >= MAX_ACTORS or _actors.has(actor_id.canonical_key()) \
		or not _raid.has_authorized_actor_source(actor_id, source, _generation) \
		or _health.actor_snapshot(actor_id).is_empty():
		return _fail(&"combat_actor_registration_invalid")
	if not natural_melee and (owner == null or reconciler == null or context == null or reload == null \
		or not owner.is_current_generation(owner.generation()) or not reconciler.is_bound() \
		or not context.authenticates_combat_binding(_raid, _weapons, actor_id, source, context.binding_generation()) \
		or not reload.is_bound()):
		return _fail(&"combat_actor_dependencies_invalid")
	if natural_melee and source != ZRaidIntent.Source.AI:
		return _fail(&"natural_melee_source_invalid")
	_actors[actor_id.canonical_key()] = {"id": ZEntityId.parse(actor_id.canonical_key()), "source": int(source),
		"owner": owner, "owner_generation": owner.generation() if owner != null else 0,
		"reconciler": reconciler, "context": context, "reload": reload,
		"natural_melee": natural_melee, "timeline": ZMeleeTimeline.new(),
		"melee_weapon_id": "", "equipment_revision": -1, "started_tick": 0}
	return true

func _current(raid: RaidAuthority, phase: int, tick: int, id: StringName, callback: Callable) -> bool:
	return not _released and not _inside and raid == _raid and _raid.generation() == _generation \
		and _registrations.has(id) and _raid.is_dispatching_phase_registration(
			id, _registrations[id], callback, phase, tick, _generation)

func _commands(raid: RaidAuthority, phase: int, tick: int, intents: Array[ZRaidIntent]) -> bool:
	if not _current(raid, phase, tick, COMMANDS, Callable(self, "_commands")):
		return _fail(&"combat_commands_phase_invalid")
	_inside = true
	_tick = tick
	_noise.clear()
	_feedback.clear()
	_poses.clear()
	for key: String in _sorted_actors():
		var actor: Dictionary = _actors[key]
		var facts := _raid.authoritative_weapon_actor_context(actor.id, tick, _generation)
		if facts.get("ok") != true:
			_inside = false
			return _fail(&"combat_actor_pose_missing")
		var p: Dictionary = facts.authoritative_origin
		var a: Dictionary = facts.authoritative_aim
		_poses[key] = {"origin_raw": Vector2i(int(p.x) * 1000, int(p.y) * 1000),
			"aim_raw": Vector2i(int(a.x), int(a.y)), "alive": bool(facts.actor_live)}
	for intent: ZRaidIntent in intents:
		if intent == null or not String(intent.kind).begins_with("combat_"): continue
		var key := intent.actor_id.canonical_key()
		if not _actors.has(key) or _actors[key].source != int(intent.source):
			_set_receipt(intent, false, true, &"combat_actor_not_registered")
			continue
		var error := ZCombatActionCodec.validate_intent(intent)
		if not error.is_empty():
			_set_receipt(intent, false, true, error)
			continue
		if not _execute(_actors[key], intent, tick):
			_inside = false
			return false
	_inside = false
	return true

func _execute(actor: Dictionary, intent: ZRaidIntent, tick: int) -> bool:
	var key := intent.actor_id.canonical_key()
	var kind := ZCombatActionCodec.action_for_intent(intent.kind)
	var payload := intent.payload
	var health := _health.actor_snapshot(actor.id)
	if health.is_empty() or not health.alive:
		_set_receipt(intent, false, true, &"actor_dead")
		return true
	if kind == &"aim":
		_set_receipt(intent, true, true, &"")
		return true # Locomotion already resolved facing BEFORE pose publication.
	if kind == &"quick_heal":
		var request := {"schema": HealthConsequenceAdapter.TREATMENT_REQUEST_SCHEMA,
			"request_id": intent.request_id.canonical_key(), "actor_id": key,
			"actor_registration_generation": health.actor_registration_generation,
			"adapter_generation": _health.binding_generation(), "authority_epoch": _admission.authority_epoch,
			"authority_generation": _generation, "body_zone": payload.body_zone,
			"expected_health_revision": payload.expected_health_revision,
			"expected_inventory_revision": payload.expected_inventory_revision,
			"raid_id": _admission.raid_id.canonical_key(), "session_id": _admission.session_id.canonical_key(),
			"sequence": intent.sequence, "target_tick": tick, "treatment": payload.treatment}
		var result := _health.queue_treatment(request)
		if result.get("requires_recovery", false): return _fail(&"combat_treatment_recovery")
		if result.get("accepted", false):
			_pending[intent.request_id.canonical_key()] = {"intent": intent.snapshot(), "kind": kind, "tick": tick}
		_set_receipt(intent, bool(result.get("accepted", false)), not bool(result.get("queued", false)), result.get("reason", &""))
		return true
	if kind == &"melee":
		var melee := _melee_equipment(actor)
		if melee.is_empty() or melee.weapon_id != payload.weapon_id or melee.revision != payload.expected_equipment_revision:
			_set_receipt(intent, false, true, &"melee_equipment_stale")
		elif _pending_starts.has(key) or not actor.timeline.can_start(tick):
			_set_receipt(intent, false, true, &"melee_busy")
		elif _weapon_reloading(actor):
			_set_receipt(intent, false, true, &"weapon_reloading")
		else:
			_pending_starts[key] = intent.snapshot()
			_set_receipt(intent, true, false, &"")
		return true
	if not actor.timeline.can_start(tick) or _pending_starts.has(key):
		_set_receipt(intent, false, true, &"melee_busy")
		return true
	var record := _weapon_record(actor, String(payload.weapon_id))
	var snapshot := _weapons.snapshot(String(payload.weapon_id))
	if record.is_empty() or snapshot.is_empty():
		_set_receipt(intent, false, true, &"weapon_not_equipped")
		return true
	if snapshot.get("revision") != payload.expected_weapon_revision:
		_set_receipt(intent, false, true, &"weapon_revision_stale")
		return true
	if kind == &"fire":
		var seed := (intent.request_id.canonical_key() + ":" + str(_raid.rng.state)).sha256_text().substr(0, 8).hex_to_int()
		var command_id := "fire_" + intent.request_id.canonical_key().sha256_text()
		var sequence := maxi(int(snapshot.get("last_command_sequence", 0)), int(snapshot.get("admitted_sequence_high_watermark", 0))) + 1
		var result := _fire.commit_fire(command_id, sequence, payload.weapon_id, payload.expected_weapon_revision,
			tick, seed, actor.id, actor.source)
		if _fire.lifecycle != WeaponCombatAdapter.Lifecycle.BOUND or not _fire.last_error.is_empty() and result.get("accepted", false):
			return _fail(&"combat_fire_invariant_failure")
		if result.get("accepted", false):
			_pending[intent.request_id.canonical_key()] = {"intent": intent.snapshot(), "kind": kind,
				"shot": result.shot_identity, "tick": tick}
		else:
			_set_receipt(intent, false, true, result.get("reason", &"weapon_rejected"), result.get("rejection", 0))
		return true
	var reload := actor.reload as InventoryWeaponAdapter
	var request := {"request_id": intent.request_id.canonical_key(), "weapon_id": payload.weapon_id,
		"weapon_binding_generation": record.weapon_binding_generation,
		"adapter_generation": reload.adapter_generation(), "authority_epoch": _admission.authority_epoch,
		"inventory_id": reload.inventory_id(), "expected_weapon_revision": payload.expected_weapon_revision, "tick": tick}
	var result: Dictionary = {}
	if kind == &"reload":
		request["expected_inventory_revision"] = payload.expected_inventory_revision
		result = reload.begin_reload(request)
		if result.get("accepted", false):
			_pending[intent.request_id.canonical_key()] = {"intent": intent.snapshot(), "kind": kind,
				"reservation": result.get("reservation_id", ""), "tick": tick}
		_set_receipt(intent, bool(result.get("accepted", false)), not bool(result.get("accepted", false)), result.get("reason", &""))
	elif kind == &"cancel_reload":
		if snapshot.get("reload", {}).get("reservation_id", "") != payload.reservation_id:
			_set_receipt(intent, false, true, &"reload_reservation_stale")
			return true
		request["reason"] = &"input_cancel"
		result = reload.cancel_reload(request)
		_set_receipt(intent, bool(result.get("accepted", false)), true, result.get("reason", &""))
	if reload.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED:
		return _fail(&"combat_reload_recovery")
	return true

func _contacts(raid: RaidAuthority, phase: int, tick: int, _intents: Array[ZRaidIntent]) -> bool:
	if not _current(raid, phase, tick, CONTACTS, Callable(self, "_contacts")):
		return _fail(&"combat_contact_phase_invalid")
	_contact_phase_entries += 1
	if not _has_active_melee_work(tick):
		_contact_idle_skips += 1
		return true
	_inside = true
	for key: String in _sorted_actors():
		var actor: Dictionary = _actors[key]
		if not (actor.timeline as ZMeleeTimeline).has_active_work(tick):
			continue
		_contact_actor_advances += 1
		var equipment := _melee_equipment(actor)
		var health := _health.actor_snapshot(actor.id)
		var usable: bool = health.get("alive", false) and not equipment.is_empty() \
			and equipment.weapon_id == actor.melee_weapon_id and equipment.revision == actor.equipment_revision
		var state: Dictionary = actor.timeline.advance(tick, usable)
		if not state.ok:
			_inside = false
			return _fail(&"melee_timeline_invalid")
		if state.query_contact and not _resolve_contact(actor, state.swing, tick):
			_inside = false
			return false
	_inside = false
	return true

func _resolve_contact(actor: Dictionary, swing: Dictionary, tick: int) -> bool:
	var pose: Dictionary = _poses[actor.id.canonical_key()]
	var metadata := _world.melee_snapshot_metadata(CONTACTS, _registrations[CONTACTS], Callable(self, "_contacts"), tick)
	if metadata.get("tick") != tick: return _fail(&"melee_world_snapshot_stale")
	var origin: Vector2i = pose.origin_raw
	var aim: Vector2i = swing.aim_raw
	var reach: int = swing.definition.reach_raw
	# Weapon aim is a fixed unit vector. Keep all endpoint arithmetic in int64.
	@warning_ignore("integer_division")
	var x: int = int(origin.x) + int(aim.x) * reach / ZWorldUnits.WEAPON_DIRECTION_SCALE
	@warning_ignore("integer_division")
	var y: int = int(origin.y) + int(aim.y) * reach / ZWorldUnits.WEAPON_DIRECTION_SCALE
	if absi(x) > BodyHitboxWorld2D.MAX_COORDINATE_RAW or absi(y) > BodyHitboxWorld2D.MAX_COORDINATE_RAW:
		return _fail(&"melee_endpoint_out_of_bounds")
	var hash := (String(swing.request_id) + ":" + str(tick)).sha256_text()
	var request_id := ZRequestId.from_parts(PackedStringArray(["melee", hash.substr(0, 32), hash.substr(32)]))
	var event_id := ZConsequenceId.from_parts(PackedStringArray(["melee", hash.substr(0, 32), hash.substr(32)]))
	if not _raid.can_record_event(ZRaidEvent.EventKind.HIT, event_id, tick, actor.id, {}, _generation):
		return _fail(_raid.last_error)
	var query := {"request_id": request_id.canonical_key(), "raid_id": _admission.raid_id.canonical_key(),
		"session_id": _admission.session_id.canonical_key(), "authority_epoch": _admission.authority_epoch,
		"authority_generation": _generation, "binding_token": metadata.binding_token,
		"owner_actor_id": _admission.actor_id.canonical_key(), "owner_actor_source": int(ZRaidIntent.Source.PLAYER),
		"query_actor_id": actor.id.canonical_key(), "query_actor_source": actor.source,
		"tick": tick, "world_revision": metadata.world_revision, "origin_raw": origin, "target_raw": Vector2i(x, y),
		"body_mask": 1, "obstruction_mask": 2, "excluded_entity_ids": [actor.id.canonical_key()]}
	var result := _world.phase_melee_sweep(query, int(swing.definition.radius_raw), CONTACTS,
		_registrations[CONTACTS], Callable(self, "_contacts"))
	if result.get("accepted") != true or result.get("duplicate", false): return _fail(&"melee_world_query_failed")
	if not result.hit and not result.blocked and tick + 1 < int(swing.recovery_tick):
		return true # Still in the active window; no hit is invented.
	var payload := {"schema": HealthConsequenceAdapter.MELEE_CONSEQUENCE_SCHEMA,
		"raid_id": _admission.raid_id.canonical_key(), "session_id": _admission.session_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch, "authority_generation": _generation,
		"consequence_id": event_id.canonical_key(), "request_id": swing.request_id,
		"actor_id": actor.id.canonical_key(), "actor_source": actor.source, "tick": tick,
		"start_tick": swing.start_tick, "definition_id": swing.definition.id,
		"damage_milliunits": swing.definition.damage_milliunits, "hit": result.hit, "blocked": result.blocked,
		"entity_id": result.entity_id, "body_zone": result.body_zone, "world_revision": result.world_revision,
		"world_resolution_digest": result.resolution_digest}
	payload["resolution_digest"] = ZCanonicalValue.sha256(payload)
	if not _raid.record_event(ZRaidEvent.EventKind.HIT, event_id, tick, actor.id, payload, _generation):
		return _fail(_raid.last_error)
	_contact_records[event_id.canonical_key()] = {"tick": tick, "digest": payload.resolution_digest}
	if result.hit or result.blocked:
		if not actor.timeline.mark_contact(tick): return _fail(&"melee_contact_commit_failed")
	_feedback.append({"id": event_id.canonical_key(), "kind": &"melee_contact", "actor_id": actor.id.canonical_key(),
		"hit": result.hit, "blocked": result.blocked, "tick": tick})
	return true

## Consumed by health during its exact phase; only this executor's just-recorded
## consequences may use its cost admission. No private native/world handle leaves.
func has_contact(event_id: String, digest: String) -> bool:
	return _contact_records.get(event_id, {}).get("digest", "") == digest and not digest.is_empty()

func _due(raid: RaidAuthority, phase: int, tick: int, _intents: Array[ZRaidIntent]) -> bool:
	if not _current(raid, phase, tick, DUE, Callable(self, "_due")):
		return _fail(&"combat_due_phase_invalid")
	_due_phase_entries += 1
	if _pending_starts.is_empty() and _pending.is_empty() \
			and not _has_pending_reload_work():
		_due_idle_skips += 1
		return true
	_inside = true
	for key: String in _sorted_actors():
		var actor: Dictionary = _actors[key]
		var reload := actor.reload as InventoryWeaponAdapter
		if reload != null and reload.pending_reload_count() > 0:
			_reload_due_scans += 1
			var outcomes := reload.advance_due_reloads(tick)
			for result: Dictionary in outcomes:
				if result.get("requires_recovery", false) or reload.lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED:
					_inside = false
					return _fail(&"combat_reload_completion_failed")
				if result.get("kind") == &"reload_committed":
					for request_id: String in _pending.keys():
						var pending: Dictionary = _pending[request_id]
						if pending.kind == &"reload" and pending.reservation == result.get("reservation_id"):
							_set_receipt(pending.intent, true, true, &"")
							_pending.erase(request_id)
		if not _pending_starts.has(key): continue
		var intent: ZRaidIntent = _pending_starts[key]
		var equipment := _melee_equipment(actor)
		if equipment.is_empty() or equipment.weapon_id != intent.payload.weapon_id or equipment.revision != intent.payload.expected_equipment_revision:
			_set_receipt(intent, false, true, &"melee_equipment_changed_before_cost")
			continue
		var archetype: StringName = &"mutant" if actor.natural_melee else &"machete"
		var cost := _health.commit_melee_start(self, actor.id, intent.request_id, archetype, tick)
		if cost.get("requires_recovery", false):
			_inside = false
			return _fail(&"combat_melee_cost_recovery")
		if cost.get("accepted", false):
			if not actor.timeline.start(intent.request_id.canonical_key(), tick, ZMeleePolicy.definition(archetype), _poses[key].aim_raw):
				_inside = false
				return _fail(&"melee_start_after_cost_failed")
			actor.melee_weapon_id = equipment.weapon_id
			actor.equipment_revision = equipment.revision
			actor.started_tick = tick
		_set_receipt(intent, bool(cost.get("accepted", false)), true, cost.get("reason", &""))
	_pending_starts.clear()
	# Dead actors have already interrupted reloads in health. No health/resource
	# mutation occurs when completing these admission-to-execution receipts.
	for request_id: String in _pending.keys():
		var pending: Dictionary = _pending[request_id]
		var intent: ZRaidIntent = pending.intent
		if pending.kind == &"fire":
			var result := _fire.resolved_consequence(pending.shot)
			if result.get("accepted") != true:
				_inside = false
				return _fail(&"fire_consequence_missing")
			_set_receipt(intent, true, true, &"")
			var pose: Dictionary = _poses[intent.actor_id.canonical_key()]
			_noise.append({"event_id": result.consequence_id, "source_id": result.actor_id, "tick": tick,
				"position_raw": pose.origin_raw, "category": &"gunshot", "intensity_milli": 1000})
			_feedback.append({"id": result.consequence_id, "kind": &"shot", "actor_id": result.actor_id,
				"hit": result.hit, "blocked": result.blocked, "tick": tick})
			_pending.erase(request_id)
		elif pending.kind == &"quick_heal":
			var result := _health.treatment_receipt(request_id)
			if result.get("terminal", false):
				_set_receipt(intent, bool(result.get("committed", false)), true, result.get("reason", &""))
				_pending.erase(request_id)
		elif pending.kind == &"reload":
			var reloading: bool = false
			for reload_record: Dictionary in _actors[intent.actor_id.canonical_key()].reload.pending_reloads():
				if reload_record.reservation_id == pending.reservation: reloading = true
			if not reloading:
				_set_receipt(intent, false, true, &"reload_interrupted")
				_pending.erase(request_id)
	_inside = false
	return true

func work_counts() -> Dictionary:
	return _frozen({
		"contact_phase_entries": _contact_phase_entries,
		"contact_idle_skips": _contact_idle_skips,
		"contact_actor_advances": _contact_actor_advances,
		"due_phase_entries": _due_phase_entries,
		"due_idle_skips": _due_idle_skips,
		"reload_due_scans": _reload_due_scans,
		"pending_starts": _pending_starts.size(),
		"pending_actions": _pending.size(),
	})


func _has_active_melee_work(tick: int) -> bool:
	for actor_value in _actors.values():
		var actor := actor_value as Dictionary
		if (actor.timeline as ZMeleeTimeline).has_active_work(tick):
			return true
	return false


func _has_pending_reload_work() -> bool:
	for actor_value in _actors.values():
		var reload := (actor_value as Dictionary).reload as InventoryWeaponAdapter
		if reload != null and reload.pending_reload_count() > 0:
			return true
	return false


func _publish(raid: RaidAuthority, phase: int, tick: int, _intents: Array[ZRaidIntent]) -> bool:
	if not _current(raid, phase, tick, PUBLISH, Callable(self, "_publish")):
		return _fail(&"combat_publish_phase_invalid")
	_inside = true
	for id: String in _receipts.keys():
		if _receipts[id].terminal and tick - int(_receipts[id].resolved_tick) > RECEIPT_TICKS: _receipts.erase(id)
	for id: String in _contact_records.keys():
		if tick - int(_contact_records[id].tick) > RECEIPT_TICKS: _contact_records.erase(id)
	for key: String in _sorted_actors():
		var actor: Dictionary = _actors[key]
		var health := _health.actor_snapshot(actor.id)
		var weapon := _primary_snapshot(actor)
		var equipment := _melee_equipment(actor)
		var receipts: Array = []
		for id: String in _receipts:
			if _receipts[id].actor_id == key and int(_receipts[id].resolved_tick) == tick:
				receipts.append(_receipts[id])
		receipts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.request_id < b.request_id)
		var feedback: Array = []
		for event: Dictionary in _feedback:
			if event.actor_id == key:
				var published := event.duplicate(true)
				var damage := _health.damage_result(String(event.id))
				published["damage_confirmed"] = damage.get("committed", false) and int(damage.get("applied_damage_micros", 0)) > 0
				published["kill_confirmed"] = published.damage_confirmed and damage.get("dead", false)
				feedback.append(published)
		var frame := {"schema": "zerkov.combat.frame.v1", "actor_id": key, "generation": _generation,
			"tick": tick, "available": not health.is_empty(), "health": health, "weapon": weapon,
			"inventory_revision": _inventory_revision(actor), "reserve_rounds": _reserve_rounds(actor),
			"melee_equipment": equipment, "melee": actor.timeline.snapshot(tick),
			"receipts": receipts, "feedback": feedback}
		_frames[key] = _frozen(frame)
		frame_published.emit(_frames[key])
	_inside = false
	return true

func _set_receipt(intent: ZRaidIntent, accepted: bool, terminal: bool, reason: StringName, code: int = 0) -> void:
	var key := intent.request_id.canonical_key()
	_receipts[key] = _frozen({"request_id": key, "actor_id": intent.actor_id.canonical_key(),
		"generation": _generation, "kind": ZCombatActionCodec.action_for_intent(intent.kind),
		"target_tick": intent.target_tick, "resolved_tick": _tick,
		"accepted": accepted, "terminal": terminal, "committed": accepted and terminal,
		"reason": reason, "code": code})

func receipt(request_id: String) -> Dictionary:
	return _frozen(_receipts.get(request_id, {}))

func frame_for(actor_id: String) -> Dictionary:
	return _frames.get(actor_id, _frozen({}))

func committed_noise(tick: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if tick == _tick and not _released:
		for event in _noise: result.append(_frozen(event))
	result.make_read_only()
	return result

func _weapon_record(actor: Dictionary, weapon_id: String) -> Dictionary:
	var context := actor.context as WeaponInstanceContextAdapter
	if context == null or not context.is_bound(): return {}
	for record in context.instance_records():
		if record.get("weapon_id") == weapon_id and record.get("equipped", false) and not record.get("parked", true):
			return record
	return {}

func _primary_snapshot(actor: Dictionary) -> Dictionary:
	var context := actor.context as WeaponInstanceContextAdapter
	if context == null or not context.is_bound(): return {}
	for record in context.instance_records():
		if record.get("equipped", false) and not record.get("parked", true):
			return _weapons.snapshot(String(record.weapon_id))
	return {}

func _weapon_reloading(actor: Dictionary) -> bool:
	return _primary_snapshot(actor).get("phase") == "reloading"

func _melee_equipment(actor: Dictionary) -> Dictionary:
	if actor.natural_melee:
		return {"weapon_id": "zerkov.weapon.mutant.claw", "revision": 0, "definition_id": "zerkov.attack.mutant.claw"}
	var reconciler := actor.reconciler as EquippedItemReconciler
	if reconciler == null or not reconciler.is_bound(): return {}
	var mapping := reconciler.mapping_for_slot(EquippedItemReconciler.SLOT_MELEE)
	if mapping.get("combat_definition_identifier") != ZerkovCombatContent.WEAPON_MACHETE: return {}
	return {"weapon_id": mapping.weapon_id, "revision": reconciler.current_revision(),
		"definition_id": String(ZerkovCombatContent.WEAPON_MACHETE)}

func _inventory_revision(actor: Dictionary) -> int:
	var owner := actor.owner as RaidInventoryOwner
	if owner == null or not owner.is_current_generation(int(actor.owner_generation)): return 0
	return maxi(0, owner.raid_authority().inventory_revision(
		owner.raid_player_inventory_id))

func _reserve_rounds(actor: Dictionary) -> int:
	var reload := actor.reload as InventoryWeaponAdapter
	return reload.available_rounds() if reload != null else 0

func _sorted_actors() -> Array:
	var keys := _actors.keys()
	keys.sort()
	return keys

func release() -> bool:
	if _inside: return _fail(&"combat_release_during_dispatch")
	if _released: return true
	if not _rollback_handlers(): return false
	_released = true
	for actor: Dictionary in _actors.values(): actor.timeline.clear()
	_pending_starts.clear()
	_pending.clear()
	_frames.clear()
	_noise.clear()
	_actors.clear()
	return true

func _rollback_handlers() -> bool:
	for id: StringName in [PUBLISH, DUE, CONTACTS, COMMANDS]:
		if _registrations.has(id) and _raid != null and _raid.has_phase_handler(id, _generation):
			if not _raid.unregister_phase_handler(id, _generation): return _fail(_raid.last_error)
		_registrations.erase(id)
	return true

static func _frozen(value: Dictionary) -> Dictionary:
	var copy := value.duplicate(true)
	ZMeleeTimeline._freeze(copy)
	return copy

func _fail(reason: StringName) -> bool:
	last_error = reason
	return false
