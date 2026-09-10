#ifndef INVENTORY_SYSTEM_PROTOCOL_COMPAT_H
#define INVENTORY_SYSTEM_PROTOCOL_COMPAT_H

#include "core/inv_catalog.h"
#include "core/inv_status.h"
#include "protocol/inv_protocol_types.h"

// Protocol/session compatibility (tasks.md 6.3; docs/inventory/
// compatibility.md "Session compatibility", the six-item list; inventory-
// protocol spec, "Protocol and Manifest Compatibility"). Fail-closed, no
// partial compatibility: `check_session_compatibility` reports the FIRST
// mismatched axis and stops -- it never reports two mismatches or infers
// degraded acceptance from a subset of matching axes (matches the sibling
// gameplay_abilities addon's protocol/gap_handshake.h convention, sampled
// for this boundary's own file-naming/namespace-layout precedent).
namespace inv::protocol {

// Fail-closed compatibility check, run independently by each peer from its
// own perspective (mirrors gap_handshake.h's evaluate_handshake()): does
// p_remote satisfy everything p_local needs, and vice versa? Checked in
// compatibility.md's exact six-item order (first mismatch wins; later
// checks never run once an earlier one fails):
//   1. protocol_version differs ->
//      StatusCode::PROTOCOL_MISMATCH / DiagnosticId::PROTOCOL_VERSION_DIFFERS.
//   2. mass_unit differs ->
//      StatusCode::PROTOCOL_MISMATCH / DiagnosticId::SESSION_MASS_UNIT_MISMATCH.
//   3. required_feature_bits: p_local requires a bit p_remote does not
//      advertise, OR p_remote requires a bit p_local does not advertise
//      (bidirectional -- V1's required_feature_bits doubles as "bits this
//      build supports", so this is the only axis with two failure
//      directions) ->
//      StatusCode::FEATURE_UNSUPPORTED / DiagnosticId::FEATURE_SET_UNSUPPORTED,
//      detail = the missing bitmask from whichever direction failed first
//      (p_remote missing what p_local requires is checked before the
//      reverse).
//   4. hard_limit_digest differs ->
//      StatusCode::SCHEMA_MISMATCH / DiagnosticId::SESSION_LIMIT_DIGEST_MISMATCH.
//   5. identifier_dictionary_digest differs ->
//      StatusCode::MANIFEST_MISMATCH / DiagnosticId::SESSION_IDENTIFIER_DIGEST_MISMATCH.
//   6. manifest_algorithm differs ->
//      StatusCode::MANIFEST_MISMATCH / DiagnosticId::SESSION_MANIFEST_ALGORITHM_MISMATCH;
//      else manifest_fingerprint differs ->
//      StatusCode::MANIFEST_MISMATCH / DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS.
// Otherwise returns ok_status(). There is no other return path -- no
// partial/degraded compatibility is ever inferred from a subset of matching
// axes (inventory-protocol spec: "Required incompatibility MUST fail closed
// before partial inventory state is accepted").
Status check_session_compatibility(const SessionHello &p_local, const SessionHello &p_remote);

// Derives a complete SessionHello from a sealed catalog and the compiled-in
// version/limit constants:
//   protocol_version            = inv::PROTOCOL_VERSION
//   mass_unit                   = inv::MASS_UNIT
//   manifest_algorithm          = inv::MANIFEST_ALGORITHM
//   manifest_fingerprint        = p_sealed.manifest()->fingerprint (0 if
//                                  p_sealed is not sealed)
//   required_feature_bits       = inv::supported_features()
//   hard_limit_digest           = fnv1a64 over inv::encode_hard_limits()'s
//                                  canonical byte sequence
//   identifier_dictionary_digest = p_sealed.identifier_dictionary_fingerprint()
//                                  (0 if p_sealed is not sealed)
// See each field's doc comment in protocol/inv_protocol_types.h and
// core/inv_catalog.h's identifier_dictionary_fingerprint() for the exact
// derivations.
SessionHello make_session_hello(const DefinitionCatalog &p_sealed);

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_COMPAT_H
