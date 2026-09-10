#ifndef INVENTORY_SYSTEM_CORE_RUNTIME_STATE_H
#define INVENTORY_SYSTEM_CORE_RUNTIME_STATE_H

#include "core/inv_catalog.h"
#include "core/inv_definitions.h"
#include "core/inv_identity_authority.h"
#include "core/inv_ids.h"
#include "core/inv_identifier.h"
#include "core/inv_status.h"

#include <cstdint>
#include <map>
#include <string>
#include <variant>
#include <vector>

// Canonical, engine-free runtime state for one inventory: the mutable side of
// the sealed DefinitionCatalog. Every collection here is a std::map keyed by
// a stable handle/identifier or a vector produced in canonical (ascending
// handle or definition-identifier) order, so two identical primitive
// sequences on identically-built inventories always produce byte-identical
// observable state. Nothing here depends on Godot, wall-clock time, random
// iteration order, or pointer identity.
//
// This file implements tasks 4.2-4.4 (the state model, structural
// invariants, and low-level validate-then-mutate primitives that a later
// transaction pipeline in tasks.md 5.x will drive), 4.5 (checked mass/
// capacity/fit derived queries, core/inv_checked_math.h), 4.7 (the bounded
// invariant audit walker), and the read-only accessors + restore builder
// core/inv_snapshot.{h,cpp} (task 4.6) needs to construct and validate a
// candidate runtime without exposing any mutable internal map.
namespace inv {

// Forward declaration only (never an #include -- core never depends on
// protocol; see native/tests/check_boundaries.py). Named here so
// InventoryRuntime can grant it friend access to the replica-only raw
// record primitives below (tasks.md 6.4), the same "extend the friend
// list" pattern InventoryTransactionPipeline already uses.
namespace protocol {
class InventoryReplica;
} // namespace protocol

// --- Location model ---------------------------------------------------
//
// Every item has exactly one owning location, modeled as a variant over the
// three V1 ownership layouts. `container` on every alternative names the
// ContainerInstance that owns the placement.

struct SpatialPlacement {
	ContainerInstanceId container;
	std::uint32_t x = 0;
	std::uint32_t y = 0;
	bool rotated = false;
};

struct SlotPlacement {
	ContainerInstanceId container;
	// Stable NamedSlotDefinition::identifier from the sealed catalog. Slots
	// are catalog-declared, not runtime-allocated, so no runtime SlotId
	// handle is minted for them (see report/design notes).
	std::string slot_identifier;
};

struct ListPlacement {
	ContainerInstanceId container;
	std::uint32_t ordinal = 0;
};

using ItemLocation = std::variant<SpatialPlacement, SlotPlacement, ListPlacement>;

// Returns the owning ContainerInstanceId regardless of which layout the
// location holds.
ContainerInstanceId location_container(const ItemLocation &p_location);

// --- Instances -----------------------------------------------------------

struct MutableComponent {
	std::string component_identifier;
	std::vector<std::uint8_t> payload;
};

struct ItemInstance {
	ItemInstanceId id;
	DefinitionId item_definition = INVALID_DEFINITION_ID;
	std::uint64_t quantity = 1;
	// Canonical ascending order by component_identifier; see set_component().
	std::vector<MutableComponent> mutable_components;
	ItemLocation location = SpatialPlacement{};
	// ContainerInstanceIds this item provides (rigs/backpacks/cases/secure
	// containers), in ascending id order, which is also the sorted
	// provided_containers identifier order from the item definition. Empty
	// for items that provide nothing.
	std::vector<ContainerInstanceId> provided_containers;
};

struct ContainerInstance {
	ContainerInstanceId id;
	DefinitionId container_definition = INVALID_DEFINITION_ID;
	// Invalid (zero) for a profile root container. Otherwise the item whose
	// definition provides this container; the container has no location of
	// its own and moves implicitly with that item (see move_item()).
	ItemInstanceId provider_item;
};

// Forward declaration only. The transaction pipeline (tasks.md 5.x) is a
// later slice; this header reserves the hook it will need without
// implementing it.
class InventoryTransactionPipeline;
class PreparedQuantityReservations;

// One invariant-audit violation (task 4.7, InventoryRuntime::
// audit_invariants()). container_raw/item_raw/reference_raw carry the
// offending handle's raw value in whichever domain(s) the check that
// produced `status` was scoped to; a domain that does not apply to this
// finding is left at 0 (0 is never a valid handle in any domain, so it
// doubles as "not applicable").
struct InvariantFinding {
	Status status;
	std::uint64_t container_raw = 0;
	std::uint64_t item_raw = 0;
	std::uint64_t reference_raw = 0;
};

// One verbatim-transferred record plus the portable string identifier of
// its DefinitionId (tasks.md 5.4: InventoryRuntime::adopt_item_subtree()/
// release_item_subtree()). The identifier travels alongside the instance
// because the receiving runtime may never have resolved that DefinitionId
// before (its item_definition_cache_/container_definition_cache_ is
// populated lazily, per-runtime) even though both runtimes share the same
// DefinitionCatalog.
struct ItemSubtreeEntry {
	ItemInstance instance;
	std::string definition_identifier;
};

struct ContainerSubtreeEntry {
	ContainerInstance instance;
	std::string definition_identifier;
};

class InventoryRuntime {
public:
	InventoryRuntime() = default;

	// Builds a new inventory from a sealed catalog and one of its registered
	// profiles. Instantiates the profile's root containers as
	// ContainerInstance records; the inventory starts empty (no items, no
	// references) at revision 0. p_inventory_id is allocated by the caller's
	// own (inventory-scoped, cross-inventory) authority and must be valid.
	//
	// p_authority is non-owning and optional (default nullptr): when
	// present, ALL item/container/reference id allocation for this runtime
	// goes through the shared IdentityAuthority instead of this runtime's
	// own private allocators (tasks.md 5.4 -- see core/
	// inv_identity_authority.h). p_authority MUST outlive this runtime.
	// Every pre-5.4 call site omits this parameter and is unaffected: the
	// private allocators remain the fallback for the single-inventory path.
	static Status create(
			const DefinitionCatalog &p_catalog,
			const std::string &p_profile_identifier,
			InventoryId p_inventory_id,
			InventoryRuntime &r_runtime,
			IdentityAuthority *p_authority = nullptr);

	InventoryId id() const { return inventory_id; }
	DefinitionId profile_definition() const { return profile_definition_id; }
	std::uint64_t revision() const { return revision_counter; }
	const InventoryLimitsDefinition &limits() const { return limits_; }
	// Non-owning; nullptr when this runtime uses its own private allocators
	// (the pre-5.4 single-inventory path). InventoryTransactionPipeline
	// compares this across a multi-inventory command's targeted runtimes to
	// enforce "cross-inventory commands share one authority" (tasks.md 5.4).
	const IdentityAuthority *identity_authority() const { return authority_; }

	const std::map<ItemInstanceId, ItemInstance> &items() const { return items_; }
	const std::map<ContainerInstanceId, ContainerInstance> &containers() const { return containers_; }
	const std::map<ReferenceId, ItemInstanceId> &references() const { return references_; }

	const ItemInstance *find_item(ItemInstanceId p_item) const;
	const ContainerInstance *find_container(ContainerInstanceId p_container) const;

	// Canonical (ascending ItemInstanceId) order.
	std::vector<ItemInstanceId> items_in_container(ContainerInstanceId p_container) const;
	// Canonical (ascending ContainerInstanceId) order.
	std::vector<ContainerInstanceId> root_containers() const;

	// 0 for a root container; 1 + the depth of the container the provider
	// item currently occupies for a provided container. Returns UINT32_MAX
	// if the provider chain does not terminate at a root within a bounded
	// number of hops, which only happens if some other invariant has already
	// been broken (defensive; validate_invariants() reports this as
	// CONTAINMENT_CYCLE).
	std::uint32_t container_depth(ContainerInstanceId p_container) const;

	// --- Mutation primitives ---
	//
	// Every primitive fully validates the proposed change before making any
	// change to items_/containers_/references_/allocators. On any rejection,
	// state is left byte-identical to how it was before the call.

	Status create_item(
			const std::string &p_item_identifier,
			std::uint64_t p_quantity,
			const ItemLocation &p_location,
			ItemInstanceId &r_item_id);

	// Destroying a provider item cascades to its complete provided-container
	// subtree (per inventory-runtime spec: "Removing ... a provider item
	// MUST include its complete contained ownership subtree"): every
	// descendant item and container is destroyed too, and every reference to
	// any destroyed item is removed. See report for the rationale.
	Status destroy_item(ItemInstanceId p_item_id);

	Status move_item(ItemInstanceId p_item_id, const ItemLocation &p_new_location);

	// Atomically exchanges two distinct items' current locations. Added for
	// the transaction pipeline's SwapItems command (tasks.md 5.2): a plain
	// move_item()/move_item() pair cannot express "neither intermediate state
	// need be valid, only the final one" (inventory-transactions spec, "Swap
	// requires two moves"), because each move_item() call independently
	// validates against the OTHER item still occupying its pre-swap spot.
	// Fully validates the mutual exchange (both final placements, nesting,
	// and cycle safety) before mutating either item; on any rejection both
	// items are left byte-identical to their pre-call state.
	Status swap_items(ItemInstanceId p_item_a, ItemInstanceId p_item_b);

	Status set_quantity(ItemInstanceId p_item_id, std::uint64_t p_quantity);

	Status set_component(
			ItemInstanceId p_item_id,
			const std::string &p_component_identifier,
			std::vector<std::uint8_t> p_payload);
	Status remove_component(ItemInstanceId p_item_id, const std::string &p_component_identifier);

	Status add_reference(ItemInstanceId p_item_id, ReferenceId &r_reference_id);
	Status remove_reference(ReferenceId p_reference_id);

	// Cheap full structural audit: re-derives and checks every invariant
	// listed in design.md "Runtime state and invariants" that this slice
	// owns (uniqueness, placement validity, filters/cardinality, list
	// density, stack/component bounds, provider/container agreement,
	// acyclic/bounded nesting, no dangling references, aggregate bounds).
	// Returns the first violation found in canonical (container, then item,
	// then reference) order, or ok_status(). Delegates to audit_invariants()
	// (task 4.7) with p_max_findings == 1 so the two never drift apart.
	Status validate_invariants() const;

	// Bounded invariant audit (task 4.7): walks the same checks as
	// validate_invariants(), in the same canonical (aggregate bounds, then
	// container, then item, then reference) order, but instead of stopping
	// at the first violation it collects up to p_max_findings of them.
	// Returns ok_status() if none were found, otherwise the first finding's
	// Status (so validate_invariants() can delegate to this and return the
	// same thing).
	Status audit_invariants(std::vector<InvariantFinding> &r_findings, std::size_t p_max_findings = 64) const;

	// --- Derived queries (checked mass, capacity, and fit; task 4.5) ---
	//
	// Every query below is side-effect-free (const) and reports a structured
	// Status instead of ever wrapping/saturating an overflowed value or
	// inventing a capacity the catalog/profile never declared. See
	// inventory-runtime spec, "Checked Canonical Numeric State" and
	// "Deterministic Derived Queries".

	// Sum of p_item_id's own quantity * unit_mass_mg plus the mass of every
	// container it provides (recursively), each owned item counted exactly
	// once. Traversal follows the canonical ascending-id order items_/
	// containers_ (std::map) already iterate in, so the result is
	// traversal-order independent by construction. Checked at every add/mul;
	// on overflow returns a structured Status (StatusCode::ARITHMETIC_ERROR)
	// with r_out_mg left at 0, never a wrapped or saturated value.
	Status item_subtree_mass(ItemInstanceId p_item_id, std::int64_t &r_out_mg) const;
	// Sum of item_subtree_mass() for every item directly in p_container_id.
	Status container_mass(ContainerInstanceId p_container_id, std::int64_t &r_out_mg) const;
	// Sum of container_mass() for every root container: the complete
	// canonical item graph, each item counted exactly once.
	Status total_mass(std::int64_t &r_out_mg) const;

	// Reports p_container_id's declared mass capacity only if its container
	// definition has has_mass_capacity AND the profile that created this
	// inventory enables inventory.feature.mass_capacity; otherwise reports a
	// structured StatusCode::FEATURE_UNSUPPORTED result rather than
	// inventing a zero or infinite capacity.
	Status container_mass_capacity(ContainerInstanceId p_container_id, std::int64_t &r_out_mg) const;

	// Always-available occupancy count; no feature gate (counting is not a
	// capacity claim).
	Status count_in_container(ContainerInstanceId p_container_id, std::uint32_t &r_out_count) const;
	// Same feature-unavailable discipline as container_mass_capacity():
	// reports remaining headroom only if the container declares an explicit
	// (nonzero) item cap AND the profile enables
	// inventory.feature.count_capacity.
	Status remaining_count_capacity(ContainerInstanceId p_container_id, std::uint32_t &r_out_remaining) const;

	// Non-mutating placement query for a candidate item/location/quantity,
	// reusing the same validate_placement()/validate_nesting_target()
	// machinery the mutation primitives use. p_excluding_item lets a caller
	// ask "would this item fit here if moved", mirroring move_item()'s own
	// exclusion (pass the default invalid handle for a brand-new item).
	// Reports OK or the stable rejection Status; never mutates state or
	// advances the revision.
	Status fits(
			const std::string &p_item_definition_identifier,
			const ItemLocation &p_location,
			std::uint64_t p_quantity = 1,
			ItemInstanceId p_excluding_item = ItemInstanceId{}) const;

	// True if the profile that created this inventory enables
	// p_feature_identifier (e.g. inventory.feature.mass_capacity).
	bool has_feature(const std::string &p_feature_identifier) const;

	// --- Snapshot support (task 4.6) ---
	//
	// Read-only identity/allocator accessors plus the one restore entry
	// point core/inv_snapshot.cpp needs. None of these expose a mutable
	// internal map; restore_from_snapshot_parts() takes and returns complete
	// value types only.

	const std::string &profile_identifier() const { return profile_identifier_; }
	// 0 if this runtime has no catalog (should not happen once constructed
	// via create() or restore_from_snapshot_parts()) or the catalog is
	// unsealed.
	std::uint64_t manifest_fingerprint() const;
	// Reads through to the shared IdentityAuthority when one is set (see
	// identity_authority()), so a snapshot taken of an authority-backed
	// runtime records the SHARED counter, not a private one.
	std::uint64_t container_allocator_next_raw() const { return active_container_allocator().next_raw(); }
	std::uint64_t item_allocator_next_raw() const { return active_item_allocator().next_raw(); }
	std::uint64_t reference_allocator_next_raw() const { return active_reference_allocator().next_raw(); }
	// Portable identifier string for a resolved item/container DefinitionId
	// this runtime has already cached (root-container instantiation or
	// create_item()/restore_from_snapshot_parts()), or nullptr otherwise.
	const std::string *item_definition_identifier(DefinitionId p_id) const;
	const std::string *container_definition_identifier(DefinitionId p_id) const;
	// Resolved authored definitions for discovery/projection consumers. The
	// returned pointers are owned by the sealed catalog and remain valid for
	// the runtime's lifetime. nullptr means the instance is unknown, its
	// definition cache is invalid, or the container has no discovery policy.
	const ContainerDefinition *container_definition(ContainerInstanceId p_container) const;
	const DiscoveryPolicyDefinition *discovery_policy(ContainerInstanceId p_container) const;

	// Builds a candidate InventoryRuntime directly from already-resolved,
	// already-bounded snapshot parts (see core/inv_snapshot.cpp restore()).
	// No invariant audit runs here: on success r_runtime IS the candidate,
	// and a caller that needs defensive replacement (inv_snapshot::restore()
	// does exactly this) must audit it and swap it into the real target
	// itself. Fails closed -- r_runtime is left default-constructed -- if
	// p_catalog is unsealed, p_inventory_id is invalid, or an allocator
	// counter is inconsistent with the maximum handle already present in the
	// supplied maps (which would risk a future id collision).
	//
	// p_authority behaves exactly like create()'s parameter of the same
	// name. When set, the three allocator-next parameters CONVERGE into the
	// shared authority (advance it only if the recorded value exceeds the
	// authority's current counter) rather than being restored strictly:
	// restoring several inventories that share one authority is expected to
	// see the SAME live counter value repeated in every snapshot (each
	// snapshot() call reads the shared counter at the time it was taken), so
	// restoring them in any order converges to the max without the
	// ordering-sensitive rejection restore_from() enforces for a private,
	// single-inventory-scoped allocator. The per-inventory sanity check
	// (recorded counter >= the maximum handle actually present in THIS
	// inventory's own maps) still runs unconditionally, authority or not.
	static Status restore_from_snapshot_parts(
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
			IdentityAuthority *p_authority = nullptr);

private:
	// Reserved for the transaction pipeline (tasks.md 5.x), which alone may
	// advance the revision counter once a command commits, and (5.4) alone
	// drives cross-runtime subtree transfer via adopt_item_subtree()/
	// release_item_subtree() below. Mutation primitives in this file never
	// call any of these three.
	friend class InventoryTransactionPipeline;
	friend class PreparedQuantityReservations;

	// Reserved for InventoryReplica (protocol/inv_replica.h, tasks.md 6.4):
	// applying an already-decoded, already-authority-vetted InventoryDelta's
	// ops one at a time onto a clone, and (on success) directly setting the
	// clone's revision to the delta's declared successor and repointing its
	// authority_ back to the replica's own IdentityAuthority member. See the
	// replica_apply_*() primitives below for why these need friend access
	// rather than going through the public validate-then-mutate primitives.
	friend class protocol::InventoryReplica;

	std::uint64_t commit_revision();

	// Verbatim cross-runtime subtree transfer pair (tasks.md 5.4/5.5:
	// LootItem, DropItem, SettleInventory). Both runtimes in a transfer MUST
	// share one IdentityAuthority (InventoryTransactionPipeline enforces
	// this before ever calling either) so the moved ids can never collide
	// with a record already present on the receiving side.
	//
	// release_item_subtree() validates p_item_id exists, then REMOVES it and
	// its complete provided-container subtree from this runtime's storage
	// (items_/containers_), clearing any reference that pointed at a removed
	// item (same cascade discipline as destroy_item()), and returns the
	// removed records BY VALUE with their original ids and locations intact
	// -- r_items[0] is always the root item, matching collect_cascade()'s
	// existing root-first convention. r_cleared_references receives the ids
	// of every reference this call cascaded away (empty if none), so a
	// caller building a canonical delta record (core/inv_transaction.cpp) can
	// emit a REFERENCE_CLEARED op for each without re-deriving the cascade
	// set itself. On any rejection neither this runtime nor any output
	// parameter is touched.
	Status release_item_subtree(
			ItemInstanceId p_item_id,
			std::vector<ItemSubtreeEntry> &r_items,
			std::vector<ContainerSubtreeEntry> &r_containers,
			std::vector<ReferenceId> &r_cleared_references);

	// adopt_item_subtree() validates the ROOT item (p_items[0]) fits at
	// p_destination_location using the same placement/nesting/filter/count
	// discipline create_item() applies to a brand-new item (geometry,
	// trait filters, slot cardinality, list bounds, per-container item cap,
	// and nesting-target depth), plus a subtree-wide nesting-depth bound for
	// every transferred container computed structurally from the transfer
	// set itself (no dependency on the source runtime, which may already
	// have released these records). ACCESS and mass-capacity are NOT
	// re-checked here (mirrors every other primitive: those are
	// FEATURE-phase, access_mask/mass_capacity-aware checks the pipeline
	// runs before SIMULATE, not primitive-level concerns). Aggregate bounds
	// (limits_.max_items/max_containers) and an id-collision guard (every
	// incoming id must be absent from this runtime) are checked before any
	// mutation. On success every record in p_items/p_containers is inserted
	// verbatim (ids unchanged) except the root item's location, which
	// becomes p_destination_location. On any rejection this runtime is left
	// completely untouched.
	Status adopt_item_subtree(
			const std::vector<ItemSubtreeEntry> &p_items,
			const std::vector<ContainerSubtreeEntry> &p_containers,
			const ItemLocation &p_destination_location);

	// --- Replica raw record application (tasks.md 6.4) ---
	//
	// InventoryReplica's (protocol/inv_replica.h) per-op complement to
	// adopt_item_subtree()/release_item_subtree() above: where those two
	// transplant a COMPLETE subtree between two authority-shared runtimes in
	// one call, these ten mirror core/inv_deltas.h's ten DeltaOpKind
	// alternatives one-for-one, applied individually as a replica walks one
	// InventoryDelta::ops sequence in order. Each takes the op's EXACT
	// recorded id (never an allocator-assigned one) and performs ONLY the
	// checks raw record application itself needs (id collision/not-found,
	// unknown catalog definition, aggregate bound) -- deliberately NOT the
	// geometric/filter/nesting validation create_item()/move_item() apply,
	// because a delta's ops can pass through transiently "invalid"
	// intermediate states while being applied in the authority's own
	// emission order (a subtree descendant item's ITEM_CREATED referencing a
	// container its own CONTAINER_ADOPTED op has not run yet; an ITEM_MOVED
	// pair from a swap, neither half independently valid). Full structural
	// correctness across the WHOLE resulting inventory is instead re-
	// verified exactly once, by audit_invariants(), after every op in the
	// enclosing delta has applied -- see InventoryReplica::apply_delta().
	// On any rejection here this runtime is left completely untouched,
	// matching every other primitive's fail-closed discipline. Every
	// *_created/*_adopted/*_assigned insertion also converges (never
	// rewinds) this runtime's matching allocator counter to at least the
	// applied id, so a snapshot() taken later reports the same allocator-
	// next values an authority runtime that produced this exact id would
	// (needed for replica/authority canonical-byte convergence).
	//
	// ITEM_CREATED/ITEM_MOVED additionally reproduce create_item()'s/
	// move_item()'s ORDERED_LIST side effect of shifting sibling ordinals
	// (apply_list_insert()/redensify_list()), because a delta's ops never
	// carry a sibling's ordinal shift as its own separate op -- exactly the
	// same "built from p_clone's post-mutation state" discipline the
	// pipeline's own DELTA-EMISSION phase relies on the RECEIVING side to
	// replay (see native/tests/inv_test_deltas.cpp's apply_ops_manually(),
	// which calls the real move_item()/create_item() for the same reason).
	Status replica_apply_item_created(
			ItemInstanceId p_item,
			const std::string &p_item_definition_identifier,
			std::uint64_t p_quantity,
			const ItemLocation &p_location,
			std::vector<MutableComponent> p_mutable_components,
			std::vector<ContainerInstanceId> p_provided_containers);
	Status replica_apply_item_destroyed(ItemInstanceId p_item);
	Status replica_apply_item_moved(ItemInstanceId p_item, const ItemLocation &p_location);
	Status replica_apply_item_quantity(ItemInstanceId p_item, std::uint64_t p_quantity);
	Status replica_apply_item_component_set(ItemInstanceId p_item, MutableComponent p_component);
	Status replica_apply_item_component_removed(ItemInstanceId p_item, const std::string &p_component_identifier);
	Status replica_apply_container_adopted(
			ContainerInstanceId p_container,
			const std::string &p_container_definition_identifier,
			ItemInstanceId p_provider_item);
	Status replica_apply_container_released(ContainerInstanceId p_container);
	Status replica_apply_reference_assigned(ReferenceId p_reference, ItemInstanceId p_item);
	Status replica_apply_reference_cleared(ReferenceId p_reference);

	const ItemDefinition *item_definition_of(DefinitionId p_id) const;
	const ContainerDefinition *container_definition_of(DefinitionId p_id) const;

	// Active allocators: this runtime's own private allocator, or the
	// shared IdentityAuthority's when authority_ is set (create()'s
	// p_authority parameter) -- every id allocation and counter read for
	// this runtime goes through these so the two paths can never silently
	// diverge. Both overloads return the SAME referenced allocator; the
	// const overload exists only so const query methods (e.g.
	// container_allocator_next_raw()) can use it.
	HandleAllocator<ContainerInstanceId> &active_container_allocator() { return authority_ != nullptr ? authority_->containers : container_allocator; }
	const HandleAllocator<ContainerInstanceId> &active_container_allocator() const { return authority_ != nullptr ? authority_->containers : container_allocator; }
	HandleAllocator<ItemInstanceId> &active_item_allocator() { return authority_ != nullptr ? authority_->items : item_allocator; }
	const HandleAllocator<ItemInstanceId> &active_item_allocator() const { return authority_ != nullptr ? authority_->items : item_allocator; }
	HandleAllocator<ReferenceId> &active_reference_allocator() { return authority_ != nullptr ? authority_->references : reference_allocator; }
	const HandleAllocator<ReferenceId> &active_reference_allocator() const { return authority_ != nullptr ? authority_->references : reference_allocator; }

	std::uint32_t effective_container_item_cap(const ContainerDefinition &p_def) const;
	std::vector<ItemInstanceId> list_items_by_ordinal(ContainerInstanceId p_container) const;
	void apply_list_insert(ContainerInstanceId p_container, ItemInstanceId p_item, std::uint32_t p_ordinal);
	void redensify_list(ContainerInstanceId p_container);

	// p_excluding_item_2 defaults to the invalid (zero) handle, which never
	// matches a real item id, so every pre-existing call site (single
	// exclusion or none) is unaffected. swap_items() is the only caller that
	// supplies both: the moving item's own prior self-entry AND the other
	// swap participant currently squatting on the target cell/slot/ordinal,
	// both of which must be ignored by the same occupancy/cardinality/list
	// bound check for a same-container swap to validate correctly.
	Status validate_placement(
			const ItemLocation &p_location,
			ItemInstanceId p_excluding_item,
			const ItemDefinition &p_item_def,
			const ContainerInstance *&r_container,
			const ContainerDefinition *&r_container_def,
			ItemInstanceId p_excluding_item_2 = ItemInstanceId{}) const;
	Status validate_nesting_target(ContainerInstanceId p_container, const ContainerDefinition &p_container_def) const;
	Status check_no_cycle(ContainerInstanceId p_target, ItemInstanceId p_moving_item) const;
	Status validate_subtree_nesting_after_move(const ItemInstance &p_moving_item, ContainerInstanceId p_target_container) const;

	// Per-entity invariant checks shared by validate_invariants() and
	// audit_invariants() (task 4.7): each returns the first violation found
	// for that single container/item/reference, or ok_status(). Neither
	// duplicates the other's logic; both callers just loop these.
	Status validate_one_container(ContainerInstanceId p_container_id, const ContainerInstance &p_container) const;
	Status validate_one_item(ItemInstanceId p_item_id, const ItemInstance &p_item) const;
	Status validate_one_reference(ReferenceId p_reference_id, ItemInstanceId p_item_id) const;

	Status collect_cascade(
			ItemInstanceId p_root_item,
			std::vector<ItemInstanceId> &r_items,
			std::vector<ContainerInstanceId> &r_containers) const;
	std::vector<ContainerInstanceId> collect_subtree_containers(ItemInstanceId p_item) const;

	const DefinitionCatalog *catalog_ = nullptr;
	InventoryId inventory_id;
	DefinitionId profile_definition_id = INVALID_DEFINITION_ID;
	// Copied from the profile at create()/restore_from_snapshot_parts() time
	// (the same pattern limits_ already uses), so derived queries -- and
	// snapshot() -- never need to re-resolve the profile through the
	// catalog by DefinitionId (the catalog does not expose that reverse
	// lookup).
	std::string profile_identifier_;
	std::vector<std::string> enabled_features_;
	InventoryLimitsDefinition limits_;
	std::uint64_t revision_counter = 0;

	// Non-owning; nullptr for the pre-5.4 single-inventory path (see
	// identity_authority()/active_*_allocator()).
	IdentityAuthority *authority_ = nullptr;

	HandleAllocator<ContainerInstanceId> container_allocator;
	HandleAllocator<ItemInstanceId> item_allocator;
	HandleAllocator<ReferenceId> reference_allocator;

	std::map<ContainerInstanceId, ContainerInstance> containers_;
	std::map<ItemInstanceId, ItemInstance> items_;
	std::map<ReferenceId, ItemInstanceId> references_;

	// Caches of catalog-owned pointers, populated the first time this
	// runtime resolves a given identifier (root-container instantiation and
	// create_item()). Not canonical state: purely a derived lookup index
	// from DefinitionId back to the catalog's ItemDefinition/
	// ContainerDefinition, which the catalog's public API does not expose
	// directly (see report). catalog_ must outlive this InventoryRuntime.
	std::map<DefinitionId, const ItemDefinition *> item_definition_cache_;
	std::map<DefinitionId, const ContainerDefinition *> container_definition_cache_;
};

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_RUNTIME_STATE_H
