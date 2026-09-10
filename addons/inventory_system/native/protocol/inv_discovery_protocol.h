#ifndef INVENTORY_SYSTEM_PROTOCOL_DISCOVERY_PROTOCOL_H
#define INVENTORY_SYSTEM_PROTOCOL_DISCOVERY_PROTOCOL_H

#include "core/inv_discovery.h"
#include "core/inv_status.h"
#include "protocol/inv_discovery_view.h"

#include <cstdint>

namespace inv::protocol {

// Discovery is negotiated only for catalogs/profiles that opt into it.
// Keeping this version out of the legacy SessionHello feature bitset
// preserves byte-identical handshakes for every non-participating profile.
constexpr std::uint16_t DISCOVERY_PROTOCOL_VERSION = 1;

struct DiscoveryHello {
	std::uint16_t version = DISCOVERY_PROTOCOL_VERSION;
	bool supported = true;
};

enum class DiscoveryIntentKind : std::uint8_t {
	BEGIN_CONTAINER_SEARCH = 1,
	BEGIN_ITEM_SCAN = 2,
	CANCEL = 3,
};

struct DiscoveryIntentEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint16_t discovery_protocol_version = DISCOVERY_PROTOCOL_VERSION;
	DiscoveryIntentKind kind = DiscoveryIntentKind::BEGIN_CONTAINER_SEARCH;
	DiscoveryIntentHeader header;
	// Container/entry token for begin intents; exactly zero for CANCEL.
	std::uint64_t target_token = 0;
};

// Wire-safe result intentionally omits canonical container/item ids.
struct DiscoveryResultEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint16_t discovery_protocol_version = DISCOVERY_PROTOCOL_VERSION;
	std::uint64_t request_id = 0;
	Status status;
	bool accepted = false;
	bool replayed = false;
	bool completed = false;
	std::uint64_t inventory_revision = 0;
	std::uint64_t discovery_revision = 0;
	DiscoveryTaskKind task_kind = DiscoveryTaskKind::NONE;
	std::uint32_t elapsed_ms = 0;
	std::uint32_t duration_ms = 0;
};

struct DiscoveryViewEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint16_t discovery_protocol_version = DISCOVERY_PROTOCOL_VERSION;
	InventoryId inventory;
	DiscoveryView view;
};

// V1 deltas are complete replacement views with explicit predecessor and
// successor pairs. This costs more bytes than op-level patches but makes the
// privacy boundary auditable: no hidden identity can survive in replica
// state through an omitted removal op.
struct DiscoveryViewDelta {
	std::uint64_t predecessor_inventory_revision = 0;
	std::uint64_t successor_inventory_revision = 0;
	std::uint64_t predecessor_discovery_revision = 0;
	std::uint64_t successor_discovery_revision = 0;
	DiscoveryView view;
};

struct DiscoveryDeltaEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint16_t discovery_protocol_version = DISCOVERY_PROTOCOL_VERSION;
	InventoryId inventory;
	DiscoveryViewDelta delta;
};

Status check_discovery_compatibility(const DiscoveryHello &p_local, const DiscoveryHello &p_remote);
DiscoveryResultEnvelope make_discovery_result_envelope(
		std::uint64_t p_request_id,
		const DiscoveryIntentResult &p_result);

Status encode_discovery_hello(const DiscoveryHello &p_hello, ByteWriter &p_writer);
Status decode_discovery_hello(ByteReader &p_reader, DiscoveryHello &r_out);
Status encode_discovery_intent(const DiscoveryIntentEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_discovery_intent(ByteReader &p_reader, DiscoveryIntentEnvelope &r_out);
Status encode_discovery_result(const DiscoveryResultEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_discovery_result(ByteReader &p_reader, DiscoveryResultEnvelope &r_out);
Status encode_discovery_view(const DiscoveryViewEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_discovery_view(ByteReader &p_reader, DiscoveryViewEnvelope &r_out);
Status encode_discovery_delta(const DiscoveryDeltaEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_discovery_delta(ByteReader &p_reader, DiscoveryDeltaEnvelope &r_out);

class DiscoveryReplica {
public:
	bool initialized() const { return initialized_; }
	bool needs_resync() const { return needs_resync_; }
	InventoryId inventory() const { return inventory_; }
	std::uint64_t inventory_revision() const { return view_.inventory_revision; }
	std::uint64_t discovery_revision() const { return view_.discovery_revision; }
	const DiscoveryView &view() const { return view_; }

	Status apply_view(const DiscoveryViewEnvelope &p_envelope);
	Status apply_delta(const DiscoveryDeltaEnvelope &p_envelope);

private:
	static Status validate_envelope_view(InventoryId p_inventory, const DiscoveryView &p_view);

	bool initialized_ = false;
	bool needs_resync_ = false;
	InventoryId inventory_;
	DiscoveryView view_;
};

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_DISCOVERY_PROTOCOL_H
