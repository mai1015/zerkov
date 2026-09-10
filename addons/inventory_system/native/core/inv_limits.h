#ifndef INVENTORY_SYSTEM_CORE_LIMITS_H
#define INVENTORY_SYSTEM_CORE_LIMITS_H

#include <cstddef>
#include <cstdint>

// Canonical limits and version numbers live in one engine-independent header.
// Values that affect encoding, manifests, or accepted state are compatibility
// inputs: changing one requires the applicable version and fixtures to change.
namespace inv {

// Public API remains pre-1.0 until two materially different games validate it.
constexpr int API_VERSION_MAJOR = 0;
constexpr int API_VERSION_MINOR = 4;
constexpr int API_VERSION_PATCH = 0;

constexpr std::uint16_t PROTOCOL_VERSION = 1;
constexpr std::uint16_t RESOURCE_SCHEMA_VERSION = 1;
constexpr std::uint16_t FEATURE_MODULE_VERSION = 1;
constexpr std::uint16_t PERSISTENCE_SCHEMA_VERSION = 1;
constexpr const char *MANIFEST_ALGORITHM = "fnv1a64-canonical-v1";
constexpr const char *MASS_UNIT = "milligram";

// Stable authored identifiers use lower-case dotted ASCII namespaces.
constexpr std::size_t MAX_IDENTIFIER_BYTES = 128;
constexpr std::size_t MAX_IDENTIFIER_SEGMENTS = 8;
constexpr std::size_t MAX_SOURCE_LABEL_BYTES = 256;
constexpr std::size_t MAX_STRING_BYTES = 256;
constexpr std::size_t MAX_DIAGNOSTIC_BYTES = 256;

// Catalog and feature-composition limits.
constexpr std::size_t MAX_CATALOG_DEFINITIONS = 4096;
constexpr std::size_t MAX_MANIFEST_ENTRIES = 8192;
constexpr std::size_t MAX_MANIFEST_ENTRY_BYTES = 65536;
constexpr std::size_t MAX_FEATURE_MODULES = 64;
constexpr std::size_t MAX_FEATURE_DEPENDENCIES = 16;
constexpr std::size_t MAX_FEATURE_PHASES = 16;
constexpr std::size_t MAX_FEATURE_OWNED_RECORDS = 32;
constexpr std::size_t MAX_TRAIT_SCHEMAS = 512;
constexpr std::size_t MAX_TRAITS_PER_ITEM = 32;
constexpr std::size_t MAX_TRAIT_PAYLOAD_BYTES = 1024;
constexpr std::size_t MAX_CONTAINERS_PER_PROFILE = 64;
constexpr std::size_t MAX_ROOT_CONTAINERS = 32;
constexpr std::size_t MAX_ITEM_PROVIDED_CONTAINERS = 8;
constexpr std::size_t MAX_SLOTS_PER_CONTAINER = 128;
constexpr std::size_t MAX_FILTER_TRAITS = 32;

// Optional staged-discovery feature bounds. These are encoded in
// inventory.feature.discovery's canonical_config only when a catalog opts in,
// rather than in encode_hard_limits(), so catalogs that do not register the
// feature retain their existing manifest/session bytes.
constexpr std::size_t MAX_DISCOVERY_POLICIES = 256;
constexpr std::size_t MAX_DISCOVERY_RECIPIENTS = 256;
constexpr std::size_t MAX_DISCOVERY_INDEXED_CONTAINERS = 512;
constexpr std::size_t MAX_DISCOVERY_REVEALED_ITEMS = 4096;
constexpr std::size_t MAX_DISCOVERY_TOKEN_BINDINGS = 8192;
constexpr std::size_t MAX_DISCOVERY_IDEMPOTENCY_RECORDS = 1024;
constexpr std::uint32_t MAX_DISCOVERY_DURATION_MS = 86400000; // 24 hours.
constexpr std::uint32_t MAX_DISCOVERY_ADVANCE_MS = 60000;

// Authoritative layout and item bounds.
constexpr std::uint32_t MAX_GRID_DIMENSION = 256;
constexpr std::uint32_t MAX_ITEM_FOOTPRINT = 64;
constexpr std::uint32_t MAX_LIST_ENTRIES = 4096;
constexpr std::uint64_t MAX_STACK_QUANTITY = 1000000;
constexpr std::uint32_t MAX_NESTING_DEPTH = 16;

// Runtime aggregate and transaction bounds.
constexpr std::uint32_t MAX_ITEMS_PER_INVENTORY = 4096;
constexpr std::uint32_t MAX_CONTAINERS_PER_INVENTORY = 512;
constexpr std::uint32_t MAX_REFERENCES_PER_INVENTORY = 256;
constexpr std::uint32_t MAX_MUTABLE_COMPONENTS_PER_ITEM = 32;
constexpr std::uint32_t MAX_INVENTORIES_PER_TRANSACTION = 16;
constexpr std::uint32_t MAX_IDEMPOTENCY_RECORDS = 4096;
// Bounds how many reentrant submissions (tasks.md 5.9: a command submitted
// from inside a transaction observer's notification) can wait in the
// pipeline's FIFO queue at once. Deliberately smaller than
// MAX_COLLECTION_COUNT: reentrant fan-out during one notification round is
// expected to stay small, and a bound this tight surfaces runaway
// observer->submit->observer chains quickly instead of silently growing an
// unbounded queue.
constexpr std::uint32_t MAX_PENDING_REENTRANT_TRANSACTIONS = 64;
constexpr std::size_t MAX_SETTLEMENT_PLAN_ENTRIES = 256;
// Bounds InventoryDelta::ops (core/inv_deltas.h, tasks.md 5.1 delta-emission
// phase): the worst case (a subtree transfer/settlement touching many items
// and provided containers) is already bounded well under this by
// MAX_ITEMS_PER_INVENTORY/MAX_CONTAINERS_PER_INVENTORY/
// MAX_SETTLEMENT_PLAN_ENTRIES; matches MAX_COLLECTION_COUNT's magnitude as a
// named, delta-specific cap so protocol/inv_protocol_codec.* has one stable
// bound to enforce before allocating an ops vector from untrusted bytes.
constexpr std::size_t MAX_DELTA_OPS_PER_INVENTORY = 8192;
constexpr std::size_t MAX_PREPARED_QUANTITY_RESERVATIONS = 256;
constexpr std::size_t MAX_PREPARED_QUANTITY_LINES = 64;

// Canonical payload bounds.
constexpr std::size_t MAX_COMMAND_BYTES = 4096;
constexpr std::size_t MAX_DELTA_BYTES = 262144;
constexpr std::size_t MAX_SNAPSHOT_BYTES = 1048576;
constexpr std::size_t MAX_MANIFEST_BYTES = 1048576;
constexpr std::size_t MAX_COLLECTION_COUNT = 8192;
// Engine-independent authenticated gateway state. These are part of the
// hard-limit contract because they bound memory retained for untrusted
// sessions, grants, exact replay bytes, and retired-session identity floors.
constexpr std::size_t MAX_GATEWAY_SESSIONS = 1024;
constexpr std::size_t MAX_GATEWAY_INVENTORY_GRANTS_PER_SESSION = 256;
constexpr std::size_t MAX_GATEWAY_OBSERVER_GRANTS_PER_SESSION = 64;
constexpr std::size_t MAX_GATEWAY_REPLAY_ENTRIES_PER_SESSION = 256;
constexpr std::size_t MAX_GATEWAY_REPLAY_BYTES = 4 * 1024 * 1024;
constexpr std::size_t MAX_GATEWAY_RETIRED_SESSIONS = 4096;
constexpr std::uint32_t DEFAULT_GATEWAY_COMMANDS_PER_SECOND = 32;
constexpr std::uint32_t DEFAULT_GATEWAY_RESYNCS_PER_MINUTE = 16;
constexpr std::uint32_t DEFAULT_GATEWAY_TICK_RATE = 60;
// Recipient-bound observer packets carry only the projected value view. Keep
// the view budget separate from the envelope budgets: a legal maximum-size
// view must still fit its recipient/protocol framing and the full-replacement
// delta uses the same bound as the bootstrap snapshot.
constexpr std::size_t MAX_OBSERVER_VIEW_BYTES = MAX_SNAPSHOT_BYTES;
constexpr std::size_t MAX_OBSERVER_ENVELOPE_OVERHEAD_BYTES = 512;
constexpr std::size_t MAX_OBSERVER_SNAPSHOT_BYTES = MAX_OBSERVER_VIEW_BYTES + MAX_OBSERVER_ENVELOPE_OVERHEAD_BYTES;
constexpr std::size_t MAX_OBSERVER_DELTA_BYTES = MAX_OBSERVER_VIEW_BYTES + MAX_OBSERVER_ENVELOPE_OVERHEAD_BYTES;
constexpr std::size_t MAX_OBSERVER_RESYNC_BYTES = 128;
// Observer streams live for the recipient's observation session rather than
// for one transaction.  Keep a named per-recipient fairness cap so one
// registered actor cannot consume every view slot by enumerating inventories;
// this is intentionally independent of MAX_INVENTORIES_PER_TRANSACTION.
constexpr std::size_t MAX_OBSERVER_STREAMS_PER_RECIPIENT = 32;
// Independent global bound: at the maximum legal view size this caps the
// retained projected-value budget at roughly 512 MiB before allocator/map
// overhead, rather than multiplying the per-recipient cap by every possible
// discovery recipient.
constexpr std::size_t MAX_OBSERVER_STREAMS = 512;
// Retained per-recipient generation epochs survive stream teardown and
// re-registration so delayed packets cannot become valid after a reconnect.
// This is intentionally independent of the live observer-stream cap.
constexpr std::size_t MAX_OBSERVER_GENERATION_KEYS = 65536;
// A recipient view may contain a maximum-size projected snapshot plus the
// token/progress overlay. Reuse the existing snapshot and delta budgets
// rather than hiding an unbounded additive allowance.
constexpr std::size_t MAX_DISCOVERY_VIEW_BYTES = MAX_SNAPSHOT_BYTES + MAX_DELTA_BYTES;
// V1 discovery deltas carry a complete replacement recipient view so a
// newly-revealed ordinary SnapshotItem cannot be partially reconstructed.
constexpr std::size_t MAX_DISCOVERY_DELTA_BYTES = MAX_DISCOVERY_VIEW_BYTES;

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_LIMITS_H
