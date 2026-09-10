#include "protocol/gap_delta_messages.h"

namespace ga::proto {

Status encode_delta_batch(const AbilityComponent &p_component, ChangeAudience p_audience,
		const std::vector<DirtyRecord> &p_dirty, const DeltaBaseline &p_baseline,
		const GameplayAbilityWorldCoordinator *p_session_coordinator, std::size_t p_byte_limit,
		std::vector<std::uint8_t> &r_bytes) {
	r_bytes.clear();
	SnapshotWriter writer(p_byte_limit);
	const Status status = p_component.write_delta_batch(writer, p_audience, p_dirty, p_baseline, p_session_coordinator);
	if (!status.ok()) {
		return status;
	}
	if (!writer.ok()) {
		return writer.status();
	}
	r_bytes = writer.take();
	return ok_status();
}

Status decode_and_apply_delta_batch(const std::vector<std::uint8_t> &p_bytes, std::size_t p_byte_limit,
		AbilityComponent &p_component, GameplayAbilityWorldCoordinator *p_session_coordinator) {
	if (p_bytes.size() > p_byte_limit) {
		return make_status(StatusCode::PAYLOAD_TOO_LARGE, DiagnosticId::BYTE_LIMIT_EXCEEDED, p_bytes.size());
	}
	SnapshotReader reader(p_bytes);
	const Status status = p_component.apply_delta_batch(reader, p_session_coordinator);
	if (!status.ok()) {
		return status;
	}
	if (!reader.at_end()) {
		return make_status(StatusCode::DECODE_FAILED, DiagnosticId::TRUNCATED_PAYLOAD, p_bytes.size());
	}
	return ok_status();
}

} // namespace ga::proto
