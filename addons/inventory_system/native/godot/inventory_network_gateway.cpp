#include "godot/inventory_network_gateway.h"

#include "core/inv_deltas.h"
#include "core/inv_limits.h"
#include "godot/inventory_godot_util.h"
#include "protocol/inv_observer_protocol.h"
#include "protocol/inv_protocol_codec.h"
#include "protocol/inv_protocol_types.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cstring>
#include <limits>
#include <type_traits>
#include <utility>

namespace godot {

namespace {

constexpr std::uint64_t SCRIPT_MAX = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());

Dictionary safe_status_dict(const inv::Status &p_status) {
	Dictionary d;
	d["code"] = static_cast<int>(p_status.code);
	d["diagnostic"] = static_cast<int>(p_status.diagnostic);
	// A hostile u64 detail must never wrap into a misleading negative Variant
	// integer.  The explicit marker keeps the result useful without exposing a
	// value the script façade cannot represent.
	const bool in_range = p_status.detail <= SCRIPT_MAX;
	d["detail"] = in_range ? static_cast<int64_t>(p_status.detail) : int64_t(0);
	d["detail_out_of_range"] = !in_range;
	d["ok"] = p_status.ok();
	return d;
}

inv::Status authority_status(const InventoryAuthority *p_authority, const inv::Status &p_fallback) {
	if (p_authority == nullptr) {
		return p_fallback;
	}
	const Dictionary d = p_authority->get_last_status();
	if (!d.has("code")) {
		return p_fallback;
	}
	const int code = int(d.get("code", int(inv::StatusCode::INTERNAL_ERROR)));
	const int diagnostic = int(d.get("diagnostic", int(inv::DiagnosticId::NONE)));
	const int64_t detail = int64_t(d.get("detail", int64_t(0)));
	return inv::make_status(
			static_cast<inv::StatusCode>(code),
			static_cast<inv::DiagnosticId>(diagnostic),
			detail < 0 ? 0 : static_cast<std::uint64_t>(detail));
}

bool dictionary_ok(const Dictionary &p_dictionary) {
	return bool(p_dictionary.get("ok", false));
}

bool observer_wire_prefix(const PackedByteArray &p_bytes) {
	const std::string magic = inv::protocol::OBSERVER_PROTOCOL_MAGIC;
	if (p_bytes.size() < 6) {
		return false;
	}
	const std::uint16_t protocol = static_cast<std::uint16_t>(p_bytes.get(0)) |
			(static_cast<std::uint16_t>(p_bytes.get(1)) << 8);
	const std::uint32_t magic_size = static_cast<std::uint32_t>(p_bytes.get(2)) |
			(static_cast<std::uint32_t>(p_bytes.get(3)) << 8) |
			(static_cast<std::uint32_t>(p_bytes.get(4)) << 16) |
			(static_cast<std::uint32_t>(p_bytes.get(5)) << 24);
	if (protocol != inv::protocol::OBSERVER_PROTOCOL_VERSION || magic_size != magic.size() ||
			p_bytes.size() < 6 + static_cast<int64_t>(magic.size())) {
		return false;
	}
	for (std::size_t i = 0; i < magic.size(); ++i) {
		if (p_bytes.get(static_cast<int64_t>(6 + i)) != static_cast<std::uint8_t>(magic[i])) {
			return false;
		}
	}
	return true;
}

struct GodotProcessingScope {
	bool &flag;
	explicit GodotProcessingScope(bool &p_flag) : flag(p_flag) { flag = true; }
	~GodotProcessingScope() { flag = false; }
};

struct ObserverEgressMetadata {
	std::uint64_t generation = 0;
	std::uint64_t sequence = 0;
};

bool observer_egress_identity_matches(
		const inv::protocol::ObserverSnapshot &p_snapshot,
		const inv::DiscoveryRecipientKey &p_recipient,
		std::uint64_t p_inventory,
		inv::VisibilityScope p_visibility) {
	return p_snapshot.inventory_id == p_inventory &&
			p_snapshot.visibility == p_visibility &&
			p_snapshot.generation != 0 && p_snapshot.sequence != 0 &&
			p_recipient.session_id != 0 && p_recipient.actor_id != 0;
}

bool observer_recipient_matches(
		const inv::DiscoveryRecipientKey &p_actual,
		const inv::DiscoveryRecipientKey &p_expected) {
	return p_actual.session_id == p_expected.session_id &&
			p_actual.actor_id == p_expected.actor_id;
}

inv::Status observer_snapshot_metadata(
		const PackedByteArray &p_bytes,
		const inv::DiscoveryRecipientKey &p_expected_recipient,
		std::uint64_t p_inventory,
		inv::VisibilityScope p_visibility,
		ObserverEgressMetadata &r_metadata) {
	r_metadata = ObserverEgressMetadata{};
	if (p_bytes.is_empty() || p_bytes.size() > static_cast<int64_t>(inv::MAX_OBSERVER_SNAPSHOT_BYTES)) {
		return inv::make_status(inv::StatusCode::DECODE_FAILED, inv::DiagnosticId::BYTE_LIMIT_EXCEEDED);
	}
	const std::vector<std::uint8_t> raw = from_packed(p_bytes);
	inv::ByteReader reader(raw);
	inv::protocol::ObserverSnapshotEnvelope envelope;
	inv::Status status = inv::protocol::decode_observer_snapshot(reader, envelope);
	if (!status.ok()) return status;
	if (!observer_recipient_matches(envelope.recipient, p_expected_recipient) ||
			!observer_egress_identity_matches(envelope.snapshot, envelope.recipient, p_inventory, p_visibility)) {
		return inv::make_status(inv::StatusCode::INVARIANT_VIOLATION, inv::DiagnosticId::RESYNC_IDENTITY_MISMATCH);
	}
	r_metadata.generation = envelope.snapshot.generation;
	r_metadata.sequence = envelope.snapshot.sequence;
	return inv::ok_status();
}

inv::Status observer_delta_metadata(
		const PackedByteArray &p_bytes,
		const inv::DiscoveryRecipientKey &p_expected_recipient,
		std::uint64_t p_inventory,
		inv::VisibilityScope p_visibility,
		std::uint64_t p_expected_predecessor,
		ObserverEgressMetadata &r_metadata) {
	r_metadata = ObserverEgressMetadata{};
	if (p_bytes.is_empty() || p_bytes.size() > static_cast<int64_t>(inv::MAX_OBSERVER_DELTA_BYTES)) {
		return inv::make_status(inv::StatusCode::DECODE_FAILED, inv::DiagnosticId::BYTE_LIMIT_EXCEEDED);
	}
	const std::vector<std::uint8_t> raw = from_packed(p_bytes);
	inv::ByteReader reader(raw);
	inv::protocol::ObserverDeltaEnvelope envelope;
	inv::Status status = inv::protocol::decode_observer_delta(reader, envelope);
	if (!status.ok()) return status;
	if (!observer_recipient_matches(envelope.recipient, p_expected_recipient) ||
			!observer_egress_identity_matches(envelope.snapshot, envelope.recipient, p_inventory, p_visibility) ||
			envelope.predecessor_sequence != p_expected_predecessor ||
			envelope.successor_sequence != envelope.snapshot.sequence) {
		return inv::make_status(inv::StatusCode::INVARIANT_VIOLATION, inv::DiagnosticId::RESYNC_IDENTITY_MISMATCH);
	}
	r_metadata.generation = envelope.snapshot.generation;
	r_metadata.sequence = envelope.successor_sequence;
	return inv::ok_status();
}

PackedByteArray bytes_from_dictionary(const Dictionary &p_dictionary) {
	return PackedByteArray(p_dictionary.get("bytes", PackedByteArray()));
}

} // namespace

InventoryNetworkGateway::InventoryNetworkGateway() {}

InventoryNetworkGateway::~InventoryNetworkGateway() {
	InventoryAuthority *authority = resolve_bound_authority();
	if (authority != nullptr) {
		for (auto &entry : sessions) {
			teardown_discovery(entry.second, authority);
		}
	}
	unbind_authority_lifecycle();
	if (gateway != nullptr) {
		gateway->clear();
	}
	sessions.clear();
	peer_to_session.clear();
}

void InventoryNetworkGateway::set_authority_path(const NodePath &p_path) {
	if (authority_path == p_path) {
		return;
	}
	// A live authenticated binding must never silently migrate to a different
	// authority.  The setter is intentionally void for scene/property parity;
	// callers can observe the unchanged path and status through later calls.
	if (processing || !sessions.empty() || gateway != nullptr) {
		return;
	}
	authority_path = p_path;
}

void InventoryNetworkGateway::set_world_policy(const Callable &p_policy) {
	if (processing) {
		return;
	}
	world_policy = p_policy;
}

bool InventoryNetworkGateway::set_authority_epoch(int64_t p_epoch) {
	if (processing || !valid_positive(p_epoch)) {
		return false;
	}
	if (authority_epoch_configured && authority_epoch != p_epoch) {
		return false;
	}
	authority_epoch = p_epoch;
	authority_epoch_configured = true;
	return true;
}

bool InventoryNetworkGateway::set_tick_rate(int64_t p_tick_rate) {
	if (processing || !valid_tick(p_tick_rate)) {
		return false;
	}
	if (tick_rate_configured && tick_rate != p_tick_rate) {
		return false;
	}
	tick_rate = p_tick_rate;
	tick_rate_configured = true;
	return true;
}

Dictionary InventoryNetworkGateway::configure(int64_t p_authority_epoch, int64_t p_tick_rate) {
	// Validate the complete configuration before committing either field.  A
	// rejected initial call must not leave an epoch half-installed and make a
	// corrected retry impossible.
	if (processing || !valid_positive(p_authority_epoch) || !valid_tick(p_tick_rate) ||
			(authority_epoch_configured && authority_epoch != p_authority_epoch) ||
			(tick_rate_configured && tick_rate != p_tick_rate)) {
		return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	authority_epoch = p_authority_epoch;
	tick_rate = p_tick_rate;
	authority_epoch_configured = true;
	tick_rate_configured = true;
	return status_result(inv::ok_status(), true);
}

InventoryAuthority *InventoryNetworkGateway::resolve_authority() const {
	if (authority_path.is_empty()) {
		return nullptr;
	}
	Node *node = get_node_or_null(authority_path);
	return Object::cast_to<InventoryAuthority>(node);
}

InventoryAuthority *InventoryNetworkGateway::resolve_bound_authority() const {
	if (callbacks_authority_id == ObjectID()) return nullptr;
	return Object::cast_to<InventoryAuthority>(ObjectDB::get_instance(callbacks_authority_id));
}

bool InventoryNetworkGateway::check_bound_authority(InventoryAuthority *p_authority, inv::Status &r_status) const {
	if (p_authority == nullptr) {
		r_status = inv::make_status(inv::StatusCode::NOT_FOUND);
		return false;
	}
	if (gateway == nullptr || callbacks_authority_id == ObjectID()) {
		r_status = inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_UNKNOWN);
		return false;
	}
	if (ObjectID(p_authority->get_instance_id()) != callbacks_authority_id) {
		r_status = inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::AUTHORITY_EPOCH_MISMATCH);
		return false;
	}
	r_status = inv::ok_status();
	return true;
}

bool InventoryNetworkGateway::bind_authority_lifecycle(InventoryAuthority *p_authority) {
	if (p_authority == nullptr) return false;
	const Callable callback = callable_mp(this, &InventoryNetworkGateway::_on_inventory_generation_invalidated);
	const StringName signals[] = {
		StringName("inventory_unloaded"),
		StringName("inventory_generation_changing"),
	};
	for (const StringName &signal : signals) {
		if (!p_authority->is_connected(signal, callback) && p_authority->connect(signal, callback) != OK) {
			for (const StringName &rollback : signals) {
				if (p_authority->is_connected(rollback, callback)) p_authority->disconnect(rollback, callback);
			}
			return false;
		}
	}
	return true;
}

void InventoryNetworkGateway::unbind_authority_lifecycle() {
	InventoryAuthority *authority = resolve_bound_authority();
	if (authority != nullptr) {
		const Callable callback = callable_mp(this, &InventoryNetworkGateway::_on_inventory_generation_invalidated);
		const StringName signals[] = {
			StringName("inventory_unloaded"),
			StringName("inventory_generation_changing"),
		};
		for (const StringName &signal : signals) {
			if (authority->is_connected(signal, callback)) authority->disconnect(signal, callback);
		}
	}
}

void InventoryNetworkGateway::_on_inventory_generation_invalidated(int64_t p_inventory) {
	if (p_inventory <= 0) return;
	const std::uint64_t inventory = static_cast<std::uint64_t>(p_inventory);
	for (auto &entry : sessions) entry.second.replication_grants.erase(inventory);
	if (processing) {
		// A policy callback can synchronously replace/unload a runtime.  Latch a
		// bounded fail-closed reset; invoke_world_policy() observes this before
		// allocator/executor admission and submit_command_bytes() flushes it once
		// the core processing guard has unwound.
		pending_lifecycle_reset = true;
		return;
	}
	if (gateway != nullptr) {
		last_status = gateway->invalidate_inventory(inv::InventoryId{ inventory });
	}
}

void InventoryNetworkGateway::flush_pending_lifecycle_reset() {
	if (!pending_lifecycle_reset) return;
	pending_lifecycle_reset = false;
	InventoryAuthority *authority = resolve_bound_authority();
	if (authority != nullptr) {
		for (auto &entry : sessions) teardown_discovery(entry.second, authority);
	}
	if (gateway != nullptr) gateway->clear();
	sessions.clear();
	peer_to_session.clear();
}

bool InventoryNetworkGateway::valid_positive(int64_t p_value) const {
	return p_value > 0;
}

bool InventoryNetworkGateway::valid_u32_mask(int64_t p_value) const {
	return p_value >= 0 && static_cast<std::uint64_t>(p_value) <= inv::protocol::ALL_COMMAND_CLASSES_MASK;
}

bool InventoryNetworkGateway::valid_tick(int64_t p_value) const {
	return p_value > 0 && static_cast<std::uint64_t>(p_value) <= std::numeric_limits<std::uint32_t>::max();
}

bool InventoryNetworkGateway::valid_now_tick(int64_t p_value) const {
	return p_value >= 0;
}

bool InventoryNetworkGateway::check_transport_session(
		int64_t p_peer,
		int64_t p_session,
		int64_t p_connection_epoch,
		const SessionRecord *&r_record,
		inv::Status &r_status) const {
	r_record = nullptr;
	if (!valid_positive(p_peer) || !valid_positive(p_session) || !valid_positive(p_connection_epoch)) {
		r_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return false;
	}
	const SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr || record->peer != static_cast<std::uint64_t>(p_peer)) {
		r_status = inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_UNKNOWN,
				static_cast<std::uint64_t>(p_session));
		return false;
	}
	if (record->connection_epoch != static_cast<std::uint64_t>(p_connection_epoch)) {
		r_status = inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::CONNECTION_EPOCH_MISMATCH,
				static_cast<std::uint64_t>(p_connection_epoch));
		return false;
	}
	r_record = record;
	r_status = inv::ok_status();
	return true;
}

bool InventoryNetworkGateway::check_server_authority(inv::Status &r_status) const {
	InventoryAuthority *authority = resolve_authority();
	if (authority == nullptr) {
		r_status = inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::SESSION_UNKNOWN);
		return false;
	}
	if (authority->get_role() != InventoryAuthority::ROLE_SERVER_AUTHORITY) {
		r_status = inv::make_status(inv::StatusCode::ROLE_VIOLATION, inv::DiagnosticId::AUTHORITY_CALLBACK_FORBIDDEN);
		return false;
	}
	r_status = inv::ok_status();
	return true;
}

bool InventoryNetworkGateway::check_configured(inv::Status &r_status) const {
	if (!authority_epoch_configured || !tick_rate_configured || !valid_positive(authority_epoch) || !valid_tick(tick_rate)) {
		r_status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return false;
	}
	r_status = inv::ok_status();
	return true;
}

bool InventoryNetworkGateway::ensure_core(InventoryAuthority *p_authority, inv::Status &r_status) {
	if (p_authority == nullptr) {
		r_status = inv::make_status(inv::StatusCode::NOT_FOUND);
		return false;
	}
	if (p_authority->signal_emission_depth != 0) {
		r_status = inv::make_status(
				inv::StatusCode::COMMAND_REJECTED,
				inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY);
		return false;
	}
	if (!check_configured(r_status)) {
		return false;
	}
	const ObjectID authority_id(p_authority->get_instance_id());
	if (gateway != nullptr) {
		if (callbacks_authority_id != authority_id) {
			// One façade lifetime is pinned to one concrete authority object.  A
			// replacement node at the same NodePath is a new authority generation;
			// silently reusing the configured epoch would admit delayed traffic from
			// the old generation.  Recreate/reconfigure the façade instead.
			r_status = inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::AUTHORITY_EPOCH_MISMATCH);
			return false;
		}
	}
	if (gateway == nullptr) {
		PackedByteArray hello_bytes = p_authority->session_hello_bytes();
		if (hello_bytes.is_empty() || hello_bytes.size() > static_cast<int64_t>(inv::MAX_COMMAND_BYTES)) {
			r_status = authority_status(p_authority, inv::make_status(inv::StatusCode::CATALOG_NOT_SEALED));
			return false;
		}
		const std::vector<std::uint8_t> hello_copy = from_packed(hello_bytes);
		inv::ByteReader reader(hello_copy);
		inv::protocol::SessionHello hello;
		const inv::Status decode_status = inv::protocol::decode_session_hello(reader, hello);
		if (!decode_status.ok()) {
			r_status = decode_status;
			return false;
		}
		inv::protocol::GatewayConfig config;
		config.default_tick_rate = static_cast<std::uint32_t>(tick_rate);
		gateway = std::make_unique<inv::protocol::InventoryNetworkGateway>(hello, config);
		callbacks_authority_id = authority_id;
		callbacks_installed = false;
	}
	if (!callbacks_installed) {
		install_core_callbacks(p_authority);
		callbacks_installed = true;
	}
	if (!bind_authority_lifecycle(p_authority)) {
		r_status = inv::make_status(inv::StatusCode::INTERNAL_ERROR, inv::DiagnosticId::GATEWAY_CALLBACK_MISSING);
		return false;
	}
	r_status = inv::ok_status();
	return true;
}

void InventoryNetworkGateway::install_core_callbacks(InventoryAuthority *p_authority) {
	if (gateway == nullptr || p_authority == nullptr) {
		return;
	}
	const ObjectID self_id(get_instance_id());
	const ObjectID authority_id(p_authority->get_instance_id());
	gateway->set_callbacks(
			[self_id, authority_id](const inv::protocol::CommandIdentity &p_identity, inv::CommandId &r_id) {
				InventoryNetworkGateway *self = Object::cast_to<InventoryNetworkGateway>(ObjectDB::get_instance(self_id));
				InventoryAuthority *authority = Object::cast_to<InventoryAuthority>(ObjectDB::get_instance(authority_id));
				if (self == nullptr || authority == nullptr || p_identity.local_command_id.value > SCRIPT_MAX) {
					return inv::make_status(inv::StatusCode::INTERNAL_ERROR, inv::DiagnosticId::COMMAND_ID_ALLOCATOR_FAILED);
				}
				r_id = authority->allocate_canonical_command_id();
				if (!r_id || r_id.value > SCRIPT_MAX) {
					r_id = inv::CommandId{};
					return inv::make_status(inv::StatusCode::INTERNAL_ERROR, inv::DiagnosticId::COMMAND_ID_ALLOCATOR_FAILED);
				}
				return inv::ok_status();
			},
			[self_id, authority_id](inv::InventoryId p_inventory, std::uint64_t &r_revision) {
				InventoryNetworkGateway *self = Object::cast_to<InventoryNetworkGateway>(ObjectDB::get_instance(self_id));
				InventoryAuthority *authority = Object::cast_to<InventoryAuthority>(ObjectDB::get_instance(authority_id));
				if (self == nullptr || authority == nullptr || p_inventory.value == 0 || p_inventory.value > SCRIPT_MAX) {
					return inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
				}
				const int64_t revision = authority->inventory_revision(static_cast<int64_t>(p_inventory.value));
				if (revision < 0) {
					return inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::GATEWAY_TOUCHED_SET_INVALID, p_inventory.value);
				}
				r_revision = static_cast<std::uint64_t>(revision);
				return inv::ok_status();
			},
			[self_id](const inv::protocol::WorldPolicyRequest &p_request) {
				InventoryNetworkGateway *self = Object::cast_to<InventoryNetworkGateway>(ObjectDB::get_instance(self_id));
				return self == nullptr ? inv::make_status(inv::StatusCode::INTERNAL_ERROR, inv::DiagnosticId::GATEWAY_CALLBACK_MISSING) : self->invoke_world_policy(p_request);
			},
			[self_id](const inv::protocol::CommandExecutionRequest &p_request) {
				InventoryNetworkGateway *self = Object::cast_to<InventoryNetworkGateway>(ObjectDB::get_instance(self_id));
				return self == nullptr ? inv::TransactionResult{} : self->execute_command(p_request);
			});
}

void InventoryNetworkGateway::teardown_discovery(SessionRecord &r_record, InventoryAuthority *p_authority) const {
	if (p_authority != nullptr && r_record.discovery_registered) {
		p_authority->teardown_discovery_recipient(as_script_int(r_record.session), as_script_int(r_record.actor));
	}
	r_record.discovery_registered = false;
	r_record.replication_grants.clear();
}

InventoryNetworkGateway::SessionRecord *InventoryNetworkGateway::session_record(std::uint64_t p_session) {
	auto it = sessions.find(p_session);
	return it == sessions.end() ? nullptr : &it->second;
}

const InventoryNetworkGateway::SessionRecord *InventoryNetworkGateway::session_record(std::uint64_t p_session) const {
	auto it = sessions.find(p_session);
	return it == sessions.end() ? nullptr : &it->second;
}

InventoryNetworkGateway::SessionRecord *InventoryNetworkGateway::session_record_by_peer(std::uint64_t p_peer) {
	auto found = peer_to_session.find(p_peer);
	return found == peer_to_session.end() ? nullptr : session_record(found->second);
}

const InventoryNetworkGateway::SessionRecord *InventoryNetworkGateway::session_record_by_peer(std::uint64_t p_peer) const {
	auto found = peer_to_session.find(p_peer);
	return found == peer_to_session.end() ? nullptr : session_record(found->second);
}

Dictionary InventoryNetworkGateway::status_result(const inv::Status &p_status, bool p_gateway_admitted) const {
	last_status = p_status;
	Dictionary d;
	d["ok"] = p_status.ok();
	d["gateway_admitted"] = p_gateway_admitted;
	d["gateway_replayed"] = false;
	d["status"] = safe_status_dict(p_status);
	return d;
}

Dictionary InventoryNetworkGateway::status_result_from_authority(const Dictionary &p_authority_result, bool p_default_ok) const {
	Dictionary d = p_authority_result;
	const bool ok = bool(d.get("ok", p_default_ok));
	d["ok"] = ok;
	d["gateway_admitted"] = ok;
	d["gateway_replayed"] = false;
	return d;
}

Dictionary InventoryNetworkGateway::invalid_result(inv::StatusCode p_code, inv::DiagnosticId p_diagnostic, std::uint64_t p_detail) const {
	return status_result(inv::make_status(p_code, p_diagnostic, p_detail), false);
}

Dictionary InventoryNetworkGateway::begin_session(
		int64_t p_peer,
		int64_t p_session,
		int64_t p_actor,
		int64_t p_connection_epoch,
		int64_t p_command_allowlist) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!check_configured(status) || !valid_positive(p_peer) || !valid_positive(p_session) ||
			!valid_positive(p_actor) || !valid_positive(p_connection_epoch) || !valid_u32_mask(p_command_allowlist)) {
		return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	InventoryAuthority *authority = resolve_authority();
	if (!ensure_core(authority, status)) return status_result(status);
	const std::uint64_t peer = static_cast<std::uint64_t>(p_peer);
	const std::uint64_t session_id = static_cast<std::uint64_t>(p_session);
	const std::uint64_t actor = static_cast<std::uint64_t>(p_actor);
	const std::uint64_t connection = static_cast<std::uint64_t>(p_connection_epoch);
	SessionRecord *existing_peer = session_record_by_peer(peer);
	if (existing_peer != nullptr && existing_peer->session != session_id) {
		return status_result(inv::make_status(inv::StatusCode::ALREADY_EXISTS, inv::DiagnosticId::SESSION_UNKNOWN, existing_peer->session));
	}
	status = gateway->begin_session(peer, session_id, actor, static_cast<std::uint64_t>(authority_epoch), connection,
			static_cast<std::uint32_t>(p_command_allowlist));
	if (!status.ok()) return status_result(status);
	SessionRecord *record = session_record(session_id);
	if (record == nullptr) {
		SessionRecord fresh;
		fresh.peer = peer;
		fresh.session = session_id;
		fresh.actor = actor;
		fresh.connection_epoch = connection;
		sessions.emplace(session_id, fresh);
		record = session_record(session_id);
	} else {
		if (record->actor != actor) {
			return status_result(inv::make_status(inv::StatusCode::ALREADY_EXISTS, inv::DiagnosticId::ACTOR_MISMATCH, actor));
		}
		if (record->peer != peer) peer_to_session.erase(record->peer);
		record->peer = peer;
		record->connection_epoch = connection;
	}
	peer_to_session[peer] = session_id;
	Dictionary result = status_result(inv::ok_status(), true);
	result["peer"] = p_peer;
	result["session"] = p_session;
	result["actor"] = p_actor;
	result["authority_epoch"] = authority_epoch;
	result["connection_epoch"] = p_connection_epoch;
	result["command_allowlist"] = p_command_allowlist;
	result["session_ready"] = gateway->session_ready(session_id);
	return result;
}

Dictionary InventoryNetworkGateway::end_session(int64_t p_peer) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!valid_positive(p_peer)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	// Teardown must remain available after the bound authority is freed or a
	// different node appears at its path.  Use only the pinned ObjectID for
	// optional discovery cleanup; core/local revocation needs no authority.
	InventoryAuthority *authority = resolve_bound_authority();
	SessionRecord *record = session_record_by_peer(static_cast<std::uint64_t>(p_peer));
	if (record == nullptr) {
		return status_result(gateway == nullptr
				? inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::SESSION_UNKNOWN, static_cast<std::uint64_t>(p_peer))
				: gateway->end_session(static_cast<std::uint64_t>(p_peer)));
	}
	const std::uint64_t session_id = record->session;
	teardown_discovery(*record, authority);
	status = gateway == nullptr ? inv::ok_status() : gateway->end_session(static_cast<std::uint64_t>(p_peer));
	peer_to_session.erase(static_cast<std::uint64_t>(p_peer));
	sessions.erase(session_id);
	return status_result(status);
}

Dictionary InventoryNetworkGateway::drop_session(int64_t p_session) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!valid_positive(p_session)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	InventoryAuthority *authority = resolve_bound_authority();
	SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) {
		return status_result(gateway == nullptr
				? inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::SESSION_UNKNOWN, static_cast<std::uint64_t>(p_session))
				: gateway->drop_session(static_cast<std::uint64_t>(p_session)));
	}
	const std::uint64_t peer = record->peer;
	teardown_discovery(*record, authority);
	status = gateway == nullptr ? inv::ok_status() : gateway->drop_session(static_cast<std::uint64_t>(p_session));
	peer_to_session.erase(peer);
	sessions.erase(static_cast<std::uint64_t>(p_session));
	return status_result(status);
}

Dictionary InventoryNetworkGateway::clear_sessions() {
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	InventoryAuthority *authority = resolve_bound_authority();
	for (auto &entry : sessions) teardown_discovery(entry.second, authority);
	const inv::Status status = gateway == nullptr ? inv::ok_status() : gateway->clear();
	sessions.clear();
	peer_to_session.clear();
	return status_result(status);
}

Dictionary InventoryNetworkGateway::accept_session_hello(
		int64_t p_peer,
		int64_t p_session,
		int64_t p_connection_epoch,
		const PackedByteArray &p_bytes,
		int64_t p_now_tick) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!check_configured(status) || !valid_positive(p_peer) || !valid_positive(p_session) ||
			!valid_positive(p_connection_epoch) || !valid_now_tick(p_now_tick)) {
		return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	InventoryAuthority *authority = resolve_authority();
	if (!ensure_core(authority, status)) return status_result(status);
	const SessionRecord *record = nullptr;
	if (!check_transport_session(p_peer, p_session, p_connection_epoch, record, status)) return status_result(status);
	GodotProcessingScope processing_scope(processing);
	const inv::protocol::InboundContext context{
			static_cast<std::uint64_t>(p_peer), static_cast<std::uint64_t>(p_session),
			static_cast<std::uint64_t>(authority_epoch), static_cast<std::uint64_t>(p_connection_epoch),
			static_cast<std::uint64_t>(p_now_tick), static_cast<std::uint32_t>(tick_rate)};
	status = gateway->admit_session_hello(
			context,
			p_bytes.ptr(),
			static_cast<std::size_t>(p_bytes.size()));
	Dictionary result = status_result(status, status.ok());
	result["peer"] = p_peer;
	result["session"] = p_session;
	result["connection_epoch"] = p_connection_epoch;
	result["session_ready"] = status.ok();
	return result;
}

Dictionary InventoryNetworkGateway::set_command_allowlist(int64_t p_session, int64_t p_allowlist) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!valid_positive(p_session) || !valid_u32_mask(p_allowlist)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	if (gateway == nullptr) return status_result(inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_UNKNOWN));
	status = gateway->set_command_allowlist(static_cast<std::uint64_t>(p_session), static_cast<std::uint32_t>(p_allowlist));
	Dictionary result = status_result(status, status.ok());
	result["session"] = p_session;
	result["command_allowlist"] = p_allowlist;
	return result;
}

int64_t InventoryNetworkGateway::get_command_allowlist(int64_t p_session) const {
	if (gateway == nullptr || p_session <= 0) return 0;
	return static_cast<int64_t>(gateway->command_allowlist(static_cast<std::uint64_t>(p_session)));
}

bool InventoryNetworkGateway::session_ready(int64_t p_session) const {
	return gateway != nullptr && p_session > 0 && gateway->session_ready(static_cast<std::uint64_t>(p_session));
}

Dictionary InventoryNetworkGateway::grant_inventory(int64_t p_session, int64_t p_inventory) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!valid_positive(p_session) || !valid_positive(p_inventory)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	InventoryAuthority *authority = resolve_authority();
	if (!ensure_core(authority, status)) return status_result(status);
	if (!authority->has_inventory(p_inventory)) return status_result(inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::INVENTORY_ACCESS_DENIED, static_cast<std::uint64_t>(p_inventory)));
	status = gateway->grant_inventory(static_cast<std::uint64_t>(p_session), inv::InventoryId{ static_cast<std::uint64_t>(p_inventory) });
	Dictionary result = status_result(status, status.ok());
	result["session"] = p_session;
	result["inventory"] = p_inventory;
	return result;
}

Dictionary InventoryNetworkGateway::revoke_inventory(int64_t p_session, int64_t p_inventory) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!valid_positive(p_session) || !valid_positive(p_inventory)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	if (gateway == nullptr) return status_result(inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_UNKNOWN));
	status = gateway->revoke_inventory(static_cast<std::uint64_t>(p_session), inv::InventoryId{ static_cast<std::uint64_t>(p_inventory) });
	Dictionary result = status_result(status, status.ok());
	result["session"] = p_session;
	result["inventory"] = p_inventory;
	return result;
}

bool InventoryNetworkGateway::has_inventory_grant(int64_t p_session, int64_t p_inventory) const {
	return gateway != nullptr && p_session > 0 && p_inventory > 0 && gateway->has_inventory_grant(
			static_cast<std::uint64_t>(p_session), inv::InventoryId{ static_cast<std::uint64_t>(p_inventory) });
}

Dictionary InventoryNetworkGateway::grant_replication(int64_t p_session, int64_t p_inventory, int64_t p_visibility) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!valid_positive(p_session) || !valid_positive(p_inventory) ||
			(p_visibility != VISIBILITY_OWNER && p_visibility != VISIBILITY_OBSERVER && p_visibility != VISIBILITY_REDACTED)) {
		return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	InventoryAuthority *authority = resolve_authority();
	if (!ensure_core(authority, status)) return status_result(status);
	if (!authority->has_inventory(p_inventory)) return status_result(inv::make_status(inv::StatusCode::NOT_FOUND));
	SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) return status_result(inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::SESSION_UNKNOWN, p_session));
	const std::uint64_t inventory = static_cast<std::uint64_t>(p_inventory);
	auto old = record->replication_grants.find(inventory);
	if (old != record->replication_grants.end() && static_cast<int>(old->second) == p_visibility) {
		return status_result(inv::ok_status(), true);
	}
	if (old == record->replication_grants.end() &&
			record->replication_grants.size() >= static_cast<std::size_t>(MAX_REPLICATION_GRANTS_PER_SESSION)) {
		return status_result(inv::make_status(
				inv::StatusCode::LIMIT_EXCEEDED,
				inv::DiagnosticId::COUNT_LIMIT_EXCEEDED,
				record->replication_grants.size() + 1));
	}
	if (old != record->replication_grants.end()) {
		if (old->second != inv::VisibilityScope::OWNER) {
			// Revoke the authority-side recipient grant before changing the local
			// visibility record. Every replacement erases the old local grant first,
			// so a failed OWNER-to-observer downgrade cannot retain wider access.
			authority->revoke_discovery_inventory(p_session, record->actor, p_inventory);
			gateway->revoke_observer(static_cast<std::uint64_t>(p_session), inv::InventoryId{ inventory });
		}
		record->replication_grants.erase(old);
	}
	if (p_visibility == VISIBILITY_OWNER) {
		record->replication_grants[inventory] = inv::VisibilityScope::OWNER;
	} else {
		if (!record->discovery_registered) {
			const Dictionary registered = authority->register_discovery_recipient(p_session, record->actor);
			if (!dictionary_ok(registered)) return status_result(authority_status(authority, inv::make_status(inv::StatusCode::INTERNAL_ERROR)));
			record->discovery_registered = true;
		}
		const inv::VisibilityScope scope = p_visibility == VISIBILITY_REDACTED ? inv::VisibilityScope::REDACTED : inv::VisibilityScope::OBSERVER;
		status = gateway->grant_observer(static_cast<std::uint64_t>(p_session), inv::InventoryId{ inventory }, scope);
		if (!status.ok()) return status_result(status);
		record->replication_grants[inventory] = scope;
	}
	Dictionary result = status_result(inv::ok_status(), true);
	result["session"] = p_session;
	result["inventory"] = p_inventory;
	result["visibility"] = p_visibility;
	return result;
}

Dictionary InventoryNetworkGateway::revoke_replication(int64_t p_session, int64_t p_inventory) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!valid_positive(p_session) || !valid_positive(p_inventory)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	InventoryAuthority *authority = resolve_authority();
	if (!ensure_core(authority, status)) return status_result(status);
	SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) return status_result(inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::SESSION_UNKNOWN, p_session));
	auto found = record->replication_grants.find(static_cast<std::uint64_t>(p_inventory));
	if (found == record->replication_grants.end()) return status_result(inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::OBSERVER_GRANT_MISSING, p_inventory));
	if (found->second != inv::VisibilityScope::OWNER) {
		// This call is intentionally made while the grant is still present.
		authority->revoke_discovery_inventory(p_session, record->actor, p_inventory);
		gateway->revoke_observer(static_cast<std::uint64_t>(p_session), inv::InventoryId{ static_cast<std::uint64_t>(p_inventory) });
	}
	record->replication_grants.erase(found);
	return status_result(inv::ok_status(), true);
}

Dictionary InventoryNetworkGateway::grant_observer_replication(int64_t p_session, int64_t p_inventory, int64_t p_visibility) {
	if (p_visibility == VISIBILITY_OWNER) {
		return invalid_result(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::INVALID_ENUM);
	}
	return grant_replication(p_session, p_inventory, p_visibility);
}

int InventoryNetworkGateway::get_replication_visibility(int64_t p_session, int64_t p_inventory) const {
	if (p_session <= 0 || p_inventory <= 0) return -1;
	const SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) return -1;
	auto found = record->replication_grants.find(static_cast<std::uint64_t>(p_inventory));
	return found == record->replication_grants.end() ? -1 : static_cast<int>(found->second);
}

bool InventoryNetworkGateway::has_replication_grant(int64_t p_session, int64_t p_inventory) const {
	return get_replication_visibility(p_session, p_inventory) >= 0;
}

inv::Status InventoryNetworkGateway::resolve_revision(inv::InventoryId p_inventory, std::uint64_t &r_revision) const {
	if (!p_inventory || p_inventory.value > SCRIPT_MAX) return inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	InventoryAuthority *authority = resolve_authority();
	inv::Status binding_status;
	if (!check_bound_authority(authority, binding_status)) return binding_status;
	const int64_t revision = authority->inventory_revision(static_cast<int64_t>(p_inventory.value));
	if (revision < 0) return inv::make_status(inv::StatusCode::NOT_FOUND, inv::DiagnosticId::GATEWAY_TOUCHED_SET_INVALID, p_inventory.value);
	r_revision = static_cast<std::uint64_t>(revision);
	return inv::ok_status();
}

inv::Status InventoryNetworkGateway::invoke_world_policy(const inv::protocol::WorldPolicyRequest &p_request) {
	if (!script_safe_envelope(p_request.envelope)) return inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	for (std::uint64_t revision : p_request.current_revisions) {
		if (revision > SCRIPT_MAX) return inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	if (!world_policy.is_valid()) return inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::GATEWAY_CALLBACK_MISSING);
	Dictionary request;
	request["peer"] = as_script_int(p_request.identity.peer);
	request["session"] = as_script_int(p_request.identity.session);
	request["actor"] = as_script_int(p_request.identity.actor);
	request["authority_epoch"] = as_script_int(p_request.identity.authority_epoch);
	request["connection_epoch"] = as_script_int(p_request.identity.connection_epoch);
	request["client_sequence"] = as_script_int(p_request.identity.local_command_id.value);
	request["command_class"] = static_cast<int>(p_request.command_class);
	request["command_name"] = String(command_class_name(p_request.command_class));
	request["touched_inventories"] = ids_value(p_request.touched_inventories);
	request["current_revisions"] = revisions_value(p_request.current_revisions);
	request["expected_revisions"] = expected_revisions_value(p_request.envelope.header.expected_revisions);
	request["command"] = command_value(p_request.envelope.command);
	request["fields"] = command_value(p_request.envelope.command);
	const Variant decision = world_policy.call(request);
	if (pending_lifecycle_reset) {
		return inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY);
	}
	if (decision.get_type() != Variant::BOOL) return inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::GATEWAY_CALLBACK_MISSING);
	if (!bool(decision)) return inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::ACCESS_DENIED);
	return inv::ok_status();
}

inv::TransactionResult InventoryNetworkGateway::execute_command(const inv::protocol::CommandExecutionRequest &p_request) {
	inv::TransactionResult rejected;
	rejected.command_id = p_request.canonical_command_id;
	if (!script_safe_envelope(p_request.envelope)) {
		rejected.status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return rejected;
	}
	InventoryAuthority *authority = resolve_authority();
	inv::Status authority_status_value;
	if (pending_lifecycle_reset || !check_bound_authority(authority, authority_status_value) ||
			authority->get_role() != InventoryAuthority::ROLE_SERVER_AUTHORITY) {
		rejected.status = inv::make_status(inv::StatusCode::ROLE_VIOLATION, inv::DiagnosticId::AUTHORITY_CALLBACK_FORBIDDEN);
		return rejected;
	}
	return authority->execute_gateway_command(p_request.envelope);
}

Dictionary InventoryNetworkGateway::submit_command_bytes(
		int64_t p_peer,
		int64_t p_session,
		int64_t p_connection_epoch,
		const PackedByteArray &p_bytes,
		int64_t p_now_tick) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!check_configured(status) || !valid_positive(p_peer) || !valid_positive(p_session) ||
			!valid_positive(p_connection_epoch) || !valid_now_tick(p_now_tick)) {
		return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	}
	InventoryAuthority *authority = resolve_authority();
	if (!ensure_core(authority, status)) return status_result(status);
	const SessionRecord *transport_record = nullptr;
	if (!check_transport_session(p_peer, p_session, p_connection_epoch, transport_record, status)) return status_result(status);
	const inv::protocol::InboundContext context{
			static_cast<std::uint64_t>(p_peer), static_cast<std::uint64_t>(p_session),
			static_cast<std::uint64_t>(authority_epoch), static_cast<std::uint64_t>(p_connection_epoch),
			static_cast<std::uint64_t>(p_now_tick), static_cast<std::uint32_t>(tick_rate)};
	inv::protocol::GatewaySubmitOutcome outcome;
	{
		GodotProcessingScope processing_scope(processing);
		status = gateway->submit_command(
				context,
				p_bytes.ptr(),
				static_cast<std::size_t>(p_bytes.size()),
				outcome);
	}
	flush_pending_lifecycle_reset();
	Dictionary result = command_outcome(context, outcome, outcome.local_command_id.value);
	return result;
}

Dictionary InventoryNetworkGateway::command_outcome(
		const inv::protocol::InboundContext &p_context,
		const inv::protocol::GatewaySubmitOutcome &p_outcome,
		std::uint64_t p_client_sequence) const {
	inv::TransactionResult transport_result = p_outcome.transaction;
	// Server integration events/deltas are never command acknowledgements.
	// Detailed canonical result fields are sent only when this exact session has
	// OWNER replication for every touched inventory; command permission alone
	// cannot widen an observer/redacted response.
	transport_result.events.clear();
	transport_result.deltas.clear();
	transport_result.dropped_items.clear();
	transport_result.dropped_external_owner = inv::ExternalOwnerId{};
	const SessionRecord *record = session_record(p_context.session);
	bool full_owner = record != nullptr && !p_outcome.touched_inventories.empty();
	for (const inv::InventoryId inventory : p_outcome.touched_inventories) {
		if (record == nullptr) {
			full_owner = false;
			break;
		}
		const auto grant = record->replication_grants.find(inventory.value);
		if (grant == record->replication_grants.end() || grant->second != inv::VisibilityScope::OWNER) {
			full_owner = false;
			break;
		}
	}
	if (!full_owner) {
		transport_result.command_id = inv::CommandId{};
		transport_result.revisions.clear();
		transport_result.new_item_id = inv::ItemInstanceId{};
		transport_result.new_reference_id = inv::ReferenceId{};
		transport_result.transferred_quantity = 0;
		transport_result.remaining_quantity = 0;
		transport_result.conflicting_inventory = inv::InventoryId{};
		transport_result.authoritative_revision = 0;
	}
	inv::Status public_status = p_outcome.status;
	if (!full_owner) {
		// Diagnostics remain useful for control flow, but their detail field can
		// contain canonical item ids, counts, hashes, or revisions produced by
		// the executor.  A command grant is not an OWNER replication grant.
		public_status.detail = 0;
		transport_result.status.detail = 0;
	}
	last_status = public_status;
	const std::uint64_t public_canonical_id = full_owner ? p_outcome.canonical_command_id.value : 0;
	Dictionary result;
	result["ok"] = p_outcome.status.ok();
	result["gateway_admitted"] = p_outcome.status.ok();
	result["gateway_replayed"] = p_outcome.replayed;
	result["status"] = safe_status_dict(public_status);
	result["gateway_status"] = safe_status_dict(public_status);
	result["peer"] = as_script_int(p_context.peer);
	result["session"] = as_script_int(p_context.session);
	result["client_sequence"] = as_script_int(p_client_sequence);
	result["canonical_command_id"] = as_script_int(public_canonical_id);
	result["accepted"] = transport_result.accepted;
	result["replayed"] = transport_result.replayed;
	result["queued"] = transport_result.queued;
	result["owner_result_scope"] = full_owner;
	result["touched_inventories"] = ids_value(p_outcome.touched_inventories);
	bool script_boundary_violation = p_client_sequence > SCRIPT_MAX || public_canonical_id > SCRIPT_MAX;
	for (const inv::InventoryId &inventory : p_outcome.touched_inventories) script_boundary_violation = script_boundary_violation || inventory.value > SCRIPT_MAX;
	PackedByteArray result_bytes;
	inv::protocol::ResultEnvelope envelope;
	envelope.result = transport_result;
	inv::ByteWriter writer(inv::MAX_DELTA_BYTES + 64);
	if (inv::protocol::encode_result_envelope(envelope, writer).ok()) result_bytes = to_packed(writer.bytes());
	result["result_bytes"] = result_bytes;
	Dictionary transaction = transaction_value(transport_result);
	script_boundary_violation = script_boundary_violation || bool(transaction.get("script_boundary_violation", false));
	result["transaction"] = transaction;
	// Keep the authority's stable transaction shape available at the top level
	// as well; older Godot callers consume `command_id`/`revisions` directly,
	// while newer callers can use the namespaced `transaction` dictionary.
	const char *const transaction_keys[] = {
			"accepted", "replayed", "queued", "status", "command_id", "revisions", "events",
			"new_item_id", "new_reference_id", "dropped_external_owner", "dropped_items",
			"transferred_quantity", "remaining_quantity", "conflicting_inventory", "authoritative_revision"};
	for (const char *key : transaction_keys) {
		if (transaction.has(key)) result[key] = transaction[key];
	}
	result["script_boundary_violation"] = script_boundary_violation;
	return result;
}

Dictionary InventoryNetworkGateway::snapshot_result(int64_t p_session, int64_t p_inventory) const {
	inv::Status status;
	if (!check_server_authority(status)) return status_result(status);
	if (p_session <= 0 || p_inventory <= 0) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	if (gateway == nullptr || !gateway->session_ready(static_cast<std::uint64_t>(p_session))) {
		return status_result(inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_HELLO_REQUIRED));
	}
	const SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) return status_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::SESSION_UNKNOWN, p_session));
	auto found = record->replication_grants.find(static_cast<std::uint64_t>(p_inventory));
	if (found == record->replication_grants.end()) return status_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::OBSERVER_GRANT_MISSING, p_inventory));
	InventoryAuthority *authority = resolve_authority();
	if (!check_bound_authority(authority, status)) return status_result(status);
	if (authority->signal_emission_depth != 0) {
		return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY));
	}
	PackedByteArray bytes;
	if (found->second == inv::VisibilityScope::OWNER) {
		bytes = authority->snapshot_envelope_bytes(p_inventory, VISIBILITY_OWNER);
	} else {
		bytes = authority->observer_snapshot_envelope_bytes(p_session, as_script_int(record->actor), p_inventory, static_cast<int>(found->second));
		if (!bytes.is_empty()) {
			ObserverEgressMetadata metadata;
			status = observer_snapshot_metadata(
					bytes,
					inv::DiscoveryRecipientKey{ static_cast<std::uint64_t>(p_session), record->actor },
					static_cast<std::uint64_t>(p_inventory),
					found->second,
					metadata);
			if (!status.ok()) {
				return observer_result(status, PackedByteArray(), static_cast<std::uint64_t>(p_inventory), found->second);
			}
			return observer_result(
					status, bytes, static_cast<std::uint64_t>(p_inventory), found->second,
					metadata.generation, metadata.sequence);
		}
	}
	status = bytes.is_empty() ? authority_status(authority, inv::make_status(inv::StatusCode::NOT_FOUND)) : inv::ok_status();
	return observer_result(status, bytes, static_cast<std::uint64_t>(p_inventory), found->second);
}

PackedByteArray InventoryNetworkGateway::snapshot_bytes(int64_t p_session, int64_t p_inventory) const {
	return bytes_from_dictionary(snapshot_result(p_session, p_inventory));
}

Dictionary InventoryNetworkGateway::delta_result(int64_t p_session, int64_t p_inventory, int64_t p_predecessor) const {
	inv::Status status;
	if (!check_server_authority(status)) return status_result(status);
	if (p_session <= 0 || p_inventory <= 0 || p_predecessor < 0 || static_cast<std::uint64_t>(p_predecessor) > SCRIPT_MAX) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	if (gateway == nullptr || !gateway->session_ready(static_cast<std::uint64_t>(p_session))) {
		return status_result(inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_HELLO_REQUIRED));
	}
	const SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) return status_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::SESSION_UNKNOWN, p_session));
	auto found = record->replication_grants.find(static_cast<std::uint64_t>(p_inventory));
	if (found == record->replication_grants.end()) return status_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::OBSERVER_GRANT_MISSING, p_inventory));
	InventoryAuthority *authority = resolve_authority();
	if (!check_bound_authority(authority, status)) return status_result(status);
	if (authority->signal_emission_depth != 0) {
		return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY));
	}
	PackedByteArray bytes;
	if (found->second == inv::VisibilityScope::OWNER) {
		const PackedByteArray batch_bytes = authority->last_delta_batch_bytes();
		if (batch_bytes.size() > static_cast<int64_t>(inv::MAX_DELTA_BYTES)) return owner_delta_result(inv::make_status(inv::StatusCode::PAYLOAD_TOO_LARGE, inv::DiagnosticId::BYTE_LIMIT_EXCEEDED, batch_bytes.size()), PackedByteArray(), static_cast<std::uint64_t>(p_inventory));
		if (!batch_bytes.is_empty()) {
			const std::vector<std::uint8_t> raw = from_packed(batch_bytes);
			inv::ByteReader reader(raw);
			inv::protocol::DeltaBatch batch;
			status = inv::protocol::decode_delta_batch(reader, batch);
			if (!status.ok()) return owner_delta_result(status, PackedByteArray(), static_cast<std::uint64_t>(p_inventory));
			inv::protocol::DeltaBatch filtered;
			// A canonical command id is global authority identity. Once a
			// multi-inventory batch is reduced to one recipient-scoped inventory,
			// retaining it would create a cross-inventory/principal correlation
			// channel (and could undo command-ack redaction). Client egress always
			// clears it; raw delta_ready remains available to trusted server code.
			filtered.source_command_id = inv::CommandId{};
			for (const inv::InventoryDelta &delta : batch.inventories) {
				if (delta.inventory.value == static_cast<std::uint64_t>(p_inventory) &&
						(p_predecessor == 0 || delta.predecessor_revision == static_cast<std::uint64_t>(p_predecessor))) {
					filtered.inventories.push_back(delta);
				}
			}
			if (!filtered.inventories.empty()) {
				inv::ByteWriter writer(inv::MAX_DELTA_BYTES);
				status = inv::protocol::encode_delta_batch(filtered, writer);
				if (!status.ok()) return owner_delta_result(status, PackedByteArray(), static_cast<std::uint64_t>(p_inventory));
				bytes = to_packed(writer.bytes());
			}
		}
		if (bytes.is_empty() && p_predecessor > 0) {
			const int64_t current_revision = authority->inventory_revision(p_inventory);
			if (current_revision < 0 || current_revision != p_predecessor) {
				return owner_delta_result(
						inv::make_status(inv::StatusCode::SNAPSHOT_REQUIRED,
								inv::DiagnosticId::REPLICA_REVISION_GAP,
								current_revision < 0 ? 0 : static_cast<std::uint64_t>(current_revision)),
						PackedByteArray(), static_cast<std::uint64_t>(p_inventory));
			}
		}
		status = inv::ok_status();
		return owner_delta_result(status, bytes, static_cast<std::uint64_t>(p_inventory));
	}
	if (p_predecessor <= 0) return observer_result(inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE), PackedByteArray(), static_cast<std::uint64_t>(p_inventory), found->second);
	bytes = authority->observer_delta_bytes(p_session, as_script_int(record->actor), p_inventory, p_predecessor);
	status = bytes.is_empty() ? authority_status(authority, inv::ok_status()) : inv::ok_status();
	if (!status.ok()) return observer_result(status, PackedByteArray(), static_cast<std::uint64_t>(p_inventory), found->second);
	ObserverEgressMetadata metadata;
	const inv::DiscoveryRecipientKey recipient{ static_cast<std::uint64_t>(p_session), record->actor };
	if (!bytes.is_empty()) {
		status = observer_delta_metadata(
				bytes, recipient, static_cast<std::uint64_t>(p_inventory), found->second,
				static_cast<std::uint64_t>(p_predecessor), metadata);
	} else {
		// An empty successful observer delta means the projected view did not
		// change. The authority has already authenticated the exact predecessor;
		// read its unchanged recipient-bound stream metadata without producing a
		// second snapshot or advancing any observer state.
		const InventoryAuthority::ObserverViewKey key{
				recipient, inv::InventoryId{ static_cast<std::uint64_t>(p_inventory) }
		};
		const auto stream = authority->observer_views.find(key);
		if (stream == authority->observer_views.end() ||
				!observer_egress_identity_matches(
						stream->second.view, recipient, static_cast<std::uint64_t>(p_inventory), found->second) ||
				stream->second.view.sequence != static_cast<std::uint64_t>(p_predecessor)) {
			status = inv::make_status(inv::StatusCode::INVARIANT_VIOLATION, inv::DiagnosticId::RESYNC_IDENTITY_MISMATCH);
		} else {
			metadata.generation = stream->second.view.generation;
			metadata.sequence = stream->second.view.sequence;
		}
	}
	if (!status.ok()) return observer_result(status, PackedByteArray(), static_cast<std::uint64_t>(p_inventory), found->second);
	return observer_result(
			status, bytes, static_cast<std::uint64_t>(p_inventory), found->second,
			metadata.generation, metadata.sequence);
}

PackedByteArray InventoryNetworkGateway::delta_bytes(int64_t p_session, int64_t p_inventory, int64_t p_predecessor) const {
	return bytes_from_dictionary(delta_result(p_session, p_inventory, p_predecessor));
}

Dictionary InventoryNetworkGateway::resync_result(
		int64_t p_peer,
		int64_t p_session,
		int64_t p_connection_epoch,
	const PackedByteArray &p_bytes,
	int64_t p_now_tick) {
	inv::Status status;
	if (processing) return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::GATEWAY_REENTRANT));
	if (!check_server_authority(status)) return status_result(status);
	if (!check_configured(status) || p_peer <= 0 || p_session <= 0 || p_connection_epoch <= 0 || !valid_now_tick(p_now_tick)) return invalid_result(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
	if (gateway == nullptr) return status_result(inv::make_status(inv::StatusCode::SESSION_NOT_READY, inv::DiagnosticId::SESSION_UNKNOWN));
	const inv::protocol::InboundContext context{
			static_cast<std::uint64_t>(p_peer), static_cast<std::uint64_t>(p_session),
			static_cast<std::uint64_t>(authority_epoch), static_cast<std::uint64_t>(p_connection_epoch),
			static_cast<std::uint64_t>(p_now_tick), static_cast<std::uint32_t>(tick_rate)};
	InventoryAuthority *authority = resolve_authority();
	if (!check_bound_authority(authority, status)) return status_result(status);
	if (authority->signal_emission_depth != 0) {
		return status_result(inv::make_status(inv::StatusCode::COMMAND_REJECTED, inv::DiagnosticId::AUTHORITY_LIFECYCLE_BUSY));
	}
	const SessionRecord *transport_record = nullptr;
	if (!check_transport_session(p_peer, p_session, p_connection_epoch, transport_record, status)) return status_result(status);
	if (!gateway->session_ready(static_cast<std::uint64_t>(p_session))) {
		{
			GodotProcessingScope processing_scope(processing);
			status = gateway->admit_resync_context(context);
		}
		return observer_result(status, PackedByteArray(), 0, inv::VisibilityScope::REDACTED);
	}
	if (p_bytes.size() > static_cast<int64_t>(inv::MAX_COMMAND_BYTES)) {
		{
			GodotProcessingScope processing_scope(processing);
			status = gateway->admit_resync_context(context);
		}
		if (status.ok()) {
			status = inv::make_status(inv::StatusCode::PAYLOAD_TOO_LARGE,
					inv::DiagnosticId::BYTE_LIMIT_EXCEEDED,
					static_cast<std::uint64_t>(p_bytes.size()));
		}
		return observer_result(status, PackedByteArray(), 0, inv::VisibilityScope::REDACTED);
	}
	GodotProcessingScope processing_scope(processing);
	if (observer_wire_prefix(p_bytes)) {
		inv::protocol::ObserverAdmission admission;
		status = gateway->admit_observer_resync(
				context,
				p_bytes.ptr(),
				static_cast<std::size_t>(p_bytes.size()),
				admission);
		if (!status.ok()) return observer_result(status, PackedByteArray(), admission.request.inventory_id, admission.visibility);
		const SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
		if (record == nullptr) return observer_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::SESSION_UNKNOWN), PackedByteArray(), admission.request.inventory_id, admission.visibility);
		auto grant = record->replication_grants.find(admission.request.inventory_id);
		if (grant == record->replication_grants.end() || grant->second != admission.visibility || admission.request.inventory_id > SCRIPT_MAX) return observer_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::OBSERVER_GRANT_MISSING, admission.request.inventory_id), PackedByteArray(), admission.request.inventory_id, admission.visibility);
		PackedByteArray bytes = authority == nullptr ? PackedByteArray() : authority->observer_snapshot_envelope_bytes(p_session, as_script_int(record->actor), as_script_int(admission.request.inventory_id), static_cast<int>(grant->second));
		status = bytes.is_empty() ? authority_status(authority, inv::make_status(inv::StatusCode::NOT_FOUND)) : inv::ok_status();
		if (!status.ok()) return observer_result(status, PackedByteArray(), admission.request.inventory_id, grant->second);
		ObserverEgressMetadata metadata;
		status = observer_snapshot_metadata(
				bytes,
				inv::DiscoveryRecipientKey{ static_cast<std::uint64_t>(p_session), record->actor },
				admission.request.inventory_id,
				grant->second,
				metadata);
		if (!status.ok()) return observer_result(status, PackedByteArray(), admission.request.inventory_id, grant->second);
		return observer_result(
				status, bytes, admission.request.inventory_id, grant->second,
				metadata.generation, metadata.sequence);
	}
	// Owner resync is independently authenticated/rate-limited before this
	// decode.  No owner packet can bypass the core session/hello gate.
	status = gateway->admit_resync_context(context);
	if (!status.ok()) return observer_result(status, PackedByteArray(), 0, inv::VisibilityScope::OWNER);
	const std::vector<std::uint8_t> raw = from_packed(p_bytes);
	inv::ByteReader reader(raw);
	inv::protocol::ResyncRequest request;
	status = inv::protocol::decode_resync_request(reader, request);
	if (!status.ok() || !request.inventory || request.inventory.value > SCRIPT_MAX || request.last_applied_revision > SCRIPT_MAX) {
		if (status.ok()) status = inv::make_status(inv::StatusCode::INVALID_ARGUMENT, inv::DiagnosticId::VALUE_OUT_OF_RANGE);
		return observer_result(status, PackedByteArray(), request.inventory.value, inv::VisibilityScope::OWNER);
	}
	const SessionRecord *record = session_record(static_cast<std::uint64_t>(p_session));
	if (record == nullptr) return observer_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::SESSION_UNKNOWN), PackedByteArray(), request.inventory.value, inv::VisibilityScope::OWNER);
	auto grant = record->replication_grants.find(request.inventory.value);
	if (grant == record->replication_grants.end() || grant->second != inv::VisibilityScope::OWNER) return observer_result(inv::make_status(inv::StatusCode::PERMISSION_DENIED, inv::DiagnosticId::OBSERVER_GRANT_MISSING, request.inventory.value), PackedByteArray(), request.inventory.value, inv::VisibilityScope::OWNER);
	PackedByteArray bytes = authority == nullptr ? PackedByteArray() : authority->snapshot_envelope_bytes(as_script_int(request.inventory.value), VISIBILITY_OWNER);
	status = bytes.is_empty() ? authority_status(authority, inv::make_status(inv::StatusCode::NOT_FOUND)) : inv::ok_status();
	return observer_result(status, bytes, request.inventory.value, inv::VisibilityScope::OWNER);
}

PackedByteArray InventoryNetworkGateway::resync_bytes(
		int64_t p_peer,
		int64_t p_session,
		int64_t p_connection_epoch,
		const PackedByteArray &p_bytes,
		int64_t p_now_tick) {
	return bytes_from_dictionary(resync_result(p_peer, p_session, p_connection_epoch, p_bytes, p_now_tick));
}

Dictionary InventoryNetworkGateway::observer_result(
		const inv::Status &p_status,
		const PackedByteArray &p_bytes,
		std::uint64_t p_inventory,
		inv::VisibilityScope p_visibility,
		std::uint64_t p_generation,
		std::uint64_t p_sequence) const {
	Dictionary result = status_result(p_status, p_status.ok());
	result["bytes"] = p_bytes;
	result["inventory"] = as_script_int(p_inventory);
	result["inventory_id"] = as_script_int(p_inventory);
	result["visibility"] = static_cast<int>(p_visibility);
	result["generation"] = as_script_int(p_generation);
	result["sequence"] = as_script_int(p_sequence);
	result["script_boundary_violation"] = p_inventory > SCRIPT_MAX || p_generation > SCRIPT_MAX || p_sequence > SCRIPT_MAX;
	return result;
}

Dictionary InventoryNetworkGateway::owner_delta_result(
		const inv::Status &p_status,
		const PackedByteArray &p_bytes,
		std::uint64_t p_inventory) const {
	Dictionary result = status_result(p_status, p_status.ok());
	result["bytes"] = p_bytes;
	result["inventory"] = as_script_int(p_inventory);
	result["inventory_id"] = as_script_int(p_inventory);
	result["visibility"] = VISIBILITY_OWNER;
	result["script_boundary_violation"] = p_inventory > SCRIPT_MAX;
	return result;
}

Dictionary InventoryNetworkGateway::get_last_status() const {
	return status_result(last_status, false);
}

int64_t InventoryNetworkGateway::tracked_session_count() const {
	return static_cast<int64_t>(sessions.size());
}

int64_t InventoryNetworkGateway::replay_entry_count(int64_t p_session) const {
	if (gateway == nullptr || p_session <= 0) return 0;
	return static_cast<int64_t>(gateway->replay_entry_count(static_cast<std::uint64_t>(p_session)));
}

int64_t InventoryNetworkGateway::command_mask_for_class(int64_t p_class) {
	if (p_class < 1 || p_class > 19) return 0;
	return INT64_C(1) << (p_class - 1);
}

const char *InventoryNetworkGateway::command_class_name(inv::protocol::CommandClass p_class) {
	switch (p_class) {
		case inv::protocol::CommandClass::MOVE_ITEM: return "move_item";
		case inv::protocol::CommandClass::ROTATE_ITEM: return "rotate_item";
		case inv::protocol::CommandClass::SPLIT_STACK: return "split_stack";
		case inv::protocol::CommandClass::MERGE_STACKS: return "merge_stacks";
		case inv::protocol::CommandClass::INSERT_ITEM: return "insert_item";
		case inv::protocol::CommandClass::REMOVE_ITEM: return "remove_item";
		case inv::protocol::CommandClass::EQUIP_ITEM: return "equip_item";
		case inv::protocol::CommandClass::UNEQUIP_ITEM: return "unequip_item";
		case inv::protocol::CommandClass::SWAP_ITEMS: return "swap_items";
		case inv::protocol::CommandClass::AUTO_PLACE_ITEM: return "auto_place_item";
		case inv::protocol::CommandClass::QUICK_TRANSFER_ITEM: return "quick_transfer_item";
		case inv::protocol::CommandClass::LOOT_ITEM: return "loot_item";
		case inv::protocol::CommandClass::DROP_ITEM: return "drop_item";
		case inv::protocol::CommandClass::SETTLE_INVENTORY: return "settle_inventory";
		case inv::protocol::CommandClass::ASSIGN_REFERENCE: return "assign_reference";
		case inv::protocol::CommandClass::CLEAR_REFERENCE: return "clear_reference";
		case inv::protocol::CommandClass::TARGETED_PROVIDER_TRANSFER: return "targeted_provider_transfer";
		case inv::protocol::CommandClass::SET_ITEM_COMPONENT: return "set_item_component";
		case inv::protocol::CommandClass::REMOVE_ITEM_COMPONENT: return "remove_item_component";
	}
	return "unknown";
}

Dictionary InventoryNetworkGateway::location_value(const inv::ItemLocation &p_location) {
	return location_dict(p_location);
}

Dictionary InventoryNetworkGateway::command_value(const inv::Command &p_command) {
	Dictionary d;
	std::visit([&](const auto &p_body) {
		using T = std::decay_t<decltype(p_body)>;
		if constexpr (std::is_same_v<T, inv::MoveItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["destination"] = location_value(p_body.destination);
		} else if constexpr (std::is_same_v<T, inv::RotateItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["rotated"] = p_body.rotated;
		} else if constexpr (std::is_same_v<T, inv::SplitStackCommand>) {
			d["source"] = as_script_int(p_body.source.value); d["quantity"] = as_script_int(p_body.quantity); d["destination"] = location_value(p_body.destination);
		} else if constexpr (std::is_same_v<T, inv::MergeStacksCommand>) {
			d["source"] = as_script_int(p_body.source.value); d["destination_item"] = as_script_int(p_body.destination.value);
		} else if constexpr (std::is_same_v<T, inv::InsertItemCommand>) {
			d["item_definition_identifier"] = String(p_body.item_definition_identifier.c_str()); d["quantity"] = as_script_int(p_body.quantity); d["destination"] = location_value(p_body.destination);
		} else if constexpr (std::is_same_v<T, inv::RemoveItemCommand>) {
			d["item"] = as_script_int(p_body.item.value);
		} else if constexpr (std::is_same_v<T, inv::EquipItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["destination_container"] = as_script_int(p_body.destination_container.value); d["slot_identifier"] = String(p_body.slot_identifier.c_str());
		} else if constexpr (std::is_same_v<T, inv::UnequipItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["destination"] = location_value(p_body.destination);
		} else if constexpr (std::is_same_v<T, inv::SwapItemsCommand>) {
			d["item_a"] = as_script_int(p_body.item_a.value); d["item_b"] = as_script_int(p_body.item_b.value);
		} else if constexpr (std::is_same_v<T, inv::AutoPlaceItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["destination"] = as_script_int(p_body.destination.value); d["destination_container"] = as_script_int(p_body.destination_container.value);
		} else if constexpr (std::is_same_v<T, inv::QuickTransferItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["source"] = as_script_int(p_body.source.value); d["destination"] = as_script_int(p_body.destination.value); d["allow_partial"] = p_body.allow_partial;
		} else if constexpr (std::is_same_v<T, inv::TargetedProviderTransferCommand>) {
			d["source"] = as_script_int(p_body.source.value); d["destination"] = as_script_int(p_body.destination.value); d["item"] = as_script_int(p_body.item.value); d["destination_provider"] = as_script_int(p_body.destination_provider.value);
		} else if constexpr (std::is_same_v<T, inv::LootItemCommand>) {
			d["source"] = as_script_int(p_body.source.value); d["destination"] = as_script_int(p_body.destination.value); d["item"] = as_script_int(p_body.item.value); d["destination_location"] = location_value(p_body.destination_location);
		} else if constexpr (std::is_same_v<T, inv::DropItemCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["external_owner"] = as_script_int(p_body.external_owner.value);
		} else if constexpr (std::is_same_v<T, inv::SettleInventoryCommand>) {
			d["inventory"] = as_script_int(p_body.inventory.value);
			Array plan;
			for (const inv::SettlementEntry &entry : p_body.plan) {
				Dictionary item; item["item"] = as_script_int(entry.item.value);
				std::visit([&](const auto &disposition) {
					using D = std::decay_t<decltype(disposition)>;
					if constexpr (std::is_same_v<D, inv::SettlementRetain>) item["disposition"] = String("retain");
					else if constexpr (std::is_same_v<D, inv::SettlementTransfer>) { item["disposition"] = String("transfer_to"); item["destination"] = as_script_int(disposition.destination.value); item["location"] = location_value(disposition.location); }
					else { item["disposition"] = String("release_to"); item["external_owner"] = as_script_int(disposition.external_owner.value); }
				}, entry.disposition);
				plan.append(item);
			}
			d["plan"] = plan;
		} else if constexpr (std::is_same_v<T, inv::AssignReferenceCommand>) {
			d["item"] = as_script_int(p_body.item.value);
		} else if constexpr (std::is_same_v<T, inv::ClearReferenceCommand>) {
			d["reference"] = as_script_int(p_body.reference.value);
		} else if constexpr (std::is_same_v<T, inv::SetItemComponentCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["component_identifier"] = String(p_body.component_identifier.c_str()); d["payload"] = to_packed(p_body.payload);
		} else if constexpr (std::is_same_v<T, inv::RemoveItemComponentCommand>) {
			d["item"] = as_script_int(p_body.item.value); d["component_identifier"] = String(p_body.component_identifier.c_str());
		}
	}, p_command);
	return d;
}

Dictionary InventoryNetworkGateway::transaction_value(const inv::TransactionResult &p_result) {
	Dictionary d;
	bool boundary = p_result.command_id.value > SCRIPT_MAX ||
			p_result.new_item_id.value > SCRIPT_MAX || p_result.new_reference_id.value > SCRIPT_MAX ||
			p_result.dropped_external_owner.value > SCRIPT_MAX ||
			p_result.conflicting_inventory.value > SCRIPT_MAX ||
			p_result.authoritative_revision > SCRIPT_MAX ||
			p_result.transferred_quantity > SCRIPT_MAX || p_result.remaining_quantity > SCRIPT_MAX;
	d["accepted"] = p_result.accepted;
	d["replayed"] = p_result.replayed;
	d["queued"] = p_result.queued;
	d["status"] = safe_status_dict(p_result.status);
	d["command_id"] = as_script_int(p_result.command_id.value);
	Array revisions;
	for (const inv::RevisionOutcome &revision : p_result.revisions) {
		boundary = boundary || revision.inventory.value > SCRIPT_MAX || revision.predecessor_revision > SCRIPT_MAX || revision.successor_revision > SCRIPT_MAX;
		Dictionary value;
		value["inventory"] = as_script_int(revision.inventory.value);
		value["predecessor"] = as_script_int(revision.predecessor_revision);
		value["successor"] = as_script_int(revision.successor_revision);
		revisions.append(value);
	}
	d["revisions"] = revisions;
	Array events;
	for (const inv::TransactionEvent &event : p_result.events) {
		boundary = boundary || event.item.value > SCRIPT_MAX || event.secondary_item.value > SCRIPT_MAX ||
				event.source_container.value > SCRIPT_MAX || event.destination_container.value > SCRIPT_MAX || event.reference.value > SCRIPT_MAX;
		Dictionary value;
		value["kind"] = static_cast<int>(event.kind);
		value["item"] = as_script_int(event.item.value);
		value["secondary_item"] = as_script_int(event.secondary_item.value);
		value["source_container"] = as_script_int(event.source_container.value);
		value["destination_container"] = as_script_int(event.destination_container.value);
		value["reference"] = as_script_int(event.reference.value);
		events.append(value);
	}
	d["events"] = events;
	d["new_item_id"] = as_script_int(p_result.new_item_id.value);
	d["new_reference_id"] = as_script_int(p_result.new_reference_id.value);
	d["dropped_external_owner"] = as_script_int(p_result.dropped_external_owner.value);
	Array dropped;
	for (const inv::DroppedItemValue &item : p_result.dropped_items) {
		boundary = boundary || item.quantity > SCRIPT_MAX || item.external_owner.value > SCRIPT_MAX;
		Dictionary value;
		value["item_definition_identifier"] = String(item.item_definition_identifier.c_str());
		value["quantity"] = as_script_int(item.quantity);
		value["external_owner"] = as_script_int(item.external_owner.value);
		Array components;
		for (const inv::MutableComponent &component : item.mutable_components) {
			Dictionary component_value;
			component_value["component_identifier"] = String(component.component_identifier.c_str());
			component_value["payload"] = to_packed(component.payload);
			components.append(component_value);
		}
		value["mutable_components"] = components;
		dropped.append(value);
	}
	d["dropped_items"] = dropped;
	d["transferred_quantity"] = as_script_int(p_result.transferred_quantity);
	d["remaining_quantity"] = as_script_int(p_result.remaining_quantity);
	d["conflicting_inventory"] = as_script_int(p_result.conflicting_inventory.value);
	d["authoritative_revision"] = as_script_int(p_result.authoritative_revision);
	d["script_boundary_violation"] = boundary;
	return d;
}

Array InventoryNetworkGateway::expected_revisions_value(const std::vector<inv::ExpectedRevision> &p_revisions) {
	Array values;
	for (const inv::ExpectedRevision &revision : p_revisions) {
		Dictionary value;
		value["inventory"] = as_script_int(revision.inventory.value);
		value["revision"] = as_script_int(revision.revision);
		values.append(value);
	}
	return values;
}

PackedInt64Array InventoryNetworkGateway::ids_value(const std::vector<inv::InventoryId> &p_ids) {
	PackedInt64Array values;
	values.resize(static_cast<int64_t>(p_ids.size()));
	for (std::size_t i = 0; i < p_ids.size(); ++i) values.set(static_cast<int64_t>(i), as_script_int(p_ids[i].value));
	return values;
}

PackedInt64Array InventoryNetworkGateway::revisions_value(const std::vector<std::uint64_t> &p_revisions) {
	PackedInt64Array values;
	values.resize(static_cast<int64_t>(p_revisions.size()));
	for (std::size_t i = 0; i < p_revisions.size(); ++i) values.set(static_cast<int64_t>(i), as_script_int(p_revisions[i]));
	return values;
}

bool InventoryNetworkGateway::script_safe_location(const inv::ItemLocation &p_location) {
	return std::visit([](const auto &p_placement) { return p_placement.container.value <= SCRIPT_MAX; }, p_location);
}

bool InventoryNetworkGateway::script_safe_command(const inv::Command &p_command) {
	return std::visit([](const auto &p_body) {
		using T = std::decay_t<decltype(p_body)>;
		if constexpr (std::is_same_v<T, inv::MoveItemCommand>) return p_body.item.value <= SCRIPT_MAX && script_safe_location(p_body.destination);
		if constexpr (std::is_same_v<T, inv::RotateItemCommand>) return p_body.item.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::SplitStackCommand>) return p_body.source.value <= SCRIPT_MAX && p_body.quantity <= SCRIPT_MAX && script_safe_location(p_body.destination);
		if constexpr (std::is_same_v<T, inv::MergeStacksCommand>) return p_body.source.value <= SCRIPT_MAX && p_body.destination.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::InsertItemCommand>) return p_body.quantity <= SCRIPT_MAX && script_safe_location(p_body.destination);
		if constexpr (std::is_same_v<T, inv::RemoveItemCommand>) return p_body.item.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::EquipItemCommand>) return p_body.item.value <= SCRIPT_MAX && p_body.destination_container.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::UnequipItemCommand>) return p_body.item.value <= SCRIPT_MAX && script_safe_location(p_body.destination);
		if constexpr (std::is_same_v<T, inv::SwapItemsCommand>) return p_body.item_a.value <= SCRIPT_MAX && p_body.item_b.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::AutoPlaceItemCommand>) return p_body.item.value <= SCRIPT_MAX && p_body.destination.value <= SCRIPT_MAX && p_body.destination_container.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::QuickTransferItemCommand>) return p_body.item.value <= SCRIPT_MAX && p_body.source.value <= SCRIPT_MAX && p_body.destination.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::TargetedProviderTransferCommand>) return p_body.source.value <= SCRIPT_MAX && p_body.destination.value <= SCRIPT_MAX && p_body.item.value <= SCRIPT_MAX && p_body.destination_provider.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::LootItemCommand>) return p_body.source.value <= SCRIPT_MAX && p_body.destination.value <= SCRIPT_MAX && p_body.item.value <= SCRIPT_MAX && script_safe_location(p_body.destination_location);
		if constexpr (std::is_same_v<T, inv::DropItemCommand>) return p_body.item.value <= SCRIPT_MAX && p_body.external_owner.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::SettleInventoryCommand>) {
			if (p_body.inventory.value > SCRIPT_MAX) return false;
			for (const inv::SettlementEntry &entry : p_body.plan) {
				if (entry.item.value > SCRIPT_MAX) return false;
				bool safe = true;
				std::visit([&](const auto &disposition) {
					using D = std::decay_t<decltype(disposition)>;
					if constexpr (std::is_same_v<D, inv::SettlementTransfer>) safe = disposition.destination.value <= SCRIPT_MAX && script_safe_location(disposition.location);
					else if constexpr (std::is_same_v<D, inv::SettlementRelease>) safe = disposition.external_owner.value <= SCRIPT_MAX;
				}, entry.disposition);
				if (!safe) return false;
			}
			return true;
		}
		if constexpr (std::is_same_v<T, inv::AssignReferenceCommand>) return p_body.item.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::ClearReferenceCommand>) return p_body.reference.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::SetItemComponentCommand>) return p_body.item.value <= SCRIPT_MAX;
		if constexpr (std::is_same_v<T, inv::RemoveItemComponentCommand>) return p_body.item.value <= SCRIPT_MAX;
		return false;
	}, p_command);
}

bool InventoryNetworkGateway::script_safe_envelope(const inv::protocol::CommandEnvelope &p_envelope) {
	if (p_envelope.header.command_id.value == 0 || p_envelope.header.command_id.value > SCRIPT_MAX || p_envelope.header.actor > SCRIPT_MAX) return false;
	for (const inv::ExpectedRevision &expected : p_envelope.header.expected_revisions) {
		if (!expected.inventory || expected.inventory.value > SCRIPT_MAX || expected.revision > SCRIPT_MAX) return false;
	}
	return script_safe_command(p_envelope.command);
}

int64_t InventoryNetworkGateway::as_script_int(std::uint64_t p_value) {
	return p_value <= SCRIPT_MAX ? static_cast<int64_t>(p_value) : int64_t(0);
}

void InventoryNetworkGateway::_bind_methods() {
	ClassDB::bind_static_method("InventoryNetworkGateway", D_METHOD("command_mask_for_class", "command_class"), &InventoryNetworkGateway::command_mask_for_class);
	ClassDB::bind_method(D_METHOD("set_authority_path", "path"), &InventoryNetworkGateway::set_authority_path);
	ClassDB::bind_method(D_METHOD("get_authority_path"), &InventoryNetworkGateway::get_authority_path);
	ClassDB::bind_method(D_METHOD("set_inventory_authority_path", "path"), &InventoryNetworkGateway::set_inventory_authority_path);
	ClassDB::bind_method(D_METHOD("get_inventory_authority_path"), &InventoryNetworkGateway::get_inventory_authority_path);
	ClassDB::bind_method(D_METHOD("set_authority_epoch", "epoch"), &InventoryNetworkGateway::set_authority_epoch);
	ClassDB::bind_method(D_METHOD("get_authority_epoch"), &InventoryNetworkGateway::get_authority_epoch);
	ClassDB::bind_method(D_METHOD("set_tick_rate", "tick_rate"), &InventoryNetworkGateway::set_tick_rate);
	ClassDB::bind_method(D_METHOD("get_tick_rate"), &InventoryNetworkGateway::get_tick_rate);
	ClassDB::bind_method(D_METHOD("configure", "authority_epoch", "tick_rate"), &InventoryNetworkGateway::configure);
	ClassDB::bind_method(D_METHOD("set_world_policy", "policy"), &InventoryNetworkGateway::set_world_policy);
	ClassDB::bind_method(D_METHOD("get_world_policy"), &InventoryNetworkGateway::get_world_policy);
	ClassDB::bind_method(D_METHOD("set_world_policy_callback", "policy"), &InventoryNetworkGateway::set_world_policy_callback);
	ClassDB::bind_method(D_METHOD("get_world_policy_callback"), &InventoryNetworkGateway::get_world_policy_callback);
	ClassDB::bind_method(D_METHOD("begin_session", "peer", "session", "actor", "connection_epoch", "command_allowlist"), &InventoryNetworkGateway::begin_session, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("end_session", "peer"), &InventoryNetworkGateway::end_session);
	ClassDB::bind_method(D_METHOD("drop_session", "session"), &InventoryNetworkGateway::drop_session);
	ClassDB::bind_method(D_METHOD("clear_sessions"), &InventoryNetworkGateway::clear_sessions);
	ClassDB::bind_method(D_METHOD("accept_session_hello", "peer", "session", "connection_epoch", "bytes", "now_tick"), &InventoryNetworkGateway::accept_session_hello, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("admit_session_hello", "peer", "session", "connection_epoch", "bytes", "now_tick"), &InventoryNetworkGateway::admit_session_hello, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("set_command_allowlist", "session", "allowlist"), &InventoryNetworkGateway::set_command_allowlist);
	ClassDB::bind_method(D_METHOD("get_command_allowlist", "session"), &InventoryNetworkGateway::get_command_allowlist);
	ClassDB::bind_method(D_METHOD("session_ready", "session"), &InventoryNetworkGateway::session_ready);
	ClassDB::bind_method(D_METHOD("grant_inventory", "session", "inventory"), &InventoryNetworkGateway::grant_inventory);
	ClassDB::bind_method(D_METHOD("revoke_inventory", "session", "inventory"), &InventoryNetworkGateway::revoke_inventory);
	ClassDB::bind_method(D_METHOD("grant_command_inventory", "session", "inventory"), &InventoryNetworkGateway::grant_command_inventory);
	ClassDB::bind_method(D_METHOD("revoke_command_inventory", "session", "inventory"), &InventoryNetworkGateway::revoke_command_inventory);
	ClassDB::bind_method(D_METHOD("has_inventory_grant", "session", "inventory"), &InventoryNetworkGateway::has_inventory_grant);
	ClassDB::bind_method(D_METHOD("grant_replication", "session", "inventory", "visibility"), &InventoryNetworkGateway::grant_replication);
	ClassDB::bind_method(D_METHOD("revoke_replication", "session", "inventory"), &InventoryNetworkGateway::revoke_replication);
	ClassDB::bind_method(D_METHOD("grant_owner_replication", "session", "inventory"), &InventoryNetworkGateway::grant_owner_replication);
	ClassDB::bind_method(D_METHOD("grant_observer_replication", "session", "inventory", "visibility"), &InventoryNetworkGateway::grant_observer_replication, DEFVAL(VISIBILITY_OBSERVER));
	ClassDB::bind_method(D_METHOD("get_replication_visibility", "session", "inventory"), &InventoryNetworkGateway::get_replication_visibility);
	ClassDB::bind_method(D_METHOD("has_replication_grant", "session", "inventory"), &InventoryNetworkGateway::has_replication_grant);
	ClassDB::bind_method(D_METHOD("submit_command_bytes", "peer", "session", "connection_epoch", "bytes", "now_tick"), &InventoryNetworkGateway::submit_command_bytes, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("submit_remote_command", "peer", "session", "connection_epoch", "bytes", "now_tick"), &InventoryNetworkGateway::submit_remote_command, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("submit_command", "bytes", "peer", "session", "connection_epoch", "now_tick"), &InventoryNetworkGateway::submit_command, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("snapshot_result", "session", "inventory"), &InventoryNetworkGateway::snapshot_result);
	ClassDB::bind_method(D_METHOD("snapshot_bytes", "session", "inventory"), &InventoryNetworkGateway::snapshot_bytes);
	ClassDB::bind_method(D_METHOD("delta_result", "session", "inventory", "predecessor"), &InventoryNetworkGateway::delta_result, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("delta_bytes", "session", "inventory", "predecessor"), &InventoryNetworkGateway::delta_bytes, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("resync_result", "peer", "session", "connection_epoch", "bytes", "now_tick"), &InventoryNetworkGateway::resync_result, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("resync_bytes", "peer", "session", "connection_epoch", "bytes", "now_tick"), &InventoryNetworkGateway::resync_bytes, DEFVAL(int64_t(0)));
	ClassDB::bind_method(D_METHOD("get_last_status"), &InventoryNetworkGateway::get_last_status);
	ClassDB::bind_method(D_METHOD("tracked_session_count"), &InventoryNetworkGateway::tracked_session_count);
	ClassDB::bind_method(D_METHOD("replay_entry_count", "session"), &InventoryNetworkGateway::replay_entry_count);

	BIND_ENUM_CONSTANT(VISIBILITY_OWNER);
	BIND_ENUM_CONSTANT(VISIBILITY_OBSERVER);
	BIND_ENUM_CONSTANT(VISIBILITY_REDACTED);
	BIND_CONSTANT(COMMAND_CLASS_MOVE_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_ROTATE_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_SPLIT_STACK);
	BIND_CONSTANT(COMMAND_CLASS_MERGE_STACKS);
	BIND_CONSTANT(COMMAND_CLASS_INSERT_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_REMOVE_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_EQUIP_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_UNEQUIP_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_SWAP_ITEMS);
	BIND_CONSTANT(COMMAND_CLASS_AUTO_PLACE_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_QUICK_TRANSFER_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_LOOT_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_DROP_ITEM);
	BIND_CONSTANT(COMMAND_CLASS_SETTLE_INVENTORY);
	BIND_CONSTANT(COMMAND_CLASS_ASSIGN_REFERENCE);
	BIND_CONSTANT(COMMAND_CLASS_CLEAR_REFERENCE);
	BIND_CONSTANT(COMMAND_CLASS_TARGETED_PROVIDER_TRANSFER);
	BIND_CONSTANT(COMMAND_CLASS_SET_ITEM_COMPONENT);
	BIND_CONSTANT(COMMAND_CLASS_REMOVE_ITEM_COMPONENT);
	BIND_CONSTANT(COMMAND_MASK_MOVE_ITEM);
	BIND_CONSTANT(COMMAND_MASK_ROTATE_ITEM);
	BIND_CONSTANT(COMMAND_MASK_SPLIT_STACK);
	BIND_CONSTANT(COMMAND_MASK_MERGE_STACKS);
	BIND_CONSTANT(COMMAND_MASK_INSERT_ITEM);
	BIND_CONSTANT(COMMAND_MASK_REMOVE_ITEM);
	BIND_CONSTANT(COMMAND_MASK_EQUIP_ITEM);
	BIND_CONSTANT(COMMAND_MASK_UNEQUIP_ITEM);
	BIND_CONSTANT(COMMAND_MASK_SWAP_ITEMS);
	BIND_CONSTANT(COMMAND_MASK_AUTO_PLACE_ITEM);
	BIND_CONSTANT(COMMAND_MASK_QUICK_TRANSFER_ITEM);
	BIND_CONSTANT(COMMAND_MASK_LOOT_ITEM);
	BIND_CONSTANT(COMMAND_MASK_DROP_ITEM);
	BIND_CONSTANT(COMMAND_MASK_SETTLE_INVENTORY);
	BIND_CONSTANT(COMMAND_MASK_ASSIGN_REFERENCE);
	BIND_CONSTANT(COMMAND_MASK_CLEAR_REFERENCE);
	BIND_CONSTANT(COMMAND_MASK_TARGETED_PROVIDER_TRANSFER);
	BIND_CONSTANT(COMMAND_MASK_SET_ITEM_COMPONENT);
	BIND_CONSTANT(COMMAND_MASK_REMOVE_ITEM_COMPONENT);
	BIND_CONSTANT(COMMAND_MASK_ALL);
	BIND_CONSTANT(MAX_REPLICATION_GRANTS_PER_SESSION);
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "authority_path"), "set_authority_path", "get_authority_path");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "authority_epoch"), "set_authority_epoch", "get_authority_epoch");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tick_rate"), "set_tick_rate", "get_tick_rate");
}

} // namespace godot
