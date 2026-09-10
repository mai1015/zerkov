#include "protocol/inv_protocol_compat.h"

#include "core/inv_hash.h"
#include "core/inv_limits.h"
#include "core/inv_version.h"

namespace inv::protocol {

Status check_session_compatibility(const SessionHello &p_local, const SessionHello &p_remote) {
	// 1. protocol version.
	if (p_local.protocol_version != p_remote.protocol_version) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_remote.protocol_version);
	}

	// 2. canonical numeric unit identifier.
	if (p_local.mass_unit != p_remote.mass_unit) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::SESSION_MASS_UNIT_MISMATCH, hash_string(p_remote.mass_unit));
	}

	// 3. required protocol feature bits, bidirectional: each side's declared
	// required set doubles as its declared supported set (V1 has no notion of
	// a feature a build supports but does not require -- see
	// inv_protocol_types.h's SessionHello::required_feature_bits doc
	// comment), so both directions must hold.
	std::uint64_t missing_in_remote = 0;
	Status status = negotiate_features(p_remote.required_feature_bits, p_local.required_feature_bits, missing_in_remote);
	if (!status.ok()) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_SET_UNSUPPORTED, missing_in_remote);
	}
	std::uint64_t missing_in_local = 0;
	status = negotiate_features(p_local.required_feature_bits, p_remote.required_feature_bits, missing_in_local);
	if (!status.ok()) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_SET_UNSUPPORTED, missing_in_local);
	}

	// 4. hard-limit contract.
	if (p_local.hard_limit_digest != p_remote.hard_limit_digest) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SESSION_LIMIT_DIGEST_MISMATCH, p_remote.hard_limit_digest);
	}

	// 5. canonical identifier dictionary.
	if (p_local.identifier_dictionary_digest != p_remote.identifier_dictionary_digest) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::SESSION_IDENTIFIER_DIGEST_MISMATCH, p_remote.identifier_dictionary_digest);
	}

	// 6. authority-affecting content-manifest algorithm and fingerprint.
	if (p_local.manifest_algorithm != p_remote.manifest_algorithm) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::SESSION_MANIFEST_ALGORITHM_MISMATCH, hash_string(p_remote.manifest_algorithm));
	}
	if (p_local.manifest_fingerprint != p_remote.manifest_fingerprint) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_remote.manifest_fingerprint);
	}

	return ok_status();
}

SessionHello make_session_hello(const DefinitionCatalog &p_sealed) {
	SessionHello hello;
	hello.protocol_version = PROTOCOL_VERSION;
	hello.mass_unit = MASS_UNIT;
	hello.manifest_algorithm = MANIFEST_ALGORITHM;
	const ContentManifest *manifest = p_sealed.manifest();
	hello.manifest_fingerprint = manifest != nullptr ? manifest->fingerprint : 0;
	hello.required_feature_bits = supported_features();

	ByteWriter limits_writer(MAX_MANIFEST_ENTRY_BYTES);
	encode_hard_limits(limits_writer);
	hello.hard_limit_digest = limits_writer.status().ok() ? hash_bytes(limits_writer.bytes()) : 0;

	hello.identifier_dictionary_digest = p_sealed.identifier_dictionary_fingerprint();
	return hello;
}

} // namespace inv::protocol
