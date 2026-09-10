#ifndef WEAPON_SYSTEM_PROTOCOL_CODEC_H
#define WEAPON_SYSTEM_PROTOCOL_CODEC_H

#include "core/wpn_bytes.h"
#include "core/wpn_status.h"
#include "protocol/wpn_protocol_types.h"

#include <cstdint>

// Canonical binary encoding/decoding for every DTO in
// protocol/wpn_protocol_types.h (tasks.md 7.2; weapon-protocol spec,
// "Versioned Canonical Weapon Protocol": "Encoding MUST be independent of
// C++ layout, Godot Variant iteration order, locale, and transport"). Every
// value is written field-by-field in a fixed canonical order via
// core/wpn_bytes.h's ByteWriter -- never a raw struct memcpy -- so encoding
// depends only on field VALUES, never on padding, alignment, member
// declaration order changes that preserve the struct's public shape, map
// iteration order (WeaponDeltaBatch/WeaponSnapshotBatch/AcknowledgementBatch
// entries are written in the caller-supplied vector order, which callers are
// expected to have already sorted canonically -- see each function's doc
// comment), or host endianness/locale.
//
// Every decoder here is a bounded untrusted decoder (weapon-protocol spec,
// "Bounded Malformed Input Handling"): each enforces its envelope's byte cap
// (see the per-function doc comment for which named limit) via
// ByteReader::remaining() before reading a single field, and every nested
// count/string goes through ByteReader::read_count()/read_string() with an
// explicit limit, so a hostile or truncated payload fails closed with a
// stable Status before any collection is allocated at the declared
// (attacker-controlled) size.
namespace wpn::protocol {

// --- CompatibilityHandshake -----------------------------------------------
// Fixed-size (no strings/collections); bounded by MAX_COMMAND_BYTES.
Status encode_compatibility_handshake(const CompatibilityHandshake &p_handshake, ByteWriter &p_writer);
Status decode_compatibility_handshake(ByteReader &p_reader, CompatibilityHandshake &r_out);

// --- FireIntent / BeginReloadIntent / CancelReloadIntent ------------------
// Bounded by MAX_COMMAND_BYTES (contracts hard limit for one command).
Status encode_fire_intent(const FireIntent &p_intent, ByteWriter &p_writer);
Status decode_fire_intent(ByteReader &p_reader, FireIntent &r_out);

Status encode_begin_reload_intent(const BeginReloadIntent &p_intent, ByteWriter &p_writer);
Status decode_begin_reload_intent(ByteReader &p_reader, BeginReloadIntent &r_out);

Status encode_cancel_reload_intent(const CancelReloadIntent &p_intent, ByteWriter &p_writer);
Status decode_cancel_reload_intent(ByteReader &p_reader, CancelReloadIntent &r_out);

// --- ConfigureAttachmentsIntent --------------------------------------------
// Bounded by MAX_COMMAND_BYTES; `desired_loadout` is additionally bounded by
// MAX_ATTACHMENT_SLOTS_PER_WEAPON.
Status encode_configure_attachments_intent(const ConfigureAttachmentsIntent &p_intent, ByteWriter &p_writer);
Status decode_configure_attachments_intent(ByteReader &p_reader, ConfigureAttachmentsIntent &r_out);

// --- CommandRejection ------------------------------------------------------
// Bounded by MAX_COMMAND_BYTES: structurally comparable in size to the
// command it rejects.
Status encode_command_rejection(const CommandRejection &p_rejection, ByteWriter &p_writer);
Status decode_command_rejection(ByteReader &p_reader, CommandRejection &r_out);

// --- WeaponTransitionEvent / ShotResultEnvelope ---------------------------
// Bounded by MAX_COMMAND_BYTES: a mechanical transition or single committed
// shot is structurally comparable in size to the command that produced it.
Status encode_transition_event(const WeaponTransitionEvent &p_event, ByteWriter &p_writer);
Status decode_transition_event(ByteReader &p_reader, WeaponTransitionEvent &r_out);

Status encode_shot_result(const ShotResultEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_shot_result(ByteReader &p_reader, ShotResultEnvelope &r_out);

// --- WeaponSnapshotEnvelope / WeaponSnapshotBatch -------------------------
// Bounded by MAX_SNAPSHOT_BYTES (contracts hard limit); WeaponSnapshotBatch's
// `snapshots` is additionally bounded by MAX_SNAPSHOTS_PER_BATCH.
Status encode_snapshot_envelope(const WeaponSnapshotEnvelope &p_envelope, ByteWriter &p_writer);
Status decode_snapshot_envelope(ByteReader &p_reader, WeaponSnapshotEnvelope &r_out);

Status encode_snapshot_batch(const WeaponSnapshotBatch &p_batch, ByteWriter &p_writer);
Status decode_snapshot_batch(ByteReader &p_reader, WeaponSnapshotBatch &r_out);

// --- WeaponDeltaBatch -------------------------------------------------------
// Bounded by MAX_DELTA_BYTES (contracts hard limit); `deltas` is additionally
// bounded by MAX_DELTAS_PER_BATCH.
Status encode_delta_batch(const WeaponDeltaBatch &p_batch, ByteWriter &p_writer);
Status decode_delta_batch(ByteReader &p_reader, WeaponDeltaBatch &r_out);

// --- AcknowledgementBatch ---------------------------------------------------
// Bounded by MAX_DELTA_BYTES (paired traffic with WeaponDeltaBatch);
// `acknowledgements` is additionally bounded by MAX_ACKNOWLEDGEMENTS_PER_BATCH.
Status encode_acknowledgement_batch(const AcknowledgementBatch &p_batch, ByteWriter &p_writer);
Status decode_acknowledgement_batch(ByteReader &p_reader, AcknowledgementBatch &r_out);

// --- ResyncRequest ----------------------------------------------------------
// One bounded string plus one u64; bounded incidentally by ByteReader's own
// truncation check (no collection), matching
// inv_protocol_codec.h's ResyncRequest precedent.
Status encode_resync_request(const ResyncRequest &p_request, ByteWriter &p_writer);
Status decode_resync_request(ByteReader &p_reader, ResyncRequest &r_out);

} // namespace wpn::protocol

#endif // WEAPON_SYSTEM_PROTOCOL_CODEC_H
