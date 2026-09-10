#include "core/wpn_catalog.h"

#include "core/wpn_hash.h"
#include "core/wpn_limits.h"
#include "core/wpn_numerics.h"
#include "core/wpn_version.h"

#include <algorithm>

namespace wpn {

Status WeaponCatalog::add_shot_profile(const HitscanShotProfile &p_definition) {
	if (is_sealed) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	Status status = p_definition.validate();
	if (!status.ok()) return status;
	if (shot_profiles.size() >= MAX_CATALOG_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, shot_profiles.size() + 1);
	}
	if (!shot_profiles.emplace(Key{ p_definition.id, p_definition.version }, p_definition).second) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
	}
	return ok_status();
}

Status WeaponCatalog::add_recoil_profile(const RecoilProfile &p_definition) {
	if (is_sealed) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	Status status = p_definition.validate();
	if (!status.ok()) return status;
	if (recoil_profiles.size() >= MAX_CATALOG_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, recoil_profiles.size() + 1);
	}
	if (!recoil_profiles.emplace(Key{ p_definition.id, p_definition.version }, p_definition).second) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
	}
	return ok_status();
}

Status WeaponCatalog::add_attachment(const AttachmentDefinition &p_definition) {
	if (is_sealed) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	Status status = p_definition.validate();
	if (!status.ok()) return status;
	if (attachments.size() >= MAX_CATALOG_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, attachments.size() + 1);
	}
	if (!attachments.emplace(Key{ p_definition.id, p_definition.version }, p_definition).second) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
	}
	return ok_status();
}

Status WeaponCatalog::add_ammo_profile(const AmmunitionBallisticProfile &p_definition) {
	if (is_sealed) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	Status status = p_definition.validate();
	if (!status.ok()) return status;
	if (ammo_profiles.size() >= MAX_CATALOG_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, ammo_profiles.size() + 1);
	}
	if (!ammo_profiles.emplace(Key{ p_definition.id, p_definition.version }, p_definition).second) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
	}
	return ok_status();
}

Status WeaponCatalog::add_weapon(const WeaponDefinition &p_definition) {
	if (is_sealed) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	Status status = p_definition.validate();
	if (!status.ok()) return status;
	if (weapons.size() >= MAX_CATALOG_DEFINITIONS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, weapons.size() + 1);
	}
	if (!weapons.emplace(Key{ p_definition.id, p_definition.version }, p_definition).second) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
	}
	return ok_status();
}

Status WeaponCatalog::seal() {
	if (is_sealed) return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	for (const auto &entry : weapons) {
		const WeaponDefinition &weapon = entry.second;
		if (shot_profiles.find(Key{ weapon.shot_profile_id, weapon.shot_profile_version }) == shot_profiles.end()) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		}
		if (recoil_profiles.find(Key{ weapon.recoil_profile_id, weapon.recoil_profile_version }) == recoil_profiles.end()) {
			return make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		}
	}
	Hasher h;
	h.write_u16(PROTOCOL_VERSION);
	h.write_u16(RESOURCE_SCHEMA_VERSION);
	h.write_u64(supported_features());
	h.write_u64(MAX_WEAPON_INSTANCES);
	h.write_u64(MAX_IDEMPOTENCY_RECORDS);
	h.write_u64(MAX_TARGET_CANDIDATES);
	// Sealed numeric contract: algorithm versions and bounds all contribute
	// to the fingerprint so peers with different conversion/sampler/algebra
	// rules cannot become compatibility-ready (weapon-authoring: "Canonical
	// Content Fingerprints").
	h.write_u16(MOA_CONVERSION_VERSION);
	h.write_u16(AIM_ROTATION_ALGORITHM_VERSION);
	h.write_u16(DISPERSION_SEED_SAMPLER_VERSION);
	h.write_u16(MODIFIER_ALGEBRA_VERSION);
	h.write_i64(PI_NANORADIANS);
	h.write_i64(MOA_MILLI_TO_NANORADIAN_DENOMINATOR);
	h.write_i64(MAX_ACCURACY_MOA_MILLI);
	h.write_i64(MAX_RECOIL_KICK_NRAD);
	h.write_i64(MAX_RECOIL_OFFSET_NRAD);
	h.write_i64(MODIFIER_NEUTRAL_PPM);
	h.write_i64(MAX_MODIFIER_DELTA_PPM);
	h.write_i64(MIN_MODIFIER_MULTIPLIER_PPM);
	h.write_i64(MAX_MODIFIER_MULTIPLIER_PPM);
	h.write_u64(MAX_ATTACHMENT_SLOTS_PER_WEAPON);

	h.write_u32(static_cast<std::uint32_t>(shot_profiles.size()));
	for (const auto &entry : shot_profiles) {
		h.write_string(entry.first.first);
		h.write_u16(entry.first.second);
		h.write_u64(entry.second.fingerprint());
	}
	h.write_u32(static_cast<std::uint32_t>(recoil_profiles.size()));
	for (const auto &entry : recoil_profiles) {
		h.write_string(entry.first.first);
		h.write_u16(entry.first.second);
		h.write_u64(entry.second.fingerprint());
	}
	h.write_u32(static_cast<std::uint32_t>(attachments.size()));
	for (const auto &entry : attachments) {
		h.write_string(entry.first.first);
		h.write_u16(entry.first.second);
		h.write_u64(entry.second.fingerprint());
	}
	h.write_u32(static_cast<std::uint32_t>(ammo_profiles.size()));
	for (const auto &entry : ammo_profiles) {
		h.write_string(entry.first.first);
		h.write_u16(entry.first.second);
		h.write_u64(entry.second.fingerprint());
	}
	h.write_u32(static_cast<std::uint32_t>(weapons.size()));
	for (const auto &entry : weapons) {
		h.write_string(entry.first.first);
		h.write_u16(entry.first.second);
		h.write_u64(entry.second.fingerprint());
	}
	catalog_fingerprint = h.digest();
	is_sealed = true;
	return ok_status();
}

const HitscanShotProfile *WeaponCatalog::find_shot_profile(const std::string &p_id, std::uint16_t p_version) const {
	if (!is_sealed) return nullptr;
	const auto found = shot_profiles.find(Key{ p_id, p_version });
	return found == shot_profiles.end() ? nullptr : &found->second;
}

const RecoilProfile *WeaponCatalog::find_recoil_profile(const std::string &p_id, std::uint16_t p_version) const {
	if (!is_sealed) return nullptr;
	const auto found = recoil_profiles.find(Key{ p_id, p_version });
	return found == recoil_profiles.end() ? nullptr : &found->second;
}

const AttachmentDefinition *WeaponCatalog::find_attachment(const std::string &p_id, std::uint16_t p_version) const {
	if (!is_sealed) return nullptr;
	const auto found = attachments.find(Key{ p_id, p_version });
	return found == attachments.end() ? nullptr : &found->second;
}

const AmmunitionBallisticProfile *WeaponCatalog::find_ammo_profile(const std::string &p_id, std::uint16_t p_version) const {
	if (!is_sealed) return nullptr;
	const auto found = ammo_profiles.find(Key{ p_id, p_version });
	return found == ammo_profiles.end() ? nullptr : &found->second;
}

const WeaponDefinition *WeaponCatalog::find_weapon(const std::string &p_id, std::uint16_t p_version) const {
	if (!is_sealed) return nullptr;
	const auto found = weapons.find(Key{ p_id, p_version });
	return found == weapons.end() ? nullptr : &found->second;
}

ContentManifest WeaponCatalog::manifest() const {
	ContentManifest result;
	if (!is_sealed) return result;
	result.fingerprint = catalog_fingerprint;
	result.weapon_count = static_cast<std::uint32_t>(weapons.size());
	result.shot_profile_count = static_cast<std::uint32_t>(shot_profiles.size());
	result.recoil_profile_count = static_cast<std::uint32_t>(recoil_profiles.size());
	result.attachment_count = static_cast<std::uint32_t>(attachments.size());
	result.ammo_profile_count = static_cast<std::uint32_t>(ammo_profiles.size());
	result.protocol = PROTOCOL_VERSION;
	result.resource_schema = RESOURCE_SCHEMA_VERSION;
	result.features = supported_features();
	return result;
}

Status ContentManifest::compare(const ContentManifest &p_other) const {
	if (protocol != p_other.protocol) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_other.protocol);
	}
	if (resource_schema != p_other.resource_schema) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED, p_other.resource_schema);
	}
	std::uint64_t missing = 0;
	Status feature_status = negotiate_features(features, p_other.features, missing);
	if (!feature_status.ok()) return feature_status;
	if (fingerprint != p_other.fingerprint || weapon_count != p_other.weapon_count ||
			shot_profile_count != p_other.shot_profile_count ||
			recoil_profile_count != p_other.recoil_profile_count ||
			attachment_count != p_other.attachment_count ||
			ammo_profile_count != p_other.ammo_profile_count) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_other.fingerprint);
	}
	return ok_status();
}

namespace {

template <typename T>
void collect_batch_findings(
		const char *p_kind,
		const std::vector<T> &p_items,
		std::vector<CatalogDiagnosticFinding> &r_findings,
		std::uint32_t &r_total) {
	// Stable definition order: sort a copy of the indices by (id, version) so
	// findings are deterministic regardless of the caller's batch order.
	std::vector<std::size_t> order(p_items.size());
	for (std::size_t i = 0; i < order.size(); ++i) order[i] = i;
	std::sort(order.begin(), order.end(), [&](std::size_t p_a, std::size_t p_b) {
		if (p_items[p_a].id != p_items[p_b].id) return p_items[p_a].id < p_items[p_b].id;
		return p_items[p_a].version < p_items[p_b].version;
	});
	std::map<std::pair<std::string, std::uint16_t>, bool> seen;
	for (std::size_t index : order) {
		const T &item = p_items[index];
		Status status = item.validate();
		if (status.ok()) {
			const auto key = std::pair<std::string, std::uint16_t>{ item.id, item.version };
			if (!seen.emplace(key, true).second) {
				status = make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::DEFINITION_DUPLICATE);
			} else {
				continue;
			}
		}
		++r_total;
		if (r_findings.size() < MAX_DIAGNOSTIC_FINDINGS) {
			r_findings.push_back({ p_kind, item.id, item.version, status });
		}
	}
}

} // namespace

CatalogDiagnosticReport validate_catalog_batch(const CatalogDefinitionBatch &p_batch, const WeaponCatalog *p_existing) {
	CatalogDiagnosticReport report;
	collect_batch_findings("shot_profile", p_batch.shot_profiles, report.findings, report.total_finding_count);
	collect_batch_findings("recoil_profile", p_batch.recoil_profiles, report.findings, report.total_finding_count);
	collect_batch_findings("attachment", p_batch.attachments, report.findings, report.total_finding_count);
	collect_batch_findings("ammo_profile", p_batch.ammo_profiles, report.findings, report.total_finding_count);
	collect_batch_findings("weapon", p_batch.weapons, report.findings, report.total_finding_count);

	// Weapon cross-reference diagnostics (unknown shot profile / recoil
	// profile), checked against both the batch itself and any already-sealed
	// catalog supplied for context.
	std::vector<std::size_t> weapon_order(p_batch.weapons.size());
	for (std::size_t i = 0; i < weapon_order.size(); ++i) weapon_order[i] = i;
	std::sort(weapon_order.begin(), weapon_order.end(), [&](std::size_t p_a, std::size_t p_b) {
		const WeaponDefinition &a = p_batch.weapons[p_a];
		const WeaponDefinition &b = p_batch.weapons[p_b];
		if (a.id != b.id) return a.id < b.id;
		return a.version < b.version;
	});
	auto shot_profile_known = [&](const std::string &p_id, std::uint16_t p_version) {
		for (const HitscanShotProfile &profile : p_batch.shot_profiles) {
			if (profile.id == p_id && profile.version == p_version) return true;
		}
		return p_existing != nullptr && p_existing->find_shot_profile(p_id, p_version) != nullptr;
	};
	auto recoil_profile_known = [&](const std::string &p_id, std::uint16_t p_version) {
		for (const RecoilProfile &profile : p_batch.recoil_profiles) {
			if (profile.id == p_id && profile.version == p_version) return true;
		}
		return p_existing != nullptr && p_existing->find_recoil_profile(p_id, p_version) != nullptr;
	};
	for (std::size_t index : weapon_order) {
		const WeaponDefinition &weapon = p_batch.weapons[index];
		if (!weapon.validate().ok()) continue; // already reported above
		Status reference_status = ok_status();
		if (!shot_profile_known(weapon.shot_profile_id, weapon.shot_profile_version) ||
				!recoil_profile_known(weapon.recoil_profile_id, weapon.recoil_profile_version)) {
			reference_status = make_status(StatusCode::INVALID_REFERENCE, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE);
		}
		if (!reference_status.ok()) {
			++report.total_finding_count;
			if (report.findings.size() < MAX_DIAGNOSTIC_FINDINGS) {
				report.findings.push_back({ "weapon", weapon.id, weapon.version, reference_status });
			}
		}
	}

	report.truncated = report.total_finding_count > report.findings.size();
	return report;
}

} // namespace wpn
