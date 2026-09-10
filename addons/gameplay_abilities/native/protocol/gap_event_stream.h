#ifndef GAMEPLAY_ABILITIES_PROTOCOL_EVENT_STREAM_H
#define GAMEPLAY_ABILITIES_PROTOCOL_EVENT_STREAM_H

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "protocol/gap_messages.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <vector>

// Ordered Authoritative Event Streams (task 7.8).
//
// Each replicated component has exactly one monotonically increasing
// `ga::EventSeq` sequence. A state-bearing event batch declares the
// sequence it builds on (its "predecessor") and the sequence it advances to
// ("batch end"); a client applies a batch only when its predecessor equals
// the client's own confirmed sequence, in canonical (received) order,
// atomically. A gap, a duplicate with conflicting bytes, or a structurally
// impossible transition never applies speculatively -- see
// `ClientEventStream::apply_batch`.
//
// *** SCOPE SEAM ***: this file frames and sequences an OPAQUE event-batch
// payload (`std::vector<std::uint8_t>` plus its `ga::Hasher`/`ga::hash_bytes`
// fingerprint). It never decodes gameplay content. The component/effects
// agent's real batch encoder produces the bytes `AuthoritativeEventStream::
// append_batch` wraps; the real batch decoder/applier is the
// `ApplyEventBatchFn` callback `ClientEventStream::apply_batch` invokes --
// that is the one place gameplay content re-enters the picture, and it does
// so entirely outside this file.
namespace ga::proto {

// ---------------------------------------------------------------------------
// EventBatchHeader
// ---------------------------------------------------------------------------

// On-wire layout -- exactly EVENT_BATCH_HEADER_BYTES (44) bytes,
// little-endian fixed width, fixed field order, never renumbered:
//
//   offset  size  field                notes
//   0       8     component            u64, raw ga::EntityId
//   8       8     predecessor          u64, raw ga::EventSeq the batch
//                                       declares it builds on
//   16      8     batch_end            u64, raw ga::EventSeq after applying
//                                       this batch (== predecessor +
//                                       event_count; enforced on encode AND
//                                       decode)
//   24      8     authoritative_tick   u64, ga::Tick this batch was decided at
//   32      4     event_count          u32, 1..MAX_EVENTS_PER_BATCH
//   36      8     payload_fingerprint  u64, FNV1a64 (ga::hash_bytes) over the
//                                       opaque event payload bytes that
//                                       immediately follow this header on
//                                       the wire (see encode_event_batch)
//
// Total: 44 bytes. `batch_end == predecessor + event_count` is a structural
// invariant checked by both encode and decode: it is what lets
// `ClientEventStream` recognize a zero-length range, a shrinking range, or
// any other impossible transition purely from the header's own fields.
constexpr std::size_t EVENT_BATCH_HEADER_BYTES = 44;

struct EventBatchHeader {
	EntityId component = INVALID_ENTITY_ID;
	EventSeq predecessor = INVALID_EVENT_SEQ;
	EventSeq batch_end = INVALID_EVENT_SEQ;
	Tick authoritative_tick = 0;
	std::uint32_t event_count = 0;
	std::uint64_t payload_fingerprint = 0;
};

// Canonical encode/decode of the header alone (fixed 44 bytes). Both
// directions validate `component != INVALID_ENTITY_ID`, `1 <= event_count
// <= MAX_EVENTS_PER_BATCH`, and `batch_end == predecessor + event_count`;
// on any failure the out-param is reset to its default and nothing is
// written. Ordinary callers use `encode_event_batch`/`decode_event_batch`
// below, which additionally carry the event payload; these are exposed
// separately because `AuthoritativeEventStream`/`ClientEventStream` also
// need to validate a bare, already-separated header.
Status encode_event_batch_header(const EventBatchHeader &p_header, std::vector<std::uint8_t> &r_out);
Status decode_event_batch_header(const std::vector<std::uint8_t> &p_bytes, EventBatchHeader &r_header);

// Encodes the full wire shape of one EVENT_BATCH message payload: the
// canonical header immediately followed by `p_event_payload`'s raw bytes
// (opaque -- produced by the component/effects layer). Fails closed,
// writing nothing, if:
//   - `p_header.payload_fingerprint != ga::hash_bytes(p_event_payload)` --
//     StatusCode::INVALID_ARGUMENT (caller bug: header/payload disagree
//     before a single byte is sent).
//   - the header itself fails `encode_event_batch_header`'s own checks.
//   - the combined header+payload size exceeds `MAX_EVENT_BATCH_BYTES` --
//     StatusCode::PAYLOAD_TOO_LARGE / DiagnosticId::BYTE_LIMIT_EXCEEDED.
Status encode_event_batch(const EventBatchHeader &p_header, const std::vector<std::uint8_t> &p_event_payload, std::vector<std::uint8_t> &r_out);

// Decodes a full EVENT_BATCH payload produced by `encode_event_batch`.
// Untrusted-input order: buffer at least `EVENT_BATCH_HEADER_BYTES` and at
// most `MAX_EVENT_BATCH_BYTES` -> header decodes and validates on its own
// terms -> the trailing bytes' `ga::hash_bytes` digest matches the header's
// declared `payload_fingerprint` (StatusCode::DECODE_FAILED /
// DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS on mismatch -- this is a
// per-message integrity check, distinct from `ClientEventStream`'s
// cross-message duplicate-with-conflicting-bytes detection). On any
// failure both out-params are reset to empty/default.
Status decode_event_batch(const std::vector<std::uint8_t> &p_bytes, EventBatchHeader &r_header, std::vector<std::uint8_t> &r_event_payload);

// ---------------------------------------------------------------------------
// AuthoritativeEventStream (server side)
// ---------------------------------------------------------------------------

// Bound on how many recent batches one component's stream retains for
// catch-up (task 7.8: "bounded retained history so a client slightly
// behind can be caught up without a full snapshot"). 64 is a small, fixed,
// per-component footprint chosen generously above ordinary bursts of
// in-flight prediction/ack traffic (MAX_PENDING_PREDICTIONS is 16); a
// client further behind than this falls back to a full snapshot instead,
// which is always correct, just more expensive -- exceeding this bound is
// a capacity/performance choice, never a correctness one. Eviction is
// deterministic: the single oldest retained batch (lowest predecessor
// sequence) is dropped, never a hash-order-dependent choice.
constexpr std::size_t MAX_RETAINED_EVENT_BATCHES = 64;

// Whether a payload of exactly `p_payload_bytes` opaque event bytes could
// ride the owner event stream AT ALL -- decided up front, from named
// constants only, before either encoder actually runs. A caller (see
// `GameplayAbilityNetworkBridge::send_owner_event_batch`,
// gameplay_ability_network_bridge.cpp) MUST consult this BEFORE calling
// `append_batch`: TWO independent bounds gate an event batch ever reaching a
// peer, and `append_batch` alone only enforces the first one.
//
//   1. The append bound `append_batch` (via `encode_event_batch`) itself
//      enforces: `EVENT_BATCH_HEADER_BYTES + p_payload_bytes <=
//      MAX_EVENT_BATCH_BYTES`.
//   2. The framing bound `encode_message` additionally enforces once the
//      encoded batch above is wrapped in a wire message:
//      `MESSAGE_HEADER_BYTES + (EVENT_BATCH_HEADER_BYTES + p_payload_bytes)
//      <= message_byte_limit(MessageType::EVENT_BATCH)`.
//
// A payload can satisfy (1) while failing (2) -- `message_byte_limit
// (EVENT_BATCH)` reuses `MAX_EVENT_BATCH_BYTES` (see gap_messages.cpp), so
// framing's extra `MESSAGE_HEADER_BYTES` makes bound (2) strictly tighter
// today. Calling `append_batch` for a payload that fails (2) would advance
// the stream's head and retain a batch for a message that can never
// actually be sent -- a real defect this predicate exists to prevent. Both
// bounds are checked explicitly here (never assuming (2) implies (1) or
// vice versa) so this stays correct even if either constant changes
// independently. `stream_event_batch_fits_stream_matches_encoders_at_boundary`
// (ga_test_event_stream.cpp) proves `true` here implies BOTH `append_batch`
// and `encode_message` succeed for the same payload, and that a size for
// which `append_batch` itself refuses is never reported `true`.
bool event_batch_fits_stream(std::size_t p_payload_bytes);

// Owns one component's monotonically increasing `EventSeq` and the bounded
// history needed to answer "give me everything after sequence S" for a
// client that is behind but not gapped beyond the retained window.
//
// The component identity is established by the FIRST `append_batch` call
// (there is no separate constructor argument) and is fixed thereafter --
// every later call must name the same `EntityId`, matching the class's
// "one instance per replicated component" contract while still matching
// `append_batch`'s documented signature exactly.
class AuthoritativeEventStream {
public:
	AuthoritativeEventStream() = default;

	// Assigns the next sequence range for `p_event_count` events (must be in
	// [1, MAX_EVENTS_PER_BATCH]), declares its predecessor as this stream's
	// current head sequence, computes `payload_fingerprint` from `p_payload`
	// via `ga::hash_bytes`, retains the batch for catch-up, advances the
	// head sequence to the batch end, and fills `r_header` with the fully
	// assigned header. Fails closed (head/history unchanged, `r_header`
	// reset) if:
	//   - `p_component == INVALID_ENTITY_ID`, or differs from the entity
	//     this stream was already locked to by an earlier call --
	//     StatusCode::INVALID_ARGUMENT.
	//   - `p_event_count == 0` or `> MAX_EVENTS_PER_BATCH` --
	//     StatusCode::OUT_OF_BOUNDS / DiagnosticId::COUNT_LIMIT_EXCEEDED.
	//   - the encoded batch (header + `p_payload`) would exceed
	//     `MAX_EVENT_BATCH_BYTES` -- StatusCode::PAYLOAD_TOO_LARGE /
	//     DiagnosticId::BYTE_LIMIT_EXCEEDED.
	Status append_batch(EntityId p_component, Tick p_tick, std::vector<std::uint8_t> p_payload, std::size_t p_event_count, EventBatchHeader &r_header);

	EntityId component() const { return owner; }
	EventSeq head_sequence() const { return head; }

	// Retained-history catch-up lookup: the header/payload of the batch
	// whose *predecessor* equals `p_since`, or a not-found result if it is
	// not (or no longer) retained -- the caller must fall back to a full
	// snapshot in that case (the "gap ... requests a full snapshot instead
	// of guessing state" rule). `try_get_payload` returns `false` and clears
	// `r_payload` on a miss rather than ever returning a partial/stale copy.
	const EventBatchHeader *find_batch_after(EventSeq p_since) const;
	bool try_get_payload(EventSeq p_since, std::vector<std::uint8_t> &r_payload) const;

	std::size_t retained_batch_count() const { return history.size(); }

private:
	struct RetainedBatch {
		EventBatchHeader header;
		std::vector<std::uint8_t> payload;
	};

	EntityId owner = INVALID_ENTITY_ID;
	EventSeq head = INVALID_EVENT_SEQ;
	// Keyed by the retained batch's declared predecessor (raw EventSeq
	// value) so lookup-by-"everything after S" is a single O(log n) find.
	// A std::map iterates in key order, so eviction of "the oldest" is
	// always erase(begin()) -- deterministic regardless of insertion order.
	std::map<std::uint64_t, RetainedBatch> history;
};

// ---------------------------------------------------------------------------
// ClientEventStream (client side)
// ---------------------------------------------------------------------------

// Explicit stream state a client-side component is in. A component with no
// confirmed snapshot baseline yet MUST be AWAITING_BASELINE and MUST NOT
// apply any delta; NEEDS_SNAPSHOT is the analogous "stop applying deltas,
// a fresh snapshot is required" state reached after a sequence gap, a
// failed snapshot application, a lost-relevance quarantine, or a new
// session -- see the relevant methods below for exactly which transition
// produces which state.
enum class ClientStreamState : std::uint8_t {
	AWAITING_BASELINE = 0,
	SYNCED = 1,
	NEEDS_SNAPSHOT = 2,
};

// Seam: hands an accepted batch's opaque event payload to the component/
// effects layer for real decoding and gameplay application. Invoked AT
// MOST once per distinct (predecessor, batch_end) range, and only once
// `ClientEventStream::apply_batch` has already proven it is safe to apply
// (predecessor == the stream's confirmed sequence) -- never speculatively,
// never for an idempotent duplicate or a rejected range. A non-OK return
// means the opaque payload could not actually be applied (e.g. the
// component layer's own decode failed); `apply_batch` then leaves the
// confirmed sequence unchanged and moves the stream to NEEDS_SNAPSHOT so a
// resync is requested rather than silently drifting.
using ApplyEventBatchFn = std::function<Status(const EventBatchHeader &p_header, const std::vector<std::uint8_t> &p_payload)>;

// Per-component client-side sequencing state machine. One instance per
// replicated component, keyed externally (e.g. `std::map<EntityId,
// ClientEventStream>`) by whatever owns the component's replication
// bookkeeping.
class ClientEventStream {
public:
	explicit ClientEventStream(EntityId p_component);

	EntityId component() const { return owner; }
	ClientStreamState state() const { return current_state; }
	EventSeq confirmed_sequence() const { return confirmed; }

	// Establishes (or re-establishes, after a fresh snapshot) the confirmed
	// baseline sequence, moves to SYNCED, and clears the bounded
	// idempotency/conflict-detection history below (a new baseline starts a
	// fresh epoch of "what has already been applied"). This is the ONLY way
	// a stream leaves AWAITING_BASELINE or NEEDS_SNAPSHOT. Exposed directly
	// (in addition to being called by gap_resync.h's
	// `apply_snapshot_envelope`) so a test can drive the sequencing half in
	// isolation from snapshot wire bytes.
	void establish_baseline(EventSeq p_confirmed_sequence);

	// Quarantine policy for a temporary condition that makes the confirmed
	// baseline untrustworthy without discarding it: a detected sequence gap,
	// a snapshot that failed to apply, or the component losing server-side
	// relevance ("Component leaves and regains relevance": hidden state is
	// QUARANTINED, not discarded -- `confirmed` and the retained idempotency
	// history are left exactly as they were, only further delta application
	// is gated, so a still-current confirmed value is not thrown away for
	// nothing). A no-op if already AWAITING_BASELINE (there is nothing more
	// restrictive to move to). SYNCED -> NEEDS_SNAPSHOT otherwise. A fresh
	// `establish_baseline` (normally via a validated `SnapshotEnvelope`) is
	// required before deltas apply again.
	void mark_needs_snapshot();

	// Reconnection under a brand-new session ("Client reconnects"): unlike
	// `mark_needs_snapshot`'s quarantine policy, a new session is a new
	// trust epoch, not a temporary condition, so this fully DISCARDS the
	// confirmed baseline and the retained idempotency history and returns to
	// AWAITING_BASELINE. A fresh snapshot is required before any prediction
	// or delta application resumes -- see the "fresh snapshots precede
	// resumed prediction" requirement.
	void reset_for_new_session();

	// The core state machine. Validates `p_header`'s own shape first (this
	// runs regardless of state), then checks state, then compares
	// `p_header.predecessor` against `confirmed`:
	//
	//   1. Header shape: `component` must match this stream's `component()`,
	//      `event_count` in [1, MAX_EVENTS_PER_BATCH], `batch_end ==
	//      predecessor + event_count`, and `payload_fingerprint ==
	//      ga::hash_bytes(p_payload)`. Any failure ->
	//      StatusCode::OUT_OF_BOUNDS / DiagnosticId::SEQUENCE_OUT_OF_ORDER
	//      (shape) or StatusCode::DECODE_FAILED /
	//      DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS (fingerprint); `p_apply`
	//      is never invoked, state unchanged.
	//   2. `state() != SYNCED` (AWAITING_BASELINE or NEEDS_SNAPSHOT) ->
	//      StatusCode::SNAPSHOT_REQUIRED / DiagnosticId::BASELINE_MISSING;
	//      `p_apply` is never invoked, state unchanged -- "never
	//      speculatively apply."
	//   3. `predecessor == confirmed` (fresh, in order): `p_apply` is
	//      invoked exactly once.
	//        - OK -> `confirmed` advances to `batch_end`, the range is
	//          recorded for future idempotency checks, state stays SYNCED,
	//          returns ok_status().
	//        - non-OK -> `confirmed` is NOT advanced, the stream moves to
	//          NEEDS_SNAPSHOT (quarantine -- see `mark_needs_snapshot`), and
	//          `p_apply`'s own Status is returned unchanged.
	//   4. `predecessor < confirmed`:
	//        - `batch_end > confirmed` -> structurally impossible (starts in
	//          already-applied territory but claims to extend past it) ->
	//          StatusCode::OUT_OF_BOUNDS / DiagnosticId::SEQUENCE_OUT_OF_ORDER;
	//          `p_apply` never invoked, state unchanged.
	//        - otherwise (`batch_end <= confirmed`, an already-covered
	//          range): if the bounded retained history has a record for this
	//          exact `predecessor` --
	//            * matching `batch_end` AND `payload_fingerprint` -> genuine
	//              idempotent duplicate: ok_status(), `p_apply` NOT invoked,
	//              nothing changes.
	//            * differing `batch_end` or `payload_fingerprint` -> a
	//              protocol violation, not a benign duplicate:
	//              StatusCode::ALREADY_EXISTS /
	//              DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS; `p_apply`
	//              never invoked, state unchanged.
	//          If no record is retained for this `predecessor` (evicted, or
	//          older than this stream's retained window), the range is
	//          already guaranteed superseded by `confirmed` either way, so
	//          it is treated as a presumed-stale, harmless duplicate and
	//          ignored (ok_status(), `p_apply` NOT invoked) rather than
	//          rejected -- this addon does not retain unbounded history just
	//          to distinguish "duplicate of something long past" from
	//          "duplicate of something never seen," since neither case can
	//          ever cause anything to be applied twice.
	//   5. `predecessor > confirmed`: a gap. `p_apply` is NEVER invoked
	//      (never speculative). The stream moves to NEEDS_SNAPSHOT (quarantine)
	//      and returns StatusCode::SEQUENCE_GAP /
	//      DiagnosticId::SEQUENCE_OUT_OF_ORDER; `confirmed` unchanged.
	Status apply_batch(const EventBatchHeader &p_header, const std::vector<std::uint8_t> &p_payload, const ApplyEventBatchFn &p_apply);

	std::size_t retained_fingerprint_count() const { return applied.size(); }

private:
	struct AppliedRange {
		std::uint64_t batch_end = 0;
		std::uint64_t fingerprint = 0;
	};

	void note_applied(const EventBatchHeader &p_header);

	EntityId owner;
	ClientStreamState current_state = ClientStreamState::AWAITING_BASELINE;
	EventSeq confirmed = INVALID_EVENT_SEQ;
	// Bounded idempotency/conflict-detection log, keyed by predecessor raw
	// value; bounded and evicted exactly like AuthoritativeEventStream's
	// retained history (see MAX_RETAINED_EVENT_BATCHES).
	std::map<std::uint64_t, AppliedRange> applied;
};

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_EVENT_STREAM_H
