#include "protocol/gap_command_gate.h"

#include <algorithm>

namespace ga::proto {

// ---------------------------------------------------------------------------
// CommandSequenceTracker
// ---------------------------------------------------------------------------

void CommandSequenceTracker::enforce_command_state_cap() {
	if (command_states.size() <= MAX_TRACKED_COMMAND_STATES) {
		return;
	}
	auto oldest = command_states.begin();
	for (auto it = command_states.begin(); it != command_states.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	command_states.erase(oldest);
}

void CommandSequenceTracker::enforce_prediction_session_cap() {
	if (prediction_states.size() <= MAX_TRACKED_PREDICTION_SESSIONS) {
		return;
	}
	auto oldest = prediction_states.begin();
	for (auto it = prediction_states.begin(); it != prediction_states.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	prediction_states.erase(oldest);
}

CommandSequenceTracker::SequenceOutcome CommandSequenceTracker::check_command_sequence(SessionId p_session, EntityId p_component, CommandSeq p_sequence, Status &r_replay_status) {
	r_replay_status = ok_status();

	if (p_sequence == INVALID_COMMAND_SEQ) {
		return SequenceOutcome::STALE;
	}

	const SessionComponentKey key{ p_session, p_component.value };
	auto it = command_states.find(key);
	if (it == command_states.end()) {
		// Never tracked this (session, component) pair before: anything is
		// fresh.
		return SequenceOutcome::EXECUTE;
	}

	CommandState &state = it->second;
	state.touch_seq = next_touch();

	auto cache_it = state.replay_cache.find(p_sequence.value);
	if (cache_it != state.replay_cache.end()) {
		r_replay_status = cache_it->second;
		return SequenceOutcome::DUPLICATE;
	}

	if (p_sequence.value <= state.watermark) {
		const std::uint64_t window_floor = (state.watermark > MAX_REORDER_WINDOW) ? (state.watermark - MAX_REORDER_WINDOW) : 0;
		if (p_sequence.value >= window_floor) {
			// In-window reorder, not a cached duplicate: treat as fresh.
			return SequenceOutcome::EXECUTE;
		}
		return SequenceOutcome::STALE;
	}

	return SequenceOutcome::EXECUTE;
}

void CommandSequenceTracker::record_command_result(SessionId p_session, EntityId p_component, CommandSeq p_sequence, const Status &p_result) {
	if (p_sequence == INVALID_COMMAND_SEQ) {
		return;
	}

	const SessionComponentKey key{ p_session, p_component.value };
	CommandState &state = command_states[key];
	if (p_sequence.value > state.watermark) {
		state.watermark = p_sequence.value;
	}
	state.replay_cache[p_sequence.value] = p_result;
	if (state.replay_cache.size() > MAX_DUPLICATE_RESULT_CACHE) {
		state.replay_cache.erase(state.replay_cache.begin());
	}
	state.touch_seq = next_touch();
	enforce_command_state_cap();
}

Status CommandSequenceTracker::claim_prediction_key(SessionId p_session, PredictionKey p_key) {
	if (p_key == INVALID_PREDICTION_KEY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
	}

	PredictionState &state = prediction_states[p_session];
	if (p_key.value <= state.evicted_floor ||
			state.claimed_keys.find(p_key.value) != state.claimed_keys.end()) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::NONE, p_key.value);
	}
	state.claimed_keys.insert(p_key.value);
	if (state.claimed_keys.size() > MAX_PREDICTION_KEYS_PER_SESSION) {
		const std::uint64_t evicted = *state.claimed_keys.begin();
		if (evicted > state.evicted_floor) {
			state.evicted_floor = evicted;
		}
		state.claimed_keys.erase(state.claimed_keys.begin());
	}
	state.touch_seq = next_touch();
	enforce_prediction_session_cap();
	return ok_status();
}

Status CommandSequenceTracker::validate_prediction_key(SessionId p_session, PredictionKey p_key) const {
	if (p_key == INVALID_PREDICTION_KEY) {
		return make_status(StatusCode::PREDICTION_UNKNOWN_KEY, DiagnosticId::NONE, 0);
	}
	auto it = prediction_states.find(p_session);
	if (it == prediction_states.end() || it->second.claimed_keys.find(p_key.value) == it->second.claimed_keys.end()) {
		return make_status(StatusCode::PREDICTION_UNKNOWN_KEY, DiagnosticId::NONE, p_key.value);
	}
	return ok_status();
}

void CommandSequenceTracker::drop_session(SessionId p_session) {
	for (auto it = command_states.begin(); it != command_states.end();) {
		if (it->first.session == p_session) {
			it = command_states.erase(it);
		} else {
			++it;
		}
	}
	prediction_states.erase(p_session);
}

// ---------------------------------------------------------------------------
// RateLimiter
// ---------------------------------------------------------------------------

Status RateLimiter::try_admit(TokenBucket &r_bucket, Tick p_now, std::uint64_t p_window_ticks, std::uint32_t p_capacity) {
	if (p_window_ticks == 0 || p_capacity == 0) {
		// Defensive only: a validated SessionTiming's tick_rate is always in
		// [MIN_TICK_RATE, MAX_TICK_RATE] and MAX_COMMANDS_PER_SECOND /
		// MAX_RESYNCS_PER_MINUTE are nonzero compile-time constants, so this
		// path means a caller bug, not real input. Fail closed rather than
		// divide by zero or admit unconditionally.
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, p_window_ticks);
	}

	if (!r_bucket.initialized) {
		// Start full: allow an initial burst up to capacity so a freshly
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
	// permissive than its nominal per-window capacity -- only ever stricter,
	// the safe direction for a rate limit under integer-only arithmetic.
	const std::uint64_t cost = (p_window_ticks + p_capacity - 1) / p_capacity;
	if (r_bucket.credit_ticks < cost) {
		return make_status(StatusCode::RATE_LIMITED, DiagnosticId::NONE, r_bucket.credit_ticks);
	}
	r_bucket.credit_ticks -= cost;
	return ok_status();
}

void RateLimiter::enforce_command_bucket_cap() {
	if (command_buckets.size() <= MAX_RATE_LIMIT_COMMAND_BUCKETS) {
		return;
	}
	auto oldest = command_buckets.begin();
	for (auto it = command_buckets.begin(); it != command_buckets.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	command_buckets.erase(oldest);
}

void RateLimiter::enforce_resync_bucket_cap() {
	if (resync_buckets.size() <= MAX_RATE_LIMIT_RESYNC_BUCKETS) {
		return;
	}
	auto oldest = resync_buckets.begin();
	for (auto it = resync_buckets.begin(); it != resync_buckets.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	resync_buckets.erase(oldest);
}

Status RateLimiter::admit_command(PeerId p_peer, EntityId p_component, Tick p_now, const SessionTiming &p_timing) {
	const PeerComponentKey key{ p_peer, p_component.value };
	TokenBucket &bucket = command_buckets[key];
	const std::uint32_t rate = (p_timing.tick_rate == 0) ? DEFAULT_TICK_RATE : p_timing.tick_rate;
	const std::uint64_t window_ticks = static_cast<std::uint64_t>(rate); // one second.
	const Status status = try_admit(bucket, p_now, window_ticks, MAX_COMMANDS_PER_SECOND);
	bucket.touch_seq = next_touch();
	enforce_command_bucket_cap();
	return status;
}

Status RateLimiter::admit_resync(PeerId p_peer, Tick p_now, const SessionTiming &p_timing) {
	TokenBucket &bucket = resync_buckets[p_peer];
	const std::uint32_t rate = (p_timing.tick_rate == 0) ? DEFAULT_TICK_RATE : p_timing.tick_rate;
	const std::uint64_t window_ticks = static_cast<std::uint64_t>(rate) * 60; // one minute.
	const Status status = try_admit(bucket, p_now, window_ticks, MAX_RESYNCS_PER_MINUTE);
	bucket.touch_seq = next_touch();
	enforce_resync_bucket_cap();
	return status;
}

void RateLimiter::drop_peer(PeerId p_peer) {
	for (auto it = command_buckets.begin(); it != command_buckets.end();) {
		if (it->first.peer == p_peer) {
			it = command_buckets.erase(it);
		} else {
			++it;
		}
	}
	resync_buckets.erase(p_peer);
}

// ---------------------------------------------------------------------------
// StrikePolicy / DefaultStrikePolicy
// ---------------------------------------------------------------------------

void DefaultStrikePolicy::enforce_cap() {
	if (peers.size() <= MAX_TRACKED_STRIKE_PEERS) {
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

void DefaultStrikePolicy::on_rejection(PeerId p_peer, StatusCode p_code, std::uint64_t p_detail) {
	(void)p_code;
	(void)p_detail;
	StrikeRecord &record = peers[p_peer];
	if (record.count < UINT32_MAX) {
		++record.count;
	}
	record.touch_seq = next_touch();
	enforce_cap();
}

bool DefaultStrikePolicy::should_disconnect(PeerId p_peer) const {
	auto it = peers.find(p_peer);
	return it != peers.end() && it->second.count >= threshold;
}

void DefaultStrikePolicy::drop_peer(PeerId p_peer) {
	peers.erase(p_peer);
}

std::uint32_t DefaultStrikePolicy::strike_count(PeerId p_peer) const {
	auto it = peers.find(p_peer);
	return it == peers.end() ? 0 : it->second.count;
}

// ---------------------------------------------------------------------------
// CommandGate
// ---------------------------------------------------------------------------

Status CommandGate::admit(const InboundCommandContext &p_context, const SessionTiming &p_timing, InboundCommandVerdict &r_verdict) {
	r_verdict = InboundCommandVerdict{};

	auto reject = [&](const Status &p_status) -> Status {
		r_verdict.kind = CommandOutcomeKind::REJECTED;
		r_verdict.status = p_status;
		if (strikes != nullptr) {
			strikes->on_rejection(p_context.peer, p_status.code, p_status.detail);
		}
		return p_status;
	};

	const Status session_status = ownership.validate_session(p_context.peer, p_context.session);
	if (!session_status.ok()) {
		return reject(session_status);
	}

	const Status control_status = ownership.validate_control(p_context.peer, p_context.component);
	if (!control_status.ok()) {
		return reject(control_status);
	}

	Status replay_status = ok_status();
	const CommandSequenceTracker::SequenceOutcome seq_outcome =
			sequence.check_command_sequence(p_context.session, p_context.component, p_context.command_sequence, replay_status);
	if (seq_outcome == CommandSequenceTracker::SequenceOutcome::STALE) {
		return reject(make_status(StatusCode::STALE_COMMAND, DiagnosticId::SEQUENCE_OUT_OF_ORDER, p_context.command_sequence.value));
	}
	if (seq_outcome == CommandSequenceTracker::SequenceOutcome::DUPLICATE) {
		// Not a rejection: an ack/reject was likely lost and the client
		// legitimately resent, so this never counts as a strike.
		r_verdict.kind = CommandOutcomeKind::DUPLICATE_REPLAY;
		r_verdict.status = replay_status;
		return ok_status();
	}

	if (p_context.prediction_key != INVALID_PREDICTION_KEY) {
		const Status key_status = sequence.claim_prediction_key(p_context.session, p_context.prediction_key);
		if (!key_status.ok()) {
			return reject(key_status);
		}
	}

	const Status rate_status = rate.admit_command(p_context.peer, p_context.component, p_context.current_tick, p_timing);
	if (!rate_status.ok()) {
		return reject(rate_status);
	}

	r_verdict.kind = CommandOutcomeKind::EXECUTE;
	r_verdict.status = ok_status();
	return ok_status();
}

} // namespace ga::proto
