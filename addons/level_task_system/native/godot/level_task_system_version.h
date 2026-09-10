#ifndef LEVEL_TASK_SYSTEM_GODOT_VERSION_H
#define LEVEL_TASK_SYSTEM_GODOT_VERSION_H

#include <cstdint>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

// Stable Godot-facing compatibility façade for the package foundation.
//
// The façade only consumes scalar compatibility constants from native/core;
// the core remains engine-independent and never includes godot-cpp. Keeping
// all values behind static methods gives GDScript and headless smoke tests a
// single discoverable contract.
class LevelTaskSystemVersion : public RefCounted {
	GDCLASS(LevelTaskSystemVersion, RefCounted)

public:
	enum FeatureFlag {
		FEATURE_LEVEL_DEFINITIONS = 1 << 0,
		FEATURE_TASK_GRAPHS = 1 << 1,
		FEATURE_CONVERSATIONS = 1 << 2,
		FEATURE_CATALOG_VALIDATION = 1 << 3,
		FEATURE_SNAPSHOTS = 1 << 4,
		FEATURE_DETERMINISTIC_RUNTIME = 1 << 5,
	};

	static String get_api_version();
	static int get_api_version_major();
	static int get_api_version_minor();
	static int get_api_version_patch();
	static int get_protocol_version();
	static int get_level_definition_schema_version();
	static int get_task_graph_definition_schema_version();
	static int get_conversation_definition_schema_version();
	static int get_speaker_definition_schema_version();
	static int get_provider_definition_schema_version();
	static int get_resource_schema_version();
	static int get_snapshot_schema_version();
	static int get_canonical_format_version();
	static String get_catalog_fingerprint_algorithm();
	static String get_manifest_algorithm();
	static int64_t get_supported_features();
	static bool has_feature(int64_t p_feature);

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(LevelTaskSystemVersion::FeatureFlag);

#endif // LEVEL_TASK_SYSTEM_GODOT_VERSION_H
