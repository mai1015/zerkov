#ifndef WEAPON_SYSTEM_GODOT_VERSION_H
#define WEAPON_SYSTEM_GODOT_VERSION_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class WeaponSystemVersion : public RefCounted {
	GDCLASS(WeaponSystemVersion, RefCounted)

public:
	enum FeatureFlag {
		FEATURE_CATALOG_MANIFEST = 1 << 0,
		FEATURE_SEMI_AUTO = 1 << 1,
		FEATURE_HITSCAN_2D = 1 << 2,
		FEATURE_SIMPLE_RELOAD = 1 << 3,
		FEATURE_SNAPSHOTS = 1 << 4,
	};

	static String get_api_version();
	static int get_api_version_major();
	static int get_api_version_minor();
	static int get_api_version_patch();
	static int get_protocol_version();
	static int get_resource_schema_version();
	static String get_manifest_algorithm();
	static int64_t get_supported_features();
	static bool has_feature(int64_t p_feature);

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(WeaponSystemVersion::FeatureFlag);

#endif // WEAPON_SYSTEM_GODOT_VERSION_H
