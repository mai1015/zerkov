class_name InventoryPersistenceBoundary
extends RefCounted
## Game-owned validation boundary for opaque Inventory System persistence bytes.
##
## Persistence bytes and their surrounding metadata are storage input, never
## authority.  Every candidate is decoded on a disposable InventoryAuthority
## with the exact live sealed catalog before an explicit same-id replacement is
## allowed.  The caller must also present the current owner generation and the
## exact live canonical SHA-256 captured for its compare-and-swap operation.

signal binding_invalidated(reason: StringName)

const SCOPE_PROFILE: StringName = &"profile"
const SCOPE_RAID: StringName = &"raid"
const ENVELOPE_SCHEMA: String = "zerkov.inventory.persistence-envelope.v1"
const MAX_PERSISTENCE_RECORD_BYTES: int = 1_052_672

const _ENVELOPE_KEYS: PackedStringArray = [
	"schema",
	"scope",
	"inventory_id",
	"profile_identifier",
	"revision",
	"manifest_fingerprint",
	"manifest_algorithm",
	"canonical_hash",
	"canonical_sha256",
	"record_sha256",
	"source_owner_generation",
	"record_bytes",
	"envelope_sha256",
]

var last_error: StringName = &""

var _bound: bool = false
var _invalidated: bool = false
var _owner: RaidInventoryOwner
var _owner_instance_id: int = 0
var _owner_generation: int = 0
var _catalog: InventoryCatalog
var _catalog_instance_id: int = 0
var _manifest_fingerprint: int = 0
var _manifest_algorithm: String = ""
var _profile_authority: InventoryAuthority
var _profile_authority_id: int = 0
var _raid_authority: InventoryAuthority
var _raid_authority_id: int = 0
var _authority_connections: Array[Dictionary] = []
var _owner_tree_exiting_callback: Callable
var _operation_active: bool = false
var _replacement_scope: StringName = &""
var _replacement_inventory_id: int = 0
var _replacement_signal_observed: bool = false


func bind_owner(owner: RaidInventoryOwner, expected_owner_generation: int) -> bool:
	last_error = &""
	if _bound or _invalidated:
		return _reject_bool(&"persistence_boundary_already_used")
	if owner == null or not is_instance_valid(owner) \
			or expected_owner_generation <= 0 \
			or not owner.is_current_generation(expected_owner_generation):
		return _reject_bool(&"inventory_owner_invalid")
	var catalog := owner.catalog()
	var profile_authority := owner.profile_authority()
	var raid_authority := owner.raid_authority()
	if catalog == null or not catalog.is_sealed() \
			or catalog.manifest_fingerprint() == 0 \
			or catalog.manifest_algorithm().is_empty():
		return _reject_bool(&"inventory_catalog_invalid")
	if profile_authority == null or not is_instance_valid(profile_authority) \
			or raid_authority == null or not is_instance_valid(raid_authority):
		return _reject_bool(&"inventory_authority_invalid")
	if not profile_authority.has_inventory(owner.profile_inventory_id) \
			or not raid_authority.has_inventory(owner.raid_player_inventory_id) \
			or not raid_authority.has_inventory(owner.world_crate_inventory_id) \
			or not raid_authority.has_inventory(owner.corpse_inventory_id):
		return _reject_bool(&"inventory_set_incomplete")

	_owner = owner
	_owner_instance_id = owner.get_instance_id()
	_owner_generation = expected_owner_generation
	_catalog = catalog
	_catalog_instance_id = catalog.get_instance_id()
	_manifest_fingerprint = catalog.manifest_fingerprint()
	_manifest_algorithm = catalog.manifest_algorithm()
	_profile_authority = profile_authority
	_profile_authority_id = profile_authority.get_instance_id()
	_raid_authority = raid_authority
	_raid_authority_id = raid_authority.get_instance_id()
	_bound = true
	_connect_lifecycle_signals()
	return true


func is_bound() -> bool:
	return _bound and not _invalidated and _binding_is_current()


func owner_generation() -> int:
	return _owner_generation


## Creates an immutable-by-convention envelope around the add-on's opaque
## record. The outer digest detects accidental metadata corruption; native
## validation remains the authority for the record itself.
func capture_record(
	scope: StringName,
	inventory_id: int,
	expected_owner_generation: int
) -> Dictionary:
	last_error = &""
	if not _begin_operation(expected_owner_generation):
		return _failure(last_error)
	var target := _resolve_live_target(scope, inventory_id)
	if target.is_empty():
		_end_operation()
		return _failure(&"inventory_target_invalid")
	var authority := target["authority"] as InventoryAuthority
	var snapshot := authority.snapshot(inventory_id)
	if not _snapshot_matches_live_target(snapshot, target):
		_end_operation()
		return _failure(&"live_snapshot_invalid")
	var record_bytes := authority.make_persistence_record(inventory_id)
	if record_bytes.is_empty() or record_bytes.size() > MAX_PERSISTENCE_RECORD_BYTES:
		_end_operation()
		return _failure(&"persistence_record_invalid")
	var canonical_bytes := snapshot.canonical_bytes()
	var canonical_sha256 := _sha256_bytes(canonical_bytes)
	var record_sha256 := _sha256_bytes(record_bytes)
	if canonical_sha256.is_empty() or record_sha256.is_empty():
		_end_operation()
		return _failure(&"persistence_digest_failed")
	var envelope := {
		"schema": ENVELOPE_SCHEMA,
		"scope": String(scope),
		"inventory_id": inventory_id,
		"profile_identifier": snapshot.get_profile_identifier(),
		"revision": snapshot.get_revision(),
		"manifest_fingerprint": str(snapshot.get_manifest_fingerprint()),
		"manifest_algorithm": snapshot.get_manifest_algorithm(),
		"canonical_hash": str(snapshot.hash()),
		"canonical_sha256": canonical_sha256,
		"record_sha256": record_sha256,
		"source_owner_generation": _owner_generation,
		"record_bytes": record_bytes,
	}
	envelope["envelope_sha256"] = _envelope_digest(envelope)
	if String(envelope["envelope_sha256"]).is_empty():
		_end_operation()
		return _failure(&"persistence_envelope_digest_failed")
	_end_operation()
	envelope.make_read_only()
	return envelope


## Decodes opaque bytes only on a disposable authority. No live authority state
## or presentation generation changes on this path.
func preflight_bytes(
	record_bytes: PackedByteArray,
	scope: StringName,
	inventory_id: int,
	expected_owner_generation: int
) -> Dictionary:
	last_error = &""
	if not _begin_operation(expected_owner_generation):
		return _failure(last_error)
	var outcome := _preflight_bytes_once(record_bytes, scope, inventory_id)
	_end_operation()
	last_error = StringName(outcome.get("reason", &""))
	return outcome


## Explicit same-id replacement. The target generation and pre-operation live
## digest are out-of-band authority inputs and are never read from persistence.
func replace_live(
	envelope: Dictionary,
	expected_owner_generation: int,
	expected_live_sha256: String
) -> Dictionary:
	last_error = &""
	if not _begin_operation(expected_owner_generation):
		return _failure(last_error)
	if not _is_sha256(expected_live_sha256):
		_end_operation()
		return _failure(&"expected_live_digest_invalid")
	var normalized := _normalize_envelope(envelope)
	if normalized.is_empty():
		_end_operation()
		return _failure(last_error)
	var scope := StringName(normalized["scope"])
	var inventory_id := int(normalized["inventory_id"])
	var target := _resolve_live_target(scope, inventory_id)
	if target.is_empty():
		_end_operation()
		return _failure(&"inventory_target_invalid")
	var live_authority := target["authority"] as InventoryAuthority
	var before_snapshot := live_authority.snapshot(inventory_id)
	if not _snapshot_matches_live_target(before_snapshot, target):
		_end_operation()
		return _failure(&"live_snapshot_invalid")
	var before_bytes := before_snapshot.canonical_bytes()
	var before_sha256 := _sha256_bytes(before_bytes)
	if before_sha256 != expected_live_sha256:
		_end_operation()
		return _failure(&"stale_live_digest", {}, inventory_id, before_sha256)

	var record_bytes := normalized["record_bytes"] as PackedByteArray
	var preflight := _preflight_bytes_once(record_bytes, scope, inventory_id)
	if not bool(preflight.get("ok", false)):
		_end_operation()
		last_error = StringName(preflight.get("reason", &"persistence_preflight_failed"))
		return preflight
	if not _envelope_matches_preflight(normalized, preflight):
		_end_operation()
		return _failure(last_error, {}, inventory_id, before_sha256)
	if (preflight["canonical_bytes"] as PackedByteArray) == before_bytes:
		_end_operation()
		return _success(
			inventory_id, true, false, before_sha256,
			String(preflight["canonical_sha256"]),
			int(preflight["canonical_hash"]), {})
	# Recheck after disposable decoding: no stale caller can win a synchronous
	# callback boundary by changing the owner or target in between validations.
	if not _binding_matches_generation(expected_owner_generation):
		_end_operation()
		return _failure(&"stale_owner_generation", {}, inventory_id, before_sha256)
	var rechecked_snapshot := live_authority.snapshot(inventory_id)
	if not _snapshot_matches_live_target(rechecked_snapshot, target) \
			or _sha256_bytes(rechecked_snapshot.canonical_bytes()) != before_sha256:
		_end_operation()
		return _failure(&"live_state_changed_during_preflight", {}, inventory_id)

	_replacement_scope = scope
	_replacement_inventory_id = inventory_id
	_replacement_signal_observed = false
	var native_result: Dictionary = live_authority.apply_persistence_record(record_bytes, true)
	var observed_generation_signal := _replacement_signal_observed
	_replacement_scope = &""
	_replacement_inventory_id = 0
	_replacement_signal_observed = false
	if not bool(native_result.get("ok", false)):
		_end_operation()
		return _failure(
			&"native_persistence_rejected",
			native_result.get("status", {}) as Dictionary,
			inventory_id,
			before_sha256)
	if not observed_generation_signal \
			or not _binding_matches_generation(expected_owner_generation) \
			or not is_instance_valid(live_authority):
		_end_operation()
		_invalidate_binding(&"replacement_lifecycle_verification_failed")
		return _failure(
			&"replacement_lifecycle_verification_failed",
			native_result.get("status", {}) as Dictionary,
			inventory_id,
			before_sha256)
	var restored_snapshot := live_authority.snapshot(inventory_id)
	var expected_bytes := preflight["canonical_bytes"] as PackedByteArray
	var restored_bytes := restored_snapshot.canonical_bytes() \
		if restored_snapshot != null else PackedByteArray()
	var restored_sha256 := _sha256_bytes(restored_bytes)
	var exact := _snapshot_matches_preflight(restored_snapshot, preflight) \
		and restored_bytes == expected_bytes \
		and restored_sha256 == String(preflight["canonical_sha256"])
	_end_operation()
	if not exact:
		# The native apply already committed. Fail closed and retire this boundary
		# so no caller can mistake a verification failure for a reusable binding.
		_invalidate_binding(&"restored_state_verification_failed")
		return _failure(
			&"restored_state_verification_failed",
			native_result.get("status", {}) as Dictionary,
			inventory_id,
			before_sha256,
			restored_sha256)
	var result := _success(
		inventory_id, false, true, before_sha256, restored_sha256,
		restored_snapshot.hash(), native_result.get("status", {}) as Dictionary)
	_invalidate_binding(&"persistence_replacement_committed")
	return result


func release_binding(reason: StringName = &"persistence_boundary_released") -> bool:
	last_error = &""
	if not _bound or _invalidated:
		return _reject_bool(&"persistence_boundary_not_bound")
	if _operation_active:
		return _reject_bool(&"persistence_operation_active")
	_invalidate_binding(reason if not reason.is_empty() \
		else &"persistence_boundary_released")
	return true


func _preflight_bytes_once(
	record_bytes: PackedByteArray,
	scope: StringName,
	inventory_id: int
) -> Dictionary:
	if record_bytes.is_empty() or record_bytes.size() > MAX_PERSISTENCE_RECORD_BYTES:
		return _failure(&"persistence_record_size_invalid", {}, inventory_id)
	var target := _resolve_live_target(scope, inventory_id)
	if target.is_empty():
		return _failure(&"inventory_target_invalid", {}, inventory_id)
	var authority := InventoryAuthority.new()
	authority.set_role(InventoryAuthority.ROLE_OFFLINE_AUTHORITY)
	authority.set_catalog(_catalog)
	var native_result: Dictionary = authority.apply_persistence_record(record_bytes)
	if not bool(native_result.get("ok", false)):
		var rejected := _failure(
			&"persistence_record_rejected",
			native_result.get("status", {}) as Dictionary,
			inventory_id)
		authority.free()
		return rejected
	if int(native_result.get("inventory_id", 0)) != inventory_id:
		authority.free()
		return _failure(
			&"persistence_inventory_id_mismatch",
			native_result.get("status", {}) as Dictionary,
			inventory_id)
	var snapshot := authority.snapshot(inventory_id)
	if not _snapshot_matches_live_target(snapshot, target):
		authority.free()
		return _failure(
			&"persistence_identity_mismatch",
			native_result.get("status", {}) as Dictionary,
			inventory_id)
	var remade_record := authority.make_persistence_record(inventory_id)
	var canonical_bytes := snapshot.canonical_bytes()
	var canonical_sha256 := _sha256_bytes(canonical_bytes)
	var exact_record_round_trip := remade_record == record_bytes
	var result := {
		"ok": exact_record_round_trip and not canonical_sha256.is_empty(),
		"accepted": exact_record_round_trip and not canonical_sha256.is_empty(),
		"duplicate": false,
		"replaced": false,
		"reason": &"" if exact_record_round_trip and not canonical_sha256.is_empty() \
			else &"persistence_round_trip_mismatch",
		"native_status": (native_result.get("status", {}) as Dictionary).duplicate(true),
		"inventory_id": inventory_id,
		"profile_identifier": snapshot.get_profile_identifier(),
		"revision": snapshot.get_revision(),
		"manifest_fingerprint": snapshot.get_manifest_fingerprint(),
		"manifest_algorithm": snapshot.get_manifest_algorithm(),
		"canonical_hash": snapshot.hash(),
		"canonical_sha256": canonical_sha256,
		"record_sha256": _sha256_bytes(record_bytes),
		"canonical_bytes": canonical_bytes,
		"record_bytes": remade_record,
	}
	authority.free()
	return result


func _normalize_envelope(envelope: Dictionary) -> Dictionary:
	last_error = &"persistence_envelope_invalid"
	if envelope.size() != _ENVELOPE_KEYS.size():
		return {}
	for key in _ENVELOPE_KEYS:
		if not envelope.has(key):
			return {}
	if typeof(envelope["schema"]) != TYPE_STRING \
			or String(envelope["schema"]) != ENVELOPE_SCHEMA:
		last_error = &"persistence_envelope_schema_mismatch"
		return {}
	if (typeof(envelope["scope"]) != TYPE_STRING \
			and typeof(envelope["scope"]) != TYPE_STRING_NAME) \
			or not [SCOPE_PROFILE, SCOPE_RAID].has(StringName(envelope["scope"])):
		return {}
	if typeof(envelope["inventory_id"]) != TYPE_INT \
			or int(envelope["inventory_id"]) <= 0 \
			or typeof(envelope["revision"]) != TYPE_INT \
			or int(envelope["revision"]) < 0 \
			or typeof(envelope["source_owner_generation"]) != TYPE_INT \
			or int(envelope["source_owner_generation"]) <= 0:
		return {}
	for key in ["profile_identifier", "manifest_fingerprint", \
			"manifest_algorithm", "canonical_hash"]:
		if typeof(envelope[key]) != TYPE_STRING or String(envelope[key]).is_empty():
			return {}
	if typeof(envelope["record_bytes"]) != TYPE_PACKED_BYTE_ARRAY:
		return {}
	var record_bytes := envelope["record_bytes"] as PackedByteArray
	if record_bytes.is_empty() or record_bytes.size() > MAX_PERSISTENCE_RECORD_BYTES:
		last_error = &"persistence_record_size_invalid"
		return {}
	for key in ["canonical_sha256", "record_sha256", "envelope_sha256"]:
		if typeof(envelope[key]) != TYPE_STRING or not _is_sha256(String(envelope[key])):
			return {}
	if _sha256_bytes(record_bytes) != String(envelope["record_sha256"]):
		last_error = &"persistence_record_digest_mismatch"
		return {}
	var normalized := envelope.duplicate(true)
	if _envelope_digest(normalized) != String(normalized["envelope_sha256"]):
		last_error = &"persistence_envelope_digest_mismatch"
		return {}
	return normalized


func _envelope_matches_preflight(envelope: Dictionary, preflight: Dictionary) -> bool:
	if String(envelope["manifest_fingerprint"]) != str(_manifest_fingerprint) \
			or String(envelope["manifest_algorithm"]) != _manifest_algorithm:
		last_error = &"persistence_catalog_mismatch"
		return false
	if int(envelope["inventory_id"]) != int(preflight["inventory_id"]) \
			or String(envelope["profile_identifier"]) \
				!= String(preflight["profile_identifier"]):
		last_error = &"persistence_identity_mismatch"
		return false
	if int(envelope["revision"]) != int(preflight["revision"]) \
			or String(envelope["manifest_fingerprint"]) \
				!= str(preflight["manifest_fingerprint"]) \
			or String(envelope["manifest_algorithm"]) \
				!= String(preflight["manifest_algorithm"]) \
			or String(envelope["canonical_hash"]) != str(preflight["canonical_hash"]) \
			or String(envelope["canonical_sha256"]) \
				!= String(preflight["canonical_sha256"]) \
			or String(envelope["record_sha256"]) \
				!= String(preflight["record_sha256"]):
		last_error = &"persistence_envelope_content_mismatch"
		return false
	return true


func _snapshot_matches_live_target(
	snapshot: InventorySnapshotResource,
	target: Dictionary
) -> bool:
	return snapshot != null \
		and snapshot.get_inventory_id() == int(target.get("inventory_id", 0)) \
		and snapshot.get_profile_identifier() == String(target.get("profile_identifier", "")) \
		and snapshot.get_manifest_fingerprint() == _manifest_fingerprint \
		and snapshot.get_manifest_algorithm() == _manifest_algorithm \
		and not snapshot.canonical_bytes().is_empty()


func _snapshot_matches_preflight(
	snapshot: InventorySnapshotResource,
	preflight: Dictionary
) -> bool:
	return snapshot != null \
		and snapshot.get_inventory_id() == int(preflight["inventory_id"]) \
		and snapshot.get_profile_identifier() == String(preflight["profile_identifier"]) \
		and snapshot.get_revision() == int(preflight["revision"]) \
		and snapshot.get_manifest_fingerprint() == int(preflight["manifest_fingerprint"]) \
		and snapshot.get_manifest_algorithm() == String(preflight["manifest_algorithm"]) \
		and snapshot.hash() == int(preflight["canonical_hash"])


func _resolve_live_target(scope: StringName, inventory_id: int) -> Dictionary:
	if not _binding_is_current() or inventory_id <= 0:
		return {}
	var authority: InventoryAuthority
	if scope == SCOPE_PROFILE and inventory_id == _owner.profile_inventory_id:
		authority = _profile_authority
	elif scope == SCOPE_RAID and inventory_id in [
		_owner.raid_player_inventory_id,
		_owner.world_crate_inventory_id,
		_owner.corpse_inventory_id,
	]:
		authority = _raid_authority
	else:
		return {}
	var snapshot := authority.snapshot(inventory_id)
	if snapshot == null:
		return {}
	return {
		"scope": scope,
		"inventory_id": inventory_id,
		"profile_identifier": snapshot.get_profile_identifier(),
		"authority": authority,
		"authority_id": authority.get_instance_id(),
	}


func _begin_operation(expected_owner_generation: int) -> bool:
	if _operation_active:
		return _reject_bool(&"persistence_operation_active")
	if not _bound or _invalidated:
		return _reject_bool(&"persistence_boundary_not_bound")
	if not _binding_matches_generation(expected_owner_generation):
		if not _binding_is_current():
			_invalidate_binding(&"inventory_owner_generation_invalidated")
		return _reject_bool(&"stale_owner_generation")
	_operation_active = true
	return true


func _end_operation() -> void:
	_operation_active = false


func _binding_matches_generation(expected_owner_generation: int) -> bool:
	return expected_owner_generation == _owner_generation and _binding_is_current()


func _binding_is_current() -> bool:
	return _owner != null and is_instance_valid(_owner) \
		and _owner.get_instance_id() == _owner_instance_id \
		and _owner.is_current_generation(_owner_generation) \
		and _catalog != null and _catalog.get_instance_id() == _catalog_instance_id \
		and _owner.catalog() == _catalog and _catalog.is_sealed() \
		and _catalog.manifest_fingerprint() == _manifest_fingerprint \
		and _catalog.manifest_algorithm() == _manifest_algorithm \
		and _profile_authority != null and is_instance_valid(_profile_authority) \
		and _profile_authority.get_instance_id() == _profile_authority_id \
		and _owner.profile_authority() == _profile_authority \
		and _raid_authority != null and is_instance_valid(_raid_authority) \
		and _raid_authority.get_instance_id() == _raid_authority_id \
		and _owner.raid_authority() == _raid_authority


func _connect_lifecycle_signals() -> void:
	_connect_authority(SCOPE_PROFILE, _profile_authority)
	_connect_authority(SCOPE_RAID, _raid_authority)
	_owner_tree_exiting_callback = Callable(self, "_on_owner_tree_exiting")
	_owner.tree_exiting.connect(_owner_tree_exiting_callback)


func _connect_authority(scope: StringName, authority: InventoryAuthority) -> void:
	var authority_id := authority.get_instance_id()
	var generation_callback := Callable(
		self, "_on_inventory_generation_changing").bind(scope, authority_id)
	var unloaded_callback := Callable(
		self, "_on_inventory_unloaded").bind(scope, authority_id)
	authority.inventory_generation_changing.connect(generation_callback)
	authority.inventory_unloaded.connect(unloaded_callback)
	_authority_connections.append({
		"authority": authority,
		"generation": generation_callback,
		"unloaded": unloaded_callback,
	})


func _disconnect_lifecycle_signals() -> void:
	for entry_value in _authority_connections:
		var entry := entry_value as Dictionary
		var authority_value: Variant = entry.get("authority", null)
		if authority_value == null or not is_instance_valid(authority_value):
			continue
		var authority := authority_value as InventoryAuthority
		var generation_callback := entry.get("generation", Callable()) as Callable
		var unloaded_callback := entry.get("unloaded", Callable()) as Callable
		if generation_callback.is_valid() \
				and authority.inventory_generation_changing.is_connected(generation_callback):
			authority.inventory_generation_changing.disconnect(generation_callback)
		if unloaded_callback.is_valid() \
				and authority.inventory_unloaded.is_connected(unloaded_callback):
			authority.inventory_unloaded.disconnect(unloaded_callback)
	_authority_connections.clear()
	if _owner != null and is_instance_valid(_owner) \
			and _owner_tree_exiting_callback.is_valid() \
			and _owner.tree_exiting.is_connected(_owner_tree_exiting_callback):
		_owner.tree_exiting.disconnect(_owner_tree_exiting_callback)
	_owner_tree_exiting_callback = Callable()


func _on_inventory_generation_changing(
	inventory_id: int,
	scope: StringName,
	authority_id: int
) -> void:
	if not _lifecycle_callback_is_current(scope, authority_id, inventory_id):
		return
	if _operation_active and scope == _replacement_scope \
			and inventory_id == _replacement_inventory_id:
		_replacement_signal_observed = true
		return
	_invalidate_binding(&"inventory_generation_changing")


func _on_inventory_unloaded(
	inventory_id: int,
	scope: StringName,
	authority_id: int
) -> void:
	if _lifecycle_callback_is_current(scope, authority_id, inventory_id):
		_invalidate_binding(&"inventory_unloaded")


func _on_owner_tree_exiting() -> void:
	_invalidate_binding(&"inventory_owner_tree_exiting")


func _lifecycle_callback_is_current(
	scope: StringName,
	authority_id: int,
	inventory_id: int
) -> bool:
	if not _bound or _invalidated or _owner == null or not is_instance_valid(_owner):
		return false
	if scope == SCOPE_PROFILE:
		return _profile_authority != null and is_instance_valid(_profile_authority) \
			and _profile_authority.get_instance_id() == authority_id \
			and inventory_id == _owner.profile_inventory_id
	if scope == SCOPE_RAID:
		return _raid_authority != null and is_instance_valid(_raid_authority) \
			and _raid_authority.get_instance_id() == authority_id \
			and inventory_id in [
				_owner.raid_player_inventory_id,
				_owner.world_crate_inventory_id,
				_owner.corpse_inventory_id,
			]
	return false


func _invalidate_binding(reason: StringName) -> void:
	if not _bound or _invalidated:
		return
	_disconnect_lifecycle_signals()
	_bound = false
	_invalidated = true
	_operation_active = false
	last_error = reason
	_owner = null
	_catalog = null
	_profile_authority = null
	_raid_authority = null
	binding_invalidated.emit(reason)


func _envelope_digest(envelope: Dictionary) -> String:
	var metadata := {
		"schema": String(envelope.get("schema", "")),
		"scope": String(envelope.get("scope", "")),
		"inventory_id": int(envelope.get("inventory_id", 0)),
		"profile_identifier": String(envelope.get("profile_identifier", "")),
		"revision": int(envelope.get("revision", -1)),
		"manifest_fingerprint": String(envelope.get("manifest_fingerprint", "")),
		"manifest_algorithm": String(envelope.get("manifest_algorithm", "")),
		"canonical_hash": String(envelope.get("canonical_hash", "")),
		"canonical_sha256": String(envelope.get("canonical_sha256", "")),
		"record_sha256": String(envelope.get("record_sha256", "")),
		"source_owner_generation": int(envelope.get("source_owner_generation", 0)),
	}
	return ZCanonicalValue.sha256(metadata)


static func _sha256_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


static func _is_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for character in value:
		if not "0123456789abcdef".contains(character):
			return false
	return true


func _success(
	inventory_id: int,
	duplicate: bool,
	replaced: bool,
	previous_sha256: String,
	restored_sha256: String,
	canonical_hash: int,
	native_status: Dictionary
) -> Dictionary:
	last_error = &""
	return {
		"ok": true,
		"accepted": true,
		"duplicate": duplicate,
		"replaced": replaced,
		"reason": &"",
		"native_status": native_status.duplicate(true),
		"inventory_id": inventory_id,
		"previous_canonical_sha256": previous_sha256,
		"restored_canonical_sha256": restored_sha256,
		"canonical_hash": canonical_hash,
	}


func _failure(
	reason: StringName,
	native_status: Dictionary = {},
	inventory_id: int = 0,
	previous_sha256: String = "",
	restored_sha256: String = ""
) -> Dictionary:
	last_error = reason
	return {
		"ok": false,
		"accepted": false,
		"duplicate": false,
		"replaced": false,
		"reason": reason,
		"native_status": native_status.duplicate(true),
		"inventory_id": inventory_id,
		"previous_canonical_sha256": previous_sha256,
		"restored_canonical_sha256": restored_sha256,
	}


func _reject_bool(reason: StringName) -> bool:
	last_error = reason
	return false
