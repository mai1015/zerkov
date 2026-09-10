#include "core/inv_transaction.h"

#include "core/inv_builtin_features.h"
#include "core/inv_checked_math.h"
#include "core/inv_hash.h"
#include "core/inv_identifier.h"

#include <algorithm>
#include <functional>
#include <map>
#include <set>
#include <type_traits>
#include <variant>

// Phase order (tasks.md 5.1; design.md "Transaction pipeline" steps 2-11 --
// step 1, decode, is a later protocol slice: commands here are already
// decoded value types, see inv_commands.h):
//
//   0. (pre-check) command_id nonzero, idempotency cache hit/conflict.
//   1. RESOLVE                - targeted identities exist and are in-scope.
//   2. IDENTITY/IDEMPOTENCY/REVISION - expected-revision shape + staleness
//      (the command_id/idempotency half of this step is step 0 above; see
//      the ambiguity note in submit()).
//   3. POLICY                 - PermissionProvider::check().
//   4. STRUCTURAL              - command-specific preconditions.
//   5. FEATURE/CONSTRAINT      - canonical order (tasks.md 5.8):
//      access -> filters -> count capacity -> mass capacity -> nesting ->
//      stack bounds -> protected retention (evaluated-but-neutral).
//   6. SIMULATE                - apply the mutation to a cloned runtime.
//   7. INVARIANT                - validate_invariants() on the clone.
//   8. COMMIT                  - swap the clone in, commit_revision() once.
//   9. RESULT/EVENTS            - build the TransactionResult.
//  10. NOTIFY                   - observers see the immutable result.
//
// Phases 1-5 are read-only against the caller's real InventoryRuntime; only
// phase 6 (on a clone) and phase 8 (swapping the validated clone in) ever
// touch storage, so a rejection at any phase 0-7 provably leaves
// p_inventory untouched.
namespace inv {

Status AllowAllPermissionProvider::check(const CommandHeader &, const Command &) const {
	return ok_status();
}

namespace {

// --- Definition lookups (bridges InventoryRuntime instances back to their
// catalog-owned ContainerDefinition/ItemDefinition; InventoryRuntime itself
// only caches these by DefinitionId internally, so the pipeline goes
// through the public identifier accessors instead of touching that cache).

const ContainerDefinition *container_definition_for(
		const InventoryRuntime &p_runtime,
		const DefinitionCatalog &p_catalog,
		ContainerInstanceId p_container) {
	const ContainerInstance *instance = p_runtime.find_container(p_container);
	if (instance == nullptr) {
		return nullptr;
	}
	const std::string *identifier = p_runtime.container_definition_identifier(instance->container_definition);
	if (identifier == nullptr) {
		return nullptr;
	}
	return p_catalog.find_container(*identifier);
}

const ItemDefinition *item_definition_for(
		const InventoryRuntime &p_runtime,
		const DefinitionCatalog &p_catalog,
		ItemInstanceId p_item) {
	const ItemInstance *instance = p_runtime.find_item(p_item);
	if (instance == nullptr) {
		return nullptr;
	}
	const std::string *identifier = p_runtime.item_definition_identifier(instance->item_definition);
	if (identifier == nullptr) {
		return nullptr;
	}
	return p_catalog.find_item(*identifier);
}

bool container_has_feature(const ContainerDefinition &p_def, const char *p_feature) {
	return std::find(p_def.enabled_features.begin(), p_def.enabled_features.end(), std::string(p_feature)) != p_def.enabled_features.end();
}

bool item_has_trait(const ItemDefinition &p_def, const std::string &p_trait) {
	for (const ItemTraitValue &trait : p_def.traits) {
		if (trait.trait_identifier == p_trait) {
			return true;
		}
	}
	return false;
}

// Mutable components are stored in canonical identifier order by
// InventoryRuntime. Until a game registers an explicit transformation
// policy, two stacks may coalesce only when that complete state is identical;
// otherwise merging would silently choose one instance's durability/ammo/etc.
bool mutable_component_state_matches(const ItemInstance &p_a, const ItemInstance &p_b) {
	if (p_a.mutable_components.size() != p_b.mutable_components.size()) {
		return false;
	}
	for (std::size_t i = 0; i < p_a.mutable_components.size(); ++i) {
		if (p_a.mutable_components[i].component_identifier != p_b.mutable_components[i].component_identifier ||
				p_a.mutable_components[i].payload != p_b.mutable_components[i].payload) {
			return false;
		}
	}
	return true;
}

// Coalescing destroys one item identity. An item that materially owns
// provided containers therefore cannot be folded into another stack: doing
// so would also destroy its container subtree and every nested item. There is
// no deterministic way to merge two independently owned subtrees, so this is
// fail-closed until an explicit game policy exists.
bool stack_state_can_coalesce(const ItemInstance &p_a, const ItemInstance &p_b) {
	return p_a.provided_containers.empty() &&
			p_b.provided_containers.empty() &&
			mutable_component_state_matches(p_a, p_b);
}

Status copy_mutable_component_state(
		const ItemInstance &p_source,
		InventoryRuntime &r_destination,
		ItemInstanceId p_destination_item) {
	for (const MutableComponent &component : p_source.mutable_components) {
		const Status status = r_destination.set_component(
				p_destination_item,
				component.component_identifier,
				component.payload);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

// Mirrors InventoryRuntime's private check_trait_filters() (core/
// inv_runtime_state.cpp): same status/diagnostic pair, reimplemented here
// because the pipeline needs it as an explicit, independently-orderable
// FEATURE-phase step (tasks.md 5.8) ahead of and independent from the
// primitive's own internal filter check at SIMULATE time.
Status check_trait_filters(
		const std::vector<std::string> &p_required,
		const std::vector<std::string> &p_blocked,
		const ItemDefinition &p_item_def) {
	for (const std::string &trait : p_required) {
		if (!item_has_trait(p_item_def, trait)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::FILTER_TRAIT_MISMATCH, hash_string(trait));
		}
	}
	for (const std::string &trait : p_blocked) {
		if (item_has_trait(p_item_def, trait)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::FILTER_TRAIT_MISMATCH, hash_string(trait));
		}
	}
	return ok_status();
}

const NamedSlotDefinition *find_slot(const ContainerDefinition &p_def, const std::string &p_slot_identifier) {
	if (const auto *named = std::get_if<NamedSlotsLayout>(&p_def.layout)) {
		for (const NamedSlotDefinition &slot : named->slots) {
			if (slot.identifier == p_slot_identifier) {
				return &slot;
			}
		}
	}
	return nullptr;
}

// --- FEATURE/CONSTRAINT canonical-order sub-checks (tasks.md 5.8) ---------

Status check_access(const ContainerDefinition &p_def, AccessFlag p_flag) {
	if ((p_def.constraints.access_mask & static_cast<std::uint8_t>(p_flag)) == 0) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::ACCESS_DENIED, static_cast<std::uint64_t>(p_flag));
	}
	return ok_status();
}

// Container-level filters always apply; slot-level filters additionally
// apply when p_location names a NAMED_SLOTS slot the container declares
// (matches InventoryRuntime::validate_placement()'s own slot-then-container
// filter order). An unrecognized slot identifier is left to SIMULATE
// (SLOT_UNKNOWN) rather than duplicated here.
Status check_destination_filters(
		const ContainerDefinition &p_container_def,
		const ItemDefinition &p_item_def,
		const ItemLocation &p_location) {
	if (const SlotPlacement *slot = std::get_if<SlotPlacement>(&p_location)) {
		const NamedSlotDefinition *slot_def = find_slot(p_container_def, slot->slot_identifier);
		if (slot_def != nullptr) {
			Status slot_status = check_trait_filters(slot_def->required_traits, slot_def->blocked_traits, p_item_def);
			if (!slot_status.ok()) {
				return slot_status;
			}
		}
	}
	return check_trait_filters(p_container_def.constraints.required_traits, p_container_def.constraints.blocked_traits, p_item_def);
}

// Always enforced (mirrors InventoryRuntime::effective_container_item_cap());
// unlike mass capacity this is never feature-gated -- the primitives already
// enforce it unconditionally at SIMULATE time, so skipping it here would
// just delay (not avoid) the rejection and lose the canonical-order
// guarantee tasks.md 5.8 requires when combined with another violation.
Status check_count_capacity(const ContainerDefinition &p_def, const InventoryLimitsDefinition &p_limits, std::uint32_t p_projected_count) {
	const std::uint32_t cap = p_def.constraints.max_items != 0 ? p_def.constraints.max_items : p_limits.max_items;
	if (p_projected_count > cap) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_projected_count);
	}
	return ok_status();
}

// Feature-gated (container declares has_mass_capacity AND the profile
// enables inventory.feature.mass_capacity, mirroring container_mass_
// capacity()'s own discipline): FEATURE_UNSUPPORTED means "not applicable
// here", not a violation.
Status check_mass_capacity(const InventoryRuntime &p_runtime, ContainerInstanceId p_container, std::int64_t p_projected_mg) {
	std::int64_t capacity = 0;
	Status status = p_runtime.container_mass_capacity(p_container, capacity);
	if (status.code == StatusCode::FEATURE_UNSUPPORTED) {
		return ok_status();
	}
	if (!status.ok()) {
		return status;
	}
	if (p_projected_mg > capacity) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::MASS_CAPACITY_EXCEEDED, static_cast<std::uint64_t>(p_projected_mg));
	}
	return ok_status();
}

// Mirrors InventoryRuntime's private validate_nesting_target().
Status check_nesting(const InventoryRuntime &p_runtime, ContainerInstanceId p_container, const ContainerDefinition &p_def) {
	const std::uint32_t depth = p_runtime.container_depth(p_container);
	if (depth == UINT32_MAX) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_container.value);
	}
	if (depth > 0 && (!p_def.constraints.allow_nesting || depth > p_def.constraints.max_nesting_depth || depth > MAX_NESTING_DEPTH)) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::NESTING_DEPTH_EXCEEDED, depth);
	}
	return ok_status();
}

// Evaluated-but-neutral for this slice (design.md: the core "does not infer
// why the settlement occurred" / "does not decide ... retention policy
// itself"): the classification is read so a later settlement slice (5.5)
// has one already-wired evaluation point in the canonical order, but
// nothing here ever rejects on it.
Status check_retention(const ContainerDefinition &p_def) {
	(void)p_def.constraints.retention;
	return ok_status();
}

// Shared FEATURE-phase evaluation for "one item moves from wherever it is
// now into p_destination": MoveItemCommand, RotateItemCommand (destination
// == current location), EquipItemCommand, and UnequipItemCommand all reduce
// to this. access is MOVE when the destination container equals the
// item's current container, else REMOVE(source) then INSERT(dest); count
// and mass are only evaluated when crossing containers (an in-place
// move/rotate changes neither).
Status evaluate_move_like(
		const InventoryRuntime &p_inventory,
		const DefinitionCatalog &p_catalog,
		ItemInstanceId p_item,
		const ItemLocation &p_destination) {
	const ItemInstance *item = p_inventory.find_item(p_item);
	const ItemDefinition *item_def = item_definition_for(p_inventory, p_catalog, p_item);
	if (item == nullptr || item_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const ContainerInstanceId source_container = location_container(item->location);
	const ContainerInstanceId dest_container = location_container(p_destination);
	const ContainerDefinition *source_def = container_definition_for(p_inventory, p_catalog, source_container);
	const ContainerDefinition *dest_def = container_definition_for(p_inventory, p_catalog, dest_container);
	if (source_def == nullptr || dest_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const bool same_container = source_container == dest_container;

	// ACCESS
	Status status = same_container ? check_access(*dest_def, AccessFlag::MOVE) : check_access(*source_def, AccessFlag::REMOVE);
	if (!status.ok()) {
		return status;
	}
	if (!same_container) {
		status = check_access(*dest_def, AccessFlag::INSERT);
		if (!status.ok()) {
			return status;
		}
	}

	// FILTERS
	status = check_destination_filters(*dest_def, *item_def, p_destination);
	if (!status.ok()) {
		return status;
	}

	// COUNT + MASS (only when the item is genuinely arriving at a new
	// container; an in-place move/rotate changes neither).
	if (!same_container) {
		std::uint32_t count = 0;
		p_inventory.count_in_container(dest_container, count);
		status = check_count_capacity(*dest_def, p_inventory.limits(), count + 1);
		if (!status.ok()) {
			return status;
		}

		std::int64_t item_mass = 0;
		status = p_inventory.item_subtree_mass(p_item, item_mass);
		if (!status.ok()) {
			return status;
		}
		std::int64_t dest_mass = 0;
		status = p_inventory.container_mass(dest_container, dest_mass);
		if (!status.ok()) {
			return status;
		}
		std::int64_t projected = 0;
		status = checked_add_i64(dest_mass, item_mass, projected);
		if (!status.ok()) {
			return status;
		}
		status = check_mass_capacity(p_inventory, dest_container, projected);
		if (!status.ok()) {
			return status;
		}
	}

	// NESTING
	status = check_nesting(p_inventory, dest_container, *dest_def);
	if (!status.ok()) {
		return status;
	}
	// STACK BOUNDS: n/a (quantity does not change).
	// RETENTION
	return check_retention(*dest_def);
}

// Shared FEATURE-phase evaluation for "a brand-new item instance arrives at
// p_destination" (InsertItemCommand). SplitStackCommand is deliberately NOT
// routed through this helper: its mass check must be skipped when the new
// stack lands in the SAME container as the still-present source item (the
// container's total mass is unchanged by a split, since the item being
// split typically has no provided containers of its own -- see
// inv_transaction.cpp's SplitStackCommand branch for the full reasoning),
// whereas InsertItemCommand's destination never has a "source" to conserve
// mass with.
Status evaluate_arrival(
		const InventoryRuntime &p_inventory,
		const DefinitionCatalog &p_catalog,
		const ItemDefinition &p_item_def,
		const ItemLocation &p_destination,
		std::uint64_t p_quantity) {
	const ContainerInstanceId dest_container = location_container(p_destination);
	const ContainerDefinition *dest_def = container_definition_for(p_inventory, p_catalog, dest_container);
	if (dest_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}

	Status status = check_access(*dest_def, AccessFlag::INSERT);
	if (!status.ok()) {
		return status;
	}
	status = check_destination_filters(*dest_def, p_item_def, p_destination);
	if (!status.ok()) {
		return status;
	}

	std::uint32_t count = 0;
	p_inventory.count_in_container(dest_container, count);
	status = check_count_capacity(*dest_def, p_inventory.limits(), count + 1);
	if (!status.ok()) {
		return status;
	}

	std::int64_t new_mass = 0;
	status = checked_mul_i64(p_item_def.unit_mass_mg, static_cast<std::int64_t>(p_quantity), new_mass);
	if (!status.ok()) {
		return status;
	}
	std::int64_t dest_mass = 0;
	status = p_inventory.container_mass(dest_container, dest_mass);
	if (!status.ok()) {
		return status;
	}
	std::int64_t projected = 0;
	status = checked_add_i64(dest_mass, new_mass, projected);
	if (!status.ok()) {
		return status;
	}
	status = check_mass_capacity(p_inventory, dest_container, projected);
	if (!status.ok()) {
		return status;
	}

	status = check_nesting(p_inventory, dest_container, *dest_def);
	if (!status.ok()) {
		return status;
	}
	return check_retention(*dest_def);
}

// SwapItemsCommand's FEATURE-phase evaluation. Unlike a move, a swap never
// changes either container's occupant COUNT (one item leaves, one arrives,
// net zero -- always true, same container or not), so count capacity is
// never evaluated. Mass CAN change per container (the two items may have
// different mass), so each container's projected total is computed as
// current - outgoing + incoming rather than the arrival-style "current +
// added" a plain move/insert uses.
Status evaluate_swap(
		const InventoryRuntime &p_inventory,
		const DefinitionCatalog &p_catalog,
		ItemInstanceId p_item_a,
		ItemInstanceId p_item_b) {
	const ItemInstance *item_a = p_inventory.find_item(p_item_a);
	const ItemInstance *item_b = p_inventory.find_item(p_item_b);
	const ItemDefinition *def_a = item_definition_for(p_inventory, p_catalog, p_item_a);
	const ItemDefinition *def_b = item_definition_for(p_inventory, p_catalog, p_item_b);
	if (item_a == nullptr || item_b == nullptr || def_a == nullptr || def_b == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const ContainerInstanceId container_a = location_container(item_a->location);
	const ContainerInstanceId container_b = location_container(item_b->location);
	const ContainerDefinition *def_container_a = container_definition_for(p_inventory, p_catalog, container_a);
	const ContainerDefinition *def_container_b = container_definition_for(p_inventory, p_catalog, container_b);
	if (def_container_a == nullptr || def_container_b == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const bool same_container = container_a == container_b;

	// ACCESS
	Status status;
	if (same_container) {
		status = check_access(*def_container_a, AccessFlag::MOVE);
		if (!status.ok()) {
			return status;
		}
	} else {
		status = check_access(*def_container_a, AccessFlag::REMOVE); // item_a leaving A
		if (!status.ok()) {
			return status;
		}
		status = check_access(*def_container_b, AccessFlag::INSERT); // item_a arriving at B
		if (!status.ok()) {
			return status;
		}
		status = check_access(*def_container_b, AccessFlag::REMOVE); // item_b leaving B
		if (!status.ok()) {
			return status;
		}
		status = check_access(*def_container_a, AccessFlag::INSERT); // item_b arriving at A
		if (!status.ok()) {
			return status;
		}
	}

	// FILTERS
	status = check_destination_filters(*def_container_b, *def_a, item_b->location); // item_a -> item_b's old location
	if (!status.ok()) {
		return status;
	}
	status = check_destination_filters(*def_container_a, *def_b, item_a->location); // item_b -> item_a's old location
	if (!status.ok()) {
		return status;
	}

	// COUNT: never evaluated (net zero for every container, always).

	// MASS
	if (!same_container) {
		std::int64_t mass_a = 0;
		std::int64_t mass_b = 0;
		status = p_inventory.item_subtree_mass(p_item_a, mass_a);
		if (!status.ok()) {
			return status;
		}
		status = p_inventory.item_subtree_mass(p_item_b, mass_b);
		if (!status.ok()) {
			return status;
		}
		std::int64_t current_a = 0;
		std::int64_t current_b = 0;
		status = p_inventory.container_mass(container_a, current_a);
		if (!status.ok()) {
			return status;
		}
		status = p_inventory.container_mass(container_b, current_b);
		if (!status.ok()) {
			return status;
		}

		std::int64_t projected_b = 0;
		status = checked_sub_i64(current_b, mass_b, projected_b);
		if (!status.ok()) {
			return status;
		}
		status = checked_add_i64(projected_b, mass_a, projected_b);
		if (!status.ok()) {
			return status;
		}
		status = check_mass_capacity(p_inventory, container_b, projected_b);
		if (!status.ok()) {
			return status;
		}

		std::int64_t projected_a = 0;
		status = checked_sub_i64(current_a, mass_a, projected_a);
		if (!status.ok()) {
			return status;
		}
		status = checked_add_i64(projected_a, mass_b, projected_a);
		if (!status.ok()) {
			return status;
		}
		status = check_mass_capacity(p_inventory, container_a, projected_a);
		if (!status.ok()) {
			return status;
		}
	}

	// NESTING (both destinations, always).
	status = check_nesting(p_inventory, container_b, *def_container_b);
	if (!status.ok()) {
		return status;
	}
	status = check_nesting(p_inventory, container_a, *def_container_a);
	if (!status.ok()) {
		return status;
	}

	// STACK BOUNDS: n/a (no quantity change).
	// RETENTION
	status = check_retention(*def_container_a);
	if (!status.ok()) {
		return status;
	}
	return check_retention(*def_container_b);
}

// --- 5.3 deterministic candidate search ------------------------------------
//
// Shared candidate-container/cell enumeration for AutoPlaceItemCommand and
// QuickTransferItemCommand's remainder placement (tasks.md 5.3's documented
// order, verbatim in inv_commands.h's AutoPlaceItemCommand/
// QuickTransferItemCommand doc comments): profile root containers of
// p_inventory, in canonical (sorted definition-identifier) order, that
// declare allow_auto_placement, THEN every other container that also
// declares allow_auto_placement, in ascending ContainerInstanceId order
// (std::map iteration order); p_container_filter, when valid, replaces the
// whole walk with exactly that one container. Within a candidate: p_test is
// invoked for each candidate ItemLocation in the documented per-layout
// order (SPATIAL_GRID: unrotated then rotated, row-major; NAMED_SLOTS:
// declared slot order; ORDERED_LIST: append-at-end, one candidate) and the
// first one p_test accepts wins. Deterministic: p_inventory/p_catalog are
// never mutated by this walk, so identical inputs always visit candidates
// in the identical order and return the identical result.
Status search_auto_place_candidates(
		const InventoryRuntime &p_inventory,
		const DefinitionCatalog &p_catalog,
		const ItemDefinition &p_item_def,
		ContainerInstanceId p_container_filter,
		const std::vector<ContainerInstanceId> *p_container_scope,
		const std::function<bool(const ItemLocation &)> &p_test,
		ItemLocation &r_candidate) {
	std::vector<ContainerInstanceId> candidates;
	if (p_container_scope != nullptr) {
		candidates = *p_container_scope;
	} else if (p_container_filter) {
		if (p_inventory.find_container(p_container_filter) == nullptr) {
			return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_container_filter.value);
		}
		candidates.push_back(p_container_filter);
	} else {
		std::vector<std::pair<std::string, ContainerInstanceId>> root_candidates;
		for (ContainerInstanceId root : p_inventory.root_containers()) {
			const ContainerDefinition *def = container_definition_for(p_inventory, p_catalog, root);
			if (def != nullptr && def->constraints.allow_auto_placement) {
				root_candidates.emplace_back(def->identifier, root);
			}
		}
		std::sort(root_candidates.begin(), root_candidates.end(), [](const auto &p_a, const auto &p_b) {
			return identifier_less(p_a.first, p_b.first);
		});
		for (const auto &entry : root_candidates) {
			candidates.push_back(entry.second);
		}
		for (const auto &pair : p_inventory.containers()) {
			if (!pair.second.provider_item) {
				continue; // root containers already added above, in definition-identifier order.
			}
			const ContainerDefinition *def = container_definition_for(p_inventory, p_catalog, pair.first);
			if (def != nullptr && def->constraints.allow_auto_placement) {
				candidates.push_back(pair.first);
			}
		}
	}

	for (ContainerInstanceId container_id : candidates) {
		const ContainerDefinition *def = container_definition_for(p_inventory, p_catalog, container_id);
		if (def == nullptr) {
			continue;
		}
		const OwnershipLayoutKind kind = layout_kind(def->layout);
		if (kind == OwnershipLayoutKind::SPATIAL_GRID) {
			const SpatialGridLayout &grid = std::get<SpatialGridLayout>(def->layout);
			for (bool rotated : { false, true }) {
				if (rotated && (!p_item_def.allow_rotation || !grid.allow_rotation)) {
					continue;
				}
				for (std::uint32_t y = 0; y < grid.height; ++y) {
					for (std::uint32_t x = 0; x < grid.width; ++x) {
						SpatialPlacement candidate{ container_id, x, y, rotated };
						if (p_test(candidate)) {
							r_candidate = candidate;
							return ok_status();
						}
					}
				}
			}
		} else if (kind == OwnershipLayoutKind::NAMED_SLOTS) {
			const NamedSlotsLayout &named = std::get<NamedSlotsLayout>(def->layout);
			for (const NamedSlotDefinition &slot : named.slots) {
				SlotPlacement candidate{ container_id, slot.identifier };
				if (p_test(candidate)) {
					r_candidate = candidate;
					return ok_status();
				}
			}
		} else {
			std::uint32_t count = 0;
			p_inventory.count_in_container(container_id, count);
			ListPlacement candidate{ container_id, count };
			if (p_test(candidate)) {
				r_candidate = candidate;
				return ok_status();
			}
		}
	}
	return make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::PLACEMENT_CANDIDATE_EXHAUSTED, p_item_def.footprint_width);
}

// AutoPlaceItemCommand candidate test: the item already lives somewhere in
// p_inventory and is being reorganized within it, so this is exactly a
// MoveItemCommand-shaped evaluation (fits() for geometry/filters/count/
// nesting, evaluate_move_like() for access/mass) against p_item's OWN
// current identity (fits()/evaluate_move_like() exclude its own prior
// placement).
Status find_reorganize_candidate(
		const InventoryRuntime &p_inventory,
		const DefinitionCatalog &p_catalog,
		ItemInstanceId p_item,
		ContainerInstanceId p_container_filter,
		ItemLocation &r_candidate) {
	const ItemInstance *item = p_inventory.find_item(p_item);
	const ItemDefinition *item_def = item_definition_for(p_inventory, p_catalog, p_item);
	if (item == nullptr || item_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const std::function<bool(const ItemLocation &)> test = [&](const ItemLocation &p_candidate) {
		return p_inventory.fits(item_def->identifier, p_candidate, item->quantity, p_item).ok() &&
				evaluate_move_like(p_inventory, p_catalog, p_item, p_candidate).ok();
	};
	return search_auto_place_candidates(p_inventory, p_catalog, *item_def, p_container_filter, nullptr, test, r_candidate);
}

// QuickTransferItemCommand's cross-inventory placement candidate test: the
// item does not exist in p_inventory yet (it is arriving fresh, either as a
// brand-new split-off instance or as a whole verbatim subtree transfer), so
// this mirrors evaluate_arrival()'s access/mass discipline (unconditional
// INSERT + mass-capacity growth, since there is no "already here" case)
// combined with fits() for geometry/filters/count/nesting.
Status find_arrival_candidate(
		const InventoryRuntime &p_inventory,
		const DefinitionCatalog &p_catalog,
		const ItemDefinition &p_item_def,
		std::uint64_t p_quantity,
		ContainerInstanceId p_container_filter,
		ItemLocation &r_candidate) {
	const std::function<bool(const ItemLocation &)> test = [&](const ItemLocation &p_candidate) {
		if (!p_inventory.fits(p_item_def.identifier, p_candidate, p_quantity, ItemInstanceId{}).ok()) {
			return false;
		}
		const ContainerInstanceId dest_container = location_container(p_candidate);
		const ContainerDefinition *dest_def = container_definition_for(p_inventory, p_catalog, dest_container);
		if (dest_def == nullptr || !check_access(*dest_def, AccessFlag::INSERT).ok()) {
			return false;
		}
		std::int64_t new_mass = 0;
		if (!checked_mul_i64(p_item_def.unit_mass_mg, static_cast<std::int64_t>(p_quantity), new_mass).ok()) {
			return false;
		}
		std::int64_t dest_mass = 0;
		if (!p_inventory.container_mass(dest_container, dest_mass).ok()) {
			return false;
		}
		std::int64_t projected = 0;
		if (!checked_add_i64(dest_mass, new_mass, projected).ok()) {
			return false;
		}
		return check_mass_capacity(p_inventory, dest_container, projected).ok();
	};
	return search_auto_place_candidates(p_inventory, p_catalog, p_item_def, p_container_filter, nullptr, test, r_candidate);
}

// --- Delta-op builders (tasks.md 5.1 DELTA-EMISSION phase; core/
// inv_deltas.h) --------------------------------------------------------
//
// Every helper below reads p_clone's state AFTER the mutation it describes
// has already happened (or, for a subtree release/adoption, the
// ItemSubtreeEntry/ContainerSubtreeEntry vectors release_item_subtree()
// already captured immediately before removing them), so every emitted op
// carries a complete after-state value -- never a diff -- matching
// core/inv_deltas.h's contract.

ItemCreatedOp make_item_created_op(const ItemInstance &p_instance, const std::string &p_definition_identifier) {
	ItemCreatedOp op;
	op.item = p_instance.id.value;
	op.item_definition_identifier = p_definition_identifier;
	op.quantity = p_instance.quantity;
	op.location = to_snapshot_location(p_instance.location);
	op.mutable_components.reserve(p_instance.mutable_components.size());
	for (const MutableComponent &component : p_instance.mutable_components) {
		op.mutable_components.push_back(SnapshotMutableComponent{ component.component_identifier, component.payload });
	}
	op.provided_containers.reserve(p_instance.provided_containers.size());
	for (ContainerInstanceId provided : p_instance.provided_containers) {
		op.provided_containers.push_back(provided.value);
	}
	return op;
}

ContainerAdoptedOp make_container_adopted_op(const ContainerInstance &p_instance, const std::string &p_definition_identifier) {
	ContainerAdoptedOp op;
	op.container = p_instance.id.value;
	op.container_definition_identifier = p_definition_identifier;
	op.provider_item = p_instance.provider_item.value;
	return op;
}

// Appends ITEM_CREATED for p_item (looked up live in p_clone, so it reflects
// every mutation -- including SplitStackCommand's inherited-component copy
// -- the caller wants captured) plus CONTAINER_ADOPTED for every container
// p_item provides, in ItemInstance::provided_containers' own ascending
// order. Used for a genuinely new item (InsertItemCommand/SplitStackCommand)
// -- never for subtree adoption, which uses append_subtree_created() below
// (the subtree's already-captured entries, not a live p_clone lookup, since
// the source runtime that captured them may differ from the destination
// p_clone).
void append_item_created(const InventoryRuntime &p_clone, ItemInstanceId p_item, std::vector<DeltaOp> &r_ops) {
	const ItemInstance *instance = p_clone.find_item(p_item);
	if (instance == nullptr) {
		return; // defensive; every caller invokes this right after a successful create_item().
	}
	const std::string *identifier = p_clone.item_definition_identifier(instance->item_definition);
	r_ops.push_back(DeltaOp{ make_item_created_op(*instance, identifier != nullptr ? *identifier : std::string()) });
	for (ContainerInstanceId provided : instance->provided_containers) {
		const ContainerInstance *container = p_clone.find_container(provided);
		if (container == nullptr) {
			continue;
		}
		const std::string *container_identifier = p_clone.container_definition_identifier(container->container_definition);
		r_ops.push_back(DeltaOp{ make_container_adopted_op(*container, container_identifier != nullptr ? *container_identifier : std::string()) });
	}
}

// Appends ITEM_MOVED for p_item's CURRENT (post-move) location in p_clone.
void append_item_moved(const InventoryRuntime &p_clone, ItemInstanceId p_item, std::vector<DeltaOp> &r_ops) {
	const ItemInstance *instance = p_clone.find_item(p_item);
	if (instance == nullptr) {
		return;
	}
	r_ops.push_back(DeltaOp{ ItemMovedOp{ p_item.value, to_snapshot_location(instance->location) } });
}

// Appends ITEM_CREATED/CONTAINER_ADOPTED for a whole adopted subtree (loot/
// quick-transfer/settlement-transfer destination side): root item first
// (its location overridden to p_destination_location, matching
// adopt_item_subtree()'s own root-placement contract) then every descendant
// item at its unchanged relative location, then every subtree container --
// exactly p_items'/p_containers' own root-first order (release_item_subtree(
// )'s/collect_cascade()'s convention), which adopt_item_subtree() also
// consumes unchanged.
void append_subtree_created(
		const std::vector<ItemSubtreeEntry> &p_items,
		const std::vector<ContainerSubtreeEntry> &p_containers,
		const ItemLocation &p_destination_location,
		std::vector<DeltaOp> &r_ops) {
	for (std::size_t i = 0; i < p_items.size(); ++i) {
		ItemCreatedOp op = make_item_created_op(p_items[i].instance, p_items[i].definition_identifier);
		if (i == 0) {
			op.location = to_snapshot_location(p_destination_location);
		}
		r_ops.push_back(DeltaOp{ std::move(op) });
	}
	for (const ContainerSubtreeEntry &entry : p_containers) {
		r_ops.push_back(DeltaOp{ make_container_adopted_op(entry.instance, entry.definition_identifier) });
	}
}

// Appends ITEM_DESTROYED for every subtree item (root first, p_items' own
// order), then CONTAINER_RELEASED for every subtree container, then
// REFERENCE_CLEARED for every reference release_item_subtree() cascaded
// away. Used for BOTH a same-inventory destroy (RemoveItemCommand, a merge's
// consumed source, a fully-consumed quick-transfer source) and the source
// side of a cross-inventory subtree transfer (loot/drop/settlement) --
// release_item_subtree() is now the one primitive every subtree-capable
// removal in this file goes through, so this helper has one shape.
void append_subtree_released(
		const std::vector<ItemSubtreeEntry> &p_items,
		const std::vector<ContainerSubtreeEntry> &p_containers,
		const std::vector<ReferenceId> &p_cleared_references,
		std::vector<DeltaOp> &r_ops) {
	for (const ItemSubtreeEntry &entry : p_items) {
		r_ops.push_back(DeltaOp{ ItemDestroyedOp{ entry.instance.id.value } });
	}
	for (const ContainerSubtreeEntry &entry : p_containers) {
		r_ops.push_back(DeltaOp{ ContainerReleasedOp{ entry.instance.id.value } });
	}
	for (ReferenceId reference : p_cleared_references) {
		r_ops.push_back(DeltaOp{ ReferenceClearedOp{ reference.value } });
	}
}

// --- Command-bucket split (tasks.md 5.4/5.9) --------------------------------
//
// True for the four command types that can name more than one InventoryId
// and are dispatched through dispatch_multi(); false for every other
// Command alternative (the original nine, plus AutoPlaceItemCommand/
// AssignReferenceCommand/ClearReferenceCommand/DropItemCommand, all of
// which only ever touch one runtime and go through dispatch_single()).
bool is_multi_inventory_command(const Command &p_command) {
	return std::holds_alternative<LootItemCommand>(p_command) ||
			std::holds_alternative<SettleInventoryCommand>(p_command) ||
			std::holds_alternative<QuickTransferItemCommand>(p_command) ||
			std::holds_alternative<TargetedProviderTransferCommand>(p_command);
}

} // namespace

InventoryTransactionPipeline::InventoryTransactionPipeline(
		const DefinitionCatalog &p_catalog,
		const PermissionProvider &p_permissions,
		const ExternalMetricProvider *p_metrics,
		std::size_t p_idempotency_capacity,
		const PreparedQuantityReservations *p_quantity_reservations) :
		catalog_(&p_catalog),
		permissions_(&p_permissions),
		metrics_(p_metrics),
		quantity_reservations_(p_quantity_reservations),
		idempotency_capacity_(p_idempotency_capacity) {
}

// --- POLICY-phase companion: game-owned external metrics (tasks.md 6.6) ---

Status InventoryTransactionPipeline::check_external_metrics(const CommandHeader &p_header) const {
	if (metrics_ == nullptr) {
		return ok_status();
	}
	std::int64_t value = 0;
	return metrics_->fixed_value(hash_string(EXTERNAL_METRIC_MASS_CAPACITY_BONUS), p_header, value);
}

void InventoryTransactionPipeline::add_observer(std::uint64_t p_owner_key, Observer p_observer) {
	for (auto &entry : observers_) {
		if (entry.first == p_owner_key) {
			entry.second = std::move(p_observer);
			return;
		}
	}
	observers_.emplace_back(p_owner_key, std::move(p_observer));
}

void InventoryTransactionPipeline::remove_observer(std::uint64_t p_owner_key) {
	observers_.erase(
			std::remove_if(observers_.begin(), observers_.end(), [&](const std::pair<std::uint64_t, Observer> &p_entry) {
				return p_entry.first == p_owner_key;
			}),
			observers_.end());
}

std::size_t InventoryTransactionPipeline::invalidate_idempotency_for_inventory(InventoryId p_inventory) {
	if (!p_inventory) {
		return 0;
	}

	std::size_t removed = 0;
	for (auto order_it = idempotency_order_.begin(); order_it != idempotency_order_.end();) {
		const auto record_it = idempotency_index_.find(*order_it);
		if (record_it == idempotency_index_.end()) {
			// Keep the two bounded journal structures self-healing if a future
			// edit ever leaves an orphaned FIFO entry behind.
			order_it = idempotency_order_.erase(order_it);
			continue;
		}

		const bool touches_inventory = std::any_of(
				record_it->second.result.revisions.begin(),
				record_it->second.result.revisions.end(),
				[&](const RevisionOutcome &p_revision) {
					return p_revision.inventory == p_inventory;
				});
		if (!touches_inventory) {
			++order_it;
			continue;
		}

		idempotency_index_.erase(record_it);
		order_it = idempotency_order_.erase(order_it);
		++removed;
	}
	return removed;
}

void InventoryTransactionPipeline::notify(const TransactionResult &p_result) const {
	for (const auto &entry : observers_) {
		if (entry.second) {
			entry.second(p_result);
		}
	}
}

void InventoryTransactionPipeline::record_idempotency(CommandId p_command_id, std::uint64_t p_payload_fingerprint, const TransactionResult &p_result) {
	if (idempotency_capacity_ == 0) {
		return;
	}
	// FIFO eviction by acceptance order: idempotency_order_ holds command
	// ids in the order they were first recorded, so the front is always the
	// oldest surviving accepted command regardless of numeric CommandId
	// order.
	while (idempotency_index_.size() >= idempotency_capacity_ && !idempotency_order_.empty()) {
		const CommandId oldest = idempotency_order_.front();
		idempotency_order_.pop_front();
		idempotency_index_.erase(oldest);
	}
	idempotency_index_[p_command_id] = IdempotencyRecord{ p_payload_fingerprint, p_result };
	idempotency_order_.push_back(p_command_id);
}

// --- Phase 1: RESOLVE ------------------------------------------------------

Status InventoryTransactionPipeline::resolve(const InventoryRuntime &p_inventory, const Command &p_command) const {
	return std::visit(
			[&](const auto &p_body) -> Status {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, MoveItemCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId dest = location_container(p_body.destination);
					if (p_inventory.find_container(dest) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, dest.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, RotateItemCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, SplitStackCommand>) {
					if (p_inventory.find_item(p_body.source) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.source.value);
					}
					const ContainerInstanceId dest = location_container(p_body.destination);
					if (p_inventory.find_container(dest) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, dest.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, MergeStacksCommand>) {
					if (p_inventory.find_item(p_body.source) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.source.value);
					}
					if (p_inventory.find_item(p_body.destination) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.destination.value);
					}
					if (p_body.source == p_body.destination) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_body.source.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, InsertItemCommand>) {
					if (catalog_->find_item(p_body.item_definition_identifier) == nullptr) {
						return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_body.item_definition_identifier));
					}
					const ContainerInstanceId dest = location_container(p_body.destination);
					if (p_inventory.find_container(dest) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, dest.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, RemoveItemCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, EquipItemCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					if (p_inventory.find_container(p_body.destination_container) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.destination_container.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, UnequipItemCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId dest = location_container(p_body.destination);
					if (p_inventory.find_container(dest) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, dest.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, SwapItemsCommand>) {
					if (p_inventory.find_item(p_body.item_a) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item_a.value);
					}
					if (p_inventory.find_item(p_body.item_b) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item_b.value);
					}
					if (p_body.item_a == p_body.item_b) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_body.item_a.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) {
					// AutoPlaceItemCommand is single-inventory (see
					// inv_commands.h): destination must name the very
					// runtime dispatch_single() is running against.
					if (p_body.destination != p_inventory.id()) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::INVENTORY_NOT_IN_TRANSACTION_SET, p_body.destination.value);
					}
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					if (p_body.destination_container && p_inventory.find_container(p_body.destination_container) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.destination_container.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, AssignReferenceCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, ClearReferenceCommand>) {
					if (p_inventory.references().find(p_body.reference) == p_inventory.references().end()) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.reference.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, SetItemComponentCommand> ||
						std::is_same_v<T, RemoveItemComponentCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, DropItemCommand>) {
					if (p_inventory.find_item(p_body.item) == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					return ok_status();
				} else {
						static_assert(
								std::is_same_v<T, LootItemCommand> ||
										std::is_same_v<T, SettleInventoryCommand> ||
										std::is_same_v<T, QuickTransferItemCommand> ||
										std::is_same_v<T, TargetedProviderTransferCommand>,
								"unhandled Command alternative in resolve()");
					// Multi-inventory commands are dispatched through
					// dispatch_multi(), never dispatch_single() (and
					// therefore never here); see submit()'s command-bucket
					// split.
					return make_status(StatusCode::INTERNAL_ERROR);
				}
			},
			p_command);
}

// --- Phase 4: STRUCTURAL ---------------------------------------------------

Status InventoryTransactionPipeline::check_structural(const InventoryRuntime &p_inventory, const Command &p_command) const {
	const DefinitionCatalog &catalog = *catalog_;
	return std::visit(
			[&](const auto &p_body) -> Status {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, MoveItemCommand>) {
					return ok_status();
				} else if constexpr (std::is_same_v<T, RotateItemCommand>) {
					const ItemInstance *item = p_inventory.find_item(p_body.item);
					const ItemDefinition *item_def = item_definition_for(p_inventory, catalog, p_body.item);
					if (item == nullptr || item_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const SpatialPlacement *placement = std::get_if<SpatialPlacement>(&item->location);
					if (placement == nullptr) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, p_body.item.value);
					}
					if (!item_def->allow_rotation) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::ITEM_FOOTPRINT_INVALID, p_body.item.value);
					}
					const ContainerDefinition *container_def = container_definition_for(p_inventory, catalog, placement->container);
					if (container_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const SpatialGridLayout *grid = std::get_if<SpatialGridLayout>(&container_def->layout);
					if (grid == nullptr || !grid->allow_rotation) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::ITEM_FOOTPRINT_INVALID, placement->container.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, SplitStackCommand>) {
					const ItemInstance *source = p_inventory.find_item(p_body.source);
					if (source == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (!source->provided_containers.empty()) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_PROVIDED_CONTAINER_UNSUPPORTED, p_body.source.value);
					}
					if (p_body.quantity < 1 || p_body.quantity >= source->quantity) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, p_body.quantity);
					}
					const ContainerDefinition *source_container_def = container_definition_for(p_inventory, catalog, location_container(source->location));
					if (source_container_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (!container_has_feature(*source_container_def, FEATURE_STACKING) || !source_container_def->constraints.allow_stack_split) {
						return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_REQUIRED, hash_string(std::string(FEATURE_STACKING)));
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, MergeStacksCommand>) {
					const ItemInstance *source = p_inventory.find_item(p_body.source);
					const ItemInstance *dest = p_inventory.find_item(p_body.destination);
					if (source == nullptr || dest == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (source->item_definition != dest->item_definition) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_DEFINITION_MISMATCH, dest->item_definition);
					}
					if (!source->provided_containers.empty() || !dest->provided_containers.empty()) {
						const ItemInstanceId incompatible = !source->provided_containers.empty() ? p_body.source : p_body.destination;
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_PROVIDED_CONTAINER_UNSUPPORTED, incompatible.value);
					}
					if (!mutable_component_state_matches(*source, *dest)) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_COMPONENT_MISMATCH, p_body.destination.value);
					}
					const ContainerDefinition *dest_container_def = container_definition_for(p_inventory, catalog, location_container(dest->location));
					if (dest_container_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (!container_has_feature(*dest_container_def, FEATURE_STACKING)) {
						return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_REQUIRED, hash_string(std::string(FEATURE_STACKING)));
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, InsertItemCommand>) {
					const ItemDefinition *item_def = catalog.find_item(p_body.item_definition_identifier);
					if (item_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (p_body.quantity < 1 || p_body.quantity > item_def->max_stack || p_body.quantity > MAX_STACK_QUANTITY) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, p_body.quantity);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, RemoveItemCommand>) {
					return ok_status();
				} else if constexpr (std::is_same_v<T, EquipItemCommand>) {
					const ContainerDefinition *dest_def = container_definition_for(p_inventory, catalog, p_body.destination_container);
					if (dest_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (layout_kind(dest_def->layout) != OwnershipLayoutKind::NAMED_SLOTS) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, p_body.destination_container.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, UnequipItemCommand>) {
					const ItemInstance *item = p_inventory.find_item(p_body.item);
					if (item == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					if (!std::holds_alternative<SlotPlacement>(item->location)) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, p_body.item.value);
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, SwapItemsCommand>) {
					return ok_status();
				} else if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) {
					return ok_status(); // destination/item existence already RESOLVEd.
				} else if constexpr (std::is_same_v<T, AssignReferenceCommand>) {
					return ok_status();
				} else if constexpr (std::is_same_v<T, ClearReferenceCommand>) {
					return ok_status();
				} else if constexpr (std::is_same_v<T, SetItemComponentCommand>) {
					Status status = validate_identifier(p_body.component_identifier);
					if (!status.ok()) {
						return status;
					}
					if (p_body.payload.size() > MAX_TRAIT_PAYLOAD_BYTES) {
						return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE, p_body.payload.size());
					}
					return ok_status();
				} else if constexpr (std::is_same_v<T, RemoveItemComponentCommand>) {
					return validate_identifier(p_body.component_identifier);
				} else if constexpr (std::is_same_v<T, DropItemCommand>) {
					if (!p_body.external_owner) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::EXTERNAL_OWNER_INVALID, p_body.item.value);
					}
					return ok_status();
				} else {
						static_assert(
								std::is_same_v<T, LootItemCommand> ||
										std::is_same_v<T, SettleInventoryCommand> ||
										std::is_same_v<T, QuickTransferItemCommand> ||
										std::is_same_v<T, TargetedProviderTransferCommand>,
								"unhandled Command alternative in check_structural()");
					return make_status(StatusCode::INTERNAL_ERROR);
				}
			},
			p_command);
}

// --- Phase 5: FEATURE/CONSTRAINT (tasks.md 5.8 canonical order) -----------

Status InventoryTransactionPipeline::check_feature_constraints(const InventoryRuntime &p_inventory, const Command &p_command) const {
	const DefinitionCatalog &catalog = *catalog_;
	return std::visit(
			[&](const auto &p_body) -> Status {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, MoveItemCommand>) {
					return evaluate_move_like(p_inventory, catalog, p_body.item, p_body.destination);
				} else if constexpr (std::is_same_v<T, RotateItemCommand>) {
					const ItemInstance *item = p_inventory.find_item(p_body.item);
					if (item == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					return evaluate_move_like(p_inventory, catalog, p_body.item, item->location);
				} else if constexpr (std::is_same_v<T, SplitStackCommand>) {
					const ItemInstance *source = p_inventory.find_item(p_body.source);
					const ItemDefinition *item_def = item_definition_for(p_inventory, catalog, p_body.source);
					if (source == nullptr || item_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const ContainerInstanceId source_container = location_container(source->location);
					const ContainerInstanceId dest_container = location_container(p_body.destination);
					const ContainerDefinition *dest_def = container_definition_for(p_inventory, catalog, dest_container);
					if (dest_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}

					Status status = check_access(*dest_def, AccessFlag::INSERT);
					if (!status.ok()) {
						return status;
					}
					status = check_destination_filters(*dest_def, *item_def, p_body.destination);
					if (!status.ok()) {
						return status;
					}

					// A split always creates a genuinely new, distinct
					// occupant even when it lands in the source's own
					// container, so count capacity is always evaluated.
					std::uint32_t count = 0;
					p_inventory.count_in_container(dest_container, count);
					status = check_count_capacity(*dest_def, p_inventory.limits(), count + 1);
					if (!status.ok()) {
						return status;
					}

					// Mass is only evaluated when crossing containers: a
					// same-container split conserves the source item's
					// current subtree mass across the two resulting stacks
					// (the source keeps whatever provided containers it has;
					// the freshly-created stack starts with none), so the
					// container's total is unchanged and re-adding the new
					// stack's mass on top of the still-full-quantity source
					// total already counted would over-reject.
					if (source_container != dest_container) {
						std::int64_t new_mass = 0;
						status = checked_mul_i64(item_def->unit_mass_mg, static_cast<std::int64_t>(p_body.quantity), new_mass);
						if (!status.ok()) {
							return status;
						}
						std::int64_t dest_mass = 0;
						status = p_inventory.container_mass(dest_container, dest_mass);
						if (!status.ok()) {
							return status;
						}
						std::int64_t projected = 0;
						status = checked_add_i64(dest_mass, new_mass, projected);
						if (!status.ok()) {
							return status;
						}
						status = check_mass_capacity(p_inventory, dest_container, projected);
						if (!status.ok()) {
							return status;
						}
					}

					status = check_nesting(p_inventory, dest_container, *dest_def);
					if (!status.ok()) {
						return status;
					}
					// STACK BOUNDS: the new stack's quantity is strictly less
					// than the source's already-valid quantity (STRUCTURAL
					// phase enforced 1 <= quantity < source.quantity), so it
					// is trivially <= item_def->max_stack; nothing further.
					return check_retention(*dest_def);
				} else if constexpr (std::is_same_v<T, MergeStacksCommand>) {
					const ItemInstance *source = p_inventory.find_item(p_body.source);
					const ItemInstance *dest = p_inventory.find_item(p_body.destination);
					const ItemDefinition *item_def = item_definition_for(p_inventory, catalog, p_body.destination);
					if (source == nullptr || dest == nullptr || item_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const ContainerInstanceId source_container = location_container(source->location);
					const ContainerInstanceId dest_container = location_container(dest->location);
					const ContainerDefinition *source_def = container_definition_for(p_inventory, catalog, source_container);
					const ContainerDefinition *dest_def = container_definition_for(p_inventory, catalog, dest_container);
					if (source_def == nullptr || dest_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const bool same_container = source_container == dest_container;

					Status status = same_container ? check_access(*dest_def, AccessFlag::MOVE) : check_access(*source_def, AccessFlag::REMOVE);
					if (!status.ok()) {
						return status;
					}
					if (!same_container) {
						status = check_access(*dest_def, AccessFlag::INSERT);
						if (!status.ok()) {
							return status;
						}
					}

					status = check_destination_filters(*dest_def, *item_def, dest->location);
					if (!status.ok()) {
						return status;
					}

					// COUNT: never evaluated -- the destination item already
					// exists and stays; the source item vanishes without
					// ever being counted as a destination occupant.

					if (!same_container) {
						std::int64_t added_mg = 0;
						status = checked_mul_i64(item_def->unit_mass_mg, static_cast<std::int64_t>(source->quantity), added_mg);
						if (!status.ok()) {
							return status;
						}
						std::int64_t dest_mass = 0;
						status = p_inventory.container_mass(dest_container, dest_mass);
						if (!status.ok()) {
							return status;
						}
						std::int64_t projected = 0;
						status = checked_add_i64(dest_mass, added_mg, projected);
						if (!status.ok()) {
							return status;
						}
						status = check_mass_capacity(p_inventory, dest_container, projected);
						if (!status.ok()) {
							return status;
						}
					}

					status = check_nesting(p_inventory, dest_container, *dest_def);
					if (!status.ok()) {
						return status;
					}

					std::uint64_t combined = 0;
					status = checked_add_u64(source->quantity, dest->quantity, combined);
					if (!status.ok()) {
						return status;
					}
					if (combined > item_def->max_stack || combined > MAX_STACK_QUANTITY) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, combined);
					}

					return check_retention(*dest_def);
				} else if constexpr (std::is_same_v<T, InsertItemCommand>) {
					const ItemDefinition *item_def = catalog.find_item(p_body.item_definition_identifier);
					if (item_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					return evaluate_arrival(p_inventory, catalog, *item_def, p_body.destination, p_body.quantity);
				} else if constexpr (std::is_same_v<T, RemoveItemCommand>) {
					const ItemInstance *item = p_inventory.find_item(p_body.item);
					if (item == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const ContainerDefinition *source_def = container_definition_for(p_inventory, catalog, location_container(item->location));
					if (source_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					Status status = check_access(*source_def, AccessFlag::REMOVE);
					if (!status.ok()) {
						return status;
					}
					return check_retention(*source_def);
				} else if constexpr (std::is_same_v<T, EquipItemCommand>) {
					const ItemLocation destination = SlotPlacement{ p_body.destination_container, p_body.slot_identifier };
					return evaluate_move_like(p_inventory, catalog, p_body.item, destination);
				} else if constexpr (std::is_same_v<T, UnequipItemCommand>) {
					return evaluate_move_like(p_inventory, catalog, p_body.item, p_body.destination);
				} else if constexpr (std::is_same_v<T, SwapItemsCommand>) {
					return evaluate_swap(p_inventory, catalog, p_body.item_a, p_body.item_b);
				} else if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) {
					// The FEATURE-phase pre-check for a search-based command
					// is running the same search the SIMULATE phase will
					// run again on the clone: identical read-only inputs
					// always produce the identical candidate (or the
					// identical rejection), so re-running it costs a little
					// but never diverges (tasks.md 5.3 determinism
					// requirement).
					ItemLocation discard;
					return find_reorganize_candidate(p_inventory, catalog, p_body.item, p_body.destination_container, discard);
				} else if constexpr (std::is_same_v<T, AssignReferenceCommand>) {
					return ok_status(); // non-owning references are not subject to container FEATURE/CONSTRAINT evaluation.
				} else if constexpr (std::is_same_v<T, ClearReferenceCommand>) {
					return ok_status();
				} else if constexpr (std::is_same_v<T, SetItemComponentCommand> ||
						std::is_same_v<T, RemoveItemComponentCommand>) {
					// Component policy is evaluated through PermissionProvider in the
					// POLICY phase. Components do not alter container constraints.
					return ok_status();
				} else if constexpr (std::is_same_v<T, DropItemCommand>) {
					const ItemInstance *item = p_inventory.find_item(p_body.item);
					if (item == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const ContainerDefinition *source_def = container_definition_for(p_inventory, catalog, location_container(item->location));
					if (source_def == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					Status status = check_access(*source_def, AccessFlag::REMOVE);
					if (!status.ok()) {
						return status;
					}
					return check_retention(*source_def);
				} else {
						static_assert(
								std::is_same_v<T, LootItemCommand> ||
										std::is_same_v<T, SettleInventoryCommand> ||
										std::is_same_v<T, QuickTransferItemCommand> ||
										std::is_same_v<T, TargetedProviderTransferCommand>,
								"unhandled Command alternative in check_feature_constraints()");
					return make_status(StatusCode::INTERNAL_ERROR);
				}
			},
			p_command);
}

// --- Phase 6: SIMULATE ------------------------------------------------------

Status InventoryTransactionPipeline::simulate(InventoryRuntime &p_clone, const Command &p_command, TransactionResult &r_result, std::vector<DeltaOp> &r_ops) const {
	return std::visit(
			[&](const auto &p_body) -> Status {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, MoveItemCommand>) {
					const ItemInstance *before = p_clone.find_item(p_body.item);
					if (before == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId source_container = location_container(before->location);
					Status status = p_clone.move_item(p_body.item, p_body.destination);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::MOVED, p_body.item, ItemInstanceId{}, source_container, location_container(p_body.destination), ReferenceId{} });
					append_item_moved(p_clone, p_body.item, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, RotateItemCommand>) {
					const ItemInstance *before = p_clone.find_item(p_body.item);
					if (before == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const SpatialPlacement *placement = std::get_if<SpatialPlacement>(&before->location);
					if (placement == nullptr) {
						return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, p_body.item.value);
					}
					SpatialPlacement rotated = *placement;
					rotated.rotated = p_body.rotated;
					const ContainerInstanceId container_id = placement->container;
					Status status = p_clone.move_item(p_body.item, rotated);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::ROTATED, p_body.item, ItemInstanceId{}, container_id, container_id, ReferenceId{} });
					append_item_moved(p_clone, p_body.item, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, SplitStackCommand>) {
					const ItemInstance *source = p_clone.find_item(p_body.source);
					if (source == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.source.value);
					}
					const std::string *definition_identifier = p_clone.item_definition_identifier(source->item_definition);
					if (definition_identifier == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const std::string item_definition_identifier_copy = *definition_identifier;
					const ContainerInstanceId source_container = location_container(source->location);
					const std::uint64_t remaining = source->quantity - p_body.quantity;

					ItemInstanceId new_item_id;
					Status status = p_clone.create_item(item_definition_identifier_copy, p_body.quantity, p_body.destination, new_item_id);
					if (!status.ok()) {
						return status;
					}
					// The split stack inherits the source's mutable components
					// (durability etc.): both halves came from the same
					// physical stack (zerkov_v1 split semantics).
					status = copy_mutable_component_state(*source, p_clone, new_item_id);
					if (!status.ok()) {
						return status;
					}
					status = p_clone.set_quantity(p_body.source, remaining);
					if (!status.ok()) {
						return status;
					}
					r_result.new_item_id = new_item_id;
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::SPLIT, new_item_id, p_body.source, source_container, location_container(p_body.destination), ReferenceId{} });
					// ITEM_CREATED first (the new stack, including any
					// inherited components already copied above), then
					// ITEM_QUANTITY for the reduced source -- tasks.md 5.1's
					// documented split op shape.
					append_item_created(p_clone, new_item_id, r_ops);
					r_ops.push_back(DeltaOp{ ItemQuantityOp{ p_body.source.value, remaining } });
					return ok_status();
				} else if constexpr (std::is_same_v<T, MergeStacksCommand>) {
					const ItemInstance *source = p_clone.find_item(p_body.source);
					const ItemInstance *dest = p_clone.find_item(p_body.destination);
					if (source == nullptr || dest == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE);
					}
					const ContainerInstanceId source_container = location_container(source->location);
					const ContainerInstanceId dest_container = location_container(dest->location);
					std::uint64_t combined = 0;
					Status status = checked_add_u64(source->quantity, dest->quantity, combined);
					if (!status.ok()) {
						return status;
					}
					status = p_clone.set_quantity(p_body.destination, combined);
					if (!status.ok()) {
						return status;
					}
					std::vector<ItemSubtreeEntry> released_items;
					std::vector<ContainerSubtreeEntry> released_containers;
					std::vector<ReferenceId> cleared_references;
					status = p_clone.release_item_subtree(p_body.source, released_items, released_containers, cleared_references);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::MERGED, p_body.destination, p_body.source, source_container, dest_container, ReferenceId{} });
					r_ops.push_back(DeltaOp{ ItemQuantityOp{ p_body.destination.value, combined } });
					append_subtree_released(released_items, released_containers, cleared_references, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, InsertItemCommand>) {
					ItemInstanceId new_item_id;
					Status status = p_clone.create_item(p_body.item_definition_identifier, p_body.quantity, p_body.destination, new_item_id);
					if (!status.ok()) {
						return status;
					}
					r_result.new_item_id = new_item_id;
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::INSERTED, new_item_id, ItemInstanceId{}, ContainerInstanceId{}, location_container(p_body.destination), ReferenceId{} });
					append_item_created(p_clone, new_item_id, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, RemoveItemCommand>) {
					const ItemInstance *item = p_clone.find_item(p_body.item);
					if (item == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId source_container = location_container(item->location);
					std::vector<ItemSubtreeEntry> released_items;
					std::vector<ContainerSubtreeEntry> released_containers;
					std::vector<ReferenceId> cleared_references;
					Status status = p_clone.release_item_subtree(p_body.item, released_items, released_containers, cleared_references);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::REMOVED, p_body.item, ItemInstanceId{}, source_container, ContainerInstanceId{}, ReferenceId{} });
					append_subtree_released(released_items, released_containers, cleared_references, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, EquipItemCommand>) {
					const ItemInstance *before = p_clone.find_item(p_body.item);
					if (before == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId source_container = location_container(before->location);
					SlotPlacement destination;
					destination.container = p_body.destination_container;
					destination.slot_identifier = p_body.slot_identifier;
					Status status = p_clone.move_item(p_body.item, destination);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::EQUIPPED, p_body.item, ItemInstanceId{}, source_container, p_body.destination_container, ReferenceId{} });
					append_item_moved(p_clone, p_body.item, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, UnequipItemCommand>) {
					const ItemInstance *before = p_clone.find_item(p_body.item);
					if (before == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId source_container = location_container(before->location);
					Status status = p_clone.move_item(p_body.item, p_body.destination);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::UNEQUIPPED, p_body.item, ItemInstanceId{}, source_container, location_container(p_body.destination), ReferenceId{} });
					append_item_moved(p_clone, p_body.item, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, SwapItemsCommand>) {
					const ItemInstance *a_before = p_clone.find_item(p_body.item_a);
					const ItemInstance *b_before = p_clone.find_item(p_body.item_b);
					if (a_before == nullptr || b_before == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE);
					}
					const ContainerInstanceId container_a = location_container(a_before->location);
					const ContainerInstanceId container_b = location_container(b_before->location);
					Status status = p_clone.swap_items(p_body.item_a, p_body.item_b);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::SWAPPED, p_body.item_a, p_body.item_b, container_a, container_b, ReferenceId{} });
					append_item_moved(p_clone, p_body.item_a, r_ops);
					append_item_moved(p_clone, p_body.item_b, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) {
					ItemLocation candidate;
					Status status = find_reorganize_candidate(p_clone, *catalog_, p_body.item, p_body.destination_container, candidate);
					if (!status.ok()) {
						return status;
					}
					const ItemInstance *before = p_clone.find_item(p_body.item);
					if (before == nullptr) {
						return make_status(StatusCode::INTERNAL_ERROR);
					}
					const ContainerInstanceId source_container = location_container(before->location);
					status = p_clone.move_item(p_body.item, candidate);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::MOVED, p_body.item, ItemInstanceId{}, source_container, location_container(candidate), ReferenceId{} });
					append_item_moved(p_clone, p_body.item, r_ops);
					return ok_status();
				} else if constexpr (std::is_same_v<T, AssignReferenceCommand>) {
					ReferenceId new_reference_id;
					Status status = p_clone.add_reference(p_body.item, new_reference_id);
					if (!status.ok()) {
						return status;
					}
					r_result.new_reference_id = new_reference_id;
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::REFERENCE_ASSIGNED, p_body.item, ItemInstanceId{}, ContainerInstanceId{}, ContainerInstanceId{}, new_reference_id });
					r_ops.push_back(DeltaOp{ ReferenceAssignedOp{ new_reference_id.value, p_body.item.value } });
					return ok_status();
				} else if constexpr (std::is_same_v<T, ClearReferenceCommand>) {
					const auto found = p_clone.references().find(p_body.reference);
					if (found == p_clone.references().end()) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.reference.value);
					}
					const ItemInstanceId referenced_item = found->second;
					Status status = p_clone.remove_reference(p_body.reference);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::REFERENCE_CLEARED, referenced_item, ItemInstanceId{}, ContainerInstanceId{}, ContainerInstanceId{}, p_body.reference });
					r_ops.push_back(DeltaOp{ ReferenceClearedOp{ p_body.reference.value } });
					return ok_status();
				} else if constexpr (std::is_same_v<T, SetItemComponentCommand>) {
					Status status = p_clone.set_component(
							p_body.item,
							p_body.component_identifier,
							p_body.payload);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::COMPONENT_SET, p_body.item, ItemInstanceId{}, ContainerInstanceId{}, ContainerInstanceId{}, ReferenceId{} });
					r_ops.push_back(DeltaOp{ ItemComponentSetOp{ p_body.item.value, SnapshotMutableComponent{ p_body.component_identifier, p_body.payload } } });
					return ok_status();
				} else if constexpr (std::is_same_v<T, RemoveItemComponentCommand>) {
					Status status = p_clone.remove_component(p_body.item, p_body.component_identifier);
					if (!status.ok()) {
						return status;
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::COMPONENT_REMOVED, p_body.item, ItemInstanceId{}, ContainerInstanceId{}, ContainerInstanceId{}, ReferenceId{} });
					r_ops.push_back(DeltaOp{ ItemComponentRemovedOp{ p_body.item.value, p_body.component_identifier } });
					return ok_status();
				} else if constexpr (std::is_same_v<T, DropItemCommand>) {
					const ItemInstance *before = p_clone.find_item(p_body.item);
					if (before == nullptr) {
						return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_body.item.value);
					}
					const ContainerInstanceId source_container = location_container(before->location);
					std::vector<ItemSubtreeEntry> items;
					std::vector<ContainerSubtreeEntry> containers;
					std::vector<ReferenceId> cleared_references;
					Status status = p_clone.release_item_subtree(p_body.item, items, containers, cleared_references);
					if (!status.ok()) {
						return status;
					}
					r_result.dropped_external_owner = p_body.external_owner;
					r_result.dropped_items.reserve(items.size());
					for (const ItemSubtreeEntry &entry : items) {
						r_result.dropped_items.push_back(DroppedItemValue{ entry.definition_identifier, entry.instance.quantity, entry.instance.mutable_components, p_body.external_owner });
					}
					r_result.events.push_back(TransactionEvent{ TransactionEventKind::DROPPED, p_body.item, ItemInstanceId{}, source_container, ContainerInstanceId{}, ReferenceId{} });
					append_subtree_released(items, containers, cleared_references, r_ops);
					return ok_status();
				} else {
						static_assert(
								std::is_same_v<T, LootItemCommand> ||
										std::is_same_v<T, SettleInventoryCommand> ||
										std::is_same_v<T, QuickTransferItemCommand> ||
										std::is_same_v<T, TargetedProviderTransferCommand>,
								"unhandled Command alternative in simulate()");
					// Multi-inventory commands never reach dispatch_single()
					// (and therefore never here); see submit()'s bucket
					// split and run_loot()/run_settle()/
					// run_quick_transfer().
					return make_status(StatusCode::INTERNAL_ERROR);
				}
			},
			p_command);
}

// --- reject(): shared rejection shape ---------------------------------------

TransactionResult InventoryTransactionPipeline::reject(TransactionResult p_result, Status p_status) const {
	p_result.accepted = false;
	p_result.status = p_status;
	p_result.events.clear();
	p_result.new_item_id = ItemInstanceId{};
	p_result.new_reference_id = ReferenceId{};
	p_result.dropped_external_owner = ExternalOwnerId{};
	p_result.dropped_items.clear();
	p_result.transferred_quantity = 0;
	p_result.remaining_quantity = 0;
	p_result.deltas.clear();
	notify(p_result);
	return p_result;
}

// --- dispatch_single(): the original nine commands plus AutoPlaceItem/
// AssignReference/ClearReference/DropItem, all single-runtime -------------

TransactionResult InventoryTransactionPipeline::dispatch_single(InventoryRuntime &p_inventory, const CommandHeader &p_header, const Command &p_command) {
	TransactionResult result;
	result.command_id = p_header.command_id;
	// Populated unconditionally, even for a rejection, so "before == after"
	// is directly assertable as revisions[0].predecessor == .successor
	// without special-casing the reject path (tasks.md 5.10).
	result.revisions.push_back(RevisionOutcome{ p_inventory.id(), p_inventory.revision(), p_inventory.revision() });

	if (!p_header.command_id) {
		return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE));
	}

	// Idempotency cache-hit short-circuit. This intentionally runs BEFORE
	// RESOLVE even though design.md numbers RESOLVE as step 1 and identity/
	// idempotency as step 2: a duplicate must "return the recorded result
	// without executing the mutation again" (spec) regardless of what has
	// happened to the command's targets SINCE the original accept (e.g. a
	// later, different command moved or destroyed the same item) -- running
	// RESOLVE first could turn a legitimate duplicate-replay into a spurious
	// NOT_FOUND rejection. Only accepted results are ever recorded (see
	// record_idempotency() callers below), so a duplicate of a REJECTED
	// command is never in idempotency_index_ and correctly falls through to
	// re-run the full ordered pipeline, re-rejecting identically because
	// state never changed the first time either.
	const std::uint64_t incoming_fingerprint = payload_fingerprint(p_command);
	const auto idempotent = idempotency_index_.find(p_header.command_id);
	if (idempotent != idempotency_index_.end()) {
		if (idempotent->second.payload_fingerprint == incoming_fingerprint) {
			// Replay the recorded accepted result without re-emitting its
			// events: they were observable exactly once, on first accept
			// (zerkov_v1 duplicate_command_replays_result: events=0,
			// status=duplicate_result_replay).
			TransactionResult replay = idempotent->second.result;
			replay.status = make_status(StatusCode::OK, DiagnosticId::DUPLICATE_RESULT_REPLAY, replay.events.size());
			replay.events.clear();
			replay.deltas.clear();
			replay.replayed = true;
			return replay;
		}
		return reject(result, make_status(StatusCode::DUPLICATE_COMMAND, DiagnosticId::IDEMPOTENCY_PAYLOAD_MISMATCH, incoming_fingerprint));
	}

	if (quantity_reservations_ != nullptr &&
			quantity_reservations_->conflicts(p_command, &p_inventory)) {
		return reject(result, make_status(
				StatusCode::COMMAND_REJECTED,
				DiagnosticId::RESERVATION_CONFLICT));
	}

	// Phase 1: RESOLVE.
	Status status = resolve(p_inventory, p_command);
	if (!status.ok()) {
		return reject(result, status);
	}

	// Phase 2: REVISION (the remaining half of design.md step 2, after the
	// identity/idempotency short-circuit above).
	if (p_header.expected_revisions.size() != 1 || p_header.expected_revisions[0].inventory != p_inventory.id()) {
		return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_header.expected_revisions.size()));
	}
	if (p_header.expected_revisions[0].revision != p_inventory.revision()) {
		result.conflicting_inventory = p_inventory.id();
		result.authoritative_revision = p_inventory.revision();
		return reject(result, make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, p_inventory.revision()));
	}

	// Phase 3: POLICY.
	status = permissions_->check(p_header, p_command);
	if (!status.ok()) {
		return reject(result, status);
	}
	status = check_external_metrics(p_header);
	if (!status.ok()) {
		return reject(result, status);
	}

	// Phase 4: STRUCTURAL.
	status = check_structural(p_inventory, p_command);
	if (!status.ok()) {
		return reject(result, status);
	}

	// Phase 5: FEATURE/CONSTRAINT.
	status = check_feature_constraints(p_inventory, p_command);
	if (!status.ok()) {
		return reject(result, status);
	}

	// Phase 6: SIMULATE (clone; only the clone is ever mutated here).
	InventoryRuntime clone = p_inventory;
	std::vector<DeltaOp> ops;
	status = simulate(clone, p_command, result, ops);
	if (!status.ok()) {
		return reject(result, status);
	}

	// Phase 7: INVARIANT.
	status = clone.validate_invariants();
	if (!status.ok()) {
		return reject(result, status);
	}

	// Phase 8: COMMIT.
	const std::uint64_t predecessor = p_inventory.revision();
	p_inventory = std::move(clone);
	const std::uint64_t successor = p_inventory.commit_revision();

	// Phase 9: RESULT/EVENTS.
	result.accepted = true;
	result.status = ok_status();
	result.revisions[0] = RevisionOutcome{ p_inventory.id(), predecessor, successor };
	result.deltas.push_back(InventoryDelta{ p_inventory.id(), predecessor, successor, std::move(ops) });

	record_idempotency(p_header.command_id, incoming_fingerprint, result);

	// Phase 10: NOTIFY.
	notify(result);
	return result;
}

// --- prepare_multi()/finish_multi(): shared multi-inventory harness --------

Status InventoryTransactionPipeline::prepare_multi(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const Command &p_command,
		std::vector<InventoryId> p_touched_raw,
		std::vector<InventoryId> &r_touched,
		std::vector<InventoryRuntime *> &r_runtimes,
		std::vector<InventoryRuntime> &r_clones,
		TransactionResult &r_result) const {
	r_touched.clear();
	r_runtimes.clear();
	r_clones.clear();

	// RESOLVE (touched-set): canonical ascending-InventoryId order,
	// independent of argument order in either p_touched_raw or
	// p_inventories (tasks.md 5.4 determinism requirement).
	std::sort(p_touched_raw.begin(), p_touched_raw.end());
	p_touched_raw.erase(std::unique(p_touched_raw.begin(), p_touched_raw.end()), p_touched_raw.end());
	if (p_touched_raw.empty()) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	if (p_touched_raw.size() > MAX_INVENTORIES_PER_TRANSACTION) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, p_touched_raw.size());
	}
	for (InventoryId id : p_touched_raw) {
		InventoryRuntime *found = nullptr;
		for (InventoryRuntime *candidate : p_inventories) {
			if (candidate != nullptr && candidate->id() == id) {
				found = candidate;
				break;
			}
		}
		if (found == nullptr) {
			return make_status(StatusCode::NOT_FOUND, DiagnosticId::INVENTORY_NOT_IN_TRANSACTION_SET, id.value);
		}
		r_touched.push_back(id);
		r_runtimes.push_back(found);
	}

	// Populated unconditionally, even for a rejection below, so "before ==
	// after" is directly assertable per touched inventory (tasks.md 5.10).
	for (std::size_t i = 0; i < r_touched.size(); ++i) {
		r_result.revisions.push_back(RevisionOutcome{ r_touched[i], r_runtimes[i]->revision(), r_runtimes[i]->revision() });
	}

	// Shared-authority requirement (tasks.md 5.4): only meaningful once more
	// than one runtime is actually touched.
	if (r_touched.size() > 1) {
		const IdentityAuthority *authority = r_runtimes[0]->identity_authority();
		if (authority == nullptr) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::IDENTITY_AUTHORITY_MISMATCH, r_touched[0].value);
		}
		for (std::size_t i = 1; i < r_runtimes.size(); ++i) {
			if (r_runtimes[i]->identity_authority() != authority) {
				return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::IDENTITY_AUTHORITY_MISMATCH, r_touched[i].value);
			}
		}
	}

	// Phase 2: REVISION -- expected_revisions must be an exact bijection
	// with the touched set (missing/extra/duplicate all reject), then every
	// touched inventory's expectation is checked in canonical ascending
	// order (r_touched is already sorted), so the FIRST stale one found is
	// deterministic regardless of argument order.
	if (p_header.expected_revisions.size() != r_touched.size()) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::REVISION_COVERAGE_INVALID, p_header.expected_revisions.size());
	}
	for (InventoryId id : r_touched) {
		std::size_t matches = 0;
		for (const ExpectedRevision &expected : p_header.expected_revisions) {
			if (expected.inventory == id) {
				++matches;
			}
		}
		if (matches != 1) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::REVISION_COVERAGE_INVALID, id.value);
		}
	}
	for (std::size_t i = 0; i < r_touched.size(); ++i) {
		std::uint64_t expected_revision = 0;
		for (const ExpectedRevision &expected : p_header.expected_revisions) {
			if (expected.inventory == r_touched[i]) {
				expected_revision = expected.revision;
				break;
			}
		}
		if (expected_revision != r_runtimes[i]->revision()) {
			r_result.conflicting_inventory = r_touched[i];
			r_result.authoritative_revision = r_runtimes[i]->revision();
			return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, r_runtimes[i]->revision());
		}
	}

	// Phase 3: POLICY.
	Status status = permissions_->check(p_header, p_command);
	if (!status.ok()) {
		return status;
	}
	status = check_external_metrics(p_header);
	if (!status.ok()) {
		return status;
	}

	// Clone setup for the caller's command-specific RESOLVE/STRUCTURAL/
	// FEATURE/SIMULATE (see this method's header doc comment for why the
	// multi-inventory path validates against clones rather than the live
	// runtimes: a rejection still leaves every real runtime untouched
	// either way, since clones are only ever swapped in by finish_multi()
	// after every one of them passes INVARIANT).
	r_clones.reserve(r_runtimes.size());
	for (InventoryRuntime *runtime : r_runtimes) {
		r_clones.push_back(*runtime);
	}
	return ok_status();
}

TransactionResult InventoryTransactionPipeline::finish_multi(
		const std::vector<InventoryId> &p_touched,
		const std::vector<InventoryRuntime *> &p_runtimes,
		std::vector<InventoryRuntime> &p_clones,
		const CommandHeader &p_header,
		std::uint64_t p_payload_fingerprint,
		TransactionResult r_result,
		std::map<InventoryId, std::vector<DeltaOp>> p_ops_by_inventory) {
	// Phase 7: INVARIANT -- every touched clone, first failure rejects the
	// WHOLE transaction (design.md: "commit all of them or none of them").
	for (InventoryRuntime &clone : p_clones) {
		Status status = clone.validate_invariants();
		if (!status.ok()) {
			return reject(r_result, status);
		}
	}

	// Phase 8: COMMIT -- canonical ascending order (p_touched is already
	// sorted by prepare_multi()).
	r_result.deltas.reserve(p_touched.size());
	for (std::size_t i = 0; i < p_touched.size(); ++i) {
		const std::uint64_t predecessor = p_runtimes[i]->revision();
		*p_runtimes[i] = std::move(p_clones[i]);
		const std::uint64_t successor = p_runtimes[i]->commit_revision();
		r_result.revisions[i] = RevisionOutcome{ p_touched[i], predecessor, successor };
		const auto ops_it = p_ops_by_inventory.find(p_touched[i]);
		std::vector<DeltaOp> ops = ops_it != p_ops_by_inventory.end() ? std::move(ops_it->second) : std::vector<DeltaOp>{};
		r_result.deltas.push_back(InventoryDelta{ p_touched[i], predecessor, successor, std::move(ops) });
	}

	// Phase 9: RESULT/EVENTS.
	r_result.accepted = true;
	r_result.status = ok_status();

	// Idempotency is command-scoped, not per-inventory: one record covers
	// every touched inventory's outcome together.
	record_idempotency(p_header.command_id, p_payload_fingerprint, r_result);

	// Phase 10: NOTIFY.
	notify(r_result);
	return r_result;
}

// --- run_loot(): LootItemCommand (tasks.md 5.4) -----------------------------

TransactionResult InventoryTransactionPipeline::run_loot(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const LootItemCommand &p_command,
		std::uint64_t p_payload_fingerprint) {
	TransactionResult result;
	result.command_id = p_header.command_id;

	std::vector<InventoryId> touched;
	std::vector<InventoryRuntime *> runtimes;
	std::vector<InventoryRuntime> clones;
	Status status = prepare_multi(p_inventories, p_header, Command{ p_command }, { p_command.source, p_command.destination }, touched, runtimes, clones, result);
	if (!status.ok()) {
		return reject(result, status);
	}

	auto clone_for = [&](InventoryId p_id) -> InventoryRuntime & {
		for (std::size_t i = 0; i < touched.size(); ++i) {
			if (touched[i] == p_id) {
				return clones[i];
			}
		}
		return clones[0]; // unreachable: prepare_multi() guarantees every named id is touched.
	};
	InventoryRuntime &source_clone = clone_for(p_command.source);
	InventoryRuntime &destination_clone = clone_for(p_command.destination);

	// RESOLVE.
	const ItemInstance *item = source_clone.find_item(p_command.item);
	if (item == nullptr) {
		return reject(result, make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_command.item.value));
	}
	const ContainerInstanceId source_container = location_container(item->location);
	const ContainerInstanceId dest_container = location_container(p_command.destination_location);

	// FEATURE/CONSTRAINT: access (REMOVE at source, INSERT at destination)
	// and mass capacity for the whole moving subtree, in that order
	// (matches evaluate_move_like()'s access-then-mass ordering).
	// adopt_item_subtree() below owns placement/filters/count/nesting
	// (including subtree depth) for the destination -- the same
	// primitive/pipeline split every other command in this file uses.
	const ContainerDefinition *source_def = container_definition_for(source_clone, *catalog_, source_container);
	const ContainerDefinition *dest_def = container_definition_for(destination_clone, *catalog_, dest_container);
	if (source_def == nullptr || dest_def == nullptr) {
		return reject(result, make_status(StatusCode::INTERNAL_ERROR));
	}
	status = check_access(*source_def, AccessFlag::REMOVE);
	if (!status.ok()) {
		return reject(result, status);
	}
	status = check_access(*dest_def, AccessFlag::INSERT);
	if (!status.ok()) {
		return reject(result, status);
	}
	std::int64_t subtree_mass = 0;
	status = source_clone.item_subtree_mass(p_command.item, subtree_mass);
	if (!status.ok()) {
		return reject(result, status);
	}
	std::int64_t dest_mass = 0;
	status = destination_clone.container_mass(dest_container, dest_mass);
	if (!status.ok()) {
		return reject(result, status);
	}
	std::int64_t projected_mass = 0;
	status = checked_add_i64(dest_mass, subtree_mass, projected_mass);
	if (!status.ok()) {
		return reject(result, status);
	}
	status = check_mass_capacity(destination_clone, dest_container, projected_mass);
	if (!status.ok()) {
		return reject(result, status);
	}

	// SIMULATE.
	const std::uint64_t moved_quantity = item->quantity;
	std::vector<ItemSubtreeEntry> items;
	std::vector<ContainerSubtreeEntry> containers;
	std::vector<ReferenceId> cleared_references;
	status = source_clone.release_item_subtree(p_command.item, items, containers, cleared_references);
	if (!status.ok()) {
		return reject(result, status);
	}
	status = destination_clone.adopt_item_subtree(items, containers, p_command.destination_location);
	if (!status.ok()) {
		return reject(result, status);
	}

	result.events.push_back(TransactionEvent{ TransactionEventKind::LOOTED, p_command.item, ItemInstanceId{}, source_container, dest_container, ReferenceId{} });
	result.transferred_quantity = moved_quantity;
	result.remaining_quantity = 0;

	std::map<InventoryId, std::vector<DeltaOp>> ops_by_inventory;
	append_subtree_released(items, containers, cleared_references, ops_by_inventory[p_command.source]);
	append_subtree_created(items, containers, p_command.destination_location, ops_by_inventory[p_command.destination]);

	return finish_multi(touched, runtimes, clones, p_header, p_payload_fingerprint, result, std::move(ops_by_inventory));
}

// --- run_settle(): SettleInventoryCommand (tasks.md 5.5) -------------------

TransactionResult InventoryTransactionPipeline::run_settle(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const SettleInventoryCommand &p_command,
		std::uint64_t p_payload_fingerprint) {
	TransactionResult result;
	result.command_id = p_header.command_id;

	if (p_command.plan.empty() || p_command.plan.size() > MAX_SETTLEMENT_PLAN_ENTRIES) {
		return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SETTLEMENT_PLAN_INVALID, p_command.plan.size()));
	}
	{
		std::set<std::uint64_t> seen;
		for (const SettlementEntry &entry : p_command.plan) {
			if (!seen.insert(entry.item.value).second) {
				return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SETTLEMENT_PLAN_INVALID, entry.item.value));
			}
		}
	}

	std::vector<InventoryId> touched_raw = { p_command.inventory };
	for (const SettlementEntry &entry : p_command.plan) {
		if (const SettlementTransfer *transfer = std::get_if<SettlementTransfer>(&entry.disposition)) {
			touched_raw.push_back(transfer->destination);
		}
	}

	std::vector<InventoryId> touched;
	std::vector<InventoryRuntime *> runtimes;
	std::vector<InventoryRuntime> clones;
	Status status = prepare_multi(p_inventories, p_header, Command{ p_command }, touched_raw, touched, runtimes, clones, result);
	if (!status.ok()) {
		return reject(result, status);
	}

	auto clone_for = [&](InventoryId p_id) -> InventoryRuntime & {
		for (std::size_t i = 0; i < touched.size(); ++i) {
			if (touched[i] == p_id) {
				return clones[i];
			}
		}
		return clones[0]; // unreachable: prepare_multi() guarantees every named id is touched.
	};
	InventoryRuntime &self_clone = clone_for(p_command.inventory);
	std::map<InventoryId, std::vector<DeltaOp>> ops_by_inventory;

	// RESOLVE/STRUCTURAL/FEATURE/SIMULATE, one plan entry at a time, in the
	// game-declared plan order (a deterministic property of the input, like
	// every other ordering in this pipeline). A RETAIN entry mutates
	// nothing; TRANSFER_TO/RELEASE_TO reuse exactly LootItemCommand's/
	// DropItemCommand's own access+mass+subtree-transfer discipline.
	for (const SettlementEntry &entry : p_command.plan) {
		const ItemInstance *item = self_clone.find_item(entry.item);
		if (item == nullptr) {
			return reject(result, make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, entry.item.value));
		}

		if (std::holds_alternative<SettlementRetain>(entry.disposition)) {
			// The only retention semantics the core owns (design.md
			// "Protected and secure containers"): RETAIN is eligible only
			// when the item's CURRENT container already declares
			// PROTECTED or BOUND retention. There is no field anywhere in
			// SettlementEntry/SettlementRetain for an untrusted sender to
			// assert a retention OUTCOME (inventory-transactions spec,
			// "Client declares retained items") -- gate WHO may submit a
			// SettleInventoryCommand at all in PermissionProvider::check().
			const ContainerDefinition *container_def = container_definition_for(self_clone, *catalog_, location_container(item->location));
			if (container_def == nullptr) {
				return reject(result, make_status(StatusCode::INTERNAL_ERROR));
			}
			if (container_def->constraints.retention != RetentionClass::PROTECTED && container_def->constraints.retention != RetentionClass::BOUND) {
				return reject(result, make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::RETENTION_NOT_ELIGIBLE, entry.item.value));
			}
			continue;
		}

		if (const SettlementTransfer *transfer = std::get_if<SettlementTransfer>(&entry.disposition)) {
			InventoryRuntime &dest_clone = clone_for(transfer->destination);
			const ContainerInstanceId source_container = location_container(item->location);
			const ContainerInstanceId dest_container = location_container(transfer->location);
			const ContainerDefinition *source_def = container_definition_for(self_clone, *catalog_, source_container);
			const ContainerDefinition *dest_def = container_definition_for(dest_clone, *catalog_, dest_container);
			if (source_def == nullptr || dest_def == nullptr) {
				return reject(result, make_status(StatusCode::INTERNAL_ERROR));
			}
			status = check_access(*source_def, AccessFlag::REMOVE);
			if (!status.ok()) {
				return reject(result, status);
			}
			status = check_access(*dest_def, AccessFlag::INSERT);
			if (!status.ok()) {
				return reject(result, status);
			}
			std::int64_t subtree_mass = 0;
			status = self_clone.item_subtree_mass(entry.item, subtree_mass);
			if (!status.ok()) {
				return reject(result, status);
			}
			std::int64_t dest_mass = 0;
			status = dest_clone.container_mass(dest_container, dest_mass);
			if (!status.ok()) {
				return reject(result, status);
			}
			std::int64_t projected_mass = 0;
			status = checked_add_i64(dest_mass, subtree_mass, projected_mass);
			if (!status.ok()) {
				return reject(result, status);
			}
			status = check_mass_capacity(dest_clone, dest_container, projected_mass);
			if (!status.ok()) {
				return reject(result, status);
			}

			std::vector<ItemSubtreeEntry> items;
			std::vector<ContainerSubtreeEntry> containers;
			std::vector<ReferenceId> cleared_references;
			status = self_clone.release_item_subtree(entry.item, items, containers, cleared_references);
			if (!status.ok()) {
				return reject(result, status);
			}
			status = dest_clone.adopt_item_subtree(items, containers, transfer->location);
			if (!status.ok()) {
				return reject(result, status);
			}
			result.events.push_back(TransactionEvent{ TransactionEventKind::LOOTED, entry.item, ItemInstanceId{}, source_container, dest_container, ReferenceId{} });
			append_subtree_released(items, containers, cleared_references, ops_by_inventory[p_command.inventory]);
			append_subtree_created(items, containers, transfer->location, ops_by_inventory[transfer->destination]);
			continue;
		}

		const SettlementRelease &release = std::get<SettlementRelease>(entry.disposition);
		if (!release.external_owner) {
			return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::EXTERNAL_OWNER_INVALID, entry.item.value));
		}
		const ContainerInstanceId source_container = location_container(item->location);
		const ContainerDefinition *source_def = container_definition_for(self_clone, *catalog_, source_container);
		if (source_def == nullptr) {
			return reject(result, make_status(StatusCode::INTERNAL_ERROR));
		}
		status = check_access(*source_def, AccessFlag::REMOVE);
		if (!status.ok()) {
			return reject(result, status);
		}
		std::vector<ItemSubtreeEntry> items;
		std::vector<ContainerSubtreeEntry> containers;
		std::vector<ReferenceId> cleared_references;
		status = self_clone.release_item_subtree(entry.item, items, containers, cleared_references);
		if (!status.ok()) {
			return reject(result, status);
		}
		result.dropped_items.reserve(result.dropped_items.size() + items.size());
		for (const ItemSubtreeEntry &subtree_entry : items) {
			result.dropped_items.push_back(DroppedItemValue{ subtree_entry.definition_identifier, subtree_entry.instance.quantity, subtree_entry.instance.mutable_components, release.external_owner });
		}
		result.events.push_back(TransactionEvent{ TransactionEventKind::DROPPED, entry.item, ItemInstanceId{}, source_container, ContainerInstanceId{}, ReferenceId{} });
		append_subtree_released(items, containers, cleared_references, ops_by_inventory[p_command.inventory]);
	}

	return finish_multi(touched, runtimes, clones, p_header, p_payload_fingerprint, result, std::move(ops_by_inventory));
}

// --- run_quick_transfer(): QuickTransferItemCommand (tasks.md 5.3) ---------

TransactionResult InventoryTransactionPipeline::run_quick_transfer(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const QuickTransferItemCommand &p_command,
		std::uint64_t p_payload_fingerprint) {
	TransactionResult result;
	result.command_id = p_header.command_id;

	std::vector<InventoryId> touched;
	std::vector<InventoryRuntime *> runtimes;
	std::vector<InventoryRuntime> clones;
	Status status = prepare_multi(p_inventories, p_header, Command{ p_command }, { p_command.source, p_command.destination }, touched, runtimes, clones, result);
	if (!status.ok()) {
		return reject(result, status);
	}

	auto clone_for = [&](InventoryId p_id) -> InventoryRuntime & {
		for (std::size_t i = 0; i < touched.size(); ++i) {
			if (touched[i] == p_id) {
				return clones[i];
			}
		}
		return clones[0]; // unreachable: prepare_multi() guarantees every named id is touched.
	};
	InventoryRuntime &source_clone = clone_for(p_command.source);
	InventoryRuntime &destination_clone = clone_for(p_command.destination);
	const bool same_inventory = p_command.source == p_command.destination;
	std::map<InventoryId, std::vector<DeltaOp>> ops_by_inventory;

	const ItemInstance *item = source_clone.find_item(p_command.item);
	if (item == nullptr) {
		return reject(result, make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_command.item.value));
	}
	const ItemDefinition *item_def = item_definition_for(source_clone, *catalog_, p_command.item);
	if (item_def == nullptr) {
		return reject(result, make_status(StatusCode::INTERNAL_ERROR));
	}
	const std::uint64_t original_quantity = item->quantity;
	const std::string identifier = item_def->identifier;
	const ContainerInstanceId original_container = location_container(item->location);

	// Strategy step 1 (documented in inv_commands.h's
	// QuickTransferItemCommand doc comment): fill compatible existing
	// destination stacks first, ascending ItemInstanceId order.
	std::uint64_t remaining_to_place = original_quantity;
	std::uint64_t merged_amount = 0;
	for (const auto &pair : destination_clone.items()) {
		if (remaining_to_place == 0) {
			break;
		}
		if (pair.first == p_command.item) {
			continue; // only relevant when source == destination.
		}
		const ItemInstance &candidate_stack = pair.second;
		if (candidate_stack.item_definition != item->item_definition ||
				!stack_state_can_coalesce(*item, candidate_stack) ||
				candidate_stack.quantity >= item_def->max_stack) {
			continue;
		}
		const ContainerInstanceId stack_container = location_container(candidate_stack.location);
		const ContainerDefinition *stack_container_def = container_definition_for(destination_clone, *catalog_, stack_container);
		if (stack_container_def == nullptr || !container_has_feature(*stack_container_def, FEATURE_STACKING) ||
				!check_access(*stack_container_def, AccessFlag::INSERT).ok()) {
			continue;
		}
		const std::uint64_t room = item_def->max_stack - candidate_stack.quantity;
		const std::uint64_t transfer = room < remaining_to_place ? room : remaining_to_place;
		std::int64_t added_mg = 0;
		std::int64_t current_mg = 0;
		std::int64_t projected_mg = 0;
		if (!checked_mul_i64(item_def->unit_mass_mg, static_cast<std::int64_t>(transfer), added_mg).ok() ||
				!destination_clone.container_mass(stack_container, current_mg).ok() ||
				!checked_add_i64(current_mg, added_mg, projected_mg).ok() ||
				!check_mass_capacity(destination_clone, stack_container, projected_mg).ok()) {
			continue;
		}
		const std::uint64_t new_stack_quantity = candidate_stack.quantity + transfer;
		status = destination_clone.set_quantity(pair.first, new_stack_quantity);
		if (!status.ok()) {
			return reject(result, status);
		}
		ops_by_inventory[p_command.destination].push_back(DeltaOp{ ItemQuantityOp{ pair.first.value, new_stack_quantity } });
		remaining_to_place -= transfer;
		merged_amount += transfer;
	}

	// Strategy step 2: auto-place the remainder (AutoPlaceItemCommand's
	// candidate order). Nothing merged at all -> the WHOLE item relocates,
	// preserving identity and any subtree (a backpack-like item can never
	// merge -- max_stack is always 1 for a stacking-incompatible provided-
	// container item -- so this is exactly the path such an item takes).
	// Otherwise the leftover becomes a brand-new destination stack. Items
	// owning provided containers never enter the merge path above, so they
	// always relocate as a complete subtree or fail atomically.
	ItemInstanceId new_instance_id;
	bool whole_item_relocated = false;
	ContainerInstanceId final_container;
	if (remaining_to_place > 0) {
		if (merged_amount == 0) {
			if (same_inventory) {
				ItemLocation candidate;
				if (find_reorganize_candidate(source_clone, *catalog_, p_command.item, ContainerInstanceId{}, candidate).ok()) {
					status = source_clone.move_item(p_command.item, candidate);
					if (!status.ok()) {
						return reject(result, status);
					}
					remaining_to_place = 0;
					whole_item_relocated = true;
					final_container = location_container(candidate);
					append_item_moved(source_clone, p_command.item, ops_by_inventory[p_command.source]);
				}
			} else {
				ItemLocation candidate;
				if (find_arrival_candidate(destination_clone, *catalog_, *item_def, original_quantity, ContainerInstanceId{}, candidate).ok()) {
					std::vector<ItemSubtreeEntry> items;
					std::vector<ContainerSubtreeEntry> containers;
					std::vector<ReferenceId> cleared_references;
					status = source_clone.release_item_subtree(p_command.item, items, containers, cleared_references);
					if (!status.ok()) {
						return reject(result, status);
					}
					status = destination_clone.adopt_item_subtree(items, containers, candidate);
					if (!status.ok()) {
						return reject(result, status);
					}
					remaining_to_place = 0;
					whole_item_relocated = true;
					final_container = location_container(candidate);
					append_subtree_released(items, containers, cleared_references, ops_by_inventory[p_command.source]);
					append_subtree_created(items, containers, candidate, ops_by_inventory[p_command.destination]);
				}
			}
		} else {
			ItemLocation candidate;
			if (find_arrival_candidate(destination_clone, *catalog_, *item_def, remaining_to_place, ContainerInstanceId{}, candidate).ok()) {
				status = destination_clone.create_item(identifier, remaining_to_place, candidate, new_instance_id);
				if (!status.ok()) {
					return reject(result, status);
				}
				status = copy_mutable_component_state(*item, destination_clone, new_instance_id);
				if (!status.ok()) {
					return reject(result, status);
				}
				remaining_to_place = 0;
				final_container = location_container(candidate);
				append_item_created(destination_clone, new_instance_id, ops_by_inventory[p_command.destination]);
			}
		}
	}

	// Reconcile the source item: whole_item_relocated already moved/adopted
	// it (nothing further to do); otherwise reduce it by whatever left via
	// merges and/or a new instance, destroying it if fully consumed.
	if (!whole_item_relocated) {
		const std::uint64_t total_consumed = original_quantity - remaining_to_place;
		if (total_consumed > 0) {
			if (total_consumed == original_quantity) {
				std::vector<ItemSubtreeEntry> items;
				std::vector<ContainerSubtreeEntry> containers;
				std::vector<ReferenceId> cleared_references;
				status = source_clone.release_item_subtree(p_command.item, items, containers, cleared_references);
				if (!status.ok()) {
					return reject(result, status);
				}
				append_subtree_released(items, containers, cleared_references, ops_by_inventory[p_command.source]);
			} else {
				const std::uint64_t reduced_quantity = original_quantity - total_consumed;
				status = source_clone.set_quantity(p_command.item, reduced_quantity);
				if (!status.ok()) {
					return reject(result, status);
				}
				ops_by_inventory[p_command.source].push_back(DeltaOp{ ItemQuantityOp{ p_command.item.value, reduced_quantity } });
			}
		}
	}

	const std::uint64_t transferred = original_quantity - remaining_to_place;
	// A zero-effect quick transfer is not a meaningful "partial success"
	// regardless of allow_partial; a nonzero-but-incomplete transfer only
	// commits when the caller explicitly opted into partial results
	// (inventory-transactions spec: "rejects atomically unless the command
	// explicitly permits a bounded partial result").
	if (transferred == 0) {
		return reject(result, make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::QUICK_TRANSFER_INCOMPLETE, p_command.item.value));
	}
	if (remaining_to_place > 0 && !p_command.allow_partial) {
		return reject(result, make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::QUICK_TRANSFER_INCOMPLETE, remaining_to_place));
	}

	result.transferred_quantity = transferred;
	result.remaining_quantity = remaining_to_place;
	result.new_item_id = new_instance_id;
	result.events.push_back(TransactionEvent{
			(whole_item_relocated && !same_inventory) ? TransactionEventKind::LOOTED : TransactionEventKind::MOVED,
			p_command.item,
			new_instance_id,
			original_container,
			final_container,
			ReferenceId{} });

	return finish_multi(touched, runtimes, clones, p_header, p_payload_fingerprint, result, std::move(ops_by_inventory));
}

// --- targeted provider transfer --------------------------------------------

Status InventoryTransactionPipeline::simulate_targeted_provider_transfer(
		InventoryRuntime &p_source_clone,
		InventoryRuntime &p_destination_clone,
		const TargetedProviderTransferCommand &p_command,
		TransactionResult &r_result,
		std::map<InventoryId, std::vector<DeltaOp>> &r_ops_by_inventory,
		ContainerInstanceId &r_destination_container) const {
	if (!p_command.source || !p_command.destination || !p_command.item || !p_command.destination_provider) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}

	const bool same_inventory = p_command.source == p_command.destination;
	if (same_inventory && p_command.item == p_command.destination_provider) {
		return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_command.item.value);
	}

	const ItemInstance *source_item = p_source_clone.find_item(p_command.item);
	if (source_item == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_command.item.value);
	}
	const ItemDefinition *source_item_def = item_definition_for(p_source_clone, *catalog_, p_command.item);
	if (source_item_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, p_command.item.value);
	}
	const ItemInstance source_item_before = *source_item;
	const std::uint64_t original_quantity = source_item_before.quantity;
	const ContainerInstanceId original_container = location_container(source_item_before.location);
	const ContainerDefinition *source_container_def =
			container_definition_for(p_source_clone, *catalog_, original_container);
	if (source_container_def == nullptr) {
		return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, original_container.value);
	}

	const ItemInstance *provider = p_destination_clone.find_item(p_command.destination_provider);
	if (provider == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_command.destination_provider.value);
	}

	// A same-inventory source cannot be placed into a provider nested anywhere
	// below that source. Detect this before stack simulation so the primary
	// rejection remains the containment-cycle reason rather than a generic
	// exhausted-candidate result.
	if (same_inventory) {
		ItemInstanceId cursor = p_command.destination_provider;
		const std::size_t hop_limit = p_destination_clone.items().size() + 2;
		for (std::size_t hop = 0; cursor && hop < hop_limit; ++hop) {
			if (cursor == p_command.item) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, p_command.item.value);
			}
			const ItemInstance *cursor_item = p_destination_clone.find_item(cursor);
			if (cursor_item == nullptr) {
				return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, cursor.value);
			}
			const ContainerInstance *owner =
					p_destination_clone.find_container(location_container(cursor_item->location));
			if (owner == nullptr || !owner->provider_item) {
				cursor = ItemInstanceId{};
				break;
			}
			cursor = owner->provider_item;
		}
		if (cursor) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CONTAINMENT_CYCLE, cursor.value);
		}
	}

	// The scope comes only from the canonical provider record. Verify both
	// directions of the provider/container relationship defensively and sort
	// by the stable instance identity required by the command contract.
	// Unlike an untargeted AutoPlace command, explicit selection of the
	// provider is the opt-in; its materialized containers need not also set
	// allow_auto_placement.
	std::vector<ContainerInstanceId> scope;
	scope.reserve(provider->provided_containers.size());
	for (ContainerInstanceId provided : provider->provided_containers) {
		const ContainerInstance *container = p_destination_clone.find_container(provided);
		if (container == nullptr || container->provider_item != p_command.destination_provider) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::ITEM_CONTAINER_MISSING, provided.value);
		}
		const ContainerDefinition *container_def =
				container_definition_for(p_destination_clone, *catalog_, provided);
		if (container_def == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, provided.value);
		}
		scope.push_back(provided);
	}
	std::sort(scope.begin(), scope.end());
	scope.erase(std::unique(scope.begin(), scope.end()), scope.end());
	if (scope.empty()) {
		return make_status(
				StatusCode::COMMAND_REJECTED,
				DiagnosticId::PLACEMENT_CANDIDATE_EXHAUSTED,
				p_command.destination_provider.value);
	}
	const std::set<ContainerInstanceId> scoped_containers(scope.begin(), scope.end());

	Status first_rejection = make_status(
			StatusCode::COMMAND_REJECTED,
			DiagnosticId::PLACEMENT_CANDIDATE_EXHAUSTED,
			p_command.destination_provider.value);
	bool captured_rejection = false;
	const auto capture_rejection = [&](Status p_status) {
		if (!p_status.ok() && !captured_rejection) {
			first_rejection = p_status;
			captured_rejection = true;
		}
	};

	std::uint64_t remaining_to_place = original_quantity;
	std::uint64_t merged_amount = 0;
	ContainerInstanceId last_merge_container;

	// Provided-container items carry a subtree and must move as a whole; they
	// are never converted into quantity-only stack records even if a hostile
	// catalog declares an unusual max_stack greater than one.
	if (source_item_before.provided_containers.empty()) {
		for (const auto &pair : p_destination_clone.items()) {
			if (remaining_to_place == 0) {
				break;
			}
			if (same_inventory && pair.first == p_command.item) {
				continue;
			}
			const ItemInstance &candidate_stack = pair.second;
			const ContainerInstanceId stack_container = location_container(candidate_stack.location);
			if (scoped_containers.find(stack_container) == scoped_containers.end() ||
					candidate_stack.item_definition != source_item_before.item_definition ||
					candidate_stack.quantity >= source_item_def->max_stack ||
					!stack_state_can_coalesce(source_item_before, candidate_stack)) {
				continue;
			}
			const ContainerDefinition *stack_container_def =
					container_definition_for(p_destination_clone, *catalog_, stack_container);
			if (stack_container_def == nullptr ||
					!container_has_feature(*stack_container_def, FEATURE_STACKING)) {
				continue;
			}

			Status status = original_container == stack_container && same_inventory ?
					check_access(*stack_container_def, AccessFlag::MOVE) :
					check_access(*source_container_def, AccessFlag::REMOVE);
			if (status.ok() && !(original_container == stack_container && same_inventory)) {
				status = check_access(*stack_container_def, AccessFlag::INSERT);
			}
			if (!status.ok()) {
				capture_rejection(status);
				continue;
			}

			const std::uint64_t room = source_item_def->max_stack - candidate_stack.quantity;
			const std::uint64_t transfer = std::min(room, remaining_to_place);
			if (!(same_inventory && original_container == stack_container)) {
				std::int64_t added_mg = 0;
				std::int64_t current_mg = 0;
				std::int64_t projected_mg = 0;
				status = checked_mul_i64(
						source_item_def->unit_mass_mg,
						static_cast<std::int64_t>(transfer),
						added_mg);
				if (status.ok()) {
					status = p_destination_clone.container_mass(stack_container, current_mg);
				}
				if (status.ok()) {
					status = checked_add_i64(current_mg, added_mg, projected_mg);
				}
				if (status.ok()) {
					status = check_mass_capacity(p_destination_clone, stack_container, projected_mg);
				}
				if (!status.ok()) {
					capture_rejection(status);
					continue;
				}
			}

			const std::uint64_t new_stack_quantity = candidate_stack.quantity + transfer;
			status = p_destination_clone.set_quantity(pair.first, new_stack_quantity);
			if (!status.ok()) {
				return status;
			}
			r_ops_by_inventory[p_command.destination].push_back(
					DeltaOp{ ItemQuantityOp{ pair.first.value, new_stack_quantity } });
			remaining_to_place -= transfer;
			merged_amount += transfer;
			last_merge_container = stack_container;
		}
	}

	ItemInstanceId new_instance_id;
	bool whole_item_relocated = false;

	if (merged_amount > 0) {
		// The original identity is consumed by the scoped merge strategy. If a
		// remainder exists it is recreated only after the source record has
		// left, which makes same-container geometry and mass checks model the
		// final state rather than temporarily double-counting the source.
		std::vector<ItemSubtreeEntry> released_items;
		std::vector<ContainerSubtreeEntry> released_containers;
		std::vector<ReferenceId> cleared_references;
		Status status = p_source_clone.release_item_subtree(
				p_command.item,
				released_items,
				released_containers,
				cleared_references);
		if (!status.ok()) {
			return status;
		}
		append_subtree_released(
				released_items,
				released_containers,
				cleared_references,
				r_ops_by_inventory[p_command.source]);

		if (remaining_to_place > 0) {
			InventoryRuntime accepted_destination;
			bool accepted_candidate = false;
			ItemLocation candidate;
			const std::function<bool(const ItemLocation &)> test =
					[&](const ItemLocation &p_candidate) {
						InventoryRuntime candidate_destination = p_destination_clone;
						Status candidate_status = evaluate_arrival(
								candidate_destination,
								*catalog_,
								*source_item_def,
								p_candidate,
								remaining_to_place);
						if (candidate_status.ok()) {
							candidate_status = candidate_destination.fits(
									source_item_def->identifier,
									p_candidate,
									remaining_to_place,
									ItemInstanceId{});
						}
						ItemInstanceId candidate_item;
						if (candidate_status.ok()) {
							candidate_status = candidate_destination.create_item(
									source_item_def->identifier,
									remaining_to_place,
									p_candidate,
									candidate_item);
						}
						if (candidate_status.ok()) {
							candidate_status = copy_mutable_component_state(
									source_item_before,
									candidate_destination,
									candidate_item);
						}
						if (!candidate_status.ok()) {
							capture_rejection(candidate_status);
							return false;
						}
						new_instance_id = candidate_item;
						accepted_destination = std::move(candidate_destination);
						accepted_candidate = true;
						return true;
					};
			status = search_auto_place_candidates(
					p_destination_clone,
					*catalog_,
					*source_item_def,
					ContainerInstanceId{},
					&scope,
					test,
					candidate);
			if (!status.ok() || !accepted_candidate) {
				return captured_rejection ? first_rejection : status;
			}
			p_destination_clone = std::move(accepted_destination);
			r_destination_container = location_container(candidate);
			append_item_created(
					p_destination_clone,
					new_instance_id,
					r_ops_by_inventory[p_command.destination]);
		} else {
			r_destination_container = last_merge_container;
		}
	} else {
		ItemLocation candidate;
		Status status;
		if (same_inventory) {
			InventoryRuntime accepted_inventory;
			bool accepted_candidate = false;
			const std::function<bool(const ItemLocation &)> test =
					[&](const ItemLocation &p_candidate) {
						InventoryRuntime candidate_inventory = p_source_clone;
						Status candidate_status = evaluate_move_like(
								candidate_inventory,
								*catalog_,
								p_command.item,
								p_candidate);
						if (candidate_status.ok()) {
							candidate_status = candidate_inventory.move_item(
									p_command.item,
									p_candidate);
						}
						if (!candidate_status.ok()) {
							capture_rejection(candidate_status);
							return false;
						}
						accepted_inventory = std::move(candidate_inventory);
						accepted_candidate = true;
						return true;
					};
			status = search_auto_place_candidates(
					p_destination_clone,
					*catalog_,
					*source_item_def,
					ContainerInstanceId{},
					&scope,
					test,
					candidate);
			if (!status.ok() || !accepted_candidate) {
				return captured_rejection ? first_rejection : status;
			}
			p_source_clone = std::move(accepted_inventory);
			r_destination_container = location_container(candidate);
			append_item_moved(
					p_source_clone,
					p_command.item,
					r_ops_by_inventory[p_command.source]);
			whole_item_relocated = true;
		} else {
			Status source_access = check_access(*source_container_def, AccessFlag::REMOVE);
			if (!source_access.ok()) {
				return source_access;
			}
			std::int64_t subtree_mass = 0;
			status = p_source_clone.item_subtree_mass(p_command.item, subtree_mass);
			if (!status.ok()) {
				return status;
			}

			InventoryRuntime accepted_source;
			InventoryRuntime accepted_destination;
			std::vector<ItemSubtreeEntry> accepted_items;
			std::vector<ContainerSubtreeEntry> accepted_containers;
			std::vector<ReferenceId> accepted_cleared_references;
			bool accepted_candidate = false;
			const std::function<bool(const ItemLocation &)> test =
					[&](const ItemLocation &p_candidate) {
						InventoryRuntime candidate_source = p_source_clone;
						InventoryRuntime candidate_destination = p_destination_clone;
						const ContainerInstanceId candidate_container =
								location_container(p_candidate);
						const ContainerDefinition *candidate_def =
								container_definition_for(candidate_destination, *catalog_, candidate_container);
						Status candidate_status = candidate_def == nullptr ?
								make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, candidate_container.value) :
								check_access(*candidate_def, AccessFlag::INSERT);
						if (candidate_status.ok()) {
							std::int64_t destination_mass = 0;
							std::int64_t projected_mass = 0;
							candidate_status = candidate_destination.container_mass(
									candidate_container,
									destination_mass);
							if (candidate_status.ok()) {
								candidate_status = checked_add_i64(
										destination_mass,
										subtree_mass,
										projected_mass);
							}
							if (candidate_status.ok()) {
								candidate_status = check_mass_capacity(
										candidate_destination,
										candidate_container,
										projected_mass);
							}
							if (candidate_status.ok()) {
								candidate_status = check_retention(*candidate_def);
							}
						}

						std::vector<ItemSubtreeEntry> items;
						std::vector<ContainerSubtreeEntry> containers;
						std::vector<ReferenceId> cleared_references;
						if (candidate_status.ok()) {
							candidate_status = candidate_source.release_item_subtree(
									p_command.item,
									items,
									containers,
									cleared_references);
						}
						if (candidate_status.ok()) {
							candidate_status = candidate_destination.adopt_item_subtree(
									items,
									containers,
									p_candidate);
						}
						if (!candidate_status.ok()) {
							capture_rejection(candidate_status);
							return false;
						}
						accepted_source = std::move(candidate_source);
						accepted_destination = std::move(candidate_destination);
						accepted_items = std::move(items);
						accepted_containers = std::move(containers);
						accepted_cleared_references = std::move(cleared_references);
						accepted_candidate = true;
						return true;
					};
			status = search_auto_place_candidates(
					p_destination_clone,
					*catalog_,
					*source_item_def,
					ContainerInstanceId{},
					&scope,
					test,
					candidate);
			if (!status.ok() || !accepted_candidate) {
				return captured_rejection ? first_rejection : status;
			}
			p_source_clone = std::move(accepted_source);
			p_destination_clone = std::move(accepted_destination);
			r_destination_container = location_container(candidate);
			append_subtree_released(
					accepted_items,
					accepted_containers,
					accepted_cleared_references,
					r_ops_by_inventory[p_command.source]);
			append_subtree_created(
					accepted_items,
					accepted_containers,
					candidate,
					r_ops_by_inventory[p_command.destination]);
			whole_item_relocated = true;
		}
	}

	if (remaining_to_place > 0 && merged_amount == 0 && !whole_item_relocated) {
		return captured_rejection ? first_rejection :
				make_status(
						StatusCode::COMMAND_REJECTED,
						DiagnosticId::PLACEMENT_CANDIDATE_EXHAUSTED,
						p_command.destination_provider.value);
	}
	if (remaining_to_place > 0 && merged_amount > 0 && !new_instance_id) {
		return captured_rejection ? first_rejection :
				make_status(
						StatusCode::COMMAND_REJECTED,
						DiagnosticId::QUICK_TRANSFER_INCOMPLETE,
						remaining_to_place);
	}

	r_result.transferred_quantity = original_quantity;
	r_result.remaining_quantity = 0;
	r_result.new_item_id = new_instance_id;
	r_result.events.push_back(TransactionEvent{
			same_inventory ? TransactionEventKind::MOVED : TransactionEventKind::LOOTED,
			p_command.item,
			new_instance_id,
			original_container,
			r_destination_container,
			ReferenceId{} });
	return ok_status();
}

TransactionResult InventoryTransactionPipeline::run_targeted_provider_transfer(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const TargetedProviderTransferCommand &p_command,
		std::uint64_t p_payload_fingerprint) {
	TransactionResult result;
	result.command_id = p_header.command_id;

	std::vector<InventoryId> touched;
	std::vector<InventoryRuntime *> runtimes;
	std::vector<InventoryRuntime> clones;
	Status status = prepare_multi(
			p_inventories,
			p_header,
			Command{ p_command },
			{ p_command.source, p_command.destination },
			touched,
			runtimes,
			clones,
			result);
	if (!status.ok()) {
		return reject(result, status);
	}

	auto clone_for = [&](InventoryId p_id) -> InventoryRuntime & {
		for (std::size_t i = 0; i < touched.size(); ++i) {
			if (touched[i] == p_id) {
				return clones[i];
			}
		}
		return clones[0];
	};
	std::map<InventoryId, std::vector<DeltaOp>> ops_by_inventory;
	ContainerInstanceId destination_container;
	status = simulate_targeted_provider_transfer(
			clone_for(p_command.source),
			clone_for(p_command.destination),
			p_command,
			result,
			ops_by_inventory,
			destination_container);
	if (!status.ok()) {
		return reject(result, status);
	}
	return finish_multi(
			touched,
			runtimes,
			clones,
			p_header,
			p_payload_fingerprint,
			result,
			std::move(ops_by_inventory));
}

TargetedProviderTransferPreview InventoryTransactionPipeline::preview_targeted_provider_transfer(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const TargetedProviderTransferCommand &p_command) const {
	TargetedProviderTransferPreview preview;
	TransactionResult scratch;
	scratch.command_id = p_header.command_id;

	if (quantity_reservations_ != nullptr &&
			quantity_reservations_->conflicts(Command{ p_command }, nullptr)) {
		preview.status = make_status(
				StatusCode::COMMAND_REJECTED,
				DiagnosticId::RESERVATION_CONFLICT);
		return preview;
	}

	std::vector<InventoryId> touched;
	std::vector<InventoryRuntime *> runtimes;
	std::vector<InventoryRuntime> clones;
	Status status = prepare_multi(
			p_inventories,
			p_header,
			Command{ p_command },
			{ p_command.source, p_command.destination },
			touched,
			runtimes,
			clones,
			scratch);
	if (!status.ok()) {
		preview.status = status;
		preview.conflicting_inventory = scratch.conflicting_inventory;
		preview.authoritative_revision = scratch.authoritative_revision;
		return preview;
	}

	auto clone_for = [&](InventoryId p_id) -> InventoryRuntime & {
		for (std::size_t i = 0; i < touched.size(); ++i) {
			if (touched[i] == p_id) {
				return clones[i];
			}
		}
		return clones[0];
	};
	std::map<InventoryId, std::vector<DeltaOp>> ignored_ops;
	ContainerInstanceId destination_container;
	status = simulate_targeted_provider_transfer(
			clone_for(p_command.source),
			clone_for(p_command.destination),
			p_command,
			scratch,
			ignored_ops,
			destination_container);
	if (status.ok()) {
		for (const InventoryRuntime &clone : clones) {
			status = clone.validate_invariants();
			if (!status.ok()) {
				break;
			}
		}
	}
	preview.status = status;
	preview.valid = status.ok();
	if (preview.valid) {
		preview.destination_container = destination_container;
		preview.transferred_quantity = scratch.transferred_quantity;
	}
	return preview;
}

// --- dispatch()/dispatch_multi(): command-bucket routing --------------------

TransactionResult InventoryTransactionPipeline::dispatch_multi(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const Command &p_command) {
	TransactionResult result;
	result.command_id = p_header.command_id;

	if (!p_header.command_id) {
		return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE));
	}

	// Idempotency cache-hit short-circuit -- identical role and ordering
	// rationale as dispatch_single()'s, shared here because all four
	// multi-inventory command types fall through this one entry point.
	const std::uint64_t incoming_fingerprint = payload_fingerprint(p_command);
	const auto idempotent = idempotency_index_.find(p_header.command_id);
	if (idempotent != idempotency_index_.end()) {
		if (idempotent->second.payload_fingerprint == incoming_fingerprint) {
			// Replay the recorded accepted result without re-emitting its
			// events: they were observable exactly once, on first accept
			// (zerkov_v1 duplicate_command_replays_result: events=0,
			// status=duplicate_result_replay).
			TransactionResult replay = idempotent->second.result;
			replay.status = make_status(StatusCode::OK, DiagnosticId::DUPLICATE_RESULT_REPLAY, replay.events.size());
			replay.events.clear();
			replay.deltas.clear();
			replay.replayed = true;
			return replay;
		}
		return reject(result, make_status(StatusCode::DUPLICATE_COMMAND, DiagnosticId::IDEMPOTENCY_PAYLOAD_MISMATCH, incoming_fingerprint));
	}

	// SplitStackCommand (the only quantity-aware conflicts() case) is
	// single-inventory only and never reaches dispatch_multi(); nullptr is
	// correct here (see conflicts()'s doc comment).
	if (quantity_reservations_ != nullptr &&
			quantity_reservations_->conflicts(p_command, nullptr)) {
		return reject(result, make_status(
				StatusCode::COMMAND_REJECTED,
				DiagnosticId::RESERVATION_CONFLICT));
	}

	if (const LootItemCommand *loot = std::get_if<LootItemCommand>(&p_command)) {
		return run_loot(p_inventories, p_header, *loot, incoming_fingerprint);
	}
	if (const SettleInventoryCommand *settle = std::get_if<SettleInventoryCommand>(&p_command)) {
		return run_settle(p_inventories, p_header, *settle, incoming_fingerprint);
	}
	if (const QuickTransferItemCommand *quick = std::get_if<QuickTransferItemCommand>(&p_command)) {
		return run_quick_transfer(p_inventories, p_header, *quick, incoming_fingerprint);
	}
	if (const TargetedProviderTransferCommand *targeted =
				std::get_if<TargetedProviderTransferCommand>(&p_command)) {
		return run_targeted_provider_transfer(
				p_inventories,
				p_header,
				*targeted,
				incoming_fingerprint);
	}
	return reject(result, make_status(StatusCode::INTERNAL_ERROR)); // unreachable: is_multi_inventory_command() gated the call.
}

TransactionResult InventoryTransactionPipeline::dispatch(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const Command &p_command) {
	if (is_multi_inventory_command(p_command)) {
		return dispatch_multi(p_inventories, p_header, p_command);
	}
	if (p_inventories.size() != 1 || p_inventories[0] == nullptr) {
		TransactionResult result;
		result.command_id = p_header.command_id;
		return reject(result, make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_inventories.size()));
	}
	return dispatch_single(*p_inventories[0], p_header, p_command);
}

// --- submit(): public entry points, reentrancy (tasks.md 5.9) --------------

TransactionResult InventoryTransactionPipeline::submit(InventoryRuntime &p_inventory, const CommandHeader &p_header, const Command &p_command) {
	return submit(std::vector<InventoryRuntime *>{ &p_inventory }, p_header, p_command);
}

TransactionResult InventoryTransactionPipeline::submit_immediate(InventoryRuntime &p_inventory,
		const CommandHeader &p_header, const Command &p_command) {
	return submit_immediate(std::vector<InventoryRuntime *>{ &p_inventory }, p_header, p_command);
}

TransactionResult InventoryTransactionPipeline::submit_immediate(
		const std::vector<InventoryRuntime *> &p_inventories,
		const CommandHeader &p_header,
		const Command &p_command) {
	if (executing_) {
		TransactionResult rejected;
		rejected.command_id = p_header.command_id;
		rejected.accepted = false;
		rejected.status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::GATEWAY_REENTRANT);
		return rejected;
	}
	return submit(p_inventories, p_header, p_command);
}

TransactionResult InventoryTransactionPipeline::submit(const std::vector<InventoryRuntime *> &p_inventories, const CommandHeader &p_header, const Command &p_command) {
	if (executing_) {
		// Reentrant: called from inside an observer's notification callback
		// while an earlier submit() on this pipeline is still executing.
		// Queue instead of touching pipeline/runtime working state; the
		// synchronous caller only ever sees this immutable marker.
		if (pending_.size() >= MAX_PENDING_REENTRANT_TRANSACTIONS) {
			TransactionResult overflow;
			overflow.command_id = p_header.command_id;
			overflow.accepted = false;
			overflow.status = make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::PENDING_QUEUE_FULL, pending_.size());
			return overflow;
		}
		pending_.push_back(PendingSubmission{ p_inventories, p_header, p_command });
		TransactionResult queued;
		queued.command_id = p_header.command_id;
		queued.accepted = false;
		queued.queued = true;
		queued.status = make_status(StatusCode::OK, DiagnosticId::TRANSACTION_QUEUED);
		return queued;
	}

	executing_ = true;
	const TransactionResult result = dispatch(p_inventories, p_header, p_command);

	// Drain FIFO. executing_ stays true for the WHOLE loop, so a queued
	// command's own notify() reentrantly submitting yet another command
	// enqueues into this SAME pending_ (appended to the back, picked up by
	// a later iteration of this very loop) instead of recursing -- pure
	// FIFO regardless of how deep the reentrant chain goes. Each drained
	// command runs the complete ordered pipeline (re-validating its own
	// expected_revisions against whatever is current by the time it
	// actually executes); its result is delivered to observers only via
	// dispatch()'s own notify() call and is not returned to anything here.
	while (!pending_.empty()) {
		PendingSubmission next = std::move(pending_.front());
		pending_.pop_front();
		dispatch(next.inventories, next.header, next.command);
	}
	executing_ = false;

	return result;
}

} // namespace inv
