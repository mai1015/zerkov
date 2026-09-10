#include "protocol/inv_discovery_protocol.h"

#include "core/inv_limits.h"

#include <limits>
#include <utility>
#include <vector>

namespace inv::protocol {

namespace {

Status fail_trailing(const ByteReader &p_reader) {
	return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRAILING_PAYLOAD_BYTES, p_reader.remaining());
}

Status validate_versions(std::uint16_t p_protocol, std::uint16_t p_discovery) {
	if (p_protocol != PROTOCOL_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_protocol);
	}
	if (p_discovery != DISCOVERY_PROTOCOL_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_discovery);
	}
	return ok_status();
}

bool valid_status_code(std::uint16_t p_raw) {
	switch (static_cast<StatusCode>(p_raw)) {
		case StatusCode::OK:
		case StatusCode::INVALID_ARGUMENT:
		case StatusCode::NOT_FOUND:
		case StatusCode::ALREADY_EXISTS:
		case StatusCode::OUT_OF_BOUNDS:
		case StatusCode::ARITHMETIC_ERROR:
		case StatusCode::LIMIT_EXCEEDED:
		case StatusCode::NOT_SUPPORTED:
		case StatusCode::INTERNAL_ERROR:
		case StatusCode::INVALID_IDENTIFIER:
		case StatusCode::DUPLICATE_DEFINITION:
		case StatusCode::UNKNOWN_DEFINITION:
		case StatusCode::INVALID_REFERENCE:
		case StatusCode::CATALOG_SEALED:
		case StatusCode::CATALOG_NOT_SEALED:
		case StatusCode::HASH_COLLISION:
		case StatusCode::DEPENDENCY_MISSING:
		case StatusCode::DEPENDENCY_CYCLE:
		case StatusCode::INCOMPATIBLE_DEFINITION:
		case StatusCode::MANIFEST_MISMATCH:
		case StatusCode::PROTOCOL_MISMATCH:
		case StatusCode::SCHEMA_MISMATCH:
		case StatusCode::FEATURE_UNSUPPORTED:
		case StatusCode::ENCODE_FAILED:
		case StatusCode::DECODE_FAILED:
		case StatusCode::PAYLOAD_TOO_LARGE:
		case StatusCode::REVISION_MISMATCH:
		case StatusCode::DUPLICATE_COMMAND:
		case StatusCode::PERMISSION_DENIED:
		case StatusCode::ROLE_VIOLATION:
		case StatusCode::INVARIANT_VIOLATION:
		case StatusCode::COMMAND_REJECTED:
		case StatusCode::SNAPSHOT_REQUIRED:
		case StatusCode::SESSION_NOT_READY:
		case StatusCode::RATE_LIMITED:
			return true;
	}
	return false;
}

bool valid_diagnostic(std::uint16_t p_raw) {
	return p_raw == 0 ||
			(p_raw >= 1 && p_raw <= 6) ||
			(p_raw >= 20 && p_raw <= 31) ||
			(p_raw >= 40 && p_raw <= 46) ||
			(p_raw >= 60 && p_raw <= 76) ||
			(p_raw >= 90 && p_raw <= 93) ||
			(p_raw >= 110 && p_raw <= 191);
}

Status validate_view_shape(const DiscoveryView &p_view) {
	if (p_view.projected_snapshot.visibility == VisibilityScope::OWNER ||
			p_view.projected_snapshot.revision != p_view.inventory_revision ||
			p_view.projected_snapshot.container_allocator_next != 0 ||
			p_view.projected_snapshot.item_allocator_next != 0 ||
			p_view.projected_snapshot.reference_allocator_next != 0) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED);
	}
	for (const DiscoveryContainerView &container : p_view.containers) {
		if (container.stage == DiscoveryContainerStage::INDEXED) {
			if (container.token != 0 || container.container_id == 0 || !container.layout_revealed) {
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_TOKEN_INVALID);
			}
		} else if (container.token == 0 || container.container_id != 0 ||
				container.layout_revealed || container.item_count != 0 ||
				!container.entries.empty()) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_QUERY_REDACTED);
		}
		for (const DiscoveryEntryView &entry : container.entries) {
			if (entry.token == 0 ||
					(entry.stage == DiscoveryEntryStage::UNKNOWN &&
							(entry.elapsed_ms != 0 || entry.duration_ms != 0))) {
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_TOKEN_INVALID);
			}
		}
	}
	if ((!p_view.task.actor_busy && p_view.task.kind != DiscoveryTaskKind::NONE) ||
			(p_view.task.kind == DiscoveryTaskKind::NONE &&
					(p_view.task.target_token != 0 || p_view.task.elapsed_ms != 0 || p_view.task.duration_ms != 0)) ||
			(p_view.task.kind != DiscoveryTaskKind::NONE &&
					(!p_view.task.actor_busy || p_view.task.target_token == 0))) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_TASK_NOT_FOUND);
	}
	return ok_status();
}

Status encode_view_body(const DiscoveryView &p_view, ByteWriter &p_writer) {
	p_writer.write_u64(p_view.inventory_revision);
	p_writer.write_u64(p_view.discovery_revision);

	ByteWriter snapshot_writer(MAX_SNAPSHOT_BYTES);
	Status snapshot_status = encode_canonical(p_view.projected_snapshot, snapshot_writer);
	if (!snapshot_status.ok()) {
		return snapshot_status;
	}
	p_writer.write_blob(snapshot_writer.bytes(), MAX_SNAPSHOT_BYTES);

	p_writer.write_count(p_view.containers.size(), MAX_DISCOVERY_INDEXED_CONTAINERS);
	std::size_t total_entries = 0;
	for (const DiscoveryContainerView &container : p_view.containers) {
		p_writer.write_u64(container.token);
		p_writer.write_u64(container.container_id);
		p_writer.write_u64(container.provider_item_id);
		p_writer.write_u8(static_cast<std::uint8_t>(container.stage));
		p_writer.write_string(container.shell_label);
		p_writer.write_u32(container.elapsed_ms);
		p_writer.write_u32(container.duration_ms);
		p_writer.write_bool(container.layout_revealed);
		p_writer.write_u8(static_cast<std::uint8_t>(container.layout_kind));
		p_writer.write_u32(container.width);
		p_writer.write_u32(container.height);
		p_writer.write_u32(container.capacity);
		p_writer.write_u32(container.item_count);
		if (container.entries.size() > MAX_DISCOVERY_REVEALED_ITEMS - total_entries) {
			return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
		}
		total_entries += container.entries.size();
		p_writer.write_count(container.entries.size(), MAX_DISCOVERY_REVEALED_ITEMS);
		for (const DiscoveryEntryView &entry : container.entries) {
			p_writer.write_u64(entry.token);
			p_writer.write_u8(static_cast<std::uint8_t>(entry.stage));
			p_writer.write_u32(entry.elapsed_ms);
			p_writer.write_u32(entry.duration_ms);
		}
	}
	p_writer.write_bool(p_view.task.actor_busy);
	p_writer.write_u8(static_cast<std::uint8_t>(p_view.task.kind));
	p_writer.write_u64(p_view.task.target_token);
	p_writer.write_u32(p_view.task.elapsed_ms);
	p_writer.write_u32(p_view.task.duration_ms);
	return p_writer.status();
}

Status decode_view_body(ByteReader &p_reader, DiscoveryView &r_view) {
	DiscoveryView result;
	if (!p_reader.read_u64(result.inventory_revision) ||
			!p_reader.read_u64(result.discovery_revision)) {
		return p_reader.status();
	}
	std::vector<std::uint8_t> snapshot_bytes;
	if (!p_reader.read_blob(snapshot_bytes, MAX_SNAPSHOT_BYTES)) {
		return p_reader.status();
	}
	ByteReader snapshot_reader(snapshot_bytes);
	Status snapshot_status = decode_canonical(snapshot_reader, result.projected_snapshot);
	if (!snapshot_status.ok()) {
		return snapshot_status;
	}
	if (!snapshot_reader.at_end()) {
		return fail_trailing(snapshot_reader);
	}

	std::size_t container_count = 0;
	if (!p_reader.read_count(container_count, MAX_DISCOVERY_INDEXED_CONTAINERS, 62)) {
		return p_reader.status();
	}
	result.containers.reserve(container_count);
	std::size_t total_entries = 0;
	for (std::size_t i = 0; i < container_count; ++i) {
		DiscoveryContainerView container;
		std::uint8_t stage = 0;
		std::uint8_t layout = 0;
		if (!p_reader.read_u64(container.token) ||
				!p_reader.read_u64(container.container_id) ||
				!p_reader.read_u64(container.provider_item_id) ||
				!p_reader.read_u8(stage) ||
				!p_reader.read_string(container.shell_label) ||
				!p_reader.read_u32(container.elapsed_ms) ||
				!p_reader.read_u32(container.duration_ms) ||
				!p_reader.read_bool(container.layout_revealed) ||
				!p_reader.read_u8(layout) ||
				!p_reader.read_u32(container.width) ||
				!p_reader.read_u32(container.height) ||
				!p_reader.read_u32(container.capacity) ||
				!p_reader.read_u32(container.item_count)) {
			return p_reader.status();
		}
		if (stage < static_cast<std::uint8_t>(DiscoveryContainerStage::UNSEARCHED) ||
				stage > static_cast<std::uint8_t>(DiscoveryContainerStage::INDEXED) ||
				layout < static_cast<std::uint8_t>(OwnershipLayoutKind::SPATIAL_GRID) ||
				layout > static_cast<std::uint8_t>(OwnershipLayoutKind::ORDERED_LIST)) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM);
		}
		container.stage = static_cast<DiscoveryContainerStage>(stage);
		container.layout_kind = static_cast<OwnershipLayoutKind>(layout);

		std::size_t entry_count = 0;
		if (!p_reader.read_count(entry_count, MAX_DISCOVERY_REVEALED_ITEMS, 17) ||
				entry_count > MAX_DISCOVERY_REVEALED_ITEMS - total_entries) {
			return make_status(StatusCode::DECODE_FAILED, DiagnosticId::COUNT_LIMIT_EXCEEDED);
		}
		total_entries += entry_count;
		container.entries.reserve(entry_count);
		for (std::size_t entry_index = 0; entry_index < entry_count; ++entry_index) {
			DiscoveryEntryView entry;
			std::uint8_t entry_stage = 0;
			if (!p_reader.read_u64(entry.token) ||
					!p_reader.read_u8(entry_stage) ||
					!p_reader.read_u32(entry.elapsed_ms) ||
					!p_reader.read_u32(entry.duration_ms)) {
				return p_reader.status();
			}
			if (entry_stage < static_cast<std::uint8_t>(DiscoveryEntryStage::UNKNOWN) ||
					entry_stage > static_cast<std::uint8_t>(DiscoveryEntryStage::SCANNING)) {
				return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM);
			}
			entry.stage = static_cast<DiscoveryEntryStage>(entry_stage);
			container.entries.push_back(entry);
		}
		result.containers.push_back(std::move(container));
	}

	std::uint8_t task_kind = 0;
	if (!p_reader.read_bool(result.task.actor_busy) ||
			!p_reader.read_u8(task_kind) ||
			!p_reader.read_u64(result.task.target_token) ||
			!p_reader.read_u32(result.task.elapsed_ms) ||
			!p_reader.read_u32(result.task.duration_ms)) {
		return p_reader.status();
	}
	if (task_kind > static_cast<std::uint8_t>(DiscoveryTaskKind::ITEM_SCAN)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM);
	}
	result.task.kind = static_cast<DiscoveryTaskKind>(task_kind);
	Status shape_status = validate_view_shape(result);
	if (!shape_status.ok()) {
		return shape_status;
	}
	r_view = std::move(result);
	return ok_status();
}

} // namespace

Status check_discovery_compatibility(const DiscoveryHello &p_local, const DiscoveryHello &p_remote) {
	if (!p_local.supported || !p_remote.supported) {
		return make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::FEATURE_SET_UNSUPPORTED);
	}
	if (p_local.version != p_remote.version ||
			p_local.version != DISCOVERY_PROTOCOL_VERSION) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_remote.version);
	}
	return ok_status();
}

DiscoveryResultEnvelope make_discovery_result_envelope(
		std::uint64_t p_request_id,
		const DiscoveryIntentResult &p_result) {
	DiscoveryResultEnvelope result;
	result.request_id = p_request_id;
	result.status = p_result.status;
	result.accepted = p_result.accepted;
	result.replayed = p_result.replayed;
	result.completed = p_result.completed;
	result.inventory_revision = p_result.inventory_revision;
	result.discovery_revision = p_result.discovery_revision;
	result.task_kind = p_result.task.kind;
	result.elapsed_ms = p_result.task.elapsed_ms;
	result.duration_ms = p_result.task.duration_ms;
	return result;
}

Status encode_discovery_hello(const DiscoveryHello &p_hello, ByteWriter &p_writer) {
	p_writer.write_u16(p_hello.version);
	p_writer.write_bool(p_hello.supported);
	return p_writer.status();
}

Status decode_discovery_hello(ByteReader &p_reader, DiscoveryHello &r_out) {
	if (p_reader.remaining() > 3) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_reader.remaining());
	}
	DiscoveryHello result;
	if (!p_reader.read_u16(result.version) || !p_reader.read_bool(result.supported)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = result;
	return ok_status();
}

Status encode_discovery_intent(const DiscoveryIntentEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	p_writer.write_u16(p_envelope.discovery_protocol_version);
	p_writer.write_u8(static_cast<std::uint8_t>(p_envelope.kind));
	p_writer.write_u64(p_envelope.header.recipient.session_id);
	p_writer.write_u64(p_envelope.header.recipient.actor_id);
	p_writer.write_u64(p_envelope.header.request_id);
	p_writer.write_u64(p_envelope.header.inventory.value);
	p_writer.write_u64(p_envelope.header.expected_inventory_revision);
	p_writer.write_u64(p_envelope.header.expected_discovery_revision);
	p_writer.write_u64(p_envelope.target_token);
	return p_writer.status();
}

Status decode_discovery_intent(ByteReader &p_reader, DiscoveryIntentEnvelope &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_reader.remaining());
	}
	DiscoveryIntentEnvelope result;
	std::uint8_t kind = 0;
	if (!p_reader.read_u16(result.protocol_version) ||
			!p_reader.read_u16(result.discovery_protocol_version) ||
			!p_reader.read_u8(kind) ||
			!p_reader.read_u64(result.header.recipient.session_id) ||
			!p_reader.read_u64(result.header.recipient.actor_id) ||
			!p_reader.read_u64(result.header.request_id) ||
			!p_reader.read_u64(result.header.inventory.value) ||
			!p_reader.read_u64(result.header.expected_inventory_revision) ||
			!p_reader.read_u64(result.header.expected_discovery_revision) ||
			!p_reader.read_u64(result.target_token)) {
		return p_reader.status();
	}
	if (kind < static_cast<std::uint8_t>(DiscoveryIntentKind::BEGIN_CONTAINER_SEARCH) ||
			kind > static_cast<std::uint8_t>(DiscoveryIntentKind::CANCEL)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM);
	}
	result.kind = static_cast<DiscoveryIntentKind>(kind);
	if ((result.kind == DiscoveryIntentKind::CANCEL) != (result.target_token == 0)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::DISCOVERY_TOKEN_INVALID);
	}
	Status version_status = validate_versions(result.protocol_version, result.discovery_protocol_version);
	if (!version_status.ok()) {
		return version_status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = result;
	return ok_status();
}

Status encode_discovery_result(const DiscoveryResultEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	p_writer.write_u16(p_envelope.discovery_protocol_version);
	p_writer.write_u64(p_envelope.request_id);
	p_writer.write_u16(static_cast<std::uint16_t>(p_envelope.status.code));
	p_writer.write_u16(static_cast<std::uint16_t>(p_envelope.status.diagnostic));
	p_writer.write_u64(p_envelope.status.detail);
	p_writer.write_bool(p_envelope.accepted);
	p_writer.write_bool(p_envelope.replayed);
	p_writer.write_bool(p_envelope.completed);
	p_writer.write_u64(p_envelope.inventory_revision);
	p_writer.write_u64(p_envelope.discovery_revision);
	p_writer.write_u8(static_cast<std::uint8_t>(p_envelope.task_kind));
	p_writer.write_u32(p_envelope.elapsed_ms);
	p_writer.write_u32(p_envelope.duration_ms);
	return p_writer.status();
}

Status decode_discovery_result(ByteReader &p_reader, DiscoveryResultEnvelope &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_reader.remaining());
	}
	DiscoveryResultEnvelope result;
	std::uint16_t status_code = 0;
	std::uint16_t diagnostic = 0;
	std::uint8_t task_kind = 0;
	if (!p_reader.read_u16(result.protocol_version) ||
			!p_reader.read_u16(result.discovery_protocol_version) ||
			!p_reader.read_u64(result.request_id) ||
			!p_reader.read_u16(status_code) ||
			!p_reader.read_u16(diagnostic) ||
			!p_reader.read_u64(result.status.detail) ||
			!p_reader.read_bool(result.accepted) ||
			!p_reader.read_bool(result.replayed) ||
			!p_reader.read_bool(result.completed) ||
			!p_reader.read_u64(result.inventory_revision) ||
			!p_reader.read_u64(result.discovery_revision) ||
			!p_reader.read_u8(task_kind) ||
			!p_reader.read_u32(result.elapsed_ms) ||
			!p_reader.read_u32(result.duration_ms)) {
		return p_reader.status();
	}
	if (!valid_status_code(status_code) ||
			!valid_diagnostic(diagnostic) ||
			task_kind > static_cast<std::uint8_t>(DiscoveryTaskKind::ITEM_SCAN)) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::INVALID_ENUM);
	}
	result.status.code = static_cast<StatusCode>(status_code);
	result.status.diagnostic = static_cast<DiagnosticId>(diagnostic);
	result.task_kind = static_cast<DiscoveryTaskKind>(task_kind);
	Status version_status = validate_versions(result.protocol_version, result.discovery_protocol_version);
	if (!version_status.ok()) {
		return version_status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = result;
	return ok_status();
}

Status encode_discovery_view(const DiscoveryViewEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	p_writer.write_u16(p_envelope.discovery_protocol_version);
	p_writer.write_u64(p_envelope.inventory.value);
	Status status = encode_view_body(p_envelope.view, p_writer);
	return status.ok() ? p_writer.status() : status;
}

Status decode_discovery_view(ByteReader &p_reader, DiscoveryViewEnvelope &r_out) {
	if (p_reader.remaining() > MAX_DISCOVERY_VIEW_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_reader.remaining());
	}
	DiscoveryViewEnvelope result;
	if (!p_reader.read_u16(result.protocol_version) ||
			!p_reader.read_u16(result.discovery_protocol_version) ||
			!p_reader.read_u64(result.inventory.value)) {
		return p_reader.status();
	}
	Status version_status = validate_versions(result.protocol_version, result.discovery_protocol_version);
	if (!version_status.ok()) {
		return version_status;
	}
	Status view_status = decode_view_body(p_reader, result.view);
	if (!view_status.ok()) {
		return view_status;
	}
	if (result.inventory.value == 0 ||
			result.view.projected_snapshot.inventory_id != result.inventory.value) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::PERSISTENCE_RECORD_IDENTITY_MISMATCH);
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(result);
	return ok_status();
}

Status encode_discovery_delta(const DiscoveryDeltaEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	p_writer.write_u16(p_envelope.discovery_protocol_version);
	p_writer.write_u64(p_envelope.inventory.value);
	p_writer.write_u64(p_envelope.delta.predecessor_inventory_revision);
	p_writer.write_u64(p_envelope.delta.successor_inventory_revision);
	p_writer.write_u64(p_envelope.delta.predecessor_discovery_revision);
	p_writer.write_u64(p_envelope.delta.successor_discovery_revision);
	Status status = encode_view_body(p_envelope.delta.view, p_writer);
	return status.ok() ? p_writer.status() : status;
}

Status decode_discovery_delta(ByteReader &p_reader, DiscoveryDeltaEnvelope &r_out) {
	if (p_reader.remaining() > MAX_DISCOVERY_DELTA_BYTES) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_reader.remaining());
	}
	DiscoveryDeltaEnvelope result;
	if (!p_reader.read_u16(result.protocol_version) ||
			!p_reader.read_u16(result.discovery_protocol_version) ||
			!p_reader.read_u64(result.inventory.value) ||
			!p_reader.read_u64(result.delta.predecessor_inventory_revision) ||
			!p_reader.read_u64(result.delta.successor_inventory_revision) ||
			!p_reader.read_u64(result.delta.predecessor_discovery_revision) ||
			!p_reader.read_u64(result.delta.successor_discovery_revision)) {
		return p_reader.status();
	}
	Status version_status = validate_versions(result.protocol_version, result.discovery_protocol_version);
	if (!version_status.ok()) {
		return version_status;
	}
	Status view_status = decode_view_body(p_reader, result.delta.view);
	if (!view_status.ok()) {
		return view_status;
	}
	if (result.inventory.value == 0 ||
			result.delta.view.projected_snapshot.inventory_id != result.inventory.value ||
			result.delta.successor_inventory_revision != result.delta.view.inventory_revision ||
			result.delta.successor_discovery_revision != result.delta.view.discovery_revision) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::PERSISTENCE_RECORD_IDENTITY_MISMATCH);
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(result);
	return ok_status();
}

Status DiscoveryReplica::validate_envelope_view(InventoryId p_inventory, const DiscoveryView &p_view) {
	if (!p_inventory ||
			p_view.projected_snapshot.inventory_id != p_inventory.value ||
			p_view.projected_snapshot.revision != p_view.inventory_revision ||
			p_view.projected_snapshot.visibility == VisibilityScope::OWNER) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::PERSISTENCE_RECORD_IDENTITY_MISMATCH);
	}
	return ok_status();
}

Status DiscoveryReplica::apply_view(const DiscoveryViewEnvelope &p_envelope) {
	Status version_status = validate_versions(p_envelope.protocol_version, p_envelope.discovery_protocol_version);
	if (!version_status.ok()) {
		return version_status;
	}
	Status view_status = validate_envelope_view(p_envelope.inventory, p_envelope.view);
	if (!view_status.ok()) {
		return view_status;
	}
	inventory_ = p_envelope.inventory;
	view_ = p_envelope.view;
	initialized_ = true;
	needs_resync_ = false;
	return ok_status();
}

Status DiscoveryReplica::apply_delta(const DiscoveryDeltaEnvelope &p_envelope) {
	Status version_status = validate_versions(p_envelope.protocol_version, p_envelope.discovery_protocol_version);
	if (!version_status.ok()) {
		return version_status;
	}
	if (!initialized_ || p_envelope.inventory != inventory_ || needs_resync_) {
		needs_resync_ = true;
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP);
	}
	const DiscoveryViewDelta &delta = p_envelope.delta;
	if (delta.successor_inventory_revision <= view_.inventory_revision &&
			delta.successor_discovery_revision <= view_.discovery_revision) {
		return make_status(StatusCode::OK, DiagnosticId::REPLICA_DUPLICATE_DELTA);
	}
	if (delta.predecessor_inventory_revision != view_.inventory_revision ||
			delta.predecessor_discovery_revision != view_.discovery_revision) {
		needs_resync_ = true;
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_REVISION_GAP);
	}
	Status view_status = validate_envelope_view(p_envelope.inventory, delta.view);
	if (!view_status.ok() ||
			delta.successor_inventory_revision != delta.view.inventory_revision ||
			delta.successor_discovery_revision != delta.view.discovery_revision) {
		needs_resync_ = true;
		return make_status(StatusCode::SNAPSHOT_REQUIRED, DiagnosticId::REPLICA_IMPOSSIBLE_TRANSITION);
	}
	view_ = delta.view;
	needs_resync_ = false;
	return ok_status();
}

} // namespace inv::protocol
