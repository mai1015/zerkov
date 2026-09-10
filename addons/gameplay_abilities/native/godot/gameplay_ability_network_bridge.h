#ifndef GAMEPLAY_ABILITIES_GODOT_ABILITY_NETWORK_BRIDGE_H
#define GAMEPLAY_ABILITIES_GODOT_ABILITY_NETWORK_BRIDGE_H

#include "core/ga_change_tracking.h"
#include "core/ga_delta.h"
#include "core/ga_ids.h"
#include "core/ga_prediction.h"
#include "core/ga_reconciliation.h"
#include "core/ga_status.h"
#include "core/ga_tick.h"
#include "godot/gameplay_ability_component.h"
#include "protocol/gap_authority.h"
#include "protocol/gap_command_gate.h"
#include "protocol/gap_delta_messages.h"
#include "protocol/gap_event_stream.h"
#include "protocol/gap_handshake.h"
#include "protocol/gap_heartbeat.h"
#include "protocol/gap_replication_gate.h"
#include "protocol/gap_resync.h"
#include "protocol/gap_target_messages.h"
#include "protocol/gap_task_messages.h"

#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <vector>

// Task 7.3/7.4/7.6(remainder)/7.9(replication)/7.11/7.12: the network-facing
// half of the addon. This node attaches beneath a game-selected
// `MultiplayerAPI` branch (see design.md "Protocol and replication") and
// never creates, replaces, or owns the game's `MultiplayerPeer`, connection,
// lobby, or authentication -- it only ever reads `Node::get_multiplayer()`
// (which resolves the branch-scoped API the game already configured, exactly
// as `examples/gameplay_abilities/net/ga_session_harness.gd` sets up via
// `SceneTree.set_multiplayer(api, branch_root.get_path())`).
//
// One bridge instance serves exactly one `GameplayAbilityComponent` (named
// by `component_path`), mirroring that component's role
// (`ga::ComponentRole`). Every DTO on the wire is built and parsed through
// `gap_messages.h`'s `encode_message`/`decode_message` framing plus this
// file's own bounded codecs for activation commands and command results
// (there is no existing protocol-layer DTO for those -- see the .cpp file
// comment for exactly why that is this file's job, not protocol's).
//
// *** Section 8 (client prediction/reconciliation), task 8.10 ***: this
// bridge drives the `ga::PredictingComponent`/`ga::PredictionReconciler` its
// served `GameplayAbilityComponent` owns (see that class's "C++-only
// collaborator seams") -- never a second, competing prediction layer of its
// own. `request_activation_networked` predicts locally first (when eligible)
// and stamps the wire command with the journal-allocated command
// sequence/prediction key so a later `command_acknowledged`/
// `command_rejected` can find the SAME pending entry;
// `PredictionReconciler::handle_acknowledgement` closes it, and a rejection
// or a detected replication gap drives `reconcile(...)`, resending any
// commands it still-eligibly replays. `get_estimated_tick()` delegates to
// the shared `ga::ServerTickEstimator` (task 8.10's "replace the bridge's
// inline tick smoothing... so there is one implementation, not two") instead
// of this file's own inline snap/smooth arithmetic.
namespace godot {

class GameplayAbilityWorldCoordinator;
class GameplayTargetValue;

class GameplayAbilityNetworkBridge : public Node {
	GDCLASS(GameplayAbilityNetworkBridge, Node)

public:
	// Mirrors ga::PredictionMode exactly (task 8.10's "surface PredictionMode
	// to script"). Carried as the `prediction_mode` key of
	// `request_activation_networked`'s result Dictionary when the served
	// component is ROLE_NETWORK_CLIENT.
	enum PredictionMode {
		PREDICTION_MODE_NOT_PREDICTED_NO_BASELINE = 0,
		PREDICTION_MODE_NOT_PREDICTED_UNKNOWN_ABILITY = 1,
		PREDICTION_MODE_NOT_PREDICTED_JOURNAL_FULL = 2,
		PREDICTION_MODE_PRESENTATION_ONLY = 3,
		PREDICTION_MODE_PREDICTED = 4,
	};

	GameplayAbilityNetworkBridge();
	~GameplayAbilityNetworkBridge() override;

	// -- Wiring ---------------------------------------------------------------

	void set_component_path(const NodePath &p_path);
	NodePath get_component_path() const { return component_path; }
	void set_world_coordinator_path(const NodePath &p_path) {
		world_coordinator_path = p_path;
	}
	NodePath get_world_coordinator_path() const {
		return world_coordinator_path;
	}

	// The peer id treated as "the server" for outbound RPCs made while this
	// bridge's component is NETWORK_CLIENT. Almost always 1 (Godot's
	// convention for the authority/host peer).
	void set_server_peer_id(int p_peer_id) { server_peer_id = p_peer_id; }
	int get_server_peer_id() const { return server_peer_id; }

	// Client-side hint: true (the default) when the LOCAL peer owns/controls
	// the entity this bridge represents -- it then receives the full
	// canonical snapshot/event codec (task 7.9) and predicts/reconciles
	// locally once section 8 exists. False marks this bridge as an
	// observer's mirror: it receives only the relevance-filtered public
	// state feed (task 7.11) via `public_state_updated`, never the full
	// canonical snapshot, and never restores anything into the local
	// `GameplayAbilityComponent`.
	void set_owner_view(bool p_owner_view) { owner_view = p_owner_view; }
	bool get_owner_view() const { return owner_view; }

	// Session timing shared with `ga::proto::RateLimiter`/`CommandSequenceTracker`
	// (ticks only, never a wall clock -- see gap_command_gate.h). Task 7.19:
	// this is only the BOOTSTRAP value used before this bridge has resolved
	// a configured served component (or if it never does) -- once one
	// exists, `effective_tick_rate()` below defers to ITS `tick_rate`
	// instead (the authoritative source; see
	// `GameplayAbilityComponent::set_tick_rate()`'s doc comment for why),
	// so a game does not have to keep two independently-settable tick rates
	// in agreement by hand. Kept as a real, still-settable property (rather
	// than removed) because `_process()`'s local advisory clock and this
	// bridge's server-side protocol bookkeeping both need SOME value before
	// -- or even without -- a resolved component.
	void set_tick_rate(int p_tick_rate) { tick_rate = p_tick_rate > 0 ? p_tick_rate : int(ga::DEFAULT_TICK_RATE); }
	int get_tick_rate() const { return tick_rate; }

	// -- Owner and Observer Visibility (task 7.11) -----------------------------
	//
	// Server-side policy: which attributes/tags/abilities appear in the
	// public (observer) state feed. Anything not listed as hidden is public
	// by default -- the ADDITIONAL owner-only detail (exact cooldown ticks,
	// set-by-caller values, source context, target data, prediction
	// metadata) is never part of the public feed regardless of these lists;
	// it is only ever present in the full canonical snapshot the owner
	// alone receives. See the .cpp for exactly what the public payload
	// contains. `hidden_ability_identifiers` governs ONLY this public-state
	// feed (which granted abilities an observer's `public_state_updated`
	// shows) -- it never governs cue visibility; see
	// `hidden_effect_identifiers` immediately below for that.
	//
	// Wave 3 (add-granular-delta-replication-2026-07-27, "Wire the
	// visibility seam"): these three setters ALSO translate their
	// identifiers into the served component's core
	// `ga::AudienceVisibilityConfig` (`sync_visibility_config()`, .cpp) so
	// the delta codec's own PUBLIC-audience filtering
	// (`AbilityComponent::write_delta_batch`) agrees with what
	// `encode_public_state()` has always filtered by these SAME
	// `PackedStringArray` lists -- and, when the effective hidden set
	// actually changed, force a full resync
	// (`ga::ChangeTracker::force_full_resync()`) so every already-synced
	// peer's cursor is treated as stale rather than silently missing the
	// now-different visibility boundary.
	void set_hidden_attribute_identifiers(const PackedStringArray &p_ids);
	PackedStringArray get_hidden_attribute_identifiers() const { return hidden_attributes; }
	void set_hidden_tag_identifiers(const PackedStringArray &p_ids);
	PackedStringArray get_hidden_tag_identifiers() const { return hidden_tags; }
	void set_hidden_ability_identifiers(const PackedStringArray &p_ids);
	PackedStringArray get_hidden_ability_identifiers() const { return hidden_abilities; }

	// Finding 7: `on_effect_cue_triggered`'s own hidden-effect filter used to
	// compare a cue's `definition_identifier` (an EFFECT identifier --
	// `effect_cue_dict`'s own field) against `hidden_ability_identifiers` (an
	// ABILITY identifier list), so it filtered nothing in normal use -- a
	// "hidden" effect's cue still reached every peer. `hidden_effect_identifiers`
	// is the list that filter actually checks: a hidden effect's cue never
	// leaves the server for ANY peer, owner included (see the .cpp for the
	// exact check).
	void set_hidden_effect_identifiers(const PackedStringArray &p_ids) { hidden_effect_identifiers = p_ids; }
	PackedStringArray get_hidden_effect_identifiers() const { return hidden_effect_identifiers; }

	// Game-provided target authorization callback (design.md "Server
	// authority and ownership", step 6: "a game-provided authority
	// validator"). Finding 8: called as `callable.callv([context])` with a
	// SINGLE Dictionary argument -- the previous 4-positional-argument
	// signature (`[entity_id, spec_id, ability_identifier, targets]`) gave a
	// validator no way to see who sent the command, which session, or its
	// sequencing/tick identity, and any of those needing to be added later
	// would have meant another breaking positional-argument change. `context`
	// carries:
	//   peer               (int)               -- the sending peer id.
	//   session            (int)               -- that peer's SessionId (see begin_session()).
	//   component          (int64)             -- this bridge's served component's entity id.
	//   spec               (int64)             -- the AbilitySpecId being activated.
	//   ability_identifier (String)
	//   targets            (PackedInt64Array)
	//   set_by_caller      (Array of {field: String, value: float})
	//   command_sequence   (int64)
	//   prediction_key     (int64)
	//   client_tick        (int64)              -- the wire command's advisory client tick.
	//   current_tick       (int64)              -- this bridge's served component's authoritative tick.
	// Must return a bool. Unset means no additional target authorization
	// runs beyond the structural bounds check (see .cpp) UNLESS
	// `require_target_authorization` is true (see that property below).
	void set_target_authorization_callback(const Callable &p_callback) { target_authorization_callback = p_callback; }
	Callable get_target_authorization_callback() const { return target_authorization_callback; }

	// Finding 8: false (the default) preserves this addon's original opt-in
	// posture -- an unset callback means "this game does not need per-target
	// authorization", exactly as before this property existed. A game whose
	// gameplay REQUIRES target authorization for every targeted ability sets
	// this true so an unset callback becomes a fail-closed configuration
	// error instead of a silent "allow everything": a targeted command
	// arriving while no callback is configured is then rejected
	// (ABILITY_INVALID_TARGET) with a bounded `network_diagnostic`, exactly
	// like a callback that itself returned false.
	void set_require_target_authorization(bool p_require) { require_target_authorization = p_require; }
	bool get_require_target_authorization() const { return require_target_authorization; }

	// -- Role / transport state -------------------------------------------

	bool is_multiplayer_active() const;

	// -- Server-side ownership (Server-Controlled Ownership and Permission) --
	//
	// The game (or a session harness/lobby step) calls these explicitly once
	// it has authenticated a peer and decided what it controls; a
	// client-declared entity/owner field is never itself sufficient (see
	// gap_authority.h).
	void begin_session(int p_peer, int p_session);
	void end_session(int p_peer);
	bool authorize_control(int p_peer, int64_t p_entity);
	bool revoke_control(int p_peer, int64_t p_entity);
	bool authorize_server_entity(int64_t p_entity);
	void drop_peer(int p_peer);

	// -- Activation (client -> server intent; local for offline/authority) --

	// Role-aware entry point matching the "Explicit Runtime Network Roles"
	// requirement: OFFLINE_AUTHORITY/SERVER_AUTHORITY call straight into the
	// local component (no packets, no prediction entries -- "Offline game
	// runs without a peer"). NETWORK_CLIENT first tries the served
	// component's own `ga::PredictingComponent` (task 8.10): when eligible,
	// the ability actually runs locally with `ChangeProvenance::PREDICTED`
	// before anything is sent, and the wire command carries the
	// journal-allocated command sequence/prediction key (not necessarily
	// `p_request`'s own) so a later acknowledgement can find the same
	// pending entry. Either way the command is then encoded and sent as an
	// ACTIVATION_COMMAND RPC to `server_peer_id`, returning immediately with
	// `{sent:true}`; the AUTHORITATIVE result still only ever arrives later
	// via `command_acknowledged`/`command_rejected`. The result Dictionary
	// additionally carries `prediction_mode` (a `PredictionMode` value) and,
	// when `PREDICTION_MODE_PREDICTED` itself failed locally (e.g. stale
	// cost/cooldown/tag state), that real local rejection is returned
	// immediately WITHOUT sending anything -- resending a command the same
	// deterministic state machine already rejected would only waste a round
	// trip. If NETWORK_CLIENT and `is_multiplayer_active()` is false, returns
	// a NETWORK_UNAVAILABLE result WITHOUT sending anything and WITHOUT
	// touching the component (it never silently becomes authority -- the
	// "Client bridge has no active peer" scenario).
	Dictionary request_activation_networked(const Dictionary &p_request, int64_t p_client_tick);
	Dictionary request_task_input_networked(int64_t p_task,
			int p_phase, int64_t p_command_sequence,
			int64_t p_client_tick, int64_t p_prediction_key = 0);
	Dictionary request_target_command_networked(int64_t p_session,
			int p_kind,
			const Ref<GameplayTargetValue> &p_intent,
			int64_t p_command_sequence,
			int64_t p_session_sequence, int64_t p_client_tick,
			int64_t p_prediction_key = 0);

	// Compatibility-only `remote_effects_pending` routing contract. This
	// signal remains for pre-typed integrations but is deprecated as the
	// primary path. New networked targeting sets `world_coordinator_path`
	// and sends typed target commands; authority resolves and applies them
	// through coordinator batches.
	//
	// `_rpc_activation_command` (server-side authority validation point)
	// calls straight into the served component's own `request_activation`,
	// exactly like the offline/authority path above -- and that result's
	// `pending_remote_effects` (task 6.13's accepted-but-not-locally-
	// applicable remote-target hook commands) used to be read only for
	// `status`/`execution` and silently dropped, even though the core had
	// already validated and captured them. This bridge now emits
	// `remote_effects_pending(payload: Dictionary)` instead, ONE time per
	// successful activation whose result carries a non-empty list:
	//   payload = {
	//     commands: Array,            -- pending_remote_effect_dict-shaped entries (see GameplayAbilityComponent)
	//     peer: int,                  -- the sending peer id
	//     spec: int,                  -- the AbilitySpecId that was activated
	//     execution: int,             -- the resulting ExecutionId
	//     command_sequence: int,      -- the wire command's own sequence
	//     current_tick: int,          -- this bridge's served component's authoritative tick
	//   }
	// One bridge serves exactly ONE component (see this file's own class
	// comment), so applying a command to some OTHER entity's component is
	// necessarily the game's job -- this signal is the legacy routing seam.
	// A legacy game connects it (typically on SERVER bridge instances) and
	// calls the TARGET entity's own `GameplayAbilityComponent.
	// apply_pending_remote_effect(command, source_component, tick)` for each
	// entry in `commands` (see that method's own doc comment). If NOTHING is
	// connected when a non-empty list would otherwise be silently dropped a
	// SECOND time, this bridge instead emits a bounded `network_diagnostic`
	// carrying `ga::DiagnosticId::REMOTE_EFFECT_UNCONSUMED` (see that
	// constant's own doc comment, ga_status.h, for why the core-side
	// `PENDING_REMOTE_EFFECT_DROPPED` diagnostic can never fire from this
	// call path instead) so silent discard is impossible either way.
	//
	// Client-side: request a fresh full snapshot (late join, gap recovery,
	// or an explicit user action).
	void request_resync(int p_reason);

	// -- Server-side state push (task 7.9 replication + 7.11 filtering) -----

	// Call once per authoritative tick (after the component's own
	// `advance_to`) on SERVER_AUTHORITY/OFFLINE_AUTHORITY. For every
	// connected peer (or every entry `relevant_peers` names, if non-empty --
	// see `set_relevant_peers`): sends an initial visibility-filtered
	// baseline SNAPSHOT the first time a peer is seen (or after
	// `request_resync`), then an ordered, change-gated EVENT_BATCH
	// afterward -- the owner's full-audience delta on `owner_stream`, an
	// observer's PUBLIC-audience delta on the independent `public_stream`
	// (Wave 4, task 3.3: "Sequenced Observer Delta Streams" -- observers no
	// longer receive a per-tick unsequenced full envelope). A no-op off
	// SERVER_AUTHORITY/OFFLINE_AUTHORITY (there is no "peer" concept to push
	// to).
	void push_full_state(int64_t p_tick);

	// -- Test/debug utilities (task 6.3, add-granular-delta-replication-
	// 2026-07-27: multipeer ENet conformance's duplication/reorder/idle-
	// suppression assertions -- see
	// tests/gameplay_abilities/network/test_delta_conformance.gd). SERVER-
	// side only; never part of a game's own replication contract, never
	// gated by handshake/relevance, and never consulted by any of this
	// class's own send logic -- a conformance test uses these to redeliver a
	// REAL previously-sent frame to a client bridge out of order or twice
	// (`_rpc_event_batch`/`_rpc_heartbeat` are already public bound methods a
	// test can call directly), and to observe heartbeat cadence, without
	// needing a custom transport that can actually duplicate or reorder real
	// ENet packets.
	//
	// Re-frames and returns the OWNER stream's retained batch whose declared
	// predecessor equals `p_since_sequence` -- byte-identical to whatever
	// `send_owner_event_batch` handed `_rpc_event_batch` for that original
	// send (same `encode_event_batch`/`encode_message` calls, same inputs).
	// Empty if `owner_stream` is null or no such batch is still retained
	// (`AuthoritativeEventStream::find_batch_after`/`try_get_payload`'s own
	// bounded retained-history window -- see that class's doc comment).
	PackedByteArray debug_peek_owner_event_batch_frame(int64_t p_since_sequence) const;

	// The most recently framed HEARTBEAT this bridge sent `p_peer` (same
	// bytes `send_heartbeat` handed `_rpc_heartbeat`), or empty if none has
	// been sent yet. Heartbeats are fire-and-forget (no retained-history
	// concept, unlike event batches -- see gap_heartbeat.h), so only the
	// single most recent one is cached, updated on every `send_heartbeat`
	// call regardless of peer.
	PackedByteArray debug_peek_last_heartbeat_frame(int p_peer) const;

	// How many HEARTBEAT messages this bridge has sent `p_peer` in total
	// (across every component this bridge has ever served -- the counter is
	// per-bridge-instance bookkeeping, never reset by `set_component_path`).
	// A conformance test drives a known number of idle authoritative ticks
	// and asserts this grows by at most `ceil(ticks / HEARTBEAT_SUPPRESSED_
	// CADENCE_TICKS)` -- "heartbeats arrive at no more than the documented
	// cadence" (spec "Idle component sends no state").
	int64_t debug_heartbeat_send_count(int p_peer) const;

	// `owner_stream`'s current head sequence (0 if not yet constructed).
	// `AuthoritativeEventStream::append_batch` advances this on EVERY
	// successful send and never otherwise -- a heartbeat never touches it
	// (gap_heartbeat.h's own "never resolve a gap" scope note) -- so an
	// UNCHANGED value across a driven idle window is direct, positive proof
	// that zero event batches were sent during it, not merely an absence of
	// a signal a test happened not to observe (spec "Idle component sends no
	// state").
	int64_t debug_owner_stream_head_sequence() const;

	// Restricts `push_full_state` to an explicit peer allow-list (server
	// visibility policy). Empty (the default -- and UNCHANGED by task 7.18
	// below: an explicit call with an empty array still means this) means
	// "every currently connected peer is relevant" -- a minimal, honest
	// default; a game wanting real spatial/team relevance calls this to
	// narrow it. Superseded by a later `set_relevant_peers`/
	// `set_no_relevant_peers` call, whichever comes last.
	void set_relevant_peers(const PackedInt32Array &p_peers) {
		relevant_peer_override = p_peers;
		relevant_peers_none = false;
	}

	// Task 7.18: explicit "no peers are relevant" -- distinct from the
	// DEFAULT empty-override state above, which means "every connected
	// peer." Before this existed, there was no way to express "nobody": a
	// server-owned entity with no local mirror (e.g. an NPC no client
	// controls or observes yet) left `relevant_peer_override` empty because
	// there was nothing else to put there, which `current_relevant_peers()`
	// read as "broadcast to everyone" -- so `push_full_state`/cue forwarding
	// silently sent snapshots and presentation events to peers that were
	// never relevant to this entity and cannot receive them meaningfully.
	// Calling this makes `current_relevant_peers()` return an empty list
	// UNCONDITIONALLY (never falling back to "every connected peer") until
	// a later `set_relevant_peers` call (empty or not) supersedes it.
	void set_no_relevant_peers() {
		relevant_peer_override.clear();
		relevant_peers_none = true;
	}
	bool get_no_relevant_peers() const { return relevant_peers_none; }

	// -- Authoritative tick alignment (task 7.12, refactored by 8.10) --------
	//
	// Presentation-only estimate, corrected from every authoritative tick
	// value this bridge observes on the wire. Never used to bypass
	// validation -- server ticks always come from the component's own
	// `advance_to` driver; this estimate is for client-side countdown UI and
	// as the advisory `client_tick` stamped on outgoing commands. Delegates
	// to the shared `ga::ServerTickEstimator` (task 8.10) instead of a
	// second, bridge-local smoothing implementation.
	int64_t get_estimated_tick() const { return int64_t(tick_estimator.estimate(local_tick_counter)); }

	void _ready() override;
	void _process(double p_delta) override;
	void _notification(int p_what);

protected:
	static void _bind_methods();

private:
	// RPC entry points (configured via rpc_config in _ready; see .cpp).
	void _rpc_handshake_request(const PackedByteArray &p_bytes);
	void _rpc_handshake_response(const PackedByteArray &p_bytes);
	void _rpc_activation_command(const PackedByteArray &p_bytes);
	void _rpc_command_result(const PackedByteArray &p_bytes);
	void _rpc_event_batch(const PackedByteArray &p_bytes);
	void _rpc_snapshot(const PackedByteArray &p_bytes);
	void _rpc_resync_request(const PackedByteArray &p_bytes);
	void _rpc_presentation_event(const PackedByteArray &p_bytes);
	void _rpc_task_input_command(const PackedByteArray &p_bytes);
	void _rpc_target_command(const PackedByteArray &p_bytes);
	void _rpc_target_outcome(const PackedByteArray &p_bytes);
	void _rpc_target_state(const PackedByteArray &p_bytes);
	// Change-Gated State Sends (task 3.4/4.4): the bounded liveness/tick-
	// alignment message a synced peer receives instead of a state-bearing
	// one while its audience revision is unchanged -- see gap_heartbeat.h.
	void _rpc_heartbeat(const PackedByteArray &p_bytes);

	GameplayAbilityComponent *resolve_component();
	const GameplayAbilityComponent *resolve_component() const;
	GameplayAbilityWorldCoordinator *resolve_world_coordinator();
	const GameplayAbilityWorldCoordinator *
	resolve_world_coordinator() const;
	void ensure_server_state();
	void ensure_client_state();
	// Wave 4 (task 4.2): lazily constructs `public_client_stream` -- the
	// observer-side sibling of `ensure_client_state()`'s `client_stream`,
	// kept as a SEPARATE method (rather than folded into
	// `ensure_client_state()`) because a given client bridge only ever
	// needs ONE of the two, decided once by `owner_view` and never both.
	void ensure_public_client_state();

	// Task 7.19: the tick rate actually in force for this bridge's session --
	// the served component's own `tick_rate` once one is resolved AND
	// configured (the authoritative source; see
	// `GameplayAbilityComponent::set_tick_rate()`), falling back to this
	// bridge's own `tick_rate` property before that (or if it never
	// resolves). Every protocol-timing-sensitive use of tick rate in this
	// file (the handshake's `tick_rate` field, `RateLimiter`/`CommandGate`
	// `SessionTiming`, `ResyncCoordinator`'s `SessionTiming`, and
	// `_process()`'s local advisory clock) reads THIS instead of the raw
	// `tick_rate` member directly, so there is exactly one value in force at
	// any moment -- never two that can silently disagree.
	std::uint32_t effective_tick_rate() const;

	// Task 7.17: performs the one-time, component-dependent setup `_ready()`
	// used to do unconditionally and only once -- connecting
	// `effect_cue_triggered` for cue forwarding, `set_multiplayer_authority(1)`
	// for a non-NETWORK_CLIENT role, and (for NETWORK_CLIENT with an active
	// peer) sending the initial handshake request. Idempotent and safe to
	// call from `_ready()`, `set_component_path()`, and lazily from any
	// on-demand entry point: a no-op once already wired to the CURRENTLY
	// resolved component; re-wires (disconnecting the old one first) if
	// `component_path` was changed to point somewhere else; does nothing
	// (but does not error) if `component_path` still does not resolve or
	// this node is not yet inside the tree -- the next call (another
	// `set_component_path`, or the next on-demand entry point) retries.
	void try_wire_component();

	// Connects this bridge to the branch-scoped MultiplayerAPI through
	// ordinary object/method Callables, whose target is tracked by ObjectID
	// rather than the raw-pointer `callable_mp` representation. The latter
	// is unsafe when a transport signal synchronously causes the client
	// world (and this bridge) to be freed while Godot is still walking the
	// same signal's connection list. `unwire_multiplayer_signals()` is
	// idempotent and uses the retained API Ref, because the SceneTree branch
	// may already have been detached by the time EXIT_TREE arrives.
	void wire_multiplayer_signals();
	void unwire_multiplayer_signals();

	// Task 7.17: emits a single bounded `network_diagnostic` the first time
	// (per unresolved streak -- reset whenever `component_path` is set or
	// wiring succeeds) an on-demand entry point (`request_activation_networked`,
	// `push_full_state`, `request_resync`) finds `component_path` still
	// unresolved, instead of silently doing nothing forever with no signal
	// a game could observe.
	void diagnose_unresolved_component();

	// Wave 3 "Wire the visibility seam": translates `hidden_attributes`/
	// `hidden_tags`/`hidden_abilities` (this bridge's script-facing
	// `PackedStringArray`s) into the served component's core
	// `ga::AudienceVisibilityConfig` (`GameplayAbilityComponent::
	// resolve_attribute_definition_id`/`resolve_tag_definition_id`/
	// `resolve_ability_definition_id`), so the delta codec's own PUBLIC-
	// audience filtering agrees with what `encode_public_state()` has always
	// filtered by these same lists. A no-op if the component is not yet
	// resolved (the next successful `try_wire_component()`/setter call
	// retries). `p_notify_resync` forces
	// `change_tracker().force_full_resync()` when the effective (translated)
	// hidden set actually changed -- callers pass `true` from a setter
	// (script changed policy live, already-synced peers must be told their
	// view may be stale) and `false` from `try_wire_component()`'s own
	// initial sync (nothing has been sent to any peer yet, so there is
	// nothing to invalidate).
	void sync_visibility_config(bool p_notify_resync);

	void send_handshake_request();
	ga::proto::HandshakeRequest build_local_handshake() const;

	// Builds the full canonical snapshot bytes (owner/authority shape) from
	// the local component.
	std::vector<std::uint8_t> encode_full_snapshot() const;
	// Builds the relevance-filtered public payload (observer shape) --
	// task 7.11. Never includes set-by-caller values, source context,
	// target data, prediction metadata, or anything named in the hidden_*
	// lists. Wave 4 (add-granular-delta-replication-2026-07-27, tasks 3.3/
	// 4.2, "Sequenced Observer Delta Streams"): superseded as this bridge's
	// OWN wire baseline source by `encode_public_baseline()` below -- a
	// bespoke, non-canonical byte layout cannot compose with the canonical
	// PUBLIC-audience delta batches `send_public_state` now rides on top of
	// a baseline (see that method's own doc comment). Kept, unused by this
	// file's own send path, because its bespoke Dictionary shape is still
	// documented and cross-referenced by several core/protocol files (e.g.
	// ga_change_tracking.h, gap_task_messages.h) describing hidden-content
	// filtering by example.
	std::vector<std::uint8_t> encode_public_state() const;
	Dictionary decode_public_state(const std::vector<std::uint8_t> &p_bytes) const;

	// Wave 4 (task 3.3): shared by `encode_public_state()` (unchanged output)
	// and this bridge's own new observer-task section
	// (`encode_public_baseline()`/`send_public_state()`) -- see the
	// definition's own doc comment (gameplay_ability_network_bridge.cpp) for
	// why ABILITY_TASK content rides this SEPARATE whitelist-projection
	// codec rather than the canonical section-delta codec's own ABILITY_TASK
	// section.
	std::vector<ga::proto::ObserverTaskRecord> build_observable_task_records() const;

	// Wave 4 (task 3.3): the observer wire baseline, replacing
	// `encode_public_state()` above as of this wave. The payload is TWO
	// concatenated parts (`compose_public_payload`, gameplay_ability_network_
	// bridge.cpp): ONE canonical delta batch (`ga::proto::encode_delta_batch`,
	// PUBLIC audience) whose dirty set is EVERY currently live identity in
	// each of ATTRIBUTE, TAG_SOURCE, ABILITY_GRANT -- the three PUBLIC-
	// eligible sections `AbilityComponent::apply_delta_batch` can install
	// onto a mirror that carries no ACTIVE_EXECUTION (see
	// `build_full_public_dirty`'s own doc comment for why ABILITY_TASK is
	// deliberately NOT among them) -- followed by an observer-task section
	// (`build_observable_task_records()` + `ga::proto::
	// encode_observer_task_section`), ALWAYS present for a baseline (a
	// baseline represents complete state, so even zero observable tasks is
	// asserted, not omitted). Marking dirty count == live count for every
	// included delta section forces `choose_delta_section_mode` (ga_delta.h)
	// to ALWAYS choose `DeltaSectionMode::FULL_REENCODE` (100% churn, provably
	// >= `DELTA_SECTION_REENCODE_CHURN_PERCENT`), which is the one section
	// mode whose own writer applies `AudienceVisibilityConfig` filtering --
	// this is what makes it safe to pass EVERY live identity here (including
	// a hidden one) without pre-filtering: the writer excludes it regardless
	// (`ga_test_wire_public_delta.cpp` proves this on the WIRE path, not just
	// the codec path -- see that file's own header comment). The delta
	// portion's canonical bytes are the SAME bytes
	// `decode_and_apply_delta_batch` (client side, `apply_public_delta`)
	// installs onto a scratch component for every later incremental delta
	// too -- baseline and delta share the ONE codec for those three
	// sections, never a second interpreter.
	std::vector<std::uint8_t> encode_public_baseline() const;
	// The dirty set `encode_public_baseline()`'s delta portion needs: every
	// currently live identity in ATTRIBUTE, TAG_SOURCE, and ABILITY_GRANT --
	// deliberately NEVER ABILITY_TASK (see `encode_public_baseline()`'s own
	// comment: a PUBLIC batch can never satisfy `apply_delta_batch`'s
	// cross-section parent-execution check, since ACTIVE_EXECUTION has no
	// PUBLIC exposure at all -- `build_observable_task_records()`/
	// `encode_observer_task_section` carry task content instead), regardless
	// of each identity's OWN hidden/visible status (see
	// `encode_public_baseline()`'s own comment for why that is safe). Never
	// touches `ChangeTracker` -- this is a LIVE-STATE enumeration, not a
	// since-revision-R dirty query, which is exactly what makes it usable as
	// a baseline even when a peer's cursor has fallen off the bounded
	// change-history ring.
	std::vector<ga::DirtyRecord> build_full_public_dirty(const ga::AbilityComponent &p_core) const;

	void send_snapshot_to_peer(int p_peer, ga::proto::ResyncTrigger p_trigger, int64_t p_tick);
	void send_owner_event_batch(int p_peer, int64_t p_tick);
	void send_public_state(int p_peer, int64_t p_tick);
	// Change-Gated State Sends (task 3.4): sent to `p_peer` in place of a
	// state-bearing message while `decide_send_gate_action` reports
	// SUPPRESSED-past-cadence for that peer's audience/channel.
	// `p_head_sequence` is whichever single event stream serves this send --
	// `owner_stream->head_sequence()` for an owner, and (Wave 4, task 3.3)
	// `public_stream->head_sequence()` for an observer, now that observers
	// have their own sequenced stream too. `ga::INVALID_EVENT_SEQ` remains a
	// legitimate value either audience's caller can pass for a peer whose
	// stream has not appended anything yet (see gap_heartbeat.h's own doc
	// comment on that field being "not established," not "never applies to
	// observers").
	void send_heartbeat(int p_peer, ga::EventSeq p_head_sequence, int64_t p_tick);
	// `p_authority_durable_handles` (task 8.11): every durable effect handle
	// THIS commit produced that a predicting client would also have
	// journaled a temp handle for -- see `CommandResultWire`'s own doc
	// comment (gameplay_ability_network_bridge.cpp) for the exact ordering
	// contract. Empty for a rejection or for a role that never predicts.
	void send_command_result(int p_peer, ga::EntityId p_component, ga::CommandSeq p_sequence, ga::PredictionKey p_key,
			ga::ExecutionId p_execution, const ga::Status &p_status,
			const std::vector<ga::EffectHandle> &p_authority_durable_handles = {});
	void send_target_outcome(int p_peer,
			const ga::TargetSessionCommandResult &p_result);
	void send_target_state_to_peer(int p_peer,
			ga::EntityId p_owner);

	void on_effect_cue_triggered(Dictionary p_cue);

	void correct_estimated_tick(ga::Tick p_observed);

	// Task 7.16: per-ability target-data schema cardinality/byte-limit
	// enforcement, run at the authority validation point
	// (`_rpc_activation_command`) before the game-provided target
	// authorization callback and before any mutation. `ok()` on the returned
	// Status means either no schema was declared for this ability (only the
	// protocol's global bounds apply) or the decoded command satisfies it.
	//
	// Task 7.20: a thin delegate to
	// `GameplayAbilityComponent::validate_target_data_schema` -- the actual
	// enforcement logic now lives THERE (so `GameplayAbilityComponent::
	// request_activation`/`process_activation_batch`'s direct/offline path
	// enforces the exact same per-ability schema this networked path always
	// has), not duplicated here. Kept as its own method, with this same
	// signature, only so `_rpc_activation_command`'s existing call site did
	// not need to change.
	ga::Status validate_target_data_schema(const GameplayAbilityComponent &p_component, const String &p_ability_identifier,
			const std::vector<ga::EntityId> &p_targets, const std::vector<ga::SetByCallerMagnitude> &p_set_by_caller) const;

	// Task 8.10: encodes and sends one ACTIVATION_COMMAND RPC built from
	// already-resolved parts (spec/targets/set_by_caller from
	// `p_request`, sequence/key supplied explicitly) -- the shared tail both
	// `request_activation_networked` and the reconcile-driven resend path
	// use, so there is exactly one wire encoder for this message, not two.
	ga::Status send_activation_command(const ga::ActivationRequest &p_request, ga::CommandSeq p_sequence,
			ga::PredictionKey p_key, ga::Tick p_client_tick);
	ga::Status send_task_input_command(
			const ga::proto::TaskInputCommandDto &p_command);
	ga::Status send_target_command(
			const ga::proto::TargetCommandDto &p_command);

	// Task 8.10: feeds one decoded acknowledgement/rejection into the served
	// component's `ga::PredictionReconciler` (a no-op if the component is not
	// ROLE_NETWORK_CLIENT or the ack's identity is not currently pending).
	// On REJECTED, also drives `reconcile(...)` against `last_confirmed_snapshot`
	// and resends every still-eligible replayed command.
	// `p_authority_durable_handles` (task 8.11): the wire's ordered authority
	// handle list (see `CommandResultWire`'s doc comment); zipped,
	// positionally, against this component's own journaled temp handles to
	// build `ga::PredictionAck::temp_handles`/`authority_handles` before
	// `PredictionReconciler::handle_acknowledgement` runs. Ignored for a
	// REJECTED ack (nothing to map).
	void feed_prediction_acknowledgement(const ga::proto::MessageType &p_type, ga::CommandSeq p_sequence,
			ga::PredictionKey p_key, const ga::Status &p_status,
			const std::vector<ga::EffectHandle> &p_authority_durable_handles = {});

	// Task 8.10: "drive reconcile(...) on rejection or divergence" -- shared
	// by the REJECTED-ack path above and by a detected replication gap
	// (`_rpc_event_batch`'s sequence-gap branch). No-op if this bridge has no
	// confirmed baseline yet (`last_confirmed_snapshot` empty) or the
	// component is not predicting.
	void reconcile_and_resend(ga::Tick p_tick);

	// Finding 2a: `_rpc_snapshot`'s owner-path `ApplySnapshotFn` uses this so
	// a SNAPSHOT arriving mid-prediction does not silently strand the
	// journal (see this bridge's own `_rpc_event_batch`'s doc comment for
	// why the routine per-tick EVENT_BATCH path deliberately does NOT also
	// route through here -- a plain restore is that path's own instead).
	// When `p_comp` is predicting AND its journal has pending entries,
	// routes through `p_comp->reconcile_snapshot(...)` (restores `p_payload`
	// AND replays every still-pending command against the fresh baseline,
	// preserving identity -- see that method's own doc comment) instead of
	// a plain `restore_snapshot()` -- `reconcile_snapshot()` performs the
	// restore itself, so this never ALSO calls `restore_snapshot()` for the
	// SAME payload. Deliberately never resends anything here even when
	// replay succeeds: the original commands are already in flight and the
	// server's own `ga::proto::CommandSequenceTracker` dedupes duplicates
	// regardless -- resending stays exclusive to `reconcile_and_resend`
	// (the rejection/gap paths). Returns a Status suitable to hand straight
	// back as the callback's own return value (ok() advances the caller's
	// own sequencing bookkeeping; non-ok() moves it to NEEDS_SNAPSHOT,
	// exactly like a plain failed restore would).
	ga::Status apply_confirmed_payload(GameplayAbilityComponent *p_comp, const std::vector<std::uint8_t> &p_payload, ga::Tick p_tick);

	// Wave 3 (task 4.1/4.3): `_rpc_event_batch`'s ROUTINE per-batch
	// `ApplyEventBatchFn` -- EVENT_BATCH now carries a granular delta
	// (task 3.2), never a self-sufficient full snapshot, so this is the
	// delta-shaped analogue of the plain-restore half of
	// `apply_confirmed_payload` above: restores this bridge's OWN
	// `last_confirmed_snapshot` baseline onto `p_comp` (via the existing
	// atomic, rollback-on-failure `GameplayAbilityComponent::
	// restore_snapshot`), applies `p_delta_payload` on top
	// (`ga::proto::decode_and_apply_delta_batch`, which -- since this
	// bridge never encodes a TARGET_SESSION section into an owner delta,
	// see `send_owner_event_batch`'s own comment -- is fully atomic here:
	// either all six owned sections install or none do), and on success
	// refreshes `last_confirmed_snapshot` to the resulting confirmed state
	// (re-encoded via `encode_full_snapshot()`) so a LATER reconciliation
	// (an owner-path SNAPSHOT, a REJECTED acknowledgement, or a detected
	// gap -- all via `reconcile_and_resend`, which already restores+replays
	// from `last_confirmed_snapshot`) restores the right baseline.
	//
	// Deliberately does NOT itself replay pending predictions -- see
	// `_rpc_event_batch`'s own doc comment for why routing the ROUTINE
	// per-batch path through `reconcile_snapshot()`'s replay would
	// re-introduce the "PREDICT fires once per still-pending batch instead
	// of once" regression Finding 2a's own comment documents (the SAME
	// concern, now framed for a delta payload instead of a full snapshot).
	// A predicting client's speculative state is (as before Wave 3)
	// superseded by this restore-then-apply and re-established the next
	// time one of those genuinely infrequent reconciliation events runs.
	//
	// On ANY failure (restore fails, or the delta fails to apply), the live
	// component is left holding exactly `last_confirmed_snapshot` (restore
	// already installed it; a failed `apply_delta_batch` never partially
	// installs, per the atomicity note above) -- a valid, if stale, state.
	// The caller's existing non-OK handling in `_rpc_event_batch`
	// (`request_resync` + `reconcile_and_resend`, unchanged by this wave)
	// already implements "restore last_confirmed_snapshot if possible, else
	// disable prediction + request resync" from THAT known-good baseline,
	// satisfying the same baseline-lost recovery contract
	// `apply_confirmed_payload`'s failure path gives a failed SNAPSHOT
	// restore, without this method duplicating that recovery itself.
	ga::Status apply_owner_delta(GameplayAbilityComponent *p_comp, const std::vector<std::uint8_t> &p_delta_payload);

	// Wave 4 (task 4.2): the observer-side analogue of `apply_owner_delta`,
	// applying ONE canonical PUBLIC-audience delta batch (a baseline built
	// by `encode_public_baseline()`, or a routine incremental delta) onto
	// `public_mirror`. `p_delta_payload` is the TWO-part composed payload
	// `compose_public_payload` built server-side (gameplay_ability_network_
	// bridge.cpp): `decompose_public_payload` splits it back into the
	// canonical delta-batch portion (applied onto `public_mirror` via
	// `ga::proto::decode_and_apply_delta_batch`, covering ATTRIBUTE,
	// TAG_SOURCE, ABILITY_GRANT ONLY -- see `build_full_public_dirty`'s own
	// doc comment for why ABILITY_TASK is never part of it) and an OPTIONAL
	// observer-task section (`ga::proto::decode_observer_task_section`,
	// decoded straight into `confirmed_observable_tasks`, wholesale-replacing
	// it -- there is no per-task add/update/remove op here, matching
	// `encode_observer_task_section`'s own "always the full current list"
	// convention); ABSENT (not merely empty) means "no task changed since
	// the last update," so `confirmed_observable_tasks` is left untouched.
	// Unlike the owner path, this never restores-then-applies the delta
	// portion on every call: an observer never predicts, so nothing ever
	// overwrites `public_mirror` with speculative state between confirmed
	// updates -- `public_mirror` simply accumulates confirmed PUBLIC state
	// across calls, exactly like `p_comp->core_component()` does for a
	// (non-predicting) authority. The FIRST call after a fresh baseline is
	// distinguished by the caller (`_rpc_snapshot`'s observer branch)
	// rebuilding `public_mirror` from scratch via
	// `GameplayAbilityComponent::build_scratch_mirror()` first -- see that
	// method's own doc comment for why a stale mirror must never survive a
	// resync (an OMITTED section in a delta batch means "unchanged," not
	// "empty," so replaying a fresh baseline onto a STALE mirror could leave
	// content the new baseline never re-asserts); a baseline's task section
	// is ALWAYS present (even representing zero tasks), so
	// `confirmed_observable_tasks` gets the identical "replace wholesale"
	// treatment with no separate reset needed. On success, re-derives this
	// bridge's decoded public Dictionary from the mirror's/list's now-current
	// state (`decode_public_state_from_mirror`) and emits
	// `public_state_updated` exactly like the pre-Wave-4 per-tick path did
	// -- the signal's own Dictionary contract is unchanged, only how it gets
	// produced. On failure, `public_mirror`/`confirmed_observable_tasks` are
	// left exactly as `ga::AbilityComponent::apply_delta_batch`'s own
	// validate-then-mutate contract guarantees for the delta portion
	// (unchanged, since a failed apply never partially installs) -- the
	// caller's existing gap handling (`request_resync`) recovers from there,
	// matching the owner path's identical shape. `p_tick` is the batch's/
	// envelope's own `authoritative_tick` (the CALLER already decoded it --
	// `public_mirror` has no independent tick of its own to read, unlike an
	// authority component that runs its own `advance_to`), forwarded
	// unchanged into the emitted Dictionary's `tick` field.
	ga::Status apply_public_delta(const std::vector<std::uint8_t> &p_delta_payload, int64_t p_tick);

	// Wave 4 (task 4.2): reads `public_mirror`'s CURRENT live state
	// (attributes/tags/grants) directly -- no byte round-trip;
	// `public_mirror` shares this bridge's served `GameplayAbilityComponent`'s
	// own registries via `build_scratch_mirror`, so identifiers resolve
	// through THAT component's existing `resolve_attribute_identifier`/
	// `resolve_tag_identifier`/`resolve_ability_identifier` -- plus
	// `confirmed_observable_tasks` (already-decoded `ObserverTaskRecord`s,
	// no further selection/resolution needed) for the task list, into the
	// EXACT SAME Dictionary shape `decode_public_state()` produces from wire
	// bytes (entity_id, tick, attributes, tags, granted_abilities,
	// observable_tasks) -- the `public_state_updated` signal's decoded
	// surface does not change between the pre-Wave-4 per-tick path and this
	// one. No filtering by this bridge's OWN `hidden_*` lists happens here
	// (unlike `encode_public_state()`): `public_mirror`'s and
	// `confirmed_observable_tasks`' content was already filtered
	// SERVER-side (`encode_public_baseline()`/the PUBLIC delta codec/
	// `build_observable_task_records()`) before it ever reached the wire, so
	// there is nothing hidden left to filter by the time this reads it.
	// Returns an empty Dictionary if `public_mirror` is null (defensive;
	// every call site establishes it first).
	Dictionary decode_public_state_from_mirror(int64_t p_tick) const;

	// Finding 2e: sweeps `ga::MAX_PREDICTION_AGE_TICKS`-abandoned journal
	// entries once per local tick increment (called from `_process()`) for a
	// ROLE_NETWORK_CLIENT component. A cheap no-op when nothing is pending.
	// When it drops anything (prediction is now disabled -- see
	// `ga::PredictingComponent::sweep_expired`'s own doc comment), requests
	// a resync so recovery starts automatically instead of leaving
	// prediction disabled forever.
	void sweep_expired_predictions();

	// Finding 2c: reacts to this bridge's session ending from underneath a
	// ROLE_NETWORK_CLIENT component -- connected by
	// `wire_multiplayer_signals()` to the branch `MultiplayerAPI`'s own
	// `server_disconnected`/`peer_disconnected` signals from
	// `try_wire_component()`. Disables prediction (its baseline is gone),
	// resets `handshake_ok` (a fresh handshake is required before this
	// bridge trusts anything from a reconnect), and clears
	// `last_confirmed_snapshot` (a stale baseline from the dead session
	// must never be reconciled against after reconnecting).
	void on_disconnected_from_server();
	void on_server_disconnected();
	void on_peer_disconnected(int64_t p_peer_id);

	// Finding 3a: "handshake never retried" -- `try_wire_component()` used to
	// send the client handshake ONLY when the branch `MultiplayerAPI` was
	// already connected at wiring time; a peer that connected LATER (the
	// natural "build the gameplay world first, connect the transport after"
	// order) never got a handshake at all. `on_connected_to_server` (wired to
	// the branch API's own `connected_to_server` signal) covers the
	// ordinary "this peer just finished connecting to the server" case;
	// `on_peer_connected` (wired to `peer_connected`) covers the
	// listen-server/mesh case where THIS peer observes `server_peer_id`
	// itself becoming a known peer, which is not guaranteed to also fire
	// `connected_to_server` on every `MultiplayerAPI` implementation. Both
	// just (re)send the handshake -- re-sending an identical, already-
	// accepted handshake is idempotent server-side (see
	// `_rpc_handshake_request`, which simply recomputes and re-inserts the
	// same `handshake_ok_peers` membership either way), so there is no harm
	// if both signals fire for the same connection event.
	void on_connected_to_server();
	void on_peer_connected(int64_t p_peer_id);

	PackedInt32Array current_relevant_peers() const;
	bool peer_is_owner(int p_peer) const;

	// Structural debt fix: the 8 `_rpc_*` handlers above each repeated the
	// same "decode_message + this-message-type's byte limit + header type
	// check + bail" preamble with zero behavioral variation in the DECODE
	// step itself -- only what happens AFTER a failed decode differs (some
	// emit a bounded `network_diagnostic`, some return silently), and THAT
	// decision stays at each call site, never inside this helper. Returns
	// false if `decode_message` itself failed OR the decoded header's
	// `message_type` does not equal `p_expected`; `r_header`/`r_payload` are
	// still populated with whatever `decode_message` itself produced
	// whenever THAT step alone succeeded, even on a `p_expected` mismatch --
	// `_rpc_command_result` (the one handler that legitimately accepts
	// either of two message types sharing one wire shape) relies on being
	// able to inspect `r_header.message_type` itself after a single call
	// instead of decoding the same bytes twice.
	bool decode_framed(const PackedByteArray &p_bytes, ga::proto::MessageType p_expected, ga::proto::MessageHeader &r_header, std::vector<std::uint8_t> &r_payload);

	// Change-Gated State Sends (task 3.2/3.4/3.5): this bridge's OWN
	// per-peer, per-audience replication bookkeeping -- the two numbers
	// `ga::proto::decide_send_gate_action` (gap_replication_gate.h) needs to
	// decide SUPPRESSED/HEARTBEAT/SEND_STATE/SEND_SNAPSHOT_OVERFLOW for one
	// peer this tick. `revision` is the last `ga::ChangeTracker` revision
	// (OWNER_FACING or PUBLIC, matching whichever map holds this entry) this
	// peer has been fully brought up to date on -- for OWNER_FACING that
	// means "represented in an EVENT_BATCH delta the peer received, or in a
	// SNAPSHOT" (see `send_snapshot_to_peer`/`send_owner_event_batch`); for
	// PUBLIC it means the SAME thing, one audience over: represented in a
	// public EVENT_BATCH delta or a public baseline SNAPSHOT (Wave 4, task
	// 3.3; see `send_snapshot_to_peer`/`send_public_state`).
	// `ticks_since_send` counts ticks since the last message (state OR
	// heartbeat) this bridge sent the peer on that same channel -- see
	// `send_heartbeat`'s own doc comment for why a target-state-only send
	// deliberately still resets it (a documented simplification, not a
	// separate counter).
	struct ReplicationCursor {
		std::uint64_t revision = 0;
		std::uint64_t ticks_since_send = 0;
	};
	// Established (see `send_snapshot_to_peer`) exactly when
	// `synced_peers.insert(peer)` first happens for an owner, and reset to
	// the fresh baseline's own revision on every later `ResyncTrigger::
	// DELTA_OVERFLOW`/explicit-resync snapshot -- `send_owner_event_batch`
	// never expects a missing entry in normal operation (see that method's
	// own comment), but the map's own default-construction (revision 0,
	// never sent) is still a safe, if conservative, fallback should one ever
	// occur. Review fix (Wave 5, owner-side invalidation audit): a revision
	// here is only meaningful relative to the OLD component's own
	// `ChangeTracker` -- cleared in `set_component_path()` when the served
	// component changes, closing the gap `public_cursors`' own Wave 4 fix
	// comment used to flag as "PRE-EXISTING Wave 3, not touched here". No
	// equivalent fix is needed for disconnect+reconnect: server-side
	// `drop_peer()` already erases a disconnected peer's entry (Wave 3), so a
	// reconnecting peer is unconditionally treated as never-synced again.
	std::map<int32_t, ReplicationCursor> owner_cursors;
	// Established the FIRST time `send_public_state` actually sends this
	// peer state -- detected via simple map membership (`send_public_state`'s
	// own doc comment) rather than a 0-revision sentinel that could coincide
	// with a genuinely unchanged component. Wave 4 (task 3.3): a missing
	// entry now routes through `send_snapshot_to_peer(peer,
	// ResyncTrigger::FIRST_RELEVANCE, tick)` -- the SAME first-relevance path
	// owners' `synced_peers` drives, generalized to build its payload from
	// `encode_public_baseline()` for a non-owner peer -- rather than a
	// separate observer-only "first send" branch. Review fix (Wave 4):
	// cleared in `set_component_path()` when the served component changes --
	// a revision here is only meaningful relative to the OLD component's own
	// `ChangeTracker`, and (Wave 5 closed the same gap for `owner_cursors`,
	// see that member's own comment) map membership itself is load-bearing: a
	// stale entry would make `send_public_state` skip a peer's mandatory
	// first-relevance baseline for the new component entirely, not just
	// compare a foreign revision number.
	std::map<int32_t, ReplicationCursor> public_cursors;

	NodePath component_path;
	NodePath world_coordinator_path;
	int server_peer_id = 1;
	bool owner_view = true;
	int tick_rate = int(ga::DEFAULT_TICK_RATE);
	PackedStringArray hidden_attributes;
	PackedStringArray hidden_tags;
	PackedStringArray hidden_abilities;
	// Finding 7: see `set_hidden_effect_identifiers()`'s own doc comment --
	// this is the list `on_effect_cue_triggered` actually filters cues
	// against, never `hidden_abilities` above.
	PackedStringArray hidden_effect_identifiers;
	Callable target_authorization_callback;
	// Finding 8: see `set_require_target_authorization()`'s own doc comment.
	bool require_target_authorization = false;
	PackedInt32Array relevant_peer_override;
	// Task 7.18: see `set_no_relevant_peers()`. When true,
	// `current_relevant_peers()` returns empty unconditionally, regardless
	// of `relevant_peer_override`/connected-peer fallback.
	bool relevant_peers_none = false;

	GameplayAbilityComponent *component = nullptr;
	ga::proto::SessionId local_session_id = 1;

	// Task 7.17: one-time wiring bookkeeping -- see `try_wire_component()`.
	bool wired = false;
	GameplayAbilityComponent *wired_component = nullptr;
	bool unresolved_diagnostic_sent = false;
	// The exact branch API that owns the four connect/disconnect signal
	// callables installed by `wire_multiplayer_signals()`. Holding the
	// Ref is intentional: the session harness removes the SceneTree branch
	// before its `session_failed` callback frees the gameplay world, so
	// `get_multiplayer()` during EXIT_TREE would return a different/default
	// API and leave the real emitter connected.
	Ref<MultiplayerAPI> wired_multiplayer_api;

	// Server-side protocol state (constructed lazily; harmless if unused on
	// a pure client/offline bridge).
	std::unique_ptr<ga::proto::OwnershipTable> ownership;
	std::unique_ptr<ga::proto::CommandSequenceTracker> sequence;
	std::unique_ptr<ga::proto::RateLimiter> rate_limiter;
	std::unique_ptr<ga::proto::DefaultStrikePolicy> strikes;
	std::unique_ptr<ga::proto::CommandGate> gate;
	// Review fix (Wave 5, owner-side invalidation audit): reset to null in
	// `set_component_path()` for the IDENTICAL reason `public_stream` below
	// already was in Wave 4 -- `AuthoritativeEventStream` locks onto
	// whichever `EntityId` its FIRST `append_batch` call names and rejects
	// every later call naming a different one (see that class's own doc
	// comment), so left alone across a repoint it would fail closed forever
	// for a differently-identified new component. This was the "PRE-EXISTING
	// Wave 3 gap" `public_stream`'s own Wave 4 fix comment used to flag as
	// not yet touched; `ensure_server_state()` rebuilds it unlocked on next
	// use, exactly like `public_stream`.
	std::unique_ptr<ga::proto::AuthoritativeEventStream> owner_stream;
	// Wave 4 (task 3.3): the PUBLIC audience's own sequencing stream,
	// instantiated and reset exactly like `owner_stream` above (see
	// `ensure_server_state()`) but never shared with it -- one component
	// owns two independent `EventSeq` spaces, one per audience, matching
	// `ga::ChangeTracker`'s own per-audience revision split
	// (ga_change_tracking.h). Every currently relevant observer peer's
	// batches ride THIS stream (`send_public_state`'s SEND_STATE branch);
	// `send_owner_event_batch`'s owner batches keep riding `owner_stream`
	// exclusively, never this one. Review fix (Wave 4): reset to null in
	// `set_component_path()` when the served component changes --
	// `AuthoritativeEventStream` locks onto whichever `EntityId` its FIRST
	// `append_batch` call names and rejects every later call naming a
	// different one (see that class's own doc comment), so left alone it
	// would fail closed forever for a differently-identified new component;
	// `ensure_server_state()` rebuilds it unlocked on next use.
	std::unique_ptr<ga::proto::AuthoritativeEventStream> public_stream;
	std::unique_ptr<ga::proto::ResyncCoordinator> resync_coordinator;
	std::set<int32_t> handshake_ok_peers;
	// Gates whether an owner peer gets the unconditional FIRST_RELEVANCE
	// snapshot (`push_full_state`) vs. a routine `send_owner_event_batch`
	// call. Cleared per-peer on disconnect by server-side `drop_peer()`
	// (Wave 3 -- a reconnecting peer is unconditionally treated as
	// never-synced again). Review fix (Wave 5, owner-side invalidation
	// audit): also cleared WHOLESALE in `set_component_path()` -- membership
	// here is only meaningful for the OLD component; left alone across a
	// repoint, an already-synced peer would skip the new component's own
	// mandatory first-relevance snapshot (and the send-gate would then
	// compare `owner_cursors`/`owner_stream` state that no longer describes
	// the served component at all). Same gap class `public_cursors`' Wave 4
	// fix already closed for the PUBLIC audience.
	std::set<int32_t> synced_peers;
	// PeerId -> SessionId, populated by begin_session(); see the .cpp file
	// comment's "v1 simplification" note on SessionId defaulting.
	std::map<int32_t, int32_t> peer_sessions;

	// Test/debug-only bookkeeping for `debug_peek_last_heartbeat_frame`/
	// `debug_heartbeat_send_count` above -- see those methods' own doc
	// comments. Never read by any real send/gate decision in this file.
	std::map<int32_t, std::vector<std::uint8_t>> debug_last_heartbeat_frame;
	std::map<int32_t, std::uint64_t> debug_heartbeat_count;

	// Client-side protocol state.
	// Review fix (Wave 5, owner-side invalidation audit): reset to null in
	// `set_component_path()`, mirroring `public_client_stream` below --
	// `ClientEventStream` is entity-locked at CONSTRUCTION (unlike
	// `AuthoritativeEventStream`'s first-`append_batch` lock, there is no
	// later call that could re-lock it), so left alone across a repoint it
	// would reject every future snapshot/event batch for the new component
	// forever (`apply_snapshot_envelope`'s own component-identity check).
	// Also quarantined via `reset_for_new_session()` in
	// `on_disconnected_from_server()`, mirroring `public_client_stream`'s own
	// treatment there: the served component's identity does not change
	// across a reconnect, so the entity check alone would keep matching, and
	// the guaranteed fresh FIRST_RELEVANCE snapshot a reconnecting peer
	// receives (server-side `drop_peer()` above) calls `establish_baseline()`
	// unconditionally regardless -- but `public_client_stream` gets the same
	// explicit reset for the identical narrow reason (closing the window
	// before that fresh baseline lands, not relying on it), so `client_stream`
	// gets it too rather than staying the one asymmetric exception.
	std::unique_ptr<ga::proto::ClientEventStream> client_stream;
	// Wave 4 (task 4.2): the observer-side sibling of `client_stream` --
	// established by `_rpc_snapshot`'s observer branch via
	// `ga::proto::apply_snapshot_envelope`, exactly like `client_stream` is
	// for owners, just against `public_stream`'s sequence space instead of
	// `owner_stream`'s. A bridge with `owner_view == true` never constructs
	// this; a bridge with `owner_view == false` never constructs
	// `client_stream` -- the two are mutually exclusive per bridge instance
	// (see `ensure_client_state()`/`ensure_public_client_state()`'s own doc
	// comments). Review fix (Wave 4): entity-locked exactly like
	// `public_stream` above (`ensure_public_client_state()` constructs it
	// ONCE, from `resolve_component()`'s entity id, only when null) -- reset
	// to null in `set_component_path()` (so a repoint rebuilds it bound to
	// whatever resolves next; left alone, `apply_snapshot_envelope`'s own
	// component-identity check would permanently reject every future
	// baseline) and quarantined via `reset_for_new_session()` in
	// `on_disconnected_from_server()` (a reconnect is a new trust epoch --
	// see that method's own call site and `reset_for_new_session()`'s own
	// doc comment).
	std::unique_ptr<ga::proto::ClientEventStream> public_client_stream;
	// Wave 4 (task 4.2): the observer's scratch core-component mirror
	// canonical PUBLIC-audience baseline/delta batches install onto -- see
	// `GameplayAbilityComponent::build_scratch_mirror()`'s own doc comment
	// for why this is a SEPARATE instance from `component->core_component()`
	// (which stays untouched for an observer bridge, preserving this file's
	// pre-Wave-4 "never restores anything into the local
	// GameplayAbilityComponent" contract for observers -- see
	// `set_owner_view()`'s own doc comment). Rebuilt from scratch on every
	// fresh baseline (`_rpc_snapshot`'s observer branch); null before the
	// first one arrives, matching `last_confirmed_snapshot`'s own
	// "empty until first successful apply" convention below. Review fix
	// (Wave 4): `build_scratch_mirror()` captures the SERVED component's own
	// registries BY REFERENCE, so this must never survive past that
	// component -- reset to null in `set_component_path()` (leaving it
	// pointed at a freed node's registries would be a use-after-free the
	// next time `apply_public_delta` touches it, the same bug class as the
	// coordinator's own `restore_snapshot` UAF this file fixes elsewhere) and
	// discarded (not merely stale) in `on_disconnected_from_server()` (a
	// stray in-flight delta from the dead session must never apply onto it).
	std::unique_ptr<ga::AbilityComponent> public_mirror;
	// Wave 4 (task 4.2): the observer's confirmed observable-task list --
	// see `apply_public_delta`'s own doc comment for exactly when this is
	// replaced wholesale vs. left untouched. Kept SEPARATE from
	// `public_mirror`'s own `ability_tasks()` because ABILITY_TASK content
	// never rides the canonical delta codec for PUBLIC audience at all (see
	// `build_full_public_dirty`'s own doc comment) -- this is the ONLY place
	// this bridge keeps confirmed observer-task state client-side. Review fix
	// (Wave 4): cleared alongside `public_mirror` in BOTH `set_component_
	// path()` and `on_disconnected_from_server()` for the identical reason --
	// confirmed PUBLIC state for a component/session that is no longer this
	// bridge's own must never survive into the next one.
	std::vector<ga::proto::ObserverTaskRecord> confirmed_observable_tasks;
	bool handshake_ok = false;

	// Task 8.10: the latest CONFIRMED (authoritative) full component-snapshot
	// bytes this bridge has successfully applied, from either a SNAPSHOT or
	// an EVENT_BATCH message (both carry a full canonical snapshot payload --
	// see the .cpp file comment's "Deliberate v1 scope reductions"). Fed
	// straight into `ga::PredictionReconciler::reconcile` as its
	// `p_confirmed_snapshot` argument; empty until the first successful
	// apply, in which case `reconcile_and_resend` is a no-op (nothing
	// confirmed yet to restore to). Cleared in `on_disconnected_from_server()`
	// (a stale baseline from the dead session must never be reconciled
	// against once a new one begins). Review fix (Wave 5, owner-side
	// invalidation audit): ALSO cleared in `set_component_path()` -- these
	// bytes are confirmed state captured FROM the OLD component; left alone
	// across a repoint, an EVENT_BATCH arriving before `client_stream`'s
	// fresh baseline is established would hit `apply_batch`'s
	// AWAITING_BASELINE branch, fall into `_rpc_event_batch`'s gap-handling
	// call to `reconcile_and_resend`, and -- since that function only
	// no-ops on an EMPTY baseline -- restore the OLD component's stale
	// snapshot bytes onto the NEW one via `reconcile_snapshot`: a real
	// cross-component state-stomp on the live component, not merely a stale
	// comparison.
	std::vector<std::uint8_t> last_confirmed_snapshot;
	std::vector<std::uint8_t> last_confirmed_target_snapshot;

	double tick_accumulator = 0.0;
	// Task 8.10: this bridge's own advisory local tick counter (renamed from
	// the old `estimated_tick`, which conflated "my local clock" with "my
	// best guess at the authoritative tick" -- `ga::ServerTickEstimator`
	// keeps those separate: `local_tick_counter` is the former,
	// `tick_estimator.estimate(local_tick_counter)` is the latter).
	ga::Tick local_tick_counter = 0;
	ga::ServerTickEstimator tick_estimator;
};

} // namespace godot

VARIANT_ENUM_CAST(GameplayAbilityNetworkBridge::PredictionMode);

#endif // GAMEPLAY_ABILITIES_GODOT_ABILITY_NETWORK_BRIDGE_H
