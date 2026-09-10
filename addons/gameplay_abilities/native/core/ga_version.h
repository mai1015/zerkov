#ifndef GAMEPLAY_ABILITIES_CORE_VERSION_H
#define GAMEPLAY_ABILITIES_CORE_VERSION_H

#include "core/ga_limits.h"
#include "core/ga_status.h"

#include <cstdint>
#include <string>

// The addon's own version identity, independent of any Godot binding target.
// Every peer -- client or server, native or Web -- reports these numbers
// during the protocol handshake so an incompatible peer fails before a
// gameplay session begins, per the "Godot and Binding Compatibility" and
// "Release Manifest and Fail-Fast Diagnostics" requirements. The numeric
// constants themselves live in ga_limits.h; this header is the stable facade
// the godot-cpp binding (and everything else) reads them through, so they are
// never redeclared as a second set of literals.
namespace ga {

constexpr int api_version_major() { return GA_API_VERSION_MAJOR; }
constexpr int api_version_minor() { return GA_API_VERSION_MINOR; }
constexpr int api_version_patch() { return GA_API_VERSION_PATCH; }
constexpr std::uint16_t protocol_version() { return GA_PROTOCOL_VERSION; }
constexpr const char *manifest_algorithm() { return GA_MANIFEST_ALGORITHM; }

// "major.minor.patch", e.g. "0.2.0". Built from the same three integers a
// caller could read individually, so the two representations never drift.
std::string api_version_string();

// ---------------------------------------------------------------------------
// Feature negotiation
// ---------------------------------------------------------------------------

// Bit flags for the capabilities a peer may negotiate over the wire. New
// features are appended at the next unused bit; a bit is never renumbered or
// reused once shipped, because a peer's reported mask is compared against
// every protocol version it might ever talk to.
enum class FeatureSet : std::uint32_t {
	NONE = 0,
	PREDICTION = 1u << 0,
	DEDICATED_SERVER = 1u << 1,
	SNAPSHOT_RESYNC = 1u << 2,
	PERIODIC_EFFECTS = 1u << 3,
	GAMEPLAY_EVENTS = 1u << 4,
	ABILITY_TASKS = 1u << 5,
	TYPED_TARGETING = 1u << 6,
	// Protocol 3: the additive observable-task section of the public observer
	// payload (`GameplayAbilityNetworkBridge::encode_public_state`). Required
	// (see `supported_features()`), so a peer that predates this bit fails
	// the handshake closed rather than silently missing observer task state
	// it has no way to ask for -- the same fail-closed posture every prior
	// wire-relevant feature bit takes.
	OBSERVER_TASK_STATE = 1u << 7,
	// Protocol 4 (add-granular-delta-replication-2026-07-27, task 5.1):
	// owner `EVENT_BATCH` payloads carry a canonical granular delta
	// (`ga::proto::encode_delta_batch`) instead of a full component
	// snapshot, and a synced peer may receive a bounded `HEARTBEAT` message
	// in place of a state-bearing one while suppressed. Required (see
	// `supported_features()`): a peer that predates this bit cannot decode
	// either shape, so the handshake fails closed exactly like protocol 3's
	// own bit -- no session ever mixes legacy full-state batches with delta
	// batches.
	DELTA_REPLICATION = 1u << 8,
};

inline std::uint32_t operator|(FeatureSet p_a, FeatureSet p_b) {
	return static_cast<std::uint32_t>(p_a) | static_cast<std::uint32_t>(p_b);
}
inline std::uint32_t operator|(std::uint32_t p_a, FeatureSet p_b) {
	return p_a | static_cast<std::uint32_t>(p_b);
}
inline std::uint32_t operator&(std::uint32_t p_a, FeatureSet p_b) {
	return p_a & static_cast<std::uint32_t>(p_b);
}

inline bool has_feature(std::uint32_t p_mask, FeatureSet p_feature) {
	return (p_mask & static_cast<std::uint32_t>(p_feature)) != 0;
}

// Every feature this build implements, as a FeatureSet bitmask. A remote
// peer's required-feature mask is checked against this during negotiation.
std::uint32_t supported_features();

// Checks a remote peer's required-feature mask `p_remote` against what this
// build supports (`p_local`; normally supported_features() -- it is an
// explicit parameter, not read implicitly, so tests can negotiate against a
// hypothetical local mask without depending on this build's real feature
// list). Any bit set in `p_remote` that is not set in `p_local` is
// unsupported and fails negotiation closed: an unrecognized required bit is
// exactly as unsupported as a recognized one this build happens to lack, so a
// forward-incompatible remote peer can never be silently accepted.
//
// `r_missing_required` receives the exact unsupported bits so a diagnostic or
// a reconnect prompt can name them; it is always written, even on success
// (as 0). Returns OK when negotiation succeeds, or
// PROTOCOL_MISMATCH/FEATURE_UNSUPPORTED with `detail` set to the same mask.
Status negotiate_features(std::uint32_t p_local, std::uint32_t p_remote, std::uint32_t &r_missing_required);

} // namespace ga

#endif // GAMEPLAY_ABILITIES_CORE_VERSION_H
