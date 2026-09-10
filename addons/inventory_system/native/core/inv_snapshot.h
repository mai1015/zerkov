#ifndef INVENTORY_SYSTEM_CORE_SNAPSHOT_H
#define INVENTORY_SYSTEM_CORE_SNAPSHOT_H

#include "core/inv_bytes.h"
#include "core/inv_catalog.h"
#include "core/inv_identity_authority.h"
#include "core/inv_ids.h"
#include "core/inv_identifier.h"
#include "core/inv_runtime_state.h"
#include "core/inv_status.h"

#include <cstdint>
#include <string>
#include <vector>

// Immutable canonical inventory snapshots (task 4.6): a deep, plain-value
// copy of one InventoryRuntime's complete canonical state, a canonical
// fixed-width little-endian byte encoding of that value, and defensive
// restoration back into a runtime. See inventory-runtime spec, "Immutable
// Canonical Snapshots", and design.md "Runtime state and invariants" /
// "Authority, protocol, and persistence" (canonical binary encoding is the
// compatibility/hashing format).
namespace inv {

// A plain annotation for now -- full owner/observer/redacted content
// projection is a later protocol slice (see design.md "Authority, protocol,
// and persistence": "Visibility projection occurs before encoding").
enum class VisibilityScope : std::uint8_t {
	OWNER = 0,
	OBSERVER = 1,
	REDACTED = 2,
};

struct SnapshotContainer {
	std::uint64_t id = 0;
	// Portable across peers: resolved back to a DefinitionId via the local
	// catalog on restore(), never transmitted as a raw DefinitionId.
	std::string container_definition_identifier;
	std::uint64_t provider_item = 0; // 0 (invalid ItemInstanceId) == root container.
};

struct SnapshotMutableComponent {
	std::string component_identifier;
	std::vector<std::uint8_t> payload;
};

// Append-only; encoded as a u8 tag distinct from ItemLocation's std::variant
// index so the wire format never depends on that variant's declaration
// order.
enum class SnapshotLocationKind : std::uint8_t {
	SPATIAL = 1,
	SLOT = 2,
	LIST = 3,
};

// Flattened, self-describing counterpart of ItemLocation. Only the fields
// relevant to `kind` are meaningful; the others are left at their default.
struct SnapshotLocation {
	SnapshotLocationKind kind = SnapshotLocationKind::SPATIAL;
	std::uint64_t container = 0;
	std::uint32_t x = 0;
	std::uint32_t y = 0;
	bool rotated = false;
	std::string slot_identifier;
	std::uint32_t ordinal = 0;
};

struct SnapshotItem {
	std::uint64_t id = 0;
	std::string item_definition_identifier;
	std::uint64_t quantity = 1;
	SnapshotLocation location;
	// Canonical ascending order by component_identifier (mirrors
	// ItemInstance::mutable_components); restore()'s invariant audit rejects
	// a decoded snapshot that violates this.
	std::vector<SnapshotMutableComponent> mutable_components;
	// Raw ContainerInstanceIds this item provides, in the same order
	// ItemInstance::provided_containers held them.
	std::vector<std::uint64_t> provided_containers;
};

struct SnapshotReference {
	std::uint64_t id = 0;
	std::uint64_t item_id = 0;
};

// Immutable-by-convention value type: every field is a plain owned value
// (string/vector/scalar), so copying or mutating an InventorySnapshot can
// never alias or affect InventoryRuntime's canonical storage. See
// inventory-runtime spec, "Immutable Canonical Snapshots": "Consumers MUST
// NOT receive mutable access to canonical storage through a snapshot or
// query."
struct InventorySnapshot {
	std::uint64_t inventory_id = 0;
	std::string profile_identifier;
	DefinitionId profile_definition_id = INVALID_DEFINITION_ID;
	std::uint64_t manifest_fingerprint = 0;
	std::string manifest_algorithm;
	std::uint64_t revision = 0;
	std::uint64_t container_allocator_next = 0;
	std::uint64_t item_allocator_next = 0;
	std::uint64_t reference_allocator_next = 0;
	VisibilityScope visibility = VisibilityScope::OWNER;
	// Canonical order (ascending id), inherited from InventoryRuntime's
	// std::map iteration order at snapshot() time.
	std::vector<SnapshotContainer> containers;
	std::vector<SnapshotItem> items;
	std::vector<SnapshotReference> references;
	// fnv1a64 hash of the canonical encoding of every field above (see
	// contracts.md, "Hash and manifest input is the canonical byte
	// representation"). A pure function of those fields, recomputed by
	// snapshot() from the runtime it copies -- never used by restore() as a
	// tamper gate (fnv1a64 is a divergence detector, not tamper-evident; see
	// contracts.md's identical caveat about the manifest fingerprint).
	std::uint64_t hash = 0;
};

// Deep-copies p_runtime's complete canonical state into an immutable
// snapshot value in canonical order, then computes `hash`.
Status snapshot(const InventoryRuntime &p_runtime, VisibilityScope p_scope, InventorySnapshot &r_out);

// Recomputes `hash` from every other field using the same canonical body
// bytes as snapshot(). Recipient-specific projections use this after
// removing hidden records and sanitizing hidden-derived scalar counters.
Status recompute_snapshot_hash(InventorySnapshot &r_snapshot);

// Flattened ItemLocation<->SnapshotLocation conversion and their canonical
// codec, exported (not file-local) so core/inv_deltas.h's location-bearing
// delta ops (ITEM_CREATED/ITEM_MOVED) and the protocol layer's decoders can
// reuse the exact same byte layout as an embedded InventorySnapshot's own
// items[].location instead of re-deriving it (contracts.md: canonical
// collections/encodings never drift by call site). Bytes are IDENTICAL to
// core/inv_commands.h's commands_detail::encode_location()'s own ItemLocation
// encoding (same tag values 1/2/3, same field order per kind), so a decoded
// Command's location field can also be built via decode_snapshot_location()
// + from_snapshot_location() rather than a second, parallel decoder.
SnapshotLocation to_snapshot_location(const ItemLocation &p_location);
Status from_snapshot_location(const SnapshotLocation &p_location, ItemLocation &r_out);
Status encode_snapshot_location(const SnapshotLocation &p_location, ByteWriter &p_writer);
Status decode_snapshot_location(ByteReader &p_reader, SnapshotLocation &r_out);

// Canonical fixed-width little-endian encode/decode. Every canonical integer
// is little-endian; strings and blobs are byte-length prefixed; collections
// are count-prefixed and bounds-checked against inv_limits.h (per-collection
// hard limits, e.g. MAX_CONTAINERS_PER_INVENTORY) BEFORE any per-entry
// allocation or loop. Booleans encode as exactly 0/1. `encode_canonical`
// fails closed (via ByteWriter) if the encoding would exceed
// MAX_SNAPSHOT_BYTES; `decode_canonical` rejects an oversized input before
// reading a single field.
Status encode_canonical(const InventorySnapshot &p_snapshot, ByteWriter &p_writer);
Status decode_canonical(ByteReader &p_reader, InventorySnapshot &r_out);

// Defensive replacement (inventory-runtime spec, "Valid snapshot replaces
// replica state" / "Snapshot fails an invariant"): validates the manifest
// fingerprint/algorithm against p_catalog, resolves the profile and every
// item/container definition identifier, rebuilds a candidate
// InventoryRuntime (including allocator counters), and runs the complete
// invariant audit on the candidate. Only on success does the candidate
// atomically replace r_runtime; on ANY failure r_runtime is left completely
// untouched, and the returned Status is the first structural or audit
// failure (InventoryRuntime::audit_invariants()'s first finding), so
// authority logs/editor tools can report why the snapshot was rejected.
//
// p_authority is optional (default nullptr) and behaves exactly like
// InventoryRuntime::create()'s parameter of the same name (tasks.md 5.4):
// when set, r_runtime's id allocation reads through the shared authority
// and the recorded allocator counters CONVERGE into it rather than being
// restored strictly (see InventoryRuntime::restore_from_snapshot_parts()'s
// doc comment) -- restoring several authority-sharing inventories' snapshots
// in any order converges to the same shared counter.
Status restore(const DefinitionCatalog &p_catalog, const InventorySnapshot &p_snapshot, InventoryRuntime &r_runtime, IdentityAuthority *p_authority = nullptr);

} // namespace inv

#endif // INVENTORY_SYSTEM_CORE_SNAPSHOT_H
