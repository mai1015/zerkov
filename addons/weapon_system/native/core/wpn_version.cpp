#include "core/wpn_version.h"

#include "core/wpn_hash.h"

namespace wpn {

std::uint64_t CompatibilityManifest::fingerprint() const {
	Hasher h;
	h.write_u16(api_major);
	h.write_u16(api_minor);
	h.write_u16(api_patch);
	h.write_u16(protocol);
	h.write_u16(resource_schema);
	h.write_u64(features);
	h.write_u64(catalog_fingerprint);
	h.write_u16(world_quantization_version);
	h.write_u16(world_tie_rule_version);
	return h.digest();
}

std::string api_version_string() {
	return std::to_string(API_VERSION_MAJOR) + "." + std::to_string(API_VERSION_MINOR) + "." + std::to_string(API_VERSION_PATCH);
}

std::uint64_t supported_features() {
	return static_cast<std::uint64_t>(ProtocolFeature::CATALOG_MANIFEST) |
			static_cast<std::uint64_t>(ProtocolFeature::SEMI_AUTO) |
			static_cast<std::uint64_t>(ProtocolFeature::HITSCAN_2D) |
			static_cast<std::uint64_t>(ProtocolFeature::SIMPLE_RELOAD) |
			static_cast<std::uint64_t>(ProtocolFeature::SNAPSHOTS);
}

Status negotiate_features(std::uint64_t p_local, std::uint64_t p_required, std::uint64_t &r_missing) {
	r_missing = p_required & ~p_local;
	if (r_missing != 0) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_SET_UNSUPPORTED, r_missing);
	}
	return ok_status();
}

CompatibilityManifest compatibility_manifest(std::uint64_t p_catalog_fingerprint) {
	CompatibilityManifest manifest;
	manifest.features = supported_features();
	manifest.catalog_fingerprint = p_catalog_fingerprint;
	return manifest;
}

Status check_compatibility(
		const CompatibilityManifest &p_local,
		const CompatibilityManifest &p_remote,
		std::uint64_t &r_missing_features) {
	r_missing_features = 0;
	// Before 1.0, a minor API bump may be breaking, so require an exact
	// major/minor match. Patch releases remain wire-compatible.
	if (p_local.api_major != p_remote.api_major || p_local.api_minor != p_remote.api_minor) {
		return make_status(StatusCode::API_MISMATCH, DiagnosticId::API_VERSION_DIFFERS);
	}
	if (p_local.protocol != p_remote.protocol) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS);
	}
	if (p_local.resource_schema != p_remote.resource_schema) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED);
	}
	if (p_local.world_quantization_version != p_remote.world_quantization_version ||
			p_local.world_tie_rule_version != p_remote.world_tie_rule_version) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED);
	}
	Status feature_status = negotiate_features(p_local.features, p_remote.features, r_missing_features);
	if (!feature_status.ok()) return feature_status;
	if (p_local.catalog_fingerprint != p_remote.catalog_fingerprint) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS);
	}
	return ok_status();
}

} // namespace wpn
