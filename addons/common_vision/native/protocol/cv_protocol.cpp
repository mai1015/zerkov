#include "protocol/cv_protocol.h"

#include "core/cv_limits.h"

#include <limits>

namespace cv::protocol {
namespace {

class Writer {
public:
	std::vector<std::uint8_t> bytes;

	void u8(std::uint8_t p_value) { bytes.push_back(p_value); }
	void u16(std::uint16_t p_value) {
		for (int i = 0; i < 2; ++i) {
			u8(static_cast<std::uint8_t>(p_value >> (i * 8)));
		}
	}
	void u32(std::uint32_t p_value) {
		for (int i = 0; i < 4; ++i) {
			u8(static_cast<std::uint8_t>(p_value >> (i * 8)));
		}
	}
	void u64(std::uint64_t p_value) {
		for (int i = 0; i < 8; ++i) {
			u8(static_cast<std::uint8_t>(p_value >> (i * 8)));
		}
	}
	void i64(std::int64_t p_value) { u64(static_cast<std::uint64_t>(p_value)); }
};

class Reader {
public:
	Reader(const std::uint8_t *p_data, std::size_t p_size) :
			data(p_data), size(p_size) {}

	bool u8(std::uint8_t &r_value) {
		if (position == size) {
			return false;
		}
		r_value = data[position++];
		return true;
	}
	bool u16(std::uint16_t &r_value) {
		std::uint64_t value = 0;
		if (!unsigned_value(2, value)) return false;
		r_value = static_cast<std::uint16_t>(value);
		return true;
	}
	bool u32(std::uint32_t &r_value) {
		std::uint64_t value = 0;
		if (!unsigned_value(4, value)) return false;
		r_value = static_cast<std::uint32_t>(value);
		return true;
	}
	bool u64(std::uint64_t &r_value) { return unsigned_value(8, r_value); }
	bool i64(std::int64_t &r_value) {
		std::uint64_t value = 0;
		if (!u64(value)) return false;
		r_value = static_cast<std::int64_t>(value);
		return true;
	}
	bool complete() const { return position == size; }

private:
	const std::uint8_t *data = nullptr;
	std::size_t size = 0;
	std::size_t position = 0;

	bool unsigned_value(std::size_t p_width, std::uint64_t &r_value) {
		if (p_width > size - position) {
			return false;
		}
		r_value = 0;
		for (std::size_t i = 0; i < p_width; ++i) {
			r_value |= std::uint64_t(data[position++]) << (i * 8);
		}
		return true;
	}
};

void write_manifest(Writer &p_writer, const Manifest &p_manifest) {
	p_writer.u16(p_manifest.protocol_version);
	p_writer.u16(p_manifest.algorithm_version);
}

bool read_manifest(Reader &p_reader, Manifest &r_manifest) {
	return p_reader.u16(r_manifest.protocol_version) &&
			p_reader.u16(r_manifest.algorithm_version);
}

Status validate_manifest(const Manifest &p_manifest) {
	if (p_manifest.protocol_version != PROTOCOL_VERSION) {
		return make_status(StatusCode::INCOMPATIBLE,
				DiagnosticId::PROTOCOL_VERSION_DIFFERS,
				p_manifest.protocol_version);
	}
	if (p_manifest.algorithm_version != ALGORITHM_CONTRACT_VERSION) {
		return make_status(StatusCode::INCOMPATIBLE,
				DiagnosticId::ALGORITHM_VERSION_DIFFERS,
				p_manifest.algorithm_version);
	}
	return ok_status();
}

Status validate_projection_for_wire(
		const ObserverProjection &p_projection) {
	if (!static_cast<bool>(p_projection.observer) ||
			p_projection.world_revision == 0 ||
			p_projection.observer_revision == 0 ||
			p_projection.result_revision == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_IDENTITY);
	}
	if (p_projection.work_units > MAX_WORK_PER_TICK) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::WORK_BUDGET_EXCEEDED,
				p_projection.work_units);
	}
	if (p_projection.records.size() >
			MAX_MEMORY_RECORDS_PER_OBSERVER) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED,
				p_projection.records.size());
	}
	TargetId previous;
	for (const VisibilityRecord &record : p_projection.records) {
		if (!static_cast<bool>(record.target) ||
				(static_cast<bool>(previous) && !(previous < record.target)) ||
				record.target_revision == 0 ||
				record.last_seen_tick < record.first_seen_tick) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_IDENTITY, record.target.value);
		}
		if (static_cast<std::uint8_t>(record.state) >
					static_cast<std::uint8_t>(VisibilityState::VISIBLE) ||
				static_cast<std::uint8_t>(record.transition) >
						static_cast<std::uint8_t>(
								VisibilityTransition::REMOVED)) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_ENUM, record.target.value);
		}
		const bool live_state = record.state == VisibilityState::VISIBLE &&
				(record.transition == VisibilityTransition::BECAME_VISIBLE ||
						record.transition ==
								VisibilityTransition::REMAINED_VISIBLE);
		const bool remembered_state =
				record.state == VisibilityState::REMEMBERED &&
				(record.transition ==
						VisibilityTransition::BECAME_REMEMBERED ||
						record.transition ==
								VisibilityTransition::REMAINED_REMEMBERED);
		const bool terminal_state = record.state == VisibilityState::UNKNOWN &&
				(record.transition == VisibilityTransition::MEMORY_EXPIRED ||
						record.transition == VisibilityTransition::REMOVED);
		if (!(live_state || remembered_state || terminal_state) ||
				record.has_last_known_position == terminal_state) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_ENUM, record.target.value);
		}
		if (!record.has_last_known_position) {
			if (record.last_known_position != Vec2{}) {
				return make_status(StatusCode::INVALID_ARGUMENT,
						DiagnosticId::COORDINATE_OUT_OF_RANGE,
						record.target.value);
			}
		} else if (record.last_known_position.x < -MAX_ABS_COORDINATE ||
				record.last_known_position.x > MAX_ABS_COORDINATE ||
				record.last_known_position.y < -MAX_ABS_COORDINATE ||
				record.last_known_position.y > MAX_ABS_COORDINATE) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::COORDINATE_OUT_OF_RANGE,
					record.target.value);
		}
		previous = record.target;
	}
	return ok_status();
}

void write_projection(Writer &p_writer, const ObserverProjection &p_projection) {
	p_writer.u64(p_projection.observer.value);
	p_writer.u64(p_projection.world_revision);
	p_writer.u64(p_projection.geometry_revision);
	p_writer.u64(p_projection.observer_revision);
	p_writer.u64(p_projection.result_revision);
	p_writer.u64(p_projection.completed_tick);
	p_writer.u64(p_projection.work_units);
	p_writer.u32(static_cast<std::uint32_t>(p_projection.records.size()));
	for (const VisibilityRecord &record : p_projection.records) {
		p_writer.u64(record.target.value);
		p_writer.u8(static_cast<std::uint8_t>(record.state));
		p_writer.u8(static_cast<std::uint8_t>(record.transition));
		p_writer.u8(record.has_last_known_position ? 1 : 0);
		p_writer.u8(0);
		p_writer.u64(record.first_seen_tick);
		p_writer.u64(record.last_seen_tick);
		p_writer.i64(record.last_known_position.x);
		p_writer.i64(record.last_known_position.y);
		p_writer.u64(record.geometry_revision);
		p_writer.u64(record.target_revision);
	}
}

Status read_projection(Reader &p_reader, ObserverProjection &r_projection) {
	std::uint64_t observer = 0;
	std::uint32_t count = 0;
	if (!p_reader.u64(observer) ||
			!p_reader.u64(r_projection.world_revision) ||
			!p_reader.u64(r_projection.geometry_revision) ||
			!p_reader.u64(r_projection.observer_revision) ||
			!p_reader.u64(r_projection.result_revision) ||
			!p_reader.u64(r_projection.completed_tick) ||
			!p_reader.u64(r_projection.work_units) ||
			!p_reader.u32(count)) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TRUNCATED_PAYLOAD);
	}
	if (observer == 0) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_IDENTITY);
	}
	if (count > MAX_MEMORY_RECORDS_PER_OBSERVER) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::COUNT_LIMIT_EXCEEDED, count);
	}
	r_projection.observer = ObserverId{ observer };
	r_projection.records.clear();
	r_projection.records.reserve(count);
	for (std::uint32_t i = 0; i < count; ++i) {
		VisibilityRecord record;
		std::uint64_t target = 0;
		std::uint8_t state = 0;
		std::uint8_t transition = 0;
		std::uint8_t has_position = 0;
		std::uint8_t reserved = 0;
		if (!p_reader.u64(target) || !p_reader.u8(state) ||
				!p_reader.u8(transition) || !p_reader.u8(has_position) ||
				!p_reader.u8(reserved) ||
				!p_reader.u64(record.first_seen_tick) ||
				!p_reader.u64(record.last_seen_tick) ||
				!p_reader.i64(record.last_known_position.x) ||
				!p_reader.i64(record.last_known_position.y) ||
				!p_reader.u64(record.geometry_revision) ||
				!p_reader.u64(record.target_revision)) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::TRUNCATED_PAYLOAD);
		}
		if (target == 0) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_IDENTITY);
		}
		if (state > static_cast<std::uint8_t>(VisibilityState::VISIBLE) ||
				transition > static_cast<std::uint8_t>(
						VisibilityTransition::REMOVED) ||
				has_position > 1 || reserved != 0) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_ENUM);
		}
		record.target = TargetId{ target };
		record.state = static_cast<VisibilityState>(state);
		record.transition = static_cast<VisibilityTransition>(transition);
		record.has_last_known_position = has_position != 0;
		if (!r_projection.records.empty() &&
				!(r_projection.records.back().target < record.target)) {
			return make_status(StatusCode::INVALID_ARGUMENT,
					DiagnosticId::INVALID_IDENTITY, target);
		}
		r_projection.records.push_back(record);
	}
	return validate_projection_for_wire(r_projection);
}

Status validate_size(std::size_t p_size) {
	if (p_size > MAX_PROTOCOL_BYTES) {
		return make_status(StatusCode::LIMIT_EXCEEDED,
				DiagnosticId::PAYLOAD_TOO_LARGE, p_size);
	}
	return ok_status();
}

} // namespace

Status encode_snapshot(const Snapshot &p_snapshot,
		std::vector<std::uint8_t> &r_bytes) {
	Status status = validate_manifest(p_snapshot.manifest);
	if (!status.ok()) return status;
	status = validate_projection_for_wire(p_snapshot.projection);
	if (!status.ok()) return status;
	if (!static_cast<bool>(p_snapshot.world) || p_snapshot.sequence == 0 ||
			p_snapshot.sequence != p_snapshot.projection.result_revision) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::INVALID_IDENTITY);
	}
	Writer writer;
	writer.bytes.reserve(76 + p_snapshot.projection.records.size() * 68);
	writer.u32(SNAPSHOT_MAGIC);
	write_manifest(writer, p_snapshot.manifest);
	writer.u64(p_snapshot.world.value);
	writer.u64(p_snapshot.sequence);
	write_projection(writer, p_snapshot.projection);
	status = validate_size(writer.bytes.size());
	if (!status.ok()) return status;
	r_bytes = std::move(writer.bytes);
	return ok_status();
}

Status decode_snapshot(const std::uint8_t *p_data, std::size_t p_size,
		Snapshot &r_snapshot) {
	Status status = validate_size(p_size);
	if (!status.ok()) return status;
	if (p_data == nullptr || p_size < 4) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TRUNCATED_PAYLOAD);
	}
	Reader reader(p_data, p_size);
	Snapshot decoded;
	std::uint32_t magic = 0;
	if (!reader.u32(magic) || magic != SNAPSHOT_MAGIC ||
			!read_manifest(reader, decoded.manifest) ||
			!reader.u64(decoded.world.value) ||
			!reader.u64(decoded.sequence)) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TRUNCATED_PAYLOAD);
	}
	status = validate_manifest(decoded.manifest);
	if (!status.ok()) return status;
	status = read_projection(reader, decoded.projection);
	if (!status.ok()) return status;
	if (!reader.complete() || !static_cast<bool>(decoded.world) ||
			decoded.sequence == 0 ||
			decoded.sequence != decoded.projection.result_revision) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TRUNCATED_PAYLOAD);
	}
	r_snapshot = std::move(decoded);
	return ok_status();
}

Status encode_delta(const Delta &p_delta, std::vector<std::uint8_t> &r_bytes) {
	Status status = validate_manifest(p_delta.manifest);
	if (!status.ok()) return status;
	status = validate_projection_for_wire(p_delta.projection);
	if (!status.ok()) return status;
	if (!static_cast<bool>(p_delta.world) || p_delta.predecessor == 0 ||
			p_delta.predecessor ==
					std::numeric_limits<Revision>::max() ||
			p_delta.successor != p_delta.predecessor + 1 ||
			p_delta.successor != p_delta.projection.result_revision) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::WORLD_REVISION_STALE);
	}
	Writer writer;
	writer.bytes.reserve(84 + p_delta.projection.records.size() * 68);
	writer.u32(DELTA_MAGIC);
	write_manifest(writer, p_delta.manifest);
	writer.u64(p_delta.world.value);
	writer.u64(p_delta.predecessor);
	writer.u64(p_delta.successor);
	write_projection(writer, p_delta.projection);
	status = validate_size(writer.bytes.size());
	if (!status.ok()) return status;
	r_bytes = std::move(writer.bytes);
	return ok_status();
}

Status decode_delta(const std::uint8_t *p_data, std::size_t p_size,
		Delta &r_delta) {
	Status status = validate_size(p_size);
	if (!status.ok()) return status;
	if (p_data == nullptr || p_size < 4) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TRUNCATED_PAYLOAD);
	}
	Reader reader(p_data, p_size);
	Delta decoded;
	std::uint32_t magic = 0;
	if (!reader.u32(magic) || magic != DELTA_MAGIC ||
			!read_manifest(reader, decoded.manifest) ||
			!reader.u64(decoded.world.value) ||
			!reader.u64(decoded.predecessor) ||
			!reader.u64(decoded.successor)) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::TRUNCATED_PAYLOAD);
	}
	status = validate_manifest(decoded.manifest);
	if (!status.ok()) return status;
	status = read_projection(reader, decoded.projection);
	if (!status.ok()) return status;
	if (!reader.complete() || !static_cast<bool>(decoded.world) ||
			decoded.predecessor == 0 ||
			decoded.predecessor ==
					std::numeric_limits<Revision>::max() ||
			decoded.successor != decoded.predecessor + 1 ||
			decoded.successor != decoded.projection.result_revision) {
		return make_status(StatusCode::INVALID_ARGUMENT,
				DiagnosticId::WORLD_REVISION_STALE);
	}
	r_delta = std::move(decoded);
	return ok_status();
}

Status apply_delta(Snapshot &r_current, const Delta &p_delta) {
	Status status = validate_manifest(p_delta.manifest);
	if (!status.ok()) return status;
	status = validate_projection_for_wire(p_delta.projection);
	if (!status.ok()) return status;
	if (p_delta.successor != p_delta.projection.result_revision) {
		return make_status(StatusCode::REVISION_MISMATCH,
				DiagnosticId::PROJECTION_STALE,
				p_delta.projection.result_revision);
	}
	if (r_current.world != p_delta.world ||
			r_current.projection.observer != p_delta.projection.observer) {
		return make_status(StatusCode::INCOMPATIBLE,
				DiagnosticId::INVALID_IDENTITY);
	}
	if (p_delta.predecessor < r_current.sequence ||
			p_delta.successor <= r_current.sequence) {
		return make_status(StatusCode::REVISION_MISMATCH,
				DiagnosticId::WORLD_REVISION_STALE, r_current.sequence);
	}
	if (p_delta.predecessor != r_current.sequence ||
			r_current.sequence ==
					std::numeric_limits<Revision>::max() ||
			p_delta.successor != r_current.sequence + 1) {
		return make_status(StatusCode::SNAPSHOT_REQUIRED,
				DiagnosticId::WORLD_REVISION_STALE, r_current.sequence);
	}
	r_current.manifest = p_delta.manifest;
	r_current.sequence = p_delta.successor;
	r_current.projection = p_delta.projection;
	return ok_status();
}

std::uint64_t stable_hash(const std::vector<std::uint8_t> &p_bytes) {
	std::uint64_t hash = UINT64_C(14695981039346656037);
	for (std::uint8_t byte : p_bytes) {
		hash ^= byte;
		hash *= UINT64_C(1099511628211);
	}
	return hash;
}

} // namespace cv::protocol
