#include "protocol/wpn_protocol_codec.h"

#include <utility>

namespace wpn::protocol {

namespace {

Status fail_trailing(const ByteReader &p_reader) {
	return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRAILING_PAYLOAD_BYTES, p_reader.remaining());
}

Status fail_too_large(std::size_t p_remaining) {
	return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_remaining);
}

// --- FixedVec2 <-> wire -----------------------------------------------

void encode_vec2(const FixedVec2 &p_value, ByteWriter &p_writer) {
	p_writer.write_i64(p_value.x);
	p_writer.write_i64(p_value.y);
}

Status decode_vec2(ByteReader &p_reader, FixedVec2 &r_out) {
	if (!p_reader.read_i64(r_out.x) || !p_reader.read_i64(r_out.y)) {
		return p_reader.status();
	}
	return ok_status();
}

// --- Status/Rejection <-> wire (mirrors
// inv_protocol_codec.cpp's encode_status()/decode_status() discipline:
// code/diagnostic are decoded WITHOUT range validation, since StatusCode/
// DiagnosticId/Rejection are append-only carried DATA that never itself
// gates how a later byte is interpreted) --------------------------------

void encode_status(const Status &p_status, ByteWriter &p_writer) {
	p_writer.write_u16(static_cast<std::uint16_t>(p_status.code));
	p_writer.write_u16(static_cast<std::uint16_t>(p_status.diagnostic));
	p_writer.write_u64(p_status.detail);
}

Status decode_status(ByteReader &p_reader, Status &r_out) {
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

// --- CompatibilityManifest <-> wire (mirrors
// CompatibilityManifest::fingerprint()'s field order in wpn_version.cpp) --
// tasks.md 7.8/7.9: `world_quantization_version`/`world_tie_rule_version`
// (task 6.8's sealed world-geometry contract, already part of
// CompatibilityManifest::fingerprint() and core::check_compatibility()'s
// comparison) were missing from the wire form entirely -- two authorities
// that genuinely disagreed on either version would previously decode as
// 0 == 0 and falsely appear compatible. Added here as part of this
// PROTOCOL_VERSION bump.

void encode_manifest(const CompatibilityManifest &p_manifest, ByteWriter &p_writer) {
	p_writer.write_u16(p_manifest.api_major);
	p_writer.write_u16(p_manifest.api_minor);
	p_writer.write_u16(p_manifest.api_patch);
	p_writer.write_u16(p_manifest.protocol);
	p_writer.write_u16(p_manifest.resource_schema);
	p_writer.write_u64(p_manifest.features);
	p_writer.write_u64(p_manifest.catalog_fingerprint);
	p_writer.write_u16(p_manifest.world_quantization_version);
	p_writer.write_u16(p_manifest.world_tie_rule_version);
}

Status decode_manifest(ByteReader &p_reader, CompatibilityManifest &r_out) {
	if (!p_reader.read_u16(r_out.api_major) || !p_reader.read_u16(r_out.api_minor) ||
			!p_reader.read_u16(r_out.api_patch) || !p_reader.read_u16(r_out.protocol) ||
			!p_reader.read_u16(r_out.resource_schema)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(r_out.features) || !p_reader.read_u64(r_out.catalog_fingerprint)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(r_out.world_quantization_version) || !p_reader.read_u16(r_out.world_tie_rule_version)) {
		return p_reader.status();
	}
	return ok_status();
}

// --- BallisticProfileIdentity/AttachmentLoadoutEntry/WeaponTombstone/
// ConsequenceIdentity <-> wire (tasks.md 7.8/7.9) --------------------------
// Small reusable helpers shared by ReloadState, WeaponSnapshot,
// CommittedShot, WeaponDelta, WeaponSnapshotBatch, and WeaponTransitionEvent
// below -- exactly one canonical wire shape per core value type, never
// re-derived per call site.

void encode_ballistic_profile_identity(const BallisticProfileIdentity &p_profile, ByteWriter &p_writer) {
	p_writer.write_string(p_profile.id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u16(p_profile.version);
}

Status decode_ballistic_profile_identity(ByteReader &p_reader, BallisticProfileIdentity &r_out) {
	if (!p_reader.read_string(r_out.id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(r_out.version)) {
		return p_reader.status();
	}
	return ok_status();
}

void encode_attachment_loadout_entry(const AttachmentLoadoutEntry &p_entry, ByteWriter &p_writer) {
	p_writer.write_string(p_entry.slot_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_string(p_entry.attachment_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u16(p_entry.attachment_version);
}

Status decode_attachment_loadout_entry(ByteReader &p_reader, AttachmentLoadoutEntry &r_out) {
	if (!p_reader.read_string(r_out.slot_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(r_out.attachment_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(r_out.attachment_version)) {
		return p_reader.status();
	}
	return ok_status();
}

void encode_attachment_loadout(const std::vector<AttachmentLoadoutEntry> &p_loadout, ByteWriter &p_writer) {
	p_writer.write_count(p_loadout.size(), MAX_ATTACHMENT_SLOTS_PER_WEAPON);
	for (const AttachmentLoadoutEntry &entry : p_loadout) {
		encode_attachment_loadout_entry(entry, p_writer);
	}
}

Status decode_attachment_loadout(ByteReader &p_reader, std::vector<AttachmentLoadoutEntry> &r_out) {
	std::size_t count = 0;
	// Structural floor per entry: slot_id len(4) + attachment_id len(4) +
	// attachment_version(2) = 10 bytes even if both strings are empty. Must
	// stay AT OR BELOW every entry's true minimum size, never above it, or a
	// legitimately minimal-size declared count would be rejected here before
	// ever reaching the per-entry decode below.
	if (!p_reader.read_count(count, MAX_ATTACHMENT_SLOTS_PER_WEAPON, /*p_min_bytes_per_entry=*/10)) {
		return p_reader.status();
	}
	r_out.clear();
	r_out.reserve(count);
	for (std::size_t i = 0; i < count; ++i) {
		AttachmentLoadoutEntry entry;
		Status status = decode_attachment_loadout_entry(p_reader, entry);
		if (!status.ok()) {
			return status;
		}
		r_out.push_back(std::move(entry));
	}
	return ok_status();
}

// Mirrors ConsequenceIdentity::compact_hash()'s field order in
// wpn_runtime.cpp -- full-value equality remains authoritative (see that
// type's doc comment); this is only its canonical wire shape.
void encode_consequence_identity(const ConsequenceIdentity &p_identity, ByteWriter &p_writer) {
	p_writer.write_u16(p_identity.version);
	p_writer.write_u32(p_identity.domain);
	p_writer.write_string(p_identity.authority_scope, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_identity.authority_epoch);
	p_writer.write_string(p_identity.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_identity.successor_revision);
	p_writer.write_string(p_identity.command_id, MAX_IDENTIFIER_BYTES);
}

Status decode_consequence_identity(ByteReader &p_reader, ConsequenceIdentity &r_out) {
	if (!p_reader.read_u16(r_out.version)) {
		return p_reader.status();
	}
	if (!p_reader.read_u32(r_out.domain)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(r_out.authority_scope, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(r_out.authority_epoch)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(r_out.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(r_out.successor_revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(r_out.command_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	return ok_status();
}

void encode_tombstone(const WeaponTombstone &p_tombstone, ByteWriter &p_writer) {
	p_writer.write_string(p_tombstone.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_string(p_tombstone.authority_scope, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_tombstone.authority_epoch);
	p_writer.write_u64(p_tombstone.revision);
}

Status decode_tombstone(ByteReader &p_reader, WeaponTombstone &r_out) {
	WeaponTombstone candidate;
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.authority_scope, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.authority_epoch)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.revision)) {
		return p_reader.status();
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- ReloadState/WeaponSnapshot <-> wire (mirrors
// WeaponSnapshot::fingerprint()'s field order in wpn_runtime.cpp) --------
// tasks.md 7.8/7.9: extended to carry every field core::WeaponSnapshot now
// declares -- previously only the V1 subset (identity, revision, sequence/
// fire ticks, loaded rounds, phase, reload without its profile) was on the
// wire; the authority scope/epoch/tick-floor/tick-health envelope, admitted
// sequence high-watermark, recoil anchor state, flat attachment loadout, and
// optional loaded/reserved ballistic-profile identity were silently dropped
// on every encode. Field order below matches
// WeaponSnapshot::fingerprint()'s exactly so a canonical-order regression
// here would also show up as a fingerprint mismatch in the core layer's own
// tests.

void encode_reload_state(const ReloadState &p_reload, ByteWriter &p_writer) {
	p_writer.write_string(p_reload.reservation_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u32(p_reload.reserved_rounds);
	p_writer.write_u64(p_reload.start_tick);
	p_writer.write_u64(p_reload.due_tick);
	encode_ballistic_profile_identity(p_reload.reserved_profile, p_writer);
}

Status decode_reload_state(ByteReader &p_reader, ReloadState &r_out) {
	if (!p_reader.read_string(r_out.reservation_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u32(r_out.reserved_rounds)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(r_out.start_tick) || !p_reader.read_u64(r_out.due_tick)) {
		return p_reader.status();
	}
	Status status = decode_ballistic_profile_identity(p_reader, r_out.reserved_profile);
	if (!status.ok()) {
		return status;
	}
	return ok_status();
}

void encode_snapshot(const WeaponSnapshot &p_snapshot, ByteWriter &p_writer) {
	p_writer.write_string(p_snapshot.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_string(p_snapshot.definition_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u16(p_snapshot.definition_version);
	p_writer.write_u64(p_snapshot.revision);
	p_writer.write_bool(p_snapshot.has_last_command_sequence);
	if (p_snapshot.has_last_command_sequence) {
		p_writer.write_u64(p_snapshot.last_command_sequence);
	}
	p_writer.write_u32(p_snapshot.loaded_rounds);
	p_writer.write_bool(p_snapshot.loaded_profile.has_value());
	if (p_snapshot.loaded_profile.has_value()) {
		encode_ballistic_profile_identity(*p_snapshot.loaded_profile, p_writer);
	}
	p_writer.write_bool(p_snapshot.has_last_fire_tick);
	if (p_snapshot.has_last_fire_tick) {
		p_writer.write_u64(p_snapshot.last_fire_tick);
	}
	p_writer.write_u8(static_cast<std::uint8_t>(p_snapshot.phase));
	p_writer.write_bool(p_snapshot.reload.has_value());
	if (p_snapshot.reload.has_value()) {
		encode_reload_state(*p_snapshot.reload, p_writer);
	}
	p_writer.write_string(p_snapshot.authority_scope, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_snapshot.authority_epoch);
	p_writer.write_u64(p_snapshot.authority_tick_floor);
	p_writer.write_u64(p_snapshot.admitted_sequence_high_watermark);
	p_writer.write_bool(p_snapshot.tick_unhealthy);
	p_writer.write_i64(p_snapshot.recoil_vertical_offset_nrad);
	p_writer.write_i64(p_snapshot.recoil_horizontal_offset_nrad);
	p_writer.write_u64(p_snapshot.recoil_anchor_tick);
	encode_attachment_loadout(p_snapshot.attachment_loadout, p_writer);
}

Status decode_snapshot(ByteReader &p_reader, WeaponSnapshot &r_out) {
	WeaponSnapshot candidate;
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.definition_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(candidate.definition_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_bool(candidate.has_last_command_sequence)) {
		return p_reader.status();
	}
	if (candidate.has_last_command_sequence && !p_reader.read_u64(candidate.last_command_sequence)) {
		return p_reader.status();
	}
	if (!p_reader.read_u32(candidate.loaded_rounds)) {
		return p_reader.status();
	}
	bool has_loaded_profile = false;
	if (!p_reader.read_bool(has_loaded_profile)) {
		return p_reader.status();
	}
	if (has_loaded_profile) {
		BallisticProfileIdentity profile;
		Status status = decode_ballistic_profile_identity(p_reader, profile);
		if (!status.ok()) {
			return status;
		}
		candidate.loaded_profile = std::move(profile);
	}
	if (!p_reader.read_bool(candidate.has_last_fire_tick)) {
		return p_reader.status();
	}
	if (candidate.has_last_fire_tick && !p_reader.read_u64(candidate.last_fire_tick)) {
		return p_reader.status();
	}
	std::uint8_t phase_raw = 0;
	if (!p_reader.read_u8(phase_raw)) {
		return p_reader.status();
	}
	if (phase_raw > static_cast<std::uint8_t>(WeaponPhase::RELOADING)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	candidate.phase = static_cast<WeaponPhase>(phase_raw);
	bool has_reload = false;
	if (!p_reader.read_bool(has_reload)) {
		return p_reader.status();
	}
	if (has_reload) {
		ReloadState reload;
		Status status = decode_reload_state(p_reader, reload);
		if (!status.ok()) {
			return status;
		}
		candidate.reload = std::move(reload);
	}
	if (!p_reader.read_string(candidate.authority_scope, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.authority_epoch)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.authority_tick_floor)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.admitted_sequence_high_watermark)) {
		return p_reader.status();
	}
	if (!p_reader.read_bool(candidate.tick_unhealthy)) {
		return p_reader.status();
	}
	if (!p_reader.read_i64(candidate.recoil_vertical_offset_nrad) ||
			!p_reader.read_i64(candidate.recoil_horizontal_offset_nrad)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.recoil_anchor_tick)) {
		return p_reader.status();
	}
	Status loadout_status = decode_attachment_loadout(p_reader, candidate.attachment_loadout);
	if (!loadout_status.ok()) {
		return loadout_status;
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- CommittedShot <-> wire ----------------------------------------------
// tasks.md 7.9: extended with the canonical versioned `consequence_identity`
// (weapon-protocol spec: "stable shot/consequence identity" -- `consequence_id`
// above remains the legacy compact string projection, kept verbatim for
// source compatibility per core::CommittedShot's own doc comment) and the
// exact `consumed_profile` ballistic-profile identity (weapon-protocol spec:
// "consumed profile identity"). `consumed_profile` is a plain (non-optional)
// value exactly like ReloadState::reserved_profile above -- an empty `id`
// canonically encodes "no ballistic-profile mechanic consumed this shot".

void encode_shot(const CommittedShot &p_shot, ByteWriter &p_writer) {
	p_writer.write_string(p_shot.consequence_id, MAX_IDENTIFIER_BYTES);
	encode_consequence_identity(p_shot.consequence_identity, p_writer);
	p_writer.write_string(p_shot.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_string(p_shot.weapon_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u16(p_shot.weapon_version);
	p_writer.write_string(p_shot.shot_profile_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u16(p_shot.shot_profile_version);
	p_writer.write_u64(p_shot.tick);
	encode_vec2(p_shot.origin, p_writer);
	encode_vec2(p_shot.direction, p_writer);
	p_writer.write_i64(p_shot.damage_milliunits);
	p_writer.write_i64(p_shot.range_milliunits);
	p_writer.write_i64(p_shot.noise_radius_milliunits);
	encode_ballistic_profile_identity(p_shot.consumed_profile, p_writer);
}

Status decode_shot(ByteReader &p_reader, CommittedShot &r_out) {
	CommittedShot candidate;
	if (!p_reader.read_string(candidate.consequence_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	Status status = decode_consequence_identity(p_reader, candidate.consequence_identity);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.weapon_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(candidate.weapon_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.shot_profile_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u16(candidate.shot_profile_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.tick)) {
		return p_reader.status();
	}
	status = decode_vec2(p_reader, candidate.origin);
	if (!status.ok()) {
		return status;
	}
	status = decode_vec2(p_reader, candidate.direction);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.read_i64(candidate.damage_milliunits) || !p_reader.read_i64(candidate.range_milliunits) ||
			!p_reader.read_i64(candidate.noise_radius_milliunits)) {
		return p_reader.status();
	}
	status = decode_ballistic_profile_identity(p_reader, candidate.consumed_profile);
	if (!status.ok()) {
		return status;
	}
	r_out = std::move(candidate);
	return ok_status();
}

} // namespace

// --- CompatibilityHandshake -------------------------------------------

Status encode_compatibility_handshake(const CompatibilityHandshake &p_handshake, ByteWriter &p_writer) {
	p_writer.write_u16(p_handshake.protocol_version);
	encode_manifest(p_handshake.manifest, p_writer);
	return p_writer.status();
}

Status decode_compatibility_handshake(ByteReader &p_reader, CompatibilityHandshake &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	CompatibilityHandshake candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	Status status = decode_manifest(p_reader, candidate.manifest);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- FireIntent -------------------------------------------------------

Status encode_fire_intent(const FireIntent &p_intent, ByteWriter &p_writer) {
	p_writer.write_u16(p_intent.protocol_version);
	p_writer.write_string(p_intent.command_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.sequence);
	p_writer.write_string(p_intent.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.expected_revision);
	encode_vec2(p_intent.claimed_origin, p_writer);
	encode_vec2(p_intent.claimed_aim, p_writer);
	p_writer.write_u64(p_intent.spread_seed);
	return p_writer.status();
}

Status decode_fire_intent(ByteReader &p_reader, FireIntent &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	FireIntent candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.command_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.sequence)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.expected_revision)) {
		return p_reader.status();
	}
	Status status = decode_vec2(p_reader, candidate.claimed_origin);
	if (!status.ok()) {
		return status;
	}
	status = decode_vec2(p_reader, candidate.claimed_aim);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.read_u64(candidate.spread_seed)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- BeginReloadIntent --------------------------------------------------

Status encode_begin_reload_intent(const BeginReloadIntent &p_intent, ByteWriter &p_writer) {
	p_writer.write_u16(p_intent.protocol_version);
	p_writer.write_string(p_intent.command_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.sequence);
	p_writer.write_string(p_intent.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.expected_revision);
	p_writer.write_string(p_intent.reservation_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u32(p_intent.reserved_rounds);
	return p_writer.status();
}

Status decode_begin_reload_intent(ByteReader &p_reader, BeginReloadIntent &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	BeginReloadIntent candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.command_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.sequence)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.expected_revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.reservation_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u32(candidate.reserved_rounds)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- CancelReloadIntent --------------------------------------------------

Status encode_cancel_reload_intent(const CancelReloadIntent &p_intent, ByteWriter &p_writer) {
	p_writer.write_u16(p_intent.protocol_version);
	p_writer.write_string(p_intent.command_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.sequence);
	p_writer.write_string(p_intent.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.expected_revision);
	return p_writer.status();
}

Status decode_cancel_reload_intent(ByteReader &p_reader, CancelReloadIntent &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	CancelReloadIntent candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.command_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.sequence)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.expected_revision)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- ConfigureAttachmentsIntent -------------------------------------------

Status encode_configure_attachments_intent(const ConfigureAttachmentsIntent &p_intent, ByteWriter &p_writer) {
	p_writer.write_u16(p_intent.protocol_version);
	p_writer.write_string(p_intent.command_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.sequence);
	p_writer.write_string(p_intent.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_intent.expected_revision);
	encode_attachment_loadout(p_intent.desired_loadout, p_writer);
	return p_writer.status();
}

Status decode_configure_attachments_intent(ByteReader &p_reader, ConfigureAttachmentsIntent &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	ConfigureAttachmentsIntent candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.command_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.sequence)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.expected_revision)) {
		return p_reader.status();
	}
	Status status = decode_attachment_loadout(p_reader, candidate.desired_loadout);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- CommandRejection ---------------------------------------------------

Status encode_command_rejection(const CommandRejection &p_rejection, ByteWriter &p_writer) {
	p_writer.write_u16(p_rejection.protocol_version);
	p_writer.write_string(p_rejection.command_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_string(p_rejection.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u16(static_cast<std::uint16_t>(p_rejection.rejection));
	encode_status(p_rejection.status, p_writer);
	p_writer.write_u64(p_rejection.current_revision);
	return p_writer.status();
}

Status decode_command_rejection(ByteReader &p_reader, CommandRejection &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	CommandRejection candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.command_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	std::uint16_t rejection_raw = 0;
	if (!p_reader.read_u16(rejection_raw)) {
		return p_reader.status();
	}
	candidate.rejection = static_cast<Rejection>(rejection_raw);
	Status status = decode_status(p_reader, candidate.status);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.read_u64(candidate.current_revision)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- WeaponTransitionEvent -----------------------------------------------

Status encode_transition_event(const WeaponTransitionEvent &p_event, ByteWriter &p_writer) {
	p_writer.write_u16(p_event.protocol_version);
	p_writer.write_string(p_event.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u8(static_cast<std::uint8_t>(p_event.kind));
	p_writer.write_u64(p_event.predecessor_revision);
	p_writer.write_u64(p_event.successor_revision);
	p_writer.write_u32(p_event.loaded_rounds);
	p_writer.write_u8(static_cast<std::uint8_t>(p_event.phase));
	p_writer.write_bool(p_event.shot.has_value());
	if (p_event.shot.has_value()) {
		encode_shot(*p_event.shot, p_writer);
	}
	p_writer.write_bool(p_event.tombstone.has_value());
	if (p_event.tombstone.has_value()) {
		encode_tombstone(*p_event.tombstone, p_writer);
	}
	return p_writer.status();
}

Status decode_transition_event(ByteReader &p_reader, WeaponTransitionEvent &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	WeaponTransitionEvent candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	std::uint8_t kind_raw = 0;
	if (!p_reader.read_u8(kind_raw)) {
		return p_reader.status();
	}
	if (kind_raw < static_cast<std::uint8_t>(TransitionKind::FIRE) ||
			kind_raw > static_cast<std::uint8_t>(TransitionKind::CONFIGURE_ATTACHMENTS)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	candidate.kind = static_cast<TransitionKind>(kind_raw);
	if (!p_reader.read_u64(candidate.predecessor_revision) || !p_reader.read_u64(candidate.successor_revision)) {
		return p_reader.status();
	}
	if (!p_reader.read_u32(candidate.loaded_rounds)) {
		return p_reader.status();
	}
	std::uint8_t phase_raw = 0;
	if (!p_reader.read_u8(phase_raw)) {
		return p_reader.status();
	}
	if (phase_raw > static_cast<std::uint8_t>(WeaponPhase::RELOADING)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	candidate.phase = static_cast<WeaponPhase>(phase_raw);
	bool has_shot = false;
	if (!p_reader.read_bool(has_shot)) {
		return p_reader.status();
	}
	if (has_shot) {
		CommittedShot shot;
		Status status = decode_shot(p_reader, shot);
		if (!status.ok()) {
			return status;
		}
		candidate.shot = std::move(shot);
	}
	bool has_tombstone = false;
	if (!p_reader.read_bool(has_tombstone)) {
		return p_reader.status();
	}
	if (has_tombstone) {
		WeaponTombstone tombstone;
		Status status = decode_tombstone(p_reader, tombstone);
		if (!status.ok()) {
			return status;
		}
		candidate.tombstone = std::move(tombstone);
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- ShotResultEnvelope --------------------------------------------------

Status encode_shot_result(const ShotResultEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	encode_shot(p_envelope.shot, p_writer);
	return p_writer.status();
}

Status decode_shot_result(ByteReader &p_reader, ShotResultEnvelope &r_out) {
	if (p_reader.remaining() > MAX_COMMAND_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	ShotResultEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	Status status = decode_shot(p_reader, candidate.shot);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- WeaponSnapshotEnvelope ------------------------------------------------

Status encode_snapshot_envelope(const WeaponSnapshotEnvelope &p_envelope, ByteWriter &p_writer) {
	p_writer.write_u16(p_envelope.protocol_version);
	encode_snapshot(p_envelope.snapshot, p_writer);
	return p_writer.status();
}

Status decode_snapshot_envelope(ByteReader &p_reader, WeaponSnapshotEnvelope &r_out) {
	if (p_reader.remaining() > MAX_SNAPSHOT_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	WeaponSnapshotEnvelope candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	Status status = decode_snapshot(p_reader, candidate.snapshot);
	if (!status.ok()) {
		return status;
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- WeaponSnapshotBatch ----------------------------------------------------
// tasks.md 7.9: extended with a parallel `tombstones` list (weapon-protocol
// spec: "lifecycle/tombstone state") so a late join / reconnect batch can
// also tell a replica about terminal instances, bounded by MAX_TOMBSTONES
// exactly like core::WeaponRuntime's own bounded tombstone retention.

Status encode_snapshot_batch(const WeaponSnapshotBatch &p_batch, ByteWriter &p_writer) {
	p_writer.write_u16(p_batch.protocol_version);
	p_writer.write_count(p_batch.snapshots.size(), MAX_SNAPSHOTS_PER_BATCH);
	for (const WeaponSnapshot &snapshot : p_batch.snapshots) {
		encode_snapshot(snapshot, p_writer);
	}
	p_writer.write_count(p_batch.tombstones.size(), MAX_TOMBSTONES);
	for (const WeaponTombstone &tombstone : p_batch.tombstones) {
		encode_tombstone(tombstone, p_writer);
	}
	return p_writer.status();
}

Status decode_snapshot_batch(ByteReader &p_reader, WeaponSnapshotBatch &r_out) {
	if (p_reader.remaining() > MAX_SNAPSHOT_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	WeaponSnapshotBatch candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_SNAPSHOTS_PER_BATCH, /*p_min_bytes_per_entry=*/20)) {
		return p_reader.status();
	}
	candidate.snapshots.reserve(count);
	for (std::size_t i = 0; i < count; ++i) {
		WeaponSnapshot snapshot;
		Status status = decode_snapshot(p_reader, snapshot);
		if (!status.ok()) {
			return status;
		}
		candidate.snapshots.push_back(std::move(snapshot));
	}
	std::size_t tombstone_count = 0;
	if (!p_reader.read_count(tombstone_count, MAX_TOMBSTONES, /*p_min_bytes_per_entry=*/12)) {
		return p_reader.status();
	}
	candidate.tombstones.reserve(tombstone_count);
	for (std::size_t i = 0; i < tombstone_count; ++i) {
		WeaponTombstone tombstone;
		Status status = decode_tombstone(p_reader, tombstone);
		if (!status.ok()) {
			return status;
		}
		candidate.tombstones.push_back(std::move(tombstone));
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- WeaponDeltaBatch --------------------------------------------------------

namespace {

// tasks.md 7.9: `lifecycle`/`tombstone` are pure additions appended after the
// pre-existing `snapshot` field -- `snapshot` is still always encoded
// unconditionally (unchanged wire position/shape for that part), so a
// TOMBSTONED delta's `snapshot` is simply a meaningless placeholder on the
// wire (harmless, a handful of extra bytes) rather than requiring a
// conditional that would perturb every existing byte offset after it.
void encode_delta(const WeaponDelta &p_delta, ByteWriter &p_writer) {
	p_writer.write_u64(p_delta.predecessor_revision);
	p_writer.write_u64(p_delta.successor_revision);
	p_writer.write_u8(static_cast<std::uint8_t>(p_delta.lifecycle));
	encode_snapshot(p_delta.snapshot, p_writer);
	p_writer.write_bool(p_delta.tombstone.has_value());
	if (p_delta.tombstone.has_value()) {
		encode_tombstone(*p_delta.tombstone, p_writer);
	}
	p_writer.write_bool(p_delta.shot.has_value());
	if (p_delta.shot.has_value()) {
		encode_shot(*p_delta.shot, p_writer);
	}
}

Status decode_delta(ByteReader &p_reader, WeaponDelta &r_out) {
	WeaponDelta candidate;
	if (!p_reader.read_u64(candidate.predecessor_revision) || !p_reader.read_u64(candidate.successor_revision)) {
		return p_reader.status();
	}
	std::uint8_t lifecycle_raw = 0;
	if (!p_reader.read_u8(lifecycle_raw)) {
		return p_reader.status();
	}
	if (lifecycle_raw < static_cast<std::uint8_t>(WeaponLifecycleState::ACTIVE) ||
			lifecycle_raw > static_cast<std::uint8_t>(WeaponLifecycleState::TOMBSTONED)) {
		p_reader.fail(DiagnosticId::INVALID_ENUM);
		return p_reader.status();
	}
	candidate.lifecycle = static_cast<WeaponLifecycleState>(lifecycle_raw);
	Status status = decode_snapshot(p_reader, candidate.snapshot);
	if (!status.ok()) {
		return status;
	}
	bool has_tombstone = false;
	if (!p_reader.read_bool(has_tombstone)) {
		return p_reader.status();
	}
	if (has_tombstone) {
		WeaponTombstone tombstone;
		status = decode_tombstone(p_reader, tombstone);
		if (!status.ok()) {
			return status;
		}
		candidate.tombstone = std::move(tombstone);
	}
	bool has_shot = false;
	if (!p_reader.read_bool(has_shot)) {
		return p_reader.status();
	}
	if (has_shot) {
		CommittedShot shot;
		status = decode_shot(p_reader, shot);
		if (!status.ok()) {
			return status;
		}
		candidate.shot = std::move(shot);
	}
	r_out = std::move(candidate);
	return ok_status();
}

} // namespace

Status encode_delta_batch(const WeaponDeltaBatch &p_batch, ByteWriter &p_writer) {
	p_writer.write_u16(p_batch.protocol_version);
	p_writer.write_u64(p_batch.authority_tick);
	p_writer.write_count(p_batch.deltas.size(), MAX_DELTAS_PER_BATCH);
	for (const WeaponDelta &delta : p_batch.deltas) {
		encode_delta(delta, p_writer);
	}
	return p_writer.status();
}

Status decode_delta_batch(ByteReader &p_reader, WeaponDeltaBatch &r_out) {
	if (p_reader.remaining() > MAX_DELTA_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	WeaponDeltaBatch candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.authority_tick)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_DELTAS_PER_BATCH, /*p_min_bytes_per_entry=*/30)) {
		return p_reader.status();
	}
	candidate.deltas.reserve(count);
	for (std::size_t i = 0; i < count; ++i) {
		WeaponDelta delta;
		Status status = decode_delta(p_reader, delta);
		if (!status.ok()) {
			return status;
		}
		candidate.deltas.push_back(std::move(delta));
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- AcknowledgementBatch ----------------------------------------------------

Status encode_acknowledgement_batch(const AcknowledgementBatch &p_batch, ByteWriter &p_writer) {
	p_writer.write_u16(p_batch.protocol_version);
	p_writer.write_count(p_batch.acknowledgements.size(), MAX_ACKNOWLEDGEMENTS_PER_BATCH);
	for (const DeltaAcknowledgement &ack : p_batch.acknowledgements) {
		p_writer.write_string(ack.instance_id, MAX_IDENTIFIER_BYTES);
		p_writer.write_u64(ack.acknowledged_revision);
	}
	return p_writer.status();
}

Status decode_acknowledgement_batch(ByteReader &p_reader, AcknowledgementBatch &r_out) {
	if (p_reader.remaining() > MAX_DELTA_BYTES) {
		return fail_too_large(p_reader.remaining());
	}
	AcknowledgementBatch candidate;
	if (!p_reader.read_u16(candidate.protocol_version)) {
		return p_reader.status();
	}
	std::size_t count = 0;
	if (!p_reader.read_count(count, MAX_ACKNOWLEDGEMENTS_PER_BATCH, /*p_min_bytes_per_entry=*/8)) {
		return p_reader.status();
	}
	candidate.acknowledgements.reserve(count);
	for (std::size_t i = 0; i < count; ++i) {
		DeltaAcknowledgement ack;
		if (!p_reader.read_string(ack.instance_id, MAX_IDENTIFIER_BYTES)) {
			return p_reader.status();
		}
		if (!p_reader.read_u64(ack.acknowledged_revision)) {
			return p_reader.status();
		}
		candidate.acknowledgements.push_back(std::move(ack));
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

// --- ResyncRequest ------------------------------------------------------

Status encode_resync_request(const ResyncRequest &p_request, ByteWriter &p_writer) {
	p_writer.write_string(p_request.instance_id, MAX_IDENTIFIER_BYTES);
	p_writer.write_u64(p_request.last_applied_revision);
	return p_writer.status();
}

Status decode_resync_request(ByteReader &p_reader, ResyncRequest &r_out) {
	ResyncRequest candidate;
	if (!p_reader.read_string(candidate.instance_id, MAX_IDENTIFIER_BYTES)) {
		return p_reader.status();
	}
	if (!p_reader.read_u64(candidate.last_applied_revision)) {
		return p_reader.status();
	}
	if (!p_reader.at_end()) {
		return fail_trailing(p_reader);
	}
	r_out = std::move(candidate);
	return ok_status();
}

} // namespace wpn::protocol
