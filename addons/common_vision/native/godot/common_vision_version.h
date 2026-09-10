#ifndef COMMON_VISION_GODOT_VERSION_H
#define COMMON_VISION_GODOT_VERSION_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class CommonVisionVersion : public RefCounted {
	GDCLASS(CommonVisionVersion, RefCounted)

public:
	enum FeatureFlag {
		FEATURE_FIXED_POINT_LOS = 1 << 0,
		FEATURE_VISIBILITY_MEMORY = 1 << 1,
		FEATURE_BUDGET_SCHEDULER = 1 << 2,
		FEATURE_SNAPSHOT_DELTA = 1 << 3,
		FEATURE_DEDICATED_SERVER = 1 << 4,
	};

	static String get_api_version();
	static int get_protocol_version();
	static int get_algorithm_contract_version();
	static int64_t get_coordinate_scale();
	static int get_supported_features();
	static bool has_feature(int p_feature);

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(CommonVisionVersion::FeatureFlag);

#endif // COMMON_VISION_GODOT_VERSION_H
