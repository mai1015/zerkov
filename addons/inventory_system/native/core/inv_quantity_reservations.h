#ifndef INVENTORY_SYSTEM_CORE_QUANTITY_RESERVATIONS_H
#define INVENTORY_SYSTEM_CORE_QUANTITY_RESERVATIONS_H

#include "core/inv_commands.h"
#include "core/inv_limits.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace inv {

// Authority-only, ephemeral reservation participant. It intentionally knows
// nothing about weapons: crafting, trading, quest turn-ins, and other
// coordinators can reserve an exact trait-bearing quantity through the same
// contract.
struct QuantityReservationRequest {
	std::string reservation_id;
	InventoryId inventory;
	std::uint64_t expected_revision = 0;
	std::string required_trait;
	// Container definition identifiers in highest-to-lowest source priority.
	// Containers whose definitions are absent from this list are ineligible.
	std::vector<std::string> container_definition_priority;
	std::uint64_t quantity = 0;
	// Optional caller-supplied authority-tick deadline (inventory-transactions
	// delta, "Ephemeral Reservation Lifecycle": "bounded expiry/teardown
	// compatible with a caller-supplied deadline tick"). 0 means "never
	// expires" -- expire() only ever transitions a reservation whose
	// deadline_tick is nonzero and has elapsed. The core never interprets
	// "tick" itself; it is whatever monotonic authority clock the caller
	// (e.g. a reload coordinator) already advances.
	std::uint64_t deadline_tick = 0;

	bool operator==(const QuantityReservationRequest &p_other) const {
		return reservation_id == p_other.reservation_id &&
				inventory == p_other.inventory &&
				expected_revision == p_other.expected_revision &&
				required_trait == p_other.required_trait &&
				container_definition_priority == p_other.container_definition_priority &&
				quantity == p_other.quantity &&
				deadline_tick == p_other.deadline_tick;
	}
};

struct QuantityReservationLine {
	ItemInstanceId item;
	std::uint64_t quantity = 0;
	// Per-item, per-hold monotonic stamp assigned when this line was
	// selected (inventory-transactions delta, "Prepared Quantity Reservation
	// Participant": "record bounded reservation-line hold generations").
	// Distinct from the inventory's aggregate revision: commit-time
	// validation (commit_silent()) re-checks this line's generation and its
	// item's CURRENT quantity, never the aggregate revision, so an unrelated
	// accepted mutation elsewhere in the inventory can advance the aggregate
	// revision without disturbing this hold ("Selective Hold Isolation").
	std::uint64_t generation = 0;

	bool operator==(const QuantityReservationLine &p_other) const {
		return item == p_other.item && quantity == p_other.quantity &&
				generation == p_other.generation;
	}
};

// Explicit lifecycle stage for health diagnostics (Ephemeral Reservation
// Lifecycle: "Reservations SHALL support ... explicit health diagnostics").
// Mirrors PreparedQuantityReservations::State without exposing that private
// enum.
enum class QuantityReservationStage : std::uint8_t {
	UNKNOWN = 0,
	HELD = 1,
	COMMITTED = 2,
	RELEASED = 3,
	PUBLISHED = 4,
};

struct QuantityReservationResult {
	bool accepted = false;
	bool replayed = false;
	Status status;
	std::string reservation_id;
	InventoryId inventory;
	std::uint64_t revision = 0;
	std::uint64_t quantity = 0;
	std::vector<QuantityReservationLine> lines;
	QuantityReservationStage stage = QuantityReservationStage::UNKNOWN;
};

struct QuantityConsumptionLine {
	ItemInstanceId item;
	std::uint64_t quantity_before = 0;
	std::uint64_t quantity_consumed = 0;
	std::uint64_t quantity_after = 0;
	bool destroyed = false;
};

struct PreparedQuantityCommit {
	std::string reservation_id;
	InventoryId inventory;
	std::uint64_t predecessor_revision = 0;
	std::uint64_t successor_revision = 0;
	std::uint64_t quantity = 0;
	std::vector<QuantityConsumptionLine> lines;
};

class PreparedQuantityReservations {
public:
	using Observer = std::function<void(const PreparedQuantityCommit &)>;

	explicit PreparedQuantityReservations(const DefinitionCatalog &p_catalog);

	QuantityReservationResult prepare(
			InventoryRuntime &p_inventory,
			const QuantityReservationRequest &p_request);
	QuantityReservationResult release(
			InventoryRuntime &p_inventory,
			const std::string &p_reservation_id);
	QuantityReservationResult commit_silent(
			InventoryRuntime &p_inventory,
			const std::string &p_reservation_id);
	QuantityReservationResult rollback(
			InventoryRuntime &p_inventory,
			const std::string &p_reservation_id);
	QuantityReservationResult publish(const std::string &p_reservation_id);

	// Bounded, deadline-compatible expiry/teardown (Ephemeral Reservation
	// Lifecycle). No-op (RESERVATION_NOT_DUE) unless the record's
	// deadline_tick is nonzero and p_current_tick has reached it. A HELD
	// record simply releases (same ephemeral-only bookkeeping as release());
	// a COMMITTED (silently-prepared-but-unpublished) record additionally
	// discards its unpublished working successor by restoring the immediate
	// predecessor first -- mirroring rollback() -- so an expired hold NEVER
	// advances canonical inventory revision. Idempotent: expiring an
	// already-terminal (RELEASED/PUBLISHED) record returns the recorded
	// terminal outcome without mutating p_inventory.
	QuantityReservationResult expire(
			InventoryRuntime &p_inventory,
			const std::string &p_reservation_id,
			std::uint64_t p_current_tick);

	// Explicit, non-mutating health diagnostics (Ephemeral Reservation
	// Lifecycle: "explicit health diagnostics"). Returns the recorded
	// result/stage for p_reservation_id without touching any InventoryRuntime
	// or ledger state -- a caller (e.g. a reload coordinator checking whether
	// its hold is still HELD before beginning prepared commit) can poll this
	// freely.
	QuantityReservationResult health(const std::string &p_reservation_id) const;

	// Used by InventoryTransactionPipeline before ordinary command
	// validation. Only commands that can mutate/move a held line conflict;
	// unrelated items and read-only references remain available.
	// p_inventory, when non-null, lets a quantity-aware check (currently:
	// SplitStackCommand) distinguish "consumes only the provably unheld
	// balance of a held stack, without moving or re-identifying the held
	// line" (Selective Hold Isolation's partial-stack-isolation scenario,
	// allowed) from a split that would eat into the held quantity (rejected).
	// Multi-inventory commands never reach the quantity-aware branch, so
	// dispatch_multi() passes nullptr.
	bool conflicts(const Command &p_command, const InventoryRuntime *p_inventory) const;

	void add_observer(std::uint64_t p_owner_key, Observer p_observer);
	void remove_observer(std::uint64_t p_owner_key);
	void clear();
	// Drops every ephemeral reservation record for one inventory while
	// preserving holds, terminal outcomes, and generation counters belonging
	// to unrelated inventories. Used when an authority unloads or replaces a
	// single live runtime.
	std::size_t clear_inventory(InventoryId p_inventory);
	std::size_t active_count() const;

private:
	enum class State : std::uint8_t {
		HELD = 0,
		COMMITTED = 1,
		RELEASED = 2,
		PUBLISHED = 3,
	};

	struct Record {
		QuantityReservationRequest request;
		std::vector<QuantityReservationLine> lines;
		State state = State::HELD;
		std::optional<InventoryRuntime> predecessor;
		std::optional<PreparedQuantityCommit> commit;
	};

	struct ItemGenerationKey {
		InventoryId inventory;
		ItemInstanceId item;

		bool operator<(const ItemGenerationKey &p_other) const {
			return inventory < p_other.inventory ||
					(inventory == p_other.inventory && item < p_other.item);
		}
	};

	bool item_is_held(InventoryId p_inventory, ItemInstanceId p_item) const;
	std::uint64_t quantity_held(InventoryId p_inventory, ItemInstanceId p_item) const;
	QuantityReservationResult result_for(const Record &p_record, bool p_replayed) const;
	void notify(const PreparedQuantityCommit &p_commit) const;
	void trim_terminal_records();

	const DefinitionCatalog *catalog_ = nullptr;
	std::map<std::string, Record> records_;
	std::vector<std::string> terminal_order_;
	std::vector<std::pair<std::uint64_t, Observer>> observers_;
	// Per-item monotonic hold-generation counter (never an aggregate
	// revision): bumped once per newly placed reservation line on that item
	// instance, in prepare(). See QuantityReservationLine::generation.
	std::map<ItemGenerationKey, std::uint64_t> item_generation_;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_QUANTITY_RESERVATIONS_H
