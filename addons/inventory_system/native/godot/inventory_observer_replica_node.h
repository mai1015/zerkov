#ifndef INVENTORY_SYSTEM_GODOT_OBSERVER_REPLICA_NODE_H
#define INVENTORY_SYSTEM_GODOT_OBSERVER_REPLICA_NODE_H

#include "godot/inventory_catalog.h"
#include "protocol/inv_replica.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot {

// Recipient-only projected value store. This node intentionally does not
// expose InventoryRuntime, canonical SnapshotEnvelope restore, derived
// runtime queries, or authority mutation methods. It accepts only the
// dedicated observer replacement packets and returns a plain redacted view.
class InventoryObserverReplicaNode : public Node {
	GDCLASS(InventoryObserverReplicaNode, Node)

public:
	InventoryObserverReplicaNode();
	~InventoryObserverReplicaNode() override;

	void set_catalog(const Ref<InventoryCatalog> &p_catalog);
	Ref<InventoryCatalog> get_catalog() const { return catalog_resource; }

	Dictionary configure_stream(int64_t p_session_id, int64_t p_actor_id, int64_t p_inventory_id, int64_t p_visibility);
	int64_t get_inventory_id() const;
	int64_t get_generation() const;
	int64_t get_last_applied_sequence() const;
	bool needs_resync() const;
	bool initialized() const { return replica.initialized(); }

	Dictionary apply_snapshot_bytes(const PackedByteArray &p_bytes);
	Dictionary apply_delta_bytes(const PackedByteArray &p_bytes);
	PackedByteArray resync_request_bytes() const;
	// Plain value DTO: no canonical resource or runtime pointer is returned.
	Dictionary view() const;

protected:
	static void _bind_methods();

private:
	Dictionary query_error(const inv::Status &p_status) const;
	void on_replica_event(inv::protocol::ReplicaEventKind p_kind, inv::InventoryId p_inventory, std::uint64_t p_sequence);

	Ref<InventoryCatalog> catalog_resource;
	inv::protocol::InventoryObserverReplica replica;
};

} // namespace godot

#endif // INVENTORY_SYSTEM_GODOT_OBSERVER_REPLICA_NODE_H
