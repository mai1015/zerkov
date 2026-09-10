#ifndef INVENTORY_SYSTEM_PROTOCOL_NETWORK_GATEWAY_H
#define INVENTORY_SYSTEM_PROTOCOL_NETWORK_GATEWAY_H

#include "core/inv_commands.h"
#include "core/inv_ids.h"
#include "core/inv_limits.h"
#include "core/inv_status.h"
#include "protocol/inv_observer_protocol.h"
#include "protocol/inv_protocol_codec.h"
#include "protocol/inv_protocol_compat.h"
#include "protocol/inv_protocol_types.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

// Engine-independent ingress for Inventory System.  This is deliberately a
// synchronous state machine over value types and callbacks: it owns no
// MultiplayerPeer, socket, RPC registration, thread, timer, or Inventory
// runtime.  A game-owned bridge supplies authenticated session lifecycle,
// authoritative inventory lookup/policy, id allocation, and execution.
namespace inv::protocol {

// A peer is a transport principal, never an actor/gameplay identity.  Zero is
// reserved for "not bound" in every gateway identity domain.
using PeerId = std::uint64_t;
using SessionId = std::uint64_t;
using ActorId = std::uint64_t;
using AuthorityEpoch = std::uint64_t;
using ConnectionEpoch = std::uint64_t;

constexpr PeerId INVALID_PEER_ID = 0;
constexpr SessionId INVALID_SESSION_ID = 0;
constexpr ActorId INVALID_ACTOR_ID = 0;
constexpr AuthorityEpoch INVALID_AUTHORITY_EPOCH = 0;
constexpr ConnectionEpoch INVALID_CONNECTION_EPOCH = 0;

// Stable command classes.  Values intentionally match the canonical
// commands_detail::CommandTag values (1..19), but the gateway uses this
// public enum rather than relying on std::variant declaration order.
enum class CommandClass : std::uint8_t {
	MOVE_ITEM = 1,
	ROTATE_ITEM = 2,
	SPLIT_STACK = 3,
	MERGE_STACKS = 4,
	INSERT_ITEM = 5,
	REMOVE_ITEM = 6,
	EQUIP_ITEM = 7,
	UNEQUIP_ITEM = 8,
	SWAP_ITEMS = 9,
	AUTO_PLACE_ITEM = 10,
	QUICK_TRANSFER_ITEM = 11,
	LOOT_ITEM = 12,
	DROP_ITEM = 13,
	SETTLE_INVENTORY = 14,
	ASSIGN_REFERENCE = 15,
	CLEAR_REFERENCE = 16,
	TARGETED_PROVIDER_TRANSFER = 17,
	SET_ITEM_COMPONENT = 18,
	REMOVE_ITEM_COMPONENT = 19,
};

constexpr std::uint32_t ALL_COMMAND_CLASSES_MASK = (UINT32_C(1) << 19) - 1;

constexpr std::uint32_t command_class_bit(CommandClass p_class) {
	const std::uint8_t raw = static_cast<std::uint8_t>(p_class);
	return raw >= 1 && raw <= 19 ? (UINT32_C(1) << (raw - 1)) : 0;
}

// Session identity is installed by the authenticated game bridge. Within one
// authority epoch, newly issued logical session ids are strictly increasing;
// reconnect retains the same id and advances only connection_epoch. This
// lets bounded tombstones reject delayed traffic without assuming random or
// reusable transport ids. The allowlist defaults to zero.
struct SessionBinding {
	PeerId peer = INVALID_PEER_ID;
	SessionId session = INVALID_SESSION_ID;
	ActorId actor = INVALID_ACTOR_ID;
	AuthorityEpoch authority_epoch = INVALID_AUTHORITY_EPOCH;
	ConnectionEpoch connection_epoch = INVALID_CONNECTION_EPOCH;
	std::uint32_t command_allowlist = 0;
};

struct InboundContext {
	PeerId peer = INVALID_PEER_ID;
	SessionId session = INVALID_SESSION_ID;
	AuthorityEpoch authority_epoch = INVALID_AUTHORITY_EPOCH;
	ConnectionEpoch connection_epoch = INVALID_CONNECTION_EPOCH;
	std::uint64_t now_tick = 0;
	std::uint32_t tick_rate = DEFAULT_GATEWAY_TICK_RATE;
};

// Identity supplied to game callbacks.  local_command_id is the positive,
// client-local CommandHeader.command_id; it is never used as canonical global
// identity by the gateway executor.
struct CommandIdentity {
	PeerId peer = INVALID_PEER_ID;
	SessionId session = INVALID_SESSION_ID;
	ActorId actor = INVALID_ACTOR_ID;
	AuthorityEpoch authority_epoch = INVALID_AUTHORITY_EPOCH;
	ConnectionEpoch connection_epoch = INVALID_CONNECTION_EPOCH;
	CommandId local_command_id;
};

struct WorldPolicyRequest {
	CommandIdentity identity;
	CommandEnvelope envelope;
	CommandClass command_class = CommandClass::MOVE_ITEM;
	std::vector<InventoryId> touched_inventories;
	std::vector<std::uint64_t> current_revisions;
};

struct CommandExecutionRequest {
	CommandIdentity identity;
	CommandId canonical_command_id;
	CommandEnvelope envelope; // header.actor/id are canonicalized.
	CommandClass command_class = CommandClass::MOVE_ITEM;
	std::vector<InventoryId> touched_inventories;
	std::vector<std::uint64_t> current_revisions;
};

using CanonicalCommandAllocator = std::function<Status(const CommandIdentity &, CommandId &)>;
using RevisionProvider = std::function<Status(InventoryId, std::uint64_t &)>;
using WorldPolicy = std::function<Status(const WorldPolicyRequest &)>;
// The executor contract is synchronous and immediate: it must neither enqueue
// nor mutate external state if it returns a queued result. The gateway rejects
// queued outcomes because they cannot produce one authoritative reply here.
using CommandExecutor = std::function<TransactionResult(const CommandExecutionRequest &)>;

struct GatewayConfig {
	std::size_t max_sessions = MAX_GATEWAY_SESSIONS;
	std::size_t max_inventory_grants_per_session = MAX_GATEWAY_INVENTORY_GRANTS_PER_SESSION;
	std::size_t max_observer_grants_per_session = MAX_GATEWAY_OBSERVER_GRANTS_PER_SESSION;
	std::size_t replay_capacity_per_session = MAX_GATEWAY_REPLAY_ENTRIES_PER_SESSION;
	std::size_t replay_bytes_global = MAX_GATEWAY_REPLAY_BYTES;
	std::uint32_t commands_per_second = DEFAULT_GATEWAY_COMMANDS_PER_SECOND;
	std::uint32_t resyncs_per_minute = DEFAULT_GATEWAY_RESYNCS_PER_MINUTE;
	std::uint32_t default_tick_rate = DEFAULT_GATEWAY_TICK_RATE;
};

// Result returned by submit_command().  `status` is always the final gateway
// or executor status and mirrors `transaction.status`; `transaction` is
// retained even for rejections so callers can inspect conflict/revision
// fields without inventing a second result vocabulary.
struct GatewaySubmitOutcome {
	Status status;
	TransactionResult transaction;
	bool replayed = false;
	// Positive client-local sequence decoded from the authenticated command.
	// This remains distinct from transaction.command_id, which is replaced by
	// the authority-owned canonical id after execution.
	CommandId local_command_id;
	CommandId canonical_command_id;
	std::vector<InventoryId> touched_inventories;
};

// Observer admission is intentionally only an admission decision.  The
// returned visibility is resolved from an authenticated grant, never from the
// packet (ObserverResyncRequest has no visibility field).
struct ObserverAdmission {
	Status status;
	ObserverResyncRequest request;
	VisibilityScope visibility = VisibilityScope::REDACTED;
};

class InventoryNetworkGateway {
public:
	explicit InventoryNetworkGateway(SessionHello p_expected_hello, GatewayConfig p_config = {});

	// Installs a live authenticated binding.  A peer already bound to a
	// different session is rejected until end_session() explicitly retires the
	// old one.  A reconnect retaining the same logical session preserves grants
	// and replay state but clears hello readiness until the exact hello is
	// admitted again.
	Status bind_session(const SessionBinding &p_binding);
	Status begin_session(
			PeerId p_peer,
			SessionId p_session,
			ActorId p_actor,
			AuthorityEpoch p_authority_epoch,
			ConnectionEpoch p_connection_epoch,
			std::uint32_t p_command_allowlist = 0);

	Status end_session(PeerId p_peer);
	Status drop_session(SessionId p_session);
	Status clear();

	// Decodes and compares a SessionHello against the gateway's exact expected
	// value.  A mismatch never marks a session ready.  The raw overload is the
	// normal untrusted ingress path; the DTO overload is useful when a game
	// transport has already performed bounded decoding itself.
	Status admit_session_hello(
			const InboundContext &p_context,
			const std::uint8_t *p_data,
			std::size_t p_size);
	Status admit_session_hello(const InboundContext &p_context, const std::vector<std::uint8_t> &p_bytes);
	Status admit_session_hello(const InboundContext &p_context, const SessionHello &p_hello);
	// Size-only engine adapter path: authenticates the bound context and
	// consumes the shared ingress budget before rejecting an oversized hello,
	// without requiring the engine byte array to be copied first.
	Status reject_oversized_session_hello(const InboundContext &p_context, std::size_t p_packet_size);
	bool session_ready(SessionId p_session) const;

	Status set_command_allowlist(SessionId p_session, std::uint32_t p_allowlist);
	std::uint32_t command_allowlist(SessionId p_session) const;

	// Exact per-session inventory access.  The gateway derives every touched
	// inventory from the command's static shape and explicit inventory fields
	// (or, for a single-inventory command, its sole expected-revision entry)
	// before invoking the revision provider or world policy callback.
	Status grant_inventory(SessionId p_session, InventoryId p_inventory);
	Status revoke_inventory(SessionId p_session, InventoryId p_inventory);
	bool has_inventory_grant(SessionId p_session, InventoryId p_inventory) const;
	// Authority lifecycle hook.  Unload/replacement revokes every command and
	// replication grant for the raw id and retires cached commands that touched
	// its former runtime generation.  Unrelated inventory state is preserved.
	Status invalidate_inventory(InventoryId p_inventory);

	// Observer stream grants are recipient/session/inventory/visibility scoped.
	// Registering a grant does not authenticate a transport and never exposes
	// visibility through a packet.
	Status grant_observer(SessionId p_session, InventoryId p_inventory, VisibilityScope p_visibility);
	Status revoke_observer(SessionId p_session, InventoryId p_inventory);

	Status set_expected_hello(SessionHello p_expected_hello);
	const SessionHello &expected_hello() const { return expected_hello_; }

	Status set_callbacks(
			CanonicalCommandAllocator p_allocator,
			RevisionProvider p_revision_provider,
			WorldPolicy p_world_policy,
			CommandExecutor p_executor);
	Status set_allocator(CanonicalCommandAllocator p_allocator);
	Status set_revision_provider(RevisionProvider p_provider);
	Status set_world_policy(WorldPolicy p_policy);
	Status set_executor(CommandExecutor p_executor);

	// The shared command-ingress token bucket is consumed after exact
	// identity/session checks but before hello readiness, command size, or byte
	// parsing. SessionHello attempts use this bucket too, so pre-handshake,
	// malformed, and oversized traffic all consume the same bounded budget.
	Status submit_command(
			const InboundContext &p_context,
			const std::uint8_t *p_data,
			std::size_t p_size,
			GatewaySubmitOutcome &r_outcome);
	Status submit_command(
			const InboundContext &p_context,
			const std::vector<std::uint8_t> &p_bytes,
			GatewaySubmitOutcome &r_outcome);

	// Convenience for a caller that already decoded through the canonical
	// codec.  It still canonical-encodes the envelope to establish the exact
	// replay bytes and follows the same rate/admission path.
	Status submit_command(
			const InboundContext &p_context,
			const CommandEnvelope &p_envelope,
			GatewaySubmitOutcome &r_outcome);

	// Size-only adapter path for engines whose byte-array value must not be
	// copied before the core cap is known.  The same authenticated hello and
	// command-rate gates are consumed before PAYLOAD_TOO_LARGE is returned.
	// Calling this for an in-range packet is an invalid argument.
	Status reject_oversized_command(
			const InboundContext &p_context,
			std::size_t p_packet_size,
			GatewaySubmitOutcome &r_outcome);
	// Engine adapter path for a correctly bound session that has not completed
	// compatibility hello. It consumes the same command bucket before returning
	// SESSION_HELLO_REQUIRED, allowing the adapter to reject without copying.
	Status reject_unready_command(
			const InboundContext &p_context,
			GatewaySubmitOutcome &r_outcome);

	// Observer resync has an independent token bucket and consumes it before
	// size/decode, including malformed and unauthorized requests.
	Status admit_observer_resync(
			const InboundContext &p_context,
			const std::uint8_t *p_data,
			std::size_t p_size,
			ObserverAdmission &r_admission);
	Status admit_observer_resync(
			const InboundContext &p_context,
			const std::vector<std::uint8_t> &p_bytes,
			ObserverAdmission &r_admission);

	// Owner/canonical resyncs use the same authenticated session/hello gate
	// and independent resync bucket without pretending to be observer
	// requests.  The caller performs its own owner-grant check after this
	// admission; this method only authenticates context and consumes budget.
	Status admit_resync_context(const InboundContext &p_context);

	std::size_t tracked_session_count() const { return sessions_.size(); }
	std::size_t inventory_grant_count(SessionId p_session) const;
	std::size_t observer_grant_count(SessionId p_session) const;
	std::size_t replay_entry_count(SessionId p_session) const;
	std::size_t replay_bytes() const { return replay_bytes_; }
	std::uint64_t highest_sequence(SessionId p_session) const;
	std::uint64_t evicted_sequence_floor(SessionId p_session) const;

	static CommandClass classify_command(const Command &p_command);
	static bool is_authority_only(CommandClass p_class);
	static Status derive_touched_inventories(
			const CommandEnvelope &p_envelope,
			std::vector<InventoryId> &r_touched);

private:
	struct TokenBucket {
		// Whole tokens plus an exact fractional refill numerator.  Keeping the
		// fraction separate avoids the ceil(window_ticks / capacity) rounding
		// that otherwise under-admits rates such as 32 commands at 60 Hz.
		std::uint64_t available_tokens = 0;
		std::uint64_t refill_remainder = 0;
		std::uint64_t last_tick = 0;
		bool initialized = false;
	};

	struct ReplayEntry {
		std::vector<std::uint8_t> bytes;
		GatewaySubmitOutcome outcome;
		std::size_t accounted_bytes = 0;
		bool in_flight = false;
		std::uint64_t touch_seq = 0;
	};

	struct SessionState {
		SessionBinding binding;
		bool hello_ready = false;
		SessionHello remote_hello;
		std::map<InventoryId, bool> inventory_grants;
		std::map<InventoryId, VisibilityScope> observer_grants;
		std::map<std::uint64_t, ReplayEntry> replay;
		std::uint64_t highest_sequence = 0;
		std::uint64_t evicted_floor = 0;
		TokenBucket command_bucket;
		TokenBucket resync_bucket;
		std::uint64_t touch_seq = 0;
	};

	SessionState *find_session(PeerId p_peer, SessionId p_session);
	const SessionState *find_session(PeerId p_peer, SessionId p_session) const;
	SessionState *find_session_id(SessionId p_session);
	const SessionState *find_session_id(SessionId p_session) const;
	Status validate_context(const InboundContext &p_context, SessionState *&r_session);
	Status validate_context(const InboundContext &p_context, const SessionState *&r_session) const;
	Status admit_command_rate(SessionState &r_session, const InboundContext &p_context);
	Status admit_resync_rate(SessionState &r_session, const InboundContext &p_context);
	static Status admit_bucket(
			TokenBucket &r_bucket,
			std::uint64_t p_now_tick,
			std::uint32_t p_tick_rate,
			std::uint32_t p_capacity,
			std::uint64_t p_window_seconds);
	Status submit_decoded(
			SessionState &r_session,
			const std::vector<std::uint8_t> &p_bytes,
			const CommandEnvelope &p_envelope,
			GatewaySubmitOutcome &r_outcome);
	Status submit_command_view(
			const InboundContext &p_context,
			const std::uint8_t *p_data,
			std::size_t p_size,
			GatewaySubmitOutcome &r_outcome);
	Status reject_and_cache(
			SessionState &r_session,
			std::uint64_t p_sequence,
			const std::vector<std::uint8_t> &p_bytes,
			const GatewaySubmitOutcome &p_outcome);
	void cache_outcome(SessionState &r_session, std::uint64_t p_sequence, const std::vector<std::uint8_t> &p_bytes, const GatewaySubmitOutcome &p_outcome);
	Status reserve_replay(SessionState &r_session, std::uint64_t p_sequence, const std::vector<std::uint8_t> &p_bytes);
	void enforce_replay_byte_cap();
	void invalidate_session_replay(SessionState &r_session);
	static GatewaySubmitOutcome make_replay_receipt(const GatewaySubmitOutcome &p_outcome);
	static std::size_t replay_receipt_bytes(const GatewaySubmitOutcome &p_outcome);
	Status mutation_busy() const;
	Status callback_status_begin();
	void callback_status_end();
	void record_retired(SessionId p_session, AuthorityEpoch p_epoch);
	static Status add_touched(std::vector<InventoryId> &r_touched, InventoryId p_inventory);
	static void set_rejection(GatewaySubmitOutcome &r_outcome, Status p_status, CommandId p_command_id = {});
	static Status normalize_touched(std::vector<InventoryId> &r_touched);
	static bool expected_revision_for(
			const std::vector<ExpectedRevision> &p_expected,
			InventoryId p_inventory,
			std::uint64_t &r_revision);

	SessionHello expected_hello_;
	GatewayConfig config_;
	CanonicalCommandAllocator allocator_;
	RevisionProvider revision_provider_;
	WorldPolicy world_policy_;
	CommandExecutor executor_;
	std::map<PeerId, SessionState> sessions_;
	std::map<SessionId, AuthorityEpoch> retired_sessions_;
	std::uint64_t retired_session_floor_ = 0;
	AuthorityEpoch active_authority_epoch_ = INVALID_AUTHORITY_EPOCH;
	SessionId highest_session_id_ = INVALID_SESSION_ID;
	std::size_t replay_bytes_ = 0;
	std::uint64_t touch_counter_ = 0;
	bool processing_ = false;
	bool callback_active_ = false;
};

} // namespace inv::protocol

#endif // INVENTORY_SYSTEM_PROTOCOL_NETWORK_GATEWAY_H
