#ifndef INVENTORY_SYSTEM_PROTOCOL_OBSERVER_PROTOCOL_H
#define INVENTORY_SYSTEM_PROTOCOL_OBSERVER_PROTOCOL_H

#include "core/inv_bytes.h"
#include "core/inv_status.h"
#include "protocol/inv_observer_types.h"

namespace inv::protocol {

// Recipient-bound observer packets use a separate protocol namespace and
// bounded replacement-view codecs.  They are not aliases for the canonical
// SnapshotEnvelope/DeltaBatch codecs and therefore cannot accidentally be
// passed to core::restore() or InventoryReplica.
Status encode_observer_snapshot(const ObserverSnapshotEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_observer_snapshot(ByteReader &p_reader, ObserverSnapshotEnvelope &r_out);

Status encode_observer_delta(const ObserverDeltaEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_observer_delta(ByteReader &p_reader, ObserverDeltaEnvelope &r_out);

Status encode_observer_resync_request(const ObserverResyncRequest &p_request, ByteWriter &p_writer);
Status decode_observer_resync_request(ByteReader &p_reader, ObserverResyncRequest &r_out);

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_OBSERVER_PROTOCOL_H
