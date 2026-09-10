#ifndef INVENTORY_SYSTEM_CORE_CATALOG_H
#define INVENTORY_SYSTEM_CORE_CATALOG_H

#include "core/inv_definitions.h"
#include "core/inv_identifier.h"
#include "core/inv_manifest.h"

#include <map>
#include <string>
#include <vector>

namespace inv {

// Canonical encoding of every compiled-in hard limit (inv_limits.h), in fixed
// declaration order -- a pure function of compile-time constants, identical
// for every catalog instance and every process. Backs the sealed catalog's
// own LIMITS manifest entry (see inv_catalog.cpp's build_manifest()) and the
// protocol layer's session hard-limit-contract digest
// (SessionHello::hard_limit_digest = fnv1a64 over this exact byte sequence;
// see protocol/inv_protocol_compat.cpp's make_session_hello()). Exported so
// both call sites share one implementation instead of drifting.
void encode_hard_limits(ByteWriter &p_writer);

// Adapter-owned authority-affecting mapping (e.g. equipped-trait-to-GAS-grant
// tables). The core does not interpret the bytes; the registering adapter is
// responsible for producing an already-canonical payload. Registration only
// validates the identifier and the byte bound so the mapping can safely
// participate in the sealed manifest and fingerprint.
struct IntegrationMappingRecord {
	std::string identifier;
	std::vector<std::uint8_t> canonical_bytes;
};

class DefinitionCatalog {
public:
	explicit DefinitionCatalog(IdentifierHashFunction p_hash_function = stable_identifier_hash);

	Status register_builtin_definitions();
	// Explicit opt-in companion to register_builtin_definitions(). Keeping
	// discovery out of the default set preserves existing catalog bytes.
	Status register_discovery_definitions();

	Status register_feature(
			FeatureModuleDefinition p_definition,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);
	Status register_trait_schema(
			TraitSchemaDefinition p_definition,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);
	Status register_discovery_policy(
			DiscoveryPolicyDefinition p_definition,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);
	Status register_container(
			ContainerDefinition p_definition,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);
	Status register_item(
			ItemDefinition p_definition,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);
	Status register_profile(
			InventoryProfileDefinition p_definition,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);
	// Registers an opaque, adapter-owned canonical mapping payload (e.g. from
	// inventory_gameplay_abilities). p_canonical_bytes is trusted to already be
	// in canonical form; the catalog validates only the identifier and bound.
	Status register_integration_mapping(
			const std::string &p_identifier,
			std::vector<std::uint8_t> p_canonical_bytes,
			const std::string &p_source_label,
			IdentifierConflict *r_conflict = nullptr);

	// On failure, if r_offending_identifier is non-null, it is set to the
	// identifier most relevant to the failure (e.g. the unknown reference or
	// the item at fault). It is cleared to empty on entry and left empty on
	// success.
	Status seal(std::string *r_offending_identifier = nullptr);
	bool sealed() const { return is_sealed; }

	const FeatureModuleDefinition *find_feature(const std::string &p_identifier) const;
	const TraitSchemaDefinition *find_trait_schema(const std::string &p_identifier) const;
	const DiscoveryPolicyDefinition *find_discovery_policy(const std::string &p_identifier) const;
	const ContainerDefinition *find_container(const std::string &p_identifier) const;
	const ItemDefinition *find_item(const std::string &p_identifier) const;
	const InventoryProfileDefinition *find_profile(const std::string &p_identifier) const;
	const IntegrationMappingRecord *find_integration_mapping(const std::string &p_identifier) const;

	DefinitionId feature_id(const std::string &p_identifier) const;
	DefinitionId trait_schema_id(const std::string &p_identifier) const;
	DefinitionId discovery_policy_id(const std::string &p_identifier) const;
	DefinitionId container_id(const std::string &p_identifier) const;
	DefinitionId item_id(const std::string &p_identifier) const;
	DefinitionId profile_id(const std::string &p_identifier) const;
	DefinitionId integration_mapping_id(const std::string &p_identifier) const;

	const ContentManifest *manifest() const;
	const std::vector<std::uint8_t> &manifest_bytes() const { return sealed_manifest_bytes; }

	// fnv1a64 combination of the six per-kind IdentifierTable::fingerprint()
	// values (feature, trait_schema, container, item, profile,
	// integration_mapping -- always this fixed order), each in turn fnv1a64
	// over that table's (identifier string, assigned dense DefinitionId)
	// pairs in ascending-identifier order (IdentifierTable::fingerprint()'s
	// own std::map iteration order, which is bytewise identifier order).
	// Backs SessionHello::identifier_dictionary_digest (task 6.3,
	// protocol/inv_protocol_compat.cpp's make_session_hello()): two catalogs
	// whose registered identifier SETS or assigned dense ids differ produce a
	// different digest even if a later feature makes the manifest fingerprint
	// itself insensitive to registration order. 0 before seal() (mirrors
	// IdentifierTable::fingerprint()'s own "unsealed reports 0").
	std::uint64_t identifier_dictionary_fingerprint() const;

	// Returns the complete deterministic canonical byte stream of the sealed
	// catalog (header, limits, and every definition in kind then identifier
	// order). This is currently the same byte sequence backing the manifest;
	// it is exposed as an explicit, fail-closed accessor so protocol and
	// persistence code have one stable, validated entry point rather than
	// reaching into manifest_bytes() (which silently returns empty when
	// unsealed). Fails with CATALOG_NOT_SEALED before the catalog is sealed.
	Status encode_canonical(std::vector<std::uint8_t> &r_bytes) const;

	std::size_t feature_count() const { return features.size(); }
	std::size_t trait_schema_count() const { return trait_schemas.size(); }
	std::size_t discovery_policy_count() const { return discovery_policies.size(); }
	std::size_t container_count() const { return containers.size(); }
	std::size_t item_count() const { return items.size(); }
	std::size_t profile_count() const { return profiles.size(); }
	std::size_t integration_mapping_count() const { return integration_mappings.size(); }

private:
	Status validate_cross_references(std::string *r_offending = nullptr) const;
	Status validate_feature_graph(std::string *r_offending = nullptr) const;
	Status validate_enabled_features(const std::vector<std::string> &p_features, std::string *r_offending = nullptr) const;
	// Validates that item-provided subcontainers reference registered
	// containers within bounds and that the item/container definition
	// reference graph implied by provided_containers is acyclic and within
	// MAX_NESTING_DEPTH. See inv_catalog.cpp for the conservative reachability
	// rule used (nesting-enabled containers with an explicit required-trait
	// filter conservatively reach any non-owning item satisfying that filter).
	Status validate_provided_container_graph(std::string *r_offending = nullptr) const;
	Status build_manifest(ContentManifest &r_manifest, std::vector<std::uint8_t> &r_bytes) const;

	IdentifierTable feature_ids;
	IdentifierTable trait_schema_ids;
	IdentifierTable discovery_policy_ids;
	IdentifierTable container_ids;
	IdentifierTable item_ids;
	IdentifierTable profile_ids;
	IdentifierTable integration_mapping_ids;

	std::map<std::string, FeatureModuleDefinition> features;
	std::map<std::string, TraitSchemaDefinition> trait_schemas;
	std::map<std::string, DiscoveryPolicyDefinition> discovery_policies;
	std::map<std::string, ContainerDefinition> containers;
	std::map<std::string, ItemDefinition> items;
	std::map<std::string, InventoryProfileDefinition> profiles;
	std::map<std::string, IntegrationMappingRecord> integration_mappings;

	ContentManifest sealed_manifest;
	std::vector<std::uint8_t> sealed_manifest_bytes;
	bool is_sealed = false;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_CATALOG_H
