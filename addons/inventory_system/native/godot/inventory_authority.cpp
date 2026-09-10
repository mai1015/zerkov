#include "godot/inventory_authority.h"

#include "core/inv_commands.h"
#include "core/inv_deltas.h"
#include "core/inv_hash.h"
#include "core/inv_identifier.h"
#include "core/inv_limits.h"
#include "core/inv_snapshot.h"

#include "protocol/inv_persistence.h"
#include "protocol/inv_discovery_protocol.h"
#include "protocol/inv_discovery_view.h"
#include "protocol/inv_protocol_codec.h"
#include "protocol/inv_protocol_compat.h"
#include "protocol/inv_protocol_types.h"
#include "protocol/inv_visibility.h"

#include "godot/inventory_godot_util.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <limits>
#include <utility>

namespace godot {

namespace {

// Parses one settlement plan entry Dictionary into `inv::SettlementEntry`.
// Returns false (leaving r_out untouched) on a malformed "disposition"
// string or a missing required field.
bool parse_settlement_entry(const Dictionary &p_entry, inv::SettlementEntry &r_out) {
	inv::SettlementEntry entry;
	entry.item = to_item_id(int64_t(p_entry.get("item", int64_t(0))));
	const String disposition = String(p_entry.get("disposition", String("retain")));
	if (disposition == "retain") {
		entry.disposition = inv::SettlementRetain{};
	} else if (disposition == "transfer_to") {
		inv::SettlementTransfer transfer;
		transfer.destination = to_inventory_id(int64_t(p_entry.get("destination", int64_t(0))));
		inv::ItemLocation location;
		if (!location_from_dict(p_entry.get("location", Dictionary()), location)) {
			return false;
		}
		transfer.location = location;
		entry.disposition = transfer;
	} else if (disposition == "release_to") {
		inv::SettlementRelease release;
		release.external_owner = to_external_owner_id(int64_t(p_entry.get("external_owner", int64_t(0))));
		entry.disposition = release;
	} else {
		return false;
	}
	r_out = entry;
	return true;
}

} // namespace

InventoryAuthority::InventoryAuthority() {}

InventoryAuthority::~InventoryAuthority() {}

void InventoryAuthority::set_catalog(const Ref<InventoryCatalog> &p_catalog) {
	if (pipeline != nullptr) {
		return; // immutable once the pipeline is built -- see header comment.
	}
	catalog_resource = p_catalog;
}

Dictionary InventoryAuthority::get_last_status() const {
	return status_dict(last_status);
}

bool InventoryAuthority::ensure_pipeline() {
	if (pipeline != nullptr) {
		return true;
	}
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		return false;
	}
	quantity_reservations = std::make_unique<inv::PreparedQuantityReservations>(
			catalog_resource->native_catalog());
	pipeline = std::make_unique<inv::InventoryTransactionPipeline>(
			catalog_resource->native_catalog(),
			permissions,
			nullptr,
			inv::MAX_IDEMPOTENCY_RECORDS,
			quantity_reservations.get());

	// Checked lifetime identity (7.5): the observer lambda captures only this
	// node's ObjectID, never `this` directly, and re-resolves it through
	// ObjectDB before touching `this` on every invocation -- matching
	// gameplay_abilities' GameplayAbilityWorldCoordinator::register_component()/
	// prune_freed_components() precedent (native/godot/
	// gameplay_ability_world_coordinator.cpp). The pipeline itself is a
	// member of this Node and is destroyed alongside it, but the guard is
	// unconditional defense-in-depth against any reentrant notification that
	// could otherwise race a mid-teardown Node.
	const ObjectID self_id(get_instance_id());
	pipeline->add_observer(1, [self_id](const inv::TransactionResult &p_result) {
		InventoryAuthority *self = Object::cast_to<InventoryAuthority>(ObjectDB::get_instance(self_id));
		if (self == nullptr) {
			return;
		}
		self->on_transaction_result(p_result);
	});
	quantity_reservations->add_observer(1, [self_id](const inv::PreparedQuantityCommit &p_commit) {
		InventoryAuthority *self = Object::cast_to<InventoryAuthority>(ObjectDB::get_instance(self_id));
		if (self == nullptr) {
			return;
		}
		self->on_quantity_reservation_published(p_commit);
	});
	return true;
}

inv::InventoryRuntime *InventoryAuthority::runtime_for(int64_t p_inventory_id) {
	auto it = runtimes.find(p_inventory_id);
	return it == runtimes.end() ? nullptr : &it->second;
}

const inv::InventoryRuntime *InventoryAuthority::runtime_for(int64_t p_inventory_id) const {
	auto it = runtimes.find(p_inventory_id);
	return it == runtimes.end() ? nullptr : &it->second;
}

std::vector<inv::InventoryId> InventoryAuthority::unique_sorted(std::vector<inv::InventoryId> p_ids) {
	std::sort(p_ids.begin(), p_ids.end());
	p_ids.erase(std::unique(p_ids.begin(), p_ids.end()), p_ids.end());
	return p_ids;
}

inv::CommandHeader InventoryAuthority::make_header(const std::vector<inv::InventoryId> &p_touched, int64_t p_actor, int64_t p_command_id) {
	inv::CommandHeader header;
	if (p_command_id > 0) {
		header.command_id = to_command_id(p_command_id);
		observe_explicit_command_id(header.command_id);
	} else {
		header.command_id = allocate_canonical_command_id();
	}
	header.actor = std::uint64_t(p_actor < 0 ? 0 : p_actor);
	for (const inv::InventoryId &id : p_touched) {
		const inv::InventoryRuntime *runtime = runtime_for(int64_t(id.value));
		inv::ExpectedRevision expected;
		expected.inventory = id;
		expected.revision = runtime == nullptr ? 0 : runtime->revision();
		header.expected_revisions.push_back(expected);
	}
	return header;
}

inv::CommandId InventoryAuthority::allocate_canonical_command_id() {
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (next_command_id == 0 || next_command_id > script_max) {
		return inv::CommandId{};
	}
	const inv::CommandId allocated{ next_command_id };
	next_command_id = next_command_id == script_max ? 0 : next_command_id + 1;
	return allocated;
}

void InventoryAuthority::observe_explicit_command_id(inv::CommandId p_command_id) {
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (!p_command_id || p_command_id.value > script_max || next_command_id == 0 ||
			p_command_id.value < next_command_id) {
		return;
	}
	next_command_id = p_command_id.value == script_max ? 0 : p_command_id.value + 1;
}

inv::CommandHeader InventoryAuthority::make_preview_header(
		const std::vector<inv::InventoryId> &p_touched,
		int64_t p_actor) const {
	inv::CommandHeader header;
	// Preview never enters idempotency or commit, so it deliberately does not
	// consume next_command_id. A valid nonzero marker keeps game permission
	// providers that validate header shape on the same path as submission.
	header.command_id = inv::CommandId{ 1 };
	header.actor = std::uint64_t(p_actor < 0 ? 0 : p_actor);
	for (const inv::InventoryId &id : p_touched) {
		const inv::InventoryRuntime *runtime = runtime_for(int64_t(id.value));
		header.expected_revisions.push_back(
				inv::ExpectedRevision{
					id,
					runtime == nullptr ? 0 : runtime->revision(),
				});
	}
	return header;
}

Dictionary InventoryAuthority::submit_single(int64_t p_inventory_id, const inv::Command &p_command, int64_t p_actor, int64_t p_command_id) {
	if (!ensure_pipeline()) {
		UtilityFunctions::push_error("InventoryAuthority: catalog is missing or not sealed; cannot submit commands.");
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		UtilityFunctions::push_error(vformat("InventoryAuthority: unknown inventory_id %d.", p_inventory_id));
		return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	const inv::CommandHeader header = make_header({ to_inventory_id(p_inventory_id) }, p_actor, p_command_id);
	if (!header.command_id) {
		return error_result_dict(inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED));
	}
	const inv::TransactionResult result = pipeline->submit(*runtime, header, p_command);
	return result_dict(result);
}

Dictionary InventoryAuthority::submit_multi(const std::vector<inv::InventoryId> &p_touched, const inv::Command &p_command, int64_t p_actor, int64_t p_command_id) {
	if (!ensure_pipeline()) {
		UtilityFunctions::push_error("InventoryAuthority: catalog is missing or not sealed; cannot submit commands.");
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	std::vector<inv::InventoryRuntime *> targets;
	targets.reserve(p_touched.size());
	for (const inv::InventoryId &id : p_touched) {
		inv::InventoryRuntime *runtime = runtime_for(int64_t(id.value));
		if (runtime == nullptr) {
			UtilityFunctions::push_error(vformat("InventoryAuthority: unknown inventory_id %d.", int64_t(id.value)));
			return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
		}
		targets.push_back(runtime);
	}
	const inv::CommandHeader header = make_header(p_touched, p_actor, p_command_id);
	if (!header.command_id) {
		return error_result_dict(inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED));
	}
	const inv::TransactionResult result = pipeline->submit(targets, header, p_command);
	return result_dict(result);
}

Dictionary InventoryAuthority::result_dict(const inv::TransactionResult &p_result) const {
	Dictionary d;
	d["accepted"] = p_result.accepted;
	d["replayed"] = p_result.replayed;
	d["queued"] = p_result.queued;
	d["status"] = status_dict(p_result.status);
	d["command_id"] = int64_t(p_result.command_id.value);

	Array revisions;
	for (const inv::RevisionOutcome &rev : p_result.revisions) {
		Dictionary rd;
		rd["inventory"] = int64_t(rev.inventory.value);
		rd["predecessor"] = int64_t(rev.predecessor_revision);
		rd["successor"] = int64_t(rev.successor_revision);
		revisions.append(rd);
	}
	d["revisions"] = revisions;

	Array events;
	for (const inv::TransactionEvent &event : p_result.events) {
		Dictionary ed;
		ed["kind"] = int(event.kind);
		ed["item"] = int64_t(event.item.value);
		ed["secondary_item"] = int64_t(event.secondary_item.value);
		ed["source_container"] = int64_t(event.source_container.value);
		ed["destination_container"] = int64_t(event.destination_container.value);
		ed["reference"] = int64_t(event.reference.value);
		events.append(ed);
	}
	d["events"] = events;

	d["new_item_id"] = int64_t(p_result.new_item_id.value);
	d["new_reference_id"] = int64_t(p_result.new_reference_id.value);
	d["dropped_external_owner"] = int64_t(p_result.dropped_external_owner.value);

	Array dropped;
	for (const inv::DroppedItemValue &item : p_result.dropped_items) {
		Dictionary dd;
		dd["item_definition_identifier"] = String(item.item_definition_identifier.c_str());
		dd["quantity"] = int64_t(item.quantity);
		Array components;
		for (const inv::MutableComponent &component : item.mutable_components) {
			Dictionary cd;
			cd["component_identifier"] = String(component.component_identifier.c_str());
			cd["payload"] = to_packed(component.payload);
			components.append(cd);
		}
		dd["mutable_components"] = components;
		dd["external_owner"] = int64_t(item.external_owner.value);
		dropped.append(dd);
	}
	d["dropped_items"] = dropped;

	d["transferred_quantity"] = int64_t(p_result.transferred_quantity);
	d["remaining_quantity"] = int64_t(p_result.remaining_quantity);
	d["conflicting_inventory"] = int64_t(p_result.conflicting_inventory.value);
	d["authoritative_revision"] = int64_t(p_result.authoritative_revision);
	return d;
}

Dictionary InventoryAuthority::targeted_provider_preview_dict(
		const inv::TargetedProviderTransferPreview &p_preview) const {
	Dictionary d;
	d["valid"] = p_preview.valid;
	d["status"] = status_dict(p_preview.status);
	d["destination_container"] =
			int64_t(p_preview.destination_container.value);
	d["transferred_quantity"] =
			int64_t(p_preview.transferred_quantity);
	d["conflicting_inventory"] =
			int64_t(p_preview.conflicting_inventory.value);
	d["authoritative_revision"] =
			int64_t(p_preview.authoritative_revision);
	return d;
}

Dictionary InventoryAuthority::quantity_result_dict(const inv::QuantityReservationResult &p_result) const {
	Dictionary d;
	d["accepted"] = p_result.accepted;
	d["replayed"] = p_result.replayed;
	d["status"] = status_dict(p_result.status);
	d["reservation_id"] = String(p_result.reservation_id.c_str());
	d["inventory_id"] = int64_t(p_result.inventory.value);
	d["revision"] = int64_t(p_result.revision);
	d["quantity"] = int64_t(p_result.quantity);
	Array lines;
	for (const inv::QuantityReservationLine &line : p_result.lines) {
		Dictionary line_dict;
		line_dict["item"] = int64_t(line.item.value);
		line_dict["quantity"] = int64_t(line.quantity);
		line_dict["generation"] = int64_t(line.generation);
		lines.append(line_dict);
	}
	d["lines"] = lines;
	// Explicit health diagnostics (Ephemeral Reservation Lifecycle):
	// 0=unknown, 1=held, 2=committed, 3=released, 4=published -- mirrors
	// inv::QuantityReservationStage.
	d["stage"] = int(p_result.stage);
	return d;
}

Dictionary InventoryAuthority::error_result_dict(const inv::Status &p_status) {
	last_status = p_status;
	inv::TransactionResult result;
	result.accepted = false;
	result.status = p_status;
	return result_dict(result);
}

Dictionary InventoryAuthority::query_error(const inv::Status &p_status) const {
	Dictionary d;
	d["ok"] = false;
	d["status"] = status_dict(p_status);
	return d;
}

Dictionary InventoryAuthority::lifecycle_result_dict(
		int64_t p_inventory_id,
		const inv::Status &p_status,
		bool p_ok) {
	last_status = p_status;
	Dictionary d;
	d["ok"] = p_ok;
	d["status"] = status_dict(p_status);
	d["inventory_id"] = p_inventory_id;
	return d;
}

void InventoryAuthority::clear_inventory_scoped_state(inv::InventoryId p_inventory) {
	if (!p_inventory) {
		return;
	}
	if (quantity_reservations != nullptr) {
		quantity_reservations->clear_inventory(p_inventory);
	}
	discovery_store.clear_inventory(p_inventory);
	if (pipeline != nullptr) {
		pipeline->invalidate_idempotency_for_inventory(p_inventory);
	}
	if (last_delta_batch_inventories.erase(p_inventory) != 0) {
		last_delta_batch_bytes_value = PackedByteArray();
		last_delta_batch_inventories.clear();
	}
	for (auto it = observer_views.begin(); it != observer_views.end();) {
		if (it->first.inventory == p_inventory) {
			it = observer_views.erase(it);
		} else {
			++it;
		}
	}
}

bool InventoryAuthority::discovery_recipient_from_args(
		int64_t p_session_id,
		int64_t p_actor_id,
		inv::DiscoveryRecipientKey &r_recipient) {
	if (p_session_id <= 0 || p_actor_id <= 0) {
		return false;
	}
	r_recipient.session_id = std::uint64_t(p_session_id);
	r_recipient.actor_id = std::uint64_t(p_actor_id);
	return true;
}

inv::DiscoveryIntentHeader InventoryAuthority::make_discovery_header(
		inv::DiscoveryRecipientKey p_recipient,
		const inv::InventoryRuntime &p_runtime,
		int64_t p_request_id,
		int64_t p_expected_inventory_revision,
		int64_t p_expected_discovery_revision) {
	inv::DiscoveryIntentHeader header;
	header.recipient = p_recipient;
	if (p_request_id > 0) {
		header.request_id = std::uint64_t(p_request_id);
		if (header.request_id >= next_discovery_request_id) {
			next_discovery_request_id = header.request_id + 1;
		}
	} else {
		header.request_id = next_discovery_request_id++;
	}
	header.inventory = p_runtime.id();
	header.expected_inventory_revision = p_expected_inventory_revision >= 0 ?
			std::uint64_t(p_expected_inventory_revision) :
			p_runtime.revision();
	if (p_expected_discovery_revision >= 0) {
		header.expected_discovery_revision = std::uint64_t(p_expected_discovery_revision);
	} else {
		std::uint64_t current_revision = 0;
		if (discovery_store.discovery_revision(p_recipient, p_runtime.id(), current_revision).ok()) {
			header.expected_discovery_revision = current_revision;
		}
	}
	return header;
}

Ref<InventoryDiscoveryResultResource> InventoryAuthority::discovery_result_resource(
		std::uint64_t p_request_id,
		const inv::DiscoveryIntentResult &p_result) {
	last_status = p_result.status;
	Ref<InventoryDiscoveryResultResource> resource;
	resource.instantiate();
	resource->set_native_result(inv::protocol::make_discovery_result_envelope(p_request_id, p_result));
	return resource;
}

Ref<InventoryDiscoveryResultResource> InventoryAuthority::discovery_error_resource(
		std::uint64_t p_request_id,
		const inv::Status &p_status,
		const inv::InventoryRuntime *p_runtime,
		std::uint64_t p_discovery_revision) {
	inv::DiscoveryIntentResult result;
	result.status = p_status;
	result.inventory_revision = p_runtime == nullptr ? 0 : p_runtime->revision();
	result.discovery_revision = p_discovery_revision;
	return discovery_result_resource(p_request_id, result);
}

inv::Status InventoryAuthority::build_discovery_view_envelope(
		inv::DiscoveryRecipientKey p_recipient,
		const inv::InventoryRuntime &p_runtime,
		inv::protocol::DiscoveryViewEnvelope &r_envelope) {
	inv::protocol::DiscoveryViewEnvelope envelope;
	envelope.inventory = p_runtime.id();
	const inv::Status status = inv::protocol::build_discovery_view(
			p_runtime, discovery_store, p_recipient, envelope.view);
	if (!status.ok()) {
		return status;
	}
	r_envelope = std::move(envelope);
	return inv::ok_status();
}

inv::Status InventoryAuthority::build_discovery_delta_envelope(
		inv::DiscoveryRecipientKey p_recipient,
		const inv::InventoryRuntime &p_runtime,
		std::uint64_t p_predecessor_inventory_revision,
		std::uint64_t p_predecessor_discovery_revision,
		inv::protocol::DiscoveryDeltaEnvelope &r_envelope) {
	inv::protocol::DiscoveryViewEnvelope current;
	const inv::Status view_status = build_discovery_view_envelope(p_recipient, p_runtime, current);
	if (!view_status.ok()) {
		return view_status;
	}
	if (p_predecessor_inventory_revision > current.view.inventory_revision ||
			p_predecessor_discovery_revision > current.view.discovery_revision) {
		return inv::make_status(inv::StatusCode::REVISION_MISMATCH, inv::DiagnosticId::DISCOVERY_REVISION_STALE);
	}
	inv::protocol::DiscoveryDeltaEnvelope envelope;
	envelope.inventory = p_runtime.id();
	envelope.delta.predecessor_inventory_revision = p_predecessor_inventory_revision;
	envelope.delta.successor_inventory_revision = current.view.inventory_revision;
	envelope.delta.predecessor_discovery_revision = p_predecessor_discovery_revision;
	envelope.delta.successor_discovery_revision = current.view.discovery_revision;
	envelope.delta.view = std::move(current.view);
	r_envelope = std::move(envelope);
	return inv::ok_status();
}

void InventoryAuthority::reconcile_discovery_after_transaction(const inv::TransactionResult &p_result) {
	if (!p_result.accepted || p_result.revisions.empty() || discovery_recipients.empty()) {
		return;
	}

	std::map<inv::InventoryId, std::map<inv::DiscoveryRecipientKey, std::uint64_t>> predecessors_by_inventory;
	for (const inv::RevisionOutcome &revision : p_result.revisions) {
		for (const inv::DiscoveryRecipientKey &recipient : discovery_recipients) {
			std::uint64_t predecessor = 0;
			if (discovery_store.discovery_revision(recipient, revision.inventory, predecessor).ok()) {
				predecessors_by_inventory[revision.inventory].emplace(recipient, predecessor);
			}
		}
	}

	// Preserve session knowledge for stable ids that crossed an inventory
	// boundary. The event deliberately omits inventory ids, so resolve the
	// destination from the accepted touched runtimes and try every other
	// touched runtime as a possible source; transfer_revealed_item() changes
	// only recipients that actually learned the source key.
	for (const inv::TransactionEvent &event : p_result.events) {
		if (event.kind != inv::TransactionEventKind::LOOTED || !event.item) {
			continue;
		}
		inv::InventoryRuntime *destination = nullptr;
		for (const inv::RevisionOutcome &revision : p_result.revisions) {
			inv::InventoryRuntime *candidate = runtime_for(int64_t(revision.inventory.value));
			if (candidate != nullptr && candidate->find_item(event.item) != nullptr) {
				destination = candidate;
				break;
			}
		}
		if (destination == nullptr) {
			continue;
		}
		for (const inv::RevisionOutcome &revision : p_result.revisions) {
			inv::InventoryRuntime *source = runtime_for(int64_t(revision.inventory.value));
			if (source == nullptr || source == destination) {
				continue;
			}
			const inv::Status transfer_status = discovery_store.transfer_revealed_item(
					*source, *destination, event.item);
			if (!transfer_status.ok() &&
					transfer_status.diagnostic != inv::DiagnosticId::DISCOVERY_TARGET_STALE) {
				UtilityFunctions::push_error("InventoryAuthority: failed to reconcile transferred discovery knowledge.");
			}
		}
	}

	for (const inv::RevisionOutcome &revision : p_result.revisions) {
		inv::InventoryRuntime *runtime = runtime_for(int64_t(revision.inventory.value));
		if (runtime == nullptr) {
			continue;
		}
		const inv::Status reconcile_status = discovery_store.reconcile(*runtime);
		if (!reconcile_status.ok()) {
			UtilityFunctions::push_error("InventoryAuthority: failed to reconcile discovery state after an accepted transaction.");
			continue;
		}
		const auto predecessors_found = predecessors_by_inventory.find(runtime->id());
		if (predecessors_found == predecessors_by_inventory.end()) {
			continue;
		}
		for (const auto &entry : predecessors_found->second) {
			inv::protocol::DiscoveryDeltaEnvelope delta;
			const inv::Status delta_status = build_discovery_delta_envelope(
					entry.first,
					*runtime,
					revision.predecessor_revision,
					entry.second,
					delta);
			if (!delta_status.ok()) {
				continue;
			}
			inv::ByteWriter writer(inv::MAX_DISCOVERY_DELTA_BYTES);
			const inv::Status encode_status = inv::protocol::encode_discovery_delta(delta, writer);
			if (!encode_status.ok()) {
				continue;
			}
			{
				SignalEmissionScope signal_scope(*this);
				emit_signal(
						"discovery_delta_ready",
						int64_t(entry.first.session_id),
						int64_t(entry.first.actor_id),
						int64_t(runtime->id().value),
						to_packed(writer.bytes()));
			}
		}
	}
}

void InventoryAuthority::on_transaction_result(const inv::TransactionResult &p_result) {
	const Dictionary d = result_dict(p_result);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("transaction_committed", d);
	}

	if (!p_result.accepted || p_result.deltas.empty()) {
		return;
	}
	reconcile_discovery_after_transaction(p_result);
	inv::protocol::DeltaBatch batch;
	batch.source_command_id = p_result.command_id;
	batch.inventories = p_result.deltas;
	inv::ByteWriter writer(inv::MAX_DELTA_BYTES);
	const inv::Status status = inv::protocol::encode_delta_batch(batch, writer);
	if (!status.ok()) {
		UtilityFunctions::push_error("InventoryAuthority: failed to encode the accepted delta batch.");
		return;
	}
	last_delta_batch_bytes_value = to_packed(writer.bytes());
	last_delta_batch_inventories.clear();
	for (const inv::InventoryDelta &delta : p_result.deltas) {
		last_delta_batch_inventories.insert(delta.inventory);
	}
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("delta_ready", last_delta_batch_bytes_value);
	}
}

void InventoryAuthority::on_quantity_reservation_published(const inv::PreparedQuantityCommit &p_commit) {
	inv::TransactionResult result;
	result.accepted = true;
	result.status = inv::ok_status();
	result.command_id = inv::CommandId{ inv::hash_string(p_commit.reservation_id) };
	result.revisions.push_back(inv::RevisionOutcome{
			p_commit.inventory,
			p_commit.predecessor_revision,
			p_commit.successor_revision });
	inv::InventoryDelta delta;
	delta.inventory = p_commit.inventory;
	delta.predecessor_revision = p_commit.predecessor_revision;
	delta.successor_revision = p_commit.successor_revision;
	for (const inv::QuantityConsumptionLine &line : p_commit.lines) {
		if (line.destroyed) {
			delta.ops.push_back(inv::ItemDestroyedOp{ line.item.value });
		} else {
			delta.ops.push_back(inv::ItemQuantityOp{ line.item.value, line.quantity_after });
		}
	}
	result.deltas.push_back(std::move(delta));
	on_transaction_result(result);

	Dictionary published;
	published["reservation_id"] = String(p_commit.reservation_id.c_str());
	published["inventory_id"] = int64_t(p_commit.inventory.value);
	published["predecessor_revision"] = int64_t(p_commit.predecessor_revision);
	published["successor_revision"] = int64_t(p_commit.successor_revision);
	published["quantity"] = int64_t(p_commit.quantity);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("quantity_reservation_published", published);
	}
}

// ---------------------------------------------------------------------------
// Inventory construction
// ---------------------------------------------------------------------------

int64_t InventoryAuthority::create_inventory(const String &p_profile_identifier) {
	if (!ensure_pipeline()) {
		UtilityFunctions::push_error("InventoryAuthority.create_inventory: catalog is missing or not sealed.");
		last_status = inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED);
		return 0;
	}
	const std::uint64_t max_script_id = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (inventory_id_allocator.next_raw() >= max_script_id) {
		last_status = inv::make_status(
				inv::StatusCode::LIMIT_EXCEEDED,
				inv::DiagnosticId::OVERFLOW_DETECTED,
				inventory_id_allocator.next_raw());
		UtilityFunctions::push_error("InventoryAuthority.create_inventory: inventory id space is exhausted.");
		return 0;
	}

	// Stage the counter so a failed create cannot consume an inventory id.
	inv::HandleAllocator<inv::InventoryId> candidate_allocator = inventory_id_allocator;
	const inv::InventoryId id = candidate_allocator.allocate();
	if (!id) {
		last_status = inv::make_status(
				inv::StatusCode::LIMIT_EXCEEDED,
				inv::DiagnosticId::OVERFLOW_DETECTED,
				inventory_id_allocator.next_raw());
		UtilityFunctions::push_error("InventoryAuthority.create_inventory: inventory id allocation overflowed.");
		return 0;
	}
	const int64_t script_id = static_cast<int64_t>(id.value);
	if (runtimes.find(script_id) != runtimes.end()) {
		last_status = inv::make_status(
				inv::StatusCode::ALREADY_EXISTS,
				inv::DiagnosticId::OWNERSHIP_DUPLICATE,
				id.value);
		UtilityFunctions::push_error(vformat(
				"InventoryAuthority.create_inventory: inventory id %d is already live.",
				script_id));
		return 0;
	}

	inv::InventoryRuntime runtime;
	const inv::Status status = inv::InventoryRuntime::create(
			catalog_resource->native_catalog(), to_std(p_profile_identifier), id, runtime, &identity_authority);
	last_status = status;
	if (!status.ok()) {
		UtilityFunctions::push_error(vformat("InventoryAuthority.create_inventory: failed for profile '%s' (code %d, diagnostic %d).",
				p_profile_identifier, int(status.code), int(status.diagnostic)));
		return 0;
	}
	const auto inserted = runtimes.emplace(script_id, std::move(runtime));
	if (!inserted.second) {
		last_status = inv::make_status(
				inv::StatusCode::ALREADY_EXISTS,
				inv::DiagnosticId::OWNERSHIP_DUPLICATE,
				id.value);
		UtilityFunctions::push_error(vformat(
				"InventoryAuthority.create_inventory: inventory id %d collided during insertion.",
				script_id));
		return 0;
	}
	inventory_id_allocator = candidate_allocator;
	return script_id;
}

bool InventoryAuthority::has_inventory(int64_t p_inventory_id) const {
	return runtime_for(p_inventory_id) != nullptr;
}

int64_t InventoryAuthority::inventory_revision(int64_t p_inventory_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	return runtime == nullptr ? -1 : int64_t(runtime->revision());
}

Dictionary InventoryAuthority::unload_inventory(int64_t p_inventory_id) {
	if (p_inventory_id <= 0) {
		return lifecycle_result_dict(
				p_inventory_id,
				inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE),
				false);
	}
	if (signal_emission_depth != 0) {
		return lifecycle_result_dict(
				p_inventory_id,
				inv::make_status(
						inv::StatusCode::COMMAND_REJECTED,
						inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY,
						signal_emission_depth),
				false);
	}
	const auto found = runtimes.find(p_inventory_id);
	if (found == runtimes.end()) {
		return lifecycle_result_dict(
				p_inventory_id,
				inv::make_status(inv::StatusCode::NOT_FOUND),
				false);
	}

	clear_inventory_scoped_state(inv::InventoryId{ static_cast<std::uint64_t>(p_inventory_id) });
	runtimes.erase(found);
	const inv::Status status = inv::ok_status();
	Dictionary result = lifecycle_result_dict(p_inventory_id, status, true);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("inventory_unloaded", p_inventory_id);
	}
	return result;
}

// ---------------------------------------------------------------------------
// Typed command submission
// ---------------------------------------------------------------------------

Dictionary InventoryAuthority::move_item(int64_t p_inventory_id, int64_t p_item, const Dictionary &p_destination, int64_t p_actor, int64_t p_command_id) {
	inv::ItemLocation destination;
	if (!location_from_dict(p_destination, destination)) {
		UtilityFunctions::push_error("InventoryAuthority.move_item: malformed destination.");
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	inv::MoveItemCommand command;
	command.item = to_item_id(p_item);
	command.destination = destination;
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::rotate_item(int64_t p_inventory_id, int64_t p_item, bool p_rotated, int64_t p_actor, int64_t p_command_id) {
	inv::RotateItemCommand command;
	command.item = to_item_id(p_item);
	command.rotated = p_rotated;
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::split_stack(int64_t p_inventory_id, int64_t p_source, int64_t p_quantity, const Dictionary &p_destination, int64_t p_actor, int64_t p_command_id) {
	inv::ItemLocation destination;
	if (!location_from_dict(p_destination, destination)) {
		UtilityFunctions::push_error("InventoryAuthority.split_stack: malformed destination.");
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	inv::SplitStackCommand command;
	command.source = to_item_id(p_source);
	command.quantity = std::uint64_t(p_quantity < 0 ? 0 : p_quantity);
	command.destination = destination;
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::merge_stacks(int64_t p_inventory_id, int64_t p_source, int64_t p_destination_item, int64_t p_actor, int64_t p_command_id) {
	inv::MergeStacksCommand command;
	command.source = to_item_id(p_source);
	command.destination = to_item_id(p_destination_item);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::insert_item(int64_t p_inventory_id, const String &p_item_definition_identifier, int64_t p_quantity, const Dictionary &p_destination, int64_t p_actor, int64_t p_command_id) {
	inv::ItemLocation destination;
	if (!location_from_dict(p_destination, destination)) {
		UtilityFunctions::push_error("InventoryAuthority.insert_item: malformed destination.");
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	inv::InsertItemCommand command;
	command.item_definition_identifier = to_std(p_item_definition_identifier);
	command.quantity = std::uint64_t(p_quantity < 0 ? 0 : p_quantity);
	command.destination = destination;
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::remove_item(int64_t p_inventory_id, int64_t p_item, int64_t p_actor, int64_t p_command_id) {
	inv::RemoveItemCommand command;
	command.item = to_item_id(p_item);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::equip_item(int64_t p_inventory_id, int64_t p_item, int64_t p_destination_container, const String &p_slot_identifier, int64_t p_actor, int64_t p_command_id) {
	inv::EquipItemCommand command;
	command.item = to_item_id(p_item);
	command.destination_container = to_container_id(p_destination_container);
	command.slot_identifier = to_std(p_slot_identifier);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::unequip_item(int64_t p_inventory_id, int64_t p_item, const Dictionary &p_destination, int64_t p_actor, int64_t p_command_id) {
	inv::ItemLocation destination;
	if (!location_from_dict(p_destination, destination)) {
		UtilityFunctions::push_error("InventoryAuthority.unequip_item: malformed destination.");
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	inv::UnequipItemCommand command;
	command.item = to_item_id(p_item);
	command.destination = destination;
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::swap_items(int64_t p_inventory_id, int64_t p_item_a, int64_t p_item_b, int64_t p_actor, int64_t p_command_id) {
	inv::SwapItemsCommand command;
	command.item_a = to_item_id(p_item_a);
	command.item_b = to_item_id(p_item_b);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::auto_place_item(int64_t p_inventory_id, int64_t p_item, int64_t p_destination_container, int64_t p_actor, int64_t p_command_id) {
	inv::AutoPlaceItemCommand command;
	command.item = to_item_id(p_item);
	command.destination = to_inventory_id(p_inventory_id);
	command.destination_container = to_container_id(p_destination_container);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::quick_transfer_item(int64_t p_source_inventory_id, int64_t p_destination_inventory_id, int64_t p_item, bool p_allow_partial, int64_t p_actor, int64_t p_command_id) {
	inv::QuickTransferItemCommand command;
	command.item = to_item_id(p_item);
	command.source = to_inventory_id(p_source_inventory_id);
	command.destination = to_inventory_id(p_destination_inventory_id);
	command.allow_partial = p_allow_partial;
	const std::vector<inv::InventoryId> touched = unique_sorted({ command.source, command.destination });
	return submit_multi(touched, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::transfer_item_to_provider(
		int64_t p_source_inventory_id,
		int64_t p_destination_inventory_id,
		int64_t p_item,
		int64_t p_destination_provider,
		int64_t p_actor,
		int64_t p_command_id) {
	inv::TargetedProviderTransferCommand command;
	command.source = to_inventory_id(p_source_inventory_id);
	command.destination = to_inventory_id(p_destination_inventory_id);
	command.item = to_item_id(p_item);
	command.destination_provider = to_item_id(p_destination_provider);
	const std::vector<inv::InventoryId> touched =
			unique_sorted({ command.source, command.destination });
	return submit_multi(touched, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::preview_transfer_item_to_provider(
		int64_t p_source_inventory_id,
		int64_t p_destination_inventory_id,
		int64_t p_item,
		int64_t p_destination_provider,
		int64_t p_actor) {
	if (!ensure_pipeline()) {
		return targeted_provider_preview_dict(
				inv::TargetedProviderTransferPreview{
					false,
					inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED),
				});
	}
	inv::TargetedProviderTransferCommand command;
	command.source = to_inventory_id(p_source_inventory_id);
	command.destination = to_inventory_id(p_destination_inventory_id);
	command.item = to_item_id(p_item);
	command.destination_provider = to_item_id(p_destination_provider);
	const std::vector<inv::InventoryId> touched =
			unique_sorted({ command.source, command.destination });
	std::vector<inv::InventoryRuntime *> targets;
	targets.reserve(touched.size());
	for (const inv::InventoryId &id : touched) {
		inv::InventoryRuntime *runtime = runtime_for(int64_t(id.value));
		if (runtime == nullptr) {
			inv::TargetedProviderTransferPreview missing;
			missing.status = inv::make_status(
					inv::StatusCode::NOT_FOUND,
					inv::DiagnosticId::INVENTORY_NOT_IN_TRANSACTION_SET,
					id.value);
			return targeted_provider_preview_dict(missing);
		}
		targets.push_back(runtime);
	}
	const inv::CommandHeader header = make_preview_header(touched, p_actor);
	return targeted_provider_preview_dict(
			pipeline->preview_targeted_provider_transfer(
					targets,
					header,
					command));
}

Dictionary InventoryAuthority::loot_item(int64_t p_source_inventory_id, int64_t p_destination_inventory_id, int64_t p_item, const Dictionary &p_destination_location, int64_t p_actor, int64_t p_command_id) {
	inv::ItemLocation destination_location;
	if (!location_from_dict(p_destination_location, destination_location)) {
		UtilityFunctions::push_error("InventoryAuthority.loot_item: malformed destination_location.");
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	inv::LootItemCommand command;
	command.source = to_inventory_id(p_source_inventory_id);
	command.destination = to_inventory_id(p_destination_inventory_id);
	command.item = to_item_id(p_item);
	command.destination_location = destination_location;
	const std::vector<inv::InventoryId> touched = unique_sorted({ command.source, command.destination });
	return submit_multi(touched, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::drop_item(int64_t p_inventory_id, int64_t p_item, int64_t p_external_owner, int64_t p_actor, int64_t p_command_id) {
	inv::DropItemCommand command;
	command.item = to_item_id(p_item);
	command.external_owner = to_external_owner_id(p_external_owner);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::settle_inventory(int64_t p_inventory_id, const Array &p_plan, int64_t p_actor, int64_t p_command_id) {
	inv::SettleInventoryCommand command;
	command.inventory = to_inventory_id(p_inventory_id);
	std::vector<inv::InventoryId> touched = { command.inventory };
	command.plan.reserve(p_plan.size());
	for (int i = 0; i < p_plan.size(); ++i) {
		inv::SettlementEntry entry;
		if (!parse_settlement_entry(Dictionary(p_plan[i]), entry)) {
			UtilityFunctions::push_error(vformat("InventoryAuthority.settle_inventory: malformed plan entry %d.", i));
			return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
		}
		if (const inv::SettlementTransfer *transfer = std::get_if<inv::SettlementTransfer>(&entry.disposition)) {
			touched.push_back(transfer->destination);
		}
		command.plan.push_back(entry);
	}
	return submit_multi(unique_sorted(touched), command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::assign_reference(int64_t p_inventory_id, int64_t p_item, int64_t p_actor, int64_t p_command_id) {
	inv::AssignReferenceCommand command;
	command.item = to_item_id(p_item);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::clear_reference(int64_t p_inventory_id, int64_t p_reference, int64_t p_actor, int64_t p_command_id) {
	inv::ClearReferenceCommand command;
	command.reference = to_reference_id(p_reference);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::set_item_component(
		int64_t p_inventory_id,
		int64_t p_item,
		const String &p_component_identifier,
		const PackedByteArray &p_payload,
		int64_t p_actor,
		int64_t p_command_id) {
	if (p_inventory_id <= 0 || p_item <= 0) {
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
	}
	if (p_component_identifier.length() > int64_t(inv::MAX_IDENTIFIER_BYTES)) {
		return error_result_dict(inv::make_status(
				inv::StatusCode::INVALID_IDENTIFIER,
				inv::DiagnosticId::IDENTIFIER_TOO_LONG,
				std::uint64_t(p_component_identifier.length())));
	}
	const std::string component_identifier = to_std(p_component_identifier);
	const inv::Status identifier_status = inv::validate_identifier(component_identifier);
	if (!identifier_status.ok()) {
		return error_result_dict(identifier_status);
	}
	if (p_payload.size() > int64_t(inv::MAX_TRAIT_PAYLOAD_BYTES)) {
		return error_result_dict(inv::make_status(
				inv::StatusCode::LIMIT_EXCEEDED,
				inv::DiagnosticId::TRAIT_PAYLOAD_TOO_LARGE,
				std::uint64_t(p_payload.size())));
	}
	inv::SetItemComponentCommand command;
	command.item = to_item_id(p_item);
	command.component_identifier = component_identifier;
	command.payload = from_packed(p_payload);
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::remove_item_component(
		int64_t p_inventory_id,
		int64_t p_item,
		const String &p_component_identifier,
		int64_t p_actor,
		int64_t p_command_id) {
	if (p_inventory_id <= 0 || p_item <= 0) {
		return error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
	}
	if (p_component_identifier.length() > int64_t(inv::MAX_IDENTIFIER_BYTES)) {
		return error_result_dict(inv::make_status(
				inv::StatusCode::INVALID_IDENTIFIER,
				inv::DiagnosticId::IDENTIFIER_TOO_LONG,
				std::uint64_t(p_component_identifier.length())));
	}
	const std::string component_identifier = to_std(p_component_identifier);
	const inv::Status identifier_status = inv::validate_identifier(component_identifier);
	if (!identifier_status.ok()) {
		return error_result_dict(identifier_status);
	}
	inv::RemoveItemComponentCommand command;
	command.item = to_item_id(p_item);
	command.component_identifier = component_identifier;
	return submit_single(p_inventory_id, command, p_actor, p_command_id);
}

Dictionary InventoryAuthority::prepare_quantity_reservation(
		int64_t p_inventory_id,
		const String &p_reservation_id,
		const String &p_required_trait,
		const Array &p_container_priorities,
		int64_t p_quantity,
		int64_t p_expected_revision,
		int64_t p_deadline_tick) {
	if (!ensure_pipeline()) {
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	inv::QuantityReservationRequest request;
	request.reservation_id = to_std(p_reservation_id);
	request.inventory = to_inventory_id(p_inventory_id);
	request.expected_revision = p_expected_revision < 0 ?
			runtime->revision() :
			std::uint64_t(p_expected_revision);
	request.required_trait = to_std(p_required_trait);
	request.quantity = p_quantity < 0 ? 0 : std::uint64_t(p_quantity);
	for (int i = 0; i < p_container_priorities.size(); ++i) {
		request.container_definition_priority.push_back(to_std(String(p_container_priorities[i])));
	}
	request.deadline_tick = p_deadline_tick < 0 ? 0 : std::uint64_t(p_deadline_tick);
	return quantity_result_dict(quantity_reservations->prepare(*runtime, request));
}

Dictionary InventoryAuthority::release_quantity_reservation(
		int64_t p_inventory_id,
		const String &p_reservation_id) {
	if (!ensure_pipeline()) {
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	return quantity_result_dict(quantity_reservations->release(*runtime, to_std(p_reservation_id)));
}

Dictionary InventoryAuthority::commit_quantity_reservation_silent(
		int64_t p_inventory_id,
		const String &p_reservation_id) {
	if (!ensure_pipeline()) {
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	return quantity_result_dict(quantity_reservations->commit_silent(*runtime, to_std(p_reservation_id)));
}

Dictionary InventoryAuthority::rollback_quantity_reservation(
		int64_t p_inventory_id,
		const String &p_reservation_id) {
	if (!ensure_pipeline()) {
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	return quantity_result_dict(quantity_reservations->rollback(*runtime, to_std(p_reservation_id)));
}

Dictionary InventoryAuthority::publish_quantity_reservation(const String &p_reservation_id) {
	if (!ensure_pipeline()) {
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	return quantity_result_dict(quantity_reservations->publish(to_std(p_reservation_id)));
}

Dictionary InventoryAuthority::expire_quantity_reservation(
		int64_t p_inventory_id,
		const String &p_reservation_id,
		int64_t p_current_tick) {
	if (!ensure_pipeline()) {
		return error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	return quantity_result_dict(quantity_reservations->expire(
			*runtime, to_std(p_reservation_id), std::uint64_t(p_current_tick < 0 ? 0 : p_current_tick)));
}

Dictionary InventoryAuthority::health_quantity_reservation(const String &p_reservation_id) const {
	if (quantity_reservations == nullptr) {
		inv::QuantityReservationResult not_found;
		not_found.reservation_id = to_std(p_reservation_id);
		not_found.status = inv::make_status(inv::StatusCode::NOT_FOUND);
		return quantity_result_dict(not_found);
	}
	return quantity_result_dict(quantity_reservations->health(to_std(p_reservation_id)));
}

int64_t InventoryAuthority::active_quantity_reservation_count() const {
	return quantity_reservations == nullptr ? 0 : int64_t(quantity_reservations->active_count());
}

// ---------------------------------------------------------------------------
// Remote intent submission (7.6 carried-over fix a)
// ---------------------------------------------------------------------------

Dictionary InventoryAuthority::submit_command_bytes(const PackedByteArray &p_bytes) {
	if (p_bytes.is_empty() || p_bytes.size() > int64_t(inv::MAX_COMMAND_BYTES)) {
		const inv::Status status = p_bytes.is_empty()
				? inv::make_status(inv::StatusCode::DECODE_FAILED, inv::DiagnosticId::TRUNCATED_PAYLOAD)
				: inv::make_status(inv::StatusCode::PAYLOAD_TOO_LARGE, inv::DiagnosticId::BYTE_LIMIT_EXCEEDED, std::uint64_t(p_bytes.size()));
		Dictionary d = error_result_dict(status);
		d["result_bytes"] = PackedByteArray();
		return d;
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::CommandEnvelope envelope;
	const inv::Status decode_status = inv::protocol::decode_command_envelope(reader, envelope);
	if (!decode_status.ok()) {
		UtilityFunctions::push_error("InventoryAuthority.submit_command_bytes: failed to decode CommandEnvelope.");
		Dictionary d = error_result_dict(decode_status);
		d["result_bytes"] = PackedByteArray();
		return d;
	}
	return submit_decoded_command_envelope(envelope);
}

Dictionary InventoryAuthority::submit_decoded_command_envelope(const inv::protocol::CommandEnvelope &p_envelope) {
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (!p_envelope.header.command_id || p_envelope.header.command_id.value > script_max ||
			p_envelope.header.actor > script_max) {
		Dictionary d = error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
		d["result_bytes"] = PackedByteArray();
		return d;
	}
	if (!ensure_pipeline()) {
		UtilityFunctions::push_error("InventoryAuthority.submit_command_bytes: catalog is missing or not sealed.");
		Dictionary d = error_result_dict(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
		d["result_bytes"] = PackedByteArray();
		return d;
	}
	if (p_envelope.header.expected_revisions.empty()) {
		UtilityFunctions::push_error("InventoryAuthority.submit_command_bytes: CommandEnvelope named no target inventory.");
		Dictionary d = error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
		d["result_bytes"] = PackedByteArray();
		return d;
	}
	std::vector<inv::InventoryRuntime *> targets;
	targets.reserve(p_envelope.header.expected_revisions.size());
	for (const inv::ExpectedRevision &expected : p_envelope.header.expected_revisions) {
		if (!expected.inventory || expected.inventory.value > script_max || expected.revision > script_max) {
			Dictionary d = error_result_dict(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
			d["result_bytes"] = PackedByteArray();
			return d;
		}
		inv::InventoryRuntime *runtime = runtime_for(int64_t(expected.inventory.value));
		if (runtime == nullptr) {
			UtilityFunctions::push_error(vformat("InventoryAuthority.submit_command_bytes: unknown inventory_id %d.", int64_t(expected.inventory.value)));
			Dictionary d = error_result_dict(inv::make_status(inv::StatusCode::NOT_FOUND));
			d["result_bytes"] = PackedByteArray();
			return d;
		}
		targets.push_back(runtime);
	}
	observe_explicit_command_id(p_envelope.header.command_id);

	// header used VERBATIM -- unlike submit_single()/submit_multi(), which
	// build a fresh CommandHeader from make_header() (always the current
	// revision), this is the one entry point that lets the caller's own
	// (possibly stale) expected_revisions reach the pipeline unmodified.
	const inv::TransactionResult result = targets.size() == 1
			? pipeline->submit(*targets.front(), p_envelope.header, p_envelope.command)
			: pipeline->submit(targets, p_envelope.header, p_envelope.command);

	Dictionary d = result_dict(result);
	inv::protocol::ResultEnvelope reply;
	reply.result = result;
	inv::ByteWriter writer(inv::MAX_DELTA_BYTES + 64);
	const inv::Status encode_status = inv::protocol::encode_result_envelope(reply, writer);
	d["result_bytes"] = encode_status.ok() ? to_packed(writer.bytes()) : PackedByteArray();
	return d;
}

inv::TransactionResult InventoryAuthority::execute_gateway_command(const inv::protocol::CommandEnvelope &p_envelope) {
	auto rejected = [&](const inv::Status &p_status) {
		inv::TransactionResult result;
		result.accepted = false;
		result.status = p_status;
		result.command_id = p_envelope.header.command_id;
		last_status = p_status;
		return result;
	};
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (!p_envelope.header.command_id || p_envelope.header.command_id.value > script_max ||
			p_envelope.header.actor > script_max || p_envelope.header.expected_revisions.empty()) {
		return rejected(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
	}
	if (signal_emission_depth != 0) {
		return rejected(inv::make_status(
				inv::StatusCode::COMMAND_REJECTED,
				inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY,
				signal_emission_depth));
	}
	if (!ensure_pipeline()) {
		return rejected(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	std::vector<inv::InventoryRuntime *> targets;
	targets.reserve(p_envelope.header.expected_revisions.size());
	for (const inv::ExpectedRevision &expected : p_envelope.header.expected_revisions) {
		if (!expected.inventory || expected.inventory.value > script_max || expected.revision > script_max) {
			return rejected(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
		}
		inv::InventoryRuntime *runtime = runtime_for(static_cast<int64_t>(expected.inventory.value));
		if (runtime == nullptr) {
			return rejected(inv::make_status(inv::StatusCode::NOT_FOUND));
		}
		targets.push_back(runtime);
	}
	observe_explicit_command_id(p_envelope.header.command_id);
	inv::TransactionResult result = targets.size() == 1
			? pipeline->submit_immediate(*targets.front(), p_envelope.header, p_envelope.command)
			: pipeline->submit_immediate(targets, p_envelope.header, p_envelope.command);
	last_status = result.status;
	return result;
}

PackedByteArray InventoryAuthority::encode_move_command_bytes_for_test(int64_t p_inventory_id, int64_t p_item, const Dictionary &p_destination, int64_t p_expected_revision, int64_t p_actor, int64_t p_command_id) {
	inv::ItemLocation destination;
	if (!location_from_dict(p_destination, destination)) {
		UtilityFunctions::push_error("InventoryAuthority.encode_move_command_bytes_for_test: malformed destination.");
		return PackedByteArray();
	}
	inv::protocol::CommandEnvelope envelope;
	if (p_command_id > 0) {
		envelope.header.command_id = to_command_id(p_command_id);
		observe_explicit_command_id(envelope.header.command_id);
	} else {
		envelope.header.command_id = allocate_canonical_command_id();
	}
	if (!envelope.header.command_id) {
		last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED);
		return PackedByteArray();
	}
	envelope.header.actor = std::uint64_t(p_actor < 0 ? 0 : p_actor);
	inv::ExpectedRevision expected;
	expected.inventory = to_inventory_id(p_inventory_id);
	expected.revision = std::uint64_t(p_expected_revision < 0 ? 0 : p_expected_revision);
	envelope.header.expected_revisions.push_back(expected);
	inv::MoveItemCommand command;
	command.item = to_item_id(p_item);
	command.destination = destination;
	envelope.command = command;

	inv::ByteWriter writer(inv::MAX_COMMAND_BYTES);
	const inv::Status status = inv::protocol::encode_command_envelope(envelope, writer);
	if (!status.ok()) {
		UtilityFunctions::push_error("InventoryAuthority.encode_move_command_bytes_for_test: failed to encode.");
		return PackedByteArray();
	}
	return to_packed(writer.bytes());
}

PackedByteArray InventoryAuthority::encode_quick_transfer_command_bytes_for_test(
		int64_t p_source_inventory_id,
		int64_t p_destination_inventory_id,
		int64_t p_item,
		bool p_allow_partial,
		int64_t p_source_expected_revision,
		int64_t p_destination_expected_revision,
		int64_t p_actor,
		int64_t p_command_id) {
	// Keep this test-only bridge bounded at the script boundary.  The normal
	// remote path owns its own codec; this helper exists only because the
	// headless Godot suite has no other way to build a genuine multi-inventory
	// CommandEnvelope for InventoryNetworkGateway.submit_command_bytes().
	if (p_source_inventory_id <= 0 || p_destination_inventory_id <= 0 ||
			p_source_inventory_id == p_destination_inventory_id || p_item <= 0 ||
			p_source_expected_revision < 0 || p_destination_expected_revision < 0) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return PackedByteArray();
	}
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (static_cast<std::uint64_t>(p_source_inventory_id) > script_max ||
			static_cast<std::uint64_t>(p_destination_inventory_id) > script_max ||
			static_cast<std::uint64_t>(p_item) > script_max ||
			static_cast<std::uint64_t>(p_source_expected_revision) > script_max ||
			static_cast<std::uint64_t>(p_destination_expected_revision) > script_max ||
			p_actor < 0 || static_cast<std::uint64_t>(p_actor) > script_max) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return PackedByteArray();
	}

	inv::protocol::CommandEnvelope envelope;
	if (p_command_id > 0) {
		envelope.header.command_id = to_command_id(p_command_id);
		observe_explicit_command_id(envelope.header.command_id);
	} else {
		envelope.header.command_id = allocate_canonical_command_id();
	}
	if (!envelope.header.command_id) {
		last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED);
		return PackedByteArray();
	}
	envelope.header.actor = static_cast<std::uint64_t>(p_actor);
	const inv::ExpectedRevision source_revision{
			to_inventory_id(p_source_inventory_id), static_cast<std::uint64_t>(p_source_expected_revision)};
	const inv::ExpectedRevision destination_revision{
			to_inventory_id(p_destination_inventory_id), static_cast<std::uint64_t>(p_destination_expected_revision)};
	if (source_revision.inventory.value < destination_revision.inventory.value) {
		envelope.header.expected_revisions.push_back(source_revision);
		envelope.header.expected_revisions.push_back(destination_revision);
	} else {
		envelope.header.expected_revisions.push_back(destination_revision);
		envelope.header.expected_revisions.push_back(source_revision);
	}
	inv::QuickTransferItemCommand command;
	command.item = to_item_id(p_item);
	command.source = to_inventory_id(p_source_inventory_id);
	command.destination = to_inventory_id(p_destination_inventory_id);
	command.allow_partial = p_allow_partial;
	envelope.command = command;

	inv::ByteWriter writer(inv::MAX_COMMAND_BYTES);
	const inv::Status status = inv::protocol::encode_command_envelope(envelope, writer);
	if (!status.ok()) {
		last_status = status;
		UtilityFunctions::push_error("InventoryAuthority.encode_quick_transfer_command_bytes_for_test: failed to encode.");
		return PackedByteArray();
	}
	last_status = inv::ok_status();
	return to_packed(writer.bytes());
}

// ---------------------------------------------------------------------------
// Snapshot / delta / protocol access
// ---------------------------------------------------------------------------

inv::Status InventoryAuthority::build_visible_snapshot(const inv::InventoryRuntime &p_runtime, inv::VisibilityScope p_scope, inv::InventorySnapshot &r_out) const {
	// The runtime's own full-detail content, always at OWNER scope regardless
	// of p_scope -- project_snapshot() below is what actually applies a
	// non-OWNER scope's projection; inv::snapshot() itself only ever tags
	// `visibility` (core/inv_snapshot.h's snapshot() doc comment).
	inv::InventorySnapshot full;
	const inv::Status snapshot_status = inv::snapshot(p_runtime, inv::VisibilityScope::OWNER, full);
	if (!snapshot_status.ok()) {
		return snapshot_status;
	}
	if (p_scope == inv::VisibilityScope::OWNER) {
		r_out = std::move(full);
		return inv::ok_status();
	}
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		return inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED);
	}

	inv::protocol::ProjectionPolicy policy;
	if (p_scope == inv::VisibilityScope::OBSERVER) {
		// OBSERVER: game-declared per-container INSPECT policy (inventory-
		// protocol spec's stated default rule) -- a container the profile
		// marked inspectable stays PUBLIC even for a non-owner recipient.
		const inv::Status policy_status = inv::protocol::derive_default_policy(catalog_resource->native_catalog(), full, policy);
		if (!policy_status.ok()) {
			return policy_status;
		}
	}
	// else p_scope == REDACTED: leave `policy` at its default construction
	// (default_visibility == REDACTED, empty overrides) -- see this method's
	// header-comment rationale for why REDACTED deliberately ignores the
	// INSPECT access bit rather than reusing derive_default_policy().

	return inv::protocol::project_snapshot(full, p_scope, policy, r_out);
}

inv::Status InventoryAuthority::build_observer_snapshot(
		const inv::InventoryRuntime &p_runtime,
		inv::DiscoveryRecipientKey p_recipient,
		inv::VisibilityScope p_scope,
		std::uint64_t p_generation,
		std::uint64_t p_sequence,
		ObserverViewState &r_stream,
		inv::protocol::ObserverSnapshot &r_out) const {
	if (p_scope == inv::VisibilityScope::OWNER ||
			p_recipient.session_id == 0 || p_recipient.actor_id == 0 ||
			p_generation == 0 || p_sequence == 0) {
		return inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	inv::InventorySnapshot full;
	inv::Status status = inv::snapshot(p_runtime, inv::VisibilityScope::OWNER, full);
	if (!status.ok()) {
		return status;
	}
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		return inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED, inv::DiagnosticId::CATALOG_REQUIRES_SEAL);
	}
	inv::protocol::ProjectionPolicy policy;
	if (p_scope == inv::VisibilityScope::OBSERVER) {
		status = inv::protocol::derive_default_policy(catalog_resource->native_catalog(), full, policy);
		if (!status.ok()) {
			return status;
		}
	}
	policy.opaque_container_ids = r_stream.opaque_container_ids;
	policy.opaque_container_counter = r_stream.next_opaque_container_id;
	policy.opaque_item_ids = r_stream.opaque_item_ids;
	policy.opaque_item_counter = r_stream.next_opaque_item_id;
	const inv::Status projection_status = inv::protocol::project_observer_snapshot(
			full, p_scope, policy, p_recipient, p_generation, p_sequence, r_out);
	if (projection_status.ok()) {
		r_stream.opaque_container_ids = policy.opaque_container_ids;
		r_stream.next_opaque_container_id = policy.opaque_container_counter;
		r_stream.opaque_item_ids = policy.opaque_item_ids;
		r_stream.next_opaque_item_id = policy.opaque_item_counter;
	}
	return projection_status;
}

PackedByteArray InventoryAuthority::observer_snapshot_envelope_bytes(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_visibility) const {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || p_inventory_id <= 0) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return PackedByteArray();
	}
	if (discovery_recipients.count(recipient) == 0) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
		return PackedByteArray();
	}
	if (p_visibility != static_cast<int>(inv::VisibilityScope::OBSERVER) &&
			p_visibility != static_cast<int>(inv::VisibilityScope::REDACTED)) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::INVALID_ENUM);
		return PackedByteArray();
	}
	const inv::VisibilityScope scope = static_cast<inv::VisibilityScope>(p_visibility);
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND);
		return PackedByteArray();
	}
	const ObserverViewKey key{ recipient, runtime->id() };
	auto found = observer_views.find(key);
	auto generation_epoch = observer_generation_epochs.find(recipient);
	if (generation_epoch == observer_generation_epochs.end()) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
		return PackedByteArray();
	}
	if (found == observer_views.end()) {
		std::size_t recipient_stream_count = 0;
		for (const auto &entry : observer_views) {
			if (entry.first.recipient == recipient) {
				++recipient_stream_count;
			}
		}
		if (recipient_stream_count >= inv::MAX_OBSERVER_STREAMS_PER_RECIPIENT) {
			last_status = inv::make_status(
					inv::StatusCode::LIMIT_EXCEEDED,
					inv::DiagnosticId::COUNT_LIMIT_EXCEEDED,
					recipient_stream_count);
			return PackedByteArray();
		}
		if (observer_views.size() >= inv::MAX_OBSERVER_STREAMS) {
			last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::COUNT_LIMIT_EXCEEDED, observer_views.size());
			return PackedByteArray();
		}
	}
	std::uint64_t generation = 0;
	std::uint64_t sequence = 1;
	bool allocate_generation = false;
	if (found == observer_views.end() || found->second.view.visibility != scope) {
		if (generation_epoch->second == 0 ||
				generation_epoch->second > static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max())) {
			last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED);
			return PackedByteArray();
		}
		// Reserve the candidate locally.  A failed projection/encode must not
		// consume an authority stream epoch and create a misleading generation
		// gap for the next successful bootstrap.
		generation = generation_epoch->second;
		allocate_generation = true;
	} else {
		generation = found->second.view.generation;
		sequence = found->second.view.sequence;
	}
	ObserverViewState candidate_state;
	if (found != observer_views.end() && found->second.view.visibility == scope) {
		candidate_state = found->second;
	}
	inv::protocol::ObserverSnapshot candidate;
	last_status = build_observer_snapshot(*runtime, recipient, scope, generation, 1, candidate_state, candidate);
	if (!last_status.ok()) {
		return PackedByteArray();
	}
	bool same_content = false;
	if (found != observer_views.end() && found->second.view.visibility == scope) {
		last_status = inv::protocol::observer_snapshot_content_equal(found->second.view, candidate, same_content);
		if (!last_status.ok()) {
			return PackedByteArray();
		}
	}
	const bool changed = found == observer_views.end() || found->second.view.visibility != scope || !same_content;
	if (changed) {
		if (found != observer_views.end() && found->second.view.visibility == scope) {
			if (found->second.view.sequence == UINT64_MAX ||
					found->second.view.sequence >= static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max())) {
				last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED);
				return PackedByteArray();
			}
			sequence = found->second.view.sequence + 1;
		} else {
			sequence = 1;
		}
	}
	candidate.sequence = sequence;
	inv::protocol::ObserverSnapshotEnvelope envelope;
	envelope.recipient = recipient;
	envelope.snapshot = candidate;
	inv::ByteWriter writer(inv::MAX_OBSERVER_SNAPSHOT_BYTES);
	last_status = inv::protocol::encode_observer_snapshot(envelope, writer);
	if (!last_status.ok()) {
		return PackedByteArray();
	}
	candidate_state.view = candidate;
	observer_views[key] = std::move(candidate_state);
	if (allocate_generation) {
		const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
		// Zero is an exhausted sentinel; never wrap or reuse a recipient epoch.
		generation_epoch->second = generation == script_max ? 0 : generation + 1;
	}
	return to_packed(writer.bytes());
}

PackedByteArray InventoryAuthority::observer_delta_bytes(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_predecessor_sequence) const {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || p_inventory_id <= 0 || p_predecessor_sequence <= 0) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return PackedByteArray();
	}
	if (discovery_recipients.count(recipient) == 0) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
		return PackedByteArray();
	}
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND);
		return PackedByteArray();
	}
	const ObserverViewKey key{ recipient, runtime->id() };
	auto found = observer_views.find(key);
	if (found == observer_views.end()) {
		last_status = inv::make_status(inv::StatusCode::SNAPSHOT_REQUIRED, inv::DiagnosticId::REPLICA_REVISION_GAP);
		return PackedByteArray();
	}
	if (static_cast<std::uint64_t>(p_predecessor_sequence) != found->second.view.sequence) {
		last_status = inv::make_status(inv::StatusCode::SNAPSHOT_REQUIRED, inv::DiagnosticId::REPLICA_REVISION_GAP, found->second.view.sequence);
		return PackedByteArray();
	}
	ObserverViewState candidate_state = found->second;
	inv::protocol::ObserverSnapshot candidate;
	last_status = build_observer_snapshot(
			*runtime, recipient, found->second.view.visibility, found->second.view.generation, 1, candidate_state, candidate);
	if (!last_status.ok()) {
		return PackedByteArray();
	}
	bool same_content = false;
	last_status = inv::protocol::observer_snapshot_content_equal(found->second.view, candidate, same_content);
	if (!last_status.ok()) {
		return PackedByteArray();
	}
	if (same_content) {
		last_status = inv::ok_status();
		return PackedByteArray(); // no visible change; do not expose a hidden mutation.
	}
	if (found->second.view.sequence == UINT64_MAX ||
			found->second.view.sequence >= static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max())) {
		last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED);
		return PackedByteArray();
	}
	candidate.sequence = found->second.view.sequence + 1;
	inv::protocol::ObserverDeltaEnvelope envelope;
	envelope.recipient = recipient;
	envelope.predecessor_sequence = found->second.view.sequence;
	envelope.successor_sequence = candidate.sequence;
	envelope.snapshot = candidate;
	inv::ByteWriter writer(inv::MAX_OBSERVER_DELTA_BYTES);
	last_status = inv::protocol::encode_observer_delta(envelope, writer);
	if (!last_status.ok()) {
		return PackedByteArray();
	}
	candidate_state.view = candidate;
	found->second = std::move(candidate_state);
	return to_packed(writer.bytes());
}

Ref<InventorySnapshotResource> InventoryAuthority::snapshot(int64_t p_inventory_id, int64_t p_visibility) const {
	if (p_visibility != InventorySnapshotResource::VISIBILITY_OWNER &&
			p_visibility != InventorySnapshotResource::VISIBILITY_OBSERVER &&
			p_visibility != InventorySnapshotResource::VISIBILITY_REDACTED) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::INVALID_ENUM);
		UtilityFunctions::push_error("InventoryAuthority.snapshot: visibility must be OWNER, OBSERVER, or REDACTED.");
		return Ref<InventorySnapshotResource>();
	}
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		UtilityFunctions::push_error(vformat("InventoryAuthority.snapshot: unknown inventory_id %d.", p_inventory_id));
		return Ref<InventorySnapshotResource>();
	}
	inv::InventorySnapshot snap;
	const inv::Status status = build_visible_snapshot(*runtime, inv::VisibilityScope(p_visibility), snap);
	if (!status.ok()) {
		UtilityFunctions::push_error("InventoryAuthority.snapshot: failed to build the snapshot.");
		return Ref<InventorySnapshotResource>();
	}
	Ref<InventorySnapshotResource> resource;
	resource.instantiate();
	resource->set_native_snapshot(snap);
	return resource;
}

PackedByteArray InventoryAuthority::snapshot_envelope_bytes(int64_t p_inventory_id, int64_t p_visibility) const {
	if (p_visibility != InventorySnapshotResource::VISIBILITY_OWNER) {
		// The canonical envelope is an owner-only transport.  A projected
		// SnapshotEnvelope still has canonical IDs, allocator counters, and
		// component/reference structure, so accepting it here would make a
		// seemingly convenient observer path a data-leak boundary.  Callers
		// needing a recipient-safe stream must use observer_snapshot_envelope_bytes()
		// and InventoryObserverReplicaNode instead.
		last_status = inv::make_status(inv::StatusCode::ROLE_VIOLATION);
		UtilityFunctions::push_error("InventoryAuthority.snapshot_envelope_bytes: canonical envelopes are owner-only; use observer_snapshot_envelope_bytes for non-owner streams.");
		return PackedByteArray();
	}
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND);
		UtilityFunctions::push_error(vformat("InventoryAuthority.snapshot_envelope_bytes: unknown inventory_id %d.", p_inventory_id));
		return PackedByteArray();
	}
	// Same projection as snapshot() (7.6 carried-over fix b) -- the wire
	// envelope must not leak more than the Resource-based accessor above
	// does for the identical (inventory_id, visibility) pair.
	inv::protocol::SnapshotEnvelope envelope;
	const inv::Status snapshot_status = build_visible_snapshot(*runtime, inv::VisibilityScope(p_visibility), envelope.snapshot);
	if (!snapshot_status.ok()) {
		last_status = snapshot_status;
		UtilityFunctions::push_error("InventoryAuthority.snapshot_envelope_bytes: failed to build the snapshot.");
		return PackedByteArray();
	}
	inv::ByteWriter writer(inv::MAX_SNAPSHOT_BYTES + 64);
	const inv::Status encode_status = inv::protocol::encode_snapshot_envelope(envelope, writer);
	if (!encode_status.ok()) {
		last_status = encode_status;
		UtilityFunctions::push_error("InventoryAuthority.snapshot_envelope_bytes: failed to encode.");
		return PackedByteArray();
	}
	last_status = inv::ok_status();
	return to_packed(writer.bytes());
}

PackedByteArray InventoryAuthority::session_hello_bytes() const {
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		last_status = inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED);
		UtilityFunctions::push_error("InventoryAuthority.session_hello_bytes: catalog is missing or not sealed.");
		return PackedByteArray();
	}
	const inv::protocol::SessionHello hello = inv::protocol::make_session_hello(catalog_resource->native_catalog());
	inv::ByteWriter writer;
	const inv::Status status = inv::protocol::encode_session_hello(hello, writer);
	if (!status.ok()) {
		last_status = status;
		UtilityFunctions::push_error("InventoryAuthority.session_hello_bytes: failed to encode.");
		return PackedByteArray();
	}
	last_status = inv::ok_status();
	return to_packed(writer.bytes());
}

PackedByteArray InventoryAuthority::make_persistence_record(int64_t p_inventory_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr || catalog_resource.is_null()) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND);
		UtilityFunctions::push_error(vformat("InventoryAuthority.make_persistence_record: unknown inventory_id %d.", p_inventory_id));
		return PackedByteArray();
	}
	inv::protocol::PersistenceRecord record;
	const inv::Status build_status = inv::protocol::make_persistence_record(catalog_resource->native_catalog(), *runtime, record);
	if (!build_status.ok()) {
		last_status = build_status;
		UtilityFunctions::push_error("InventoryAuthority.make_persistence_record: failed to build the record.");
		return PackedByteArray();
	}
	inv::ByteWriter writer(inv::MAX_SNAPSHOT_BYTES + 4096);
	const inv::Status encode_status = inv::protocol::encode_persistence_record(record, writer);
	if (!encode_status.ok()) {
		last_status = encode_status;
		UtilityFunctions::push_error("InventoryAuthority.make_persistence_record: failed to encode the record.");
		return PackedByteArray();
	}
	last_status = inv::ok_status();
	return to_packed(writer.bytes());
}

Dictionary InventoryAuthority::apply_persistence_record(const PackedByteArray &p_bytes, bool p_replace_existing) {
	if (catalog_resource.is_null() || !catalog_resource->is_sealed()) {
		UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: catalog is missing or not sealed.");
		return query_error(inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
	}
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	inv::ByteReader reader(bytes.data(), bytes.size());
	inv::protocol::PersistenceRecord record;
	const inv::Status decode_status = inv::protocol::decode_persistence_record(reader, record);
	if (!decode_status.ok()) {
		UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: failed to decode.");
		return query_error(decode_status);
	}
	const std::uint64_t max_script_id = static_cast<std::uint64_t>(std::numeric_limits<int64_t>::max());
	if (!record.inventory) {
		UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: inventory id zero is invalid.");
		return query_error(inv::make_status(
				inv::StatusCode::INVALID_ARGUMENT,
				inv::DiagnosticId::VALUE_OUT_OF_RANGE));
	}
	if (record.inventory.value > max_script_id) {
		UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: inventory id is outside the script-safe range.");
		return query_error(inv::make_status(
				inv::StatusCode::LIMIT_EXCEEDED,
				inv::DiagnosticId::OVERFLOW_DETECTED,
				max_script_id));
	}

	const int64_t inventory_id = static_cast<int64_t>(record.inventory.value);
	if (signal_emission_depth != 0) {
		return lifecycle_result_dict(
				inventory_id,
				inv::make_status(
						inv::StatusCode::COMMAND_REJECTED,
						inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY,
						signal_emission_depth),
				false);
	}
	const auto existing = runtimes.find(inventory_id);
	if (existing != runtimes.end() && !p_replace_existing) {
		UtilityFunctions::push_error(vformat(
				"InventoryAuthority.apply_persistence_record: inventory id %d is already live; explicit replacement was not requested.",
				inventory_id));
		Dictionary collision = query_error(inv::make_status(
				inv::StatusCode::ALREADY_EXISTS,
				inv::DiagnosticId::OWNERSHIP_DUPLICATE,
				record.inventory.value));
		collision["inventory_id"] = inventory_id;
		return collision;
	}

	// Advancing a copy first makes allocator validation non-mutating. Older
	// records never move the counter backwards; larger restored ids reserve
	// every preceding id before any runtime state is installed.
	inv::HandleAllocator<inv::InventoryId> candidate_allocator = inventory_id_allocator;
	if (record.inventory.value > candidate_allocator.next_raw()) {
		const inv::Status allocator_status = candidate_allocator.restore_from(record.inventory.value);
		if (!allocator_status.ok()) {
			UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: failed to advance the inventory id allocator.");
			return query_error(allocator_status);
		}
	}

	inv::InventoryRuntime runtime;
	const inv::Status load_status = inv::protocol::load_inventory(catalog_resource->native_catalog(), record, &identity_authority, runtime);
	if (!load_status.ok()) {
		UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: failed to load.");
		return query_error(load_status);
	}
	if (existing != runtimes.end()) {
		// Replacement establishes a new runtime generation. Tear down only the
		// state keyed to this inventory; reservations, discovery knowledge,
		// idempotency records, and the last encoded delta for every unrelated
		// inventory remain valid.
		//
		// Extract the live map node before emitting the invalidation edge. The
		// decoded replacement remains staged in this stack frame, while the old
		// runtime remains owned by the extracted node but is unreachable through
		// every public authority path (all inventory operations resolve through
		// runtimes/runtime_for()). This makes listener order irrelevant: no
		// listener can mutate, snapshot, encode, or resync either the doomed old
		// generation or the staged new one while the signal is in flight.
		//
		// Reusing the extracted node also preserves the existing fail-atomic
		// staging contract. Decode/load and allocator validation have already
		// succeeded, and publishing the replacement requires no map allocation or
		// fallible domain operation after listeners return.
		// Publish the already-validated allocator state before callbacks may create
		// unrelated inventories. Assigning the pre-signal copy afterwards would
		// otherwise roll back any allocator progress made by such a callback.
		inventory_id_allocator = candidate_allocator;
		auto replacement_node = runtimes.extract(existing);
		clear_inventory_scoped_state(record.inventory);
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("inventory_generation_changing", inventory_id);
		}
		replacement_node.mapped() = std::move(runtime);
		runtimes.insert(std::move(replacement_node));
		// The runtime now represents a new generation even when the restored
		// record reuses the same revision. Preserve the pipeline itself (and
		// therefore observers plus queued reentrant submissions), but discard
		// every cached accepted result that touched the replaced inventory.
	} else {
		const auto inserted = runtimes.emplace(inventory_id, std::move(runtime));
		if (!inserted.second) {
			UtilityFunctions::push_error("InventoryAuthority.apply_persistence_record: inventory id collided during insertion.");
			Dictionary collision = query_error(inv::make_status(
					inv::StatusCode::ALREADY_EXISTS,
					inv::DiagnosticId::OWNERSHIP_DUPLICATE,
					record.inventory.value));
			collision["inventory_id"] = inventory_id;
			return collision;
		}
		inventory_id_allocator = candidate_allocator;
	}
	Dictionary d;
	d["ok"] = true;
	d["status"] = status_dict(load_status);
	d["inventory_id"] = inventory_id;
	return d;
}

// ---------------------------------------------------------------------------
// Recipient-bound staged discovery
// ---------------------------------------------------------------------------

Dictionary InventoryAuthority::register_discovery_recipient(int64_t p_session_id, int64_t p_actor_id) {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient)) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		Dictionary d = query_error(last_status);
		d["session_id"] = p_session_id;
		d["actor_id"] = p_actor_id;
		return d;
	}
	const bool new_generation_key = observer_generation_epochs.find(recipient) == observer_generation_epochs.end();
	if (new_generation_key && observer_generation_epochs.size() >= inv::MAX_OBSERVER_GENERATION_KEYS) {
		last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::COUNT_LIMIT_EXCEEDED,
				observer_generation_epochs.size());
		Dictionary d = query_error(last_status);
		d["session_id"] = p_session_id;
		d["actor_id"] = p_actor_id;
		return d;
	}
	if (next_discovery_token_seed >
			std::uint64_t(std::numeric_limits<int64_t>::max()) - inv::MAX_DISCOVERY_TOKEN_BINDINGS - 1) {
		last_status = inv::make_status(inv::StatusCode::LIMIT_EXCEEDED, inv::DiagnosticId::OVERFLOW_DETECTED);
		Dictionary d = query_error(last_status);
		d["session_id"] = p_session_id;
		d["actor_id"] = p_actor_id;
		return d;
	}
	const inv::Status status = discovery_store.register_recipient(recipient, next_discovery_token_seed);
	last_status = status;
	if (status.ok()) {
		discovery_recipients.insert(recipient);
		if (new_generation_key) {
			// Registration is the point at which a recipient becomes eligible for
			// a stream.  The epoch is still only advanced after a successful
			// observer packet encode below.
			observer_generation_epochs.emplace(recipient, 1);
		}
		next_discovery_token_seed += inv::MAX_DISCOVERY_TOKEN_BINDINGS + 1;
	}
	Dictionary d;
	d["ok"] = status.ok();
	d["status"] = status_dict(status);
	d["session_id"] = p_session_id;
	d["actor_id"] = p_actor_id;
	return d;
}

Dictionary InventoryAuthority::teardown_discovery_recipient(int64_t p_session_id, int64_t p_actor_id) {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient)) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return query_error(last_status);
	}
	const bool existed = discovery_recipients.erase(recipient) != 0;
	discovery_store.teardown_recipient(recipient);
	for (auto it = observer_views.begin(); it != observer_views.end();) {
		if (it->first.recipient == recipient) {
			it = observer_views.erase(it);
		} else {
			++it;
		}
	}
	last_status = existed ?
			inv::ok_status() :
			inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	Dictionary d;
	d["ok"] = last_status.ok();
	d["status"] = status_dict(last_status);
	d["session_id"] = p_session_id;
	d["actor_id"] = p_actor_id;
	return d;
}

Dictionary InventoryAuthority::teardown_discovery_session(int64_t p_session_id) {
	if (p_session_id <= 0) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return query_error(last_status);
	}
	bool existed = false;
	for (auto it = discovery_recipients.begin(); it != discovery_recipients.end();) {
		if (it->session_id == std::uint64_t(p_session_id)) {
			existed = true;
			it = discovery_recipients.erase(it);
		} else {
			++it;
		}
	}
	discovery_store.teardown_session(std::uint64_t(p_session_id));
	for (auto it = observer_views.begin(); it != observer_views.end();) {
		if (it->first.recipient.session_id == std::uint64_t(p_session_id)) {
			it = observer_views.erase(it);
		} else {
			++it;
		}
	}
	last_status = existed ?
			inv::ok_status() :
			inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
	Dictionary d;
	d["ok"] = last_status.ok();
	d["status"] = status_dict(last_status);
	d["session_id"] = p_session_id;
	return d;
}

Dictionary InventoryAuthority::revoke_discovery_inventory(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id) {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || p_inventory_id <= 0) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return query_error(last_status);
	}
	last_status = discovery_store.revoke_inventory_access(recipient, to_inventory_id(p_inventory_id));
	if (last_status.ok()) {
		observer_views.erase(ObserverViewKey{ recipient, to_inventory_id(p_inventory_id) });
	}
	Dictionary d;
	d["ok"] = last_status.ok();
	d["status"] = status_dict(last_status);
	d["inventory_id"] = p_inventory_id;
	return d;
}

int64_t InventoryAuthority::discovery_revision(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id) const {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || p_inventory_id <= 0) {
		return -1;
	}
	std::uint64_t revision = 0;
	const inv::Status status = discovery_store.discovery_revision(
			recipient, to_inventory_id(p_inventory_id), revision);
	return status.ok() ? int64_t(revision) : -1;
}

Ref<InventoryDiscoveryResultResource> InventoryAuthority::begin_container_search(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_container_token,
		int64_t p_request_id,
		int64_t p_expected_inventory_revision,
		int64_t p_expected_discovery_revision) {
	inv::DiscoveryRecipientKey recipient;
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) ||
			runtime == nullptr || p_container_token <= 0) {
		Ref<InventoryDiscoveryResultResource> error = discovery_error_resource(
				p_request_id > 0 ? std::uint64_t(p_request_id) : 0,
				inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE),
				runtime);
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("discovery_result", p_session_id, p_actor_id, p_inventory_id, error);
		}
		return error;
	}
	const inv::DiscoveryIntentHeader header = make_discovery_header(
			recipient,
			*runtime,
			p_request_id,
			p_expected_inventory_revision,
			p_expected_discovery_revision);
	const inv::DiscoveryIntentResult result = discovery_store.begin_container_search(
			*runtime, header, std::uint64_t(p_container_token));
	Ref<InventoryDiscoveryResultResource> resource = discovery_result_resource(header.request_id, result);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("discovery_result", p_session_id, p_actor_id, p_inventory_id, resource);
	}
	if (result.accepted) {
		discovery_view(p_session_id, p_actor_id, p_inventory_id);
	}
	return resource;
}

Ref<InventoryDiscoveryResultResource> InventoryAuthority::begin_item_scan(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_entry_token,
		int64_t p_request_id,
		int64_t p_expected_inventory_revision,
		int64_t p_expected_discovery_revision) {
	inv::DiscoveryRecipientKey recipient;
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) ||
			runtime == nullptr || p_entry_token <= 0) {
		Ref<InventoryDiscoveryResultResource> error = discovery_error_resource(
				p_request_id > 0 ? std::uint64_t(p_request_id) : 0,
				inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE),
				runtime);
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("discovery_result", p_session_id, p_actor_id, p_inventory_id, error);
		}
		return error;
	}
	const inv::DiscoveryIntentHeader header = make_discovery_header(
			recipient,
			*runtime,
			p_request_id,
			p_expected_inventory_revision,
			p_expected_discovery_revision);
	const inv::DiscoveryIntentResult result = discovery_store.begin_item_scan(
			*runtime, header, std::uint64_t(p_entry_token));
	Ref<InventoryDiscoveryResultResource> resource = discovery_result_resource(header.request_id, result);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("discovery_result", p_session_id, p_actor_id, p_inventory_id, resource);
	}
	if (result.accepted) {
		discovery_view(p_session_id, p_actor_id, p_inventory_id);
	}
	return resource;
}

Ref<InventoryDiscoveryResultResource> InventoryAuthority::cancel_discovery(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_request_id,
		int64_t p_expected_inventory_revision,
		int64_t p_expected_discovery_revision) {
	inv::DiscoveryRecipientKey recipient;
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || runtime == nullptr) {
		Ref<InventoryDiscoveryResultResource> error = discovery_error_resource(
				p_request_id > 0 ? std::uint64_t(p_request_id) : 0,
				inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE),
				runtime);
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("discovery_result", p_session_id, p_actor_id, p_inventory_id, error);
		}
		return error;
	}
	const inv::DiscoveryIntentHeader header = make_discovery_header(
			recipient,
			*runtime,
			p_request_id,
			p_expected_inventory_revision,
			p_expected_discovery_revision);
	const inv::DiscoveryIntentResult result = discovery_store.cancel(*runtime, header);
	Ref<InventoryDiscoveryResultResource> resource = discovery_result_resource(header.request_id, result);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("discovery_result", p_session_id, p_actor_id, p_inventory_id, resource);
	}
	if (result.accepted) {
		discovery_view(p_session_id, p_actor_id, p_inventory_id);
	}
	return resource;
}

Ref<InventoryDiscoveryResultResource> InventoryAuthority::advance_discovery(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_elapsed_ms) {
	inv::DiscoveryRecipientKey recipient;
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient)) {
		Ref<InventoryDiscoveryResultResource> error = discovery_error_resource(
				0, inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE));
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("discovery_result", p_session_id, p_actor_id, int64_t(0), error);
		}
		return error;
	}
	inv::DiscoveryTask task;
	const inv::Status task_status = discovery_store.active_task(recipient, task);
	inv::InventoryRuntime *runtime = task_status.ok() ? runtime_for(int64_t(task.inventory.value)) : nullptr;
	if (!task_status.ok() || runtime == nullptr || p_elapsed_ms <= 0 ||
			std::uint64_t(p_elapsed_ms) > std::numeric_limits<std::uint32_t>::max()) {
		const inv::Status status = !task_status.ok() ?
				task_status :
				inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::DISCOVERY_ELAPSED_INVALID);
		Ref<InventoryDiscoveryResultResource> error = discovery_error_resource(0, status, runtime);
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("discovery_result", p_session_id, p_actor_id,
					runtime == nullptr ? int64_t(0) : int64_t(runtime->id().value), error);
		}
		return error;
	}
	const inv::DiscoveryIntentResult result = discovery_store.advance(
			*runtime, recipient, std::uint32_t(p_elapsed_ms));
	Ref<InventoryDiscoveryResultResource> resource = discovery_result_resource(0, result);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("discovery_result", p_session_id, p_actor_id, int64_t(runtime->id().value), resource);
	}
	if (result.accepted) {
		discovery_view(p_session_id, p_actor_id, int64_t(runtime->id().value));
	}
	return resource;
}

Ref<InventoryDiscoverySnapshotResource> InventoryAuthority::discovery_view(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id) {
	inv::DiscoveryRecipientKey recipient;
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || runtime == nullptr) {
		last_status = inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN);
		return Ref<InventoryDiscoverySnapshotResource>();
	}
	inv::protocol::DiscoveryViewEnvelope envelope;
	last_status = build_discovery_view_envelope(recipient, *runtime, envelope);
	if (!last_status.ok()) {
		return Ref<InventoryDiscoverySnapshotResource>();
	}
	Ref<InventoryDiscoverySnapshotResource> resource;
	resource.instantiate();
	resource->set_native_envelope(envelope);
	{
		SignalEmissionScope signal_scope(*this);
		emit_signal("discovery_view_ready", p_session_id, p_actor_id, p_inventory_id, resource);
	}
	return resource;
}

PackedByteArray InventoryAuthority::discovery_view_bytes(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id) {
	const Ref<InventoryDiscoverySnapshotResource> resource = discovery_view(
			p_session_id, p_actor_id, p_inventory_id);
	return resource.is_valid() ? resource->canonical_bytes() : PackedByteArray();
}

Ref<InventoryDiscoveryDeltaResource> InventoryAuthority::discovery_delta(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_predecessor_inventory_revision,
		int64_t p_predecessor_discovery_revision) {
	inv::DiscoveryRecipientKey recipient;
	inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) ||
			runtime == nullptr ||
			p_predecessor_inventory_revision < 0 ||
			p_predecessor_discovery_revision < 0) {
		last_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return Ref<InventoryDiscoveryDeltaResource>();
	}
	inv::protocol::DiscoveryDeltaEnvelope envelope;
	last_status = build_discovery_delta_envelope(
			recipient,
			*runtime,
			std::uint64_t(p_predecessor_inventory_revision),
			std::uint64_t(p_predecessor_discovery_revision),
			envelope);
	if (!last_status.ok()) {
		return Ref<InventoryDiscoveryDeltaResource>();
	}
	Ref<InventoryDiscoveryDeltaResource> resource;
	resource.instantiate();
	resource->set_native_envelope(envelope);
	return resource;
}

PackedByteArray InventoryAuthority::discovery_delta_bytes(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_predecessor_inventory_revision,
		int64_t p_predecessor_discovery_revision) {
	const Ref<InventoryDiscoveryDeltaResource> resource = discovery_delta(
			p_session_id,
			p_actor_id,
			p_inventory_id,
			p_predecessor_inventory_revision,
			p_predecessor_discovery_revision);
	if (resource.is_null()) {
		return PackedByteArray();
	}
	const PackedByteArray bytes = resource->canonical_bytes();
	if (!bytes.is_empty()) {
		{
			SignalEmissionScope signal_scope(*this);
			emit_signal("discovery_delta_ready", p_session_id, p_actor_id, p_inventory_id, bytes);
		}
	}
	return bytes;
}

PackedByteArray InventoryAuthority::discovery_hello_bytes() const {
	inv::ByteWriter writer;
	const inv::Status status = inv::protocol::encode_discovery_hello(
			inv::protocol::DiscoveryHello{}, writer);
	return status.ok() ? to_packed(writer.bytes()) : PackedByteArray();
}

Dictionary InventoryAuthority::discovery_count_in_container(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_container_id) const {
	inv::DiscoveryRecipientKey recipient;
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN));
	}
	std::uint32_t count = 0;
	const inv::Status status = inv::protocol::discovery_count_in_container(
			*runtime, discovery_store, recipient, to_container_id(p_container_id), count);
	Dictionary d;
	d["ok"] = status.ok();
	d["status"] = status_dict(status);
	d["count"] = int(count);
	return d;
}

Dictionary InventoryAuthority::discovery_layout_kind(
		int64_t p_session_id,
		int64_t p_actor_id,
		int64_t p_inventory_id,
		int64_t p_container_id) const {
	inv::DiscoveryRecipientKey recipient;
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (!discovery_recipient_from_args(p_session_id, p_actor_id, recipient) || runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::DISCOVERY_RECIPIENT_UNKNOWN));
	}
	inv::OwnershipLayoutKind kind = inv::OwnershipLayoutKind::SPATIAL_GRID;
	const inv::Status status = inv::protocol::discovery_layout_kind(
			*runtime, discovery_store, recipient, to_container_id(p_container_id), kind);
	Dictionary d;
	d["ok"] = status.ok();
	d["status"] = status_dict(status);
	d["layout_kind"] = int(kind);
	return d;
}

// ---------------------------------------------------------------------------
// Derived queries
// ---------------------------------------------------------------------------

Dictionary InventoryAuthority::total_mass(int64_t p_inventory_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	int64_t mass_mg = 0;
	const inv::Status status = runtime->total_mass(mass_mg);
	Dictionary d = query_error(status);
	d["ok"] = status.ok();
	d["mass_mg"] = mass_mg;
	return d;
}

Dictionary InventoryAuthority::container_mass(int64_t p_inventory_id, int64_t p_container_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	int64_t mass_mg = 0;
	const inv::Status status = runtime->container_mass(to_container_id(p_container_id), mass_mg);
	Dictionary d = query_error(status);
	d["ok"] = status.ok();
	d["mass_mg"] = mass_mg;
	return d;
}

Dictionary InventoryAuthority::container_mass_capacity(int64_t p_inventory_id, int64_t p_container_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	int64_t mass_capacity_mg = 0;
	const inv::Status status = runtime->container_mass_capacity(to_container_id(p_container_id), mass_capacity_mg);
	Dictionary d = query_error(status);
	d["ok"] = status.ok();
	d["mass_capacity_mg"] = mass_capacity_mg;
	return d;
}

Dictionary InventoryAuthority::count_in_container(int64_t p_inventory_id, int64_t p_container_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	std::uint32_t count = 0;
	const inv::Status status = runtime->count_in_container(to_container_id(p_container_id), count);
	Dictionary d = query_error(status);
	d["ok"] = status.ok();
	d["count"] = int(count);
	return d;
}

Dictionary InventoryAuthority::remaining_count_capacity(int64_t p_inventory_id, int64_t p_container_id) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	std::uint32_t remaining = 0;
	const inv::Status status = runtime->remaining_count_capacity(to_container_id(p_container_id), remaining);
	Dictionary d = query_error(status);
	d["ok"] = status.ok();
	d["remaining"] = int(remaining);
	return d;
}

Dictionary InventoryAuthority::fits(int64_t p_inventory_id, const String &p_item_definition_identifier, const Dictionary &p_destination, int64_t p_quantity, int64_t p_excluding_item) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	if (runtime == nullptr) {
		return query_error(inv::make_status(inv::StatusCode::NOT_FOUND));
	}
	inv::ItemLocation location;
	if (!location_from_dict(p_destination, location)) {
		return query_error(inv::make_status(inv::StatusCode::INVALID_ARGUMENT));
	}
	const inv::Status status = runtime->fits(to_std(p_item_definition_identifier), location,
			std::uint64_t(p_quantity < 0 ? 0 : p_quantity), to_item_id(p_excluding_item));
	Dictionary d = query_error(status);
	d["ok"] = status.ok();
	return d;
}

bool InventoryAuthority::has_feature(int64_t p_inventory_id, const String &p_feature_identifier) const {
	const inv::InventoryRuntime *runtime = runtime_for(p_inventory_id);
	return runtime != nullptr && runtime->has_feature(to_std(p_feature_identifier));
}

// ---------------------------------------------------------------------------
// _bind_methods
// ---------------------------------------------------------------------------

void InventoryAuthority::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_role", "role"), &InventoryAuthority::set_role);
	ClassDB::bind_method(D_METHOD("get_role"), &InventoryAuthority::get_role);
	ClassDB::bind_method(D_METHOD("set_catalog", "catalog"), &InventoryAuthority::set_catalog);
	ClassDB::bind_method(D_METHOD("get_catalog"), &InventoryAuthority::get_catalog);
	ClassDB::bind_method(D_METHOD("get_last_status"), &InventoryAuthority::get_last_status);

	ClassDB::bind_method(D_METHOD("create_inventory", "profile_identifier"), &InventoryAuthority::create_inventory);
	ClassDB::bind_method(D_METHOD("has_inventory", "inventory_id"), &InventoryAuthority::has_inventory);
	ClassDB::bind_method(D_METHOD("inventory_revision", "inventory_id"), &InventoryAuthority::inventory_revision);
	ClassDB::bind_method(D_METHOD("unload_inventory", "inventory_id"), &InventoryAuthority::unload_inventory);

	ClassDB::bind_method(D_METHOD("move_item", "inventory_id", "item", "destination", "actor", "command_id"),
			&InventoryAuthority::move_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("rotate_item", "inventory_id", "item", "rotated", "actor", "command_id"),
			&InventoryAuthority::rotate_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("split_stack", "inventory_id", "source", "quantity", "destination", "actor", "command_id"),
			&InventoryAuthority::split_stack, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("merge_stacks", "inventory_id", "source", "destination_item", "actor", "command_id"),
			&InventoryAuthority::merge_stacks, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("insert_item", "inventory_id", "item_definition_identifier", "quantity", "destination", "actor", "command_id"),
			&InventoryAuthority::insert_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("remove_item", "inventory_id", "item", "actor", "command_id"),
			&InventoryAuthority::remove_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("equip_item", "inventory_id", "item", "destination_container", "slot_identifier", "actor", "command_id"),
			&InventoryAuthority::equip_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("unequip_item", "inventory_id", "item", "destination", "actor", "command_id"),
			&InventoryAuthority::unequip_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("swap_items", "inventory_id", "item_a", "item_b", "actor", "command_id"),
			&InventoryAuthority::swap_items, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("auto_place_item", "inventory_id", "item", "destination_container", "actor", "command_id"),
			&InventoryAuthority::auto_place_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("quick_transfer_item", "source_inventory_id", "destination_inventory_id", "item", "allow_partial", "actor", "command_id"),
			&InventoryAuthority::quick_transfer_item, DEFVAL(false), DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("transfer_item_to_provider", "source_inventory_id", "destination_inventory_id", "item", "destination_provider", "actor", "command_id"),
			&InventoryAuthority::transfer_item_to_provider, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("preview_transfer_item_to_provider", "source_inventory_id", "destination_inventory_id", "item", "destination_provider", "actor"),
			&InventoryAuthority::preview_transfer_item_to_provider, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("loot_item", "source_inventory_id", "destination_inventory_id", "item", "destination_location", "actor", "command_id"),
			&InventoryAuthority::loot_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("drop_item", "inventory_id", "item", "external_owner", "actor", "command_id"),
			&InventoryAuthority::drop_item, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("settle_inventory", "inventory_id", "plan", "actor", "command_id"),
			&InventoryAuthority::settle_inventory, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("assign_reference", "inventory_id", "item", "actor", "command_id"),
			&InventoryAuthority::assign_reference, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("clear_reference", "inventory_id", "reference", "actor", "command_id"),
			&InventoryAuthority::clear_reference, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("set_item_component", "inventory_id", "item", "component_identifier", "payload", "actor", "command_id"),
			&InventoryAuthority::set_item_component, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("remove_item_component", "inventory_id", "item", "component_identifier", "actor", "command_id"),
			&InventoryAuthority::remove_item_component, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("prepare_quantity_reservation", "inventory_id", "reservation_id", "required_trait", "container_priorities", "quantity", "expected_revision", "deadline_tick"),
			&InventoryAuthority::prepare_quantity_reservation, DEFVAL(int64_t(-1)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("release_quantity_reservation", "inventory_id", "reservation_id"),
			&InventoryAuthority::release_quantity_reservation);
	ClassDB::bind_method(D_METHOD("commit_quantity_reservation_silent", "inventory_id", "reservation_id"),
			&InventoryAuthority::commit_quantity_reservation_silent);
	ClassDB::bind_method(D_METHOD("rollback_quantity_reservation", "inventory_id", "reservation_id"),
			&InventoryAuthority::rollback_quantity_reservation);
	ClassDB::bind_method(D_METHOD("publish_quantity_reservation", "reservation_id"),
			&InventoryAuthority::publish_quantity_reservation);
	ClassDB::bind_method(D_METHOD("expire_quantity_reservation", "inventory_id", "reservation_id", "current_tick"),
			&InventoryAuthority::expire_quantity_reservation);
	ClassDB::bind_method(D_METHOD("health_quantity_reservation", "reservation_id"),
			&InventoryAuthority::health_quantity_reservation);
	ClassDB::bind_method(D_METHOD("active_quantity_reservation_count"),
			&InventoryAuthority::active_quantity_reservation_count);

	ClassDB::bind_method(D_METHOD("submit_command_bytes", "bytes"), &InventoryAuthority::submit_command_bytes);
	ClassDB::bind_method(D_METHOD("encode_move_command_bytes_for_test", "inventory_id", "item", "destination", "expected_revision", "actor", "command_id"),
			&InventoryAuthority::encode_move_command_bytes_for_test, DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD(
				"encode_quick_transfer_command_bytes_for_test",
				"source_inventory_id", "destination_inventory_id", "item", "allow_partial",
				"source_expected_revision", "destination_expected_revision", "actor", "command_id"),
			&InventoryAuthority::encode_quick_transfer_command_bytes_for_test,
			DEFVAL(int64_t(0)), DEFVAL(int64_t(0)));

	ClassDB::bind_method(D_METHOD("snapshot", "inventory_id", "visibility"), &InventoryAuthority::snapshot,
			DEFVAL(int(InventorySnapshotResource::VISIBILITY_OWNER)));
	ClassDB::bind_method(D_METHOD("snapshot_envelope_bytes", "inventory_id", "visibility"), &InventoryAuthority::snapshot_envelope_bytes,
			DEFVAL(int(InventorySnapshotResource::VISIBILITY_OWNER)));
	ClassDB::bind_method(D_METHOD("observer_snapshot_envelope_bytes", "session_id", "actor_id", "inventory_id", "visibility"),
			&InventoryAuthority::observer_snapshot_envelope_bytes,
			DEFVAL(int(InventorySnapshotResource::VISIBILITY_OBSERVER)));
	ClassDB::bind_method(D_METHOD("observer_delta_bytes", "session_id", "actor_id", "inventory_id", "predecessor_sequence"),
			&InventoryAuthority::observer_delta_bytes);
	ClassDB::bind_method(D_METHOD("last_delta_batch_bytes"), &InventoryAuthority::last_delta_batch_bytes);
	ClassDB::bind_method(D_METHOD("session_hello_bytes"), &InventoryAuthority::session_hello_bytes);
	ClassDB::bind_method(D_METHOD("make_persistence_record", "inventory_id"), &InventoryAuthority::make_persistence_record);
	ClassDB::bind_method(D_METHOD("apply_persistence_record", "bytes", "replace_existing"),
			&InventoryAuthority::apply_persistence_record, DEFVAL(false));

	ClassDB::bind_method(D_METHOD("register_discovery_recipient", "session_id", "actor_id"),
			&InventoryAuthority::register_discovery_recipient);
	ClassDB::bind_method(D_METHOD("teardown_discovery_recipient", "session_id", "actor_id"),
			&InventoryAuthority::teardown_discovery_recipient);
	ClassDB::bind_method(D_METHOD("teardown_discovery_session", "session_id"),
			&InventoryAuthority::teardown_discovery_session);
	ClassDB::bind_method(D_METHOD("revoke_discovery_inventory", "session_id", "actor_id", "inventory_id"),
			&InventoryAuthority::revoke_discovery_inventory);
	ClassDB::bind_method(D_METHOD("discovery_revision", "session_id", "actor_id", "inventory_id"),
			&InventoryAuthority::discovery_revision);
	ClassDB::bind_method(D_METHOD("begin_container_search", "session_id", "actor_id", "inventory_id", "container_token", "request_id", "expected_inventory_revision", "expected_discovery_revision"),
			&InventoryAuthority::begin_container_search,
			DEFVAL(int64_t(0)), DEFVAL(int64_t(-1)), DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("begin_item_scan", "session_id", "actor_id", "inventory_id", "entry_token", "request_id", "expected_inventory_revision", "expected_discovery_revision"),
			&InventoryAuthority::begin_item_scan,
			DEFVAL(int64_t(0)), DEFVAL(int64_t(-1)), DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("cancel_discovery", "session_id", "actor_id", "inventory_id", "request_id", "expected_inventory_revision", "expected_discovery_revision"),
			&InventoryAuthority::cancel_discovery,
			DEFVAL(int64_t(0)), DEFVAL(int64_t(-1)), DEFVAL(int64_t(-1)));
	ClassDB::bind_method(D_METHOD("advance_discovery", "session_id", "actor_id", "elapsed_ms"),
			&InventoryAuthority::advance_discovery);
	ClassDB::bind_method(D_METHOD("discovery_view", "session_id", "actor_id", "inventory_id"),
			&InventoryAuthority::discovery_view);
	ClassDB::bind_method(D_METHOD("discovery_view_bytes", "session_id", "actor_id", "inventory_id"),
			&InventoryAuthority::discovery_view_bytes);
	ClassDB::bind_method(D_METHOD("discovery_delta", "session_id", "actor_id", "inventory_id", "predecessor_inventory_revision", "predecessor_discovery_revision"),
			&InventoryAuthority::discovery_delta);
	ClassDB::bind_method(D_METHOD("discovery_delta_bytes", "session_id", "actor_id", "inventory_id", "predecessor_inventory_revision", "predecessor_discovery_revision"),
			&InventoryAuthority::discovery_delta_bytes);
	ClassDB::bind_method(D_METHOD("discovery_hello_bytes"), &InventoryAuthority::discovery_hello_bytes);
	ClassDB::bind_method(D_METHOD("discovery_count_in_container", "session_id", "actor_id", "inventory_id", "container_id"),
			&InventoryAuthority::discovery_count_in_container);
	ClassDB::bind_method(D_METHOD("discovery_layout_kind", "session_id", "actor_id", "inventory_id", "container_id"),
			&InventoryAuthority::discovery_layout_kind);

	ClassDB::bind_method(D_METHOD("total_mass", "inventory_id"), &InventoryAuthority::total_mass);
	ClassDB::bind_method(D_METHOD("container_mass", "inventory_id", "container_id"), &InventoryAuthority::container_mass);
	ClassDB::bind_method(D_METHOD("container_mass_capacity", "inventory_id", "container_id"), &InventoryAuthority::container_mass_capacity);
	ClassDB::bind_method(D_METHOD("count_in_container", "inventory_id", "container_id"), &InventoryAuthority::count_in_container);
	ClassDB::bind_method(D_METHOD("remaining_count_capacity", "inventory_id", "container_id"), &InventoryAuthority::remaining_count_capacity);
	ClassDB::bind_method(D_METHOD("fits", "inventory_id", "item_definition_identifier", "destination", "quantity", "excluding_item"),
			&InventoryAuthority::fits, DEFVAL(int64_t(1)), DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("has_feature", "inventory_id", "feature_identifier"), &InventoryAuthority::has_feature);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "role", PROPERTY_HINT_ENUM, "OfflineAuthority,ServerAuthority"),
			"set_role", "get_role");
	// No ADD_PROPERTY for "catalog": InventoryCatalog is RefCounted, not
	// Resource (see inventory_catalog.h's class comment), so
	// PROPERTY_HINT_RESOURCE_TYPE's editor file-picker semantics do not
	// apply to it. Assignment is a script-driven call
	// (`authority.set_catalog(catalog)`), matching how a sealed catalog is
	// necessarily built at runtime, not authored in the Inspector.

	ADD_SIGNAL(MethodInfo("transaction_committed", PropertyInfo(Variant::DICTIONARY, "result")));
	ADD_SIGNAL(MethodInfo("delta_ready", PropertyInfo(Variant::PACKED_BYTE_ARRAY, "bytes")));
	ADD_SIGNAL(MethodInfo("inventory_unloaded", PropertyInfo(Variant::INT, "inventory_id")));
	ADD_SIGNAL(MethodInfo("inventory_generation_changing", PropertyInfo(Variant::INT, "inventory_id")));
	ADD_SIGNAL(MethodInfo("quantity_reservation_published", PropertyInfo(Variant::DICTIONARY, "result")));
	ADD_SIGNAL(MethodInfo(
			"discovery_result",
			PropertyInfo(Variant::INT, "session_id"),
			PropertyInfo(Variant::INT, "actor_id"),
			PropertyInfo(Variant::INT, "inventory_id"),
			PropertyInfo(Variant::OBJECT, "result", PROPERTY_HINT_RESOURCE_TYPE, "InventoryDiscoveryResultResource")));
	ADD_SIGNAL(MethodInfo(
			"discovery_view_ready",
			PropertyInfo(Variant::INT, "session_id"),
			PropertyInfo(Variant::INT, "actor_id"),
			PropertyInfo(Variant::INT, "inventory_id"),
			PropertyInfo(Variant::OBJECT, "view", PROPERTY_HINT_RESOURCE_TYPE, "InventoryDiscoverySnapshotResource")));
	ADD_SIGNAL(MethodInfo(
			"discovery_delta_ready",
			PropertyInfo(Variant::INT, "session_id"),
			PropertyInfo(Variant::INT, "actor_id"),
			PropertyInfo(Variant::INT, "inventory_id"),
			PropertyInfo(Variant::PACKED_BYTE_ARRAY, "bytes")));

	BIND_ENUM_CONSTANT(ROLE_OFFLINE_AUTHORITY);
	BIND_ENUM_CONSTANT(ROLE_SERVER_AUTHORITY);
}

} // namespace godot
