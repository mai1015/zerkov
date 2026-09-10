#include "protocol/gap_authority.h"

namespace ga::proto {

std::uint64_t OwnershipTable::next_touch() {
	++touch_counter;
	return touch_counter;
}

void OwnershipTable::enforce_peer_cap() {
	if (peers.size() <= MAX_TRACKED_PEERS) {
		return;
	}
	// Deterministic eviction: drop the least-recently-touched peer record.
	// A linear scan is fine here -- the map is capped at MAX_TRACKED_PEERS,
	// so this is bounded work, never proportional to hostile input.
	auto oldest = peers.begin();
	for (auto it = peers.begin(); it != peers.end(); ++it) {
		if (it->second.touch_seq < oldest->second.touch_seq) {
			oldest = it;
		}
	}
	peers.erase(oldest);
}

Status OwnershipTable::begin_session(PeerId p_peer, SessionId p_session) {
	if (p_session == INVALID_SESSION_ID) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, p_session);
	}
	PeerRecord &record = peers[p_peer];
	record.session = p_session;
	record.touch_seq = next_touch();
	enforce_peer_cap();
	return ok_status();
}

void OwnershipTable::end_session(PeerId p_peer) {
	auto it = peers.find(p_peer);
	if (it != peers.end()) {
		it->second.session = INVALID_SESSION_ID;
	}
}

Status OwnershipTable::validate_session(PeerId p_peer, SessionId p_session) const {
	auto it = peers.find(p_peer);
	if (it == peers.end() || it->second.session == INVALID_SESSION_ID || it->second.session != p_session) {
		return make_status(StatusCode::SESSION_MISMATCH, DiagnosticId::NONE, static_cast<std::uint64_t>(p_session));
	}
	return ok_status();
}

Status OwnershipTable::authorize_control(PeerId p_peer, EntityId p_entity) {
	if (p_entity == INVALID_ENTITY_ID) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
	}
	PeerRecord &record = peers[p_peer];
	record.entities.insert(p_entity.value);
	if (record.entities.size() > MAX_ENTITIES_PER_PEER) {
		// Deterministic eviction: forget the numerically-oldest grant. Real
		// EntityId values are assigned by a monotonic session allocator, so
		// the smallest raw value is also the oldest grant in practice.
		record.entities.erase(record.entities.begin());
	}
	record.touch_seq = next_touch();
	enforce_peer_cap();
	return ok_status();
}

Status OwnershipTable::revoke_control(PeerId p_peer, EntityId p_entity) {
	auto it = peers.find(p_peer);
	if (it == peers.end() || it->second.entities.erase(p_entity.value) == 0) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_entity.value);
	}
	return ok_status();
}

Status OwnershipTable::validate_control(PeerId p_peer, EntityId p_entity) const {
	if (p_entity == INVALID_ENTITY_ID) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::NONE, 0);
	}
	auto it = peers.find(p_peer);
	if (it == peers.end() || it->second.entities.find(p_entity.value) == it->second.entities.end()) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::NONE, p_entity.value);
	}
	return ok_status();
}

void OwnershipTable::drop_peer(PeerId p_peer) {
	peers.erase(p_peer);
}

Status OwnershipTable::authorize_server_entity(EntityId p_entity) {
	if (p_entity == INVALID_ENTITY_ID) {
		return make_status(StatusCode::INVALID_ARGUMENT, DiagnosticId::NONE, 0);
	}
	server_entities.insert(p_entity.value);
	if (server_entities.size() > MAX_SERVER_OWNED_ENTITIES) {
		server_entities.erase(server_entities.begin());
	}
	return ok_status();
}

Status OwnershipTable::revoke_server_entity(EntityId p_entity) {
	if (server_entities.erase(p_entity.value) == 0) {
		return make_status(StatusCode::NOT_FOUND, DiagnosticId::NONE, p_entity.value);
	}
	return ok_status();
}

Status OwnershipTable::validate_server_entity(EntityId p_entity) const {
	if (p_entity == INVALID_ENTITY_ID || server_entities.find(p_entity.value) == server_entities.end()) {
		return make_status(StatusCode::PERMISSION_DENIED, DiagnosticId::NONE, p_entity.value);
	}
	return ok_status();
}

std::size_t OwnershipTable::controlled_entity_count(PeerId p_peer) const {
	auto it = peers.find(p_peer);
	return it == peers.end() ? 0 : it->second.entities.size();
}

} // namespace ga::proto
