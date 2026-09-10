#include "godot/gameplay_ability_network_bridge.h"

#include "core/ga_bytes.h"
#include "core/ga_effect_spec.h"
#include "core/ga_fixed.h"
#include "core/ga_hash.h"
#include "core/ga_limits.h"
#include "core/ga_version.h"
#include "godot/gameplay_ability_godot_util.h"
#include "godot/gameplay_ability_world_coordinator.h"
#include "godot/gameplay_target_value.h"
#include "protocol/gap_messages.h"

#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/classes/multiplayer_peer.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

// This is the ONE place `ActivationCommandWire`/`CommandResultWire`/
// `PresentationEventWire` are encoded and decoded. `native/protocol/`
// deliberately stops at framing and sequencing (see gap_messages.h,
// gap_event_stream.h, gap_resync.h -- every one of those files' "SCOPE SEAM"
// comments says the actual gameplay-content payload is produced/consumed
// OUTSIDE protocol/, by "the component/effects agent's real batch encoder").
// Since ability/effect content lives in `native/core/` and the Godot-facing
// runtime lives here, this bridge is that seam's real implementation for
// activation commands, command results, and cue-forwarding presentation
// events. Every encoder below follows the same canonical rules as
// `native/protocol/` and `native/core/` (little-endian explicit shifts,
// bounded counts checked before reserving, fail closed on any malformed or
// oversized input) even though it lives in native/godot/.
//
// *** Wave 3 (add-granular-delta-replication-2026-07-27) ***: the owning
// client's authoritative EVENT_BATCH payload is now a canonical GRANULAR
// DELTA (`ga::proto::encode_delta_batch`/`gap_delta_messages.h`), not a full
// `ga::AbilityComponent` snapshot -- see `send_owner_event_batch`'s own doc
// comment for the per-peer change-gating/overflow-fallback contract, and
// `_rpc_event_batch`/`apply_owner_delta` for the client-side apply contract.
// SNAPSHOT still carries a full canonical snapshot (first relevance, late
// join, explicit resync, and `ResyncTrigger::DELTA_OVERFLOW` fallback all
// still send one) -- only the routine per-batch owner payload changed
// shape. This satisfies every ordering/atomicity/gap requirement
// gap_event_stream.h/gap_resync.h already enforce exactly as the prior
// full-snapshot payload did (predecessor/batch_end bookkeeping never cared
// what the opaque bytes represent).
//
// *** Wave 4 (add-granular-delta-replication-2026-07-27) ***: observers move
// onto the SAME sequenced-stream machinery owners already have -- an
// independent `public_stream`/`public_cursors` (server side) and
// `public_client_stream` (client side), paralleling `owner_stream`/
// `owner_cursors`/`client_stream` one audience over (see `send_public_state`,
// `send_snapshot_to_peer`'s now-audience-generic producer, and
// `_rpc_snapshot`/`_rpc_event_batch`/`_rpc_heartbeat`'s observer branches).
// The wire baseline switches from the bespoke `encode_public_state()` byte
// layout to `encode_public_baseline()` -- a canonical delta batch (the SAME
// `ga::proto::encode_delta_batch`/`decode_and_apply_delta_batch` codec
// owners' incremental deltas use) whose dirty set is EVERY currently live
// PUBLIC-eligible identity, so `ga::proto::decode_and_apply_delta_batch` is
// the ONE interpreter for both an observer's baseline and every later
// incremental delta, never a second one. The client-side observer
// establishes a scratch core-component mirror (`public_mirror`,
// `GameplayAbilityComponent::build_scratch_mirror()`) that canonical
// baseline/delta application installs onto -- `comp->core_component()`
// itself stays untouched for an observer bridge, preserving this file's
// pre-Wave-4 "never restores anything into the local
// GameplayAbilityComponent" contract for observers (see `set_owner_view()`'s
// own doc comment) -- and re-derives the EXACT SAME `public_state_updated`
// Dictionary shape `decode_public_state()` used to produce from wire bytes,
// now read directly off the mirror's live state
// (`decode_public_state_from_mirror`). `encode_public_state()`/
// `decode_public_state()` themselves are UNCHANGED and still compile (several
// other core/protocol files' doc comments cross-reference their bespoke
// shape by example), just no longer this bridge's own wire path.
//
// *** Deliberate v1 scope reductions (see the task report for the full
// list) ***:
//   - SessionId defaults to the Godot peer id unless the game explicitly
//     calls `begin_session(peer, session)` with a distinct id (a real game
//     is expected to call this once it authenticates a connection -- see
//     the "Server-Controlled Ownership and Permission" requirement; this
//     bridge never invents ownership or a session by itself).
//   - `identifier_dictionary_fingerprint` reuses the same content-manifest
//     fingerprint as `content_manifest_fingerprint` (both already fold
//     every sealed registry's canonical identifier ordering in). A real
//     per-registry identifier-table hash would let a diagnostic distinguish
//     "identifiers differ" from "field values differ" more precisely; this
//     pass does not add that second hash.
//   - Task 7.16 closed the "per-ability target-data schema lookup is not
//     wired to a specific granted ability" gap described above in earlier
//     revisions of this comment, and task 7.20 then moved the actual
//     enforcement onto `GameplayAbilityComponent::validate_target_data_schema`
//     itself -- this bridge's own method of the same name (below) is now a
//     thin delegate to it, kept only so `_rpc_activation_command`'s existing
//     call site did not need to change. That single implementation is now
//     the seam BOTH activation paths enforce the SAME per-ability
//     `GameplayTargetDataSchema` cardinality/byte bounds through: a networked
//     activation (here, at `_rpc_activation_command`) and a direct/offline
//     one (`GameplayAbilityComponent::request_activation`/
//     `process_activation_batch`) can no longer disagree about what one
//     ability's schema allows -- neither path can bypass what the other
//     enforces. Both apply it in addition to (never instead of) the
//     always-enforced GLOBAL `MAX_TARGETS_PER_COMMAND`/`MAX_SET_BY_CALLER`
//     bounds already checked at decode time.
//   - Task 8.11 closed the "PredictionAck/CommandResultWire gap" described in
//     earlier revisions of this comment: `CommandResultWire` now carries
//     `authority_durable_handles` (see that struct's own doc comment), and
//     `feed_prediction_acknowledgement` below zips it, positionally, against
//     this component's OWN journaled temp handles (`ga::PredictingComponent::
//     journal()`) to build `ga::PredictionAck::temp_handles`/
//     `authority_handles` before calling `PredictionReconciler::
//     handle_acknowledgement` -- a predicted cooldown's temporary handle now
//     actually maps to its authoritative counterpart via
//     `PredictionHandleMap`, and `GameplayAbilityComponent::
//     predicted_effect_authority_handle` exposes the result. No protocol
//     version bump: see the task report -- this addon is still pre-1.0 and
//     the field is purely additive with a documented bounded/fail-closed
//     decode, matching `docs/protocol.md`'s own worked precedent.
namespace godot {

namespace {

// ---------------------------------------------------------------------------
// ActivationCommandWire -- client -> server activation intent.
// ---------------------------------------------------------------------------

// Finding 6a: `ActivationCommandWire::input_phase`'s legal range. Determined
// by grepping `input_phase` across the ENTIRE repo (native C++ and every
// GDScript file, incl. tests/examples/docs): the field is written on the
// wire (here) and read back into a Dictionary key on the client send path,
// but NOTHING in this addon today -- no core gameplay code, no GDScript
// consumer, no test, no doc -- actually reads it back out for a decision;
// `docs/spec/changes/add-gameplay-ability-foundation-2026-07-24/specs/
// gameplay-ability-networking/spec.md`'s "Versioned Activation Commands"
// requirement names "declared input phase" as one of a command's required
// fields but never numbers a range. Decoding a bare `std::uint8_t` with no
// bounds at all would accept and forward any of 256 values a future
// consumer has no defined meaning for -- exactly the "trailing/undeclared
// data accepted silently" failure mode this finding is about, just for a
// single scalar field instead of a whole payload. Rather than leave it
// perpetually unbounded, this addon defines the same 3-state
// press/hold/release convention most action-ability systems settle on (a
// tap-vs-charge-vs-release distinction), so a future consumer never has to
// retroactively narrow what already-live wire bytes could already contain:
enum class InputPhase : std::uint8_t {
	PRESSED = 0,
	HELD = 1,
	RELEASED = 2,
};
constexpr std::uint8_t MAX_INPUT_PHASE = static_cast<std::uint8_t>(InputPhase::RELEASED);

struct ActivationCommandWire {
	ga::EntityId component = ga::INVALID_ENTITY_ID;
	ga::AbilitySpecId spec = ga::INVALID_ABILITY_SPEC_ID;
	ga::CommandSeq command_sequence = ga::INVALID_COMMAND_SEQ;
	ga::PredictionKey prediction_key = ga::INVALID_PREDICTION_KEY;
	ga::Tick client_tick = 0; // advisory only -- see ga_tick alignment doc.
	std::uint8_t input_phase = 0; // InputPhase::PRESSED/HELD/RELEASED (0-2) -- see that enum's own doc comment above.
	std::vector<ga::EntityId> targets;
	std::vector<ga::SetByCallerMagnitude> set_by_caller;
};

ga::Status encode_activation_command(const ActivationCommandWire &p_cmd, std::vector<std::uint8_t> &r_out) {
	r_out.clear();
	if (p_cmd.targets.size() > ga::MAX_TARGETS_PER_COMMAND || p_cmd.set_by_caller.size() > ga::MAX_SET_BY_CALLER) {
		return ga::make_status(ga::StatusCode::CAPACITY_EXCEEDED, ga::DiagnosticId::COUNT_LIMIT_EXCEEDED, p_cmd.targets.size());
	}
	ga::ByteWriter writer(ga::proto::message_byte_limit(ga::proto::MessageType::ACTIVATION_COMMAND));
	ga::handle_write(writer, p_cmd.component);
	ga::handle_write(writer, p_cmd.spec);
	ga::handle_write(writer, p_cmd.command_sequence);
	ga::handle_write(writer, p_cmd.prediction_key);
	writer.write_u64(p_cmd.client_tick);
	writer.write_u8(p_cmd.input_phase);
	writer.write_count(p_cmd.targets.size(), ga::MAX_TARGETS_PER_COMMAND);
	for (ga::EntityId target : p_cmd.targets) {
		ga::handle_write(writer, target);
	}
	writer.write_count(p_cmd.set_by_caller.size(), ga::MAX_SET_BY_CALLER);
	for (const ga::SetByCallerMagnitude &magnitude : p_cmd.set_by_caller) {
		writer.write_string(magnitude.field);
		ga::fixed_write(writer, magnitude.value);
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ga::ok_status();
}

ga::Status decode_activation_command(const std::vector<std::uint8_t> &p_bytes, ActivationCommandWire &r_cmd) {
	r_cmd = ActivationCommandWire{};
	ga::ByteReader reader(p_bytes);
	if (!ga::handle_read(reader, r_cmd.component) || !ga::handle_read(reader, r_cmd.spec) ||
			!ga::handle_read(reader, r_cmd.command_sequence) || !ga::handle_read(reader, r_cmd.prediction_key) ||
			!reader.read_u64(r_cmd.client_tick) || !reader.read_u8(r_cmd.input_phase)) {
		return reader.status();
	}
	if (r_cmd.input_phase > MAX_INPUT_PHASE) {
		// Finding 6a: a raw u8 could otherwise smuggle a value this build has
		// no defined meaning for -- reject at decode instead of silently
		// accepting-and-ignoring it (see InputPhase's own doc comment above
		// for the accepted range and how it was determined).
		return ga::make_status(ga::StatusCode::DECODE_FAILED, ga::DiagnosticId::INVALID_ENUM, r_cmd.input_phase);
	}
	std::size_t target_count = 0;
	if (!reader.read_count(target_count, ga::MAX_TARGETS_PER_COMMAND, 8)) {
		return reader.status();
	}
	r_cmd.targets.reserve(target_count);
	for (std::size_t i = 0; i < target_count; ++i) {
		ga::EntityId target;
		if (!ga::handle_read(reader, target)) {
			return reader.status();
		}
		r_cmd.targets.push_back(target);
	}
	std::size_t sbc_count = 0;
	if (!reader.read_count(sbc_count, ga::MAX_SET_BY_CALLER, 3)) {
		return reader.status();
	}
	r_cmd.set_by_caller.reserve(sbc_count);
	for (std::size_t i = 0; i < sbc_count; ++i) {
		ga::SetByCallerMagnitude magnitude;
		if (!reader.read_string(magnitude.field)) {
			return reader.status();
		}
		if (!ga::fixed_read(reader, magnitude.value)) {
			return reader.status();
		}
		r_cmd.set_by_caller.push_back(magnitude);
	}
	// Finding 6a: `at_end()` (not `ok()`) -- trailing bytes after an
	// otherwise-valid payload must fail closed instead of being silently
	// ignored, matching every protocol-layer decoder's own convention (see
	// gap_handshake.cpp's `decode_fields`, gap_event_stream.cpp,
	// gap_resync.cpp, ga_reconciliation.cpp). Deliberately constructs a fresh
	// status here rather than returning `reader.status()`: every individual
	// field read above already succeeded (nothing set `reader`'s own
	// `failed` flag), so `reader.status()` alone would still report
	// `ok_status()` even though unconsumed trailing bytes remain -- exactly
	// the "trailing bytes accepted silently" bug this finding is fixing, not
	// a second copy of it.
	if (!reader.at_end()) {
		return ga::make_status(ga::StatusCode::DECODE_FAILED, ga::DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	return ga::ok_status();
}

// ---------------------------------------------------------------------------
// CommandResultWire -- server -> client ack/reject (same shape for both).
// ---------------------------------------------------------------------------

struct CommandResultWire {
	ga::EntityId component = ga::INVALID_ENTITY_ID;
	ga::CommandSeq command_sequence = ga::INVALID_COMMAND_SEQ;
	ga::PredictionKey prediction_key = ga::INVALID_PREDICTION_KEY;
	ga::ExecutionId execution = ga::INVALID_EXECUTION_ID;
	ga::Status status;
	// Task 8.11: every durable (non-instant) effect handle THIS commit
	// produced that a client's own local prediction of the identical command
	// would also have journaled a temp handle for, in the SAME order
	// `ga::PredictingComponent::predict_full` records them (ga_prediction.cpp)
	// -- today that is exactly "the cooldown effect's handle, if this commit
	// newly applied one" (that function's own SELF_EFFECT_APPLIED op never
	// captures a declared commit effect's handle -- a separate, pre-existing
	// gap this task does not extend; see the file-level comment below). The
	// server never learns, and never sends, a client's TEMP handle value --
	// that is purely client-local bookkeeping the client already has in its
	// own prediction journal; only the AUTHORITY side of the mapping needs
	// to cross the wire at all. The receiving client zips this list,
	// positionally, against its own journaled temp handles (see
	// `GameplayAbilityNetworkBridge::feed_prediction_acknowledgement`).
	// Bounded by `MAX_PENDING_PREDICTIONS`, matching
	// `ga::PredictionAck::authority_handles`'s own documented cap.
	std::vector<ga::EffectHandle> authority_durable_handles;
};

ga::Status encode_command_result(const CommandResultWire &p_result, std::vector<std::uint8_t> &r_out) {
	r_out.clear();
	if (p_result.authority_durable_handles.size() > ga::MAX_PENDING_PREDICTIONS) {
		return ga::make_status(ga::StatusCode::CAPACITY_EXCEEDED, ga::DiagnosticId::COUNT_LIMIT_EXCEEDED, p_result.authority_durable_handles.size());
	}
	ga::ByteWriter writer(ga::proto::message_byte_limit(ga::proto::MessageType::COMMAND_ACK));
	ga::handle_write(writer, p_result.component);
	ga::handle_write(writer, p_result.command_sequence);
	ga::handle_write(writer, p_result.prediction_key);
	ga::handle_write(writer, p_result.execution);
	writer.write_u16(static_cast<std::uint16_t>(p_result.status.code));
	writer.write_u16(static_cast<std::uint16_t>(p_result.status.diagnostic));
	writer.write_u64(p_result.status.detail);
	writer.write_count(p_result.authority_durable_handles.size(), ga::MAX_PENDING_PREDICTIONS);
	for (ga::EffectHandle handle : p_result.authority_durable_handles) {
		ga::handle_write(writer, handle);
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ga::ok_status();
}

ga::Status decode_command_result(const std::vector<std::uint8_t> &p_bytes, CommandResultWire &r_result) {
	r_result = CommandResultWire{};
	ga::ByteReader reader(p_bytes);
	std::uint16_t code = 0;
	std::uint16_t diagnostic = 0;
	std::uint64_t detail = 0;
	if (!ga::handle_read(reader, r_result.component) || !ga::handle_read(reader, r_result.command_sequence) ||
			!ga::handle_read(reader, r_result.prediction_key) || !ga::handle_read(reader, r_result.execution) ||
			!reader.read_u16(code) || !reader.read_u16(diagnostic) || !reader.read_u64(detail)) {
		return reader.status();
	}
	std::size_t handle_count = 0;
	// Each element is one 8-byte handle.
	if (!reader.read_count(handle_count, ga::MAX_PENDING_PREDICTIONS, 8)) {
		return reader.status();
	}
	r_result.authority_durable_handles.reserve(handle_count);
	for (std::size_t i = 0; i < handle_count; ++i) {
		ga::EffectHandle handle;
		if (!ga::handle_read(reader, handle)) {
			return reader.status();
		}
		r_result.authority_durable_handles.push_back(handle);
	}
	// Small decoder bug fix (same class as Finding 6a/6b above): `at_end()`,
	// not `ok()` alone -- every individual field read above already
	// succeeded whenever execution reaches here, so `reader.status()` would
	// still report `ok_status()` even with unconsumed trailing bytes left in
	// `p_bytes`. Constructs an explicit failing status instead of returning
	// `reader.status()` (which would silently accept the trailing garbage),
	// matching `decode_activation_command`/`decode_presentation_event`'s own
	// identical fix in this same file.
	if (!reader.at_end()) {
		return ga::make_status(ga::StatusCode::DECODE_FAILED, ga::DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	r_result.status.code = static_cast<ga::StatusCode>(code);
	r_result.status.diagnostic = static_cast<ga::DiagnosticId>(diagnostic);
	r_result.status.detail = detail;
	return ga::ok_status();
}

// ---------------------------------------------------------------------------
// PresentationEventWire -- server -> client cue forwarding.
// ---------------------------------------------------------------------------

constexpr std::size_t MAX_PRESENTATION_CUE_IDENTIFIERS = 8;

struct PresentationEventWire {
	ga::EntityId component = ga::INVALID_ENTITY_ID;
	ga::GameplayEventId id = ga::INVALID_GAMEPLAY_EVENT_ID;
	ga::EntityId target = ga::INVALID_ENTITY_ID;
	ga::DefinitionId definition = ga::INVALID_DEFINITION_ID;
	std::uint64_t handle = 0;
	std::uint64_t occurrence = 0;
	ga::PredictionKey prediction_key = ga::INVALID_PREDICTION_KEY;
	std::uint8_t phase = 0;
	ga::EntityId source = ga::INVALID_ENTITY_ID;
	ga::Tick tick = 0;
	std::vector<std::string> cue_identifiers;
};

ga::Status encode_presentation_event(const PresentationEventWire &p_event, std::vector<std::uint8_t> &r_out) {
	r_out.clear();
	if (p_event.cue_identifiers.size() > MAX_PRESENTATION_CUE_IDENTIFIERS) {
		return ga::make_status(ga::StatusCode::CAPACITY_EXCEEDED, ga::DiagnosticId::COUNT_LIMIT_EXCEEDED, p_event.cue_identifiers.size());
	}
	ga::ByteWriter writer(ga::proto::message_byte_limit(ga::proto::MessageType::PRESENTATION_EVENT));
	ga::handle_write(writer, p_event.component);
	ga::handle_write(writer, p_event.id);
	ga::handle_write(writer, p_event.target);
	writer.write_u32(p_event.definition);
	writer.write_u64(p_event.handle);
	writer.write_u64(p_event.occurrence);
	ga::handle_write(writer, p_event.prediction_key);
	writer.write_u8(p_event.phase);
	ga::handle_write(writer, p_event.source);
	writer.write_u64(p_event.tick);
	writer.write_count(p_event.cue_identifiers.size(), MAX_PRESENTATION_CUE_IDENTIFIERS);
	for (const std::string &identifier : p_event.cue_identifiers) {
		writer.write_string(identifier);
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_out = writer.take();
	return ga::ok_status();
}

ga::Status decode_presentation_event(const std::vector<std::uint8_t> &p_bytes, PresentationEventWire &r_event) {
	r_event = PresentationEventWire{};
	ga::ByteReader reader(p_bytes);
	if (!ga::handle_read(reader, r_event.component) || !ga::handle_read(reader, r_event.id) ||
			!ga::handle_read(reader, r_event.target) || !reader.read_u32(r_event.definition) ||
			!reader.read_u64(r_event.handle) || !reader.read_u64(r_event.occurrence) ||
			!ga::handle_read(reader, r_event.prediction_key) || !reader.read_u8(r_event.phase) ||
			!ga::handle_read(reader, r_event.source) || !reader.read_u64(r_event.tick)) {
		return reader.status();
	}
	std::size_t count = 0;
	if (!reader.read_count(count, MAX_PRESENTATION_CUE_IDENTIFIERS, 2)) {
		return reader.status();
	}
	r_event.cue_identifiers.reserve(count);
	for (std::size_t i = 0; i < count; ++i) {
		std::string identifier;
		if (!reader.read_string(identifier)) {
			return reader.status();
		}
		r_event.cue_identifiers.push_back(identifier);
	}
	// Finding 6b: same bug class as `decode_activation_command` above --
	// `at_end()`, not `ok()`, and an explicitly-constructed failing status
	// rather than `reader.status()` (which only reflects a field READ that
	// failed, never unconsumed trailing bytes after every declared field
	// parsed fine) -- see that function's own comment for the full
	// reasoning.
	if (!reader.at_end()) {
		return ga::make_status(ga::StatusCode::DECODE_FAILED, ga::DiagnosticId::TRUNCATED_PAYLOAD, reader.consumed());
	}
	return ga::ok_status();
}

// ---------------------------------------------------------------------------
// Public payload composition (Wave 4, add-granular-delta-replication-2026-
// 07-27, tasks 3.3/4.2).
// ---------------------------------------------------------------------------

// Combines the canonical PUBLIC delta-batch bytes (`ga::proto::
// encode_delta_batch`, covering ATTRIBUTE/TAG_SOURCE/ABILITY_GRANT only) with
// an OPTIONAL observer-task section (`ga::proto::encode_observer_task_
// section`) into ONE opaque wire payload -- see `GameplayAbilityNetworkBridge
// ::build_full_public_dirty`'s own doc comment (gameplay_ability_network_
// bridge.h) for why ABILITY_TASK content cannot ride the canonical delta
// section itself for this audience. Layout: a 4-byte little-endian length
// for the delta portion, that many delta bytes, then EITHER nothing
// (`p_task_section_bytes == nullptr`: no task changed since the receiver's
// last update, so its own confirmed task list stays untouched) or the
// remaining bytes are `p_task_section_bytes`'s own content verbatim. Bridge-
// local framing only -- never its own `ga::proto::MessageType`, exactly like
// `encode_public_state()`'s own bespoke shape before it; this rides inside
// the SAME `SnapshotEnvelope`/`EVENT_BATCH` opaque payload either format
// always has.
std::vector<std::uint8_t> compose_public_payload(const std::vector<std::uint8_t> &p_delta_bytes, const std::vector<std::uint8_t> *p_task_section_bytes) {
	std::vector<std::uint8_t> out;
	out.reserve(4 + p_delta_bytes.size() + (p_task_section_bytes != nullptr ? p_task_section_bytes->size() : 0));
	const std::uint32_t delta_len = static_cast<std::uint32_t>(p_delta_bytes.size());
	out.push_back(std::uint8_t(delta_len & 0xFF));
	out.push_back(std::uint8_t((delta_len >> 8) & 0xFF));
	out.push_back(std::uint8_t((delta_len >> 16) & 0xFF));
	out.push_back(std::uint8_t((delta_len >> 24) & 0xFF));
	out.insert(out.end(), p_delta_bytes.begin(), p_delta_bytes.end());
	if (p_task_section_bytes != nullptr) {
		out.insert(out.end(), p_task_section_bytes->begin(), p_task_section_bytes->end());
	}
	return out;
}

// The matching split, untrusted-input convention (matching every other
// decoder in this file): fails closed (returns `false`, out-params left
// untouched) if `p_payload` is shorter than the 4-byte length prefix, or if
// the declared delta length exceeds the bytes actually remaining.
// `r_has_task_section` is true iff any bytes remain after the delta portion.
bool decompose_public_payload(const std::vector<std::uint8_t> &p_payload, std::vector<std::uint8_t> &r_delta_bytes,
		std::vector<std::uint8_t> &r_task_section_bytes, bool &r_has_task_section) {
	if (p_payload.size() < 4) {
		return false;
	}
	const std::uint32_t delta_len = std::uint32_t(p_payload[0]) | (std::uint32_t(p_payload[1]) << 8) |
			(std::uint32_t(p_payload[2]) << 16) | (std::uint32_t(p_payload[3]) << 24);
	if (std::size_t(delta_len) > p_payload.size() - 4) {
		return false;
	}
	r_delta_bytes.assign(p_payload.begin() + 4, p_payload.begin() + 4 + std::ptrdiff_t(delta_len));
	const std::size_t remaining = p_payload.size() - 4 - std::size_t(delta_len);
	r_has_task_section = remaining > 0;
	if (r_has_task_section) {
		r_task_section_bytes.assign(p_payload.end() - std::ptrdiff_t(remaining), p_payload.end());
	} else {
		r_task_section_bytes.clear();
	}
	return true;
}

} // namespace

// ---------------------------------------------------------------------------
// GameplayAbilityNetworkBridge
// ---------------------------------------------------------------------------

GameplayAbilityNetworkBridge::GameplayAbilityNetworkBridge() {}
GameplayAbilityNetworkBridge::~GameplayAbilityNetworkBridge() {}

void GameplayAbilityNetworkBridge::set_component_path(const NodePath &p_path) {
	if (component_path == p_path) {
		return;
	}
	component_path = p_path;
	// Task 7.17: `_ready()` used to be the ONLY place this bridge ever tried
	// to wire itself to its component, exactly once, at whatever
	// `component_path` happened to be at that moment. The natural
	// `add_child(bridge); bridge.set_component_path(...)` order means
	// `component_path` is still empty when `_ready()` runs, so cue
	// forwarding, `set_multiplayer_authority(1)`, and the client handshake
	// were silently and permanently skipped -- no error, no signal, nothing
	// to observe. Re-resolving HERE (whenever the property changes) closes
	// that gap: if this node is already inside the tree, wiring happens
	// immediately; otherwise `_ready()` still performs it once entering the
	// tree, matching the ORIGINAL order (`set_component_path` before
	// `add_child`) that already worked.
	if (wired && wired_component != nullptr) {
		// The path now names a DIFFERENT node (or none at all): forget the
		// old wiring so `try_wire_component()` below re-wires cleanly rather
		// than silently forwarding a now-unrelated component's cues forever.
		const Callable cue_callable = callable_mp(this, &GameplayAbilityNetworkBridge::on_effect_cue_triggered);
		if (wired_component->is_connected("effect_cue_triggered", cue_callable)) {
			wired_component->disconnect("effect_cue_triggered", cue_callable);
		}
	}
	wired = false;
	wired_component = nullptr;
	unresolved_diagnostic_sent = false;
	// Review fix (Wave 4, add-granular-delta-replication-2026-07-27): every
	// piece of PUBLIC-audience state this wave added is either a raw pointer/
	// reference INTO whatever component was served at the time it was built,
	// or bookkeeping keyed to that component's own identity -- neither
	// survives the path now naming a different node (or none at all).
	//   - `public_mirror` was built by `GameplayAbilityComponent::
	//     build_scratch_mirror()` capturing the OLD component's registries BY
	//     REFERENCE (see that method's own doc comment); if the old node is
	//     freed, the next observer delta apply (`apply_public_delta`, guarded
	//     only by `public_mirror == nullptr`) would be a use-after-free --
	//     same bug class as the coordinator's own `restore_snapshot` UAF this
	//     file already fixes elsewhere. Even if the old node survives, the
	//     mirror would silently disagree with whatever component is served
	//     now. Discarding it here is required, not merely tidy.
	//   - `confirmed_observable_tasks` is confirmed PUBLIC state for the OLD
	//     component; carrying it forward would let a stale task survive in
	//     `public_state_updated` until the new component happens to touch
	//     ABILITY_TASK itself.
	//   - `public_client_stream` is entity-locked to whichever component it
	//     was constructed against (`ensure_public_client_state()` builds it
	//     ONCE, from `resolve_component()`'s entity id, and only when null) --
	//     left alone, `apply_snapshot_envelope`'s own component-identity check
	//     would permanently reject every future baseline for the new
	//     component. Reset to null (not merely quarantined) so
	//     `ensure_public_client_state()` rebuilds it fresh, bound to whatever
	//     resolves next.
	public_mirror.reset();
	confirmed_observable_tasks.clear();
	public_client_stream.reset();
	// Server-side counterparts, for the SAME reason one level up: `public_
	// stream` is entity-locked exactly like `public_client_stream` (its
	// owning `EntityId` is fixed by its first `append_batch` call and never
	// changes thereafter -- see `AuthoritativeEventStream`'s own class
	// comment), so left alone it would fail closed forever for a
	// differently-identified new component; reset to null so `ensure_server_
	// state()` rebuilds it unlocked. `public_cursors`' revisions are only
	// meaningful relative to the OLD component's own `ChangeTracker` --
	// stale entries would skip a peer's mandatory first-relevance baseline
	// for the new component (`send_public_state` only treats a MISSING map
	// entry as "never synced"), so the map is cleared outright rather than
	// left to compare a foreign revision number.
	public_stream.reset();
	public_cursors.clear();
	// Review fix (Wave 5, owner-side invalidation audit): the OWNER-audience
	// counterparts to every PUBLIC-audience reset above -- see each member's
	// own doc comment (gameplay_ability_network_bridge.h: `owner_stream`,
	// `owner_cursors`, `synced_peers`, `client_stream`,
	// `last_confirmed_snapshot`) for exactly why each one is unsafe to leave
	// behind across a repoint; this was a pre-existing gap Wave 4's own fix
	// above explicitly did not touch.
	owner_stream.reset();
	owner_cursors.clear();
	synced_peers.clear();
	client_stream.reset();
	last_confirmed_snapshot.clear();
	last_confirmed_target_snapshot.clear();
	if (is_inside_tree()) {
		try_wire_component();
	}
}

GameplayAbilityComponent *GameplayAbilityNetworkBridge::resolve_component() {
	if (component_path.is_empty()) {
		component = nullptr;
		return nullptr;
	}
	component = get_node<GameplayAbilityComponent>(component_path);
	return component;
}

const GameplayAbilityComponent *GameplayAbilityNetworkBridge::resolve_component() const {
	if (component_path.is_empty()) {
		return nullptr;
	}
	return get_node<GameplayAbilityComponent>(component_path);
}

GameplayAbilityWorldCoordinator *
GameplayAbilityNetworkBridge::resolve_world_coordinator() {
	if (world_coordinator_path.is_empty()) {
		return nullptr;
	}
	return get_node<GameplayAbilityWorldCoordinator>(
			world_coordinator_path);
}

const GameplayAbilityWorldCoordinator *
GameplayAbilityNetworkBridge::resolve_world_coordinator() const {
	if (world_coordinator_path.is_empty()) {
		return nullptr;
	}
	return get_node<GameplayAbilityWorldCoordinator>(
			world_coordinator_path);
}

std::uint32_t GameplayAbilityNetworkBridge::effective_tick_rate() const {
	const GameplayAbilityComponent *comp = resolve_component();
	if (comp != nullptr && comp->is_configured()) {
		return std::uint32_t(comp->get_tick_rate());
	}
	return std::uint32_t(tick_rate);
}

void GameplayAbilityNetworkBridge::wire_multiplayer_signals() {
	const Ref<MultiplayerAPI> api = get_multiplayer();
	if (!api.is_valid()) {
		return;
	}
	if (wired_multiplayer_api.is_valid() &&
			wired_multiplayer_api.ptr() != api.ptr()) {
		unwire_multiplayer_signals();
	}
	wired_multiplayer_api = api;

	// These are deliberately ordinary object/method Callables rather than
	// callable_mp custom callables. Godot stores this shape by ObjectID, so
	// it remains safe even if an earlier callback in the same transport
	// signal frees this bridge while the emitter is still iterating a copied
	// connection list. Explicit unwiring below still removes the steady-
	// state connections and prevents stale entries from accumulating.
	const Callable server_disconnected_callable(
			this, StringName("_on_server_disconnected"));
	const Callable peer_disconnected_callable(
			this, StringName("_on_peer_disconnected"));
	const Callable connected_to_server_callable(
			this, StringName("_on_connected_to_server"));
	const Callable peer_connected_callable(
			this, StringName("_on_peer_connected"));

	if (!api->is_connected("server_disconnected",
				server_disconnected_callable)) {
		api->connect("server_disconnected",
				server_disconnected_callable);
	}
	if (!api->is_connected("peer_disconnected",
				peer_disconnected_callable)) {
		api->connect("peer_disconnected", peer_disconnected_callable);
	}
	if (!api->is_connected("connected_to_server",
				connected_to_server_callable)) {
		api->connect("connected_to_server",
				connected_to_server_callable);
	}
	if (!api->is_connected("peer_connected", peer_connected_callable)) {
		api->connect("peer_connected", peer_connected_callable);
	}
}

void GameplayAbilityNetworkBridge::unwire_multiplayer_signals() {
	// Copy the Ref first so disconnecting remains safe even if a callback
	// releases the bridge's member during signal teardown. Clear the member
	// up front to make this helper harmless under EXIT_TREE followed by
	// PREDELETE.
	const Ref<MultiplayerAPI> api = wired_multiplayer_api;
	wired_multiplayer_api.unref();
	if (!api.is_valid()) {
		return;
	}

	const Callable server_disconnected_callable(
			this, StringName("_on_server_disconnected"));
	const Callable peer_disconnected_callable(
			this, StringName("_on_peer_disconnected"));
	const Callable connected_to_server_callable(
			this, StringName("_on_connected_to_server"));
	const Callable peer_connected_callable(
			this, StringName("_on_peer_connected"));
	if (api->is_connected("server_disconnected",
				server_disconnected_callable)) {
		api->disconnect("server_disconnected",
				server_disconnected_callable);
	}
	if (api->is_connected("peer_disconnected",
				peer_disconnected_callable)) {
		api->disconnect("peer_disconnected", peer_disconnected_callable);
	}
	if (api->is_connected("connected_to_server",
				connected_to_server_callable)) {
		api->disconnect("connected_to_server",
				connected_to_server_callable);
	}
	if (api->is_connected("peer_connected", peer_connected_callable)) {
		api->disconnect("peer_connected", peer_connected_callable);
	}
}

void GameplayAbilityNetworkBridge::try_wire_component() {
	if (wired) {
		return; // already wired to the currently-resolved component -- never double-connect.
	}
	if (!is_inside_tree()) {
		return; // multiplayer/signal state only makes sense once in the tree; _ready() or the next set_component_path() retries.
	}
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return; // still unresolved -- nothing to wire yet; see diagnose_unresolved_component() for the on-demand-caller diagnostic.
	}
	if (comp->get_role() != GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		set_multiplayer_authority(1);
	}
	comp->connect("effect_cue_triggered", callable_mp(this, &GameplayAbilityNetworkBridge::on_effect_cue_triggered));
	// Findings 2c/3a: wire the disconnect and (re)connect reactions together
	// against the exact branch API retained by `wire_multiplayer_signals()`.
	// Only a client role predicts or initiates a handshake.
	if (comp->get_role() ==
			GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		wire_multiplayer_signals();
	}
	if (comp->get_role() == GameplayAbilityComponent::ROLE_NETWORK_CLIENT && is_multiplayer_active()) {
		send_handshake_request();
	}
	// Wave 3: the component now exists to push a visibility config into --
	// carry over whatever hidden_* lists a caller already set (property or
	// setter, possibly before this bridge ever resolved a component). Never
	// a resync notification here: nothing has been sent to any peer yet for
	// THIS wiring, so there is nothing to invalidate (see
	// `sync_visibility_config`'s own doc comment).
	sync_visibility_config(false);
	wired = true;
	wired_component = comp;
	unresolved_diagnostic_sent = false;
}

void GameplayAbilityNetworkBridge::diagnose_unresolved_component() {
	if (unresolved_diagnostic_sent) {
		return; // bounded: at most one diagnostic per unresolved streak, not one per call/tick.
	}
	unresolved_diagnostic_sent = true;
	emit_signal("network_diagnostic", status_dict(ga::make_status(ga::StatusCode::NOT_FOUND)));
}

// ---------------------------------------------------------------------------
// Visibility seam (Wave 3, add-granular-delta-replication-2026-07-27)
// ---------------------------------------------------------------------------

void GameplayAbilityNetworkBridge::set_hidden_attribute_identifiers(const PackedStringArray &p_ids) {
	hidden_attributes = p_ids;
	sync_visibility_config(true);
}

void GameplayAbilityNetworkBridge::set_hidden_tag_identifiers(const PackedStringArray &p_ids) {
	hidden_tags = p_ids;
	sync_visibility_config(true);
}

void GameplayAbilityNetworkBridge::set_hidden_ability_identifiers(const PackedStringArray &p_ids) {
	hidden_abilities = p_ids;
	sync_visibility_config(true);
}

void GameplayAbilityNetworkBridge::sync_visibility_config(bool p_notify_resync) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->core_component() == nullptr) {
		return; // not yet resolved -- try_wire_component()'s own call retries once it is.
	}
	ga::AudienceVisibilityConfig &config = comp->core_component()->visibility_config();

	std::set<ga::DefinitionId> new_hidden_attributes;
	for (int i = 0; i < hidden_attributes.size(); ++i) {
		const ga::DefinitionId id = comp->resolve_attribute_definition_id(to_std(hidden_attributes[i]));
		if (id != ga::INVALID_DEFINITION_ID) {
			new_hidden_attributes.insert(id);
		}
	}
	std::set<ga::DefinitionId> new_hidden_tags;
	for (int i = 0; i < hidden_tags.size(); ++i) {
		const ga::DefinitionId id = comp->resolve_tag_definition_id(to_std(hidden_tags[i]));
		if (id != ga::INVALID_DEFINITION_ID) {
			new_hidden_tags.insert(id);
		}
	}
	std::set<ga::DefinitionId> new_hidden_abilities;
	for (int i = 0; i < hidden_abilities.size(); ++i) {
		const ga::DefinitionId id = comp->resolve_ability_definition_id(to_std(hidden_abilities[i]));
		if (id != ga::INVALID_DEFINITION_ID) {
			new_hidden_abilities.insert(id);
		}
	}

	const bool changed = config.hidden_attributes != new_hidden_attributes ||
			config.hidden_tags != new_hidden_tags ||
			config.hidden_abilities != new_hidden_abilities;
	config.hidden_attributes = std::move(new_hidden_attributes);
	config.hidden_tags = std::move(new_hidden_tags);
	config.hidden_abilities = std::move(new_hidden_abilities);

	if (changed && p_notify_resync) {
		// `force_full_resync()` advances BOTH audiences (see that method's
		// own doc comment) -- a peer's already-sent PUBLIC view may now
		// include/omit a record this boundary just moved, and there is no
		// per-record way to say which without re-deriving the whole diff,
		// so every synced peer of every audience is treated as stale.
		comp->core_component()->change_tracker().force_full_resync();
	}
}

void GameplayAbilityNetworkBridge::ensure_server_state() {
	if (ownership == nullptr) {
		ownership = std::make_unique<ga::proto::OwnershipTable>();
	}
	if (sequence == nullptr) {
		sequence = std::make_unique<ga::proto::CommandSequenceTracker>();
	}
	if (rate_limiter == nullptr) {
		rate_limiter = std::make_unique<ga::proto::RateLimiter>();
	}
	if (strikes == nullptr) {
		strikes = std::make_unique<ga::proto::DefaultStrikePolicy>();
	}
	if (gate == nullptr) {
		gate = std::make_unique<ga::proto::CommandGate>(*ownership, *sequence, *rate_limiter, strikes.get());
	}
	if (owner_stream == nullptr) {
		owner_stream = std::make_unique<ga::proto::AuthoritativeEventStream>();
	}
	// Wave 4 (task 3.3): the PUBLIC audience's own independent stream -- see
	// this member's own doc comment (gameplay_ability_network_bridge.h).
	if (public_stream == nullptr) {
		public_stream = std::make_unique<ga::proto::AuthoritativeEventStream>();
	}
	if (resync_coordinator == nullptr) {
		resync_coordinator = std::make_unique<ga::proto::ResyncCoordinator>(*rate_limiter, strikes.get());
	}
}

void GameplayAbilityNetworkBridge::ensure_client_state() {
	if (client_stream == nullptr) {
		const GameplayAbilityComponent *comp = resolve_component();
		const std::uint64_t entity = comp != nullptr ? std::uint64_t(comp->get_entity_id()) : 0;
		client_stream = std::make_unique<ga::proto::ClientEventStream>(ga::EntityId{ entity });
	}
}

void GameplayAbilityNetworkBridge::ensure_public_client_state() {
	if (public_client_stream == nullptr) {
		const GameplayAbilityComponent *comp = resolve_component();
		const std::uint64_t entity = comp != nullptr ? std::uint64_t(comp->get_entity_id()) : 0;
		public_client_stream = std::make_unique<ga::proto::ClientEventStream>(ga::EntityId{ entity });
	}
}

bool GameplayAbilityNetworkBridge::is_multiplayer_active() const {
	const Ref<MultiplayerAPI> api = get_multiplayer();
	if (!api.is_valid()) {
		return false;
	}
	// Godot's SceneTree always exposes a default MultiplayerAPI with an
	// implicit local peer object -- both has_multiplayer_peer() and
	// get_multiplayer_peer() report non-null even with zero network setup
	// (confirmed empirically against the installed Godot 4.7.1 engine), so
	// neither alone distinguishes "really connected" from "untouched
	// default, offline". A non-empty peer list is the reliable signal: it
	// is only non-empty once a real MultiplayerPeer has actually connected
	// to (or accepted a connection from) another endpoint.
	return api->has_multiplayer_peer() && !api->get_peers().is_empty();
}

// Structural debt fix: see this method's own header doc comment
// (gameplay_ability_network_bridge.h) for the full contract. `r_header`/
// `r_payload` are populated whenever `decode_message` itself succeeds, even
// if the type check below then fails -- `_rpc_command_result` relies on
// this to accept either of COMMAND_ACK/COMMAND_REJECT from a single call.
bool GameplayAbilityNetworkBridge::decode_framed(const PackedByteArray &p_bytes, ga::proto::MessageType p_expected,
		ga::proto::MessageHeader &r_header, std::vector<std::uint8_t> &r_payload) {
	if (!ga::proto::decode_message(from_packed(p_bytes), ga::proto::message_byte_limit(p_expected), r_header, r_payload).ok()) {
		return false;
	}
	return r_header.message_type == p_expected;
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

ga::proto::HandshakeRequest GameplayAbilityNetworkBridge::build_local_handshake() const {
	ga::proto::HandshakeRequest req;
	req.protocol_version = ga::protocol_version();
	req.api_version_major = std::uint8_t(ga::api_version_major());
	req.api_version_minor = std::uint8_t(ga::api_version_minor());
	req.api_version_patch = std::uint8_t(ga::api_version_patch());
	req.required_features = ga::supported_features();
	// Task 7.19: the served component's own tick rate once resolved -- the
	// SAME value its manifest fingerprint was built with -- rather than this
	// bridge's independently-settable bootstrap property; see
	// effective_tick_rate()'s doc comment.
	req.tick_rate = effective_tick_rate();
	req.fixed_point_scale = ga::FIXED_SCALE;
	const GameplayAbilityComponent *comp = resolve_component();
	const std::uint64_t fingerprint = comp != nullptr ? std::uint64_t(comp->get_content_manifest_fingerprint()) : 0;
	// v1 simplification: identifier-dictionary and content-manifest
	// fingerprints share one value -- see file comment.
	req.identifier_dictionary_fingerprint = fingerprint;
	req.content_manifest_fingerprint = fingerprint;
	req.max_command_packet_bytes = std::uint32_t(ga::MAX_COMMAND_PACKET_BYTES);
	req.max_event_batch_bytes = std::uint32_t(ga::MAX_EVENT_BATCH_BYTES);
	req.max_snapshot_bytes = std::uint32_t(ga::MAX_SNAPSHOT_BYTES);
	req.max_handshake_bytes = std::uint32_t(ga::MAX_HANDSHAKE_BYTES);
	req.manifest_algorithm = ga::GA_MANIFEST_ALGORITHM;
	return req;
}

void GameplayAbilityNetworkBridge::send_handshake_request() {
	if (!is_multiplayer_active()) {
		return;
	}
	const ga::proto::HandshakeRequest request = build_local_handshake();
	std::vector<std::uint8_t> payload;
	if (!ga::proto::encode_handshake_request(request, payload).ok()) {
		return;
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::HANDSHAKE_REQUEST, ga::proto::SessionId(local_session_id),
				 payload, ga::proto::message_byte_limit(ga::proto::MessageType::HANDSHAKE_REQUEST), framed)
					 .ok()) {
		return;
	}
	rpc_id(server_peer_id, "_rpc_handshake_request", to_packed(framed));
}

void GameplayAbilityNetworkBridge::_rpc_handshake_request(const PackedByteArray &p_bytes) {
	const GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->get_role() == GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int32_t peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	if (peer == 0) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::HANDSHAKE_REQUEST, header, payload)) {
		return;
	}
	ga::proto::HandshakeRequest remote;
	if (!ga::proto::decode_handshake_request(payload, remote).ok()) {
		return;
	}

	const ga::proto::HandshakeRequest local = build_local_handshake();
	ga::proto::HandshakeResult result;
	ga::proto::evaluate_handshake(remote, local, result);
	if (result.compatible) {
		handshake_ok_peers.insert(peer);
	} else {
		handshake_ok_peers.erase(peer);
	}

	// Structural debt fix: `HandshakeRequest`/`HandshakeResponse` are
	// layout-identical (see gap_handshake.h) -- `to_response` replaces what
	// used to be a hand-copied 13-field block here.
	const ga::proto::HandshakeResponse response = ga::proto::to_response(local);

	std::vector<std::uint8_t> response_payload;
	if (!ga::proto::encode_handshake_response(response, response_payload).ok()) {
		return;
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::HANDSHAKE_RESPONSE, ga::proto::SessionId(local_session_id),
				 response_payload, ga::proto::message_byte_limit(ga::proto::MessageType::HANDSHAKE_RESPONSE), framed)
					 .ok()) {
		return;
	}
	rpc_id(peer, "_rpc_handshake_response", to_packed(framed));
}

void GameplayAbilityNetworkBridge::_rpc_handshake_response(const PackedByteArray &p_bytes) {
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::HANDSHAKE_RESPONSE, header, payload)) {
		return;
	}
	ga::proto::HandshakeResponse remote;
	if (!ga::proto::decode_handshake_response(payload, remote).ok()) {
		return;
	}
	// Structural debt fix: `to_request` replaces what used to be a
	// hand-copied 13-field block reconstituting a request-shaped value from
	// a received response so `evaluate_handshake` (which always compares two
	// `HandshakeRequest`s) can run from this side too.
	const ga::proto::HandshakeRequest remote_as_request = ga::proto::to_request(remote);

	const ga::proto::HandshakeRequest local = build_local_handshake();
	ga::proto::HandshakeResult result;
	ga::proto::evaluate_handshake(remote_as_request, local, result);
	handshake_ok = result.compatible;

	Dictionary d;
	d["compatible"] = result.compatible;
	d["reason"] = int(result.reason);
	d["status"] = status_dict(result.status);
	emit_signal("handshake_completed", d);
}

// ---------------------------------------------------------------------------
// Session / ownership
// ---------------------------------------------------------------------------

void GameplayAbilityNetworkBridge::begin_session(int p_peer, int p_session) {
	ensure_server_state();
	peer_sessions[p_peer] = p_session;
	ownership->begin_session(ga::proto::PeerId(p_peer), ga::proto::SessionId(p_session));
}

void GameplayAbilityNetworkBridge::end_session(int p_peer) {
	ensure_server_state();
	peer_sessions.erase(p_peer);
	ownership->end_session(ga::proto::PeerId(p_peer));
}

bool GameplayAbilityNetworkBridge::authorize_control(int p_peer, int64_t p_entity) {
	ensure_server_state();
	return ownership->authorize_control(ga::proto::PeerId(p_peer), ga::EntityId{ std::uint64_t(p_entity) }).ok();
}

bool GameplayAbilityNetworkBridge::revoke_control(int p_peer, int64_t p_entity) {
	ensure_server_state();
	return ownership->revoke_control(ga::proto::PeerId(p_peer), ga::EntityId{ std::uint64_t(p_entity) }).ok();
}

bool GameplayAbilityNetworkBridge::authorize_server_entity(int64_t p_entity) {
	ensure_server_state();
	return ownership->authorize_server_entity(ga::EntityId{ std::uint64_t(p_entity) }).ok();
}

void GameplayAbilityNetworkBridge::drop_peer(int p_peer) {
	ensure_server_state();
	ownership->drop_peer(ga::proto::PeerId(p_peer));
	sequence->drop_session(ga::proto::SessionId(peer_sessions.count(p_peer) ? peer_sessions[p_peer] : p_peer));
	rate_limiter->drop_peer(ga::proto::PeerId(p_peer));
	if (strikes) {
		strikes->drop_peer(ga::proto::PeerId(p_peer));
	}
	peer_sessions.erase(p_peer);
	handshake_ok_peers.erase(p_peer);
	synced_peers.erase(p_peer);
	// Wave 3: bounded per-peer replication bookkeeping -- a dropped peer, if
	// it reconnects, is treated as never-synced again (exactly like
	// `synced_peers.erase` above), so its old cursor must not linger.
	owner_cursors.erase(p_peer);
	public_cursors.erase(p_peer);
}

bool GameplayAbilityNetworkBridge::peer_is_owner(int p_peer) const {
	const GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || ownership == nullptr) {
		return false;
	}
	return ownership->validate_control(ga::proto::PeerId(p_peer), ga::EntityId{ std::uint64_t(comp->get_entity_id()) }).ok();
}

PackedInt32Array GameplayAbilityNetworkBridge::current_relevant_peers() const {
	// Task 7.18: explicit "nobody" wins unconditionally -- never falls
	// through to the connected-peer default. See `set_no_relevant_peers()`.
	if (relevant_peers_none) {
		return PackedInt32Array();
	}
	if (!relevant_peer_override.is_empty()) {
		return relevant_peer_override;
	}
	const Ref<MultiplayerAPI> api = get_multiplayer();
	return api.is_valid() ? api->get_peers() : PackedInt32Array();
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

Dictionary GameplayAbilityNetworkBridge::request_activation_networked(const Dictionary &p_request, int64_t p_client_tick) {
	Dictionary result;
	try_wire_component(); // on-demand: complete deferred wiring if a prior _ready()/set_component_path() could not yet.
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		diagnose_unresolved_component();
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		result["sent"] = false;
		return result;
	}
	if (!comp->is_configured()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED));
		result["sent"] = false;
		return result;
	}

	if (comp->get_role() != GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		// "Offline game runs without a peer": validate/execute locally, no
		// packets, no prediction entries.
		result = comp->request_activation(p_request, p_client_tick);
		result["sent"] = false;
		return result;
	}

	// NETWORK_CLIENT: "Client bridge has no active peer" scenario -- never
	// silently becomes authority.
	if (!is_multiplayer_active()) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::NETWORK_UNAVAILABLE));
		result["sent"] = false;
		return result;
	}

	const ga::Tick client_tick = ga::Tick(p_client_tick < 0 ? 0 : p_client_tick);

	// Task 8.10: try local prediction FIRST, through the served component's
	// OWN `ga::PredictingComponent` (never a second, bridge-local prediction
	// layer). A PREDICTED outcome overrides the wire command's own
	// command_sequence/prediction_key with the journal-allocated pair --
	// NEVER the caller-supplied ones (`ga::PredictingComponent::predict_full`
	// always allocates fresh values) -- so a later `command_acknowledged`/
	// `command_rejected` can find the SAME pending journal entry.
	//
	// Gated on the caller NOT already supplying its own `prediction_key`: a
	// caller that already ran its own predicted `request_activation(...,
	// PROVENANCE_PREDICTED)` (composing directly against the existing
	// `request_activation`/`notify_prediction_phase` seams -- a legitimate,
	// pre-8.10-documented pattern this bridge must not break) and then calls
	// this method purely to transmit the already-decided command is asking
	// to be a thin pass-through, exactly like before this task; re-predicting
	// here would activate the SAME ability a second time. Passing no
	// `prediction_key` (or 0/INVALID_PREDICTION_KEY) is how a caller opts
	// INTO this method doing the prediction itself.
	ga::CommandSeq wire_sequence{ std::uint64_t(int64_t(p_request.get("command_sequence", 0))) };
	ga::PredictionKey wire_prediction_key{ std::uint64_t(int64_t(p_request.get("prediction_key", 0))) };
	int prediction_mode = int(ga::PredictionMode::NOT_PREDICTED_NO_BASELINE);
	const bool caller_already_predicted = wire_prediction_key != ga::INVALID_PREDICTION_KEY;

	// Finding 6c/6d: the request Dictionary is validated/converted through
	// `build_activation_request` -- the ONE shared, fail-closed converter
	// (Finding 6d unified its overflow policy across every call site in this
	// addon) -- EXACTLY ONCE, for EVERY networked send, predicted or not.
	// Before this fix, a `build_activation_request` FAILURE (oversized
	// targets/set_by_caller, or a set_by_caller value that fails fixed-point
	// quantization) still fell through to a second, hand-rolled conversion
	// straight off the raw Dictionary below that silently TRUNCATED to
	// MAX_TARGETS_PER_COMMAND/MAX_SET_BY_CALLER and zeroed failed
	// quantizations instead of rejecting -- e.g. a 17-target request would
	// mutate the first 16 targets server-side rather than being refused.
	// Fail closed instead: nothing is sent, and the wire command below is
	// built from THIS validated `core_request`, never from `p_request` a
	// second time.
	ga::ActivationRequest core_request;
	if (!comp->build_activation_request(p_request, core_request)) {
		result["status"] = status_dict(ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		result["sent"] = false;
		return result;
	}

	ga::PredictingComponent *predicting = caller_already_predicted ? nullptr : comp->predicting_component();
	if (predicting != nullptr) {
		ensure_client_state();
		const ga::PredictionOutcome outcome = predicting->request(core_request, client_tick, *client_stream);
		prediction_mode = int(outcome.mode);
		if (outcome.mode == ga::PredictionMode::PREDICTED) {
			if (!outcome.status.ok()) {
				// The REAL local activation was itself rejected (e.g.
				// locally-stale cost/cooldown/tag state) -- nothing was
				// journaled as pending (PredictionOutcome's own doc
				// comment), so sending this to the server would just
				// exercise the SAME deterministic state machine for the
				// SAME rejection. Return it immediately instead of
				// spending a round trip on a foregone conclusion.
				result["status"] = status_dict(outcome.status);
				result["sent"] = false;
				result["prediction_mode"] = prediction_mode;
				return result;
			}
			wire_sequence = outcome.command_sequence;
			wire_prediction_key = outcome.prediction_key;
		}
	}

	ActivationCommandWire wire;
	wire.component = ga::EntityId{ std::uint64_t(comp->get_entity_id()) };
	wire.spec = core_request.spec;
	wire.command_sequence = wire_sequence;
	wire.prediction_key = wire_prediction_key;
	wire.client_tick = client_tick;
	wire.input_phase = std::uint8_t(int(p_request.get("input_phase", 0)));
	wire.targets = core_request.targets;
	wire.set_by_caller = core_request.set_by_caller;

	std::vector<std::uint8_t> payload;
	const ga::Status encode_status = encode_activation_command(wire, payload);
	if (!encode_status.ok()) {
		result["status"] = status_dict(encode_status);
		result["sent"] = false;
		result["prediction_mode"] = prediction_mode;
		return result;
	}
	std::vector<std::uint8_t> framed;
	const ga::Status frame_status = ga::proto::encode_message(ga::proto::MessageType::ACTIVATION_COMMAND,
			ga::proto::SessionId(local_session_id), payload, ga::proto::message_byte_limit(ga::proto::MessageType::ACTIVATION_COMMAND), framed);
	if (!frame_status.ok()) {
		result["status"] = status_dict(frame_status);
		result["sent"] = false;
		result["prediction_mode"] = prediction_mode;
		return result;
	}

	rpc_id(server_peer_id, "_rpc_activation_command", to_packed(framed));
	result["status"] = status_dict(ga::ok_status());
	result["sent"] = true;
	result["prediction_mode"] = prediction_mode;
	return result;
}

ga::Status GameplayAbilityNetworkBridge::send_activation_command(const ga::ActivationRequest &p_request,
		ga::CommandSeq p_sequence, ga::PredictionKey p_key, ga::Tick p_client_tick) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return ga::make_status(ga::StatusCode::NOT_SUPPORTED);
	}
	ActivationCommandWire wire;
	wire.component = ga::EntityId{ std::uint64_t(comp->get_entity_id()) };
	wire.spec = p_request.spec;
	wire.command_sequence = p_sequence;
	wire.prediction_key = p_key;
	wire.client_tick = p_client_tick;
	wire.input_phase = 0; // a replay has no GDScript-supplied phase to preserve.
	wire.targets = p_request.targets;
	wire.set_by_caller = p_request.set_by_caller;

	std::vector<std::uint8_t> payload;
	const ga::Status encode_status = encode_activation_command(wire, payload);
	if (!encode_status.ok()) {
		return encode_status;
	}
	std::vector<std::uint8_t> framed;
	const ga::Status frame_status = ga::proto::encode_message(ga::proto::MessageType::ACTIVATION_COMMAND,
			ga::proto::SessionId(local_session_id), payload, ga::proto::message_byte_limit(ga::proto::MessageType::ACTIVATION_COMMAND), framed);
	if (!frame_status.ok()) {
		return frame_status;
	}
	rpc_id(server_peer_id, "_rpc_activation_command", to_packed(framed));
	return ga::ok_status();
}

ga::Status GameplayAbilityNetworkBridge::send_task_input_command(
		const ga::proto::TaskInputCommandDto &p_command) {
	std::vector<std::uint8_t> payload;
	ga::Status status =
			ga::proto::encode_task_input(p_command, payload);
	if (!status.ok()) {
		return status;
	}
	std::vector<std::uint8_t> framed;
	status = ga::proto::encode_message(
			ga::proto::MessageType::TASK_INPUT_COMMAND,
			ga::proto::SessionId(local_session_id), payload,
			ga::proto::message_byte_limit(
					ga::proto::MessageType::TASK_INPUT_COMMAND),
			framed);
	if (!status.ok()) {
		return status;
	}
	rpc_id(server_peer_id, "_rpc_task_input_command",
			to_packed(framed));
	return ga::ok_status();
}

ga::Status GameplayAbilityNetworkBridge::send_target_command(
		const ga::proto::TargetCommandDto &p_command) {
	const GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (world == nullptr || !world->is_configured()) {
		return ga::make_status(ga::StatusCode::NOT_SUPPORTED,
				ga::DiagnosticId::INVALID_TARGET_SCHEMA);
	}
	std::vector<std::uint8_t> payload;
	ga::Status status = ga::proto::encode_target_command(p_command,
			world->target_schema_registry(), payload);
	if (!status.ok()) {
		return status;
	}
	std::vector<std::uint8_t> framed;
	status = ga::proto::encode_message(
			ga::proto::MessageType::TARGET_COMMAND,
			ga::proto::SessionId(local_session_id), payload,
			ga::proto::message_byte_limit(
					ga::proto::MessageType::TARGET_COMMAND),
			framed);
	if (!status.ok()) {
		return status;
	}
	rpc_id(server_peer_id, "_rpc_target_command", to_packed(framed));
	return ga::ok_status();
}

Dictionary GameplayAbilityNetworkBridge::request_task_input_networked(
		int64_t p_task, int p_phase, int64_t p_command_sequence,
		int64_t p_client_tick, int64_t p_prediction_key) {
	Dictionary result;
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || !comp->is_configured() || p_task <= 0 ||
			p_phase < 0 ||
			p_phase > int(ga::LogicalInputPhase::CANCEL)) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::INVALID_TASK_PAYLOAD));
		result["sent"] = false;
		return result;
	}
	const ga::AbilityTaskHandle handle{
		static_cast<std::uint64_t>(p_task)
	};
	const ga::ActiveAbilityTask *task =
			comp->core_component()->ability_tasks().find(handle);
	if (task == nullptr ||
			task->request.kind !=
					ga::AbilityTaskKind::WAIT_LOGICAL_INPUT) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::UNKNOWN_ABILITY_TASK,
				ga::DiagnosticId::TASK_PARENT_MISSING,
				handle.value));
		result["sent"] = false;
		return result;
	}
	const ga::Tick tick = static_cast<ga::Tick>(
			std::max<int64_t>(0, p_client_tick));
	ga::AbilityTaskLogicalInputCommand command;
	command.owner = comp->core_component()->entity();
	command.execution = task->execution;
	command.task = handle;
	command.logical_input = task->request.logical_input;
	command.phase = static_cast<ga::LogicalInputPhase>(p_phase);
	command.sequence = ga::CommandSeq{
		static_cast<std::uint64_t>(
				std::max<int64_t>(0, p_command_sequence))
	};
	command.prediction_key = ga::PredictionKey{
		static_cast<std::uint64_t>(
				std::max<int64_t>(0, p_prediction_key))
	};

	if (comp->get_role() !=
			GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		const ga::AbilityTaskTransitionResult applied =
				comp->core_component()->submit_logical_input(
						command, tick,
						ga::ChangeProvenance::AUTHORITATIVE);
		result["status"] = status_dict(applied.status);
		result["transitioned"] = applied.transitioned;
		result["sent"] = false;
		return result;
	}
	if (!is_multiplayer_active()) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::NETWORK_UNAVAILABLE));
		result["sent"] = false;
		return result;
	}
	ga::CommandSeq wire_sequence = command.sequence;
	ga::PredictionKey wire_key = command.prediction_key;
	int prediction_mode = int(
			ga::PredictionMode::NOT_PREDICTED_NO_BASELINE);
	if (!wire_key) {
		if (ga::PredictingComponent *predicting =
					comp->predicting_component()) {
			ensure_client_state();
			const ga::TaskPredictionOutcome predicted =
					predicting->predict_task_input(command, tick,
							*client_stream);
			prediction_mode = int(predicted.mode);
			if (predicted.mode ==
						ga::PredictionMode::PREDICTED) {
				if (!predicted.status.ok()) {
					result["status"] =
							status_dict(predicted.status);
					result["sent"] = false;
					result["prediction_mode"] =
							prediction_mode;
					return result;
				}
				wire_sequence = predicted.command_sequence;
				wire_key = predicted.prediction_key;
			}
		}
	}
	ga::proto::TaskInputCommandDto wire;
	wire.owner = command.owner;
	wire.execution = command.execution;
	wire.task = command.task;
	wire.expected_kind = task->request.kind;
	wire.logical_input = command.logical_input;
	wire.phase = command.phase;
	wire.command_sequence = wire_sequence;
	wire.prediction_key = wire_key;
	wire.issued_tick = tick;
	const ga::Status status = send_task_input_command(wire);
	result["status"] = status_dict(status);
	result["sent"] = status.ok();
	result["prediction_mode"] = prediction_mode;
	result["command_sequence"] =
			static_cast<int64_t>(wire_sequence.value);
	result["prediction_key"] =
			static_cast<int64_t>(wire_key.value);
	return result;
}

Dictionary GameplayAbilityNetworkBridge::request_target_command_networked(
		int64_t p_session, int p_kind,
		const Ref<GameplayTargetValue> &p_intent,
		int64_t p_command_sequence, int64_t p_session_sequence,
		int64_t p_client_tick, int64_t p_prediction_key) {
	Dictionary result;
	GameplayAbilityComponent *comp = resolve_component();
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (comp == nullptr || !comp->is_configured() || world == nullptr ||
			!world->is_configured() || p_session <= 0 ||
			p_kind < 0 ||
			p_kind > int(ga::TargetSessionCommandKind::CANCEL)) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::INVALID_ARGUMENT,
				ga::DiagnosticId::TARGET_SESSION_STALE));
		result["sent"] = false;
		return result;
	}
	ga::GameplayAbilityWorldCoordinator *core_world =
			world->core_coordinator();
	const ga::TargetSessionId session_id{
		static_cast<std::uint64_t>(p_session)
	};
	const ga::ActiveTargetSession *session =
			core_world->find_session(session_id);
	if (session == nullptr ||
			session->owner != comp->core_component()->entity()) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::UNKNOWN_TARGET_SESSION,
				ga::DiagnosticId::TARGET_SESSION_STALE,
				session_id.value));
		result["sent"] = false;
		return result;
	}
	const ga::TargetSchema *schema =
			world->target_schema_registry().find(session->schema);
	if (schema == nullptr) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::UNKNOWN_TARGET_SCHEMA,
				ga::DiagnosticId::INVALID_TARGET_SCHEMA));
		result["sent"] = false;
		return result;
	}
	const ga::Tick tick = static_cast<ga::Tick>(
			std::max<int64_t>(0, p_client_tick));
	ga::TargetSessionCommand command;
	command.kind =
			static_cast<ga::TargetSessionCommandKind>(p_kind);
	command.owner = session->owner;
	command.execution = session->execution;
	command.task = session->task;
	command.session = session->id;
	command.schema = session->schema;
	command.schema_version = schema->desc.schema_version;
	command.sequence = ga::CommandSeq{
		static_cast<std::uint64_t>(
				std::max<int64_t>(0, p_session_sequence))
	};
	command.tick = tick;
	command.prediction_key = ga::PredictionKey{
		static_cast<std::uint64_t>(
				std::max<int64_t>(0, p_prediction_key))
	};
	if (p_intent.is_valid()) {
		const ga::Status conversion = p_intent->to_core(*schema, true,
				session->owner, command.intent);
		if (!conversion.ok()) {
			result["status"] = status_dict(conversion);
			result["sent"] = false;
			return result;
		}
		command.has_intent = true;
	}
	if (comp->get_role() !=
			GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		const ga::TargetSessionCommandResult applied =
				core_world->submit_session_command(command);
		result["status"] = status_dict(applied.status);
		result["transitioned"] = applied.transitioned;
		result["terminal"] = applied.terminal;
		result["sent"] = false;
		return result;
	}
	if (!is_multiplayer_active()) {
		result["status"] = status_dict(ga::make_status(
				ga::StatusCode::NETWORK_UNAVAILABLE));
		result["sent"] = false;
		return result;
	}
	ga::CommandSeq wire_sequence{
		static_cast<std::uint64_t>(
				std::max<int64_t>(0, p_command_sequence))
	};
	ga::PredictionKey wire_key = command.prediction_key;
	int prediction_mode = int(
			ga::PredictionMode::NOT_PREDICTED_NO_BASELINE);
	if (!wire_key) {
		if (ga::PredictingComponent *predicting =
					comp->predicting_component()) {
			ensure_client_state();
			const ga::TargetPredictionOutcome predicted =
					predicting->predict_target_intent(
							*core_world, command, tick,
							*client_stream);
			prediction_mode = int(predicted.mode);
			if (predicted.mode ==
						ga::PredictionMode::PREDICTED) {
				if (!predicted.status.ok()) {
					result["status"] =
							status_dict(predicted.status);
					result["sent"] = false;
					result["prediction_mode"] =
							prediction_mode;
					return result;
				}
				wire_sequence = predicted.command_sequence;
				wire_key = predicted.prediction_key;
			}
		}
	}
	ga::proto::TargetCommandDto wire;
	wire.owner = command.owner;
	wire.execution = command.execution;
	wire.task = command.task;
	wire.target_session = command.session;
	wire.schema = command.schema;
	wire.schema_version = command.schema_version;
	wire.kind = command.kind;
	wire.command_sequence = wire_sequence;
	wire.session_sequence = command.sequence;
	wire.prediction_key = wire_key;
	wire.issued_tick = tick;
	wire.has_intent = command.has_intent;
	wire.intent = command.intent;
	const ga::Status status = send_target_command(wire);
	result["status"] = status_dict(status);
	result["sent"] = status.ok();
	result["prediction_mode"] = prediction_mode;
	result["command_sequence"] =
			static_cast<int64_t>(wire_sequence.value);
	result["prediction_key"] =
			static_cast<int64_t>(wire_key.value);
	return result;
}

ga::Status GameplayAbilityNetworkBridge::validate_target_data_schema(const GameplayAbilityComponent &p_component,
		const String &p_ability_identifier, const std::vector<ga::EntityId> &p_targets,
		const std::vector<ga::SetByCallerMagnitude> &p_set_by_caller) const {
	// Task 7.20: see this method's own header doc comment -- the real
	// enforcement now lives on the component itself, so this bridge and
	// `GameplayAbilityComponent::request_activation`/`process_activation_batch`
	// can never silently disagree about what one ability's schema allows.
	return p_component.validate_target_data_schema(p_ability_identifier, p_targets, p_set_by_caller);
}

void GameplayAbilityNetworkBridge::feed_prediction_acknowledgement(const ga::proto::MessageType &p_type,
		ga::CommandSeq p_sequence, ga::PredictionKey p_key, const ga::Status &p_status,
		const std::vector<ga::EffectHandle> &p_authority_durable_handles) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return;
	}
	ga::PredictionReconciler *recon = comp->prediction_reconciler();
	if (recon == nullptr) {
		return; // not ROLE_NETWORK_CLIENT, or not yet configured -- nothing predicting to reconcile.
	}

	ga::PredictionAck ack;
	ack.command_sequence = p_sequence;
	ack.prediction_key = p_key;
	ack.kind = (p_type == ga::proto::MessageType::COMMAND_ACK) ? ga::PredictionAckKind::ACCEPTED : ga::PredictionAckKind::REJECTED;
	ack.rejection_status = p_status;

	// Task 8.11: this component is the ONLY party that ever knew its own
	// temp handles (see `ga::PredictedOp`'s own doc comment -- they are
	// purely local, client-issued bookkeeping, never sent to the server).
	// Zip them, POSITIONALLY, against the server's ordered
	// `p_authority_durable_handles` list: both sides run the IDENTICAL
	// deterministic `commit_execution_body` sequence for a PREDICTABLE
	// ability (see `validate_prediction_eligibility`), so the Nth durable
	// handle either side produced names the SAME logical operation -- this
	// is exactly the ordering contract `CommandResultWire`'s own doc comment
	// documents. Only ACCEPTED acks carry a mapping; a REJECTED command was
	// never really executed by authority, so there is nothing to map.
	if (ack.kind == ga::PredictionAckKind::ACCEPTED && !p_authority_durable_handles.empty()) {
		if (const ga::PredictingComponent *predicting = comp->predicting_component()) {
			if (const ga::PendingPrediction *entry = predicting->journal().find_pending(p_key)) {
				for (const ga::PredictedOp &op : entry->ops) {
					if (op.temp_handle == ga::INVALID_EFFECT_HANDLE) {
						continue;
					}
					if (ack.temp_handles.size() >= p_authority_durable_handles.size()) {
						break; // more local durable ops than the server reported -- stop, never guess.
					}
					ack.temp_handles.push_back(op.temp_handle);
					ack.authority_handles.push_back(p_authority_durable_handles[ack.temp_handles.size() - 1]);
				}
			}
		}
	}

	ga::PendingPrediction rejected;
	const ga::Status handle_status = recon->handle_acknowledgement(ack, &rejected);
	if (!handle_status.ok()) {
		return; // unknown/stale identity (already resynced/despawned/aged out) -- never mutates anything.
	}
	if (ack.kind == ga::PredictionAckKind::REJECTED) {
		reconcile_and_resend(ga::Tick(get_estimated_tick()));
	}
}

void GameplayAbilityNetworkBridge::reconcile_and_resend(ga::Tick p_tick) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || last_confirmed_snapshot.empty()) {
		return; // nothing confirmed yet to restore to.
	}
	ga::PredictionReconciler *recon = comp->prediction_reconciler();
	if (recon == nullptr) {
		return;
	}
	ensure_client_state();
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	ga::GameplayAbilityWorldCoordinator *core_world =
			world != nullptr && world->is_configured() ?
			world->core_coordinator() :
			nullptr;
	if (core_world != nullptr &&
			!last_confirmed_target_snapshot.empty()) {
		ga::SnapshotReader target_reader(
				last_confirmed_target_snapshot);
		// Fix (same-class UAF as the coordinator's own `restore_snapshot`):
		// routed through the Godot wrapper's `restore_owner_snapshot()`
		// (which prunes freed components first) rather than calling the raw
		// `core_world` pointer directly -- see that wrapper method's own
		// comment.
		const ga::Status target_status =
				world->restore_owner_snapshot(target_reader,
						comp->core_component()->entity());
		if (!target_status.ok() || !target_reader.at_end()) {
			emit_signal("network_diagnostic",
					status_dict(target_status.ok() ?
									ga::make_status(
											ga::StatusCode::DECODE_FAILED,
											ga::DiagnosticId::TRUNCATED_PAYLOAD) :
									target_status));
			request_resync(
					int(ga::proto::ResyncReason::GAP_DETECTED));
			return;
		}
	}
	// Finding 5: routed through `reconcile_snapshot()` (not `recon->
	// reconcile()` directly) so this restore gets the SAME rollback-then-
	// quarantine atomicity guarantee every other restore path does.
	const ga::ReconciliationResult result =
			comp->reconcile_snapshot(last_confirmed_snapshot, p_tick,
					*client_stream, nullptr, core_world);
	if (result.outcome != ga::ReconciliationOutcomeKind::REPLAYED) {
		// COMPONENT_MUST_BE_REBUILT / EVENT_APPLICATION_FAILED. Finding 5:
		// `reconcile_snapshot()` already rolled this component back to its
		// pre-restore state, or quarantined it if even that failed (see its
		// own doc comment) -- either way this component's predicted
		// baseline is gone: disable prediction too (rather than leave it
		// enabled against a baseline this reconciliation attempt could not
		// actually establish), and drive automatic recovery via a fresh
		// resync instead of just diagnosing and stopping here.
		if (ga::PredictingComponent *predicting = comp->predicting_component()) {
			predicting->disable_and_clear();
		}
		emit_signal("network_diagnostic", status_dict(result.status));
		request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
		return;
	}
	for (std::size_t i = 0; i < result.replayed.size() && i < result.replay_results.size(); ++i) {
		const ga::PredictionOutcome &outcome = result.replay_results[i];
		if (outcome.mode != ga::PredictionMode::PREDICTED ||
				!outcome.status.ok()) {
			continue;
		}
		const ga::PendingPrediction &entry =
				result.replayed[i];
		ga::Status send_status;
		switch (entry.command_kind) {
			case ga::PredictionCommandKind::ACTIVATION:
				send_status = send_activation_command(
						entry.original_request,
						outcome.command_sequence,
						outcome.prediction_key, p_tick);
				break;
			case ga::PredictionCommandKind::TASK_INPUT: {
				const ga::AbilityTaskLogicalInputCommand &original =
						entry.original_task_input;
				ga::proto::TaskInputCommandDto command;
				command.owner = original.owner;
				command.execution = original.execution;
				command.task = original.task;
				command.expected_kind =
						ga::AbilityTaskKind::WAIT_LOGICAL_INPUT;
				command.logical_input =
						original.logical_input;
				command.phase = original.phase;
				command.command_sequence =
						outcome.command_sequence;
				command.prediction_key =
						outcome.prediction_key;
				command.issued_tick = entry.issued_tick;
				send_status =
						send_task_input_command(command);
				break;
			}
			case ga::PredictionCommandKind::TARGET_INTENT: {
				const ga::TargetSessionCommand &original =
						entry.original_target_command;
				ga::proto::TargetCommandDto command;
				command.owner = original.owner;
				command.execution = original.execution;
				command.task = original.task;
				command.target_session = original.session;
				command.schema = original.schema;
				command.schema_version =
						original.schema_version;
				command.kind = original.kind;
				command.command_sequence =
						outcome.command_sequence;
				command.session_sequence =
						original.sequence;
				command.prediction_key =
						outcome.prediction_key;
				command.issued_tick = entry.issued_tick;
				command.has_intent = original.has_intent;
				command.intent = original.intent;
				send_status = send_target_command(command);
				break;
			}
		}
		if (!send_status.ok()) {
			emit_signal("network_diagnostic",
					status_dict(send_status));
		}
	}
}

ga::Status GameplayAbilityNetworkBridge::apply_confirmed_payload(GameplayAbilityComponent *p_comp, const std::vector<std::uint8_t> &p_payload, ga::Tick p_tick) {
	const ga::PredictingComponent *predicting = p_comp->predicting_component();
	if (predicting != nullptr && predicting->journal().pending_count() > 0) {
		ensure_client_state();
		// Finding 2a: this fresh authoritative payload is about to replace
		// locally-predicted state while journal entries are still alive.
		// Route through `reconcile_snapshot()` (restores AND replays every
		// still-pending command against the fresh baseline, preserving
		// identity) instead of a plain restore, so those commands are
		// re-recorded against the new baseline rather than left dangling
		// against state that no longer exists. Deliberately never resends
		// here -- see this method's own header doc comment.
		GameplayAbilityWorldCoordinator *world =
				resolve_world_coordinator();
		ga::GameplayAbilityWorldCoordinator *core_world =
				world != nullptr && world->is_configured() ?
				world->core_coordinator() :
				nullptr;
		const ga::ReconciliationResult result =
				p_comp->reconcile_snapshot(p_payload, p_tick,
						*client_stream, nullptr, core_world);
		if (result.outcome == ga::ReconciliationOutcomeKind::REPLAYED) {
			return ga::ok_status();
		}
		return result.status; // COMPONENT_MUST_BE_REBUILT / EVENT_APPLICATION_FAILED -- always non-ok here.
	}
	return p_comp->restore_snapshot(to_packed(p_payload)) ? ga::ok_status() : ga::make_status(ga::StatusCode::DECODE_FAILED);
}

ga::Status GameplayAbilityNetworkBridge::apply_owner_delta(GameplayAbilityComponent *p_comp, const std::vector<std::uint8_t> &p_delta_payload) {
	if (last_confirmed_snapshot.empty()) {
		// Unreachable in normal operation: `_rpc_event_batch` only invokes
		// this once `client_stream` is SYNCED, which requires an already-
		// established baseline (see `ClientEventStream::apply_batch`'s own
		// doc comment) -- and every path that establishes one
		// (`_rpc_snapshot`) also sets `last_confirmed_snapshot` on success.
		// Kept as a defensive fail-closed path rather than an assert.
		return ga::make_status(ga::StatusCode::SNAPSHOT_REQUIRED, ga::DiagnosticId::BASELINE_MISSING);
	}
	// Restore the OLD confirmed baseline first -- through the existing
	// atomic, rollback-on-failure `GameplayAbilityComponent::
	// restore_snapshot` (captures this component's pre-restore state and
	// rolls back to it, or quarantines, on failure; see that method's own
	// doc comment), never the raw core call. This supersedes whatever
	// speculative/predicted state currently sits on `p_comp` -- the SAME
	// thing a plain full-snapshot restore has always done for this routine
	// per-batch path (see this method's own header doc comment).
	if (!p_comp->restore_snapshot(to_packed(last_confirmed_snapshot))) {
		return ga::make_status(ga::StatusCode::DECODE_FAILED);
	}
	// Apply the delta on top. `p_session_coordinator = nullptr`: this
	// bridge's own owner delta batches never carry a TARGET_SESSION section
	// (see `send_owner_event_batch`'s own comment), so `apply_delta_batch`
	// never encounters one here -- and, precisely because it never does,
	// this call is FULLY atomic: either all six owned sections install, or
	// (per `AbilityComponent::apply_delta_batch`'s own doc comment) none of
	// them do, since `install_owned_sections()` never runs early without a
	// TARGET_SESSION section forcing it to. A failure here therefore leaves
	// `p_comp` holding EXACTLY the state the restore above just installed --
	// a valid, if now-stale, baseline.
	const ga::Status apply_status = ga::proto::decode_and_apply_delta_batch(
			p_delta_payload, ga::MAX_EVENT_BATCH_BYTES, *p_comp->core_component(), /*p_session_coordinator=*/ nullptr);
	if (!apply_status.ok()) {
		return apply_status;
	}
	// Refresh `last_confirmed_snapshot` to the resulting confirmed state
	// (task 4.3) so a LATER reconciliation (`reconcile_and_resend`, or a
	// predicting `_rpc_snapshot` arrival) restores from the right baseline.
	const std::vector<std::uint8_t> refreshed = encode_full_snapshot();
	if (refreshed.empty()) {
		return ga::make_status(ga::StatusCode::INTERNAL_ERROR);
	}
	last_confirmed_snapshot = refreshed;
	return ga::ok_status();
}

ga::Status GameplayAbilityNetworkBridge::apply_public_delta(const std::vector<std::uint8_t> &p_delta_payload, int64_t p_tick) {
	if (public_mirror == nullptr) {
		// Unreachable in normal operation: every call site
		// (`_rpc_snapshot`'s observer branch, `_rpc_event_batch`'s observer
		// branch) establishes `public_mirror` first -- see those methods'
		// own comments. Kept as a defensive fail-closed path rather than an
		// assert, matching `apply_owner_delta`'s identical convention.
		return ga::make_status(ga::StatusCode::SNAPSHOT_REQUIRED, ga::DiagnosticId::BASELINE_MISSING);
	}
	// `p_delta_payload` is `compose_public_payload`'s TWO-part shape (see
	// that function's own doc comment) -- split it back apart before either
	// half is interpreted.
	std::vector<std::uint8_t> delta_bytes;
	std::vector<std::uint8_t> task_section_bytes;
	bool has_task_section = false;
	if (!decompose_public_payload(p_delta_payload, delta_bytes, task_section_bytes, has_task_section)) {
		return ga::make_status(ga::StatusCode::DECODE_FAILED, ga::DiagnosticId::TRUNCATED_PAYLOAD, p_delta_payload.size());
	}

	// `MAX_SNAPSHOT_BYTES`, not `MAX_EVENT_BATCH_BYTES`: unlike
	// `apply_owner_delta` (only ever called for a routine, event-batch-bound
	// EVENT_BATCH payload), this method ALSO applies the first, larger
	// baseline-as-full-delta payload (`encode_public_baseline()`'s own
	// output, carried inside a SnapshotEnvelope, bounded by
	// `MAX_SNAPSHOT_BYTES`) -- the larger bound safely covers both call
	// shapes; the REAL per-message wire bound for a routine delta is still
	// `event_batch_fits_stream` on the SERVER side before it is ever sent.
	const ga::Status apply_status = ga::proto::decode_and_apply_delta_batch(
			delta_bytes, ga::MAX_SNAPSHOT_BYTES, *public_mirror, /*p_session_coordinator=*/ nullptr);
	if (!apply_status.ok()) {
		return apply_status;
	}

	// The task section, if present, wholesale-replaces
	// `confirmed_observable_tasks` -- see `apply_public_delta`'s own header
	// doc comment for why an ABSENT section means "unchanged" rather than
	// "empty."
	if (has_task_section) {
		ga::ByteReader task_reader(task_section_bytes);
		std::vector<ga::proto::ObserverTaskRecord> records;
		const ga::Status task_status = ga::proto::decode_observer_task_section(task_reader, records);
		if (!task_status.ok() || !task_reader.at_end()) {
			return task_status.ok() ? ga::make_status(ga::StatusCode::DECODE_FAILED, ga::DiagnosticId::TRUNCATED_PAYLOAD, task_section_bytes.size()) : task_status;
		}
		confirmed_observable_tasks = std::move(records);
	}

	const Dictionary state = decode_public_state_from_mirror(p_tick);
	if (!state.is_empty()) {
		emit_signal("public_state_updated", state);
	}
	return ga::ok_status();
}

Dictionary GameplayAbilityNetworkBridge::decode_public_state_from_mirror(int64_t p_tick) const {
	Dictionary result;
	if (public_mirror == nullptr) {
		return result;
	}
	const GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return result;
	}
	result["entity_id"] = int64_t(public_mirror->entity().value);
	result["tick"] = p_tick;

	Dictionary attributes;
	for (ga::DefinitionId id : public_mirror->attributes().initialized_attributes()) {
		ga::Fixed value = ga::Fixed::zero();
		if (!public_mirror->attributes().get_current(id, value).ok()) {
			continue;
		}
		const String name = comp->resolve_attribute_identifier(int64_t(id));
		if (!name.is_empty()) {
			attributes[name] = ga::fixed_to_double(value);
		}
	}
	result["attributes"] = attributes;

	PackedStringArray tags;
	for (ga::DefinitionId id : public_mirror->tags().owned_tags()) {
		const String name = comp->resolve_tag_identifier(int64_t(id));
		if (!name.is_empty()) {
			tags.push_back(name);
		}
	}
	result["tags"] = tags;

	PackedStringArray abilities;
	for (ga::AbilitySpecId spec : public_mirror->granted_specs()) {
		const ga::AbilityGrant *grant = public_mirror->find_grant(spec);
		if (grant == nullptr || grant->revoked) {
			continue;
		}
		const String name = comp->resolve_ability_identifier(int64_t(grant->ability));
		if (!name.is_empty()) {
			abilities.push_back(name);
		}
	}
	result["granted_abilities"] = abilities;

	// Additive observable-task section, sourced from `confirmed_observable_
	// tasks` -- already-selected-and-resolved `ObserverTaskRecord`s decoded
	// straight off the wire's own observer-task section (see
	// `apply_public_delta`'s own doc comment for exactly when this list was
	// last replaced) -- NOT `public_mirror`'s own task runtime, which never
	// holds ABILITY_TASK content at all for this audience (see
	// `build_full_public_dirty`'s own doc comment).
	Array observable_tasks;
	for (const ga::proto::ObserverTaskRecord &record : confirmed_observable_tasks) {
		Dictionary task_dict;
		task_dict["task"] = int64_t(record.task.value);
		task_dict["execution"] = int64_t(record.execution.value);
		task_dict["ability_identifier"] = String(record.ability_identifier.c_str());
		task_dict["kind"] = int(record.kind);
		task_dict["start_tick"] = int64_t(record.start_tick);
		task_dict["has_deadline"] = record.has_deadline;
		task_dict["deadline_tick"] = record.has_deadline ? int64_t(record.deadline_tick) : int64_t(-1);
		observable_tasks.push_back(task_dict);
	}
	result["observable_tasks"] = observable_tasks;

	return result;
}

void GameplayAbilityNetworkBridge::sweep_expired_predictions() {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->get_role() != GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	ga::PredictingComponent *predicting = comp->predicting_component();
	if (predicting == nullptr) {
		return; // not configured yet, or not actually a predicting component.
	}
	const std::vector<ga::PendingPrediction> dropped = predicting->sweep_expired(ga::Tick(get_estimated_tick()));
	if (!dropped.empty()) {
		// Finding 2e: age-out disabled prediction (see `sweep_expired`'s own
		// doc comment) -- kick off recovery automatically instead of leaving
		// it disabled forever. `GAP_DETECTED` is the closest fit among the
		// existing reasons: the abandoned commands' local effects are still
		// installed with no authority decision ever coming for them, which
		// is exactly the same kind of "local state may have diverged from
		// authority" condition a detected sequence gap represents.
		request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
	}
}

void GameplayAbilityNetworkBridge::on_disconnected_from_server() {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp != nullptr) {
		if (ga::PredictingComponent *predicting = comp->predicting_component()) {
			predicting->on_disconnected();
		}
	}
	handshake_ok = false;
	// A stale baseline from the now-dead session must never be reconciled
	// against once a new one begins -- see this bridge's own doc comment on
	// `last_confirmed_snapshot`.
	last_confirmed_snapshot.clear();
	last_confirmed_target_snapshot.clear();
	// Review fix (Wave 4): the observer's confirmed PUBLIC state is equally a
	// "baseline from the now-dead session" and must not survive into the new
	// one either -- the served component itself is unchanged here (unlike
	// `set_component_path`), so there is no UAF risk, but WITHOUT this, any
	// stray in-flight delta that arrives from the OLD session before this
	// bridge notices the disconnect (or a late-delivered one right after)
	// would apply onto dead-session state until the next public baseline
	// happens to land. `public_mirror`/`confirmed_observable_tasks` are
	// discarded outright (a fresh baseline rebuilds the mirror from scratch
	// regardless -- see `_rpc_snapshot`'s observer branch); `public_client_
	// stream->reset_for_new_session()` is the SAME "a new session is a new
	// trust epoch" transition its own doc comment already describes for
	// exactly this scenario (as opposed to `mark_needs_snapshot()`'s
	// same-session quarantine), discarding its confirmed sequence and
	// idempotency history so no delta applies until a fresh baseline
	// re-establishes it.
	public_mirror.reset();
	confirmed_observable_tasks.clear();
	if (public_client_stream != nullptr) {
		public_client_stream->reset_for_new_session();
	}
	// Review fix (Wave 5, owner-side invalidation audit): `client_stream` is
	// the owner-audience twin of `public_client_stream` immediately above --
	// see that member's own doc comment (gameplay_ability_network_bridge.h)
	// for why it gets the identical `reset_for_new_session()` treatment here.
	if (client_stream != nullptr) {
		client_stream->reset_for_new_session();
	}
}

void GameplayAbilityNetworkBridge::on_server_disconnected() {
	on_disconnected_from_server();
}

void GameplayAbilityNetworkBridge::on_peer_disconnected(int64_t p_peer_id) {
	if (int(p_peer_id) == server_peer_id) {
		on_disconnected_from_server();
	}
}

void GameplayAbilityNetworkBridge::on_connected_to_server() {
	// Finding 3a: fires once THIS peer finishes connecting to a server --
	// exactly the "gameplay world built first, transport connected later"
	// case `try_wire_component()`'s own immediate `is_multiplayer_active()`
	// check cannot cover (it only ever runs once, at wiring time).
	// `send_handshake_request()` itself is the single source of truth for
	// "am I actually able to send right now" (its own `is_multiplayer_active()`
	// guard), so this never needs to re-check that here.
	send_handshake_request();
}

void GameplayAbilityNetworkBridge::on_peer_connected(int64_t p_peer_id) {
	// Finding 3a: `connected_to_server` is not guaranteed to be the only
	// signal a listen-server/mesh topology fires when THIS peer's connection
	// to `server_peer_id` becomes usable -- `peer_connected` is the more
	// general "a peer just became known" signal every `MultiplayerAPI`
	// exposes, so this reacts to it too, narrowed to the one peer id this
	// bridge actually treats as the server (a client with several OTHER
	// known peers -- e.g. a relay topology -- must not (re)send a handshake
	// for each of THOSE; only `server_peer_id` matters here).
	if (int(p_peer_id) == server_peer_id) {
		send_handshake_request();
	}
}

void GameplayAbilityNetworkBridge::send_command_result(int p_peer, ga::EntityId p_component, ga::CommandSeq p_sequence,
		ga::PredictionKey p_key, ga::ExecutionId p_execution, const ga::Status &p_status,
		const std::vector<ga::EffectHandle> &p_authority_durable_handles) {
	CommandResultWire wire;
	wire.component = p_component;
	wire.command_sequence = p_sequence;
	wire.prediction_key = p_key;
	wire.execution = p_execution;
	wire.status = p_status;
	wire.authority_durable_handles = p_authority_durable_handles;

	std::vector<std::uint8_t> payload;
	if (!encode_command_result(wire, payload).ok()) {
		return;
	}
	const ga::proto::MessageType type = p_status.ok() ? ga::proto::MessageType::COMMAND_ACK : ga::proto::MessageType::COMMAND_REJECT;
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(type, ga::proto::SessionId(local_session_id), payload, ga::proto::message_byte_limit(type), framed).ok()) {
		return;
	}
	rpc_id(p_peer, "_rpc_command_result", to_packed(framed));
}

void GameplayAbilityNetworkBridge::send_target_outcome(
		int p_peer,
		const ga::TargetSessionCommandResult &p_result) {
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (world == nullptr || !world->is_configured() ||
			!peer_is_owner(p_peer) || !p_result.event.session ||
			p_result.event.schema == ga::INVALID_DEFINITION_ID) {
		return;
	}
	ga::proto::TargetOutcomeDto outcome;
	outcome.event = p_result.event;
	outcome.has_validated_data =
			p_result.has_validated_data;
	if (p_result.has_validated_data) {
		outcome.canonical_intent =
				p_result.validated_data.canonical_intent();
		outcome.result = p_result.validated_data.result();
		outcome.outcomes =
				p_result.validated_data.provider_outcomes();
	}
	std::vector<std::uint8_t> payload;
	ga::Status status = ga::proto::encode_target_outcome(outcome,
			world->target_schema_registry(),
			ga::TargetResultVisibility::OWNER_ONLY, payload);
	if (!status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(status));
		return;
	}
	std::vector<std::uint8_t> framed;
	status = ga::proto::encode_message(
			ga::proto::MessageType::TARGET_OUTCOME,
			ga::proto::SessionId(local_session_id), payload,
			ga::proto::message_byte_limit(
					ga::proto::MessageType::TARGET_OUTCOME),
			framed);
	if (!status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(status));
		return;
	}
	rpc_id(p_peer, "_rpc_target_outcome",
			to_packed(framed));
}

void GameplayAbilityNetworkBridge::send_target_state_to_peer(
		int p_peer, ga::EntityId p_owner) {
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (world == nullptr || !world->is_configured() || !p_owner ||
			!peer_is_owner(p_peer)) {
		return;
	}
	ga::SnapshotWriter writer;
	ga::Status status =
			world->core_coordinator()->write_snapshot(writer,
					ga::TargetResultVisibility::OWNER_ONLY,
					p_owner);
	if (!status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(status));
		return;
	}
	const std::vector<std::uint8_t> payload = writer.take();
	std::vector<std::uint8_t> framed;
	status = ga::proto::encode_message(
			ga::proto::MessageType::TARGET_STATE,
			ga::proto::SessionId(local_session_id), payload,
			ga::proto::message_byte_limit(
					ga::proto::MessageType::TARGET_STATE),
			framed);
	if (!status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(status));
		return;
	}
	rpc_id(p_peer, "_rpc_target_state",
			to_packed(framed));
}

void GameplayAbilityNetworkBridge::_rpc_activation_command(const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || !comp->is_configured() || comp->get_role() == GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	ensure_server_state();

	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int32_t peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	if (peer == 0) {
		return;
	}

	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::ACTIVATION_COMMAND, header, payload)) {
		emit_signal("network_diagnostic", status_dict(ga::make_status(ga::StatusCode::DECODE_FAILED)));
		return;
	}
	ActivationCommandWire wire;
	if (!decode_activation_command(payload, wire).ok()) {
		emit_signal("network_diagnostic", status_dict(ga::make_status(ga::StatusCode::DECODE_FAILED)));
		return;
	}

	if (handshake_ok_peers.find(peer) == handshake_ok_peers.end()) {
		send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID,
				ga::make_status(ga::StatusCode::PROTOCOL_MISMATCH));
		return;
	}
	if (wire.component.value != std::uint64_t(comp->get_entity_id())) {
		send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID,
				ga::make_status(ga::StatusCode::INVALID_ARGUMENT));
		return;
	}

	ga::proto::InboundCommandContext ctx;
	ctx.peer = peer;
	const auto session_it = peer_sessions.find(peer);
	ctx.session = ga::proto::SessionId(session_it != peer_sessions.end() ? session_it->second : 0);
	ctx.component = wire.component;
	ctx.command_sequence = wire.command_sequence;
	ctx.prediction_key = wire.prediction_key;
	ctx.current_tick = ga::Tick(comp->get_current_tick());

	ga::proto::InboundCommandVerdict verdict;
	const ga::Status admit_status = gate->admit(ctx, ga::SessionTiming{ effective_tick_rate() }, verdict);
	if (!admit_status.ok() || verdict.kind != ga::proto::CommandOutcomeKind::EXECUTE) {
		const ga::Status reply_status = admit_status.ok() ? verdict.status : admit_status;
		send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID, reply_status);
		return;
	}

	// *** Gameplay-validation seam (task 7.6 remainder) ***
	const Dictionary grant = comp->get_grant(int64_t(wire.spec.value));
	if (grant.is_empty()) {
		const ga::Status status = ga::make_status(ga::StatusCode::ABILITY_NOT_GRANTED);
		gate->sequence_tracker().record_command_result(ctx.session, ctx.component, ctx.command_sequence, status);
		send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID, status);
		return;
	}

	// Task 7.16: per-ability target-data schema cardinality/byte bounds --
	// BEFORE the game-provided target authorization callback and before any
	// mutation, per the "Bounded and Validated Target Data" requirement.
	{
		const ga::Status schema_status = validate_target_data_schema(*comp, grant.get("ability_identifier", String()),
				wire.targets, wire.set_by_caller);
		if (!schema_status.ok()) {
			gate->sequence_tracker().record_command_result(ctx.session, ctx.component, ctx.command_sequence, schema_status);
			send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID, schema_status);
			return;
		}
	}

	if (!wire.targets.empty()) {
		if (!target_authorization_callback.is_valid()) {
			// Finding 8: `require_target_authorization` turns "no callback
			// configured" from a silent allow into a fail-closed rejection --
			// a game that opted into mandatory target authorization must
			// never have a targeted command slip through just because the
			// callback was never wired up (a configuration bug, not a
			// deliberate policy choice). Default false preserves the
			// original opt-in behavior for every game that has not set this.
			if (require_target_authorization) {
				const ga::Status status = ga::make_status(ga::StatusCode::ABILITY_INVALID_TARGET);
				gate->sequence_tracker().record_command_result(ctx.session, ctx.component, ctx.command_sequence, status);
				send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID, status);
				emit_signal("network_diagnostic", status_dict(status));
				return;
			}
		} else {
			// Finding 8: a single context Dictionary replaces the old
			// 4-positional-argument callback signature -- see
			// `set_target_authorization_callback`'s own doc comment (bridge.h)
			// for the full field list and why.
			Dictionary context;
			context["peer"] = peer;
			context["session"] = int64_t(ctx.session);
			context["component"] = int64_t(comp->get_entity_id());
			context["spec"] = int64_t(wire.spec.value);
			context["ability_identifier"] = grant.get("ability_identifier", String());
			PackedInt64Array targets_array;
			for (ga::EntityId target : wire.targets) {
				targets_array.push_back(int64_t(target.value));
			}
			context["targets"] = targets_array;
			Array set_by_caller_array;
			for (const ga::SetByCallerMagnitude &magnitude : wire.set_by_caller) {
				Dictionary field;
				field["field"] = String(magnitude.field.c_str());
				field["value"] = ga::fixed_to_double(magnitude.value);
				set_by_caller_array.push_back(field);
			}
			context["set_by_caller"] = set_by_caller_array;
			context["command_sequence"] = int64_t(wire.command_sequence.value);
			context["prediction_key"] = int64_t(wire.prediction_key.value);
			context["client_tick"] = int64_t(wire.client_tick);
			context["current_tick"] = int64_t(ctx.current_tick);

			Array args;
			args.push_back(context);
			const Variant authorized = target_authorization_callback.callv(args);
			if (!bool(authorized)) {
				const ga::Status status = ga::make_status(ga::StatusCode::ABILITY_INVALID_TARGET);
				gate->sequence_tracker().record_command_result(ctx.session, ctx.component, ctx.command_sequence, status);
				send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, ga::INVALID_EXECUTION_ID, status);
				return;
			}
		}
	}

	Dictionary request;
	request["spec"] = int64_t(wire.spec.value);
	PackedInt64Array targets_array;
	for (ga::EntityId target : wire.targets) {
		targets_array.push_back(int64_t(target.value));
	}
	request["targets"] = targets_array;
	Array set_by_caller;
	for (const ga::SetByCallerMagnitude &magnitude : wire.set_by_caller) {
		Dictionary field;
		field["field"] = String(magnitude.field.c_str());
		field["value"] = ga::fixed_to_double(magnitude.value);
		set_by_caller.push_back(field);
	}
	request["set_by_caller"] = set_by_caller;
	request["command_sequence"] = int64_t(wire.command_sequence.value);
	request["provenance"] = int(GameplayAbilityComponent::PROVENANCE_AUTHORITATIVE);
	request["prediction_key"] = int64_t(wire.prediction_key.value);

	// Task 8.11: snapshot the grant's cooldown handle BEFORE the commit --
	// `commit_execution_body` only ever assigns a NEW cooldown handle when it
	// actually applies the ability's declared cooldown effect this call (see
	// that function's own step 2); comparing before/after is how this
	// authority-side code detects "this call produced a fresh durable handle"
	// without needing to know the ability's shape at all.
	const std::uint64_t cooldown_handle_before = std::uint64_t(int64_t(grant.get("cooldown_handle", 0)));

	const Dictionary activation_result = comp->request_activation(request, int64_t(ctx.current_tick));
	const Dictionary result_status_dict = activation_result.get("status", Dictionary());
	ga::Status core_status;
	core_status.code = static_cast<ga::StatusCode>(int(result_status_dict.get("code", 0)));
	core_status.diagnostic = static_cast<ga::DiagnosticId>(int(result_status_dict.get("diagnostic", 0)));
	core_status.detail = std::uint64_t(int64_t(result_status_dict.get("detail", 0)));

	gate->sequence_tracker().record_command_result(ctx.session, ctx.component, ctx.command_sequence, core_status);

	const ga::ExecutionId execution{ std::uint64_t(int64_t(activation_result.get("execution", 0))) };

	// Task 8.11: the ordered "durable handles a predicting client would also
	// have journaled" list -- see `CommandResultWire`'s own doc comment for
	// why this is positional and, today, cooldown-only (matching
	// `ga::PredictingComponent::predict_full`'s own current op-recording
	// shape exactly, so the client's later positional zip lines up).
	std::vector<ga::EffectHandle> authority_durable_handles;
	if (core_status.ok()) {
		const Dictionary grant_after = comp->get_grant(int64_t(wire.spec.value));
		const std::uint64_t cooldown_handle_after = std::uint64_t(int64_t(grant_after.get("cooldown_handle", 0)));
		if (cooldown_handle_after != 0 && cooldown_handle_after != cooldown_handle_before) {
			authority_durable_handles.push_back(ga::EffectHandle{ cooldown_handle_after });
		}
	}
	send_command_result(peer, wire.component, wire.command_sequence, wire.prediction_key, execution, core_status, authority_durable_handles);

	if (core_status.ok()) {
		push_full_state(int64_t(ctx.current_tick));

		// Finding 4: `activation_result["pending_remote_effects"]` (task
		// 6.13's accepted-but-not-locally-applicable remote-target hook
		// commands, see `GameplayAbilityComponent::activation_result_dict`'s
		// own doc comment) used to be read only for `status`/`execution`
		// above and silently dropped here -- the core had already validated
		// and captured these, so nothing about them was ever unsafe, only
		// unrouted. `remote_effects_pending` is the routing seam (see this
		// method's own header doc comment for the full payload shape and
		// contract): one bridge serves exactly one component, so applying a
		// command to some OTHER entity's component is necessarily the game's
		// job.
		const Array pending_remote_effects = activation_result.get("pending_remote_effects", Array());
		if (!pending_remote_effects.is_empty()) {
			if (get_signal_connection_list("remote_effects_pending").is_empty()) {
				// Nothing is connected -- without this, the command would be
				// silently dropped a SECOND time (the FIRST drop this addon
				// already closed at the core layer; see
				// `ga::DiagnosticId::REMOTE_EFFECT_UNCONSUMED`'s own doc
				// comment for why the core's OWN `PENDING_REMOTE_EFFECT_DROPPED`
				// diagnostic can never fire from this call path instead).
				// Bounded: at most one diagnostic per triggering activation,
				// never a loop over `pending_remote_effects` itself.
				emit_signal("network_diagnostic",
						status_dict(ga::make_status(ga::StatusCode::NOT_SUPPORTED, ga::DiagnosticId::REMOTE_EFFECT_UNCONSUMED,
								pending_remote_effects.size())));
			} else {
				Dictionary payload;
				payload["commands"] = pending_remote_effects;
				payload["peer"] = peer;
				payload["spec"] = int64_t(wire.spec.value);
				payload["execution"] = int64_t(execution.value);
				payload["command_sequence"] = int64_t(wire.command_sequence.value);
				payload["current_tick"] = int64_t(ctx.current_tick);
				emit_signal("remote_effects_pending", payload);
			}
		}
	}
}

void GameplayAbilityNetworkBridge::_rpc_task_input_command(
		const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || !comp->is_configured() ||
			comp->get_role() ==
					GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int32_t peer =
			api.is_valid() ? api->get_remote_sender_id() : 0;
	if (peer == 0) {
		return;
	}

	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes,
				ga::proto::MessageType::TASK_INPUT_COMMAND,
				header, payload)) {
		emit_signal("network_diagnostic",
				status_dict(ga::make_status(
						ga::StatusCode::DECODE_FAILED)));
		return;
	}
	ga::proto::TaskInputCommandDto command;
	const ga::Status decode_status =
			ga::proto::decode_task_input(payload, command);
	if (!decode_status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(decode_status));
		return;
	}
	if (handshake_ok_peers.find(peer) ==
			handshake_ok_peers.end()) {
		send_command_result(peer, command.owner,
				command.command_sequence,
				command.prediction_key, command.execution,
				ga::make_status(
						ga::StatusCode::PROTOCOL_MISMATCH));
		return;
	}

	const auto session_it = peer_sessions.find(peer);
	const ga::proto::SessionId session =
			ga::proto::SessionId(session_it != peer_sessions.end() ?
							session_it->second :
							0);
	ga::proto::InboundCommandVerdict verdict;
	ga::AbilityTaskTransitionResult task_result;
	const ga::Status admission =
			ga::proto::admit_and_apply_task_input(command,
					ga::proto::PeerId(peer), session,
					ga::Tick(comp->get_current_tick()),
					ga::SessionTiming{ effective_tick_rate() },
					*gate, gate->sequence_tracker(),
					*comp->core_component(), verdict,
					task_result);
	ga::Status reply = task_result.status;
	if (reply.ok() && !admission.ok()) {
		reply = admission;
	}
	if (reply.ok() && !verdict.status.ok()) {
		reply = verdict.status;
	}
	send_command_result(peer, command.owner,
			command.command_sequence, command.prediction_key,
			command.execution, reply);
	if (reply.ok() &&
			verdict.kind ==
					ga::proto::CommandOutcomeKind::EXECUTE) {
		push_full_state(
				static_cast<int64_t>(comp->get_current_tick()));
	}
}

void GameplayAbilityNetworkBridge::_rpc_target_command(
		const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (comp == nullptr || !comp->is_configured() || world == nullptr ||
			!world->is_configured() ||
			comp->get_role() ==
					GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int32_t peer =
			api.is_valid() ? api->get_remote_sender_id() : 0;
	if (peer == 0) {
		return;
	}

	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes,
				ga::proto::MessageType::TARGET_COMMAND,
				header, payload)) {
		emit_signal("network_diagnostic",
				status_dict(ga::make_status(
						ga::StatusCode::DECODE_FAILED)));
		return;
	}
	ga::proto::TargetCommandDto command;
	const ga::Status decode_status =
			ga::proto::decode_target_command(payload,
					world->target_schema_registry(), command);
	if (!decode_status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(decode_status));
		return;
	}
	if (handshake_ok_peers.find(peer) ==
			handshake_ok_peers.end()) {
		send_command_result(peer, command.owner,
				command.command_sequence,
				command.prediction_key, command.execution,
				ga::make_status(
						ga::StatusCode::PROTOCOL_MISMATCH));
		return;
	}

	const auto session_it = peer_sessions.find(peer);
	const ga::proto::SessionId session =
			ga::proto::SessionId(session_it != peer_sessions.end() ?
							session_it->second :
							0);
	ga::proto::InboundCommandVerdict verdict;
	ga::TargetSessionCommandResult target_result;
	const ga::Status admission =
			ga::proto::admit_and_apply_target_command(command,
					ga::proto::PeerId(peer), session,
					ga::Tick(comp->get_current_tick()),
					ga::SessionTiming{ effective_tick_rate() },
					*gate, gate->sequence_tracker(),
					*world->core_coordinator(),
					*comp->core_component(), verdict,
					target_result);
	ga::Status reply = target_result.status;
	if (reply.ok() && !admission.ok()) {
		reply = admission;
	}
	if (reply.ok() && !verdict.status.ok()) {
		reply = verdict.status;
	}

	// An admitted target command may update the session's sequence,
	// submission count, intent, or terminal task state even when provider
	// resolution later rejects it. Publish the authoritative component
	// snapshot first and the owner-filtered target snapshot second on the
	// same reliable channel; the generic acknowledgement is deliberately
	// last so rejection reconciliation sees both confirmed baselines.
	if (verdict.kind ==
			ga::proto::CommandOutcomeKind::EXECUTE) {
		push_full_state(
				static_cast<int64_t>(comp->get_current_tick()));
	}
	if (target_result.event.session &&
			target_result.event.schema !=
					ga::INVALID_DEFINITION_ID) {
		send_target_outcome(peer, target_result);
	}
	send_command_result(peer, command.owner,
			command.command_sequence, command.prediction_key,
			command.execution, reply);
}

void GameplayAbilityNetworkBridge::_rpc_command_result(const PackedByteArray &p_bytes) {
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	// COMMAND_ACK/COMMAND_REJECT share one wire shape and one byte limit (see
	// gap_messages.cpp) -- a single `decode_framed` call against COMMAND_ACK
	// still leaves `header`/`payload` correctly populated even when the
	// decoded type is actually COMMAND_REJECT (decode_framed's own contract:
	// it only fails the CALL'S return value on a type mismatch, never on
	// populating its out-params), so this checks the actual decoded type
	// afterward instead of decoding the same bytes twice.
	if (!decode_framed(p_bytes, ga::proto::MessageType::COMMAND_ACK, header, payload) &&
			header.message_type != ga::proto::MessageType::COMMAND_REJECT) {
		return;
	}
	CommandResultWire wire;
	if (!decode_command_result(payload, wire).ok()) {
		return;
	}
	Dictionary d;
	d["component"] = int64_t(wire.component.value);
	d["command_sequence"] = int64_t(wire.command_sequence.value);
	d["prediction_key"] = int64_t(wire.prediction_key.value);
	d["execution"] = int64_t(wire.execution.value);
	d["status"] = status_dict(wire.status);
	// Task 8.11: surfaced for observability/diagnostics parity with every
	// other wire field this signal already exposes -- the actual mapping
	// happens below via `feed_prediction_acknowledgement`, not from a script
	// reading this array itself.
	PackedInt64Array authority_durable_handles;
	for (ga::EffectHandle handle : wire.authority_durable_handles) {
		authority_durable_handles.push_back(int64_t(handle.value));
	}
	d["authority_durable_handles"] = authority_durable_handles;
	if (header.message_type == ga::proto::MessageType::COMMAND_ACK) {
		emit_signal("command_acknowledged", d);
	} else {
		emit_signal("command_rejected", d);
	}

	// Task 8.10/8.11: feed every acknowledgement/rejection, plus the wire's
	// ordered authority-durable-handle list, into the served component's own
	// prediction reconciler (a no-op when it is not currently predicting --
	// see `feed_prediction_acknowledgement`).
	feed_prediction_acknowledgement(header.message_type, wire.command_sequence, wire.prediction_key, wire.status, wire.authority_durable_handles);
}

void GameplayAbilityNetworkBridge::_rpc_target_outcome(
		const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (comp == nullptr || world == nullptr ||
			!world->is_configured() || !owner_view) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes,
				ga::proto::MessageType::TARGET_OUTCOME,
				header, payload)) {
		return;
	}
	ga::proto::TargetOutcomeDto outcome;
	const ga::Status status =
			ga::proto::decode_target_outcome(payload,
					world->target_schema_registry(), outcome);
	if (!status.ok() ||
			outcome.event.owner !=
					comp->core_component()->entity()) {
		emit_signal("network_diagnostic",
				status_dict(status.ok() ?
								ga::make_status(
										ga::StatusCode::PERMISSION_DENIED,
										ga::DiagnosticId::TARGET_NOT_RELEVANT,
										outcome.event.owner.value) :
								status));
		return;
	}

	Dictionary event;
	event["kind"] = static_cast<int>(outcome.event.kind);
	event["session"] =
			static_cast<int64_t>(outcome.event.session.value);
	event["owner"] =
			static_cast<int64_t>(outcome.event.owner.value);
	event["execution"] =
			static_cast<int64_t>(outcome.event.execution.value);
	event["task"] =
			static_cast<int64_t>(outcome.event.task.value);
	event["schema_id"] =
			static_cast<int64_t>(outcome.event.schema);
	event["tick"] = static_cast<int64_t>(outcome.event.tick);
	event["status"] = status_dict(outcome.event.status);
	event["command_sequence"] = static_cast<int64_t>(
			outcome.event.command_sequence.value);
	event["has_intent"] = outcome.event.has_intent;
	event["canonical_intent_hash"] = static_cast<int64_t>(
			outcome.event.canonical_intent_hash);

	Dictionary result;
	result["event"] = event;
	result["has_validated_data"] =
			outcome.has_validated_data;
	if (outcome.has_validated_data) {
		const ga::TargetSchema *schema =
				world->target_schema_registry().find(
						outcome.event.schema);
		const int64_t coordinate_scale = schema != nullptr ?
				schema->desc.coordinate_scale :
				1000000;
		const int dimension = schema != nullptr ?
				static_cast<int>(schema->desc.dimension) :
				0;
		result["canonical_intent"] =
				GameplayTargetValue::from_core(
						outcome.canonical_intent.value,
						coordinate_scale, dimension);
		result["result"] =
				GameplayTargetValue::from_core(outcome.result,
						coordinate_scale, dimension);
		Array outcomes;
		for (const ga::TargetEntityOutcome &entity_outcome :
				outcome.outcomes) {
			Dictionary entry;
			entry["entity"] = static_cast<int64_t>(
					entity_outcome.entity.value);
			entry["rank"] =
					static_cast<int>(entity_outcome.rank);
			entry["kind"] =
					static_cast<int>(entity_outcome.kind);
			entry["status"] =
					status_dict(entity_outcome.status);
			outcomes.append(entry);
		}
		result["outcomes"] = outcomes;
	}
	// This signal exposes decoded, sanitized presentation data only.
	// `ValidatedTargetData` remains impossible to construct outside the
	// authority coordinator and is never manufactured from the wire.
	emit_signal("target_outcome_received", result);
}

void GameplayAbilityNetworkBridge::_rpc_target_state(
		const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	GameplayAbilityWorldCoordinator *world =
			resolve_world_coordinator();
	if (comp == nullptr || !comp->is_configured() || world == nullptr ||
			!world->is_configured() || !owner_view) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes,
				ga::proto::MessageType::TARGET_STATE,
				header, payload)) {
		return;
	}
	ga::GameplayAbilityWorldCoordinator *core_world =
			world->core_coordinator();
	const ga::EntityId owner =
			comp->core_component()->entity();

	// Preserve the whole world coordinator so a malformed owner payload
	// with trailing bytes cannot partially replace this owner's sessions.
	ga::SnapshotWriter rollback_writer;
	const ga::Status capture_status =
			core_world->write_snapshot(rollback_writer,
					ga::TargetResultVisibility::INTERNAL);
	if (!capture_status.ok()) {
		emit_signal("network_diagnostic",
				status_dict(capture_status));
		return;
	}
	const std::vector<std::uint8_t> rollback_bytes =
			rollback_writer.take();
	ga::SnapshotReader reader(payload);
	// Fix (same-class UAF as the coordinator's own `restore_snapshot`):
	// routed through the wrapper's `restore_owner_snapshot()` (prunes freed
	// components first) rather than the raw `core_world` pointer -- see that
	// wrapper method's own comment. The rollback `restore_snapshot()` call
	// below stays on `core_world` directly: it runs synchronously right
	// after this call, within the same tick, so no additional node can have
	// been freed in between.
	ga::Status status =
			world->restore_owner_snapshot(reader, owner);
	if (status.ok() && !reader.at_end()) {
		status = ga::make_status(ga::StatusCode::DECODE_FAILED,
				ga::DiagnosticId::TRUNCATED_PAYLOAD,
				payload.size());
	}
	if (!status.ok()) {
		ga::SnapshotReader rollback_reader(rollback_bytes);
		(void)core_world->restore_snapshot(rollback_reader);
		emit_signal("network_diagnostic",
				status_dict(status));
		request_resync(
				int(ga::proto::ResyncReason::GAP_DETECTED));
		return;
	}

	const bool initial_restore =
			last_confirmed_target_snapshot.empty();
	last_confirmed_target_snapshot = payload;
	if (initial_restore) {
		core_world->notify_restored_sessions(
				ga::Tick(comp->get_current_tick()), owner);
	}
	Dictionary info;
	info["owner"] = static_cast<int64_t>(owner.value);
	info["initial_restore"] = initial_restore;
	int64_t session_count = 0;
	for (ga::TargetSessionId session :
			core_world->active_sessions()) {
		const ga::ActiveTargetSession *active =
				core_world->find_session(session);
		if (active != nullptr && active->owner == owner) {
			++session_count;
		}
	}
	info["active_sessions"] = session_count;
	emit_signal("target_state_synced", info);
}

// ---------------------------------------------------------------------------
// Snapshots / event batches / relevance filtering (tasks 7.9, 7.11)
// ---------------------------------------------------------------------------

std::vector<std::uint8_t> GameplayAbilityNetworkBridge::encode_full_snapshot() const {
	const GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->core_component() == nullptr) {
		return {};
	}
	// Fix (spec "Task Snapshot Visibility and Restore"): every call site of
	// this method addresses the OWNING peer only -- `send_snapshot_to_peer`
	// and `_rpc_resync_request`'s own `owner ? encode_full_snapshot() :
	// encode_public_state()` branches, and `send_owner_event_batch`, which is
	// itself only ever invoked for an owning peer (see `push_full_state`).
	// `AbilityComponent::write_snapshot`'s default audience is `INTERNAL`
	// (everything, for local persistence/digest/rollback use), which would
	// otherwise leak authority-only task implementation state to the owning
	// client. Filter to `OWNER_ONLY` here, mirroring
	// `send_target_state_to_peer`'s own OWNER_ONLY filter for target-session
	// state -- the SECTION format itself is unchanged, this only omits
	// INTERNAL entries.
	//
	// Fix (info-leak: retained `TargetEffectContext` on the wire): the same
	// `INTERNAL` default would also hand this owning peer any OTHER entity's
	// retained effect-target context at full fidelity (e.g. an attacker's
	// exact quantized aim/hit data on an effect it applied to THIS
	// component's entity), regardless of that context's own
	// schema-declared visibility. Pass `OWNER_ONLY` here too --
	// `AbilityComponent::write_snapshot` derives, per retained context,
	// whether this component's own entity is that context's source (a
	// self-applied effect, so this owning peer legitimately owns it) or a
	// foreign one (this peer is merely an observer of it) -- see
	// `EffectRuntime::write_snapshot`'s own comment for that derivation and
	// its one accepted over-sanitization edge. Same non-change to the
	// SECTION format: a sanitized context still decodes and validates like
	// any other.
	ga::SnapshotWriter writer;
	const ga::Status status = comp->core_component()->write_snapshot(
			writer, ga::AbilityTaskVisibility::OWNER_ONLY,
			ga::TargetResultVisibility::OWNER_ONLY);
	if (!status.ok() || !writer.ok()) {
		return {};
	}
	return writer.take();
}

// Wave 4 (add-granular-delta-replication-2026-07-27, task 3.3): shared by
// `encode_public_state()` below (unchanged output) and
// `encode_public_baseline()`/`send_public_state()`'s own observer-task
// section -- see those methods' own doc comments for why ABILITY_TASK rides
// this SEPARATE, purpose-built whitelist-projection codec
// (`ga::proto::select_observer_task_records`/`encode_observer_task_section`)
// rather than the canonical section-delta codec's own ABILITY_TASK section:
// `AbilityComponent::apply_delta_batch`'s cross-section parent-execution
// check (ga_ability_component.cpp) requires a live ACTIVE_EXECUTION record
// for any task's owning execution, and ACTIVE_EXECUTION has no PUBLIC
// exposure at all (`AudienceVisibilityConfig`'s own comment) -- a PUBLIC
// batch can therefore never satisfy that check, so ABILITY_TASK content is
// never safe to route through the canonical delta/apply path for this
// audience. Selection itself -- the `task_visible_to(..., OBSERVABLE)`
// filter (the SAME shared filter the core snapshot section and the
// standalone `TASK_STATE` DTO codec use) plus the defensive
// authoritative-only check (this method only ever runs on authority --
// `push_full_state` returns early for `ROLE_NETWORK_CLIENT` -- but a
// predicted, unconfirmed task must structurally never reach an observer even
// if that call-site guarantee ever regressed) -- lives in
// `ga::proto::select_observer_task_records` (native, unit-tested) so it is
// not a third hand-rolled copy of the filter here. This bridge only supplies
// the one piece that CANNOT live in native/protocol: resolving a task's
// owning ability to an identifier string and applying hidden-ability
// suppression, consistent with the grant list -- a task whose owning ability
// identifier is hidden (or cannot be resolved at all) is OMITTED entirely,
// never encoded with a blanked identity. `ability_identifier` is resolved
// through `get_grant(task.spec)`, the exact lookup the grant-list section
// already performs (a task's `spec` and the owning grant's `ability` always
// agree -- a task is only ever started from an execution begun against a
// granted spec), so hidden-ability suppression and observer-side
// correlation against `granted_abilities` stay consistent by construction.
std::vector<ga::proto::ObserverTaskRecord> GameplayAbilityNetworkBridge::build_observable_task_records() const {
	std::vector<ga::proto::ObserverTaskRecord> observable_tasks;
	const GameplayAbilityComponent *comp = resolve_component();
	const ga::AbilityComponent *core = comp != nullptr ? comp->core_component() : nullptr;
	if (core == nullptr) {
		return observable_tasks;
	}
	std::vector<ga::ActiveAbilityTask> active_tasks;
	const ga::AbilityTaskRuntime &tasks = core->ability_tasks();
	for (ga::AbilityTaskHandle handle : tasks.active_handles()) {
		const ga::ActiveAbilityTask *task = tasks.find(handle);
		if (task != nullptr) {
			active_tasks.push_back(*task);
		}
	}
	ga::proto::select_observer_task_records(active_tasks,
			[comp, this](const ga::ActiveAbilityTask &p_task, std::string &r_identifier) -> bool {
				const Dictionary grant = comp->get_grant(int64_t(p_task.spec.value));
				if (grant.is_empty()) {
					return false;
				}
				const String identifier = grant.get("ability_identifier", String());
				if (identifier.is_empty() || hidden_abilities.has(identifier)) {
					return false;
				}
				r_identifier = to_std(identifier);
				return true;
			},
			observable_tasks);
	return observable_tasks;
}

std::vector<std::uint8_t> GameplayAbilityNetworkBridge::encode_public_state() const {
	const GameplayAbilityComponent *comp = resolve_component();
	std::vector<std::uint8_t> empty;
	if (comp == nullptr) {
		return empty;
	}

	ga::ByteWriter writer(ga::MAX_SNAPSHOT_BYTES);
	writer.write_u64(std::uint64_t(comp->get_entity_id()));
	writer.write_u64(std::uint64_t(comp->get_current_tick()));

	const PackedStringArray all_attributes = comp->get_initialized_attributes();
	std::vector<String> visible_attributes;
	for (int i = 0; i < all_attributes.size(); ++i) {
		if (!hidden_attributes.has(all_attributes[i])) {
			visible_attributes.push_back(all_attributes[i]);
		}
	}
	writer.write_count(visible_attributes.size(), ga::MAX_ATTRIBUTES);
	for (const String &name : visible_attributes) {
		writer.write_string(to_std(name));
		ga::Fixed value = ga::Fixed::zero();
		ga::fixed_quantize(comp->get_attribute_current(name), value);
		ga::fixed_write(writer, value);
	}

	const PackedStringArray all_tags = comp->owned_tags();
	std::vector<String> visible_tags;
	for (int i = 0; i < all_tags.size(); ++i) {
		if (!hidden_tags.has(all_tags[i])) {
			visible_tags.push_back(all_tags[i]);
		}
	}
	writer.write_count(visible_tags.size(), ga::MAX_TAG_SOURCES);
	for (const String &name : visible_tags) {
		writer.write_string(to_std(name));
	}

	const PackedInt64Array specs = comp->granted_specs();
	std::vector<String> visible_abilities;
	for (int i = 0; i < specs.size(); ++i) {
		const Dictionary grant = comp->get_grant(specs[i]);
		if (grant.is_empty() || bool(grant.get("revoked", false))) {
			continue;
		}
		const String identifier = grant.get("ability_identifier", String());
		if (!identifier.is_empty() && !hidden_abilities.has(identifier)) {
			visible_abilities.push_back(identifier);
		}
	}
	writer.write_count(visible_abilities.size(), ga::MAX_ABILITY_GRANTS);
	for (const String &name : visible_abilities) {
		writer.write_string(to_std(name));
	}

	// Additive observable-task section (spec "Observable Task Observer Wire
	// Path", protocol-3 / `FeatureSet::OBSERVER_TASK_STATE`) -- see
	// `build_observable_task_records()`'s own doc comment for the full
	// selection/resolution contract this shares with
	// `encode_public_baseline()`/`send_public_state()`.
	const ga::Status task_section_status = ga::proto::encode_observer_task_section(build_observable_task_records(), writer);
	if (!task_section_status.ok()) {
		return empty;
	}

	if (!writer.ok()) {
		return empty;
	}
	return writer.take();
}

Dictionary GameplayAbilityNetworkBridge::decode_public_state(const std::vector<std::uint8_t> &p_bytes) const {
	ga::ByteReader reader(p_bytes);
	std::uint64_t entity = 0;
	std::uint64_t tick = 0;
	if (!reader.read_u64(entity) || !reader.read_u64(tick)) {
		return Dictionary();
	}
	Dictionary result;
	result["entity_id"] = int64_t(entity);
	result["tick"] = int64_t(tick);

	std::size_t attribute_count = 0;
	if (!reader.read_count(attribute_count, ga::MAX_ATTRIBUTES, 3)) {
		return Dictionary();
	}
	Dictionary attributes;
	for (std::size_t i = 0; i < attribute_count; ++i) {
		std::string name;
		ga::Fixed value = ga::Fixed::zero();
		if (!reader.read_string(name) || !ga::fixed_read(reader, value)) {
			return Dictionary();
		}
		attributes[String(name.c_str())] = ga::fixed_to_double(value);
	}
	result["attributes"] = attributes;

	std::size_t tag_count = 0;
	if (!reader.read_count(tag_count, ga::MAX_TAG_SOURCES, 2)) {
		return Dictionary();
	}
	PackedStringArray tags;
	for (std::size_t i = 0; i < tag_count; ++i) {
		std::string name;
		if (!reader.read_string(name)) {
			return Dictionary();
		}
		tags.push_back(String(name.c_str()));
	}
	result["tags"] = tags;

	std::size_t ability_count = 0;
	if (!reader.read_count(ability_count, ga::MAX_ABILITY_GRANTS, 2)) {
		return Dictionary();
	}
	PackedStringArray abilities;
	for (std::size_t i = 0; i < ability_count; ++i) {
		std::string name;
		if (!reader.read_string(name)) {
			return Dictionary();
		}
		abilities.push_back(String(name.c_str()));
	}
	result["granted_abilities"] = abilities;

	// Additive observable-task section (see `encode_public_state`'s own
	// comment for the whitelist/filtering contract this mirrors). A malformed
	// section fails the WHOLE decode closed -- returning an empty Dictionary,
	// exactly like every earlier field above -- rather than surfacing a
	// partial `observable_tasks` list, per "no partial task section reaches
	// the public state consumer".
	std::vector<ga::proto::ObserverTaskRecord> observable_task_records;
	if (!ga::proto::decode_observer_task_section(reader, observable_task_records).ok()) {
		return Dictionary();
	}
	Array observable_tasks;
	for (const ga::proto::ObserverTaskRecord &record : observable_task_records) {
		Dictionary task_dict;
		task_dict["task"] = int64_t(record.task.value);
		task_dict["execution"] = int64_t(record.execution.value);
		task_dict["ability_identifier"] = String(record.ability_identifier.c_str());
		task_dict["kind"] = int(record.kind);
		task_dict["start_tick"] = int64_t(record.start_tick);
		task_dict["has_deadline"] = record.has_deadline;
		task_dict["deadline_tick"] = record.has_deadline ? int64_t(record.deadline_tick) : int64_t(-1);
		observable_tasks.push_back(task_dict);
	}
	result["observable_tasks"] = observable_tasks;

	if (!reader.ok()) {
		return Dictionary();
	}
	return result;
}

// Wave 4 (task 3.3): every currently live identity in each PUBLIC-eligible
// section of `p_core` that the canonical delta codec can carry for this
// audience -- ATTRIBUTE, TAG_SOURCE, ABILITY_GRANT. Deliberately NEVER
// ABILITY_TASK: `AbilityComponent::apply_delta_batch`'s cross-section
// parent-execution check (ga_ability_component.cpp) requires a live
// ACTIVE_EXECUTION record for any task's owning execution, and
// ACTIVE_EXECUTION has no PUBLIC exposure at all
// (`ga::AudienceVisibilityConfig`'s own comment) -- a PUBLIC-audience mirror
// (`public_mirror`) never has one installed, so that check can never
// succeed; `build_observable_task_records()`/`encode_observer_task_section`
// carry task content instead (see `encode_public_baseline()`'s own doc
// comment). ACTIVE_EXECUTION/ACTIVE_EFFECT/TARGET_SESSION are never included
// either: none has PUBLIC exposure today (see `ga::AudienceVisibilityConfig`'s
// own comment, ga_change_tracking.h, and this class's own
// `send_target_state_to_peer` call sites, both owner-only). Deliberately does
// NOT pre-filter by THIS bridge's own hidden_* lists (or `p_core`'s own
// `visibility_config()`, which `sync_visibility_config()` already keeps in
// agreement with them) -- see `encode_public_baseline()`'s own doc comment
// for why passing every live identity, hidden or not, is still safe.
std::vector<ga::DirtyRecord> GameplayAbilityNetworkBridge::build_full_public_dirty(const ga::AbilityComponent &p_core) const {
	std::vector<ga::DirtyRecord> dirty;
	for (ga::DefinitionId id : p_core.attributes().initialized_attributes()) {
		dirty.push_back(ga::DirtyRecord{ ga::ChangeSection::ATTRIBUTE, std::uint64_t(id) });
	}
	for (const auto &entry : p_core.tags().all_source_records()) {
		dirty.push_back(ga::DirtyRecord{ ga::ChangeSection::TAG_SOURCE, entry.first.value });
	}
	for (ga::AbilitySpecId spec : p_core.granted_specs()) {
		dirty.push_back(ga::DirtyRecord{ ga::ChangeSection::ABILITY_GRANT, spec.value });
	}
	return dirty;
}

std::vector<std::uint8_t> GameplayAbilityNetworkBridge::encode_public_baseline() const {
	const GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->core_component() == nullptr) {
		return {};
	}
	const ga::AbilityComponent *core = comp->core_component();
	const std::vector<ga::DirtyRecord> dirty = build_full_public_dirty(*core);
	std::vector<std::uint8_t> delta_bytes;
	// `p_session_coordinator = nullptr`: `build_full_public_dirty` never
	// names a TARGET_SESSION identity (no PUBLIC exposure -- see that
	// method's own comment), so `write_delta_batch`'s own "null coordinator
	// + dirty TARGET_SESSION identity fails closed" check can never fire
	// here, exactly like `send_owner_event_batch`'s identical reasoning.
	const ga::Status status = ga::proto::encode_delta_batch(*core, ga::ChangeAudience::PUBLIC, dirty, ga::DeltaBaseline{},
			/*p_session_coordinator=*/ nullptr, ga::MAX_SNAPSHOT_BYTES, delta_bytes);
	if (!status.ok()) {
		return {};
	}
	// A baseline represents COMPLETE state, so the task section is ALWAYS
	// present, even when there are zero observable tasks right now (asserted
	// emptiness, never omission -- see `compose_public_payload`'s own doc
	// comment on what an absent section means).
	ga::ByteWriter task_writer(ga::MAX_SNAPSHOT_BYTES);
	const ga::Status task_status = ga::proto::encode_observer_task_section(build_observable_task_records(), task_writer);
	if (!task_status.ok() || !task_writer.ok()) {
		return {};
	}
	const std::vector<std::uint8_t> task_section_bytes = task_writer.take();
	return compose_public_payload(delta_bytes, &task_section_bytes);
}

void GameplayAbilityNetworkBridge::send_snapshot_to_peer(int p_peer, ga::proto::ResyncTrigger p_trigger, int64_t p_tick) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return;
	}
	const bool owner = peer_is_owner(p_peer);
	// Wave 4 (task 3.3): `r.valid_as_of`/`r.payload` now come from whichever
	// audience's OWN stream/codec applies -- `owner_stream`/
	// `encode_full_snapshot()` for an owner, unchanged; `public_stream`/
	// `encode_public_baseline()` (the canonical delta-batch-as-baseline, not
	// the bespoke `encode_public_state()`) for an observer, so the SAME
	// `ga::proto::decode_and_apply_delta_batch` codec that applies every
	// later incremental public delta also applies this first one -- see
	// `encode_public_baseline()`'s own doc comment.
	ga::proto::SnapshotProducer producer = [this, owner, p_tick](ga::EntityId, ga::proto::SnapshotProductionResult &r) -> ga::Status {
		const GameplayAbilityComponent *c = resolve_component();
		if (c == nullptr) {
			return ga::make_status(ga::StatusCode::INTERNAL_ERROR);
		}
		r.authoritative_tick = ga::Tick(p_tick);
		r.valid_as_of = owner ? owner_stream->head_sequence() : public_stream->head_sequence();
		r.manifest_fingerprint = std::uint64_t(c->get_content_manifest_fingerprint());
		r.payload = owner ? encode_full_snapshot() : encode_public_baseline();
		return r.payload.empty() ? ga::make_status(ga::StatusCode::INTERNAL_ERROR) : ga::ok_status();
	};
	ga::proto::SnapshotEnvelope envelope;
	if (!resync_coordinator->produce_unconditional(ga::EntityId{ std::uint64_t(comp->get_entity_id()) }, p_trigger, producer, envelope).ok()) {
		return;
	}
	std::vector<std::uint8_t> envelope_bytes;
	if (!ga::proto::encode_snapshot_envelope(envelope, envelope_bytes).ok()) {
		return;
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::SNAPSHOT, ga::proto::SessionId(local_session_id), envelope_bytes,
				 ga::proto::message_byte_limit(ga::proto::MessageType::SNAPSHOT), framed)
					 .ok()) {
		return;
	}
	rpc_id(p_peer, "_rpc_snapshot", to_packed(framed));
	if (owner) {
		send_target_state_to_peer(p_peer,
				ga::EntityId{
						std::uint64_t(comp->get_entity_id()) });
	}
	// Wave 3 (task 3.2/3.5): a fresh full snapshot is a fresh baseline for
	// replication-cursor purposes too -- reset the peer's cursor to the
	// revision this snapshot's payload was actually built from so the NEXT
	// gating decision (`send_owner_event_batch`/`send_public_state`)
	// compares against the right starting point, whether this call came
	// from FIRST_RELEVANCE, an explicit resync request, or a
	// `DELTA_OVERFLOW`/`BATCH_OVERFLOW` fallback. Read AFTER the send above
	// (never before): this whole method runs synchronously with no
	// intervening transaction, so the revision cannot have changed, but
	// reading it here keeps the "the cursor names what was ACTUALLY sent"
	// invariant textually obvious rather than relying on that timing fact.
	if (comp->core_component() != nullptr) {
		const ga::ChangeAudience audience = owner ? ga::ChangeAudience::OWNER_FACING : ga::ChangeAudience::PUBLIC;
		const std::uint64_t revision = comp->core_component()->change_tracker().revision(audience);
		ReplicationCursor &cursor = owner ? owner_cursors[p_peer] : public_cursors[p_peer];
		cursor.revision = revision;
		cursor.ticks_since_send = 0;
	}
}

void GameplayAbilityNetworkBridge::send_heartbeat(int p_peer, ga::EventSeq p_head_sequence, int64_t p_tick) {
	ga::proto::HeartbeatPayload heartbeat;
	heartbeat.authoritative_tick = ga::Tick(p_tick);
	heartbeat.stream_head_sequence = p_head_sequence;
	std::vector<std::uint8_t> payload;
	if (!ga::proto::encode_heartbeat(heartbeat, payload).ok()) {
		return;
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::HEARTBEAT, ga::proto::SessionId(local_session_id), payload,
				 ga::proto::message_byte_limit(ga::proto::MessageType::HEARTBEAT), framed)
					 .ok()) {
		return;
	}
	rpc_id(p_peer, "_rpc_heartbeat", to_packed(framed));
	// Test/debug bookkeeping only -- see `debug_peek_last_heartbeat_frame`/
	// `debug_heartbeat_send_count`'s own doc comments (gameplay_ability_
	// network_bridge.h). Never consulted by any real send/gate decision.
	debug_last_heartbeat_frame[p_peer] = framed;
	++debug_heartbeat_count[p_peer];
}

PackedByteArray GameplayAbilityNetworkBridge::debug_peek_owner_event_batch_frame(int64_t p_since_sequence) const {
	if (owner_stream == nullptr) {
		return PackedByteArray();
	}
	std::vector<std::uint8_t> payload;
	if (!owner_stream->try_get_payload(ga::EventSeq{ std::uint64_t(p_since_sequence) }, payload)) {
		return PackedByteArray();
	}
	const ga::proto::EventBatchHeader *header = owner_stream->find_batch_after(ga::EventSeq{ std::uint64_t(p_since_sequence) });
	if (header == nullptr) {
		return PackedByteArray();
	}
	std::vector<std::uint8_t> encoded;
	if (!ga::proto::encode_event_batch(*header, payload, encoded).ok()) {
		return PackedByteArray();
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::EVENT_BATCH, ga::proto::SessionId(local_session_id), encoded,
				 ga::proto::message_byte_limit(ga::proto::MessageType::EVENT_BATCH), framed)
					 .ok()) {
		return PackedByteArray();
	}
	return to_packed(framed);
}

PackedByteArray GameplayAbilityNetworkBridge::debug_peek_last_heartbeat_frame(int p_peer) const {
	const auto it = debug_last_heartbeat_frame.find(p_peer);
	if (it == debug_last_heartbeat_frame.end()) {
		return PackedByteArray();
	}
	return to_packed(it->second);
}

int64_t GameplayAbilityNetworkBridge::debug_heartbeat_send_count(int p_peer) const {
	const auto it = debug_heartbeat_count.find(p_peer);
	return it == debug_heartbeat_count.end() ? 0 : int64_t(it->second);
}

int64_t GameplayAbilityNetworkBridge::debug_owner_stream_head_sequence() const {
	return owner_stream == nullptr ? 0 : int64_t(owner_stream->head_sequence().value);
}

// Owner push (task 3.2 "Granular Owner Delta Batches" / 3.4 "Change-Gated
// State Sends" / 3.5 "Delta Bounds and Snapshot Fallback" / 3.6 "Session-
// State Change Gating"). Called once per authoritative tick, per relevant
// ALREADY-SYNCED owner peer (`push_full_state`'s own `synced_peers` gate --
// a peer's FIRST send is always the unconditional `send_snapshot_to_peer`
// FIRST_RELEVANCE path above, which also seeds this peer's `owner_cursors`
// entry, so a normal call here always finds one already established).
void GameplayAbilityNetworkBridge::send_owner_event_batch(int p_peer, int64_t p_tick) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->core_component() == nullptr) {
		return;
	}
	ga::AbilityComponent *core = comp->core_component();
	const ga::ChangeTracker &tracker = core->change_tracker();
	const std::uint64_t revision = tracker.revision(ga::ChangeAudience::OWNER_FACING);
	// `[]`'s default-construct (revision 0, never sent) is a safe fallback
	// for the -- not expected in normal operation -- case of a missing
	// entry; see this class's own `owner_cursors` doc comment.
	ReplicationCursor &cursor = owner_cursors[p_peer];
	const bool overflowed = tracker.cursor_overflowed(ga::ChangeAudience::OWNER_FACING, cursor.revision);
	const ga::proto::SendGateAction action = ga::proto::decide_send_gate_action(
			cursor.revision, revision, overflowed, cursor.ticks_since_send, ga::HEARTBEAT_SUPPRESSED_CADENCE_TICKS);

	if (action == ga::proto::SendGateAction::SEND_SNAPSHOT_OVERFLOW) {
		// Task 3.5: the peer's cursor fell off `ChangeTracker`'s bounded
		// ring -- a correct delta can no longer be computed for it (see
		// `ChangeTracker::cursor_overflowed`'s own doc comment). Fall back
		// to a fresh full snapshot exactly like the pre-existing
		// `BATCH_OVERFLOW` path did for an oversized payload;
		// `send_snapshot_to_peer` resets `owner_cursors[p_peer]` (and
		// unconditionally re-sends target-session state) on success.
		send_snapshot_to_peer(p_peer, ga::proto::ResyncTrigger::DELTA_OVERFLOW, p_tick);
		return;
	}
	if (action == ga::proto::SendGateAction::SUPPRESSED) {
		++cursor.ticks_since_send;
		return;
	}
	if (action == ga::proto::SendGateAction::HEARTBEAT) {
		send_heartbeat(p_peer, owner_stream->head_sequence(), p_tick);
		cursor.ticks_since_send = 0;
		return;
	}

	// SEND_STATE: something changed since `cursor.revision`. Split the
	// dirty set into this component's own six delta-codec sections
	// (task 3.2) and TARGET_SESSION (task 3.6, gated on the SAME cursor but
	// delivered through the pre-existing, separate `TARGET_STATE` channel --
	// see `send_target_state_to_peer`'s own call site below for why this
	// bridge does not fold retained target-session state into the owner
	// delta batch itself).
	const std::vector<ga::DirtyRecord> owner_dirty = tracker.dirty_since(ga::ChangeAudience::OWNER_FACING, cursor.revision);
	std::vector<ga::DirtyRecord> component_dirty;
	component_dirty.reserve(owner_dirty.size());
	bool target_session_dirty = false;
	for (const ga::DirtyRecord &record : owner_dirty) {
		if (record.section == ga::ChangeSection::TARGET_SESSION) {
			target_session_dirty = true;
		} else {
			component_dirty.push_back(record);
		}
	}

	bool overflow_fallback = false;
	if (!component_dirty.empty()) {
		// `DeltaBaseline{}` (empty, task 2.1's documented default): this
		// bridge keeps no per-peer identity-existence ledger, so every
		// still-live touched identity encodes as `DeltaOpKind::ADD` rather
		// than `UPDATE` -- always a SAFE over-approximation (see
		// `DeltaBaseline`'s own doc comment, ga_delta.h: apply treats ADD
		// and UPDATE identically, so this only affects a diagnostic op tag,
		// never applied state).
		//
		// `p_session_coordinator = nullptr`: TARGET_SESSION was already
		// filtered out of `component_dirty` above, so `write_delta_batch`
		// never encounters a dirty TARGET_SESSION identity here and its own
		// "null coordinator + dirty TARGET_SESSION identity fails closed"
		// check (ga_ability_component.cpp) can never fire.
		//
		// `MAX_SNAPSHOT_BYTES` as the writer's own cap (matching
		// `encode_full_snapshot`'s implicit default): a delta is expected to
		// stay far under this, and the REAL wire bound is
		// `event_batch_fits_stream` immediately below, checked exactly like
		// the pre-existing full-snapshot path checked it.
		std::vector<std::uint8_t> payload;
		const ga::Status encode_status = ga::proto::encode_delta_batch(*core, ga::ChangeAudience::OWNER_FACING,
				component_dirty, ga::DeltaBaseline{}, /*p_session_coordinator=*/ nullptr, ga::MAX_SNAPSHOT_BYTES, payload);
		if (!encode_status.ok() || !ga::proto::event_batch_fits_stream(payload.size())) {
			overflow_fallback = true;
		} else {
			ga::proto::EventBatchHeader header;
			// Unreachable in practice once `event_batch_fits_stream`
			// returned true above (see that function's own doc comment for
			// the proof); kept as a defensive fail-closed path rather than
			// an assert, matching this file's existing convention. The
			// stream's sequence has NOT advanced if this fails -- `append_
			// batch` itself never mutates on a failed call.
			if (!owner_stream->append_batch(ga::EntityId{ std::uint64_t(comp->get_entity_id()) },
							ga::Tick(p_tick), payload, 1, header)
							 .ok()) {
				overflow_fallback = true;
			} else {
				std::vector<std::uint8_t> encoded;
				std::vector<std::uint8_t> framed;
				if (!ga::proto::encode_event_batch(header, payload, encoded).ok() ||
						!ga::proto::encode_message(ga::proto::MessageType::EVENT_BATCH, ga::proto::SessionId(local_session_id), encoded,
								 ga::proto::message_byte_limit(ga::proto::MessageType::EVENT_BATCH), framed)
										 .ok()) {
					// Unreachable in practice for the identical reason
					// `event_batch_fits_stream` documents -- but the stream
					// HAS already advanced at this point (append_batch
					// succeeded above), so this branch cannot un-advance
					// it; kept defensive anyway, matching the pre-existing
					// full-snapshot path's own identical comment.
					overflow_fallback = true;
				} else {
					rpc_id(p_peer, "_rpc_event_batch", to_packed(framed));
				}
			}
		}
	}

	if (overflow_fallback) {
		send_snapshot_to_peer(p_peer, ga::proto::ResyncTrigger::DELTA_OVERFLOW, p_tick);
		return;
	}

	if (target_session_dirty) {
		send_target_state_to_peer(p_peer, ga::EntityId{ std::uint64_t(comp->get_entity_id()) });
	}
	// Advance the cursor to the revision just fully represented -- whether
	// that meant an actual delta batch (component_dirty non-empty), a
	// target-state-only send (component_dirty empty, target_session_dirty
	// true), or -- unreachable given SEND_STATE's own precondition, kept for
	// clarity -- neither. `ticks_since_send` resets on ANY message sent to
	// this peer this branch (delta batch and/or target-state), a documented
	// simplification: a target-state-only tick does not itself carry an
	// `authoritative_tick` sample, so in the narrow, unlikely combination of
	// "target session churns every tick while the component's own six
	// sections stay perfectly idle" the tick estimator could go slightly
	// longer than the documented cadence between corrections -- acceptable
	// because that combination is not the common case this bound targets
	// (ordinary target-session activity accompanies ability/effect activity
	// on the SAME commit far more often than not).
	cursor.revision = revision;
	cursor.ticks_since_send = 0;
}

// Observer push (Wave 4, add-granular-delta-replication-2026-07-27, task
// 3.3 "Sequenced Observer Delta Streams"). Mirrors `send_owner_event_batch`
// immediately below, one audience over: PUBLIC instead of OWNER_FACING,
// `public_stream`/`public_cursors` instead of `owner_stream`/`owner_cursors`,
// and `encode_public_baseline()`'s canonical delta-batch-as-baseline instead
// of `encode_full_snapshot()` for the first-relevance/overflow snapshot
// path. Called once per authoritative tick for every relevant observer peer
// (`push_full_state`'s else-branch) -- unlike owners, there is no separate
// `synced_peers`-gated dispatch here: "never sent yet" is detected via
// `public_cursors` map membership below, exactly as before this wave.
void GameplayAbilityNetworkBridge::send_public_state(int p_peer, int64_t p_tick) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->core_component() == nullptr) {
		return;
	}
	const auto existing = public_cursors.find(p_peer);
	if (existing == public_cursors.end()) {
		// First relevance: an unconditional visibility-filtered public
		// baseline, exactly like an owner's FIRST_RELEVANCE snapshot --
		// `send_snapshot_to_peer` seeds `public_cursors[p_peer]` on success.
		send_snapshot_to_peer(p_peer, ga::proto::ResyncTrigger::FIRST_RELEVANCE, p_tick);
		return;
	}

	ga::AbilityComponent *core = comp->core_component();
	const ga::ChangeTracker &tracker = core->change_tracker();
	const std::uint64_t revision = tracker.revision(ga::ChangeAudience::PUBLIC);
	ReplicationCursor &cursor = existing->second;
	const bool overflowed = tracker.cursor_overflowed(ga::ChangeAudience::PUBLIC, cursor.revision);
	const ga::proto::SendGateAction action = ga::proto::decide_send_gate_action(
			cursor.revision, revision, overflowed, cursor.ticks_since_send, ga::HEARTBEAT_SUPPRESSED_CADENCE_TICKS);

	if (action == ga::proto::SendGateAction::SEND_SNAPSHOT_OVERFLOW) {
		// Task 3.5's fallback, PUBLIC audience: this peer's cursor fell off
		// the bounded change-history ring -- fall back to a fresh baseline,
		// exactly like the owner path's identical branch.
		send_snapshot_to_peer(p_peer, ga::proto::ResyncTrigger::DELTA_OVERFLOW, p_tick);
		return;
	}
	if (action == ga::proto::SendGateAction::SUPPRESSED) {
		++cursor.ticks_since_send;
		return;
	}
	if (action == ga::proto::SendGateAction::HEARTBEAT) {
		send_heartbeat(p_peer, public_stream->head_sequence(), p_tick);
		cursor.ticks_since_send = 0;
		return;
	}

	// SEND_STATE: something PUBLIC-visible changed since `cursor.revision`.
	// Two kinds of dirty record never ride the canonical delta section
	// itself, filtered out of `component_dirty` here:
	//   - TARGET_SESSION -- unlike the owner path, there is no PUBLIC
	//     target-state delivery channel today (`send_target_state_to_peer`
	//     is owner-only by its own `peer_is_owner` guard, unchanged by this
	//     wave and out of this task's scope), so a PUBLIC-visible
	//     target-session change (task 1.4's `record_target_session_change(...,
	//     p_public_visible=true)`) is simply never represented on the wire
	//     for observers -- exactly matching what the pre-Wave-4
	//     `encode_public_state()` feed already never carried.
	//   - ABILITY_TASK -- see `build_full_public_dirty`'s own doc comment:
	//     `AbilityComponent::apply_delta_batch`'s cross-section parent-
	//     execution check can never succeed against `public_mirror` (no
	//     ACTIVE_EXECUTION content, ever). Tracked separately as
	//     `task_dirty` and represented instead via the SAME observer-task
	//     section `encode_public_baseline()` uses, appended by
	//     `compose_public_payload` -- present ONLY when something task-
	//     related actually changed (an absent section means "unchanged," per
	//     that function's own doc comment), unlike the baseline's
	//     unconditional inclusion.
	const std::vector<ga::DirtyRecord> public_dirty = tracker.dirty_since(ga::ChangeAudience::PUBLIC, cursor.revision);
	std::vector<ga::DirtyRecord> component_dirty;
	component_dirty.reserve(public_dirty.size());
	bool task_dirty = false;
	for (const ga::DirtyRecord &record : public_dirty) {
		if (record.section == ga::ChangeSection::TARGET_SESSION) {
			continue;
		}
		if (record.section == ga::ChangeSection::ABILITY_TASK) {
			task_dirty = true;
			continue;
		}
		component_dirty.push_back(record);
	}

	bool overflow_fallback = false;
	if (!component_dirty.empty() || task_dirty) {
		// `DeltaBaseline{}` (empty): matches `send_owner_event_batch`'s own
		// identical reasoning -- this bridge keeps no per-peer identity-
		// existence ledger, so every still-live touched identity encodes as
		// `DeltaOpKind::ADD` rather than `UPDATE`, a safe over-approximation.
		// Called even when `component_dirty` is empty (task-only churn) so
		// the composed payload always carries a well-formed, if empty,
		// canonical delta portion -- `decode_and_apply_delta_batch` requires
		// one, never a zero-length buffer.
		std::vector<std::uint8_t> delta_bytes;
		const ga::Status encode_status = ga::proto::encode_delta_batch(*core, ga::ChangeAudience::PUBLIC,
				component_dirty, ga::DeltaBaseline{}, /*p_session_coordinator=*/ nullptr, ga::MAX_SNAPSHOT_BYTES, delta_bytes);
		std::vector<std::uint8_t> task_section_bytes;
		bool task_encode_failed = false;
		if (encode_status.ok() && task_dirty) {
			ga::ByteWriter task_writer(ga::MAX_SNAPSHOT_BYTES);
			const ga::Status task_status = ga::proto::encode_observer_task_section(build_observable_task_records(), task_writer);
			if (task_status.ok() && task_writer.ok()) {
				task_section_bytes = task_writer.take();
			} else {
				// A task update genuinely could not be encoded (e.g. a
				// documented capacity bound) -- this must fall back to a
				// fresh snapshot, NEVER silently drop the task change by
				// sending the rest of the batch without it.
				task_encode_failed = true;
			}
		}
		const std::vector<std::uint8_t> payload = (encode_status.ok() && !task_encode_failed)
				? compose_public_payload(delta_bytes, task_dirty ? &task_section_bytes : nullptr)
				: std::vector<std::uint8_t>();
		if (!encode_status.ok() || task_encode_failed || !ga::proto::event_batch_fits_stream(payload.size())) {
			overflow_fallback = true;
		} else {
			ga::proto::EventBatchHeader header;
			// Consult `event_batch_fits_stream` BEFORE this call, never
			// after -- see `send_owner_event_batch`'s identical comment and
			// this change's own "the sequence must never advance for an
			// unsent batch" requirement: `public_stream`'s head only moves
			// once `append_batch` itself succeeds.
			if (!public_stream->append_batch(ga::EntityId{ std::uint64_t(comp->get_entity_id()) },
							ga::Tick(p_tick), payload, 1, header)
							 .ok()) {
				overflow_fallback = true;
			} else {
				std::vector<std::uint8_t> encoded;
				std::vector<std::uint8_t> framed;
				if (!ga::proto::encode_event_batch(header, payload, encoded).ok() ||
						!ga::proto::encode_message(ga::proto::MessageType::EVENT_BATCH, ga::proto::SessionId(local_session_id), encoded,
								 ga::proto::message_byte_limit(ga::proto::MessageType::EVENT_BATCH), framed)
										 .ok()) {
					// Unreachable in practice -- see `send_owner_event_batch`'s
					// identical comment (the stream already advanced above;
					// this branch cannot un-advance it, kept defensive anyway).
					overflow_fallback = true;
				} else {
					rpc_id(p_peer, "_rpc_event_batch", to_packed(framed));
				}
			}
		}
	}

	if (overflow_fallback) {
		send_snapshot_to_peer(p_peer, ga::proto::ResyncTrigger::DELTA_OVERFLOW, p_tick);
		return;
	}

	// Advance the cursor to the revision just fully represented -- whether
	// that meant an actual delta batch (component_dirty and/or task_dirty
	// non-empty) or nothing sent at all this tick (both empty because the
	// ONLY thing dirty was an undeliverable-to-observers TARGET_SESSION
	// change): either way every PUBLIC-visible, delta-representable fact up
	// to `revision` has now been accounted for, so a peer whose only dirty
	// fact is target-session churn does not re-trigger SEND_STATE every
	// tick forever.
	cursor.revision = revision;
	cursor.ticks_since_send = 0;
}

void GameplayAbilityNetworkBridge::push_full_state(int64_t p_tick) {
	try_wire_component(); // on-demand: complete deferred wiring if a prior _ready()/set_component_path() could not yet.
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		diagnose_unresolved_component();
		return;
	}
	if (!comp->is_configured() || comp->get_role() == GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	ensure_server_state();
	correct_estimated_tick(ga::Tick(p_tick));

	const PackedInt32Array peers = current_relevant_peers();
	for (int i = 0; i < peers.size(); ++i) {
		const int32_t peer = peers[i];
		if (peer == 0) {
			continue;
		}
		// Finding 3b: a peer that never completed (or failed) the compatibility
		// handshake must never receive ANY state -- an incompatible or
		// not-yet-checked peer could otherwise decode a snapshot/event batch
		// its own build disagrees with (different tick rate, fixed-point
		// scale, content manifest, ...). `synced_peers` is deliberately left
		// untouched for a skipped peer: the `continue` below runs BEFORE that
		// bookkeeping, so once this peer later handshakes successfully it is
		// still treated as "never synced" and gets its FIRST_RELEVANCE
		// snapshot exactly like a peer seen for the first time.
		if (handshake_ok_peers.find(peer) == handshake_ok_peers.end()) {
			continue;
		}
		const bool owner = peer_is_owner(peer);
		if (owner) {
			if (synced_peers.find(peer) == synced_peers.end()) {
				send_snapshot_to_peer(peer, ga::proto::ResyncTrigger::FIRST_RELEVANCE, p_tick);
				synced_peers.insert(peer);
			} else {
				send_owner_event_batch(peer, p_tick);
			}
		} else {
			send_public_state(peer, p_tick);
		}
	}
}

void GameplayAbilityNetworkBridge::request_resync(int p_reason) {
	try_wire_component(); // on-demand: complete deferred wiring if a prior _ready()/set_component_path() could not yet.
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		diagnose_unresolved_component();
		return;
	}
	if (!is_multiplayer_active() || !ga::proto::is_valid_resync_reason(std::uint8_t(p_reason))) {
		return;
	}
	ga::proto::ResyncRequest request;
	request.session = ga::proto::SessionId(local_session_id);
	request.component = ga::EntityId{ std::uint64_t(comp->get_entity_id()) };
	// Wave 4 (task 4.2): report whichever stream serves THIS bridge's own
	// audience -- `client_stream` for an owner, `public_client_stream` for
	// an observer -- never the other one (a bridge only ever constructs the
	// stream matching its own `owner_view`; see `ensure_client_state`/
	// `ensure_public_client_state`'s own doc comments).
	request.confirmed_sequence = owner_view
			? (client_stream != nullptr ? client_stream->confirmed_sequence() : ga::INVALID_EVENT_SEQ)
			: (public_client_stream != nullptr ? public_client_stream->confirmed_sequence() : ga::INVALID_EVENT_SEQ);
	request.reason = static_cast<ga::proto::ResyncReason>(p_reason);

	std::vector<std::uint8_t> payload;
	if (!ga::proto::encode_resync_request(request, payload).ok()) {
		return;
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::RESYNC_REQUEST, ga::proto::SessionId(local_session_id), payload,
				 ga::proto::message_byte_limit(ga::proto::MessageType::RESYNC_REQUEST), framed)
					 .ok()) {
		return;
	}
	rpc_id(server_peer_id, "_rpc_resync_request", to_packed(framed));
}

void GameplayAbilityNetworkBridge::_rpc_resync_request(const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->get_role() == GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int32_t peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	if (peer == 0) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::RESYNC_REQUEST, header, payload)) {
		return;
	}
	ga::proto::ResyncRequest request;
	if (!ga::proto::decode_resync_request(payload, request).ok()) {
		return;
	}

	// Finding 3c: an unhandshaked or not-currently-relevant peer must never
	// be served a snapshot just by asking for one -- this endpoint would
	// otherwise be a way around both the handshake gate (Finding 3b) and
	// relevance filtering `push_full_state`'s own routine per-tick path
	// already enforces. Fail closed: return with NO reply of any kind (a
	// bounded LOCAL diagnostic is fine -- it never crosses the wire back to
	// the requesting peer).
	if (handshake_ok_peers.find(peer) == handshake_ok_peers.end()) {
		emit_signal("network_diagnostic", status_dict(ga::make_status(ga::StatusCode::PROTOCOL_MISMATCH)));
		return;
	}
	const PackedInt32Array relevant_peers = current_relevant_peers();
	bool peer_is_relevant = false;
	for (int i = 0; i < relevant_peers.size(); ++i) {
		if (relevant_peers[i] == peer) {
			peer_is_relevant = true;
			break;
		}
	}
	if (!peer_is_relevant) {
		emit_signal("network_diagnostic", status_dict(ga::make_status(ga::StatusCode::CAPABILITY_VIOLATION, ga::DiagnosticId::TARGET_NOT_RELEVANT)));
		return;
	}

	const bool owner = peer_is_owner(peer);
	// Wave 4 (task 3.3): same audience-appropriate stream/codec split as
	// `send_snapshot_to_peer`'s own producer -- see that method's doc
	// comment.
	ga::proto::SnapshotProducer producer = [this, owner](ga::EntityId, ga::proto::SnapshotProductionResult &r) -> ga::Status {
		const GameplayAbilityComponent *c = resolve_component();
		if (c == nullptr) {
			return ga::make_status(ga::StatusCode::INTERNAL_ERROR);
		}
		r.authoritative_tick = ga::Tick(c->get_current_tick());
		r.valid_as_of = owner ? owner_stream->head_sequence() : public_stream->head_sequence();
		r.manifest_fingerprint = std::uint64_t(c->get_content_manifest_fingerprint());
		r.payload = owner ? encode_full_snapshot() : encode_public_baseline();
		return r.payload.empty() ? ga::make_status(ga::StatusCode::INTERNAL_ERROR) : ga::ok_status();
	};
	ga::proto::SnapshotEnvelope envelope;
	const ga::Status status = resync_coordinator->produce_for_request(ga::proto::PeerId(peer), request, ga::Tick(comp->get_current_tick()),
			ga::SessionTiming{ effective_tick_rate() }, producer, envelope);
	if (!status.ok()) {
		return; // rate-limited or production failed -- bounded, no partial work.
	}
	std::vector<std::uint8_t> envelope_bytes;
	if (!ga::proto::encode_snapshot_envelope(envelope, envelope_bytes).ok()) {
		return;
	}
	std::vector<std::uint8_t> framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::SNAPSHOT, ga::proto::SessionId(local_session_id), envelope_bytes,
				 ga::proto::message_byte_limit(ga::proto::MessageType::SNAPSHOT), framed)
					 .ok()) {
		return;
	}
	synced_peers.insert(peer);
	rpc_id(peer, "_rpc_snapshot", to_packed(framed));
	if (owner) {
		send_target_state_to_peer(peer,
				ga::EntityId{
						std::uint64_t(comp->get_entity_id()) });
	}
	// Wave 3: this explicit-request path sends a fresh full snapshot exactly
	// like `send_snapshot_to_peer` does -- reset this peer's replication
	// cursor the same way (see that method's own identical comment) so the
	// next gating decision compares against this snapshot's own revision,
	// not a stale pre-resync one.
	if (comp->core_component() != nullptr) {
		const ga::ChangeAudience audience = owner ? ga::ChangeAudience::OWNER_FACING : ga::ChangeAudience::PUBLIC;
		const std::uint64_t revision = comp->core_component()->change_tracker().revision(audience);
		ReplicationCursor &cursor = owner ? owner_cursors[peer] : public_cursors[peer];
		cursor.revision = revision;
		cursor.ticks_since_send = 0;
	}
}

void GameplayAbilityNetworkBridge::_rpc_snapshot(const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::SNAPSHOT, header, payload)) {
		return;
	}
	ga::proto::SnapshotEnvelope envelope;
	if (!ga::proto::decode_snapshot_envelope(payload, envelope).ok()) {
		comp->notify_replication_gap(int(ga::StatusCode::DECODE_FAILED), 0);
		return;
	}
	correct_estimated_tick(envelope.authoritative_tick);

	if (owner_view) {
		ensure_client_state();
		// Finding 2a: `apply_confirmed_payload` decides, per call, whether to
		// plain-restore or route through `reconcile_snapshot()` (when this
		// component is predicting AND has pending journal entries) -- either
		// way `e.payload` is restored EXACTLY ONCE.
		ga::proto::ApplySnapshotFn apply = [this, comp](const ga::proto::SnapshotEnvelope &e) -> ga::Status {
			return apply_confirmed_payload(comp, e.payload, e.authoritative_tick);
		};
		const ga::Status status = ga::proto::apply_snapshot_envelope(envelope, std::uint64_t(comp->get_content_manifest_fingerprint()), *client_stream, apply);
		if (status.ok()) {
			// Task 8.10: this is now the latest CONFIRMED baseline
			// `PredictionReconciler::reconcile` restores to on a later
			// rejection or divergence.
			last_confirmed_snapshot = envelope.payload;
			// Finding 2f: a fresh confirmed baseline just landed -- if
			// prediction was disabled pending recovery (on_baseline_lost/
			// on_disconnected/on_manifest_changed/sweep_expired), there is
			// now something trustworthy to predict against again.
			if (ga::PredictingComponent *predicting = comp->predicting_component()) {
				if (predicting->is_disabled_pending_recovery()) {
					predicting->resume_after_recovery();
				}
			}
			Dictionary d;
			d["confirmed_sequence"] = int64_t(client_stream->confirmed_sequence().value);
			emit_signal("state_synced", d);
		} else {
			ga::PredictingComponent *predicting = comp->predicting_component();
			if (status.code == ga::StatusCode::MANIFEST_MISMATCH) {
				// Finding 2b: the content manifest changed underneath a
				// predicting client -- cancel every pending prediction (CANCEL
				// cues) and disable prediction BEFORE the existing
				// diagnostic/replication_gap signal below, matching
				// `on_manifest_changed()`'s own documented contract.
				if (predicting != nullptr) {
					predicting->on_manifest_changed();
				}
			} else {
				// Finding 5.2: the restore (plain or reconcile-driven)
				// failed -- `apply_confirmed_payload` already rolled this
				// component back to its pre-restore state, or quarantined
				// it if even that failed (see `GameplayAbilityComponent::
				// restore_snapshot`/`reconcile_snapshot`'s own doc
				// comments). Either way this component's predicted baseline
				// is gone: disable prediction too, and drive automatic
				// recovery via a fresh resync instead of just diagnosing
				// and leaving prediction dangling against a baseline that
				// was never actually established.
				if (predicting != nullptr) {
					predicting->disable_and_clear();
				}
				request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
			}
			comp->notify_replication_gap(int(status.code), int64_t(status.detail));
			emit_signal("replication_gap", status_dict(status));
		}
	} else {
		// Wave 4 (task 3.3/4.2): the observer's own visibility-filtered
		// baseline -- `encode_public_baseline()`'s canonical delta-batch-as-
		// baseline bytes, riding the SAME `SnapshotEnvelope`/`_rpc_snapshot`
		// path an owner's baseline always has. `ensure_public_client_state()`
		// mirrors `ensure_client_state()` above; `apply_snapshot_envelope`
		// performs the SAME component-identity/manifest-fingerprint checks
		// for this audience it always has for owners (see that function's
		// own doc comment), establishing/re-establishing
		// `public_client_stream`'s confirmed sequence on success.
		ensure_public_client_state();
		// A fresh baseline discards any previous mirror -- see
		// `GameplayAbilityComponent::build_scratch_mirror()`'s own doc
		// comment for why a stale mirror must never survive a resync (an
		// OMITTED section in a delta batch means "unchanged," never "empty").
		ga::proto::ApplySnapshotFn apply = [this, comp](const ga::proto::SnapshotEnvelope &e) -> ga::Status {
			public_mirror = comp->build_scratch_mirror();
			if (public_mirror == nullptr) {
				return ga::make_status(ga::StatusCode::INTERNAL_ERROR);
			}
			return apply_public_delta(e.payload, int64_t(e.authoritative_tick));
		};
		const ga::Status status = ga::proto::apply_snapshot_envelope(envelope, std::uint64_t(comp->get_content_manifest_fingerprint()), *public_client_stream, apply);
		if (!status.ok()) {
			// Mirrors the owner path's non-manifest-mismatch failure branch
			// (Finding 5.2), minus every prediction-specific step -- an
			// observer never predicts, so there is nothing to disable/clear
			// here. `apply_public_delta`'s own `decode_and_apply_delta_batch`
			// call already leaves `public_mirror` untouched on failure (its
			// validate-then-mutate contract); a fresh resync's own baseline
			// rebuilds the mirror from scratch regardless.
			comp->notify_replication_gap(int(status.code), int64_t(status.detail));
			emit_signal("replication_gap", status_dict(status));
			request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
		}
		// `public_state_updated` is emitted from inside `apply_public_delta`
		// on success -- nothing further to do here (mirrors
		// `_rpc_event_batch`'s own identical "already handled inside the
		// apply callback" shape).
	}
}

void GameplayAbilityNetworkBridge::_rpc_event_batch(const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::EVENT_BATCH, header, payload)) {
		return;
	}
	ga::proto::EventBatchHeader batch_header;
	std::vector<std::uint8_t> event_payload;
	if (!ga::proto::decode_event_batch(payload, batch_header, event_payload).ok()) {
		comp->notify_replication_gap(int(ga::StatusCode::DECODE_FAILED), 0);
		return;
	}
	correct_estimated_tick(batch_header.authoritative_tick);

	if (owner_view) {
		ensure_client_state();

		// Wave 3 (task 4.1): `event_payload` is now a canonical GRANULAR DELTA
		// (see this file's own "Wave 3" header comment), not a self-sufficient
		// full snapshot -- `apply_owner_delta` restores this bridge's OWN
		// `last_confirmed_snapshot` baseline onto `comp`, applies the delta on
		// top, and (on success) refreshes `last_confirmed_snapshot` to the
		// resulting confirmed state. This deliberately keeps Finding 2a's own
		// established contract: the ROUTINE per-batch path never routes through
		// `reconcile_snapshot()`'s replay (see `apply_owner_delta`'s own doc
		// comment, gameplay_ability_network_bridge.h, for why -- reconciling on
		// every batch a still-pending command outlives would re-announce
		// `CuePhase::PREDICT` once per batch instead of once, the EXACT
		// regression `tests/gameplay_abilities/slice/test_slice.gd`'s
		// `listen_server_and_prediction` scenario already covers). A predicted
		// effect is (as before Wave 3) re-established the next time a genuinely
		// infrequent reconciliation event runs -- an owner-path SNAPSHOT
		// (below), a REJECTED acknowledgement, or a detected sequence gap (both
		// via `reconcile_and_resend`, unchanged by this wave).
		ga::proto::ApplyEventBatchFn apply = [this, comp](const ga::proto::EventBatchHeader &, const std::vector<std::uint8_t> &p) -> ga::Status {
			return apply_owner_delta(comp, p);
		};
		const ga::Status status = client_stream->apply_batch(batch_header, event_payload, apply);
		if (!status.ok()) {
			comp->notify_replication_gap(int(status.code), int64_t(status.detail));
			emit_signal("replication_gap", status_dict(status));
			request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
			// Task 8.10: "drive reconcile(...) on rejection or divergence" -- a
			// sequence gap is exactly a detected divergence between what this
			// client predicted and what authority actually did. Restores AND
			// replays from `last_confirmed_snapshot` (refreshed by every
			// successful `apply_owner_delta` above), which is exactly the
			// "restore last_confirmed_snapshot if possible, else disable
			// prediction + request resync" baseline-lost recovery a failed
			// delta apply requires -- see `apply_owner_delta`'s own doc comment.
			reconcile_and_resend(batch_header.authoritative_tick);
		}
		// last_confirmed_snapshot is already refreshed inside apply_owner_delta
		// on success -- nothing further to do here.
	} else {
		// Wave 4 (task 4.2): the observer-side analogue of the owner branch
		// above, riding `public_client_stream`/`public_mirror` instead of
		// `client_stream`/`comp`'s own core component. An observer never
		// predicts, so there is no `reconcile_and_resend` counterpart on
		// failure here -- a detected gap only ever needs a fresh public
		// baseline (`request_resync`), never a replay of speculative local
		// commands that do not exist for this role.
		ensure_public_client_state();
		ga::proto::ApplyEventBatchFn apply = [this](const ga::proto::EventBatchHeader &p_header, const std::vector<std::uint8_t> &p) -> ga::Status {
			return apply_public_delta(p, int64_t(p_header.authoritative_tick));
		};
		const ga::Status status = public_client_stream->apply_batch(batch_header, event_payload, apply);
		if (!status.ok()) {
			comp->notify_replication_gap(int(status.code), int64_t(status.detail));
			emit_signal("replication_gap", status_dict(status));
			request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
		}
		// `public_state_updated` is emitted from inside `apply_public_delta`
		// on success -- nothing further to do here.
	}
}

// Change-Gated State Sends (task 4.4; Wave 4 task 3.3/4.2 extends this to
// observers): received in place of a state-bearing message while this
// peer's audience revision is unchanged server-side -- see
// gap_heartbeat.h's own doc comment. A heartbeat never carries state to
// apply -- it can only ever feed the tick estimator and OBSERVE a gap
// (never resolve one), so this never touches `client_stream`'s (or, for an
// observer, `public_client_stream`'s) confirmed sequence directly.
void GameplayAbilityNetworkBridge::_rpc_heartbeat(const PackedByteArray &p_bytes) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr) {
		return;
	}
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::HEARTBEAT, header, payload)) {
		return;
	}
	ga::proto::HeartbeatPayload heartbeat;
	if (!ga::proto::decode_heartbeat(payload, heartbeat).ok()) {
		return;
	}
	// "Feed the authoritative tick into correct_estimated_tick" (task 4.4)
	// -- the SAME one-line `ServerTickEstimator::observe` call every other
	// state-bearing message already makes; see `ga::ServerTickEstimator`'s
	// own doc comment on why a heartbeat needs no dedicated estimator API.
	correct_estimated_tick(heartbeat.authoritative_tick);

	// Gap detection: the carried head sequence is whichever stream serves
	// THIS peer's own audience -- the owner's `owner_stream` head via
	// `client_stream`, or (Wave 4) the observer's `public_stream` head via
	// `public_client_stream` -- see gap_heartbeat.h's own "exactly ONE
	// stream head is meaningful here" doc comment and `send_heartbeat`'s own
	// call sites (`send_owner_event_batch`/`send_public_state`) for which
	// head each audience's heartbeat actually carries. A head strictly
	// AHEAD of this client's own confirmed sequence means at least one
	// state-bearing send this client should have received was missed --
	// exactly the "existing resync request path" the task requires,
	// reusing `ClientEventStream::mark_needs_snapshot()`'s own quarantine
	// policy rather than inventing a second one. `INVALID_EVENT_SEQ` (an
	// owner heartbeat sent before the FIRST owner event batch ever appended
	// anything) is never treated as a gap -- see that sentinel's own
	// "legitimately not established yet" doc comment.
	if (owner_view) {
		if (client_stream != nullptr && heartbeat.stream_head_sequence != ga::INVALID_EVENT_SEQ &&
				heartbeat.stream_head_sequence.value > client_stream->confirmed_sequence().value) {
			client_stream->mark_needs_snapshot();
			const ga::Status gap_status = ga::make_status(ga::StatusCode::SEQUENCE_GAP, ga::DiagnosticId::SEQUENCE_OUT_OF_ORDER,
					heartbeat.stream_head_sequence.value);
			comp->notify_replication_gap(int(gap_status.code), int64_t(gap_status.detail));
			emit_signal("replication_gap", status_dict(gap_status));
			request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
			// Spec "Tick estimation survives suppression": prediction
			// eligibility must not degrade solely from idle suppression --
			// driving the SAME reconcile-and-resend recovery a detected
			// EVENT_BATCH gap already triggers keeps a genuinely MISSED-update
			// gap (as opposed to mere idle suppression, which never reaches
			// this branch at all) recovering exactly like one would.
			reconcile_and_resend(heartbeat.authoritative_tick);
		}
	} else {
		// Observer: identical gap detection against `public_client_stream`,
		// minus `reconcile_and_resend` -- an observer never predicts, so a
		// detected gap only ever needs the fresh public baseline
		// `request_resync` already triggers.
		if (public_client_stream != nullptr && heartbeat.stream_head_sequence != ga::INVALID_EVENT_SEQ &&
				heartbeat.stream_head_sequence.value > public_client_stream->confirmed_sequence().value) {
			public_client_stream->mark_needs_snapshot();
			const ga::Status gap_status = ga::make_status(ga::StatusCode::SEQUENCE_GAP, ga::DiagnosticId::SEQUENCE_OUT_OF_ORDER,
					heartbeat.stream_head_sequence.value);
			comp->notify_replication_gap(int(gap_status.code), int64_t(gap_status.detail));
			emit_signal("replication_gap", status_dict(gap_status));
			request_resync(int(ga::proto::ResyncReason::GAP_DETECTED));
		}
	}
}

// ---------------------------------------------------------------------------
// Cue forwarding
// ---------------------------------------------------------------------------

void GameplayAbilityNetworkBridge::on_effect_cue_triggered(Dictionary p_cue) {
	GameplayAbilityComponent *comp = resolve_component();
	if (comp == nullptr || comp->get_role() == GameplayAbilityComponent::ROLE_NETWORK_CLIENT) {
		return;
	}
	// Finding 7: `definition_identifier` here IS an effect identifier
	// (`effect_cue_dict`'s own field) -- checking it against
	// `hidden_abilities` (an ABILITY identifier list; see that property's own
	// doc comment) filtered nothing in normal use. `hidden_effect_identifiers`
	// is the list this cue's OWN definition is actually checked against: a
	// hidden effect's cue never leaves the server for ANY peer, owner
	// included.
	const String definition_identifier = p_cue.get("definition_identifier", String());
	if (!definition_identifier.is_empty() && hidden_effect_identifiers.has(definition_identifier)) {
		return; // hidden effect's cue never leaves the server.
	}

	// Finding 7: the "Owner and Observer Visibility" requirement's redaction
	// rule -- visibility filtering must never leak prediction details,
	// internal effect bookkeeping, or source context to an observer. Every
	// relevant peer used to receive the IDENTICAL owner-shaped wire event
	// regardless of `peer_is_owner()`. Two variants are built and encoded
	// ONCE here (never per-peer) and picked per relevant peer below instead.
	PresentationEventWire owner_wire;
	owner_wire.component = ga::EntityId{ std::uint64_t(comp->get_entity_id()) };
	owner_wire.id = ga::GameplayEventId{ std::uint64_t(int64_t(p_cue.get("id", 0))) };
	owner_wire.target = ga::EntityId{ std::uint64_t(int64_t(p_cue.get("target", 0))) };
	owner_wire.definition = ga::DefinitionId(int64_t(p_cue.get("definition", 0)));
	owner_wire.handle = std::uint64_t(int64_t(p_cue.get("handle", 0)));
	owner_wire.occurrence = std::uint64_t(int64_t(p_cue.get("occurrence", 0)));
	owner_wire.prediction_key = ga::PredictionKey{ std::uint64_t(int64_t(p_cue.get("prediction_key", 0))) };
	owner_wire.phase = std::uint8_t(int(p_cue.get("phase", 0)));
	owner_wire.source = ga::EntityId{ std::uint64_t(int64_t(p_cue.get("source", 0))) };
	owner_wire.tick = ga::Tick(int64_t(p_cue.get("tick", 0)));
	const PackedStringArray cue_identifiers = p_cue.get("cue_identifiers", PackedStringArray());
	for (int i = 0; i < cue_identifiers.size() && owner_wire.cue_identifiers.size() < MAX_PRESENTATION_CUE_IDENTIFIERS; ++i) {
		owner_wire.cue_identifiers.push_back(to_std(cue_identifiers[i]));
	}

	// The redaction rule itself: `prediction_key` (a prediction detail),
	// `handle` (internal effect bookkeeping -- an opaque server-side id an
	// observer has no legitimate use for), and `source` (source context) are
	// exactly the categories the spec's requirement names as never part of
	// any observer-facing feed. `component`/`id`/`target`/`definition`/
	// `occurrence`/`phase`/`tick`/`cue_identifiers` are left unchanged --
	// everything an observer needs to play a deduplicated cue on the right
	// entity, and nothing more.
	PresentationEventWire observer_wire = owner_wire;
	observer_wire.prediction_key = ga::INVALID_PREDICTION_KEY;
	observer_wire.handle = 0;
	observer_wire.source = ga::INVALID_ENTITY_ID;

	std::vector<std::uint8_t> owner_payload;
	std::vector<std::uint8_t> observer_payload;
	if (!encode_presentation_event(owner_wire, owner_payload).ok() ||
			!encode_presentation_event(observer_wire, observer_payload).ok()) {
		return;
	}
	std::vector<std::uint8_t> owner_framed;
	std::vector<std::uint8_t> observer_framed;
	if (!ga::proto::encode_message(ga::proto::MessageType::PRESENTATION_EVENT, ga::proto::SessionId(local_session_id), owner_payload,
				 ga::proto::message_byte_limit(ga::proto::MessageType::PRESENTATION_EVENT), owner_framed)
					 .ok() ||
			!ga::proto::encode_message(ga::proto::MessageType::PRESENTATION_EVENT, ga::proto::SessionId(local_session_id), observer_payload,
					ga::proto::message_byte_limit(ga::proto::MessageType::PRESENTATION_EVENT), observer_framed)
					.ok()) {
		return;
	}
	const PackedByteArray owner_packed = to_packed(owner_framed);
	const PackedByteArray observer_packed = to_packed(observer_framed);

	const PackedInt32Array peers = current_relevant_peers();
	for (int i = 0; i < peers.size(); ++i) {
		const int32_t peer = peers[i];
		if (peer == 0) {
			continue;
		}
		// Finding 7 item 3: consistency with `push_full_state`'s own
		// handshake gate (Finding 3b) -- an incompatible or not-yet-checked
		// peer must never receive a cue either.
		if (handshake_ok_peers.find(peer) == handshake_ok_peers.end()) {
			continue;
		}
		rpc_id(peer, "_rpc_presentation_event", peer_is_owner(peer) ? owner_packed : observer_packed);
	}
}

void GameplayAbilityNetworkBridge::_rpc_presentation_event(const PackedByteArray &p_bytes) {
	ga::proto::MessageHeader header;
	std::vector<std::uint8_t> payload;
	if (!decode_framed(p_bytes, ga::proto::MessageType::PRESENTATION_EVENT, header, payload)) {
		return;
	}
	PresentationEventWire wire;
	if (!decode_presentation_event(payload, wire).ok()) {
		return;
	}
	correct_estimated_tick(wire.tick);

	Dictionary d;
	d["component"] = int64_t(wire.component.value);
	d["id"] = int64_t(wire.id.value);
	d["target"] = int64_t(wire.target.value);
	d["definition"] = int64_t(wire.definition);
	d["handle"] = int64_t(wire.handle);
	d["occurrence"] = int64_t(wire.occurrence);
	d["prediction_key"] = int64_t(wire.prediction_key.value);
	d["phase"] = int(wire.phase);
	d["source"] = int64_t(wire.source.value);
	d["tick"] = int64_t(wire.tick);
	PackedStringArray cue_identifiers;
	for (const std::string &identifier : wire.cue_identifiers) {
		cue_identifiers.push_back(String(identifier.c_str()));
	}
	d["cue_identifiers"] = cue_identifiers;
	emit_signal("cue_received", d);
}

// ---------------------------------------------------------------------------
// Tick estimation (task 7.12, refactored by 8.10 onto ga::ServerTickEstimator)
// ---------------------------------------------------------------------------

void GameplayAbilityNetworkBridge::correct_estimated_tick(ga::Tick p_observed) {
	// `ga::ServerTickEstimator` already implements the identical snap/smooth
	// rule this file used to duplicate inline (see its own doc comment in
	// ga_reconciliation.h) -- one implementation now, not two.
	tick_estimator.observe(local_tick_counter, p_observed);
}

void GameplayAbilityNetworkBridge::_process(double p_delta) {
	const std::uint32_t rate = effective_tick_rate();
	if (rate == 0) {
		return;
	}
	tick_accumulator += p_delta * double(rate);
	while (tick_accumulator >= 1.0) {
		local_tick_counter += 1;
		tick_accumulator -= 1.0;
		// Finding 2e: at most once per local tick increment (never per
		// frame) -- a cheap no-op whenever nothing is pending.
		sweep_expired_predictions();
	}
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

void GameplayAbilityNetworkBridge::_ready() {
	Dictionary any_peer_reliable;
	any_peer_reliable["rpc_mode"] = MultiplayerAPI::RPC_MODE_ANY_PEER;
	any_peer_reliable["call_local"] = false;
	any_peer_reliable["transfer_mode"] = MultiplayerPeer::TRANSFER_MODE_RELIABLE;
	any_peer_reliable["channel"] = 0;

	Dictionary authority_reliable;
	authority_reliable["rpc_mode"] = MultiplayerAPI::RPC_MODE_AUTHORITY;
	authority_reliable["call_local"] = false;
	authority_reliable["transfer_mode"] = MultiplayerPeer::TRANSFER_MODE_RELIABLE;
	authority_reliable["channel"] = 0;

	// Client -> server (any peer may call; ownership/session/gate checks
	// happen inside the handler, never via RPC mode alone -- "Node
	// multiplayer authority alone is not accepted as permission").
	rpc_config("_rpc_handshake_request", any_peer_reliable);
	rpc_config("_rpc_activation_command", any_peer_reliable);
	rpc_config("_rpc_task_input_command", any_peer_reliable);
	rpc_config("_rpc_target_command", any_peer_reliable);
	rpc_config("_rpc_resync_request", any_peer_reliable);
	// Server -> client (defense-in-depth: only this node's designated
	// multiplayer authority may invoke these on a remote peer).
	rpc_config("_rpc_handshake_response", authority_reliable);
	rpc_config("_rpc_command_result", authority_reliable);
	rpc_config("_rpc_event_batch", authority_reliable);
	rpc_config("_rpc_snapshot", authority_reliable);
	rpc_config("_rpc_presentation_event", authority_reliable);
	rpc_config("_rpc_target_outcome", authority_reliable);
	rpc_config("_rpc_target_state", authority_reliable);
	rpc_config("_rpc_heartbeat", authority_reliable);

	// Task 7.17: was inline here, unconditionally and only-ever-once,
	// resolving `component_path` at exactly this moment -- if a caller had
	// not yet called `set_component_path()` (the natural `add_child(bridge);
	// bridge.set_component_path(...)` order), this silently and permanently
	// skipped cue forwarding, authority assignment, and the client
	// handshake. `try_wire_component()` is the SAME logic, now idempotent
	// and also invoked from `set_component_path()` (and retried lazily by
	// on-demand entry points), so whichever of "_ready() then
	// set_component_path()" or "set_component_path() then _ready()" happens
	// first, wiring still completes.
	try_wire_component();
}

void GameplayAbilityNetworkBridge::_notification(int p_what) {
	if (p_what == NOTIFICATION_PREDELETE || p_what == NOTIFICATION_EXIT_TREE) {
		// The SceneTree branch may already have been removed by the transport
		// harness, so this must use the retained emitter Ref rather than
		// `get_multiplayer()`. Besides preventing stale connections, the
		// connected callbacks themselves use ObjectID-backed Callables (see
		// `wire_multiplayer_signals()`), making teardown safe even when this
		// notification runs from inside the emitter's own disconnect signal.
		unwire_multiplayer_signals();

		// Finding 2d: this bridge (or its served component -- both leave the
		// tree together in every documented layout) is going away. A
		// predicting component must get `on_despawned()` so its still-
		// pending commands each get exactly one required CANCEL phase
		// instead of silently vanishing with no presentation event at all
		// (`on_despawned()` also permanently disables prediction -- "late
		// acknowledgements cannot recreate the component"). Resolved via
		// `resolve_component()` rather than the cached `component`/
		// `wired_component` pointers so this still works even if wiring
		// never completed. Guarded on `is_inside_tree()`: a relative
		// `NodePath` only resolves while actually inside a tree, and
		// `NOTIFICATION_PREDELETE` alone (a bridge freed without ever being
		// added to one) would otherwise attempt a `get_node()` lookup that
		// can never succeed. `NOTIFICATION_EXIT_TREE` itself still fires
		// WHILE this node is inside the tree (a node's last chance to
		// interact with it), so the real despawn case this finding targets
		// is unaffected by the guard.
		if (is_inside_tree()) {
			if (GameplayAbilityComponent *comp = resolve_component()) {
				if (ga::PredictingComponent *predicting = comp->predicting_component()) {
					predicting->on_despawned();
				}
			}
		}
		// This bridge owns no gameplay state of its own (no ObjectID/RID ever
		// crosses into core/protocol -- see file comment); it only forgets
		// its own transport-side bookkeeping so a freed bridge never leaves
		// a dangling per-peer entry behind.
		handshake_ok_peers.clear();
		synced_peers.clear();
		peer_sessions.clear();
	}
}

// ---------------------------------------------------------------------------
// _bind_methods
// ---------------------------------------------------------------------------

void GameplayAbilityNetworkBridge::_bind_methods() {
	// Internal signal endpoints use ordinary object/method Callables instead
	// of raw-pointer custom callables; binding is what lets Godot resolve
	// them safely by this Object's instance id.
	ClassDB::bind_method(D_METHOD("_on_server_disconnected"),
			&GameplayAbilityNetworkBridge::on_server_disconnected);
	ClassDB::bind_method(D_METHOD("_on_peer_disconnected", "peer_id"),
			&GameplayAbilityNetworkBridge::on_peer_disconnected);
	ClassDB::bind_method(D_METHOD("_on_connected_to_server"),
			&GameplayAbilityNetworkBridge::on_connected_to_server);
	ClassDB::bind_method(D_METHOD("_on_peer_connected", "peer_id"),
			&GameplayAbilityNetworkBridge::on_peer_connected);

	ClassDB::bind_method(D_METHOD("set_component_path", "path"), &GameplayAbilityNetworkBridge::set_component_path);
	ClassDB::bind_method(D_METHOD("get_component_path"), &GameplayAbilityNetworkBridge::get_component_path);
	ClassDB::bind_method(D_METHOD("set_world_coordinator_path", "path"),
			&GameplayAbilityNetworkBridge::set_world_coordinator_path);
	ClassDB::bind_method(D_METHOD("get_world_coordinator_path"),
			&GameplayAbilityNetworkBridge::get_world_coordinator_path);
	ClassDB::bind_method(D_METHOD("set_server_peer_id", "peer_id"), &GameplayAbilityNetworkBridge::set_server_peer_id);
	ClassDB::bind_method(D_METHOD("get_server_peer_id"), &GameplayAbilityNetworkBridge::get_server_peer_id);
	ClassDB::bind_method(D_METHOD("set_owner_view", "owner_view"), &GameplayAbilityNetworkBridge::set_owner_view);
	ClassDB::bind_method(D_METHOD("get_owner_view"), &GameplayAbilityNetworkBridge::get_owner_view);
	ClassDB::bind_method(D_METHOD("set_tick_rate", "tick_rate"), &GameplayAbilityNetworkBridge::set_tick_rate);
	ClassDB::bind_method(D_METHOD("get_tick_rate"), &GameplayAbilityNetworkBridge::get_tick_rate);

	ClassDB::bind_method(D_METHOD("set_hidden_attribute_identifiers", "ids"), &GameplayAbilityNetworkBridge::set_hidden_attribute_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_attribute_identifiers"), &GameplayAbilityNetworkBridge::get_hidden_attribute_identifiers);
	ClassDB::bind_method(D_METHOD("set_hidden_tag_identifiers", "ids"), &GameplayAbilityNetworkBridge::set_hidden_tag_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_tag_identifiers"), &GameplayAbilityNetworkBridge::get_hidden_tag_identifiers);
	ClassDB::bind_method(D_METHOD("set_hidden_ability_identifiers", "ids"), &GameplayAbilityNetworkBridge::set_hidden_ability_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_ability_identifiers"), &GameplayAbilityNetworkBridge::get_hidden_ability_identifiers);
	ClassDB::bind_method(D_METHOD("set_hidden_effect_identifiers", "ids"), &GameplayAbilityNetworkBridge::set_hidden_effect_identifiers);
	ClassDB::bind_method(D_METHOD("get_hidden_effect_identifiers"), &GameplayAbilityNetworkBridge::get_hidden_effect_identifiers);
	ClassDB::bind_method(D_METHOD("set_target_authorization_callback", "callback"), &GameplayAbilityNetworkBridge::set_target_authorization_callback);
	ClassDB::bind_method(D_METHOD("get_target_authorization_callback"), &GameplayAbilityNetworkBridge::get_target_authorization_callback);
	ClassDB::bind_method(D_METHOD("set_require_target_authorization", "require"), &GameplayAbilityNetworkBridge::set_require_target_authorization);
	ClassDB::bind_method(D_METHOD("get_require_target_authorization"), &GameplayAbilityNetworkBridge::get_require_target_authorization);

	ClassDB::bind_method(D_METHOD("is_multiplayer_active"), &GameplayAbilityNetworkBridge::is_multiplayer_active);

	ClassDB::bind_method(D_METHOD("begin_session", "peer", "session"), &GameplayAbilityNetworkBridge::begin_session);
	ClassDB::bind_method(D_METHOD("end_session", "peer"), &GameplayAbilityNetworkBridge::end_session);
	ClassDB::bind_method(D_METHOD("authorize_control", "peer", "entity"), &GameplayAbilityNetworkBridge::authorize_control);
	ClassDB::bind_method(D_METHOD("revoke_control", "peer", "entity"), &GameplayAbilityNetworkBridge::revoke_control);
	ClassDB::bind_method(D_METHOD("authorize_server_entity", "entity"), &GameplayAbilityNetworkBridge::authorize_server_entity);
	ClassDB::bind_method(D_METHOD("drop_peer", "peer"), &GameplayAbilityNetworkBridge::drop_peer);

	ClassDB::bind_method(D_METHOD("request_activation_networked", "request", "client_tick"), &GameplayAbilityNetworkBridge::request_activation_networked);
	ClassDB::bind_method(D_METHOD("request_task_input_networked",
								 "task", "phase", "command_sequence",
								 "client_tick", "prediction_key"),
			&GameplayAbilityNetworkBridge::request_task_input_networked,
			DEFVAL(0));
	ClassDB::bind_method(D_METHOD("request_target_command_networked",
								 "session", "kind", "intent",
								 "command_sequence",
								 "session_sequence", "client_tick",
								 "prediction_key"),
			&GameplayAbilityNetworkBridge::request_target_command_networked,
			DEFVAL(0));
	ClassDB::bind_method(D_METHOD("request_resync", "reason"), &GameplayAbilityNetworkBridge::request_resync);
	ClassDB::bind_method(D_METHOD("push_full_state", "tick"), &GameplayAbilityNetworkBridge::push_full_state);
	ClassDB::bind_method(D_METHOD("debug_peek_owner_event_batch_frame", "since_sequence"), &GameplayAbilityNetworkBridge::debug_peek_owner_event_batch_frame);
	ClassDB::bind_method(D_METHOD("debug_peek_last_heartbeat_frame", "peer"), &GameplayAbilityNetworkBridge::debug_peek_last_heartbeat_frame);
	ClassDB::bind_method(D_METHOD("debug_heartbeat_send_count", "peer"), &GameplayAbilityNetworkBridge::debug_heartbeat_send_count);
	ClassDB::bind_method(D_METHOD("debug_owner_stream_head_sequence"), &GameplayAbilityNetworkBridge::debug_owner_stream_head_sequence);
	ClassDB::bind_method(D_METHOD("set_relevant_peers", "peers"), &GameplayAbilityNetworkBridge::set_relevant_peers);
	ClassDB::bind_method(D_METHOD("set_no_relevant_peers"), &GameplayAbilityNetworkBridge::set_no_relevant_peers);
	ClassDB::bind_method(D_METHOD("get_no_relevant_peers"), &GameplayAbilityNetworkBridge::get_no_relevant_peers);

	ClassDB::bind_method(D_METHOD("get_estimated_tick"), &GameplayAbilityNetworkBridge::get_estimated_tick);

	ClassDB::bind_method(D_METHOD("_rpc_handshake_request", "bytes"), &GameplayAbilityNetworkBridge::_rpc_handshake_request);
	ClassDB::bind_method(D_METHOD("_rpc_handshake_response", "bytes"), &GameplayAbilityNetworkBridge::_rpc_handshake_response);
	ClassDB::bind_method(D_METHOD("_rpc_activation_command", "bytes"), &GameplayAbilityNetworkBridge::_rpc_activation_command);
	ClassDB::bind_method(D_METHOD("_rpc_command_result", "bytes"), &GameplayAbilityNetworkBridge::_rpc_command_result);
	ClassDB::bind_method(D_METHOD("_rpc_event_batch", "bytes"), &GameplayAbilityNetworkBridge::_rpc_event_batch);
	ClassDB::bind_method(D_METHOD("_rpc_snapshot", "bytes"), &GameplayAbilityNetworkBridge::_rpc_snapshot);
	ClassDB::bind_method(D_METHOD("_rpc_resync_request", "bytes"), &GameplayAbilityNetworkBridge::_rpc_resync_request);
	ClassDB::bind_method(D_METHOD("_rpc_presentation_event", "bytes"), &GameplayAbilityNetworkBridge::_rpc_presentation_event);
	ClassDB::bind_method(D_METHOD("_rpc_task_input_command", "bytes"),
			&GameplayAbilityNetworkBridge::_rpc_task_input_command);
	ClassDB::bind_method(D_METHOD("_rpc_target_command", "bytes"),
			&GameplayAbilityNetworkBridge::_rpc_target_command);
	ClassDB::bind_method(D_METHOD("_rpc_target_outcome", "bytes"),
			&GameplayAbilityNetworkBridge::_rpc_target_outcome);
	ClassDB::bind_method(D_METHOD("_rpc_target_state", "bytes"),
			&GameplayAbilityNetworkBridge::_rpc_target_state);
	ClassDB::bind_method(D_METHOD("_rpc_heartbeat", "bytes"),
			&GameplayAbilityNetworkBridge::_rpc_heartbeat);

	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "component_path"), "set_component_path", "get_component_path");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH,
						 "world_coordinator_path"),
			"set_world_coordinator_path",
			"get_world_coordinator_path");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "server_peer_id"), "set_server_peer_id", "get_server_peer_id");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "owner_view"), "set_owner_view", "get_owner_view");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tick_rate"), "set_tick_rate", "get_tick_rate");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_attribute_identifiers"),
			"set_hidden_attribute_identifiers", "get_hidden_attribute_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_tag_identifiers"),
			"set_hidden_tag_identifiers", "get_hidden_tag_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_ability_identifiers"),
			"set_hidden_ability_identifiers", "get_hidden_ability_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_STRING_ARRAY, "hidden_effect_identifiers"),
			"set_hidden_effect_identifiers", "get_hidden_effect_identifiers");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "require_target_authorization"),
			"set_require_target_authorization", "get_require_target_authorization");

	ADD_SIGNAL(MethodInfo("handshake_completed", PropertyInfo(Variant::DICTIONARY, "result")));
	ADD_SIGNAL(MethodInfo("command_acknowledged", PropertyInfo(Variant::DICTIONARY, "result")));
	ADD_SIGNAL(MethodInfo("command_rejected", PropertyInfo(Variant::DICTIONARY, "result")));
	ADD_SIGNAL(MethodInfo("state_synced", PropertyInfo(Variant::DICTIONARY, "info")));
	ADD_SIGNAL(MethodInfo("replication_gap", PropertyInfo(Variant::DICTIONARY, "info")));
	ADD_SIGNAL(MethodInfo("public_state_updated", PropertyInfo(Variant::DICTIONARY, "state")));
	ADD_SIGNAL(MethodInfo("cue_received", PropertyInfo(Variant::DICTIONARY, "cue")));
	ADD_SIGNAL(MethodInfo("network_diagnostic", PropertyInfo(Variant::DICTIONARY, "info")));
	ADD_SIGNAL(MethodInfo("target_outcome_received",
			PropertyInfo(Variant::DICTIONARY, "result")));
	ADD_SIGNAL(MethodInfo("target_state_synced",
			PropertyInfo(Variant::DICTIONARY, "info")));
	// Finding 4: see `request_activation_networked`'s own header doc comment
	// (immediately above its declaration, gameplay_ability_network_bridge.h)
	// for the full payload shape and routing contract -- emitted from
	// `_rpc_activation_command` whenever a successful authoritative
	// activation's result carries a non-empty `pending_remote_effects` list
	// (task 6.13) and at least one listener is connected.
	ADD_SIGNAL(MethodInfo("remote_effects_pending", PropertyInfo(Variant::DICTIONARY, "payload")));

	BIND_ENUM_CONSTANT(PREDICTION_MODE_NOT_PREDICTED_NO_BASELINE);
	BIND_ENUM_CONSTANT(PREDICTION_MODE_NOT_PREDICTED_UNKNOWN_ABILITY);
	BIND_ENUM_CONSTANT(PREDICTION_MODE_NOT_PREDICTED_JOURNAL_FULL);
	BIND_ENUM_CONSTANT(PREDICTION_MODE_PRESENTATION_ONLY);
	BIND_ENUM_CONSTANT(PREDICTION_MODE_PREDICTED);
}

} // namespace godot
