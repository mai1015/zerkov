#ifndef COMMON_VISION_CORE_IDS_H
#define COMMON_VISION_CORE_IDS_H

#include <cstdint>

namespace cv {

template <typename Tag>
struct Id {
	std::uint64_t value = 0;

	constexpr explicit operator bool() const { return value != 0; }
	bool operator==(const Id &p_other) const { return value == p_other.value; }
	bool operator!=(const Id &p_other) const { return value != p_other.value; }
	bool operator<(const Id &p_other) const { return value < p_other.value; }
};

struct WorldIdTag {};
struct ObserverIdTag {};
struct TargetIdTag {};
struct SegmentIdTag {};
struct ProfileIdTag {};

using WorldId = Id<WorldIdTag>;
using ObserverId = Id<ObserverIdTag>;
using TargetId = Id<TargetIdTag>;
using SegmentId = Id<SegmentIdTag>;
using ProfileId = Id<ProfileIdTag>;
using Tick = std::uint64_t;
using Revision = std::uint64_t;

} // namespace cv

#endif // COMMON_VISION_CORE_IDS_H
