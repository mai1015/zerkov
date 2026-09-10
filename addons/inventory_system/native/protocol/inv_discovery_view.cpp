#include "protocol/inv_discovery_view.h"

#include "core/inv_builtin_features.h"
#include "core/inv_limits.h"

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <utility>

namespace inv::protocol {

namespace {

Status disclose_layout(const ContainerDefinition &p_definition, DiscoveryContainerView &r_view) {
	r_view.layout_revealed = true;
	r_view.layout_kind = layout_kind(p_definition.layout);
	if (const SpatialGridLayout *grid = std::get_if<SpatialGridLayout>(&p_definition.layout)) {
		r_view.width = grid->width;
		r_view.height = grid->height;
		return ok_status();
	}
	if (const NamedSlotsLayout *slots = std::get_if<NamedSlotsLayout>(&p_definition.layout)) {
		std::uint64_t capacity = 0;
		for (const NamedSlotDefinition &slot : slots->slots) {
			if (capacity > std::numeric_limits<std::uint32_t>::max() - slot.max_items) {
				return make_status(StatusCode::ARITHMETIC_ERROR, DiagnosticId::OVERFLOW_DETECTED);
			}
			capacity += slot.max_items;
		}
		r_view.capacity = static_cast<std::uint32_t>(capacity);
		return ok_status();
	}
	r_view.capacity = std::get<OrderedListLayout>(p_definition.layout).max_entries;
	return ok_status();
}

bool task_matches_container(const DiscoveryTask &p_task, InventoryId p_inventory, ContainerInstanceId p_container) {
	return p_task.kind == DiscoveryTaskKind::CONTAINER_SEARCH &&
			p_task.inventory == p_inventory && p_task.container == p_container;
}

bool task_matches_item(const DiscoveryTask &p_task, InventoryId p_inventory, ItemInstanceId p_item) {
	return p_task.kind == DiscoveryTaskKind::ITEM_SCAN &&
			p_task.inventory == p_inventory && p_task.item == p_item;
}

} // namespace

Status build_discovery_view(
		const InventoryRuntime &p_runtime,
		DiscoveryStateStore &r_store,
		DiscoveryRecipientKey p_recipient,
		DiscoveryView &r_view) {
	if (!p_runtime.has_feature(FEATURE_DISCOVERY)) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::DISCOVERY_FEATURE_REQUIRED);
	}
	Status reconcile_status = r_store.reconcile(p_runtime);
	if (!reconcile_status.ok()) {
		return reconcile_status;
	}

	DiscoveryView result;
	result.inventory_revision = p_runtime.revision();
	Status revision_status = r_store.discovery_revision(p_recipient, p_runtime.id(), result.discovery_revision);
	if (!revision_status.ok()) {
		return revision_status;
	}
	DiscoveryTask active;
	Status task_status = r_store.active_task(p_recipient, active);
	if (!task_status.ok()) {
		return task_status;
	}
	result.task.actor_busy = active.active();

	InventorySnapshot full;
	Status snapshot_status = snapshot(p_runtime, VisibilityScope::OWNER, full);
	if (!snapshot_status.ok()) {
		return snapshot_status;
	}

	std::set<ContainerInstanceId> eligible_containers;
	std::set<ContainerInstanceId> processed_containers;
	std::set<std::uint64_t> visible_container_ids;
	std::set<std::uint64_t> visible_item_ids;
	for (ContainerInstanceId root : p_runtime.root_containers()) {
		eligible_containers.insert(root);
	}

	while (!eligible_containers.empty()) {
		const ContainerInstanceId container_id = *eligible_containers.begin();
		eligible_containers.erase(eligible_containers.begin());
		if (!processed_containers.insert(container_id).second) {
			continue;
		}
		const ContainerInstance *container = p_runtime.find_container(container_id);
		const ContainerDefinition *definition = p_runtime.container_definition(container_id);
		if (container == nullptr || definition == nullptr) {
			return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::DISCOVERY_TARGET_STALE, container_id.value);
		}

		const DiscoveryPolicyDefinition *policy = p_runtime.discovery_policy(container_id);
		const bool staged = policy != nullptr;
		DiscoveryContainerStage stage = DiscoveryContainerStage::INDEXED;
		if (staged) {
			Status stage_status = r_store.container_stage(p_recipient, p_runtime.id(), container_id, stage);
			if (!stage_status.ok()) {
				return stage_status;
			}
			DiscoveryContainerView container_view;
			container_view.stage = stage;
			container_view.shell_label = policy->shell_label;
			if (container->provider_item && visible_item_ids.count(container->provider_item.value) != 0) {
				container_view.provider_item_id = container->provider_item.value;
			}

			if (stage != DiscoveryContainerStage::INDEXED) {
				Status token_status = r_store.issue_container_token(
						p_recipient,
						p_runtime.id(),
						p_runtime.revision(),
						container_id,
						container_view.token);
				if (!token_status.ok()) {
					return token_status;
				}
				if (task_matches_container(active, p_runtime.id(), container_id)) {
					container_view.elapsed_ms = active.elapsed_ms;
					container_view.duration_ms = active.duration_ms;
					result.task.kind = active.kind;
					result.task.target_token = container_view.token;
					result.task.elapsed_ms = active.elapsed_ms;
					result.task.duration_ms = active.duration_ms;
				}
			} else {
				container_view.container_id = container_id.value;
				Status layout_status = disclose_layout(*definition, container_view);
				if (!layout_status.ok()) {
					return layout_status;
				}
				const std::vector<ItemInstanceId> direct_items = p_runtime.items_in_container(container_id);
				if (direct_items.size() > std::numeric_limits<std::uint32_t>::max()) {
					return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
				}
				container_view.item_count = static_cast<std::uint32_t>(direct_items.size());
				for (ItemInstanceId item_id : direct_items) {
					if (r_store.item_revealed(p_recipient, p_runtime.id(), item_id)) {
						visible_item_ids.insert(item_id.value);
						continue;
					}
					DiscoveryEntryView entry;
					Status token_status = r_store.issue_item_token(
							p_recipient,
							p_runtime.id(),
							p_runtime.revision(),
							container_id,
							item_id,
							entry.token);
					if (!token_status.ok()) {
						return token_status;
					}
					if (task_matches_item(active, p_runtime.id(), item_id)) {
						entry.stage = DiscoveryEntryStage::SCANNING;
						entry.elapsed_ms = active.elapsed_ms;
						entry.duration_ms = active.duration_ms;
						result.task.kind = active.kind;
						result.task.target_token = entry.token;
						result.task.elapsed_ms = active.elapsed_ms;
						result.task.duration_ms = active.duration_ms;
					}
					container_view.entries.push_back(entry);
				}
			}
			result.containers.push_back(std::move(container_view));
		}

		if (!staged || stage == DiscoveryContainerStage::INDEXED) {
			visible_container_ids.insert(container_id.value);
			for (ItemInstanceId item_id : p_runtime.items_in_container(container_id)) {
				if (!staged || r_store.item_revealed(p_recipient, p_runtime.id(), item_id)) {
					visible_item_ids.insert(item_id.value);
				}
			}
		}

		// Only a disclosed provider item makes its nested containers eligible.
		// A staged parent therefore cannot leak descendant shells.
		for (std::uint64_t item_raw : visible_item_ids) {
			const ItemInstance *item = p_runtime.find_item(ItemInstanceId{ item_raw });
			if (item == nullptr || location_container(item->location) != container_id) {
				continue;
			}
			for (ContainerInstanceId provided : item->provided_containers) {
				if (processed_containers.count(provided) == 0) {
					eligible_containers.insert(provided);
				}
			}
		}
	}

	InventorySnapshot projected = full;
	projected.visibility = VisibilityScope::REDACTED;
	// These counters are authority allocation state and can reveal hidden
	// population even when every hidden record is omitted.
	projected.container_allocator_next = 0;
	projected.item_allocator_next = 0;
	projected.reference_allocator_next = 0;
	projected.containers.clear();
	projected.items.clear();
	projected.references.clear();

	for (const SnapshotContainer &container : full.containers) {
		if (visible_container_ids.count(container.id) == 0) {
			continue;
		}
		SnapshotContainer kept = container;
		if (p_runtime.discovery_policy(ContainerInstanceId{ container.id }) != nullptr) {
			kept.container_definition_identifier = DISCOVERY_INDEXED_CONTAINER_IDENTIFIER;
		}
		if (kept.provider_item != 0 && visible_item_ids.count(kept.provider_item) == 0) {
			kept.provider_item = 0;
		}
		projected.containers.push_back(std::move(kept));
	}

	for (const SnapshotItem &item : full.items) {
		if (visible_item_ids.count(item.id) == 0 ||
				visible_container_ids.count(item.location.container) == 0) {
			continue;
		}
		SnapshotItem kept = item;
		kept.provided_containers.erase(
				std::remove_if(
						kept.provided_containers.begin(),
						kept.provided_containers.end(),
						[&](std::uint64_t p_container) {
							return visible_container_ids.count(p_container) == 0;
						}),
				kept.provided_containers.end());
		projected.items.push_back(std::move(kept));
	}

	for (const SnapshotReference &reference : full.references) {
		if (visible_item_ids.count(reference.item_id) != 0) {
			projected.references.push_back(reference);
		}
	}

	Status hash_status = recompute_snapshot_hash(projected);
	if (!hash_status.ok()) {
		return hash_status;
	}
	result.projected_snapshot = std::move(projected);
	r_view = std::move(result);
	return ok_status();
}

Status discovery_count_in_container(
		const InventoryRuntime &p_runtime,
		const DiscoveryStateStore &p_store,
		DiscoveryRecipientKey p_recipient,
		ContainerInstanceId p_container,
		std::uint32_t &r_count) {
	if (p_runtime.find_container(p_container) == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_TARGET_STALE);
	}
	if (p_runtime.discovery_policy(p_container) != nullptr) {
		DiscoveryContainerStage stage = DiscoveryContainerStage::UNSEARCHED;
		Status stage_status = p_store.container_stage(p_recipient, p_runtime.id(), p_container, stage);
		if (!stage_status.ok()) {
			return stage_status;
		}
		if (stage != DiscoveryContainerStage::INDEXED) {
			return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_QUERY_REDACTED);
		}
	}
	return p_runtime.count_in_container(p_container, r_count);
}

Status discovery_layout_kind(
		const InventoryRuntime &p_runtime,
		const DiscoveryStateStore &p_store,
		DiscoveryRecipientKey p_recipient,
		ContainerInstanceId p_container,
		OwnershipLayoutKind &r_kind) {
	const ContainerDefinition *definition = p_runtime.container_definition(p_container);
	if (definition == nullptr) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::DISCOVERY_TARGET_STALE);
	}
	if (p_runtime.discovery_policy(p_container) != nullptr) {
		DiscoveryContainerStage stage = DiscoveryContainerStage::UNSEARCHED;
		Status stage_status = p_store.container_stage(p_recipient, p_runtime.id(), p_container, stage);
		if (!stage_status.ok()) {
			return stage_status;
		}
		if (stage != DiscoveryContainerStage::INDEXED) {
			return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::DISCOVERY_QUERY_REDACTED);
		}
	}
	r_kind = layout_kind(definition->layout);
	return ok_status();
}

} // namespace inv::protocol
