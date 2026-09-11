class_name ProfileStore
extends RefCounted
## Versioned, fail-closed local profile persistence for the offline game.
##
## The supported runtime is single-process and single-writer. An in-process
## lease rejects two ProfileStore writers for the same storage identity, but no
## interprocess lock is claimed. Lease-map and instance-state transitions are
## mutex-linearized across Godot Threads; the mutexes are never held across an
## adapter callback, hashing, serialization, or storage I/O. Production paths
## are fixed by GodotProfileFileOperations; the injected operations entry
## point is a trusted test seam and never receives caller-selected paths.

const GodotOperations = preload("res://game/profile/godot_profile_file_operations.gd")

const ENVELOPE_SCHEMA: String = "zerkov.profile.envelope"
const ENVELOPE_VERSION: int = 1
const PAYLOAD_SCHEMA: String = "zerkov.profile.payload.v1"
const CHECKSUM_ALGORITHM: String = "sha256"
const FINGERPRINT_ALGORITHM: String = "sha256"
const PAYLOAD_CHECKSUM_DOMAIN: String = "zerkov.profile.payload-checksum.v1"
const ENVELOPE_FINGERPRINT_DOMAIN: String = "zerkov.profile.envelope-fingerprint.v1"

const MAX_PROFILE_FILE_BYTES: int = ProfileCanonicalCodec.MAX_ENCODED_BYTES
const MAX_PROFILE_ID_BYTES: int = 192
const MAX_PROFILE_ID_SEGMENTS: int = 8
const MAX_PROFILE_ID_SEGMENT_BYTES: int = 48
const MAX_DOMAIN_RECORDS: int = 16
const MAX_DOMAIN_KEY_BYTES: int = 128
const MAX_TOTAL_DOMAIN_BYTES: int = 1_800_000
const MAX_COUNTER: int = ProfileCanonicalCodec.MAX_ABS_INTEGER

const LOAD_PRIMARY: StringName = &"loaded_primary"
const LOAD_RECOVERED_BACKUP: StringName = &"recovered_backup"
const LOAD_FAILED: StringName = &"load_failed"

const WRITE_COMMITTED_DURABLE: StringName = &"committed_durable"
const WRITE_COMMITTED_DURABILITY_UNCERTAIN: StringName = \
	&"committed_durability_uncertain"
const WRITE_COMMITTED_RECOVERY_REQUIRED: StringName = \
	&"committed_recovery_required"
const WRITE_REPLAYED: StringName = &"replayed_exact_write"
const WRITE_PRE_COMMIT_FAILED: StringName = &"pre_commit_failed"

const _ENVELOPE_KEYS: PackedStringArray = [
	"checksum_algorithm",
	"codec",
	"fingerprint",
	"fingerprint_algorithm",
	"generation",
	"payload",
	"payload_checksum",
	"payload_schema",
	"profile_id",
	"revision",
	"schema",
	"version",
]
const _PAYLOAD_KEYS: PackedStringArray = ["domains", "project"]

static var _writer_leases: Dictionary = {}
static var _writer_leases_mutex: Mutex = Mutex.new()

var _state_mutex: Mutex = Mutex.new()
var _last_error: StringName = &""
var last_error: StringName:
	get:
		_state_mutex.lock()
		var result := _last_error
		_state_mutex.unlock()
		return result

var _configured: bool = false
var _configuration_active: bool = false
var _operation_active: bool = false
var _profile_id: String = ""
var _operations: ProfileFileOperations
var _lease_key: String = ""


func configure(profile_id: String) -> bool:
	return _configure(profile_id, GodotOperations.new())


## Trusted test seam. Production composition must call configure(), which does
## not accept a root, directory, filename, or arbitrary path.
func configure_with_trusted_operations(
	profile_id: String,
	operations: ProfileFileOperations
) -> bool:
	if not OS.is_debug_build():
		return _reject_bool(&"trusted_file_operations_debug_only")
	return _configure(profile_id, operations)


## Releases this store's in-process lease. Teardown is refused while configure
## or load/save is active, so close can never publish the lease mid-operation.
func close() -> bool:
	_writer_leases_mutex.lock()
	_state_mutex.lock()
	if _configuration_active:
		_last_error = &"profile_store_configuration_active"
		_state_mutex.unlock()
		_writer_leases_mutex.unlock()
		return false
	if _operation_active:
		_last_error = &"profile_store_operation_active"
		_state_mutex.unlock()
		_writer_leases_mutex.unlock()
		return false
	if not _configured:
		_last_error = &""
		_state_mutex.unlock()
		_writer_leases_mutex.unlock()
		return true
	var held: Variant = _writer_leases.get(_lease_key)
	var owned_lease: bool = held is WeakRef and (held as WeakRef).get_ref() == self
	if owned_lease:
		_writer_leases.erase(_lease_key)
	_configured = false
	_operation_active = false
	_profile_id = ""
	_lease_key = ""
	_operations = null
	_last_error = &"" if owned_lease else &"single_writer_lease_lost"
	_state_mutex.unlock()
	_writer_leases_mutex.unlock()
	return owned_lease


func is_configured() -> bool:
	_writer_leases_mutex.lock()
	_state_mutex.lock()
	var held: Variant = _writer_leases.get(_lease_key)
	var result: bool = _configured and _operations != null \
		and held is WeakRef and (held as WeakRef).get_ref() == self
	_state_mutex.unlock()
	_writer_leases_mutex.unlock()
	return result


func profile_id() -> String:
	_state_mutex.lock()
	var result := _profile_id
	_state_mutex.unlock()
	return result


func storage_capabilities() -> Dictionary:
	var operations := _snapshot_current_operations()
	if operations == null:
		return _freeze({}) as Dictionary
	# The adapter callback stays outside both mutexes. The local strong reference
	# remains valid if another thread closes immediately after the snapshot.
	var result := operations.capabilities().duplicate(true)
	result["in_process_lease_thread_safe"] = true
	result["per_store_operation_admission_thread_safe"] = true
	return _freeze(result) as Dictionary


## Loads no default. Primary and backup are read and validated independently.
## A corrupt or missing primary may fall back to a valid backup, but unsafe
## filesystem objects, I/O uncertainty, or divergent equal generations fail
## closed even if one candidate appears valid.
func load_profile() -> Dictionary:
	var admission_reason := _begin_operation()
	if not admission_reason.is_empty():
		return _load_failure(admission_reason)
	var selection := _read_selection()
	if not bool(selection.get("ok", false)):
		var failure_reason := StringName(selection.get("reason", &"profile_load_failed"))
		_finish_operation(failure_reason)
		return _load_failure(failure_reason, selection)
	var selected := selection["selected"] as Dictionary
	var envelope := selected["envelope"] as Dictionary
	var recovered := StringName(selected["slot"]) == ProfileFileOperations.SLOT_BACKUP
	var recovery_reason: StringName = &""
	if recovered:
		var primary := selection["primary"] as Dictionary
		if primary.get("state", &"") == &"missing":
			recovery_reason = &"primary_missing_backup_selected"
		elif primary.get("state", &"") == &"invalid":
			recovery_reason = &"primary_invalid_backup_selected"
		else:
			recovery_reason = &"newer_backup_selected"
	var result := _freeze({
		"ok": true,
		"status": LOAD_RECOVERED_BACKUP if recovered else LOAD_PRIMARY,
		"reason": recovery_reason,
		"source": selected["slot"],
		"recovered_backup": recovered,
		"profile_id": envelope["profile_id"],
		"generation": envelope["generation"],
		"revision": envelope["revision"],
		"fingerprint": envelope["fingerprint"],
		"payload_checksum": envelope["payload_checksum"],
		"payload": envelope["payload"],
		"primary_validation": _candidate_diagnostic(selection["primary"] as Dictionary),
		"backup_validation": _candidate_diagnostic(selection["backup"] as Dictionary),
	}) as Dictionary
	_finish_operation(&"")
	return result


## Compare-and-swap save. candidate generation is expected_generation + 1;
## profile revision must match that generation and therefore advance exactly
## once. Replaying the exact payload, expected generation, and revision reads
## both copies for validation, but performs no write or storage mutation. A
## divergent candidate at that generation fails closed.
func save_profile(
	payload: Dictionary,
	expected_generation: int,
	revision: int
) -> Dictionary:
	var admission_reason := _begin_operation()
	if not admission_reason.is_empty():
		return _write_failure(admission_reason)
	var result := _save_profile_active(payload, expected_generation, revision)
	_finish_operation(StringName(result.get("reason", &"")))
	return _freeze(result) as Dictionary


func _save_profile_active(
	payload: Dictionary,
	expected_generation: int,
	revision: int
) -> Dictionary:
	if expected_generation < 0 or expected_generation >= MAX_COUNTER:
		return _write_failure(&"expected_generation_invalid")
	if revision <= 0 or revision > MAX_COUNTER:
		return _write_failure(&"revision_invalid")
	var candidate_generation := expected_generation + 1
	if revision != candidate_generation:
		return _write_failure(&"generation_revision_lineage_invalid")
	var payload_validation := _validate_payload(payload)
	if not bool(payload_validation.get("ok", false)):
		return _write_failure(StringName(payload_validation.get("reason", &"payload_invalid")))

	var selection := _read_selection()
	var is_missing: bool = not bool(selection.get("ok", false)) \
		and selection.get("reason", &"") == &"profile_missing"
	if not bool(selection.get("ok", false)) and not is_missing:
		return _write_failure(
			StringName(selection.get("reason", &"profile_load_failed")), selection)

	var current: Dictionary = {}
	if not is_missing:
		current = selection["selected"] as Dictionary
	var candidate := _build_envelope_bytes(payload, candidate_generation, revision)
	if not bool(candidate.get("ok", false)):
		return _write_failure(StringName(candidate.get("reason", &"envelope_build_failed")))

	if current.is_empty():
		if expected_generation != 0:
			return _write_failure(&"stale_generation")
		if revision != 1:
			return _write_failure(&"revision_not_monotonic")
	else:
		var current_envelope := current["envelope"] as Dictionary
		var current_generation := int(current_envelope["generation"])
		var current_revision := int(current_envelope["revision"])
		if current_generation == candidate_generation:
			if (current["bytes"] as PackedByteArray) \
					== (candidate["bytes"] as PackedByteArray):
				return _write_success(
					WRITE_REPLAYED, candidate, true, true,
					StringName(current["slot"]), selection, {}, {})
			return _write_failure(&"generation_replay_conflict", selection)
		if current_generation != expected_generation:
			return _write_failure(&"stale_generation", selection)
		if current_revision >= MAX_COUNTER or revision != current_revision + 1:
			return _write_failure(&"revision_not_monotonic", selection)

	var cleanup_before := _cleanup_temps()
	if not bool(cleanup_before.get("ok", false)):
		return _write_failure(
			StringName(cleanup_before.get("reason", &"temp_cleanup_failed")),
			selection, cleanup_before)

	var candidate_bytes := candidate["bytes"] as PackedByteArray
	var candidate_write := _operations.write_temp(
		ProfileFileOperations.SLOT_WRITE_TEMP, candidate_bytes)
	if not bool(candidate_write.get("ok", false)):
		var failed_cleanup := _cleanup_temps()
		return _write_failure(
			StringName(candidate_write.get("reason", &"candidate_temp_write_failed")),
			selection, failed_cleanup)
	var staged_candidate := _validate_staged(
		ProfileFileOperations.SLOT_WRITE_TEMP, candidate_bytes)
	if not bool(staged_candidate.get("ok", false)):
		var invalid_cleanup := _cleanup_temps()
		return _write_failure(
			StringName(staged_candidate.get("reason", &"candidate_temp_invalid")),
			selection, invalid_cleanup)

	var backup_rotation: Dictionary = {
		"attempted": false,
		"replaced": false,
		"verified": false,
		"preserved_recovered_backup": false,
	}
	if not current.is_empty() \
			and StringName(current["slot"]) == ProfileFileOperations.SLOT_PRIMARY:
		backup_rotation = _rotate_validated_primary_to_backup(current)
		if not bool(backup_rotation.get("ok", false)):
			var rotation_cleanup := _cleanup_temps()
			return _write_failure(
				StringName(backup_rotation.get("reason", &"backup_rotation_failed")),
				selection, rotation_cleanup, backup_rotation)
	elif not current.is_empty():
		# Recovery selected the already-validated backup. Never replace it with
		# bytes from an invalid or missing primary.
		backup_rotation = {
			"ok": true,
			"attempted": false,
			"replaced": false,
			"verified": true,
			"preserved_recovered_backup": true,
		}

	var primary_replace := _operations.replace_slot(
		ProfileFileOperations.SLOT_WRITE_TEMP,
		ProfileFileOperations.SLOT_PRIMARY)
	var replace_committed := bool(primary_replace.get("committed", false))
	if not replace_committed:
		var replace_cleanup := _cleanup_temps()
		var replace_reason := StringName(primary_replace.get("reason", &""))
		if replace_reason.is_empty():
			replace_reason = &"primary_replace_not_committed"
		return _write_failure(
			replace_reason,
			selection, replace_cleanup, backup_rotation)

	var committed_validation := _validate_staged(
		ProfileFileOperations.SLOT_PRIMARY, candidate_bytes)
	var cleanup_after := _cleanup_temps()
	if not bool(committed_validation.get("ok", false)):
		return _write_success(
			WRITE_COMMITTED_RECOVERY_REQUIRED, candidate, false, true,
			ProfileFileOperations.SLOT_PRIMARY, selection,
			backup_rotation, cleanup_after,
			StringName(committed_validation.get("reason", &"committed_primary_unverified")),
			{}, primary_replace)

	var directory_sync := _operations.sync_directory()
	var fully_durable := bool(primary_replace.get("ok", false)) \
		and replace_committed \
		and bool(candidate_write.get("durable", false)) \
		and bool(directory_sync.get("supported", false)) \
		and bool(directory_sync.get("ok", false))
	var status := WRITE_COMMITTED_DURABLE if fully_durable \
		else WRITE_COMMITTED_DURABILITY_UNCERTAIN
	var durability_reason: StringName = &""
	if not fully_durable:
		if not bool(primary_replace.get("ok", false)):
			durability_reason = StringName(primary_replace.get("reason", &""))
			if durability_reason.is_empty():
				durability_reason = &"post_replace_operation_failed"
		elif not bool(candidate_write.get("durable", false)):
			durability_reason = &"file_durability_not_proven"
		elif not bool(directory_sync.get("supported", false)):
			durability_reason = StringName(directory_sync.get("reason", &""))
			if durability_reason.is_empty():
				durability_reason = &"directory_sync_unsupported"
		else:
			durability_reason = StringName(directory_sync.get("reason", &""))
			if durability_reason.is_empty():
				durability_reason = &"directory_sync_failed"
	return _write_success(
		status, candidate, false, true, ProfileFileOperations.SLOT_PRIMARY,
		selection, backup_rotation, cleanup_after, durability_reason,
		directory_sync, primary_replace)


func _rotate_validated_primary_to_backup(current: Dictionary) -> Dictionary:
	var primary_bytes := current["bytes"] as PackedByteArray
	var write := _operations.write_temp(
		ProfileFileOperations.SLOT_BACKUP_TEMP, primary_bytes)
	if not bool(write.get("ok", false)):
		return {
			"ok": false,
			"attempted": true,
			"replaced": false,
			"verified": false,
			"reason": StringName(write.get("reason", &"backup_temp_write_failed")),
		}
	var staged := _validate_staged(ProfileFileOperations.SLOT_BACKUP_TEMP, primary_bytes)
	if not bool(staged.get("ok", false)):
		return {
			"ok": false,
			"attempted": true,
			"replaced": false,
			"verified": false,
			"reason": StringName(staged.get("reason", &"backup_temp_invalid")),
		}
	var replace := _operations.replace_slot(
		ProfileFileOperations.SLOT_BACKUP_TEMP,
		ProfileFileOperations.SLOT_BACKUP)
	var replace_committed := bool(replace.get("committed", false))
	if not bool(replace.get("ok", false)) and not replace_committed:
		return {
			"ok": false,
			"attempted": true,
			"replaced": false,
			"verified": false,
			"reason": StringName(replace.get("reason", &"backup_replace_failed")),
		}
	var verified := _validate_staged(ProfileFileOperations.SLOT_BACKUP, primary_bytes)
	if not bool(verified.get("ok", false)):
		return {
			"ok": false,
			"attempted": true,
			"replaced": replace_committed,
			"verified": false,
			"reason": StringName(verified.get("reason", &"backup_replace_unverified")),
		}
	return {
		"ok": bool(replace.get("ok", false)),
		"attempted": true,
		"replaced": true,
		"verified": true,
		"post_replace_error": not bool(replace.get("ok", false)),
		"reason": StringName(replace.get("reason", &"")),
	}


func _read_selection() -> Dictionary:
	var primary := _read_candidate(ProfileFileOperations.SLOT_PRIMARY)
	var backup := _read_candidate(ProfileFileOperations.SLOT_BACKUP)
	for candidate in [primary, backup]:
		var state := StringName((candidate as Dictionary).get("state", &"io_error"))
		if state == &"unsafe" or state == &"io_error":
			return {
				"ok": false,
				"reason": &"storage_unsafe_or_unreadable",
				"primary": primary,
				"backup": backup,
			}
	var primary_valid: bool = primary.get("state", &"") == &"valid"
	var backup_valid: bool = backup.get("state", &"") == &"valid"
	if not primary_valid and not backup_valid:
		var both_missing: bool = primary.get("state", &"") == &"missing" \
			and backup.get("state", &"") == &"missing"
		return {
			"ok": false,
			"reason": &"profile_missing" if both_missing else &"profile_unreadable",
			"primary": primary,
			"backup": backup,
		}
	var selected: Dictionary
	if primary_valid and not backup_valid:
		selected = primary
	elif backup_valid and not primary_valid:
		selected = backup
	else:
		var primary_generation := int((primary["envelope"] as Dictionary)["generation"])
		var backup_generation := int((backup["envelope"] as Dictionary)["generation"])
		if primary_generation == backup_generation:
			if (primary["bytes"] as PackedByteArray) != (backup["bytes"] as PackedByteArray):
				return {
					"ok": false,
					"reason": &"equal_generation_divergence",
					"primary": primary,
					"backup": backup,
				}
			selected = primary
		else:
			selected = primary if primary_generation > backup_generation else backup
	return {
		"ok": true,
		"reason": &"",
		"selected": selected,
		"primary": primary,
		"backup": backup,
	}


func _read_candidate(slot: StringName) -> Dictionary:
	var read := _operations.read_slot(slot, MAX_PROFILE_FILE_BYTES)
	var storage_state := StringName(read.get("state", ProfileFileOperations.STATE_ERROR))
	if storage_state == ProfileFileOperations.STATE_MISSING:
		return {"slot": slot, "state": &"missing", "reason": &"profile_file_missing"}
	if storage_state == ProfileFileOperations.STATE_UNSAFE:
		return {
			"slot": slot,
			"state": &"unsafe",
			"reason": StringName(read.get("reason", &"storage_slot_unsafe")),
		}
	if storage_state == ProfileFileOperations.STATE_INVALID:
		return {
			"slot": slot,
			"state": &"invalid",
			"reason": StringName(read.get("reason", &"profile_file_invalid")),
		}
	if not bool(read.get("ok", false)) or storage_state != ProfileFileOperations.STATE_REGULAR:
		return {
			"slot": slot,
			"state": &"io_error",
			"reason": StringName(read.get("reason", &"profile_read_failed")),
		}
	var bytes := read.get("bytes", PackedByteArray()) as PackedByteArray
	var decoded := _decode_envelope(bytes)
	if not bool(decoded.get("ok", false)):
		return {
			"slot": slot,
			"state": &"invalid",
			"reason": StringName(decoded.get("reason", &"profile_envelope_invalid")),
		}
	return {
		"slot": slot,
		"state": &"valid",
		"reason": &"",
		"bytes": bytes,
		"envelope": decoded["envelope"],
	}


func _build_envelope_bytes(
	payload: Dictionary,
	generation: int,
	revision: int
) -> Dictionary:
	var payload_copy := payload.duplicate(true)
	var payload_encoded := ProfileCanonicalCodec.encode(payload_copy)
	if not bool(payload_encoded.get("ok", false)):
		return {"ok": false, "reason": payload_encoded.get("reason", &"payload_encode_failed")}
	var payload_bytes := payload_encoded["bytes"] as PackedByteArray
	var checksum := ProfileCanonicalCodec.sha256_domain(
		PAYLOAD_CHECKSUM_DOMAIN, payload_bytes)
	if not ProfileCanonicalCodec.is_sha256(checksum):
		return {"ok": false, "reason": &"payload_checksum_failed"}
	var core := {
		"checksum_algorithm": CHECKSUM_ALGORITHM,
		"codec": ProfileCanonicalCodec.FORMAT,
		"fingerprint_algorithm": FINGERPRINT_ALGORITHM,
		"generation": generation,
		"payload": payload_copy,
		"payload_checksum": checksum,
		"payload_schema": PAYLOAD_SCHEMA,
		"profile_id": _profile_id,
		"revision": revision,
		"schema": ENVELOPE_SCHEMA,
		"version": ENVELOPE_VERSION,
	}
	var core_encoded := ProfileCanonicalCodec.encode(core)
	if not bool(core_encoded.get("ok", false)):
		return {"ok": false, "reason": &"fingerprint_input_encode_failed"}
	var fingerprint := ProfileCanonicalCodec.sha256_domain(
		ENVELOPE_FINGERPRINT_DOMAIN,
		core_encoded["bytes"] as PackedByteArray)
	if not ProfileCanonicalCodec.is_sha256(fingerprint):
		return {"ok": false, "reason": &"envelope_fingerprint_failed"}
	var envelope := core.duplicate(true)
	envelope["fingerprint"] = fingerprint
	var encoded := ProfileCanonicalCodec.encode(envelope)
	if not bool(encoded.get("ok", false)):
		return {"ok": false, "reason": encoded.get("reason", &"envelope_encode_failed")}
	return {
		"ok": true,
		"bytes": encoded["bytes"],
		"envelope": envelope,
		"generation": generation,
		"revision": revision,
		"fingerprint": fingerprint,
		"payload_checksum": checksum,
	}


func _decode_envelope(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > MAX_PROFILE_FILE_BYTES:
		return {"ok": false, "reason": &"profile_file_size_invalid"}
	var decoded := ProfileCanonicalCodec.decode(bytes)
	if not bool(decoded.get("ok", false)):
		return {"ok": false, "reason": decoded.get("reason", &"profile_decode_failed")}
	if typeof(decoded.get("value")) != TYPE_DICTIONARY:
		return {"ok": false, "reason": &"envelope_type_invalid"}
	var envelope := decoded["value"] as Dictionary
	if not _has_exact_keys(envelope, _ENVELOPE_KEYS):
		return {"ok": false, "reason": &"envelope_fields_invalid"}
	for string_field in [
		"checksum_algorithm", "codec", "fingerprint", "fingerprint_algorithm",
		"payload_checksum", "payload_schema", "profile_id", "schema",
	]:
		if typeof(envelope[string_field]) != TYPE_STRING:
			return {"ok": false, "reason": &"envelope_field_type_invalid"}
	if typeof(envelope["version"]) != TYPE_INT \
			or typeof(envelope["generation"]) != TYPE_INT \
			or typeof(envelope["revision"]) != TYPE_INT \
			or typeof(envelope["payload"]) != TYPE_DICTIONARY:
		return {"ok": false, "reason": &"envelope_field_type_invalid"}
	if envelope["schema"] != ENVELOPE_SCHEMA \
			or envelope["version"] != ENVELOPE_VERSION \
			or envelope["payload_schema"] != PAYLOAD_SCHEMA \
			or envelope["codec"] != ProfileCanonicalCodec.FORMAT:
		return {"ok": false, "reason": &"envelope_version_unsupported"}
	if envelope["profile_id"] != _profile_id:
		return {"ok": false, "reason": &"profile_identity_mismatch"}
	if envelope["checksum_algorithm"] != CHECKSUM_ALGORITHM \
			or envelope["fingerprint_algorithm"] != FINGERPRINT_ALGORITHM:
		return {"ok": false, "reason": &"digest_algorithm_unsupported"}
	var generation := envelope["generation"] as int
	var revision := envelope["revision"] as int
	if generation <= 0 or generation > MAX_COUNTER \
			or revision <= 0 or revision > MAX_COUNTER:
		return {"ok": false, "reason": &"envelope_counter_invalid"}
	if generation != revision:
		return {"ok": false, "reason": &"generation_revision_lineage_invalid"}
	var payload := envelope["payload"] as Dictionary
	var payload_validation := _validate_payload(payload)
	if not bool(payload_validation.get("ok", false)):
		return {"ok": false, "reason": payload_validation.get("reason", &"payload_invalid")}
	var payload_encoded := ProfileCanonicalCodec.encode(payload)
	if not bool(payload_encoded.get("ok", false)):
		return {"ok": false, "reason": &"payload_encode_failed"}
	var expected_checksum := ProfileCanonicalCodec.sha256_domain(
		PAYLOAD_CHECKSUM_DOMAIN,
		payload_encoded["bytes"] as PackedByteArray)
	if not ProfileCanonicalCodec.is_sha256(envelope["payload_checksum"]) \
			or not _digest_equal(envelope["payload_checksum"] as String, expected_checksum):
		return {"ok": false, "reason": &"payload_checksum_mismatch"}
	if not ProfileCanonicalCodec.is_sha256(envelope["fingerprint"]):
		return {"ok": false, "reason": &"envelope_fingerprint_invalid"}
	var core := envelope.duplicate(true)
	core.erase("fingerprint")
	var core_encoded := ProfileCanonicalCodec.encode(core)
	if not bool(core_encoded.get("ok", false)):
		return {"ok": false, "reason": &"fingerprint_input_encode_failed"}
	var expected_fingerprint := ProfileCanonicalCodec.sha256_domain(
		ENVELOPE_FINGERPRINT_DOMAIN,
		core_encoded["bytes"] as PackedByteArray)
	if not _digest_equal(envelope["fingerprint"] as String, expected_fingerprint):
		return {"ok": false, "reason": &"envelope_fingerprint_mismatch"}
	return {"ok": true, "reason": &"", "envelope": envelope}


func _validate_payload(payload: Dictionary) -> Dictionary:
	if not _has_exact_keys(payload, _PAYLOAD_KEYS):
		return {"ok": false, "reason": &"payload_fields_invalid"}
	if typeof(payload["project"]) != TYPE_DICTIONARY \
			or typeof(payload["domains"]) != TYPE_DICTIONARY:
		return {"ok": false, "reason": &"payload_field_type_invalid"}
	var domains := payload["domains"] as Dictionary
	if domains.size() > MAX_DOMAIN_RECORDS:
		return {"ok": false, "reason": &"domain_count_exceeded"}
	var total_bytes: int = 0
	for key in domains:
		if typeof(key) != TYPE_STRING or not _is_domain_key(key as String):
			return {"ok": false, "reason": &"domain_key_invalid"}
		if typeof(domains[key]) != TYPE_PACKED_BYTE_ARRAY:
			return {"ok": false, "reason": &"domain_record_type_invalid"}
		var record := domains[key] as PackedByteArray
		if record.size() > ProfileCanonicalCodec.MAX_BLOB_BYTES:
			return {"ok": false, "reason": &"domain_record_too_large"}
		total_bytes += record.size()
		if total_bytes > MAX_TOTAL_DOMAIN_BYTES:
			return {"ok": false, "reason": &"domain_bytes_exceeded"}
	var encoded := ProfileCanonicalCodec.encode(payload)
	if not bool(encoded.get("ok", false)):
		return {"ok": false, "reason": encoded.get("reason", &"payload_invalid")}
	return {"ok": true, "reason": &"", "bytes": encoded["bytes"]}


func _validate_staged(slot: StringName, expected_bytes: PackedByteArray) -> Dictionary:
	var candidate := _read_candidate(slot)
	if candidate.get("state", &"") != &"valid":
		return {
			"ok": false,
			"reason": candidate.get("reason", &"staged_profile_invalid"),
		}
	if (candidate["bytes"] as PackedByteArray) != expected_bytes:
		return {"ok": false, "reason": &"staged_profile_bytes_mismatch"}
	return {"ok": true, "reason": &""}


func _cleanup_temps() -> Dictionary:
	var details: Dictionary = {}
	var ok: bool = true
	var first_reason: StringName = &""
	for slot in [
		ProfileFileOperations.SLOT_WRITE_TEMP,
		ProfileFileOperations.SLOT_BACKUP_TEMP,
	]:
		var result := _operations.remove_slot(slot)
		details[String(slot)] = result
		if not bool(result.get("ok", false)):
			ok = false
			if first_reason.is_empty():
				first_reason = StringName(result.get("reason", &"temp_cleanup_failed"))
	return {"ok": ok, "reason": first_reason, "slots": details}


func _configure(profile_id: String, operations: ProfileFileOperations) -> bool:
	if not _begin_configuration():
		return false
	if not _is_profile_id_valid(profile_id):
		return _finish_configuration_failure(&"profile_id_invalid")
	if operations == null:
		return _finish_configuration_failure(&"file_operations_invalid")
	# Adapter setup can touch the filesystem or invoke a trusted test double, so
	# it deliberately runs without either ProfileStore mutex held.
	var configured := operations.configure(profile_id)
	if not bool(configured.get("ok", false)):
		return _finish_configuration_failure(StringName(
			configured.get("reason", &"file_operations_configure_failed")))
	var prepared := operations.prepare()
	if not bool(prepared.get("ok", false)):
		return _finish_configuration_failure(StringName(
			prepared.get("reason", &"storage_prepare_failed")))
	var key := operations.lease_key()
	if key.is_empty() or key.to_utf8_buffer().size() > 1024:
		return _finish_configuration_failure(&"storage_lease_key_invalid")

	# Lock order is always global lease map, then instance state. No adapter
	# callback or storage I/O occurs while either mutex is held.
	_writer_leases_mutex.lock()
	_state_mutex.lock()
	var existing: Variant = _writer_leases.get(key)
	if existing is WeakRef and (existing as WeakRef).get_ref() != null:
		_configuration_active = false
		_last_error = &"single_writer_lease_held"
		_state_mutex.unlock()
		_writer_leases_mutex.unlock()
		return false
	_writer_leases[key] = weakref(self)
	_operations = operations
	_profile_id = profile_id
	_lease_key = key
	_configured = true
	_configuration_active = false
	_last_error = &""
	_state_mutex.unlock()
	_writer_leases_mutex.unlock()
	return true


func _begin_operation() -> StringName:
	var observed_operations: ProfileFileOperations
	var observed_key: String
	_state_mutex.lock()
	if not _configured or _operations == null:
		_last_error = &"profile_store_not_configured"
		_state_mutex.unlock()
		return &"profile_store_not_configured"
	observed_operations = _operations
	observed_key = _lease_key
	_state_mutex.unlock()

	# This trusted callback remains outside the mutex. State and lease identity
	# are rechecked atomically afterward, so close/reconfigure cannot create a
	# stale admission window.
	var reported_key := observed_operations.lease_key()
	_writer_leases_mutex.lock()
	_state_mutex.lock()
	var reason: StringName = &""
	if not _configured or _operations == null:
		reason = &"profile_store_not_configured"
	elif _operations != observed_operations or _lease_key != observed_key:
		reason = &"storage_identity_changed"
	elif reported_key != observed_key:
		reason = &"storage_identity_changed"
	else:
		var held: Variant = _writer_leases.get(observed_key)
		if not (held is WeakRef) or (held as WeakRef).get_ref() != self:
			reason = &"single_writer_lease_lost"
		elif _operation_active:
			reason = &"profile_store_reentrant_operation"
	if not reason.is_empty():
		_last_error = reason
		_state_mutex.unlock()
		_writer_leases_mutex.unlock()
		return reason
	_operation_active = true
	_last_error = &""
	_state_mutex.unlock()
	_writer_leases_mutex.unlock()
	return &""


func _finish_operation(reason: StringName) -> void:
	_state_mutex.lock()
	_operation_active = false
	_last_error = reason
	_state_mutex.unlock()


func _begin_configuration() -> bool:
	_state_mutex.lock()
	if _configured:
		_last_error = &"profile_store_already_configured"
		_state_mutex.unlock()
		return false
	if _configuration_active:
		_last_error = &"profile_store_configuration_active"
		_state_mutex.unlock()
		return false
	_configuration_active = true
	_last_error = &""
	_state_mutex.unlock()
	return true


func _finish_configuration_failure(reason: StringName) -> bool:
	_state_mutex.lock()
	_configuration_active = false
	_last_error = reason
	_state_mutex.unlock()
	return false


func _snapshot_current_operations() -> ProfileFileOperations:
	_writer_leases_mutex.lock()
	_state_mutex.lock()
	var held: Variant = _writer_leases.get(_lease_key)
	var result: ProfileFileOperations
	if _configured and _operations != null \
			and held is WeakRef and (held as WeakRef).get_ref() == self:
		result = _operations
	_state_mutex.unlock()
	_writer_leases_mutex.unlock()
	return result


func _reject_bool(reason: StringName) -> bool:
	_state_mutex.lock()
	_last_error = reason
	_state_mutex.unlock()
	return false


static func _has_exact_keys(dictionary: Dictionary, expected: PackedStringArray) -> bool:
	if dictionary.size() != expected.size():
		return false
	for key in dictionary:
		if typeof(key) != TYPE_STRING or not expected.has(key as String):
			return false
	return true


static func _is_profile_id_valid(value: String) -> bool:
	if value.to_utf8_buffer().size() > MAX_PROFILE_ID_BYTES:
		return false
	var segments := value.split(".", true)
	if segments.size() < 3 or segments.size() > MAX_PROFILE_ID_SEGMENTS \
			or segments[0] != "zerkov" or segments[1] != "profile":
		return false
	for segment in segments:
		if segment.is_empty() or segment.to_utf8_buffer().size() > MAX_PROFILE_ID_SEGMENT_BYTES:
			return false
		for index in segment.length():
			var code := segment.unicode_at(index)
			if not (code >= 97 and code <= 122) \
					and not (code >= 48 and code <= 57) and code != 95 and code != 45:
				return false
	return true


static func _is_domain_key(value: String) -> bool:
	if not value.begins_with("zerkov.") or value.to_utf8_buffer().size() > MAX_DOMAIN_KEY_BYTES:
		return false
	var segments := value.split(".", true)
	if segments.size() < 2 or segments.size() > 12:
		return false
	for segment in segments:
		if segment.is_empty():
			return false
		for index in segment.length():
			var code := segment.unicode_at(index)
			if not (code >= 97 and code <= 122) \
					and not (code >= 48 and code <= 57) and code != 95 and code != 45:
				return false
	return true


static func _digest_equal(left: String, right: String) -> bool:
	if left.length() != right.length() or left.length() != 64:
		return false
	var difference: int = 0
	for index in left.length():
		difference |= left.unicode_at(index) ^ right.unicode_at(index)
	return difference == 0


static func _candidate_diagnostic(candidate: Dictionary) -> Dictionary:
	return {
		"slot": candidate.get("slot", &""),
		"state": candidate.get("state", &""),
		"reason": candidate.get("reason", &""),
		"generation": int((candidate.get("envelope", {}) as Dictionary).get("generation", 0)),
		"revision": int((candidate.get("envelope", {}) as Dictionary).get("revision", 0)),
	}


static func _write_failure(
	reason: StringName,
	selection: Dictionary = {},
	cleanup: Dictionary = {},
	backup_rotation: Dictionary = {}
) -> Dictionary:
	return _freeze({
		"ok": false,
		"status": WRITE_PRE_COMMIT_FAILED,
		"reason": reason,
		"committed": false,
		"write_performed": false,
		"durable": false,
		"verified": false,
		"replayed": false,
		"recovery_required": false,
		"selection": selection,
		"cleanup": cleanup,
		"backup_rotation": backup_rotation,
	}) as Dictionary


static func _write_success(
	status: StringName,
	candidate: Dictionary,
	replayed: bool,
	committed: bool,
	source: StringName,
	selection: Dictionary,
	backup_rotation: Dictionary,
	cleanup: Dictionary,
	reason: StringName = &"",
	directory_sync: Dictionary = {},
	primary_replace: Dictionary = {}
) -> Dictionary:
	var envelope := candidate["envelope"] as Dictionary
	return {
		"ok": status != WRITE_COMMITTED_RECOVERY_REQUIRED,
		"status": status,
		"reason": reason,
		"committed": committed,
		"write_performed": committed and not replayed,
		"durable": status == WRITE_COMMITTED_DURABLE,
		"verified": status != WRITE_COMMITTED_RECOVERY_REQUIRED,
		"replayed": replayed,
		"recovery_required": status == WRITE_COMMITTED_RECOVERY_REQUIRED,
		"source": source,
		"recovered_backup": source == ProfileFileOperations.SLOT_BACKUP,
		"profile_id": envelope["profile_id"],
		"generation": envelope["generation"],
		"revision": envelope["revision"],
		"fingerprint": envelope["fingerprint"],
		"payload_checksum": envelope["payload_checksum"],
		"selection": selection,
		"backup_rotation": backup_rotation,
		"cleanup": cleanup,
		"directory_sync": directory_sync,
		"primary_replace": primary_replace,
	}


static func _load_failure(reason: StringName, details: Dictionary = {}) -> Dictionary:
	return _freeze({
		"ok": false,
		"status": LOAD_FAILED,
		"reason": reason,
		"recovered_backup": false,
		"details": details,
	}) as Dictionary


static func _freeze(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var frozen_dictionary: Dictionary = {}
			for key in value:
				frozen_dictionary[key] = _freeze(value[key])
			frozen_dictionary.make_read_only()
			return frozen_dictionary
		TYPE_ARRAY:
			var frozen_array: Array = []
			for child in value:
				frozen_array.append(_freeze(child))
			frozen_array.make_read_only()
			return frozen_array
		TYPE_PACKED_BYTE_ARRAY:
			return (value as PackedByteArray).duplicate()
	return value
