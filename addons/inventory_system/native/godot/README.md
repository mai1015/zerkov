# Godot façade boundary

This directory holds ClassDB registration (`register_types.*`), versioned
façade Nodes (`InventoryAuthority`, `InventoryReplicaNode`), the sealed-
catalog façade (`InventoryCatalog`, RefCounted), an immutable DTO Resource
(`InventorySnapshotResource`), Variant conversion (`inventory_godot_util.h`),
checked Godot owner lifetime (ObjectID re-resolution before every post-commit
signal emission), and post-commit signals (`transaction_committed`,
`delta_ready`, `snapshot_replaced`, `delta_applied`, `resync_needed`).

It adapts public native values; canonical rules remain in `core/` or
`protocol/` -- every mutation goes through
`inv::InventoryTransactionPipeline::submit()`, never a direct
`InventoryRuntime` call from this layer.
