#ifndef WEAPON_SYSTEM_CORE_STATUS_H
#define WEAPON_SYSTEM_CORE_STATUS_H

#include <cstdint>

namespace wpn {

enum class StatusCode : std::uint16_t {
	OK = 0,
	INVALID_ARGUMENT = 1,
	NOT_FOUND = 2,
	ALREADY_EXISTS = 3,
	LIMIT_EXCEEDED = 4,
	NOT_SUPPORTED = 5,
	INTERNAL_ERROR = 6,
	ARITHMETIC_ERROR = 7,
	INVALID_IDENTIFIER = 20,
	DUPLICATE_DEFINITION = 21,
	UNKNOWN_DEFINITION = 22,
	INVALID_REFERENCE = 23,
	CATALOG_SEALED = 24,
	CATALOG_NOT_SEALED = 25,
	MANIFEST_MISMATCH = 40,
	PROTOCOL_MISMATCH = 41,
	SCHEMA_MISMATCH = 42,
	FEATURE_UNSUPPORTED = 43,
	API_MISMATCH = 44,
	REVISION_MISMATCH = 60,
	DUPLICATE_CONFLICT = 61,
	COMMAND_REJECTED = 62,
	SNAPSHOT_REQUIRED = 63,
	// World-port/coordinator status codes (task 6.1/6.4/6.5/6.8). These cover
	// the post-commit world-resolution transaction: bounded checked-integer
	// geometry quantization, the world-adapter query/dispatch ports, and the
	// exactly-one-canonical-damage-sink configuration gate. They are distinct
	// from the mechanical `COMMAND_REJECTED` family above, which only covers
	// pre-mutation fire/reload/teardown command admission. Checked-arithmetic
	// faults reuse the shared ARITHMETIC_ERROR = 7 above.
	WORLD_QUERY_FAILED = 65,
	SINK_MISCONFIGURED = 66,
	SINK_DISPATCH_FAILED = 67,
	// --- Protocol/admission-gate layer (tasks.md 7.1-7.4), additive. ---
	DECODE_FAILED = 80,
	PAYLOAD_TOO_LARGE = 81,
	SESSION_NOT_READY = 82,
	PERMISSION_DENIED = 83,
	RATE_LIMITED = 84,
	// --- Authority envelope / recoil / attachment / ballistic-profile /
	// prepared reload-completion participant layer (tasks.md 4.10-4.14),
	// additive. UNHEALTHY covers the "affected runtime remains unavailable
	// until trusted epoch replacement" case (weapon-runtime spec, "Canonical
	// Revision and Authority-Tick Semantics").
	UNHEALTHY = 90,
};

enum class DiagnosticId : std::uint16_t {
	NONE = 0,
	IDENTIFIER_INVALID = 1,
	IDENTIFIER_TOO_LONG = 2,
	SOURCE_LABEL_TOO_LONG = 3,
	COUNT_LIMIT_EXCEEDED = 4,
	BYTE_LIMIT_EXCEEDED = 5,
	INVALID_ENUM = 6,
	VALUE_OUT_OF_RANGE = 7,
	NON_FINITE_VALUE = 8,
	OVERFLOW_DETECTED = 9,
	NESTED_ATTACHMENT_REJECTED = 10,
	DEFINITION_DUPLICATE = 20,
	DEFINITION_UNKNOWN_REFERENCE = 21,
	CATALOG_ALREADY_SEALED = 22,
	CATALOG_REQUIRES_SEAL = 23,
	MANIFEST_FINGERPRINT_DIFFERS = 40,
	PROTOCOL_VERSION_DIFFERS = 41,
	SCHEMA_VERSION_UNSUPPORTED = 42,
	FEATURE_SET_UNSUPPORTED = 43,
	API_VERSION_DIFFERS = 44,
	INSTANCE_UNKNOWN = 60,
	INSTANCE_DUPLICATE = 61,
	REVISION_STALE = 62,
	COMMAND_DUPLICATE_CONFLICT = 63,
	ACTOR_NOT_LIVE = 64,
	WEAPON_NOT_USABLE = 65,
	WEAPON_NOT_EQUIPPED = 77,
	WEAPON_RELOADING = 66,
	WEAPON_NOT_RELOADING = 67,
	CADENCE_NOT_ELAPSED = 68,
	OUT_OF_AMMO = 69,
	ORIGIN_MISMATCH = 70,
	AIM_MISMATCH = 71,
	RESERVATION_REQUIRED = 72,
	RELOAD_NOT_NEEDED = 73,
	RELOAD_QUANTITY_INVALID = 74,
	TICK_REVERSED = 75,
	SEQUENCE_STALE = 76,
	// NOTE: WEAPON_NOT_EQUIPPED = 77 is declared above, out of numeric order.
	// World-port/coordinator diagnostics (task 6.1/6.4/6.5/6.8) continue from
	// the next unused value, 79. Quantization overflow reuses the shared
	// OVERFLOW_DETECTED = 9 above.
	WORLD_TARGET_QUERY_FAILED = 79,
	WORLD_OBSTRUCTION_QUERY_FAILED = 80,
	WORLD_PORT_MISSING = 81,
	DAMAGE_SINK_COUNT_INVALID = 82,
	DAMAGE_SINK_REJECTED = 83,
	DAMAGE_SINK_AMBIGUOUS = 84,
	DECODE_TRUNCATED = 90,
	// --- Protocol/admission-gate layer (tasks.md 7.1-7.4), additive. ---
	TRAILING_PAYLOAD_BYTES = 100,
	CONNECTION_EPOCH_STALE = 101,
	SESSION_UNKNOWN = 102,
	ACTOR_BINDING_DENIED = 103,
	ROLE_INSUFFICIENT = 104,
	CONTENT_NOT_READY = 105,
	COMMAND_RATE_EXCEEDED = 106,
	REPLICA_REVISION_GAP = 107,
	REPLICA_DUPLICATE_DELTA = 108,
	REPLICA_IMPOSSIBLE_TRANSITION = 109,
	// --- Authority envelope / recoil / attachment / ballistic-profile /
	// prepared reload-completion participant layer (tasks.md 4.10-4.14),
	// additive; continues from the next unused value, 110. ---
	AUTHORITY_SCOPE_MISMATCH = 110,
	AUTHORITY_EPOCH_MISMATCH = 111,
	AUTHORITY_TICK_REGRESSION = 112,
	DUPLICATE_OUTCOME_EVICTED = 113,
	RUNTIME_UNHEALTHY = 114,
	TICK_ARITHMETIC_OVERFLOW = 115,
	ATTACHMENT_SLOT_UNKNOWN = 116,
	ATTACHMENT_SLOT_DUPLICATE = 117,
	ATTACHMENT_UNKNOWN_REFERENCE = 118,
	ATTACHMENT_SLOT_INCOMPATIBLE = 119,
	ATTACHMENT_CONFIG_DURING_RELOAD = 120,
	PROFILE_UNKNOWN_REFERENCE = 121,
	PROFILE_TRAIT_MISMATCH = 122,
	PROFILE_TOPUP_MISMATCH = 123,
	PROFILE_REQUIRED = 124,
	PROFILE_MUST_BE_ABSENT = 125,
	RELOAD_PARTICIPANT_STATE_INVALID = 126,
	RELOAD_PARTICIPANT_UNKNOWN = 127,
	TOMBSTONED_INSTANCE = 128,
	// --- World-coordinator unresolved-consequence retention (task 6.8
	// remainder), additive; continues from the next unused value, 129. ---
	UNRESOLVED_CONSEQUENCE_UNKNOWN = 129,
};

enum class Rejection : std::uint16_t {
	NONE = 0,
	UNKNOWN_INSTANCE = 1,
	REVISION_MISMATCH = 2,
	DUPLICATE_CONFLICT = 3,
	ACTOR_NOT_LIVE = 4,
	WEAPON_NOT_USABLE = 5,
	WEAPON_RELOADING = 6,
	WEAPON_NOT_RELOADING = 7,
	CADENCE_NOT_ELAPSED = 8,
	OUT_OF_AMMO = 9,
	ORIGIN_MISMATCH = 10,
	AIM_MISMATCH = 11,
	MALFORMED_COMMAND = 12,
	RESERVATION_REQUIRED = 13,
	RELOAD_NOT_NEEDED = 14,
	RELOAD_QUANTITY_INVALID = 15,
	TICK_REVERSED = 16,
	SEQUENCE_STALE = 17,
	WEAPON_NOT_EQUIPPED = 18,
	// --- Authority envelope / recoil / attachment / ballistic-profile /
	// prepared reload-completion participant layer (tasks.md 4.10-4.14),
	// additive. ---
	AUTHORITY_SCOPE_MISMATCH = 19,
	AUTHORITY_EPOCH_MISMATCH = 20,
	AUTHORITY_TICK_REGRESSION = 21,
	DUPLICATE_OUTCOME_EVICTED = 22,
	RUNTIME_UNHEALTHY = 23,
	TICK_ARITHMETIC_FAULT = 24,
	ATTACHMENT_INVALID = 25,
	PROFILE_INVALID = 26,
	RELOAD_PARTICIPANT_INVALID = 27,
};

struct Status {
	StatusCode code = StatusCode::OK;
	DiagnosticId diagnostic = DiagnosticId::NONE;
	std::uint64_t detail = 0;

	bool ok() const { return code == StatusCode::OK; }
	bool operator==(const Status &p_other) const {
		return code == p_other.code && diagnostic == p_other.diagnostic && detail == p_other.detail;
	}
};

inline Status ok_status() { return {}; }
inline Status make_status(StatusCode p_code, DiagnosticId p_diagnostic = DiagnosticId::NONE, std::uint64_t p_detail = 0) {
	return { p_code, p_diagnostic, p_detail };
}

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_STATUS_H
