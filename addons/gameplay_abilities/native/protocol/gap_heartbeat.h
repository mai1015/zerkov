#ifndef GAMEPLAY_ABILITIES_PROTOCOL_HEARTBEAT_H
#define GAMEPLAY_ABILITIES_PROTOCOL_HEARTBEAT_H

#include "core/ga_bytes.h"
#include "core/ga_ids.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"

#include <cstddef>
#include <cstdint>
#include <vector>

// Change-Gated State Sends (add-granular-delta-replication-2026-07-27, task
// 3.4/4.4's codec half): the bounded liveness/tick-alignment message a
// synced peer receives INSTEAD of a state-bearing message while its
// audience revision is unchanged. Deliberately carries nothing else --
// spec "Change-Gated State Sends" bounds it to "at most authoritative tick
// and stream-head sequence."
//
// *** SCOPE SEAM ***: this file is send-cadence-agnostic. It only frames and
// validates the wire payload; deciding WHEN a heartbeat is due (the
// suppressed-send cadence, `ga::HEARTBEAT_SUPPRESSED_CADENCE_TICKS`,
// ga_limits.h) and which peer/component pair it is sent for is the sending
// bridge's job (a later wave's change-gating logic, out of this file's
// scope).
//
// Client-side tick-estimator feed: a decoded `HeartbeatPayload` needs no
// dedicated entry point into `ga::ServerTickEstimator` -- `observe()`
// (ga_reconciliation.h) already takes exactly a (local tick, authoritative
// tick) pair with no dependency on the message that supplied it. A caller
// feeds a heartbeat's `authoritative_tick` into the SAME
// `estimator.observe(local_tick, heartbeat.authoritative_tick)` call it
// already makes for a snapshot's or event batch's own `authoritative_tick`
// (see `GameplayAbilityNetworkBridge::correct_estimated_tick`, which is
// already exactly this one-line call) -- so alignment surviving idle
// suppression requires no new core API, only routing this message's tick
// through the existing one.
namespace ga::proto {

// On-wire layout -- exactly HEARTBEAT_PAYLOAD_BYTES (16) bytes,
// little-endian fixed width, fixed field order, never renumbered:
//
//   offset  size  field                notes
//   0       8     authoritative_tick   u64, ga::Tick this heartbeat was
//                                      sent at
//   8       8     stream_head_sequence u64, raw ga::EventSeq -- the head
//                                      sequence of whichever event stream
//                                      serves the receiving peer
//
// Total: 16 bytes. A heartbeat is a per-peer send (the enclosing
// `MessageHeader::session_id`, gap_messages.h, already names the
// recipient), so exactly ONE stream head is meaningful here even though a
// peer may hold many replicated components: this payload names whichever
// single stream the sending bridge is heartbeating FOR, matching "at most
// authoritative tick and stream-head sequence" literally rather than
// folding multiple components' heads into one message. A peer tracking
// several components receives one heartbeat per component/peer pair that
// needs one that tick, exactly like it already receives one event batch or
// target-state message per component today.
constexpr std::size_t HEARTBEAT_PAYLOAD_BYTES = 16;

struct HeartbeatPayload {
	Tick authoritative_tick = 0;
	EventSeq stream_head_sequence = INVALID_EVENT_SEQ;
};

// Canonical encode/decode, matching `gap_resync.h`'s `ResyncRequest` style:
// a small fixed-size payload with no section-local version field (the
// outer envelope's `protocol_version`, gap_messages.h, already governs
// compatibility for a shape this small and this additive -- see
// `TASK_MESSAGE_VERSION`'s own doc comment in gap_task_messages.h for when a
// body version IS warranted; a fixed two-scalar payload never grows a
// second shape the way a record-bearing DTO can). Decoding rejects any
// buffer not exactly `HEARTBEAT_PAYLOAD_BYTES` long -- covers truncated
// (too few bytes), oversized, and trailing-byte (too many bytes) buffers
// alike, since this payload has no internal variable-length section to
// distinguish those cases further. On any failure `r_heartbeat` is reset to
// its default value.
//
// Neither direction validates `authoritative_tick` or
// `stream_head_sequence` beyond their fixed wire shape: `stream_head_sequence
// == INVALID_EVENT_SEQ` is itself a value a caller may legitimately not have
// established yet (matching `ResyncRequest::confirmed_sequence`'s own
// "0 == no confirmed baseline yet" convention, gap_resync.h), and this file
// has no session/stream context to check a tick or sequence against even if
// it wanted to -- that is the sending/receiving bridge's job, not this
// codec's.
Status encode_heartbeat(const HeartbeatPayload &p_heartbeat, std::vector<std::uint8_t> &r_out);
Status decode_heartbeat(const std::vector<std::uint8_t> &p_bytes, HeartbeatPayload &r_heartbeat);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_HEARTBEAT_H
