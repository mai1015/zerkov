#include "core/ga_version.h"

namespace ga {

std::string api_version_string() {
	return std::to_string(api_version_major()) + "." + std::to_string(api_version_minor()) + "." +
			std::to_string(api_version_patch());
}

std::uint32_t supported_features() {
	return FeatureSet::PREDICTION | FeatureSet::DEDICATED_SERVER | FeatureSet::SNAPSHOT_RESYNC |
			FeatureSet::PERIODIC_EFFECTS | FeatureSet::GAMEPLAY_EVENTS |
			FeatureSet::ABILITY_TASKS | FeatureSet::TYPED_TARGETING |
			FeatureSet::OBSERVER_TASK_STATE | FeatureSet::DELTA_REPLICATION;
}

Status negotiate_features(std::uint32_t p_local, std::uint32_t p_remote, std::uint32_t &r_missing_required) {
	r_missing_required = p_remote & ~p_local;
	if (r_missing_required != 0) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::FEATURE_UNSUPPORTED, r_missing_required);
	}
	return ok_status();
}

} // namespace ga
