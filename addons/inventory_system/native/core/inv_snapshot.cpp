#include "core/inv_snapshot.h"

#include "core/inv_hash.h"
#include "core/inv_limits.h"

#include <utility>

namespace inv {

// Exported (see inv_snapshot.h doc comment): reused verbatim by
// core/inv_deltas.h-shaped delta ops and by protocol decoders for a
// Command's ItemLocation fields, so this location codec has exactly one
// implementation.

Status encode_snapshot_location(const SnapshotLocation &p_location, ByteWriter &p_writer) {
	p_writer.write_u8(static_cast<std::uint8_t>(p_location.kind));
	p_writer.write_u64(p_location.container);
	switch (p_location.kind) {
		case SnapshotLocationKind::SPATIAL:
			p_writer.write_u32(p_location.x);
			p_writer.write_u32(p_location.y);
			p_writer.write_bool(p_location.rotated);
			break;
		case SnapshotLocationKind::SLOT:
			p_writer.write_string(p_location.slot_identifier);
			break;
		case SnapshotLocationKind::LIST:
			p_writer.write_u32(p_location.ordinal);
			break;
	}
	return p_writer.status();
}

Status decode_snapshot_location(ByteReader &p_reader, SnapshotLocation &r_out) {
	std::uint8_t kind_raw = 0;
	if (!p_reader.read_u8(kind_raw)) {
		return p_reader.status();
	}
	if (kind_raw < static_cast<std::uint8_t>(SnapshotLocationKind::SPATIAL) ||
			kind_raw > static_cast<std::uint8_t>(SnapshotLocationKind::LIST)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	r_out.kind = static_cast<SnapshotLocationKind>(kind_raw);
	if (!p_reader.read_u64(r_out.container)) {
		return p_reader.status();
	}
	switch (r_out.kind) {
		case SnapshotLocationKind::SPATIAL:
			if (!p_reader.read_u32(r_out.x) || !p_reader.read_u32(r_out.y) || !p_reader.read_bool(r_out.rotated)) {
				return p_reader.status();
			}
			break;
		case SnapshotLocationKind::SLOT:
			if (!p_reader.read_string(r_out.slot_identifier)) {
				return p_reader.status();
			}
			break;
		case SnapshotLocationKind::LIST:
			if (!p_reader.read_u32(r_out.ordinal)) {
				return p_reader.status();
			}
			break;
	}
	return ok_status();
}

SnapshotLocation to_snapshot_location(const ItemLocation &p_location) {
	SnapshotLocation result;
	if (const SpatialPlacement *spatial = std::get_if<SpatialPlacement>(&p_location)) {
		result.kind = SnapshotLocationKind::SPATIAL;
		result.container = spatial->container.value;
		result.x = spatial->x;
		result.y = spatial->y;
		result.rotated = spatial->rotated;
	} else if (const SlotPlacement *slot = std::get_if<SlotPlacement>(&p_location)) {
		result.kind = SnapshotLocationKind::SLOT;
		result.container = slot->container.value;
		result.slot_identifier = slot->slot_identifier;
	} else {
		const ListPlacement &list_placement = std::get<ListPlacement>(p_location);
		result.kind = SnapshotLocationKind::LIST;
		result.container = list_placement.container.value;
		result.ordinal = list_placement.ordinal;
	}
	return result;
}

Status from_snapshot_location(const SnapshotLocation &p_location, ItemLocation &r_out) {
	switch (p_location.kind) {
		case SnapshotLocationKind::SPATIAL: {
			SpatialPlacement spatial;
			spatial.container = ContainerInstanceId{ p_location.container };
			spatial.x = p_location.x;
			spatial.y = p_location.y;
			spatial.rotated = p_location.rotated;
			r_out = spatial;
			return ok_status();
		}
		case SnapshotLocationKind::SLOT: {
			SlotPlacement slot;
			slot.container = ContainerInstanceId{ p_location.container };
			slot.slot_identifier = p_location.slot_identifier;
			r_out = slot;
			return ok_status();
		}
		case SnapshotLocationKind::LIST: {
			ListPlacement list_placement;
			list_placement.container = ContainerInstanceId{ p_location.container };
			list_placement.ordinal = p_location.ordinal;
			r_out = list_placement;
			return ok_status();
		}
	}
	return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM);
}

namespace {

// Encodes every InventorySnapshot field EXCEPT `hash` itself, in the exact
// field order decode_canonical()/compute_body_hash() expect:
//   inventory_id, profile_identifier, profile_definition_id,
//   manifest_fingerprint, manifest_algorithm, revision,
//   container_allocator_next, item_allocator_next, reference_allocator_next,
//   visibility,
//   containers[] (id, container_definition_identifier, provider_item),
//   items[] (id, item_definition_identifier, quantity, location,
//            mutable_components[] (component_identifier, payload),
//            provided_containers[] (raw container id)),
//   references[] (id, item_id).
Status encode_body(const InventorySnapshot &p_snapshot, ByteWriter &p_writer) {
	p_writer.write_u64(p_snapshot.inventory_id);
	p_writer.write_string(p_snapshot.profile_identifier);
	p_writer.write_u32(p_snapshot.profile_definition_id);
	p_writer.write_u64(p_snapshot.manifest_fingerprint);
	p_writer.write_string(p_snapshot.manifest_algorithm);
	p_writer.write_u64(p_snapshot.revision);
	p_writer.write_u64(p_snapshot.container_allocator_next);
	p_writer.write_u64(p_snapshot.item_allocator_next);
	p_writer.write_u64(p_snapshot.reference_allocator_next);
	p_writer.write_u8(static_cast<std::uint8_t>(p_snapshot.visibility));

	p_writer.write_count(p_snapshot.containers.size(), MAX_CONTAINERS_PER_INVENTORY);
	for (const SnapshotContainer &container : p_snapshot.containers) {
		p_writer.write_u64(container.id);
		p_writer.write_string(container.container_definition_identifier);
		p_writer.write_u64(container.provider_item);
	}

	p_writer.write_count(p_snapshot.items.size(), MAX_ITEMS_PER_INVENTORY);
	for (const SnapshotItem &item : p_snapshot.items) {
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

	p_writer.write_count(p_snapshot.references.size(), MAX_REFERENCES_PER_INVENTORY);
	for (const SnapshotReference &reference : p_snapshot.references) {
		p_writer.write_u64(reference.id);
		p_writer.write_u64(reference.item_id);
	}

	return p_writer.status();
}

Status compute_body_hash(const InventorySnapshot &p_snapshot, std::uint64_t &r_hash) {
	ByteWriter writer;
	Status status = encode_body(p_snapshot, writer);
	if (!status.ok()) {
		return status;
	}
	r_hash = hash_bytes(writer.bytes());
	return ok_status();
}

} // namespace

Status recompute_snapshot_hash(InventorySnapshot &r_snapshot) {
	std::uint64_t hash_value = 0;
	Status status = compute_body_hash(r_snapshot, hash_value);
	if (!status.ok()) {
		return status;
	}
	r_snapshot.hash = hash_value;
	return ok_status();
}

Status snapshot(const InventoryRuntime &p_runtime, VisibilityScope p_scope, InventorySnapshot &r_out) {
	InventorySnapshot result;
	result.inventory_id = p_runtime.id().value;
	result.profile_identifier = p_runtime.profile_identifier();
	result.profile_definition_id = p_runtime.profile_definition();
	result.manifest_fingerprint = p_runtime.manifest_fingerprint();
	result.manifest_algorithm = MANIFEST_ALGORITHM;
	result.revision = p_runtime.revision();
	result.container_allocator_next = p_runtime.container_allocator_next_raw();
	result.item_allocator_next = p_runtime.item_allocator_next_raw();
	result.reference_allocator_next = p_runtime.reference_allocator_next_raw();
	result.visibility = p_scope;

	result.containers.reserve(p_runtime.containers().size());
	for (const auto &pair : p_runtime.containers()) {
		const std::string *identifier = p_runtime.container_definition_identifier(pair.second.container_definition);
		if (identifier == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, pair.first.value);
		}
		SnapshotContainer container;
		container.id = pair.first.value;
		container.container_definition_identifier = *identifier;
		container.provider_item = pair.second.provider_item.value;
		result.containers.push_back(std::move(container));
	}

	result.items.reserve(p_runtime.items().size());
	for (const auto &pair : p_runtime.items()) {
		const std::string *identifier = p_runtime.item_definition_identifier(pair.second.item_definition);
		if (identifier == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::NONE, pair.first.value);
		}
		SnapshotItem item;
		item.id = pair.first.value;
		item.item_definition_identifier = *identifier;
		item.quantity = pair.second.quantity;
		item.location = to_snapshot_location(pair.second.location);
		item.mutable_components.reserve(pair.second.mutable_components.size());
		for (const MutableComponent &component : pair.second.mutable_components) {
			SnapshotMutableComponent snapshot_component;
			snapshot_component.component_identifier = component.component_identifier;
			snapshot_component.payload = component.payload;
			item.mutable_components.push_back(std::move(snapshot_component));
		}
		item.provided_containers.reserve(pair.second.provided_containers.size());
		for (ContainerInstanceId provided : pair.second.provided_containers) {
			item.provided_containers.push_back(provided.value);
		}
		result.items.push_back(std::move(item));
	}

	result.references.reserve(p_runtime.references().size());
	for (const auto &pair : p_runtime.references()) {
		SnapshotReference reference;
		reference.id = pair.first.value;
		reference.item_id = pair.second.value;
		result.references.push_back(reference);
	}

	Status hash_status = recompute_snapshot_hash(result);
	if (!hash_status.ok()) {
		return hash_status;
	}

	r_out = std::move(result);
	return ok_status();
}

Status encode_canonical(const InventorySnapshot &p_snapshot, ByteWriter &p_writer) {
	Status status = encode_body(p_snapshot, p_writer);
	if (!status.ok()) {
		return status;
	}
	p_writer.write_u64(p_snapshot.hash);
	return p_writer.status();
}

Status decode_canonical(ByteReader &p_reader, InventorySnapshot &r_out) {
	InventorySnapshot result;

	// The whole payload is bounded before a single field is read; every
	// collection below is additionally bounded per-collection (against the
	// same inv_limits.h hard limits the runtime itself enforces) before its
	// entries are looped over.
	if (p_reader.remaining() > MAX_SNAPSHOT_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_reader.remaining());
	}

	std::uint64_t inventory_id_raw = 0;
	if (!p_reader.read_u64(inventory_id_raw)) {
		return p_reader.status();
	}
	result.inventory_id = inventory_id_raw;
	if (!p_reader.read_string(result.profile_identifier)) {
		return p_reader.status();
	}
	std::uint32_t profile_definition_id_raw = 0;
	if (!p_reader.read_u32(profile_definition_id_raw)) {
		return p_reader.status();
	}
	result.profile_definition_id = profile_definition_id_raw;
	if (!p_reader.read_u64(result.manifest_fingerprint)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(result.manifest_algorithm)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(result.revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(result.container_allocator_next)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(result.item_allocator_next)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(result.reference_allocator_next)) {
		return p_reader.status();
	}
	std::uint8_t visibility_raw = 0;
	if (!p_reader.read_u8(visibility_raw)) {
		return p_reader.status();
	}
	if (visibility_raw > static_cast<std::uint8_t>(VisibilityScope::REDACTED)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	result.visibility = static_cast<VisibilityScope>(visibility_raw);

	std::size_t container_count = 0;
	if (!p_reader.read_count(container_count, MAX_CONTAINERS_PER_INVENTORY, /*p_min_bytes_per_entry=*/8)) {
		return p_reader.status();
	}
	result.containers.reserve(container_count);
	for (std::size_t i = 0; i < container_count; ++i) {
		SnapshotContainer container;
		if (!p_reader.read_u64(container.id)) {
			return p_reader.status();
		}
		if (!p_reader.read_string(container.container_definition_identifier)) {
			return p_reader.status();
		}
		if (!p_reader.read_u64(container.provider_item)) {
			return p_reader.status();
		}
		result.containers.push_back(std::move(container));
	}

	std::size_t item_count = 0;
	if (!p_reader.read_count(item_count, MAX_ITEMS_PER_INVENTORY, /*p_min_bytes_per_entry=*/8)) {
		return p_reader.status();
	}
	result.items.reserve(item_count);
	for (std::size_t i = 0; i < item_count; ++i) {
		SnapshotItem item;
		if (!p_reader.read_u64(item.id)) {
			return p_reader.status();
		}
		if (!p_reader.read_string(item.item_definition_identifier)) {
			return p_reader.status();
		}
		if (!p_reader.read_u64(item.quantity)) {
			return p_reader.status();
		}
		Status location_status = decode_snapshot_location(p_reader, item.location);
		if (!location_status.ok()) {
			return location_status;
		}

		std::size_t component_count = 0;
		if (!p_reader.read_count(component_count, MAX_MUTABLE_COMPONENTS_PER_ITEM, /*p_min_bytes_per_entry=*/4)) {
			return p_reader.status();
		}
		item.mutable_components.reserve(component_count);
		for (std::size_t c = 0; c < component_count; ++c) {
			SnapshotMutableComponent component;
			if (!p_reader.read_string(component.component_identifier)) {
				return p_reader.status();
			}
			if (!p_reader.read_blob(component.payload, MAX_TRAIT_PAYLOAD_BYTES)) {
				return p_reader.status();
			}
			item.mutable_components.push_back(std::move(component));
		}

		std::size_t provided_count = 0;
		if (!p_reader.read_count(provided_count, MAX_ITEM_PROVIDED_CONTAINERS, /*p_min_bytes_per_entry=*/8)) {
			return p_reader.status();
		}
		item.provided_containers.reserve(provided_count);
		for (std::size_t p = 0; p < provided_count; ++p) {
			std::uint64_t provided_raw = 0;
			if (!p_reader.read_u64(provided_raw)) {
				return p_reader.status();
			}
			item.provided_containers.push_back(provided_raw);
		}

		result.items.push_back(std::move(item));
	}

	std::size_t reference_count = 0;
	if (!p_reader.read_count(reference_count, MAX_REFERENCES_PER_INVENTORY, /*p_min_bytes_per_entry=*/16)) {
		return p_reader.status();
	}
	result.references.reserve(reference_count);
	for (std::size_t i = 0; i < reference_count; ++i) {
		SnapshotReference reference;
		if (!p_reader.read_u64(reference.id)) {
			return p_reader.status();
		}
		if (!p_reader.read_u64(reference.item_id)) {
			return p_reader.status();
		}
		result.references.push_back(reference);
	}

	if (!p_reader.read_u64(result.hash)) {
		return p_reader.status();
	}

	r_out = std::move(result);
	return ok_status();
}

Status restore(const DefinitionCatalog &p_catalog, const InventorySnapshot &p_snapshot, InventoryRuntime &r_runtime, IdentityAuthority *p_authority) {
	// Visibility-safe projection (tasks.md 6.7; inventory-protocol spec,
	// "Visibility-Safe Projection"): a snapshot produced by protocol/
	// inv_visibility.cpp's project_snapshot() for anything other than
	// VisibilityScope::OWNER has already had item/container detail stripped
	// or redacted for its recipient -- restoring it as canonical state would
	// silently corrupt or truncate that state, so restore() refuses it
	// before touching p_catalog or r_runtime. A snapshot() call always
	// produces VisibilityScope::OWNER unless the caller explicitly asked for
	// a narrower scope, so every pre-6.7 call site (which never did) is
	// unaffected.
	if (p_snapshot.visibility != VisibilityScope::OWNER) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VISIBILITY_RESTORE_REQUIRES_OWNER, static_cast<std::uint64_t>(p_snapshot.visibility));
	}
	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	const ContentManifest *manifest = p_catalog.manifest();
	if (manifest == nullptr) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	if (p_snapshot.manifest_algorithm != MANIFEST_ALGORITHM || p_snapshot.manifest_fingerprint != manifest->fingerprint) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_snapshot.manifest_fingerprint);
	}

	const InventoryProfileDefinition *profile = p_catalog.find_profile(p_snapshot.profile_identifier);
	if (profile == nullptr) {
		return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(p_snapshot.profile_identifier));
	}
	const DefinitionId profile_definition_id = p_catalog.profile_id(p_snapshot.profile_identifier);
	if (profile_definition_id != p_snapshot.profile_definition_id) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, profile_definition_id);
	}

	std::map<ContainerInstanceId, ContainerInstance> containers;
	std::map<DefinitionId, const ContainerDefinition *> container_definition_cache;
	for (const SnapshotContainer &snapshot_container : p_snapshot.containers) {
		const ContainerDefinition *def = p_catalog.find_container(snapshot_container.container_definition_identifier);
		if (def == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(snapshot_container.container_definition_identifier));
		}
		ContainerInstance instance;
		instance.id = ContainerInstanceId{ snapshot_container.id };
		instance.container_definition = p_catalog.container_id(snapshot_container.container_definition_identifier);
		instance.provider_item = ItemInstanceId{ snapshot_container.provider_item };
		if (!instance.id) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
		}
		if (containers.find(instance.id) != containers.end()) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, instance.id.value);
		}
		container_definition_cache.emplace(instance.container_definition, def);
		containers.emplace(instance.id, instance);
	}

	std::map<ItemInstanceId, ItemInstance> items;
	std::map<DefinitionId, const ItemDefinition *> item_definition_cache;
	for (const SnapshotItem &snapshot_item : p_snapshot.items) {
		const ItemDefinition *def = p_catalog.find_item(snapshot_item.item_definition_identifier);
		if (def == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE, hash_string(snapshot_item.item_definition_identifier));
		}
		ItemInstance instance;
		instance.id = ItemInstanceId{ snapshot_item.id };
		instance.item_definition = p_catalog.item_id(snapshot_item.item_definition_identifier);
		instance.quantity = snapshot_item.quantity;
		Status location_status = from_snapshot_location(snapshot_item.location, instance.location);
		if (!location_status.ok()) {
			return location_status;
		}
		instance.mutable_components.reserve(snapshot_item.mutable_components.size());
		for (const SnapshotMutableComponent &snapshot_component : snapshot_item.mutable_components) {
			MutableComponent component;
			component.component_identifier = snapshot_component.component_identifier;
			component.payload = snapshot_component.payload;
			instance.mutable_components.push_back(std::move(component));
		}
		instance.provided_containers.reserve(snapshot_item.provided_containers.size());
		for (std::uint64_t provided_raw : snapshot_item.provided_containers) {
			instance.provided_containers.push_back(ContainerInstanceId{ provided_raw });
		}
		if (!instance.id) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
		}
		if (items.find(instance.id) != items.end()) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, instance.id.value);
		}
		item_definition_cache.emplace(instance.item_definition, def);
		items.emplace(instance.id, instance);
	}

	std::map<ReferenceId, ItemInstanceId> references;
	for (const SnapshotReference &snapshot_reference : p_snapshot.references) {
		const ReferenceId reference_id{ snapshot_reference.id };
		if (!reference_id) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
		}
		if (references.find(reference_id) != references.end()) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::OWNERSHIP_DUPLICATE, reference_id.value);
		}
		references.emplace(reference_id, ItemInstanceId{ snapshot_reference.item_id });
	}

	InventoryRuntime candidate;
	Status build_status = InventoryRuntime::restore_from_snapshot_parts(
			p_catalog,
			profile_definition_id,
			p_snapshot.profile_identifier,
			profile->enabled_features,
			profile->limits,
			InventoryId{ p_snapshot.inventory_id },
			p_snapshot.revision,
			p_snapshot.container_allocator_next,
			p_snapshot.item_allocator_next,
			p_snapshot.reference_allocator_next,
			std::move(containers),
			std::move(items),
			std::move(references),
			std::move(item_definition_cache),
			std::move(container_definition_cache),
			candidate,
			p_authority);
	if (!build_status.ok()) {
		return build_status;
	}

	// Full bounded audit (task 4.7), not just the first-only
	// validate_invariants() shortcut, so a rejection can eventually surface
	// more than one offending id to authority logs/editor tools if callers
	// want it; restore() itself only needs (and returns) the first finding.
	std::vector<InvariantFinding> findings;
	Status audit_status = candidate.audit_invariants(findings, 1);
	if (!audit_status.ok()) {
		return audit_status;
	}

	r_runtime = std::move(candidate);
	return ok_status();
}

} // namespace inv
