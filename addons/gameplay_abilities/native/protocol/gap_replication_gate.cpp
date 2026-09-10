#include "protocol/gap_replication_gate.h"

namespace ga::proto {

SendGateAction decide_send_gate_action(std::uint64_t p_cursor_revision, std::uint64_t p_current_revision,
		bool p_cursor_overflowed, std::uint64_t p_ticks_since_send, std::uint64_t p_heartbeat_cadence) {
	if (p_cursor_overflowed) {
		return SendGateAction::SEND_SNAPSHOT_OVERFLOW;
	}
	if (p_cursor_revision != p_current_revision) {
		return SendGateAction::SEND_STATE;
	}
	if (p_heartbeat_cadence > 0 && p_ticks_since_send >= p_heartbeat_cadence) {
		return SendGateAction::HEARTBEAT;
	}
	return SendGateAction::SUPPRESSED;
}

} // namespace ga::proto
