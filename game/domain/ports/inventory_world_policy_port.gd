class_name ZInventoryWorldPolicyPort
extends RefCounted
## Deny-by-default world-fact seam for authoritative inventory interactions.
##
## Movement and Vision implementations can later answer these queries without
## exposing their private state or importing InventoryAuthority internals.

const ACCESS_OPEN: StringName = &"open"
const ACCESS_CLOSED: StringName = &"closed"
const ACCESS_UNAVAILABLE: StringName = &"unavailable"


## A loot transfer may originate only from a registered live world inventory.
func is_world_inventory(actor_id: ZEntityId, inventory_id: int, generation: int) -> bool:
	return false


## Return authoritative distance in ZWorldUnits canonical raw units.  A
## negative value means no authoritative fact is available and fails closed.
func authoritative_distance_raw(
	actor_id: ZEntityId,
	inventory_id: int,
	generation: int
) -> int:
	return -1


## Current visibility only.  Remembered/presentation visibility must not grant
## an inventory mutation.
func is_currently_visible(actor_id: ZEntityId, inventory_id: int, generation: int) -> bool:
	return false


## ACCESS_OPEN is the sole state that admits mutation.  Unknown, searching,
## locked, closed, destroyed, or any future state fails closed.
func access_state(actor_id: ZEntityId, inventory_id: int, generation: int) -> StringName:
	return ACCESS_UNAVAILABLE


## Final game-owned policy gate for phase, liveness, eligibility, or other
## product rules. Implementations must be side-effect-free and repeatable: the
## adapter calls the full world-policy query set again immediately before the
## native transaction, including this method, to close stale-observation gaps.
func allows_transfer(
	actor_id: ZEntityId,
	source_inventory_id: int,
	destination_inventory_id: int,
	item_id: int,
	generation: int
) -> bool:
	return false
