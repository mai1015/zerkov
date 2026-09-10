#ifndef WEAPON_SYSTEM_CORE_VERSION_H
#define WEAPON_SYSTEM_CORE_VERSION_H

#include "core/wpn_limits.h"
#include "core/wpn_status.h"

#include <cstdint>
#include <string>

namespace wpn {

enum class ProtocolFeature : std::uint64_t {
	NONE = 0,
	CATALOG_MANIFEST = UINT64_C(1) << 0,
	SEMI_AUTO = UINT64_C(1) << 1,
	HITSCAN_2D = UINT64_C(1) << 2,
	SIMPLE_RELOAD = UINT64_C(1) << 3,
	SNAPSHOTS = UINT64_C(1) << 4,
};

struct CompatibilityManifest {
	std::uint16_t api_major = API_VERSION_MAJOR;
	std::uint16_t api_minor = API_VERSION_MINOR;
	std::uint16_t api_patch = API_VERSION_PATCH;
	std::uint16_t protocol = PROTOCOL_VERSION;
	std::uint16_t resource_schema = RESOURCE_SCHEMA_VERSION;
	std::uint64_t features = 0;
	std::uint64_t catalog_fingerprint = 0;
	// Sealed world-geometry quantization/tie-rule contract (task 6.8; see
	// wpn_limits.h). Two authorities that disagree on either version could
	// silently resolve the same shot differently, so both fold into the
	// manifest fingerprint and are compared like protocol/schema versions.
	std::uint16_t world_quantization_version = WORLD_QUANTIZATION_VERSION;
	std::uint16_t world_tie_rule_version = WORLD_TIE_RULE_VERSION;

	std::uint64_t fingerprint() const;
};

constexpr int api_version_major() { return API_VERSION_MAJOR; }
constexpr int api_version_minor() { return API_VERSION_MINOR; }
constexpr int api_version_patch() { return API_VERSION_PATCH; }
constexpr std::uint16_t protocol_version() { return PROTOCOL_VERSION; }
constexpr std::uint16_t resource_schema_version() { return RESOURCE_SCHEMA_VERSION; }
std::string api_version_string();
std::uint64_t supported_features();
Status negotiate_features(std::uint64_t p_local, std::uint64_t p_required, std::uint64_t &r_missing);
CompatibilityManifest compatibility_manifest(std::uint64_t p_catalog_fingerprint);
Status check_compatibility(
		const CompatibilityManifest &p_local,
		const CompatibilityManifest &p_remote,
		std::uint64_t &r_missing_features);

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_VERSION_H
