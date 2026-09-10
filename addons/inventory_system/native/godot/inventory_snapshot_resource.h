#ifndef INVENTORY_SYSTEM_GODOT_SNAPSHOT_RESOURCE_H
#define INVENTORY_SYSTEM_GODOT_SNAPSHOT_RESOURCE_H

#include "core/inv_snapshot.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

// Immutable DTO Resource (task 7.4): every read accessor below is generated
// on demand from `snapshot`, a plain owned `inv::InventorySnapshot` value
// copy -- never a pointer into `InventoryRuntime`'s canonical storage, so
// nothing reachable from script can mutate authority state through this
// class (inventory-runtime spec, "Consumers MUST NOT receive mutable access
// to canonical storage through a snapshot or query").
namespace godot {

class InventorySnapshotResource : public Resource {
	GDCLASS(InventorySnapshotResource, Resource)

public:
	enum Visibility {
		VISIBILITY_OWNER = 0,
		VISIBILITY_OBSERVER = 1,
		VISIBILITY_REDACTED = 2,
	};

	int64_t get_inventory_id() const { return int64_t(snapshot.inventory_id); }
	String get_profile_identifier() const { return String(snapshot.profile_identifier.c_str()); }
	int64_t get_revision() const { return int64_t(snapshot.revision); }
	int64_t get_manifest_fingerprint() const { return int64_t(snapshot.manifest_fingerprint); }
	String get_manifest_algorithm() const { return String(snapshot.manifest_algorithm.c_str()); }
	Visibility get_visibility() const { return Visibility(int(snapshot.visibility)); }

	// {id:int64, container_definition_identifier:String, provider_item:int64}
	// per entry, in the snapshot's own canonical (ascending id) order.
	Array get_containers() const;
	// {id:int64, item_definition_identifier:String, quantity:int64,
	// location:Dictionary (see inventory_godot_util.h's snapshot_location_dict),
	// mutable_components:Array[Dictionary{component_identifier:String,
	// payload:PackedByteArray}], provided_containers:PackedInt64Array}.
	Array get_items() const;
	// {id:int64, item_id:int64}
	Array get_references() const;

	// Canonical fixed-width little-endian encoding (core/inv_snapshot.h),
	// available only for OWNER snapshots. Non-owner projections are recipient-
	// local diagnostic values and must use the dedicated observer protocol;
	// returning canonical bytes for them would expose raw IDs/allocators.
	// Empty on non-owner scope or encode failure.
	PackedByteArray canonical_bytes() const;
	// `inv::InventorySnapshot::hash` -- fnv1a64 over the same canonical
	// encoding, recomputed by the core when this snapshot was produced (a
	// divergence detector, never a security boundary; contracts.md).
	int64_t hash() const { return int64_t(snapshot.hash); }

	// C++-only (NOT ClassDB-bound -- `inv::InventorySnapshot` is not
	// Variant-marshalable): `InventoryAuthority`/`InventoryReplicaNode` in
	// the same module populate a freshly constructed instance through this
	// seam before ever handing it to script.
	void set_native_snapshot(const inv::InventorySnapshot &p_snapshot) { snapshot = p_snapshot; }
	const inv::InventorySnapshot &native_snapshot() const { return snapshot; }

protected:
	static void _bind_methods();

private:
	inv::InventorySnapshot snapshot;
};

} // namespace godot

VARIANT_ENUM_CAST(InventorySnapshotResource::Visibility);

#endif // INVENTORY_SYSTEM_GODOT_SNAPSHOT_RESOURCE_H
