#include "protocol/wpn_command_gate.h"

#include "core/wpn_hash.h"

#include <algorithm>

namespace wpn::protocol {

// ---------------------------------------------------------------------------
// WeaponOwnershipTable
// ---------------------------------------------------------------------------

void WeaponOwnershipTable::enforce_peer_cap() {
	if (peers.size() <= MAX_TRACKED_PEERS) {
		return;
	}
	auto oldest = peers.begin();
	for (auto it = peers.begin(); it != peers.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	peers.erase(oldest);
}

Status WeaponOwnershipTable::begin_session(PeerId p_peer, SessionId p_session, ConnectionEpoch p_epoch) {
	if (p_session == INVALID_SESSION_ID || p_epoch == INVALID_CONNECTION_EPOCH) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
	}
	PeerRecord &record = peers[p_peer];
	record.session = p_session;
	record.epoch = p_epoch;
	record.compatibility_ready = false;
	record.touch_seq = next_touch();
	enforce_peer_cap();
	return ok_status();
}

void WeaponOwnershipTable::end_session(PeerId p_peer) {
	auto it = peers.find(p_peer);
	if (it == peers.end()) {
		return;
	}
	it->second.session = INVALID_SESSION_ID;
	it->second.epoch = INVALID_CONNECTION_EPOCH;
	it->second.compatibility_ready = false;
}

Status WeaponOwnershipTable::validate_session(PeerId p_peer, SessionId p_session) const {
	auto it = peers.find(p_peer);
	if (it == peers.end() || it->second.session == INVALID_SESSION_ID || it->second.session != p_session) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_UNKNOWN, static_cast<std::uint64_t>(p_session));
	}
	return ok_status();
}

Status WeaponOwnershipTable::validate_connection_epoch(PeerId p_peer, ConnectionEpoch p_epoch) const {
	auto it = peers.find(p_peer);
	if (it == peers.end() || it->second.epoch == INVALID_CONNECTION_EPOCH || it->second.epoch != p_epoch) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::CONNECTION_EPOCH_STALE, static_cast<std::uint64_t>(p_epoch));
	}
	return ok_status();
}

void WeaponOwnershipTable::mark_compatibility_ready(PeerId p_peer) {
	auto it = peers.find(p_peer);
	if (it == peers.end()) {
		return;
	}
	it->second.compatibility_ready = true;
	it->second.touch_seq = next_touch();
}

bool WeaponOwnershipTable::is_compatibility_ready(PeerId p_peer) const {
	auto it = peers.find(p_peer);
	return it != peers.end() && it->second.compatibility_ready;
}

Status WeaponOwnershipTable::validate_compatibility_ready(PeerId p_peer) const {
	if (!is_compatibility_ready(p_peer)) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::CONTENT_NOT_READY, 0);
	}
	return ok_status();
}

Status WeaponOwnershipTable::authorize_instance(PeerId p_peer, const std::string &p_instance_id, WeaponRole p_role) {
	PeerRecord &record = peers[p_peer];
	if (record.instances.find(p_instance_id) == record.instances.end() &&
			record.instances.size() >= MAX_BOUND_INSTANCES_PER_PEER) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, record.instances.size() + 1);
	}
	record.instances[p_instance_id] = p_role;
	record.touch_seq = next_touch();
	enforce_peer_cap();
	return ok_status();
}

Status WeaponOwnershipTable::revoke_instance(PeerId p_peer, const std::string &p_instance_id) {
	auto it = peers.find(p_peer);
	if (it == peers.end() || it->second.instances.erase(p_instance_id) == 0) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, 0);
	}
	return ok_status();
}

Status WeaponOwnershipTable::validate_binding(PeerId p_peer, const std::string &p_instance_id, WeaponRole p_required_role) const {
	auto it = peers.find(p_peer);
	if (it == peers.end()) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::ACTOR_BINDING_DENIED, hash_string(p_instance_id));
	}
	auto instance_it = it->second.instances.find(p_instance_id);
	if (instance_it == it->second.instances.end()) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::ACTOR_BINDING_DENIED, hash_string(p_instance_id));
	}
	if (static_cast<std::uint8_t>(instance_it->second) < static_cast<std::uint8_t>(p_required_role)) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::ROLE_INSUFFICIENT, static_cast<std::uint64_t>(instance_it->second));
	}
	return ok_status();
}

void WeaponOwnershipTable::drop_peer(PeerId p_peer) {
	peers.erase(p_peer);
}

std::size_t WeaponOwnershipTable::bound_instance_count(PeerId p_peer) const {
	auto it = peers.find(p_peer);
	return it == peers.end() ? 0 : it->second.instances.size();
}

// ---------------------------------------------------------------------------
// CommandSequenceTracker
// ---------------------------------------------------------------------------

void CommandSequenceTracker::enforce_instance_cap() {
	if (instances.size() <= MAX_TRACKED_COMMAND_STATES) {
		return;
	}
	auto oldest = instances.begin();
	for (auto it = instances.begin(); it != instances.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	instances.erase(oldest);
}

CommandSequenceTracker::SequenceOutcome CommandSequenceTracker::check(
		const std::string &p_instance_id, const std::string &p_command_id,
		std::uint64_t p_sequence, std::uint64_t p_payload_hash, Status &r_replay_status) {
	r_replay_status = ok_status();

	auto it = instances.find(p_instance_id);
	if (it == instances.end()) {
		// Never tracked this instance before: anything is fresh.
		return SequenceOutcome::EXECUTE;
	}

	InstanceState &state = it->second;
	state.touch_seq = next_touch();

	auto cache_it = state.replay_cache.find(p_command_id);
	if (cache_it != state.replay_cache.end()) {
		if (cache_it->second.payload_hash != p_payload_hash) {
			return SequenceOutcome::CONFLICT;
		}
		r_replay_status = cache_it->second.result;
		return SequenceOutcome::DUPLICATE;
	}

	if (p_sequence <= state.watermark) {
		return SequenceOutcome::STALE;
	}

	return SequenceOutcome::EXECUTE;
}

void CommandSequenceTracker::record(
		const std::string &p_instance_id, const std::string &p_command_id,
		std::uint64_t p_sequence, std::uint64_t p_payload_hash, const Status &p_result) {
	InstanceState &state = instances[p_instance_id];
	if (p_sequence > state.watermark) {
		state.watermark = p_sequence;
	}
	if (state.replay_cache.find(p_command_id) == state.replay_cache.end()) {
		state.replay_order.push_back(p_command_id);
	}
	state.replay_cache[p_command_id] = RecordedCommand{ p_payload_hash, p_result };
	while (state.replay_cache.size() > MAX_DUPLICATE_RESULT_CACHE && !state.replay_order.empty()) {
		state.replay_cache.erase(state.replay_order.front());
		state.replay_order.pop_front();
	}
	state.touch_seq = next_touch();
	enforce_instance_cap();
}

void CommandSequenceTracker::drop_instance(const std::string &p_instance_id) {
	instances.erase(p_instance_id);
}

// ---------------------------------------------------------------------------
// RateLimiter
// ---------------------------------------------------------------------------

Status RateLimiter::try_admit(TokenBucket &r_bucket, std::uint64_t p_now, std::uint64_t p_window_ticks, std::uint32_t p_capacity) {
	if (p_window_ticks == 0 || p_capacity == 0) {
		// Defensive only: p_tick_rate defaults to DEFAULT_TICK_RATE and
		// MAX_COMMANDS_PER_SECOND/MAX_RESYNCS_PER_MINUTE are nonzero
		// compile-time constants, so this path means a caller passed an
		// explicit zero tick rate. Fail closed rather than divide by zero or
		// admit unconditionally.
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, p_window_ticks);
	}

	if (!r_bucket.initialized) {
		// Start full: an initial burst up to capacity is allowed so a freshly
		// connected peer is not throttled before it has sent anything.
		r_bucket.credit_ticks = p_window_ticks;
		r_bucket.last_tick = p_now;
		r_bucket.initialized = true;
	} else if (p_now > r_bucket.last_tick) {
		const std::uint64_t elapsed = p_now - r_bucket.last_tick;
		r_bucket.credit_ticks = std::min(p_window_ticks, r_bucket.credit_ticks + elapsed);
		r_bucket.last_tick = p_now;
	}
	// p_now <= r_bucket.last_tick (tick did not advance, or a caller passed a
	// non-monotonic value): no additional credit is granted, but this is not
	// itself an error -- ticks are supplied by the caller and are never
	// trusted to be strictly increasing.

	// Cost of one admission, rounded UP so this limiter is never more
	// permissive than its nominal per-window capacity.
	const std::uint64_t cost = (p_window_ticks + p_capacity - 1) / p_capacity;
	if (r_bucket.credit_ticks < cost) {
		return make_status(StatusCode::RATE_LIMITED, DiagnosticId::COMMAND_RATE_EXCEEDED, r_bucket.credit_ticks);
	}
	r_bucket.credit_ticks -= cost;
	return ok_status();
}

void RateLimiter::enforce_cap(std::map<PeerId, TokenBucket> &r_buckets, std::size_t p_limit) {
	if (r_buckets.size() <= p_limit) {
		return;
	}
	auto oldest = r_buckets.begin();
	for (auto it = r_buckets.begin(); it != r_buckets.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	r_buckets.erase(oldest);
}

Status RateLimiter::admit_command(PeerId p_peer, std::uint64_t p_now_tick, std::uint32_t p_tick_rate) {
	TokenBucket &bucket = command_buckets[p_peer];
	const std::uint32_t rate = (p_tick_rate == 0) ? DEFAULT_TICK_RATE : p_tick_rate;
	const std::uint64_t window_ticks = static_cast<std::uint64_t>(rate); // one second.
	const Status status = try_admit(bucket, p_now_tick, window_ticks, MAX_COMMANDS_PER_SECOND);
	bucket.touch_seq = next_touch();
	enforce_cap(command_buckets, MAX_RATE_LIMIT_BUCKETS);
	return status;
}

Status RateLimiter::admit_resync(PeerId p_peer, std::uint64_t p_now_tick, std::uint32_t p_tick_rate) {
	TokenBucket &bucket = resync_buckets[p_peer];
	const std::uint32_t rate = (p_tick_rate == 0) ? DEFAULT_TICK_RATE : p_tick_rate;
	const std::uint64_t window_ticks = static_cast<std::uint64_t>(rate) * 60; // one minute.
	const Status status = try_admit(bucket, p_now_tick, window_ticks, MAX_RESYNCS_PER_MINUTE);
	bucket.touch_seq = next_touch();
	enforce_cap(resync_buckets, MAX_RATE_LIMIT_BUCKETS);
	return status;
}

void RateLimiter::drop_peer(PeerId p_peer) {
	command_buckets.erase(p_peer);
	resync_buckets.erase(p_peer);
}

// ---------------------------------------------------------------------------
// Free functions
// ---------------------------------------------------------------------------

Status validate_payload_size(std::size_t p_bytes) {
	if (p_bytes > MAX_COMMAND_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes);
	}
	return ok_status();
}

// ---------------------------------------------------------------------------
// WeaponCommandGate
// ---------------------------------------------------------------------------

Status WeaponCommandGate::admit(const InboundWeaponCommandContext &p_context, WeaponRole p_required_role, InboundCommandVerdict &r_verdict) {
	r_verdict = InboundCommandVerdict{};

	auto reject = [&](const Status &p_status) -> Status {
		r_verdict.kind = CommandOutcomeKind::REJECTED;
		r_verdict.status = p_status;
		return p_status;
	};

	// 1. session readiness.
	const Status session_status = ownership.validate_session(p_context.peer, p_context.session);
	if (!session_status.ok()) {
		return reject(session_status);
	}

	// 2. owner + 3. actor binding + 4. role.
	const Status binding_status = ownership.validate_binding(p_context.peer, p_context.instance_id, p_required_role);
	if (!binding_status.ok()) {
		return reject(binding_status);
	}

	// 5. connection epoch.
	const Status epoch_status = ownership.validate_connection_epoch(p_context.peer, p_context.epoch);
	if (!epoch_status.ok()) {
		return reject(epoch_status);
	}

	// 6. monotonic command sequence + 7. idempotent command identity.
	Status replay_status = ok_status();
	const CommandSequenceTracker::SequenceOutcome seq_outcome = sequence.check(
			p_context.instance_id, p_context.command_id, p_context.sequence, p_context.payload_hash, replay_status);
	if (seq_outcome == CommandSequenceTracker::SequenceOutcome::STALE) {
		return reject(make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::SEQUENCE_STALE, p_context.sequence));
	}
	if (seq_outcome == CommandSequenceTracker::SequenceOutcome::CONFLICT) {
		return reject(make_status(StatusCode::DUPLICATE_CONFLICT, DiagnosticId::COMMAND_DUPLICATE_CONFLICT, 0));
	}
	if (seq_outcome == CommandSequenceTracker::SequenceOutcome::DUPLICATE) {
		// Not a rejection: an ack/reject was likely lost and the client
		// legitimately resent.
		r_verdict.kind = CommandOutcomeKind::DUPLICATE_REPLAY;
		r_verdict.status = replay_status;
		return ok_status();
	}

	// 8. payload size.
	const Status size_status = validate_payload_size(p_context.payload_bytes);
	if (!size_status.ok()) {
		return reject(size_status);
	}

	// 9. content compatibility.
	const Status compat_status = ownership.validate_compatibility_ready(p_context.peer);
	if (!compat_status.ok()) {
		return reject(compat_status);
	}

	// 10. command rate.
	const Status rate_status = rate.admit_command(p_context.peer, p_context.current_tick, p_context.tick_rate);
	if (!rate_status.ok()) {
		return reject(rate_status);
	}

	r_verdict.kind = CommandOutcomeKind::EXECUTE;
	r_verdict.status = ok_status();
	return ok_status();
}

} // namespace wpn::protocol
