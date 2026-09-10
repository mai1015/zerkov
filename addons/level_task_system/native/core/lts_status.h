#ifndef LEVEL_TASK_SYSTEM_CORE_STATUS_H
#define LEVEL_TASK_SYSTEM_CORE_STATUS_H

#include "core/lts_limits.h"

#include <cstdint>
#include <string>

// The native core is deliberately exception-free at its public boundaries.
// Validation and compatibility failures are values so the Godot adapter,
// headless tests, and a future server process observe the same result.
namespace lts {

enum class StatusCode : std::uint16_t {
	OK = 0,

	// Generic value validation.
	INVALID_ARGUMENT = 1,
	NOT_FOUND = 2,
	ALREADY_EXISTS = 3,
	OUT_OF_BOUNDS = 4,
	ARITHMETIC_ERROR = 5,
	CAPACITY_EXCEEDED = 6,
	LIMIT_EXCEEDED = CAPACITY_EXCEEDED,
	NOT_SUPPORTED = 7,
	INTERNAL_ERROR = 8,

	// Definitions and compatibility. Values are append-only.
	INVALID_IDENTIFIER = 20,
	DUPLICATE_DEFINITION = 21,
	UNKNOWN_DEFINITION = 22,
	INVALID_REFERENCE = 23,
	SCHEMA_MISMATCH = 24,
	CATALOG_SEALED = 25,
	REGISTRY_SEALED = CATALOG_SEALED,
	CATALOG_NOT_SEALED = 26,
	INCOMPATIBLE_DEFINITION = 27,
	INVALID_DEFINITION = 28,
	MANIFEST_MISMATCH = 29,
	CATALOG_FINGERPRINT_MISMATCH = MANIFEST_MISMATCH,

	// Authoring graph/value validation.
	INVALID_ENUM = 40,
	VALUE_OUT_OF_RANGE = 41,
	INVALID_VALUE = 42,
	GRAPH_INVALID = 43,
	CONVERSATION_INVALID = 44,
	PROVIDER_INVALID = 45,
	ANCHOR_INVALID = 46,
	EXIT_INVALID = 47,
};

// Stable diagnostic identities are presentation-neutral. The editor may map
// these to localized text, while tests and protocol code can compare the
// numeric value without depending on a UI string.
enum class DiagnosticId : std::uint16_t {
	NONE = 0,

	IDENTIFIER_EMPTY = 1,
	IDENTIFIER_EMPTY_SEGMENT = IDENTIFIER_EMPTY,
	IDENTIFIER_BAD_CHARACTER = 2,
	IDENTIFIER_INVALID = IDENTIFIER_BAD_CHARACTER,
	IDENTIFIER_NOT_NAMESPACED = 3,
	IDENTIFIER_TOO_LONG = 4,
	IDENTIFIER_TOO_MANY_SEGMENTS = 5,
	IDENTIFIER_SEGMENT_TOO_LONG = 6,
	SCHEMA_VERSION_UNSUPPORTED = 7,
	COUNT_LIMIT_EXCEEDED = 8,
	BYTE_LIMIT_EXCEEDED = 9,
	VALUE_OUT_OF_RANGE = 10,
	BOUNDS_INVERTED = 11,
	INVALID_ENUM = 12,
	VALUE_NOT_REPRESENTABLE = 13,
	DEFINITION_DUPLICATE = 14,
	DEFINITION_UNKNOWN_REFERENCE = 15,
	CANONICAL_ORDER_VIOLATION = 16,
	MANIFEST_FINGERPRINT_DIFFERS = 17,
	CATALOG_FINGERPRINT_DIFFERS = MANIFEST_FINGERPRINT_DIFFERS,
	PROTOCOL_VERSION_DIFFERS = 18,
	TRUNCATED_PAYLOAD = 19,

	GRAPH_IDENTIFIER_INVALID = 40,
	GRAPH_ENTRY_INVALID = 41,
	GRAPH_NODE_LIMIT = 42,
	GRAPH_EDGE_LIMIT = 43,
	GRAPH_PORT_LIMIT = 44,
	GRAPH_NODE_DUPLICATE = 45,
	GRAPH_EDGE_DUPLICATE = 46,
	GRAPH_NODE_REFERENCE_INVALID = 47,
	GRAPH_PORT_INVALID = 48,
	GRAPH_OUTCOME_INVALID = 49,
	GRAPH_PAYLOAD_INVALID = 50,

	LEVEL_SCENE_REFERENCE_INVALID = 60,
	LEVEL_ENTRY_GRAPH_INVALID = 61,
	LEVEL_ANCHOR_INVALID = 62,
	LEVEL_EXIT_INVALID = 63,
	LEVEL_AVAILABILITY_INVALID = 64,

	CONVERSATION_ENTRY_INVALID = 80,
	CONVERSATION_STEP_LIMIT = 81,
	CONVERSATION_STEP_DUPLICATE = 82,
	CONVERSATION_STEP_REFERENCE_INVALID = 83,
	CONVERSATION_SPEAKER_INVALID = 84,
	CONVERSATION_LINE_INVALID = 85,
	CONVERSATION_CHOICE_INVALID = 86,
	CONVERSATION_CHOICE_LIMIT = 87,
	CONVERSATION_OUTCOME_INVALID = 88,

	PROVIDER_IDENTIFIER_INVALID = 100,
	PROVIDER_KIND_INVALID = 101,
	PROVIDER_PAYLOAD_LIMIT = 102,
};

struct Status {
	StatusCode code = StatusCode::OK;
	DiagnosticId diagnostic = DiagnosticId::NONE;
	std::uint64_t detail = 0;

	bool ok() const { return code == StatusCode::OK; }

	bool operator==(const Status &p_other) const {
		return code == p_other.code && diagnostic == p_other.diagnostic && detail == p_other.detail;
	}
	bool operator!=(const Status &p_other) const { return !(*this == p_other); }
};

inline Status ok_status() {
	return Status{};
}

inline Status make_status(StatusCode p_code, DiagnosticId p_diagnostic = DiagnosticId::NONE, std::uint64_t p_detail = 0) {
	return Status{ p_code, p_diagnostic, p_detail };
}

// A bounded, deterministic finding payload. It intentionally carries a path
// rather than an arbitrary error string: callers can render a useful message
// without allowing untrusted content to make diagnostics unbounded.
struct Diagnostic {
	DiagnosticId id = DiagnosticId::NONE;
	std::uint64_t detail = 0;
	std::string path;

	Status validate() const {
		if (path.size() > MAX_DIAGNOSTIC_PATH_BYTES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, path.size());
		}
		return ok_status();
	}

	bool operator==(const Diagnostic &p_other) const {
		return id == p_other.id && detail == p_other.detail && path == p_other.path;
	}
	bool operator!=(const Diagnostic &p_other) const { return !(*this == p_other); }
	bool operator<(const Diagnostic &p_other) const {
		if (path != p_other.path) return path < p_other.path;
		if (id != p_other.id) return static_cast<std::uint16_t>(id) < static_cast<std::uint16_t>(p_other.id);
		return detail < p_other.detail;
	}
};

inline bool is_known_status_code(std::uint16_t p_raw) {
	switch (static_cast<StatusCode>(p_raw)) {
		case StatusCode::OK:
		case StatusCode::INVALID_ARGUMENT:
		case StatusCode::NOT_FOUND:
		case StatusCode::ALREADY_EXISTS:
		case StatusCode::OUT_OF_BOUNDS:
		case StatusCode::ARITHMETIC_ERROR:
		case StatusCode::CAPACITY_EXCEEDED:
		case StatusCode::NOT_SUPPORTED:
		case StatusCode::INTERNAL_ERROR:
		case StatusCode::INVALID_IDENTIFIER:
		case StatusCode::DUPLICATE_DEFINITION:
		case StatusCode::UNKNOWN_DEFINITION:
		case StatusCode::INVALID_REFERENCE:
		case StatusCode::SCHEMA_MISMATCH:
		case StatusCode::CATALOG_SEALED:
		case StatusCode::CATALOG_NOT_SEALED:
		case StatusCode::INCOMPATIBLE_DEFINITION:
		case StatusCode::INVALID_DEFINITION:
		case StatusCode::MANIFEST_MISMATCH:
		case StatusCode::INVALID_ENUM:
		case StatusCode::VALUE_OUT_OF_RANGE:
		case StatusCode::INVALID_VALUE:
		case StatusCode::GRAPH_INVALID:
		case StatusCode::CONVERSATION_INVALID:
		case StatusCode::PROVIDER_INVALID:
		case StatusCode::ANCHOR_INVALID:
		case StatusCode::EXIT_INVALID:
			return true;
	}
	return false;
}

inline bool is_known_diagnostic_id(std::uint16_t p_raw) {
	switch (static_cast<DiagnosticId>(p_raw)) {
		case DiagnosticId::NONE:
		case DiagnosticId::IDENTIFIER_EMPTY:
		case DiagnosticId::IDENTIFIER_BAD_CHARACTER:
		case DiagnosticId::IDENTIFIER_NOT_NAMESPACED:
		case DiagnosticId::IDENTIFIER_TOO_LONG:
		case DiagnosticId::IDENTIFIER_TOO_MANY_SEGMENTS:
		case DiagnosticId::IDENTIFIER_SEGMENT_TOO_LONG:
		case DiagnosticId::SCHEMA_VERSION_UNSUPPORTED:
		case DiagnosticId::COUNT_LIMIT_EXCEEDED:
		case DiagnosticId::BYTE_LIMIT_EXCEEDED:
		case DiagnosticId::VALUE_OUT_OF_RANGE:
		case DiagnosticId::BOUNDS_INVERTED:
		case DiagnosticId::INVALID_ENUM:
		case DiagnosticId::VALUE_NOT_REPRESENTABLE:
		case DiagnosticId::DEFINITION_DUPLICATE:
		case DiagnosticId::DEFINITION_UNKNOWN_REFERENCE:
		case DiagnosticId::CANONICAL_ORDER_VIOLATION:
		case DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS:
		case DiagnosticId::PROTOCOL_VERSION_DIFFERS:
		case DiagnosticId::TRUNCATED_PAYLOAD:
		case DiagnosticId::GRAPH_IDENTIFIER_INVALID:
		case DiagnosticId::GRAPH_ENTRY_INVALID:
		case DiagnosticId::GRAPH_NODE_LIMIT:
		case DiagnosticId::GRAPH_EDGE_LIMIT:
		case DiagnosticId::GRAPH_PORT_LIMIT:
		case DiagnosticId::GRAPH_NODE_DUPLICATE:
		case DiagnosticId::GRAPH_EDGE_DUPLICATE:
		case DiagnosticId::GRAPH_NODE_REFERENCE_INVALID:
		case DiagnosticId::GRAPH_PORT_INVALID:
		case DiagnosticId::GRAPH_OUTCOME_INVALID:
		case DiagnosticId::GRAPH_PAYLOAD_INVALID:
		case DiagnosticId::LEVEL_SCENE_REFERENCE_INVALID:
		case DiagnosticId::LEVEL_ENTRY_GRAPH_INVALID:
		case DiagnosticId::LEVEL_ANCHOR_INVALID:
		case DiagnosticId::LEVEL_EXIT_INVALID:
		case DiagnosticId::LEVEL_AVAILABILITY_INVALID:
		case DiagnosticId::CONVERSATION_ENTRY_INVALID:
		case DiagnosticId::CONVERSATION_STEP_LIMIT:
		case DiagnosticId::CONVERSATION_STEP_DUPLICATE:
		case DiagnosticId::CONVERSATION_STEP_REFERENCE_INVALID:
		case DiagnosticId::CONVERSATION_SPEAKER_INVALID:
		case DiagnosticId::CONVERSATION_LINE_INVALID:
		case DiagnosticId::CONVERSATION_CHOICE_INVALID:
		case DiagnosticId::CONVERSATION_CHOICE_LIMIT:
		case DiagnosticId::CONVERSATION_OUTCOME_INVALID:
		case DiagnosticId::PROVIDER_IDENTIFIER_INVALID:
		case DiagnosticId::PROVIDER_KIND_INVALID:
		case DiagnosticId::PROVIDER_PAYLOAD_LIMIT:
			return true;
	}
	return false;
}

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_STATUS_H
