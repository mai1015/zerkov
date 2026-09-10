class_name WeaponReloadParticipantPort
extends RefCounted
## Game-owned transaction port for Weapon System reload state.
##
## The complete contract has a prepared, silent-commit, rollback, and publish
## lifecycle.  The vendored WeaponAuthority Godot facade currently exposes
## only `commit_due_reload()`, whose native implementation closes its internal
## participant before returning.  Concrete ports MUST therefore report their
## commit capability honestly.  InventoryWeaponAdapter never treats a signal
## as a commit edge and never claims crash/restart atomicity for the facade-
## compatibility mode.

enum CommitCapability {
	UNAVAILABLE,
	FACADE_SINGLE_WRITER,
	ROLLBACKABLE_PARTICIPANT,
}

const MUTATION_NONE: StringName = &"none"
const MUTATION_COMMITTED: StringName = &"committed"
const MUTATION_AMBIGUOUS: StringName = &"ambiguous"


func commit_capability() -> CommitCapability:
	return CommitCapability.UNAVAILABLE


func is_ready() -> bool:
	return false


func identity_token() -> String:
	return ""


func snapshot(_instance_id: String) -> Dictionary:
	return {}


func begin_reload(_command: Dictionary) -> Dictionary:
	return _unsupported()


func cancel_reload(_command: Dictionary) -> Dictionary:
	return _unsupported()


func due_reloads(_tick: int) -> Array:
	return []


func prepare_due_reload(
	_tick: int,
	_instance_id: String,
	_reservation_id: String
) -> Dictionary:
	return _unsupported()


func commit_reload_silent(_reservation_id: String) -> Dictionary:
	return _unsupported()


func rollback_reload(_reservation_id: String) -> Dictionary:
	return _unsupported()


func publish_reload(_reservation_id: String) -> Dictionary:
	return _unsupported()


func clear() -> void:
	pass


func _unsupported() -> Dictionary:
	return {
		"accepted": false,
		"reason": &"weapon_reload_participant_unavailable",
		"mutation_state": MUTATION_NONE,
	}
