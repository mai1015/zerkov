#ifndef INVENTORY_SYSTEM_GODOT_DISCOVERY_RESOURCES_H
#define INVENTORY_SYSTEM_GODOT_DISCOVERY_RESOURCES_H

#include "protocol/inv_discovery_protocol.h"

#include "godot/inventory_snapshot_resource.h"

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

// Immutable script-facing DTOs for recipient-bound discovery state. Their
// native value setters are intentionally not ClassDB-bound; script receives
// owned copies and cannot mutate authority or replica storage through them.

class InventoryDiscoveryEntryResource : public Resource {
	GDCLASS(InventoryDiscoveryEntryResource, Resource)

public:
	enum Stage {
		STAGE_UNKNOWN = 1,
		STAGE_SCANNING = 2,
	};

	int64_t get_token() const { return int64_t(entry.token); }
	Stage get_stage() const { return Stage(int(entry.stage)); }
	int get_elapsed_ms() const { return int(entry.elapsed_ms); }
	int get_duration_ms() const { return int(entry.duration_ms); }

	void set_native_entry(const inv::protocol::DiscoveryEntryView &p_entry) { entry = p_entry; }
	const inv::protocol::DiscoveryEntryView &native_entry() const { return entry; }

protected:
	static void _bind_methods();

private:
	inv::protocol::DiscoveryEntryView entry;
};

class InventoryDiscoveryContainerViewResource : public Resource {
	GDCLASS(InventoryDiscoveryContainerViewResource, Resource)

public:
	enum Stage {
		STAGE_UNSEARCHED = 1,
		STAGE_SEARCHING = 2,
		STAGE_INDEXED = 3,
	};
	enum LayoutKind {
		LAYOUT_SPATIAL_GRID = 1,
		LAYOUT_NAMED_SLOTS = 2,
		LAYOUT_ORDERED_LIST = 3,
	};

	int64_t get_token() const { return int64_t(view.token); }
	int64_t get_container_id() const { return int64_t(view.container_id); }
	int64_t get_provider_item_id() const { return int64_t(view.provider_item_id); }
	Stage get_stage() const { return Stage(int(view.stage)); }
	String get_shell_label() const { return String(view.shell_label.c_str()); }
	int get_elapsed_ms() const { return int(view.elapsed_ms); }
	int get_duration_ms() const { return int(view.duration_ms); }
	bool is_layout_revealed() const { return view.layout_revealed; }
	LayoutKind get_layout_kind() const { return LayoutKind(int(view.layout_kind)); }
	int get_width() const { return int(view.width); }
	int get_height() const { return int(view.height); }
	int get_capacity() const { return int(view.capacity); }
	int get_item_count() const { return int(view.item_count); }
	TypedArray<InventoryDiscoveryEntryResource> get_entries() const;

	void set_native_view(const inv::protocol::DiscoveryContainerView &p_view) { view = p_view; }
	const inv::protocol::DiscoveryContainerView &native_view() const { return view; }

protected:
	static void _bind_methods();

private:
	inv::protocol::DiscoveryContainerView view;
};

class InventoryDiscoveryTaskResource : public Resource {
	GDCLASS(InventoryDiscoveryTaskResource, Resource)

public:
	enum Kind {
		TASK_NONE = 0,
		TASK_CONTAINER_SEARCH = 1,
		TASK_ITEM_SCAN = 2,
	};

	bool is_actor_busy() const { return task.actor_busy; }
	Kind get_kind() const { return Kind(int(task.kind)); }
	int64_t get_target_token() const { return int64_t(task.target_token); }
	int get_elapsed_ms() const { return int(task.elapsed_ms); }
	int get_duration_ms() const { return int(task.duration_ms); }

	void set_native_task(const inv::protocol::DiscoveryTaskView &p_task) { task = p_task; }
	const inv::protocol::DiscoveryTaskView &native_task() const { return task; }

protected:
	static void _bind_methods();

private:
	inv::protocol::DiscoveryTaskView task;
};

class InventoryDiscoveryResultResource : public Resource {
	GDCLASS(InventoryDiscoveryResultResource, Resource)

public:
	int64_t get_request_id() const { return int64_t(result.request_id); }
	Dictionary get_status() const;
	bool is_accepted() const { return result.accepted; }
	bool is_replayed() const { return result.replayed; }
	bool is_completed() const { return result.completed; }
	int64_t get_inventory_revision() const { return int64_t(result.inventory_revision); }
	int64_t get_discovery_revision() const { return int64_t(result.discovery_revision); }
	InventoryDiscoveryTaskResource::Kind get_task_kind() const {
		return InventoryDiscoveryTaskResource::Kind(int(result.task_kind));
	}
	int get_elapsed_ms() const { return int(result.elapsed_ms); }
	int get_duration_ms() const { return int(result.duration_ms); }
	PackedByteArray canonical_bytes() const;

	void set_native_result(const inv::protocol::DiscoveryResultEnvelope &p_result) { result = p_result; }
	const inv::protocol::DiscoveryResultEnvelope &native_result() const { return result; }

protected:
	static void _bind_methods();

private:
	inv::protocol::DiscoveryResultEnvelope result;
};

class InventoryDiscoverySnapshotResource : public Resource {
	GDCLASS(InventoryDiscoverySnapshotResource, Resource)

public:
	int64_t get_inventory_id() const { return int64_t(envelope.inventory.value); }
	int64_t get_inventory_revision() const { return int64_t(envelope.view.inventory_revision); }
	int64_t get_discovery_revision() const { return int64_t(envelope.view.discovery_revision); }
	Ref<InventorySnapshotResource> get_projected_snapshot() const;
	TypedArray<InventoryDiscoveryContainerViewResource> get_containers() const;
	Ref<InventoryDiscoveryTaskResource> get_task() const;
	PackedByteArray canonical_bytes() const;

	void set_native_envelope(const inv::protocol::DiscoveryViewEnvelope &p_envelope) { envelope = p_envelope; }
	const inv::protocol::DiscoveryViewEnvelope &native_envelope() const { return envelope; }

protected:
	static void _bind_methods();

private:
	inv::protocol::DiscoveryViewEnvelope envelope;
};

class InventoryDiscoveryDeltaResource : public Resource {
	GDCLASS(InventoryDiscoveryDeltaResource, Resource)

public:
	int64_t get_inventory_id() const { return int64_t(envelope.inventory.value); }
	int64_t get_predecessor_inventory_revision() const { return int64_t(envelope.delta.predecessor_inventory_revision); }
	int64_t get_successor_inventory_revision() const { return int64_t(envelope.delta.successor_inventory_revision); }
	int64_t get_predecessor_discovery_revision() const { return int64_t(envelope.delta.predecessor_discovery_revision); }
	int64_t get_successor_discovery_revision() const { return int64_t(envelope.delta.successor_discovery_revision); }
	Ref<InventoryDiscoverySnapshotResource> get_replacement_snapshot() const;
	PackedByteArray canonical_bytes() const;

	void set_native_envelope(const inv::protocol::DiscoveryDeltaEnvelope &p_envelope) { envelope = p_envelope; }
	const inv::protocol::DiscoveryDeltaEnvelope &native_envelope() const { return envelope; }

protected:
	static void _bind_methods();

private:
	inv::protocol::DiscoveryDeltaEnvelope envelope;
};

} // namespace godot

VARIANT_ENUM_CAST(InventoryDiscoveryEntryResource::Stage);
VARIANT_ENUM_CAST(InventoryDiscoveryContainerViewResource::Stage);
VARIANT_ENUM_CAST(InventoryDiscoveryContainerViewResource::LayoutKind);
VARIANT_ENUM_CAST(InventoryDiscoveryTaskResource::Kind);

#endif // INVENTORY_SYSTEM_GODOT_DISCOVERY_RESOURCES_H
