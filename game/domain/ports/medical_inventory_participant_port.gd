class_name MedicalInventoryParticipantPort
extends RefCounted
## Narrow inventory participant used by the health consequence coordinator.
##
## Inventory System remains the sole owner of item quantities. Implementations
## reserve one authored treatment item, keep the commit unpublished while the
## health transition is verified, then publish or roll the exact predecessor
## back. The default implementation denies every mutation.

const MUTATION_NONE: StringName = &"none"
const MUTATION_COMMITTED: StringName = &"committed"
const MUTATION_AMBIGUOUS: StringName = &"ambiguous"


func is_ready() -> bool:
	return false


func identity_token() -> String:
	return ""


func actor_id() -> String:
	return ""


func owner_generation() -> int:
	return 0


func inventory_id() -> int:
	return 0


func current_revision() -> int:
	return -1


func prepare_treatment(
	_reservation_id: String,
	_treatment: StringName,
	_expected_revision: int,
	_deadline_tick: int
) -> Dictionary:
	return _unavailable()


func reservation_health(_reservation_id: String) -> Dictionary:
	return _unavailable()


func commit_treatment_silent(_reservation_id: String) -> Dictionary:
	return _unavailable()


func publish_treatment(_reservation_id: String) -> Dictionary:
	return _unavailable()


func rollback_treatment(_reservation_id: String) -> Dictionary:
	return _unavailable()


func release_treatment(_reservation_id: String) -> Dictionary:
	return _unavailable()


func recovery_details() -> Dictionary:
	return {}


func clear() -> bool:
	return true


func _unavailable() -> Dictionary:
	return {
		"accepted": false,
		"reason": &"medical_inventory_participant_unavailable",
		"mutation_state": MUTATION_NONE,
	}
