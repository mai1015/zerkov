#include "core/inv_definitions.h"

#include "core/inv_identifier.h"

#include <algorithm>
#include <set>

namespace inv {

namespace {

template <typename T>
bool enum_in_range(T p_value, T p_first, T p_last) {
	return p_value >= p_first && p_value <= p_last;
}

Status validate_schema(std::uint16_t p_version) {
	if (p_version != RESOURCE_SCHEMA_VERSION) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED, p_version);
	}
	return ok_status();
}

Status canonicalize_identifiers(
		std::vector<std::string> &r_values,
		std::size_t p_limit,
		DiagnosticId p_duplicate_diagnostic = DiagnosticId::DEFINITION_DUPLICATE) {
	if (r_values.size() > p_limit) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_values.size());
	}
	for (const std::string &value : r_values) {
		Status status = validate_identifier(value);
		if (!status.ok()) {
			return status;
		}
	}
	std::sort(r_values.begin(), r_values.end(), identifier_less);
	const auto duplicate = std::adjacent_find(r_values.begin(), r_values.end());
	if (duplicate != r_values.end()) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, p_duplicate_diagnostic);
	}
	return ok_status();
}

Status ensure_disjoint(
		const std::vector<std::string> &p_required,
		const std::vector<std::string> &p_blocked) {
	std::size_t a = 0;
	std::size_t b = 0;
	while (a < p_required.size() && b < p_blocked.size()) {
		if (p_required[a] == p_blocked[b]) {
			return make_status(StatusCode::INCOMPATIBLE_DEFINITION, DiagnosticId::FEATURE_INCOMPATIBLE);
		}
		if (identifier_less(p_required[a], p_blocked[b])) {
			++a;
		} else {
			++b;
		}
	}
	return ok_status();
}

void encode_identifiers(const std::vector<std::string> &p_values, std::size_t p_limit, ByteWriter &p_writer) {
	p_writer.write_count(p_values.size(), p_limit);
	for (const std::string &value : p_values) {
		p_writer.write_string(value, MAX_IDENTIFIER_BYTES);
	}
}

Status validate_slot(NamedSlotDefinition &r_slot) {
	Status status = validate_identifier(r_slot.identifier);
	if (!status.ok()) {
		return status;
	}
	if (r_slot.max_items == 0 || r_slot.max_items > MAX_ITEMS_PER_INVENTORY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SLOT_CARDINALITY_INVALID, r_slot.max_items);
	}
	status = canonicalize_identifiers(r_slot.required_traits, MAX_FILTER_TRAITS, DiagnosticId::TRAIT_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_slot.blocked_traits, MAX_FILTER_TRAITS, DiagnosticId::TRAIT_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	return ensure_disjoint(r_slot.required_traits, r_slot.blocked_traits);
}

void encode_slot(const NamedSlotDefinition &p_slot, ByteWriter &p_writer) {
	p_writer.write_string(p_slot.identifier, MAX_IDENTIFIER_BYTES);
	p_writer.write_u32(p_slot.max_items);
	encode_identifiers(p_slot.required_traits, MAX_FILTER_TRAITS, p_writer);
	encode_identifiers(p_slot.blocked_traits, MAX_FILTER_TRAITS, p_writer);
}

Status validate_constraints(ContainerConstraints &r_constraints) {
	if (r_constraints.max_items > MAX_ITEMS_PER_INVENTORY) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_constraints.max_items);
	}
	if (r_constraints.has_mass_capacity && r_constraints.mass_capacity_mg < 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::MASS_CAPACITY_INVALID);
	}
	if (!r_constraints.allow_nesting && r_constraints.max_nesting_depth != 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NESTING_CONFIGURATION_INVALID, r_constraints.max_nesting_depth);
	}
	if (r_constraints.allow_nesting &&
			(r_constraints.max_nesting_depth == 0 || r_constraints.max_nesting_depth > MAX_NESTING_DEPTH)) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NESTING_CONFIGURATION_INVALID, r_constraints.max_nesting_depth);
	}
	if ((r_constraints.access_mask & ~DEFAULT_ACCESS) != 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, r_constraints.access_mask);
	}
	if (!enum_in_range(r_constraints.retention, RetentionClass::NONE, RetentionClass::BOUND)) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::INVALID_ENUM, static_cast<std::uint8_t>(r_constraints.retention));
	}

	Status status = canonicalize_identifiers(r_constraints.required_traits, MAX_FILTER_TRAITS, DiagnosticId::TRAIT_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_constraints.blocked_traits, MAX_FILTER_TRAITS, DiagnosticId::TRAIT_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	return ensure_disjoint(r_constraints.required_traits, r_constraints.blocked_traits);
}

void encode_constraints(const ContainerConstraints &p_constraints, ByteWriter &p_writer) {
	p_writer.write_u32(p_constraints.max_items);
	p_writer.write_bool(p_constraints.has_mass_capacity);
	p_writer.write_i64(p_constraints.mass_capacity_mg);
	encode_identifiers(p_constraints.required_traits, MAX_FILTER_TRAITS, p_writer);
	encode_identifiers(p_constraints.blocked_traits, MAX_FILTER_TRAITS, p_writer);
	p_writer.write_bool(p_constraints.allow_nesting);
	p_writer.write_u32(p_constraints.max_nesting_depth);
	p_writer.write_u8(p_constraints.access_mask);
	p_writer.write_u8(static_cast<std::uint8_t>(p_constraints.retention));
	p_writer.write_bool(p_constraints.allow_stack_split);
	p_writer.write_bool(p_constraints.allow_auto_placement);
	p_writer.write_bool(p_constraints.allow_quick_transfer);
}

Status canonicalize_phases(std::vector<FeaturePhase> &r_phases) {
	if (r_phases.empty() || r_phases.size() > MAX_FEATURE_PHASES) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::FEATURE_PHASE_INVALID, r_phases.size());
	}
	for (FeaturePhase phase : r_phases) {
		if (!enum_in_range(phase, FeaturePhase::DEFINITION_VALIDATION, FeaturePhase::ENCODING)) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::FEATURE_PHASE_INVALID, static_cast<std::uint8_t>(phase));
		}
	}
	std::sort(r_phases.begin(), r_phases.end(), [](FeaturePhase p_a, FeaturePhase p_b) {
		return static_cast<std::uint8_t>(p_a) < static_cast<std::uint8_t>(p_b);
	});
	if (std::adjacent_find(r_phases.begin(), r_phases.end()) != r_phases.end()) {
		return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::FEATURE_PHASE_INVALID);
	}
	return ok_status();
}

void encode_phases(const std::vector<FeaturePhase> &p_phases, ByteWriter &p_writer) {
	p_writer.write_count(p_phases.size(), MAX_FEATURE_PHASES);
	for (FeaturePhase phase : p_phases) {
		p_writer.write_u8(static_cast<std::uint8_t>(phase));
	}
}

} // namespace

Status InventoryLimitsDefinition::validate() const {
	if (max_items == 0 || max_items > MAX_ITEMS_PER_INVENTORY ||
			max_containers == 0 || max_containers > MAX_CONTAINERS_PER_INVENTORY ||
			max_references > MAX_REFERENCES_PER_INVENTORY ||
			max_nesting_depth == 0 || max_nesting_depth > MAX_NESTING_DEPTH ||
			max_mutable_components_per_item > MAX_MUTABLE_COMPONENTS_PER_ITEM) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_LIMIT_INVALID);
	}
	return ok_status();
}

void InventoryLimitsDefinition::encode(ByteWriter &p_writer) const {
	p_writer.write_u32(max_items);
	p_writer.write_u32(max_containers);
	p_writer.write_u32(max_references);
	p_writer.write_u32(max_nesting_depth);
	p_writer.write_u32(max_mutable_components_per_item);
}

OwnershipLayoutKind layout_kind(const LayoutDefinition &p_layout) {
	if (std::holds_alternative<SpatialGridLayout>(p_layout)) {
		return OwnershipLayoutKind::SPATIAL_GRID;
	}
	if (std::holds_alternative<NamedSlotsLayout>(p_layout)) {
		return OwnershipLayoutKind::NAMED_SLOTS;
	}
	return OwnershipLayoutKind::ORDERED_LIST;
}

Status validate_and_canonicalize(TraitSchemaDefinition &r_definition) {
	Status status = validate_identifier(r_definition.identifier);
	if (!status.ok()) {
		return status;
	}
	status = validate_schema(r_definition.version);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.max_payload_bytes > MAX_TRAIT_PAYLOAD_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE, r_definition.max_payload_bytes);
	}
	return ok_status();
}

Status validate_and_canonicalize(DiscoveryPolicyDefinition &r_definition) {
	Status status = validate_identifier(r_definition.identifier);
	if (!status.ok()) {
		return status;
	}
	status = validate_schema(r_definition.schema_version);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.shell_label.size() > MAX_STRING_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, r_definition.shell_label.size());
	}
	if ((!r_definition.container_search_instant && r_definition.container_search_duration_ms == 0) ||
			r_definition.container_search_duration_ms > MAX_DISCOVERY_DURATION_MS ||
			(!r_definition.item_scan_instant && r_definition.item_scan_duration_ms == 0) ||
			r_definition.item_scan_duration_ms > MAX_DISCOVERY_DURATION_MS) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::DISCOVERY_POLICY_INVALID);
	}
	if (r_definition.container_search_instant) {
		r_definition.container_search_duration_ms = 0;
	}
	if (r_definition.item_scan_instant) {
		r_definition.item_scan_duration_ms = 0;
	}
	return ok_status();
}

Status validate_and_canonicalize(ContainerDefinition &r_definition) {
	Status status = validate_identifier(r_definition.identifier);
	if (!status.ok()) {
		return status;
	}
	status = validate_schema(r_definition.schema_version);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_definition.enabled_features, MAX_FEATURE_MODULES, DiagnosticId::FEATURE_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	if (!r_definition.discovery_policy_identifier.empty()) {
		status = validate_identifier(r_definition.discovery_policy_identifier);
		if (!status.ok()) {
			return status;
		}
	}

	if (auto *grid = std::get_if<SpatialGridLayout>(&r_definition.layout)) {
		if (grid->width == 0 || grid->height == 0 ||
				grid->width > MAX_GRID_DIMENSION || grid->height > MAX_GRID_DIMENSION) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GRID_DIMENSION_INVALID);
		}
	} else if (auto *named = std::get_if<NamedSlotsLayout>(&r_definition.layout)) {
		if (named->slots.empty() || named->slots.size() > MAX_SLOTS_PER_CONTAINER) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SLOT_CARDINALITY_INVALID, named->slots.size());
		}
		for (NamedSlotDefinition &slot : named->slots) {
			status = validate_slot(slot);
			if (!status.ok()) {
				return status;
			}
		}
		std::sort(named->slots.begin(), named->slots.end(), [](const NamedSlotDefinition &p_a, const NamedSlotDefinition &p_b) {
			return identifier_less(p_a.identifier, p_b.identifier);
		});
		for (std::size_t i = 1; i < named->slots.size(); ++i) {
			if (named->slots[i - 1].identifier == named->slots[i].identifier) {
				return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::SLOT_DUPLICATE, i);
			}
		}
	} else if (auto *list = std::get_if<OrderedListLayout>(&r_definition.layout)) {
		if (list->max_entries == 0 || list->max_entries > MAX_LIST_ENTRIES) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LIST_CAPACITY_INVALID, list->max_entries);
		}
	} else {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_REQUIRED);
	}

	return validate_constraints(r_definition.constraints);
}

Status validate_and_canonicalize(ItemDefinition &r_definition) {
	Status status = validate_identifier(r_definition.identifier);
	if (!status.ok()) {
		return status;
	}
	status = validate_schema(r_definition.schema_version);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.max_stack == 0 || r_definition.max_stack > MAX_STACK_QUANTITY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, r_definition.max_stack);
	}
	if (r_definition.unit_mass_mg < 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::MASS_CAPACITY_INVALID);
	}
	if (r_definition.footprint_width == 0 || r_definition.footprint_height == 0 ||
			r_definition.footprint_width > MAX_ITEM_FOOTPRINT ||
			r_definition.footprint_height > MAX_ITEM_FOOTPRINT) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::ITEM_FOOTPRINT_INVALID);
	}
	if (r_definition.traits.size() > MAX_TRAITS_PER_ITEM) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, r_definition.traits.size());
	}
	for (ItemTraitValue &trait : r_definition.traits) {
		status = validate_identifier(trait.trait_identifier);
		if (!status.ok()) {
			return status;
		}
		if (trait.version == 0) {
			return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED);
		}
		if (trait.canonical_payload.size() > MAX_TRAIT_PAYLOAD_BYTES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE, trait.canonical_payload.size());
		}
	}
	std::sort(r_definition.traits.begin(), r_definition.traits.end(), [](const ItemTraitValue &p_a, const ItemTraitValue &p_b) {
		return identifier_less(p_a.trait_identifier, p_b.trait_identifier);
	});
	for (std::size_t i = 1; i < r_definition.traits.size(); ++i) {
		if (r_definition.traits[i - 1].trait_identifier == r_definition.traits[i].trait_identifier) {
			return make_status(StatusCode::DUPLICATE_DEFINITION, DiagnosticId::TRAIT_DUPLICATE, i);
		}
	}
	return canonicalize_identifiers(r_definition.provided_containers, MAX_ITEM_PROVIDED_CONTAINERS);
}

Status validate_and_canonicalize(FeatureModuleDefinition &r_definition) {
	Status status = validate_identifier(r_definition.identifier);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.version != FEATURE_MODULE_VERSION) {
		return make_status(StatusCode::SCHEMA_MISMATCH, DiagnosticId::SCHEMA_VERSION_UNSUPPORTED, r_definition.version);
	}
	status = canonicalize_identifiers(r_definition.dependencies, MAX_FEATURE_DEPENDENCIES, DiagnosticId::FEATURE_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	if (std::binary_search(r_definition.dependencies.begin(), r_definition.dependencies.end(), r_definition.identifier, identifier_less)) {
		return make_status(StatusCode::DEPENDENCY_CYCLE, DiagnosticId::FEATURE_DEPENDENCY_CYCLE);
	}
	status = canonicalize_phases(r_definition.phases);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_definition.owned_definition_records, MAX_FEATURE_OWNED_RECORDS);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_definition.owned_state_records, MAX_FEATURE_OWNED_RECORDS);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_definition.owned_command_records, MAX_FEATURE_OWNED_RECORDS);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.canonical_config.size() > MAX_MANIFEST_ENTRY_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, r_definition.canonical_config.size());
	}
	return ok_status();
}

Status validate_and_canonicalize(InventoryProfileDefinition &r_definition) {
	Status status = validate_identifier(r_definition.identifier);
	if (!status.ok()) {
		return status;
	}
	status = validate_schema(r_definition.schema_version);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.root_containers.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_ROOT_MISSING);
	}
	status = canonicalize_identifiers(r_definition.root_containers, MAX_ROOT_CONTAINERS);
	if (!status.ok()) {
		return status;
	}
	status = canonicalize_identifiers(r_definition.enabled_features, MAX_FEATURE_MODULES, DiagnosticId::FEATURE_DUPLICATE);
	if (!status.ok()) {
		return status;
	}
	if (r_definition.root_containers.size() > r_definition.limits.max_containers) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PROFILE_LIMIT_INVALID, r_definition.root_containers.size());
	}
	return r_definition.limits.validate();
}

Status encode_canonical(const TraitSchemaDefinition &p_definition, ByteWriter &p_writer) {
	p_writer.write_u16(p_definition.version);
	p_writer.write_bool(p_definition.authority_affecting);
	p_writer.write_u32(p_definition.max_payload_bytes);
	return p_writer.status();
}

Status encode_canonical(const DiscoveryPolicyDefinition &p_definition, ByteWriter &p_writer) {
	p_writer.write_u16(p_definition.schema_version);
	p_writer.write_bool(p_definition.container_search_instant);
	p_writer.write_u32(p_definition.container_search_duration_ms);
	p_writer.write_bool(p_definition.item_scan_instant);
	p_writer.write_u32(p_definition.item_scan_duration_ms);
	p_writer.write_string(p_definition.shell_label, MAX_STRING_BYTES);
	return p_writer.status();
}

Status encode_canonical(const ContainerDefinition &p_definition, ByteWriter &p_writer) {
	p_writer.write_u16(p_definition.schema_version);
	const OwnershipLayoutKind kind = layout_kind(p_definition.layout);
	p_writer.write_u8(static_cast<std::uint8_t>(kind));
	if (kind == OwnershipLayoutKind::SPATIAL_GRID) {
		const SpatialGridLayout &grid = std::get<SpatialGridLayout>(p_definition.layout);
		p_writer.write_u32(grid.width);
		p_writer.write_u32(grid.height);
		p_writer.write_bool(grid.allow_rotation);
	} else if (kind == OwnershipLayoutKind::NAMED_SLOTS) {
		const NamedSlotsLayout &named = std::get<NamedSlotsLayout>(p_definition.layout);
		p_writer.write_count(named.slots.size(), MAX_SLOTS_PER_CONTAINER);
		for (const NamedSlotDefinition &slot : named.slots) {
			encode_slot(slot, p_writer);
		}
	} else {
		p_writer.write_u32(std::get<OrderedListLayout>(p_definition.layout).max_entries);
	}
	encode_identifiers(p_definition.enabled_features, MAX_FEATURE_MODULES, p_writer);
	encode_constraints(p_definition.constraints, p_writer);
	// Preserve the exact historical bytes for every container that does not
	// opt into discovery. Discovery-enabled catalogs negotiate the feature
	// and therefore understand this append-only field.
	if (!p_definition.discovery_policy_identifier.empty()) {
		p_writer.write_string(p_definition.discovery_policy_identifier, MAX_IDENTIFIER_BYTES);
	}
	return p_writer.status();
}

Status encode_canonical(const ItemDefinition &p_definition, ByteWriter &p_writer) {
	p_writer.write_u16(p_definition.schema_version);
	p_writer.write_u64(p_definition.max_stack);
	p_writer.write_i64(p_definition.unit_mass_mg);
	p_writer.write_u32(p_definition.footprint_width);
	p_writer.write_u32(p_definition.footprint_height);
	p_writer.write_bool(p_definition.allow_rotation);
	p_writer.write_count(p_definition.traits.size(), MAX_TRAITS_PER_ITEM);
	for (const ItemTraitValue &trait : p_definition.traits) {
		p_writer.write_string(trait.trait_identifier, MAX_IDENTIFIER_BYTES);
		p_writer.write_u16(trait.version);
		p_writer.write_blob(trait.canonical_payload, MAX_TRAIT_PAYLOAD_BYTES);
	}
	encode_identifiers(p_definition.provided_containers, MAX_ITEM_PROVIDED_CONTAINERS, p_writer);
	return p_writer.status();
}

Status encode_canonical(const FeatureModuleDefinition &p_definition, ByteWriter &p_writer) {
	p_writer.write_u16(p_definition.version);
	encode_identifiers(p_definition.dependencies, MAX_FEATURE_DEPENDENCIES, p_writer);
	encode_phases(p_definition.phases, p_writer);
	encode_identifiers(p_definition.owned_definition_records, MAX_FEATURE_OWNED_RECORDS, p_writer);
	encode_identifiers(p_definition.owned_state_records, MAX_FEATURE_OWNED_RECORDS, p_writer);
	encode_identifiers(p_definition.owned_command_records, MAX_FEATURE_OWNED_RECORDS, p_writer);
	p_writer.write_blob(p_definition.canonical_config, MAX_MANIFEST_ENTRY_BYTES);
	return p_writer.status();
}

Status encode_canonical(const InventoryProfileDefinition &p_definition, ByteWriter &p_writer) {
	p_writer.write_u16(p_definition.schema_version);
	encode_identifiers(p_definition.root_containers, MAX_ROOT_CONTAINERS, p_writer);
	encode_identifiers(p_definition.enabled_features, MAX_FEATURE_MODULES, p_writer);
	p_definition.limits.encode(p_writer);
	return p_writer.status();
}

} // namespace inv
