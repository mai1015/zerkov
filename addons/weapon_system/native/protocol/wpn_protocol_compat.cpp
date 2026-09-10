#include "protocol/wpn_protocol_compat.h"

#include "core/wpn_version.h"

namespace wpn::protocol {

CompatibilityHandshake make_compatibility_handshake(const WeaponCatalog &p_sealed) {
	CompatibilityHandshake handshake;
	handshake.protocol_version = PROTOCOL_VERSION;
	handshake.manifest = compatibility_manifest(p_sealed.fingerprint());
	return handshake;
}

Status check_handshake_compatibility(
		const CompatibilityHandshake &p_local,
		const CompatibilityHandshake &p_remote,
		std::uint64_t &r_missing_features) {
	r_missing_features = 0;
	if (p_local.protocol_version != p_remote.protocol_version) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_remote.protocol_version);
	}
	return check_compatibility(p_local.manifest, p_remote.manifest, r_missing_features);
}

} // namespace wpn::protocol
