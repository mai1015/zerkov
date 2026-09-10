class_name InventoryIntentAdapter
extends RefCounted
## Bounded game-owned authorization seam for raid world-loot transfers.
##
## The adapter snapshots an admitted ZRaidIntent, resolves its actor through a
## trusted port, validates current world facts, and performs one complete-only
## InventoryAuthority.quick_transfer_item() call. It owns no canonical state.

const INTENT_KIND_TRANSFER: StringName = &"inventory_transfer"
# Deliberately narrow first allowlist: same-inventory move/rotate/split/merge
# and placement-specific loot remain separate authority work before UI binding.
const SUPPORTED_INTENT_KINDS: Array[StringName] = [INTENT_KIND_TRANSFER]
const DEFAULT_PHASE_HANDLER_ID: StringName = &"inventory_intent_adapter"
const MAX_TRACKED_REQUESTS: int = 1024
const MAX_SEQUENCE: int = 2_147_483_647

const _PAYLOAD_KEYS: PackedStringArray = [
	"inventory_command_id",
	"source_inventory_id",
	"destination_inventory_id",
	"item_id",
	"expected_source_revision",
	"expected_destination_revision",
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
var _native_call_active: bool = false
var _raid_authority_instance_id: int = 0


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
	return true


## Registers only the explicit allowlist in the canonical interaction phase.
func register_with_raid_authority(
	raid_authority: RaidAuthority,
	handler_id: StringName = DEFAULT_PHASE_HANDLER_ID
) -> bool:
	last_error = &""
	if not _configured:
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
	for intent in intents:
		if intent == null or not SUPPORTED_INTENT_KINDS.has(intent.kind):
			continue
		if intent.target_tick != tick:
			last_error = &"handler_tick_invalid"
			return false
		var result := submit_intent(intent)
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
	if intent.kind != INTENT_KIND_TRANSFER:
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
	if _request_ledger.size() >= MAX_TRACKED_REQUESTS:
		return _result(false, false, &"request_history_full", request_key)

	var payload := _normalize_payload(intent_copy.payload)
	if payload.is_empty():
		return _complete_rejection(request_key, fingerprint, last_error)
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
				inventory_command_id
			)
	if not _owner_is_current():
		return _complete_rejection(
			request_key, fingerprint, &"stale_generation", inventory_command_id)
	if _native_call_active:
		return _result(
			false, false, &"reentrant_submission", request_key, inventory_command_id)
	_command_bindings[inventory_command_id] = {
		"request_id": request_key,
		"fingerprint": fingerprint,
	}

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


func _owner_is_current() -> bool:
	return (
		_owner != null
		and is_instance_valid(_owner)
		and _owner.is_current_generation(_owner_generation)
		and _authority != null
		and is_instance_valid(_authority)
		and _owner.raid_authority() == _authority
	)


func _normalize_payload(payload: Dictionary) -> Dictionary:
	last_error = &"payload_schema_invalid"
	if payload.size() != _PAYLOAD_KEYS.size():
		return {}
	var normalized: Dictionary = {}
	for key_value in payload:
		if typeof(key_value) != TYPE_STRING and typeof(key_value) != TYPE_STRING_NAME:
			return {}
		var key := String(key_value)
		if not _PAYLOAD_KEYS.has(key) or normalized.has(key):
			return {}
		normalized[key] = payload[key_value]
	for key in _PAYLOAD_KEYS:
		if not normalized.has(key) or typeof(normalized[key]) != TYPE_INT:
			return {}
	if int(normalized["inventory_command_id"]) <= 0 \
		or int(normalized["source_inventory_id"]) <= 0 \
		or int(normalized["destination_inventory_id"]) <= 0 \
		or int(normalized["item_id"]) <= 0:
		return {}
	if int(normalized["source_inventory_id"]) == int(normalized["destination_inventory_id"]):
		return {}
	if int(normalized["expected_source_revision"]) < 0 \
		or int(normalized["expected_destination_revision"]) < 0:
		return {}
	last_error = &""
	return normalized


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
	inventory_command_id: int = 0
) -> Dictionary:
	var result := _result(
		false, false, reason, request_key, inventory_command_id)
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
		destination_predecessor_revision, destination_revision, exposed_status)
	_store_result(request_key, fingerprint, result)
	return result


func _store_result(request_key: String, fingerprint: String, result: Dictionary) -> void:
	_request_ledger[request_key] = {
		"fingerprint": fingerprint,
		"result": result.duplicate(true),
	}


func _world_policy_rejection(
	source_inventory_id: int,
	destination_inventory_id: int,
	item_id: int
) -> StringName:
	if not _world_policy_port.is_world_inventory(
		_admission.actor_id, source_inventory_id, _admission.generation
	):
		return &"world_target_invalid"
	var distance_raw := _world_policy_port.authoritative_distance_raw(
		_admission.actor_id, source_inventory_id, _admission.generation)
	if distance_raw < 0:
		return &"distance_unavailable"
	if distance_raw > _max_transfer_distance_raw:
		return &"out_of_range"
	if not _world_policy_port.is_currently_visible(
		_admission.actor_id, source_inventory_id, _admission.generation
	):
		return &"not_visible"
	if _world_policy_port.access_state(
		_admission.actor_id, source_inventory_id, _admission.generation
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
	return _identity_port.actor_owns_inventory(
		_admission.session_id,
		_admission.actor_id,
		destination_inventory_id,
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
	var source_seen := false
	var destination_seen := false
	for revision_value in (native_result.get("revisions", []) as Array):
		if not revision_value is Dictionary:
			return false
		var revision := revision_value as Dictionary
		var inventory_id := int(revision.get("inventory", 0))
		var predecessor := int(revision.get("predecessor", -1))
		var successor := int(revision.get("successor", -1))
		if inventory_id == source_inventory_id:
			source_seen = predecessor == expected_source_revision \
				and successor == expected_source_revision + 1
		elif inventory_id == destination_inventory_id:
			destination_seen = predecessor == expected_destination_revision \
				and successor == expected_destination_revision + 1
	return (
		source_seen
		and destination_seen
		and _authority.inventory_revision(source_inventory_id) == expected_source_revision + 1
		and _authority.inventory_revision(destination_inventory_id) == expected_destination_revision + 1
	)


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
	status: Dictionary = {}
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
	}


func _reject_configuration(reason: StringName) -> bool:
	last_error = reason
	return false
