#ifndef INVENTORY_SYSTEM_PROTOCOL_CODEC_H
#define INVENTORY_SYSTEM_PROTOCOL_CODEC_H

#include "core/inv_bytes.h"
#include "core/inv_status.h"
#include "protocol/inv_protocol_types.h"

#include <cstdint>
#include <string>

// Canonical binary encoding/decoding for every DTO in
// protocol/inv_protocol_types.h (tasks.md 6.2), plus deterministic bounded
// diagnostic JSON (tasks.md 6.2) for the three DTOs the spec calls out
// (SessionHello, ResultEnvelope, DeltaBatch). Canonical binary is the
// compatibility/hashing/persistence format; JSON is one-way (encode only --
// core protocol never decodes JSON) and exists purely for fixtures,
// diagnostics, and tooling (inventory-protocol spec, "Canonical Encoding and
// Hashing": "JSON formatting MUST NOT replace the canonical binary
// compatibility definition").
//
// Every decoder here is a bounded untrusted decoder (tasks.md 6.9): each
// enforces its envelope's byte cap (see the per-function doc comment for
// which) via ByteReader::remaining() before reading a single field, and every
// nested count/string/blob goes through ByteReader::read_count()/
// read_string()/read_blob() with an explicit limit, so a hostile or
// truncated payload fails closed with a stable Status before any collection
// is allocated at the declared (attacker-controlled) size. Reused codecs
// (core::encode_canonical/decode_canonical for InventorySnapshot,
// core::encode_snapshot_location/decode_snapshot_location for locations)
// already carry the same discipline; this file does not re-validate what
// those already validate, only what it adds itself.
namespace inv::protocol {

// Status is a fixed-width, append-only wire value.  These helpers are kept
// public so every transport envelope (including engine-independent gateway
// diagnostics) can round-trip the same status vocabulary.
Status encode_status(const Status &p_status, ByteWriter &p_writer);
Status decode_status(ByteReader &p_reader, Status &r_out);

// --- SessionHello ---------------------------------------------------------
// Bounded by a small fixed-plus-two-strings envelope (well under
// MAX_COMMAND_BYTES; see inv_protocol_codec.cpp for the exact byte layout
// comment).
Status encode_session_hello(const SessionHello &p_hello, ByteWriter &p_writer);
Status decode_session_hello(ByteReader &p_reader, SessionHello &r_out);

// --- CommandEnvelope --------------------------------------------------
// Bounded by MAX_COMMAND_BYTES (contracts.md hard limit).
Status encode_command_envelope(const CommandEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_command_envelope(ByteReader &p_reader, CommandEnvelope &r_out);

// --- ResultEnvelope ---------------------------------------------------
// Bounded by MAX_DELTA_BYTES: a TransactionResult's content (bounded events/
// dropped-items lists) is structurally comparable in size to the delta batch
// the same accepted transaction produces, so this envelope reuses that named
// limit rather than introducing an independent one. `result.deltas` is never
// encoded (see protocol/inv_protocol_types.h's ResultEnvelope doc comment);
// decode always leaves it empty.
Status encode_result_envelope(const ResultEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_result_envelope(ByteReader &p_reader, ResultEnvelope &r_out);

// --- DeltaBatch ---------------------------------------------------------
// Bounded by MAX_DELTA_BYTES (contracts.md hard limit); each InventoryDelta's
// `ops` is additionally bounded by MAX_DELTA_OPS_PER_INVENTORY.
Status encode_delta_batch(const DeltaBatch &p_batch, ByteWriter &p_writer);
Status decode_delta_batch(ByteReader &p_reader, DeltaBatch &r_out);

// --- SnapshotEnvelope -----------------------------------------------------
// Bounded by MAX_SNAPSHOT_BYTES (contracts.md hard limit); the embedded
// InventorySnapshot reuses core::encode_canonical()/decode_canonical()
// verbatim.
Status encode_snapshot_envelope(const SnapshotEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_snapshot_envelope(ByteReader &p_reader, SnapshotEnvelope &r_out);

// --- ResyncRequest --------------------------------------------------------
// Two fixed-width u64 fields; bounded incidentally by ByteReader's own
// truncation check (no collection, no string).
Status encode_resync_request(const ResyncRequest &p_request, ByteWriter &p_writer);
Status decode_resync_request(ByteReader &p_reader, ResyncRequest &r_out);

// --- PersistenceRecord ------------------------------------------------
// Bounded by MAX_SNAPSHOT_BYTES plus a small fixed allowance for the
// record's own header fields (the embedded canonical_snapshot_bytes blob
// dominates; see inv_protocol_codec.cpp for the exact constant). `record_
// hash` is written/read as the LAST field, mirroring InventorySnapshot's own
// body-then-hash discipline (core/inv_snapshot.cpp's encode_canonical()).
Status encode_persistence_record(const PersistenceRecord &p_record, ByteWriter &p_writer);
Status decode_persistence_record(ByteReader &p_reader, PersistenceRecord &r_out);

// fnv1a64 over every PersistenceRecord field EXCEPT record_hash itself, in
// canonical encode order. Callers building a record for storage or a golden
// fixture call this to fill PersistenceRecord::record_hash before encoding;
// decode_persistence_record() does not itself verify the read-back hash
// against this function's return value (fnv1a64 is a divergence detector,
// never a tamper-evidence or integrity gate -- contracts.md's identical
// caveat about the manifest fingerprint applies here too), it only decodes
// the field.
std::uint64_t compute_persistence_record_hash(const PersistenceRecord &p_record);

// --- Deterministic diagnostic JSON (tasks.md 6.2) --------------------------
//
// Stable rule set, applied uniformly across all three functions below:
//   - object keys are emitted in strict ASCII/bytewise alphabetical order;
//   - every std::uint64_t scalar field (ids in every identity domain, hashes,
//     digests, revisions, quantities, byte counts) is emitted as a quoted
//     decimal string -- never a bare JSON number -- so a 64-bit value can
//     never silently lose precision in a consumer that parses JSON numbers
//     as IEEE-754 doubles (53-bit mantissa) or overflow inv_test_json.h's
//     int64-based parser;
//   - every narrower integer (u8/u16/u32) and every enum's underlying numeric
//     tag (StatusCode, DiagnosticId, TransactionEventKind, DeltaOpKind,
///    SnapshotLocationKind) is emitted as a bare JSON integer;
//   - bool is emitted as true/false;
//   - std::string is emitted as an escaped JSON string;
//   - a byte blob (component payload, dropped-item component payload) is
//     emitted as a lowercase-hex JSON string, two characters per byte;
//   - a vector is emitted as a JSON array in the vector's own (already
//     canonical) order;
//   - there are no floating-point values anywhere in this output.
// Two calls with byte-identical input DTOs always produce byte-identical
// output strings (inventory-protocol spec, "Canonical Encoding and
// Hashing": repeated runs are identical).
std::string to_diagnostic_json(const SessionHello &p_hello);
std::string to_diagnostic_json(const ResultEnvelope &p_envelope);
std::string to_diagnostic_json(const DeltaBatch &p_batch);

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_CODEC_H
