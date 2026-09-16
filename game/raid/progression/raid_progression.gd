class_name RaidProgression
extends RefCounted
## Existing RaidAuthority owns all ticks/phase changes. Native discovery and
## Level Task consume canonical state, not UI promises. Call after_tick outside
## dispatch, then finish only after a terminal decision. No wall clock involved.
const HANDLER: StringName = &"raid_progression_audit"
var last_error: StringName = &""
var _raid: RaidAuthority
var _owner: RaidInventoryOwner
var _movement: ZPlayerLocomotion
var _settlement_audited: bool = false
var _discovery_released: bool = false
var _combat: RaidCombatSession
var _interaction: ZInteractionPolicyOwner
var _task: SupplyRunTask
var _timer: ExtractionCountdown
var _crates: Dictionary = {}
var _generation: int = 0
var _registration: String = ""
var _recipient: int = 0
var _search: Dictionary = {}
var _searched: Dictionary = {}
var _audit_cursor: int = 0
var _damage_seen: Dictionary = {}
var _stats := {"kills":0,"damage_dealt_micros":0,"damage_received_micros":0,"searched_crates":0,"rejected_inputs":0}
var _frame: Dictionary = {}
var _pending_frame: Dictionary = {}
var _terminal: Dictionary = {}
var _settlement: Dictionary = {}
var _tick: int = 0
var _closed_tick: int = 0
var _countdown_duration: int = 0
var _inside: bool = false
var _released: bool = false
var _combat_released: bool = false

func bind(raid: RaidAuthority, owner: RaidInventoryOwner, combat: RaidCombatSession,
	interaction: ZInteractionPolicyOwner, crates: Dictionary, limit_ticks: int, countdown_ticks: int, movement: ZPlayerLocomotion) -> bool:
	if _generation != 0 or raid == null or owner == null or combat == null or interaction == null \
		or raid.lifecycle != RaidAuthority.Lifecycle.PREPARING or not owner.is_current_generation(owner.generation()) \
		or combat.health == null or not combat.health.is_bound() or crates.size() != 3 \
		or movement == null or movement.actor_id() == null or not movement.actor_id().is_equal(raid.admission().actor_id):
		return _fail(&"progression_binding_invalid")
	var ids: Dictionary = {}
	for key: String in SupplyRunGraph.CRATES:
		if typeof(crates.get(key)) != TYPE_INT or ids.has(crates[key]): return _fail(&"progression_crate_mapping_invalid")
		var snapshot := owner.raid_authority().snapshot(int(crates[key]))
		if snapshot == null or StringName(snapshot.get_profile_identifier()) != ZerkovInventoryCatalog.PROFILE_WORLD_CRATE:
			return _fail(&"progression_crate_profile_invalid")
		ids[crates[key]] = true
	if not raid.has_phase_handler(ZInteractionPolicyOwner.DEFAULT_PHASE_HANDLER_ID,raid.generation()):
		return _fail(&"progression_interaction_owner_missing")
	_timer = ExtractionCountdown.new()
	if not _timer.configure(countdown_ticks,limit_ticks): return _fail(&"progression_timing_invalid")
	_task = SupplyRunTask.new()
	if not _task.configure(raid.raid_id().canonical_key()): return _fail(_task.last_error)
	_raid=raid;_owner=owner;_combat=combat;_interaction=interaction;_crates=crates.duplicate()
	_generation=raid.generation();_countdown_duration=countdown_ticks;_movement=movement
	_recipient = 1 + int(raid.raid_id().canonical_key().sha256_text().substr(0,7).hex_to_int())
	var accepted := owner.raid_authority().register_discovery_recipient(_recipient,_recipient)
	if accepted.get("ok") != true: return _fail(&"progression_discovery_recipient_failed")
	if not raid.register_phase_handler(RaidAuthority.TickPhase.TASKS_AND_AUDIT,HANDLER,
		Callable(self,"_advance"),_generation,200): return _fail(raid.last_error)
	_registration=raid.phase_handler_registration_id(HANDLER,_generation)
	return true

func _advance(raid: RaidAuthority, phase: int, tick: int, intents: Array[ZRaidIntent]) -> bool:
	if _released or _inside or raid != _raid or tick != _tick + 1 or _tick != _closed_tick \
		or not raid.is_dispatching_phase_registration(HANDLER,_registration,Callable(self,"_advance"),phase,tick,_generation):
		return _fail(&"progression_phase_invalid")
	_inside=true
	var ok := _advance_inner(tick,intents)
	_inside=false
	return ok

func _advance_inner(tick: int, intents: Array[ZRaidIntent]) -> bool:
	var actor := _raid.admission().actor_id
	var health := _combat.health.actor_snapshot(actor)
	# Weapon context reads are intentionally restricted to phase 4. Phase 7
	# consumes the local movement owner's already-published same-tick snapshot.
	var pose := _movement.get_snapshot()
	if health.is_empty() or pose.get("last_processed_tick") != tick or not pose.get("pose_published",false) \
		or pose.get("actor_id") != actor.canonical_key(): return _fail(&"progression_actor_state_missing")
	var position: Vector2 = pose.position_px
	if not _interaction.set_actor_position(actor,position,_generation): return _fail(_interaction.last_error)
	var damaged := _consume_audit()
	var cancel: bool = false
	var start: bool = false
	var requested_crate: String = ""
	for intent in intents:
		if intent.kind not in [&"interaction",&"raid_cancel"]: continue
		if not intent.actor_id.is_equal(actor) or intent.source != ZRaidIntent.Source.PLAYER \
			or not RaidGameplayInput.valid_payload(intent.kind,intent.payload):
			_stats.rejected_inputs += 1
			continue
		if intent.kind == &"raid_cancel": cancel=true;continue
		var target: String = intent.payload.target_id
		if target == SupplyRunGraph.ROAD_GATE: start=true
		elif requested_crate.is_empty(): requested_crate=target
	if not _task.update_facts(_holds_objective()): return _fail(_task.last_error)
	var inside := _interaction.evaluate_for_actor(actor,StringName(SupplyRunGraph.ROAD_GATE),ZInteractionKind.EXTRACTION_ZONE,_generation).allowed
	# Health commits earlier in the SAME tick. Deadline/death also stop searches.
	if not health.alive or cancel or damaged or tick >= _timer.snapshot().deadline_tick:
		if not _cancel_search(): return false
	elif not _search.is_empty():
		if not _interaction.evaluate_for_actor(actor,StringName(_search.crate),ZInteractionKind.CRATE,_generation).allowed:
			if not _cancel_search(): return false
		elif not _advance_search(tick): return false
	elif not requested_crate.is_empty() and not _searched.has(requested_crate):
		if _interaction.evaluate_for_actor(actor,StringName(requested_crate),ZInteractionKind.CRATE,_generation).allowed:
			if not _begin_search(requested_crate,tick): return false
		else: _stats.rejected_inputs+=1
	var result := _timer.advance(tick,health.alive,_task.ready_to_extract(),inside,damaged,start,cancel)
	if not result.ok: return _fail(&"progression_timer_failed")
	_tick=tick
	if not String(result.outcome).is_empty():
		if not _cancel_search(): return false
		# Reserve an additional journal slot for the post-commit settlement record.
		if _raid.journal.remaining_capacity() < 2: return _fail(&"progression_terminal_journal_capacity")
		if result.outcome=="extracted":
			if not _task.extracted(SupplyRunGraph.ROAD_GATE): return _fail(_task.last_error)
		elif not _task.fail_raid(_raid.journal.size()+1,tick): return _fail(_task.last_error)
		if not _record(&"terminal",ZRaidEvent.EventKind.EXTRACTION,tick,{"outcome":String(result.outcome),"task":String(_task.snapshot().status)}): return false
		_terminal = {"outcome":String(result.outcome),"tick":tick,"audit_available":true,
			"audit_digest":_raid.journal.digest(),"stats":_stats.duplicate(),"health":_health_record(health),"task":_task.snapshot()}
	_pending_frame=RaidProgressionValues.freeze({"schema":"zerkov.raid.progression.v1","generation":_generation,
		"raid_id":_raid.raid_id().canonical_key(),"tick":tick,"clock":result,"task":_task.snapshot(),
		"searched_ids":_searched.keys(),"searching":_search.get("crate",""),"terminal_pending_settlement":not _terminal.is_empty(),"summary_final":false})
	return true

func _begin_search(crate: String, tick: int) -> bool:
	var native := _owner.raid_authority()
	var inventory_id: int = _crates[crate]
	var view := native.discovery_view(_recipient,_recipient,inventory_id)
	if view==null or view.get_containers().size()!=1: return _fail(&"progression_crate_shell_missing")
	var container: InventoryDiscoveryContainerViewResource = view.get_containers()[0]
	if container.get_stage()!=InventoryDiscoveryContainerViewResource.STAGE_UNSEARCHED:
		return _fail(&"progression_discovery_owner_conflict")
	var result := native.begin_container_search(_recipient,_recipient,inventory_id,container.get_token(),tick,
		view.get_inventory_revision(),view.get_discovery_revision())
	if result==null or not result.is_accepted(): return _fail(&"progression_search_begin_rejected")
	_search={"crate":crate,"inventory_id":inventory_id,"start_tick":tick}
	return true

func _advance_search(tick: int) -> bool:
	var key: String = _search.crate
	var inventory := _owner.raid_authority().snapshot(int(_search.inventory_id))
	if inventory==null: return _fail(&"progression_search_inventory_removed")
	var payload := {"verb":"crate_searched","crate_id":key,"inventory_id":int(_search.inventory_id),"inventory_revision":inventory.get_revision()}
	var id := _event_id(key)
	if not _raid.can_record_event(ZRaidEvent.EventKind.LOOT,id,tick,_raid.admission().actor_id,payload,_generation): return _fail(_raid.last_error)
	var elapsed: int = tick-int(_search.start_tick)
	@warning_ignore("integer_division")
	var ms: int = elapsed*1000/RaidClock.TICK_RATE-(elapsed-1)*1000/RaidClock.TICK_RATE
	var result := _owner.raid_authority().advance_discovery(_recipient,_recipient,ms)
	if result==null or not result.is_accepted(): return _fail(&"progression_search_advance_rejected")
	if result.is_completed():
		if not _raid.record_event(ZRaidEvent.EventKind.LOOT,id,tick,_raid.admission().actor_id,payload,_generation): return _fail(_raid.last_error)
		if not _task.crate_committed(key,_raid.journal.size(),tick): return _fail(_task.last_error)
		_searched[key]=true;_search={};_stats.searched_crates=_searched.size()
	return true

func _cancel_search() -> bool:
	if _search.is_empty(): return true
	var result := _owner.raid_authority().cancel_discovery(_recipient,_recipient,int(_search.inventory_id))
	if result==null or not result.is_accepted(): return _fail(&"progression_search_cancel_failed")
	_search={}
	return true

func _holds_objective() -> bool:
	var snapshot := _owner.raid_authority().snapshot(_owner.raid_player_inventory_id)
	if snapshot==null: return false
	for item: Dictionary in snapshot.get_items():
		if item.item_definition_identifier==String(ZerkovInventoryCatalog.ITEM_SUPPLY_CRATE) and int(item.quantity)>0: return true
	return false

## Audit damage lookups join the committed health receipts; repeated injury and
## death records for one operation are counted once, not once per emitted event.
func _consume_audit() -> bool:
	var damaged: bool = false
	var records := _raid.journal.records()
	var actor_key := _raid.admission().actor_id.canonical_key()
	while _audit_cursor < records.size():
		var event: Dictionary = records[_audit_cursor];_audit_cursor+=1
		if event.kind=="kill" and event.actor_id==actor_key: _stats.kills+=1
		var operation: String = String(event.payload.get("operation_id",event.event_id))
		if _damage_seen.has(operation): continue
		var damage := _combat.health.damage_result(operation)
		if not damage.get("committed",false): continue
		_damage_seen[operation]=true
		var amount: int = int(damage.get("applied_damage_micros",0))
		if damage.get("attacker_id")==actor_key: _stats.damage_dealt_micros+=amount
		if damage.get("target_id")==actor_key:
			_stats.damage_received_micros+=amount
			damaged=damaged or amount>0
	return damaged

## Must be called after successful advance_one, outside phase dispatch. An
## interrupted controller leaves no early extraction/lifecycle publication.
func after_tick() -> bool:
	if _inside or _released or _raid==null or _raid.last_processed_tick!=_tick or _tick<=_closed_tick:
		return _fail(&"progression_post_tick_invalid")
	if _raid.lifecycle not in [RaidAuthority.Lifecycle.ACTIVE,RaidAuthority.Lifecycle.EXTRACTING]: return _fail(&"progression_authority_failed")
	var desired: RaidAuthority.Lifecycle = RaidAuthority.Lifecycle.SETTLING if not _terminal.is_empty() \
		else (RaidAuthority.Lifecycle.EXTRACTING if _timer.snapshot().counting else RaidAuthority.Lifecycle.ACTIVE)
	if desired!=_raid.lifecycle and not _raid.transition(desired,_generation): return _fail(_raid.last_error)
	_closed_tick=_tick
	_frame=_pending_frame
	_pending_frame={}
	return true

## The root first releases other owners (AI/vision/equipment contributions) in
## their documented order. This method releases combat and flushes its weapon
## state before serializing. Pre-commit failure leaves SETTLING and retryable.
func finish(service: RaidSettlementService) -> Dictionary:
	if not _inside and _released and not _settlement.is_empty() and _raid.lifecycle==RaidAuthority.Lifecycle.COMPLETED:
		return RaidProgressionValues.freeze(_settlement)
	if _inside or service==null or _terminal.is_empty() or _raid.lifecycle!=RaidAuthority.Lifecycle.SETTLING:
		return RaidProgressionValues.failure(&"progression_not_settling")
	if not _combat_released:
		if not _combat.release(): return RaidProgressionValues.failure(_combat.last_error)
		_combat_released=true
	var loadout := _owner.raid_authority().make_persistence_record(_owner.raid_player_inventory_id)
	var prepared := service.prepare(_raid.raid_id().canonical_key(),_terminal,loadout)
	if not prepared.ok: return prepared
	var committed := service.commit(_raid.raid_id().canonical_key())
	if not committed.ok: return committed
	_settlement=committed
	if not _settlement_audited:
		if not _record(&"settlement",ZRaidEvent.EventKind.SETTLEMENT,_tick,
			{"settlement_id":String(committed.receipt.settlement_id),"profile_generation":int(committed.receipt.profile_generation)}):
			return {"ok":false,"committed":true,"reason":&"settlement_committed_audit_failed","receipt":committed.receipt}
		_settlement_audited=true
	if not release(): return {"ok":false,"committed":true,"reason":last_error,"receipt":committed.receipt}
	if not _raid.transition(RaidAuthority.Lifecycle.COMPLETED,_generation):
		return {"ok":false,"committed":true,"reason":_raid.last_error,"receipt":committed.receipt}
	return committed

func snapshot() -> Dictionary:
	return _frame
## Only completed tick publication authorizes opening the searched container.
func was_crate_searched(crate_id: String) -> bool:
	return _frame.get("searched_ids", []).has(crate_id)

func terminal_record() -> Dictionary:
	return RaidProgressionValues.freeze(_terminal if _closed_tick==_tick else {})
func committed_summary() -> Dictionary:
	return RaidProgressionValues.freeze(_settlement)

func raid_view() -> RaidView:
	if _frame.is_empty(): return null
	var state: Dictionary = _frame.clock
	var status: RaidView.ExtractionStatus = RaidView.ExtractionStatus.LOCKED
	if state.outcome=="extracted": status=RaidView.ExtractionStatus.COMPLETED
	elif state.counting: status=RaidView.ExtractionStatus.COUNTING_DOWN
	elif _task.ready_to_extract(): status=RaidView.ExtractionStatus.AVAILABLE
	var extraction := RaidView.Extraction.create(StringName(SupplyRunGraph.ROAD_GATE),"Road Gate",status,0,
		_countdown_duration-int(state.countdown_remaining) if state.started_tick>=0 else 0,_countdown_duration,
		&"supply_run_required" if status==RaidView.ExtractionStatus.LOCKED else &"")
	return RaidView.create(_generation,_tick,_tick,_raid.raid_id(),_raid.admission().actor_id,
		int(_raid.lifecycle),&"zerkov.map.sawmill","Sawmill Yard",mini(_tick,int(state.deadline_tick)),
		int(state.deadline_tick),null,[extraction],[])

func release() -> bool:
	if _inside: return _fail(&"progression_release_during_tick")
	if _released: return true
	if _generation == 0:
		if _task != null: _task.release()
		_released=true
		return true
	if not _cancel_search(): return false
	if not _discovery_released:
		if not _owner.raid_authority().teardown_discovery_recipient(_recipient,_recipient).get("ok",false): return _fail(&"progression_discovery_release_failed")
		_discovery_released=true
	if _raid.has_phase_handler(HANDLER,_generation) and not _raid.unregister_phase_handler(HANDLER,_generation): return _fail(_raid.last_error)
	_task.release();_released=true
	return true

func _record(key: StringName, kind: ZRaidEvent.EventKind, tick: int, payload: Dictionary) -> bool:
	return true if _raid.record_event(kind,_event_id(String(key)),tick,_raid.admission().actor_id,payload,_generation) else _fail(_raid.last_error)
func _event_id(key: String) -> ZConsequenceId:
	var digest := (_raid.raid_id().canonical_key()+":"+key).sha256_text()
	return ZConsequenceId.from_parts(PackedStringArray(["progression",digest.substr(0,32),digest.substr(32)]))
static func _health_record(health: Dictionary) -> Dictionary:
	var parts: Array = []
	for zone: Dictionary in health.body_parts:
		parts.append({"zone":String(zone.zone_identifier),"health_micros":int(zone.health_micros),
			"maximum_micros":int(zone.max_health_micros),"bleeding":bool(zone.heavy_bleed),"fractured":bool(zone.fractured)})
	return {"alive":bool(health.alive),"health_revision":int(health.health_revision),
		"stamina_micros":int(health.stamina_micros),"hydration_micros":int(health.hydration_micros),"body_parts":parts}
func _fail(reason: StringName) -> bool:
	last_error=reason
	return false
