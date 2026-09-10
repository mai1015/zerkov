#ifndef LEVEL_TASK_SYSTEM_CORE_LIMITS_H
#define LEVEL_TASK_SYSTEM_CORE_LIMITS_H

#include <cstddef>
#include <cstdint>

// Values in this header are part of the engine-independent authoring contract.
// A value which is accepted by a Godot Resource and a value which is accepted
// by the native core must have the same bound.  Changing a bound that affects
// canonical bytes requires a schema/compatibility review and new fixtures.
namespace lts {

// ---------------------------------------------------------------------------
// Version and compatibility identity
// ---------------------------------------------------------------------------

constexpr int API_VERSION_MAJOR = 0;
constexpr int API_VERSION_MINOR = 1;
constexpr int API_VERSION_PATCH = 0;

// Additive schema changes are represented by a new schema value.  V1 has no
// migration table yet, therefore the first slice accepts exactly these values.
constexpr std::uint16_t LEVEL_DEFINITION_SCHEMA_VERSION = 1;
constexpr std::uint16_t TASK_GRAPH_DEFINITION_SCHEMA_VERSION = 1;
constexpr std::uint16_t CONVERSATION_DEFINITION_SCHEMA_VERSION = 1;
constexpr std::uint16_t SPEAKER_DEFINITION_SCHEMA_VERSION = 1;
constexpr std::uint16_t PROVIDER_DEFINITION_SCHEMA_VERSION = 1;
constexpr std::uint16_t CANONICAL_FORMAT_VERSION = 1;
constexpr std::uint16_t RESOURCE_SCHEMA_VERSION = 1;
constexpr std::uint16_t PROTOCOL_VERSION = 1;
constexpr std::uint16_t SNAPSHOT_SCHEMA_VERSION = 1;
constexpr std::int64_t FIXED_SCALE = 1000000;

// The algorithm name is exchanged/recorded with fingerprints so that a future
// hash change cannot silently compare values produced by different encoders.
constexpr const char *CATALOG_FINGERPRINT_ALGORITHM = "fnv1a64-canonical-v1";
constexpr const char *MANIFEST_ALGORITHM = CATALOG_FINGERPRINT_ALGORITHM;
using CatalogFingerprint = std::uint64_t;
constexpr CatalogFingerprint INVALID_CATALOG_FINGERPRINT = 0;

// The core does not execute authored content.  These declarations make that
// boundary explicit for callers and future adapters.
constexpr bool CORE_EXECUTES_AUTHORED_CODE = false;

// ---------------------------------------------------------------------------
// Stable identifiers and bounded text
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_IDENTIFIER_BYTES = 128;
constexpr std::size_t MAX_IDENTIFIER_SEGMENTS = 8;
constexpr std::size_t MAX_IDENTIFIER_SEGMENT_BYTES = 32;
constexpr std::size_t MAX_STRING_BYTES = 256;
constexpr std::size_t MAX_LOCALIZATION_KEY_BYTES = 128;
constexpr std::size_t MAX_SCENE_RESOURCE_BYTES = 512;
constexpr std::size_t MAX_DIAGNOSTIC_PATH_BYTES = 256;

// ---------------------------------------------------------------------------
// Catalog and definition collection bounds
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_LEVEL_DEFINITIONS = 1024;
constexpr std::size_t MAX_TASK_GRAPH_DEFINITIONS = 2048;
constexpr std::size_t MAX_CONVERSATION_DEFINITIONS = 2048;
constexpr std::size_t MAX_SPEAKER_DEFINITIONS = 512;
constexpr std::size_t MAX_PROVIDER_DECLARATIONS = 512;

constexpr std::size_t MAX_ENTRY_GRAPHS_PER_LEVEL = 32;
constexpr std::size_t MAX_AVAILABILITY_RULES = 32;
constexpr std::size_t MAX_ANCHORS_PER_LEVEL = 128;
constexpr std::size_t MAX_EXITS_PER_LEVEL = 64;

constexpr std::size_t MAX_NODES_PER_TASK_GRAPH = 256;
constexpr std::size_t MAX_EDGES_PER_TASK_GRAPH = 512;
constexpr std::size_t MAX_PORTS_PER_TASK_NODE = 16;
constexpr std::size_t MAX_TERMINAL_OUTCOMES = 32;
constexpr std::size_t MAX_NODE_PARAMETERS = 16;
constexpr std::size_t MAX_NODE_FILTERS = 16;

constexpr std::size_t MAX_STEPS_PER_CONVERSATION = 512;
constexpr std::size_t MAX_SPEAKERS_PER_CONVERSATION = 64;
constexpr std::size_t MAX_CHOICES_PER_CONVERSATION_STEP = 16;
constexpr std::size_t MAX_CHOICE_CONDITIONS = 8;
constexpr std::size_t MAX_LINE_PARAMETERS = 8;

// ---------------------------------------------------------------------------
// Payload and scalar bounds
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_VALUE_BYTES = 1024;
constexpr std::size_t MAX_PROVIDER_PAYLOAD_BYTES = 4096;
constexpr std::size_t MAX_PARAMETERS_BYTES = 4096;
constexpr std::size_t MAX_LOCALIZED_PARAMETERS = 8;
constexpr std::size_t MAX_EVENT_FILTERS = 16;

constexpr std::uint32_t MAX_OBJECTIVE_TARGET = 1000000;
constexpr std::uint32_t MAX_TRANSITIONS_PER_ADVANCE = 1024;
constexpr std::uint32_t MAX_CONVERSATION_STEPS_PER_ADVANCE = 1024;
constexpr std::uint32_t MAX_JUMPS_PER_ADVANCE = 256;
constexpr std::uint32_t MAX_SUBGRAPH_DEPTH = 16;
constexpr std::uint32_t MAX_PENDING_REQUESTS = 64;
constexpr std::size_t MAX_EVENTS_PER_ADVANCE = 128;
constexpr std::size_t MAX_TRACE_RECORDS = 1024;
constexpr std::size_t MAX_STATE_CHANGE_RECORDS = 512;
constexpr std::size_t MAX_SNAPSHOT_BYTES = 1048576;

// A scene anchor is a description only; no native definition may retain a
// live Object, Node, RID, pointer, or engine path object.
constexpr std::size_t MAX_ANCHOR_BINDING_LABEL_BYTES = 128;

// ---------------------------------------------------------------------------
// Compatibility helpers
// ---------------------------------------------------------------------------

constexpr bool schema_version_supported(std::uint16_t p_version, std::uint16_t p_supported) {
	return p_version != 0 && p_version == p_supported;
}

constexpr bool schema_version_compatible(std::uint16_t p_local, std::uint16_t p_remote) {
	// V1 has no additive compatibility window. Keep this helper instead of
	// scattering equality checks through adapters so a future migration policy
	// has one explicit seam.
	return p_local != 0 && p_local == p_remote;
}

} // namespace lts

#endif // LEVEL_TASK_SYSTEM_CORE_LIMITS_H
