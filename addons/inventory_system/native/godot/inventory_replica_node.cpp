#include "godot/inventory_replica_node.h"

#include "core/inv_limits.h"
#include "core/inv_snapshot.h"

#include "protocol/inv_protocol_codec.h"
#include "protocol/inv_protocol_types.h"

#include "godot/inventory_godot_util.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

InventoryReplicaNode::InventoryReplicaNode() {
	// Checked lifetime identity (7.5), matching InventoryAuthority's
	// ensure_pipeline() precedent: the listener captures only this node's
	// ObjectID and re-resolves it through ObjectDB before touching `this`.
	// Installed once, here, rather than lazily -- `replica` (a plain member)
	// exists for this node's whole lifetime, unlike InventoryAuthority's
	// pipeline, which is built lazily only once a sealed catalog is known.
	const ObjectID self_id(get_instance_id());
	replica.set_listener([self_id](inv::protocol::ReplicaEventKind p_kind, inv::InventoryId p_inventory, std::uint64_t p_detail) {
		InventoryReplicaNode *self = Object::cast_to<InventoryReplicaNode>(ObjectDB::get_instance(self_id));
		if (self == nullptr) {
			return;
		}
		self->on_replica_event(p_kind, p_inventory, p_detail);
	});
	listener_installed = true;
}

InventoryReplicaNode::~InventoryReplicaNode() {}

void InventoryReplicaNode::set_catalog(const Ref<InventoryCatalog> &p_catalog) {
	if (bool(replica.id()) || discovery_replica.initialized()) {
		return; // immutable once a snapshot has been applied -- see header comment.
	}
	catalog_resource = p_catalog;
}

int64_t InventoryReplicaNode::get_discovery_inventory_id() const {
	return int64_t(discovery_replica.inventory().value);
}

int64_t InventoryReplicaNode::get_discovery_inventory_revision() const {
	return discovery_replica.initialized() ? int64_t(discovery_replica.inventory_revision()) : -1;
}

int64_t InventoryReplicaNode::get_discovery_revision() const {
	return discovery_replica.initialized() ? int64_t(discovery_replica.discovery_revision()) : -1;
}

bool InventoryReplicaNode::discovery_needs_resync() const {
	return discovery_replica.needs_resync();
}

int64_t InventoryReplicaNode::get_inventory_id() const {
	return int64_t(replica.id().value);
}

int64_t InventoryReplicaNode::get_last_applied_revision() const {
	return int64_t(replica.last_applied_revision());
}

bool InventoryReplicaNode::needs_resync() const {
	return replica.needs_resync();
}

void InventoryReplicaNode::on_replica_event(inv::protocol::ReplicaEventKind p_kind, inv::InventoryId p_inventory, std::uint64_t p_detail_revision) {
	switch (p_kind) {
		case inv::protocol::ReplicaEventKind::SNAPSHOT_REPLACED:
			emit_signal("snapshot_replaced", int64_t(p_inventory.value), int64_t(p_detail_revision));
			break;
		case inv::protocol::ReplicaEventKind::DELTA_APPLIED:
			emit_signal("delta_applied", int64_t(p_inventory.value), int64_t(p_detail_revision));
			break;
		case inv::protocol::ReplicaEventKind::RESYNC_NEEDED:
			emit_signal("resync_needed", int64_t(p_inventory.value), int64_t(p_detail_revision));
			break;
	}
}

Dictionary InventoryReplicaNode::apply_snapshot_bytes(const PackedByteArray &p_bytes) {
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_snapshot_bytes: catalog is missing or not sealed.");
		return query_error(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::SnapshotEnvelope envelope;
	const inv::Status decode_status = inv::protocol::decode_snapshot_envelope(reader, envelope);
	if (!decode_status.ok()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_snapshot_bytes: failed to decode.");
		return query_error(decode_status);
	}
	const inv::Status apply_status = replica.apply_snapshot(catalog_resource->native_catalog(), envelope);
	if (!apply_status.ok()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_snapshot_bytes: rejected by the replica.");
	}
	return query_error(apply_status);
}

Dictionary InventoryReplicaNode::apply_delta_bytes(const PackedByteArray &p_bytes) {
	if (!bool(replica.id())) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_delta_bytes: no snapshot has been applied yet.");
		Dictionary d = query_error(inv::make_status(inv::StatusCode::SNAPSHOT_REQUIRED));
		d["applied"] = false;
		return d;
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::DeltaBatch batch;
	const inv::Status decode_status = inv::protocol::decode_delta_batch(reader, batch);
	if (!decode_status.ok()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_delta_bytes: failed to decode.");
		Dictionary d = query_error(decode_status);
		d["applied"] = false;
		return d;
	}
	for (const inv::InventoryDelta &delta : batch.inventories) {
		if (delta.inventory != replica.id()) {
			continue;
		}
		const inv::Status apply_status = replica.apply_delta(delta);
		Dictionary d = query_error(apply_status);
		d["applied"] = true;
		return d;
	}
	// No entry for this replica's inventory -- a harmless no-op (see header
	// comment).
	Dictionary d = query_error(inv::ok_status());
	d["applied"] = false;
	return d;
}

PackedByteArray InventoryReplicaNode::resync_request_bytes() const {
	if (!bool(replica.id())) {
		return PackedByteArray();
	}
	const inv::protocol::ResyncRequest request = replica.make_resync_request();
	inv::ByteWriter writer;
	const inv::Status status = inv::protocol::encode_resync_request(request, writer);
	if (!status.ok()) {
		return PackedByteArray();
	}
	return to_packed(writer.bytes());
}

Dictionary InventoryReplicaNode::apply_discovery_view_bytes(const PackedByteArray &p_bytes) {
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_discovery_view_bytes: catalog is missing or not sealed.");
		return query_error(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::DiscoveryViewEnvelope envelope;
	const inv::Status decode_status = inv::protocol::decode_discovery_view(reader, envelope);
	if (!decode_status.ok()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_discovery_view_bytes: failed to decode.");
		return query_error(decode_status);
	}
	if (envelope.view.projected_snapshot.manifest_fingerprint !=
			std::uint64_t(catalog_resource->manifest_fingerprint())) {
		return query_error(inv::make_status(
				inv::StatusCode::MANIFEST_MISMATCH,
				inv::DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS));
	}
	const inv::Status apply_status = discovery_replica.apply_view(envelope);
	if (apply_status.ok()) {
		emit_signal(
				"discovery_snapshot_replaced",
				int64_t(envelope.inventory.value),
				int64_t(envelope.view.inventory_revision),
				int64_t(envelope.view.discovery_revision));
	}
	return query_error(apply_status);
}

Dictionary InventoryReplicaNode::apply_discovery_delta_bytes(const PackedByteArray &p_bytes) {
	if (!discovery_replica.initialized()) {
		return query_error(inv::make_status(inv::StatusCode::SNAPSHOT_REQUIRED));
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::DiscoveryDeltaEnvelope envelope;
	const inv::Status decode_status = inv::protocol::decode_discovery_delta(reader, envelope);
	if (!decode_status.ok()) {
		UtilityFunctions::push_error("InventoryReplicaNode.apply_discovery_delta_bytes: failed to decode.");
		return query_error(decode_status);
	}
	if (catalog_resource.is_null() || !catalog_resource->is_sealed() ||
			envelope.delta.view.projected_snapshot.manifest_fingerprint !=
					std::uint64_t(catalog_resource->manifest_fingerprint())) {
		return query_error(inv::make_status(
				inv::StatusCode::MANIFEST_MISMATCH,
				inv::DiagnosticId::MANIFEST_FINGERPRINT_DIFFERS));
	}
	const inv::Status apply_status = discovery_replica.apply_delta(envelope);
	if (apply_status.ok()) {
		emit_signal(
				"discovery_delta_applied",
				int64_t(envelope.inventory.value),
				int64_t(discovery_replica.inventory_revision()),
				int64_t(discovery_replica.discovery_revision()));
	} else if (discovery_replica.needs_resync()) {
		emit_signal(
				"discovery_resync_needed",
				int64_t(discovery_replica.inventory().value),
				int64_t(discovery_replica.inventory_revision()),
				int64_t(discovery_replica.discovery_revision()));
	}
	return query_error(apply_status);
}

Ref<InventoryDiscoverySnapshotResource> InventoryReplicaNode::discovery_view() const {
	if (!discovery_replica.initialized()) {
		return Ref<InventoryDiscoverySnapshotResource>();
	}
	inv::protocol::DiscoveryViewEnvelope envelope;
	envelope.inventory = discovery_replica.inventory();
	envelope.view = discovery_replica.view();
	Ref<InventoryDiscoverySnapshotResource> resource;
	resource.instantiate();
	resource->set_native_envelope(envelope);
	return resource;
}

Ref<InventorySnapshotResource> InventoryReplicaNode::snapshot(int64_t p_visibility) const {
	if (!bool(replica.id())) {
		UtilityFunctions::push_error("InventoryReplicaNode.snapshot: no snapshot has been applied yet.");
		return Ref<InventorySnapshotResource>();
	}
	if (p_visibility != InventorySnapshotResource::VISIBILITY_OWNER &&
			p_visibility != InventorySnapshotResource::VISIBILITY_OBSERVER &&
			p_visibility != InventorySnapshotResource::VISIBILITY_REDACTED) {
		UtilityFunctions::push_error("InventoryReplicaNode.snapshot: visibility is out of range.");
		return Ref<InventorySnapshotResource>();
	}
	inv::InventorySnapshot snap;
	const inv::Status status = inv::snapshot(replica.inventory(), inv::VisibilityScope(p_visibility), snap);
	if (!status.ok()) {
		UtilityFunctions::push_error("InventoryReplicaNode.snapshot: failed to build the snapshot.");
		return Ref<InventorySnapshotResource>();
	}
	Ref<InventorySnapshotResource> resource;
	resource.instantiate();
	resource->set_native_snapshot(snap);
	return resource;
}

Dictionary InventoryReplicaNode::query_error(const inv::Status &p_status) const {
	Dictionary d;
	d["ok"] = p_status.ok();
	d["status"] = status_dict(p_status);
	return d;
}

Dictionary InventoryReplicaNode::total_mass() const {
	if (!bool(replica.id())) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	int64_t mass_mg = 0;
	const inv::Status status = replica.inventory().total_mass(mass_mg);
	Dictionary d = query_error(status);
	d["mass_mg"] = mass_mg;
	return d;
}

Dictionary InventoryReplicaNode::container_mass(int64_t p_container_id) const {
	if (!bool(replica.id())) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	int64_t mass_mg = 0;
	const inv::Status status = replica.inventory().container_mass(to_container_id(p_container_id), mass_mg);
	Dictionary d = query_error(status);
	d["mass_mg"] = mass_mg;
	return d;
}

Dictionary InventoryReplicaNode::container_mass_capacity(int64_t p_container_id) const {
	if (!bool(replica.id())) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	int64_t mass_capacity_mg = 0;
	const inv::Status status = replica.inventory().container_mass_capacity(to_container_id(p_container_id), mass_capacity_mg);
	Dictionary d = query_error(status);
	d["mass_capacity_mg"] = mass_capacity_mg;
	return d;
}

Dictionary InventoryReplicaNode::count_in_container(int64_t p_container_id) const {
	if (!bool(replica.id())) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	std::uint32_t count = 0;
	const inv::Status status = replica.inventory().count_in_container(to_container_id(p_container_id), count);
	Dictionary d = query_error(status);
	d["count"] = int(count);
	return d;
}

Dictionary InventoryReplicaNode::remaining_count_capacity(int64_t p_container_id) const {
	if (!bool(replica.id())) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	std::uint32_t remaining = 0;
	const inv::Status status = replica.inventory().remaining_count_capacity(to_container_id(p_container_id), remaining);
	Dictionary d = query_error(status);
	d["remaining"] = int(remaining);
	return d;
}

Dictionary InventoryReplicaNode::fits(const String &p_item_definition_identifier, const Dictionary &p_destination, int64_t p_quantity, int64_t p_excluding_item) const {
	if (!bool(replica.id())) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	inv::ItemLocation location;
	if (!location_from_dict(p_destination, location)) {
		return query_error(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	const inv::Status status = replica.inventory().fits(to_std(p_item_definition_identifier), location,
			std::uint64_t(p_quantity < 0 ? 0 : p_quantity), to_item_id(p_excluding_item));
	return query_error(status);
}

bool InventoryReplicaNode::has_feature(const String &p_feature_identifier) const {
	return bool(replica.id()) && replica.inventory().has_feature(to_std(p_feature_identifier));
}

void InventoryReplicaNode::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_catalog", "catalog"), &InventoryReplicaNode::set_catalog);
	ClassDB::bind_method(D_METHOD("get_catalog"), &InventoryReplicaNode::get_catalog);
	ClassDB::bind_method(D_METHOD("get_inventory_id"), &InventoryReplicaNode::get_inventory_id);
	ClassDB::bind_method(D_METHOD("get_last_applied_revision"), &InventoryReplicaNode::get_last_applied_revision);
	ClassDB::bind_method(D_METHOD("needs_resync"), &InventoryReplicaNode::needs_resync);
	ClassDB::bind_method(D_METHOD("apply_snapshot_bytes", "bytes"), &InventoryReplicaNode::apply_snapshot_bytes);
	ClassDB::bind_method(D_METHOD("apply_delta_bytes", "bytes"), &InventoryReplicaNode::apply_delta_bytes);
	ClassDB::bind_method(D_METHOD("resync_request_bytes"), &InventoryReplicaNode::resync_request_bytes);
	ClassDB::bind_method(D_METHOD("get_discovery_inventory_id"), &InventoryReplicaNode::get_discovery_inventory_id);
	ClassDB::bind_method(D_METHOD("get_discovery_inventory_revision"), &InventoryReplicaNode::get_discovery_inventory_revision);
	ClassDB::bind_method(D_METHOD("get_discovery_revision"), &InventoryReplicaNode::get_discovery_revision);
	ClassDB::bind_method(D_METHOD("discovery_needs_resync"), &InventoryReplicaNode::discovery_needs_resync);
	ClassDB::bind_method(D_METHOD("apply_discovery_view_bytes", "bytes"), &InventoryReplicaNode::apply_discovery_view_bytes);
	ClassDB::bind_method(D_METHOD("apply_discovery_delta_bytes", "bytes"), &InventoryReplicaNode::apply_discovery_delta_bytes);
	ClassDB::bind_method(D_METHOD("discovery_view"), &InventoryReplicaNode::discovery_view);
	ClassDB::bind_method(D_METHOD("snapshot", "visibility"), &InventoryReplicaNode::snapshot,
			DEFVAL(int(InventorySnapshotResource::VISIBILITY_OWNER)));
	ClassDB::bind_method(D_METHOD("total_mass"), &InventoryReplicaNode::total_mass);
	ClassDB::bind_method(D_METHOD("container_mass", "container_id"), &InventoryReplicaNode::container_mass);
	ClassDB::bind_method(D_METHOD("container_mass_capacity", "container_id"), &InventoryReplicaNode::container_mass_capacity);
	ClassDB::bind_method(D_METHOD("count_in_container", "container_id"), &InventoryReplicaNode::count_in_container);
	ClassDB::bind_method(D_METHOD("remaining_count_capacity", "container_id"), &InventoryReplicaNode::remaining_count_capacity);
	ClassDB::bind_method(D_METHOD("fits", "item_definition_identifier", "destination", "quantity", "excluding_item"),
			&InventoryReplicaNode::fits, DEFVAL(int64_t(1)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("has_feature", "feature_identifier"), &InventoryReplicaNode::has_feature);

	ADD_SIGNAL(MethodInfo("snapshot_replaced", PropertyInfo(Variant::INT, "inventory_id"), PropertyInfo(Variant::INT, "revision")));
	ADD_SIGNAL(MethodInfo("delta_applied", PropertyInfo(Variant::INT, "inventory_id"), PropertyInfo(Variant::INT, "revision")));
	ADD_SIGNAL(MethodInfo("resync_needed", PropertyInfo(Variant::INT, "inventory_id"), PropertyInfo(Variant::INT, "last_applied_revision")));
	ADD_SIGNAL(MethodInfo(
			"discovery_snapshot_replaced",
			PropertyInfo(Variant::INT, "inventory_id"),
			PropertyInfo(Variant::INT, "inventory_revision"),
			PropertyInfo(Variant::INT, "discovery_revision")));
	ADD_SIGNAL(MethodInfo(
			"discovery_delta_applied",
			PropertyInfo(Variant::INT, "inventory_id"),
			PropertyInfo(Variant::INT, "inventory_revision"),
			PropertyInfo(Variant::INT, "discovery_revision")));
	ADD_SIGNAL(MethodInfo(
			"discovery_resync_needed",
			PropertyInfo(Variant::INT, "inventory_id"),
			PropertyInfo(Variant::INT, "inventory_revision"),
			PropertyInfo(Variant::INT, "discovery_revision")));
}

} // namespace godot
