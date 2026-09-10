#include "godot/weapon_network_bridge.h"

#include "core/wpn_bytes.h"
#include "core/wpn_hash.h"
#include "core/wpn_limits.h"
#include "godot/weapon_authority.h"
#include "protocol/wpn_protocol_codec.h"

#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/classes/multiplayer_peer.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <utility>

// See the class comment (weapon_network_bridge.h) for the full role/scope
// contract this file implements. Structural notes specific to THIS file:
//
//   - Every *_networked client entry point and every _rpc_* server handler
//     is the ONLY place identity/sequence/tick values cross the untrusted
//     wire boundary; from there on, everything routes through
//     protocol/wpn_command_gate.h's WeaponCommandGate (server) or
//     protocol/wpn_replica.h's WeaponReplica (client) exactly like
//     addons/weapon_system's own in-process test harness
//     (native/tests/wpn_test_network_fakes.h) does -- this bridge is that
//     SAME composition, wired to a real MultiplayerAPI instead of a
//     FakeTransport.
//   - `fire_native()` (native/godot/weapon_authority.h) is the one core
//     entry point this bridge calls directly (C++-only, no Dictionary
//     round-trip) so an accepted fire's `CommittedShot` can ride the
//     replicated WeaponDelta's own `shot` field; begin_reload/cancel_reload/
//     configure_attachments have no comparable Dictionary-lossy payload, so
//     this bridge uses WeaponAuthority's existing Dictionary-shaped methods
//     for those.
namespace godot {

namespace {

std::string to_std(const String &p_value) {
	return p_value.utf8().get_data();
}

std::uint64_t nonnegative_u64(int64_t p_value) {
	return p_value < 0 ? 0 : std::uint64_t(p_value);
}

PackedByteArray to_packed(const std::vector<std::uint8_t> &p_bytes) {
	PackedByteArray out;
	out.resize(int64_t(p_bytes.size()));
	for (std::size_t i = 0; i < p_bytes.size(); ++i) {
		out.set(int64_t(i), p_bytes[i]);
	}
	return out;
}

std::vector<std::uint8_t> from_packed(const PackedByteArray &p_bytes) {
	std::vector<std::uint8_t> out;
	out.resize(std::size_t(p_bytes.size()));
	for (int64_t i = 0; i < p_bytes.size(); ++i) {
		out[std::size_t(i)] = std::uint8_t(p_bytes[i]);
	}
	return out;
}

wpn::FixedVec2 fixed_vec_from_dict(const Dictionary &p_value) {
	return {
		int64_t(p_value.get("x", int64_t(0))),
		int64_t(p_value.get("y", int64_t(0))),
	};
}

Dictionary status_dict(const wpn::Status &p_status) {
	Dictionary result;
	result["ok"] = p_status.ok();
	result["code"] = int(p_status.code);
	result["diagnostic"] = int(p_status.diagnostic);
	result["detail"] = int64_t(p_status.detail);
	return result;
}

const char *rpc_name_for(wpn::protocol::PredictionIntentKind p_kind) {
	switch (p_kind) {
		case wpn::protocol::PredictionIntentKind::FIRE:
			return "_rpc_fire_intent";
		case wpn::protocol::PredictionIntentKind::BEGIN_RELOAD:
			return "_rpc_begin_reload_intent";
		case wpn::protocol::PredictionIntentKind::CANCEL_RELOAD:
			return "_rpc_cancel_reload_intent";
		case wpn::protocol::PredictionIntentKind::CONFIGURE_ATTACHMENTS:
			return "_rpc_configure_attachments_intent";
	}
	return "_rpc_fire_intent";
}

} // namespace

WeaponNetworkBridge::WeaponNetworkBridge() {}
WeaponNetworkBridge::~WeaponNetworkBridge() {}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

void WeaponNetworkBridge::ensure_server_state() {
	if (ownership) {
		return;
	}
	ownership = std::make_unique<wpn::protocol::WeaponOwnershipTable>();
	sequence_tracker = std::make_unique<wpn::protocol::CommandSequenceTracker>();
	rate_limiter = std::make_unique<wpn::protocol::RateLimiter>();
	gate = std::make_unique<wpn::protocol::WeaponCommandGate>(*ownership, *sequence_tracker, *rate_limiter);
	acks = std::make_unique<wpn::protocol::DeltaAcknowledgementTracker>();
}

void WeaponNetworkBridge::ensure_client_state() {
	if (replica) {
		return;
	}
	replica = std::make_unique<wpn::protocol::WeaponReplica>();
	prediction = std::make_unique<wpn::protocol::PresentationPredictionTracker>();
}

bool WeaponNetworkBridge::is_multiplayer_active() const {
	const Ref<MultiplayerAPI> api = get_multiplayer();
	if (!api.is_valid()) {
		return false;
	}
	// Mirrors GameplayAbilityNetworkBridge::is_multiplayer_active()'s own
	// doc comment: Godot's SceneTree always exposes a default MultiplayerAPI
	// with an implicit local peer object, so a non-empty peer list is the
	// reliable "really connected" signal, not has_multiplayer_peer() alone.
	return api->has_multiplayer_peer() && !api->get_peers().is_empty();
}

WeaponAuthority *WeaponNetworkBridge::resolve_weapon_authority() {
	if (weapon_authority_path.is_empty()) {
		weapon_authority = nullptr;
		return nullptr;
	}
	weapon_authority = get_node<WeaponAuthority>(weapon_authority_path);
	return weapon_authority;
}

std::uint32_t WeaponNetworkBridge::effective_tick_rate() const {
	return std::uint32_t(tick_rate > 0 ? tick_rate : int(wpn::DEFAULT_TICK_RATE));
}

void WeaponNetworkBridge::_ready() {
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
	// happen INSIDE the handler, never via RPC mode alone -- "Node
	// multiplayer authority alone is not accepted as permission").
	rpc_config("_rpc_compatibility_handshake", any_peer_reliable);
	rpc_config("_rpc_fire_intent", any_peer_reliable);
	rpc_config("_rpc_begin_reload_intent", any_peer_reliable);
	rpc_config("_rpc_cancel_reload_intent", any_peer_reliable);
	rpc_config("_rpc_configure_attachments_intent", any_peer_reliable);
	rpc_config("_rpc_acknowledgement_batch", any_peer_reliable);
	rpc_config("_rpc_resync_request", any_peer_reliable);
	// Server -> client (defense-in-depth: only this node's designated
	// multiplayer authority may invoke these on a remote peer).
	rpc_config("_rpc_snapshot_batch", authority_reliable);
	rpc_config("_rpc_delta_batch", authority_reliable);
	rpc_config("_rpc_command_rejection", authority_reliable);

	if (role == ROLE_SERVER) {
		ensure_server_state();
		set_multiplayer_authority(1);
	} else {
		ensure_client_state();
		if (!disconnect_signal_wired) {
			const Ref<MultiplayerAPI> api = get_multiplayer();
			if (api.is_valid()) {
				api->connect("server_disconnected", callable_mp(this, &WeaponNetworkBridge::on_server_disconnected));
				disconnect_signal_wired = true;
			}
		}
	}
}

void WeaponNetworkBridge::_process(double p_delta) {
	if (role != ROLE_CLIENT) {
		return;
	}
	ensure_client_state();
	// Auto-handshake-on-connect (see send_compatibility_handshake()'s own
	// doc comment): without this, EVERY command this bridge ever sends
	// would be rejected CONTENT_NOT_READY forever, since nothing else
	// drives the content-compatibility admission gate.
	if (!handshake_sent && is_multiplayer_active()) {
		send_compatibility_handshake();
		handshake_sent = true;
	}
	const std::uint32_t rate = effective_tick_rate();
	if (rate == 0) {
		return;
	}
	tick_accumulator += p_delta * double(rate);
	bool advanced = false;
	while (tick_accumulator >= 1.0) {
		local_tick_counter += 1;
		tick_accumulator -= 1.0;
		advanced = true;
	}
	if (!advanced) {
		return;
	}
	for (const wpn::protocol::PredictionOutcome &outcome : prediction->sweep_expired(local_tick_counter)) {
		emit_signal("presentation_expired", String(outcome.intent.command_id.c_str()),
				String(outcome.intent.instance_id.c_str()), int(outcome.intent.kind));
	}
}

void WeaponNetworkBridge::on_server_disconnected() {
	// The replica's confirmed state is left exactly as-is (still the newest
	// snapshot the now-dead session ever confirmed) -- the next successful
	// reconnect's fresh snapshot/reconnect batch replaces it wholesale
	// (WeaponReplica::replace_from_snapshot_batch()'s own documented
	// reconnect contract), never a partial patch on top of stale state.
	// PresentationPredictionTracker has no blanket "clear everything" (it is
	// keyed per-instance, matching "discard ... only bounded still-valid
	// presentation intents" -- there is no session-wide operation in its own
	// contract): whatever this peer had pending naturally resolves via the
	// SAME divergence/confirm/expiry paths every other snapshot/delta
	// already drives once traffic resumes after reconnect, or ages out via
	// sweep_expired() (called every _process tick) if it never does.
	ensure_client_state();
}

// ---------------------------------------------------------------------------
// Server-side ownership
// ---------------------------------------------------------------------------

void WeaponNetworkBridge::begin_session(int p_peer, int64_t p_session) {
	ensure_server_state();
	const std::uint64_t epoch = ++epoch_counter;
	ownership->begin_session(wpn::protocol::PeerId(p_peer), wpn::protocol::SessionId(nonnegative_u64(p_session)), epoch);
	peer_epochs[p_peer] = epoch;
	peer_sessions[p_peer] = nonnegative_u64(p_session);
}

void WeaponNetworkBridge::end_session(int p_peer) {
	ensure_server_state();
	ownership->end_session(wpn::protocol::PeerId(p_peer));
}

bool WeaponNetworkBridge::authorize_instance(int p_peer, const String &p_instance_id, int p_role) {
	ensure_server_state();
	const wpn::protocol::WeaponRole role_value = p_role != 0 ? wpn::protocol::WeaponRole::OWNER : wpn::protocol::WeaponRole::OBSERVER;
	const wpn::Status status = ownership->authorize_instance(wpn::protocol::PeerId(p_peer), to_std(p_instance_id), role_value);
	if (!status.ok()) {
		return false;
	}
	peer_instances[p_peer].insert(p_instance_id);
	// First relevance: send this newly-authorized peer whatever the
	// instance's current state is right away, rather than waiting for the
	// next accepted mutation or push_state() sweep.
	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority != nullptr && authority->find_snapshot(to_std(p_instance_id)) != nullptr) {
		send_snapshot_to_peer(p_peer, p_instance_id);
	}
	return true;
}

bool WeaponNetworkBridge::revoke_instance(int p_peer, const String &p_instance_id) {
	ensure_server_state();
	const wpn::Status status = ownership->revoke_instance(wpn::protocol::PeerId(p_peer), to_std(p_instance_id));
	auto it = peer_instances.find(p_peer);
	if (it != peer_instances.end()) {
		it->second.erase(p_instance_id);
	}
	return status.ok();
}

void WeaponNetworkBridge::drop_peer(int p_peer) {
	ensure_server_state();
	ownership->drop_peer(wpn::protocol::PeerId(p_peer));
	rate_limiter->drop_peer(wpn::protocol::PeerId(p_peer));
	acks->drop_peer(wpn::protocol::PeerId(p_peer));
	peer_epochs.erase(p_peer);
	peer_sessions.erase(p_peer);
	peer_instances.erase(p_peer);
}

// ---------------------------------------------------------------------------
// Server-side admission + replication
// ---------------------------------------------------------------------------

bool WeaponNetworkBridge::admit_command(int p_peer, const String &p_instance_id, const String &p_command_id, std::uint64_t p_sequence,
		const std::vector<std::uint8_t> &p_bytes, wpn::protocol::InboundCommandVerdict &r_verdict) {
	ensure_server_state();
	wpn::protocol::InboundWeaponCommandContext context;
	context.peer = wpn::protocol::PeerId(p_peer);
	auto session_it = peer_sessions.find(p_peer);
	context.session = session_it == peer_sessions.end() ? wpn::protocol::INVALID_SESSION_ID : wpn::protocol::SessionId(session_it->second);
	auto epoch_it = peer_epochs.find(p_peer);
	context.epoch = epoch_it == peer_epochs.end() ? wpn::protocol::INVALID_CONNECTION_EPOCH : epoch_it->second;
	context.instance_id = to_std(p_instance_id);
	context.command_id = to_std(p_command_id);
	context.sequence = p_sequence;
	context.payload_hash = wpn::hash_bytes(p_bytes);
	context.payload_bytes = p_bytes.size();
	context.current_tick = local_tick_counter;
	context.tick_rate = effective_tick_rate();

	gate->admit(context, wpn::protocol::WeaponRole::OWNER, r_verdict);
	if (r_verdict.kind == wpn::protocol::CommandOutcomeKind::REJECTED) {
		send_rejection(p_peer, p_command_id, p_instance_id, r_verdict.status);
		return false;
	}
	if (r_verdict.kind == wpn::protocol::CommandOutcomeKind::DUPLICATE_REPLAY) {
		if (r_verdict.status.ok()) {
			broadcast_instance(p_instance_id);
		} else {
			send_rejection(p_peer, p_command_id, p_instance_id, r_verdict.status);
		}
		return false;
	}
	return true;
}

void WeaponNetworkBridge::send_rejection(int p_peer, const String &p_command_id, const String &p_instance_id, const wpn::Status &p_status) {
	wpn::protocol::CommandRejection rejection;
	rejection.command_id = to_std(p_command_id);
	rejection.instance_id = to_std(p_instance_id);
	rejection.status = p_status;
	WeaponAuthority *authority = resolve_weapon_authority();
	const wpn::WeaponSnapshot *snapshot = authority == nullptr ? nullptr : authority->find_snapshot(to_std(p_instance_id));
	rejection.current_revision = snapshot == nullptr ? 0 : snapshot->revision;
	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_command_rejection(rejection, writer).ok()) {
		return;
	}
	rpc_id(p_peer, "_rpc_command_rejection", to_packed(writer.bytes()));
	emit_signal("command_rejected", p_peer, p_command_id, p_instance_id, status_dict(p_status));
}

void WeaponNetworkBridge::reject_malformed(int p_peer, const wpn::Status &p_status) {
	ensure_server_state();
	// Repeated malformed traffic still consumes the sender's rate budget
	// (weapon-protocol spec: "Repeated malformed traffic exceeds rate
	// limit") so a flood of garbage eventually trips the same limiter a
	// flood of valid-but-over-rate commands would.
	const wpn::Status rate_status = rate_limiter->admit_command(wpn::protocol::PeerId(p_peer), local_tick_counter, effective_tick_rate());
	if (!rate_status.ok()) {
		emit_signal("network_diagnostic", p_peer, status_dict(rate_status));
	}
	send_rejection(p_peer, String(), String(), p_status);
}

void WeaponNetworkBridge::broadcast_instance(const String &p_instance_id) {
	ensure_server_state();
	auto it = peer_instances.begin();
	for (; it != peer_instances.end(); ++it) {
		if (it->second.find(p_instance_id) == it->second.end()) {
			continue;
		}
		const int peer = it->first;
		WeaponAuthority *authority = resolve_weapon_authority();
		const wpn::WeaponSnapshot *snapshot = authority == nullptr ? nullptr : authority->find_snapshot(to_std(p_instance_id));
		if (snapshot == nullptr) {
			continue;
		}
		const std::uint64_t acked = acks->acknowledged_revision(wpn::protocol::PeerId(peer), to_std(p_instance_id));
		if (acked == 0) {
			send_snapshot_to_peer(peer, p_instance_id);
		} else if (acked != snapshot->revision) {
			send_delta_to_peer(peer, p_instance_id, acked);
		}
		// acked == snapshot->revision: this peer is already caught up --
		// "idle authority ticks SHALL not create weapon-state deltas".
	}
}

void WeaponNetworkBridge::send_snapshot_to_peer(int p_peer, const String &p_instance_id) {
	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr) {
		return;
	}
	wpn::protocol::WeaponSnapshotBatch batch;
	const wpn::WeaponSnapshot *snapshot = authority->find_snapshot(to_std(p_instance_id));
	if (snapshot != nullptr) {
		batch.snapshots.push_back(*snapshot);
	} else {
		const wpn::WeaponTombstone *tombstone = authority->find_tombstone_value(to_std(p_instance_id));
		if (tombstone == nullptr) {
			return;
		}
		batch.tombstones.push_back(*tombstone);
	}
	wpn::ByteWriter writer(wpn::MAX_SNAPSHOT_BYTES);
	if (!wpn::protocol::encode_snapshot_batch(batch, writer).ok()) {
		return;
	}
	rpc_id(p_peer, "_rpc_snapshot_batch", to_packed(writer.bytes()));
}

void WeaponNetworkBridge::send_delta_to_peer(int p_peer, const String &p_instance_id, std::uint64_t p_acked_revision) {
	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr) {
		return;
	}
	const wpn::WeaponSnapshot *snapshot = authority->find_snapshot(to_std(p_instance_id));
	if (snapshot == nullptr) {
		return;
	}
	wpn::protocol::WeaponDeltaBatch batch;
	batch.authority_tick = local_tick_counter;
	wpn::protocol::WeaponDelta delta;
	delta.predecessor_revision = p_acked_revision;
	delta.successor_revision = snapshot->revision;
	delta.lifecycle = wpn::protocol::WeaponLifecycleState::ACTIVE;
	delta.snapshot = *snapshot;
	batch.deltas.push_back(delta);
	wpn::ByteWriter writer(wpn::MAX_DELTA_BYTES);
	if (!wpn::protocol::encode_delta_batch(batch, writer).ok()) {
		return;
	}
	rpc_id(p_peer, "_rpc_delta_batch", to_packed(writer.bytes()));
}

void WeaponNetworkBridge::replicate_teardown(const String &p_instance_id) {
	ensure_server_state();
	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr || authority->find_tombstone_value(to_std(p_instance_id)) == nullptr) {
		return;
	}
	const wpn::WeaponTombstone tombstone = *authority->find_tombstone_value(to_std(p_instance_id));
	for (const auto &[peer, instances] : peer_instances) {
		if (instances.find(p_instance_id) == instances.end()) {
			continue;
		}
		const std::uint64_t acked = acks->acknowledged_revision(wpn::protocol::PeerId(peer), to_std(p_instance_id));
		if (acked == 0) {
			send_snapshot_to_peer(peer, p_instance_id);
			continue;
		}
		wpn::protocol::WeaponDeltaBatch batch;
		batch.authority_tick = local_tick_counter;
		wpn::protocol::WeaponDelta delta;
		delta.predecessor_revision = acked;
		delta.successor_revision = tombstone.revision;
		delta.lifecycle = wpn::protocol::WeaponLifecycleState::TOMBSTONED;
		delta.tombstone = tombstone;
		batch.deltas.push_back(delta);
		wpn::ByteWriter writer(wpn::MAX_DELTA_BYTES);
		if (!wpn::protocol::encode_delta_batch(batch, writer).ok()) {
			continue;
		}
		rpc_id(peer, "_rpc_delta_batch", to_packed(writer.bytes()));
	}
}

void WeaponNetworkBridge::push_state(int64_t p_tick) {
	ensure_server_state();
	local_tick_counter = nonnegative_u64(p_tick);
	std::set<String> instances;
	for (const auto &[peer, ids] : peer_instances) {
		(void)peer;
		for (const String &id : ids) {
			instances.insert(id);
		}
	}
	for (const String &instance_id : instances) {
		broadcast_instance(instance_id);
	}
}

// ---------------------------------------------------------------------------
// Server RPC handlers
// ---------------------------------------------------------------------------

void WeaponNetworkBridge::_rpc_compatibility_handshake(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	// v1 simplification (mirrors gameplay_abilities' own handshake posture):
	// this bridge does not itself validate content-compatibility fields --
	// a game wanting a real handshake round-trip does so at a higher layer
	// (e.g. protocol/wpn_protocol_compat.h's check_handshake_compatibility(),
	// driven by a game-owned session step) and then simply calls
	// mark_compatibility_ready via begin_session()'s own bookkeeping. This
	// handler exists so an "any peer" RPC surface for a future stricter
	// handshake is already wired without a breaking wire-shape change later.
	(void)p_bytes;
	ownership->mark_compatibility_ready(wpn::protocol::PeerId(peer));
}

void WeaponNetworkBridge::_rpc_fire_intent(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);

	wpn::protocol::FireIntent intent;
	wpn::ByteReader reader(bytes);
	const wpn::Status decode_status = wpn::protocol::decode_fire_intent(reader, intent);
	if (!decode_status.ok()) {
		reject_malformed(peer, decode_status);
		return;
	}
	const String instance_id = String(intent.instance_id.c_str());
	const String command_id = String(intent.command_id.c_str());
	wpn::protocol::InboundCommandVerdict verdict;
	if (!admit_command(peer, instance_id, command_id, intent.sequence, bytes, verdict)) {
		return;
	}

	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr) {
		const wpn::Status status = wpn::make_status(wpn::StatusCode::INTERNAL_ERROR);
		sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes), status);
		send_rejection(peer, command_id, instance_id, status);
		return;
	}

	wpn::FireCommand command;
	command.command_id = intent.command_id;
	command.sequence = intent.sequence;
	command.instance_id = intent.instance_id;
	command.expected_revision = intent.expected_revision;
	command.tick = local_tick_counter; // trusted server tick -- NEVER the wire.
	command.authority_scope = to_std(authority_scope);
	command.authority_epoch = nonnegative_u64(authority_epoch);
	command.claimed_origin = intent.claimed_origin;
	command.claimed_aim = intent.claimed_aim;
	command.spread_seed = intent.spread_seed;

	wpn::AuthorityContext context; // all-false/neutral by default: fails closed with no provider configured.
	if (authority_context_provider.is_valid()) {
		Dictionary call_context;
		call_context["peer"] = peer;
		call_context["session"] = int64_t(peer_sessions.count(peer) ? peer_sessions[peer] : 0);
		call_context["instance_id"] = instance_id;
		call_context["command_id"] = command_id;
		call_context["sequence"] = int64_t(intent.sequence);
		const Variant returned = authority_context_provider.call(call_context);
		if (returned.get_type() == Variant::DICTIONARY) {
			const Dictionary value = returned;
			context.actor_live = bool(value.get("actor_live", false));
			context.weapon_equipped = bool(value.get("weapon_equipped", false));
			context.weapon_usable = bool(value.get("weapon_usable", false));
			context.authoritative_origin = fixed_vec_from_dict(value.get("authoritative_origin", Dictionary()));
			context.authoritative_aim = fixed_vec_from_dict(value.get("authoritative_aim", Dictionary()));
			context.spread_modifier_ppm = int64_t(value.get("spread_modifier_ppm", int64_t(1000000)));
			context.damage_modifier_ppm = int64_t(value.get("damage_modifier_ppm", int64_t(1000000)));
			context.range_modifier_ppm = int64_t(value.get("range_modifier_ppm", int64_t(1000000)));
			context.noise_modifier_ppm = int64_t(value.get("noise_modifier_ppm", int64_t(1000000)));
		}
	}

	const wpn::CommandOutcome outcome = authority->fire_native(command, context);
	sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes),
			outcome.accepted ? wpn::ok_status() : outcome.status);
	if (!outcome.accepted) {
		send_rejection(peer, command_id, instance_id, outcome.status);
		return;
	}
	broadcast_instance(instance_id);
}

void WeaponNetworkBridge::_rpc_begin_reload_intent(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);

	wpn::protocol::BeginReloadIntent intent;
	wpn::ByteReader reader(bytes);
	const wpn::Status decode_status = wpn::protocol::decode_begin_reload_intent(reader, intent);
	if (!decode_status.ok()) {
		reject_malformed(peer, decode_status);
		return;
	}
	const String instance_id = String(intent.instance_id.c_str());
	const String command_id = String(intent.command_id.c_str());
	wpn::protocol::InboundCommandVerdict verdict;
	if (!admit_command(peer, instance_id, command_id, intent.sequence, bytes, verdict)) {
		return;
	}

	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr) {
		const wpn::Status status = wpn::make_status(wpn::StatusCode::INTERNAL_ERROR);
		sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes), status);
		send_rejection(peer, command_id, instance_id, status);
		return;
	}

	Dictionary profile_dict;
	if (reload_profile_provider.is_valid()) {
		Dictionary call_context;
		call_context["peer"] = peer;
		call_context["session"] = int64_t(peer_sessions.count(peer) ? peer_sessions[peer] : 0);
		call_context["instance_id"] = instance_id;
		call_context["command_id"] = command_id;
		call_context["sequence"] = int64_t(intent.sequence);
		call_context["reservation_id"] = String(intent.reservation_id.c_str());
		call_context["reserved_rounds"] = int(intent.reserved_rounds);
		const Variant returned = reload_profile_provider.call(call_context);
		if (returned.get_type() == Variant::DICTIONARY) {
			profile_dict = returned;
		}
	}

	Dictionary command_dict;
	command_dict["command_id"] = command_id;
	command_dict["sequence"] = int64_t(intent.sequence);
	command_dict["instance_id"] = instance_id;
	command_dict["expected_revision"] = int64_t(intent.expected_revision);
	command_dict["tick"] = int64_t(local_tick_counter);
	command_dict["authority_scope"] = authority_scope;
	command_dict["authority_epoch"] = authority_epoch;
	command_dict["reservation_id"] = String(intent.reservation_id.c_str());
	command_dict["reserved_rounds"] = int(intent.reserved_rounds);
	command_dict["profile"] = profile_dict;

	const Dictionary result = authority->begin_reload(command_dict);
	const bool accepted = bool(result.get("accepted", false));
	const Dictionary status_value = result.get("status", Dictionary());
	const wpn::Status status = wpn::make_status(
			wpn::StatusCode(int(status_value.get("code", 0))),
			wpn::DiagnosticId(int(status_value.get("diagnostic", 0))),
			std::uint64_t(int64_t(status_value.get("detail", int64_t(0)))));
	sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes),
			accepted ? wpn::ok_status() : status);
	if (!accepted) {
		send_rejection(peer, command_id, instance_id, status);
		return;
	}
	broadcast_instance(instance_id);
}

void WeaponNetworkBridge::_rpc_cancel_reload_intent(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);

	wpn::protocol::CancelReloadIntent intent;
	wpn::ByteReader reader(bytes);
	const wpn::Status decode_status = wpn::protocol::decode_cancel_reload_intent(reader, intent);
	if (!decode_status.ok()) {
		reject_malformed(peer, decode_status);
		return;
	}
	const String instance_id = String(intent.instance_id.c_str());
	const String command_id = String(intent.command_id.c_str());
	wpn::protocol::InboundCommandVerdict verdict;
	if (!admit_command(peer, instance_id, command_id, intent.sequence, bytes, verdict)) {
		return;
	}

	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr) {
		const wpn::Status status = wpn::make_status(wpn::StatusCode::INTERNAL_ERROR);
		sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes), status);
		send_rejection(peer, command_id, instance_id, status);
		return;
	}

	Dictionary command_dict;
	command_dict["command_id"] = command_id;
	command_dict["sequence"] = int64_t(intent.sequence);
	command_dict["instance_id"] = instance_id;
	command_dict["expected_revision"] = int64_t(intent.expected_revision);
	command_dict["tick"] = int64_t(local_tick_counter);
	command_dict["authority_scope"] = authority_scope;
	command_dict["authority_epoch"] = authority_epoch;

	const Dictionary result = authority->cancel_reload(command_dict);
	const bool accepted = bool(result.get("accepted", false));
	const Dictionary status_value = result.get("status", Dictionary());
	const wpn::Status status = wpn::make_status(
			wpn::StatusCode(int(status_value.get("code", 0))),
			wpn::DiagnosticId(int(status_value.get("diagnostic", 0))),
			std::uint64_t(int64_t(status_value.get("detail", int64_t(0)))));
	sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes),
			accepted ? wpn::ok_status() : status);
	if (!accepted) {
		send_rejection(peer, command_id, instance_id, status);
		return;
	}
	broadcast_instance(instance_id);
}

void WeaponNetworkBridge::_rpc_configure_attachments_intent(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);

	wpn::protocol::ConfigureAttachmentsIntent intent;
	wpn::ByteReader reader(bytes);
	const wpn::Status decode_status = wpn::protocol::decode_configure_attachments_intent(reader, intent);
	if (!decode_status.ok()) {
		reject_malformed(peer, decode_status);
		return;
	}
	const String instance_id = String(intent.instance_id.c_str());
	const String command_id = String(intent.command_id.c_str());
	wpn::protocol::InboundCommandVerdict verdict;
	if (!admit_command(peer, instance_id, command_id, intent.sequence, bytes, verdict)) {
		return;
	}

	WeaponAuthority *authority = resolve_weapon_authority();
	if (authority == nullptr) {
		const wpn::Status status = wpn::make_status(wpn::StatusCode::INTERNAL_ERROR);
		sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes), status);
		send_rejection(peer, command_id, instance_id, status);
		return;
	}

	Array desired_loadout;
	for (const wpn::AttachmentLoadoutEntry &entry : intent.desired_loadout) {
		Dictionary entry_dict;
		entry_dict["slot_id"] = String(entry.slot_id.c_str());
		entry_dict["attachment_id"] = String(entry.attachment_id.c_str());
		entry_dict["attachment_version"] = int(entry.attachment_version);
		desired_loadout.append(entry_dict);
	}

	Dictionary command_dict;
	command_dict["command_id"] = command_id;
	command_dict["sequence"] = int64_t(intent.sequence);
	command_dict["instance_id"] = instance_id;
	command_dict["expected_revision"] = int64_t(intent.expected_revision);
	command_dict["tick"] = int64_t(local_tick_counter);
	command_dict["authority_scope"] = authority_scope;
	command_dict["authority_epoch"] = authority_epoch;
	command_dict["desired_loadout"] = desired_loadout;

	const Dictionary result = authority->configure_attachments(command_dict);
	const bool accepted = bool(result.get("accepted", false));
	const Dictionary status_value = result.get("status", Dictionary());
	const wpn::Status status = wpn::make_status(
			wpn::StatusCode(int(status_value.get("code", 0))),
			wpn::DiagnosticId(int(status_value.get("diagnostic", 0))),
			std::uint64_t(int64_t(status_value.get("detail", int64_t(0)))));
	sequence_tracker->record(intent.instance_id, intent.command_id, intent.sequence, wpn::hash_bytes(bytes),
			accepted ? wpn::ok_status() : status);
	if (!accepted) {
		send_rejection(peer, command_id, instance_id, status);
		return;
	}
	broadcast_instance(instance_id);
}

void WeaponNetworkBridge::_rpc_acknowledgement_batch(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;
	wpn::protocol::AcknowledgementBatch batch;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	wpn::ByteReader reader(bytes);
	if (!wpn::protocol::decode_acknowledgement_batch(reader, batch).ok()) {
		return;
	}
	for (const wpn::protocol::DeltaAcknowledgement &ack : batch.acknowledgements) {
		acks->record_acknowledgement(wpn::protocol::PeerId(peer), ack.instance_id, ack.acknowledged_revision);
	}
}

void WeaponNetworkBridge::_rpc_resync_request(const PackedByteArray &p_bytes) {
	if (role != ROLE_SERVER) {
		return;
	}
	ensure_server_state();
	const Ref<MultiplayerAPI> api = get_multiplayer();
	const int peer = api.is_valid() ? api->get_remote_sender_id() : 0;

	const wpn::Status rate_status = rate_limiter->admit_resync(wpn::protocol::PeerId(peer), local_tick_counter, effective_tick_rate());
	if (!rate_status.ok()) {
		emit_signal("network_diagnostic", peer, status_dict(rate_status));
		return;
	}

	wpn::protocol::ResyncRequest request;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	wpn::ByteReader reader(bytes);
	if (!wpn::protocol::decode_resync_request(reader, request).ok()) {
		return;
	}
	send_snapshot_to_peer(peer, String(request.instance_id.c_str()));
}

// ---------------------------------------------------------------------------
// Client commands
// ---------------------------------------------------------------------------

Dictionary WeaponNetworkBridge::send_predicted_command(wpn::protocol::PredictionIntentKind p_kind, const String &p_instance_id,
		const String &p_command_id, std::uint64_t p_sequence, const char *p_rpc_name, const PackedByteArray &p_encoded) {
	rpc_id(server_peer_id, p_rpc_name, p_encoded);

	wpn::protocol::PresentationIntent intent;
	intent.command_id = to_std(p_command_id);
	intent.instance_id = to_std(p_instance_id);
	intent.kind = p_kind;
	intent.sequence = p_sequence;
	intent.sent_tick = local_tick_counter;
	std::optional<wpn::protocol::PredictionOutcome> evicted;
	prediction->track(intent, evicted);
	if (evicted.has_value()) {
		emit_signal("presentation_expired", String(evicted->intent.command_id.c_str()),
				String(evicted->intent.instance_id.c_str()), int(evicted->intent.kind));
	}
	emit_signal("presentation_predicted", p_command_id, p_instance_id, int(p_kind));

	Dictionary result;
	result["sent"] = true;
	result["command_id"] = p_command_id;
	return result;
}

Dictionary WeaponNetworkBridge::request_fire_networked(const Dictionary &p_intent) {
	Dictionary result;
	if (role != ROLE_CLIENT) {
		result["sent"] = false;
		result["reason"] = "wrong_role";
		return result;
	}
	if (!is_multiplayer_active()) {
		result["sent"] = false;
		result["reason"] = "network_unavailable";
		return result;
	}
	ensure_client_state();
	const String instance_id = String(p_intent.get("instance_id", String()));
	wpn::protocol::FireIntent intent;
	intent.command_id = to_std("c" + String::num_int64(int64_t(++local_command_counter)));
	intent.sequence = ++next_client_sequence[instance_id];
	intent.instance_id = to_std(instance_id);
	intent.expected_revision = nonnegative_u64(int64_t(p_intent.get("expected_revision", int64_t(0))));
	intent.claimed_origin = fixed_vec_from_dict(p_intent.get("claimed_origin", Dictionary()));
	intent.claimed_aim = fixed_vec_from_dict(p_intent.get("claimed_aim", Dictionary()));
	intent.spread_seed = nonnegative_u64(int64_t(p_intent.get("spread_seed", int64_t(0))));

	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_fire_intent(intent, writer).ok()) {
		result["sent"] = false;
		result["reason"] = "encode_failed";
		return result;
	}
	return send_predicted_command(wpn::protocol::PredictionIntentKind::FIRE, instance_id, String(intent.command_id.c_str()),
			intent.sequence, "_rpc_fire_intent", to_packed(writer.bytes()));
}

Dictionary WeaponNetworkBridge::request_begin_reload_networked(const Dictionary &p_intent) {
	Dictionary result;
	if (role != ROLE_CLIENT) {
		result["sent"] = false;
		result["reason"] = "wrong_role";
		return result;
	}
	if (!is_multiplayer_active()) {
		result["sent"] = false;
		result["reason"] = "network_unavailable";
		return result;
	}
	ensure_client_state();
	const String instance_id = String(p_intent.get("instance_id", String()));
	wpn::protocol::BeginReloadIntent intent;
	intent.command_id = to_std("c" + String::num_int64(int64_t(++local_command_counter)));
	intent.sequence = ++next_client_sequence[instance_id];
	intent.instance_id = to_std(instance_id);
	intent.expected_revision = nonnegative_u64(int64_t(p_intent.get("expected_revision", int64_t(0))));
	intent.reservation_id = to_std(String(p_intent.get("reservation_id", String())));
	intent.reserved_rounds = std::uint32_t(nonnegative_u64(int64_t(p_intent.get("reserved_rounds", int64_t(0)))));

	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_begin_reload_intent(intent, writer).ok()) {
		result["sent"] = false;
		result["reason"] = "encode_failed";
		return result;
	}
	return send_predicted_command(wpn::protocol::PredictionIntentKind::BEGIN_RELOAD, instance_id, String(intent.command_id.c_str()),
			intent.sequence, "_rpc_begin_reload_intent", to_packed(writer.bytes()));
}

Dictionary WeaponNetworkBridge::request_cancel_reload_networked(const Dictionary &p_intent) {
	Dictionary result;
	if (role != ROLE_CLIENT) {
		result["sent"] = false;
		result["reason"] = "wrong_role";
		return result;
	}
	if (!is_multiplayer_active()) {
		result["sent"] = false;
		result["reason"] = "network_unavailable";
		return result;
	}
	ensure_client_state();
	const String instance_id = String(p_intent.get("instance_id", String()));
	wpn::protocol::CancelReloadIntent intent;
	intent.command_id = to_std("c" + String::num_int64(int64_t(++local_command_counter)));
	intent.sequence = ++next_client_sequence[instance_id];
	intent.instance_id = to_std(instance_id);
	intent.expected_revision = nonnegative_u64(int64_t(p_intent.get("expected_revision", int64_t(0))));

	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_cancel_reload_intent(intent, writer).ok()) {
		result["sent"] = false;
		result["reason"] = "encode_failed";
		return result;
	}
	return send_predicted_command(wpn::protocol::PredictionIntentKind::CANCEL_RELOAD, instance_id, String(intent.command_id.c_str()),
			intent.sequence, "_rpc_cancel_reload_intent", to_packed(writer.bytes()));
}

Dictionary WeaponNetworkBridge::request_configure_attachments_networked(const Dictionary &p_intent) {
	Dictionary result;
	if (role != ROLE_CLIENT) {
		result["sent"] = false;
		result["reason"] = "wrong_role";
		return result;
	}
	if (!is_multiplayer_active()) {
		result["sent"] = false;
		result["reason"] = "network_unavailable";
		return result;
	}
	ensure_client_state();
	const String instance_id = String(p_intent.get("instance_id", String()));
	wpn::protocol::ConfigureAttachmentsIntent intent;
	intent.command_id = to_std("c" + String::num_int64(int64_t(++local_command_counter)));
	intent.sequence = ++next_client_sequence[instance_id];
	intent.instance_id = to_std(instance_id);
	intent.expected_revision = nonnegative_u64(int64_t(p_intent.get("expected_revision", int64_t(0))));
	const Array desired_loadout = p_intent.get("desired_loadout", Array());
	intent.desired_loadout.reserve(std::size_t(desired_loadout.size()));
	for (int i = 0; i < desired_loadout.size(); ++i) {
		const Dictionary entry_value = desired_loadout[i];
		wpn::AttachmentLoadoutEntry entry;
		entry.slot_id = to_std(String(entry_value.get("slot_id", String())));
		entry.attachment_id = to_std(String(entry_value.get("attachment_id", String())));
		entry.attachment_version = std::uint16_t(int(entry_value.get("attachment_version", 1)));
		intent.desired_loadout.push_back(entry);
	}

	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_configure_attachments_intent(intent, writer).ok()) {
		result["sent"] = false;
		result["reason"] = "encode_failed";
		return result;
	}
	return send_predicted_command(wpn::protocol::PredictionIntentKind::CONFIGURE_ATTACHMENTS, instance_id, String(intent.command_id.c_str()),
			intent.sequence, "_rpc_configure_attachments_intent", to_packed(writer.bytes()));
}

bool WeaponNetworkBridge::request_resync(const String &p_instance_id) {
	if (role != ROLE_CLIENT || !is_multiplayer_active()) {
		return false;
	}
	ensure_client_state();
	wpn::protocol::ResyncRequest request = replica->make_resync_request(to_std(p_instance_id));
	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_resync_request(request, writer).ok()) {
		return false;
	}
	rpc_id(server_peer_id, "_rpc_resync_request", to_packed(writer.bytes()));
	return true;
}

void WeaponNetworkBridge::send_compatibility_handshake() {
	if (role != ROLE_CLIENT) {
		return;
	}
	wpn::protocol::CompatibilityHandshake handshake; // default protocol_version + default manifest; see the header's doc comment.
	wpn::ByteWriter writer(wpn::MAX_COMMAND_BYTES);
	if (!wpn::protocol::encode_compatibility_handshake(handshake, writer).ok()) {
		return;
	}
	rpc_id(server_peer_id, "_rpc_compatibility_handshake", to_packed(writer.bytes()));
}

Dictionary WeaponNetworkBridge::confirmed_snapshot(const String &p_instance_id) const {
	if (!replica) {
		return Dictionary();
	}
	const wpn::WeaponSnapshot *snapshot = replica->find(to_std(p_instance_id));
	if (snapshot == nullptr) {
		return Dictionary();
	}
	Dictionary result;
	result["instance_id"] = String(snapshot->instance_id.c_str());
	result["revision"] = int64_t(snapshot->revision);
	result["loaded_rounds"] = int(snapshot->loaded_rounds);
	result["phase"] = snapshot->phase == wpn::WeaponPhase::READY ? "ready" : "reloading";
	result["recoil_vertical_offset_nrad"] = int64_t(snapshot->recoil_vertical_offset_nrad);
	result["recoil_horizontal_offset_nrad"] = int64_t(snapshot->recoil_horizontal_offset_nrad);
	result["recoil_anchor_tick"] = int64_t(snapshot->recoil_anchor_tick);
	return result;
}

bool WeaponNetworkBridge::is_instance_tombstoned(const String &p_instance_id) const {
	return replica && replica->is_tombstoned(to_std(p_instance_id));
}

// ---------------------------------------------------------------------------
// Client RPC handlers
// ---------------------------------------------------------------------------

void WeaponNetworkBridge::_rpc_snapshot_batch(const PackedByteArray &p_bytes) {
	if (role != ROLE_CLIENT) {
		return;
	}
	ensure_client_state();
	wpn::protocol::WeaponSnapshotBatch batch;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	wpn::ByteReader reader(bytes);
	if (!wpn::protocol::decode_snapshot_batch(reader, batch).ok()) {
		return;
	}
	replica->apply_snapshot_batch(batch);
	// apply_snapshot_batch() stops at the FIRST failing entry (entries
	// applied before that remain applied) -- guard each signal below on
	// last_applied_revision() actually matching THIS entry's revision
	// rather than assuming every entry in the batch succeeded.
	for (const wpn::WeaponSnapshot &snapshot : batch.snapshots) {
		const String instance_id = String(snapshot.instance_id.c_str());
		if (replica->last_applied_revision(snapshot.instance_id) != snapshot.revision || replica->is_tombstoned(snapshot.instance_id)) {
			continue;
		}
		emit_signal("snapshot_applied", instance_id, int64_t(snapshot.revision));
		resolve_presentation_up_to(instance_id, snapshot.has_last_command_sequence, snapshot.last_command_sequence);
	}
	for (const wpn::WeaponTombstone &tombstone : batch.tombstones) {
		const String instance_id = String(tombstone.instance_id.c_str());
		if (!replica->is_tombstoned(tombstone.instance_id) || replica->last_applied_revision(tombstone.instance_id) != tombstone.revision) {
			continue;
		}
		emit_signal("instance_tombstoned", instance_id, int64_t(tombstone.revision));
		handle_divergence(instance_id, true); // a snapshot/tombstone just resolved this instance; nothing further to resync.
	}
}

void WeaponNetworkBridge::_rpc_delta_batch(const PackedByteArray &p_bytes) {
	if (role != ROLE_CLIENT) {
		return;
	}
	ensure_client_state();
	wpn::protocol::WeaponDeltaBatch batch;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	wpn::ByteReader reader(bytes);
	if (!wpn::protocol::decode_delta_batch(reader, batch).ok()) {
		return;
	}
	for (const wpn::protocol::WeaponDelta &delta : batch.deltas) {
		const wpn::Status status = replica->apply_delta(delta);
		if (delta.lifecycle == wpn::protocol::WeaponLifecycleState::TOMBSTONED) {
			const String instance_id = delta.tombstone.has_value() ? String(delta.tombstone->instance_id.c_str()) : String();
			if (status.ok()) {
				emit_signal("instance_tombstoned", instance_id, int64_t(delta.successor_revision));
				handle_divergence(instance_id, true);
			} else if (replica->needs_resync(to_std(instance_id))) {
				handle_divergence(instance_id, false);
			}
			continue;
		}
		const String instance_id = String(delta.snapshot.instance_id.c_str());
		if (status.ok()) {
			emit_signal("delta_applied", instance_id, int64_t(delta.successor_revision));
			resolve_presentation_up_to(instance_id, delta.snapshot.has_last_command_sequence, delta.snapshot.last_command_sequence);
		} else if (replica->needs_resync(to_std(instance_id))) {
			handle_divergence(instance_id, false);
		}
	}
	// Report convergence back to the authority so its DeltaAcknowledgementTracker-driven
	// predecessor bookkeeping advances (weapon-protocol spec, "baseline
	// acknowledgement").
	if (!batch.deltas.empty() && is_multiplayer_active()) {
		wpn::protocol::AcknowledgementBatch ack_batch;
		std::set<std::string> seen;
		for (const wpn::protocol::WeaponDelta &delta : batch.deltas) {
			const std::string instance_id = delta.lifecycle == wpn::protocol::WeaponLifecycleState::TOMBSTONED && delta.tombstone.has_value() ?
					delta.tombstone->instance_id :
					delta.snapshot.instance_id;
			if (instance_id.empty() || !seen.insert(instance_id).second) {
				continue;
			}
			wpn::protocol::DeltaAcknowledgement ack;
			ack.instance_id = instance_id;
			ack.acknowledged_revision = replica->last_applied_revision(instance_id);
			ack_batch.acknowledgements.push_back(ack);
		}
		if (!ack_batch.acknowledgements.empty()) {
			wpn::ByteWriter writer(wpn::MAX_DELTA_BYTES);
			if (wpn::protocol::encode_acknowledgement_batch(ack_batch, writer).ok()) {
				rpc_id(server_peer_id, "_rpc_acknowledgement_batch", to_packed(writer.bytes()));
			}
		}
	}
}

void WeaponNetworkBridge::_rpc_command_rejection(const PackedByteArray &p_bytes) {
	if (role != ROLE_CLIENT) {
		return;
	}
	ensure_client_state();
	wpn::protocol::CommandRejection rejection;
	const std::vector<std::uint8_t> bytes = from_packed(p_bytes);
	wpn::ByteReader reader(bytes);
	if (!wpn::protocol::decode_command_rejection(reader, rejection).ok()) {
		return;
	}
	const std::optional<wpn::protocol::PredictionOutcome> outcome = prediction->reject(rejection.command_id);
	const String instance_id = String(rejection.instance_id.c_str());
	const String command_id = String(rejection.command_id.c_str());
	// "restores the newest confirmed weapon snapshot": this bridge's
	// WeaponReplica was never advanced by a prediction (see the class
	// comment), so it is already sitting there -- nothing to restore.
	emit_signal("presentation_reverted", command_id, instance_id,
			outcome.has_value() ? int(outcome->intent.kind) : -1, status_dict(rejection.status), confirmed_snapshot(instance_id));
}

// ---------------------------------------------------------------------------
// Presentation-only prediction (tasks.md 7.6)
// ---------------------------------------------------------------------------

void WeaponNetworkBridge::resolve_presentation_up_to(const String &p_instance_id, bool p_has_sequence, std::uint64_t p_sequence) {
	if (!p_has_sequence) {
		return;
	}
	for (const wpn::protocol::PredictionOutcome &outcome : prediction->confirm_up_to(to_std(p_instance_id), p_sequence)) {
		emit_signal("presentation_confirmed", String(outcome.intent.command_id.c_str()), p_instance_id, int(outcome.intent.kind));
	}
}

void WeaponNetworkBridge::handle_divergence(const String &p_instance_id, bool p_already_requested_resync) {
	for (const wpn::protocol::PredictionOutcome &outcome : prediction->diverge_instance(to_std(p_instance_id))) {
		emit_signal("presentation_diverged", String(outcome.intent.command_id.c_str()), p_instance_id, int(outcome.intent.kind));
	}
	if (!p_already_requested_resync) {
		emit_signal("resync_needed", p_instance_id);
		request_resync(p_instance_id);
	}
}

// ---------------------------------------------------------------------------
// _bind_methods
// ---------------------------------------------------------------------------

void WeaponNetworkBridge::_bind_methods() {
	BIND_ENUM_CONSTANT(ROLE_SERVER);
	BIND_ENUM_CONSTANT(ROLE_CLIENT);

	ClassDB::bind_method(D_METHOD("set_role", "role"), &WeaponNetworkBridge::set_role);
	ClassDB::bind_method(D_METHOD("get_role"), &WeaponNetworkBridge::get_role);
	ClassDB::bind_method(D_METHOD("set_weapon_authority_path", "path"), &WeaponNetworkBridge::set_weapon_authority_path);
	ClassDB::bind_method(D_METHOD("get_weapon_authority_path"), &WeaponNetworkBridge::get_weapon_authority_path);
	ClassDB::bind_method(D_METHOD("set_server_peer_id", "peer_id"), &WeaponNetworkBridge::set_server_peer_id);
	ClassDB::bind_method(D_METHOD("get_server_peer_id"), &WeaponNetworkBridge::get_server_peer_id);
	ClassDB::bind_method(D_METHOD("set_tick_rate", "tick_rate"), &WeaponNetworkBridge::set_tick_rate);
	ClassDB::bind_method(D_METHOD("get_tick_rate"), &WeaponNetworkBridge::get_tick_rate);
	ClassDB::bind_method(D_METHOD("set_authority_scope", "scope"), &WeaponNetworkBridge::set_authority_scope);
	ClassDB::bind_method(D_METHOD("get_authority_scope"), &WeaponNetworkBridge::get_authority_scope);
	ClassDB::bind_method(D_METHOD("set_authority_epoch", "epoch"), &WeaponNetworkBridge::set_authority_epoch);
	ClassDB::bind_method(D_METHOD("get_authority_epoch"), &WeaponNetworkBridge::get_authority_epoch);
	ClassDB::bind_method(D_METHOD("set_authority_context_provider", "callback"), &WeaponNetworkBridge::set_authority_context_provider);
	ClassDB::bind_method(D_METHOD("get_authority_context_provider"), &WeaponNetworkBridge::get_authority_context_provider);
	ClassDB::bind_method(D_METHOD("set_reload_profile_provider", "callback"), &WeaponNetworkBridge::set_reload_profile_provider);
	ClassDB::bind_method(D_METHOD("get_reload_profile_provider"), &WeaponNetworkBridge::get_reload_profile_provider);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "role", PROPERTY_HINT_ENUM, "Server,Client"), "set_role", "get_role");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "weapon_authority_path"), "set_weapon_authority_path", "get_weapon_authority_path");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "server_peer_id"), "set_server_peer_id", "get_server_peer_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tick_rate"), "set_tick_rate", "get_tick_rate");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "authority_scope"), "set_authority_scope", "get_authority_scope");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "authority_epoch"), "set_authority_epoch", "get_authority_epoch");
	ADD_PROPERTY(PropertyInfo(Variant::CALLABLE, "authority_context_provider"), "set_authority_context_provider", "get_authority_context_provider");
	ADD_PROPERTY(PropertyInfo(Variant::CALLABLE, "reload_profile_provider"), "set_reload_profile_provider", "get_reload_profile_provider");

	ClassDB::bind_method(D_METHOD("is_multiplayer_active"), &WeaponNetworkBridge::is_multiplayer_active);
	ClassDB::bind_method(D_METHOD("begin_session", "peer", "session"), &WeaponNetworkBridge::begin_session);
	ClassDB::bind_method(D_METHOD("end_session", "peer"), &WeaponNetworkBridge::end_session);
	ClassDB::bind_method(D_METHOD("authorize_instance", "peer", "instance_id", "role"), &WeaponNetworkBridge::authorize_instance);
	ClassDB::bind_method(D_METHOD("revoke_instance", "peer", "instance_id"), &WeaponNetworkBridge::revoke_instance);
	ClassDB::bind_method(D_METHOD("drop_peer", "peer"), &WeaponNetworkBridge::drop_peer);
	ClassDB::bind_method(D_METHOD("replicate_teardown", "instance_id"), &WeaponNetworkBridge::replicate_teardown);
	ClassDB::bind_method(D_METHOD("push_state", "tick"), &WeaponNetworkBridge::push_state);

	ClassDB::bind_method(D_METHOD("request_fire_networked", "intent"), &WeaponNetworkBridge::request_fire_networked);
	ClassDB::bind_method(D_METHOD("request_begin_reload_networked", "intent"), &WeaponNetworkBridge::request_begin_reload_networked);
	ClassDB::bind_method(D_METHOD("request_cancel_reload_networked", "intent"), &WeaponNetworkBridge::request_cancel_reload_networked);
	ClassDB::bind_method(D_METHOD("request_configure_attachments_networked", "intent"), &WeaponNetworkBridge::request_configure_attachments_networked);
	ClassDB::bind_method(D_METHOD("request_resync", "instance_id"), &WeaponNetworkBridge::request_resync);
	ClassDB::bind_method(D_METHOD("send_compatibility_handshake"), &WeaponNetworkBridge::send_compatibility_handshake);
	ClassDB::bind_method(D_METHOD("confirmed_snapshot", "instance_id"), &WeaponNetworkBridge::confirmed_snapshot);
	ClassDB::bind_method(D_METHOD("is_instance_tombstoned", "instance_id"), &WeaponNetworkBridge::is_instance_tombstoned);

	ClassDB::bind_method(D_METHOD("_rpc_compatibility_handshake", "bytes"), &WeaponNetworkBridge::_rpc_compatibility_handshake);
	ClassDB::bind_method(D_METHOD("_rpc_fire_intent", "bytes"), &WeaponNetworkBridge::_rpc_fire_intent);
	ClassDB::bind_method(D_METHOD("_rpc_begin_reload_intent", "bytes"), &WeaponNetworkBridge::_rpc_begin_reload_intent);
	ClassDB::bind_method(D_METHOD("_rpc_cancel_reload_intent", "bytes"), &WeaponNetworkBridge::_rpc_cancel_reload_intent);
	ClassDB::bind_method(D_METHOD("_rpc_configure_attachments_intent", "bytes"), &WeaponNetworkBridge::_rpc_configure_attachments_intent);
	ClassDB::bind_method(D_METHOD("_rpc_acknowledgement_batch", "bytes"), &WeaponNetworkBridge::_rpc_acknowledgement_batch);
	ClassDB::bind_method(D_METHOD("_rpc_resync_request", "bytes"), &WeaponNetworkBridge::_rpc_resync_request);
	ClassDB::bind_method(D_METHOD("_rpc_snapshot_batch", "bytes"), &WeaponNetworkBridge::_rpc_snapshot_batch);
	ClassDB::bind_method(D_METHOD("_rpc_delta_batch", "bytes"), &WeaponNetworkBridge::_rpc_delta_batch);
	ClassDB::bind_method(D_METHOD("_rpc_command_rejection", "bytes"), &WeaponNetworkBridge::_rpc_command_rejection);

	// -- Server-side signals ------------------------------------------------
	ADD_SIGNAL(MethodInfo("command_rejected", PropertyInfo(Variant::INT, "peer"), PropertyInfo(Variant::STRING, "command_id"),
			PropertyInfo(Variant::STRING, "instance_id"), PropertyInfo(Variant::DICTIONARY, "status")));
	ADD_SIGNAL(MethodInfo("network_diagnostic", PropertyInfo(Variant::INT, "peer"), PropertyInfo(Variant::DICTIONARY, "status")));

	// -- Client-side signals -------------------------------------------------
	ADD_SIGNAL(MethodInfo("presentation_predicted", PropertyInfo(Variant::STRING, "command_id"), PropertyInfo(Variant::STRING, "instance_id"),
			PropertyInfo(Variant::INT, "kind")));
	ADD_SIGNAL(MethodInfo("presentation_confirmed", PropertyInfo(Variant::STRING, "command_id"), PropertyInfo(Variant::STRING, "instance_id"),
			PropertyInfo(Variant::INT, "kind")));
	ADD_SIGNAL(MethodInfo("presentation_reverted", PropertyInfo(Variant::STRING, "command_id"), PropertyInfo(Variant::STRING, "instance_id"),
			PropertyInfo(Variant::INT, "kind"), PropertyInfo(Variant::DICTIONARY, "status"), PropertyInfo(Variant::DICTIONARY, "confirmed_snapshot")));
	ADD_SIGNAL(MethodInfo("presentation_diverged", PropertyInfo(Variant::STRING, "command_id"), PropertyInfo(Variant::STRING, "instance_id"),
			PropertyInfo(Variant::INT, "kind")));
	ADD_SIGNAL(MethodInfo("presentation_expired", PropertyInfo(Variant::STRING, "command_id"), PropertyInfo(Variant::STRING, "instance_id"),
			PropertyInfo(Variant::INT, "kind")));
	ADD_SIGNAL(MethodInfo("snapshot_applied", PropertyInfo(Variant::STRING, "instance_id"), PropertyInfo(Variant::INT, "revision")));
	ADD_SIGNAL(MethodInfo("delta_applied", PropertyInfo(Variant::STRING, "instance_id"), PropertyInfo(Variant::INT, "revision")));
	ADD_SIGNAL(MethodInfo("resync_needed", PropertyInfo(Variant::STRING, "instance_id")));
	ADD_SIGNAL(MethodInfo("instance_tombstoned", PropertyInfo(Variant::STRING, "instance_id"), PropertyInfo(Variant::INT, "revision")));
}

} // namespace godot
