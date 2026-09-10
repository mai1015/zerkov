#ifndef WEAPON_SYSTEM_GODOT_WEAPON_NETWORK_BRIDGE_H
#define WEAPON_SYSTEM_GODOT_WEAPON_NETWORK_BRIDGE_H

#include "core/wpn_runtime.h"
#include "core/wpn_status.h"
#include "protocol/wpn_command_gate.h"
#include "protocol/wpn_prediction.h"
#include "protocol/wpn_protocol_types.h"
#include "protocol/wpn_replica.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <map>
#include <memory>
#include <set>

// Tasks.md 7.5/7.6/7.7 (weapon-protocol spec: "Game-Owned Session and
// Transport" / "Authoritative Command Admission" / "Snapshot and Delta
// Convergence" / "Presentation-Only Client Prediction"). An OPTIONAL Node
// that attaches beneath a game-selected `MultiplayerAPI` branch (see
// design.md "Protocol and networking") and NEVER creates, replaces, or owns
// the game's `MultiplayerPeer`, connection, lobby, or authentication -- it
// only ever reads `Node::get_multiplayer()` (which resolves the branch-scoped
// API the game already configured), matching the sibling gameplay_abilities
// addon's `GameplayAbilityNetworkBridge`
// (native/godot/gameplay_ability_network_bridge.h) structural precedent one
// level down in scope: the weapon protocol has no per-audience visibility
// split, no ability-task/target-session concept, and no client-side
// speculative mutation -- so this bridge is deliberately simpler.
//
// Role is EXPLICIT (`set_role`), never inferred from `get_multiplayer()`'s
// own state ("Server and client roles explicit (no ambient inference)"):
//
//   ROLE_SERVER: gates every inbound command through protocol/
//     wpn_command_gate.h's WeaponCommandGate (owner/role/epoch/sequence/
//     rate/size) BEFORE routing it into a game-configured `WeaponAuthority`
//     node (native/godot/weapon_authority.h, resolved by
//     `weapon_authority_path`) -- this bridge never constructs or owns a
//     WeaponAuthority/WeaponRuntime itself. It creates the TRUSTED core
//     authority envelope (tick/authority_scope/authority_epoch) server-side;
//     commands decoded from the wire (protocol/wpn_protocol_types.h's
//     *Intent DTOs) never carry a trusted tick at all, by construction --
//     there is no field to read one from. Accepted mutations are replicated
//     (snapshot on first relevance, delta afterward, driven by
//     DeltaAcknowledgementTracker's per-peer baseline) to every peer
//     currently `authorize_instance()`-d for the affected instance.
//   ROLE_CLIENT: owns exactly one protocol::WeaponReplica (tracking
//     whatever instances this session is relevant to -- possibly several:
//     the owned weapon plus any observed ones) and one
//     protocol::PresentationPredictionTracker (tasks.md 7.6) for bounded,
//     reversible, intent-keyed presentation-only prediction. Structurally
//     cannot mutate canonical ammo/reload/hit/damage state: this role never
//     touches a WeaponAuthority/WeaponRuntime at all.
//
// There is deliberately no ROLE_OFFLINE_AUTHORITY: an offline/local game
// simply does not attach this node at all and drives a WeaponAuthority
// directly (weapon-protocol spec, "Game uses ENet": "the same canonical
// weapon command and state contracts are used" -- this bridge is optional
// plumbing on top of that shared contract, never a requirement to use it).
namespace godot {

class WeaponAuthority;

class WeaponNetworkBridge : public Node {
	GDCLASS(WeaponNetworkBridge, Node)

public:
	enum Role {
		ROLE_SERVER = 0,
		ROLE_CLIENT = 1,
	};

	WeaponNetworkBridge();
	~WeaponNetworkBridge() override;

	// -- Wiring -----------------------------------------------------------

	void set_role(Role p_role) { role = p_role; }
	Role get_role() const { return role; }

	// SERVER only: an already-configured `WeaponAuthority` node (role
	// SERVER_AUTHORITY, already `configure()`d) this bridge routes admitted
	// commands into. Resolved lazily, exactly like
	// GameplayAbilityNetworkBridge::component_path.
	void set_weapon_authority_path(const NodePath &p_path) { weapon_authority_path = p_path; }
	NodePath get_weapon_authority_path() const { return weapon_authority_path; }

	// CLIENT only: the peer id treated as "the server" for outbound RPCs.
	// Almost always 1 (Godot's convention for the authority/host peer).
	void set_server_peer_id(int p_peer_id) { server_peer_id = p_peer_id; }
	int get_server_peer_id() const { return server_peer_id; }

	void set_tick_rate(int p_tick_rate) { tick_rate = p_tick_rate > 0 ? p_tick_rate : int(wpn::DEFAULT_TICK_RATE); }
	int get_tick_rate() const { return tick_rate; }

	// SERVER only: the core authority-scope/epoch envelope this bridge
	// stamps on every admitted command it routes into WeaponAuthority --
	// MUST match whatever a game passed as `authority_scope`/
	// `authority_epoch` to `WeaponAuthority.create_weapon()` for the
	// instances this bridge serves (core/wpn_runtime.h's
	// AuthorityContext/*Command envelope fields are a DIFFERENT concept
	// from this bridge's own PeerId/SessionId/ConnectionEpoch protocol-layer
	// identity -- see the class comment). Defaults ("", 0) match
	// WeaponAuthority.create_weapon()'s own defaults, so a single-scope game
	// needs no extra configuration.
	void set_authority_scope(const String &p_scope) { authority_scope = p_scope; }
	String get_authority_scope() const { return authority_scope; }
	void set_authority_epoch(int64_t p_epoch) { authority_epoch = p_epoch; }
	int64_t get_authority_epoch() const { return authority_epoch; }

	// SERVER only, FIRE commands only: a game-provided hook building the
	// `AuthorityContext` Dictionary (WeaponAuthority.fire()'s own
	// `p_authority` shape: actor_live, weapon_equipped, weapon_usable,
	// authoritative_origin, authoritative_aim, and the four *_modifier_ppm
	// fields) an admitted fire command is evaluated against. Called as
	// `callable.call(context)` with a single Dictionary argument carrying
	// peer/session/instance_id/command_id/sequence/client_tick. UNSET means
	// every fire is evaluated with an all-false/neutral AuthorityContext
	// (WeaponAuthority.fire()'s own Dictionary defaults), which
	// WeaponRuntime::fire() deterministically rejects as ACTOR_NOT_LIVE --
	// a fail-closed default, never a silent "always allow". A game wanting
	// live weapon networking configures this.
	void set_authority_context_provider(const Callable &p_callback) { authority_context_provider = p_callback; }
	Callable get_authority_context_provider() const { return authority_context_provider; }

	// SERVER only, BEGIN_RELOAD commands only: BeginReloadIntent (protocol/
	// wpn_protocol_types.h) carries no ballistic-profile field at all (a
	// client cannot choose canonical ammunition identity -- weapon-protocol
	// spec, "A client MUST NOT directly select canonical attachment
	// mechanics or ammunition ballistic identity outside an
	// authority-accepted inventory/game command path"), so the exact
	// `BallisticProfileIdentity` a reload reservation carries is always
	// resolved server-side. Called as `callable.call(context)` with the
	// SAME Dictionary shape as authority_context_provider (minus the
	// authority-context fields), MUST return {id: String, version: int}.
	// UNSET (or a callback that returns nothing usable) submits an empty
	// profile identity, which WeaponRuntime::begin_reload() deterministically
	// rejects (e.g. PROFILE_UNKNOWN_REFERENCE) rather than resolving to a
	// meaningless default -- fail-closed, same posture as
	// authority_context_provider.
	void set_reload_profile_provider(const Callable &p_callback) { reload_profile_provider = p_callback; }
	Callable get_reload_profile_provider() const { return reload_profile_provider; }

	// -- Role / transport state --------------------------------------------

	bool is_multiplayer_active() const;

	// -- Server-side ownership (weapon-protocol spec, "Authoritative Command
	// Admission") -- the game (or a session harness/lobby step) calls these
	// explicitly once it has authenticated a peer and decided what it
	// controls; a client-declared instance id, role, or epoch in a packet
	// MUST NOT by itself grant admission (see protocol/wpn_command_gate.h's
	// WeaponOwnershipTable doc comment). --

	// Assigns a FRESH ConnectionEpoch every call, even for a reused
	// `p_session` (protocol/wpn_command_gate.h's ConnectionEpoch contract: a
	// physically new connection always supersedes an old one -- "Old epoch
	// sends after reconnect").
	void begin_session(int p_peer, int64_t p_session);
	void end_session(int p_peer);
	// p_role: 0 = OBSERVER (may only receive snapshots/deltas), 1 = OWNER
	// (may also submit mutating commands), matching
	// protocol::WeaponRole. Also registers p_peer as replication-relevant
	// for p_instance_id and immediately sends it a full snapshot/tombstone
	// batch if the instance currently exists ("first relevance").
	bool authorize_instance(int p_peer, const String &p_instance_id, int p_role);
	bool revoke_instance(int p_peer, const String &p_instance_id);
	void drop_peer(int p_peer);

	// SERVER only: replicates an authoritatively torn-down instance's
	// tombstone to every peer currently relevant for it. Teardown itself has
	// no client-submittable wire command (weapon-protocol spec: a client
	// cannot request its own removal over the network in v1) -- the game
	// calls `WeaponAuthority.teardown()` (or `remove_weapon()`, though that
	// leaves no tombstone to replicate) directly, then this, exactly like it
	// would call any other administrative WeaponAuthority method.
	void replicate_teardown(const String &p_instance_id);

	// SERVER only: periodic catch-up sweep -- call once per authoritative
	// tick (or at whatever cadence a game likes; NOT required for
	// correctness of the event-driven push every accepted command already
	// performs, only for resilience against a peer whose event-driven
	// update was lost with no LATER traffic to reveal the resulting gap).
	// For every relevant (peer, instance) pair whose acknowledged revision
	// still differs from the instance's current one, resends a
	// snapshot/delta exactly like the event-driven path would.
	void push_state(int64_t p_tick);

	// -- Client commands (owning client -> server intent) -------------------
	//
	// Role-checked (CLIENT only; returns {sent:false, reason:"wrong_role"}
	// otherwise) and network-checked (`is_multiplayer_active()`; returns
	// {sent:false, reason:"network_unavailable"} otherwise, WITHOUT
	// constructing or tracking anything -- "Client bridge has no active
	// peer"). On success returns {sent:true, command_id: String}. Each
	// records a bounded PresentationIntent (protocol/wpn_prediction.h) and
	// emits `presentation_predicted` immediately -- NEVER mutates this
	// bridge's own WeaponReplica (there is no path from these methods to
	// replica mutation at all), matching "presentation-only" by
	// construction, not merely by discipline.
	Dictionary request_fire_networked(const Dictionary &p_intent);
	Dictionary request_begin_reload_networked(const Dictionary &p_intent);
	Dictionary request_cancel_reload_networked(const Dictionary &p_intent);
	Dictionary request_configure_attachments_networked(const Dictionary &p_intent);

	// CLIENT only: requests a fresh full snapshot for p_instance_id (late
	// join, gap recovery, or an explicit user/game action). A no-op
	// (returns false) if not CLIENT role or the network is not active.
	bool request_resync(const String &p_instance_id);

	// CLIENT only: sends this bridge's local CompatibilityHandshake to
	// `server_peer_id` (weapon-protocol spec, "Versioned Canonical Weapon
	// Protocol": content-compatibility handshake). Called automatically,
	// exactly once per connection, from `_process()` once
	// `is_multiplayer_active()` first becomes true -- also callable directly
	// (e.g. to re-handshake after a game-side content change). The SERVER
	// side's `_rpc_compatibility_handshake` handler is the ONLY thing that
	// marks a peer's `WeaponOwnershipTable` compatibility readiness (the
	// "content compatibility" admission gate every command is checked
	// against); a peer that never handshakes can begin a session and be
	// authorize_instance()-d, but every command it submits is rejected
	// CONTENT_NOT_READY until this round-trips.
	void send_compatibility_handshake();

	// CLIENT only, read-only convenience: the replica's current confirmed
	// state for p_instance_id, or an empty Dictionary if untracked. A game's
	// presentation layer reads this to snap back to "the newest confirmed
	// weapon snapshot" on `presentation_reverted`/`presentation_diverged`.
	Dictionary confirmed_snapshot(const String &p_instance_id) const;
	bool is_instance_tombstoned(const String &p_instance_id) const;

	void _ready() override;
	void _process(double p_delta) override;

protected:
	static void _bind_methods();

private:
	// -- RPC entry points (configured via rpc_config in _ready()) ---------
	void _rpc_compatibility_handshake(const PackedByteArray &p_bytes);
	void _rpc_fire_intent(const PackedByteArray &p_bytes);
	void _rpc_begin_reload_intent(const PackedByteArray &p_bytes);
	void _rpc_cancel_reload_intent(const PackedByteArray &p_bytes);
	void _rpc_configure_attachments_intent(const PackedByteArray &p_bytes);
	void _rpc_acknowledgement_batch(const PackedByteArray &p_bytes);
	void _rpc_resync_request(const PackedByteArray &p_bytes);
	void _rpc_snapshot_batch(const PackedByteArray &p_bytes);
	void _rpc_delta_batch(const PackedByteArray &p_bytes);
	void _rpc_command_rejection(const PackedByteArray &p_bytes);

	WeaponAuthority *resolve_weapon_authority();
	std::uint32_t effective_tick_rate() const;

	void on_server_disconnected();

	// -- Server-side command handling helpers --------------------------------
	// Runs the shared admission preamble (session/owner/role/epoch/sequence/
	// payload-size/compatibility/rate -- protocol/wpn_command_gate.h's exact
	// documented order) for one already-decoded command's identity fields.
	// Returns true (and advances r_context/r_verdict) exactly when the
	// caller should proceed to submit the command to WeaponAuthority; false
	// covers BOTH a hard rejection (a bounded CommandRejection has already
	// been sent to the peer) and a DUPLICATE_REPLAY that this call already
	// fully handled (re-broadcast on an ok() replay, or a resent rejection
	// on a rejected one) -- either way the caller has nothing further to do.
	bool admit_command(int p_peer, const String &p_instance_id, const String &p_command_id, std::uint64_t p_sequence,
			const std::vector<std::uint8_t> &p_bytes, wpn::protocol::InboundCommandVerdict &r_verdict);
	void send_rejection(int p_peer, const String &p_command_id, const String &p_instance_id, const wpn::Status &p_status);
	// A decode failure has no reliable instance_id/command_id -- still
	// consumes the sender's rate budget and produces a bounded rejection
	// (empty identity fields) rather than silently dropping malformed
	// traffic (weapon-protocol spec, "Bounded Malformed Input Handling").
	void reject_malformed(int p_peer, const wpn::Status &p_status);
	// Broadcasts the CURRENT state of p_instance_id to every peer this
	// bridge has registered as relevant for it (authorize_instance()),
	// choosing snapshot-vs-delta per peer from DeltaAcknowledgementTracker.
	void broadcast_instance(const String &p_instance_id);
	void send_snapshot_to_peer(int p_peer, const String &p_instance_id);
	void send_delta_to_peer(int p_peer, const String &p_instance_id, std::uint64_t p_acked_revision);

	// -- Client-side application ------------------------------------------
	void apply_snapshot_batch_bytes(const PackedByteArray &p_bytes);
	void apply_delta_batch_bytes(const PackedByteArray &p_bytes);
	void apply_command_rejection_bytes(const PackedByteArray &p_bytes);
	// Feeds a fresh confirmed sequence for p_instance_id into the
	// presentation tracker (tasks.md 7.6), emitting presentation_confirmed
	// for every intent it resolves.
	void resolve_presentation_up_to(const String &p_instance_id, bool p_has_sequence, std::uint64_t p_sequence);
	// Divergence recovery (tasks.md 7.6: "on rejection/divergence restore
	// newest confirmed snapshot and discard/replay only bounded still-valid
	// presentation intents"). The replica itself needs no explicit restore
	// call -- it was never advanced by a prediction, so it is already
	// sitting at the newest confirmed snapshot; this only discards this
	// instance's now-unknowable pending presentation intents and (unless
	// p_already_requested) sends a resync.
	void handle_divergence(const String &p_instance_id, bool p_already_requested_resync);
	Dictionary send_predicted_command(wpn::protocol::PredictionIntentKind p_kind, const String &p_instance_id, const String &p_command_id,
			std::uint64_t p_sequence, const char *p_rpc_name, const PackedByteArray &p_encoded);

	Role role = ROLE_SERVER;
	NodePath weapon_authority_path;
	int server_peer_id = 1;
	int tick_rate = int(wpn::DEFAULT_TICK_RATE);
	String authority_scope;
	int64_t authority_epoch = 0;
	Callable authority_context_provider;
	Callable reload_profile_provider;

	WeaponAuthority *weapon_authority = nullptr;

	// -- Server-side protocol state -----------------------------------------
	std::unique_ptr<wpn::protocol::WeaponOwnershipTable> ownership;
	std::unique_ptr<wpn::protocol::CommandSequenceTracker> sequence_tracker;
	std::unique_ptr<wpn::protocol::RateLimiter> rate_limiter;
	std::unique_ptr<wpn::protocol::WeaponCommandGate> gate;
	std::unique_ptr<wpn::protocol::DeltaAcknowledgementTracker> acks;
	std::map<int32_t, std::uint64_t> peer_epochs; // PeerId -> current ConnectionEpoch.
	std::map<int32_t, std::uint64_t> peer_sessions; // PeerId -> current SessionId, as THIS bridge assigned it.
	std::uint64_t epoch_counter = 0;
	std::map<int32_t, std::set<String>> peer_instances; // PeerId -> replication-relevant instance ids.
	std::uint64_t local_tick_counter = 0;

	// -- Client-side protocol state ------------------------------------------
	std::unique_ptr<wpn::protocol::WeaponReplica> replica;
	std::unique_ptr<wpn::protocol::PresentationPredictionTracker> prediction;
	std::map<String, std::uint64_t> next_client_sequence; // instance_id -> next FireIntent/etc sequence to assign.
	std::uint64_t local_command_counter = 0;
	bool disconnect_signal_wired = false;
	double tick_accumulator = 0.0; // advisory local clock, presentation-intent age sweeping only.
	bool handshake_sent = false; // guards the auto-handshake-on-connect in _process().

	void ensure_server_state();
	void ensure_client_state();
};

} // namespace godot

VARIANT_ENUM_CAST(WeaponNetworkBridge::Role);

#endif // WEAPON_SYSTEM_GODOT_WEAPON_NETWORK_BRIDGE_H
