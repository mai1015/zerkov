class_name InventoryWeaponAdapter
extends Node
## Game-owned ammunition/reload coordinator for one raid inventory authority.
##
## Inventory System remains the sole owner of physical ammunition. Weapon
## System remains the sole owner of loaded rounds and reload phase. This
## adapter serializes their public participant APIs in one no-yield critical
## section and publishes game-owned outcomes only after coordination settles.
## Signals from either add-on are notification edges, never transaction edges.
##
## The installed WeaponAuthority facade has no public weapon rollback method.
## Its compatibility path is safe only for this slice's offline, single-thread,
## single-writer process lifetime: inventory silent commit emits nothing,
## commit_due_reload emits nothing, both canonical states are coherent before
## inventory publication, then the weapon completion signal is emitted. It is
## not crash/restart atomic. Any impossible post-commit invariant breach
## permanently latches RECOVERY_REQUIRED; the reservation is never minted or
## retried as a new reload.

signal reload_coordinated(outcome: Dictionary)
signal recovery_latched(reason: StringName, details: Dictionary)
signal binding_invalidated(reason: StringName)

enum Lifecycle {
	UNBOUND,
	BOUND,
	RECOVERY_REQUIRED,
	INVALIDATED,
}

const MAX_PENDING_RELOADS: int = 64
const MAX_REQUEST_RECEIPTS: int = 256
const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000
const RESERVATION_TTL_TICKS: int = 3_600

const STAGE_HELD: StringName = &"held"
const STAGE_CANCEL_PENDING: StringName = &"cancel_pending"
const STAGE_COMMITTING: StringName = &"committing"
const STAGE_COMMITTED: StringName = &"committed"
const STAGE_RELEASED: StringName = &"released"
const STAGE_RECOVERY: StringName = &"recovery_required"

const INTERRUPT_REASONS: Array[StringName] = [
	&"death",
	&"weapon_swap",
	&"weapon_invalidation",
	&"authority_invalidation",
	&"teardown",
]

# Exact first-playable policy. The caller never chooses trait, profile, source
# priority, or quantity. A loaded AKM magazine is consumed first, followed by
# carried loose ammunition from rig, pockets, backpack, and secure container.
const AKM_CONTAINER_PRIORITY: Array[StringName] = [
	ZerkovInventoryCatalog.CONTAINER_MAGAZINE_AKM,
	ZerkovInventoryCatalog.CONTAINER_RIG,
	ZerkovInventoryCatalog.CONTAINER_POCKETS,
	ZerkovInventoryCatalog.CONTAINER_BACKPACK,
	ZerkovInventoryCatalog.CONTAINER_SECURE,
]

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _owner_generation: int = 0
var _inventory_authority: InventoryAuthority
var _inventory_authority_instance_id: int = 0
var _inventory_id: int = 0
var _admission: ZSessionAdmission
var _adapter_generation: int = 0
var _generation_counter: int = 0
var _weapon_port: WeaponReloadParticipantPort
var _weapon_port_token: String = ""
var _bindings: Dictionary = {}
var _pending_by_weapon: Dictionary = {}
var _pending_by_reservation: Dictionary = {}
var _request_receipts: Dictionary = {}
var _receipt_order: PackedStringArray = PackedStringArray()
var _transaction_active: bool = false
var _public_signal_active: bool = false
var _deferred_invalidation_reason: StringName = &""
var _recovery_details: Dictionary = {}
var _recovery_signal_emitted: bool = false
var _inventory_unloaded_callback: Callable
var _inventory_generation_callback: Callable


func bind_owner(
	owner: RaidInventoryOwner,
	admission: ZSessionAdmission,
	weapon_port: WeaponReloadParticipantPort,
	expected_owner_generation: int
) -> bool:
	last_error = &""
	if _transaction_active or _public_signal_active:
		return _reject_bind(&"reentrant_binding_change")
	if lifecycle == Lifecycle.BOUND or lifecycle == Lifecycle.RECOVERY_REQUIRED:
		return _reject_bind(&"adapter_already_bound")
	if owner == null or not is_instance_valid(owner) \
			or expected_owner_generation <= 0 \
			or not owner.is_current_generation(expected_owner_generation):
		return _reject_bind(&"inventory_owner_invalid")
	if admission == null or not admission.is_usable():
		return _reject_bind(&"session_admission_invalid")
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return _reject_bind(&"session_admission_invalid")
	if weapon_port == null or not weapon_port.is_ready() \
			or weapon_port.commit_capability() \
				== WeaponReloadParticipantPort.CommitCapability.UNAVAILABLE:
		return _reject_bind(&"weapon_reload_port_invalid")
	var authority := owner.raid_authority()
	if authority == null or not is_instance_valid(authority) \
			or owner.raid_player_inventory_id <= 0 \
			or not authority.has_inventory(owner.raid_player_inventory_id):
		return _reject_bind(&"raid_inventory_authority_invalid")

	_reset_unbound_state()
	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_owner_generation = expected_owner_generation
	_inventory_authority = authority
	_inventory_authority_instance_id = authority.get_instance_id()
	_inventory_id = owner.raid_player_inventory_id
	_admission = admission_copy
	_generation_counter += 1
	_adapter_generation = _generation_counter
	_weapon_port = weapon_port
	_weapon_port_token = weapon_port.identity_token()
	if _weapon_port_token.is_empty():
		_reset_unbound_state()
		return _reject_bind(&"weapon_reload_port_identity_invalid")
	lifecycle = Lifecycle.BOUND
	_connect_inventory_lifecycle()
	return true


func is_bound() -> bool:
	return lifecycle == Lifecycle.BOUND and _binding_is_current()


func adapter_generation() -> int:
	return _adapter_generation


func owner_generation() -> int:
	return _owner_generation


func inventory_id() -> int:
	return _inventory_id


func commit_capability() -> WeaponReloadParticipantPort.CommitCapability:
	return _weapon_port.commit_capability() \
		if _weapon_port != null else WeaponReloadParticipantPort.CommitCapability.UNAVAILABLE


## Opaque provenance for game-owned composition adapters. This permits task
## 5.2 to prove that instance lifecycle and reload coordination target the
## exact same WeaponAuthority without exposing either participant for mutation.
func weapon_port_identity_token() -> String:
	return _weapon_port_token if is_bound() else ""


func recovery_details() -> Dictionary:
	return _recovery_details.duplicate(true)


func pending_reloads() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var reservation_ids := PackedStringArray(_pending_by_reservation.keys())
	reservation_ids.sort()
	for reservation_id in reservation_ids:
		result.append((_pending_by_reservation[reservation_id] as Dictionary).duplicate(true))
	return result


func register_weapon(mapping: Dictionary, binding_generation: int) -> Dictionary:
	last_error = &""
	if not _can_mutate():
		return _rejection(last_error)
	if binding_generation <= 0:
		return _rejection(&"weapon_binding_generation_invalid")
	var validation := _validate_mapping(mapping)
	if not bool(validation.get("ok", false)):
		return _rejection(StringName(validation.get("reason", &"weapon_mapping_invalid")))
	var weapon_id := String(mapping.get("weapon_id", ""))
	if _pending_by_weapon.has(weapon_id):
		return _rejection(&"weapon_reload_active")
	var weapon_snapshot := _weapon_port.snapshot(weapon_id)
	if not _weapon_snapshot_matches_mapping(weapon_snapshot, mapping):
		return _rejection(&"weapon_authority_binding_mismatch")
	var existing := _bindings.get(weapon_id, {}) as Dictionary
	if not existing.is_empty():
		if int(existing.get("binding_generation", 0)) == binding_generation \
				and (existing.get("mapping", {}) as Dictionary) == mapping:
			return {
				"accepted": true,
				"replayed": true,
				"weapon_id": weapon_id,
				"binding_generation": binding_generation,
			}
		return _rejection(&"weapon_binding_conflict")
	var sequence_floor := maxi(
		int(weapon_snapshot.get("admitted_sequence_high_watermark", 0)),
		int(weapon_snapshot.get("last_command_sequence", 0)))
	if sequence_floor >= MAX_AUTHORITY_TICK:
		return _rejection(&"weapon_sequence_exhausted")
	_bindings[weapon_id] = {
		"mapping": mapping.duplicate(true),
		"binding_generation": binding_generation,
		"next_sequence": maxi(1, sequence_floor + 1),
	}
	return {
		"accepted": true,
		"replayed": false,
		"weapon_id": weapon_id,
		"binding_generation": binding_generation,
		"inventory_revision": _inventory_authority.inventory_revision(_inventory_id),
		"weapon_revision": int(weapon_snapshot.get("revision", -1)),
	}


## Retires one instance binding without mutating either native authority. This
## cleanup operation deliberately does not require a current inventory runtime:
## owner lifecycle signals arrive after native inventory erasure, while the
## game-owned binding must still be explicitly accounted for. Exact replay is a
## no-op; a stale generation can never remove a replacement binding.
func unregister_weapon(weapon_id: String, binding_generation: int) -> Dictionary:
	last_error = &""
	if _transaction_active or _public_signal_active:
		return _rejection(&"reentrant_binding_change")
	if ZWeaponId.parse(weapon_id) == null:
		return _rejection(&"weapon_id_invalid")
	if binding_generation <= 0:
		return _rejection(&"weapon_binding_generation_invalid")
	var existing := _bindings.get(weapon_id, {}) as Dictionary
	if existing.is_empty():
		return {
			"accepted": true,
			"replayed": true,
			"weapon_id": weapon_id,
			"binding_generation": binding_generation,
		}
	if lifecycle != Lifecycle.BOUND and lifecycle != Lifecycle.RECOVERY_REQUIRED:
		return _rejection(&"adapter_not_bound")
	if _pending_by_weapon.has(weapon_id):
		return _rejection(&"weapon_reload_active")
	if int(existing.get("binding_generation", 0)) != binding_generation:
		return _rejection(&"weapon_binding_generation_stale")
	_bindings.erase(weapon_id)
	return {
		"accepted": true,
		"replayed": false,
		"weapon_id": weapon_id,
		"binding_generation": binding_generation,
	}


func begin_reload(intent: Dictionary) -> Dictionary:
	last_error = &""
	var replay := _request_replay(intent)
	if not replay.is_empty():
		return replay
	if not _can_mutate():
		# Reentrant/publication calls are observational rejections only. They do
		# not even claim a request-ledger slot while the critical section runs.
		return _rejection(last_error)
	var validation := _validate_begin_intent(intent)
	if not bool(validation.get("ok", false)):
		return _remember_rejection(
			intent, StringName(validation.get("reason", &"reload_intent_invalid")))
	var weapon_id := String(intent["weapon_id"])
	if _pending_by_weapon.has(weapon_id):
		return _remember_rejection(intent, &"weapon_reload_active")
	if _pending_by_reservation.size() >= MAX_PENDING_RELOADS:
		return _remember_rejection(intent, &"pending_reload_limit")
	var binding := _bindings.get(weapon_id, {}) as Dictionary
	if not _intent_matches_context_and_binding(intent, binding):
		return _remember_rejection(intent, &"reload_context_stale")
	var mapping := binding.get("mapping", {}) as Dictionary
	var inventory_snapshot := _inventory_authority.snapshot(_inventory_id)
	if inventory_snapshot == null \
			or inventory_snapshot.get_revision() != int(intent["expected_inventory_revision"]):
		return _remember_rejection(intent, &"inventory_revision_stale")
	if not _mapping_is_equipped(inventory_snapshot, mapping):
		return _remember_rejection(intent, &"weapon_not_equipped")
	var weapon_snapshot := _weapon_port.snapshot(weapon_id)
	if not _weapon_snapshot_matches_mapping(weapon_snapshot, mapping):
		return _remember_rejection(intent, &"weapon_authority_binding_mismatch")
	if int(weapon_snapshot.get("revision", -1)) != int(intent["expected_weapon_revision"]):
		return _remember_rejection(intent, &"weapon_revision_stale")
	if String(weapon_snapshot.get("phase", "")) != "ready":
		return _remember_rejection(intent, &"weapon_reload_active")
	if not _loaded_profile_is_compatible(weapon_snapshot):
		return _remember_rejection(intent, &"loaded_ammunition_profile_mismatch")
	var missing := ZerkovCombatContent.AKM_CAPACITY \
		- int(weapon_snapshot.get("loaded_rounds", -1))
	if missing <= 0 or missing > ZerkovCombatContent.AKM_CAPACITY:
		return _remember_rejection(intent, &"reload_not_needed")
	var available := _available_ammunition(inventory_snapshot)
	var quantity := mini(missing, available)
	if quantity <= 0:
		return _remember_rejection(intent, &"ammunition_unavailable")
	var tick := int(intent["tick"])
	if tick < 0 or tick > MAX_AUTHORITY_TICK - RESERVATION_TTL_TICKS:
		return _remember_rejection(intent, &"authority_tick_invalid")

	var request_id := String(intent["request_id"])
	var reservation_id := derive_reservation_id(
		_admission, _owner_generation, _adapter_generation, _inventory_id,
		mapping, int(binding["binding_generation"]), request_id)
	if reservation_id.is_empty() or _pending_by_reservation.has(reservation_id):
		return _remember_rejection(intent, &"reservation_identity_invalid")
	var deadline_tick := tick + RESERVATION_TTL_TICKS
	_transaction_active = true
	var prepared: Dictionary = _inventory_authority.prepare_quantity_reservation(
		_inventory_id,
		reservation_id,
		String(ZerkovCombatContent.AMMO_TRAIT_762X39),
		_container_priority_strings(),
		quantity,
		inventory_snapshot.get_revision(),
		deadline_tick
	)
	if not _inventory_result_is(prepared, 1, reservation_id, quantity):
		_transaction_active = false
		var prepare_rejection := _remember_rejection(
			intent, &"ammunition_reservation_rejected", prepared)
		_process_deferred_invalidation(tick)
		return prepare_rejection

	var sequence := _reserve_sequence(weapon_id)
	if sequence <= 0:
		var sequence_release := _inventory_authority.release_quantity_reservation(
			_inventory_id, reservation_id)
		_transaction_active = false
		if not _inventory_result_is(sequence_release, 3, reservation_id, quantity):
			var sequence_recovery := _latch_recovery(
				&"begin_cleanup_release_failed", {}, sequence_release)
			_emit_outcome(sequence_recovery)
			_process_deferred_invalidation(tick)
			return sequence_recovery
		var sequence_rejection := _remember_rejection(intent, &"weapon_sequence_exhausted")
		_process_deferred_invalidation(tick)
		return sequence_rejection
	var command_id := _derive_command_id("begin", reservation_id, request_id)
	var record := _build_pending_record(
		intent, mapping, binding, weapon_snapshot, reservation_id,
		quantity, tick, deadline_tick, sequence, command_id, prepared)
	_pending_by_weapon[weapon_id] = reservation_id
	_pending_by_reservation[reservation_id] = record
	var begun := _weapon_port.begin_reload({
		"command_id": command_id,
		"sequence": sequence,
		"instance_id": weapon_id,
		"expected_revision": int(intent["expected_weapon_revision"]),
		"tick": tick,
		"authority_scope": _admission.raid_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"reservation_id": reservation_id,
		"reserved_rounds": quantity,
		"profile": _ammo_profile(),
	})
	if not bool(begun.get("accepted", false)):
		var released := _inventory_authority.release_quantity_reservation(
			_inventory_id, reservation_id)
		if _inventory_result_is(released, 3, reservation_id, quantity):
			_remove_pending(record)
			_transaction_active = false
			var begin_rejection := _remember_rejection(
				intent, &"weapon_reload_rejected", begun)
			_process_deferred_invalidation(tick)
			return begin_rejection
		record["stage"] = STAGE_CANCEL_PENDING
		record["cancel_reason"] = &"begin_rejected_release_pending"
		_pending_by_reservation[reservation_id] = record
		_transaction_active = false
		var release_pending := _remember_rejection(
			intent, &"weapon_reload_rejected_release_pending", {"weapon": begun, "inventory": released})
		_process_deferred_invalidation(tick)
		return release_pending

	record["weapon_reload_revision"] = int(begun.get("revision", -1))
	var post_weapon := _weapon_port.snapshot(weapon_id)
	var reload_state := post_weapon.get("reload", {}) as Dictionary
	if not _weapon_snapshot_matches_mapping(post_weapon, mapping) \
			or String(post_weapon.get("phase", "")) != "reloading" \
			or String(reload_state.get("reservation_id", "")) != reservation_id \
			or int(reload_state.get("reserved_rounds", -1)) != quantity \
			or not _profile_matches(
				reload_state.get("reserved_profile", {}) as Dictionary) \
			or int(post_weapon.get("revision", -1)) != int(record["weapon_reload_revision"]) \
			or int(post_weapon.get("loaded_rounds", -1)) \
				!= int(record["weapon_pre_reload_loaded_rounds"]) \
			or (post_weapon.get("loaded_profile", {}) as Dictionary) \
				!= (record.get("weapon_pre_reload_loaded_profile", {}) as Dictionary) \
			or int(reload_state.get("due_tick", -1)) <= tick \
			or int(reload_state.get("due_tick", -1)) > deadline_tick:
		var cleanup := _cancel_started_record(record, tick, &"begin_postcondition_failed")
		_transaction_active = false
		if not bool(cleanup.get("accepted", false)):
			var cleanup_recovery := _latch_recovery(
				&"begin_postcondition_cleanup_failed", record, cleanup)
			_emit_outcome(cleanup_recovery)
			_process_deferred_invalidation(tick)
			return cleanup_recovery
		var postcondition_rejection := _remember_rejection(
			intent, &"weapon_reload_postcondition_failed")
		_process_deferred_invalidation(tick)
		return postcondition_rejection
	record["due_tick"] = int(reload_state["due_tick"])
	record["stage"] = STAGE_HELD
	_pending_by_reservation[reservation_id] = record
	_transaction_active = false
	var outcome := _outcome_from_record(record, &"reload_started")
	_remember_request(intent, outcome, true)
	_emit_outcome(outcome)
	_process_deferred_invalidation(tick)
	return outcome.duplicate(true)


func cancel_reload(intent: Dictionary) -> Dictionary:
	last_error = &""
	var replay := _request_replay(intent)
	if not replay.is_empty():
		return replay
	if not _can_mutate():
		return _rejection(last_error)
	var validation := _validate_cancel_intent(intent)
	if not bool(validation.get("ok", false)):
		return _remember_rejection(
			intent, StringName(validation.get("reason", &"cancel_intent_invalid")))
	var weapon_id := String(intent["weapon_id"])
	var binding := _bindings.get(weapon_id, {}) as Dictionary
	if not _intent_matches_context_and_binding(intent, binding):
		return _remember_rejection(intent, &"reload_context_stale")
	if not _pending_by_weapon.has(weapon_id):
		return _remember_rejection(intent, &"reload_not_pending")
	var reservation_id := String(_pending_by_weapon[weapon_id])
	var record := _pending_by_reservation[reservation_id] as Dictionary
	_transaction_active = true
	var outcome := _cancel_record(
		record,
		int(intent["tick"]),
		StringName(intent["reason"]),
		String(intent["request_id"]),
		int(intent["expected_weapon_revision"])
	)
	_transaction_active = false
	_remember_request(intent, outcome, false)
	_emit_outcome(outcome)
	_process_deferred_invalidation(int(intent["tick"]))
	return outcome.duplicate(true)


func interrupt_reload(weapon_id: String, reason: StringName, tick: int) -> Dictionary:
	last_error = &""
	if not INTERRUPT_REASONS.has(reason):
		return _rejection(&"interrupt_reason_invalid")
	if not _can_mutate():
		return _rejection(last_error)
	if tick < 0 or tick > MAX_AUTHORITY_TICK:
		return _rejection(&"authority_tick_invalid")
	if not _pending_by_weapon.has(weapon_id):
		return {
			"accepted": true,
			"replayed": true,
			"kind": &"reload_interruption_noop",
			"weapon_id": weapon_id,
			"reason": reason,
		}
	var record := _pending_by_reservation[String(_pending_by_weapon[weapon_id])] as Dictionary
	var weapon_snapshot := _weapon_port.snapshot(weapon_id)
	var expected_revision := int(weapon_snapshot.get("revision", -1))
	var internal_request := _derive_internal_request_id(record, reason)
	var effective_tick := maxi(
		tick,
		maxi(int(record.get("start_tick", 0)),
			int(weapon_snapshot.get("authority_tick_floor", 0))))
	_transaction_active = true
	var outcome := _cancel_record(
		record, effective_tick, reason, internal_request, expected_revision)
	_transaction_active = false
	_emit_outcome(outcome)
	_process_deferred_invalidation(effective_tick)
	return outcome.duplicate(true)


func advance_due_reloads(tick: int) -> Array[Dictionary]:
	last_error = &""
	var outcomes: Array[Dictionary] = []
	if not _can_mutate():
		outcomes.append(_rejection(last_error))
		return outcomes
	if tick < 0 or tick > MAX_AUTHORITY_TICK:
		outcomes.append(_rejection(&"authority_tick_invalid"))
		return outcomes

	# Equipment removal, death/swap orchestration, and a previously failed
	# inventory release are resolved before any due completion is considered.
	var reservation_ids := PackedStringArray(_pending_by_reservation.keys())
	reservation_ids.sort()
	for reservation_id in reservation_ids:
		if not _pending_by_reservation.has(reservation_id):
			continue
		var record := _pending_by_reservation[reservation_id] as Dictionary
		if StringName(record.get("stage", &"")) == STAGE_CANCEL_PENDING:
			_transaction_active = true
			var retry := _retry_pending_release(record)
			_transaction_active = false
			outcomes.append(retry)
			continue
		var binding := _bindings.get(String(record["weapon_id"]), {}) as Dictionary
		var mapping := binding.get("mapping", {}) as Dictionary
		var inventory_snapshot := _inventory_authority.snapshot(_inventory_id)
		if inventory_snapshot == null or not _mapping_is_equipped(inventory_snapshot, mapping):
			outcomes.append(interrupt_reload(
				String(record["weapon_id"]), &"weapon_swap", tick))
	if lifecycle != Lifecycle.BOUND:
		return outcomes

	var due_candidates: Array = _weapon_port.due_reloads(tick)
	var candidates_by_reservation: Dictionary = {}
	for candidate_value in due_candidates:
		var candidate := candidate_value as Dictionary
		var reservation_id := String(candidate.get("reservation_id", ""))
		if reservation_id.is_empty() or candidates_by_reservation.has(reservation_id):
			_latch_recovery(&"weapon_due_candidate_ambiguous", {}, candidate)
			outcomes.append(_rejection(&"weapon_due_candidate_ambiguous"))
			return outcomes
		candidates_by_reservation[reservation_id] = candidate.duplicate(true)

	reservation_ids = PackedStringArray(_pending_by_reservation.keys())
	reservation_ids.sort()
	for reservation_id in reservation_ids:
		if lifecycle != Lifecycle.BOUND or not _pending_by_reservation.has(reservation_id):
			break
		var record := _pending_by_reservation[reservation_id] as Dictionary
		if StringName(record.get("stage", &"")) != STAGE_HELD \
				or int(record.get("due_tick", MAX_AUTHORITY_TICK)) > tick:
			continue
		if not candidates_by_reservation.has(reservation_id):
			var current_weapon := _weapon_port.snapshot(String(record["weapon_id"]))
			if current_weapon.is_empty() or String(current_weapon.get("phase", "")) == "ready":
				outcomes.append(interrupt_reload(
					String(record["weapon_id"]), &"weapon_invalidation", tick))
				continue
			_latch_recovery(&"due_reload_missing_from_weapon_authority", record, current_weapon)
			outcomes.append(_rejection(&"due_reload_missing_from_weapon_authority"))
			break
		_transaction_active = true
		var committed := _commit_record(
			record, tick, candidates_by_reservation[reservation_id])
		_transaction_active = false
		outcomes.append(committed)
		_emit_outcome(committed)
		_process_deferred_invalidation(tick)
	return outcomes


func release_binding(reason: StringName = &"teardown", tick: int = 0) -> bool:
	last_error = &""
	if _transaction_active or _public_signal_active:
		return _reject_bool(&"reentrant_binding_change")
	if lifecycle != Lifecycle.BOUND:
		return _reject_bool(&"adapter_not_bound")
	if not INTERRUPT_REASONS.has(reason):
		return _reject_bool(&"interrupt_reason_invalid")
	var weapon_ids := PackedStringArray(_pending_by_weapon.keys())
	weapon_ids.sort()
	for weapon_id in weapon_ids:
		var outcome := interrupt_reload(weapon_id, reason, tick)
		if not bool(outcome.get("accepted", false)):
			return _reject_bool(&"pending_reload_release_failed")
	_disconnect_inventory_lifecycle()
	lifecycle = Lifecycle.INVALIDATED
	last_error = reason
	_generation_counter += 1
	_adapter_generation = _generation_counter
	_bindings.clear()
	_pending_by_weapon.clear()
	_pending_by_reservation.clear()
	_clear_reload_request_receipts()
	_weapon_port.clear()
	_emit_invalidation(reason)
	return true


func validate_binding(tick: int = 0) -> bool:
	last_error = &""
	if lifecycle == Lifecycle.BOUND and _binding_is_current():
		return true
	if lifecycle == Lifecycle.BOUND:
		_resolve_stale_binding(tick)
	return false


static func derive_reservation_id(
	admission: ZSessionAdmission,
	owner_generation_value: int,
	adapter_generation_value: int,
	inventory_id_value: int,
	mapping: Dictionary,
	binding_generation: int,
	request_id: String
) -> String:
	if admission == null or not admission.is_usable() \
			or owner_generation_value <= 0 or adapter_generation_value <= 0 \
			or inventory_id_value <= 0 or binding_generation <= 0 \
			or ZRequestId.parse(request_id) == null:
		return ""
	var digest := ZCanonicalValue.sha256({
		"schema": "zerkov.reload.reservation.v1",
		"request_id": request_id,
		"raid_id": admission.raid_id.canonical_key(),
		"session_id": admission.session_id.canonical_key(),
		"actor_id": admission.actor_id.canonical_key(),
		"authority_epoch": admission.authority_epoch,
		"admission_generation": admission.generation,
		"owner_generation": owner_generation_value,
		"adapter_generation": adapter_generation_value,
		"inventory_id": inventory_id_value,
		"native_item_id": int(mapping.get("native_item_id", 0)),
		"weapon_id": String(mapping.get("weapon_id", "")),
		"weapon_binding_generation": binding_generation,
	})
	return "zerkov.reload.%s" % digest.substr(0, 48) if digest.length() >= 48 else ""


func _commit_record(record: Dictionary, tick: int, candidate: Dictionary) -> Dictionary:
	var reservation_id := String(record["reservation_id"])
	var weapon_id := String(record["weapon_id"])
	var quantity := int(record["quantity"])
	var health: Dictionary = _inventory_authority.health_quantity_reservation(reservation_id)
	if not _inventory_result_is(health, 1, reservation_id, quantity) \
			or (health.get("lines", []) as Array) != (record.get("reservation_lines", []) as Array):
		return _latch_recovery(&"inventory_reservation_health_invalid", record, health)
	var weapon_before := _weapon_port.snapshot(weapon_id)
	var reload_state := weapon_before.get("reload", {}) as Dictionary
	if String(weapon_before.get("phase", "")) != "reloading" \
			or String(reload_state.get("reservation_id", "")) != reservation_id \
			or int(reload_state.get("reserved_rounds", -1)) != quantity \
			or not _profile_matches(reload_state.get("reserved_profile", {}) as Dictionary) \
			or int(reload_state.get("due_tick", -1)) > tick \
			or int(weapon_before.get("revision", -1)) != int(record["weapon_reload_revision"]):
		return _latch_recovery(&"weapon_reload_health_invalid", record, weapon_before)
	if not _candidate_matches_record(candidate, record, weapon_before):
		return _latch_recovery(&"weapon_due_candidate_invalid", record, candidate)

	var weapon_prepared := _weapon_port.prepare_due_reload(tick, weapon_id, reservation_id)
	if not bool(weapon_prepared.get("accepted", false)):
		return _latch_recovery(&"weapon_prepare_due_failed", record, weapon_prepared)
	record["stage"] = STAGE_COMMITTING
	record["commit_tick"] = tick
	_pending_by_reservation[reservation_id] = record

	var predecessor_revision := _inventory_authority.inventory_revision(_inventory_id)
	var inventory_committed: Dictionary = _inventory_authority.commit_quantity_reservation_silent(
		_inventory_id, reservation_id)
	if not _inventory_result_is(inventory_committed, 2, reservation_id, quantity) \
			or int(inventory_committed.get("revision", -1)) != predecessor_revision + 1:
		return _latch_recovery(&"inventory_silent_commit_failed", record, inventory_committed)

	var weapon_committed := _weapon_port.commit_reload_silent(reservation_id)
	if not bool(weapon_committed.get("accepted", false)):
		var mutation_state := StringName(weapon_committed.get(
			"mutation_state", WeaponReloadParticipantPort.MUTATION_AMBIGUOUS))
		if mutation_state != WeaponReloadParticipantPort.MUTATION_NONE:
			# The facade cannot prove whether rounds were added. Restoring ammo in
			# this branch could duplicate it, so stop forever with both records.
			return _latch_recovery(
				&"weapon_commit_ambiguous_after_inventory_commit", record, weapon_committed)
		var inventory_rolled_back: Dictionary = _inventory_authority.rollback_quantity_reservation(
			_inventory_id, reservation_id)
		if not _inventory_result_is(inventory_rolled_back, 3, reservation_id, quantity) \
				or _inventory_authority.inventory_revision(_inventory_id) != predecessor_revision:
			return _latch_recovery(
				&"inventory_rollback_unproven", record, inventory_rolled_back)
		# Weapon state was proven unchanged and still references the now-
		# released reservation. Cancel it before allowing another reload.
		var cancelled := _cancel_weapon_after_rollback(record, tick)
		if not bool(cancelled.get("accepted", false)):
			return _latch_recovery(&"weapon_cancel_after_rollback_failed", record, cancelled)
		_remove_pending(record)
		return _outcome_from_record(record, &"reload_commit_rolled_back", {
			"accepted": false,
			"reason": &"weapon_commit_failed",
			"inventory_rollback": inventory_rolled_back,
			"weapon_commit": weapon_committed,
		})

	var completion := weapon_committed.get("completion", {}) as Dictionary
	if not _candidate_matches_completion(candidate, completion):
		return _latch_recovery(&"weapon_commit_completion_invalid", record, weapon_committed)

	# In the facade path the weapon commit is now irreversible but silent. A
	# valid Inventory COMMITTED record has no ordinary failure branch here and
	# no adapter-mediated operation can interleave. Any unexpected rejection is
	# terminal-fatal; retrying under a new identity is forbidden.
	var inventory_published: Dictionary = _inventory_authority.publish_quantity_reservation(
		reservation_id)
	if not _inventory_result_is(inventory_published, 4, reservation_id, quantity):
		if _weapon_port.commit_capability() \
				== WeaponReloadParticipantPort.CommitCapability.ROLLBACKABLE_PARTICIPANT:
			var weapon_rollback := _weapon_port.rollback_reload(reservation_id)
			var inventory_rollback := _inventory_authority.rollback_quantity_reservation(
				_inventory_id, reservation_id)
			if bool(weapon_rollback.get("accepted", false)) \
					and _inventory_result_is(inventory_rollback, 3, reservation_id, quantity) \
					and _inventory_authority.inventory_revision(_inventory_id) == predecessor_revision:
				_remove_pending(record)
				return _outcome_from_record(record, &"reload_publish_rolled_back", {
					"accepted": false,
					"reason": &"inventory_publish_failed",
				})
		return _latch_recovery(
			&"inventory_publish_failed_after_weapon_commit", record, inventory_published)

	var weapon_published := _weapon_port.publish_reload(reservation_id)
	if not bool(weapon_published.get("accepted", false)):
		return _latch_recovery(
			&"weapon_publication_failed_after_canonical_commit", record, weapon_published)
	record["stage"] = STAGE_COMMITTED
	record["inventory_predecessor_revision"] = predecessor_revision
	record["inventory_successor_revision"] = int(inventory_published.get("revision", -1))
	record["weapon_successor_revision"] = int(completion.get("revision", -1))
	record["completion"] = completion.duplicate(true)
	_remove_pending(record)
	return _outcome_from_record(record, &"reload_committed", {
		"accepted": true,
		"inventory_publication": inventory_published,
		"weapon_completion": completion,
	})


func _cancel_record(
	record: Dictionary,
	tick: int,
	reason: StringName,
	request_id: String,
	expected_weapon_revision: int
) -> Dictionary:
	var reservation_id := String(record["reservation_id"])
	if StringName(record.get("stage", &"")) == STAGE_CANCEL_PENDING:
		return _retry_pending_release(record)
	if StringName(record.get("stage", &"")) != STAGE_HELD:
		return _outcome_from_record(record, &"reload_cancel_rejected", {
			"accepted": false,
			"reason": &"reload_stage_not_cancellable",
		})
	var weapon_id := String(record["weapon_id"])
	var current_weapon := _weapon_port.snapshot(weapon_id)
	if current_weapon.is_empty():
		# A missing instance cannot prove whether the held ammunition was loaded
		# before removal. Releasing it could duplicate rounds in another owner.
		return _latch_recovery(
			&"weapon_missing_during_reload_cancel", record,
			{"weapon_id": weapon_id, "reservation_id": reservation_id})
	if not _weapon_snapshot_matches_record(current_weapon, record):
		return _latch_recovery(
			&"weapon_identity_ambiguous_during_reload_cancel", record, current_weapon)
	var weapon_cancel: Dictionary = {
		"accepted": true,
		"replayed": true,
		"reservation_to_release": reservation_id,
	}
	var phase := String(current_weapon.get("phase", ""))
	if phase == "ready":
		if not _ready_weapon_proves_external_cancel(record, current_weapon):
			var ready_reason := &"weapon_ready_state_ambiguous_during_reload_cancel"
			if int(current_weapon.get("loaded_rounds", -1)) \
					!= int(record.get("weapon_pre_reload_loaded_rounds", -2)) \
					or (current_weapon.get("loaded_profile", {}) as Dictionary) \
						!= (record.get("weapon_pre_reload_loaded_profile", {}) as Dictionary):
				ready_reason = &"weapon_completed_outside_reload_transaction"
			return _latch_recovery(ready_reason, record, current_weapon)
		if expected_weapon_revision != int(current_weapon.get("revision", -1)):
			return _outcome_from_record(record, &"reload_cancel_rejected", {
				"accepted": false,
				"reason": &"weapon_revision_stale",
			})
		weapon_cancel["proof"] = &"externally_cancelled_unchanged"
		weapon_cancel["revision"] = int(current_weapon.get("revision", -1))
	elif phase == "reloading":
		var reload_state := current_weapon.get("reload", {}) as Dictionary
		if String(reload_state.get("reservation_id", "")) != reservation_id:
			return _latch_recovery(
				&"weapon_reload_reservation_ambiguous_during_cancel", record, current_weapon)
		if int(current_weapon.get("revision", -1)) \
				!= int(record.get("weapon_reload_revision", -2)) \
				or int(current_weapon.get("loaded_rounds", -1)) \
					!= int(record.get("weapon_pre_reload_loaded_rounds", -2)) \
				or (current_weapon.get("loaded_profile", {}) as Dictionary) \
					!= (record.get("weapon_pre_reload_loaded_profile", {}) as Dictionary):
			return _latch_recovery(
				&"weapon_reload_state_ambiguous_during_cancel", record, current_weapon)
		if expected_weapon_revision != int(current_weapon.get("revision", -1)):
			return _outcome_from_record(record, &"reload_cancel_rejected", {
				"accepted": false,
				"reason": &"weapon_revision_stale",
			})
		var sequence := _reserve_sequence(weapon_id)
		if sequence <= 0:
			return _outcome_from_record(record, &"reload_cancel_rejected", {
				"accepted": false,
				"reason": &"weapon_sequence_exhausted",
			})
		weapon_cancel = _weapon_port.cancel_reload({
			"command_id": _derive_command_id("cancel", reservation_id, request_id),
			"sequence": sequence,
			"instance_id": weapon_id,
			"expected_revision": expected_weapon_revision,
			"tick": tick,
			"authority_scope": _admission.raid_id.canonical_key(),
			"authority_epoch": _admission.authority_epoch,
		})
		if not bool(weapon_cancel.get("accepted", false)):
			return _outcome_from_record(record, &"reload_cancel_rejected", {
				"accepted": false,
				"reason": &"weapon_cancel_rejected",
				"weapon": weapon_cancel,
			})
		if String(weapon_cancel.get("reservation_to_release", "")) != reservation_id:
			return _latch_recovery(&"weapon_cancel_reservation_mismatch", record, weapon_cancel)
	else:
		return _latch_recovery(
			&"weapon_phase_ambiguous_during_reload_cancel", record, current_weapon)

	var released: Dictionary = _inventory_authority.release_quantity_reservation(
		_inventory_id, reservation_id)
	if not _inventory_result_is(released, 3, reservation_id, int(record["quantity"])):
		record["stage"] = STAGE_CANCEL_PENDING
		record["cancel_reason"] = reason
		record["cancel_request_id"] = request_id
		record["weapon_cancel"] = weapon_cancel.duplicate(true)
		_pending_by_reservation[reservation_id] = record
		return _outcome_from_record(record, &"reload_cancel_pending", {
			"accepted": false,
			"reason": &"inventory_release_pending",
			"weapon": weapon_cancel,
			"inventory": released,
		})
	record["stage"] = STAGE_RELEASED
	record["cancel_reason"] = reason
	_remove_pending(record)
	return _outcome_from_record(record, &"reload_cancelled", {
		"accepted": true,
		"weapon": weapon_cancel,
		"inventory": released,
	})


func _retry_pending_release(record: Dictionary) -> Dictionary:
	var reservation_id := String(record["reservation_id"])
	var health: Dictionary = _inventory_authority.health_quantity_reservation(reservation_id)
	# Inventory unload/replacement clears scoped reservations. If the exact
	# bound inventory is no longer live, its lifecycle itself proved the hold
	# cannot commit; otherwise a missing record is an invariant breach.
	if not bool(health.get("accepted", false)) \
			and not _inventory_authority.has_inventory(_inventory_id):
		_remove_pending(record)
		return _outcome_from_record(record, &"reload_cancelled_by_inventory_lifecycle", {
			"accepted": true,
			"replayed": true,
		})
	var released: Dictionary = _inventory_authority.release_quantity_reservation(
		_inventory_id, reservation_id)
	if not _inventory_result_is(released, 3, reservation_id, int(record["quantity"])):
		return _outcome_from_record(record, &"reload_cancel_pending", {
			"accepted": false,
			"reason": &"inventory_release_pending",
			"inventory": released,
		})
	record["stage"] = STAGE_RELEASED
	_remove_pending(record)
	return _outcome_from_record(record, &"reload_cancelled", {
		"accepted": true,
		"inventory": released,
	})


func _cancel_started_record(record: Dictionary, tick: int, reason: StringName) -> Dictionary:
	var weapon := _weapon_port.snapshot(String(record["weapon_id"]))
	return _cancel_record(
		record,
		tick,
		reason,
		_derive_internal_request_id(record, reason),
		int(weapon.get("revision", -1))
	)


func _cancel_weapon_after_rollback(record: Dictionary, tick: int) -> Dictionary:
	var weapon_id := String(record["weapon_id"])
	var weapon := _weapon_port.snapshot(weapon_id)
	if weapon.is_empty() or String(weapon.get("phase", "")) == "ready":
		return {"accepted": true, "replayed": true}
	var sequence := _reserve_sequence(weapon_id)
	if sequence <= 0:
		return _rejection(&"weapon_sequence_exhausted")
	var result := _weapon_port.cancel_reload({
		"command_id": _derive_command_id(
			"rollback_cancel", String(record["reservation_id"]), String(record["begin_request_id"])),
		"sequence": sequence,
		"instance_id": weapon_id,
		"expected_revision": int(weapon.get("revision", -1)),
		"tick": tick,
		"authority_scope": _admission.raid_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
	})
	if bool(result.get("accepted", false)) \
			and String(result.get("reservation_to_release", "")) == String(record["reservation_id"]):
		return result
	return _rejection(&"weapon_cancel_after_rollback_rejected", result)


func _build_pending_record(
	intent: Dictionary,
	mapping: Dictionary,
	binding: Dictionary,
	weapon_snapshot: Dictionary,
	reservation_id: String,
	quantity: int,
	tick: int,
	deadline_tick: int,
	sequence: int,
	command_id: String,
	prepared: Dictionary
) -> Dictionary:
	return {
		"stage": STAGE_HELD,
		"begin_request_id": String(intent["request_id"]),
		"reservation_id": reservation_id,
		"raid_id": _admission.raid_id.canonical_key(),
		"session_id": _admission.session_id.canonical_key(),
		"actor_id": _admission.actor_id.canonical_key(),
		"authority_epoch": _admission.authority_epoch,
		"admission_generation": _admission.generation,
		"owner_generation": _owner_generation,
		"adapter_generation": _adapter_generation,
		"inventory_authority_instance_id": _inventory_authority_instance_id,
		"inventory_id": _inventory_id,
		"inventory_prepare_revision": int(prepared.get("revision", -1)),
		"reservation_lines": (prepared.get("lines", []) as Array).duplicate(true),
		"weapon_port_token": _weapon_port_token,
		"weapon_id": String(intent["weapon_id"]),
		"weapon_binding_generation": int(binding["binding_generation"]),
		"native_item_id": int(mapping["native_item_id"]),
		"weapon_definition": String(mapping["combat_definition_identifier"]),
		"weapon_definition_version": int(weapon_snapshot.get("definition_version", 0)),
		"weapon_ready_revision": int(weapon_snapshot.get("revision", -1)),
		"weapon_pre_reload_loaded_rounds": int(weapon_snapshot.get("loaded_rounds", -1)),
		"weapon_pre_reload_loaded_profile": (
			weapon_snapshot.get("loaded_profile", {}) as Dictionary).duplicate(true),
		"weapon_pre_reload_last_command_sequence": int(
			weapon_snapshot.get("last_command_sequence", 0)),
		"weapon_pre_reload_sequence_high_watermark": int(
			weapon_snapshot.get("admitted_sequence_high_watermark", 0)),
		"weapon_reload_revision": -1,
		"begin_sequence": sequence,
		"begin_command_id": command_id,
		"ammo_trait": String(ZerkovCombatContent.AMMO_TRAIT_762X39),
		"ammo_profile": _ammo_profile(),
		"container_priority": _container_priority_strings(),
		"quantity": quantity,
		"start_tick": tick,
		"due_tick": -1,
		"deadline_tick": deadline_tick,
		"commit_capability": int(_weapon_port.commit_capability()),
		"single_writer_required": true,
		"crash_restart_atomic": false,
	}


func _validate_mapping(mapping: Dictionary) -> Dictionary:
	var required := PackedStringArray([
		"slot_identifier",
		"native_inventory_id",
		"native_item_id",
		"item_definition_identifier",
		"combat_definition_identifier",
		"weapon_kind",
		"weapon_id",
		"entity_id",
	])
	for key in required:
		if not mapping.has(key):
			return {"ok": false, "reason": &"weapon_mapping_schema_invalid"}
	var weapon_id := ZWeaponId.parse(String(mapping.get("weapon_id", "")))
	var entity_id := ZEntityId.parse(String(mapping.get("entity_id", "")))
	if weapon_id == null or entity_id == null:
		return {"ok": false, "reason": &"weapon_mapping_identity_invalid"}
	if int(mapping.get("native_inventory_id", 0)) != _inventory_id \
			or int(mapping.get("native_item_id", 0)) <= 0 \
			or StringName(mapping.get("slot_identifier", &"")) \
				!= EquippedItemReconciler.SLOT_PRIMARY \
			or StringName(mapping.get("item_definition_identifier", &"")) \
				!= ZerkovInventoryCatalog.ITEM_AKM \
			or StringName(mapping.get("combat_definition_identifier", &"")) \
				!= ZerkovCombatContent.WEAPON_AKM \
			or StringName(mapping.get("weapon_kind", &"")) \
				!= EquippedItemReconciler.WEAPON_KIND_FIREARM:
		return {"ok": false, "reason": &"weapon_mapping_content_invalid"}
	var expected_identities := EquippedItemReconciler.derive_identity_keys(
		_admission,
		_owner_generation,
		_inventory_id,
		int(mapping.get("native_item_id", 0)),
		ZerkovInventoryCatalog.ITEM_AKM)
	if expected_identities.is_empty() \
			or String(mapping.get("weapon_id", "")) \
				!= String(expected_identities.get("weapon_id", "")) \
			or String(mapping.get("entity_id", "")) \
				!= String(expected_identities.get("entity_id", "")):
		return {"ok": false, "reason": &"weapon_mapping_identity_not_authoritative"}
	var snapshot := _inventory_authority.snapshot(_inventory_id)
	if snapshot == null or not _mapping_is_equipped(snapshot, mapping):
		return {"ok": false, "reason": &"weapon_mapping_not_equipped"}
	return {"ok": true}


func _validate_begin_intent(intent: Dictionary) -> Dictionary:
	var expected := PackedStringArray([
		"request_id",
		"weapon_id",
		"weapon_binding_generation",
		"adapter_generation",
		"authority_epoch",
		"inventory_id",
		"expected_inventory_revision",
		"expected_weapon_revision",
		"tick",
	])
	if not _has_exact_keys(intent, expected):
		return {"ok": false, "reason": &"reload_intent_schema_invalid"}
	if ZRequestId.parse(String(intent.get("request_id", ""))) == null \
			or ZWeaponId.parse(String(intent.get("weapon_id", ""))) == null:
		return {"ok": false, "reason": &"reload_intent_identity_invalid"}
	for key in [
		"weapon_binding_generation", "adapter_generation", "authority_epoch",
		"inventory_id", "expected_inventory_revision", "expected_weapon_revision", "tick",
	]:
		if typeof(intent.get(key)) != TYPE_INT:
			return {"ok": false, "reason": &"reload_intent_numeric_invalid"}
	if int(intent["weapon_binding_generation"]) <= 0 \
			or int(intent["adapter_generation"]) <= 0 \
			or int(intent["authority_epoch"]) <= 0 \
			or int(intent["inventory_id"]) <= 0 \
			or int(intent["expected_inventory_revision"]) < 0 \
			or int(intent["expected_weapon_revision"]) < 0:
		return {"ok": false, "reason": &"reload_intent_numeric_invalid"}
	if not _has_receipt_capacity():
		return {"ok": false, "reason": &"request_receipt_limit"}
	return {"ok": true}


func _validate_cancel_intent(intent: Dictionary) -> Dictionary:
	var expected := PackedStringArray([
		"request_id",
		"weapon_id",
		"weapon_binding_generation",
		"adapter_generation",
		"authority_epoch",
		"inventory_id",
		"expected_weapon_revision",
		"tick",
		"reason",
	])
	if not _has_exact_keys(intent, expected):
		return {"ok": false, "reason": &"cancel_intent_schema_invalid"}
	if ZRequestId.parse(String(intent.get("request_id", ""))) == null \
			or ZWeaponId.parse(String(intent.get("weapon_id", ""))) == null:
		return {"ok": false, "reason": &"cancel_intent_identity_invalid"}
	for key in [
		"weapon_binding_generation", "adapter_generation", "authority_epoch",
		"inventory_id", "expected_weapon_revision", "tick",
	]:
		if typeof(intent.get(key)) != TYPE_INT:
			return {"ok": false, "reason": &"cancel_intent_numeric_invalid"}
	if int(intent["weapon_binding_generation"]) <= 0 \
			or int(intent["adapter_generation"]) <= 0 \
			or int(intent["authority_epoch"]) <= 0 \
			or int(intent["inventory_id"]) <= 0 \
			or int(intent["expected_weapon_revision"]) < 0 \
			or int(intent["tick"]) < 0 \
			or int(intent["tick"]) > MAX_AUTHORITY_TICK:
		return {"ok": false, "reason": &"cancel_intent_numeric_invalid"}
	if not [&"user_cancel", &"input_cancel"].has(StringName(intent.get("reason", &""))):
		return {"ok": false, "reason": &"cancel_reason_invalid"}
	if not _has_receipt_capacity():
		return {"ok": false, "reason": &"request_receipt_limit"}
	return {"ok": true}


func _intent_matches_context_and_binding(intent: Dictionary, binding: Dictionary) -> bool:
	return not binding.is_empty() \
		and int(intent.get("adapter_generation", 0)) == _adapter_generation \
		and int(intent.get("authority_epoch", 0)) == _admission.authority_epoch \
		and int(intent.get("inventory_id", 0)) == _inventory_id \
		and int(intent.get("weapon_binding_generation", 0)) \
			== int(binding.get("binding_generation", -1))


func _weapon_snapshot_matches_mapping(snapshot: Dictionary, mapping: Dictionary) -> bool:
	return not snapshot.is_empty() \
		and String(snapshot.get("instance_id", "")) == String(mapping.get("weapon_id", "")) \
		and StringName(snapshot.get("definition_id", &"")) \
			== ZerkovCombatContent.WEAPON_AKM \
		and int(snapshot.get("definition_version", 0)) == ZerkovCombatContent.CONTENT_VERSION \
		and String(snapshot.get("authority_scope", "")) == _admission.raid_id.canonical_key() \
		and int(snapshot.get("authority_epoch", 0)) == _admission.authority_epoch \
		and not bool(snapshot.get("tick_unhealthy", true))


func _weapon_snapshot_matches_record(snapshot: Dictionary, record: Dictionary) -> bool:
	return not snapshot.is_empty() \
		and String(snapshot.get("instance_id", "")) == String(record.get("weapon_id", "")) \
		and String(snapshot.get("definition_id", "")) \
			== String(record.get("weapon_definition", "")) \
		and int(snapshot.get("definition_version", 0)) \
			== int(record.get("weapon_definition_version", -1)) \
		and String(snapshot.get("authority_scope", "")) == String(record.get("raid_id", "")) \
		and int(snapshot.get("authority_epoch", 0)) == int(record.get("authority_epoch", -1)) \
		and not bool(snapshot.get("tick_unhealthy", true))


func _ready_weapon_proves_external_cancel(record: Dictionary, snapshot: Dictionary) -> bool:
	var last_sequence := int(snapshot.get("last_command_sequence", 0))
	return _weapon_snapshot_matches_record(snapshot, record) \
		and String(snapshot.get("phase", "")) == "ready" \
		and (snapshot.get("reload", {}) as Dictionary).is_empty() \
		and int(snapshot.get("revision", -1)) \
			== int(record.get("weapon_reload_revision", -3)) + 1 \
		and int(snapshot.get("loaded_rounds", -1)) \
			== int(record.get("weapon_pre_reload_loaded_rounds", -2)) \
		and (snapshot.get("loaded_profile", {}) as Dictionary) \
			== (record.get("weapon_pre_reload_loaded_profile", {}) as Dictionary) \
		and last_sequence > int(record.get("begin_sequence", 0)) \
		and int(snapshot.get("admitted_sequence_high_watermark", 0)) == last_sequence


func _ready_weapon_proves_begin_never_started(record: Dictionary, snapshot: Dictionary) -> bool:
	return _weapon_snapshot_matches_record(snapshot, record) \
		and int(record.get("weapon_reload_revision", -1)) < 0 \
		and String(snapshot.get("phase", "")) == "ready" \
		and (snapshot.get("reload", {}) as Dictionary).is_empty() \
		and int(snapshot.get("revision", -1)) == int(record.get("weapon_ready_revision", -2)) \
		and int(snapshot.get("loaded_rounds", -1)) \
			== int(record.get("weapon_pre_reload_loaded_rounds", -2)) \
		and (snapshot.get("loaded_profile", {}) as Dictionary) \
			== (record.get("weapon_pre_reload_loaded_profile", {}) as Dictionary) \
		and int(snapshot.get("last_command_sequence", 0)) \
			== int(record.get("weapon_pre_reload_last_command_sequence", -1)) \
		and int(snapshot.get("admitted_sequence_high_watermark", 0)) \
			== int(record.get("weapon_pre_reload_sequence_high_watermark", -1))


func _mapping_is_equipped(snapshot: InventorySnapshotResource, mapping: Dictionary) -> bool:
	if snapshot == null or snapshot.get_inventory_id() != _inventory_id \
			or StringName(snapshot.get_profile_identifier()) \
				!= ZerkovInventoryCatalog.PROFILE_PLAYER_RAID:
		return false
	var equipment_container_id := 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get("container_definition_identifier", "")) \
					== ZerkovInventoryCatalog.CONTAINER_EQUIPMENT:
			if equipment_container_id != 0:
				return false
			equipment_container_id = int(container.get("id", 0))
	if equipment_container_id <= 0:
		return false
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) != int(mapping.get("native_item_id", 0)):
			continue
		var location := item.get("location", {}) as Dictionary
		return int(item.get("quantity", 0)) == 1 \
			and StringName(item.get("item_definition_identifier", &"")) \
				== ZerkovInventoryCatalog.ITEM_AKM \
			and String(location.get("kind", "")) == "slot" \
			and int(location.get("container", 0)) == equipment_container_id \
			and StringName(location.get("slot_identifier", &"")) \
				== EquippedItemReconciler.SLOT_PRIMARY
	return false


func _available_ammunition(snapshot: InventorySnapshotResource) -> int:
	var container_definitions: Dictionary = {}
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		container_definitions[int(container.get("id", 0))] = StringName(
			container.get("container_definition_identifier", &""))
	var available := 0
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if StringName(item.get("item_definition_identifier", &"")) \
				!= ZerkovInventoryCatalog.ITEM_AMMO_762:
			continue
		var location := item.get("location", {}) as Dictionary
		var definition := StringName(container_definitions.get(
			int(location.get("container", 0)), &""))
		if AKM_CONTAINER_PRIORITY.has(definition):
			available += maxi(0, int(item.get("quantity", 0)))
	return available


func _loaded_profile_is_compatible(snapshot: Dictionary) -> bool:
	if int(snapshot.get("loaded_rounds", 0)) == 0:
		return true
	return _profile_matches(snapshot.get("loaded_profile", {}) as Dictionary)


func _profile_matches(profile: Dictionary) -> bool:
	return bool(profile.get("has_profile", true)) \
		and StringName(profile.get("id", &"")) \
			== ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD \
		and int(profile.get("version", 0)) == ZerkovCombatContent.CONTENT_VERSION


func _candidate_matches_record(
	candidate: Dictionary,
	record: Dictionary,
	weapon_before: Dictionary
) -> bool:
	return String(candidate.get("instance_id", "")) == String(record["weapon_id"]) \
		and String(candidate.get("reservation_id", "")) == String(record["reservation_id"]) \
		and int(candidate.get("added_rounds", -1)) == int(record["quantity"]) \
		and int(candidate.get("revision", -1)) == int(weapon_before.get("revision", -2)) + 1 \
		and int(candidate.get("loaded_rounds", -1)) \
			== int(weapon_before.get("loaded_rounds", -2)) + int(record["quantity"]) \
		and _profile_matches(candidate.get("profile", {}) as Dictionary)


func _candidate_matches_completion(candidate: Dictionary, completion: Dictionary) -> bool:
	return String(candidate.get("instance_id", "")) == String(completion.get("instance_id", "")) \
		and String(candidate.get("reservation_id", "")) \
			== String(completion.get("reservation_id", "")) \
		and int(candidate.get("added_rounds", -1)) == int(completion.get("added_rounds", -2)) \
		and int(candidate.get("revision", -1)) == int(completion.get("revision", -2)) \
		and int(candidate.get("loaded_rounds", -1)) \
			== int(completion.get("loaded_rounds", -2)) \
		and _profile_matches(completion.get("profile", {}) as Dictionary)


func _inventory_result_is(
	result: Dictionary,
	stage: int,
	reservation_id: String,
	quantity: int
) -> bool:
	return bool(result.get("accepted", false)) \
		and int(result.get("stage", -1)) == stage \
		and String(result.get("reservation_id", "")) == reservation_id \
		and int(result.get("inventory_id", 0)) == _inventory_id \
		and int(result.get("quantity", -1)) == quantity


func _reserve_sequence(weapon_id: String) -> int:
	var binding := _bindings.get(weapon_id, {}) as Dictionary
	var next_sequence := int(binding.get("next_sequence", 0))
	if next_sequence <= 0 or next_sequence > MAX_AUTHORITY_TICK:
		return 0
	# Reserve before entering the native call. Synchronous signal reentry can
	# never observe or reuse this identity.
	binding["next_sequence"] = next_sequence + 1
	_bindings[weapon_id] = binding
	return next_sequence


func _remove_pending(record: Dictionary) -> void:
	var weapon_id := String(record.get("weapon_id", ""))
	var reservation_id := String(record.get("reservation_id", ""))
	if String(_pending_by_weapon.get(weapon_id, "")) == reservation_id:
		_pending_by_weapon.erase(weapon_id)
	_pending_by_reservation.erase(reservation_id)
	var begin_request_id := String(record.get("begin_request_id", ""))
	if _request_receipts.has(begin_request_id):
		var receipt_record := _request_receipts[begin_request_id] as Dictionary
		receipt_record["active"] = false
		_request_receipts[begin_request_id] = receipt_record
	_trim_receipts()


func _request_replay(intent: Dictionary) -> Dictionary:
	# Completed receipts are generation-scoped. Preserve synchronous publication
	# replay while the exact binding is current, but never answer from an
	# invalidated/deferred-stale adapter merely because this check precedes the
	# normal mutation gate.
	if lifecycle != Lifecycle.BOUND \
			or not _deferred_invalidation_reason.is_empty() \
			or not _binding_is_current():
		return {}
	var request_id := String(intent.get("request_id", ""))
	if request_id.is_empty() or not _request_receipts.has(request_id):
		return {}
	var existing := _request_receipts[request_id] as Dictionary
	if String(existing.get("digest", "")) != ZCanonicalValue.sha256(intent):
		return _rejection(&"request_id_payload_conflict")
	var result := (existing.get("receipt", {}) as Dictionary).duplicate(true)
	result["replayed"] = true
	return result


func _remember_request(intent: Dictionary, result: Dictionary, active: bool) -> void:
	var request_id := String(intent.get("request_id", ""))
	if ZRequestId.parse(request_id) == null or _request_receipts.has(request_id):
		return
	_request_receipts[request_id] = {
		"digest": ZCanonicalValue.sha256(intent),
		"receipt": result.duplicate(true),
		"active": active,
	}
	_receipt_order.append(request_id)
	_trim_receipts()


func _remember_rejection(
	intent: Dictionary,
	reason: StringName,
	details: Dictionary = {}
) -> Dictionary:
	var result := _rejection(reason, details)
	_remember_request(intent, result, false)
	return result


func _has_receipt_capacity() -> bool:
	_trim_receipts()
	return _request_receipts.size() < MAX_REQUEST_RECEIPTS


func _trim_receipts() -> void:
	var retained := PackedStringArray()
	for request_id in _receipt_order:
		if _request_receipts.size() < MAX_REQUEST_RECEIPTS:
			retained.append(request_id)
			continue
		var record := _request_receipts.get(request_id, {}) as Dictionary
		if not bool(record.get("active", false)):
			_request_receipts.erase(request_id)
		else:
			retained.append(request_id)
	_receipt_order = retained


func _outcome_from_record(
	record: Dictionary,
	kind: StringName,
	extra: Dictionary = {}
) -> Dictionary:
	var result := {
		"accepted": bool(extra.get("accepted", true)),
		"replayed": bool(extra.get("replayed", false)),
		"kind": kind,
		"reason": extra.get("reason", &""),
		"reservation_id": String(record.get("reservation_id", "")),
		"raid_id": String(record.get("raid_id", "")),
		"session_id": String(record.get("session_id", "")),
		"actor_id": String(record.get("actor_id", "")),
		"authority_epoch": int(record.get("authority_epoch", 0)),
		"admission_generation": int(record.get("admission_generation", 0)),
		"owner_generation": int(record.get("owner_generation", 0)),
		"adapter_generation": int(record.get("adapter_generation", 0)),
		"inventory_id": int(record.get("inventory_id", 0)),
		"weapon_id": String(record.get("weapon_id", "")),
		"weapon_binding_generation": int(record.get("weapon_binding_generation", 0)),
		"native_item_id": int(record.get("native_item_id", 0)),
		"ammo_trait": String(record.get("ammo_trait", "")),
		"ammo_profile": (record.get("ammo_profile", {}) as Dictionary).duplicate(true),
		"container_priority": (record.get("container_priority", []) as Array).duplicate(true),
		"quantity": int(record.get("quantity", 0)),
		"start_tick": int(record.get("start_tick", -1)),
		"due_tick": int(record.get("due_tick", -1)),
		"stage": record.get("stage", &""),
		"commit_capability": int(record.get("commit_capability", 0)),
		"single_writer_required": true,
		"crash_restart_atomic": false,
	}
	for key in extra.keys():
		if key == "accepted" or key == "replayed" or key == "reason":
			continue
		result[key] = _duplicate_variant(extra[key])
	return result


func _latch_recovery(
	reason: StringName,
	record: Dictionary,
	details: Dictionary
) -> Dictionary:
	lifecycle = Lifecycle.RECOVERY_REQUIRED
	last_error = reason
	if not record.is_empty():
		record["stage"] = STAGE_RECOVERY
		var reservation_id := String(record.get("reservation_id", ""))
		if not reservation_id.is_empty():
			_pending_by_reservation[reservation_id] = record
	_recovery_details = {
		"reason": reason,
		"record": record.duplicate(true),
		"details": details.duplicate(true),
		"new_reload_forbidden": true,
		"requires_authoritative_recovery": true,
	}
	return _outcome_from_record(record, &"reload_recovery_required", {
		"accepted": false,
		"reason": reason,
		"details": details,
		"new_reload_forbidden": true,
	})


func _rejection(reason: StringName, details: Dictionary = {}) -> Dictionary:
	return {
		"accepted": false,
		"replayed": false,
		"kind": &"reload_rejected",
		"reason": reason,
		"details": details.duplicate(true),
	}


func _reject_bool(reason: StringName) -> bool:
	last_error = reason
	return false


func _reject_bind(reason: StringName) -> bool:
	last_error = reason
	return false


func _can_mutate() -> bool:
	if _transaction_active:
		last_error = &"reload_transaction_active"
		return false
	if _public_signal_active:
		last_error = &"reload_publication_active"
		return false
	if lifecycle == Lifecycle.RECOVERY_REQUIRED:
		last_error = &"reload_recovery_required"
		return false
	if lifecycle != Lifecycle.BOUND:
		last_error = &"adapter_not_bound"
		return false
	if not _binding_is_current():
		_resolve_stale_binding(0)
		if last_error.is_empty():
			last_error = &"adapter_binding_stale"
		return false
	return true


func _binding_is_current() -> bool:
	return _inventory_binding_is_current() and _weapon_binding_is_current()


func _inventory_binding_is_current() -> bool:
	return _owner != null \
		and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.is_current_generation(_owner_generation) \
		and _inventory_runtime_is_live() \
		and _owner.raid_authority() == _inventory_authority \
		and _owner.raid_player_inventory_id == _inventory_id


func _inventory_runtime_is_live() -> bool:
	return _inventory_authority != null \
		and is_instance_valid(_inventory_authority) \
		and _inventory_authority.get_instance_id() == _inventory_authority_instance_id \
		and _inventory_authority.has_inventory(_inventory_id)


func _weapon_binding_is_current() -> bool:
	return _weapon_port != null \
		and _weapon_port.is_ready() \
		and _weapon_port.identity_token() == _weapon_port_token


func _resolve_stale_binding(tick: int) -> void:
	if lifecycle != Lifecycle.BOUND:
		return
	if not _inventory_runtime_is_live():
		_invalidate_after_external_lifecycle(&"authority_invalidation", tick)
		return
	if _pending_by_reservation.is_empty():
		_disconnect_inventory_lifecycle()
		lifecycle = Lifecycle.INVALIDATED
		last_error = &"adapter_binding_stale"
		_generation_counter += 1
		_adapter_generation = _generation_counter
		_bindings.clear()
		_pending_by_weapon.clear()
		_pending_by_reservation.clear()
		_clear_reload_request_receipts()
		_emit_invalidation(last_error)
		return

	# The exact inventory runtime and its HELD quantity reservation still exist.
	# A stale weapon port/token or owner pointer cannot prove whether rounds were
	# loaded, so clearing coordinator state or releasing inventory would risk a
	# duplicate. Retain both under a terminal recovery latch.
	var reservation_ids := PackedStringArray(_pending_by_reservation.keys())
	reservation_ids.sort()
	var record := _pending_by_reservation[String(reservation_ids[0])] as Dictionary
	var reason := &"weapon_binding_invalid_with_live_inventory" \
		if not _weapon_binding_is_current() \
		else &"inventory_binding_invalid_with_live_inventory"
	var recovery := _latch_recovery(reason, record, {
		"inventory_runtime_live": true,
		"inventory_binding_current": _inventory_binding_is_current(),
		"weapon_binding_current": _weapon_binding_is_current(),
		"expected_weapon_port_token": _weapon_port_token,
		"observed_weapon_port_token": _weapon_port.identity_token() \
			if _weapon_port != null and _weapon_port.is_ready() else "",
	})
	_emit_outcome(recovery)


func _connect_inventory_lifecycle() -> void:
	_inventory_unloaded_callback = Callable(self, "_on_inventory_unloaded")
	_inventory_generation_callback = Callable(self, "_on_inventory_generation_changing")
	_inventory_authority.inventory_unloaded.connect(_inventory_unloaded_callback)
	_inventory_authority.inventory_generation_changing.connect(_inventory_generation_callback)


func _disconnect_inventory_lifecycle() -> void:
	if _inventory_authority == null or not is_instance_valid(_inventory_authority):
		return
	if _inventory_unloaded_callback.is_valid() \
			and _inventory_authority.inventory_unloaded.is_connected(_inventory_unloaded_callback):
		_inventory_authority.inventory_unloaded.disconnect(_inventory_unloaded_callback)
	if _inventory_generation_callback.is_valid() \
			and _inventory_authority.inventory_generation_changing.is_connected(
				_inventory_generation_callback):
		_inventory_authority.inventory_generation_changing.disconnect(
				_inventory_generation_callback)


func _on_inventory_unloaded(unloaded_inventory_id: int) -> void:
	if unloaded_inventory_id != _inventory_id:
		return
	_clear_reload_request_receipts()
	if _transaction_active or _public_signal_active:
		_deferred_invalidation_reason = &"authority_invalidation"
		return
	_invalidate_after_external_lifecycle(&"authority_invalidation", 0)


func _on_inventory_generation_changing(changing_inventory_id: int) -> void:
	if changing_inventory_id != _inventory_id:
		return
	_clear_reload_request_receipts()
	if _transaction_active or _public_signal_active:
		_deferred_invalidation_reason = &"authority_invalidation"
		return
	_invalidate_after_external_lifecycle(&"authority_invalidation", 0)


func _invalidate_after_external_lifecycle(reason: StringName, tick: int) -> void:
	if lifecycle != Lifecycle.BOUND:
		return
	_clear_reload_request_receipts()
	# The inventory lifecycle operation clears this inventory's ephemeral
	# reservation ledger. Stop each weapon mechanically so it cannot later
	# complete against a disappeared hold. No inventory mutation is attempted
	# reentrantly from the lifecycle signal.
	_transaction_active = true
	var weapon_ids := PackedStringArray(_pending_by_weapon.keys())
	weapon_ids.sort()
	var cancel_failures: Array[Dictionary] = []
	for weapon_id in weapon_ids:
		var record := _pending_by_reservation.get(
			String(_pending_by_weapon[weapon_id]), {}) as Dictionary
		if record.is_empty() or not _weapon_binding_is_current():
			cancel_failures.append({
				"record": record.duplicate(true),
				"cancel": _rejection(&"weapon_binding_unavailable_during_inventory_lifecycle"),
			})
			continue
		var weapon := _weapon_port.snapshot(weapon_id)
		if weapon.is_empty() or not _weapon_snapshot_matches_record(weapon, record):
			cancel_failures.append({
				"record": record.duplicate(true),
				"cancel": _rejection(&"weapon_state_unproven_during_inventory_lifecycle", weapon),
			})
			continue
		if String(weapon.get("phase", "")) == "ready":
			if not _ready_weapon_proves_external_cancel(record, weapon) \
					and not _ready_weapon_proves_begin_never_started(record, weapon):
				cancel_failures.append({
					"record": record.duplicate(true),
					"cancel": _rejection(
						&"weapon_ready_state_unproven_during_inventory_lifecycle", weapon),
				})
			continue
		if String(weapon.get("phase", "")) != "reloading" \
				or String((weapon.get("reload", {}) as Dictionary).get(
					"reservation_id", "")) != String(record["reservation_id"]):
			cancel_failures.append({
				"record": record.duplicate(true),
				"cancel": _rejection(&"weapon_reload_unproven_during_inventory_lifecycle", weapon),
			})
			continue
		var sequence := _reserve_sequence(weapon_id)
		if sequence <= 0:
			cancel_failures.append({
				"record": record.duplicate(true),
				"cancel": _rejection(&"weapon_sequence_exhausted"),
			})
			continue
		var effective_tick := maxi(
			tick,
			maxi(int(record.get("start_tick", 0)),
				int(weapon.get("authority_tick_floor", 0))))
		var cancelled := _weapon_port.cancel_reload({
			"command_id": _derive_command_id(
				"lifecycle", String(record["reservation_id"]), String(reason)),
			"sequence": sequence,
			"instance_id": weapon_id,
			"expected_revision": int(weapon.get("revision", -1)),
			"tick": effective_tick,
			"authority_scope": _admission.raid_id.canonical_key(),
			"authority_epoch": _admission.authority_epoch,
		})
		if not bool(cancelled.get("accepted", false)) \
				or String(cancelled.get("reservation_to_release", "")) \
					!= String(record["reservation_id"]):
			cancel_failures.append({
				"record": record.duplicate(true),
				"cancel": cancelled.duplicate(true),
			})
	_transaction_active = false
	_disconnect_inventory_lifecycle()
	if not cancel_failures.is_empty():
		var failed_record := cancel_failures[0].get("record", {}) as Dictionary
		var recovery := _latch_recovery(
			&"weapon_cancel_failed_during_inventory_lifecycle", failed_record,
			{"failures": cancel_failures})
		_emit_outcome(recovery)
		return
	lifecycle = Lifecycle.INVALIDATED
	last_error = reason
	_generation_counter += 1
	_adapter_generation = _generation_counter
	_bindings.clear()
	_pending_by_weapon.clear()
	_pending_by_reservation.clear()
	_emit_invalidation(reason)


func _process_deferred_invalidation(tick: int) -> void:
	if _transaction_active or _public_signal_active \
			or _deferred_invalidation_reason.is_empty():
		return
	var reason := _deferred_invalidation_reason
	_deferred_invalidation_reason = &""
	_invalidate_after_external_lifecycle(reason, tick)


func _emit_outcome(outcome: Dictionary) -> void:
	var publication := outcome.duplicate(true)
	_make_deep_read_only(publication)
	_public_signal_active = true
	reload_coordinated.emit(publication)
	_public_signal_active = false
	if lifecycle == Lifecycle.RECOVERY_REQUIRED and not _recovery_signal_emitted:
		var details := _recovery_details.duplicate(true)
		_make_deep_read_only(details)
		_recovery_signal_emitted = true
		_public_signal_active = true
		recovery_latched.emit(last_error, details)
		_public_signal_active = false


func _emit_invalidation(reason: StringName) -> void:
	_public_signal_active = true
	binding_invalidated.emit(reason)
	_public_signal_active = false


func _clear_reload_request_receipts() -> void:
	_request_receipts.clear()
	_receipt_order.clear()


func _reset_unbound_state() -> void:
	_disconnect_inventory_lifecycle()
	lifecycle = Lifecycle.UNBOUND
	last_error = &""
	_owner = null
	_owner_instance_id = 0
	_owner_generation = 0
	_inventory_authority = null
	_inventory_authority_instance_id = 0
	_inventory_id = 0
	_admission = null
	_adapter_generation = 0
	_weapon_port = null
	_weapon_port_token = ""
	_bindings.clear()
	_pending_by_weapon.clear()
	_pending_by_reservation.clear()
	_clear_reload_request_receipts()
	_transaction_active = false
	_public_signal_active = false
	_deferred_invalidation_reason = &""
	_recovery_details.clear()
	_recovery_signal_emitted = false
	_inventory_unloaded_callback = Callable()
	_inventory_generation_callback = Callable()


func _exit_tree() -> void:
	# Normal composition must call release_binding() before owner teardown. This
	# guard still disconnects callbacks and asks the weapon side to stop active
	# reloads; InventoryAuthority itself clears holds when its owner unloads.
	if lifecycle == Lifecycle.BOUND and not _transaction_active:
		release_binding(&"teardown", 0)
	else:
		_disconnect_inventory_lifecycle()


func _derive_internal_request_id(record: Dictionary, reason: StringName) -> String:
	var digest := ZCanonicalValue.sha256({
		"schema": "zerkov.reload.interrupt.v1",
		"reservation_id": String(record.get("reservation_id", "")),
		"reason": String(reason),
	})
	return "zerkov.request.reload_interrupt.%s" % digest.substr(0, 32)


func _derive_command_id(kind: String, reservation_id: String, request_id: String) -> String:
	var digest := ZCanonicalValue.sha256({
		"schema": "zerkov.reload.command.v1",
		"kind": kind,
		"reservation_id": reservation_id,
		"request_id": request_id,
	})
	return "zerkov.reload_%s.%s" % [kind, digest.substr(0, 32)]


func _ammo_profile() -> Dictionary:
	return {
		"id": String(ZerkovCombatContent.AMMO_PROFILE_762X39_STANDARD),
		"version": ZerkovCombatContent.CONTENT_VERSION,
	}


func _container_priority_strings() -> Array:
	var result: Array = []
	for identifier in AKM_CONTAINER_PRIORITY:
		result.append(String(identifier))
	return result


static func _has_exact_keys(value: Dictionary, expected: PackedStringArray) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true


static func _duplicate_variant(value: Variant) -> Variant:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array:
		return (value as Array).duplicate(true)
	return value


static func _make_deep_read_only(value: Variant) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			for key in dictionary.keys():
				_make_deep_read_only(dictionary[key])
			dictionary.make_read_only()
		TYPE_ARRAY:
			var array := value as Array
			for entry in array:
				_make_deep_read_only(entry)
			array.make_read_only()
