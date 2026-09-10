#include "protocol/inv_observer_protocol.h"

#include "core/inv_identifier.h"
#include "core/inv_limits.h"
#include "core/inv_snapshot.h"
#include "protocol/inv_visibility.h"

#include <utility>
#include <vector>
#include <limits>

namespace inv::protocol {

namespace {

Status fail_trailing(const ByteReader &p_reader) {
	return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRAILING_PAYLOAD_BYTES, p_reader.remaining());
}

Status fail_too_large(std::size_t p_remaining) {
	return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_remaining);
}


Status validate_protocol(
		std::uint16_t p_protocol,
		const std::string &p_magic,
		const std::string &p_manifest_algorithm) {
	if (p_protocol != OBSERVER_PROTOCOL_VERSION || p_magic != OBSERVER_PROTOCOL_MAGIC) {
		return make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_protocol);
	}
	if (p_manifest_algorithm != MANIFEST_ALGORITHM) {
		return make_status(StatusCode::MANIFEST_MISMATCH, DiagnosticId::SESSION_MANIFEST_ALGORITHM_MISMATCH);
	}
	return ok_status();
}

Status validate_recipient(const DiscoveryRecipientKey &p_recipient) {
	if (p_recipient.session_id == 0 || p_recipient.actor_id == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	return ok_status();
}

Status encode_view_body(const ObserverSnapshot &p_snapshot, ByteWriter &p_writer) {
	p_writer.write_u64(p_snapshot.inventory_id);
	p_writer.write_u8(static_cast<std::uint8_t>(p_snapshot.visibility));
	p_writer.write_u64(p_snapshot.generation);
	p_writer.write_u64(p_snapshot.sequence);
	p_writer.write_u64(p_snapshot.manifest_fingerprint);
	p_writer.write_count(p_snapshot.containers.size(), MAX_CONTAINERS_PER_INVENTORY);
	for (const ObserverContainerView &container : p_snapshot.containers) {
		p_writer.write_u64(container.id);
		p_writer.write_string(container.definition_identifier, MAX_IDENTIFIER_BYTES);
		p_writer.write_u64(container.provider_item);
		p_writer.write_u32(container.item_count);
		p_writer.write_bool(container.aggregate_only);
	}
	p_writer.write_count(p_snapshot.items.size(), MAX_ITEMS_PER_INVENTORY);
	for (const ObserverItemView &item : p_snapshot.items) {
		p_writer.write_u64(item.id);
		p_writer.write_string(item.item_definition_identifier, MAX_IDENTIFIER_BYTES);
		p_writer.write_u64(item.quantity);
		Status location_status = encode_snapshot_location(item.location, p_writer);
		if (!location_status.ok()) {
			return location_status;
		}
		p_writer.write_count(item.mutable_components.size(), MAX_MUTABLE_COMPONENTS_PER_ITEM);
		for (const SnapshotMutableComponent &component : item.mutable_components) {
			p_writer.write_string(component.component_identifier, MAX_IDENTIFIER_BYTES);
			p_writer.write_blob(component.payload, MAX_TRAIT_PAYLOAD_BYTES);
		}
		p_writer.write_count(item.provided_containers.size(), MAX_ITEM_PROVIDED_CONTAINERS);
		for (std::uint64_t provided : item.provided_containers) {
			p_writer.write_u64(provided);
		}
	}
	return p_writer.status();
}

Status decode_view_body(ByteReader &p_reader, ObserverSnapshot &r_snapshot) {
	ObserverSnapshot candidate;
	std::uint8_t visibility_raw = 0;
	if (!p_reader.read_u64(candidate.inventory_id) ||
			!p_reader.read_u8(visibility_raw) ||
			!p_reader.read_u64(candidate.generation) ||
			!p_reader.read_u64(candidate.sequence) ||
			!p_reader.read_u64(candidate.manifest_fingerprint)) {
		return p_reader.status();
	}
	if (visibility_raw > static_cast<std::uint8_t>(VisibilityScope::REDACTED)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	candidate.visibility = static_cast<VisibilityScope>(visibility_raw);
	std::size_t container_count = 0;
	// The fixed-width minimum is 8-byte id + 4-byte string length +
	// 8-byte provider + 4-byte item count + 1-byte aggregate flag.  Do not
	// include the identifier bytes themselves: a valid namespaced identifier
	// may be shorter than the old 29-byte hint, and a false lower bound would
	// reject a bounded packet before its strings are decoded.
	if (!p_reader.read_count(container_count, MAX_CONTAINERS_PER_INVENTORY, 25)) {
		return p_reader.status();
	}
	candidate.containers.reserve(container_count);
	for (std::size_t i = 0; i < container_count; ++i) {
		ObserverContainerView container;
		if (!p_reader.read_u64(container.id) ||
				!p_reader.read_string(container.definition_identifier, MAX_IDENTIFIER_BYTES) ||
				!p_reader.read_u64(container.provider_item) ||
				!p_reader.read_u32(container.item_count) ||
				!p_reader.read_bool(container.aggregate_only)) {
			return p_reader.status();
		}
		candidate.containers.push_back(std::move(container));
	}
	std::size_t item_count = 0;
	// The shortest location is SLOT/LIST (13 bytes including kind and
	// container), followed by the two mandatory zero-length collection counts;
	// with id/definition-length/quantity this is 41 bytes.  Spatial entries
	// are larger, so the lower bound remains safe for every location kind.
	if (!p_reader.read_count(item_count, MAX_ITEMS_PER_INVENTORY, 41)) {
		return p_reader.status();
	}
	candidate.items.reserve(item_count);
	for (std::size_t i = 0; i < item_count; ++i) {
		ObserverItemView item;
		if (!p_reader.read_u64(item.id) ||
				!p_reader.read_string(item.item_definition_identifier, MAX_IDENTIFIER_BYTES) ||
				!p_reader.read_u64(item.quantity)) {
			return p_reader.status();
		}
		Status location_status = decode_snapshot_location(p_reader, item.location);
		if (!location_status.ok()) {
			return location_status;
		}
		std::size_t component_count = 0;
		if (!p_reader.read_count(component_count, MAX_MUTABLE_COMPONENTS_PER_ITEM, 8)) {
			return p_reader.status();
		}
		item.mutable_components.reserve(component_count);
		for (std::size_t c = 0; c < component_count; ++c) {
			SnapshotMutableComponent component;
			if (!p_reader.read_string(component.component_identifier, MAX_IDENTIFIER_BYTES) ||
					!p_reader.read_blob(component.payload, MAX_TRAIT_PAYLOAD_BYTES)) {
				return p_reader.status();
			}
			item.mutable_components.push_back(std::move(component));
		}
		std::size_t provided_count = 0;
		if (!p_reader.read_count(provided_count, MAX_ITEM_PROVIDED_CONTAINERS, 8)) {
			return p_reader.status();
		}
		item.provided_containers.reserve(provided_count);
		for (std::size_t c = 0; c < provided_count; ++c) {
			std::uint64_t provided = 0;
			if (!p_reader.read_u64(provided)) {
				return p_reader.status();
			}
			item.provided_containers.push_back(provided);
		}
		candidate.items.push_back(std::move(item));
	}
	Status view_status = validate_observer_snapshot(candidate);
	if (!view_status.ok()) {
		return view_status;
	}
	r_snapshot = std::move(candidate);
	return ok_status();
}

} // namespace

Status encode_observer_snapshot(const ObserverSnapshotEnvelope &p_envelope, ByteWriter &p_writer) {
	Status status = validate_protocol(p_envelope.protocol_version, p_envelope.protocol_magic, p_envelope.manifest_algorithm);
	if (!status.ok()) return status;
	status = validate_recipient(p_envelope.recipient);
	if (!status.ok()) return status;
	status = validate_observer_snapshot(p_envelope.snapshot);
	if (!status.ok()) return status;
	p_writer.write_u16(p_envelope.protocol_version);
	p_writer.write_string(p_envelope.protocol_magic, MAX_STRING_BYTES);
	p_writer.write_u64(p_envelope.recipient.session_id);
	p_writer.write_u64(p_envelope.recipient.actor_id);
	p_writer.write_string(p_envelope.manifest_algorithm, MAX_STRING_BYTES);
	ByteWriter view_writer(MAX_OBSERVER_VIEW_BYTES);
	Status view_status = encode_view_body(p_envelope.snapshot, view_writer);
	if (!view_status.ok()) {
		return view_status;
	}
	p_writer.write_blob(view_writer.bytes(), MAX_OBSERVER_VIEW_BYTES);
	return p_writer.status();
}

Status decode_observer_snapshot(ByteReader &p_reader, ObserverSnapshotEnvelope &r_out) {
	if (p_reader.remaining() > MAX_OBSERVER_SNAPSHOT_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	ObserverSnapshotEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version) ||
			!p_reader.read_string(candidate.protocol_magic, MAX_STRING_BYTES) ||
			!p_reader.read_u64(candidate.recipient.session_id) ||
			!p_reader.read_u64(candidate.recipient.actor_id) ||
			!p_reader.read_string(candidate.manifest_algorithm, MAX_STRING_BYTES)) {
		return p_reader.status();
	}
	Status status = validate_protocol(candidate.protocol_version, candidate.protocol_magic, candidate.manifest_algorithm);
	if (!status.ok()) return status;
	status = validate_recipient(candidate.recipient);
	if (!status.ok()) return status;
	std::vector<std::uint8_t> view_bytes;
	if (!p_reader.read_blob(view_bytes, MAX_OBSERVER_VIEW_BYTES)) {
		return p_reader.status();
	}
	ByteReader view_reader(view_bytes);
	status = decode_view_body(view_reader, candidate.snapshot);
	if (!status.ok()) return status;
	if (!view_reader.at_end()) return fail_trailing(view_reader);
	if (!p_reader.at_end()) return fail_trailing(p_reader);
	r_out = std::move(candidate);
	return ok_status();
}

Status encode_observer_delta(const ObserverDeltaEnvelope &p_envelope, ByteWriter &p_writer) {
	Status status = validate_protocol(p_envelope.protocol_version, p_envelope.protocol_magic, p_envelope.manifest_algorithm);
	if (!status.ok()) return status;
	status = validate_recipient(p_envelope.recipient);
	if (!status.ok()) return status;
	status = validate_observer_snapshot(p_envelope.snapshot);
	if (!status.ok()) return status;
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (p_envelope.predecessor_sequence == 0 || p_envelope.predecessor_sequence == UINT64_MAX ||
			p_envelope.predecessor_sequence > script_max ||
			p_envelope.successor_sequence == 0 || p_envelope.successor_sequence > script_max ||
			p_envelope.successor_sequence != p_envelope.predecessor_sequence + 1 ||
			p_envelope.snapshot.sequence != p_envelope.successor_sequence) {
		return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
	}
	p_writer.write_u16(p_envelope.protocol_version);
	p_writer.write_string(p_envelope.protocol_magic, MAX_STRING_BYTES);
	p_writer.write_u64(p_envelope.recipient.session_id);
	p_writer.write_u64(p_envelope.recipient.actor_id);
	p_writer.write_string(p_envelope.manifest_algorithm, MAX_STRING_BYTES);
	p_writer.write_u64(p_envelope.predecessor_sequence);
	p_writer.write_u64(p_envelope.successor_sequence);
	ByteWriter view_writer(MAX_OBSERVER_VIEW_BYTES);
	Status view_status = encode_view_body(p_envelope.snapshot, view_writer);
	if (!view_status.ok()) {
		return view_status;
	}
	p_writer.write_blob(view_writer.bytes(), MAX_OBSERVER_VIEW_BYTES);
	return p_writer.status();
}

Status decode_observer_delta(ByteReader &p_reader, ObserverDeltaEnvelope &r_out) {
	if (p_reader.remaining() > MAX_OBSERVER_DELTA_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	ObserverDeltaEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version) ||
			!p_reader.read_string(candidate.protocol_magic, MAX_STRING_BYTES) ||
			!p_reader.read_u64(candidate.recipient.session_id) ||
			!p_reader.read_u64(candidate.recipient.actor_id) ||
			!p_reader.read_string(candidate.manifest_algorithm, MAX_STRING_BYTES) ||
			!p_reader.read_u64(candidate.predecessor_sequence) ||
			!p_reader.read_u64(candidate.successor_sequence)) {
		return p_reader.status();
	}
	Status status = validate_protocol(candidate.protocol_version, candidate.protocol_magic, candidate.manifest_algorithm);
	if (!status.ok()) return status;
	status = validate_recipient(candidate.recipient);
	if (!status.ok()) return status;
	std::vector<std::uint8_t> view_bytes;
	if (!p_reader.read_blob(view_bytes, MAX_OBSERVER_VIEW_BYTES)) {
		return p_reader.status();
	}
	ByteReader view_reader(view_bytes);
	status = decode_view_body(view_reader, candidate.snapshot);
	if (!status.ok()) return status;
	if (!view_reader.at_end()) return fail_trailing(view_reader);
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (candidate.predecessor_sequence == 0 || candidate.predecessor_sequence == UINT64_MAX ||
			candidate.predecessor_sequence > script_max ||
			candidate.successor_sequence == 0 || candidate.successor_sequence > script_max ||
			candidate.successor_sequence != candidate.predecessor_sequence + 1 ||
			candidate.snapshot.sequence != candidate.successor_sequence) {
		return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE);
	}
	if (!p_reader.at_end()) return fail_trailing(p_reader);
	r_out = std::move(candidate);
	return ok_status();
}

Status encode_observer_resync_request(const ObserverResyncRequest &p_request, ByteWriter &p_writer) {
	Status status = validate_protocol(p_request.protocol_version, p_request.protocol_magic, MANIFEST_ALGORITHM);
	if (!status.ok()) return status;
	status = validate_recipient(p_request.recipient);
	if (!status.ok()) return status;
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (p_request.inventory_id == 0 ||
			p_request.inventory_id > script_max || p_request.generation > script_max ||
			p_request.last_applied_sequence > script_max ||
			((p_request.generation == 0) != (p_request.last_applied_sequence == 0))) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	p_writer.write_u16(p_request.protocol_version);
	p_writer.write_string(p_request.protocol_magic, MAX_STRING_BYTES);
	p_writer.write_u64(p_request.recipient.session_id);
	p_writer.write_u64(p_request.recipient.actor_id);
	p_writer.write_u64(p_request.inventory_id);
	p_writer.write_u64(p_request.generation);
	p_writer.write_u64(p_request.last_applied_sequence);
	return p_writer.status();
}

Status decode_observer_resync_request(ByteReader &p_reader, ObserverResyncRequest &r_out) {
	if (p_reader.remaining() > MAX_OBSERVER_RESYNC_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	ObserverResyncRequest candidate;
	if (!p_reader.read_u16(candidate.protocol_version) ||
			!p_reader.read_string(candidate.protocol_magic, MAX_STRING_BYTES) ||
			!p_reader.read_u64(candidate.recipient.session_id) ||
			!p_reader.read_u64(candidate.recipient.actor_id) ||
			!p_reader.read_u64(candidate.inventory_id) ||
			!p_reader.read_u64(candidate.generation) ||
			!p_reader.read_u64(candidate.last_applied_sequence)) {
		return p_reader.status();
	}
	Status status = validate_protocol(candidate.protocol_version, candidate.protocol_magic, MANIFEST_ALGORITHM);
	if (!status.ok()) return status;
	status = validate_recipient(candidate.recipient);
	if (!status.ok()) return status;
	const std::uint64_t script_max = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
	if (candidate.inventory_id == 0 ||
			candidate.inventory_id > script_max || candidate.generation > script_max ||
			candidate.last_applied_sequence > script_max ||
			((candidate.generation == 0) != (candidate.last_applied_sequence == 0))) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (!p_reader.at_end()) return fail_trailing(p_reader);
	r_out = candidate;
	return ok_status();
}

} // namespace inv::protocol
