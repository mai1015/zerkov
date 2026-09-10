#ifndef GAMEPLAY_ABILITIES_PROTOCOL_RESYNC_H
#define GAMEPLAY_ABILITIES_PROTOCOL_RESYNC_H

#include "core/ga_bytes.h"
#include "core/ga_hash.h"
#include "core/ga_ids.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "protocol/gap_authority.h"
#include "protocol/gap_command_gate.h"
#include "protocol/gap_event_stream.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

// Late Join, Relevance, and Resynchronization (stream/resync half of task
// 7.10); also the encode/decode home for `ResyncRequest` and
// `SnapshotEnvelope` (task 7.9's DTO plus this task's request/response
// flow).
//
// *** SCOPE SEAM ***: `SnapshotEnvelope::payload` is an opaque blob here too
// -- this file bounds it, fingerprints it, and stamps a manifest fingerprint
// and validity sequence around it, but never interprets it. The component
// layer supplies the real snapshot bytes through the `SnapshotProducer`
// callback (server side) and consumes an accepted envelope's bytes through
// the `ApplySnapshotFn` callback (client side).
namespace ga::proto {

// ---------------------------------------------------------------------------
// ResyncRequest
// ---------------------------------------------------------------------------

// Why a client is asking for a fresh full snapshot. Additive -- append,
// never renumber, matching every other wire enum in this addon.
enum class ResyncReason : std::uint8_t {
	GAP_DETECTED = 0,
	BASELINE_MISSING = 1,
	MANIFEST_CHANGED = 2,
	RELEVANCE_REGAINED = 3,
	EXPLICIT = 4,
};

constexpr std::uint8_t RESYNC_REASON_COUNT = 5;

inline bool is_valid_resync_reason(std::uint8_t p_raw) {
	return p_raw < RESYNC_REASON_COUNT;
}

// On-wire layout -- exactly RESYNC_REQUEST_BYTES (21) bytes, little-endian
// fixed width, fixed field order, never renumbered:
//
//   offset  size  field               notes
//   0       4     session             u32, SessionId
//   4       8     component           u64, raw ga::EntityId
//   12      8     confirmed_sequence  u64, raw ga::EventSeq (0 == no
//                                      confirmed baseline yet)
//   20      1     reason              u8, ResyncReason; must be a
//                                      recognized value
//
// Total: 21 bytes.
struct ResyncRequest {
	SessionId session = INVALID_SESSION_ID;
	EntityId component = INVALID_ENTITY_ID;
	EventSeq confirmed_sequence = INVALID_EVENT_SEQ;
	ResyncReason reason = ResyncReason::EXPLICIT;
};

constexpr std::size_t RESYNC_REQUEST_BYTES = 21;

// Canonical encode/decode. Decoding rejects any buffer not exactly
// RESYNC_REQUEST_BYTES long and any `reason` byte outside
// `is_valid_resync_reason`; on any failure `r_request` is reset to its
// default value.
Status encode_resync_request(const ResyncRequest &p_request, std::vector<std::uint8_t> &r_out);
Status decode_resync_request(const std::vector<std::uint8_t> &p_bytes, ResyncRequest &r_request);

// ---------------------------------------------------------------------------
// SnapshotEnvelope
// ---------------------------------------------------------------------------

// On-wire layout -- SNAPSHOT_ENVELOPE_FIXED_BYTES (44) fixed bytes followed
// by exactly `payload.size()` raw payload bytes, little-endian fixed width,
// fixed field order, never renumbered:
//
//   offset  size    field                notes
//   0       8       component            u64, raw ga::EntityId
//   8       8       authoritative_tick   u64, ga::Tick this snapshot was
//                                        produced at
//   16      8       valid_as_of          u64, raw ga::EventSeq the snapshot
//                                        is valid as of -- becomes the
//                                        client's confirmed sequence on
//                                        acceptance
//   24      8       manifest_fingerprint u64, content-manifest fingerprint
//                                        (ga::ContentManifest::fingerprint)
//                                        this snapshot's content was
//                                        produced under
//   32      8       payload_fingerprint  u64, FNV1a64 (ga::hash_bytes) over
//                                        the payload bytes below
//   40      4       payload length       u32, <= MAX_SNAPSHOT_BYTES
//   44      N       payload              opaque bytes, component/effects
//                                        content
//
// Fixed portion: 44 bytes, plus N payload bytes.
struct SnapshotEnvelope {
	EntityId component = INVALID_ENTITY_ID;
	Tick authoritative_tick = 0;
	EventSeq valid_as_of = INVALID_EVENT_SEQ;
	std::uint64_t manifest_fingerprint = 0;
	std::uint64_t payload_fingerprint = 0;
	std::vector<std::uint8_t> payload;
};

constexpr std::size_t SNAPSHOT_ENVELOPE_FIXED_BYTES = 44;

// Encoding FAILS -- it never truncates -- when `p_envelope.payload.size() >
// MAX_SNAPSHOT_BYTES`: StatusCode::PAYLOAD_TOO_LARGE /
// DiagnosticId::BYTE_LIMIT_EXCEEDED, `r_out` left empty. This is the
// structural enforcement of "Snapshot is too large": snapshot generation
// must fail with an operational diagnostic rather than ever emitting a
// truncated authoritative state.
Status encode_snapshot_envelope(const SnapshotEnvelope &p_envelope, std::vector<std::uint8_t> &r_out);

// Decodes a `SnapshotEnvelope`, validating (in order) buffer length, the
// declared payload length against `MAX_SNAPSHOT_BYTES` and the bytes
// actually remaining, and the payload's `ga::hash_bytes` digest against the
// declared `payload_fingerprint` -- StatusCode::DECODE_FAILED /
// DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS on an integrity mismatch. This
// function does NOT check `manifest_fingerprint` against any expected
// value (it has no session context to compare against); that is
// `apply_snapshot_envelope`'s job. On any failure `r_envelope` is reset to
// its default (empty payload).
Status decode_snapshot_envelope(const std::vector<std::uint8_t> &p_bytes, SnapshotEnvelope &r_envelope);

// ---------------------------------------------------------------------------
// Client-side snapshot application
// ---------------------------------------------------------------------------

// Seam: hands an accepted envelope's opaque payload to the component layer
// to replace the covered state atomically (per "Restoring a snapshot MUST
// replace the covered state atomically without replaying historical
// gameplay hooks"). Invoked at most once per `apply_snapshot_envelope`
// call, only after every wire-level and manifest check has already passed.
// A non-OK return means the component layer itself could not apply the
// (already-integrity-checked) payload; the stream is then treated exactly
// like any other validation failure -- see `apply_snapshot_envelope`.
using ApplySnapshotFn = std::function<Status(const SnapshotEnvelope &p_envelope)>;

// Client-side snapshot intake. `p_envelope` must already have passed
// `decode_snapshot_envelope` (or be a trusted in-process value, e.g. built
// directly by a same-process test or an offline-authority component) --
// this function adds the two checks decoding alone cannot make: does the
// envelope actually name `r_stream`'s own component, and does its
// `manifest_fingerprint` match `p_expected_manifest_fingerprint` (the
// content-manifest fingerprint this session already agreed to at
// handshake). On success, invokes `p_apply`, then moves `r_stream` to
// SYNCED with its confirmed sequence set to `p_envelope.valid_as_of` (via
// `ClientEventStream::establish_baseline`).
//
// On ANY failure -- component mismatch, manifest mismatch, or `p_apply`
// itself failing -- `r_stream` is explicitly moved to NEEDS_SNAPSHOT (via
// `mark_needs_snapshot`) regardless of what state it was already in, so a
// snapshot that arrives while a component still believed itself SYNCED
// (e.g. a proactively re-sent snapshot that turns out to be invalid) does
// not leave the component confidently trusting stale state: it becomes
// explicitly non-predicting and recovery-seeking, matching "the client
// rejects it and remains non-predicting" / "triggers recovery... according
// to policy." The failure Status is returned unchanged.
Status apply_snapshot_envelope(const SnapshotEnvelope &p_envelope, std::uint64_t p_expected_manifest_fingerprint, ClientEventStream &r_stream, const ApplySnapshotFn &p_apply);

// ---------------------------------------------------------------------------
// ResyncCoordinator (server side)
// ---------------------------------------------------------------------------

// What the produced envelope's fields should be for one component, as of
// "now." Supplied by the component/effects layer -- `ResyncCoordinator`
// never interprets `payload`, only wraps it (computing `payload_fingerprint`
// and validating `MAX_SNAPSHOT_BYTES`) into a `SnapshotEnvelope`.
struct SnapshotProductionResult {
	Tick authoritative_tick = 0;
	EventSeq valid_as_of = INVALID_EVENT_SEQ;
	std::uint64_t manifest_fingerprint = 0;
	std::vector<std::uint8_t> payload;
};

// A non-OK return means snapshot production itself failed (e.g. the
// component layer determined its own content would exceed
// MAX_SNAPSHOT_BYTES) -- `ResyncCoordinator` surfaces that failure as-is
// rather than ever emitting a truncated envelope.
using SnapshotProducer = std::function<Status(EntityId p_component, SnapshotProductionResult &r_result)>;

// Which server-decided event is asking for a fresh snapshot. Purely
// informational to `ResyncCoordinator` today (every trigger shares one
// production path); kept as a distinct parameter so a caller's own
// telemetry/logging can distinguish them without this class inventing a
// second enum later.
enum class ResyncTrigger : std::uint8_t {
	FIRST_RELEVANCE = 0,
	LATE_JOIN = 1,
	RECONNECT_NEW_SESSION = 2,
	RELEVANCE_REGAINED = 3,
	// The owner's per-tick full-snapshot payload could not ride the event
	// batch stream at all -- see `event_batch_fits_stream` (gap_event_stream.h)
	// -- so `GameplayAbilityNetworkBridge::send_owner_event_batch`
	// (gameplay_ability_network_bridge.cpp) fell back to an unconditional
	// full SNAPSHOT instead of either silently dropping owner state or
	// advancing the stream for a batch that was never sent. Purely
	// informational, exactly like every other value here -- NOT wire-encoded
	// (`SnapshotEnvelope` carries no trigger field, and
	// `ResyncCoordinator::produce_unconditional` only ever uses `p_trigger`
	// for a caller's own telemetry), so adding this value is not a protocol
	// change.
	BATCH_OVERFLOW = 4,
	// A peer's pending OWNER-audience delta could not be delivered as a delta
	// (add-granular-delta-replication-2026-07-27, task 3.5, "Delta Bounds and
	// Snapshot Fallback"): the encoded delta batch failed
	// `event_batch_fits_stream` (or `write_delta_batch`/`encode_delta_batch`
	// itself failed), or the peer's replication cursor fell off
	// `ga::ChangeTracker`'s bounded ring (`ChangeTracker::cursor_overflowed`)
	// so a correct delta could not even be computed. `GameplayAbilityNetwork
	// Bridge::send_owner_event_batch` falls back to an unconditional full
	// `SNAPSHOT` for that peer under this trigger, subject to the SAME
	// `ResyncCoordinator`/`RateLimiter` bounds `BATCH_OVERFLOW` already is
	// (`produce_unconditional` never consults `RateLimiter::admit_resync` for
	// either -- both are server-decided, not peer-requested), and resets that
	// peer's replication cursor to the revision the fresh snapshot captured.
	// Purely informational, exactly like every other value here -- not
	// wire-encoded, so adding it is not itself a protocol change (the wire
	// break for granular deltas is the protocol-4 bump/feature bit, not this
	// enumerator).
	DELTA_OVERFLOW = 5,
};

// Decides when a peer gets a fresh full snapshot and produces it. Two
// distinct call paths, matching the "Late Join, Relevance, and
// Resynchronization" requirement's two kinds of trigger:
//
//   - `produce_unconditional`: first relevance, late join, reconnect under
//     a new session, or relevance regained. These are server-decided
//     events, not something an untrusted peer can request arbitrarily
//     often (the server's own visibility/session logic fires them, at most
//     once per real occurrence), so they are NEVER subject to
//     `RateLimiter::admit_resync`'s budget.
//   - `produce_for_request`: an explicit client `ResyncRequest`. THIS path
//     consults `RateLimiter::admit_resync` first and invokes the supplied
//     `StrikePolicy` (if any) on a rate-limit rejection, per "Client
//     requests excessive resyncs": "the server rate-limits requests and
//     invokes its policy hook, and does not allocate unbounded snapshot
//     work." `p_producer` is NEVER invoked when the rate check itself
//     fails -- no snapshot production work happens for a flooding peer.
class ResyncCoordinator {
public:
	ResyncCoordinator(RateLimiter &p_rate, StrikePolicy *p_strikes = nullptr) :
			rate(p_rate), strikes(p_strikes) {}

	Status produce_unconditional(EntityId p_component, ResyncTrigger p_trigger, const SnapshotProducer &p_producer, SnapshotEnvelope &r_envelope);

	// `p_now`/`p_timing` are passed straight through to
	// `RateLimiter::admit_resync` (ticks only, no wall clock -- see
	// gap_command_gate.h).
	Status produce_for_request(PeerId p_peer, const ResyncRequest &p_request, Tick p_now, const SessionTiming &p_timing, const SnapshotProducer &p_producer, SnapshotEnvelope &r_envelope);

private:
	Status finalize_envelope(EntityId p_component, const SnapshotProducer &p_producer, SnapshotEnvelope &r_envelope);

	RateLimiter &rate;
	StrikePolicy *strikes;
};

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_RESYNC_H
