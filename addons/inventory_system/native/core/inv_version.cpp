#include "core/inv_version.h"

namespace inv {

std::string api_version_string() {
	return std::to_string(api_version_major()) + "." + std::to_string(api_version_minor()) + "." +
			std::to_string(api_version_patch());
}

std::uint64_t supported_features() {
	return ProtocolFeature::CATALOG_MANIFEST |
			ProtocolFeature::MODULAR_PROFILES |
			ProtocolFeature::SPATIAL_GRID |
			ProtocolFeature::NAMED_SLOTS |
				ProtocolFeature::ORDERED_LIST |
				ProtocolFeature::TYPED_TRAITS |
				ProtocolFeature::FEATURE_MODULES |
				ProtocolFeature::TARGETED_PROVIDER_TRANSFER |
				ProtocolFeature::MUTABLE_COMPONENT_COMMANDS |
				ProtocolFeature::OBSERVER_REPLICATION;
}

Status negotiate_features(std::uint64_t p_local, std::uint64_t p_required_remote, std::uint64_t &r_missing_required) {
	r_missing_required = p_required_remote & ~p_local;
	if (r_missing_required != 0) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_SET_UNSUPPORTED, r_missing_required);
	}
	return ok_status();
}

} // namespace inv
