#include "core/inv_builtin_features.h"

#include "core/inv_identifier.h"
#include "core/inv_limits.h"

#include <algorithm>
#include <utility>

namespace inv {

namespace {

FeatureModuleDefinition module(
		const char *p_identifier,
		std::vector<std::string> p_dependencies,
		std::vector<FeaturePhase> p_phases,
		std::vector<std::string> p_definition_records,
		std::vector<std::string> p_state_records,
		std::vector<std::string> p_command_records) {
	FeatureModuleDefinition result;
	result.identifier = p_identifier;
	result.dependencies = std::move(p_dependencies);
	result.phases = std::move(p_phases);
	result.owned_definition_records = std::move(p_definition_records);
	result.owned_state_records = std::move(p_state_records);
	result.owned_command_records = std::move(p_command_records);
	return result;
}

void add_required(std::vector<std::string> &r_features, const char *p_feature) {
	if (std::find(r_features.begin(), r_features.end(), p_feature) == r_features.end()) {
		r_features.emplace_back(p_feature);
	}
}

} // namespace

std::vector<FeatureModuleDefinition> builtin_feature_modules() {
	return {
		module(
				FEATURE_SPATIAL_GRID,
				{},
				{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::LAYOUT, FeaturePhase::INVARIANT, FeaturePhase::ENCODING },
				{ "inventory.record.spatial_grid_definition" },
				{ "inventory.record.spatial_placement" },
				{ "inventory.command.move_spatial" }),
		module(
				FEATURE_NAMED_SLOTS,
				{},
				{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::LAYOUT, FeaturePhase::INVARIANT, FeaturePhase::ENCODING },
				{ "inventory.record.named_slots_definition" },
				{ "inventory.record.named_slot_location" },
				{ "inventory.command.equip" }),
		module(
				FEATURE_ORDERED_LIST,
				{},
				{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::LAYOUT, FeaturePhase::INVARIANT, FeaturePhase::ENCODING },
				{ "inventory.record.ordered_list_definition" },
				{ "inventory.record.ordered_list_location" },
				{ "inventory.command.move_list" }),
		module(
				FEATURE_STACKING,
				{},
				{ FeaturePhase::PRECONDITION, FeaturePhase::CONSTRAINT, FeaturePhase::INVARIANT },
				{ "inventory.record.stack_definition" },
				{ "inventory.record.stack_quantity" },
				{ "inventory.command.split", "inventory.command.merge" }),
		module(
				FEATURE_FILTERING,
				{},
				{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::CONSTRAINT },
				{ "inventory.record.trait_filter" },
				{},
				{}),
		module(
				FEATURE_NESTING,
				{},
				{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::CONSTRAINT, FeaturePhase::INVARIANT },
				{ "inventory.record.container_provider" },
				{ "inventory.record.containment_edge" },
				{}),
		module(
				FEATURE_ACCESS,
				{},
				{ FeaturePhase::PRECONDITION, FeaturePhase::CONSTRAINT },
				{ "inventory.record.access_policy" },
				{},
				{}),
		module(
				FEATURE_COUNT_CAPACITY,
				{},
				{ FeaturePhase::CONSTRAINT, FeaturePhase::DERIVATION },
				{ "inventory.record.count_capacity" },
				{},
				{}),
		module(
				FEATURE_MASS_CAPACITY,
				{},
				{ FeaturePhase::CONSTRAINT, FeaturePhase::DERIVATION },
				{ "inventory.record.mass_capacity" },
				{ "inventory.record.mass_total" },
				{}),
		module(
				FEATURE_PROTECTED_RETENTION,
				{},
				{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::DERIVATION },
				{ "inventory.record.retention_class" },
				{},
				{}),
		module(
				FEATURE_AUTO_PLACEMENT,
				{},
				{ FeaturePhase::PRECONDITION, FeaturePhase::LAYOUT },
				{ "inventory.record.auto_placement_policy" },
				{},
				{ "inventory.command.auto_place" }),
		module(
				FEATURE_QUICK_TRANSFER,
				{ FEATURE_AUTO_PLACEMENT },
				{ FeaturePhase::PRECONDITION, FeaturePhase::LAYOUT },
				{ "inventory.record.quick_transfer_policy" },
				{},
				{ "inventory.command.quick_transfer" }),
		module(
				FEATURE_ROTATION,
				{ FEATURE_SPATIAL_GRID },
				{ FeaturePhase::PRECONDITION, FeaturePhase::LAYOUT },
				{ "inventory.record.rotation_policy" },
				{ "inventory.record.orientation" },
				{ "inventory.command.rotate" }),
	};
}

FeatureModuleDefinition builtin_discovery_feature_module() {
	FeatureModuleDefinition result = module(
			FEATURE_DISCOVERY,
			{},
			{ FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::DERIVATION, FeaturePhase::ENCODING },
			{ "inventory.record.discovery_policy" },
			{ "inventory.record.discovery_state", "inventory.record.discovery_task" },
			{ "inventory.intent.discovery_begin_container", "inventory.intent.discovery_begin_item", "inventory.intent.discovery_cancel" });
	// Feature-local hard bounds: only an opted-in catalog contributes these
	// bytes, so legacy catalog/session digests remain untouched.
	ByteWriter writer(MAX_MANIFEST_ENTRY_BYTES);
	writer.write_u64(MAX_DISCOVERY_POLICIES);
	writer.write_u64(MAX_DISCOVERY_RECIPIENTS);
	writer.write_u64(MAX_DISCOVERY_INDEXED_CONTAINERS);
	writer.write_u64(MAX_DISCOVERY_REVEALED_ITEMS);
	writer.write_u64(MAX_DISCOVERY_TOKEN_BINDINGS);
	writer.write_u64(MAX_DISCOVERY_IDEMPOTENCY_RECORDS);
	writer.write_u32(MAX_DISCOVERY_DURATION_MS);
	writer.write_u32(MAX_DISCOVERY_ADVANCE_MS);
	writer.write_u64(MAX_DISCOVERY_VIEW_BYTES);
	writer.write_u64(MAX_DISCOVERY_DELTA_BYTES);
	result.canonical_config = writer.take();
	return result;
}

std::vector<TraitSchemaDefinition> builtin_trait_schemas() {
	return {
		{ TRAIT_EQUIPMENT, RESOURCE_SCHEMA_VERSION, true, 256 },
		{ TRAIT_CATEGORY, RESOURCE_SCHEMA_VERSION, true, 256 },
		{ TRAIT_DURABILITY, RESOURCE_SCHEMA_VERSION, true, 32 },
		{ TRAIT_AMMUNITION, RESOURCE_SCHEMA_VERSION, true, 256 },
		{ TRAIT_INTEGRATION, RESOURCE_SCHEMA_VERSION, true, MAX_TRAIT_PAYLOAD_BYTES },
	};
}

const char *layout_feature(OwnershipLayoutKind p_kind) {
	switch (p_kind) {
		case OwnershipLayoutKind::SPATIAL_GRID:
			return FEATURE_SPATIAL_GRID;
		case OwnershipLayoutKind::NAMED_SLOTS:
			return FEATURE_NAMED_SLOTS;
		case OwnershipLayoutKind::ORDERED_LIST:
			return FEATURE_ORDERED_LIST;
	}
	return "";
}

std::vector<std::string> required_container_features(const ContainerDefinition &p_definition) {
	std::vector<std::string> result;
	add_required(result, layout_feature(layout_kind(p_definition.layout)));

	if (p_definition.constraints.max_items > 0) {
		add_required(result, FEATURE_COUNT_CAPACITY);
	}
	if (p_definition.constraints.has_mass_capacity) {
		add_required(result, FEATURE_MASS_CAPACITY);
	}
	if (!p_definition.constraints.required_traits.empty() ||
			!p_definition.constraints.blocked_traits.empty()) {
		add_required(result, FEATURE_FILTERING);
	}
	if (const auto *named = std::get_if<NamedSlotsLayout>(&p_definition.layout)) {
		for (const NamedSlotDefinition &slot : named->slots) {
			if (!slot.required_traits.empty() || !slot.blocked_traits.empty()) {
				add_required(result, FEATURE_FILTERING);
				break;
			}
		}
	}
	if (p_definition.constraints.allow_nesting) {
		add_required(result, FEATURE_NESTING);
	}
	if (p_definition.constraints.access_mask != DEFAULT_ACCESS) {
		add_required(result, FEATURE_ACCESS);
	}
	if (p_definition.constraints.retention != RetentionClass::NONE) {
		add_required(result, FEATURE_PROTECTED_RETENTION);
	}
	if (p_definition.constraints.allow_stack_split) {
		add_required(result, FEATURE_STACKING);
	}
	if (p_definition.constraints.allow_auto_placement) {
		add_required(result, FEATURE_AUTO_PLACEMENT);
	}
	if (p_definition.constraints.allow_quick_transfer) {
		add_required(result, FEATURE_QUICK_TRANSFER);
	}
	const auto *grid = std::get_if<SpatialGridLayout>(&p_definition.layout);
	if (grid != nullptr && grid->allow_rotation) {
		add_required(result, FEATURE_ROTATION);
	}
	if (!p_definition.discovery_policy_identifier.empty()) {
		add_required(result, FEATURE_DISCOVERY);
	}

	std::sort(result.begin(), result.end(), identifier_less);
	return result;
}

} // namespace inv
