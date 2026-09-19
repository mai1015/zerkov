class_name ZReplicationProjectionPort
extends RefCounted
## Read-only product seam for recipient-specific confirmed replication state.
##
## Implementations run on the trusted server. They may read canonical inventory,
## weapon, ability and Vision owners, but must return value copies only. The
## grant-scoped egress validates every result and owns recipient mapping,
## sequencing and transport routing. Defaults fail closed.


func snapshot(
	_admission: ZSessionAdmission,
	_channel: StringName,
	_subject: StringName
) -> Dictionary:
	return {
		"ok": false,
		"reason": &"replication_projection_unimplemented",
		"revision": -1,
		"payload": {},
	}


func delta(
	_admission: ZSessionAdmission,
	_channel: StringName,
	_subject: StringName,
	_predecessor_revision: int
) -> Dictionary:
	return {
		"ok": false,
		"reason": &"replication_projection_unimplemented",
		"predecessor_revision": -1,
		"revision": -1,
		"payload": {},
	}
