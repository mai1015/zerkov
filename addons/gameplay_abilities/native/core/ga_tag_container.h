#ifndef GAMEPLAY_ABILITIES_CORE_TAG_CONTAINER_H
#define GAMEPLAY_ABILITIES_CORE_TAG_CONTAINER_H

#include "core/ga_ids.h"
#include "core/ga_snapshot.h"
#include "core/ga_status.h"
#include "core/ga_tags.h"
#include "core/ga_transaction.h"

#include <cstdint>
#include <functional>
#include <map>
#include <set>
#include <vector>

// Per-owner (component/entity) gameplay-tag ownership, ref-counted by stable
// `SourceToken` so two independent grantors of the same tag cannot remove each
// other's grant. All mutation goes through `apply_mutations`, which uses
// `ga::Transaction` exactly the way `ga_transaction.h` documents: state is
// applied optimistically with an `add_undo` closure per change, and change
// records are handed to a `ga::NotificationQueue` for post-commit dispatch --
// by the time any listener runs, the container already reflects the full,
// final batch, never a partially-applied one.
//
// -----------------------------------------------------------------------
// Transaction participation (read this before calling anything below --
// mirrors `AttributeSet`, see ga_attribute_state.h)
// -----------------------------------------------------------------------
// `apply_mutations`/`add_tag`/`remove_tag` each come in two shapes:
//
//   1. `(..., Transaction &p_txn, NotificationQueue &p_queue, ...)` -- the
//      PRIMARY API. Exactly like `AttributeSet::add_modifier`/`set_base`, it
//      mutates this container optimistically and registers its own undo and
//      notification closures onto the CALLER's `p_txn`. The caller decides
//      when to commit or roll back (typically via `TransactionScope`), so
//      this container's changes commit or roll back together with whatever
//      else -- attribute modifiers, active-effect bookkeeping, lifecycle
//      events -- the caller is mutating in the SAME transaction. This is the
//      overload every composed subsystem (`EffectRuntime`, `AbilityComponent`)
//      uses, and it is why granting/removing tags no longer needs to be
//      ordered "last": a later failure anywhere else in the shared
//      transaction now undoes a tag mutation just as completely as it undoes
//      an attribute modifier.
//
//   2. `(..., Tick p_tick, TransactionId p_transaction_id, NotificationQueue
//      &p_queue, ...)` -- a CONVENIENCE overload, kept only for a genuinely
//      standalone caller (a test driving a bare `TagContainer`, or a direct
//      API user with no other state to keep in lockstep). It builds and
//      commits (or rolls back) its OWN single-use `Transaction` before
//      returning. Do NOT use this overload from inside code that is already
//      composing a larger transaction -- its mutation can never be undone by
//      an outer transaction once it returns `ok()`, which is exactly the bug
//      this shape used to cause here (see design.md / the effects agent's
//      history in ga_effect_runtime.h) before the Transaction&-taking
//      overload existed.
//
// A `TagContainer` holds a non-owning pointer to the sealed `TagRegistry` that
// defines its universe of tags; the registry must outlive the container.
namespace ga {

// One tag-ownership mutation requested as part of an atomic batch.
struct TagMutationOp {
	enum class Kind : std::uint8_t {
		ADD = 0,
		REMOVE = 1,
	};

	Kind kind = Kind::ADD;
	DefinitionId tag = INVALID_DEFINITION_ID;
	SourceToken source;
};

// One immutable, already-committed ownership change, reported to listeners
// strictly after the owning transaction commits. `owner_count_after` and
// `revision_after` reflect the container's state once the *entire* batch that
// produced this record has been applied -- not an intermediate state within
// the batch -- so every record from one batch agrees on `revision_after`.
struct TagChangeRecord {
	DefinitionId tag = INVALID_DEFINITION_ID;
	SourceToken source;
	bool added = false; // true = this source's grant was added, false = removed
	std::uint32_t owner_count_after = 0;
	std::uint64_t revision_after = 0;
};

using TagChangeListener = std::function<void(const TagChangeRecord &)>;
using TagListenerId = std::uint64_t;
constexpr TagListenerId INVALID_TAG_LISTENER_ID = 0;

class TagContainer {
public:
	explicit TagContainer(const TagRegistry &p_registry) :
			registry(&p_registry) {}

	// Registers a listener invoked once per emitted `TagChangeRecord`, in
	// canonical order (see `apply_mutations`), during `NotificationQueue::dispatch()`.
	// A listener must never mutate this container synchronously -- see the
	// reentrancy rule on `apply_mutations` -- it must route any further
	// mutation through `NotificationQueue::request_mutation` instead.
	TagListenerId add_listener(TagChangeListener p_listener);
	void remove_listener(TagListenerId p_id);

	// Applies one atomic batch of add/remove requests, participating in the
	// CALLER-SUPPLIED `p_txn` exactly like `AttributeSet::add_modifier` (see
	// the class file comment): ops are applied optimistically in order, each
	// registering its own undo onto `p_txn`; the first invalid op fails
	// `p_txn` and returns that failure (no partial mutation -- the caller's
	// `TransactionScope` unwinds this container's changes along with
	// everything else registered on `p_txn`). An empty batch is a no-op:
	// no state change, no notifications, no revision bump.
	//
	// Fails (whole batch, no partial effect once `p_txn` rolls back) with:
	//   - `StatusCode::UNKNOWN_TAG` / detail = tag id, if an op names a
	//     `DefinitionId` the registry does not recognize.
	//   - `StatusCode::UNKNOWN_TAG_SOURCE` / detail = tag id, if a REMOVE names
	//     a `(tag, source)` pair that is not currently owned -- counts and
	//     revision are left completely unchanged (see spec "Unknown source
	//     attempts removal").
	//   - `StatusCode::CAPACITY_EXCEEDED` if an ADD would create a new
	//     `(tag, source)` ownership record past `MAX_TAG_SOURCES`, or if
	//     registering this batch's undo/notification onto `p_txn` would
	//     exceed `MAX_TRANSACTION_UNDO_OPS`/`MAX_TRANSACTION_NOTIFICATIONS`.
	// A redundant ADD (the same source already owns the tag) is accepted as a
	// no-op: it neither changes state nor produces a change record.
	//
	// On success, change records are built from the *final* post-batch state,
	// sorted into canonical order `(DefinitionId, SourceToken)` (matching the
	// addon-wide `(..., definition id, runtime handle, ...)` ordering rule),
	// and registered as `p_txn`'s notifications -- so, once the CALLER commits
	// `p_txn`, `NotificationQueue::dispatch()` delivers them to listeners in
	// that same order. If `r_records` is not null, it receives the same
	// records (mainly for tests) regardless of whether `p_txn` has committed
	// yet.
	Status apply_mutations(const std::vector<TagMutationOp> &p_ops, Transaction &p_txn, NotificationQueue &p_queue, std::vector<TagChangeRecord> *r_records = nullptr);

	// Convenience one-op batches, participating in `p_txn` -- see above.
	Status add_tag(SourceToken p_source, DefinitionId p_tag, Transaction &p_txn, NotificationQueue &p_queue);
	Status remove_tag(SourceToken p_source, DefinitionId p_tag, Transaction &p_txn, NotificationQueue &p_queue);

	// ---------------------------------------------------------------
	// Standalone convenience overloads -- see the class file comment's
	// "Transaction participation" section, shape 2. Each builds and commits
	// (or rolls back) its own single-use `Transaction` around the identical
	// logic the `Transaction&` overloads above use, so a genuinely standalone
	// caller does not need to construct a `Transaction`/`TransactionScope`
	// itself. Never call one of these from code that is already composing a
	// larger transaction -- its mutation cannot be rolled back by that outer
	// transaction once this call returns `ok()`.
	// ---------------------------------------------------------------
	Status apply_mutations(const std::vector<TagMutationOp> &p_ops, Tick p_tick, TransactionId p_transaction_id, NotificationQueue &p_queue, std::vector<TagChangeRecord> *r_records = nullptr);
	Status add_tag(SourceToken p_source, DefinitionId p_tag, Tick p_tick, TransactionId p_transaction_id, NotificationQueue &p_queue);
	Status remove_tag(SourceToken p_source, DefinitionId p_tag, Tick p_tick, TransactionId p_transaction_id, NotificationQueue &p_queue);

	// Exact ownership: true only if `p_tag` itself has at least one owning
	// source. Never satisfied by an owned ancestor or descendant.
	bool has_exact(DefinitionId p_tag) const;

	// Parent-aware ownership: true if `p_tag` itself, or any tag registered as
	// a descendant of it, has at least one owning source. Backed by a derived
	// index (`parent_aware_counts`) updated within the same transaction as the
	// exact counts, so this is O(1) rather than a scan.
	bool has_parent_aware(DefinitionId p_tag) const;

	// Number of distinct sources exactly owning `p_tag` (0 if unowned).
	std::uint32_t owner_count(DefinitionId p_tag) const;

	// Every exactly-owned tag, ascending `DefinitionId` (canonical order).
	std::vector<DefinitionId> owned_tags() const;

	std::uint64_t revision() const { return revision_counter.value; }
	std::size_t source_record_count() const { return total_source_records; }

	// Canonical snapshot: independent of insertion order and of any hash-table
	// iteration -- see the .cpp for the exact section layout. Two containers
	// that reached equivalent ownership through different histories serialize
	// to identical bytes and digests, since both are built from the container's
	// (sorted-map-derived) *current* state alone.
	Status write_snapshot(SnapshotWriter &p_writer) const;

	// Fully replaces this container's ownership, revision, and derived index
	// with the snapshot's content -- not a mutating transaction, so it never
	// runs through `NotificationQueue` and never emits intermediate (or final)
	// change records. Fails closed (leaving this container unchanged) on any
	// malformed, out-of-order, duplicate, or unknown-tag entry; input is
	// treated as untrusted.
	Status restore_snapshot(SnapshotReader &p_reader);

	// Same section shape `write_snapshot` writes (identical
	// `SECTION_TAG_CONTAINER` framing and canonical `(tag, source)` order,
	// decodable by the SAME `restore_snapshot`), restricted to `(tag,
	// source)` pairs for which `p_is_public(tag)` returns true. Used by the
	// delta codec's (add-granular-delta-replication-2026-07-27, task 2.1)
	// PUBLIC-audience `DeltaSectionMode::FULL_REENCODE` fallback --
	// `write_snapshot()` itself stays the OWNER-audience fallback,
	// unfiltered.
	Status write_snapshot_filtered(SnapshotWriter &p_writer, const std::function<bool(DefinitionId)> &p_is_public) const;

	// Every currently owned `(source, tag)` pair, ascending `SourceToken` --
	// the TAG_SOURCE section's per-record content this codec's delta encoder
	// needs to answer "does this source currently own a tag, and which one"
	// without a linear scan of `exact_owners` per identity.
	std::map<SourceToken, DefinitionId> all_source_records() const;

	// Task 2.1's per-record delta body for the TAG_SOURCE section: a tag
	// ownership record's entire content beyond its own stable identity
	// (`SourceToken`, carried by the delta envelope itself, never repeated
	// here) is which tag it owns -- so this writes exactly that one
	// `DefinitionId`, the SAME value `write_snapshot`'s own flat
	// `(tag, source)` pair list would carry for this source. There is no
	// UPDATE case for this section (see `ga_change_tracking.h`'s
	// `DirtyRecord` doc comment: a `SourceToken` is minted once per grant and
	// never changes which tag it owns), but this codec still applies
	// `DeltaOpKind::ADD`/`UPDATE` identically -- see that enum's own comment.
	Status write_tag_source_delta_record(SnapshotWriter &p_writer, DefinitionId p_tag) const;

	// Decodes one record `write_tag_source_delta_record` wrote WITHOUT
	// touching live state -- fails closed on an unregistered tag, matching
	// `restore_snapshot`'s own validation.
	Status decode_tag_source_delta_record(SnapshotReader &p_reader, DefinitionId &r_tag) const;

	// The pure-decode half of `restore_snapshot`: reads and validates a
	// COMPLETE `SECTION_TAG_CONTAINER` section into `r_owners`/`r_revision`
	// WITHOUT installing anything -- `restore_snapshot` itself is just this
	// call followed by `install_records`. The delta codec's
	// `DeltaSectionMode::FULL_REENCODE` apply path
	// (`AbilityComponent::apply_delta_batch`, ga_ability_component.cpp)
	// calls this directly so a full-reencode section decodes into a local
	// temporary just like a RECORD_OPS section does.
	Status decode_snapshot_section(SnapshotReader &p_reader, std::map<DefinitionId, std::set<SourceToken>> &r_owners, std::uint64_t &r_revision) const;

	// Replaces this container's ENTIRE ownership, revision, and derived
	// index from already-validated, already-decoded content -- the shared
	// install tail `restore_snapshot` and the delta codec's
	// `AbilityComponent::apply_delta_batch` (ga_ability_component.cpp) both
	// converge on. Trusts `p_owners` completely; never called directly on
	// untrusted input.
	void install_records(std::map<DefinitionId, std::set<SourceToken>> p_owners, std::uint64_t p_revision);

private:
	// Applies every op in `p_ops` against `p_txn` in order, appending each
	// one that actually changed state to `r_applied`. The first invalid op
	// fails `p_txn` (see `apply_add`/`apply_remove`) and returns that
	// failure immediately -- shared by both the `Transaction&` and
	// standalone-convenience `apply_mutations` overloads above.
	Status apply_ops(const std::vector<TagMutationOp> &p_ops, Transaction &p_txn, std::vector<TagMutationOp> &r_applied);
	Status apply_one(const TagMutationOp &p_op, Transaction &p_txn, std::vector<TagMutationOp> &r_applied);
	// Each fails (and calls `p_txn.fail()`) closed on its own validation
	// error, and also on `p_txn.add_undo()` itself failing (transaction-wide
	// undo cap reached) -- in the latter case it reverts its own just-applied
	// local mutation before returning, so it never leaves a trace behind an
	// undo that was never actually registered. Mirrors
	// `AttributeSet::add_modifier`'s identical local-revert pattern.
	Status apply_add(DefinitionId p_tag, SourceToken p_source, Transaction &p_txn, std::vector<TagMutationOp> &r_applied);
	Status apply_remove(DefinitionId p_tag, SourceToken p_source, Transaction &p_txn, std::vector<TagMutationOp> &r_applied);
	void adjust_ancestor_index(DefinitionId p_tag, bool p_increment);
	void dispatch_record(TagChangeRecord p_record) const;

	// Builds the (definition id, source) canonically sorted change records
	// for one batch's applied ops, all sharing `p_new_revision`. Shared by
	// both `apply_mutations` overloads.
	std::vector<TagChangeRecord> build_change_records(const std::vector<TagMutationOp> &p_applied, std::uint64_t p_new_revision) const;

	const TagRegistry *registry = nullptr;

	// tag -> owning sources, both levels sorted (std::map/std::set), never an
	// unordered_map. A tag is only ever present here while its owner set is
	// non-empty.
	std::map<DefinitionId, std::set<SourceToken>> exact_owners;
	// tag-or-registered-descendant id -> number of exactly-owned tags whose
	// ancestor chain (inclusive of itself) includes that id. Only present
	// while > 0.
	std::map<DefinitionId, std::uint32_t> parent_aware_counts;
	std::size_t total_source_records = 0;

	RevisionCounter revision_counter;

	std::map<TagListenerId, TagChangeListener> listeners; // ascending = registration order
	TagListenerId next_listener_id = INVALID_TAG_LISTENER_ID;
};

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_TAG_CONTAINER_H
