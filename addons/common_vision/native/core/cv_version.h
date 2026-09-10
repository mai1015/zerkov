#ifndef COMMON_VISION_CORE_VERSION_H
#define COMMON_VISION_CORE_VERSION_H

#include "core/cv_limits.h"

#include <cstdint>
#include <string>

namespace cv {

constexpr int api_version_major() { return API_VERSION_MAJOR; }
constexpr int api_version_minor() { return API_VERSION_MINOR; }
constexpr int api_version_patch() { return API_VERSION_PATCH; }
constexpr std::uint16_t protocol_version() { return PROTOCOL_VERSION; }
constexpr std::uint16_t algorithm_contract_version() {
	return ALGORITHM_CONTRACT_VERSION;
}
constexpr std::int64_t coordinate_scale() { return COORDINATE_SCALE; }

std::string api_version_string();

} // namespace cv

#endif // COMMON_VISION_CORE_VERSION_H
