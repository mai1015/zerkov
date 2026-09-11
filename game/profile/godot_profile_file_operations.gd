class_name GodotProfileFileOperations
extends ProfileFileOperations
## Fixed-root local ProfileStore I/O using Godot's public filesystem APIs.
##
## Temp files and their destinations share one directory. FileAccess.flush() is
## issued before every rename. Godot exposes no directory fsync API, so this
## adapter truthfully reports directory durability as unsupported. It also does
## not claim an interprocess lock; ProfileStore enforces only an in-process
## single-writer lease for the supported offline runtime.

const ROOT_PATH: String = "user://zerkov/profile_store"
const DEFAULT_NAMESPACE: StringName = &"profiles"
const PATH_DOMAIN: String = "zerkov.profile.path.v1"

var _namespace: StringName = DEFAULT_NAMESPACE
var _configured: bool = false
var _profile_digest: String = ""
var _root_path: String = ""
var _root_absolute: String = ""
var _file_names: Dictionary = {}
var _last_reason: StringName = &""


func _init(p_namespace: StringName = DEFAULT_NAMESPACE) -> void:
	_namespace = p_namespace


func configure(profile_id: String) -> Dictionary:
	if _configured:
		return _failure(&"file_operations_already_configured")
	if not _is_safe_segment(String(_namespace)):
		return _failure(&"storage_namespace_invalid")
	var digest := ProfileCanonicalCodec.sha256_domain(
		PATH_DOMAIN, profile_id.to_utf8_buffer())
	if not ProfileCanonicalCodec.is_sha256(digest):
		return _failure(&"profile_path_digest_failed")
	_profile_digest = digest
	_root_path = ROOT_PATH.path_join(String(_namespace))
	_root_absolute = ProjectSettings.globalize_path(_root_path).simplify_path()
	_file_names = {
		SLOT_PRIMARY: digest + ".profile",
		SLOT_BACKUP: digest + ".profile.backup",
		SLOT_WRITE_TEMP: digest + ".profile.write.tmp",
		SLOT_BACKUP_TEMP: digest + ".profile.backup.tmp",
	}
	_configured = true
	return {"ok": true, "reason": &""}


func lease_key() -> String:
	if not _configured:
		return ""
	return "%s/%s" % [_root_absolute, _profile_digest]


func prepare() -> Dictionary:
	_last_reason = &""
	if not _configured:
		return _failure(&"file_operations_not_configured")
	var directory_result := _ensure_directory_chain()
	if not bool(directory_result.get("ok", false)):
		return directory_result
	for slot in ALL_SLOTS:
		var status := _slot_state(slot)
		if status == STATE_UNSAFE or status == STATE_ERROR:
			return _failure(&"storage_slot_unsafe")
	return {"ok": true, "reason": &""}


func read_slot(slot: StringName, maximum_bytes: int) -> Dictionary:
	if not is_known_slot(slot) or maximum_bytes <= 0:
		return _read_failure(STATE_ERROR, &"read_request_invalid")
	var chain := _validate_directory_chain()
	if not bool(chain.get("ok", false)):
		return _read_failure(STATE_UNSAFE, StringName(chain.get("reason", &"storage_path_unsafe")))
	var state := _slot_state(slot)
	if state != STATE_REGULAR:
		return {
			"ok": state == STATE_MISSING,
			"state": state,
			"bytes": PackedByteArray(),
			"reason": &"" if state == STATE_MISSING else &"storage_slot_unsafe",
		}
	var path := _slot_absolute_path(slot)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _read_failure(STATE_ERROR, &"profile_read_open_failed")
	var length := file.get_length()
	if length <= 0 or length > maximum_bytes:
		file.close()
		return _read_failure(STATE_INVALID, &"profile_file_size_invalid")
	var bytes := file.get_buffer(length)
	var read_error := file.get_error()
	file.close()
	if read_error != OK or bytes.size() != length:
		return _read_failure(STATE_ERROR, &"profile_read_failed")
	return {"ok": true, "state": STATE_REGULAR, "bytes": bytes, "reason": &""}


func write_temp(slot: StringName, bytes: PackedByteArray) -> Dictionary:
	if not is_temp_slot(slot) or bytes.is_empty() \
			or bytes.size() > ProfileCanonicalCodec.MAX_ENCODED_BYTES:
		return _failure(&"temp_write_request_invalid")
	var chain := _validate_directory_chain()
	if not bool(chain.get("ok", false)):
		return chain
	var state := _slot_state(slot)
	if state == STATE_UNSAFE or state == STATE_ERROR:
		return _failure(&"temp_slot_unsafe")
	var path := _slot_absolute_path(slot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _failure(&"temp_write_open_failed")
	file.store_buffer(bytes)
	file.flush()
	var write_error := file.get_error()
	var written_length := file.get_position()
	file.close()
	if write_error != OK or written_length != bytes.size():
		return _failure(&"temp_write_failed")
	var verify := read_slot(slot, bytes.size())
	if not bool(verify.get("ok", false)) \
			or (verify.get("bytes", PackedByteArray()) as PackedByteArray) != bytes:
		return _failure(&"temp_write_verification_failed")
	return {
		"ok": true,
		"flushed": true,
		"durable": false,
		"reason": &"file_flush_without_directory_sync",
	}


func replace_slot(source_slot: StringName, destination_slot: StringName) -> Dictionary:
	var pair_is_valid := source_slot == SLOT_WRITE_TEMP and destination_slot == SLOT_PRIMARY \
		or source_slot == SLOT_BACKUP_TEMP and destination_slot == SLOT_BACKUP
	if not pair_is_valid:
		return _replace_failure(&"replace_pair_invalid")
	var chain := _validate_directory_chain()
	if not bool(chain.get("ok", false)):
		return _replace_failure(StringName(chain.get("reason", &"storage_path_unsafe")))
	if _slot_state(source_slot) != STATE_REGULAR:
		return _replace_failure(&"replace_source_invalid")
	var destination_state := _slot_state(destination_slot)
	if destination_state == STATE_UNSAFE or destination_state == STATE_ERROR:
		return _replace_failure(&"replace_destination_unsafe")
	var replace_error := DirAccess.rename_absolute(
		_slot_absolute_path(source_slot), _slot_absolute_path(destination_slot))
	if replace_error != OK:
		return _replace_failure(&"atomic_replace_failed")
	return {"ok": true, "committed": true, "reason": &""}


func remove_slot(slot: StringName) -> Dictionary:
	if not is_known_slot(slot):
		return _failure(&"remove_slot_invalid")
	var chain := _validate_directory_chain()
	if not bool(chain.get("ok", false)):
		return chain
	var state := _slot_state(slot)
	if state == STATE_MISSING:
		return {"ok": true, "removed": false, "reason": &""}
	if state != STATE_REGULAR:
		return _failure(&"remove_slot_unsafe")
	var remove_error := DirAccess.remove_absolute(_slot_absolute_path(slot))
	if remove_error != OK:
		return _failure(&"remove_slot_failed")
	return {"ok": true, "removed": true, "reason": &""}


func sync_directory() -> Dictionary:
	# Godot 4.7 exposes FileAccess.flush(), but no directory-handle fsync.
	return {"ok": false, "supported": false, "reason": &"directory_sync_unavailable"}


func capabilities() -> Dictionary:
	var filesystem_type := "unknown"
	if _configured and DirAccess.dir_exists_absolute(_root_absolute):
		var directory := DirAccess.open(_root_absolute)
		if directory != null and directory.has_method("get_filesystem_type"):
			filesystem_type = String(directory.get_filesystem_type())
	return {
		"adapter": "godot_file_access_v1",
		"root_policy": "fixed_user_data_digest_name",
		"filesystem_type": filesystem_type,
		"same_directory_temps": true,
		"replace_primitive": "DirAccess.rename_absolute",
		"file_flush": true,
		"file_fsync_proven": false,
		"directory_sync": false,
		"power_loss_durability_proven": false,
		"interprocess_lock": false,
		"in_process_single_writer_required": true,
		"symlink_checks": true,
		"concurrent_filesystem_attacker_safe": false,
	}


func _ensure_directory_chain() -> Dictionary:
	var user_absolute := ProjectSettings.globalize_path("user://").simplify_path()
	if user_absolute.is_empty() or not _root_absolute.begins_with(user_absolute + "/"):
		return _failure(&"storage_root_escape_detected")
	var current := user_absolute
	for segment in ["zerkov", "profile_store", String(_namespace)]:
		var parent := DirAccess.open(current)
		if parent == null:
			return _failure(&"storage_parent_open_failed")
		if parent.is_link(segment):
			return _failure(&"storage_directory_symlink_rejected")
		if parent.file_exists(segment) and not parent.dir_exists(segment):
			return _failure(&"storage_directory_type_invalid")
		if not parent.dir_exists(segment):
			var make_error := parent.make_dir(segment)
			if make_error != OK:
				return _failure(&"storage_directory_create_failed")
		if parent.is_link(segment):
			return _failure(&"storage_directory_symlink_rejected")
		current = current.path_join(segment)
	return _validate_directory_chain()


func _validate_directory_chain() -> Dictionary:
	if not _configured:
		return _failure(&"file_operations_not_configured")
	var user_absolute := ProjectSettings.globalize_path("user://").simplify_path()
	var current := user_absolute
	for segment in ["zerkov", "profile_store", String(_namespace)]:
		var parent := DirAccess.open(current)
		if parent == null or parent.is_link(segment) or not parent.dir_exists(segment):
			return _failure(&"storage_path_unsafe")
		current = current.path_join(segment)
	return {"ok": current == _root_absolute, "reason": &"" if current == _root_absolute else &"storage_root_mismatch"}


func _slot_state(slot: StringName) -> StringName:
	if not is_known_slot(slot) or not _file_names.has(slot):
		return STATE_ERROR
	var directory := DirAccess.open(_root_absolute)
	if directory == null:
		return STATE_ERROR
	var file_name := String(_file_names[slot])
	if directory.is_link(file_name):
		return STATE_UNSAFE
	if directory.dir_exists(file_name):
		return STATE_UNSAFE
	if directory.file_exists(file_name):
		return STATE_REGULAR
	return STATE_MISSING


func _slot_absolute_path(slot: StringName) -> String:
	if not _file_names.has(slot):
		return ""
	return _root_absolute.path_join(String(_file_names[slot]))


static func _is_safe_segment(value: String) -> bool:
	if value.is_empty() or value.to_utf8_buffer().size() > 48:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if not (code >= 97 and code <= 122) \
				and not (code >= 48 and code <= 57) and code != 95 and code != 45:
			return false
	return true


static func _read_failure(state: StringName, reason: StringName) -> Dictionary:
	return {"ok": false, "state": state, "bytes": PackedByteArray(), "reason": reason}


static func _replace_failure(reason: StringName) -> Dictionary:
	return {"ok": false, "committed": false, "reason": reason}


static func _failure(reason: StringName) -> Dictionary:
	return {"ok": false, "reason": reason}
