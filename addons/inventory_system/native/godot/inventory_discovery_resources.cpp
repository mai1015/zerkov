#include "godot/inventory_discovery_resources.h"

#include "core/inv_limits.h"

#include "godot/inventory_godot_util.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

TypedArray<InventoryDiscoveryEntryResource> InventoryDiscoveryContainerViewResource::get_entries() const {
	TypedArray<InventoryDiscoveryEntryResource> result;
	for (const inv::protocol::DiscoveryEntryView &entry : view.entries) {
		Ref<InventoryDiscoveryEntryResource> resource;
		resource.instantiate();
		resource->set_native_entry(entry);
		result.append(resource);
	}
	return result;
}

Dictionary InventoryDiscoveryResultResource::get_status() const {
	return status_dict(result.status);
}

PackedByteArray InventoryDiscoveryResultResource::canonical_bytes() const {
	inv::ByteWriter writer;
	const inv::Status status = inv::protocol::encode_discovery_result(result, writer);
	return status.ok() ? to_packed(writer.bytes()) : PackedByteArray();
}

Ref<InventorySnapshotResource> InventoryDiscoverySnapshotResource::get_projected_snapshot() const {
	Ref<InventorySnapshotResource> resource;
	resource.instantiate();
	resource->set_native_snapshot(envelope.view.projected_snapshot);
	return resource;
}

TypedArray<InventoryDiscoveryContainerViewResource> InventoryDiscoverySnapshotResource::get_containers() const {
	TypedArray<InventoryDiscoveryContainerViewResource> result;
	for (const inv::protocol::DiscoveryContainerView &view : envelope.view.containers) {
		Ref<InventoryDiscoveryContainerViewResource> resource;
		resource.instantiate();
		resource->set_native_view(view);
		result.append(resource);
	}
	return result;
}

Ref<InventoryDiscoveryTaskResource> InventoryDiscoverySnapshotResource::get_task() const {
	Ref<InventoryDiscoveryTaskResource> resource;
	resource.instantiate();
	resource->set_native_task(envelope.view.task);
	return resource;
}

PackedByteArray InventoryDiscoverySnapshotResource::canonical_bytes() const {
	inv::ByteWriter writer(inv::MAX_DISCOVERY_VIEW_BYTES);
	const inv::Status status = inv::protocol::encode_discovery_view(envelope, writer);
	return status.ok() ? to_packed(writer.bytes()) : PackedByteArray();
}

Ref<InventoryDiscoverySnapshotResource> InventoryDiscoveryDeltaResource::get_replacement_snapshot() const {
	inv::protocol::DiscoveryViewEnvelope replacement;
	replacement.protocol_version = envelope.protocol_version;
	replacement.discovery_protocol_version = envelope.discovery_protocol_version;
	replacement.inventory = envelope.inventory;
	replacement.view = envelope.delta.view;
	Ref<InventoryDiscoverySnapshotResource> resource;
	resource.instantiate();
	resource->set_native_envelope(replacement);
	return resource;
}

PackedByteArray InventoryDiscoveryDeltaResource::canonical_bytes() const {
	inv::ByteWriter writer(inv::MAX_DISCOVERY_DELTA_BYTES);
	const inv::Status status = inv::protocol::encode_discovery_delta(envelope, writer);
	return status.ok() ? to_packed(writer.bytes()) : PackedByteArray();
}

void InventoryDiscoveryEntryResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_token"), &InventoryDiscoveryEntryResource::get_token);
	ClassDB::bind_method(D_METHOD("get_stage"), &InventoryDiscoveryEntryResource::get_stage);
	ClassDB::bind_method(D_METHOD("get_elapsed_ms"), &InventoryDiscoveryEntryResource::get_elapsed_ms);
	ClassDB::bind_method(D_METHOD("get_duration_ms"), &InventoryDiscoveryEntryResource::get_duration_ms);
	BIND_ENUM_CONSTANT(STAGE_UNKNOWN);
	BIND_ENUM_CONSTANT(STAGE_SCANNING);
}

void InventoryDiscoveryContainerViewResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_token"), &InventoryDiscoveryContainerViewResource::get_token);
	ClassDB::bind_method(D_METHOD("get_container_id"), &InventoryDiscoveryContainerViewResource::get_container_id);
	ClassDB::bind_method(D_METHOD("get_provider_item_id"), &InventoryDiscoveryContainerViewResource::get_provider_item_id);
	ClassDB::bind_method(D_METHOD("get_stage"), &InventoryDiscoveryContainerViewResource::get_stage);
	ClassDB::bind_method(D_METHOD("get_shell_label"), &InventoryDiscoveryContainerViewResource::get_shell_label);
	ClassDB::bind_method(D_METHOD("get_elapsed_ms"), &InventoryDiscoveryContainerViewResource::get_elapsed_ms);
	ClassDB::bind_method(D_METHOD("get_duration_ms"), &InventoryDiscoveryContainerViewResource::get_duration_ms);
	ClassDB::bind_method(D_METHOD("is_layout_revealed"), &InventoryDiscoveryContainerViewResource::is_layout_revealed);
	ClassDB::bind_method(D_METHOD("get_layout_kind"), &InventoryDiscoveryContainerViewResource::get_layout_kind);
	ClassDB::bind_method(D_METHOD("get_width"), &InventoryDiscoveryContainerViewResource::get_width);
	ClassDB::bind_method(D_METHOD("get_height"), &InventoryDiscoveryContainerViewResource::get_height);
	ClassDB::bind_method(D_METHOD("get_capacity"), &InventoryDiscoveryContainerViewResource::get_capacity);
	ClassDB::bind_method(D_METHOD("get_item_count"), &InventoryDiscoveryContainerViewResource::get_item_count);
	ClassDB::bind_method(D_METHOD("get_entries"), &InventoryDiscoveryContainerViewResource::get_entries);
	BIND_ENUM_CONSTANT(STAGE_UNSEARCHED);
	BIND_ENUM_CONSTANT(STAGE_SEARCHING);
	BIND_ENUM_CONSTANT(STAGE_INDEXED);
	BIND_ENUM_CONSTANT(LAYOUT_SPATIAL_GRID);
	BIND_ENUM_CONSTANT(LAYOUT_NAMED_SLOTS);
	BIND_ENUM_CONSTANT(LAYOUT_ORDERED_LIST);
}

void InventoryDiscoveryTaskResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_actor_busy"), &InventoryDiscoveryTaskResource::is_actor_busy);
	ClassDB::bind_method(D_METHOD("get_kind"), &InventoryDiscoveryTaskResource::get_kind);
	ClassDB::bind_method(D_METHOD("get_target_token"), &InventoryDiscoveryTaskResource::get_target_token);
	ClassDB::bind_method(D_METHOD("get_elapsed_ms"), &InventoryDiscoveryTaskResource::get_elapsed_ms);
	ClassDB::bind_method(D_METHOD("get_duration_ms"), &InventoryDiscoveryTaskResource::get_duration_ms);
	BIND_ENUM_CONSTANT(TASK_NONE);
	BIND_ENUM_CONSTANT(TASK_CONTAINER_SEARCH);
	BIND_ENUM_CONSTANT(TASK_ITEM_SCAN);
}

void InventoryDiscoveryResultResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_request_id"), &InventoryDiscoveryResultResource::get_request_id);
	ClassDB::bind_method(D_METHOD("get_status"), &InventoryDiscoveryResultResource::get_status);
	ClassDB::bind_method(D_METHOD("is_accepted"), &InventoryDiscoveryResultResource::is_accepted);
	ClassDB::bind_method(D_METHOD("is_replayed"), &InventoryDiscoveryResultResource::is_replayed);
	ClassDB::bind_method(D_METHOD("is_completed"), &InventoryDiscoveryResultResource::is_completed);
	ClassDB::bind_method(D_METHOD("get_inventory_revision"), &InventoryDiscoveryResultResource::get_inventory_revision);
	ClassDB::bind_method(D_METHOD("get_discovery_revision"), &InventoryDiscoveryResultResource::get_discovery_revision);
	ClassDB::bind_method(D_METHOD("get_task_kind"), &InventoryDiscoveryResultResource::get_task_kind);
	ClassDB::bind_method(D_METHOD("get_elapsed_ms"), &InventoryDiscoveryResultResource::get_elapsed_ms);
	ClassDB::bind_method(D_METHOD("get_duration_ms"), &InventoryDiscoveryResultResource::get_duration_ms);
	ClassDB::bind_method(D_METHOD("canonical_bytes"), &InventoryDiscoveryResultResource::canonical_bytes);
}

void InventoryDiscoverySnapshotResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_inventory_id"), &InventoryDiscoverySnapshotResource::get_inventory_id);
	ClassDB::bind_method(D_METHOD("get_inventory_revision"), &InventoryDiscoverySnapshotResource::get_inventory_revision);
	ClassDB::bind_method(D_METHOD("get_discovery_revision"), &InventoryDiscoverySnapshotResource::get_discovery_revision);
	ClassDB::bind_method(D_METHOD("get_projected_snapshot"), &InventoryDiscoverySnapshotResource::get_projected_snapshot);
	ClassDB::bind_method(D_METHOD("get_containers"), &InventoryDiscoverySnapshotResource::get_containers);
	ClassDB::bind_method(D_METHOD("get_task"), &InventoryDiscoverySnapshotResource::get_task);
	ClassDB::bind_method(D_METHOD("canonical_bytes"), &InventoryDiscoverySnapshotResource::canonical_bytes);
}

void InventoryDiscoveryDeltaResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_inventory_id"), &InventoryDiscoveryDeltaResource::get_inventory_id);
	ClassDB::bind_method(D_METHOD("get_predecessor_inventory_revision"), &InventoryDiscoveryDeltaResource::get_predecessor_inventory_revision);
	ClassDB::bind_method(D_METHOD("get_successor_inventory_revision"), &InventoryDiscoveryDeltaResource::get_successor_inventory_revision);
	ClassDB::bind_method(D_METHOD("get_predecessor_discovery_revision"), &InventoryDiscoveryDeltaResource::get_predecessor_discovery_revision);
	ClassDB::bind_method(D_METHOD("get_successor_discovery_revision"), &InventoryDiscoveryDeltaResource::get_successor_discovery_revision);
	ClassDB::bind_method(D_METHOD("get_replacement_snapshot"), &InventoryDiscoveryDeltaResource::get_replacement_snapshot);
	ClassDB::bind_method(D_METHOD("canonical_bytes"), &InventoryDiscoveryDeltaResource::canonical_bytes);
}

} // namespace godot
