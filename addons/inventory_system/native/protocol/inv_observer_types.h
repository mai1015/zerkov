#ifndef INVENTORY_SYSTEM_PROTOCOL_OBSERVER_TYPES_H
#define INVENTORY_SYSTEM_PROTOCOL_OBSERVER_TYPES_H

#include "core/inv_discovery.h"
#include "core/inv_snapshot.h"

#include <cstdint>
#include <string>
#include <vector>

namespace inv::protocol {

// Observer packets are a separate protocol domain.  The explicit magic keeps
// a projected replacement view from ever being accepted by the canonical
// snapshot/delta decoder even when the enclosing transport uses the same
// protocol major number.
constexpr std::uint16_t OBSERVER_PROTOCOL_VERSION = 1;
constexpr const char *OBSERVER_PROTOCOL_MAGIC = "inventory-observer-v1";

// Stream-local opaque handles use disjoint high signed-int64 namespaces.
// Containers count down through odd values and items through even values;
// neither namespace is derived from (or advanced by) hidden canonical IDs.
// The values remain representable by Godot's signed int64 façade while making
// accidental raw-ID identity projection impossible for ordinary allocators.
constexpr std::uint64_t OBSERVER_OPAQUE_CONTAINER_START = UINT64_C(0x7fffffffffffffff);
constexpr std::uint64_t OBSERVER_OPAQUE_ITEM_START = UINT64_C(0x7ffffffffffffffe);

// A recipient-visible container record.  This is deliberately not a
// SnapshotContainer: observer packets never carry canonical allocator state,
// profile metadata, or references to records that the recipient is not
// allowed to inspect.  `aggregate_only` records are opaque shells; their
// item_count is present only when the visibility policy explicitly preserves
// that aggregate.
struct ObserverContainerView {
	std::uint64_t id = 0;
	std::string definition_identifier;
	std::uint64_t provider_item = 0;
	std::uint32_t item_count = 0;
	bool aggregate_only = false;
};

// Public item rows are copied into this value type.  Redacted items are never
// represented as rows: they are represented, when policy permits, by the
// aggregate item_count on their opaque container shell.  This prevents a
// redacted item's canonical id, quantity, location, component payload, and
// provided-container graph from crossing the authority boundary.
struct ObserverItemView {
	std::uint64_t id = 0;
	std::string item_definition_identifier;
	std::uint64_t quantity = 1;
	SnapshotLocation location;
	std::vector<SnapshotMutableComponent> mutable_components;
	std::vector<std::uint64_t> provided_containers;
};

// Structurally distinct recipient projection.  It intentionally has no
// profile/definition id, allocator counters, canonical references, or
// authority/runtime pointer.  `sequence` is a recipient-view sequence, not
// the authority's canonical revision; hidden-only changes therefore do not
// advance what the observer can learn.
struct ObserverSnapshot {
	std::uint64_t inventory_id = 0;
	VisibilityScope visibility = VisibilityScope::OBSERVER;
	std::uint64_t generation = 0;
	std::uint64_t sequence = 0;
	std::uint64_t manifest_fingerprint = 0;
	std::vector<ObserverContainerView> containers;
	std::vector<ObserverItemView> items;
};

// Recipient-bound replacement packets.  Deltas carry the complete projected
// successor view instead of filtering canonical DeltaOp records: omission of
// a hidden op can leave a replica with stale hidden state or leak a policy
// transition, while a replacement view is auditable and atomic.
struct ObserverSnapshotEnvelope {
	std::uint16_t protocol_version = OBSERVER_PROTOCOL_VERSION;
	std::string protocol_magic = OBSERVER_PROTOCOL_MAGIC;
	DiscoveryRecipientKey recipient;
	std::string manifest_algorithm = MANIFEST_ALGORITHM;
	ObserverSnapshot snapshot;
};

struct ObserverDeltaEnvelope {
	std::uint16_t protocol_version = OBSERVER_PROTOCOL_VERSION;
	std::string protocol_magic = OBSERVER_PROTOCOL_MAGIC;
	DiscoveryRecipientKey recipient;
	std::string manifest_algorithm = MANIFEST_ALGORITHM;
	std::uint64_t predecessor_sequence = 0;
	std::uint64_t successor_sequence = 0;
	ObserverSnapshot snapshot;
};

struct ObserverResyncRequest {
	std::uint16_t protocol_version = OBSERVER_PROTOCOL_VERSION;
	std::string protocol_magic = OBSERVER_PROTOCOL_MAGIC;
	DiscoveryRecipientKey recipient;
	std::uint64_t inventory_id = 0;
	std::uint64_t generation = 0;
	std::uint64_t last_applied_sequence = 0;
};

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_OBSERVER_TYPES_H
