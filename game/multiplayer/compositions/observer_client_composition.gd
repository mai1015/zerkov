class_name ZObserverClientComposition
extends Node
## Observer-client scene root. Public/scoped replicas only; never authority.

var _replicas := ZClientReplicaStore.new()

func canonical_role() -> StringName:
	return &"observer_client"

func has_canonical_authority() -> bool:
	return false

func replica_store() -> ZClientReplicaStore:
	return _replicas

func apply_replica_snapshot(channel: StringName, revision: int, payload: Dictionary) -> bool:
	return _replicas.apply_snapshot(channel, revision, payload)
