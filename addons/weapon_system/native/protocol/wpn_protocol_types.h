#ifndef WEAPON_SYSTEM_PROTOCOL_TYPES_H
#define WEAPON_SYSTEM_PROTOCOL_TYPES_H

#include "core/wpn_limits.h"
#include "core/wpn_runtime.h"
#include "core/wpn_status.h"
#include "core/wpn_version.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Bounded, versioned, transport-neutral DTOs (tasks.md 7.1; weapon-protocol
// spec, "Versioned Canonical Weapon Protocol"). Every DTO here is a plain
// value type: no byte parsing happens in this file (that is
// protocol/wpn_protocol_codec.h/.cpp's job, matching core/wpn_runtime.h's
// own decode-is-a-later-slice discipline). None of these types create or
// require a MultiplayerPeer, RPC topology, or transport -- a game
// encodes/decodes them over whatever transport it owns and submits the
// decoded canonical intent to the same authority gate an offline game uses
// (see protocol/wpn_command_gate.h for that gate).
//
// Where a DTO's payload is already a core value type (WeaponSnapshot,
// CommittedShot, CompatibilityManifest), the DTO wraps that type verbatim
// instead of re-declaring an equivalent shape -- one canonical definition per
// concept, per addons/inventory_system/native/protocol/inv_protocol_types.h's
// identical reuse discipline.
//
// *** Command DTOs never carry a trusted authority tick. *** design.md
// "Protocol and networking": "Command DTOs carry untrusted intent identity
// and sequence but never a trusted authority tick; the bridge creates the
// core authority envelope." FireIntent/BeginReloadIntent/CancelReloadIntent
// below are therefore intentionally NOT core::FireCommand/
// BeginReloadCommand/CancelReloadCommand verbatim (those core types DO carry
// a `tick`, because the core trusts whatever tick its caller supplies -- see
// core/wpn_runtime.h). A later WeaponNetworkBridge (tasks.md 7.5, out of this
// slice's scope) is the one place that turns a gate-admitted *Intent plus a
// server-side trusted tick into the core command the runtime accepts.
//
// *** tasks.md 7.8/7.9 (PROTOCOL_VERSION 1 -> 2). *** core/wpn_runtime.h grew
// recoil anchor state, the canonical flat attachment loadout, exact
// loaded/consumed ballistic-profile identity, and an authority-scope/epoch/
// tick-floor/sequence-baseline/tick-health envelope on WeaponSnapshot (tasks.md
// 4.10-4.14), plus a canonical ConsequenceIdentity on CommittedShot and a
// WeaponTombstone type. Every DTO below still wraps the CURRENT
// core::WeaponSnapshot/core::CommittedShot/core::WeaponTombstone shape
// verbatim rather than re-declaring a wider one -- protocol/wpn_protocol_codec.cpp
// is where those extra core fields are now actually put on the wire (a
// core-struct change plus this PROTOCOL_VERSION bump, never a redesign of
// this file's envelope shapes). `WeaponLifecycleState` below is the one
// protocol-only addition with no direct core counterpart: it lets
// `WeaponDelta`/`WeaponSnapshotBatch` distinguish an ordinary live successor
// snapshot from a terminal `core::WeaponTombstone` successor, since a torn-down
// instance has no live `core::WeaponSnapshot` to send at all (weapon-protocol
// spec, "Versioned Canonical Weapon Protocol": "lifecycle/tombstone state").
namespace wpn::protocol {

// Discriminates whether a convergence payload names a live instance
// (`WeaponSnapshot`) or a terminal one (`WeaponTombstone`). Starts at 1 (not
// 0) so a zero-initialized/never-set byte on the wire is distinguishable from
// a deliberately chosen state, matching `TransitionKind` below.
enum class WeaponLifecycleState : std::uint8_t {
	ACTIVE = 1,
	TOMBSTONED = 2,
};

// --- Content-compatibility handshake (weapon-protocol spec, "Unknown
// required version is received") --------------------------------------

// One peer's compatibility declaration. Wraps core::CompatibilityManifest
// verbatim: that type already carries every axis the spec's "Versioned
// Canonical Weapon Protocol" requirement names -- semantic (api_major/minor/
// patch), API, protocol, and resource-schema versions, a feature bitmask,
// and a content (catalog) fingerprint -- so this envelope adds only the
// protocol identity a handshake message needs on the wire. See
// protocol/wpn_protocol_compat.h for how one is derived
// (make_compatibility_handshake()) and compared (check_handshake_
// compatibility(), which delegates to core::check_compatibility()).
struct CompatibilityHandshake {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	CompatibilityManifest manifest;
};

// --- Untrusted client command intents (weapon-protocol spec, "Authoritative
// Command Admission": "Command DTOs carry untrusted intent identity and
// client sequence but never a trusted authority tick") -----------------

struct FireIntent {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string command_id; // untrusted idempotency identity; bounded by MAX_IDENTIFIER_BYTES.
	std::uint64_t sequence = 0; // untrusted per-instance monotonic sequence claim.
	std::string instance_id; // claimed target weapon instance; admission binds this to the sender.
	std::uint64_t expected_revision = 0;
	FixedVec2 claimed_origin;
	FixedVec2 claimed_aim;
	std::uint64_t spread_seed = 0;
};

struct BeginReloadIntent {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::string reservation_id;
	std::uint32_t reserved_rounds = 0;
};

struct CancelReloadIntent {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
};

// Untrusted client form of core::ConfigureAttachmentsCommand (tasks.md 7.8;
// weapon-runtime spec, "Atomic Flat Attachment Loadout"). Like every other
// *Intent above, this NEVER carries a trusted authority tick -- the bridge
// (tasks.md 7.5) supplies that when it turns an admitted intent into the core
// command. `desired_loadout` is the complete wholesale-replacement loadout
// (not a delta against the previous one), bounded by
// MAX_ATTACHMENT_SLOTS_PER_WEAPON exactly like
// core::WeaponSnapshot::attachment_loadout.
struct ConfigureAttachmentsIntent {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string command_id;
	std::uint64_t sequence = 0;
	std::string instance_id;
	std::uint64_t expected_revision = 0;
	std::vector<AttachmentLoadoutEntry> desired_loadout; // bounded by MAX_ATTACHMENT_SLOTS_PER_WEAPON.
};

// --- Structured rejection (weapon-protocol spec: rejections carry "code +
// current revision") ----------------------------------------------------

// Reports why one command_id/instance_id pair was rejected, including the
// instance's current revision at rejection time so a client can decide
// whether its `expected_revision` claim is merely stale (retry against
// current_revision) or something else is wrong. Wraps core::Rejection and
// core::Status verbatim rather than re-declaring an equivalent code space.
struct CommandRejection {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string command_id;
	std::string instance_id;
	Rejection rejection = Rejection::NONE;
	Status status;
	std::uint64_t current_revision = 0;
};

// --- Mechanical transition events (design.md "Revision, tick, and
// idempotency model": "one predecessor/successor transition") ----------

enum class TransitionKind : std::uint8_t {
	FIRE = 1,
	RELOAD_BEGIN = 2,
	RELOAD_CANCEL = 3,
	RELOAD_COMPLETE = 4,
	TEARDOWN = 5,
	// tasks.md 7.8: an accepted core::WeaponRuntime::configure_attachments()
	// mutation (weapon-runtime spec, "Atomic Flat Attachment Loadout") is an
	// accepted canonical instance mutation like any other and therefore also
	// "emits one predecessor/successor transition" per design.md's revision
	// matrix. TransitionKind is protocol-only (no core counterpart), so
	// adding this value is additive here without touching core.
	CONFIGURE_ATTACHMENTS = 6,
};

// One accepted canonical instance mutation, named by its exact predecessor
// and successor revision (design.md: "Every accepted canonical instance
// mutation advances that instance revision exactly once and emits one
// predecessor/successor transition"). `shot` is present only for
// TransitionKind::FIRE and wraps the accepted core::CommittedShot verbatim,
// carrying its stable consequence identity. `tombstone` is present only for
// TransitionKind::TEARDOWN and wraps the accepted core::WeaponTombstone
// verbatim (tasks.md 7.9: "lifecycle/tombstone state"). Idle authority-tick
// advancement that commits no due reload never produces one of these
// (weapon-protocol spec, "Snapshot and Delta Convergence": "idle authority
// ticks SHALL not create weapon-state deltas").
struct WeaponTransitionEvent {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::string instance_id;
	TransitionKind kind = TransitionKind::FIRE;
	std::uint64_t predecessor_revision = 0;
	std::uint64_t successor_revision = 0;
	std::uint32_t loaded_rounds = 0;
	WeaponPhase phase = WeaponPhase::READY;
	std::optional<CommittedShot> shot;
	std::optional<WeaponTombstone> tombstone;
};

// --- Committed-shot result (weapon-protocol spec: "stable shot/consequence
// identity") -------------------------------------------------------------

// Wraps core::CommittedShot (already a complete bounded value: consequence
// id, instance/weapon/shot-profile identity, tick, origin, direction,
// damage/range/noise) plus protocol identity, exactly mirroring
// inv_protocol_types.h's ResultEnvelope/DeltaBatch precedent of adding only
// an envelope around an already-canonical core type.
struct ShotResultEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	CommittedShot shot;
};

// --- Complete canonical snapshot (weapon-protocol spec: "Snapshot restores
// recoil and ammunition profile" scenario -- this envelope restores every
// field core::WeaponSnapshot carries: revision, loaded rounds and optional
// loaded ballistic-profile identity, phase, active reload record (including
// its reserved ballistic-profile identity), authority scope/epoch/tick-floor/
// tick-health, recoil anchor offsets and anchor tick, the canonical flat
// attachment loadout, and the admitted command-sequence high-watermark used
// as a delta-convergence baseline) -----------------------------------------

struct WeaponSnapshotEnvelope {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	WeaponSnapshot snapshot;
};

// A late-join / full-session-readiness batch: every instance a session is
// currently authorized to observe, in one bounded message (weapon-protocol
// spec, "Client joins late": "it receives a complete current snapshot before
// applying later deltas"). Reuses core::WeaponSnapshot verbatim per entry --
// no separate per-entry envelope, since protocol_version already applies to
// the whole batch. `tombstones` additively carries every terminal instance
// this session should also know about (tasks.md 7.9: "lifecycle/tombstone
// state") -- a late joiner or a reconnecting client that only ever saw
// `snapshots` could otherwise mistake "never existed" for "destroyed", or
// keep requesting a resync for an instance that is gone for good. Reuses
// core::WeaponTombstone verbatim per entry, mirroring
// core::WeaponRuntime's own bounded `instances`/`tombstones` split.
struct WeaponSnapshotBatch {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::vector<WeaponSnapshot> snapshots; // bounded by MAX_SNAPSHOTS_PER_BATCH.
	std::vector<WeaponTombstone> tombstones; // bounded by MAX_TOMBSTONES.
};

// --- Ordered revisioned delta (weapon-protocol spec, "Snapshot and Delta
// Convergence": "Authority SHALL provide ... ordered revisioned deltas with
// baseline acknowledgement. ... Every accepted mutation SHALL name exactly
// one predecessor and successor revision") ------------------------------

// WeaponSnapshot has no per-field op vocabulary the way InventoryDelta's
// item/container ops do (see inv_deltas.h) -- a weapon instance transition
// already produces a brand-new WeaponSnapshot from
// WeaponRuntime::find_instance()/snapshots(), so a delta simply carries that
// complete successor state alongside the predecessor revision a replica must
// already be at to apply it (protocol/wpn_replica.h's WeaponReplica::
// apply_delta() rejects a baseline mismatch rather than guessing). `shot` is
// populated when this delta was produced by an accepted fire, letting a
// replica correlate the state change with its stable consequence identity
// without a second round trip.
//
// `lifecycle`/`tombstone` (tasks.md 7.9) handle the one case a live
// `snapshot` cannot represent: an accepted teardown. Once
// core::WeaponRuntime::remove_instance() runs, the instance has no live
// WeaponSnapshot left at all -- only a core::WeaponTombstone. When
// `lifecycle == TOMBSTONED`, `tombstone` carries that terminal successor
// state instead (`tombstone->revision == successor_revision`) and `snapshot`
// is not meaningful (left default-constructed by convention, its
// `instance_id` MAY still be set to the affected instance for readability,
// but protocol/wpn_replica.h's WeaponReplica::apply_delta() always resolves
// the affected instance from `tombstone->instance_id` in this case, never
// from `snapshot.instance_id`).
struct WeaponDelta {
	std::uint64_t predecessor_revision = 0;
	std::uint64_t successor_revision = 0;
	WeaponLifecycleState lifecycle = WeaponLifecycleState::ACTIVE;
	WeaponSnapshot snapshot; // meaningful iff lifecycle == ACTIVE: snapshot.instance_id names the affected instance; snapshot.revision == successor_revision.
	std::optional<WeaponTombstone> tombstone; // meaningful iff lifecycle == TOMBSTONED.
	std::optional<CommittedShot> shot;
};

struct WeaponDeltaBatch {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::uint64_t authority_tick = 0;
	std::vector<WeaponDelta> deltas; // bounded by MAX_DELTAS_PER_BATCH; ordered as authority produced them.
};

// --- Baseline acknowledgement (weapon-protocol spec: "baseline
// acknowledgement tracking") ---------------------------------------------

// A client's confirmation that it has applied a given instance up to
// `acknowledged_revision`, letting authority bound how much delta history it
// must retain per (peer, instance) -- see protocol/wpn_command_gate.h's
// notion of a per-peer baseline and protocol/wpn_replica.h's
// WeaponReplicationAuthority.
struct DeltaAcknowledgement {
	std::string instance_id;
	std::uint64_t acknowledged_revision = 0;
};

struct AcknowledgementBatch {
	std::uint16_t protocol_version = PROTOCOL_VERSION;
	std::vector<DeltaAcknowledgement> acknowledgements; // bounded by MAX_ACKNOWLEDGEMENTS_PER_BATCH.
};

// --- Resynchronization request (weapon-protocol spec: "Delta is lost" ->
// "it requests or awaits a full snapshot") --------------------------------

// A replica's request for a fresh authoritative snapshot of one instance,
// naming the last revision it successfully applied (or 0 if it has none
// yet). No protocol_version field, matching inv_protocol_types.h's
// ResyncRequest precedent: this DTO only ever travels inside an
// already-negotiated session.
struct ResyncRequest {
	std::string instance_id;
	std::uint64_t last_applied_revision = 0;
};

} // namespace wpn::protocol

#endif // WEAPON_SYSTEM_PROTOCOL_TYPES_H
