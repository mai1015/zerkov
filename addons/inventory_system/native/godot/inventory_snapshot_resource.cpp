#include "godot/inventory_snapshot_resource.h"

#include "godot/inventory_godot_util.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

namespace godot {

Array InventorySnapshotResource::get_containers() const {
	Array result;
	for (const inv::SnapshotContainer &container : snapshot.containers) {
		Dictionary d;
		d["id"] = int64_t(container.id);
		d["container_definition_identifier"] = String(container.container_definition_identifier.c_str());
		d["provider_item"] = int64_t(container.provider_item);
		result.append(d);
	}
	return result;
}

Array InventorySnapshotResource::get_items() const {
	Array result;
	for (const inv::SnapshotItem &item : snapshot.items) {
		Dictionary d;
		d["id"] = int64_t(item.id);
		d["item_definition_identifier"] = String(item.item_definition_identifier.c_str());
		d["quantity"] = int64_t(item.quantity);
		d["location"] = snapshot_location_dict(item.location);

		Array components;
		for (const inv::SnapshotMutableComponent &component : item.mutable_components) {
			Dictionary cd;
			cd["component_identifier"] = String(component.component_identifier.c_str());
			cd["payload"] = to_packed(component.payload);
			components.append(cd);
		}
		d["mutable_components"] = components;

		PackedInt64Array provided;
		provided.resize(int64_t(item.provided_containers.size()));
		for (std::size_t i = 0; i < item.provided_containers.size(); ++i) {
			provided.set(int64_t(i), int64_t(item.provided_containers[i]));
		}
		d["provided_containers"] = provided;

		result.append(d);
	}
	return result;
}

Array InventorySnapshotResource::get_references() const {
	Array result;
	for (const inv::SnapshotReference &reference : snapshot.references) {
		Dictionary d;
		d["id"] = int64_t(reference.id);
		d["item_id"] = int64_t(reference.item_id);
		result.append(d);
	}
	return result;
}

PackedByteArray InventorySnapshotResource::canonical_bytes() const {
	if (snapshot.visibility != inv::VisibilityScope::OWNER) {
		return PackedByteArray();
	}
	inv::ByteWriter writer;
	const inv::Status status = inv::encode_canonical(snapshot, writer);
	if (!status.ok()) {
		return PackedByteArray();
	}
	return to_packed(writer.bytes());
}

void InventorySnapshotResource::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_inventory_id"), &InventorySnapshotResource::get_inventory_id);
	ClassDB::bind_method(D_METHOD("get_profile_identifier"), &InventorySnapshotResource::get_profile_identifier);
	ClassDB::bind_method(D_METHOD("get_revision"), &InventorySnapshotResource::get_revision);
	ClassDB::bind_method(D_METHOD("get_manifest_fingerprint"), &InventorySnapshotResource::get_manifest_fingerprint);
	ClassDB::bind_method(D_METHOD("get_manifest_algorithm"), &InventorySnapshotResource::get_manifest_algorithm);
	ClassDB::bind_method(D_METHOD("get_visibility"), &InventorySnapshotResource::get_visibility);
	ClassDB::bind_method(D_METHOD("get_containers"), &InventorySnapshotResource::get_containers);
	ClassDB::bind_method(D_METHOD("get_items"), &InventorySnapshotResource::get_items);
	ClassDB::bind_method(D_METHOD("get_references"), &InventorySnapshotResource::get_references);
	ClassDB::bind_method(D_METHOD("canonical_bytes"), &InventorySnapshotResource::canonical_bytes);
	ClassDB::bind_method(D_METHOD("hash"), &InventorySnapshotResource::hash);

	BIND_ENUM_CONSTANT(VISIBILITY_OWNER);
	BIND_ENUM_CONSTANT(VISIBILITY_OBSERVER);
	BIND_ENUM_CONSTANT(VISIBILITY_REDACTED);
}

} // namespace godot
