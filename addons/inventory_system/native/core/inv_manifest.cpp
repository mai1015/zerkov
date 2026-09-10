#include "core/inv_manifest.h"

#include "core/inv_bytes.h"
#include "core/inv_hash.h"
#include "core/inv_identifier.h"
#include "core/inv_limits.h"
#include "core/inv_version.h"

namespace inv {

Status ManifestBuilder::add(
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const std::vector<std::uint8_t> &p_canonical_fields) {
	if (p_kind < ManifestEntryKind::LIMITS ||
			p_kind > ManifestEntryKind::DISCOVERY_POLICY) {
		return make_status(
				StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_ENUM,
				static_cast<std::uint8_t>(p_kind));
	}
	Status status = validate_identifier(p_identifier);
	if (!status.ok()) {
		return status;
	}
	if (entries.size() >= MAX_MANIFEST_ENTRIES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, entries.size() + 1);
	}
	if (p_canonical_fields.size() > MAX_MANIFEST_ENTRY_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_canonical_fields.size());
	}

	const Key key{ p_kind, p_identifier };
	if (entries.find(key) != entries.end()) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, static_cast<std::uint64_t>(p_kind));
	}
	entries.emplace(key, p_canonical_fields);
	return ok_status();
}

Status ManifestBuilder::canonical_bytes(std::vector<std::uint8_t> &r_bytes) const {
	ByteWriter writer(MAX_MANIFEST_BYTES);
	writer.write_u16(PROTOCOL_VERSION);
	writer.write_u16(RESOURCE_SCHEMA_VERSION);
	writer.write_u16(FEATURE_MODULE_VERSION);
	writer.write_u16(PERSISTENCE_SCHEMA_VERSION);
	writer.write_u64(supported_features());
	writer.write_string(MANIFEST_ALGORITHM);
	writer.write_string(MASS_UNIT);
	writer.write_count(entries.size(), MAX_MANIFEST_ENTRIES);

	for (const auto &entry : entries) {
		writer.write_u8(static_cast<std::uint8_t>(entry.first.first));
		writer.write_string(entry.first.second, MAX_IDENTIFIER_BYTES);
		writer.write_blob(entry.second, MAX_MANIFEST_ENTRY_BYTES);
	}

	if (!writer.ok()) {
		return writer.status();
	}
	r_bytes = writer.take();
	return ok_status();
}

Status ManifestBuilder::build(ContentManifest &r_manifest) const {
	std::vector<std::uint8_t> bytes;
	Status status = canonical_bytes(bytes);
	if (!status.ok()) {
		return status;
	}

	r_manifest.fingerprint = hash_bytes(bytes);
	r_manifest.entry_count = static_cast<std::uint32_t>(entries.size());
	r_manifest.protocol = PROTOCOL_VERSION;
	r_manifest.resource_schema = RESOURCE_SCHEMA_VERSION;
	r_manifest.feature_module_schema = FEATURE_MODULE_VERSION;
	r_manifest.persistence_schema = PERSISTENCE_SCHEMA_VERSION;
	r_manifest.features = supported_features();
	return ok_status();
}

Status ContentManifest::compare(const ContentManifest &p_other) const {
	if (protocol != p_other.protocol) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_other.protocol);
	}
	if (resource_schema != p_other.resource_schema ||
			feature_module_schema != p_other.feature_module_schema ||
			persistence_schema != p_other.persistence_schema) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED);
	}
	std::uint64_t missing = 0;
	Status feature_status = negotiate_features(features, p_other.features, missing);
	if (!feature_status.ok()) {
		return feature_status;
	}
	if (fingerprint != p_other.fingerprint || entry_count != p_other.entry_count) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_other.fingerprint);
	}
	return ok_status();
}

} // namespace inv
