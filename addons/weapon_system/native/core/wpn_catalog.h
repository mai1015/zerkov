#ifndef WEAPON_SYSTEM_CORE_CATALOG_H
#define WEAPON_SYSTEM_CORE_CATALOG_H

#include "core/wpn_definitions.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace wpn {

struct ContentManifest {
	std::uint64_t fingerprint = 0;
	std::uint32_t weapon_count = 0;
	std::uint32_t shot_profile_count = 0;
	std::uint32_t recoil_profile_count = 0;
	std::uint32_t attachment_count = 0;
	std::uint32_t ammo_profile_count = 0;
	std::uint16_t protocol = 0;
	std::uint16_t resource_schema = 0;
	std::uint64_t features = 0;

	Status compare(const ContentManifest &p_other) const;
};

class WeaponCatalog {
public:
	Status add_shot_profile(const HitscanShotProfile &p_definition);
	Status add_recoil_profile(const RecoilProfile &p_definition);
	Status add_attachment(const AttachmentDefinition &p_definition);
	Status add_ammo_profile(const AmmunitionBallisticProfile &p_definition);
	Status add_weapon(const WeaponDefinition &p_definition);
	Status seal();

	bool sealed() const { return is_sealed; }
	const HitscanShotProfile *find_shot_profile(const std::string &p_id, std::uint16_t p_version) const;
	const RecoilProfile *find_recoil_profile(const std::string &p_id, std::uint16_t p_version) const;
	const AttachmentDefinition *find_attachment(const std::string &p_id, std::uint16_t p_version) const;
	const AmmunitionBallisticProfile *find_ammo_profile(const std::string &p_id, std::uint16_t p_version) const;
	const WeaponDefinition *find_weapon(const std::string &p_id, std::uint16_t p_version) const;
	std::size_t shot_profile_count() const { return shot_profiles.size(); }
	std::size_t recoil_profile_count() const { return recoil_profiles.size(); }
	std::size_t attachment_count() const { return attachments.size(); }
	std::size_t ammo_profile_count() const { return ammo_profiles.size(); }
	std::size_t weapon_count() const { return weapons.size(); }
	std::uint64_t fingerprint() const { return catalog_fingerprint; }
	ContentManifest manifest() const;

private:
	using Key = std::pair<std::string, std::uint16_t>;
	std::map<Key, HitscanShotProfile> shot_profiles;
	std::map<Key, RecoilProfile> recoil_profiles;
	std::map<Key, AttachmentDefinition> attachments;
	std::map<Key, AmmunitionBallisticProfile> ammo_profiles;
	std::map<Key, WeaponDefinition> weapons;
	bool is_sealed = false;
	std::uint64_t catalog_fingerprint = 0;
};

// One diagnostic finding from a bounded batch validation pass
// (weapon-authoring: "Bounded Catalog Diagnostics"): the kind/ID/version of
// the offending definition plus its rejection status.
struct CatalogDiagnosticFinding {
	std::string definition_kind;
	std::string id;
	std::uint16_t version = 0;
	Status status;
};

// Bounded report from `validate_catalog_batch`: a deterministic, stable-order
// prefix of findings, capped at MAX_DIAGNOSTIC_FINDINGS, plus whether more
// findings existed beyond that cap.
struct CatalogDiagnosticReport {
	std::vector<CatalogDiagnosticFinding> findings;
	bool truncated = false;
	std::uint32_t total_finding_count = 0;
};

// One proposed batch of not-yet-added definitions, e.g. everything an editor
// or Resource loader collected from one content load before calling the
// fail-fast `add_*`/`seal()` methods above. Validates the batch as a whole
// (individual field validation, in-batch duplicate IDs, and weapon
// cross-references against both the batch and `p_existing`) without
// mutating any catalog, so many problems can be reported at once instead of
// stopping at the first one.
struct CatalogDefinitionBatch {
	std::vector<HitscanShotProfile> shot_profiles;
	std::vector<RecoilProfile> recoil_profiles;
	std::vector<AttachmentDefinition> attachments;
	std::vector<AmmunitionBallisticProfile> ammo_profiles;
	std::vector<WeaponDefinition> weapons;
};

CatalogDiagnosticReport validate_catalog_batch(
		const CatalogDefinitionBatch &p_batch,
		const WeaponCatalog *p_existing = nullptr);

} // namespace wpn

#endif // WEAPON_SYSTEM_CORE_CATALOG_H
