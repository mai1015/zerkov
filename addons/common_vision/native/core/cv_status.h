#ifndef COMMON_VISION_CORE_STATUS_H
#define COMMON_VISION_CORE_STATUS_H

#include <cstdint>

namespace cv {

enum class StatusCode : std::uint16_t {
	OK = 0,
	INVALID_ARGUMENT = 1,
	NOT_FOUND = 2,
	ALREADY_EXISTS = 3,
	LIMIT_EXCEEDED = 4,
	ARITHMETIC_ERROR = 5,
	REVISION_MISMATCH = 6,
	ROLE_VIOLATION = 7,
	SNAPSHOT_REQUIRED = 8,
	INCOMPATIBLE = 9,
	INTERNAL_ERROR = 10,
};

enum class DiagnosticId : std::uint16_t {
	NONE = 0,
	INVALID_IDENTITY = 1,
	NON_POSITIVE_RANGE = 2,
	INVALID_DIRECTION = 3,
	INVALID_CONE = 4,
	INVALID_MASK = 5,
	INVALID_SAMPLE_POLICY = 6,
	COUNT_LIMIT_EXCEEDED = 7,
	COORDINATE_OUT_OF_RANGE = 8,
	COORDINATE_OVERFLOW = 9,
	ZERO_LENGTH_SEGMENT = 10,
	DUPLICATE_SEGMENT = 11,
	GEOMETRY_REVISION_STALE = 12,
	WORLD_REVISION_STALE = 13,
	OBSERVER_REVISION_STALE = 14,
	TARGET_REVISION_STALE = 15,
	WORK_BUDGET_EXCEEDED = 16,
	PROJECTION_STALE = 17,
	PROTOCOL_VERSION_DIFFERS = 18,
	ALGORITHM_VERSION_DIFFERS = 19,
	TRUNCATED_PAYLOAD = 20,
	PAYLOAD_TOO_LARGE = 21,
	INVALID_ENUM = 22,
	ROLE_IS_REPLICA = 23,
};

struct Status {
	StatusCode code = StatusCode::OK;
	DiagnosticId diagnostic = DiagnosticId::NONE;
	std::uint64_t detail = 0;

	bool ok() const { return code == StatusCode::OK; }
	bool operator==(const Status &p_other) const {
		return code == p_other.code && diagnostic == p_other.diagnostic &&
				detail == p_other.detail;
	}
};

inline Status ok_status() {
	return {};
}

inline Status make_status(StatusCode p_code,
		DiagnosticId p_diagnostic = DiagnosticId::NONE,
		std::uint64_t p_detail = 0) {
	return { p_code, p_diagnostic, p_detail };
}

} // namespace cv

#endif // COMMON_VISION_CORE_STATUS_H
