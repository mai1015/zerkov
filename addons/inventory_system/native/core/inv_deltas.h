#ifndef INVENTORY_SYSTEM_CORE_DELTAS_H
#define INVENTORY_SYSTEM_CORE_DELTAS_H

#include "core/inv_ids.h"
#include "core/inv_snapshot.h"

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

// Canonical accepted-transaction delta record (tasks.md 5.1's DELTA-EMISSION
// phase; inventory-protocol spec, "Ordered Authoritative Deltas"). Core owns
// this semantic value type -- the pipeline (core/inv_transaction.cpp) is the
// only writer, built during SIMULATE/COMMIT alongside TransactionEvent -- so
// core never depends on protocol. The protocol layer's DeltaBatch DTO
// (protocol/inv_protocol_types.h) wraps a bounded vector of InventoryDelta
// verbatim and adds only the transport envelope (protocol version, source
// command id) plus the canonical codec/diagnostic-JSON encoding.
//
// Every op field is a value type reused verbatim from core/inv_snapshot.h
// (SnapshotLocation, SnapshotMutableComponent) so a delta op's byte layout
// for a shared concept (a location, a mutable component) is byte-identical
// to that same concept's representation inside a full InventorySnapshot --
// one canonical location/component codec, not two.
//
// Every op carries COMPLETE after-state values, never a diff of a diff
// (design.md "Authority, protocol, and persistence"): applying an op means
// "this id now has exactly this state" (ITEM_CREATED/CONTAINER_ADOPTED/
// ITEM_MOVED/ITEM_QUANTITY/ITEM_COMPONENT_SET/REFERENCE_ASSIGNED) or "this id
// no longer exists in this inventory" (ITEM_DESTROYED/CONTAINER_RELEASED/
// ITEM_COMPONENT_REMOVED/REFERENCE_CLEARED). A replica applying ops in order
// to its declared predecessor state reconstructs the exact successor state;
// see native/tests/inv_test_deltas.cpp for the manual-application proof this
// slice adds (6.4's actual ordered-application API is a later slice).
//
// ADOPTED/RELEASED (not CREATED/DESTROYED) is deliberately used for
// containers: no command creates or destroys a container directly -- every
// container instance comes into being only as a side effect of create_item()
// instantiating an item's provided_containers, or of adopt_item_subtree()
// receiving one verbatim, and goes out of an inventory's state only via
// destroy_item()'s/release_item_subtree()'s cascade -- so "adopted"/
// "released" (matching those two primitives' own names) describes container
// lifecycle from ONE inventory's point of view without implying the
// container was freshly allocated or permanently gone (a loot/settlement
// transfer releases it from the source InventoryDelta and adopts it in the
// destination InventoryDelta in the SAME transaction).
namespace inv {

// Append-only; the numeric tag is independent of DeltaOp's std::variant
// index (same discipline as core/inv_commands.h's CommandTag and
// core/inv_snapshot.h's SnapshotLocationKind), so the wire format never
// depends on declaration order.
enum class DeltaOpKind : std::uint8_t {
	ITEM_CREATED = 1,
	ITEM_DESTROYED = 2,
	ITEM_MOVED = 3,
	ITEM_QUANTITY = 4,
	ITEM_COMPONENT_SET = 5,
	ITEM_COMPONENT_REMOVED = 6,
	CONTAINER_ADOPTED = 7,
	CONTAINER_RELEASED = 8,
	REFERENCE_ASSIGNED = 9,
	REFERENCE_CLEARED = 10,
};

// Full after-state record for an item id that now exists in this inventory
// (a brand-new instance from InsertItemCommand/SplitStackCommand, or one
// arriving verbatim via adopt_item_subtree() -- loot/settlement-transfer/
// cross-inventory quick-transfer). mutable_components/provided_containers
// are the item's COMPLETE current sets (not deltas of them).
struct ItemCreatedOp {
	std::uint64_t item = 0; // ItemInstanceId.value
	std::string item_definition_identifier;
	std::uint64_t quantity = 0;
	SnapshotLocation location;
	std::vector<SnapshotMutableComponent> mutable_components;
	std::vector<std::uint64_t> provided_containers; // raw ContainerInstanceId values, ascending (ItemInstance::provided_containers order).
};

// Item id no longer exists in this inventory (RemoveItemCommand, a merge's
// consumed source, or the source side of a subtree release). No further
// fields: an absent id needs no after-state.
struct ItemDestroyedOp {
	std::uint64_t item = 0;
};

// Item id's complete new location (move/rotate/equip/unequip/auto-place, or
// one half of a swap). Rotation is represented purely via the location's own
// `rotated` bit -- there is no separate "rotated" op.
struct ItemMovedOp {
	std::uint64_t item = 0;
	SnapshotLocation location;
};

// Item id's complete new quantity (split's reduced source, a merge's
// combined destination, or a quick-transfer partial-merge/remainder step).
struct ItemQuantityOp {
	std::uint64_t item = 0;
	std::uint64_t quantity = 0;
};

// Item id now carries this exact component value (full payload, not a
// diff). No V1 command in this slice mutates a component directly (only
// SplitStackCommand's inherited-copy, which is folded into ItemCreatedOp::
// mutable_components instead of a separate op); defined now for op-
// vocabulary completeness ahead of a future component-mutating command.
struct ItemComponentSetOp {
	std::uint64_t item = 0;
	SnapshotMutableComponent component;
};

// Item id no longer carries a component with this identifier. See
// ItemComponentSetOp: unused by any V1 command, defined for completeness.
struct ItemComponentRemovedOp {
	std::uint64_t item = 0;
	std::string component_identifier;
};

// Full after-state record for a container id that now exists in this
// inventory (freshly instantiated by create_item() alongside an
// ItemCreatedOp for the item that provides it, or arriving verbatim via
// adopt_item_subtree()).
struct ContainerAdoptedOp {
	std::uint64_t container = 0; // ContainerInstanceId.value
	std::string container_definition_identifier;
	std::uint64_t provider_item = 0; // ItemInstanceId.value; 0 (invalid) would mean root, but a released/adopted container is always provided (roots never move).
};

// Container id no longer exists in this inventory (destroy_item()'s cascade,
// or the source side of a subtree release).
struct ContainerReleasedOp {
	std::uint64_t container = 0;
};

// Reference id now exists and points at this item (AssignReferenceCommand).
struct ReferenceAssignedOp {
	std::uint64_t reference = 0; // ReferenceId.value
	std::uint64_t item = 0; // ItemInstanceId.value
};

// Reference id no longer exists (explicit ClearReferenceCommand, or a
// cascade clear from a destroyed/released item it pointed at). Only the id:
// an absent reference needs no after-state, matching ItemDestroyedOp/
// ContainerReleasedOp.
struct ReferenceClearedOp {
	std::uint64_t reference = 0;
};

// Closed variant on purpose (same discipline as core/inv_commands.h's
// Command): a new op struct and a new alternative here never silently
// compiles without a matching branch in every std::visit that touches it.
using DeltaOp = std::variant<
		ItemCreatedOp,
		ItemDestroyedOp,
		ItemMovedOp,
		ItemQuantityOp,
		ItemComponentSetOp,
		ItemComponentRemovedOp,
		ContainerAdoptedOp,
		ContainerReleasedOp,
		ReferenceAssignedOp,
		ReferenceClearedOp>;

// One inventory's slice of an accepted transaction's delta batch. Field
// names deliberately match RevisionOutcome (core/inv_commands.h) --
// predecessor_revision/successor_revision -- since both describe the exact
// same commit from two angles (the bare revision numbers vs. the complete
// canonical mutation that produced them). `ops` is bounded by
// MAX_DELTA_OPS_PER_INVENTORY (core/inv_limits.h).
struct InventoryDelta {
	InventoryId inventory;
	std::uint64_t predecessor_revision = 0;
	std::uint64_t successor_revision = 0;
	std::vector<DeltaOp> ops;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_DELTAS_H
