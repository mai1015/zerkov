#include "core/inv_runtime_state.h"

#include "core/inv_builtin_features.h"
#include "core/inv_checked_math.h"
#include "core/inv_hash.h"
#include "core/inv_limits.h"
#include "core/inv_placement.h"

#include <algorithm>
#include <cstdint>
#include <utility>

namespace inv {

namespace {

bool item_definition_has_trait(const ItemDefinition &p_def, const std::string &p_trait_identifier) {
	for (const ItemTraitValue &trait : p_def.traits) {
		if (trait.trait_identifier == p_trait_identifier) {
			return true;
		}
	}
	return false;
}

Status check_trait_filters(
		const std::vector<std::string> &p_required,
		const std::vector<std::string> &p_blocked,
		const ItemDefinition &p_item_def) {
	for (const std::string &trait : p_required) {
		if (!item_definition_has_trait(p_item_def, trait)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::FILTER_TRAIT_MISMATCH, hash_string(trait));
		}
	}
	for (const std::string &trait : p_blocked) {
		if (item_definition_has_trait(p_item_def, trait)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::FILTER_TRAIT_MISMATCH, hash_string(trait));
		}
	}
	return ok_status();
}

template <typename T>
bool has_headroom(const HandleAllocator<T> &p_allocator, std::size_t p_count) {
	return p_allocator.next_raw() <= UINT64_MAX - static_cast<std::uint64_t>(p_count);
}

// Restores one allocator counter for restore_from_snapshot_parts(). When
// p_shared is false (no IdentityAuthority), this is exactly
// r_allocator.restore_from(p_recorded_next) -- unchanged pre-5.4 behavior
// (the candidate's own private allocator always starts at 0, so this is
// always a plain forward assignment). When p_shared is true, a recorded
// value at or below the authority's CURRENT counter is not corruption --
// see restore_from_snapshot_parts()'s doc comment -- so it is a no-op
// rather than a rejection; only a genuinely larger recorded value advances
// the shared counter.
template <typename T>
Status restore_allocator_counter(HandleAllocator<T> &r_allocator, std::uint64_t p_recorded_next, bool p_shared) {
	if (p_shared && p_recorded_next <= r_allocator.next_raw()) {
		return ok_status();
	}
	return r_allocator.restore_from(p_recorded_next);
}

} // namespace

ContainerInstanceId location_container(const ItemLocation &p_location) {
	return std::visit([](const auto &p_placement) { return p_placement.container; }, p_location);
}

Status InventoryRuntime::create(
		const DefinitionCatalog &p_catalog,
		const std::string &p_profile_identifier,
		InventoryId p_inventory_id,
		InventoryRuntime &r_runtime,
		IdentityAuthority *p_authority) {
	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	if (!p_inventory_id) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	const InventoryProfileDefinition *profile = p_catalog.find_profile(p_profile_identifier);
	if (profile == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_profile_identifier));
	}

	InventoryRuntime runtime;
	runtime.catalog_ = &p_catalog;
	runtime.authority_ = p_authority;
	runtime.inventory_id = p_inventory_id;
	runtime.profile_definition_id = p_catalog.profile_id(p_profile_identifier);
	runtime.profile_identifier_ = p_profile_identifier;
	runtime.enabled_features_ = profile->enabled_features;
	runtime.limits_ = profile->limits;

	if (profile->root_containers.size() > runtime.limits_.max_containers) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, profile->root_containers.size());
	}

	for (const std::string &container_identifier : profile->root_containers) {
		const ContainerDefinition *def = p_catalog.find_container(container_identifier);
		if (def == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(container_identifier));
		}
		const ContainerInstanceId container_id = runtime.active_container_allocator().allocate();
		if (!container_id) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
		}
		ContainerInstance instance;
		instance.id = container_id;
		instance.container_definition = p_catalog.container_id(container_identifier);
		runtime.container_definition_cache_.emplace(instance.container_definition, def);
		runtime.containers_.emplace(container_id, instance);
	}

	r_runtime = std::move(runtime);
	return ok_status();
}

const ItemInstance *InventoryRuntime::find_item(ItemInstanceId p_item) const {
	const auto found = items_.find(p_item);
	return found == items_.end() ? nullptr : &found->second;
}

const ContainerInstance *InventoryRuntime::find_container(ContainerInstanceId p_container) const {
	const auto found = containers_.find(p_container);
	return found == containers_.end() ? nullptr : &found->second;
}

std::vector<ItemInstanceId> InventoryRuntime::items_in_container(ContainerInstanceId p_container) const {
	std::vector<ItemInstanceId> result;
	for (const auto &pair : items_) {
		if (location_container(pair.second.location) == p_container) {
			result.push_back(pair.first);
		}
	}
	return result;
}

std::vector<ContainerInstanceId> InventoryRuntime::root_containers() const {
	std::vector<ContainerInstanceId> result;
	for (const auto &pair : containers_) {
		if (!pair.second.provider_item) {
			result.push_back(pair.first);
		}
	}
	return result;
}

std::uint32_t InventoryRuntime::container_depth(ContainerInstanceId p_container) const {
	ContainerInstanceId current = p_container;
	std::uint32_t depth = 0;
	const std::size_t hop_limit = containers_.size() + 2;
	for (std::size_t hops = 0; hops <= hop_limit; ++hops) {
		const ContainerInstance *container = find_container(current);
		if (container == nullptr) {
			return UINT32_MAX;
		}
		if (!container->provider_item) {
			return depth;
		}
		const ItemInstance *provider = find_item(container->provider_item);
		if (provider == nullptr) {
			return UINT32_MAX;
		}
		current = location_container(provider->location);
		++depth;
	}
	return UINT32_MAX;
}

bool InventoryRuntime::has_feature(const std::string &p_feature_identifier) const {
	return std::find(enabled_features_.begin(), enabled_features_.end(), p_feature_identifier) != enabled_features_.end();
}

std::uint64_t InventoryRuntime::manifest_fingerprint() const {
	if (catalog_ == nullptr) {
		return 0;
	}
	const ContentManifest *manifest = catalog_->manifest();
	return manifest == nullptr ? 0 : manifest->fingerprint;
}

const std::string *InventoryRuntime::item_definition_identifier(DefinitionId p_id) const {
	const ItemDefinition *def = item_definition_of(p_id);
	return def == nullptr ? nullptr : &def->identifier;
}

const std::string *InventoryRuntime::container_definition_identifier(DefinitionId p_id) const {
	const ContainerDefinition *def = container_definition_of(p_id);
	return def == nullptr ? nullptr : &def->identifier;
}

const ContainerDefinition *InventoryRuntime::container_definition(ContainerInstanceId p_container) const {
	const ContainerInstance *instance = find_container(p_container);
	return instance != nullptr ? container_definition_of(instance->container_definition) : nullptr;
}

const DiscoveryPolicyDefinition *InventoryRuntime::discovery_policy(ContainerInstanceId p_container) const {
	if (catalog_ == nullptr) {
		return nullptr;
	}
	const ContainerDefinition *definition = container_definition(p_container);
	if (definition == nullptr || definition->discovery_policy_identifier.empty()) {
		return nullptr;
	}
	return catalog_->find_discovery_policy(definition->discovery_policy_identifier);
}

Status InventoryRuntime::item_subtree_mass(ItemInstanceId p_item_id, std::int64_t &r_out_mg) const {
	r_out_mg = 0;
	const ItemInstance *item = find_item(p_item_id);
	if (item == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}
	const ItemDefinition *def = item_definition_of(item->item_definition);
	if (def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_item_id.value);
	}

	// item->quantity is already bounded by MAX_STACK_QUANTITY (1,000,000, see
	// create_item()/set_quantity()), so it always fits in an int64_t.
	const std::int64_t quantity = static_cast<std::int64_t>(item->quantity);
	std::int64_t total = 0;
	Status status = checked_mul_i64(def->unit_mass_mg, quantity, total);
	if (!status.ok()) {
		return status;
	}

	// provided_containers is already in canonical ascending ContainerInstanceId
	// order (see ItemInstance::provided_containers), so accumulation order is
	// deterministic and independent of any external traversal choice.
	for (ContainerInstanceId provided : item->provided_containers) {
		std::int64_t contained_mass = 0;
		status = container_mass(provided, contained_mass);
		if (!status.ok()) {
			return status;
		}
		std::int64_t next_total = 0;
		status = checked_add_i64(total, contained_mass, next_total);
		if (!status.ok()) {
			return status;
		}
		total = next_total;
	}

	r_out_mg = total;
	return ok_status();
}

Status InventoryRuntime::container_mass(ContainerInstanceId p_container_id, std::int64_t &r_out_mg) const {
	r_out_mg = 0;
	if (find_container(p_container_id) == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_container_id.value);
	}

	// items_in_container() walks items_ (a std::map), so members already come
	// back in canonical ascending ItemInstanceId order; every member is
	// counted exactly once regardless of traversal order elsewhere.
	std::int64_t total = 0;
	for (ItemInstanceId member_id : items_in_container(p_container_id)) {
		std::int64_t member_mass = 0;
		Status status = item_subtree_mass(member_id, member_mass);
		if (!status.ok()) {
			return status;
		}
		std::int64_t next_total = 0;
		status = checked_add_i64(total, member_mass, next_total);
		if (!status.ok()) {
			return status;
		}
		total = next_total;
	}

	r_out_mg = total;
	return ok_status();
}

Status InventoryRuntime::total_mass(std::int64_t &r_out_mg) const {
	r_out_mg = 0;
	std::int64_t total = 0;
	for (ContainerInstanceId root : root_containers()) {
		std::int64_t root_mass = 0;
		Status status = container_mass(root, root_mass);
		if (!status.ok()) {
			return status;
		}
		std::int64_t next_total = 0;
		status = checked_add_i64(total, root_mass, next_total);
		if (!status.ok()) {
			return status;
		}
		total = next_total;
	}
	r_out_mg = total;
	return ok_status();
}

Status InventoryRuntime::container_mass_capacity(ContainerInstanceId p_container_id, std::int64_t &r_out_mg) const {
	r_out_mg = 0;
	const ContainerInstance *container = find_container(p_container_id);
	if (container == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_container_id.value);
	}
	const ContainerDefinition *def = container_definition_of(container->container_definition);
	if (def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_container_id.value);
	}
	if (!def->constraints.has_mass_capacity || !has_feature(FEATURE_MASS_CAPACITY)) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::CAPACITY_FEATURE_UNAVAILABLE, p_container_id.value);
	}
	r_out_mg = def->constraints.mass_capacity_mg;
	return ok_status();
}

Status InventoryRuntime::count_in_container(ContainerInstanceId p_container_id, std::uint32_t &r_out_count) const {
	r_out_count = 0;
	if (find_container(p_container_id) == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_container_id.value);
	}
	r_out_count = static_cast<std::uint32_t>(items_in_container(p_container_id).size());
	return ok_status();
}

Status InventoryRuntime::remaining_count_capacity(ContainerInstanceId p_container_id, std::uint32_t &r_out_remaining) const {
	r_out_remaining = 0;
	const ContainerInstance *container = find_container(p_container_id);
	if (container == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_container_id.value);
	}
	const ContainerDefinition *def = container_definition_of(container->container_definition);
	if (def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_container_id.value);
	}
	// constraints.max_items == 0 means "inherits the profile hard bound", not
	// an explicit per-container capacity claim; only an explicit cap counts
	// as the inventory.feature.count_capacity feature having something to
	// report (mirrors container_mass_capacity()'s has_mass_capacity gate).
	if (def->constraints.max_items == 0 || !has_feature(FEATURE_COUNT_CAPACITY)) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::CAPACITY_FEATURE_UNAVAILABLE, p_container_id.value);
	}
	const std::uint32_t current = static_cast<std::uint32_t>(items_in_container(p_container_id).size());
	r_out_remaining = current >= def->constraints.max_items ? 0 : def->constraints.max_items - current;
	return ok_status();
}

Status InventoryRuntime::fits(
		const std::string &p_item_definition_identifier,
		const ItemLocation &p_location,
		std::uint64_t p_quantity,
		ItemInstanceId p_excluding_item) const {
	if (catalog_ == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const ItemDefinition *item_def = catalog_->find_item(p_item_definition_identifier);
	if (item_def == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_item_definition_identifier));
	}
	if (p_quantity < 1 || p_quantity > item_def->max_stack || p_quantity > MAX_STACK_QUANTITY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, p_quantity);
	}

	const ContainerInstance *target = nullptr;
	const ContainerDefinition *target_def = nullptr;
	Status placement_status = validate_placement(p_location, p_excluding_item, *item_def, target, target_def);
	if (!placement_status.ok()) {
		return placement_status;
	}
	return validate_nesting_target(target->id, *target_def);
}

const ItemDefinition *InventoryRuntime::item_definition_of(DefinitionId p_id) const {
	const auto found = item_definition_cache_.find(p_id);
	return found == item_definition_cache_.end() ? nullptr : found->second;
}

const ContainerDefinition *InventoryRuntime::container_definition_of(DefinitionId p_id) const {
	const auto found = container_definition_cache_.find(p_id);
	return found == container_definition_cache_.end() ? nullptr : found->second;
}

std::uint32_t InventoryRuntime::effective_container_item_cap(const ContainerDefinition &p_def) const {
	return p_def.constraints.max_items != 0 ? p_def.constraints.max_items : limits_.max_items;
}

std::vector<ItemInstanceId> InventoryRuntime::list_items_by_ordinal(ContainerInstanceId p_container) const {
	std::vector<std::pair<std::uint32_t, ItemInstanceId>> entries;
	for (ItemInstanceId id : items_in_container(p_container)) {
		const ItemInstance &item = items_.at(id);
		if (const ListPlacement *placement = std::get_if<ListPlacement>(&item.location)) {
			entries.emplace_back(placement->ordinal, id);
		}
	}
	std::sort(entries.begin(), entries.end());
	std::vector<ItemInstanceId> result;
	result.reserve(entries.size());
	for (const auto &entry : entries) {
		result.push_back(entry.second);
	}
	return result;
}

void InventoryRuntime::apply_list_insert(ContainerInstanceId p_container, ItemInstanceId p_item, std::uint32_t p_ordinal) {
	std::vector<ItemInstanceId> sequence = list_items_by_ordinal(p_container);
	sequence.erase(std::remove(sequence.begin(), sequence.end(), p_item), sequence.end());
	const std::uint32_t clamped = p_ordinal < sequence.size() ? p_ordinal : static_cast<std::uint32_t>(sequence.size());
	sequence.insert(sequence.begin() + clamped, p_item);
	for (std::uint32_t i = 0; i < sequence.size(); ++i) {
		ListPlacement placement;
		placement.container = p_container;
		placement.ordinal = i;
		items_.at(sequence[i]).location = placement;
	}
}

void InventoryRuntime::redensify_list(ContainerInstanceId p_container) {
	std::vector<ItemInstanceId> sequence = list_items_by_ordinal(p_container);
	for (std::uint32_t i = 0; i < sequence.size(); ++i) {
		ListPlacement placement;
		placement.container = p_container;
		placement.ordinal = i;
		items_.at(sequence[i]).location = placement;
	}
}

Status InventoryRuntime::validate_placement(
		const ItemLocation &p_location,
		ItemInstanceId p_excluding_item,
		const ItemDefinition &p_item_def,
		const ContainerInstance *&r_container,
		const ContainerDefinition *&r_container_def,
		ItemInstanceId p_excluding_item_2) const {
	const auto is_excluded = [&](ItemInstanceId p_id) {
		return p_id == p_excluding_item || (bool(p_excluding_item_2) && p_id == p_excluding_item_2);
	};
	const ContainerInstanceId container_id = location_container(p_location);
	r_container = find_container(container_id);
	if (r_container == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, container_id.value);
	}
	r_container_def = container_definition_of(r_container->container_definition);
	if (r_container_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, container_id.value);
	}
	const OwnershipLayoutKind kind = layout_kind(r_container_def->layout);

	if (const SpatialPlacement *spatial = std::get_if<SpatialPlacement>(&p_location)) {
		if (kind != OwnershipLayoutKind::SPATIAL_GRID) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID);
		}
		const SpatialGridLayout &grid = std::get<SpatialGridLayout>(r_container_def->layout);
		if (spatial->rotated && (!p_item_def.allow_rotation || !grid.allow_rotation)) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::ITEM_FOOTPRINT_INVALID);
		}
		const GridRect rect = effective_footprint(spatial->x, spatial->y, p_item_def.footprint_width, p_item_def.footprint_height, spatial->rotated);
		if (!grid_rect_in_bounds(rect, grid.width, grid.height)) {
			return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::PLACEMENT_OUT_OF_BOUNDS, container_id.value);
		}
		for (ItemInstanceId other_id : items_in_container(container_id)) {
			if (is_excluded(other_id)) {
				continue;
			}
			const ItemInstance &other = items_.at(other_id);
			const SpatialPlacement *other_placement = std::get_if<SpatialPlacement>(&other.location);
			if (other_placement == nullptr) {
				continue;
			}
			const ItemDefinition *other_def = item_definition_of(other.item_definition);
			if (other_def == nullptr) {
				return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, other_id.value);
			}
			const GridRect other_rect = effective_footprint(other_placement->x, other_placement->y, other_def->footprint_width, other_def->footprint_height, other_placement->rotated);
			if (grid_rects_overlap(rect, other_rect)) {
				return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::PLACEMENT_OVERLAP, other_id.value);
			}
		}
	} else if (const SlotPlacement *slot_placement = std::get_if<SlotPlacement>(&p_location)) {
		if (kind != OwnershipLayoutKind::NAMED_SLOTS) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID);
		}
		const NamedSlotsLayout &named = std::get<NamedSlotsLayout>(r_container_def->layout);
		const NamedSlotDefinition *slot_def = nullptr;
		for (const NamedSlotDefinition &candidate : named.slots) {
			if (candidate.identifier == slot_placement->slot_identifier) {
				slot_def = &candidate;
				break;
			}
		}
		if (slot_def == nullptr) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SLOT_UNKNOWN, hash_string(slot_placement->slot_identifier));
		}
		Status filter_status = check_trait_filters(slot_def->required_traits, slot_def->blocked_traits, p_item_def);
		if (!filter_status.ok()) {
			return filter_status;
		}
		std::uint32_t occupancy = 0;
		for (ItemInstanceId other_id : items_in_container(container_id)) {
			if (is_excluded(other_id)) {
				continue;
			}
			const SlotPlacement *other_slot = std::get_if<SlotPlacement>(&items_.at(other_id).location);
			if (other_slot != nullptr && other_slot->slot_identifier == slot_placement->slot_identifier) {
				++occupancy;
			}
		}
		if (occupancy >= slot_def->max_items) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, occupancy + 1);
		}
	} else {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_location);
		if (kind != OwnershipLayoutKind::ORDERED_LIST) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID);
		}
		const OrderedListLayout &list_layout = std::get<OrderedListLayout>(r_container_def->layout);
		const std::vector<ItemInstanceId> sequence = list_items_by_ordinal(container_id);
		// filtered_size == "how many entries this list would have if every
		// excluded id were already gone", so the item being validated always
		// lands as exactly one more than that (this generalizes the old
		// single-exclusion already_present bookkeeping -- see
		// validate_placement()'s p_excluding_item_2 doc comment in the header
		// for the equivalence with the prior single-id logic).
		std::size_t filtered_size = 0;
		for (ItemInstanceId existing_id : sequence) {
			if (!is_excluded(existing_id)) {
				++filtered_size;
			}
		}
		const std::size_t count_after = filtered_size + 1;
		if (count_after > list_layout.max_entries) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LIST_CAPACITY_INVALID, count_after);
		}
		if (list_placement.ordinal > filtered_size) {
			return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::LIST_ORDINAL_INVALID, list_placement.ordinal);
		}
	}

	Status filter_status = check_trait_filters(r_container_def->constraints.required_traits, r_container_def->constraints.blocked_traits, p_item_def);
	if (!filter_status.ok()) {
		return filter_status;
	}

	std::uint32_t container_count = 0;
	for (ItemInstanceId other_id : items_in_container(container_id)) {
		if (!is_excluded(other_id)) {
			++container_count;
		}
	}
	const std::uint32_t cap = effective_container_item_cap(*r_container_def);
	if (container_count >= cap) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, container_count + 1);
	}

	return ok_status();
}

Status InventoryRuntime::validate_nesting_target(ContainerInstanceId p_container, const ContainerDefinition &p_container_def) const {
	const std::uint32_t depth = container_depth(p_container);
	if (depth == UINT32_MAX) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_container.value);
	}
	if (depth == 0) {
		return ok_status();
	}
	if (!p_container_def.constraints.allow_nesting ||
			depth > p_container_def.constraints.max_nesting_depth ||
			depth > MAX_NESTING_DEPTH) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::NESTING_DEPTH_EXCEEDED, depth);
	}
	return ok_status();
}

Status InventoryRuntime::check_no_cycle(ContainerInstanceId p_target, ItemInstanceId p_moving_item) const {
	ContainerInstanceId current = p_target;
	const std::size_t hop_limit = containers_.size() + 2;
	for (std::size_t hops = 0; hops < hop_limit; ++hops) {
		const ContainerInstance *container = find_container(current);
		if (container == nullptr) {
			return ok_status();
		}
		if (!container->provider_item) {
			return ok_status();
		}
		if (container->provider_item == p_moving_item) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, current.value);
		}
		const ItemInstance *provider = find_item(container->provider_item);
		if (provider == nullptr) {
			return ok_status();
		}
		current = location_container(provider->location);
	}
	return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_target.value);
}

std::vector<ContainerInstanceId> InventoryRuntime::collect_subtree_containers(ItemInstanceId p_item) const {
	std::vector<ContainerInstanceId> result;
	std::vector<ItemInstanceId> frontier = { p_item };
	std::size_t cursor = 0;
	while (cursor < frontier.size()) {
		const ItemInstance *item = find_item(frontier[cursor]);
		++cursor;
		if (item == nullptr) {
			continue;
		}
		for (ContainerInstanceId container_id : item->provided_containers) {
			result.push_back(container_id);
			for (ItemInstanceId child : items_in_container(container_id)) {
				frontier.push_back(child);
			}
		}
	}
	return result;
}

Status InventoryRuntime::validate_subtree_nesting_after_move(const ItemInstance &p_moving_item, ContainerInstanceId p_target_container) const {
	const std::uint32_t old_depth = container_depth(location_container(p_moving_item.location));
	const std::uint32_t new_depth = container_depth(p_target_container);
	if (old_depth == UINT32_MAX || new_depth == UINT32_MAX) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_target_container.value);
	}
	for (ContainerInstanceId descendant : collect_subtree_containers(p_moving_item.id)) {
		const std::uint32_t old_descendant_depth = container_depth(descendant);
		if (old_descendant_depth == UINT32_MAX || old_descendant_depth < old_depth) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, descendant.value);
		}
		const std::uint32_t relative = old_descendant_depth - old_depth;
		const std::uint32_t new_descendant_depth = new_depth + relative;
		const ContainerInstance *container = find_container(descendant);
		const ContainerDefinition *def = container == nullptr ? nullptr : container_definition_of(container->container_definition);
		if (def == nullptr || !def->constraints.allow_nesting ||
				new_descendant_depth > def->constraints.max_nesting_depth ||
				new_descendant_depth > MAX_NESTING_DEPTH) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::NESTING_DEPTH_EXCEEDED, new_descendant_depth);
		}
	}
	return ok_status();
}

Status InventoryRuntime::create_item(
		const std::string &p_item_identifier,
		std::uint64_t p_quantity,
		const ItemLocation &p_location,
		ItemInstanceId &r_item_id) {
	r_item_id = ItemInstanceId{};

	if (catalog_ == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	if (items_.size() >= limits_.max_items) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, items_.size() + 1);
	}

	const ItemDefinition *item_def = catalog_->find_item(p_item_identifier);
	if (item_def == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_item_identifier));
	}
	if (p_quantity < 1 || p_quantity > item_def->max_stack || p_quantity > MAX_STACK_QUANTITY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, p_quantity);
	}

	const ContainerInstance *target = nullptr;
	const ContainerDefinition *target_def = nullptr;
	Status placement_status = validate_placement(p_location, ItemInstanceId{}, *item_def, target, target_def);
	if (!placement_status.ok()) {
		return placement_status;
	}
	Status nesting_status = validate_nesting_target(target->id, *target_def);
	if (!nesting_status.ok()) {
		return nesting_status;
	}

	const std::uint32_t target_depth = container_depth(target->id);
	std::vector<const ContainerDefinition *> provided_defs;
	provided_defs.reserve(item_def->provided_containers.size());
	for (const std::string &provided_identifier : item_def->provided_containers) {
		const ContainerDefinition *provided_def = catalog_->find_container(provided_identifier);
		if (provided_def == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, hash_string(provided_identifier));
		}
		const std::uint32_t child_depth = target_depth + 1;
		if (!provided_def->constraints.allow_nesting ||
				child_depth > provided_def->constraints.max_nesting_depth ||
				child_depth > MAX_NESTING_DEPTH) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::NESTING_DEPTH_EXCEEDED, child_depth);
		}
		provided_defs.push_back(provided_def);
	}

	if (containers_.size() + provided_defs.size() > limits_.max_containers) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, containers_.size() + provided_defs.size());
	}
	if (!has_headroom(active_item_allocator(), 1) || !has_headroom(active_container_allocator(), provided_defs.size())) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}

	// Validation complete; mutate.
	const ItemInstanceId new_item_id = active_item_allocator().allocate();

	ItemInstance instance;
	instance.id = new_item_id;
	instance.item_definition = catalog_->item_id(p_item_identifier);
	instance.quantity = p_quantity;
	instance.location = p_location;
	item_definition_cache_.emplace(instance.item_definition, item_def);

	for (std::size_t i = 0; i < item_def->provided_containers.size(); ++i) {
		const ContainerInstanceId provided_id = active_container_allocator().allocate();
		ContainerInstance provided;
		provided.id = provided_id;
		provided.container_definition = catalog_->container_id(item_def->provided_containers[i]);
		provided.provider_item = new_item_id;
		container_definition_cache_.emplace(provided.container_definition, provided_defs[i]);
		containers_.emplace(provided_id, provided);
		instance.provided_containers.push_back(provided_id);
	}

	items_.emplace(new_item_id, instance);

	if (std::holds_alternative<ListPlacement>(p_location)) {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_location);
		apply_list_insert(list_placement.container, new_item_id, list_placement.ordinal);
	}

	r_item_id = new_item_id;
	return ok_status();
}

Status InventoryRuntime::collect_cascade(
		ItemInstanceId p_root_item,
		std::vector<ItemInstanceId> &r_items,
		std::vector<ContainerInstanceId> &r_containers) const {
	r_items.clear();
	r_containers.clear();
	r_items.push_back(p_root_item);
	const std::size_t hop_limit = items_.size() + containers_.size() + 2;
	std::size_t cursor = 0;
	while (cursor < r_items.size()) {
		if (r_items.size() + r_containers.size() > hop_limit) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_root_item.value);
		}
		const ItemInstance *item = find_item(r_items[cursor]);
		const ItemInstanceId current_id = r_items[cursor];
		++cursor;
		if (item == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, current_id.value);
		}
		for (ContainerInstanceId container_id : item->provided_containers) {
			r_containers.push_back(container_id);
			for (ItemInstanceId child : items_in_container(container_id)) {
				r_items.push_back(child);
			}
		}
	}
	return ok_status();
}

Status InventoryRuntime::destroy_item(ItemInstanceId p_item_id) {
	const auto found = items_.find(p_item_id);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}

	std::vector<ItemInstanceId> cascade_items;
	std::vector<ContainerInstanceId> cascade_containers;
	Status gather_status = collect_cascade(p_item_id, cascade_items, cascade_containers);
	if (!gather_status.ok()) {
		return gather_status;
	}

	const ItemLocation original_location = found->second.location;
	const bool was_list = std::holds_alternative<ListPlacement>(original_location);
	const ContainerInstanceId original_container = location_container(original_location);

	// Validation complete; mutate. References first (so nothing can dangle
	// even transiently), then containers, then items.
	std::vector<ReferenceId> dangling;
	for (const auto &pair : references_) {
		for (ItemInstanceId cascaded : cascade_items) {
			if (pair.second == cascaded) {
				dangling.push_back(pair.first);
				break;
			}
		}
	}
	for (ReferenceId reference_id : dangling) {
		references_.erase(reference_id);
	}
	for (ContainerInstanceId container_id : cascade_containers) {
		containers_.erase(container_id);
	}
	for (ItemInstanceId item_id : cascade_items) {
		items_.erase(item_id);
	}

	if (was_list) {
		redensify_list(original_container);
	}
	return ok_status();
}

Status InventoryRuntime::move_item(ItemInstanceId p_item_id, const ItemLocation &p_new_location) {
	const auto found = items_.find(p_item_id);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}
	const ItemInstance existing = found->second;
	const ItemDefinition *item_def = item_definition_of(existing.item_definition);
	if (item_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_item_id.value);
	}

	const ContainerInstanceId new_container = location_container(p_new_location);

	Status cycle_status = check_no_cycle(new_container, p_item_id);
	if (!cycle_status.ok()) {
		return cycle_status;
	}

	const ContainerInstance *target = nullptr;
	const ContainerDefinition *target_def = nullptr;
	Status placement_status = validate_placement(p_new_location, p_item_id, *item_def, target, target_def);
	if (!placement_status.ok()) {
		return placement_status;
	}
	Status nesting_status = validate_nesting_target(new_container, *target_def);
	if (!nesting_status.ok()) {
		return nesting_status;
	}
	Status subtree_status = validate_subtree_nesting_after_move(existing, new_container);
	if (!subtree_status.ok()) {
		return subtree_status;
	}

	// Validation complete; mutate.
	const bool old_was_list = std::holds_alternative<ListPlacement>(existing.location);
	const ContainerInstanceId old_container = location_container(existing.location);

	if (std::holds_alternative<ListPlacement>(p_new_location)) {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_new_location);
		apply_list_insert(list_placement.container, p_item_id, list_placement.ordinal);
	} else {
		items_.at(p_item_id).location = p_new_location;
	}

	if (old_was_list && (old_container != new_container || !std::holds_alternative<ListPlacement>(p_new_location))) {
		redensify_list(old_container);
	}
	return ok_status();
}

Status InventoryRuntime::swap_items(ItemInstanceId p_item_a, ItemInstanceId p_item_b) {
	if (!p_item_a || !p_item_b || p_item_a == p_item_b) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_item_a.value);
	}
	const auto found_a = items_.find(p_item_a);
	if (found_a == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_a.value);
	}
	const auto found_b = items_.find(p_item_b);
	if (found_b == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_b.value);
	}
	// Captured before any mutation, exactly like move_item()'s `existing`, so
	// every check below reads one consistent pre-swap snapshot.
	const ItemInstance existing_a = found_a->second;
	const ItemInstance existing_b = found_b->second;
	const ItemDefinition *def_a = item_definition_of(existing_a.item_definition);
	const ItemDefinition *def_b = item_definition_of(existing_b.item_definition);
	if (def_a == nullptr || def_b == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE);
	}

	// item_a's destination is item_b's current location and vice versa: a
	// pure exchange, no caller-supplied coordinates.
	const ContainerInstanceId new_container_a = location_container(existing_b.location);
	const ContainerInstanceId new_container_b = location_container(existing_a.location);

	Status cycle_status = check_no_cycle(new_container_a, p_item_a);
	if (!cycle_status.ok()) {
		return cycle_status;
	}
	cycle_status = check_no_cycle(new_container_b, p_item_b);
	if (!cycle_status.ok()) {
		return cycle_status;
	}

	// Each validate_placement() call excludes BOTH the item being placed
	// (its own still-present old self-entry, exactly like move_item()) AND
	// the other swap participant (who currently squats on the exact target
	// cell/slot/ordinal and is vacating it in the same atomic exchange). A
	// single exclusion id cannot express that for a same-container swap; see
	// the p_excluding_item_2 doc comment on validate_placement().
	const ContainerInstance *target_a = nullptr;
	const ContainerDefinition *target_def_a = nullptr;
	Status placement_status = validate_placement(existing_b.location, p_item_a, *def_a, target_a, target_def_a, p_item_b);
	if (!placement_status.ok()) {
		return placement_status;
	}
	Status nesting_status = validate_nesting_target(new_container_a, *target_def_a);
	if (!nesting_status.ok()) {
		return nesting_status;
	}

	const ContainerInstance *target_b = nullptr;
	const ContainerDefinition *target_def_b = nullptr;
	placement_status = validate_placement(existing_a.location, p_item_b, *def_b, target_b, target_def_b, p_item_a);
	if (!placement_status.ok()) {
		return placement_status;
	}
	nesting_status = validate_nesting_target(new_container_b, *target_def_b);
	if (!nesting_status.ok()) {
		return nesting_status;
	}

	Status subtree_status = validate_subtree_nesting_after_move(existing_a, new_container_a);
	if (!subtree_status.ok()) {
		return subtree_status;
	}
	subtree_status = validate_subtree_nesting_after_move(existing_b, new_container_b);
	if (!subtree_status.ok()) {
		return subtree_status;
	}

	// Validation complete; mutate. Whatever cell/slot/ordinal item_a vacates
	// is exactly item_b's new location and vice versa, so the exchange is
	// self-densifying for ORDERED_LIST containers too: no redensify_list()
	// call can ever be needed (unlike move_item(), which can leave a real
	// gap behind in a list nothing else fills).
	items_.at(p_item_a).location = existing_b.location;
	items_.at(p_item_b).location = existing_a.location;
	return ok_status();
}

Status InventoryRuntime::set_quantity(ItemInstanceId p_item_id, std::uint64_t p_quantity) {
	const auto found = items_.find(p_item_id);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}
	const ItemDefinition *item_def = item_definition_of(found->second.item_definition);
	if (item_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_item_id.value);
	}
	if (p_quantity < 1 || p_quantity > item_def->max_stack || p_quantity > MAX_STACK_QUANTITY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, p_quantity);
	}
	found->second.quantity = p_quantity;
	return ok_status();
}

Status InventoryRuntime::set_component(
		ItemInstanceId p_item_id,
		const std::string &p_component_identifier,
		std::vector<std::uint8_t> p_payload) {
	const auto found = items_.find(p_item_id);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}
	Status identifier_status = validate_identifier(p_component_identifier);
	if (!identifier_status.ok()) {
		return identifier_status;
	}
	if (p_payload.size() > MAX_TRAIT_PAYLOAD_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE, p_payload.size());
	}

	std::vector<MutableComponent> &components = found->second.mutable_components;
	const auto existing = std::find_if(components.begin(), components.end(), [&](const MutableComponent &p_component) {
		return p_component.component_identifier == p_component_identifier;
	});
	if (existing == components.end() && components.size() >= limits_.max_mutable_components_per_item) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, components.size() + 1);
	}

	if (existing != components.end()) {
		existing->payload = std::move(p_payload);
		return ok_status();
	}

	MutableComponent component;
	component.component_identifier = p_component_identifier;
	component.payload = std::move(p_payload);
	const auto insert_at = std::lower_bound(components.begin(), components.end(), component,
			[](const MutableComponent &p_a, const MutableComponent &p_b) {
				return identifier_less(p_a.component_identifier, p_b.component_identifier);
			});
	components.insert(insert_at, std::move(component));
	return ok_status();
}

Status InventoryRuntime::remove_component(ItemInstanceId p_item_id, const std::string &p_component_identifier) {
	const auto found = items_.find(p_item_id);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}
	std::vector<MutableComponent> &components = found->second.mutable_components;
	const auto existing = std::find_if(components.begin(), components.end(), [&](const MutableComponent &p_component) {
		return p_component.component_identifier == p_component_identifier;
	});
	if (existing == components.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE);
	}
	components.erase(existing);
	return ok_status();
}

Status InventoryRuntime::add_reference(ItemInstanceId p_item_id, ReferenceId &r_reference_id) {
	r_reference_id = ReferenceId{};
	if (items_.find(p_item_id) == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}
	if (references_.size() >= limits_.max_references) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, references_.size() + 1);
	}
	if (!has_headroom(active_reference_allocator(), 1)) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}

	const ReferenceId new_id = active_reference_allocator().allocate();
	references_.emplace(new_id, p_item_id);
	r_reference_id = new_id;
	return ok_status();
}

Status InventoryRuntime::remove_reference(ReferenceId p_reference_id) {
	const auto found = references_.find(p_reference_id);
	if (found == references_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_reference_id.value);
	}
	references_.erase(found);
	return ok_status();
}

std::uint64_t InventoryRuntime::commit_revision() {
	++revision_counter;
	return revision_counter;
}

Status InventoryRuntime::release_item_subtree(
		ItemInstanceId p_item_id,
		std::vector<ItemSubtreeEntry> &r_items,
		std::vector<ContainerSubtreeEntry> &r_containers,
		std::vector<ReferenceId> &r_cleared_references) {
	r_items.clear();
	r_containers.clear();
	r_cleared_references.clear();

	const auto found = items_.find(p_item_id);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item_id.value);
	}

	// Same cascade collection destroy_item() uses; r_items[0] is always the
	// root (collect_cascade()'s own convention).
	std::vector<ItemInstanceId> cascade_items;
	std::vector<ContainerInstanceId> cascade_containers;
	Status gather_status = collect_cascade(p_item_id, cascade_items, cascade_containers);
	if (!gather_status.ok()) {
		return gather_status;
	}

	std::vector<ItemSubtreeEntry> items_out;
	items_out.reserve(cascade_items.size());
	for (ItemInstanceId id : cascade_items) {
		const std::string *identifier = item_definition_identifier(items_.at(id).item_definition);
		if (identifier == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, id.value);
		}
		items_out.push_back(ItemSubtreeEntry{ items_.at(id), *identifier });
	}
	std::vector<ContainerSubtreeEntry> containers_out;
	containers_out.reserve(cascade_containers.size());
	for (ContainerInstanceId id : cascade_containers) {
		const std::string *identifier = container_definition_identifier(containers_.at(id).container_definition);
		if (identifier == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, id.value);
		}
		containers_out.push_back(ContainerSubtreeEntry{ containers_.at(id), *identifier });
	}

	const ItemLocation original_location = found->second.location;
	const bool was_list = std::holds_alternative<ListPlacement>(original_location);
	const ContainerInstanceId original_container = location_container(original_location);

	// Validation complete; mutate -- identical ordering to destroy_item()'s
	// cascade (references, then containers, then items) so nothing can
	// dangle even transiently.
	std::vector<ReferenceId> dangling;
	for (const auto &pair : references_) {
		for (ItemInstanceId cascaded : cascade_items) {
			if (pair.second == cascaded) {
				dangling.push_back(pair.first);
				break;
			}
		}
	}
	for (ReferenceId reference_id : dangling) {
		references_.erase(reference_id);
	}
	for (ContainerInstanceId container_id : cascade_containers) {
		containers_.erase(container_id);
	}
	for (ItemInstanceId item_id : cascade_items) {
		items_.erase(item_id);
	}

	if (was_list) {
		redensify_list(original_container);
	}

	r_items = std::move(items_out);
	r_containers = std::move(containers_out);
	r_cleared_references = std::move(dangling);
	return ok_status();
}

Status InventoryRuntime::adopt_item_subtree(
		const std::vector<ItemSubtreeEntry> &p_items,
		const std::vector<ContainerSubtreeEntry> &p_containers,
		const ItemLocation &p_destination_location) {
	if (catalog_ == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	if (p_items.empty()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	// Collision guard: authority-shared ids should never already be present
	// here (InventoryTransactionPipeline enforces shared-authority before
	// ever calling this), but a defensive check keeps this primitive
	// validate-then-mutate on its own terms.
	for (const ItemSubtreeEntry &entry : p_items) {
		if (items_.find(entry.instance.id) != items_.end()) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, entry.instance.id.value);
		}
	}
	for (const ContainerSubtreeEntry &entry : p_containers) {
		if (containers_.find(entry.instance.id) != containers_.end()) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, entry.instance.id.value);
		}
	}
	if (items_.size() + p_items.size() > limits_.max_items) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, items_.size() + p_items.size());
	}
	if (containers_.size() + p_containers.size() > limits_.max_containers) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, containers_.size() + p_containers.size());
	}

	const ItemInstance &root_instance = p_items[0].instance;
	const ItemDefinition *root_def = catalog_->find_item(p_items[0].definition_identifier);
	if (root_def == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_items[0].definition_identifier));
	}

	// Root placement: same discipline create_item() applies to a brand-new
	// item (geometry/overlap, slot/list rules, trait filters, per-container
	// item cap, and the target container's own nesting-depth bound).
	const ContainerInstance *target = nullptr;
	const ContainerDefinition *target_def = nullptr;
	Status placement_status = validate_placement(p_destination_location, ItemInstanceId{}, *root_def, target, target_def);
	if (!placement_status.ok()) {
		return placement_status;
	}
	Status nesting_status = validate_nesting_target(target->id, *target_def);
	if (!nesting_status.ok()) {
		return nesting_status;
	}

	// Resolve every transferred item/container definition once, both for
	// the depth walk below and for populating the destination's caches on
	// success.
	std::map<ContainerInstanceId, const ContainerDefinition *> container_defs;
	for (const ContainerSubtreeEntry &entry : p_containers) {
		const ContainerDefinition *def = catalog_->find_container(entry.definition_identifier);
		if (def == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(entry.definition_identifier));
		}
		container_defs.emplace(entry.instance.id, def);
	}
	std::map<ItemInstanceId, const ItemDefinition *> item_defs;
	std::map<ItemInstanceId, std::size_t> item_index;
	for (std::size_t i = 0; i < p_items.size(); ++i) {
		const ItemDefinition *def = catalog_->find_item(p_items[i].definition_identifier);
		if (def == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_items[i].definition_identifier));
		}
		item_defs.emplace(p_items[i].instance.id, def);
		item_index.emplace(p_items[i].instance.id, i);
	}

	// Subtree-wide nesting depth ("nesting incl. subtree depth at
	// destination", tasks.md 5.4), computed structurally from the transfer
	// set itself: provider_item/provided_containers chains never leave the
	// transferred set, so this needs no dependency on the source runtime
	// (which may already have released these records). The root item lands
	// at container_depth(target); each container it directly (or
	// transitively) provides is one level deeper than the item that
	// occupies it.
	std::map<ContainerInstanceId, std::vector<ItemInstanceId>> children_by_container;
	for (std::size_t i = 1; i < p_items.size(); ++i) {
		children_by_container[location_container(p_items[i].instance.location)].push_back(p_items[i].instance.id);
	}
	std::map<ItemInstanceId, std::uint32_t> item_depth;
	item_depth.emplace(root_instance.id, container_depth(target->id));
	std::vector<ItemInstanceId> frontier = { root_instance.id };
	const std::size_t hop_limit = p_items.size() + p_containers.size() + 2;
	std::size_t cursor = 0;
	while (cursor < frontier.size()) {
		if (frontier.size() > hop_limit) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, root_instance.id.value);
		}
		const ItemInstanceId current_item = frontier[cursor];
		++cursor;
		const auto index_it = item_index.find(current_item);
		if (index_it == item_index.end()) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, current_item.value);
		}
		const std::uint32_t base_depth = item_depth.at(current_item);
		for (ContainerInstanceId provided : p_items[index_it->second].instance.provided_containers) {
			const std::uint32_t child_depth = base_depth + 1;
			const auto def_it = container_defs.find(provided);
			if (def_it == container_defs.end()) {
				return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, provided.value);
			}
			if (!def_it->second->constraints.allow_nesting ||
					child_depth > def_it->second->constraints.max_nesting_depth ||
					child_depth > MAX_NESTING_DEPTH) {
				return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::NESTING_DEPTH_EXCEEDED, child_depth);
			}
			const auto children_it = children_by_container.find(provided);
			if (children_it != children_by_container.end()) {
				for (ItemInstanceId child_item : children_it->second) {
					item_depth[child_item] = child_depth;
					frontier.push_back(child_item);
				}
			}
		}
	}
	if (frontier.size() != p_items.size()) {
		// Every item handed to release_item_subtree() is reachable from its
		// root by construction (collect_cascade()); a mismatch here means
		// the caller assembled p_items/p_containers inconsistently.
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, root_instance.id.value);
	}

	// Validation complete; mutate: containers first (provider back-
	// references stay consistent even mid-insert), then items (root's
	// location overwritten; every other record verbatim) -- mirrors
	// create_item()'s "provided containers, then item" ordering.
	for (const ContainerSubtreeEntry &entry : p_containers) {
		containers_.emplace(entry.instance.id, entry.instance);
		container_definition_cache_.emplace(entry.instance.container_definition, container_defs.at(entry.instance.id));
	}
	for (const ItemSubtreeEntry &entry : p_items) {
		ItemInstance to_insert = entry.instance;
		if (to_insert.id == root_instance.id) {
			to_insert.location = p_destination_location;
		}
		items_.emplace(to_insert.id, to_insert);
		item_definition_cache_.emplace(to_insert.item_definition, item_defs.at(to_insert.id));
	}

	if (std::holds_alternative<ListPlacement>(p_destination_location)) {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_destination_location);
		apply_list_insert(list_placement.container, root_instance.id, list_placement.ordinal);
	}

	return ok_status();
}

// --- Replica raw record application (tasks.md 6.4) -------------------------
// See the doc comment on the declarations in inv_runtime_state.h for the
// deliberate absence of geometric/filter/nesting validation here.

Status InventoryRuntime::replica_apply_item_created(
		ItemInstanceId p_item,
		const std::string &p_item_definition_identifier,
		std::uint64_t p_quantity,
		const ItemLocation &p_location,
		std::vector<MutableComponent> p_mutable_components,
		std::vector<ContainerInstanceId> p_provided_containers) {
	if (catalog_ == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	if (!p_item) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (items_.find(p_item) != items_.end()) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, p_item.value);
	}
	if (items_.size() >= limits_.max_items) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, items_.size() + 1);
	}
	const ItemDefinition *def = catalog_->find_item(p_item_definition_identifier);
	if (def == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_item_definition_identifier));
	}
	if (p_mutable_components.size() > limits_.max_mutable_components_per_item) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_mutable_components.size());
	}
	if (p_provided_containers.size() > MAX_ITEM_PROVIDED_CONTAINERS) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_provided_containers.size());
	}

	ItemInstance instance;
	instance.id = p_item;
	instance.item_definition = catalog_->item_id(p_item_definition_identifier);
	instance.quantity = p_quantity;
	instance.location = p_location;
	instance.mutable_components = std::move(p_mutable_components);
	instance.provided_containers = std::move(p_provided_containers);
	item_definition_cache_.emplace(instance.item_definition, def);
	items_.emplace(p_item, std::move(instance));

	if (std::holds_alternative<ListPlacement>(p_location)) {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_location);
		apply_list_insert(list_placement.container, p_item, list_placement.ordinal);
	}

	if (p_item.value > active_item_allocator().next_raw()) {
		active_item_allocator().restore_from(p_item.value);
	}
	return ok_status();
}

Status InventoryRuntime::replica_apply_item_destroyed(ItemInstanceId p_item) {
	const auto found = items_.find(p_item);
	if (found == items_.end()) {
		return ok_status(); // Idempotent: every cascaded id in a subtree removal carries its own explicit op.
	}
	const ItemLocation original_location = found->second.location;
	const bool was_list = std::holds_alternative<ListPlacement>(original_location);
	const ContainerInstanceId original_container = location_container(original_location);
	items_.erase(found);
	if (was_list) {
		redensify_list(original_container);
	}
	return ok_status();
}

Status InventoryRuntime::replica_apply_item_moved(ItemInstanceId p_item, const ItemLocation &p_location) {
	const auto found = items_.find(p_item);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item.value);
	}
	const ItemLocation previous_location = found->second.location;
	const bool old_was_list = std::holds_alternative<ListPlacement>(previous_location);
	const ContainerInstanceId old_container = location_container(previous_location);

	if (std::holds_alternative<ListPlacement>(p_location)) {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_location);
		apply_list_insert(list_placement.container, p_item, list_placement.ordinal);
	} else {
		found->second.location = p_location;
	}

	if (old_was_list) {
		const ContainerInstanceId new_container = location_container(p_location);
		if (old_container != new_container || !std::holds_alternative<ListPlacement>(p_location)) {
			redensify_list(old_container);
		}
	}
	return ok_status();
}

Status InventoryRuntime::replica_apply_item_quantity(ItemInstanceId p_item, std::uint64_t p_quantity) {
	const auto found = items_.find(p_item);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item.value);
	}
	found->second.quantity = p_quantity;
	return ok_status();
}

Status InventoryRuntime::replica_apply_item_component_set(ItemInstanceId p_item, MutableComponent p_component) {
	const auto found = items_.find(p_item);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item.value);
	}
	std::vector<MutableComponent> &components = found->second.mutable_components;
	const auto existing = std::find_if(components.begin(), components.end(), [&](const MutableComponent &p_existing) {
		return p_existing.component_identifier == p_component.component_identifier;
	});
	if (existing != components.end()) {
		existing->payload = std::move(p_component.payload);
		return ok_status();
	}
	if (components.size() >= limits_.max_mutable_components_per_item) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, components.size() + 1);
	}
	const auto insert_at = std::lower_bound(components.begin(), components.end(), p_component,
			[](const MutableComponent &p_a, const MutableComponent &p_b) {
				return identifier_less(p_a.component_identifier, p_b.component_identifier);
			});
	components.insert(insert_at, std::move(p_component));
	return ok_status();
}

Status InventoryRuntime::replica_apply_item_component_removed(ItemInstanceId p_item, const std::string &p_component_identifier) {
	const auto found = items_.find(p_item);
	if (found == items_.end()) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_item.value);
	}
	std::vector<MutableComponent> &components = found->second.mutable_components;
	const auto existing = std::find_if(components.begin(), components.end(), [&](const MutableComponent &p_existing) {
		return p_existing.component_identifier == p_component_identifier;
	});
	if (existing == components.end()) {
		return ok_status(); // Idempotent, matching every other removal op above.
	}
	components.erase(existing);
	return ok_status();
}

Status InventoryRuntime::replica_apply_container_adopted(
		ContainerInstanceId p_container,
		const std::string &p_container_definition_identifier,
		ItemInstanceId p_provider_item) {
	if (catalog_ == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	if (!p_container) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (containers_.find(p_container) != containers_.end()) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, p_container.value);
	}
	if (containers_.size() >= limits_.max_containers) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, containers_.size() + 1);
	}
	const ContainerDefinition *def = catalog_->find_container(p_container_definition_identifier);
	if (def == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_container_definition_identifier));
	}
	ContainerInstance instance;
	instance.id = p_container;
	instance.container_definition = catalog_->container_id(p_container_definition_identifier);
	instance.provider_item = p_provider_item;
	container_definition_cache_.emplace(instance.container_definition, def);
	containers_.emplace(p_container, instance);
	if (p_container.value > active_container_allocator().next_raw()) {
		active_container_allocator().restore_from(p_container.value);
	}
	return ok_status();
}

Status InventoryRuntime::replica_apply_container_released(ContainerInstanceId p_container) {
	containers_.erase(p_container); // Idempotent regardless of prior presence.
	return ok_status();
}

Status InventoryRuntime::replica_apply_reference_assigned(ReferenceId p_reference, ItemInstanceId p_item) {
	if (!p_reference) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (references_.find(p_reference) != references_.end()) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, p_reference.value);
	}
	if (references_.size() >= limits_.max_references) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, references_.size() + 1);
	}
	references_.emplace(p_reference, p_item);
	if (p_reference.value > active_reference_allocator().next_raw()) {
		active_reference_allocator().restore_from(p_reference.value);
	}
	return ok_status();
}

Status InventoryRuntime::replica_apply_reference_cleared(ReferenceId p_reference) {
	references_.erase(p_reference); // Idempotent regardless of prior presence.
	return ok_status();
}

Status InventoryRuntime::validate_one_container(ContainerInstanceId p_container_id, const ContainerInstance &p_container) const {
	const ContainerDefinition *def = container_definition_of(p_container.container_definition);
	if (def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_container_id.value);
	}

	if (p_container.provider_item) {
		const ItemInstance *provider = find_item(p_container.provider_item);
		if (provider == nullptr) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, p_container_id.value);
		}
		const bool owns_back_reference = std::find(
				provider->provided_containers.begin(), provider->provided_containers.end(), p_container_id) !=
				provider->provided_containers.end();
		if (!owns_back_reference) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, p_container_id.value);
		}
	}

	const std::uint32_t depth = container_depth(p_container_id);
	if (depth == UINT32_MAX) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_container_id.value);
	}
	if (depth > 0 && (!def->constraints.allow_nesting || depth > def->constraints.max_nesting_depth || depth > MAX_NESTING_DEPTH)) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::NESTING_DEPTH_EXCEEDED, depth);
	}

	const std::vector<ItemInstanceId> members = items_in_container(p_container_id);
	const std::uint32_t cap = effective_container_item_cap(*def);
	if (members.size() > cap) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, members.size());
	}

	const OwnershipLayoutKind kind = layout_kind(def->layout);
	if (kind == OwnershipLayoutKind::SPATIAL_GRID) {
		const SpatialGridLayout &grid = std::get<SpatialGridLayout>(def->layout);
		std::vector<GridRect> rects;
		for (ItemInstanceId member_id : members) {
			const ItemInstance &member = items_.at(member_id);
			const SpatialPlacement *placement = std::get_if<SpatialPlacement>(&member.location);
			if (placement == nullptr) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::LAYOUT_INVALID, member_id.value);
			}
			const ItemDefinition *member_def = item_definition_of(member.item_definition);
			if (member_def == nullptr) {
				return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, member_id.value);
			}
			const GridRect rect = effective_footprint(placement->x, placement->y, member_def->footprint_width, member_def->footprint_height, placement->rotated);
			if (!grid_rect_in_bounds(rect, grid.width, grid.height)) {
				return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::PLACEMENT_OUT_OF_BOUNDS, member_id.value);
			}
			for (const GridRect &other : rects) {
				if (grid_rects_overlap(rect, other)) {
					return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::PLACEMENT_OVERLAP, member_id.value);
				}
			}
			rects.push_back(rect);
		}
	} else if (kind == OwnershipLayoutKind::NAMED_SLOTS) {
		const NamedSlotsLayout &named = std::get<NamedSlotsLayout>(def->layout);
		std::map<std::string, std::uint32_t> occupancy;
		for (ItemInstanceId member_id : members) {
			const ItemInstance &member = items_.at(member_id);
			const SlotPlacement *placement = std::get_if<SlotPlacement>(&member.location);
			if (placement == nullptr) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::LAYOUT_INVALID, member_id.value);
			}
			const NamedSlotDefinition *slot_def = nullptr;
			for (const NamedSlotDefinition &candidate : named.slots) {
				if (candidate.identifier == placement->slot_identifier) {
					slot_def = &candidate;
					break;
				}
			}
			if (slot_def == nullptr) {
				return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SLOT_UNKNOWN, member_id.value);
			}
			const ItemDefinition *member_def = item_definition_of(member.item_definition);
			if (member_def == nullptr) {
				return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, member_id.value);
			}
			Status filter_status = check_trait_filters(slot_def->required_traits, slot_def->blocked_traits, *member_def);
			if (!filter_status.ok()) {
				return filter_status;
			}
			const std::uint32_t next_count = ++occupancy[placement->slot_identifier];
			if (next_count > slot_def->max_items) {
				return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, next_count);
			}
		}
	} else {
		const OrderedListLayout &list_layout = std::get<OrderedListLayout>(def->layout);
		if (members.size() > list_layout.max_entries) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::LIST_CAPACITY_INVALID, members.size());
		}
		const std::vector<ItemInstanceId> ordered = list_items_by_ordinal(p_container_id);
		if (ordered.size() != members.size()) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::LAYOUT_INVALID, p_container_id.value);
		}
		for (std::uint32_t i = 0; i < ordered.size(); ++i) {
			const ListPlacement &placement = std::get<ListPlacement>(items_.at(ordered[i]).location);
			if (placement.ordinal != i) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::LIST_ORDINAL_INVALID, placement.ordinal);
			}
		}
	}

	for (ItemInstanceId member_id : members) {
		const ItemInstance &member = items_.at(member_id);
		const ItemDefinition *member_def = item_definition_of(member.item_definition);
		if (member_def == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, member_id.value);
		}
		Status filter_status = check_trait_filters(def->constraints.required_traits, def->constraints.blocked_traits, *member_def);
		if (!filter_status.ok()) {
			return filter_status;
		}
	}

	return ok_status();
}

Status InventoryRuntime::validate_one_item(ItemInstanceId p_item_id, const ItemInstance &p_item) const {
	const ItemDefinition *def = item_definition_of(p_item.item_definition);
	if (def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_item_id.value);
	}
	if (p_item.quantity < 1 || p_item.quantity > def->max_stack || p_item.quantity > MAX_STACK_QUANTITY) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, p_item.quantity);
	}
	if (p_item.mutable_components.size() > limits_.max_mutable_components_per_item) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_item.mutable_components.size());
	}
	for (std::size_t i = 0; i < p_item.mutable_components.size(); ++i) {
		if (p_item.mutable_components[i].payload.size() > MAX_TRAIT_PAYLOAD_BYTES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE, p_item.mutable_components[i].payload.size());
		}
		if (i > 0 && !identifier_less(p_item.mutable_components[i - 1].component_identifier, p_item.mutable_components[i].component_identifier)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CANONICAL_ORDER_VIOLATION, p_item_id.value);
		}
	}
	for (ContainerInstanceId provided_id : p_item.provided_containers) {
		const ContainerInstance *provided = find_container(provided_id);
		if (provided == nullptr || provided->provider_item != p_item_id) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, provided_id.value);
		}
	}
	return ok_status();
}

Status InventoryRuntime::validate_one_reference(ReferenceId p_reference_id, ItemInstanceId p_item_id) const {
	if (items_.find(p_item_id) == items_.end()) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, p_reference_id.value);
	}
	return ok_status();
}

Status InventoryRuntime::audit_invariants(std::vector<InvariantFinding> &r_findings, std::size_t p_max_findings) const {
	r_findings.clear();
	Status first_status = ok_status();
	bool have_first = false;

	// Records a violation for the return-value/first-finding bookkeeping
	// regardless of the cap, but only grows r_findings while there is still
	// room under p_max_findings -- so audit_invariants(findings, 0) still
	// reports whether *anything* is wrong (via the returned Status) without
	// ever storing a finding, and audit_invariants(findings, 1) always
	// behaves exactly like the old single-Status validate_invariants().
	auto record = [&](Status p_status, std::uint64_t p_container_raw, std::uint64_t p_item_raw, std::uint64_t p_reference_raw) {
		if (!have_first) {
			first_status = p_status;
			have_first = true;
		}
		if (r_findings.size() < p_max_findings) {
			r_findings.push_back(InvariantFinding{ p_status, p_container_raw, p_item_raw, p_reference_raw });
		}
	};

	if (items_.size() > limits_.max_items) {
		record(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, items_.size()), 0, 0, 0);
	}
	if (containers_.size() > limits_.max_containers) {
		record(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, containers_.size()), 0, 0, 0);
	}
	if (references_.size() > limits_.max_references) {
		record(make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, references_.size()), 0, 0, 0);
	}

	// containers_/items_/references_ are std::maps, so each loop below walks
	// its entities in canonical ascending-handle order; at most one finding
	// is recorded per entity (the first check that fails for it), then the
	// walk moves on to the next entity so a single corrupted entity can never
	// starve the audit of every other entity's findings.
	for (const auto &pair : containers_) {
		Status status = validate_one_container(pair.first, pair.second);
		if (!status.ok()) {
			record(status, pair.first.value, 0, 0);
		}
	}
	for (const auto &pair : items_) {
		Status status = validate_one_item(pair.first, pair.second);
		if (!status.ok()) {
			record(status, 0, pair.first.value, 0);
		}
	}
	for (const auto &pair : references_) {
		Status status = validate_one_reference(pair.first, pair.second);
		if (!status.ok()) {
			record(status, 0, 0, pair.first.value);
		}
	}

	return have_first ? first_status : ok_status();
}

Status InventoryRuntime::validate_invariants() const {
	std::vector<InvariantFinding> findings;
	return audit_invariants(findings, 1);
}

Status InventoryRuntime::restore_from_snapshot_parts(
		const DefinitionCatalog &p_catalog,
		DefinitionId p_profile_definition_id,
		const std::string &p_profile_identifier,
		const std::vector<std::string> &p_enabled_features,
		const InventoryLimitsDefinition &p_limits,
		InventoryId p_inventory_id,
		std::uint64_t p_revision,
		std::uint64_t p_container_allocator_next,
		std::uint64_t p_item_allocator_next,
		std::uint64_t p_reference_allocator_next,
		std::map<ContainerInstanceId, ContainerInstance> p_containers,
		std::map<ItemInstanceId, ItemInstance> p_items,
		std::map<ReferenceId, ItemInstanceId> p_references,
		std::map<DefinitionId, const ItemDefinition *> p_item_definition_cache,
		std::map<DefinitionId, const ContainerDefinition *> p_container_definition_cache,
		InventoryRuntime &r_runtime,
		IdentityAuthority *p_authority) {
	r_runtime = InventoryRuntime();

	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	if (!p_inventory_id) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	// containers_/items_/references_ are std::maps, so the greatest key
	// (if any) is always the last element; an allocator counter below that
	// maximum would let a future allocate() reissue an id already in use.
	const std::uint64_t max_container = p_containers.empty() ? 0 : p_containers.rbegin()->first.value;
	if (p_container_allocator_next < max_container) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CANONICAL_ORDER_VIOLATION, max_container);
	}
	const std::uint64_t max_item = p_items.empty() ? 0 : p_items.rbegin()->first.value;
	if (p_item_allocator_next < max_item) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CANONICAL_ORDER_VIOLATION, max_item);
	}
	const std::uint64_t max_reference = p_references.empty() ? 0 : p_references.rbegin()->first.value;
	if (p_reference_allocator_next < max_reference) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CANONICAL_ORDER_VIOLATION, max_reference);
	}

	InventoryRuntime candidate;
	candidate.catalog_ = &p_catalog;
	candidate.authority_ = p_authority;
	candidate.inventory_id = p_inventory_id;
	candidate.profile_definition_id = p_profile_definition_id;
	candidate.profile_identifier_ = p_profile_identifier;
	candidate.enabled_features_ = p_enabled_features;
	candidate.limits_ = p_limits;
	candidate.revision_counter = p_revision;

	const bool shared = p_authority != nullptr;
	Status status = restore_allocator_counter(candidate.active_container_allocator(), p_container_allocator_next, shared);
	if (!status.ok()) {
		return status;
	}
	status = restore_allocator_counter(candidate.active_item_allocator(), p_item_allocator_next, shared);
	if (!status.ok()) {
		return status;
	}
	status = restore_allocator_counter(candidate.active_reference_allocator(), p_reference_allocator_next, shared);
	if (!status.ok()) {
		return status;
	}

	candidate.containers_ = std::move(p_containers);
	candidate.items_ = std::move(p_items);
	candidate.references_ = std::move(p_references);
	candidate.item_definition_cache_ = std::move(p_item_definition_cache);
	candidate.container_definition_cache_ = std::move(p_container_definition_cache);

	r_runtime = std::move(candidate);
	return ok_status();
}

} // namespace inv
