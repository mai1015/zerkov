#ifndef INVENTORY_SYSTEM_PROTOCOL_TYPES_H
#define INVENTORY_SYSTEM_PROTOCOL_TYPES_H

#include "core/inv_commands.h"
#include "core/inv_deltas.h"
#include "core/inv_ids.h"
#include "core/inv_limits.h"
#include "core/inv_snapshot.h"

#include <cstdint>
#include <string>
#include <vector>

// Bounded, versioned, transport-neutral DTOs (tasks.md 6.1; inventory-
// protocol spec, "Versioned Transport-Neutral Contracts"). Every DTO here is
// a plain value type: no byte parsing happens in this file (that is
// protocol/inv_protocol_codec.h/.cpp's job, matching core/inv_commands.h's
// own decode-is-a-later-slice discipline). None of these types create or
// require a MultiplayerPeer, RPC topology, database, or transport -- a game
// encodes/decodes them over whatever transport it owns and submits the
// decoded canonical intent to the same authority gate an offline game uses.
//
// Where a DTO's payload is already a core value type (Command, CommandHeader,
// TransactionResult, InventorySnapshot, InventoryDelta), the DTO wraps that
// type verbatim instead of re-declaring an equivalent shape -- one canonical
// definition per concept, per the reuse instructions in inv_snapshot.h/
// inv_commands.h.
namespace inv::protocol {

// --- Compatibility handshake (tasks.md 6.3) --------------------------------

// One peer's compatibility declaration; compatibility.md's six-item session-
// compatibility list, verbatim: protocol version, canonical numeric unit
// identifier, required protocol feature bits, hard-limit contract digest,
// canonical identifier-dictionary digest, and content-manifest algorithm +
// fingerprint. See protocol/inv_protocol_compat.h for how a SessionHello is
// derived (make_session_hello()) and compared (check_session_compatibility()).
struct SessionHello {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	// contracts.md "Canonical numeric and byte rules": the mass unit
	// identifier, always "milligram" in V1 (inv::MASS_UNIT) but carried on
	// the wire rather than assumed, so a future differing unit fails closed
	// instead of silently misinterpreting quantities.
	std::string mass_unit = MASS_UNIT;
	std::string manifest_algorithm = MANIFEST_ALGORITHM;
	std::uint64_t manifest_fingerprint = 0;
	// This build's compiled-in supported protocol feature bits
	// (inv::supported_features()), doubling as "every feature bit this build
	// requires a peer to also support" (V1 has no notion of a feature a
	// build supports but does not require -- see
	// protocol/inv_protocol_compat.cpp's check_session_compatibility() doc
	// comment for the exact bidirectional check this backs).
	std::uint64_t required_feature_bits = 0;
	// fnv1a64 over inv::encode_hard_limits()'s canonical byte sequence (every
	// compiled-in hard limit from inv_limits.h, in fixed order) -- a
	// build-time constant, not catalog-dependent.
	std::uint64_t hard_limit_digest = 0;
	// DefinitionCatalog::identifier_dictionary_fingerprint() of the sealed
	// catalog this session authenticates against -- see that method's doc
	// comment in core/inv_catalog.h for the exact derivation.
	std::uint64_t identifier_dictionary_digest = 0;
};

// --- Command submission -----------------------------------------------

// A CommandHeader/Command pair plus protocol identity, ready to cross a
// transport (inventory-protocol spec: "Commands contain protocol/session
// identity where applicable, command identity, actor identity, targeted
// inventory identities, every expected revision, operation payload").
struct CommandEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	CommandHeader header;
	Command command;
};

// --- Structured result -------------------------------------------------

// Wraps a TransactionResult exactly as InventoryTransactionPipeline::submit()
// produced it, plus protocol identity. `result.deltas` is intentionally NOT
// part of this envelope's wire encoding (see protocol/inv_protocol_codec.cpp'
// s encode_result_envelope()/decode_result_envelope()): the accepted delta
// batch is a separate, dedicated wire message (DeltaBatch below) fanned out
// to replicas, not duplicated inside the sender's own result confirmation. A
// decoded ResultEnvelope::result.deltas is always left empty.
struct ResultEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	TransactionResult result;
};

// --- Ordered authoritative deltas (tasks.md 5.1/6.1) -----------------------

// One accepted transaction's complete canonical delta batch: protocol
// identity, the originating command id (so a replica/observer can correlate
// a delta batch with the ResultEnvelope the submitter received), and the
// bounded per-inventory InventoryDelta records core/inv_transaction.cpp
// built during SIMULATE/COMMIT. `inventories` reuses core::InventoryDelta
// verbatim (see core/inv_deltas.h) -- this struct adds only the envelope.
struct DeltaBatch {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	CommandId source_command_id;
	std::vector<InventoryDelta> inventories; // bounded by MAX_INVENTORIES_PER_TRANSACTION.
};

// --- Canonical full snapshots (tasks.md 6.1) -------------------------------

// Wraps an already-visibility-projected InventorySnapshot (core/
// inv_snapshot.h) plus protocol identity. Visibility is carried on the
// embedded snapshot's own `visibility` field (InventorySnapshot::visibility)
// rather than duplicated here, so the two can never disagree; projection
// FILTERING (which fields a REDACTED/OBSERVER scope actually strips) is
// tasks.md 6.7, a later slice -- this DTO only carries the annotation and the
// (possibly already-projected) snapshot body.
struct SnapshotEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	InventorySnapshot snapshot;
};

// --- Resynchronization request (tasks.md 6.1; application logic is 6.4/6.5)-

// A replica's request for a fresh authoritative snapshot of one inventory,
// naming the last revision it successfully applied (or 0 if it has none
// yet). Deliberately just these two fields, matching the task's literal
// `{ inventory, last_applied_revision }` shape -- no protocol_version, since
// this DTO only ever travels inside an already-negotiated session (unlike
// SessionHello/CommandEnvelope/DeltaBatch/SnapshotEnvelope, which can appear
// before or alongside negotiation).
struct ResyncRequest {
	InventoryId inventory;
	std::uint64_t last_applied_revision = 0;
};

// --- Persistence records (tasks.md 6.1; adapters are 6.8, a later slice) --

// Versioned canonical persistence record for one inventory's snapshot
// (compatibility.md "Persistence compatibility": "carry persistence schema,
// API/protocol provenance, manifest identity, inventory profile, stable
// identities, revision, and canonical snapshot bytes"). `canonical_snapshot_
// bytes` is the ALREADY-ENCODED output of core::encode_canonical(const
// InventorySnapshot&, ByteWriter&) -- this record does not re-encode the
// snapshot itself, so a persistence adapter (a later slice, 6.8) can store
// this record's own encoding without re-deriving the embedded snapshot's
// bytes. `record_hash` is fnv1a64 over every field above it in canonical
// order (see protocol/inv_protocol_codec.h's compute_persistence_record_hash(
// )), mirroring InventorySnapshot::hash's own body-then-hash discipline.
struct PersistenceRecord {
	std::uint16_t persistence_schema_version = PERSISTENCE_SCHEMA_VERSION;
	// "API/protocol provenance": which build/protocol produced this record,
	// for diagnostics and future migration-chain selection -- never itself a
	// compatibility gate (that is manifest_algorithm/manifest_fingerprint
	// below, matching SessionHello's discipline of keeping provenance and
	// compatibility axes separate).
	std::uint8_t api_version_major = 0;
	std::uint8_t api_version_minor = 0;
	std::uint8_t api_version_patch = 0;
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string manifest_algorithm = MANIFEST_ALGORITHM;
	std::uint64_t manifest_fingerprint = 0;
	std::string profile_identifier;
	InventoryId inventory;
	std::uint64_t revision = 0;
	std::vector<std::uint8_t> canonical_snapshot_bytes; // bounded by MAX_SNAPSHOT_BYTES.
	std::uint64_t record_hash = 0;
};

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_TYPES_H
