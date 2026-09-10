class_name InventoryAbilityAdapter
extends RefCounted
## Canonical inventory equipment -> Gameplay Abilities reconciliation.
##
## This adapter binds one exact RaidInventoryOwner generation, its player raid
## InventoryAuthority, one authenticated admission, and one authoritative
## Gameplay Abilities participant. Inventory transaction results are queued as
## bounded sequencing hints only. During the authority abilities/due-work
## phase, advance_to() pulls a fresh OWNER snapshot from the exact bound native
## authority and derives the complete desired grant set from after-state.
##
## Gameplay Abilities exposes no batch grant/revoke transaction. A complete
## plan is preflighted, operations run in stable order, and only one game-owned
## completion is published. Any unexpected partial native failure quarantines
## this adapter and best-effort revokes every adapter-owned spec; it is never
## represented as an atomic rollback.

signal reconciliation_applied(outcome: Dictionary)
signal recovery_latched(reason: StringName, details: Dictionary)
signal binding_invalidated(reason: StringName)

enum Lifecycle {
	UNBOUND,
	BOUND,
	RECOVERY_REQUIRED,
	INVALIDATED,
}

const MAX_AUTHORITY_TICK: int = 9_007_199_254_740_000
const MAX_PENDING_RESULTS: int = 64
const MAX_RECONCILIATIONS_PER_ADVANCE: int = 8
const SOURCE_SCHEMA: String = "zerkov.inventory_ability.source.v1"
const SOURCE_HASH_SEGMENT_BYTES: int = 48
const DEFAULT_PHASE_HANDLER_ID: StringName = &"inventory_ability_adapter"

var lifecycle: Lifecycle = Lifecycle.UNBOUND
var last_error: StringName = &""

var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _owner_generation: int = 0
var _raid_authority: RaidAuthority
var _raid_authority_instance_id: int = 0
var _raid_generation: int = 0
var _raid_admission_digest: String = ""
var _phase_registered: bool = false
var _phase_call_active: bool = false
var _authority: InventoryAuthority
var _authority_instance_id: int = 0
var _inventory_id: int = 0
var _catalog: InventoryCatalog
var _catalog_instance_id: int = 0
var _inventory_manifest_fingerprint: int = 0
var _inventory_manifest_algorithm: StringName = &""
var _admission: ZSessionAdmission
var _identity_port: ZInventoryIdentityPort
var _native_actor_id: int = 0
var _ability_port: EquipmentAbilityParticipantPort
var _ability_port_token: String = ""
var _ability_entity_id: int = 0
var _declarations: Array[Dictionary] = []
var _declaration_digest: String = ""

var _last_revision: int = -1
var _last_snapshot_digest: String = ""
var _last_tick: int = 0
var _active_sources: Dictionary = {}
var _current_outcome: Dictionary = {}

var _pending_results: Array[Dictionary] = []
var _pending_result_digests: Dictionary = {}
var _resync_required: bool = false
var _mutation_active: bool = false
var _public_signal_active: bool = false
var _deferred_invalidation_reason: StringName = &""

var _transaction_callback: Callable
var _inventory_unloaded_callback: Callable
var _inventory_generation_callback: Callable
var _owner_tree_exiting_callback: Callable
var _component_tree_exiting_callback: Callable


func bind_owner(
	owner: RaidInventoryOwner,
	admission: ZSessionAdmission,
	identity_port: ZInventoryIdentityPort,
	ability_port: EquipmentAbilityParticipantPort,
	raid_authority: RaidAuthority,
	expected_owner_generation: int,
	initial_tick: int = 0,
	handler_id: StringName = DEFAULT_PHASE_HANDLER_ID
) -> bool:
	last_error = &""
	if _mutation_active or _public_signal_active:
		return _reject_bind(&"reentrant_binding_change")
	if lifecycle != Lifecycle.UNBOUND or _phase_registered:
		return _reject_bind(&"adapter_already_bound")
	if initial_tick < 0 or initial_tick > MAX_AUTHORITY_TICK:
		return _reject_bind(&"authority_tick_invalid")
	if owner == null or not is_instance_valid(owner) \
			or expected_owner_generation <= 0 \
			or not owner.is_current_generation(expected_owner_generation):
		return _reject_bind(&"inventory_owner_invalid")
	if admission == null or not admission.is_usable():
		return _reject_bind(&"session_admission_invalid")
	var admission_copy := admission.snapshot()
	if admission_copy == null or identity_port == null:
		return _reject_bind(&"session_admission_invalid")
	if raid_authority == null or raid_authority.lifecycle != RaidAuthority.Lifecycle.PREPARING \
			or raid_authority.generation() != admission_copy.generation \
			or raid_authority.last_processed_tick != initial_tick \
			or not _admissions_match(raid_authority.admission(), admission_copy):
		return _reject_bind(&"raid_authority_invalid")
	var authority := owner.raid_authority()
	var inventory_id := owner.raid_player_inventory_id
	var catalog := owner.catalog()
	if authority == null or not is_instance_valid(authority) \
			or inventory_id <= 0 or not authority.has_inventory(inventory_id):
		return _reject_bind(&"raid_inventory_authority_invalid")
	if catalog == null or not catalog.is_sealed() or catalog.manifest_fingerprint() == 0:
		return _reject_bind(&"inventory_catalog_invalid")
	var expected_catalog := ZerkovInventoryCatalog.build_sealed_catalog()
	if expected_catalog == null \
			or catalog.manifest_fingerprint() != expected_catalog.manifest_fingerprint() \
			or catalog.manifest_algorithm() != expected_catalog.manifest_algorithm():
		return _reject_bind(&"inventory_catalog_manifest_mismatch")
	if ability_port == null or not ability_port.is_ready() \
			or ability_port.entity_id() <= 0 \
			or ability_port.current_tick() > initial_tick:
		return _reject_bind(&"equipment_ability_port_invalid")
	var component_node := ability_port.owner_node()
	if component_node == null or not is_instance_valid(component_node):
		return _reject_bind(&"ability_owner_node_invalid")
	var resolved_actor := identity_port.native_actor_id(
		admission_copy.session_id,
		admission_copy.actor_id,
		admission_copy.authority_epoch,
		admission_copy.generation)
	if resolved_actor <= 0 or resolved_actor != ability_port.entity_id() \
			or not identity_port.actor_owns_inventory(
				admission_copy.session_id,
				admission_copy.actor_id,
				inventory_id,
				admission_copy.authority_epoch,
				admission_copy.generation):
		return _reject_bind(&"equipment_ability_actor_mismatch")
	var declarations := ZerkovEquipmentAbilityContent.equipment_declarations()
	var declaration_digest := ZerkovEquipmentAbilityContent.declaration_digest()
	var integration_bytes := ZerkovEquipmentAbilityContent.integration_mapping_bytes()
	if declarations.is_empty() or declaration_digest.is_empty() \
			or integration_bytes.is_empty():
		return _reject_bind(&"equipment_ability_content_invalid")
	var content_result := ability_port.validate_content(declarations)
	if not bool(content_result.get("accepted", false)):
		return _reject_bind(StringName(content_result.get(
			"reason", &"equipment_ability_content_incompatible")))
	var initial_snapshot := authority.snapshot(inventory_id)
	if initial_snapshot == null \
			or not _snapshot_has_expected_envelope(
				initial_snapshot,
				inventory_id,
				catalog.manifest_fingerprint(),
				catalog.manifest_algorithm()):
		return _reject_bind(&"initial_inventory_snapshot_invalid")
	# Re-resolve after all content/snapshot work so an identity implementation
	# cannot repoint the authenticated actor during the bind critical section.
	if identity_port.native_actor_id(
			admission_copy.session_id,
			admission_copy.actor_id,
			admission_copy.authority_epoch,
			admission_copy.generation) != resolved_actor:
		return _reject_bind(&"equipment_ability_actor_repointed")

	_reset_unbound_state()
	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_owner_generation = expected_owner_generation
	_raid_authority = raid_authority
	_raid_authority_instance_id = raid_authority.get_instance_id()
	_raid_generation = raid_authority.generation()
	_raid_admission_digest = _admission_digest(admission_copy)
	_authority = authority
	_authority_instance_id = authority.get_instance_id()
	_inventory_id = inventory_id
	_catalog = catalog
	_catalog_instance_id = catalog.get_instance_id()
	_inventory_manifest_fingerprint = catalog.manifest_fingerprint()
	_inventory_manifest_algorithm = catalog.manifest_algorithm()
	_admission = admission_copy
	_identity_port = identity_port
	_native_actor_id = resolved_actor
	_ability_port = ability_port
	_ability_port_token = ability_port.identity_token()
	_ability_entity_id = ability_port.entity_id()
	_declarations = declarations.duplicate(true)
	_declaration_digest = declaration_digest
	_last_tick = initial_tick
	lifecycle = Lifecycle.BOUND
	_connect_lifecycle_signals(component_node)
	if not raid_authority.register_phase_handler(
			RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK,
			handler_id,
			Callable(self, "handle_raid_phase"),
			_raid_generation):
		_disconnect_lifecycle_signals()
		var registration_error := raid_authority.last_error
		_reset_unbound_state()
		return _reject_bind(registration_error)
	_phase_registered = true
	_current_outcome = _base_outcome()
	_current_outcome.merge({
		"accepted": true,
		"changed": false,
		"duplicate": false,
		"initial": true,
		"invalidated": false,
		"pending_initial_snapshot": true,
		"reason": &"",
		"revision": -1,
		"snapshot_digest": "",
		"sources": [],
		"granted": [],
		"revoked": [],
	}, true)
	return true


func is_bound() -> bool:
	return lifecycle == Lifecycle.BOUND and _binding_is_current()


func owner_generation() -> int:
	return _owner_generation


func inventory_id() -> int:
	return _inventory_id


func ability_entity_id() -> int:
	return _ability_entity_id


func current_revision() -> int:
	return _last_revision


func current_tick() -> int:
	return _last_tick


func pending_result_count() -> int:
	return _pending_results.size()


func resync_required() -> bool:
	return _resync_required


func current_outcome() -> Dictionary:
	return _current_outcome.duplicate(true)


func current_sources() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var keys := PackedStringArray(_active_sources.keys())
	keys.sort()
	for key in keys:
		result.append((_active_sources[key] as Dictionary).duplicate(true))
	return result


func source_for_native_item(native_item_id: int) -> Dictionary:
	for source in current_sources():
		if int(source.get("native_item_id", 0)) == native_item_id:
			return source
	return {}


## Public sequencing-hint ingress. The bound native signal uses this same
## path. A caller cannot grant anything by forging a result: advance_to()
## always re-pulls the exact authority snapshot and derives state from it.
func observe_inventory_result(result: Dictionary) -> bool:
	last_error = &""
	if lifecycle != Lifecycle.BOUND:
		return _reject_observation(&"adapter_not_bound")
	# This callback can run in the inventory mutation phase. It only validates
	# and queues a sequencing hint; actor/ability reconciliation is deferred to
	# the registered phase-7 handler.
	if not _inventory_binding_structural_current():
		_resync_required = true
		return _reject_observation(&"binding_generation_invalidated")
	if typeof(result.get("accepted", null)) != TYPE_BOOL \
			or typeof(result.get("queued", null)) != TYPE_BOOL \
			or typeof(result.get("replayed", null)) != TYPE_BOOL \
			or not (result.get("revisions", null) is Array):
		return _reject_observation(&"inventory_result_schema_invalid")
	if bool(result["queued"]) or not bool(result["accepted"]):
		return true
	var matched_rows: Array[Dictionary] = []
	for row_value in result["revisions"] as Array:
		var row := row_value as Dictionary
		if int(row.get("inventory", 0)) == _inventory_id:
			matched_rows.append(row)
	if matched_rows.is_empty():
		return true
	if matched_rows.size() != 1:
		_resync_required = true
		return _reject_observation(&"inventory_result_revision_ambiguous")
	var row := matched_rows[0]
	if typeof(row.get("predecessor", null)) != TYPE_INT \
			or typeof(row.get("successor", null)) != TYPE_INT:
		_resync_required = true
		return _reject_observation(&"inventory_result_revision_invalid")
	var predecessor := int(row["predecessor"])
	var successor := int(row["successor"])
	var replayed := bool(result["replayed"])
	var valid_edge := predecessor >= 0 and (
		(successor == predecessor + 1)
		or (replayed and successor == predecessor)
	)
	if not valid_edge:
		_resync_required = true
		return _reject_observation(&"inventory_result_revision_invalid")
	var hint := {
		"command_id": int(result.get("command_id", 0)),
		"replayed": replayed,
		"predecessor": predecessor,
		"successor": successor,
	}
	var digest := ZCanonicalValue.sha256(hint)
	if digest.is_empty():
		_resync_required = true
		return _reject_observation(&"inventory_result_digest_invalid")
	if _pending_result_digests.has(digest):
		return true
	if _pending_results.size() >= MAX_PENDING_RESULTS:
		_pending_results.clear()
		_pending_result_digests.clear()
		_resync_required = true
		return true
	_pending_results.append(hint)
	_pending_result_digests[digest] = true
	return true


## Called from RaidAuthority.ABILITIES_AND_DUE_WORK. Multiple accepted native
## revisions may have accumulated since the prior tick; each iteration pulls
## after-state again so a reentrant publication cannot recurse or be lost.
func advance_to(tick: int) -> Array[Dictionary]:
	last_error = &""
	var outcomes: Array[Dictionary] = []
	if not _phase_call_active:
		outcomes.append(_rejection(&"authority_phase_required"))
		return outcomes
	if lifecycle != Lifecycle.BOUND:
		outcomes.append(_rejection(&"adapter_not_bound"))
		return outcomes
	if _mutation_active or _public_signal_active:
		outcomes.append(_rejection(&"reentrant_reconciliation"))
		return outcomes
	if tick < _last_tick or tick < _ability_port.current_tick() \
			or tick < 0 or tick > MAX_AUTHORITY_TICK:
		outcomes.append(_rejection(&"authority_tick_invalid"))
		return outcomes
	if not _binding_is_current():
		if _ability_port == null or not _ability_port.is_ready():
			_invalidate_or_recover_component(
				&"ability_component_invalidated", tick)
		else:
			_invalidate_binding(&"binding_generation_invalidated", tick)
		outcomes.append(current_outcome())
		return outcomes
	_last_tick = tick
	var iterations := 0
	while lifecycle == Lifecycle.BOUND and iterations < MAX_RECONCILIATIONS_PER_ADVANCE:
		iterations += 1
		var hints := _consume_pending_hints()
		var snapshot := _authority.snapshot(_inventory_id)
		if snapshot == null:
			_latch_recovery(&"inventory_snapshot_unavailable", hints, tick,
				_all_grant_records(_active_sources))
			outcomes.append(current_outcome())
			break
		var result := _reconcile_snapshot(
			snapshot, tick, _last_revision < 0, hints)
		outcomes.append(result)
		if lifecycle != Lifecycle.BOUND:
			break
		_process_deferred_invalidation(tick)
		if lifecycle != Lifecycle.BOUND:
			outcomes.append(current_outcome())
			break
		var authority_revision := _authority.inventory_revision(_inventory_id)
		if authority_revision == _last_revision and _pending_results.is_empty():
			break
	if lifecycle == Lifecycle.BOUND \
			and (_authority.inventory_revision(_inventory_id) != _last_revision \
				or not _pending_results.is_empty()):
		_resync_required = true
		outcomes.append({
			"accepted": true,
			"changed": false,
			"duplicate": false,
			"deferred": true,
			"reason": &"reconciliation_budget_exhausted",
			"revision": _last_revision,
		})
	return outcomes


## Stable RaidAuthority phase handler. RaidAuthority retains this RefCounted
## adapter through its registered Callable, so an invalidated binding remains
## a valid no-op handler until that raid authority seals or tears down.
func handle_raid_phase(
	raid_authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	_intents: Array[ZRaidIntent]
) -> bool:
	last_error = &""
	if raid_authority == null or raid_authority != _raid_authority \
			or raid_authority.get_instance_id() != _raid_authority_instance_id:
		last_error = &"handler_authority_mismatch"
		return false
	if phase != RaidAuthority.TickPhase.ABILITIES_AND_DUE_WORK:
		last_error = &"handler_phase_invalid"
		return false
	if lifecycle == Lifecycle.INVALIDATED:
		return true
	if lifecycle == Lifecycle.RECOVERY_REQUIRED or lifecycle == Lifecycle.UNBOUND:
		last_error = &"equipment_ability_recovery_required"
		return false
	if not _raid_authority_is_current():
		_invalidate_binding(&"raid_authority_generation_invalidated", tick)
		return lifecycle == Lifecycle.INVALIDATED
	_phase_call_active = true
	var outcomes := advance_to(tick)
	_phase_call_active = false
	if lifecycle == Lifecycle.INVALIDATED:
		return true
	if lifecycle == Lifecycle.RECOVERY_REQUIRED:
		last_error = StringName(current_outcome().get(
			"reason", &"equipment_ability_recovery_required"))
		return false
	for outcome in outcomes:
		if not bool(outcome.get("accepted", false)):
			last_error = StringName(outcome.get("reason", &"equipment_ability_phase_failed"))
			return false
	return true


func validate_binding() -> bool:
	last_error = &""
	if lifecycle == Lifecycle.BOUND and _binding_is_current():
		return true
	if lifecycle == Lifecycle.BOUND:
		if _ability_port == null or not _ability_port.is_ready():
			_invalidate_or_recover_component(
				&"ability_component_invalidated", _last_tick)
		else:
			_invalidate_binding(&"binding_generation_invalidated", _last_tick)
	last_error = &"binding_generation_invalidated"
	return false


func release_binding(
	reason: StringName = &"inventory_ability_adapter_released",
	tick: int = -1
) -> Dictionary:
	if lifecycle != Lifecycle.BOUND:
		return current_outcome()
	var final_reason := reason if not reason.is_empty() \
		else &"inventory_ability_adapter_released"
	if _mutation_active or _public_signal_active:
		if _deferred_invalidation_reason.is_empty():
			_deferred_invalidation_reason = final_reason
		return {
			"accepted": true,
			"deferred": true,
			"reason": final_reason,
		}
	var effective_tick := maxi(_last_tick, _ability_port.current_tick())
	if tick >= 0:
		effective_tick = maxi(effective_tick, tick)
	if effective_tick > MAX_AUTHORITY_TICK:
		_latch_recovery(&"authority_tick_invalid", {}, _last_tick,
			_all_grant_records(_active_sources))
		return current_outcome()
	return _invalidate_binding(final_reason, effective_tick)


static func derive_source_item_key(
	admission: ZSessionAdmission,
	owner_generation_value: int,
	inventory_id_value: int,
	native_item_id: int,
	item_definition_identifier: StringName,
	ability_entity_id_value: int
) -> String:
	if admission == null or not admission.is_usable() \
			or owner_generation_value <= 0 or inventory_id_value <= 0 \
			or native_item_id <= 0 or item_definition_identifier.is_empty() \
			or ability_entity_id_value <= 0:
		return ""
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return ""
	var digest := ZCanonicalValue.sha256({
		"schema": SOURCE_SCHEMA,
		"raid_id": admission_copy.raid_id.canonical_key(),
		"session_id": admission_copy.session_id.canonical_key(),
		"actor_id": admission_copy.actor_id.canonical_key(),
		"authority_epoch": admission_copy.authority_epoch,
		"admission_generation": admission_copy.generation,
		"owner_generation": owner_generation_value,
		"inventory_id": inventory_id_value,
		"native_item_id": native_item_id,
		"item_definition_identifier": item_definition_identifier,
		"ability_entity_id": ability_entity_id_value,
	})
	if digest.length() < SOURCE_HASH_SEGMENT_BYTES:
		return ""
	return "zerkov.equipment.item.%s" % digest.substr(0, SOURCE_HASH_SEGMENT_BYTES)


static func derive_grant_source_key(
	source_item_key: String,
	declaration_digest: String,
	grant_ordinal: int,
	ability_identifier: StringName
) -> String:
	if source_item_key.is_empty() or declaration_digest.is_empty() \
			or grant_ordinal < 0 or ability_identifier.is_empty():
		return ""
	var digest := ZCanonicalValue.sha256({
		"schema": SOURCE_SCHEMA,
		"source_item_key": source_item_key,
		"declaration_digest": declaration_digest,
		"grant_ordinal": grant_ordinal,
		"ability_identifier": ability_identifier,
	})
	if digest.length() < SOURCE_HASH_SEGMENT_BYTES:
		return ""
	return "zerkov.equipment.grant.%s" % digest.substr(0, SOURCE_HASH_SEGMENT_BYTES)


func _connect_lifecycle_signals(component_node: Node) -> void:
	_transaction_callback = Callable(self, "_on_transaction_committed")
	_inventory_unloaded_callback = Callable(self, "_on_inventory_unloaded")
	_inventory_generation_callback = Callable(self, "_on_inventory_generation_changing")
	_owner_tree_exiting_callback = Callable(self, "_on_owner_tree_exiting")
	_component_tree_exiting_callback = Callable(self, "_on_component_tree_exiting")
	_authority.transaction_committed.connect(_transaction_callback)
	_authority.inventory_unloaded.connect(_inventory_unloaded_callback)
	_authority.inventory_generation_changing.connect(_inventory_generation_callback)
	_owner.tree_exiting.connect(_owner_tree_exiting_callback)
	component_node.tree_exiting.connect(_component_tree_exiting_callback)


func _disconnect_lifecycle_signals() -> void:
	if _authority != null and is_instance_valid(_authority):
		if _transaction_callback.is_valid() \
				and _authority.transaction_committed.is_connected(_transaction_callback):
			_authority.transaction_committed.disconnect(_transaction_callback)
		if _inventory_unloaded_callback.is_valid() \
				and _authority.inventory_unloaded.is_connected(_inventory_unloaded_callback):
			_authority.inventory_unloaded.disconnect(_inventory_unloaded_callback)
		if _inventory_generation_callback.is_valid() \
				and _authority.inventory_generation_changing.is_connected(
					_inventory_generation_callback):
			_authority.inventory_generation_changing.disconnect(
				_inventory_generation_callback)
	if _owner != null and is_instance_valid(_owner) \
			and _owner_tree_exiting_callback.is_valid() \
			and _owner.tree_exiting.is_connected(_owner_tree_exiting_callback):
		_owner.tree_exiting.disconnect(_owner_tree_exiting_callback)
	var component_node := _ability_port.owner_node() if _ability_port != null else null
	if component_node != null and is_instance_valid(component_node) \
			and _component_tree_exiting_callback.is_valid() \
			and component_node.tree_exiting.is_connected(_component_tree_exiting_callback):
		component_node.tree_exiting.disconnect(_component_tree_exiting_callback)
	_transaction_callback = Callable()
	_inventory_unloaded_callback = Callable()
	_inventory_generation_callback = Callable()
	_owner_tree_exiting_callback = Callable()
	_component_tree_exiting_callback = Callable()


func _on_transaction_committed(result: Dictionary) -> void:
	observe_inventory_result(result)


func _on_inventory_unloaded(inventory_id_value: int) -> void:
	if inventory_id_value == _inventory_id:
		_request_invalidation(&"raid_player_inventory_unloaded")


func _on_inventory_generation_changing(inventory_id_value: int) -> void:
	if inventory_id_value == _inventory_id:
		_request_invalidation(&"raid_player_inventory_generation_changing")


func _on_owner_tree_exiting() -> void:
	_request_invalidation(&"inventory_owner_tree_exiting")


func _on_component_tree_exiting() -> void:
	if lifecycle != Lifecycle.BOUND:
		return
	if _mutation_active or _public_signal_active:
		if _deferred_invalidation_reason.is_empty():
			_deferred_invalidation_reason = &"ability_component_tree_exiting"
		return
	if _ability_port != null and _ability_port.is_ready():
		_invalidate_binding(&"ability_component_tree_exiting", _last_tick)
	elif _component_lifecycle_cleanup_observed():
		_invalidate_after_component_lifecycle(&"ability_component_tree_exiting")
	else:
		_latch_recovery(&"ability_component_cleanup_unproven", {}, _last_tick,
			_all_grant_records(_active_sources))


func _request_invalidation(reason: StringName) -> void:
	if lifecycle != Lifecycle.BOUND:
		return
	if _mutation_active or _public_signal_active:
		if _deferred_invalidation_reason.is_empty():
			_deferred_invalidation_reason = reason
		return
	if _ability_port != null and _ability_port.is_ready():
		_invalidate_binding(reason, maxi(_last_tick, _ability_port.current_tick()))
	elif _component_lifecycle_cleanup_observed():
		# queue_teardown() synchronously cancels execution-owned effects before a
		# later inventory/owner lifecycle notification can arrive. There is no
		# live native participant left to revoke through in this order.
		_invalidate_after_component_lifecycle(reason)
	else:
		_latch_recovery(&"ability_component_cleanup_unproven", {
			"requested_reason": reason,
		}, _last_tick, _all_grant_records(_active_sources))


func _process_deferred_invalidation(tick: int) -> void:
	if lifecycle != Lifecycle.BOUND or _deferred_invalidation_reason.is_empty():
		return
	var reason := _deferred_invalidation_reason
	_deferred_invalidation_reason = &""
	if _ability_port != null and _ability_port.is_ready():
		_invalidate_binding(reason, maxi(tick, _ability_port.current_tick()))
	elif _component_lifecycle_cleanup_observed():
		_invalidate_after_component_lifecycle(reason)
	else:
		_latch_recovery(&"ability_component_cleanup_unproven", {
			"requested_reason": reason,
		}, tick, _all_grant_records(_active_sources))


func _component_lifecycle_cleanup_observed() -> bool:
	if _ability_port == null:
		return _active_sources.is_empty()
	for record in _all_grant_records(_active_sources):
		if not _ability_port.grant_record_is_terminally_clean(record):
			return false
	return true


func _invalidate_or_recover_component(reason: StringName, tick: int) -> void:
	if _component_lifecycle_cleanup_observed():
		_invalidate_after_component_lifecycle(reason)
	else:
		_latch_recovery(&"ability_component_cleanup_unproven", {
			"requested_reason": reason,
		}, tick, _all_grant_records(_active_sources))


func _reconcile_snapshot(
	snapshot: InventorySnapshotResource,
	tick: int,
	initial: bool,
	hints: Dictionary
) -> Dictionary:
	if not _snapshot_has_expected_envelope(
			snapshot,
			_inventory_id,
			_inventory_manifest_fingerprint,
			_inventory_manifest_algorithm):
		return _latch_recovery(&"inventory_snapshot_envelope_invalid", hints, tick,
			_all_grant_records(_active_sources))
	if snapshot.get_revision() != _authority.inventory_revision(_inventory_id):
		return _latch_recovery(&"inventory_snapshot_revision_not_current", hints, tick,
			_all_grant_records(_active_sources))
	var revision := snapshot.get_revision()
	var digest := _snapshot_digest(snapshot)
	if digest.is_empty():
		return _latch_recovery(&"inventory_snapshot_digest_invalid", hints, tick,
			_all_grant_records(_active_sources))
	if revision < _last_revision:
		return _rejection(&"stale_snapshot_revision")
	if revision == _last_revision:
		if digest != _last_snapshot_digest:
			return _latch_recovery(&"equal_revision_divergence", hints, tick,
				_all_grant_records(_active_sources))
		for record in _all_grant_records(_active_sources):
			if not _ability_port.grant_record_is_live(record):
				return _latch_recovery(&"equipment_grant_externally_invalidated", {
					"record": record.duplicate(true),
				}, tick, _all_grant_records(_active_sources))
		var duplicate := _duplicate_result(hints)
		_resync_required = false
		return duplicate

	var desired_result := _build_desired_sources(snapshot)
	if not bool(desired_result.get("ok", false)):
		return _latch_recovery(StringName(desired_result.get(
			"reason", &"equipment_snapshot_invalid")), hints, tick,
			_all_grant_records(_active_sources))
	var desired := desired_result["sources"] as Dictionary
	var plan := _build_plan(_active_sources, desired)
	if not bool(plan.get("ok", false)):
		return _latch_recovery(StringName(plan.get(
			"reason", &"equipment_reconciliation_plan_invalid")), hints, tick,
			_all_grant_records(_active_sources))
	var addition_plans := plan["addition_plans"] as Array[Dictionary]
	var revocation_records := plan["revocation_records"] as Array[Dictionary]
	var preflight := _ability_port.preflight(addition_plans, revocation_records)
	if not bool(preflight.get("accepted", false)):
		return _latch_recovery(StringName(preflight.get(
			"reason", &"equipment_ability_preflight_failed")), {
			"preflight": preflight.duplicate(true),
			"revision": revision,
		}, tick, _all_grant_records(_active_sources))
	if not _identity_is_current():
		return _invalidate_binding(&"equipment_ability_actor_repointed", tick)

	var working := _copy_sources(_active_sources)
	var revoked_publications: Array[Dictionary] = []
	var granted_publications: Array[Dictionary] = []
	_mutation_active = true
	# Adds run first after complete headroom/content preflight so no old state is
	# revoked before the replacement grant has committed. There is still no
	# public native batch transaction: any unexpected failure quarantines and
	# best-effort cleans all adapter-owned specs rather than claiming rollback.
	for source_key in plan["added_keys"] as PackedStringArray:
		var source := (desired[source_key] as Dictionary).duplicate(true)
		var grant_records: Array = []
		for plan_value in source["grant_plans"] as Array:
			var grant_plan := plan_value as Dictionary
			var grant_result := _ability_port.grant(grant_plan, tick)
			if not bool(grant_result.get("accepted", false)):
				for recovery_value in grant_result.get("recovery_records", []) as Array:
					if recovery_value is Dictionary:
						grant_records.append(
							(recovery_value as Dictionary).duplicate(true))
				source["grant_records"] = grant_records
				working[source_key] = source
				_mutation_active = false
				return _latch_recovery(&"equipment_ability_grant_failed", {
					"native_result": grant_result.duplicate(true),
					"source_item_key": source_key,
					"ability_identifier": grant_plan.get("ability_identifier", &""),
				}, tick, _all_grant_records(working))
			grant_records.append(grant_result.duplicate(true))
			granted_publications.append(
				_grant_publication(source, grant_result, grant_result))
			source["grant_records"] = grant_records
			working[source_key] = source
			if not _identity_is_current():
				_mutation_active = false
				return _latch_recovery(&"equipment_ability_actor_repointed", {
					"source_item_key": source_key,
				}, tick, _all_grant_records(working))
			if not _deferred_invalidation_reason.is_empty():
				break
		if not _deferred_invalidation_reason.is_empty():
			break

	if _deferred_invalidation_reason.is_empty():
		for source_key in plan["removed_keys"] as PackedStringArray:
			var source := working[source_key] as Dictionary
			var records := source["grant_records"] as Array
			for record_value in records.duplicate(true):
				var record := record_value as Dictionary
				var revoke_result := _ability_port.revoke(record, tick)
				if not bool(revoke_result.get("accepted", false)):
					for recovery_value in revoke_result.get(
							"recovery_records", []) as Array:
						if recovery_value is Dictionary:
							records.append(
								(recovery_value as Dictionary).duplicate(true))
					source["grant_records"] = records
					working[source_key] = source
					_mutation_active = false
					return _latch_recovery(&"equipment_ability_revoke_failed", {
						"native_result": revoke_result.duplicate(true),
						"source_item_key": source_key,
						"spec": int(record.get("spec", 0)),
					}, tick, _all_grant_records(working))
				revoked_publications.append(
					_grant_publication(source, record, revoke_result))
				records.erase(record_value)
				source["grant_records"] = records
				working[source_key] = source
				if not _identity_is_current():
					_mutation_active = false
					return _latch_recovery(&"equipment_ability_actor_repointed", {
						"source_item_key": source_key,
					}, tick, _all_grant_records(working))
				if not _deferred_invalidation_reason.is_empty():
					break
			if records.is_empty():
				working.erase(source_key)
			if not _deferred_invalidation_reason.is_empty():
				break
	_mutation_active = false
	_active_sources = working
	if not _deferred_invalidation_reason.is_empty():
		_process_deferred_invalidation(tick)
		return current_outcome()

	# Every retained source must still point at exactly the native spec/effect
	# records created for this adapter. A foreign direct revoke never causes an
	# implicit regrant under the same inventory revision.
	for record in _all_grant_records(_active_sources):
		if not _ability_port.grant_record_is_live(record):
			return _latch_recovery(&"equipment_grant_postcondition_invalid", {
				"record": record.duplicate(true),
			}, tick, _all_grant_records(_active_sources))

	_last_revision = revision
	_last_snapshot_digest = digest
	_resync_required = false
	_current_outcome = _base_outcome()
	_current_outcome.merge({
		"accepted": true,
		"changed": not (plan["added_keys"] as PackedStringArray).is_empty() \
			or not (plan["removed_keys"] as PackedStringArray).is_empty(),
		"duplicate": false,
		"initial": initial,
		"invalidated": false,
		"reason": &"",
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"sources": current_sources(),
		"granted": granted_publications,
		"revoked": revoked_publications,
		"retained_source_keys": plan["retained_keys"],
		"result_hints": hints.duplicate(true),
	}, true)
	var published := current_outcome()
	_emit_reconciliation(published)
	return published


func _build_desired_sources(snapshot: InventorySnapshotResource) -> Dictionary:
	var equipment_container_id := 0
	for container_value in snapshot.get_containers():
		var container := container_value as Dictionary
		if StringName(container.get("container_definition_identifier", &"")) \
				!= ZerkovInventoryCatalog.CONTAINER_EQUIPMENT:
			continue
		if int(container.get("provider_item", 0)) != 0 or equipment_container_id != 0:
			return {"ok": false, "reason": &"equipment_container_invalid"}
		equipment_container_id = int(container.get("id", 0))
	if equipment_container_id <= 0:
		return {"ok": false, "reason": &"equipment_container_missing"}

	var declarations_by_item: Dictionary = {}
	for declaration in _declarations:
		declarations_by_item[StringName(
			declaration["item_definition_identifier"])] = declaration
	var sources: Dictionary = {}
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		var item_identifier := StringName(item.get("item_definition_identifier", &""))
		if not declarations_by_item.has(item_identifier):
			continue
		var location := item.get("location", {}) as Dictionary
		if String(location.get("kind", "")) != "slot" \
				or int(location.get("container", 0)) != equipment_container_id:
			continue
		var declaration := declarations_by_item[item_identifier] as Dictionary
		var slot := StringName(location.get("slot_identifier", &""))
		var allowed_slots := declaration["allowed_slots"] as Array
		if not allowed_slots.has(String(slot)):
			return {"ok": false, "reason": &"equipment_item_slot_invalid"}
		var native_item_id := int(item.get("id", 0))
		if native_item_id <= 0 or int(item.get("quantity", 0)) != 1:
			return {"ok": false, "reason": &"equipment_item_identity_invalid"}
		var source_key := derive_source_item_key(
			_admission, _owner_generation, _inventory_id, native_item_id,
			item_identifier, _ability_entity_id)
		if source_key.is_empty() or sources.has(source_key):
			return {"ok": false, "reason": &"equipment_source_identity_invalid"}
		var grant_plans: Array[Dictionary] = []
		var grants := declaration["ability_grants"] as Array
		for ordinal in range(grants.size()):
			var grant_plan := (grants[ordinal] as Dictionary).duplicate(true)
			var input_id := derive_grant_source_key(
				source_key, _declaration_digest, ordinal,
				StringName(grant_plan["ability_identifier"]))
			if input_id.is_empty():
				return {"ok": false, "reason": &"equipment_grant_identity_invalid"}
			grant_plan["input_id"] = input_id
			grant_plan["source_item_key"] = source_key
			grant_plan["grant_ordinal"] = ordinal
			grant_plans.append(grant_plan)
		sources[source_key] = {
			"source_item_key": source_key,
			"native_inventory_id": _inventory_id,
			"native_item_id": native_item_id,
			"item_definition_identifier": item_identifier,
			"slot_identifier": slot,
			"declaration_digest": _declaration_digest,
			"grant_plans": grant_plans,
			"grant_records": [],
		}
	return {"ok": true, "sources": sources}


func _build_plan(current: Dictionary, desired: Dictionary) -> Dictionary:
	var current_keys := PackedStringArray(current.keys())
	var desired_keys := PackedStringArray(desired.keys())
	current_keys.sort()
	desired_keys.sort()
	var removed_keys := PackedStringArray()
	var added_keys := PackedStringArray()
	var retained_keys := PackedStringArray()
	var revocation_records: Array[Dictionary] = []
	var addition_plans: Array[Dictionary] = []
	for key in current_keys:
		if not desired.has(key):
			removed_keys.append(key)
			for record in (current[key] as Dictionary)["grant_records"] as Array:
				revocation_records.append((record as Dictionary).duplicate(true))
			continue
		if not _source_definition_equal(
				current[key] as Dictionary, desired[key] as Dictionary):
			return {"ok": false, "reason": &"stable_equipment_source_diverged"}
		retained_keys.append(key)
	for key in desired_keys:
		if current.has(key):
			continue
		added_keys.append(key)
		for grant_plan in (desired[key] as Dictionary)["grant_plans"] as Array:
			addition_plans.append((grant_plan as Dictionary).duplicate(true))
	return {
		"ok": true,
		"removed_keys": removed_keys,
		"added_keys": added_keys,
		"retained_keys": retained_keys,
		"revocation_records": revocation_records,
		"addition_plans": addition_plans,
	}


func _source_definition_equal(left: Dictionary, right: Dictionary) -> bool:
	for key in [
		"source_item_key", "native_inventory_id", "native_item_id",
		"item_definition_identifier", "slot_identifier", "declaration_digest",
		"grant_plans",
	]:
		if left.get(key) != right.get(key):
			return false
	return true


func _snapshot_has_expected_envelope(
	snapshot: InventorySnapshotResource,
	expected_inventory_id: int,
	expected_manifest_fingerprint: int,
	expected_manifest_algorithm: StringName
) -> bool:
	return snapshot != null \
		and snapshot.get_inventory_id() == expected_inventory_id \
		and StringName(snapshot.get_profile_identifier()) \
			== ZerkovInventoryCatalog.PROFILE_PLAYER_RAID \
		and snapshot.get_revision() >= 0 \
		and snapshot.get_manifest_fingerprint() == expected_manifest_fingerprint \
		and StringName(snapshot.get_manifest_algorithm()) == expected_manifest_algorithm \
		and snapshot.get_visibility() == InventorySnapshotResource.VISIBILITY_OWNER \
		and not snapshot.canonical_bytes().is_empty()


func _consume_pending_hints() -> Dictionary:
	var cursor := _last_revision
	var accepted_edges := 0
	var replayed_edges := 0
	var invalid_edges := 0
	var maximum_successor := cursor
	for hint in _pending_results:
		var predecessor := int(hint["predecessor"])
		var successor := int(hint["successor"])
		maximum_successor = maxi(maximum_successor, successor)
		if cursor < 0:
			# Before the first full snapshot there is no applied revision edge
			# against which to chain hints. Count only their already-validated
			# shape; the exact full snapshot establishes canonical state.
			if bool(hint.get("replayed", false)):
				replayed_edges += 1
			else:
				accepted_edges += 1
			continue
		if successor <= cursor:
			replayed_edges += 1
			continue
		if predecessor == cursor and successor == cursor + 1:
			cursor = successor
			accepted_edges += 1
		else:
			invalid_edges += 1
			_resync_required = true
	_pending_results.clear()
	_pending_result_digests.clear()
	return {
		"accepted_edges": accepted_edges,
		"replayed_edges": replayed_edges,
		"invalid_edges": invalid_edges,
		"hint_successor": cursor,
		"maximum_successor": maximum_successor,
		"resync_required_before_pull": _resync_required,
	}


func _snapshot_digest(snapshot: InventorySnapshotResource) -> String:
	var bytes := snapshot.canonical_bytes()
	if bytes.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _binding_is_current() -> bool:
	return _binding_is_current_except_revision() \
		and _ability_port.is_ready() \
		and _ability_port.identity_token() == _ability_port_token \
		and _ability_port.entity_id() == _ability_entity_id


func _binding_is_current_except_revision() -> bool:
	return _inventory_binding_structural_current() \
		and _raid_authority_is_current() \
		and _identity_is_current()


func _inventory_binding_structural_current() -> bool:
	return _owner != null and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.is_current_generation(_owner_generation) \
		and _authority != null and is_instance_valid(_authority) \
		and _authority.get_instance_id() == _authority_instance_id \
		and _owner.raid_authority() == _authority \
		and _owner.raid_player_inventory_id == _inventory_id \
		and _authority.has_inventory(_inventory_id) \
		and _catalog != null and _catalog.get_instance_id() == _catalog_instance_id \
		and _owner.catalog() == _catalog \
		and _catalog.is_sealed() \
		and _catalog.manifest_fingerprint() == _inventory_manifest_fingerprint \
		and _catalog.manifest_algorithm() == _inventory_manifest_algorithm


func _raid_authority_is_current() -> bool:
	return _raid_authority != null \
		and _raid_authority.get_instance_id() == _raid_authority_instance_id \
		and _raid_authority.generation() == _raid_generation \
		and _admission_digest(_raid_authority.admission()) == _raid_admission_digest


func _identity_is_current() -> bool:
	if _identity_port == null or _admission == null:
		return false
	return _identity_port.native_actor_id(
			_admission.session_id,
			_admission.actor_id,
			_admission.authority_epoch,
			_admission.generation) == _native_actor_id \
		and _native_actor_id == _ability_entity_id \
		and _identity_port.actor_owns_inventory(
			_admission.session_id,
			_admission.actor_id,
			_inventory_id,
			_admission.authority_epoch,
			_admission.generation)


static func _admission_digest(value: ZSessionAdmission) -> String:
	if value == null or not value.is_usable():
		return ""
	return ZCanonicalValue.sha256({
		"raid_id": value.raid_id.canonical_key(),
		"session_id": value.session_id.canonical_key(),
		"actor_id": value.actor_id.canonical_key(),
		"authority_epoch": value.authority_epoch,
		"generation": value.generation,
	})


static func _admissions_match(
	left: ZSessionAdmission,
	right: ZSessionAdmission
) -> bool:
	return left != null and right != null \
		and left.is_usable() and right.is_usable() \
		and left.raid_id.is_equal(right.raid_id) \
		and left.session_id.is_equal(right.session_id) \
		and left.actor_id.is_equal(right.actor_id) \
		and left.authority_epoch == right.authority_epoch \
		and left.generation == right.generation


func _invalidate_binding(reason: StringName, tick: int) -> Dictionary:
	if lifecycle != Lifecycle.BOUND:
		return current_outcome()
	var previous_sources := current_sources()
	var records := _all_grant_records(_active_sources)
	_disconnect_lifecycle_signals()
	_mutation_active = true
	var revoked: Array[Dictionary] = []
	var failed: Array[Dictionary] = []
	var recovery_records: Array[Dictionary] = []
	for record in records:
		var result := _ability_port.revoke(record, tick)
		if bool(result.get("accepted", false)):
			revoked.append(result.duplicate(true))
		else:
			failed.append(result.duplicate(true))
			_append_unique_records(recovery_records,
				_recovery_records_from_result(result, record))
			# A revoke recovery baseline was captured while later ordinary
			# contributors were still live. Preserve that baseline and let the
			# mutation-first recovery pass prove it before removing anything else.
			break
	_mutation_active = false
	if not failed.is_empty():
		var records_for_recovery: Array[Dictionary] = []
		_append_unique_records(records_for_recovery, records)
		_append_unique_records(records_for_recovery, recovery_records)
		return _latch_recovery(&"equipment_ability_lifecycle_revoke_failed", {
			"requested_reason": reason,
			"revoke_failures": failed,
		}, tick, records_for_recovery)
	lifecycle = Lifecycle.INVALIDATED
	_active_sources.clear()
	_pending_results.clear()
	_pending_result_digests.clear()
	_resync_required = false
	_current_outcome = _base_outcome()
	_current_outcome.merge({
		"accepted": false,
		"changed": not previous_sources.is_empty(),
		"duplicate": false,
		"initial": false,
		"invalidated": true,
		"reason": reason,
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"sources": [],
		"removed_sources": previous_sources,
		"revoked": revoked,
	}, true)
	last_error = reason
	var published := current_outcome()
	_emit_reconciliation(published, reason)
	_clear_bound_references()
	last_error = reason
	return published


func _invalidate_after_component_lifecycle(reason: StringName) -> void:
	if lifecycle != Lifecycle.BOUND:
		return
	var previous_sources := current_sources()
	_disconnect_lifecycle_signals()
	lifecycle = Lifecycle.INVALIDATED
	_active_sources.clear()
	_pending_results.clear()
	_pending_result_digests.clear()
	_resync_required = false
	_current_outcome = _base_outcome()
	_current_outcome.merge({
		"accepted": false,
		"changed": not previous_sources.is_empty(),
		"duplicate": false,
		"initial": false,
		"invalidated": true,
		"reason": reason,
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"sources": [],
		"removed_sources": previous_sources,
		"component_lifecycle_cleanup": true,
	}, true)
	last_error = reason
	var published := current_outcome()
	_emit_reconciliation(published, reason)
	_clear_bound_references()
	last_error = reason


func _latch_recovery(
	reason: StringName,
	details: Dictionary,
	tick: int,
	owned_records: Array[Dictionary]
) -> Dictionary:
	if lifecycle == Lifecycle.RECOVERY_REQUIRED:
		return current_outcome()
	_disconnect_lifecycle_signals()
	_mutation_active = true
	var cleanup_results: Array[Dictionary] = []
	var unresolved_records: Array[Dictionary] = []
	var quarantine_result: Dictionary = {}
	if _ability_port != null:
		var cleanup_tick := mini(MAX_AUTHORITY_TICK,
			maxi(tick, _ability_port.current_tick()))
		# A partial grant capture's before-state includes every already-live
		# ordinary contributor. Restore and prove those captures before removing
		# older records, then clean ordinary records. Preserve the deterministic
		# source/spec order within each class.
		var mutation_records: Array[Dictionary] = []
		var ordinary_records: Array[Dictionary] = []
		for record in owned_records:
			if StringName(record.get("record_kind", &"")) == &"mutation_recovery":
				mutation_records.append(record)
			else:
				ordinary_records.append(record)
		var seen_specs: Dictionary = {}
		var discovered_mutations := _attempt_recovery_cleanup(
			mutation_records, cleanup_tick, cleanup_results, seen_specs)
		_append_unique_records(mutation_records, discovered_mutations)
		var mutation_unresolved := _unresolved_recovery_records(mutation_records)
		if mutation_unresolved.is_empty():
			# Mutation captures are proven against the still-live ordinary
			# contributor baseline at this point. Do not invalidate that proof by
			# comparing their historical aggregate again after ordinary cleanup.
			for ordinary_record in ordinary_records:
				discovered_mutations = _attempt_recovery_cleanup(
					[ordinary_record], cleanup_tick, cleanup_results, seen_specs)
				_append_unique_records(mutation_records, discovered_mutations)
				var discovered_unresolved := _unresolved_recovery_records(
					discovered_mutations)
				if not discovered_unresolved.is_empty():
					mutation_unresolved = discovered_unresolved
					break
			if mutation_unresolved.is_empty():
				unresolved_records = _unresolved_recovery_records(ordinary_records)
			else:
				# Stop before another ordinary revoke can change the just-captured
				# aggregate baseline. Component-wide quarantine receives all records.
				unresolved_records = mutation_unresolved
				_append_unique_records(unresolved_records, ordinary_records)
		else:
			# Preserve the aggregate baseline for unresolved partial captures.
			# Quarantine below is component-wide and therefore receives every
			# adapter-owned record, including ordinary records not individually
			# revoked in this branch.
			unresolved_records = mutation_unresolved
			_append_unique_records(unresolved_records, ordinary_records)
		if not unresolved_records.is_empty():
			var quarantine_records: Array[Dictionary] = []
			_append_unique_records(quarantine_records, mutation_records)
			_append_unique_records(quarantine_records, ordinary_records)
			quarantine_result = _ability_port.quarantine(
				quarantine_records, cleanup_tick)
			unresolved_records = _unresolved_recovery_records(quarantine_records)
	_mutation_active = false
	lifecycle = Lifecycle.RECOVERY_REQUIRED
	var previous_sources := current_sources()
	_active_sources.clear()
	_pending_results.clear()
	_pending_result_digests.clear()
	_resync_required = true
	var recovery_details_value := details.duplicate(true)
	recovery_details_value["owned_record_count"] = owned_records.size()
	recovery_details_value["cleanup_results"] = cleanup_results
	recovery_details_value["unresolved_records"] = unresolved_records
	recovery_details_value["quarantine_result"] = quarantine_result
	recovery_details_value["previous_sources"] = previous_sources
	_current_outcome = _base_outcome()
	_current_outcome.merge({
		"accepted": false,
		"changed": false,
		"duplicate": false,
		"initial": false,
		"invalidated": true,
		"recovery_required": true,
		"reason": reason,
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"sources": [],
		"details": recovery_details_value,
	}, true)
	last_error = reason
	var published := current_outcome()
	_emit_reconciliation(published)
	var recovery_publication := recovery_details_value.duplicate(true)
	_make_deep_read_only(recovery_publication)
	recovery_latched.emit(reason, recovery_publication)
	binding_invalidated.emit(reason)
	return published


func _attempt_recovery_cleanup(
	records: Array[Dictionary],
	cleanup_tick: int,
	cleanup_results: Array[Dictionary],
	seen_specs: Dictionary
) -> Array[Dictionary]:
	var discovered_recovery_records: Array[Dictionary] = []
	for record in records:
		var spec := int(record.get("spec", 0))
		if spec <= 0:
			cleanup_results.append({
				"accepted": false,
				"reason": &"equipment_recovery_spec_unavailable",
				"record": record.duplicate(true),
			})
			continue
		if seen_specs.has(spec):
			continue
		seen_specs[spec] = true
		if _ability_port.recovery_record_is_clean(record):
			cleanup_results.append({
				"accepted": true,
				"replayed": true,
				"spec": spec,
				"reason": &"equipment_recovery_already_absent",
			})
			continue
		if _ability_port.grant_record_is_terminally_clean(record):
			cleanup_results.append({
				"accepted": true,
				"replayed": true,
				"spec": spec,
				"reason": &"equipment_recovery_terminally_clean",
			})
			continue
		var revoke_result := _ability_port.revoke(record, cleanup_tick)
		cleanup_results.append(revoke_result.duplicate(true))
		_append_unique_records(discovered_recovery_records,
			_recovery_records_from_result(revoke_result, record))
	return discovered_recovery_records


func _recovery_records_from_result(
	result: Dictionary,
	fallback_record: Dictionary
) -> Array[Dictionary]:
	var recovered: Array[Dictionary] = []
	for value in result.get("recovery_records", []) as Array:
		if value is Dictionary:
			_append_unique_records(recovered, [value as Dictionary])
	# A rejecting participant must surface precise recovery provenance. If it
	# violates that boundary contract, retain a strong fallback record instead
	# of allowing the original committed record's weaker absence check to erase
	# an ambiguous partial mutation.
	if not bool(result.get("accepted", false)) and recovered.is_empty() \
			and not fallback_record.is_empty():
		var fallback := fallback_record.duplicate(true)
		fallback["record_kind"] = &"mutation_recovery"
		_append_unique_records(recovered, [fallback])
	return recovered


func _append_unique_records(
	target: Array[Dictionary],
	candidates: Array
) -> void:
	for value in candidates:
		if not value is Dictionary:
			continue
		var candidate := (value as Dictionary).duplicate(true)
		var already_present := false
		for existing in target:
			if existing == candidate:
				already_present = true
				break
		if not already_present:
			target.append(candidate)


func _unresolved_recovery_records(
	records: Array[Dictionary]
) -> Array[Dictionary]:
	var unresolved: Array[Dictionary] = []
	for record in records:
		if not _ability_port.recovery_record_is_clean(record) \
				and not _ability_port.grant_record_is_terminally_clean(record):
			unresolved.append(record.duplicate(true))
	return unresolved


func _all_grant_records(sources: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var source_keys := PackedStringArray(sources.keys())
	source_keys.sort()
	for source_key in source_keys:
		var source := sources[source_key] as Dictionary
		var records := source.get("grant_records", []) as Array
		for record_value in records:
			result.append((record_value as Dictionary).duplicate(true))
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("input_id", "")) < String(right.get("input_id", "")))
	return result


func _copy_sources(source: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in source.keys():
		result[key] = (source[key] as Dictionary).duplicate(true)
	return result


func _grant_publication(
	source: Dictionary,
	record: Dictionary,
	native_result: Dictionary
) -> Dictionary:
	return {
		"source_item_key": source.get("source_item_key", ""),
		"native_inventory_id": source.get("native_inventory_id", 0),
		"native_item_id": source.get("native_item_id", 0),
		"item_definition_identifier": source.get("item_definition_identifier", &""),
		"slot_identifier": source.get("slot_identifier", &""),
		"ability_identifier": record.get("ability_identifier", &""),
		"input_id": record.get("input_id", ""),
		"spec": record.get("spec", 0),
		"native_result": native_result.duplicate(true),
	}


func _base_outcome() -> Dictionary:
	return {
		"raid_id": _admission.raid_id.canonical_key() if _admission != null else "",
		"session_id": _admission.session_id.canonical_key() if _admission != null else "",
		"actor_id": _admission.actor_id.canonical_key() if _admission != null else "",
		"authority_epoch": _admission.authority_epoch if _admission != null else 0,
		"admission_generation": _admission.generation if _admission != null else 0,
		"owner_generation": _owner_generation,
		"inventory_authority_instance_id": _authority_instance_id,
		"inventory_id": _inventory_id,
		"inventory_manifest_fingerprint": _inventory_manifest_fingerprint,
		"ability_port_token": _ability_port_token,
		"ability_entity_id": _ability_entity_id,
		"declaration_digest": _declaration_digest,
		"tick": _last_tick,
	}


func _duplicate_result(hints: Dictionary) -> Dictionary:
	var result := _base_outcome()
	result.merge({
		"accepted": true,
		"changed": false,
		"duplicate": true,
		"initial": false,
		"invalidated": false,
		"reason": &"duplicate_snapshot",
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"sources": current_sources(),
		"granted": [],
		"revoked": [],
		"result_hints": hints.duplicate(true),
	}, true)
	return result


func _rejection(reason: StringName) -> Dictionary:
	last_error = reason
	var result := _base_outcome()
	result.merge({
		"accepted": false,
		"changed": false,
		"duplicate": false,
		"initial": false,
		"invalidated": false,
		"reason": reason,
		"revision": _last_revision,
		"snapshot_digest": _last_snapshot_digest,
		"sources": current_sources(),
		"granted": [],
		"revoked": [],
	}, true)
	return result


func _emit_reconciliation(
	outcome: Dictionary,
	invalidation_reason: StringName = &""
) -> void:
	var publication := outcome.duplicate(true)
	_make_deep_read_only(publication)
	_public_signal_active = true
	reconciliation_applied.emit(publication)
	if not invalidation_reason.is_empty():
		binding_invalidated.emit(invalidation_reason)
	_public_signal_active = false
	if lifecycle == Lifecycle.BOUND and not _deferred_invalidation_reason.is_empty():
		_process_deferred_invalidation(_last_tick)
	elif lifecycle != Lifecycle.BOUND:
		_deferred_invalidation_reason = &""


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


func _clear_bound_references() -> void:
	_owner = null
	_owner_instance_id = 0
	_authority = null
	_authority_instance_id = 0
	_catalog = null
	_catalog_instance_id = 0
	_admission = null
	_identity_port = null
	_ability_port = null
	_declarations.clear()


func _reset_unbound_state() -> void:
	_disconnect_lifecycle_signals()
	lifecycle = Lifecycle.UNBOUND
	_owner = null
	_owner_instance_id = 0
	_owner_generation = 0
	_raid_authority = null
	_raid_authority_instance_id = 0
	_raid_generation = 0
	_raid_admission_digest = ""
	_phase_registered = false
	_phase_call_active = false
	_authority = null
	_authority_instance_id = 0
	_inventory_id = 0
	_catalog = null
	_catalog_instance_id = 0
	_inventory_manifest_fingerprint = 0
	_inventory_manifest_algorithm = &""
	_admission = null
	_identity_port = null
	_native_actor_id = 0
	_ability_port = null
	_ability_port_token = ""
	_ability_entity_id = 0
	_declarations.clear()
	_declaration_digest = ""
	_last_revision = -1
	_last_snapshot_digest = ""
	_last_tick = 0
	_active_sources.clear()
	_current_outcome.clear()
	_pending_results.clear()
	_pending_result_digests.clear()
	_resync_required = false
	_mutation_active = false
	_public_signal_active = false
	_deferred_invalidation_reason = &""


func _reject_bind(reason: StringName) -> bool:
	last_error = reason
	return false


func _reject_observation(reason: StringName) -> bool:
	last_error = reason
	return false
