class_name ZOwningClientComposition
extends Node
## Owning-client scene root. Confirmed scoped replicas only; never authority.

var _replicas := ZClientReplicaStore.new()

func canonical_role() -> StringName:
	return &"owning_client"

func has_canonical_authority() -> bool:
	return false

func replica_store() -> ZClientReplicaStore:
	return _replicas

func apply_replica_snapshot(channel: StringName, revision: int, payload: Dictionary) -> bool:
	return _replicas.apply_snapshot(channel, revision, payload)
