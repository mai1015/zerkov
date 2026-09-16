#ifndef WEAPON_SYSTEM_GODOT_WEAPON_NETWORK_BRIDGE_H
#define WEAPON_SYSTEM_GODOT_WEAPON_NETWORK_BRIDGE_H

#include "core/wpn_runtime.h"
#include "protocol/wpn_command_gate.h"
#include "protocol/wpn_prediction.h"
#include "protocol/wpn_protocol_types.h"
#include "protocol/wpn_replica.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/multiplayer_api.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <map>
#include <set>
#include <memory>

namespace godot {
class WeaponAuthority;

// Optional, fail-closed transport adapter. The game authenticates peers and
// owns MultiplayerAPI, the authoritative tick, inventory and action execution.
// Wire revision WNB1 wraps the unchanged core DTOs in a fresh connection token.
// No RPC handler here invokes fire/reload/attachment mutation. A required host
// admission callback queues validated commands; complete_command() reports the
// later authoritative decision, never an inference from another actor's state.
class WeaponNetworkBridge : public Node {
 GDCLASS(WeaponNetworkBridge, Node)
public:
 enum Role { ROLE_SERVER = 0, ROLE_CLIENT = 1 };
 WeaponNetworkBridge() = default;
 ~WeaponNetworkBridge() override = default;
 void set_role(Role value) { if (!is_inside_tree()) role = value; }
 Role get_role() const { return role; }
 void set_weapon_authority_path(const NodePath &value) { weapon_authority_path = value; }
 NodePath get_weapon_authority_path() const { return weapon_authority_path; }
 void set_server_peer_id(int value) { if (!is_inside_tree() && value > 0) server_peer_id = value; }
 int get_server_peer_id() const { return server_peer_id; }
 void set_tick_rate(int value) { tick_rate = value > 0 && value <= 1000 ? value : int(wpn::DEFAULT_TICK_RATE); }
 int get_tick_rate() const { return tick_rate; }
 void set_authority_scope(const String &value) { authority_scope = value; }
 String get_authority_scope() const { return authority_scope; }
 void set_authority_epoch(int64_t value) { authority_epoch = value; }
 int64_t get_authority_epoch() const { return authority_epoch; }
 // Retained API for migration; these no longer authorize direct RPC mutation.
 void set_authority_context_provider(const Callable &value) { authority_context_provider = value; }
 Callable get_authority_context_provider() const { return authority_context_provider; }
 void set_reload_profile_provider(const Callable &value) { reload_profile_provider = value; }
 Callable get_reload_profile_provider() const { return reload_profile_provider; }
 void set_command_admission_handler(const Callable &value) { command_admission_handler = value; }
 Callable get_command_admission_handler() const { return command_admission_handler; }
 // Client loads its own sealed catalog and supplies the full uint64 bit pattern.
 void set_client_catalog_fingerprint(int64_t value);
 int64_t get_client_catalog_fingerprint() const { return int64_t(client_catalog); }
 int get_hardening_revision() const { return 1; }
 bool is_multiplayer_active() const;
 bool is_session_ready() const { return role == ROLE_CLIENT && client_ready; }
 PackedByteArray connection_token() const { return role == ROLE_CLIENT ? client_token.duplicate() : PackedByteArray(); }
 Dictionary peer_state(int peer) const;
 void begin_session(int peer, int64_t session);
 void end_session(int peer);
 void drop_peer(int peer);
 bool authorize_instance(int peer, const String &instance, int permission);
 bool revoke_instance(int peer, const String &instance);
 void push_state(int64_t tick);
 void replicate_teardown(const String &instance);
 // Call from the game-owned executor immediately before a queued operation and
 // after its outcome. Revocation/reconnect invalidates retained pending work.
 bool command_still_current(const String &command_id);
 bool complete_command(const String &command_id, bool accepted);
 Dictionary request_fire_networked(const Dictionary &intent);
 Dictionary request_begin_reload_networked(const Dictionary &intent);
 Dictionary request_cancel_reload_networked(const Dictionary &intent);
 Dictionary request_configure_attachments_networked(const Dictionary &intent);
 bool request_resync(const String &instance);
 void send_compatibility_handshake();
 Dictionary confirmed_snapshot(const String &instance) const;
 bool is_instance_tombstoned(const String &instance) const;
protected:
 static void _bind_methods();
public: // Godot-cpp virtual dispatch registration requires public overrides.
 void _ready() override;
 void _process(double delta) override;
 void _exit_tree() override;
private:
 static constexpr int TOKEN_BYTES = 16;
 static constexpr int HEADER_BYTES = 20;
 static constexpr std::size_t MAX_PEERS = 64;
 static constexpr std::size_t MAX_PENDING = 1024;
 struct Session {
  uint64_t id = 0, epoch = 0, catalog = 0;
  PackedByteArray token;
  bool ready = false;
  std::map<String, int> grants;
  wpn::protocol::CommandSequenceTracker sequence;
  std::map<String, uint64_t> acked;
  std::map<String, std::set<uint64_t>> sent;
 };
 struct Pending {
  int peer = 0;
  std::shared_ptr<Session> session;
  String instance, client_id;
  uint64_t sequence = 0, payload_hash = 0;
 };
 Role role = ROLE_SERVER;
 NodePath weapon_authority_path;
 int server_peer_id = 1, tick_rate = int(wpn::DEFAULT_TICK_RATE);
 String authority_scope;
 int64_t authority_epoch = 0;
 Callable authority_context_provider, reload_profile_provider, command_admission_handler;
 std::map<int, std::shared_ptr<Session>> sessions;
 std::map<String, Pending> pending;
 wpn::protocol::RateLimiter rate;
 uint64_t epoch_counter = 0, tick = 0;
 Ref<MultiplayerAPI> wired_api;
 std::unique_ptr<wpn::protocol::WeaponReplica> replica;
 std::unique_ptr<wpn::protocol::PresentationPredictionTracker> prediction;
 PackedByteArray client_token;
 uint64_t client_catalog = 0, local_counter = 0;
 std::map<String, uint64_t> client_sequences;
 bool client_catalog_set = false, client_ready = false, in_admission = false;
 double advisory_ticks = 0.0, handshake_retry = 0.0;
 WeaponAuthority *authority() const;
 bool local_manifest(wpn::protocol::CompatibilityHandshake &value) const;
 bool recipient_ready(int peer, const String &instance, int permission = 0) const;
 bool server_sender() const;
 bool unpack_client(const PackedByteArray &wire, std::size_t maximum, int &peer, std::vector<uint8_t> &bytes, bool require_ready = true);
 bool unpack_server(const PackedByteArray &wire, std::size_t maximum, std::vector<uint8_t> &bytes) const;
 static PackedByteArray pack(const PackedByteArray &token, const std::vector<uint8_t> &bytes);
 static bool unpack(const PackedByteArray &wire, const PackedByteArray &token, std::size_t maximum, std::vector<uint8_t> &bytes);
 void send_offer(int peer);
 void send_state(int peer, const String &instance, bool force_snapshot = false);
 void send_result(int peer, const String &instance, const String &client_id, const wpn::Status &status, bool final);
 void remember_sent(Session &session, const String &instance, uint64_t revision);
 void dispatch(int peer, const String &instance, const String &client_id, uint64_t sequence, const std::vector<uint8_t> &bytes, Dictionary request);
 Dictionary send_intent(wpn::protocol::PredictionIntentKind kind, const Dictionary &request);
 void clear_client();
 void on_peer_disconnected(int peer);
 void on_server_disconnected();
 void _rpc_request_offer();
 void _rpc_session_offer(const PackedByteArray &token, const PackedByteArray &manifest);
 void _rpc_session_ready(const PackedByteArray &token);
 void _rpc_session_closed(const PackedByteArray &token);
 void _rpc_instance_revoked(const PackedByteArray &bytes);
 void _rpc_compatibility_handshake(const PackedByteArray &bytes);
 void _rpc_fire_intent(const PackedByteArray &bytes);
 void _rpc_begin_reload_intent(const PackedByteArray &bytes);
 void _rpc_cancel_reload_intent(const PackedByteArray &bytes);
 void _rpc_configure_attachments_intent(const PackedByteArray &bytes);
 void _rpc_acknowledgement_batch(const PackedByteArray &bytes);
 void _rpc_resync_request(const PackedByteArray &bytes);
 void _rpc_snapshot_batch(const PackedByteArray &bytes);
 void _rpc_delta_batch(const PackedByteArray &bytes);
 void _rpc_command_rejection(const PackedByteArray &bytes);
 void _rpc_command_result(const PackedByteArray &bytes);
 void apply_result(const PackedByteArray &bytes, bool success_allowed);
 void acknowledge(const std::set<std::string> &instances);
};
} // namespace godot
VARIANT_ENUM_CAST(WeaponNetworkBridge::Role);
#endif
