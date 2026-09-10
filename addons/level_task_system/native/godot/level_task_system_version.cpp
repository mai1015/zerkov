#include "godot/level_task_system_version.h"

#include "core/lts_limits.h"

#include <godot_cpp/core/class_db.hpp>

#include <string>

namespace {

constexpr int SNAPSHOT_SCHEMA_VERSION = 1;

} // namespace

namespace godot {

String LevelTaskSystemVersion::get_api_version() {
	const std::string version =
			std::to_string(lts::API_VERSION_MAJOR) + "." +
			std::to_string(lts::API_VERSION_MINOR) + "." +
			std::to_string(lts::API_VERSION_PATCH);
	return String(version.c_str());
}

int LevelTaskSystemVersion::get_api_version_major() {
	return lts::API_VERSION_MAJOR;
}

int LevelTaskSystemVersion::get_api_version_minor() {
	return lts::API_VERSION_MINOR;
}

int LevelTaskSystemVersion::get_api_version_patch() {
	return lts::API_VERSION_PATCH;
}

int LevelTaskSystemVersion::get_protocol_version() {
	return 1;
}

int LevelTaskSystemVersion::get_level_definition_schema_version() {
	return lts::LEVEL_DEFINITION_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_task_graph_definition_schema_version() {
	return lts::TASK_GRAPH_DEFINITION_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_conversation_definition_schema_version() {
	return lts::CONVERSATION_DEFINITION_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_speaker_definition_schema_version() {
	return lts::SPEAKER_DEFINITION_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_provider_definition_schema_version() {
	return lts::PROVIDER_DEFINITION_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_resource_schema_version() {
	return lts::RESOURCE_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_snapshot_schema_version() {
	return SNAPSHOT_SCHEMA_VERSION;
}

int LevelTaskSystemVersion::get_canonical_format_version() {
	return lts::CANONICAL_FORMAT_VERSION;
}

String LevelTaskSystemVersion::get_catalog_fingerprint_algorithm() {
	return String(lts::CATALOG_FINGERPRINT_ALGORITHM);
}

String LevelTaskSystemVersion::get_manifest_algorithm() {
	return String(lts::MANIFEST_ALGORITHM);
}

int64_t LevelTaskSystemVersion::get_supported_features() {
	return FEATURE_LEVEL_DEFINITIONS | FEATURE_TASK_GRAPHS |
			FEATURE_CONVERSATIONS | FEATURE_CATALOG_VALIDATION |
			FEATURE_SNAPSHOTS | FEATURE_DETERMINISTIC_RUNTIME;
}

bool LevelTaskSystemVersion::has_feature(int64_t p_feature) {
	return p_feature != 0 &&
			(get_supported_features() & p_feature) == p_feature;
}

void LevelTaskSystemVersion::_bind_methods() {
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_api_version"),
			&LevelTaskSystemVersion::get_api_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_api_version_major"),
			&LevelTaskSystemVersion::get_api_version_major);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_api_version_minor"),
			&LevelTaskSystemVersion::get_api_version_minor);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_api_version_patch"),
			&LevelTaskSystemVersion::get_api_version_patch);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_protocol_version"),
			&LevelTaskSystemVersion::get_protocol_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_level_definition_schema_version"),
			&LevelTaskSystemVersion::get_level_definition_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_task_graph_definition_schema_version"),
			&LevelTaskSystemVersion::get_task_graph_definition_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_conversation_definition_schema_version"),
			&LevelTaskSystemVersion::get_conversation_definition_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_speaker_definition_schema_version"),
			&LevelTaskSystemVersion::get_speaker_definition_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_provider_definition_schema_version"),
			&LevelTaskSystemVersion::get_provider_definition_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_resource_schema_version"),
			&LevelTaskSystemVersion::get_resource_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_snapshot_schema_version"),
			&LevelTaskSystemVersion::get_snapshot_schema_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_canonical_format_version"),
			&LevelTaskSystemVersion::get_canonical_format_version);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_catalog_fingerprint_algorithm"),
			&LevelTaskSystemVersion::get_catalog_fingerprint_algorithm);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_manifest_algorithm"),
			&LevelTaskSystemVersion::get_manifest_algorithm);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("get_supported_features"),
			&LevelTaskSystemVersion::get_supported_features);
	ClassDB::bind_static_method("LevelTaskSystemVersion",
			D_METHOD("has_feature", "feature"),
			&LevelTaskSystemVersion::has_feature);

	BIND_ENUM_CONSTANT(FEATURE_LEVEL_DEFINITIONS);
	BIND_ENUM_CONSTANT(FEATURE_TASK_GRAPHS);
	BIND_ENUM_CONSTANT(FEATURE_CONVERSATIONS);
	BIND_ENUM_CONSTANT(FEATURE_CATALOG_VALIDATION);
	BIND_ENUM_CONSTANT(FEATURE_SNAPSHOTS);
	BIND_ENUM_CONSTANT(FEATURE_DETERMINISTIC_RUNTIME);
}

} // namespace godot
