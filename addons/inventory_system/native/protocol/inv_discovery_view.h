#ifndef INVENTORY_SYSTEM_PROTOCOL_DISCOVERY_VIEW_H
#define INVENTORY_SYSTEM_PROTOCOL_DISCOVERY_VIEW_H

#include "core/inv_discovery.h"
#include "core/inv_snapshot.h"

#include <cstdint>
#include <string>
#include <vector>

namespace inv::protocol {

// Staged containers use a non-catalog placeholder in the projected snapshot
// after indexing. Authored definition identity and constraints are not part
// of the "size/count" disclosure contract; renderers use the layout fields
// in DiscoveryContainerView instead.
inline const std::string DISCOVERY_INDEXED_CONTAINER_IDENTIFIER = "inventory.discovery.indexed_container";

struct DiscoveryEntryView {
	std::uint64_t token = 0;
	DiscoveryEntryStage stage = DiscoveryEntryStage::UNKNOWN;
	std::uint32_t elapsed_ms = 0;
	std::uint32_t duration_ms = 0;
};

struct DiscoveryContainerView {
	// Pre-index identity is token-only. container_id becomes nonzero only
	// after INDEXED. provider_item_id is nonzero only when the provider item
	// is already revealed in this same view.
	std::uint64_t token = 0;
	std::uint64_t container_id = 0;
	std::uint64_t provider_item_id = 0;
	DiscoveryContainerStage stage = DiscoveryContainerStage::UNSEARCHED;
	std::string shell_label;
	std::uint32_t elapsed_ms = 0;
	std::uint32_t duration_ms = 0;

	bool layout_revealed = false;
	OwnershipLayoutKind layout_kind = OwnershipLayoutKind::SPATIAL_GRID;
	std::uint32_t width = 0;
	std::uint32_t height = 0;
	std::uint32_t capacity = 0;
	std::uint32_t item_count = 0;
	std::vector<DiscoveryEntryView> entries;
};

struct DiscoveryTaskView {
	bool actor_busy = false;
	DiscoveryTaskKind kind = DiscoveryTaskKind::NONE;
	std::uint64_t target_token = 0;
	std::uint32_t elapsed_ms = 0;
	std::uint32_t duration_ms = 0;
};

struct DiscoveryView {
	std::uint64_t inventory_revision = 0;
	std::uint64_t discovery_revision = 0;
	InventorySnapshot projected_snapshot;
	std::vector<DiscoveryContainerView> containers;
	DiscoveryTaskView task;
};

// Produces a recipient-safe view. Unknown items are absent from the embedded
// snapshot and represented only by entry tokens; unindexed containers omit
// definition/layout/count/content entirely. Hidden allocator counters are
// zeroed before the projection hash is recomputed.
Status build_discovery_view(
		const InventoryRuntime &p_runtime,
		DiscoveryStateStore &r_store,
		DiscoveryRecipientKey p_recipient,
		DiscoveryView &r_view);

// Derived-query wrappers enforce the same disclosure boundary as the view.
Status discovery_count_in_container(
		const InventoryRuntime &p_runtime,
		const DiscoveryStateStore &p_store,
		DiscoveryRecipientKey p_recipient,
		ContainerInstanceId p_container,
		std::uint32_t &r_count);
Status discovery_layout_kind(
		const InventoryRuntime &p_runtime,
		const DiscoveryStateStore &p_store,
		DiscoveryRecipientKey p_recipient,
		ContainerInstanceId p_container,
		OwnershipLayoutKind &r_kind);

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_DISCOVERY_VIEW_H
