#ifndef GAMEPLAY_ABILITIES_CORE_TRANSACTION_H
#define GAMEPLAY_ABILITIES_CORE_TRANSACTION_H

#include "core/ga_ids.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"

#include <cstddef>
#include <functional>
#include <vector>

// Every mutation in this addon goes through a `Transaction`: all of its
// changes commit together or none do, and observers only ever see state
// after a successful commit, never mid-transaction.
//
// Design choice -- std::function undo-list over a TransactionParticipant
// interface: subsystems in this addon (tags, attributes, effects, abilities)
// model runtime state as plain value records and stable handles rather than
// polymorphic objects (see design.md, "Stable identities and immutable
// definitions"). Requiring every subsystem to define and register a class
// implementing a shared virtual interface would add an indirection layer the
// rest of the addon deliberately avoids. A bounded vector of closures gives
// the identical guarantee -- all-or-nothing undo, deferred notification --
// with less boilerplate, and it keeps `Transaction` itself free of any
// subsystem-specific type. Both lists are capped (see `MAX_TRANSACTION_UNDO_OPS`
// / `MAX_TRANSACTION_NOTIFICATIONS` below) so one transaction cannot grow
// without bound.
namespace ga {

// Soft, addon-internal bounds (not part of the wire contract -- see
// ga_limits.h for those). They exist only so a single transaction cannot
// accumulate unbounded memory.
//
// Task 11.10: MAX_TRANSACTION_UNDO_OPS/MAX_TRANSACTION_NOTIFICATIONS are
// deliberately set to MAX_TAG_SOURCES (512, ga_limits.h) rather than some
// smaller "typical batch" size. `TagContainer::apply_mutations` registers
// exactly one undo closure AND, for every op that actually changes state,
// one notification per op (ga_tag_container.cpp) -- both against the SAME
// `ga::Transaction` for the whole batch. Before this change both caps were
// 256, which meant a single batch attempting to fill a container from empty
// to MAX_TAG_SOURCES (512) failed closed with CAPACITY_EXCEEDED at the
// halfway point, even though 512 is the documented per-container maximum:
// reaching it required silently splitting into >= 2 batches, a requirement
// nothing on `TagContainer::apply_mutations` stated. Raising both caps to
// match MAX_TAG_SOURCES makes the honest, simpler property hold instead: the
// largest per-container maximum this addon defines today is reachable in
// exactly the "one atomic batch" shape the API's own doc comment describes,
// with no undocumented multi-call choreography required. This is a purely
// addon-internal bound (see above) -- raising it does not touch the wire
// contract or `GA_PROTOCOL_VERSION`. See budgets.md and
// `budget_tags_single_transaction_batch_reaches_max_tag_sources` in
// ga_test_budgets.cpp.
constexpr std::size_t MAX_TRANSACTION_UNDO_OPS = 512;
constexpr std::size_t MAX_TRANSACTION_NOTIFICATIONS = 512;
constexpr std::size_t MAX_QUEUED_NOTIFICATIONS = 512;
constexpr std::size_t MAX_PENDING_MUTATION_REQUESTS = 64;
constexpr std::size_t MAX_NOTIFICATION_HOLD_DEPTH = 8;

// Buffers immutable change-record dispatch until after a transaction
// commits, and separates any mutation requested *during* that dispatch into
// a distinct pending-request list so it is never applied reentrantly.
//
// Usage: a subsystem's listener-notification code runs inside `dispatch()`.
// If that code wants to request a further mutation, it must check
// `is_dispatching()` first; if true, it defers the request through
// `request_mutation()` instead of mutating state inline. A higher-level
// driver (owned by later sections) periodically drains
// `take_pending_requests()` and processes each one as its own new
// transaction, never inside `dispatch()`.
class NotificationQueue {
public:
	// Queues one already-committed change record's dispatch closure. Called
	// by `Transaction::commit()`; callers should not normally call this
	// directly. Bounded by `MAX_QUEUED_NOTIFICATIONS`.
	Status enqueue(std::function<void()> p_record);

	// Runs every buffered record, in the order they were enqueued (which is
	// commit order, and within a commit, canonical order -- the caller is
	// responsible for enqueuing records in that order). Reentrant calls
	// (i.e. calling dispatch() again while already dispatching) are a no-op:
	// dispatch() is never called recursively by this class itself, but a
	// defensive guard is kept here since callers must never observe partial
	// re-entrant dispatch.
	void dispatch();

	// True for the duration of `dispatch()`. Subsystems check this to decide
	// whether to mutate state immediately (safe -- not dispatching) or defer
	// through `request_mutation()` (required -- currently dispatching).
	bool is_dispatching() const { return dispatching; }

	// Queues a mutation request for later, out-of-band processing. Always
	// defers regardless of `is_dispatching()`, so callers that always route
	// through this method never need to special-case "not dispatching" --
	// only `is_dispatching()` decides whether they must. Bounded by
	// `MAX_PENDING_MUTATION_REQUESTS`.
	Status request_mutation(std::function<void()> p_request);

	// Drains and returns every pending mutation request accumulated since
	// the last call. The caller processes each as a separate later
	// transaction.
	std::vector<std::function<void()>> take_pending_requests();

	// Cross-component prepared batches hold publication on every
	// participant until all participants have committed. Holds may nest;
	// commit only removes the current marker, while rollback discards every
	// record/request added since that marker. `dispatch()` is a no-op while
	// any hold is active.
	Status begin_hold();
	Status commit_hold();
	Status rollback_hold();
	bool is_holding() const { return !hold_markers.empty(); }
	bool current_hold_changed() const {
		return !hold_markers.empty() &&
				(pending_records.size() != hold_markers.back().record_count ||
						pending_requests.size() !=
								hold_markers.back().request_count);
	}
	bool can_enqueue(std::size_t p_count) const {
		return p_count <= MAX_QUEUED_NOTIFICATIONS - pending_records.size();
	}

	bool empty() const { return pending_records.empty(); }
	std::size_t pending_request_count() const { return pending_requests.size(); }

private:
	struct HoldMarker {
		std::size_t record_count = 0;
		std::size_t request_count = 0;
	};

	std::vector<std::function<void()>> pending_records;
	std::vector<std::function<void()>> pending_requests;
	std::vector<HoldMarker> hold_markers;
	bool dispatching = false;
};

// One atomic mutation. Subsystems apply their state changes as they go
// (optimistically) and register how to undo each one via `add_undo`; if
// anything later in the same transaction fails, `rollback()` unwinds every
// registered undo in reverse order, restoring exactly the pre-transaction
// state. On success, `commit()` hands the transaction's notification
// closures to a `NotificationQueue` for deferred, post-commit dispatch.
//
// Never throws: every failure path is reported through `Status` (see
// `fail()`/`failed()`), matching the rest of this addon's core boundary.
class Transaction {
public:
	Transaction(TransactionId p_id, Tick p_tick) :
			transaction_id(p_id), applies_at_tick(p_tick) {}

	TransactionId id() const { return transaction_id; }
	Tick tick() const { return applies_at_tick; }

	// Registers an undo closure invoked, in LIFO (reverse-registration)
	// order, if this transaction rolls back. Fails with
	// `StatusCode::CAPACITY_EXCEEDED` past `MAX_TRANSACTION_UNDO_OPS`.
	Status add_undo(std::function<void()> p_undo);

	// Registers a change-record dispatch closure, run only after a
	// successful commit (see `commit()`). Callers must register these in
	// canonical order themselves; `Transaction` does not reorder them. Fails
	// with `StatusCode::CAPACITY_EXCEEDED` past `MAX_TRANSACTION_NOTIFICATIONS`.
	Status add_notification(std::function<void()> p_notify);

	// Marks the transaction as failed with `p_status`. `commit()` will then
	// behave as `rollback()`. Idempotent: the first status recorded wins.
	void fail(Status p_status);

	bool failed() const { return !failure.ok(); }
	Status failure_status() const { return failure; }
	std::size_t notification_count() const { return notify_ops.size(); }

	// If `failed()`, rolls back and returns the recorded failure `Status`.
	// Otherwise hands every registered notification to `p_queue` (which
	// dispatches them later, never synchronously here) and clears both the
	// undo and notification lists.
	Status commit(NotificationQueue &p_queue);

	// Runs every undo closure in reverse registration order, then clears
	// both lists without ever dispatching a notification.
	void rollback();

private:
	TransactionId transaction_id;
	Tick applies_at_tick = 0;
	std::vector<std::function<void()>> undo_ops;
	std::vector<std::function<void()>> notify_ops;
	Status failure;
};

// RAII helper: commits `p_transaction` into `p_queue` when the scope ends
// normally, or rolls it back if `fail()` was called first (or if the
// transaction was already `failed()` for any other reason). Move-only by
// virtue of being non-copyable; there is exactly one owner per transaction.
class TransactionScope {
public:
	TransactionScope(Transaction &p_transaction, NotificationQueue &p_queue) :
			transaction(&p_transaction), queue(&p_queue) {}

	TransactionScope(const TransactionScope &) = delete;
	TransactionScope &operator=(const TransactionScope &) = delete;

	~TransactionScope() {
		if (!finished) {
			finish();
		}
	}

	void fail(Status p_status) { transaction->fail(p_status); }

	// Explicit early finish, for callers that want the resulting `Status`
	// before the scope's destructor runs. Safe to call at most once; later
	// calls (including the implicit one in the destructor) are a no-op.
	Status finish() {
		if (finished) {
			return ok_status();
		}
		finished = true;
		if (transaction->failed()) {
			transaction->rollback();
			return transaction->failure_status();
		}
		return transaction->commit(*queue);
	}

private:
	Transaction *transaction;
	NotificationQueue *queue;
	bool finished = false;
};

// Monotonic revision, bumped exactly once per commit that changes the state
// it is attached to. Tags, attributes, and effects each keep one of these so
// readers can detect "did this change since I last looked" without
// comparing full state.
class RevisionCounter {
public:
	std::uint64_t value = 0;
	void bump() { ++value; }
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TRANSACTION_H
