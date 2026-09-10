#include "godot/common_vision_version.h"

#include "core/cv_version.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

String CommonVisionVersion::get_api_version() {
	return String(cv::api_version_string().c_str());
}

int CommonVisionVersion::get_protocol_version() {
	return cv::protocol_version();
}

int CommonVisionVersion::get_algorithm_contract_version() {
	return cv::algorithm_contract_version();
}

int64_t CommonVisionVersion::get_coordinate_scale() {
	return cv::coordinate_scale();
}

int CommonVisionVersion::get_supported_features() {
	return FEATURE_FIXED_POINT_LOS | FEATURE_VISIBILITY_MEMORY |
			FEATURE_BUDGET_SCHEDULER | FEATURE_SNAPSHOT_DELTA |
			FEATURE_DEDICATED_SERVER;
}

bool CommonVisionVersion::has_feature(int p_feature) {
	return (get_supported_features() & p_feature) == p_feature;
}

void CommonVisionVersion::_bind_methods() {
	ClassDB::bind_static_method("CommonVisionVersion",
			D_METHOD("get_api_version"), &CommonVisionVersion::get_api_version);
	ClassDB::bind_static_method("CommonVisionVersion",
			D_METHOD("get_protocol_version"),
			&CommonVisionVersion::get_protocol_version);
	ClassDB::bind_static_method("CommonVisionVersion",
			D_METHOD("get_algorithm_contract_version"),
			&CommonVisionVersion::get_algorithm_contract_version);
	ClassDB::bind_static_method("CommonVisionVersion",
			D_METHOD("get_coordinate_scale"),
			&CommonVisionVersion::get_coordinate_scale);
	ClassDB::bind_static_method("CommonVisionVersion",
			D_METHOD("get_supported_features"),
			&CommonVisionVersion::get_supported_features);
	ClassDB::bind_static_method("CommonVisionVersion",
			D_METHOD("has_feature", "feature"),
			&CommonVisionVersion::has_feature);

	BIND_ENUM_CONSTANT(FEATURE_FIXED_POINT_LOS);
	BIND_ENUM_CONSTANT(FEATURE_VISIBILITY_MEMORY);
	BIND_ENUM_CONSTANT(FEATURE_BUDGET_SCHEDULER);
	BIND_ENUM_CONSTANT(FEATURE_SNAPSHOT_DELTA);
	BIND_ENUM_CONSTANT(FEATURE_DEDICATED_SERVER);
}

} // namespace godot
