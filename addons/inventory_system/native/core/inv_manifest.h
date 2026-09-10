#ifndef INVENTORY_SYSTEM_CORE_MANIFEST_H
#define INVENTORY_SYSTEM_CORE_MANIFEST_H

#include "core/inv_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace inv {

// Values are append-only because kind order is part of canonical bytes.
enum class ManifestEntryKind : std::uint8_t {
	LIMITS = 0,
	FEATURE_MODULE = 1,
	TRAIT_SCHEMA = 2,
	CONTAINER = 3,
	ITEM = 4,
	PROFILE = 5,
	INTEGRATION_MAPPING = 6,
	DISCOVERY_POLICY = 7,
};

struct ContentManifest {
	std::uint64_t fingerprint = 0;
	std::uint32_t entry_count = 0;
	std::uint16_t protocol = 0;
	std::uint16_t resource_schema = 0;
	std::uint16_t feature_module_schema = 0;
	std::uint16_t persistence_schema = 0;
	std::uint64_t features = 0;

	Status compare(const ContentManifest &p_other) const;
};

class ManifestBuilder {
public:
	Status add(
			ManifestEntryKind p_kind,
			const std::string &p_identifier,
			const std::vector<std::uint8_t> &p_canonical_fields);

	Status canonical_bytes(std::vector<std::uint8_t> &r_bytes) const;
	Status build(ContentManifest &r_manifest) const;

	std::size_t size() const { return entries.size(); }

private:
	using Key = std::pair<ManifestEntryKind, std::string>;
	std::map<Key, std::vector<std::uint8_t>> entries;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_MANIFEST_H
