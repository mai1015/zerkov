class_name RaidSettlementService
extends RefCounted
## Tasks 7.2/7.8/7.10/7.11/7.13. One root-owned service, existing ProfileStore.
## Three CAS checkpoints: deployed escrow -> prepared result -> committed profile.
## No sidecar result, unsafe rename, mutable UI state or second save format.
const V = preload("res://game/raid/progression/raid_progression_values.gd")
var _store: ProfileStore
var _inventory: SettlementInventoryPort
var _busy: bool = false

func configure(store: ProfileStore, inventory: SettlementInventoryPort) -> bool:
	if _store != null or store == null or not store.is_configured() or inventory == null: return false
	_store = store
	_inventory = inventory
	return true

## The selected loadout already belongs to this immutable profile generation.
## No fixture items are created. All profile mutations must honor active escrow.
func deploy(request_id: String, expected_generation: int, map_descriptor: Dictionary = {}) -> Dictionary:
	if not _enter(): return V.failure(&"settlement_service_unavailable_or_busy")
	var result := _deploy(request_id, expected_generation, map_descriptor)
	_busy = false
	return V.freeze(result)

func _deploy(request_id: String, expected_generation: int, map_descriptor: Dictionary = {}) -> Dictionary:
	if not map_descriptor.is_empty() and not V.valid_map_descriptor(map_descriptor): return V.failure(&"deployment_map_invalid")
	if not ZIdentityRules.is_valid(request_id, &"request"): return V.failure(&"deployment_request_invalid")
	var current := _read()
	if not current.ok: return current
	var state: Dictionary = current.payload.project.get(V.STATE_KEY, V.initial_state())
	if not V.valid_state(state): return V.failure(&"raid_profile_schema_invalid")
	# Producer retries cannot allocate a second identity after a completed raid.
	for bytes: Variant in state.history.values():
		if not bytes is PackedByteArray: return V.failure(&"settlement_history_invalid")
		var receipt := V.decode(bytes)
		if receipt.get("deployment_request") == request_id:
			if receipt.get("map",{}) != map_descriptor: return V.failure(&"deployment_map_conflict")
			return {"ok": true, "status": &"already_settled", "receipt": receipt, "committed": true, "replayed": true}
	if not state.active.is_empty():
		if state.active.get("request_id") == request_id and state.active.get("start_generation") == expected_generation:
			if state.active.get("map",{}) != map_descriptor: return V.failure(&"deployment_map_conflict")
			return _deployment_result(current, true)
		return V.failure(&"profile_has_active_raid")
	if current.generation != expected_generation: return V.failure(&"profile_generation_stale")
	if state.history.size() >= V.MAX_HISTORY: return V.failure(&"raid_history_capacity_requires_migration")
	var domains: Dictionary = current.payload.domains
	if not domains.has(V.LOADOUT) or not domains.has(V.STASH) \
		or not _inventory.validate_loadout(domains[V.LOADOUT]) or not _inventory.validate_stash(domains[V.STASH]): return V.failure(&"profile_loadout_invalid")
	var next: Dictionary = current.payload.duplicate(true)
	state = state.duplicate(true)
	var identifiers := V.ids(_store.profile_id(), state.next_sequence)
	state.next_sequence += 1
	state.active = {"phase": "deployed", "raid_id": identifiers.raid_id,
		"settlement_id": identifiers.settlement_id, "request_id": request_id,
		"start_generation": expected_generation, "start_fingerprint": current.fingerprint,
		"escrow_digest": domains[V.LOADOUT].hex_encode().sha256_text(),
		"resume_enabled": false}
	if not map_descriptor.is_empty(): state.active["map"]=map_descriptor.duplicate(true)
	next.project[V.STATE_KEY] = state
	var saved := _save(next, current.generation)
	if not saved.ok: return saved
	return _deployment_result(_read(), false)

func _deployment_result(current: Dictionary, replayed: bool) -> Dictionary:
	if not current.get("ok", false): return current
	return {"ok": true, "committed": true, "replayed": replayed,
		"can_instantiate": not replayed and current.payload.project[V.STATE_KEY].active.phase == "deployed",
		"deployment": current.payload.project[V.STATE_KEY].active,
		"profile_generation": current.generation, "profile_fingerprint": current.fingerprint,
		"domains": current.payload.domains}

## Caller is the trusted post-tick raid composition. It captures native loadout
## AFTER all cancellation/weapon persistence owners have successfully released.
func prepare(raid_id: String, terminal: Dictionary, loadout: PackedByteArray) -> Dictionary:
	if not _enter(): return V.failure(&"settlement_service_unavailable_or_busy")
	var result := _prepare(raid_id, terminal, loadout)
	_busy = false
	return V.freeze(result)

func _prepare(raid_id: String, terminal: Dictionary, loadout: PackedByteArray) -> Dictionary:
	if not _valid_terminal(terminal): return V.failure(&"terminal_record_invalid")
	var current := _read()
	if not current.ok: return current
	var state: Dictionary = current.payload.project.get(V.STATE_KEY, {})
	if not V.valid_state(state): return V.failure(&"raid_profile_schema_invalid")
	var input: Dictionary = {"terminal": terminal, "loadout": loadout}
	var pinned: Dictionary = V.decode(state.history[raid_id]) if state.history.has(raid_id) else state.active
	if pinned.has("map"): input["map"]=pinned.map
	var input_digest := V.digest(input)
	if input_digest.is_empty(): return V.failure(&"settlement_input_unbounded")
	if state.history.has(raid_id):
		var receipt := V.decode(state.history[raid_id])
		return {"ok": true, "committed": true, "replayed": true, "receipt": receipt} \
			if receipt.get("input_digest") == input_digest else V.failure(&"settlement_identity_conflict")
	var active: Dictionary = state.active
	if active.get("raid_id") != raid_id: return V.failure(&"deployment_identity_mismatch")
	if active.get("phase") == "prepared":
		var prior := V.decode(active.get("receipt_bytes", PackedByteArray()))
		return {"ok": true, "committed": false, "prepared": true, "replayed": true, "receipt": prior} \
			if prior.get("input_digest") == input_digest else V.failure(&"settlement_identity_conflict")
	if active.get("phase") != "deployed": return V.failure(&"deployment_phase_invalid")
	var plan := _inventory.plan(loadout, terminal.outcome)
	if plan.get("ok") != true or not plan.get("record") is PackedByteArray \
		or not plan.get("retained") is Array or not plan.get("lost") is Array \
		or not _inventory.validate_loadout(plan.record): return V.failure(&"settlement_inventory_plan_failed")
	var receipt := {"schema": "zerkov.raid.settlement.v1", "raid_id": raid_id,
		"settlement_id": active.settlement_id, "deployment_request": active.request_id,
		"source_profile_generation": active.start_generation, "input_digest": input_digest,
		"outcome": terminal.outcome, "duration_ticks": terminal.tick,
		"audit_digest": terminal.audit_digest, "audit_available": terminal.audit_available,
		"stats": terminal.stats, "health": terminal.health, "task": terminal.task,
		"retained": plan.retained, "lost": plan.lost,
		"valuation_available": false, "currency_reward": 0,
		"inventory_digest": plan.record.hex_encode().sha256_text(),
		"profile_generation": int(current.generation) + 2}
	if active.has("map"): receipt["map"]=active.map.duplicate(true)
	var encoded := V.encode(receipt)
	if encoded.is_empty(): return V.failure(&"settlement_receipt_unbounded")
	var next: Dictionary = current.payload.duplicate(true)
	next.project[V.STATE_KEY].active["phase"] = "prepared"
	next.project[V.STATE_KEY].active["receipt_bytes"] = encoded
	next.domains[V.PENDING_LOADOUT] = plan.record
	var saved := _save(next, current.generation)
	if not saved.ok: return saved
	return {"ok": true, "prepared": true, "committed": false, "replayed": false, "receipt": receipt}

func commit(raid_id: String) -> Dictionary:
	if not _enter(): return V.failure(&"settlement_service_unavailable_or_busy")
	var result := _commit(raid_id)
	_busy = false
	return V.freeze(result)

func _commit(raid_id: String) -> Dictionary:
	var current := _read()
	if not current.ok: return current
	var state: Dictionary = current.payload.project.get(V.STATE_KEY, {})
	if not V.valid_state(state): return V.failure(&"raid_profile_schema_invalid")
	if state.history.has(raid_id): return _committed(current, raid_id, true)
	if state.active.get("raid_id") != raid_id or state.active.get("phase") != "prepared":
		return V.failure(&"settlement_not_prepared")
	var receipt := V.decode(state.active.get("receipt_bytes", PackedByteArray()))
	var pending: Variant = current.payload.domains.get(V.PENDING_LOADOUT)
	if receipt.is_empty() or not pending is PackedByteArray \
		or pending.hex_encode().sha256_text() != receipt.get("inventory_digest") \
		or receipt.get("profile_generation") != current.generation + 1 \
		or not _inventory.validate_loadout(pending): return V.failure(&"prepared_settlement_corrupt")
	var next: Dictionary = current.payload.duplicate(true)
	next.domains[V.LOADOUT] = pending
	next.domains.erase(V.PENDING_LOADOUT)
	next.project[V.STATE_KEY].history[raid_id] = state.active.receipt_bytes
	next.project[V.STATE_KEY].active = {}
	# Preserve terminal health consequences; never manufacture healing or reset
	# the next raid's actor behind a UI. Reconstruction is a deployment adapter.
	next.project["last_raid_health"] = V.encode(receipt.health)
	var saved := _save(next, current.generation)
	if not saved.ok: return saved
	var result := _committed(_read(), raid_id, false)
	if result.get("ok", false): result["durable"] = saved.get("durable", false)
	return result

## No mid-raid restore. A persisted prepared plan replays. A crashed active raid
## loses unsecured ESCROW items and cannot resurrect uncommitted loot/results.
func recover() -> Dictionary:
	if not _enter(): return V.failure(&"settlement_service_unavailable_or_busy")
	var current := _read()
	var result: Dictionary = current
	if current.ok:
		var state: Dictionary = current.payload.project.get(V.STATE_KEY, V.initial_state())
		if not V.valid_state(state): result = V.failure(&"raid_profile_schema_invalid")
		elif state.active.is_empty(): result = {"ok": true, "status": &"no_active_raid"}
		else:
			var active: Dictionary = state.active
			if active.phase == "deployed":
				var terminal := {"outcome": "abandoned", "tick": 0, "audit_available": false,
					"audit_digest": V.digest({"raid_id": active.raid_id, "reason": "uncommitted_raid_not_restored"}),
					"stats": {}, "health": {}, "task": {"status": "failed", "reason": "resume_disabled"}}
				result = _prepare(active.raid_id, terminal, current.payload.domains[V.LOADOUT])
				if result.ok: result = _commit(active.raid_id)
			else: result = _commit(active.raid_id)
	_busy = false
	return V.freeze(result)

func summary(raid_id: String) -> Dictionary:
	if not _enter(): return V.failure(&"settlement_service_unavailable_or_busy")
	var current := _read()
	var result := _committed(current, raid_id, true) if current.ok else current
	_busy = false
	return V.freeze(result)

func _committed(current: Dictionary, raid_id: String, replayed: bool) -> Dictionary:
	if not current.get("ok", false): return current
	var state: Dictionary = current.payload.project.get(V.STATE_KEY, {})
	if not V.valid_state(state) or not state.history.has(raid_id): return V.failure(&"settlement_not_committed")
	var receipt := V.decode(state.history[raid_id])
	if receipt.get("raid_id") != raid_id or receipt.get("schema") != "zerkov.raid.settlement.v1":
		return V.failure(&"settlement_history_corrupt")
	return {"ok": true, "committed": true, "replayed": replayed, "receipt": receipt,
		"profile_generation": current.generation, "profile_fingerprint": current.fingerprint}

func _read() -> Dictionary:
	var result := _store.load_profile()
	if not result.ok: return V.failure(StringName(result.get("reason", &"profile_load_failed")))
	var state: Variant=result.payload.project.get(V.STATE_KEY,V.initial_state())
	if not state is Dictionary or not V.valid_state(state): return V.failure(&"raid_profile_schema_invalid")
	for key: String in state.history:
		var receipt:=V.decode(state.history[key])
		if not key.begins_with("zerkov.raid."+_store.profile_id().sha256_text().substr(0,32)+".") \
			or receipt.profile_generation>result.generation: return V.failure(&"raid_history_binding_invalid")
	if not state.active.is_empty():
		var active: Dictionary=state.active
		var expected_ids:=V.ids(_store.profile_id(),state.next_sequence-1)
		if state.next_sequence<2 or active.raid_id!=expected_ids.raid_id or active.settlement_id!=expected_ids.settlement_id \
			or result.generation!=active.start_generation+(2 if active.phase=="prepared" else 1):
			return V.failure(&"active_profile_generation_invalid")
		var escrow: Variant=result.payload.domains.get(V.LOADOUT)
		if not escrow is PackedByteArray or escrow.hex_encode().sha256_text()!=active.escrow_digest:
			return V.failure(&"active_escrow_changed")
	return result

func _save(payload: Dictionary, generation: int) -> Dictionary:
	# Probe total codec limits before entering ProfileStore's filesystem boundary.
	if not ProfileCanonicalCodec.encode(payload).ok: return V.failure(&"profile_payload_unbounded")
	var result := _store.save_profile(payload, generation, generation + 1)
	if not result.get("committed", false) or not result.get("verified", false):
		return {"ok": false, "reason": result.get("reason", &"profile_commit_unverified"),
			"committed": result.get("committed", false), "recovery_required": result.get("recovery_required", false)}
	# Re-read selection to protect against committing a summary for another value.
	var observed := _store.load_profile()
	if not observed.ok or observed.generation != generation + 1 or V.digest(observed.payload) != V.digest(payload):
		return {"ok": false, "committed": true, "recovery_required": true, "reason": &"profile_commit_readback_failed"}
	return {"ok": true, "committed": true, "durable": result.get("durable", false)}

func _enter() -> bool:
	if _busy or _store == null or not _store.is_configured(): return false
	_busy = true
	return true

static func _valid_terminal(value: Dictionary) -> bool:
	return value.size() == 7 and value.get("outcome") in ["extracted", "dead", "timeout", "abandoned"] \
		and typeof(value.get("tick")) == TYPE_INT and value.tick >= 0 and value.tick <= 2_147_483_647 \
		and typeof(value.get("audit_available")) == TYPE_BOOL and V.sha(value.get("audit_digest")) \
		and value.get("stats") is Dictionary and value.get("health") is Dictionary and value.get("task") is Dictionary
