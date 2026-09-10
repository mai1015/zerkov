class_name EquipmentAbilityParticipantPort
extends RefCounted
## Narrow game-owned port for equipment-scoped Gameplay Abilities state.
##
## InventoryAbilityAdapter depends only on this contract. The production port
## wraps the installed GameplayAbilityComponent public API; deterministic
## failure fixtures can implement the same bounded transaction surface without
## pretending to be the native add-on.

const MUTATION_NONE: StringName = &"none"
const MUTATION_COMMITTED: StringName = &"committed"
const MUTATION_AMBIGUOUS: StringName = &"ambiguous"


func is_ready() -> bool:
	return false


func identity_token() -> String:
	return ""


func entity_id() -> int:
	return 0


func current_tick() -> int:
	return 0


func owner_node() -> Node:
	return null


func validate_content(_equipment_declarations: Array[Dictionary]) -> Dictionary:
	return _unsupported()


func preflight(
	_addition_plans: Array[Dictionary],
	_revocation_records: Array[Dictionary]
) -> Dictionary:
	return _unsupported()


func grant(plan: Dictionary, _tick: int) -> Dictionary:
	return _unsupported({"plan": plan.duplicate(true)})


func revoke(record: Dictionary, _tick: int) -> Dictionary:
	return _unsupported({"record": record.duplicate(true)})


func grant_record_is_live(_record: Dictionary) -> bool:
	return false


func grant_record_is_absent(_record: Dictionary) -> bool:
	return false


## Stronger recovery proof for a record captured around a possibly partial
## mutation. In addition to absent specs/executions/effects, implementations
## must prove every captured attribute and tag has returned to its exact
## before-state. Ordinary absence alone is not enough for ambiguous failures.
func recovery_record_is_clean(_record: Dictionary) -> bool:
	return false


## Terminal owner teardown has a distinct proof shape: the installed native
## component intentionally retains immutable, unrevoked grant history while
## cancelling every execution-owned effect. Implementations must restrict
## this predicate to the exact captured terminal participant identity.
func grant_record_is_terminally_clean(_record: Dictionary) -> bool:
	return false


## Fail-stop an exact participant after ordinary per-spec cleanup is
## ambiguous. Production may terminally tear down its captured component; it
## must then prove every supplied record terminally clean.
func quarantine(
	_records: Array[Dictionary],
	_tick: int
) -> Dictionary:
	return _unsupported()


func clear() -> bool:
	return false


func _unsupported(extra: Dictionary = {}) -> Dictionary:
	var result := {
		"accepted": false,
		"reason": &"equipment_ability_participant_unavailable",
		"mutation_state": MUTATION_NONE,
	}
	result.merge(extra, true)
	return result
