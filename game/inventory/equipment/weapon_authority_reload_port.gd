class_name WeaponAuthorityReloadPort
extends WeaponReloadParticipantPort
## Narrow port over the public WeaponAuthority Godot facade.
##
## `commit_due_reload()` mutates Weapon System state and closes the native
## participant, but emits no completion signal.  That makes a synchronous,
## no-yield, single-writer transaction possible with InventoryAuthority:
## inventory silent commit -> weapon commit -> inventory publish -> weapon
## completion signal.  It does NOT expose weapon rollback and therefore is not
## a durable/crash-safe two-phase commit participant.  Every result names that
## limitation through `capability` and `irreversible_after_commit`.

const MAX_LOCAL_RECORDS: int = 128

var _authority: WeaponAuthority
var _authority_instance_id: int = 0
var _records: Dictionary = {}
var _record_order: PackedStringArray = PackedStringArray()
var _publication_active: bool = false


func configure(authority: WeaponAuthority) -> bool:
	if _authority != null or authority == null or not is_instance_valid(authority):
		return false
	if not authority.is_ready():
		return false
	_authority = authority
	_authority_instance_id = authority.get_instance_id()
	return true


func commit_capability() -> CommitCapability:
	return CommitCapability.FACADE_SINGLE_WRITER


func is_ready() -> bool:
	return _authority != null \
		and is_instance_valid(_authority) \
		and _authority.get_instance_id() == _authority_instance_id \
		and _authority.is_ready()


func identity_token() -> String:
	return "weapon_authority:%d" % _authority_instance_id if is_ready() else ""


func snapshot(instance_id: String) -> Dictionary:
	return _authority.snapshot(instance_id).duplicate(true) if is_ready() else {}


func begin_reload(command: Dictionary) -> Dictionary:
	if not is_ready():
		return _not_ready()
	if _publication_active:
		return _rejection(&"weapon_publication_active", MUTATION_NONE)
	return _authority.begin_reload(command).duplicate(true)


func cancel_reload(command: Dictionary) -> Dictionary:
	if not is_ready():
		return _not_ready()
	if _publication_active:
		return _rejection(&"weapon_publication_active", MUTATION_NONE)
	return _authority.cancel_reload(command).duplicate(true)


func due_reloads(tick: int) -> Array:
	if not is_ready() or _publication_active:
		return []
	return _authority.due_reloads(tick).duplicate(true)


func prepare_due_reload(
	tick: int,
	instance_id: String,
	reservation_id: String
) -> Dictionary:
	if not is_ready():
		return _not_ready()
	if _publication_active:
		return _rejection(&"weapon_publication_active", MUTATION_NONE)
	if _records.has(reservation_id):
		var existing := _records[reservation_id] as Dictionary
		if int(existing.get("tick", -1)) != tick \
				or String(existing.get("instance_id", "")) != instance_id:
			return _rejection(&"weapon_prepare_replay_conflict", MUTATION_NONE)
		var replay := existing.duplicate(true)
		replay["accepted"] = true
		replay["replayed"] = true
		return replay
	if _records.size() >= MAX_LOCAL_RECORDS:
		_trim_terminal_records()
	if _records.size() >= MAX_LOCAL_RECORDS:
		return _rejection(&"weapon_port_record_limit", MUTATION_NONE)

	var matches: Array[Dictionary] = []
	for candidate_value in _authority.due_reloads(tick):
		var candidate := candidate_value as Dictionary
		if String(candidate.get("instance_id", "")) == instance_id \
				and String(candidate.get("reservation_id", "")) == reservation_id:
			matches.append(candidate.duplicate(true))
	if matches.size() != 1:
		return _rejection(&"weapon_due_candidate_missing_or_ambiguous", MUTATION_NONE)
	var before := _authority.snapshot(instance_id).duplicate(true)
	if before.is_empty() \
			or String(before.get("phase", "")) != "reloading" \
			or String((before.get("reload", {}) as Dictionary).get(
				"reservation_id", "")) != reservation_id:
		return _rejection(&"weapon_reload_state_mismatch", MUTATION_NONE)
	var record := {
		"accepted": true,
		"replayed": false,
		"stage": &"prepared",
		"capability": int(commit_capability()),
		"irreversible_after_commit": true,
		"mutation_state": MUTATION_NONE,
		"tick": tick,
		"instance_id": instance_id,
		"reservation_id": reservation_id,
		"before": before,
		"completion": matches[0],
	}
	_records[reservation_id] = record
	_record_order.append(reservation_id)
	return record.duplicate(true)


func commit_reload_silent(reservation_id: String) -> Dictionary:
	if not is_ready():
		return _not_ready()
	if _publication_active:
		return _rejection(&"weapon_publication_active", MUTATION_NONE)
	if not _records.has(reservation_id):
		return _rejection(&"weapon_reload_not_prepared", MUTATION_NONE)
	var record := _records[reservation_id] as Dictionary
	var stage := StringName(record.get("stage", &""))
	if stage == &"committed" or stage == &"published":
		var replay := record.duplicate(true)
		replay["accepted"] = true
		replay["replayed"] = true
		return replay
	if stage != &"prepared":
		return _rejection(&"weapon_reload_stage_invalid", MUTATION_NONE)

	var result: Dictionary = _authority.commit_due_reload(
		int(record["tick"]),
		String(record["instance_id"]),
		reservation_id
	).duplicate(true)
	var after := _authority.snapshot(String(record["instance_id"])).duplicate(true)
	var expected := record.get("completion", {}) as Dictionary
	var mutation_state := _classify_post_commit(record["before"], after, expected)
	if not bool(result.get("ok", false)):
		return {
			"accepted": false,
			"reason": &"weapon_commit_failed",
			"status": (result.get("status", {}) as Dictionary).duplicate(true),
			"mutation_state": mutation_state,
			"capability": int(commit_capability()),
			"irreversible_after_commit": mutation_state != MUTATION_NONE,
		}
	if mutation_state != MUTATION_COMMITTED or not _same_completion(result, expected):
		return {
			"accepted": false,
			"reason": &"weapon_commit_postcondition_failed",
			"status": (result.get("status", {}) as Dictionary).duplicate(true),
			"mutation_state": MUTATION_AMBIGUOUS,
			"capability": int(commit_capability()),
			"irreversible_after_commit": true,
		}
	record["stage"] = &"committed"
	record["mutation_state"] = MUTATION_COMMITTED
	record["completion"] = result.duplicate(true)
	record["after"] = after
	_records[reservation_id] = record
	return record.duplicate(true)


func rollback_reload(_reservation_id: String) -> Dictionary:
	return {
		"accepted": false,
		"reason": &"weapon_facade_rollback_unavailable",
		"mutation_state": MUTATION_AMBIGUOUS,
		"capability": int(commit_capability()),
		"irreversible_after_commit": true,
	}


func publish_reload(reservation_id: String) -> Dictionary:
	if not is_ready():
		return _not_ready()
	if not _records.has(reservation_id):
		return _rejection(&"weapon_reload_not_committed", MUTATION_NONE)
	var record := _records[reservation_id] as Dictionary
	var stage := StringName(record.get("stage", &""))
	if stage == &"published":
		var replay := record.duplicate(true)
		replay["accepted"] = true
		replay["replayed"] = true
		return replay
	if _publication_active:
		return _rejection(&"weapon_publication_active", MUTATION_NONE)
	if stage != &"committed":
		return _rejection(&"weapon_reload_not_committed", MUTATION_NONE)
	# This public method is a notification only. Canonical Weapon state was
	# already committed by commit_due_reload(), and the adapter calls this only
	# after Inventory publication succeeds. Mark and cache the terminal result
	# before entering user signal callbacks: a same-reservation recursive call
	# can then only replay this record and can never emit a duplicate signal.
	# The native facade returns void, so callback delivery failure is not a
	# representable rollback edge; once emission starts, terminal state remains.
	record["stage"] = &"published"
	record["accepted"] = true
	record["replayed"] = false
	_records[reservation_id] = record
	var result := record.duplicate(true)
	_publication_active = true
	_authority.publish_reload_completion(
		(record.get("completion", {}) as Dictionary).duplicate(true))
	_publication_active = false
	return result


func clear() -> void:
	if _publication_active:
		return
	_records.clear()
	_record_order.clear()
	_authority = null
	_authority_instance_id = 0


func _classify_post_commit(
	before: Dictionary,
	after: Dictionary,
	expected: Dictionary
) -> StringName:
	if after == before:
		return MUTATION_NONE
	if after.is_empty():
		return MUTATION_AMBIGUOUS
	if String(after.get("phase", "")) == "ready" \
			and (after.get("reload", {}) as Dictionary).is_empty() \
			and int(after.get("revision", -1)) == int(expected.get("revision", -2)) \
			and int(after.get("loaded_rounds", -1)) == int(expected.get("loaded_rounds", -2)):
		return MUTATION_COMMITTED
	return MUTATION_AMBIGUOUS


func _same_completion(left: Dictionary, right: Dictionary) -> bool:
	return String(left.get("instance_id", "")) == String(right.get("instance_id", "")) \
		and String(left.get("reservation_id", "")) == String(right.get("reservation_id", "")) \
		and int(left.get("added_rounds", -1)) == int(right.get("added_rounds", -2)) \
		and int(left.get("revision", -1)) == int(right.get("revision", -2)) \
		and int(left.get("loaded_rounds", -1)) == int(right.get("loaded_rounds", -2)) \
		and (left.get("profile", {}) as Dictionary) == (right.get("profile", {}) as Dictionary)


func _trim_terminal_records() -> void:
	var retained := PackedStringArray()
	for reservation_id in _record_order:
		if _records.size() < MAX_LOCAL_RECORDS:
			retained.append(reservation_id)
			continue
		var record := _records.get(reservation_id, {}) as Dictionary
		if StringName(record.get("stage", &"")) == &"published":
			_records.erase(reservation_id)
		else:
			retained.append(reservation_id)
	_record_order = retained


func _not_ready() -> Dictionary:
	return _rejection(&"weapon_authority_not_ready", MUTATION_NONE)


func _rejection(reason: StringName, mutation_state: StringName) -> Dictionary:
	return {
		"accepted": false,
		"reason": reason,
		"mutation_state": mutation_state,
		"capability": int(commit_capability()),
		"irreversible_after_commit": false,
	}
