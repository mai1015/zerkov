#include "protocol/gap_fake_transport.h"

#include <algorithm>

namespace ga::proto {

namespace {

// Corrupts one byte in place, guaranteed to differ from its original value:
// XOR with a delta drawn from [1, 255] can never produce the identity
// mapping, so "this byte was corrupted" is a structural guarantee rather
// than a probabilistic one.
void corrupt_one_byte(std::uint8_t &r_byte, DeterministicPrng &p_prng) {
	const std::uint8_t delta = static_cast<std::uint8_t>(1 + p_prng.next_bounded(255));
	r_byte = static_cast<std::uint8_t>(r_byte ^ delta);
}

} // namespace

FakeTransport::FakeTransport(std::uint64_t p_seed) :
		prng(p_seed) {}

FakeTransport::EndpointState &FakeTransport::endpoint_state(EndpointId p_id) {
	return endpoints[p_id]; // Default-constructed EndpointState starts connected==true.
}

const FakeTransport::LinkConfig *FakeTransport::find_link(EndpointId p_a, EndpointId p_b) const {
	const UnorderedKey key{ std::min(p_a, p_b), std::max(p_a, p_b) };
	const auto it = links.find(key);
	return it == links.end() ? nullptr : &it->second;
}

TransportCounters &FakeTransport::counters_for(EndpointId p_id) {
	return per_peer[p_id];
}

Status FakeTransport::connect(EndpointId p_a, EndpointId p_b, ChannelReliability p_reliability, const TransportImpairment &p_impairment) {
	if (p_a == INVALID_ENDPOINT_ID || p_b == INVALID_ENDPOINT_ID || p_a == p_b) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	if (p_impairment.latency_ticks_max < p_impairment.latency_ticks_min) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	if (p_impairment.duplicate_permille > 1000 || p_impairment.reorder_permille > 1000 ||
			p_impairment.loss_permille > 1000 || p_impairment.corruption_permille > 1000) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	if (p_impairment.corruption_permille > 0 && p_impairment.max_corrupted_bytes == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	// The one rule this class never lets a caller bypass: a reliable-ordered
	// channel's correctness argument depends on it actually being reliable
	// (see the "Ordered Authoritative Event Streams" requirement). Loss is
	// only ever legal on a channel that already promises no delivery
	// guarantee at all.
	if (p_impairment.loss_permille > 0 && p_reliability == ChannelReliability::RELIABLE_ORDERED) {
		return make_status(StatusCode::NOT_SUPPORTED, DiagnosticId::NONE, p_impairment.loss_permille);
	}

	endpoint_state(p_a);
	endpoint_state(p_b);
	const UnorderedKey key{ std::min(p_a, p_b), std::max(p_a, p_b) };
	links[key] = LinkConfig{ p_reliability, p_impairment };
	return ok_status();
}

template <typename Predicate>
void FakeTransport::evict_if(Predicate p_predicate) {
	for (auto it = queue.begin(); it != queue.end();) {
		const DeliveryKey &key = it->first;
		if (p_predicate(key.sender, key.receiver)) {
			counters_for(key.receiver).dropped += 1;
			totals.dropped += 1;
			it = queue.erase(it);
		} else {
			++it;
		}
	}
	for (auto &entry : directions) {
		DirectionState &state = entry.second;
		if (state.has_hold && p_predicate(entry.first.from, entry.first.to)) {
			counters_for(entry.first.to).dropped += 1;
			totals.dropped += 1;
			state.has_hold = false;
			state.hold = HeldMessage{};
		}
	}
}

void FakeTransport::disconnect(EndpointId p_endpoint) {
	EndpointState &state = endpoint_state(p_endpoint);
	state.connected = false;
	// Hard link drop: evict everything in flight to OR from this endpoint,
	// in either direction, regardless of its scheduled tick.
	evict_if([p_endpoint](EndpointId p_sender, EndpointId p_receiver) {
		return p_sender == p_endpoint || p_receiver == p_endpoint;
	});
}

Status FakeTransport::reconnect(EndpointId p_endpoint, SessionId p_new_session) {
	if (p_endpoint == INVALID_ENDPOINT_ID || p_new_session == INVALID_SESSION_ID) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	EndpointState &state = endpoint_state(p_endpoint);
	state.connected = true;
	state.session = p_new_session;
	// Old in-flight messages cannot be delivered into the new session:
	// evict everything still queued or held that is addressed TO this
	// endpoint (messages it had already sent to someone else are left
	// alone -- see the class comment).
	evict_if([p_endpoint](EndpointId /*p_sender*/, EndpointId p_receiver) {
		return p_receiver == p_endpoint;
	});
	return ok_status();
}

bool FakeTransport::is_connected(EndpointId p_endpoint) const {
	const auto it = endpoints.find(p_endpoint);
	return it != endpoints.end() && it->second.connected;
}

SessionId FakeTransport::current_session(EndpointId p_endpoint) const {
	const auto it = endpoints.find(p_endpoint);
	return it == endpoints.end() ? INVALID_SESSION_ID : it->second.session;
}

void FakeTransport::commit_entry(EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_bytes, Tick p_tick, std::uint64_t p_seq, bool p_corrupted, bool p_duplicate) {
	const DeliveryKey key{ p_tick, p_from, p_to, p_seq };
	queue[key] = QueuedEntry{ std::move(p_bytes), p_corrupted, p_duplicate };
}

void FakeTransport::schedule_send(EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_bytes, bool p_corrupted, bool p_duplicate) {
	const LinkConfig *link = find_link(p_from, p_to);
	// send() already validated the link exists before calling this; a null
	// link here would be an internal logic error, not a reachable input
	// state, but treat it as "no jitter, no reorder" defensively rather than
	// dereferencing a null pointer.
	const TransportImpairment fallback;
	const TransportImpairment &impairment = link != nullptr ? link->impairment : fallback;

	const DirectionKey dkey{ p_from, p_to };
	DirectionState &dstate = directions[dkey];

	const std::uint64_t seq = next_seq++;
	const Tick jitter = prng.next_range(impairment.latency_ticks_min, impairment.latency_ticks_max);
	const Tick natural_tick = std::max(now_tick + jitter, dstate.last_scheduled_delivery_tick);
	const bool triggers_reorder = prng.roll_permille(impairment.reorder_permille);

	if (dstate.has_hold) {
		// A previous message on this direction is held back. This message
		// becomes the flush trigger regardless of whether it itself also
		// rolled reorder (bounded to one held message per direction).
		commit_entry(p_from, p_to, p_bytes, natural_tick, seq, p_corrupted, p_duplicate);
		dstate.last_scheduled_delivery_tick = natural_tick;

		HeldMessage held = std::move(dstate.hold);
		dstate.has_hold = false;
		dstate.hold = HeldMessage{};

		const Tick flush_tick = std::max(held.natural_tick, natural_tick + 1);
		commit_entry(p_from, p_to, std::move(held.bytes), flush_tick, held.enqueue_seq, held.corrupted, held.duplicate);
		dstate.last_scheduled_delivery_tick = std::max(dstate.last_scheduled_delivery_tick, flush_tick);

		counters_for(p_to).reordered += 1;
		totals.reordered += 1;
		return;
	}

	if (triggers_reorder) {
		dstate.has_hold = true;
		dstate.hold = HeldMessage{ std::move(p_bytes), natural_tick, seq, p_corrupted, p_duplicate };
		return; // Not yet committed; released by a follow-up send() or by advance_to's safety net.
	}

	commit_entry(p_from, p_to, std::move(p_bytes), natural_tick, seq, p_corrupted, p_duplicate);
	dstate.last_scheduled_delivery_tick = natural_tick;
}

Status FakeTransport::send(EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_message) {
	if (p_from == INVALID_ENDPOINT_ID || p_to == INVALID_ENDPOINT_ID || p_from == p_to) {
		return make_status(StatusCode::INVALID_ARGUMENT);
	}
	const auto from_it = endpoints.find(p_from);
	const auto to_it = endpoints.find(p_to);
	if (from_it == endpoints.end() || to_it == endpoints.end() ||
			!from_it->second.connected || !to_it->second.connected) {
		return make_status(StatusCode::NETWORK_UNAVAILABLE);
	}
	const LinkConfig *link = find_link(p_from, p_to);
	if (link == nullptr) {
		return make_status(StatusCode::NOT_FOUND);
	}

	counters_for(p_from).sent += 1;
	totals.sent += 1;

	if (link->reliability == ChannelReliability::UNRELIABLE && prng.roll_permille(link->impairment.loss_permille)) {
		counters_for(p_to).dropped += 1;
		totals.dropped += 1;
		return ok_status();
	}

	bool corrupted = false;
	if (prng.roll_permille(link->impairment.corruption_permille)) {
		const std::size_t bound = std::min(link->impairment.max_corrupted_bytes, p_message.size());
		if (bound > 0) {
			if (bound == p_message.size()) {
				for (std::uint8_t &byte : p_message) {
					corrupt_one_byte(byte, prng);
				}
			} else {
				std::vector<bool> used(p_message.size(), false);
				std::size_t chosen = 0;
				while (chosen < bound) {
					const std::size_t idx = static_cast<std::size_t>(prng.next_bounded(p_message.size()));
					if (used[idx]) {
						continue;
					}
					used[idx] = true;
					corrupt_one_byte(p_message[idx], prng);
					++chosen;
				}
			}
			corrupted = true;
		}
		counters_for(p_to).corrupted += 1;
		totals.corrupted += 1;
	}

	schedule_send(p_from, p_to, p_message, corrupted, false);

	if (prng.roll_permille(link->impairment.duplicate_permille)) {
		counters_for(p_to).duplicated += 1;
		totals.duplicated += 1;
		schedule_send(p_from, p_to, p_message, corrupted, true);
	}

	return ok_status();
}

void FakeTransport::advance_to(Tick p_target_tick) {
	if (p_target_tick < now_tick) {
		return; // Time never moves backwards.
	}
	now_tick = p_target_tick;

	// Safety net: release any held-back reorder message whose own natural
	// tick has become due, so nothing can be stuck forever if no follow-up
	// message ever arrives on its direction. No swap occurred, so this does
	// NOT count as `reordered`.
	for (auto &entry : directions) {
		DirectionState &dstate = entry.second;
		if (dstate.has_hold && dstate.hold.natural_tick <= p_target_tick) {
			HeldMessage held = std::move(dstate.hold);
			dstate.has_hold = false;
			dstate.hold = HeldMessage{};
			const DeliveryKey key{ held.natural_tick, entry.first.from, entry.first.to, held.enqueue_seq };
			queue[key] = QueuedEntry{ std::move(held.bytes), held.corrupted, held.duplicate };
			dstate.last_scheduled_delivery_tick = std::max(dstate.last_scheduled_delivery_tick, held.natural_tick);
		}
	}

	auto it = queue.begin();
	while (it != queue.end() && it->first.delivery_tick <= p_target_tick) {
		const DeliveryKey &key = it->first;
		QueuedEntry &entry = it->second;

		const LinkConfig *link = find_link(key.sender, key.receiver);
		const bool link_cut = link != nullptr &&
				link->impairment.disconnect_at_tick != INVALID_TICK &&
				key.delivery_tick >= link->impairment.disconnect_at_tick;

		if (link_cut) {
			counters_for(key.receiver).dropped += 1;
			totals.dropped += 1;
		} else {
			DeliveredMessage delivered;
			delivered.sender = key.sender;
			delivered.receiver = key.receiver;
			delivered.delivery_tick = key.delivery_tick;
			delivered.enqueue_seq = key.enqueue_seq;
			delivered.bytes = std::move(entry.bytes);
			delivered.was_duplicate = entry.duplicate;
			delivered.was_corrupted = entry.corrupted;

			counters_for(key.receiver).delivered += 1;
			totals.delivered += 1;

			log.push_back(delivered);
			inboxes[key.receiver].push_back(std::move(delivered));
		}

		it = queue.erase(it);
	}
}

std::vector<DeliveredMessage> FakeTransport::take_delivered(EndpointId p_receiver) {
	const auto it = inboxes.find(p_receiver);
	if (it == inboxes.end()) {
		return {};
	}
	std::vector<DeliveredMessage> result = std::move(it->second);
	it->second.clear();
	return result;
}

std::uint64_t FakeTransport::delivery_log_hash() const {
	Hasher hasher;
	hasher.write_u64(static_cast<std::uint64_t>(log.size()));
	for (const DeliveredMessage &message : log) {
		hasher.write_u64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(message.sender)));
		hasher.write_u64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(message.receiver)));
		hasher.write_u64(message.delivery_tick);
		hasher.write_u64(message.enqueue_seq);
		hasher.write_byte(message.was_duplicate ? 1 : 0);
		hasher.write_byte(message.was_corrupted ? 1 : 0);
		hasher.write_bytes(message.bytes);
	}
	return hasher.digest();
}

TransportCounters FakeTransport::peer_counters(EndpointId p_endpoint) const {
	const auto it = per_peer.find(p_endpoint);
	return it == per_peer.end() ? TransportCounters{} : it->second;
}

// ---------------------------------------------------------------------------
// TransportScript
// ---------------------------------------------------------------------------

void TransportScript::add_connect(Tick p_tick, EndpointId p_a, EndpointId p_b, ChannelReliability p_reliability, const TransportImpairment &p_impairment) {
	ScriptStep step;
	step.kind = ScriptStepKind::CONNECT;
	step.tick = p_tick;
	step.endpoint_a = p_a;
	step.endpoint_b = p_b;
	step.reliability = p_reliability;
	step.impairment = p_impairment;
	entries.push_back(std::move(step));
}

void TransportScript::add_send(Tick p_tick, EndpointId p_from, EndpointId p_to, std::vector<std::uint8_t> p_message) {
	ScriptStep step;
	step.kind = ScriptStepKind::SEND;
	step.tick = p_tick;
	step.endpoint_a = p_from;
	step.endpoint_b = p_to;
	step.message = std::move(p_message);
	entries.push_back(std::move(step));
}

void TransportScript::add_advance_to(Tick p_tick) {
	ScriptStep step;
	step.kind = ScriptStepKind::ADVANCE_TO;
	step.tick = p_tick;
	entries.push_back(std::move(step));
}

void TransportScript::add_disconnect(Tick p_tick, EndpointId p_endpoint) {
	ScriptStep step;
	step.kind = ScriptStepKind::DISCONNECT;
	step.tick = p_tick;
	step.endpoint_a = p_endpoint;
	entries.push_back(std::move(step));
}

void TransportScript::add_reconnect(Tick p_tick, EndpointId p_endpoint, SessionId p_new_session) {
	ScriptStep step;
	step.kind = ScriptStepKind::RECONNECT;
	step.tick = p_tick;
	step.endpoint_a = p_endpoint;
	step.new_session = p_new_session;
	entries.push_back(std::move(step));
}

Status TransportScript::execute(FakeTransport &r_transport) const {
	Status last = ok_status();
	for (const ScriptStep &step : entries) {
		r_transport.advance_to(step.tick);
		switch (step.kind) {
			case ScriptStepKind::CONNECT: {
				const Status status = r_transport.connect(step.endpoint_a, step.endpoint_b, step.reliability, step.impairment);
				if (!status.ok()) {
					last = status;
				}
				break;
			}
			case ScriptStepKind::SEND: {
				const Status status = r_transport.send(step.endpoint_a, step.endpoint_b, step.message);
				if (!status.ok()) {
					last = status;
				}
				break;
			}
			case ScriptStepKind::ADVANCE_TO:
				break; // Already advanced above.
			case ScriptStepKind::DISCONNECT:
				r_transport.disconnect(step.endpoint_a);
				break;
			case ScriptStepKind::RECONNECT: {
				const Status status = r_transport.reconnect(step.endpoint_a, step.new_session);
				if (!status.ok()) {
					last = status;
				}
				break;
			}
		}
	}
	return last;
}

} // namespace ga::proto
