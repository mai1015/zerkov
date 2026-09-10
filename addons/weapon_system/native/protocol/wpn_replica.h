#ifndef WEAPON_SYSTEM_PROTOCOL_REPLICA_H
#define WEAPON_SYSTEM_PROTOCOL_REPLICA_H

#include "core/wpn_limits.h"
#include "core/wpn_runtime.h"
#include "core/wpn_status.h"
#include "protocol/wpn_command_gate.h"
#include "protocol/wpn_protocol_types.h"

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

// Snapshot/delta convergence state machine (tasks.md 7.4; weapon-protocol
// spec, "Snapshot and Delta Convergence"). Two independent, deterministic,
// engine-free, socket-free halves:
//
//   - WeaponReplica: the CLIENT side. Applies authoritative snapshots/deltas
//     and rejects a delta whose baseline does not match its own confirmed
//     revision rather than guessing (mirrors
//     addons/inventory_system/native/protocol/inv_replica.h's
//     InventoryReplica -- see that file's structural precedent). Role
//     separation is STRUCTURAL: WeaponReplica has no WeaponRuntime member
//     and no command-accepting method, so there is no way to mistakenly
//     mutate canonical state from a replica.
//   - DeltaAcknowledgementTracker: the AUTHORITY side's bounded baseline
//     bookkeeping (weapon-protocol spec: "ordered revisioned deltas with
//     baseline acknowledgement"). Records, per (peer, instance), the highest
//     revision that peer has confirmed applying, so an authority-side
//     WeaponNetworkBridge (tasks.md 7.5, out of this slice's scope) can
//     decide whether a delta is safe to send against that peer's known
//     baseline or whether a full snapshot is required instead.
namespace wpn::protocol {

// ---------------------------------------------------------------------------
// WeaponReplica (client side)
// ---------------------------------------------------------------------------

// Bounded observer-event vocabulary, mirroring inv_replica.h's
// ReplicaEventKind. Every listener callback receives only value args --
// listener code cannot see or mutate this replica's canonical storage.
enum class ReplicaEventKind : std::uint8_t {
	DELTA_APPLIED = 1, // One WeaponDelta applied (lifecycle == ACTIVE). Args: (instance_id, successor_revision).
	SNAPSHOT_REPLACED = 2, // apply_snapshot()/apply_snapshot_batch()/replace_from_snapshot_batch() succeeded for this instance. Args: (instance_id, revision).
	RESYNC_NEEDED = 3, // apply_delta() detected a gap or impossible transition. Args: (instance_id, last_applied_revision AT THE TIME OF DETECTION).
	// tasks.md 7.9 (weapon-protocol spec: "lifecycle/tombstone state").
	// apply_tombstone(), apply_snapshot_batch()/replace_from_snapshot_batch()
	// (for a batch's `tombstones` entries), or apply_delta() (lifecycle ==
	// TOMBSTONED) succeeded for this instance. Args: (instance_id, revision).
	// This is the terminal state: no further DELTA_APPLIED/SNAPSHOT_REPLACED
	// event fires for the same instance_id unless a later trusted snapshot
	// replacement (apply_snapshot()/replace_from_snapshot_batch()) revives it
	// under a fresh authority_epoch.
	INSTANCE_TOMBSTONED = 4,
};

class WeaponReplica {
public:
	using Listener = std::function<void(ReplicaEventKind, const std::string &, std::uint64_t)>;

	WeaponReplica() = default;

	// nullptr if untracked OR the instance is tombstoned (a tombstoned
	// instance has no live snapshot -- see find_tombstone() below).
	const WeaponSnapshot *find(const std::string &p_instance_id) const;
	// tasks.md 7.9. nullptr unless the instance is currently tombstoned.
	const WeaponTombstone *find_tombstone(const std::string &p_instance_id) const;
	bool is_tombstoned(const std::string &p_instance_id) const; // false if untracked.
	std::uint64_t last_applied_revision(const std::string &p_instance_id) const; // 0 if untracked.
	// tasks.md 7.9 (weapon-protocol spec, "Snapshot restores recoil and
	// ammunition profile": "... and sequence baseline"). The admitted
	// command-sequence high-watermark carried by the last live WeaponSnapshot
	// applied for this instance (apply_snapshot()/apply_snapshot_batch()/
	// replace_from_snapshot_batch()) or the last ACTIVE WeaponDelta applied
	// via apply_delta() -- 0 if untracked, tombstoned, or never populated by
	// the authority. A client-side bridge uses this (together with
	// last_applied_revision()) as the baseline it reports back in a
	// DeltaAcknowledgement, so authority's per-peer bookkeeping (protocol/
	// wpn_command_gate.h's CommandSequenceTracker) can safely evict cached
	// duplicate-outcome history the peer has already moved past.
	std::uint64_t sequence_baseline(const std::string &p_instance_id) const;
	bool needs_resync(const std::string &p_instance_id) const; // false if untracked.
	std::vector<std::string> tracked_instance_ids() const;

	// Atomic single-instance full-snapshot replacement (weapon-protocol
	// spec, "Client joins late"). On success: last_applied_revision()
	// becomes p_snapshot.revision, needs_resync() clears, and the listener
	// (if set) fires exactly one SNAPSHOT_REPLACED event -- never a replayed
	// per-transition event for the state the snapshot brought in. Fails
	// (state for this instance completely untouched) if
	// wpn::validate_identifier(p_snapshot.instance_id) fails. If this
	// instance_id was previously tombstoned, this REVIVES it (clears
	// is_tombstoned(), find_tombstone() returns nullptr again) -- a trusted
	// live snapshot for an instance_id always means "this is the current
	// live truth", whatever this replica previously believed, matching
	// core::WeaponRuntime::create_instance() being able to reuse an
	// instance_id under a fresh authority_epoch after a prior teardown.
	Status apply_snapshot(const WeaponSnapshot &p_snapshot);

	// tasks.md 7.9 (weapon-protocol spec: "lifecycle/tombstone state").
	// Atomic single-instance tombstone application: marks p_tombstone's
	// instance_id terminal (is_tombstoned() becomes true, find() becomes
	// nullptr, find_tombstone() returns p_tombstone), sets
	// last_applied_revision() to p_tombstone.revision, clears needs_resync(),
	// and fires exactly one INSTANCE_TOMBSTONED event. Fails (state for this
	// instance completely untouched) if
	// wpn::validate_identifier(p_tombstone.instance_id) fails.
	Status apply_tombstone(const WeaponTombstone &p_tombstone);

	// Applies every snapshot in p_batch.snapshots via apply_snapshot()
	// semantics, THEN every tombstone in p_batch.tombstones via
	// apply_tombstone() semantics, both additively -- instances already
	// tracked but absent from p_batch are left untouched. Used for late join
	// / partial resync response. Stops and returns the first failing entry's
	// Status; entries applied before the failure remain applied (each
	// apply_snapshot()/apply_tombstone() call is itself atomic per-instance).
	Status apply_snapshot_batch(const WeaponSnapshotBatch &p_batch);

	// Reconnect replacement (weapon-protocol spec: "replace old-epoch state
	// from a fresh authoritative snapshot"): atomically discards EVERY
	// currently-tracked instance (live or tombstoned) and replaces this
	// replica's entire state with exactly p_batch's contents (its
	// `snapshots` become live tracked instances, its `tombstones` become
	// tombstoned tracked instances). Unlike apply_snapshot_batch(), an
	// instance this replica knew about that is absent from BOTH lists is
	// dropped (it fires no event -- only SNAPSHOT_REPLACED per surviving/new
	// live instance and INSTANCE_TOMBSTONED per surviving/new tombstoned
	// instance in p_batch). On ANY entry's validation failure (including the
	// same instance_id appearing in both `snapshots` and `tombstones`), this
	// replica's state is left completely untouched (validated as a candidate
	// replacement map first, swapped in only on full success). This is the
	// epoch-replacement path: a fresh authoritative snapshot's
	// WeaponSnapshot::authority_epoch simply flows through as part of the
	// wholesale replacement, so a reconnecting client that receives a new
	// epoch for an instance never needs special-case handling here -- the
	// entire tracked instance is replaced, not merged.
	Status replace_from_snapshot_batch(const WeaponSnapshotBatch &p_batch);

	// Ordered delta application (weapon-protocol spec, "Delta is lost").
	// Checked in this exact order (first match wins):
	//   1. Structural precondition, lifecycle-dependent: if
	//      p_delta.lifecycle == ACTIVE, p_delta.snapshot.revision must equal
	//      p_delta.successor_revision; if TOMBSTONED,
	//      p_delta.tombstone must be present and
	//      p_delta.tombstone->revision must equal p_delta.successor_revision.
	//      Violated -> a structurally malformed delta: StatusCode::
	//      INVALID_ARGUMENT / DiagnosticId::VALUE_OUT_OF_RANGE, state
	//      completely untouched, no resync flagged (this is an input-shape
	//      violation, not a convergence gap).
	//   2. p_delta.successor_revision <= last_applied_revision(instance) ->
	//      DUPLICATE: state unchanged, returns a non-fatal
	//      OK/REPLICA_DUPLICATE_DELTA status.
	//   3. needs_resync(instance) is already true -> state unchanged (still
	//      waiting on a snapshot), returns
	//      SNAPSHOT_REQUIRED/REPLICA_REVISION_GAP without re-notifying.
	//   4. p_delta.predecessor_revision > last_applied_revision(instance) ->
	//      GAP: needs_resync(instance) becomes true, fires RESYNC_NEEDED,
	//      returns SNAPSHOT_REQUIRED/REPLICA_REVISION_GAP.
	//   5. p_delta.predecessor_revision == last_applied_revision(instance)
	//      -> applies: if lifecycle == ACTIVE, p_delta.snapshot (already the
	//      complete successor state -- a delta simply carries the full
	//      post-state rather than a per-field op list, see
	//      wpn_protocol_types.h's WeaponDelta doc comment) REPLACES this
	//      instance's tracked state outright and fires DELTA_APPLIED; if
	//      lifecycle == TOMBSTONED, p_delta.tombstone REPLACES this
	//      instance's tracked state with a terminal one (matching
	//      apply_tombstone()) and fires INSTANCE_TOMBSTONED instead. Returns
	//      ok_status() either way.
	//   6. Otherwise (predecessor strictly older, successor strictly newer
	//      than current -- an impossible transition) ->
	//      SNAPSHOT_REQUIRED/REPLICA_IMPOSSIBLE_TRANSITION, same handling as
	//      case 4.
	Status apply_delta(const WeaponDelta &p_delta);

	ResyncRequest make_resync_request(const std::string &p_instance_id) const;

	// Every currently-tracked instance with needs_resync() == true, in
	// tracked-instance canonical (map) order -- ready to hand to a bridge
	// for a bounded batch of resync requests.
	std::vector<ResyncRequest> pending_resync_requests() const;

	// p_listener may be empty (the default) to detach; setting a new
	// listener discards the previous one. Exactly one listener slot: a
	// replica has exactly one consumer by construction.
	void set_listener(Listener p_listener);

private:
	struct InstanceState {
		WeaponSnapshot snapshot; // meaningful iff !tombstoned.
		std::uint64_t last_applied_revision = 0;
		bool needs_resync = false;
		// tasks.md 7.9. When true, `snapshot` is stale/meaningless and
		// `tombstone` names this instance's terminal state instead.
		bool tombstoned = false;
		std::optional<WeaponTombstone> tombstone; // meaningful iff tombstoned.
	};

	void notify(ReplicaEventKind p_kind, const std::string &p_instance_id, std::uint64_t p_detail_revision) const;

	std::map<std::string, InstanceState> instances;
	Listener listener_;
};

// ---------------------------------------------------------------------------
// DeltaAcknowledgementTracker (authority side)
// ---------------------------------------------------------------------------

// Bounded per-(peer, instance) "highest revision this peer has confirmed
// applying" bookkeeping. Reuses protocol/wpn_command_gate.h's PeerId. Never
// itself decides whether to send a delta or a snapshot -- that policy call
// belongs to a later WeaponNetworkBridge (tasks.md 7.5); this class only
// tracks the input that decision needs.
class DeltaAcknowledgementTracker {
public:
	// Advances the tracked acknowledgement for (p_peer, p_instance_id) to
	// p_revision if it is higher than what is already recorded (an
	// out-of-order/stale acknowledgement arriving late is simply ignored,
	// never regresses the tracked baseline). Bounded by
	// MAX_TRACKED_COMMAND_STATES total records, evicting the
	// least-recently-touched (peer, instance) pair.
	void record_acknowledgement(PeerId p_peer, const std::string &p_instance_id, std::uint64_t p_revision);

	// The highest acknowledged revision for (p_peer, p_instance_id), or 0 if
	// no acknowledgement has ever been recorded for that pair.
	std::uint64_t acknowledged_revision(PeerId p_peer, const std::string &p_instance_id) const;

	// Forgets every acknowledgement recorded for p_peer (disconnect/epoch
	// change -- a reconnected peer's baseline must be re-established, e.g.
	// from its next DeltaAcknowledgement or a fresh snapshot handshake).
	void drop_peer(PeerId p_peer);

	// Forgets every peer's acknowledgement for p_instance_id (teardown/
	// tombstone).
	void drop_instance(const std::string &p_instance_id);

	std::size_t tracked_record_count() const { return records.size(); }

private:
	struct Key {
		PeerId peer = INVALID_PEER_ID;
		std::string instance_id;
		bool operator<(const Key &p_other) const {
			if (peer != p_other.peer) {
				return peer < p_other.peer;
			}
			return instance_id < p_other.instance_id;
		}
	};
	struct Record {
		std::uint64_t revision = 0;
		std::uint64_t touch_seq = 0;
	};

	std::uint64_t next_touch() { return ++touch_counter; }
	void enforce_cap();

	std::map<Key, Record> records; // bounded by MAX_TRACKED_COMMAND_STATES.
	std::uint64_t touch_counter = 0;
};

} // namespace wpn::protocol

#endif // WEAPON_SYSTEM_PROTOCOL_REPLICA_H
