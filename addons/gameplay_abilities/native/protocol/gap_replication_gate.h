#ifndef GAMEPLAY_ABILITIES_PROTOCOL_REPLICATION_GATE_H
#define GAMEPLAY_ABILITIES_PROTOCOL_REPLICATION_GATE_H

#include <cstdint>

// Change-Gated State Sends (add-granular-delta-replication-2026-07-27, tasks
// 3.2/3.4/3.5): the pure, engine-free per-peer per-audience send decision
// every server push site (owner deltas, public snapshots) reduces to once it
// already knows a peer's own bookkeeping. This file owns exactly one
// decision -- "what, if anything, does this peer need this tick for this
// audience" -- and nothing else: it never touches `ga::ChangeTracker`,
// `ga::proto::AuthoritativeEventStream`, a `PeerId`, or a byte. The bridge
// (`GameplayAbilityNetworkBridge::send_owner_event_batch`/`send_public_state`,
// native/godot/gameplay_ability_network_bridge.cpp) is the one caller: it
// keeps a small per-peer `revision`/`ticks_since_send` pair (its own private
// bookkeeping, not exposed here -- this file only needs the two numbers, a
// pre-computed overflow bit, and the documented cadence constant to decide),
// calls `decide_send_gate_action` once per peer per tick, and acts on the
// result. Kept in `protocol/` (not `core/`) because it is send-cadence
// bookkeeping about REPLICATION, exactly like `gap_heartbeat.h`'s own
// "SCOPE SEAM" -- it deliberately has no dependency on `ga::ChangeAudience`/
// `ga::ChangeTracker` (core/ga_change_tracking.h) so a caller can reuse the
// identical decision for the PUBLIC audience, which this wave does not give
// its own `ChangeTracker`-ring-backed overflow concept at all (see
// `decide_send_gate_action`'s own `p_cursor_overflowed` doc below).
namespace ga::proto {

// What a peer needs THIS tick for one audience/channel, decided purely from
// four numbers. Ordered so the caller can `switch` on severity without a
// second comparison: SEND_SNAPSHOT_OVERFLOW is always the most drastic
// action a caller could take for this decision, SUPPRESSED the least.
enum class SendGateAction : std::uint8_t {
	// Nothing to send: the peer's cursor already matches the current
	// revision, and the heartbeat cadence has not yet elapsed since the
	// last send.
	SUPPRESSED = 0,
	// Cursor matches revision (no state changed), but the peer has gone
	// `p_heartbeat_cadence` ticks since its last send on this channel --
	// spec "Change-Gated State Sends": emit the bounded liveness/tick-
	// alignment heartbeat instead of state.
	HEARTBEAT = 1,
	// The revision advanced since the peer's cursor: the caller builds and
	// sends its own audience-appropriate state (a delta batch for owners
	// this wave, a full public snapshot for observers) and, on success,
	// advances the peer's cursor to the revision it just represented.
	SEND_STATE = 2,
	// The peer's cursor can no longer be bridged to the current revision by
	// any state this decision's caller could produce (spec "Delta Bounds
	// and Snapshot Fallback": the change-history ring already evicted an
	// intervening revision). The caller MUST fall back to a fresh full
	// snapshot (`ResyncTrigger::DELTA_OVERFLOW`) and reset the peer's
	// cursor to the revision that snapshot captured, rather than attempt a
	// delta that would silently omit missing revisions.
	SEND_SNAPSHOT_OVERFLOW = 3,
};

// Pure decision, no side effects, no I/O: the SAME four inputs always
// produce the SAME action, on every platform and every run (task 2.2's
// "deterministic" convention extended to send-gating).
//
//   p_cursor_revision    -- this peer's last-represented revision for the
//                            audience/channel in question (0 if genuinely
//                            never sent -- but see the note below: a truly
//                            first-time peer should usually bypass this
//                            function entirely rather than rely on
//                            0-vs-0 comparing equal by coincidence when the
//                            audience itself has never advanced).
//   p_current_revision   -- the audience's revision RIGHT NOW (e.g.
//                            `ga::ChangeTracker::revision(audience)`).
//   p_cursor_overflowed  -- true iff the caller's own bounded change-history
//                            ring can no longer answer "what changed since
//                            `p_cursor_revision`" (e.g.
//                            `ga::ChangeTracker::cursor_overflowed`). A
//                            caller with no such ring for this audience
//                            (this wave's PUBLIC/observer path, which always
//                            resends full state rather than a delta) passes
//                            `false` unconditionally -- SEND_SNAPSHOT_OVERFLOW
//                            is then never returned, matching "observers
//                            keep full-state sends, not sequenced deltas,
//                            this wave."
//   p_ticks_since_send   -- ticks elapsed since the last message (state OR
//                            heartbeat) this caller sent the peer on this
//                            channel.
//   p_heartbeat_cadence  -- `ga::HEARTBEAT_SUPPRESSED_CADENCE_TICKS`
//                            (ga_limits.h), passed explicitly (never read
//                            implicitly) so a test can pick a small cadence
//                            without waiting out the real constant. A value
//                            of 0 disables the heartbeat branch entirely
//                            (SUPPRESSED forever once caught up) -- not a
//                            real deployment configuration, but a documented
//                            edge a caller/test may legitimately exercise.
//
// Checked in this order -- overflow always wins over a plain send, and a
// plain send always wins over a heartbeat, matching `SendGateAction`'s own
// declared severity order:
//   1. `p_cursor_overflowed` -> SEND_SNAPSHOT_OVERFLOW.
//   2. `p_cursor_revision != p_current_revision` -> SEND_STATE.
//   3. `p_heartbeat_cadence > 0 && p_ticks_since_send >= p_heartbeat_cadence`
//      -> HEARTBEAT.
//   4. otherwise -> SUPPRESSED.
SendGateAction decide_send_gate_action(std::uint64_t p_cursor_revision, std::uint64_t p_current_revision,
		bool p_cursor_overflowed, std::uint64_t p_ticks_since_send, std::uint64_t p_heartbeat_cadence);

} // namespace ga::proto

#endif // GAMEPLAY_ABILITIES_PROTOCOL_REPLICATION_GATE_H
