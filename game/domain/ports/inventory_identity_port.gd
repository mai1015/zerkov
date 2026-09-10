class_name ZInventoryIdentityPort
extends RefCounted
## Deny-by-default identity seam for game-owned inventory adapters.
##
## Session/authentication code may replace this port with an implementation
## backed by its own identity store.  Inventory adapters never inspect that
## store directly and never treat InventoryAuthority's opaque actor integer as
## proof of ownership.


## Resolve the already-authenticated product identity to the positive opaque
## actor value passed to InventoryAuthority. Zero means unresolved/denied.
## The mapping must remain stable for one synchronous adapter submission; the
## adapter re-resolves it after world policy and fails closed if it changes.
func native_actor_id(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	authority_epoch: int,
	generation: int
) -> int:
	return 0


## Return whether the exact authenticated actor owns the destination
## inventory. The adapter rechecks this after world policy. The default is
## deliberately deny-all.
func actor_owns_inventory(
	session_id: ZSessionId,
	actor_id: ZEntityId,
	inventory_id: int,
	authority_epoch: int,
	generation: int
) -> bool:
	return false
