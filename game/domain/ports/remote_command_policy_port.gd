class_name ZRemoteCommandPolicyPort
extends RefCounted
## Game-owned policy seam for remote command relevance, revision and semantics.
##
## Defaults fail closed. Implementations must be synchronous and must not mutate
## canonical gameplay state; the remote command gate remains the sole caller that
## may translate a validated remote request into a RaidAuthority intent.


func is_relevant(
	_admission: ZSessionAdmission,
	_kind: StringName,
	_payload: Dictionary,
	_server_tick: int
) -> bool:
	return false


func expected_revision(
	_admission: ZSessionAdmission,
	_kind: StringName,
	_payload: Dictionary,
	_server_tick: int
) -> int:
	return -1


func validate_semantics(
	_admission: ZSessionAdmission,
	_kind: StringName,
	_payload: Dictionary,
	_server_tick: int
) -> StringName:
	return &"remote_semantic_policy_unimplemented"
