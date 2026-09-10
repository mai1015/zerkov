#ifndef INVENTORY_SYSTEM_GODOT_NETWORK_GATEWAY_H
#define INVENTORY_SYSTEM_GODOT_NETWORK_GATEWAY_H

#include "godot/inventory_authority.h"
#include "protocol/inv_network_gateway.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/core/object.hpp>

#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <vector>

namespace godot {

// Server-only Godot adapter for inv::protocol::InventoryNetworkGateway.
//
// This node deliberately owns no MultiplayerPeer and declares no RPC entry
// points.  A game-owned transport authenticates a connection and calls the
// explicit methods below with the trusted peer/session/actor/epoch tuple.  A
// transport may then forward the returned `bytes` value using whatever RPC or
// packet format the game owns.  InventoryAuthority remains a local canonical
// object; this class is the only façade that can admit remote inventory bytes.
class InventoryNetworkGateway : public Node {
	GDCLASS(InventoryNetworkGateway, Node)

public:
	// Kept numerically aligned with inv::VisibilityScope and
	// InventorySnapshotResource::Visibility.  OWNER replication is a separate
	// grant from command inventory access; OBSERVER/REDACTED grants use the
	// authority's recipient-safe observer protocol.
	enum Visibility {
		VISIBILITY_OWNER = 0,
		VISIBILITY_OBSERVER = 1,
		VISIBILITY_REDACTED = 2,
	};

	// Stable script-facing command class ids.  These deliberately mirror the
	// transport protocol's append-only 1..19 values; scripts should use the
	// mask constants below (or command_mask_for_class()) rather than shifting
	// an undocumented bit position themselves.
	enum CommandClass {
		COMMAND_CLASS_MOVE_ITEM = 1,
		COMMAND_CLASS_ROTATE_ITEM = 2,
		COMMAND_CLASS_SPLIT_STACK = 3,
		COMMAND_CLASS_MERGE_STACKS = 4,
		COMMAND_CLASS_INSERT_ITEM = 5,
		COMMAND_CLASS_REMOVE_ITEM = 6,
		COMMAND_CLASS_EQUIP_ITEM = 7,
		COMMAND_CLASS_UNEQUIP_ITEM = 8,
		COMMAND_CLASS_SWAP_ITEMS = 9,
		COMMAND_CLASS_AUTO_PLACE_ITEM = 10,
		COMMAND_CLASS_QUICK_TRANSFER_ITEM = 11,
		COMMAND_CLASS_LOOT_ITEM = 12,
		COMMAND_CLASS_DROP_ITEM = 13,
		COMMAND_CLASS_SETTLE_INVENTORY = 14,
		COMMAND_CLASS_ASSIGN_REFERENCE = 15,
		COMMAND_CLASS_CLEAR_REFERENCE = 16,
		COMMAND_CLASS_TARGETED_PROVIDER_TRANSFER = 17,
		COMMAND_CLASS_SET_ITEM_COMPONENT = 18,
		COMMAND_CLASS_REMOVE_ITEM_COMPONENT = 19,
	};

	static constexpr int64_t COMMAND_MASK_MOVE_ITEM = INT64_C(1) << 0;
	static constexpr int64_t COMMAND_MASK_ROTATE_ITEM = INT64_C(1) << 1;
	static constexpr int64_t COMMAND_MASK_SPLIT_STACK = INT64_C(1) << 2;
	static constexpr int64_t COMMAND_MASK_MERGE_STACKS = INT64_C(1) << 3;
	static constexpr int64_t COMMAND_MASK_INSERT_ITEM = INT64_C(1) << 4;
	static constexpr int64_t COMMAND_MASK_REMOVE_ITEM = INT64_C(1) << 5;
	static constexpr int64_t COMMAND_MASK_EQUIP_ITEM = INT64_C(1) << 6;
	static constexpr int64_t COMMAND_MASK_UNEQUIP_ITEM = INT64_C(1) << 7;
	static constexpr int64_t COMMAND_MASK_SWAP_ITEMS = INT64_C(1) << 8;
	static constexpr int64_t COMMAND_MASK_AUTO_PLACE_ITEM = INT64_C(1) << 9;
	static constexpr int64_t COMMAND_MASK_QUICK_TRANSFER_ITEM = INT64_C(1) << 10;
	static constexpr int64_t COMMAND_MASK_LOOT_ITEM = INT64_C(1) << 11;
	static constexpr int64_t COMMAND_MASK_DROP_ITEM = INT64_C(1) << 12;
	static constexpr int64_t COMMAND_MASK_SETTLE_INVENTORY = INT64_C(1) << 13;
	static constexpr int64_t COMMAND_MASK_ASSIGN_REFERENCE = INT64_C(1) << 14;
	static constexpr int64_t COMMAND_MASK_CLEAR_REFERENCE = INT64_C(1) << 15;
	static constexpr int64_t COMMAND_MASK_TARGETED_PROVIDER_TRANSFER = INT64_C(1) << 16;
	static constexpr int64_t COMMAND_MASK_SET_ITEM_COMPONENT = INT64_C(1) << 17;
	static constexpr int64_t COMMAND_MASK_REMOVE_ITEM_COMPONENT = INT64_C(1) << 18;
	static constexpr int64_t COMMAND_MASK_ALL = (INT64_C(1) << 19) - 1;
	static constexpr int64_t MAX_REPLICATION_GRANTS_PER_SESSION =
			static_cast<int64_t>(inv::MAX_GATEWAY_INVENTORY_GRANTS_PER_SESSION);

	static int64_t command_mask_for_class(int64_t p_class);

	InventoryNetworkGateway();
	~InventoryNetworkGateway() override;

	// -- Server wiring and immutable protocol configuration ------------------
	void set_authority_path(const NodePath &p_path);
	NodePath get_authority_path() const { return authority_path; }
	// Alias retained for scene authors who use the façade's concrete name.
	void set_inventory_authority_path(const NodePath &p_path) { set_authority_path(p_path); }
	NodePath get_inventory_authority_path() const { return get_authority_path(); }

	// Both values are positive signed-int64 façade values.  Once configured,
	// setting a different value fails closed; this prevents a live session from
	// silently changing the identity/rate domain it authenticated against.
	bool set_authority_epoch(int64_t p_epoch);
	int64_t get_authority_epoch() const { return authority_epoch; }
	bool set_tick_rate(int64_t p_tick_rate);
	int64_t get_tick_rate() const { return tick_rate; }
	Dictionary configure(int64_t p_authority_epoch, int64_t p_tick_rate);

	void set_world_policy(const Callable &p_policy);
	Callable get_world_policy() const { return world_policy; }
	// Explicitly named alias for integrations that use callback terminology.
	void set_world_policy_callback(const Callable &p_policy) { set_world_policy(p_policy); }
	Callable get_world_policy_callback() const { return get_world_policy(); }

	// -- Authenticated session lifecycle -------------------------------------
	// `command_allowlist` is a bit mask over command classes.  It intentionally
	// defaults to zero: a session has no command permission until the game
	// grants it.  The authority epoch is the immutable configured value above.
	Dictionary begin_session(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_actor,
			int64_t p_connection_epoch,
			int64_t p_command_allowlist = 0);
	Dictionary end_session(int64_t p_peer);
	Dictionary drop_session(int64_t p_session);
	Dictionary clear_sessions();

	Dictionary accept_session_hello(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const PackedByteArray &p_bytes,
			int64_t p_now_tick = 0);
	// Protocol terminology alias; both names perform the same exact-byte
	// compatibility admission and neither trusts packet identity fields.
	Dictionary admit_session_hello(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const PackedByteArray &p_bytes,
			int64_t p_now_tick = 0) {
		return accept_session_hello(p_peer, p_session, p_connection_epoch, p_bytes, p_now_tick);
	}

	Dictionary set_command_allowlist(int64_t p_session, int64_t p_allowlist);
	int64_t get_command_allowlist(int64_t p_session) const;
	bool session_ready(int64_t p_session) const;

	// Exact command-inventory grants.  These grants are intentionally separate
	// from replication grants: command access never authorizes an OWNER packet.
	Dictionary grant_inventory(int64_t p_session, int64_t p_inventory);
	Dictionary revoke_inventory(int64_t p_session, int64_t p_inventory);
	Dictionary grant_command_inventory(int64_t p_session, int64_t p_inventory) { return grant_inventory(p_session, p_inventory); }
	Dictionary revoke_command_inventory(int64_t p_session, int64_t p_inventory) { return revoke_inventory(p_session, p_inventory); }
	bool has_inventory_grant(int64_t p_session, int64_t p_inventory) const;

	// Exact recipient replication grants.  `VISIBILITY_OWNER` is held wholly in
	// this façade because canonical owner packets are not observer streams;
	// non-owner grants are mirrored into the engine-free gateway and the
	// authority's recipient-safe discovery lifecycle.
	Dictionary grant_replication(int64_t p_session, int64_t p_inventory, int64_t p_visibility);
	Dictionary revoke_replication(int64_t p_session, int64_t p_inventory);
	Dictionary grant_owner_replication(int64_t p_session, int64_t p_inventory) {
		return grant_replication(p_session, p_inventory, VISIBILITY_OWNER);
	}
	Dictionary grant_observer_replication(int64_t p_session, int64_t p_inventory, int64_t p_visibility = VISIBILITY_OBSERVER);
	int get_replication_visibility(int64_t p_session, int64_t p_inventory) const;
	bool has_replication_grant(int64_t p_session, int64_t p_inventory) const;

	// -- Remote command admission -------------------------------------------
	// These methods are transport-facing but not RPCs.  The transport supplies
	// the authenticated tuple; peer/actor/visibility are never taken from the
	// packet.  The bytes are checked before copying and then passed through the
	// engine-free gateway's rate, sequence, revision, policy, replay, and
	// executor gates.
	Dictionary submit_command_bytes(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const PackedByteArray &p_bytes,
			int64_t p_now_tick = 0);
	Dictionary submit_remote_command(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const PackedByteArray &p_bytes,
			int64_t p_now_tick = 0) {
		return submit_command_bytes(p_peer, p_session, p_connection_epoch, p_bytes, p_now_tick);
	}
	// Bytes-first convenience for scripts that keep the packet as their first
	// local value; it still uses the same trusted transport context.
	Dictionary submit_command(
			const PackedByteArray &p_bytes,
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			int64_t p_now_tick = 0) {
		return submit_command_bytes(p_peer, p_session, p_connection_epoch, p_bytes, p_now_tick);
	}

	// -- Grant-scoped replication -------------------------------------------
	Dictionary snapshot_result(int64_t p_session, int64_t p_inventory) const;
	PackedByteArray snapshot_bytes(int64_t p_session, int64_t p_inventory) const;
	Dictionary delta_result(int64_t p_session, int64_t p_inventory, int64_t p_predecessor = 0) const;
	PackedByteArray delta_bytes(int64_t p_session, int64_t p_inventory, int64_t p_predecessor = 0) const;

	// Accepts either a recipient-safe ObserverResyncRequest or a canonical
	// owner ResyncRequest.  Observer visibility is always looked up from the
	// stored grant; no packet field can select or widen it.  Generation/sequence
	// 0/0 is a valid observer bootstrap request.
	Dictionary resync_result(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const PackedByteArray &p_bytes,
			int64_t p_now_tick = 0);
	PackedByteArray resync_bytes(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const PackedByteArray &p_bytes,
			int64_t p_now_tick = 0);

	Dictionary get_last_status() const;
	int64_t tracked_session_count() const;
	int64_t replay_entry_count(int64_t p_session) const;

protected:
	static void _bind_methods();

private:
	struct SessionRecord {
		std::uint64_t peer = 0;
		std::uint64_t session = 0;
		std::uint64_t actor = 0;
		std::uint64_t connection_epoch = 0;
		bool discovery_registered = false;
		std::map<std::uint64_t, inv::VisibilityScope> replication_grants;
	};

	InventoryAuthority *resolve_authority() const;
	InventoryAuthority *resolve_bound_authority() const;
	bool check_bound_authority(InventoryAuthority *p_authority, inv::Status &r_status) const;
	bool bind_authority_lifecycle(InventoryAuthority *p_authority);
	void unbind_authority_lifecycle();
	void _on_inventory_generation_invalidated(int64_t p_inventory);
	void flush_pending_lifecycle_reset();
	Dictionary status_result(const inv::Status &p_status, bool p_gateway_admitted = false) const;
	Dictionary status_result_from_authority(const Dictionary &p_authority_result, bool p_default_ok = false) const;
	Dictionary invalid_result(inv::StatusCode p_code, inv::DiagnosticId p_diagnostic = inv::DiagnosticId::VALUE_OUT_OF_RANGE, std::uint64_t p_detail = 0) const;
	bool valid_positive(int64_t p_value) const;
	bool valid_u32_mask(int64_t p_value) const;
	bool valid_tick(int64_t p_value) const;
	bool valid_now_tick(int64_t p_value) const;
	bool check_transport_session(
			int64_t p_peer,
			int64_t p_session,
			int64_t p_connection_epoch,
			const SessionRecord *&r_record,
			inv::Status &r_status) const;
	bool check_server_authority(inv::Status &r_status) const;
	bool check_configured(inv::Status &r_status) const;
	bool ensure_core(InventoryAuthority *p_authority, inv::Status &r_status);
	void install_core_callbacks(InventoryAuthority *p_authority);
	void teardown_discovery(SessionRecord &r_record, InventoryAuthority *p_authority) const;
	SessionRecord *session_record(std::uint64_t p_session);
	const SessionRecord *session_record(std::uint64_t p_session) const;
	SessionRecord *session_record_by_peer(std::uint64_t p_peer);
	const SessionRecord *session_record_by_peer(std::uint64_t p_peer) const;

	inv::Status resolve_revision(inv::InventoryId p_inventory, std::uint64_t &r_revision) const;
	inv::Status invoke_world_policy(const inv::protocol::WorldPolicyRequest &p_request);
	inv::TransactionResult execute_command(const inv::protocol::CommandExecutionRequest &p_request);

	Dictionary command_outcome(
			const inv::protocol::InboundContext &p_context,
			const inv::protocol::GatewaySubmitOutcome &p_outcome,
			std::uint64_t p_client_sequence) const;
	Dictionary observer_result(
			const inv::Status &p_status,
			const PackedByteArray &p_bytes,
			std::uint64_t p_inventory,
			inv::VisibilityScope p_visibility,
			std::uint64_t p_generation = 0,
			std::uint64_t p_sequence = 0) const;
	Dictionary owner_delta_result(
			const inv::Status &p_status,
			const PackedByteArray &p_bytes,
			std::uint64_t p_inventory) const;

	static const char *command_class_name(inv::protocol::CommandClass p_class);
	static Dictionary location_value(const inv::ItemLocation &p_location);
	static Dictionary command_value(const inv::Command &p_command);
	static Dictionary transaction_value(const inv::TransactionResult &p_result);
	static Array expected_revisions_value(const std::vector<inv::ExpectedRevision> &p_revisions);
	static PackedInt64Array ids_value(const std::vector<inv::InventoryId> &p_ids);
	static PackedInt64Array revisions_value(const std::vector<std::uint64_t> &p_revisions);
	static bool script_safe_location(const inv::ItemLocation &p_location);
	static bool script_safe_command(const inv::Command &p_command);
	static bool script_safe_envelope(const inv::protocol::CommandEnvelope &p_envelope);
	static int64_t as_script_int(std::uint64_t p_value);

	NodePath authority_path;
	int64_t authority_epoch = 0;
	int64_t tick_rate = inv::DEFAULT_GATEWAY_TICK_RATE;
	bool authority_epoch_configured = false;
	bool tick_rate_configured = false;
	Callable world_policy;

	std::unique_ptr<inv::protocol::InventoryNetworkGateway> gateway;
	std::map<std::uint64_t, SessionRecord> sessions;
	std::map<std::uint64_t, std::uint64_t> peer_to_session;
	ObjectID callbacks_authority_id = ObjectID();
	bool callbacks_installed = false;
	bool processing = false;
	bool pending_lifecycle_reset = false;
	mutable inv::Status last_status;
};

} // namespace godot

VARIANT_ENUM_CAST(InventoryNetworkGateway::Visibility);

#endif // INVENTORY_SYSTEM_GODOT_NETWORK_GATEWAY_H
