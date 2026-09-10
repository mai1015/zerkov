#ifndef INVENTORY_SYSTEM_CORE_BUILTIN_FEATURES_H
#define INVENTORY_SYSTEM_CORE_BUILTIN_FEATURES_H

#include "core/inv_definitions.h"

#include <string>
#include <vector>

namespace inv {

constexpr const char *FEATURE_SPATIAL_GRID = "inventory.feature.spatial_grid";
constexpr const char *FEATURE_NAMED_SLOTS = "inventory.feature.named_slots";
constexpr const char *FEATURE_ORDERED_LIST = "inventory.feature.ordered_list";
constexpr const char *FEATURE_STACKING = "inventory.feature.stacking";
constexpr const char *FEATURE_FILTERING = "inventory.feature.filtering";
constexpr const char *FEATURE_NESTING = "inventory.feature.nesting";
constexpr const char *FEATURE_ACCESS = "inventory.feature.access";
constexpr const char *FEATURE_COUNT_CAPACITY = "inventory.feature.count_capacity";
constexpr const char *FEATURE_MASS_CAPACITY = "inventory.feature.mass_capacity";
constexpr const char *FEATURE_PROTECTED_RETENTION = "inventory.feature.protected_retention";
constexpr const char *FEATURE_AUTO_PLACEMENT = "inventory.feature.auto_placement";
constexpr const char *FEATURE_QUICK_TRANSFER = "inventory.feature.quick_transfer";
constexpr const char *FEATURE_ROTATION = "inventory.feature.rotation";
constexpr const char *FEATURE_DISCOVERY = "inventory.feature.discovery";

constexpr const char *TRAIT_EQUIPMENT = "inventory.trait.equipment";
constexpr const char *TRAIT_CATEGORY = "inventory.trait.category";
constexpr const char *TRAIT_DURABILITY = "inventory.trait.durability";
constexpr const char *TRAIT_AMMUNITION = "inventory.trait.ammunition";
constexpr const char *TRAIT_INTEGRATION = "inventory.trait.integration";

std::vector<FeatureModuleDefinition> builtin_feature_modules();
// Discovery is compiled in but registered only when a catalog opts in, which
// preserves existing catalogs' feature tables and manifest bytes.
FeatureModuleDefinition builtin_discovery_feature_module();
std::vector<TraitSchemaDefinition> builtin_trait_schemas();

const char *layout_feature(OwnershipLayoutKind p_kind);
std::vector<std::string> required_container_features(const ContainerDefinition &p_definition);

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_BUILTIN_FEATURES_H
