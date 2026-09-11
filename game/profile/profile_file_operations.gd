class_name ProfileFileOperations
extends RefCounted
## Trusted storage adapter used by ProfileStore.
##
## Production composition uses GodotProfileFileOperations. Tests may inject a
## deterministic in-memory implementation, but ProfileStore only ever supplies
## one of these fixed slot names; it never accepts a caller-provided path.

const SLOT_PRIMARY: StringName = &"primary"
const SLOT_BACKUP: StringName = &"backup"
const SLOT_WRITE_TEMP: StringName = &"write_temp"
const SLOT_BACKUP_TEMP: StringName = &"backup_temp"
const ALL_SLOTS: Array[StringName] = [
	SLOT_PRIMARY,
	SLOT_BACKUP,
	SLOT_WRITE_TEMP,
	SLOT_BACKUP_TEMP,
]

const STATE_REGULAR: StringName = &"regular"
const STATE_MISSING: StringName = &"missing"
const STATE_INVALID: StringName = &"invalid"
const STATE_UNSAFE: StringName = &"unsafe"
const STATE_ERROR: StringName = &"error"


func configure(_profile_id: String) -> Dictionary:
	return _unsupported(&"configure_not_implemented")


func lease_key() -> String:
	return ""


func prepare() -> Dictionary:
	return _unsupported(&"prepare_not_implemented")


func read_slot(_slot: StringName, _maximum_bytes: int) -> Dictionary:
	return {
		"ok": false,
		"state": STATE_ERROR,
		"bytes": PackedByteArray(),
		"reason": &"read_not_implemented",
	}


func write_temp(_slot: StringName, _bytes: PackedByteArray) -> Dictionary:
	return _unsupported(&"write_not_implemented")


func replace_slot(_source_slot: StringName, _destination_slot: StringName) -> Dictionary:
	return {
		"ok": false,
		"committed": false,
		"reason": &"replace_not_implemented",
	}


func remove_slot(_slot: StringName) -> Dictionary:
	return _unsupported(&"remove_not_implemented")


func sync_directory() -> Dictionary:
	return {
		"ok": false,
		"supported": false,
		"reason": &"directory_sync_not_implemented",
	}


func capabilities() -> Dictionary:
	return {
		"same_directory_temps": false,
		"file_flush": false,
		"directory_sync": false,
		"interprocess_lock": false,
		"symlink_checks": false,
	}


static func is_known_slot(slot: StringName) -> bool:
	return ALL_SLOTS.has(slot)


static func is_temp_slot(slot: StringName) -> bool:
	return slot == SLOT_WRITE_TEMP or slot == SLOT_BACKUP_TEMP


static func _unsupported(reason: StringName) -> Dictionary:
	return {"ok": false, "reason": reason}
