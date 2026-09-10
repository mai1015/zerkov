#include "godot/gameplay_ability_version.h"

#include "core/ga_version.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

String GameplayAbilityVersion::get_api_version() {
	return String(ga::api_version_string().c_str());
}

int GameplayAbilityVersion::get_api_version_major() {
	return ga::api_version_major();
}

int GameplayAbilityVersion::get_api_version_minor() {
	return ga::api_version_minor();
}

int GameplayAbilityVersion::get_api_version_patch() {
	return ga::api_version_patch();
}

int GameplayAbilityVersion::get_protocol_version() {
	return static_cast<int>(ga::protocol_version());
}

String GameplayAbilityVersion::get_manifest_algorithm() {
	return String(ga::manifest_algorithm());
}

int GameplayAbilityVersion::get_supported_features() {
	return static_cast<int>(ga::supported_features());
}

bool GameplayAbilityVersion::has_feature(int p_feature) {
	return ga::has_feature(ga::supported_features(), static_cast<ga::FeatureSet>(p_feature));
}

void GameplayAbilityVersion::_bind_methods() {
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_api_version"),
			&GameplayAbilityVersion::get_api_version);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_api_version_major"),
			&GameplayAbilityVersion::get_api_version_major);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_api_version_minor"),
			&GameplayAbilityVersion::get_api_version_minor);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_api_version_patch"),
			&GameplayAbilityVersion::get_api_version_patch);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_protocol_version"),
			&GameplayAbilityVersion::get_protocol_version);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_manifest_algorithm"),
			&GameplayAbilityVersion::get_manifest_algorithm);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("get_supported_features"),
			&GameplayAbilityVersion::get_supported_features);
	ClassDB::bind_static_method("GameplayAbilityVersion", D_METHOD("has_feature", "feature"),
			&GameplayAbilityVersion::has_feature);

	BIND_ENUM_CONSTANT(FEATURE_PREDICTION);
	BIND_ENUM_CONSTANT(FEATURE_DEDICATED_SERVER);
	BIND_ENUM_CONSTANT(FEATURE_SNAPSHOT_RESYNC);
	BIND_ENUM_CONSTANT(FEATURE_PERIODIC_EFFECTS);
	BIND_ENUM_CONSTANT(FEATURE_GAMEPLAY_EVENTS);
	BIND_ENUM_CONSTANT(FEATURE_ABILITY_TASKS);
	BIND_ENUM_CONSTANT(FEATURE_TYPED_TARGETING);
	BIND_ENUM_CONSTANT(FEATURE_OBSERVER_TASK_STATE);
	BIND_ENUM_CONSTANT(FEATURE_DELTA_REPLICATION);
}

} // namespace godot
