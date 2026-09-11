extends SceneTree
## Task 7.9 promoted contract: deterministic versioned envelopes, strict hostile
## input rejection, atomic-replacement state reporting, and backup recovery.

const Store = preload("res://game/profile/profile_store.gd")
const Codec = preload("res://game/profile/profile_canonical_codec.gd")
const FileOps = preload("res://game/profile/profile_file_operations.gd")
const GodotOps = preload("res://game/profile/godot_profile_file_operations.gd")

const PROFILE_ID: String = "zerkov.profile.contract_7_9"
const THREAD_TIMEOUT_MSEC: int = 5_000
const CONCURRENT_CONFIGURE_WORKERS: int = 8


class FakeFileOperations extends ProfileFileOperations:
	var label: String = ""
	var configured_profile: String = ""
	var slots: Dictionary = {}
	var unsafe_slots: Dictionary = {}
	var io_error_slots: Dictionary = {}
	var calls: Array[String] = []
	var failures_before: Dictionary = {}
	var failures_after: Dictionary = {}
	var corrupt_primary_after_replace: bool = false
	var durable_writes: bool = false
	var primary_replace_result_override: bool = false
	var primary_replace_ok: bool = true
	var primary_replace_committed: bool = true
	var directory_sync_supported: bool = false
	var directory_sync_ok: bool = false
	var configure_calls: int = 0

	func _init(p_label: String = "fake") -> void:
		label = p_label

	func configure(profile_id: String) -> Dictionary:
		configure_calls += 1
		if configured_profile.is_empty():
			configured_profile = profile_id
		if configured_profile != profile_id:
			return {"ok": false, "reason": &"fake_profile_changed"}
		return {"ok": true, "reason": &""}

	func lease_key() -> String:
		return "fake://%s/%s" % [label, configured_profile]

	func prepare() -> Dictionary:
		calls.append("prepare")
		return {"ok": true, "reason": &""}

	func read_slot(slot: StringName, maximum_bytes: int) -> Dictionary:
		calls.append("read:%s" % slot)
		if not ProfileFileOperations.is_known_slot(slot):
			return _read_result(false, STATE_ERROR, &"fake_unknown_slot")
		if unsafe_slots.has(slot):
			return _read_result(false, STATE_UNSAFE, &"fake_unsafe_slot")
		if io_error_slots.has(slot):
			return _read_result(false, STATE_ERROR, &"fake_io_error")
		if not slots.has(slot):
			return _read_result(true, STATE_MISSING, &"")
		var bytes := slots[slot] as PackedByteArray
		if bytes.size() > maximum_bytes:
			return _read_result(false, STATE_INVALID, &"profile_file_size_invalid")
		return {
			"ok": true,
			"state": STATE_REGULAR,
			"bytes": bytes.duplicate(),
			"reason": &"",
		}

	func write_temp(slot: StringName, bytes: PackedByteArray) -> Dictionary:
		var action := "write:%s" % slot
		calls.append(action)
		if not ProfileFileOperations.is_temp_slot(slot):
			return {"ok": false, "reason": &"fake_non_temp_write"}
		if _consume_failure(failures_before, action):
			return {"ok": false, "reason": &"injected_before_write"}
		slots[slot] = bytes.duplicate()
		if _consume_failure(failures_after, action):
			return {"ok": false, "reason": &"injected_after_write"}
		return {
			"ok": true,
			"flushed": true,
			"durable": durable_writes,
			"reason": &"",
		}

	func replace_slot(source_slot: StringName, destination_slot: StringName) -> Dictionary:
		var action := "replace:%s:%s" % [source_slot, destination_slot]
		calls.append(action)
		if _consume_failure(failures_before, action):
			return {"ok": false, "committed": false, "reason": &"injected_before_replace"}
		if not slots.has(source_slot):
			return {"ok": false, "committed": false, "reason": &"fake_source_missing"}
		var reported_ok := true
		var reported_committed := true
		if destination_slot == SLOT_PRIMARY and primary_replace_result_override:
			reported_ok = primary_replace_ok
			reported_committed = primary_replace_committed
		if not reported_committed:
			return {
				"ok": reported_ok,
				"committed": false,
				"reason": &"injected_primary_not_committed",
			}
		slots[destination_slot] = (slots[source_slot] as PackedByteArray).duplicate()
		slots.erase(source_slot)
		if destination_slot == SLOT_PRIMARY and corrupt_primary_after_replace:
			corrupt_primary_after_replace = false
			var corrupt := slots[destination_slot] as PackedByteArray
			if not corrupt.is_empty():
				corrupt[corrupt.size() - 1] ^= 0x01
			slots[destination_slot] = corrupt
		if _consume_failure(failures_after, action):
			return {"ok": false, "committed": true, "reason": &"injected_after_replace"}
		return {
			"ok": reported_ok,
			"committed": true,
			"reason": &"" if reported_ok else &"injected_primary_replace_error",
		}

	func remove_slot(slot: StringName) -> Dictionary:
		var action := "remove:%s" % slot
		calls.append(action)
		if _consume_failure(failures_before, action):
			return {"ok": false, "removed": false, "reason": &"injected_remove_failure"}
		if unsafe_slots.has(slot):
			return {"ok": false, "removed": false, "reason": &"fake_unsafe_slot"}
		var existed := slots.erase(slot)
		return {"ok": true, "removed": existed, "reason": &""}

	func sync_directory() -> Dictionary:
		calls.append("sync_directory")
		if _consume_failure(failures_before, "sync_directory"):
			return {"ok": false, "supported": true, "reason": &"injected_directory_sync_failure"}
		return {
			"ok": directory_sync_ok,
			"supported": directory_sync_supported,
			"reason": &"" if directory_sync_supported and directory_sync_ok \
				else &"directory_sync_unavailable",
		}

	func capabilities() -> Dictionary:
		return {
			"adapter": "fake",
			"same_directory_temps": true,
			"file_flush": true,
			"file_fsync_proven": durable_writes,
			"directory_sync": directory_sync_supported,
			"power_loss_durability_proven": durable_writes \
				and directory_sync_supported and directory_sync_ok,
			"interprocess_lock": false,
			"symlink_checks": true,
		}

	func fail_before(action: String) -> void:
		failures_before[action] = int(failures_before.get(action, 0)) + 1

	func fail_after(action: String) -> void:
		failures_after[action] = int(failures_after.get(action, 0)) + 1

	func _consume_failure(source: Dictionary, action: String) -> bool:
		var remaining := int(source.get(action, 0))
		if remaining <= 0:
			return false
		if remaining == 1:
			source.erase(action)
		else:
			source[action] = remaining - 1
		return true

	func _read_result(ok: bool, state: StringName, reason: StringName) -> Dictionary:
		return {"ok": ok, "state": state, "bytes": PackedByteArray(), "reason": reason}


class ThreadGate extends RefCounted:
	var _participants: int = 0
	var _mutex: Mutex = Mutex.new()
	var _semaphore: Semaphore = Semaphore.new()
	var _arrived: int = 0
	var _released: bool = false

	func _init(participants: int) -> void:
		_participants = participants

	func arrive_and_wait() -> void:
		_mutex.lock()
		_arrived += 1
		var already_released := _released
		_mutex.unlock()
		if not already_released:
			_semaphore.wait()

	func arrived_count() -> int:
		_mutex.lock()
		var result := _arrived
		_mutex.unlock()
		return result

	func release_all() -> void:
		_mutex.lock()
		if _released:
			_mutex.unlock()
			return
		_released = true
		_mutex.unlock()
		for _index in _participants:
			_semaphore.post()


class ThreadSafeFakeFileOperations extends FakeFileOperations:
	var lease_key_gate: ThreadGate
	var write_temp_gate: ThreadGate
	var _io_mutex: Mutex = Mutex.new()

	func configure(profile_id: String) -> Dictionary:
		_io_mutex.lock()
		var result := super.configure(profile_id)
		_io_mutex.unlock()
		return result

	func lease_key() -> String:
		var gate := lease_key_gate
		if gate != null:
			gate.arrive_and_wait()
		_io_mutex.lock()
		var result := super.lease_key()
		_io_mutex.unlock()
		return result

	func prepare() -> Dictionary:
		_io_mutex.lock()
		var result := super.prepare()
		_io_mutex.unlock()
		return result

	func read_slot(slot: StringName, maximum_bytes: int) -> Dictionary:
		_io_mutex.lock()
		var result := super.read_slot(slot, maximum_bytes)
		_io_mutex.unlock()
		return result

	func write_temp(slot: StringName, bytes: PackedByteArray) -> Dictionary:
		var gate := write_temp_gate
		if gate != null:
			gate.arrive_and_wait()
		_io_mutex.lock()
		var result := super.write_temp(slot, bytes)
		_io_mutex.unlock()
		return result

	func replace_slot(source_slot: StringName, destination_slot: StringName) -> Dictionary:
		_io_mutex.lock()
		var result := super.replace_slot(source_slot, destination_slot)
		_io_mutex.unlock()
		return result

	func remove_slot(slot: StringName) -> Dictionary:
		_io_mutex.lock()
		var result := super.remove_slot(slot)
		_io_mutex.unlock()
		return result

	func sync_directory() -> Dictionary:
		_io_mutex.lock()
		var result := super.sync_directory()
		_io_mutex.unlock()
		return result

	func capabilities() -> Dictionary:
		_io_mutex.lock()
		var result := super.capabilities()
		_io_mutex.unlock()
		return result


var checks: int = 0
var failures: int = 0
var host_capabilities: Dictionary = {}


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("PROFILE_STORE_CONTRACT: " + message)


func run() -> void:
	_test_canonical_codec()
	_test_identity_and_writer_boundary()
	_test_public_result_immutability()
	_test_unsupported_format_blocks_downgrade()
	_test_concurrent_lease_and_operation_admission()
	_test_initial_save_load_replay_and_rotation()
	_test_validation_and_recovery_precedence()
	_test_preserve_recovered_backup()
	_test_injected_failures()
	_test_payload_bounds()
	_test_real_symlink_rejection()
	_test_real_filesystem_restart()
	print("PROFILE_STORE_HOST filesystem=%s replace=%s file_flush=%s file_fsync_proven=%s directory_sync=%s interprocess_lock=%s lease_thread_safe=%s operation_admission_thread_safe=%s" % [
		host_capabilities.get("filesystem_type", "unknown"),
		host_capabilities.get("replace_primitive", "unknown"),
		host_capabilities.get("file_flush", false),
		host_capabilities.get("file_fsync_proven", false),
		host_capabilities.get("directory_sync", false),
		host_capabilities.get("interprocess_lock", false),
		host_capabilities.get("in_process_lease_thread_safe", false),
		host_capabilities.get("per_store_operation_admission_thread_safe", false),
	])
	print("PROFILE_STORE_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _test_canonical_codec() -> void:
	var left := {"z": 3, "a": [true, null, "é"], "blob": PackedByteArray([0, 255, 3])}
	var right: Dictionary = {}
	right["blob"] = PackedByteArray([0, 255, 3])
	right["a"] = [true, null, "é"]
	right["z"] = 3
	var left_encoded := Codec.encode(left)
	var right_encoded := Codec.encode(right)
	check(bool(left_encoded.get("ok", false)), "canonical codec accepts bounded values")
	check((left_encoded.get("bytes", PackedByteArray()) as PackedByteArray) \
		== (right_encoded.get("bytes", PackedByteArray()) as PackedByteArray),
		"dictionary insertion order does not change canonical bytes")
	var decoded := Codec.decode(left_encoded.get("bytes", PackedByteArray()))
	check(bool(decoded.get("ok", false)) and decoded.get("value") == left,
		"canonical bytes decode without type coercion")
	var unicode_keys := {"é": 1, "e": 2, "😀": 3}
	var unicode_encoded := Codec.encode(unicode_keys)
	check(bool(unicode_encoded.get("ok", false)) \
		and Codec.decode(unicode_encoded["bytes"]).get("value") == unicode_keys,
		"valid UTF-8 strings and dictionary keys round-trip canonically")
	check(not bool(Codec.decode(
		(left_encoded["bytes"] as PackedByteArray) + PackedByteArray([0])).get("ok", true)),
		"trailing bytes are rejected")
	check(Codec.decode("d2:{s1:ai1;s1:ai2;}".to_utf8_buffer()).get("reason", &"") \
		== &"duplicate_dictionary_key", "duplicate dictionary keys are rejected")
	check(Codec.decode("d2:{s1:bi1;s1:ai2;}".to_utf8_buffer()).get("reason", &"") \
		== &"dictionary_key_order_invalid", "noncanonical dictionary key order is rejected")
	check(Codec.decode("i01;".to_utf8_buffer()).get("reason", &"") \
		== &"integer_encoding_invalid", "noncanonical integer spelling is rejected")
	check(not bool(Codec.decode(PackedByteArray([0x73, 0x31, 0x3a, 0xff])).get("ok", true)),
		"invalid UTF-8 is rejected")
	check(not bool(Codec.encode(1.25).get("ok", true)), "floating point values are rejected")
	check(not bool(Codec.encode(NAN).get("ok", true)), "NaN is rejected")
	check(not bool(Codec.encode(INF).get("ok", true)), "infinity is rejected")
	check(not bool(Codec.encode(Codec.MAX_ABS_INTEGER + 1).get("ok", true)),
		"integers beyond the declared bound are rejected")
	check(not bool(Codec.encode("x".repeat(Codec.MAX_STRING_BYTES + 1)).get("ok", true)),
		"oversized strings are rejected")
	var oversized_blob := PackedByteArray()
	oversized_blob.resize(Codec.MAX_BLOB_BYTES + 1)
	check(Codec.encode(oversized_blob).get("reason", &"") == &"blob_too_large",
		"opaque byte arrays have an explicit size bound")
	var empty_bytes_encoded := Codec.encode(PackedByteArray())
	check(bool(empty_bytes_encoded.get("ok", false)) \
		and typeof(Codec.decode(empty_bytes_encoded["bytes"]).get("value")) \
		== TYPE_PACKED_BYTE_ARRAY,
		"empty byte arrays have one accepted typed representation")
	var too_many: Array = []
	for index in Codec.MAX_COLLECTION_COUNT + 1:
		too_many.append(index)
	check(Codec.encode(too_many).get("reason", &"") == &"collection_too_large",
		"collection count is bounded")
	var deep: Variant = "leaf"
	for _index in Codec.MAX_DEPTH + 2:
		deep = [deep]
	check(Codec.encode(deep).get("reason", &"") == &"depth_limit_exceeded",
		"nesting depth is bounded")
	var node_heavy: Array = []
	for outer in Codec.MAX_COLLECTION_COUNT:
		var children: Array = []
		for inner in 16:
			children.append(outer * 16 + inner)
		node_heavy.append(children)
	check(Codec.encode(node_heavy).get("reason", &"") == &"node_limit_exceeded",
		"aggregate decoded/encoded node work is bounded independently of depth")


func _test_identity_and_writer_boundary() -> void:
	for invalid_id in [
		"", "local", "zerkov.profile", "zerkov.profile../escape",
		"zerkov.profile.local/path", "zerkov.profile.Local", "zerkov.profile.ümlaut",
	]:
		var rejected_ops := FakeFileOperations.new("invalid_" + str(checks))
		var rejected_store := Store.new()
		check(not rejected_store.configure_with_trusted_operations(invalid_id, rejected_ops),
			"invalid/traversal profile identity is rejected: " + invalid_id)
		check(rejected_ops.configure_calls == 0,
			"invalid identity reaches no file-operation configuration")
	var retry_ops := FakeFileOperations.new("invalid_retry")
	var retry_store := Store.new()
	check(not retry_store.configure_with_trusted_operations("zerkov.profile.Bad", retry_ops),
		"invalid configuration fails before adapter setup")
	check(retry_store.configure_with_trusted_operations(PROFILE_ID, retry_ops),
		"configuration admission is released after validation failure")
	check(retry_store.close(), "validation-retry store releases its lease")

	var ops := FakeFileOperations.new("lease")
	var first := Store.new()
	var second := Store.new()
	check(first.configure_with_trusted_operations(PROFILE_ID, ops),
		"first offline writer acquires the in-process lease")
	check(not second.configure_with_trusted_operations(PROFILE_ID, ops) \
		and second.last_error == &"single_writer_lease_held",
		"second writer for the exact storage identity is rejected")
	first.close()
	check(second.configure_with_trusted_operations(PROFILE_ID, ops),
		"explicit close releases the in-process writer lease")
	second.close()
	check(ops.calls.all(func(call: String) -> bool:
		return call == "prepare" or call.begins_with("read:") \
			or call.begins_with("write:") or call.begins_with("replace:") \
			or call.begins_with("remove:") or call == "sync_directory"),
		"the store seam is slot-based and receives no caller path")


func _test_public_result_immutability() -> void:
	var unconfigured := Store.new()
	var capabilities := unconfigured.storage_capabilities()
	check(capabilities.is_empty() and _is_recursively_read_only(capabilities),
		"unconfigured storage capabilities return a read-only empty dictionary")
	var load_admission := unconfigured.load_profile()
	check(load_admission.get("reason", &"") == &"profile_store_not_configured" \
		and _is_recursively_read_only(load_admission),
		"unconfigured load admission failure is recursively read-only")
	var save_admission := unconfigured.save_profile(_payload(1), 0, 1)
	check(save_admission.get("reason", &"") == &"profile_store_not_configured" \
		and _is_recursively_read_only(save_admission),
		"unconfigured save admission failure is recursively read-only")

	var ops := FakeFileOperations.new("immutable_failures")
	var store := _open_store(ops)
	var before_calls := ops.calls.size()
	var lineage_failure := store.save_profile(_payload(1), 0, 2)
	check(lineage_failure.get("reason", &"") \
		== &"generation_revision_lineage_invalid" \
		and _is_recursively_read_only(lineage_failure),
		"pre-selection lineage failure is recursively read-only")
	check(ops.calls.size() == before_calls,
		"invalid requested lineage reaches no storage selection or mutation")
	var missing := store.load_profile()
	check(missing.get("reason", &"") == &"profile_missing" \
		and _is_recursively_read_only(missing),
		"missing-profile failure and nested diagnostics are recursively read-only")
	var configured_capabilities := store.storage_capabilities()
	check(_is_recursively_read_only(configured_capabilities),
		"configured storage capabilities are recursively read-only")
	check(store.close(), "immutability probe releases its lease")


func _test_unsupported_format_blocks_downgrade() -> void:
	var fixture := _two_generation_fixture("unsupported_format_source")
	var fixture_ops := fixture["ops"] as FakeFileOperations
	var supported_two := (fixture_ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) \
		.duplicate()
	var supported_one := (fixture_ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray) \
		.duplicate()
	(fixture["store"] as ProfileStore).close()

	var cases: Array[Dictionary] = [
		{
			"label": "version",
			"reason": &"envelope_version_unsupported",
			"mutation": func(envelope: Dictionary) -> void:
				envelope["version"] = Store.ENVELOPE_VERSION + 1
				envelope["future_header_extension"] = "preserve-me",
		},
		{
			"label": "schema",
			"reason": &"envelope_schema_unsupported",
			"mutation": func(envelope: Dictionary) -> void:
				envelope["schema"] = "zerkov.profile.envelope.future",
		},
		{
			"label": "codec",
			"reason": &"envelope_codec_unsupported",
			"mutation": func(envelope: Dictionary) -> void:
				envelope["codec"] = "zerkov.profile.canonical-value.v2",
		},
	]
	for case in cases:
		var mutation: Callable = case["mutation"]
		var unsupported_bytes := _mutate_envelope_and_recompute_fingerprint(
			supported_two, mutation)
		for unsupported_slot in [FileOps.SLOT_PRIMARY, FileOps.SLOT_BACKUP]:
			var label := "unsupported_%s_%s" % [case["label"], unsupported_slot]
			var primary_bytes := unsupported_bytes \
				if unsupported_slot == FileOps.SLOT_PRIMARY else supported_one
			var backup_bytes := unsupported_bytes \
				if unsupported_slot == FileOps.SLOT_BACKUP else supported_one
			var ops := _ops_with(label, primary_bytes, backup_bytes)
			var store := _open_store(ops)
			ops.slots[FileOps.SLOT_WRITE_TEMP] = PackedByteArray([0xa1, 0x01])
			ops.slots[FileOps.SLOT_BACKUP_TEMP] = PackedByteArray([0xb2, 0x02])
			var original_primary := (ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) \
				.duplicate()
			var original_backup := (ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray) \
				.duplicate()
			var original_write_temp := (ops.slots[FileOps.SLOT_WRITE_TEMP] as PackedByteArray) \
				.duplicate()
			var original_backup_temp := (ops.slots[FileOps.SLOT_BACKUP_TEMP] as PackedByteArray) \
				.duplicate()
			ops.calls.clear()

			var load_result := store.load_profile()
			check(not bool(load_result.get("ok", true)) \
				and load_result.get("status", &"") \
					== Store.LOAD_BLOCKED_UNSUPPORTED_FORMAT \
				and load_result.get("reason", &"") == Store.PROFILE_FORMAT_UNSUPPORTED \
				and bool(load_result.get("unsupported_format", false)) \
				and bool(load_result.get("migration_required", false)) \
				and not bool(load_result.get("recovered_backup", true)),
				"recognized unsupported %s in %s blocks load instead of fallback" \
				% [case["label"], unsupported_slot])
			var details := load_result.get("details", {}) as Dictionary
			var candidate_key := "primary" \
				if unsupported_slot == FileOps.SLOT_PRIMARY else "backup"
			var unsupported_candidate := details.get(candidate_key, {}) as Dictionary
			check(unsupported_candidate.get("state", &"") == &"unsupported" \
				and unsupported_candidate.get("reason", &"") == case["reason"],
				"blocked load identifies the unsupported %s header in %s" \
				% [case["label"], unsupported_slot])
			check(_is_recursively_read_only(load_result),
				"blocked unsupported load receipt is recursively read-only: " + label)

			var save_result := store.save_profile(
				_payload(222, PackedByteArray([2, 2, 2])), 1, 2)
			check(_is_unsupported_write_result(save_result),
				"unsupported %s in %s blocks a next-generation save" \
				% [case["label"], unsupported_slot])
			check(_is_recursively_read_only(save_result),
				"blocked unsupported save receipt is recursively read-only: " + label)

			var replay_result := store.save_profile(
				_payload(100, PackedByteArray([1])), 0, 1)
			check(_is_unsupported_write_result(replay_result),
				"unsupported %s in %s blocks replay of the older valid copy" \
				% [case["label"], unsupported_slot])
			check(_is_recursively_read_only(replay_result),
				"blocked unsupported replay receipt is recursively read-only: " + label)

			check((ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) == original_primary \
				and (ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray) == original_backup \
				and (ops.slots[FileOps.SLOT_WRITE_TEMP] as PackedByteArray) \
					== original_write_temp \
				and (ops.slots[FileOps.SLOT_BACKUP_TEMP] as PackedByteArray) \
					== original_backup_temp,
				"blocked unsupported operations preserve all four slots byte-for-byte: " \
				+ label)
			check(ops.calls.size() == 6 and ops.calls.all(func(call: String) -> bool:
				return call.begins_with("read:")),
				"blocked unsupported load/save/replay perform only six independent reads: " \
				+ label)
			check(store.close(), "unsupported-format store releases its lease: " + label)

	# The barrier has no hidden latch. Once an external future migration replaces
	# the unsupported bytes with a malformed current-format copy, ordinary
	# supported-version backup recovery and saving work exactly as before.
	var migrated_ops := _ops_with(
		"unsupported_then_migrated",
		_mutate_envelope_and_recompute_fingerprint(
			supported_two, func(envelope: Dictionary) -> void:
				envelope["version"] = Store.ENVELOPE_VERSION + 1),
		supported_one)
	var migrated_store := _open_store(migrated_ops)
	var initially_blocked := migrated_store.load_profile()
	check(initially_blocked.get("status", &"") \
		== Store.LOAD_BLOCKED_UNSUPPORTED_FORMAT,
		"future-format copy initially blocks the migration fixture")
	migrated_ops.slots[FileOps.SLOT_PRIMARY] = _mutate_envelope(
		supported_two, func(envelope: Dictionary) -> void:
			envelope["unexpected_current_field"] = true)
	var recovered := migrated_store.load_profile()
	check(bool(recovered.get("ok", false)) \
		and recovered.get("status", &"") == Store.LOAD_RECOVERED_BACKUP \
		and int(recovered.get("generation", 0)) == 1 \
		and (recovered.get("primary_validation", {}) as Dictionary) \
			.get("reason", &"") == &"envelope_fields_invalid",
		"externally migrated current-format corruption still recovers the valid backup")
	var resumed_save := migrated_store.save_profile(
		_payload(130, PackedByteArray([7, 8])), 1, 2)
	check(bool(resumed_save.get("committed", false)) \
		and int(resumed_save.get("generation", 0)) == 2,
		"normal supported-version saving resumes after external migration")
	check(migrated_store.close(), "post-migration recovery store releases its lease")


func _is_unsupported_write_result(result: Dictionary) -> bool:
	return not bool(result.get("ok", true)) \
		and result.get("status", &"") == Store.WRITE_BLOCKED_UNSUPPORTED_FORMAT \
		and result.get("reason", &"") == Store.PROFILE_FORMAT_UNSUPPORTED \
		and bool(result.get("unsupported_format", false)) \
		and bool(result.get("migration_required", false)) \
		and not bool(result.get("committed", true)) \
		and not bool(result.get("write_performed", true)) \
		and not bool(result.get("replayed", true))


func _test_concurrent_lease_and_operation_admission() -> void:
	_test_concurrent_configure_lease()
	_test_concurrent_same_store_save()
	_test_close_during_save_preserves_lease()


func _test_concurrent_configure_lease() -> void:
	var gate := ThreadGate.new(CONCURRENT_CONFIGURE_WORKERS)
	var stores: Array[ProfileStore] = []
	var operations: Array[ThreadSafeFakeFileOperations] = []
	var threads: Array[Thread] = []
	var started: Array[bool] = []
	var all_started := true
	for index in CONCURRENT_CONFIGURE_WORKERS:
		var store := Store.new()
		var ops := ThreadSafeFakeFileOperations.new("concurrent_configure")
		ops.lease_key_gate = gate
		var thread := Thread.new()
		var start_error := thread.start(Callable(self, "_thread_configure").bind(store, ops))
		stores.append(store)
		operations.append(ops)
		threads.append(thread)
		started.append(start_error == OK)
		all_started = start_error == OK and all_started
	check(all_started, "all synchronized configure workers start")
	var all_arrived := _wait_for_gate(gate, CONCURRENT_CONFIGURE_WORKERS)
	check(all_arrived, "all configure workers rendezvous before lease acquisition")
	gate.release_all()
	var joined := _bounded_join(threads, started)
	check(bool(joined.get("complete", false)), "concurrent configure workers join without deadlock")

	var results := joined.get("results", []) as Array
	var success_count := 0
	var winner_index := -1
	var losers_are_explicit := true
	if bool(joined.get("complete", false)):
		for index in results.size():
			if bool(results[index]):
				success_count += 1
				winner_index = index
			elif started[index]:
				losers_are_explicit = stores[index].last_error \
					== &"single_writer_lease_held" and losers_are_explicit
	check(success_count == 1, "one synchronized configure acquires the shared lease")
	check(losers_are_explicit, "all concurrent configure losers report the held lease")
	check(winner_index >= 0 and stores[winner_index].is_configured(),
		"the sole configure winner retains its lease after worker teardown")
	for ops in operations:
		ops.lease_key_gate = null
	if winner_index >= 0:
		check(stores[winner_index].close(), "the configure winner releases its lease atomically")
	else:
		check(false, "a configure winner exists for release")
	for index in stores.size():
		if index != winner_index:
			stores[index].close()
	var successor_ops := ThreadSafeFakeFileOperations.new("concurrent_configure")
	var successor := Store.new()
	check(successor.configure_with_trusted_operations(PROFILE_ID, successor_ops),
		"a successor acquires the lease after the sole winner closes")
	check(successor.close(), "the successor releases the reacquired lease")


func _test_concurrent_same_store_save() -> void:
	var ops := ThreadSafeFakeFileOperations.new("concurrent_save")
	var store := Store.new()
	check(store.configure_with_trusted_operations(PROFILE_ID, ops),
		"concurrent-save store configures")
	var lease_gate := ThreadGate.new(2)
	var write_gate := ThreadGate.new(2)
	ops.lease_key_gate = lease_gate
	ops.write_temp_gate = write_gate
	var first_thread := Thread.new()
	var second_thread := Thread.new()
	var first_start := first_thread.start(Callable(self, "_thread_save").bind(
		store, _payload(501, PackedByteArray([5, 0, 1]))))
	var second_start := second_thread.start(Callable(self, "_thread_save").bind(
		store, _payload(501, PackedByteArray([5, 0, 1]))))
	var threads: Array[Thread] = [first_thread, second_thread]
	var started: Array[bool] = [first_start == OK, second_start == OK]
	check(first_start == OK and second_start == OK, "both concurrent save workers start")
	var both_admission_callbacks := _wait_for_gate(lease_gate, 2)
	check(both_admission_callbacks,
		"both saves rendezvous outside the operation-admission critical section")
	check(store.is_configured(),
		"lease-key callbacks execute without holding the lease/state mutexes")
	lease_gate.release_all()
	var winner_reached_storage := _wait_for_gate(write_gate, 1)
	check(winner_reached_storage, "the admitted save reaches candidate storage")
	var loser_finished_while_winner_blocked := _wait_for_live_count(threads, started, 1)
	check(loser_finished_while_winner_blocked,
		"the second save is rejected while the admitted save remains blocked")
	write_gate.release_all()
	var joined := _bounded_join(threads, started)
	ops.lease_key_gate = null
	ops.write_temp_gate = null
	check(bool(joined.get("complete", false)), "concurrent save workers join without deadlock")
	var committed_count := 0
	var rejected_count := 0
	var rejected_receipt_frozen := true
	for value in joined.get("results", []) as Array:
		if value is Dictionary and bool((value as Dictionary).get("committed", false)):
			committed_count += 1
		elif value is Dictionary \
				and (value as Dictionary).get("reason", &"") \
				== &"profile_store_reentrant_operation":
			rejected_count += 1
			rejected_receipt_frozen = _is_recursively_read_only(value) \
				and rejected_receipt_frozen
	check(committed_count == 1, "exactly one concurrent save commits")
	check(rejected_count == 1, "exactly one concurrent save is rejected at admission")
	check(rejected_receipt_frozen,
		"the concurrent-save admission loser receives a recursively read-only receipt")
	var loaded := store.load_profile()
	check(bool(loaded.get("ok", false)) and int(loaded.get("generation", 0)) == 1 \
		and (loaded.get("payload", {}) as Dictionary) \
		== _payload(501, PackedByteArray([5, 0, 1])),
		"concurrent admission leaves one exact committed generation")
	check(store.is_configured(), "concurrent save completion does not lose the writer lease")
	check(store.close(), "concurrent-save store closes after both workers finish")
	var successor := Store.new()
	var successor_ops := ThreadSafeFakeFileOperations.new("concurrent_save")
	check(successor.configure_with_trusted_operations(PROFILE_ID, successor_ops),
		"save-successor store reacquires the released lease")
	check(successor.close(), "save-successor store releases its lease")


func _test_close_during_save_preserves_lease() -> void:
	var ops := ThreadSafeFakeFileOperations.new("close_during_save")
	var store := Store.new()
	check(store.configure_with_trusted_operations(PROFILE_ID, ops),
		"close-race store configures")
	var write_gate := ThreadGate.new(1)
	ops.write_temp_gate = write_gate
	var save_thread := Thread.new()
	var start_error := save_thread.start(Callable(self, "_thread_save").bind(
		store, _payload(777, PackedByteArray([7, 7, 7]))))
	var threads: Array[Thread] = [save_thread]
	var started: Array[bool] = [start_error == OK]
	check(start_error == OK, "close-race save worker starts")
	check(_wait_for_gate(write_gate, 1), "close-race save blocks inside test storage")
	check(not store.close() and store.last_error == &"profile_store_operation_active",
		"close refuses to release a lease while a save is active")
	check(store.is_configured(), "failed concurrent close leaves the original store configured")
	var contender_ops := ThreadSafeFakeFileOperations.new("close_during_save")
	var contender := Store.new()
	check(not contender.configure_with_trusted_operations(PROFILE_ID, contender_ops) \
		and contender.last_error == &"single_writer_lease_held",
		"another writer cannot enter while close is refused")
	write_gate.release_all()
	var joined := _bounded_join(threads, started)
	ops.write_temp_gate = null
	check(bool(joined.get("complete", false)), "close-race save joins without deadlock")
	var save_results := joined.get("results", []) as Array
	check(save_results.size() == 1 and save_results[0] is Dictionary \
		and bool((save_results[0] as Dictionary).get("committed", false)),
		"the protected in-flight save commits normally")
	check(store.close(), "close succeeds after the admitted save finishes")
	check(contender.configure_with_trusted_operations(PROFILE_ID, contender_ops),
		"the previously rejected contender acquires the released lease")
	check(contender.close(), "the close-race contender releases its lease")


func _test_initial_save_load_replay_and_rotation() -> void:
	var ops := FakeFileOperations.new("basic")
	var store := Store.new()
	check(store.configure_with_trusted_operations(PROFILE_ID, ops), "basic store configures")
	var missing := store.load_profile()
	check(not bool(missing.get("ok", true)) and missing.get("reason", &"") == &"profile_missing",
		"both missing copies fail closed without inventing defaults")
	var payload_one := _payload(100, PackedByteArray([1, 2, 3]))
	var initial := store.save_profile(payload_one, 0, 1)
	check(bool(initial.get("ok", false)) and bool(initial.get("committed", false)) \
		and initial.get("status", &"") == Store.WRITE_COMMITTED_DURABILITY_UNCERTAIN,
		"production-like seam reports verified commit with uncertain durability")
	check(ops.slots.has(FileOps.SLOT_PRIMARY) and not ops.slots.has(FileOps.SLOT_BACKUP),
		"initial commit installs primary without inventing a backup generation")
	check(not ops.slots.has(FileOps.SLOT_WRITE_TEMP) \
		and not ops.slots.has(FileOps.SLOT_BACKUP_TEMP),
		"successful initial commit leaves no temporary files")
	var loaded := store.load_profile()
	check(bool(loaded.get("ok", false)) and loaded.get("status", &"") == Store.LOAD_PRIMARY,
		"valid primary loads")
	check(loaded.get("payload") == payload_one and int(loaded.get("generation", 0)) == 1 \
		and int(loaded.get("revision", 0)) == 1,
		"load preserves exact payload types, generation, and revision")
	check(Codec.is_sha256(loaded.get("payload_checksum")) \
		and Codec.is_sha256(loaded.get("fingerprint")) \
		and loaded.get("payload_checksum") != loaded.get("fingerprint"),
		"payload checksum and envelope fingerprint are separate domain digests")
	var returned_project := (loaded["payload"] as Dictionary)["project"] as Dictionary
	check(returned_project.is_read_only(), "loaded project dictionary is read-only")

	var calls_before_replay := ops.calls.size()
	var replay := store.save_profile(payload_one, 0, 1)
	check(bool(replay.get("ok", false)) and bool(replay.get("replayed", false)) \
		and bool(replay.get("committed", false)) and not bool(replay.get("write_performed", true)) \
		and replay.get("status", &"") == Store.WRITE_REPLAYED,
		"exact write replay returns committed truth without performing another write")
	check(ops.calls.size() == calls_before_replay + 2,
		"exact replay performs only independent primary/backup reads and no write")
	var conflict := store.save_profile(_payload(101, PackedByteArray([1, 2, 3])), 0, 1)
	check(not bool(conflict.get("ok", true)) \
		and conflict.get("reason", &"") == &"generation_replay_conflict",
		"divergent replay at an already committed generation is rejected")
	check(not bool(store.save_profile(_payload(200), 1, 3).get("ok", true)),
		"revision jumps are rejected")

	var primary_generation_one := (ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray).duplicate()
	var payload_two := _payload(125, PackedByteArray([4, 5]))
	var second := store.save_profile(payload_two, 1, 2)
	check(bool(second.get("ok", false)) and bool(second.get("committed", false)),
		"next generation commits")
	check((ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray) == primary_generation_one,
		"backup policy retains the exact previously validated primary generation")
	var loaded_two := store.load_profile()
	check(int(loaded_two.get("generation", 0)) == 2 \
		and loaded_two.get("payload") == payload_two,
		"higher valid primary generation wins over older backup")
	var stale := store.save_profile(_payload(140), 0, 1)
	check(not bool(stale.get("ok", true)) and stale.get("reason", &"") == &"stale_generation",
		"a generation behind the committed profile is rejected")

	var canonical_primary := (ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray).duplicate()
	store.close()
	var deterministic_ops := FakeFileOperations.new("deterministic")
	var deterministic_store := Store.new()
	check(deterministic_store.configure_with_trusted_operations(PROFILE_ID, deterministic_ops),
		"independent deterministic store configures")
	check(bool(deterministic_store.save_profile(payload_one, 0, 1).get("committed", false)),
		"independent first generation commits")
	check(bool(deterministic_store.save_profile(payload_two, 1, 2).get("committed", false)),
		"independent second generation commits")
	check((deterministic_ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) == canonical_primary,
		"same identity, payload, generation, and revision produce byte-identical envelope")
	deterministic_store.close()


func _test_validation_and_recovery_precedence() -> void:
	var base := _two_generation_fixture("tamper_base")
	var base_ops := base["ops"] as FakeFileOperations
	var primary_two := (base_ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray).duplicate()
	var backup_one := (base_ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray).duplicate()
	(base["store"] as ProfileStore).close()

	var checksum_ops := _ops_with("checksum", _tamper_payload_without_digests(primary_two), backup_one)
	var checksum_store := _open_store(checksum_ops)
	var checksum_load := checksum_store.load_profile()
	check(bool(checksum_load.get("ok", false)) and bool(checksum_load.get("recovered_backup", false)),
		"payload tamper recovers the independently valid backup")
	check(((checksum_load["primary_validation"] as Dictionary).get("reason", &"")) \
		== &"payload_checksum_mismatch", "payload checksum detects payload tamper first")
	checksum_store.close()

	var fingerprint_ops := _ops_with(
		"fingerprint", _tamper_metadata_without_fingerprint(primary_two), backup_one)
	var fingerprint_store := _open_store(fingerprint_ops)
	var fingerprint_load := fingerprint_store.load_profile()
	check(bool(fingerprint_load.get("recovered_backup", false)) \
		and ((fingerprint_load["primary_validation"] as Dictionary).get("reason", &"")) \
		== &"envelope_fingerprint_mismatch",
		"envelope fingerprint independently detects metadata tamper")
	fingerprint_store.close()

	var fingerprint_value := _mutate_envelope(primary_two, func(envelope: Dictionary) -> void:
		envelope["fingerprint"] = "0".repeat(64))
	var fingerprint_value_ops := _ops_with(
		"fingerprint_value", fingerprint_value, backup_one)
	var fingerprint_value_store := _open_store(fingerprint_value_ops)
	var fingerprint_value_load := fingerprint_value_store.load_profile()
	check(bool(fingerprint_value_load.get("recovered_backup", false)) \
		and ((fingerprint_value_load["primary_validation"] as Dictionary).get("reason", &"")) \
		== &"envelope_fingerprint_mismatch",
		"forged fingerprint value is rejected")
	fingerprint_value_store.close()

	var truncated_ops := _ops_with(
		"truncated", primary_two.slice(0, primary_two.size() - 1), backup_one)
	var truncated_store := _open_store(truncated_ops)
	check(bool(truncated_store.load_profile().get("recovered_backup", false)),
		"truncated primary recovers backup")
	truncated_store.close()

	var primary_good_ops := _ops_with("good_primary", primary_two, PackedByteArray([0xff, 0x00]))
	var primary_good_store := _open_store(primary_good_ops)
	var primary_good := primary_good_store.load_profile()
	check(bool(primary_good.get("ok", false)) and not bool(primary_good.get("recovered_backup", true)) \
		and int(primary_good.get("generation", 0)) == 2,
		"good primary remains authoritative when backup is corrupt")
	primary_good_store.close()

	var missing_primary_ops := _ops_with("missing_primary", PackedByteArray(), backup_one, false)
	var missing_primary_store := _open_store(missing_primary_ops)
	check(bool(missing_primary_store.load_profile().get("recovered_backup", false)),
		"missing primary deterministically recovers valid backup")
	missing_primary_store.close()

	var both_bad_ops := _ops_with("both_bad", PackedByteArray([0xff]), PackedByteArray([0xfe]))
	var both_bad_store := _open_store(both_bad_ops)
	var both_bad := both_bad_store.load_profile()
	check(not bool(both_bad.get("ok", true)) and both_bad.get("reason", &"") == &"profile_unreadable",
		"two corrupt copies fail closed")
	both_bad_store.close()

	var oversized_file := PackedByteArray()
	oversized_file.resize(Store.MAX_PROFILE_FILE_BYTES + 1)
	var oversized_ops := _ops_with("oversized_primary", oversized_file, backup_one)
	var oversized_store := _open_store(oversized_ops)
	var oversized_load := oversized_store.load_profile()
	check(bool(oversized_load.get("recovered_backup", false)) \
		and ((oversized_load["primary_validation"] as Dictionary).get("reason", &"")) \
		== &"profile_file_size_invalid",
		"oversized regular primary is invalid and recovers bounded backup without allocation")
	oversized_store.close()

	var both_missing_ops := FakeFileOperations.new("both_missing")
	var both_missing_store := _open_store(both_missing_ops)
	check(both_missing_store.load_profile().get("reason", &"") == &"profile_missing",
		"two missing copies remain distinct from corruption")
	both_missing_store.close()

	var newer_backup_ops := _ops_with("newer_backup", backup_one, primary_two)
	var newer_backup_store := _open_store(newer_backup_ops)
	var newer_backup := newer_backup_store.load_profile()
	check(bool(newer_backup.get("recovered_backup", false)) \
		and int(newer_backup.get("generation", 0)) == 2,
		"higher valid backup generation deterministically wins over stale primary")
	newer_backup_store.close()

	var invalid_newer_primary := _mutate_envelope_and_recompute_fingerprint(
		primary_two, func(envelope: Dictionary) -> void:
			envelope["generation"] = 3
			envelope["revision"] = 2)
	var invalid_primary_ops := _ops_with(
		"invalid_newer_primary", invalid_newer_primary, backup_one)
	var invalid_primary_store := _open_store(invalid_primary_ops)
	var invalid_primary_load := invalid_primary_store.load_profile()
	check(bool(invalid_primary_load.get("recovered_backup", false)) \
		and int(invalid_primary_load.get("generation", 0)) == 1 \
		and (invalid_primary_load.get("primary_validation", {}) as Dictionary) \
			.get("reason", &"") == &"generation_revision_lineage_invalid",
		"re-signed mismatched newer primary is invalid before backup selection")
	invalid_primary_store.close()

	var invalid_newer_backup := _mutate_envelope_and_recompute_fingerprint(
		primary_two, func(envelope: Dictionary) -> void:
			envelope["generation"] = 4
			envelope["revision"] = 3)
	var invalid_backup_ops := _ops_with(
		"invalid_newer_backup", primary_two, invalid_newer_backup)
	var invalid_backup_store := _open_store(invalid_backup_ops)
	var invalid_backup_load := invalid_backup_store.load_profile()
	check(bool(invalid_backup_load.get("ok", false)) \
		and not bool(invalid_backup_load.get("recovered_backup", true)) \
		and int(invalid_backup_load.get("generation", 0)) == 2 \
		and (invalid_backup_load.get("backup_validation", {}) as Dictionary) \
			.get("reason", &"") == &"generation_revision_lineage_invalid",
		"re-signed mismatched newer backup cannot outrank a valid primary")
	invalid_backup_store.close()

	var divergent_bytes := _single_generation_bytes(
		"divergent_source", _payload(999, PackedByteArray([9])))
	var divergent_ops := _ops_with("divergent", backup_one, divergent_bytes)
	var divergent_store := _open_store(divergent_ops)
	var divergent := divergent_store.load_profile()
	check(not bool(divergent.get("ok", true)) \
		and divergent.get("reason", &"") == &"equal_generation_divergence",
		"equal-generation divergent valid envelopes fail closed")
	divergent_store.close()

	var unsafe_ops := _ops_with("unsafe", primary_two, backup_one)
	unsafe_ops.unsafe_slots[FileOps.SLOT_PRIMARY] = true
	var unsafe_store := _open_store(unsafe_ops)
	check(unsafe_store.load_profile().get("reason", &"") == &"storage_unsafe_or_unreadable",
		"symlink/reparse-like primary state fails closed even with good backup")
	unsafe_store.close()

	var unknown_field := _mutate_envelope(primary_two, func(envelope: Dictionary) -> void:
		envelope["unknown"] = 1)
	var malformed_type := _mutate_envelope(primary_two, func(envelope: Dictionary) -> void:
		envelope["generation"] = "2")
	var wrong_identity := _mutate_envelope(primary_two, func(envelope: Dictionary) -> void:
		envelope["profile_id"] = "zerkov.profile.other")
	for case in [
		{"label": "unknown", "bytes": unknown_field, "reason": &"envelope_fields_invalid"},
		{"label": "type", "bytes": malformed_type, "reason": &"envelope_field_type_invalid"},
		{"label": "identity", "bytes": wrong_identity, "reason": &"profile_identity_mismatch"},
	]:
		var case_ops := _ops_with(String(case["label"]), case["bytes"], PackedByteArray())
		var case_store := _open_store(case_ops)
		var case_load := case_store.load_profile()
		var details := case_load.get("details", {}) as Dictionary
		var primary_validation := details.get("primary", {}) as Dictionary
		check(not bool(case_load.get("ok", true)) \
			and primary_validation.get("reason", &"") == case["reason"],
			"strict envelope rejects " + String(case["label"]))
		case_store.close()

	var duplicate_bytes := "d2:{s1:ai1;s1:ai2;}".to_utf8_buffer()
	var duplicate_ops := _ops_with("duplicate_raw", duplicate_bytes, PackedByteArray())
	var duplicate_store := _open_store(duplicate_ops)
	var duplicate_load := duplicate_store.load_profile()
	check(not bool(duplicate_load.get("ok", true)),
		"duplicate raw fields cannot be normalized into an envelope")
	duplicate_store.close()


func _test_preserve_recovered_backup() -> void:
	var fixture := _two_generation_fixture("preserve_backup")
	var store := fixture["store"] as ProfileStore
	var ops := fixture["ops"] as FakeFileOperations
	var good_backup := (ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray).duplicate()
	ops.slots[FileOps.SLOT_PRIMARY] = PackedByteArray([0x01, 0x02, 0x03])
	var recovered := store.load_profile()
	check(bool(recovered.get("recovered_backup", false)) \
		and int(recovered.get("generation", 0)) == 1,
		"corrupt primary selects generation-one backup before save")
	var result := store.save_profile(_payload(130, PackedByteArray([7, 8])), 1, 2)
	check(bool(result.get("committed", false)) \
		and bool((result["backup_rotation"] as Dictionary).get(
			"preserved_recovered_backup", false)),
		"save from recovery explicitly preserves the good backup")
	check((ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray) == good_backup,
		"corrupt primary is never rotated over the sole good backup")
	check(int(store.load_profile().get("generation", 0)) == 2,
		"recovered save installs the next primary generation")
	store.close()


func _test_injected_failures() -> void:
	_test_write_failure(false)
	_test_write_failure(true)
	_test_replace_failure(FileOps.SLOT_PRIMARY, false)
	_test_replace_failure(FileOps.SLOT_PRIMARY, true)
	_test_replace_failure(FileOps.SLOT_BACKUP, false)
	_test_replace_failure(FileOps.SLOT_BACKUP, true)
	_test_durability_result_cross_product()

	var corrupt_fixture := _one_generation_fixture("post_commit_corrupt")
	var corrupt_store := corrupt_fixture["store"] as ProfileStore
	var corrupt_ops := corrupt_fixture["ops"] as FakeFileOperations
	corrupt_ops.corrupt_primary_after_replace = true
	var corrupt_result := corrupt_store.save_profile(_payload(200), 1, 2)
	check(bool(corrupt_result.get("committed", false)) \
		and corrupt_result.get("status", &"") == Store.WRITE_COMMITTED_RECOVERY_REQUIRED \
		and not bool(corrupt_result.get("ok", true)),
		"post-replace verification mismatch reports committed recovery-required truth")
	check((corrupt_ops.slots[FileOps.SLOT_BACKUP] as PackedByteArray) \
		== (corrupt_fixture["generation_one"] as PackedByteArray),
		"post-commit corruption still leaves validated previous generation backup")
	corrupt_store.close()

	var durable_ops := FakeFileOperations.new("durable")
	durable_ops.durable_writes = true
	durable_ops.directory_sync_supported = true
	durable_ops.directory_sync_ok = true
	var durable_store := _open_store(durable_ops)
	var durable := durable_store.save_profile(_payload(100), 0, 1)
	check(durable.get("status", &"") == Store.WRITE_COMMITTED_DURABLE \
		and bool(durable.get("durable", false)),
		"durable status is reserved for a seam proving file and directory durability")
	durable_store.close()

	var sync_failure := _one_generation_fixture("sync_failure")
	var sync_store := sync_failure["store"] as ProfileStore
	var sync_ops := sync_failure["ops"] as FakeFileOperations
	sync_ops.durable_writes = true
	sync_ops.directory_sync_supported = true
	sync_ops.directory_sync_ok = false
	var sync_result := sync_store.save_profile(_payload(200), 1, 2)
	check(sync_result.get("status", &"") == Store.WRITE_COMMITTED_DURABILITY_UNCERTAIN \
		and bool(sync_result.get("committed", false)),
		"directory sync failure after replace remains a committed uncertain result")
	sync_store.close()

	var cleanup_fixture := _one_generation_fixture("cleanup")
	var cleanup_store := cleanup_fixture["store"] as ProfileStore
	var cleanup_ops := cleanup_fixture["ops"] as FakeFileOperations
	cleanup_ops.slots[FileOps.SLOT_WRITE_TEMP] = PackedByteArray([0xaa])
	var cleanup_result := cleanup_store.save_profile(_payload(200), 1, 2)
	check(bool(cleanup_result.get("committed", false)) \
		and not cleanup_ops.slots.has(FileOps.SLOT_WRITE_TEMP) \
		and not cleanup_ops.slots.has(FileOps.SLOT_BACKUP_TEMP),
		"safe stale and operation temps are cleaned")
	cleanup_store.close()

	var cleanup_fail_fixture := _one_generation_fixture("cleanup_fail")
	var cleanup_fail_store := cleanup_fail_fixture["store"] as ProfileStore
	var cleanup_fail_ops := cleanup_fail_fixture["ops"] as FakeFileOperations
	cleanup_fail_ops.slots[FileOps.SLOT_WRITE_TEMP] = PackedByteArray([0xbb])
	cleanup_fail_ops.fail_before("remove:write_temp")
	var cleanup_failure := cleanup_fail_store.save_profile(_payload(200), 1, 2)
	check(cleanup_failure.get("status", &"") == Store.WRITE_PRE_COMMIT_FAILED \
		and not bool(cleanup_failure.get("committed", true)),
		"temp cleanup failure blocks before candidate commit")
	check((cleanup_fail_ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) \
		== (cleanup_fail_fixture["generation_one"] as PackedByteArray),
		"cleanup failure leaves primary generation unchanged")
	cleanup_fail_store.close()


func _test_durability_result_cross_product() -> void:
	var case_count := 0
	for write_durable in [false, true]:
		for replace_ok in [false, true]:
			for replace_committed in [false, true]:
				for sync_supported in [false, true]:
					for sync_ok in [false, true]:
						var label := "durability_%s_%s_%s_%s_%s" % [
							write_durable,
							replace_ok,
							replace_committed,
							sync_supported,
							sync_ok,
						]
						var ops := FakeFileOperations.new(label)
						ops.durable_writes = write_durable
						ops.primary_replace_result_override = true
						ops.primary_replace_ok = replace_ok
						ops.primary_replace_committed = replace_committed
						ops.directory_sync_supported = sync_supported
						ops.directory_sync_ok = sync_ok
						var store := _open_store(ops)
						var result := store.save_profile(_payload(case_count + 1), 0, 1)
						var expected_durable: bool = write_durable and replace_ok \
							and replace_committed and sync_supported and sync_ok
						if not replace_committed:
							check(result.get("status", &"") \
								== Store.WRITE_PRE_COMMIT_FAILED \
								and not bool(result.get("committed", true)) \
								and not bool(result.get("durable", true)),
								"uncommitted replace result is pre-commit: " + label)
							check(not ops.slots.has(FileOps.SLOT_PRIMARY) \
								and not ops.calls.has("sync_directory"),
								"uncommitted replace installs no primary or sync: " + label)
						else:
							var expected_status := Store.WRITE_COMMITTED_DURABLE \
								if expected_durable \
								else Store.WRITE_COMMITTED_DURABILITY_UNCERTAIN
							check(result.get("status", &"") == expected_status \
								and bool(result.get("ok", false)) \
								and bool(result.get("committed", false)) \
								and bool(result.get("verified", false)) \
								and bool(result.get("durable", false)) == expected_durable,
								"committed durability tuple is exact: " + label)
							check(ops.slots.has(FileOps.SLOT_PRIMARY) \
								and ops.calls.has("sync_directory") \
								and (replace_ok \
									or result.get("reason", &"") \
										== &"injected_primary_replace_error"),
								"committed replace is retained and errors stay explicit: " + label)
						check(_is_recursively_read_only(result),
							"durability cross-product receipt is recursively read-only: " + label)
						check(store.close(), "durability cross-product store closes: " + label)
						case_count += 1
	check(case_count == 32, "durability result cross-product covers all 32 tuples")


func _test_write_failure(after_write: bool) -> void:
	var ops := FakeFileOperations.new("write_%s" % after_write)
	var store := _open_store(ops)
	var action := "write:%s" % FileOps.SLOT_WRITE_TEMP
	if after_write:
		ops.fail_after(action)
	else:
		ops.fail_before(action)
	var result := store.save_profile(_payload(100), 0, 1)
	check(result.get("status", &"") == Store.WRITE_PRE_COMMIT_FAILED \
		and not bool(result.get("committed", true)),
		"injected %s candidate-write failure is pre-commit" \
		% ["after" if after_write else "before"])
	check(not ops.slots.has(FileOps.SLOT_PRIMARY) \
		and not ops.slots.has(FileOps.SLOT_WRITE_TEMP),
		"candidate-write failure cleans temp and exposes no primary")
	store.close()


func _test_replace_failure(destination: StringName, after_replace: bool) -> void:
	var fixture := _one_generation_fixture("replace_%s_%s" % [destination, after_replace])
	var store := fixture["store"] as ProfileStore
	var ops := fixture["ops"] as FakeFileOperations
	var old_primary := fixture["generation_one"] as PackedByteArray
	var source := FileOps.SLOT_WRITE_TEMP if destination == FileOps.SLOT_PRIMARY \
		else FileOps.SLOT_BACKUP_TEMP
	var action := "replace:%s:%s" % [source, destination]
	if after_replace:
		ops.fail_after(action)
	else:
		ops.fail_before(action)
	var result := store.save_profile(_payload(200), 1, 2)
	if destination == FileOps.SLOT_PRIMARY and after_replace:
		check(bool(result.get("committed", false)) \
			and result.get("status", &"") == Store.WRITE_COMMITTED_DURABILITY_UNCERTAIN,
			"failure after primary replacement verifies and reports committed uncertainty")
		check((ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) != old_primary,
			"after-primary-replace failure exposes the complete new generation")
	else:
		check(not bool(result.get("committed", true)) \
			and result.get("status", &"") == Store.WRITE_PRE_COMMIT_FAILED,
			"%s backup/primary replacement failure remains pre-commit" \
			% ["after" if after_replace else "before"])
		check((ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray) == old_primary,
			"pre-commit replacement failure preserves old primary")
	check(not ops.slots.has(FileOps.SLOT_WRITE_TEMP) \
		and not ops.slots.has(FileOps.SLOT_BACKUP_TEMP),
		"replacement failure path cleans both temporary slots")
	store.close()


func _test_payload_bounds() -> void:
	var cases: Array[Dictionary] = []
	cases.append({"payload": {"project": {}, "domains": {}, "extra": 1}, "label": "unknown payload field"})
	cases.append({"payload": {"project": [], "domains": {}}, "label": "project type"})
	cases.append({"payload": {"project": {}, "domains": {"../escape": PackedByteArray()}}, "label": "domain traversal"})
	cases.append({"payload": {"project": {}, "domains": {"zerkov.inventory": "bytes"}}, "label": "domain value type"})
	cases.append({"payload": {"project": {"float": 1.0}, "domains": {}}, "label": "float coercion"})
	cases.append({"payload": {"project": {"nan": NAN}, "domains": {}}, "label": "NaN"})
	cases.append({"payload": {"project": {"inf": INF}, "domains": {}}, "label": "infinity"})
	cases.append({"payload": {"project": {"long": "x".repeat(Codec.MAX_STRING_BYTES + 1)}, "domains": {}}, "label": "string bound"})
	var too_many_domains: Dictionary = {}
	for index in Store.MAX_DOMAIN_RECORDS + 1:
		too_many_domains["zerkov.domain.d%d" % index] = PackedByteArray()
	cases.append({"payload": {"project": {}, "domains": too_many_domains}, "label": "domain count"})
	var large_domain_a := PackedByteArray()
	large_domain_a.resize(1_000_000)
	var large_domain_b := PackedByteArray()
	large_domain_b.resize(900_001)
	cases.append({
		"payload": {
			"project": {},
			"domains": {
				"zerkov.domain.large_a": large_domain_a,
				"zerkov.domain.large_b": large_domain_b,
			},
		},
		"label": "total domain bytes",
	})
	var deep: Variant = 1
	for _index in Codec.MAX_DEPTH + 2:
		deep = [deep]
	cases.append({"payload": {"project": {"deep": deep}, "domains": {}}, "label": "depth bound"})
	for case in cases:
		var ops := FakeFileOperations.new("bounds_" + String(case["label"]))
		var store := _open_store(ops)
		var before_calls := ops.calls.size()
		var result := store.save_profile(case["payload"], 0, 1)
		check(not bool(result.get("ok", true)) and not bool(result.get("committed", true)),
			"malformed/bounded payload rejects: " + String(case["label"]))
		check(not ops.slots.has(FileOps.SLOT_PRIMARY),
			"invalid payload writes no profile: " + String(case["label"]))
		check(ops.calls.size() == before_calls,
			"invalid payload reaches no read or write operation: " + String(case["label"]))
		store.close()


func _test_real_filesystem_restart() -> void:
	var suffix := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var profile := "zerkov.profile.host_contract_" + suffix
	var first := Store.new()
	check(first.configure(profile), "production fixed-root adapter configures on host")
	var missing := first.load_profile()
	check(missing.get("reason", &"") == &"profile_missing",
		"fresh host profile starts missing rather than defaulted")
	var payload := _payload(321, PackedByteArray([0, 4, 7, 2]))
	var write := first.save_profile(payload, 0, 1)
	check(bool(write.get("committed", false)) and bool(write.get("verified", false)) \
		and write.get("status", &"") == Store.WRITE_COMMITTED_DURABILITY_UNCERTAIN,
		"host FileAccess/rename commit is verified but directory durability is unproven")
	var capabilities := first.storage_capabilities()
	host_capabilities = capabilities.duplicate(true)
	check(capabilities.get("root_policy", "") == "fixed_user_data_digest_name" \
		and bool(capabilities.get("same_directory_temps", false)) \
		and not bool(capabilities.get("directory_sync", true)) \
		and not bool(capabilities.get("interprocess_lock", true)),
		"host capabilities state path, temp, directory-sync, and writer limitations")
	check(bool(capabilities.get("in_process_lease_thread_safe", false)) \
		and bool(capabilities.get("per_store_operation_admission_thread_safe", false)),
		"host capabilities expose mutex-backed lease and operation admission")
	first.close()

	var restarted := Store.new()
	check(restarted.configure(profile), "fresh store instance reacquires host writer lease")
	var restarted_load := restarted.load_profile()
	check(bool(restarted_load.get("ok", false)) and restarted_load.get("payload") == payload \
		and int(restarted_load.get("generation", 0)) == 1,
		"restart-like fresh instance restores exact committed host bytes")
	var payload_two := _payload(654, PackedByteArray([9, 8, 7]))
	var host_second := restarted.save_profile(payload_two, 1, 2)
	check(bool(host_second.get("committed", false)) \
		and bool((host_second["backup_rotation"] as Dictionary).get("verified", false)),
		"host second save stages and verifies the previous primary backup")
	restarted.close()

	var restarted_again := Store.new()
	check(restarted_again.configure(profile), "second fresh host instance configures")
	var generation_two := restarted_again.load_profile()
	check(bool(generation_two.get("ok", false)) and generation_two.get("payload") == payload_two \
		and int(generation_two.get("generation", 0)) == 2,
		"fresh host instance selects exact generation-two primary over backup")
	restarted_again.close()

	var digest := Codec.sha256_domain(GodotOps.PATH_DOMAIN, profile.to_utf8_buffer())
	var primary_path := ProjectSettings.globalize_path(
		GodotOps.ROOT_PATH.path_join(String(GodotOps.DEFAULT_NAMESPACE)) \
			.path_join(digest + ".profile"))
	var corrupt_primary := FileAccess.open(primary_path, FileAccess.WRITE)
	check(corrupt_primary != null, "host corruption fixture resolves only digest-owned primary")
	if corrupt_primary != null:
		corrupt_primary.store_buffer(PackedByteArray([0xff, 0x00, 0x01]))
		corrupt_primary.flush()
		corrupt_primary.close()
	var recovered_store := Store.new()
	check(recovered_store.configure(profile), "fresh host recovery instance configures")
	var host_recovered := recovered_store.load_profile()
	check(bool(host_recovered.get("recovered_backup", false)) \
		and host_recovered.get("payload") == payload \
		and int(host_recovered.get("generation", 0)) == 1,
		"host corrupt primary recovers exact independently validated generation-one backup")
	recovered_store.close()

	# Exact-profile cleanup only; no broad path or recursive deletion is exposed.
	var cleanup: GodotProfileFileOperations = GodotOps.new()
	var cleanup_configured: Dictionary = cleanup.configure(profile)
	var cleanup_prepared: Dictionary = cleanup.prepare()
	check(bool(cleanup_configured.get("ok", false)) \
		and bool(cleanup_prepared.get("ok", false)),
		"host cleanup adapter resolves the same digest-owned slots")
	var cleanup_ok: bool = true
	for slot in FileOps.ALL_SLOTS:
		cleanup_ok = bool(cleanup.remove_slot(slot).get("ok", false)) and cleanup_ok
	check(cleanup_ok, "host test removes only its four exact profile slots")


func _test_real_symlink_rejection() -> void:
	var suffix := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var namespace_name := "symlink_" + suffix
	var profile := "zerkov.profile.symlink_contract_" + suffix
	var setup: GodotProfileFileOperations = GodotOps.new(StringName(namespace_name))
	check(bool(setup.configure(profile).get("ok", false)) \
		and bool(setup.prepare().get("ok", false)),
		"symlink fixture prepares a safe fixed-root namespace")
	var root_path := ProjectSettings.globalize_path(
		GodotOps.ROOT_PATH.path_join(namespace_name)).simplify_path()
	var digest := Codec.sha256_domain(GodotOps.PATH_DOMAIN, profile.to_utf8_buffer())
	var target_name := "target.bin"
	var primary_name := digest + ".profile"
	var target_path := root_path.path_join(target_name)
	var target := FileAccess.open(target_path, FileAccess.WRITE)
	check(target != null, "symlink fixture target opens")
	if target != null:
		target.store_buffer(PackedByteArray([1, 2, 3]))
		target.flush()
		target.close()
	var directory := DirAccess.open(root_path)
	var link_error := ERR_CANT_OPEN
	if directory != null:
		link_error = directory.create_link(target_name, primary_name)
	check(link_error == OK and directory != null and directory.is_link(primary_name),
		"host creates a real primary symlink/reparse attack fixture")
	var attacked_ops: GodotProfileFileOperations = GodotOps.new(StringName(namespace_name))
	var attacked_store := Store.new()
	check(not attacked_store.configure_with_trusted_operations(profile, attacked_ops) \
		and attacked_store.last_error == &"storage_slot_unsafe",
		"production adapter rejects a real primary symlink before any profile I/O")
	var link_path := root_path.path_join(primary_name)
	var link_removed := DirAccess.remove_absolute(link_path) == OK
	var target_removed := DirAccess.remove_absolute(target_path) == OK
	var namespace_removed := DirAccess.remove_absolute(root_path) == OK
	check(link_removed and target_removed and namespace_removed,
		"symlink fixture cleanup removes only the exact link, target, and empty namespace")


func _thread_configure(
	store: ProfileStore,
	operations: ProfileFileOperations
) -> bool:
	return store.configure_with_trusted_operations(PROFILE_ID, operations)


func _thread_save(store: ProfileStore, payload: Dictionary) -> Dictionary:
	return store.save_profile(payload, 0, 1)


func _wait_for_gate(gate: ThreadGate, expected: int) -> bool:
	var deadline := Time.get_ticks_msec() + THREAD_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if gate.arrived_count() >= expected:
			return true
		OS.delay_msec(1)
	return gate.arrived_count() >= expected


func _wait_for_live_count(
	threads: Array[Thread],
	started: Array[bool],
	maximum_live: int
) -> bool:
	var deadline := Time.get_ticks_msec() + THREAD_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		var live_count := 0
		for index in threads.size():
			if started[index] and threads[index].is_alive():
				live_count += 1
		if live_count <= maximum_live:
			return true
		OS.delay_msec(1)
	return false


func _bounded_join(threads: Array[Thread], started: Array[bool]) -> Dictionary:
	var complete := _wait_for_live_count(threads, started, 0)
	var results: Array = []
	results.resize(threads.size())
	if complete:
		for index in threads.size():
			if started[index]:
				results[index] = threads[index].wait_to_finish()
	return {"complete": complete, "results": results}


func _is_recursively_read_only(value: Variant) -> bool:
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := value as Dictionary
			if not dictionary.is_read_only():
				return false
			for child in dictionary.values():
				if not _is_recursively_read_only(child):
					return false
			return true
		TYPE_ARRAY:
			var array := value as Array
			if not array.is_read_only():
				return false
			for child in array:
				if not _is_recursively_read_only(child):
					return false
			return true
	return true


func _one_generation_fixture(label: String) -> Dictionary:
	var ops := FakeFileOperations.new(label)
	var store := _open_store(ops)
	var committed := store.save_profile(_payload(100, PackedByteArray([1])), 0, 1)
	check(bool(committed.get("committed", false)), label + " fixture generation one commits")
	return {
		"ops": ops,
		"store": store,
		"generation_one": (ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray).duplicate(),
	}


func _two_generation_fixture(label: String) -> Dictionary:
	var fixture := _one_generation_fixture(label)
	var store := fixture["store"] as ProfileStore
	var committed := store.save_profile(_payload(120, PackedByteArray([2])), 1, 2)
	check(bool(committed.get("committed", false)), label + " fixture generation two commits")
	return fixture


func _single_generation_bytes(label: String, payload: Dictionary) -> PackedByteArray:
	var ops := FakeFileOperations.new(label)
	var store := _open_store(ops)
	var result := store.save_profile(payload, 0, 1)
	check(bool(result.get("committed", false)), label + " divergent fixture commits")
	var bytes := (ops.slots[FileOps.SLOT_PRIMARY] as PackedByteArray).duplicate()
	store.close()
	return bytes


func _ops_with(
	label: String,
	primary: PackedByteArray,
	backup: PackedByteArray,
	include_primary: bool = true
) -> FakeFileOperations:
	var ops := FakeFileOperations.new(label)
	if include_primary and not primary.is_empty():
		ops.slots[FileOps.SLOT_PRIMARY] = primary.duplicate()
	if not backup.is_empty():
		ops.slots[FileOps.SLOT_BACKUP] = backup.duplicate()
	return ops


func _open_store(ops: FakeFileOperations) -> ProfileStore:
	var store := Store.new()
	check(store.configure_with_trusted_operations(PROFILE_ID, ops), ops.label + " store configures")
	return store


func _payload(currency: int, domain_bytes: PackedByteArray = PackedByteArray()) -> Dictionary:
	return {
		"project": {
			"currency": currency,
			"display_name": "Local Raider",
			"settlement_ids": [],
		},
		"domains": {
			"zerkov.inventory.profile": domain_bytes.duplicate(),
		},
	}


func _tamper_payload_without_digests(bytes: PackedByteArray) -> PackedByteArray:
	return _mutate_envelope(bytes, func(envelope: Dictionary) -> void:
		var payload := envelope["payload"] as Dictionary
		var project := payload["project"] as Dictionary
		project["currency"] = int(project["currency"]) + 1)


func _tamper_metadata_without_fingerprint(bytes: PackedByteArray) -> PackedByteArray:
	return _mutate_envelope(bytes, func(envelope: Dictionary) -> void:
		envelope["generation"] = int(envelope["generation"]) + 1
		envelope["revision"] = int(envelope["revision"]) + 1)


func _mutate_envelope_and_recompute_fingerprint(
	bytes: PackedByteArray,
	mutation: Callable
) -> PackedByteArray:
	var decoded := Codec.decode(bytes)
	check(bool(decoded.get("ok", false)),
		"lineage fixture decodes before mutation")
	if not bool(decoded.get("ok", false)):
		return PackedByteArray([0xff])
	var envelope := decoded["value"] as Dictionary
	mutation.call(envelope)
	var core := envelope.duplicate(true)
	core.erase("fingerprint")
	var core_encoded := Codec.encode(core)
	check(bool(core_encoded.get("ok", false)),
		"lineage fixture core remains canonical")
	if not bool(core_encoded.get("ok", false)):
		return PackedByteArray([0xfe])
	envelope["fingerprint"] = Codec.sha256_domain(
		Store.ENVELOPE_FINGERPRINT_DOMAIN,
		core_encoded.get("bytes", PackedByteArray()) as PackedByteArray)
	var encoded := Codec.encode(envelope)
	check(bool(encoded.get("ok", false)),
		"lineage fixture with recomputed fingerprint remains canonical")
	return encoded.get("bytes", PackedByteArray()) as PackedByteArray


func _mutate_envelope(bytes: PackedByteArray, mutation: Callable) -> PackedByteArray:
	var decoded := Codec.decode(bytes)
	check(bool(decoded.get("ok", false)), "tamper fixture decodes before mutation")
	if not bool(decoded.get("ok", false)):
		return PackedByteArray([0xff])
	var envelope := decoded["value"] as Dictionary
	mutation.call(envelope)
	var encoded := Codec.encode(envelope)
	check(bool(encoded.get("ok", false)), "tamper fixture remains canonical after mutation")
	return encoded.get("bytes", PackedByteArray()) as PackedByteArray
