#ifndef GAMEPLAY_ABILITIES_PROTOCOL_MESSAGES_H
#define GAMEPLAY_ABILITIES_PROTOCOL_MESSAGES_H

#include "core/ga_bytes.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_version.h"

#include <cstddef>
#include <cstdint>
#include <vector>

// The envelope every wire message shares: a fixed-size header naming the
// protocol version, message type, session, and declared payload length,
// followed by exactly that many payload bytes. A later message body
// (activation command, event batch, snapshot, ...) is carried as an opaque
// payload here; this file only frames it and enforces the version/type/
// length/byte-limit checks that MUST happen before a single payload byte is
// interpreted by anything downstream.
//
// Error reporting convention for every file under native/protocol/: fallible
// functions return `ga::Status` directly (no separate `DecodeError` wrapper
// type). This matches every core boundary function (`ga_bytes.h`,
// `ga_manifest.h`, `ga_fixed.h`, ...) and keeps one uniform result shape
// across the whole addon; a caller never has to remember which layer wraps
// which. `Status::diagnostic` and `Status::detail` (see `ga_status.h`) carry
// enough structure that a second wrapper type would add indirection without
// adding information.
//
// Decoding is untrusted input: `decode_message` validates header fields and
// the per-type byte limit strictly *before* the payload is copied anywhere,
// so a hostile or corrupt frame can never drive an allocation ahead of
// validation, a partially-applied gameplay mutation, or an unbounded
// diagnostic string. Every failure path here fails closed: `r_header` and
// `r_payload` are left at their default/empty state, never partially filled.
namespace ga::proto {

// Wire-level connection/session identity assigned by the transport
// (independent of `ga::EntityId` and friends in `core/ga_ids.h`). It exists
// purely so one physical connection's messages can be told apart from
// another's; it is never used as, or converted into, a gameplay identity --
// see `gap_identity.h` for the rule this follows.
using SessionId = std::uint32_t;
constexpr SessionId INVALID_SESSION_ID = 0;

// Every protocol message. Values are additive and MUST NEVER be renumbered or
// reused once shipped: a peer running an older or newer build must keep
// interpreting an already-shipped value identically forever. Append new
// message types at the next unused value and bump `MESSAGE_TYPE_COUNT`.
enum class MessageType : std::uint8_t {
	HANDSHAKE_REQUEST = 0,
	HANDSHAKE_RESPONSE = 1,
	ACTIVATION_COMMAND = 2,
	COMMAND_ACK = 3,
	COMMAND_REJECT = 4,
	EVENT_BATCH = 5,
	SNAPSHOT = 6,
	RESYNC_REQUEST = 7,
	PRESENTATION_EVENT = 8,
	TASK_INPUT_COMMAND = 9,
	TASK_STATE = 10,
	TARGET_COMMAND = 11,
	TARGET_OUTCOME = 12,
	TARGET_STATE = 13,
	// Change-Gated State Sends (add-granular-delta-replication-2026-07-27,
	// task 3.4/4.4): the bounded liveness/tick-alignment message a synced
	// peer receives instead of a state-bearing message while its audience
	// revision is unchanged. Payload is `HeartbeatPayload`, see
	// gap_heartbeat.h.
	HEARTBEAT = 14,
};

// One past the highest currently-defined `MessageType` value. Lets a decoded
// type byte be range-checked without hand-listing every enumerator at each
// call site; update alongside any newly appended `MessageType`.
constexpr std::uint8_t MESSAGE_TYPE_COUNT = 15;

inline bool is_valid_message_type(std::uint8_t p_raw) {
	return p_raw < MESSAGE_TYPE_COUNT;
}

// This message type's maximum payload size in bytes (header excluded).
// Every value below is an existing `ga_limits.h` constant reused for its
// closest-matching message shape (see the .cpp for the exact mapping and
// rationale) -- this file never introduces a second bound for something
// `ga_limits.h` already governs, and this function is the single reviewable
// place the per-type table lives.
std::size_t message_byte_limit(MessageType p_type);

// ---------------------------------------------------------------------------
// On-wire header layout -- exactly MESSAGE_HEADER_BYTES (12) bytes,
// little-endian fixed width via explicit shifts (see ga_bytes.h), fixed
// field order, never renumbered:
//
//   offset  size  field              notes
//   0       2     protocol_version   u16, must equal ga::protocol_version()
//   2       1     message_type       u8, MessageType; must be < MESSAGE_TYPE_COUNT
//   3       1     reserved           u8, MUST be 0 (see below)
//   4       4     session_id         u32, SessionId
//   8       4     payload_length     u32, exact byte count of the payload
//                                    that immediately follows the header
//
// Total header size: 12 bytes. The payload follows immediately and MUST be
// exactly `payload_length` bytes -- no trailing bytes, no gap. `reserved`
// exists so a future protocol version can add per-message flags without
// resizing the header; a decoder that does not understand a nonzero value
// there must reject the message rather than silently ignore a flag a newer
// peer relies on, so this build treats any nonzero `reserved` byte as
// malformed rather than as "unknown, ignore".
// ---------------------------------------------------------------------------
constexpr std::size_t MESSAGE_HEADER_BYTES = 12;

struct MessageHeader {
	std::uint16_t protocol_version = 0;
	MessageType message_type = MessageType::HANDSHAKE_REQUEST;
	SessionId session_id = INVALID_SESSION_ID;
	std::uint32_t payload_length = 0;
};

// Frames `p_payload` behind a `MessageHeader` for `p_type`, stamping the
// current build's protocol version and `ga::proto::INVALID_SESSION_ID` (0).
// Equivalent to the 5-argument overload below with `p_session_id ==
// INVALID_SESSION_ID`; callers that already know their session id should
// call that overload directly instead of patching the header afterward.
Status encode_message(MessageType p_type, const std::vector<std::uint8_t> &p_payload, std::size_t p_byte_limit, std::vector<std::uint8_t> &r_out);

// Full form of `encode_message`, carrying an explicit `p_session_id`. Fails
// closed (returns non-OK, leaves `r_out` empty) without writing anything if:
//   - `p_type` is not a recognized `MessageType` --
//     StatusCode::INVALID_ARGUMENT / DiagnosticId::INVALID_ENUM.
//   - `p_payload.size()` exceeds `message_byte_limit(p_type)` --
//     StatusCode::PAYLOAD_TOO_LARGE / DiagnosticId::BYTE_LIMIT_EXCEEDED.
//   - the framed message (header + payload) would exceed `p_byte_limit` --
//     same code/diagnostic. `p_byte_limit` is the caller's own overall frame
//     cap (e.g. a transport MTU, or a stricter bound in a test); it can only
//     make encoding stricter than `message_byte_limit`, never looser.
Status encode_message(MessageType p_type, SessionId p_session_id, const std::vector<std::uint8_t> &p_payload, std::size_t p_byte_limit, std::vector<std::uint8_t> &r_out);

// Decodes and validates a `MessageHeader` from `p_bytes`, then splits off its
// payload into `r_payload`. Validates, strictly in this order, before
// touching payload bytes:
//   1. `p_bytes.size() >= MESSAGE_HEADER_BYTES` --
//      StatusCode::DECODE_FAILED / DiagnosticId::TRUNCATED_PAYLOAD.
//   2. `protocol_version` matches `ga::protocol_version()` --
//      StatusCode::PROTOCOL_MISMATCH / DiagnosticId::PROTOCOL_VERSION_DIFFERS.
//   3. `message_type` is a recognized `MessageType` --
//      StatusCode::DECODE_FAILED / DiagnosticId::INVALID_ENUM.
//   4. `reserved` is zero --
//      StatusCode::DECODE_FAILED / DiagnosticId::INVALID_ENUM.
//   5. `payload_length` exactly equals the bytes remaining after the header
//      (rejects a declared length either longer OR shorter than the actual
//      buffer) --
//      StatusCode::DECODE_FAILED / DiagnosticId::TRUNCATED_PAYLOAD.
//   6. `payload_length` does not exceed `message_byte_limit(message_type)`
//      and the total framed size does not exceed `p_byte_limit` --
//      StatusCode::PAYLOAD_TOO_LARGE / DiagnosticId::BYTE_LIMIT_EXCEEDED.
// `r_payload` is only resized/copied into after every check above passes, so
// a hostile declared length can never drive an allocation ahead of
// validation. On any failure, `r_header` and `r_payload` are reset to their
// default/empty state -- never a partially-applied result.
Status decode_message(const std::vector<std::uint8_t> &p_bytes, std::size_t p_byte_limit, MessageHeader &r_header, std::vector<std::uint8_t> &r_payload);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_MESSAGES_H
