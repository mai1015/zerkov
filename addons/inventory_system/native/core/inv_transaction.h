#ifndef INVENTORY_SYSTEM_CORE_TRANSACTION_H
#define INVENTORY_SYSTEM_CORE_TRANSACTION_H

#include "core/inv_authority_interfaces.h"
#include "core/inv_catalog.h"
#include "core/inv_commands.h"
#include "core/inv_deltas.h"
#include "core/inv_ids.h"
#include "core/inv_limits.h"
#include "core/inv_quantity_reservations.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <utility>
#include <vector>

// InventoryTransactionPipeline: the ordered transaction pipeline (tasks.md
// 5.1, design.md "Transaction pipeline"). See inv_transaction.cpp for the
// phase-by-phase implementation notes and the canonical FEATURE/CONSTRAINT
// evaluation order (tasks.md 5.8).
namespace inv {

// Game-supplied authority policy. Value inputs only: check() takes const
// references to the header/command and never a mutable InventoryRuntime, so
// policy cannot see or touch canonical storage (design.md: "It does not
// receive mutable internal containers"). Deliberately minimal; the protocol
// slice (6.6) extends this with bounded external-metric inputs.
class PermissionProvider {
public:
	virtual ~PermissionProvider() = default;
	virtual Status check(const CommandHeader &p_header, const Command &p_command) const = 0;
};

// Default-allow implementation for offline/single-player hosts and tests
// that don't exercise policy rejection.
class AllowAllPermissionProvider : public PermissionProvider {
public:
	Status check(const CommandHeader &p_header, const Command &p_command) const override;
};

struct IdempotencyRecord {
	std::uint64_t payload_fingerprint = 0;
	TransactionResult result;
};

// Side-effect-free answer for a targeted-provider transfer hover/preview.
// The query runs the same policy, revision, candidate, constraint, subtree,
// and invariant checks as submission, but never commits, journals, emits a
// delta/event, or notifies observers.
struct TargetedProviderTransferPreview {
	bool valid = false;
	Status status;
	ContainerInstanceId destination_container;
	std::uint64_t transferred_quantity = 0;
	InventoryId conflicting_inventory;
	std::uint64_t authoritative_revision = 0;
};

// Owns an observer list, a bounded idempotency journal, and a reference to
// the game-supplied PermissionProvider.
//
// submit(InventoryRuntime&, ...) is a thin wrapper (tasks.md 5.4) over
// submit(const std::vector<InventoryRuntime*>&, ...): every pre-5.4 call
// site and command keeps working unchanged, targeting exactly one runtime.
// The vector-taking overload is the primary entry point for multi-inventory
// commands (LootItemCommand, SettleInventoryCommand,
// QuickTransferItemCommand -- see inv_commands.h): it resolves which of the
// passed runtimes a command actually touches, enforces
// MAX_INVENTORIES_PER_TRANSACTION, requires every touched runtime to share
// one IdentityAuthority when more than one is touched, processes touched
// inventories in canonical ascending-InventoryId order regardless of
// argument order, and commits every touched runtime or none of them
// (design.md "Transaction pipeline": "acquire or receive aggregates in
// canonical inventory-identity order and commit all of them or none of
// them"). AutoPlaceItemCommand, AssignReferenceCommand,
// ClearReferenceCommand, and DropItemCommand only ever touch one runtime
// and are dispatched through the same single-runtime path the original
// nine commands use.
class InventoryTransactionPipeline {
public:
	using Observer = std::function<void(const TransactionResult &)>;

	// p_metrics is optional (tasks.md 6.6, default nullptr): a game-owned
	// ExternalMetricProvider, queried once per submission right after
	// PermissionProvider::check() succeeds (same POLICY phase, before any
	// STRUCTURAL/FEATURE/SIMULATE work -- see inv_transaction.cpp's
	// check_external_metrics()). A submitting game that has no need for a
	// bounded external metric (the common case for V1, since no built-in
	// constraint consumes one yet) simply omits this argument and every
	// existing call site keeps compiling and behaving unchanged.
	explicit InventoryTransactionPipeline(
			const DefinitionCatalog &p_catalog,
			const PermissionProvider &p_permissions,
			const ExternalMetricProvider *p_metrics = nullptr,
			std::size_t p_idempotency_capacity = MAX_IDEMPOTENCY_RECORDS,
			const PreparedQuantityReservations *p_quantity_reservations = nullptr);

	// p_owner_key is an opaque caller-chosen identity (never a pointer,
	// ObjectID, or node path) used only to find this observer again for
	// remove_observer(); re-adding the same key replaces the previous
	// observer registered under it.
	void add_observer(std::uint64_t p_owner_key, Observer p_observer);
	void remove_observer(std::uint64_t p_owner_key);

	// A live InventoryRuntime replacement establishes a new generation for
	// that inventory id. Remove every accepted command whose result touched
	// the replaced inventory so a reused CommandId is evaluated against the
	// replacement instead of replaying a prior-generation success. Records
	// for unrelated inventories retain their FIFO order. This is safe to call
	// from an observer notification: it does not alter observers, executing_,
	// or the pending reentrant-submission queue.
	std::size_t invalidate_idempotency_for_inventory(InventoryId p_inventory);

	// Single-inventory convenience overload; see the class comment. Any
	// rejection leaves p_inventory (bytes, hash, revision), non-owning
	// references, and this pipeline's idempotency journal byte-for-byte/
	// entry-for-entry unchanged (design.md: "Any rejection leaves all
	// aggregates, revisions, idempotency records, non-owning references,
	// and observable events unchanged").
	TransactionResult submit(InventoryRuntime &p_inventory, const CommandHeader &p_header, const Command &p_command);

	// Primary multi-inventory entry point; see the class comment.
	// p_inventories is the set of runtimes AVAILABLE to this command, not
	// necessarily all touched by it; every runtime the command actually
	// names must be present in this set or the command rejects
	// (INVENTORY_NOT_IN_TRANSACTION_SET). A rejection leaves every runtime
	// in p_inventories byte-for-byte unchanged.
	//
	// Reentrancy (tasks.md 5.9): if this is called from inside an
	// observer's notification callback (i.e. reentrantly, while an earlier
	// call to this same method is still executing on this pipeline
	// instance), the command is queued (FIFO, bounded by
	// MAX_PENDING_REENTRANT_TRANSACTIONS) instead of executed immediately,
	// and this returns a TransactionResult with queued=true, accepted=false,
	// and a Status of OK/TRANSACTION_QUEUED -- no pipeline or runtime
	// working state is touched or exposed. Once the outermost call's
	// notifications finish, queued commands run in FIFO order (each
	// re-validated against whatever is then current, including its own
	// expected_revisions); their real results are delivered to observers
	// only -- nothing here waits for or returns them.
	TransactionResult submit(const std::vector<InventoryRuntime*> &p_inventories, const CommandHeader &p_header, const Command &p_command);

	// Network/request-response entry point: execute synchronously or reject
	// without enqueuing when this pipeline is already inside a submission.
	// Unlike submit(), a caller can therefore safely bind the returned result to
	// one remote request without a rejected reply later mutating world state.
	TransactionResult submit_immediate(InventoryRuntime &p_inventory, const CommandHeader &p_header, const Command &p_command);
	TransactionResult submit_immediate(const std::vector<InventoryRuntime*> &p_inventories, const CommandHeader &p_header, const Command &p_command);

	TargetedProviderTransferPreview preview_targeted_provider_transfer(
			const std::vector<InventoryRuntime *> &p_inventories,
			const CommandHeader &p_header,
			const TargetedProviderTransferCommand &p_command) const;

private:
	struct PendingSubmission {
		std::vector<InventoryRuntime *> inventories;
		CommandHeader header;
		Command command;
	};

	// Runs the complete ordered pipeline for one submission with no
	// reentrancy handling of its own (submit() above owns that); routes to
	// dispatch_single()/dispatch_multi() by command type.
	TransactionResult dispatch(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const Command &p_command);
	TransactionResult dispatch_single(InventoryRuntime &p_inventory, const CommandHeader &p_header, const Command &p_command);
	TransactionResult dispatch_multi(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const Command &p_command);

	Status resolve(const InventoryRuntime &p_inventory, const Command &p_command) const;
	// POLICY-phase companion to permissions_->check() (tasks.md 6.6): a
	// no-op (ok_status()) when metrics_ is null; otherwise calls
	// metrics_->fixed_value() once for EXTERNAL_METRIC_MASS_CAPACITY_BONUS
	// and propagates a non-OK result verbatim so the caller rejects BEFORE
	// STRUCTURAL/FEATURE/SIMULATE, exactly like a PermissionProvider
	// rejection. This slice does not read the resolved value into any
	// constraint (see core/inv_authority_interfaces.h's doc comment).
	Status check_external_metrics(const CommandHeader &p_header) const;
	Status check_structural(const InventoryRuntime &p_inventory, const Command &p_command) const;
	Status check_feature_constraints(const InventoryRuntime &p_inventory, const Command &p_command) const;
	// Applies p_command to p_clone via InventoryRuntime's public mutation
	// primitives (or swap_items()/release_item_subtree()/
	// adopt_item_subtree() for DropItemCommand). On success appends exactly
	// one TransactionEvent to r_result.events, fills whichever of r_result's
	// command-specific fields (new_item_id, new_reference_id, dropped_items,
	// dropped_external_owner) the command produced (leaving every other such
	// field at its default), and appends this command's complete canonical
	// delta ops for p_clone's own inventory to r_ops (tasks.md 5.1
	// DELTA-EMISSION; core/inv_deltas.h) -- built from p_clone's
	// post-mutation state, never r_result, so ops always carry complete
	// after-state values. dispatch_single() wraps r_ops into the single
	// InventoryDelta it appends to r_result.deltas once predecessor/successor
	// revisions are known (only simulate() sees clone state per-mutation;
	// only dispatch_single() sees the eventual commit revisions). Never
	// touches r_result.accepted/status/revisions/deltas itself -- dispatch_
	// single() owns those.
	Status simulate(InventoryRuntime &p_clone, const Command &p_command, TransactionResult &r_result, std::vector<DeltaOp> &r_ops) const;

	// Command-specific handlers for the four multi-inventory command types.
	// Each resolves its touched InventoryId set, delegates the shared
	// resolve/revision/authority/policy/clone setup to prepare_multi(), runs
	// its own RESOLVE/STRUCTURAL/FEATURE/SIMULATE against the returned
	// clones, then delegates INVARIANT/COMMIT/RESULT/NOTIFY/idempotency to
	// finish_multi(). p_payload_fingerprint is precomputed once by
	// dispatch_multi() (which already needed it for the idempotency
	// short-circuit) and threaded through for the eventual
	// record_idempotency() call in finish_multi().
	TransactionResult run_loot(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const LootItemCommand &p_command, std::uint64_t p_payload_fingerprint);
	TransactionResult run_settle(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const SettleInventoryCommand &p_command, std::uint64_t p_payload_fingerprint);
	TransactionResult run_quick_transfer(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const QuickTransferItemCommand &p_command, std::uint64_t p_payload_fingerprint);
	TransactionResult run_targeted_provider_transfer(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const TargetedProviderTransferCommand &p_command, std::uint64_t p_payload_fingerprint);
	Status simulate_targeted_provider_transfer(
			InventoryRuntime &p_source_clone,
			InventoryRuntime &p_destination_clone,
			const TargetedProviderTransferCommand &p_command,
			TransactionResult &r_result,
			std::map<InventoryId, std::vector<DeltaOp>> &r_ops_by_inventory,
			ContainerInstanceId &r_destination_container) const;

	// Shared RESOLVE(touched-set)/REVISION/POLICY phase plus clone setup for
	// a multi-inventory command. p_touched_raw need not be sorted or
	// deduplicated. On success (return value ok()), r_touched/r_runtimes/
	// r_clones are parallel vectors in canonical ascending-InventoryId order
	// and r_result.revisions already carries one (predecessor==successor==
	// current) entry per touched inventory; the caller continues with its
	// own command-specific RESOLVE/STRUCTURAL/FEATURE/SIMULATE against
	// r_clones. On rejection (return value not ok()), r_result.revisions
	// (and, for a REVISION_MISMATCH, conflicting_inventory/
	// authoritative_revision) are already populated but accepted/status are
	// NOT set and observers are NOT notified -- the caller must still call
	// reject(r_result, <the returned status>) itself, exactly like every
	// other phase check in this pipeline.
	Status prepare_multi(
			const std::vector<InventoryRuntime *> &p_inventories,
			const CommandHeader &p_header,
			const Command &p_command,
			std::vector<InventoryId> p_touched_raw,
			std::vector<InventoryId> &r_touched,
			std::vector<InventoryRuntime *> &r_runtimes,
			std::vector<InventoryRuntime> &r_clones,
			TransactionResult &r_result) const;

	// Shared INVARIANT/COMMIT/RESULT/NOTIFY/idempotency tail for a
	// multi-inventory command that has already fully validated and mutated
	// r_clones. r_result must already carry accepted=false and one
	// revisions[] entry (predecessor==current) per touched inventory (as
	// prepare_multi() leaves it); on success this overwrites accepted/
	// status/revisions[].successor_revision, builds r_result.deltas (one
	// InventoryDelta per p_touched entry, in the same canonical order, each
	// wrapping p_ops_by_inventory[touched-id] -- an inventory the caller
	// touched but recorded no ops for gets an InventoryDelta with empty ops
	// rather than being skipped, so `deltas` and `revisions` always stay the
	// same length in the same order), and records idempotency once
	// (command-scoped, not per-inventory).
	TransactionResult finish_multi(
			const std::vector<InventoryId> &p_touched,
			const std::vector<InventoryRuntime *> &p_runtimes,
			std::vector<InventoryRuntime> &p_clones,
			const CommandHeader &p_header,
			std::uint64_t p_payload_fingerprint,
			TransactionResult r_result,
			std::map<InventoryId, std::vector<DeltaOp>> p_ops_by_inventory);

	// Shared rejection shape for both dispatch_single() and the
	// multi-inventory handlers: sets accepted=false, clears events, notifies
	// observers, and returns. r_result must already carry command_id and
	// its (possibly empty) revisions[].
	TransactionResult reject(TransactionResult p_result, Status p_status) const;

	void record_idempotency(CommandId p_command_id, std::uint64_t p_payload_fingerprint, const TransactionResult &p_result);
	void notify(const TransactionResult &p_result) const;

	const DefinitionCatalog *catalog_;
	const PermissionProvider *permissions_;
	const ExternalMetricProvider *metrics_;
	const PreparedQuantityReservations *quantity_reservations_;
	std::size_t idempotency_capacity_;
	std::map<CommandId, IdempotencyRecord> idempotency_index_;
	// Insertion (== acceptance) order, oldest first. record_idempotency()
	// evicts idempotency_order_.front() before inserting once size() would
	// exceed idempotency_capacity_ -- FIFO by acceptance order, not by
	// CommandId numeric order.
	std::deque<CommandId> idempotency_order_;
	std::vector<std::pair<std::uint64_t, Observer>> observers_;

	// Reentrancy guard (tasks.md 5.9). executing_ is true for the entire
	// duration of the outermost submit() call, including its drain loop, so
	// every nested reentrant submit() (however deep) enqueues into the SAME
	// pending_ FIFO instead of recursing -- see submit()'s .cpp comment.
	bool executing_ = false;
	std::deque<PendingSubmission> pending_;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_TRANSACTION_H
