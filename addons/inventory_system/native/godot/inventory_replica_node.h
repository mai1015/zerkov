#ifndef INVENTORY_SYSTEM_GODOT_REPLICA_NODE_H
#define INVENTORY_SYSTEM_GODOT_REPLICA_NODE_H

#include "protocol/inv_replica.h"
#include "protocol/inv_discovery_protocol.h"

#include "godot/inventory_catalog.h"
#include "godot/inventory_discovery_resources.h"
#include "godot/inventory_snapshot_resource.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

// The remote-replica façade Node (tasks 7.1, 7.3, 7.4, 7.5; design.md
// "Godot façade and authoring": "A remote replica cannot invoke canonical
// mutation methods"). This is STRUCTURAL role safety, not a runtime check:
// this class wraps `inv::protocol::InventoryReplica`, which has no
// `InventoryTransactionPipeline` member and no Command-accepting method at
// all (see protocol/inv_replica.h's own class comment) -- there is no
// mutation entry point here to forget to guard. This façade represents
// exactly ONE remote inventory per instance; a game submits intent through
// its own bridge to a separate authority-side `InventoryAuthority` and feeds
// this node only the resulting snapshot/delta bytes that authority already
// produced.
namespace godot {

class InventoryReplicaNode : public Node {
	GDCLASS(InventoryReplicaNode, Node)

public:
	InventoryReplicaNode();
	~InventoryReplicaNode() override;

	// Must reference an already-sealed InventoryCatalog compatible with the
	// authority this replica mirrors (apply_snapshot_bytes()/
	// apply_delta_bytes() fail closed on a manifest/protocol mismatch
	// otherwise). Immutable once this instance has applied its first
	// snapshot.
	void set_catalog(const Ref<InventoryCatalog> &p_catalog);
	Ref<InventoryCatalog> get_catalog() const { return catalog_resource; }

	// 0 (invalid) before the first successful apply_snapshot_bytes().
	int64_t get_inventory_id() const;
	int64_t get_last_applied_revision() const;
	bool needs_resync() const;

	// Decodes a `protocol::SnapshotEnvelope` and atomically replaces this
	// replica's state (protocol/inv_replica.h's apply_snapshot() contract).
	// {ok:bool, status:Dictionary}.
	Dictionary apply_snapshot_bytes(const PackedByteArray &p_bytes);
	// Decodes a `protocol::DeltaBatch` and, if it carries an entry for this
	// replica's own inventory id, applies exactly that one InventoryDelta
	// (protocol/inv_replica.h's apply_delta() contract). A batch with no
	// entry for this replica's inventory id is a harmless no-op
	// ({ok:true, applied:false}) -- a game may legitimately broadcast one
	// multi-inventory delta batch to replicas that only care about a subset
	// of it. {ok:bool, applied:bool, status:Dictionary}.
	Dictionary apply_delta_bytes(const PackedByteArray &p_bytes);
	// Encodes a `protocol::ResyncRequest` naming this replica's own
	// inventory id and last_applied_revision, for the game's bridge to
	// forward to the authority. Empty before the first snapshot (there is no
	// inventory id yet to request a resync for).
	PackedByteArray resync_request_bytes() const;

	// Recipient-bound discovery mirror. These methods only decode/apply
	// authority-produced views; no begin, cancel, advance, complete, or reveal
	// method exists on the replica.
	int64_t get_discovery_inventory_id() const;
	int64_t get_discovery_inventory_revision() const;
	int64_t get_discovery_revision() const;
	bool discovery_needs_resync() const;
	Dictionary apply_discovery_view_bytes(const PackedByteArray &p_bytes);
	Dictionary apply_discovery_delta_bytes(const PackedByteArray &p_bytes);
	Ref<InventoryDiscoverySnapshotResource> discovery_view() const;

	// -- Read-only snapshot / derived-query access, identical in shape to
	// InventoryAuthority's read side (7.4) --
	Ref<InventorySnapshotResource> snapshot(int64_t p_visibility = InventorySnapshotResource::VISIBILITY_OWNER) const;
	Dictionary total_mass() const;
	Dictionary container_mass(int64_t p_container_id) const;
	Dictionary container_mass_capacity(int64_t p_container_id) const;
	Dictionary count_in_container(int64_t p_container_id) const;
	Dictionary remaining_count_capacity(int64_t p_container_id) const;
	Dictionary fits(const String &p_item_definition_identifier, const Dictionary &p_destination, int64_t p_quantity = 1, int64_t p_excluding_item = 0) const;
	bool has_feature(const String &p_feature_identifier) const;

protected:
	static void _bind_methods();

private:
	Dictionary query_error(const inv::Status &p_status) const;
	void on_replica_event(inv::protocol::ReplicaEventKind p_kind, inv::InventoryId p_inventory, std::uint64_t p_detail_revision);

	Ref<InventoryCatalog> catalog_resource;
	inv::protocol::InventoryReplica replica;
	inv::protocol::DiscoveryReplica discovery_replica;
	bool listener_installed = false;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_GODOT_REPLICA_NODE_H
