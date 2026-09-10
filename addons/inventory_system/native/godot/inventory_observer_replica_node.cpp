#include "godot/inventory_observer_replica_node.h"

#include "core/inv_limits.h"
#include "protocol/inv_observer_protocol.h"

#include "godot/inventory_godot_util.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>
#include <string>

namespace godot {

InventoryObserverReplicaNode::InventoryObserverReplicaNode() {
	const ObjectID self_id(get_instance_id());
	replica.set_listener([self_id](inv::protocol::ReplicaEventKind p_kind, inv::InventoryId p_inventory, std::uint64_t p_sequence) {
		InventoryObserverReplicaNode *self = Object::cast_to<InventoryObserverReplicaNode>(ObjectDB::get_instance(self_id));
		if (self != nullptr) {
			self->on_replica_event(p_kind, p_inventory, p_sequence);
		}
	});
}

InventoryObserverReplicaNode::~InventoryObserverReplicaNode() {}

void InventoryObserverReplicaNode::set_catalog(const Ref<InventoryCatalog> &p_catalog) {
	if (replica.initialized()) {
		return;
	}
	catalog_resource = p_catalog;
}

Dictionary InventoryObserverReplicaNode::configure_stream(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_visibility) {
	if (p_session_id <= 0 || p_actor_id <= 0 || p_inventory_id <= 0 ||
			(p_visibility != static_cast<int>(inv::VisibilityScope::OBSERVER) &&
					p_visibility != static_cast<int>(inv::VisibilityScope::REDACTED))) {
		return query_error(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
	}
	const inv::Status status = replica.configure_stream(
			inv::DiscoveryRecipientKey{ static_cast<std::uint64_t>(p_session_id), static_cast<std::uint64_t>(p_actor_id) },
			inv::InventoryId{ static_cast<std::uint64_t>(p_inventory_id) },
			static_cast<inv::VisibilityScope>(p_visibility));
	return query_error(status);
}

int64_t InventoryObserverReplicaNode::get_inventory_id() const {
	return static_cast<int64_t>(replica.id().value);
}

int64_t InventoryObserverReplicaNode::get_generation() const {
	return static_cast<int64_t>(replica.generation());
}

int64_t InventoryObserverReplicaNode::get_last_applied_sequence() const {
	return static_cast<int64_t>(replica.last_applied_sequence());
}

bool InventoryObserverReplicaNode::needs_resync() const {
	return replica.needs_resync();
}

void InventoryObserverReplicaNode::on_replica_event(
		inv::protocol::ReplicaEventKind p_kind,
		inv::InventoryId p_inventory,
		std::uint64_t p_sequence) {
	switch (p_kind) {
		case inv::protocol::ReplicaEventKind::SNAPSHOT_REPLACED:
			emit_signal("snapshot_replaced", static_cast<int64_t>(p_inventory.value), static_cast<int64_t>(p_sequence));
			break;
		case inv::protocol::ReplicaEventKind::DELTA_APPLIED:
			emit_signal("delta_applied", static_cast<int64_t>(p_inventory.value), static_cast<int64_t>(p_sequence));
			break;
		case inv::protocol::ReplicaEventKind::RESYNC_NEEDED:
			emit_signal("resync_needed", static_cast<int64_t>(p_inventory.value), static_cast<int64_t>(p_sequence));
			break;
		}
}

Dictionary InventoryObserverReplicaNode::apply_snapshot_bytes(const PackedByteArray &p_bytes) {
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		return query_error(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED, inv::DiagnosticId::CATALOG_REQUIRES_SEAL));
	}
	if (p_bytes.size() > static_cast<int64_t>(inv::MAX_OBSERVER_SNAPSHOT_BYTES)) {
		return query_error(inv::make_status(inv::StatusCode::PAYLOAD_TOO_LARGE, inv::DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size()));
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::ObserverSnapshotEnvelope envelope;
	inv::Status status = inv::protocol::decode_observer_snapshot(reader, envelope);
	if (status.ok()) {
		status = replica.apply_snapshot(catalog_resource->native_catalog(), envelope);
	}
	return query_error(status);
}

Dictionary InventoryObserverReplicaNode::apply_delta_bytes(const PackedByteArray &p_bytes) {
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		Dictionary result = query_error(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED, inv::DiagnosticId::CATALOG_REQUIRES_SEAL));
		result["applied"] = false;
		return result;
	}
	if (p_bytes.size() > static_cast<int64_t>(inv::MAX_OBSERVER_DELTA_BYTES)) {
		Dictionary result = query_error(inv::make_status(inv::StatusCode::PAYLOAD_TOO_LARGE, inv::DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size()));
		result["applied"] = false;
		return result;
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::ObserverDeltaEnvelope envelope;
	inv::Status status = inv::protocol::decode_observer_delta(reader, envelope);
	if (status.ok()) {
		status = replica.apply_delta(catalog_resource->native_catalog(), envelope);
	}
	Dictionary result = query_error(status);
	// Duplicate/stale observer deltas are a successful idempotent no-op, not
	// a newly installed successor.  Keep the script-facing result aligned with
	// the core replica event semantics (DELTA_APPLIED is the only true apply).
	result["applied"] = status.ok() && status.diagnostic != inv::DiagnosticId::REPLICA_DUPLICATE_DELTA;
	return result;
}

PackedByteArray InventoryObserverReplicaNode::resync_request_bytes() const {
	if (!replica.stream_configured()) {
		return PackedByteArray();
	}
	inv::ByteWriter writer(inv::MAX_OBSERVER_RESYNC_BYTES);
	const inv::Status status = inv::protocol::encode_observer_resync_request(replica.make_resync_request(), writer);
	return status.ok() ? to_packed(writer.bytes()) : PackedByteArray();
}

Dictionary InventoryObserverReplicaNode::view() const {
	Dictionary result;
	if (!replica.initialized()) {
		return result;
	}
	const inv::protocol::ObserverSnapshot &snapshot = replica.view();
	result["inventory_id"] = static_cast<int64_t>(snapshot.inventory_id);
	result["visibility"] = static_cast<int>(snapshot.visibility);
	result["generation"] = static_cast<int64_t>(snapshot.generation);
	result["sequence"] = static_cast<int64_t>(snapshot.sequence);
	result["manifest_fingerprint"] = String(std::to_string(snapshot.manifest_fingerprint).c_str());
	Array containers;
	for (const inv::protocol::ObserverContainerView &container : snapshot.containers) {
		Dictionary value;
		value["id"] = static_cast<int64_t>(container.id);
		value["definition_identifier"] = String(container.definition_identifier.c_str());
		value["provider_item"] = static_cast<int64_t>(container.provider_item);
		value["item_count"] = static_cast<int>(container.item_count);
		value["aggregate_only"] = container.aggregate_only;
		containers.append(value);
	}
	result["containers"] = containers;
	Array items;
	for (const inv::protocol::ObserverItemView &item : snapshot.items) {
		Dictionary value;
		value["id"] = static_cast<int64_t>(item.id);
		value["item_definition_identifier"] = String(item.item_definition_identifier.c_str());
		value["quantity"] = static_cast<int64_t>(item.quantity);
		value["location"] = snapshot_location_dict(item.location);
		Array components;
		for (const inv::SnapshotMutableComponent &component : item.mutable_components) {
			Dictionary component_value;
			component_value["component_identifier"] = String(component.component_identifier.c_str());
			component_value["payload"] = to_packed(component.payload);
			components.append(component_value);
		}
		value["mutable_components"] = components;
		PackedInt64Array provided;
		provided.resize(static_cast<int64_t>(item.provided_containers.size()));
		for (std::size_t i = 0; i < item.provided_containers.size(); ++i) {
			provided.set(static_cast<int64_t>(i), static_cast<int64_t>(item.provided_containers[i]));
		}
		value["provided_containers"] = provided;
		items.append(value);
	}
	result["items"] = items;
	return result;
}

Dictionary InventoryObserverReplicaNode::query_error(const inv::Status &p_status) const {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["status"] = status_dict(p_status);
	return result;
}

void InventoryObserverReplicaNode::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_catalog", "catalog"), &InventoryObserverReplicaNode::set_catalog);
	ClassDB::bind_method(D_METHOD("get_catalog"), &InventoryObserverReplicaNode::get_catalog);
	ClassDB::bind_method(D_METHOD("configure_stream", "session_id", "actor_id", "inventory_id", "visibility"), &InventoryObserverReplicaNode::configure_stream);
	ClassDB::bind_method(D_METHOD("get_inventory_id"), &InventoryObserverReplicaNode::get_inventory_id);
	ClassDB::bind_method(D_METHOD("get_generation"), &InventoryObserverReplicaNode::get_generation);
	ClassDB::bind_method(D_METHOD("get_last_applied_sequence"), &InventoryObserverReplicaNode::get_last_applied_sequence);
	ClassDB::bind_method(D_METHOD("needs_resync"), &InventoryObserverReplicaNode::needs_resync);
	ClassDB::bind_method(D_METHOD("initialized"), &InventoryObserverReplicaNode::initialized);
	ClassDB::bind_method(D_METHOD("apply_snapshot_bytes", "bytes"), &InventoryObserverReplicaNode::apply_snapshot_bytes);
	ClassDB::bind_method(D_METHOD("apply_delta_bytes", "bytes"), &InventoryObserverReplicaNode::apply_delta_bytes);
	ClassDB::bind_method(D_METHOD("resync_request_bytes"), &InventoryObserverReplicaNode::resync_request_bytes);
	ClassDB::bind_method(D_METHOD("view"), &InventoryObserverReplicaNode::view);

	ADD_SIGNAL(MethodInfo("snapshot_replaced", PropertyInfo(Variant::INT, "inventory_id"), PropertyInfo(Variant::INT, "sequence")));
	ADD_SIGNAL(MethodInfo("delta_applied", PropertyInfo(Variant::INT, "inventory_id"), PropertyInfo(Variant::INT, "sequence")));
	ADD_SIGNAL(MethodInfo("resync_needed", PropertyInfo(Variant::INT, "inventory_id"), PropertyInfo(Variant::INT, "last_applied_sequence")));
}

} // namespace godot
