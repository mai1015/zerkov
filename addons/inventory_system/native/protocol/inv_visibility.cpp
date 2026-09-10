#include "protocol/inv_visibility.h"

#include "core/inv_definitions.h"
#include "core/inv_hash.h"
#include "core/inv_identifier.h"
#include "core/inv_limits.h"

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace inv::protocol {

namespace {

// Reproduces InventorySnapshot::hash's own body-then-hash discipline
// (core/inv_snapshot.cpp's compute_body_hash(), which is file-local there)
// using only the EXPORTED encode_canonical(): encode with hash temporarily
// zeroed, then hash everything except the trailing 8-byte (LE u64) hash
// field encode_canonical() itself appended. This keeps inv_snapshot.{h,cpp}
// unchanged -- no new export needed for this one caller.
Status recompute_projected_hash(InventorySnapshot &r_snapshot) {
	r_snapshot.hash = 0;
	ByteWriter writer(MAX_SNAPSHOT_BYTES);
	Status status = encode_canonical(r_snapshot, writer);
	if (!status.ok()) {
		return status;
	}
	const std::vector<std::uint8_t> &bytes = writer.bytes();
	if (bytes.size() < 8) {
		return make_status(StatusCode::INTERNAL_ERROR);
	}
	const std::vector<std::uint8_t> body(bytes.begin(), bytes.end() - 8);
	r_snapshot.hash = hash_bytes(body);
	return ok_status();
}

Status encode_observer_content(const ObserverSnapshot &p_snapshot, ByteWriter &p_writer) {
	p_writer.write_u64(p_snapshot.inventory_id);
	p_writer.write_u8(static_cast<std::uint8_t>(p_snapshot.visibility));
	p_writer.write_u64(p_snapshot.manifest_fingerprint);
	p_writer.write_count(p_snapshot.containers.size(), MAX_CONTAINERS_PER_INVENTORY);
	for (const ObserverContainerView &container : p_snapshot.containers) {
		p_writer.write_u64(container.id);
		p_writer.write_string(container.definition_identifier);
		p_writer.write_u64(container.provider_item);
		p_writer.write_u32(container.item_count);
		p_writer.write_bool(container.aggregate_only);
	}
	p_writer.write_count(p_snapshot.items.size(), MAX_ITEMS_PER_INVENTORY);
	for (const ObserverItemView &item : p_snapshot.items) {
		p_writer.write_u64(item.id);
		p_writer.write_string(item.item_definition_identifier);
		p_writer.write_u64(item.quantity);
		Status location_status = encode_snapshot_location(item.location, p_writer);
		if (!location_status.ok()) {
			return location_status;
		}
		p_writer.write_count(item.mutable_components.size(), MAX_MUTABLE_COMPONENTS_PER_ITEM);
		for (const SnapshotMutableComponent &component : item.mutable_components) {
			p_writer.write_string(component.component_identifier);
			p_writer.write_blob(component.payload, MAX_TRAIT_PAYLOAD_BYTES);
		}
		p_writer.write_count(item.provided_containers.size(), MAX_ITEM_PROVIDED_CONTAINERS);
		for (std::uint64_t provided : item.provided_containers) {
			p_writer.write_u64(provided);
		}
	}
	return p_writer.status();
}

} // namespace

Status derive_default_policy(const DefinitionCatalog &p_catalog, const InventorySnapshot &p_reference, ProjectionPolicy &r_policy) {
	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	ProjectionPolicy result;
	result.default_visibility = ContainerVisibility::REDACTED;
	for (const SnapshotContainer &container : p_reference.containers) {
		const ContainerDefinition *def = p_catalog.find_container(container.container_definition_identifier);
		if (def == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(container.container_definition_identifier));
		}
		const bool has_inspect = (def->constraints.access_mask & static_cast<std::uint8_t>(AccessFlag::INSPECT)) != 0;
		result.overrides[container.container_definition_identifier] = has_inspect ? ContainerVisibility::PUBLIC : ContainerVisibility::REDACTED;
	}
	r_policy = std::move(result);
	return ok_status();
}

ContainerVisibility container_visibility(const ProjectionPolicy &p_policy, const std::string &p_container_definition_identifier) {
	const auto found = p_policy.overrides.find(p_container_definition_identifier);
	return found != p_policy.overrides.end() ? found->second : p_policy.default_visibility;
}

Status project_snapshot(const InventorySnapshot &p_full, VisibilityScope p_scope, const ProjectionPolicy &p_policy, InventorySnapshot &r_projected) {
	if (p_scope == VisibilityScope::OWNER) {
		InventorySnapshot result = p_full;
		result.visibility = VisibilityScope::OWNER;
		r_projected = std::move(result);
		return ok_status();
	}

	// Resolve every container instance's policy once, by instance id (not
	// definition identifier), so the cascade below never re-derives it.
	std::map<std::uint64_t, ContainerVisibility> policy_by_container_id;
	for (const SnapshotContainer &container : p_full.containers) {
		policy_by_container_id.emplace(container.id, container_visibility(p_policy, container.container_definition_identifier));
	}

	// Fixed-point cascade (bounded: p_full.containers/items are already
	// bounded by MAX_CONTAINERS_PER_INVENTORY/MAX_ITEMS_PER_INVENTORY, so
	// this is a small, terminating loop, never unbounded recursion):
	//   - an item is removed if its OWN container is HIDDEN (directly or by
	//     having itself cascaded away), or is REDACTED with
	//     redacted_preserves_item_count == false;
	//   - a container is removed if its provider item was removed (a
	//     container cannot outlive the item that provides it once that
	//     item's identity is gone from the projection).
	std::set<std::uint64_t> removed_items;
	std::set<std::uint64_t> removed_containers;
	for (const SnapshotContainer &container : p_full.containers) {
		if (policy_by_container_id.at(container.id) == ContainerVisibility::HIDDEN) {
			removed_containers.insert(container.id);
		}
	}
	bool changed = true;
	while (changed) {
		changed = false;
		for (const SnapshotItem &item : p_full.items) {
			if (removed_items.count(item.id) != 0) {
				continue;
			}
			const auto policy_it = policy_by_container_id.find(item.location.container);
			const ContainerVisibility policy = policy_it != policy_by_container_id.end() ? policy_it->second : p_policy.default_visibility;
			const bool container_removed_or_hidden = removed_containers.count(item.location.container) != 0 || policy == ContainerVisibility::HIDDEN;
			const bool redacted_with_count_hidden = policy == ContainerVisibility::REDACTED && !p_policy.redacted_preserves_item_count;
			if (container_removed_or_hidden || redacted_with_count_hidden) {
				removed_items.insert(item.id);
				changed = true;
			}
		}
		for (const SnapshotContainer &container : p_full.containers) {
			if (removed_containers.count(container.id) != 0) {
				continue;
			}
			if (container.provider_item != 0 && removed_items.count(container.provider_item) != 0) {
				removed_containers.insert(container.id);
				changed = true;
			}
		}
	}

	std::set<std::uint64_t> removed_references;
	for (const SnapshotReference &reference : p_full.references) {
		if (removed_items.count(reference.item_id) != 0) {
			removed_references.insert(reference.id);
		}
	}

	InventorySnapshot result = p_full; // Scalar/meta fields (revision, manifest identity, allocator counters, ...) carry over verbatim; collections rebuilt below.
	result.visibility = p_scope;
	result.containers.clear();
	result.items.clear();
	result.references.clear();

	for (const SnapshotContainer &container : p_full.containers) {
		if (removed_containers.count(container.id) != 0) {
			continue; // HIDDEN, or cascaded away with its provider item -- "container + contents absent entirely".
		}
		result.containers.push_back(container);
	}

	for (const SnapshotItem &item : p_full.items) {
		if (removed_items.count(item.id) != 0) {
			continue;
		}
		const auto policy_it = policy_by_container_id.find(item.location.container);
		const ContainerVisibility policy = policy_it != policy_by_container_id.end() ? policy_it->second : p_policy.default_visibility;

		SnapshotItem kept = item;
		// Never leave a dangling provided_containers reference to a
		// container this projection removed, regardless of this item's own
		// policy.
		kept.provided_containers.erase(
				std::remove_if(kept.provided_containers.begin(), kept.provided_containers.end(),
						[&](std::uint64_t p_container_id) { return removed_containers.count(p_container_id) != 0; }),
				kept.provided_containers.end());

		if (policy != ContainerVisibility::PUBLIC) {
			// REDACTED with count preserved (the only way to reach here with
			// a non-PUBLIC policy -- HIDDEN and REDACTED-with-count-hidden
			// items were already excluded above): strip identity and
			// mutable content, keep quantity/location so the container's
			// shape/occupancy is still legible.
			kept.item_definition_identifier = REDACTED_ITEM_DEFINITION_IDENTIFIER;
			kept.mutable_components.clear();
			kept.provided_containers.clear();
		}
		result.items.push_back(std::move(kept));
	}

	for (const SnapshotReference &reference : p_full.references) {
		if (removed_references.count(reference.id) != 0) {
			continue;
		}
		result.references.push_back(reference);
	}

	Status hash_status = recompute_projected_hash(result);
	if (!hash_status.ok()) {
		return hash_status;
	}
	r_projected = std::move(result);
	return ok_status();
}

Status validate_observer_snapshot(const ObserverSnapshot &p_snapshot) {
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (p_snapshot.inventory_id == 0 ||
			(p_snapshot.visibility != VisibilityScope::OBSERVER && p_snapshot.visibility != VisibilityScope::REDACTED) ||
			p_snapshot.generation == 0 || p_snapshot.sequence == 0 ||
			p_snapshot.manifest_fingerprint == 0 || p_snapshot.inventory_id > script_max ||
			p_snapshot.generation > script_max || p_snapshot.sequence > script_max) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (p_snapshot.containers.size() > MAX_CONTAINERS_PER_INVENTORY ||
			p_snapshot.items.size() > MAX_ITEMS_PER_INVENTORY) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	const bool redacted_scope = p_snapshot.visibility == VisibilityScope::REDACTED;
	if (redacted_scope && !p_snapshot.items.empty()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED);
	}
	std::set<std::uint64_t> container_ids;
	std::uint64_t previous_container_id = 0;
	for (const ObserverContainerView &container : p_snapshot.containers) {
		if (container.id == 0 || container.id > script_max || container.provider_item > script_max ||
				!container_ids.insert(container.id).second ||
				(previous_container_id != 0 && container.id <= previous_container_id)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::OWNERSHIP_DUPLICATE, container.id);
		}
		previous_container_id = container.id;
		if (redacted_scope && (!container.aggregate_only ||
				container.definition_identifier != REDACTED_CONTAINER_DEFINITION_IDENTIFIER ||
				container.provider_item != 0)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED, container.id);
		}
		if (container.definition_identifier.empty()) {
			return make_status(StatusCode::INVALID_IDENTIFIER, DiagnosticId::IDENTIFIER_EMPTY_SEGMENT);
		}
		if (container.definition_identifier.size() > MAX_IDENTIFIER_BYTES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::IDENTIFIER_TOO_LONG, container.id);
		}
		if (container.aggregate_only) {
			if (container.definition_identifier != REDACTED_CONTAINER_DEFINITION_IDENTIFIER ||
					container.provider_item != 0) {
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED, container.id);
			}
			if (container.item_count > MAX_ITEMS_PER_INVENTORY) {
				return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, container.item_count);
			}
		} else {
			Status identifier_status = validate_identifier(container.definition_identifier);
			if (!identifier_status.ok()) {
				return identifier_status;
			}
			if (container.item_count != 0) {
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED, container.id);
			}
		}
	}

	std::set<std::uint64_t> item_ids;
	std::uint64_t previous_item_id = 0;
	for (const ObserverItemView &item : p_snapshot.items) {
		if (item.id == 0 || item.id > script_max || item.location.container > script_max ||
				!item_ids.insert(item.id).second ||
				(previous_item_id != 0 && item.id <= previous_item_id)) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::OWNERSHIP_DUPLICATE, item.id);
		}
		previous_item_id = item.id;
		Status identifier_status = validate_identifier(item.item_definition_identifier);
		if (!identifier_status.ok()) {
			return identifier_status;
		}
		if (item.item_definition_identifier.size() > MAX_IDENTIFIER_BYTES) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::IDENTIFIER_TOO_LONG, item.id);
		}
		switch (item.location.kind) {
			case SnapshotLocationKind::SPATIAL:
				if (item.location.x >= MAX_GRID_DIMENSION || item.location.y >= MAX_GRID_DIMENSION ||
						!item.location.slot_identifier.empty() || item.location.ordinal != 0) {
					return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, item.id);
				}
				break;
			case SnapshotLocationKind::SLOT: {
				if (item.location.x != 0 || item.location.y != 0 || item.location.rotated || item.location.ordinal != 0 ||
						item.location.slot_identifier.empty() || item.location.slot_identifier.size() > MAX_IDENTIFIER_BYTES) {
					return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, item.id);
				}
				Status slot_status = validate_identifier(item.location.slot_identifier);
				if (!slot_status.ok()) {
					return slot_status;
				}
				break;
			}
			case SnapshotLocationKind::LIST:
				if (item.location.ordinal >= MAX_LIST_ENTRIES || item.location.x != 0 || item.location.y != 0 ||
						item.location.rotated || !item.location.slot_identifier.empty()) {
					return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, item.id);
				}
				break;
			default:
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, item.id);
		}
		if (item.quantity == 0 || item.quantity > MAX_STACK_QUANTITY) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, item.quantity);
		}
		if (container_ids.count(item.location.container) == 0) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, item.location.container);
		}
		const auto location_container = std::find_if(
				p_snapshot.containers.begin(), p_snapshot.containers.end(),
				[&](const ObserverContainerView &container) { return container.id == item.location.container; });
		if (location_container == p_snapshot.containers.end() || location_container->aggregate_only) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED, item.id);
		}
		if (item.mutable_components.size() > MAX_MUTABLE_COMPONENTS_PER_ITEM ||
				item.provided_containers.size() > MAX_ITEM_PROVIDED_CONTAINERS) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, item.id);
		}
		for (std::size_t i = 0; i < item.mutable_components.size(); ++i) {
			const SnapshotMutableComponent &component = item.mutable_components[i];
			Status component_status = validate_identifier(component.component_identifier);
			if (!component_status.ok()) {
				return component_status;
			}
			if (component.component_identifier.size() > MAX_IDENTIFIER_BYTES) {
				return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::IDENTIFIER_TOO_LONG, item.id);
			}
			if (component.payload.size() > MAX_TRAIT_PAYLOAD_BYTES ||
					(i != 0 && !identifier_less(item.mutable_components[i - 1].component_identifier, component.component_identifier))) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CANONICAL_ORDER_VIOLATION, item.id);
			}
		}
		std::uint64_t previous_provided = 0;
		for (std::uint64_t provided : item.provided_containers) {
			if (provided > script_max) {
				return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::VALUE_OUT_OF_RANGE, provided);
			}
			if (container_ids.count(provided) == 0) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, provided);
			}
			if (previous_provided != 0 && provided <= previous_provided) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::CANONICAL_ORDER_VIOLATION, provided);
			}
			previous_provided = provided;
			const auto provided_container = std::find_if(
					p_snapshot.containers.begin(), p_snapshot.containers.end(),
					[&](const ObserverContainerView &container) { return container.id == provided; });
			if (provided_container == p_snapshot.containers.end() || provided_container->aggregate_only ||
					provided_container->provider_item != item.id) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, provided);
			}
		}
	}
	for (const ObserverContainerView &container : p_snapshot.containers) {
		if (container.aggregate_only && container.provider_item != 0) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED, container.id);
		}
		if (container.provider_item != 0 && item_ids.count(container.provider_item) == 0) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, container.provider_item);
		}
		if (container.provider_item != 0) {
			const auto provider_item = std::find_if(
					p_snapshot.items.begin(), p_snapshot.items.end(),
					[&](const ObserverItemView &item) { return item.id == container.provider_item; });
			if (provider_item == p_snapshot.items.end() ||
					std::find(provider_item->provided_containers.begin(), provider_item->provided_containers.end(), container.id) ==
							provider_item->provided_containers.end()) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, container.id);
			}
		}
	}
	return ok_status();
}

std::uint64_t observer_snapshot_content_hash(const ObserverSnapshot &p_snapshot) {
	ByteWriter writer(MAX_OBSERVER_VIEW_BYTES);
	if (!encode_observer_content(p_snapshot, writer).ok()) {
		return 0;
	}
	return hash_bytes(writer.bytes());
}

Status observer_snapshot_content_equal(
		const ObserverSnapshot &p_left,
		const ObserverSnapshot &p_right,
		bool &r_equal) {
	r_equal = false;
	ByteWriter left_writer(MAX_OBSERVER_VIEW_BYTES);
	ByteWriter right_writer(MAX_OBSERVER_VIEW_BYTES);
	Status left_status = encode_observer_content(p_left, left_writer);
	if (!left_status.ok()) {
		return left_status;
	}
	Status right_status = encode_observer_content(p_right, right_writer);
	if (!right_status.ok()) {
		return right_status;
	}
	// The hash is only a cheap prefilter after both bounded canonical encodes
	// have succeeded; equality itself is decided from the complete bytes so a
	// collision or an encode failure can never suppress a visible update.
	if (hash_bytes(left_writer.bytes()) != hash_bytes(right_writer.bytes())) {
		return ok_status();
	}
	r_equal = left_writer.bytes() == right_writer.bytes();
	return ok_status();
}

Status project_observer_snapshot(
		const InventorySnapshot &p_full,
		VisibilityScope p_scope,
		ProjectionPolicy &p_policy,
		DiscoveryRecipientKey p_recipient,
		std::uint64_t p_generation,
		std::uint64_t p_sequence,
		ObserverSnapshot &r_observer) {
	(void)p_recipient; // binding is carried by the envelope; IDs are stream-mapped below.
	if ((p_scope != VisibilityScope::OBSERVER && p_scope != VisibilityScope::REDACTED) ||
			p_recipient.session_id == 0 || p_recipient.actor_id == 0 ||
			p_generation == 0 || p_sequence == 0 || p_full.inventory_id == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	// Opaque handles and counters are stream state.  Publish a candidate only
	// after the complete projected value validates, so a late failure cannot
	// consume handles or leave the caller's policy partially mutated.
	ProjectionPolicy candidate_policy = p_policy;
	const bool force_redacted_scope = p_scope == VisibilityScope::REDACTED;
	auto visibility_for = [&](const std::string &p_definition_identifier) {
		const ContainerVisibility requested = container_visibility(candidate_policy, p_definition_identifier);
		// REDACTED is aggregate-only.  Preserve an explicit HIDDEN policy, but
		// never let a PUBLIC override disclose item rows in this scope.
		return force_redacted_scope && requested != ContainerVisibility::HIDDEN ?
				ContainerVisibility::REDACTED : requested;
	};

	std::map<std::uint64_t, ContainerVisibility> policy_by_container_id;
	for (const SnapshotContainer &container : p_full.containers) {
		policy_by_container_id.emplace(container.id, visibility_for(container.container_definition_identifier));
	}

	std::set<std::uint64_t> removed_items;
	std::set<std::uint64_t> removed_containers;
	std::map<std::uint64_t, ContainerVisibility> effective_policy = policy_by_container_id;
	for (const SnapshotContainer &container : p_full.containers) {
		if (visibility_for(container.container_definition_identifier) == ContainerVisibility::HIDDEN) {
			removed_containers.insert(container.id);
		}
	}
	bool changed = true;
	while (changed) {
		changed = false;
		for (const SnapshotItem &item : p_full.items) {
			if (removed_items.count(item.id) != 0) {
				continue;
			}
			const auto policy_it = effective_policy.find(item.location.container);
			const ContainerVisibility item_policy = policy_it != effective_policy.end() ?
					policy_it->second : visibility_for("");
			if (removed_containers.count(item.location.container) != 0 ||
					item_policy == ContainerVisibility::HIDDEN ||
					(item_policy == ContainerVisibility::REDACTED && !candidate_policy.redacted_preserves_item_count)) {
				removed_items.insert(item.id);
				changed = true;
			}
		}
		for (const SnapshotContainer &container : p_full.containers) {
			if (removed_containers.count(container.id) != 0 || !container.provider_item) {
				continue;
			}
			const auto provider_policy_it = std::find_if(
					p_full.items.begin(), p_full.items.end(),
					[&](const SnapshotItem &item) { return item.id == container.provider_item; });
			bool provider_public = false;
			if (provider_policy_it != p_full.items.end()) {
				const auto provider_container = std::find_if(
						p_full.containers.begin(), p_full.containers.end(),
						[&](const SnapshotContainer &candidate) { return candidate.id == provider_policy_it->location.container; });
				provider_public = provider_container != p_full.containers.end() &&
						visibility_for(provider_container->container_definition_identifier) == ContainerVisibility::PUBLIC;
			}
			if (removed_items.count(container.provider_item) != 0 || !provider_public) {
				removed_containers.insert(container.id);
				changed = true;
			}
		}
	}

	ObserverSnapshot result;
	result.inventory_id = p_full.inventory_id;
	result.visibility = p_scope;
	result.generation = p_generation;
	result.sequence = p_sequence;
	result.manifest_fingerprint = p_full.manifest_fingerprint;
	std::map<std::uint64_t, std::uint64_t> output_container_ids;
	std::set<std::uint64_t> reserved_container_ids;
	if (candidate_policy.opaque_container_ids.size() > MAX_CONTAINERS_PER_INVENTORY ||
			candidate_policy.opaque_item_ids.size() > MAX_ITEMS_PER_INVENTORY) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	for (const auto &entry : candidate_policy.opaque_container_ids) {
		if (entry.first == 0 || entry.second == 0 ||
				entry.second > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) ||
				(entry.second & 1U) == 0 ||
				!reserved_container_ids.insert(entry.second).second) {
			return make_status(StatusCode::HASH_COLLISION, DiagnosticId::OWNERSHIP_DUPLICATE, entry.second);
		}
	}
	if (candidate_policy.opaque_container_counter == 0 || candidate_policy.opaque_item_counter == 0) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED);
	}
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (candidate_policy.opaque_container_counter > script_max ||
			(candidate_policy.opaque_container_counter & 1U) == 0 ||
			candidate_policy.opaque_item_counter > script_max ||
			(candidate_policy.opaque_item_counter & 1U) != 0) {
		return make_status(StatusCode::HASH_COLLISION, DiagnosticId::OWNERSHIP_DUPLICATE);
	}
	std::uint64_t container_counter = candidate_policy.opaque_container_counter;
	auto allocate_opaque = [](std::map<std::uint64_t, std::uint64_t> &r_mapping,
			std::set<std::uint64_t> &r_reserved,
			std::uint64_t &r_counter,
			std::uint64_t p_raw,
			std::uint64_t &r_output) -> Status {
		auto existing = r_mapping.find(p_raw);
		if (existing != r_mapping.end()) {
			if (existing->second == 0 || existing->second > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
				return make_status(StatusCode::HASH_COLLISION, DiagnosticId::OWNERSHIP_DUPLICATE, existing->second);
			}
			r_output = existing->second;
			return ok_status();
		}
		while (r_counter != 0 && r_counter <= static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
			const std::uint64_t candidate = r_counter;
			if (r_counter <= 2) {
				r_counter = 0;
			} else {
				r_counter -= 2;
			}
			// Do not branch on the canonical numeric value.  Opaque handles are
			// interpreted in a recipient-local namespace, so equal integers are
			// harmless and must not create allocation gaps that reveal hidden
			// allocator occupancy.
			if (candidate != 0 && r_reserved.insert(candidate).second) {
				r_mapping.emplace(p_raw, candidate);
				r_output = candidate;
				return ok_status();
			}
		}
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::OVERFLOW_DETECTED);
	};
	for (const SnapshotContainer &container : p_full.containers) {
		if (removed_containers.count(container.id) != 0) {
			continue;
		}
		const ContainerVisibility visibility = visibility_for(container.container_definition_identifier);
		const bool aggregate = visibility == ContainerVisibility::REDACTED;
		std::uint64_t output_id = 0;
		Status allocate_status = allocate_opaque(
				candidate_policy.opaque_container_ids, reserved_container_ids, container_counter, container.id, output_id);
		if (!allocate_status.ok()) {
			return allocate_status;
		}
		output_container_ids.emplace(container.id, output_id);
		ObserverContainerView view;
		view.id = output_id;
		view.aggregate_only = aggregate;
		view.definition_identifier = aggregate ? REDACTED_CONTAINER_DEFINITION_IDENTIFIER : container.container_definition_identifier;
		if (aggregate && candidate_policy.redacted_preserves_item_count) {
			for (const SnapshotItem &item : p_full.items) {
				if (item.location.container == container.id && removed_items.count(item.id) == 0) {
					++view.item_count;
				}
			}
		}
		result.containers.push_back(std::move(view));
	}

	std::set<std::uint64_t> reserved_item_ids;
	for (const auto &entry : candidate_policy.opaque_item_ids) {
		if (entry.first == 0 || entry.second == 0 ||
				entry.second > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) ||
				(entry.second & 1U) != 0 ||
				!reserved_item_ids.insert(entry.second).second) {
			return make_status(StatusCode::HASH_COLLISION, DiagnosticId::OWNERSHIP_DUPLICATE, entry.second);
		}
	}
	std::uint64_t item_counter = candidate_policy.opaque_item_counter;
	std::map<std::uint64_t, std::uint64_t> output_item_ids;
	for (const SnapshotItem &item : p_full.items) {
		if (removed_items.count(item.id) != 0) {
			continue;
		}
		const auto container_it = std::find_if(
				p_full.containers.begin(), p_full.containers.end(),
				[&](const SnapshotContainer &container) { return container.id == item.location.container; });
		if (container_it == p_full.containers.end() ||
				visibility_for(container_it->container_definition_identifier) != ContainerVisibility::PUBLIC) {
			continue;
		}
		const auto output_container_it = output_container_ids.find(item.location.container);
		if (output_container_it == output_container_ids.end()) {
			continue;
		}
		std::uint64_t output_item_id = 0;
		Status item_allocate_status = allocate_opaque(
				candidate_policy.opaque_item_ids, reserved_item_ids, item_counter, item.id, output_item_id);
		if (!item_allocate_status.ok()) {
			return item_allocate_status;
		}
		output_item_ids.emplace(item.id, output_item_id);
		ObserverItemView view;
		view.id = output_item_id;
		view.item_definition_identifier = item.item_definition_identifier;
		view.quantity = item.quantity;
		view.location = item.location;
		view.location.container = output_container_it->second;
		view.mutable_components = item.mutable_components;
		for (std::uint64_t provided : item.provided_containers) {
			const auto provided_it = output_container_ids.find(provided);
			if (provided_it != output_container_ids.end()) {
				const auto provided_source = std::find_if(
						p_full.containers.begin(), p_full.containers.end(),
						[&](const SnapshotContainer &container) { return container.id == provided; });
				if (provided_source != p_full.containers.end() &&
						visibility_for(provided_source->container_definition_identifier) == ContainerVisibility::PUBLIC) {
					view.provided_containers.push_back(provided_it->second);
				}
			}
		}
		std::sort(view.provided_containers.begin(), view.provided_containers.end());
		result.items.push_back(std::move(view));
	}
	for (const SnapshotContainer &container : p_full.containers) {
		const auto output_container_it = output_container_ids.find(container.id);
		if (output_container_it == output_container_ids.end()) {
			continue;
		}
		const auto output_item_it = output_item_ids.find(container.provider_item);
		if (visibility_for(container.container_definition_identifier) != ContainerVisibility::REDACTED &&
				container.provider_item != 0 && output_item_it != output_item_ids.end()) {
			for (ObserverContainerView &view : result.containers) {
				if (view.id == output_container_it->second) {
					view.provider_item = output_item_it->second;
					break;
				}
			}
		}
	}
	for (auto it = candidate_policy.opaque_container_ids.begin(); it != candidate_policy.opaque_container_ids.end();) {
		if (output_container_ids.count(it->first) == 0) {
			it = candidate_policy.opaque_container_ids.erase(it);
		} else {
			++it;
		}
	}
	for (auto it = candidate_policy.opaque_item_ids.begin(); it != candidate_policy.opaque_item_ids.end();) {
		if (output_item_ids.count(it->first) == 0) {
			it = candidate_policy.opaque_item_ids.erase(it);
		} else {
			++it;
		}
	}
	if (candidate_policy.opaque_container_ids.size() > MAX_CONTAINERS_PER_INVENTORY ||
			candidate_policy.opaque_item_ids.size() > MAX_ITEMS_PER_INVENTORY) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
	}
	candidate_policy.opaque_container_counter = container_counter;
	candidate_policy.opaque_item_counter = item_counter;

	std::sort(result.containers.begin(), result.containers.end(), [](const ObserverContainerView &a, const ObserverContainerView &b) {
		return a.id < b.id;
	});
	std::sort(result.items.begin(), result.items.end(), [](const ObserverItemView &a, const ObserverItemView &b) {
		return a.id < b.id;
	});
	Status validate_status = validate_observer_snapshot(result);
	if (!validate_status.ok()) {
		return validate_status;
	}
	p_policy = std::move(candidate_policy);
	r_observer = std::move(result);
	return ok_status();
}

} // namespace inv::protocol
