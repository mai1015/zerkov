#ifndef INVENTORY_SYSTEM_CORE_DEFINITIONS_H
#define INVENTORY_SYSTEM_CORE_DEFINITIONS_H

#include "core/inv_bytes.h"
#include "core/inv_limits.h"
#include "core/inv_status.h"

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

namespace inv {

enum class OwnershipLayoutKind : std::uint8_t {
	SPATIAL_GRID = 1,
	NAMED_SLOTS = 2,
	ORDERED_LIST = 3,
};

enum class FeaturePhase : std::uint8_t {
	DEFINITION_VALIDATION = 1,
	PRECONDITION = 2,
	LAYOUT = 3,
	CONSTRAINT = 4,
	DERIVATION = 5,
	INVARIANT = 6,
	ENCODING = 7,
};

enum class RetentionClass : std::uint8_t {
	NONE = 0,
	PROTECTED = 1,
	BOUND = 2,
};

enum class AccessFlag : std::uint8_t {
	NONE = 0,
	INSERT = 1u << 0,
	REMOVE = 1u << 1,
	MOVE = 1u << 2,
	INSPECT = 1u << 3,
};

inline std::uint8_t operator|(AccessFlag p_a, AccessFlag p_b) {
	return static_cast<std::uint8_t>(p_a) | static_cast<std::uint8_t>(p_b);
}

inline std::uint8_t operator|(std::uint8_t p_a, AccessFlag p_b) {
	return p_a | static_cast<std::uint8_t>(p_b);
}

constexpr std::uint8_t DEFAULT_ACCESS =
		static_cast<std::uint8_t>(AccessFlag::INSERT) |
		static_cast<std::uint8_t>(AccessFlag::REMOVE) |
		static_cast<std::uint8_t>(AccessFlag::MOVE) |
		static_cast<std::uint8_t>(AccessFlag::INSPECT);

struct InventoryLimitsDefinition {
	std::uint32_t max_items = MAX_ITEMS_PER_INVENTORY;
	std::uint32_t max_containers = MAX_CONTAINERS_PER_INVENTORY;
	std::uint32_t max_references = MAX_REFERENCES_PER_INVENTORY;
	std::uint32_t max_nesting_depth = MAX_NESTING_DEPTH;
	std::uint32_t max_mutable_components_per_item = MAX_MUTABLE_COMPONENTS_PER_ITEM;

	Status validate() const;
	void encode(ByteWriter &p_writer) const;
};

struct TraitSchemaDefinition {
	std::string identifier;
	std::uint16_t version = RESOURCE_SCHEMA_VERSION;
	bool authority_affecting = true;
	std::uint32_t max_payload_bytes = MAX_TRAIT_PAYLOAD_BYTES;
};

struct ItemTraitValue {
	std::string trait_identifier;
	std::uint16_t version = RESOURCE_SCHEMA_VERSION;
	std::vector<std::uint8_t> canonical_payload;
};

struct SpatialGridLayout {
	std::uint32_t width = 1;
	std::uint32_t height = 1;
	bool allow_rotation = false;
};

struct NamedSlotDefinition {
	std::string identifier;
	std::uint32_t max_items = 1;
	std::vector<std::string> required_traits;
	std::vector<std::string> blocked_traits;
};

struct NamedSlotsLayout {
	std::vector<NamedSlotDefinition> slots;
};

struct OrderedListLayout {
	std::uint32_t max_entries = 1;
};

using LayoutDefinition = std::variant<SpatialGridLayout, NamedSlotsLayout, OrderedListLayout>;

// Sealed, fixed-value staged-discovery policy. The two explicit instant flags
// are what make a zero duration unambiguous; a non-instant zero is rejected.
// shell_label is presentation-safe authored metadata and MUST NOT be used as
// an authority identifier.
struct DiscoveryPolicyDefinition {
	std::string identifier;
	std::uint16_t schema_version = RESOURCE_SCHEMA_VERSION;
	bool container_search_instant = false;
	std::uint32_t container_search_duration_ms = 1000;
	bool item_scan_instant = false;
	std::uint32_t item_scan_duration_ms = 500;
	std::string shell_label;
};

struct ContainerConstraints {
	std::uint32_t max_items = 0; // Zero inherits the profile hard bound.
	bool has_mass_capacity = false;
	std::int64_t mass_capacity_mg = 0;
	std::vector<std::string> required_traits;
	std::vector<std::string> blocked_traits;
	bool allow_nesting = false;
	std::uint32_t max_nesting_depth = 0;
	std::uint8_t access_mask = DEFAULT_ACCESS;
	RetentionClass retention = RetentionClass::NONE;
	bool allow_stack_split = false;
	bool allow_auto_placement = false;
	bool allow_quick_transfer = false;
};

struct ContainerDefinition {
	std::string identifier;
	std::uint16_t schema_version = RESOURCE_SCHEMA_VERSION;
	LayoutDefinition layout = SpatialGridLayout{};
	std::vector<std::string> enabled_features;
	ContainerConstraints constraints;
	// Empty keeps the historical instant-disclosure encoding and behavior.
	// Non-empty names one registered DiscoveryPolicyDefinition and requires
	// inventory.feature.discovery on both this container and its active
	// inventory profile.
	std::string discovery_policy_identifier;
};

struct ItemDefinition {
	std::string identifier;
	std::uint16_t schema_version = RESOURCE_SCHEMA_VERSION;
	std::uint64_t max_stack = 1;
	std::int64_t unit_mass_mg = 0;
	std::uint32_t footprint_width = 1;
	std::uint32_t footprint_height = 1;
	bool allow_rotation = false;
	std::vector<ItemTraitValue> traits;
	std::vector<std::string> provided_containers;
};

struct FeatureModuleDefinition {
	std::string identifier;
	std::uint16_t version = FEATURE_MODULE_VERSION;
	std::vector<std::string> dependencies;
	std::vector<FeaturePhase> phases;
	std::vector<std::string> owned_definition_records;
	std::vector<std::string> owned_state_records;
	std::vector<std::string> owned_command_records;
	std::vector<std::uint8_t> canonical_config;
};

struct InventoryProfileDefinition {
	std::string identifier;
	std::uint16_t schema_version = RESOURCE_SCHEMA_VERSION;
	std::vector<std::string> root_containers;
	std::vector<std::string> enabled_features;
	InventoryLimitsDefinition limits;
};

OwnershipLayoutKind layout_kind(const LayoutDefinition &p_layout);

Status validate_and_canonicalize(TraitSchemaDefinition &r_definition);
Status validate_and_canonicalize(DiscoveryPolicyDefinition &r_definition);
Status validate_and_canonicalize(ContainerDefinition &r_definition);
Status validate_and_canonicalize(ItemDefinition &r_definition);
Status validate_and_canonicalize(FeatureModuleDefinition &r_definition);
Status validate_and_canonicalize(InventoryProfileDefinition &r_definition);

Status encode_canonical(const TraitSchemaDefinition &p_definition, ByteWriter &p_writer);
Status encode_canonical(const DiscoveryPolicyDefinition &p_definition, ByteWriter &p_writer);
Status encode_canonical(const ContainerDefinition &p_definition, ByteWriter &p_writer);
Status encode_canonical(const ItemDefinition &p_definition, ByteWriter &p_writer);
Status encode_canonical(const FeatureModuleDefinition &p_definition, ByteWriter &p_writer);
Status encode_canonical(const InventoryProfileDefinition &p_definition, ByteWriter &p_writer);

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_DEFINITIONS_H
