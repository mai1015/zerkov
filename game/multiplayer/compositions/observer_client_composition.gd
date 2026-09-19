class_name ZObserverClientComposition
extends Node
## Observer-client scene root. Confirmed scoped replicas only; never authority.

var _replicas := ZClientReplicaStore.new()


func canonical_role() -> StringName:
	return &"observer_client"


func has_canonical_authority() -> bool:
	return false


func replica_store() -> ZClientReplicaStore:
	return _replicas


func bind_replication_recipient(admission: ZSessionAdmission) -> bool:
	return _replicas.bind_recipient(admission)


func apply_replication_envelope(envelope: Dictionary) -> bool:
	return _replicas.apply_envelope(envelope)


func apply_replica_snapshot(
	channel: StringName,
	revision: int,
	payload: Dictionary
) -> bool:
	return _replicas.apply_snapshot(channel, revision, payload)
