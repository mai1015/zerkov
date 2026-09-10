#include "core/ga_change_tracking.h"

namespace ga {

ChangeTracker::AudienceState &ChangeTracker::state_for(ChangeAudience p_audience) {
	return states[static_cast<std::uint8_t>(p_audience)];
}

const ChangeTracker::AudienceState &ChangeTracker::state_for(ChangeAudience p_audience) const {
	return states[static_cast<std::uint8_t>(p_audience)];
}

void ChangeTracker::commit_change(ChangeAudience p_audience, std::vector<DirtyRecord> p_records) {
	if (p_records.empty()) {
		return;
	}
	AudienceState &state = state_for(p_audience);
	state.revision_value += 1;
	if (state.ring_entries.size() >= MAX_CHANGE_REVISION_RING_DEPTH) {
		state.ring_entries.pop_front();
	}
	ChangeRevisionEntry entry;
	entry.revision = state.revision_value;
	entry.records = std::move(p_records);
	state.ring_entries.push_back(std::move(entry));
}

void ChangeTracker::force_full_resync() {
	for (AudienceState &state : states) {
		state.revision_value += 1;
		state.ring_entries.clear();
	}
}

std::uint64_t ChangeTracker::revision(ChangeAudience p_audience) const {
	return state_for(p_audience).revision_value;
}

bool ChangeTracker::cursor_overflowed(ChangeAudience p_audience, std::uint64_t p_cursor) const {
	const AudienceState &state = state_for(p_audience);
	if (p_cursor >= state.revision_value) {
		return false;
	}
	if (state.ring_entries.empty()) {
		return state.revision_value > 0;
	}
	return (p_cursor + 1) < state.ring_entries.front().revision;
}

const std::deque<ChangeRevisionEntry> &ChangeTracker::ring(ChangeAudience p_audience) const {
	return state_for(p_audience).ring_entries;
}

std::vector<DirtyRecord> ChangeTracker::dirty_since(ChangeAudience p_audience, std::uint64_t p_cursor) const {
	std::vector<DirtyRecord> result;
	for (const ChangeRevisionEntry &entry : ring(p_audience)) {
		if (entry.revision <= p_cursor) {
			continue;
		}
		result.insert(result.end(), entry.records.begin(), entry.records.end());
	}
	return result;
}

} // namespace ga
