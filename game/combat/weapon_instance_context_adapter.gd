class_name WeaponInstanceContextAdapter
extends Node
## Equipped inventory -> Weapon System instance lifecycle and fire context.
##
## InventoryAuthority remains canonical for ownership/equipment, RaidAuthority
## remains canonical for liveness/pose/game usability, and WeaponAuthority
## remains canonical for firearm mechanics. This adapter owns only the binding
## between those facts. It never creates the machete in Weapon System V1 (the
## add-on has no melee mechanism) and it never accepts caller-supplied context.

signal reconciliation_published(outcome: Dictionary)
signal recovery_latched(reason: StringName, details: Dictionary)
signal binding_invalidated(reason: StringName)

enum Lifecycle {
	UNBOUND,
	BOUND,
	RECOVERY_REQUIRED,
	INVALIDATED,
}

const PHASE_HANDLER_ID: StringName = &"weapon_instance_context"
const PHASE_HANDLER_PRIORITY: int = 100
const CONSUMER_PHASE_PRIORITY: int = 200
const NEUTRAL_MODIFIER_PPM: int = 1_000_000
const MAX_TRACKED_FIREARMS: int = 16
# Public Inventory System TransactionEventKind values. REMOVED destroys the
# item, while DROPPED retires its stable native id into value-only custody.
const INVENTORY_EVENT_REMOVED: int = 6
const INVENTORY_EVENT_DROPPED: int = 11

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _reconciler: EquippedItemReconciler
var _reconciler_instance_id: int = 0
var _admission: ZSessionAdmission
var _owner_generation: int = 0
var _scope_generation: int = 0
var _raid_authority: RaidAuthority
var _raid_generation: int = 0
var _weapon_authority: WeaponAuthority
var _weapon_authority_instance_id: int = 0
var _weapon_content_fingerprint: int = 0
var _weapon_port: WeaponAuthorityReloadPort
var _weapon_port_instance_id: int = 0
var _reload_adapter: InventoryWeaponAdapter
var _reload_adapter_instance_id: int = 0
var _binding_generation: int = 0
var _generation_counter: int = 0
var _next_weapon_binding_generation: int = 1
var _records: Dictionary = {}
var _retired_item_ids: Dictionary = {}
var _last_outcome: Dictionary = {}
var _recovery_details: Dictionary = {}
var _public_signal_active: bool = false
var _reconciler_invalidated_callback: Callable
var _inventory_authority: InventoryAuthority
var _inventory_authority_instance_id: int = 0
var _inventory_transaction_callback: Callable
var _phase_registered: bool = false


static func consumer_phase_dependencies() -> PackedStringArray:
	return PackedStringArray([String(PHASE_HANDLER_ID)])


## Binding is setup-only and creates no weapon instance. Instance creation is
## deterministic in RaidAuthority phase 5 after current equipment is known.
func bind_owner(
	owner: RaidInventoryOwner,
	reconciler: EquippedItemReconciler,
	admission: ZSessionAdmission,
	raid_authority: RaidAuthority,
	weapon_authority: WeaponAuthority,
	weapon_port: WeaponAuthorityReloadPort,
	reload_adapter: InventoryWeaponAdapter,
	expected_owner_generation: int,
	expected_scope_generation: int,
	expected_raid_generation: int
) -> bool:
	last_error = &""
	if _public_signal_active:
		return _reject(&"reentrant_binding_change")
	if lifecycle == Lifecycle.BOUND or lifecycle == Lifecycle.RECOVERY_REQUIRED:
		return _reject(&"adapter_already_bound")
	if owner == null or not is_instance_valid(owner) \
			or not owner.is_current_generation(expected_owner_generation):
		return _reject(&"inventory_owner_invalid")
	if reconciler == null or not is_instance_valid(reconciler) \
			or not reconciler.is_bound() \
			or reconciler.owner_generation() != expected_owner_generation \
			or reconciler.scope_generation() != expected_scope_generation \
			or reconciler.player_inventory_id() != owner.raid_player_inventory_id:
		return _reject(&"equipment_reconciler_invalid")
	if admission == null or not admission.is_usable():
		return _reject(&"session_admission_invalid")
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return _reject(&"session_admission_invalid")
	if raid_authority == null or raid_authority.generation() != expected_raid_generation \
			or raid_authority.lifecycle != RaidAuthority.Lifecycle.PREPARING:
		return _reject(&"raid_authority_invalid")
	var authority_admission := raid_authority.admission()
	if authority_admission == null \
			or not authority_admission.raid_id.is_equal(admission_copy.raid_id) \
			or not authority_admission.session_id.is_equal(admission_copy.session_id) \
			or not authority_admission.actor_id.is_equal(admission_copy.actor_id) \
			or authority_admission.authority_epoch != admission_copy.authority_epoch \
			or authority_admission.generation != admission_copy.generation:
		return _reject(&"raid_admission_mismatch")
	if weapon_authority == null or not is_instance_valid(weapon_authority) \
			or not weapon_authority.is_ready():
		return _reject(&"weapon_authority_invalid")
	var content_report := ZerkovCombatContent.validate_resource_bundle()
	var expected_content_fingerprint := int(content_report.get("fingerprint", 0))
	if not bool(content_report.get("ok", false)) or expected_content_fingerprint == 0:
		return _reject(&"weapon_content_contract_invalid")
	if weapon_authority.content_fingerprint() != expected_content_fingerprint:
		return _reject(&"weapon_content_fingerprint_mismatch")
	if weapon_port == null or not is_instance_valid(weapon_port) \
			or not weapon_port.is_ready() \
			or weapon_port.identity_token() \
				!= "weapon_authority:%d" % weapon_authority.get_instance_id():
		return _reject(&"weapon_reload_port_invalid")
	if reload_adapter == null or not is_instance_valid(reload_adapter) \
			or not reload_adapter.is_bound() \
			or reload_adapter.owner_generation() != expected_owner_generation \
			or reload_adapter.inventory_id() != owner.raid_player_inventory_id \
			or reload_adapter.weapon_port_identity_token() != weapon_port.identity_token():
		return _reject(&"inventory_weapon_adapter_invalid")
	var next_binding_generation := _generation_counter + 1
	_reset_unbound_state()
	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_reconciler = reconciler
	_reconciler_instance_id = reconciler.get_instance_id()
	_admission = admission_copy
	_owner_generation = expected_owner_generation
	_scope_generation = expected_scope_generation
	_raid_authority = raid_authority
	_raid_generation = expected_raid_generation
	_weapon_authority = weapon_authority
	_weapon_authority_instance_id = weapon_authority.get_instance_id()
	_weapon_content_fingerprint = expected_content_fingerprint
	_weapon_port = weapon_port
	_weapon_port_instance_id = weapon_port.get_instance_id()
	_reload_adapter = reload_adapter
	_reload_adapter_instance_id = reload_adapter.get_instance_id()
	_inventory_authority = owner.raid_authority()
	_inventory_authority_instance_id = _inventory_authority.get_instance_id()
	if not raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		PHASE_HANDLER_ID,
		Callable(self, "_on_weapon_phase").bind(next_binding_generation),
		expected_raid_generation,
		PHASE_HANDLER_PRIORITY
	):
		var registration_error := raid_authority.last_error
		_reset_unbound_state()
		last_error = registration_error
		return false
	_phase_registered = true
	_generation_counter = next_binding_generation
	_binding_generation = next_binding_generation
	lifecycle = Lifecycle.BOUND
	_reconciler_invalidated_callback = Callable(self, "_on_reconciler_invalidated")
	_reconciler.binding_invalidated.connect(_reconciler_invalidated_callback)
	_inventory_transaction_callback = Callable(
		self, "_on_inventory_transaction_committed").bind(
		_inventory_authority_instance_id, _owner_generation, _binding_generation)
	_inventory_authority.transaction_committed.connect(_inventory_transaction_callback)
	return true


func is_bound() -> bool:
	return lifecycle == Lifecycle.BOUND and _binding_is_current()


func binding_generation() -> int:
	return _binding_generation


func current_outcome() -> Dictionary:
	return _last_outcome.duplicate(true)


func recovery_details() -> Dictionary:
	return _recovery_details.duplicate(true)


func instance_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var weapon_ids := PackedStringArray(_records.keys())
	weapon_ids.sort()
	for weapon_id in weapon_ids:
		result.append((_records[weapon_id] as Dictionary).duplicate(true))
	return result


func weapon_binding_generation(weapon_id: String) -> int:
	var record := _records.get(weapon_id, {}) as Dictionary
	return int(record.get("weapon_binding_generation", 0))


## Called by the phase-5 fire path. Equipment is re-derived from the complete
## current native inventory snapshot; liveness/pose/usability come only from
## RaidAuthority. Missing or stale facts fail closed and no fallback exists.
func authority_context(weapon_id: String, tick: int) -> Dictionary:
	if lifecycle != Lifecycle.BOUND or not _binding_is_current():
		return {"ok": false, "reason": &"weapon_context_binding_stale"}
	var record := _records.get(weapon_id, {}) as Dictionary
	if record.is_empty():
		return {"ok": false, "reason": &"weapon_instance_not_owned"}
	var snapshot := _owner.raid_authority().snapshot(_owner.raid_player_inventory_id)
	if snapshot == null or snapshot.get_revision() != _reconciler.current_revision():
		return {"ok": false, "reason": &"inventory_equipment_snapshot_stale"}
	var item_state := _item_state(snapshot, record)
	if not bool(item_state.get("valid", false)):
		return {"ok": false, "reason": &"weapon_inventory_state_invalid"}
	if not bool(item_state.get("player_owned", false)):
		return {"ok": false, "reason": &"weapon_item_not_owned"}
	var native_snapshot := _weapon_authority.snapshot(weapon_id)
	if not _native_snapshot_matches_record(native_snapshot, record):
		return {"ok": false, "reason": &"weapon_instance_state_mismatch"}
	var actor_facts := _raid_authority.authoritative_weapon_actor_context(
		_admission.actor_id, tick, _raid_generation)
	if not bool(actor_facts.get("ok", false)):
		return {
			"ok": false,
			"reason": actor_facts.get("reason", &"weapon_actor_context_unavailable"),
		}
	var context := {
		"actor_live": bool(actor_facts["actor_live"]),
		"weapon_equipped": bool(item_state["equipped"]),
		"weapon_usable": bool(actor_facts["weapon_usable"])
			and not bool(native_snapshot.get("tick_unhealthy", true)),
		"authoritative_origin":
			(actor_facts["authoritative_origin"] as Dictionary).duplicate(true),
		"authoritative_aim":
			(actor_facts["authoritative_aim"] as Dictionary).duplicate(true),
		"spread_modifier_ppm": NEUTRAL_MODIFIER_PPM,
		"damage_modifier_ppm": NEUTRAL_MODIFIER_PPM,
		"range_modifier_ppm": NEUTRAL_MODIFIER_PPM,
		"noise_modifier_ppm": NEUTRAL_MODIFIER_PPM,
		"recoil_modifier_ppm": NEUTRAL_MODIFIER_PPM,
	}
	var result := {
		"ok": true,
		"weapon_id": weapon_id,
		"native_item_id": int(record["native_item_id"]),
		"inventory_revision": snapshot.get_revision(),
		"weapon_revision": int(native_snapshot.get("revision", -1)),
		"tick": tick,
		"context": context,
	}
	_make_deep_read_only(result)
	return result


## Normal composition releases this adapter before the reload coordinator,
## inventory owner, WeaponAuthority, or RaidAuthority terminalizes.
func release_binding(reason: StringName = &"teardown", tick: int = 0) -> bool:
	last_error = &""
	if _public_signal_active:
		return _reject(&"reentrant_binding_change")
	if lifecycle != Lifecycle.BOUND and lifecycle != Lifecycle.RECOVERY_REQUIRED:
		return _reject(&"adapter_not_bound")
	if not InventoryWeaponAdapter.INTERRUPT_REASONS.has(reason):
		return _reject(&"interrupt_reason_invalid")
	# In the synchronous single-writer runtime this preflight closes every
	# deterministic handler-removal rejection before weapon state is touched.
	if not _preflight_phase_handler_removal():
		return false
	if not _remove_all_owned_instances(reason, tick):
		return false
	if not _unregister_phase_handler():
		return false
	_disconnect_reconciler()
	_disconnect_inventory_transactions()
	lifecycle = Lifecycle.INVALIDATED
	last_error = reason
	_generation_counter += 1
	_binding_generation = _generation_counter
	_emit_invalidation(reason)
	return true


func _on_weapon_phase(
	authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent],
	expected_binding_generation: int
) -> bool:
	if expected_binding_generation != _binding_generation \
			or lifecycle == Lifecycle.INVALIDATED:
		return true
	if authority != _raid_authority \
			or phase != RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS:
		return _reject(&"weapon_phase_context_invalid")
	var outcome := _reconcile_current(tick)
	return bool(outcome.get("accepted", false))


func _reconcile_current(tick: int) -> Dictionary:
	last_error = &""
	if lifecycle != Lifecycle.BOUND or not _binding_is_current():
		return _reconciliation_rejection(&"weapon_context_binding_stale")
	var snapshot := _owner.raid_authority().snapshot(_owner.raid_player_inventory_id)
	if snapshot == null or snapshot.get_revision() != _reconciler.current_revision():
		return _reconciliation_rejection(&"inventory_equipment_snapshot_stale")
	var active_firearms: Dictionary = {}
	var deferred_melee: Array[Dictionary] = []
	for mapping_value in _reconciler.current_mappings():
		var mapping := mapping_value as Dictionary
		var kind := StringName(mapping.get("weapon_kind", &""))
		if kind == EquippedItemReconciler.WEAPON_KIND_MELEE:
			deferred_melee.append(mapping.duplicate(true))
			continue
		if not _mapping_is_authoritative_firearm(mapping):
			return _reconciliation_rejection(&"equipped_firearm_mapping_invalid")
		var weapon_id := String(mapping["weapon_id"])
		if active_firearms.has(weapon_id):
			return _reconciliation_rejection(&"equipped_firearm_mapping_duplicate")
		active_firearms[weapon_id] = mapping.duplicate(true)

	var added: Array[Dictionary] = []
	var retained: Array[Dictionary] = []
	var dormant: Array[Dictionary] = []
	var parked: Array[Dictionary] = []
	var removed: Array[Dictionary] = []
	# Capacity is an admission preflight, not a bookkeeping side effect. Inspect
	# every inactive record first and prove how many destroyed records will leave
	# before changing a public record, reload binding, or native instance. A
	# rejected seventeenth stable identity therefore cannot advance the sixteen
	# retained records while _last_outcome still describes the preceding tick.
	var tracked_ids := PackedStringArray(_records.keys())
	tracked_ids.sort()
	var inactive_states: Dictionary = {}
	var destroyed_inactive_count := 0
	for weapon_id in tracked_ids:
		if active_firearms.has(weapon_id):
			continue
		var record := _records[weapon_id] as Dictionary
		var state := _item_state(snapshot, record)
		if not bool(state.get("valid", false)):
			return _latch_recovery(&"weapon_inventory_state_invalid", {
				"record": record,
				"state": state,
			})
		inactive_states[weapon_id] = state.duplicate(true)
		if bool(state.get("destroyed", false)):
			destroyed_inactive_count += 1
	var new_active_count := 0
	for weapon_id in active_firearms:
		if not _records.has(weapon_id):
			new_active_count += 1
	var projected_record_count := _records.size() \
		- destroyed_inactive_count + new_active_count
	if projected_record_count > MAX_TRACKED_FIREARMS:
		return _reconciliation_rejection(&"weapon_instance_limit")

	# Retire or park inactive records before admitting a new native instance.
	# A value-only DROPPED item therefore cannot consume the live stable-id cap
	# on the tick where a replacement becomes equipped.
	for weapon_id in tracked_ids:
		if active_firearms.has(weapon_id):
			continue
		var record := _records[weapon_id] as Dictionary
		var state := inactive_states[weapon_id] as Dictionary
		if bool(state.get("destroyed", false)):
			var removed_record := record.duplicate(true)
			if not _remove_instance(weapon_id, &"weapon_invalidation", tick):
				return _reconciliation_rejection(last_error)
			removed.append(removed_record)
			continue
		if not _park_instance(record, state, snapshot.get_revision(), tick):
			return _reconciliation_rejection(last_error)
		var parked_record := (_records[weapon_id] as Dictionary).duplicate(true)
		if bool(state.get("player_owned", false)):
			dormant.append(parked_record)
		else:
			parked.append(parked_record)

	var active_ids := PackedStringArray(active_firearms.keys())
	active_ids.sort()
	for weapon_id in active_ids:
		var mapping := active_firearms[weapon_id] as Dictionary
		if not _records.has(weapon_id):
			var created := _create_instance(mapping, tick)
			if not bool(created.get("accepted", false)):
				return created
			added.append((created["record"] as Dictionary).duplicate(true))
		else:
			var existing := _records[weapon_id] as Dictionary
			if _retired_item_ids.has(int(existing.get("native_item_id", 0))):
				return _latch_recovery(&"destroyed_weapon_reappeared", existing)
			if not _record_matches_mapping(existing, mapping):
				return _latch_recovery(&"weapon_instance_mapping_conflict", existing)
			existing["equipped"] = true
			existing["parked"] = false
			existing["custody"] = &"player"
			existing["last_inventory_revision"] = snapshot.get_revision()
			existing["last_reconciled_tick"] = tick
			_records[weapon_id] = existing
			retained.append(existing.duplicate(true))

	_last_outcome = {
		"accepted": true,
		"tick": tick,
		"binding_generation": _binding_generation,
		"owner_generation": _owner_generation,
		"scope_generation": _scope_generation,
		"inventory_id": _owner.raid_player_inventory_id,
		"inventory_revision": snapshot.get_revision(),
		"added": added,
		"retained": retained,
		"dormant": dormant,
		"parked": parked,
		"removed": removed,
		"deferred_melee": deferred_melee,
	}
	_emit_reconciliation(_last_outcome)
	return _last_outcome.duplicate(true)


func _create_instance(mapping: Dictionary, tick: int) -> Dictionary:
	var weapon_id := String(mapping["weapon_id"])
	if not _weapon_authority.snapshot(weapon_id).is_empty():
		return _latch_recovery(&"weapon_instance_identity_collision", mapping)
	var created: Dictionary = _weapon_authority.create_weapon(
		weapon_id,
		String(ZerkovCombatContent.WEAPON_AKM),
		ZerkovCombatContent.CONTENT_VERSION,
		0,
		{},
		_admission.raid_id.canonical_key(),
		_admission.authority_epoch
	)
	if not bool(created.get("ok", false)):
		return _latch_recovery(&"weapon_instance_create_failed", created)
	var record := {
		"weapon_id": weapon_id,
		"entity_id": String(mapping["entity_id"]),
		"native_inventory_id": int(mapping["native_inventory_id"]),
		"native_item_id": int(mapping["native_item_id"]),
		"item_definition_identifier": mapping["item_definition_identifier"],
		"combat_definition_identifier": mapping["combat_definition_identifier"],
		"weapon_kind": mapping["weapon_kind"],
		"weapon_binding_generation": _next_weapon_binding_generation,
		"equipped": true,
		"parked": false,
		"custody": &"player",
		"created_tick": tick,
		"last_reconciled_tick": tick,
		"last_inventory_revision": _reconciler.current_revision(),
	}
	_next_weapon_binding_generation += 1
	var registered := _reload_adapter.register_weapon(
		mapping, int(record["weapon_binding_generation"]))
	if not bool(registered.get("accepted", false)):
		var cleanup: Dictionary = _weapon_authority.remove_weapon(weapon_id)
		if not bool(cleanup.get("ok", false)) \
				or not String(cleanup.get("reservation_to_release", "")).is_empty() \
				or not _weapon_authority.snapshot(weapon_id).is_empty():
			_records[weapon_id] = record
			return _latch_recovery(&"weapon_instance_register_cleanup_failed", {
				"record": record,
				"registration": registered,
				"cleanup": cleanup,
			})
		return _reconciliation_rejection(
			StringName(registered.get("reason", &"weapon_reload_registration_failed")))
	_records[weapon_id] = record
	return {"accepted": true, "record": record.duplicate(true)}


func _remove_instance(weapon_id: String, reason: StringName, tick: int) -> bool:
	var record := _records.get(weapon_id, {}) as Dictionary
	if record.is_empty():
		return true
	if _reload_adapter == null or not is_instance_valid(_reload_adapter):
		_latch_recovery(&"weapon_reload_binding_unreachable", {"record": record})
		return false
	var reload_lifecycle := _reload_adapter.lifecycle
	if reload_lifecycle == InventoryWeaponAdapter.Lifecycle.BOUND:
		if _reload_adapter.is_bound():
			var interrupted := _reload_adapter.interrupt_reload(weapon_id, reason, tick)
			if not bool(interrupted.get("accepted", false)):
				_latch_recovery(&"weapon_reload_interrupt_failed", {
					"record": record,
					"interruption": interrupted,
				})
				return false
		else:
			# Owner unload erases inventory state before emitting its lifecycle
			# signal. Ask the coordinator to cancel mechanically and invalidate
			# itself before exact deregistration is attempted.
			_reload_adapter.validate_binding(tick)
			reload_lifecycle = _reload_adapter.lifecycle
	if reload_lifecycle == InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED:
		var quarantined := _reload_adapter.quarantine_weapon_after_inventory_loss(
			weapon_id, int(record.get("weapon_binding_generation", 0)))
		if not bool(quarantined.get("accepted", false)):
			_latch_recovery(&"weapon_reload_quarantine_failed", {
				"record": record,
				"quarantine": quarantined,
				"reload_recovery": _reload_adapter.recovery_details(),
			})
			return false
		var quarantine_reservation := String(quarantined.get("reservation_id", ""))
		var native_before := _weapon_authority.snapshot(weapon_id)
		var native_phase := String(native_before.get("phase", ""))
		var native_reservation := String((native_before.get(
			"reload", {}) as Dictionary).get("reservation_id", ""))
		if native_before.is_empty() \
				or (native_phase == "reloading" \
					and native_reservation != quarantine_reservation) \
				or (native_phase != "ready" and native_phase != "reloading"):
			_latch_recovery(&"weapon_reload_quarantine_state_mismatch", {
				"record": record,
				"quarantine": quarantined,
				"native": native_before,
			})
			return false
		record["terminal_reload_quarantine_reservation"] = quarantine_reservation
		_records[weapon_id] = record
		reload_lifecycle = _reload_adapter.lifecycle
	# A successful exact quarantine deliberately leaves the reload adapter in
	# RECOVERY_REQUIRED until its final binding is retired. That is a settled
	# state for this one weapon, so continue native retirement instead of
	# stranding the remaining generation-scoped bindings.
	if reload_lifecycle != InventoryWeaponAdapter.Lifecycle.BOUND \
			and reload_lifecycle != InventoryWeaponAdapter.Lifecycle.RECOVERY_REQUIRED \
			and reload_lifecycle != InventoryWeaponAdapter.Lifecycle.INVALIDATED:
		_latch_recovery(&"weapon_reload_lifecycle_unsettled", {
			"record": record,
			"reload_lifecycle": int(reload_lifecycle),
			"reload_error": _reload_adapter.last_error,
		})
		return false
	var deregistered := _reload_adapter.unregister_weapon(
		weapon_id, int(record.get("weapon_binding_generation", 0)))
	if not bool(deregistered.get("accepted", false)):
		_latch_recovery(&"weapon_reload_deregistration_failed", {
			"record": record,
			"deregistration": deregistered,
		})
		return false
	var removed := _remove_native_weapon(weapon_id)
	var reservation_to_release := String(removed.get("reservation_to_release", ""))
	var quarantined_reservation := String(record.get(
		"terminal_reload_quarantine_reservation", ""))
	if not bool(removed.get("ok", false)) \
			or (not reservation_to_release.is_empty() \
				and reservation_to_release != quarantined_reservation) \
			or not _weapon_authority.snapshot(weapon_id).is_empty():
		_latch_recovery(&"weapon_instance_remove_failed", {
			"record": record,
			"deregistration": deregistered,
			"removal": removed,
		})
		return false
	_records.erase(weapon_id)
	_retired_item_ids.erase(int(record.get("native_item_id", 0)))
	return true


func _remove_native_weapon(weapon_id: String) -> Dictionary:
	return _weapon_authority.remove_weapon(weapon_id)


func _park_instance(
	record: Dictionary,
	state: Dictionary,
	inventory_revision: int,
	tick: int
) -> bool:
	var weapon_id := String(record.get("weapon_id", ""))
	if bool(record.get("equipped", false)):
		var interrupted := _reload_adapter.interrupt_reload(
			weapon_id, &"weapon_swap", tick)
		if not bool(interrupted.get("accepted", false)):
			_latch_recovery(&"weapon_parking_interrupt_failed", {
				"record": record,
				"interruption": interrupted,
			})
			return false
	record["equipped"] = false
	record["parked"] = true
	record["custody"] = state.get("custody", &"external")
	record["last_inventory_revision"] = inventory_revision
	record["last_reconciled_tick"] = tick
	_records[weapon_id] = record
	return true


func _remove_all_owned_instances(reason: StringName, tick: int) -> bool:
	var weapon_ids := PackedStringArray(_records.keys())
	weapon_ids.sort()
	var first_failure_error: StringName = &""
	var first_failure_details: Dictionary = {}
	for weapon_id in weapon_ids:
		if not _remove_instance(weapon_id, reason, tick):
			if first_failure_error.is_empty():
				first_failure_error = last_error
				if first_failure_error.is_empty():
					first_failure_error = StringName(
						_recovery_details.get("reason", &"weapon_instance_cleanup_failed"))
				first_failure_details = _recovery_details.duplicate(true)
	if first_failure_error.is_empty():
		return true
	# Teardown is terminal and bounded by MAX_TRACKED_FIREARMS. Continue past a
	# reachable native failure so every other exact-generation reload binding is
	# quarantined/retired, then preserve the first deterministic failure and its
	# retry evidence for the remaining record.
	lifecycle = Lifecycle.RECOVERY_REQUIRED
	last_error = first_failure_error
	_recovery_details = first_failure_details
	return false


func _mapping_is_authoritative_firearm(mapping: Dictionary) -> bool:
	if StringName(mapping.get("slot_identifier", &"")) \
			!= EquippedItemReconciler.SLOT_PRIMARY \
			or int(mapping.get("native_inventory_id", 0)) \
				!= _owner.raid_player_inventory_id \
			or int(mapping.get("native_item_id", 0)) <= 0 \
			or StringName(mapping.get("item_definition_identifier", &"")) \
				!= ZerkovInventoryCatalog.ITEM_AKM \
			or StringName(mapping.get("combat_definition_identifier", &"")) \
				!= ZerkovCombatContent.WEAPON_AKM \
			or StringName(mapping.get("weapon_kind", &"")) \
				!= EquippedItemReconciler.WEAPON_KIND_FIREARM:
		return false
	var identities := EquippedItemReconciler.derive_identity_keys(
		_admission,
		_owner_generation,
		_owner.raid_player_inventory_id,
		int(mapping["native_item_id"]),
		ZerkovInventoryCatalog.ITEM_AKM
	)
	return not identities.is_empty() \
		and String(mapping.get("weapon_id", "")) == String(identities["weapon_id"]) \
		and String(mapping.get("entity_id", "")) == String(identities["entity_id"])


func _record_matches_mapping(record: Dictionary, mapping: Dictionary) -> bool:
	for key in [
		"weapon_id", "entity_id", "native_inventory_id", "native_item_id",
		"item_definition_identifier", "combat_definition_identifier", "weapon_kind",
	]:
		if record.get(key) != mapping.get(key):
			return false
	return _native_snapshot_matches_record(
		_weapon_authority.snapshot(String(record["weapon_id"])), record)


func _native_snapshot_matches_record(snapshot: Dictionary, record: Dictionary) -> bool:
	return not snapshot.is_empty() \
		and String(snapshot.get("instance_id", "")) == String(record.get("weapon_id", "")) \
		and StringName(snapshot.get("definition_id", &"")) \
			== ZerkovCombatContent.WEAPON_AKM \
		and int(snapshot.get("definition_version", 0)) \
			== ZerkovCombatContent.CONTENT_VERSION \
		and String(snapshot.get("authority_scope", "")) \
			== _admission.raid_id.canonical_key() \
		and int(snapshot.get("authority_epoch", 0)) == _admission.authority_epoch


func _item_state(snapshot: InventorySnapshotResource, record: Dictionary) -> Dictionary:
	var matches: Array[Dictionary] = []
	var player_match := _item_state_in_snapshot(snapshot, record, true)
	if bool(player_match.get("found", false)):
		matches.append(player_match)
	for inventory_entry in [
		{"id": _owner.world_crate_inventory_id, "custody": &"world_crate"},
		{"id": _owner.corpse_inventory_id, "custody": &"corpse"},
	]:
		var inventory_id := int(inventory_entry["id"])
		if inventory_id <= 0 or not _inventory_authority.has_inventory(inventory_id):
			continue
		var custody_snapshot := _inventory_authority.snapshot(inventory_id)
		if custody_snapshot == null:
			return {"valid": false, "reason": &"custody_snapshot_missing"}
		var custody_match := _item_state_in_snapshot(custody_snapshot, record, false)
		if bool(custody_match.get("found", false)):
			custody_match["custody"] = inventory_entry["custody"]
			matches.append(custody_match)
	if matches.size() > 1:
		return {"valid": false, "reason": &"weapon_item_duplicate_custody"}
	var native_item_id := int(record.get("native_item_id", 0))
	if _retired_item_ids.has(native_item_id) and not matches.is_empty():
		return {"valid": false, "reason": &"destroyed_weapon_still_present"}
	if matches.size() == 1:
		var matched_state := matches[0]
		if not bool(matched_state.get("valid", false)):
			return matched_state
		matched_state["live"] = true
		matched_state["destroyed"] = false
		return matched_state
	if _retired_item_ids.has(native_item_id):
		return {
			"valid": true,
			"live": false,
			"destroyed": true,
			"player_owned": false,
			"equipped": false,
			"custody": &"destroyed",
		}
	# A stable-id-preserving transfer to a custody service outside the three raid
	# inventories keeps the same item live. Absence alone is never destruction;
	# REMOVED and value-only DROPPED events explicitly retire the native id.
	return {
		"valid": true,
		"live": true,
		"destroyed": false,
		"player_owned": false,
		"equipped": false,
		"custody": &"external",
	}


func _item_state_in_snapshot(
	snapshot: InventorySnapshotResource,
	record: Dictionary,
	player_owned: bool
) -> Dictionary:
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) != int(record.get("native_item_id", 0)):
			continue
		if int(item.get("quantity", 0)) != 1 \
				or item.get("item_definition_identifier") \
					!= record.get("item_definition_identifier"):
			return {
				"found": true,
				"valid": false,
				"reason": &"weapon_item_identity_mismatch",
			}
		var location := item.get("location", {}) as Dictionary
		var equipment_container := _equipment_container_id(snapshot) if player_owned else 0
		return {
			"found": true,
			"valid": true,
			"player_owned": player_owned,
			"equipped": player_owned and equipment_container > 0 \
				and String(location.get("kind", "")) == "slot" \
				and int(location.get("container", 0)) == equipment_container \
				and StringName(location.get("slot_identifier", &"")) \
					== EquippedItemReconciler.SLOT_PRIMARY,
			"custody": &"player" if player_owned else &"external",
		}
	return {"found": false, "valid": true}


func _equipment_container_id(snapshot: InventorySnapshotResource) -> int:
	var result := 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if int(container.get("provider_item", 0)) == 0 \
				and StringName(container.get("container_definition_identifier", &"")) \
					== ZerkovInventoryCatalog.CONTAINER_EQUIPMENT:
			if result != 0:
				return 0
			result = int(container.get("id", 0))
	return result


func _binding_is_current() -> bool:
	return _owner != null and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.is_current_generation(_owner_generation) \
		and _reconciler != null and is_instance_valid(_reconciler) \
		and _reconciler.get_instance_id() == _reconciler_instance_id \
		and _reconciler.is_bound() \
		and _reconciler.owner_generation() == _owner_generation \
		and _reconciler.scope_generation() == _scope_generation \
		and _raid_authority != null \
		and _raid_authority.generation() == _raid_generation \
		and _phase_registered \
		and _raid_authority.has_phase_handler(PHASE_HANDLER_ID, _raid_generation) \
		and _inventory_authority != null and is_instance_valid(_inventory_authority) \
		and _inventory_authority.get_instance_id() == _inventory_authority_instance_id \
		and _owner.raid_authority() == _inventory_authority \
		and _weapon_authority != null and is_instance_valid(_weapon_authority) \
		and _weapon_authority.get_instance_id() == _weapon_authority_instance_id \
		and _weapon_authority.is_ready() \
		and _weapon_content_fingerprint != 0 \
		and _weapon_authority.content_fingerprint() == _weapon_content_fingerprint \
		and _weapon_port != null and is_instance_valid(_weapon_port) \
		and _weapon_port.get_instance_id() == _weapon_port_instance_id \
		and _weapon_port.identity_token() \
			== "weapon_authority:%d" % _weapon_authority_instance_id \
		and _reload_adapter != null and is_instance_valid(_reload_adapter) \
		and _reload_adapter.get_instance_id() == _reload_adapter_instance_id \
		and _reload_adapter.is_bound() \
		and _reload_adapter.weapon_port_identity_token() == _weapon_port.identity_token()


func _on_reconciler_invalidated(reason: StringName) -> void:
	if lifecycle != Lifecycle.BOUND and lifecycle != Lifecycle.RECOVERY_REQUIRED:
		return
	var effective := reason if not reason.is_empty() else &"authority_invalidation"
	var tick := _raid_authority.last_processed_tick if _raid_authority != null else 0
	if not _preflight_phase_handler_removal():
		_latch_recovery(&"weapon_phase_handler_release_blocked", {
			"reason": _raid_authority.last_error if _raid_authority != null else &"raid_missing",
		})
		return
	# The reload adapter may already have observed the same inventory lifecycle
	# boundary. Removing the native instance is still required; a non-empty
	# reservation is quarantined because no second inventory release is guessed.
	if not _remove_all_owned_instances(&"authority_invalidation", tick):
		return
	if not _unregister_phase_handler():
		_latch_recovery(&"weapon_phase_handler_release_failed", {
			"reason": _raid_authority.last_error if _raid_authority != null else &"raid_missing",
		})
		return
	_disconnect_reconciler()
	_disconnect_inventory_transactions()
	lifecycle = Lifecycle.INVALIDATED
	last_error = effective
	_generation_counter += 1
	_binding_generation = _generation_counter
	_emit_invalidation(effective)


func _on_inventory_transaction_committed(
	result: Dictionary,
	expected_authority_instance_id: int,
	expected_owner_generation: int,
	expected_binding_generation: int
) -> void:
	if lifecycle != Lifecycle.BOUND \
			or expected_binding_generation != _binding_generation \
			or expected_owner_generation != _owner_generation \
			or _inventory_authority == null \
			or not is_instance_valid(_inventory_authority) \
			or _inventory_authority.get_instance_id() != expected_authority_instance_id \
			or not bool(result.get("accepted", false)) \
			or bool(result.get("queued", false)) \
			or bool(result.get("replayed", false)):
		return
	var events := result.get("events", []) as Array
	for event_value in events:
		var event := event_value as Dictionary
		var event_kind := int(event.get("kind", -1))
		if event_kind != INVENTORY_EVENT_REMOVED \
				and event_kind != INVENTORY_EVENT_DROPPED:
			continue
		var native_item_id := int(event.get("item", 0))
		if native_item_id <= 0:
			continue
		for record_value in _records.values():
			var record := record_value as Dictionary
			if int(record.get("native_item_id", 0)) == native_item_id:
				_retired_item_ids[native_item_id] = true
				break


func _reconciliation_rejection(reason: StringName) -> Dictionary:
	last_error = reason
	return {"accepted": false, "reason": reason}


func _latch_recovery(reason: StringName, details: Dictionary) -> Dictionary:
	if lifecycle != Lifecycle.RECOVERY_REQUIRED:
		lifecycle = Lifecycle.RECOVERY_REQUIRED
		last_error = reason
		_recovery_details = {
			"reason": reason,
			"details": details.duplicate(true),
			"binding_generation": _binding_generation,
			"new_instance_forbidden": true,
		}
		var publication := _recovery_details.duplicate(true)
		_make_deep_read_only(publication)
		_public_signal_active = true
		recovery_latched.emit(reason, publication)
		_public_signal_active = false
	return {"accepted": false, "reason": reason, "recovery_required": true}


func _emit_reconciliation(outcome: Dictionary) -> void:
	var publication := outcome.duplicate(true)
	_make_deep_read_only(publication)
	_public_signal_active = true
	reconciliation_published.emit(publication)
	_public_signal_active = false


func _emit_invalidation(reason: StringName) -> void:
	_public_signal_active = true
	binding_invalidated.emit(reason)
	_public_signal_active = false


func _disconnect_reconciler() -> void:
	if _reconciler != null and is_instance_valid(_reconciler) \
			and _reconciler_invalidated_callback.is_valid() \
			and _reconciler.binding_invalidated.is_connected(
				_reconciler_invalidated_callback):
		_reconciler.binding_invalidated.disconnect(_reconciler_invalidated_callback)
	_reconciler_invalidated_callback = Callable()


func _disconnect_inventory_transactions() -> void:
	if _inventory_authority != null and is_instance_valid(_inventory_authority) \
			and _inventory_transaction_callback.is_valid() \
			and _inventory_authority.transaction_committed.is_connected(
				_inventory_transaction_callback):
		_inventory_authority.transaction_committed.disconnect(_inventory_transaction_callback)
	_inventory_transaction_callback = Callable()


func _unregister_phase_handler() -> bool:
	if not _phase_registered:
		return true
	if _raid_authority == null:
		return _reject(&"raid_authority_invalid")
	if not _raid_authority.has_phase_handler(PHASE_HANDLER_ID, _raid_generation):
		_phase_registered = false
		return true
	if not _raid_authority.unregister_phase_handler(
		PHASE_HANDLER_ID, _raid_generation):
		last_error = _raid_authority.last_error
		return false
	_phase_registered = false
	return true


func _preflight_phase_handler_removal() -> bool:
	if not _phase_registered:
		return true
	if _raid_authority == null:
		return _reject(&"raid_authority_invalid")
	if not _raid_authority.has_phase_handler(PHASE_HANDLER_ID, _raid_generation):
		return true
	if not _raid_authority.can_unregister_phase_handler(
			PHASE_HANDLER_ID, _raid_generation):
		last_error = _raid_authority.last_error
		return false
	return true


func _reset_unbound_state() -> void:
	_disconnect_reconciler()
	_disconnect_inventory_transactions()
	lifecycle = Lifecycle.UNBOUND
	last_error = &""
	_owner = null
	_owner_instance_id = 0
	_reconciler = null
	_reconciler_instance_id = 0
	_admission = null
	_owner_generation = 0
	_scope_generation = 0
	_raid_authority = null
	_raid_generation = 0
	_weapon_authority = null
	_weapon_authority_instance_id = 0
	_weapon_content_fingerprint = 0
	_weapon_port = null
	_weapon_port_instance_id = 0
	_reload_adapter = null
	_reload_adapter_instance_id = 0
	_inventory_authority = null
	_inventory_authority_instance_id = 0
	_binding_generation = 0
	_records.clear()
	_retired_item_ids.clear()
	_last_outcome.clear()
	_recovery_details.clear()
	_public_signal_active = false
	_phase_registered = false


func _make_deep_read_only(value: Variant) -> void:
	if value is Dictionary:
		var dictionary := value as Dictionary
		for child in dictionary.values():
			_make_deep_read_only(child)
		dictionary.make_read_only()
	elif value is Array:
		var array := value as Array
		for child in array:
			_make_deep_read_only(child)
		array.make_read_only()


func _reject(reason: StringName) -> bool:
	last_error = reason
	return false


func _exit_tree() -> void:
	if (lifecycle == Lifecycle.BOUND or lifecycle == Lifecycle.RECOVERY_REQUIRED) \
			and not _public_signal_active:
		release_binding(&"teardown", _raid_authority.last_processed_tick)
	else:
		_disconnect_reconciler()
		_disconnect_inventory_transactions()
