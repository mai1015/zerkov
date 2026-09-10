#include "protocol/wpn_replica.h"

#include "core/wpn_identifier.h"

#include <utility>

namespace wpn::protocol {

// ---------------------------------------------------------------------------
// WeaponReplica
// ---------------------------------------------------------------------------

void WeaponReplica::notify(ReplicaEventKind p_kind, const std::string &p_instance_id, std::uint64_t p_detail_revision) const {
	if (listener_) {
		listener_(p_kind, p_instance_id, p_detail_revision);
	}
}

void WeaponReplica::set_listener(Listener p_listener) {
	listener_ = std::move(p_listener);
}

const WeaponSnapshot *WeaponReplica::find(const std::string &p_instance_id) const {
	auto it = instances.find(p_instance_id);
	if (it == instances.end() || it->second.tombstoned) {
		return nullptr;
	}
	return &it->second.snapshot;
}

const WeaponTombstone *WeaponReplica::find_tombstone(const std::string &p_instance_id) const {
	auto it = instances.find(p_instance_id);
	if (it == instances.end() || !it->second.tombstoned) {
		return nullptr;
	}
	return &*it->second.tombstone;
}

bool WeaponReplica::is_tombstoned(const std::string &p_instance_id) const {
	auto it = instances.find(p_instance_id);
	return it != instances.end() && it->second.tombstoned;
}

std::uint64_t WeaponReplica::last_applied_revision(const std::string &p_instance_id) const {
	auto it = instances.find(p_instance_id);
	return it == instances.end() ? 0 : it->second.last_applied_revision;
}

std::uint64_t WeaponReplica::sequence_baseline(const std::string &p_instance_id) const {
	auto it = instances.find(p_instance_id);
	if (it == instances.end() || it->second.tombstoned) {
		return 0;
	}
	return it->second.snapshot.admitted_sequence_high_watermark;
}

bool WeaponReplica::needs_resync(const std::string &p_instance_id) const {
	auto it = instances.find(p_instance_id);
	return it != instances.end() && it->second.needs_resync;
}

std::vector<std::string> WeaponReplica::tracked_instance_ids() const {
	std::vector<std::string> ids;
	ids.reserve(instances.size());
	for (const auto &entry : instances) {
		ids.push_back(entry.first);
	}
	return ids;
}

Status WeaponReplica::apply_snapshot(const WeaponSnapshot &p_snapshot) {
	Status status = validate_identifier(p_snapshot.instance_id);
	if (!status.ok()) {
		return status;
	}
	InstanceState state;
	state.snapshot = p_snapshot;
	state.last_applied_revision = p_snapshot.revision;
	state.needs_resync = false;
	state.tombstoned = false;
	state.tombstone.reset();
	instances[p_snapshot.instance_id] = std::move(state);
	notify(ReplicaEventKind::SNAPSHOT_REPLACED, p_snapshot.instance_id, p_snapshot.revision);
	return ok_status();
}

Status WeaponReplica::apply_tombstone(const WeaponTombstone &p_tombstone) {
	Status status = validate_identifier(p_tombstone.instance_id);
	if (!status.ok()) {
		return status;
	}
	InstanceState state;
	state.tombstoned = true;
	state.tombstone = p_tombstone;
	state.last_applied_revision = p_tombstone.revision;
	state.needs_resync = false;
	instances[p_tombstone.instance_id] = std::move(state);
	notify(ReplicaEventKind::INSTANCE_TOMBSTONED, p_tombstone.instance_id, p_tombstone.revision);
	return ok_status();
}

Status WeaponReplica::apply_snapshot_batch(const WeaponSnapshotBatch &p_batch) {
	for (const WeaponSnapshot &snapshot : p_batch.snapshots) {
		Status status = apply_snapshot(snapshot);
		if (!status.ok()) {
			return status;
		}
	}
	for (const WeaponTombstone &tombstone : p_batch.tombstones) {
		Status status = apply_tombstone(tombstone);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status WeaponReplica::replace_from_snapshot_batch(const WeaponSnapshotBatch &p_batch) {
	if (p_batch.snapshots.size() > MAX_SNAPSHOTS_PER_BATCH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_batch.snapshots.size());
	}
	if (p_batch.tombstones.size() > MAX_TOMBSTONES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_batch.tombstones.size());
	}
	std::map<std::string, InstanceState> replacement;
	for (const WeaponSnapshot &snapshot : p_batch.snapshots) {
		Status status = validate_identifier(snapshot.instance_id);
		if (!status.ok()) {
			return status;
		}
		InstanceState state;
		state.snapshot = snapshot;
		state.last_applied_revision = snapshot.revision;
		state.needs_resync = false;
		if (!replacement.emplace(snapshot.instance_id, std::move(state)).second) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::INSTANCE_DUPLICATE, 0);
		}
	}
	for (const WeaponTombstone &tombstone : p_batch.tombstones) {
		Status status = validate_identifier(tombstone.instance_id);
		if (!status.ok()) {
			return status;
		}
		InstanceState state;
		state.tombstoned = true;
		state.tombstone = tombstone;
		state.last_applied_revision = tombstone.revision;
		state.needs_resync = false;
		if (!replacement.emplace(tombstone.instance_id, std::move(state)).second) {
			// Also catches an instance_id present in both `snapshots` and
			// `tombstones` -- an authority MUST NOT declare an instance both
			// live and terminal in the same batch.
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::INSTANCE_DUPLICATE, 0);
		}
	}
	instances = std::move(replacement);
	for (const auto &entry : instances) {
		notify(entry.second.tombstoned ? ReplicaEventKind::INSTANCE_TOMBSTONED : ReplicaEventKind::SNAPSHOT_REPLACED,
				entry.first, entry.second.last_applied_revision);
	}
	return ok_status();
}

Status WeaponReplica::apply_delta(const WeaponDelta &p_delta) {
	// 1. Structural precondition, lifecycle-dependent (tasks.md 7.9): a
	// mismatch here is a malformed message, not a convergence gap, so it
	// never flags needs_resync.
	const bool tombstoning = p_delta.lifecycle == WeaponLifecycleState::TOMBSTONED;
	if (tombstoning) {
		if (!p_delta.tombstone.has_value() || p_delta.tombstone->revision != p_delta.successor_revision) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_delta.successor_revision);
		}
	} else if (p_delta.snapshot.revision != p_delta.successor_revision) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_delta.snapshot.revision);
	}

	const std::string &instance_id = tombstoning ? p_delta.tombstone->instance_id : p_delta.snapshot.instance_id;
	InstanceState &state = instances[instance_id]; // default-constructed (revision 0, no resync) if new.

	// 2. Duplicate: already-confirmed, ignored idempotently regardless of
	// needs_resync (a genuinely duplicate delta never needs a resync to
	// recognize).
	if (p_delta.successor_revision <= state.last_applied_revision) {
		return make_status(StatusCode::OK, DiagnosticId::REPLICA_DUPLICATE_DELTA, p_delta.successor_revision);
	}

	// 3. Already desynced: dependent deltas stop applying until a snapshot
	// resolves it. No re-notification -- RESYNC_NEEDED already fired once.
	if (state.needs_resync) {
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, p_delta.predecessor_revision);
	}

	// 4. Gap.
	if (p_delta.predecessor_revision > state.last_applied_revision) {
		state.needs_resync = true;
		notify(ReplicaEventKind::RESYNC_NEEDED, instance_id, state.last_applied_revision);
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, p_delta.predecessor_revision);
	}

	// 5. Matching predecessor: the delta already carries the complete
	// successor state, so applying it is a direct replacement -- no clone/
	// op-replay/audit is needed the way InventoryReplica's per-op delta
	// requires (see wpn_protocol_types.h's WeaponDelta doc comment). A
	// TOMBSTONED delta replaces this instance's tracked state with a
	// terminal one instead (tasks.md 7.9), mirroring apply_tombstone().
	if (p_delta.predecessor_revision == state.last_applied_revision) {
		if (tombstoning) {
			state.snapshot = WeaponSnapshot{};
			state.tombstoned = true;
			state.tombstone = *p_delta.tombstone;
			state.last_applied_revision = p_delta.successor_revision;
			state.needs_resync = false;
			notify(ReplicaEventKind::INSTANCE_TOMBSTONED, instance_id, state.last_applied_revision);
		} else {
			state.snapshot = p_delta.snapshot;
			state.tombstoned = false;
			state.tombstone.reset();
			state.last_applied_revision = p_delta.successor_revision;
			state.needs_resync = false;
			notify(ReplicaEventKind::DELTA_APPLIED, instance_id, state.last_applied_revision);
		}
		return ok_status();
	}

	// 6. Impossible transition: predecessor strictly older than current,
	// with a successor that (per check 2) is still strictly newer than
	// current -- a transition no ordered application can ever reach.
	state.needs_resync = true;
	notify(ReplicaEventKind::RESYNC_NEEDED, instance_id, state.last_applied_revision);
	return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_IMPOSSIBLE_TRANSITION, p_delta.predecessor_revision);
}

ResyncRequest WeaponReplica::make_resync_request(const std::string &p_instance_id) const {
	ResyncRequest request;
	request.instance_id = p_instance_id;
	request.last_applied_revision = last_applied_revision(p_instance_id);
	return request;
}

std::vector<ResyncRequest> WeaponReplica::pending_resync_requests() const {
	std::vector<ResyncRequest> requests;
	for (const auto &entry : instances) {
		if (entry.second.needs_resync) {
			requests.push_back(ResyncRequest{ entry.first, entry.second.last_applied_revision });
		}
	}
	return requests;
}

// ---------------------------------------------------------------------------
// DeltaAcknowledgementTracker
// ---------------------------------------------------------------------------

void DeltaAcknowledgementTracker::enforce_cap() {
	if (records.size() <= MAX_TRACKED_COMMAND_STATES) {
		return;
	}
	auto oldest = records.begin();
	for (auto it = records.begin(); it != records.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	records.erase(oldest);
}

void DeltaAcknowledgementTracker::record_acknowledgement(PeerId p_peer, const std::string &p_instance_id, std::uint64_t p_revision) {
	Record &record = records[Key{ p_peer, p_instance_id }];
	if (p_revision > record.revision) {
		record.revision = p_revision;
	}
	record.touch_seq = next_touch();
	enforce_cap();
}

std::uint64_t DeltaAcknowledgementTracker::acknowledged_revision(PeerId p_peer, const std::string &p_instance_id) const {
	auto it = records.find(Key{ p_peer, p_instance_id });
	return it == records.end() ? 0 : it->second.revision;
}

void DeltaAcknowledgementTracker::drop_peer(PeerId p_peer) {
	for (auto it = records.begin(); it != records.end();) {
		if (it->first.peer == p_peer) {
			it = records.erase(it);
		} else {
			++it;
		}
	}
}

void DeltaAcknowledgementTracker::drop_instance(const std::string &p_instance_id) {
	for (auto it = records.begin(); it != records.end();) {
		if (it->first.instance_id == p_instance_id) {
			it = records.erase(it);
		} else {
			++it;
		}
	}
}

} // namespace wpn::protocol
