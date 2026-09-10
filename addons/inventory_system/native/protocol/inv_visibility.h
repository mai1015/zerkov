#ifndef INVENTORY_SYSTEM_PROTOCOL_VISIBILITY_H
#define INVENTORY_SYSTEM_PROTOCOL_VISIBILITY_H

#include "core/inv_catalog.h"
#include "core/inv_discovery.h"
#include "core/inv_snapshot.h"
#include "core/inv_status.h"
#include "protocol/inv_observer_types.h"

#include <cstdint>
#include <limits>
#include <map>
#include <string>

// Visibility-safe projection (tasks.md 6.7; inventory-protocol spec,
// "Visibility-Safe Projection"). project_snapshot() turns a full OWNER-scope
// InventorySnapshot (as inv::snapshot() produces) into the bounded
// representation a non-owner recipient is allowed to see, BEFORE that
// recipient's peer ever encodes it onto the wire -- core/inv_snapshot.cpp's
// restore() refuses to install anything this file produces as canonical
// state (VisibilityScope != OWNER is rejected), so a projected snapshot can
// only ever be encoded and sent, never restored.
namespace inv::protocol {

// Placeholder item-definition identifier substituted for a REDACTED item's
// real identity (inventory-protocol spec: "hidden items cannot be inferred
// ... beyond declared policy"). Deliberately never registered in any
// DefinitionCatalog -- it exists only as a wire placeholder for encoding to
// an observer peer.
inline const std::string REDACTED_ITEM_DEFINITION_IDENTIFIER = "inventory.redacted.item";
inline const std::string REDACTED_CONTAINER_DEFINITION_IDENTIFIER = "inventory.redacted.container";

enum class ContainerVisibility : std::uint8_t {
	PUBLIC = 1, // Container present; every item directly inside it is fully visible.
	REDACTED = 2, // Container present; every item directly inside it has its definition identifier/mutable components/provided-container links stripped (see ProjectionPolicy::redacted_preserves_item_count for whether the stripped entries themselves survive).
	HIDDEN = 3, // Container and everything transitively inside it (items, nested containers, cleared references) are absent entirely.
};

// Bounded per-container-definition visibility policy. `overrides` is
// authoritative when it names a container definition identifier;
// `default_visibility` is what every container NOT named in `overrides`
// falls back to. Build the defaults with derive_default_policy() (the
// INSPECT-access-bit rule) and customize `overrides` afterward for a
// game-owned policy, or build one entirely by hand.
struct ProjectionPolicy {
	ContainerVisibility default_visibility = ContainerVisibility::REDACTED;
	// Bounded by the reference snapshot's own container count
	// (MAX_CONTAINERS_PER_INVENTORY) when built via derive_default_policy();
	// a hand-built policy should keep the same bound.
	std::map<std::string, ContainerVisibility> overrides;
	// REDACTED containers: true keeps one stripped SnapshotItem entry per
	// real item (preserving how many there are, per inventory-protocol
	// spec's "item count preserved ... per policy flag"); false omits the
	// entries entirely (count not inferable either).
	bool redacted_preserves_item_count = true;
	// Authority-owned recipient-local opaque container handles. The map is
	// deliberately a stream-owned allocation table rather than a hash of the
	// canonical id: a recipient must not be able to brute-force or collide its
	// way back to an authority-side container id. Authorities keep this table
	// per (recipient, inventory, stream generation) and advance the counter
	// monotonically; standalone projection callers may leave it empty and the
	// projector will allocate a local, non-canonical namespace for this value.
	std::map<std::uint64_t, std::uint64_t> opaque_container_ids;
	std::uint64_t opaque_container_counter = OBSERVER_OPAQUE_CONTAINER_START;
	std::map<std::uint64_t, std::uint64_t> opaque_item_ids;
	std::uint64_t opaque_item_counter = OBSERVER_OPAQUE_ITEM_START;
};

// Derives r_policy.overrides for every container definition referenced by
// p_reference's own containers[] (NOT every container the whole catalog
// knows about -- only the ones actually present in the snapshot being
// projected): INSPECT access bit set -> PUBLIC, else REDACTED (inventory-
// protocol spec's stated default rule). r_policy.default_visibility and any
// pre-existing entry in r_policy.overrides for a container identifier this
// call would also set are OVERWRITTEN (call this first, then customize
// afterward for a game-owned override). Fails if p_reference names a
// container definition identifier the sealed p_catalog does not recognize.
Status derive_default_policy(const DefinitionCatalog &p_catalog, const InventorySnapshot &p_reference, ProjectionPolicy &r_policy);

// p_policy.overrides[p_container_definition_identifier] if present, else
// p_policy.default_visibility.
ContainerVisibility container_visibility(const ProjectionPolicy &p_policy, const std::string &p_container_definition_identifier);

// Projects p_full into r_projected for p_scope:
//   OWNER      -> a verbatim copy (full detail; r_projected.visibility stays
//                 OWNER, so it remains restore()-able by its recipient).
//   otherwise  -> containers survive as structure; each container's own
//                 ContainerVisibility (via p_policy) decides its direct
//                 items' fate (PUBLIC: untouched; REDACTED: stripped, kept
//                 or dropped per p_policy.redacted_preserves_item_count;
//                 HIDDEN: the container record itself, and everything
//                 transitively inside it -- items, nested containers, and
//                 any reference pointing at a removed item -- are absent
//                 entirely). r_projected.visibility is set to p_scope, which
//                 core/inv_snapshot.cpp's restore() refuses to install as
//                 canonical state.
// r_projected always re-encodes cleanly (encode_canonical()/decode_
// canonical() round-trip) and its `hash` is recomputed over its OWN
// (projected) contents -- never the original p_full.hash.
Status project_snapshot(const InventorySnapshot &p_full, VisibilityScope p_scope, const ProjectionPolicy &p_policy, InventorySnapshot &r_projected);

// Strict recipient-safe observer projection.  Unlike project_snapshot(),
// which remains a useful inspection/debug representation for existing
// SnapshotResource callers, this function produces the structurally distinct
// ObserverSnapshot wire value: public containers/items may retain their
// policy-authorized detail, redacted containers become opaque aggregate shells
// (or zero-count shells when count preservation is disabled), and hidden data
// is omitted.  Canonical profile metadata, allocator counters, references,
// redacted item ids/quantities/locations/components, and provided-container
// links never enter the result.  p_sequence is a recipient-view sequence and
// is intentionally independent of p_full.revision.
Status project_observer_snapshot(
		const InventorySnapshot &p_full,
		VisibilityScope p_scope,
		ProjectionPolicy &p_policy,
		DiscoveryRecipientKey p_recipient,
		std::uint64_t p_generation,
		std::uint64_t p_sequence,
		ObserverSnapshot &r_observer);

// Structural validation and a deterministic content fingerprint for the
// observer value store.  The fingerprint excludes sequence/generation so the
// authority can detect whether a visible view changed without exposing a
// hidden canonical revision transition.
Status validate_observer_snapshot(const ObserverSnapshot &p_snapshot);
std::uint64_t observer_snapshot_content_hash(const ObserverSnapshot &p_snapshot);
Status observer_snapshot_content_equal(
		const ObserverSnapshot &p_left,
		const ObserverSnapshot &p_right,
		bool &r_equal);

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_VISIBILITY_H
