#ifndef GAMEPLAY_ABILITIES_PROTOCOL_HANDSHAKE_H
#define GAMEPLAY_ABILITIES_PROTOCOL_HANDSHAKE_H

#include "core/ga_bytes.h"
#include "core/ga_limits.h"
#include "core/ga_status.h"
#include "core/ga_version.h"

#include <cstdint>
#include <string>
#include <vector>

// Before any gameplay command or state crosses the wire, both peers must
// prove they agree on everything that would otherwise let them silently
// diverge: protocol version, required feature flags, gameplay tick rate,
// fixed-point scale, identifier-dictionary fingerprint, packet limits, and
// content-manifest fingerprint (see the "Protocol and Content Compatibility
// Handshake" requirement). `HandshakeRequest`/`HandshakeResponse` are the
// exchanged DTOs; `evaluate_handshake` is the single fail-closed comparison
// every peer runs before marking a session gameplay-ready.
//
// There is deliberately no partial-compatibility result: `HandshakeResult`
// is either fully `compatible` or carries exactly one `reason` and a stable
// `Status` -- never a "degrade gracefully" mode. This addon's error
// convention (see gap_messages.h) is to return `ga::Status` directly rather
// than a dedicated `DecodeError` type; the handshake functions below follow
// that same convention.
namespace ga::proto {

// ---------------------------------------------------------------------------
// On-wire layout of HandshakeRequest/HandshakeResponse -- identical field
// set and order for both message types in v1 (they differ only in which
// `MessageType` they are framed under; see gap_messages.h). Little-endian,
// fixed width via explicit shifts, one bounded trailing string:
//
//   offset  size    field
//   0       2       protocol_version              (u16)
//   2       1       api_version_major              (u8)
//   3       1       api_version_minor              (u8)
//   4       1       api_version_patch              (u8)
//   5       4       required_features              (u32, ga::FeatureSet mask)
//   9       4       tick_rate                      (u32)
//   13      8       fixed_point_scale              (i64)
//   21      8       identifier_dictionary_fingerprint (u64)
//   29      8       content_manifest_fingerprint   (u64)
//   37      4       max_command_packet_bytes       (u32)
//   41      4       max_event_batch_bytes          (u32)
//   45      4       max_snapshot_bytes             (u32)
//   49      4       max_handshake_bytes            (u32)
//   53      2+N     manifest_algorithm             (u16 length, then N UTF-8
//                                                    bytes; N <= MAX_STRING_BYTES)
//
// Fixed portion: 53 bytes. `manifest_algorithm` is carried purely for
// diagnostics (so a mismatch report can name which algorithm produced each
// fingerprint); it is never itself a compatibility gate -- see
// `evaluate_handshake`. Likewise `api_version_*` is diagnostic only: two
// builds can share a protocol version across different addon patch/minor
// releases. Both are still length/byte bounded like every other decoded
// field.
// ---------------------------------------------------------------------------

// Fields exchanged by the client's opening handshake message.
//
// `required_features` should be built from `ga::supported_features()`: v1
// has no notion of a feature a build supports but does not require, so the
// simplest fail-closed policy is "I require everything I support." A peer's
// `evaluate_handshake` call checks the *other* side's `required_features`
// against its own (see below) -- full bidirectional protection comes from
// each peer running that check once, from its own perspective, over the
// course of the request/response exchange.
struct HandshakeRequest {
	std::uint16_t protocol_version = ga::GA_PROTOCOL_VERSION;
	std::uint8_t api_version_major = 0;
	std::uint8_t api_version_minor = 0;
	std::uint8_t api_version_patch = 0;
	std::uint32_t required_features = 0;
	std::uint32_t tick_rate = ga::DEFAULT_TICK_RATE;
	std::int64_t fixed_point_scale = ga::FIXED_SCALE;
	std::uint64_t identifier_dictionary_fingerprint = 0;
	std::uint64_t content_manifest_fingerprint = 0;
	std::uint32_t max_command_packet_bytes = ga::MAX_COMMAND_PACKET_BYTES;
	std::uint32_t max_event_batch_bytes = ga::MAX_EVENT_BATCH_BYTES;
	std::uint32_t max_snapshot_bytes = ga::MAX_SNAPSHOT_BYTES;
	std::uint32_t max_handshake_bytes = ga::MAX_HANDSHAKE_BYTES;
	std::string manifest_algorithm = ga::GA_MANIFEST_ALGORITHM;
};

// Same field set as `HandshakeRequest` (see the layout comment above); a
// distinct C++ type so a decode path bound to one direction of the exchange
// can never accidentally accept bytes framed as the other.
struct HandshakeResponse {
	std::uint16_t protocol_version = ga::GA_PROTOCOL_VERSION;
	std::uint8_t api_version_major = 0;
	std::uint8_t api_version_minor = 0;
	std::uint8_t api_version_patch = 0;
	std::uint32_t required_features = 0;
	std::uint32_t tick_rate = ga::DEFAULT_TICK_RATE;
	std::int64_t fixed_point_scale = ga::FIXED_SCALE;
	std::uint64_t identifier_dictionary_fingerprint = 0;
	std::uint64_t content_manifest_fingerprint = 0;
	std::uint32_t max_command_packet_bytes = ga::MAX_COMMAND_PACKET_BYTES;
	std::uint32_t max_event_batch_bytes = ga::MAX_EVENT_BATCH_BYTES;
	std::uint32_t max_snapshot_bytes = ga::MAX_SNAPSHOT_BYTES;
	std::uint32_t max_handshake_bytes = ga::MAX_HANDSHAKE_BYTES;
	std::string manifest_algorithm = ga::GA_MANIFEST_ALGORITHM;
};

// Canonical encode/decode, both bounded by MAX_HANDSHAKE_BYTES (the writer
// refuses to grow past it; the decoder refuses any input already larger
// than it before parsing a single field). Decoding never partially fills
// `r_request`/`r_response`: on any failure the out-param is reset to its
// default value.
Status encode_handshake_request(const HandshakeRequest &p_request, std::vector<std::uint8_t> &r_out);
Status decode_handshake_request(const std::vector<std::uint8_t> &p_bytes, HandshakeRequest &r_request);
Status encode_handshake_response(const HandshakeResponse &p_response, std::vector<std::uint8_t> &r_out);
Status decode_handshake_response(const std::vector<std::uint8_t> &p_bytes, HandshakeResponse &r_response);

// Structural debt fix: `HandshakeRequest`/`HandshakeResponse` share an
// IDENTICAL field set and order (see the on-wire layout comment above) --
// `GameplayAbilityNetworkBridge` used to hand-copy all thirteen fields at
// each direction of the exchange (building a response from the request it
// just evaluated, then again reconstituting a request-shaped value from a
// received response to run the SAME `evaluate_handshake` both peers use).
// These two helpers are the one place that field-copy happens now; protocol
// owns both types and the layout invariant, so it also owns keeping the
// conversion trivially correct.
HandshakeResponse to_response(const HandshakeRequest &p_request);
HandshakeRequest to_request(const HandshakeResponse &p_response);

// Stable, bounded reason a handshake failed. Additive -- append, never
// renumber, matching every other enum crossing this boundary.
enum class HandshakeIncompatibilityReason : std::uint8_t {
	NONE = 0,
	PROTOCOL_VERSION = 1,
	REQUIRED_FEATURE = 2,
	TICK_RATE = 3,
	FIXED_POINT_SCALE = 4,
	IDENTIFIER_DICTIONARY = 5,
	CONTENT_MANIFEST = 6,
	PACKET_LIMITS = 7,
};

// Result of one `evaluate_handshake` call. `status` never carries client-
// supplied string content or any value beyond what both sides already
// exchanged in the clear during the handshake itself (a version number, a
// fingerprint, a byte limit, a feature mask) -- exactly the "identifies the
// incompatible manifest without exposing secret state" scenario the
// networking spec requires. There is no partial/degraded state: either
// `compatible` is true and `reason == NONE`, or `compatible` is false and
// exactly one `reason` (with a matching `status`) explains why.
struct HandshakeResult {
	bool compatible = false;
	HandshakeIncompatibilityReason reason = HandshakeIncompatibilityReason::NONE;
	Status status;
	// Meaningful only when reason == REQUIRED_FEATURE: the exact bits from
	// `ga::negotiate_features` that the remote required and this build does
	// not have.
	std::uint32_t missing_required_features = 0;
};

// Fail-closed compatibility check, run independently by each peer from its
// own perspective: does `p_local` (this build's own declared handshake
// fields) satisfy everything `p_remote` (the value received from the other
// side) requires? Checked in this order (first mismatch wins -- later
// checks never run once an earlier one fails, so `r_result` always reports
// exactly one reason):
//   1. protocol_version differs ->
//      StatusCode::PROTOCOL_MISMATCH / DiagnosticId::PROTOCOL_VERSION_DIFFERS,
//      reason = PROTOCOL_VERSION.
//   2. `ga::negotiate_features(p_local.required_features,
//      p_remote.required_features, missing)` fails (a feature p_remote
//      requires that p_local's build does not have) ->
//      StatusCode::PROTOCOL_MISMATCH / DiagnosticId::FEATURE_UNSUPPORTED,
//      reason = REQUIRED_FEATURE, `missing_required_features` set.
//   3. tick_rate differs -> StatusCode::MANIFEST_MISMATCH /
//      DiagnosticId::TICK_RATE_UNSUPPORTED, reason = TICK_RATE.
//   4. fixed_point_scale differs -> StatusCode::MANIFEST_MISMATCH /
//      DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, reason = FIXED_POINT_SCALE.
//   5. identifier_dictionary_fingerprint differs -> StatusCode::MANIFEST_MISMATCH /
//      DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, reason = IDENTIFIER_DICTIONARY.
//   6. content_manifest_fingerprint differs -> StatusCode::MANIFEST_MISMATCH /
//      DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, reason = CONTENT_MANIFEST.
//   7. any of the four packet limits differs -> StatusCode::MANIFEST_MISMATCH /
//      DiagnosticId::BYTE_LIMIT_EXCEEDED, reason = PACKET_LIMITS.
// Otherwise `r_result.compatible = true`, `reason = NONE`,
// `status = ga::ok_status()`. There is no other return path: no partial
// compatibility mode is ever inferred, matching the "Client advertises an
// unsupported protocol" scenario's "no partial compatibility mode is
// inferred" requirement.
//
// `manifest_algorithm` and `api_version_*` are intentionally not checked
// here (see the on-wire layout comment above) -- they are diagnostic-only
// fields, not compatibility gates.
Status evaluate_handshake(const HandshakeRequest &p_remote, const HandshakeRequest &p_local, HandshakeResult &r_result);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_HANDSHAKE_H
