class_name InventoryIntentAdapter
extends RefCounted
## Bounded game-owned authorization seam for raid inventory mutations.
##
## The adapter snapshots an admitted ZRaidIntent, resolves its actor through a
## trusted port, validates current inventory/world facts, and performs exactly
## one synchronous InventoryAuthority command. It owns no canonical state.

signal binding_invalidated(reason: StringName)

const INTENT_KIND_TRANSFER: StringName = &"inventory_transfer"
const INTENT_KIND_LOOT: StringName = &"inventory_loot"
const INTENT_KIND_MOVE: StringName = &"inventory_move"
const INTENT_KIND_ROTATE: StringName = &"inventory_rotate"
const INTENT_KIND_SPLIT: StringName = &"inventory_split"
const INTENT_KIND_MERGE: StringName = &"inventory_merge"
const INTENT_KIND_QUICK_TRANSFER: StringName = &"inventory_quick_transfer"
const SUPPORTED_INTENT_KINDS: Array[StringName] = [
	INTENT_KIND_TRANSFER,
	INTENT_KIND_LOOT,
	INTENT_KIND_MOVE,
	INTENT_KIND_ROTATE,
	INTENT_KIND_SPLIT,
	INTENT_KIND_MERGE,
	INTENT_KIND_QUICK_TRANSFER,
]
const DEFAULT_PHASE_HANDLER_ID: StringName = &"inventory_intent_adapter"
const MAX_TRACKED_REQUESTS: int = 1024
const MAX_SEQUENCE: int = 2_147_483_647

const _TRANSFER_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"source_inventory_id",
	"destination_inventory_id",
	"item_id",
	"expected_source_revision",
	"expected_destination_revision",
]
const _LOOT_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"source_inventory_id",
	"destination_inventory_id",
	"item_id",
	"destination_location",
	"expected_source_revision",
	"expected_destination_revision",
]
const _MOVE_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"inventory_id",
	"item_id",
	"destination_location",
	"expected_revision",
]
const _ROTATE_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"inventory_id",
	"item_id",
	"rotated",
	"expected_revision",
]
const _SPLIT_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"inventory_id",
	"item_id",
	"quantity",
	"destination_location",
	"expected_revision",
]
const _MERGE_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"inventory_id",
	"source_item_id",
	"destination_item_id",
	"expected_revision",
]
const _QUICK_TRANSFER_PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"source_inventory_id",
	"destination_inventory_id",
	"item_id",
	"expected_source_revision",
	"expected_destination_revision",
]
const _LOCATION_FULL_KEYS: PackedStringArray = [
	"kind",
	"container",
	"x",
	"y",
	"rotated",
	"slot_identifier",
	"ordinal",
]
const _LOCATION_SPATIAL_KEYS: PackedStringArray = [
	"kind", "container", "x", "y", "rotated",
]
const _LOCATION_SLOT_KEYS: PackedStringArray = [
	"kind", "container", "slot_identifier",
]
const _LOCATION_LIST_KEYS: PackedStringArray = [
	"kind", "container", "ordinal",
]

const _INTERNAL_HANDLER_FAILURES: Dictionary = {
	&"adapter_not_configured": true,
	&"handler_authority_mismatch": true,
	&"handler_phase_invalid": true,
	&"handler_tick_invalid": true,
	&"native_command_id_mismatch": true,
	&"native_command_replay_unexpected": true,
	&"native_result_invalid": true,
	&"native_revision_mismatch": true,
	&"native_transfer_deferred": true,
	&"reentrant_submission": true,
	&"stale_generation": true,
}

var last_error: StringName = &""

var _configured: bool = false
var _owner: RaidInventoryOwner
var _authority: InventoryAuthority
var _admission: ZSessionAdmission
var _identity_port: ZInventoryIdentityPort
var _world_policy_port: ZInventoryWorldPolicyPort
var _owner_generation: int = 0
var _max_transfer_distance_raw: int = 0
var _request_ledger: Dictionary = {}
var _command_bindings: Dictionary = {}
var _submission_active: bool = false
var _native_call_active: bool = false
var _raid_authority_instance_id: int = 0
var _invalidated: bool = false
var _invalidation_emitted: bool = false
var _deferred_invalidation_reason: StringName = &""
var _clear_replay_on_invalidation: bool = false
var _inventory_unloaded_callback: Callable
var _inventory_generation_callback: Callable
var _owner_tree_exiting_callback: Callable


func configure(
	owner: RaidInventoryOwner,
	admission: ZSessionAdmission,
	identity_port: ZInventoryIdentityPort,
	world_policy_port: ZInventoryWorldPolicyPort,
	max_transfer_distance_raw: int
) -> bool:
	last_error = &""
	if _configured:
		return _reject_configuration(&"adapter_already_configured")
	if owner == null or not is_instance_valid(owner):
		return _reject_configuration(&"inventory_owner_invalid")
	var captured_owner_generation := owner.generation()
	if not owner.is_current_generation(captured_owner_generation):
		return _reject_configuration(&"inventory_owner_inactive")
	var authority := owner.raid_authority()
	if authority == null or not is_instance_valid(authority):
		return _reject_configuration(&"inventory_authority_missing")
	if admission == null or not admission.is_usable():
		return _reject_configuration(&"session_admission_invalid")
	var admission_copy := admission.snapshot()
	if admission_copy == null:
		return _reject_configuration(&"session_admission_invalid")
	if identity_port == null:
		return _reject_configuration(&"identity_port_missing")
	if world_policy_port == null:
		return _reject_configuration(&"world_policy_port_missing")
	if max_transfer_distance_raw <= 0 \
		or max_transfer_distance_raw > ZWorldUnits.MAX_CANONICAL_RAW:
		return _reject_configuration(&"transfer_distance_invalid")

	_owner = owner
	_authority = authority
	_admission = admission_copy
	_identity_port = identity_port
	_world_policy_port = world_policy_port
	_owner_generation = captured_owner_generation
	_max_transfer_distance_raw = max_transfer_distance_raw
	_configured = true
	_connect_lifecycle_signals()
	return true


func is_bound() -> bool:
	return _configured and not _invalidated and _owner_is_current()


func owner_generation() -> int:
	return _owner_generation


## Read-only world-container facts for presentation consumers.  This mirrors
## the same trusted policy port used by mutation admission, but deliberately
## does not inspect an item, create a request, or advance any authority state.
func world_policy_state(inventory_id: int) -> Dictionary:
	var result := {
		"available": false,
		"reason": &"inventory_runtime_unbound",
		"inventory_id": inventory_id,
		"distance_raw": -1,
		"access": ZInventoryWorldPolicyPort.ACCESS_UNAVAILABLE,
	}
	if not is_bound() or inventory_id <= 0:
		return result
	if not _world_policy_port.is_world_inventory(
		_admission.actor_id, inventory_id, _admission.generation):
		result.reason = &"world_target_invalid"
		return result
	var distance_raw := _world_policy_port.authoritative_distance_raw(
		_admission.actor_id, inventory_id, _admission.generation)
	result.distance_raw = distance_raw
	if distance_raw < 0:
		result.reason = &"distance_unavailable"
		return result
	if distance_raw > _max_transfer_distance_raw:
		result.reason = &"out_of_range"
		return result
	if not _world_policy_port.is_currently_visible(
		_admission.actor_id, inventory_id, _admission.generation):
		result.reason = &"not_visible"
		return result
	var access := _world_policy_port.access_state(
		_admission.actor_id, inventory_id, _admission.generation)
	result.access = access
	if access != ZInventoryWorldPolicyPort.ACCESS_OPEN:
		result.reason = &"access_closed"
		return result
	result.available = true
	result.reason = &""
	return result


func matches_binding(
	owner: RaidInventoryOwner,
	admission: ZSessionAdmission
) -> bool:
	return is_bound() and owner != null and admission != null \
		and _owner == owner and _authority == owner.raid_authority() \
		and _owner_generation == owner.generation() \
		and _admissions_match(_admission, admission)


## The registered raid phase handler intentionally remains a stable no-op
## after release. RaidAuthority owns that Callable until its own terminal edge.
func release_binding(reason: StringName = &"inventory_intent_adapter_released") -> bool:
	last_error = &""
	if not _configured or _invalidated:
		return _reject_configuration(&"adapter_not_bound")
	if _submission_active or _native_call_active:
		return _reject_configuration(&"reentrant_binding_change")
	_request_invalidation(reason if not reason.is_empty() \
		else &"inventory_intent_adapter_released", true)
	return true


## Registers only the explicit allowlist in the canonical interaction phase.
func register_with_raid_authority(
	raid_authority: RaidAuthority,
	handler_id: StringName = DEFAULT_PHASE_HANDLER_ID
) -> bool:
	last_error = &""
	if not _configured or _invalidated:
		return _reject_configuration(&"adapter_not_configured")
	if raid_authority == null or not is_instance_valid(raid_authority):
		return _reject_configuration(&"raid_authority_invalid")
	if _raid_authority_instance_id != 0:
		return _reject_configuration(&"raid_authority_already_registered")
	var raid_admission := raid_authority.admission()
	if raid_admission == null or not _admissions_match(raid_admission, _admission):
		return _reject_configuration(&"raid_authority_admission_mismatch")
	if not raid_authority.register_phase_handler(
		RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS,
		handler_id,
		Callable(self, "handle_raid_phase"),
		_admission.generation
	):
		return _reject_configuration(raid_authority.last_error)
	_raid_authority_instance_id = raid_authority.get_instance_id()
	return true


## Business rejection is a handled intent result, never a false failed tick.
func handle_raid_phase(
	raid_authority: RaidAuthority,
	phase: RaidAuthority.TickPhase,
	tick: int,
	intents: Array[ZRaidIntent]
) -> bool:
	last_error = &""
	if raid_authority == null or not is_instance_valid(raid_authority) \
		or _raid_authority_instance_id == 0 \
		or raid_authority.get_instance_id() != _raid_authority_instance_id:
		last_error = &"handler_authority_mismatch"
		return false
	if phase != RaidAuthority.TickPhase.INTERACTIONS_AND_WEAPONS:
		last_error = &"handler_phase_invalid"
		return false
	if _invalidated:
		return true
	for intent in intents:
		if intent == null or not SUPPORTED_INTENT_KINDS.has(intent.kind):
			continue
		if intent.target_tick != tick:
			last_error = &"handler_tick_invalid"
			return false
		var result := submit_intent(intent)
		if _invalidated:
			return true
		var reason := StringName(result.get("reason", &""))
		if _INTERNAL_HANDLER_FAILURES.has(reason):
			last_error = reason
			return false
	last_error = &""
	return true


## Result includes both product request identity and a separate positive
## inventory command identity. `command_id` is the presentation-compatible
## alias; `native_command_id` records what InventoryAuthority returned.
func submit_intent(intent: ZRaidIntent) -> Dictionary:
	# Policy and identity ports are synchronous callback boundaries. Guard the
	# complete submission so a callback cannot commit before its outer receipt.
	if _submission_active:
		return _result(false, false, &"reentrant_submission")
	_submission_active = true
	var result := _submit_intent_once(intent)
	_submission_active = false
	_finish_deferred_invalidation()
	return result


func _submit_intent_once(intent: ZRaidIntent) -> Dictionary:
	last_error = &""
	if not _configured:
		return _result(false, false, &"adapter_not_configured")
	if intent == null:
		return _result(false, false, &"intent_missing")
	if not _valid_request_id(intent.request_id):
		return _result(false, false, &"request_id_invalid")
	var request_key := intent.request_id.canonical_key()
	if not _valid_session_id(intent.session_id) \
		or not intent.session_id.is_equal(_admission.session_id):
		return _result(false, false, &"session_mismatch", request_key)
	if not _valid_actor_id(intent.actor_id) \
		or not intent.actor_id.is_equal(_admission.actor_id):
		return _result(false, false, &"actor_mismatch", request_key)
	if intent.authority_epoch != _admission.authority_epoch:
		return _result(false, false, &"authority_epoch_mismatch", request_key)
	if intent.generation != _admission.generation:
		return _result(false, false, &"stale_generation", request_key)
	if intent.source != ZRaidIntent.Source.PLAYER:
		return _result(false, false, &"intent_source_invalid", request_key)
	if not SUPPORTED_INTENT_KINDS.has(intent.kind):
		return _result(false, false, &"intent_kind_unsupported", request_key)
	if intent.target_tick <= 0 or intent.sequence <= 0 or intent.sequence > MAX_SEQUENCE:
		return _result(false, false, &"intent_order_invalid", request_key)
	if not ZCanonicalValue.is_bounded(intent.payload):
		return _result(false, false, &"payload_invalid_or_unbounded", request_key)

	# Copy once: later caller/port mutation cannot alter fingerprinted facts.
	var intent_copy := intent.snapshot()
	if intent_copy == null:
		return _result(false, false, &"intent_snapshot_invalid", request_key)
	var fingerprint := _intent_fingerprint(intent_copy)
	if fingerprint.is_empty():
		return _result(false, false, &"intent_fingerprint_invalid", request_key)

	# Replay/conflict lookup precedes all mutable owner, revision, identity,
	# visibility, access, distance, and policy facts.
	if _request_ledger.has(request_key):
		return _replay_or_conflict(request_key, fingerprint)
	if _invalidated:
		return _result(false, false, &"stale_generation", request_key)
	if _request_ledger.size() >= MAX_TRACKED_REQUESTS:
		return _result(false, false, &"request_history_full", request_key)

	var payload := _normalize_payload(intent_copy.kind, intent_copy.payload)
	if payload.is_empty():
		return _complete_rejection(
			request_key, fingerprint, last_error, 0, intent_copy.kind)
	var inventory_command_id := int(payload["inventory_command_id"])

	# Bind the native command identity to exactly one product request. This gate
	# is before policy so a reused client value cannot select an earlier result.
	if _command_bindings.has(inventory_command_id):
		var binding := _command_bindings[inventory_command_id] as Dictionary
		if String(binding.get("request_id", "")) != request_key \
			or String(binding.get("fingerprint", "")) != fingerprint:
			return _complete_rejection(
				request_key,
				fingerprint,
				&"inventory_command_id_conflict",
				inventory_command_id,
				intent_copy.kind
			)
	if not _owner_is_current():
		return _complete_rejection(
			request_key, fingerprint, &"stale_generation", inventory_command_id,
			intent_copy.kind)
	if _native_call_active:
		return _result(
			false, false, &"reentrant_submission", request_key, inventory_command_id)
	_command_bindings[inventory_command_id] = {
		"request_id": request_key,
		"fingerprint": fingerprint,
	}
	if intent_copy.kind != INTENT_KIND_TRANSFER:
		return _submit_routed_mutation(
			intent_copy.kind,
			payload,
			request_key,
			fingerprint,
			inventory_command_id
		)

	var source_inventory_id := int(payload["source_inventory_id"])
	var destination_inventory_id := int(payload["destination_inventory_id"])
	var item_id := int(payload["item_id"])
	var native_actor_id := _resolve_native_actor_id()
	if native_actor_id <= 0:
		return _complete_rejection(
			request_key, fingerprint, &"actor_identity_unresolved", inventory_command_id)
	if not _actor_owns_destination(destination_inventory_id):
		return _complete_rejection(
			request_key, fingerprint, &"destination_not_owned", inventory_command_id)
	if not _authority.has_inventory(source_inventory_id) \
		or not _authority.has_inventory(destination_inventory_id):
		return _complete_rejection(
			request_key, fingerprint, &"inventory_not_found", inventory_command_id)

	var source_revision := _authority.inventory_revision(source_inventory_id)
	var destination_revision := _authority.inventory_revision(destination_inventory_id)
	if source_revision != int(payload["expected_source_revision"]):
		return _complete_rejection(
			request_key, fingerprint, &"source_revision_stale", inventory_command_id)
	if destination_revision != int(payload["expected_destination_revision"]):
		return _complete_rejection(
			request_key, fingerprint, &"destination_revision_stale", inventory_command_id)

	var policy_reason := _world_policy_rejection(
		source_inventory_id, destination_inventory_id, item_id)
	if not policy_reason.is_empty():
		return _complete_rejection(
			request_key, fingerprint, policy_reason, inventory_command_id)
	if not _inventory_contains_item(source_inventory_id, item_id):
		return _complete_rejection(
			request_key,
			fingerprint,
			&"item_not_owned_by_source",
			inventory_command_id
		)

	# Trusted ports must be pure, but re-read every mutable fact after the final
	# policy call so a once-true observation cannot authorize the transaction.
	if not _owner_is_current():
		return _complete_rejection(
			request_key, fingerprint, &"stale_generation", inventory_command_id)
	if _resolve_native_actor_id() != native_actor_id:
		return _complete_rejection(
			request_key, fingerprint, &"actor_identity_changed", inventory_command_id)
	if not _actor_owns_destination(destination_inventory_id):
		return _complete_rejection(
			request_key, fingerprint, &"destination_not_owned", inventory_command_id)
	if not _authority.has_inventory(source_inventory_id) \
		or not _authority.has_inventory(destination_inventory_id):
		return _complete_rejection(
			request_key, fingerprint, &"inventory_not_found", inventory_command_id)
	if _authority.inventory_revision(source_inventory_id) != source_revision:
		return _complete_rejection(
			request_key, fingerprint, &"source_revision_stale", inventory_command_id)
	if _authority.inventory_revision(destination_inventory_id) != destination_revision:
		return _complete_rejection(
			request_key, fingerprint, &"destination_revision_stale", inventory_command_id)
	policy_reason = _world_policy_rejection(
		source_inventory_id, destination_inventory_id, item_id)
	if not policy_reason.is_empty():
		return _complete_rejection(
			request_key, fingerprint, policy_reason, inventory_command_id)
	if not _inventory_contains_item(source_inventory_id, item_id):
		return _complete_rejection(
			request_key,
			fingerprint,
			&"item_not_owned_by_source",
			inventory_command_id
		)
	if not _owner_is_current():
		return _complete_rejection(
			request_key, fingerprint, &"stale_generation", inventory_command_id)
	if _resolve_native_actor_id() != native_actor_id:
		return _complete_rejection(
			request_key, fingerprint, &"actor_identity_changed", inventory_command_id)
	if not _actor_owns_destination(destination_inventory_id):
		return _complete_rejection(
			request_key, fingerprint, &"destination_not_owned", inventory_command_id)
	if not _authority.has_inventory(source_inventory_id) \
		or not _authority.has_inventory(destination_inventory_id):
		return _complete_rejection(
			request_key, fingerprint, &"inventory_not_found", inventory_command_id)
	if _authority.inventory_revision(source_inventory_id) != source_revision:
		return _complete_rejection(
			request_key, fingerprint, &"source_revision_stale", inventory_command_id)
	if _authority.inventory_revision(destination_inventory_id) != destination_revision:
		return _complete_rejection(
			request_key, fingerprint, &"destination_revision_stale", inventory_command_id)
	if not _inventory_contains_item(source_inventory_id, item_id):
		return _complete_rejection(
			request_key, fingerprint, &"item_not_owned_by_source", inventory_command_id)

	# Complete-only, synchronous, and explicitly idempotent in the native
	# command domain. Zero/auto allocation is forbidden at this boundary.
	_native_call_active = true
	var native_result: Dictionary = _authority.quick_transfer_item(
		source_inventory_id,
		destination_inventory_id,
		item_id,
		false,
		native_actor_id,
		inventory_command_id
	)
	_native_call_active = false
	if not _native_result_shape_valid(native_result):
		return _complete_native_result(
			request_key, fingerprint, native_result, false,
			&"native_result_invalid", inventory_command_id,
			source_inventory_id, destination_inventory_id)
	if int(native_result.get("command_id", 0)) != inventory_command_id:
		return _complete_native_result(
			request_key, fingerprint, native_result, false,
			&"native_command_id_mismatch", inventory_command_id,
			source_inventory_id, destination_inventory_id)
	if bool(native_result.get("queued", false)):
		return _complete_native_result(
			request_key, fingerprint, native_result, false,
			&"native_transfer_deferred", inventory_command_id,
			source_inventory_id, destination_inventory_id)
	if bool(native_result.get("replayed", false)):
		return _complete_native_result(
			request_key, fingerprint, native_result, false,
			&"native_command_replay_unexpected", inventory_command_id,
			source_inventory_id, destination_inventory_id)
	if not bool(native_result.get("accepted", false)):
		return _complete_native_result(
			request_key, fingerprint, native_result, false,
			&"native_transfer_rejected", inventory_command_id,
			source_inventory_id, destination_inventory_id)
	if not _accepted_revisions_match(
		native_result,
		source_inventory_id,
		destination_inventory_id,
		source_revision,
		destination_revision
	):
		return _complete_native_result(
			request_key, fingerprint, native_result, false,
			&"native_revision_mismatch", inventory_command_id,
			source_inventory_id, destination_inventory_id)
	return _complete_native_result(
		request_key, fingerprint, native_result, true, &"",
		inventory_command_id, source_inventory_id, destination_inventory_id)


func tracked_request_count() -> int:
	return _request_ledger.size()


func tracked_command_count() -> int:
	return _command_bindings.size()


func receipt_for_request(request_id: ZRequestId) -> Dictionary:
	if not _valid_request_id(request_id):
		return {}
	var entry := _request_ledger.get(request_id.canonical_key(), {}) as Dictionary
	return (entry.get("result", {}) as Dictionary).duplicate(true)


func _submit_routed_mutation(
	operation: StringName,
	payload: Dictionary,
	request_key: String,
	fingerprint: String,
	inventory_command_id: int
) -> Dictionary:
	var native_actor_id := _resolve_native_actor_id()
	if native_actor_id <= 0:
		return _complete_rejection(
			request_key, fingerprint, &"actor_identity_unresolved",
			inventory_command_id, operation)
	var shape := _routed_shape(operation, payload)
	if shape.is_empty():
		return _complete_rejection(
			request_key, fingerprint, &"payload_schema_invalid",
			inventory_command_id, operation)

	var validation := _routed_fact_validation(
		operation, payload, shape, native_actor_id)
	var reason := StringName(validation.get("reason", &""))
	if not reason.is_empty():
		return _complete_rejection(
			request_key, fingerprint, reason, inventory_command_id, operation)
	var world_inventory_id := int(validation.get("world_inventory_id", 0))
	if world_inventory_id > 0:
		reason = _world_policy_rejection(
			int(shape["source_inventory_id"]),
			int(shape["destination_inventory_id"]),
			int(shape["primary_item_id"]),
			world_inventory_id
		)
		if not reason.is_empty():
			return _complete_rejection(
				request_key, fingerprint, reason, inventory_command_id, operation)

	# Re-read all trusted identity, ownership, item, inventory, and revision facts
	# after policy. Then repeat policy and one final fact pass so the last policy
	# observation cannot authorize against facts it invalidated.
	validation = _routed_fact_validation(
		operation, payload, shape, native_actor_id)
	reason = StringName(validation.get("reason", &""))
	if not reason.is_empty():
		return _complete_rejection(
			request_key, fingerprint, reason, inventory_command_id, operation)
	if int(validation.get("world_inventory_id", 0)) != world_inventory_id:
		return _complete_rejection(
			request_key, fingerprint, &"world_target_changed",
			inventory_command_id, operation)
	if world_inventory_id > 0:
		reason = _world_policy_rejection(
			int(shape["source_inventory_id"]),
			int(shape["destination_inventory_id"]),
			int(shape["primary_item_id"]),
			world_inventory_id
		)
		if not reason.is_empty():
			return _complete_rejection(
				request_key, fingerprint, reason, inventory_command_id, operation)
	validation = _routed_fact_validation(
		operation, payload, shape, native_actor_id)
	reason = StringName(validation.get("reason", &""))
	if not reason.is_empty():
		return _complete_rejection(
			request_key, fingerprint, reason, inventory_command_id, operation)
	if int(validation.get("world_inventory_id", 0)) != world_inventory_id:
		return _complete_rejection(
			request_key, fingerprint, &"world_target_changed",
			inventory_command_id, operation)

	_native_call_active = true
	var native_result := _invoke_routed_native(
		operation, payload, native_actor_id, inventory_command_id)
	_native_call_active = false
	return _finish_routed_native_result(
		request_key,
		fingerprint,
		operation,
		payload,
		shape,
		native_result,
		inventory_command_id
	)


func _routed_fact_validation(
	operation: StringName,
	payload: Dictionary,
	shape: Dictionary,
	native_actor_id: int
) -> Dictionary:
	var denied := {"reason": &"", "world_inventory_id": 0}
	if not _owner_is_current():
		denied["reason"] = &"stale_generation"
		return denied
	if _resolve_native_actor_id() != native_actor_id:
		denied["reason"] = &"actor_identity_changed"
		return denied
	var source_inventory_id := int(shape["source_inventory_id"])
	var destination_inventory_id := int(shape["destination_inventory_id"])
	if not _actor_owns_inventory(destination_inventory_id):
		denied["reason"] = &"destination_not_owned"
		return denied
	var source_is_world := _world_policy_port.is_world_inventory(
		_admission.actor_id, source_inventory_id, _admission.generation)
	var destination_is_world := source_is_world \
		if source_inventory_id == destination_inventory_id \
		else _world_policy_port.is_world_inventory(
			_admission.actor_id, destination_inventory_id, _admission.generation)
	if source_is_world and destination_is_world \
		and source_inventory_id != destination_inventory_id:
		denied["reason"] = &"multiple_world_targets_unsupported"
		return denied
	if operation == INTENT_KIND_LOOT and not source_is_world:
		denied["reason"] = &"world_target_invalid"
		return denied
	if source_inventory_id != destination_inventory_id \
		and not source_is_world \
		and not _actor_owns_inventory(source_inventory_id):
		denied["reason"] = &"source_not_owned"
		return denied
	var expected_revisions := _expected_revisions(operation, payload, shape)
	if expected_revisions.is_empty():
		denied["reason"] = &"payload_schema_invalid"
		return denied
	for inventory_id_value in expected_revisions:
		var inventory_id := int(inventory_id_value)
		if not _authority.has_inventory(inventory_id):
			denied["reason"] = &"inventory_not_found"
			return denied
		if _authority.inventory_revision(inventory_id) \
			!= int(expected_revisions[inventory_id_value]):
			denied["reason"] = _revision_rejection_for(
				inventory_id, source_inventory_id, destination_inventory_id)
			return denied
	if not _inventory_contains_item(source_inventory_id, int(shape["primary_item_id"])):
		denied["reason"] = &"item_not_owned_by_source"
		return denied
	var secondary_item_id := int(shape.get("secondary_item_id", 0))
	if secondary_item_id > 0 \
		and not _inventory_contains_item(source_inventory_id, secondary_item_id):
		denied["reason"] = &"secondary_item_not_owned_by_source"
		return denied
	if source_is_world:
		denied["world_inventory_id"] = source_inventory_id
	elif destination_is_world:
		denied["world_inventory_id"] = destination_inventory_id
	return denied


func _routed_shape(operation: StringName, payload: Dictionary) -> Dictionary:
	match operation:
		INTENT_KIND_LOOT, INTENT_KIND_QUICK_TRANSFER:
			return {
				"source_inventory_id": int(payload["source_inventory_id"]),
				"destination_inventory_id": int(payload["destination_inventory_id"]),
				"primary_item_id": int(payload["item_id"]),
				"secondary_item_id": 0,
			}
		INTENT_KIND_MOVE, INTENT_KIND_ROTATE, INTENT_KIND_SPLIT:
			return {
				"source_inventory_id": int(payload["inventory_id"]),
				"destination_inventory_id": int(payload["inventory_id"]),
				"primary_item_id": int(payload["item_id"]),
				"secondary_item_id": 0,
			}
		INTENT_KIND_MERGE:
			return {
				"source_inventory_id": int(payload["inventory_id"]),
				"destination_inventory_id": int(payload["inventory_id"]),
				"primary_item_id": int(payload["source_item_id"]),
				"secondary_item_id": int(payload["destination_item_id"]),
			}
	return {}


func _expected_revisions(
	operation: StringName,
	payload: Dictionary,
	shape: Dictionary
) -> Dictionary:
	var revisions: Dictionary = {}
	match operation:
		INTENT_KIND_LOOT, INTENT_KIND_QUICK_TRANSFER:
			var source_inventory_id := int(shape["source_inventory_id"])
			var destination_inventory_id := int(shape["destination_inventory_id"])
			revisions[source_inventory_id] = int(payload["expected_source_revision"])
			if destination_inventory_id != source_inventory_id:
				revisions[destination_inventory_id] = int(
					payload["expected_destination_revision"])
		INTENT_KIND_MOVE, INTENT_KIND_ROTATE, INTENT_KIND_SPLIT, INTENT_KIND_MERGE:
			revisions[int(shape["source_inventory_id"])] = int(payload["expected_revision"])
	return revisions


func _revision_rejection_for(
	inventory_id: int,
	source_inventory_id: int,
	destination_inventory_id: int
) -> StringName:
	if source_inventory_id == destination_inventory_id:
		return &"inventory_revision_stale"
	if inventory_id == source_inventory_id:
		return &"source_revision_stale"
	return &"destination_revision_stale"


func _owner_is_current() -> bool:
	return (
		not _invalidated
		and _owner != null
		and is_instance_valid(_owner)
		and _owner.is_current_generation(_owner_generation)
		and _authority != null
		and is_instance_valid(_authority)
		and _owner.raid_authority() == _authority
	)


func _connect_lifecycle_signals() -> void:
	_inventory_unloaded_callback = Callable(self, "_on_inventory_unloaded").bind(
		_authority.get_instance_id())
	_inventory_generation_callback = Callable(
		self, "_on_inventory_generation_changing").bind(
		_authority.get_instance_id())
	_owner_tree_exiting_callback = Callable(self, "_on_owner_tree_exiting")
	_authority.inventory_unloaded.connect(_inventory_unloaded_callback)
	_authority.inventory_generation_changing.connect(_inventory_generation_callback)
	_owner.tree_exiting.connect(_owner_tree_exiting_callback)


func _disconnect_lifecycle_signals() -> void:
	if _authority != null and is_instance_valid(_authority):
		if _inventory_unloaded_callback.is_valid() \
				and _authority.inventory_unloaded.is_connected(
					_inventory_unloaded_callback):
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
	_inventory_unloaded_callback = Callable()
	_inventory_generation_callback = Callable()
	_owner_tree_exiting_callback = Callable()


func _on_inventory_unloaded(inventory_id: int, expected_authority_id: int) -> void:
	if _lifecycle_callback_is_current(inventory_id, expected_authority_id):
		# A completed receipt remains a safe immutable answer after teardown; no
		# new request can pass the invalidated binding gate below it.
		_request_invalidation(&"inventory_unloaded", false)


func _on_inventory_generation_changing(
	inventory_id: int,
	expected_authority_id: int
) -> void:
	if _lifecycle_callback_is_current(inventory_id, expected_authority_id):
		# Same-id replacement resets the add-on's scoped idempotency journal. The
		# game-owned receipt/command ledgers must cross the generation edge too.
		_request_invalidation(&"inventory_generation_changing", true)


func _on_owner_tree_exiting() -> void:
	_request_invalidation(&"inventory_owner_tree_exiting", false)


func _lifecycle_callback_is_current(
	inventory_id: int,
	expected_authority_id: int
) -> bool:
	return not _invalidated and _owner != null and is_instance_valid(_owner) \
		and _authority != null and is_instance_valid(_authority) \
		and _authority.get_instance_id() == expected_authority_id \
		and inventory_id in [
			_owner.raid_player_inventory_id,
			_owner.world_crate_inventory_id,
			_owner.corpse_inventory_id,
		]


func _request_invalidation(reason: StringName, clear_replay: bool) -> void:
	if not _configured or _invalidation_emitted or _invalidated:
		return
	_invalidated = true
	_clear_replay_on_invalidation = _clear_replay_on_invalidation or clear_replay
	if clear_replay:
		_request_ledger.clear()
		_command_bindings.clear()
	last_error = reason
	if _submission_active or _native_call_active:
		_deferred_invalidation_reason = reason
		return
	_finalize_invalidation(reason)


func _finish_deferred_invalidation() -> void:
	if _deferred_invalidation_reason.is_empty() or _invalidation_emitted:
		return
	var reason := _deferred_invalidation_reason
	_deferred_invalidation_reason = &""
	_finalize_invalidation(reason)


func _finalize_invalidation(reason: StringName) -> void:
	if _invalidation_emitted:
		return
	_disconnect_lifecycle_signals()
	if _clear_replay_on_invalidation:
		# A submission interrupted by the generation signal can construct a local
		# rejection while it unwinds. Clear again at the final boundary so neither
		# that result nor any pre-generation receipt survives replacement.
		_request_ledger.clear()
		_command_bindings.clear()
	_invalidation_emitted = true
	last_error = reason
	_owner = null
	_authority = null
	_identity_port = null
	_world_policy_port = null
	binding_invalidated.emit(reason)


func _normalize_payload(kind: StringName, payload: Dictionary) -> Dictionary:
	last_error = &"payload_schema_invalid"
	var expected_keys := _payload_keys_for_kind(kind)
	if expected_keys.is_empty() or payload.size() != expected_keys.size():
		return {}
	var normalized := _normalize_exact_dictionary(payload, expected_keys)
	if normalized.is_empty():
		return {}
	if typeof(normalized.get("inventory_command_id", null)) != TYPE_INT \
		or int(normalized["inventory_command_id"]) <= 0:
		return {}

	match kind:
		INTENT_KIND_TRANSFER, INTENT_KIND_QUICK_TRANSFER:
			if not _positive_int_fields(normalized, [
				"source_inventory_id", "destination_inventory_id", "item_id"
			]) or not _nonnegative_int_fields(normalized, [
				"expected_source_revision", "expected_destination_revision"
			]):
				return {}
			if kind == INTENT_KIND_TRANSFER \
				and int(normalized["source_inventory_id"]) \
				== int(normalized["destination_inventory_id"]):
				return {}
			if int(normalized["source_inventory_id"]) \
				== int(normalized["destination_inventory_id"]) \
				and int(normalized["expected_source_revision"]) \
				!= int(normalized["expected_destination_revision"]):
				return {}
		INTENT_KIND_LOOT:
			if not _positive_int_fields(normalized, [
				"source_inventory_id", "destination_inventory_id", "item_id"
			]) or not _nonnegative_int_fields(normalized, [
				"expected_source_revision", "expected_destination_revision"
			]):
				return {}
			if int(normalized["source_inventory_id"]) \
				== int(normalized["destination_inventory_id"]):
				return {}
			var loot_location := _normalize_location(
				normalized.get("destination_location", null))
			if loot_location.is_empty():
				return {}
			normalized["destination_location"] = loot_location
		INTENT_KIND_MOVE:
			if not _positive_int_fields(normalized, ["inventory_id", "item_id"]) \
				or not _nonnegative_int_fields(normalized, ["expected_revision"]):
				return {}
			var move_location := _normalize_location(
				normalized.get("destination_location", null))
			if move_location.is_empty():
				return {}
			normalized["destination_location"] = move_location
		INTENT_KIND_ROTATE:
			if not _positive_int_fields(normalized, ["inventory_id", "item_id"]) \
				or not _nonnegative_int_fields(normalized, ["expected_revision"]) \
				or typeof(normalized.get("rotated", null)) != TYPE_BOOL:
				return {}
		INTENT_KIND_SPLIT:
			if not _positive_int_fields(normalized, [
				"inventory_id", "item_id", "quantity"
			]) or not _nonnegative_int_fields(normalized, ["expected_revision"]):
				return {}
			var split_location := _normalize_location(
				normalized.get("destination_location", null))
			if split_location.is_empty():
				return {}
			normalized["destination_location"] = split_location
		INTENT_KIND_MERGE:
			if not _positive_int_fields(normalized, [
				"inventory_id", "source_item_id", "destination_item_id"
			]) or not _nonnegative_int_fields(normalized, ["expected_revision"]):
				return {}
			if int(normalized["source_item_id"]) == int(normalized["destination_item_id"]):
				return {}
		_:
			return {}
	last_error = &""
	return normalized


func _payload_keys_for_kind(kind: StringName) -> PackedStringArray:
	match kind:
		INTENT_KIND_TRANSFER:
			return _TRANSFER_PAYLOAD_KEYS
		INTENT_KIND_LOOT:
			return _LOOT_PAYLOAD_KEYS
		INTENT_KIND_MOVE:
			return _MOVE_PAYLOAD_KEYS
		INTENT_KIND_ROTATE:
			return _ROTATE_PAYLOAD_KEYS
		INTENT_KIND_SPLIT:
			return _SPLIT_PAYLOAD_KEYS
		INTENT_KIND_MERGE:
			return _MERGE_PAYLOAD_KEYS
		INTENT_KIND_QUICK_TRANSFER:
			return _QUICK_TRANSFER_PAYLOAD_KEYS
	return PackedStringArray()


func _normalize_exact_dictionary(value: Dictionary, keys: PackedStringArray) -> Dictionary:
	if value.size() != keys.size():
		return {}
	var normalized: Dictionary = {}
	for key_value in value:
		if typeof(key_value) != TYPE_STRING and typeof(key_value) != TYPE_STRING_NAME:
			return {}
		var key := String(key_value)
		if not keys.has(key) or normalized.has(key):
			return {}
		normalized[key] = value[key_value]
	for key in keys:
		if not normalized.has(key):
			return {}
	return normalized


func _positive_int_fields(value: Dictionary, fields: Array) -> bool:
	for field_value in fields:
		var field := String(field_value)
		if typeof(value.get(field, null)) != TYPE_INT or int(value[field]) <= 0:
			return false
	return true


func _nonnegative_int_fields(value: Dictionary, fields: Array) -> bool:
	for field_value in fields:
		var field := String(field_value)
		if typeof(value.get(field, null)) != TYPE_INT or int(value[field]) < 0:
			return false
	return true


func _normalize_location(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var raw := value as Dictionary
	var kind_value: Variant = raw.get("kind", null)
	if typeof(kind_value) != TYPE_STRING and typeof(kind_value) != TYPE_STRING_NAME:
		return {}
	var kind := String(kind_value)
	var minimal_keys := PackedStringArray()
	match kind:
		"spatial":
			minimal_keys = _LOCATION_SPATIAL_KEYS
		"slot":
			minimal_keys = _LOCATION_SLOT_KEYS
		"list":
			minimal_keys = _LOCATION_LIST_KEYS
		_:
			return {}
	var normalized := _normalize_exact_dictionary(raw, minimal_keys)
	var used_full_shape := false
	if normalized.is_empty():
		normalized = _normalize_exact_dictionary(raw, _LOCATION_FULL_KEYS)
		used_full_shape = not normalized.is_empty()
	if normalized.is_empty() \
		or typeof(normalized.get("container", null)) != TYPE_INT \
		or int(normalized["container"]) <= 0:
		return {}
	if used_full_shape and (
		typeof(normalized.get("x", null)) != TYPE_INT
		or typeof(normalized.get("y", null)) != TYPE_INT
		or typeof(normalized.get("rotated", null)) != TYPE_BOOL
		or (typeof(normalized.get("slot_identifier", null)) != TYPE_STRING
			and typeof(normalized.get("slot_identifier", null)) != TYPE_STRING_NAME)
		or typeof(normalized.get("ordinal", null)) != TYPE_INT
	):
		return {}
	match kind:
		"spatial":
			if typeof(normalized.get("x", null)) != TYPE_INT \
				or typeof(normalized.get("y", null)) != TYPE_INT \
				or typeof(normalized.get("rotated", null)) != TYPE_BOOL \
				or int(normalized["x"]) < 0 or int(normalized["x"]) > MAX_SEQUENCE \
				or int(normalized["y"]) < 0 or int(normalized["y"]) > MAX_SEQUENCE:
				return {}
			return {
				"kind": "spatial",
				"container": int(normalized["container"]),
				"x": int(normalized["x"]),
				"y": int(normalized["y"]),
				"rotated": bool(normalized["rotated"]),
			}
		"slot":
			var slot_value: Variant = normalized.get("slot_identifier", null)
			if typeof(slot_value) != TYPE_STRING and typeof(slot_value) != TYPE_STRING_NAME:
				return {}
			var slot_identifier := String(slot_value)
			if not ZIdentityRules.is_valid_part(slot_identifier):
				return {}
			return {
				"kind": "slot",
				"container": int(normalized["container"]),
				"slot_identifier": slot_identifier,
			}
		"list":
			if typeof(normalized.get("ordinal", null)) != TYPE_INT \
				or int(normalized["ordinal"]) < 0 \
				or int(normalized["ordinal"]) > MAX_SEQUENCE:
				return {}
			return {
				"kind": "list",
				"container": int(normalized["container"]),
				"ordinal": int(normalized["ordinal"]),
			}
	return {}


func _intent_fingerprint(intent: ZRaidIntent) -> String:
	return ZCanonicalValue.sha256(intent.canonical_record())


func _replay_or_conflict(request_key: String, fingerprint: String) -> Dictionary:
	var entry := _request_ledger[request_key] as Dictionary
	if String(entry.get("fingerprint", "")) != fingerprint:
		return _result(false, false, &"request_id_conflict", request_key)
	var replay := (entry.get("result", {}) as Dictionary).duplicate(true)
	replay["replayed"] = true
	last_error = StringName(replay.get("reason", &""))
	return replay


func _complete_rejection(
	request_key: String,
	fingerprint: String,
	reason: StringName,
	inventory_command_id: int = 0,
	operation: StringName = INTENT_KIND_TRANSFER
) -> Dictionary:
	var result := _result(
		false, false, reason, request_key, inventory_command_id,
		0, -1, -1, -1, -1, -1, {}, operation)
	_store_result(request_key, fingerprint, result)
	return result


func _complete_native_result(
	request_key: String,
	fingerprint: String,
	native_result: Dictionary,
	accepted: bool,
	reason: StringName,
	inventory_command_id: int,
	source_inventory_id: int,
	destination_inventory_id: int
) -> Dictionary:
	var status: Dictionary = {}
	if native_result.get("status", null) is Dictionary:
		status = (native_result.get("status", {}) as Dictionary).duplicate(true)
	var revisions: Array = []
	if native_result.get("revisions", null) is Array:
		revisions = native_result.get("revisions", []) as Array
	var source_predecessor_revision := -1
	var source_revision := -1
	var destination_predecessor_revision := -1
	var destination_revision := -1
	for revision_value in revisions:
		if not revision_value is Dictionary:
			continue
		var revision := revision_value as Dictionary
		var inventory_id := int(revision.get("inventory", 0))
		if inventory_id == source_inventory_id:
			source_predecessor_revision = int(revision.get("predecessor", -1))
			source_revision = int(revision.get("successor", -1))
		elif inventory_id == destination_inventory_id:
			destination_predecessor_revision = int(revision.get("predecessor", -1))
			destination_revision = int(revision.get("successor", -1))
	var exposed_status := status
	if not accepted and reason != &"native_transfer_rejected":
		# Internal adapter failures must not expose a native OK/replay marker as
		# though it were a coherent rejected command status.
		exposed_status = {}
	var result := _result(
		accepted, false, reason, request_key, inventory_command_id,
		int(native_result.get("command_id", 0)),
		int(status.get("code", -1)),
		source_predecessor_revision, source_revision,
		destination_predecessor_revision, destination_revision, exposed_status,
		INTENT_KIND_TRANSFER)
	result["revisions"] = revisions.duplicate(true)
	if native_result.get("events", null) is Array:
		result["events"] = (native_result.get("events", []) as Array).duplicate(true)
	result["new_item_id"] = int(native_result.get("new_item_id", 0))
	result["transferred_quantity"] = int(native_result.get("transferred_quantity", 0))
	result["remaining_quantity"] = int(native_result.get("remaining_quantity", 0))
	_store_result(request_key, fingerprint, result)
	return result


func _invoke_routed_native(
	operation: StringName,
	payload: Dictionary,
	native_actor_id: int,
	inventory_command_id: int
) -> Dictionary:
	match operation:
		INTENT_KIND_LOOT:
			return _authority.loot_item(
				int(payload["source_inventory_id"]),
				int(payload["destination_inventory_id"]),
				int(payload["item_id"]),
				(payload["destination_location"] as Dictionary).duplicate(true),
				native_actor_id,
				inventory_command_id
			)
		INTENT_KIND_MOVE:
			return _authority.move_item(
				int(payload["inventory_id"]),
				int(payload["item_id"]),
				(payload["destination_location"] as Dictionary).duplicate(true),
				native_actor_id,
				inventory_command_id
			)
		INTENT_KIND_ROTATE:
			return _authority.rotate_item(
				int(payload["inventory_id"]),
				int(payload["item_id"]),
				bool(payload["rotated"]),
				native_actor_id,
				inventory_command_id
			)
		INTENT_KIND_SPLIT:
			return _authority.split_stack(
				int(payload["inventory_id"]),
				int(payload["item_id"]),
				int(payload["quantity"]),
				(payload["destination_location"] as Dictionary).duplicate(true),
				native_actor_id,
				inventory_command_id
			)
		INTENT_KIND_MERGE:
			return _authority.merge_stacks(
				int(payload["inventory_id"]),
				int(payload["source_item_id"]),
				int(payload["destination_item_id"]),
				native_actor_id,
				inventory_command_id
			)
		INTENT_KIND_QUICK_TRANSFER:
			return _authority.quick_transfer_item(
				int(payload["source_inventory_id"]),
				int(payload["destination_inventory_id"]),
				int(payload["item_id"]),
				false,
				native_actor_id,
				inventory_command_id
			)
	return {}


func _finish_routed_native_result(
	request_key: String,
	fingerprint: String,
	operation: StringName,
	payload: Dictionary,
	shape: Dictionary,
	native_result: Dictionary,
	inventory_command_id: int
) -> Dictionary:
	var accepted := false
	var reason: StringName = &""
	if not _native_result_shape_valid(native_result):
		reason = &"native_result_invalid"
	elif int(native_result.get("command_id", 0)) != inventory_command_id:
		reason = &"native_command_id_mismatch"
	elif bool(native_result.get("queued", false)):
		reason = &"native_transfer_deferred"
	elif bool(native_result.get("replayed", false)):
		reason = &"native_command_replay_unexpected"
	elif not bool(native_result.get("accepted", false)):
		reason = &"native_command_rejected"
	else:
		var expected_revisions := _expected_revisions(operation, payload, shape)
		if not _accepted_revision_map_matches(native_result, expected_revisions):
			reason = &"native_revision_mismatch"
		elif not _operation_outcome_valid(operation, native_result):
			reason = &"native_result_invalid"
		else:
			accepted = true

	var status: Dictionary = {}
	if native_result.get("status", null) is Dictionary:
		status = (native_result.get("status", {}) as Dictionary).duplicate(true)
	var exposed_status := status
	if not accepted and reason != &"native_command_rejected":
		exposed_status = {}
	var revisions: Array = []
	if native_result.get("revisions", null) is Array:
		revisions = (native_result.get("revisions", []) as Array).duplicate(true)
	var source_inventory_id := int(shape["source_inventory_id"])
	var destination_inventory_id := int(shape["destination_inventory_id"])
	var source_pair := _revision_pair_for(revisions, source_inventory_id)
	var destination_pair := source_pair if source_inventory_id == destination_inventory_id \
		else _revision_pair_for(revisions, destination_inventory_id)
	var result := _result(
		accepted,
		false,
		reason,
		request_key,
		inventory_command_id,
		int(native_result.get("command_id", 0)),
		int(status.get("code", -1)),
		int(source_pair.get("predecessor", -1)),
		int(source_pair.get("successor", -1)),
		int(destination_pair.get("predecessor", -1)),
		int(destination_pair.get("successor", -1)),
		exposed_status,
		operation
	)
	result["revisions"] = revisions
	if native_result.get("events", null) is Array:
		result["events"] = (native_result.get("events", []) as Array).duplicate(true)
	result["new_item_id"] = int(native_result.get("new_item_id", 0))
	result["transferred_quantity"] = int(native_result.get("transferred_quantity", 0))
	result["remaining_quantity"] = int(native_result.get("remaining_quantity", 0))
	result["primary_item_id"] = int(shape["primary_item_id"])
	result["secondary_item_id"] = int(shape.get("secondary_item_id", 0))
	_store_result(request_key, fingerprint, result)
	return result


func _accepted_revision_map_matches(
	native_result: Dictionary,
	expected_revisions: Dictionary
) -> bool:
	var revisions := native_result.get("revisions", []) as Array
	if revisions.size() != expected_revisions.size():
		return false
	var seen: Dictionary = {}
	for revision_value in revisions:
		if not revision_value is Dictionary:
			return false
		var revision := revision_value as Dictionary
		if typeof(revision.get("inventory", null)) != TYPE_INT \
			or typeof(revision.get("predecessor", null)) != TYPE_INT \
			or typeof(revision.get("successor", null)) != TYPE_INT:
			return false
		var inventory_id := int(revision["inventory"])
		if not expected_revisions.has(inventory_id) or seen.has(inventory_id):
			return false
		var expected := int(expected_revisions[inventory_id])
		if int(revision["predecessor"]) != expected \
			or int(revision["successor"]) != expected + 1:
			return false
		seen[inventory_id] = true
	for inventory_id_value in expected_revisions:
		var inventory_id := int(inventory_id_value)
		if not seen.has(inventory_id) \
			or _authority.inventory_revision(inventory_id) \
			!= int(expected_revisions[inventory_id_value]) + 1:
			return false
	return true


func _operation_outcome_valid(operation: StringName, native_result: Dictionary) -> bool:
	match operation:
		INTENT_KIND_SPLIT:
			return typeof(native_result.get("new_item_id", null)) == TYPE_INT \
				and int(native_result["new_item_id"]) > 0
		INTENT_KIND_LOOT, INTENT_KIND_QUICK_TRANSFER:
			return typeof(native_result.get("transferred_quantity", null)) == TYPE_INT \
				and typeof(native_result.get("remaining_quantity", null)) == TYPE_INT \
				and int(native_result["transferred_quantity"]) > 0 \
				and int(native_result["remaining_quantity"]) == 0
		INTENT_KIND_MOVE, INTENT_KIND_ROTATE, INTENT_KIND_MERGE:
			return true
	return false


func _revision_pair_for(revisions: Array, inventory_id: int) -> Dictionary:
	for revision_value in revisions:
		if not revision_value is Dictionary:
			continue
		var revision := revision_value as Dictionary
		if int(revision.get("inventory", 0)) == inventory_id:
			return {
				"predecessor": int(revision.get("predecessor", -1)),
				"successor": int(revision.get("successor", -1)),
			}
	return {"predecessor": -1, "successor": -1}


func _store_result(request_key: String, fingerprint: String, result: Dictionary) -> void:
	_request_ledger[request_key] = {
		"fingerprint": fingerprint,
		"result": result.duplicate(true),
	}


func _world_policy_rejection(
	source_inventory_id: int,
	destination_inventory_id: int,
	item_id: int,
	world_inventory_id: int = 0
) -> StringName:
	var target_inventory_id := source_inventory_id \
		if world_inventory_id <= 0 else world_inventory_id
	if not _world_policy_port.is_world_inventory(
		_admission.actor_id, target_inventory_id, _admission.generation
	):
		return &"world_target_invalid"
	var distance_raw := _world_policy_port.authoritative_distance_raw(
		_admission.actor_id, target_inventory_id, _admission.generation)
	if distance_raw < 0:
		return &"distance_unavailable"
	if distance_raw > _max_transfer_distance_raw:
		return &"out_of_range"
	if not _world_policy_port.is_currently_visible(
		_admission.actor_id, target_inventory_id, _admission.generation
	):
		return &"not_visible"
	if _world_policy_port.access_state(
		_admission.actor_id, target_inventory_id, _admission.generation
	) != ZInventoryWorldPolicyPort.ACCESS_OPEN:
		return &"access_closed"
	if not _world_policy_port.allows_transfer(
		_admission.actor_id,
		source_inventory_id,
		destination_inventory_id,
		item_id,
		_admission.generation
	):
		return &"world_policy_denied"
	return &""


func _resolve_native_actor_id() -> int:
	return _identity_port.native_actor_id(
		_admission.session_id,
		_admission.actor_id,
		_admission.authority_epoch,
		_admission.generation
	)


func _actor_owns_destination(destination_inventory_id: int) -> bool:
	return _actor_owns_inventory(destination_inventory_id)


func _actor_owns_inventory(inventory_id: int) -> bool:
	return _identity_port.actor_owns_inventory(
		_admission.session_id,
		_admission.actor_id,
		inventory_id,
		_admission.authority_epoch,
		_admission.generation
	)


func _inventory_contains_item(inventory_id: int, item_id: int) -> bool:
	var snapshot := _authority.snapshot(inventory_id)
	if snapshot == null:
		return false
	for item_value in snapshot.get_items():
		var item := item_value as Dictionary
		if int(item.get("id", 0)) == item_id:
			return true
	return false


func _native_result_shape_valid(native_result: Dictionary) -> bool:
	if not (
		typeof(native_result.get("accepted", null)) == TYPE_BOOL
		and typeof(native_result.get("replayed", null)) == TYPE_BOOL
		and typeof(native_result.get("queued", null)) == TYPE_BOOL
		and typeof(native_result.get("command_id", null)) == TYPE_INT
		and native_result.get("status", null) is Dictionary
		and native_result.get("revisions", null) is Array
		and native_result.get("events", null) is Array
		and typeof(native_result.get("new_item_id", null)) == TYPE_INT
		and typeof(native_result.get("transferred_quantity", null)) == TYPE_INT
		and typeof(native_result.get("remaining_quantity", null)) == TYPE_INT
	):
		return false
	var status := native_result.get("status", {}) as Dictionary
	return (
		typeof(status.get("code", null)) == TYPE_INT
		and typeof(status.get("diagnostic", null)) == TYPE_INT
		and typeof(status.get("detail", null)) == TYPE_INT
		and typeof(status.get("ok", null)) == TYPE_BOOL
		and bool(status.get("ok", false)) == (
			bool(native_result.get("accepted", false))
			or bool(native_result.get("queued", false))
		)
	)


func _accepted_revisions_match(
	native_result: Dictionary,
	source_inventory_id: int,
	destination_inventory_id: int,
	expected_source_revision: int,
	expected_destination_revision: int
) -> bool:
	var expected_revisions: Dictionary = {}
	expected_revisions[source_inventory_id] = expected_source_revision
	expected_revisions[destination_inventory_id] = expected_destination_revision
	return _accepted_revision_map_matches(native_result, expected_revisions)


func _admissions_match(left: ZSessionAdmission, right: ZSessionAdmission) -> bool:
	return (
		left != null
		and right != null
		and left.is_usable()
		and right.is_usable()
		and left.session_id.is_equal(right.session_id)
		and left.actor_id.is_equal(right.actor_id)
		and left.raid_id.is_equal(right.raid_id)
		and left.authority_epoch == right.authority_epoch
		and left.generation == right.generation
	)


func _valid_request_id(value: ZRequestId) -> bool:
	return value != null and ZRequestId.parse(value.canonical_key()) != null


func _valid_session_id(value: ZSessionId) -> bool:
	return value != null and ZSessionId.parse(value.canonical_key()) != null


func _valid_actor_id(value: ZEntityId) -> bool:
	return value != null and ZEntityId.parse(value.canonical_key()) != null


func _result(
	accepted: bool,
	replayed: bool,
	reason: StringName,
	request_id: String = "",
	inventory_command_id: int = 0,
	native_command_id: int = 0,
	native_status_code: int = -1,
	source_predecessor_revision: int = -1,
	source_revision: int = -1,
	destination_predecessor_revision: int = -1,
	destination_revision: int = -1,
	status: Dictionary = {},
	operation: StringName = &""
) -> Dictionary:
	last_error = reason
	var stable_status := status.duplicate(true)
	if stable_status.is_empty():
		stable_status = {
			"code": InventoryCatalog.STATUS_OK if accepted else InventoryCatalog.STATUS_COMMAND_REJECTED,
			"diagnostic": 0,
			"detail": 0,
			"ok": accepted,
		}
	return {
		"accepted": accepted,
		"replayed": replayed,
		"queued": false,
		"reason": reason,
		"operation": operation,
		"request_id": request_id,
		"inventory_command_id": inventory_command_id,
		"command_id": inventory_command_id,
		"native_command_id": native_command_id,
		"native_status_code": native_status_code,
		"status": stable_status,
		"source_predecessor_revision": source_predecessor_revision,
		"source_revision": source_revision,
		"destination_predecessor_revision": destination_predecessor_revision,
		"destination_revision": destination_revision,
		"revisions": [],
		"events": [],
		"new_item_id": 0,
		"transferred_quantity": 0,
		"remaining_quantity": 0,
	}


func _reject_configuration(reason: StringName) -> bool:
	last_error = reason
	return false
