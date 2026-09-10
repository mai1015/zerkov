#include "protocol/inv_protocol_codec.h"

#include "core/inv_hash.h"

#include <cstdio>
#include <type_traits>
#include <utility>
#include <variant>

namespace inv::protocol {

namespace {

// --- Local byte-envelope bounds not already named in core/inv_limits.h ----
//
// Every bound named directly in contracts.md's "Command / delta / snapshot
// bytes" row (MAX_COMMAND_BYTES/MAX_DELTA_BYTES/MAX_SNAPSHOT_BYTES) is a
// compatibility-versioned hard limit reused verbatim below. ResultEnvelope
// and PersistenceRecord have no such named hard limit; these two local
// constants derive from existing hard limits rather than introducing new
// independent ones that would need to participate in
// inv::encode_hard_limits()'s manifest/session digest.
constexpr std::size_t MAX_RESULT_ENVELOPE_BYTES = MAX_DELTA_BYTES;
constexpr std::size_t MAX_PERSISTENCE_RECORD_BYTES = MAX_SNAPSHOT_BYTES + 4096;

Status fail_trailing(const ByteReader &p_reader) {
	return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRAILING_PAYLOAD_BYTES, p_reader.remaining());
}

Status fail_too_large(std::size_t p_remaining) {
	return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_remaining);
}

// --- ItemLocation <-> wire (reuses core::SnapshotLocation's identical byte
// layout; see inv_snapshot.h's to_snapshot_location()/decode_snapshot_
// location() doc comment) --------------------------------------------------

Status decode_item_location(ByteReader &p_reader, ItemLocation &r_out) {
	SnapshotLocation location;
	Status status = decode_snapshot_location(p_reader, location);
	if (!status.ok()) {
		return status;
	}
	return from_snapshot_location(location, r_out);
}

// --- SettlementEntry <-> wire (mirrors core/inv_commands.h's commands_
// detail::encode_settlement_entry()) ----------------------------------------

Status decode_settlement_entry(ByteReader &p_reader, SettlementEntry &r_out) {
	SettlementEntry candidate;
	std::uint64_t item_raw = 0;
	if (!p_reader.read_u64(item_raw)) {
		return p_reader.status();
	}
	candidate.item = ItemInstanceId{ item_raw };
	std::uint8_t tag = 0;
	if (!p_reader.read_u8(tag)) {
		return p_reader.status();
	}
	if (tag == static_cast<std::uint8_t>(commands_detail::SettlementDispositionTag::RETAIN)) {
		candidate.disposition = SettlementRetain{};
	} else if (tag == static_cast<std::uint8_t>(commands_detail::SettlementDispositionTag::TRANSFER_TO)) {
		SettlementTransfer transfer;
		std::uint64_t destination_raw = 0;
		if (!p_reader.read_u64(destination_raw)) {
			return p_reader.status();
		}
		transfer.destination = InventoryId{ destination_raw };
		Status status = decode_item_location(p_reader, transfer.location);
		if (!status.ok()) {
			return status;
		}
		candidate.disposition = std::move(transfer);
	} else if (tag == static_cast<std::uint8_t>(commands_detail::SettlementDispositionTag::RELEASE_TO)) {
		SettlementRelease release;
		std::uint64_t owner_raw = 0;
		if (!p_reader.read_u64(owner_raw)) {
			return p_reader.status();
		}
		release.external_owner = ExternalOwnerId{ owner_raw };
		candidate.disposition = release;
	} else {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- Command <-> wire (mirrors core/inv_commands.h's commands_detail::
// encode_command(); CommandTag/SettlementDispositionTag are that namespace's
// own public enums, reused here rather than redeclared) --------------------

Status decode_command(ByteReader &p_reader, Command &r_out) {
	std::uint8_t tag = 0;
	if (!p_reader.read_u8(tag)) {
		return p_reader.status();
	}
	switch (static_cast<commands_detail::CommandTag>(tag)) {
		case commands_detail::CommandTag::MOVE_ITEM: {
			MoveItemCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			Status status = decode_item_location(p_reader, cmd.destination);
			if (!status.ok()) {
				return status;
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::ROTATE_ITEM: {
			RotateItemCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			if (!p_reader.read_bool(cmd.rotated)) {
				return p_reader.status();
			}
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::SPLIT_STACK: {
			SplitStackCommand cmd;
			std::uint64_t source_raw = 0;
			if (!p_reader.read_u64(source_raw)) {
				return p_reader.status();
			}
			cmd.source = ItemInstanceId{ source_raw };
			if (!p_reader.read_u64(cmd.quantity)) {
				return p_reader.status();
			}
			Status status = decode_item_location(p_reader, cmd.destination);
			if (!status.ok()) {
				return status;
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::MERGE_STACKS: {
			MergeStacksCommand cmd;
			std::uint64_t source_raw = 0;
			std::uint64_t destination_raw = 0;
			if (!p_reader.read_u64(source_raw) || !p_reader.read_u64(destination_raw)) {
				return p_reader.status();
			}
			cmd.source = ItemInstanceId{ source_raw };
			cmd.destination = ItemInstanceId{ destination_raw };
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::INSERT_ITEM: {
			InsertItemCommand cmd;
			if (!p_reader.read_string(cmd.item_definition_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			if (!p_reader.read_u64(cmd.quantity)) {
				return p_reader.status();
			}
			Status status = decode_item_location(p_reader, cmd.destination);
			if (!status.ok()) {
				return status;
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::REMOVE_ITEM: {
			RemoveItemCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::EQUIP_ITEM: {
			EquipItemCommand cmd;
			std::uint64_t item_raw = 0;
			std::uint64_t container_raw = 0;
			if (!p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			if (!p_reader.read_u64(container_raw)) {
				return p_reader.status();
			}
			cmd.destination_container = ContainerInstanceId{ container_raw };
			if (!p_reader.read_string(cmd.slot_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::UNEQUIP_ITEM: {
			UnequipItemCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			Status status = decode_item_location(p_reader, cmd.destination);
			if (!status.ok()) {
				return status;
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::SWAP_ITEMS: {
			SwapItemsCommand cmd;
			std::uint64_t a_raw = 0;
			std::uint64_t b_raw = 0;
			if (!p_reader.read_u64(a_raw) || !p_reader.read_u64(b_raw)) {
				return p_reader.status();
			}
			cmd.item_a = ItemInstanceId{ a_raw };
			cmd.item_b = ItemInstanceId{ b_raw };
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::AUTO_PLACE_ITEM: {
			AutoPlaceItemCommand cmd;
			std::uint64_t item_raw = 0;
			std::uint64_t destination_raw = 0;
			std::uint64_t container_raw = 0;
			if (!p_reader.read_u64(item_raw) || !p_reader.read_u64(destination_raw) || !p_reader.read_u64(container_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			cmd.destination = InventoryId{ destination_raw };
			cmd.destination_container = ContainerInstanceId{ container_raw };
			r_out = cmd;
			return ok_status();
		}
			case commands_detail::CommandTag::QUICK_TRANSFER_ITEM: {
				QuickTransferItemCommand cmd;
			std::uint64_t item_raw = 0;
			std::uint64_t source_raw = 0;
			std::uint64_t destination_raw = 0;
			if (!p_reader.read_u64(item_raw) || !p_reader.read_u64(source_raw) || !p_reader.read_u64(destination_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			cmd.source = InventoryId{ source_raw };
			cmd.destination = InventoryId{ destination_raw };
			if (!p_reader.read_bool(cmd.allow_partial)) {
				return p_reader.status();
			}
				r_out = cmd;
				return ok_status();
			}
			case commands_detail::CommandTag::TARGETED_PROVIDER_TRANSFER: {
				TargetedProviderTransferCommand cmd;
				std::uint64_t source_raw = 0;
				std::uint64_t destination_raw = 0;
				std::uint64_t item_raw = 0;
				std::uint64_t provider_raw = 0;
				if (!p_reader.read_u64(source_raw) ||
						!p_reader.read_u64(destination_raw) ||
						!p_reader.read_u64(item_raw) ||
						!p_reader.read_u64(provider_raw)) {
					return p_reader.status();
				}
				cmd.source = InventoryId{ source_raw };
				cmd.destination = InventoryId{ destination_raw };
				cmd.item = ItemInstanceId{ item_raw };
				cmd.destination_provider = ItemInstanceId{ provider_raw };
				r_out = cmd;
				return ok_status();
			}
			case commands_detail::CommandTag::LOOT_ITEM: {
			LootItemCommand cmd;
			std::uint64_t source_raw = 0;
			std::uint64_t destination_raw = 0;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(source_raw) || !p_reader.read_u64(destination_raw) || !p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.source = InventoryId{ source_raw };
			cmd.destination = InventoryId{ destination_raw };
			cmd.item = ItemInstanceId{ item_raw };
			Status status = decode_item_location(p_reader, cmd.destination_location);
			if (!status.ok()) {
				return status;
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::DROP_ITEM: {
			DropItemCommand cmd;
			std::uint64_t item_raw = 0;
			std::uint64_t owner_raw = 0;
			if (!p_reader.read_u64(item_raw) || !p_reader.read_u64(owner_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			cmd.external_owner = ExternalOwnerId{ owner_raw };
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::SETTLE_INVENTORY: {
			SettleInventoryCommand cmd;
			std::uint64_t inventory_raw = 0;
			if (!p_reader.read_u64(inventory_raw)) {
				return p_reader.status();
			}
			cmd.inventory = InventoryId{ inventory_raw };
			std::size_t plan_count = 0;
			if (!p_reader.read_count(plan_count, MAX_SETTLEMENT_PLAN_ENTRIES, /*p_min_bytes_per_entry=*/9)) {
				return p_reader.status();
			}
			cmd.plan.reserve(plan_count);
			for (std::size_t i = 0; i < plan_count; ++i) {
				SettlementEntry entry;
				Status status = decode_settlement_entry(p_reader, entry);
				if (!status.ok()) {
					return status;
				}
				cmd.plan.push_back(std::move(entry));
			}
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::ASSIGN_REFERENCE: {
			AssignReferenceCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::CLEAR_REFERENCE: {
			ClearReferenceCommand cmd;
			std::uint64_t reference_raw = 0;
			if (!p_reader.read_u64(reference_raw)) {
				return p_reader.status();
			}
			cmd.reference = ReferenceId{ reference_raw };
			r_out = cmd;
			return ok_status();
		}
		case commands_detail::CommandTag::SET_ITEM_COMPONENT: {
			SetItemComponentCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw) ||
					!p_reader.read_string(cmd.component_identifier, MAX_IDENTIFIER_BYTES) ||
					!p_reader.read_blob(cmd.payload, MAX_TRAIT_PAYLOAD_BYTES)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			r_out = std::move(cmd);
			return ok_status();
		}
		case commands_detail::CommandTag::REMOVE_ITEM_COMPONENT: {
			RemoveItemComponentCommand cmd;
			std::uint64_t item_raw = 0;
			if (!p_reader.read_u64(item_raw) ||
					!p_reader.read_string(cmd.component_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			cmd.item = ItemInstanceId{ item_raw };
			r_out = std::move(cmd);
			return ok_status();
		}
		default:
			p_reader.fail(DiagnosticId::INVALID_ENUM);
			return p_reader.status();
	}
}

// --- CommandHeader <-> wire -------------------------------------------

Status encode_command_header(const CommandHeader &p_header, ByteWriter &p_writer) {
	p_writer.write_u64(p_header.command_id.value);
	p_writer.write_u64(p_header.actor);
	p_writer.write_count(p_header.expected_revisions.size(), MAX_INVENTORIES_PER_TRANSACTION);
	for (const ExpectedRevision &expected : p_header.expected_revisions) {
		p_writer.write_u64(expected.inventory.value);
		p_writer.write_u64(expected.revision);
	}
	return p_writer.status();
}

Status decode_command_header(ByteReader &p_reader, CommandHeader &r_out) {
	CommandHeader candidate;
	std::uint64_t command_id_raw = 0;
	if (!p_reader.read_u64(command_id_raw)) {
		return p_reader.status();
	}
	candidate.command_id = CommandId{ command_id_raw };
	if (!p_reader.read_u64(candidate.actor)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_INVENTORIES_PER_TRANSACTION, /*p_min_bytes_per_entry=*/16)) {
		return p_reader.status();
	}
	candidate.expected_revisions.reserve(count);
	for (std::size_t i = 0; i < count; ++i) {
		std::uint64_t inventory_raw = 0;
		std::uint64_t revision = 0;
		if (!p_reader.read_u64(inventory_raw) || !p_reader.read_u64(revision)) {
			return p_reader.status();
		}
		candidate.expected_revisions.push_back(ExpectedRevision{ InventoryId{ inventory_raw }, revision });
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- Status <-> wire -----------------------------------------------------
//
// code/diagnostic are decoded WITHOUT range validation against currently-
// known enum values on purpose: StatusCode/DiagnosticId are append-only
// (contracts.md), and this pair is carried DATA -- it never determines how
// any subsequent byte is interpreted (unlike a location/op/settlement tag,
// which gates parsing and therefore MUST be range-checked before
// proceeding). A peer that does not yet recognize a newer diagnostic id
// still decodes the envelope structurally; only the (out-of-scope for this
// slice) presentation of that specific value is degraded.

Status encode_status_wire(const Status &p_status, ByteWriter &p_writer) {
	p_writer.write_u16(static_cast<std::uint16_t>(p_status.code));
	p_writer.write_u16(static_cast<std::uint16_t>(p_status.diagnostic));
	p_writer.write_u64(p_status.detail);
	return p_writer.status();
}

Status decode_status_wire(ByteReader &p_reader, Status &r_out) {
	std::uint16_t code_raw = 0;
	std::uint16_t diagnostic_raw = 0;
	std::uint64_t detail = 0;
	if (!p_reader.read_u16(code_raw) || !p_reader.read_u16(diagnostic_raw) || !p_reader.read_u64(detail)) {
		return p_reader.status();
	}
	r_out.code = static_cast<StatusCode>(code_raw);
	r_out.diagnostic = static_cast<DiagnosticId>(diagnostic_raw);
	r_out.detail = detail;
	return ok_status();
}

// --- TransactionEvent/RevisionOutcome/DroppedItemValue <-> wire -----------

Status encode_transaction_event(const TransactionEvent &p_event, ByteWriter &p_writer) {
	p_writer.write_u8(static_cast<std::uint8_t>(p_event.kind));
	p_writer.write_u64(p_event.item.value);
	p_writer.write_u64(p_event.secondary_item.value);
	p_writer.write_u64(p_event.source_container.value);
	p_writer.write_u64(p_event.destination_container.value);
	p_writer.write_u64(p_event.reference.value);
	return p_writer.status();
}

Status decode_transaction_event(ByteReader &p_reader, TransactionEvent &r_out) {
	std::uint8_t kind_raw = 0;
	if (!p_reader.read_u8(kind_raw)) {
		return p_reader.status();
	}
	if (kind_raw < static_cast<std::uint8_t>(TransactionEventKind::MOVED) ||
			kind_raw > static_cast<std::uint8_t>(TransactionEventKind::COMPONENT_REMOVED)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	TransactionEvent candidate;
	candidate.kind = static_cast<TransactionEventKind>(kind_raw);
	std::uint64_t item_raw = 0;
	std::uint64_t secondary_raw = 0;
	std::uint64_t source_raw = 0;
	std::uint64_t destination_raw = 0;
	std::uint64_t reference_raw = 0;
	if (!p_reader.read_u64(item_raw) || !p_reader.read_u64(secondary_raw) || !p_reader.read_u64(source_raw) ||
			!p_reader.read_u64(destination_raw) || !p_reader.read_u64(reference_raw)) {
		return p_reader.status();
	}
	candidate.item = ItemInstanceId{ item_raw };
	candidate.secondary_item = ItemInstanceId{ secondary_raw };
	candidate.source_container = ContainerInstanceId{ source_raw };
	candidate.destination_container = ContainerInstanceId{ destination_raw };
	candidate.reference = ReferenceId{ reference_raw };
	r_out = candidate;
	return ok_status();
}

Status encode_mutable_component(const MutableComponent &p_component, ByteWriter &p_writer) {
	p_writer.write_string(p_component.component_identifier, MAX_IDENTIFIER_BYTES);
	p_writer.write_blob(p_component.payload, MAX_TRAIT_PAYLOAD_BYTES);
	return p_writer.status();
}

Status decode_mutable_component(ByteReader &p_reader, MutableComponent &r_out) {
	MutableComponent candidate;
	if (!p_reader.read_string(candidate.component_identifier, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_blob(candidate.payload, MAX_TRAIT_PAYLOAD_BYTES)) {
		return p_reader.status();
	}
	r_out = std::move(candidate);
	return ok_status();
}

Status encode_dropped_item(const DroppedItemValue &p_dropped, ByteWriter &p_writer) {
	p_writer.write_string(p_dropped.item_definition_identifier, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_dropped.quantity);
	p_writer.write_count(p_dropped.mutable_components.size(), MAX_MUTABLE_COMPONENTS_PER_ITEM);
	for (const MutableComponent &component : p_dropped.mutable_components) {
		Status status = encode_mutable_component(component, p_writer);
		if (!status.ok()) {
			return status;
		}
	}
	p_writer.write_u64(p_dropped.external_owner.value);
	return p_writer.status();
}

Status decode_dropped_item(ByteReader &p_reader, DroppedItemValue &r_out) {
	DroppedItemValue candidate;
	if (!p_reader.read_string(candidate.item_definition_identifier, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.quantity)) {
		return p_reader.status();
	}
	std::size_t component_count = 0;
	if (!p_reader.read_count(component_count, MAX_MUTABLE_COMPONENTS_PER_ITEM, /*p_min_bytes_per_entry=*/8)) {
		return p_reader.status();
	}
	candidate.mutable_components.reserve(component_count);
	for (std::size_t i = 0; i < component_count; ++i) {
		MutableComponent component;
		Status status = decode_mutable_component(p_reader, component);
		if (!status.ok()) {
			return status;
		}
		candidate.mutable_components.push_back(std::move(component));
	}
	std::uint64_t owner_raw = 0;
	if (!p_reader.read_u64(owner_raw)) {
		return p_reader.status();
	}
	candidate.external_owner = ExternalOwnerId{ owner_raw };
	r_out = std::move(candidate);
	return ok_status();
}

// --- DeltaOp/InventoryDelta <-> wire (mirrors core/inv_deltas.h) ----------

Status encode_delta_op(const DeltaOp &p_op, ByteWriter &p_writer) {
	return std::visit(
			[&](const auto &p_body) -> Status {
				using T = std::decay_t<decltype(p_body)>;
				if constexpr (std::is_same_v<T, ItemCreatedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::ITEM_CREATED));
					p_writer.write_u64(p_body.item);
					p_writer.write_string(p_body.item_definition_identifier, MAX_IDENTIFIER_BYTES);
					p_writer.write_u64(p_body.quantity);
					Status status = encode_snapshot_location(p_body.location, p_writer);
					if (!status.ok()) {
						return status;
					}
					p_writer.write_count(p_body.mutable_components.size(), MAX_MUTABLE_COMPONENTS_PER_ITEM);
					for (const SnapshotMutableComponent &component : p_body.mutable_components) {
						p_writer.write_string(component.component_identifier, MAX_IDENTIFIER_BYTES);
						p_writer.write_blob(component.payload, MAX_TRAIT_PAYLOAD_BYTES);
					}
					p_writer.write_count(p_body.provided_containers.size(), MAX_ITEM_PROVIDED_CONTAINERS);
					for (std::uint64_t provided : p_body.provided_containers) {
						p_writer.write_u64(provided);
					}
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ItemDestroyedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::ITEM_DESTROYED));
					p_writer.write_u64(p_body.item);
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ItemMovedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::ITEM_MOVED));
					p_writer.write_u64(p_body.item);
					return encode_snapshot_location(p_body.location, p_writer);
				} else if constexpr (std::is_same_v<T, ItemQuantityOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::ITEM_QUANTITY));
					p_writer.write_u64(p_body.item);
					p_writer.write_u64(p_body.quantity);
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ItemComponentSetOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::ITEM_COMPONENT_SET));
					p_writer.write_u64(p_body.item);
					p_writer.write_string(p_body.component.component_identifier, MAX_IDENTIFIER_BYTES);
					p_writer.write_blob(p_body.component.payload, MAX_TRAIT_PAYLOAD_BYTES);
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ItemComponentRemovedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::ITEM_COMPONENT_REMOVED));
					p_writer.write_u64(p_body.item);
					p_writer.write_string(p_body.component_identifier, MAX_IDENTIFIER_BYTES);
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ContainerAdoptedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::CONTAINER_ADOPTED));
					p_writer.write_u64(p_body.container);
					p_writer.write_string(p_body.container_definition_identifier, MAX_IDENTIFIER_BYTES);
					p_writer.write_u64(p_body.provider_item);
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ContainerReleasedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::CONTAINER_RELEASED));
					p_writer.write_u64(p_body.container);
					return p_writer.status();
				} else if constexpr (std::is_same_v<T, ReferenceAssignedOp>) {
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::REFERENCE_ASSIGNED));
					p_writer.write_u64(p_body.reference);
					p_writer.write_u64(p_body.item);
					return p_writer.status();
				} else {
					static_assert(std::is_same_v<T, ReferenceClearedOp>, "unhandled DeltaOp alternative");
					p_writer.write_u8(static_cast<std::uint8_t>(DeltaOpKind::REFERENCE_CLEARED));
					p_writer.write_u64(p_body.reference);
					return p_writer.status();
				}
			},
			p_op);
}

Status decode_delta_op(ByteReader &p_reader, DeltaOp &r_out) {
	std::uint8_t tag = 0;
	if (!p_reader.read_u8(tag)) {
		return p_reader.status();
	}
	switch (static_cast<DeltaOpKind>(tag)) {
		case DeltaOpKind::ITEM_CREATED: {
			ItemCreatedOp op;
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			if (!p_reader.read_string(op.item_definition_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			if (!p_reader.read_u64(op.quantity)) {
				return p_reader.status();
			}
			Status status = decode_snapshot_location(p_reader, op.location);
			if (!status.ok()) {
				return status;
			}
			std::size_t component_count = 0;
			if (!p_reader.read_count(component_count, MAX_MUTABLE_COMPONENTS_PER_ITEM, /*p_min_bytes_per_entry=*/8)) {
				return p_reader.status();
			}
			op.mutable_components.reserve(component_count);
			for (std::size_t i = 0; i < component_count; ++i) {
				SnapshotMutableComponent component;
				if (!p_reader.read_string(component.component_identifier, MAX_IDENTIFIER_BYTES)) {
					return p_reader.status();
				}
				if (!p_reader.read_blob(component.payload, MAX_TRAIT_PAYLOAD_BYTES)) {
					return p_reader.status();
				}
				op.mutable_components.push_back(std::move(component));
			}
			std::size_t provided_count = 0;
			if (!p_reader.read_count(provided_count, MAX_ITEM_PROVIDED_CONTAINERS, /*p_min_bytes_per_entry=*/8)) {
				return p_reader.status();
			}
			op.provided_containers.reserve(provided_count);
			for (std::size_t i = 0; i < provided_count; ++i) {
				std::uint64_t provided = 0;
				if (!p_reader.read_u64(provided)) {
					return p_reader.status();
				}
				op.provided_containers.push_back(provided);
			}
			r_out = std::move(op);
			return ok_status();
		}
		case DeltaOpKind::ITEM_DESTROYED: {
			ItemDestroyedOp op;
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::ITEM_MOVED: {
			ItemMovedOp op;
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			Status status = decode_snapshot_location(p_reader, op.location);
			if (!status.ok()) {
				return status;
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::ITEM_QUANTITY: {
			ItemQuantityOp op;
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			if (!p_reader.read_u64(op.quantity)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::ITEM_COMPONENT_SET: {
			ItemComponentSetOp op;
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			if (!p_reader.read_string(op.component.component_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			if (!p_reader.read_blob(op.component.payload, MAX_TRAIT_PAYLOAD_BYTES)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::ITEM_COMPONENT_REMOVED: {
			ItemComponentRemovedOp op;
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			if (!p_reader.read_string(op.component_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::CONTAINER_ADOPTED: {
			ContainerAdoptedOp op;
			if (!p_reader.read_u64(op.container)) {
				return p_reader.status();
			}
			if (!p_reader.read_string(op.container_definition_identifier, MAX_IDENTIFIER_BYTES)) {
				return p_reader.status();
			}
			if (!p_reader.read_u64(op.provider_item)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::CONTAINER_RELEASED: {
			ContainerReleasedOp op;
			if (!p_reader.read_u64(op.container)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::REFERENCE_ASSIGNED: {
			ReferenceAssignedOp op;
			if (!p_reader.read_u64(op.reference)) {
				return p_reader.status();
			}
			if (!p_reader.read_u64(op.item)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		case DeltaOpKind::REFERENCE_CLEARED: {
			ReferenceClearedOp op;
			if (!p_reader.read_u64(op.reference)) {
				return p_reader.status();
			}
			r_out = op;
			return ok_status();
		}
		default:
			p_reader.fail(DiagnosticId::INVALID_ENUM);
			return p_reader.status();
	}
}

Status encode_inventory_delta(const InventoryDelta &p_delta, ByteWriter &p_writer) {
	p_writer.write_u64(p_delta.inventory.value);
	p_writer.write_u64(p_delta.predecessor_revision);
	p_writer.write_u64(p_delta.successor_revision);
	p_writer.write_count(p_delta.ops.size(), MAX_DELTA_OPS_PER_INVENTORY);
	for (const DeltaOp &op : p_delta.ops) {
		Status status = encode_delta_op(op, p_writer);
		if (!status.ok()) {
			return status;
		}
	}
	return p_writer.status();
}

Status decode_inventory_delta(ByteReader &p_reader, InventoryDelta &r_out) {
	InventoryDelta candidate;
	std::uint64_t inventory_raw = 0;
	if (!p_reader.read_u64(inventory_raw)) {
		return p_reader.status();
	}
	candidate.inventory = InventoryId{ inventory_raw };
	if (!p_reader.read_u64(candidate.predecessor_revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.successor_revision)) {
		return p_reader.status();
	}
	std::size_t op_count = 0;
	if (!p_reader.read_count(op_count, MAX_DELTA_OPS_PER_INVENTORY, /*p_min_bytes_per_entry=*/9)) {
		return p_reader.status();
	}
	candidate.ops.reserve(op_count);
	for (std::size_t i = 0; i < op_count; ++i) {
		DeltaOp op;
		Status status = decode_delta_op(p_reader, op);
		if (!status.ok()) {
			return status;
		}
		candidate.ops.push_back(std::move(op));
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- JSON writer helpers (tasks.md 6.2; see inv_protocol_codec.h's rule-set
// doc comment on to_diagnostic_json()) --------------------------------------

void json_escape_append(std::string &r_out, const std::string &p_value) {
	r_out.push_back('"');
	for (unsigned char c : p_value) {
		switch (c) {
			case '"':
				r_out += "\\\"";
				break;
			case '\\':
				r_out += "\\\\";
				break;
			case '\n':
				r_out += "\\n";
				break;
			case '\r':
				r_out += "\\r";
				break;
			case '\t':
				r_out += "\\t";
				break;
			default:
				if (c < 0x20) {
					char buffer[8];
					std::snprintf(buffer, sizeof(buffer), "\\u%04x", static_cast<unsigned>(c));
					r_out += buffer;
				} else {
					r_out.push_back(static_cast<char>(c));
				}
		}
	}
	r_out.push_back('"');
}

void json_hex_append(std::string &r_out, const std::vector<std::uint8_t> &p_bytes) {
	static const char HEX[] = "0123456789abcdef";
	r_out.push_back('"');
	for (std::uint8_t byte : p_bytes) {
		r_out.push_back(HEX[(byte >> 4) & 0xF]);
		r_out.push_back(HEX[byte & 0xF]);
	}
	r_out.push_back('"');
}

// Every std::uint64_t scalar (id or otherwise) is quoted; see the rule-set
// doc comment on to_diagnostic_json() in the header.
void json_u64_append(std::string &r_out, std::uint64_t p_value) {
	r_out.push_back('"');
	r_out += std::to_string(p_value);
	r_out.push_back('"');
}

void json_bool_append(std::string &r_out, bool p_value) {
	r_out += p_value ? "true" : "false";
}

void json_location_append(std::string &r_out, const SnapshotLocation &p_location) {
	r_out += '{';
	r_out += "\"container\":";
	json_u64_append(r_out, p_location.container);
	r_out += ",\"kind\":";
	r_out += std::to_string(static_cast<unsigned>(p_location.kind));
	r_out += ",\"ordinal\":";
	r_out += std::to_string(p_location.ordinal);
	r_out += ",\"rotated\":";
	json_bool_append(r_out, p_location.rotated);
	r_out += ",\"slot_identifier\":";
	json_escape_append(r_out, p_location.slot_identifier);
	r_out += ",\"x\":";
	r_out += std::to_string(p_location.x);
	r_out += ",\"y\":";
	r_out += std::to_string(p_location.y);
	r_out += '}';
}

void json_snapshot_component_append(std::string &r_out, const SnapshotMutableComponent &p_component) {
	r_out += '{';
	r_out += "\"component_identifier\":";
	json_escape_append(r_out, p_component.component_identifier);
	r_out += ",\"payload\":";
	json_hex_append(r_out, p_component.payload);
	r_out += '}';
}

void json_delta_op_append(std::string &r_out, const DeltaOp &p_op) {
	std::visit(
			[&](const auto &p_body) {
				using T = std::decay_t<decltype(p_body)>;
				r_out += '{';
				if constexpr (std::is_same_v<T, ItemCreatedOp>) {
					r_out += "\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"item_definition_identifier\":";
					json_escape_append(r_out, p_body.item_definition_identifier);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::ITEM_CREATED));
					r_out += ",\"location\":";
					json_location_append(r_out, p_body.location);
					r_out += ",\"mutable_components\":[";
					for (std::size_t i = 0; i < p_body.mutable_components.size(); ++i) {
						if (i > 0) {
							r_out += ',';
						}
						json_snapshot_component_append(r_out, p_body.mutable_components[i]);
					}
					r_out += "],\"provided_containers\":[";
					for (std::size_t i = 0; i < p_body.provided_containers.size(); ++i) {
						if (i > 0) {
							r_out += ',';
						}
						json_u64_append(r_out, p_body.provided_containers[i]);
					}
					r_out += "],\"quantity\":";
					json_u64_append(r_out, p_body.quantity);
				} else if constexpr (std::is_same_v<T, ItemDestroyedOp>) {
					r_out += "\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::ITEM_DESTROYED));
				} else if constexpr (std::is_same_v<T, ItemMovedOp>) {
					r_out += "\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::ITEM_MOVED));
					r_out += ",\"location\":";
					json_location_append(r_out, p_body.location);
				} else if constexpr (std::is_same_v<T, ItemQuantityOp>) {
					r_out += "\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::ITEM_QUANTITY));
					r_out += ",\"quantity\":";
					json_u64_append(r_out, p_body.quantity);
				} else if constexpr (std::is_same_v<T, ItemComponentSetOp>) {
					r_out += "\"component\":";
					json_snapshot_component_append(r_out, p_body.component);
					r_out += ",\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::ITEM_COMPONENT_SET));
				} else if constexpr (std::is_same_v<T, ItemComponentRemovedOp>) {
					r_out += "\"component_identifier\":";
					json_escape_append(r_out, p_body.component_identifier);
					r_out += ",\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::ITEM_COMPONENT_REMOVED));
				} else if constexpr (std::is_same_v<T, ContainerAdoptedOp>) {
					r_out += "\"container\":";
					json_u64_append(r_out, p_body.container);
					r_out += ",\"container_definition_identifier\":";
					json_escape_append(r_out, p_body.container_definition_identifier);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::CONTAINER_ADOPTED));
					r_out += ",\"provider_item\":";
					json_u64_append(r_out, p_body.provider_item);
				} else if constexpr (std::is_same_v<T, ContainerReleasedOp>) {
					r_out += "\"container\":";
					json_u64_append(r_out, p_body.container);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::CONTAINER_RELEASED));
				} else if constexpr (std::is_same_v<T, ReferenceAssignedOp>) {
					r_out += "\"item\":";
					json_u64_append(r_out, p_body.item);
					r_out += ",\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::REFERENCE_ASSIGNED));
					r_out += ",\"reference\":";
					json_u64_append(r_out, p_body.reference);
				} else {
					static_assert(std::is_same_v<T, ReferenceClearedOp>, "unhandled DeltaOp alternative");
					r_out += "\"kind\":";
					r_out += std::to_string(static_cast<unsigned>(DeltaOpKind::REFERENCE_CLEARED));
					r_out += ",\"reference\":";
					json_u64_append(r_out, p_body.reference);
				}
				r_out += '}';
			},
			p_op);
}

void json_inventory_delta_append(std::string &r_out, const InventoryDelta &p_delta) {
	r_out += '{';
	r_out += "\"inventory\":";
	json_u64_append(r_out, p_delta.inventory.value);
	r_out += ",\"ops\":[";
	for (std::size_t i = 0; i < p_delta.ops.size(); ++i) {
		if (i > 0) {
			r_out += ',';
		}
		json_delta_op_append(r_out, p_delta.ops[i]);
	}
	r_out += "],\"predecessor_revision\":";
	json_u64_append(r_out, p_delta.predecessor_revision);
	r_out += ",\"successor_revision\":";
	json_u64_append(r_out, p_delta.successor_revision);
	r_out += '}';
}

void json_status_append(std::string &r_out, const Status &p_status) {
	r_out += '{';
	r_out += "\"code\":";
	r_out += std::to_string(static_cast<unsigned>(p_status.code));
	r_out += ",\"detail\":";
	json_u64_append(r_out, p_status.detail);
	r_out += ",\"diagnostic\":";
	r_out += std::to_string(static_cast<unsigned>(p_status.diagnostic));
	r_out += '}';
}

void json_revision_outcome_append(std::string &r_out, const RevisionOutcome &p_revision) {
	r_out += '{';
	r_out += "\"inventory\":";
	json_u64_append(r_out, p_revision.inventory.value);
	r_out += ",\"predecessor_revision\":";
	json_u64_append(r_out, p_revision.predecessor_revision);
	r_out += ",\"successor_revision\":";
	json_u64_append(r_out, p_revision.successor_revision);
	r_out += '}';
}

void json_transaction_event_append(std::string &r_out, const TransactionEvent &p_event) {
	r_out += '{';
	r_out += "\"destination_container\":";
	json_u64_append(r_out, p_event.destination_container.value);
	r_out += ",\"item\":";
	json_u64_append(r_out, p_event.item.value);
	r_out += ",\"kind\":";
	r_out += std::to_string(static_cast<unsigned>(p_event.kind));
	r_out += ",\"reference\":";
	json_u64_append(r_out, p_event.reference.value);
	r_out += ",\"secondary_item\":";
	json_u64_append(r_out, p_event.secondary_item.value);
	r_out += ",\"source_container\":";
	json_u64_append(r_out, p_event.source_container.value);
	r_out += '}';
}

void json_dropped_item_append(std::string &r_out, const DroppedItemValue &p_dropped) {
	r_out += '{';
	r_out += "\"external_owner\":";
	json_u64_append(r_out, p_dropped.external_owner.value);
	r_out += ",\"item_definition_identifier\":";
	json_escape_append(r_out, p_dropped.item_definition_identifier);
	r_out += ",\"mutable_components\":[";
	for (std::size_t i = 0; i < p_dropped.mutable_components.size(); ++i) {
		if (i > 0) {
			r_out += ',';
		}
		r_out += '{';
		r_out += "\"component_identifier\":";
		json_escape_append(r_out, p_dropped.mutable_components[i].component_identifier);
		r_out += ",\"payload\":";
		json_hex_append(r_out, p_dropped.mutable_components[i].payload);
		r_out += '}';
	}
	r_out += "],\"quantity\":";
	json_u64_append(r_out, p_dropped.quantity);
	r_out += '}';
}

} // namespace

Status encode_status(const Status &p_status, ByteWriter &p_writer) {
	return encode_status_wire(p_status, p_writer);
}

Status decode_status(ByteReader &p_reader, Status &r_out) {
	return decode_status_wire(p_reader, r_out);
}

// --- SessionHello ---------------------------------------------------------
//
// On-wire layout (fixed 2+8+8+8+8=34 bytes plus two length-prefixed
// strings):
//   protocol_version u16, mass_unit string, manifest_algorithm string,
//   manifest_fingerprint u64, required_feature_bits u64, hard_limit_digest
//   u64, identifier_dictionary_digest u64.

Status encode_session_hello(const SessionHello &p_hello, ByteWriter &p_writer) {
	p_writer.write_u16(p_hello.protocol_version);
	p_writer.write_string(p_hello.mass_unit, MAX_STRING_BYTES);
	p_writer.write_string(p_hello.manifest_algorithm, MAX_STRING_BYTES);
	p_writer.write_u64(p_hello.manifest_fingerprint);
	p_writer.write_u64(p_hello.required_feature_bits);
	p_writer.write_u64(p_hello.hard_limit_digest);
	p_writer.write_u64(p_hello.identifier_dictionary_digest);
	return p_writer.status();
}

Status decode_session_hello(ByteReader &p_reader, SessionHello &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	SessionHello candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.mass_unit, MAX_STRING_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.manifest_algorithm, MAX_STRING_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.manifest_fingerprint)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.required_feature_bits)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.hard_limit_digest)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.identifier_dictionary_digest)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- CommandEnvelope ----------------------------------------------------

Status encode_command_envelope(const CommandEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	Status status = encode_command_header(p_envelope.header, p_writer);
	if (!status.ok()) {
		return status;
	}
	commands_detail::encode_command(p_envelope.command, p_writer);
	return p_writer.status();
}

Status decode_command_envelope(ByteReader &p_reader, CommandEnvelope &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	CommandEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	Status status = decode_command_header(p_reader, candidate.header);
	if (!status.ok()) {
		return status;
	}
	status = decode_command(p_reader, candidate.command);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- ResultEnvelope -----------------------------------------------------

Status encode_result_envelope(const ResultEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	const TransactionResult &result = p_envelope.result;
	p_writer.write_bool(result.accepted);
	Status status = encode_status_wire(result.status, p_writer);
	if (!status.ok()) {
		return status;
	}
	p_writer.write_u64(result.command_id.value);
	p_writer.write_bool(result.queued);
	p_writer.write_bool(result.replayed);
	p_writer.write_count(result.revisions.size(), MAX_INVENTORIES_PER_TRANSACTION);
	for (const RevisionOutcome &revision : result.revisions) {
		p_writer.write_u64(revision.inventory.value);
		p_writer.write_u64(revision.predecessor_revision);
		p_writer.write_u64(revision.successor_revision);
	}
	p_writer.write_count(result.events.size(), MAX_SETTLEMENT_PLAN_ENTRIES);
	for (const TransactionEvent &event : result.events) {
		status = encode_transaction_event(event, p_writer);
		if (!status.ok()) {
			return status;
		}
	}
	p_writer.write_u64(result.new_item_id.value);
	p_writer.write_u64(result.new_reference_id.value);
	p_writer.write_u64(result.dropped_external_owner.value);
	p_writer.write_count(result.dropped_items.size(), MAX_ITEMS_PER_INVENTORY);
	for (const DroppedItemValue &dropped : result.dropped_items) {
		status = encode_dropped_item(dropped, p_writer);
		if (!status.ok()) {
			return status;
		}
	}
	p_writer.write_u64(result.transferred_quantity);
	p_writer.write_u64(result.remaining_quantity);
	p_writer.write_u64(result.conflicting_inventory.value);
	p_writer.write_u64(result.authoritative_revision);
	return p_writer.status();
}

Status decode_result_envelope(ByteReader &p_reader, ResultEnvelope &r_out) {
	if (p_reader.remaining() > MAX_RESULT_ENVELOPE_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	ResultEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	TransactionResult &result = candidate.result;
	if (!p_reader.read_bool(result.accepted)) {
		return p_reader.status();
	}
	Status status = decode_status_wire(p_reader, result.status);
	if (!status.ok()) {
		return status;
	}
	std::uint64_t command_id_raw = 0;
	if (!p_reader.read_u64(command_id_raw)) {
		return p_reader.status();
	}
	result.command_id = CommandId{ command_id_raw };
	if (!p_reader.read_bool(result.queued)) {
		return p_reader.status();
	}
	if (!p_reader.read_bool(result.replayed)) {
		return p_reader.status();
	}
	std::size_t revision_count = 0;
	if (!p_reader.read_count(revision_count, MAX_INVENTORIES_PER_TRANSACTION, /*p_min_bytes_per_entry=*/24)) {
		return p_reader.status();
	}
	result.revisions.reserve(revision_count);
	for (std::size_t i = 0; i < revision_count; ++i) {
		std::uint64_t inventory_raw = 0;
		std::uint64_t predecessor = 0;
		std::uint64_t successor = 0;
		if (!p_reader.read_u64(inventory_raw) || !p_reader.read_u64(predecessor) || !p_reader.read_u64(successor)) {
			return p_reader.status();
		}
		result.revisions.push_back(RevisionOutcome{ InventoryId{ inventory_raw }, predecessor, successor });
	}
	std::size_t event_count = 0;
	if (!p_reader.read_count(event_count, MAX_SETTLEMENT_PLAN_ENTRIES, /*p_min_bytes_per_entry=*/40)) {
		return p_reader.status();
	}
	result.events.reserve(event_count);
	for (std::size_t i = 0; i < event_count; ++i) {
		TransactionEvent event;
		status = decode_transaction_event(p_reader, event);
		if (!status.ok()) {
			return status;
		}
		result.events.push_back(event);
	}
	std::uint64_t new_item_raw = 0;
	if (!p_reader.read_u64(new_item_raw)) {
		return p_reader.status();
	}
	result.new_item_id = ItemInstanceId{ new_item_raw };
	std::uint64_t new_reference_raw = 0;
	if (!p_reader.read_u64(new_reference_raw)) {
		return p_reader.status();
	}
	result.new_reference_id = ReferenceId{ new_reference_raw };
	std::uint64_t dropped_owner_raw = 0;
	if (!p_reader.read_u64(dropped_owner_raw)) {
		return p_reader.status();
	}
	result.dropped_external_owner = ExternalOwnerId{ dropped_owner_raw };
	std::size_t dropped_count = 0;
	if (!p_reader.read_count(dropped_count, MAX_ITEMS_PER_INVENTORY, /*p_min_bytes_per_entry=*/24)) {
		return p_reader.status();
	}
	result.dropped_items.reserve(dropped_count);
	for (std::size_t i = 0; i < dropped_count; ++i) {
		DroppedItemValue dropped;
		status = decode_dropped_item(p_reader, dropped);
		if (!status.ok()) {
			return status;
		}
		result.dropped_items.push_back(std::move(dropped));
	}
	if (!p_reader.read_u64(result.transferred_quantity)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(result.remaining_quantity)) {
		return p_reader.status();
	}
	std::uint64_t conflicting_raw = 0;
	if (!p_reader.read_u64(conflicting_raw)) {
		return p_reader.status();
	}
	result.conflicting_inventory = InventoryId{ conflicting_raw };
	if (!p_reader.read_u64(result.authoritative_revision)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- DeltaBatch -----------------------------------------------------------

Status encode_delta_batch(const DeltaBatch &p_batch, ByteWriter &p_writer) {
	p_writer.write_u16(p_batch.protocol_version);
	p_writer.write_u64(p_batch.source_command_id.value);
	p_writer.write_count(p_batch.inventories.size(), MAX_INVENTORIES_PER_TRANSACTION);
	for (const InventoryDelta &delta : p_batch.inventories) {
		Status status = encode_inventory_delta(delta, p_writer);
		if (!status.ok()) {
			return status;
		}
	}
	return p_writer.status();
}

Status decode_delta_batch(ByteReader &p_reader, DeltaBatch &r_out) {
	if (p_reader.remaining() > MAX_DELTA_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	DeltaBatch candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	std::uint64_t command_id_raw = 0;
	if (!p_reader.read_u64(command_id_raw)) {
		return p_reader.status();
	}
	candidate.source_command_id = CommandId{ command_id_raw };
	std::size_t inventory_count = 0;
	if (!p_reader.read_count(inventory_count, MAX_INVENTORIES_PER_TRANSACTION, /*p_min_bytes_per_entry=*/28)) {
		return p_reader.status();
	}
	candidate.inventories.reserve(inventory_count);
	for (std::size_t i = 0; i < inventory_count; ++i) {
		InventoryDelta delta;
		Status status = decode_inventory_delta(p_reader, delta);
		if (!status.ok()) {
			return status;
		}
		candidate.inventories.push_back(std::move(delta));
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- SnapshotEnvelope -------------------------------------------------

Status encode_snapshot_envelope(const SnapshotEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	return encode_canonical(p_envelope.snapshot, p_writer);
}

Status decode_snapshot_envelope(ByteReader &p_reader, SnapshotEnvelope &r_out) {
	if (p_reader.remaining() > MAX_SNAPSHOT_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	SnapshotEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	Status status = decode_canonical(p_reader, candidate.snapshot);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- ResyncRequest ------------------------------------------------------

Status encode_resync_request(const ResyncRequest &p_request, ByteWriter &p_writer) {
	p_writer.write_u64(p_request.inventory.value);
	p_writer.write_u64(p_request.last_applied_revision);
	return p_writer.status();
}

Status decode_resync_request(ByteReader &p_reader, ResyncRequest &r_out) {
	ResyncRequest candidate;
	std::uint64_t inventory_raw = 0;
	if (!p_reader.read_u64(inventory_raw)) {
		return p_reader.status();
	}
	candidate.inventory = InventoryId{ inventory_raw };
	if (!p_reader.read_u64(candidate.last_applied_revision)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = candidate;
	return ok_status();
}

// --- PersistenceRecord --------------------------------------------------

namespace {

Status encode_persistence_record_body(const PersistenceRecord &p_record, ByteWriter &p_writer) {
	p_writer.write_u16(p_record.persistence_schema_version);
	p_writer.write_u8(p_record.api_version_major);
	p_writer.write_u8(p_record.api_version_minor);
	p_writer.write_u8(p_record.api_version_patch);
	p_writer.write_u16(p_record.protocol_version);
	p_writer.write_string(p_record.manifest_algorithm, MAX_STRING_BYTES);
	p_writer.write_u64(p_record.manifest_fingerprint);
	p_writer.write_string(p_record.profile_identifier, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_record.inventory.value);
	p_writer.write_u64(p_record.revision);
	p_writer.write_blob(p_record.canonical_snapshot_bytes, MAX_SNAPSHOT_BYTES);
	return p_writer.status();
}

} // namespace

std::uint64_t compute_persistence_record_hash(const PersistenceRecord &p_record) {
	ByteWriter writer(MAX_PERSISTENCE_RECORD_BYTES);
	Status status = encode_persistence_record_body(p_record, writer);
	if (!status.ok()) {
		return 0;
	}
	return hash_bytes(writer.bytes());
}

Status encode_persistence_record(const PersistenceRecord &p_record, ByteWriter &p_writer) {
	Status status = encode_persistence_record_body(p_record, p_writer);
	if (!status.ok()) {
		return status;
	}
	p_writer.write_u64(p_record.record_hash);
	return p_writer.status();
}

Status decode_persistence_record(ByteReader &p_reader, PersistenceRecord &r_out) {
	if (p_reader.remaining() > MAX_PERSISTENCE_RECORD_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	PersistenceRecord candidate;
	if (!p_reader.read_u16(candidate.persistence_schema_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_u8(candidate.api_version_major)) {
		return p_reader.status();
	}
	if (!p_reader.read_u8(candidate.api_version_minor)) {
		return p_reader.status();
	}
	if (!p_reader.read_u8(candidate.api_version_patch)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.manifest_algorithm, MAX_STRING_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.manifest_fingerprint)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.profile_identifier, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	std::uint64_t inventory_raw = 0;
	if (!p_reader.read_u64(inventory_raw)) {
		return p_reader.status();
	}
	candidate.inventory = InventoryId{ inventory_raw };
	if (!p_reader.read_u64(candidate.revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_blob(candidate.canonical_snapshot_bytes, MAX_SNAPSHOT_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.record_hash)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- Deterministic diagnostic JSON ---------------------------------------

std::string to_diagnostic_json(const SessionHello &p_hello) {
	std::string out;
	out += '{';
	out += "\"hard_limit_digest\":";
	json_u64_append(out, p_hello.hard_limit_digest);
	out += ",\"identifier_dictionary_digest\":";
	json_u64_append(out, p_hello.identifier_dictionary_digest);
	out += ",\"manifest_algorithm\":";
	json_escape_append(out, p_hello.manifest_algorithm);
	out += ",\"manifest_fingerprint\":";
	json_u64_append(out, p_hello.manifest_fingerprint);
	out += ",\"mass_unit\":";
	json_escape_append(out, p_hello.mass_unit);
	out += ",\"protocol_version\":";
	out += std::to_string(p_hello.protocol_version);
	out += ",\"required_feature_bits\":";
	json_u64_append(out, p_hello.required_feature_bits);
	out += '}';
	return out;
}

std::string to_diagnostic_json(const ResultEnvelope &p_envelope) {
	const TransactionResult &result = p_envelope.result;
	std::string out;
	out += '{';
	out += "\"accepted\":";
	json_bool_append(out, result.accepted);
	out += ",\"authoritative_revision\":";
	json_u64_append(out, result.authoritative_revision);
	out += ",\"command_id\":";
	json_u64_append(out, result.command_id.value);
	out += ",\"conflicting_inventory\":";
	json_u64_append(out, result.conflicting_inventory.value);
	out += ",\"dropped_external_owner\":";
	json_u64_append(out, result.dropped_external_owner.value);
	out += ",\"dropped_items\":[";
	for (std::size_t i = 0; i < result.dropped_items.size(); ++i) {
		if (i > 0) {
			out += ',';
		}
		json_dropped_item_append(out, result.dropped_items[i]);
	}
	out += "],\"events\":[";
	for (std::size_t i = 0; i < result.events.size(); ++i) {
		if (i > 0) {
			out += ',';
		}
		json_transaction_event_append(out, result.events[i]);
	}
	out += "],\"new_item_id\":";
	json_u64_append(out, result.new_item_id.value);
	out += ",\"new_reference_id\":";
	json_u64_append(out, result.new_reference_id.value);
	out += ",\"protocol_version\":";
	out += std::to_string(p_envelope.protocol_version);
	out += ",\"queued\":";
	json_bool_append(out, result.queued);
	out += ",\"remaining_quantity\":";
	json_u64_append(out, result.remaining_quantity);
	out += ",\"replayed\":";
	json_bool_append(out, result.replayed);
	out += ",\"revisions\":[";
	for (std::size_t i = 0; i < result.revisions.size(); ++i) {
		if (i > 0) {
			out += ',';
		}
		json_revision_outcome_append(out, result.revisions[i]);
	}
	out += "],\"status\":";
	json_status_append(out, result.status);
	out += ",\"transferred_quantity\":";
	json_u64_append(out, result.transferred_quantity);
	out += '}';
	return out;
}

std::string to_diagnostic_json(const DeltaBatch &p_batch) {
	std::string out;
	out += '{';
	out += "\"inventories\":[";
	for (std::size_t i = 0; i < p_batch.inventories.size(); ++i) {
		if (i > 0) {
			out += ',';
		}
		json_inventory_delta_append(out, p_batch.inventories[i]);
	}
	out += "],\"protocol_version\":";
	out += std::to_string(p_batch.protocol_version);
	out += ",\"source_command_id\":";
	json_u64_append(out, p_batch.source_command_id.value);
	out += '}';
	return out;
}

} // namespace inv::protocol
