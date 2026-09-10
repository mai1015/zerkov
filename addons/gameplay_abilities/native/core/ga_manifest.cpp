#include "core/ga_manifest.h"

#include "core/ga_identifier.h"

#include <limits>

namespace ga {

Status ManifestBuilder::add(ManifestEntryKind p_kind, const std::string &p_identifier, const std::vector<std::uint8_t> &p_canonical_fields) {
	const Status validity = validate_identifier(p_identifier);
	if (!validity.ok()) {
		return validity;
	}

	const Key key{ p_kind, p_identifier };
	if (entries.find(key) != entries.end()) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE, static_cast<std::uint64_t>(p_kind));
	}

	entries.emplace(key, p_canonical_fields);
	return ok_status();
}

Status ManifestBuilder::build(ContentManifest &r_out) const {
	if (entries.size() > std::numeric_limits<std::uint32_t>::max()) {
		return make_status(StatusCode::CAPACITY_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, entries.size());
	}

	Hasher hasher;
	// `entries` is a std::map keyed by (kind, identifier), so this iteration
	// already visits entries in canonical (kind, identifier) order.
	for (const auto &entry : entries) {
		hasher.write_byte(static_cast<std::uint8_t>(entry.first.first));
		hasher.write_string(entry.first.second);
		hasher.write_u32(static_cast<std::uint32_t>(entry.second.size()));
		hasher.write_bytes(entry.second);
	}

	hasher.write_u16(GA_PROTOCOL_VERSION);
	hasher.write_i64(FIXED_SCALE);
	hasher.write_u32(tick_rate);

	r_out.fingerprint = hasher.digest();
	r_out.entry_count = static_cast<std::uint32_t>(entries.size());
	r_out.tick_rate = tick_rate;
	return ok_status();
}

Status ContentManifest::compare(const ContentManifest &p_other) const {
	if (fingerprint != p_other.fingerprint || tick_rate != p_other.tick_rate || entry_count != p_other.entry_count) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_other.fingerprint);
	}
	return ok_status();
}

} // namespace ga
