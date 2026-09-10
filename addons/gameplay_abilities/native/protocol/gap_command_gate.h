#ifndef GAMEPLAY_ABILITIES_PROTOCOL_COMMAND_GATE_H
#define GAMEPLAY_ABILITIES_PROTOCOL_COMMAND_GATE_H

#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "protocol/gap_authority.h"
#include "protocol/gap_messages.h"

#include <cstdint>
#include <map>
#include <set>

// The single choke point every inbound *client* activation command passes
// through before any gameplay mutation is attempted. Composes:
//   - gap_authority.h's `OwnershipTable`  (session validity, sender-to-entity
//     permission)
//   - `CommandSequenceTracker` (idempotent duplicates, stale/out-of-order
//     rejection, prediction-key uniqueness)
//   - `RateLimiter`            (per-peer-per-component command rate, per-peer
//     resync rate)
//   - `StrikePolicy`           (configurable rejection-counting hook)
//
// This covers steps 1-3 and the rate-limiting half of step 4 of design.md's
// "Server authority and ownership" numbered validation list. Granted-ability
// identity/execution policy, required/blocked tags, costs, cooldowns,
// target-data schema/visibility/game-provided authority validation, and
// set-by-caller bounds are a later agent's *gameplay-validation seam* -- see
// `CommandGate::admit`'s doc comment for exactly where that seam plugs in.
//
// Server/AI-issued activation requests (no client peer, no session, no
// client command sequence) do not pass through this file at all; they call
// `OwnershipTable::validate_server_entity` directly (see gap_authority.h).
namespace ga::proto {

// ---------------------------------------------------------------------------
// Local, protocol-layer bookkeeping bounds (NOT part of the wire contract --
// ga_limits.h owns those). These sit directly in the untrusted-client-input
// path, so unlike gap_authority.h's bounds they are this file's primary
// "a hostile peer flooding distinct sessions/components/sequences/peers
// cannot grow tracked memory without limit" guarantee, not just
// defense-in-depth. Every cap below is enforced by evicting the
// least-recently-touched entry (a private monotonic call counter, not a
// wall clock -- see each class's `next_touch()`), never by silently growing.
// ---------------------------------------------------------------------------

// Cap on CommandSequenceTracker's distinct (session, component) sequence
// states.
constexpr std::size_t MAX_TRACKED_COMMAND_STATES = 512;

// How far below a (session, component)'s confirmed watermark a not-yet-seen
// sequence number may still land and be treated as a fresh, executable
// reorder rather than outright stale (see CommandSequenceTracker's class
// comment for the exact policy). Deliberately small: it exists to tolerate
// ordinary transport reordering of a client's own recent commands, not to
// accept an old replayed command.
constexpr std::uint64_t MAX_REORDER_WINDOW = 32;

// Per (session, component): how many recent CommandSeq -> Status results are
// cached for idempotent replay ("cache the last N results" -- this is N).
// Deliberately equal to MAX_REORDER_WINDOW, not some smaller "typical burst"
// number: check_command_sequence() answers a sequence at/below the watermark
// from this cache when present, and otherwise falls back to treating any
// sequence within MAX_REORDER_WINDOW of the watermark as a fresh, re-
// executable reorder (see that method's own doc comment). A cache smaller
// than the window left the gap between the two bounds -- MAX_REORDER_WINDOW
// minus a smaller N -- silently uncovered: a replayed command whose sequence
// fell in that gap was answered as EXECUTE instead of DUPLICATE and re-
// entered gameplay validation instead of replaying its already-decided
// result. Downstream idempotence (terminal ability tasks resolve an unknown
// handle rather than re-running) happened to absorb that gap without a
// double effect, but this tracker should be self-sufficient rather than
// depend on that. Sizing the cache to the full window closes the gap
// exactly: there are at most MAX_REORDER_WINDOW distinct sequence values a
// watermark comparison can ever call "in window", so every one of them can
// have its own cached entry. Memory cost stays trivial: `Status` is 16
// bytes, so a `std::map<uint64_t, Status>` node (8-byte key + 16-byte value
// plus red-black-tree/allocator bookkeeping) is roughly 60-80 bytes; even at
// 32 entries that is only on the order of 2-2.5 KB per tracked (session,
// component) pair, and MAX_TRACKED_COMMAND_STATES (512) still bounds the
// worst-case total around 1-1.3 MB -- a quadrupling from the previous 8-
// entry cache's ~300 KB worst case, and still negligible for a per-
// connection allocation.
constexpr std::size_t MAX_DUPLICATE_RESULT_CACHE = MAX_REORDER_WINDOW;

// Cap on CommandSequenceTracker's distinct sessions tracked for
// prediction-key uniqueness, and per-session claimed-key cap.
constexpr std::size_t MAX_TRACKED_PREDICTION_SESSIONS = 512;
constexpr std::size_t MAX_PREDICTION_KEYS_PER_SESSION = 64;

// Caps on RateLimiter's distinct (peer, component) command buckets and
// distinct per-peer resync buckets.
constexpr std::size_t MAX_RATE_LIMIT_COMMAND_BUCKETS = 2048;
constexpr std::size_t MAX_RATE_LIMIT_RESYNC_BUCKETS = 1024;

// Cap on DefaultStrikePolicy's tracked peers.
constexpr std::size_t MAX_TRACKED_STRIKE_PEERS = 1024;

// ---------------------------------------------------------------------------
// CommandSequenceTracker
// ---------------------------------------------------------------------------

// Per-(session, component) monotonic CommandSeq state: idempotent-duplicate
// detection/replay, stale/out-of-order rejection, and per-session
// prediction-key uniqueness ("Versioned Activation Commands"'s duplicate
// scenario and the "Untrusted Payload Validation"/design.md sequence rule).
//
// Policy for `check_command_sequence` (documented here since it is the one
// place a reader needs to understand the whole rule):
//   - `p_sequence == INVALID_COMMAND_SEQ` (0) is never legitimate -> STALE.
//   - If `p_sequence` is found in this (session, component)'s bounded replay
//     cache, it is an exact repeat of an already-decided command -> DUPLICATE,
//     with the cached `Status` returned via `r_replay_status` for idempotent
//     resend. This is checked before the watermark comparison below, so an
//     exact duplicate is always recognized regardless of how far behind the
//     current watermark it has fallen.
//   - Otherwise, if `p_sequence` is at or below the confirmed watermark (the
//     highest sequence ever recorded for this (session, component)), it is
//     either a genuinely stale/replayed-attack sequence or a legitimately
//     reordered-in-transit command whose result simply is not (or is no
//     longer) in the small bounded cache. These two cases are told apart
//     only by distance from the watermark: within `MAX_REORDER_WINDOW` of it,
//     the sequence is treated as fresh (EXECUTE) -- it is not a delivery
//     duplicate of anything currently on record, so there is nothing to
//     replay, and this addon does not attempt to guess how a game's own
//     ability logic would react to reprocessing a stale value blindly.
//     Farther below the window, it is STALE. The confirmed watermark itself
//     only ever moves forward (see `record_command_result`) -- it is not
//     reset when an in-window reorder executes, so a burst of reordered
//     commands cannot be replayed indefinitely by resending them slightly
//     out of order.
//   - Otherwise (`p_sequence` is above the watermark) -> EXECUTE: an
//     ordinary fresh command.
//
// `check_command_sequence` never mutates confirmed state by itself (it may
// only touch this class's internal LRU recency bookkeeping) -- the caller
// must call `record_command_result` once the command's real outcome
// (success or authoritative rejection) is known, so a later duplicate can
// replay that exact result rather than whatever `check_command_sequence`
// happened to see.
class CommandSequenceTracker {
public:
	enum class SequenceOutcome : std::uint8_t {
		EXECUTE = 0, // Fresh (or in-window reordered) sequence: caller proceeds to gameplay validation/mutation.
		DUPLICATE = 1, // Exact repeat of an already-decided sequence: replay `r_replay_status`, do not re-mutate.
		STALE = 2, // At/below the watermark, outside the reorder window (or sequence == 0): reject.
	};

	SequenceOutcome check_command_sequence(SessionId p_session, EntityId p_component, CommandSeq p_sequence, Status &r_replay_status);

	// Records `p_result` as the decided outcome of `p_sequence` for
	// (`p_session`, `p_component`), advancing the confirmed watermark if
	// `p_sequence` is the highest seen yet for this pair. Idempotent to call
	// more than once for the same sequence (the cached result is simply
	// overwritten). Evicts the bounded per-state replay cache and the
	// bounded outer (session, component) map deterministically once their
	// caps (`MAX_DUPLICATE_RESULT_CACHE` / `MAX_TRACKED_COMMAND_STATES`) are
	// exceeded.
	void record_command_result(SessionId p_session, EntityId p_component, CommandSeq p_sequence, const Status &p_result);

	// Prediction-key uniqueness, scoped per session (not per component --
	// see the "Duplicate prediction key rejected" scenario and
	// gap_identity.h's note that PredictionKey scope tracking belongs here).
	// `StatusCode::ALREADY_EXISTS` (detail = the raw key value) if `p_key`
	// was already claimed by this session, OR if `p_key` is at or below the
	// highest key this session has ever had evicted -- see
	// `PredictionState::evicted_floor`'s doc comment for why re-admitting a
	// retired key must be rejected rather than silently re-claimed.
	// `StatusCode::INVALID_ARGUMENT` if `p_key == INVALID_PREDICTION_KEY`.
	// Bounded by `MAX_TRACKED_PREDICTION_SESSIONS` /
	// `MAX_PREDICTION_KEYS_PER_SESSION`, evicting the numerically-smallest
	// (oldest, since a real client's prediction keys are allocated
	// monotonically) claimed key first.
	Status claim_prediction_key(SessionId p_session, PredictionKey p_key);

	// `StatusCode::PREDICTION_UNKNOWN_KEY` (detail = the raw key value, or 0
	// for `INVALID_PREDICTION_KEY`) unless `p_key` was previously claimed by
	// `p_session` and has not since been evicted.
	Status validate_prediction_key(SessionId p_session, PredictionKey p_key) const;

	// Forgets every tracked (session, component) sequence state and claimed
	// prediction key for `p_session`. Callers should invoke this alongside
	// gap_authority.h's `OwnershipTable::end_session`/`drop_peer` on
	// disconnect/reconnect so a retired session's memory does not linger
	// until eviction happens to reclaim it.
	void drop_session(SessionId p_session);

	std::size_t tracked_command_state_count() const { return command_states.size(); }
	std::size_t tracked_prediction_session_count() const { return prediction_states.size(); }

private:
	struct SessionComponentKey {
		SessionId session = INVALID_SESSION_ID;
		std::uint64_t component = 0; // raw EntityId value.
		bool operator<(const SessionComponentKey &p_other) const {
			if (session != p_other.session) {
				return session < p_other.session;
			}
			return component < p_other.component;
		}
	};

	struct CommandState {
		std::uint64_t watermark = 0; // highest CommandSeq raw value ever recorded.
		std::map<std::uint64_t, Status> replay_cache; // bounded to MAX_DUPLICATE_RESULT_CACHE.
		std::uint64_t touch_seq = 0;
	};

	struct PredictionState {
		std::set<std::uint64_t> claimed_keys; // bounded to MAX_PREDICTION_KEYS_PER_SESSION.
		// Fix: prediction-key eviction re-claim. A real client's
		// `PredictionKey`s are allocated monotonically per session (see
		// `ga::PredictionJournal`'s `key_allocator`, ga_prediction.h/.cpp --
		// only ever raised, and `begin_with_identity`'s replay path reuses an
		// already-issued key rather than a fresh one, so it never produces a
		// key above the allocator's current value either). Once
		// `claimed_keys` evicts its numerically-smallest entry past
		// `MAX_PREDICTION_KEYS_PER_SESSION`, that key is no longer tracked in
		// the set and, without this floor, a hostile peer could re-submit
		// (`claim_prediction_key`) that exact retired value and have it
		// accepted as fresh. `evicted_floor` remembers the highest key ever
		// evicted for this session so `claim_prediction_key` can keep
		// rejecting it (and everything at or below it) even after it falls
		// out of `claimed_keys`, without rejecting any legitimate future
		// key -- a monotonic client's next key is always greater than every
		// key it has ever had evicted, since eviction only removes the
		// smallest of a set of keys strictly below the client's own
		// most-recently-claimed (and therefore always-increasing) value.
		std::uint64_t evicted_floor = 0;
		std::uint64_t touch_seq = 0;
	};

	std::uint64_t next_touch() { return ++touch_counter; }
	void enforce_command_state_cap();
	void enforce_prediction_session_cap();

	std::map<SessionComponentKey, CommandState> command_states;
	std::map<SessionId, PredictionState> prediction_states;
	std::uint64_t touch_counter = 0;
};

// ---------------------------------------------------------------------------
// RateLimiter
// ---------------------------------------------------------------------------

// Tick-based token buckets enforcing `MAX_COMMANDS_PER_SECOND` (keyed per
// (peer, component) -- ga_limits.h documents this constant as exactly the
// "per-peer per-component rate limit," i.e. one bucket per pair, not two
// independent per-peer and per-component limits) and `MAX_RESYNCS_PER_MINUTE`
// (keyed per peer only, per ga_limits.h's "per-peer resync rate limit").
//
// No wall clock is ever read: every bucket's refill is a pure function of
// the caller-supplied authoritative `Tick` and `SessionTiming`. A bucket
// starts full (an initial burst up to capacity is allowed, so a freshly
// connected peer is not immediately throttled) and refills linearly with
// elapsed ticks, saturating at full. Admission cost per call is computed as
// `ceil(window_ticks / capacity)`, rounding UP so this limiter is never more
// permissive than its nominal rate -- only ever stricter, which is the safe
// direction for a rate limit under integer-only arithmetic. A `p_now` that
// has not advanced (or has gone backwards -- ticks are caller-supplied and
// therefore untrusted-for-monotonicity) simply grants no additional credit
// rather than erroring.
//
// "Exceeding a budget must not allocate unbounded work and must leave other
// peers' processing bounded": every bucket lookup/insert here is O(log n)
// against a map capped at `MAX_RATE_LIMIT_COMMAND_BUCKETS` /
// `MAX_RATE_LIMIT_RESYNC_BUCKETS`, entirely independent of any other peer's
// bucket, so one peer's flood can never slow down or fail another peer's
// `admit_command`/`admit_resync` call, and a rejection here does zero
// additional work (no snapshot generation, no allocation) beyond returning
// `RATE_LIMITED`.
class RateLimiter {
public:
	// `StatusCode::RATE_LIMITED` (detail = remaining credit_ticks, always <
	// the per-admission cost) if `p_peer`'s (implicit, via `p_component`)
	// bucket has insufficient credit; `ok_status()` and one token consumed
	// otherwise.
	Status admit_command(PeerId p_peer, EntityId p_component, Tick p_now, const SessionTiming &p_timing);

	// Same policy, `MAX_RESYNCS_PER_MINUTE` budget, keyed per peer only.
	Status admit_resync(PeerId p_peer, Tick p_now, const SessionTiming &p_timing);

	// Forgets every bucket belonging to `p_peer` (disconnect/reconnect).
	void drop_peer(PeerId p_peer);

	std::size_t tracked_command_bucket_count() const { return command_buckets.size(); }
	std::size_t tracked_resync_bucket_count() const { return resync_buckets.size(); }

private:
	struct PeerComponentKey {
		PeerId peer = INVALID_PEER_ID;
		std::uint64_t component = 0; // raw EntityId value.
		bool operator<(const PeerComponentKey &p_other) const {
			if (peer != p_other.peer) {
				return peer < p_other.peer;
			}
			return component < p_other.component;
		}
	};

	struct TokenBucket {
		std::uint64_t credit_ticks = 0;
		Tick last_tick = 0;
		bool initialized = false;
		std::uint64_t touch_seq = 0;
	};

	static Status try_admit(TokenBucket &r_bucket, Tick p_now, std::uint64_t p_window_ticks, std::uint32_t p_capacity);
	std::uint64_t next_touch() { return ++touch_counter; }
	void enforce_command_bucket_cap();
	void enforce_resync_bucket_cap();

	std::map<PeerComponentKey, TokenBucket> command_buckets;
	std::map<PeerId, TokenBucket> resync_buckets;
	std::uint64_t touch_counter = 0;
};

// ---------------------------------------------------------------------------
// StrikePolicy
// ---------------------------------------------------------------------------

// Configurable rejection-counting hook. The addon counts strikes and exposes
// a disconnect *decision*; per design.md's "Security and failure policy" it
// deliberately does NOT implement account bans, a persistent blocklist, or
// call an external anti-cheat service, and it never disconnects a peer
// itself -- `should_disconnect()` is read-only advice the embedding
// game/network bridge may act on (or ignore) as its own policy dictates.
class StrikePolicy {
public:
	virtual ~StrikePolicy() = default;

	// Invoked by `CommandGate::admit` exactly once per rejected command
	// (never for a duplicate replay, which is not a violation). `p_code`/
	// `p_detail` mirror the rejection `Status` -- a stable code and a
	// bounded numeric detail, never an untrusted string.
	virtual void on_rejection(PeerId p_peer, StatusCode p_code, std::uint64_t p_detail) = 0;

	// Whether this policy currently recommends disconnecting `p_peer`.
	virtual bool should_disconnect(PeerId p_peer) const = 0;

	// Forgets any accumulated state for `p_peer` (disconnect/reconnect).
	virtual void drop_peer(PeerId p_peer) = 0;
};

// Simple default: counts rejections per peer and recommends disconnecting
// once a configurable threshold is reached. Bounded and evicted the same
// deterministic way as every other tracker in this file.
class DefaultStrikePolicy : public StrikePolicy {
public:
	explicit DefaultStrikePolicy(std::uint32_t p_disconnect_threshold = 20) :
			threshold(p_disconnect_threshold) {}

	void on_rejection(PeerId p_peer, StatusCode p_code, std::uint64_t p_detail) override;
	bool should_disconnect(PeerId p_peer) const override;
	void drop_peer(PeerId p_peer) override;

	std::uint32_t strike_count(PeerId p_peer) const;
	std::size_t tracked_peer_count() const { return peers.size(); }

private:
	struct StrikeRecord {
		std::uint32_t count = 0;
		std::uint64_t touch_seq = 0;
	};

	std::uint64_t next_touch() { return ++touch_counter; }
	void enforce_cap();

	std::map<PeerId, StrikeRecord> peers;
	std::uint32_t threshold;
	std::uint64_t touch_counter = 0;
};

// ---------------------------------------------------------------------------
// CommandGate
// ---------------------------------------------------------------------------

// One already-decoded inbound client command's identity fields. The
// activation command's own wire DTO (its bounded target data, set-by-caller
// fields, ability identity, ...) is a later agent's concern; `CommandGate`
// only ever sees the scalar identity/sequencing fields it needs to run its
// own checks.
struct InboundCommandContext {
	PeerId peer = INVALID_PEER_ID;
	SessionId session = INVALID_SESSION_ID;
	EntityId component = INVALID_ENTITY_ID; // Target component ("Versioned Activation Commands"'s target component identity).
	CommandSeq command_sequence = INVALID_COMMAND_SEQ;
	PredictionKey prediction_key = INVALID_PREDICTION_KEY; // INVALID_PREDICTION_KEY => not a predicted command.
	Tick current_tick = 0; // Authoritative "now"; used only for rate-limit token accounting, never trusted as client-supplied.
};

// What `CommandGate::admit` decided. Distinguishes the three outcomes the
// "Duplicate command arrives"/"Valid activation command arrives" scenarios
// require calling code to tell apart.
enum class CommandOutcomeKind : std::uint8_t {
	EXECUTE = 0, // Fresh, eligible command: caller must still run the gameplay-validation seam before mutating.
	DUPLICATE_REPLAY = 1, // Exact repeat: caller resends `status` idempotently and performs no mutation.
	REJECTED = 2, // Failed a gate check: caller reports `status` as an authoritative rejection.
};

struct InboundCommandVerdict {
	CommandOutcomeKind kind = CommandOutcomeKind::REJECTED;
	// OK when kind == EXECUTE; the replayed prior result when kind ==
	// DUPLICATE_REPLAY; the rejection reason when kind == REJECTED.
	Status status;
};

// Composes ownership + session + sequence + prediction-key + rate + strike
// checks into one call. See the file-level comment for what this class does
// and does not cover.
class CommandGate {
public:
	// None of the referenced objects are owned; all must outlive this
	// `CommandGate`. `p_strikes` may be `nullptr` if the embedding caller
	// does not want rejection counting (admit() simply skips that step).
	CommandGate(OwnershipTable &p_ownership, CommandSequenceTracker &p_sequence, RateLimiter &p_rate, StrikePolicy *p_strikes = nullptr) :
			ownership(p_ownership), sequence(p_sequence), rate(p_rate), strikes(p_strikes) {}

	// Runs, in order:
	//   1. `ownership.validate_session`      -> SESSION_MISMATCH
	//   2. `ownership.validate_control`      -> PERMISSION_DENIED
	//   3. `sequence.check_command_sequence` -> STALE_COMMAND, or a
	//      DUPLICATE_REPLAY verdict (not itself a rejection -- see below)
	//   3b. `sequence.claim_prediction_key` (only if `p_context.prediction_key
	//       != INVALID_PREDICTION_KEY`) -> ALREADY_EXISTS / INVALID_ARGUMENT
	//   4. `rate.admit_command`              -> RATE_LIMITED
	// matching design.md's numbered validation list through the
	// rate-limiting half of its step 4.
	//
	// *** GAMEPLAY-VALIDATION SEAM ***: granted-ability identity/execution
	// policy, required/blocked tags, costs, cooldowns, target-data
	// schema/visibility/game-provided authority validation, and
	// set-by-caller bounds are steps this function deliberately does NOT
	// run. A caller that receives `r_verdict.kind == EXECUTE` MUST still run
	// that validation -- itself likely composed as one more chained check
	// after this call -- before mutating gameplay state, and only then call
	// `sequence_tracker().record_command_result(p_context.session,
	// p_context.component, p_context.command_sequence, <final Status>)` so a
	// later duplicate replays the *actual* decided outcome rather than
	// nothing. `admit()` proves only that the command is eligible to be
	// attempted, never that it will succeed.
	//
	// Every rejection invokes `p_strikes->on_rejection(...)` (if a
	// `StrikePolicy` was supplied); a `DUPLICATE_REPLAY` verdict is not a
	// violation and never does.
	Status admit(const InboundCommandContext &p_context, const SessionTiming &p_timing, InboundCommandVerdict &r_verdict);

	// Accessors for the gameplay-validation seam and for callers that need
	// to drive session teardown (drop_session/drop_peer) alongside
	// gap_authority.h's OwnershipTable.
	OwnershipTable &ownership_table() { return ownership; }
	CommandSequenceTracker &sequence_tracker() { return sequence; }
	RateLimiter &rate_limiter() { return rate; }
	StrikePolicy *strike_policy() { return strikes; }

private:
	OwnershipTable &ownership;
	CommandSequenceTracker &sequence;
	RateLimiter &rate;
	StrikePolicy *strikes;
};

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_COMMAND_GATE_H
