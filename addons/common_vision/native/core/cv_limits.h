#ifndef COMMON_VISION_CORE_LIMITS_H
#define COMMON_VISION_CORE_LIMITS_H

#include <cstddef>
#include <cstdint>

namespace cv {

constexpr int API_VERSION_MAJOR = 0;
constexpr int API_VERSION_MINOR = 1;
constexpr int API_VERSION_PATCH = 0;
constexpr std::uint16_t PROTOCOL_VERSION = 1;
constexpr std::uint16_t ALGORITHM_CONTRACT_VERSION = 1;
constexpr std::int64_t COORDINATE_SCALE = 1000000;

constexpr std::size_t MAX_OBSERVERS = 4096;
constexpr std::size_t MAX_TARGETS = 16384;
constexpr std::size_t MAX_OCCLUDER_SEGMENTS = 131072;
constexpr std::size_t MAX_SAMPLES_PER_TARGET = 8;
constexpr std::size_t MAX_MEMORY_RECORDS_PER_OBSERVER = 16384;
constexpr std::size_t MAX_LISTENERS = 64;
// A broadphase query must reject its cell rectangle before iteration when it
// would visit more than this many buckets. This limit is independent of the
// number of targets actually stored in those buckets.
constexpr std::uint64_t MAX_VISITED_CELLS_PER_QUERY = UINT64_C(65536);
constexpr std::uint64_t MAX_WORK_PER_TICK = UINT64_C(10000000);
constexpr std::int64_t MAX_ABS_COORDINATE = INT64_C(4000000000000);

} // namespace cv

#endif // COMMON_VISION_CORE_LIMITS_H
