#ifndef WEAPON_SYSTEM_PROTOCOL_COMPAT_H
#define WEAPON_SYSTEM_PROTOCOL_COMPAT_H

#include "core/wpn_catalog.h"
#include "core/wpn_status.h"
#include "protocol/wpn_protocol_types.h"

// Content-compatibility handshake helpers (tasks.md 7.1/7.3; weapon-protocol
// spec, "Versioned Canonical Weapon Protocol" / "Unknown required version is
// received"). Thin wrappers around core/wpn_version.h's already-sealed
// compatibility algebra (compatibility_manifest()/check_compatibility()) --
// this file adds no new comparison rule, it only derives/compares the
// wire-shaped protocol::CompatibilityHandshake envelope those core functions
// need.
namespace wpn::protocol {

// Derives a complete CompatibilityHandshake from a sealed catalog's manifest
// fingerprint and the compiled-in version/feature constants (delegates to
// core::compatibility_manifest()).
CompatibilityHandshake make_compatibility_handshake(const WeaponCatalog &p_sealed);

// Fail-closed compatibility check between a locally-derived handshake and one
// received from a peer. Checks protocol_version first (the envelope's own
// field, before even looking at the embedded manifest), then delegates the
// manifest comparison to core::check_compatibility() so weapon compatibility
// has exactly one comparison algorithm regardless of caller (offline
// catalog-vs-catalog check or a protocol handshake).
// `r_missing_features` receives check_compatibility()'s missing-feature
// bitmask (0 unless the failure is FEATURE_UNSUPPORTED).
Status check_handshake_compatibility(
		const CompatibilityHandshake &p_local,
		const CompatibilityHandshake &p_remote,
		std::uint64_t &r_missing_features);

} // namespace wpn::protocol

#endif // WEAPON_SYSTEM_PROTOCOL_COMPAT_H
