#ifndef INVENTORY_SYSTEM_CORE_IDENTITY_AUTHORITY_H
#define INVENTORY_SYSTEM_CORE_IDENTITY_AUTHORITY_H

#include "core/inv_ids.h"

// Shared cross-inventory identity scope (tasks.md 5.4). Per-inventory
// allocators (InventoryRuntime's default, still the fallback for the
// existing single-inventory path) let two unrelated inventories mint the
// same numeric id, which is fine until an item or container instance must
// cross an inventory boundary and keep the SAME id (inventory-transactions
// spec, "Player loots a backpack": "every item exists in exactly one
// destination location after commit" -- referring to the SAME identity, not
// a new one). IdentityAuthority centralizes item/container/reference id
// allocation for every InventoryRuntime constructed against it, so ids stay
// unique across the whole authority scope and a moved record can be adopted
// verbatim (see InventoryRuntime::adopt_item_subtree()/
// release_item_subtree()).
namespace inv {

// Non-owning by convention: a game or test owns the authority's lifetime,
// exactly like DefinitionCatalog already is for InventoryRuntime::catalog_.
// Every InventoryRuntime sharing an authority holds only a raw pointer that
// MUST outlive the runtime. No locking or thread-safety: the core is
// single-threaded by contract (design.md "Transaction pipeline": "The core
// itself is deterministic and non-reentrant").
struct IdentityAuthority {
	HandleAllocator<ItemInstanceId> items;
	HandleAllocator<ContainerInstanceId> containers;
	HandleAllocator<ReferenceId> references;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_IDENTITY_AUTHORITY_H
