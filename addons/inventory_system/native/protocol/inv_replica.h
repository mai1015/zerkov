#ifndef INVENTORY_SYSTEM_PROTOCOL_REPLICA_H
#define INVENTORY_SYSTEM_PROTOCOL_REPLICA_H

#include "core/inv_catalog.h"
#include "core/inv_deltas.h"
#include "core/inv_identity_authority.h"
#include "core/inv_ids.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"
#include "protocol/inv_protocol_types.h"
#include "protocol/inv_observer_protocol.h"

#include <cstdint>
#include <functional>

// Remote-client-side state holder (tasks.md 6.4/6.5; inventory-protocol
// spec, "Ordered Authoritative Deltas" / "Canonical Full Snapshots and
// Resynchronization"). Role separation is STRUCTURAL, not a runtime flag
// (design.md "Godot façade and authoring": "A remote replica cannot invoke
// canonical mutation methods"): InventoryReplica has no
// InventoryTransactionPipeline member, no Command-accepting method, and no
// way to reach one -- there is no method here to forget to guard. A game's
// bridge submits intent to a SEPARATE authority-side pipeline (offline or
// server) and feeds this class only the resulting DeltaBatch/
// SnapshotEnvelope it already produced; §7's Godot façade will surface this
// same boundary as an explicit role enum on top, but the boundary already
// exists at this C++ type's shape.
namespace inv::protocol {

// Bounded observer-event vocabulary (tasks.md 6.4/6.5's "minimal observer
// hook"). Every listener callback receives ONLY value args (never a mutable
// runtime reference), mirroring core::InventoryTransactionPipeline::Observer
// -- listener code cannot see or mutate this replica's canonical storage any
// more than a transaction observer can see a pipeline's.
enum class ReplicaEventKind : std::uint8_t {
	DELTA_APPLIED = 1, // One accepted InventoryDelta applied. Args: (inventory, successor_revision).
	SNAPSHOT_REPLACED = 2, // apply_snapshot() succeeded; the ONLY event fired for a snapshot -- never a per-item/per-op event (inventory-protocol spec: "does not replay historical one-shot transaction hooks"). Args: (inventory, revision).
	RESYNC_NEEDED = 3, // apply_delta() detected a gap or impossible transition and set needs_resync(). Args: (inventory, last_applied_revision AT THE TIME OF DETECTION).
};

class InventoryReplica {
public:
	using Listener = std::function<void(ReplicaEventKind, InventoryId, std::uint64_t)>;

	InventoryReplica() = default;

	InventoryId id() const { return inventory_.id(); }
	std::uint64_t last_applied_revision() const { return last_applied_revision_; }
	bool needs_resync() const { return needs_resync_; }
	const InventoryRuntime &inventory() const { return inventory_; }

	// Atomic full-snapshot replacement (inventory-protocol spec, "Canonical
	// Full Snapshots and Resynchronization"). Delegates to core::restore()
	// (defensive candidate build against p_catalog; this replica's own
	// IdentityAuthority is passed through so its allocator counters
	// converge -- see restore_from_snapshot_parts()'s doc comment). On ANY
	// failure this replica's state (inventory, last_applied_revision(),
	// needs_resync()) is completely untouched. On success:
	// last_applied_revision() becomes p_envelope.snapshot.revision,
	// needs_resync() clears, and the listener (if set) fires EXACTLY ONE
	// SNAPSHOT_REPLACED event -- covering both "resync after a gap" and
	// "fresh/late-join replica" the same way, since neither ever replays a
	// per-item/per-op event for the state the snapshot brought in.
	Status apply_snapshot(const DefinitionCatalog &p_catalog, const SnapshotEnvelope &p_envelope);

	// Ordered delta application (inventory-protocol spec, "Ordered
	// Authoritative Deltas"). Checked in this exact order (first match
	// wins):
	//   1. p_delta.successor_revision <= last_applied_revision() -> DUPLICATE:
	//      state completely unchanged, returns a non-fatal
	//      OK/REPLICA_DUPLICATE_DELTA status (mirrors TransactionResult's own
	//      OK/DUPLICATE_RESULT_REPLAY precedent for "successfully a no-op").
	//   2. needs_resync() is already true -> state unchanged (still waiting
	//      on a snapshot), returns SNAPSHOT_REQUIRED/REPLICA_REVISION_GAP
	//      without re-notifying (RESYNC_NEEDED already fired once, when the
	//      flag first became true).
	//   3. p_delta.predecessor_revision > last_applied_revision() -> GAP:
	//      needs_resync() becomes true, fires RESYNC_NEEDED, returns
	//      SNAPSHOT_REQUIRED/REPLICA_REVISION_GAP.
	//   4. p_delta.predecessor_revision == last_applied_revision() -> applies
	//      every op in order onto a CLONE of this replica's runtime (using
	//      an isolated scratch IdentityAuthority so a mid-sequence failure
	//      cannot leave this replica's REAL allocator counters advanced --
	//      see inv_replica.cpp), then audits the clone's invariants. On
	//      success: swaps the clone in, sets last_applied_revision() to the
	//      delta's declared successor_revision, fires DELTA_APPLIED, returns
	//      ok_status(). On ANY op or audit failure: this replica's state is
	//      completely untouched, needs_resync() becomes true, fires
	//      RESYNC_NEEDED, returns SNAPSHOT_REQUIRED with the failing op's/
	//      audit's own diagnostic preserved as detail (StatusCode is
	//      normalized to SNAPSHOT_REQUIRED either way -- an impossible
	//      transition can only be cured by a full snapshot, never retried).
	//   5. Otherwise (predecessor_revision < last_applied_revision(), and,
	//      having already failed check 1, successor_revision strictly newer
	//      than last_applied_revision()) -> IMPOSSIBLE TRANSITION: same
	//      handling as a failed apply in (4):
	//      SNAPSHOT_REQUIRED/REPLICA_IMPOSSIBLE_TRANSITION.
	Status apply_delta(const InventoryDelta &p_delta);

	ResyncRequest make_resync_request() const;

	// p_listener may be empty (the default) to detach; setting a new
	// listener discards the previous one. Exactly one listener slot: a
	// replica has exactly one consumer by construction (unlike
	// InventoryTransactionPipeline::add_observer()'s multi-owner registry),
	// so no owner key is needed.
	void set_listener(Listener p_listener);

private:
	Status apply_ops(InventoryRuntime &r_clone, const InventoryDelta &p_delta) const;
	void notify(ReplicaEventKind p_kind, std::uint64_t p_detail_revision) const;

	InventoryRuntime inventory_;
	IdentityAuthority authority_;
	std::uint64_t last_applied_revision_ = 0;
	bool needs_resync_ = false;
	Listener listener_;
};

// Recipient-only value replica.  This is intentionally a separate class,
// not a visibility mode on InventoryReplica: it owns no InventoryRuntime,
// IdentityAuthority, catalog restore path, or canonical mutation primitive.
// The only state it can install is an already-redacted ObserverSnapshot value
// and its replacement-view successors.
class InventoryObserverReplica {
public:
	using Listener = std::function<void(ReplicaEventKind, InventoryId, std::uint64_t)>;

	InventoryObserverReplica() = default;

	// The complete recipient/inventory/visibility tuple is mandatory before any
	// packet is accepted and is immutable for the replica lifetime.
	Status configure_stream(
			DiscoveryRecipientKey p_recipient,
			InventoryId p_inventory,
			VisibilityScope p_visibility);
	bool stream_configured() const { return stream_configured_; }
	DiscoveryRecipientKey recipient() const { return recipient_; }
	bool initialized() const { return initialized_; }
	InventoryId id() const { return InventoryId{ view_.inventory_id }; }
	std::uint64_t generation() const { return view_.generation; }
	std::uint64_t last_applied_sequence() const { return view_.sequence; }
	VisibilityScope visibility() const { return view_.visibility; }
	bool needs_resync() const { return needs_resync_; }
	const ObserverSnapshot &view() const { return view_; }

	Status apply_snapshot(const DefinitionCatalog &p_catalog, const ObserverSnapshotEnvelope &p_envelope);
	Status apply_delta(const DefinitionCatalog &p_catalog, const ObserverDeltaEnvelope &p_envelope);
	ObserverResyncRequest make_resync_request() const;

	void set_listener(Listener p_listener);

private:
	Status validate_packet(const DefinitionCatalog &p_catalog, const ObserverSnapshot &p_snapshot,
			const DiscoveryRecipientKey &p_recipient) const;
	void notify(ReplicaEventKind p_kind, std::uint64_t p_detail_sequence) const;

	DiscoveryRecipientKey recipient_;
	InventoryId expected_inventory_;
	VisibilityScope expected_visibility_ = VisibilityScope::OBSERVER;
	bool stream_configured_ = false;
	bool initialized_ = false;
	bool needs_resync_ = false;
	ObserverSnapshot view_;
	Listener listener_;
};

// Short name used by native callers and tests; the long name remains the
// explicit public contract for code that wants to emphasize the role split.
using ObserverReplica = InventoryObserverReplica;

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_REPLICA_H
