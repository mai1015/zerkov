#include "protocol/inv_network_gateway.h"

#include "core/inv_version.h"

#include <algorithm>
#include <limits>
#include <type_traits>
#include <utility>

namespace inv::protocol {

namespace {

bool valid_visibility(VisibilityScope p_visibility) {
	return p_visibility == VisibilityScope::OBSERVER || p_visibility == VisibilityScope::REDACTED;
}

template <typename T>
bool positive(T p_value) {
	return p_value != 0;
}

Status invalid_gateway_argument(std::uint64_t p_detail = 0) {
	return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::VALUE_OUT_OF_RANGE, p_detail);
}

Status missing_callback() {
	return make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::GATEWAY_CALLBACK_MISSING);
}

Status gateway_busy() {
	return make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::GATEWAY_REENTRANT);
}

struct ProcessingGuard {
	bool &flag;
	explicit ProcessingGuard(bool &p_flag) : flag(p_flag) { flag = true; }
	~ProcessingGuard() { flag = false; }
};

std::size_t saturating_add(std::size_t p_left, std::size_t p_right) {
	return p_right > std::numeric_limits<std::size_t>::max() - p_left
			? std::numeric_limits<std::size_t>::max()
			: p_left + p_right;
}

} // namespace

InventoryNetworkGateway::InventoryNetworkGateway(SessionHello p_expected_hello, GatewayConfig p_config) :
		expected_hello_(std::move(p_expected_hello)),
		config_(p_config) {
	config_.max_sessions = std::max<std::size_t>(1, std::min(config_.max_sessions, MAX_GATEWAY_SESSIONS));
	config_.max_inventory_grants_per_session = std::max<std::size_t>(1,
			std::min(config_.max_inventory_grants_per_session, MAX_GATEWAY_INVENTORY_GRANTS_PER_SESSION));
	config_.max_observer_grants_per_session = std::max<std::size_t>(1,
			std::min(config_.max_observer_grants_per_session, MAX_GATEWAY_OBSERVER_GRANTS_PER_SESSION));
	config_.replay_capacity_per_session = std::max<std::size_t>(1,
			std::min(config_.replay_capacity_per_session, MAX_GATEWAY_REPLAY_ENTRIES_PER_SESSION));
	config_.replay_bytes_global = std::max<std::size_t>(1,
			std::min(config_.replay_bytes_global, MAX_GATEWAY_REPLAY_BYTES));
	if (config_.commands_per_second == 0) config_.commands_per_second = 1;
	if (config_.resyncs_per_minute == 0) config_.resyncs_per_minute = 1;
	if (config_.default_tick_rate == 0) config_.default_tick_rate = DEFAULT_GATEWAY_TICK_RATE;
}

InventoryNetworkGateway::SessionState *InventoryNetworkGateway::find_session(PeerId p_peer, SessionId p_session) {
	auto it = sessions_.find(p_peer);
	return it == sessions_.end() || it->second.binding.session != p_session ? nullptr : &it->second;
}

const InventoryNetworkGateway::SessionState *InventoryNetworkGateway::find_session(PeerId p_peer, SessionId p_session) const {
	auto it = sessions_.find(p_peer);
	return it == sessions_.end() || it->second.binding.session != p_session ? nullptr : &it->second;
}

InventoryNetworkGateway::SessionState *InventoryNetworkGateway::find_session_id(SessionId p_session) {
	for (auto &entry : sessions_) {
		if (entry.second.binding.session == p_session) return &entry.second;
	}
	return nullptr;
}

const InventoryNetworkGateway::SessionState *InventoryNetworkGateway::find_session_id(SessionId p_session) const {
	for (const auto &entry : sessions_) {
		if (entry.second.binding.session == p_session) return &entry.second;
	}
	return nullptr;
}

void InventoryNetworkGateway::enforce_replay_byte_cap() {
	while (replay_bytes_ > config_.replay_bytes_global) {
		SessionState *oldest_session = nullptr;
		std::map<std::uint64_t, ReplayEntry>::iterator oldest_entry;
		std::uint64_t oldest_touch = std::numeric_limits<std::uint64_t>::max();
		for (auto &session_entry : sessions_) {
			for (auto replay_it = session_entry.second.replay.begin(); replay_it != session_entry.second.replay.end(); ++replay_it) {
				if (replay_it->second.in_flight || replay_it->second.accounted_bytes == 0) continue;
				if (replay_it->second.touch_seq < oldest_touch) {
					oldest_touch = replay_it->second.touch_seq;
					oldest_session = &session_entry.second;
					oldest_entry = replay_it;
				}
			}
		}
		if (oldest_session == nullptr) break; // an in-flight entry is never evicted.
		const std::uint64_t sequence = oldest_entry->first;
		replay_bytes_ -= oldest_entry->second.accounted_bytes;
		if (sequence > oldest_session->evicted_floor) oldest_session->evicted_floor = sequence;
		oldest_session->replay.erase(oldest_entry);
	}
}

void InventoryNetworkGateway::invalidate_session_replay(SessionState &r_session) {
	for (const auto &entry : r_session.replay) {
		r_session.evicted_floor = std::max(r_session.evicted_floor, entry.first);
		replay_bytes_ -= entry.second.accounted_bytes;
	}
	r_session.replay.clear();
}

void InventoryNetworkGateway::record_retired(SessionId p_session, AuthorityEpoch p_epoch) {
	if (!p_session) return;
	auto retired = retired_sessions_.find(p_session);
	if (retired == retired_sessions_.end()) retired_sessions_[p_session] = p_epoch;
	else retired->second = std::max(retired->second, p_epoch);
	while (retired_sessions_.size() > MAX_GATEWAY_RETIRED_SESSIONS) {
		auto oldest = retired_sessions_.begin();
		retired_session_floor_ = std::max(retired_session_floor_, oldest->first);
		retired_sessions_.erase(oldest);
	}
}

Status InventoryNetworkGateway::mutation_busy() const {
	return (processing_ || callback_active_) ? gateway_busy() : ok_status();
}

Status InventoryNetworkGateway::bind_session(const SessionBinding &p_binding) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	if (!positive(p_binding.peer) || !positive(p_binding.session) || !positive(p_binding.actor) ||
			!positive(p_binding.authority_epoch) || !positive(p_binding.connection_epoch) ||
			(p_binding.command_allowlist & ~ALL_COMMAND_CLASSES_MASK) != 0) {
		return invalid_gateway_argument();
	}
	if (active_authority_epoch_ == INVALID_AUTHORITY_EPOCH) {
		active_authority_epoch_ = p_binding.authority_epoch;
	} else if (p_binding.authority_epoch < active_authority_epoch_) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::AUTHORITY_EPOCH_MISMATCH,
				p_binding.authority_epoch);
	} else if (p_binding.authority_epoch > active_authority_epoch_) {
		if (!sessions_.empty()) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::AUTHORITY_EPOCH_MISMATCH,
					p_binding.authority_epoch);
		}
		// A true authority rotation starts a new monotonic session-id domain.
		// Older packets still carry the retired authority epoch and cannot enter
		// this domain even if the new authority deliberately reuses low ids.
		active_authority_epoch_ = p_binding.authority_epoch;
		highest_session_id_ = INVALID_SESSION_ID;
		retired_sessions_.clear();
		retired_session_floor_ = 0;
	}
	auto existing = sessions_.find(p_binding.peer);
	if (existing != sessions_.end()) {
		SessionState &state = existing->second;
		if (state.binding.session != p_binding.session) {
			// A different live session is never silently replaced.  The caller
			// must explicitly end_session(), which retires the id.
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::SESSION_UNKNOWN, state.binding.session);
		}
		if (state.binding.actor != p_binding.actor) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::ACTOR_MISMATCH, p_binding.actor);
		}
		if (state.binding.authority_epoch != p_binding.authority_epoch) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::AUTHORITY_EPOCH_MISMATCH, p_binding.authority_epoch);
		}
		if (p_binding.connection_epoch < state.binding.connection_epoch) {
			return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::CONNECTION_EPOCH_MISMATCH, p_binding.connection_epoch);
		}
		if (p_binding.connection_epoch == state.binding.connection_epoch) {
			// Equal-epoch rebinding is only an exact idempotent install.  In
			// particular, it cannot reset hello/rate/replay state.
			if (p_binding.command_allowlist != state.binding.command_allowlist) {
				return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::CONNECTION_EPOCH_MISMATCH, p_binding.connection_epoch);
			}
			return ok_status();
		}
		// A strictly newer connection epoch may reconnect the same logical
		// session. Grants, replay, and abuse budgets remain scoped to that
		// logical session; only the exact compatibility hello is re-established.
		// Reconnect must not mint a fresh command or resync burst.
		state.binding.connection_epoch = p_binding.connection_epoch;
		state.binding.command_allowlist = p_binding.command_allowlist;
		state.hello_ready = false;
		state.remote_hello = SessionHello{};
		state.touch_seq = ++touch_counter_;
		return ok_status();
	}
	// A transport reconnect may receive a different peer id while retaining the
	// same authenticated logical session. Move the complete state only for an
	// exact actor/authority match and a strictly newer connection epoch; replay,
	// grants, sequence floors, and both abuse buckets move with it.
	auto logical_session = sessions_.end();
	for (auto it = sessions_.begin(); it != sessions_.end(); ++it) {
		if (it->second.binding.session == p_binding.session) {
			logical_session = it;
			break;
		}
	}
	if (logical_session != sessions_.end()) {
		SessionState &state = logical_session->second;
		if (state.binding.actor != p_binding.actor) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::ACTOR_MISMATCH, p_binding.actor);
		}
		if (state.binding.authority_epoch != p_binding.authority_epoch) {
			return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::AUTHORITY_EPOCH_MISMATCH, p_binding.authority_epoch);
		}
		if (p_binding.connection_epoch <= state.binding.connection_epoch) {
			return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::CONNECTION_EPOCH_MISMATCH, p_binding.connection_epoch);
		}
		auto node = sessions_.extract(logical_session);
		node.key() = p_binding.peer;
		node.mapped().binding.peer = p_binding.peer;
		node.mapped().binding.connection_epoch = p_binding.connection_epoch;
		node.mapped().binding.command_allowlist = p_binding.command_allowlist;
		node.mapped().hello_ready = false;
		node.mapped().remote_hello = SessionHello{};
		node.mapped().touch_seq = ++touch_counter_;
		sessions_.insert(std::move(node));
		return ok_status();
	}
	// Tombstones apply only to a fresh logical session. A live low-id session
	// may legitimately outlast enough later retired sessions to fall below the
	// bounded tombstone floor; its reconnect was resolved above and must retain
	// grants, replay state, and abuse budgets.
	auto retired = retired_sessions_.find(p_binding.session);
	if (p_binding.session <= retired_session_floor_ ||
			(retired != retired_sessions_.end() && p_binding.authority_epoch <= retired->second)) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::SESSION_RETIRED, p_binding.session);
	}
	if (p_binding.session <= highest_session_id_) {
		return make_status(StatusCode::ALREADY_EXISTS, DiagnosticId::SESSION_RETIRED, p_binding.session);
	}
	if (sessions_.size() >= config_.max_sessions) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, sessions_.size() + 1);
	}
	SessionState state;
	state.binding = p_binding;
	state.touch_seq = ++touch_counter_;
	sessions_.emplace(p_binding.peer, std::move(state));
	highest_session_id_ = p_binding.session;
	return ok_status();
}

Status InventoryNetworkGateway::begin_session(PeerId p_peer, SessionId p_session, ActorId p_actor,
		AuthorityEpoch p_authority_epoch, ConnectionEpoch p_connection_epoch, std::uint32_t p_command_allowlist) {
	return bind_session(SessionBinding{ p_peer, p_session, p_actor, p_authority_epoch, p_connection_epoch, p_command_allowlist });
}

Status InventoryNetworkGateway::end_session(PeerId p_peer) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	auto it = sessions_.find(p_peer);
	if (it == sessions_.end()) return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_peer);
	record_retired(it->second.binding.session, it->second.binding.authority_epoch);
	for (const auto &replay : it->second.replay) replay_bytes_ -= replay.second.accounted_bytes;
	sessions_.erase(it);
	return ok_status();
}

Status InventoryNetworkGateway::drop_session(SessionId p_session) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	for (auto it = sessions_.begin(); it != sessions_.end(); ++it) {
		if (it->second.binding.session == p_session) {
			record_retired(it->second.binding.session, it->second.binding.authority_epoch);
			for (const auto &replay : it->second.replay) replay_bytes_ -= replay.second.accounted_bytes;
			sessions_.erase(it);
			return ok_status();
		}
	}
	return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_session);
}

Status InventoryNetworkGateway::clear() {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	for (const auto &entry : sessions_) {
		record_retired(entry.second.binding.session, entry.second.binding.authority_epoch);
	}
	sessions_.clear();
	replay_bytes_ = 0;
	return ok_status();
}

Status InventoryNetworkGateway::validate_context(const InboundContext &p_context, SessionState *&r_session) {
	r_session = nullptr;
	if (!positive(p_context.peer) || !positive(p_context.session) || !positive(p_context.authority_epoch) || !positive(p_context.connection_epoch)) {
		return invalid_gateway_argument();
	}
	if (p_context.tick_rate != 0 && p_context.tick_rate != config_.default_tick_rate) {
		return invalid_gateway_argument(p_context.tick_rate);
	}
	SessionState *state = find_session(p_context.peer, p_context.session);
	if (state == nullptr) return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_UNKNOWN, p_context.session);
	if (state->binding.authority_epoch != p_context.authority_epoch) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::AUTHORITY_EPOCH_MISMATCH, p_context.authority_epoch);
	}
	if (state->binding.connection_epoch != p_context.connection_epoch) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::CONNECTION_EPOCH_MISMATCH, p_context.connection_epoch);
	}
	state->touch_seq = ++touch_counter_;
	r_session = state;
	return ok_status();
}

Status InventoryNetworkGateway::validate_context(const InboundContext &p_context, const SessionState *&r_session) const {
	r_session = nullptr;
	if (!positive(p_context.peer) || !positive(p_context.session) || !positive(p_context.authority_epoch) || !positive(p_context.connection_epoch)) {
		return invalid_gateway_argument();
	}
	if (p_context.tick_rate != 0 && p_context.tick_rate != config_.default_tick_rate) {
		return invalid_gateway_argument(p_context.tick_rate);
	}
	const SessionState *state = find_session(p_context.peer, p_context.session);
	if (state == nullptr) return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_UNKNOWN, p_context.session);
	if (state->binding.authority_epoch != p_context.authority_epoch) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::AUTHORITY_EPOCH_MISMATCH, p_context.authority_epoch);
	}
	if (state->binding.connection_epoch != p_context.connection_epoch) {
		return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::CONNECTION_EPOCH_MISMATCH, p_context.connection_epoch);
	}
	r_session = state;
	return ok_status();
}

Status InventoryNetworkGateway::admit_session_hello(
		const InboundContext &p_context,
		const std::uint8_t *p_data,
		std::size_t p_size) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) return status;
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) return status;
	if (p_size > MAX_COMMAND_BYTES) return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_size);
	if (p_size != 0 && p_data == nullptr) return invalid_gateway_argument(p_size);
	ByteReader reader(p_data, p_size);
	SessionHello hello;
	status = decode_session_hello(reader, hello);
	if (!status.ok()) return status;
	status = check_session_compatibility(expected_hello_, hello);
	if (!status.ok()) {
		session->hello_ready = false;
		return status;
	}
	session->remote_hello = std::move(hello);
	session->hello_ready = true;
	return ok_status();
}

Status InventoryNetworkGateway::admit_session_hello(
		const InboundContext &p_context,
		const std::vector<std::uint8_t> &p_bytes) {
	return admit_session_hello(p_context, p_bytes.data(), p_bytes.size());
}

Status InventoryNetworkGateway::admit_session_hello(const InboundContext &p_context, const SessionHello &p_hello) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) return status;
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) return status;
	status = check_session_compatibility(expected_hello_, p_hello);
	if (!status.ok()) {
		session->hello_ready = false;
		return status;
	}
	session->remote_hello = p_hello;
	session->hello_ready = true;
	return ok_status();
}

Status InventoryNetworkGateway::reject_oversized_session_hello(
		const InboundContext &p_context, std::size_t p_packet_size) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) return status;
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) return status;
	if (p_packet_size <= MAX_COMMAND_BYTES) return invalid_gateway_argument(p_packet_size);
	return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED,
			static_cast<std::uint64_t>(p_packet_size));
}

bool InventoryNetworkGateway::session_ready(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session != nullptr && session->hello_ready;
}

Status InventoryNetworkGateway::set_command_allowlist(SessionId p_session, std::uint32_t p_allowlist) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	if ((p_allowlist & ~ALL_COMMAND_CLASSES_MASK) != 0) return invalid_gateway_argument(p_allowlist);
	SessionState *session = find_session_id(p_session);
	if (session == nullptr) return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_session);
	session->binding.command_allowlist = p_allowlist;
	session->touch_seq = ++touch_counter_;
	return ok_status();
}

std::uint32_t InventoryNetworkGateway::command_allowlist(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session == nullptr ? 0 : session->binding.command_allowlist;
}

Status InventoryNetworkGateway::grant_inventory(SessionId p_session, InventoryId p_inventory) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	if (!p_inventory) return invalid_gateway_argument();
	SessionState *session = find_session_id(p_session);
	if (session == nullptr) return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_session);
	if (session->inventory_grants.find(p_inventory) == session->inventory_grants.end() && session->inventory_grants.size() >= config_.max_inventory_grants_per_session) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, session->inventory_grants.size() + 1);
	}
	session->inventory_grants[p_inventory] = true;
	session->touch_seq = ++touch_counter_;
	return ok_status();
}

Status InventoryNetworkGateway::revoke_inventory(SessionId p_session, InventoryId p_inventory) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	SessionState *session = find_session_id(p_session);
	if (session == nullptr) return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_session);
	if (session->inventory_grants.erase(p_inventory) == 0) return make_status(StatusCode::NOT_FOUND, DiagnosticId::INVENTORY_ACCESS_DENIED, p_inventory.value);
	return ok_status();
}

bool InventoryNetworkGateway::has_inventory_grant(SessionId p_session, InventoryId p_inventory) const {
	const SessionState *session = find_session_id(p_session);
	return session != nullptr && session->inventory_grants.find(p_inventory) != session->inventory_grants.end();
}

Status InventoryNetworkGateway::invalidate_inventory(InventoryId p_inventory) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	if (!p_inventory) return invalid_gateway_argument();
	for (auto &session_entry : sessions_) {
		SessionState &session = session_entry.second;
		session.inventory_grants.erase(p_inventory);
		session.observer_grants.erase(p_inventory);
		for (auto replay = session.replay.begin(); replay != session.replay.end();) {
			const std::vector<InventoryId> &touched = replay->second.outcome.touched_inventories;
			if (std::find(touched.begin(), touched.end(), p_inventory) == touched.end()) {
				++replay;
				continue;
			}
			session.evicted_floor = std::max(session.evicted_floor, replay->first);
			replay_bytes_ -= replay->second.accounted_bytes;
			replay = session.replay.erase(replay);
		}
	}
	return ok_status();
}

Status InventoryNetworkGateway::grant_observer(SessionId p_session, InventoryId p_inventory, VisibilityScope p_visibility) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	if (!p_inventory || !valid_visibility(p_visibility)) return invalid_gateway_argument();
	SessionState *session = find_session_id(p_session);
	if (session == nullptr) return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_session);
	if (session->observer_grants.find(p_inventory) == session->observer_grants.end() && session->observer_grants.size() >= config_.max_observer_grants_per_session) {
		return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::COUNT_LIMIT_EXCEEDED, session->observer_grants.size() + 1);
	}
	session->observer_grants[p_inventory] = p_visibility;
	session->touch_seq = ++touch_counter_;
	return ok_status();
}

Status InventoryNetworkGateway::revoke_observer(SessionId p_session, InventoryId p_inventory) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	SessionState *session = find_session_id(p_session);
	if (session == nullptr) return make_status(StatusCode::NOT_FOUND, DiagnosticId::SESSION_UNKNOWN, p_session);
	if (session->observer_grants.erase(p_inventory) == 0) return make_status(StatusCode::NOT_FOUND, DiagnosticId::OBSERVER_GRANT_MISSING, p_inventory.value);
	return ok_status();
}

Status InventoryNetworkGateway::set_expected_hello(SessionHello p_expected_hello) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	expected_hello_ = std::move(p_expected_hello);
	for (auto &entry : sessions_) {
		invalidate_session_replay(entry.second);
		entry.second.hello_ready = false;
		entry.second.remote_hello = SessionHello{};
	}
	return ok_status();
}

Status InventoryNetworkGateway::set_callbacks(CanonicalCommandAllocator p_allocator,
		RevisionProvider p_revision_provider, WorldPolicy p_world_policy, CommandExecutor p_executor) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	allocator_ = std::move(p_allocator);
	revision_provider_ = std::move(p_revision_provider);
	world_policy_ = std::move(p_world_policy);
	executor_ = std::move(p_executor);
	return ok_status();
}

Status InventoryNetworkGateway::set_allocator(CanonicalCommandAllocator p_allocator) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	allocator_ = std::move(p_allocator);
	return ok_status();
}

Status InventoryNetworkGateway::set_revision_provider(RevisionProvider p_provider) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	revision_provider_ = std::move(p_provider);
	return ok_status();
}

Status InventoryNetworkGateway::set_world_policy(WorldPolicy p_policy) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	world_policy_ = std::move(p_policy);
	return ok_status();
}

Status InventoryNetworkGateway::set_executor(CommandExecutor p_executor) {
	Status busy = mutation_busy();
	if (!busy.ok()) return busy;
	executor_ = std::move(p_executor);
	return ok_status();
}

Status InventoryNetworkGateway::callback_status_begin() {
	if (callback_active_) return gateway_busy();
	callback_active_ = true;
	return ok_status();
}

void InventoryNetworkGateway::callback_status_end() {
	callback_active_ = false;
}

Status InventoryNetworkGateway::admit_bucket(TokenBucket &r_bucket, std::uint64_t p_now_tick, std::uint32_t p_tick_rate,
		std::uint32_t p_capacity, std::uint64_t p_window_seconds) {
	const std::uint64_t tick_rate = p_tick_rate == 0 ? DEFAULT_GATEWAY_TICK_RATE : p_tick_rate;
	if (p_capacity == 0 || p_window_seconds == 0 || tick_rate > std::numeric_limits<std::uint64_t>::max() / p_window_seconds) return invalid_gateway_argument();
	const std::uint64_t window_ticks = tick_rate * p_window_seconds;
	if (!r_bucket.initialized) {
		r_bucket.initialized = true;
		r_bucket.last_tick = p_now_tick;
		r_bucket.available_tokens = p_capacity;
		r_bucket.refill_remainder = 0;
	} else if (p_now_tick > r_bucket.last_tick) {
		const std::uint64_t elapsed = p_now_tick - r_bucket.last_tick;
		if (elapsed >= window_ticks) {
			r_bucket.available_tokens = p_capacity;
			r_bucket.refill_remainder = 0;
		} else if (r_bucket.available_tokens < p_capacity) {
			// Compute (elapsed * capacity + remainder) / window_ticks without
			// overflowing uint64_t.  With a uint32_t capacity this loop is
			// bounded (at most a few dozen chunks even at the largest tick rate).
			std::uint64_t remaining_multiplier = p_capacity;
			std::uint64_t added_tokens = 0;
			std::uint64_t remainder = r_bucket.refill_remainder;
			while (remaining_multiplier > 0) {
				const std::uint64_t safe_chunk = (std::numeric_limits<std::uint64_t>::max() - remainder) / elapsed;
				const std::uint64_t chunk = std::min(remaining_multiplier, std::max<std::uint64_t>(1, safe_chunk));
				const std::uint64_t numerator = remainder + elapsed * chunk;
				added_tokens += numerator / window_ticks;
				remainder = numerator % window_ticks;
				remaining_multiplier -= chunk;
			}
			const std::uint64_t missing = static_cast<std::uint64_t>(p_capacity) - r_bucket.available_tokens;
			if (added_tokens >= missing) {
				r_bucket.available_tokens = p_capacity;
				r_bucket.refill_remainder = 0;
			} else {
				r_bucket.available_tokens += added_tokens;
				r_bucket.refill_remainder = remainder;
			}
		} else {
			r_bucket.refill_remainder = 0;
		}
		r_bucket.last_tick = p_now_tick;
	}
	if (r_bucket.available_tokens == 0) return make_status(StatusCode::RATE_LIMITED, DiagnosticId::COMMAND_RATE_EXCEEDED, 0);
	--r_bucket.available_tokens;
	return ok_status();
}

Status InventoryNetworkGateway::admit_command_rate(SessionState &r_session, const InboundContext &p_context) {
	return admit_bucket(r_session.command_bucket, p_context.now_tick, config_.default_tick_rate, config_.commands_per_second, 1);
}

Status InventoryNetworkGateway::admit_resync_rate(SessionState &r_session, const InboundContext &p_context) {
	Status status = admit_bucket(r_session.resync_bucket, p_context.now_tick, config_.default_tick_rate, config_.resyncs_per_minute, 60);
	if (status.code == StatusCode::RATE_LIMITED) status.diagnostic = DiagnosticId::RESYNC_RATE_EXCEEDED;
	return status;
}

void InventoryNetworkGateway::set_rejection(GatewaySubmitOutcome &r_outcome, Status p_status, CommandId p_command_id) {
	r_outcome.status = p_status;
	r_outcome.transaction = TransactionResult{};
	r_outcome.transaction.status = p_status;
	r_outcome.transaction.command_id = p_command_id;
	r_outcome.transaction.accepted = false;
	r_outcome.transaction.replayed = false;
	r_outcome.replayed = false;
	r_outcome.local_command_id = p_command_id;
	r_outcome.canonical_command_id = CommandId{};
}

Status InventoryNetworkGateway::add_touched(std::vector<InventoryId> &r_touched, InventoryId p_inventory) {
	if (!p_inventory) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GATEWAY_TOUCHED_SET_INVALID);
	r_touched.push_back(p_inventory);
	return ok_status();
}

Status InventoryNetworkGateway::normalize_touched(std::vector<InventoryId> &r_touched) {
	if (r_touched.empty() || r_touched.size() > MAX_INVENTORIES_PER_TRANSACTION) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GATEWAY_TOUCHED_SET_INVALID, r_touched.size());
	for (InventoryId inventory : r_touched) if (!inventory) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GATEWAY_TOUCHED_SET_INVALID);
	std::sort(r_touched.begin(), r_touched.end(), [](InventoryId p_a, InventoryId p_b) { return p_a.value < p_b.value; });
	r_touched.erase(std::unique(r_touched.begin(), r_touched.end()), r_touched.end());
	if (r_touched.empty() || r_touched.size() > MAX_INVENTORIES_PER_TRANSACTION) return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::GATEWAY_TOUCHED_SET_INVALID, r_touched.size());
	return ok_status();
}

bool InventoryNetworkGateway::expected_revision_for(const std::vector<ExpectedRevision> &p_expected, InventoryId p_inventory, std::uint64_t &r_revision) {
	bool found = false;
	for (const ExpectedRevision &entry : p_expected) {
		if (entry.inventory == p_inventory) {
			if (found) return false;
			found = true;
			r_revision = entry.revision;
		}
	}
	return found;
}

Status InventoryNetworkGateway::derive_touched_inventories(const CommandEnvelope &p_envelope,
		std::vector<InventoryId> &r_touched) {
	r_touched.clear();
	const Command &command = p_envelope.command;
	Status status = ok_status();
	auto add_single_expected = [&]() -> Status {
		if (p_envelope.header.expected_revisions.size() != 1 ||
				!p_envelope.header.expected_revisions.front().inventory) {
			return make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_COVERAGE_INVALID,
					p_envelope.header.expected_revisions.size());
		}
		return add_touched(r_touched, p_envelope.header.expected_revisions.front().inventory);
	};
	auto add_explicit = [&](InventoryId p_inventory) -> Status {
		return add_touched(r_touched, p_inventory);
	};
	std::visit([&](const auto &body) {
		using T = std::decay_t<decltype(body)>;
		if constexpr (std::is_same_v<T, InsertItemCommand> || std::is_same_v<T, RemoveItemCommand> ||
				std::is_same_v<T, DropItemCommand> || std::is_same_v<T, SettleInventoryCommand> ||
				std::is_same_v<T, SetItemComponentCommand> || std::is_same_v<T, RemoveItemComponentCommand>) {
			status = make_status(StatusCode::ROLE_VIOLATION, DiagnosticId::AUTHORITY_ONLY_COMMAND,
					static_cast<std::uint64_t>(classify_command(command)));
		} else if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) {
			status = add_explicit(body.destination);
		} else if constexpr (std::is_same_v<T, QuickTransferItemCommand>) {
			status = add_explicit(body.source);
			if (status.ok()) status = add_explicit(body.destination);
		} else if constexpr (std::is_same_v<T, TargetedProviderTransferCommand>) {
			status = add_explicit(body.source);
			if (status.ok()) status = add_explicit(body.destination);
		} else if constexpr (std::is_same_v<T, LootItemCommand>) {
			status = add_explicit(body.source);
			if (status.ok()) status = add_explicit(body.destination);
		} else {
			// Move/rotate/split/merge/equip/unequip/swap and reference
			// commands are single-inventory by pipeline contract.  Their item,
			// container, or reference membership is proved by the executor;
			// this gateway never scans unbounded world state to infer it.
			status = add_single_expected();
		}
	}, command);
	if (!status.ok()) return status;
	return normalize_touched(r_touched);
}

GatewaySubmitOutcome InventoryNetworkGateway::make_replay_receipt(const GatewaySubmitOutcome &p_outcome) {
	GatewaySubmitOutcome receipt;
	receipt.status = p_outcome.status;
	receipt.replayed = false;
	receipt.local_command_id = p_outcome.local_command_id;
	receipt.canonical_command_id = p_outcome.canonical_command_id;
	receipt.touched_inventories = p_outcome.touched_inventories;

	const TransactionResult &source = p_outcome.transaction;
	TransactionResult &result = receipt.transaction;
	result.accepted = source.accepted;
	result.status = source.status;
	result.command_id = source.command_id;
	result.queued = false;
	result.replayed = source.accepted;
	if (source.revisions.size() <= MAX_INVENTORIES_PER_TRANSACTION) {
		result.revisions = source.revisions;
	} else {
		result.revisions.assign(source.revisions.begin(),
				source.revisions.begin() + MAX_INVENTORIES_PER_TRANSACTION);
	}
	// Integration events and canonical deltas are observable once only.  Drop
	// results are authority-only in this gateway, so no dropped subtree belongs
	// in a remote replay receipt either.  Keeping only bounded scalar/result
	// identity fields prevents a small request retaining a large runtime graph.
	result.new_item_id = source.new_item_id;
	result.new_reference_id = source.new_reference_id;
	result.transferred_quantity = source.transferred_quantity;
	result.remaining_quantity = source.remaining_quantity;
	result.conflicting_inventory = source.conflicting_inventory;
	result.authoritative_revision = source.authoritative_revision;
	if (source.accepted) {
		result.status = make_status(StatusCode::OK, DiagnosticId::DUPLICATE_RESULT_REPLAY,
				static_cast<std::uint64_t>(source.events.size()));
		receipt.status = result.status;
	}
	return receipt;
}

std::size_t InventoryNetworkGateway::replay_receipt_bytes(const GatewaySubmitOutcome &p_outcome) {
	ResultEnvelope envelope;
	envelope.result = p_outcome.transaction;
	ByteWriter writer(MAX_DELTA_BYTES);
	const Status status = encode_result_envelope(envelope, writer);
	if (!status.ok()) return std::numeric_limits<std::size_t>::max();
	return saturating_add(writer.bytes().size(),
			p_outcome.touched_inventories.size() * sizeof(InventoryId));
}

Status InventoryNetworkGateway::reserve_replay(SessionState &r_session, std::uint64_t p_sequence, const std::vector<std::uint8_t> &p_bytes) {
	const std::size_t accounted = saturating_add(sizeof(ReplayEntry), p_bytes.size());
	if (p_sequence == 0 || p_bytes.empty() || accounted > config_.replay_bytes_global) return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, accounted);
	ReplayEntry entry;
	entry.bytes = p_bytes;
	entry.accounted_bytes = accounted;
	entry.in_flight = true;
	entry.touch_seq = ++touch_counter_;
	r_session.replay[p_sequence] = std::move(entry);
	replay_bytes_ += accounted;
	if (p_sequence > r_session.highest_sequence) r_session.highest_sequence = p_sequence;
	while (r_session.replay.size() > config_.replay_capacity_per_session) {
		auto oldest = r_session.replay.begin();
		for (auto it = r_session.replay.begin(); it != r_session.replay.end(); ++it) {
			if (!it->second.in_flight) { oldest = it; break; }
		}
		if (oldest->second.in_flight) break;
		if (oldest->first > r_session.evicted_floor) r_session.evicted_floor = oldest->first;
		replay_bytes_ -= oldest->second.accounted_bytes;
		r_session.replay.erase(oldest);
	}
	enforce_replay_byte_cap();
	if (r_session.replay.find(p_sequence) == r_session.replay.end()) return make_status(StatusCode::LIMIT_EXCEEDED, DiagnosticId::BYTE_LIMIT_EXCEEDED, replay_bytes_);
	return ok_status();
}

void InventoryNetworkGateway::cache_outcome(SessionState &r_session, std::uint64_t p_sequence, const std::vector<std::uint8_t> &p_bytes, const GatewaySubmitOutcome &p_outcome) {
	if (p_sequence == 0) return;
	GatewaySubmitOutcome receipt = make_replay_receipt(p_outcome);
	std::size_t accounted = saturating_add(sizeof(ReplayEntry), p_bytes.size());
	accounted = saturating_add(accounted, replay_receipt_bytes(receipt));
	auto found = r_session.replay.find(p_sequence);
	if (accounted > config_.replay_bytes_global) {
		if (found != r_session.replay.end()) {
			replay_bytes_ -= found->second.accounted_bytes;
			r_session.replay.erase(found);
		}
		r_session.highest_sequence = std::max(r_session.highest_sequence, p_sequence);
		r_session.evicted_floor = std::max(r_session.evicted_floor, p_sequence);
		return;
	}
	if (found == r_session.replay.end()) {
		ReplayEntry entry;
		entry.bytes = p_bytes;
		entry.outcome = std::move(receipt);
		entry.accounted_bytes = accounted;
		entry.touch_seq = ++touch_counter_;
		r_session.replay.emplace(p_sequence, std::move(entry));
		replay_bytes_ += accounted;
	} else {
		replay_bytes_ -= found->second.accounted_bytes;
		found->second.bytes = p_bytes;
		found->second.outcome = std::move(receipt);
		found->second.accounted_bytes = accounted;
		found->second.in_flight = false;
		found->second.touch_seq = ++touch_counter_;
		replay_bytes_ += accounted;
	}
	if (p_sequence > r_session.highest_sequence) r_session.highest_sequence = p_sequence;
	while (r_session.replay.size() > config_.replay_capacity_per_session) {
		auto oldest = r_session.replay.begin();
		for (auto it = r_session.replay.begin(); it != r_session.replay.end(); ++it) {
			if (!it->second.in_flight) { oldest = it; break; }
		}
		if (oldest->second.in_flight) break;
		if (oldest->first > r_session.evicted_floor) r_session.evicted_floor = oldest->first;
		replay_bytes_ -= oldest->second.accounted_bytes;
		r_session.replay.erase(oldest);
	}
	enforce_replay_byte_cap();
}

Status InventoryNetworkGateway::reject_and_cache(SessionState &r_session, std::uint64_t p_sequence, const std::vector<std::uint8_t> &p_bytes, const GatewaySubmitOutcome &p_outcome) {
	const Status status = p_outcome.status;
	cache_outcome(r_session, p_sequence, p_bytes, p_outcome);
	return status;
}

Status InventoryNetworkGateway::submit_command_view(
		const InboundContext &p_context,
		const std::uint8_t *p_data,
		std::size_t p_size,
		GatewaySubmitOutcome &r_outcome) {
	r_outcome = GatewaySubmitOutcome{};
	if (processing_) {
		Status status = gateway_busy();
		set_rejection(r_outcome, status);
		return status;
	}
	ProcessingGuard processing(processing_);
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	// Rate accounting is deliberately before hello readiness, size checking,
	// and decoding so a bound pre-handshake sender cannot obtain free work.
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	if (!session->hello_ready) { status = make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_HELLO_REQUIRED); set_rejection(r_outcome, status); return status; }
	if (p_size > MAX_COMMAND_BYTES) { status = make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_size); set_rejection(r_outcome, status); return status; }
	if (p_size != 0 && p_data == nullptr) { status = invalid_gateway_argument(p_size); set_rejection(r_outcome, status); return status; }
	ByteReader reader(p_data, p_size);
	CommandEnvelope envelope;
	status = decode_command_envelope(reader, envelope);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	// Exact bytes are retained only after authenticated rate/hello/size/decode
	// admission, but before any game callback. This both avoids allocating for
	// early rejection and prevents a callback with a non-const alias to caller
	// storage from rewriting the replay key underneath the decoded command.
	std::vector<std::uint8_t> owned_bytes;
	if (p_size != 0) owned_bytes.assign(p_data, p_data + p_size);
	return submit_decoded(*session, owned_bytes, envelope, r_outcome);
}

Status InventoryNetworkGateway::submit_command(
		const InboundContext &p_context,
		const std::uint8_t *p_data,
		std::size_t p_size,
		GatewaySubmitOutcome &r_outcome) {
	return submit_command_view(p_context, p_data, p_size, r_outcome);
}

Status InventoryNetworkGateway::submit_command(
		const InboundContext &p_context,
		const std::vector<std::uint8_t> &p_bytes,
		GatewaySubmitOutcome &r_outcome) {
	return submit_command_view(p_context, p_bytes.data(), p_bytes.size(), r_outcome);
}

Status InventoryNetworkGateway::submit_command(const InboundContext &p_context, const CommandEnvelope &p_envelope, GatewaySubmitOutcome &r_outcome) {
	r_outcome = GatewaySubmitOutcome{};
	if (processing_) { Status status = gateway_busy(); set_rejection(r_outcome, status); return status; }
	ProcessingGuard processing(processing_);
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	if (!session->hello_ready) { status = make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_HELLO_REQUIRED); set_rejection(r_outcome, status); return status; }
	// The convenience DTO is caller-owned. Snapshot it before encoding and
	// before any callback so a captured non-const alias cannot change the
	// command after its allowlist/grant/revision gates have run.
	const CommandEnvelope envelope = p_envelope;
	ByteWriter writer(MAX_COMMAND_BYTES);
	status = encode_command_envelope(envelope, writer);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	return submit_decoded(*session, writer.bytes(), envelope, r_outcome);
}

Status InventoryNetworkGateway::reject_oversized_command(const InboundContext &p_context,
		std::size_t p_packet_size, GatewaySubmitOutcome &r_outcome) {
	r_outcome = GatewaySubmitOutcome{};
	if (processing_) {
		Status status = gateway_busy();
		set_rejection(r_outcome, status);
		return status;
	}
	ProcessingGuard processing(processing_);
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	if (!session->hello_ready) {
		status = make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_HELLO_REQUIRED);
		set_rejection(r_outcome, status);
		return status;
	}
	if (p_packet_size <= MAX_COMMAND_BYTES) {
		status = invalid_gateway_argument(p_packet_size);
		set_rejection(r_outcome, status);
		return status;
	}
	status = make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED,
			static_cast<std::uint64_t>(p_packet_size));
	set_rejection(r_outcome, status);
	return status;
}

Status InventoryNetworkGateway::reject_unready_command(
		const InboundContext &p_context, GatewaySubmitOutcome &r_outcome) {
	r_outcome = GatewaySubmitOutcome{};
	if (processing_) {
		const Status status = gateway_busy();
		set_rejection(r_outcome, status);
		return status;
	}
	ProcessingGuard processing(processing_);
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	status = admit_command_rate(*session, p_context);
	if (!status.ok()) { set_rejection(r_outcome, status); return status; }
	if (session->hello_ready) {
		status = invalid_gateway_argument();
	} else {
		status = make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_HELLO_REQUIRED);
	}
	set_rejection(r_outcome, status);
	return status;
}

Status InventoryNetworkGateway::submit_decoded(SessionState &r_session, const std::vector<std::uint8_t> &p_bytes, const CommandEnvelope &p_envelope, GatewaySubmitOutcome &r_outcome) {
	r_outcome = GatewaySubmitOutcome{};
	const CommandId local_id = p_envelope.header.command_id;
	if (!local_id) { Status status = invalid_gateway_argument(); set_rejection(r_outcome, status, local_id); return status; }
	r_outcome.local_command_id = local_id;
	r_outcome.transaction.command_id = local_id;
	if (p_envelope.protocol_version != PROTOCOL_VERSION) {
		Status status = make_status(StatusCode::PROTOCOL_MISMATCH, DiagnosticId::PROTOCOL_VERSION_DIFFERS, p_envelope.protocol_version);
		set_rejection(r_outcome, status, local_id);
		// Version-invalid bytes are outside the authenticated command domain and
		// must never consume or replace a client sequence.
		return status;
	}
	if (p_envelope.header.actor != r_session.binding.actor) {
		Status status = make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::ACTOR_MISMATCH, p_envelope.header.actor);
		set_rejection(r_outcome, status, local_id);
		// An unauthenticated actor echo must never reserve or poison a sequence in
		// the authenticated session's replay domain.
		return status;
	}

	const CommandClass command_class = classify_command(p_envelope.command);
	if ((r_session.binding.command_allowlist & command_class_bit(command_class)) == 0) {
		Status status = make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::COMMAND_NOT_ALLOWLISTED, static_cast<std::uint64_t>(command_class));
		set_rejection(r_outcome, status, local_id);
		return status;
	}
	if (is_authority_only(command_class)) {
		Status status = make_status(StatusCode::ROLE_VIOLATION, DiagnosticId::AUTHORITY_ONLY_COMMAND, static_cast<std::uint64_t>(command_class));
		set_rejection(r_outcome, status, local_id);
		return status;
	}

	// The touched set is intrinsic to the command shape.  For commands whose
	// item/container/reference membership is single-inventory, the exact sole
	// expected-revision target is the touched inventory; multi-inventory
	// transfer shapes carry both source and destination explicitly.
	Status status = ok_status();
	std::vector<InventoryId> touched;
	status = derive_touched_inventories(p_envelope, touched);
	if (!status.ok()) {
		set_rejection(r_outcome, status, local_id);
		return status;
	}
	r_outcome.touched_inventories = touched;
	for (InventoryId inventory : touched) {
		if (r_session.inventory_grants.find(inventory) == r_session.inventory_grants.end()) {
			Status denied = make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::INVENTORY_ACCESS_DENIED, inventory.value);
			set_rejection(r_outcome, denied, local_id);
			r_outcome.touched_inventories = touched;
			return denied;
		}
	}

	// Sequence identity is intentionally checked only after the live allowlist
	// and every derived inventory grant.  Otherwise permission revocation would
	// expose whether attacker-selected bytes matched a private replay entry.
	auto replay = r_session.replay.find(local_id.value);
	if (replay != r_session.replay.end() && replay->second.bytes != p_bytes) {
		Status conflict = make_status(StatusCode::DUPLICATE_COMMAND, DiagnosticId::COMMAND_SEQUENCE_CONFLICT, local_id.value);
		set_rejection(r_outcome, conflict, local_id);
		r_outcome.touched_inventories = touched;
		return conflict;
	}
	if (replay == r_session.replay.end() &&
			(local_id.value <= r_session.evicted_floor || local_id.value <= r_session.highest_sequence)) {
		Status stale = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::COMMAND_SEQUENCE_STALE, local_id.value);
		set_rejection(r_outcome, stale, local_id);
		r_outcome.touched_inventories = touched;
		return stale;
	}
	// A cached exact command is allowed to replay only after the live session,
	// actor, allowlist, intrinsic touched set, and every grant still match.
	if (replay != r_session.replay.end()) {
		if (replay->second.in_flight) {
			Status in_flight = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::COMMAND_REPLAY_IN_FLIGHT, local_id.value);
			set_rejection(r_outcome, in_flight, local_id);
			return in_flight;
		}
		r_outcome = replay->second.outcome;
		r_outcome.replayed = true;
		return r_outcome.status;
	}

	if (p_envelope.header.expected_revisions.size() > MAX_INVENTORIES_PER_TRANSACTION || p_envelope.header.expected_revisions.size() != touched.size()) {
		Status coverage = make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_COVERAGE_INVALID, p_envelope.header.expected_revisions.size());
		set_rejection(r_outcome, coverage, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	for (const ExpectedRevision &expected : p_envelope.header.expected_revisions) {
		std::uint64_t expected_revision = 0;
		if (!expected.inventory || !expected_revision_for(p_envelope.header.expected_revisions, expected.inventory, expected_revision)) {
			Status coverage = make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_COVERAGE_INVALID, expected.inventory.value);
			set_rejection(r_outcome, coverage, local_id);
			r_outcome.touched_inventories = touched;
			return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
		}
		if (std::find(touched.begin(), touched.end(), expected.inventory) == touched.end()) {
			Status coverage = make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_COVERAGE_INVALID, expected.inventory.value);
			set_rejection(r_outcome, coverage, local_id);
			r_outcome.touched_inventories = touched;
			return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
		}
	}

	// Reserve before any revision/policy/allocator/executor callback.  A
	// synchronous callback attempting the same local sequence is therefore
	// never able to enter the executor a second time.
	status = reserve_replay(r_session, local_id.value, p_bytes);
	if (!status.ok()) { set_rejection(r_outcome, status, local_id); return status; }

	if (!revision_provider_) {
		status = missing_callback();
		set_rejection(r_outcome, status, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	std::vector<std::uint64_t> current;
	current.reserve(touched.size());
	for (InventoryId inventory : touched) {
		std::uint64_t revision = 0;
		status = callback_status_begin();
		if (status.ok()) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
			try {
				status = revision_provider_(inventory, revision);
			} catch (...) {
				status = missing_callback();
			}
#else
			status = revision_provider_(inventory, revision);
#endif
		}
		callback_status_end();
		if (!status.ok()) {
			set_rejection(r_outcome, status, local_id);
			r_outcome.touched_inventories = touched;
			return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
		}
		current.push_back(revision);
	}
	for (std::size_t i = 0; i < touched.size(); ++i) {
		std::uint64_t expected_revision = 0;
		if (!expected_revision_for(p_envelope.header.expected_revisions, touched[i], expected_revision)) continue;
		if (expected_revision != current[i]) {
			Status stale = make_status(StatusCode::REVISION_MISMATCH, DiagnosticId::REVISION_STALE, touched[i].value);
			set_rejection(r_outcome, stale, local_id);
			r_outcome.touched_inventories = touched;
			for (std::size_t j = 0; j < touched.size(); ++j) r_outcome.transaction.revisions.push_back(RevisionOutcome{ touched[j], current[j], current[j] });
			r_outcome.transaction.conflicting_inventory = touched[i];
			r_outcome.transaction.authoritative_revision = current[i];
			return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
		}
	}
	if (!world_policy_) {
		status = missing_callback();
		set_rejection(r_outcome, status, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	const CommandIdentity identity{
			r_session.binding.peer,
			r_session.binding.session,
			r_session.binding.actor,
			r_session.binding.authority_epoch,
			r_session.binding.connection_epoch,
			local_id };
	WorldPolicyRequest policy;
	policy.identity = identity;
	policy.envelope = p_envelope;
	policy.command_class = command_class;
	policy.touched_inventories = touched;
	policy.current_revisions = current;
	status = callback_status_begin();
	if (status.ok()) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
		try {
			status = world_policy_(policy);
		} catch (...) {
			status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::GATEWAY_CALLBACK_MISSING);
		}
#else
		status = world_policy_(policy);
#endif
	}
	callback_status_end();
	if (!status.ok()) {
		set_rejection(r_outcome, status, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	if (!allocator_ || !executor_) {
		status = missing_callback();
		set_rejection(r_outcome, status, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	CommandId canonical;
	status = callback_status_begin();
	if (status.ok()) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
		try {
			status = allocator_(identity, canonical);
		} catch (...) {
			status = missing_callback();
		}
#else
		status = allocator_(identity, canonical);
#endif
	}
	callback_status_end();
	if (!status.ok()) {
		set_rejection(r_outcome, status, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	if (!canonical) {
		status = make_status(StatusCode::INTERNAL_ERROR, DiagnosticId::COMMAND_ID_ALLOCATOR_FAILED);
		set_rejection(r_outcome, status, local_id);
		r_outcome.touched_inventories = touched;
		return reject_and_cache(r_session, local_id.value, p_bytes, r_outcome);
	}
	CommandExecutionRequest execution;
	execution.identity = identity;
	execution.canonical_command_id = canonical;
	execution.envelope = p_envelope;
	execution.envelope.header.actor = r_session.binding.actor;
	execution.envelope.header.command_id = canonical;
	execution.command_class = command_class;
	execution.touched_inventories = touched;
	execution.current_revisions = current;
	TransactionResult transaction;
	bool executor_returned = false;
	status = callback_status_begin();
	if (status.ok()) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS) || defined(_CPPUNWIND)
		try {
			transaction = executor_(execution);
			executor_returned = true;
		} catch (...) {
			status = missing_callback();
		}
#else
		transaction = executor_(execution);
		executor_returned = true;
#endif
	}
	callback_status_end();
	transaction.command_id = canonical;
	if (!executor_returned) {
		transaction.accepted = false;
		transaction.queued = false;
		transaction.status = status;
	} else if (transaction.queued) {
		status = make_status(StatusCode::COMMAND_REJECTED, DiagnosticId::GATEWAY_REENTRANT);
		transaction.accepted = false;
		transaction.queued = false;
		transaction.status = status;
	} else {
		status = transaction.status;
	}
	r_outcome.status = status;
	r_outcome.transaction = std::move(transaction);
	r_outcome.canonical_command_id = canonical;
	r_outcome.touched_inventories = touched;
	r_outcome.replayed = false;
	cache_outcome(r_session, local_id.value, p_bytes, r_outcome);
	return r_outcome.status;
}

Status InventoryNetworkGateway::admit_observer_resync(
		const InboundContext &p_context,
		const std::uint8_t *p_data,
		std::size_t p_size,
		ObserverAdmission &r_admission) {
	r_admission = ObserverAdmission{};
	if (processing_) {
		r_admission.status = gateway_busy();
		return r_admission.status;
	}
	ProcessingGuard processing(processing_);
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) { r_admission.status = status; return status; }
	status = admit_resync_rate(*session, p_context);
	if (!status.ok()) { r_admission.status = status; return status; }
	if (!session->hello_ready) { status = make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_HELLO_REQUIRED); r_admission.status = status; return status; }
	if (!has_feature(expected_hello_.required_feature_bits, ProtocolFeature::OBSERVER_REPLICATION)) {
		status = make_status(StatusCode::FEATURE_UNSUPPORTED, DiagnosticId::OBSERVER_FEATURE_REQUIRED);
		r_admission.status = status;
		return status;
	}
	if (p_size > MAX_OBSERVER_RESYNC_BYTES) { status = make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_size); r_admission.status = status; return status; }
	if (p_size != 0 && p_data == nullptr) { status = invalid_gateway_argument(p_size); r_admission.status = status; return status; }
	ByteReader reader(p_data, p_size);
	ObserverResyncRequest request;
	status = decode_observer_resync_request(reader, request);
	if (!status.ok()) { r_admission.status = status; return status; }
	if (request.recipient.session_id != session->binding.session || request.recipient.actor_id != session->binding.actor) {
		status = make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::RESYNC_IDENTITY_MISMATCH);
		r_admission.status = status;
		return status;
	}
	auto grant = session->observer_grants.find(InventoryId{ request.inventory_id });
	if (grant == session->observer_grants.end()) {
		status = make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::OBSERVER_GRANT_MISSING, request.inventory_id);
		r_admission.status = status;
		return status;
	}
	r_admission.request = std::move(request);
	r_admission.visibility = grant->second;
	r_admission.status = ok_status();
	return ok_status();
}

Status InventoryNetworkGateway::admit_observer_resync(
		const InboundContext &p_context,
		const std::vector<std::uint8_t> &p_bytes,
		ObserverAdmission &r_admission) {
	return admit_observer_resync(p_context, p_bytes.data(), p_bytes.size(), r_admission);
}

Status InventoryNetworkGateway::admit_resync_context(const InboundContext &p_context) {
	if (processing_) return gateway_busy();
	ProcessingGuard processing(processing_);
	SessionState *session = nullptr;
	Status status = validate_context(p_context, session);
	if (!status.ok()) return status;
	status = admit_resync_rate(*session, p_context);
	if (!status.ok()) return status;
	if (!session->hello_ready) return make_status(StatusCode::SESSION_NOT_READY, DiagnosticId::SESSION_HELLO_REQUIRED);
	return ok_status();
}

std::size_t InventoryNetworkGateway::inventory_grant_count(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session == nullptr ? 0 : session->inventory_grants.size();
}

std::size_t InventoryNetworkGateway::observer_grant_count(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session == nullptr ? 0 : session->observer_grants.size();
}

std::size_t InventoryNetworkGateway::replay_entry_count(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session == nullptr ? 0 : session->replay.size();
}

std::uint64_t InventoryNetworkGateway::highest_sequence(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session == nullptr ? 0 : session->highest_sequence;
}

std::uint64_t InventoryNetworkGateway::evicted_sequence_floor(SessionId p_session) const {
	const SessionState *session = find_session_id(p_session);
	return session == nullptr ? 0 : session->evicted_floor;
}

CommandClass InventoryNetworkGateway::classify_command(const Command &p_command) {
	return std::visit([](const auto &body) -> CommandClass {
		using T = std::decay_t<decltype(body)>;
		if constexpr (std::is_same_v<T, MoveItemCommand>) return CommandClass::MOVE_ITEM;
		if constexpr (std::is_same_v<T, RotateItemCommand>) return CommandClass::ROTATE_ITEM;
		if constexpr (std::is_same_v<T, SplitStackCommand>) return CommandClass::SPLIT_STACK;
		if constexpr (std::is_same_v<T, MergeStacksCommand>) return CommandClass::MERGE_STACKS;
		if constexpr (std::is_same_v<T, InsertItemCommand>) return CommandClass::INSERT_ITEM;
		if constexpr (std::is_same_v<T, RemoveItemCommand>) return CommandClass::REMOVE_ITEM;
		if constexpr (std::is_same_v<T, EquipItemCommand>) return CommandClass::EQUIP_ITEM;
		if constexpr (std::is_same_v<T, UnequipItemCommand>) return CommandClass::UNEQUIP_ITEM;
		if constexpr (std::is_same_v<T, SwapItemsCommand>) return CommandClass::SWAP_ITEMS;
		if constexpr (std::is_same_v<T, AutoPlaceItemCommand>) return CommandClass::AUTO_PLACE_ITEM;
		if constexpr (std::is_same_v<T, QuickTransferItemCommand>) return CommandClass::QUICK_TRANSFER_ITEM;
		if constexpr (std::is_same_v<T, TargetedProviderTransferCommand>) return CommandClass::TARGETED_PROVIDER_TRANSFER;
		if constexpr (std::is_same_v<T, LootItemCommand>) return CommandClass::LOOT_ITEM;
		if constexpr (std::is_same_v<T, DropItemCommand>) return CommandClass::DROP_ITEM;
		if constexpr (std::is_same_v<T, SettleInventoryCommand>) return CommandClass::SETTLE_INVENTORY;
		if constexpr (std::is_same_v<T, AssignReferenceCommand>) return CommandClass::ASSIGN_REFERENCE;
		if constexpr (std::is_same_v<T, ClearReferenceCommand>) return CommandClass::CLEAR_REFERENCE;
		if constexpr (std::is_same_v<T, SetItemComponentCommand>) return CommandClass::SET_ITEM_COMPONENT;
		return CommandClass::REMOVE_ITEM_COMPONENT;
	}, p_command);
}

bool InventoryNetworkGateway::is_authority_only(CommandClass p_class) {
	return p_class == CommandClass::INSERT_ITEM || p_class == CommandClass::REMOVE_ITEM || p_class == CommandClass::DROP_ITEM ||
			p_class == CommandClass::SETTLE_INVENTORY || p_class == CommandClass::SET_ITEM_COMPONENT || p_class == CommandClass::REMOVE_ITEM_COMPONENT;
}

} // namespace inv::protocol
