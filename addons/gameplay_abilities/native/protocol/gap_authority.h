#ifndef GAMEPLAY_ABILITIES_PROTOCOL_AUTHORITY_H
#define GAMEPLAY_ABILITIES_PROTOCOL_AUTHORITY_H

#include "core/ga_ids.h"
#include "core/ga_status.h"
#include "protocol/gap_messages.h"

#include <cstdint>
#include <map>
#include <set>

// Server-Controlled Ownership and Permission.
//
// The server -- never the client -- maintains the authoritative mapping from
// an authenticated peer session to the gameplay entities it may control. A
// client-declared node authority, target-entity field, or "owner" field in a
// packet MUST NOT by itself grant mutation permission: every activation
// command's sender-to-entity relationship is checked against this table, not
// against anything the packet itself claims. See the "Server-Controlled
// Ownership and Permission" requirement.
namespace ga::proto {

// A Godot `MultiplayerAPI` unique peer id (`get_unique_id()` /
// `get_remote_sender_id()`). This is a *transport-layer* connection identity
// assigned by the active `MultiplayerPeer` -- it is never a gameplay identity
// and must never be stored, compared, or transmitted as one (see ga_ids.h's
// "Runtime identity" section for the identities that are). `OwnershipTable`
// is the single place a `PeerId` is translated into gameplay permission.
using PeerId = std::int32_t;

// `0` is never a real connected peer id in Godot's own convention (an
// unconnected/unassigned `MultiplayerPeer` reports unique id 0), so it is
// reserved here as "no peer" the same way `INVALID_ENTITY_ID` etc. reserve 0
// in ga_ids.h.
constexpr PeerId INVALID_PEER_ID = 0;

// Soft, server-side bookkeeping bounds (not part of the wire contract --
// see ga_limits.h for those). `OwnershipTable` is populated by trusted
// server/game code deciding "peer X controls entity Y," not directly by
// untrusted packet bytes, so these are defense-in-depth rather than the
// addon's primary "hostile peer cannot grow memory without bound" guarantee
// (that guarantee belongs to gap_command_gate.h's CommandSequenceTracker and
// RateLimiter, which sit directly in the untrusted-input path). Exceeding a
// cap evicts the least-recently-touched entry (see the .cpp) rather than
// growing without limit.
constexpr std::size_t MAX_TRACKED_PEERS = 1024;
constexpr std::size_t MAX_ENTITIES_PER_PEER = 256;
constexpr std::size_t MAX_SERVER_OWNED_ENTITIES = 4096;

// Authoritative peer-session -> controlled-entity map, plus a server/AI path
// for entities no client peer owns at all.
//
// Reconnection ("Client reconnects"): `begin_session` records the *current*
// live `SessionId` for a `PeerId`. A peer that reconnects calls
// `begin_session` again with its new session id, which overwrites the old
// one; any later `validate_session` call naming the old id then fails with
// `SESSION_MISMATCH`. This is how an old session's command and prediction
// identities stop being able to authorize new mutations without this table
// needing to know anything about `CommandSeq`/`PredictionKey` bookkeeping
// itself (that bookkeeping lives in gap_command_gate.h's
// `CommandSequenceTracker`, keyed by `SessionId`, and is expected to be
// dropped via `CommandSequenceTracker::drop_session` in the same step a
// caller retires a session here). Reconnection does NOT implicitly revoke
// entity ownership grants -- a game that wants ownership to lapse on
// disconnect calls `drop_peer` explicitly; a game that wants ownership to
// survive a reconnect (the common case) just calls `begin_session` again.
//
// Server AI path ("Server AI activates an ability"): modeled as a
// **distinct pair of calls** (`authorize_server_entity` /
// `validate_server_entity`) rather than a reserved sentinel `PeerId`. A
// sentinel value would still have to satisfy `validate_control`'s
// `(PeerId, EntityId)` signature, tempting a caller to "invent" a peer id
// for AI-driven entities -- exactly what the spec scenario says must not
// happen. Server/AI-issued activation requests carry no `PeerId` or
// `SessionId` at all: they are the server's own trusted code, not inbound
// client packets, so they do not pass through `gap_command_gate.h`'s
// `CommandGate` (which exists specifically to police *untrusted client*
// commands). They call `validate_server_entity` directly and then still run
// the same downstream gameplay validation (grant/tag/cost/cooldown/target)
// as any other activation, per "normal ability validation still applies."
class OwnershipTable {
public:
	// ---- Session lifecycle -------------------------------------------

	// Records `p_session` as the current live session for `p_peer`,
	// overwriting (and thereby retiring) any previous session that peer
	// held. Does not touch entity ownership grants. Fails with
	// `StatusCode::INVALID_ARGUMENT` if `p_session == INVALID_SESSION_ID`
	// (an invalid session can never be "begun"); otherwise always succeeds.
	Status begin_session(PeerId p_peer, SessionId p_session);

	// Retires `p_peer`'s live session (later `validate_session` calls for
	// any session id, including the one just retired, fail with
	// `SESSION_MISMATCH`) without touching entity ownership grants. A
	// no-op if `p_peer` is not tracked.
	void end_session(PeerId p_peer);

	// `StatusCode::SESSION_MISMATCH` (detail = p_session) if `p_peer` has
	// no live session or its live session differs from `p_session`;
	// `ok_status()` otherwise. Every mutating command must pass this before
	// `validate_control` runs (see gap_command_gate.h's `CommandGate`,
	// which is the only intended caller in the untrusted-input path).
	Status validate_session(PeerId p_peer, SessionId p_session) const;

	// ---- Client ownership ----------------------------------------------

	// Authorizes `p_peer` to control `p_entity`. Used both for primary
	// ownership (a player's own character) and any explicit extra
	// permission grant (e.g. a temporarily shared minion) -- v1 does not
	// distinguish the two shapes, since both resolve to the identical
	// question `validate_control` asks. Fails with
	// `StatusCode::INVALID_ARGUMENT` if `p_entity == INVALID_ENTITY_ID`.
	Status authorize_control(PeerId p_peer, EntityId p_entity);

	// Revokes a previously authorized entity. `StatusCode::NOT_FOUND` if
	// `p_peer` is untracked or was never authorized for `p_entity`.
	Status revoke_control(PeerId p_peer, EntityId p_entity);

	// The single check point for "Client spoofs another entity": does NOT
	// consult anything about the command or packet itself, only this
	// server-owned map. `StatusCode::PERMISSION_DENIED` (detail =
	// p_entity's raw value) if `p_peer` is untracked, `p_entity` is
	// `INVALID_ENTITY_ID`, or `p_peer` was never authorized for
	// `p_entity`. A read-only const query: it never registers or mutates
	// anything as a side effect of a failed (or successful) check.
	Status validate_control(PeerId p_peer, EntityId p_entity) const;

	// Fully forgets `p_peer`: live session AND every controlled-entity
	// grant. Intended for "this peer is gone for good" (permanent
	// disconnect, banned, entity despawned) as opposed to `end_session`'s
	// narrower "this connection ended, ownership may resume on reconnect."
	void drop_peer(PeerId p_peer);

	// ---- Server / AI path ------------------------------------------------

	// Marks `p_entity` as directly server-controlled (e.g. an AI-driven
	// NPC) with no client peer owner. Fails with
	// `StatusCode::INVALID_ARGUMENT` if `p_entity == INVALID_ENTITY_ID`.
	Status authorize_server_entity(EntityId p_entity);

	Status revoke_server_entity(EntityId p_entity);

	// `StatusCode::PERMISSION_DENIED` (detail = p_entity's raw value) if
	// `p_entity` was never authorized via `authorize_server_entity`.
	Status validate_server_entity(EntityId p_entity) const;

	// ---- Introspection (tests / diagnostics) ---------------------------

	std::size_t tracked_peer_count() const { return peers.size(); }
	std::size_t controlled_entity_count(PeerId p_peer) const;
	std::size_t server_entity_count() const { return server_entities.size(); }

private:
	struct PeerRecord {
		SessionId session = INVALID_SESSION_ID;
		std::set<std::uint64_t> entities; // raw EntityId values this peer controls.
		std::uint64_t touch_seq = 0; // for deterministic LRU eviction; see .cpp.
	};

	// Bumps p_record's recency stamp and returns the new stamp. Not a wall
	// clock: a private monotonic call counter used purely to break eviction
	// ties deterministically given a fixed sequence of calls.
	std::uint64_t next_touch();
	void enforce_peer_cap();

	std::map<PeerId, PeerRecord> peers;
	std::set<std::uint64_t> server_entities; // raw EntityId values, server-owned.
	std::uint64_t touch_counter = 0;
};

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_AUTHORITY_H
