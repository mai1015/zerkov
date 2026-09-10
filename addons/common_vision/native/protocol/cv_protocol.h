#ifndef COMMON_VISION_PROTOCOL_PROTOCOL_H
#define COMMON_VISION_PROTOCOL_PROTOCOL_H

#include "core/cv_limits.h"
#include "core/cv_status.h"
#include "core/cv_world.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace cv::protocol {

constexpr std::uint32_t SNAPSHOT_MAGIC = UINT32_C(0x31535643); // CVS1
constexpr std::uint32_t DELTA_MAGIC = UINT32_C(0x31445643); // CVD1
constexpr std::size_t MAX_PROTOCOL_BYTES = 16 * 1024 * 1024;

struct Manifest {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint16_t algorithm_version = ALGORITHM_CONTRACT_VERSION;
};

struct Snapshot {
	Manifest manifest;
	WorldId world;
	// Canonical wire streams use the recipient projection result revision as
	// their sequence. Encode/decode reject a mismatched pair.
	Revision sequence = 0;
	ObserverProjection projection;
};

struct Delta {
	Manifest manifest;
	WorldId world;
	Revision predecessor = 0;
	// Must equal predecessor + 1 and projection.result_revision.
	Revision successor = 0;
	ObserverProjection projection;
};

Status encode_snapshot(const Snapshot &p_snapshot,
		std::vector<std::uint8_t> &r_bytes);
Status decode_snapshot(const std::uint8_t *p_data, std::size_t p_size,
		Snapshot &r_snapshot);

Status encode_delta(const Delta &p_delta, std::vector<std::uint8_t> &r_bytes);
Status decode_delta(const std::uint8_t *p_data, std::size_t p_size,
		Delta &r_delta);

// Applies only an exact, canonical successor. Duplicates/stale packets, gaps,
// malformed record semantics, and sequence/projection mismatches are rejected
// without mutating the current snapshot.
Status apply_delta(Snapshot &r_current, const Delta &p_delta);

std::uint64_t stable_hash(const std::vector<std::uint8_t> &p_bytes);

} // namespace cv::protocol

#endif // COMMON_VISION_PROTOCOL_PROTOCOL_H
