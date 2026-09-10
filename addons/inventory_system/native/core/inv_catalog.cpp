#include "core/inv_catalog.h"

#include "core/inv_builtin_features.h"
#include "core/inv_hash.h"
#include "core/inv_limits.h"

#include <algorithm>
#include <functional>
#include <set>

namespace inv {

namespace {

template <typename T>
const T *find_definition(const std::map<std::string, T> &p_definitions, const std::string &p_identifier) {
	const auto found = p_definitions.find(p_identifier);
	return found == p_definitions.end() ? nullptr : &found->second;
}

bool contains_identifier(const std::vector<std::string> &p_values, const std::string &p_identifier) {
	return std::binary_search(p_values.begin(), p_values.end(), p_identifier, identifier_less);
}

Status add_encoded(
		ManifestBuilder &r_builder,
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const TraitSchemaDefinition &p_definition) {
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	Status status = encode_canonical(p_definition, writer);
	if (!status.ok()) {
		return status;
	}
	return r_builder.add(p_kind, p_identifier, writer.bytes());
}

Status add_encoded(
		ManifestBuilder &r_builder,
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const DiscoveryPolicyDefinition &p_definition) {
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	Status status = encode_canonical(p_definition, writer);
	if (!status.ok()) {
		return status;
	}
	return r_builder.add(p_kind, p_identifier, writer.bytes());
}

Status add_encoded(
		ManifestBuilder &r_builder,
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const ContainerDefinition &p_definition) {
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	Status status = encode_canonical(p_definition, writer);
	if (!status.ok()) {
		return status;
	}
	return r_builder.add(p_kind, p_identifier, writer.bytes());
}

Status add_encoded(
		ManifestBuilder &r_builder,
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const ItemDefinition &p_definition) {
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	Status status = encode_canonical(p_definition, writer);
	if (!status.ok()) {
		return status;
	}
	return r_builder.add(p_kind, p_identifier, writer.bytes());
}

Status add_encoded(
		ManifestBuilder &r_builder,
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const FeatureModuleDefinition &p_definition) {
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	Status status = encode_canonical(p_definition, writer);
	if (!status.ok()) {
		return status;
	}
	return r_builder.add(p_kind, p_identifier, writer.bytes());
}

Status add_encoded(
		ManifestBuilder &r_builder,
		ManifestEntryKind p_kind,
		const std::string &p_identifier,
		const InventoryProfileDefinition &p_definition) {
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	Status status = encode_canonical(p_definition, writer);
	if (!status.ok()) {
		return status;
	}
	return r_builder.add(p_kind, p_identifier, writer.bytes());
}

Status validate_trait_references(
		const std::vector<std::string> &p_traits,
		const std::map<std::string, TraitSchemaDefinition> &p_schemas,
		std::string *r_offending = nullptr) {
	for (const std::string &trait : p_traits) {
		if (p_schemas.find(trait) == p_schemas.end()) {
			if (r_offending != nullptr) {
				*r_offending = trait;
			}
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::TRAIT_UNKNOWN, hash_string(trait));
		}
	}
	return ok_status();
}

// Conservative, statically-decidable admissibility check used only for
// definition-cycle detection (see validate_provided_container_graph). Full
// runtime admissibility also depends on footprint, occupancy, and other
// instance state that does not exist at catalog-seal time; this check only
// asks whether the item's fixed trait set matches the container's declared
// required/blocked trait identifiers.
bool item_satisfies_trait_filter(const ItemDefinition &p_item, const ContainerConstraints &p_constraints) {
	std::set<std::string> item_traits;
	for (const ItemTraitValue &trait : p_item.traits) {
		item_traits.insert(trait.trait_identifier);
	}
	for (const std::string &required : p_constraints.required_traits) {
		if (item_traits.find(required) == item_traits.end()) {
			return false;
		}
	}
	for (const std::string &blocked : p_constraints.blocked_traits) {
		if (item_traits.find(blocked) != item_traits.end()) {
			return false;
		}
	}
	return true;
}

} // namespace

// Exported (see inv_catalog.h doc comment): reused by both build_manifest()
// below and the protocol layer's SessionHello digest.
void encode_hard_limits(ByteWriter &p_writer) {
	p_writer.write_u64(MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(MAX_IDENTIFIER_SEGMENTS);
	p_writer.write_u64(MAX_SOURCE_LABEL_BYTES);
	p_writer.write_u64(MAX_STRING_BYTES);
	p_writer.write_u64(MAX_DIAGNOSTIC_BYTES);
	p_writer.write_u64(MAX_CATALOG_DEFINITIONS);
	p_writer.write_u64(MAX_MANIFEST_ENTRIES);
	p_writer.write_u64(MAX_MANIFEST_ENTRY_BYTES);
	p_writer.write_u64(MAX_FEATURE_MODULES);
	p_writer.write_u64(MAX_FEATURE_DEPENDENCIES);
	p_writer.write_u64(MAX_FEATURE_PHASES);
	p_writer.write_u64(MAX_FEATURE_OWNED_RECORDS);
	p_writer.write_u64(MAX_TRAIT_SCHEMAS);
	p_writer.write_u64(MAX_TRAITS_PER_ITEM);
	p_writer.write_u64(MAX_TRAIT_PAYLOAD_BYTES);
	p_writer.write_u64(MAX_CONTAINERS_PER_PROFILE);
	p_writer.write_u64(MAX_ROOT_CONTAINERS);
	p_writer.write_u64(MAX_ITEM_PROVIDED_CONTAINERS);
	p_writer.write_u64(MAX_SLOTS_PER_CONTAINER);
	p_writer.write_u64(MAX_FILTER_TRAITS);
	p_writer.write_u32(MAX_GRID_DIMENSION);
	p_writer.write_u32(MAX_ITEM_FOOTPRINT);
	p_writer.write_u32(MAX_LIST_ENTRIES);
	p_writer.write_u64(MAX_STACK_QUANTITY);
	p_writer.write_u32(MAX_NESTING_DEPTH);
	p_writer.write_u32(MAX_ITEMS_PER_INVENTORY);
	p_writer.write_u32(MAX_CONTAINERS_PER_INVENTORY);
	p_writer.write_u32(MAX_REFERENCES_PER_INVENTORY);
	p_writer.write_u32(MAX_MUTABLE_COMPONENTS_PER_ITEM);
	p_writer.write_u32(MAX_INVENTORIES_PER_TRANSACTION);
	p_writer.write_u32(MAX_IDEMPOTENCY_RECORDS);
	p_writer.write_u64(MAX_COMMAND_BYTES);
	p_writer.write_u64(MAX_DELTA_BYTES);
	p_writer.write_u64(MAX_SNAPSHOT_BYTES);
	p_writer.write_u64(MAX_OBSERVER_VIEW_BYTES);
	p_writer.write_u64(MAX_OBSERVER_ENVELOPE_OVERHEAD_BYTES);
	p_writer.write_u64(MAX_OBSERVER_SNAPSHOT_BYTES);
	p_writer.write_u64(MAX_OBSERVER_DELTA_BYTES);
	p_writer.write_u64(MAX_OBSERVER_RESYNC_BYTES);
	p_writer.write_u64(MAX_OBSERVER_STREAMS_PER_RECIPIENT);
	p_writer.write_u64(MAX_OBSERVER_STREAMS);
	p_writer.write_u64(MAX_OBSERVER_GENERATION_KEYS);
	p_writer.write_u64(MAX_MANIFEST_BYTES);
	p_writer.write_u64(MAX_COLLECTION_COUNT);
	p_writer.write_u64(MAX_GATEWAY_SESSIONS);
	p_writer.write_u64(MAX_GATEWAY_INVENTORY_GRANTS_PER_SESSION);
	p_writer.write_u64(MAX_GATEWAY_OBSERVER_GRANTS_PER_SESSION);
	p_writer.write_u64(MAX_GATEWAY_REPLAY_ENTRIES_PER_SESSION);
	p_writer.write_u64(MAX_GATEWAY_REPLAY_BYTES);
	p_writer.write_u64(MAX_GATEWAY_RETIRED_SESSIONS);
	p_writer.write_u64(DEFAULT_GATEWAY_COMMANDS_PER_SECOND);
	p_writer.write_u64(DEFAULT_GATEWAY_RESYNCS_PER_MINUTE);
	p_writer.write_u64(DEFAULT_GATEWAY_TICK_RATE);
}

DefinitionCatalog::DefinitionCatalog(IdentifierHashFunction p_hash_function) :
		feature_ids(p_hash_function),
		trait_schema_ids(p_hash_function),
		discovery_policy_ids(p_hash_function),
		container_ids(p_hash_function),
		item_ids(p_hash_function),
		profile_ids(p_hash_function),
		integration_mapping_ids(p_hash_function) {}

Status DefinitionCatalog::register_builtin_definitions() {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}

	DefinitionCatalog candidate = *this;
	for (FeatureModuleDefinition definition : builtin_feature_modules()) {
		Status status = candidate.register_feature(
				std::move(definition),
				"inventory_system:builtin_feature");
		if (!status.ok()) {
			return status;
		}
	}
	for (TraitSchemaDefinition definition : builtin_trait_schemas()) {
		Status status = candidate.register_trait_schema(
				std::move(definition),
				"inventory_system:builtin_trait");
		if (!status.ok()) {
			return status;
		}
	}
	*this = std::move(candidate);
	return ok_status();
}

Status DefinitionCatalog::register_discovery_definitions() {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	if (find_feature(FEATURE_DISCOVERY) != nullptr) {
		return ok_status();
	}
	return register_feature(
			builtin_discovery_feature_module(),
			"inventory_system:builtin_discovery_feature");
}

Status DefinitionCatalog::register_feature(
		FeatureModuleDefinition p_definition,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	if (features.size() >= MAX_FEATURE_MODULES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, features.size() + 1);
	}
	Status status = validate_and_canonicalize(p_definition);
	if (!status.ok()) {
		return status;
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = feature_ids.intern(p_definition.identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	features.emplace(p_definition.identifier, std::move(p_definition));
	return ok_status();
}

Status DefinitionCatalog::register_trait_schema(
		TraitSchemaDefinition p_definition,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	if (trait_schemas.size() >= MAX_TRAIT_SCHEMAS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, trait_schemas.size() + 1);
	}
	Status status = validate_and_canonicalize(p_definition);
	if (!status.ok()) {
		return status;
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = trait_schema_ids.intern(p_definition.identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	trait_schemas.emplace(p_definition.identifier, std::move(p_definition));
	return ok_status();
}

Status DefinitionCatalog::register_discovery_policy(
		DiscoveryPolicyDefinition p_definition,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	if (discovery_policies.size() >= MAX_DISCOVERY_POLICIES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, discovery_policies.size() + 1);
	}
	Status status = validate_and_canonicalize(p_definition);
	if (!status.ok()) {
		return status;
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = discovery_policy_ids.intern(p_definition.identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	discovery_policies.emplace(p_definition.identifier, std::move(p_definition));
	return ok_status();
}

Status DefinitionCatalog::register_container(
		ContainerDefinition p_definition,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	Status status = validate_and_canonicalize(p_definition);
	if (!status.ok()) {
		return status;
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = container_ids.intern(p_definition.identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	containers.emplace(p_definition.identifier, std::move(p_definition));
	return ok_status();
}

Status DefinitionCatalog::register_item(
		ItemDefinition p_definition,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	Status status = validate_and_canonicalize(p_definition);
	if (!status.ok()) {
		return status;
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = item_ids.intern(p_definition.identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	items.emplace(p_definition.identifier, std::move(p_definition));
	return ok_status();
}

Status DefinitionCatalog::register_profile(
		InventoryProfileDefinition p_definition,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	Status status = validate_and_canonicalize(p_definition);
	if (!status.ok()) {
		return status;
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = profile_ids.intern(p_definition.identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	profiles.emplace(p_definition.identifier, std::move(p_definition));
	return ok_status();
}

Status DefinitionCatalog::register_integration_mapping(
		const std::string &p_identifier,
		std::vector<std::uint8_t> p_canonical_bytes,
		const std::string &p_source_label,
		IdentifierConflict *r_conflict) {
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}
	Status status = validate_identifier(p_identifier);
	if (!status.ok()) {
		return status;
	}
	if (p_canonical_bytes.size() > MAX_MANIFEST_ENTRY_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_canonical_bytes.size());
	}
	DefinitionId ignored = INVALID_DEFINITION_ID;
	status = integration_mapping_ids.intern(p_identifier, p_source_label, ignored, r_conflict);
	if (!status.ok()) {
		return status;
	}
	IntegrationMappingRecord record;
	record.identifier = p_identifier;
	record.canonical_bytes = std::move(p_canonical_bytes);
	integration_mappings.emplace(p_identifier, std::move(record));
	return ok_status();
}

Status DefinitionCatalog::validate_enabled_features(const std::vector<std::string> &p_features, std::string *r_offending) const {
	for (const std::string &feature_identifier : p_features) {
		const FeatureModuleDefinition *feature = find_feature(feature_identifier);
		if (feature == nullptr) {
			if (r_offending != nullptr) {
				*r_offending = feature_identifier;
			}
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::FEATURE_DEPENDENCY_MISSING, hash_string(feature_identifier));
		}
		for (const std::string &dependency : feature->dependencies) {
			if (!contains_identifier(p_features, dependency)) {
				if (r_offending != nullptr) {
					*r_offending = dependency;
				}
				return make_status(StatusCode::DEPENDENCY_MISSING, DiagnosticId::FEATURE_DEPENDENCY_MISSING, hash_string(dependency));
			}
		}
	}
	return ok_status();
}

Status DefinitionCatalog::validate_feature_graph(std::string *r_offending) const {
	enum class Visit : std::uint8_t {
		UNVISITED,
		VISITING,
		VISITED,
	};
	std::map<std::string, Visit> visits;
	for (const auto &pair : features) {
		visits.emplace(pair.first, Visit::UNVISITED);
	}

	std::function<Status(const std::string &)> visit = [&](const std::string &identifier) -> Status {
		Visit &state = visits.at(identifier);
		if (state == Visit::VISITED) {
			return ok_status();
		}
		if (state == Visit::VISITING) {
			if (r_offending != nullptr) {
				*r_offending = identifier;
			}
			return make_status(StatusCode::DEPENDENCY_CYCLE, DiagnosticId::FEATURE_DEPENDENCY_CYCLE, hash_string(identifier));
		}
		state = Visit::VISITING;

		const FeatureModuleDefinition &feature = features.at(identifier);
		for (const std::string &dependency : feature.dependencies) {
			if (features.find(dependency) == features.end()) {
				if (r_offending != nullptr) {
					*r_offending = dependency;
				}
				return make_status(StatusCode::DEPENDENCY_MISSING, DiagnosticId::FEATURE_DEPENDENCY_MISSING, hash_string(dependency));
			}
			Status status = visit(dependency);
			if (!status.ok()) {
				return status;
			}
		}
		state = Visit::VISITED;
		return ok_status();
	};

	for (const auto &pair : features) {
		Status status = visit(pair.first);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status DefinitionCatalog::validate_cross_references(std::string *r_offending) const {
	if (profiles.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_ROOT_MISSING);
	}

	Status status = validate_feature_graph(r_offending);
	if (!status.ok()) {
		return status;
	}

	for (const auto &pair : containers) {
		const ContainerDefinition &container = pair.second;
		status = validate_enabled_features(container.enabled_features, r_offending);
		if (!status.ok()) {
			return status;
		}
		if (!container.discovery_policy_identifier.empty()) {
			if (find_discovery_policy(container.discovery_policy_identifier) == nullptr) {
				if (r_offending != nullptr) {
					*r_offending = container.discovery_policy_identifier;
				}
				return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DISCOVERY_POLICY_INVALID, hash_string(container.discovery_policy_identifier));
			}
			if (!contains_identifier(container.enabled_features, FEATURE_DISCOVERY)) {
				if (r_offending != nullptr) {
					*r_offending = FEATURE_DISCOVERY;
				}
				return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::DISCOVERY_FEATURE_REQUIRED, hash_string(FEATURE_DISCOVERY));
			}
		}
		for (const std::string &required : required_container_features(container)) {
			if (!contains_identifier(container.enabled_features, required)) {
				if (r_offending != nullptr) {
					*r_offending = required;
				}
				return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::FEATURE_REQUIRED, hash_string(required));
			}
		}
		status = validate_trait_references(container.constraints.required_traits, trait_schemas, r_offending);
		if (!status.ok()) {
			return status;
		}
		status = validate_trait_references(container.constraints.blocked_traits, trait_schemas, r_offending);
		if (!status.ok()) {
			return status;
		}
		if (const auto *named = std::get_if<NamedSlotsLayout>(&container.layout)) {
			for (const NamedSlotDefinition &slot : named->slots) {
				status = validate_trait_references(slot.required_traits, trait_schemas, r_offending);
				if (!status.ok()) {
					return status;
				}
				status = validate_trait_references(slot.blocked_traits, trait_schemas, r_offending);
				if (!status.ok()) {
					return status;
				}
			}
		}
	}

	for (const auto &pair : items) {
		const ItemDefinition &item = pair.second;
		for (const ItemTraitValue &trait : item.traits) {
			const TraitSchemaDefinition *schema = find_trait_schema(trait.trait_identifier);
			if (schema == nullptr) {
				if (r_offending != nullptr) {
					*r_offending = trait.trait_identifier;
				}
				return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::TRAIT_UNKNOWN, hash_string(trait.trait_identifier));
			}
			if (trait.version != schema->version) {
				if (r_offending != nullptr) {
					*r_offending = pair.first;
				}
				return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::TRAIT_VERSION_MISMATCH, trait.version);
			}
			if (trait.canonical_payload.size() > schema->max_payload_bytes) {
				if (r_offending != nullptr) {
					*r_offending = pair.first;
				}
				return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE, trait.canonical_payload.size());
			}
		}
		for (const std::string &container : item.provided_containers) {
			if (find_container(container) == nullptr) {
				if (r_offending != nullptr) {
					*r_offending = container;
				}
				return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::ITEM_CONTAINER_MISSING, hash_string(container));
			}
		}
	}

	// Every provided-container reference now resolves to a registered
	// container, so the definition-cycle/chain-depth graph below can safely
	// look up containers without re-checking for missing references.
	status = validate_provided_container_graph(r_offending);
	if (!status.ok()) {
		return status;
	}

	for (const auto &pair : profiles) {
		const InventoryProfileDefinition &profile = pair.second;
		status = validate_enabled_features(profile.enabled_features, r_offending);
		if (!status.ok()) {
			return status;
		}
		for (const std::string &container : profile.root_containers) {
			const ContainerDefinition *container_definition = find_container(container);
			if (container_definition == nullptr) {
				if (r_offending != nullptr) {
					*r_offending = container;
				}
				return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::PROFILE_ROOT_MISSING, hash_string(container));
			}
			if (!container_definition->discovery_policy_identifier.empty() &&
					!contains_identifier(profile.enabled_features, FEATURE_DISCOVERY)) {
				if (r_offending != nullptr) {
					*r_offending = FEATURE_DISCOVERY;
				}
				return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::DISCOVERY_FEATURE_REQUIRED, hash_string(FEATURE_DISCOVERY));
			}
		}
	}
	return ok_status();
}

// Definition-level cycle/depth check for item-provided subcontainers.
//
// Nothing in a ContainerDefinition names the items it can hold, and full
// runtime admissibility (footprint, occupancy, current contents) is not
// available at seal time, so this check deliberately does not try to decide
// exact admissibility. Instead it uses two purely structural, statically
// known signals to build a conservative reachability graph:
//
//   - item -> container: item.provided_containers (the item owns/creates an
//     instance of the container when equipped or picked up).
//   - container -> item: only for a container with allow_nesting enabled AND
//     a non-empty required_traits filter. Any OTHER item (not one of the
//     items that directly provide that same container) whose fixed trait set
//     satisfies the filter is conservatively considered reachable. A
//     container with no explicit filter, or with nesting disabled, does not
//     fan out at all: without a declared filter we cannot statically narrow
//     "admissible items" from "every item in the catalog", and treating an
//     unfiltered container as reaching every other nesting container would
//     reject the ordinary, intended pattern of several independent
//     item-provided containers (e.g. a rig, a backpack, and a secure
//     container) that never actually nest inside each other.
//
// An item nesting inside the exact container it itself provides (a bag
// holding another instance of the same bag type) is intentionally not an
// edge: that recursion is legitimate and already bounded by each
// container's max_nesting_depth plus MAX_NESTING_DEPTH, not a definition
// cycle. A genuine cycle across two or more distinct item/container pairs,
// or a chain whose container count exceeds MAX_NESTING_DEPTH, still fails
// closed.
Status DefinitionCatalog::validate_provided_container_graph(std::string *r_offending) const {
	enum class Visit : std::uint8_t {
		UNVISITED,
		VISITING,
		VISITED,
	};

	std::map<std::string, Visit> item_visits;
	std::map<std::string, Visit> container_visits;
	for (const auto &pair : items) {
		item_visits.emplace(pair.first, Visit::UNVISITED);
	}
	for (const auto &pair : containers) {
		container_visits.emplace(pair.first, Visit::UNVISITED);
	}

	std::function<Status(const std::string &, std::uint32_t)> visit_item;
	std::function<Status(const std::string &, std::uint32_t)> visit_container;

	visit_item = [&](const std::string &p_item_identifier, std::uint32_t p_depth) -> Status {
		Visit &state = item_visits.at(p_item_identifier);
		if (state == Visit::VISITED) {
			return ok_status();
		}
		if (state == Visit::VISITING) {
			if (r_offending != nullptr) {
				*r_offending = p_item_identifier;
			}
			return make_status(StatusCode::DEPENDENCY_CYCLE, DiagnosticId::ITEM_CONTAINER_CYCLE, hash_string(p_item_identifier));
		}
		state = Visit::VISITING;
		const ItemDefinition &item_definition = items.at(p_item_identifier);
		for (const std::string &container_identifier : item_definition.provided_containers) {
			Status status = visit_container(container_identifier, p_depth);
			if (!status.ok()) {
				return status;
			}
		}
		state = Visit::VISITED;
		return ok_status();
	};

	visit_container = [&](const std::string &p_container_identifier, std::uint32_t p_depth) -> Status {
		if (p_depth > MAX_NESTING_DEPTH) {
			if (r_offending != nullptr) {
				*r_offending = p_container_identifier;
			}
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::ITEM_CONTAINER_CHAIN_TOO_DEEP, p_depth);
		}
		const auto found = container_visits.find(p_container_identifier);
		if (found == container_visits.end()) {
			// Unknown references are reported by the caller before this graph
			// check runs; nothing further to traverse from here.
			return ok_status();
		}
		Visit &state = found->second;
		if (state == Visit::VISITED) {
			return ok_status();
		}
		if (state == Visit::VISITING) {
			if (r_offending != nullptr) {
				*r_offending = p_container_identifier;
			}
			return make_status(StatusCode::DEPENDENCY_CYCLE, DiagnosticId::ITEM_CONTAINER_CYCLE, hash_string(p_container_identifier));
		}
		state = Visit::VISITING;

		const ContainerDefinition &container_definition = containers.at(p_container_identifier);
		if (container_definition.constraints.allow_nesting &&
				!container_definition.constraints.required_traits.empty()) {
			std::set<std::string> direct_providers;
			for (const auto &pair : items) {
				if (contains_identifier(pair.second.provided_containers, p_container_identifier)) {
					direct_providers.insert(pair.first);
				}
			}
			for (const auto &pair : items) {
				if (direct_providers.find(pair.first) != direct_providers.end()) {
					continue;
				}
				if (!item_satisfies_trait_filter(pair.second, container_definition.constraints)) {
					continue;
				}
				Status status = visit_item(pair.first, p_depth + 1);
				if (!status.ok()) {
					return status;
				}
			}
		}

		state = Visit::VISITED;
		return ok_status();
	};

	for (const auto &pair : items) {
		Status status = visit_item(pair.first, 1);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status DefinitionCatalog::build_manifest(ContentManifest &r_manifest, std::vector<std::uint8_t> &r_bytes) const {
	ManifestBuilder builder;

	ByteWriter limits_writer(MAX_MANIFEST_ENTRY_BYTES);
	encode_hard_limits(limits_writer);
	Status status = limits_writer.status();
	if (!status.ok()) {
		return status;
	}
	status = builder.add(ManifestEntryKind::LIMITS, "inventory.system.limits", limits_writer.bytes());
	if (!status.ok()) {
		return status;
	}

	for (const auto &pair : features) {
		status = add_encoded(builder, ManifestEntryKind::FEATURE_MODULE, pair.first, pair.second);
		if (!status.ok()) {
			return status;
		}
	}
	for (const auto &pair : trait_schemas) {
		status = add_encoded(builder, ManifestEntryKind::TRAIT_SCHEMA, pair.first, pair.second);
		if (!status.ok()) {
			return status;
		}
	}
	for (const auto &pair : containers) {
		status = add_encoded(builder, ManifestEntryKind::CONTAINER, pair.first, pair.second);
		if (!status.ok()) {
			return status;
		}
	}
	for (const auto &pair : items) {
		status = add_encoded(builder, ManifestEntryKind::ITEM, pair.first, pair.second);
		if (!status.ok()) {
			return status;
		}
	}
	for (const auto &pair : profiles) {
		status = add_encoded(builder, ManifestEntryKind::PROFILE, pair.first, pair.second);
		if (!status.ok()) {
			return status;
		}
	}
	for (const auto &pair : integration_mappings) {
		status = builder.add(ManifestEntryKind::INTEGRATION_MAPPING, pair.first, pair.second.canonical_bytes);
		if (!status.ok()) {
			return status;
		}
	}
	for (const auto &pair : discovery_policies) {
		status = add_encoded(builder, ManifestEntryKind::DISCOVERY_POLICY, pair.first, pair.second);
		if (!status.ok()) {
			return status;
		}
	}

	status = builder.canonical_bytes(r_bytes);
	if (!status.ok()) {
		return status;
	}
	return builder.build(r_manifest);
}

Status DefinitionCatalog::seal(std::string *r_offending_identifier) {
	if (r_offending_identifier != nullptr) {
		*r_offending_identifier = std::string();
	}
	if (is_sealed) {
		return make_status(StatusCode::CATALOG_SEALED, DiagnosticId::CATALOG_ALREADY_SEALED);
	}

	DefinitionCatalog candidate = *this;
	Status status = candidate.validate_cross_references(r_offending_identifier);
	if (!status.ok()) {
		return status;
	}

	ContentManifest manifest_value;
	std::vector<std::uint8_t> manifest_bytes_value;
	status = candidate.build_manifest(manifest_value, manifest_bytes_value);
	if (!status.ok()) {
		return status;
	}

	status = candidate.feature_ids.seal();
	if (!status.ok()) {
		return status;
	}
	status = candidate.trait_schema_ids.seal();
	if (!status.ok()) {
		return status;
	}
	status = candidate.discovery_policy_ids.seal();
	if (!status.ok()) {
		return status;
	}
	status = candidate.container_ids.seal();
	if (!status.ok()) {
		return status;
	}
	status = candidate.item_ids.seal();
	if (!status.ok()) {
		return status;
	}
	status = candidate.profile_ids.seal();
	if (!status.ok()) {
		return status;
	}
	status = candidate.integration_mapping_ids.seal();
	if (!status.ok()) {
		return status;
	}

	candidate.sealed_manifest = manifest_value;
	candidate.sealed_manifest_bytes = std::move(manifest_bytes_value);
	candidate.is_sealed = true;
	*this = std::move(candidate);
	return ok_status();
}

const FeatureModuleDefinition *DefinitionCatalog::find_feature(const std::string &p_identifier) const {
	return find_definition(features, p_identifier);
}

const TraitSchemaDefinition *DefinitionCatalog::find_trait_schema(const std::string &p_identifier) const {
	return find_definition(trait_schemas, p_identifier);
}

const DiscoveryPolicyDefinition *DefinitionCatalog::find_discovery_policy(const std::string &p_identifier) const {
	return find_definition(discovery_policies, p_identifier);
}

const ContainerDefinition *DefinitionCatalog::find_container(const std::string &p_identifier) const {
	return find_definition(containers, p_identifier);
}

const ItemDefinition *DefinitionCatalog::find_item(const std::string &p_identifier) const {
	return find_definition(items, p_identifier);
}

const InventoryProfileDefinition *DefinitionCatalog::find_profile(const std::string &p_identifier) const {
	return find_definition(profiles, p_identifier);
}

const IntegrationMappingRecord *DefinitionCatalog::find_integration_mapping(const std::string &p_identifier) const {
	return find_definition(integration_mappings, p_identifier);
}

DefinitionId DefinitionCatalog::feature_id(const std::string &p_identifier) const {
	return feature_ids.lookup(p_identifier);
}

DefinitionId DefinitionCatalog::trait_schema_id(const std::string &p_identifier) const {
	return trait_schema_ids.lookup(p_identifier);
}

DefinitionId DefinitionCatalog::discovery_policy_id(const std::string &p_identifier) const {
	return discovery_policy_ids.lookup(p_identifier);
}

DefinitionId DefinitionCatalog::container_id(const std::string &p_identifier) const {
	return container_ids.lookup(p_identifier);
}

DefinitionId DefinitionCatalog::item_id(const std::string &p_identifier) const {
	return item_ids.lookup(p_identifier);
}

DefinitionId DefinitionCatalog::profile_id(const std::string &p_identifier) const {
	return profile_ids.lookup(p_identifier);
}

DefinitionId DefinitionCatalog::integration_mapping_id(const std::string &p_identifier) const {
	return integration_mapping_ids.lookup(p_identifier);
}

const ContentManifest *DefinitionCatalog::manifest() const {
	return is_sealed ? &sealed_manifest : nullptr;
}

std::uint64_t DefinitionCatalog::identifier_dictionary_fingerprint() const {
	if (!is_sealed) {
		return 0;
	}
	Hasher hasher;
	hasher.write_u64(feature_ids.fingerprint());
	hasher.write_u64(trait_schema_ids.fingerprint());
	hasher.write_u64(container_ids.fingerprint());
	hasher.write_u64(item_ids.fingerprint());
	hasher.write_u64(profile_ids.fingerprint());
	hasher.write_u64(integration_mapping_ids.fingerprint());
	if (!discovery_policies.empty()) {
		hasher.write_u64(discovery_policy_ids.fingerprint());
	}
	return hasher.digest();
}

Status DefinitionCatalog::encode_canonical(std::vector<std::uint8_t> &r_bytes) const {
	if (!is_sealed) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	r_bytes = sealed_manifest_bytes;
	return ok_status();
}

} // namespace inv
