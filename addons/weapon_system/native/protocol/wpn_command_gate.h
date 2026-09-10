#ifndef WEAPON_SYSTEM_PROTOCOL_COMMAND_GATE_H
#define WEAPON_SYSTEM_PROTOCOL_COMMAND_GATE_H

#include "core/wpn_limits.h"
#include "core/wpn_status.h"

#include <cstdint>
#include <deque>
#include <map>
#include <string>

// Engine-free, reusable protocol-level admission gates (tasks.md 7.3;
// weapon-protocol spec, "Authoritative Command Admission": "The authority
// bridge SHALL validate session readiness, owner, actor binding, role,
// connection epoch, monotonic command sequence, command identity, payload
// size, content compatibility, and command rate before routing a command to
// Weapon System"). Pure functions/state machines over identity scalars and
// configured policy -- no MultiplayerPeer, socket, or Node anywhere in this
// file, mirroring the sibling gameplay_abilities addon's
// protocol/gap_command_gate.h and protocol/gap_authority.h (this file's
// structural template).
//
// This is NOT the WeaponNetworkBridge (tasks.md 7.5, a later, out-of-scope
// task): nothing here decodes a wire DTO, touches a WeaponRuntime, or knows
// about MultiplayerAPI. WeaponCommandGate::admit() only proves a command is
// ELIGIBLE to be attempted -- the caller (the later bridge, or a test
// standing in for it) still decodes the DTO into the intent the runtime
// wants, submits it, and then calls
// CommandSequenceTracker::record()/WeaponOwnershipTable's readiness setters
// to keep this gate's bookkeeping in sync with the real outcome.
//
// *** GAMEPLAY-VALIDATION SEAM ***: WeaponRuntime's own admission rules
// (definition/instance existence, revision matching, cadence, ammunition,
// origin/aim tolerance, ...) are NOT re-implemented or duplicated here. This
// gate exists to reject an obviously stale/duplicate/unauthorized/oversized/
// over-rate command BEFORE it ever reaches the runtime -- a caller whose
// command clears `admit()` still gets whatever core::WeaponRuntime itself
// decides.
namespace wpn::protocol {

// A Godot `MultiplayerAPI` unique peer id (or any other transport's
// equivalent connection identity). Never a gameplay identity; `0` is
// reserved as "no peer", matching gap_authority.h's PeerId convention.
using PeerId = std::int32_t;
constexpr PeerId INVALID_PEER_ID = 0;

// An authority-assigned live-session identity for one peer's current
// connection. `0` means "no live session".
using SessionId = std::uint64_t;
constexpr SessionId INVALID_SESSION_ID = 0;

// A monotonically-assigned "which physical connection is this" counter, one
// per (re)connect, scoped per peer identity. Distinct from SessionId: a game
// may keep the same logical SessionId across a reconnect (e.g. resuming a
// saved session) while ConnectionEpoch always advances, so a command that
// physically arrives on a superseded connection is rejected even if its
// claimed session id still matches (weapon-protocol spec, "Old epoch sends
// after reconnect"). `0` means "no live connection".
using ConnectionEpoch = std::uint64_t;
constexpr ConnectionEpoch INVALID_CONNECTION_EPOCH = 0;

// Whether a peer may only observe (snapshots/deltas) or may also submit
// mutating commands (fire/begin_reload/cancel_reload) for a specific bound
// instance. Ordered so `WeaponRole::OWNER >= WeaponRole::OBSERVER` reads
// naturally as "owner has at least observer's access".
enum class WeaponRole : std::uint8_t {
	OBSERVER = 0,
	OWNER = 1,
};

// ---------------------------------------------------------------------------
// WeaponOwnershipTable
// ---------------------------------------------------------------------------

// Server-controlled peer -> (session, connection epoch, content-compat
// readiness, bound-instance/role) authority. A client-declared instance id,
// role, or epoch in a packet MUST NOT by itself grant admission -- every
// check compares against THIS table, never against anything the packet
// itself claims (mirrors gap_authority.h's OwnershipTable doc comment).
class WeaponOwnershipTable {
public:
	// Records `p_session`/`p_epoch` as the peer's current live connection,
	// overwriting (and thereby superseding) any previous one. Does not touch
	// bound-instance grants or compatibility readiness. `StatusCode::
	// INVALID_ARGUMENT` if `p_session == INVALID_SESSION_ID` or
	// `p_epoch == INVALID_CONNECTION_EPOCH`.
	Status begin_session(PeerId p_peer, SessionId p_session, ConnectionEpoch p_epoch);

	// Retires `p_peer`'s live session/epoch (later validate_session/
	// validate_connection_epoch calls fail) without touching bound-instance
	// grants or readiness -- a peer may reconnect and resume. A no-op if
	// `p_peer` is not tracked.
	void end_session(PeerId p_peer);

	// "session readiness": `StatusCode::SESSION_NOT_READY` /
	// `DiagnosticId::SESSION_UNKNOWN` unless `p_peer` has a live session
	// equal to `p_session`.
	Status validate_session(PeerId p_peer, SessionId p_session) const;

	// "connection epoch": `StatusCode::SESSION_NOT_READY` /
	// `DiagnosticId::CONNECTION_EPOCH_STALE` unless `p_peer`'s live
	// connection epoch equals `p_epoch` exactly (not merely `<=`: only this
	// table ever assigns a "current" epoch, so any other value -- stale or
	// otherwise -- names a superseded or forged connection).
	Status validate_connection_epoch(PeerId p_peer, ConnectionEpoch p_epoch) const;

	// "content compatibility": marks/clears/queries whether `p_peer` has
	// completed a successful CompatibilityHandshake
	// (protocol/wpn_protocol_compat.h's check_handshake_compatibility()).
	// Cleared automatically by end_session()/drop_peer() -- a reconnect must
	// re-handshake before commands are admitted again.
	void mark_compatibility_ready(PeerId p_peer);
	bool is_compatibility_ready(PeerId p_peer) const;
	Status validate_compatibility_ready(PeerId p_peer) const;

	// "owner"/"actor binding"/"role": authorizes `p_peer` to submit commands
	// for `p_instance_id` at `p_role` or below. Re-authorizing an already
	//-bound instance overwrites its role. Bounded by
	// MAX_BOUND_INSTANCES_PER_PEER; `StatusCode::LIMIT_EXCEEDED` if a NEW
	// binding would exceed it.
	Status authorize_instance(PeerId p_peer, const std::string &p_instance_id, WeaponRole p_role);
	Status revoke_instance(PeerId p_peer, const std::string &p_instance_id);

	// The single check point for "Client commands another actor's weapon":
	// `StatusCode::PERMISSION_DENIED` / `DiagnosticId::ACTOR_BINDING_DENIED`
	// if `p_peer` has no binding for `p_instance_id` at all;
	// `StatusCode::PERMISSION_DENIED` / `DiagnosticId::ROLE_INSUFFICIENT` if
	// bound at a role below `p_required_role`. Read-only; never mutates.
	Status validate_binding(PeerId p_peer, const std::string &p_instance_id, WeaponRole p_required_role) const;

	// Fully forgets `p_peer`: live session/epoch, compatibility readiness,
	// AND every bound instance. Use for "this peer is gone for good", as
	// opposed to end_session()'s narrower "connection ended, may resume".
	void drop_peer(PeerId p_peer);

	std::size_t tracked_peer_count() const { return peers.size(); }
	std::size_t bound_instance_count(PeerId p_peer) const;

private:
	struct PeerRecord {
		SessionId session = INVALID_SESSION_ID;
		ConnectionEpoch epoch = INVALID_CONNECTION_EPOCH;
		bool compatibility_ready = false;
		std::map<std::string, WeaponRole> instances; // bounded by MAX_BOUND_INSTANCES_PER_PEER.
		std::uint64_t touch_seq = 0;
	};

	std::uint64_t next_touch() { return ++touch_counter; }
	void enforce_peer_cap();

	std::map<PeerId, PeerRecord> peers;
	std::uint64_t touch_counter = 0;
};

// ---------------------------------------------------------------------------
// CommandSequenceTracker
// ---------------------------------------------------------------------------

// Per-instance "monotonic command sequence" and "idempotent command
// identity" bookkeeping, run BEFORE a command reaches WeaponRuntime (which
// keeps its own, separate, authoritative copy of the same two checks --
// see core/wpn_runtime.cpp's `state.last_command_sequence` and
// `command_history`). Running this gate-level copy first lets an obviously
// stale/duplicate/conflicting command be rejected without touching the
// runtime at all, and gives protocol-level tests that do not need a
// WeaponRuntime/WeaponCatalog to construct.
class CommandSequenceTracker {
public:
	enum class SequenceOutcome : std::uint8_t {
		EXECUTE = 0, // Fresh sequence: caller proceeds to submit the command to WeaponRuntime.
		DUPLICATE = 1, // Exact repeat of an already-recorded command_id (same payload_hash): replay r_replay_status, do not re-submit.
		CONFLICT = 2, // command_id reused with a DIFFERENT payload_hash: reject, never replay or execute.
		STALE = 3, // sequence at/below this instance's watermark and command_id not cached: reject.
	};

	// `p_payload_hash` is the caller's own canonical hash of the untrusted
	// intent DTO's encoded bytes (wpn_hash.h's hash_bytes() over
	// protocol/wpn_protocol_codec.h's encoded output) -- this tracker never
	// decodes or interprets the payload itself, only compares hashes.
	SequenceOutcome check(const std::string &p_instance_id, const std::string &p_command_id,
			std::uint64_t p_sequence, std::uint64_t p_payload_hash, Status &r_replay_status);

	// Records `p_result` as `p_command_id`'s decided outcome for
	// `p_instance_id`, advancing that instance's watermark if `p_sequence` is
	// the highest seen yet. The caller must call this once the command's
	// real outcome (submitted-and-accepted, submitted-and-rejected, or
	// gate-rejected) is known, so a later duplicate replays the ACTUAL
	// decided outcome. Idempotent to call more than once for the same
	// command_id (overwrites the cached result). Bounded by
	// MAX_DUPLICATE_RESULT_CACHE per instance and MAX_TRACKED_COMMAND_STATES
	// total, evicted deterministically (oldest-touched instance state, and
	// oldest-inserted command_id within an instance's cache).
	void record(const std::string &p_instance_id, const std::string &p_command_id,
			std::uint64_t p_sequence, std::uint64_t p_payload_hash, const Status &p_result);

	// Forgets every tracked command_id/watermark for `p_instance_id` (e.g.
	// teardown/tombstone).
	void drop_instance(const std::string &p_instance_id);

	std::size_t tracked_instance_count() const { return instances.size(); }

private:
	struct RecordedCommand {
		std::uint64_t payload_hash = 0;
		Status result;
	};
	struct InstanceState {
		std::uint64_t watermark = 0;
		std::map<std::string, RecordedCommand> replay_cache; // bounded by MAX_DUPLICATE_RESULT_CACHE.
		std::deque<std::string> replay_order;
		std::uint64_t touch_seq = 0;
	};

	std::uint64_t next_touch() { return ++touch_counter; }
	void enforce_instance_cap();

	std::map<std::string, InstanceState> instances; // bounded by MAX_TRACKED_COMMAND_STATES.
	std::uint64_t touch_counter = 0;
};

// ---------------------------------------------------------------------------
// RateLimiter
// ---------------------------------------------------------------------------

// Tick-based token buckets enforcing MAX_COMMANDS_PER_SECOND (per peer,
// covering every weapon instance that peer controls -- a single owner
// flooding several bound instances still shares one budget) and
// MAX_RESYNCS_PER_MINUTE (also per peer). No wall clock is ever read: every
// bucket's refill is a pure function of the caller-supplied authoritative
// tick and tick rate, mirroring gap_command_gate.h's RateLimiter exactly
// (see that file's class comment for the full accounting-policy rationale:
// starts full, refills linearly, admission cost rounds UP so the limiter is
// never more permissive than its nominal rate, and a non-advancing or
// regressing tick simply grants no additional credit rather than erroring).
class RateLimiter {
public:
	// `StatusCode::RATE_LIMITED` (detail = remaining credit_ticks) if
	// `p_peer`'s command bucket lacks credit; `ok_status()` and one token
	// consumed otherwise.
	Status admit_command(PeerId p_peer, std::uint64_t p_now_tick, std::uint32_t p_tick_rate = DEFAULT_TICK_RATE);

	// Same policy, MAX_RESYNCS_PER_MINUTE budget.
	Status admit_resync(PeerId p_peer, std::uint64_t p_now_tick, std::uint32_t p_tick_rate = DEFAULT_TICK_RATE);

	void drop_peer(PeerId p_peer);

	std::size_t tracked_command_bucket_count() const { return command_buckets.size(); }
	std::size_t tracked_resync_bucket_count() const { return resync_buckets.size(); }

private:
	struct TokenBucket {
		std::uint64_t credit_ticks = 0;
		std::uint64_t last_tick = 0;
		bool initialized = false;
		std::uint64_t touch_seq = 0;
	};

	static Status try_admit(TokenBucket &r_bucket, std::uint64_t p_now, std::uint64_t p_window_ticks, std::uint32_t p_capacity);
	std::uint64_t next_touch() { return ++touch_counter; }
	static void enforce_cap(std::map<PeerId, TokenBucket> &r_buckets, std::size_t p_limit);

	std::map<PeerId, TokenBucket> command_buckets; // bounded by MAX_RATE_LIMIT_BUCKETS.
	std::map<PeerId, TokenBucket> resync_buckets; // bounded by MAX_RATE_LIMIT_BUCKETS.
	std::uint64_t touch_counter = 0;
};

// Free function for the "payload size" gate: `StatusCode::PAYLOAD_TOO_LARGE`
// / `DiagnosticId::BYTE_LIMIT_EXCEEDED` if `p_bytes` exceeds
// `MAX_COMMAND_BYTES` (the contracts hard limit every command DTO's codec
// already enforces on decode -- this lets a caller reject an oversized
// packet before even attempting to decode it).
Status validate_payload_size(std::size_t p_bytes);

// ---------------------------------------------------------------------------
// WeaponCommandGate
// ---------------------------------------------------------------------------

// One already-decoded inbound client command's identity fields. The
// command's own wire payload (claimed origin/aim, reservation id, ...) is
// this gate's caller's concern, not this struct's -- WeaponCommandGate only
// ever sees the scalar identity/sequencing/sizing fields it needs to run its
// own checks (mirrors gap_command_gate.h's InboundCommandContext).
struct InboundWeaponCommandContext {
	PeerId peer = INVALID_PEER_ID;
	SessionId session = INVALID_SESSION_ID;
	ConnectionEpoch epoch = INVALID_CONNECTION_EPOCH;
	std::string instance_id; // claimed target weapon instance.
	std::string command_id; // untrusted idempotency identity.
	std::uint64_t sequence = 0; // untrusted per-instance monotonic sequence claim.
	std::uint64_t payload_hash = 0; // hash of the intent DTO's canonical encoded bytes.
	std::size_t payload_bytes = 0; // encoded size of the untrusted payload.
	std::uint64_t current_tick = 0; // authoritative "now"; used only for rate-limit accounting, never trusted as client-supplied.
	std::uint32_t tick_rate = DEFAULT_TICK_RATE;
};

enum class CommandOutcomeKind : std::uint8_t {
	EXECUTE = 0, // Fresh, eligible command: caller submits it to WeaponRuntime.
	DUPLICATE_REPLAY = 1, // Exact repeat: caller resends `status` idempotently, no re-submission.
	REJECTED = 2, // Failed a gate check: caller reports `status` as an authoritative rejection.
};

struct InboundCommandVerdict {
	CommandOutcomeKind kind = CommandOutcomeKind::REJECTED;
	Status status;
};

// Composes ownership + sequence + rate checks into one call, in the exact
// order weapon-protocol spec's "Authoritative Command Admission" requirement
// lists them: session readiness, owner, actor binding, role, connection
// epoch, monotonic command sequence, command identity, payload size, content
// compatibility, command rate.
class WeaponCommandGate {
public:
	// None of the referenced objects are owned; all must outlive this
	// WeaponCommandGate.
	WeaponCommandGate(WeaponOwnershipTable &p_ownership, CommandSequenceTracker &p_sequence, RateLimiter &p_rate) :
			ownership(p_ownership), sequence(p_sequence), rate(p_rate) {}

	// See the class comment for the exact check order. A DUPLICATE_REPLAY
	// verdict is not itself a rejection. `admit()` proves only that
	// `p_context` is eligible to be attempted -- see the *** GAMEPLAY
	// -VALIDATION SEAM *** note at the top of this file.
	Status admit(const InboundWeaponCommandContext &p_context, WeaponRole p_required_role, InboundCommandVerdict &r_verdict);

	WeaponOwnershipTable &ownership_table() { return ownership; }
	CommandSequenceTracker &sequence_tracker() { return sequence; }
	RateLimiter &rate_limiter() { return rate; }

private:
	WeaponOwnershipTable &ownership;
	CommandSequenceTracker &sequence;
	RateLimiter &rate;
};

} // namespace wpn::protocol

#endif // WEAPON_SYSTEM_PROTOCOL_COMMAND_GATE_H
