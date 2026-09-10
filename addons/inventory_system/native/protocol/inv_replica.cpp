#include "protocol/inv_replica.h"

#include "core/inv_snapshot.h"
#include "protocol/inv_visibility.h"

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <type_traits>
#include <utility>
#include <variant>
#include <vector>

namespace inv::protocol {

namespace {

Status validate_observer_catalog_semantics(
		const DefinitionCatalog &p_catalog,
		const ObserverSnapshot &p_snapshot) {
	std::map<std::uint64_t, const ContainerDefinition *> public_containers;
	for (const ObserverContainerView &container : p_snapshot.containers) {
		if (container.aggregate_only) {
			continue;
		}
		if (container.definition_identifier == REDACTED_CONTAINER_DEFINITION_IDENTIFIER) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(container.definition_identifier));
		}
		const ContainerDefinition *definition = p_catalog.find_container(container.definition_identifier);
		if (definition == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(container.definition_identifier));
		}
		public_containers.emplace(container.id, definition);
	}

	std::map<std::uint64_t, const ItemDefinition *> public_items;
	for (const ObserverItemView &item : p_snapshot.items) {
		if (item.item_definition_identifier == REDACTED_ITEM_DEFINITION_IDENTIFIER) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(item.item_definition_identifier));
		}
		const ItemDefinition *definition = p_catalog.find_item(item.item_definition_identifier);
		if (definition == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(item.item_definition_identifier));
		}
		if (item.quantity == 0 || item.quantity > definition->max_stack || item.quantity > MAX_STACK_QUANTITY) {
			return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::STACK_LIMIT_INVALID, item.quantity);
		}
		const auto container_it = public_containers.find(item.location.container);
		if (container_it == public_containers.end()) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, item.location.container);
		}
		const ContainerDefinition &container_definition = *container_it->second;
		switch (item.location.kind) {
			case SnapshotLocationKind::SPATIAL: {
				const SpatialGridLayout *grid = std::get_if<SpatialGridLayout>(&container_definition.layout);
				if (grid == nullptr) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, item.id);
				}
				if (item.location.rotated && (!definition->allow_rotation || !grid->allow_rotation)) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::ITEM_FOOTPRINT_INVALID, item.id);
				}
				const std::uint32_t width = item.location.rotated ? definition->footprint_height : definition->footprint_width;
				const std::uint32_t height = item.location.rotated ? definition->footprint_width : definition->footprint_height;
				if (item.location.x >= grid->width || item.location.y >= grid->height ||
						width > grid->width - item.location.x || height > grid->height - item.location.y) {
					return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::PLACEMENT_OUT_OF_BOUNDS, item.id);
				}
				break;
			}
			case SnapshotLocationKind::SLOT: {
				const NamedSlotsLayout *named = std::get_if<NamedSlotsLayout>(&container_definition.layout);
				if (named == nullptr) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, item.id);
				}
				const auto slot_it = std::find_if(named->slots.begin(), named->slots.end(),
						[&](const NamedSlotDefinition &slot) { return slot.identifier == item.location.slot_identifier; });
				if (slot_it == named->slots.end()) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::SLOT_UNKNOWN,
							hash_string(item.location.slot_identifier));
				}
				break;
			}
			case SnapshotLocationKind::LIST: {
				const OrderedListLayout *list = std::get_if<OrderedListLayout>(&container_definition.layout);
				if (list == nullptr) {
					return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::LAYOUT_INVALID, item.id);
				}
				if (item.location.ordinal >= list->max_entries) {
					return make_status(StatusCode::OUT_OF_BOUNDS, DiagnosticId::LIST_ORDINAL_INVALID, item.location.ordinal);
				}
				break;
			}
			default:
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM, item.id);
		}
		public_items.emplace(item.id, definition);
	}

	// A public provider may expose only public child containers.  Every such
	// edge must still be declared by the provider definition; otherwise a
	// forged observer DTO could invent a new containment relationship even
	// though all of its individual identifiers resolve in the sealed catalog.
	for (const ObserverItemView &item : p_snapshot.items) {
		const auto item_it = public_items.find(item.id);
		if (item_it == public_items.end()) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, item.id);
		}
		for (std::uint64_t provided : item.provided_containers) {
			const auto container_it = public_containers.find(provided);
			if (container_it == public_containers.end()) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, provided);
			}
			if (std::find(item_it->second->provided_containers.begin(), item_it->second->provided_containers.end(),
					container_it->second->identifier) == item_it->second->provided_containers.end()) {
				return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, provided);
			}
		}
	}
	for (const ObserverContainerView &container : p_snapshot.containers) {
		if (container.aggregate_only || container.provider_item == 0) {
			continue;
		}
		const auto provider_it = public_items.find(container.provider_item);
		if (provider_it == public_items.end()) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, container.provider_item);
		}
		if (std::find(provider_it->second->provided_containers.begin(), provider_it->second->provided_containers.end(),
				container.definition_identifier) == provider_it->second->provided_containers.end()) {
			return make_status(StatusCode::INVARIANT_VIOLATION, DiagnosticId::NONE, container.id);
		}
	}
	return ok_status();
}

} // namespace

void InventoryReplica::notify(ReplicaEventKind p_kind, std::uint64_t p_detail_revision) const {
	if (listener_) {
		listener_(p_kind, inventory_.id(), p_detail_revision);
	}
}

void InventoryReplica::set_listener(Listener p_listener) {
	listener_ = std::move(p_listener);
}

ResyncRequest InventoryReplica::make_resync_request() const {
	ResyncRequest request;
	request.inventory = inventory_.id();
	request.last_applied_revision = last_applied_revision_;
	return request;
}

Status InventoryReplica::apply_snapshot(const DefinitionCatalog &p_catalog, const SnapshotEnvelope &p_envelope) {
	InventoryRuntime candidate;
	Status status = restore(p_catalog, p_envelope.snapshot, candidate, &authority_);
	if (!status.ok()) {
		return status;
	}
	inventory_ = std::move(candidate);
	last_applied_revision_ = p_envelope.snapshot.revision;
	needs_resync_ = false;
	notify(ReplicaEventKind::SNAPSHOT_REPLACED, last_applied_revision_);
	return ok_status();
}

// Applies every op in p_delta onto r_clone, in order, via InventoryRuntime's
// friend-only replica_apply_*() primitives (core/inv_runtime_state.h). Each
// op's after-state fields are decoded from their SnapshotLocation/
// SnapshotMutableComponent wire-shaped forms via the SAME conversion helper
// (from_snapshot_location()) the manual-replay test proof in
// native/tests/inv_test_deltas.cpp uses.
Status InventoryReplica::apply_ops(InventoryRuntime &r_clone, const InventoryDelta &p_delta) const {
	for (const DeltaOp &op : p_delta.ops) {
		Status status = std::visit(
				[&](const auto &p_body) -> Status {
					using T = std::decay_t<decltype(p_body)>;
					if constexpr (std::is_same_v<T, ItemCreatedOp>) {
						ItemLocation location;
						Status location_status = from_snapshot_location(p_body.location, location);
						if (!location_status.ok()) {
							return location_status;
						}
						std::vector<MutableComponent> components;
						components.reserve(p_body.mutable_components.size());
						for (const SnapshotMutableComponent &component : p_body.mutable_components) {
							components.push_back(MutableComponent{ component.component_identifier, component.payload });
						}
						std::vector<ContainerInstanceId> provided;
						provided.reserve(p_body.provided_containers.size());
						for (std::uint64_t raw : p_body.provided_containers) {
							provided.push_back(ContainerInstanceId{ raw });
						}
						return r_clone.replica_apply_item_created(
								ItemInstanceId{ p_body.item },
								p_body.item_definition_identifier,
								p_body.quantity,
								location,
								std::move(components),
								std::move(provided));
					} else if constexpr (std::is_same_v<T, ItemDestroyedOp>) {
						return r_clone.replica_apply_item_destroyed(ItemInstanceId{ p_body.item });
					} else if constexpr (std::is_same_v<T, ItemMovedOp>) {
						ItemLocation location;
						Status location_status = from_snapshot_location(p_body.location, location);
						if (!location_status.ok()) {
							return location_status;
						}
						return r_clone.replica_apply_item_moved(ItemInstanceId{ p_body.item }, location);
					} else if constexpr (std::is_same_v<T, ItemQuantityOp>) {
						return r_clone.replica_apply_item_quantity(ItemInstanceId{ p_body.item }, p_body.quantity);
					} else if constexpr (std::is_same_v<T, ItemComponentSetOp>) {
						MutableComponent component{ p_body.component.component_identifier, p_body.component.payload };
						return r_clone.replica_apply_item_component_set(ItemInstanceId{ p_body.item }, std::move(component));
					} else if constexpr (std::is_same_v<T, ItemComponentRemovedOp>) {
						return r_clone.replica_apply_item_component_removed(ItemInstanceId{ p_body.item }, p_body.component_identifier);
					} else if constexpr (std::is_same_v<T, ContainerAdoptedOp>) {
						return r_clone.replica_apply_container_adopted(
								ContainerInstanceId{ p_body.container },
								p_body.container_definition_identifier,
								ItemInstanceId{ p_body.provider_item });
					} else if constexpr (std::is_same_v<T, ContainerReleasedOp>) {
						return r_clone.replica_apply_container_released(ContainerInstanceId{ p_body.container });
					} else if constexpr (std::is_same_v<T, ReferenceAssignedOp>) {
						return r_clone.replica_apply_reference_assigned(ReferenceId{ p_body.reference }, ItemInstanceId{ p_body.item });
					} else {
						static_assert(std::is_same_v<T, ReferenceClearedOp>, "unhandled DeltaOp alternative");
						return r_clone.replica_apply_reference_cleared(ReferenceId{ p_body.reference });
					}
				},
				op);
		if (!status.ok()) {
			return status;
		}
	}
	return ok_status();
}

Status InventoryReplica::apply_delta(const InventoryDelta &p_delta) {
	// 1. Duplicate: already-confirmed, ignored idempotently regardless of
	// needs_resync() (a genuinely duplicate delta never needs a resync to
	// recognize).
	if (p_delta.successor_revision <= last_applied_revision_) {
		return make_status(StatusCode::OK, DiagnosticId::REPLICA_DUPLICATE_DELTA, p_delta.successor_revision);
	}

	// 2. Already desynced: dependent deltas stop applying until a snapshot
	// resolves it (inventory-protocol spec: "dependent deltas stop
	// applying"). No re-notification -- RESYNC_NEEDED already fired once.
	if (needs_resync_) {
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, p_delta.predecessor_revision);
	}

	// 3. Gap.
	if (p_delta.predecessor_revision > last_applied_revision_) {
		needs_resync_ = true;
		notify(ReplicaEventKind::RESYNC_NEEDED, last_applied_revision_);
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, p_delta.predecessor_revision);
	}

	// 4. Matching predecessor: apply onto an isolated clone with its OWN
	// scratch identity scope -- never the shared authority_ member directly
	// -- so a failure partway through leaves authority_ (and therefore this
	// replica's observable snapshot() output) byte-for-byte untouched, not
	// just inventory_'s maps. Only on full success do the scratch counters
	// (which the replica_apply_*() primitives may have converged forward)
	// get folded back into authority_.
	if (p_delta.predecessor_revision == last_applied_revision_) {
		InventoryRuntime clone = inventory_;
		IdentityAuthority scratch_authority = authority_;
		clone.authority_ = &scratch_authority;

		Status status = apply_ops(clone, p_delta);
		if (status.ok()) {
			std::vector<InvariantFinding> findings;
			status = clone.audit_invariants(findings, 1);
		}
		if (!status.ok()) {
			needs_resync_ = true;
			notify(ReplicaEventKind::RESYNC_NEEDED, last_applied_revision_);
			return make_status(StatusCode::SNAPSHOT_REQUIRED, status.diagnostic, status.detail);
		}

		clone.revision_counter = p_delta.successor_revision;
		authority_ = scratch_authority;
		clone.authority_ = &authority_;
		inventory_ = std::move(clone);
		last_applied_revision_ = p_delta.successor_revision;
		needs_resync_ = false;
		notify(ReplicaEventKind::DELTA_APPLIED, last_applied_revision_);
		return ok_status();
	}

	// 5. Impossible transition: predecessor strictly older than current,
	// with a successor that (per check 1) is still strictly newer than
	// current -- a transition no ordered application can ever reach.
	needs_resync_ = true;
	notify(ReplicaEventKind::RESYNC_NEEDED, last_applied_revision_);
	return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_IMPOSSIBLE_TRANSITION, p_delta.predecessor_revision);
}

void InventoryObserverReplica::set_listener(Listener p_listener) {
	listener_ = std::move(p_listener);
}

Status InventoryObserverReplica::configure_stream(
		DiscoveryRecipientKey p_recipient,
		InventoryId p_inventory,
		VisibilityScope p_visibility) {
	if (p_recipient.session_id == 0 || p_recipient.actor_id == 0 ||
			!p_inventory || (p_visibility != VisibilityScope::OBSERVER && p_visibility != VisibilityScope::REDACTED)) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (stream_configured_) {
		if (!(recipient_ == p_recipient) || expected_inventory_ != p_inventory || expected_visibility_ != p_visibility) {
			return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_TARGET_STALE, p_inventory.value);
		}
		return ok_status();
	}
	recipient_ = p_recipient;
	expected_inventory_ = p_inventory;
	expected_visibility_ = p_visibility;
	stream_configured_ = true;
	return ok_status();
}

void InventoryObserverReplica::notify(ReplicaEventKind p_kind, std::uint64_t p_detail_sequence) const {
	if (listener_ && stream_configured_) {
		listener_(p_kind, initialized_ ? id() : expected_inventory_, p_detail_sequence);
	}
}

Status InventoryObserverReplica::validate_packet(
		const DefinitionCatalog &p_catalog,
		const ObserverSnapshot &p_snapshot,
		const DiscoveryRecipientKey &p_recipient) const {
	if (!stream_configured_ || !(p_recipient == recipient_)) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	}
	if (stream_configured_ &&
			(InventoryId{ p_snapshot.inventory_id } != expected_inventory_ || p_snapshot.visibility != expected_visibility_)) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_TARGET_STALE, p_snapshot.inventory_id);
	}
	if (!p_catalog.sealed()) {
		return make_status(StatusCode::CATALOG_NOT_SEALED, DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	const ContentManifest *manifest = p_catalog.manifest();
	if (manifest == nullptr || manifest->fingerprint != p_snapshot.manifest_fingerprint) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS, p_snapshot.manifest_fingerprint);
	}
	// Enforce the cheap bounded structural checks before walking any
	// catalog-facing strings.  Direct C++ callers can construct a DTO without
	// passing through the bounded wire decoder, so this ordering is part of the
	// untrusted-input contract as well as a useful DoS guard.
	Status structural_status = validate_observer_snapshot(p_snapshot);
	if (!structural_status.ok()) {
		return structural_status;
	}
	for (const ObserverContainerView &container : p_snapshot.containers) {
		if (container.aggregate_only) {
			continue;
		}
		if (p_catalog.find_container(container.definition_identifier) == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(container.definition_identifier));
		}
	}
	for (const ObserverItemView &item : p_snapshot.items) {
		if (p_catalog.find_item(item.item_definition_identifier) == nullptr) {
			return make_status(StatusCode::UNKNOWN_DEFINITION, DiagnosticId::DEFINITION_UNKNOWN_REFERENCE,
					hash_string(item.item_definition_identifier));
		}
	}
	return validate_observer_catalog_semantics(p_catalog, p_snapshot);
}

Status InventoryObserverReplica::apply_snapshot(
		const DefinitionCatalog &p_catalog,
		const ObserverSnapshotEnvelope &p_envelope) {
	if (p_envelope.protocol_version != OBSERVER_PROTOCOL_VERSION ||
			p_envelope.protocol_magic != OBSERVER_PROTOCOL_MAGIC ||
			p_envelope.manifest_algorithm != MANIFEST_ALGORITHM) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_envelope.protocol_version);
	}
	Status status = validate_packet(p_catalog, p_envelope.snapshot, p_envelope.recipient);
	if (!status.ok()) {
		return status;
	}
	if (initialized_ && p_envelope.snapshot.inventory_id != view_.inventory_id) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_TARGET_STALE, p_envelope.snapshot.inventory_id);
	}
	if (initialized_ && p_envelope.snapshot.generation < view_.generation) {
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REVISION_STALE, view_.generation);
	}
	if (initialized_ && p_envelope.snapshot.generation == view_.generation) {
		if (p_envelope.snapshot.visibility != view_.visibility) {
			return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_TARGET_STALE,
					static_cast<std::uint64_t>(p_envelope.snapshot.visibility));
		}
		if (p_envelope.snapshot.sequence < view_.sequence) {
			return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, view_.sequence);
		}
		if (p_envelope.snapshot.sequence == view_.sequence) {
			bool same_content = false;
			Status equality_status = observer_snapshot_content_equal(p_envelope.snapshot, view_, same_content);
			if (!equality_status.ok()) {
				return equality_status;
			}
			if (same_content) {
				if (needs_resync_) {
					// A complete replacement is also the recovery mechanism for an
					// equivocation latch.  It may be byte-identical to the last good
					// view (for example, the conflicting packet was forged), but the
					// caller has still supplied the required authoritative snapshot.
					needs_resync_ = false;
					notify(ReplicaEventKind::SNAPSHOT_REPLACED, view_.sequence);
				}
				return make_status(StatusCode::OK, DiagnosticId::REPLICA_DUPLICATE_DELTA, view_.sequence);
			}
			if (!needs_resync_) {
				needs_resync_ = true;
				notify(ReplicaEventKind::RESYNC_NEEDED, view_.sequence);
			}
			return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_IMPOSSIBLE_TRANSITION, view_.sequence);
		}
	}
	// Copy only after every identity/shape check succeeds.  A malformed or
	// stale replacement therefore leaves the last good view and resync latch
	// untouched.
	view_ = p_envelope.snapshot;
	initialized_ = true;
	stream_configured_ = true;
	needs_resync_ = false;
	notify(ReplicaEventKind::SNAPSHOT_REPLACED, view_.sequence);
	return ok_status();
}

Status InventoryObserverReplica::apply_delta(
		const DefinitionCatalog &p_catalog,
		const ObserverDeltaEnvelope &p_envelope) {
	if (p_envelope.protocol_version != OBSERVER_PROTOCOL_VERSION ||
			p_envelope.protocol_magic != OBSERVER_PROTOCOL_MAGIC ||
			p_envelope.manifest_algorithm != MANIFEST_ALGORITHM) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_envelope.protocol_version);
	}
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (p_envelope.predecessor_sequence == 0 || p_envelope.predecessor_sequence == UINT64_MAX ||
			p_envelope.successor_sequence == 0 || p_envelope.predecessor_sequence > script_max ||
			p_envelope.successor_sequence > script_max) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	Status status = validate_packet(p_catalog, p_envelope.snapshot, p_envelope.recipient);
	if (!status.ok()) {
		return status;
	}
	if (p_envelope.successor_sequence != p_envelope.predecessor_sequence + 1 ||
			p_envelope.snapshot.sequence != p_envelope.successor_sequence) {
		return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE,
				p_envelope.successor_sequence);
	}
	if (!initialized_) {
		if (!needs_resync_) {
			needs_resync_ = true;
			notify(ReplicaEventKind::RESYNC_NEEDED, 0);
		}
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP);
	}
	// Foreign inventory, visibility, or stream generation is an identity
	// rejection, not a sequence gap. Do not poison the last-good stream: the
	// caller may be multiplexing several recipients/inventories over one
	// transport and should be able to continue applying its own packets.
	if (p_envelope.snapshot.inventory_id != view_.inventory_id ||
			p_envelope.snapshot.visibility != view_.visibility) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_TARGET_STALE,
				p_envelope.snapshot.inventory_id);
	}
	if (p_envelope.snapshot.generation < view_.generation) {
		return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, view_.generation);
	}
	if (p_envelope.snapshot.generation > view_.generation) {
		if (!needs_resync_) {
			needs_resync_ = true;
			notify(ReplicaEventKind::RESYNC_NEEDED, view_.sequence);
		}
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, view_.generation);
	}
	if (needs_resync_) {
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, view_.sequence);
	}
	if (p_envelope.successor_sequence < view_.sequence) {
		return make_status(StatusCode::OK, DiagnosticId::REPLICA_DUPLICATE_DELTA, p_envelope.successor_sequence);
	}
	if (p_envelope.successor_sequence == view_.sequence) {
		bool same_content = false;
		Status equality_status = observer_snapshot_content_equal(p_envelope.snapshot, view_, same_content);
		if (!equality_status.ok()) {
			return equality_status;
		}
		if (same_content) {
			return make_status(StatusCode::OK, DiagnosticId::REPLICA_DUPLICATE_DELTA, p_envelope.successor_sequence);
		}
		needs_resync_ = true;
		notify(ReplicaEventKind::RESYNC_NEEDED, view_.sequence);
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_IMPOSSIBLE_TRANSITION, view_.sequence);
	}
	if (p_envelope.predecessor_sequence != view_.sequence ||
			p_envelope.successor_sequence != p_envelope.predecessor_sequence + 1 ||
			p_envelope.snapshot.sequence != p_envelope.successor_sequence) {
		needs_resync_ = true;
		notify(ReplicaEventKind::RESYNC_NEEDED, view_.sequence);
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP, p_envelope.predecessor_sequence);
	}
	view_ = p_envelope.snapshot;
	needs_resync_ = false;
	notify(ReplicaEventKind::DELTA_APPLIED, view_.sequence);
	return ok_status();
}

ObserverResyncRequest InventoryObserverReplica::make_resync_request() const {
	ObserverResyncRequest request;
	request.recipient = recipient_;
	request.inventory_id = stream_configured_ ? expected_inventory_.value : 0;
	request.generation = initialized_ ? view_.generation : 0;
	request.last_applied_sequence = initialized_ ? view_.sequence : 0;
	return request;
}

} // namespace inv::protocol
