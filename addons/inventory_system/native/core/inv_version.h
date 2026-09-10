#ifndef INVENTORY_SYSTEM_CORE_VERSION_H
#define INVENTORY_SYSTEM_CORE_VERSION_H

#include "core/inv_limits.h"
#include "core/inv_status.h"

#include <cstdint>
#include <string>

namespace inv {

constexpr int api_version_major() { return API_VERSION_MAJOR; }
constexpr int api_version_minor() { return API_VERSION_MINOR; }
constexpr int api_version_patch() { return API_VERSION_PATCH; }
constexpr std::uint16_t protocol_version() { return PROTOCOL_VERSION; }
constexpr std::uint16_t resource_schema_version() { return RESOURCE_SCHEMA_VERSION; }
constexpr std::uint16_t feature_module_version() { return FEATURE_MODULE_VERSION; }
constexpr std::uint16_t persistence_schema_version() { return PERSISTENCE_SCHEMA_VERSION; }
constexpr const char *manifest_algorithm() { return MANIFEST_ALGORITHM; }
constexpr const char *mass_unit() { return MASS_UNIT; }

std::string api_version_string();

enum class ProtocolFeature : std::uint64_t {
	NONE = 0,
	CATALOG_MANIFEST = UINT64_C(1) << 0,
	MODULAR_PROFILES = UINT64_C(1) << 1,
	SPATIAL_GRID = UINT64_C(1) << 2,
	NAMED_SLOTS = UINT64_C(1) << 3,
	ORDERED_LIST = UINT64_C(1) << 4,
	TYPED_TRAITS = UINT64_C(1) << 5,
	FEATURE_MODULES = UINT64_C(1) << 6,
	TARGETED_PROVIDER_TRANSFER = UINT64_C(1) << 7,
	MUTABLE_COMPONENT_COMMANDS = UINT64_C(1) << 8,
	OBSERVER_REPLICATION = UINT64_C(1) << 9,
};

inline std::uint64_t operator|(ProtocolFeature p_a, ProtocolFeature p_b) {
	return static_cast<std::uint64_t>(p_a) | static_cast<std::uint64_t>(p_b);
}

inline std::uint64_t operator|(std::uint64_t p_a, ProtocolFeature p_b) {
	return p_a | static_cast<std::uint64_t>(p_b);
}

inline bool has_feature(std::uint64_t p_mask, ProtocolFeature p_feature) {
	return (p_mask & static_cast<std::uint64_t>(p_feature)) != 0;
}

std::uint64_t supported_features();
Status negotiate_features(std::uint64_t p_local, std::uint64_t p_required_remote, std::uint64_t &r_missing_required);

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_VERSION_H
