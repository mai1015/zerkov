#ifndef INVENTORY_SYSTEM_CORE_COMMANDS_H
#define INVENTORY_SYSTEM_CORE_COMMANDS_H

#include "core/inv_bytes.h"
#include "core/inv_deltas.h"
#include "core/inv_hash.h"
#include "core/inv_ids.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

// Transaction-pipeline command and result value types (tasks.md 5.2). Every
// type here is a transport-neutral, already-decoded plain value: no byte
// parsing happens in this file (decode is a later protocol slice, tasks.md
// 6.x). InventoryTransactionPipeline (core/inv_transaction.h) is the only
// consumer that interprets these.
//
// Command availability in this slice is single-inventory (move/rotate/split/
// merge/insert/remove/equip/unequip/swap all target one InventoryRuntime).
// CommandHeader::expected_revisions is nonetheless a bounded vector rather
// than one scalar, so a later multi-inventory slice (loot/transfer, tasks.md
// 5.4) can add commands that name more than one target without changing the
// header shape; this slice always supplies exactly one entry and
// InventoryTransactionPipeline::submit() rejects anything else.
namespace inv {

// --- Header -----------------------------------------------------------

// One target inventory's expected revision. See CommandHeader.
struct ExpectedRevision {
	InventoryId inventory;
	std::uint64_t revision = 0;

	bool operator==(const ExpectedRevision &p_other) const {
		return inventory == p_other.inventory && revision == p_other.revision;
	}
};

// Shared by every command. actor is a plain, game-scoped opaque identity
// (not ExternalOwnerId: that domain is reserved for drop/settlement
// external-ownership targets, a distinct later-slice concept -- see
// contracts.md's "separate unsigned 64-bit domains" list). Authority never
// interprets actor itself; PermissionProvider::check() is where a game maps
// it to allowed scopes/roles.
struct CommandHeader {
	CommandId command_id; // nonzero
	std::uint64_t actor = 0;
	// This slice: exactly one entry, naming the InventoryRuntime passed to
	// InventoryTransactionPipeline::submit().
	std::vector<ExpectedRevision> expected_revisions;
};

// --- Command bodies (tasks.md 5.2) -------------------------------------

struct MoveItemCommand {
	ItemInstanceId item;
	ItemLocation destination;
};

// Rotate-in-place: same x/y, orientation only. Structural preconditions
// (layout allow_rotation AND item allow_rotation) are enforced by the
// pipeline's STRUCTURAL phase, not here.
struct RotateItemCommand {
	ItemInstanceId item;
	bool rotated = false;
};

struct SplitStackCommand {
	ItemInstanceId source;
	std::uint64_t quantity = 0;
	ItemLocation destination;
};

struct MergeStacksCommand {
	ItemInstanceId source;
	ItemInstanceId destination;
};

// Authority-spawn primitive: no source, the definition is named by stable
// identifier (resolved against the catalog in the RESOLVE phase).
struct InsertItemCommand {
	std::string item_definition_identifier;
	std::uint64_t quantity = 1;
	ItemLocation destination;
};

// Authority-despawn primitive: cascade rules follow destroy_item().
struct RemoveItemCommand {
	ItemInstanceId item;
};

// A thin semantic wrapper over move-into-a-NAMED_SLOTS-container: the
// pipeline still runs it through the same access/filter/count/mass/
// nesting evaluation as MoveItemCommand, but emits an EQUIPPED event.
struct EquipItemCommand {
	ItemInstanceId item;
	ContainerInstanceId destination_container;
	std::string slot_identifier;
};

// A thin semantic wrapper over move-out-of-a-NAMED_SLOTS-container, emitting
// an UNEQUIPPED event. destination may be any layout kind the target
// container supports.
struct UnequipItemCommand {
	ItemInstanceId item;
	ItemLocation destination;
};

// Atomic exchange of two items' current locations (InventoryRuntime::
// swap_items()); no caller-supplied destinations, see inventory-transactions
// spec "Swap requires two moves".
struct SwapItemsCommand {
	ItemInstanceId item_a;
	ItemInstanceId item_b;
};

// --- 5.3-5.6/5.9 command bodies (multi-inventory transfer, external
// ownership/settlement, deterministic placement, non-owning references) ---

// Documented candidate order (tasks.md 5.3, InventoryTransactionPipeline):
// profile root containers of `destination`, in canonical (sorted
// definition-identifier) order, that declare allow_auto_placement, THEN
// item-provided containers of already-placed items in that SAME inventory
// (also allow_auto_placement) in ascending ContainerInstanceId order.
// Within a candidate SPATIAL_GRID: unrotated positions in row-major (y
// outer, x inner) order, then (only if both item and layout allow rotation)
// rotated positions in the same row-major order. Within NAMED_SLOTS: the
// container definition's declared slot order, first empty slot passing
// filters. Within ORDERED_LIST: append at the end. The first fully-valid
// candidate wins; there is no fallback beyond this order. `item` MUST
// already be present in `destination` (auto-placement reorganizes within
// one inventory; see QuickTransferItemCommand for a cross-inventory move
// that also auto-places). destination_container optionally restricts the
// search to exactly that one container instead of the full candidate walk;
// the invalid (zero) handle means "search normally".
struct AutoPlaceItemCommand {
	ItemInstanceId item;
	InventoryId destination;
	ContainerInstanceId destination_container;
};

// Documented strategy (tasks.md 5.3): first fill compatible existing stacks
// in `destination` (same item definition, FEATURE_STACKING enabled on their
// container, room under max_stack) in ascending ItemInstanceId order; then
// auto-place the remainder using AutoPlaceItemCommand's candidate order
// (searched within `destination`; `source` may equal `destination` for a
// same-inventory quick transfer). allow_partial=false rejects atomically if
// the complete quantity cannot be placed; allow_partial=true transfers what
// fits and TransactionResult::transferred_quantity/remaining_quantity
// report the split. Quantity is always conserved. A remainder that does not
// fit as one new stack in a single auto-placed destination is only
// representable when allow_partial=true (the excess is reported as
// remaining_quantity); this slice does not spread one remainder across more
// than one newly-created destination stack.
struct QuickTransferItemCommand {
	ItemInstanceId item;
	InventoryId source;
	InventoryId destination;
	bool allow_partial = false;
};

// Transfers the complete source item/stack into containers materially owned
// by one destination provider item. Unlike QuickTransferItemCommand, the
// destination search is restricted to destination_provider's canonical
// provided_containers list: compatible stacks in that scope are filled in
// ascending ItemInstanceId order, then the remainder is auto-placed by
// ascending ContainerInstanceId and the normal per-layout candidate order.
// Partial completion is never allowed. The provider relationship is resolved
// from canonical destination runtime state; callers cannot nominate a raw
// container and thereby manufacture ownership.
struct TargetedProviderTransferCommand {
	InventoryId source;
	InventoryId destination;
	ItemInstanceId item;
	ItemInstanceId destination_provider;
};

// Moves `item` and its complete provided-container subtree (ids preserved)
// from `source` to `destination` as one two-inventory transaction
// (inventory-transactions spec, "Atomic Multi-Inventory Transfer"). `source`
// needs REMOVE access; `destination` constraints (access INSERT, filters,
// count, mass, nesting incl. subtree depth) are evaluated for the whole
// subtree in the same canonical order as every other command (tasks.md
// 5.8). `source` and `destination` MUST both be present in submit()'s
// runtime set and share one IdentityAuthority (InventoryRuntime::
// adopt_item_subtree()/release_item_subtree() rely on that to move records
// verbatim without an id collision). Any reference in `source` pointing at
// the moved item or a descendant is cleared in the same commit.
struct LootItemCommand {
	InventoryId source;
	InventoryId destination;
	ItemInstanceId item;
	ItemLocation destination_location;
};

// Removes `item` and its complete subtree from its inventory atomically and
// hands bounded value data to the game via
// TransactionResult::dropped_items/dropped_external_owner (inventory-
// transactions spec, "External Ownership and Settlement Commands"). The
// core never validates or interprets external_owner; design.md "Protected
// and secure containers": raid/death/extraction policy is game-owned, not
// inferred here. Any reference pointing at the removed item or a descendant
// is cleared in the same commit.
struct DropItemCommand {
	ItemInstanceId item;
	ExternalOwnerId external_owner;
};

// One item's disposition in a game-declared SettleInventoryCommand plan.
// RETAIN requires the item's CURRENT container to already have
// RetentionClass::PROTECTED or ::BOUND -- the only retention semantics the
// core itself owns (design.md "Protected and secure containers"); no field
// anywhere in this plan lets an untrusted sender assert a retention OUTCOME
// -- the plan itself IS the trusted authoritative input, expected to be
// produced by game policy after PermissionProvider::check() has already
// gated who may submit it (inventory-transactions spec, "Client declares
// retained items": "authority rejects or ignores the authority-only field
// before mutation" -- there is no such field here by construction).
// TRANSFER_TO is validated exactly like LootItemCommand; RELEASE_TO exactly
// like DropItemCommand.
struct SettlementRetain {};
struct SettlementTransfer {
	InventoryId destination;
	ItemLocation location;
};
struct SettlementRelease {
	ExternalOwnerId external_owner;
};
using SettlementDisposition = std::variant<SettlementRetain, SettlementTransfer, SettlementRelease>;

struct SettlementEntry {
	ItemInstanceId item;
	SettlementDisposition disposition;
};

// `inventory` is the inventory being settled; every distinct TRANSFER_TO
// destination named in the plan participates in the same transaction too
// (canonical ascending-InventoryId order, all-or-nothing -- tasks.md
// 5.4/5.5). Bounded by MAX_SETTLEMENT_PLAN_ENTRIES.
struct SettleInventoryCommand {
	InventoryId inventory;
	std::vector<SettlementEntry> plan;
};

// Transactional wrapper over InventoryRuntime::add_reference(): no ownership
// transfer, the item's location is unchanged (inventory-transactions spec,
// "Non-Owning Reference Transactions").
struct AssignReferenceCommand {
	ItemInstanceId item;
};

// Transactional wrapper over InventoryRuntime::remove_reference().
struct ClearReferenceCommand {
	ReferenceId reference;
};

// Authority-approved mutable item state changes. These are commands rather
// than direct InventoryRuntime mutations so permission, expected revision,
// idempotency, invariant validation, delta emission, and observation all use
// the same ordered transaction path as every other canonical state change.
struct SetItemComponentCommand {
	ItemInstanceId item;
	std::string component_identifier;
	std::vector<std::uint8_t> payload;
};

struct RemoveItemComponentCommand {
	ItemInstanceId item;
	std::string component_identifier;
};

// Closed variant on purpose: a new command STRUCT and a new alternative
// here never changes how the pipeline dispatches on this type (std::visit
// already fails to compile if a new alternative is added without a
// matching handler in every phase).
using Command = std::variant<
		MoveItemCommand,
		RotateItemCommand,
		SplitStackCommand,
		MergeStacksCommand,
		InsertItemCommand,
		RemoveItemCommand,
		EquipItemCommand,
		UnequipItemCommand,
		SwapItemsCommand,
		AutoPlaceItemCommand,
		QuickTransferItemCommand,
		TargetedProviderTransferCommand,
		LootItemCommand,
		DropItemCommand,
		SettleInventoryCommand,
		AssignReferenceCommand,
		ClearReferenceCommand,
		SetItemComponentCommand,
		RemoveItemComponentCommand>;

// --- Canonical payload fingerprint (duplicate-detection payload identity) --

namespace commands_detail {

inline void encode_location(const ItemLocation &p_location, ByteWriter &p_writer) {
	if (const SpatialPlacement *spatial = std::get_if<SpatialPlacement>(&p_location)) {
		p_writer.write_u8(1);
		p_writer.write_u64(spatial->container.value);
		p_writer.write_u32(spatial->x);
		p_writer.write_u32(spatial->y);
		p_writer.write_bool(spatial->rotated);
	} else if (const SlotPlacement *slot = std::get_if<SlotPlacement>(&p_location)) {
		p_writer.write_u8(2);
		p_writer.write_u64(slot->container.value);
		p_writer.write_string(slot->slot_identifier);
	} else {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_location);
		p_writer.write_u8(3);
		p_writer.write_u64(list_placement.container.value);
		p_writer.write_u32(list_placement.ordinal);
	}
}

// Command-kind tags used only for fingerprint framing; independent of the
// std::variant's own index so the fingerprint never depends on declaration
// order (matches SnapshotLocationKind's precedent in core/inv_snapshot.h).
enum class CommandTag : std::uint8_t {
	MOVE_ITEM = 1,
	ROTATE_ITEM = 2,
	SPLIT_STACK = 3,
	MERGE_STACKS = 4,
	INSERT_ITEM = 5,
	REMOVE_ITEM = 6,
	EQUIP_ITEM = 7,
	UNEQUIP_ITEM = 8,
	SWAP_ITEMS = 9,
	AUTO_PLACE_ITEM = 10,
	QUICK_TRANSFER_ITEM = 11,
	LOOT_ITEM = 12,
	DROP_ITEM = 13,
	SETTLE_INVENTORY = 14,
	ASSIGN_REFERENCE = 15,
	CLEAR_REFERENCE = 16,
	TARGETED_PROVIDER_TRANSFER = 17,
	SET_ITEM_COMPONENT = 18,
	REMOVE_ITEM_COMPONENT = 19,
};

// Settlement-disposition tags, independent of SettlementDisposition's own
// std::variant index for the same reason CommandTag is independent of
// Command's (see encode_command()).
enum class SettlementDispositionTag : std::uint8_t {
	RETAIN = 1,
	TRANSFER_TO = 2,
	RELEASE_TO = 3,
};

inline void encode_settlement_entry(const SettlementEntry &p_entry, ByteWriter &p_writer) {
	p_writer.write_u64(p_entry.item.value);
	std::visit(
			[&](const auto &p_disposition) {
				using T = std::decay_t<decltype(p_disposition)>;
				if constexpr (std::is_same_v<T, SettlementRetain>) {
					p_writer.write_u8(static_cast<std::uint8_t>(SettlementDispositionTag::RETAIN));
				} else if constexpr (std::is_same_v<T, SettlementTransfer>) {
					p_writer.write_u8(static_cast<std::uint8_t>(SettlementDispositionTag::TRANSFER_TO));
					p_writer.write_u64(p_disposition.destination.value);
					encode_location(p_disposition.location, p_writer);
				} else {
					static_assert(std::is_same_v<T, SettlementRelease>, "unhandled SettlementDisposition alternative");
					p_writer.write_u8(static_cast<std::uint8_t>(SettlementDispositionTag::RELEASE_TO));
					p_writer.write_u64(p_disposition.external_owner.value);
				}
			},
			p_entry.disposition);
}

inline void encode_command(const Command &p_command, ByteWriter &p_writer) {
	std::visit(
			[&](const auto &p_body) {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, MoveItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::MOVE_ITEM));
					p_writer.write_u64(p_body.item.value);
					encode_location(p_body.destination, p_writer);
				} else if constexpr (std::is_same_v<T, RotateItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::ROTATE_ITEM));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_bool(p_body.rotated);
				} else if constexpr (std::is_same_v<T, SplitStackCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::SPLIT_STACK));
					p_writer.write_u64(p_body.source.value);
					p_writer.write_u64(p_body.quantity);
					encode_location(p_body.destination, p_writer);
				} else if constexpr (std::is_same_v<T, MergeStacksCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::MERGE_STACKS));
					p_writer.write_u64(p_body.source.value);
					p_writer.write_u64(p_body.destination.value);
				} else if constexpr (std::is_same_v<T, InsertItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::INSERT_ITEM));
					p_writer.write_string(p_body.item_definition_identifier);
					p_writer.write_u64(p_body.quantity);
					encode_location(p_body.destination, p_writer);
				} else if constexpr (std::is_same_v<T, RemoveItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::REMOVE_ITEM));
					p_writer.write_u64(p_body.item.value);
				} else if constexpr (std::is_same_v<T, EquipItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::EQUIP_ITEM));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_u64(p_body.destination_container.value);
					p_writer.write_string(p_body.slot_identifier);
				} else if constexpr (std::is_same_v<T, UnequipItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::UNEQUIP_ITEM));
					p_writer.write_u64(p_body.item.value);
					encode_location(p_body.destination, p_writer);
				} else if constexpr (std::is_same_v<T, SwapItemsCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::SWAP_ITEMS));
					p_writer.write_u64(p_body.item_a.value);
					p_writer.write_u64(p_body.item_b.value);
				} else if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::AUTO_PLACE_ITEM));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_u64(p_body.destination.value);
					p_writer.write_u64(p_body.destination_container.value);
				} else if constexpr (std::is_same_v<T, QuickTransferItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::QUICK_TRANSFER_ITEM));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_u64(p_body.source.value);
					p_writer.write_u64(p_body.destination.value);
					p_writer.write_bool(p_body.allow_partial);
				} else if constexpr (std::is_same_v<T, TargetedProviderTransferCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::TARGETED_PROVIDER_TRANSFER));
					p_writer.write_u64(p_body.source.value);
					p_writer.write_u64(p_body.destination.value);
					p_writer.write_u64(p_body.item.value);
					p_writer.write_u64(p_body.destination_provider.value);
				} else if constexpr (std::is_same_v<T, LootItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::LOOT_ITEM));
					p_writer.write_u64(p_body.source.value);
					p_writer.write_u64(p_body.destination.value);
					p_writer.write_u64(p_body.item.value);
					encode_location(p_body.destination_location, p_writer);
				} else if constexpr (std::is_same_v<T, DropItemCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::DROP_ITEM));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_u64(p_body.external_owner.value);
				} else if constexpr (std::is_same_v<T, SettleInventoryCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::SETTLE_INVENTORY));
					p_writer.write_u64(p_body.inventory.value);
					p_writer.write_count(p_body.plan.size(), MAX_SETTLEMENT_PLAN_ENTRIES);
					for (const SettlementEntry &entry : p_body.plan) {
						encode_settlement_entry(entry, p_writer);
					}
				} else if constexpr (std::is_same_v<T, AssignReferenceCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::ASSIGN_REFERENCE));
					p_writer.write_u64(p_body.item.value);
				} else if constexpr (std::is_same_v<T, ClearReferenceCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::CLEAR_REFERENCE));
					p_writer.write_u64(p_body.reference.value);
				} else if constexpr (std::is_same_v<T, SetItemComponentCommand>) {
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::SET_ITEM_COMPONENT));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_string(p_body.component_identifier, MAX_IDENTIFIER_BYTES);
					p_writer.write_blob(p_body.payload, MAX_TRAIT_PAYLOAD_BYTES);
				} else {
					static_assert(std::is_same_v<T, RemoveItemComponentCommand>, "unhandled Command alternative");
					p_writer.write_u8(static_cast<std::uint8_t>(CommandTag::REMOVE_ITEM_COMPONENT));
					p_writer.write_u64(p_body.item.value);
					p_writer.write_string(p_body.component_identifier, MAX_IDENTIFIER_BYTES);
				}
			},
			p_command);
}

} // namespace commands_detail

// fnv1a64 over the command's canonical field encoding (MAX_COMMAND_BYTES
// bound, matching every other canonical encoder in this codebase). Used for
// duplicate-detection payload identity: two submissions with the same
// command_id and the same payload_fingerprint() are the same logical
// command; a differing fingerprint under a reused command_id is rejected
// rather than silently replayed or re-executed.
inline std::uint64_t payload_fingerprint(const Command &p_command) {
	ByteWriter writer(MAX_COMMAND_BYTES);
	commands_detail::encode_command(p_command, writer);
	return hash_bytes(writer.bytes());
}

// --- Results (tasks.md 5.2, 5.10) --------------------------------------

// One primary event per accepted command (fixture parity: move -> 1 event,
// split -> 1 SPLIT event carrying new_item_id, etc; see inv_transaction.h
// for the exact per-command mapping). Rejections always produce zero events.
// A SettleInventoryCommand emits one LOOTED/DROPPED event per mutating plan
// entry (TRANSFER_TO/RELEASE_TO respectively; RETAIN mutates nothing and
// emits nothing) -- it reuses these two kinds rather than adding a third
// "settled" vocabulary, since each entry genuinely IS a loot or a drop.
enum class TransactionEventKind : std::uint8_t {
	MOVED = 1,
	ROTATED = 2,
	SPLIT = 3,
	MERGED = 4,
	INSERTED = 5,
	REMOVED = 6,
	EQUIPPED = 7,
	UNEQUIPPED = 8,
	SWAPPED = 9,
	LOOTED = 10, // LootItemCommand / SettleInventory TRANSFER_TO entry.
	DROPPED = 11, // DropItemCommand / SettleInventory RELEASE_TO entry.
	REFERENCE_ASSIGNED = 12, // AssignReferenceCommand.
	REFERENCE_CLEARED = 13, // ClearReferenceCommand, or a cascade clear from LOOTED/DROPPED removing the referenced item.
	COMPONENT_SET = 14, // SetItemComponentCommand.
	COMPONENT_REMOVED = 15, // RemoveItemComponentCommand.
};

// container fields left at the invalid (zero) handle when not applicable
// (e.g. destination_container for REMOVED, source_container for INSERTED).
// `reference` is populated only for REFERENCE_ASSIGNED/REFERENCE_CLEARED
// (invalid otherwise); `item` on those two names the referenced item.
struct TransactionEvent {
	TransactionEventKind kind = TransactionEventKind::MOVED;
	ItemInstanceId item; // primary subject (new item for SPLIT/INSERTED; surviving item for MERGED; item_a for SWAPPED; the referenced item for REFERENCE_*)
	ItemInstanceId secondary_item; // SPLIT: original (reduced) source item. MERGED: destroyed source item. SWAPPED: item_b. Invalid otherwise.
	ContainerInstanceId source_container;
	ContainerInstanceId destination_container;
	ReferenceId reference; // REFERENCE_ASSIGNED/REFERENCE_CLEARED only. Invalid otherwise.
};

struct RevisionOutcome {
	InventoryId inventory;
	std::uint64_t predecessor_revision = 0;
	std::uint64_t successor_revision = 0;
};

// Bounded value data for one removed item (DropItemCommand / a
// SettleInventory RELEASE_TO entry), sufficient for the game to spawn or
// update world representation without the core knowing what that means
// (design.md "Protected and secure containers"). One entry per removed
// item, root first then descendants in the same order
// InventoryRuntime::release_item_subtree() returned them. external_owner
// repeats the owning RELEASE_TO's target on every entry in that subtree
// (redundant for a single DropItemCommand, which has exactly one owner for
// its whole result, but necessary for SettleInventory: a plan may contain
// more than one RELEASE_TO entry, each naming a different external owner).
struct DroppedItemValue {
	std::string item_definition_identifier;
	std::uint64_t quantity = 0;
	std::vector<MutableComponent> mutable_components;
	ExternalOwnerId external_owner;
};

struct TransactionResult {
	bool accepted = false;
	Status status;
	CommandId command_id;
	// True only for the synchronous marker returned to a reentrant submit()
	// call (tasks.md 5.9): accepted is always false and status is
	// OK/TRANSACTION_QUEUED when this is true. No mutation or notification
	// has happened yet for the underlying command; it is delivered to
	// observers later, when the pipeline actually drains and executes it.
	bool queued = false;
	// True when this result is an idempotency replay of a previously recorded
	// accepted result (tasks.md 5.7; zerkov_v1 duplicate_command_replays_result):
	// revisions/new ids are the recorded originals, events is empty (the
	// original events were already observable exactly once, on first accept),
	// and status carries OK/DUPLICATE_RESULT_REPLAY with the original event
	// count as detail.
	bool replayed = false;
	// One entry per inventory the command touched, in ascending InventoryId
	// order, populated as soon as the touched set is known (even for a
	// rejection, so "before == after" is directly assertable as
	// revisions[i].predecessor == .successor). This slice's original nine
	// commands always populate exactly one entry.
	std::vector<RevisionOutcome> revisions;
	// Bounded; always empty for a rejected command (spec: "no accepted delta
	// or gameplay integration event is emitted" on rejection).
	std::vector<TransactionEvent> events;
	// Valid only for SplitStackCommand/InsertItemCommand/a QuickTransferItem
	// remainder that created a new destination stack.
	ItemInstanceId new_item_id;
	// Valid only for an accepted AssignReferenceCommand.
	ReferenceId new_reference_id;
	// Valid only for an accepted DropItemCommand (the plan's single
	// external owner). A SettleInventoryCommand may release to more than
	// one external owner in one plan, so it reports per-entry owners on
	// dropped_items instead and leaves this at the invalid handle.
	ExternalOwnerId dropped_external_owner;
	std::vector<DroppedItemValue> dropped_items;
	// Quantity actually placed vs. quantity left behind in the source
	// inventory. Valid for an accepted LootItemCommand (transferred_quantity
	// is always the moved item's full quantity and remaining_quantity is
	// always 0 -- loot is all-or-nothing) and for an accepted
	// QuickTransferItemCommand (where remaining_quantity can be nonzero
	// under allow_partial=true). transferred_quantity + remaining_quantity
	// always equals the requested quantity (conservation).
	std::uint64_t transferred_quantity = 0;
	std::uint64_t remaining_quantity = 0;
	// Populated only when status.code == StatusCode::REVISION_MISMATCH
	// (inventory-transactions spec: "the result identifies the conflicting
	// inventory and authoritative revision"). Left at the invalid handle/0
	// for every other rejection reason.
	InventoryId conflicting_inventory;
	std::uint64_t authoritative_revision = 0;
	// Canonical delta record (tasks.md 5.1 DELTA-EMISSION phase; core/
	// inv_deltas.h), one entry per touched inventory in the same ascending-
	// InventoryId order as `revisions` (one-to-one, same length, same order,
	// on acceptance). Always empty for a rejected command (matches `events`)
	// AND for a replayed idempotency hit (replayed==true): a duplicate
	// resubmission does not re-carry the original delta any more than it
	// re-carries the original events -- the delta was already observable
	// exactly once, on first accept.
	std::vector<InventoryDelta> deltas;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_COMMANDS_H
