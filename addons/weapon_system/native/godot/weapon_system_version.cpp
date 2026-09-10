#include "godot/weapon_system_version.h"

#include "core/wpn_limits.h"
#include "core/wpn_version.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

String WeaponSystemVersion::get_api_version() {
	return String(wpn::api_version_string().c_str());
}

int WeaponSystemVersion::get_api_version_major() {
	return wpn::api_version_major();
}

int WeaponSystemVersion::get_api_version_minor() {
	return wpn::api_version_minor();
}

int WeaponSystemVersion::get_api_version_patch() {
	return wpn::api_version_patch();
}

int WeaponSystemVersion::get_protocol_version() {
	return static_cast<int>(wpn::protocol_version());
}

int WeaponSystemVersion::get_resource_schema_version() {
	return static_cast<int>(wpn::resource_schema_version());
}

String WeaponSystemVersion::get_manifest_algorithm() {
	return String(wpn::MANIFEST_ALGORITHM);
}

int64_t WeaponSystemVersion::get_supported_features() {
	return static_cast<int64_t>(wpn::supported_features());
}

bool WeaponSystemVersion::has_feature(int64_t p_feature) {
	const std::uint64_t feature = static_cast<std::uint64_t>(p_feature);
	return feature != 0 && (wpn::supported_features() & feature) == feature;
}

void WeaponSystemVersion::_bind_methods() {
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_api_version"), &WeaponSystemVersion::get_api_version);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_api_version_major"), &WeaponSystemVersion::get_api_version_major);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_api_version_minor"), &WeaponSystemVersion::get_api_version_minor);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_api_version_patch"), &WeaponSystemVersion::get_api_version_patch);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_protocol_version"), &WeaponSystemVersion::get_protocol_version);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_resource_schema_version"), &WeaponSystemVersion::get_resource_schema_version);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_manifest_algorithm"), &WeaponSystemVersion::get_manifest_algorithm);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("get_supported_features"), &WeaponSystemVersion::get_supported_features);
	ClassDB::bind_static_method("WeaponSystemVersion", D_METHOD("has_feature", "feature"), &WeaponSystemVersion::has_feature);

	BIND_ENUM_CONSTANT(FEATURE_CATALOG_MANIFEST);
	BIND_ENUM_CONSTANT(FEATURE_SEMI_AUTO);
	BIND_ENUM_CONSTANT(FEATURE_HITSCAN_2D);
	BIND_ENUM_CONSTANT(FEATURE_SIMPLE_RELOAD);
	BIND_ENUM_CONSTANT(FEATURE_SNAPSHOTS);
}

} // namespace godot
