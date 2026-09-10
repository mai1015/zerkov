#include "protocol/wpn_prediction.h"

#include <algorithm>

namespace wpn::protocol {

void PresentationPredictionTracker::track(const PresentationIntent &p_intent, std::optional<PredictionOutcome> &r_evicted) {
	r_evicted.reset();
	if (pending.size() >= MAX_PENDING_PRESENTATION_INTENTS) {
		r_evicted = PredictionOutcome{ pending.front(), PredictionOutcomeKind::EXPIRED };
		pending.pop_front();
	}
	pending.push_back(p_intent);
}

std::vector<PredictionOutcome> PresentationPredictionTracker::confirm_up_to(const std::string &p_instance_id, std::uint64_t p_confirmed_sequence) {
	std::vector<PredictionOutcome> resolved;
	std::deque<PresentationIntent> remaining;
	for (const PresentationIntent &intent : pending) {
		if (intent.instance_id == p_instance_id && intent.sequence <= p_confirmed_sequence) {
			resolved.push_back(PredictionOutcome{ intent, PredictionOutcomeKind::CONFIRMED });
		} else {
			remaining.push_back(intent);
		}
	}
	pending = std::move(remaining);
	return resolved;
}

std::optional<PredictionOutcome> PresentationPredictionTracker::reject(const std::string &p_command_id) {
	for (auto it = pending.begin(); it != pending.end(); ++it) {
		if (it->command_id == p_command_id) {
			PredictionOutcome outcome{ *it, PredictionOutcomeKind::REJECTED };
			pending.erase(it);
			return outcome;
		}
	}
	return std::nullopt;
}

std::vector<PredictionOutcome> PresentationPredictionTracker::diverge_instance(const std::string &p_instance_id) {
	std::vector<PredictionOutcome> discarded;
	std::deque<PresentationIntent> remaining;
	for (const PresentationIntent &intent : pending) {
		if (intent.instance_id == p_instance_id) {
			discarded.push_back(PredictionOutcome{ intent, PredictionOutcomeKind::DIVERGED });
		} else {
			remaining.push_back(intent);
		}
	}
	pending = std::move(remaining);
	return discarded;
}

std::vector<PredictionOutcome> PresentationPredictionTracker::sweep_expired(std::uint64_t p_now_tick) {
	std::vector<PredictionOutcome> expired;
	std::deque<PresentationIntent> remaining;
	for (const PresentationIntent &intent : pending) {
		const bool too_old = p_now_tick > intent.sent_tick &&
				(p_now_tick - intent.sent_tick) > MAX_PRESENTATION_INTENT_AGE_TICKS;
		if (too_old) {
			expired.push_back(PredictionOutcome{ intent, PredictionOutcomeKind::EXPIRED });
		} else {
			remaining.push_back(intent);
		}
	}
	pending = std::move(remaining);
	return expired;
}

bool PresentationPredictionTracker::is_pending(const std::string &p_command_id) const {
	return std::any_of(pending.begin(), pending.end(), [&](const PresentationIntent &p_intent) {
		return p_intent.command_id == p_command_id;
	});
}

} // namespace wpn::protocol
